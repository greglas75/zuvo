#!/usr/bin/env bash
# THE WHOLE-FEATURE SMOKE PROOFS for `zuvo:backlog verify / groom / doc` — SMOKE1 (dogfood the whole
# pipeline on this repo's own backlog, with entry-level conservation) and SMOKE2 (the refusal holds,
# and a second pass resumes for free).
#
# ONE THING TO READ BEFORE ANY NUMBER THIS FILE PRINTS. **No verdict here was produced by a model.**
# Task 7's GREEN says that where a step needs real agent dispatch the suite asserts the orchestrator's
# queue and conservation logic against a RECORDED RESPONSE FIXTURE rather than calling one, so that it
# stays deterministic in CI. That is the right call, and it means every "N of N entries carry a verdict
# with a resolvable evidence line" below is a statement about the pipeline's BOOKKEEPING and about
# nothing else. The agent-lane rows say so in their own `evidence` field — they read "the recorded
# fixture response reaches no verdict for this entry". A reader who mistakes this ledger for a
# verification pass has read it backwards, which is why `mkresp7.py` writes that sentence into the
# data instead of only into a comment: the whole feature exists to make verdicts trustworthy, and a
# fixture-fed ledger presented as a verified one would be the worst defect this plan could ship.
#
# WHAT IS REAL HERE, and it is most of it: the mint pre-pass, the four deterministic classes and their
# resolvability checks, the byte-capped chunker, the dispatch, control (a) shape / (b) resolvability /
# (c) keyword overlap / (d) seeded known-answers, three-way conservation against the dispatch, the
# ledger's content-keyed staleness and reuse, the coverage refusal, the scope refusal, the delegated
# closures, entry-level conservation over both files, and the rendered document's provenance. All of
# that runs on 421 real entries of this repo's own `memory/backlog.md`.
#
# EVERY COUNT IS DERIVED, AND THAT IS NOT FASTIDIOUSNESS. SMOKE1 as written in the plan names "the
# 387-entry inventory", "the 24 marker-carrying entries" and "the 6 duplicate content keys". The entry
# count has been wrong SIX times in that plan (387, 330, 483, 402, 494, 495); measured here it is 421
# committed against 503 in the live working tree, and that the two differ is the argument. So this file
# asserts no inventory literal: it derives each number from the bytes, prints it, names the SELECTION,
# and cross-checks it against the number the pre-pass independently reports. A smoke proof that
# asserted `== 24` would fail for a reason that has nothing to do with the pipeline.
#
# THE DOGFOOD NEVER TOUCHES THE LIVE BACKLOG. `zuvo_backlog_io.resolve` deliberately jumps to the MAIN
# worktree, so in a linked checkout the live file is *another directory's*. Every run below is against a
# temp clone of this checkout's WORKING TREE, and the live `memory/backlog.md`, its archive and its
# ledger are sha256'd before anything runs and re-checked in `finish` — a moved byte is a FAIL, not a
# surprise.
#
# THE FIXTURE TREE IS COPIED, NOT `git archive`d, and that is a measured requirement rather than a
# preference: `rt`'s delta mirror carries NO `.git` at all (checked 2026-10-02 — `git rev-parse HEAD`
# there is `fatal: not a git repository`), so a fixture built from git history would make this child a
# permanent farm red of exactly the kind `docs/runbook/testing.md` §5 warns about. The whole source tree
# travels because the deterministic `STALE-OBSOLETE` class asks the filesystem whether each cited path
# exists: a fixture with the backlog and no code would classify every path-citing entry as obsolete and
# the dogfood would be about a repo that does not exist.
#
# ONE GROUP DOES NEED HISTORY and says so: group R runs the refusal half against the real pre-refusal
# COMMITS. Where there is no `.git` it prints NOTE lines and asserts nothing — it never prints a PASS it
# did not earn, and never a `SKIP:` that would make `tests/run-all.sh` discount the whole child.
#
# FOUR HARNESS RULES, each paid for by a false green in this repo:
#   * `set -uo pipefail`, never `set -e`.
#   * `command_not_found_handle` CANNOT increment a counter: bash runs it in a SUBSHELL, so
#     `FAIL=$((FAIL+1))` is discarded. A FILE is the only evidence that crosses the boundary — hence
#     CNFH_MARK and `finish`. That subshell class has cost this plan FIVE defects (this handler, `no()`
#     inside `$( )`, `mkrepo4`'s counter inside `$( )` which made a byte-equality check compare a file
#     with itself and pass, an unescaped backtick, and bash expanding every word of a `local` before
#     assigning any of them). Nothing below creates a subshell where it needs a side effect, and no
#     `local` initialiser reads another name declared in the same statement.
#   * NO `SKIP:` PATH. python3, git and tar are stated prerequisites. A missing one is a `no` then
#     `finish` — `tests/run-all.sh` classifies exit 0 plus a leading `SKIP:` as SKIP, and a SKIP never
#     fails the run.
#   * EVERY assertion group has a MUTANT that reverts only its behaviour (group MS), and the factory
#     HARD-ERRORS when a substitution does not apply exactly once — otherwise "the mutant passed"
#     silently means "the mutation was never made".
#
# NO VACUOUS ASSERTIONS. Task 4's write-discipline assertions had an empty subject on this repo (N=0)
# and would have passed trivially, so every fixture here is CENSUSED and the census is printed: the
# entry count, the marker count, the duplicate-key count, the chunk count, the dispatched-row count,
# the seed count per chunk and the moved-entry count all have to be non-zero before anything is claimed
# about them.
#
# THE FIXTURE TREE IS NOT REMOVED. It lives under $TMPDIR (OS-reaped) and holds git repos and lock
# dirs; a recursive delete is the one command in this file that must never be misaimed. The path is
# printed at the end so a failing run can be inspected instead of re-created.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
SCRIPTS="$ROOT/scripts/zuvo-home"
GROOM="$SCRIPTS/backlog-groom.py"
ARCHIVER="$SCRIPTS/backlog-archive.py"

# The lock wait is the only thing shortened; nothing here contends for real.
export ZUVO_LOCK_WAIT=0.5

PASS=0; FAIL=0
ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

FIX="$(mktemp -d "${TMPDIR:-/tmp}/zuvo-backlog-smoke.XXXXXX")"
# Canonicalise once: on macOS $TMPDIR is /var/folders/... and /var is a symlink to /private/var, so the
# helpers (which resolve real paths, correctly) answer /private/var/... while every comparison here
# would hold the unresolved form. Linux has no such symlink, which is why the farm never sees it.
FIX="$(cd "$FIX" && pwd -P)"

CNFH_MARK="$FIX/.cnfh"
command_not_found_handle(){
  echo "  FAIL harness: unknown command '$1'"
  printf '%s\n' "$1" >> "$CNFH_MARK"
  return 127
}

sha256f(){ if [ -f "$1" ]; then python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1"; else echo "-"; fi; }

# ---- THE LIVE-FILE GUARD ---------------------------------------------------------------------------
# Recorded BEFORE anything runs and re-checked in `finish`. The paths come from the shipped io layer,
# not from `$ROOT/memory`, because `resolve` jumps to the MAIN worktree — in a linked checkout the live
# backlog is another directory's file, and guarding the wrong path would prove nothing.
LIVE_LIST="$FIX/live.txt"
python3 - "$SCRIPTS" "$ROOT" >"$LIVE_LIST" 2>"$FIX/live.err" <<'PYEOF'
import os
import sys
sys.path.insert(0, sys.argv[1])
import zuvo_backlog_io as zio      # noqa: E402
import zuvo_backlog_ledger as zl   # noqa: E402
root = sys.argv[2]
_, real, archive = zio.resolve(root)
print(real)
print(archive)
print(zl.ledger_paths(root)[1])
print(os.path.join(root, "memory", "backlog.md"))        # this checkout's OWN copy, guarded too
PYEOF
LIVE_SHAS="$FIX/live-shas.txt"
: > "$LIVE_SHAS"
while IFS= read -r p; do printf '%s %s\n' "$(sha256f "$p")" "$p" >> "$LIVE_SHAS"; done < "$LIVE_LIST"

finish(){
  if [ -s "$CNFH_MARK" ]; then
    no "(G0) unknown command(s) ran: $(sort -u "$CNFH_MARK" | tr '\n' ' ')— a misspelled helper prints and returns 127 in a SUBSHELL, so every assertion that used it checked nothing"
  fi
  local moved
  moved=0
  while IFS=' ' read -r want path; do
    if [ "$(sha256f "$path")" != "$want" ]; then
      no "(LIVE) $path MOVED during this run (was $want) — the dogfood is supposed to run on a temp clone and never on the live backlog"
      moved=$((moved+1))
    fi
  done < "$LIVE_SHAS"
  [ "$moved" -eq 0 ] && ok "(LIVE) every live backlog path is byte-identical across the whole suite ($(awk 'END{print NR}' "$LIVE_SHAS") path(s), sha256): $(awk '{printf "%s=%s ", $2, substr($1,1,12)}' "$LIVE_SHAS")"
  echo "fixtures: $FIX ($(du -sh "$FIX" 2>/dev/null | awk '{print $1}') — four full tree copies, deliberately NOT deleted; \$TMPDIR reaps them)"
  echo "RESULT: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

echo "== backlog grooming: whole-feature smoke =="

# --- G0 preconditions. No SKIP on any of them. -----------------------------------------------------
if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
  ok "(G0) bash ${BASH_VERSION%%(*} is 4+ — command_not_found_handle fires, typo protection is live"
else
  no "(G0) bash ${BASH_VERSION%%(*} predates command_not_found_handle (bash 4+): a misspelled helper returns 127 and writes no marker, so this file's FAIL count proves nothing — re-run under bash >= 4"
  finish
fi
for f in "$GROOM" "$ARCHIVER" "$SCRIPTS/zuvo_backlog_ledger.py" "$SCRIPTS/zuvo_backlog_apply.py" \
         "$SCRIPTS/zuvo_backlog_render.py" "$SCRIPTS/zuvo_backlog_prepass.py"; do
  [ -f "$f" ] && ok "(G0) present: ${f#"$ROOT"/}" || { no "(G0) missing: ${f#"$ROOT"/} — nothing below can be checked"; finish; }
done
for c in python3 git tar; do
  command -v "$c" >/dev/null 2>&1 && ok "(G0) $c is on PATH" || { no "(G0) $c is absent and this suite has no SKIP path — it is a stated prerequisite of this repo"; finish; }
done
[ -s "$LIVE_LIST" ] && ok "(G0) the live-file guard resolved $(awk 'END{print NR}' "$LIVE_LIST") path(s) through the shipped io layer, so finish compares the files the helpers would really write" \
  || { no "(G0) the live-file guard could not resolve any path: $(tail -2 "$FIX/live.err") — without it this suite could corrupt the real backlog and report green"; finish; }
SRC_BL="$ROOT/memory/backlog.md"
if [ -s "$SRC_BL" ]; then
  ok "(G0) the selection exists: $SRC_BL, $(wc -c <"$SRC_BL" | tr -d ' ') bytes, sha256 $(sha256f "$SRC_BL") — named exactly, because the plan's SMOKE1 quotes an entry count instead and has been wrong six times"
else
  no "(G0) $SRC_BL is missing or empty, so there is nothing to dogfood"
  finish
fi
# History is OPTIONAL and used by exactly one group. Resolved once, here, so no later command has to
# guess, and so the farm's historyless delta mirror produces a NOTE rather than a red.
HAVE_GIT=0
HEAD_SHA="no-git-history"
if git -C "$ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1; then
  HAVE_GIT=1
  HEAD_SHA="$(git -C "$ROOT" rev-parse --short HEAD)"
  ok "(G0) git history IS available here (HEAD=$HEAD_SHA), so group R can run the RED against the real pre-refusal commits"
else
  echo "  NOTE git history is absent in this environment (rt's delta mirror carries no .git), so group R will assert nothing and say so. Every other group below is unaffected: the fixture is a copy of the working tree."
fi

# ==================================================================================================
# The committed helpers this suite runs. Each one is a FILE written here rather than an inline `-c`
# string, for the reason the sibling suite's probes record: a multi-line python program inside a shell
# string loses its indentation to the first stray quote, and the failure reads as "the module is
# broken".
# ==================================================================================================

# ---- the entry census: the three numbers SMOKE1 names, derived from the bytes ----------------------
CENSUS7="$FIX/census7.py"
cat > "$CENSUS7" <<'PYEOF'
r"""Census ONE backlog file: entries, headings, resolution markers, duplicate keys. Machine-readable.

RAW docstring, same reason as every probe in the sibling suite: a `\s` in a plain one is a
SyntaxWarning on stderr, and a caller reads stderr as "the fixture did not build".

Usage: census7.py <moddir> <backlog>

THE MARKER TEST IS THE CLASSIFIER'S OWN, not a regex retyped here: `heading_resolution_pos` for a
heading entry and `resolution_marker_pos` otherwise — the exact pair `zuvo_backlog_verdicts.marker_pos`
uses. PR 1 measured 50 false positives over 3561 heading entries for the loose guard, every one of them
in the archivable direction, so a second copy of this choice is the drift that reopens them.

DUPLICATE KEYS ARE SPLIT BY PREFIX. `fp:` keys are CONTENT keys (sha1 of `normalize_signature`); `id:`
keys are not. The plan's "6 duplicate content keys" is the only one of its three SMOKE1 numbers that
survives measurement, and it survives only under the `fp:`-only reading — the total is 9.
"""
import collections
import sys

sys.path.insert(0, sys.argv[1])
import zuvo_backlog_io as zio      # noqa: E402
import zuvo_backlog_ledger as zl   # noqa: E402
import zuvo_backlog_parse as zb    # noqa: E402

KINDS = zb.DEFAULT_KINDS + (zb.KIND_HEADING,)
text = zio.read(sys.argv[2])
entries = list(zb.iter_entries(text, kinds=KINDS))


def marker_pos(e):
    return (zb.heading_resolution_pos(e.body) if e.kind == zb.KIND_HEADING
            else zb.resolution_marker_pos(e.body))


markers = [e for e in entries if marker_pos(e) >= 0]
counts = collections.Counter(e.key for e in entries)
dups = sorted(k for k, n in counts.items() if n > 1)
print("BYTES=%d" % len(text.encode("utf-8")))
print("ENTRIES=%d" % len(entries))
print("HEADINGS=%d" % sum(1 for e in entries if e.kind == zb.KIND_HEADING))
print("KINDS=%s" % ",".join("%s:%d" % kv for kv in sorted(collections.Counter(
    e.kind for e in entries).items())))
print("MARKERS=%d" % len(markers))
print("MARKERS_BY_KIND=%s" % ",".join("%s:%d" % kv for kv in sorted(collections.Counter(
    e.kind for e in markers).items())))
print("STATUS_DONE=%d" % sum(1 for e in entries if e.status == "done"))
print("STATUS_DONE_BY_KIND=%s" % ",".join("%s:%d" % kv for kv in sorted(collections.Counter(
    e.kind for e in entries if e.status == "done").items())))
print("DUP_KEYS=%d" % len(dups))
print("DUP_KEYS_FP=%d" % sum(1 for k in dups if k.startswith("fp:")))
print("DUP_KEYS_ID=%d" % sum(1 for k in dups if k.startswith("id:")))
print("DUP_ENTRIES=%d" % sum(counts[k] for k in dups))
for k in dups:
    mine = [e for e in entries if e.key == k]
    print("DUP=%s entries=%d distinct_text=%d lines=%s"
          % (k, len(mine), len({zl.text_sha(e.body) for e in mine}),
             ",".join(str(e.lineno) for e in mine)))
print("HEADING_IDS=%d" % sum(1 for e in entries
                             if e.kind == zb.KIND_HEADING and e.ident))
for e in entries:
    if e.kind == zb.KIND_HEADING and e.ident:
        print("HEADING_ID=%s" % e.ident)
PYEOF

# ---- entry-level conservation, keyed on text_sha, over BOTH files ---------------------------------
CONS7="$FIX/conserve7.py"
cat > "$CONS7" <<'PYEOF'
r"""One `<WHERE> <text_sha> <subject>` line per entry across BOTH files, so conservation is a multiset
comparison a caller can diff.

Usage: conserve7.py <moddir> <open.md> <archive.md>

WHY `text_sha` AND NOT LINES OR COUNTS. `cmd_archive` ends `atomic_write(archive)` then
`atomic_write(real)`; decision 7 records that both a line count and an occurrence count stay green
through a boundary error (A25's own comment says so, and PR 1's boundary trap proved it). `text_sha`
is the per-entry identity the ledger already uses, so `open_before + archived_before ==
open_after + archived_after` as a MULTISET is the only form of the invariant that catches
mis-attribution — which is exactly what PR 1's `refuse_foreign_entries` exists to catch.
"""
import sys

sys.path.insert(0, sys.argv[1])
import zuvo_backlog_io as zio      # noqa: E402
import zuvo_backlog_ledger as zl   # noqa: E402
import zuvo_backlog_parse as zb    # noqa: E402

KINDS = zb.DEFAULT_KINDS + (zb.KIND_HEADING,)
for where, path in (("OPEN", sys.argv[2]), ("ARCH", sys.argv[3])):
    for e in zb.iter_entries(zio.read(path), kinds=KINDS):
        print("%s %s %s" % (where, zl.text_sha(e.body), e.ident or e.key))
PYEOF

# ---- the duplicate-key NON-MERGE census, against the ledger ---------------------------------------
DUPS7="$FIX/dups7.py"
cat > "$DUPS7" <<'PYEOF'
r"""Prove nothing MERGED: every duplicate-keyed entry still exists, still resolves to an exact-sha
ledger row, and the ledger holds one row per distinct TEXT under that key.

Usage: dups7.py <moddir> <backlog> <ledger.jsonl>

`backlog-protocol.md` is explicit that two entries sharing a key are TWO entries, and the plan's own
option-A deferral records that a key-deduping rewriter destroys real entries here. The invariant is
therefore stated at ENTRY level and at TEXT level, never at row level: `_dedup` collapses two rows that
share a key AND a `text_sha` — two judgements about one text — and that is correct. Collapsing two
DISTINCT texts would not be.
"""
import collections
import json
import sys

sys.path.insert(0, sys.argv[1])
import zuvo_backlog_io as zio      # noqa: E402
import zuvo_backlog_ledger as zl   # noqa: E402
import zuvo_backlog_parse as zb    # noqa: E402

KINDS = zb.DEFAULT_KINDS + (zb.KIND_HEADING,)
entries = list(zb.iter_entries(zio.read(sys.argv[2]), kinds=KINDS))
read = zl.read_ledger(sys.argv[3])
counts = collections.Counter(e.key for e in entries)
dups = sorted(k for k, n in counts.items() if n > 1)
print("DUP_KEYS=%d LEDGER_ROWS=%d LEDGER_DEFECTS=%d" % (len(dups), len(read.rows), len(read.defects)))
mismatch = 0
for k in dups:
    mine = [e for e in entries if e.key == k]
    texts = {zl.text_sha(e.body) for e in mine}
    rows = [r for r in read.rows if k in (r.get("keys") or [])]
    flag = "" if len(rows) == len(texts) else " MERGED"
    mismatch += int(len(rows) != len(texts))
    print("DUP=%s entries=%d distinct_text=%d rows=%d%s"
          % (k, len(mine), len(texts), len(rows), flag))
print("ROWS_PER_TEXT_MISMATCH=%d" % mismatch)
plan = zl.plan_reuse(entries, read.rows)
reused = {id(e) for e, _ in plan.reuse}
dupe_entries = [e for e in entries if counts[e.key] > 1]
print("DUP_ENTRIES=%d DUP_ENTRIES_WITH_EXACT_ROW=%d"
      % (len(dupe_entries), sum(1 for e in dupe_entries if id(e) in reused)))
print("DUPLICATE_OF_ROWS=%d" % sum(1 for r in read.rows
                                   if r.get("verdict") == zl.VERDICT_DUPLICATE_OF))
# The MINT premise, measured rather than assumed: SMOKE1 says the duplicates are "disambiguated by
# minting distinct ids". `mint_into` refuses the BULLET dialect by a deliberate, pinned PR 1 contract,
# so the honest statement is how many of them a mint could even reach.
from zuvo_backlog_prepass import mint_set, mintable   # noqa: E402
lines = zio.read(sys.argv[2]).splitlines(keepends=True)
declared = mint_set(entries)
targets, unmintable = mintable(lines, declared)
dup_keys = set(dups)
print("MINT_SET=%d MINTABLE=%d UNMINTABLE=%d" % (len(declared), len(targets), len(unmintable)))
print("DUP_ENTRIES_IN_MINT_SET=%d DUP_ENTRIES_MINTABLE=%d"
      % (sum(1 for e in declared if e.key in dup_keys),
         sum(1 for e in targets if e.key in dup_keys)))
PYEOF

# ---- the RECORDED verifier response. No model is called; the fixture SAYS SO in its own data. -----
RESP7="$FIX/mkresp7.py"
cat > "$RESP7" <<'PYEOF'
r"""The RECORDED verifier response for ONE dispatched chunk. **No model is called.**

Usage: mkresp7.py <moddir> <repo> <dispatch.jsonl> <answers.json> <flavour> [subject]

WHAT IT ANSWERS, and why the wording is in the DATA. Every real row gets `NOT-VERIFIABLE` with the
evidence sentence below, so that a reader of the ledger, the rendered document or either proof artifact
cannot mistake a fixture-fed row for a verdict a model reached. `NOT-VERIFIABLE` is also the only
answer a fixture is ENTITLED to give: control (b) exempts it from citation precisely because demanding
one for "the repo does not answer" is an incentive to answer something else, and inventing a
`STILL-REAL` citation here would be fabricating the evidence this feature exists to check.

THE SEEDS ARE ANSWERED CORRECTLY, and that is the part that really exercises the controls. Control (d)
grades K=4 rows per chunk whose answer this repo already records; a miss in either direction re-dispatches
the chunk. The two `STALE-FIXED` seeds are answered in the archive-proof shape the include's evidence
table permits, citing the archive line that actually holds the entry — so control (c)'s words half runs
against the archive window — and the two `STILL-REAL` seeds are answered from the live anchor's own
`path:line`, so (b) resolvability and (c) basename-equality-plus-two-words both run for real.

Flavours: `clean`, and `omit <key>` — the latter is A5b's conservation negative control, which is what
makes "every chunk passed with zero rejections" a measurement rather than a statement about a fixture.
"""
import json
import sys

MODDIR, REPO, DISPATCH, ANSWERS, FLAVOUR = sys.argv[1:6]
SUBJECT = sys.argv[6] if len(sys.argv) > 6 else ""
sys.path.insert(0, MODDIR)
import zuvo_backlog_io as zio      # noqa: E402
import zuvo_backlog_parse as zb    # noqa: E402

KINDS = zb.DEFAULT_KINDS + (zb.KIND_HEADING,)
NOT_VERIFIED_BY_A_MODEL = "the recorded fixture response reaches no verdict for this entry"

rows = [json.loads(line) for line in open(DISPATCH, encoding="utf-8") if line.strip()]
answers = {str(k): str(v) for k, v in json.load(open(ANSWERS, encoding="utf-8")).items()}
_, _real, archive = zio.resolve(REPO)
archived = list(zb.iter_entries(zio.read(archive), kinds=KINDS))
# The archive LINE that holds each closed seed's text. `build_seeds` strips the resolution markers
# before seeding, so the lookup strips them too — otherwise the seed never matches its own source and
# the citation would fall back to a line about a different entry.
line_of = {zb.strip_resolution_markers(e.body).strip(): e.lineno for e in archived}


def answer(row):
    key = row["keys"][0]
    want = answers.get(key)
    if want == "STALE-FIXED":
        body = row["raw_text"].strip()
        lineno = line_of.get(body, archived[0].lineno if archived else 1)
        return want, ('backlog-done.md:%d section="Archived" records %s'
                      % (lineno, " ".join(body.split()[:8])))
    if want == "STILL-REAL":
        path, lineno = row["raw_text"].split()[0].split(":")
        return want, "%s:%s %s" % (path, lineno, " ".join(row["raw_text"].split()[3:9]))
    return "NOT-VERIFIABLE", NOT_VERIFIED_BY_A_MODEL


out = []
for row in rows:
    verdict, evidence = answer(row)
    out.append({"key": row["keys"][0], "verdict": verdict, "evidence": evidence})
if FLAVOUR == "omit":
    out = [r for r in out if r["key"] != SUBJECT]
elif FLAVOUR != "clean":
    sys.exit("mkresp7: unknown flavour %r" % FLAVOUR)
for r in out:
    print(json.dumps(r, sort_keys=True))
PYEOF

# ---- the E2E selection: drop the status-done entries the ARCHIVER structurally cannot move --------
REDUCE7="$FIX/reduce7.py"
cat > "$REDUCE7" <<'PYEOF'
r"""Derive, and PRINT, the selection on which `apply` can actually perform its closures.

Usage: reduce7.py <moddir> <in.md> <out.md>

WHY THIS EXISTS, measured at Task 7 and reported rather than patched around. `zuvo_backlog_apply._decide`
returns `archived` for any entry whose `status` is `done`; `backlog-archive.py archive` indexes
`kinds=(KIND_CHECKBOX,)` and gates the heading dialect behind `ZUVO_BACKLOG_HEADING_ARCHIVE`. On this
repo's own backlog the 58 status-done entries are 37 BULLET and 21 HEADING and NOT ONE checkbox, so the
archiver's movable set is 20 and `apply` refuses at its scope check (RC_SCOPE) rather than delegating a
whole-file archive no verdict licensed. That refusal is the safe direction and it is asserted as the
dogfood's real outcome; it also means the full file can never reach the closure half of the pipeline.

So the closure half runs on the SAME backlog with exactly two classes of entry removed, both named on
stdout: every status-done entry the archiver cannot see (not a heading), and the OPEN twin of any id a
done entry also carries — the double-duty id the archiver refuses on by name. Nothing else is touched,
and the census of what went is printed so the selection is auditable rather than asserted.
"""
import sys

sys.path.insert(0, sys.argv[1])
import zuvo_backlog_io as zio      # noqa: E402
import zuvo_backlog_parse as zb    # noqa: E402
from zuvo_backlog_block import entry_block   # noqa: E402

KINDS = zb.DEFAULT_KINDS + (zb.KIND_HEADING,)
text = zio.read(sys.argv[2])
lines = text.splitlines(keepends=True)
entries = list(zb.iter_entries(text, kinds=KINDS))
drop = set()
why = []


def take(e, reason):
    end = entry_block(lines, e.lineno - 1)
    drop.update(range(e.lineno - 1, end))
    why.append((reason, e.kind, e.ident or e.key, e.lineno))


done_idents = {e.ident.upper() for e in entries if e.status == "done" and e.ident}
for e in entries:
    if e.status == "done" and e.kind != zb.KIND_HEADING:
        take(e, "unmovable-dialect")
    elif e.status != "done" and e.ident and e.ident.upper() in done_idents:
        take(e, "double-duty-id")
out = "".join(ln for i, ln in enumerate(lines) if i not in drop)
with open(sys.argv[3], "w", encoding="utf-8") as fh:
    fh.write(out)
after = list(zb.iter_entries(out, kinds=KINDS))
print("REDUCE_BEFORE=%d REDUCE_AFTER=%d REDUCE_DROPPED=%d REDUCE_LINES=%d"
      % (len(entries), len(after), len(why), len(drop)))
for reason, kind, subject, lineno in why:
    print("REDUCE_DROP=%s %s %s :%d" % (reason, kind, subject, lineno))
print("REDUCE_DONE_AFTER=%d REDUCE_DONE_HEADING_AFTER=%d"
      % (sum(1 for e in after if e.status == "done"),
         sum(1 for e in after if e.status == "done" and e.kind == zb.KIND_HEADING)))
PYEOF

# ---- remove ONE verdict from a ledger, by id ------------------------------------------------------
SHORT7="$FIX/short7.py"
cat > "$SHORT7" <<'PYEOF'
r"""Copy a ledger, dropping every row for ONE id. Usage: short7.py <in> <out> <id>

The ROW is deleted, not corrupted: a corrupt line is `read_ledger`'s fail-closed path and it refuses
with RC_LEDGER, which is a DIFFERENT refusal from the coverage one SMOKE2 is about. Deleting makes the
entry simply unverified, which is the state decision 10's gate exists for.
"""
import json
import sys

src, dst, victim = sys.argv[1:4]
kept = [line for line in open(src, encoding="utf-8")
        if line.strip() and json.loads(line).get("id") != victim]
with open(dst, "w", encoding="utf-8") as fh:
    fh.writelines(kept)
print("KEPT=%d" % len(kept))
PYEOF

# ---- the mutant factory: ONE named mutation per directory, beside untouched siblings --------------
MKMUT7="$FIX/mkmut7.py"
cat > "$MKMUT7" <<'PYEOF'
r"""Write a named mutation of ONE shipped module into its own directory, beside untouched copies of
every sibling it imports AND of `backlog-archive.py`.

Usage: mkmut7.py <scriptsdir> <kind> <outdir>

EVERY sibling travels by GLOB rather than by a list: that list was manual twice in this repo's history
and cost the identical failure both times — a new module landed, the factory still named N files, and
every mutant died with ModuleNotFoundError, an import error wearing a mutation's clothes inside the
assertions that exist to prove the mutation fires. `backlog-archive.py` travels because `apply` finds
it through `os.path.realpath(__file__)`'s own directory, so a mutant directory without it would refuse
RC_HELPER in every delegation scenario and read exactly like a mutation.

`old` must occur EXACTLY ONCE in its file or this exits non-zero: "the mutant passed" must never be
able to mean "the mutation was never made".
"""
import glob
import os
import shutil
import sys

SRC, KIND, OUT = sys.argv[1:4]

APPLY = "zuvo_backlog_apply.py"
LEDGER = "zuvo_backlog_ledger.py"
RENDER = "zuvo_backlog_render.py"

MUTATIONS = {
    # SMOKE2's first refusal: decision 10's coverage gate. Removed, `apply` closes entries on a ledger
    # that never examined one of them.
    "nocoverrefuse": (APPLY, "    if verified != total:", "    if False:"),
    # SMOKE2's second refusal: decision 11's render gate. Removed, an unverified backlog is ranked and
    # grouped with no label at all.
    "norenderrefuse": (RENDER, "    if verified == total or partial:\n        return",
                       "    return\n    if verified == total or partial:\n        return"),
    # `--partial` stops omitting the ranking, so the escape hatch silently becomes the thing decision 11
    # refused: a RANKED document over a partially verified set.
    "partialranks": (RENDER, "    if not doc.partial:\n        out += _ranking(doc.scored)",
                     "    if True:\n        out += _ranking(doc.scored)"),
    # THE ONE WITH TEETH. The scope check is what stops `apply` delegating a WHOLE-FILE archive on
    # behalf of entries whose verdicts licensed it, carrying out the ones that did not. On this repo's
    # own backlog the two sets are 58 and 20, so with this removed the dogfood performs a closure
    # against the helper's own set and reports it as the licensed one.
    "noscoperefuse": (APPLY, "    if int(m.group(1)) != len(want):", "    if False:"),
    # Reuse by key alone: the second pass re-dispatches every entry, so "zero dispatches on resume" —
    # the property that makes mandatory whole-set verification affordable — quietly stops holding.
    "reuseblind": (LEDGER, '        exact = next((i for i in idx if rows[i].get("text_sha") == sha), None)',
                   "        exact = None"),
    # `_dedup` keyed on the key alone, dropping `text_sha` from the identity: two entries that share a
    # content key but say DIFFERENT things then collapse onto one verdict row — the key-deduping merge
    # `backlog-protocol.md` forbids and the option-A deferral measured as destroying real entries here.
    "dedupkeyonly": (LEDGER, '        ids = [(str(k), sha) for k in row.get("keys", [])]',
                     '        ids = [(str(k), "") for k in row.get("keys", [])]'),
    # `DUPLICATE-OF` stops being a REPORT and becomes a licence to drop one side of the pair.
    "dupmerges": (APPLY, '    if verdict == zl.VERDICT_DUPLICATE_OF:\n        return ("no-remedy",',
                  '    if verdict == zl.VERDICT_DUPLICATE_OF:\n        return ("dropped", "merge", VERB_DROP)\n'
                  '    if verdict == zl.VERDICT_DUPLICATE_OF:\n        return ("no-remedy",'),
    # The document's provenance sha stops describing the source, so decision 12's "a reader must be
    # able to tell whether the document still describes the file" becomes unanswerable.
    "shalies": (RENDER, '"source_sha256: %s" % sha,', '"source_sha256: %s" % ("0" * 64),'),
}


def sub(text, old, new, what):
    if text.count(old) != 1:
        sys.exit("mkmut7: %s occurs %dx, expected once — the mutation would not apply: %r"
                 % (what, text.count(old), old))
    return text.replace(old, new)


os.makedirs(OUT, exist_ok=True)
names = ["backlog-groom.py", "backlog-archive.py", "backlog-census.py"]
names += [os.path.basename(p) for p in sorted(glob.glob(os.path.join(SRC, "zuvo_backlog_*.py")))]
for name in names:
    shutil.copyfile(os.path.join(SRC, name), os.path.join(OUT, name))
if KIND != "none":
    if KIND not in MUTATIONS:
        sys.exit("mkmut7: unknown mutation %r" % KIND)
    target, old, new = MUTATIONS[KIND]
    dest = os.path.join(OUT, target)
    with open(dest, encoding="utf-8") as fh:
        text = fh.read()
    with open(dest, "w", encoding="utf-8") as fh:
        fh.write(sub(text, old, new, KIND))
PYEOF

mut7_build(){ python3 "$MKMUT7" "$SCRIPTS" "$1" "$FIX/mut-$1" >"$FIX/mk-$1.log" 2>&1; }
if mut7_build none; then
  ok "(Q0) the mutant factory writes its CONTROL copy — a failing mutant below is a mutation, not a copy"
else
  no "(Q0) the factory cannot write an unmutated copy ($(tail -1 "$FIX/mk-none.log")) — every mutant assertion here would be vacuous"
  finish
fi
CTL="$FIX/mut-none"
[ -f "$CTL/backlog-archive.py" ] \
  && ok "(Q0b) the control directory carries backlog-archive.py — apply delegates to the copy beside ITSELF, so a missing one would fail on an absence that reads exactly like a mutation" \
  || { no "(Q0b) $CTL has no backlog-archive.py"; finish; }

# ==================================================================================================
# Shell helpers. No subshell anywhere a side effect is needed, and no `local` initialiser reads a name
# declared in the same statement — bash expands every word of a `local` before assigning any of them,
# which is the fifth instance of this plan's subshell/expansion defect class.
# ==================================================================================================
mkclone(){   # $1 = destination dir, $2 = backlog file to install ("" keeps the working tree's own)
  mkdir -p "$1" || return 1
  # The WORKING TREE, excluding everything that is either enormous, generated, or a git directory this
  # fixture must not inherit — a nested .git would make `git init` below a no-op against the real repo.
  # Caches are excluded and content directories are NOT: every one of scripts/, tests/, hooks/,
  # shared/, rules/, docs/, skills/ and website/ is CITED by entries in this backlog, so dropping any
  # of them would turn their entries into STALE-OBSOLETE and change the dogfood's verdict mix.
  tar -c -C "$ROOT" --exclude=.git --exclude=node_modules --exclude=zuvo --exclude=.run \
      --exclude=.lastrun --exclude=dist --exclude=build --exclude=.mypy_cache \
      --exclude=.ruff_cache --exclude=.pytest_cache --exclude=__pycache__ --exclude=.venv \
      -f - . 2>/dev/null | tar -x -C "$1" || return 1
  [ -s "$1/memory/backlog.md" ] || return 1
  if [ -n "$2" ]; then cp "$2" "$1/memory/backlog.md" || return 1; fi
  git -C "$1" init -q . >/dev/null 2>&1 || return 1
  # `git add` and no commit: the ONLY consumer of trackedness here is `git ls-files` (control (d)'s live
  # anchors) and `git check-ignore` (the ledger placement rule), and both read the INDEX.
  git -C "$1" add . >/dev/null 2>&1 || return 1
  return 0
}

G7(){        # $1 = module dir, $2 = repo, $3 = $ZUVO_OUTPUT_DIR, $4... = argv
  ZUVO_OUTPUT_DIR="$3" python3 "$1/backlog-groom.py" "${@:4}" --repo "$2"
}

A7(){        # $1 = module dir, $2 = repo, $3... = argv — the archiver, heading gate ON
  ZUVO_BACKLOG_HEADING_ARCHIVE=1 python3 "$1/backlog-archive.py" "${@:3}" --repo "$2"
}

# The whole verify lane over every chunk: plan, then dispatch -> recorded response -> ingest per chunk.
# Writes <log>-plan.out, <log>-d<N>.out, <log>-i<N>.out and <log>-summary; returns non-zero on the
# first step that refuses, so a caller can assert on the failure rather than on a tail.
pipeline7(){ # $1 = moddir, $2 = repo, $3 = outdir, $4 = log prefix
  local md repo out log ctx nch k rc
  md="$1"; repo="$2"; out="$3"; log="$4"
  ctx="$out/context"
  rc=0
  G7 "$md" "$repo" "$out" plan >"$log-plan.out" 2>&1 || return 10
  nch="$(sed -n 's/^CHUNKS=\([0-9]*\).*/\1/p' "$log-plan.out" | head -1)"
  [ -n "$nch" ] || return 11
  : > "$log-summary"
  for k in $(seq 0 $((nch - 1))); do
    G7 "$md" "$repo" "$out" dispatch --chunk "$k" >"$log-d$k.out" 2>&1 || { rc=20; break; }
    python3 "$RESP7" "$CTL" "$repo" "$ctx/backlog-dispatch-$k.jsonl" \
            "$ctx/backlog-answers-$k.json" clean >"$log-resp$k.jsonl" 2>>"$log-resp.err" \
      || { rc=21; break; }
    G7 "$md" "$repo" "$out" ingest --chunk "$k" --dispatch "$ctx/backlog-dispatch-$k.jsonl" \
       --response "$log-resp$k.jsonl" >"$log-i$k.out" 2>&1 || { rc=22; break; }
    printf 'CHUNK %s dispatched=%s responded=%s seeds=%s accepted=%s rejects=%s\n' "$k" \
      "$(sed -n 's/^DISPATCHED=\([0-9]*\).*/\1/p' "$log-i$k.out" | head -1)" \
      "$(sed -n 's/.*RESPONDED=\([0-9]*\).*/\1/p' "$log-i$k.out" | head -1)" \
      "$(sed -n 's/.*SEEDS=\([0-9]*\).*/\1/p' "$log-i$k.out" | head -1)" \
      "$(sed -n 's/^ACCEPTED=\([0-9]*\).*/\1/p' "$log-i$k.out" | head -1)" \
      "$(sed -n 's/^REJECTS=\([0-9]*\).*/\1/p' "$log-i$k.out" | head -1)" >>"$log-summary"
  done
  return "$rc"
}

iv7(){ sed -n "s/^$2=//p" "$1" | head -1; }   # first `KEY=value` of a log, value only

# ==================================================================================================
# D — THE SELECTION AND THE THREE DERIVED COUNTS. Every one of SMOKE1's literals is stale; none is
# asserted. Each number is derived twice — once by this suite's census, once by the shipped pre-pass —
# and the two are required to AGREE, which is the guard that keeps them from going stale again.
# ==================================================================================================
echo "-- D: the selection, censused from the bytes --"

DOG="$FIX/dogfood"
if mkclone "$DOG" ""; then
  ok "(D0) the dogfood fixture is a temp copy of this checkout's working tree (HEAD=$HEAD_SHA) — the live backlog is never the subject, which is what makes this suite re-runnable"
else
  no "(D0) could not build the dogfood clone — nothing below can be checked"
  finish
fi
DOG_OUT="$FIX/dogfood-zuvo"
DOG_BL="$DOG/memory/backlog.md"
DOG_AR="$DOG/memory/backlog-done.md"
DOG_LED="$DOG/memory/backlog-verdicts.jsonl"

python3 "$CENSUS7" "$CTL" "$DOG_BL" >"$FIX/census-dog.out" 2>&1
if [ "$?" -eq 0 ] && [ -s "$FIX/census-dog.out" ]; then
  ok "(D1) the census ran over the selected bytes"
else
  no "(D1) the census could not run: $(tail -3 "$FIX/census-dog.out")"
  finish
fi
grep -Ev '^(DUP|HEADING_ID)=' "$FIX/census-dog.out"
D_ENTRIES="$(iv7 "$FIX/census-dog.out" ENTRIES)"
D_MARKERS="$(iv7 "$FIX/census-dog.out" MARKERS)"
D_DUPS="$(iv7 "$FIX/census-dog.out" DUP_KEYS)"
D_DUPS_FP="$(iv7 "$FIX/census-dog.out" DUP_KEYS_FP)"
D_DUPS_ID="$(iv7 "$FIX/census-dog.out" DUP_KEYS_ID)"
D_HEADIDS="$(iv7 "$FIX/census-dog.out" HEADING_IDS)"
D_DONE="$(iv7 "$FIX/census-dog.out" STATUS_DONE)"

# THE SELECTION, stated. Then the three counts, each with its own non-vacuity floor: a census that
# derived 0 entries, 0 markers or 0 duplicate keys would make every assertion below true for free, and
# Task 4's write-discipline group is the precedent — it had N=0 on this repo and passed trivially.
echo "  SELECTION: $SRC_BL as it stands in this checkout (sha256 $(sha256f "$SRC_BL"), HEAD=$HEAD_SHA), parsed by iter_entries(kinds=DEFAULT_KINDS+(KIND_HEADING,))"
[ "${D_ENTRIES:-0}" -gt 100 ] \
  && ok "(D2) entry inventory DERIVED = $D_ENTRIES (the plan's SMOKE1 says 387; its own text has also carried 330, 483, 402, 494, 495 and 503 — not one literal is asserted here)" \
  || no "(D2) the derived entry inventory is ${D_ENTRIES:-0}, which is below the 100-entry floor this fixture must clear; every count assertion below would be vacuous"
[ "${D_MARKERS:-0}" -gt 0 ] \
  && ok "(D3) marker-carrying entries DERIVED = $D_MARKERS, by the classifier's own heading_resolution_pos/resolution_marker_pos pair (SMOKE1 says 24) — by kind: $(iv7 "$FIX/census-dog.out" MARKERS_BY_KIND)" \
  || no "(D3) no entry carries a resolution marker, so the whole closure half of this proof would have no subject"
[ "${D_DUPS:-0}" -gt 0 ] \
  && ok "(D4) duplicate entry keys DERIVED = $D_DUPS ($D_DUPS_FP content/fp: + $D_DUPS_ID id:) over $(iv7 "$FIX/census-dog.out" DUP_ENTRIES) entries — SMOKE1's '6 duplicate content keys' is the ONE number of its three that measurement confirms, and only under the fp:-only reading" \
  || no "(D4) no duplicate key exists in the selection, so the non-merge assertions below would be vacuous"
grep '^DUP=' "$FIX/census-dog.out"

# The STALENESS GUARD: the same three numbers, derived a second time by the shipped code path, must
# agree. A literal cannot drift here because there is no literal — but two independent derivations can,
# and that disagreement is exactly the defect a hand-typed count hides.
G7 "$CTL" "$DOG" "$DOG_OUT" plan --dry-run >"$FIX/dog-plan-dry.out" 2>&1
P_ENTRIES="$(iv7 "$FIX/dog-plan-dry.out" ENTRIES)"
P_MARKERS="$(sed -n 's/^DET_CLASS=marker //p' "$FIX/dog-plan-dry.out" | head -1)"
[ "${P_ENTRIES:-x}" = "${D_ENTRIES:-y}" ] \
  && ok "(D5) the shipped pre-pass independently reports ENTRIES=$P_ENTRIES, equal to the census — two derivations, one number, no literal" \
  || no "(D5) the census says $D_ENTRIES entries and the pre-pass says ${P_ENTRIES:-<none>}; one of the two parses the file differently and a smoke proof cannot sit on either"
[ "${P_MARKERS:-x}" = "${D_MARKERS:-y}" ] \
  && ok "(D6) …and its deterministic marker class is $P_MARKERS, equal to the censused marker count — the loose-guard regression PR 1 measured (50 false positives over 3561 heading entries) would show up here as a disagreement" \
  || no "(D6) the census says $D_MARKERS markers and the marker class says ${P_MARKERS:-<none>}"

# The live working tree, REPORTED and gating nothing — because the divergence IS the plan's argument.
LIVE_BL="$(head -1 "$LIVE_LIST")"
python3 "$CENSUS7" "$CTL" "$LIVE_BL" >"$FIX/census-live.out" 2>&1
echo "  OBSERVED (gates nothing): the live $LIVE_BL has $(iv7 "$FIX/census-live.out" ENTRIES) entries, $(iv7 "$FIX/census-live.out" MARKERS) markers, $(iv7 "$FIX/census-live.out" DUP_KEYS) duplicate keys"
[ "$(iv7 "$FIX/census-live.out" ENTRIES)" != "$D_ENTRIES" ] \
  && ok "(D7) the committed selection and the live working tree DISAGREE on the entry count ($D_ENTRIES vs $(iv7 "$FIX/census-live.out" ENTRIES)) — which is why this suite names its selection instead of quoting a number" \
  || ok "(D7) the committed selection and the live working tree agree at $D_ENTRIES entries today; the suite still names its selection, because they have differed six times in this plan"

# The refusal codes, READ from the module and never retyped: an assertion on a literal 27 keeps passing
# after a renumbering that moved the meaning.
python3 - "$CTL" >"$FIX/codes.out" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import zuvo_backlog_prepass as zp      # noqa: E402
print("CODES=%s" % ",".join("%s=%d" % kv for kv in sorted(
    (n, v) for n, v in vars(zp).items() if n.startswith("RC_") and isinstance(v, int))))
PYEOF
rc7(){ sed -n "s/.*RC_$1=\([0-9]*\).*/\1/p" "$FIX/codes.out" | head -1; }
RC_UNVERIFIED="$(rc7 UNVERIFIED)"; RC_SCOPE="$(rc7 SCOPE)"
RC_PARTIAL="$(rc7 PARTIAL)"; RC_QUEUE="$(rc7 QUEUE)"; RC_REJECTED="$(rc7 REJECTED)"
if [ -n "$RC_UNVERIFIED" ] && [ -n "$RC_SCOPE" ] && [ -n "$RC_PARTIAL" ] && [ -n "$RC_QUEUE" ] \
   && [ -n "$RC_REJECTED" ]; then
  ok "(D8) the five refusal codes are READ from zuvo_backlog_prepass (unverified=$RC_UNVERIFIED scope=$RC_SCOPE partial=$RC_PARTIAL queue=$RC_QUEUE rejected=$RC_REJECTED), so renumbering one cannot leave an assertion passing against a stale literal"
else
  no "(D8) could not read the refusal codes from the module: $(cat "$FIX/codes.out" | tr '\n' ' ')"
  finish
fi

# ==================================================================================================
# A — SMOKE1. The whole pipeline on this repo's own backlog: verify (plan + fan-out + ingest) -> groom
# (apply) -> doc (render), then the invariants.
# ==================================================================================================
echo "-- A/SMOKE1: verify -> groom -> doc on the committed backlog --"

A_BL0="$(sha256f "$DOG_BL")"; A_AR0="$(sha256f "$DOG_AR")"
python3 "$CONS7" "$CTL" "$DOG_BL" "$DOG_AR" | sort >"$FIX/dog-cons-before.txt"

pipeline7 "$CTL" "$DOG" "$DOG_OUT" "$FIX/dog"
A_RC="$?"
grep -Ev '^(UNMINTABLE_ENTRY|IDLESS_HEADING|CHUNK)=' "$FIX/dog-plan.out" | head -24
A_CHUNKS="$(sed -n 's/^CHUNKS=\([0-9]*\).*/\1/p' "$FIX/dog-plan.out" | head -1)"
A_DET="$(iv7 "$FIX/dog-plan.out" DETERMINISTIC)"
A_REFUSED="$(iv7 "$FIX/dog-plan.out" REFUSED_EVIDENCE)"
if [ "$A_RC" -eq 0 ]; then
  ok "(A1) the verify lane completed every one of its $A_CHUNKS chunks: plan -> dispatch -> recorded response -> ingest, with no step refusing"
else
  no "(A1) the verify lane stopped with internal code $A_RC (10=plan 11=no CHUNKS line 20=dispatch 21=response 22=ingest); last ingest said: $(grep -h '^REJECT=' "$FIX"/dog-i*.out 2>/dev/null | head -3)"
fi
cat "$FIX/dog-summary"
[ "${A_CHUNKS:-0}" -gt 1 ] \
  && ok "(A2) the byte chunker really split the work ($A_CHUNKS chunks, cap $(sed -n 's/^CHUNKS=[0-9]* cap=\([0-9]*\).*/\1/p' "$FIX/dog-plan.out" | head -1) bytes) — a one-chunk fan-out would make the per-chunk conservation and seeding assertions a statement about one batch" \
  || no "(A2) the fan-out produced ${A_CHUNKS:-0} chunk(s); every per-chunk assertion below would be near-vacuous"
A_BADSEED="$(awk '$5 != "seeds=4"' "$FIX/dog-summary" | wc -l | tr -d ' ')"
[ "${A_BADSEED:-1}" -eq 0 ] \
  && ok "(A3) every one of the $A_CHUNKS chunks was gated by K=4 control-(d) seeds — a chunk dispatched with two seeds reads identically to a gated one in every report, which is the one failure that control cannot survive" \
  || no "(A3) $A_BADSEED chunk(s) carried a seed count other than 4: $(awk '$5 != "seeds=4"' "$FIX/dog-summary" | head -3 | tr '\n' ' ')"
A_BADREJ="$(awk '$7 != "rejects=0"' "$FIX/dog-summary" | wc -l | tr -d ' ')"
[ "${A_BADREJ:-1}" -eq 0 ] \
  && ok "(A4) and every chunk passed conservation and controls (a)-(d) with zero rejections, so the ledger below was built by the real orchestrator and not by a fixture writing rows directly" \
  || no "(A4) $A_BADREJ chunk(s) had rejections: $(awk '$7 != "rejects=0"' "$FIX/dog-summary" | head -3 | tr '\n' ' ')"
[ "${A_DET:-0}" -gt 0 ] && [ "${A_REFUSED:-1}" -eq 0 ] \
  && ok "(A5) the deterministic pre-pass decided $A_DET entries from the bytes and REFUSED 0 of its own evidence lines as unresolvable — $(grep '^DET_CLASS=' "$FIX/dog-plan.out" | tr '\n' ' ')" \
  || no "(A5) deterministic=${A_DET:-0} refused_evidence=${A_REFUSED:-?}; a refused evidence line means the pre-pass emitted a citation that does not resolve"

# ---- THE NEGATIVE CONTROL for A4, on the SAME chunk and the SAME dispatch ------------------------
# "every chunk passed with zero rejections" is a statement about the fixture until a response that
# SHOULD be rejected is shown to be. One record is dropped from chunk 0's otherwise-clean response —
# the shape conservation exists to catch, because a missing row is an agent FAILURE and never an
# implicit verdict — and the ledger is measured in BYTES across the attempt: "no row for that id"
# would also be true of a ledger that grew by the other 87.
A_DISP0="$DOG_OUT/context/backlog-dispatch-0.jsonl"
A_DROP="$(python3 -c "
import json,sys
print(json.loads(open(sys.argv[1],encoding='utf-8').readline())['keys'][0])
" "$A_DISP0" 2>/dev/null)"
A_LEDB0="$(wc -c <"$DOG_LED" 2>/dev/null | tr -d ' ')"
python3 "$RESP7" "$CTL" "$DOG" "$A_DISP0" "$DOG_OUT/context/backlog-answers-0.json" omit "$A_DROP" \
        >"$FIX/dog-resp-omit.jsonl" 2>"$FIX/dog-resp-omit.err"
G7 "$CTL" "$DOG" "$DOG_OUT" ingest --chunk 0 --dispatch "$A_DISP0" \
   --response "$FIX/dog-resp-omit.jsonl" >"$FIX/dog-ing-omit.out" 2>&1
A_OMITRC="$?"
A_LEDB1="$(wc -c <"$DOG_LED" 2>/dev/null | tr -d ' ')"
[ -n "$A_DROP" ] && [ "$A_OMITRC" -eq "$RC_REJECTED" ] && grep -q 'KEYSET' "$FIX/dog-ing-omit.out" \
  && ok "(A5b) the negative control fires: the same chunk with ONE record dropped ($A_DROP) is REFUSED with RC_REJECTED=$RC_REJECTED and a KEYSET rejection — so A4's zero-rejection run is a measurement of a live control and not of a dead one. $(grep -m1 '^REJECTS=' "$FIX/dog-ing-omit.out")" \
  || no "(A5b) the omitted-row response exited $A_OMITRC (RC_REJECTED=$RC_REJECTED) with rejections $(grep -m1 '^REJECTS=' "$FIX/dog-ing-omit.out"); dropped key was '${A_DROP:-<none>}' and the generator said: $(tail -1 "$FIX/dog-resp-omit.err")"
[ "${A_LEDB0:-0}" = "${A_LEDB1:-x}" ] \
  && ok "(A5c) …and it appended ZERO BYTES ($A_LEDB0 -> $A_LEDB1): never the clean half of a response that failed conservation, which is the whole reason conservation runs before the controls" \
  || no "(A5c) the ledger moved $A_LEDB0 -> $A_LEDB1 bytes on a response that failed conservation"

G7 "$CTL" "$DOG" "$DOG_OUT" coverage >"$FIX/dog-cov.out" 2>&1
A_COVRC="$?"
if [ "$A_COVRC" -eq 0 ] && [ ! -s "$FIX/dog-cov.out" ]; then
  ok "(A6) the non-blocking coverage count is SILENT on the groomed clone — every one of the $D_ENTRIES entries carries a text_sha-current verdict, by the same arithmetic apply refuses on"
else
  no "(A6) coverage rc=$A_COVRC and said: $(cat "$FIX/dog-cov.out" | tr '\n' ' ')"
fi

# THE REFUSAL THE DOGFOOD REALLY HITS, measured and reported rather than engineered away. `_decide`
# calls every status-done entry `archived`; `backlog-archive.py archive` indexes kinds=(KIND_CHECKBOX,)
# and gates headings — so on this file the two sets are the censused status-done count and the
# archiver's own, and the scope check REFUSES rather than delegating a whole-file archive that would
# close entries no verdict licensed.
G7 "$CTL" "$DOG" "$DOG_OUT" apply --dry-run >"$FIX/dog-apply.out" 2>&1
A_APPLYRC="$?"
grep -Ev '^DISPOSITION=' "$FIX/dog-apply.out" | tail -12
[ "$A_APPLYRC" -eq "$RC_SCOPE" ] \
  && ok "(A7) apply on the full selection REFUSES with RC_SCOPE=$RC_SCOPE, naming both sets: $(grep -o 'would move [0-9]* entries where [0-9]* carry a verdict' "$FIX/dog-apply.out" | head -1) — the safe direction, and the reason the closure half below runs on a stated sub-selection" \
  || no "(A7) apply --dry-run exited $A_APPLYRC where RC_SCOPE=$RC_SCOPE was owed; without that refusal a whole-file archive would close entries no verdict licensed"
[ "$(sha256f "$DOG_BL")" = "$A_BL0" ] && [ "$(sha256f "$DOG_AR")" = "$A_AR0" ] \
  && ok "(A8) …and it wrote zero bytes: both files are byte-identical across the refusal (sha256 before == after)" \
  || no "(A8) a refused apply changed a file: backlog $A_BL0 -> $(sha256f "$DOG_BL"), archive $A_AR0 -> $(sha256f "$DOG_AR")"
A_NOMINT="$(iv7 "$FIX/dog-plan.out" INSERTED_BYTES)"
[ "${A_NOMINT:-x}" = "0" ] \
  && ok "(A9) the open file also gained no minted id (INSERTED_BYTES=0, MINTABLE=$(iv7 "$FIX/dog-plan.out" MINTABLE) of MINT_SET=$(iv7 "$FIX/dog-plan.out" MINT_SET)) — so SMOKE1's 'differing only by minted ids' holds here in its degenerate form, because mint_into refuses the BULLET dialect by a pinned PR 1 contract and 0 of the set are reachable" \
  || no "(A9) the pre-pass inserted ${A_NOMINT:-?} bytes of minted id into a tracked file on this selection, which PR 1's pinned refusal says is impossible"

# ---- the DUPLICATE keys: disambiguated or reported, NEVER merged ----------------------------------
python3 "$DUPS7" "$CTL" "$DOG_BL" "$DOG_LED" >"$FIX/dog-dups.out" 2>&1
grep -v '^DUP=' "$FIX/dog-dups.out"
A_MISM="$(iv7 "$FIX/dog-dups.out" ROWS_PER_TEXT_MISMATCH)"
A_DUPE="$(sed -n 's/^DUP_ENTRIES=\([0-9]*\).*/\1/p' "$FIX/dog-dups.out" | head -1)"
A_DUPE_OK="$(sed -n 's/.*DUP_ENTRIES_WITH_EXACT_ROW=\([0-9]*\).*/\1/p' "$FIX/dog-dups.out" | head -1)"
A_DUPROWS="$(iv7 "$FIX/dog-dups.out" DUPLICATE_OF_ROWS)"
[ "${A_DUPE:-0}" -gt 0 ] && [ "${A_DUPE_OK:-0}" = "${A_DUPE:-0}" ] \
  && ok "(A10) all $A_DUPE duplicate-keyed entries survive the pipeline as SEPARATE entries, each resolving to its own exact-text_sha verdict row — nothing was merged, which is what backlog-protocol.md requires and what the option-A deferral measured a key-deduping rewriter destroying" \
  || no "(A10) ${A_DUPE_OK:-0} of ${A_DUPE:-0} duplicate-keyed entries resolve to an exact verdict row; the rest lost theirs to a collapse"
[ "${A_MISM:-1}" -eq 0 ] \
  && ok "(A11) …and the ledger holds exactly one row per DISTINCT text under each duplicate key, never one per key: _dedup collapses two judgements about one text, which is correct, and does not collapse two texts, which would be the merge" \
  || no "(A11) $A_MISM duplicate key(s) hold fewer rows than they have distinct entry texts — two different entries are sharing one verdict"
[ "${A_DUPROWS:-0}" -gt 0 ] \
  && ok "(A12) the duplicate class emitted $A_DUPROWS DUPLICATE-OF row(s), so A10/A11 have a subject rather than being true of an empty set" \
  || no "(A12) no DUPLICATE-OF row exists in the ledger, so A10/A11 are vacuous on this fixture"
A_DUPDISP="$(grep '^DISPOSITION=' "$FIX/dog-apply.out" | awk -F'|' '$2=="no-remedy" && $3=="-"' | wc -l | tr -d ' ')"
A_DUPBAD="$(grep '^DISPOSITION=' "$FIX/dog-apply.out" | awk -F'|' '$4 ~ /DUPLICATE-OF is a REPORT/ && $2 != "no-remedy"' | wc -l | tr -d ' ')"
[ "${A_DUPBAD:-1}" -eq 0 ] && [ "${A_DUPDISP:-0}" -gt 0 ] \
  && ok "(A13) and not one DUPLICATE-OF verdict licensed a performable action: $A_DUPDISP no-remedy dispositions with an empty verb, 0 with drop-stale or archive — a report, never a licence to merge" \
  || no "(A13) ${A_DUPBAD:-?} DUPLICATE-OF disposition(s) carried a performable verb, or none was emitted at all (${A_DUPDISP:-0} no-remedy rows)"
echo "  NOTE (reported, gates nothing): SMOKE1 says the duplicates are 'disambiguated by minting distinct ids'. Measured on this selection, $(sed -n 's/.*DUP_ENTRIES_IN_MINT_SET=\([0-9]*\).*/\1/p' "$FIX/dog-dups.out" | head -1) of them are in the mint set and $(sed -n 's/.*DUP_ENTRIES_MINTABLE=\([0-9]*\).*/\1/p' "$FIX/dog-dups.out" | head -1) are mintable, because mint_into refuses the BULLET dialect. They are therefore REPORTED as DUPLICATE-OF and left as two entries — which is the outcome the protocol wants, reached by a different route than the plan's prose describes."

# ---- doc: the working document, on a FULLY verified ledger, no --partial needed -------------------
G7 "$CTL" "$DOG" "$DOG_OUT" render >"$FIX/dog-render.out" 2>&1
A_RENRC="$?"
grep -E '^(ENTRIES|VERIFIED|CLUSTERS|RANKING|NOT_VERIFIABLE|RENDERED|REPORT|REPORT_BYTES)=' "$FIX/dog-render.out"
A_DOC="$(iv7 "$FIX/dog-render.out" REPORT)"
if [ "$A_RENRC" -eq 0 ] && [ -s "$A_DOC" ]; then
  ok "(A14) doc rendered without --partial, which it could only do because coverage is complete: $(sed -n 's/^RENDERED=\([0-9]*\).*/\1/p' "$FIX/dog-render.out" | head -1) entries, $(iv7 "$FIX/dog-render.out" CLUSTERS) clusters, ranking=$(iv7 "$FIX/dog-render.out" RANKING), $(iv7 "$FIX/dog-render.out" REPORT_BYTES) bytes"
else
  no "(A14) render exited $A_RENRC and left no document at ${A_DOC:-<none>}: $(tail -3 "$FIX/dog-render.out")"
fi
A_DOCSHA="$(sed -n 's/^source_sha256: //p' "$A_DOC" 2>/dev/null | head -1)"
[ -n "$A_DOCSHA" ] && [ "$A_DOCSHA" = "$(sha256f "$DOG_BL")" ] \
  && ok "(A15) its provenance header's source_sha256 equals the source file's sha256 ($A_DOCSHA) — decision 12's 'a reader must be able to tell whether the document still describes the file', checkable from the document alone" \
  || no "(A15) the document says source_sha256=${A_DOCSHA:-<none>} where the file hashes to $(sha256f "$DOG_BL")"
grep -q '^## Not verifiable' "$A_DOC" 2>/dev/null \
  && ok "(A16) the document carries the explicit Not-verifiable section ($(iv7 "$FIX/dog-render.out" NOT_VERIFIABLE) entries) rather than silently omitting those rows — and on this run that section holds the fixture-fed rows, which is exactly why it must be explicit" \
  || no "(A16) the document has no Not-verifiable section, so unverifiable entries are silently absent"
grep -q '^## Ranking' "$A_DOC" 2>/dev/null \
  && ok "(A17) …and the Ranking section IS present, because the set is fully verified; decision 11 omits it only under --partial, and SMOKE2 below asserts that half" \
  || no "(A17) the ranking section is missing from a fully verified render"

# ---- the archiver's own answers, on the groomed clone ---------------------------------------------
A7 "$CTL" "$DOG" verify >"$FIX/dog-verify.out" 2>&1
A_VRC="$?"
head -2 "$FIX/dog-verify.out"
[ "$A_VRC" -eq 0 ] && grep -q '^OK disjoint' "$FIX/dog-verify.out" \
  && ok "(A18) backlog-archive.py verify reports OK disjoint — no id is defined in both files: $(head -1 "$FIX/dog-verify.out")" \
  || no "(A18) verify exited $A_VRC: $(head -2 "$FIX/dog-verify.out" | tr '\n' ' ')"
# `status` ANSWERS on 10/11/12 — those codes are its vocabulary, not failures (the refusal registry is
# deliberately disjoint from them for exactly this reason), so neither assertion gates on rc=0.
A7 "$CTL" "$DOG" status >"$FIX/dog-status.out" 2>&1
A_SRC="$?"
head -2 "$FIX/dog-status.out"
[ -s "$FIX/dog-status.out" ] && ! grep -q 'nothing resolved left' "$FIX/dog-status.out" \
  && ok "(A19) status does NOT print the false 'nothing resolved left' — with the heading gate on it answers rc=$A_SRC and names what is outstanding: $(sed -n 's/^OVERDUE [^:]*: //p' "$FIX/dog-status.out" | head -1 | cut -c1-120)" \
  || no "(A19) status exited $A_SRC saying: $(head -2 "$FIX/dog-status.out" | tr '\n' ' ') — SMOKE1 asks specifically that the false 'nothing resolved left' be gone"
# The SAME command without the gate, to show what decides the answer. PR 1's decision 6 gates heading
# archival because archiving a heading MOVES LINES, so with the gate off the archiver indexes
# kinds=(KIND_CHECKBOX,) only — and this backlog has no ticked checkbox at all.
python3 "$CTL/backlog-archive.py" status --repo "$DOG" >"$FIX/dog-status-nogate.out" 2>&1
A_SRC2="$?"
head -1 "$FIX/dog-status-nogate.out"
[ "$A_SRC2" -ne "$A_SRC" ] && grep -q 'nothing resolved left' "$FIX/dog-status-nogate.out" \
  && ok "(A19b) …and the gate is what decides it: without ZUVO_BACKLOG_HEADING_ARCHIVE the same command answers rc=$A_SRC2 'nothing resolved left', because it then indexes the CHECKBOX dialect only and this selection has $(sed -n 's/.*STATUS_DONE_BY_KIND=//p' "$FIX/census-dog.out" | head -1) — that pair is the honest form of SMOKE1's claim, and reading either line alone misstates it" \
  || no "(A19b) with the heading gate off, status answered rc=$A_SRC2: $(head -1 "$FIX/dog-status-nogate.out") — the two answers were expected to differ"

# ---- lookup resolves a sample of heading ids ------------------------------------------------------
grep '^HEADING_ID=' "$FIX/census-dog.out" | sed 's/^HEADING_ID=//' | head -10 >"$FIX/dog-headids.txt"
A_NID="$(awk 'END{print NR}' "$FIX/dog-headids.txt")"
A_HIT=0
while IFS= read -r hid; do
  python3 "$CTL/backlog-archive.py" lookup "$hid" --repo "$DOG" >"$FIX/dog-lookup.out" 2>&1
  if grep -qE '^(OPEN|ARCHIVED) ' "$FIX/dog-lookup.out"; then A_HIT=$((A_HIT+1)); else echo "  MISS $hid :: $(tail -1 "$FIX/dog-lookup.out")"; fi
done < "$FIX/dog-headids.txt"
[ "${A_NID:-0}" -ge 10 ] && [ "$A_HIT" -eq "$A_NID" ] \
  && ok "(A20) lookup resolves all $A_HIT of a $A_NID-id sample of HEADING ids (PR 1's whole point: the heading entries are findable) — note the answer rides on exit code 10/11/12, which is why this gates on the OPEN/ARCHIVED line and not on rc=0" \
  || no "(A20) lookup resolved $A_HIT of ${A_NID:-0} sampled heading ids; SMOKE1 asks for a sample of 10 and $D_HEADIDS exist"

# ---- the closure the scope check refused, performed by the helper it would have delegated to -------
# SMOKE1's invariant is ENTRY-LEVEL conservation keyed on `text_sha` across the move. On the full
# selection `apply` refuses (A7), so the move is performed by `backlog-archive.py archive` ALONE — the
# same binary `perform` would have exec'd, with the same heading gate — on a SECOND clone, so the first
# one's post-refusal state stays available for inspection.
echo "-- A/SMOKE1: the move itself, and entry-level conservation over the real file --"
DOGC="$FIX/dogfood-closure"
if mkclone "$DOGC" ""; then
  ok "(A21) a second clone of the same selection carries the closure half, so the refused-apply state above is not disturbed by it"
else
  no "(A21) could not build the closure clone"
fi
DOGC_BL="$DOGC/memory/backlog.md"; DOGC_AR="$DOGC/memory/backlog-done.md"
python3 "$CONS7" "$CTL" "$DOGC_BL" "$DOGC_AR" | sort >"$FIX/dogc-before.txt"
A7 "$CTL" "$DOGC" archive >"$FIX/dogc-archive.out" 2>&1
A_ARCRC="$?"
head -2 "$FIX/dogc-archive.out"
A_MOVED="$(sed -n 's/^moved \([0-9]*\) entries.*/\1/p' "$FIX/dogc-archive.out" | head -1)"
[ "$A_ARCRC" -eq 0 ] && [ "${A_MOVED:-0}" -gt 0 ] \
  && ok "(A22) the helper moved $A_MOVED resolved entries out of the open file ($(head -1 "$FIX/dogc-archive.out" | sed 's/.*(\(.*\))/\1/')) — a non-zero move count is what gives the conservation check below a subject, and Task 4's write-discipline group is the precedent for why that floor is asserted" \
  || no "(A22) the helper exited $A_ARCRC having moved ${A_MOVED:-0} entries: $(tail -2 "$FIX/dogc-archive.out" | tr '\n' ' ')"
python3 "$CONS7" "$CTL" "$DOGC_BL" "$DOGC_AR" | sort >"$FIX/dogc-after.txt"
awk '{print $2}' "$FIX/dogc-before.txt" | sort >"$FIX/dogc-shas-before.txt"
awk '{print $2}' "$FIX/dogc-after.txt" | sort >"$FIX/dogc-shas-after.txt"
A_NB="$(awk 'END{print NR}' "$FIX/dogc-shas-before.txt")"
A_NA="$(awk 'END{print NR}' "$FIX/dogc-shas-after.txt")"
if diff -q "$FIX/dogc-shas-before.txt" "$FIX/dogc-shas-after.txt" >/dev/null 2>&1; then
  ok "(A23) ENTRY-LEVEL CONSERVATION HOLDS: the text_sha MULTISET over (open + archived) is identical before and after — $A_NB entries before, $A_NA after. open_before + archived_before == open_after + archived_after, keyed on content and not on lines or counts, because A25's own comment records that a line count and an occurrence count both stay green through a boundary error"
else
  no "(A23) conservation BROKE: $(diff "$FIX/dogc-shas-before.txt" "$FIX/dogc-shas-after.txt" | grep -c '^[<>]') text_sha(s) differ between before and after — $(diff "$FIX/dogc-shas-before.txt" "$FIX/dogc-shas-after.txt" | head -4 | tr '\n' ' ')"
fi
A_OPEN_LOST="$(comm -23 <(awk '$1=="OPEN"{print $2}' "$FIX/dogc-before.txt" | sort) <(awk '{print $2}' "$FIX/dogc-after.txt" | sort) | awk 'END{print NR}')"
[ "${A_OPEN_LOST:-1}" -eq 0 ] \
  && ok "(A24) and every entry that was OPEN before is still present afterwards in one of the two files — their blocks moved whole and their siblings were not taken with them, which is the half a count-only check cannot express" \
  || no "(A24) $A_OPEN_LOST entry text(s) that were open before the move are in neither file afterwards"
A_MOVED_SET="$(comm -12 <(awk '$1=="OPEN"{print $2}' "$FIX/dogc-before.txt" | sort) <(awk '$1=="ARCH"{print $2}' "$FIX/dogc-after.txt" | sort) | awk 'END{print NR}')"
[ "${A_MOVED_SET:-0}" -gt 0 ] && [ "${A_MOVED_SET:-0}" -ge "${A_MOVED:-1}" ] \
  && ok "(A25) the move is ATTRIBUTABLE, not just balanced: $A_MOVED_SET entry texts that were in the open file are now in the archive, so the multiset equality above is not two unrelated sets that happen to be the same size. The helper reported $A_MOVED and this says $A_MOVED_SET, and BOTH are right: its count is of RESOLVED entries, while a heading entry's block deliberately CONTAINS its children, so archiving one heading carries every entry inside it. That gap is precisely why conservation has to be entry-level — a count-only check comparing $A_MOVED with $A_MOVED_SET would read as a defect, and a line count would hide a real one" \
  || no "(A25) no entry text moved from OPEN to ARCH, so A23's multiset equality says nothing about a move"
A7 "$CTL" "$DOGC" verify >"$FIX/dogc-verify.out" 2>&1
[ "$?" -eq 0 ] && grep -q '^OK disjoint' "$FIX/dogc-verify.out" \
  && ok "(A26) after the move the two files are still disjoint: $(head -1 "$FIX/dogc-verify.out")" \
  || no "(A26) verify after the move: $(head -2 "$FIX/dogc-verify.out" | tr '\n' ' ')"

# ==================================================================================================
# B/C — the SUB-SELECTION on which `apply` itself can perform the closures, and SMOKE2 on top of it.
#
# WHY A SUB-SELECTION AND WHAT IT IS. A7 measured the reason: `_decide` calls every status-done entry
# `archived`, while `backlog-archive.py` indexes kinds=(KIND_CHECKBOX,) and gates the heading dialect —
# so a BULLET entry carrying a resolution marker is one `apply` intends to archive and the helper
# structurally cannot move. `reduce7.py` removes exactly those, plus the OPEN twin of any double-duty
# id, and PRINTS every line it took. Nothing else differs from the committed selection.
# ==================================================================================================
echo "-- B/C: the sub-selection where apply performs, and SMOKE2's refusals --"

python3 "$REDUCE7" "$CTL" "$DOG_BL" "$FIX/reduced-backlog.md" >"$FIX/reduce.out" 2>&1
B_RRC="$?"
grep -v '^REDUCE_DROP=' "$FIX/reduce.out"
B_BEFORE="$(sed -n 's/^REDUCE_BEFORE=\([0-9]*\).*/\1/p' "$FIX/reduce.out" | head -1)"
B_AFTER="$(sed -n 's/.*REDUCE_AFTER=\([0-9]*\).*/\1/p' "$FIX/reduce.out" | head -1)"
B_DROPPED="$(sed -n 's/.*REDUCE_DROPPED=\([0-9]*\).*/\1/p' "$FIX/reduce.out" | head -1)"
if [ "$B_RRC" -eq 0 ] && [ "${B_AFTER:-0}" -gt 100 ] && [ "${B_DROPPED:-0}" -gt 0 ]; then
  ok "(B0) the sub-selection is DERIVED and printed: $B_BEFORE entries in, $B_AFTER out, $B_DROPPED removed by the two named reasons ($(grep -c 'REDUCE_DROP=unmovable-dialect' "$FIX/reduce.out") unmovable-dialect, $(grep -c 'REDUCE_DROP=double-duty-id' "$FIX/reduce.out") double-duty-id) — a selection nobody can list is a selection nobody can check"
else
  no "(B0) the reduction exited $B_RRC leaving ${B_AFTER:-0} entries and dropping ${B_DROPPED:-0}: $(tail -3 "$FIX/reduce.out")"
  finish
fi
E2E="$FIX/e2e"
if mkclone "$E2E" "$FIX/reduced-backlog.md"; then
  ok "(B1) the sub-selection is installed in its own temp clone"
else
  no "(B1) could not build the sub-selection clone"
  finish
fi
E2E_OUT="$FIX/e2e-zuvo"
E2E_BL="$E2E/memory/backlog.md"; E2E_AR="$E2E/memory/backlog-done.md"
E2E_LED="$E2E/memory/backlog-verdicts.jsonl"

pipeline7 "$CTL" "$E2E" "$E2E_OUT" "$FIX/e2e"
B_PRC="$?"
B_ENTRIES="$(iv7 "$FIX/e2e-plan.out" ENTRIES)"
B_CHUNKS="$(sed -n 's/^CHUNKS=\([0-9]*\).*/\1/p' "$FIX/e2e-plan.out" | head -1)"
[ "$B_PRC" -eq 0 ] \
  && ok "(B2) the verify lane completed on the sub-selection too: $B_ENTRIES entries over $B_CHUNKS chunks, $(iv7 "$FIX/e2e-plan.out" DETERMINISTIC) decided deterministically" \
  || no "(B2) the verify lane stopped with internal code $B_PRC on the sub-selection"
[ "${B_ENTRIES:-0}" = "${B_AFTER:-x}" ] \
  && ok "(B3) …and the pre-pass counts exactly the $B_AFTER entries the reduction said it left, so the sub-selection is the file the pipeline actually ran on" \
  || no "(B3) the reduction left $B_AFTER entries and the pre-pass sees ${B_ENTRIES:-0}"
cp "$E2E_LED" "$FIX/e2e-ledger-full.jsonl"
B_LEDSHA="$(sha256f "$FIX/e2e-ledger-full.jsonl")"

# ---- SMOKE2, step 1: ONE verdict deleted. Both gates must refuse, NAMING that id. ------------------
C_VICTIM="$(python3 -c "
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1],encoding='utf-8') if l.strip()]
print(next((r['id'] for r in rows if not str(r['id']).startswith('fp:')), rows[0]['id'] if rows else ''))
" "$FIX/e2e-ledger-full.jsonl")"
if [ -n "$C_VICTIM" ]; then
  ok "(C0) SMOKE2's subject is a NAMED entry id, not an fp: content key: $C_VICTIM — the refusals below have to print it, and an fp: key would make 'the id is named' unreadable"
else
  no "(C0) could not choose a victim id from the complete ledger"
  finish
fi
python3 "$SHORT7" "$FIX/e2e-ledger-full.jsonl" "$E2E_LED" "$C_VICTIM" >"$FIX/short.out" 2>&1
C_BL0="$(sha256f "$E2E_BL")"; C_AR0="$(sha256f "$E2E_AR")"
G7 "$CTL" "$E2E" "$E2E_OUT" apply >"$FIX/c-apply.out" 2>&1
C_ARC="$?"
grep -E '^(VERIFIED|UNVERIFIED)=' "$FIX/c-apply.out"
grep -o 'refusing to apply[^.]*\.' "$FIX/c-apply.out" | head -1
[ "$C_ARC" -eq "$RC_UNVERIFIED" ] \
  && ok "(C1/SMOKE2) groom REFUSES on the incomplete ledger with RC_UNVERIFIED=$RC_UNVERIFIED — decision 10's mechanical form of 'wszystkie ma najpierw zweryfikować', and a code outside {0,1,2,10,11,12} so it cannot read as one of the archiver's lookup/status answers" \
  || no "(C1/SMOKE2) apply exited $C_ARC where RC_UNVERIFIED=$RC_UNVERIFIED was owed"
C_NAMED="$(grep -c "^UNVERIFIED=$C_VICTIM\$" "$FIX/c-apply.out")"
C_NSHORT="$(grep -c '^UNVERIFIED=' "$FIX/c-apply.out")"
[ "${C_NAMED:-0}" -ge 1 ] && [ "${C_NSHORT:-0}" -eq 1 ] \
  && ok "(C2/SMOKE2) …and it names the shortfall by id: exactly one UNVERIFIED= line, and it is $C_VICTIM. 'N-1 of N' sends a reader back to a 265 KB file to diff two lists by hand, which is how a refusal stops being acted on" \
  || no "(C2/SMOKE2) the refusal printed ${C_NSHORT:-0} UNVERIFIED= line(s) and ${C_NAMED:-0} of them named $C_VICTIM"
[ "$(sha256f "$E2E_BL")" = "$C_BL0" ] && [ "$(sha256f "$E2E_AR")" = "$C_AR0" ] \
  && ok "(C3/SMOKE2) the refusal wrote zero bytes to either backlog file" \
  || no "(C3/SMOKE2) the refused apply changed a file"
G7 "$CTL" "$E2E" "$E2E_OUT" render >"$FIX/c-render.out" 2>&1
C_RRC="$?"
grep -E '^(VERIFIED|UNVERIFIED)=' "$FIX/c-render.out"
[ "$C_RRC" -eq "$RC_PARTIAL" ] && grep -q "^UNVERIFIED=$C_VICTIM\$" "$FIX/c-render.out" \
  && ok "(C4/SMOKE2) doc REFUSES without --partial, with its OWN code RC_PARTIAL=$RC_PARTIAL and the same id named — 'verify the rest' and 'pass --partial' are different remedies, so an operator who greps an exit code gets one answer" \
  || no "(C4/SMOKE2) render exited $C_RRC where RC_PARTIAL=$RC_PARTIAL was owed, or did not name $C_VICTIM"
G7 "$CTL" "$E2E" "$FIX/c-partial-zuvo" render --partial >"$FIX/c-partial.out" 2>&1
C_PRC="$?"
C_PDOC="$(iv7 "$FIX/c-partial.out" REPORT)"
if [ "$C_PRC" -eq 0 ] && [ -s "$C_PDOC" ]; then
  ok "(C5/SMOKE2) --partial renders ($(iv7 "$FIX/c-partial.out" VERIFIED) covered, ranking=$(iv7 "$FIX/c-partial.out" RANKING))"
else
  no "(C5/SMOKE2) render --partial exited $C_PRC with no document at ${C_PDOC:-<none>}"
fi
if ! grep -q '^## Ranking' "$C_PDOC" 2>/dev/null; then
  ok "(C6/SMOKE2) …and it OMITS the ranking section while stamping the coverage ratio into the header ($(grep -m1 '^coverage: ' "$C_PDOC")) — decision 11, which revision 1's 'clearly labelled' render had silently deviated from"
else
  no "(C6/SMOKE2) a --partial render emitted a Ranking section, so the label is doing the work the omission was supposed to"
fi
# Asserted on the DOCUMENT and not on stdout: `gate_or_refuse` returns before printing UNVERIFIED= when
# --partial is passed, and the claim is about what a reader of the document alone can tell.
grep -q '^## Unverified' "$C_PDOC" 2>/dev/null && grep -q -- "- \`$C_VICTIM\`" "$C_PDOC" 2>/dev/null \
  && ok "(C7/SMOKE2) the unrendered entry is NAMED in the document's own Unverified section — naming it is not rendering it, and leaving it out would make the document silently describe a subset of the file it claims to be about" \
  || no "(C7/SMOKE2) the --partial document does not name $C_VICTIM under an Unverified section: $(grep -c '^## Unverified' "$C_PDOC" 2>/dev/null) section(s), $(grep -c "$C_VICTIM" "$C_PDOC" 2>/dev/null) mention(s)"

# ---- SMOKE2, step 2: restore the verdict; the second pass costs ZERO dispatches --------------------
cp "$FIX/e2e-ledger-full.jsonl" "$E2E_LED"
[ "$(sha256f "$E2E_LED")" = "$B_LEDSHA" ] \
  && ok "(C8/SMOKE2) the ledger is restored byte-identically ($B_LEDSHA), so the resume below is measured against the same rows the first pass wrote and not against a rebuilt file" \
  || no "(C8/SMOKE2) the restored ledger does not match the snapshot"
G7 "$CTL" "$E2E" "$E2E_OUT" plan --dry-run >"$FIX/c-replan.out" 2>&1
C_REPRC="$?"
grep -E '^(ENTRIES|REUSED|CHUNKS|LEDGER_DEFECTS)=' "$FIX/c-replan.out"
C_REUSED="$(iv7 "$FIX/c-replan.out" REUSED)"
C_RECH="$(sed -n 's/^CHUNKS=\([0-9]*\).*/\1/p' "$FIX/c-replan.out" | head -1)"
C_ORPH="$(grep -c '^ORPHAN=' "$FIX/c-replan.out")"
[ "$C_REPRC" -eq 0 ] && [ "${C_REUSED:-0}" = "${B_ENTRIES:-x}" ] \
  && ok "(C9/SMOKE2) the second verify REUSES all $C_REUSED of $B_ENTRIES verdicts free — key resolves AND text_sha matches, which is decision 4's reuse bucket and the property that makes mandatory whole-set verification affordable at all" \
  || no "(C9/SMOKE2) the re-plan reused ${C_REUSED:-0} of ${B_ENTRIES:-?} verdicts (rc=$C_REPRC)"
[ "${C_RECH:-1}" -eq 0 ] \
  && ok "(C10/SMOKE2) …so the fan-out is EMPTY: CHUNKS=0, down from $B_CHUNKS on the first pass. ZERO rows are handed to a verifier on the resume" \
  || no "(C10/SMOKE2) the second pass still assigned ${C_RECH:-?} chunk(s), so the resume re-dispatches work the ledger already answered"
[ "${C_ORPH:-1}" -eq 0 ] \
  && ok "(C11/SMOKE2) and no ledger row is orphaned: every verdict's key still resolves to an entry, so none of them was quietly re-spent" \
  || no "(C11/SMOKE2) $C_ORPH orphan verdict(s) on the resume: $(grep -m1 '^ORPHAN=' "$FIX/c-replan.out")"
# The mechanical proof that zero dispatch means zero dispatch: with the queue written from the resumed
# plan, asking for chunk 0 is a REFUSAL rather than an empty pass.
G7 "$CTL" "$E2E" "$E2E_OUT" plan >"$FIX/c-replan-write.out" 2>&1
G7 "$CTL" "$E2E" "$E2E_OUT" dispatch --chunk 0 >"$FIX/c-redispatch.out" 2>&1
C_DRC="$?"
[ "$C_DRC" -eq "$RC_QUEUE" ] && grep -q '^CHUNK=0 rows=0' "$FIX/c-redispatch.out" \
  && ok "(C12/SMOKE2) dispatching chunk 0 after the resume REFUSES with RC_QUEUE=$RC_QUEUE on rows=0 — a run over an empty chunk would otherwise report a clean pass, which is the shape 'zero dispatches' must not be allowed to take" \
  || no "(C12/SMOKE2) dispatch --chunk 0 exited $C_DRC on the resumed queue: $(tail -2 "$FIX/c-redispatch.out" | tr '\n' ' ')"

# ---- SMOKE2, step 3 / SMOKE1's closure through `apply`: then groom SUCCEEDS ------------------------
python3 "$CONS7" "$CTL" "$E2E_BL" "$E2E_AR" | sort >"$FIX/e2e-before.txt"
B_BL0="$(sha256f "$E2E_BL")"
G7 "$CTL" "$E2E" "$E2E_OUT" apply >"$FIX/b-apply.out" 2>&1
B_ARC="$?"
grep -Ev '^DISPOSITION=' "$FIX/b-apply.out" | tail -14
[ "$B_ARC" -eq 0 ] \
  && ok "(C13/SMOKE2) with every verdict back, groom SUCCEEDS (rc=0) — the same command that refused twice above, on the same files, with one ledger row restored. $(grep -m1 '^VERIFIED=' "$FIX/b-apply.out") verified, dispositions: $(grep '^DISPOSED=' "$FIX/b-apply.out" | tr '\n' ' ')" \
  || no "(C13/SMOKE2) apply exited $B_ARC on the complete ledger: $(tail -3 "$FIX/b-apply.out" | tr '\n' ' ')"
B_HELPER="$(grep -c '^HELPER=' "$FIX/b-apply.out")"
B_MOVED="$(sed -n 's/^HELPER=moved \([0-9]*\) entries.*/\1/p' "$FIX/b-apply.out" | head -1)"
[ "${B_HELPER:-0}" -gt 0 ] && [ "${B_MOVED:-0}" -gt 0 ] \
  && ok "(B4/SMOKE1) and the closures were DELEGATED, not written here: $B_MOVED entries moved by backlog-archive.py as a subprocess, reported on $B_HELPER HELPER= lines. backlog-protocol.md records what the hand-written alternative did — it counted LINES as items, '106 completed items' for three entries, and destroyed quoted open copies" \
  || no "(B4/SMOKE1) apply succeeded with ${B_HELPER:-0} helper line(s) and ${B_MOVED:-0} entries moved, so the delegation has no subject"
B_HINTS="$(sed -n 's/^ORDER_HINTS=.*applied=\([0-9]*\)/\1/p' "$FIX/b-apply.out" | head -1)"
[ "${B_HINTS:-1}" = "0" ] \
  && ok "(B5/SMOKE1) nothing was reordered: $(grep -m1 '^ORDER_HINTS=' "$FIX/b-apply.out") — decision 7 keeps ordering in the ledger and the document, because option A's correctness has no oracle until the per-entry text_sha this PR creates exists" \
  || no "(B5/SMOKE1) apply reported applying an order hint to the open file"
python3 "$CONS7" "$CTL" "$E2E_BL" "$E2E_AR" | sort >"$FIX/e2e-after.txt"
awk '{print $2}' "$FIX/e2e-before.txt" | sort >"$FIX/e2e-shas-before.txt"
awk '{print $2}' "$FIX/e2e-after.txt" | sort >"$FIX/e2e-shas-after.txt"
B_NB="$(awk 'END{print NR}' "$FIX/e2e-shas-before.txt")"
B_NA="$(awk 'END{print NR}' "$FIX/e2e-shas-after.txt")"
B_FROMOPEN="$(comm -12 <(awk '$1=="OPEN"{print $2}' "$FIX/e2e-before.txt" | sort) <(awk '$1=="ARCH"{print $2}' "$FIX/e2e-after.txt" | sort) | awk 'END{print NR}')"
if diff -q "$FIX/e2e-shas-before.txt" "$FIX/e2e-shas-after.txt" >/dev/null 2>&1; then
  ok "(B6/SMOKE1) ENTRY-LEVEL CONSERVATION HOLDS ACROSS apply ITSELF: open_before + archived_before == open_after + archived_after as a text_sha MULTISET ($B_NB == $B_NA), while $B_FROMOPEN entry texts crossed from the open file into the archive — $B_MOVED of them RESOLVED, the rest children of an archived heading, whose block contains them by design. A line-level or count-only check passes mis-attribution, which is exactly the defect PR 1's refuse_foreign_entries exists to catch"
else
  no "(B6/SMOKE1) conservation BROKE across apply: $(diff "$FIX/e2e-shas-before.txt" "$FIX/e2e-shas-after.txt" | grep -c '^[<>]') text_sha(s) differ — $(diff "$FIX/e2e-shas-before.txt" "$FIX/e2e-shas-after.txt" | head -4 | tr '\n' ' ')"
fi
[ "${B_FROMOPEN:-0}" -gt 0 ] \
  && ok "(B7/SMOKE1) …and that crossing is why B6 is not two unrelated sets of equal size: the archive gained exactly the entry texts the open file lost" \
  || no "(B7/SMOKE1) no entry text crossed from open to archive, so B6's equality says nothing about the move"
[ "$(sha256f "$E2E_BL")" != "$B_BL0" ] \
  && ok "(B8/SMOKE1) the open file DID change (sha256 moved) — AC8's two halves cannot both hold on a run that performs a closure, which is what revision 9 split: apply writes nothing itself, and the helper it delegates to rewrites both files" \
  || no "(B8/SMOKE1) the open file is byte-identical after a run that moved $B_MOVED entries out of it, so either the move or the hash is wrong"
G7 "$CTL" "$E2E" "$E2E_OUT" render >"$FIX/b-render.out" 2>&1
B_RRC2="$?"
B_DOC2="$(iv7 "$FIX/b-render.out" REPORT)"
[ "$B_RRC2" -eq 0 ] && [ "$(sed -n 's/^source_sha256: //p' "$B_DOC2" 2>/dev/null | head -1)" = "$(sha256f "$E2E_BL")" ] \
  && ok "(B9/SMOKE1) doc re-renders after the closures and its provenance sha tracks the NEW source bytes — so the verify -> groom -> doc chain closes, and the document cannot be mistaken for one describing the pre-closure file" \
  || no "(B9/SMOKE1) render after apply exited $B_RRC2 with source_sha256=$(sed -n 's/^source_sha256: //p' "$B_DOC2" 2>/dev/null | head -1) against a file hashing to $(sha256f "$E2E_BL")"
A7 "$CTL" "$E2E" verify >"$FIX/b-verify.out" 2>&1
[ "$?" -eq 0 ] && grep -q '^OK disjoint' "$FIX/b-verify.out" \
  && ok "(B10/SMOKE1) and the two files are disjoint afterwards: $(head -1 "$FIX/b-verify.out")" \
  || no "(B10/SMOKE1) verify after apply: $(head -2 "$FIX/b-verify.out" | tr '\n' ' ')"

# ==================================================================================================
# R — THE RED, against the REAL pre-refusal trees rather than against a mutant standing in for them.
#
# Task 7's RED is "the refusal half fails before Task 4 and passes after". That is a claim about
# HISTORY, so it is checked against history: `git archive <commit> scripts/zuvo-home` gives the actual
# module set as it shipped, and the same fixture is driven through both.
#
# THE BRIEF NAMED THE WRONG COMMIT, and it matters, because the wrong one makes the RED pass on both
# sides. It said "53bbe684's parent for the apply gate"; 53bbe684 is revision 9, a PLAN commit whose
# parent is 6b833d3d — the commit that INTRODUCES the apply gate. Derived here instead:
#   RC_UNVERIFIED (apply's coverage gate) lands in the commit that adds `cmd_apply`; its parent is the
#   pre-refusal tree. RC_PARTIAL (render's gate) lands in the commit that adds `cmd_render`.
# Both parents are resolved from the tree by searching for the first commit that defines the function,
# so a rebase cannot leave this group asserting against a stale sha.
# ==================================================================================================
echo "-- R: the RED, against the real pre-refusal trees --"

# THE SHORT-LEDGER CLONE, built unconditionally: group R needs it and so do three of the mutants, and a
# fixture that exists only on one branch of an `if` is a fixture `set -u` turns into an abort.
RED="$FIX/red"
if mkclone "$RED" "$FIX/reduced-backlog.md"; then
  ok "(R1) the short-ledger fixture is its own clone of the sub-selection, so group R and the mutants are order-independent"
else
  no "(R1) could not build the short-ledger clone"
  finish
fi
RED_OUT="$FIX/red-zuvo"
# The same complete ledger the pipeline built, minus the same one row: the RED is about the CODE, so the
# data on both sides has to be identical.
cp "$FIX/e2e-ledger-full.jsonl" "$RED/memory/backlog-verdicts.jsonl"
python3 "$SHORT7" "$FIX/e2e-ledger-full.jsonl" "$RED/memory/backlog-verdicts.jsonl" "$C_VICTIM" >/dev/null 2>&1

R_RAN=0
R_APPLY_AT=""; R_RENDER_AT=""; R_PRE_APPLY=""; R_PRE_RENDER=""
R_A_PRE="n/a"; R_A_NOW="n/a"; R_R_PRE="n/a"; R_R_NOW="n/a"
if [ "$HAVE_GIT" -eq 0 ]; then
  echo "  NOTE (R) NOT EXERCISED HERE: this environment has no git history, so there is no pre-refusal"
  echo "  NOTE (R) tree to run against. Nothing is asserted and nothing is claimed — a PASS printed here"
  echo "  NOTE (R) would be the vacuous kind this file's header forbids. Run this child from a checkout"
  echo "  NOTE (R) with history (any dev machine) to exercise it; the recorded run is in the SMOKE2 artifact."
fi
if [ "$HAVE_GIT" -eq 1 ]; then
R_APPLY_AT="$(git -C "$ROOT" log --format=%H --reverse -S'def cmd_apply' -- scripts/zuvo-home/backlog-groom.py | head -1)"
R_RENDER_AT="$(git -C "$ROOT" log --format=%H --reverse -S'def cmd_render' -- scripts/zuvo-home/backlog-groom.py | head -1)"
R_PRE_APPLY=""; R_PRE_RENDER=""
[ -n "$R_APPLY_AT" ] && R_PRE_APPLY="$(git -C "$ROOT" rev-parse --verify -q "$R_APPLY_AT^" 2>/dev/null)"
[ -n "$R_RENDER_AT" ] && R_PRE_RENDER="$(git -C "$ROOT" rev-parse --verify -q "$R_RENDER_AT^" 2>/dev/null)"
if [ -n "$R_PRE_APPLY" ] && [ -n "$R_PRE_RENDER" ]; then
  ok "(R0) the two gates are dated from the tree: cmd_apply arrives in $(git -C "$ROOT" rev-parse --short "$R_APPLY_AT") (pre-refusal parent $(git -C "$ROOT" rev-parse --short "$R_PRE_APPLY")), cmd_render in $(git -C "$ROOT" rev-parse --short "$R_RENDER_AT") (parent $(git -C "$ROOT" rev-parse --short "$R_PRE_RENDER")) — derived, so the brief's 53bbe684 cannot be taken on trust"
else
  no "(R0) could not date the two gates from history (cmd_apply=$R_APPLY_AT cmd_render=$R_RENDER_AT); the RED below would have no pre-refusal tree to run against"
fi
oldtree(){   # $1 = commit, $2 = destination
  mkdir -p "$2" || return 1
  git -C "$ROOT" archive "$1" scripts/zuvo-home | tar -x -C "$2" || return 1
  return 0
}
for pair in "apply:$R_PRE_APPLY" "render:$R_PRE_RENDER"; do
  R_WHAT="${pair%%:*}"; R_SHA="${pair#*:}"
  R_DIR="$FIX/pre-$R_WHAT"
  if oldtree "$R_SHA" "$R_DIR"; then :; else no "(R2) could not extract $R_WHAT's pre-refusal tree $R_SHA"; continue; fi
  R_MOD="$R_DIR/scripts/zuvo-home"
  # THE POSITIVE CONTROL FIRST. Without it "rc is not the refusal code" could just as well mean the old
  # checkout does not run at all, and the RED would be a statement about a broken extraction.
  G7 "$R_MOD" "$RED" "$FIX/red-pre-$R_WHAT-zuvo" plan --dry-run >"$FIX/red-pre-$R_WHAT-plan.out" 2>&1
  R_PRC="$?"
  R_PENT="$(iv7 "$FIX/red-pre-$R_WHAT-plan.out" ENTRIES)"
  [ "$R_PRC" -eq 0 ] && [ "${R_PENT:-0}" = "${B_ENTRIES:-x}" ] \
    && ok "(R2/$R_WHAT) the pre-refusal tree $(git -C "$ROOT" rev-parse --short "$R_SHA") RUNS on this fixture — plan --dry-run rc=0 over the same $R_PENT entries — so an absent refusal below is the code's and not the extraction's" \
    || no "(R2/$R_WHAT) the pre-refusal tree exited $R_PRC reporting ${R_PENT:-0} entries against $B_ENTRIES expected; its RED would prove nothing"
done
# apply: the coverage refusal, before and after.
G7 "$FIX/pre-apply/scripts/zuvo-home" "$RED" "$FIX/red-a-pre-zuvo" apply >"$FIX/red-apply-pre.out" 2>&1
R_A_PRE="$?"
G7 "$CTL" "$RED" "$RED_OUT" apply >"$FIX/red-apply-now.out" 2>&1
R_A_NOW="$?"
echo "  observed: apply at $(git -C "$ROOT" rev-parse --short "$R_PRE_APPLY") rc=$R_A_PRE :: $(tail -1 "$FIX/red-apply-pre.out")"
echo "  observed: apply at HEAD rc=$R_A_NOW, expected RC_UNVERIFIED=$RC_UNVERIFIED"
[ "$R_A_PRE" -ne "$RC_UNVERIFIED" ] && ! grep -q 'refusing to apply any disposition' "$FIX/red-apply-pre.out" \
  && ok "(R3/RED) BEFORE the gate landed, groom does NOT refuse an incomplete ledger: rc=$R_A_PRE and no 'refusing to apply any disposition' anywhere in its output — so C1/C2 FAIL against that tree, which is exactly the RED Task 7 owes" \
  || no "(R3/RED) the pre-refusal tree already produced the refusal (rc=$R_A_PRE), so C1/C2 would pass on both sides and prove nothing — check that $(git -C "$ROOT" rev-parse --short "$R_PRE_APPLY") really predates cmd_apply"
[ "$R_A_NOW" -eq "$RC_UNVERIFIED" ] && grep -q "^UNVERIFIED=$C_VICTIM\$" "$FIX/red-apply-now.out" \
  && ok "(R4/RED) …and AFTER it landed the same command on the same bytes refuses with RC_UNVERIFIED=$RC_UNVERIFIED naming $C_VICTIM. Observed-vs-expected: $R_A_PRE -> $R_A_NOW" \
  || no "(R4/RED) HEAD exited $R_A_NOW where $RC_UNVERIFIED was owed"
# render: the partial-verification refusal, before and after.
G7 "$FIX/pre-render/scripts/zuvo-home" "$RED" "$FIX/red-r-pre-zuvo" render >"$FIX/red-render-pre.out" 2>&1
R_R_PRE="$?"
G7 "$CTL" "$RED" "$RED_OUT" render >"$FIX/red-render-now.out" 2>&1
R_R_NOW="$?"
echo "  observed: render at $(git -C "$ROOT" rev-parse --short "$R_PRE_RENDER") rc=$R_R_PRE :: $(tail -1 "$FIX/red-render-pre.out")"
echo "  observed: render at HEAD rc=$R_R_NOW, expected RC_PARTIAL=$RC_PARTIAL"
[ "$R_R_PRE" -ne "$RC_PARTIAL" ] && ! grep -q 'refusing to render' "$FIX/red-render-pre.out" \
  && ok "(R5/RED) BEFORE the gate landed, doc does NOT refuse a partially verified backlog: rc=$R_R_PRE, no 'refusing to render' — so C4 FAILS against that tree. Observed-vs-expected: $R_R_PRE -> $R_R_NOW with RC_PARTIAL=$RC_PARTIAL" \
  || no "(R5/RED) the pre-render tree already refused (rc=$R_R_PRE), so C4 would pass on both sides"
[ "$R_R_NOW" -eq "$RC_PARTIAL" ] \
  && ok "(R6/RED) …and AFTER it landed the refusal is RC_PARTIAL=$RC_PARTIAL" \
  || no "(R6/RED) HEAD's render exited $R_R_NOW where $RC_PARTIAL was owed"
R_RAN=1
fi
if [ "$R_RAN" -eq 1 ]; then
  ok "(R7) the R group ran end to end in this environment, so the RED above is a measurement and not a claim"
fi

# ==================================================================================================
# MS — ONE MUTANT PER CLAIM. Each reverts exactly the behaviour one group above asserts, the factory
# hard-errors unless its substitution applies exactly once, and each is run against the SAME fixture as
# its control, so "the mutant appeared" is attributable to the mutation and not to a different input.
# ==================================================================================================
echo "-- MS: the mutants --"

ms_build(){  # $1 = kind — reports its own failure, because a mutant that did not build makes its assertion vacuous
  if mut7_build "$1"; then return 0; fi
  no "(MS) mutant '$1' did NOT build: $(tail -1 "$FIX/mk-$1.log") — its substitution no longer applies, so the assertion it targets would pass against a mutant that does not exist"
  return 1
}

# MS1 — C1/C2: the coverage refusal.
if ms_build nocoverrefuse; then
  G7 "$FIX/mut-nocoverrefuse" "$RED" "$FIX/ms1-zuvo" apply --dry-run >"$FIX/ms1.out" 2>&1
  MS1="$?"
  [ "$MS1" -ne "$RC_UNVERIFIED" ] \
    && ok "(MS1) with decision 10's coverage gate removed, apply no longer refuses the incomplete ledger (rc=$MS1 against the control's $RC_UNVERIFIED) — C1/C2 fail under it" \
    || no "(MS1) the nocoverrefuse mutant still exited $RC_UNVERIFIED, so C1/C2 would pass with the gate gone"
fi
# MS2 — C4: the render refusal.
if ms_build norenderrefuse; then
  G7 "$FIX/mut-norenderrefuse" "$RED" "$FIX/ms2-zuvo" render >"$FIX/ms2.out" 2>&1
  MS2="$?"
  [ "$MS2" -ne "$RC_PARTIAL" ] \
    && ok "(MS2) with decision 11's render gate removed, doc renders an unverified backlog without --partial (rc=$MS2 against the control's $RC_PARTIAL) — C4 fails under it" \
    || no "(MS2) the norenderrefuse mutant still exited $RC_PARTIAL"
fi
# MS3 — C6: --partial OMITS the ranking rather than labelling it.
if ms_build partialranks; then
  G7 "$FIX/mut-partialranks" "$RED" "$FIX/ms3-zuvo" render --partial >"$FIX/ms3.out" 2>&1
  MS3_DOC="$(iv7 "$FIX/ms3.out" REPORT)"
  if grep -q '^## Ranking' "$MS3_DOC" 2>/dev/null; then
    ok "(MS3) with the partial guard inverted, a --partial document DOES carry a Ranking section — C6 fails under it, which is what makes C6 an assertion about the omission rather than about the banner"
  else
    no "(MS3) the partialranks mutant still omitted the ranking (doc=${MS3_DOC:-<none>}), so C6 is not attributable to the guard"
  fi
fi
# MS4 — A7: the scope refusal. THE ONE WITH TEETH: without it the dogfood performs a whole-file archive
# on behalf of entries whose verdicts licensed it and carries out the ones that did not.
if ms_build noscoperefuse; then
  G7 "$FIX/mut-noscoperefuse" "$DOG" "$FIX/ms4-zuvo" apply --dry-run >"$FIX/ms4.out" 2>&1
  MS4="$?"
  [ "$MS4" -ne "$RC_SCOPE" ] \
    && ok "(MS4) with the scope check removed, apply stops refusing on this repo's own backlog (rc=$MS4 against the control's $RC_SCOPE) and proceeds to delegate a whole-file archive whose set it never compared — A7 fails under it" \
    || no "(MS4) the noscoperefuse mutant still exited $RC_SCOPE, so A7 is not attributable to the scope check"
fi
# MS7 — A13: DUPLICATE-OF is a report, never a licence.
if ms_build dupmerges; then
  G7 "$FIX/mut-dupmerges" "$DOG" "$FIX/ms7-zuvo" apply --dry-run >"$FIX/ms7.out" 2>&1
  MS7_N="$(grep '^DISPOSITION=' "$FIX/ms7.out" | awk -F'|' '$2=="dropped" && $3=="drop-stale"' | wc -l | tr -d ' ')"
  [ "${MS7_N:-0}" -gt 0 ] \
    && ok "(MS7) with DUPLICATE-OF turned into a licence, $MS7_N duplicate(s) acquire a drop-stale verb — A13 fails under it, and the control's zero is therefore a measurement rather than an absence of duplicates" \
    || no "(MS7) the dupmerges mutant produced no performable duplicate disposition, so A13 is not attributable"
fi
# MS8 — A15/B9: the document's provenance sha really describes the source.
if ms_build shalies; then
  G7 "$FIX/mut-shalies" "$DOG" "$FIX/ms8-zuvo" render >"$FIX/ms8.out" 2>&1
  MS8_DOC="$(iv7 "$FIX/ms8.out" REPORT)"
  MS8_SHA="$(sed -n 's/^source_sha256: //p' "$MS8_DOC" 2>/dev/null | head -1)"
  [ -n "$MS8_SHA" ] && [ "$MS8_SHA" != "$(sha256f "$DOG_BL")" ] \
    && ok "(MS8) with the provenance sha detached from the source, the header no longer matches the file ($MS8_SHA) — A15/B9 fail under it, so they are assertions about decision 12 and not about the presence of a line" \
    || no "(MS8) the shalies mutant still produced a matching source_sha256 (${MS8_SHA:-<none>})"
fi
# The reuse and dedup mutants need a repo whose ledger is COMPLETE, so the RED clone gets its full one
# back. Done here and not earlier because MS1-MS3 are about the short one.
cp "$FIX/e2e-ledger-full.jsonl" "$RED/memory/backlog-verdicts.jsonl"
G7 "$CTL" "$RED" "$FIX/ms5-ctl-zuvo" plan --dry-run >"$FIX/ms5-ctl.out" 2>&1
MS5_CTL="$(iv7 "$FIX/ms5-ctl.out" REUSED)"
MS5_CTLCH="$(sed -n 's/^CHUNKS=\([0-9]*\).*/\1/p' "$FIX/ms5-ctl.out" | head -1)"
[ "${MS5_CTL:-0}" = "${B_ENTRIES:-x}" ] && [ "${MS5_CTLCH:-1}" -eq 0 ] \
  && ok "(MS5a) the control reuses all $MS5_CTL verdicts on the RED clone with CHUNKS=0, so MS5 below is measured against a real zero" \
  || no "(MS5a) the control on the RED clone reused ${MS5_CTL:-0} of ${B_ENTRIES:-?} with ${MS5_CTLCH:-?} chunk(s); MS5 would not be attributable"
# MS5 — C9/C10: the free resume.
if ms_build reuseblind; then
  G7 "$FIX/mut-reuseblind" "$RED" "$FIX/ms5-zuvo" plan --dry-run >"$FIX/ms5.out" 2>&1
  MS5_R="$(iv7 "$FIX/ms5.out" REUSED)"
  MS5_CH="$(sed -n 's/^CHUNKS=\([0-9]*\).*/\1/p' "$FIX/ms5.out" | head -1)"
  [ "${MS5_R:-1}" = "0" ] && [ "${MS5_CH:-0}" -gt 0 ] \
    && ok "(MS5) with the text_sha-exact reuse decision removed, the second pass reuses nothing and re-dispatches ${MS5_CH} chunk(s) — C9/C10 fail under it, and 'zero dispatches on resume' is therefore a property of the code and not of an empty queue" \
    || no "(MS5) the reuseblind mutant still reused ${MS5_R:-?} verdicts over ${MS5_CH:-?} chunk(s)"
fi
# MS6 — A10/A11: nothing merges two entries that share a content key.
if ms_build dedupkeyonly; then
  python3 "$DUPS7" "$FIX/mut-dedupkeyonly" "$DOG_BL" "$DOG_LED" >"$FIX/ms6.out" 2>&1
  MS6_M="$(iv7 "$FIX/ms6.out" ROWS_PER_TEXT_MISMATCH)"
  MS6_OK="$(sed -n 's/.*DUP_ENTRIES_WITH_EXACT_ROW=\([0-9]*\).*/\1/p' "$FIX/ms6.out" | head -1)"
  [ "${MS6_M:-0}" -gt 0 ] \
    && ok "(MS6) with text_sha dropped from the dedup identity, $MS6_M duplicate key(s) collapse two DIFFERENT entry texts onto one verdict row and only ${MS6_OK:-?} of $A_DUPE duplicate-keyed entries keep an exact row — A10/A11 fail under it" \
    || no "(MS6) the dedupkeyonly mutant produced no merge (mismatch=${MS6_M:-?}), so A10/A11 are not attributable to the sha half of the identity"
fi

# ==================================================================================================
# THE TWO ACCEPTANCE ARTIFACTS. Written by the suite rather than transcribed by hand, so the proof and
# the run cannot disagree — and both of them open with HOW THE VERDICTS WERE PRODUCED, because a
# fixture-fed ledger presented as a verification pass would be the worst defect this plan could ship.
# ==================================================================================================
PROOF_DIR="${ZUVO_OUTPUT_DIR:-$ROOT/zuvo}/proofs"
mkdir -p "$PROOF_DIR" 2>/dev/null
P1="$PROOF_DIR/smoke-dogfood-zuvo-plugin.txt"
P2="$PROOF_DIR/smoke-refusal-and-resume.txt"

{
  echo "SMOKE1 — dogfood the whole grooming pipeline on this repo's own backlog"
  echo "generated by tests/hooks/test-backlog-grooming-smoke.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "repo=$ROOT  HEAD=$HEAD_SHA  fixtures=$FIX"
  echo
  echo "=== HOW THE VERDICTS WERE PRODUCED — READ THIS BEFORE ANY NUMBER BELOW ==="
  echo "NOT ONE VERDICT IN THIS PROOF WAS PRODUCED BY A MODEL READING THE CODE."
  echo "Task 7's GREEN specifies that where a step needs real agent dispatch the suite asserts the"
  echo "orchestrator's queue and conservation logic against a RECORDED RESPONSE FIXTURE rather than"
  echo "calling a model, so that it stays deterministic in CI. Of the $D_ENTRIES verdicts in the ledger this"
  echo "run built, $A_DET are DETERMINISTIC — the pre-pass read the bytes ($(grep '^DET_CLASS=' "$FIX/dog-plan.out" | tr '\n' ' '))"
  echo "— and the remainder come from the recorded fixture mkresp7.py, which answers NOT-VERIFIABLE to"
  echo "every real row and the recorded answer to every control-(d) seed. THEREFORE:"
  echo "  * this proof shows the ORCHESTRATOR conserves, gates, refuses and renders correctly;"
  echo "  * it shows NOTHING about whether any entry in memory/backlog.md is still true;"
  echo "  * '$D_ENTRIES of $D_ENTRIES entries carry a verdict with a resolvable evidence line' is a statement about"
  echo "    the pipeline's BOOKKEEPING, not a verification pass. Every fixture-fed row says so in its own"
  echo "    evidence field: \"the recorded fixture response reaches no verdict for this entry\"."
  echo "A real verification pass is zuvo:backlog verify with the verifier lane actually dispatched."
  echo
  echo "=== SELECTION (named, because the plan's counts are stale six times over) ==="
  echo "$SRC_BL as it stands in this checkout (HEAD=$HEAD_SHA), sha256 $(sha256f "$SRC_BL"),"
  echo "$(wc -c <"$SRC_BL" | tr -d ' ') bytes, parsed by iter_entries(kinds=DEFAULT_KINDS+(KIND_HEADING,))."
  echo "Run on a temp COPY of the working tree — not git-archive, because rt's delta mirror carries no"
  echo ".git at all and a history-based fixture would make this child a permanent farm red. The live"
  echo "backlog is never the subject; its sha256 is re-checked at the end of the suite."
  echo "  entries DERIVED            = $D_ENTRIES   (SMOKE1 says 387; the plan has also carried 330/483/402/494/495/503)"
  echo "  marker-carrying DERIVED    = $D_MARKERS    (SMOKE1 says 24)   by kind: $(iv7 "$FIX/census-dog.out" MARKERS_BY_KIND)"
  echo "  duplicate keys DERIVED     = $D_DUPS     ($D_DUPS_FP content/fp: + $D_DUPS_ID id:)  (SMOKE1's '6 duplicate content keys' is the ONE of its three numbers measurement confirms, under the fp:-only reading)"
  echo "  status-done DERIVED        = $D_DONE    by kind: $(iv7 "$FIX/census-dog.out" STATUS_DONE_BY_KIND)"
  echo "  heading ids DERIVED        = $D_HEADIDS"
  echo "  live working tree (gates nothing) = $(iv7 "$FIX/census-live.out" ENTRIES) entries / $(iv7 "$FIX/census-live.out" MARKERS) markers / $(iv7 "$FIX/census-live.out" DUP_KEYS) dup keys"
  echo "Cross-check: the shipped pre-pass independently reports ENTRIES=$P_ENTRIES and DET_CLASS=marker $P_MARKERS."
  echo
  echo "=== VERIFY (plan -> dispatch -> recorded response -> ingest) ==="
  grep -Ev '^(UNMINTABLE_ENTRY|IDLESS_HEADING|CHUNK|ORPHAN)=' "$FIX/dog-plan.out"
  echo "-- per chunk --"
  cat "$FIX/dog-summary"
  echo "negative control on the SAME chunk 0 dispatch, one record dropped ($A_DROP):"
  echo "  rc=$A_OMITRC (RC_REJECTED=$RC_REJECTED), $(grep -m1 '^REJECTS=' "$FIX/dog-ing-omit.out"), ledger $A_LEDB0 -> $A_LEDB1 bytes"
  echo "  so the zero-rejection rows above are a measurement of a live control, not of a fixture that"
  echo "  nothing could reject; and nothing is appended from a response that failed conservation."
  echo "coverage after the lane: $(if [ -s "$FIX/dog-cov.out" ]; then cat "$FIX/dog-cov.out"; else echo "(silent — every entry carries a text_sha-current verdict)"; fi)"
  echo
  echo "=== GROOM on the full selection: the scope refusal, measured ==="
  grep -Ev '^DISPOSITION=' "$FIX/dog-apply.out" | tail -12
  echo "apply --dry-run rc=$A_APPLYRC (RC_SCOPE=$RC_SCOPE); backlog sha256 $A_BL0 unchanged, archive sha256 $A_AR0 unchanged."
  echo "WHY: _decide calls every status-done entry 'archived'; backlog-archive.py indexes"
  echo "kinds=(KIND_CHECKBOX,) and gates the heading dialect, so of the $D_DONE status-done entries"
  echo "($(iv7 "$FIX/census-dog.out" STATUS_DONE_BY_KIND)) its movable set is smaller. The refusal is the safe"
  echo "direction — nothing is closed that no verdict licensed — and it is why the closure half below"
  echo "runs on a stated sub-selection."
  echo
  echo "=== DUPLICATES: reported, never merged ==="
  cat "$FIX/dog-dups.out"
  echo
  echo "=== DOC ==="
  grep -E '^(ENTRIES|VERIFIED|CLUSTERS|RANKING|NOT_VERIFIABLE|RENDERED|REPORT|REPORT_BYTES)=' "$FIX/dog-render.out"
  # The provenance KEY LINES, not a `sed` range: the document also carries a "## Provenance self-check"
  # heading and its own fenced recipe, so a range from /^## Provenance/ to the next fence prints that
  # instead of the header it was aimed at.
  grep -E '^(source|source_sha256|source_bytes|entries|coverage|mode|ledger|ledger_rows|ledger_defects|generated_by|generated_at): ' "$A_DOC" 2>/dev/null | head -12
  echo
  echo "=== THE ARCHIVER'S OWN ANSWERS ==="
  echo "verify: $(head -1 "$FIX/dog-verify.out")"
  echo "status (heading gate ON,  rc=$A_SRC):  $(head -1 "$FIX/dog-status.out" | cut -c1-150)"
  echo "status (heading gate OFF, rc=$A_SRC2): $(head -1 "$FIX/dog-status-nogate.out" | cut -c1-150)"
  echo "  SMOKE1 asks that status no longer print the false 'nothing resolved left'. It does not — WITH the"
  echo "  heading gate. Without it the archiver indexes kinds=(KIND_CHECKBOX,) only, and this selection's"
  echo "  status-done entries are $(sed -n 's/.*STATUS_DONE_BY_KIND=//p' "$FIX/census-dog.out" | head -1), so it says 'nothing resolved left' and means"
  echo "  'no ticked CHECKBOX is left'. Both lines belong in the proof; either one alone misstates it."
  echo "lookup: $A_HIT of $A_NID sampled heading ids resolved (answer rides on rc 10/11/12, not 0)"
  echo
  echo "=== ENTRY-LEVEL CONSERVATION, keyed on text_sha ==="
  echo "Full selection, closure performed by the helper apply would have delegated to:"
  echo "  $(head -1 "$FIX/dogc-archive.out")"
  echo "  open+archived before = $A_NB entries, after = $A_NA; multiset of text_sha: $(if diff -q "$FIX/dogc-shas-before.txt" "$FIX/dogc-shas-after.txt" >/dev/null 2>&1; then echo IDENTICAL; else echo DIFFERS; fi)"
  echo "  entry texts that crossed OPEN -> ARCH = $A_MOVED_SET ; open texts present in neither file afterwards = $A_OPEN_LOST"
  echo "  the helper says '$A_MOVED entries' and the census says $A_MOVED_SET crossed. Both are right: the helper counts"
  echo "  RESOLVED entries, and a heading entry's block deliberately CONTAINS its children, so archiving one"
  echo "  heading carries every entry inside it. That gap is exactly why conservation is asserted entry-level."
  echo "Sub-selection, closure performed by apply ITSELF (see SMOKE2 artifact for the gate half):"
  echo "  sub-selection = $B_AFTER of $B_BEFORE entries ($B_DROPPED removed: $(grep -c 'REDUCE_DROP=unmovable-dialect' "$FIX/reduce.out") unmovable-dialect, $(grep -c 'REDUCE_DROP=double-duty-id' "$FIX/reduce.out") double-duty-id)"
  echo "  apply rc=$B_ARC, $B_MOVED entries moved by the delegated helper, ORDER_HINTS applied=$B_HINTS"
  echo "  open+archived before = $B_NB, after = $B_NA; multiset: $(if diff -q "$FIX/e2e-shas-before.txt" "$FIX/e2e-shas-after.txt" >/dev/null 2>&1; then echo IDENTICAL; else echo DIFFERS; fi); crossed OPEN -> ARCH = $B_FROMOPEN"
  echo "  open file sha256 $B_BL0 -> $(sha256f "$E2E_BL")"
  echo
  echo "=== MINT ==="
  echo "INSERTED_BYTES=$A_NOMINT, MINTABLE=$(iv7 "$FIX/dog-plan.out" MINTABLE) of MINT_SET=$(iv7 "$FIX/dog-plan.out" MINT_SET)."
  echo "SMOKE1's 'differing only by minted ids' therefore holds in its degenerate form: mint_into refuses"
  echo "the BULLET dialect by a deliberate, pinned PR 1 contract, so 0 of the set are reachable and the"
  echo "duplicates are disambiguated by REPORT (DUPLICATE-OF) rather than by a minted id."
  echo
  echo "=== LIVE FILES, unchanged across the whole suite ==="
  cat "$LIVE_SHAS"
} >"$P1" 2>&1

{
  echo "SMOKE2 — the refusal actually holds, and a second pass resumes for free"
  echo "generated by tests/hooks/test-backlog-grooming-smoke.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "repo=$ROOT  HEAD=$HEAD_SHA  fixtures=$FIX"
  echo
  echo "=== HOW THE VERDICTS WERE PRODUCED ==="
  echo "NOT ONE VERDICT HERE WAS PRODUCED BY A MODEL. The ledger this artifact refuses on, resumes from"
  echo "and finally applies was built by the real orchestrator (plan, dispatch, controls (a)-(d),"
  echo "three-way conservation, ingest) over a RECORDED RESPONSE FIXTURE, per Task 7's GREEN. Every"
  echo "fixture-fed row says so in its own evidence field. What is proven below is the behaviour of the"
  echo "GATES, not the truth of any verdict."
  echo
  echo "=== FIXTURE ==="
  echo "A temp copy of $SRC_BL as it stands in this checkout (HEAD=$HEAD_SHA, sha256"
  echo "$(sha256f "$SRC_BL")), reduced to the sub-selection on"
  echo "which apply can perform its closures: $B_AFTER of $B_BEFORE entries, $B_DROPPED removed and each one named"
  echo "on stdout by reason. Verify lane: $B_CHUNKS chunks, all ingested, $(iv7 "$FIX/e2e-plan.out" DETERMINISTIC) decided deterministically."
  echo "Then ONE verdict row deleted from the ledger. Subject: $C_VICTIM"
  echo
  echo "=== REFUSAL 1 — groom ==="
  grep -E '^(VERIFIED|UNVERIFIED)=' "$FIX/c-apply.out"
  grep -o 'refusing to apply[^.]*\.' "$FIX/c-apply.out" | head -1
  echo "rc=$C_ARC (RC_UNVERIFIED=$RC_UNVERIFIED, outside {0,1,2,10,11,12}); exactly $C_NSHORT UNVERIFIED= line, naming $C_VICTIM."
  echo "zero bytes written: backlog $C_BL0 unchanged, archive $C_AR0 unchanged."
  echo
  echo "=== REFUSAL 2 — doc ==="
  grep -E '^(VERIFIED|UNVERIFIED)=' "$FIX/c-render.out"
  grep -o 'refusing to render[^.]*\.' "$FIX/c-render.out" | head -1
  echo "rc=$C_RRC (RC_PARTIAL=$RC_PARTIAL — its OWN code, because 'verify the rest' and 'pass --partial' are"
  echo "different remedies). With --partial: rc=$C_PRC, $(grep -m1 '^coverage: ' "$C_PDOC" 2>/dev/null), ranking $(iv7 "$FIX/c-partial.out" RANKING),"
  echo "'## Ranking' sections in the document = $(grep -c '^## Ranking' "$C_PDOC" 2>/dev/null)."
  echo
  echo "=== RESUME — zero dispatches ==="
  echo "ledger restored byte-identically ($B_LEDSHA)."
  grep -E '^(ENTRIES|REUSED|CHUNKS|LEDGER_DEFECTS)=' "$FIX/c-replan.out"
  echo "orphan verdicts = $C_ORPH"
  echo "dispatch --chunk 0 on the resumed queue: rc=$C_DRC (RC_QUEUE=$RC_QUEUE), $(grep -m1 '^CHUNK=0' "$FIX/c-redispatch.out")"
  echo "so the resume hands ZERO rows to a verifier: $C_REUSED of $B_ENTRIES reused free, CHUNKS $B_CHUNKS -> $C_RECH."
  echo
  echo "=== THEN groom SUCCEEDS ==="
  grep -E '^(VERIFIED|DISPOSED|ORDER_HINTS|HELPER|LEDGER_APPENDED)=' "$FIX/b-apply.out"
  echo "rc=$B_ARC"
  echo
  echo "=== THE RED, against the real pre-refusal trees ==="
  if [ "$R_RAN" -eq 1 ]; then
    echo "cmd_apply arrives in  $(git -C "$ROOT" rev-parse --short "$R_APPLY_AT")  -> pre-refusal parent $(git -C "$ROOT" rev-parse --short "$R_PRE_APPLY")"
    echo "cmd_render arrives in $(git -C "$ROOT" rev-parse --short "$R_RENDER_AT") -> pre-refusal parent $(git -C "$ROOT" rev-parse --short "$R_PRE_RENDER")"
    echo "The brief said \"53bbe684's parent for the apply gate\". 53bbe684 is revision 9, a PLAN commit whose"
    echo "parent is $(git -C "$ROOT" rev-parse --short "$R_APPLY_AT") — the commit that INTRODUCES the gate, so the brief's"
    echo "instruction would have produced a FALSE red. Measured: apply at 53bbe684 already refuses, rc=$RC_UNVERIFIED."
    echo "observed-vs-expected, same fixture, same bytes, only the code changing:"
    echo "  apply  @ $(git -C "$ROOT" rev-parse --short "$R_PRE_APPLY") rc=$R_A_PRE  :: $(tail -1 "$FIX/red-apply-pre.out")"
    echo "  apply  @ HEAD      rc=$R_A_NOW  :: expected RC_UNVERIFIED=$RC_UNVERIFIED, names $C_VICTIM"
    echo "  render @ $(git -C "$ROOT" rev-parse --short "$R_PRE_RENDER") rc=$R_R_PRE  :: $(tail -1 "$FIX/red-render-pre.out")"
    echo "  render @ HEAD      rc=$R_R_NOW  :: expected RC_PARTIAL=$RC_PARTIAL"
    echo "positive control on both old trees: plan --dry-run rc=0 over the same $B_ENTRIES entries, so an absent"
    echo "refusal is the code's and not a broken extraction's."
  else
    echo "NOT EXERCISED in this run: no git history in this environment (rt's delta mirror carries no .git),"
    echo "so there is no pre-refusal tree to drive. Nothing else in this artifact depends on it; the group"
    echo "asserts nothing rather than printing a PASS it did not earn."
  fi
  echo
  echo "=== LIVE FILES, unchanged across the whole suite ==="
  cat "$LIVE_SHAS"
} >"$P2" 2>&1

[ -s "$P1" ] && [ -s "$P2" ] \
  && ok "(Z1) both acceptance artifacts were written by the suite itself ($(wc -c <"$P1" | tr -d ' ') and $(wc -c <"$P2" | tr -d ' ') bytes under $PROOF_DIR), so the proof and the run cannot disagree" \
  || no "(Z1) one of the acceptance artifacts is missing or empty: $P1 / $P2"
grep -q 'NOT ONE VERDICT IN THIS PROOF WAS PRODUCED BY A MODEL' "$P1" 2>/dev/null \
  && grep -q 'NOT ONE VERDICT HERE WAS PRODUCED BY A MODEL' "$P2" 2>/dev/null \
  && ok "(Z2) …and each one STATES, in its first section, that the verdicts came from a recorded fixture and not from a model — overclaiming here would be the worst defect this plan could ship, so the wording is asserted and not merely written" \
  || no "(Z2) an artifact is missing its fixture-provenance statement"

finish
