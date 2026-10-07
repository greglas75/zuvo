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

BPTMP="$HERE/.tmp/bp.$$"; mkdir -p "$BPTMP/bin"
cleanup_bp() { rm -rf "$BPTMP"; }
trap cleanup_bp EXIT
KEYFILE="$BPTMP/byteplus.key"
( umask 077; printf 'fake-key-for-test' > "$KEYFILE" )
PLAN_URL="https://ark.ap-southeast.bytepluses.com/api/coding/v3"

# No case reaches a real host: every run has this fake curl first on PATH. It records what each call
# was asked for under $BP_REC (the case's home) — the URL, the -K config (where the key travels) and the
# -d payload — and answers like a model that found nothing. A refusal is then proven by curl.urls
# never being written, and an allowed request by the exact URL it went to.
cat > "$BPTMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  case "$prev" in
    -K) cat "$a" >> "$BP_REC/curl.cfg" ;;
    -d) cp "${a#@}" "$BP_REC/payload.json" ;;
  esac
  case "$a" in *://*) printf '%s\n' "$a" >> "$BP_REC/curl.urls" ;; esac
  prev="$a"
done
printf '%s\n%s' '{"choices":[{"message":{"content":"NO ISSUES FOUND."}}]}' 200
EOF
chmod +x "$BPTMP/bin/curl"

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
# run_bp <case-name> <base-url, "" = unset> [provider] [driver] -> that provider's captured stderr. The
# run's exit code is left in <home>/rc and the fake curl's records in <home>/curl.*; HOME is the case's
# home too, so no ~/.zuvo key, registry or ledger of the machine takes part.
run_bp() {
  local home="$BPTMP/$1"; shift
  mkdir -p "$home"
  env -u ZUVO_BYTEPLUS_BASE_URL ${1:+"ZUVO_BYTEPLUS_BASE_URL=$1"} PATH="$BPTMP/bin:$PATH" BP_REC="$home" \
    ZUVO_BYTEPLUS_KEY_FILE="$KEYFILE" HOME="$home" ZUVO_HOME="$home" \
    ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=25 \
    bash "${3:-$ADV}" --provider "${2:-byteplus}" --mode code --files "$EMPTY" >/dev/null 2>&1
  echo "$?" > "$home/rc"
  cat "$home"/adversarial-failures/*/provider_*.stderr 2>/dev/null
}
# refused_without_request <case> — the refusal's two halves besides its message: no review (exit 2) and
# no request at all (curl never called). An if, not `A && fail … || pass`: fail returns non-zero, so that
# form also ran pass and counted one check twice — a fail AND a pass.
refused_without_request() {
  assert_eq "2" "$(cat "$BPTMP/$1/rc")" "no review (exit 2)"
  if [ -e "$BPTMP/$1/curl.urls" ]; then
    fail "…but a request was sent anyway" "$(cat "$BPTMP/$1/curl.urls")"
  else
    pass "…and no request was sent"
  fi
}
# sent_to <case> <url> — exactly one request, to <url>/chat/completions, and the run reviewed (exit 0).
sent_to() {
  assert_eq "$2/chat/completions" "$(cat "$BPTMP/$1/curl.urls" 2>/dev/null)" "exactly one request, to the Coding Plan endpoint"
  assert_eq "0" "$(cat "$BPTMP/$1/rc")" "…answered: the review completes (exit 0)"
}

# ─── 1. the metered base URL is REFUSED ───────────────────────────────────
start_test "bp.1 the pay-as-you-go base URL (/api/v3) is refused, not silently billed"
out=$(run_bp c1 "https://ark.ap-southeast.bytepluses.com/api/v3")
assert_contains "$out" "refusing" "the lane refuses the metered path"
assert_contains "$out" "bill" "…and says why, in money terms"
refused_without_request c1

# ─── 2. …including the Chinese region host, same trap ─────────────────────
start_test "bp.2 the volces.com host is guarded too"
out=$(run_bp c2 "https://ark.cn-beijing.volces.com/api/v3")
assert_contains "$out" "refusing" "volces.com metered path refused"
refused_without_request c2

# ─── 3. …and a lookalike that merely CONTAINS the right words ─────────────
# The guard must match the path, not a substring anywhere in the URL.
start_test "bp.3 a URL that only mentions /api/coding elsewhere is still refused"
out=$(run_bp c3 "https://ark.ap-southeast.bytepluses.com/api/v3?from=/api/coding")
assert_contains "$out" "refusing" "query-string lookalike refused"
refused_without_request c3

# ─── 4. the Coding Plan path is NOT refused ───────────────────────────────
# What must not happen is the billing refusal, otherwise the guard would have made the lane unusable:
# the request goes out, to the plan's endpoint (the fake curl answers it).
start_test "bp.4 the Coding Plan path is allowed through the guard"
out=$(run_bp c4 "$PLAN_URL")
case "$out" in *refusing*) fail "the plan path was refused by the billing guard" "$out" ;; *) pass "no refusal" ;; esac
sent_to c4 "$PLAN_URL"

# ─── 5. both lanes exist and name different model families ────────────────
# Cross-model coverage is the entire point of a second lane; two aliases of one vendor would be
# a slot spent on nothing. Read off the requests the two lanes actually send.
start_test "bp.5 byteplus and byteplus-alt resolve to different vendors"
# Both lanes run HERE, each in its own home, so this case runs alone.
run_bp c5a "$PLAN_URL" byteplus >/dev/null
run_bp c5 "$PLAN_URL" byteplus-alt >/dev/null
m4="$(jq -r '.model' "$BPTMP/c5a/payload.json" 2>/dev/null)"; m5="$(jq -r '.model' "$BPTMP/c5/payload.json" 2>/dev/null)"
assert_eq "glm-5.3-flash" "$m4" "byteplus asks for glm-5.3-flash"
assert_eq "deepseek-v4-flash" "$m5" "byteplus-alt asks for deepseek-v4-flash"
assert_ne "$m4" "$m5" "…two different models"

# ─── 6. the lane is opt-in, like every other paid-or-shared lane ──────────
# The plan's quota is shared with whatever else the owner points at it, so presence of a key
# must not be read as consent to spend it on every review. --list-providers is detection alone: no
# lane is probed (--doctor would call every client this machine has, for real).
start_test "bp.6 a key on disk alone does not enable the lane"
mkdir -p "$BPTMP/c6"
bp_listed() { # bp_listed <ZUVO_ADV_BYTEPLUS value> -> the byteplus lanes detection offers, space-separated
  env -u BYTEPLUS_API_KEY -u ZUVO_ADV_BYTEPLUS_LANES ZUVO_BYTEPLUS_KEY_FILE="$KEYFILE" HOME="$BPTMP/c6" ZUVO_HOME="$BPTMP/c6" \
    ZUVO_ADV_BYTEPLUS="$1" bash "$ADV" --list-providers 2>/dev/null | awk '/^byteplus/' | tr '\n' ' ' | sed 's/ $//'
}
assert_eq "" "$(bp_listed 0)" "without ZUVO_ADV_BYTEPLUS=1 the lane is not detected"
assert_eq "byteplus byteplus-3" "$(bp_listed 1)" "anchor: with it (and the key), both default lanes are"

# ─── 7. the plan's own key, never the OpenRouter one ──────────────────────
# run_byteplus reuses the OpenRouter client, which reads OPENROUTER_API_KEY FIRST. A BytePlus lane must
# blank it, or an OpenRouter key set in the environment is sent to the BytePlus endpoint (and the plan
# key ignored).
start_test "bp.7 a BytePlus lane sends the plan key, never OPENROUTER_API_KEY"
OPENROUTER_API_KEY=sk-or-must-not-leak run_bp c7 "$PLAN_URL" >/dev/null
cfg="$(cat "$BPTMP/c7/curl.cfg" 2>/dev/null)"
assert_contains "$cfg" "fake-key-for-test" "the Coding Plan key is the one sent"
case "$cfg" in *sk-or-must-not-leak*) fail "the OpenRouter key reached the BytePlus endpoint" ;; *) pass "the OpenRouter key is never sent to BytePlus" ;; esac

# ─── 8. with no base URL set, the lane goes to the Coding Plan ────────────
# Two defaults stand between an unset ZUVO_BYTEPLUS_BASE_URL and a request: the model registry's (loaded
# in the repo, the cache and every install) and the driver's own fallback (scripts/lib/adversarial-
# dispatch.sh, run_byteplus) for a driver that finds no registry. Both must be the plan's path.
start_test "bp.8 an unset base URL means the Coding Plan, never the metered path"
out=$(run_bp c8 "")
case "$out" in *refusing*) fail "the default base URL was refused by the billing guard" "$out" ;; *) pass "no refusal (the registry's default)" ;; esac
sent_to c8 "$PLAN_URL"
. "$ROOT/tests/lib/adversarial-driver.sh"
# A copy beside no registry: <dir>/model-registry.sh absent, no ../shared/includes, HOME holds none.
adv_driver_copy "$ADV" "$BPTMP/noreg/adversarial-review.sh" || fail "premise: copying the driver failed"
cp "$ROOT/scripts/lib/model-subprocess.sh" "$BPTMP/noreg/lib/model-subprocess.sh"
out=$(run_bp c8b "" byteplus "$BPTMP/noreg/adversarial-review.sh")
case "$out" in *refusing*) fail "the driver's own default base URL was refused" "$out" ;; *) pass "no refusal (the driver's own fallback, no registry)" ;; esac
sent_to c8b "$PLAN_URL"

# ─── 9-11. the guard compares the PATH: fragment cut, trailing slash, both plan forms ──
# The billing guard in run_openrouter (adversarial-lanes-http.sh). The three branches the query-string case
# (bp.3) does not reach: the `#` cut, the trailing-slash trim and the second accepted form, `/api/coding`
# without `/v3`.
start_test "bp.9 a fragment lookalike (/api/v3#/api/coding) is refused, not billed"
# Without the fragment cut, this URL ends in `/api/coding` and passes the allow-list — and curl never sends
# a fragment, so the request would go to /api/v3: the metered endpoint.
out=$(run_bp c9 "https://ark.ap-southeast.bytepluses.com/api/v3#/api/coding")
assert_contains "$out" "refusing" "fragment lookalike refused"
refused_without_request c9

start_test "bp.10 the plan path with a trailing slash is still the plan path"
out=$(run_bp c10 "$PLAN_URL/")
case "$out" in *refusing*) fail "the plan path with a trailing slash was refused by the billing guard" "$out" ;; *) pass "no refusal" ;; esac
sent_to c10 "$PLAN_URL/"

start_test "bp.11 /api/coding without /v3 is the plan's other accepted form"
out=$(run_bp c11 "https://ark.ap-southeast.bytepluses.com/api/coding")
case "$out" in *refusing*) fail "/api/coding was refused by the billing guard" "$out" ;; *) pass "no refusal" ;; esac
sent_to c11 "https://ark.ap-southeast.bytepluses.com/api/coding"

# ─── 12. the third lane goes through the same client, guard and key ───────
# byteplus-3 is in the default lane set (bp.6) but was never dispatched by a case: its arm of
# _dispatch_provider_inner (adversarial-dispatch.sh) routes it through run_byteplus like the other two, with
# its own model.
start_test "bp.12 byteplus-3 is dispatched through run_byteplus, to the plan, with its own model"
out=$(run_bp c12 "$PLAN_URL" byteplus-3)
case "$out" in *refusing*) fail "byteplus-3 was refused by the billing guard" "$out" ;; *) pass "no refusal" ;; esac
sent_to c12 "$PLAN_URL"
assert_eq "dola-seed-2.0-code" "$(jq -r '.model' "$BPTMP/c12/payload.json" 2>/dev/null)" "byteplus-3 asks for dola-seed-2.0-code"
assert_contains "$(cat "$BPTMP/c12/curl.cfg" 2>/dev/null)" "fake-key-for-test" "…with the Coding Plan key"
