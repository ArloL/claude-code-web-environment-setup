#!/bin/bash
#
# Check that the hosts we list can still be reached, and that reaching them
# needs nothing the allowed-domains list does not have.
#
#     network/check-reachable.sh [--probes FILE]
#
# Every entry in allowed-domains/ was true when it was written. What makes it
# rot is invisible from here: a host moves behind a CDN, an API endpoint is
# retired, a redirect grows a hop to a name nobody listed. In the environment
# that surfaces as a 503 in the middle of unrelated work, which is the failure
# this repo exists to stop being a debugging session.
#
# So each probe in probes.txt is fetched through hostlog-proxy in enforce mode,
# with the effective list (ours plus Anthropic's defaults) as the allowlist --
# the same treatment the environment gives it. A probe fails if the request
# fails, if it needs a host the list does not have, or if the set of hosts it
# contacted is not the set the probe declares.
#
# This needs real internet access, so it belongs on a CI runner rather than in
# pr-check.yaml's offline test job. It says nothing about whether the pasted
# Allowed domains field of an environment is up to date -- only the list in
# this repo is checked. See network/README.md.

set -o errexit
set -o nounset
set -o pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
probes_file="${script_dir}/probes.txt"

usage() {
    cat <<'EOF'
Usage: check-reachable.sh [--probes FILE]

  --probes FILE  probe list to run (default: network/probes.txt)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --probes)
        probes_file="$2"
        shift 2
        ;;
    --help)
        usage
        exit 0
        ;;
    *)
        echo "check-reachable.sh: unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
done

if [[ ! -f "${probes_file}" ]]; then
    echo "check-reachable.sh: no such probe file: ${probes_file}" >&2
    exit 2
fi

work_dir="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317  # invoked indirectly by the EXIT trap
cleanup() {
    rm -rf "${work_dir}"
}
trap cleanup EXIT

effective="${work_dir}/effective.txt"
python3 "${script_dir}/build-allowed-domains.py" --effective > "${effective}"

# Say who is calling. An unattributed default curl user agent is the kind of
# thing a site blocks without warning, and a monthly check that quietly starts
# failing on a 403 teaches nothing.
user_agent="claude-code-web-environment-setup network check (+https://github.com/ArloL/claude-code-web-environment-setup)"

host_of() {
    printf '%s\n' "$1" | sed 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||; s|/.*||; s|.*@||; s|:[0-9]*$||'
}

failures=0
probe_count=0

while read -r line; do
    line="${line%%#*}"
    # shellcheck disable=SC2206  # word splitting is the format: url then hosts
    fields=(${line})
    [[ "${#fields[@]}" -eq 0 ]] && continue

    url="${fields[0]}"
    expected=("${fields[@]:1}")
    if [[ "${#expected[@]}" -eq 0 ]]; then
        expected=("$(host_of "${url}")")
    fi
    probe_count=$((probe_count + 1))

    hosts_file="${work_dir}/hosts-${probe_count}.txt"
    log_file="${work_dir}/log-${probe_count}.txt"

    # --retry covers what curl calls transient -- 408, 429, the 5xx family,
    # a timeout, a refused connection -- which is how a live host still fails
    # a run. Deliberately not --retry-all-errors: that retries a 404 too, and
    # a retired endpoint is the finding here, not noise to be smoothed over.
    set +o errexit
    "${script_dir}/discover.sh" \
        --allow-file "${effective}" \
        --output "${hosts_file}" \
        -- curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --output /dev/null \
        --max-time 30 \
        --retry 2 \
        --retry-delay 2 \
        --retry-connrefused \
        --user-agent "${user_agent}" \
        "${url}" \
        > "${log_file}" 2>&1
    status=$?
    set -o errexit

    contacted=()
    if [[ -s "${hosts_file}" ]]; then
        while read -r host; do
            contacted+=("${host}")
        done < "${hosts_file}"
    fi

    expected_sorted="$(printf '%s\n' "${expected[@]}" | sort --unique)"
    contacted_sorted="$(printf '%s\n' "${contacted[@]+"${contacted[@]}"}" | sort --unique)"

    if [[ "${status}" -ne 0 ]]; then
        echo "FAIL - ${url}: the request failed (exit ${status})"
        sed 's/^/       /' "${log_file}"
        failures=$((failures + 1))
        continue
    fi

    if [[ "${expected_sorted}" != "${contacted_sorted}" ]]; then
        echo "FAIL - ${url}: contacted hosts differ from the probe"
        echo "       declared:  ${expected_sorted//$'\n'/ }"
        echo "       contacted: ${contacted_sorted//$'\n'/ }"
        echo "       Update probes.txt and allowed-domains/ together: a host"
        echo "       that appears here is a host the environment must allow."
        failures=$((failures + 1))
        continue
    fi

    echo "ok   - ${url} (${contacted_sorted//$'\n'/ })"
done < "${probes_file}"

echo
if [[ "${probe_count}" -eq 0 ]]; then
    echo "check-reachable: no probes in ${probes_file}" >&2
    exit 2
fi

if [[ "${failures}" -ne 0 ]]; then
    echo "${failures} of ${probe_count} probes failed"
    # Run inside a Claude Code environment, every probe for a host the pasted
    # Allowed domains field is missing fails as a 403 -- which reads exactly
    # like the host being down. Say which of the two is being looked at before
    # anyone goes to check whether Bugzilla is having an outage.
    if [[ -n "${HTTPS_PROXY:-}${https_proxy:-}" ]]; then
        echo
        echo "note: this shell has an HTTPS proxy configured, so it is probably"
        echo "      a Claude Code environment. A 403 there is the environment's"
        echo "      own gateway refusing a host its pasted Allowed domains field"
        echo "      does not have -- not evidence about the host. This check"
        echo "      belongs on a runner with unrestricted network access."
    fi
    exit 1
fi

echo "all ${probe_count} probes passed"
