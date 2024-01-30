# ArgoCD KPT Configuration Management Plugin

Note: this is a fork from this repository: https://github.com/bluebrown/argocd-cmp-kpt

This repo contains an example implementation of [kpt](https://kpt.dev/) as [ArgoCD](https://argo-cd.readthedocs.io/en/stable/) configuration management plugin.

## The Concept

ArgoCD comes with a few configuration management tools build in. It is possible to configure your own CMP (configuration management plugin).

The basic idea is that ArgoCD will not sync raw manifests directly to the cluster but invoke one of the included tools or user provided CMPs to obtain the final yaml manifests that should be synced to the cluster. For example, one could use helm to render a chart using the `helm template` command.

Kpt is a tool to manage so called packages, which are collections of kubernetes manifests. The goal of this project is to integrate kpt as CMP such that it will produce the yaml manifests and have ArgoCD sync them to the cluster.

There are a few challenges which come along with this. This repo aims to provide only exemplary solutions to those, with room for improvement, for Nephio Context.

The first challenge is to use kpt to output the final manifests instead of relying on its `live` mechanism. This is because ArgoCD should decide wether the cluster state is in sync with the produced yaml or not. This can be solved
relatively easy by using its `unwrap` output option. Before outputting the manifests any local configs, including the `Kptfile` itself, are removed using the [remove-local-config-resource-function](https://catalog.kpt.dev/remove-local-config-resources/v0.1/).

```bash
kpt fn eval --exec remove-local-config-resources-v0.1.0 --output unwrap
```

The second and greater challenge is actually the function management. This is because kpt usually works by running each function in container. This architecture is tricky to realize when running kpt as a CMP sidecar. The workaround presented here is to use `exec` instead of `image`, which allows to use local executables as functions. You can actually see an example of this in the below code snippet. However, this comes with a number of problems around the availability and versioning of the functions. These problems have been naively solved by including some common functions in the CMP image. That means kpt packages deployed in this fashion are limited in the functions and versions they can use. One can imagine more elaborate setups to spawn containers to run the functions, or fetch the executables on demand.

```dockerfile
COPY --from=gcr.io/kpt-dev/kpt:v1.0.0-beta.21 /usr/local/bin/kpt /usr/local/bin/kpt
COPY --from=gcr.io/kpt-fn/remove-local-config-resources:v0.1.0 /usr/local/bin/function /usr/local/bin/remove-local-config-resources-v0.1.0
COPY --from=gcr.io/kpt-fn/set-annotations:v0.1.4 /usr/local/bin/function /usr/local/bin/set-annotations-v0.1.4
```

## Hands On

In order to build the CMP we need a few ingredients:

- A container image containing kpt and common functions
- A plugin configuration
- A script to use as generate command
- A patch for the ArgoCD repo server to inject the CMP sidecar

### The Plugin Config

This configuration will be used by the `cmp-server` to register the plugin with `repo-server`. Every time the repo server finds a file matching the discovery criteria it will delegate the production of the final yaml manifests to the plugin.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ConfigManagementPlugin
metadata:
  name: kpt
spec:
  version: v1.0
  discover:
    fileName: Kptfile
  lockRepo: true
  generate:
    command:
      - cmp-generate
```

### The Generate Script

This script will run inside the configured [argo application path](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#applications) every time ArgoCD detects changes to the upstream repository. It will use kpt to emit the desired kubernetes manifests and let ArgoCD decide what and how it should be synced.

You may notice this hackish `find + sed` combination. This is to replace all `image` references in all `Ktpfiles` with `exec` references so that the local binaries included in the image will be used, when issuing the `kpt fn render --allow-exec` command.

Finally, in order to rely on upstream kpt package, the script will run `kpt pkg update` to fetch upstream package to ArgoCD can properly apply the expected manifests.

```bash
#!/bin/bash

set -euo pipefail

# the prefix is used to annotate the resources with
# the argocd build environment
: "${ANNOTATION_DOMAIN:=argocd.my-org.io}"

# replace all image refs with exec refs, in Ktptfile pipelines
# this could be more solid, perhaps writing a custom fn to exec ;)
find . -name Kptfile -print0 |
    xargs -0 --no-run-if-empty \
        sed --in-place -E 's|image:.+/(.+):(.+)|exec: \1-\2|'

# fetch the upstream packages if any
if [[ "$(yq '.upstream' Kptfile)" != "null" ]] ; then
    kpt pkg update
fi

# render the configuration with the Kptfile pipelines
kpt fn render --allow-exec

# Set annotations from the argocd environment
kpt fn eval --exec set-annotations-v0.1.4 -- \
    "$ANNOTATION_DOMAIN/app=$ARGOCD_APP_NAME" \
    "$ANNOTATION_DOMAIN/rev=$ARGOCD_APP_REVISION" \
    "$ANNOTATION_DOMAIN/repo=$ARGOCD_APP_SOURCE_REPO_URL" \
    "$ANNOTATION_DOMAIN/branch=$ARGOCD_APP_SOURCE_TARGET_REVISION" \
    "$ANNOTATION_DOMAIN/path=$ARGOCD_APP_SOURCE_PATH"

# Lastly, emit the final config by using the remove-local-config-resources
# function which strips all local configs including Kpt files, from the output
kpt fn eval --exec remove-local-config-resources-v0.1.0 --output unwrap
```

### The Dockerfile

It is crucial to create a user with the id 999 since that is the user id inside the ArgoCD repo server. This is very important because the entrypoint of the sidecar will be ultimately the mounted `argocd-cmp-server` binary which listens on a socket. This socket will be accessible for the repo server through a shared volume. In order for the two programs to communicate, the repo server must have write permission on the socket. This is ensured by using the same uid 999. This will make more sense further down, when we get to the patch.

Also, for the time being, the Dockerfile will fetch all the various kpt function currently required for Nephio installation, and add them as binary within the container so they can be used for kpt pipeline execution.

```dockerfile
FROM alpine

# git is required by kpt and bash is used to have
# a more solid script since pipefail is available
RUN apk --no-cache add git bash yq

# its important to use the id 999 since the argocd repo server user will write
# to the the socker file created by the mounted entrypoint
RUN adduser --system --disabled-password --gecos "" --shell /bin/bash --uid 999 argocd

# add the kpt binary wich is the core piece of this cpm as  well a some functions.
COPY --from=gcr.io/kpt-dev/kpt:v1.0.0-beta.43 /usr/local/bin/kpt /usr/local/bin/kpt

# add some other functions that you want to use

# remove-local-config-resources is required to make it all work since it allows to purge local configs.
COPY --from=gcr.io/kpt-fn/remove-local-config-resources:v0.1.0 /usr/local/bin/function /usr/local/bin/remove-local-config-resources-v0.1.0
# set-annotations is used to annotate the rendered config with the argocd app name and environment
COPY --from=gcr.io/kpt-fn/set-annotations:v0.1.4 /usr/local/bin/function /usr/local/bin/set-annotations-v0.1.4
COPY --from=gcr.io/kpt-fn/set-image:v0.1.1 /usr/local/bin/function /usr/local/bin/set-image-v0.1.1
COPY --from=gcr.io/kpt-fn/set-labels:v0.2.0 /usr/local/bin/function /usr/local/bin/set-labels-v0.2.0
COPY --from=gcr.io/kpt-fn/starlark:v0.4.3 /usr/local/bin/function /usr/local/bin/starlark-v0.4.3
COPY --from=gcr.io/kpt-fn/apply-replacements:v0.1.1 /usr/local/bin/function /usr/local/bin/apply-replacements-v0.1.1
COPY --from=gcr.io/kpt-fn/search-replace:v0.2.0 /usr/local/bin/function /usr/local/bin/search-replace-v0.2.0

# the plugin definition can also be mounted from a config map, if preffered
COPY plugin.yaml /home/argocd/cmp-server/config/plugin.yaml

# the generate script is executed to render the kubernetes manifests
# as defined in the plugin.yaml
COPY --chmod=755 generate.sh /usr/local/bin/cmp-generate

WORKDIR /home/argocd
USER 999
ENTRYPOINT ["/bin/bash"]
```

### The Patch

This patch injects the CMP container as sidecar to the ArgoCD repo server. It mounts the `var-files` volume which is already in the `argocd-repo-server` pod spec. Through this shared volume the entrypoint `/var/run/argocd/argocd-cmp-server` is available. And the socket created by the entrypoint will be created in this volume so that the repo server can communicate with the CMP server.

The CMP server does all the heavy lifting of sending the yaml back and forth and invoking our plugin in the right directory. So our plugin only cares about dealing with the current path containing a `Kptfile`.

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: ArgoCD
metadata:
  name: openshift-gitops
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/sync-options: ServerSideApply=true
spec:
  repo:
    volumes:
      - name: kpt-cache
        emptyDir: {}
      - name: cmp-tmp
        emptyDir: {}
      - name: kustomize
        emptyDir: {}
    sidecarContainers:
      - command:
          - /var/run/argocd/argocd-cmp-server
        image: quay.io/adetalho/argocd-ktp-nephio-cmd:0.0.1
        imagePullPolicy: Always
        name: cmp-kpt
        resources:
          limits:
            cpu: 2
            memory: 1Gi
          requests:
            cpu: 1
            memory: 512Mi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
              - ALL
          readOnlyRootFilesystem: true
        volumeMounts:
          - mountPath: /var/run/argocd
            name: var-files
          - mountPath: /home/argocd/cmp-server/plugins
            name: plugins
          - mountPath: /tmp
            name: cmp-tmp
          - mountPath: /.kpt
            name: kpt-cache
```
