#!/usr/bin/env bash
# Characterization of OpenRouter's existing response parsing and content guard.
# The fake curl returns fixture bytes; no network or paid API is used.
# Sourced by run.sh before the decoder is extracted.

ADV="$ROOT/scripts/adversarial-review.sh"
OR_HOME="$(mktemp -d "$ADV_TEST_HOME/openrouter-response.XXXXXX")"
mkdir -p "$OR_HOME/bin"
export ZUVO_HOME="$OR_HOME" OPENROUTER_API_KEY="fixture-key"
export PATH="$OR_HOME/bin:$PATH"
trap 'rm -rf "$OR_HOME"' EXIT
cat > "$OR_HOME/bin/curl" <<'EOF'
#!/usr/bin/env bash
cat "$OR_RESPONSE_FILE"
printf '\n%s' "${OR_HTTP_STATUS:-200}"
EOF
chmod +x "$OR_HOME/bin/curl"

openrouter_case() {
  OR_RESPONSE_FILE="$1" OR_HTTP_STATUS="${2:-200}" \
    bash "$ADV" --provider openrouter --single --json --files "$ADV_TEST_EMPTY" 2>"$OR_HOME/driver.err"
}

start_test "OR.1 scalar review content is returned without JSON wrapper text"
jq -n '{choices:[{message:{content:"OPENROUTER_SCALAR_REVIEW_927"}}],usage:{prompt_tokens:12,completion_tokens:34}}' > "$OR_HOME/scalar.json"
out=$(openrouter_case "$OR_HOME/scalar.json"); rc=$?
assert_exit_code "0" "$rc" "scalar review accepted"
assert_eq "OPENROUTER_SCALAR_REVIEW_927" "$(printf '%s' "$out" | jq -r '.results.openrouter')" "exact scalar review text"
start_test "OR.2 typed text blocks are concatenated and non-text blocks omitted"
jq -n '{choices:[{message:{content:[{type:"text",text:"PART_A_"},{type:"image",url:"decoy"},{type:"text",text:"PART_B"}]}}],usage:{prompt_tokens:2,completion_tokens:3}}' > "$OR_HOME/blocks.json"
out=$(openrouter_case "$OR_HOME/blocks.json"); rc=$?
assert_exit_code "0" "$rc" "typed content accepted"
assert_eq "PART_A_PART_B" "$(printf '%s' "$out" | jq -r '.results.openrouter')" "text blocks joined without image data"

start_test "OR.3 short quota content is refused as an error"
jq -n '{choices:[{message:{content:"quota reached"}}]}' > "$OR_HOME/quota.json"
out=$(openrouter_case "$OR_HOME/quota.json"); rc=$?
assert_exit_code "2" "$rc" "quota text is no review"
assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "JSON status reports no review"
assert_eq "openrouter:empty" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "quota content was excluded"
assert_contains "$(cat "$OR_HOME/driver.err")" "failed or returned empty" "the driver reports the refusal"

start_test "OR.4 a long genuine review may quote rate limit"
long_review="$(printf 'x%.0s' {1..1100}) rate limit discussed in a finding"
jq -n --arg text "$long_review" '{choices:[{message:{content:$text}}]}' > "$OR_HOME/long.json"
out=$(openrouter_case "$OR_HOME/long.json"); rc=$?
assert_exit_code "0" "$rc" "quoted phrase does not reject a long review"
assert_contains "$(printf '%s' "$out" | jq -r '.results.openrouter')" "rate limit discussed in a finding" "review content is preserved"

start_test "OR.5 long error-prefixed content is refused"
long_error="error: $(printf 'x%.0s' {1..1100})"
jq -n --arg text "$long_error" '{choices:[{message:{content:$text}}]}' > "$OR_HOME/long-error.json"
out=$(openrouter_case "$OR_HOME/long-error.json"); rc=$?
assert_exit_code "2" "$rc" "error prefix still rejects long output"
assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "JSON status reports no review"
assert_eq "openrouter:empty" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "long error content was excluded"
assert_contains "$(cat "$OR_HOME/driver.err")" "failed or returned empty" "the driver reports the refusal"
