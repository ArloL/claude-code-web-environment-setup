#!/bin/sh
#
# Refuse to run outside the Claude Code web environment.
#
# Source this from any script that mutates $HOME:
#
#     . "$(dirname "$0")/assert-environment.sh"
#
# These scripts install mise into ~/.local/bin and overwrite
# ~/.claude/settings.json. That is exactly what a throwaway cloud VM wants and
# exactly what a workstation does not, and nothing about the scripts themselves
# makes the difference visible -- running setup.sh on a laptop looks like a
# reasonable thing to do right up until it replaces your Claude Code settings.
#
# X_ENVIRONMENT_MINE=1 is the one signal that distinguishes the two. The
# environment's setup script exports it before fetching go.sh, and the
# environment's variables set it for the session as well (see README.md) -- both
# are needed, because variables configured in the UI are only injected into the
# session, not into the setup script, which runs when the image is built. CI
# sets it deliberately in .github/workflows/pr-check.yaml. That is the point:
# running these scripts is an opt-in, never an accident.

if [ "${X_ENVIRONMENT_MINE:-}" != "1" ]; then
    echo "$0: refusing to run: X_ENVIRONMENT_MINE is not set to 1." >&2
    echo "$0: this script is only for the Claude Code web environment --" >&2
    echo "$0: it installs tools into \$HOME and overwrites" >&2
    echo "$0: ~/.claude/settings.json." >&2
    exit 1
fi
