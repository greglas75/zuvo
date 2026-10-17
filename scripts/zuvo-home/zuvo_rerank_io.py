"""The rerank client's edges: which key and URL it may use, and the telemetry line (the request itself is
zuvo_rerank_http.py).
Split from zuvo_rerank.py so the client stays inside the utility file limit; nothing here is meant to be
called by anything but zuvo_rerank.

KEY      OPENROUTER_API_KEY, else ZUVO_OR_KEY_FILE, else $HOME/.zuvo/openrouter.key — the rule of
         adversarial-lanes-http.sh: a file is read only at mode 600/400, and an empty key or one holding a
         quote, backslash or line break is refused.
URL      the OpenRouter key goes ONLY to https://openrouter.ai or to a loopback IP literal (IPv4 127/8, ::1;
         the test stub; http allowed there). Refused before any request: `bad-url` (does not parse, not
         http(s), or carries userinfo `user[:pw]@`), `insecure-url` (cleartext http to another host),
         `foreign-host` (https to any other host — the key is OpenRouter's, never another vendor's).
LOG      one TSV line per call, one os.write under LOG_LOCK; rotated to rerank.log.1 above 5 MB. Opened with
         O_NOFOLLOW: a symlinked rerank.log is never written through (the line is dropped). Every
         non-printable character in caller/model becomes a space, so a name can add no column, line or
         terminal escape.
"""

from __future__ import annotations

import ipaddress
import math
import os
import stat
import threading
import time
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

LOG_MAX_BYTES = 5 * 1024 * 1024
KEY_HOSTS = ("openrouter.ai",)
LOG_LOCK = threading.Lock()


def env_num(name: str, default: float) -> float:
    """A finite, non-negative number from the environment, else `default` (a typo never lifts a limit)."""
    try:
        v = float(os.environ.get(name, ""))
    except ValueError:
        return default
    return v if math.isfinite(v) and v >= 0 else default


def key() -> str | None:
    k = os.environ.get("OPENROUTER_API_KEY", "")
    if not k:
        try:
            kf = Path(os.environ.get("ZUVO_OR_KEY_FILE") or Path.home() / ".zuvo" / "openrouter.key")
        except RuntimeError:  # Path.home() with no HOME and no passwd entry
            return None
        try:
            # O_NONBLOCK (absent on Windows, which has no FIFOs): a FIFO would otherwise wait forever.
            # Mode and type are checked on the OPEN file (fstat), so a swap between check and read cannot
            # slip in.
            with os.fdopen(os.open(kf, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0))) as fh:
                st = os.fstat(fh.fileno())
                if not stat.S_ISREG(st.st_mode) or st.st_mode & 0o777 not in (0o600, 0o400):
                    return None
                k = fh.read().rstrip("\n")
        except (OSError, UnicodeDecodeError):
            return None
    if not k or any(c in k for c in "\"'\\\n\r"):
        return None
    return k


def _loopback(host: str) -> bool:
    """An IP literal on loopback. Names never count: `localhost` resolves through /etc/hosts."""
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def url_problem(url: str) -> str | None:
    """None when `url` may carry the key; otherwise the outcome that refuses it."""
    try:
        parts = urllib.parse.urlsplit(url)
        host = parts.hostname
        parts.port  # noqa: B018 — raises ValueError on a port out of range or not a number
    except ValueError:
        return "bad-url"
    if parts.scheme not in ("https", "http") or not host:
        return "bad-url"
    if parts.scheme == "http" and not _loopback(host):
        return "insecure-url"
    if "@" in parts.netloc:
        return "bad-url"
    if not _loopback(host) and host not in KEY_HOSTS:
        return "foreign-host"
    return None


def log(caller: str, model: str, n: int, t0: float, cost: float | None, outcome: str) -> None:
    """Append `ts caller model n_docs latency_ms cost outcome`. Never raises: telemetry is not a failure."""
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    ms = int((time.monotonic() - t0) * 1000)
    who, what = ("".join(c if c.isprintable() else " " for c in str(x)) or "-" for x in (caller, model))
    fields = (ts, who, what, str(n), str(ms), "-" if cost is None else f"{cost:g}", outcome)
    line = ("\t".join(fields) + "\n").encode("utf-8", "backslashreplace")
    with LOG_LOCK:
        try:
            # inside the try: Path.home() raises RuntimeError when HOME is unset and no passwd entry exists
            path = Path(os.environ.get("ZUVO_HOME") or Path.home() / ".zuvo") / "rerank.log"
            if path.is_symlink():
                return
            old = path.with_name("rerank.log.1")
            if path.exists() and path.lstat().st_size > LOG_MAX_BYTES and not old.is_symlink():
                os.replace(path, old)
            fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            try:
                os.write(fd, line)
            finally:
                os.close(fd)
        except (OSError, RuntimeError):
            pass
