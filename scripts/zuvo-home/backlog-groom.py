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

`dispatch` then hands ONE chunk to the verifier lane, with control (d)'s seeds mixed in and the answer
key written where the agent never sees it; `ingest` takes the response back and decides, mechanically,
whether any of it reaches the ledger. The mint, the controls and the row shape live in their own
modules — `backlog-groom.py` measured 399 raw lines with the mint inlined, one line under
`rules/file-limits.md`'s 400-line Python default, and this command adds two subcommands to it.

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
import json
import os
import sys
from typing import Sequence, Tuple

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import zuvo_backlog_io as zio  # noqa: E402  (path must be set before the import)
import zuvo_backlog_ledger as zl  # noqa: E402  (same path dependency)
import zuvo_backlog_parse as zb  # noqa: E402  (same path dependency)
# The row shape and the byte-capped split, one concern in one module (this file measured 439 raw lines
# with them inlined, against rules/file-limits.md's 400-line Python default — the same ceiling that
# chose the seams for the block boundary, the heading policy and the mint in backlog-archive.py).
import zuvo_backlog_queue as zq  # noqa: E402  (same path dependency)
import zuvo_backlog_verdicts as zv  # noqa: E402  (same path dependency)
# The verifier lane: conservation, controls (a)-(d), the seeds and the ledger rows a response becomes.
import zuvo_backlog_agent as za
import zuvo_backlog_cli as zc  # noqa: E402  (same path dependency)
# Control (d)'s seeds: built at dispatch, checked at ingest by the module above. Two modules because a
# seed BUILDER that imported the rejection vocabulary would close an import cycle with it.
import zuvo_backlog_seeds as zs  # noqa: E402  (same path dependency)
# `apply`'s dispositions and the delegated closures. Extracted for the 400-line reason its own
# docstring records: this file measured 376 raw lines before `apply` existed.
import zuvo_backlog_apply as zap  # noqa: E402  (same path dependency)
# `render`'s working document and the read-only fleet lane. Both extracted whole rather than
# inlined: this file measured 369 raw lines before they existed, against rules/file-limits.md's
# 400-line Python default, and `render` alone is ~200 lines of markdown emission.
import zuvo_backlog_render as zr  # noqa: E402  (same path dependency)
import zuvo_backlog_fleet as zf  # noqa: E402  (same path dependency)
# The mint pre-pass, extracted for the 400-line reason its own docstring records. RE-EXPORTED by name
# rather than reached through `zp.`, so a probe that loads this file still finds `mint_set`/`mintable`/
# `mint_lines` on it and a mutant of the prepass is the one that gets imported.
# The READ MODEL: the shape the two files are parsed into, the derived counts about lines the parser
# did not yield, and `$ZUVO_DIR`. RE-EXPORTED by name for the same reason the mint pre-pass is — the
# suite's probe looks these up on THIS module, so a mutant of the loader has to be the copy this
# command imports. The `iter_entries` CALLS stay HERE on purpose; that module's docstring carries the
# measurement (H19c's pin-guard family reads a call site's selection, and `kinds=KINDS` hides it).
from zuvo_backlog_load import (  # noqa: E402  (same path dependency)
    Loaded, idless_headings, nudge, template_lines, zuvo_dir)
from zuvo_backlog_prepass import (  # noqa: E402  (same path dependency)
    RC_COUNT, RC_MINT_SHAPE, RC_MOVED, RC_QUEUE, RC_REJECTED, mint_lines, mint_set, mint_write,
    mintable, refuse)

# EVERY dialect, heading entries included. The archiver's family pins `kinds=(KIND_CHECKBOX,)` on its
# write paths and gates its ONE heading request behind an env var, because archiving a heading MOVES
# lines. Here a heading entry is an entry: leaving the 81 of them out would make `groom`'s "every entry
# is verified" refusal a statement about a subset.
# Two of the three sites spelling this name read; `_report_mint`'s re-parse is the count-neutrality
# oracle that LICENSES `mint_write`, so this line moves what that oracle compares. A literal pin there
# would narrow the feature, so the claim sits at this BINDING — H19d asserts it, with a mutant.
KINDS: Tuple[str, ...] = zb.DEFAULT_KINDS + (zb.KIND_HEADING,)


def load(repo: str) -> Loaded:
    """Resolve, read and parse both files. Read-only; every write in this module happens under a lock
    taken afterwards, against a RE-READ of the same path."""
    _, real, archive = zio.resolve(repo)
    text = zio.read(real)
    return Loaded(real=real, archive=archive, root=zb.main_root(repo),
                  lines=text.splitlines(keepends=True),
                  entries=list(zb.iter_entries(text, kinds=KINDS)),
                  archived=list(zb.iter_entries(zio.read(archive), kinds=KINDS)))


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
    written = mint_write(loaded.real, targets)
    if written != inserted:
        refuse(RC_MINT_SHAPE, f"the locked write inserted {written} bytes where the plan said "
                              f"{inserted}; the file changed between the two")
    return load(repo)


def cmd_plan(a: argparse.Namespace) -> int:
    """Mint, decide, queue — and print every number it acted on, because a pre-pass nobody can count
    is a pre-pass nobody can check."""
    if a.fleet:
        # Decision 13's read-only lane. It returns BEFORE `load`, because resolving this repo at
        # all is work a fleet verification has no business doing.
        return zf.verify_fleet(a.dry_run)
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


# The two files `dispatch` writes. The ANSWER KEY is a SEPARATE file on purpose: the dispatch is what a
# read-only agent is pointed at, and a chunk carrying its own expected answers gates nothing.
DISPATCH_NAME = "backlog-dispatch-%d.jsonl"
ANSWERS_NAME = "backlog-answers-%d.json"


def cmd_dispatch(a: argparse.Namespace) -> int:
    """Hand ONE chunk to the verifier lane: the queue's rows for that chunk, control (d)'s seeds mixed
    in indistinguishably, and the answer key written where the agent is never pointed.

    IT REFUSES RATHER THAN DISPATCHING A CHUNK IT CANNOT GATE. A seed shortfall, a queue defect and a
    chunk number that holds no rows are all refusals with their own codes, because a dispatch that
    silently went out with two seeds instead of four reads identically to one that went out with four.
    """
    loaded = load(a.repo)
    queue = a.queue or os.path.join(zuvo_dir(a.repo), "context", zq.QUEUE_NAME)
    rows, defects = za.read_jsonl(queue)
    for line in defects:
        print("QUEUE_DEFECT=" + line)
    if defects:
        refuse(RC_QUEUE, f"{queue} does not fully parse — a dispatch built from a queue this command "
                         f"cannot account for is a dispatch nothing can be conserved against")
    mine = [r for r in rows if r.get("chunk") == a.chunk]
    print("QUEUE=%s rows=%d" % (queue, len(rows)))
    print("CHUNK=%d rows=%d bytes=%d" % (a.chunk, len(mine), sum(r.get("bytes", 0) for r in mine)))
    if not mine:
        refuse(RC_QUEUE, f"chunk {a.chunk} holds no rows; `plan` prints the CHUNKS= line that says how "
                         f"many there are, and a run over an empty chunk would report a clean pass")
    # The chunk's MODAL section, so a seed's `section` is one the chunk really contains. A constant
    # there — never mind a literal marker — is a field `jq` can select the graded rows on.
    sections = [str(r.get("section", "")) for r in mine]
    seeds, answers, short = zs.build_seeds(
        a.chunk, [e.body for e in loaded.archived],
        zs.live_anchors(loaded.root, zs.SEEDS_PER_CHUNK), mine, zs.SEEDS_PER_CHUNK,
        max(set(sections), key=sections.count) if sections else zs.SEED_SECTION)
    print("SEEDS=%d expected=%s" % (len(seeds), ",".join(sorted(set(answers.values())))))
    if short:
        refuse(RC_QUEUE, "%s: %s" % (za.R_SEED_SHORT, short))
    out = zs.interleave(list(mine) + seeds, "chunk%d" % a.chunk)
    # The COUNT, never the positions: stdout is not a private channel (it printed 2,38,49,55).
    print("DISPATCH_ROWS=%d interleaved=%d" % (len(out), len(seeds)))
    dpath = os.path.join(zuvo_dir(a.repo), "context", DISPATCH_NAME % a.chunk)
    apath = os.path.join(zuvo_dir(a.repo), "context", ANSWERS_NAME % a.chunk)
    print("DISPATCH=%s" % dpath)
    print("ANSWERS=%s" % apath)
    if a.dry_run:
        print("DRY_RUN=1 wrote nothing")
        return 0
    za.write_jsonl(dpath, zs.dispatch_view(out))
    os.makedirs(os.path.dirname(apath), exist_ok=True)
    with open(apath, "w", encoding="utf-8") as fh:
        json.dump(answers, fh, sort_keys=True, indent=1)
    return 0


def cmd_ingest(a: argparse.Namespace) -> int:
    """Take the verifier's response back and decide, mechanically, whether ANY of it reaches the ledger.

    Conservation first, then (a)-(d) on every record, and the append only when the rejection list is
    empty — never the clean half of a response that failed conservation.
    """
    loaded = load(a.repo)
    tree = zv.Tree(root=loaded.root, real=loaded.real, archive=loaded.archive)
    rows, rdef = za.read_jsonl(a.dispatch)
    recs, cdef = za.read_jsonl(a.response)
    for line in rdef + cdef:
        print("DEFECT=" + line)
    answers = zs.read_answers(a.answers or a.dispatch.replace("dispatch-", "answers-")
                          .replace(".jsonl", ".json"))
    print("DISPATCHED=%d RESPONDED=%d SEEDS=%d" % (len(rows), len(recs), len(answers)))
    if rdef or cdef:
        refuse(RC_QUEUE, "the dispatch or the response does not fully parse; a record this command "
                         "cannot read is NO record, never a verdict")
    result = za.ingest(rows, recs, answers, tree, a.lane)
    for line in result.controls:
        print("CONTROL=" + line)
    print("REJECTS=%d" % len(result.rejects))
    for r in result.rejects:
        print("REJECT=" + str(r))
    print("ACCEPTED=%d" % len(result.rows))
    if result.rejects:
        refuse(RC_REJECTED, f"{len(result.rejects)} rejection(s) — nothing is appended from a response "
                            f"that failed any control; re-dispatch chunk {a.chunk}")
    if a.dry_run:
        print("DRY_RUN=1 wrote nothing")
        return 0
    appended, defects = zl.append_rows(a.repo, result.rows) if result.rows else (0, [])
    print("LEDGER_APPENDED=%d preexisting_defects=%d" % (appended, len(defects)))
    return 0


def cmd_apply(a: argparse.Namespace) -> int:
    """THE REFUSAL GATE, then the dispositions the verdicts license — and not one byte of either
    backlog file written by this command.

    The order is decision 10's: a ledger this cannot fully read is a refusal, an incomplete ledger is
    a refusal NAMING every entry that is missing, and only then does anything get performed. The
    closures themselves are `backlog-archive.py`'s, delegated as a subprocess, because
    `backlog-protocol.md` records what the hand-written alternative did to the archive.

    WHAT IT DOES NOT DO, and each is asserted rather than described: it mints nothing (the pre-pass
    owns the mint, and on this repo it mints 0 of 263 by a pinned PR 1 contract), it reorders nothing
    (decision 7 — a ledger may carry a `rank` and the open file still does not move), and it reports
    `no-remedy` with a reason wherever no helper will act, never a false `archived`.
    """
    zf.refuse_fleet_apply(a.fleet)
    loaded = load(a.repo)
    print("BACKLOG=%s" % loaded.real)
    print("ENTRIES=%d" % len(loaded.entries))
    ledger, read = zap.ledger_or_refuse(a.repo)
    print("LEDGER=%s lines=%d rows=%d" % (ledger, read.lines, len(read.rows)))
    zf.refuse_index_rows(read.rows)
    zap.coverage_or_refuse(loaded.entries, read.rows)
    actions = zap.dispositions(loaded.entries, read.rows, loaded.archived)
    zap.report(actions)
    for line in zap.perform(actions, a.repo, loaded.real, a.dry_run):
        print("HELPER=" + line)
    if a.dry_run:
        print("DRY_RUN=1 wrote nothing")
        return 0
    appended, defects = zl.append_rows(a.repo, zap.disposition_rows(actions)) if actions else (0, [])
    print("LEDGER_APPENDED=%d preexisting_defects=%d" % (appended, len(defects)))
    return 0


def cmd_render(a: argparse.Namespace) -> int:
    """The working document, gated by decision 11 and never by a label. Thin on purpose: what the
    document SAYS lives in zuvo_backlog_render.py and zuvo_backlog_score.py.

    `zuvo_dir(a.repo)` and not `main_root`: the report is THIS checkout's output, while `main_root`
    deliberately jumps to the main worktree so six checkouts share one backlog.
    """
    return zr.render(load(a.repo), a.repo, zuvo_dir(a.repo), a.partial, a.dry_run)


def cmd_coverage(a: argparse.Namespace) -> int:
    """Decision 9's non-blocking count, the one `append-runlog` wires in: read-only, silent on a fully
    verified repo, never a refusal. `zuvo_backlog_load.nudge` carries the measurement behind both."""
    return nudge(load(a.repo), a.repo)


def main() -> int:
    """The command surface lives in `zuvo_backlog_cli`; the handler table stays here, because the
    commands do."""
    return zc.dispatch_to({"plan": cmd_plan, "dispatch": cmd_dispatch, "ingest": cmd_ingest,
                           "apply": cmd_apply, "render": cmd_render, "coverage": cmd_coverage},
                          __doc__ or "")


if __name__ == "__main__":
    raise SystemExit(main())
