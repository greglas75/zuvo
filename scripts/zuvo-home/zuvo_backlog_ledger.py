"""THE VERDICT LEDGER of the backlog: what was verified, what the verdict was, and when the text
moved out from under it. Imported by backlog-groom.py; not a script, no shebang, no executable bit.

WHY A LEDGER AT ALL. `memory/backlog.md` records what someone once believed. It does not record
whether that is still true, so every pass over it re-spends the judgement the last pass already made
— 387 entries here, several hundred more per checkout across the fleet. The user's decision is that
NOTHING is closed, ranked, grouped or rendered before every entry carries a verdict, which is only
affordable if a verdict SURVIVES between runs. This file is what makes it survive.

WHY `memory/backlog-verdicts.jsonl`, beside the real backlog:
  * it inherits the backlog's git-ignore status and file mode, so judgements about untracked content
    are not published into git (the refusal below), and judgements about TRACKED content are not
    lost on clone — `zuvo/` is gitignored here, so a ledger under `$ZUVO_DIR/` costs 387 re-spent
    judgements per machine;
  * it is undated and it is not `.md`, so it is structurally unable to be mistaken for one of the
    banned whole-file snapshots the protocol lists (`backlog-verified-stale-<date>.md` is *literally*
    one of them). A snapshot is a copy of a file; this is a list of judgements ABOUT one.

WHY `text_sha` AND NOT A TTL. A verdict does not expire with the clock, it expires with the text. The
key is `sha1(strip_resolution_markers(body))` — the same normalisation `entry_key` runs — so an entry
that was reworded is unverified again while an entry that merely sat there for a month is not. That is
also why `read_ledger` is append-only-friendly rather than rewriting: two writers and two passes leave
a history, and `_dedup` reduces it at READ time.

EVERYTHING HERE FAILS CLOSED, and the direction is not symmetric. A corrupt line read as "verified"
closes an entry nobody examined; read as "unverified" it produces a refusal someone then looks at. So
a truncated final line, unparseable JSON and a row that misses the schema all land in `defects` and
their row is NOT in `rows`. `append_rows` refuses an invalid incoming row BEFORE taking the lock, and
a lock it cannot take exits non-zero from `Lock.__enter__` with `atomic_write` never reached — zero
bytes, not a partial ledger.

THE UNDERSCORE IN THE NAME IS LOAD-BEARING, exactly as in the three siblings: `install.sh` globs
`scripts/zuvo-home/*` into the machine-global `~/.zuvo/`, so the parser, the io layer and this module
end up as FLAT siblings with no package around them, and a plain same-directory
`import zuvo_backlog_io` resolves identically in the checkout and on the flattened layout. Putting the
importer's directory on `sys.path` is the IMPORTER's job — nothing here touches `sys.path`, because a
module that rewrites the path of whoever imports it is the one thing that breaks in exactly one of the
two layouts. By importing the parser this module also joins the pin-guard family that
`tests/hooks/test-backlog-headings.sh` (H19c) DERIVES as "the archiver plus every
`zuvo_backlog_*.py` that imports the parser".
"""
import datetime
import hashlib
import json
import os
import re
import sys
from typing import Any, Dict, List, NamedTuple, Optional, Sequence, Set, Tuple

import zuvo_backlog_io as zio
import zuvo_backlog_parse as zb

LEDGER_NAME = "backlog-verdicts.jsonl"

# THE VOCABULARY IS CLOSED AT FIVE, and it deliberately does NOT live in
# `shared/includes/severity-vocabulary.md`: that file maps *impact* (how bad), this maps *existence*
# (is it still there). An entry has both, and `scripts/audit-registry-integrity.py` validates the
# severity file's rows, so folding these in would fail there. A test asserts they stayed out.
VERDICT_STILL_REAL = "STILL-REAL"
VERDICT_STALE_FIXED = "STALE-FIXED"
VERDICT_STALE_OBSOLETE = "STALE-OBSOLETE"
VERDICT_DUPLICATE_OF = "DUPLICATE-OF"
VERDICT_NOT_VERIFIABLE = "NOT-VERIFIABLE"
VERDICTS: Tuple[str, ...] = (VERDICT_STILL_REAL, VERDICT_STALE_FIXED, VERDICT_STALE_OBSOLETE,
                             VERDICT_DUPLICATE_OF, VERDICT_NOT_VERIFIABLE)

# Written by `groom`, never by `verify`: a verdict says what is true, a disposition says what was done
# about it, and `no-remedy` exists so that "there is nothing this tool can perform here" is reported
# as itself rather than as a false `archived`.
DISPOSITIONS: Tuple[str, ...] = ("pending", "archived", "dropped", "kept", "no-remedy")

# `disposition` is the one field a row may omit (it defaults to `pending`); every other one is
# mandatory, because a row missing any of them cannot be checked and an uncheckable row is a defect.
FIELDS: Tuple[str, ...] = ("id", "keys", "text_sha", "verdict", "evidence",
                           "verified_at", "verified_by", "disposition")
OPTIONAL_FIELDS: Tuple[str, ...] = ("disposition",)

Row = Dict[str, Any]                 # what json.loads hands back; typing it tighter would be fiction

_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
# `path:line`, the shape control (b) resolves. The lookbehind stops `a/b.py:12` being harvested as
# `b.py:12` out of the middle of a longer path, and the trailing guard stops `:1` matching inside
# `:123`.
_LOC_RE = re.compile(r"(?<![\w./@+-])([\w./@+-]*[\w@+-]\.[A-Za-z][A-Za-z0-9]{0,4}):(\d+)(?!\d)")
_KEY_RE = re.compile(r"^(?:id:[\w.-]+|fp:[0-9a-f]{12})$")
_KEY_IN_TEXT_RE = re.compile(r"(?:id:[\w.-]+|fp:[0-9a-f]{12})")
# `deterministic:<class>` for the pre-pass, `agent:<lane>` for a model. Free-form provenance was the
# alternative and it makes "which of these verdicts did a model produce" unanswerable, which is
# exactly the question the cross-model spot check asks.
_BY_RE = re.compile(r"^(?:deterministic|agent):[\w.@/+-]+$")


class LedgerRead(NamedTuple):
    """`rows` are usable; `defects` are named and their rows are NOT in `rows`. `lines` is what was
    on disk, so a caller can report "N of M lines were unusable" without re-reading the file."""

    rows: List[Row]
    defects: List[str]
    lines: int


class Plan(NamedTuple):
    """Decision 4's four buckets. `reuse` costs nothing — that is the whole point of the ledger."""

    reuse: List[Tuple[zb.Entry, Row]]
    reverify: List[Tuple[zb.Entry, Row]]
    fresh: List[zb.Entry]
    orphans: List[str]


def ledger_paths(repo: str) -> Tuple[str, str]:
    """(REAL backlog path, ledger path beside it) — through the parser's `main_root`, never a fresh
    implementation of it: six ~/DEV checkouts reach ONE canonical backlog through symlinks, and a
    second copy of that resolution rule is the drift `zuvo_backlog_parse` exists to prevent."""
    _, real, _ = zio.resolve(repo)
    return real, os.path.join(os.path.dirname(real), LEDGER_NAME)


def now_stamp() -> str:
    """Aware UTC (rules/python.md CAP27). Fleet ledgers are merged from several hosts and `_dedup`
    compares these stamps as strings, so a naive local one would pick the wrong winner."""
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def text_sha(body: str) -> str:
    """The invalidation key: sha1 of the entry text with resolution shrapnel stripped.

    `strip_resolution_markers` and not the raw body, because closing an entry REWRITES it — the marker,
    the commit sha, the PR number and the date all arrive with the closure — and a verdict must not be
    invalidated by the very edit that proves it. It is also the normalisation `entry_key` already runs,
    so the sha and the content key move together instead of drifting apart.
    """
    return hashlib.sha1(zb.strip_resolution_markers(body).encode("utf-8")).hexdigest()


def evidence_locations(evidence: str) -> List[Tuple[str, int]]:
    """Every `path:line` in an evidence string, in order. Control (b) resolves these against the tree
    at the verified commit; `validate_row` only needs to know that at least one exists."""
    return [(m.group(1), int(m.group(2))) for m in _LOC_RE.finditer(evidence)]


def validate_row(obj: object, where: str) -> List[str]:
    """Every schema problem in one row, each naming `where`. An empty list means the row is usable.

    A FAILING ROW IS A DEFECT, NEVER A SKIP. The caller reports it and the entry it described stays
    UNVERIFIED — which makes `groom` refuse rather than close something nobody examined. Returning a
    list rather than raising is deliberate: a ledger with four bad rows must report four reasons in
    one pass, because a caller that fixes them one traceback at a time reads the file five times.
    """
    if not isinstance(obj, dict):
        return [f"{where}: not a JSON object"]
    out: List[str] = []
    missing = [f for f in FIELDS if f not in obj and f not in OPTIONAL_FIELDS]
    if missing:
        out.append(f"{where}: missing field(s) {','.join(missing)}")
    if not isinstance(obj.get("id"), str) or not str(obj.get("id", "")).strip():
        out.append(f"{where}: `id` is empty — a verdict with no subject cannot be reused")
    keys = obj.get("keys")
    if (not isinstance(keys, list) or not keys
            or not all(isinstance(k, str) and _KEY_RE.match(k) for k in keys)):
        out.append(f"{where}: `keys` must be a non-empty list of `id:`/`fp:` entry keys")
    if not isinstance(obj.get("text_sha"), str) or not _SHA_RE.match(str(obj.get("text_sha", ""))):
        out.append(f"{where}: `text_sha` is not 40 lowercase hex — staleness cannot be decided")
    verdict = obj.get("verdict")
    if verdict not in VERDICTS:
        out.append(f"{where}: verdict {verdict!r} is outside the closed set {'|'.join(VERDICTS)}")
    evidence = obj.get("evidence")
    if not isinstance(evidence, str) or not evidence.strip():
        out.append(f"{where}: `evidence` is empty — no verdict stands without one")
    else:
        out.extend(_evidence_problems(verdict, evidence, where))
    if not isinstance(obj.get("verified_by"), str) or not _BY_RE.match(str(obj.get("verified_by", ""))):
        out.append(f"{where}: `verified_by` must be `deterministic:<class>` or `agent:<lane>`")
    if not isinstance(obj.get("verified_at"), str) or not str(obj.get("verified_at", "")).strip():
        out.append(f"{where}: `verified_at` is empty — `_dedup` cannot order two writers")
    disposition = obj.get("disposition", "pending")
    if disposition not in DISPOSITIONS:
        out.append(f"{where}: disposition {disposition!r} is outside {'|'.join(DISPOSITIONS)}")
    return out


def _evidence_problems(verdict: object, evidence: str, where: str) -> List[str]:
    """The two verdict-specific evidence shapes that can be checked without touching the tree.

    `STILL-REAL` is the verdict that keeps an entry alive, so it must point at the code that keeps it
    alive. `DUPLICATE-OF` names the other entry's KEY in its evidence rather than in the verdict field,
    because the vocabulary is closed at five tokens and a verdict carrying a variable payload cannot be
    validated against a closed set. `STALE-OBSOLETE` cites a *backlog* line by construction, and
    `NOT-VERIFIABLE` may legitimately cite nothing resolvable at all — both are checked elsewhere.
    """
    if verdict == VERDICT_STILL_REAL and not evidence_locations(evidence):
        return [f"{where}: STILL-REAL without a `path:line` in its evidence is INVALID"]
    if verdict == VERDICT_DUPLICATE_OF and not _KEY_IN_TEXT_RE.search(evidence):
        return [f"{where}: DUPLICATE-OF must name the other entry's `id:`/`fp:` key in its evidence"]
    return []


def read_ledger(path: str) -> LedgerRead:
    """Parse the ledger FAIL-CLOSED: anything this cannot fully account for becomes a named defect and
    its row is absent from `rows`, so the entry it described reads UNVERIFIED.

    A missing file is not a defect — it is an unverified backlog, which is the starting state of every
    repo — so it returns empty rather than raising.
    """
    text = zio.read(path)
    defects: List[str] = []
    rows: List[Row] = []
    if not text:
        return LedgerRead(rows, defects, 0)
    where_base = os.path.basename(path)
    lines = text.split("\n")
    terminated = text.endswith("\n")
    if terminated:
        lines.pop()                                  # split() leaves one empty tail element
    for i, line in enumerate(lines, start=1):
        where = f"{where_base}:{i}"
        if not line.strip():
            continue
        # A TRUNCATED FINAL LINE READS UNVERIFIED, and the test is the missing terminator rather than a
        # parse failure: every write here ends in "\n", so its absence means the last write did not
        # complete. Checking only `json.loads` would pass a truncation that happens to land on a
        # syntactically complete prefix, and that row would then read as a verdict nobody recorded.
        if not terminated and i == len(lines):
            defects.append(f"{where}: final line is not newline-terminated — a truncated write reads "
                           f"UNVERIFIED, never verified")
            continue
        try:
            obj = json.loads(line)
        except ValueError as exc:
            defects.append(f"{where}: unparseable JSON ({exc}) — reads UNVERIFIED")
            continue
        problems = validate_row(obj, where)
        if problems:
            defects.extend(problems)
            continue
        rows.append(obj)
    return LedgerRead(_dedup(rows), defects, len(lines))


def _dedup(rows: Sequence[Row]) -> List[Row]:
    """Two writers that verified the same entry text collapse to ONE row, the later `verified_at`
    winning; equal stamps keep the LAST appended, because that is the write that completed second.

    Identity is `(key, text_sha)` and a row carries several keys, so two rows collide when they share
    ANY key at the same sha — which is exactly the pre-mint/post-mint bridge `keys_for` builds. Two
    rows at DIFFERENT shas are two judgements about two different texts and both survive: that history
    is what makes a re-verification auditable instead of silently overwriting its predecessor.
    """
    chosen: List[Row] = []
    at: Dict[Tuple[str, str], int] = {}
    for row in rows:
        sha = str(row.get("text_sha", ""))
        ids = [(str(k), sha) for k in row.get("keys", [])]
        hit = next((at[k] for k in ids if k in at), None)
        if hit is None:
            chosen.append(row)
            for k in ids:
                at[k] = len(chosen) - 1
            continue
        if str(row.get("verified_at", "")) >= str(chosen[hit].get("verified_at", "")):
            chosen[hit] = row
        for k in ids:
            at.setdefault(k, hit)
    return chosen


def refuse_tracked_ledger(real: str, ledger: str) -> None:
    """The archiver's refusal, for the same reason, with the LEDGER named.

    `is False`, never a bare falsy test: `is_ignored` answers None outside a git repository (the
    canonical backlog lives there) and "unknown" must not masquerade as "tracked". The recipe names all
    three siblings because a user who adds only the one the message asked for lands back here on the
    next command.
    """
    if zio.is_ignored(real) and zio.is_ignored(ledger) is False:
        sys.exit(f"refusing to create a git-TRACKED verdict ledger beside a git-IGNORED backlog.\n"
                 f"the ledger quotes the entries it judges, so publishing it publishes content that\n"
                 f"was deliberately untracked. add these lines to .gitignore first, then re-run:\n"
                 f"    /memory/{LEDGER_NAME}\n"
                 f"    /memory/{zio.ARCHIVE_NAME}\n"
                 f"    /memory/{zio.LOCK_NAME}/")


def append_rows(repo: str, new_rows: Sequence[Row]) -> Tuple[int, List[str]]:
    """Append verdicts under the backlog's own lock. Returns (rows appended, pre-existing defects).

    APPEND, not rewrite, and that is the fail-closed choice: rewriting would silently drop the very
    lines `read_ledger` reported as defects, destroying the evidence of a corrupt write while leaving
    the entry unverified anyway. Nothing here repairs a bad line; a truncated tail is only TERMINATED,
    so it cannot swallow the row appended after it — the terminated line still does not parse, so it
    still reads unverified.

    Three fail-closed clauses, each its own exit: an invalid incoming row is refused BEFORE the lock;
    a tracked-ledger placement is refused before the lock; a lock this process cannot take exits
    non-zero from `Lock.__enter__` with `atomic_write` never reached, so the file is untouched.
    """
    real, ledger = ledger_paths(repo)
    bad: List[str] = []
    for i, row in enumerate(new_rows, start=1):
        bad.extend(validate_row(row, f"<incoming row {i}>"))
    if bad:
        sys.exit("refusing to append an invalid verdict row:\n  " + "\n  ".join(bad))
    refuse_tracked_ledger(real, ledger)
    with zio.Lock(os.path.dirname(real)):
        old = zio.read(ledger)                       # re-read UNDER the lock
        existing = read_ledger(ledger)
        if old and not old.endswith("\n"):
            old += "\n"
        fresh = "".join(json.dumps(r, sort_keys=True, ensure_ascii=False) + "\n" for r in new_rows)
        mode: Optional[int] = None
        if not os.path.exists(ledger) and os.path.exists(real):
            mode = os.stat(real).st_mode & 0o7777     # inherit the source's visibility AND its mode
        zio.atomic_write(ledger, old + fresh, mode)
    return len(new_rows), existing.defects


def plan_reuse(entries: Sequence[zb.Entry], rows: Sequence[Row]) -> Plan:
    """Decision 4, mechanically: key + sha match -> reuse free; key matches, sha differs -> re-verify;
    no row at all -> fresh; a ROW no entry resolves -> a NAMED defect, never a silent drop.

    The last bucket is the one the ledger exists to detect. A row whose keys reach no entry means the
    entry was normalised without an id being minted for it, so its content key rotated and the verdict
    was orphaned — the failure mode that silently re-spends judgement for ever. Dropping such rows
    quietly would make the ledger look healthy at exactly the moment it stopped working.
    """
    by_key: Dict[str, List[int]] = {}
    for i, row in enumerate(rows):
        for key in row.get("keys", []):
            by_key.setdefault(str(key), []).append(i)
    matched: Set[int] = set()
    reuse: List[Tuple[zb.Entry, Row]] = []
    reverify: List[Tuple[zb.Entry, Row]] = []
    fresh: List[zb.Entry] = []
    for entry in entries:
        idx = sorted({i for k in zb.keys_for(entry.body, entry.ident) for i in by_key.get(k, [])})
        matched.update(idx)
        sha = text_sha(entry.body)
        exact = next((i for i in idx if rows[i].get("text_sha") == sha), None)
        if exact is not None:
            reuse.append((entry, rows[exact]))
        elif idx:
            reverify.append((entry, rows[idx[-1]]))
        else:
            fresh.append(entry)
    orphans = [_orphan_defect(rows[i]) for i in range(len(rows)) if i not in matched]
    return Plan(reuse, reverify, fresh, orphans)


def _orphan_defect(row: Row) -> str:
    """The orphan message, NAMED — the row's id and its keys, so a reader can find both sides."""
    keys = ",".join(str(k) for k in row.get("keys", []))
    return (f"orphan verdict {row.get('id')!r} keys={keys} resolves to no entry in backlog.md"
            f" — the entry was normalised without a minted id, so its content key rotated")


def coverage(entries: Sequence[zb.Entry], rows: Sequence[Row]) -> Tuple[int, int, List[str]]:
    """(entries carrying a CURRENT verdict, total entries, the shortfall named).

    "Current" is `text_sha`-exact, never key-only: an entry whose text moved after it was verified is
    unverified again, which is the whole point of a content key instead of a clock-based TTL. The
    shortfall is returned NAMED because the refusal it feeds has to say which entries are missing —
    "386 of 387" sends a reader back to the file to diff two lists by hand.
    """
    plan = plan_reuse(entries, rows)
    short = [entry.ident or entry.key for entry, _ in plan.reverify] + [e.ident or e.key for e in plan.fresh]
    return len(plan.reuse), len(entries), sorted(short)
