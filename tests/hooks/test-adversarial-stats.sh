#!/usr/bin/env bash
# Contract for ~/.zuvo/adversarial-stats — the usage table must name the lane AND the model, and
# must end with the billing page of every vendor in it. A lane name is an account slot
# (`byteplus-3`), so a table keyed by lane alone hid which model ran and who billed it.
#
# bash 3.2-compatible (macOS default).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$ROOT/scripts/zuvo-home/adversarial-stats"
fail=0
npass=0; nfail=0
pass() { printf 'PASS: %s\n' "$1"; npass=$((npass + 1)); }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; nfail=$((nfail + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }
[ -f "$TOOL" ] || { bad "scripts/zuvo-home/adversarial-stats does not exist"; printf 'RESULT: PASS=%d FAIL=%d\n' "$npass" "$nfail"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/adversarial.log"
T="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
row() { # lane model outcome findings critical pdur project
  printf '%s\trid\tcode\t%s\t100\t50\t%s\t%s\t0\t0\t9s\t0\t/x.diff\t%s\t%s\t%s\t%s\n' \
    "$T" "$2" "$4" "$5" "$1" "$3" "$6" "$7" >> "$LOG"
}
# The real log starts with the writer's header row; it must never be counted as a lane.
printf 'date\trun_id\tmode\tmodel\tinput_chars\toutput_chars\tfindings\tcritical\twarning\tinfo\tduration\texit\tinput_file\tprovider\toutcome\tprovider_duration\tproject\n' >> "$LOG"
row byteplus-3 dola-seed-2.0-code ok 4 2 100s projA
row byteplus-3 dola-seed-2.0-code ok 2 0 200s projA
row byteplus-3 dola-seed-2.0-code timeout 0 0 500s projA
row byteplus glm-5.3-flash ok 1 1 50s projB
row openrouter qwen/qwen3.8-flash ok 3 0 10s projA
row mock-success fake-model ok 9 9 1s projA
row codex-5.3 gpt-6-sol not-attempted 0 0 0s projA
printf '%s\t2020-01-01T00:00:00Z\tcode\tpartial\t5\t1\t503\tx\t0\n' "SUMMARY" >> "$LOG"
printf '2020-01-01T00:00:00Z\trid\tcode\told-model\t1\t1\t1\t1\t0\t0\t1s\t0\t/x\tbyteplus\tok\t1s\tprojA\n' >> "$LOG"

out="$("$TOOL" --log "$LOG" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "exits 0 on a normal log" || bad "exit $rc: $out"

# Assert on --markdown cells: a vendor name with a different word count must not shift the fields.
md0="$("$TOOL" --log "$LOG" --markdown 2>&1)"
cell() { # cell <lane> <column-number, 1-based: LANE MODEL PAYS RUNS OK% P50/P90 FIND CRIT FAILURES>
  printf '%s\n' "$md0" | awk -F' [|] ' -v lane="\`$1\`" -v n="$2" '{ sub(/^[|] /, ""); sub(/ [|]$/, "") } $1 == lane { print $n; exit }'
}
[ "$(cell byteplus-3 2)" = '`dola-seed-2.0-code`' ] && pass "a row names its lane AND its model" || bad "model cell: [$(cell byteplus-3 2)]"
[ "$(cell byteplus-3 3)" = "BytePlus ModelArk" ] && pass "a row names who pays" || bad "vendor cell: [$(cell byteplus-3 3)]"
[ "$(cell byteplus-3 4)" = "3" ] && pass "RUNS counts every attempted invocation" || bad "RUNS: [$(cell byteplus-3 4)]"
[ "$(cell byteplus-3 5)" = "66%" ] && pass "OK% = floor(ok / runs): 2 of 3 is 66%, never rounded up" || bad "OK%: [$(cell byteplus-3 5)]"
[ "$(cell byteplus-3 6)" = "100/200s" ] && pass "P50/P90 uses successful reviews only" || bad "P50/P90: [$(cell byteplus-3 6)]"
[ "$(cell byteplus-3 7)" = "3.0" ] && [ "$(cell byteplus-3 8)" = "1.00" ] && pass "FIND/CRIT average over successful reviews only" \
  || bad "FIND/CRIT: [$(cell byteplus-3 7)]/[$(cell byteplus-3 8)]"
[ "$(cell byteplus-3 9)" = "timeout 1" ] && pass "failures are listed by outcome" || bad "FAILURES: [$(cell byteplus-3 9)]"

case "$out" in *mock-success*|*fake-model*) bad "a mock lane was counted" ;; *) pass "mock lanes are never counted" ;; esac
case "$out" in *gpt-6-sol*) bad "a not-attempted row was counted" ;; *) pass "not-attempted rows are left out" ;; esac
case "$out" in *old-model*) bad "a row outside the window was counted" ;; *) pass "the window excludes old rows" ;; esac

case "$out" in *"https://console.byteplus.com/ark/region:ap-southeast-1/subscription/coding-plan"*)
  pass "the BytePlus billing link is printed under the table" ;; *) bad "BytePlus billing link missing" ;; esac
case "$out" in *"https://openrouter.ai/activity"*) pass "the OpenRouter billing link is printed" ;; *) bad "OpenRouter link missing" ;; esac
bl="$(printf '%s\n' "$out" | awk '/BytePlus ModelArk \(Coding Plan\)/ && /http/')"
case "$bl" in *byteplus-3*byteplus*) pass "the billing line lists the lanes it covers" ;; *) bad "billing line lacks lanes: [$bl]" ;; esac
case "$out" in *"Alibaba"*) bad "a vendor with no rows got a billing line" ;; *) pass "only vendors in the table get a billing line" ;; esac

outp="$("$TOOL" --log "$LOG" --project projB 2>&1)"
case "$outp" in *glm-5.3-flash*) case "$outp" in *dola-seed*) bad "--project leaked another project" ;; *) pass "--project filters rows" ;; esac ;;
  *) bad "--project dropped its own rows: $outp" ;; esac

md="$("$TOOL" --log "$LOG" --markdown 2>&1)"
case "$md" in *'| `byteplus-3` | `dola-seed-2.0-code` |'*) pass "--markdown keeps lane and model in adjacent cells" ;;
  *) bad "markdown row malformed: $md" ;; esac
case "$md" in *"coding-plan"*) pass "--markdown also ends with the billing links" ;; *) bad "markdown lacks billing links" ;; esac

"$TOOL" --log "$LOG" --since not-a-date >/dev/null 2>&1 && bad "a bad --since was accepted" || pass "a bad --since is refused"
outn="$("$TOOL" --log "$LOG" --project nope 2>&1)"; rcn=$?
[ "$rcn" -ne 0 ] && case "$outn" in *"project nope"*) true ;; *) false ;; esac \
  && pass "a --project that matches nothing says so and exits non-zero" || bad "empty --project: rc=$rcn [$outn]"
day="${T%%T*}"   # the rows' own day, not "now": no flake when the suite crosses UTC midnight
outd="$("$TOOL" --log "$LOG" --since "$day" 2>&1)"
case "$outd" in *dola-seed*) pass "--since DAY keeps rows from that whole day" ;; *) bad "--since today dropped today's rows" ;; esac
"$TOOL" --log "$TMP/missing" >/dev/null 2>&1 && bad "a missing log exited 0" || pass "a missing log is an error"

case "$out" in *"provider "*|*"unknown"*) bad "the header row was counted as a lane: $out" ;; *) pass "the log header row is not a lane" ;; esac
printf '%s\trid\tcode\tm\t1\t1\t1\t0\t0\t0\t1s\t0\t/x\tbyteplus\tok\tinf\tprojA\n' "$T" > "$TMP/inf.log"
"$TOOL" --log "$TMP/inf.log" >/dev/null 2>&1 && pass "an 'inf' duration does not crash the report" || bad "an 'inf' duration crashed the report"
printf '%s\trid\tcode\tm\t1\t1\t1\t0\t0\t0\t1s\t0\t/x\tbyteplus\tok\t-30s\tprojA\n' "$T" > "$TMP/neg.log"
negmd="$("$TOOL" --log "$TMP/neg.log" --markdown 2>&1)"
case "$negmd" in *"| 0/0s |"*) pass "a negative duration (clock step) is clamped to 0" ;; *) bad "negative duration leaked: $negmd" ;; esac
"$TOOL" --log "$LOG" --since 2026-13-45 >/dev/null 2>&1 && bad "an impossible date was accepted" || pass "an impossible --since date is refused"
billing="$(python3 -c 'import runpy,sys; g=runpy.run_path(sys.argv[1], run_name="t"); print(g["billing_for"]("kimi-api")[0], "|", g["billing_for"]("kimi")[0], "|", g["billing_for"]("kimiX")[0])' "$TOOL")"
[ "$billing" = "Moonshot API (per token) | Moonshot Kimi Code | unknown" ] && pass "billing uses the longest prefix at a '-' boundary" || bad "billing_for: [$billing]"
printf 'SUMMARY\t%s\tcode\tpartial\t5\t1\t503\tcursor-agent, codex-5.3\t0\ngarbage line\n%s\trid\tcode\tm\t1\n' "$T" "$T" >> "$TMP/neg.log"
negout="$("$TOOL" --log "$TMP/neg.log" 2>&1)"
case "$negout" in *"1 truncated row"*) pass "a truncated dated row is counted; SUMMARY and undated lines are not" ;; *) bad "skip count wrong: $negout" ;; esac
case "$out" in *truncated*) bad "a normal log reported skipped rows: $out" ;; *) pass "a normal log (header + SUMMARY-free) reports no skipped rows" ;; esac
outs="$("$TOOL" --log "$LOG" --since "${T}" 2>&1 | awk 'NR==1')"
case "$outs" in *"since ${T%%T*}T00:00:00Z"*) pass "--since accepts the tool's own timestamp form" ;; *) bad "--since timestamp: $outs" ;; esac
"$TOOL" --log "$LOG" --days 0 >/dev/null 2>&1 && bad "--days 0 was accepted" || pass "--days outside 1-3650 is refused"
"$TOOL" --log "$LOG" --days 99999999 >/dev/null 2>&1 && bad "--days 99999999 was accepted" || pass "a huge --days is refused, not an OverflowError"

# A model name is log data: a pipe must not split the markdown row.
LOG2="$TMP/pipe.log"
printf '%s\trid\tcode\tweird|model\t1\t1\t1\t0\t0\t0\t1s\t0\t/x\tbyteplus\tok\t5s\tprojA\n' "$T" > "$LOG2"
mdp="$("$TOOL" --log "$LOG2" --markdown 2>&1)"
case "$mdp" in *'weird\|model'*) pass "a pipe inside a model name is escaped in --markdown" ;; *) bad "pipe not escaped: $mdp" ;; esac

# Equal-run rows have a canonical order (lane, then model), whatever order the log wrote them in;
# plain cells escape Markdown too (an outcome is log data, like a model name).
printf '%s\trid\tcode\tm\t1\t1\t1\t0\t0\t0\t1s\t0\t/x\tmuse\ttime*out\t5s\tprojA\n%s\trid\tcode\tzz-model\t1\t1\t1\t0\t0\t0\t1s\t0\t/x\tagy\tok\t5s\tprojA\n%s\trid\tcode\taa-model\t1\t1\t1\t0\t0\t0\t1s\t0\t/x\tagy\tok\t5s\tprojA\n' "$T" "$T" "$T" > "$TMP/tie.log"
tie="$("$TOOL" --log "$TMP/tie.log" --markdown 2>&1)"
order="$(printf '%s\n' "$tie" | awk -F' [|] ' '/^[|] `/ { sub(/^[|] /, ""); print $1 "/" $2 }' | paste -sd, -)"
[ "$order" = '`agy`/`aa-model`,`agy`/`zz-model`,`muse`/`m`' ] && pass "rows with equal runs are ordered by lane, then model" \
  || bad "tie order: [$order]"
case "$tie" in *'time\*out 1'*) pass "plain markdown cells escape log data" ;; *) bad "plain cell not escaped: $tie" ;; esac

# --since is normalised: the compact form 20260101 must cut at the same place as 2026-01-01.
a="$("$TOOL" --log "$LOG" --since 2020-01-01 2>&1 | awk 'NR==1')"; b="$("$TOOL" --log "$LOG" --since 20200101 2>&1 | awk 'NR==1')"
[ "$a" = "$b" ] && pass "--since compact and dashed forms give the same cutoff" || bad "since forms differ: [$a] vs [$b]"

# The default log follows the writer: ZUVO_ADVERSARIAL_LOG_FILE, then $ZUVO_HOME.
# A clean HOME: with the real one, a tool ignoring the variable would still find rows in the
# host's ~/.zuvo/adversarial.log and pass.
mkdir -p "$TMP/emptyhome"
oute="$(env -u ZUVO_HOME HOME="$TMP/emptyhome" ZUVO_ADVERSARIAL_LOG_FILE="$LOG" "$TOOL" 2>&1)"
case "$oute" in *dola-seed*) pass "ZUVO_ADVERSARIAL_LOG_FILE is the default log" ;; *) bad "env log ignored: $oute" ;; esac
mkdir -p "$TMP/zh"; cp "$LOG" "$TMP/zh/adversarial.log"
outh="$(env -u ZUVO_ADVERSARIAL_LOG_FILE HOME="$TMP/emptyhome" ZUVO_HOME="$TMP/zh" "$TOOL" 2>&1)"
case "$outh" in *dola-seed*) pass "\$ZUVO_HOME/adversarial.log is the fallback default" ;; *) bad "ZUVO_HOME ignored: $outh" ;; esac

# Contracts: the column indices name the writer's fields; the docs table carries every BILLING vendor.
contract="$(python3 - "$TOOL" "$ROOT/scripts/adversarial-review.sh" "$ROOT/docs/adversarial-providers.md" <<'PY'
import re, runpy, sys
g = runpy.run_path(sys.argv[1], run_name="adversarial_stats_test")
src = open(sys.argv[2]).read()
m = re.search(r'LOG_HEADER=\$\(printf [^\n]*\\\n((?:\s*"[^\n]*\n)+)', src)
fields = re.findall(r'"([a-z_]+)"', m.group(1)) if m else []
want = {"C_DATE": "date", "C_MODEL": "model", "C_FIND": "findings", "C_CRIT": "critical", "C_DUR": "duration",
        "C_PROVIDER": "provider", "C_OUTCOME": "outcome", "C_PDUR": "provider_duration", "C_PROJECT": "project"}
bad = ["%s=%s is %r" % (k, g[k], fields[g[k]] if g[k] < len(fields) else None) for k, v in want.items()
       if g[k] >= len(fields) or fields[g[k]] != v]
docs = open(sys.argv[3]).read()
for prefix, vendor, url in g["BILLING"]:
    if vendor not in docs or (url and url not in docs):
        bad.append("docs lack %s %s" % (vendor, url or ""))
print("OK" if fields and not bad else "; ".join(bad) or "no LOG_HEADER found")
PY
)"
[ "$contract" = "OK" ] && pass "column indices match the writer's LOG_HEADER and the docs list every BILLING vendor" \
  || bad "contract: $contract"

printf 'RESULT: PASS=%d FAIL=%d\n' "$npass" "$nfail"   # the verdict line mutation runners read
exit "$fail"
