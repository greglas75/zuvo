#!/bin/sh
# Polyglot sh/python header — same reason as backlog-archive.py: `#!/usr/bin/env python3` dies on
# Windows/Git Bash. Keep it on ONE line and do not "tidy" the quoting.
''''exec "$(command -v python3 || command -v python || echo python3)" "$0" "$@" # '''
"""Backlog grooming, phase one: mint the ids, decide what the file already answers, queue the rest.

    backlog-groom.py plan [--repo R] [--dry-run] [--chunk-bytes N]

WHAT `plan` DOES, in the order it does it, because the order is the whole design:

  1. MINT, at body position 0, under the backlog's own lock — for the dialects that can take an id.
     It runs BEFORE any verdict because minting is none of the four verbs decision 3 forbids (closed,
     ranked, grouped, rendered) and because it is COUNT-NEUTRAL: every minted entry was already one of
     the N, so `entry_count` cannot move. That neutrality is CHECKED, not assumed, by re-parsing the
     minted text and refusing when it differs — and when nothing is minted it is trivially true, which
     is worth saying rather than deleting, because the check is what catches a write that would have
     turned a section header into an entry.

     THE PLAN'S RATIONALE FOR MINTING FIRST WAS FALSE, and revision 6 records why. It argued that a
     content-keyed entry "cannot carry a stable verdict until it has an id" and that deferring the mint
     deadlocks `groom`. It cannot: `keys_for` gives such an entry a first-class `fp:<12hex>` key, the
     ledger's `_KEY_RE` accepts `fp:` as first-class, and `plan_reuse` keys staleness on
     `(key, text_sha)` — on content, never on an id. The real cost is that an `fp:` key ROTATES when
     the text changes, so such a verdict is orphaned by the very normalisation `groom` performs;
     `plan_reuse` reports that row as a NAMED defect, which is what keeps the cost visible.

     WHICH entries: the ones `iter_entries` yields with no `ident` AND that `mintable()` accepts.
     Today that second set is EMPTY here — 263 and 0 — because every id-less entry is the BULLET
     dialect and `mint_into` refuses that dialect by a deliberate, pinned contract. Plan revision 6
     records the decision this measurement forced: **verification proceeds on `fp:` keys and no id is
     written into a tracked file to satisfy a premise measurement refuted.** So in practice this step
     REPORTS, per line and with its reason, and the mint path below exists for the dialects
     `mint_into` does accept rather than for the ones it is asked about.
  2. DECIDE what the bytes already answer — the four deterministic classes in
     `zuvo_backlog_verdicts.py`, each with a citation that must RESOLVE before it is emitted.
  3. QUEUE one row per entry into `$ZUVO_DIR/context/backlog-verify-queue.jsonl`, byte-chunked for
     the fan-out, with the deterministic rows carrying their verdict so nothing re-dispatches them.

WHAT IT NEVER DOES. It does not mint into a heading that `iter_entries` does not yield as an entry —
26 here, nine of them plain section headers like `## benchmark skill`, and writing an id into one would
put an identifier into the STRUCTURE of a tracked file. PR 1's decision 1 is that they are REPORTED, on
the `IDLESS_HEADING=` lines. It writes no `backlog-done.md`, no ordering and no disposition either:
those are `groom`'s and the archiver's, and this command exists to give them something true to act on.

THE WRITE FAILS CLOSED ON `is_ignored() is None`, and that is deliberately NOT what the ledger's
PLACEMENT check does. Placement fails OPEN there, because the canonical backlog legitimately lives
outside any git repository and "unknown" must not masquerade as "tracked" — a refusal there would
refuse every canonical backlog. This is a WRITE into a file whose tracked-ness decides whether the
edit is publishable, so the unknown answer is the one case where proceeding is the expensive mistake.
Both behaviours are asserted, in opposite directions, in tests/hooks/test-backlog-grooming.sh.
"""
import argparse
import os
import sys
from typing import List, NamedTuple, NoReturn, Sequence, Tuple

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import zuvo_backlog_io as zio  # noqa: E402  (path must be set before the import)
import zuvo_backlog_ledger as zl  # noqa: E402  (same path dependency)
import zuvo_backlog_parse as zb  # noqa: E402  (same path dependency)
# The row shape and the byte-capped split, one concern in one module (this file measured 439 raw lines
# with them inlined, against rules/file-limits.md's 400-line Python default — the same ceiling that
# chose the seams for the block boundary, the heading policy and the mint in backlog-archive.py).
import zuvo_backlog_queue as zq  # noqa: E402  (same path dependency)
import zuvo_backlog_verdicts as zv  # noqa: E402  (same path dependency)
# The minted id's shape AND its position, one contract with `zb.MINTED_ID_RE`/`zb.keys_for`, which
# strip exactly that prefix to recover the content key the entry had BEFORE minting. `mint_into`
# REFUSES rather than returning a line unchanged, and this file acts on the refusal.
from zuvo_backlog_mint import mint_id, mint_into  # noqa: E402  (same path dependency)

# EVERY dialect, heading entries included. The archiver's family pins `kinds=(KIND_CHECKBOX,)` on its
# write paths and gates its ONE heading request behind an env var, because archiving a heading MOVES
# lines. This command reads, and a heading entry is an entry: leaving the 81 of them out would make
# `groom`'s "every entry is verified" refusal a statement about a subset.
KINDS: Tuple[str, ...] = zb.DEFAULT_KINDS + (zb.KIND_HEADING,)

# Exit codes OUTSIDE {0,1,2,10,11,12}: those are already spoken for across this family (1 = a
# namespace violation `append-runlog` turns into a blocked run, 10/11/12 = lookup and status answers),
# and a refusal that collides with one of them is read as the other thing.
RC_UNKNOWN_IGNORE = 20
RC_MOVED = 21
RC_COUNT = 22
RC_MINT_SHAPE = 23


class Loaded(NamedTuple):
    """Both backlog files, parsed once. `lines` is `splitlines(keepends=True)` over `zio.read`, so the
    indices agree with `Entry.lineno` and `entry_block` measures spans over the same list.

    These are the PARSE lines, not the write lines. `zio.read` opens with the default `newline=None`,
    so universal-newline translation has already turned any `\r\n` into `\n` — which is harmless for
    counting and for spans, and would silently rewrite a CRLF backlog if it were used for the write.
    The locked write therefore re-reads through `read_raw()`; that split is deliberate, not an
    oversight, and `read_raw`'s docstring carries the measurement.
    """

    real: str
    archive: str
    root: str
    lines: List[str]
    entries: List[zb.Entry]
    archived: List[zb.Entry]


def refuse(code: int, message: str) -> NoReturn:
    """Print to stderr and exit with a NAMED code. `sys.exit(str)` would collapse every refusal here
    onto rc=1, which this family already uses for a namespace violation."""
    print("backlog-groom: " + message, file=sys.stderr)
    raise SystemExit(code)


def zuvo_dir(repo: str) -> str:
    """`$ZUVO_DIR` per shared/includes/report-output-location.md: the override verbatim, else the git
    root of `--repo` plus `/zuvo`, else the directory itself.

    The GIT ROOT of the argument, not `main_root`: the queue is this checkout's working state, while
    `main_root` deliberately jumps to the MAIN worktree so that six checkouts share ONE backlog. A
    queue written there would be overwritten by whichever worktree ran last.
    """
    override = os.environ.get("ZUVO_OUTPUT_DIR", "")
    if override:
        return override
    return os.path.join(zb.sh(["git", "rev-parse", "--show-toplevel"], cwd=repo) or repo, "zuvo")


def load(repo: str) -> Loaded:
    """Resolve, read and parse both files. Read-only; every write in this module happens under a lock
    taken afterwards, against a RE-READ of the same path."""
    _, real, archive = zio.resolve(repo)
    text = zio.read(real)
    return Loaded(real=real, archive=archive, root=zb.main_root(repo),
                  lines=text.splitlines(keepends=True),
                  entries=list(zb.iter_entries(text, kinds=KINDS)),
                  archived=list(zb.iter_entries(zio.read(archive), kinds=KINDS)))


def idless_headings(loaded: Loaded) -> List[Tuple[int, str]]:
    """Heading-shaped lines that `iter_entries` did NOT yield as entries — REPORTED, never minted.

    They are not a subset of the entries and they are not a defect: nine of the 26 here are plain
    section headers (`## benchmark skill`, `## 2026-04-17 zuvo:leads Task 1 (schema include)`), which
    is what a backlog's structure looks like. The mint set is defined by what the parser yields, so
    this list exists to be LOOKED at rather than to be acted on.
    """
    yielded = {e.lineno for e in loaded.entries}
    return [(i, ln.rstrip("\r\n")) for i, ln in enumerate(loaded.lines, start=1)
            if i not in yielded and zb.HEADING_RE.match(ln.rstrip())]


def template_lines(loaded: Loaded) -> int:
    """How many entry-shaped lines the parser dropped as TEMPLATE_RE matches. Counted so "a template
    is not an entry" is an observable number rather than an invisible absence."""
    return sum(1 for ln in loaded.lines
               if zb.TEMPLATE_RE.search(zb.body_of(ln.strip()))
               and (zb.CHECK_LINE_RE.match(ln.strip()) or zb.HEADING_RE.match(ln.rstrip())))


def mint_set(entries: Sequence[zb.Entry]) -> List[zb.Entry]:
    """The entries the PLAN names as the mint set: the ones `iter_entries` yielded with no `ident`.

    Not "every id-less heading", which is a different and larger set — see `idless_headings`, and see
    `mintable()` for the two reasons this set is a DENOMINATOR here rather than the list that gets
    written to.
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

    A REFUSAL IS NEVER SILENT AND NEVER FATAL HERE. `backlog-archive.py` aborts on a refused mint
    because the entry is about to MOVE and would land in the archive unfindable for ever. Nothing moves
    here: an entry that cannot be minted simply stays content-keyed, which is the state it was already
    in. So it is reported, by line, and the run continues — and `mint_lines` below still treats an
    unanchored arrival as a refusal, because after this filter one would mean the two disagree.
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


def mint_write(loaded: Loaded, targets: Sequence[zb.Entry]) -> int:
    """Insert the ids for real: fail closed on an unknown ignore status, then lock, RE-READ, check
    identity, and replace the bytes, keeping the file's mode. Returns the bytes inserted.

    Nothing is written when anything refuses, because `atomic_write` is the last statement and every
    refusal above it exits. The lock is the archiver's own, on the REAL file's directory, so an
    archive running concurrently waits rather than interleaving.

    THE MODE IS PASSED EXPLICITLY. `atomic_write(..., None)` writes a fresh temp file at the umask and
    `os.replace` carries THAT mode onto the target, so a 0600 backlog came back 0644 — the file
    becoming world-readable as a side effect of an id being added to it. Measured on the AC8′ fixture.
    """
    if zio.is_ignored(loaded.real) is None:
        refuse(RC_UNKNOWN_IGNORE,
               f"cannot tell whether {loaded.real} is git-tracked (no repository above it), and this "
               f"is a WRITE: minting into a tracked file publishes the ids, into an ignored one it "
               f"does not, and the two are not interchangeable. run from inside the repository that "
               f"owns the backlog, or set ZUVO_OUTPUT_DIR and use --dry-run to inspect the plan.")
    with zio.Lock(os.path.dirname(loaded.real)):
        fresh = read_raw(loaded.real)                 # re-read UNDER the lock, terminators intact
        new_lines, inserted, bad = mint_lines(fresh, targets)
        if bad:
            refuse(RC_MOVED, "the backlog changed under the lock — nothing written:\n  "
                   + "\n  ".join(bad))
        if len(new_lines) != len(fresh):
            refuse(RC_MINT_SHAPE, f"the mint changed the line count {len(fresh)} -> "
                                  f"{len(new_lines)}; an id belongs INSIDE an existing line")
        mode = os.stat(loaded.real).st_mode & 0o7777
        zio.atomic_write(loaded.real, "".join(new_lines), mode)
    return inserted


def _report_mint(repo: str, loaded: Loaded, targets: Sequence[zb.Entry],
                 dry_run: bool) -> Loaded:
    """The mint pre-pass with its two refusals, then the RE-PARSE that proves count-neutrality.

    The simulation runs in BOTH modes, so `--dry-run` checks the same invariants the write does and a
    refusal is discovered before anything is touched rather than after.
    """
    pre = len(loaded.entries)
    sim, inserted, bad = mint_lines(loaded.lines, targets)
    if bad:
        refuse(RC_MOVED, "the parsed lines do not match the file — nothing written:\n  "
               + "\n  ".join(bad))
    post = list(zb.iter_entries("".join(sim), kinds=KINDS))
    if len(post) != pre:
        refuse(RC_COUNT, f"minting moved the entry count {pre} -> {len(post)}; it must be "
                         f"count-neutral, because every minted entry was already one of the {pre}")
    if len(sim) != len(loaded.lines):
        refuse(RC_MINT_SHAPE, f"minting moved the line count {len(loaded.lines)} -> {len(sim)}")
    print("COUNT_NEUTRAL=%d/%d" % (len(post), pre))
    print("INSERTED_BYTES=%d" % inserted)
    if dry_run or not targets:
        # The SIMULATED lines travel with the simulated entries. Keeping the originals would hand the
        # queue a `raw_text` without the id the same run just reported minting — a dry run describing
        # a file that is half of two states.
        return loaded._replace(entries=post, lines=sim)
    written = mint_write(loaded, targets)
    if written != inserted:
        refuse(RC_MINT_SHAPE, f"the locked write inserted {written} bytes where the plan said "
                              f"{inserted}; the file changed between the two")
    return load(repo)


def cmd_plan(a: argparse.Namespace) -> int:
    """Mint, decide, queue — and print every number it acted on, because a pre-pass nobody can count
    is a pre-pass nobody can check."""
    loaded = load(a.repo)
    declared = mint_set(loaded.entries)
    targets, unmintable = mintable(loaded.lines, declared)
    print("BACKLOG=%s" % loaded.real)
    print("ENTRIES=%d" % len(loaded.entries))
    print("HEADING_ENTRIES=%d" % sum(1 for e in loaded.entries if e.kind == zb.KIND_HEADING))
    print("MINT_SET=%d" % len(declared))
    print("MINTABLE=%d" % len(targets))
    print("UNMINTABLE=%d" % len(unmintable))
    for line in unmintable:
        print("UNMINTABLE_ENTRY=" + line)
    print("TEMPLATES=%d" % template_lines(loaded))
    heads = idless_headings(loaded)
    print("IDLESS_HEADINGS=%d" % len(heads))
    for lineno, line in heads:
        print("IDLESS_HEADING=:%d %s" % (lineno, line[:100]))
    loaded = _report_mint(a.repo, loaded, targets, a.dry_run)
    tree = zv.Tree(root=loaded.root, real=loaded.real, archive=loaded.archive)
    verdicts, refused = zv.classify(loaded.entries, tree, loaded.archived)
    _report_verdicts(verdicts, refused)
    read = zl.read_ledger(zl.ledger_paths(a.repo)[1])
    plan = zl.plan_reuse(loaded.entries, read.rows)
    reused = {e.lineno for e, _ in plan.reuse}
    print("LEDGER_DEFECTS=%d" % len(read.defects))
    print("REUSED=%d" % len(reused))
    for orphan in plan.orphans:
        print("ORPHAN=" + orphan)
    by_line = {v.entry.lineno: v for v in verdicts}
    rows = [zq.queue_row(loaded.lines, e, by_line.get(e.lineno), e.lineno in reused)
            for e in loaded.entries]
    for line in zq.chunk_report(rows, a.chunk_bytes):
        print(line)
    queue = os.path.join(zuvo_dir(a.repo), "context", zq.QUEUE_NAME)
    print("QUEUE=%s rows=%d" % (queue, len(rows)))
    if a.dry_run:
        print("DRY_RUN=1 wrote nothing")
        return 0
    zq.write(queue, rows)
    appended, defects = zl.append_rows(a.repo, zv.ledger_rows(verdicts)) if verdicts else (0, [])
    print("LEDGER_APPENDED=%d preexisting_defects=%d" % (appended, len(defects)))
    return 0


def _report_verdicts(verdicts: Sequence[zv.Verdict], refused: Sequence[str]) -> None:
    print("DETERMINISTIC=%d" % len(verdicts))
    for klass in zv.CLASSES:
        print("DET_CLASS=%s %d" % (klass, sum(1 for v in verdicts if v.klass == klass)))
    print("REFUSED_EVIDENCE=%d" % len(refused))
    for line in refused:
        print("REFUSED=" + line)


def main() -> int:
    ap = argparse.ArgumentParser(prog="backlog-groom.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan", help="mint ids, decide the deterministic classes, write the queue")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--dry-run", action="store_true",
                   help="check every invariant and print the plan, writing nothing at all")
    p.add_argument("--chunk-bytes", type=int, default=zq.CHUNK_CAP)
    a = ap.parse_args()
    return cmd_plan(a)


if __name__ == "__main__":
    raise SystemExit(main())
