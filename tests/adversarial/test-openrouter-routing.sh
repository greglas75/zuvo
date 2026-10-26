#!/usr/bin/env bash
# test-openrouter-routing.sh — the `provider` object an OpenRouter request carries (openrouter_provider_routing,
# adversarial-lanes-http.sh): a model in the pin table keeps its hosts (#108), an unpinned one is sorted by throughput
# and kept off fp4 where it has fp8-or-better endpoints, per-lane env overrides, and none of it sent to a plan; and the
# `reasoning` effort a lane asks for (openrouter_reasoning).

ADV="$ROOT/scripts/adversarial-review.sh"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1

RTMP="$HERE/.tmp/orroute.$$"; mkdir -p "$RTMP/bin"
cleanup_orroute() { rm -rf "$RTMP"; }
trap cleanup_orroute EXIT

# Fake curl: each chat request's body -> bodies.jsonl; /key answers a spend of $0; a chat answers a review.
cat > "$RTMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
prev="" url=""
for a in "$@"; do
  [ "$prev" = "-d" ] && jq -c . "${a#@}" >> "$RR_REC/bodies.jsonl"
  case "$a" in *://*) url="$a" ;; esac
  prev="$a"
done
case "$url" in */key) printf '{"data":{"usage_daily":0}}'; exit 0 ;; esac
printf '%s\n%s' '{"provider":"DeepInfra","choices":[{"message":{"content":"NO ISSUES FOUND."}}]}' 200
EOF
chmod +x "$RTMP/bin/curl"
BPKEY="$RTMP/byteplus.key"; ( umask 077; printf 'fake-plan-key' > "$BPKEY" )

# run_r <case> <lane> [VAR=value…] — the lane's one review; its request's `provider` field ("none" when absent)
# on stdout, its stderr in <home>/err.
run_r() {
  local home="$RTMP/$1" lane="$2"; shift 2
  mkdir -p "$home/.zuvo"
  ( umask 077; printf 'fake-or-key' > "$home/.zuvo/openrouter.key" )
  env -u OPENROUTER_API_KEY -u ZUVO_OPENROUTER_BASE_URL -u ZUVO_BYTEPLUS_BASE_URL -u BYTEPLUS_API_KEY \
    -u ZUVO_OR_SORT_OPENROUTER -u ZUVO_OR_QUANTS_OPENROUTER -u ZUVO_OR_SORT_OPENROUTER_4 -u ZUVO_OR_QUANTS_OPENROUTER_4 \
    -u ZUVO_OR_SORT_OPENROUTER_MINI -u ZUVO_OR_QUANTS_OPENROUTER_MINI -u ZUVO_OR_PROVIDER_ORDER \
    -u ZUVO_OR_REASONING_OPENROUTER -u ZUVO_OR_REASONING_OPENROUTER_ALT -u ZUVO_OR_REASONING_OPENROUTER_3 \
    -u ZUVO_OR_REASONING_OPENROUTER_4 -u ZUVO_OR_REASONING_OPENROUTER_MINI -u ZUVO_OR_REASONING_OPENROUTER_5 \
    -u ZUVO_OR_SORT_OPENROUTER_5 -u ZUVO_OR_QUANTS_OPENROUTER_5 -u ZUVO_OR_MAX_INFLIGHT_INCEPTION_MERCURY_3 \
    -u ZUVO_MODEL_OPENROUTER -u ZUVO_MODEL_OPENROUTER_ALT -u ZUVO_MODEL_OPENROUTER_3 -u ZUVO_MODEL_OPENROUTER_MINI \
    -u ZUVO_MODEL_OPENROUTER_5 ZUVO_OR_INFLIGHT_DIR="$home/slots" \
    PATH="$RTMP/bin:$PATH" RR_REC="$home" HOME="$home" ZUVO_HOME="$home" ZUVO_BYTEPLUS_KEY_FILE="$BPKEY" \
    ZUVO_ADVERSARIAL_LOG_FILE="$home/adversarial.log" ZUVO_PROVIDER_HEALTH_FILE="$home/health" \
    ZUVO_OPENROUTER_USAGE_FILE="$home/usage" ZUVO_BYTEPLUS_QUOTA_FILE="$home/bpquota" \
    ZUVO_ADV_OPENROUTER=1 ZUVO_ADV_BYTEPLUS=1 ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=25 "$@" \
    bash "$ADV" --provider "$lane" --mode code --files "$EMPTY" >/dev/null 2>"$home/err"
  jq -c '.provider // "none"' "$home/bodies.jsonl" 2>/dev/null
}

# Bug caught: glm-5.3-flashx balanced by price onto a slow or 4-bit endpoint (unpinned mimo did: 32% timeouts).
start_test "rr.1 an unpinned lane on a model with fp8 endpoints: sorted by throughput, fp8 or better only"
assert_eq '{"sort":"throughput","quantizations":["fp8","fp16","bf16","fp32"]}' "$(run_r c1 openrouter)" "openrouter (glm-5.3-flashx)"

# Bug caught: a quantization filter on a model served only at fp4 / undeclared, which leaves it no endpoint (404).
start_test "rr.2 a model without fp8 endpoints gets the sort and no quantization filter"
assert_eq '{"sort":"throughput"}' "$(run_r c2 openrouter-5)" "openrouter-5 (mercury-3, one undeclared endpoint)"

# Bug caught: the sort or filter overriding the owner's host pins, or a second pin table drifting from #108's.
start_test "rr.7 pinned models keep exactly their hosts, no fallbacks, no sort"
assert_eq '{"order":["makora","deepinfra"],"allow_fallbacks":false}' "$(run_r c7 openrouter-alt)" "mimo: Makora, then DeepInfra"
assert_eq '{"order":["novita"],"allow_fallbacks":false}' "$(run_r c7b openrouter-3)" "ling-3.1-flash: Novita only"

# Bug caught: openrouter-mini still sending the retired :free id (the lane only timed out from 2026-10-22), or the paid
# minimax balanced onto the slow hosts measured 2026-10-24 (3/5 of the slowest batches past the 300 s ceiling).
start_test "rr.8 openrouter-mini sends the paid minimax-m3.1-flash pinned to Parasail fp8, then GMICloud fp8"
assert_eq '{"order":["parasail/fp8","gmicloud/fp8"],"allow_fallbacks":false,"quantizations":["fp8"]}' "$(run_r c8 openrouter-mini)" "the pinned hosts"
assert_eq '"minimax/minimax-m3.1-flash"' "$(jq -c '.model' "$RTMP/c8/bodies.jsonl")" "the paid model id"
run_r c8b openrouter-5 >/dev/null
assert_eq '"inception/mercury-3"' "$(jq -c '.model' "$RTMP/c8b/bodies.jsonl")" "openrouter-5 sends mercury-3"

# Bug caught: no way to turn the routing off for one lane when a provider change breaks it.
start_test "rr.3 the per-lane env overrides set or empty the sort and the filter"
assert_eq '"none"' "$(run_r c3 openrouter ZUVO_OR_SORT_OPENROUTER= ZUVO_OR_QUANTS_OPENROUTER=)" "both emptied: no provider object"
assert_eq '{"sort":"latency","quantizations":["bf16"]}' "$(run_r c3b openrouter ZUVO_OR_SORT_OPENROUTER=latency ZUVO_OR_QUANTS_OPENROUTER=bf16)" "both set"
assert_eq '{"sort":"throughput","quantizations":["fp8","fp16","bf16","fp32"]}' "$(run_r c3c openrouter ZUVO_OR_QUANTS_OPENROUTER_4=)" "another lane's override does not leak"

# Bug caught: a typo sending routing nobody asked for (or OpenRouter rejecting the request mid-review).
start_test "rr.4 a malformed sort is refused before any request"
assert_eq "" "$(run_r c4 openrouter ZUVO_OR_SORT_OPENROUTER=fastest)" "no request sent"
assert_contains "$(cat "$RTMP/c4/err")" "not price/throughput/latency" "the lane says why"

# Bug caught: OpenRouter's routing field sent to the BytePlus plan, which does not know it.
start_test "rr.5 a plan lane's request carries no provider object"
assert_eq '"none"' "$(run_r c5 byteplus-alt)" "byteplus-alt on the plan"

# Bug caught: the answering endpoint invisible, so a slow or failing provider cannot be told from the model.
start_test "rr.6 the endpoint that answered is named on stderr"
run_r c6 openrouter >/dev/null
assert_contains "$(cat "$RTMP/c6/err")" "Done: openrouter (answered by provider DeepInfra)" "named"

# Bug caught: openrouter-mini left at minimax's default `max` effort (~17k reasoning tokens a review, 10x mimo's cost),
# or the cap leaking onto a lane whose model was never measured with it.
start_test "rr.9 openrouter-mini asks minimax for xhigh reasoning; other lanes send none"
run_r c9 openrouter-mini >/dev/null
assert_eq '{"effort":"xhigh"}' "$(jq -c '.reasoning // "none"' "$RTMP/c9/bodies.jsonl")" "minimax one level below max"
run_r c9b openrouter-alt >/dev/null
assert_eq '"none"' "$(jq -c '.reasoning // "none"' "$RTMP/c9b/bodies.jsonl")" "mimo keeps its own default"
run_r c9c byteplus-alt >/dev/null
assert_eq '"none"' "$(jq -c '.reasoning // "none"' "$RTMP/c9c/bodies.jsonl")" "the plan gets no OpenRouter field"

# Bug caught: no way to move the effort back (or off) for one lane without a release, or a typo sent as the effort.
start_test "rr.10 ZUVO_OR_REASONING_<LANE> sets or empties the effort; a malformed one sends nothing"
run_r c10 openrouter-mini ZUVO_OR_REASONING_OPENROUTER_MINI=high >/dev/null
assert_eq '{"effort":"high"}' "$(jq -c '.reasoning // "none"' "$RTMP/c10/bodies.jsonl")" "set"
run_r c10b openrouter-mini ZUVO_OR_REASONING_OPENROUTER_MINI= >/dev/null
assert_eq '"none"' "$(jq -c '.reasoning // "none"' "$RTMP/c10b/bodies.jsonl")" "emptied: the model's default"
assert_eq "" "$(run_r c10c openrouter-mini ZUVO_OR_REASONING_OPENROUTER_MINI=hihg)" "no request sent"
assert_contains "$(cat "$RTMP/c10c/err")" "not max/xhigh/high/medium/low/minimal/none" "the lane says why"
