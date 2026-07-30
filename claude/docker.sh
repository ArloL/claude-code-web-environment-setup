#!/bin/bash
#
# Start the Docker daemon, so Testcontainers works.
#
# The environment ships the entire Docker stack -- the CLI, dockerd, containerd,
# runc, even /lib/systemd/system/docker.service -- but PID 1 is the session
# supervisor rather than systemd, so nothing ever starts the daemon.
# /var/run/docker.sock is simply absent, and Testcontainers reports that as
# "Could not find a valid Docker environment", which reads like Docker is not
# installed rather than like a service nobody launched.
#
# Deliberately no proxy or CA configuration. Egress here is intercepted
# transparently: an allowed host answers normally on a direct connection and a
# blocked one answers 403 whether or not HTTPS_PROXY is used, so dockerd needs
# neither the proxy nor the CA bundle. Verified by running dockerd with the
# proxy variables unset and getting byte-identical pull behaviour. Passing the
# proxy in would in fact be the riskier choice, since dockerd would inherit
# HTTP_PROXY too and this proxy answers plain-HTTP requests with 405.
#
# Pulls still obey the environment's allowed-domains list. Docker Hub needs one
# host that is not in Anthropic's defaults -- see
# network/allowed-domains/docker.txt.
#
# Never fails the session. This runs from the SessionStart hook, where a
# non-zero exit would put an error at the top of every session, and a project
# that does not use containers should not care that the daemon did not come up.
# Hence no `errexit` and the unconditional `exit 0` at the end.

set -o nounset
set -o pipefail

say() {
    echo "docker.sh: $*"
}

if ! command -v dockerd > /dev/null 2>&1; then
    say "no dockerd in this image, skipping."
    exit 0
fi

# Also the path taken on a workstation, where Docker Desktop is already up --
# which is why this script needs no assert-environment.sh guard: it starts a
# daemon rather than touching $HOME, and where a daemon is already running it
# does nothing at all.
if docker info > /dev/null 2>&1; then
    say "daemon already running."
    exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
    say "not root, cannot start dockerd; skipping."
    exit 0
fi

log_file="${TMPDIR:-/tmp}/dockerd.log"
say "starting dockerd (log: ${log_file})"

# setsid so the daemon outlives this hook: the container work happens later in
# the session, long after the SessionStart process group is gone.
setsid dockerd > "${log_file}" 2>&1 < /dev/null &

# Poll rather than sleep a fixed amount. Testcontainers may be the very next
# thing that runs, so returning before the socket accepts connections would just
# move the failure.
for _ in $(seq 1 60); do
    if docker info > /dev/null 2>&1; then
        say "daemon ready."
        exit 0
    fi
    sleep 1
done

say "daemon did not come up within 60s; last lines of ${log_file}:" >&2
tail -n 20 "${log_file}" >&2 || true
exit 0
