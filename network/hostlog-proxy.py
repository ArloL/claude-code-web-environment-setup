#!/usr/bin/env python3
"""A logging HTTP/HTTPS forward proxy for discovering which hosts an installer needs.

The Claude Code web environment reaches the internet through a CONNECT proxy
that only tunnels to hosts on the environment's allowed-domains list. Every
"why is this download failing" debugging session is really the question "which
hostname did the tool want". This proxy answers that question locally, without
guessing:

    ./network/discover.sh --output hosts.txt -- npx playwright install chromium

It runs in two modes:

record (default)
    Tunnel everything, append every requested host to the log. Use this to
    discover the hosts a tool needs.

enforce (--allow-file)
    Tunnel only hosts on the list, reject everything else with 503 -- the same
    status the real environment returns. Use this to prove a candidate
    allowed-domains list is complete before pasting it into the web UI.

Only the standard library is used, so this also runs inside the environment
itself. HTTPS is tunnelled untouched: the hostname comes from the CONNECT line,
so there is no TLS interception and no certificate to install.
"""

import argparse
import http.server
import select
import signal
import socket
import sys
import threading
import urllib.parse

# A CONNECT tunnel to a slow download must not be torn down mid-transfer, but a
# wedged socket must not hang the proxy forever either.
TUNNEL_IDLE_TIMEOUT_SECONDS = 300
CONNECT_TIMEOUT_SECONDS = 30


class HostLog:
    """Collects requested hosts, de-duplicated, in first-seen order."""

    def __init__(self, output_path=None):
        self._output_path = output_path
        self._lock = threading.Lock()
        self._hosts = {}

    def record(self, host, allowed):
        with self._lock:
            first_time = host not in self._hosts
            # A host allowed once stays allowed: the same host may be requested
            # both before and after it is added to a list.
            self._hosts[host] = self._hosts.get(host, False) or allowed
        if first_time:
            marker = "allow" if allowed else "BLOCK"
            print(f"[{marker}] {host}", file=sys.stderr, flush=True)

    def hosts(self):
        with self._lock:
            return dict(self._hosts)

    def write(self):
        if not self._output_path:
            return
        hosts = self.hosts()
        with open(self._output_path, "w", encoding="utf-8") as handle:
            for host in sorted(hosts):
                handle.write(f"{host}\n")


def host_allowed(host, allowed_domains):
    """Match a host against the allowlist.

    Suffix matching (``jdx.dev`` covering ``mise.jdx.dev``) is deliberately NOT
    implemented: the environment's list is exact-hostname, so accepting
    suffixes here would report a list as complete that the real proxy rejects.
    """
    if allowed_domains is None:
        return True
    return host.lower() in allowed_domains


def read_domain_list(path):
    """Read a domain list, ignoring blank lines and ``#`` comments."""
    domains = set()
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.split("#", 1)[0].strip()
            if line:
                domains.add(line.lower())
    return domains


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # BaseHTTPRequestHandler logs every request to stderr; the host log is the
    # signal we care about, so keep the noise out.
    def log_message(self, format, *args):  # noqa: A002 - signature is fixed
        pass

    @property
    def _host_log(self):
        return self.server.host_log

    @property
    def _allowed_domains(self):
        return self.server.allowed_domains

    def _reject_blocked(self, host):
        """Mimic the environment's response for a host that is not allowed."""
        body = (
            f"Blocked by hostlog-proxy: {host} is not in the allowed-domains "
            f"list.\n"
        ).encode()
        self.send_response(503)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_CONNECT(self):  # noqa: N802 - name is fixed by the base class
        host, _, port = self.path.rpartition(":")
        if not host:
            host, port = self.path, "443"
        allowed = host_allowed(host, self._allowed_domains)
        self._host_log.record(host, allowed)
        if not allowed:
            self._reject_blocked(host)
            return

        try:
            upstream = socket.create_connection(
                (host, int(port)), timeout=CONNECT_TIMEOUT_SECONDS
            )
        except OSError as error:
            self.send_error(502, f"Cannot reach {host}:{port}: {error}")
            return

        self.send_response(200, "Connection established")
        self.end_headers()
        # Flush the 200 before handing the socket to the raw tunnel loop.
        self.wfile.flush()
        with upstream:
            self._tunnel(self.connection, upstream)

    @staticmethod
    def _tunnel(client, upstream):
        client.settimeout(None)
        upstream.settimeout(None)
        sockets = [client, upstream]
        while True:
            readable, _, errored = select.select(
                sockets, [], sockets, TUNNEL_IDLE_TIMEOUT_SECONDS
            )
            if errored or not readable:
                return
            for source in readable:
                destination = upstream if source is client else client
                try:
                    chunk = source.recv(65536)
                except OSError:
                    return
                if not chunk:
                    return
                try:
                    destination.sendall(chunk)
                except OSError:
                    return

    def _do_plain_http(self):
        """Forward an absolute-URI request (plain HTTP through a proxy)."""
        parsed = urllib.parse.urlsplit(self.path)
        host = parsed.hostname or ""
        allowed = host_allowed(host, self._allowed_domains)
        self._host_log.record(host, allowed)
        if not allowed:
            self._reject_blocked(host)
            return

        port = parsed.port or 80
        path = urllib.parse.urlunsplit(("", "", parsed.path or "/", parsed.query, ""))
        body_length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(body_length) if body_length else b""

        request = [f"{self.command} {path} HTTP/1.1"]
        for name, value in self.headers.items():
            if name.lower() in ("proxy-connection", "connection"):
                continue
            request.append(f"{name}: {value}")
        request.append("Connection: close")
        request.append("")
        request.append("")
        head = "\r\n".join(request).encode("latin-1")

        try:
            with socket.create_connection(
                (host, port), timeout=CONNECT_TIMEOUT_SECONDS
            ) as upstream:
                upstream.sendall(head + body)
                while True:
                    chunk = upstream.recv(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                self.wfile.flush()
        except OSError as error:
            self.send_error(502, f"Cannot reach {host}:{port}: {error}")
            return
        # The upstream response was relayed verbatim, including its own
        # framing, so this connection cannot be reused.
        self.close_connection = True

    do_GET = _do_plain_http
    do_POST = _do_plain_http
    do_PUT = _do_plain_http
    do_HEAD = _do_plain_http
    do_DELETE = _do_plain_http
    do_PATCH = _do_plain_http
    do_OPTIONS = _do_plain_http


class ProxyServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, host_log, allowed_domains):
        super().__init__(address, ProxyHandler)
        self.host_log = host_log
        self.allowed_domains = allowed_domains

    def handle_error(self, request, client_address):
        """Stay quiet about clients hanging up.

        A client that gets a 503 for a CONNECT usually resets the connection
        rather than reading a response body, and an aborted download closes
        mid-transfer. Both are normal here, and a traceback for each one buries
        the host log that is the actual output.
        """
        if isinstance(sys.exception(), (ConnectionResetError, BrokenPipeError)):
            return
        super().handle_error(request, client_address)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Logging HTTP/HTTPS proxy that records the hosts a tool requests."
    )
    parser.add_argument(
        "--port",
        type=int,
        default=0,
        help="port to listen on (default: pick a free port and print it)",
    )
    parser.add_argument(
        "--output",
        help="file to write the sorted list of requested hosts to on shutdown",
    )
    parser.add_argument(
        "--allow-file",
        help=(
            "enforce this allowed-domains list: hosts not on it get a 503, "
            "like the real environment (default: allow everything)"
        ),
    )
    parser.add_argument(
        "--port-file",
        help="file to write the listening port to once bound",
    )
    args = parser.parse_args(argv)

    allowed_domains = (
        read_domain_list(args.allow_file) if args.allow_file else None
    )
    host_log = HostLog(args.output)
    server = ProxyServer(("127.0.0.1", args.port), host_log, allowed_domains)
    port = server.server_address[1]
    mode = "enforce" if allowed_domains is not None else "record"
    print(f"hostlog-proxy listening on 127.0.0.1:{port} ({mode} mode)",
          file=sys.stderr, flush=True)
    if args.port_file:
        with open(args.port_file, "w", encoding="utf-8") as handle:
            handle.write(f"{port}\n")

    # serve_forever() runs off the main thread so that a signal handler can
    # call shutdown() without deadlocking against it.
    stop = threading.Event()
    serve_thread = threading.Thread(target=server.serve_forever, daemon=True)
    serve_thread.start()

    def request_stop(signum, frame):  # noqa: ARG001 - handler signature
        stop.set()

    for signal_name in ("SIGTERM", "SIGINT", "SIGHUP"):
        number = getattr(signal, signal_name, None)
        if number is None:
            continue
        # A shell starting this proxy as a background job sets SIGINT to
        # ignored and the child inherits that, so install handlers explicitly
        # rather than relying on Python's default KeyboardInterrupt behaviour.
        signal.signal(number, request_stop)

    try:
        stop.wait()
    finally:
        server.shutdown()
        server.server_close()
        host_log.write()
        blocked = sorted(h for h, ok in host_log.hosts().items() if not ok)
        if blocked:
            print(
                "blocked hosts: " + " ".join(blocked), file=sys.stderr, flush=True
            )
    return 1 if blocked else 0


if __name__ == "__main__":
    sys.exit(main())
