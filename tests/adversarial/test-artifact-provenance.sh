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
assert_contains "$out" "count toward your finding limit" "repeats are budget-exempt"

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
# Pre-seed the cache with every provider the run would use. The path is $TMPDIR/zuvo-adv-<uid>/
# since the symlink hardening (PROV.16) — the cache lives in a dir this user owns, not directly
# in a shared TMPDIR.
seed_dir="$TD/zuvo-adv-$(id -u)"; mkdir -p "$seed_dir"
seed="$seed_dir/failed-providers.${cache_key}"
printf 'mock-success\n' > "$seed"
out=$(ZUVO_RUN_ID="$cache_key" ZUVO_REVIEW_TEST_PROVIDERS="mock-success" \
  bash "$ADV" --files "$EMPTY" --artifact "$TD/a8.md" 2>&1) || true
assert_contains "$out" "ignoring it and retrying all" "fail-open: a fully-stale cache is discarded"
assert_contains "$(hdr "$TD/a8.md")" "provider_count=1" "the review still ran"

# ─── Case 6: truncation must cut on a FILE boundary, not mid-file ──────────

# Since 2026-08-01 the DEFAULT for oversized multi-file input is auto-chunking
# (see test-input-chunking.sh) — the legacy whole-file-drop truncation tested
# here remains reachable via --no-chunk / ZUVO_ADV_NO_CHUNK=1 and inside chunk
# children, so its contract still needs this coverage.
start_test "PROV.9 oversized multi-file input (--no-chunk) drops the trailing file WHOLE and names it"
BIG="$TD/big.diff"
python3 - "$BIG" <<'PYEOF'
import sys
def f(n,c): return f"diff --git a/{n} b/{n}\n" + "".join(f"+line {i} of {n}\n" for i in range(c))
open(sys.argv[1],'w').write(f('one.ts',700)+f('two.ts',700)+f('three.ts',700))
PYEOF
out=$(bash "$ADV" --dry-run --no-chunk < "$BIG" 2>"$TD/trunc.err")
sent=$(printf '%s' "$out" | grep -c '^diff --git' || true)
assert_eq "2" "$sent" "only whole files are sent (the partial third is dropped)"
assert_contains "$out" "Files NOT included: three.ts" "the dropped file is named in the prompt manifest"
assert_contains "$(cat "$TD/trunc.err")" "whole-file boundary" "the trim is reported on stderr"
# The regression: before v1.6.47 the cut landed inside three.ts, so its header stayed in the kept
# portion, the omitted manifest came out EMPTY, and the reviewer silently judged half a file.
if printf '%s' "$out" | grep -q 'line 699 of two.ts'; then
  pass "the last kept file is complete"
else
  fail "PROV.9" "the last kept file was itself truncated"
fi

start_test "PROV.10 a single oversized file still gets reviewed (no boundary to fall back to)"
python3 - "$TD/one.diff" <<'PYEOF'
import sys
open(sys.argv[1],'w').write("diff --git a/solo.ts b/solo.ts\n" + "".join(f"+line {i}\n" for i in range(3000)))
PYEOF
out=$(bash "$ADV" --dry-run < "$TD/one.diff" 2>/dev/null)
assert_contains "$out" "diff --git a/solo.ts" "half of one file beats none"
assert_contains "$out" "TRUNCATED" "and it is labelled as truncated"

start_test "PROV.11 prompt tells the reviewer that create/update variants differ by design"
out=$(printf 'x' | bash "$ADV" --dry-run 2>/dev/null)
assert_contains "$out" "DELIBERATE contract" "type-variant rule present in the code prompt"

# ─── Case 7: proof-of-work markers in EVERY dispatch mode and format ───────
# The gate (pipeline-gate-lib :: pg_artifact_proven) counts `REVIEW BY:` lines. They used to come
# only from the MULTI path's body banner, so a genuine --single / --rotate / --json review produced
# an artifact with ZERO markers and had its coverage refused. 19 retro hits.

start_test "PROV.12 single-provider artifact carries exactly one REVIEW BY marker"
ZUVO_RUN_ID=mk1 ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-success" \
  bash "$ADV" --single --files "$EMPTY" --artifact "$TD/m1.md" >/dev/null 2>&1 || true
n=$(grep -c 'REVIEW BY:' "$TD/m1.md" || true)
assert_eq "1" "$n" "one marker for one provider"
assert_contains "$(cat "$TD/m1.md")" "single_provider_note=" "…plus the single-provider note the gate accepts"

start_test "PROV.13 multi-provider artifact carries exactly one marker PER provider"
ZUVO_RUN_ID=mk2 ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-success" \
  bash "$ADV" --multi --files "$EMPTY" --artifact "$TD/m2.md" >/dev/null 2>&1 || true
n=$(grep -c 'REVIEW BY:' "$TD/m2.md" || true)
assert_eq "2" "$n" "two providers -> exactly two markers (not doubled by the body banner)"

start_test "PROV.14 JSON output still carries markers and a parseable body"
ZUVO_RUN_ID=mk3 ZUVO_REVIEW_TEST_PROVIDERS="mock-success" \
  bash "$ADV" --json --files "$EMPTY" --artifact "$TD/m3.md" >/dev/null 2>&1 || true
n=$(grep -c 'REVIEW BY:' "$TD/m3.md" || true)
assert_eq "1" "$n" "JSON mode is not exempt from proof-of-work"
body=$(sed -n '/^---$/,$p' "$TD/m3.md" | tail -n +2)
if printf '%s' "$body" | jq . >/dev/null 2>&1; then
  pass "JSON body survived marker injection (markers live in the header)"
else
  fail "PROV.14" "artifact body is no longer valid JSON"
fi

start_test "PROV.15 a failed provider contributes no marker"
ZUVO_RUN_ID=mk4 ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
  bash "$ADV" --multi --files "$EMPTY" --artifact "$TD/m4.md" >/dev/null 2>&1 || true
n=$(grep -c 'REVIEW BY:' "$TD/m4.md" || true)
assert_eq "1" "$n" "markers count reviews, not attempts"

# ─── Case 8: the run-scoped failure cache must not be symlink-hijackable ───
# Found by this change's own adversarial pass (agy + cursor-agent, CRITICAL, CWE-59) and
# REPRODUCED before fixing: the cache path was $TMPDIR/zuvo-adv-failed-providers.<key>, a
# predictable name. With TMPDIR on a world-writable /tmp — which is where zuvo runs on the shared
# VPS hosts — a neighbour pre-creates that path as a symlink and the `>>` append writes THROUGH it
# into the victim's file. Confirmed by appending a provider name into a planted victim.txt.

start_test "PROV.16 a symlink planted at the cache path cannot be written through"
SD="$TD/sym"; rm -rf "$SD"; mkdir -p "$SD/tmp"
printf 'ORIGINAL\n' > "$SD/victim.txt"
# Plant BOTH shapes: the per-uid dir the code creates, and the file inside it.
ln -s "$SD/victim.txt" "$SD/tmp/zuvo-adv-$(id -u)" 2>/dev/null
key=$(printf '%s' "$(git -C "$ROOT" rev-parse --show-toplevel | tr '/' '_')" | sed 's/[^A-Za-z0-9._-]/_/g')
ln -s "$SD/victim.txt" "$SD/tmp/failed-providers.$key" 2>/dev/null
# mock-fail's output is not an auth stub, so drive the auth path with a stub that looks unauthenticated
printf '#!/bin/sh\necho "Not logged in. Please run login."\nexit 0\n' > "$SD/mock-authfail"
chmod +x "$SD/mock-authfail"
( export PATH="$SD:$PATH" TMPDIR="$SD/tmp"
  printf 'x' | ZUVO_REVIEW_TEST_PROVIDERS="mock-authfail" bash "$ADV" --single --files "$EMPTY" ) >/dev/null 2>&1 || true
if [ "$(cat "$SD/victim.txt")" = "ORIGINAL" ]; then
  pass "planted symlink was not followed — victim file untouched"
else
  fail "PROV.16" "cache write followed a symlink: victim.txt now contains $(cat "$SD/victim.txt" | tr '\n' ' ')"
fi

start_test "PROV.17 the cache key carries no date (no silent reset across UTC midnight)"
grep -q '_ar_cache_key=.*date' "$ADV" \
  && bad_date=1 || bad_date=0
[ "$bad_date" -eq 0 ] && pass "cache key is date-free" \
                      || fail "PROV.17" "cache key embeds a date — a rotation across midnight re-probes dead providers"

start_test "PROV.18 single-provider path records timeout/empty outcomes, not just ok/auth"
out=$(ZUVO_RUN_ID=oc1 ZUVO_REVIEW_TEST_PROVIDERS="mock-timeout" ZUVO_REVIEW_TIMEOUT=2 \
  bash "$ADV" --single --files "$EMPTY" --artifact "$TD/oc.md" 2>&1) || true
h=$(hdr "$TD/oc.md")
if printf '%s' "$h" | grep -q 'provider_outcomes=mock-timeout:timeout'; then
  pass "a timed-out single provider is recorded as :timeout"
else
  fail "PROV.18" "single-path outcome missing — got: $(printf '%s' "$h" | grep provider_outcomes=)"
fi
