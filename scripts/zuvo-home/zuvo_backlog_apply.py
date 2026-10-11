"""THE DISPOSITIONS: what a verdict licenses, which helper performs it, and what is reported when
nothing can be performed at all. Imported by backlog-groom.py; not a script, no shebang, no
executable bit.

WHY ITS OWN MODULE, and the number is the argument rather than the taste. `backlog-groom.py` measured
**376 raw lines** before `apply` existed, against `rules/file-limits.md`'s 400-line default for a
Python module (800 is the automatic CQ11 FAIL) — the same ceiling that already moved the block
boundary, the heading policy and the mint out of `backlog-archive.py`, and the mint pre-pass out of
this command. `apply` plus its subparser is ~60 lines, so it crossed the default on arrival. This is
ONE cohesive concern: which verdict licenses which action, and the discipline a delegated write owes.

THREE THINGS THIS FILE DOES NOT DO, each of them deliberate:

  * IT NEVER WRITES `backlog-done.md`, and it never writes `backlog.md`. `backlog-protocol.md` records
    what a hand-written archive did: it copied the helper's heading format, counted LINES as items
    ("106 completed items" for three entries) and destroyed quoted open copies. So the closures are
    delegated to `backlog-archive.py archive` / `drop-stale` as a SUBPROCESS, and every byte that
    changes in either file is that helper's. `tests/hooks/test-backlog-grooming.sh` proves it by
    running the helper ALONE on a pristine copy and comparing the two results byte for byte.
  * IT NEVER REORDERS THE OPEN FILE. Decision 7 keeps ordering, grouping and backfilled metadata in
    the ledger and the rendered document, because option A (re-emitting `backlog.md` in a new order)
    has no oracle — the per-entry `text_sha` is the entry-level conservation check that line-level
    ones cannot express. A ledger row may therefore carry a `rank`/`order` hint and this module
    COUNTS it, reports it, and moves no line.
  * IT NEVER REPORTS A FALSE `archived`. Two of the five verdicts can reach a state where neither
    helper will act — a `DUPLICATE-OF` (a report, never a licence to merge) and a stale entry that is
    neither ticked nor already in the archive. Those are `no-remedy` WITH A REASON, because the
    failure mode this whole PR exists to end is a disposition that reads as done and is not.

THE HEADING GATE IS PROCESS-GLOBAL, so it is set PER INVOCATION and never exported.
`ZUVO_BACKLOG_HEADING_ARCHIVE=1` is read by `zuvo_backlog_heading.heading_candidates` at call time,
and PR 1's decision 6 gates heading archival behind it precisely because archiving a heading MOVES
LINES. `os.environ[...] = "1"` here would turn it on for every later call in this process — including
a second, checkbox-only delegation that must not see it — which is `B-20260928-HEADING-GATE-PROCESS-
GLOBAL`. It therefore travels in a COPY of the environment handed to one `subprocess.run`, and the
suite asserts both that a heading row gets the gate and that this process's own environment is
unchanged afterwards.

THE UNDERSCORE IN THE NAME IS LOAD-BEARING, exactly as in the siblings: `install.sh` globs
`scripts/zuvo-home/*` into the machine-global `~/.zuvo/`, so these end up FLAT with no package around
them and a plain same-directory import resolves identically in both layouts. `sys.path` is the
IMPORTER's job. By importing the parser this module joins the pin-guard family that
`tests/hooks/test-backlog-headings.sh` (H19c) DERIVES, where its expectation is the default one: NO
`iter_entries` call lives here — reading and parsing the two files is backlog-groom.py's job.
"""
from typing import Dict, List, Sequence, Set, Tuple

import zuvo_backlog_ledger as zl
import zuvo_backlog_parse as zb
from zuvo_backlog_block import declared_reopen
# The delegated closures and the `Action` that requests one, extracted whole for the
# 400-line reason that module's docstring records. Re-exported by NAME below.
from zuvo_backlog_closure import (ARCHIVER, HEADING_GATE, VERB_ARCHIVE,  # noqa: F401
                                  VERB_DROP, Action, archiver_path, guard_write, perform)
# The family's exit-code registry and its one refusal primitive. Imported rather than re-declared: a
# second copy of "codes outside {0,1,2,10,11,12}" is how one of them drifts back into the taken set.
from zuvo_backlog_prepass import (RC_LEDGER, RC_UNVERIFIED,
                                  refuse)

def archived_resolved_keys(archived: Sequence[zb.Entry]) -> Set[str]:
    """Every key under which the ARCHIVE records a TICKED entry.

    `drop-stale` refuses unless the archived copy's status is `done`, so an untitled or still-open
    archived copy is not a licence to remove the open one — asking for it would be a guaranteed
    refusal, which is a worse report than `no-remedy`.
    """
    return {k for e in archived if e.status == "done"
            for k in zb.keys_for(e.body, e.ident)}


def _decide(entry: zb.Entry, verdict: str, resolved: Set[str],
            reopen: str) -> Tuple[str, str, str, str]:
    """(disposition, reason, verb, the key that licensed it) for one verdict.

    EVERY branch carries a reason, including the ones that do nothing, because "kept" and
    "no-remedy" are answers a reader has to be able to audit.

    The two stale verdicts share a remedy ladder rather than a verdict-keyed action: what can be
    performed depends on the FILE (is the entry ticked, is a resolved copy already archived), not on
    which of the two reasons made it stale. Keying the action on the verdict instead would ask
    `drop-stale` for an entry with no archived copy and get a refusal where a report was owed.
    `reopen` (`declared_reopen`, measured only for an entry the archive resolves) withholds the drop the
    same way: `drop-stale` refuses a declared re-open, and one refused key refuses the whole batch.
    """
    if verdict == zl.VERDICT_STILL_REAL:
        return ("kept", "the verdict says the entry is still true; closing it would be a false "
                "closure", "", "")
    if verdict == zl.VERDICT_NOT_VERIFIABLE:
        return "kept", "no verdict could be reached, and an unreachable verdict licenses nothing", "", ""
    if verdict == zl.VERDICT_DUPLICATE_OF:
        return ("no-remedy",
                "DUPLICATE-OF is a REPORT, never a licence to merge: the two entries can differ in "
                "scope and no helper here can decide which text survives — settle the pair by hand",
                "", "")
    # THE KEY THAT MATCHED travels with the decision. `keys_for` is the pre-mint bridge, so the match
    # can be on a key that is not `entry.key`, and the helper has to be handed that one.
    matched = next((k for k in sorted(zb.keys_for(entry.body, entry.ident)) if k in resolved), "")
    if matched and not reopen:
        return ("dropped",
                "the archive already records this entry resolved, so the open copy is a stale "
                "duplicate and `drop-stale` removes it, quoting the open text into the archive",
                VERB_DROP, matched)
    if entry.status == "done":
        return ("archived",
                "the entry is ticked, so `archive` moves it out with whatever evidence it carries",
                VERB_ARCHIVE, "")
    if reopen:
        return ("no-remedy", f"{verdict}, but the open copy declares {reopen}, the live definition, "
                f"so `drop-stale` refuses it: tick it once the rest is done, or remove a wrong one", "", "")
    return ("no-remedy",
            f"{verdict} with nothing performable: the entry is NOT ticked and the archive holds no "
            f"resolved copy of it, so `archive` (which moves only ticked entries) and `drop-stale` "
            f"(which needs an archived ticked copy) both decline. Reported as no-remedy, never as a "
            f"false `archived` — tick it with a resolution marker, or settle it by hand",
            "", "")


def dispositions(entries: Sequence[zb.Entry], rows: Sequence[zl.Row],
                 archived: Sequence[zb.Entry], lines: List[str]) -> List[Action]:
    """One Action per entry that carries a CURRENT verdict, in document order.

    `plan_reuse().reuse` is the source of the pairs and not a fresh key walk: it is the same
    `(key, text_sha)`-exact match `coverage` counts, so "every entry is verified" and "every entry has
    a disposition" cannot disagree about which rows are current. An entry whose text moved after it
    was verified is in `reverify`, never here — and `cmd_apply` has already refused by then.
    """
    resolved = archived_resolved_keys(archived)
    out: List[Action] = []
    for entry, row in zl.plan_reuse(entries, rows).reuse:
        verdict = str(row.get("verdict", ""))
        # Only an entry `_decide` would drop can be refused by `drop-stale`, so only those are measured.
        droppable = entry.kind == zb.KIND_CHECKBOX and any(
            k in resolved for k in zb.keys_for(entry.body, entry.ident))
        reopen = declared_reopen(lines, entry) if droppable else ""
        disposition, reason, verb, key = _decide(entry, verdict, resolved, reopen)
        out.append(Action(entry, row, disposition, reason, verb, key))
    return out


def order_hints(actions: Sequence[Action]) -> Tuple[int, bool]:
    """(rows carrying a `rank`/`order` hint, whether that hint asks for an order the FILE does not
    already have).

    Both halves are reported so "the open file is not reordered" is an assertion with a subject. A
    ledger with no hints, or with hints that happen to agree with document order, would make the
    byte-identity claim below true for a reason that has nothing to do with this module.
    """
    ranked = [(a, a.row.get("rank", a.row.get("order"))) for a in actions]
    hinted = [(a, r) for a, r in ranked if isinstance(r, (int, float))]
    want = [a.subject for a, _ in sorted(hinted, key=lambda pair: pair[1])]
    have = [a.subject for a, _ in hinted]
    return len(hinted), want != have




def disposition_rows(actions: Sequence[Action]) -> List[zl.Row]:
    """The ledger rows that record what was done — the verified row, with `disposition` replaced.

    APPENDED, never rewritten: the ledger is append-only so that two writers and two passes leave a
    history, and `_dedup` reduces it at READ time on `(key, text_sha)` keeping the later
    `verified_at`. The stamp is therefore carried over UNCHANGED — equal stamps keep the LAST appended
    row, which is this one — because bumping it would claim the entry was re-VERIFIED just now, and
    nothing here re-examined anything.
    """
    out: List[zl.Row] = []
    for a in actions:
        row = dict(a.row)
        row["disposition"] = a.disposition
        out.append(row)
    return out


def ledger_or_refuse(repo: str) -> Tuple[str, zl.LedgerRead]:
    """(ledger path, its parsed contents) — or a refusal, because `apply` is the destructive command.

    `plan` PRINTS its ledger defects and carries on: it decides nothing, so a line it cannot read
    costs a re-verification. `apply` closes entries, and a ledger it cannot fully account for is a
    ledger whose unreadable lines might have said `STILL-REAL`. `read_ledger` already keeps a defective
    row out of `rows`, so coverage would refuse anyway — this refusal exists to say WHICH line is
    broken instead of reporting an entry as unverified and letting someone re-verify it for ever.
    """
    ledger = zl.ledger_paths(repo)[1]
    read = zl.read_ledger(ledger)
    for line in read.defects:
        print("LEDGER_DEFECT=" + line)
    if read.defects:
        refuse(RC_LEDGER, f"{ledger} has {len(read.defects)} unreadable line(s) and `apply` closes "
                          f"entries; a line that might have said STILL-REAL is not a line to guess at")
    return ledger, read


def coverage_or_refuse(entries: Sequence[zb.Entry], rows: Sequence[zl.Row]) -> int:
    """Decision 10, mechanically: refuse unless every entry carries a CURRENT verdict, NAMING the
    shortfall by id and exiting with a code outside `{0,1,2,10,11,12}`.

    The user's binding decision 3 is "wszystkie ma najpierw zweryfikować" — all of them first — and
    this is where it becomes a mechanism rather than a paragraph. It is enforced HERE, at the
    destructive action, and deliberately not as a gate on unrelated runs: `append-runlog` records that
    housekeeping able to refuse a completed run gets switched off within a week.

    Every missing id is printed, not a sample. "494 of 495" sends a reader back to a 265 KB file to
    diff two lists by hand, which is how a refusal stops being acted on.
    """
    verified, total, short = zl.coverage(entries, rows)
    print("VERIFIED=%d/%d" % (verified, total))
    for subject in short:
        print("UNVERIFIED=" + subject)
    if verified != total:
        named = ", ".join(short[:10]) + (f" … and {len(short) - 10} more" if len(short) > 10 else "")
        refuse(RC_UNVERIFIED,
               f"refusing to apply any disposition: {verified} of {total} entries carry a current "
               f"verdict, {len(short)} do not. every entry is verified first — nothing is closed, "
               f"ranked, grouped or rendered without a verdict backed by an evidence line. the "
               f"shortfall, by id: {named}. run `backlog-groom.py plan` then the verify lane, or read "
               f"the UNVERIFIED= lines above for the full list.")
    return verified


def report(actions: Sequence[Action]) -> Dict[str, int]:
    """Print one line per disposition and the per-disposition totals; return the totals.

    A `no-remedy` prints its REASON on the same line. That is the whole difference between this and a
    false `archived`: an operator who reads `no-remedy` has to be able to see what would have to
    change for something to be performable.
    """
    counts = {d: 0 for d in zl.DISPOSITIONS}
    for a in actions:
        counts[a.disposition] = counts.get(a.disposition, 0) + 1
        print("DISPOSITION=%s|%s|%s|%s" % (a.subject, a.disposition, a.verb or "-", a.reason))
    for name in zl.DISPOSITIONS:
        print("DISPOSED=%s %d" % (name, counts.get(name, 0)))
    hints, differs = order_hints(actions)
    # Decision 7, reported so it can be asserted: the ledger may ask for an order and the open file
    # is still not reordered. A run with no hints says so, which is what keeps the claim honest.
    print("ORDER_HINTS=%d different_from_file=%d applied=0" % (hints, int(differs)))
    return counts
