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
export ZUVO_REVIEW_TEST_PROVIDERS=mock-success
export PATH="$MOCKS:$PATH"
# Isolate the failure cache per case so cases cannot leak into one another.
export TMPDIR="$TD"

hdr() { sed -n '1,/^---$/p' "$1"; }
# prov_run <artifact> <providers> [driver args...] — one review of the empty input over <providers>, written
# to <artifact>; everything the run printed (stdout and stderr) is kept in <artifact>.out. Never fatal: each
# case asserts on what the run left. One copy of the invocation fifteen cases had pasted.
prov_run() {
  local art="$1" provs="$2"; shift 2
  ZUVO_REVIEW_TEST_PROVIDERS="$provs" bash "$ADV" "$@" --files "$EMPTY" --artifact "$art" > "$art.out" 2>&1 || true
}
markers() { grep -c 'REVIEW BY:' "$1" 2>/dev/null || true; }   # markers <artifact> -> its REVIEW BY: lines
notes() { grep '^single_provider_note=' "$1" 2>/dev/null; }      # notes <artifact> -> its single_provider_note= lines

# ─── Case 1: all succeed → per-provider outcomes, no single_provider_note ──

start_test "PROV.1 two successes → provider_outcomes lists both, no single_provider_note"
ZUVO_RUN_ID=prov1 prov_run "$TD/a1.md" "mock-success mock-success" --multi
h=$(hdr "$TD/a1.md")
assert_contains "$h" "provider_outcomes=" "provider_outcomes present"
assert_contains "$h" "providers_attempted=2" "providers_attempted recorded"
if printf '%s' "$h" | grep -q '^single_provider_note='; then
  fail "single_provider_note must be absent when 2 providers reviewed"
else
  pass "no single_provider_note on a real multi-provider run"
fi
assert_contains "$h" "count_method=severity-records" "counts identify parsed severity records"

# ─── Case 2: a collapsed multi-run is distinguishable from a deliberate single ──

start_test "PROV.2 1 of 2 providers dies → single_provider_note explains the collapse"
ZUVO_RUN_ID=prov2 prov_run "$TD/a2.md" "mock-success mock-fail" --multi
h=$(hdr "$TD/a2.md")
assert_contains "$h" "single_provider_note=" "collapse is annotated"
assert_contains "$h" "produced no review" "note names the collapse, not a design choice"
assert_contains "$h" "mock-fail:" "failing provider appears in provider_outcomes"
assert_eq "single_provider_note=1 of 2 providers produced no review — see provider_outcomes" "$(notes "$TD/a2.md")" \
  "the note, exactly: how many of how many produced nothing (report.sh:49)"

start_test "PROV.3 deliberate --single → note says by design, not a failure"
ZUVO_RUN_ID=prov3 prov_run "$TD/a3.md" "mock-success mock-success" --single
h=$(hdr "$TD/a3.md")
assert_contains "$h" "by design" "deliberate single run is labelled as such"
assert_eq "single_provider_note=by design (--single)" "$(notes "$TD/a3.md")" "the note names the flag that chose it (report.sh:45)"

# ─── Case 3: --append-artifact keeps the earlier pass ──────────────────────

start_test "PROV.4 --append-artifact preserves pass 1"
ZUVO_RUN_ID=prov4 prov_run "$TD/a4.md" "mock-success"
first_created=$(grep -m1 '^created_at=' "$TD/a4.md")
ZUVO_RUN_ID=prov4 prov_run "$TD/a4.md" "mock-success" --append-artifact
assert_contains "$(cat "$TD/a4.md")" "=== APPENDED PASS" "append marker written"
assert_contains "$(cat "$TD/a4.md")" "$first_created" "pass 1 header survived the append"
n=$(grep -c '^artifact_kind=adversarial-review' "$TD/a4.md")
assert_eq "2" "$n" "both passes present in the appended artifact"
# One candidate, no --single: the collapse-versus-deliberate distinction this file's header is about. Not
# "by design" (nobody asked for one provider) and not "produced no review" (it did) — one was all there was
# (report.sh:46-47), said in each pass's header.
assert_eq "single_provider_note=only 1 provider available after exclusions
single_provider_note=only 1 provider available after exclusions" "$(notes "$TD/a4.md")" \
  "each pass says only 1 provider was available — no exclusion named, none was made"

start_test "PROV.4b one candidate left by --exclude: the note names the exclusion"
ZUVO_RUN_ID=prov4b prov_run "$TD/a4b.md" "mock-success mock-fail" --exclude mock-fail
assert_contains "$(hdr "$TD/a4b.md")" "providers_attempted=1" "premise: the exclusion left one candidate"
assert_eq "single_provider_note=only 1 provider available after exclusions (--exclude: mock-fail)" "$(notes "$TD/a4b.md")" \
  "the --exclude list is interpolated, so a gate can tell a caller's choice from a collapse (report.sh:47)"

start_test "PROV.4c one candidate left by the auth-failure cache: the note names the cached lane"
# A fresh cache entry for mock-fail under this run id: the lane is skipped as dead before dispatch.
seed_4c="$TD/zuvo-adv-$(id -u)"; mkdir -p "$seed_4c"; chmod 700 "$seed_4c"
printf 'mock-fail\t%s\n' "$(date +%s)" > "$seed_4c/failed-providers.prov4c"
ZUVO_RUN_ID=prov4c prov_run "$TD/a4c.md" "mock-success mock-fail"
assert_contains "$(hdr "$TD/a4c.md")" "providers_attempted=1" "premise: the cache left one candidate"
assert_eq "single_provider_note=only 1 provider available after exclusions (auth-cached: mock-fail)" "$(notes "$TD/a4c.md")" \
  "the auth-cached lane is interpolated (report.sh:47)"

start_test "PROV.5 without --append-artifact the file is still overwritten (no silent growth)"
ZUVO_RUN_ID=prov5 prov_run "$TD/a5.md" "mock-success"
ZUVO_RUN_ID=prov5 prov_run "$TD/a5.md" "mock-success"
n=$(grep -c '^artifact_kind=adversarial-review' "$TD/a5.md")
assert_eq "1" "$n" "default stays overwrite"

# ─── Case 4: --known-finding reaches the prompt and is budget-exempt ───────

start_test "PROV.6 --known-finding is injected into the review prompt"
out=$(bash "$ADV" --dry-run --files "$EMPTY" --known-finding "svc.ts:42:missing-tenant-scope" 2>&1)
assert_contains "$out" "ALREADY-DISPOSITIONED FINDINGS" "known-finding block present"
assert_contains "$out" "svc.ts:42:missing-tenant-scope" "the fingerprint itself is passed through"
assert_contains "$out" "count toward your finding limit" "repeats are budget-exempt"

start_test "PROV.7 no --known-finding → no stray block in the prompt"
out=$(bash "$ADV" --dry-run --files "$EMPTY" 2>&1)
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
# An entry is "<lane><TAB><epoch>" and lapses after ZUVO_AUTH_CACHE_TTL: seed a fresh one, or it is
# simply expired and this case tests nothing.
printf 'mock-success\t%s\n' "$(date +%s)" > "$seed"
ZUVO_RUN_ID="$cache_key" prov_run "$TD/a8.md" "mock-success"
assert_contains "$(cat "$TD/a8.md.out")" "ignoring it and retrying all" "fail-open: a fully-stale cache is discarded"
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
out=$(bash "$ADV" --dry-run --files "$EMPTY" 2>/dev/null)
assert_contains "$out" "DELIBERATE contract" "type-variant rule present in the code prompt"

# ─── Case 7: proof-of-work markers in EVERY dispatch mode and format ───────
# The gate (pipeline-gate-lib :: pg_artifact_proven) counts `REVIEW BY:` lines. They used to come
# only from the MULTI path's body banner, so a genuine --single / --rotate / --json review produced
# an artifact with ZERO markers and had its coverage refused. 19 retro hits.

start_test "PROV.12 single-provider artifact carries exactly one REVIEW BY marker"
ZUVO_RUN_ID=mk1 prov_run "$TD/m1.md" "mock-success mock-success" --single
n=$(markers "$TD/m1.md")
assert_eq "1" "$n" "one marker for one provider"
assert_contains "$(cat "$TD/m1.md")" "single_provider_note=" "…plus the single-provider note the gate accepts"

start_test "PROV.13 multi-provider artifact carries exactly one marker PER provider"
ZUVO_RUN_ID=mk2 prov_run "$TD/m2.md" "mock-success mock-success" --multi
n=$(markers "$TD/m2.md")
assert_eq "2" "$n" "two providers -> exactly two markers (not doubled by the body banner)"

start_test "PROV.14 JSON output still carries markers and a parseable body"
ZUVO_RUN_ID=mk3 prov_run "$TD/m3.md" "mock-success" --json
n=$(markers "$TD/m3.md")
assert_eq "1" "$n" "JSON mode is not exempt from proof-of-work"
body=$(sed -n '/^---$/,$p' "$TD/m3.md" | tail -n +2)
if printf '%s' "$body" | jq . >/dev/null 2>&1; then
  pass "JSON body survived marker injection (markers live in the header)"
else
  fail "PROV.14" "artifact body is no longer valid JSON"
fi

start_test "PROV.15 a failed provider contributes no marker"
ZUVO_RUN_ID=mk4 prov_run "$TD/m4.md" "mock-success mock-fail" --multi
n=$(markers "$TD/m4.md")
assert_eq "1" "$n" "markers count reviews, not attempts"

# ─── Case 8: the run-scoped failure cache must not be symlink-hijackable ───
# Found by this change's own adversarial pass (agy + cursor-agent, CRITICAL, CWE-59) and
# REPRODUCED before fixing: the cache path was $TMPDIR/zuvo-adv-failed-providers.<key>, a
# predictable name. With TMPDIR on a world-writable /tmp — which is where zuvo runs on the shared
# VPS hosts — a neighbour pre-creates that path as a symlink and the `>>` append writes THROUGH it
# into the victim's file. Confirmed by appending a provider name into a planted victim.txt.

# The plants sit where an UNGUARDED write would land: under the per-uid directory, at the cache file's real
# name. That name is the program's own key — ar_digest16 of ar_repo_root, read from the driver and evaluated
# here in the CWD the run uses (no ZUVO_RUN_ID) — never a formula restated in this file: the old plant used
# `tr / _` on the repo path, a key production had already replaced, so it matched no file and the case
# stayed green whatever the guard did. PROV.16c proves the key against a real write.
. "$ROOT/tests/lib/adversarial-driver.sh"   # the program as one text (also PROV.17)
prov16_key="$( eval "$(adv_driver_source "$ADV" 2>/dev/null \
  | awk '/^(ar_repo_root|ar_digest16)\(\) \{/ { on = 1 } on { print } on && /^}/ { on = 0 }')" 2>/dev/null \
  && ar_digest16 "$(ar_repo_root)" )"
[[ "$prov16_key" =~ ^[A-Za-z0-9._-]+$ ]] || prov16_key=""
# mock-fail's output is not an auth stub, so drive the auth path with a stub that looks unauthenticated
printf '#!/bin/sh\necho "Not logged in. Please run login."\nexit 0\n' > "$TD/mock-authfail"
chmod +x "$TD/mock-authfail"
# prov16_run <tmpdir> <err file> — one --single run of mock-authfail with TMPDIR=<tmpdir>, no ZUVO_RUN_ID.
prov16_run() {
  ( export PATH="$TD:$PATH" TMPDIR="$1"; unset ZUVO_RUN_ID
    printf 'x' | ZUVO_REVIEW_TEST_PROVIDERS="mock-authfail" bash "$ADV" --single --files "$EMPTY" ) >/dev/null 2>"$2" || true
}
PROV16_OFF="is not this user's private directory — the run's auth-failure cache is off"
PROV16_AUTH="WARN: mock-authfail not authenticated (auth error, no review)"

start_test "PROV.16 a symlink planted at the cache path cannot be written through"
SD="$TD/sym"; rm -rf "$SD"; mkdir -p "$SD/tmp"
printf 'ORIGINAL\n' > "$SD/victim.txt"
# The per-uid directory the code creates, planted as a link to a regular FILE.
ln -s "$SD/victim.txt" "$SD/tmp/zuvo-adv-$(id -u)" 2>/dev/null
prov16_run "$SD/tmp" "$SD/err"
if [ "$(cat "$SD/victim.txt")" = "ORIGINAL" ]; then
  pass "planted symlink was not followed — victim file untouched"
else
  fail "PROV.16" "cache write followed a symlink: victim.txt now contains $(cat "$SD/victim.txt" | tr '\n' ' ')"
fi
assert_contains "$(cat "$SD/err")" "$PROV16_OFF" "the run turns its cache off and says so (providers.sh:95-98)"
assert_contains "$(cat "$SD/err")" "$PROV16_AUTH" "the auth-failure path — the one that writes the cache — ran"

start_test "PROV.16b a per-uid directory planted as a symlink to a DIRECTORY is refused (CWE-59)"
# The real attack shape: a neighbour's directory at the predictable path, holding a link named exactly like
# the cache file and pointing at the victim. `mkdir -p` succeeds on a link to a directory, so only the `-L`
# test (providers.sh:96) stands between the `>>` append and the victim.
SD="$TD/symdir"; rm -rf "$SD"; mkdir -p "$SD/tmp" "$SD/attacker"
printf 'ORIGINAL\n' > "$SD/victim.txt"
if [[ -z "$prov16_key" ]]; then
  fail "premise: the cache key computed from the program" "ar_repo_root/ar_digest16 could not be read from the program"
else
  ln -s "$SD/victim.txt" "$SD/attacker/failed-providers.$prov16_key"
  ln -s "$SD/attacker" "$SD/tmp/zuvo-adv-$(id -u)"
  prov16_run "$SD/tmp" "$SD/err"
  assert_eq "ORIGINAL" "$(cat "$SD/victim.txt")" "the victim behind the planted cache file is untouched"
  assert_eq "failed-providers.$prov16_key" "$(ls "$SD/attacker")" "nothing was created in the neighbour's directory"
  assert_contains "$(cat "$SD/err")" "$PROV16_OFF" "the run turns its cache off and says so"
  assert_contains "$(cat "$SD/err")" "$PROV16_AUTH" "the auth-failure path — the one that writes the cache — ran"
fi

start_test "PROV.16c anchor: with a private per-uid dir the auth failure is cached under exactly that key"
# Without this, PROV.16b's plant could sit at a name no run ever writes, and pass for that reason alone.
SD="$TD/symanchor"; rm -rf "$SD"; mkdir -p "$SD/tmp"
prov16_run "$SD/tmp" "$SD/err"
assert_contains "$(cat "$SD/err")" "$PROV16_AUTH" "the auth-failure path ran"
assert_eq "mock-authfail" "$(cut -f1 "$SD/tmp/zuvo-adv-$(id -u)/failed-providers.${prov16_key:-unset}" 2>/dev/null)" \
  "the lane is cached in <TMPDIR>/zuvo-adv-<uid>/failed-providers.<the computed key>"

start_test "PROV.17 the cache key carries no date (no silent reset across UTC midnight)"
. "$ROOT/tests/lib/adversarial-driver.sh"   # its own load (also above): the key is built in a module now
# A here-string, not `printf | grep -q`: under pipefail grep's early exit on a MATCH can SIGPIPE the writer
# and read as "not found" — exactly the wrong way round for an absence check.
if ! prov17_src="$(adv_driver_source "$ADV")"; then
  fail "PROV.17" "the program text could not be assembled (reason above) — the absence check cannot run"
elif ! grep -q '^_ar_cache_key=' <<< "$prov17_src"; then
  # The anchor: with the key renamed or built elsewhere, "no _ar_cache_key=…date line" holds for any key.
  fail "PROV.17" "the cache-key assignment (^_ar_cache_key=) was not found — the absence check would prove nothing"
elif grep -q '_ar_cache_key=.*date' <<< "$prov17_src"; then
  fail "PROV.17" "cache key embeds a date — a rotation across midnight re-probes dead providers"
else
  pass "cache key is date-free"
fi

start_test "PROV.18 single-provider path records timeout/empty outcomes, not just ok/auth"
ZUVO_RUN_ID=oc1 ZUVO_REVIEW_TIMEOUT=2 prov_run "$TD/oc.md" "mock-timeout" --single
h=$(hdr "$TD/oc.md")
if printf '%s' "$h" | grep -q 'provider_outcomes=mock-timeout:timeout'; then
  pass "a timed-out single provider is recorded as :timeout"
else
  fail "PROV.18" "single-path outcome missing — got: $(printf '%s' "$h" | grep provider_outcomes=)"
fi
