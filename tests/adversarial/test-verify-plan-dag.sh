#!/usr/bin/env bash
# test-verify-plan-dag.sh — Plan v1.3.110 T1 RED.
# Pure-bash DFS DAG validator for zuvo:plan markdown plans.
# Must handle BOTH standalone `**Dependencies:** …` lines AND
# inline-`·`-separated metadata format used by real zuvo plans
# (otherwise the validator would BLOCK its own birth plan — SMOKE2
# self-validation would fail). Exit codes: 0 clean, 1 violation,
# 2 parse/IO error.

V="$ROOT/scripts/zuvo-home/verify-plan-dag"
TMPROOT="$ADV_TEST_HOME/verify-plan-dag-$$"
mkdir -p "$TMPROOT"

# Helper: write a plan fixture to a file and return its path via stdout.
_mk() {
  local name="$1"; shift
  local p="$TMPROOT/$name.md"
  printf '%s' "$*" > "$p"
  printf '%s' "$p"
}

# Common preflight — keep the rest of the test runnable even when V is absent
# (RED phase). assert_exit_code uses 'command not found' = 127.
start_test "T1.0 verify-plan-dag exists and is executable"
if [ -x "$V" ]; then pass "binary present + +x"
else fail "T1.0" "expected executable at $V"
fi

# ── Case 1: clean linear ─────────────────────────────────────────────────────
start_test "T1.1 clean linear DAG → exit 0 + 'valid'"
P=$(_mk linear '### Task 1: a
**Dependencies:** none
### Task 2: b
**Dependencies:** Task 1
### Task 3: c
**Dependencies:** Task 2
')
OUT=$("$V" "$P" 2>&1); RC=$?
assert_eq 0 "$RC" "exit code"
assert_contains "$OUT" "valid" "stdout contains 'valid'"

# ── Case 2: clean diamond ────────────────────────────────────────────────────
start_test "T1.2 clean diamond DAG → exit 0"
P=$(_mk diamond '### Task 1: a
**Dependencies:** none
### Task 2: b
**Dependencies:** Task 1
### Task 3: c
**Dependencies:** Task 1
### Task 4: d
**Dependencies:** Task 2, Task 3
')
"$V" "$P" >/dev/null 2>&1; assert_eq 0 "$?" "exit code"

# ── Case 3: self-loop ────────────────────────────────────────────────────────
start_test "T1.3 self-loop (T3→T3) → exit 1 + 'cycle' + 'Task 3'"
P=$(_mk selfloop '### Task 1: a
**Dependencies:** none
### Task 2: b
**Dependencies:** Task 1
### Task 3: c
**Dependencies:** Task 3
')
OUT=$("$V" "$P" 2>&1); RC=$?
assert_eq 1 "$RC" "exit code"
assert_contains "$OUT" "cycle" "mentions cycle"
assert_contains "$OUT" "Task 3" "names offending task"

# ── Case 4: 2-cycle (iter4 W: 2-cycle is mechanically also a forward-ref) ──
start_test "T1.4 2-cycle (T1↔T2) → exit 1 + cycle|forward (either label)"
P=$(_mk twocycle '### Task 1: a
**Dependencies:** Task 2
### Task 2: b
**Dependencies:** Task 1
')
OUT=$("$V" "$P" 2>&1); RC=$?
assert_eq 1 "$RC" "exit code"
if [[ "$OUT" == *"cycle"* || "$OUT" == *"forward"* ]]; then
  pass "labels as cycle or forward-ref (both acceptable for 2-cycle)"
else
  fail "T1.4" "expected cycle|forward in: $OUT"
fi

# ── Case 5: 3-cycle ──────────────────────────────────────────────────────────
start_test "T1.5 3-cycle (T1→T2→T3→T1) → exit 1 + 'cycle'"
P=$(_mk threecycle '### Task 1: a
**Dependencies:** Task 3
### Task 2: b
**Dependencies:** Task 1
### Task 3: c
**Dependencies:** Task 2
')
OUT=$("$V" "$P" 2>&1); RC=$?
assert_eq 1 "$RC" "exit code"
assert_contains "$OUT" "cycle" "mentions cycle"

# ── Case 6: forward-ref (T1→T3, T3 exists; rule 9 = SPLIT>RENUMBER) ──────
start_test "T1.6 forward-ref (T1→T3) → exit 1 + 'forward'"
P=$(_mk fwdref '### Task 1: a
**Dependencies:** Task 3
### Task 2: b
**Dependencies:** Task 1
### Task 3: c
**Dependencies:** Task 2
')
OUT=$("$V" "$P" 2>&1); RC=$?
assert_eq 1 "$RC" "exit code"
assert_contains "$OUT" "forward" "mentions forward-ref"

# ── Case 7: missing-dep ──────────────────────────────────────────────────────
start_test "T1.7 missing-dep (T1→T99, T99 absent) → exit 1 + 'missing' + '99'"
P=$(_mk missingdep '### Task 1: a
**Dependencies:** Task 99
### Task 2: b
**Dependencies:** Task 1
')
OUT=$("$V" "$P" 2>&1); RC=$?
assert_eq 1 "$RC" "exit code"
assert_contains "$OUT" "missing" "mentions missing"
assert_contains "$OUT" "99" "names missing task id"

# ── Case 8: no dependencies line (implicit none) ─────────────────────────────
start_test "T1.8 no '**Dependencies:**' line → exit 0 (implicit none)"
P=$(_mk nodepline '### Task 1: a

### Task 2: b
**Dependencies:** Task 1
')
"$V" "$P" >/dev/null 2>&1; assert_eq 0 "$?" "exit code"

# ── Case 9: dep value 'none' ────────────────────────────────────────────────
start_test "T1.9 dep value 'none' → exit 0"
P=$(_mk depnone '### Task 1: a
**Dependencies:** none
### Task 2: b
**Dependencies:** Task 1
')
"$V" "$P" >/dev/null 2>&1; assert_eq 0 "$?" "exit code"

# ── Case 10: trailing comma ──────────────────────────────────────────────────
start_test "T1.10 trailing comma in deps list → exit 0 (tolerated)"
P=$(_mk trailcomma '### Task 1: a
**Dependencies:** none
### Task 2: b
**Dependencies:** Task 1,
')
"$V" "$P" >/dev/null 2>&1; assert_eq 0 "$?" "exit code"

# ── Case 11: --json clean ────────────────────────────────────────────────────
start_test "T1.11 --json clean → exit 0 + JSON 'valid':true"
P=$(_mk jsonclean '### Task 1: a
**Dependencies:** none
### Task 2: b
**Dependencies:** Task 1
')
OUT=$("$V" --json "$P" 2>&1); RC=$?
assert_eq 0 "$RC" "exit code"
# Tolerate whitespace variants around the colon and value. Use grep -E to
# avoid bash regex backslash-escape pitfalls with literal `"`.
if printf '%s' "$OUT" | grep -Eq '"valid"[[:space:]]*:[[:space:]]*true'; then
  pass "JSON contains \"valid\": true"
else
  fail "T1.11" "expected \"valid\":true in: $OUT"
fi

# ── Case 12: --json cycle ────────────────────────────────────────────────────
start_test "T1.12 --json cycle → exit 1 + JSON 'cycles':[…] non-empty"
P=$(_mk jsoncycle '### Task 1: a
**Dependencies:** Task 2
### Task 2: b
**Dependencies:** Task 1
')
OUT=$("$V" --json "$P" 2>&1); RC=$?
assert_eq 1 "$RC" "exit code"
# Non-empty cycles array: at least one non-`]` non-whitespace char after the `[`.
if printf '%s' "$OUT" | grep -Eq '"cycles"[[:space:]]*:[[:space:]]*\[[[:space:]]*[^][:space:]]'; then
  pass "JSON has non-empty cycles array"
else
  fail "T1.12" "expected non-empty cycles[] in: $OUT"
fi

# ── Case 13: file-not-found → exit 2 + 'not found'|'ENOENT' ────────────────
start_test "T1.13 file-not-found → exit 2 + stderr 'not found' or 'ENOENT'"
ERR=$("$V" "$TMPROOT/__nope__.md" 2>&1 >/dev/null); RC=$?
assert_eq 2 "$RC" "exit code"
if [[ "$ERR" == *"not found"* || "$ERR" == *"ENOENT"* ]]; then
  pass "stderr mentions missing-file"
else
  fail "T1.13" "expected 'not found' or 'ENOENT' in: $ERR"
fi

# ── Case 14 (iter3 CRITICAL fix): inline-metadata fixture ──────────────────
# Real zuvo plans format task metadata INLINE on a single line:
#   **Surface:** docs · **Complexity:** complex · **Dependencies:** Task 1 · **Execution routing:** deep
# A standalone-only parser would mis-capture the dep field as
#   "Task 1 · **Execution routing:** deep"
# and report Task "1 · **Execution routing:** deep" as a missing dependency.
# Without this fixture, the validator would BLOCK its own birth plan
# (SMOKE2 self-validation would fail).
start_test "T1.14 INLINE-metadata fixture (· separator) → exit 0"
P=$(_mk inline '### Task 1: a
**Surface:** docs · **Complexity:** standard · **Dependencies:** none · **Execution routing:** default

### Task 2: b
**Surface:** backend-logic · **Complexity:** complex · **Dependencies:** Task 1 · **Execution routing:** deep
')
OUT=$("$V" "$P" 2>&1); RC=$?
assert_eq 0 "$RC" "exit code (must correctly extract just 'Task 1', not the trailing metadata)"

# Negative twin: same inline format but with a real cycle — must still fire.
start_test "T1.14b INLINE-metadata cycle → exit 1 + 'cycle'"
P=$(_mk inline_cycle '### Task 1: a
**Surface:** docs · **Complexity:** standard · **Dependencies:** Task 2 · **Execution routing:** default

### Task 2: b
**Surface:** docs · **Complexity:** standard · **Dependencies:** Task 1 · **Execution routing:** default
')
OUT=$("$V" "$P" 2>&1); RC=$?
assert_eq 1 "$RC" "exit code"
assert_contains "$OUT" "cycle" "mentions cycle"

# ── Case 15 (iter3 W fix): malformed-plan fixture ──────────────────────────
# Truly malformed markdown (no `### Task` headers / non-numeric task ids) →
# exit 2 (parse error). Distinct from file-not-found (also exit 2 but
# stderr contains "not found"/"ENOENT").
start_test "T1.15 malformed-plan (no '### Task N:' headers) → exit 2 + 'no tasks parsed' or 'malformed'"
P=$(_mk malformed '# Just a heading

Some prose with no task headers at all.

### Task abc: non-numeric id
**Dependencies:** none
')
ERR=$("$V" "$P" 2>&1 >/dev/null); RC=$?
assert_eq 2 "$RC" "exit code"
if [[ "$ERR" == *"no tasks parsed"* || "$ERR" == *"malformed"* ]]; then
  pass "stderr mentions parse-error semantics"
else
  fail "T1.15" "expected 'no tasks parsed' or 'malformed' in: $ERR"
fi

# ── Case 16 (CONDITIONAL bonus, iter3 W fix): sanity-check against a real
# shipped plan IF it exists. Skip cleanly otherwise so a fresh checkout (or
# future plan removal) does not break the test.
start_test "T1.16 CONDITIONAL: validates a real shipped v1.3.109 plan (if present)"
SHIPPED="$ROOT/docs/specs/2026-05-18-retro-checkpoint-capture-plan.md"
if [ -f "$SHIPPED" ]; then
  "$V" "$SHIPPED" >/dev/null 2>&1
  RC=$?
  assert_eq 0 "$RC" "real shipped plan validates clean"
else
  pass "skipped (no shipped plan at $SHIPPED — fresh checkout or future removal is acceptable)"
fi

# ── Adversarial-driven cases (2026-05-23 code-mode review, Gemini findings) ─

# C1: multiple positional files must not silently ignore all-but-last.
start_test "T1.17 multiple plan files rejected → exit 2 + stderr 'multiple' or 'one'"
P1=$(_mk multi1 '### Task 1: a
**Dependencies:** none
')
P2=$(_mk multi2 '### Task 1: a
**Dependencies:** Task 1
')
ERR=$("$V" "$P1" "$P2" 2>&1 >/dev/null); RC=$?
assert_eq 2 "$RC" "exit code"
if [[ "$ERR" == *"multiple"* || "$ERR" == *"one plan file"* || "$ERR" == *"only one"* ]]; then
  pass "stderr signals multi-file rejection"
else
  fail "T1.17" "expected multi-file rejection message in: $ERR"
fi

# C2: prose mention of `**Dependencies:**` must not shadow the real deps line.
start_test "T1.18 prose mention does NOT shadow real deps → cycle still detected"
P=$(_mk prose '### Task 1: a
Some narrative that says **Dependencies:** are tricky to write.
**Dependencies:** Task 2
### Task 2: b
**Dependencies:** Task 1
')
OUT=$("$V" "$P" 2>&1); RC=$?
assert_eq 1 "$RC" "exit code (cycle must still fire despite prose mention)"
assert_contains "$OUT" "cycle" "mentions cycle"

# C3: non-numeric dep token (e.g. `Build`) must NOT be silently dropped.
start_test "T1.19 non-numeric dep token → exit 2 + 'malformed' or 'non-numeric'"
P=$(_mk nonnumdep '### Task 1: a
**Dependencies:** Build
### Task 2: b
**Dependencies:** Task 1
')
ERR=$("$V" "$P" 2>&1 >/dev/null); RC=$?
assert_eq 2 "$RC" "exit code"
if [[ "$ERR" == *"malformed"* || "$ERR" == *"non-numeric"* || "$ERR" == *"invalid"* ]]; then
  pass "stderr signals non-numeric-dep"
else
  fail "T1.19" "expected non-numeric-dep diagnostic in: $ERR"
fi

# W5: redefined task ids must NOT silently drop the second block's deps.
start_test "T1.20 redefined task id → exit 2 + 'duplicate' or 'malformed'"
P=$(_mk dupid '### Task 1: a
**Dependencies:** none
### Task 1: a-redux
**Dependencies:** Task 2
### Task 2: b
**Dependencies:** Task 1
')
ERR=$("$V" "$P" 2>&1 >/dev/null); RC=$?
assert_eq 2 "$RC" "exit code"
if [[ "$ERR" == *"duplicate"* || "$ERR" == *"malformed"* || "$ERR" == *"redefined"* ]]; then
  pass "stderr signals duplicate-id"
else
  fail "T1.20" "expected duplicate-id diagnostic in: $ERR"
fi

# W4: malformed flag must NOT be bypassed when at least one valid task exists.
start_test "T1.21 malformed task header MIXED with valid → exit 2 (no silent drop)"
P=$(_mk mixedmalformed '### Task 1: a
**Dependencies:** none
### Task 2a: bad-id
**Dependencies:** Task 1
### Task 3: c
**Dependencies:** Task 1
')
ERR=$("$V" "$P" 2>&1 >/dev/null); RC=$?
assert_eq 2 "$RC" "exit code (malformed wins over otherwise-valid siblings)"
if [[ "$ERR" == *"malformed"* ]]; then
  pass "stderr signals malformed (mixed)"
else
  fail "T1.21" "expected 'malformed' in: $ERR"
fi

# W6: filename containing `=` must NOT be treated as awk var assignment (hang).
start_test "T1.22 filename with '=' is read as a file (no awk var-assignment hang)"
EQDIR="$TMPROOT/eq-dir"; mkdir -p "$EQDIR"
EQFILE="$EQDIR/plan=auth.md"
printf '### Task 1: a\n**Dependencies:** none\n### Task 2: b\n**Dependencies:** Task 1\n' > "$EQFILE"
# Wrap with a CPU/wall timeout — hang would otherwise stall the whole harness.
# Prefer perl's alarm wrapper (portable on macOS; coreutils `timeout` is GNU-only by default).
RC=$(perl -e '
  use POSIX ":sys_wait_h";
  $SIG{ALRM} = sub { kill "TERM", -$$; exit 124 };
  alarm 10;
  my $pid = fork();
  if ($pid == 0) { setpgrp; exec @ARGV; exit 127 }
  waitpid $pid, 0;
  exit ($? >> 8);
' "$V" "$EQFILE" >/dev/null 2>&1; echo $?)
assert_eq 0 "$RC" "exit code (and did not hang)"

# W7: filename containing `"` must produce parseable JSON (escape, not break it).
start_test "T1.23 JSON output escapes literal '\"' in planpath"
QDIR="$TMPROOT/q-dir"; mkdir -p "$QDIR"
QFILE="$QDIR/my\"quoted\".md"
printf '### Task 1: a\n**Dependencies:** none\n' > "$QFILE"
JOUT=$("$V" --json "$QFILE" 2>&1); JRC=$?
assert_eq 0 "$JRC" "exit code"
# A trivial structural parse: open-brace, "valid":true, close-brace, AND
# the planpath quote is escaped (\") not raw — otherwise the next `"` would
# prematurely close the plan-string.
if printf '%s' "$JOUT" | grep -Eq '^\{.*"plan":"[^"]*\\"' \
   && printf '%s' "$JOUT" | grep -Eq '"valid"[[:space:]]*:[[:space:]]*true'; then
  pass "JSON valid; quote in filename escaped to \\\""
else
  fail "T1.23" "expected escaped \\\" in plan field. Got: $JOUT"
fi

# Hermetic cleanup
rm -rf "$TMPROOT"
