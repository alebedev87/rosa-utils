#!/usr/bin/env bash

set -ue

# NOTE: this script will use your current AWS profile!
# ROSA creates the cluster on your current AWS profile, change it if you want to use different from the default one.

# By default, both the worker and control plane nodes are hosted in the ROSA customer's AWS account (your account).
# The customer's account needs to be enabled with the ROSA service (AWS marketplace).
# So the customer pays for the AWS resources and for the ROSA service.

# Source: https://access.redhat.com/documentation/en-us/red_hat_openshift_service_on_aws/4/html/rosa_cli/rosa-get-started-cli

usage() {
    cat <<EOF
Create or delete a ROSA cluster.
Usage: ${0} [OPTIONS]
    --cluster-name      Cluster name (<= 15 characters) [defaults to \${USERNAME}\$(date)-test].
    --rosa-token        ROSA token [defaults to \${HOME}/.rosa-token].
    --username          Cluster admin username [defaults to \${USER}].
    --password          Cluster admin password [required].
    --delete            Delete ROSA cluster [optional].
    --production        Use ROSA production [optional].
    --tags              Add additional resource tags (tag1:val1,tag2:val2) [optional].
EOF
    exit 1
}

# To get the token: https://console.redhat.com/openshift/token/rosa/show
ROSA_TOKEN=$(cat ${HOME}/.rosa-token)
USERNAME="${USER}"
PASSWORD=""
PREFIX="${USERNAME:0:6}$(date +%m%d)"
# not more than 15 chars
CLUSTER_NAME="${PREFIX}-test"
ACTION="create"
# --env is hidden option to force the creation on prod
ENV_OPT="--env=staging"
CLUSTER_WAIT_TIMEOUT="10s"
CUSTOM_TAGS_OPT=""

while [ $# -gt 0 ]; do
  case ${1} in
      --cluster-name)
          CLUSTER_NAME="$2"
          shift
          ;;
      --rosa-token)
          ROSA_TOKEN="$2"
          shift
          ;;
      --password)
          PASSWORD="$2"
          shift
          ;;
      --username)
          USERNAME="$2"
          shift
          ;;
      --delete)
          ACTION="delete"
          ;;
      --production)
          ENV_OPT=""
          ;;
      --tags)
          CUSTOM_TAGS_OPT="--tags=$2"
          shift
          ;;
      *)
          usage
          ;;
  esac
  shift
done

[ ! -x "$(command -v rosa)" ] && { echo "ERROR: rosa client not found"; exit 1; }
[ -z "${CLUSTER_NAME}" ] && { echo "ERROR: no cluster name provided"; usage; exit 1; }
if [ "${ACTION}" == "create" ]; then
    [ ${#CLUSTER_NAME} -gt 15 ] && { echo "ERROR: cluster name must not be greater than 15 characters."; usage; exit 1; }
    [ -z "${ROSA_TOKEN}" ] && { echo "ERROR: no ROSA token provided"; usage; exit 1; }
    [ -z "${PASSWORD}" ] && { echo "ERROR: no cluster admin password provided"; usage; exit 1; }
    [ -z "${USERNAME}" ] && { echo "ERROR: no cluster admin username provided"; usage; exit 1; }
fi

if [ "${ACTION}" == "delete" ]; then
    echo "=> deleting cluster"
    DELETE_CLUSTER_FILE=$(mktemp)
    # Note that if you created a cluster with custom account roles and those roles got wiped out
    # you will have to recreate them before the cluster deletion.
    rosa delete cluster -c "${CLUSTER_NAME}" -y | tee "${DELETE_CLUSTER_FILE}"

    echo "=> waiting for cluster to be deleted"
    while true; do
        STATE="$(rosa describe cluster -c ${CLUSTER_NAME} --output=json | jq -r .state)"
        if [ "${STATE}" == "uninstalling" ]; then
            echo "=> cluster is uninstalling"
            sleep "${CLUSTER_WAIT_TIMEOUT}"
        else
            echo "=> cluster is deleted"
            break
        fi
    done

    echo "=> deleting operator roles and oidc provider"
    OPERATOR_ROLE_ID=$(\grep 'rosa delete operator-roles' "${DELETE_CLUSTER_FILE}" | xargs)
    OIDC_PROVIDER_ID=$(\grep 'rosa delete oidc-provider' "${DELETE_CLUSTER_FILE}" | xargs)
    # Once the cluster is uninstalled, run these commands to clean up the roles and IDP
    rosa delete operator-roles -c "${OPERATOR_ROLE_ID}" -y -m auto
    rosa delete oidc-provider -c "${OIDC_PROVIDER_ID}" -y -m auto
fi

[ "${ACTION}" != "create" ] && exit 0

echo "=> logging to rosa"
rosa login ${ENV_OPT} --token="${ROSA_TOKEN}"
echo "=> initializing rosa client"
rosa init

echo "=> creating custom account roles"
# You may need to create the account roles (controlplane, worker, installer, etc.) in your AWS account.
# These roles can be shared between users, but be aware that they may be updated by another user to use the trusted entity from prod or staging which may be different from your choice.
# Then creation of the personally prefixed ones may be your choice:
ACCOUNT_ROLES_FILE=$(mktemp)
rosa create account-roles --prefix="${PREFIX}" --mode auto -y | tee "${ACCOUNT_ROLES_FILE}"
CONTROL_PLANE_ROLE_ARN=$(\grep 'Created role' "${ACCOUNT_ROLES_FILE}" | \grep -oP 'arn:aws:iam:.*' | \grep 'ControlPlane-Role' | tr -d \')
WORKER_ROLE_ARN=$(\grep 'Created role' "${ACCOUNT_ROLES_FILE}" | \grep -oP 'arn:aws:iam:.*' | \grep 'Worker-Role' | \grep -v 'HCP-ROSA' | tr -d \')

# --mode auto: will create the operator roles and oidc provider too
# auto mode is opposite to manual mode which only prints the delete commands
#rosa create cluster --cluster-name=${CLUSTER_NAME} --sts --multi-az -m auto -y

echo "=> creating cluster"
# You may want to specify the account roles explicitly if they are generated with a custom prefix.
# No flag exists for the installer role, the client will ask you which one you would like to use interactively.
rosa create cluster --cluster-name="${CLUSTER_NAME}" --sts --multi-az --controlplane-iam-role="${CONTROL_PLANE_ROLE_ARN}" --worker-iam-role="${WORKER_ROLE_ARN}" "${CUSTOM_TAGS_OPT}"

echo "=> creating operator roles and oidc provider"
# You can create the operator roles and OIDC provider manually if `rosa create cluster` wasnt' in auto mode:
rosa create operator-roles --cluster="${CLUSTER_NAME}" -y -m auto
rosa create oidc-provider --cluster="${CLUSTER_NAME}" -y -m auto
# Don't forget to notice the OIDC provider ARN!
# You may need it to generate credentials for add on operators suing ccoctl.
# Example: arn:aws:iam::<awsaccount>:oidc-provider/d3gt1gce2zmg3d.cloudfront.net/225om899gi7c9bng49rtt1qli5hkkchq

echo "=> waiting for cluster to be become ready"
while true; do
    STATE="$(rosa describe cluster -c ${CLUSTER_NAME} --output=json | jq -r .state)"
    if [ "${STATE}" != "ready" ]; then
        echo "=> cluster is not ready: ${STATE}"
        sleep "${CLUSTER_WAIT_TIMEOUT}"
    else
        echo "=> cluster is ready"
        break
    fi
done

echo "=> creating identity provider"
# Once the cluster is ready add Identity Provider (IDP) to it.
# Do not confuse it with the OIDC provider created in your AWS account before.
# This IDP will be used inside your OpenShift cluster to authenticate OpenShift users.
rosa create idp --cluster="${CLUSTER_NAME}" --type=htpasswd --username="${USERNAME}" --password="${PASSWORD}"
rosa grant user dedicated-admin --cluster="${CLUSTER_NAME}" --user="${USERNAME}"
rosa grant user cluster-admin --cluster="${CLUSTER_NAME}" --user="${USERNAME}"

# Now you can login to the console and get the login token.
echo "=> login to the console: $(rosa describe cluster -c ${CLUSTER_NAME} --output=json | jq -r .console.url)"
echo "=> login to the api: oc login -u ${USERNAME} -p ${PASSWORD} $(rosa describe cluster -c ${CLUSTER_NAME} --output=json | jq -r .api.url)"
