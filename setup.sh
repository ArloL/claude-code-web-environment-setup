#!/bin/sh

set -o errexit
set -o nounset
set -o xtrace

cd "$(dirname "$0")" || exit 1

sh mise/setup.sh
sh claude/setup.sh
