#!/usr/bin/env bash
# Contract for scripts/zuvo-home/poll-cost — the tool that measures what waiting costs.
#
# Why this has a test at all: the tool exists to verify that a guidance change actually moved
# something, so a tool that silently miscounts would validate a no-op. Two failure modes are
# specifically pinned because both already happened while writing it:
#
#   1. Attributing Codex polls by matching `zuvo[:/]<word>` anywhere in a tool call. That matches
#      the helper path `~/.zuvo/append-retro` and the output dir `zuvo/contracts`, producing
#      "skills" that do not exist. A path is not an invocation.
#   2. Counting a blocking wait as a poll. `until ...; do sleep 30; done` is the DESIRED shape —
#      scoring it as waste would push runs away from the fix.
#
# bash 3.2-compatible (macOS default). Accumulate-and-report.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/scripts/zuvo-home/poll-cost"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }
[ -f "$BIN" ] || { bad "scripts/zuvo-home/poll-cost does not exist"; exit 1; }

python3 -c "import ast,sys; ast.parse(open('$BIN').read())" 2>/dev/null \
  && pass "the tool parses" || bad "the tool has a syntax error"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_ORIG="$HOME"
export HOME="$TMP"
mkdir -p "$TMP/.claude/projects/probe" "$TMP/.codex/sessions/2026/08/26"

# ── a Claude Code session: one Skill, then one of each waiting shape ──────────
cc="$TMP/.claude/projects/probe/s.jsonl"
emit() { printf '%s\n' "$1" >> "$cc"; }
emit '{"message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"zuvo:refactor"}}]}}'
emit '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"sleep 5; cat out"}}]}}'
emit '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"until [ -f d ]; do sleep 30; done"}}]}}'
emit '{"message":{"content":[{"type":"tool_use","name":"Monitor","input":{}}]}}'
emit '{"message":{"content":[{"type":"tool_use","name":"BashOutput","input":{}}]}}'

out="$(python3 "$BIN" 2>&1)"

echo "$out" | grep -q "zuvo:refactor" \
  && pass "a Claude Code poll is attributed to the skill that was running" \
  || bad "the running skill was not attributed: $(echo "$out" | head -3)"

# 2 polls (sleep-then-check + BashOutput), 1 blocking, 1 event — the three must not be conflated.
line=$(echo "$out" | awk '/^zuvo:refactor/{print; exit}')
set -- $line
[ "${2:-}" = "2" ] && pass "sleep-then-check and BashOutput both count as polls" \
  || bad "poll count was '${2:-}' (want 2): $line"
[ "${3:-}" = "1" ] && pass "a blocking until-loop is counted as blocking, not as a poll" \
  || bad "blocking count was '${3:-}' (want 1): $line"
[ "${4:-}" = "1" ] && pass "Monitor is counted as event-driven" \
  || bad "event count was '${4:-}' (want 1): $line"

# ── Codex: a helper PATH must not be read as a skill invocation ───────────────
cx="$TMP/.codex/sessions/2026/08/26/rollout-2026-08-26T10-00-00-x.jsonl"
{
  # A call that merely mentions ~/.zuvo/append-retro and zuvo/contracts. Neither is a skill.
  printf '%s\n' '{"payload":{"type":"custom_tool_call","name":"exec","arguments":"{\"cmd\":\"~/.zuvo/append-retro; ls zuvo/contracts\"}"}}'
  printf '%s\n' '{"payload":{"type":"custom_tool_call","name":"wait","arguments":"{\"yield_time_ms\":30000}"}}'
} > "$cx"
out2="$(python3 "$BIN" 2>&1)"
echo "$out2" | grep -qE "zuvo:(append-retro|contracts)" \
  && bad "a helper path was reported as a skill — the invented-skill bug is back" \
  || pass "a helper path is not mistaken for a skill invocation"

# ── Codex: a blocking command must be COUNTED, not invisible ─────────────────
# The first version classified only `wait`, so the blocking and event columns were structurally
# zero for Codex — and a baseline was published saying "in Codex every wait is a poll", which
# described the scanner, not Codex. Zero has to be a measurement before it can be a finding.
cx2="$TMP/.codex/sessions/2026/08/26/rollout-2026-08-26T11-00-00-y.jsonl"
{
  printf '%s\n' '{"payload":{"type":"custom_tool_call","name":"exec","arguments":"{\"cmd\":\"until [ -f done ]; do sleep 30; done\"}"}}'
  printf '%s\n' '{"payload":{"type":"custom_tool_call","name":"exec","arguments":"{\"cmd\":\"rt --wait 12345\"}"}}'
} > "$cx2"
out4="$(python3 "$BIN" 2>&1)"
cxline=$(echo "$out4" | awk '/^=== Codex/{f=1} f&&/^TOTAL/{print; exit}')
# `set --` splits on IFS and would glob-expand a `*` in the output, so disable pathname expansion
# for the split. Assert the EXACT count: `>= 2` would also accept a classifier that counted the
# same command twice, or counted a poll as blocking.
set -f; set -- $cxline; set +f
[ "${3:-}" = "2" ] \
  && pass "Codex blocking commands are counted as blocking, not silently dropped" \
  || bad "Codex blocking column was '${3:-}', expected exactly 2: $cxline"

# ── the REAL Codex shape: the command is in `input`, as JS, not in `arguments` ─
# The fixture above uses `arguments`, which is the shape the scanner was written against and NOT
# the shape Codex emits: a `custom_tool_call` carries JavaScript wrapping
# `tools.exec_command({cmd: "...", yield_time_ms: N})` and leaves `arguments` empty. Because of
# that, a classifier added to count blocking commands reported 1 in 11,690 while ten live sessions
# were using 31. A test that only exercises the unused shape certifies a path nothing takes.
cx4="$TMP/.codex/sessions/2026/08/26/rollout-2026-08-26T13-00-00-w.jsonl"
printf '%s\n' '{"payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.exec_command({\n  cmd: \"rt --light npx vitest run apps/api/x.spec.ts\",\n  yield_time_ms: 300000\n});"}}' > "$cx4"
out7="$(python3 "$BIN" 2>&1)"
cxl=$(echo "$out7" | awk '/^=== Codex/{f=1} f&&/^TOTAL/{print; exit}')
set -f; set -- $cxl; set +f
# EXACT, not `>=`. A lower bound also passes when the classifier double-counts, which is the
# regression this case would otherwise be blind to.
[ "${3:-}" = "3" ] \
  && pass "a blocking command in the real \`input\` shape is counted exactly once" \
  || bad "blocking column was '${3:-}', expected exactly 3: $cxl"
rm -f "$cx4"

# ── a command containing an ESCAPED QUOTE must still be extracted ────────────
# The shape that hid a real bug: CODEX_CMD demanded TWO literal backslashes where an escape has
# one, so any command with an embedded `\"` failed to match and fell back to the whole wrapper
# blob. Classification came out right by accident — the markers were still substrings of the
# fallback — so the fix's own test passed while the fix was broken. This fixture is that shape.
cx5="$TMP/.codex/sessions/2026/08/26/rollout-2026-08-26T14-00-00-v.jsonl"
printf '%s\n' '{"payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.exec_command({\n  cmd: \"echo \\\"hello\\\" && rt --light npx vitest run b.spec.ts\",\n  yield_time_ms: 300000\n});"}}' > "$cx5"
out8="$(python3 "$BIN" 2>&1)"
cx5l=$(echo "$out8" | awk '/^=== Codex/{f=1} f&&/^TOTAL/{print; exit}')
set -f; set -- $cx5l; set +f
# 3, not 4: the previous case removes its own fixture, so what remains is cx2's two plus this one.
# The first version expected 4 and failed — the code was right and the expectation was wrong, which
# is worth a comment because the next person will do the same arithmetic.
[ "${3:-}" = "3" ] \
  && pass "a command with an embedded escaped quote is still classified as blocking" \
  || bad "escaped-quote command not counted — blocking column '${3:-}', expected 3: $cx5l"

# The count above ALSO comes out right when extraction is broken, because the marker is still a
# substring of the whole wrapper it falls back to — which is precisely how the original bug
# survived its own test. So plant a blocking marker OUTSIDE the cmd and assert it is NOT counted:
# that only holds if the command was really extracted.
rm -f "$cx5"
cx6="$TMP/.codex/sessions/2026/08/26/rollout-2026-08-26T14-30-00-w.jsonl"
printf '%s\n' '{"payload":{"type":"custom_tool_call","name":"exec","input":"// rt --wait npx vitest run decoy.spec.ts\nconst r = await tools.exec_command({\n  cmd: \"echo plain\",\n  yield_time_ms: 300000\n});"}}' > "$cx6"
out9="$(python3 "$BIN" 2>&1)"
cx6l=$(echo "$out9" | awk '/^=== Codex/{f=1} f&&/^TOTAL/{print; exit}')
set -f; set -- $cx6l; set +f
[ "${3:-}" = "2" ] \
  && pass "a blocking marker OUTSIDE cmd is not counted — proving the command was extracted" \
  || bad "wrapper text leaked into classification — blocking column '${3:-}', expected 2: $cx6l"

# Classification alone is NOT enough here, and that is the whole lesson of this bug: when the regex
# failed, the code fell back to the raw wrapper text, whose substrings still tripped BLOCKLOOP — so
# the count came out right while the extractor was broken. Assert on the EXTRACTION itself.
python3 - "$ROOT/scripts/zuvo-home/poll-cost" > "$TMP/extract.out" 2>&1 <<'PYF'
import re, sys
src = open(sys.argv[1]).read()
line = [l for l in src.splitlines() if l.startswith("CODEX_CMD")][0]
ns = {}
exec(line, {"re": re}, ns)
probe = r'tools.exec_command({cmd: "echo \"hi\" && rt --light npx vitest run b.spec.ts", y: 1})'
m = ns["CODEX_CMD"].search(probe)
print(m.group(1) if m else "NO_MATCH")
PYF
got=$(cat "$TMP/extract.out")
case "$got" in
  *'rt --light npx vitest run b.spec.ts'*)
    pass "CODEX_CMD extracts a command containing an escaped quote" ;;
  NO_MATCH*)
    bad "CODEX_CMD failed to match an escaped-quote command — the fallback would hide this" ;;
  *)  bad "CODEX_CMD extracted the wrong text: $got" ;;
esac
rm -f "$cx5"

# ── an EMPTY write_stdin is a poll, and a polled `rt` is not blocking ────────
# The dominant shape, and it was invisible: `write_stdin` with empty chars polls without writing
# (the tool's own description), and the counter only looked at `wait`. Measured across ten live
# refactors: 1,099 `wait` calls against 3,917 empty write_stdin polls — 4.6x undercount. Worse, an
# `rt` followed by those polls was being credited as a BLOCKING wait, i.e. scored as the good
# behaviour while doing the bad one.
cx6="$TMP/.codex/sessions/2026/08/26/rollout-2026-08-26T15-00-00-u.jsonl"
{
  printf '%s\n' '{"payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.exec_command({ cmd: \"rt --light npx vitest run c.spec.ts\", yield_time_ms: 30000 });"}}'
  printf '%s\n' '{"payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.write_stdin({\"session_id\":1,\"chars\":\"\",\"yield_time_ms\":30000});"}}'
  printf '%s\n' '{"payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.write_stdin({\"session_id\":1,\"chars\":\"\",\"yield_time_ms\":30000});"}}'
} > "$cx6"
out9="$(python3 "$BIN" 2>&1)"
cx6l=$(echo "$out9" | awk '/^=== Codex/{f=1} f&&/^TOTAL/{print; exit}')
set -f; set -- $cx6l; set +f
[ "${2:-0}" -ge 2 ] 2>/dev/null \
  && pass "empty write_stdin calls are counted as polls" \
  || bad "empty write_stdin polls were not counted — polls column '${2:-}': $cx6l"
[ "${3:-}" = "3" ] \
  && pass "an rt that is then polled does not keep its blocking credit" \
  || bad "polled rt still counted as blocking — column '${3:-}', expected 3: $cx6l"
rm -f "$cx6"

# ── --since must actually exclude ────────────────────────────────────────────
out3="$(python3 "$BIN" --since 2299-01-01 2>&1)"
echo "$out3" | grep -q "nothing recorded" \
  && pass "--since excludes sessions older than the cutoff" \
  || bad "--since did not filter: $(echo "$out3" | head -4)"

# ── --since dates a session by ITS OWN timestamp, not the file's mtime ───────
# A session left open across the cutoff has an mtime weeks after it began; dating it that way
# files its whole pre-change history into the "after" bucket — corrupting the one comparison this
# tool exists to produce. Verified on real data: a transcript starting 2026-07-28 with an mtime of
# 2026-08-24, 27 days out.
old_sess="$TMP/.claude/projects/probe/old.jsonl"
printf '%s\n' '{"type":"user","timestamp":"2020-01-01T00:00:00.000Z","message":{"role":"user","content":"x"}}' > "$old_sess"
printf '%s\n' '{"message":{"content":[{"type":"tool_use","name":"BashOutput","input":{}}]}}' >> "$old_sess"
touch "$old_sess"                       # mtime = now, session start = 2020
out5="$(python3 "$BIN" --since 2026-01-01 2>&1)"
echo "$out5" | grep -q "probe\|BashOutput" && true
before=$(echo "$out5" | awk '/^=== Claude Code/{f=1} f&&/^TOTAL/{print $2; exit}')
rm -f "$old_sess"
after_removed=$(python3 "$BIN" --since 2026-01-01 2>&1 | awk '/^=== Claude Code/{f=1} f&&/^TOTAL/{print $2; exit}')
# Both sides must be real numbers before comparing them: if the Claude section is absent entirely
# (no TOTAL line), `before` and `after_removed` are both empty, they compare equal, and the case
# reports a pass while having tested nothing.
case "${before:-}${after_removed:-}" in
  *[!0-9]*|"") bad "no Claude TOTAL to compare — the case tested nothing (got '$before' / '$after_removed')" ;;
  *) [ "$before" = "$after_removed" ] \
       && pass "a freshly-touched session that STARTED before the cutoff is excluded" \
       || bad "mtime leaked a pre-cutoff session into the filtered run ($before vs $after_removed)" ;;
esac

# ── the median-context branch must actually run ──────────────────────────────
# `report()` prints "median context per request" only when a session cleared `reqs >= 20`. The
# Codex fixture above has two lines, so that threshold — and the whole cost calculation built on
# it — was never exercised. An untested reporting branch is how a wrong number gets published.
cx3="$TMP/.codex/sessions/2026/08/26/rollout-2026-08-26T12-00-00-z.jsonl"
: > "$cx3"
i=0
while [ "$i" -lt 25 ]; do
  printf '%s\n' '{"payload":{"type":"custom_tool_call","name":"wait","arguments":"{\"yield_time_ms\":30000}","info":{"total_token_usage":{"input_tokens":100000}}}}' >> "$cx3"
  i=$((i + 1))
done
out6="$(python3 "$BIN" 2>&1)"
echo "$out6" | grep -q "median context per request" \
  && pass "the median-context branch runs once a session clears the reqs threshold" \
  || bad "median context never printed with 25 usage records present"
echo "$out6" | grep -q "carried by polls" \
  && pass "the poll cost derived from that median is printed too" \
  || bad "poll cost line missing"

# ── --since must refuse a value it cannot compare ────────────────────────────
# Every comparison is a lexicographic string compare, so `--since banana` does not raise: it
# quietly matches nothing and prints an empty report. On a before/after tool that is the failure
# most likely to be mistaken for a result.
python3 "$BIN" --since banana >/dev/null 2>"$TMP/since.err"
[ "$?" != 0 ] && grep -q "YYYY-MM-DD" "$TMP/since.err" \
  && pass "--since rejects an unparseable value instead of reporting nothing" \
  || bad "--since banana was accepted: $(cat "$TMP/since.err")"
python3 "$BIN" --since 2026-13-45 >/dev/null 2>"$TMP/since2.err"
[ "$?" != 0 ] \
  && pass "--since rejects a well-formed but impossible date" \
  || bad "--since 2026-13-45 was accepted"

export HOME="$HOME_ORIG"
echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
