#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Unlike the setup scripts, this one skips instead of failing. It is a
# SessionStart hook, so a non-zero exit would surface an error at the start of
# every session, and the things it configures (the mise environment, the Maven
# settings) are meaningless anywhere else. claude/setup.sh only installs the hook
# inside the environment, so in practice this never trips.
if [[ "${X_ENVIRONMENT_MINE:-}" != "1" ]]; then
    echo "session-start.sh: not the Claude Code web environment, skipping."
    exit 0
fi

cd "${CLAUDE_PROJECT_DIR}"

# mise ignores idiomatic version files (.python-version, .nvmrc, ...) unless the
# tool is opted in, so a repo that pins its interpreter only that way gets
# nothing installed. Enable exactly the tools this project actually pins.
idiomatic_tools=()
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

# Always use the precompiled CPython builds from astral-sh/python-build-standalone
# (GitHub release assets, which the environment allows by default) instead of
# compiling from source. The compile path pulls CPython tarballs from
# www.python.org via a `git clone` of pyenv, and this environment's GitHub proxy
# 403s that clone, so it can only ever fail -- better to fail loudly here than
# to have `mise install python` silently fall back to it. See
# network/allowed-domains/mise.txt.
export MISE_PYTHON_COMPILE=false

if [[ ${#idiomatic_tools[@]} -gt 0 ]]; then
    MISE_IDIOMATIC_VERSION_FILE_ENABLE_TOOLS="$(
        IFS=,
        echo "${idiomatic_tools[*]}"
    )"
    export MISE_IDIOMATIC_VERSION_FILE_ENABLE_TOOLS
fi

mise install

{
    mise env --shell bash
    # Keep the precompiled-Python pin for later `mise` calls in the session
    echo "export MISE_PYTHON_COMPILE=false"
    # Keep the opt-in for later `mise` calls in the session, not just this hook
    if [[ -n "${MISE_IDIOMATIC_VERSION_FILE_ENABLE_TOOLS:-}" ]]; then
        echo "export MISE_IDIOMATIC_VERSION_FILE_ENABLE_TOOLS=\"${MISE_IDIOMATIC_VERSION_FILE_ENABLE_TOOLS}\""
    fi
    # Single-threaded artifact download avoids parallel 407s through the proxy
    echo "export MAVEN_ARGS=\"\${MAVEN_ARGS:+\$MAVEN_ARGS }--batch-mode  --no-transfer-progress --define maven.artifact.threads=1 --threads 1\""
    echo "export JAVA_TOOL_OPTIONS=\"\${JAVA_TOOL_OPTIONS:+\$JAVA_TOOL_OPTIONS }-Djavax.net.ssl.trustStore=/etc/ssl/certs/java/cacerts\""
} >> "${CLAUDE_ENV_FILE}"

# shellcheck disable=SC1090
source "${CLAUDE_ENV_FILE}"

echo "Configuring Maven..."
python3 "${HOME}/arlo-setup/claude/configure-maven.py"

# Nothing starts dockerd in this environment, so Testcontainers has no Docker to
# find. Invoked with `bash` rather than executed, so it works even if the
# tarball loses the mode bit.
bash "${HOME}/arlo-setup/claude/docker.sh"
