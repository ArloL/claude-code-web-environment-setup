# Claude Code on the web Environment Setup

This sets up the Claude Code on the web environment the way I like it.

# Quickstart

Create a new cloud environment:

1. Name: Mine
2. Network access: Custom
3. Allowed domains:
    ```
    fs.liujiacai.netbuilds
    pkg.earth
    pkg.hexops.org
    zig-mirror.tsimnet.eu
    zig.chainsafe.dev
    zig.karearl.com
    zig.linus.dev
    zig.mirror.mschae23.de
    zig.savalione.com
    zig.squirl.dev
    zig.tilok.dev
    ziglang.freetls.fastly.net
    ziglang.org
    zigmirror.com
    zigmirror.hryx.net
    ```
4. Environment variables:
    ```
    X_ENVIRONMENT_MINE=1
    ```
5. Setup script:
    ```
    #!/bin/bash
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ArloL/claude-code-web-environment-setup/HEAD/go.sh)"
    ```
