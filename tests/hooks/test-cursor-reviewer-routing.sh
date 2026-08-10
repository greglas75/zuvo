#!/usr/bin/env bash
# Cursor was the one host that gave up on cross-model review without looking.
#
# reviewer-model-route.sh hardcoded `routing_status=same-model-fallback` in its
# `cursor)` branch — unconditionally, with no check for an available reviewer —
# while `antigravity)` five lines below routes to a different model and reports
# `ok`. reviewer-preflight.sh turns any non-ok routing_status into
# `degraded-routing`, which per shared/includes/test-reviewer-routing.md caps the
# blind audit at `clean:degraded`. That include measured the cost: a same-model
# audit returned CLEAN where `agy` found 8 uncovered defensive paths on the same
# pair (absent collections, non-list inputs, a zero-division guard, a
# size-dependent branch).
#
# So every zuvo:write-tests run on Cursor took a measurably weaker blind audit,
# permanently, even with a working cross-model client installed — and nothing
# asserted it: scripts/tests/reviewer-model-route.bats has no cursor case at all.
# Reported by a user on 2026-08-10 ("Preflight: degraded-routing (agy dostępny)").
#
# The second bug this pins: the `case "$writer_model"` arms matched the literal
# strings `fast`/`inherit` (what Cursor's model PICKER shows), but
# CURSOR_AGENT_MODEL reports the RESOLVED name (`composer-2.5-fast`), so real runs
# fell through to writer_lane=unknown.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ROUTE="$ROOT/scripts/reviewer-model-route.sh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

[ -f "$ROUTE" ] || { bad "reviewer-model-route.sh missing"; echo "SOME FAILED"; exit 1; }

# Force the cursor branch: unset CLAUDECODE (its arm is checked first) and give
# the markers the resolver looks for.
route_as_cursor() {
  env -u CLAUDECODE -u CODEX_SANDBOX -u ANTIGRAVITY_SESSION_ID \
      VSCODE_GIT_ASKPASS_MAIN="/Applications/Cursor.app/probe" \
      CURSOR_AGENT_MODEL="$1" \
      bash "$ROUTE" 2>/dev/null
}
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

out="$(route_as_cursor composer-2.5-fast)"
[ "$(field "$out" platform)" = "cursor" ] \
  && pass "cursor host is detected" \
  || { bad "cursor not detected (platform=$(field "$out" platform)) — rest is meaningless"; echo "SOME FAILED"; exit 1; }

# 1. A cross-model reviewer must be NAMED when one is installed.
if command -v agy >/dev/null 2>&1 || command -v codex >/dev/null 2>&1 || command -v claude >/dev/null 2>&1; then
  rs="$(field "$out" routing_status)"; rm_="$(field "$out" reviewer_model)"
  if [ "$rs" = "same-model-fallback" ]; then
    bad "cursor hardcoded same-model-fallback with a cross-model client on PATH — the original bug"
  elif [ "$rm_" = "composer-2.5-fast" ]; then
    bad "reviewer_model equals the writer ($rm_) — that is same-model wearing an ok status"
  elif [ "$rs" = "ok" ] && [ -n "$rm_" ]; then
    pass "cursor routes cross-model when a client exists (reviewer=$rm_, status=ok)"
  else
    bad "unexpected routing: status=$rs reviewer=$rm_"
  fi
else
  pass "no cross-model client installed — same-model fallback is correct here (skipped)"
fi

# 2. The degrade must still happen when NOTHING is available. Empty PATH removes
#    every client; the resolver must fall back rather than name a phantom reviewer.
out_none="$(env -u CLAUDECODE -u CODEX_SANDBOX -u ANTIGRAVITY_SESSION_ID \
   VSCODE_GIT_ASKPASS_MAIN="/Applications/Cursor.app/probe" CURSOR_AGENT_MODEL=composer-2.5-fast \
   PATH="/nonexistent" /bin/bash "$ROUTE" 2>/dev/null)"
if [ -z "$out_none" ]; then
  pass "empty-PATH probe unusable in this environment (resolver needs coreutils) — skipped"
elif [ "$(field "$out_none" routing_status)" = "same-model-fallback" ]; then
  pass "with no client on PATH it degrades honestly instead of naming a phantom reviewer"
else
  bad "no client available yet routing_status=$(field "$out_none" routing_status) — claims a reviewer that is not there"
fi

# 3. writer_lane must resolve for the names a real run actually reports.
for m in composer-2.5-fast fast; do
  l="$(field "$(route_as_cursor "$m")" writer_lane)"
  [ "$l" = "small" ] && pass "writer_lane=small for '$m'" || bad "writer_lane='$l' for '$m' (want small)"
done
for m in composer-2.5 inherit; do
  l="$(field "$(route_as_cursor "$m")" writer_lane)"
  [ "$l" = "strong_primary" ] && pass "writer_lane=strong_primary for '$m'" || bad "writer_lane='$l' for '$m' (want strong_primary)"
done

# 4. Regression guard on the source itself: the unconditional assignment must not
#    come back. A future edit that re-hardcodes it would otherwise pass every
#    behavioural check above on a machine with no clients installed.
if awk '/^  cursor\)/,/^    ;;/' "$ROUTE" | grep -q 'command -v'; then
  pass "cursor branch probes for an available client (not a hardcoded verdict)"
else
  bad "cursor branch no longer probes for a client — the hardcoded degrade is back"
fi

echo "=== RESULT ==="
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
