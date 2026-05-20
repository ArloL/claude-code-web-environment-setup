#!/bin/sh

set -o errexit
set -o nounset
set -o xtrace

# renovate: datasource=github-releases depName=jdx/mise
MISE_VERSION=2026.5.6
export MISE_VERSION

curl https://mise.run/bash | sh
