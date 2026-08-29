#!/bin/sh

set -o errexit
set -o nounset
set -o xtrace

# Inlined rather than sourcing assert-environment.sh: this script is fetched
# with curl and piped to a shell, so the repo does not exist yet. Keep it in
# step with assert-environment.sh.
if [ "${X_ENVIRONMENT_MINE:-}" != "1" ]; then
    echo "go.sh: refusing to run: X_ENVIRONMENT_MINE is not set to 1." >&2
    echo "go.sh: this script is only for the Claude Code web environment --" >&2
    echo "go.sh: it installs tools into \$HOME and overwrites" >&2
    echo "go.sh: ~/.claude/settings.json." >&2
    exit 1
fi

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
curl --fail --silent --show-error --location \
    https://codeload.github.com/ArloL/claude-code-web-environment-setup/tar.gz/refs/heads/main \
    --output "${HOME}/arlo-setup.tgz"
tar --extract --gzip --file "${HOME}/arlo-setup.tgz" \
    --strip-components=1 --directory "${HOME}/arlo-setup"

sh "${HOME}/arlo-setup/setup.sh"
