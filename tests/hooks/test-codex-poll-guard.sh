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

# --- regressions from the behaviour audit of 2026-08-27 ----------------------
# Every one of these was a FALSE REFUSAL or a crash, in a hook that sits in front of every tool
# call. That direction is the one that matters: a missed poll costs tokens, a wrong refusal costs
# the user work that was already correct.

d=$(decision 'tools.exec({cmd: "for i in $(seq 1 60); do curl -s http://x | grep -q done && break; sleep 5; done"})')
[ "$d" = "allow" ] && pass "a for-loop is a loop (BEHAV-1)" \
  || bad "the exact blocking shape the refusal recommends was itself refused ($d)"

d=$(decision 'tools.write_stdin({"session_id":7,"chars":" ","yield_time_ms":1000});')
[ "$d" = "allow" ] && pass "a space is a keystroke, not an empty poll (BEHAV-2)" \
  || bad "pressing space to advance a pager was refused ($d)"

d=$(decision 'echo "tools.wait_agent(x)" >> doc.md   # timeout_ms: 200')
[ "$d" = "allow" ] && pass "a command CONTAINING the name is not a call of it (BEHAV-3)" \
  || bad "writing the literal text refused the write ($d)"

d=$(decision "sed -n '1,240p' $TMP")
[ "$d" = "allow" ] && pass "a directory path fails OPEN, per this file's own contract (BEHAV-4)" \
  || bad "a directory did not fail open ($d)"

mkfifo "$TMP/fifo" 2>/dev/null
python3 - "sed -n '1,240p' $TMP/fifo" > "$TMP/fifo.json" <<'PY'
import json, sys
json.dump({"hook_event_name": "pre_tool_use",
           "tool_input": {"input": '{"cmd":"%s","max_output_tokens":30000}' % sys.argv[1]}},
          sys.stdout)
PY
timeout 5 bash "$HOOK" < "$TMP/fifo.json" >/dev/null 2>&1; rc=$?
[ "$rc" != "124" ] && pass "a FIFO with no writer does not hang the next tool call (BEHAV-5)" \
  || bad "the hook blocked forever on a FIFO — every later tool call waits behind it"

# The JS encoding writes `chars:` BARE. Requiring the quoted form meant the hook was live and
# INERT for the majority shape: it registered, reported success, and refused nothing.
d=$(decision 'tools.write_stdin({session_id:7, chars: "", yield_time_ms: 30000});')
[ "$d" = "deny" ] && pass "an empty poll in the JS (unquoted-key) encoding is refused" \
  || bad "the dominant real-world encoding was not matched ($d)"

# A wait_agent call that is fine must not end the hook early and skip every later check.
d=$(decision 'tools.wait_agent({"timeout_ms":300000}); tools.exec({cmd: "sleep 25; curl -s http://x"})')
[ "$d" = "deny" ] && pass "an acceptable wait_agent does not short-circuit the later checks" \
  || bad "one passing check waved the rest of the call through ($d)"

# --- the four encodings a command actually arrives in (2026-08-27, from live sessions) --------
# The guard knew two. The polling command captured in the wild used a THIRD, so it walked past a
# hook written precisely for it — and the separator was a newline, not the `;` the pattern wanted.
raw_decision() {  # feeds a full payload, not just an `input` string
  printf '%s' "$1" > "$TMP/raw.json"
  out=$(bash "$HOOK" < "$TMP/raw.json" 2>/dev/null)
  [ -z "$out" ] && { echo allow; return; }
  printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])'
}

d=$(decision 'const cmd=`sleep 30
curl -fsS $URL`')
[ "$d" = "deny" ] && pass "a template literal carrying `sleep N` newline check is refused" \
  || bad "the exact shape captured in the wild was allowed ($d)"

d=$(raw_decision '{"hook_event_name":"pre_tool_use","tool_input":{"command":["/bin/zsh","-lc","sleep 30\ncurl -fsS $URL"]}}')
[ "$d" = "deny" ] && pass "the zsh -lc argv array is read (separate string leaves, no comma to match)" \
  || bad "a shell-invocation array slipped past ($d)"

d=$(raw_decision '{"hook_event_name":"pre_tool_use","tool_input":{"command":["/bin/zsh","-lc","while true; do\ncurl -fsS $URL\nsleep 30\ndone"]}}')
[ "$d" = "allow" ] && pass "the same array holding a LOOP is allowed — that is the shape asked for" \
  || bad "the blocking loop the refusal recommends was refused ($d)"

d=$(raw_decision '{"hook_event_name":"pre_tool_use","tool_input":{"command":["/bin/zsh","-lc","npm run build && npm test"]}}')
[ "$d" = "allow" ] && pass "an ordinary command in the same encoding is untouched" \
  || bad "a plain build command was refused ($d)"

# --- the same read-only check, over and over (the shape `sleep` cannot see) --------------------
# Falsification first, as with the poll floor: identical tool OUTPUT is 0% of the corpus (a poll
# response always differs by a counter or a clock), so a guard keyed on that would never fire.
# Identical COMMANDS are 2.6%, in streaks reaching 32. That is the signal this uses.
sess() { printf '{"hook_event_name":"pre_tool_use","session_id":"%s","tool_input":{"input":"tools.exec({cmd: \\"%s\\"})"}}' "$1" "$2" > "$TMP/s.json"
  out=$(bash "$HOOK" < "$TMP/s.json" 2>/dev/null)
  [ -z "$out" ] && { echo allow; return; }
  printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])'; }

export TMPDIR="$TMP"       # keep the state file inside the fixture
a=$(sess r1 'gh run view 42 --json status'); b=$(sess r1 'gh run view 42 --json status'); c=$(sess r1 'gh run view 42 --json status')
[ "$a" = "allow" ] && [ "$b" = "allow" ] && [ "$c" = "deny" ] \
  && pass "the third identical read-only check is refused, the first two are not" \
  || bad "repeat detection wrong: $a/$b/$c (expected allow/allow/deny)"

d=$(sess r1 'gh run view 42 --json status')
[ "$d" = "allow" ] && pass "the refusal is a nudge per streak, not a lockout" \
  || bad "the command stayed locked out after the nudge ($d) — a final read must still be possible"

# Identical text, different meaning each time: code changed between runs. Refusing this is the
# false positive that gets a guard switched off, so only read-only shapes are ever counted.
x=$(sess r2 'npm test'); y=$(sess r2 'npm test'); z=$(sess r2 'npm test'); w=$(sess r2 'npm test')
[ "$x$y$z$w" = "allowallowallowallow" ] \
  && pass "a test command repeated four times is never counted (code changes between runs)" \
  || bad "a mutating/build command was treated as a poll: $x/$y/$z/$w"

l=$(sess r3 'while true; do gh run view 42; sleep 30; done')
l2=$(sess r3 'while true; do gh run view 42; sleep 30; done')
l3=$(sess r3 'while true; do gh run view 42; sleep 30; done')
[ "$l$l2$l3" = "allowallowallow" ] \
  && pass "a loop is never counted as a repeat — it is the shape being asked for" \
  || bad "the blocking loop was refused as a repeat: $l/$l2/$l3"

sess r4 'gh run view 42 --json status' >/dev/null
sess r4 'git status --porcelain' >/dev/null
g=$(sess r4 'gh run view 42 --json status')
[ "$g" = "allow" ] && pass "a different command in between resets the streak" \
  || bad "unrelated commands did not reset the counter ($g)"

# --- a loop opening after an ESCAPED newline (2026-08-28, from a live session) -----------------
# `\n` in a payload is TWO characters. `\bfor\b` therefore finds no word boundary in `\nfor` —
# 'n' and 'f' are both word characters — so the loop was invisible and the sleep inside it read as
# bare. The session where this was found is the worst possible case: the agent had just adopted
# `for i in $(seq 1 12); do … done` BECAUSE an earlier refusal told it to, and the guard was about
# to refuse it for doing so.
d=$(raw_decision '{"hook_event_name":"pre_tool_use","tool_input":{"input":"const cmd=`TOK=x\nfor i in $(seq 1 12); do\n curl -sS $URL\n sleep 5\ndone`"}}')
[ "$d" = "allow" ] && pass "a for-loop opening after an escaped newline is recognised (template)" \
  || bad "the shape the refusal itself recommends was refused ($d)"

d=$(raw_decision '{"hook_event_name":"pre_tool_use","tool_input":{"command":["/bin/zsh","-lc","TOK=x\nfor i in $(seq 1 12); do\n curl -sS $URL\n sleep 5\ndone"]}}')
[ "$d" = "allow" ] && pass "…and in the argv-array encoding too" \
  || bad "escaped-newline loop refused in the array encoding ($d)"

d=$(raw_decision '{"hook_event_name":"pre_tool_use","tool_input":{"command":["/bin/zsh","-lc","sleep 30\ncurl -sS $URL"]}}')
[ "$d" = "deny" ] && pass "normalising escapes does not blind it to a genuinely bare sleep" \
  || bad "the bare shape stopped being refused after normalisation ($d)"

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
