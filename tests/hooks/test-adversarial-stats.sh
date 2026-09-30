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
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }
[ -f "$TOOL" ] || { bad "scripts/zuvo-home/adversarial-stats does not exist"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/adversarial.log"
T="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
row() { # lane model outcome findings critical pdur project
  printf '%s\trid\tcode\t%s\t100\t50\t%s\t%s\t0\t0\t9s\t0\t/x.diff\t%s\t%s\t%s\t%s\n' \
    "$T" "$2" "$4" "$5" "$1" "$3" "$6" "$7" >> "$LOG"
}
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

line="$(printf '%s\n' "$out" | awk '$1=="byteplus-3"')"
case "$line" in *dola-seed-2.0-code*) pass "a row names its lane AND its model" ;; *) bad "lane row lacks the model: [$line]" ;; esac
case "$line" in *"BytePlus ModelArk"*) pass "a row names who pays" ;; *) bad "lane row lacks the vendor: [$line]" ;; esac
set -- $line
# LANE MODEL PAYS(2 words) RUNS OK% P50/P90 FIND CRIT FAILURES...
[ "$5" = "3" ] && pass "RUNS counts every attempted invocation" || bad "RUNS expected 3, got [$5] in [$line]"
[ "$6" = "67%" ] && pass "OK% = ok / runs" || bad "OK% expected 67%, got [$6]"
[ "$8" = "3.0" ] && [ "$9" = "1.00" ] && pass "FIND/CRIT average over successful reviews only" \
  || bad "FIND/CRIT expected 3.0/1.00, got [$8]/[$9]"
case "$line" in *"timeout 1"*) pass "failures are listed by outcome" ;; *) bad "timeout missing: [$line]" ;; esac

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
"$TOOL" --log "$TMP/missing" >/dev/null 2>&1 && bad "a missing log exited 0" || pass "a missing log is an error"

exit "$fail"
