#!/usr/bin/env bash
# Contract for zuvo-rewake-on-failure.sh — the StopFailure watchdog.
#
# Written after 2026-09-18, when a five-hour session limit turned this hook into a
# context flood: a dozen "Stop hook feedback" blocks a minute for hours, each one
# a wake that died on the same closed window. Every case below is one of the three
# defects that produced it, so the cases matter more than the coverage count.
#
# bash 3.2-compatible (macOS default). Runs in seconds: nothing here sleeps for
# real — the transient path pins the backoff env vars to 1s, and the limit path
# is killed mid-wait, so it is asserted by what gets SCHEDULED.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/zuvo-rewake-on-failure.sh"
RESET="$ROOT/hooks/zuvo-rewake-reset.sh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
[ -f "$HOOK" ] || { bad "hooks/zuvo-rewake-on-failure.sh does not exist"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export ZUVO_HOME="$TMP/zuvo"          # never touch the real ~/.zuvo counters
mkdir -p "$ZUVO_HOME/rewake"

payload() {
  jq -cn --arg e "$1" --arg d "$2" --arg s "${3:-sess-1}" \
    '{hook_event_name:"StopFailure", session_id:$s, error:$e, error_details:$d}'
}
# run <payload> [errfile] → prints the exit code
run() {
  printf '%s' "$1" | bash "$HOOK" 2>"${2:-$TMP/err}"
  printf '%s' "$?"
}

# 1. A session limit with NO reset instant must not wake at all.
# This is the flood itself. Claude Code already prints "Continuing automatically
# at <reset>" and resumes when the window reopens; a blind backoff on top of that
# retries into a window that cannot open, and each retry costs a turn of context.
rc=$(run "$(payload rate_limit 'Claude AI usage limit reached')")
if [ "$rc" = "0" ]; then pass "limit without a reset instant does not rewake"
else bad "limit without a reset instant exited $rc (expected 0 = no wake)"; fi

# 2. A limit WITH a reset instant wakes once, and only once per window.
# The epoch rides the raw API error body, and only a FUTURE one is trusted — a
# past epoch cannot be the window we are waiting for, and treating it as one
# would resurrect the immediate-retry flood. So this case dates it just ahead of
# now and kills the process during its wait: what is asserted is the schedule the
# hook wrote, not the wake it would eventually fire.
now=$(date +%s); soon=$(( now + 120 )); sess=flood-window
printf '%s' "$(payload rate_limit "Claude AI usage limit reached|$soon" "$sess")" >"$TMP/p1"
bash "$HOOK" <"$TMP/p1" >/dev/null 2>&1 &
hookpid=$!
sleep 2
kill "$hookpid" 2>/dev/null || true
wait "$hookpid" 2>/dev/null || true
if [ "$(cat "$ZUVO_HOME/rewake/$sess.window" 2>/dev/null)" = "$soon" ]; then
  pass "a reset instant is recorded as the window stamp"
else bad "window stamp not written (got '$(cat "$ZUVO_HOME/rewake/$sess.window" 2>/dev/null)', expected $soon)"; fi

rc=$(run "$(payload rate_limit "Claude AI usage limit reached|$soon" "$sess")")
if [ "$rc" = "0" ]; then pass "a second failure in the same reset window does not wake again"
else bad "same-window failure exited $rc (expected 0 = one wake per window)"; fi

# 3. The per-session ceiling must actually bind. It did not before: the Stop hook
# cleared the only counter between failures, so the cap was unreachable.
sess="cap-binds"
printf '10' > "$ZUVO_HOME/rewake/$sess.total"
export ZUVO_REWAKE_TOTAL_CAP=10 ZUVO_REWAKE_BACKOFF_OTHER=1
rc=$(run "$(payload unknown '' "$sess")")
unset ZUVO_REWAKE_TOTAL_CAP ZUVO_REWAKE_BACKOFF_OTHER
if [ "$rc" = "0" ]; then pass "the per-session ceiling stops the wakes, silently"
else bad "at the session cap the hook exited $rc (expected 0: waking to announce it gave up is also a flood)"; fi

# 4. The Stop hook must NOT clear that ceiling.
printf '%s' "$(jq -cn --arg s "$sess" '{session_id:$s}')" | bash "$RESET" >/dev/null 2>&1
if [ -f "$ZUVO_HOME/rewake/$sess.total" ]; then pass "a clean stop leaves the lifetime counter intact"
else bad "the Stop hook deleted \$sid.total — the cap is unreachable again (this WAS the bug)"; fi
if [ ! -f "$ZUVO_HOME/rewake/$sess.count" ]; then pass "a clean stop still clears the consecutive counter"
else bad "the Stop hook no longer clears \$sid.count"; fi

# 5. Transient errors still resume — the fix must not switch the watchdog off.
export ZUVO_REWAKE_BACKOFF_SE=1
rc=$(run "$(payload overloaded '' sess-transient)" "$TMP/e5")
unset ZUVO_REWAKE_BACKOFF_SE
if [ "$rc" = "2" ] && grep -q 'RESUME the work' "$TMP/e5"; then
  pass "a transient overload still wakes Claude to resume"
else bad "transient overload exited $rc (expected 2 with a resume instruction)"; fi

# 6. The error type is read from the field the harness actually sends. `.error`
# is the real key; the old code read `.error_type`, so every failure — including
# a five-hour limit — classified as "unknown" and took the transient path. The
# tell is the window stamp: only the limit branch writes one, so its presence
# proves `.error` was read, and its absence proves the payload fell through to
# the generic path. (Asserting on the exit code cannot separate them — since the
# transient-rate-limit split both branches legitimately exit 2.)
sess="sess-field"
fut=$(( $(date +%s) + 300 ))
bash "$HOOK" <<EOF >/dev/null 2>&1 &
$(payload rate_limit "usage limit reached|$fut" "$sess")
EOF
hookpid=$!; sleep 2; kill "$hookpid" 2>/dev/null || true; wait "$hookpid" 2>/dev/null || true
if [ "$(cat "$ZUVO_HOME/rewake/$sess.window" 2>/dev/null)" = "$fut" ]; then
  pass "the limit class is read from .error, not .error_type"
else bad "a .error=rate_limit payload never reached the limit branch — field misread"; fi

# 8. `rate_limit` covers two failures needing OPPOSITE handling, and the payload does not say
# which. Measured 2026-09-18: 186 of 186 `rate_limit` events carried an EMPTY `error_details`,
# so "no wording" is what a five-hour SESSION limit looks like here — not evidence of a transient
# one. The first version of this fix read the absence as transient and woke, reproducing the flood
# across 13 parallel sessions. An evidence-FREE rate limit must therefore stay silent; only
# POSITIVE evidence of a per-minute limit may wake.
rc=$(run "$(payload rate_limit '' sess-noevidence)")
if [ "$rc" = "0" ]; then pass "an evidence-free rate limit stays silent (the empty-payload case, 186/186)"
else bad "an empty-details rate limit exited $rc (expected 0) — this is the live flood case"; fi

export ZUVO_REWAKE_BACKOFF_RL=1
rc=$(run "$(payload rate_limit '429 too many requests, retry after 30s' sess-rpm)" "$TMP/e8")
unset ZUVO_REWAKE_BACKOFF_RL
if [ "$rc" = "2" ] && grep -q 'RESUME the work' "$TMP/e8"; then
  pass "a rate limit with POSITIVE transient evidence still resumes the turn"
else bad "an explicitly transient rate limit exited $rc (expected 2) — nothing else resumes that one"; fi

# The opt-out for a harness that does NOT auto-continue: then the absence takes the backoff again.
export ZUVO_REWAKE_BACKOFF_RL=1 ZUVO_REWAKE_RL_TRANSIENT=1
rc=$(run "$(payload rate_limit '' sess-optin)" "$TMP/e8b")
unset ZUVO_REWAKE_BACKOFF_RL ZUVO_REWAKE_RL_TRANSIENT
if [ "$rc" = "2" ]; then pass "ZUVO_REWAKE_RL_TRANSIENT=1 restores waking on an evidence-free limit"
else bad "the opt-in did not restore waking (exit $rc) — hosts without auto-continue lose the watchdog"; fi

rc=$(run "$(payload rate_limit 'You have hit your usage limit' sess-usage)")
if [ "$rc" = "0" ]; then pass "an explicit usage limit stays silent"
else bad "usage limit exited $rc (expected 0 — the harness resumes this one itself)"; fi

# 9. The housekeeping sweep must not eat the counter it is meant to protect.
# It ran FIRST and unscoped, so it deleted this session's own lifetime counter
# before reading it — and a weekly limit recurs at about the old 7-day threshold,
# i.e. exactly in the case the rewrite exists to bound.
sess="sweep-safety"
printf '3' > "$ZUVO_HOME/rewake/$sess.total"
printf '%s' "$(date +%s)" > "$ZUVO_HOME/rewake/$sess.window"
touch -t 202501010000 "$ZUVO_HOME/rewake/$sess.total" "$ZUVO_HOME/rewake/$sess.window"
export ZUVO_REWAKE_BACKOFF_OTHER=1
rc=$(run "$(payload unknown '' "$sess")")
unset ZUVO_REWAKE_BACKOFF_OTHER
if [ "$(cat "$ZUVO_HOME/rewake/$sess.total" 2>/dev/null)" = "4" ]; then
  pass "an old lifetime counter is read and incremented, not swept away first"
else bad "lifetime counter was $(cat "$ZUVO_HOME/rewake/$sess.total" 2>/dev/null || echo GONE) after an old-mtime run (expected 4) — the sweep ate the cap again"; fi

# 10. The consecutive cap must be reachable. `n` only increments alongside `t`,
# so n <= t always; a CAP above TOTAL_CAP is unreachable dead code, which is what
# shipped (20 against a total of 10).
capdef=$(sed -n 's/^CAP=$(_num "${ZUVO_REWAKE_CAP:-\([0-9]*\)}".*/\1/p' "$HOOK")
totdef=$(sed -n 's/^TOTAL_CAP=$(_num "${ZUVO_REWAKE_TOTAL_CAP:-\([0-9]*\)}".*/\1/p' "$HOOK")
if [ -n "$capdef" ] && [ -n "$totdef" ] && [ "$capdef" -lt "$totdef" ]; then
  pass "the consecutive cap ($capdef) is tighter than the lifetime cap ($totdef), so it can fire"
else bad "consecutive cap '$capdef' is not below lifetime cap '$totdef' — it is unreachable dead code"; fi

# 11. A session id becomes a filename. A payload carrying path separators must
# not write outside the counter directory.
rc=$(run "$(payload unknown '' '../../escaped')" 2>/dev/null)
if [ ! -e "$ZUVO_HOME/escaped.total" ] && [ ! -e "$TMP/escaped.total" ]; then
  pass "a path-traversing session id cannot write outside the counter directory"
else bad "counter file escaped \$cdir via the session id"; fi

# 7. The payload journal exists. Defect 1 stayed invisible for months because
# nothing ever recorded what the hook actually received.
if [ -s "$ZUVO_HOME/rewake/payloads.log" ] && grep -q 'rate_limit' "$ZUVO_HOME/rewake/payloads.log"; then
  pass "received payloads are journalled for diagnosis"
else bad "no payload journal written — the next field-name change is invisible again"; fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
