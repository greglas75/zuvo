#!/usr/bin/env bash
# test-todo-watchdog.sh — the todo-keyed stall watchdog for normal (non-skill)
# work: the heartbeat hook + the TodoWrite arm hook.
#
# These give ad-hoc multi-step work the same auto-resume the skills get, keyed
# off the TodoWrite list as the "done" signal. The contract that must hold:
#   - the beat is touched on real activity but NOT by the watchdog's own poll
#   - open-todo count excludes completed items
#   - the arm injection is valid PostToolUse JSON, carries the session tag and a
#     CronCreate instruction, and is emitted ONCE (idempotent), never when the
#     list is fully completed.

HB="$ROOT/hooks/zuvo-heartbeat.sh"
TW="$ROOT/hooks/zuvo-todo-watchdog.sh"
_o=""; _oc(){ for d in $_o; do rm -rf "$d" 2>/dev/null; done; }; trap _oc EXIT INT TERM
_z(){ local d; d=$(mktemp -d); _o="$_o $d"; printf '%s' "$d"; }

start_test "both hook scripts exist and are executable"
assert_exit_code 0 "$([ -x "$HB" ]; echo $?)" "zuvo-heartbeat.sh executable"
assert_exit_code 0 "$([ -x "$TW" ]; echo $?)" "zuvo-todo-watchdog.sh executable"

start_test "heartbeat touches the per-session beat on a normal tool call"
Z=$(_z)
printf '{"session_id":"S1","tool_name":"Bash","tool_input":{"command":"ls"}}' | ZUVO_HOME="$Z" bash "$HB"
assert_exit_code 0 "$([ -f "$Z/heartbeats/S1.beat" ]; echo $?)" "beat file created"

start_test "heartbeat does NOT touch the beat for the watchdog's own poll"
Z=$(_z)
printf '{"session_id":"S1","tool_name":"Bash","tool_input":{"command":"/x/zuvo-watchdog-check b 150"}}' | ZUVO_HOME="$Z" bash "$HB"
assert_exit_code 1 "$([ -f "$Z/heartbeats/S1.beat" ]; echo $?)" "beat NOT created for poll command"

start_test "heartbeat is a no-op without a session id"
Z=$(_z)
printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | ZUVO_HOME="$Z" bash "$HB"
assert_exit_code 1 "$([ -d "$Z/heartbeats" ] && [ -n "$(ls -A "$Z/heartbeats" 2>/dev/null)" ]; echo $?)" "no beat without session_id"

start_test "todo hook counts only OPEN todos (completed excluded)"
Z=$(_z)
printf '{"session_id":"S9","tool_name":"TodoWrite","tool_input":{"todos":[{"status":"completed"},{"status":"in_progress"},{"status":"pending"}]}}' | ZUVO_HOME="$Z" bash "$TW" >/dev/null
assert_eq "2" "$(cat "$Z/heartbeats/S9.todos" 2>/dev/null)" "2 open (1 completed excluded)"

start_test "todo hook injects a valid PostToolUse arm instruction when work is open"
Z=$(_z)
OUT=$(printf '{"session_id":"S9","tool_name":"TodoWrite","tool_input":{"todos":[{"status":"pending"},{"status":"completed"}]}}' | ZUVO_HOME="$Z" bash "$TW")
assert_exit_code 0 "$(printf '%s' "$OUT" | jq -e '.hookSpecificOutput.hookEventName=="PostToolUse"' >/dev/null 2>&1; echo $?)" "valid PostToolUse JSON"
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "$CTX" "zuvo-todo-watchdog session=S9" "carries the session tag"
assert_contains "$CTX" "CronCreate" "instructs CronCreate"
assert_contains "$CTX" "*/3 * * * *" "every-3-min schedule"
assert_contains "$CTX" "zuvo-watchdog-check" "cron prompt runs the verdict check"

start_test "todo hook is idempotent — second TodoWrite emits nothing (armed flag)"
Z=$(_z)
printf '{"session_id":"S9","tool_name":"TodoWrite","tool_input":{"todos":[{"status":"pending"}]}}' | ZUVO_HOME="$Z" bash "$TW" >/dev/null
OUT2=$(printf '{"session_id":"S9","tool_name":"TodoWrite","tool_input":{"todos":[{"status":"in_progress"}]}}' | ZUVO_HOME="$Z" bash "$TW")
assert_eq "" "$OUT2" "no re-injection once armed"

start_test "todo hook emits nothing when all todos are completed (0 open)"
Z=$(_z)
OUT3=$(printf '{"session_id":"S5","tool_name":"TodoWrite","tool_input":{"todos":[{"status":"completed"},{"status":"completed"}]}}' | ZUVO_HOME="$Z" bash "$TW")
assert_eq "0" "$(cat "$Z/heartbeats/S5.todos" 2>/dev/null)" "0 open recorded"
assert_eq "" "$OUT3" "no arm injection when nothing is open"

start_test "hooks.json registers heartbeat (match-all, async) and todo-watchdog (TodoWrite, sync)"
HJ=$(cat "$ROOT/hooks/hooks.json")
assert_contains "$HJ" "zuvo-heartbeat.sh" "heartbeat hook registered"
assert_contains "$HJ" "zuvo-todo-watchdog.sh" "todo-watchdog hook registered"
# heartbeat must be match-all + async:true; todo-watchdog must be sync (async:false)
assert_exit_code 0 "$(printf '%s' "$HJ" | jq -e '.hooks.PostToolUse[] | select(.matcher=="*") | .hooks[] | select(.command|test("zuvo-heartbeat")) | .async==true' >/dev/null 2>&1; echo $?)" "heartbeat is matcher '*' + async"
assert_exit_code 0 "$(printf '%s' "$HJ" | jq -e '.hooks.PostToolUse[] | select(.matcher=="TodoWrite") | .hooks[] | select(.command|test("zuvo-todo-watchdog")) | .async==false' >/dev/null 2>&1; echo $?)" "todo-watchdog is matcher 'TodoWrite' + sync"

start_test "include documents the todo-keyed watcher + honest limits"
INC=$(cat "$ROOT/shared/includes/stall-recovery.md")
assert_contains "$INC" "todo-keyed watchdog" "normal-work section present"
assert_contains "$INC" "/loop 3m" "single-shot fallback documented"
