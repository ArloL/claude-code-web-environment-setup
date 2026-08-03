#!/usr/bin/env python3
"""Write ~/.m2/settings.xml: global build settings, plus proxy config if needed.

The proxy half is derived from HTTPS_PROXY and only appears when the
environment sets one. The global half applies regardless, so the file is
written either way.
"""

import os
import sys
from urllib.parse import urlparse

PROXY_ENTRY = """\
        <proxy>
            <id>{proxy_id}</id>
            <active>true</active>
            <protocol>{protocol}</protocol>
            <host>{host}</host>
            <port>{port}</port>{credentials}
            <nonProxyHosts>{non_proxy_hosts}</nonProxyHosts>
        </proxy>"""

CREDENTIALS_SNIPPET = """
            <username>{username}</username>
            <password>{password}</password>"""

PROXIES_BLOCK = """\
    <proxies>
{proxies}
    </proxies>
"""

# Maven resolves only the binary jar of a dependency unless it is asked for
# more. downloadSources/downloadJavadocs are the properties the IDE
# integrations and maven-dependency-plugin read to also fetch the -sources and
# -javadoc jars, so an always-active profile that sets them saves passing
# -DdownloadSources=true -DdownloadJavadocs=true on every invocation.
GLOBAL_PROFILE = """\
    <profiles>
        <profile>
            <id>downloadSources</id>
            <properties>
                <downloadSources>true</downloadSources>
                <downloadJavadocs>true</downloadJavadocs>
            </properties>
        </profile>
    </profiles>
    <activeProfiles>
        <activeProfile>downloadSources</activeProfile>
    </activeProfiles>
"""

# settings-1.0.0.xsd declares the children of <settings> as a sequence, so
# <proxies> has to come before <profiles> and <activeProfiles>.
SETTINGS_XML = """\
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
          http://maven.apache.org/xsd/settings-1.0.0.xsd">
{body}</settings>
"""


def proxies_block():
    """Render <proxies> from HTTPS_PROXY, or "" when there is no proxy."""
    https_proxy = os.environ.get("HTTPS_PROXY", "")
    if not https_proxy:
        print("No HTTPS_PROXY environment variable found, skipping proxy configuration")
        return ""

    parsed = urlparse(https_proxy)
    host = parsed.hostname
    port = parsed.port
    if not host or not port:
        print(f"ERROR: could not parse host:port from HTTPS_PROXY={https_proxy!r}", file=sys.stderr)
        sys.exit(1)
    port = str(port)

    username = parsed.username
    password = parsed.password
    if username and password:
        credentials = CREDENTIALS_SNIPPET.format(username=username, password=password)
        print(f"Detected proxy: {username}@{host}:{port}")
    else:
        credentials = ""
        print(f"Detected proxy: {host}:{port}")

    non_proxy_hosts = os.environ.get("NO_PROXY", "localhost|127.0.0.1")

    proxy_entries = "\n".join(
        PROXY_ENTRY.format(
            proxy_id=f"{protocol}-proxy",
            protocol=protocol,
            host=host,
            port=port,
            credentials=credentials,
            non_proxy_hosts=non_proxy_hosts,
        )
        for protocol in ("http", "https")
    )

    return PROXIES_BLOCK.format(proxies=proxy_entries)


settings_dir = os.path.join(os.path.expanduser("~"), ".m2")
os.makedirs(settings_dir, exist_ok=True)
settings_path = os.path.join(settings_dir, "settings.xml")

with open(settings_path, "w") as f:
    f.write(SETTINGS_XML.format(body=proxies_block() + GLOBAL_PROFILE))

print(f"Maven settings.xml written to {settings_path}")
