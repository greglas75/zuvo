#!/usr/bin/env bash
# test-dev-push-gate.sh — Task 5: dev-push.sh Step-0 test gate.
#
# RED-first: authored BEFORE the `# >>> zuvo:test-gate` fenced block is inserted
# into scripts/dev-push.sh. Until the gate exists, the structural + behavioral
# assertions below fail loudly (intended RED evidence); once the gate is added,
# every assertion must pass.
#
# Asserts:
#   (a) STRUCTURAL — the fenced gate block exists and its start line sits AFTER
#                    the marketplace-dir check and BEFORE `# Step 1` AND before
#                    the first `cd "$ZUVO_DIR"` (no mutation runs before it).
#   (b) SYNTAX     — `bash -n scripts/dev-push.sh` passes.
#   (c) DIRECTION  — the gate guards on `!= "1"` applied to ZUVO_SKIP_TESTS
#                    (run-by-default, skip only on explicit opt-in — not inverted).
#   (d) BEHAVIORAL — extract the fenced block body and run it hermetically against
#                    a stub tests/run-all.sh + stub fail/warn/ok:
#                       (i)   no skip + failing suite  → non-zero exit + FAIL-CALLED
#                       (ii)  ZUVO_SKIP_TESTS=1        → exit 0 + WARN-CALLED (bypass)
#                       (iii) passing suite, no skip   → exit 0, no FAIL-CALLED
#   (e) PURITY     — running this test never mutates the repo working tree.
#
# awk-fence extraction idiom adapted from tests/adversarial/test-skill-retro-wiring.sh
# (T7.3); mktemp+trap fixture idiom from tests/hooks/test-pipeline-gate-lib.sh.
# bash 3.2-compatible (macOS default): no mapfile, no associative arrays.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/dev-push.sh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

# (e) baseline: capture the repo working-tree state up front; re-check at the end.
GIT_BEFORE="$( (cd "$ROOT" && git status --porcelain) 2>/dev/null )"

# throwaway fixtures: ONE mktemp root, every fixture is a subdir, cleanup is a
# single quoted `rm -rf "$TMP_ROOT"` — spaced-TMPDIR-safe by construction (no
# word-splitting over a space-separated path list). INT/TERM traps exit
# explicitly so an abort request terminates instead of resuming past cleanup.
TMP_ROOT="$(mktemp -d)"
_cleanup() { rm -rf "$TMP_ROOT"; }
trap _cleanup EXIT
trap '_cleanup; exit 1' INT TERM
FIX_FAIL="$TMP_ROOT/fail"
FIX_OK="$TMP_ROOT/ok"

if [ ! -f "$SCRIPT" ]; then
  bad "scripts/dev-push.sh not found at $SCRIPT"
  echo "SOME FAILED"; exit 1
fi

# ── line numbers (grep -F: fixed-string anchors, no regex surprises) ───────────
GATE_START="$(grep -Fn '# >>> zuvo:test-gate' "$SCRIPT" | head -1 | cut -d: -f1)"
GATE_END="$(grep -Fn '# <<< zuvo:test-gate' "$SCRIPT" | head -1 | cut -d: -f1)"
MKT_LINE="$(grep -Fn 'Marketplace repo not found' "$SCRIPT" | head -1 | cut -d: -f1)"
STEP1_LINE="$(grep -Fn '# Step 1' "$SCRIPT" | head -1 | cut -d: -f1)"
CD_LINE="$(grep -Fn 'cd "$ZUVO_DIR"' "$SCRIPT" | head -1 | cut -d: -f1)"

# ── (a) STRUCTURAL ────────────────────────────────────────────────────────────
if [ -n "$GATE_START" ] && [ -n "$GATE_END" ]; then
  pass "(a) fenced gate block present (>>> line $GATE_START, <<< line $GATE_END)"
else
  bad "(a) fenced gate block MISSING (>>> '$GATE_START' <<< '$GATE_END')"
fi

if [ -n "$GATE_START" ] && [ -n "$MKT_LINE" ] && [ "$GATE_START" -gt "$MKT_LINE" ]; then
  pass "(a) gate ($GATE_START) is AFTER the marketplace-dir check ($MKT_LINE)"
else
  bad "(a) gate ($GATE_START) must be AFTER marketplace check ($MKT_LINE)"
fi

if [ -n "$GATE_START" ] && [ -n "$STEP1_LINE" ] && [ "$GATE_START" -lt "$STEP1_LINE" ]; then
  pass "(a) gate ($GATE_START) is BEFORE '# Step 1' ($STEP1_LINE)"
else
  bad "(a) gate ($GATE_START) must be BEFORE '# Step 1' ($STEP1_LINE)"
fi

if [ -n "$GATE_START" ] && [ -n "$CD_LINE" ] && [ "$GATE_START" -lt "$CD_LINE" ]; then
  pass "(a) gate ($GATE_START) is BEFORE first cd \"\$ZUVO_DIR\" ($CD_LINE) — no mutation precedes it"
else
  bad "(a) gate ($GATE_START) must be BEFORE first cd \"\$ZUVO_DIR\" ($CD_LINE)"
fi

# ── (b) SYNTAX ────────────────────────────────────────────────────────────────
if bash -n "$SCRIPT" 2>/dev/null; then
  pass "(b) bash -n scripts/dev-push.sh passes"
else
  bad "(b) bash -n scripts/dev-push.sh FAILED"
fi

# ── HARD GUARD: never extract/execute an unbounded block ─────────────────────
# A missing/misordered end marker would make the awk below capture the REST of
# dev-push.sh — real release commands (push, tag, marketplace) — into the
# executed stub context. The structural failures above already recorded the RED
# evidence; stop here so the behavioral section is unreachable unless BOTH
# markers exist and the end marker follows the start marker.
if [ -z "$GATE_START" ] || [ -z "$GATE_END" ] || [ "$GATE_END" -le "$GATE_START" ]; then
  bad "gate markers absent/misordered (>>> '$GATE_START' <<< '$GATE_END') — refusing block extraction/execution"
  echo "----"
  echo "SOME FAILED"
  exit 1
fi

# ── extract the fenced block body (markers excluded) ──────────────────────────
BLOCK="$(awk '/# >>> zuvo:test-gate/{f=1;next} /# <<< zuvo:test-gate/{exit} f{print}' "$SCRIPT")"

# ── (c) CONDITIONAL DIRECTION ─────────────────────────────────────────────────
# Comment-stripped view: a trailing `# != "1"` comment must NOT satisfy this —
# only operational code counts. (Behavioral (d) verifies direction at runtime;
# this is the plan-mandated textual non-inversion check, made comment-proof.)
BLOCK_CODE="$(printf '%s\n' "$BLOCK" | sed 's/#.*$//')"
if [ -n "$BLOCK" ] && printf '%s\n' "$BLOCK_CODE" | grep -F 'ZUVO_SKIP_TESTS' | grep -Fq '!= "1"'; then
  pass "(c) gate guards ZUVO_SKIP_TESTS with != \"1\" (run-by-default, non-inverted)"
else
  bad "(c) gate must apply != \"1\" to ZUVO_SKIP_TESTS (block=[$BLOCK])"
fi

# ── (d) BEHAVIORAL: run the extracted block hermetically ──────────────────────
# stub run-all.sh: one fixture ZUVO_DIR whose suite fails, one whose suite passes.
mkdir -p "$FIX_FAIL/tests" "$FIX_OK/tests"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FIX_FAIL/tests/run-all.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX_OK/tests/run-all.sh"
chmod +x "$FIX_FAIL/tests/run-all.sh" "$FIX_OK/tests/run-all.sh"

# runner = stub fail/warn/ok + the extracted block body. fail() exits 1 like the
# real helper; warn()/ok() are observable no-ops.
RUNNER="$TMP_ROOT/runner.sh"
{
  printf '%s\n' 'fail() { echo "FAIL-CALLED"; exit 1; }'
  printf '%s\n' 'warn() { echo "WARN-CALLED"; }'
  printf '%s\n' 'ok()   { echo "OK-CALLED"; }'
  printf '%s\n' "$BLOCK"
} > "$RUNNER"

# (d.i) no skip + failing suite → fail() fires: non-zero exit AND FAIL-CALLED
out_i="$(env -u ZUVO_SKIP_TESTS ZUVO_DIR="$FIX_FAIL" bash "$RUNNER" 2>&1)"; rc_i=$?
if [ "$rc_i" -ne 0 ] && printf '%s\n' "$out_i" | grep -Fq 'FAIL-CALLED'; then
  pass "(d.i) no-skip + failing suite → block fails via fail() (exit $rc_i, FAIL-CALLED)"
else
  bad "(d.i) expected non-zero exit + FAIL-CALLED; got rc=$rc_i out=[$out_i]"
fi

# (d.ii) ZUVO_SKIP_TESTS=1 → skip path: exit 0, WARN-CALLED, suite never invoked
out_ii="$(ZUVO_DIR="$FIX_FAIL" ZUVO_SKIP_TESTS=1 bash "$RUNNER" 2>&1)"; rc_ii=$?
if [ "$rc_ii" -eq 0 ] \
   && printf '%s\n' "$out_ii" | grep -Fq 'WARN-CALLED' \
   && ! printf '%s\n' "$out_ii" | grep -Fq 'FAIL-CALLED'; then
  pass "(d.ii) ZUVO_SKIP_TESTS=1 → bypass (exit 0, WARN-CALLED, failing suite skipped)"
else
  bad "(d.ii) expected exit 0 + WARN-CALLED + no FAIL-CALLED; got rc=$rc_ii out=[$out_ii]"
fi

# (d.iii) passing suite, no skip → exit 0, no FAIL-CALLED
out_iii="$(env -u ZUVO_SKIP_TESTS ZUVO_DIR="$FIX_OK" bash "$RUNNER" 2>&1)"; rc_iii=$?
if [ "$rc_iii" -eq 0 ] && ! printf '%s\n' "$out_iii" | grep -Fq 'FAIL-CALLED'; then
  pass "(d.iii) passing suite, no skip → exit 0, no FAIL-CALLED"
else
  bad "(d.iii) expected exit 0 + no FAIL-CALLED; got rc=$rc_iii out=[$out_iii]"
fi

# ── (e) PURITY: the repo working tree is untouched by this test ───────────────
GIT_AFTER="$( (cd "$ROOT" && git status --porcelain) 2>/dev/null )"
if [ "$GIT_BEFORE" = "$GIT_AFTER" ]; then
  pass "(e) repo working tree unchanged by test run"
else
  bad "(e) test mutated the repo — before=[$GIT_BEFORE] after=[$GIT_AFTER]"
fi

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "ALL PASSED"
  exit 0
else
  echo "SOME FAILED"
  exit 1
fi
