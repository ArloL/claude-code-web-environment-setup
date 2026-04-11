#!/bin/sh

set -o errexit
set -o nounset
set -o xtrace

cd "$(dirname "$0")" || exit 1

mkdir --parents "${HOME}/.claude"

cp settings.json "${HOME}/.claude/settings.json"
