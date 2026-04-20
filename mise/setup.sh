#!/bin/sh

set -o errexit
set -o nounset
set -o xtrace

# renovate: datasource=github-releases depName=jdx/mise
MISE_VERSION=2026.4.11
export MISE_VERSION

curl https://mise.run/bash | sh
