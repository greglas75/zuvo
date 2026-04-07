#!/usr/bin/env bash
source "$(dirname "$0")/../seo-suite/assert.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/benchmark.sh"
assert_contains "$SCRIPT" "raw_results.json"
# Has parallel execution loop
assert_contains "$SCRIPT" "PIDS+="
assert_contains "$SCRIPT" "wait \$pid"
# Has per-provider timing
assert_contains "$SCRIPT" "time_start"
assert_contains "$SCRIPT" "response_time_s"
# Has JSON assembly with jq
assert_contains "$SCRIPT" "jq -n"
# Has --show-costs flag
assert_contains "$SCRIPT" "show-costs"
# Has all exit codes documented
assert_contains "$SCRIPT" "exit 0"
assert_contains "$SCRIPT" "exit 1"
assert_contains "$SCRIPT" "exit 2"
assert_contains "$SCRIPT" "exit 3"
pass "benchmark.sh execution loop contracts verified"
