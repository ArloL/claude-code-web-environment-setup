#!/bin/sh
#
# Install my dotfiles' Claude Code skills into ~/.claude/skills, at user scope,
# so they are available in every project.
#
# ArloL/dotfiles keeps them under claude/skills/, and only install-macos.sh
# links that directory into ~/.claude -- install-linux.sh links settings.json
# and CLAUDE.md and stops there. Without this they exist on one machine.
#
# Like everything else here this runs when the image is built, so the skills are
# pinned to whatever `main` was at that moment.

set -o errexit
set -o nounset
set -o xtrace

# shellcheck source=SCRIPTDIR/../assert-environment.sh
. "$(dirname "$0")/../assert-environment.sh"

dotfiles_dir="${HOME}/arlo-dotfiles"

# Do NOT `git clone` github.com here; go.sh documents why. Fetch a tarball over
# plain HTTPS instead, as claude/plugins.sh does. codeload.github.com is in
# Anthropic's default domain list, so this needs no entry in
# network/allowed-domains/ -- but it enforces the session's repository scope, so
# this URL answers 403 anywhere except during the image build.
tarball="$(mktemp)"
curl --fail --silent --show-error --location \
    https://codeload.github.com/ArloL/dotfiles/tar.gz/refs/heads/main \
    --output "${tarball}"
# Extract into an empty directory: tar leaves behind files a newer revision has
# deleted, and a deleted skill would keep being installed.
rm -rf "${dotfiles_dir}"
mkdir -p "${dotfiles_dir}"
tar --extract --gzip --file "${tarball}" \
    --strip-components=1 --directory "${dotfiles_dir}"
rm -f "${tarball}"

skills_src="${dotfiles_dir}/claude/skills"
if [ ! -d "${skills_src}" ]; then
    echo "skills.sh: ${skills_src} is missing -- did the dotfiles move it?" >&2
    exit 1
fi

# One directory at a time, never the whole of ~/.claude/skills. Unlike
# ~/.claude/settings.json, which claude/setup.sh overwrites wholesale, that
# directory is not ours: the image ships `session-start-hook` in it, and
# `synced/` holds the skills Claude Code syncs down from my account.
mkdir -p "${HOME}/.claude/skills"

installed=0
for skill in "${skills_src}"/*/; do
    # An unmatched glob arrives as the literal pattern.
    [ -d "${skill}" ] || continue
    name="$(basename "${skill}")"
    rm -rf "${HOME}/.claude/skills/${name}"
    cp -R "${skill}" "${HOME}/.claude/skills/${name}"
    installed=$((installed + 1))
done

if [ "${installed}" -eq 0 ]; then
    echo "skills.sh: no skills found in ${skills_src}." >&2
    exit 1
fi
