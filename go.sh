#!/bin/sh

set -o errexit
set -o nounset
set -o xtrace

cat /etc/os-release
set

wget --version
curl --version

git clone \
    --depth=1 \
    --single-branch \
    --no-tags \
    https://github.com/ArloL/claude-code-web-environment-setup.git \
    "${HOME}/arlo-setup"

sh "${HOME}/arlo-setup/setup.sh"
