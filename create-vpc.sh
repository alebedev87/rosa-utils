#! /bin/bash

set -e

TERRAFORM_URL="https://github.com/openshift-cs/terraform-vpc-example"
TERRAFORM_DIR="terraform-vpc-example"
TERRAFORM_PLAN="rosa.tfplan"
REGION="us-west-2"

if [ -d "${TERRAFORM_DIR}" ]; then
    rm -rf "${TERRAFORM_DIR}"
fi

echo "=> cloning terraform vpc repository"
git clone "${TERRAFORM_URL}" "${TERRAFORM_DIR}"

cd "${TERRAFORM_DIR}"

echo "=> terraform init"
terraform init

echo "=> terraform plan"
[ -f "${TERRAFORM_PLAN}" ] && rm -f "${TERRAFORM_PLAN}"
terraform plan -out "${TERRAFORM_PLAN}" -var region="${REGION}"

echo "=> terraform apply"
terraform apply "${TERRAFORM_PLAN}"

SUBNET_IDS=$(terraform output -raw cluster-subnets-string)

echo "=> subnets: ${SUBNET_IDS}"
