#!/usr/bin/env bash
# test-post-skill-adversarial-check.sh — the PostToolUse hook that asks "did this skill run its
# adversarial pass?"
#
# Why it needed fixing, measured 2026-09-22 over 1,115 qualifying skill runs since 2026-08-01:
#   evidence the hook USED to look for (the word "adversarial" in runs.log's note column):  6%
#   evidence that actually exists (~/.zuvo/adversarial.log, the driver's own ledger):       94%
# So it demanded a second full multi-provider review on ~19 of every 20 runs that had already
# done one. The window was the smaller half of the problem: the gap between a skill's
# adversarial call and the end of that run is p50 1.0 min, p95 15.8 min, max 662 — a flat 15
# minutes cut at the 95th percentile.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/post-skill-adversarial-check.sh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
[ -f "$HOOK" ] || { bad "hooks/post-skill-adversarial-check.sh missing"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"; mkdir -p "$HOME_DIR/.zuvo"
REPO="$TMP/myproject"; mkdir -p "$REPO"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
PROJECT="myproject"

stamp() { date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ; }

# A per-provider ledger row, shaped like the real one (17 columns since 2026-09-22).
adv_row() { # adv_row <minutes ago> <project|-->
  local proj="$2"; local extra=""
  [ "$proj" != "--" ] && extra="	$proj"
  printf '%s\t%s\tcode\tsome-model\t100\t900\t3\t1\t1\t1\t42s\t0\t/tmp/x.diff\tcursor-agent\tok\t40s%s\n' \
    "$(stamp "$1")" "run-$RANDOM" "$extra" >> "$HOME_DIR/.zuvo/adversarial.log"
}
runs_row() { # runs_row <minutes ago> <project> <note>
  printf '%s\twrite-tests\t%s\t0\t1\tPASS\t-\t-\t%s\n' "$(stamp "$1")" "$2" "$3" >> "$HOME_DIR/.zuvo/runs.log"
}

run_hook() { # prints the hook's stdout
  : > "$HOME_DIR/.zuvo/.unused"
  ( cd "$REPO" && printf '{"tool_input":{"skill":"zuvo:write-tests"}}' \
      | HOME="$HOME_DIR" bash "$HOOK" 2>/dev/null )
}
nagged() { case "$(run_hook)" in *MANDATORY*) echo yes ;; *) echo no ;; esac; }
reset()  { : > "$HOME_DIR/.zuvo/adversarial.log"; : > "$HOME_DIR/.zuvo/runs.log"; }

echo "=== post-skill adversarial check ==="

# 1. THE REGRESSION THIS FIXES: a real invocation 20 minutes ago (past the old 15-minute
#    window) for this project must count.
reset; adv_row 20 "$PROJECT"
[ "$(nagged)" = "no" ] && pass "a real ledger entry 20 min old satisfies the check" \
                       || bad "20-min-old adversarial still nags (the 6%-of-runs regression)"

# 2. …and the common case, a fresh entry.
reset; adv_row 2 "$PROJECT"
[ "$(nagged)" = "no" ] && pass "a fresh ledger entry satisfies the check" || bad "fresh entry nags"

# 3. Nothing at all still nags — the hook must not become a rubber stamp.
reset
[ "$(nagged)" = "yes" ] && pass "no evidence at all: still MANDATORY" || bad "empty ledger passed"

# 4. Outside the window nags.
reset; adv_row 120 "$PROJECT"
[ "$(nagged)" = "yes" ] && pass "a 2-hour-old entry is too old to count" || bad "stale entry accepted"

# 5. Another project's review must not satisfy this one — the machine runs several repos at once.
reset; adv_row 3 "someone-elses-repo"
[ "$(nagged)" = "yes" ] && pass "another project's review does not count" \
                        || bad "cross-project false pass"

# 6. Legacy 16-column rows (written before the project column) count on time alone: they are
#    still evidence a review ran, and dropping them would recreate the very nag this fixes.
reset; adv_row 5 "--"
[ "$(nagged)" = "no" ] && pass "a pre-project-column row still counts" || bad "legacy row discarded"

# 7. The runs.log fallback: a note that records a SKIPPED pass is not evidence it ran. The old
#    unanchored /adversarial/ match accepted exactly this.
reset; runs_row 5 "$PROJECT" "adversarial review: skipped (timeout)"
[ "$(nagged)" = "yes" ] && pass "'adversarial: skipped' does not satisfy the check" \
                        || bad "a skipped pass was accepted as a completed one"

# 8. …while a positive note still does, for hosts with no ledger yet.
reset; runs_row 5 "$PROJECT" "adversarial 4 CRITICAL fixed in-run"
[ "$(nagged)" = "no" ] && pass "a positive runs.log note still works as a fallback" \
                      || bad "fallback broken"

# 9. A skill that does not require adversarial is left alone entirely.
reset
out=$( cd "$REPO" && printf '{"tool_input":{"skill":"zuvo:docs"}}' | HOME="$HOME_DIR" bash "$HOOK" 2>/dev/null )
[ -z "$out" ] && pass "an unrelated skill produces no output" || bad "hook fired on zuvo:docs"

# 10. The window is tunable without editing the hook.
reset; adv_row 60 "$PROJECT"
out=$( cd "$REPO" && printf '{"tool_input":{"skill":"zuvo:write-tests"}}' \
       | HOME="$HOME_DIR" ZUVO_ADV_CHECK_WINDOW_MIN=90 bash "$HOOK" 2>/dev/null )
case "$out" in *MANDATORY*) bad "ZUVO_ADV_CHECK_WINDOW_MIN=90 did not widen the window" ;;
               *)           pass "ZUVO_ADV_CHECK_WINDOW_MIN widens the window" ;; esac

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
