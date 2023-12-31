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
COPY --from=gcr.io/kpt-fn/apply-setters:v0.2.0 /usr/local/bin/function /usr/local/bin/apply-setters-v0.2.0

# the plugin definition can also be mounted from a config map, if preffered
COPY plugin.yaml /home/argocd/cmp-server/config/plugin.yaml

# the generate script is executed to render the kubernetes manifests
# as defined in the plugin.yaml
COPY --chmod=755 generate.sh /usr/local/bin/cmp-generate

WORKDIR /home/argocd
USER 999
ENTRYPOINT ["/bin/bash"]
