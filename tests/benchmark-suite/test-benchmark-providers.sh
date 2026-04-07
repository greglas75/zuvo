#!/usr/bin/env bash
source "$(dirname "$0")/../seo-suite/assert.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/benchmark.sh"
assert_file_exists "$SCRIPT"
# Is executable
[ -x "$SCRIPT" ] || fail "benchmark.sh is not executable"
# Has shebang
assert_contains "$SCRIPT" "#!/usr/bin/env bash"
# Has copied core functions
assert_contains "$SCRIPT" "collect_input()"
assert_contains "$SCRIPT" "detect_providers()"
assert_contains "$SCRIPT" "dispatch_provider()"
assert_contains "$SCRIPT" "run_claude()"
assert_contains "$SCRIPT" "run_codex_fast()"
assert_contains "$SCRIPT" "run_gemini()"
assert_contains "$SCRIPT" "run_gemini_api()"
assert_contains "$SCRIPT" "run_cursor_agent()"
# Has cleanup trap
assert_contains "$SCRIPT" "trap cleanup EXIT"
# Has timeout config
assert_contains "$SCRIPT" "PROVIDER_TIMEOUT"
# Has 0-providers guard
assert_contains "$SCRIPT" "No providers available"
# Has cost table
assert_contains "$SCRIPT" "COST_IN"
assert_contains "$SCRIPT" "COST_OUT"
pass "benchmark.sh provider dispatch contracts verified"
