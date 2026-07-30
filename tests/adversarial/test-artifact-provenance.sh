#!/usr/bin/env bash
# test-artifact-provenance.sh — the artifact must say WHO reviewed, who didn't, and why.
#
# The failure this locks: a downstream gate reads only the artifact. Before v1.6.47 a run where
# three of four providers died silently produced the same `provider_count=1` as a deliberate
# --single, so a collapsed review passed a gate that a real single-provider run was meant to pass.
# Also covers --append-artifact (rotation passes must not overwrite each other) and the run-scoped
# auth-failure cache (a dead subscription must not cost a full timeout on every rotation pass).
# Sourced by run.sh.

ADV="$ROOT/scripts/adversarial-review.sh"
MOCKS="$HERE/mocks"
EMPTY="$ADV_TEST_EMPTY"
TD="$HERE/.tmp/prov"
rm -rf "$TD"; mkdir -p "$TD"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$MOCKS:$PATH"
# Isolate the failure cache per case so cases cannot leak into one another.
export TMPDIR="$TD"

hdr() { sed -n '1,/^---$/p' "$1"; }

# ─── Case 1: all succeed → per-provider outcomes, no single_provider_note ──

start_test "PROV.1 two successes → provider_outcomes lists both, no single_provider_note"
ZUVO_RUN_ID=prov1 ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-success" \
  bash "$ADV" --multi --files "$EMPTY" --artifact "$TD/a1.md" >/dev/null 2>&1 || true
h=$(hdr "$TD/a1.md")
assert_contains "$h" "provider_outcomes=" "provider_outcomes present"
assert_contains "$h" "providers_attempted=2" "providers_attempted recorded"
if printf '%s' "$h" | grep -q '^single_provider_note='; then
  fail "single_provider_note must be absent when 2 providers reviewed"
else
  pass "no single_provider_note on a real multi-provider run"
fi
assert_contains "$h" "count_method=keyword-lines" "counts are labelled as a heuristic, not parsed findings"

# ─── Case 2: a collapsed multi-run is distinguishable from a deliberate single ──

start_test "PROV.2 1 of 2 providers dies → single_provider_note explains the collapse"
ZUVO_RUN_ID=prov2 ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
  bash "$ADV" --multi --files "$EMPTY" --artifact "$TD/a2.md" >/dev/null 2>&1 || true
h=$(hdr "$TD/a2.md")
assert_contains "$h" "single_provider_note=" "collapse is annotated"
assert_contains "$h" "produced no review" "note names the collapse, not a design choice"
assert_contains "$h" "mock-fail:" "failing provider appears in provider_outcomes"

start_test "PROV.3 deliberate --single → note says by design, not a failure"
ZUVO_RUN_ID=prov3 ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-success" \
  bash "$ADV" --single --files "$EMPTY" --artifact "$TD/a3.md" >/dev/null 2>&1 || true
h=$(hdr "$TD/a3.md")
assert_contains "$h" "by design" "deliberate single run is labelled as such"

# ─── Case 3: --append-artifact keeps the earlier pass ──────────────────────

start_test "PROV.4 --append-artifact preserves pass 1"
ZUVO_RUN_ID=prov4 ZUVO_REVIEW_TEST_PROVIDERS="mock-success" \
  bash "$ADV" --files "$EMPTY" --artifact "$TD/a4.md" >/dev/null 2>&1 || true
first_created=$(grep -m1 '^created_at=' "$TD/a4.md")
ZUVO_RUN_ID=prov4 ZUVO_REVIEW_TEST_PROVIDERS="mock-success" \
  bash "$ADV" --files "$EMPTY" --artifact "$TD/a4.md" --append-artifact >/dev/null 2>&1 || true
assert_contains "$(cat "$TD/a4.md")" "=== APPENDED PASS" "append marker written"
assert_contains "$(cat "$TD/a4.md")" "$first_created" "pass 1 header survived the append"
n=$(grep -c '^artifact_kind=adversarial-review' "$TD/a4.md")
assert_eq "2" "$n" "both passes present in the appended artifact"

start_test "PROV.5 without --append-artifact the file is still overwritten (no silent growth)"
ZUVO_RUN_ID=prov5 ZUVO_REVIEW_TEST_PROVIDERS="mock-success" \
  bash "$ADV" --files "$EMPTY" --artifact "$TD/a5.md" >/dev/null 2>&1 || true
ZUVO_RUN_ID=prov5 ZUVO_REVIEW_TEST_PROVIDERS="mock-success" \
  bash "$ADV" --files "$EMPTY" --artifact "$TD/a5.md" >/dev/null 2>&1 || true
n=$(grep -c '^artifact_kind=adversarial-review' "$TD/a5.md")
assert_eq "1" "$n" "default stays overwrite"

# ─── Case 4: --known-finding reaches the prompt and is budget-exempt ───────

start_test "PROV.6 --known-finding is injected into the review prompt"
out=$(printf 'x' | bash "$ADV" --dry-run --known-finding "svc.ts:42:missing-tenant-scope" 2>&1)
assert_contains "$out" "ALREADY-DISPOSITIONED FINDINGS" "known-finding block present"
assert_contains "$out" "svc.ts:42:missing-tenant-scope" "the fingerprint itself is passed through"
assert_contains "$out" "do not count toward your finding limit" "repeats are budget-exempt"

start_test "PROV.7 no --known-finding → no stray block in the prompt"
out=$(printf 'x' | bash "$ADV" --dry-run 2>&1)
if printf '%s' "$out" | grep -q "ALREADY-DISPOSITIONED"; then
  fail "known-finding block leaked into a run that supplied none"
else
  pass "prompt is unchanged when no fingerprints are supplied"
fi

# ─── Case 5: the auth-failure cache must never filter the run down to zero ──

start_test "PROV.8 stale all-failed cache is ignored rather than emptying the provider list"
cache_key="staleprov"
# Pre-seed the cache with every provider the run would use.
seed="$TD/zuvo-adv-failed-providers.${cache_key}"
printf 'mock-success\n' > "$seed"
out=$(ZUVO_RUN_ID="$cache_key" ZUVO_REVIEW_TEST_PROVIDERS="mock-success" \
  bash "$ADV" --files "$EMPTY" --artifact "$TD/a8.md" 2>&1) || true
assert_contains "$out" "ignoring it and retrying all" "fail-open: a fully-stale cache is discarded"
assert_contains "$(hdr "$TD/a8.md")" "provider_count=1" "the review still ran"
