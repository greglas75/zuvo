#!/usr/bin/env bash
source "$(dirname "$0")/../seo-suite/assert.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/benchmark.sh"
assert_contains "$SCRIPT" "estimate_tokens()"
assert_contains "$SCRIPT" "extract_self_eval_score()"
assert_contains "$SCRIPT" "calc_cost()"
assert_contains "$SCRIPT" "run_static_checks_ts()"
assert_contains "$SCRIPT" "run_static_checks_jest()"
# Token estimation uses 1.3 multiplier
assert_contains "$SCRIPT" "1.3"
# Self-eval parses SELF_EVAL_SUMMARY block
assert_contains "$SCRIPT" "SELF_EVAL_SUMMARY"
# Token estimates flagged with ~
assert_contains "$SCRIPT" "~estimated"
# Static checks graceful if not in PATH
assert_contains "$SCRIPT" "command -v tsc"
assert_contains "$SCRIPT" "command -v jest"
pass "benchmark.sh accounting functions verified"
