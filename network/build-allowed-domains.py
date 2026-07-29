#!/usr/bin/env python3
"""Assemble the environment's Allowed domains list from the per-source files.

The web UI wants one flat newline-separated list, but a flat list loses the
only thing that makes it maintainable: why each host is there and where it came
from. So the hosts live in network/allowed-domains/*.txt, annotated and grouped
by what needs them, and this script renders the flat list from them.

    ./network/build-allowed-domains.py                 # paste-ready list
    ./network/build-allowed-domains.py --effective     # + Anthropic's defaults
    ./network/build-allowed-domains.py --update-readme # refresh README block
    ./network/build-allowed-domains.py --check         # CI: README is current

--check also reports hosts that Anthropic's default list already covers, which
is the failure mode this whole directory exists to prevent: a host gets added
during a debugging session, the default list grows to include it, and the entry
lives on forever with nobody knowing it is dead weight.
"""

import argparse
import pathlib
import sys

NETWORK_DIR = pathlib.Path(__file__).resolve().parent
DOMAINS_DIR = NETWORK_DIR / "allowed-domains"
DEFAULTS_FILE = NETWORK_DIR / "claude-defaults.txt"
README_FILE = NETWORK_DIR.parent / "README.md"

BEGIN_MARKER = "<!-- BEGIN generated allowed-domains -->"
END_MARKER = "<!-- END generated allowed-domains -->"
# The list sits inside a numbered list item in the README, so the block has to
# stay indented to remain part of that item.
README_INDENT = "    "


def read_domain_file(path):
    """Return the domains in one annotated list file."""
    domains = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            domains.append(line.lower())
    return domains


def collect_domains():
    """Return every domain across the per-source files, sorted and unique.

    Rejects `*.` entries. The docs say a leading `*.` matches every subdomain,
    but a pasted `*.jdx.dev` did not: mise.jdx.dev still came back 503. See
    "Wildcards do not work, whatever the docs say" in network/README.md.
    """
    if not DOMAINS_DIR.is_dir():
        raise SystemExit(f"build-allowed-domains: missing {DOMAINS_DIR}")
    domains = set()
    for path in sorted(DOMAINS_DIR.glob("*.txt")):
        for domain in read_domain_file(path):
            if domain.startswith("*."):
                raise SystemExit(
                    f"build-allowed-domains: {path.name} has the wildcard "
                    f"entry {domain}. The environment does not honour "
                    f"wildcards in a pasted list -- write out the exact "
                    f"hosts. See network/README.md."
                )
            domains.add(domain)
    if not domains:
        raise SystemExit(
            f"build-allowed-domains: no domains found in {DOMAINS_DIR}"
        )
    return sorted(domains)


def load_defaults():
    if not DEFAULTS_FILE.is_file():
        return []
    return read_domain_file(DEFAULTS_FILE)


def covered_by(domain, allowlist):
    """Return the allowlist entry that makes `domain` reachable, or None.

    Only ever called with Anthropic's default list, where the `*.` entries do
    work -- they are built into the environment rather than pasted into the
    field, and a pasted `*.` does not match (see collect_domains).
    """
    for entry in allowlist:
        if entry == domain:
            return entry
        if entry.startswith("*."):
            suffix = entry[1:]  # ".example.com"
            if domain.endswith(suffix):
                return entry
    return None


def render_readme_block(domains):
    lines = [BEGIN_MARKER, "```"]
    lines.extend(domains)
    lines.append("```")
    lines.append(END_MARKER)
    return [f"{README_INDENT}{line}".rstrip() for line in lines]


def replace_readme_block(text, domains):
    lines = text.splitlines()
    starts = [i for i, line in enumerate(lines) if line.strip() == BEGIN_MARKER]
    ends = [i for i, line in enumerate(lines) if line.strip() == END_MARKER]
    if len(starts) != 1 or len(ends) != 1 or ends[0] < starts[0]:
        raise SystemExit(
            "build-allowed-domains: README.md must contain exactly one "
            f"{BEGIN_MARKER} ... {END_MARKER} pair"
        )
    new_lines = lines[: starts[0]] + render_readme_block(domains) + lines[ends[0] + 1 :]
    return "\n".join(new_lines) + "\n"


def report_redundant(domains, defaults):
    """Print any of our entries that Anthropic's default list already covers."""
    redundant = []
    for domain in domains:
        entry = covered_by(domain, defaults)
        if entry:
            redundant.append((domain, entry))
    if redundant:
        print(
            "These entries are already covered by Anthropic's default list "
            "(see network/claude-defaults.txt). Remove them, as long as the "
            '"Also include default list of common package managers" box is '
            "checked:",
            file=sys.stderr,
        )
        for domain, entry in redundant:
            via = "" if domain == entry else f" (via {entry})"
            print(f"  {domain}{via}", file=sys.stderr)
    return redundant


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Render the Allowed domains list from network/allowed-domains/."
    )
    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--effective",
        action="store_true",
        help=(
            "print our domains plus Anthropic's defaults -- the set the "
            "environment can actually reach, for discover.sh --allow-file"
        ),
    )
    group.add_argument(
        "--update-readme",
        action="store_true",
        help="rewrite the generated list in README.md",
    )
    group.add_argument(
        "--check",
        action="store_true",
        help=(
            "fail if README.md is out of date or any entry is redundant with "
            "the defaults"
        ),
    )
    args = parser.parse_args(argv)

    domains = collect_domains()
    defaults = load_defaults()

    if args.effective:
        for domain in sorted(set(domains) | set(defaults)):
            print(domain)
        return 0

    if args.update_readme:
        text = README_FILE.read_text(encoding="utf-8")
        README_FILE.write_text(replace_readme_block(text, domains), encoding="utf-8")
        print(f"updated {README_FILE} ({len(domains)} domains)", file=sys.stderr)
        return 0

    if args.check:
        text = README_FILE.read_text(encoding="utf-8")
        stale = replace_readme_block(text, domains) != text
        if stale:
            print(
                "README.md is out of date; run "
                "network/build-allowed-domains.py --update-readme",
                file=sys.stderr,
            )
        redundant = report_redundant(domains, defaults)
        return 1 if (stale or redundant) else 0

    for domain in domains:
        print(domain)
    return 0


if __name__ == "__main__":
    sys.exit(main())
