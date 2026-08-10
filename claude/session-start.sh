#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Unlike the setup scripts, being in the wrong place is a skip rather than a
# failure. It is a SessionStart hook, so a non-zero exit surfaces an error at the
# start of every session -- worth it for a step that really did fail, not for a
# machine where the things it configures (the mise environment, the Maven
# settings) are meaningless to begin with. claude/setup.sh only installs the hook
# inside the environment, so in practice this never trips.
if [[ "${X_ENVIRONMENT_MINE:-}" != "1" ]]; then
    echo "session-start.sh: not the Claude Code web environment, skipping."
    exit 0
fi

# Docker first, and before anything that can fail.
#
# dockerd dies with the container, so every session start has to put it back,
# and starting it needs nothing from the rest of this script. It used to run
# last, which meant `errexit` turned any earlier failure -- a `mise install` that
# could not reach a mirror, a missing CLAUDE_ENV_FILE -- into a session with no
# Docker. That failure then surfaced much later as "Could not find a valid Docker
# environment", which names neither the daemon nor the step that actually broke.
#
# Invoked with `bash` rather than executed, so it works even if the tarball loses
# the mode bit.
bash "${HOME}/arlo-setup/claude/docker.sh"

# From here on the steps are independent of one another, so a failing one
# reports and the rest still run. The exit code is held back to the end: the
# session is told about the failure, but only after everything that could still
# be configured has been.
failed_steps=()

step() {
    local label="$1"
    shift
    if "$@"; then
        return 0
    fi
    echo "session-start.sh: ${label} failed." >&2
    failed_steps+=("${label}")
}

setup_mise() {
    # mise ignores idiomatic version files (.python-version, .nvmrc, ...) unless
    # the tool is opted in, so a repo that pins its interpreter only that way
    # gets nothing installed. Enable exactly the tools this project actually
    # pins.
    local idiomatic_tools=()
    if [[ -f .python-version ]]; then
        idiomatic_tools+=(python)
    fi
    if [[ -f .node-version || -f .nvmrc ]]; then
        idiomatic_tools+=(node)
    fi
    if [[ -f .ruby-version ]]; then
        idiomatic_tools+=(ruby)
    fi
    if [[ -f .java-version ]]; then
        idiomatic_tools+=(java)
    fi
    if [[ -f .go-version ]]; then
        idiomatic_tools+=(go)
    fi

    if [[ ${#idiomatic_tools[@]} -gt 0 ]]; then
        MISE_IDIOMATIC_VERSION_FILE_ENABLE_TOOLS="$(
            IFS=,
            echo "${idiomatic_tools[*]}"
        )"
        export MISE_IDIOMATIC_VERSION_FILE_ENABLE_TOOLS
    fi

    mise install
}

# The env file is per session and survives a resume, so this appends to a file
# that may already hold what it is about to write.
write_session_env() {
    if [[ -z "${CLAUDE_ENV_FILE:-}" ]]; then
        echo "session-start.sh: CLAUDE_ENV_FILE is not set." >&2
        return 1
    fi

    {
        mise env --shell bash
        # Keep the precompiled-Python pin for later `mise` calls in the session
        echo "export MISE_PYTHON_COMPILE=false"
        # Keep the opt-in for later `mise` calls in the session, not just this hook
        if [[ -n "${MISE_IDIOMATIC_VERSION_FILE_ENABLE_TOOLS:-}" ]]; then
            echo "export MISE_IDIOMATIC_VERSION_FILE_ENABLE_TOOLS=\"${MISE_IDIOMATIC_VERSION_FILE_ENABLE_TOOLS}\""
        fi
        # Single-threaded artifact download avoids parallel 407s through the
        # proxy. Guarded rather than appended blindly: these two build on their
        # own previous value, so a second SessionStart in the same session -- a
        # resume, a compact -- would otherwise leave every Maven invocation
        # carrying the same flags twice. The quoted heredoc keeps the expansions
        # for the file rather than resolving them here.
        cat << 'ENV_FILE'
case "${MAVEN_ARGS:-}" in
    *"maven.artifact.threads=1"*) ;;
    *) export MAVEN_ARGS="${MAVEN_ARGS:+$MAVEN_ARGS }--batch-mode  --no-transfer-progress --define maven.artifact.threads=1 --threads 1" ;;
esac
case "${JAVA_TOOL_OPTIONS:-}" in
    *"/etc/ssl/certs/java/cacerts"*) ;;
    *) export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }-Djavax.net.ssl.trustStore=/etc/ssl/certs/java/cacerts" ;;
esac
ENV_FILE
    } >> "${CLAUDE_ENV_FILE}"

    # shellcheck disable=SC1090
    source "${CLAUDE_ENV_FILE}"
}

configure_maven() {
    echo "Configuring Maven..."
    python3 "${HOME}/arlo-setup/claude/configure-maven.py"
}

if [[ -z "${CLAUDE_PROJECT_DIR:-}" ]]; then
    echo "session-start.sh: CLAUDE_PROJECT_DIR is not set; skipping project setup." >&2
    exit 1
fi
cd "${CLAUDE_PROJECT_DIR}"

# Always use the precompiled CPython builds from astral-sh/python-build-standalone
# (GitHub release assets, which the environment allows by default) instead of
# compiling from source. The compile path pulls CPython tarballs from
# www.python.org via a `git clone` of pyenv, and this environment's GitHub proxy
# 403s that clone, so it can only ever fail -- better to fail loudly here than
# to have `mise install python` silently fall back to it. See
# network/allowed-domains/mise.txt.
export MISE_PYTHON_COMPILE=false

step "mise install" setup_mise
step "writing the session env file" write_session_env
step "Maven configuration" configure_maven

if [[ ${#failed_steps[@]} -gt 0 ]]; then
    echo "session-start.sh: failed steps: ${failed_steps[*]}" >&2
    exit 1
fi
