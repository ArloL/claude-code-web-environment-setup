#!/bin/bash
#
# Make sure the Docker daemon is up before a shell command runs.
#
# claude/docker.sh starts dockerd from the SessionStart hook, which covers a
# session that opens in a fresh container. It does not cover everything:
#
#   - A resumed session gets a new container -- the old one is reclaimed, and
#     dockerd dies with it -- but the resume is not always a fresh SessionStart,
#     so the hook that would restart the daemon need not run again.
#   - A daemon that dies mid-session is never restarted, however the session
#     started.
#
# Both look identical from the inside: `docker` and Testcontainers report
# "Could not find a valid Docker environment" in a session whose startup output
# said "daemon ready" -- for a container that no longer exists.
#
# So this runs from a PreToolUse hook on Bash, where "is Docker there" is asked
# at the moment it matters instead of once at session start. Cheap enough to sit
# in front of every shell command: the common case is a single pgrep, and the
# expensive path -- waiting for a daemon to come up -- is taken at most once per
# boot for as long as it keeps failing, so an image where dockerd cannot start
# does not pay that wait on every command.

set -o nounset
set -o pipefail

# A PreToolUse hook decides whether the tool runs, and this one has no business
# blocking a shell command: Docker is a convenience here, not a precondition.
# The trap makes that true for every exit path, including an unexpected one.
trap 'exit 0' EXIT

daemon_running() {
    # Deliberately a process check rather than a test for /var/run/docker.sock.
    # The socket is a file, and a container that is reclaimed rather than shut
    # down leaves it behind -- so a resumed session can find a socket with no
    # daemon on the other end.
    pgrep -x dockerd > /dev/null 2>&1
}

if daemon_running; then
    exit 0
fi

# The boot id is the right key for "have we already tried": it changes when the
# container is replaced, which is precisely when the daemon has to be started
# again -- and since /tmp survives that replacement, a stamp file without it
# would suppress the one start that matters.
boot_id="$(cat /proc/sys/kernel/random/boot_id 2> /dev/null || echo unknown)"
stamp_file="${TMPDIR:-/tmp}/ensure-docker.failed-boot-id"

if [[ "$(cat "${stamp_file}" 2> /dev/null || true)" == "${boot_id}" ]]; then
    exit 0
fi

# Claude runs Bash calls in parallel, so several of these can arrive at once
# with no daemon up. Without the lock they would each start a dockerd and all
# but one would fail to bind the socket; with it, the others wait and find the
# daemon already running.
if command -v flock > /dev/null 2>&1; then
    if exec 9> "${TMPDIR:-/tmp}/ensure-docker.lock"; then
        # Bounded, and it proceeds either way: a lock that cannot be taken is a
        # reason to race, not a reason to leave the session without Docker.
        flock -w 90 9 || true
    fi
    if daemon_running; then
        exit 0
    fi
fi

# Shorter than the SessionStart wait, because a shell command is blocked behind
# this one. On stderr so it cannot be read as hook JSON on stdout.
#
# `9>&-` closes the lock file descriptor for this child, and dockerd is started
# from there and inherits whatever is left open. A daemon that inherits fd 9
# holds the lock for as long as it lives, which is the whole session -- so every
# later caller would block on a lock held by the very daemon it was waiting for.
DOCKER_WAIT_SECONDS="${DOCKER_WAIT_SECONDS:-30}" \
    bash "$(dirname "$0")/docker.sh" >&2 9>&-

# Record the attempt only when it failed. A daemon that dies later in the
# session deserves another start; an image where dockerd cannot come up at all
# must not make every shell command wait for it again. `docker info` rather than
# the process check, so a remote or Desktop daemon counts as success.
if ! docker info > /dev/null 2>&1; then
    printf '%s' "${boot_id}" > "${stamp_file}" 2> /dev/null || true
fi
