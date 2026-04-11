#!/usr/bin/env python3
"""Write ~/.m2/settings.xml with proxy config derived from HTTPS_PROXY."""

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

SETTINGS_XML = """\
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
          http://maven.apache.org/xsd/settings-1.0.0.xsd">
    <proxies>
{proxies}
    </proxies>
</settings>
"""

https_proxy = os.environ.get("HTTPS_PROXY", "")
if not https_proxy:
    print("No HTTPS_PROXY environment variable found, skipping proxy configuration")
    sys.exit(0)

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

settings_dir = os.path.join(os.path.expanduser("~"), ".m2")
os.makedirs(settings_dir, exist_ok=True)
settings_path = os.path.join(settings_dir, "settings.xml")

with open(settings_path, "w") as f:
    f.write(SETTINGS_XML.format(proxies=proxy_entries))

print("Maven settings.xml created with proxy configuration")
