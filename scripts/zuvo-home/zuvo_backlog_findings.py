"""THE FINDINGS LEDGER of `backlog-add`: every finding at conf >= FLOOR, kept as data, whether or not
it became a backlog entry. Not a script, no shebang, no executable bit.

WHERE. `dirname(REAL backlog)/findings/` — beside the backlog `zuvo_backlog_io.resolve` names, so it
follows the same rule: a tracked backlog is branch content (the current checkout's copy), an ignored
one is shared through the main checkout, and a symlinked one is followed to its realpath (a ledger
beside the link would fork from the backlog it describes).

SEGMENTS, `<YYYY-MM-DD>_<branch-slug>_<host>.jsonl`. One file per day, branch and host means two
branches never edit the same file (GitHub applies no merge drivers, so a shared file conflicts on
every merge), the Mac and ryzen never clobber each other through ccsync, and no file grows without
bound. `_` is the separator, so it never appears inside a slug. Making a branch or host name safe
can lose characters (`feat/x`, `feat_x` and `feat-x` all read `feat-x`; a long name is cut); when it
does, `-<sha1(raw)[:6]>` is appended, so distinct names never share a segment.

APPEND-ONLY, three line kinds, each one JSON object with `v`, `id` (the F-id) and `ts`:
  * a FULL RECORD (it has `class`) — exactly RECORD_KEYS, schema v1, field names taken from dup-map
    where they overlap;
  * a SIGHTING (`sighting: {source, sha, branch, pr}`) — the finding was reported again;
  * a STATUS PATCH (`status`, `backlog`, `note`) — a later decision about it.

THE FOLD (`fold`) reads every segment and orders events by (`ts`, segment name, line index), so a tie
breaks the same way within a segment and across segments. `ts` is compared as a STRING, so it has
exactly one spelling: canonical UTC `YYYY-MM-DDTHH:MM:SS+00:00`. The builders normalise any `ts` they
are given through `canonical_ts`; a line read with any other spelling is a `bad-record`, not an event.
  * `seen` counts EVENTS — every full record and every sighting line, in every segment. An absolute
    counter stored per branch would undercount when two branch lineages merge.
  * the latest full record supplies the fields; patches apply AFTER all full records, in event order,
    so a patch older than its record (Mac and ryzen clocks skew) still applies.
  * nothing here raises on bad data. Every problem is a named `Defect` whose kind is one of
    DEFECT_KINDS (a torn tail, bad or too deeply nested JSON, an unknown `v`, an out-of-schema line or
    field type, an unknown line kind, a status outside STATUSES, an orphan patch or sighting, an
    unreadable segment or findings path), and every other line still folds. A finding is data, so
    one corrupt line must not cost the rest.

THE LAST LINE OF A SEGMENT WITHOUT A NEWLINE. If it parses as a complete JSON value it is folded like
any other line (the write completed, only its terminator did not); if it does not, it is a `torn-tail`
defect and is not applied. `append_line` terminates such a tail before it writes, and that changes
nothing the fold reports about it: a complete tail stays applied, and a partial one becomes a
`bad-json` line that stays unapplied — it never glues onto the new line.

VISIBILITY (`check_visibility`) asks git about the SEGMENT path, never the bare directory:
`git check-ignore memory/findings` answers "not ignored" while the directory is absent even when
`/memory/findings/` is in `.gitignore`. Git is asked from the nearest EXISTING ancestor, because it
answers for paths that do not exist yet, so the check creates nothing. The rule itself is
`zuvo_backlog_ledger.tracked_beside_ignored`, shared with the verdict ledger rather than copied.

CONCURRENCY. Nothing here locks. Writers are serialised by the CALLER holding
`zuvo_backlog_io.Lock` on the backlog's directory (`zuvo_backlog_add` does, for the whole
fold-check-write sequence); `check_visibility` only reads, so concurrent calls are safe.

Imports the parser only through its siblings and never iterates entries, so H19c in
test-backlog-headings.sh does not count this module. No module-level name starts with `RC_`.
"""
from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
import socket
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import IO, Any, Dict, FrozenSet, List, Mapping, NamedTuple, Optional, Tuple

import zuvo_backlog_admit as adm
import zuvo_backlog_io as zio
import zuvo_backlog_ledger as zl

SCHEMA_VERSION = 1
FINDINGS_DIRNAME = "findings"

# Closed. Part 3's dup-map export maps `fixed` -> `merged`; nothing else is ever written.
STATUSES: FrozenSet[str] = frozenset({"found", "ticketed", "fixed", "refuted", "kept"})
RECORD_KEYS: FrozenSet[str] = frozenset({
    "v", "id", "ts", "class", "confidence", "severity", "title", "how", "fix", "anchor", "files", "target",
    "area", "agent", "source", "branch", "pr", "sha", "route", "reason", "backlog", "status", "forced"})
SIGHTING_KEYS: FrozenSet[str] = frozenset({"v", "id", "ts", "sighting"})
PATCH_KEYS: FrozenSet[str] = frozenset({"v", "id", "ts", "status", "backlog", "note"})
LINE_KINDS: FrozenSet[str] = frozenset({"record", "sighting", "patch"})

# Every Defect the fold emits uses one of these names, and nothing else (a test asserts both ways).
D_TORN, D_BAD_JSON, D_UNKNOWN_V, D_BAD_RECORD = "torn-tail", "bad-json", "unknown-v", "bad-record"
D_BAD_STATUS, D_UNKNOWN_KIND, D_ORPHAN, D_UNREADABLE = "bad-status", "unknown-kind", "orphan", "unreadable"
DEFECT_KINDS: FrozenSet[str] = frozenset({
    D_TORN, D_BAD_JSON, D_UNKNOWN_V, D_BAD_RECORD, D_BAD_STATUS, D_UNKNOWN_KIND, D_ORPHAN, D_UNREADABLE})

# Keys `record_for` takes from `meta`; anything else would overwrite the record's core fields.
META_KEYS: FrozenSet[str] = frozenset({"area", "agent", "branch", "pr", "sha"})

REFUSED_TRACKED = "tracked-findings-beside-ignored-backlog"
# Git could not answer (an error other than "not a repository", or a timeout): refused, never assumed.
REFUSED_UNKNOWN = "findings-visibility-unknown"
GIT_TIMEOUT_S = 10.0        # ONE deadline for the whole check, not per git call
# Repo-locating variables outrank `git -C`: inherited from a hook they would answer for another repo.
_GIT_REPO_VARS = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_CEILING_DIRECTORIES", "GIT_COMMON_DIR")
VISIBILITY_RECIPE = (
    "refusing to create a git-TRACKED findings ledger beside a git-IGNORED backlog.\nthe ledger quotes "
    "the findings it keeps, so publishing it publishes content that was\ndeliberately untracked. add "
    f"these lines to .gitignore first, then re-run:\n    /memory/{FINDINGS_DIRNAME}/\n"
    f"    /memory/{zio.LOCK_NAME}/\na segment already committed stays tracked whatever .gitignore says: "
    f"untrack it with\ngit rm -r --cached memory/{FINDINGS_DIRNAME}")

_FID_RE = re.compile(r"F-[0-9a-f]{12}")
_SHA_RE = re.compile(r"[0-9a-f]{7,40}")
_UNSAFE_RE = re.compile(r"[^A-Za-z0-9.-]+")    # `_` included: it separates the segment-name fields
_SLUG_CAP = 60
_DETAIL_CAP = 120
_UTC = datetime.timezone.utc
_TS_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+00:00")    # the only `ts` the fold orders
_NONE = type(None)
# Field types the fold and its consumers rely on; a wrong type is a `bad-record`, never applied.
_FIELD_TYPES: Dict[str, Dict[str, Tuple[type, ...]]] = {
    "record": {"class": (str,), "files": (list,), "backlog": (str, _NONE), "forced": (bool,),
               "confidence": (int, _NONE), "title": (str, _NONE), "source": (str, _NONE)},
    "sighting": {"sighting": (dict,)}, "patch": {"backlog": (str, _NONE), "note": (str,)}}
_SIGHTING_TYPES: Dict[str, Tuple[type, ...]] = {
    "source": (str,), "sha": (str, _NONE), "branch": (str, _NONE), "pr": (int, _NONE)}


class Defect(NamedTuple):
    where: str      # `<segment>:<line>`
    kind: str       # one of DEFECT_KINDS
    detail: str


@dataclass
class Record:
    """One folded finding: the latest full record's fields with every patch applied."""
    fields: Dict[str, Any]
    seen: int
    note: str = ""


class _Event(NamedTuple):
    kind: str                       # one of LINE_KINDS
    key: Tuple[str, str, int]       # (ts, segment name, line index): the total fold order
    where: str
    obj: Dict[str, Any]


# ── location and visibility ──────────────────────────────────────────────────────────────────────

def ledger_dir(repo: str) -> Path:
    """`findings/` beside the REAL backlog of `repo` (see WHERE above)."""
    _, real, _ = zio.resolve(repo)
    return Path(os.path.dirname(real)) / FINDINGS_DIRNAME


class _GitUnanswered(Exception):
    """Git ran but gave no usable answer, or did not finish before the check's deadline."""


def _git(cwd: Path, deadline: float, *args: str) -> "subprocess.CompletedProcess[str]":
    left = deadline - time.monotonic()
    if left <= 0:
        raise _GitUnanswered(f"git {args[0]}: the {GIT_TIMEOUT_S:g}s visibility deadline passed")
    env = {k: v for k, v in os.environ.items() if k not in _GIT_REPO_VARS}
    env["LC_ALL"] = "C"
    try:
        return subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True,
                              timeout=left, check=False, env=env)
    except (OSError, subprocess.SubprocessError) as exc:
        raise _GitUnanswered(f"git {args[0]}: {exc}") from exc


def _nearest_dir(path: Path) -> Path:
    here = path.parent
    while not here.is_dir():            # terminates: the filesystem root is a directory
        here = here.parent
    return here


def would_be_ignored(path: Path, deadline: Optional[float] = None) -> Optional[bool]:
    """Whether git ignores `path`, which need not exist: True/False inside a work tree, None outside
    any repository. Asked from the nearest EXISTING ancestor, so no directory is created and an
    absent `memory/` is answered like a present one. Raises _GitUnanswered on any other git failure.

    `check-ignore` keeps its default index semantics ON PURPOSE: a segment already committed is
    tracked whatever `.gitignore` says, so appending to it publishes — `--no-index` would hide that."""
    deadline = time.monotonic() + GIT_TIMEOUT_S if deadline is None else deadline
    here = _nearest_dir(path)
    try:
        rel = os.path.relpath(path, here)
    except ValueError as exc:
        raise _GitUnanswered(f"no relative path from {here}: {exc}") from exc
    inside = _git(here, deadline, "rev-parse", "--is-inside-work-tree")
    if inside.returncode != 0:
        if "not a git repository" in inside.stderr:
            return None
        raise _GitUnanswered(f"rev-parse rc={inside.returncode}: {inside.stderr.strip()[:_DETAIL_CAP]}")
    if inside.stdout.strip() != "true":
        return None                     # inside a .git directory: not a work tree
    probe = _git(here, deadline, "check-ignore", "-q", "--", rel)
    if probe.returncode not in (0, 1):
        raise _GitUnanswered(f"check-ignore rc={probe.returncode}: {probe.stderr.strip()[:_DETAIL_CAP]}")
    return probe.returncode == 0


def check_visibility(directory: Path, real_backlog: str, segment_name: str) -> Optional[str]:
    """REFUSED_TRACKED when the backlog is git-ignored and `segment_name` in `directory` would be
    tracked; REFUSED_UNKNOWN when git cannot answer (fail closed); None otherwise, including outside
    any git repository ("unknown repository" is not "tracked").

    Creates nothing, so concurrent calls cannot disturb each other; writers hold `zuvo_backlog_io.Lock`.
    Returns a reason instead of exiting: a refused layout is exit 3 (retrying cannot help), not the
    archiver's exit 1, and the caller can release its lock first.
    """
    if os.sep in segment_name or segment_name in ("", ".", ".."):
        raise ValueError(f"segment name must be a bare file name: {segment_name!r}")
    deadline = time.monotonic() + GIT_TIMEOUT_S
    try:
        tracked = zl.tracked_beside_ignored(would_be_ignored(Path(real_backlog), deadline),
                                            lambda: would_be_ignored(directory / segment_name, deadline))
    except _GitUnanswered:
        return REFUSED_UNKNOWN
    return REFUSED_TRACKED if tracked else None


# ── clock, host and segment name (TD11 test injection: ZUVO_BACKLOG_NOW, ZUVO_BACKLOG_HOST) ──────

def canonical_ts(raw: str) -> str:
    """`raw` as the one `ts` form the fold orders: aware UTC, seconds, `+00:00`. A naive time is read
    as UTC (never as local time), `Z` as `+00:00`. Raises ValueError on anything that is not a time —
    `fold` sorts `ts` as a string, so a second spelling of the same instant would misorder."""
    try:
        at = datetime.datetime.fromisoformat(raw[:-1] + "+00:00" if raw.endswith("Z") else raw)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"not an ISO-8601 time: {raw!r}") from exc
    if at.tzinfo is None:
        at = at.replace(tzinfo=_UTC)
    return at.astimezone(_UTC).isoformat(timespec="seconds")


def now_stamp() -> str:
    """`zuvo_backlog_ledger.now_stamp`, or `ZUVO_BACKLOG_NOW` through `canonical_ts`. An unparseable
    injection is refused, never ignored."""
    raw = os.environ.get("ZUVO_BACKLOG_NOW", "").strip()
    if not raw:
        return zl.now_stamp()
    try:
        return canonical_ts(raw)
    except ValueError as exc:
        raise ValueError(f"ZUVO_BACKLOG_NOW is not an ISO-8601 time: {raw!r}") from exc


def _safe(text: str) -> str:
    return _UNSAFE_RE.sub("-", text).strip("-.")[:_SLUG_CAP].strip("-.")


def _slug(raw: str, fallback: str) -> str:
    """`raw` made file-name safe. When that LOSES anything (a character replaced, the name cut), a
    6-hex sha1 of `raw` is appended, so `feat/x`, `feat_x` and `feat-x` never share one segment."""
    safe = _safe(raw)
    if safe == raw or not raw:
        return safe or fallback
    return f"{safe or fallback}-{hashlib.sha1(raw.encode('utf-8')).hexdigest()[:6]}"


def host_name() -> str:
    """`ZUVO_BACKLOG_HOST`, else the short host name; file-name safe, never empty."""
    return _slug(os.environ.get("ZUVO_BACKLOG_HOST") or socket.gethostname().split(".")[0], "host")


def branch_slug(branch: Optional[str], sha: str = "") -> str:
    """`main` -> `main`, `feat/x` -> `feat-x-<sha1[:6]>`; detached (`branch` None or empty) ->
    `detached-<sha7>`."""
    if branch:
        return _slug(branch, "branch")
    if not _SHA_RE.fullmatch(sha):
        raise ValueError(f"a detached HEAD needs the commit sha for its segment name, got {sha!r}")
    return f"detached-{sha[:7]}"


def segment_path(directory: Path, now: str, branch: Optional[str], host: str, sha: str = "") -> Path:
    """`<directory>/<YYYY-MM-DD>_<branch-slug>_<host>.jsonl`, dated by the UTC stamp `now`."""
    day = now[:10]
    datetime.date.fromisoformat(day)        # ValueError on a stamp that is not a time
    return directory / f"{day}_{branch_slug(branch, sha)}_{_slug(host, 'host')}.jsonl"


# ── line builders ────────────────────────────────────────────────────────────────────────────────

def _check_status(status: Any, optional: bool) -> None:
    if not (status in STATUSES or (optional and status is None)):
        raise ValueError(f"status {status!r} is outside {sorted(STATUSES)}")


def _base(fid: str, ts: Optional[str]) -> Dict[str, Any]:
    if not isinstance(fid, str) or not _FID_RE.fullmatch(fid):
        raise ValueError(f"not an F-id (F- + 12 hex): {fid!r}")
    return {"v": SCHEMA_VERSION, "id": fid, "ts": now_stamp() if ts is None else canonical_ts(ts)}


def record_line(fields: Mapping[str, Any], ts: Optional[str] = None) -> Dict[str, Any]:
    """A full schema-v1 record: every key of RECORD_KEYS, unset ones None (`files` [], `status`
    found, `forced` False). Raises ValueError on an unknown key, a missing class or id, or a status
    outside STATUSES — a builder that wrote any of those would only move the defect into the fold."""
    unknown = set(fields) - (RECORD_KEYS - {"v", "ts"})
    if unknown:
        raise ValueError(f"keys outside schema v{SCHEMA_VERSION}: {sorted(unknown)}")
    if not fields.get("class"):
        raise ValueError("a full record needs its class")
    rec: Dict[str, Any] = dict.fromkeys(RECORD_KEYS)
    rec.update({"files": [], "status": "found", "forced": False, **fields})
    rec.update(_base(str(fields.get("id", "")), ts))
    _check_status(rec["status"], optional=False)
    return rec


def _cap(text: Optional[str], cap: int) -> Optional[str]:
    return text[:cap] if text else None


def record_for(f: adm.Finding, d: adm.Decision, fid: str, *, backlog: Optional[str] = None,
               ts: Optional[str] = None, meta: Optional[Mapping[str, Any]] = None) -> Dict[str, Any]:
    """The record for one admitted finding. `class` is the ORIGINAL class (the F-id is computed from
    it); the rendered one is in the B-id. `meta` carries only META_KEYS: any other key would
    silently replace a core field (the id, the status), so it raises ValueError."""
    extra = set(meta or {}) - META_KEYS
    if extra:
        raise ValueError(f"meta keys outside {sorted(META_KEYS)}: {sorted(extra)}")
    files = [{"path": f.file, "line": f.line, "note": f.missing_assertion or ""}] if f.file else []
    fields: Dict[str, Any] = {
        "id": fid, "class": f.cls, "confidence": adm.parse_conf(f.conf), "severity": f.severity,
        "title": d.title, "how": _cap(f.evidence, adm.EVIDENCE_CAP), "fix": _cap(f.fix, adm.FIX_CAP),
        "anchor": f.anchor, "files": files, "target": f.target, "source": f.source,
        "route": d.route, "reason": d.reason, "backlog": backlog,
        "status": "ticketed" if backlog else "found", "forced": d.forced}
    fields.update(meta or {})
    return record_line(fields, ts)


def sighting_line(fid: str, *, source: str, sha: Optional[str], branch: Optional[str],
                  pr: Optional[int], ts: Optional[str] = None) -> Dict[str, Any]:
    """One more report of `fid`: one more `seen` on fold."""
    line = _base(fid, ts)
    line["sighting"] = {"source": source, "sha": sha, "branch": branch, "pr": pr}
    return line


def patch_line(fid: str, *, status: Optional[str] = None, backlog: Optional[str] = None,
               note: str = "", ts: Optional[str] = None) -> Dict[str, Any]:
    """A later decision: a new status, a backlog link, or both. A patch changing neither is refused."""
    if status is None and backlog is None:
        raise ValueError("a status patch must set a status or a backlog id")
    _check_status(status, optional=True)
    line = _base(fid, ts)
    line.update(status=status, backlog=backlog, note=note)
    return line


# ── append ───────────────────────────────────────────────────────────────────────────────────────

def _make_dir(directory: Path, backlog: Optional[str]) -> None:
    mode = zl.inherited_mode(os.path.dirname(backlog), str(directory)) if backlog else None
    directory.mkdir(parents=True, exist_ok=True, mode=0o700 if mode is not None else 0o777)
    if mode is not None:
        os.chmod(directory, mode)


def append_line(path: Path, obj: Mapping[str, Any], backlog: Optional[str] = None) -> None:
    """Append one line to a segment, creating its directory. A file that does not end in `\\n` (a
    torn tail) is terminated first, so the new line always parses on its own and the tail folds as it
    did before (see THE LAST LINE above). The line is checked against the schema before any byte is
    written. Not locked here: the caller holds `zuvo_backlog_io.Lock` so appends never interleave.

    `backlog` is the REAL backlog path: a NEW segment takes its mode and a new `findings/` its
    directory's (`zuvo_backlog_ledger.inherited_mode`, as the verdict ledger does), so a 0600 backlog
    is never quoted into a world-readable file. The file is created 0600 and widened, never narrowed
    after the fact. A failed write RAISES (buffered `write` writes all or raises) — never silent — and
    whatever partial line it left is terminated by the next append."""
    kind, detail = _classify(dict(obj))
    if kind not in LINE_KINDS:
        raise ValueError(f"refusing to append an out-of-schema line ({kind}: {detail})")
    data = (json.dumps(obj, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")
    _make_dir(path.parent, backlog)
    mode = zl.inherited_mode(backlog, str(path)) if backlog else None
    fd = os.open(path, os.O_RDWR | os.O_APPEND | os.O_CREAT, 0o600 if mode is not None else 0o666)
    with open(fd, "ab+") as fh:     # owns fd from here: closed on every path below
        if mode is not None:
            os.chmod(path, mode)
        end = fh.seek(0, os.SEEK_END)
        if end:
            fh.seek(end - 1)
            if fh.read(1) != b"\n":
                data = b"\n" + data
        fh.write(data)          # O_APPEND: lands at the end whatever the read position


# ── fold ─────────────────────────────────────────────────────────────────────────────────────────

def _is_v1(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool) and v == SCHEMA_VERSION


def _line_kind(obj: Dict[str, Any]) -> str:
    if "class" in obj:
        return "record"
    if "sighting" in obj:
        return "sighting"
    return "patch" if "status" in obj or "backlog" in obj else ""


def _typed(value: Any, types: Tuple[type, ...]) -> bool:
    return isinstance(value, types) and not (isinstance(value, bool) and bool not in types)


def _wrong_types(kind: str, obj: Dict[str, Any]) -> List[str]:
    wrong = [k for k, t in _FIELD_TYPES[kind].items() if not _typed(obj[k], t)]
    sight = obj.get("sighting")
    if kind == "sighting" and isinstance(sight, dict):
        if set(sight) != set(_SIGHTING_TYPES):
            return [f"sighting keys {sorted(sight)}"]
        wrong += [f"sighting.{k}" for k, t in _SIGHTING_TYPES.items() if not _typed(sight[k], t)]
    return wrong


def _classify(obj: Any) -> Tuple[str, str]:
    """(line kind, "") for a valid line, else (defect kind, detail)."""
    if not isinstance(obj, dict):
        return D_BAD_JSON, "not a JSON object"
    if not _is_v1(obj.get("v")):
        return D_UNKNOWN_V, f"v={obj.get('v')!r}"
    if not (isinstance(obj.get("id"), str) and _FID_RE.fullmatch(obj["id"])
            and isinstance(obj.get("ts"), str) and _TS_RE.fullmatch(obj["ts"])):
        return D_BAD_RECORD, "id is not an F-id, or ts is not canonical UTC (YYYY-MM-DDTHH:MM:SS+00:00)"
    kind = _line_kind(obj)
    if not kind:
        return D_UNKNOWN_KIND, "neither a record, a sighting nor a status patch"
    want = {"record": RECORD_KEYS, "sighting": SIGHTING_KEYS, "patch": PATCH_KEYS}[kind]
    if set(obj) != want:
        return D_BAD_RECORD, f"{kind} keys differ from schema v1: {sorted(set(obj) ^ want)}"
    wrong = _wrong_types(kind, obj)
    if wrong:
        return D_BAD_RECORD, f"{kind} field types differ from schema v1: {wrong}"
    status = obj.get("status")
    if kind != "sighting" and not (status in STATUSES or (kind == "patch" and status is None)):
        return D_BAD_STATUS, f"status {status!r} is outside the closed set"
    return kind, ""


def _parse(where: str, line: str, events: List[_Event], defects: List[Defect],
           key: Tuple[str, int]) -> None:
    """One line. A last line without `\\n` that does not parse is a torn tail, not bad JSON: the
    write died mid-line. Once terminated it is an ordinary line, and then it IS bad JSON."""
    try:
        obj = json.loads(line)
    except (ValueError, RecursionError) as exc:     # a deeply nested line is bad data, not a crash
        torn = not line.endswith("\n")
        defects.append(Defect(where, D_TORN if torn else D_BAD_JSON,
                              "the last line has no newline and does not parse: a write died" if torn
                              else str(exc)[:_DETAIL_CAP]))
        return
    kind, detail = _classify(obj)
    if kind in LINE_KINDS:
        events.append(_Event(kind, (obj["ts"], key[0], key[1]), where, obj))
    else:
        defects.append(Defect(where, kind, detail))


def _read_lines(fh: IO[str], name: str, events: List[_Event], defects: List[Defect]) -> None:
    for i, line in enumerate(fh, start=1):
        if line.strip():
            _parse(f"{name}:{i}", line, events, defects, (name, i))


def _read_segment(path: Path, events: List[_Event], defects: List[Defect]) -> None:
    try:
        # O_NONBLOCK: a FIFO with a segment's name reads as empty instead of blocking under the lock.
        with open(os.open(path, os.O_RDONLY | os.O_NONBLOCK), encoding="utf-8", errors="replace",
                  newline="\n") as fh:
            _read_lines(fh, path.name, events, defects)
    except OSError as exc:
        defects.append(Defect(path.name, D_UNREADABLE, str(exc)[:_DETAIL_CAP]))


def _apply(rec: Record, patch: Dict[str, Any]) -> None:
    for key in ("status", "backlog"):
        if patch[key] is not None:
            rec.fields[key] = patch[key]
    if patch["note"]:
        rec.note = str(patch["note"])


def fold(directory: Path) -> Tuple[Dict[str, Record], List[Defect]]:
    """Every segment in `directory`, folded by F-id (see THE FOLD above). An absent directory folds
    to nothing; a path that exists but is not a directory is an `unreadable` defect, never an empty
    history. Defects are returned, never raised."""
    events: List[_Event] = []
    defects: List[Defect] = []
    if directory.exists() and not directory.is_dir():
        defects.append(Defect(directory.name, D_UNREADABLE, "the findings path is not a directory"))
    if directory.is_dir():
        for seg in sorted(directory.glob("*.jsonl")):
            _read_segment(seg, events, defects)
    events.sort(key=lambda e: e.key)
    records: Dict[str, Record] = {}
    for ev in events:
        if ev.kind == "record":
            prior = records.get(ev.obj["id"])
            records[ev.obj["id"]] = Record(dict(ev.obj), (prior.seen if prior else 0) + 1)
    for ev in events:
        rec = records.get(ev.obj["id"])
        if ev.kind == "record":
            continue
        if rec is None:
            defects.append(Defect(ev.where, D_ORPHAN, f"{ev.kind} for {ev.obj['id']} with no record"))
        elif ev.kind == "sighting":
            rec.seen += 1
        else:
            _apply(rec, ev.obj)
    return records, defects
