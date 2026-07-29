#!/bin/bash
#
# Check that the host-discovery tooling itself works.
#
#     sh network/self-test.sh
#
# The tooling's whole value is that `discover.sh --allow-file` exits non-zero
# when a host is missing from the allowlist. A proxy that quietly allowed
# everything would still pass every allowlist it was given, so that behaviour
# needs its own test.
#
# Hermetic: serves plain HTTP from localhost for the allow case, and relies on
# the proxy rejecting a blocked host before it resolves or connects to anything
# for the block case. No internet access required.

set -o errexit
set -o nounset

script_dir="$(cd "$(dirname "$0")" && pwd)"
work_dir="$(mktemp -d)"
server_pid=""

# shellcheck disable=SC2329,SC2317  # invoked indirectly by the EXIT trap
cleanup() {
    if [[ -n "${server_pid}" ]] && kill -0 "${server_pid}" 2>/dev/null; then
        kill -TERM "${server_pid}" 2>/dev/null || true
        wait "${server_pid}" 2>/dev/null || true
    fi
    rm -rf "${work_dir}"
}
trap cleanup EXIT

failures=0

check() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        echo "ok   - ${name}"
    else
        echo "FAIL - ${name}: expected ${expected}, got ${actual}"
        failures=$((failures + 1))
    fi
}

# A local origin server, so the allow case needs no internet access.
echo "hello" > "${work_dir}/index.html"
# -u: the "Serving HTTP on ... port NNNNN" line is buffered otherwise, and the
# port is parsed out of it below.
python3 -u -m http.server 0 \
    --bind 127.0.0.1 \
    --directory "${work_dir}" \
    > "${work_dir}/server.log" 2>&1 &
server_pid=$!

origin_port=""
for _ in $(seq 1 100); do
    # python -m http.server logs "Serving HTTP on 127.0.0.1 port NNNNN ..."
    origin_port="$(sed -n 's/.*port \([0-9]\{1,\}\).*/\1/p' "${work_dir}/server.log" | head -1)"
    [[ -n "${origin_port}" ]] && break
    sleep 0.1
done
if [[ -z "${origin_port}" ]]; then
    echo "FAIL - could not start the local origin server"
    cat "${work_dir}/server.log"
    exit 1
fi

# --- an allowed host is tunnelled, and recorded -----------------------------
printf '127.0.0.1\n# comments and blank lines are ignored\n\n' \
    > "${work_dir}/allow-localhost.txt"
set +o errexit
"${script_dir}/discover.sh" \
    --allow-file "${work_dir}/allow-localhost.txt" \
    --output "${work_dir}/allowed-hosts.txt" \
    -- curl --silent --fail --max-time 20 --output /dev/null \
        "http://127.0.0.1:${origin_port}/index.html" \
    > "${work_dir}/allowed.log" 2>&1
check "an allowed host succeeds" 0 $?
set -o errexit
check "the allowed host is recorded" "127.0.0.1" "$(cat "${work_dir}/allowed-hosts.txt")"

# --- a host that is not on the list fails the run ---------------------------
# blocked.invalid is rejected by the proxy before any DNS lookup, so this stays
# hermetic and cannot pass by accident.
set +o errexit
"${script_dir}/discover.sh" \
    --allow-file "${work_dir}/allow-localhost.txt" \
    --output "${work_dir}/blocked-hosts.txt" \
    -- curl --silent --max-time 20 --output /dev/null \
        https://blocked.invalid/ \
    > "${work_dir}/blocked.log" 2>&1
check "a blocked host fails the run" 1 $?
set -o errexit
check "the blocked host is recorded" "blocked.invalid" \
    "$(cat "${work_dir}/blocked-hosts.txt")"

# --- the docs parser rejects a page it no longer understands -----------------
cat > "${work_dir}/docs-fixture.md" <<'EOF'
## Something else

* not-a-default.example.com

## Default allowed domains

<AccordionGroup>
  <Accordion title="Group">
    * api.anthropic.com
    * \*.gcr.io
    * raw\.githubusercontent.com
    * [www.github.com](http://www.github.com)
    * packagist.org (PHP Composer)
  </Accordion>
</AccordionGroup>

## Related resources

* also-not-a-default.example.com
EOF
expected_defaults="*.gcr.io
api.anthropic.com
packagist.org
raw.githubusercontent.com
www.github.com"
check "the docs parser handles escaping, links and annotations" \
    "${expected_defaults}" \
    "$(python3 "${script_dir}/extract-claude-defaults.py" < "${work_dir}/docs-fixture.md")"

set +o errexit
echo "## No such heading" | python3 "${script_dir}/extract-claude-defaults.py" \
    > /dev/null 2>&1
check "the docs parser fails loudly when the layout changes" 1 $?
set -o errexit

# --- the renderer refuses a wildcard entry -----------------------------------
# The docs promise a leading `*.` matches every subdomain, but the environment
# did not honour it for an entry pasted into the field: mise.jdx.dev came back
# 503 with `*.jdx.dev` on the list. A wildcard slipping back into
# allowed-domains/ has to fail here rather than mid-session.
mkdir -p "${work_dir}/wildcard-domains"
echo '*.jdx.dev' > "${work_dir}/wildcard-domains/mise.txt"
set +o errexit
python3 - "${script_dir}" "${work_dir}/wildcard-domains" > /dev/null 2>&1 <<'EOF'
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location(
    "build_allowed_domains", pathlib.Path(sys.argv[1]) / "build-allowed-domains.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.DOMAINS_DIR = pathlib.Path(sys.argv[2])
module.collect_domains()
EOF
check "the renderer refuses a wildcard entry" 1 $?
set -o errexit

echo
if [[ "${failures}" -gt 0 ]]; then
    echo "${failures} check(s) failed"
    exit 1
fi
echo "all checks passed"
