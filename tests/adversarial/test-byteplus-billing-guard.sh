#!/usr/bin/env bash
# test-byteplus-billing-guard.sh — the BytePlus ModelArk lane, and the one property that is
# worth a test more than any other in it.
#
# ModelArk serves the SAME api key on two base URLs, and the difference is money:
#   …/api/coding/v3   consumes the prepaid Coding Plan          (included, hard-stops when spent)
#   …/api/v3          bills the account balance, per token      (metered, silent)
# The vendor's own doc: "Requests sent to this Base URL do not consume your Coding Plan quota
# and will instead incur additional charges."
#
# So a single wrong character in a base URL turns every chunk of every review into a metered
# request, with no error, no log line that looks wrong, and no upper bound. The lane refuses
# rather than bills — and this file is what keeps a future edit from "simplifying" that away.

ADV="$ROOT/scripts/adversarial-review.sh"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1

BPTMP="$HERE/.tmp/bp.$$"; mkdir -p "$BPTMP"
cleanup_bp() { rm -rf "$BPTMP"; }
trap cleanup_bp EXIT
KEYFILE="$BPTMP/byteplus.key"
( umask 077; printf 'fake-key-for-test' > "$KEYFILE" )

# A provider's own stderr does NOT reach the caller's: the driver captures it per provider and,
# when the run produces no review, files it under $ZUVO_HOME/adversarial-failures/<run>/ instead.
# So the guard's message has to be read from there — asserting on the caller's stderr would look
# like the guard never fired. (Same plumbing that hides the agy fallback note on the happy path.)
# Each case gets its OWN home. Sharing one meant `ls -dt …/adversarial-failures/*/ | head -1`
# could hand a case the PREVIOUS case's evidence — which is how "the Coding Plan path is
# refused" appeared on a farm run while the same URL passed cleanly when run by hand. A test
# that reads a directory by recency is a test that can read somebody else's answer.
# The case name is an ARGUMENT, not a counter. `out=$(run_bp …)` runs the function in a
# SUBSHELL, so a counter incremented inside it never reaches the parent: every case reused
# case-1's home and case 4 read the refusals cases 1-3 had written. It failed while the same
# invocation passed by hand, which is the signature of shared state, not of a broken guard.
run_bp() { # run_bp <case-name> <base-url> [provider] -> that provider's captured stderr
  local home="$BPTMP/$1"; shift
  mkdir -p "$home"
  ZUVO_BYTEPLUS_KEY_FILE="$KEYFILE" ZUVO_BYTEPLUS_BASE_URL="$1" ZUVO_HOME="$home" \
  ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=25 \
    bash "$ADV" --provider "${2:-byteplus}" --mode code --files "$EMPTY" >/dev/null 2>&1
  cat "$home"/adversarial-failures/*/provider_*.stderr 2>/dev/null
}

# ─── 1. the metered base URL is REFUSED ───────────────────────────────────
start_test "bp.1 the pay-as-you-go base URL (/api/v3) is refused, not silently billed"
out=$(run_bp c1 "https://ark.ap-southeast.bytepluses.com/api/v3")
assert_contains "$out" "refusing" "the lane refuses the metered path"
assert_contains "$out" "bill" "…and says why, in money terms"

# ─── 2. …including the Chinese region host, same trap ─────────────────────
start_test "bp.2 the volces.com host is guarded too"
out=$(run_bp c2 "https://ark.cn-beijing.volces.com/api/v3")
assert_contains "$out" "refusing" "volces.com metered path refused"

# ─── 3. …and a lookalike that merely CONTAINS the right words ─────────────
# The guard must match the path, not a substring anywhere in the URL.
start_test "bp.3 a URL that only mentions /api/coding elsewhere is still refused"
out=$(run_bp c3 "https://ark.ap-southeast.bytepluses.com/api/v3?from=/api/coding")
assert_contains "$out" "refusing" "query-string lookalike refused"

# ─── 4. the Coding Plan path is NOT refused ───────────────────────────────
# It will fail afterwards on the fake key — that is fine and expected. What must not appear is
# the billing refusal, otherwise the guard would have made the lane unusable.
start_test "bp.4 the Coding Plan path is allowed through the guard"
out=$(run_bp c4 "https://ark.ap-southeast.bytepluses.com/api/coding/v3")
case "$out" in
  *refusing*) assert_eq "allowed" "refused" "the plan path must pass the billing guard" ;;
  *)          assert_eq "ok" "ok" "the plan path passes the guard (auth failure beyond it is expected)" ;;
esac

# ─── 5. both lanes exist and name different model families ────────────────
# Cross-model coverage is the entire point of a second lane; two aliases of one vendor would be
# a slot spent on nothing.
start_test "bp.5 byteplus and byteplus-alt resolve to different vendors"
if grep -q 'byteplus)     echo "${ZUVO_MODEL_BYTEPLUS:-glm-5.3-flash}"' "$ADV" \
   && grep -q 'byteplus-alt) echo "${ZUVO_MODEL_BYTEPLUS_ALT:-deepseek-v4-flash}"' "$ADV"; then
  assert_eq "ok" "ok" "byteplus=glm-5.3-flash, byteplus-alt=deepseek-v4-flash"
else
  assert_eq "two distinct model families" "not found" "lane model mapping"
fi

# ─── 6. the lane is opt-in, like every other paid-or-shared lane ──────────
# The plan's quota is shared with whatever else the owner points at it, so presence of a key
# must not be read as consent to spend it on every review.
start_test "bp.6 a key on disk alone does not enable the lane"
out=$(ZUVO_BYTEPLUS_KEY_FILE="$KEYFILE" ZUVO_HOME="$BPTMP" ZUVO_PROVIDER_BENCH=0 \
      ZUVO_REVIEW_TIMEOUT=8 ZUVO_ADV_BYTEPLUS=0 \
      bash "$ADV" --doctor 2>&1 | grep -c byteplus || true)
assert_eq "0" "${out:-0}" "without ZUVO_ADV_BYTEPLUS=1 the lane is not detected"
