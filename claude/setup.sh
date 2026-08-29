#!/bin/sh

set -o errexit
set -o nounset
set -o xtrace

cd "$(dirname "$0")" || exit 1

# This is the script with the destructive side effect: the `cp` below replaces
# ~/.claude/settings.json outright.
# shellcheck source=SCRIPTDIR/../assert-environment.sh
. ../assert-environment.sh

mkdir -p "${HOME}/.claude"

cp settings.json "${HOME}/.claude/settings.json"

# After the copy, not before: the plugin commands write the marketplaces and the
# enabled plugins into that same settings.json.
sh plugins.sh
