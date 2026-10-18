"""THE `backlog-add` COMMAND: the one write path for `memory/backlog.md` and the findings ledger beside it.
Run through the `backlog-add` launcher; not a script itself, no shebang, no executable bit.

ONE CALL, ONE FINDING, ONE LOCK. Everything that can be decided from the arguments and the work tree is
decided BEFORE the lock (validation, the cited site, the tag, the changed lines, the bars), so a refused
finding never waits for another writer. Everything that depends on what other writers did is decided
UNDER `zuvo_backlog_io.Lock` on the backlog's directory, in this order and no other:

  1. the ledger visibility check (`zuvo_backlog_findings.check_visibility`): under the lock because
     another writer may be creating the very segment it asks about;
  2. the ledger fold, which gives the finding's record and its `seen`;
  3. at most two `lookup`s: the B-id (the one already on the record, else the derived one), and only
     when that is ABSENT, the legacy text `<path>:<line> — <title>`;
  4. the backlog write — a bump in place, a REGRESSION append or a new entry; none at all when the
     entry is LEGACY (not in this command's own format: a hand-written line, a REGRESSION re-open, an
     id only a heading carries), which is linked in the ledger and its text never edited — then the
     ledger append.

Backlog before ledger: a crash between the two leaves an entry with no record, and the next sighting
finds the entry by its `id:` key and writes the record then. The reverse order would leave a record
claiming an entry that does not exist. A lookup outside the lock would let two writers both see ABSENT
and file the same finding twice, which is the race this command exists to close. A ledger that is
KNOWN unusable (an unreadable segment, a `findings` path that is not a directory, no write permission)
refuses before the backlog is touched; what remains is a failure DURING the ledger append (disk full),
after which stderr names the backlog path already written.

`seen` COUNTS EVENTS (`fold`: full records plus sightings), so the FIRST call writes exactly one full
record and no sighting; every later call writes one sighting. A status patch is written only when the
record's backlog link or status changes, or when ZUVO_BACKLOG_ADMIT forced the route (every forced
sighting is recorded, see below). The two counts are independent after a crash heal: the entry's
`seen:` keeps counting bumps, the healed ledger restarts at 1. The ledger's sites (`files[]`) are those
of the FIRST sighting; `--also` on a later one is reported on stderr as not recorded (a sighting line
has no sites). A line-level ledger defect (a torn tail, bad JSON) is reported and the fold goes on: the
B-id derives from the F-id, so a lost record re-finds its own-format entry and only undercounts `seen`.
An id-less legacy entry is reported by its lookup key (`fp:…`) but never stored as the link: a key is
not an id, so every sighting re-resolves it through the text lookup instead.

THE LOCK BUDGET. A waiter gives up after ZUVO_LOCK_WAIT (the launcher defaults it to 30 s), so one
holder's worst case must fit inside it: the visibility check is bounded by its own deadline (10 s)
and each lookup gets a share of what is left (`_lookup_timeout`), never less than 2 s — so the
guarantee holds for ZUVO_LOCK_WAIT >= 16 s (the default 30 s fits; a smaller wait is a test's choice).
The fold and the writes are not bounded (a 10 MB ledger folds well under 5 s). The `ts` and the
segment are taken AFTER the lock is acquired, so ledger order is write order; the `git check-ignore`
probes behind `wrote=` run after it is released.

WHAT IS PRINTED. Exactly one verdict line on stdout (or the same fields as one JSON object with
`--json`), and the exit code in EXIT_CODES. `wrote=` names the repo-relative paths written that git
does not ignore, so a committing skill stages exactly those and never `git add`s an ignored path.
`--dry-run` writes nothing, so it prints `wrote=-`, and reads under the lock when the backlog's
directory exists (without it there is nothing to read or race with).
Diagnostics go to stderr. A lock timeout, an IO error, a line the parser would not see and a lookup
that gave no trustworthy answer are all exit 1 (see EXIT_CODES for the one partial case).

`ZUVO_BACKLOG_ADMIT=1` is read here and nowhere else: an env var, never a flag, so it is not part of
the argument surface a skill composes; it is set only when the user's own message asked for the entry.
Every write it forces is recorded: a FIRST sighting's full record carries `forced: true` and
`reason: forced`; a later sighting of a known finding gets a status patch (`status: ticketed`,
`backlog: <B-id>`) whose `note` is `forced (natural: <the reason the bars gave>)`, which the fold
keeps as the record's note — the record's own `forced`/`reason` stay those of its first sighting.
The verdict's `--json` carries `forced: true` either way.

No module-level name starts with `RC_` (test-backlog-grooming.sh scans those across every
`zuvo_backlog_*.py` as exit-code registry entries; these are not in that registry). The parser is
imported only for `definition_id`; its entry iterator is never called here (H19c's `*)` arm).
"""
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, NamedTuple, Optional, Sequence, Set, Tuple

import zuvo_backlog_admit as adm
import zuvo_backlog_entry as ent
import zuvo_backlog_findings as fnd
import zuvo_backlog_io as zio
import zuvo_backlog_lookup as lk
import zuvo_backlog_parse as zb
import zuvo_backlog_similar as sim
import zuvo_backlog_vcs as vcs

# The verdict keywords, in the order the protocol documents them. `main` prints no other first word.
VERDICTS: Tuple[str, ...] = ("ACCEPTED", "BUMPED", "REOPENED", "LEDGER", "LEDGER-BUMPED", "DISCARDED",
                             "REFUSED")
EXIT_OK, EXIT_FAILED, EXIT_USAGE, EXIT_REFUSED = 0, 1, 2, 3
# Exit 1, never a traceback: what may fail once the arguments are valid.
EXIT_CODES: Dict[int, str] = {
    EXIT_OK: "ACCEPTED, BUMPED, REOPENED, LEDGER, LEDGER-BUMPED or DISCARDED",
    EXIT_REFUSED: "REFUSED <reason>: the input does not conform; correct it, retrying unchanged cannot help",
    EXIT_USAGE: "usage error",
    EXIT_FAILED: "lock timeout, IO error, render-invisible, lookup failure or incomplete install: nothing "
                 "written, except an IO error during the ledger append after the backlog write, when "
                 "stderr names the backlog path already written as wrote=",
}
ADMIT_ENV = "ZUVO_BACKLOG_ADMIT"
_FAILURES = (OSError, ValueError, lk.LookupFailed, ent.RenderInvisible)
# Test-only (TD11): one line is appended to this file immediately before the lock is requested, so a
# concurrency test knows every writer is AT the lock rather than guessing with a sleep.
READY_ENV = "ZUVO_BACKLOG_READY_FILE"
REFUSED_BAD_PR = "bad-pr"
STATUS_TICKETED = "ticketed"


class Result(NamedTuple):
    verdict: str                    # one of VERDICTS
    code: int = EXIT_OK
    backlog: Optional[str] = None   # the B-id (or a legacy entry's key) the finding is linked to
    ledger: Optional[str] = None    # the F-id
    seen: Optional[int] = None
    reason: Optional[str] = None
    legacy: bool = False            # linked to an entry not in backlog-add's own format; text untouched
    wrote: Tuple[str, ...] = ()
    forced: bool = False            # ZUVO_BACKLOG_ADMIT=1 changed the route


@dataclasses.dataclass
class _Call:
    """Everything decided before the lock, plus what the locked sequence wrote."""
    repo: str
    f: adm.Finding
    d: adm.Decision
    fid: str
    tag: vcs.Tag
    meta: Dict[str, Any]
    also: List[Dict[str, Any]]
    natural: str                    # the bars' own reason when ZUVO_BACKLOG_ADMIT changed the route
    real: str                       # the REAL backlog path
    archive: str
    ledger: Path
    dry: bool
    now: str = ""                   # `now` and `segment` are set once the lock is held
    segment: Path = Path()
    written: List[str] = dataclasses.field(default_factory=list)

    @property
    def today(self) -> str:
        """The LOCAL day, as backlog-archive.py dates its sections; the ledger stamp itself stays UTC."""
        return dt.datetime.fromisoformat(self.now).astimezone().date().isoformat()


class _Refused(Exception):
    """A non-conforming input found before the lock: exit 3 with this reason."""


# ── arguments ────────────────────────────────────────────────────────────────────────────────────

def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="backlog-add", allow_abbrev=False,
                                description="Persist ONE finding: the backlog when it clears the bars, "
                                            "the findings ledger always (conf >= 26).")
    p.add_argument("--class", dest="cls", help="BUG SEC DATA DUP CPLX SIZE PERF DEAD READ CQ TEST-GAP "
                                               "MUTATION PROCESS ADVISORY")
    for name in ("conf", "file", "line", "anchor", "target", "title", "evidence", "fix", "severity",
                 "source", "missing-assertion", "pr", "repo"):
        p.add_argument(f"--{name}")
    p.add_argument("--also", action="append", default=[], metavar="PATH:LINE",
                   help="another site of the same finding (DUP), kept in the record's files[]")
    p.add_argument("--dry-run", action="store_true", help="write nothing; print the verdict it would give")
    p.add_argument("--json", action="store_true", help="the verdict as one JSON object")
    return p


def _finding(a: argparse.Namespace) -> adm.Finding:
    return adm.Finding(cls=a.cls or "", conf=a.conf, source=a.source or "", title=a.title or "",
                       file=a.file, line=a.line, anchor=a.anchor, target=adm.canonical_target(a.target),
                       evidence=a.evidence, fix=a.fix, severity=a.severity,
                       missing_assertion=a.missing_assertion)


def _toplevel(repo: str) -> Optional[str]:
    """The checkout `repo` is in, so `--file` is read repo-relative from any subdirectory; None outside
    a git work tree (no branch, no tag, no work-tree anchor: nothing here can hold)."""
    return vcs.toplevel(repo)


# ── before the lock ──────────────────────────────────────────────────────────────────────────────

def _site(repo: str, raw: adm.Finding) -> adm.Finding:
    """`raw` with its file repo-relative and its line an int, once validation and the work tree accept
    it. Raises _Refused. The path is normalised BEFORE `validate`, which refuses absolute paths."""
    rel = vcs.normalize_path(repo, raw.file) if raw.file and raw.file.strip() else None
    f = dataclasses.replace(raw, file=rel) if rel is not None else raw
    reason = adm.validate(f)
    if reason is None and f.file and f.file.strip():
        line = adm.parse_line(f.line) or 0      # validate refused every line parse_line rejects
        reason = "path-outside-repo" if rel is None else vcs.check_site(repo, rel, line, f.anchor)
        f = dataclasses.replace(f, line=line)
    if reason is not None:
        raise _Refused(reason)
    return f


def _also(repo: str, specs: Sequence[str]) -> List[Dict[str, Any]]:
    """Each `--also PATH:LINE` as a files[] entry, held to the same work-tree rule as `--file`."""
    out: List[Dict[str, Any]] = []
    for spec in specs:
        path, sep, text = spec.rpartition(":")
        rel = vcs.normalize_path(repo, path) if sep else None
        line = adm.parse_line(text)
        if not sep or line is None:
            raise _Refused("line-out-of-range" if sep else "bad-path")
        reason = "path-outside-repo" if rel is None else vcs.check_site(repo, rel, line, None)
        if reason is not None:
            raise _Refused(reason)
        out.append({"path": rel, "line": line, "note": ""})
    return out


def _tag(repo: str, pr: Optional[str]) -> vcs.Tag:
    try:
        return vcs.resolve_tag(repo, pr)
    except ValueError as exc:               # --pr / ZUVO_BACKLOG_PR that is not a PR number
        raise _Refused(REFUSED_BAD_PR) from exc


def _untaggable(d: adm.Decision, tag: vcs.Tag) -> adm.Decision:
    """A branch the intake cannot resolve, with no PR: never a silently untagged non-SEC entry (it would
    be ticketed at once, before the branch merges), so it stays in the ledger. SEC lands untagged, so
    the intake tickets it at once, and the record says why it has no tag."""
    if d.route != adm.ROUTE_BACKLOG or tag.kind != vcs.TAG_UNTAGGABLE:
        return d
    if d.cls == "SEC":
        return d._replace(reason="branch-untaggable")
    return d._replace(route=adm.ROUTE_LEDGER, reason="branch-untaggable", forced=False)


def _prepare(a: argparse.Namespace, repo: str) -> _Call | Result:
    try:
        f = _site(repo, _finding(a))
        also = _also(repo, a.also)
        tag = _tag(repo, a.pr)
    except _Refused as exc:
        return Result("REFUSED", EXIT_REFUSED, reason=str(exc))
    changed: Set[int] = set()
    if f.missing_assertion and f.file and f.cls in adm.PROMOTABLE_CLASSES:
        changed = vcs.changed_lines(repo, f.file)
    d = adm.decide(f, changed, os.environ.get(ADMIT_ENV, "").strip() == "1")
    natural = adm.decide(f, changed, False).reason if d.forced else ""
    if d.route == adm.ROUTE_REFUSED:
        return Result("REFUSED", EXIT_REFUSED, reason=d.reason)
    if d.route == adm.ROUTE_DISCARDED:
        return Result("DISCARDED", reason=d.reason)
    branch, sha = vcs.current_branch(repo), vcs.head_sha7(repo)
    _, real, archive = zio.resolve(repo)
    pr = int(tag.value) if tag.kind == vcs.TAG_PR else None
    return _Call(repo=repo, f=f, d=_untaggable(d, tag), fid=adm.fingerprint(f), tag=tag,
                 meta={"branch": branch, "sha": sha, "pr": pr}, also=also, natural=natural, real=real,
                 archive=archive, ledger=fnd.ledger_dir(repo), dry=a.dry_run)


# ── writes (each one records its path once written; a dry run writes and records nothing) ─────────

def _write_backlog(c: _Call, text: str) -> None:
    if c.dry:
        return
    mode = os.stat(c.real).st_mode & 0o7777 if os.path.exists(c.real) else None
    zio.atomic_write(c.real, text, mode)
    c.written.append(c.real)


def _append_backlog(c: _Call, line: str) -> None:
    text = zio.read(c.real)
    _write_backlog(c, text + ("\n" if text and not text.endswith("\n") else "") + line + "\n")


def _append_ledger(c: _Call, obj: Dict[str, Any]) -> None:
    if not c.dry:
        fnd.append_line(c.segment, obj, backlog=c.real)
        c.written.append(str(c.segment))


def _ledger_write(c: _Call, rec: Optional[fnd.Record], link: Optional[str]) -> int:
    """The first sighting is ONE full record; every later one is a sighting line, plus a patch when the
    backlog link or the status changes. Returns the folded `seen` after this call."""
    if rec is None:
        line = fnd.record_for(c.f, c.d, c.fid, backlog=link, ts=c.now, meta=c.meta)
        line["files"] = [*line["files"], *c.also]
        _append_ledger(c, line)
        return 1
    if c.also:
        print("backlog-add: --also not recorded: the ledger keeps the sites of the first sighting",
              file=sys.stderr)
    _append_ledger(c, fnd.sighting_line(c.fid, source=c.f.source, sha=c.meta["sha"],
                                        branch=c.meta["branch"], pr=c.meta["pr"], ts=c.now))
    changed = rec.fields.get("backlog") != link or rec.fields.get("status") != STATUS_TICKETED
    note = f"forced (natural: {c.natural})" if c.d.forced else ""
    if link is not None and (changed or note):
        _append_ledger(c, fnd.patch_line(c.fid, status=STATUS_TICKETED, backlog=link, note=note, ts=c.now))
    return rec.seen + 1


# ── the backlog route ────────────────────────────────────────────────────────────────────────────

def _conf(c: _Call) -> int:
    return adm.parse_conf(c.f.conf) or 0       # validate refused every conf parse_conf rejects


def _lookup_timeout() -> float:
    """Each of the two lookups' share of the lock budget left after the visibility deadline."""
    return max(2.0, (zio.LOCK_WAIT - fnd.GIT_TIMEOUT_S) / 3)


def _bump(c: _Call, b_id: str) -> bool:
    """Bump an OPEN entry in place when it is in backlog-add's own format; False means legacy, link
    only (a hand-written line, a REGRESSION re-open, or an id only a heading entry carries)."""
    lines = zio.read(c.real).splitlines(keepends=True)
    if not any(zb.definition_id(ln).lower() == b_id.lower() for ln in lines):
        return False                            # OPEN through a heading entry: no checkbox defines it
    bumped = ent.bump(lines, b_id, _conf(c), c.f.source, c.today)
    if bumped is not None:
        _write_backlog(c, "".join(bumped))
    return bumped is not None


def _reopen(c: _Call, b_id: str, v: lk.Verdict) -> None:
    lines = zio.read(c.archive).splitlines()
    picked = lines[v.lineno - 1] if v.lineno and 1 <= v.lineno <= len(lines) else ""
    if zb.definition_id(picked).lower() != b_id.lower():   # the archive moved, or lookup is wrong
        raise lk.LookupFailed(f"lookup named {c.archive}:{v.lineno}, which does not define {b_id}")
    _append_backlog(c, ent.render_regression(b_id, picked, v.section or "", c.f.source,
                                             _conf(c), c.tag.render(), c.today))


def _legacy_text(c: _Call) -> str:
    """The text a hand-written entry for this finding would start with, keyed as `lookup` keys text."""
    where = c.f.target.strip() if c.f.target and c.f.target.strip() else f"{c.f.file}:{c.f.line}"
    return f"{where} — {' '.join(c.f.title.split())}"


def _backlog_route(c: _Call, rec: Optional[fnd.Record]) -> Result:
    linked = rec.fields.get("backlog") if rec else None
    derived = adm.b_id(c.f, c.d, c.fid)
    b_id = linked or derived
    v = lk.lookup(c.repo, b_id, timeout=_lookup_timeout())
    legacy, shown = False, b_id
    if v.status == lk.LOOKUP_OPEN:
        verdict, legacy = "BUMPED", not _bump(c, b_id)
    elif v.status == lk.LOOKUP_ARCHIVED:
        verdict = "REOPENED"
        _reopen(c, b_id, v)
    else:
        old = lk.lookup(c.repo, _legacy_text(c), timeout=_lookup_timeout())
        if old.status == lk.LOOKUP_OPEN:
            verdict, legacy, b_id, shown = "BUMPED", True, old.ident or "", old.ident or old.key
        else:
            verdict, b_id = "ACCEPTED", derived
            seen = rec.seen + 1 if rec else 1
            _append_backlog(c, ent.render(c.f, c.d, b_id, c.fid, seen, c.tag.render(), c.today))
            shown = b_id
    seen_after = _ledger_write(c, rec, b_id or None)
    shown_seen = seen_after if verdict == "BUMPED" else None      # only BUMPED's line shows a count
    return Result(verdict, backlog=shown, ledger=c.fid, seen=shown_seen, legacy=legacy, forced=c.d.forced)


def _locked(c: _Call) -> Result:
    c.now = fnd.now_stamp()
    c.segment = fnd.segment_path(c.ledger, c.now, c.meta["branch"], fnd.host_name(), c.meta["sha"] or "")
    refusal = fnd.check_visibility(c.ledger, c.real, c.segment.name)
    if refusal is not None:
        return Result("REFUSED", EXIT_REFUSED, reason=refusal)
    _check_ledger(c, [])                        # before the fold: a FIFO segment would block it
    records, defects = fnd.fold(c.ledger)
    _check_ledger(c, defects)
    if defects:
        print(f"backlog-add: the findings ledger has {len(defects)} defect(s), first {defects[0].kind} at "
              f"{defects[0].where}: {defects[0].detail}", file=sys.stderr)
    rec = records.get(c.fid)
    if c.d.route == adm.ROUTE_BACKLOG:
        r = _backlog_route(c, rec)
    else:
        seen = _ledger_write(c, rec, None)
        r = Result("LEDGER", ledger=c.fid, reason=c.d.reason) if rec is None \
            else Result("LEDGER-BUMPED", ledger=c.fid, seen=seen)
    return r


def _check_ledger(c: _Call, defects: List[fnd.Defect]) -> None:
    """Raise OSError, before ANY write, when the ledger cannot take this call's lines: a backlog entry
    written first would then have no record, and the exit-1 verdict would not name it."""
    unreadable = [f"{d.where}: {d.detail}" for d in defects if d.kind == fnd.D_UNREADABLE]
    if c.ledger.exists() and not c.ledger.is_dir() or c.segment.exists() and not c.segment.is_file():
        unreadable.append(f"{c.ledger} is not a directory, or {c.segment.name} not a regular file")
    probe = next((p for p in (c.segment, c.ledger, c.ledger.parent) if p.exists()), None)
    if not unreadable and probe is not None and not os.access(probe, os.W_OK):
        unreadable.append(f"{probe} is not writable")
    if unreadable:
        raise OSError(f"the findings ledger is unusable, nothing written: {unreadable[0]}")


def _wrote(c: _Call) -> Tuple[str, ...]:
    """The written paths a skill may `git add`: inside this checkout and not ignored. A path git could
    not answer for is left out; listing it could make a skill stage an ignored file."""
    out: List[str] = []
    for path in dict.fromkeys(c.written):
        rel = os.path.relpath(path, c.repo)
        try:
            ignored = fnd.would_be_ignored(Path(path))
        except fnd._GitUnanswered:              # git gave no answer: not listed
            ignored = None
        if ignored is False and rel != os.pardir and not rel.startswith(os.pardir + os.sep):
            out.append(Path(rel).as_posix())
    return tuple(out)


def _ready() -> None:
    path = os.environ.get(READY_ENV, "")
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(f"{os.getpid()}\n")


def _advise_similar(c: _Call) -> None:
    """Stage 1 of B-20261015-DEDUP-ANCHOR-CHOICE-SPLITS: when the structural key is about to miss,
    say that an existing finding may be the same defect. Advisory ONLY — it writes nothing, decides
    nothing, and `zuvo_backlog_similar.advise` returns None on every failure, so this line changes
    no verdict and cannot fail the call. It runs HERE, before the lock, because it makes a network
    call and the lock budget is the write path for every other writer on the machine. A --dry-run
    makes no call at all: "writes nothing" is read as "changes nothing anywhere", and a dry run that
    quietly shipped the finding's title and evidence to a third party would break that reading."""
    if c.d.route != adm.ROUTE_BACKLOG:
        return                                  # the ledger route files no entry: nothing to split
    if c.dry:
        return                                  # --dry-run sends nothing anywhere, network included
    line = sim.advise(c.ledger, c.f, c.d, c.fid)
    if line:
        print(f"backlog-add: {line}", file=sys.stderr)


def _execute(a: argparse.Namespace, repo: str) -> Result:
    c = _prepare(a, repo)
    if isinstance(c, Result):
        return c
    _advise_similar(c)
    memdir = os.path.dirname(c.real)
    if c.dry and not os.path.isdir(memdir):
        return _locked(c)                       # nothing to read and nothing to race with
    if not c.dry:
        os.makedirs(memdir, exist_ok=True)      # Lock on a missing dir fails for ever
        _ready()
    failed: Optional[BaseException] = None
    with zio.Lock(memdir):
        try:
            r = _locked(c)
        except _FAILURES as exc:
            failed = exc
    if failed is not None:                      # `wrote=` is probed with the lock released
        if c.written:
            print("backlog-add: failed after writing: wrote=" + (",".join(_wrote(c)) or "-"), file=sys.stderr)
        raise failed
    return r._replace(wrote=_wrote(c))


# ── output ───────────────────────────────────────────────────────────────────────────────────────

def render_line(r: Result) -> str:
    """The one-line verdict (TD9)."""
    if r.verdict in ("REFUSED", "DISCARDED"):
        return f"{r.verdict} {r.reason}"
    wrote = "wrote=" + (",".join(r.wrote) or "-")
    tail = {"LEDGER": f"reason={r.reason}", "LEDGER-BUMPED": f"seen={r.seen}"}.get(r.verdict)
    if tail:
        return f"{r.verdict} {r.ledger} {tail} {wrote}"
    middle = {"BUMPED": f" seen={r.seen}", "REOPENED": " regression"}.get(r.verdict, "")
    return f"{r.verdict} backlog {r.backlog}{middle} ledger={r.ledger}{' legacy' if r.legacy else ''} {wrote}"


def render_json(r: Result, dry: bool) -> str:
    """The same fields as `render_line`, as one object."""
    return json.dumps({"verdict": r.verdict, "exit": r.code, "backlog": r.backlog, "ledger": r.ledger,
                       "seen": r.seen, "reason": r.reason, "legacy": r.legacy,
                       "regression": r.verdict == "REOPENED", "wrote": list(r.wrote), "dry_run": dry,
                       "forced": r.forced},
                      ensure_ascii=False, sort_keys=True)


def main(argv: Optional[Sequence[str]] = None) -> int:
    a = _parser().parse_args(argv)              # a usage error exits 2 here
    if a.repo is not None and not os.path.isdir(a.repo):
        _parser().error(f"--repo {a.repo!r} is not a directory")
    repo = _toplevel(a.repo or os.getcwd())
    if repo is None:
        _parser().error(f"{a.repo or os.getcwd()!r} is not inside a git work tree")
    try:
        r = _execute(a, repo)
    except SystemExit as exc:                   # zio.Lock: timed out, or the lock dir is unusable
        if not isinstance(exc.code, str):
            raise
        print(f"backlog-add: {exc.code}", file=sys.stderr)
        return EXIT_FAILED
    except _FAILURES as exc:
        print(f"backlog-add: {type(exc).__name__}: {exc}", file=sys.stderr)
        return EXIT_FAILED
    if r.reason == fnd.REFUSED_TRACKED:         # after the lock is released, like every verdict
        print(fnd.VISIBILITY_RECIPE, file=sys.stderr)
    print(render_json(r, a.dry_run) if a.json else render_line(r) + (" dry-run" if a.dry_run else ""))
    return r.code
