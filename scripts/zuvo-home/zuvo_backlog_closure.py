"""THE CLOSURES this family can PERFORM, and the `Action` that requests one.

Split from `zuvo_backlog_apply.py` at 411 raw lines against the 400-line default in
`rules/file-limits.md`, and the seam is the one the code already had: that module DECIDES what each
verdict licenses, this one asks `backlog-archive.py` to do it and checks that the helper agrees about
the SET. `Action` lives here because it is the REQUEST — the decision side builds one, the delegation
side is the only thing that can honour it, and putting it with the consumer is what keeps the import
graph one-directional (the alternative is a cycle, not a preference).

`groom` NEVER WRITES EITHER BACKLOG FILE ITSELF. Every closure is `backlog-archive.py`'s, invoked as a
subprocess, for the reason `shared/includes/backlog-protocol.md` records about the hand-written
alternative.

THE UNDERSCORE IN THE NAME IS LOAD-BEARING, as in the siblings: `install.sh` globs
`scripts/zuvo-home/*` into the machine-global `~/.zuvo/`, so these end up FLAT with no package around
them and a plain same-directory import resolves identically in both layouts. By importing the parser
this module joins the H19c pin-guard family, where its expectation is the default one: NO
`iter_entries` call lives here.
"""
import os
import re
import subprocess
import sys
from typing import List, NamedTuple, Optional, Sequence, Tuple

import zuvo_backlog_io as zio
import zuvo_backlog_ledger as zl
import zuvo_backlog_parse as zb
from zuvo_backlog_prepass import RC_HELPER, RC_SCOPE, RC_UNKNOWN_IGNORE, refuse

ARCHIVER = "backlog-archive.py"
HEADING_GATE = "ZUVO_BACKLOG_HEADING_ARCHIVE"
HELPER_TIMEOUT = 180     # seconds; `archive` rewrites a 1.8 MB file under a lock

VERB_ARCHIVE = "archive"
VERB_DROP = "drop-stale"

# `would move N resolved entries` — `cmd_archive`'s own dry-run line, which is the ONLY oracle for
# what that command would move. Re-deriving its movable set here would duplicate `classify`, the
# heading walk and the double-duty partition, and the duplicate is what drifts.
_MOVE_RE = re.compile(r"would move (\d+) resolved entries")



class Action(NamedTuple):
    """One entry's disposition: what was decided, why, and which helper (if any) performs it."""

    entry: zb.Entry
    row: zl.Row
    disposition: str
    reason: str
    verb: str                       # "" when there is nothing to perform
    key: str = ""                   # the key the ARCHIVE recorded resolved, when that licensed the
                                    # drop — which may be the pre-mint content key rather than
                                    # `entry.key`, and the helper has to be told the one that matched

    @property
    def subject(self) -> str:
        """The id if the entry has one, else its content key — the same identity `coverage` names a
        shortfall by, so a disposition line and a refusal line are about comparably-named things."""
        return self.entry.ident or self.entry.key


def archiver_path() -> str:
    """The helper beside this module. `realpath`, so the flattened `~/.zuvo/` layout and the checkout
    both find their OWN copy rather than whichever one is first on `$PATH`."""
    return os.path.join(os.path.dirname(os.path.realpath(__file__)), ARCHIVER)


def _run(args: Sequence[str], repo: str, heading: bool) -> Tuple[int, str]:
    """Run the archiver as a subprocess and return (rc, its combined output).

    `sys.executable`, never the shebang: `backlog-archive.py`'s polyglot sh/python header exists
    because `#!/usr/bin/env python3` dies on Windows/Git Bash, and invoking the interpreter directly
    uses the SAME interpreter this module runs under instead of whatever `python3` resolves to.

    THE GATE TRAVELS IN A COPY. See the module docstring: `os.environ[HEADING_GATE] = "1"` would leak
    into every later call in this process, including a checkbox-only one that must not see it.
    """
    path = archiver_path()
    if not os.path.exists(path):
        refuse(RC_HELPER, f"the archiver is not beside this module at {path}; `groom` never writes "
                          f"{zio.ARCHIVE_NAME} itself, so without it there is no closure to perform")
    env = dict(os.environ)
    # SET OR CLEARED, never merely "not set". `dict(os.environ)` INHERITS the gate, so a parent that
    # exported ZUVO_BACKLOG_HEADING_ARCHIVE=1 handed it to every `heading=False` call too — and those
    # are the calls that must not see it, because archiving a heading MOVES lines. The suite's D5b
    # asserts the two subprocesses see different values, and it passed: its own parent had the variable
    # unset, which is the one configuration where the bug is invisible.
    env.pop(HEADING_GATE, None)
    if heading:
        env[HEADING_GATE] = "1"
    # A BOUNDED WAIT, like `zb.sh`'s own (`zuvo_backlog_parse.py` uses timeout=15). The callee's lock is
    # bounded by LOCK_WAIT, so no hang was demonstrated — but this chain reaches an unbounded
    # `git check-ignore`, and a delegation that can wait for ever is one an operator cannot kill cleanly.
    # The timeout is generous because `archive` rewrites a 1.8 MB file under a lock.
    try:
        proc = subprocess.run([sys.executable, path, *args, "--repo", repo], env=env,
                              capture_output=True, text=True, timeout=HELPER_TIMEOUT)
    except subprocess.TimeoutExpired as exc:
        refuse(RC_HELPER, f"`{ARCHIVER} {args[0]}` did not finish within {HELPER_TIMEOUT}s and was "
                          f"killed; nothing can be concluded about what it wrote, so this run stops "
                          f"rather than reporting a closure it cannot verify:\n  "
                          + (exc.stdout or b"").decode("utf-8", "replace")[-400:])
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def _drop(actions: Sequence[Action], repo: str, dry: bool) -> List[str]:
    """Delegate every `dropped` action to ONE `drop-stale`, and report its lines.

    ONE invocation for all of them, not one each: `_settle_targets` checks every key BEFORE dropping
    any line and exits leaving both files untouched, so a batch is all-or-nothing while a loop would
    leave a half-settled file behind the first refusal.
    """
    keys = [a.key or a.entry.key for a in actions if a.verb == VERB_DROP]
    if not keys:
        return []
    args = ["drop-stale"] + [x for k in keys for x in ("--key", k)] + (["--dry-run"] if dry else [])
    # Never the heading gate: `cmd_drop_stale` indexes `kinds=(KIND_CHECKBOX,)` on BOTH files, so a
    # heading key cannot be a target of it and the gate would change nothing while reading as if it did.
    rc, out = _run(args, repo, heading=False)
    if rc != 0:
        refuse(RC_HELPER, f"`{ARCHIVER} drop-stale` refused (rc={rc}) on {len(keys)} key(s) and "
                          f"changed nothing:\n  " + "\n  ".join(out.strip().splitlines()[-4:]))
    return out.strip().splitlines()


def _scope_or_refuse(out: str, want: Sequence[Action]) -> None:
    """The archiver's dry-run count must equal the number of entries this run intends to archive.

    AN ABSENT `would move N` LINE IS ITSELF A REFUSAL, not a pass, and that case is REACHABLE rather
    than defensive: `cmd_archive` prints "nothing to do: 0 resolved entries" — and no count line — when
    every ticked entry it found is HELD, which is what happens to a ticked entry carrying a live `[ ]`
    sub-item. So an entry `_decide` calls `archived` can be one the archiver will not move, and reading
    a missing count as agreement would report a closure that never happened.
    """
    # A COUNT, AND IT IS KNOWN TO BE WEAKER THAN A SET. A swap — an unlicensed ticked entry replacing a
    # licensed one the archiver held back — has the same cardinality and passes. Comparing IDENTITIES was
    # tried and reverted, for a measured reason rather than a difficulty: `archive --dry-run` names an
    # id-less entry as `- (no id) line 5:` while this side knows it as `fp:00d183281395`, so the two
    # identity spaces do not join for exactly the entries that have no id (and `(no id)` is not unique
    # among several). Line numbers do not join either, because `drop-stale` runs FIRST and shifts them.
    # Closing it needs the archiver to emit or accept a stable key — the same mechanism
    # `B-20261002-ARCHIVE-CHECK-THEN-ACT` already owes for the check-then-act window, and it is filed
    # there rather than half-built here.
    m = _MOVE_RE.search(out)
    if m is None:
        refuse(RC_SCOPE, f"`{ARCHIVER} archive --dry-run` printed no `would move N` line, so the set "
                         f"it would move cannot be compared with the {len(want)} this run intends "
                         f"({', '.join(a.subject for a in want[:5])}). A ticked entry holding a live "
                         f"`[ ]` sub-item is held back by the archiver, and reading a missing count as "
                         f"agreement would report a closure that never happened:\n" + out.strip())
    if int(m.group(1)) != len(want):
        refuse(RC_SCOPE,
               f"`archive` would move {m.group(1)} entries where {len(want)} carry a verdict that "
               f"licenses it ({', '.join(a.subject for a in want[:5])}). `archive` is a whole-file "
               f"action with no per-entry selection, so delegating it would close entries no verdict "
               f"licensed. Verify the difference first, or archive those entries by hand.")



def _archive(actions: Sequence[Action], repo: str, dry: bool, deferred: bool = False) -> List[str]:
    """Delegate the `archived` actions, but ONLY after the helper agrees about the SET.

    `archive` is a WHOLE-FILE action: it moves every resolved entry it finds, and it takes no
    per-entry selection. So a ticked entry whose verdict is `STILL-REAL` would be carried out by a
    delegation this module asked for on behalf of other entries — a closure no verdict licensed. The
    helper's own `--dry-run` count is the oracle (duplicating `classify` here is the drift that
    oracle exists to avoid), and a disagreement is a REFUSAL naming both numbers.

    `deferred` IS A DRY RUN'S HONEST ANSWER, not a bypass, and it exists because of a measured
    interaction: `cmd_archive` refuses outright while any id is defined in BOTH files, and an entry
    whose disposition is `dropped` is exactly such an id until `drop-stale` removes it. A real run has
    already dropped it by the time the scope check runs; a DRY run has not, so the oracle cannot answer
    a question about the file that would exist. Refusing there would make `apply --dry-run` unusable on
    every plan that both drops and archives, and pretending the check passed would be worse — so the
    dry run SAYS the scope check could not be taken, and performs nothing either way.
    """
    want = [a for a in actions if a.verb == VERB_ARCHIVE]
    heading = any(a.entry.kind == zb.KIND_HEADING for a in want)
    if not want:
        return []
    rc, out = _run(["archive", "--dry-run"], repo, heading)
    if rc != 0:
        if dry and deferred:
            print("SCOPE=deferred the archiver cannot be asked about a file it has not seen: "
                  "`drop-stale` was not performed, so an id is still defined in both files")
            return out.strip().splitlines()
        refuse(RC_HELPER, f"`{ARCHIVER} archive --dry-run` refused (rc={rc}):\n  "
               + "\n  ".join(out.strip().splitlines()[-4:]))
    _scope_or_refuse(out, want)
    lines = out.strip().splitlines()
    if dry:
        return lines
    rc, out = _run(["archive"], repo, heading)
    if rc != 0:
        refuse(RC_HELPER, f"`{ARCHIVER} archive` refused (rc={rc}):\n  "
               + "\n  ".join(out.strip().splitlines()[-4:]))
    return out.strip().splitlines()


def guard_write(real: str) -> None:
    """Fail CLOSED on `is_ignored() is None` before any closure is delegated.

    Deliberately NOT what the ledger's PLACEMENT check does: placement fails OPEN there, because the
    canonical backlog legitimately lives outside any git repository and "unknown" must not masquerade
    as "tracked". A CLOSURE rewrites both tracked files, so whether the edit is publishable decides
    whether it may happen at all, and the unknown answer is the one case where proceeding is the
    expensive mistake. Both directions are asserted, in the same directory, in the suite.
    """
    if zio.is_ignored(real) is None:
        refuse(RC_UNKNOWN_IGNORE,
               f"cannot tell whether {real} is git-tracked (no repository above it), and a closure "
               f"REWRITES it and {zio.ARCHIVE_NAME}: moving entries out of a tracked file publishes "
               f"the move, out of an ignored one it does not, and the two are not interchangeable. "
               f"run from inside the repository that owns the backlog, or use --dry-run.")


def perform(actions: Sequence[Action], repo: str, real: str, dry: bool,
            performed: Optional[List[Action]] = None) -> List[str]:
    """Run the delegated closures in the order that keeps them comparable, and return their output.

    `drop-stale` FIRST. It is per-entry and precise; `archive` is a whole-file action whose set is
    checked against the intended one, and an entry that is both ticked and already archived would be
    counted by `archive` before it is dropped and not after. Running the precise one first makes the
    set the scope check compares the set that is actually left.

    PERFORMED IS AN OUT-PARAMETER, and it exists because this function is NOT all-or-nothing and
    cannot be made so. `drop-stale` writes both files, and only then can `archive --dry-run` be asked
    about the file that now exists (see `_archive`'s `deferred` note) — so the scope refusal lands
    AFTER a destructive edit. `refuse` exits, so the caller's `append_rows` never ran: the run reported
    itself a refusal while having removed entries, and their ledger rows stayed `pending` for ever.
    Nothing reports an orphan like that; `plan` prints ORPHAN=, `apply` does not. The caller appends
    rows for whatever landed here before re-raising.
    """
    if any(a.verb for a in actions):
        guard_write(real)
    drops = _drop(actions, repo, dry)
    if performed is not None and not dry:
        performed.extend(a for a in actions if a.verb == VERB_DROP)
    out = _archive(actions, repo, dry, deferred=bool(drops))
    if performed is not None and not dry:
        performed.extend(a for a in actions if a.verb == VERB_ARCHIVE)
    return drops + out
