#!/bin/sh

set -o errexit
set -o nounset
set -o xtrace

# Each script guards itself rather than trusting its caller: they are all
# runnable on their own, and this one installs mise into ~/.local/bin.
# shellcheck source=SCRIPTDIR/../assert-environment.sh
. "$(dirname "$0")/../assert-environment.sh"

# renovate: datasource=github-releases depName=jdx/mise
MISE_VERSION=2026.8.5
export MISE_VERSION

# Download first, then run: a piped `curl ... | sh` would hide a failed
# download because dash's `sh` lacks `pipefail`, so the pipeline reports the
# (successful) `sh` exit code while mise never actually installs. Writing to a
# file lets `curl --fail` + `errexit` stop setup loudly on a blocked/failed
# download instead of failing later at `mise install`.
install_script="$(mktemp)"
trap 'rm -f "${install_script}"' EXIT
curl --fail --silent --show-error --location https://mise.run/bash \
    --output "${install_script}"
sh "${install_script}"
