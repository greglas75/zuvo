#!/usr/bin/env bash
# Regression assertions added after the OpenRouter decoder was extracted.
# The fake curl returns fixture bytes; no network or paid API is used.
# Exercises the extracted decoder through the real driver.

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

start_test "OR.6 missing review content is refused"
jq -n '{choices:[{message:{content:null}}]}' > "$OR_HOME/missing.json"
out=$(openrouter_case "$OR_HOME/missing.json"); rc=$?
assert_exit_code "2" "$rc" "null content is no review"
assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "JSON status reports no review"
assert_eq "openrouter:empty" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "null content was excluded"
assert_contains "$(cat "$OR_HOME/driver.err")" "failed or returned empty" "the driver reports the refusal"

start_test "OR.7 malformed JSON is refused"
printf '%s\n' '{"choices":[' > "$OR_HOME/malformed.json"
out=$(openrouter_case "$OR_HOME/malformed.json"); rc=$?
assert_exit_code "2" "$rc" "malformed response is no review"
assert_eq "openrouter:empty" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "malformed content was excluded"

start_test "OR.8 an array without text blocks is refused"
jq -n '{choices:[{message:{content:[{type:"image",url:"decoy"}]}}]}' > "$OR_HOME/nontext.json"
out=$(openrouter_case "$OR_HOME/nontext.json"); rc=$?
assert_exit_code "2" "$rc" "unsupported blocks are no review"
assert_eq "openrouter:empty" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "non-text content was excluded"

for shape in string array; do
  start_test "OR.10 empty $shape content is refused"
  if [[ "$shape" == string ]]; then
    jq -n '{choices:[{message:{content:""}}]}' > "$OR_HOME/empty.json"
  else
    jq -n '{choices:[{message:{content:[]}}]}' > "$OR_HOME/empty.json"
  fi
  out=$(openrouter_case "$OR_HOME/empty.json"); rc=$?
  assert_exit_code "2" "$rc" "empty $shape is no review"
  assert_eq "openrouter:empty" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "empty $shape was excluded"
done

for refusal in 'error: upstream refused' 'rate limit reached' 'insufficient credits' 'not authenticated'; do
  start_test "OR.9 short refusal is excluded: $refusal"
  jq -n --arg text "$refusal" '{choices:[{message:{content:$text}}]}' > "$OR_HOME/refusal.json"
  out=$(openrouter_case "$OR_HOME/refusal.json"); rc=$?
  assert_exit_code "2" "$rc" "short refusal is no review"
  assert_eq "openrouter:empty" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "refusal content was excluded"
done
