#!/usr/bin/env python3
"""Extract the Claude Code cloud environment default allowed-domains list.

The environment's "Custom" network mode has an *Also include default list of
common package managers* checkbox. With it checked, every domain Anthropic
already trusts is allowed, and this repo only has to list what is missing.
Knowing exactly what that default list contains is therefore the difference
between a maintained list of 5 hosts and a maintained list of 30.

Anthropic publishes the list as prose in the docs, which is the closest thing
to a machine-readable source of truth:

    https://code.claude.com/docs/en/cloud-environments.md

This parses the "Default allowed domains" section of that page into one domain
per line, so refresh-sources.sh can commit it and a diff shows when Anthropic
adds or removes a default.

    ./network/extract-claude-defaults.py <cloud-environments.md >defaults.txt
"""

import re
import sys

SECTION_HEADING = "## Default allowed domains"

# Bullets look like:
#     * api.anthropic.com
#     * \*.gcr.io                     (escaped wildcard)
#     * raw\.githubusercontent.com    (escaped dot)
#     * [www.github.com](http://www.github.com)   (autolinked by the renderer)
#     * packagist.org (PHP Composer)  (trailing annotation)
BULLET = re.compile(r"^\s*\*\s+(?P<body>\S.*?)\s*$")
MARKDOWN_LINK = re.compile(r"^\[(?P<text>[^\]]+)\]\([^)]*\)$")
DOMAIN = re.compile(r"^\*?[a-z0-9.*-]+\.[a-z]{2,}$")


def extract(markdown):
    """Yield the domains listed under the default-allowed-domains heading."""
    lines = markdown.splitlines()
    try:
        start = next(
            index for index, line in enumerate(lines)
            if line.strip() == SECTION_HEADING
        )
    except StopIteration:
        raise SystemExit(
            f"extract-claude-defaults: no '{SECTION_HEADING}' heading found; "
            "the docs page layout changed"
        )

    domains = []
    for line in lines[start + 1:]:
        # The next top-level heading ends the section.
        if line.startswith("## "):
            break
        match = BULLET.match(line)
        if not match:
            continue
        body = match.group("body")
        # A bare-URL bullet is rendered as a markdown link; the link text is
        # the hostname, the target adds a scheme we do not want.
        link = MARKDOWN_LINK.match(body)
        if link:
            body = link.group("text")
        # Drop trailing annotations like "(PHP Composer)".
        body = body.split(" (")[0].strip()
        # Undo the renderer's escaping of "*" and ".".
        body = body.replace("\\", "")
        body = body.strip().lower()
        if DOMAIN.match(body):
            domains.append(body)

    if not domains:
        raise SystemExit(
            "extract-claude-defaults: section found but no domains parsed; "
            "the docs page layout changed"
        )
    return sorted(set(domains))


def main():
    markdown = sys.stdin.read()
    for domain in extract(markdown):
        print(domain)


if __name__ == "__main__":
    main()
