# gitea

## Description

Gitea package to deploy a gitea server in a gitea namespace

## OpenShift

When deploying this kpt package on OpenShift, it will install a specific SecurityContext because Gitea expect a `fsGroup` and `uid` that aren't in the tolerated range of OpenShift. As such, this package will create an SCC, a Role and a RoleBinding.

## Access

Navigate to https://gitea-gitea.apps.{clusterName}.{domainName}

Credentials:
    - user: gitea
    - password: passowrd