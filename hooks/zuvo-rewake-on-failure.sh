#!/usr/bin/env bash
# zuvo-rewake-on-failure.sh — StopFailure hook (async + asyncRewake).
#
# Fires when a turn dies on an API error. Registered with asyncRewake, so it runs
# in the background, waits, then exits 2 — which WAKES Claude and shows this
# script's stderr as a system reminder, so the killed turn resumes where it
# stopped.
#
# ─────────────────────────────────────────────────────────────────────────────
# 2026-09-18 — WHY THIS WAS REWRITTEN (read before "simplifying" it back)
#
# On a five-hour SESSION LIMIT this hook turned into a context flood: every wake
# died instantly on the same limit, which fired StopFailure again, which woke
# Claude again — a dozen "Stop hook feedback" blocks per minute, each one eating
# context, for the hours until the window reopened. Three separate defects:
#
#   1. WRONG FIELD. The payload key is `.error` (enum: authentication_failed,
#      oauth_org_not_allowed, account_on_hold, verification_required,
#      billing_error, rate_limit, overloaded, invalid_request, model_not_found,
#      server_error, unknown, max_output_tokens, cloud_credential_error).
#      The old code read `.error_type // .stop_failure_reason // .reason //
#      .matcher`, none of which exist — so EVERY failure, including a five-hour
#      limit, was classified "unknown" and got the 30-second backoff.
#   2. THE CAP NEVER BOUND. `$sid.count` is cleared by the Stop hook on every
#      clean turn end, and a limit-killed wake still ends the turn cleanly — so
#      the counter was reset before it could ever reach the cap. Measured: all
#      363 counter files on this machine held a single digit, max 6, cap 20.
#   3. WAKING TO SAY "I GAVE UP" IS ALSO A FLOOD. The cap branch exited 2, i.e.
#      it woke Claude to announce that it had stopped waking Claude.
#
# Fixes, in the same order: read `.error` first; keep a SECOND per-session
# counter (`$sid.total`) that the Stop hook does not clear, and exit 0 (silent)
# when it binds; and for the limit class, wait for the actual reset instant
# instead of retrying into a closed window — at most once per reset window.
# ─────────────────────────────────────────────────────────────────────────────
#
# Non-retryable errors (auth/billing/invalid_request/model_not_found) are excluded
# by the hooks.json matcher and never rewake.

input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 1   # no jq: cannot parse → stay dead rather than rewake blindly

ZH="${ZUVO_HOME:-$HOME/.zuvo}"
cdir="$ZH/rewake"
if ! mkdir -p "$cdir" 2>/dev/null || ! : > "$cdir/.probe" 2>/dev/null; then
  # The caps live in this directory. If it is unwritable the counters cannot
  # persist, every invocation reads 0, and NEITHER cap can ever bind — the same
  # unbounded-wake state defect 2 produced, reached by a different route. Say so
  # on stderr and do not wake: an uncapped watchdog is worse than none.
  printf 'zuvo-watchdog: %s is not writable, so the auto-resume caps cannot be enforced — not rewaking. Fix the directory or set ZUVO_HOME.\n' "$cdir" >&2
  exit 0
fi
rm -f "$cdir/.probe" 2>/dev/null || true

sid=$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null)
# The session id becomes a FILENAME below. A payload carrying `/` or `..` in it
# would write outside $cdir, so keep only what a session id is actually made of.
sid=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-96)
case "$sid" in ''|'.'|'..'|-*) sid="unknown" ;; esac
# `.error` is the real key (see header). The rest are legacy fallbacks kept only
# so an older/newer build that renames the field still classifies instead of
# silently degrading to "unknown" — which is how defect 1 stayed invisible.
etype=$(printf '%s' "$input" | jq -r '.error // .error_type // .stop_failure_reason // .reason // "unknown"' 2>/dev/null)
case "$etype" in ''|null) etype="unknown" ;; esac
details=$(printf '%s' "$input" | jq -r '.error_details // ""' 2>/dev/null)
# The UI's "resets 10pm" line is NOT in this payload. Measured 2026-09-18: 186 of 186
# `rate_limit` events carried an EMPTY `error_details`, which is why the wording match below
# cannot be the primary signal. Journal the key set and the tail of the last assistant message
# too, so the next person answers this from data instead of re-deriving it.
keys=$(printf '%s' "$input" | jq -rc 'keys' 2>/dev/null)
# `last_assistant_message` is deliberately NOT captured. It was journalled for 200 chars while the
# classifier still read it; the classifier no longer does (the assistant's own prose about rate
# limits was matching), so persisting it bought nothing and wrote whatever the conversation last
# contained — a pasted key, a customer address, a connection string — into a file on disk.
lastmsg_present=$(printf '%s' "$input" | jq -r 'if (.last_assistant_message // "") == "" then "no" else "yes" end' 2>/dev/null)

# Payload journal — bounded. Defect 1 survived for months because nothing ever
# recorded what the hook actually received; a claim about the payload shape is
# now checkable instead of remembered.
log="$cdir/payloads.log"
{
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$sid" "$etype" \
    "$(printf '%s' "$details" | tr '\n\t' '  ' | cut -c1-400)" "$keys" "lastmsg=$lastmsg_present"
} >> "$log" 2>/dev/null || true
if [ "$(wc -l < "$log" 2>/dev/null || echo 0)" -gt 500 ]; then
  tail -n 300 "$log" > "$log.tmp" 2>/dev/null && mv "$log.tmp" "$log" 2>/dev/null || true
fi

# Housekeeping runs at the END of this script (see _sweep, called before every
# exit path), never here. Reviewed 2026-09-18: sweeping first, unscoped, deleted
# THIS session's $sid.total and $sid.window before they were read — and a weekly
# limit recurs at roughly the sweep's own threshold, so the counter that is
# supposed to be immune to clearing was being wiped in exactly the case the
# rewrite exists to bound. The sweep now skips the current session and keeps a
# retention window far longer than any reset window.
_sweep() {
  find "$cdir" -maxdepth 1 \( -name '*.count' -o -name '*.total' -o -name '*.window' \) \
       -mtime +30 ! -name "$sid.*" -delete 2>/dev/null || true
}

_num() { case "$1" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$1" ;; esac; }

cf="$cdir/$sid.count"    # consecutive failures — cleared by the Stop hook
tf="$cdir/$sid.total"    # per-session lifetime — NOT cleared by anything
n=$(_num "$(cat "$cf" 2>/dev/null)")
t=$(_num "$(cat "$tf" 2>/dev/null)")

# `n` only ever increments alongside `t`, so n <= t always holds and a CAP above
# TOTAL_CAP is unreachable dead code — the consecutive cap must be the tighter of
# the two to mean anything. (It shipped at 20 against a total of 10 and could
# never fire.) A non-numeric override is ignored rather than silently disabling
# the comparison, which `[` would otherwise treat as false.
CAP=$(_num "${ZUVO_REWAKE_CAP:-5}");         [ "$CAP" -gt 0 ] || CAP=5
TOTAL_CAP=$(_num "${ZUVO_REWAKE_TOTAL_CAP:-10}"); [ "$TOTAL_CAP" -gt 0 ] || TOTAL_CAP=10

# Hard per-session ceiling. Silent: waking to announce that we stopped waking is
# the flood we are fixing.
if [ "$t" -ge "$TOTAL_CAP" ]; then
  printf '%s\tsession-cap-reached\t%s\n' "$(date -u +%FT%TZ)" "$sid" >> "$log" 2>/dev/null || true
  _sweep; exit 0
fi
if [ "$n" -ge "$CAP" ]; then
  printf '%s\tconsecutive-cap-reached\t%s\n' "$(date -u +%FT%TZ)" "$sid" >> "$log" 2>/dev/null || true
  _sweep; exit 0
fi

# ---- usage / session limit: wait for the window, do not retry into it ---------
# A five-hour or weekly limit is not a transient error. Retrying before the reset
# instant cannot succeed, so the only useful wait is "until it reopens".
case "$etype" in
  rate_limit)
    [ "${ZUVO_REWAKE_LIMIT:-1}" = "0" ] && { _sweep; exit 0; }   # opt out entirely

    now=$(date +%s)
    # Reset instant, in order of trustworthiness: an explicit payload field, then
    # a unix epoch embedded in the raw API error message (Anthropic's usage-limit
    # body carries `…|<epoch>`; the same value rides the
    # anthropic-ratelimit-unified-reset header).
    reset=$(printf '%s' "$input" | jq -r '.rate_limit_reset // .resets_at // .resetsAt // empty' 2>/dev/null)
    case "$reset" in ''|null|*[!0-9]*) reset="" ;; esac
    if [ -z "$reset" ]; then
      for cand in $(printf '%s' "$details" | grep -o '[0-9]\{10\}' 2>/dev/null); do
        # plausible only if it is ahead of now and inside a week
        if [ "$cand" -gt "$now" ] && [ "$cand" -lt "$((now + 604800))" ]; then reset="$cand"; break; fi
      done
    fi

    # No reset instant. `rate_limit` covers TWO different failures and they need
    # opposite handling, which the first version of this fix missed: a five-hour
    # or weekly USAGE limit (hours away, Claude Code prints "Continuing
    # automatically at <reset>" and resumes by itself — waking is duplication at
    # best and a flood at worst), and an ordinary per-minute API rate limit
    # (seconds away, nothing else resumes it, and exiting 0 abandons the turn for
    # good). With no epoch to go on, the wording of the raw error is the only
    # thing that separates them.
    if [ -z "$reset" ]; then
      # NO EPOCH, and — measured — no wording either: 186 of 186 `rate_limit` events on this
      # harness carried an EMPTY `error_details`. The first version of this fix read that absence
      # as "probably a transient per-minute limit" and woke; in practice it is what a five-hour
      # SESSION limit looks like here, so the absence-means-transient default reproduced the
      # flood it was written to stop — 13 parallel sessions each waking on a window that was
      # hours from reopening. With no evidence either way the harness's own behaviour decides it:
      # Claude Code prints "Continuing automatically at <reset>" and resumes the turn itself, so
      # the safe default is to stay out of its way.
      #
      # Set ZUVO_REWAKE_RL_TRANSIENT=1 on a host whose harness does NOT auto-continue; then an
      # evidence-free rate limit takes the short backoff instead, still bounded by the caps above.
      # Read the evidence from the API error ONLY, never from `$lastmsg`. The assistant's own last
      # message is prose it wrote, and a session that was DISCUSSING rate limits (this one, while
      # the hook was being written) would match `rpm`/`retry after` there and classify a five-hour
      # session limit as transient — the model talking about the bug would re-create the bug.
      case "$(printf '%s' "$details" | tr 'A-Z' 'a-z')" in
        *retry\ after*|*too\ many\ requests*|*requests\ per\ minute*|*tokens\ per\ minute*)
          : ;;                                    # positive evidence of a transient limit
          # Bare `rpm`/`tpm` were here and matched any string CONTAINING them — `no such package:
          # python3-rpm` classified a five-hour limit as transient. A `case` glob has no word
          # boundary, so the abbreviations cannot be matched safely; only the unambiguous phrases
          # stay, and a genuinely transient limit that says none of them costs one silent turn,
          # which the harness resumes anyway.
        *)
          if [ "${ZUVO_REWAKE_RL_TRANSIENT:-0}" != "1" ]; then
            printf '%s\tlimit-no-evidence-no-rewake\t%s\n' "$(date -u +%FT%TZ)" "$sid" >> "$log" 2>/dev/null || true
            _sweep; exit 0
          fi ;;
      esac
      printf '%s' "$((n + 1))" > "$cf" 2>/dev/null || true
      printf '%s' "$((t + 1))" > "$tf" 2>/dev/null || true
      sleep "${ZUVO_REWAKE_BACKOFF_RL:-90}"
      printf 'zuvo-watchdog: the previous turn was killed by a transient rate limit and the backoff has elapsed. The conversation context is intact — RESUME the work you were doing, right where it stopped. Do not ask the user; just continue. (auto-resume %s/%s this session)\n' \
        "$((t + 1))" "$TOTAL_CAP" >&2
      _sweep; exit 2
    fi

    # At most ONE wake per reset window, however many failures land in it.
    wf="$cdir/$sid.window"
    [ "$(cat "$wf" 2>/dev/null)" = "$reset" ] && { _sweep; exit 0; }
    printf '%s' "$reset" > "$wf" 2>/dev/null || true

    printf '%s' "$((n + 1))" > "$cf" 2>/dev/null || true
    printf '%s' "$((t + 1))" > "$tf" 2>/dev/null || true

    # One minute past the reset, capped at 8h so a bogus epoch cannot park a
    # background process forever.
    wait=$(( reset + 60 - now ))
    [ "$wait" -lt 60 ] && wait=60
    [ "$wait" -gt 28800 ] && wait=28800
    sleep "$wait"

    printf 'zuvo-watchdog: the usage limit that killed the previous turn has reset (waited until %s). The conversation context is intact — RESUME the work you were doing, right where it stopped. Do not ask the user; just continue. (auto-resume %s/%s this session)\n' \
      "$(date -r "$((reset + 60))" '+%H:%M' 2>/dev/null || echo 'reset+1m')" "$((t + 1))" "$TOTAL_CAP" >&2
    _sweep; exit 2
    ;;
esac

# ---- transient errors: short backoff, then resume ---------------------------
printf '%s' "$((n + 1))" > "$cf" 2>/dev/null || true
printf '%s' "$((t + 1))" > "$tf" 2>/dev/null || true

case "$etype" in
  server_error|overloaded) sleep "${ZUVO_REWAKE_BACKOFF_SE:-20}" ;;
  *)                       sleep "${ZUVO_REWAKE_BACKOFF_OTHER:-30}" ;;
esac

printf 'zuvo-watchdog: the previous turn was killed by an API error (%s) and the backoff has elapsed. The conversation context is intact — RESUME the work you were doing, right where it stopped. Do not ask the user; just continue. (auto-resume %s/%s this session)\n' \
  "$etype" "$((t + 1))" "$TOTAL_CAP" >&2
_sweep
exit 2
