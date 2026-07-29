#!/bin/bash
#
# Run a command behind hostlog-proxy.py and report which hosts it contacted.
#
# Discover the hosts a tool needs:
#
#     network/discover.sh -- npx playwright install chromium
#
# Prove a candidate allowed-domains list is complete (unlisted hosts get a 503,
# the same way the real environment rejects them):
#
#     network/discover.sh --allow-file <(network/build-allowed-domains.py --effective) \
#         -- npx playwright install chromium
#
# Exits non-zero if any host was blocked, so this works as a CI check.

set -o errexit
set -o nounset
set -o pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"

output=""
allow_file=""
repeat=1

usage() {
    cat <<'EOF'
Usage: discover.sh [--output FILE] [--allow-file FILE] [--repeat N]
                   -- COMMAND [ARGS...]

  --output FILE      write the sorted list of contacted hosts to FILE
  --allow-file FILE  only tunnel hosts on this list; others get a 503
  --repeat N         run the command N times and report the union of hosts,
                     flagging any that did not appear on every run

--repeat detects host rotation; it cannot prove a list is complete. A tool that
shuffles a mirror list touches one arbitrary host per run, so sampling it is
hopeless -- mise's zig backend draws from 16 mirrors, and seeing them all would
take dozens of runs. Derive those from upstream instead (see refresh-sources.sh)
and use --repeat to find out whether a tool rotates at all.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --output)
        output="$2"
        shift 2
        ;;
    --allow-file)
        allow_file="$2"
        shift 2
        ;;
    --repeat)
        repeat="$2"
        if ! [[ "${repeat}" =~ ^[1-9][0-9]*$ ]]; then
            echo "discover.sh: --repeat needs a positive integer" >&2
            exit 2
        fi
        shift 2
        ;;
    --help)
        usage
        exit 0
        ;;
    --)
        shift
        break
        ;;
    *)
        echo "discover.sh: unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
done

if [[ $# -eq 0 ]]; then
    echo "discover.sh: no command given" >&2
    usage >&2
    exit 2
fi

command=("$@")

work_dir="$(mktemp -d)"
hosts_file="${output:-${work_dir}/hosts.txt}"
proxy_pid=""

# Invoked indirectly by the EXIT trap below. Which code fires for that
# depends on the shellcheck version -- SC2329 on the function locally,
# SC2317 on the body in CI -- so silence both.
# shellcheck disable=SC2329,SC2317
cleanup() {
    if [[ -n "${proxy_pid}" ]] && kill -0 "${proxy_pid}" 2>/dev/null; then
        kill -TERM "${proxy_pid}" 2>/dev/null || true
        wait "${proxy_pid}" 2>/dev/null || true
    fi
    rm -rf "${work_dir}"
}
trap cleanup EXIT

# Set by run_once.
command_status=0
proxy_status=0

# Run the command once behind its own proxy, writing the hosts it contacted to
# $1. A fresh proxy per run is what makes per-run host sets available, which is
# what --repeat compares to detect rotation.
run_once() {
    local run_hosts="$1"
    local port_file="${work_dir}/port"
    rm -f "${port_file}"

    local proxy_args=(--port-file "${port_file}" --output "${run_hosts}")
    if [[ -n "${allow_file}" ]]; then
        proxy_args+=(--allow-file "${allow_file}")
    fi

    python3 "${script_dir}/hostlog-proxy.py" "${proxy_args[@]}" &
    proxy_pid=$!

    # Wait for the proxy to bind before pointing the command at it.
    local _
    for _ in $(seq 1 100); do
        [[ -s "${port_file}" ]] && break
        sleep 0.1
    done
    if [[ ! -s "${port_file}" ]]; then
        echo "discover.sh: proxy failed to start" >&2
        exit 1
    fi
    local proxy_url
    proxy_url="http://127.0.0.1:$(cat "${port_file}")"

    # Cover the spellings the common toolchains actually read. curl and most
    # libraries take the lowercase pair; Java, Maven and some Go tools take the
    # uppercase pair; npm and pip have their own settings that ignore both.
    export http_proxy="${proxy_url}"
    export https_proxy="${proxy_url}"
    export HTTP_PROXY="${proxy_url}"
    export HTTPS_PROXY="${proxy_url}"
    export ALL_PROXY="${proxy_url}"
    export npm_config_proxy="${proxy_url}"
    export npm_config_https_proxy="${proxy_url}"
    export PIP_PROXY="${proxy_url}"
    # Nothing here is local, so no bypass should hide a host from the log.
    export no_proxy=""
    export NO_PROXY=""

    set +o errexit
    "${command[@]}"
    command_status=$?
    set -o errexit

    kill -TERM "${proxy_pid}" 2>/dev/null || true
    # The proxy exits non-zero when it blocked at least one host.
    set +o errexit
    wait "${proxy_pid}"
    proxy_status=$?
    set -o errexit
    proxy_pid=""
}

worst_command_status=0
any_blocked=0
run_host_files=()

for run in $(seq 1 "${repeat}"); do
    if [[ "${repeat}" -gt 1 ]]; then
        echo "=== run ${run}/${repeat} ==="
    fi
    run_hosts="${work_dir}/hosts-${run}.txt"
    run_host_files+=("${run_hosts}")
    run_once "${run_hosts}"
    if [[ "${command_status}" -ne 0 && "${worst_command_status}" -eq 0 ]]; then
        worst_command_status="${command_status}"
    fi
    if [[ "${proxy_status}" -ne 0 ]]; then
        any_blocked=1
    fi
done

cat "${run_host_files[@]}" 2>/dev/null | sort --unique > "${hosts_file}"

echo
if [[ "${repeat}" -gt 1 ]]; then
    echo "=== hosts contacted across ${repeat} runs of: ${command[*]} ==="
else
    echo "=== hosts contacted by: ${command[*]} ==="
fi
if [[ -s "${hosts_file}" ]]; then
    cat "${hosts_file}"
else
    echo "(none -- did the command honour the proxy environment variables?)"
fi

# A host that shows up on some runs but not others means the tool rotates, so a
# list built from a single run is incomplete by construction. Say so rather than
# leaving it to be inferred from a diff of the output.
if [[ "${repeat}" -gt 1 ]]; then
    rotating=()
    while read -r host; do
        for run_hosts in "${run_host_files[@]}"; do
            if ! grep --quiet --line-regexp --fixed-strings "${host}" \
                "${run_hosts}" 2>/dev/null; then
                rotating+=("${host}")
                break
            fi
        done
    done < "${hosts_file}"
    if [[ "${#rotating[@]}" -gt 0 ]]; then
        echo
        echo "=== ROTATING: not contacted on every run ==="
        printf '%s\n' "${rotating[@]}"
        echo "This tool picks hosts at runtime, so no number of runs proves the"
        echo "list is complete. Derive these from upstream instead -- see"
        echo "network/refresh-sources.sh."
    fi
fi
echo "=== command exit status: ${worst_command_status} ==="

# A blocked host fails the run even when the command itself succeeded: a tool
# that falls back to a second mirror still exposes a gap in the allowlist, and
# that gap is the whole point of running this.
if [[ "${any_blocked}" -ne 0 ]]; then
    echo "=== FAIL: at least one host was blocked by the allowlist ==="
    exit 1
fi

exit "${worst_command_status}"
