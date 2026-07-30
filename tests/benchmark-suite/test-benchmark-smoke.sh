#!/usr/bin/env bash
source "$(dirname "$0")/../seo-suite/assert.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/benchmark.sh"

# NOTE: assert.sh sets `pipefail`. `echo "$out" | grep -q X` is UNSAFE here:
# grep -q exits the moment it matches, closing the pipe, so echo dies on SIGPIPE
# (141) and pipefail propagates that as the pipeline status — a false FAIL that
# only appears once $out is large enough that echo has not finished writing.
# Observed when HEAD~1 was a ~68KB commit. Use a herestring: no pipe, no SIGPIPE.

# ── --show-costs exits 0 with table ──
out=$(bash "$SCRIPT" --show-costs 2>&1)
[ $? -eq 0 ] || fail "--show-costs exited non-zero"
grep -q "codex-fast" <<< "$out" || fail "--show-costs missing codex-fast row"

# ── --prompt with --dry-run exits 0 ──
out=$(bash "$SCRIPT" --prompt "test task" --dry-run 2>&1)
[ $? -eq 0 ] || fail "--prompt --dry-run exited non-zero"
grep -q "DRY RUN" <<< "$out" || fail "--prompt --dry-run missing DRY RUN header"

# ── --provider as alias for --providers ──
out=$(bash "$SCRIPT" --provider claude --prompt "test" --dry-run 2>&1)
[ $? -eq 0 ] || fail "--provider alias exited non-zero"
grep -q "claude" <<< "$out" || fail "--provider claude not reflected in output"

# ── --compare exits 0 with orchestrator message ──
out=$(bash "$SCRIPT" --compare 2>&1)
[ $? -eq 0 ] || fail "--compare exited non-zero"
grep -q "orchestrator" <<< "$out" || fail "--compare missing orchestrator message"

# ── --replay-last exits 0 with orchestrator message ──
out=$(bash "$SCRIPT" --replay-last 2>&1)
[ $? -eq 0 ] || fail "--replay-last exited non-zero"
grep -q "orchestrator" <<< "$out" || fail "--replay-last missing orchestrator message"

# ── --json is recognized (no Unknown option) ──
out=$(bash "$SCRIPT" --json --prompt "hello" --dry-run 2>&1)
[ $? -eq 0 ] || fail "--json exited non-zero"

# ── unknown option exits 1 ──
bash "$SCRIPT" --bogus 2>/dev/null && fail "--bogus should have failed" || true

# ── --mode corpus --dry-run exits 0 ──
out=$(bash "$SCRIPT" --mode corpus --dry-run 2>&1)
[ $? -eq 0 ] || fail "--mode corpus --dry-run exited non-zero"
grep -q "corpus" <<< "$out" || fail "corpus mode not reflected in dry-run"

# ── default no-input uses diff HEAD~1 ──
out=$(bash "$SCRIPT" --dry-run 2>&1)
[ $? -eq 0 ] || fail "default diff mode --dry-run exited non-zero"
grep -q "DRY RUN" <<< "$out" || fail "default diff missing DRY RUN header"

# ── exit 3 in help/contract ──
grep -q "exit 3" "$SCRIPT" || fail "exit 3 (all providers failed) missing from runner"

pass "Behavioral smoke tests passed"
