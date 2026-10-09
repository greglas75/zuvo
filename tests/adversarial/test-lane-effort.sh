#!/usr/bin/env bash
# test-lane-effort.sh — record_lane_effort / provider_effort, the source of adversarial.log's effort column.
#
# Small tests: the providers module sourced alone, a temp JSON_TMPDIR, no driver run and no client. The lanes
# that write the file are pinned against real (fake-client) runs in test-codex-lane-defaults (cx.12-13),
# test-claude-reviewer-model (cr.5), test-kimi-effort and test-agy-quota-fallback; this file covers the helper's
# own branches, which those runs reach only partly:
#   * an empty effort REMOVES the file — kimi's API fallback relies on it, or the row keeps the CLI's effort;
#   * no JSON_TMPDIR (a row written before a lane ran) is an empty effort, not an error;
#   * agy's effort is the "(Low|Medium|High)" suffix of the model it tried (effort_in_model_name), and no
#     recorded attempt is no effort, whatever model is configured;
#   * values are lowercased, and one that is then not [a-z][a-z0-9_-]{0,15} is "?", so it can never put a tab
#     or newline into the TSV;
#   * a record with no lane name writes nothing.

. "$ROOT/tests/lib/adversarial-driver.sh"
LE_MODDIR="$(adv_driver_module_dir "$ROOT/scripts/adversarial-review.sh")"
LETMP="$HERE/.tmp/lane-effort.$$"; mkdir -p "$LETMP/run"
cleanup_le() { rm -rf "$LETMP"; }
trap cleanup_le EXIT

# eff <shell snippet> — runs the snippet with the providers module loaded and JSON_TMPDIR=$LETMP/run; prints its
# stdout. A fresh bash each time: no state crosses cases except the files the case itself left in $LETMP/run.
eff() {
  env -u ZUVO_AGY_MODEL -u ZUVO_MODEL_AGY JSON_TMPDIR="$LETMP/run" bash -c '
    . "$1/adversarial-providers.sh" || { echo "<module did not load>"; exit 9; }
    eval "$2"' _ "$LE_MODDIR" "$1" 2>/dev/null
}

start_test "le.1 a recorded effort is what provider_effort returns"
rm -f "$LETMP/run"/effort-*
assert_eq "medium" "$(eff 'record_lane_effort codex-5.4 medium; provider_effort codex-5.4')" "codex-5.4: medium"
assert_eq "medium" "$(cat "$LETMP/run/effort-codex-5.4" 2>/dev/null)" "…kept in the lane's own file, effort-codex-5.4"
assert_eq "" "$(eff 'provider_effort codex-5.3')" "another lane is unaffected: codex-5.3 recorded nothing, so empty"

start_test "le.2 recording an empty effort removes the lane's earlier value"
eff 'record_lane_effort kimi high' > /dev/null
assert_eq "high" "$(eff 'provider_effort kimi')" "premise: kimi recorded high (the CLI attempt)"
eff 'record_lane_effort kimi ""' > /dev/null
assert_eq "" "$(eff 'provider_effort kimi')" "after an empty record (the kimi-api fallback): empty, not high"
assert_eq "absent" "$([ -e "$LETMP/run/effort-kimi" ] && echo present || echo absent)" "…and the file is gone"

start_test "le.3 without JSON_TMPDIR nothing is written and the effort is empty"
out=$(cd "$LETMP" && env -u JSON_TMPDIR bash -c '. "$1/adversarial-providers.sh" || exit 9; record_lane_effort claude high; echo "rc=$?"; echo "[$(provider_effort claude)]"' _ "$LE_MODDIR" 2>&1)
assert_eq "rc=0|[]" "$(printf '%s' "$out" | tr '\n' '|')" "record returns 0, provider_effort prints an empty line"
assert_eq "" "$(find "$LETMP" -name 'effort-claude' 2>/dev/null)" "…and no effort-claude file was written anywhere (cwd included)"

start_test "le.4 agy: the level an agy model name ends with"
assert_eq "Medium" "$(eff 'effort_in_model_name "Gemini 3.8 Flash (Medium)"')" "the lane default's level: Medium"
assert_eq "High" "$(eff 'effort_in_model_name "Gemini 3.8 Flash (High)"')" "(High): High"
assert_eq "Low" "$(eff 'effort_in_model_name "Claude Sonnet 5.5 (Low)"')" "(Low): Low"
assert_eq "" "$(eff 'effort_in_model_name "Mock Fallback (Test)"')" "a suffix that is no level: nothing"
assert_eq "" "$(eff 'effort_in_model_name "Gemini (High) Flash"')" "the level must END the name: (High) mid-name is nothing"
assert_eq "rc=0" "$(eff 'effort_in_model_name "no level"; echo "rc=$?"')" "no level is not an error (status 0 under set -e)"
rm -f "$LETMP/run"/effort-*
assert_eq "medium" "$(eff 'record_lane_effort agy "$(effort_in_model_name "Gemini 3.8 Flash (Medium)")"; provider_effort agy')" \
  "recorded the way run_agy does, then read like any lane: medium (lowercased)"
rm -f "$LETMP/run/effort-agy"
assert_eq "" "$(eff 'ZUVO_AGY_MODEL="Gemini 3.8 Flash (High)"; provider_effort agy')" \
  "nothing recorded (agy did not run): empty, whatever model is configured"

start_test "le.5 a value that is not one lowercase word is ?"
printf 'high\tx' > "$LETMP/run/effort-codex-5.3"
assert_eq "?" "$(eff 'provider_effort codex-5.3')" "a tab inside: ?"
printf 'HIGH' > "$LETMP/run/effort-codex-5.3"
assert_eq "high" "$(eff 'provider_effort codex-5.3')" "upper case: lowercased to high, not ?"
printf 'very high' > "$LETMP/run/effort-codex-5.3"
assert_eq "?" "$(eff 'provider_effort codex-5.3')" "a space inside: ?"
printf 'abcdefghijklmnopq' > "$LETMP/run/effort-codex-5.3"
assert_eq "?" "$(eff 'provider_effort codex-5.3')" "17 characters (over the 16 the column takes): ?"
printf 'abcdefghijklmnop' > "$LETMP/run/effort-codex-5.3"
assert_eq "abcdefghijklmnop" "$(eff 'provider_effort codex-5.3')" "exactly 16: kept"
printf 'a\nb' > "$LETMP/run/effort-codex-5.3"
assert_eq "?" "$(eff 'provider_effort codex-5.3')" "a newline inside: ?"
printf '1high' > "$LETMP/run/effort-codex-5.3"
assert_eq "?" "$(eff 'provider_effort codex-5.3')" "a leading digit: ?"
printf -- '-x' > "$LETMP/run/effort-codex-5.3"
assert_eq "?" "$(eff 'provider_effort codex-5.3')" "a leading hyphen: ?"
: > "$LETMP/run/effort-codex-5.3"
assert_eq "" "$(eff 'provider_effort codex-5.3')" "an empty file: empty, not ?"
printf 'x-high_2' > "$LETMP/run/effort-codex-5.3"
assert_eq "x-high_2" "$(eff 'provider_effort codex-5.3')" "digits, - and _ after the first letter: kept"

start_test "le.6 a record with no lane name writes nothing"
rm -f "$LETMP/run"/effort*
assert_eq "rc=0" "$(eff 'record_lane_effort "" high; echo "rc=$?"')" "returns 0"
assert_eq "" "$(ls "$LETMP/run" | grep '^effort' )" "no effort file at all (not one named effort-)"
assert_eq "high" "$(eff 'record_lane_effort claude high; provider_effort claude')" "control: a named lane still records"
