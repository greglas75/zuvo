"""THE MINT PRE-PASS: which entries an id may be written into, and the locked write that does it.
Imported by backlog-groom.py; not a script, no shebang, no executable bit.

WHY ITS OWN MODULE, and the number is the argument. `backlog-groom.py` measured **399 raw lines** with
this inlined — one line under `rules/file-limits.md`'s 400-line Python default (800 is the automatic
CQ11 FAIL) — and Task 3 adds two subcommands to it. Extending it in place would have crossed the
default on the first new function, so the mint moved out whole rather than being trimmed to fit. It is
ONE cohesive concern: which lines may take an id, and the discipline the write owes. WHICH entries are
queued, and what a verifier is handed, stay with their own owners.

WHAT THE REFUSALS ARE FOR. Every function here can decline, and none of them declines silently:

  * `mintable` filters the declared set and REPORTS the remainder, by line and with a reason. Nothing
    moves in this command, so an entry that cannot take an id simply stays content-keyed — the state it
    was already in. `backlog-archive.py` aborts on the same refusal because there the entry is about to
    MOVE and would land in the archive unfindable for ever.
  * `mint_lines` treats an unanchored arrival as a refusal even AFTER `mintable`'s filter, because one
    arriving here would mean the two disagree about the same line.
  * `mint_write` fails closed on `is_ignored() is None`, which is deliberately NOT what the ledger's
    PLACEMENT check does. Placement fails OPEN there, because the canonical backlog legitimately lives
    outside any git repository and "unknown" must not masquerade as "tracked" — a refusal there would
    refuse every canonical backlog. This is a WRITE into a file whose tracked-ness decides whether the
    edit is publishable, so the unknown answer is the one case where proceeding is the expensive
    mistake. Both behaviours are asserted, in opposite directions, in tests/hooks/test-backlog-grooming.sh.

THE UNDERSCORE IN THE NAME IS LOAD-BEARING, exactly as in the siblings: `install.sh` globs
`scripts/zuvo-home/*` into the machine-global `~/.zuvo/`, so these end up FLAT with no package around
them and a plain same-directory import resolves identically in both layouts. `sys.path` is the
IMPORTER's job. By importing the parser this module joins the pin-guard family that
`tests/hooks/test-backlog-headings.sh` (H19c) DERIVES, where its expectation is the default one: NO
`iter_entries` call lives here. Reading and re-parsing the file is backlog-groom.py's job — which is
also why `_report_mint`'s count-neutrality re-parse stayed there rather than travelling with the mint.
"""
import os
import sys
from typing import List, NoReturn, Sequence, Tuple

import zuvo_backlog_io as zio
import zuvo_backlog_parse as zb
# The minted id's shape AND its position, one contract with `zb.MINTED_ID_RE`/`zb.keys_for`, which
# strip exactly that prefix to recover the content key the entry had BEFORE minting. `mint_into`
# REFUSES rather than returning a line unchanged, and this module acts on the refusal.
from zuvo_backlog_mint import mint_id, mint_into

# Exit codes OUTSIDE {0,1,2,10,11,12}: those are already spoken for across this family (1 = a
# namespace violation `append-runlog` turns into a blocked run, 10/11/12 = lookup and status answers),
# and a refusal that collides with one of them is read as the other thing.
RC_UNKNOWN_IGNORE = 20
RC_MOVED = 21
RC_COUNT = 22
RC_MINT_SHAPE = 23
RC_QUEUE = 24
RC_REJECTED = 25


def refuse(code: int, message: str) -> NoReturn:
    """Print to stderr and exit with a NAMED code. `sys.exit(str)` would collapse every refusal in
    this family onto rc=1, which it already uses for a namespace violation."""
    print("backlog-groom: " + message, file=sys.stderr)
    raise SystemExit(code)


def read_raw(path: str) -> List[str]:
    """The file's lines with their ORIGINAL terminators, for the write path only.

    NOT `zio.read`, and this is measured rather than fussy: `zio.read` opens with the default
    `newline=None`, so universal-newline translation turns every `\r\n` into `\n` before the caller
    sees it — and a write built from that text silently converts a CRLF backlog to LF. Reading raw
    keeps the terminators, and the identity check still works because `Entry.raw` comes from
    `splitlines()` (which is `\r`-free) and the check rstrips `"\r\n"`. That is exactly why the
    prescribed comparison is `lines[idx].rstrip("\r\n") != e.raw` and not `rstrip("\n")`.

    Parsing deliberately keeps using `zio.read`: line NUMBERS must agree with what `iter_entries` saw,
    and both readers agree on those.
    """
    try:
        with open(path, encoding="utf-8", errors="replace", newline="") as fh:
            return fh.read().splitlines(keepends=True)
    except FileNotFoundError:
        return []


def mint_set(entries: Sequence[zb.Entry]) -> List[zb.Entry]:
    """The entries the PLAN names as the mint set: the ones `iter_entries` yielded with no `ident`.

    Not "every id-less heading", which is a different and larger set — see `backlog-groom.py`'s
    `idless_headings`, and see `mintable()` for the two reasons this set is a DENOMINATOR here rather
    than the list that gets written to.
    """
    return [e for e in entries if not e.ident]


def mintable(lines: Sequence[str],
             targets: Sequence[zb.Entry]) -> Tuple[List[zb.Entry], List[str]]:
    """(the entries an id is actually written into, the ones REPORTED instead) — and the gap between
    this and `mint_set` is the single most important measured fact in this command.

    MEASURED ON THIS REPO: the mint set is 263 entries and `mintable` is **0** of them. Two filters,
    both of them someone else's deliberate decision rather than a limitation of this file:

      * `mint_into` REFUSES any line that is not a checkbox or a flush-left heading, and
        `tests/hooks/test-backlog-headings.sh` (H20/AC7) pins `'- plain bullet, no checkbox'` as
        refused in as many words. All 263 entries of the mint set are the BULLET dialect, so every one
        is refused by contract, and plan revision 6 accepts that: verification proceeds on `fp:` keys,
        teaching `mint_into` this dialect is routed to its own task, and nothing here widens an anchor
        whose refusal a passing assertion pins on purpose.
      * an entry can carry a `B-` id that `definition_id` does not see, because `DEF_ID_RE` requires a
        CHECKBOX while `BODY_ID_RE` does not — `- B-4 [TRIAGE …]` has `ident == ""` and an id in plain
        sight. 38 of the 263 are this shape. Minting into one writes a SECOND id onto the line, and
        `entry_key` would then prefer the minted one while the entry still displays the old.

    A REFUSAL IS NEVER SILENT AND NEVER FATAL HERE, for the reason the module docstring gives.
    """
    out: List[zb.Entry] = []
    skipped: List[str] = []
    for e in targets:
        core = lines[e.lineno - 1].rstrip("\r\n") if e.lineno - 1 < len(lines) else ""
        if zb.BODY_ID_RE.match(e.body.strip()):
            skipped.append(f":{e.lineno} already shows a B-id `definition_id` cannot see "
                           f"({zb.BODY_ID_RE.match(e.body.strip()).group(1)})")  # type: ignore[union-attr]
        elif mint_into(core, mint_id(e.body)) is None:
            skipped.append(f":{e.lineno} kind={e.kind} has no mint anchor — `mint_into` admits only "
                           f"the checkbox and flush-heading dialects")
        else:
            out.append(e)
    return out, skipped


def mint_lines(lines: Sequence[str],
               targets: Sequence[zb.Entry]) -> Tuple[List[str], int, List[str]]:
    """(lines with ids inserted, bytes inserted, refusals). A non-empty refusal list means WRITE NOTHING.

    THE IDENTITY CHECK IS THE POINT OF THIS FUNCTION, and it is `rstrip("\\r\\n")` rather than
    `rstrip("\\n")` for a measured reason: `Entry.raw` comes from `splitlines()`, which treats `\\r\\n`
    as ONE terminator and yields a `\\r`-free line, while `keepends=True` keeps the `\\r`. Comparing
    the wrong one made every entry on a CRLF backlog fail this check and the command refuse for ever
    with a message about concurrency.

    It is a PURE function over a line list, so the locked write and the dry run share one
    implementation and a test can hand it a line that moved — which is the only way to reach the
    abort without a race.
    """
    out = list(lines)
    bad: List[str] = []
    inserted = 0
    for e in targets:
        idx = e.lineno - 1
        if idx >= len(out):
            bad.append(f"line {e.lineno} is past the end of a {len(out)}-line file")
            continue
        if out[idx].rstrip("\r\n") != e.raw:
            bad.append(f"line {e.lineno} moved: the file holds {out[idx].rstrip()!r} where "
                       f"{e.raw!r} was parsed")
            continue
        eol = out[idx][len(out[idx].rstrip("\r\n")):]
        core = out[idx][:len(out[idx]) - len(eol)]
        minted = mint_into(core, mint_id(e.body))
        if minted is None:
            bad.append(f"line {e.lineno}: no mint anchor in {core!r} — the id would land where "
                       f"`keys_for` cannot strip it back off")
            continue
        inserted += len(minted.encode("utf-8")) - len(core.encode("utf-8"))
        out[idx] = minted + eol
    return out, inserted, bad


def mint_write(real: str, targets: Sequence[zb.Entry]) -> int:
    """Insert the ids for real: fail closed on an unknown ignore status, then lock, RE-READ, check
    identity, and replace the bytes, keeping the file's mode. Returns the bytes inserted.

    Nothing is written when anything refuses, because `atomic_write` is the last statement and every
    refusal above it exits. The lock is the archiver's own, on the REAL file's directory, so an
    archive running concurrently waits rather than interleaving.

    THE MODE IS PASSED EXPLICITLY. `atomic_write(..., None)` writes a fresh temp file at the umask and
    `os.replace` carries THAT mode onto the target, so a 0600 backlog came back 0644 — the file
    becoming world-readable as a side effect of an id being added to it. Measured on the AC8′ fixture.
    """
    if zio.is_ignored(real) is None:
        refuse(RC_UNKNOWN_IGNORE,
               f"cannot tell whether {real} is git-tracked (no repository above it), and this "
               f"is a WRITE: minting into a tracked file publishes the ids, into an ignored one it "
               f"does not, and the two are not interchangeable. run from inside the repository that "
               f"owns the backlog, or set ZUVO_OUTPUT_DIR and use --dry-run to inspect the plan.")
    with zio.Lock(os.path.dirname(real)):
        fresh = read_raw(real)                        # re-read UNDER the lock, terminators intact
        new_lines, inserted, bad = mint_lines(fresh, targets)
        if bad:
            refuse(RC_MOVED, "the backlog changed under the lock — nothing written:\n  "
                   + "\n  ".join(bad))
        if len(new_lines) != len(fresh):
            refuse(RC_MINT_SHAPE, f"the mint changed the line count {len(fresh)} -> "
                                  f"{len(new_lines)}; an id belongs INSIDE an existing line")
        mode = os.stat(real).st_mode & 0o7777
        zio.atomic_write(real, "".join(new_lines), mode)
    return inserted
