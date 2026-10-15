#!/usr/bin/env bash

set -ueo pipefail

# Create or delete a ROSA HCP (Hosted Control Plane) cluster, end to end.
#
# Companion to rosa-cluster.sh, which stays as-is for ROSA Classic. This one is
# HCP-only and deliberately covers the two things that silently block HCP and
# that rosa-cluster.sh never did:
#
#   1. ocm-role / user-role. Without an ocm-role LINKED to your OCM org, every
#      cluster create dies with "Organization '<id>' is not authorized to
#      access AWS Account '<id>'". This is per-AWS-account, not per-cluster,
#      and is the single most common reason a fresh account does not work.
#   2. --billing-account, now required for HCP.
#
# Also note vs rosa-cluster.sh:
#   - `rosa init` is NOT run: its own help says it configures non-STS IAM
#     clusters. It does nothing useful for HCP.
#   - login is `--use-auth-code` (browser). The old ~/.rosa-token offline
#     token flow is deprecated, and `rosa login --env=` no longer exists.
#   - teardown removes the oidc-CONFIG (HCP) rather than the oidc-PROVIDER
#     (Classic), and the VPC CloudFormation stack if we created it.
#
# Account-wide, reusable, and NOT deleted by --delete:
#   ocm-role, user-role, account-roles.
# Per-cluster, created and deleted by this script:
#   VPC stack (unless --subnets), oidc-config, operator-roles, cluster.
#
# Docs: hcp/stage/ has the hand-run version of every step here.

STATE_DIR="${ROSA_HCP_STATE_DIR:-${HOME}/.rosa-hcp}"

# not more than 15 chars
DEFAULT_NAME="${USER:0:6}$(date +%m%d)-test"

CLUSTER_NAME="${DEFAULT_NAME}"
ACCOUNT_PREFIX="${USER}"
ACTION="create"
REGION="us-west-2"
AZ=""
REPLICAS="2"
MACHINE_TYPE="m5.xlarge"
SUBNET_IDS=""
BILLING_ACCOUNT=""
VERSION_OPT=""
CUSTOM_TAGS_OPT=""
ADMIN="yes"
DRY_RUN=""
WAIT_TIMEOUT="30"
WAIT_MAX_MIN="45"

# CIDR of the VPC we create ourselves. --machine-cidr has to match the VPC the
# subnets actually live in, so with --subnets it is looked up instead.
VPC_CIDR="10.0.0.0/16"
MACHINE_CIDR=""
OIDC_ID=""
VPC_OWNED="no"

usage() {
    cat <<EOF
Create or delete a ROSA HCP cluster.
Usage: ${0} [OPTIONS]
    --cluster-name      Cluster name (<= 15 characters) [default: ${DEFAULT_NAME}].
    --prefix            Prefix for the account-wide IAM roles [default: \${USER}].
    --region            AWS region [default: ${REGION}].
    --az                Availability zone [default: <region>a].
    --replicas          Number of compute nodes [default: ${REPLICAS}].
    --machine-type      Compute machine type [default: ${MACHINE_TYPE}].
    --subnets           Reuse existing subnets "public,private" [optional].
                        Omit to create a dedicated VPC for the cluster.
    --billing-account   AWS billing account ID [default: the current account].
    --version           Specific OpenShift version, e.g. 4.22.16 [optional].
    --nightly           Use the latest nightly version [optional].
    --tags              Extra resource tags (tag1:val1,tag2:val2) [optional].
    --no-admin          Do not create a cluster-admin user [optional].
    --dry-run           Validate the cluster create and stop [optional].
                        NOT side-effect free: the prerequisites (roles, VPC,
                        OIDC config) are really created, only the cluster is
                        skipped. Use --delete afterwards to clean up.
    --delete            Delete the cluster and its per-cluster resources.

NOTE: uses your current AWS profile. Export AWS_PROFILE first, e.g.
      AWS_PROFILE=saml ${0} --cluster-name mytest
EOF
    exit 1
}

info() { echo "=> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case ${1} in
      --cluster-name)    CLUSTER_NAME="$2"; shift ;;
      --prefix)          ACCOUNT_PREFIX="$2"; shift ;;
      --region)          REGION="$2"; shift ;;
      --az)              AZ="$2"; shift ;;
      --replicas)        REPLICAS="$2"; shift ;;
      --machine-type)    MACHINE_TYPE="$2"; shift ;;
      --subnets)         SUBNET_IDS="$2"; shift ;;
      --billing-account) BILLING_ACCOUNT="$2"; shift ;;
      --version)         VERSION_OPT="--version=$2"; shift ;;
      --nightly)         VERSION_OPT="nightly" ;;
      --tags)            CUSTOM_TAGS_OPT="--tags=$2"; shift ;;
      --no-admin)        ADMIN="no" ;;
      --dry-run)         DRY_RUN="--dry-run" ;;
      --delete)          ACTION="delete" ;;
      *)                 usage ;;
  esac
  shift
done

[ -z "${CLUSTER_NAME}" ] && die "no cluster name provided"
[ ${#CLUSTER_NAME} -gt 15 ] && die "cluster name must not exceed 15 characters"
[ -z "${AZ}" ] && AZ="${REGION}a"

STATE_FILE="${STATE_DIR}/${CLUSTER_NAME}.env"
STACK_NAME="${CLUSTER_NAME}-vpc"
# Operator roles are bound to a per-cluster OIDC config, so they get a
# per-cluster prefix. Account roles are shared, so they get a stable one.
OPERATOR_PREFIX="${CLUSTER_NAME}"

preflight() {
    for c in rosa aws jq; do
        [ -x "$(command -v ${c})" ] || die "${c} not found in PATH"
    done

    # AWS before OCM: `rosa whoami` needs working AWS credentials itself, so a
    # stale profile makes it fail with an OCM-shaped error and sends you off
    # re-running `rosa login`, which fixes nothing.
    AWS_ACCOUNT="$(aws sts get-caller-identity --query Account --output text)" \
        || die "AWS credentials not usable (AWS_PROFILE=${AWS_PROFILE:-default})"

    local who
    who="$(rosa whoami --output json 2>/dev/null)" \
        || die "rosa whoami failed. Check AWS_PROFILE, then: rosa login --use-auth-code"
    OCM_ORG="$(jq -r '.["OCM Organization ID"] // empty' <<<"${who}")"
    OCM_ENV="$(jq -r '.["OCM API"] // empty' <<<"${who}")"
    [ -n "${OCM_ORG}" ] || die "could not read the OCM organization from 'rosa whoami'"

    info "AWS account ${AWS_ACCOUNT} / OCM org ${OCM_ORG} / ${OCM_ENV}"

    # Plain assignment, NOT '[ -z ... ] && ...'. That form is the last statement
    # of the function and returns 1 whenever --billing-account was given, so
    # set -e killed the whole script here without printing anything.
    BILLING_ACCOUNT="${BILLING_ACCOUNT:-${AWS_ACCOUNT}}"
}

# The step that makes a fresh AWS account usable at all. Must be LINKED=Yes,
# otherwise cluster creation fails on org<->account authorization.
ensure_ocm_role() {
    local linked
    linked="$(rosa list ocm-role 2>/dev/null | awk 'NR>1 && $3=="Yes"{print $1; exit}')"
    if [ -n "${linked}" ]; then
        info "ocm-role already linked: ${linked}"
        return
    fi
    if rosa list ocm-role 2>/dev/null | awk 'NR>1{exit 0} END{exit 1}'; then
        # A role exists but is not linked to our org. Do NOT touch it: it is
        # usually a shared CI role owned by someone else.
        rosa list ocm-role
        die "an ocm-role exists but is not LINKED to org ${OCM_ORG}.
  If it is yours:     rosa link ocm-role --role-arn <arn>
  If it is shared CI: use a different AWS account, or ask its owner.
  Linking somebody else's shared role is not something this script will do."
    fi
    info "creating and linking ocm-role (prefix ${ACCOUNT_PREFIX})"
    rosa create ocm-role --prefix "${ACCOUNT_PREFIX}" --mode auto -y
}

ensure_user_role() {
    local linked
    linked="$(rosa list user-role 2>/dev/null | awk 'NR>1 && $3=="Yes"{print $1; exit}')"
    if [ -n "${linked}" ]; then
        info "user-role already linked: ${linked}"
        return
    fi
    # Same trap as ocm-role: creating on top of an existing unlinked role just
    # fails on a name clash, so say what is actually wrong.
    if rosa list user-role 2>/dev/null | awk 'NR>1{exit 0} END{exit 1}'; then
        rosa list user-role
        die "a user-role exists but is not LINKED to your OCM account.
  If it is yours: rosa link user-role --role-arn <arn>"
    fi
    info "creating and linking user-role (prefix ${ACCOUNT_PREFIX})"
    rosa create user-role --prefix "${ACCOUNT_PREFIX}" --mode auto -y
}

ensure_account_roles() {
    INSTALLER_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT}:role/${ACCOUNT_PREFIX}-HCP-ROSA-Installer-Role"
    SUPPORT_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT}:role/${ACCOUNT_PREFIX}-HCP-ROSA-Support-Role"
    WORKER_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT}:role/${ACCOUNT_PREFIX}-HCP-ROSA-Worker-Role"

    if aws iam get-role --role-name "${ACCOUNT_PREFIX}-HCP-ROSA-Installer-Role" >/dev/null 2>&1; then
        info "account roles already present (prefix ${ACCOUNT_PREFIX})"
        return
    fi
    info "creating HCP account roles (prefix ${ACCOUNT_PREFIX})"
    rosa create account-roles --hosted-cp --prefix "${ACCOUNT_PREFIX}" --mode auto -y
}

# Sets SUBNET_IDS. Honours --subnets; otherwise builds a dedicated VPC and
# records that we own it so --delete can tear the stack down.
ensure_network() {
    if [ -n "${SUBNET_IDS}" ]; then
        info "reusing provided subnets: ${SUBNET_IDS}"
        VPC_OWNED="no"
        # --machine-cidr must match the VPC the subnets are in. Hardcoding the
        # 10.0.0.0/16 we use for our own VPC makes cluster create fail against
        # any other VPC, so derive it.
        local first vpc
        first="${SUBNET_IDS%%,*}"
        vpc="$(aws ec2 describe-subnets --region "${REGION}" --subnet-ids "${first}" \
                 --query 'Subnets[0].VpcId' --output text)" \
            || die "cannot describe subnet ${first} in ${REGION}"
        MACHINE_CIDR="$(aws ec2 describe-vpcs --region "${REGION}" --vpc-ids "${vpc}" \
                 --query 'Vpcs[0].CidrBlock' --output text)" \
            || die "cannot describe VPC ${vpc}"
        info "machine CIDR from ${vpc}: ${MACHINE_CIDR}"
        return
    fi

    VPC_OWNED="yes"
    MACHINE_CIDR="${VPC_CIDR}"

    # describe-stacks also succeeds for ROLLBACK_COMPLETE / DELETE_FAILED, and
    # "reusing" one of those just fails later with an unhelpful missing-subnet
    # error, so check the status rather than mere existence.
    local status
    status="$(aws cloudformation describe-stacks --region "${REGION}" \
                --stack-name "${STACK_NAME}" \
                --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)"
    case "${status}" in
        CREATE_COMPLETE|UPDATE_COMPLETE)
            info "reusing existing VPC stack ${STACK_NAME}" ;;
        "")
            info "creating VPC stack ${STACK_NAME} (this takes ~3-4 min, mostly the NAT gateway)"
            rosa create network rosa-quickstart-default-vpc \
                --param "Region=${REGION}" \
                --param "Name=${STACK_NAME}" \
                --param "AvailabilityZoneCount=1" \
                --param "AZ1=${AZ}" \
                --param "VpcCidr=${VPC_CIDR}" \
                --mode auto -y ;;
        *)
            die "stack ${STACK_NAME} is in state ${status} and cannot be used.
  Remove it first:
    aws cloudformation delete-stack --region ${REGION} --stack-name ${STACK_NAME}" ;;
    esac

    local public private
    public="$(aws cloudformation describe-stack-resources --region "${REGION}" \
        --stack-name "${STACK_NAME}" \
        --query "StackResources[?LogicalResourceId=='SubnetPublic1'].PhysicalResourceId" \
        --output text)"
    private="$(aws cloudformation describe-stack-resources --region "${REGION}" \
        --stack-name "${STACK_NAME}" \
        --query "StackResources[?LogicalResourceId=='SubnetPrivate1'].PhysicalResourceId" \
        --output text)"
    [ -n "${public}" -a -n "${private}" ] || die "could not resolve subnets from stack ${STACK_NAME}"

    SUBNET_IDS="${public},${private}"
    info "subnets: public=${public} private=${private}"
    save_state
}

ensure_oidc_config() {
    info "creating managed OIDC config"
    local out
    out="$(rosa create oidc-config --managed=true --mode auto -y 2>&1)" || { echo "${out}"; die "oidc-config failed"; }
    echo "${out}"
    OIDC_ARN="$(grep -oP 'arn:aws:iam:[^ '"'"']*oidc-provider[^ '"'"']*' <<<"${out}" | head -1)"
    OIDC_ID="${OIDC_ARN##*/}"
    [ -n "${OIDC_ID}" ] || die "could not parse OIDC config id"
    info "oidc-config id: ${OIDC_ID}"
    save_state
}

ensure_operator_roles() {
    info "creating operator roles (prefix ${OPERATOR_PREFIX})"
    rosa create operator-roles --hosted-cp \
        --prefix "${OPERATOR_PREFIX}" \
        --oidc-config-id "${OIDC_ID}" \
        --installer-role-arn "${INSTALLER_ROLE_ARN}" \
        --mode auto -y
}

resolve_version() {
    [ "${VERSION_OPT}" != "nightly" ] && return
    info "resolving latest nightly"
    local v
    v="$(rosa list versions --channel-group=nightly --hosted-cp -o json | jq -r '.[0].raw_id')"
    [ -n "${v}" -a "${v}" != "null" ] || die "no nightly version available"
    VERSION_OPT="--channel-group=nightly --version=${v}"
    info "nightly: ${v}"
}

# Called after every step that creates something deletable, not once at the
# end: if a later step fails there is otherwise no state file at all, --delete
# then assumes it does not own the VPC, and a NAT gateway plus six VPC
# endpoints are left billing in an account nobody looks at again.
save_state() {
    mkdir -p "${STATE_DIR}"
    cat >"${STATE_FILE}" <<EOF
CLUSTER_NAME="${CLUSTER_NAME}"
REGION="${REGION}"
AWS_ACCOUNT="${AWS_ACCOUNT}"
ACCOUNT_PREFIX="${ACCOUNT_PREFIX}"
OPERATOR_PREFIX="${OPERATOR_PREFIX}"
OIDC_ID="${OIDC_ID}"
SUBNET_IDS="${SUBNET_IDS}"
STACK_NAME="${STACK_NAME}"
VPC_OWNED="${VPC_OWNED}"
EOF
}

create_cluster() {
    info "creating cluster ${CLUSTER_NAME}"
    set -x
    rosa create cluster \
        --cluster-name "${CLUSTER_NAME}" \
        --hosted-cp --sts \
        --role-arn "${INSTALLER_ROLE_ARN}" \
        --support-role-arn "${SUPPORT_ROLE_ARN}" \
        --worker-iam-role-arn "${WORKER_ROLE_ARN}" \
        --oidc-config-id "${OIDC_ID}" \
        --operator-roles-prefix "${OPERATOR_PREFIX}" \
        --subnet-ids "${SUBNET_IDS}" \
        --region "${REGION}" \
        --billing-account "${BILLING_ACCOUNT}" \
        --machine-cidr "${MACHINE_CIDR}" \
        --service-cidr 172.30.0.0/16 \
        --pod-cidr 10.128.0.0/14 \
        --host-prefix 23 \
        --replicas "${REPLICAS}" \
        --compute-machine-type "${MACHINE_TYPE}" \
        ${VERSION_OPT} ${CUSTOM_TAGS_OPT} ${DRY_RUN} -y
    set +x
}

# 'ready' means the HOSTED CONTROL PLANE is up. Worker nodes join afterwards,
# so a machinepool showing 0/N right after ready is expected, not a failure.
wait_ready() {
    info "waiting for the hosted control plane to become ready"
    local deadline=$(( $(date +%s) + WAIT_MAX_MIN * 60 )) state
    while true; do
        state="$(rosa describe cluster -c "${CLUSTER_NAME}" -o json 2>/dev/null | jq -r '.state // "unknown"')"
        case "${state}" in
            ready)  info "control plane ready"; break ;;
            error)  rosa describe cluster -c "${CLUSTER_NAME}"; die "cluster entered error state" ;;
        esac
        [ "$(date +%s)" -gt "${deadline}" ] && die "timed out after ${WAIT_MAX_MIN}m in state '${state}'"
        info "state=${state}"
        sleep "${WAIT_TIMEOUT}"
    done

    info "waiting for ${REPLICAS} worker node(s) to register"
    deadline=$(( $(date +%s) + WAIT_MAX_MIN * 60 ))
    local have
    while true; do
        have="$(rosa list machinepools -c "${CLUSTER_NAME}" -o json 2>/dev/null \
                 | jq -r '[.[] | .status.current_replicas // .current_replicas // 0] | add // 0')"
        # Empty when the call failed mid-wait; -ge on "" is a syntax error that
        # would spam stderr every iteration.
        [ -n "${have}" ] || have=0
        # -ge, not =: autoscaling can overshoot and string equality would then
        # never match, burning the full timeout on a healthy cluster.
        [ "${have}" -ge "${REPLICAS}" ] && { info "workers ready: ${have}/${REPLICAS}"; break; }
        [ "$(date +%s)" -gt "${deadline}" ] && { info "WARNING: only ${have}/${REPLICAS} workers after ${WAIT_MAX_MIN}m"; break; }
        info "workers ${have}/${REPLICAS}"
        sleep "${WAIT_TIMEOUT}"
    done
}

# HCP clusters have no kubeadmin and no downloadable kubeconfig. You create a
# credential, then `oc login` writes your local ~/.kube/config.
create_admin() {
    [ "${ADMIN}" = "yes" ] || { info "skipping admin creation (--no-admin)"; return; }
    info "creating cluster-admin user"
    rosa create admin -c "${CLUSTER_NAME}" -y
}

summary() {
    local api console
    api="$(rosa describe cluster -c "${CLUSTER_NAME}" -o json | jq -r '.api.url // "pending"')"
    console="$(rosa describe cluster -c "${CLUSTER_NAME}" -o json | jq -r '.console.url // "pending"')"
    cat <<EOF

=> cluster ${CLUSTER_NAME} is up
   API:     ${api}
   Console: ${console}
   State:   ${STATE_FILE}

   Log in with the oc command printed above (allow a few minutes for the
   cluster-admin IdP to roll out; early attempts return 401).

   Tear down with:
     ${0} --cluster-name ${CLUSTER_NAME} --delete
EOF
}

do_create() {
    preflight
    ensure_ocm_role
    ensure_user_role
    ensure_account_roles
    resolve_version
    ensure_network
    ensure_oidc_config
    ensure_operator_roles
    save_state
    create_cluster
    [ -n "${DRY_RUN}" ] && { info "dry run only, nothing created"; exit 0; }
    wait_ready
    create_admin
    summary
}

# Echoes the stack status, or "" when the stack genuinely no longer exists.
#
# Dies when the status cannot be established at all. A failed describe-stacks
# is NOT proof of deletion: with expired credentials every call fails, and
# treating that as success reported "stack deleted" for a stack that was still
# DELETE_IN_PROGRESS, then removed the state file that was the only record of
# it. "I cannot see it" and "it is gone" have to stay distinct.
stack_status() {
    local out
    if out="$(aws cloudformation describe-stacks --region "${REGION}" \
                --stack-name "${STACK_NAME}" \
                --query 'Stacks[0].StackStatus' --output text 2>&1)"; then
        echo "${out}"
        return 0
    fi
    grep -qiE 'does not exist|ValidationError' <<<"${out}" && { echo ""; return 0; }
    die "cannot determine the state of stack ${STACK_NAME}:
  ${out}
  Nothing was assumed deleted. Refresh your AWS credentials and re-run --delete."
}

# Returns 0 if the stack is gone, 1 if it is still there.
# The waiter also exits non-zero when our AWS credentials expire mid-wait, and
# it cannot tell that apart from a real failure -- deletion carries on
# server-side either way, so always re-check instead of trusting the exit code.
delete_stack() {
    info "deleting VPC stack ${STACK_NAME}"
    aws cloudformation delete-stack --region "${REGION}" --stack-name "${STACK_NAME}" || true
    aws cloudformation wait stack-delete-complete --region "${REGION}" --stack-name "${STACK_NAME}" \
        || info "waiter returned non-zero, re-checking stack state"

    local status
    status="$(stack_status)"
    [ -z "${status}" ] && { info "stack ${STACK_NAME} deleted"; return 0; }

    # Still deleting: the waiter gave up early (usually expired credentials),
    # but CloudFormation is making progress. Wait it out instead of declaring
    # either success or failure.
    if [ "${status}" = "DELETE_IN_PROGRESS" ]; then
        info "stack still DELETE_IN_PROGRESS, waiting again"
        aws cloudformation wait stack-delete-complete --region "${REGION}" \
            --stack-name "${STACK_NAME}" || true
        status="$(stack_status)"
        [ -z "${status}" ] && { info "stack ${STACK_NAME} deleted"; return 0; }
    fi

    info "stack ${STACK_NAME} still present (${status}):"
    aws cloudformation describe-stack-events --region "${REGION}" \
        --stack-name "${STACK_NAME}" --max-items 5 \
        --query 'StackEvents[?ResourceStatus==`DELETE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
        --output text || true
    return 1
}

# Deleting the cluster does NOT remove everything the cluster put in the VPC.
# HCP leaves a '<cluster-id>-vpce-private-router' security group behind: it was
# created by the cluster, not by CloudFormation, so CFN has no idea it exists
# and `delete-stack` dies with
#   "The vpc '<id>' has dependencies and cannot be deleted"
# leaving the stack in DELETE_FAILED.
#
# Only called AFTER a failed delete-stack, so anything CloudFormation could
# remove on its own is already gone and whatever is left really is an orphan.
reap_orphans() {
    local vpc_id sgs enis
    vpc_id="$(aws cloudformation describe-stack-resources --region "${REGION}" \
        --stack-name "${STACK_NAME}" \
        --query "StackResources[?LogicalResourceId=='VPC'].PhysicalResourceId" \
        --output text 2>/dev/null)"
    [ -n "${vpc_id}" -a "${vpc_id}" != "None" ] || return 0

    # Dangling ENIs block subnet/VPC deletion. Only 'available' ones can go;
    # an 'in-use' ENI means something is still running and must be fixed first.
    enis="$(aws ec2 describe-network-interfaces --region "${REGION}" \
        --filters Name=vpc-id,Values="${vpc_id}" Name=status,Values=available \
        --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null)"
    for eni in ${enis}; do
        info "deleting orphaned ENI ${eni}"
        aws ec2 delete-network-interface --region "${REGION}" --network-interface-id "${eni}" || true
    done

    # Skip 'default': it is removed together with the VPC and cannot be deleted
    # on its own.
    sgs="$(aws ec2 describe-security-groups --region "${REGION}" \
        --filters Name=vpc-id,Values="${vpc_id}" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null)"
    for sg in ${sgs}; do
        info "deleting orphaned security group ${sg}"
        aws ec2 delete-security-group --region "${REGION}" --group-id "${sg}" || true
    done
}

do_delete() {
    preflight

    if [ -f "${STATE_FILE}" ]; then
        info "loading ${STATE_FILE}"
        # shellcheck disable=SC1090
        . "${STATE_FILE}"
    else
        info "WARNING: no state file ${STATE_FILE}; guessing per-cluster resources"
        VPC_OWNED="${VPC_OWNED:-no}"
        OIDC_ID="${OIDC_ID:-}"
    fi

    if rosa describe cluster -c "${CLUSTER_NAME}" >/dev/null 2>&1; then
        info "deleting cluster ${CLUSTER_NAME}"
        rosa delete cluster -c "${CLUSTER_NAME}" -y
        info "waiting for the cluster to be removed"
        local deadline=$(( $(date +%s) + WAIT_MAX_MIN * 60 ))
        while rosa describe cluster -c "${CLUSTER_NAME}" >/dev/null 2>&1; do
            [ "$(date +%s)" -gt "${deadline}" ] && die "timed out waiting for cluster deletion"
            info "still uninstalling"
            sleep "${WAIT_TIMEOUT}"
        done
        info "cluster deleted"
    else
        info "cluster ${CLUSTER_NAME} not found, skipping"
    fi

    info "deleting operator roles (prefix ${OPERATOR_PREFIX})"
    rosa delete operator-roles --prefix "${OPERATOR_PREFIX}" -m auto -y || true

    if [ -n "${OIDC_ID}" ]; then
        info "deleting oidc-config ${OIDC_ID}"
        rosa delete oidc-config --oidc-config-id "${OIDC_ID}" -m auto -y || true
    else
        info "no OIDC config id known, skipping (check: rosa list oidc-config)"
    fi

    if [ "${VPC_OWNED}" = "yes" ]; then
        delete_stack || { reap_orphans; info "retrying stack delete"; delete_stack || \
            die "stack ${STACK_NAME} still will not delete; inspect the DELETE_FAILED reasons above"; }
    else
        info "VPC not created by this script, leaving it alone"
    fi

    rm -f "${STATE_FILE}"

    cat <<EOF

=> ${CLUSTER_NAME} removed.
   Left in place on purpose (account-wide and reusable):
     ocm-role, user-role, account-roles (prefix ${ACCOUNT_PREFIX}).
   Deleting the ocm-role would put the account back in the state where no
   cluster can be created at all.
EOF
}

case "${ACTION}" in
    create) do_create ;;
    delete) do_delete ;;
    *)      usage ;;
esac
