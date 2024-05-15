#! /bin/bash

set -ex

aws iam create-role --role-name albo-operator --assume-role-policy-document file://albo-operator-trusted-policy.json
aws iam put-role-policy --role-name albo-operator --policy-name perms-policy-albo-operator --policy-document file://albo-operator-permission-policy.json

aws iam create-role --role-name albo-controller --assume-role-policy-document file://albo-controller-trusted-policy.json
aws iam put-role-policy --role-name albo-controller --policy-name perms-policy-albo-controller --policy-document file://albo-controller-permission-policy.json
