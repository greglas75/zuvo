#!/usr/bin/env bash
# test-backward-compat.sh — Task 13 (AC9): backward compat + hook smoke.

ADV="$ROOT/scripts/adversarial-review.sh"
MOCKS="$HERE/mocks"
EMPTY="$ADV_TEST_EMPTY"
export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$MOCKS:$PATH"

# ─── Case 1: Old `jq -r '.status' | grep -q '^ok$'` does NOT match "partial" ─

start_test "BC.1 old-style ok-grep does NOT match new partial status"
partial_out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null)
# Old caller pattern: jq -r '.status' returns bareword "partial" (not "ok"). The
# `grep -q '^ok$'` regex anchored at line boundaries must NOT match.
if echo "$partial_out" | jq -r '.status' 2>/dev/null | grep -q '^ok$'; then
  fail "BC.1" "old caller's grep ^ok$ incorrectly matched partial — fail-CLOSED contract violated"
else
  pass "old ^ok$ regex correctly fails-closed on partial"
fi

# ─── Case 2: pre-commit-adversarial-gate hook accepts new artifact ─────────

start_test "BC.2 pre-commit-adversarial-gate accepts artifact from updated script"
ART="$ADV_TEST_HOME/bc-art.txt"
rm -f "$ART"
ZUVO_REVIEW_TEST_PROVIDERS="mock-success" \
  bash "$ADV" --json --artifact "$ART" --files "$EMPTY" >/dev/null 2>&1
if [[ -f "$ART" && -s "$ART" ]]; then
  pass "artifact written and non-empty"
else
  fail "BC.2" "artifact missing or empty"
fi
# The pre-commit hook checks artifact_kind header — verify it's there
if grep -q '^artifact_kind=adversarial-review' "$ART" 2>/dev/null; then
  pass "artifact has artifact_kind header (hook contract preserved)"
else
  fail "BC.2" "artifact missing artifact_kind=adversarial-review header"
fi

# ─── Case 3: JSON valid in all 4 status modes ──────────────────────────────

start_test "BC.4 providers_used_list is a JSON array, [0] indexes correctly (R-1 fix)"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null)
list_type=$(echo "$out" | jq -r '.providers_used_list | type' 2>/dev/null)
first=$(echo "$out" | jq -r '.providers_used_list[0]' 2>/dev/null)
str_type=$(echo "$out" | jq -r '.providers_used | type' 2>/dev/null)
assert_eq "array"        "$list_type"  "providers_used_list type is array"
assert_eq "mock-success" "$first"      "providers_used_list[0] indexes correctly"
assert_eq "string"       "$str_type"   "providers_used remains string (back-compat)"

start_test "BC.5 grep -Fx exclusion handles dotted provider names (R-2 fix)"
# Simulate a dotted provider name. mock-success-5.4 doesn't exist but the
# regex-correctness applies to detect_providers list. Easier test: --exclude
# with a value containing `.` should match literally, not as wildcard.
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
  bash "$ADV" --multi --exclude "mock.fail" --json --files "$EMPTY" 2>/dev/null)
# Without -F, `mock.fail` (regex) would match `mock-fail` (any single char between).
# With -Fx, `mock.fail` (literal) does not match `mock-fail` — so mock-fail remains in PROVIDERS.
# Test passes if mock-fail wasn't accidentally excluded by regex over-match
# (i.e., we see both providers were attempted).
attempted=$(echo "$out" | jq -r '.attempted_count' 2>/dev/null)
assert_eq "2" "$attempted" "literal exclusion does not over-match dotted names"

start_test "BC.3 JSON output is valid jq-parseable in all status modes"
# ok
ZUVO_REVIEW_TEST_PROVIDERS="mock-success" bash "$ADV" --json --files "$EMPTY" 2>/dev/null | jq . >/dev/null 2>&1 \
  && pass "ok status JSON valid" || fail "BC.3" "ok JSON invalid"
# partial
ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null | jq . >/dev/null 2>&1 \
  && pass "partial status JSON valid" || fail "BC.3" "partial JSON invalid"
# timeout
ZUVO_REVIEW_TEST_PROVIDERS="mock-timeout" ZUVO_REVIEW_TIMEOUT=2 bash "$ADV" --json --files "$EMPTY" 2>/dev/null | jq . >/dev/null 2>&1 \
  && pass "timeout status JSON valid" || fail "BC.3" "timeout JSON invalid"
# single_provider_only
ZUVO_REVIEW_TEST_PROVIDERS="mock-success" bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null | jq . >/dev/null 2>&1 \
  && pass "single_provider_only status JSON valid" || fail "BC.3" "single_provider_only JSON invalid"

# ─── Case 4: dead `gemini`/`gemini-api` lanes stay removed from --help ──────
# 2026-08-04: Google killed the free `gemini` CLI for individuals and no host in this
# fleet ever set GEMINI_API_KEY, so both lanes were dead weight — removed in favor of
# `agy` (Antigravity CLI), the sanctioned paid Gemini channel. This guards the two ways
# that regression could silently creep back: the --provider Auto: list drifting off the
# five real auto-detected providers, or a `gemini`/`gemini-api` token reappearing as a
# selectable provider (the Auto/Manual lines) instead of the historical/explanatory
# prose that legitimately still says "Gemini" when describing what agy replaced.

start_test "BC.6 --help Auto: list is exactly the 5 sanctioned providers, no gemini lane"
help_out=$(bash "$ADV" --help 2>&1)
auto_line=$(printf '%s\n' "$help_out" | grep -E 'Auto:')
manual_line=$(printf '%s\n' "$help_out" | grep -E 'Manual:')
auto_list=$(printf '%s\n' "$auto_line" | sed -E 's/^.*Auto:[[:space:]]*//')
manual_list=$(printf '%s\n' "$manual_line" | sed -E 's/^.*Manual:[[:space:]]*//')
assert_eq "codex-5.3, agy, cursor-agent, kimi, claude" "$auto_list" \
  "Auto: list is exactly codex-5.3, agy, cursor-agent, kimi, claude"
if printf '%s' "$auto_list $manual_list" | grep -qiE '(^|[^-a-z])gemini([^-a-z]|$)'; then
  fail "BC.6" "gemini still selectable in Auto:/Manual: provider list — <$auto_list> / <$manual_list>"
else
  pass "gemini is not a selectable provider in the Auto:/Manual: lists"
fi

# RED proof (run manually, not part of the suite): a scratch copy with a `gemini` arm
# reintroduced into the Auto: line makes the exact-match assertion above fail —
#   sed 's/Auto: codex-5.3, agy,/Auto: codex-5.3, gemini, agy,/' scripts/adversarial-review.sh \
#     > /tmp/adv-regression-scratch.sh
#   ADV=/tmp/adv-regression-scratch.sh bash -c '...same BC.6 body...'
# reports: expected=<codex-5.3, agy, cursor-agent, kimi, claude> actual=<codex-5.3, gemini, agy, cursor-agent, kimi, claude>
# — i.e. FAIL, proving the assertion discriminates a reintroduced gemini lane.

# ─── Case 5: the harness must run OUTSIDE a git work tree ─────────────────────
# 2026-08-04. `_ar_cache_key` was built from `git rev-parse --show-toplevel |
# tr / _`. Outside a work tree git exits 128, `set -o pipefail` propagates it and
# `set -e` kills the script at ~line 121 — before ANY output. The `2>/dev/null`
# on that call hid git's own error, so the symptom was rc=128 with empty stdout
# AND empty stderr: no message, no partial run, nothing to grep for.
# Reproduced identically on macOS and burst-i9, and it is why burst-i9's
# adversarial.log read `provider=none / all-failed` — the run never reached
# provider detection, so "the CI box has no providers" was a misdiagnosis.
# Asserted from a directory that is definitely NOT a repo, because every other
# case in this suite runs from inside one and therefore cannot catch it.
start_test "BC.7 runs from a non-git CWD (no silent rc=128)"
_ng="$(mktemp -d)"          # mktemp -d is never inside a work tree
# stderr goes to a file INSIDE that mktemp dir, not a predictable /tmp/bc7.err.
# A fixed name under a world-writable /tmp lets another user on a shared host
# pre-create it as a symlink, and the truncating `2>` then clobbers whatever it
# points at (CWE-59). adversarial-review.sh guards its own cache dir against
# exactly this; a test that reintroduces the hole is not a test worth having.
_ng_err="$_ng/stderr.txt"
_ng_out="$(cd "$_ng" && bash "$ADV" --help 2>"$_ng_err")"; _ng_rc=$?
_ng_err_bytes=$(wc -c < "$_ng_err" | tr -d ' ')
if [ "$_ng_rc" -eq 0 ] && [ -n "$_ng_out" ]; then
  pass "non-git CWD: exit 0 with real output ($(printf '%s' "$_ng_out" | wc -c | tr -d ' ') bytes)"
else
  fail "BC.7" "non-git CWD died: rc=$_ng_rc stdout_bytes=$(printf '%s' "$_ng_out" | wc -c | tr -d ' ') stderr_bytes=$_ng_err_bytes"
fi
# And the failure mode specifically: a silent death is worse than a loud one.
if [ "$_ng_rc" -ne 0 ] && [ "$_ng_err_bytes" -eq 0 ]; then
  fail "BC.7" "failed SILENTLY (rc=$_ng_rc, empty stderr) — the exact shape that hid this for a year"
else
  pass "no silent-failure shape (rc/stderr consistent)"
fi
rm -rf "$_ng"
