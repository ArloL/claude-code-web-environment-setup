#!/bin/sh

set -o errexit
set -o nounset
set -o xtrace

cat /etc/os-release
set

wget --version
curl --version

mkdir --parents ~/.local/bin

# mise

# renovate: datasource=github-releases depName=jdx/mise
MISE_VERSION=2026.4.7
export MISE_VERSION

curl https://mise.run/bash | sh
