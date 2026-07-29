# Claude Code on the web Environment Setup

This sets up the Claude Code on the web environment the way I like it.

# Quickstart

Create a new cloud environment:

1. Name: Mine
2. Network access: Custom
3. Check **Also include default list of common package managers**. Everything
   Anthropic already trusts — npm, PyPI, Maven Central, the GitHub asset hosts,
   the Ubuntu apt mirrors — then needs no entry of its own. See
   [network/README.md](network/README.md).
4. Allowed domains — generated from [network/allowed-domains/](network/allowed-domains/),
   where every host is annotated with what needs it and how to re-derive it:
    <!-- BEGIN generated allowed-domains -->
    ```
    *.jdx.dev
    archive.mozilla.org
    download-installer.cdn.mozilla.net
    download.mozilla.org
    download.zigmirror.com
    fs.liujiacai.net
    jitpack.io
    mise.run
    pkg.earth
    pkg.hexops.org
    product-details.mozilla.org
    zig-mirror.tsimnet.eu
    zig.bcr.ist
    zig.chainsafe.dev
    zig.karearl.com
    zig.linus.dev
    zig.mirror.mschae23.de
    zig.savalione.com
    zig.squirl.dev
    zig.tilok.dev
    zig.vortan.dev
    ziglang.freetls.fastly.net
    ziglang.org
    zigmirror.com
    zigmirror.hryx.net
    ```
    <!-- END generated allowed-domains -->
5. Environment variables:
    ```
    X_ENVIRONMENT_MINE=1
    ```
6. Setup script:
    ```
    #!/bin/bash
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ArloL/claude-code-web-environment-setup/HEAD/go.sh)"
    ```

# Network access

The allowed-domains list is generated, not hand-edited. Adding a host means
recording *why* it is needed and *where* that can be re-checked, so the list
stays reviewable as it grows:

```sh
# Find out which hosts a tool actually needs
network/discover.sh -- npx playwright install chromium

# Prove the committed list is sufficient (unlisted hosts get a 503)
network/discover.sh --allow-file <(network/build-allowed-domains.py --effective) \
    -- npx playwright install chromium

# Pull upstream lists (Anthropic's defaults, Zig's mirrors) and re-render README
sh network/refresh-sources.sh
```

[network/README.md](network/README.md) has the details.
