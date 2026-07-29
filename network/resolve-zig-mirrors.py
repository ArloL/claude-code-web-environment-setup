#!/usr/bin/env python3
"""Render the Zig allowed-domains file from the upstream community mirror list.

    ./network/resolve-zig-mirrors.py > network/allowed-domains/zig-mirrors.txt

mise's zig backend downloads https://ziglang.org/download/community-mirrors.txt,
shuffles it, and tries each mirror in turn until one serves the tarball
(src/plugins/core/zig.rs), so every host in that file has to be reachable --
which run picks which mirror is luck, and a missing host shows up as an
intermittent 503.

Taking the hostnames straight out of that file is not enough, though: a mirror
may redirect elsewhere, and mise follows the redirect. zigmirror.com serves from
download.zigmirror.com, which appears in no upstream list. Observed by installing
zig under network/discover.sh -- the single run that happened to draw
zigmirror.com contacted both hosts.

So each mirror is probed once and any redirect target is recorded too. That is
enumeration, not sampling: the mirror list is known, and this resolves every
entry rather than hoping a repeated install eventually draws each one.
"""

import http.client
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request

MIRROR_LIST_URL = "https://ziglang.org/download/community-mirrors.txt"
VERSION_INDEX_URL = "https://ziglang.org/download/index.json"

# Zig asks tools fetching from community mirrors to identify themselves with a
# ?source= parameter, so mirror operators can see who their traffic is. Use our
# own name rather than mise's, so this probe is not misattributed.
SOURCE = "claude-code-web-environment-setup"
USER_AGENT = f"{SOURCE} (network/resolve-zig-mirrors.py)"
TIMEOUT_SECONDS = 20


class RedirectRecorder(urllib.request.HTTPRedirectHandler):
    """Follows redirects like mise does, recording every host passed through."""

    def __init__(self):
        self.hosts = []

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        host = urllib.parse.urlsplit(newurl).hostname
        if host:
            self.hosts.append(host.lower())
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch(url, data_is_text=True):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        body = response.read()
    return body.decode("utf-8") if data_is_text else body


def probe_filenames(count=2):
    """Real tarball basenames to request, taken from the upstream index.

    The naming scheme has changed between Zig releases
    (zig-linux-x86_64-0.13.0 vs zig-x86_64-linux-0.14.0), so read actual
    tarball URLs rather than constructing them.

    More than one release is probed because a mirror that has not caught up
    with the newest release answers 404, and a 404 reveals no redirect. Trying
    an older release as well keeps a lagging mirror from silently contributing
    nothing.
    """
    import json

    index = json.loads(fetch(VERSION_INDEX_URL))
    filenames = []
    for version, targets in index.items():
        if version == "master" or not isinstance(targets, dict):
            continue
        for target, details in targets.items():
            if not isinstance(details, dict):
                continue
            tarball = details.get("tarball")
            if tarball and target.endswith("linux"):
                filenames.append(tarball.rsplit("/", 1)[-1])
                break
        if len(filenames) >= count:
            break
    if not filenames:
        raise SystemExit(
            "resolve-zig-mirrors: no tarball found in index.json; the layout "
            "changed"
        )
    return filenames


def resolve(mirror, filename):
    """Return the hosts a download from this mirror would touch.

    The mirror's own host is always included, even when the probe fails: it
    comes from the upstream list and mise will try it regardless of whether it
    happens to be up right now. Only the redirect target depends on the probe.
    """
    own_host = urllib.parse.urlsplit(mirror).hostname
    own_host = own_host.lower() if own_host else None
    recorder = RedirectRecorder()
    # opener.open, not urllib.request.urlopen: the latter uses the module-level
    # global opener and would ignore the recorder entirely.
    opener = urllib.request.build_opener(recorder)
    url = f"{mirror.rstrip('/')}/{filename}?source={SOURCE}"
    request = urllib.request.Request(
        url,
        headers={
            # Some mirrors answer a missing User-Agent with 403.
            "User-Agent": USER_AGENT,
            # One byte is enough to follow the redirect chain without pulling
            # a hundred megabytes from sixteen volunteer-run mirrors.
            "Range": "bytes=0-0",
        },
    )
    final_url = None
    try:
        with opener.open(request, timeout=TIMEOUT_SECONDS) as response:
            response.read(1)
            final_url = response.url
    except urllib.error.HTTPError as error:
        # A 4xx after redirects still tells us which hosts were involved.
        final_url = error.url
        if error.code >= 500 or not recorder.hosts:
            print(
                f"resolve-zig-mirrors: {own_host}: HTTP {error.code}; "
                "keeping the host, could not check for redirects",
                file=sys.stderr,
            )
    except (urllib.error.URLError, socket.timeout, http.client.HTTPException,
            OSError) as error:
        print(
            f"resolve-zig-mirrors: {own_host}: {error}; keeping the host, "
            "could not check for redirects",
            file=sys.stderr,
        )

    hosts = [own_host] if own_host else []
    hosts.extend(recorder.hosts)
    # Belt and braces: the recorded chain and the final URL are derived
    # independently, and a missed host here becomes an intermittent 503 later.
    if final_url:
        final_host = urllib.parse.urlsplit(final_url).hostname
        if final_host:
            hosts.append(final_host.lower())
    # Preserve order (the mirror's own host first) while de-duplicating.
    return list(dict.fromkeys(hosts))


def main():
    mirrors = [line.strip() for line in fetch(MIRROR_LIST_URL).splitlines()]
    mirrors = [m for m in mirrors if m and not m.startswith("#")]
    if not mirrors:
        raise SystemExit(
            "resolve-zig-mirrors: community-mirrors.txt was empty; refusing to "
            "shrink the allowlist"
        )

    filenames = probe_filenames()
    direct = set()
    redirect_targets = {}
    for mirror in mirrors:
        for filename in filenames:
            hosts = resolve(mirror, filename)
            if not hosts:
                continue
            direct.add(hosts[0])
            extra = [h for h in hosts[1:] if h != hosts[0]]
            for target in extra:
                redirect_targets[target] = hosts[0]
            # One successful probe is enough; only fall through to the older
            # release when this one told us nothing about redirects.
            if extra:
                break

    print("# Zig downloads, for mise's zig backend.")
    print("#")
    print("# GENERATED by network/refresh-sources.sh via")
    print("# network/resolve-zig-mirrors.py. Do not edit by hand.")
    print("#")
    print("# mise shuffles the community mirror list and tries each host in")
    print("# turn (src/plugins/core/zig.rs), so any of them can serve a given")
    print("# install and all of them have to be reachable.")
    print()
    print("# The Zig project itself: the mirror list, download/index.json for")
    print("# version resolution, and /builds/ for nightlies, which are not")
    print("# mirrored.")
    print("ziglang.org")
    print()
    print(f"# Community mirrors, from {MIRROR_LIST_URL}")
    for host in sorted(direct):
        print(host)
    if redirect_targets:
        print()
        print("# Redirect targets. These appear in no upstream list; they were")
        print("# found by requesting a tarball from each mirror and following")
        print("# the redirects, the same way mise does.")
        for host, source_host in sorted(redirect_targets.items()):
            print(f"{host}  # {source_host} redirects here")
    return 0


if __name__ == "__main__":
    sys.exit(main())
