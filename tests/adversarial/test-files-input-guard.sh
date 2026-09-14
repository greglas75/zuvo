# test-files-input-guard.sh — --files input whose listed paths do not exist.
#
# The regression under contract (2026-09-12): a file list that did not expand in zsh
# (zsh does not word-split $VAR) reached adversarial-review as paths that resolved to
# nothing. Every listed file became a "(file not found)" stub, a ~750-char input went
# to five providers, and the pass exited 0 with findings the providers produced by
# exploring the repo on their own — it read as a real review of the range.
# Sourced by run.sh.

ADV="$ROOT/scripts/adversarial-review.sh"
MOCKS="$HERE/mocks"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$MOCKS:$PATH"
export ZUVO_HOME="$ADV_TEST_HOME/zuvo-home"
mkdir -p "$ZUVO_HOME"

FG_TMP="$ADV_TEST_HOME/files-guard"
rm -rf "$FG_TMP"; mkdir -p "$FG_TMP"
printf 'export const real = 1;\n' > "$FG_TMP/real.ts"

start_test "FG.1 --files where no listed path exists → exit 2 before any provider runs"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --files "$FG_TMP/missing-a.ts
$FG_TMP/missing-b.ts" 2>"$FG_TMP/err1"); rc=$?
assert_exit_code "2" "$rc" "refused with exit 2"
assert_contains "$(cat "$FG_TMP/err1")" "none of the 2 --files path(s) exist" "the error names how many paths were missing"
assert_eq "" "$out" "no provider was dispatched"

start_test "FG.2 some --files paths missing → reviewed, with a WARN naming the missing ones"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --files "$FG_TMP/real.ts
$FG_TMP/missing-c.ts" 2>"$FG_TMP/err2"); rc=$?
assert_exit_code "0" "$rc" "the existing file is still reviewed"
assert_contains "$(cat "$FG_TMP/err2")" "WARN: 1 of 2 --files path(s) do not exist" "the partial miss is reported"
assert_contains "$(cat "$FG_TMP/err2")" "$FG_TMP/missing-c.ts" "the missing path is named"
assert_contains "$out" "real.ts" "the provider saw the existing file"

start_test "FG.3 every --files path exists → no WARN"
ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --files "$FG_TMP/real.ts" >/dev/null 2>"$FG_TMP/err3"; rc=$?
assert_exit_code "0" "$rc" "reviewed"
if grep -q 'do not exist' "$FG_TMP/err3"; then fail "no missing-file WARN" "$(cat "$FG_TMP/err3")"; else pass "no missing-file WARN"; fi

start_test "FG.4 whitespace-only piped input → exit 2 (no input)"
printf '  \n\n\t\n' | ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single >/dev/null 2>"$FG_TMP/err4"; rc=$?
assert_exit_code "2" "$rc" "refused with exit 2"
assert_contains "$(cat "$FG_TMP/err4")" "No input provided" "reported as no input"
