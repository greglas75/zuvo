#!/usr/bin/env bash
#
# smoke-blind-audit.sh — Plan B (blind coverage audit as a panel), Task 10: the whole-feature smoke
# proof, SMOKE-B1 + SMOKE-B2 of docs/specs/2026-09-25-blind-audit-panel-plan.md.
#
# Named `smoke-*` on purpose: tests/run-all.sh globs `test-*.sh`, not this file, so it never joins
# the default suite. Run it directly:
#   TF_ALLOW_LOCAL=1 bash tests/hooks/smoke-blind-audit.sh                      # SMOKE-B1 only
#   TF_ALLOW_LOCAL=1 ZUVO_LIVE_SMOKE=1 bash tests/hooks/smoke-blind-audit.sh    # + SMOKE-B2 (real CLIs)
#
# SMOKE-B1 (always runs, fully hermetic — every driver/hook call under `env -i` with an explicit
# minimal environment, like tests/hooks/test-adversarial-blind-audit.sh's drive(), never this
# process's own PATH/TMPDIR/ZUVO_*): the 3-mock strict run end to end (merged block, adversarial.log
# rows naming the mocks, MOCK_CALL_LOG proving the call count), the post-skill hook still nagging
# when the only adversarial.log rows are blind-audit ones, the echo/one-valid/none-valid/oversize
# edges.
#
# SMOKE-B2 (only with ZUVO_LIVE_SMOKE=1): ONE real run of the repo driver against real model CLIs,
# pinned agy + codex-5.3. Host-aware WITHOUT reimplementing host detection AND without ever passing
# vacuously (S1, Plan B Task 10 review round 3): the host comes from the driver's OWN stderr — the
# "Host detected: <h> -- ..." line `--list-providers --mode blind-audit` prints before any mode
# branch runs (verified live, not assumed) — never a re-extracted/eval'd copy of
# detect_host_platform() and never a re-typed copy of its lane->vendor case. bap_vendor_excluded(<h>)
# (the sourced scripts/lib/blind-audit-panel.sh) then gives the excluded-lane set the expected pins
# and the "no host-vendor lane" checks both key off. An independent oracle (CLAUDECODE set -> host
# MUST be claude) and a "detection failed or the excluded set is empty is always a FAIL" rule keep
# this from ever passing on a host that was not actually detected. Never conflated with "not
# installed" (which --list-providers's candidate list alone cannot distinguish from "host-excluded"
# — a machine with agy simply not logged in would silently pass a candidate-list-derived pin check).
#
# Exit contract: 0 every executed part passed; 75 the live panel got < 2 valid answers AND >= 1
# provider outcome was non-ok AND every non-ok outcome is infra (timeout/auth/quota/unavailable — an
# outage, not a code bug; an all-`ok` panel with < 2 valid, e.g. only one lane survived
# exclusion/allowlisting, has ZERO non-ok outcomes and so is NEVER excused); 1 anything else. Every
# executed PASS/FAIL check appends one line to zuvo/proofs/smoke-plan-b.txt (truncated at the top of
# this run); an N/A (no pin legitimately expected on this host, no codex lane in this panel) prints a
# NOTE line instead and is never counted as executed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd -P)"
cd "$ROOT" || { echo "FAIL: cannot cd to repo root $ROOT"; exit 1; }

AR="$ROOT/scripts/adversarial-review.sh"
LIB="$ROOT/scripts/lib/blind-audit-panel.sh"
MOCKS="$ROOT/tests/adversarial/mocks"
FXLIVE="$ROOT/tests/hooks/fixtures/blind-audit-live"
HOOK="$ROOT/hooks/post-skill-adversarial-check.sh"

PROOF_DIR="$ROOT/zuvo/proofs"
PROOF="$PROOF_DIR/smoke-plan-b.txt"
mkdir -p "$PROOF_DIR"
: > "$PROOF"

EXECUTED=0
FAILED=0

# record <PASS|FAIL> <name> <evidence...> — one proof line, also echoed to our own stdout. Counted.
record() {
  local status="$1" name="$2"; shift 2
  local ev="$*"
  EXECUTED=$((EXECUTED + 1))
  if [ "$status" != PASS ]; then FAILED=$((FAILED + 1)); fi
  ev="$(printf '%s' "$ev" | tr '\n\t' '  ')"
  if [ "${#ev}" -gt 400 ]; then ev="${ev:0:400}…"; fi
  printf '%s\t%s\t%s\n' "$status" "$name" "$ev" >> "$PROOF"
  echo "  $status $name — $ev"
}

# note <name> <evidence...> — an N/A: printed and logged for traceability, but NEVER counted as an
# executed check (F4) — a machine without a codex lane in the panel, or a host that excludes neither
# pin, proves nothing either way and must not inflate the executed count with a vacuous pass.
note() {
  local name="$1"; shift
  local ev="$*"
  ev="$(printf '%s' "$ev" | tr '\n\t' '  ')"
  printf 'NOTE\t%s\t%s\n' "$name" "$ev" >> "$PROOF"
  echo "  NOTE $name — $ev"
}

# Precondition failures are recorded too (F10) — a reader of the proof file must see WHY nothing
# else ran, not just an empty file next to a bare exit 1.
[ -f "$AR" ]  || { record FAIL "precondition: driver present" "not found: $AR"; exit 1; }
[ -f "$LIB" ] || { record FAIL "precondition: panel library present" "not found: $LIB"; exit 1; }
[ -f "$HOOK" ] || { record FAIL "precondition: post-skill hook present" "not found: $HOOK"; exit 1; }
[ -f "$FXLIVE/sum.sh" ] && [ -f "$FXLIVE/sum.test.sh" ] \
  || { record FAIL "precondition: live fixtures present" "missing under $FXLIVE"; exit 1; }
command -v jq >/dev/null 2>&1 || { record FAIL "precondition: jq available" "jq not found on PATH"; exit 1; }

# The panel library is sourced once, here: safe under our own `set -uo pipefail` by its own contract
# (nothing external runs at source time, no shell option/trap of ours is touched) — gives us
# bap_vendor_excluded for both F2 (expected pins) and F3 (no host-vendor lane) in SMOKE-B2, the
# driver's real vendor-exclusion table, never a re-guess of it.
# shellcheck source=scripts/lib/blind-audit-panel.sh
. "$LIB"

echo "== smoke-blind-audit: Plan B Task 10 =="

# ═══════════════════════════════════════════════════════════════════════════
# SMOKE-B1 — mock panel end to end, gates unaffected (always runs, fully hermetic)
# ═══════════════════════════════════════════════════════════════════════════
echo "-- SMOKE-B1: mock panel (hermetic) --"

T="$(mktemp -d)" || { record FAIL "precondition: mktemp -d" "mktemp -d failed"; exit 1; }
trap 'rm -rf "$T"' EXIT

SHIM="$T/shim"; mkdir -p "$SHIM"
# shellcheck source=tests/lib/hermetic-tools.sh
. "$ROOT/tests/lib/hermetic-tools.sh"
hermetic_link_tools "$SHIM" timeout:gtimeout gtimeout:timeout jq
[ -e "$SHIM/timeout" ] || { record FAIL "precondition: GNU timeout available" "the driver cannot run without it"; exit 1; }
[ -e "$SHIM/jq" ] || { record FAIL "precondition: jq available (shim)" "the driver cannot run without it"; exit 1; }

TMPD="$T/tmp"; WORK="$T/work"; B1HOME="$T/home"
mkdir -p "$TMPD" "$WORK" "$B1HOME"
B1_ZUVO_HOME="$B1HOME/.zuvo"
BASE_PATH="$SHIM:$MOCKS:/usr/bin:/bin"

SRC="$T/src"; mkdir -p "$SRC"
P="$SRC/p.sh"; TT="$SRC/p.test.sh"
printf '#!/bin/sh\np() { echo hi; }\n' > "$P"
printf '#!/bin/sh\ntrue\n' > "$TT"

# drive <tag> [EXTRA_ENV=val ...] -- <driver args...> — F7: every B1 driver call runs under `env -i`
# with an EXPLICIT minimal environment (HOME, ZUVO_HOME, TMPDIR=$T/tmp, PATH, the harness vars) —
# never this process's own environment, so a stray ZUVO_BLIND_AUDIT_PANEL or a real TMPDIR in the
# CALLER's shell can never leak into what is supposed to be a fully mocked, isolated run. Modelled on
# tests/hooks/test-adversarial-blind-audit.sh's own drive().
drive() {
  local tag="$1" rc=0; shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  ( cd "$WORK" && env -i HOME="$B1HOME" ZUVO_HOME="$B1_ZUVO_HOME" TMPDIR="$TMPD" \
      ZUVO_NO_CAFFEINATE=1 ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_PROVIDER_BENCH=0 \
      ZUVO_CODEX_BIN=/nonexistent ZUVO_CODEX_APP_BIN=/nonexistent \
      PATH="$BASE_PATH" "${envs[@]}" bash "$AR" "$@" ) > "$T/$tag.out" 2> "$T/$tag.err" || rc=$?
  return "$rc"
}
out() { cat "$T/$1.out" 2>/dev/null; }
# drive_hook <tag> <stdin-text> — F7/S7: the post-skill hook, the SAME hermetic env as drive() (not
# just HOME/PATH) — ZUVO_HOME and TMPDIR unused by the hook today, but kept identical for the same
# reason drive() has them: nothing about what this call can see should depend on which vars happen
# to matter this week.
drive_hook() {
  local tag="$1" input="$2" rc=0
  printf '%s' "$input" | env -i HOME="$B1HOME" ZUVO_HOME="$B1_ZUVO_HOME" TMPDIR="$TMPD" \
    ZUVO_NO_CAFFEINATE=1 PATH="$BASE_PATH" bash "$HOOK" > "$T/$tag.out" 2> "$T/$tag.err" || rc=$?
  return "$rc"
}

# B1.1 — the 3-mock strict run, end to end, incl. the ledger. F9: also proves the log MECHANISM
# itself — the 3 rows NAME the 3 mocks (col 14) and MOCK_CALL_LOG recorded exactly 3 calls — so
# B1.6's "0 calls" later is meaningful evidence, not an untested assertion about an untested log.
rc=0
drive b11 ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix mock-strict-rewrite" \
  MOCK_CALL_LOG="$T/b11.calls" -- --mode blind-audit --production "$P" --test "$TT" || rc=$?
out="$(out b11)"
ok=1; why=""
[ "$rc" -eq 0 ] || { ok=0; why="$why exit=$rc"; }
printf '%s\n' "$out" | sed -n 1p | grep -qx 'Audit mode: strict' || { ok=0; why="$why line1"; }
printf '%s\n' "$out" | grep -qx 'Coverage verdict: REWRITE' || { ok=0; why="$why verdict"; }
printf '%s\n' "$out" | grep -q '^Audit panel: strict valid=3/3' || { ok=0; why="$why panel-line"; }
printf '%s\n' "$out" | grep -q 'mock-strict-fix:' || { ok=0; why="$why fix-row"; }
n_rows="$(awk -F'\t' '$1 != "SUMMARY" && $3 == "blind-audit" { n++ } END { print n + 0 }' "$B1_ZUVO_HOME/adversarial.log" 2>/dev/null)"
[ "$n_rows" = 3 ] || { ok=0; why="$why log-rows=$n_rows"; }
for m in mock-strict-clean mock-strict-fix mock-strict-rewrite; do
  awk -F'\t' -v p="$m" '$1 != "SUMMARY" && $3 == "blind-audit" && $14 == p { found = 1 } END { exit !found }' \
    "$B1_ZUVO_HOME/adversarial.log" 2>/dev/null || { ok=0; why="$why log-missing-$m"; }
done
calls_n="$(wc -l < "$T/b11.calls" 2>/dev/null | tr -d ' ')"; [ -n "$calls_n" ] || calls_n=0
[ "$calls_n" = 3 ] || { ok=0; why="$why calls=$calls_n"; }
if [ "$ok" = 1 ]; then record PASS "B1.1 3-mock strict run (log names the 3 mocks, 3 calls recorded)" "exit=$rc rows=$n_rows calls=$calls_n"
else record FAIL "B1.1 3-mock strict run" "mismatch:$why exit=$rc out_head=$(printf '%s' "$out" | head -3 | tr '\n' '|')"
fi

# B1.2 — the post-skill hook still reminds: HOME=$B1HOME's adversarial.log holds ONLY blind-audit
# rows (from B1.1), which the gate must NOT count as evidence a review ran (Task 2 / X1).
drive_hook b12 'zuvo:build was just run'; hook_rc=$?
hook_out="$(out b12)"
if [ "$hook_rc" -eq 0 ] && printf '%s' "$hook_out" | grep -q 'MANDATORY'; then
  record PASS "B1.2 post-skill hook still reminds (blind-audit rows don't count as review)" "rc=$hook_rc"
else
  record FAIL "B1.2 post-skill hook still reminds" "rc=$hook_rc out=$(printf '%s' "$hook_out" | head -c 200)"
fi

# B1.3 — an echo provider in the panel: valid=2/3, exit 0.
rc=0
drive b13 ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix mock-echo-prompt" \
  -- --mode blind-audit --production "$P" --test "$TT" || rc=$?
out="$(out b13)"
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^Audit panel: strict valid=2/3'; then
  record PASS "B1.3 echo provider -> valid=2/3, exit 0" "exit=$rc"
else
  record FAIL "B1.3 echo provider -> valid=2/3, exit 0" "exit=$rc out_head=$(printf '%s' "$out" | sed -n 2p)"
fi

# B1.4 — exactly one valid answer: exit 3 (degraded).
rc=0
drive b14 ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-invalid-block mock-fail" \
  -- --mode blind-audit --production "$P" --test "$TT" || rc=$?
out="$(out b14)"
if [ "$rc" -eq 3 ] && printf '%s\n' "$out" | grep -q 'Audit panel: degraded valid=1/3'; then
  record PASS "B1.4 one valid -> exit 3 (degraded)" "exit=$rc"
else
  record FAIL "B1.4 one valid -> exit 3 (degraded)" "exit=$rc out_head=$(printf '%s' "$out" | sed -n 2p)"
fi

# B1.5 — no valid answer: exit 2, stdout EMPTY.
rc=0
drive b15 ZUVO_REVIEW_TEST_PROVIDERS="mock-invalid-block mock-echo-prompt mock-fail" \
  -- --mode blind-audit --production "$P" --test "$TT" || rc=$?
out="$(out b15)"
if [ "$rc" -eq 2 ] && [ -z "$out" ]; then
  record PASS "B1.5 no valid answer -> exit 2, empty stdout" "exit=$rc"
else
  record FAIL "B1.5 no valid answer -> exit 2, empty stdout" "exit=$rc out_len=${#out}"
fi

# B1.6 — a 400001-byte production file: exit 6, and NO provider was ever invoked (a mock call-log
# proves it — not only the exit code; meaningful because B1.1 just proved the same log mechanism
# correctly records 3/3 calls when 3 lanes DO run).
HUGE="$SRC/huge.sh"
head -c 400001 /dev/zero | tr '\0' 'x' > "$HUGE"
huge_sz="$(wc -c < "$HUGE" | tr -d ' ')"
# S6: pre-create the log EMPTY, so "still exists and is empty" is what we check — an ABSENT file
# must never silently read as "0 calls" (the old `wc -l < missing-file 2>/dev/null` produced no
# output, which the fallback then turned into 0, indistinguishable from a real zero-calls run).
: > "$T/b16.calls"
rc=0
drive b16 ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix mock-strict-rewrite" \
  MOCK_CALL_LOG="$T/b16.calls" -- --mode blind-audit --production "$HUGE" --test "$TT" || rc=$?
calls_log_state="absent"
if [ -f "$T/b16.calls" ]; then
  if [ -s "$T/b16.calls" ]; then calls_log_state="non-empty:$(wc -l < "$T/b16.calls" | tr -d ' ') lines"
  else calls_log_state="present-and-empty"; fi
fi
if [ "$rc" -eq 6 ] && [ "$huge_sz" = 400001 ] && [ "$calls_log_state" = "present-and-empty" ]; then
  record PASS "B1.6 400001-byte input -> exit 6, no provider invoked" "exit=$rc size=$huge_sz calls_log=$calls_log_state"
else
  record FAIL "B1.6 400001-byte input -> exit 6, no provider invoked" "exit=$rc size=$huge_sz calls_log=$calls_log_state"
fi

# ═══════════════════════════════════════════════════════════════════════════
# SMOKE-B2 — live panel, real model CLIs (only with ZUVO_LIVE_SMOKE=1)
# ═══════════════════════════════════════════════════════════════════════════
# B1 never touched this process's own HOME/PATH/TMPDIR (every call was `env -i` inside drive()), so
# there is nothing to restore here — $HOME is still the real one throughout.

live_ran=0
live_excused=0

echo "-- SMOKE-B2: live panel --"
if [ "${ZUVO_LIVE_SMOKE:-}" != "1" ]; then
  echo "SKIP live"
else
  live_ran=1

  # F8/S1: unset FIRST, before the host-detection probe below AND the live dispatch — a leaked
  # ZUVO_ADVERSARIAL_TEST_HARNESS from the caller must not turn the "Host detected:" probe into a
  # report about a mocked panel either.
  unset ZUVO_REVIEW_TEST_PROVIDERS ZUVO_ADVERSARIAL_TEST_HARNESS ZUVO_BLIND_AUDIT_PANEL \
    ZUVO_BLIND_AUDIT_ALLOWLIST ZUVO_REVIEW_PROVIDER ZUVO_REVIEW_PROVIDER_PICK

  # S1: host detection from the driver's OWN stderr — no awk-extracted/eval'd detect_host_platform(),
  # no copied lane->vendor case. `--list-providers --mode blind-audit` dispatches nothing (Task 4's
  # A4 case) and its stderr carries "Host detected: <h> -- ..." (verified live: that line is printed
  # by the shared host-exclusion prologue at scripts/adversarial-review.sh:~1618, which runs before
  # ANY mode branch — confirmed present for --list-providers --mode blind-audit specifically, not
  # assumed). candidates (stdout) is kept for B2.3's restored candidate-list cross-check.
  list_out="$(bash "$AR" --list-providers --mode blind-audit 2>"$T/b2-list.err")"; list_rc=$?
  candidates="$(printf '%s' "$list_out" | tr '\n' ' ')"
  host_line="$(grep -m1 -E '^[[:space:]]*Host detected:' "$T/b2-list.err" 2>/dev/null)"
  h="$(printf '%s' "$host_line" | sed -n 's/^[[:space:]]*Host detected:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*--.*/\1/p')"

  if [ "$list_rc" -eq 0 ] && [ -n "$h" ]; then
    record PASS "B2.0a host detected on the driver's own stderr" "host=[$h] line=[$host_line]"
  else
    record FAIL "B2.0a host detected on the driver's own stderr" \
      "list_rc=$list_rc host_line=[$host_line] stderr=$(cat "$T/b2-list.err" 2>/dev/null | tr '\n' '|')"
  fi

  # Independent oracle: this run is INSIDE Claude Code (CLAUDECODE is how the harness we are running
  # under marks that), so the detected host MUST be exactly "claude" — never trust the detector to
  # grade its own homework.
  if [ -n "${CLAUDECODE:-}" ]; then
    if [ "$h" = claude ]; then
      record PASS "B2.0b independent oracle: CLAUDECODE set -> detected host is claude" "h=[$h]"
    else
      record FAIL "B2.0b independent oracle: CLAUDECODE set -> detected host is claude" "h=[$h] CLAUDECODE=${CLAUDECODE}"
    fi
  fi

  excluded_lanes="$(bap_vendor_excluded "$h" 2>/dev/null)"
  if [ -z "$h" ] || [ -z "$excluded_lanes" ]; then
    record FAIL "B2.0c host vendor exclusion set is non-empty" \
      "h=[$h] excluded_lanes=[$excluded_lanes] — detection failing, or an empty excluded set, is always a FAIL"
  else
    record PASS "B2.0c host vendor exclusion set is non-empty" "h=[$h] excluded_lanes=[$excluded_lanes]"
  fi

  expected_pins=""
  for _pin in agy codex-5.3; do
    case " $excluded_lanes " in *" $_pin "*) ;; *) expected_pins="$expected_pins $_pin" ;; esac
  done
  expected_pins="${expected_pins# }"
  echo "  note: h=[$h] excluded_lanes=[$excluded_lanes] expected_pins=[$expected_pins] candidates=[$candidates]"

  # S4: the expected effort is DERIVED from the same env this live dispatch will see (unset -> high)
  # — never a hardcoded "high" — read BEFORE the dispatch so it reflects exactly what the caller had;
  # neither ZUVO_BLIND_AUDIT_EFFORT nor ZUVO_CODEX_EFFORT_AUDIT is in the unset list above.
  LIVE_BLIND_AUDIT_EFFORT="${ZUVO_BLIND_AUDIT_EFFORT:-${ZUVO_CODEX_EFFORT_AUDIT:-high}}"

  rc=0
  json_out="$(ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_PIN_PROVIDERS="agy codex-5.3" \
    bash "$AR" --mode blind-audit --production "$FXLIVE/sum.sh" --test "$FXLIVE/sum.test.sh" --json \
    2>"$T/b2.err")" || rc=$?

  status="$(printf '%s' "$json_out" | jq -r '.status' 2>/dev/null)"; : "${status:=}"
  valid_n="$(printf '%s' "$json_out" | jq -r '.valid_providers | length' 2>/dev/null)"; : "${valid_n:=0}"
  case "$valid_n" in ''|*[!0-9]*) valid_n=0 ;; esac
  outcomes="$(printf '%s' "$json_out" | jq -r '.provider_outcomes' 2>/dev/null)"; : "${outcomes:=}"
  merged="$(printf '%s' "$json_out" | jq -r '.merged_block // empty' 2>/dev/null)"

  if [ "$rc" -eq 0 ] && [ "$status" = strict ] && [ "$valid_n" -ge 2 ]; then
    record PASS "B2.1 exit 0, Audit panel: strict valid>=2" "exit=$rc status=$status valid=$valid_n"

    panel_line="$(printf '%s\n' "$merged" | sed -n 2p)"
    providers_field="$(printf '%s' "$panel_line" | sed -n 's/.*providers=\([^ ]*\).*/\1/p')"
    failed_field="$(printf '%s' "$panel_line" | sed -n 's/.* failed=\([^ ]*\)$/\1/p')"
    valid_names="$(printf '%s' "$providers_field" | tr ',' ' ')"
    failed_names="$(printf '%s' "$failed_field" | tr ',' '\n' | cut -d: -f1 | tr '\n' ' ')"
    all_names=" $valid_names $failed_names "

    # S2: every expected pin among the providers (dispatched, valid or not). A required pin missing
    # from the panel is a FAIL. Empty expected_pins is a NOTE ONLY when excluded_lanes legitimately
    # contains BOTH would-be pins — anything else (a computation bug that emptied expected_pins
    # without the vendor exclusion actually explaining it) is a FAIL, not a free pass.
    if [ -z "$expected_pins" ]; then
      case " $excluded_lanes " in *" agy "*) _agy_excl=1 ;; *) _agy_excl=0 ;; esac
      case " $excluded_lanes " in *" codex-5.3 "*) _cx_excl=1 ;; *) _cx_excl=0 ;; esac
      if [ "$_agy_excl" = 1 ] && [ "$_cx_excl" = 1 ]; then
        note "B2.2 expected pins present" "N/A — both legitimately excluded by host=$h (excluded=[$excluded_lanes])"
      else
        record FAIL "B2.2 expected pins present" \
          "expected_pins computed empty but excluded_lanes=[$excluded_lanes] (host=$h) does not legitimately explain it"
      fi
    else
      pin_ok=1; pin_missing=""
      for _pin in $expected_pins; do
        case "$all_names" in *" $_pin "*) ;; *) pin_ok=0; pin_missing="$pin_missing $_pin" ;; esac
      done
      if [ "$pin_ok" = 1 ]; then
        record PASS "B2.2 expected pins present" "expected=[$expected_pins] providers=[$all_names]"
      else
        record FAIL "B2.2 expected pins present" "missing=[$pin_missing] providers=[$all_names]"
      fi
    fi

    # S1: no host-vendor lane among EITHER the candidate list OR the dispatched providers — the SAME
    # excluded-lane set B2.0c computed (never a hardcoded "claude"), correct on a Codex/Antigravity/
    # Cursor/Kimi/Qwen host too. The candidate-list half is the restored cross-check: a lane that
    # never even CANDIDATES is a stronger guarantee than one that merely was not picked this run.
    host_lane_leak_candidates=""
    for _l in $excluded_lanes; do
      case " $candidates " in *" $_l "*) host_lane_leak_candidates="$host_lane_leak_candidates $_l" ;; esac
    done
    host_lane_leak_dispatched=""
    for _l in $excluded_lanes; do
      case "$all_names" in *" $_l "*) host_lane_leak_dispatched="$host_lane_leak_dispatched $_l" ;; esac
    done
    if [ -z "$host_lane_leak_candidates" ] && [ -z "$host_lane_leak_dispatched" ]; then
      record PASS "B2.3 no host-vendor lane among candidates or dispatched providers" \
        "excluded=[$excluded_lanes] candidates=[$candidates] providers=[$all_names]"
    else
      record FAIL "B2.3 no host-vendor lane among candidates or dispatched providers" \
        "leaked_candidates=[$host_lane_leak_candidates] leaked_dispatched=[$host_lane_leak_dispatched] excluded=[$excluded_lanes]"
    fi

    # S3: the fixture's OWN gap — the empty-input guard's line range in sum.sh, found by a
    # NESTING-AWARE, whitespace-tolerant awk: the start pattern tolerates flexible spacing around
    # `-z`/quotes/brackets, and a depth counter (any OTHER "if ... " line inside increments it) finds
    # the guard's OWN matching `fi`, not merely the next `fi` in the file (which a differently-shaped
    # fixture, or a guard containing a nested if, would get wrong).
    guard_range="$(awk '
        start == 0 && $0 ~ /^[[:space:]]*if[[:space:]]+\[[[:space:]]*-z[[:space:]]+"\$1"[[:space:]]*\]/ {
          start = NR; depth = 1; next
        }
        start > 0 {
          if (NR != start && $0 ~ /^[[:space:]]*if[[:space:]]/) depth++
          if ($0 ~ /^[[:space:]]*fi[[:space:]]*$/) {
            depth--
            if (depth == 0) { print start "-" NR; exit }
          }
        }
      ' "$FXLIVE/sum.sh")"
    g_start="${guard_range%%-*}"; g_end="${guard_range##*-}"
    if [ -z "$g_start" ] || [ -z "$g_end" ]; then
      record FAIL "B2.4 sum.sh's untested branch appears as a non-FULL row" \
        "could not locate the empty-input guard's line range in $FXLIVE/sum.sh by content"
    else
      table_rows="$(printf '%s\n' "$merged" | awk '
          $0 == "| id | kind | production lines | owned_or_delegated | coverage | test evidence | notes |" { intab = 1; next }
          intab && /^\|/ { if ($0 !~ /^\|[-:| ]+\|?$/) print; next }
          intab && $0 == "" { exit }
        ')"
      match_row=""
      while IFS= read -r _row; do
        [ -n "$_row" ] || continue
        _pl="$(printf '%s' "$_row" | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $4); print $4 }')"
        # S3: "production lines" may hold several comma-separated sub-ranges (e.g. "5, 9-12") with
        # arbitrary spacing around the dash ("7 - 10") — each sub-range is overlap-tested on its OWN,
        # never the outer span (a cell "3-4, 20-22" must not look like it covers everything 3..22).
        _pl_hit=0
        IFS=',' read -ra _subranges <<< "$_pl"
        for _sr in "${_subranges[@]}"; do
          _sr="$(printf '%s' "$_sr" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]]*-[[:space:]]*/-/')"
          case "$_sr" in
            *-*) _rs="${_sr%%-*}"; _re="${_sr##*-}" ;;
            *)   _rs="$_sr"; _re="$_sr" ;;
          esac
          case "$_rs" in ''|*[!0-9]*) continue ;; esac
          case "$_re" in ''|*[!0-9]*) continue ;; esac
          if [ "$_rs" -le "$g_end" ] && [ "$_re" -ge "$g_start" ]; then _pl_hit=1; fi
        done
        if [ "$_pl_hit" = 1 ]; then match_row="$_row"; break; fi
      done <<< "$table_rows"
      if [ -n "$match_row" ]; then
        record PASS "B2.4 sum.sh's untested branch (lines $guard_range) appears as a non-FULL row" "row=$match_row"
      else
        record FAIL "B2.4 sum.sh's untested branch (lines $guard_range) appears as a non-FULL row" \
          "no sub-range of any row's production-lines overlaps $guard_range; table=$(printf '%s' "$table_rows" | tr '\n' '|')"
      fi
    fi

    # S4: codex effort — read from the DRIVER's own stderr (the dispatch-loop announcement, D1's
    # single-source blind_audit_codex_effort()), never a raced poller against a temp dir a lane's own
    # runner subshell deletes moments after it finishes. EVERY announcement line for EVERY codex lane
    # in the panel is checked (never `head -1`), against an EXACT anchored token
    # (`effort=<value>` followed by whitespace or end of line), so "effort=highest" cannot pass as
    # "effort=high". <value> is LIVE_BLIND_AUDIT_EFFORT, derived from this run's own env, never
    # hardcoded. No codex lane in this panel -> NOTE, not counted (F4).
    codex_lanes_in_panel=""
    for _cl in codex-5.3 codex-5.4; do
      case "$all_names" in *" $_cl "*) codex_lanes_in_panel="$codex_lanes_in_panel $_cl" ;; esac
    done
    codex_lanes_in_panel="${codex_lanes_in_panel# }"
    if [ -z "$codex_lanes_in_panel" ]; then
      note "B2.5 codex effort $LIVE_BLIND_AUDIT_EFFORT" "N/A — no codex lane in this panel (providers=[$all_names])"
    else
      missing=""; evidence=""
      for _cl in $codex_lanes_in_panel; do
        _lane_lines="$(grep -E "^[[:space:]]*${_cl}:" "$T/b2.err" 2>/dev/null | tr '\n' '|')"
        _any="$(grep -c -E "^[[:space:]]*${_cl}:[[:space:]]*blind-audit[[:space:]]+effort=" "$T/b2.err" 2>/dev/null)"; : "${_any:=0}"
        _exact="$(grep -c -E "^[[:space:]]*${_cl}:[[:space:]]*blind-audit[[:space:]]+effort=${LIVE_BLIND_AUDIT_EFFORT}([[:space:]]|$)" "$T/b2.err" 2>/dev/null)"; : "${_exact:=0}"
        if [ "$_any" -eq 0 ]; then
          missing="$missing ${_cl}(no-line)"
        elif [ "$_exact" != "$_any" ]; then
          missing="$missing ${_cl}(wrong-effort:$_lane_lines)"
        else
          evidence="${evidence}${evidence:+; }$_lane_lines"
        fi
      done
      if [ -z "$missing" ]; then
        record PASS "B2.5 codex effort $LIVE_BLIND_AUDIT_EFFORT (driver stderr, every announcement line)" "$evidence"
      else
        record FAIL "B2.5 codex effort $LIVE_BLIND_AUDIT_EFFORT (driver stderr, every announcement line)" \
          "missing/wrong: [$missing] stderr_tail=$(tail -20 "$T/b2.err" | tr '\n' '|')"
      fi
    fi
  else
    # F1/S8: EXCUSED (exit 75) requires BOTH: >= 1 non-ok outcome (not merely "fewer than 2
    # dispatched" — an all-`ok` panel with valid < 2, e.g. exactly one lane survived
    # exclusion/allowlisting and it succeeded, has ZERO non-ok outcomes and is NEVER excused), AND
    # every non-ok outcome is infra (timeout/auth/quota/unavailable). `excused` used to start at 1
    # and only non-ok entries could clear it, so an all-ok/valid<2 panel passed vacuously.
    # S5: each token is CR-stripped and whitespace-trimmed before classifying it — a `\r` or a
    # stray space around a `,`/`:` must not slip "timeout " past an exact `case` match.
    outcomes_lines="$(printf '%s' "$outcomes" | tr -d '\r' | tr ',' '\n')"
    non_ok_present=0
    all_excused=1
    while IFS= read -r _entry; do
      _entry="${_entry#"${_entry%%[![:space:]]*}"}"; _entry="${_entry%"${_entry##*[![:space:]]}"}"
      [ -n "$_entry" ] || continue
      _oc="${_entry#*:}"
      _oc="${_oc#"${_oc%%[![:space:]]*}"}"; _oc="${_oc%"${_oc##*[![:space:]]}"}"
      [ "$_oc" = ok ] && continue
      non_ok_present=1
      case "$_oc" in timeout|auth|quota|unavailable) ;; *) all_excused=0 ;; esac
    done <<< "$outcomes_lines"
    if [ "$valid_n" -lt 2 ] && [ "$non_ok_present" = 1 ] && [ "$all_excused" = 1 ]; then
      live_excused=1
      record PASS "B2.1 live panel infra outage (excused: < 2 valid, >=1 failure, every failure timeout/auth/quota/unavailable)" \
        "exit=$rc status=$status valid=$valid_n outcomes=$outcomes"
    else
      record FAIL "B2.1 exit 0, Audit panel: strict valid>=2 (and not an excused outage)" \
        "exit=$rc status=$status valid=$valid_n outcomes=$outcomes"
    fi
  fi
fi

echo "=== SMOKE RESULT ==="
if [ "$live_ran" = 1 ]; then live_word=ran; else live_word=SKIP; fi
echo "RESULT: executed=$EXECUTED failed=$FAILED live=$live_word"
if [ "$live_excused" = 1 ] && [ "$FAILED" -eq 0 ]; then
  exit 75
elif [ "$FAILED" -eq 0 ] && [ "$EXECUTED" -gt 0 ]; then
  exit 0
else
  exit 1
fi
