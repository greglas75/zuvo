"""Immutable git source snapshots and ephemeral collision evidence."""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
from typing import Any
from urllib.parse import urlsplit

import radar_remote
import radar_io

MAX_FILES = 100_000
MAX_BLOB = 400_000
MAX_TOTAL = 128 * 1024 * 1024


def digest(value: Any) -> str:
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
    ).hexdigest()


def git(root: Path, *args: str, input_bytes: bytes | None = None) -> bytes:
    return radar_io.command(
        ["git", "-C", str(root), *args], root, input_bytes=input_bytes, limit=MAX_TOTAL, timeout=90
    )


def text(root: Path, *args: str) -> str:
    return git(root, *args).decode("utf-8").strip()


def remote(root: Path, cfg: dict) -> str:
    names = [cfg["remote_name"]] if cfg.get("remote_name") else ["bitbucket", "origin"]
    known = text(root, "remote").splitlines()
    for name in names:
        if name in known:
            url = text(root, "remote", "get-url", name)
            # Sanitize every URL scheme, including ssh://user:secret@host.
            if "://" in url:
                parsed = urlsplit(url)
                return parsed._replace(
                    netloc=parsed.netloc.rsplit("@", 1)[-1], query="", fragment=""
                ).geturl()
            return re.sub(r"^[^/@]+@(?=[^/:]+:)", "", url)
    if cfg.get("remote_name"):
        raise ValueError("configured remote_name does not exist")
    return ""


def repo_identity(root: Path, cfg: dict) -> tuple[str, str]:
    common = Path(text(root, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve()
    url = remote(root, cfg)
    host, slug = radar_remote.remote_location(url)
    canonical = f"https://{host}/{slug}" if host and slug else url.removesuffix(".git")
    product = cfg.get("repo_id") or canonical or str(common)
    return str(product), url


def tree(root: Path, sha: str) -> dict[str, dict]:
    records = git(root, "ls-tree", "-rlz", sha).split(b"\0")
    if len(records) > MAX_FILES + 1:
        raise ValueError("source file census exceeds limit; narrow the repository")
    entries: dict[str, dict] = {}
    for record in records:
        if not record:
            continue
        header, filename = record.split(b"\t", 1)
        mode, kind, oid, size = header.decode().split()
        path = radar_remote.safe_path(filename.decode("utf-8"))
        entries[path] = {"mode": mode, "kind": kind, "oid": oid, "size": int(size) if size != "-" else 0}
    return entries


def blobs(root: Path, entries: dict[str, dict], paths: list[str]) -> tuple[dict[str, str], list[dict]]:
    """One cat-file process; never fall back to mutable disk or follow a source symlink."""
    selected, issues = [], []
    total = 0
    for path in sorted(paths):
        entry = entries[path]
        if entry["kind"] != "blob" or entry["mode"] == "120000" or entry["size"] > MAX_BLOB:
            issues.append({"file": path, "reason": "unsupported/symlink/oversized blob"})
            continue
        total += entry["size"]
        if total > MAX_TOTAL:
            raise ValueError("source snapshot exceeds byte budget; narrow profile source_roots")
        selected.append(path)
    request = "".join(entries[p]["oid"] + "\n" for p in selected).encode()
    output = git(root, "cat-file", "--batch", input_bytes=request) if selected else b""
    contents, cursor = {}, 0
    for path in selected:
        end = output.index(b"\n", cursor)
        oid, kind, raw_size = output[cursor:end].decode().split()
        size = int(raw_size)
        cursor = end + 1
        if oid != entries[path]["oid"] or kind != "blob" or size != entries[path]["size"]:
            raise ValueError("git blob identity/size mismatch")
        body = output[cursor : cursor + size]
        if len(body) != size:
            raise ValueError("truncated git blob")
        try:
            contents[path] = body.decode("utf-8")
        except UnicodeError:
            issues.append({"file": path, "reason": "non-UTF8 source"})
        cursor += size + 1
    return contents, issues


def history(root: Path, sha: str, cutoff: int, days: int) -> list[dict]:
    start = cutoff - days * 86400
    raw = git(
        root,
        "log",
        "--no-merges",
        f"--since-as-filter=@{start}",
        f"--until=@{cutoff}",
        "--format=%x1e%H%x00%ct%x00%s",
        "--name-only",
        "-z",
        "--no-renames",
        sha,
    )
    commits = []
    for record in raw.decode("utf-8").split("\x1e"):
        if not record.strip("\n\0"):
            continue
        fields = record.split("\0")
        if len(fields) < 3:
            raise ValueError("malformed git history")
        oid, epoch, subject = fields[:3]
        if not start <= int(epoch) <= cutoff:
            continue
        match = re.match(r"^(fix|feat|refactor|test|style)(?:\([^\n()]*\))?!?:", subject, re.I)
        kind = match.group(1).lower() if match else "unknown"
        paths = [radar_remote.safe_path(p.lstrip("\n")) for p in fields[3:] if p.strip("\n")]
        commits.append({"id": oid, "epoch": int(epoch), "kind": kind, "files": paths})
    return commits


def worktrees(root: Path) -> list[dict[str, str]]:
    records = git(root, "worktree", "list", "--porcelain", "-z").decode("utf-8").split("\0\0")
    entries = []
    for record in records:
        entry = {}
        for field in record.split("\0"):
            key, _, value = field.partition(" ")
            if key:
                entry[key] = value
        if entry:
            entries.append(entry)
    return entries


def path_records(raw: bytes) -> list[str]:
    return [radar_remote.safe_path(p.decode("utf-8")) for p in raw.split(b"\0") if p]


def landed_blobs(root: Path, sha: str, bases: set[str]) -> dict[str, set[str]]:
    """Every (path -> blob) the target's history wrote since the oldest worktree base.

    A squash-merged branch never becomes an ancestor of the target, so only content can show that
    its change landed: its blob for a path appears among the blobs the target wrote to that path."""
    oldest = min(bases, key=lambda b: int(text(root, "show", "-s", "--format=%ct", b) or 0))
    raw = git(root, "log", "--raw", "--no-renames", "--no-abbrev", "--format=", "-z", sha, f"^{oldest}")
    seen: dict[str, set[str]] = {}
    fields = iter(raw.split(b"\0"))
    for field in fields:
        # Raw records are ":<modes> <old> <new> <status>" followed by the path; anything else is a
        # commit separator.
        parts = field.lstrip(b"\n").decode("utf-8", "replace").split()
        if len(parts) >= 5 and parts[0].startswith(":"):
            path = next(fields, b"").decode("utf-8", "replace")
            seen.setdefault(path, set()).add(parts[3])
    return seen


def blobs_at(root: Path, commit: str, paths: set[str]) -> dict[str, str]:
    found = {}
    ordered = sorted(paths)
    for start in range(0, len(ordered), 500):  # bounded argv
        raw = git(root, "ls-tree", "-r", "-z", commit, "--", *ordered[start:start + 500])
        for record in raw.split(b"\0"):
            if record:
                header, _, path = record.partition(b"\t")
                found[path.decode("utf-8", "replace")] = header.split()[2].decode()
    return found


def local_busy(root: Path, sha: str) -> dict:
    evidence: dict = {"complete": True, "paths": [], "hints": [], "errors": []}
    try:
        entries = worktrees(root)
    except ValueError as err:
        return dict(evidence, complete=False, errors=[str(err)])
    committed: list[tuple[str, str, set[str], str]] = []  # (branch, head, candidate paths, base)
    for wt in entries:
        checkout = Path(wt["worktree"])
        if not checkout.exists() or "bare" in wt:
            evidence["complete"] = False
            evidence["errors"].append("worktree unavailable; consult PR/contract before release")
            continue
        try:
            evidence["paths"].extend(
                path_records(git(checkout, "diff", "--name-only", "--no-renames", "-z", "HEAD", "--"))
            )
            evidence["paths"].extend(
                path_records(git(checkout, "ls-files", "--others", "--exclude-standard", "-z"))
            )
            head = wt.get("HEAD", "")
            # Names are ephemeral hints, not product/candidate identity or reservations.
            branch = wt.get("branch", "").removeprefix("refs/heads/")
            if head == sha:
                if branch:
                    evidence["hints"].append(branch)
                continue
            base = text(root, "merge-base", sha, head)
            # Pending = changed by the branch AND still different from the target. A squash-merged
            # branch keeps its old merge-base, so merge-base..HEAD alone lists every landed file.
            changed = path_records(git(root, "diff", "--name-only", "--no-renames", "-z", base, head, "--"))
            if changed:
                differs = path_records(
                    git(root, "diff", "--name-only", "--no-renames", "-z", sha, head, "--"))
                candidates = set(changed) & set(differs)
                if candidates:
                    committed.append((branch, head, candidates, base))
        except (ValueError, OSError) as err:
            evidence["complete"] = False
            evidence["errors"].append(str(err))
    if committed:
        try:
            # ...and whose branch version never reached the target (it may have moved on since).
            landed = landed_blobs(root, sha, {base for *_, base in committed})
            for branch, head, candidates, _ in committed:
                at_head = blobs_at(root, head, candidates)
                pending = {p for p in candidates if at_head.get(p) not in landed.get(p, set())}
                evidence["paths"].extend(pending)
                if branch and pending:
                    evidence["hints"].append(branch)
        except (ValueError, OSError) as err:
            # Without the landed check every candidate stays BUSY: conservative, never FREE.
            evidence["complete"] = False
            evidence["errors"].append(str(err))
            for branch, _, candidates, _ in committed:
                evidence["paths"].extend(candidates)
                if branch:
                    evidence["hints"].append(branch)
    evidence["paths"] = sorted(set(evidence["paths"]))
    evidence["hints"] = sorted(set(evidence["hints"]))
    return evidence


def collect_busy(root: Path, sha: str, cfg: dict, disabled: bool) -> dict:
    repo_id, url = repo_identity(root, cfg)
    local = local_busy(root, sha)
    prs = radar_remote.collect(root, cfg, disabled, url)
    return {
        "schema": 1,
        "repo_id": repo_id,
        "sha": sha,
        "captured_at": int(datetime.now(timezone.utc).timestamp()),
        "complete": local["complete"] and prs["complete"],
        "paths": sorted(set(local["paths"] + prs["paths"])),
        "hints": local["hints"],
        "local": local,
        "remote": prs,
    }
