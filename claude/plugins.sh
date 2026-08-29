#!/bin/sh
#
# Install the Claude Code plugins into ~/.claude, at user scope.
#
# Must run *after* claude/setup.sh has copied settings.json into place: the
# `claude plugin` commands record the marketplaces and the enabled plugins in
# that same file, so the copy would overwrite what they wrote.
#
# Like everything else here this runs when the image is built, so a plugin is
# pinned to whatever `main` was at that moment. Neither repository publishes a
# release the marketplace could track (vladikk/modularity has no tags at all),
# and rebuilding the environment is the update mechanism.

set -o errexit
set -o nounset
set -o xtrace

# shellcheck source=SCRIPTDIR/../assert-environment.sh
. "$(dirname "$0")/../assert-environment.sh"

if ! command -v claude > /dev/null 2>&1; then
    # The CI job runs the setup scripts on a bare runner, which has no claude
    # CLI and no ~/.claude to install into. Everything above this point still
    # gets exercised there; this step cannot be.
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        echo "plugins.sh: no claude CLI on the runner, skipping." >&2
        exit 0
    fi
    # In the environment itself, a missing CLI means the plugins silently would
    # not be there, so fail instead.
    echo "plugins.sh: refusing to continue: claude is not on PATH." >&2
    exit 1
fi

plugins_dir="${HOME}/arlo-plugins"
mkdir -p "${plugins_dir}"

# repo, directory name, plugin@marketplace.
#
# The marketplace name comes from the repository's .claude-plugin/marketplace.json
# and is not the repository name -- obra/superpowers calls itself
# `superpowers-dev`.
install_plugin() {
    plugin_repo="$1"
    plugin_dir="${plugins_dir}/$2"
    plugin_id="$3"
    marketplace_name="${plugin_id#*@}"

    # Do NOT use `claude plugin marketplace add <owner>/<repo>`. That path is a
    # `git clone` of github.com, and in this environment git is routed through a
    # scope-enforcing proxy that only serves repositories granted to the
    # session, so cloning somebody else's repo fails with HTTP 403. Fetch a
    # tarball over plain HTTPS instead and add the extracted directory as a
    # local marketplace, which is exactly what go.sh does for this repo.
    # codeload.github.com is in Anthropic's default domain list, so this needs
    # no entry in network/allowed-domains/.
    tarball="$(mktemp)"
    curl --fail --silent --show-error --location \
        "https://codeload.github.com/${plugin_repo}/tar.gz/refs/heads/main" \
        --output "${tarball}"
    # Extract into an empty directory: tar leaves files a newer revision has
    # deleted lying around, and the marketplace would still see them.
    rm -rf "${plugin_dir}"
    mkdir -p "${plugin_dir}"
    tar --extract --gzip --file "${tarball}" \
        --strip-components=1 --directory "${plugin_dir}"
    rm -f "${tarball}"

    # All four commands are no-ops when there is nothing to do, so a second run
    # of the setup -- the documented way to pick up repo changes in a session
    # that already exists -- refreshes the plugins instead of failing. The two
    # `update` calls are what make a re-run actually see the freshly extracted
    # revision; `add` and `install` alone report "already there" and leave the
    # previously cached copy in place.
    claude plugin marketplace add "${plugin_dir}"
    claude plugin marketplace update "${marketplace_name}"
    claude plugin install "${plugin_id}" --scope user --yes
    claude plugin update "${plugin_id}"
}

install_plugin obra/superpowers superpowers superpowers@superpowers-dev
install_plugin vladikk/modularity modularity modularity@vladikk-modularity
