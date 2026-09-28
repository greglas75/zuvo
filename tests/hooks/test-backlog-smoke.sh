#!/usr/bin/env bash
# Whole-feature smoke proofs for the '## B-id' heading-entry dialect (plan revision 6, SMOKE1+SMOKE2).
#
# The two proofs here are NOT unit tests of a function — tests/hooks/test-backlog-headings.sh and
# tests/hooks/test-backlog-archive-dedup.sh own that. These two answer the only two questions the
# plan's ACs are actually about, end to end:
#
#   SMOKE1  Is the dedup loop closed ON THIS REPO, through the CLI an audit skill really invokes?
#           Every audit skill's mandatory dedup check runs `backlog-archive.py lookup <id>`. Before
#           Task 1 that answered ABSENT for entries written as a heading, so the finding was re-filed
#           as new — the loop the backlog protocol exists to prevent. Read-only, PROVEN read-only by
#           sha256 before/after rather than asserted in prose.
#
#   SMOKE2  Does the block boundary hold at fleet scale? `entry_block` decides which lines move when
#           an entry is archived. A boundary that is one line wrong splits an entry across two files
#           with every byte still present somewhere, so a conservation check passes and the defect is
#           MIS-ATTRIBUTION. The probe is therefore about ownership, not about byte counts.
#
# THREE RULES THIS FILE IS BUILT AROUND, each paid for earlier in this plan:
#
#  1. NO `^SKIP:` PATH. run-all.sh classifies "exit 0 with a leading SKIP:" as SKIP, and a SKIP never
#     fails the run. Measured on this task's predecessor: `rt --light` on the python-lint suite exits
#     0 while printing `SKIP: neither ruff nor mypy installed`, so two gates silently never ran
#     (B-20260928-RT-SKIPS-LINT-GATES). Every missing precondition here is `no` then `finish`.
#  2. `command_not_found_handle` CANNOT increment a counter. Bash runs it in a SUBSHELL, so
#     `FAIL=$((FAIL+1))` inside it is discarded on EVERY bash version — the naive form has never
#     counted anything (B-20260927-CNFH-NEVER-COUNTED). The evidence has to cross the subshell
#     boundary, and a FILE is the only thing that does; `finish` turns a non-empty marker into a real
#     FAIL. Same pattern as test-backlog-headings.sh, for the same measured reason.
#  3. NO DERIVED NUMBER IS HARDCODED. The heading count moved 81 -> 82 -> 83 -> 84 -> 91 during this
#     plan, mostly because the plan's own tasks filed their findings as `## B-` heading entries. Every
#     count and every sha256 below is DERIVED at run time and PINNED into the artifact; the only
#     literals are lower bounds that exist to stop a loop over zero ids reporting zero ABSENT.
#
# TWO DELIBERATE DEVIATIONS FROM THE PLAN'S PROSE, both because this file runs on every `run-all.sh`
# and not once during execute:
#
#  a. "Preconditions: clean tree" is NOT asserted. A dirty tree is the normal state of this repo (an
#     agent filing a backlog finding dirties memory/backlog.md several times a day), so gating on it
#     would be a false red, and it would be a WEAKER check than the one that replaces it: sha256 of
#     every file touched, before and after the whole run. The working-tree state of memory/backlog.md
#     is recorded in the artifact as an observation instead.
#  b. "install.sh not run (decision 7)" is asserted as what it actually MEANS here: the driver under
#     test is the REPO copy at $ROOT/scripts/zuvo-home/, never the machine-global ~/.zuvo/ copy that
#     install.sh writes. That is checked (the resolved path must live under $ROOT), which is testable;
#     whether someone ran install.sh yesterday is not.
#
# THE RESOLVE TRAP, and why SMOKE1 has two targets. `zuvo_backlog_io.resolve()` routes every repo to
# `main_root()`, and "first `git worktree list` entry is ALWAYS the main worktree, even from a linked
# one" — so from this worktree the CLI answers about the MAIN checkout's memory/backlog.md, which is
# a different file with a different heading count (measured 2026-09-28: 81 there, 91 here; the 10 new
# ones are this plan's own findings). Enumerating this worktree's ids and looking them up through the
# CLI would therefore report 10 ABSENT — a false red caused by a deliberate architecture decision,
# not by a product defect. So SMOKE1 runs the loop TWICE, and the set enumerated is always the set the
# lookup consults:
#     Target A  the canonical file `path` resolves to, in place, read-only. The deployed path.
#     Target B  this worktree's own memory/backlog.md, byte-identical copy in a scratch directory
#               (a plain non-git dir: `main_root` falls back to its argument when git answers
#               nothing, so the copy IS the canonical backlog there). Covers the 10 ids that exist
#               only on this branch, and cannot touch the tracked file at all.
# When the two files are identical (running in the main checkout, or after a merge) Target B reports
# that and the single target carries the assertion — not a skip: the same assertion, one target.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
ARCHIVE_PY="$ROOT/scripts/zuvo-home/backlog-archive.py"
PARSE_MOD="$ROOT/scripts/zuvo-home/zuvo_backlog_parse.py"
BLOCK_MOD="$ROOT/scripts/zuvo-home/zuvo_backlog_block.py"
WT_BACKLOG="$ROOT/memory/backlog.md"
# The heaviest heading-dialect file on the fleet. Observation target only — see S2-OBS.
FLEET_BACKLOG="$HOME/DEV/tgm-survey-platform/memory/backlog.md"
# The pre-Task-1 reference is this SHA and nothing else. `HEAD~5` was right when the plan was written
# and is now mid-plan (ten commits on the branch), which is exactly why revision 6 replaced it.
BASE_SHA="e565df29"
# Fixture size: 8 shapes per cycle, of which the parent/child shape and the adjacent-siblings shape
# contribute two id-shaped headings each -> 10 per cycle, 40 cycles -> ~400, the plan's fleet scale.
FIX_SEED=20260927
FIX_CYCLES=40

ZUVO_DIR="${ZUVO_OUTPUT_DIR:-$ROOT/zuvo}"
PROOF_DIR="$ZUVO_DIR/proofs"
ART1="$PROOF_DIR/smoke-heading-lookup.txt"
ART2="$PROOF_DIR/smoke-fleet-scale-boundary.txt"

PASS=0; FAIL=0
ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/stqa-backlog-smoke.XXXXXX")" && pwd -P)"
# Canonicalise once with `pwd -P`: on macOS $TMPDIR is /var/folders/... and /var is a symlink to
# /private/var, so `resolve()` (which calls realpath, correctly) answers /private/var/... while every
# comparison here would hold the unresolved form. Linux has no such symlink, which is why the farm
# never sees it.
#
# THERE IS NO `trap 'rm -rf "$FIX"' EXIT`, on purpose. If `mktemp` fails, `$FIX` is empty, `cd ""`
# succeeds and stays put, and `pwd -P` hands back the CURRENT DIRECTORY — so the tidy-up idiom would
# delete the repository. The guard below refuses to run at all unless $FIX is a fresh directory whose
# name carries this suite's template, and the directory is then LEFT BEHIND in $TMPDIR (a few hundred
# KB, reaped by the OS) because a wrong `rm -rf` costs more than every temp file this suite will ever
# write. Its path is printed so it can be inspected after a failure.
CNFH_MARK="$FIX/.cnfh"
command_not_found_handle(){
  echo "  FAIL harness: unknown command '$1'"
  printf '%s\n' "$1" >> "$CNFH_MARK"
  return 127
}

# Artifact bodies are accumulated as the run goes and written out by `finish`, so a run that dies
# early still leaves the evidence it had reached. `finish` is the ONLY exit path: every early return
# goes through it, so the marker is always consulted and the RESULT line — which run-all.sh parses —
# is always printed.
A1="$FIX/a1.body"
A2="$FIX/a2.body"
: > "$A1"; : > "$A2"
rec1(){ printf '%s\n' "$*" >> "$A1"; }
rec2(){ printf '%s\n' "$*" >> "$A2"; }
say(){ echo "  ... $*"; }

finish(){
  if [ -s "$CNFH_MARK" ]; then
    no "(S0) unknown command(s) ran: $(sort -u "$CNFH_MARK" | tr '\n' ' ')— a misspelled helper prints and returns 127 in a subshell, so every assertion that used it checked nothing"
  fi
  if mkdir -p "$PROOF_DIR" 2>/dev/null; then
    { echo "RESULT: PASS=$PASS FAIL=$FAIL  (suite tests/hooks/test-backlog-smoke.sh)"; } >> "$A1"
    { echo "RESULT: PASS=$PASS FAIL=$FAIL  (suite tests/hooks/test-backlog-smoke.sh)"; } >> "$A2"
    cp "$A1" "$ART1" && say "artifact $ART1"
    cp "$A2" "$ART2" && say "artifact $ART2"
  else
    echo "  ... could not create $PROOF_DIR — artifact bodies left at $A1 / $A2"
  fi
  say "scratch kept at $FIX"
  echo "RESULT: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

echo "== backlog heading entries: whole-feature smoke (SMOKE1 + SMOKE2) =="

# --- S0 the harness guarantees the rest of the file relies on ------------------------------------
# bash 4+ is a HARD requirement, not a preference: under /bin/bash 3.2 (measured: 3.2.57 does not
# call the handler at all) a misspelled helper writes no marker, so `finish` sees nothing and the FAIL
# count below would mean nothing. It is a FAIL and never a SKIP, per rule 1 above.
if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
  ok "(S0) bash ${BASH_VERSION%%(*} is 4+ — command_not_found_handle fires, typo protection is live"
else
  no "(S0) bash ${BASH_VERSION%%(*} predates command_not_found_handle (bash 4+): a misspelled helper returns 127 and writes no marker, so this file's FAIL count proves nothing — re-run under bash >= 4"
  finish
fi

case "$FIX" in
  *stqa-backlog-smoke.*)
    if [ -d "$FIX" ] && [ -w "$FIX" ] && [ "$FIX" != "$ROOT" ] && [ "$FIX" != "$PWD" ]; then
      ok "(S0) scratch dir is a private mktemp directory outside the repo: $FIX"
    else
      no "(S0) '$FIX' is not a writable directory outside the repo — mktemp -d did not give us private scratch space"
      finish
    fi ;;
  *) no "(S0) '$FIX' does not carry the stqa-backlog-smoke template — mktemp -d failed and \$FIX fell back to the current directory; refusing to write anything"
     finish ;;
esac

if command -v python3 >/dev/null 2>&1; then ok "(S0) python3 present"; else
  no "(S0) python3 missing — it is a stated prerequisite of this repo and every probe below needs it"
  finish; fi
if command -v git >/dev/null 2>&1; then ok "(S0) git present"; else
  no "(S0) git missing — the base-tree control and the working-tree observation both need it"; finish; fi
if command -v shasum >/dev/null 2>&1; then ok "(S0) shasum present"; else
  no "(S0) shasum missing — the read-only proof IS a sha256 comparison, so there is no degraded form of this suite"
  finish; fi

for f in "$ARCHIVE_PY" "$PARSE_MOD" "$BLOCK_MOD" "$WT_BACKLOG"; do
  if [ -f "$f" ]; then ok "(S0) present: ${f#"$ROOT"/}"; else
    no "(S0) missing: $f — nothing below can be checked"; finish; fi
done

# Deviation (b): the driver under test must be the REPO copy, not ~/.zuvo/. `install.sh` globs
# scripts/zuvo-home/ into the machine-global ~/.zuvo/, and a smoke proof that measured that copy
# would be measuring whatever was installed last rather than this branch.
drv_real="$(cd "$(dirname "$ARCHIVE_PY")" && pwd -P)/$(basename "$ARCHIVE_PY")"
root_real="$(cd "$ROOT" && pwd -P)"
case "$drv_real" in
  "$root_real"/*) ok "(S0) driver under test is the repo copy: ${drv_real#"$root_real"/}" ;;
  *) no "(S0) driver resolved to $drv_real, outside $root_real — this would be measuring the installed ~/.zuvo/ copy, not this branch"; finish ;;
esac

# The archive remedy (Task 4) is behind this gate. Exported in the caller's shell it would turn the
# read-only assertions below into a measurement of the GATED write path.
unset ZUVO_BACKLOG_HEADING_ARCHIVE
if [ -z "${ZUVO_BACKLOG_HEADING_ARCHIVE:-}" ]; then
  ok "(S0) ZUVO_BACKLOG_HEADING_ARCHIVE is unset — SMOKE1 measures the default-off, read-only path"
else
  no "(S0) ZUVO_BACKLOG_HEADING_ARCHIVE='${ZUVO_BACKLOG_HEADING_ARCHIVE:-}' survived the unset, so SMOKE1 would measure the gated write path and read its result as a defect"
  finish
fi

# --- the measurement helper ----------------------------------------------------------------------
# One python file with subcommands rather than N inline heredocs: every probe needs the same sys.path
# insert, the same fence-region computation and the same span model, and three copies of the span
# model is how the two halves of one boundary rule drift apart. NOTHING in it re-implements a product
# rule — levels, fences, block ends and the flush-left-checkbox test all come from the modules under
# test.
cat > "$FIX/smoke.py" <<'PYEOF'
"""Measurement helper for tests/hooks/test-backlog-smoke.sh (generated into $FIX at run time)."""
import hashlib
import os
import sys

ROOT = os.environ["SMOKE_ROOT"]
sys.path.insert(0, os.path.join(ROOT, "scripts", "zuvo-home"))
import zuvo_backlog_parse as zb          # noqa: E402
import zuvo_backlog_block as bl          # noqa: E402

ALL_KINDS = zb.DEFAULT_KINDS + (zb.KIND_HEADING,)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def fence_lines(lines):
    """0-based indices of every line inside a CLOSED fenced block, via the product's own helpers.

    A second fence regex here would be a second source of truth about where content stops being
    structure, which is the defect class `_block_ends_at` documents. An UNCLOSED fence is not a
    region: `_scan_to_boundary` steps PAST it one line at a time so the terminators after it still
    apply, and this mirrors that exactly.

    It reads `closed_fence_spans` — the document-wide pairing — rather than pairing per opener itself.
    The per-opener form it used to mirror was the aggregate review's BEHAV-1 defect: a marker already
    consumed as a closer could be handed back as an opener, so the pairing depended on where the scan
    began. Mirroring the product exactly is the point of this oracle, and that includes the fix.
    """
    out = set()
    for open_at, close in bl.closed_fence_spans(lines).items():
        out.update(range(open_at, close + 1))
    return out


def heading_entries(text):
    return [e for e in zb.iter_entries(text, kinds=ALL_KINDS) if e.kind == zb.KIND_HEADING]


def spans(lines, entries):
    """(start0, end0, level, ident) per entry; end0 exclusive, straight from `entry_block`."""
    out = []
    for e in entries:
        s = e.lineno - 1
        out.append((s, bl.entry_block(lines, s), bl._heading_start_level(lines[s]), e.ident))
    return out


def cmd_heads(path):
    """Every id-shaped heading id, in file order, plus the count no lookup could be built from.

    `ID_RE.fullmatch` is the same gate `backlog-archive.query_key` applies: an ident it rejects is
    keyed as free TEXT, so `lookup <that ident>` would legitimately answer ABSENT and the zero-ABSENT
    assertion would be measuring the wrong thing. Reported on stderr, never silently dropped.
    """
    unqueryable = 0
    for e in heading_entries(read(path)):
        if e.ident and zb.ID_RE.fullmatch(e.ident):
            print(e.ident)
        else:
            unqueryable += 1
    print("unqueryable=%d" % unqueryable, file=sys.stderr)


def cmd_checkboxes(path, want):
    """`want` checkbox ids sampled by a fixed STRIDE over file order — deterministic, and it spreads
    the sample over the whole file instead of clustering it in the first section."""
    ids = [e.ident for e in zb.iter_entries(read(path), kinds=ALL_KINDS)
           if e.kind == zb.KIND_CHECKBOX and e.ident and zb.ID_RE.fullmatch(e.ident)]
    want = int(want)
    print("available=%d" % len(ids), file=sys.stderr)
    stride = max(1, len(ids) // want) if ids else 1
    for i in range(0, len(ids), stride):
        if want <= 0:
            break
        print(ids[i])
        want -= 1


def cmd_predialect(path):
    """THE PERMANENT RED CONTROL for SMOKE1: the pre-Task-1 read dialect, `kinds=DEFAULT_KINDS`.

    Before Task 1 the read paths had no way to ask for headings at all, so an id that exists only as
    a heading answered ABSENT — the dedup loop this plan closes. `DEFAULT_KINDS` IS that dialect and
    cannot rot the way a pinned SHA can (a shallow clone, a GC'd commit). `heading_only` is the
    honest number: a handful of ids are written BOTH as a heading and as a checkbox elsewhere, and
    those were always reachable, so counting them would overstate the RED.
    """
    text = read(path)
    keys = {"id:" + e.ident.lower() for e in heading_entries(text) if e.ident}
    default_keys = {e.key for e in zb.iter_entries(text, kinds=zb.DEFAULT_KINDS)}
    print("heading_ids=%d" % len(keys))
    print("also_reachable_pre_task1=%d" % len(keys & default_keys))
    print("heading_only=%d" % len(keys - default_keys))


def _gen_lines(seed, cycles):
    """The fleet-scale fixture, deterministic from `seed`, with no `random` module.

    An explicit LCG rather than `random.Random(seed)`: the Mersenne Twister's stream is stable across
    CPython releases in practice but is not a documented wire format, and this fixture's sha256 is
    PINNED into an artifact a later reader compares against. Five lines of LCG is the same
    determinism with none of that risk.

    GENERATED, not vendored: the real heaviest file changes daily (so no fixed count is reproducible)
    and copying another project's backlog in would import that project's content.
    """
    state = seed & 0x7FFFFFFF

    def nxt(lo, hi):
        nonlocal state
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        return lo + (state >> 7) % (hi - lo + 1)

    out = ["# Tech Debt Backlog", "",
           "Generated fleet-scale fixture — %d cycles, LCG seed %d." % (cycles, seed), ""]
    for c in range(cycles):
        if c % 5 == 0:
            out += ["## Open (batch %d)" % (c // 5), ""]      # a level-2 heading that is NOT an entry
        n = c * 10
        # shape 0 — plain heading entry with prose continuation, resolution marker in the heading
        out += ["## B-smoke-%04d-plain — DONE deadbeef%02d" % (n, c % 100)]
        out += ["Closing prose line %d." % k for k in range(nxt(1, 3))]
        out += [""]
        # shape 1 — indented continuation, including an INDENTED checkbox child (stays in the block)
        out += ["## B-smoke-%04d-indent" % (n + 1),
                "- **Fix:** flush-left continuation bullet, not a sibling entry",
                "  - detail line",
                "    - deeper detail",
                "  - [ ] indented checkbox child of this entry", ""]
        # shape 2 — heading entry followed by a FLUSH-LEFT checkbox sibling: the block ends there
        out += ["## B-smoke-%04d-beforecb" % (n + 2),
                "prose that belongs to the heading entry",
                "- [ ] B-smoke-%04d-cb a flush-left checkbox sibling" % (n + 2),
                "  - sub-detail of the checkbox", ""]
        # shape 3 — AC5's shape: a nested ### child INSIDE its ## parent's block
        out += ["## B-smoke-%04d-parent" % (n + 3),
                "parent prose",
                "### B-smoke-%04d-parent-SUB nested child" % (n + 3),
                "- **Closed:** child continuation",
                "child prose", ""]
        # shape 4 — a level-3 entry whose enclosing heading is not an entry at all
        out += ["### B-smoke-%04d-orphan3" % (n + 4), "orphan prose", ""]
        # shape 5 — a CLOSED fence carrying a flush-left '#': stepped over whole, must not end it
        out += ["## B-smoke-%04d-fence" % (n + 5),
                "recipe:", "```bash", "#!/bin/sh",
                "# restart cleanly before profiling",
                "systemctl restart workers", "```",
                "post-fence prose that still belongs to the entry", ""]
        # shape 6 — a trailing-blank run: blanks are the file's layout, not the entry's
        out += ["## B-smoke-%04d-blanks" % (n + 6), "one line of prose", "", "", ""]
        # shape 7 — two ADJACENT same-level siblings: the first block is exactly one line long
        out += ["## B-smoke-%04d-sibA" % (n + 7),
                "## B-smoke-%04d-sibB" % (n + 7),
                "sibB prose", ""]
    # One UNCLOSED fence, last: `_scan_to_boundary` steps past it a line at a time, so the structural
    # terminator after it still applies. Included once so that branch is exercised at scale too.
    out += ["## B-smoke-tail-unclosed-fence", "```",
            "# a flush-left hash after an unclosed fence",
            "## B-smoke-tail-after-unclosed-fence", "tail prose", ""]
    return out


def cmd_gen(out_path, seed, cycles):
    text = "\n".join(_gen_lines(int(seed), int(cycles))) + "\n"
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("sha256=%s" % hashlib.sha256(text.encode("utf-8")).hexdigest())
    print("lines=%d" % len(text.splitlines()))
    print("bytes=%d" % len(text.encode("utf-8")))


def cmd_census(path):
    """WHAT SHAPES the file actually holds. Runs BEFORE the boundary gate, so that gate cannot
    report zero violations over a fixture that never contained the shape under test."""
    lines = read(path).splitlines(keepends=True)
    fz = fence_lines(lines)
    per_level = {}
    for _s, _e, level, _i in spans(lines, heading_entries("".join(lines))):
        per_level[level] = per_level.get(level, 0) + 1
    print("total_lines=%d" % len(lines))
    print("fence_lines=%d" % len(fz))
    print("flush_checkboxes=%d" % sum(1 for k, ln in enumerate(lines)
                                      if k not in fz and zb.CHECK_LINE_RE.match(ln)))
    print("indented_continuation=%d" % sum(1 for ln in lines if ln.startswith("  - ")))
    print("fenced_flush_hash=%d" % sum(1 for k in sorted(fz) if lines[k].startswith("#")))
    print("blank_runs=%d" % sum(1 for k in range(len(lines) - 1)
                                if not lines[k].strip() and not lines[k + 1].strip()))
    for level in sorted(k for k in per_level if k is not None):
        print("level_%d=%d" % (level, per_level[level]))


def _analyse(lines, sp):
    """Every boundary metric, from ONE span list.

    `sp` is a parameter, not a local, precisely so the negative control can feed a DELIBERATELY
    WIDENED list through this identical code and watch all four counters go red.

    THE OVERLAP RULE, and why it is not "no two blocks overlap". AC5 requires a `##` block to
    CONTAIN its nested `### B-…-SUB`, so a flat no-overlap assertion would contradict the feature.
    Two heading entries in file order, A before B, may stand in exactly two legitimate relations:
      * DISJOINT   B starts at or after A's end.
      * NESTED     B's level is STRICTLY deeper than A's AND B ends at or before A's end.
    Anything else CROSSES: same-level blocks that overlap (sibling overlap — an entry's lines
    attributed to its neighbour) and deeper blocks that run past their parent's end (a child span
    leaking out of the entry that owns it). Both are counted as crossings; the same-level subset is
    counted separately because it is the one the plan names, and `nested_pairs` is reported so that
    "zero crossings" cannot be satisfied by a fixture with no nesting in it.
    """
    fz = fence_lines(lines)
    crossings, sibling_overlaps, nested = [], [], 0
    for i in range(len(sp)):
        a0, a1, la, ia = sp[i]
        for j in range(i + 1, len(sp)):
            b0, b1, lb, ib = sp[j]
            if b0 >= a1:
                continue
            if la is not None and lb is not None and lb > la and b1 <= a1:
                nested += 1
                continue
            crossings.append("%s[%d,%d)L%s vs %s[%d,%d)L%s" % (ia, a0, a1, la, ib, b0, b1, lb))
            if la == lb:
                sibling_overlaps.append("%s[%d,%d) vs %s[%d,%d)" % (ia, a0, a1, ib, b0, b1))
    # (i) a block must not CONTAIN a flush-left checkbox line: that line is another entry, and
    # `_block_ends_at` ends the block AT it. Fenced regions are excluded because a checkbox inside a
    # fence is content, and `entry_block` steps the whole fence over by design.
    # (ii) attribution per NESTING LEVEL: within one level every line has at most one owner, which is
    # the "exactly one entry at each nesting level" half of the AC.
    foreign, owner, dup, ends_at_cb = [], {}, [], 0
    for a0, a1, la, ia in sp:
        for k in range(a0 + 1, a1):
            if k not in fz and zb.CHECK_LINE_RE.match(lines[k]):
                foreign.append("%s: line %d %r" % (ia, k, lines[k].strip()[:56]))
        for k in range(a0, a1):
            prev = owner.setdefault((la, k), ia)
            if prev != ia:
                dup.append("L%s line %d claimed by %s and %s" % (la, k, prev, ia))
        if a1 < len(lines) and a1 not in fz and zb.CHECK_LINE_RE.match(lines[a1]):
            ends_at_cb += 1
    covered = {k for a0, a1, _l, _i in sp for k in range(a0, a1)}
    return {"crossings": crossings, "sibling_overlaps": sibling_overlaps, "nested_pairs": nested,
            "foreign_checkboxes": foreign, "level_dup_lines": dup, "ends_at_checkbox": ends_at_cb,
            "covered_lines": len(covered), "total_lines": len(lines), "headings": len(sp)}


def _emit(res, prefix=""):
    for key in ("headings", "nested_pairs", "ends_at_checkbox", "covered_lines", "total_lines"):
        print("%s%s=%s" % (prefix, key, res[key]))
    for key in ("crossings", "sibling_overlaps", "foreign_checkboxes", "level_dup_lines"):
        print("%s%s=%d" % (prefix, key, len(res[key])))
        for row in res[key][:5]:
            print("%sexample_%s: %s" % (prefix, key, row))


def cmd_scan(path):
    lines = read(path).splitlines(keepends=True)
    _emit(_analyse(lines, spans(lines, heading_entries("".join(lines)))))


def cmd_scan_widened(path, delta):
    """THE NEGATIVE CONTROL for `scan`. Widen every span by `delta` lines — the shape a broken
    `entry_block` would produce — and re-run the identical analysis. If this does not report
    crossings AND sibling overlaps AND foreign checkboxes AND duplicate ownership, then `scan`'s four
    zeros are decoration and prove nothing about the boundary."""
    lines = read(path).splitlines(keepends=True)
    sp = spans(lines, heading_entries("".join(lines)))
    wide = [(a0, min(len(lines), a1 + int(delta)), la, ia) for a0, a1, la, ia in sp]
    _emit(_analyse(lines, wide), prefix="widened_")


def cmd_fleet(path):
    """Observation only, never a verdict — see S2-OBS in the shell for why it cannot gate."""
    text = read(path)
    print("sha256=%s" % hashlib.sha256(text.encode("utf-8")).hexdigest())
    print("bytes=%d" % len(text.encode("utf-8")))
    lines = text.splitlines(keepends=True)
    _emit(_analyse(lines, spans(lines, heading_entries(text))))


def cmd_base_probe(base_dir):
    """Does the PRE-TASK-1 tree even carry the surface SMOKE2 measures? Read from source rather than
    imported: `zuvo_backlog_parse` is already in this process under the HEAD copy, and a second
    import of the same module name would hand back the one already in sys.modules."""
    print("has_block_module=%d" % int(os.path.isfile(os.path.join(base_dir, "zuvo_backlog_block.py"))))
    src = read(os.path.join(base_dir, "zuvo_backlog_parse.py"))
    print("has_kind_heading=%d" % int("KIND_HEADING" in src))
    print("has_kinds_kwarg=%d" % int("kinds:" in src))


CMDS = {"heads": cmd_heads, "checkboxes": cmd_checkboxes, "predialect": cmd_predialect,
        "gen": cmd_gen, "census": cmd_census, "scan": cmd_scan, "scan-widened": cmd_scan_widened,
        "fleet": cmd_fleet, "base-probe": cmd_base_probe}

if __name__ == "__main__":
    CMDS[sys.argv[1]](*sys.argv[2:])
PYEOF

export SMOKE_ROOT="$ROOT"
# `env -u PYTHONPATH`, not `PYTHONPATH= `: an EMPTY PYTHONPATH puts '' on sys.path (the current
# directory), so the parse module could be shadowed by a stray file in $PWD — and the empty-assignment
# form also trips shellcheck SC1007, which this repo's lint gate ratchets at zero warnings.
PY=(env -u PYTHONPATH python3)
smoke(){ "${PY[@]}" "$FIX/smoke.py" "$@"; }

if smoke gen "$FIX/probe.md" 1 1 >/dev/null 2>"$FIX/helper.err"; then
  ok "(S0) the measurement helper imports both modules under test and runs"
else
  no "(S0) the measurement helper failed to run: $(tr '\n' ' ' < "$FIX/helper.err")"
  finish
fi

sha(){ shasum -a 256 "$1" | awk '{print $1}'; }

# LK_* are set by `lookup_loop` and read immediately after each call. Globals rather than a parsed
# stdout line because the loop must also stream the failing ids to a file, and a function that
# returned one summary string would have to re-encode them.
LK_N=0; LK_OPEN=0; LK_ARCHIVED=0; LK_ABSENT=0; LK_OTHER=0
lookup_loop(){   # $1 repo dir, $2 file of ids (one per line), $3 label for the failure log
  LK_N=0; LK_OPEN=0; LK_ARCHIVED=0; LK_ABSENT=0; LK_OTHER=0
  local id out rc
  : > "$FIX/bad-$3.txt"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    LK_N=$((LK_N + 1))
    out="$("${PY[@]}" "$ARCHIVE_PY" lookup --repo "$1" "$id" 2>&1)"; rc=$?
    case "$rc" in
      10) LK_OPEN=$((LK_OPEN + 1)) ;;
      11) LK_ARCHIVED=$((LK_ARCHIVED + 1)) ;;
      0)  LK_ABSENT=$((LK_ABSENT + 1)); printf 'ABSENT %s -> %s\n' "$id" "$out" >> "$FIX/bad-$3.txt" ;;
      *)  LK_OTHER=$((LK_OTHER + 1)); printf 'rc=%s %s -> %s\n' "$rc" "$id" "$out" >> "$FIX/bad-$3.txt" ;;
    esac
  done < "$2"
}

# `status` prints one of two shapes — "OK <path>: N open, nothing resolved left" or
# "OVERDUE <path>: … ; N genuinely open". Both are matched; a third shape is a FAIL, never a silently
# empty count that would then compare equal to another empty count.
status_open(){   # $1 repo dir, $2 file to keep the raw output in
  "${PY[@]}" "$ARCHIVE_PY" status --repo "$1" > "$2" 2>&1
  sed -n -e 's/^OK [^:]*: \([0-9][0-9]*\) open,.*/\1/p' \
         -e 's/.*; \([0-9][0-9]*\) genuinely open).*/\1/p' "$2" | head -1
}

# ================================================================================================
#  SMOKE1 — the dedup loop is closed on this repo, read-only
# ================================================================================================
echo "-- SMOKE1: heading-entry lookup through the CLI (read-only) --"
rec1 "# SMOKE1 — the heading-entry dedup loop, closed on this repo (READ-ONLY)"
rec1 "suite:  tests/hooks/test-backlog-smoke.sh"
rec1 "run:    $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
rec1 "root:   $ROOT"
rec1 "HEAD:   $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '(unknown)') on $(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '(unknown)')"
rec1 "driver: ${drv_real#"$root_real"/}  (repo copy — the installed ~/.zuvo/ copy is deliberately NOT under test)"
rec1 "gate:   ZUVO_BACKLOG_HEADING_ARCHIVE unset"
rec1 ""

# --- S1a where the CLI actually looks ------------------------------------------------------------
"${PY[@]}" "$ARCHIVE_PY" path --repo "$ROOT" > "$FIX/path.txt" 2>&1
REAL="$(sed -n 's/^real  *//p' "$FIX/path.txt" | sed 's/  (symlinked)$//' | head -1)"
if [ -n "$REAL" ] && [ -f "$REAL" ]; then
  ok "(S1a) the CLI resolves this repo's canonical backlog to an existing file"
  say "canonical backlog: $REAL"
else
  no "(S1a) 'backlog-archive.py path --repo $ROOT' did not name an existing real backlog: $(tr '\n' ' ' < "$FIX/path.txt")"
  finish
fi
rec1 "## Target A — the canonical backlog the CLI resolves (in place, read-only)"
rec1 "path: $REAL"

# --- S1b derive the id sets. NO literal count, and a vacuity guard BEFORE any zero-ABSENT claim ---
smoke heads "$REAL" > "$FIX/heads-A.txt" 2>"$FIX/heads-A.err"
awk '!seen[$0]++' "$FIX/heads-A.txt" > "$FIX/heads-A.uniq"
A_TOTAL="$(wc -l < "$FIX/heads-A.txt" | tr -d ' ')"
A_UNIQ="$(wc -l < "$FIX/heads-A.uniq" | tr -d ' ')"
A_UNQ="$(sed -n 's/^unqueryable=\([0-9]*\)$/\1/p' "$FIX/heads-A.err")"
rec1 "id-shaped heading entries: $A_TOTAL (distinct ids $A_UNIQ, idents no lookup could be built from: ${A_UNQ:-?})"
say "Target A heading entries: $A_TOTAL (distinct $A_UNIQ)"
# THE VACUITY GUARD. A loop over zero ids reports zero ABSENT and is the easiest false green here, so
# the set is sized BEFORE any property of it is asserted. 20 is a floor two orders below today's
# measured 81/91, chosen so it can never need editing as the file grows; it is not an expected value.
if [ "${A_UNIQ:-0}" -ge 20 ]; then
  ok "(S1b) Target A enumerated $A_UNIQ distinct id-shaped heading entries — the set is non-empty and plausibly sized (floor 20)"
else
  no "(S1b) Target A enumerated only ${A_UNIQ:-0} distinct id-shaped heading entries; below the floor of 20 the zero-ABSENT assertion below would be vacuous — the parser or the file changed shape"
  finish
fi
if [ "${A_UNQ:-1}" -eq 0 ]; then
  ok "(S1b) every heading ident is ID_RE-fullmatch queryable — none would key as free text"
else
  no "(S1b) ${A_UNQ:-?} heading ident(s) are not ID_RE-fullmatch, so 'lookup <ident>' keys them as TEXT and would answer ABSENT for a reason that is not the defect under test"
fi

smoke checkboxes "$REAL" 10 > "$FIX/cb-A.txt" 2>"$FIX/cb-A.err"
CB_N="$(wc -l < "$FIX/cb-A.txt" | tr -d ' ')"
CB_AVAIL="$(sed -n 's/^available=\([0-9]*\)$/\1/p' "$FIX/cb-A.err")"
rec1 "checkbox sample: $CB_N of ${CB_AVAIL:-?} available, fixed stride over file order"
if [ "${CB_N:-0}" -eq 10 ]; then
  ok "(S1b) sampled 10 checkbox ids by fixed stride from ${CB_AVAIL:-?} available"
else
  no "(S1b) wanted 10 sampled checkbox ids, got ${CB_N:-0} of ${CB_AVAIL:-?} available — the checkbox half of the proof would be under-sized"
fi

# --- S1c the read-only baseline, measured not asserted -------------------------------------------
A_SHA_BEFORE="$(sha "$REAL")"
WT_SHA_BEFORE="$(sha "$WT_BACKLOG")"
A_OPEN_BEFORE="$(status_open "$ROOT" "$FIX/status-before.txt")"
rec1 "sha256 before: $A_SHA_BEFORE"
if [ -n "$A_OPEN_BEFORE" ]; then
  ok "(S1c) baseline captured: status reports $A_OPEN_BEFORE open entries, sha256 ${A_SHA_BEFORE:0:12}…"
else
  no "(S1c) could not read an open count out of \`status\`: $(tr '\n' ' ' < "$FIX/status-before.txt") — an unparsed count would compare equal to the equally unparsed one after the run"
  finish
fi

# --- S1d the loop: every heading id, then the checkbox sample -----------------------------------
lookup_loop "$ROOT" "$FIX/heads-A.uniq" "A-head"
A_H_N=$LK_N; A_H_OPEN=$LK_OPEN; A_H_ARCH=$LK_ARCHIVED; A_H_ABS=$LK_ABSENT; A_H_OTH=$LK_OTHER
rec1 "heading lookups: n=$A_H_N OPEN(rc=10)=$A_H_OPEN ARCHIVED(rc=11)=$A_H_ARCH ABSENT(rc=0)=$A_H_ABS other=$A_H_OTH"
if [ "$A_H_N" -eq "$A_UNIQ" ] && [ "$A_H_ABS" -eq 0 ] && [ "$A_H_OTH" -eq 0 ] \
   && [ $((A_H_OPEN + A_H_ARCH)) -eq "$A_H_N" ]; then
  ok "(S1d) Target A: all $A_H_N heading ids answered rc=10 OPEN or rc=11 ARCHIVED — zero ABSENT, zero other"
else
  no "(S1d) Target A: $A_H_N looked up, $A_H_ABS ABSENT, $A_H_OTH other (OPEN=$A_H_OPEN ARCHIVED=$A_H_ARCH) — the dedup loop is NOT closed: $(head -3 "$FIX/bad-A-head.txt" | tr '\n' ' ')"
fi

lookup_loop "$ROOT" "$FIX/cb-A.txt" "A-cb"
rec1 "checkbox lookups: n=$LK_N OPEN=$LK_OPEN ARCHIVED=$LK_ARCHIVED ABSENT=$LK_ABSENT other=$LK_OTHER"
if [ "$LK_ABSENT" -eq 0 ] && [ "$LK_OTHER" -eq 0 ] && [ "$LK_N" -gt 0 ]; then
  ok "(S1d) Target A: all $LK_N sampled checkbox ids still resolve (OPEN=$LK_OPEN ARCHIVED=$LK_ARCHIVED) — the older dialect did not regress"
else
  no "(S1d) Target A: $LK_ABSENT of $LK_N sampled checkbox ids ABSENT, $LK_OTHER other — teaching the read paths the heading dialect broke the checkbox dialect: $(head -3 "$FIX/bad-A-cb.txt" | tr '\n' ' ')"
fi

# --- S1e Target B: this worktree's own file, through the same CLI, on a copy ----------------------
rec1 ""
rec1 "## Target B — this worktree's own memory/backlog.md"
rec1 "path: $WT_BACKLOG"
rec1 "sha256 before: $WT_SHA_BEFORE"
if [ "$WT_SHA_BEFORE" = "$A_SHA_BEFORE" ]; then
  rec1 "identical to Target A — one file, one target; Target A above carries the assertion"
  ok "(S1e) this worktree's memory/backlog.md IS the canonical file (same sha256) — Target A already covered it"
else
  SANDBOX="$FIX/wtrepo"
  mkdir -p "$SANDBOX/memory"
  cp "$WT_BACKLOG" "$SANDBOX/memory/backlog.md"
  # A plain NON-git directory on purpose: `main_root` falls back to its own argument when
  # `git worktree list` and `git rev-parse` both answer nothing, so the copy IS the canonical backlog
  # there. No `git init`, so nothing in this suite can produce a repository the gates would then see.
  if [ "$(sha "$SANDBOX/memory/backlog.md")" = "$WT_SHA_BEFORE" ]; then
    ok "(S1e) byte-identical copy of this worktree's backlog staged outside the repo — the tracked file cannot be reached from here"
  else
    no "(S1e) the staged copy does not match the tracked file's sha256 — Target B would be measuring something else"
    finish
  fi
  smoke heads "$SANDBOX/memory/backlog.md" > "$FIX/heads-B.txt" 2>"$FIX/heads-B.err"
  awk '!seen[$0]++' "$FIX/heads-B.txt" > "$FIX/heads-B.uniq"
  B_TOTAL="$(wc -l < "$FIX/heads-B.txt" | tr -d ' ')"
  B_UNIQ="$(wc -l < "$FIX/heads-B.uniq" | tr -d ' ')"
  rec1 "id-shaped heading entries: $B_TOTAL (distinct ids $B_UNIQ)"
  say "Target B heading entries: $B_TOTAL (distinct $B_UNIQ)"
  if [ "${B_UNIQ:-0}" -ge 20 ]; then
    ok "(S1e) Target B enumerated $B_UNIQ distinct id-shaped heading entries (floor 20)"
  else
    no "(S1e) Target B enumerated only ${B_UNIQ:-0} distinct id-shaped heading entries — below the vacuity floor of 20"
    finish
  fi
  lookup_loop "$SANDBOX" "$FIX/heads-B.uniq" "B-head"
  rec1 "heading lookups: n=$LK_N OPEN(rc=10)=$LK_OPEN ARCHIVED(rc=11)=$LK_ARCHIVED ABSENT(rc=0)=$LK_ABSENT other=$LK_OTHER"
  if [ "$LK_N" -eq "$B_UNIQ" ] && [ "$LK_ABSENT" -eq 0 ] && [ "$LK_OTHER" -eq 0 ]; then
    ok "(S1e) Target B: all $LK_N heading ids of this branch's own backlog answered rc=10/rc=11 — zero ABSENT"
  else
    no "(S1e) Target B: $LK_ABSENT of $LK_N ABSENT, $LK_OTHER other — this branch's own heading entries are not found: $(head -3 "$FIX/bad-B-head.txt" | tr '\n' ' ')"
  fi
  if [ "$(sha "$SANDBOX/memory/backlog.md")" = "$WT_SHA_BEFORE" ]; then
    ok "(S1e) the staged copy is byte-unchanged after $LK_N lookups — 'lookup' writes nothing"
  else
    no "(S1e) the staged copy CHANGED during the lookup loop — 'lookup' is not read-only"
  fi
  rec1 "ids present here but not in Target A: $(comm -13 <(sort "$FIX/heads-A.uniq") <(sort "$FIX/heads-B.uniq") | tr '\n' ' ')"
fi

# --- S1f the gates, and the read-only proof ------------------------------------------------------
"${PY[@]}" "$ARCHIVE_PY" verify --repo "$ROOT" > "$FIX/verify.txt" 2>&1
V_RC=$?
rec1 ""
rec1 "verify: $(head -1 "$FIX/verify.txt")  (rc=$V_RC)"
if [ "$V_RC" -eq 0 ] && grep -q '^OK disjoint' "$FIX/verify.txt"; then
  ok "(S1f) verify prints 'OK disjoint' and exits 0 — no id is open and archived at once"
else
  no "(S1f) verify rc=$V_RC: $(tr '\n' ' ' < "$FIX/verify.txt") — expected rc=0 and a leading 'OK disjoint'"
fi

A_OPEN_AFTER="$(status_open "$ROOT" "$FIX/status-after.txt")"
rec1 "status open count: before=$A_OPEN_BEFORE after=$A_OPEN_AFTER"
if [ -n "$A_OPEN_AFTER" ] && [ "$A_OPEN_AFTER" = "$A_OPEN_BEFORE" ]; then
  ok "(S1f) status's open count is unchanged across the whole run ($A_OPEN_BEFORE) — nothing was archived"
else
  no "(S1f) status's open count moved $A_OPEN_BEFORE -> '${A_OPEN_AFTER:-<unparsed>}' — something on a read path archived an entry"
fi

A_SHA_AFTER="$(sha "$REAL")"
WT_SHA_AFTER="$(sha "$WT_BACKLOG")"
rec1 "sha256 Target A: before=$A_SHA_BEFORE after=$A_SHA_AFTER"
rec1 "sha256 Target B: before=$WT_SHA_BEFORE after=$WT_SHA_AFTER"
if [ "$A_SHA_AFTER" = "$A_SHA_BEFORE" ] && [ "$WT_SHA_AFTER" = "$WT_SHA_BEFORE" ]; then
  ok "(S1f) SMOKE1 IS READ-ONLY: both backlog files are byte-identical after every lookup, status and verify"
else
  no "(S1f) a tracked backlog changed during SMOKE1 — A $A_SHA_BEFORE -> $A_SHA_AFTER, B $WT_SHA_BEFORE -> $WT_SHA_AFTER; a read path is writing"
fi
# Deviation (a): recorded, never gated. `tr -d` on empty input emits NO line, so a `sed 's/^$/clean/'`
# would never fire and the artifact would carry a blank where the answer belongs — the same
# read-the-wrong-field class docs/runbook/operating.md §10 is about.
wt_state="$(git -C "$ROOT" status --porcelain -- memory/backlog.md 2>/dev/null | tr -d '\n')"
rec1 "working-tree state of memory/backlog.md at run start (observation, not a gate): ${wt_state:-clean}"

# --- S1g the RED, permanently: the pre-Task-1 read dialect ---------------------------------------
smoke predialect "$REAL" > "$FIX/pre.txt" 2>&1
PRE_TOTAL="$(sed -n 's/^heading_ids=\([0-9]*\)$/\1/p' "$FIX/pre.txt")"
PRE_BOTH="$(sed -n 's/^also_reachable_pre_task1=\([0-9]*\)$/\1/p' "$FIX/pre.txt")"
PRE_ONLY="$(sed -n 's/^heading_only=\([0-9]*\)$/\1/p' "$FIX/pre.txt")"
rec1 ""
rec1 "## RED — the pre-Task-1 read dialect (permanent control, no SHA required)"
rec1 "heading ids=$PRE_TOTAL  also written as a checkbox/bullet/table elsewhere=$PRE_BOTH  reachable ONLY as a heading=$PRE_ONLY"
if [ "${PRE_ONLY:-0}" -ge 20 ] && [ "${PRE_ONLY:-0}" -le "${PRE_TOTAL:-0}" ]; then
  ok "(S1g) RED control: ${PRE_ONLY} of ${PRE_TOTAL} heading ids are unreachable under the pre-Task-1 read dialect (kinds=DEFAULT_KINDS) and all $A_H_N are reachable now — the defect this suite guards is real and measurable"
else
  no "(S1g) RED control measured heading_only='${PRE_ONLY:-?}' of '${PRE_TOTAL:-?}' — if no id is heading-only then the pre-Task-1 dialect could already find everything and (S1d)'s zero ABSENT proves nothing"
fi

# --- S1h the RED, directly, against the base tree when the object is still present ---------------
# The permanent control above carries the assertion, so a missing object costs no coverage. This adds
# the DIRECT observation: the base's own CLI, on the same canonical file, answering ABSENT.
rec1 ""
rec1 "## RED — the base tree $BASE_SHA (pre-Task-1), direct observation"
if git -C "$ROOT" cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
  mkdir -p "$FIX/base"
  if git -C "$ROOT" archive "$BASE_SHA" scripts/zuvo-home | tar -x -C "$FIX/base" 2>/dev/null; then
    BASE_DIR="$FIX/base/scripts/zuvo-home"
    smoke base-probe "$BASE_DIR" > "$FIX/base-probe.txt" 2>&1
    rec1 "$(tr '\n' ' ' < "$FIX/base-probe.txt")"
    if grep -q '^has_block_module=0' "$FIX/base-probe.txt" \
       && grep -q '^has_kind_heading=0' "$FIX/base-probe.txt" \
       && grep -q '^has_kinds_kwarg=0' "$FIX/base-probe.txt"; then
      ok "(S1h) at $BASE_SHA there is no zuvo_backlog_block.py, no KIND_HEADING and no kinds= parameter — the surface both smoke proofs measure did not exist"
    else
      no "(S1h) $BASE_SHA already carries part of the heading surface ($(tr '\n' ' ' < "$FIX/base-probe.txt")) — it is not the pre-Task-1 reference this suite claims"
    fi
    head -5 "$FIX/heads-A.uniq" > "$FIX/red-sample.txt"
    BASE_ABS=0; BASE_N=0
    while IFS= read -r rid; do
      [ -n "$rid" ] || continue
      BASE_N=$((BASE_N + 1))
      bout="$("${PY[@]}" "$BASE_DIR/backlog-archive.py" lookup --repo "$ROOT" "$rid" 2>&1)"; brc=$?
      rec1 "  $BASE_SHA lookup $rid -> $bout (rc=$brc)"
      case "$brc:$bout" in 0:ABSENT*) BASE_ABS=$((BASE_ABS + 1)) ;; esac
    done < "$FIX/red-sample.txt"
    if [ "$BASE_N" -gt 0 ] && [ "$BASE_ABS" -eq "$BASE_N" ]; then
      ok "(S1h) the $BASE_SHA CLI answers ABSENT rc=0 for all $BASE_N sampled heading ids on the very file where HEAD answers OPEN rc=10 — this is the RED, observed"
    else
      no "(S1h) the $BASE_SHA CLI answered ABSENT for only $BASE_ABS of $BASE_N sampled heading ids — the observed RED does not reproduce"
    fi
  else
    no "(S1h) '$BASE_SHA' exists but 'git archive' could not extract scripts/zuvo-home from it"
  fi
else
  # NOT a skip of an assertion: (S1g) asserts the same pre-Task-1 behaviour from the current parser
  # and always runs. This branch loses only the direct observation.
  rec1 "object $BASE_SHA is not in this clone — the permanent control in (S1g) carries the assertion"
  say "OBSERVATION: commit $BASE_SHA absent from this clone; the direct base-tree observation did not run. (S1g) asserts the same behaviour and did."
fi

# ================================================================================================
#  SMOKE2 — the boundary holds at fleet scale
# ================================================================================================
echo "-- SMOKE2: entry_block boundaries over a generated fleet-scale fixture --"
rec2 "# SMOKE2 — the heading-block boundary at fleet scale"
rec2 "suite:  tests/hooks/test-backlog-smoke.sh"
rec2 "run:    $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
rec2 "HEAD:   $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '(unknown)')"
rec2 ""

# --- S2a the fixture, and its determinism --------------------------------------------------------
smoke gen "$FIX/fleet.md" "$FIX_SEED" "$FIX_CYCLES" > "$FIX/gen1.txt" 2>&1
smoke gen "$FIX/fleet2.md" "$FIX_SEED" "$FIX_CYCLES" > "$FIX/gen2.txt" 2>&1
F_SHA="$(sed -n 's/^sha256=\([0-9a-f]*\)$/\1/p' "$FIX/gen1.txt")"
F_SHA2="$(sed -n 's/^sha256=\([0-9a-f]*\)$/\1/p' "$FIX/gen2.txt")"
F_LINES="$(sed -n 's/^lines=\([0-9]*\)$/\1/p' "$FIX/gen1.txt")"
F_BYTES="$(sed -n 's/^bytes=\([0-9]*\)$/\1/p' "$FIX/gen1.txt")"
rec2 "## Generated fixture (deterministic, LCG seed $FIX_SEED, $FIX_CYCLES cycles)"
rec2 "PINNED sha256: $F_SHA"
rec2 "lines: $F_LINES   bytes: $F_BYTES"
say "fixture sha256 $F_SHA ($F_LINES lines, $F_BYTES bytes)"
if [ -n "$F_SHA" ] && [ "$F_SHA" = "$F_SHA2" ] && [ "$F_SHA" = "$(sha "$FIX/fleet.md")" ]; then
  ok "(S2a) the fixture is deterministic: two independent generations from seed $FIX_SEED hash identically ($F_SHA), and the hash matches the file on disk"
else
  no "(S2a) fixture generation is NOT deterministic: '$F_SHA' vs '$F_SHA2' vs on-disk '$(sha "$FIX/fleet.md")' — a pinned hash would be meaningless"
  finish
fi

# --- S2b the fixture really holds every shape the proof claims to exercise -----------------------
smoke census "$FIX/fleet.md" > "$FIX/census.txt" 2>&1
cen(){ sed -n "s/^$1=\([0-9]*\)$/\1/p" "$FIX/census.txt"; }
C_L2="$(cen level_2)"; C_L3="$(cen level_3)"; C_CB="$(cen flush_checkboxes)"
C_IND="$(cen indented_continuation)"; C_FH="$(cen fenced_flush_hash)"; C_BR="$(cen blank_runs)"
C_TOT="$(cen total_lines)"
rec2 ""
rec2 "## Shape census (asserted BEFORE the boundary gate, so the gate cannot pass vacuously)"
rec2 "$(tr '\n' ' ' < "$FIX/census.txt")"
shape_fail=""
for pair in "level_2:$C_L2:300" "level_3:$C_L3:60" "flush_checkboxes:$C_CB:30" \
            "indented_continuation:$C_IND:60" "fenced_flush_hash:$C_FH:40" "blank_runs:$C_BR:40"; do
  nm="${pair%%:*}"; rest="${pair#*:}"; got="${rest%%:*}"; floor="${rest##*:}"
  if [ "${got:-0}" -lt "$floor" ]; then shape_fail="$shape_fail $nm=${got:-0}(<$floor)"; fi
done
if [ -z "$shape_fail" ]; then
  ok "(S2b) the fixture holds every shape under test: $C_L2 level-2 and $C_L3 level-3 id-shaped headings, $C_CB flush-left checkbox siblings, $C_IND indented continuation lines, $C_FH flush-left '#' lines inside fences, $C_BR blank runs, over $C_TOT lines"
else
  no "(S2b) the fixture is missing shapes:$shape_fail — the boundary gate below would report zero violations over a file that never contained the case"
  finish
fi

# --- S2c the gate ---------------------------------------------------------------------------------
smoke scan "$FIX/fleet.md" > "$FIX/scan.txt" 2>&1
scn(){ sed -n "s/^$1=\([0-9]*\)$/\1/p" "$FIX/scan.txt"; }
S_H="$(scn headings)"; S_CROSS="$(scn crossings)"; S_SIB="$(scn sibling_overlaps)"
S_FOR="$(scn foreign_checkboxes)"; S_DUP="$(scn level_dup_lines)"; S_NEST="$(scn nested_pairs)"
S_ENDCB="$(scn ends_at_checkbox)"; S_COV="$(scn covered_lines)"
rec2 ""
rec2 "## Boundary gate over the generated fixture"
rec2 "$(tr '\n' ' ' < "$FIX/scan.txt")"
say "fixture headings=$S_H crossings=$S_CROSS sibling_overlaps=$S_SIB foreign=$S_FOR dup_lines=$S_DUP nested=$S_NEST"

if [ "${S_H:-0}" -ge 350 ]; then
  ok "(S2c) entry_block ran over $S_H id-shaped headings — fleet scale (floor 350)"
else
  no "(S2c) only ${S_H:-0} id-shaped headings were scanned; below 350 this is not the fleet-scale proof the plan specifies"
  finish
fi
if [ "${S_FOR:-1}" -eq 0 ]; then
  ok "(S2c) (i) no heading block contains a flush-left checkbox line belonging to another entry"
else
  no "(S2c) (i) $S_FOR heading block(s) swallowed a flush-left checkbox entry: $(grep '^example_foreign_checkboxes' "$FIX/scan.txt" | head -3 | tr '\n' ' ')"
fi
if [ "${S_SIB:-1}" -eq 0 ] && [ "${S_CROSS:-1}" -eq 0 ]; then
  ok "(S2c) (ii) zero SIBLING overlaps and zero crossings of any kind — every overlap in the fixture is a strictly-deeper block contained in its parent"
else
  no "(S2c) (ii) $S_SIB sibling overlap(s) and $S_CROSS crossing(s): $(grep -E '^example_(crossings|sibling_overlaps)' "$FIX/scan.txt" | head -3 | tr '\n' ' ')"
fi
# The half of (ii) that a flat no-overlap check would have destroyed: AC5's nesting must be PRESENT
# and must be ACCEPTED. Zero crossings over a fixture with no nesting in it would prove nothing about
# the rule that matters.
if [ "${S_NEST:-0}" -ge 40 ]; then
  ok "(S2c) AC5's shape is present and accepted: $S_NEST parent/child pairs where a '### B-…-SUB' block sits strictly inside its '## B-…' parent (floor 40)"
else
  no "(S2c) only ${S_NEST:-0} legitimate parent/child nestings were found; a fixture without nesting makes 'zero crossings' meaningless and would hide a flat no-overlap rule that contradicts AC5"
fi
if [ "${S_DUP:-1}" -eq 0 ]; then
  ok "(S2c) every line is attributed to at most one entry AT EACH nesting level — no line is claimed by two same-level blocks"
else
  no "(S2c) $S_DUP line/level pair(s) are claimed by two entries of the same level: $(grep '^example_level_dup_lines' "$FIX/scan.txt" | head -3 | tr '\n' ' ')"
fi
if [ "${S_ENDCB:-0}" -eq "${C_CB:-0}" ] && [ "${S_ENDCB:-0}" -gt 0 ]; then
  ok "(S2c) all ${S_ENDCB} flush-left checkbox siblings sit exactly at the line where a heading block ENDS — the boundary is at the sibling, not past it"
else
  no "(S2c) ${S_ENDCB:-0} heading blocks end at a flush-left checkbox but the fixture holds ${C_CB:-0} of them — some block ran past its sibling or stopped short of it"
fi
cov_floor=$(( ${C_TOT:-0} / 2 ))
if [ "${S_COV:-0}" -gt "$cov_floor" ]; then
  ok "(S2c) heading blocks cover $S_COV of $C_TOT fixture lines — the spans are substantive, not one line each"
else
  no "(S2c) heading blocks cover only ${S_COV:-0} of ${C_TOT:-?} lines — the spans collapsed to (near) single lines and the overlap assertions above are trivially satisfied"
fi

# --- S2d the negative control: all four detectors can go red ------------------------------------
smoke scan-widened "$FIX/fleet.md" 4 > "$FIX/widened.txt" 2>&1
wdn(){ sed -n "s/^widened_$1=\([0-9]*\)$/\1/p" "$FIX/widened.txt"; }
W_CROSS="$(wdn crossings)"; W_SIB="$(wdn sibling_overlaps)"; W_FOR="$(wdn foreign_checkboxes)"
W_DUP="$(wdn level_dup_lines)"
rec2 ""
rec2 "## Negative control — every span widened by 4 lines (the shape a broken entry_block produces)"
rec2 "crossings=$W_CROSS sibling_overlaps=$W_SIB foreign_checkboxes=$W_FOR level_dup_lines=$W_DUP"
if [ "${W_CROSS:-0}" -gt 0 ] && [ "${W_SIB:-0}" -gt 0 ] && [ "${W_FOR:-0}" -gt 0 ] \
   && [ "${W_DUP:-0}" -gt 0 ]; then
  ok "(S2d) all four detectors go RED on deliberately widened spans (crossings=$W_CROSS siblings=$W_SIB foreign=$W_FOR dup=$W_DUP) — the four zeros in (S2c) are measurements, not decoration"
else
  no "(S2d) widening every span by 4 lines produced crossings=${W_CROSS:-0} siblings=${W_SIB:-0} foreign=${W_FOR:-0} dup=${W_DUP:-0}; a detector that cannot go red makes its zero above worthless"
fi

# --- S2-OBS the live fleet file: reported, never a verdict ---------------------------------------
# NEVER `ok`/`no`. Two reasons, both from the plan: this file belongs to another project and changes
# daily, so a gate here could go red from someone else's edit; and a PASS here could read as cover for
# a failure of the generated-fixture gate above, which is the real proof. It runs AFTER the gate so it
# cannot short-circuit it.
rec2 ""
rec2 "## OBSERVATION — the live fleet file (never a verdict)"
rec2 "path: $FLEET_BACKLOG"
if [ -f "$FLEET_BACKLOG" ]; then
  if smoke fleet "$FLEET_BACKLOG" > "$FIX/fleetobs.txt" 2>&1; then
    rec2 "$(tr '\n' ' ' < "$FIX/fleetobs.txt")"
    o_sha="$(sed -n 's/^sha256=\([0-9a-f]*\)$/\1/p' "$FIX/fleetobs.txt")"
    o_h="$(sed -n 's/^headings=\([0-9]*\)$/\1/p' "$FIX/fleetobs.txt")"
    o_x="$(sed -n 's/^crossings=\([0-9]*\)$/\1/p' "$FIX/fleetobs.txt")"
    o_f="$(sed -n 's/^foreign_checkboxes=\([0-9]*\)$/\1/p' "$FIX/fleetobs.txt")"
    o_d="$(sed -n 's/^level_dup_lines=\([0-9]*\)$/\1/p' "$FIX/fleetobs.txt")"
    say "OBSERVATION fleet file sha256=$o_sha headings=$o_h crossings=$o_x foreign=$o_f dup_lines=$o_d (NOT a verdict)"
    if [ "${o_x:-0}" != "0" ] || [ "${o_f:-0}" != "0" ] || [ "${o_d:-0}" != "0" ]; then
      say "OBSERVATION anomaly on a file this repo does not own — file it as a backlog finding, do not fail this suite"
      rec2 "ANOMALY: crossings=$o_x foreign=$o_f dup=$o_d — investigate as a finding, not as a failure of this suite"
    else
      rec2 "no anomaly: $o_h id-shaped headings, all boundaries clean"
    fi
  else
    say "OBSERVATION the fleet scan errored: $(tr '\n' ' ' < "$FIX/fleetobs.txt")"
    rec2 "scan errored (observation only): $(tr '\n' ' ' < "$FIX/fleetobs.txt")"
  fi
else
  say "OBSERVATION $FLEET_BACKLOG is absent on this machine — nothing to observe (the gate above is unaffected)"
  rec2 "absent on this machine — nothing to observe; the generated-fixture gate above is unaffected"
fi

finish
