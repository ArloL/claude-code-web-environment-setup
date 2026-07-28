#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

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

echo "Configuring Maven proxy..."
python3 "${HOME}/arlo-setup/claude/configure-maven-proxy.py"
