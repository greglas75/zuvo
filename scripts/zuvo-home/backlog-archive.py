#!/bin/sh
# Polyglot sh/python header — same reason as backlog-collect.py: `#!/usr/bin/env python3` dies on
# Windows/Git Bash. Keep it on ONE line and do not "tidy" the quoting.
''''exec "$(command -v python3 || command -v python || echo python3)" "$0" "$@" # '''
"""Two-file backlog: move resolved entries into backlog-done.md, and answer "is this already known?"
over BOTH files at a cost that does not grow with the backlog.

    backlog-archive.py path    [--repo R]
    backlog-archive.py lookup  [--repo R] [--json] <text-or-B-id>   # exit 10 OPEN / 11 ARCHIVED / 0 ABSENT
    backlog-archive.py index   [--repo R] [--rebuild]
    backlog-archive.py archive [--repo R] [--dry-run] [--min-resolved N]
    backlog-archive.py verify  [--repo R]                           # exit 1 when a key is in BOTH
    backlog-archive.py status  [--repo R]                           # exit 12 when work is done
    backlog-archive.py drop-stale [--repo R] --id B-x [--id B-y]    # settle what verify reports

Why realpath everywhere: six ~/DEV checkouts reach ONE canonical backlog.md through symlinks, and
two of them are not git repos, so MAIN_ROOT degrades to cwd and `dirname($BACKLOG)` is six
different directories. Resolving is what stops one archive becoming six — and writing onto the
REALPATH is what stops os.replace() from turning the symlink into a regular file and forking the
1.2 MB backlog (the 2026-07-19 incident, which a naive fix would re-cause).

MEASURED, and why archiving mints ids: on the five entries that are currently in both files of the
canonical backlog, the id key matches 5/5 while the content key matches 0/5 — because closing an
entry REWRITES its text into a description of the fix (often in another language). Content hashing
therefore cannot bridge open→archived, and an entry without a `B-` id would be unfindable once
archived. So `archive` assigns an id to any entry that lacks one BEFORE moving it, and the contract
requires the resolution to be APPENDED to the original problem text rather than replacing it.
"""
import argparse
import os
import sys
import time
from typing import Dict, Iterable, List, Optional, Set, Tuple

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import zuvo_backlog_parse as zb  # noqa: E402  (path must be set before the import)
# Where an entry's block ENDS, one concern in one module (see its docstring: this file
# crossed the 800-line automatic CQ11 FAIL when the level-and-sibling rule landed). Imported
# BY NAME rather than as a module so `entry_block` reads the same at the four call sites it
# had before the move, and so a test that mutates the boundary rule mutates ONE file.
from zuvo_backlog_block import entry_block, with_span  # noqa: E402  (same path dependency)
# WHICH heading entries may be archived, and the env gate that decides whether ANY may be — one
# concern in one module, for the same two reasons as above: this file measured 850 raw lines with the
# policy inlined, and a test that mutates the policy should mutate one file. The gate lives THERE and
# not here on purpose: that module holds the family's only `iter_entries` call that may ask for
# KIND_HEADING, so `tests/hooks/test-backlog-headings.sh` (H14/H19c) can assert "seven pinned sites
# plus exactly one env-gated site" over the whole family and have it mean something.
from zuvo_backlog_heading import HeadingPlan, heading_candidates  # noqa: E402  (same path dep.)
# The minted id's shape AND its position, one contract with `zb.MINTED_ID_RE`/`zb.keys_for` — and the
# third module this file's 800-line ceiling has pushed out. It REFUSES rather than returning a line
# unchanged; the call site below acts on that.
from zuvo_backlog_mint import mint_id, mint_into  # noqa: E402  (same path dependency)
# WHERE the files are, how they are read, the cross-process lock and the one atomic write — the fourth
# module this file's size has pushed out (763 raw lines with it inlined, against the 400-line default
# in rules/file-limits.md). Imported BY NAME, under the SAME module-level names these had here, so
# every call site in this file reads exactly as it did before the move and the diff is pure motion.
# ARCHIVE_NAME and LOCK_NAME travel with it because `resolve()` and `Lock` are their only definers;
# LOCK_WAIT and STALE_LOCK_S do NOT come back, because nothing outside `Lock` ever read them and an
# import nothing uses is a name a reader has to go looking for.
from zuvo_backlog_io import (ARCHIVE_NAME, LOCK_NAME, Lock, atomic_write,  # noqa: E402  (same path dep.)
                            is_ignored, read, resolve)

INDEX_NAME = ".backlog-index.tsv"

# The shape `classify()` returns and the archive helpers pass around: (line number, entry) pairs in
# document order. Named so the five `_`-prefixed helpers below `cmd_archive` can be annotated without
# a three-deep generic on every signature; `classify` itself keeps its spelled-out return type, so
# this alias adds a name and moves nothing.
_Group = List[Tuple[int, zb.Entry]]

# WHICH DIALECTS EACH SIDE OF THIS FILE SEES, and why the split is not symmetric.
#
# READ paths (`find`/`cmd_lookup`, `cmd_index`) admit the `## B-id` HEADING dialect: an entry written
# as a heading plus prose is an entry, and answering ABSENT about one sitting in the file is what made
# every audit skill's mandatory dedup check re-file the same finding as new — the loop
# backlog-protocol.md exists to prevent. Neither of these two commands writes the backlog.
#
# WRITE and GATE paths stay checkbox-only, and each one spells `kinds=(zb.KIND_CHECKBOX,)` out at its
# own call site rather than relying on this constant or on a default. `install.sh` globs
# `scripts/zuvo-home/*` into the machine-global `~/.zuvo/`, and `append-runlog` runs
# `backlog-archive.py archive --repo "$PWD"` at the end of every skill run in every repo — so the day
# a heading-admitting archiver is installed it would rewrite tracked files, under `Lock`, across every
# checkout on the machine (measured: 170-216 marker-carrying open heading entries fleet-wide). Making
# the pin visible AT each write site is what keeps admitting headings there a one-line reviewable diff
# instead of an invisible consequence of a default; `tests/hooks/test-backlog-headings.sh` (H14)
# asserts the count of pinned sites mechanically, so a new write path cannot join quietly, and (H14b)
# re-runs the contract below against mutated copies of this file and of the parser.
#
# SPELLED OUT, not derived from `zb.DEFAULT_KINDS`, for the same reason the write sites are: the read
# dialect is a decision of THIS file, and backlog-protocol.md now documents the read/write split as
# intentional. `zb.DEFAULT_KINDS + (zb.KIND_HEADING,)` made that decision invisible twice over — a
# change to the parser's "today's tolerant set", made for parser reasons, would silently move what
# `lookup`/`index` resolve, and the day `DEFAULT_KINDS` itself gained `KIND_HEADING` the expression
# would list that kind TWICE (nothing in `iter_entries` rejects a repeated kind, so the duplicate
# would pass straight into `_requested_kinds`).
LOOKUP_KINDS: Tuple[str, ...] = (zb.KIND_CHECKBOX, zb.KIND_BULLET, zb.KIND_TABLE, zb.KIND_HEADING)


def _lookup_kinds() -> Tuple[str, ...]:
    """LOOKUP_KINDS, contract-checked ON FIRST USE. The two READ paths call this; nothing else may.

    Equality, not merely "superset of DEFAULT_KINDS + heading": the superset direction catches the
    case that matters most (the parser learns a new dialect and the read paths never hear about it),
    but the other direction is the same class of defect — a kind LEAVING `DEFAULT_KINDS` for parser
    reasons would leave the read paths tolerating what the parser no longer considers tolerant, and a
    kind added HERE would not be reviewable against any stated rule. Both must be a deliberate edit
    to the line above. `raise` rather than `assert` because `assert` is compiled out under `python -O`
    and the installed `~/.zuvo/` copy runs under shell wrappers whose interpreter flags this repo does
    not own — a contract that can be optimised away is the silent divergence it exists to prevent.

    LAZY, not at import, and the reason is a MEASURED exit-code collision rather than tidiness.
    `append-runlog` invokes this helper as a BLOCKING gate: `backlog-archive.py verify --repo "$PWD"`,
    and on a non-zero exit it prints `BACKLOG_NAMESPACE_VIOLATION`, exits 2 and does not append
    `runs.log`. An import-time `raise` exits 1 — byte-for-byte indistinguishable from a real
    namespace violation — so a broken read dialect would block every skill run in every repo on the
    machine while naming the wrong cause entirely. And it would do so out of all proportion to the
    defect: `verify`, `archive`, `status` and `drop-stale` pin `kinds=(zb.KIND_CHECKBOX,)` at each
    call site and provably never consult this constant (H14 asserts exactly that), so a read-dialect
    divergence cannot affect them. Validating where the value is USED keeps the blast radius equal to
    the scope of the defect: `lookup`/`index` fail loudly, the gate paths keep working, and the two
    failure modes stay distinguishable. `tests/hooks/test-backlog-headings.sh` (H14b) asserts both
    halves against mutated copies of this file and of the parser.

    Unmemoised on purpose: two set constructions over a 4-tuple, on a path that already reads a file
    off disk. A cache would add module state for no measurable gain.
    """
    if len(set(LOOKUP_KINDS)) != len(LOOKUP_KINDS):
        raise RuntimeError("LOOKUP_KINDS lists a kind twice: %r — `iter_entries` accepts a duplicated "
                           "kind silently, so the read paths would carry it into _requested_kinds."
                           % (LOOKUP_KINDS,))
    if set(LOOKUP_KINDS) != set(zb.DEFAULT_KINDS) | {zb.KIND_HEADING}:
        raise RuntimeError(
            "the read dialect and the parser have diverged: LOOKUP_KINDS=%r, but zuvo_backlog_parse "
            "DEFAULT_KINDS=%r plus KIND_HEADING=%r. Decide EXPLICITLY whether the new/removed kind "
            "belongs on the read paths (`lookup`, `index`) and edit LOOKUP_KINDS in this file; the "
            "write and gate paths pin kinds=(zb.KIND_CHECKBOX,) at each call site and are unaffected."
            % (LOOKUP_KINDS, zb.DEFAULT_KINDS, zb.KIND_HEADING))
    return LOOKUP_KINDS


def query_key(q: str) -> str:
    """A bare B-id keys as an id; anything else is treated as candidate entry text."""
    s = q.strip()
    if zb.ID_RE.fullmatch(s):
        return "id:" + s.lower()
    return zb.entry_key(s)


def find(path: str, key: str) -> Optional[zb.Entry]:
    """The one lookup both `cmd_lookup` verdicts come from — heading entries included (LOOKUP_KINDS).

    `_lookup_kinds()` rather than the bare constant: the read dialect's contract is checked HERE, on
    a path that consults it, instead of at import where it would take `verify` down with it.

    `end_lineno` comes back MEASURED (`with_span`). The parser sets it to the entry's own line for a
    heading entry on purpose — a heading BLOCK's extent is level-and-sibling aware and belongs to the
    file that rewrites the backlog — so a consumer reading the raw field would size the 19-line entry
    at memory/backlog.md:220 as one line.
    """
    text = read(path)
    lines = text.splitlines(keepends=True)
    for e in zb.iter_entries(text, kinds=_lookup_kinds()):
        if e.key == key:
            return with_span(lines, e)
    return None


def cmd_path(a: argparse.Namespace) -> int:
    declared, real, archive = resolve(a.repo)
    print(f"declared {declared}")
    print(f"real     {real}" + ("  (symlinked)" if os.path.realpath(declared) != declared else ""))
    print(f"archive  {archive}" + ("" if os.path.exists(archive) else "  (absent)"))
    return 0


def cmd_lookup(a: argparse.Namespace) -> int:
    _, real, archive = resolve(a.repo)
    key = query_key(a.query)
    op, dn = find(real, key), find(archive, key)
    if op is not None:
        extra = f' (ALSO ARCHIVED {ARCHIVE_NAME}:{dn.lineno} — run verify)' if dn else ""
        print(f"OPEN {key} {op.ident or '-'} backlog.md:{op.lineno}{extra}")
        return 10
    if dn is not None:
        print(f'ARCHIVED {key} {dn.ident or "-"} {ARCHIVE_NAME}:{dn.lineno} section="{dn.section}"')
        return 11
    print(f"ABSENT {key}")
    return 0


def cmd_index(a: argparse.Namespace) -> int:
    _, real, archive = resolve(a.repo)
    out = os.path.join(os.path.dirname(real), INDEX_NAME)
    rows = ["# key\tstatus\tfile\tline\tid\tsection"]
    for path, label in ((real, "backlog.md"), (archive, ARCHIVE_NAME)):
        # LOOKUP_KINDS, matching `find()`: the index is the cheap form of the same question, and an
        # index that answered differently from `lookup` would be worse than no index. Same accessor,
        # so the contract is checked on this path too and on no path that does not use the value.
        # NOT routed through `with_span`, deliberately and as the only exception: this row format has
        # no span column, and widening `.backlog-index.tsv` is a fleet-wide change — every `~/.zuvo/`
        # helper in every repo reads that file. Nothing here reads `end_lineno`, so no wrong number
        # escapes; the day a span column is wanted, it comes from `with_span` like every other one.
        for e in zb.iter_entries(read(path), kinds=_lookup_kinds()):
            sec = e.section.replace("\t", " ")
            rows.append(f"{e.key}\t{e.status}\t{label}\t{e.lineno}\t{e.ident or '-'}\t{sec}")
    atomic_write(out, "\n".join(rows) + "\n", None)
    print(f"{out}: {len(rows) - 1} entries")
    return 0


def all_keys_index(entries: Iterable[zb.Entry]) -> Dict[str, zb.Entry]:
    """Index entries by EVERY key each can be known by, including the content key it had before this
    archiver minted an id for it. Two call sites had their own copy of this loop under different
    variable names, which is how the two halves of one identity rule drift apart."""
    out: Dict[str, zb.Entry] = {}
    for e in entries:
        for k in zb.keys_for(e.body, e.ident):
            out.setdefault(k, e)
    return out


def undeclared_pairs(real: str, archive: str) -> Tuple[List[str], List[str], Dict[str, zb.Entry],
                                                        Dict[str, zb.Entry]]:
    """Keys defined in BOTH files, split into undeclared (violations) and declared regressions."""
    op = {e.key: e for e in zb.iter_entries(read(real), kinds=(zb.KIND_CHECKBOX,))}
    # The archive is indexed by EVERY key an entry can be known by, including the content key it had
    # before this archiver minted an id for it — otherwise a resolved entry that reappears in the open
    # file (a skill rewriting backlog.md from a stale copy) is invisible to both this check and the
    # archiver's refusal, and the archive silently takes it a second time.
    dn = all_keys_index(zb.iter_entries(read(archive), kinds=(zb.KIND_CHECKBOX,)))
    both = sorted(set(op) & set(dn))
    regressions = [k for k in both if zb.REOPEN_RE.search(op[k].body)]
    # Spanned for the keys in BOTH files only — those are the entries that leave here (cmd_verify
    # reports them, cmd_drop_stale removes them), and they are 0-5 in practice, where spanning every
    # entry of two whole files would be work nothing reads. Same one producer as everywhere else.
    op_lines, dn_lines = read(real).splitlines(keepends=True), read(archive).splitlines(keepends=True)
    for k in both:
        op[k], dn[k] = with_span(op_lines, op[k]), with_span(dn_lines, dn[k])
    return [k for k in both if k not in set(regressions)], regressions, op, dn


def cmd_verify(a: argparse.Namespace) -> int:
    _, real, archive = resolve(a.repo)
    # Read both files under the archive lock. cmd_archive writes the archive first and the open file
    # second, so an unlocked reader landing between those two renames sees the entry in BOTH and
    # reports a violation that is false a millisecond later — and `append-runlog` turns a violation
    # into exit 2, blocking an unrelated run on a fleet that deliberately runs parallel agents in one
    # repo. Held briefly and for reading only.
    try:
        with Lock(os.path.dirname(real)):
            bad, regressions, op, dn = undeclared_pairs(real, archive)
    except SystemExit:
        # Lock() reports failure by exiting; here that must not be fatal. A gate that cannot answer is
        # worse than one that occasionally reads a transient state, so fall back to an unlocked read.
        bad, regressions, op, dn = undeclared_pairs(real, archive)
    # A DECLARED regression is the contract's own re-open path, not a violation: the protocol says to
    # re-open under the SAME id with a back-link, which necessarily puts that id in both files. A gate
    # that flagged it would punish the behaviour it mandates — see undeclared_pairs().
    if not bad:
        extra = f", {len(regressions)} declared regression(s)" if regressions else ""
        print(f"OK disjoint: {len(op)} open, {len(dn)} archived{extra}")
        return 0
    print(f"VIOLATION {len(bad)} key(s) defined in BOTH files without declaring a regression:")
    for k in bad:
        print(f"  {k}  backlog.md:{op[k].lineno}  {ARCHIVE_NAME}:{dn[k].lineno}")
    if regressions:
        print(f"  ({len(regressions)} further pair(s) declare REGRESSION and are legitimate)")
    print("  Each one is either a stale open copy (remove it), a partial closure (say which part the")
    print("  archived entry closed), or a genuine regression (re-open per backlog-protocol.md).")
    return 1


def classify(text: str) -> Tuple[List[Tuple[int, zb.Entry]], List[Tuple[int, zb.Entry]],
                                 List[str], HeadingPlan]:
    """Ticked entries as (resolved WITH a recorded reason, resolved WITHOUT one, held back).

    Only one thing is still held back: an entry carrying a live `[ ]` sub-item, because the open
    follow-up would go out of sight with its resolved parent.

    A tick with no resolution marker used to be held too, on the argument that archiving it files
    away a decision nobody recorded. Measured across the fleet: **538 such entries in 17 files, 182
    in the largest**. So in practice that rule kept 538 finished items in the list of what is LEFT,
    indefinitely, waiting for notes nobody was going to write — it protected the record and lost the
    purpose. The tick IS a record that someone judged the work done, and the absent reason is a
    pre-existing fact that moving the line does not make worse. They therefore move, into their OWN
    section whose heading states exactly what is missing, so the archive stays honest about which
    entries carry evidence and which carry only a checkbox.

    HEADING ENTRIES join `marked` only when `ZUVO_BACKLOG_HEADING_ARCHIVE=1` (see
    `zuvo_backlog_heading.heading_candidates`). With the gate off every line below that mentions them
    is provably inert: the candidate list and its spans come back empty, so `inside` is empty and
    `nested` gains nothing, and the sort runs over a list `iter_entries` already produced in ascending
    line order. The checkbox behaviour every repo on the machine gets is byte-identical.

    The fourth return value is that walk's `HeadingPlan`, because two CHECKBOX-ONLY numbers in
    `cmd_status` and `cmd_archive` are wrong once headings can move and both of those call sites must
    keep their pin. See `HeadingPlan`.
    """
    marked: List[Tuple[int, zb.Entry]] = []
    unmarked: List[Tuple[int, zb.Entry]] = []
    nested: List[str] = []
    # `with_span` on every entry that LEAVES this function. A checkbox entry's continuation lines are
    # part of it (30+ lines each in tgm-pulse's real backlog), and the parser's `end_lineno` is the
    # entry's own line, so an unspanned Entry handed to cmd_status/cmd_archive carries a number that
    # disagrees with the range the archiver actually moves. One producer, `zuvo_backlog_block.with_span`.
    lines = text.splitlines(keepends=True)
    plan = heading_candidates(text, lines)
    nested.extend(plan.held)
    # A checkbox entry inside a resolved heading's block never moves on its own: it travels with that
    # parent when the parent moves, and waits with it when the parent is held. NECESSARY FOR THE
    # FEATURE, not for safety, and the distinction is measured: without it the child's lines are
    # counted twice while `drop` deletes them once, and the pre-existing
    # `len(kept) != len(lines) - len(moved)` check aborts the run — so the failure mode is "a resolved
    # heading with any ticked child can never be archived", fail-closed, never a wrong archive.
    inside = {n for start, end in plan.spans for n in range(start + 1, end + 1)}
    for e in zb.iter_entries(text, kinds=(zb.KIND_CHECKBOX,)):
        if e.status != "done":
            continue
        # `inside` FIRST, and the order is the assertion. Tested after the `"[ ]"` check, a ticked child
        # carrying an open follow-up inside a resolved heading's block was appended to the HELD list
        # while its parent moved and carried it into the archive: a FALSE "held", which is worse than
        # either outcome alone because the operator reads it as safe. The parent is held instead — its
        # own `open_children` sees that same marker (`zuvo_backlog_heading._OPEN_BOX_RE`).
        if e.lineno in inside:
            continue
        if "[ ]" in e.body:
            nested.append(e.ident or e.key)
            continue
        e = with_span(lines, e)
        (marked if zb.has_resolution_marker(e.body) else unmarked).append((e.lineno, e))
    marked.extend(plan.moving)
    marked.sort(key=lambda pair: pair[0])      # document order; a no-op when nothing was added
    return marked, unmarked, nested, plan


def report_held(nested: List[str]) -> None:
    """The one class that never moves: a resolved entry whose body still holds an open `[ ]` item."""
    if nested:
        print(f"HELD {len(nested)} with a live [ ] sub-item (split the parent first): {nested[:5]}")


def cmd_status(a: argparse.Namespace) -> int:
    """Is finished work sitting in the open backlog? Exit 12 when yes, 0 when the file is clean.

    Counts ENTRIES, never bytes. The reason for two files is order — a done item has no business in
    the list of what is left — so one archivable entry is already the finding, and the old "archive
    once it is ≥50 entries or >100 KB" framing measured the wrong thing.
    """
    _, real, archive = resolve(a.repo)
    text = read(real)
    if not text:
        print(f"OK no backlog at {real}")
        return 0
    marked, unmarked, nested, plan = classify(text)
    # `+ plan.total`: the pinned walk counts CHECKBOX entries, and `still_open` below subtracts the
    # classified ones — so once a heading entry can be marked or held, a checkbox-only total makes
    # `still_open` under-count and go negative. Zero with the gate off. The pin stays where it is.
    total = sum(1 for _ in zb.iter_entries(text, kinds=(zb.KIND_CHECKBOX,))) + plan.total
    still_open = total - len(marked) - len(unmarked) - len(nested)
    movable = marked + unmarked
    if not movable:
        print(f"OK {real}: {still_open} open, nothing resolved left in backlog.md")
        report_held(nested)
        return 0
    # The split is reported because the two groups land in different sections and carry different
    # evidence, not because one of them stays behind.
    print(f"OVERDUE {real}: {len(movable)} resolved entries still in backlog.md "
          f"({len(marked)} with a recorded resolution, {len(unmarked)} ticked without one; "
          f"{still_open} genuinely open). They move VERBATIM into {os.path.basename(archive)} — "
          f"history is kept, nothing is deleted.")
    print(f"  run: backlog-archive.py archive --repo {a.repo}")
    report_held(nested)
    return 12


def _partition_movable(text: str, plan: HeadingPlan, marked: _Group,
                       unmarked: _Group) -> Tuple[_Group, _Group, List[str]]:
    """Hold back every entry whose id ALSO labels something that stays open, and name those ids.

    Do not CREATE a both-files pair. When a single id labels TWO entries in the open file — one
    ticked, one still open — moving the ticked one puts that id in both files and the next run is
    blocked by a violation this command produced a second earlier. Measured by the archive run itself
    on the canonical backlog: B-20260905-STAGE1-SMOKE-DRAINING. Only those entries are skipped, never
    the whole run: one bad id must not hold back the other 230.

    `| plan.staying`: the pinned walk sees checkbox entries only, so with the gate on an id that
    names an OPEN HEADING was unprotected and the same id could end up in both files. `cmd_verify`
    cannot catch that — it is pinned checkbox-only on BOTH sides (measured: no violation, no exit 2)
    — so it would be a silently split namespace, the 2026-07 "archive took the same entry twice"
    class, rather than a blocked run. Empty with the gate off; the pin stays where it is.
    """
    staying = {e.key for e in zb.iter_entries(text, kinds=(zb.KIND_CHECKBOX,))
               if e.status != "done" or "[ ]" in e.body} | plan.staying
    shared_id = [e.ident or e.key for group in (marked, unmarked) for _, e in group
                 if e.key in staying]
    return ([(ln, e) for ln, e in marked if e.key not in staying],
            [(ln, e) for ln, e in unmarked if e.key not in staying], shared_id)


def _print_dry_run(movable: _Group, marked: _Group, unmarked: _Group,
                   mints: List[zb.Entry]) -> None:
    """What `archive --dry-run` says. Split out for length only; every line is verbatim."""
    print(f"would move {len(movable)} resolved entries out of backlog.md into {ARCHIVE_NAME}: "
          f"{len(marked)} with a recorded resolution, {len(unmarked)} ticked without one "
          f"(separate section)")
    print(f"  would mint an id for {len(mints)} of them (unaddressable once archived otherwise)")
    for _, e in movable[:5]:
        print(f"  - {e.ident or '(no id)'} line {e.lineno}: {e.body[:80]}")


def _refuse_tracked_archive(real: str, archive: str) -> None:
    """`git check-ignore` answers for paths that do not exist yet, which is the whole point: the
    question is whether the archive WOULD be tracked. Defaulting an absent archive to the source's
    own status disabled this check entirely (caught by A10). `is False`, never a bare falsy test:
    `is_ignored` returns None outside a repository and "unknown" must not read as "tracked"."""
    if is_ignored(real) and is_ignored(archive) is False:
        sys.exit(f"refusing to create a git-TRACKED archive beside a git-IGNORED backlog.\n"
                 f"add these lines to .gitignore first, then re-run:\n"
                 f"    /memory/{os.path.basename(archive)}\n"
                 f"    /memory/{LOCK_NAME}/\n"
                 f"    /memory/{INDEX_NAME}")


def _entry_block_to_move(lines: List[str], lineno: int,
                         e: zb.Entry) -> Tuple[List[str], int, int]:
    """One entry's block, id minted if it had none, newline-terminated — plus its (start, end).

    Called only from inside the archive lock, and it ABORTS rather than returning a partial answer:
    both exits below leave the two files untouched because nothing has been renamed yet.
    """
    idx = lineno - 1
    # rstrip("\r\n"), not ("\n"): Entry.raw comes from splitlines(), which treats
    # \r\n as ONE terminator and yields a \r-free line, while keepends=True keeps the \r.
    # On a CRLF backlog every entry then failed this check and both commands refused
    # forever with "changed under the lock — re-run", pointing at concurrency.
    if idx >= len(lines) or lines[idx].rstrip("\r\n") != e.raw:
        sys.exit("backlog changed under the lock — re-run")
    end = entry_block(lines, idx)
    block = list(lines[idx:end])
    if not e.ident:
        # A mint that cannot happen ABORTS the run, before either rename. Carrying on is
        # what put an id-less entry into the archive, unfindable by `lookup` for ever
        # (D2's second door). Fail-closed like the two conservation checks in the caller;
        # holding this one entry instead would mean deciding what moves outside the write
        # loop, which is a decision `classify` owns and this function must not take.
        minted = mint_into(block[0], mint_id(e.body))
        if minted is None:
            sys.exit(f"internal: cannot mint an id into {block[0]!r} — nothing written")
        block[0] = minted
    return [ln if ln.endswith("\n") else ln + "\n" for ln in block], idx, end


def _build_sections(lines: List[str], sections: List[Tuple[_Group, str]],
                    day: str) -> Tuple[str, List[str], List[int], Set[int]]:
    """(text to append, the moved lines, lines-per-entry, the open-file indices to drop)."""
    moved: List[str] = []
    entries_moved: List[int] = []     # lines per entry, so the header can count entries
    drop: Set[int] = set()
    appended = ""
    for group, shape in sections:
        group_lines: List[str] = []
        for lineno, e in group:
            block, idx, end = _entry_block_to_move(lines, lineno, e)
            group_lines.extend(block)
            entries_moved.append(len(block))
            drop.update(range(idx, end))
        if group_lines:
            # n is the number of ENTRIES, not lines. A real archive in the wild carried
            # "(106 completed items moved out)" for three multi-line entries, which is how a
            # line count reads once entries stop being one line long.
            appended += f"\n## Archived from backlog.md on {day} " + shape.format(
                n=len(group)) + "\n"
            appended += "".join(group_lines)
            moved.extend(group_lines)
    return appended, moved, entries_moved, drop


def _refuse_foreign_entries(lines: List[str], drop: Set[int],
                            sections: List[Tuple[_Group, str]], interior: Set[int]) -> None:
    """Refuse the whole run when a moved range swallowed an entry that was not selected for it.

    THE ONE CHECK THAT DOES NOT DEPEND ON THE BOUNDARY RULE BEING RIGHT. The two existing conservation
    checks above are both blind to mis-attribution by construction, and their own comment says so: the
    presence check finds every moved line present in the archive, and the line-accounting check balances
    exactly, because a swallowed entry's lines really did move exactly once. So an over-covering block
    passes both while carrying somebody else's OPEN work out of the file.

    Measured (aggregate review, behaviour audit, default gate-off `archive`): a stray ``` inside one
    entry's prose pairs with a LATER entry's code-sample opener, the span between them is stepped over
    as "content", and `- [ ] B-two still OPEN work` is archived — after which `lookup` answers ARCHIVED
    for live work, the exact inverse of the defect this whole change exists to fix. Fleet exposure today
    is zero (399 backlog files, none with an odd per-character fence count), so this is a latent class,
    not a live incident.

    It is enforced HERE rather than inside `entry_block` because the boundary rule cannot decide it. A
    flush-left `# comment` or a `- [ ] sample` inside a fenced block is legitimately content — the suite
    pins both — so "does this span contain something entry-shaped" is not answerable from the markdown
    alone. It IS answerable here: `classify` already resolved which entries exist and which were
    selected, so "a line being dropped is the first line of an entry nobody selected" is exact. An
    earlier attempt at the `entry_block` heuristic traded this over-cover for a worse under-cover,
    splitting a genuine fenced recipe at its own `#` comment.

    TWO BOUNDS ON WHAT IT SEES, both deliberate and both found by running it:

      * `kinds=(zb.KIND_CHECKBOX,)`, pinned like every other write-path call in this file. The first
        version used `_lookup_kinds()` because a swallowed heading is as bad as a swallowed checkbox —
        and the mechanical pin guard immediately failed the run, reporting a THIRD unpinned call in a
        write path. It was right to: "this particular read is harmless because it only ever refuses" is
        exactly the reasoning the guard exists to make unnecessary. The measured hazard (BEHAV-1's
        `- [ ] B-two still OPEN work`) is a checkbox entry, so the pin costs nothing today; a swallowed
        HEADING is reachable only with the gate on, where `heading_candidates` has already refused
        overlapping spans.
      * `interior` — the lines inside a MOVING heading's span. A child entry there travels with its
        parent by design (AC5), so without this the check refuses the very nesting the feature exists
        to support: it did, on the gate-on acceptance fixture, naming a legitimately carried child.

    Fail-closed and before either rename, like the checks above: nothing is written.
    """
    selected = {e.lineno for group, _ in sections for _, e in group}
    for e in zb.iter_entries("".join(lines), kinds=(zb.KIND_CHECKBOX,)):
        if e.lineno - 1 in drop and e.lineno not in selected and e.lineno not in interior:
            sys.exit(
                "internal: the block being moved contains %s (backlog.md:%d), which was not selected "
                "for archiving — a boundary over-covered into another entry. Nothing written; the two "
                "conservation checks cannot see this, so this refusal is the only signal."
                % (e.ident or e.key, e.lineno))


def _write_archive_sections(real: str, archive: str, sections: List[Tuple[_Group, str]],
                            day: str, interior: Set[int]) -> Tuple[int, int]:
    """The locked write: re-read, build, conserve, rename. Returns (entries moved, lines moved)."""
    with Lock(os.path.dirname(real)):
        text = read(real)                                   # re-read under the lock
        lines = text.splitlines(keepends=True)
        appended, moved, entries_moved, drop = _build_sections(lines, sections, day)
        kept = [ln for i, ln in enumerate(lines) if i not in drop]

        old_archive = read(archive)
        new_archive = old_archive + appended
        # Conservation, BEFORE either rename. Note what this does NOT catch, learned the hard way:
        # it proves nothing was lost, never that nothing was duplicated.
        for ln in moved:
            if ln not in new_archive:
                sys.exit("internal: a moved line is not present in the archive — nothing written")
        if len(kept) != len(lines) - len(moved):
            sys.exit("internal: line accounting mismatch — nothing written")
        _refuse_foreign_entries(lines, drop, sections, interior)

        src_mode = os.stat(real).st_mode & 0o7777
        atomic_write(archive, new_archive, src_mode if not os.path.exists(archive) else None)
        atomic_write(real, "".join(kept), None)
    return len(entries_moved), len(moved)


def cmd_archive(a: argparse.Namespace) -> int:
    """Move resolved entries out of backlog.md, into two sections that differ in the evidence they
    carry.

    The five `_`-prefixed helpers above are this command's own, in call order, and the split is
    LENGTH only — 95 body lines against the 50 in `rules/file-limits.md`. The warning that used to
    stand here is still worth its space, because it names how a previous split of this function went
    wrong: an earlier version accumulated four rounds of SCRIPTED patches and ended up with a dead
    duplicate of itself that the test suite could not see, because Python simply uses the last
    definition. `tests/hooks/test-python-no-shadowed-defs.sh` now gates exactly that, and the
    behaviour of this command is pinned byte-for-byte by the 32 groups of
    `tests/hooks/test-backlog-archive-dedup.sh`, which this refactor left unedited.
    """
    _, real, archive = resolve(a.repo)
    text = read(real)
    if not text:
        sys.exit(f"no backlog at {real}")

    marked, unmarked, skipped_nested, plan = classify(text)

    # Never archive INTO an inconsistent namespace. An id already defined in both files needs a
    # per-entry decision (stale copy / partial closure / real regression) first; moving more entries
    # across cannot improve that and can hide the duplicate inside the archive, where the two-file
    # `verify` cannot see it at all.
    bad_pairs, _, _, _ = undeclared_pairs(real, archive)
    if bad_pairs:
        sys.exit(f"refusing to archive: {len(bad_pairs)} id(s) are already defined in BOTH files.\n"
                 f"run `backlog-archive.py verify --repo {a.repo}` and settle those first — "
                 f"archiving on top of them hides the duplicates inside the archive.")

    # Do not CREATE one either — see `_partition_movable`, which holds back every entry whose id also
    # labels something that stays open, and names those ids for `report_skips` below.
    marked, unmarked, shared_id = _partition_movable(text, plan, marked, unmarked)
    movable = marked + unmarked

    def report_skips() -> None:
        report_held(skipped_nested)
        if shared_id:
            print(f"NOT MOVED, id does double duty: {len(shared_id)} {shared_id[:5]} — another entry "
                  f"that stays OPEN carries the same id, so archiving this one would put it in both "
                  f"files. Give one of the two its own id (see backlog-protocol.md).")

    if len(movable) < a.min_resolved:
        print(f"nothing to do: {len(movable)} resolved entries < --min-resolved {a.min_resolved}")
        report_skips()
        return 0

    mints = [e for _, e in movable if not e.ident]
    if a.dry_run:
        _print_dry_run(movable, marked, unmarked, mints)
        report_skips()
        return 0

    _refuse_tracked_archive(real, archive)

    day = time.strftime("%Y-%m-%d")
    sections = [
        (marked, "({n} completed items moved out)"),
        # The heading is the whole safeguard for this group: a reader must be able to tell an entry
        # closed with evidence from one closed with nothing but a checkbox.
        (unmarked, "({n} ticked WITHOUT a recorded resolution — the reason was never written down; "
                   "the tick is the only evidence)"),
    ]
    # A child entry inside a MOVING heading's block is legitimately carried out with its parent —
    # AC5's whole point — so the foreign-entry refusal must not read it as an over-cover. Same
    # expression `classify` uses for the same reason, and 1-based like `Entry.lineno`.
    interior = {n for start, end in plan.spans for n in range(start + 1, end + 1)}
    n_entries, n_lines = _write_archive_sections(real, archive, sections, day, interior)

    print(f"moved {n_entries} entries ({n_lines} lines) to {archive} "
          f"({len(marked)} with a recorded resolution, {len(unmarked)} without)")
    if mints:
        print(f"minted an id for {len(mints)} entries that had none")
    report_skips()
    return 0


def _keys_for_ids(op: Dict[str, zb.Entry], want_ids: List[str]) -> Set[str]:
    """The FILED keys of the entries `--id` names, or an exit naming the id that resolves to none.

    --id names an entry by the id PRINTED on it; the key it is FILED under is a separate question,
    and only entry_key() answers it. An ordinal id (B-70) is filed under its content fingerprint,
    because an ordinal is a position and collides between entries. This used to build "id:" + the
    argument by hand, so `--id B-70` — the form the usage line advertises — could never match and
    always answered "not defined in backlog.md" about an entry sitting in the file. Resolve through
    the open entries instead, so there is one definition of a key.
    """
    by_ident: Dict[str, List[zb.Entry]] = {}
    for e in op.values():
        if e.ident:
            by_ident.setdefault(e.ident.lower(), []).append(e)
    out: Set[str] = set()
    for i in want_ids:
        hits = by_ident.get(i.lower(), [])
        if not hits:
            sys.exit(f"{i}: not defined in backlog.md — nothing removed")
        if len(hits) > 1:
            # only an ordinal can do this (a real id keys on itself, so `op` holds one of it)
            sys.exit(f"{i}: {len(hits)} open entries carry this id, so it does not name one — "
                     f"pass the --key that `verify` printed for the copy you mean. Nothing removed")
        out.add(hits[0].key)
    return out


def _settle_targets(op: Dict[str, zb.Entry], arch_all: Dict[str, zb.Entry],
                    want: Set[str]) -> Tuple[List[Tuple[zb.Entry, zb.Entry]], List[str]]:
    """THE SETTLE LOOP: the (open copy, archived copy) pairs it is safe to remove, plus the keys
    whose safety rests on a bare tick. Every refusal here leaves BOTH files untouched — it runs
    before any line is dropped, which is what makes `sys.exit` the right answer rather than a
    partially-settled pair."""
    targets: List[Tuple[zb.Entry, zb.Entry]] = []
    weak: List[str] = []
    for key in sorted(want):
        if key not in op:
            sys.exit(f"{key}: not defined in backlog.md — nothing removed")
        if key not in arch_all:
            sys.exit(f"{key}: not in the archive, so it is not a stale copy — nothing removed")
        if arch_all[key].status != "done":
            sys.exit(f"{key}: the archived entry is not ticked — that is not a closure, "
                     f"nothing removed")
        if not zb.has_resolution_marker(arch_all[key].body):
            # Since bare ticks are archived too (policy change 2026-09-21), an archived entry
            # legitimately may not say why. Refusing here left such a pair with NO remedy at all,
            # which is worse: the open copy stays and blocks every run. Proceed, but say what the
            # decision rests on — and the removed text is kept in the archive either way.
            weak.append(key)
        targets.append((op[key], arch_all[key]))
    return targets, weak


def cmd_drop_stale(a: argparse.Namespace) -> int:
    """Remove the OPEN copy of ids the archive already records as resolved — the action `verify` asks
    for and, until now, gave no safe way to perform.

    Doing it by hand is why it stays undone: `verify` prints "stale open copy (remove it)" and the
    next person has to edit a 1.8 MB file without deleting the wrong line. So the judgement stays
    explicit (every id is named on the command line, nothing is inferred) and the mechanics are
    checked: the id must be defined in BOTH files and the ARCHIVED copy must carry a resolution
    marker, or this refuses.

    The open text is NOT discarded. Closing an entry rewrites it into a description of the fix, so the
    open copy is often the only place the PROBLEM is stated — that is exactly why "remove the stale
    copy" is risky advice. It is appended to the archive as an indented quote, not a checkbox bullet,
    so the text survives while the definition namespace stays disjoint (a second `- [x] <id>` line
    would be a duplicate the two-file `verify` cannot see).
    """
    _, real, archive = resolve(a.repo)
    # `verify` reports a content key (`fp:…`) for the 65% of entries that carry no id, and until now
    # there was no way to act on one — the only settle-it command took --id. A reported defect with no
    # available remedy is how 31 pairs accumulated in the first place.
    want_ids = [i.strip().lstrip("[").rstrip("]") for i in (a.id or [])]
    want = {k.strip().lower() for k in (a.key or [])}
    with Lock(os.path.dirname(real)):
        text = read(real)
        arch_text = read(archive)
        arch = {e.key: e for e in zb.iter_entries(arch_text, kinds=(zb.KIND_CHECKBOX,))}
        op = {e.key: e for e in zb.iter_entries(text, kinds=(zb.KIND_CHECKBOX,))}
        want |= _keys_for_ids(op, want_ids)
        # the archive is indexed by every key an entry can be known by, so a pre-mint content key
        # still finds the entry it was archived as
        arch_all = all_keys_index(arch.values())
        targets, weak = _settle_targets(op, arch_all, want)

        lines = text.splitlines(keepends=True)
        drop = set()
        quoted = []
        for o, _ in targets:
            idx = o.lineno - 1
            if idx >= len(lines) or lines[idx].rstrip("\r\n") != o.raw:
                sys.exit("backlog changed under the lock — re-run")
            # The WHOLE entry, not its bullet line: entries run 30+ lines in real backlogs, and
            # removing only the first line leaves the rest orphaned in the open file — indented prose
            # with nothing to attach it to, which the next reader cannot even attribute.
            end = entry_block(lines, idx)
            drop.update(range(idx, end))
            quoted.append(f"  > superseded open copy of {o.ident or o.key}:\n")
            quoted.extend("  > " + ln for ln in lines[idx:end])
        if a.dry_run:
            for o, _ in targets:
                print(f"would remove backlog.md:{o.lineno} {o.ident or o.key} "
                      f"(archive records it resolved)")
            return 0

        kept = [ln for i, ln in enumerate(lines) if i not in drop]
        # `len(targets)`, not `len(quoted)`: the same ENTRIES-not-LINES distinction `_build_sections`
        # documents above, repeated here because `quoted` accumulates one `>` line per line of every
        # block plus a header line per entry — so one 30-line entry wrote "(31 stale duplicate(s))".
        # Pre-existing (identical at e565df29:609) and found by the aggregate review's CQ audit, which
        # noted the file already carries the fix for this defect class two hundred lines earlier.
        header = (f"\n## Superseded open copies removed on {time.strftime('%Y-%m-%d')} "
                  f"({len(targets)} stale duplicate(s), text kept verbatim, not re-defined)\n")
        atomic_write(archive, arch_text + header + "".join(quoted), None)
        atomic_write(real, "".join(kept), None)
    for o, _ in targets:
        print(f"removed the stale open copy of {o.ident or o.key} (text kept in {ARCHIVE_NAME})")
    if weak:
        print(f"NOTE {len(weak)} of them rested on a BARE TICK in the archive, with no recorded "
              f"reason: {weak[:5]}. The removed text is quoted there, so nothing is lost — but if one "
              f"of these was still live work, that is where to look.")
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(prog="backlog-archive.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--repo", default=os.getcwd())
    sub.add_parser("path", parents=[common])
    p = sub.add_parser("lookup", parents=[common]); p.add_argument("query")
    p = sub.add_parser("index", parents=[common]); p.add_argument("--rebuild", action="store_true")
    sub.add_parser("verify", parents=[common])
    sub.add_parser("status", parents=[common])
    p = sub.add_parser("drop-stale", parents=[common])
    p.add_argument("--id", action="append")
    p.add_argument("--key", action="append", help="a key as `verify` prints it, e.g. fp:4fe544421099")
    p.add_argument("--dry-run", action="store_true")
    p = sub.add_parser("archive", parents=[common])
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--min-resolved", type=int, default=1)
    a = ap.parse_args(argv)
    if a.cmd == "drop-stale" and not (a.id or a.key):
        ap.error("drop-stale needs at least one --id or --key")
    return {"path": cmd_path, "lookup": cmd_lookup, "index": cmd_index,
            "verify": cmd_verify, "status": cmd_status, "archive": cmd_archive,
            "drop-stale": cmd_drop_stale}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
