#! /bin/bash

set -e

TERRAFORM_URL="https://github.com/openshift-cs/terraform-vpc-example"
TERRAFORM_DIR="terraform-vpc-example"
TERRAFORM_PLAN="rosa.tfplan"
# Region 'us-east-2' not currently available for Hosted Control Plane cluster.
REGION="us-west-2"
# ALBO needs at least 2 az subnets
SUBNETS="[\"usw2-az1\", \"usw2-az2\"]"
DESTROY_OPT=""

[ "${1}" = "-d" ] && DESTROY_OPT="-destroy"

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
terraform plan ${DESTROY_OPT} -out "${TERRAFORM_PLAN}" -var region="${REGION}" -var subnet_azs="${SUBNETS}" -var single_az_only="false"

read -p "=> press any key to apply..."

echo "=> terraform apply"
terraform apply ${DESTROY_OPT} "${TERRAFORM_PLAN}"

#SUBNET_IDS=$(terraform output -raw cluster-subnets-string)

#echo "=> subnets: ${SUBNET_IDS}"
