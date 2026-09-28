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
HOOK="${ZUVO_TEST_HOOK:-$ROOT/hooks/post-skill-adversarial-check.sh}"
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
adv_row() { # adv_row <minutes ago> <project|--> <mode, default "code">
  local proj="$2"; local mode="${3:-code}"; local extra=""
  [ "$proj" != "--" ] && extra="	$proj"
  printf '%s\t%s\t%s\tsome-model\t100\t900\t3\t1\t1\t1\t42s\t0\t/tmp/x.diff\tcursor-agent\tok\t40s%s\n' \
    "$(stamp "$1")" "run-$RANDOM" "$mode" "$extra" >> "$HOME_DIR/.zuvo/adversarial.log"
}
runs_row() { # runs_row <minutes ago> <project> <note>
  printf '%s\twrite-tests\t%s\t0\t1\tPASS\t-\t-\t%s\n' "$(stamp "$1")" "$2" "$3" >> "$HOME_DIR/.zuvo/runs.log"
}

run_hook() { # run_hook [skill] [VAR=value ...] — the hook's stdout for {"tool_input":{"skill":"<skill>"}}
  # ADV-C39/C41: stderr used to go straight to /dev/null with the exit code never checked, so a
  # hook that crashed under its own `set -euo pipefail` (empty/partial stdout, no MANDATORY
  # substring) was indistinguishable from a hook that correctly decided not to nag — every
  # "should NOT nag" assertion in this file could pass vacuously on a systemic crash. Stash the
  # hook's own exit code + stderr in FILES (not a shell var: `$(run_hook ...)` command
  # substitution runs in its own subshell, so a plain variable assignment here would not survive
  # back to the caller) so a caller can assert on them after the fact.
  # VAR=value arguments after the skill reach the hook's environment (the window knob cases), so
  # EVERY invocation in this file goes through here — none calls the hook with its own 2>/dev/null.
  local skill="${1:-zuvo:write-tests}"
  local rc
  [ "$#" -gt 0 ] && shift
  : > "$HOME_DIR/.zuvo/.unused"
  ( cd "$REPO" && printf '{"tool_input":{"skill":"%s"}}' "$skill" \
      | env HOME="$HOME_DIR" "$@" bash "$HOOK" 2>"$TMP/hook.err" )
  rc=$?
  printf '%s' "$rc" > "$TMP/hook.rc"
}
hook_rc() { cat "$TMP/hook.rc" 2>/dev/null; }
# nagged [skill] [VAR=value ...] — "yes" / "no" for a hook that EXITED 0, and "crashed(rc=N)" for one
# that did not (its stderr is echoed to ours for triage). P2-121: the rc check lived only in the two
# newest cases (16); the other thirteen nagged()-based assertions still read an empty stdout from a
# crashed hook as a legitimate "no". Folding the check in HERE gives every call site the same
# protection: "crashed(rc=N)" equals neither answer, so a crash fails a "yes" AND a "no" assertion.
nagged() {
  local out rc
  out="$(run_hook "$@")"
  rc="$(hook_rc)"
  if [ "$rc" != "0" ]; then
    printf '  (hook crashed rc=%s: %s)\n' "${rc:-?}" "$(tr '\n' '|' < "$TMP/hook.err" 2>/dev/null)" >&2
    echo "crashed(rc=${rc:-?})"
    return 0
  fi
  case "$out" in *MANDATORY*) echo yes ;; *) echo no ;; esac
}
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

# 9. A skill that does not require adversarial is left alone entirely — silent AND exit 0 (an empty
#    stdout is also exactly what a crash looks like).
reset
out="$(run_hook zuvo:docs)"
[ -z "$out" ] && [ "$(hook_rc)" = "0" ] && pass "an unrelated skill produces no output (and the hook exits 0)" \
  || bad "zuvo:docs: output [$out] rc=[$(hook_rc)] — the hook fired, or crashed"

# 10. The window is tunable without editing the hook.
reset; adv_row 60 "$PROJECT"
[ "$(nagged zuvo:write-tests ZUVO_ADV_CHECK_WINDOW_MIN=90)" = "no" ] && pass "ZUVO_ADV_CHECK_WINDOW_MIN widens the window" \
  || bad "ZUVO_ADV_CHECK_WINDOW_MIN=90 did not widen the window (or the hook crashed)"

# 11. Task 2 (blind-audit gate integrity): a blind-audit row is a coverage AUDIT, not a review —
#     Plan B adds `adversarial-review.sh --mode blind-audit`, which writes to this same ledger.
#     It must never satisfy this check on its own. This lands BEFORE that mode exists so the
#     gate is already closed when it ships.
reset; adv_row 5 "$PROJECT" "blind-audit"
[ "$(nagged)" = "yes" ] && pass "a blind-audit-only ledger row does NOT satisfy the check" \
                        || bad "blind-audit row wrongly counted as an adversarial review"

# 11b. ADV-A5: the match must tolerate a forward-compatible mode value (a hand-edited/corrupted
#      row, or a future `blind-audit-<variant>` mode) rather than an exact string equality that
#      only excludes the one literal value "blind-audit" known today.
reset; adv_row 5 "$PROJECT" "blind-audit-v2"
[ "$(nagged)" = "yes" ] && pass "a 'blind-audit-v2'-mode row also does NOT satisfy the check (forward-tolerant match)" \
                        || bad "a forward-compatible blind-audit variant wrongly counted as an adversarial review"

# 12. …and a genuine code review in the same window still counts even with a blind-audit row
#     alongside it — only the mode column decides, the two rows must not interact.
reset; adv_row 5 "$PROJECT" "blind-audit"; adv_row 3 "$PROJECT"
[ "$(nagged)" = "no" ] && pass "a code-mode row alongside a blind-audit row still satisfies the check" \
                       || bad "a real code review was masked by a co-occurring blind-audit row"

# 13. Task Q11 gap: the SECOND skill-detection loop (build/execute/refactor/debug/receive-review/
#     seo-fix, hooks/post-skill-adversarial-check.sh:24-30, REVIEW_MODE="code") is only ever
#     reached by zuvo:write-tests/fix-tests/write-e2e (the FIRST loop) or zuvo:docs (neither loop)
#     in every case above — no test sends any of these six skill names. Both directions per skill,
#     mirroring cases 1-3: a fresh code-mode ledger row satisfies the check, and no evidence nags.
for s in build execute refactor debug receive-review seo-fix; do
  reset; adv_row 2 "$PROJECT"
  [ "$(nagged "zuvo:$s")" = "no" ] && pass "zuvo:$s: a fresh code-mode ledger entry satisfies the check" \
                                    || bad "zuvo:$s: a fresh code-mode entry still nags (REVIEW_MODE=code path broken)"
  reset
  [ "$(nagged "zuvo:$s")" = "yes" ] && pass "zuvo:$s: no evidence at all: still MANDATORY" \
                                     || bad "zuvo:$s: empty ledger passed (second skill-detection loop never fired)"
done

# 14. The reminder text's ${REVIEW_MODE} substitution, by CONTENT, not just the presence of
#     MANDATORY: a write-tests-family skill's reminder must carry --mode test, a build-family
#     skill's must carry --mode code. A regression that always emitted one or the other would not
#     be caught by cases 1-13 above, which only check for the word MANDATORY.
# reminder_mode <skill> <want> <other> — the reminder for <skill> carries `--mode <want>` and not
# `--mode <other>`. P2-121: judged only for a hook that EXITED 0 — "does not carry" is exactly what
# a crash's empty output also says, so a crash is one FAIL here, never a vacuous PASS.
reminder_mode() {
  local out
  reset
  out="$(run_hook "$1")"
  if [ "$(hook_rc)" != "0" ]; then
    bad "$1: the hook exited $(hook_rc) — no reminder to judge ($(tr '\n' '|' < "$TMP/hook.err" 2>/dev/null))"
    return 0
  fi
  case "$out" in
    *"--mode $2"*) pass "$1: reminder text carries --mode $2" ;;
    *) bad "$1: reminder does not carry --mode $2" ;;
  esac
  case "$out" in
    *"--mode $3"*) bad "$1: reminder wrongly also carries --mode $3" ;;
    *) pass "$1: reminder does not carry --mode $3" ;;
  esac
}
reminder_mode zuvo:write-tests test code
reminder_mode zuvo:build code test

# 15. hooks/post-skill-adversarial-check.sh:52 — an invalid (non-numeric or empty)
#     ZUVO_ADV_CHECK_WINDOW_MIN falls back to the default 45, not to 0 (which would nag on
#     everything) or to something unbounded (which would nag on nothing). Proven by ONE ledger
#     row placed on each side of the 45-minute line: 20 minutes old must still satisfy, 50 minutes
#     old must still nag — either failure mode above breaks one side of this pair.
for _bad_window in abc ""; do
  reset; adv_row 20 "$PROJECT"
  [ "$(nagged zuvo:write-tests ZUVO_ADV_CHECK_WINDOW_MIN="$_bad_window")" = "no" ] \
    && pass "ZUVO_ADV_CHECK_WINDOW_MIN='$_bad_window': 20-min-old entry still satisfies (falls back to 45)" \
    || bad "ZUVO_ADV_CHECK_WINDOW_MIN='$_bad_window': 20-min-old entry nags (fallback is not 45), or the hook crashed"
  reset; adv_row 50 "$PROJECT"
  [ "$(nagged zuvo:write-tests ZUVO_ADV_CHECK_WINDOW_MIN="$_bad_window")" = "yes" ] \
    && pass "ZUVO_ADV_CHECK_WINDOW_MIN='$_bad_window': 50-min-old entry (past the 45-min fallback) still nags" \
    || bad "ZUVO_ADV_CHECK_WINDOW_MIN='$_bad_window': 50-min-old entry wrongly satisfies (fallback is not 45), or the hook crashed"
done

# 16. ADV-C39/C41: the hook's own exit code, not just its stdout content, on one "should NOT
#     nag" case and one "should nag" case — a crash under `set -euo pipefail` (empty stdout, no
#     MANDATORY substring, and a nonzero exit) must surface as a distinct FAIL, not be read as a
#     legitimate negative. (Since P2-121 nagged() itself refuses to answer for a crashed hook, so
#     these two explicit rc reads are a second, independent check of the same thing.)
reset; adv_row 2 "$PROJECT"
[ "$(nagged)" = "no" ] && [ "$(cat "$TMP/hook.rc")" = "0" ] \
  && pass "should-NOT-nag case: hook itself exits 0 (a crash would be masked as a false 'no nag' otherwise)" \
  || bad "should-NOT-nag case: hook exited non-zero (rc=$(cat "$TMP/hook.rc" 2>/dev/null)) — a crash was masked as 'no nag'"

reset
[ "$(nagged)" = "yes" ] && [ "$(cat "$TMP/hook.rc")" = "0" ] \
  && pass "should-nag (empty ledger) case: hook itself exits 0" \
  || bad "should-nag (empty ledger) case: hook exited non-zero (rc=$(cat "$TMP/hook.rc" 2>/dev/null))"

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
