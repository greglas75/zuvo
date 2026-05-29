#!/usr/bin/env bash
# test-skill-usage-escaping.sh — M5 fix: skill-usage-logger.sh must emit exactly
# ONE jq-valid JSON line per invocation even when the skill args carry a
# double-quote, real newline, tab, backslash, and apostrophe (the payloads that
# made 1845/2518 lines unparseable). Empty/garbage stdin -> exit 0, no crash.

LOGGER="$ROOT/hooks/skill-usage-logger.sh"
_o=""; _oc(){ for d in $_o; do rm -rf "$d" 2>/dev/null; done; }; trap _oc EXIT INT TERM
_home(){ local d; d=$(mktemp -d); _o="$_o $d"; mkdir -p "$d/.claude"; printf '%s' "$d"; }

command -v jq >/dev/null 2>&1 || { start_test "skill-usage escaping (jq present?)"; pass "skipped — jq not on host"; return 0 2>/dev/null || exit 0; }

start_test "hostile payload -> exactly ONE valid JSON line, args byte-exact"
H=$(_home); LOG="$H/.claude/skill-usage.jsonl"
NASTY=$(printf 'l1 "quoted"\nl2\twith tab \\ and back, it'"'"'s nasty')
PAYLOAD=$(jq -nc --arg a "$NASTY" '{tool_input:{skill:"zuvo:execute",args:$a},cwd:"/Users/x/DEV/QuotasMobi",session_id:"abc-123"}')
printf '%s' "$PAYLOAD" | HOME="$H" bash "$LOGGER"
n=$(wc -l < "$LOG" | tr -d ' ')
assert_eq 1 "$n" "exactly one physical line written"
if jq -e . "$LOG" >/dev/null 2>&1; then pass "line is valid JSON"; else fail "valid json" "jq rejected the line"; fi
got=$(jq -r '.args' "$LOG")
assert_eq "$NASTY" "$got" "args round-trips byte-exact (newline/tab/backslash/quote preserved)"
assert_eq "QuotasMobi" "$(jq -r '.project' "$LOG")" "project = cwd basename"
assert_eq "zuvo:execute" "$(jq -r '.skill' "$LOG")" "skill captured"

start_test "empty stdin -> exit 0, no crash, no line"
H=$(_home); LOG="$H/.claude/skill-usage.jsonl"
printf '' | HOME="$H" bash "$LOGGER"; rc=$?
assert_exit_code 0 "$rc" "empty stdin exits 0 (non-blocking)"
assert_eq 0 "$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')" "no line written for empty input"

start_test "non-JSON stdin -> exit 0, no crash, no corrupt line"
H=$(_home); LOG="$H/.claude/skill-usage.jsonl"
printf 'this is not json at all' | HOME="$H" bash "$LOGGER"; rc=$?
assert_exit_code 0 "$rc" "garbage stdin exits 0 (non-blocking)"
n=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
# Either 0 lines, or if jq emitted something it must still be valid JSON.
if [ "${n:-0}" -eq 0 ]; then
  pass "no line written for non-JSON input"
else
  jq -e . "$LOG" >/dev/null 2>&1 && pass "any emitted line is still valid JSON" || fail "garbage" "corrupt line written"
fi

start_test "10 hostile invocations -> 10 lines, ALL valid (no global reader abort)"
H=$(_home); LOG="$H/.claude/skill-usage.jsonl"
i=0; while [ "$i" -lt 10 ]; do
  P=$(jq -nc --arg a "args $i with \" and"$'\n'"newline" '{tool_input:{skill:"zuvo:x",args:$a},cwd:"/a/b",session_id:"s"}')
  printf '%s' "$P" | HOME="$H" bash "$LOGGER"; i=$((i+1))
done
assert_eq 10 "$(wc -l < "$LOG" | tr -d ' ')" "10 lines for 10 invocations"
valid=$(jq -e . "$LOG" >/dev/null 2>&1 && echo ok || echo bad)
# jq -e over the whole file: with -c one-object-per-line, slurp-less read parses each.
allvalid=$(awk 'END{print NR}' "$LOG"); bad=0
while IFS= read -r ln; do printf '%s' "$ln" | jq -e . >/dev/null 2>&1 || bad=$((bad+1)); done < "$LOG"
assert_eq 0 "$bad" "every one of the 10 lines parses (no shattered records)"
