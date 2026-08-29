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
    archive.mozilla.org
    arlol.github.io
    bugzilla.mozilla.org
    cdn.playwright.dev
    developer.mozilla.org
    docs.zizmor.sh
    download-installer.cdn.mozilla.net
    download.mozilla.org
    download.zigmirror.com
    fs.liujiacai.net
    jitpack.io
    mise-java.jdx.dev
    mise-versions.jdx.dev
    mise.jdx.dev
    mise.run
    pkg.earth
    pkg.hexops.org
    playwright.download.prss.microsoft.com
    product-details.mozilla.org
    production.cloudfront.docker.com
    registry.terraform.io
    searchfox.org
    sonarcloud.io
    wiki.mozilla.org
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
   The scripts refuse to run without it. They install mise into `~/.local/bin`
   and overwrite `~/.claude/settings.json`, which is fine on a throwaway VM and
   not fine on a workstation, so running them is an explicit opt-in. See
   [assert-environment.sh](assert-environment.sh).

   These variables reach the *session*, which is what `claude/session-start.sh`
   needs. They are **not** in scope while the setup script runs -- that happens
   earlier, when the environment image is built -- so the setup script has to
   export the marker itself.
6. Setup script:
    ```
    #!/bin/bash
    export X_ENVIRONMENT_MINE=1
    /bin/bash -c "$(curl --fail --silent --show-error --location https://raw.githubusercontent.com/ArloL/claude-code-web-environment-setup/HEAD/go.sh)"
    ```
   The `export` is the opt-in the guard is looking for: it is inherited by
   `go.sh` and everything below it. Copying just the `curl` line onto a
   workstation still gets refused, which is the point.

The setup script runs when the environment image is built, and *only* then — a
later session boots straight past it ("Fast resume: Environment already
configured — Skipping initialization script for faster startup"). So an existing
environment keeps running whatever revision of this repo it was built against,
however long ago that was: `~/arlo-setup` is a snapshot, not a checkout. Changes
here reach an environment when it is rebuilt. To pick them up in a session
already running:

```sh
X_ENVIRONMENT_MINE=1 /bin/bash -c "$(curl --fail --silent --show-error --location https://raw.githubusercontent.com/ArloL/claude-code-web-environment-setup/HEAD/go.sh)"
```

# Claude Code plugins

[`claude/plugins.sh`](claude/plugins.sh) installs two plugins at user scope, so
they are available in every project:

| | |
| --- | --- |
| [obra/superpowers](https://github.com/obra/superpowers) | `superpowers@superpowers-dev` |
| [vladikk/modularity](https://github.com/vladikk/modularity) | `modularity@vladikk-modularity` |

The marketplace name is whatever the repository's `.claude-plugin/marketplace.json`
calls itself, which is not the repository name: `obra/superpowers` is the
`superpowers-dev` marketplace. `claude plugin list` shows what ended up
installed.

The obvious command, `claude plugin marketplace add obra/superpowers`, does not
work here. It is a `git clone` of github.com, and github.com goes through the
credential-swapping proxy that only serves repositories granted to the session,
so cloning somebody else's repository fails with HTTP 403 -- the same trap
[go.sh](go.sh) documents for this repo. So the script fetches a
`codeload.github.com` tarball, extracts it under `~/arlo-plugins/`, and adds
that directory as a local marketplace. `codeload.github.com` is in Anthropic's
default domain list, so this needs nothing in
[network/allowed-domains/](network/allowed-domains/).

Both plugins track `main` at image-build time and are then frozen with the rest
of the snapshot -- neither repository publishes releases a marketplace could
follow, and `vladikk/modularity` has no tags at all. Re-running the setup in a
live session (see above) re-fetches and updates them; `add` and `install` on
their own report "already there" and keep serving the cached copy, which is why
the script also calls `marketplace update` and `plugin update`.

# Playwright

Browsers are not preinstalled — they are ~500 MB and tied to the Playwright
version a given project pins, so a project installs its own:

```sh
npx playwright install chromium
```

Verified to need only `cdn.playwright.dev` and
`playwright.download.prss.microsoft.com` beyond the defaults; see
[network/allowed-domains/playwright.txt](network/allowed-domains/playwright.txt).

Two things that are not covered by the allowed-domains list:

- `npx playwright install --with-deps` installs system libraries with `apt-get`
  and re-runs itself under `sudo`. The Ubuntu apt hosts are in Anthropic's
  default list, but Playwright does not forward proxy environment variables
  across that `sudo`, so if it fails, run
  `sudo HTTPS_PROXY="${HTTPS_PROXY}" npx playwright install-deps` instead.
- `npx playwright install chrome` installs branded Google Chrome from
  `dl.google.com`, which is *not* allowed. Use `chromium` unless a project
  specifically needs the branded build.

# Docker and Testcontainers

Out of the box, a Testcontainers suite fails here twice over, and neither
failure names its own cause.

**The daemon is not running.** The image has the whole Docker stack — CLI,
`dockerd`, `containerd`, `runc`, and a `docker.service` unit — but PID 1 is the
session supervisor, not systemd, so nothing starts it. There is no
`/var/run/docker.sock`, and Testcontainers reports `Could not find a valid
Docker environment`, which sounds like Docker is missing rather than merely
unstarted. [`claude/docker.sh`](claude/docker.sh), run from the SessionStart
hook, starts it and waits for the socket. It needs no proxy or CA setup: egress
is intercepted transparently, so `dockerd` behaves identically with and without
`HTTPS_PROXY`.

Starting it once per session start is not enough, though. A resumed session gets
a *new* container — the old one is reclaimed, and the daemon dies with it —
without necessarily getting a fresh SessionStart to put it back, and a daemon
that dies mid-session is never restarted either way. Both look the same from
inside: `Could not find a valid Docker environment`, in a session whose startup
output said `daemon ready` about a container that no longer exists. So
[`claude/ensure-docker.sh`](claude/ensure-docker.sh) also runs from a PreToolUse
hook on `Bash` and asks the question where it matters — right before a shell
command runs. It is a single `pgrep` when the daemon is up, and it retries the
expensive path at most once per boot for as long as starting keeps failing, so
an image without a working `dockerd` does not make every command wait.

`claude/docker.sh` runs *first* in the SessionStart hook, ahead of the mise and
Maven work, because it depends on none of it: running it last meant any earlier
failure took Docker down with it, under a name that pointed nowhere near the
real cause.

**Docker Hub's blob CDN is not on the allowed-domains list.** The registry
hosts are in Anthropic's defaults, so a pull authenticates and resolves the
manifest before dying on the layers. The default list has a *stale* CDN entry —
`production.cloudflare.docker.com` — while Hub now redirects blobs to
`production.cloudfront.docker.com`. Hence
[network/allowed-domains/docker.txt](network/allowed-domains/docker.txt), which
is why that host appears in the list above.

Until that host is pasted into the environment's **Allowed domains**, a
pull-through cache is the stopgap, because `*.gcr.io` is already in Anthropic's
defaults:

```sh
echo '{"registry-mirrors": ["https://mirror.gcr.io"]}' | sudo tee /etc/docker/daemon.json
# dockerd only reads that file at startup, and the session already started it
# -- so restart it, or the mirror is configured and unused.
sudo pkill dockerd && bash "${HOME}/arlo-setup/claude/docker.sh"
```

That covers Docker Hub only, and `dockerd` falls back to Hub when the mirror
does not have an image — which then hits the blocked host again. Prefer fixing
the list.

`quay.io` and `registry.k8s.io` are both blocked and are not in
`allowed-domains/`; a project pulling from either needs them added.

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
