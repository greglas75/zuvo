#!/usr/bin/env bash
# Cursor was the one host that gave up on cross-model review without looking.
#
# reviewer-model-route.sh hardcoded `routing_status=same-model-fallback` in its
# `cursor)` branch — unconditionally, with no check for an available reviewer —
# while `antigravity)` five lines below routes to a different model and reports
# `ok`. reviewer-preflight.sh turns any non-ok routing_status into
# `degraded-routing`, which gates Step 4's fallback-local degrade to same-model
# (shared/includes/test-reviewer-routing.md) — Step 3.5 blind-audit strictness is
# unaffected, since it comes from the panel's own `Audit panel:` line, never
# from routing_status.
#
# So every zuvo:write-tests Step-4 review on Cursor took a measurably weaker,
# same-model hit, permanently, even with a working cross-model client installed
# — and nothing asserted it: scripts/tests/reviewer-model-route.bats has no
# cursor case at all.
# Reported by a user on 2026-08-10 ("Preflight: degraded-routing (agy dostępny)").
#
# The second bug this pins: the `case "$writer_model"` arms matched the literal
# strings `fast`/`inherit` (what Cursor's model PICKER shows), but
# CURSOR_AGENT_MODEL reports the RESOLVED name (`composer-2.5-fast`), so real runs
# fell through to writer_lane=unknown.
#
# HERMETIC (2026-09-26): every router run is `env -i` with an explicit PATH. Case 1 used to branch
# on which CLIs the HOST had installed and reported "skipped" as a PASS where none was — exactly the
# machine on which a regression back to the hardcoded fallback would go unseen. It now puts STUB
# agy / codex / claude (or none) on a controlled PATH, so every branch runs on every machine; the
# stubs leave a marker if executed, and the router must only LOOK (command -v), never run them. Case
# 2 asserts the router's exit status and its full answer under PATH=/nonexistent instead of passing
# on empty output, and an unrecognised writer model pins the writer_lane fallthrough. Ambient
# CLAUDE_MODEL / ZUVO_*_MODEL / host markers cannot reach the router.
# ZUVO_TEST_ROUTE points every case at ANOTHER router copy (a deliberately broken one, to show the
# cases are red there); the copy needs its lib/model-subprocess.sh beside it.
#
# Run (both shells — the router runs under the same bash as this file, except case 2's /bin/bash):
#   TF_ALLOW_LOCAL=1 bash tests/hooks/test-cursor-reviewer-routing.sh
#   TF_ALLOW_LOCAL=1 /bin/bash tests/hooks/test-cursor-reviewer-routing.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ROUTE="${ZUVO_TEST_ROUTE:-$ROOT/scripts/reviewer-model-route.sh}"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

[ -f "$ROUTE" ] || { bad "reviewer-model-route.sh missing"; echo "SOME FAILED"; exit 1; }

T="$(mktemp -d)" || { bad "mktemp -d failed"; echo "SOME FAILED"; exit 1; }
[ -n "$T" ] && [ -d "$T" ] || { bad "mktemp -d returned an empty path or no directory"; echo "SOME FAILED"; exit 1; }
trap 'rm -rf "$T"' EXIT
RBASH="$BASH"
mkdir -p "$T/home"

# Controlled PATHs: stub clients (or none). A stub that is EXECUTED leaves $T/executed.<name>.
mkstub() { # mkstub <dir> <name>
  mkdir -p "$1"
  printf '#!/bin/sh\n: > "%s/executed.%s"\necho "stub %s"\n' "$T" "$2" "$2" > "$1/$2"
  chmod +x "$1/$2"
}
P_NONE="$T/path-none"; mkdir -p "$P_NONE"
P_AGY="$T/path-agy";       mkstub "$P_AGY" agy
P_CODEX="$T/path-codex";   mkstub "$P_CODEX" codex
P_CLAUDE="$T/path-claude"; mkstub "$P_CLAUDE" claude
P_ALL="$T/path-all";       mkstub "$P_ALL" agy; mkstub "$P_ALL" codex; mkstub "$P_ALL" claude
P_CC="$T/path-codex-claude"; mkstub "$P_CC" codex; mkstub "$P_CC" claude

# route_on <PATH> <CURSOR_AGENT_MODEL> — the router as a Cursor host, `env -i`: nothing ambient
# (CLAUDECODE, CLAUDE_MODEL, the four Codex host signals, ZUVO_CODEX_MODEL, GEMINI_MODEL, Kimi's
# PATH entry...) can reach it. stdout = the router's answer; its stderr goes to $T/route.err.
route_on() {
  env -i HOME="$T/home" PATH="$1" VSCODE_GIT_ASKPASS_MAIN="/Applications/Cursor.app/probe" \
      CURSOR_AGENT_MODEL="$2" "$RBASH" "$ROUTE" 2>"$T/route.err"
}
# route_as_cursor <model> — the cursor branch with NO client on PATH (writer_lane cases).
route_as_cursor() { route_on "$P_NONE" "$1"; }
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

out="$(route_as_cursor composer-2.5-fast)"
[ "$(field "$out" platform)" = "cursor" ] \
  && pass "cursor host is detected" \
  || { bad "cursor not detected (platform=$(field "$out" platform)) — rest is meaningless"; echo "SOME FAILED"; exit 1; }

# 1. A cross-model reviewer must be NAMED when one is installed — deterministically: each client
#    alone, and the preference order agy > codex > claude when several are present.
# expect_reviewer <label> <PATH> <want reviewer_model>
expect_reviewer() {
  local o rs rm_ rl
  rm -f "$T"/executed.*
  o="$(route_on "$2" composer-2.5-fast)"
  rs="$(field "$o" routing_status)"; rm_="$(field "$o" reviewer_model)"; rl="$(field "$o" reviewer_lane)"
  if [ "$rs" = "same-model-fallback" ]; then
    bad "$1: cursor fell back to same-model with $3 on PATH — the original bug"
  elif [ "$rm_" = "composer-2.5-fast" ]; then
    bad "$1: reviewer_model equals the writer ($rm_) — that is same-model wearing an ok status"
  elif [ "$rs" = "ok" ] && [ "$rm_" = "$3" ] && [ "$rl" = "review-alt" ]; then
    pass "$1: cursor routes cross-model (reviewer=$rm_, lane=$rl, status=ok)"
  else
    bad "$1: unexpected routing: status=$rs lane=$rl reviewer=$rm_ (want ok / review-alt / $3)"
  fi
  if ls "$T"/executed.* >/dev/null 2>&1; then
    bad "$1: the router EXECUTED a client ($(cd "$T" && ls executed.* | tr '\n' ' ')) — it must only look it up"
  else
    pass "$1: no client was executed (command -v lookup only)"
  fi
}
expect_reviewer "only agy on PATH" "$P_AGY" agy
expect_reviewer "only codex on PATH" "$P_CODEX" codex
expect_reviewer "only claude on PATH" "$P_CLAUDE" claude
expect_reviewer "agy, codex and claude on PATH (agy first)" "$P_ALL" agy
expect_reviewer "codex and claude on PATH (codex before claude)" "$P_CC" codex
_want_agy="platform=cursor
writer_model=composer-2.5-fast
writer_lane=small
reviewer_lane=review-alt
reviewer_model=agy
routing_status=ok"
[ "$(route_on "$P_AGY" composer-2.5-fast)" = "$_want_agy" ] \
  && pass "only agy on PATH: the whole six-line answer is exact" \
  || bad "only agy on PATH: answer is [$(route_on "$P_AGY" composer-2.5-fast | tr '\n' ' ')], want [$(printf '%s' "$_want_agy" | tr '\n' ' ')]"

# 2. The degrade must still happen when NOTHING is available. Empty PATH removes
#    every client; the resolver must fall back rather than name a phantom reviewer —
#    and it must ANSWER: exit 0, six keys, nothing on stderr (a crash here is not "unusable").
route_as_cursor_no_path() {
  env -i HOME="$T/home" VSCODE_GIT_ASKPASS_MAIN="/Applications/Cursor.app/probe" CURSOR_AGENT_MODEL=composer-2.5-fast \
     PATH="/nonexistent" /bin/bash "$ROUTE" 2>"$T/route-nopath.err"
}
_want_none="platform=cursor
writer_model=composer-2.5-fast
writer_lane=small
reviewer_lane=same-model-fallback
reviewer_model=composer-2.5-fast
routing_status=same-model-fallback"
out_none="$(route_as_cursor_no_path)"; rc_none=$?
[ "$rc_none" = "0" ] && pass "PATH=/nonexistent: the router exits 0" \
                     || bad "PATH=/nonexistent: the router exited $rc_none (want 0) — stderr: $(tr '\n' ' ' < "$T/route-nopath.err")"
[ -s "$T/route-nopath.err" ] && bad "PATH=/nonexistent: the router wrote to stderr: $(tr '\n' ' ' < "$T/route-nopath.err")" \
                             || pass "PATH=/nonexistent: nothing on stderr"
if [ "$out_none" = "$_want_none" ]; then
  pass "with no client on PATH it degrades honestly instead of naming a phantom reviewer"
else
  bad "no client available: answer is [$(printf '%s' "$out_none" | tr '\n' ' ')], want [$(printf '%s' "$_want_none" | tr '\n' ' ')]"
fi
out_empty="$(route_on "$P_NONE" composer-2.5-fast)"; rc_empty=$?
[ "$rc_empty" = "0" ] && [ "$out_empty" = "$_want_none" ] \
  && pass "an existing but EMPTY PATH directory degrades the same way (exit 0)" \
  || bad "empty PATH directory: exit $rc_empty, answer [$(printf '%s' "$out_empty" | tr '\n' ' ')]"

# 3. writer_lane must resolve for the names a real run actually reports.
for m in composer-2.5-fast fast; do
  l="$(field "$(route_as_cursor "$m")" writer_lane)"
  [ "$l" = "small" ] && pass "writer_lane=small for '$m'" || bad "writer_lane='$l' for '$m' (want small)"
done
for m in composer-2.5 inherit; do
  l="$(field "$(route_as_cursor "$m")" writer_lane)"
  [ "$l" = "strong_primary" ] && pass "writer_lane=strong_primary for '$m'" || bad "writer_lane='$l' for '$m' (want strong_primary)"
done

# 3b. The fallthrough: a writer model neither glob matches (`gpt-5.5` — no fast / max / composer /
#     inherit) keeps writer_lane=unknown; the reviewer is still chosen by what is on PATH.
_want_unk_agy="platform=cursor
writer_model=gpt-5.5
writer_lane=unknown
reviewer_lane=review-alt
reviewer_model=agy
routing_status=ok"
_want_unk_none="platform=cursor
writer_model=gpt-5.5
writer_lane=unknown
reviewer_lane=same-model-fallback
reviewer_model=gpt-5.5
routing_status=same-model-fallback"
o="$(route_on "$P_AGY" gpt-5.5)"; rc=$?
[ "$rc" = "0" ] && [ "$o" = "$_want_unk_agy" ] \
  && pass "unrecognised writer 'gpt-5.5' with agy on PATH: writer_lane=unknown, agy reviews (exact answer)" \
  || bad "unrecognised writer 'gpt-5.5' with agy on PATH: exit $rc, answer [$(printf '%s' "$o" | tr '\n' ' ')]"
o="$(route_on "$P_NONE" gpt-5.5)"; rc=$?
[ "$rc" = "0" ] && [ "$o" = "$_want_unk_none" ] \
  && pass "unrecognised writer 'gpt-5.5' with no client: writer_lane=unknown, same-model fallback (exact answer)" \
  || bad "unrecognised writer 'gpt-5.5' with no client: exit $rc, answer [$(printf '%s' "$o" | tr '\n' ' ')]"

# 4. Regression guard on the source itself: the unconditional assignment must not
#    come back. A future edit that re-hardcodes it would otherwise pass every
#    behavioural check above on a machine with no clients installed.
if awk '/^  cursor\)/,/^    ;;/' "$ROUTE" | grep -q 'command -v'; then
  pass "cursor branch probes for an available client (not a hardcoded verdict)"
else
  bad "cursor branch no longer probes for a client — the hardcoded degrade is back"
fi

# 5. The helpers above must be immune to an AMBIENT Codex host: this file run from inside Codex
#    Desktop, which exports these three signals (and not CODEX_SANDBOX). Without isolation the
#    router answers platform=codex and every row above tests the wrong branch.
(
  export CODEX_SHELL=1 CODEX_INTERNAL_ORIGINATOR_OVERRIDE="Codex Desktop" __CFBundleIdentifier=com.openai.codex
  export CLAUDECODE=1 CLAUDE_MODEL=claude-opus-5-5 ZUVO_CODEX_MODEL=gpt-5.5
  o="$(route_as_cursor composer-2.5-fast)"
  if [ "$(field "$o" platform)" = "cursor" ] && [ "$(field "$o" writer_lane)" = "small" ]; then
    pass "ambient Codex Desktop / Claude signals do not change the cursor row"
  else
    bad "ambient Codex Desktop / Claude signals changed the cursor row: platform=$(field "$o" platform) writer_lane=$(field "$o" writer_lane)"
  fi
  o="$(route_as_cursor_no_path)"
  if [ "$o" = "$_want_none" ]; then
    pass "ambient Codex Desktop / Claude signals do not change the no-client row"
  else
    bad "ambient Codex Desktop / Claude signals changed the no-client row: platform=$(field "$o" platform) routing_status=$(field "$o" routing_status)"
  fi
  [ "$fail" -eq 0 ]
) || fail=1

echo "=== RESULT ==="
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
