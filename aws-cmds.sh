#! /bin/bash

set -ex

[ -z "${IDP}" ] && { echo "no identity provider"; exit 1; }

cp -f albo-operator-trusted-policy.json albo-operator-trusted-policy.json.in
cp -f albo-controller-trusted-policy.json albo-controller-trusted-policy.json.in
sed -i "s|\${IDP}|${IDP}|" albo-operator-trusted-policy.json.in
sed -i "s|\${IDP}|${IDP}|" albo-controller-trusted-policy.json.in

aws iam create-role --role-name albo-operator --assume-role-policy-document file://albo-operator-trusted-policy.json
aws iam put-role-policy --role-name albo-operator --policy-name perms-policy-albo-operator --policy-document file://albo-operator-permission-policy.json

aws iam create-role --role-name albo-controller --assume-role-policy-document file://albo-controller-trusted-policy.json
aws iam put-role-policy --role-name albo-controller --policy-name perms-policy-albo-controller --policy-document file://albo-controller-permission-policy.json

# aws iam delete-role-policy --role-name albo-operator --policy-name perms-policy-albo-operator
# aws iam delete-role --role-name albo-operator
# aws iam delete-role-policy --role-name albo-controller --policy-name perms-policy-albo-controller
# aws iam delete-role --role-name albo-controller
