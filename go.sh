#!/bin/sh

set -o errexit
set -o nounset
set -o xtrace

cat /etc/os-release
set

wget --version
curl --version

# Do NOT `git clone` here. In the Claude Code web environment git is
# reconfigured to route github.com through a scope-enforcing proxy that only
# serves repositories granted to the session, so cloning this setup repo fails
# with HTTP 403 (git exit 128). Fetch a tarball over plain HTTPS instead, which
# goes through the normal egress proxy. Requires codeload.github.com to be in
# the environment's allowed domains.
mkdir -p "${HOME}/arlo-setup"
curl -fsSL \
    https://codeload.github.com/ArloL/claude-code-web-environment-setup/tar.gz/refs/heads/main \
    | tar -xz --strip-components=1 -C "${HOME}/arlo-setup"

sh "${HOME}/arlo-setup/setup.sh"
