"""The one HTTP request the rerank client makes (split from zuvo_rerank_io.py for the file-size limit).

Plain http.client, so no redirect is followed (a 3xx is `http-3NN`; urllib would re-send Authorization to
the target) and no HTTP(S)_PROXY is honoured. `timeout` bounds the phases differently:
  DNS       outside the deadline (getaddrinfo takes no timeout — a Python limitation).
  connect   create_connection applies `timeout` to EACH resolved address in turn, so a host with N
            unreachable addresses can take up to N x timeout; the deadline is checked once it returns.
  the rest  request, status line, headers and body share what is left of ONE deadline: a timer shuts the
            socket down when it expires, so a server trickling bytes cannot stretch it.
The body is capped at MAX_BODY (more is `bad-shape`); a body shorter than its Content-Length is `http-000`.
"""

from __future__ import annotations

import contextlib
import http.client
import socket
import threading
import time
import urllib.parse

import zuvo_rerank_io as rio

MAX_BODY = 1024 * 1024


def _cut(conn: http.client.HTTPConnection | None) -> None:
    """The deadline timer: unblock any recv in flight; the caller sees OSError / an empty read."""
    sock = conn.sock if conn is not None else None  # None until connect(), and again after close()
    if sock is not None:
        with contextlib.suppress(OSError):
            sock.shutdown(socket.SHUT_RDWR)


def _read(resp: http.client.HTTPResponse, deadline: float) -> tuple[bytes | None, str]:
    chunks, size = [], 0
    while True:
        if time.monotonic() > deadline:
            return None, "timeout"
        chunk = resp.read1(65536)
        if not chunk:
            break
        chunks.append(chunk)
        size += len(chunk)
        if size > MAX_BODY:
            return None, "bad-shape"
    if time.monotonic() > deadline:  # the timer cut the socket: the empty read was the deadline
        return None, "timeout"
    if resp.length:  # EOF before Content-Length was reached: a short body
        return None, "http-000"
    return b"".join(chunks), "ok"


def post(url: str, api_key: str, body: bytes, timeout: float) -> tuple[bytes | None, str]:
    """POST `body` with the key; (response body, "ok") or (None, outcome). Never raises."""
    deadline = time.monotonic() + timeout
    conn: http.client.HTTPConnection | None = None
    timer: threading.Timer | None = None
    try:
        refused = rio.url_problem(url)  # the function that sends the key enforces the allowlist itself
        if refused is not None:
            return None, refused
        parts = urllib.parse.urlsplit(url)
        cls = http.client.HTTPSConnection if parts.scheme == "https" else http.client.HTTPConnection
        conn = cls(parts.hostname or "", parts.port, timeout=timeout)
        conn.connect()  # per-address bounded (see the module docstring); the timer covers everything after
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None, "timeout"
        timer = threading.Timer(remaining, _cut, (conn,))
        timer.start()
        conn.request("POST", parts.path + (f"?{parts.query}" if parts.query else ""), body=body, headers={
            "Authorization": f"Bearer {api_key}", "Content-Type": "application/json"})
        resp = conn.getresponse()
        if not 200 <= resp.status < 300:
            return None, f"http-{resp.status:03d}"
        return _read(resp, deadline)
    except (OSError, ValueError, http.client.HTTPException):
        # reset, refused, short body or bad chunk (IncompleteRead), bad status line — or the timer's cut
        return None, "timeout" if time.monotonic() >= deadline else "http-000"
    finally:
        if timer is not None:
            timer.cancel()
        if conn is not None:
            conn.close()
