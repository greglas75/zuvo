#!/usr/bin/env bats
#
# blind-audit-codex.bats — pins scripts/blind-audit-codex.sh as a THIN back-compat wrapper over
# `adversarial-review.sh --mode blind-audit` (docs/specs/2026-09-25-blind-audit-panel-plan.md, Task 6).
# The wrapper owns exactly four things now: the closed provider vocabulary it always accepted
# (codex/agy/gemini/claude — gemini refused, the driver's wider lane list is out of scope), input
# validation the single-provider era did BEFORE dispatching anywhere (bad --production/--test/
# --timeout/--effort must never reach the driver, and a value-less trailing flag must not abort
# under `set -e`), the flag -> env translation for --timeout/--effort/--model (the driver has no
# such flags in this mode), and the exit-code remap (including passing 124/130/143 through
# unchanged). Everything else (the prompt, dispatch, isolation, validation, merge) belongs to the
# driver and is pinned by tests/hooks/test-adversarial-blind-audit.sh.
#
# Two doubles, both hermetic (no real model CLI, no network):
#   * spy-cli (tests/hooks/fixtures/model-subprocess/spy-cli) run through the REAL driver — proves
#     the wrapper's env/argv mapping actually reaches the client the driver dispatches.
#   * a FAKE adversarial-review.sh that dumps its own environment AND argv to files and exits with
#     a caller-chosen code — used for the pure flag->env/argv translation and exit-mapping cases,
#     which are the wrapper's own concern and would otherwise be entangled with the panel library's
#     own clamp/default logic (already pinned elsewhere).
#
# Run: bats scripts/tests/blind-audit-codex.bats
bats_require_minimum_version 1.5.0

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
# ZUVO_TEST_BAC overrides which wrapper copy is exercised — same override pattern as
# tests/hooks/test-adversarial-blind-audit.sh's AR="${ZUVO_TEST_AR:-...}". Used to point the whole
# suite at a mutant copy for RED-phase proof without ever touching the real script.
SCRIPT="${ZUVO_TEST_BAC:-$ROOT/scripts/blind-audit-codex.sh}"
FIXD="$ROOT/tests/hooks/fixtures/model-subprocess"
FXBA="$ROOT/tests/hooks/fixtures/blind-audit"

setup() {
  HOME="$(mktemp -d)"
  BTMP="$HOME/tmp"; mkdir -p "$BTMP"
  SPY_BIN="$HOME/spybin"; mkdir -p "$SPY_BIN"
  for c in codex claude agy; do
    cp "$FIXD/spy-cli" "$SPY_BIN/$c"
    chmod +x "$SPY_BIN/$c"
  done
  FIX_CH="$HOME/codex-home"
  cp -R "$FIXD/codex-home" "$FIX_CH"
  SHIM="$HOME/shim"; mkdir -p "$SHIM"
  # shellcheck source=/dev/null
  . "$ROOT/tests/lib/hermetic-tools.sh"
  hermetic_link_tools "$SHIM" timeout:gtimeout gtimeout:timeout jq
  RPATH="$SHIM:$SPY_BIN:/usr/bin:/bin"

  SRC="$HOME/src"; mkdir -p "$SRC"
  PRODUCTION_FILE="$SRC/example.ts"
  TEST_FILE="$SRC/example.test.ts"
  cat > "$PRODUCTION_FILE" <<'EOF'
export function add(a, b) {
  return a + b;
}
EOF
  cat > "$TEST_FILE" <<'EOF'
it('adds numbers', () => {
  expect(add(1, 2)).toBe(3);
});
EOF

  SD="$HOME/spy-rec"; mkdir -p "$SD"
}

teardown() {
  chmod -R u+rwx "$HOME" 2>/dev/null || true
  rm -rf "$HOME"
}

# run_real <env assignment>... -- <wrapper args>... — one wrapper run through the REAL driver,
# under `env -i` (nothing ambient leaks in). ZUVO_CODEX_BIN/ZUVO_CODEX_APP_BIN default to
# /nonexistent so a codex on the tester's own PATH is never picked up by accident — a case that
# needs the codex spy overrides ZUVO_CODEX_BIN itself (a later same-key `env` assignment wins).
run_real() {
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  run --separate-stderr env -i HOME="$HOME" ZUVO_HOME="$HOME/.zuvo" TMPDIR="$BTMP" CODEX_HOME="$FIX_CH" \
    PATH="$RPATH" ZUVO_NO_CAFFEINATE=1 ZUVO_PROVIDER_BENCH=0 \
    ZUVO_CODEX_BIN=/nonexistent ZUVO_CODEX_APP_BIN=/nonexistent \
    "${envs[@]}" "$SCRIPT" "$@"
}

rec_arg_after() {
  # rec_arg_after <rec-file> <flag> — the value recorded right after an `arg=<flag>` line.
  awk -v want="arg=$2" '$0 == want { getline; print substr($0, 5); exit }' "$1"
}

# fake_driver_setup [exit_code] — a scratch copy of the wrapper next to a FAKE adversarial-review.sh
# that dumps its OWN environment to $ENVDUMP, its OWN argv (one element per line) to $ARGVDUMP, prints
# a minimal strict block, and exits with [exit_code] (default 0). Isolates the wrapper's own
# flag->env/argv translation and exit-code remap from the real driver's dispatch/merge logic, which
# tests/hooks/test-adversarial-blind-audit.sh already pins.
fake_driver_setup() {
  local exit_code="${1:-0}"
  FAKE_DIR="$HOME/fakescripts"; mkdir -p "$FAKE_DIR"
  cp "$SCRIPT" "$FAKE_DIR/blind-audit-codex.sh"
  case "$exit_code" in
    2|5)
      # Real driver contract: exit 2 (no valid answer) and 5 (empty/unauditable file) print EMPTY
      # stdout — no merged block. Mirror that here (instead of the fixed non-empty block below) so
      # T2 can assert the wrapper forwards a genuinely empty stdout for these codes, not just the
      # exit-code remap.
      cat > "$FAKE_DIR/adversarial-review.sh" <<FAKE
#!/usr/bin/env bash
env > "\$ENVDUMP"
printf '%s\n' "\$@" > "\$ARGVDUMP"
exit $exit_code
FAKE
      ;;
    *)
      cat > "$FAKE_DIR/adversarial-review.sh" <<FAKE
#!/usr/bin/env bash
env > "\$ENVDUMP"
printf '%s\n' "\$@" > "\$ARGVDUMP"
printf 'Audit mode: strict\nAudit panel: degraded valid=1/1 providers=fake verdicts=fake:CLEAN\nCoverage verdict: CLEAN\nINVENTORY COMPLETE: 0 rows\n'
exit $exit_code
FAKE
      ;;
  esac
  chmod +x "$FAKE_DIR/adversarial-review.sh"
  ENVDUMP="$HOME/env.dump"
  ARGVDUMP="$HOME/argv.dump"
}

run_fake() {
  # run_fake <wrapper args>... — run the wrapper against the fake driver set up by fake_driver_setup.
  run --separate-stderr env -i HOME="$HOME" PATH=/usr/bin:/bin ENVDUMP="$ENVDUMP" ARGVDUMP="$ARGVDUMP" \
    bash "$FAKE_DIR/blind-audit-codex.sh" "$@"
}

# ═══ P1/P2: input validation, before the driver ever runs ══════════════════

@test "P1: missing --production exits 2, 'Missing required arguments.', no dispatch" {
  run_real SPY_DIR="$SD" -- --test "$TEST_FILE"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Missing required arguments."* ]]
  [ ! -e "$SD/codex.rec" ]
}

@test "P1: missing --test exits 2, 'Missing required arguments.'" {
  run_real -- --production "$PRODUCTION_FILE"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Missing required arguments."* ]]
}

@test "P1: a nonexistent --production file exits 2, 'Missing file:', before any dispatch" {
  run_real SPY_DIR="$SD" -- --production "$SRC/does-not-exist.ts" --test "$TEST_FILE"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Missing file:"* ]]
  [ ! -e "$SD/codex.rec" ]
}

@test "P1/T10: an unreadable --test file exits 2, before any dispatch (skipped as root; teardown restores perms)" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "running as root — chmod 000 does not block a root read, so this file is not actually unreadable"
  fi
  chmod 000 "$TEST_FILE"
  # No chmod-back here: it must not depend on reaching this point (an earlier failed assertion would
  # skip it under bats' `set -e`). teardown()'s `chmod -R u+rwx "$HOME"` is the ONLY restoration path,
  # exercised on every outcome, not just this happy one.
  run_real SPY_DIR="$SD" -- --production "$PRODUCTION_FILE" --test "$TEST_FILE"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Missing file:"* ]]
  [ ! -e "$SD/codex.rec" ]
}

@test "P1: a non-numeric --timeout exits 2, 'Invalid timeout: abc'" {
  run_real -- --production "$PRODUCTION_FILE" --test "$TEST_FILE" --timeout abc
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Invalid timeout: abc"* ]]
}

@test "P1: a zero --timeout exits 2, 'Invalid timeout: 0'" {
  run_real -- --production "$PRODUCTION_FILE" --test "$TEST_FILE" --timeout 0
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Invalid timeout: 0"* ]]
}

@test "P1/P5: an empty --effort value exits 2 (caught by the shared value-needed check)" {
  run_real -- --production "$PRODUCTION_FILE" --test "$TEST_FILE" --effort ""
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"--effort needs a value"* ]]
}

@test "P2: --timeout as the last argument with no value exits 2, not an aborted shift" {
  run_real -- --production "$PRODUCTION_FILE" --test "$TEST_FILE" --timeout
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"--timeout needs a value"* ]]
}

@test "P2: --provider as the last argument with no value exits 2" {
  run_real -- --production "$PRODUCTION_FILE" --test "$TEST_FILE" --provider
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"--provider needs a value"* ]]
}

# ═══ Q11: -h/--help — usage on stdout, exit 0, driver never runs ══════════════

@test "-h: exits 0, prints usage text, driver never runs" {
  fake_driver_setup
  run_fake -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: blind-audit-codex.sh"* ]]
  [ ! -e "$ENVDUMP" ]
  [ ! -e "$ARGVDUMP" ]
}

@test "--help: exits 0, prints usage text, driver never runs" {
  fake_driver_setup
  run_fake --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: blind-audit-codex.sh"* ]]
  [ ! -e "$ENVDUMP" ]
  [ ! -e "$ARGVDUMP" ]
}

# ═══ P4: --timeout validation must not do bash arithmetic (no octal / overflow hazard) ═══════

@test "P4: --timeout 08 -> driver env gets ZUVO_BLIND_AUDIT_TIMEOUT=8, no bash octal error" {
  fake_driver_setup
  run_fake --production "$PRODUCTION_FILE" --test "$TEST_FILE" --timeout 08
  [ "$status" -eq 0 ]
  grep -qx 'ZUVO_BLIND_AUDIT_TIMEOUT=8' "$ENVDUMP"
  [[ "$stderr" != *"value too great for base"* ]]
  [[ "$stderr" != *"syntax error"* ]]
}

@test "P4: --timeout 00 exits 2, 'Invalid timeout: 00' (all zeros is not positive)" {
  run_real -- --production "$PRODUCTION_FILE" --test "$TEST_FILE" --timeout 00
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Invalid timeout: 00"* ]]
}

@test "P4: a 25-digit --timeout is forwarded unchanged, no bash arithmetic-overflow error" {
  fake_driver_setup
  BIGNUM="1234567890123456789012345"
  run_fake --production "$PRODUCTION_FILE" --test "$TEST_FILE" --timeout "$BIGNUM"
  [ "$status" -eq 0 ]
  grep -qx "ZUVO_BLIND_AUDIT_TIMEOUT=$BIGNUM" "$ENVDUMP"
  [[ "$stderr" != *"value too great for base"* ]]
  [[ "$stderr" != *"overflow"* ]]
}

@test "P4: --timeout -5 exits 2, 'Invalid timeout: -5' (single-dash value reaches its own validation)" {
  run_real -- --production "$PRODUCTION_FILE" --test "$TEST_FILE" --timeout -5
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Invalid timeout: -5"* ]]
}

# ═══ P5: a value-taking flag's value must not be empty or look like another flag ══════════════
# One check in the parser (_bac_need_value), not per flag — see the header comment.

@test "P5: --provider '' exits 2 (was: silently a full panel)" {
  run_real SPY_DIR="$SD" -- --provider "" --production "$PRODUCTION_FILE" --test "$TEST_FILE"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"--provider needs a value"* ]]
  [ ! -e "$SD/codex.rec" ]
}

@test "P5: --effort --provider codex exits 2 (the next flag is not consumed as --effort's value)" {
  run_real -- --production "$PRODUCTION_FILE" --test "$TEST_FILE" --effort --provider codex
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"--effort needs a value"* ]]
}

@test "P5: --production --test x exits 2 (--production never swallows the next flag)" {
  run_real -- --production --test x
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"--production needs a value"* ]]
}

# ═══ P6: --effort must be a bare lowercase word, not restricted to a fixed list ═══════════════

@test "P6: a whitespace-only --effort value exits 2, 'Invalid effort:'" {
  run_real -- --production "$PRODUCTION_FILE" --test "$TEST_FILE" --effort "   "
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Invalid effort:"* ]]
}

@test "P6: --effort minimal (not on any fixed list, but a bare word) is accepted and forwarded" {
  fake_driver_setup
  run_fake --production "$PRODUCTION_FILE" --test "$TEST_FILE" --effort minimal
  [ "$status" -eq 0 ]
  grep -qx 'ZUVO_BLIND_AUDIT_EFFORT=minimal' "$ENVDUMP"
}

# ═══ P7: --protocol, when given, is validated exactly like --production/--test ════════════════

@test "P7: a nonexistent --protocol exits 2, 'Missing file:', and the driver never runs" {
  run_real SPY_DIR="$SD" -- --protocol "$SRC/no-such-protocol.md" \
    --production "$PRODUCTION_FILE" --test "$TEST_FILE"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Missing file:"* ]]
  [ ! -e "$SD/codex.rec" ]
  [ ! -e "$SD/claude.rec" ]
  [ ! -e "$SD/agy.rec" ]
}

# ═══ provider mapping + panel-of-one end to end (real driver + spy) ═══════════

@test "--provider codex: codex answers strict on stdout -> exit 0, line 1 Audit mode: strict, degraded valid=1/1" {
  cp "$FXBA/clean.txt" "$SD/codex.reply"
  run_real ZUVO_CODEX_BIN="$SPY_BIN/codex" SPY_DIR="$SD" -- \
    --provider codex --production "$PRODUCTION_FILE" --test "$TEST_FILE"
  [ "$status" -eq 0 ]
  first_line="$(printf '%s\n' "$output" | sed -n '1p')"
  [ "$first_line" = "Audit mode: strict" ]
  [[ "$output" == *"Audit panel: degraded valid=1/1"* ]]
  [[ "$output" == *"providers=codex-5.3"* ]]
  [ -s "$SD/codex.rec" ]
}

# T1 (quality Q7/Q11): the wrapper's own closed-provider-vocabulary and unknown-flag errors were
# exercised only incidentally before — pin them directly.
@test "T1: --provider bogus exits 2, stderr says 'Unsupported provider'" {
  run_real SPY_DIR="$SD" -- --provider bogus --production "$PRODUCTION_FILE" --test "$TEST_FILE"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Unsupported provider"* ]]
  [ ! -e "$SD/codex.rec" ]
}

@test "T1: an unknown top-level flag exits 2, stderr says 'Unknown argument'" {
  run_real -- --bogus-flag --production "$PRODUCTION_FILE" --test "$TEST_FILE"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Unknown argument"* ]]
}

# T6 (kimi): --provider gemini now records a spy dir too, so "never dispatched" is an assertion
# on the record, not merely on stderr wording.
@test "--provider gemini: refused before any dispatch, exit 2, stderr says removed, no lane recorded" {
  run_real SPY_DIR="$SD" -- --provider gemini --production "$PRODUCTION_FILE" --test "$TEST_FILE"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"removed"* ]]
  [ ! -e "$SD/codex.rec" ]
  [ ! -e "$SD/claude.rec" ]
  [ ! -e "$SD/agy.rec" ]
}

# T7 (agy/cursor-agent): pin the actual exit status of the host-exclusion case, not just the message.
@test "CLAUDECODE=1: host-exclusion message fires, claude never invoked, exit pinned to 1" {
  cp "$FXBA/clean.txt" "$SD/claude.reply"
  run_real CLAUDECODE=1 SPY_DIR="$SD" -- \
    --provider claude --production "$PRODUCTION_FILE" --test "$TEST_FILE"
  [[ "$stderr" == *"Host detected"* ]]
  [[ "$stderr" == *"auto-excluding"* ]]
  [ ! -e "$SD/claude.rec" ]
  # --provider claude leaves zero candidates once claude is host-excluded -> the driver's own
  # "every candidate excluded" exit 1, which this wrapper's exit-mapping falls through to unchanged.
  [ "$status" -eq 1 ]
}

@test "driver exit 6 (oversize prompt) maps to wrapper exit 2" {
  BIG="$SRC/big.sh"
  # 400000 bytes is ZUVO_BLIND_AUDIT_MAX_BYTES's default (scripts/lib/blind-audit-panel.sh) — the
  # prompt (protocol + this file + the test file) must clear it, so this file alone is well over.
  LC_ALL=C awk 'BEGIN { for (j = 0; j < 85; j++) x = x "x"; for (i = 1; i <= 4200; i++) printf "# line %06d %s\n", i, x }' > "$BIG"
  run_real -- --production "$BIG" --test "$TEST_FILE"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"over the"*"byte limit"* ]]
}

# T3 (agy): a real spy run with no --provider dispatches the FULL panel (more than one lane).
@test "T3: no --provider: the real driver runs a full panel (more than one lane dispatched)" {
  cp "$FXBA/clean.txt" "$SD/codex.reply"
  cp "$FXBA/clean.txt" "$SD/claude.reply"
  cp "$FXBA/clean.txt" "$SD/agy.reply"
  run_real ZUVO_CODEX_BIN="$SPY_BIN/codex" SPY_DIR="$SD" -- \
    --production "$PRODUCTION_FILE" --test "$TEST_FILE"
  [ "$status" -eq 0 ]
  dispatched=0
  for c in codex claude agy; do
    [ -s "$SD/$c.rec" ] && dispatched=$((dispatched + 1))
  done
  [ "$dispatched" -gt 1 ]
}

# ═══ per-flag env mapping (real driver + spy: proves the mapped value actually reaches the client) ═══

@test "--provider codex --model gpt-test-x: the codex spy's config.toml carries the model" {
  cp "$FXBA/clean.txt" "$SD/codex.reply"
  run_real ZUVO_CODEX_BIN="$SPY_BIN/codex" SPY_DIR="$SD" -- \
    --provider codex --model gpt-test-x --production "$PRODUCTION_FILE" --test "$TEST_FILE"
  [ "$status" -eq 0 ]
  [ -s "$SD/codex.rec" ]
  grep -q '^config=model = "gpt-test-x"$' "$SD/codex.rec"
}

@test "--provider claude --model claude-test-y: the claude spy's argv carries --model claude-test-y" {
  cp "$FXBA/clean.txt" "$SD/claude.reply"
  run_real SPY_DIR="$SD" -- \
    --provider claude --model claude-test-y --production "$PRODUCTION_FILE" --test "$TEST_FILE"
  [ "$status" -eq 0 ]
  [ -s "$SD/claude.rec" ]
  [ "$(rec_arg_after "$SD/claude.rec" --model)" = "claude-test-y" ]
}

# T5 (byteplus-3/kimi): both the lower-priority fallback (ZUVO_MODEL_AGY) AND the higher-priority
# var the wrapper itself sets (ZUVO_AGY_MODEL) are pre-set by the caller to a DIFFERENT value —
# --model must still win over both.
@test "T5: --provider agy --model agy-test-z beats caller-exported ZUVO_MODEL_AGY=other AND ZUVO_AGY_MODEL=other" {
  cp "$FXBA/clean.txt" "$SD/agy.reply"
  run_real ZUVO_MODEL_AGY=other ZUVO_AGY_MODEL=other SPY_DIR="$SD" -- \
    --provider agy --model agy-test-z --production "$PRODUCTION_FILE" --test "$TEST_FILE"
  [ "$status" -eq 0 ]
  [ -s "$SD/agy.rec" ]
  [ "$(rec_arg_after "$SD/agy.rec" --model)" = "agy-test-z" ]
}

# ═══ pure flag->env/argv translation (fake driver double) ═══════════════════

@test "--timeout 300 --effort medium map to ZUVO_BLIND_AUDIT_TIMEOUT/EFFORT" {
  fake_driver_setup
  run_fake --production "$PRODUCTION_FILE" --test "$TEST_FILE" --timeout 300 --effort medium
  [ "$status" -eq 0 ]
  grep -qx 'ZUVO_BLIND_AUDIT_TIMEOUT=300' "$ENVDUMP"
  grep -qx 'ZUVO_BLIND_AUDIT_EFFORT=medium' "$ENVDUMP"
}

@test "no flags: ZUVO_BLIND_AUDIT_TIMEOUT is NOT set by the wrapper (no clamp warning)" {
  fake_driver_setup
  run_fake --production "$PRODUCTION_FILE" --test "$TEST_FILE"
  [ "$status" -eq 0 ]
  ! grep -q '^ZUVO_BLIND_AUDIT_TIMEOUT=' "$ENVDUMP"
  ! grep -q '^ZUVO_BLIND_AUDIT_EFFORT=' "$ENVDUMP"
}

@test "--model without --provider: ignored, with a WARN, no model env var exported" {
  fake_driver_setup
  run_fake --production "$PRODUCTION_FILE" --test "$TEST_FILE" --model some-model
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"WARN"* ]]
  [[ "$stderr" == *"--model"* ]]
  ! grep -qE '^(ZUVO_MODEL_CODEX_PRIMARY|ZUVO_CLAUDE_REVIEWER_MODEL|ZUVO_MODEL_CLAUDE_REVIEWER_OPUS|ZUVO_AGY_MODEL)=' "$ENVDUMP"
}

# T4 (byteplus-3): independent of the claude spy's argv (asserted above) — both env vars must reach
# the driver's OWN process environment, not just whichever one the spy happened to read.
@test "T4: --provider claude --model: BOTH ZUVO_CLAUDE_REVIEWER_MODEL and ZUVO_MODEL_CLAUDE_REVIEWER_OPUS reach the driver's env" {
  fake_driver_setup
  run_fake --provider claude --model claude-test-y --production "$PRODUCTION_FILE" --test "$TEST_FILE"
  [ "$status" -eq 0 ]
  grep -qx 'ZUVO_CLAUDE_REVIEWER_MODEL=claude-test-y' "$ENVDUMP"
  grep -qx 'ZUVO_MODEL_CLAUDE_REVIEWER_OPUS=claude-test-y' "$ENVDUMP"
}

# T3 (agy): the fake driver's argv is asserted directly now, not merely described in a comment.
@test "T3: argv forwarding — --mode blind-audit, provider translation, and file paths reach the driver" {
  fake_driver_setup
  run_fake --provider codex --production "$PRODUCTION_FILE" --test "$TEST_FILE"
  [ "$status" -eq 0 ]
  grep -qx -- '--mode' "$ARGVDUMP"
  grep -qx -- 'blind-audit' "$ARGVDUMP"
  grep -qx -- '--provider' "$ARGVDUMP"
  grep -qx -- 'codex-5.3' "$ARGVDUMP"
  grep -qx -- "$PRODUCTION_FILE" "$ARGVDUMP"
  grep -qx -- "$TEST_FILE" "$ARGVDUMP"
}

@test "T3: argv forwarding — no --provider is forwarded when none was given" {
  fake_driver_setup
  run_fake --production "$PRODUCTION_FILE" --test "$TEST_FILE"
  [ "$status" -eq 0 ]
  ! grep -qx -- '--provider' "$ARGVDUMP"
}

# T2 (byteplus-3/cursor-agent/codex-5.3): pin EVERY driver-exit -> wrapper-exit mapping, not just
# the two the old fake driver could produce (it always exited 0).
@test "T2/T11/P8: exit code mapping — every driver status maps as documented" {
  # 125 (suspended), 7 (plan-budget) and 128 fall into the "anything else" bucket -> 1, same as a
  # plain 1/2; 124 and every 129-255 (a signal: 130 SIGINT, 137 SIGKILL, 143 SIGTERM, …) forward
  # unchanged.
  for pair in 0:0 3:0 5:2 6:2 1:1 2:1 7:1 124:124 125:1 128:1 129:129 130:130 137:137 143:143; do
    driver_code="${pair%%:*}"
    want="${pair##*:}"
    fake_driver_setup "$driver_code"
    run_fake --production "$PRODUCTION_FILE" --test "$TEST_FILE"
    [ "$status" -eq "$want" ] || { echo "driver exit $driver_code -> wrapper exit $status, want $want" >&2; return 1; }
    # driver 2 (no valid answer) / 5 (empty file): the real driver's stdout is EMPTY for these —
    # fake_driver_setup mirrors that now, so confirm the wrapper actually forwards it empty instead
    # of only checking the exit-code remap.
    case "$driver_code" in
      2|5) [ -z "$output" ] || { echo "driver exit $driver_code -> wrapper stdout not empty: $output" >&2; return 1; } ;;
    esac
  done
}

# T9 (byteplus-3): the driver lookup order — sibling wins over ~/.zuvo, and ~/.zuvo is used only
# when there is no sibling. Fake drivers that print their own identity, nothing else.
@test "T9: driver lookup — a sibling adversarial-review.sh wins over \$HOME/.zuvo/adversarial-review" {
  FAKE_DIR="$HOME/fakescripts"; mkdir -p "$FAKE_DIR"
  cp "$SCRIPT" "$FAKE_DIR/blind-audit-codex.sh"
  cat > "$FAKE_DIR/adversarial-review.sh" <<'EOF'
#!/usr/bin/env bash
echo "IDENTITY sibling"
EOF
  chmod +x "$FAKE_DIR/adversarial-review.sh"
  mkdir -p "$HOME/.zuvo"
  cat > "$HOME/.zuvo/adversarial-review" <<'EOF'
#!/usr/bin/env bash
echo "IDENTITY home"
EOF
  chmod +x "$HOME/.zuvo/adversarial-review"
  run --separate-stderr env -i HOME="$HOME" PATH=/usr/bin:/bin \
    bash "$FAKE_DIR/blind-audit-codex.sh" --production "$PRODUCTION_FILE" --test "$TEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"IDENTITY sibling"* ]]
}

@test "T9: driver lookup — \$HOME/.zuvo/adversarial-review is used when there is no sibling" {
  FAKE_DIR="$HOME/fakescripts"; mkdir -p "$FAKE_DIR"
  cp "$SCRIPT" "$FAKE_DIR/blind-audit-codex.sh"
  # deliberately NO adversarial-review.sh next to it
  mkdir -p "$HOME/.zuvo"
  cat > "$HOME/.zuvo/adversarial-review" <<'EOF'
#!/usr/bin/env bash
echo "IDENTITY home"
EOF
  chmod +x "$HOME/.zuvo/adversarial-review"
  run --separate-stderr env -i HOME="$HOME" PATH=/usr/bin:/bin \
    bash "$FAKE_DIR/blind-audit-codex.sh" --production "$PRODUCTION_FILE" --test "$TEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"IDENTITY home"* ]]
}

@test "T9/Q11: driver lookup — neither a sibling nor \$HOME/.zuvo/adversarial-review exists -> exit 1, exact 'cannot find' message" {
  FAKE_DIR="$HOME/fakescripts"; mkdir -p "$FAKE_DIR"
  cp "$SCRIPT" "$FAKE_DIR/blind-audit-codex.sh"
  # deliberately NO sibling adversarial-review.sh next to it, and setup() never created
  # $HOME/.zuvo at all in this fresh per-test $HOME, so the fallback candidate is absent too.
  [ ! -e "$HOME/.zuvo/adversarial-review" ]
  run --separate-stderr env -i HOME="$HOME" PATH=/usr/bin:/bin \
    bash "$FAKE_DIR/blind-audit-codex.sh" --production "$PRODUCTION_FILE" --test "$TEST_FILE"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"blind-audit-codex: cannot find adversarial-review.sh (looked next to this script"* ]]
  [[ "$stderr" == *"and at \$HOME/.zuvo/adversarial-review) — reinstall: ./scripts/install.sh"* ]]
}

# T9/Q11 iteration 2: the BARE-FILENAME SCRIPT_DIR fallback (scripts/blind-audit-codex.sh:~217,
# the `?*)` arm of `case "$_bac_src"`) — reached only when `${BASH_SOURCE[0]:-$0}` has NO slash at
# all, which every OTHER test in this file avoids by construction (`bash "$FAKE_DIR/blind-audit-
# codex.sh"` always has a `/`). Positive: `cd` into the wrapper's own directory and invoke it as
# `bash blind-audit-codex.sh …` — bash then opens the file by that exact bare name relative to
# $PWD, so BASH_SOURCE[0] is bare AND `$PWD/$_bac_src` exists, and SCRIPT_DIR must resolve to $PWD.
@test "Q11: bare-filename invocation ('bash blind-audit-codex.sh', no slash) resolves SCRIPT_DIR via \$PWD, sibling wins" {
  FAKE_DIR="$HOME/barefiles"; mkdir -p "$FAKE_DIR"
  cp "$SCRIPT" "$FAKE_DIR/blind-audit-codex.sh"
  cat > "$FAKE_DIR/adversarial-review.sh" <<'EOF'
#!/usr/bin/env bash
echo "IDENTITY sibling-bare"
EOF
  chmod +x "$FAKE_DIR/adversarial-review.sh"
  run --separate-stderr env -i HOME="$HOME" PATH=/usr/bin:/bin bash -c \
    'cd "$1" && bash blind-audit-codex.sh --production "$2" --test "$3"' \
    _ "$FAKE_DIR" "$PRODUCTION_FILE" "$TEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"IDENTITY sibling-bare"* ]]
}

# Negative: a bare BASH_SOURCE[0] whose file is genuinely NOT in $PWD. This cannot be produced by
# any real invocation of THIS script — bash's own top-level script argument is either given with a
# slash (records the full/relative path, the OTHER case arm) or bare (in which case bash could only
# have opened it via $PWD in the first place, so the file is necessarily there — confirmed empirically:
# a bare name resolved through `source`/`.`'s OWN $PATH search still gets rewritten to the found
# FULL path by bash, never left bare, so that route doesn't reach this arm either). The only way to
# decouple "BASH_SOURCE[0] is bare" from "the file lives at that bare name under $PWD" is to control
# `$0` directly: `bash -c 'CODE' bare-name.sh` leaves `BASH_SOURCE[0]` UNSET for inlined -c code, so
# `${BASH_SOURCE[0]:-$0}` falls through to `$0`, which is exactly the literal word we pass after the
# -c string (confirmed empirically) — independent of where any real file sits. This is a direct probe
# of the fallback branch's ROBUSTNESS, not a realistic user command line; the two sibling scripts
# that share this exact resolution idiom (adversarial-review.sh, reviewer-preflight.sh) document the
# same "a bare name only when that file is in $PWD" invariant, which is precisely why no NATURAL
# invocation can violate it — proving the negative needs to force $0 directly.
@test "Q11: a bare \$0 whose file is NOT in \$PWD resolves no SCRIPT_DIR, falls through to \$HOME/.zuvo" {
  NEG_DIR="$HOME/nobarefile"; mkdir -p "$NEG_DIR"   # deliberately no blind-audit-codex.sh here
  mkdir -p "$HOME/.zuvo"
  cat > "$HOME/.zuvo/adversarial-review" <<'EOF'
#!/usr/bin/env bash
echo "IDENTITY home-bare-fallback"
EOF
  chmod +x "$HOME/.zuvo/adversarial-review"
  SRC_TEXT="$(cat "$SCRIPT")"
  run --separate-stderr env -i HOME="$HOME" PATH=/usr/bin:/bin bash -c \
    'cd "$1" && bash -c "$2" blind-audit-codex.sh --production "$3" --test "$4"' \
    _ "$NEG_DIR" "$SRC_TEXT" "$PRODUCTION_FILE" "$TEST_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"IDENTITY home-bare-fallback"* ]]
}

@test "Q11: a bare \$0 whose file is NOT in \$PWD, and no \$HOME/.zuvo fallback either -> exit 1, 'cannot find', no SCRIPT_DIR hint" {
  NEG_DIR="$HOME/nobarefile2"; mkdir -p "$NEG_DIR"   # deliberately no blind-audit-codex.sh here
  [ ! -e "$HOME/.zuvo/adversarial-review" ]
  SRC_TEXT="$(cat "$SCRIPT")"
  run --separate-stderr env -i HOME="$HOME" PATH=/usr/bin:/bin bash -c \
    'cd "$1" && bash -c "$2" blind-audit-codex.sh --production "$3" --test "$4"' \
    _ "$NEG_DIR" "$SRC_TEXT" "$PRODUCTION_FILE" "$TEST_FILE"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"blind-audit-codex: cannot find adversarial-review.sh (looked next to this script and at \$HOME/.zuvo/adversarial-review) — reinstall: ./scripts/install.sh"* ]]
}

# ═══ source lint ═══════════════════════════════════════════════════════════

# T8/T12 (codex-5.3/cursor-agent/byteplus-3): strip BOTH whole-line comments and INLINE trailing
# comments before matching, so a future comment that mentions either phrase (explaining why NOT to
# do it, or the phrase moved into a trailing `# …`) cannot flip this lint red — or green — on its
# own; and a POSITIVE check that the wrapper actually invokes the driver's blind-audit mode IN CODE.
# `(^|[[:space:]])#` strips a `#` that starts a comment (line-start or preceded by whitespace) but
# leaves a parameter-expansion `#` alone (e.g. `${VAR#pattern}`, used a few lines above for the
# --timeout leading-zero strip, is never preceded by whitespace).
strip_comments() {
  sed -E 's/(^|[[:space:]])#.*$//' "$1"
}

@test "T8: source lint — no own codex exec, no own INVENTORY COMPLETE grep (code only), and invokes --mode blind-audit" {
  code="$(strip_comments "$SCRIPT")"
  ! printf '%s' "$code" | grep -q 'codex exec'
  ! printf '%s' "$code" | grep -q 'INVENTORY COMPLETE'
  # Anchored to the actual argv-building line, not merely the phrase — usage()'s heredoc also
  # PRINTS "--mode blind-audit" (as help text for the user), which is not an invocation and must not
  # satisfy this check on its own; T12 below proves exactly that distinction with a mutant.
  printf '%s' "$code" | grep -q -- 'DRIVER_ARGS=(--mode blind-audit)'
}

@test "T12: the positive --mode blind-audit check is defeated by a mutant that moves it into a trailing comment" {
  # Sanity: stripping comments from the REAL script still finds the anchored invocation pattern —
  # proves strip_comments does not eat the real occurrence along with the comment ones.
  printf '%s' "$(strip_comments "$SCRIPT")" | grep -q -- 'DRIVER_ARGS=(--mode blind-audit)'

  MUT="$HOME/mutant-wrapper.sh"
  sed 's/DRIVER_ARGS=(--mode blind-audit)/DRIVER_ARGS=()  # DRIVER_ARGS=(--mode blind-audit) (moved into a comment by this mutant)/' \
    "$SCRIPT" > "$MUT"
  # Premise: the mutant actually removed the CODE occurrence, not merely added another comment one.
  ! grep -q '^DRIVER_ARGS=(--mode blind-audit)$' "$MUT"
  code="$(strip_comments "$MUT")"
  ! printf '%s' "$code" | grep -q -- 'DRIVER_ARGS=(--mode blind-audit)'
}
