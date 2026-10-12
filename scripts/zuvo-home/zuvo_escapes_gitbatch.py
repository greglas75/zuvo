"""One git process for many objects: `git cat-file --batch` / `--batch-check` over a list of specs.

review-escapes reads one small object per artifact head, per escape row and per introducing commit; a
process per object cost minutes on a large repository (thousands of spawns). Specs go in chunks of
CHUNK, so no single process buffers every blob a large run asks for. Every spec is a key of the
result: a missing or ambiguous object is None, never an error, and so is a spec that cannot be sent —
one holding a newline (git reads specs one per line) or a character no byte encodes (a lone surrogate
that is not an escaped byte). A failing or timed-out process, or output not in
the documented shape (after which no later answer can be trusted to belong to its spec), raises
fw.GitError, and callers fall back to reading objects one by one.

Also the two time readers every escapes module shares: commit_ts for a raw commit object, parse_utc
for a row or ledger timestamp (UTC only, `…Z`, `…+00:00` or `…+0000`, optional fractional seconds;
any other form is None — unknown — never a raise).
"""

from __future__ import annotations

import datetime as dt
import os
import re
import subprocess

import zuvo_escapes_fixwalk as fw

BATCH_TIMEOUT = 300
CHUNK = 500
_HEADER = re.compile(rb"^([0-9a-f]{40}|[0-9a-f]{64}) ([a-z]+) ([0-9]+)$")
_UTC = re.compile(r"^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\.[0-9]{1,9})?(?:Z|\+00:?00)$")


def cat_file(repo: str, specs: list[str], check: bool = False) -> dict[str, bytes | None]:
    """Every object `specs` names, CHUNK specs per `git cat-file --batch` (or --batch-check: the
    resolved sha instead of the content); None for a missing or ambiguous one. Raises fw.GitError."""
    found: dict[str, bytes | None] = {}
    sendable: list[tuple[str, bytes]] = []
    for spec in dict.fromkeys(specs):
        try:
            wire = spec.encode("utf-8", "surrogateescape")  # a non-UTF-8 path byte goes out as-is
        except UnicodeEncodeError:
            wire = b"\n"
        if b"\n" in wire:
            found[spec] = None
        else:
            sendable.append((spec, wire))
    for i in range(0, len(sendable), CHUNK):
        found.update(_batch(repo, sendable[i:i + CHUNK], check))
    return {spec: found[spec] for spec in dict.fromkeys(specs)}


def _batch(repo: str, chunk: list[tuple[str, bytes]], check: bool) -> dict[str, bytes | None]:
    cmd = ["git", "--literal-pathspecs", "-C", repo, "cat-file", "--batch-check" if check else "--batch"]
    env = {k: v for k, v in os.environ.items() if k not in fw.REPO_ENV}
    specs, wire = [s for s, _ in chunk], [w for _, w in chunk]
    try:
        proc = subprocess.run(cmd, input=b"".join(w + b"\n" for w in wire), capture_output=True,
                              timeout=BATCH_TIMEOUT, env=env)
    except (subprocess.TimeoutExpired, OSError) as exc:
        raise fw.GitError(f"git cat-file: {exc}") from exc
    if proc.returncode != 0:
        raise fw.GitError(f"git cat-file failed (rc {proc.returncode})")
    try:
        return _parse(proc.stdout, specs, wire, check)
    except ValueError as exc:  # output cut short or not in the documented shape
        raise fw.GitError(f"git cat-file: unreadable output ({exc})") from exc


def _parse(out: bytes, specs: list[str], wire: list[bytes], check: bool) -> dict[str, bytes | None]:
    """`<sha> <type> <size>` (+ content and a newline unless `check`), or `<spec> missing|ambiguous`,
    once per spec in input order. Anything else — content not followed by its newline, bytes left over
    after the last answer — raises ValueError."""
    pos = 0
    found: dict[str, bytes | None] = {}
    for i, spec in enumerate(specs):
        sent = wire[i]
        end = out.index(b"\n", pos)
        head = out[pos:end]
        pos = end + 1
        if head in (sent + b" missing", sent + b" ambiguous"):
            found[spec] = None
            continue
        m = _HEADER.match(head)
        if not m:
            raise ValueError(f"{spec}: malformed header {head[:80]!r}")
        if check:
            found[spec] = m.group(1)
            continue
        size = int(m.group(3))
        if out[pos + size:pos + size + 1] != b"\n":
            raise ValueError(f"{spec}: {size} bytes announced, not followed by a newline")
        found[spec], pos = out[pos:pos + size], pos + size + 1
    if pos != len(out):
        raise ValueError(f"{len(out) - pos} unexpected bytes after the last answer")
    return found


def commit_ts(raw: bytes | None, who: str) -> str | None:
    """The `who` (author / committer) epoch of a raw commit object, as text; None when absent or not
    in the `<name> <email> <epoch> <zone>` shape."""
    for line in (raw or b"").split(b"\n"):
        if line.startswith(who.encode() + b" "):
            parts = line.split()
            ok = len(parts) >= 4 and parts[-2].isdigit()
            return parts[-2].decode("ascii") if ok else None
        if not line:
            break
    return None


def parse_utc(text: object) -> int | None:
    """Epoch seconds of a UTC ISO-8601 time (`2026-09-11T12:00:00Z`, `….250Z`, `…+00:00`), fraction
    dropped; None for any other form or an impossible date."""
    m = _UTC.match(text.strip()) if isinstance(text, str) else None
    if not m:
        return None
    try:
        when = dt.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None
    return int(when.replace(tzinfo=dt.timezone.utc).timestamp())
