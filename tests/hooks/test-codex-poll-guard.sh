#!/usr/bin/env bash
# Contract for codex-poll-guard — the refusal that replaces a rule which did not work.
#
# The rule came first, in env-compat.md, and was measured to change nothing: every polling session
# had READ it before polling, and not one of 14 waits used the value it asks for. The tool's own
# description carries "cap at 30000 ms" and the model sees that on every call. So this is a hook.
#
# Because it sits in front of EVERY tool call, the false-positive cases below matter more than the
# true-positive one: a guard that blocks legitimate work gets switched off, and then protects
# nothing. Most of this file is about what it must NOT refuse.
#
# bash 3.2-compatible (macOS default).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/codex-poll-guard.sh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }
[ -f "$HOOK" ] || { bad "hooks/codex-poll-guard.sh does not exist"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# decision <js-source>  → prints "deny" or "allow"
decision() {
  python3 - "$1" > "$TMP/in.json" <<'PY'
import json, sys
json.dump({"hook_event_name": "pre_tool_use", "tool_input": {"input": sys.argv[1]}}, sys.stdout)
PY
  out=$(bash "$HOOK" < "$TMP/in.json" 2>/dev/null)
  if [ -z "$out" ]; then echo "allow"; return; fi
  printf '%s' "$out" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    print(d["hookSpecificOutput"]["permissionDecision"])
except Exception as e:
    print("INVALID_JSON:%s" % e)
'
}

# ── it must REFUSE the shape that costs the tokens ───────────────────────────
d=$(decision 'const r = await tools.write_stdin({"session_id":7,"chars":"","yield_time_ms":30000});')
[ "$d" = "deny" ] && pass "an empty write_stdin poll at 30000 ms is refused" \
  || bad "the dominant poll shape was allowed ($d)"

d=$(decision 'tools.wait_agent({"timeout_ms":1000});')
[ "$d" = "deny" ] && pass "wait_agent at 1000 ms is refused" \
  || bad "a one-second agent poll was allowed ($d)"

# ── and it must NOT refuse anything else ─────────────────────────────────────
d=$(decision 'tools.write_stdin({"chars":"","yield_time_ms":300000});')
[ "$d" = "allow" ] && pass "an empty poll at the documented ceiling passes" \
  || bad "a compliant poll was refused ($d)"

# A write_stdin that actually WRITES is input, not a poll — refusing it would break interactive
# commands outright, which is how a guard gets disabled.
d=$(decision 'tools.write_stdin({"chars":"yes","yield_time_ms":1000});')
[ "$d" = "allow" ] && pass "a real write with a short window is not treated as a poll" \
  || bad "a genuine stdin write was refused ($d)"

# A short window on a FAST command is the rule applied correctly: `rg --files` finishes in
# milliseconds, so the window never elapses and the call costs one round-trip — the minimum.
d=$(decision 'tools.exec_command({cmd: "rg --files src", yield_time_ms: 1000});')
[ "$d" = "allow" ] && pass "a short window on a fast exec is not refused" \
  || bad "a correctly-sized exec window was refused ($d)"

d=$(decision 'tools.exec_command({cmd: "rt --light npx vitest run a.spec.ts", yield_time_ms: 300000});')
[ "$d" = "allow" ] && pass "a long-running command is not refused" \
  || bad "a blocking test run was refused ($d)"

# ── paging a file that fits in one read ──────────────────────────────────────
# Same shape as polling, different verb: one operation split across turns. Measured across 1,002
# sessions, 4,191 extra turns went to slicing files that fit COMFORTABLY in the budget the same
# call requested; exactly 18 were forced by the limit. `SKILL.md` alone cost 1,973 of them at
# ~5,058 tokens against a routinely requested 30,000.
BIGF="$TMP/big.md"; : > "$BIGF"
i=0; while [ "$i" -lt 400 ]; do printf 'line %d of a skill file\n' "$i" >> "$BIGF"; i=$((i+1)); done

d=$(decision "tools.exec_command({cmd: \"sed -n '1,240p' $BIGF\", max_output_tokens: 30000})")
[ "$d" = "deny" ] && pass "a head-slice of a file that fits in the budget is refused" \
  || bad "avoidable paging was allowed ($d)"

# A LATER slice is not the decision point — by then the split already happened, and refusing it
# would strand the run mid-file with no way forward.
d=$(decision "tools.exec_command({cmd: \"sed -n '241,520p' $BIGF\", max_output_tokens: 30000})")
[ "$d" = "allow" ] && pass "a continuation slice is not refused" \
  || bad "the guard blocked a continuation, stranding the read ($d)"

d=$(decision "tools.exec_command({cmd: \"sed -n '1,9999p' $BIGF\", max_output_tokens: 30000})")
[ "$d" = "allow" ] && pass "reading the whole file in one call is allowed" \
  || bad "the compliant shape was refused ($d)"

# No budget named = nothing to judge against. Guessing here would refuse ordinary partial reads.
d=$(decision "tools.exec_command({cmd: \"sed -n '1,240p' $BIGF\"})")
[ "$d" = "allow" ] && pass "with no max_output_tokens there is nothing to judge, so it passes" \
  || bad "the guard judged a call with no budget ($d)"

# A file that genuinely does NOT fit must be pageable — that is what paging is for.
d=$(decision "tools.exec_command({cmd: \"sed -n '1,50p' $BIGF\", max_output_tokens: 100})")
[ "$d" = "allow" ] && pass "paging a file that exceeds the budget is allowed — that is its purpose" \
  || bad "the guard refused genuinely necessary paging ($d)"

d=$(decision "tools.exec_command({cmd: \"sed -n '1,240p' $TMP/does-not-exist.md\", max_output_tokens: 30000})")
[ "$d" = "allow" ] && pass "an unreadable path is not judged" \
  || bad "the guard refused on a file it could not measure ($d)"

# ── it must fail OPEN on anything it cannot read ─────────────────────────────
printf 'not json at all' > "$TMP/bad.json"
out=$(bash "$HOOK" < "$TMP/bad.json" 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && pass "malformed input fails OPEN" \
  || bad "the guard blocked on unparseable input (rc=$rc)"

printf '' > "$TMP/empty.json"
bash "$HOOK" < "$TMP/empty.json" >/dev/null 2>&1
[ "$?" = 0 ] && pass "empty input fails OPEN" || bad "the guard blocked on empty input"

d=$(decision 'tools.write_stdin({"chars":"","max_output_tokens":4000});')
[ "$d" = "allow" ] && pass "a poll with no yield_time_ms at all is not refused (nothing to judge)" \
  || bad "the guard refused a call it could not measure ($d)"

# ── the human off-switch works ───────────────────────────────────────────────
python3 - 'tools.write_stdin({"chars":"","yield_time_ms":30000});' > "$TMP/in.json" <<'PY'
import json, sys
json.dump({"hook_event_name": "pre_tool_use", "tool_input": {"input": sys.argv[1]}}, sys.stdout)
PY
out=$(ZUVO_ALLOW_SHORT_POLLS=1 bash "$HOOK" < "$TMP/in.json" 2>/dev/null)
[ -z "$out" ] && pass "ZUVO_ALLOW_SHORT_POLLS=1 disables the guard" \
  || bad "the off-switch did not work"

# ── the refusal must NAME the value to retry with ────────────────────────────
# A refusal that does not say what to do instead is retried identically, which is a loop rather
# than a fix.
python3 - 'tools.write_stdin({"chars":"","yield_time_ms":30000});' > "$TMP/in.json" <<'PY'
import json, sys
json.dump({"hook_event_name": "pre_tool_use", "tool_input": {"input": sys.argv[1]}}, sys.stdout)
PY
reason=$(bash "$HOOK" < "$TMP/in.json" 2>/dev/null | python3 -c '
import json,sys
print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])' 2>/dev/null)
case "$reason" in
  *300000*) pass "the refusal names the value to use instead" ;;
  *)        bad "the refusal does not name a replacement value: ${reason:0:80}" ;;
esac

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
