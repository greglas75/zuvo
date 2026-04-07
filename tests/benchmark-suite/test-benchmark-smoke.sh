#!/usr/bin/env bash
source "$(dirname "$0")/../seo-suite/assert.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/benchmark.sh"

# ── --show-costs exits 0 with table ──
out=$(bash "$SCRIPT" --show-costs 2>&1)
[ $? -eq 0 ] || fail "--show-costs exited non-zero"
echo "$out" | grep -q "codex-fast" || fail "--show-costs missing codex-fast row"

# ── --prompt with --dry-run exits 0 ──
out=$(bash "$SCRIPT" --prompt "test task" --dry-run 2>&1)
[ $? -eq 0 ] || fail "--prompt --dry-run exited non-zero"
echo "$out" | grep -q "DRY RUN" || fail "--prompt --dry-run missing DRY RUN header"

# ── --provider as alias for --providers ──
out=$(bash "$SCRIPT" --provider claude --prompt "test" --dry-run 2>&1)
[ $? -eq 0 ] || fail "--provider alias exited non-zero"
echo "$out" | grep -q "claude" || fail "--provider claude not reflected in output"

# ── --compare exits 0 with orchestrator message ──
out=$(bash "$SCRIPT" --compare 2>&1)
[ $? -eq 0 ] || fail "--compare exited non-zero"
echo "$out" | grep -q "orchestrator" || fail "--compare missing orchestrator message"

# ── --replay-last exits 0 with orchestrator message ──
out=$(bash "$SCRIPT" --replay-last 2>&1)
[ $? -eq 0 ] || fail "--replay-last exited non-zero"
echo "$out" | grep -q "orchestrator" || fail "--replay-last missing orchestrator message"

# ── --json is recognized (no Unknown option) ──
out=$(bash "$SCRIPT" --json --prompt "hello" --dry-run 2>&1)
[ $? -eq 0 ] || fail "--json exited non-zero"

# ── unknown option exits 1 ──
bash "$SCRIPT" --bogus 2>/dev/null && fail "--bogus should have failed" || true

# ── --mode corpus --dry-run exits 0 ──
out=$(bash "$SCRIPT" --mode corpus --dry-run 2>&1)
[ $? -eq 0 ] || fail "--mode corpus --dry-run exited non-zero"
echo "$out" | grep -q "corpus" || fail "corpus mode not reflected in dry-run"

# ── default no-input uses diff HEAD~1 ──
out=$(bash "$SCRIPT" --dry-run 2>&1)
[ $? -eq 0 ] || fail "default diff mode --dry-run exited non-zero"
echo "$out" | grep -q "DRY RUN" || fail "default diff missing DRY RUN header"

# ── exit 3 in help/contract ──
grep -q "exit 3" "$SCRIPT" || fail "exit 3 (all providers failed) missing from runner"

pass "Behavioral smoke tests passed"
