# Network access

The Claude Code web environment reaches the internet through a proxy that only
tunnels to hosts on the environment's **Allowed domains** list. Anything else
fails, usually as a 503 from a tool that reports it as something else entirely.

That list is one flat newline-separated field in the web UI, which is why it
became unmaintainable: after a while it is 30 hostnames with no record of what
needs them, whether they are still needed, or where the list came from. Nobody
can safely delete a line from it.

So the list is generated. The hosts live in [`allowed-domains/`](allowed-domains/),
one file per thing that needs them, each host annotated with **what needs it**
and **the upstream source of truth that can be re-checked**.

## The three moves that shrink the list

**1. Let Anthropic's default list do the work.** Under *Custom* network access
there is a checkbox, **Also include default list of common package managers**.
With it checked, ~200 domains are already allowed: npm, PyPI, Maven Central,
crates.io, the GitHub asset hosts, the Ubuntu apt mirrors, `storage.googleapis.com`.
Those need no entry here. `claude-defaults.txt` is a generated copy of that
list, and `build-allowed-domains.py --check` fails if any of our entries have
become redundant with it.

**2. Use wildcards.** A leading `*.` matches any subdomain, so `*.jdx.dev`
replaces `mise.jdx.dev`, `mise-versions.jdx.dev` and `mise-java.jdx.dev`.

**3. Poll the lists that move on their own.** Zig's community mirrors and
Anthropic's defaults both change without anything in this repo changing.
`refresh-sources.sh` fetches them, and the monthly workflow opens a pull request
when they differ.

## Adding a host

Do not guess. Measure, then record.

```sh
# 1. Which hosts does this actually need?
network/discover.sh -- npx playwright install chromium
```

`discover.sh` runs the command behind a local proxy that logs every host it is
asked to reach, so the answer is observed rather than inferred.

**One run only shows the hosts that run happened to pick.** Four consecutive
`mise install zig` runs contacted four different mirrors, and one of them fell
through two mirrors before a download succeeded. `--repeat N` runs the command N
times and flags hosts that did not appear on every run:

```sh
network/discover.sh --repeat 4 -- mise install zig@0.13.0
```

Treat that as rotation *detection*, never as proof of completeness. mise draws
from 16 shuffled Zig mirrors and contacts about one per run, so seeing them all
would take dozens of runs and still prove nothing. For anything that rotates,
derive the set from upstream — that is what `resolve-zig-mirrors.py` does.

### Deriving a rotating set is not just reading the upstream list

`zigmirror.com` serves its tarballs from `download.zigmirror.com`, and mise
follows the redirect. That host appears in no upstream list, and only one of the
16 mirrors does it, so a single discovery run finds it only if it happens to draw
that mirror. `resolve-zig-mirrors.py` therefore probes every mirror in the
upstream list and records the redirect targets — enumeration, not sampling. It
also probes two Zig releases, because a mirror that has not caught up with the
newest release answers 404 and a 404 reveals no redirect.

```sh
# 2. Record it in the right file, with its source of truth, then re-render
python3 network/build-allowed-domains.py --update-readme

# 3. Prove the list is now sufficient: unlisted hosts get a 503, like production
python3 network/build-allowed-domains.py --effective > /tmp/effective.txt
rm -rf ~/.cache/ms-playwright   # make it actually download
network/discover.sh --allow-file /tmp/effective.txt -- npx playwright install chromium
```

Step 3 is the one worth not skipping: it turns "I think that is all the hosts"
into a command that exits non-zero if it is not. `discover.sh` fails if any host
was blocked.

## Files

| | |
| --- | --- |
| `allowed-domains/*.txt` | the hosts, grouped by what needs them. Comments and blank lines are ignored. |
| `allowed-domains/zig-mirrors.txt` | **generated** by `resolve-zig-mirrors.py`. |
| `resolve-zig-mirrors.py` | fetches the upstream Zig mirror list and probes each mirror for redirect targets. |
| `claude-defaults.txt` | **generated** from the cloud-environments docs. Reference only — never pasted into the UI. |
| `build-allowed-domains.py` | renders the flat list, updates the README block, checks for staleness and redundancy. |
| `refresh-sources.sh` | re-fetches the generated files from upstream, then re-renders. |
| `discover.sh` | runs a command behind the logging proxy and reports the hosts it contacted. |
| `hostlog-proxy.py` | the proxy. Standard library only, so it also runs inside the environment. |
| `extract-claude-defaults.py` | parses the default-domains section of the docs page. |

`hostlog-proxy.py` deliberately does **not** do suffix matching for bare
entries: the real list treats `jdx.dev` and `mise.jdx.dev` as different hosts,
and a proxy that was more permissive than production would certify lists that
then fail in production.

## What this does not solve

The allowed-domains list can only be set through the web UI — there is no API,
CLI or in-repo config that sets it ([docs](https://code.claude.com/docs/en/cloud-environments)).
So the generated block in the top-level README is still copy-pasted by hand.
What is automated is knowing *what* to paste, and being told when it changes.

GitHub traffic does not go through this allowlist at all; it uses a separate
credential-swapping proxy. That proxy only serves repositories granted to the
session, which is why `go.sh` fetches this repo as a `codeload.github.com`
tarball instead of using `git clone`.
