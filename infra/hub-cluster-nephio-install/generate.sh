#!/bin/bash

cd $1

set -euo pipefail

# fetch the upstream packages if any
if [[ "$(yq '.upstream' Kptfile)" != "null" ]] ; then
    kpt pkg update
fi

# render the configuration with the Kptfile pipelines

kpt fn render
kpt fn eval --image gcr.io/kpt-fn/remove-local-config-resources:v0.1.0
rm -rf *.md
