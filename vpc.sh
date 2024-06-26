#! /bin/bash

set -e

usage() {
    cat <<EOF
Create or delete a ROSA cluster.
Usage: ${0} [OPTIONS]
    -c      Clean and clone terraform module before plan/apply.
    -d      Destroy created terraform stack.
    -t      add extra tag to the stack (<key>=<value>).
EOF
    exit 0
}

TERRAFORM_URL="https://github.com/openshift-cs/terraform-vpc-example"
TERRAFORM_DIR="terraform-vpc-example"
TERRAFORM_PLAN="rosa.tfplan"
# Region 'us-east-2' not currently available for Hosted Control Plane cluster.
REGION="us-west-2"
# ALBO needs at least 2 az subnets
SUBNETS="[\"usw2-az1\", \"usw2-az2\"]"
DESTROY_OPT=""
EXTRA_TAGS_OPT=""
CLUSTER_NAME="aleb-rosa-hcp"

[ "${1}" = "-h" ] && usage

[ "${1}" = "-d" ] && DESTROY_OPT="-destroy"
if [ "${1}" = "-t" ]; then
    [ -z "${2}" ] && { echo "no tags provided"; exit 1; }
    # for the moment only one tag is supported
    KEY=$(echo ${2} | cut -d= -f1)
    VAL=$(echo ${2} | cut -d= -f2)
    EXTRA_TAGS_OPT="-var extra_tags={\"${KEY}\"=\"${VAL}\"}"
fi

if [ "${1}" = "-c" ]; then
    if [ -d "${TERRAFORM_DIR}" ]; then
        rm -rf "${TERRAFORM_DIR}"
    fi

    echo "=> cloning terraform vpc repository"
    git clone "${TERRAFORM_URL}" "${TERRAFORM_DIR}"
fi

cd "${TERRAFORM_DIR}"

echo "=> terraform init"
terraform init

echo "=> terraform plan"
[ -f "${TERRAFORM_PLAN}" -a "${1}" = "-c" ] && rm -f "${TERRAFORM_PLAN}"
set -x
terraform plan ${DESTROY_OPT} -out "${TERRAFORM_PLAN}" -var cluster_name="${CLUSTER_NAME}" -var region="${REGION}" -var subnet_azs="${SUBNETS}" -var single_az_only="false" ${EXTRA_TAGS_OPT}
set +x

read -p "=> press enter to apply..."

echo "=> terraform apply"
terraform apply ${DESTROY_OPT} "${TERRAFORM_PLAN}"
