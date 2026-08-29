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

## The two moves that shrink the list

**1. Let Anthropic's default list do the work.** Under *Custom* network access
there is a checkbox, **Also include default list of common package managers**.
With it checked, ~200 domains are already allowed: npm, PyPI, Maven Central,
crates.io, the GitHub asset hosts, the Ubuntu apt mirrors, `storage.googleapis.com`.
Those need no entry here. `claude-defaults.txt` is a generated copy of that
list, and `build-allowed-domains.py --check` fails if any of our entries have
become redundant with it.

**2. Poll the lists that move on their own.** Zig's community mirrors and
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

## Checking the hosts still answer

Everything above measures a host once, when it is added. What nothing here
notices is the list going stale afterwards: an endpoint retired, a host moved
behind a CDN, a redirect that grew a hop to a name nobody listed. In the
environment that surfaces as a 503 in the middle of unrelated work, which is
the debugging session this directory exists to prevent.

So the claims are re-checked against the internet:

```sh
network/check-reachable.sh
```

Each line of [`probes.txt`](probes.txt) is one request that only succeeds if the
thing a host is listed *for* is still being served — Bugzilla's `/rest/version`
rather than its front page. Every probe is fetched through `hostlog-proxy` in
enforce mode against the effective list, so it fails three ways: the request
failed, it needed a host the list does not have, or it contacted a different set
of hosts than the probe declares. That last one is the early warning — a new
redirect hop shows up as a failing check here instead of a 503 later.

A probe is a liveness check, not a feature test, and every run is traffic
somebody else pays for. Prefer the cheapest endpoint that still proves the
point.

[`check-network-hosts.yaml`](../.github/workflows/check-network-hosts.yaml) runs
it monthly and on any change under `network/`. It has no
`required-status-check` job on purpose: it fails when a third party is down, and
a Mozilla outage should not block merging an unrelated change. Red there means
look at it, not do not merge.

This says nothing about the **Allowed domains** field of any actual
environment — only about the list in this repo. Pasting is still by hand.

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
| `check-reachable.sh` | fetches every probe and fails if a host stopped answering or a new one appeared. |
| `probes.txt` | one request per host, each proving the endpoint it is listed for still works. |
| `hostlog-proxy.py` | the proxy. Standard library only, so it also runs inside the environment. |
| `extract-claude-defaults.py` | parses the default-domains section of the docs page. |

`hostlog-proxy.py` deliberately does **not** do suffix matching for bare
entries: the real list treats `jdx.dev` and `mise.jdx.dev` as different hosts,
and a proxy that was more permissive than production would certify lists that
then fail in production.

## Wildcards do not work, whatever the docs say

The docs promise that a leading `*.` in the **Allowed domains** field matches
every subdomain ([Allow specific domains](https://code.claude.com/docs/en/cloud-environments#allow-specific-domains)),
and Anthropic's own default list uses `*.googleapis.com`, `*.gcr.io` and
`*.ubuntu.com`. It was tried here and it does not hold for entries we paste in:
with `*.jdx.dev` as the only `jdx.dev` entry, `https://mise.jdx.dev/install.sh`
came back 503, which reached the user as `mise installation failed` from
`mise.run`'s installer — that installer pipes the 503 into `sh`, so an empty
script runs successfully and the real error is two steps removed from the
symptom. `mise.run`, a bare entry on the same list, worked in the same run.

So every host in `allowed-domains/` is exact. If a `*.` entry ever looks like it
would shrink the list, that is the trap this section exists to stop.

## What this does not solve

The allowed-domains list can only be set through the web UI — there is no API,
CLI or in-repo config that sets it ([docs](https://code.claude.com/docs/en/cloud-environments)).
So the generated block in the top-level README is still copy-pasted by hand.
What is automated is knowing *what* to paste, and being told when it changes.

GitHub traffic does not go through this allowlist at all; it uses a separate
credential-swapping proxy. That proxy only serves repositories granted to the
session, which is why `go.sh` fetches this repo as a `codeload.github.com`
tarball instead of using `git clone`.
