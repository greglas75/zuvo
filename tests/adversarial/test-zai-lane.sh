#!/usr/bin/env bash
# test-zai-lane.sh — the Z.ai GLM Coding Plan lane (`zai`): where its requests may go, whose key they
# carry, when it is on, and which 429s it stops asking on.
#
# Z.ai serves two OpenAI-compatible bases and the difference is money:
#   …/api/coding/paas/v4   the prepaid GLM Coding Plan
#   …/api/paas/v4          the metered API
# The lane reuses the OpenRouter client, whose billing guard (_plan_endpoint, adversarial-lanes-http.sh)
# must refuse every z.ai/bigmodel.cn path that is not the plan's — the same trap test-byteplus-billing-guard.sh
# pins for BytePlus, which shares that guard.

ADV="$ROOT/scripts/adversarial-review.sh"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1

ZTMP="$HERE/.tmp/zai.$$"; mkdir -p "$ZTMP/bin"
cleanup_zai() { rm -rf "$ZTMP"; }
trap cleanup_zai EXIT
KEYFILE="$ZTMP/zai.key"
( umask 077; printf 'zai-id.zai-secret-for-test' > "$KEYFILE" )
PLAN_URL="https://api.z.ai/api/coding/paas/v4"

# No case reaches a real host: this fake curl is first on PATH. It records each call under $Z_REC (the case's
# home) — the URL, the -K config (where the key travels), the -d payload — and answers with $Z_CODE (default
# 200) and $Z_BODY (default: a model that found nothing).
cat > "$ZTMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  case "$prev" in
    -K) cat "$a" >> "$Z_REC/curl.cfg" ;;
    -d) cp "${a#@}" "$Z_REC/payload.json" ;;
  esac
  case "$a" in *://*) printf '%s\n' "$a" >> "$Z_REC/curl.urls" ;; esac
  prev="$a"
done
# The default is a variable, not `${Z_BODY:-{…}}`: the braces of a JSON default end that expansion early.
ok='{"choices":[{"message":{"content":"NO ISSUES FOUND."}}]}'
printf '%s\n%s' "${Z_BODY:-$ok}" "${Z_CODE:-200}"
EOF
chmod +x "$ZTMP/bin/curl"

# run_zai <case> <base-url, "" = unset> [driver] -> the lane's captured stderr (the driver files a failed
# provider's stderr under $ZUVO_HOME/adversarial-failures/). Exit code in <home>/rc. One home per case: a
# shared one lets a case read another case's evidence (see test-byteplus-billing-guard.sh).
run_zai() {
  local home="$ZTMP/$1"
  mkdir -p "$home"
  env -u ZUVO_ZAI_BASE_URL -u ZAI_API_KEY ${2:+"ZUVO_ZAI_BASE_URL=$2"} PATH="$ZTMP/bin:$PATH" Z_REC="$home" \
    ZUVO_ZAI_KEY_FILE="$KEYFILE" HOME="$home" ZUVO_HOME="$home" \
    ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=40 \
    bash "${3:-$ADV}" --provider zai --mode code --files "$EMPTY" >/dev/null 2>&1
  echo "$?" > "$home/rc"
  cat "$home"/adversarial-failures/*/provider_*.stderr 2>/dev/null
}
requests() { [ -s "$ZTMP/$1/curl.urls" ] && wc -l < "$ZTMP/$1/curl.urls" | tr -d ' ' || echo 0; }
refused_without_request() {
  assert_eq "2" "$(cat "$ZTMP/$1/rc")" "no review (exit 2)"
  assert_eq "0" "$(requests "$1")" "…and no request was sent"
}
sent_to_plan() {
  assert_eq "$PLAN_URL/chat/completions" "$(cat "$ZTMP/$1/curl.urls" 2>/dev/null)" "exactly one request, to the Coding Plan endpoint"
  assert_eq "0" "$(cat "$ZTMP/$1/rc")" "…answered: the review completes (exit 0)"
}

# ─── 1-3. the metered API is refused, on both hosts and behind a query lookalike ──
start_test "zai.1 the metered base URL (/api/paas/v4) is refused, not billed"
out=$(run_zai c1 "https://api.z.ai/api/paas/v4")
assert_contains "$out" "refusing" "the lane refuses the metered path"
assert_contains "$out" "/api/coding/paas/v4" "…and names the plan path it wants"
refused_without_request c1

start_test "zai.2 the bigmodel.cn host is guarded too"
out=$(run_zai c2 "https://open.bigmodel.cn/api/paas/v4")
assert_contains "$out" "refusing" "bigmodel.cn metered path refused"
refused_without_request c2

start_test "zai.3 a URL that only mentions the plan path in its query is still refused"
out=$(run_zai c3 "https://api.z.ai/api/paas/v4?next=/api/coding/paas/v4")
assert_contains "$out" "refusing" "query-string lookalike refused"
refused_without_request c3

# ─── 4. the plan key goes to https Z.ai only — the guard fails closed ─────
# A guard that only refuses wrong PATHS on hosts it recognises lets every other spelling through: the trailing-dot
# FQDN (still Z.ai, metered path), a lookalike host, plain http — each carrying the plan key.
start_test "zai.4 the plan key is never sent off https Z.ai, whatever the spelling"
n=0
for url in "https://api.z.ai./api/paas/v4" "https://api.xyz.ai/v1" "https://api.z.ai.evil.example/api/coding/paas/v4" \
           "https://api.z.ai@evil.example/api/coding/paas/v4" "http://api.z.ai/api/coding/paas/v4" \
           "https://api.z.ai%2e.evil.example/api/coding/paas/v4" "https://api.z.ai?x=/api/coding/paas/v4" \
           "https://api.z.ai/api/paas/v4/x/api/coding/paas/v4" "$(printf 'https://api.z.ai/api/paas/v4\n/api/coding/paas/v4')" \
           "https://api.z.ai:8443/api/coding/paas/v4"; do
  n=$((n + 1)); out=$(run_zai "c4-$n" "$url")
  assert_contains "$out" "refusing" "$url refused"
  refused_without_request "c4-$n"
done

# ─── 5. defaults: the plan, the plan key, the registry model, streaming ───
start_test "zai.5 an unset base URL sends one streamed glm-5.3-flash request, thinking off, to the plan, with the plan key"
OPENROUTER_API_KEY=sk-or-must-not-leak run_zai c5 "" >/dev/null
sent_to_plan c5
cfg="$(cat "$ZTMP/c5/curl.cfg" 2>/dev/null)"
assert_contains "$cfg" "zai-id.zai-secret-for-test" "the key file's key is the one sent"
case "$cfg" in *sk-or-must-not-leak*) fail "the OpenRouter key reached Z.ai" ;; *) pass "the OpenRouter key is never sent to Z.ai" ;; esac
assert_eq "glm-5.3-flash" "$(jq -r '.model' "$ZTMP/c5/payload.json" 2>/dev/null)" "the registry's model"
# Bug caught: reasoning left on — every real review ran out the 300 s lane budget (2026-10-17, 4 timeouts, 6 h bench).
assert_eq "disabled" "$(jq -r '.thinking.type' "$ZTMP/c5/payload.json" 2>/dev/null)" "reasoning is switched off"
assert_eq "true" "$(jq -r '.stream' "$ZTMP/c5/payload.json" 2>/dev/null)" "streamed, like the BytePlus plan lanes"

# Bug caught: the opt-back-in switch ignored, so reasoning could never be turned on again for a bench.
start_test "zai.5b ZUVO_ZAI_THINKING=on sends thinking enabled"
ZUVO_ZAI_THINKING=on run_zai c5b "" >/dev/null
assert_eq "enabled" "$(jq -r '.thinking.type' "$ZTMP/c5b/payload.json" 2>/dev/null)" "reasoning is back on"

# The driver's own fallback (adversarial-dispatch.sh) for a copy that finds no model-registry.sh.
start_test "zai.6 without a registry the driver's own default is still the plan"
. "$ROOT/tests/lib/adversarial-driver.sh"
adv_driver_copy "$ADV" "$ZTMP/noreg/adversarial-review.sh" || fail "premise: copying the driver failed"
cp "$ROOT/scripts/lib/model-subprocess.sh" "$ZTMP/noreg/lib/model-subprocess.sh"
run_zai c6 "" "$ZTMP/noreg/adversarial-review.sh" >/dev/null
sent_to_plan c6
assert_eq "glm-5.3-flash" "$(jq -r '.model' "$ZTMP/c6/payload.json" 2>/dev/null)" "lane_model's own fallback model"

# ─── 7. opt-in: a key on disk is not consent to spend a shared plan ───────
start_test "zai.7 the key alone does not enable the lane; ZUVO_ADV_ZAI=1 does"
mkdir -p "$ZTMP/c7"
zai_listed() { # zai_listed <ZUVO_ADV_ZAI value> -> "zai" when detection offers the lane
  env -u ZAI_API_KEY ZUVO_ZAI_KEY_FILE="$KEYFILE" HOME="$ZTMP/c7" ZUVO_HOME="$ZTMP/c7" \
    ZUVO_ADV_ZAI="$1" bash "$ADV" --list-providers 2>/dev/null | awk '$1 == "zai"' | tr -d '\n'
}
assert_eq "" "$(zai_listed 0)" "without ZUVO_ADV_ZAI=1 the lane is not detected"
assert_eq "zai" "$(zai_listed 1)" "with it (and the key) the lane is"

# ─── 8-9. a spent plan is not asked again; a rate limit is ────────────────
start_test "zai.8 a spent 5-hour window (code 1308) is one request, not retried"
out=$(Z_CODE=429 Z_BODY='{"error":{"code":"1308","message":"Usage limit reached for 5 hour. Your limit will reset at 2026-10-17 03:00:00"}}' run_zai c8 "$PLAN_URL")
assert_eq "1" "$(requests c8)" "one request only"
assert_contains "$out" "not retried" "the WARN says it stopped on purpose"
assert_contains "$out" "will reset at 2026-10-17 03:00:00" "…and quotes the vendor's reset"
assert_eq "2" "$(cat "$ZTMP/c8/rc")" "no review (exit 2)"

start_test "zai.9 a plain rate limit (code 1302) IS retried — the stop is for plan refusals only"
Z_CODE=429 Z_BODY='{"error":{"code":"1302","message":"Rate limit reached for requests"}}' run_zai c9 "$PLAN_URL" >/dev/null
assert_eq "3" "$(requests c9)" "all OR_ATTEMPTS requests were made"

# ─── 10. no zai key → no request, even with an OpenRouter key file beside it ──
# The shared client's default key file is ~/.zuvo/openrouter.key; the zai lane must never fall back to it.
start_test "zai.10 a missing zai key skips the lane; the OpenRouter key file is never sent to Z.ai"
mkdir -p "$ZTMP/c10/.zuvo"; ( umask 077; printf 'sk-or-file-must-not-leak' > "$ZTMP/c10/.zuvo/openrouter.key" )
env -u ZAI_API_KEY -u OPENROUTER_API_KEY PATH="$ZTMP/bin:$PATH" Z_REC="$ZTMP/c10" HOME="$ZTMP/c10" ZUVO_HOME="$ZTMP/c10" \
  ZUVO_ZAI_KEY_FILE="$ZTMP/c10/absent.key" ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=40 \
  bash "$ADV" --provider zai --mode code --files "$EMPTY" >/dev/null 2>&1
assert_eq "0" "$(requests c10)" "no request without the zai key"
assert_contains "$(cat "$ZTMP/c10"/adversarial-failures/*/provider_*.stderr 2>/dev/null)" "absent.key" "…skipped for the missing zai key file, by name"

# ─── 11. another vendor's PLAN host is refused too, not only unknown hosts ──
# _plan_endpoint names the plan the host spends; a zai lane on BytePlus's plan URL would send the Z.ai key there.
start_test "zai.11 the zai lane refuses the BytePlus plan endpoint"
out=$(run_zai c11 "https://ark.ap-southeast.bytepluses.com/api/coding/v3")
assert_contains "$out" "refusing to send the plan key" "cross-vendor plan host refused"
refused_without_request c11

# ─── 12. the accepted spellings: explicit :443 and the bigmodel.cn plan path ──
start_test "zai.12 https on :443 and open.bigmodel.cn's plan path are the plan, not refused"
run_zai c12a "https://api.z.ai:443/api/coding/paas/v4" >/dev/null
assert_eq "https://api.z.ai:443/api/coding/paas/v4/chat/completions" "$(cat "$ZTMP/c12a/curl.urls" 2>/dev/null)" ":443 is the default port: sent"
run_zai c12b "https://open.bigmodel.cn/api/coding/paas/v4" >/dev/null
assert_eq "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions" "$(cat "$ZTMP/c12b/curl.urls" 2>/dev/null)" "bigmodel.cn plan path: sent"

# ─── 13. every plan-refusal family stops at one request ──────────────────
# 1308 is pinned in zai.8; these are the other windows, an empty package and a model outside the plan.
start_test "zai.13 weekly window, no package, extra-usage cap, model outside the plan: one request each"
for code in 1310 1113 1321 1311; do
  Z_CODE=429 Z_BODY="{\"error\":{\"code\":\"$code\",\"message\":\"plan refusal $code\"}}" run_zai "c13-$code" "$PLAN_URL" >/dev/null
  assert_eq "1" "$(requests "c13-$code")" "code $code: not retried"
done
