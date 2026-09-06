#!/usr/bin/env bash
# Medium integration test: real CLI and deterministic git history, no provider dispatch.
source "$(dirname "$0")/../seo-suite/assert.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/benchmark.sh"
# Dry-run coverage must work on a test host without authenticated provider CLIs.
MOCK_BIN="$(mktemp -d)"; trap 'rm -rf "$MOCK_BIN"' EXIT
printf '#!/bin/sh\nexit 99\n' > "$MOCK_BIN/claude"
chmod +x "$MOCK_BIN/claude"
export PATH="$MOCK_BIN:$PATH"

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
(
# Source-only farm mirrors and shallow clones do not supply HEAD~1. Give the real
# benchmark CLI a two-commit fixture, scoped to the case that consumes history.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
mkdir "$MOCK_BIN/repo"
cd "$MOCK_BIN/repo" || exit 1
git init -q
git config user.name Test
git config user.email test@example.invalid
git config core.hooksPath /dev/null
printf 'baseline\n' > sample.txt
git add sample.txt
git commit -qm baseline
printf 'latest-change\n' > sample.txt
git add sample.txt
git commit -qm change
out=$(bash "$SCRIPT" --dry-run 2>&1) || fail "default diff mode --dry-run exited non-zero: $out"
grep -q "DRY RUN" <<< "$out" || fail "default diff missing DRY RUN header"
grep -Fq -- '-baseline' <<< "$out" || fail "default diff omitted the previous committed content"
grep -Fq -- '+latest-change' <<< "$out" || fail "default diff omitted the latest committed content"
)

# ── exit 3 in help/contract ──
grep -q "exit 3" "$SCRIPT" || fail "exit 3 (all providers failed) missing from runner"

pass "Behavioral smoke tests passed"
