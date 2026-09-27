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

start_test "FG.5 missing-file text inside an existing file does not make the file missing"
printf '(file not found: %s)\nexport const present = true;\n' "$FG_TMP/not-a-listed-path.ts" > "$FG_TMP/stub-content.ts"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-prompt" bash "$ADV" --single --files "$FG_TMP/stub-content.ts" 2>"$FG_TMP/err5"); rc=$?
assert_exit_code "0" "$rc" "the existing file is reviewed"
assert_contains "$out" "=== FILE: stub-content.ts ===" "the mock provider received the existing file"
assert_contains "$out" "export const present = true;" "the mock provider received the file body"
if grep -Eq '^(WARN|ERROR): .*--files path\(s\)' "$FG_TMP/err5"; then fail "file body is not counted as a missing path" "$(cat "$FG_TMP/err5")"; else pass "file body is not counted as a missing path"; fi

start_test "FG.6 file-header text inside a file does not increase the listed-path count"
printf '=== FILE: embedded-header.ts ===\nexport const present = true;\n' > "$FG_TMP/header-content.ts"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --files "$FG_TMP/header-content.ts
$FG_TMP/missing-d.ts" 2>"$FG_TMP/err6"); rc=$?
assert_exit_code "0" "$rc" "the existing file is reviewed despite the missing second path"
assert_eq "WARN: 1 of 2 --files path(s) do not exist and are NOT reviewed:" "$(grep -m1 '^WARN: ' "$FG_TMP/err6")" "only the two requested paths are counted"
if grep -Fxq "  $FG_TMP/missing-d.ts" "$FG_TMP/err6"; then pass "the truly missing path is named"; else fail "the truly missing path is named" "$(cat "$FG_TMP/err6")"; fi
assert_contains "$out" "header-content.ts" "the mock provider received the existing file"
assert_contains "$out" "embedded-header.ts" "the mock provider received the header-shaped file content"
if [[ "$out" == *"=== FILE: missing-d.ts ==="* ]]; then fail "the missing file generated no provider input"; else pass "the missing file generated no provider input"; fi

start_test "FG.7 a missing space-separated path does not swallow the valid path after it"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-prompt" bash "$ADV" --single --files "$FG_TMP/missing-space.ts $FG_TMP/real.ts" 2>"$FG_TMP/err7"); rc=$?
assert_exit_code "0" "$rc" "the valid trailing file is reviewed"
assert_contains "$(cat "$FG_TMP/err7")" "WARN: 1 of 2 --files path(s) do not exist" "one of the two requested paths is missing"
if grep -Fxq "  $FG_TMP/missing-space.ts" "$FG_TMP/err7"; then pass "the warning names the missing path"; else fail "the warning names the missing path" "$(cat "$FG_TMP/err7")"; fi
if grep -Fxq "  $FG_TMP/real.ts" "$FG_TMP/err7"; then fail "the warning does not name the valid path" "$(cat "$FG_TMP/err7")"; else pass "the warning does not name the valid path"; fi
assert_contains "$out" "=== FILE: real.ts ===" "the mock provider received the valid trailing file"
assert_contains "$out" "export const real = 1;" "the mock provider received the valid file body"
if [[ "$out" == *"=== FILE: missing-space.ts ==="* || "$out" == *"(file not found:"* ]]; then fail "the missing file generated no provider input"; else pass "the missing file generated no provider input"; fi

start_test "FG.8 a readable process-substitution path is reviewed"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-prompt" bash "$ADV" --single --files <(printf 'process-substitution-body-guard-927\n') 2>"$FG_TMP/err8"); rc=$?
assert_exit_code "0" "$rc" "the readable non-regular input is reviewed"
assert_contains "$out" "process-substitution-body-guard-927" "the mock provider received the process-substitution body"
if grep -Eq '^=== FILE: [0-9]+ ===$' <<< "$out"; then pass "the process-substitution file header is present"; else fail "the process-substitution file header is present"; fi
if [[ "$out" == *"(file not found:"* ]]; then fail "the process-substitution input is not a missing-file stub"; else pass "the process-substitution input is not a missing-file stub"; fi

start_test "FG.9 a directory is refused with an honest diagnostic"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --files "$FG_TMP" 2>"$FG_TMP/err9"); rc=$?
assert_exit_code "2" "$rc" "a directory is not reviewed"
if grep -Fxq "  $FG_TMP: directory" "$FG_TMP/err9"; then pass "the diagnostic gives the exact path and directory reason"; else fail "the diagnostic gives the exact path and directory reason" "$(cat "$FG_TMP/err9")"; fi
if grep -Eq 'none of the .* path\(s\) exist|path\(s\) do not exist' "$FG_TMP/err9"; then fail "the diagnostic does not claim the directory is missing" "$(cat "$FG_TMP/err9")"; else pass "the diagnostic does not claim the directory is missing"; fi
assert_eq "" "$out" "no provider was dispatched for the directory"

start_test "FG.10 an existing unreadable file is refused as unreadable"
printf 'unreadable-file-body-guard-927\n' > "$FG_TMP/unreadable.ts"
chmod 000 "$FG_TMP/unreadable.ts"
if [[ -r "$FG_TMP/unreadable.ts" ]]; then
  chmod 600 "$FG_TMP/unreadable.ts"
  printf '  [SKIP] %s — chmod 000 remains readable under this account\n' "$CURRENT_TEST"
else
  out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --files "$FG_TMP/unreadable.ts" 2>"$FG_TMP/err10"); rc=$?
  chmod 600 "$FG_TMP/unreadable.ts"
  assert_exit_code "2" "$rc" "the unreadable file is not reviewed"
  if grep -Fxq "  $FG_TMP/unreadable.ts: unreadable" "$FG_TMP/err10"; then pass "the diagnostic gives the exact path and unreadable reason"; else fail "the diagnostic gives the exact path and unreadable reason" "$(cat "$FG_TMP/err10")"; fi
  if grep -Eq 'none of the .* path\(s\) exist|path\(s\) do not exist' "$FG_TMP/err10"; then fail "the diagnostic does not claim the unreadable file is missing" "$(cat "$FG_TMP/err10")"; else pass "the diagnostic does not claim the unreadable file is missing"; fi
  assert_eq "" "$out" "no provider was dispatched for the unreadable file"
fi

start_test "FG.11 a three-word relative path beats real prefix decoys"
mkdir -p "$FG_TMP/longest-path"
printf 'intended-longest-body-guard-927\n' > "$FG_TMP/longest-path/alpha beta gamma"
printf 'decoy-prefix-body-guard-927\n' > "$FG_TMP/longest-path/alpha"
printf 'decoy-middle-body-guard-927\n' > "$FG_TMP/longest-path/beta"
out=$(cd "$FG_TMP/longest-path" && ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-prompt" bash "$ADV" --single --files 'alpha beta gamma' 2>"$FG_TMP/err11"); rc=$?
assert_exit_code "0" "$rc" "the intended three-word file is reviewed"
assert_contains "$out" "intended-longest-body-guard-927" "the mock provider received the longest path's body"
if [[ "$out" == *"decoy-middle-body-guard-927"* ]]; then fail "the mock provider did not receive the middle-word decoy" "the decoy body was present"; else pass "the mock provider did not receive the middle-word decoy"; fi
if [[ "$out" == *"decoy-prefix-body-guard-927"* ]]; then fail "the mock provider did not receive the prefix decoy" "the decoy body was present"; else pass "the mock provider did not receive the prefix decoy"; fi
if grep -Eq '^WARN: [0-9]+ of [0-9]+ --files path' "$FG_TMP/err11"; then fail "the existing intended path produces no missing-path warning" "$(cat "$FG_TMP/err11")"; else pass "the existing intended path produces no missing-path warning"; fi

start_test "FG.12 two missing absolute paths remain separate before a valid path"
printf 'valid-third-body-guard-927\n' > "$FG_TMP/valid-third.ts"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-prompt" bash "$ADV" --single --files "$FG_TMP/missing-first.ts $FG_TMP/missing-second.ts $FG_TMP/valid-third.ts" 2>"$FG_TMP/err12"); rc=$?
assert_exit_code "0" "$rc" "the valid third file is reviewed"
assert_contains "$(cat "$FG_TMP/err12")" "WARN: 2 of 3 --files path(s) do not exist" "two of three requested paths are missing"
if grep -Fxq "  $FG_TMP/missing-first.ts" "$FG_TMP/err12"; then pass "the first missing path has its own line"; else fail "the first missing path has its own line" "$(cat "$FG_TMP/err12")"; fi
if grep -Fxq "  $FG_TMP/missing-second.ts" "$FG_TMP/err12"; then pass "the second missing path has its own line"; else fail "the second missing path has its own line" "$(cat "$FG_TMP/err12")"; fi
assert_contains "$out" "valid-third-body-guard-927" "the mock provider received the valid third file body"
if [[ "$out" == *"=== FILE: missing-first.ts ==="* || "$out" == *"=== FILE: missing-second.ts ==="* || "$out" == *"(file not found:"* ]]; then fail "missing files generated no provider input"; else pass "missing files generated no provider input"; fi

start_test "FG.13 a directory in a mixed list is warned about and excluded from provider input"
mkdir -p "$FG_TMP/invalid-directory"
printf 'valid-only-body-guard-927\n' > "$FG_TMP/valid-only.ts"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-prompt" bash "$ADV" --single --files "$FG_TMP/invalid-directory
$FG_TMP/valid-only.ts" 2>"$FG_TMP/err13"); rc=$?
assert_exit_code "0" "$rc" "the valid file is reviewed"
assert_eq "WARN: 1 of 2 --files path(s) are not reviewable and are NOT reviewed:" "$(grep -m1 '^WARN: ' "$FG_TMP/err13")" "the mixed list warns accurately about one unusable path"
if grep -Fxq "  $FG_TMP/invalid-directory: directory" "$FG_TMP/err13"; then pass "the warning gives the exact directory reason"; else fail "the warning gives the exact directory reason" "$(cat "$FG_TMP/err13")"; fi
assert_contains "$out" "valid-only-body-guard-927" "the mock provider received the valid file body"
if [[ "$out" == *"=== FILE: invalid-directory ==="* || "$out" == *"(file not found: $FG_TMP/invalid-directory)"* ]]; then fail "the directory generated no provider input" "a directory header or missing-file stub reached the mock"; else pass "the directory generated no provider input"; fi

start_test "FG.14 a literal wildcard in a missing path is not expanded"
mkdir -p "$FG_TMP/literal-wildcard"
printf 'matched-file-body-guard-927\n' > "$FG_TMP/literal-wildcard/matched.ts"
out=$(cd "$FG_TMP/literal-wildcard" && ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --files '*.ts' 2>"$FG_TMP/err14"); rc=$?
assert_exit_code "2" "$rc" "the literal wildcard path is refused as missing"
if grep -Fxq '  *.ts: missing' "$FG_TMP/err14"; then pass "the diagnostic names the supplied wildcard literally"; else fail "the diagnostic names the supplied wildcard literally" "$(cat "$FG_TMP/err14")"; fi
assert_eq "" "$out" "the matching real file was not sent to a provider"

start_test "FG.15 a missing relative path does not consume the next relative file"
out=$(cd "$FG_TMP" && ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-prompt" bash "$ADV" --single --files 'gone-relative.ts real.ts' 2>"$FG_TMP/err15"); rc=$?
assert_exit_code "0" "$rc" "the valid relative file is reviewed"
assert_contains "$(cat "$FG_TMP/err15")" "WARN: 1 of 2 --files path(s) do not exist" "one of two relative paths is missing"
if grep -Fxq "  gone-relative.ts" "$FG_TMP/err15"; then pass "the missing relative path has its own line"; else fail "the missing relative path has its own line" "$(cat "$FG_TMP/err15")"; fi
assert_contains "$out" "export const real = 1;" "the valid relative file body reached the provider"
if [[ "$out" == *"=== FILE: gone-relative.ts ==="* || "$out" == *"(file not found:"* ]]; then fail "the missing relative path generated no provider input"; else pass "the missing relative path generated no provider input"; fi

start_test "FG.16 an unreadable path in a mixed list is named and omitted"
printf 'unreadable-mixed-body-guard-927\n' > "$FG_TMP/unreadable-mixed.ts"
chmod 000 "$FG_TMP/unreadable-mixed.ts"
if [[ -r "$FG_TMP/unreadable-mixed.ts" ]]; then
  chmod 600 "$FG_TMP/unreadable-mixed.ts"
  printf '  [SKIP] %s — chmod 000 remains readable under this account\n' "$CURRENT_TEST"
else
  out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-prompt" bash "$ADV" --single --files "$FG_TMP/unreadable-mixed.ts
$FG_TMP/real.ts" 2>"$FG_TMP/err16"); rc=$?
  chmod 600 "$FG_TMP/unreadable-mixed.ts"
  assert_exit_code "0" "$rc" "the valid file is reviewed"
  assert_eq "WARN: 1 of 2 --files path(s) are not reviewable and are NOT reviewed:" "$(grep -m1 '^WARN: ' "$FG_TMP/err16")" "the mixed warning is accurate"
  if grep -Fxq "  $FG_TMP/unreadable-mixed.ts: unreadable" "$FG_TMP/err16"; then pass "the unreadable reason is named"; else fail "the unreadable reason is named" "$(cat "$FG_TMP/err16")"; fi
  assert_contains "$out" "export const real = 1;" "the valid file body reached the provider"
  if [[ "$out" == *"=== FILE: unreadable-mixed.ts ==="* || "$out" == *"(file not found:"* ]]; then fail "the unreadable file generated no provider input"; else pass "the unreadable file generated no provider input"; fi
fi

start_test "FG.17 an absolute-looking word inside a relative path stays in that path"
mkdir -p "$FG_TMP/absolute-word/report "
printf 'absolute-word-body-guard-927\n' > "$FG_TMP/absolute-word/report / 2026.ts"
out=$(cd "$FG_TMP/absolute-word" && ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-prompt" bash "$ADV" --single --files 'report / 2026.ts' 2>"$FG_TMP/err17"); rc=$?
assert_exit_code "0" "$rc" "the spaced path with an internal slash is reviewed"
assert_contains "$out" "absolute-word-body-guard-927" "the intended file body reached the provider"
if grep -Eq '^WARN: [0-9]+ of [0-9]+ --files path' "$FG_TMP/err17"; then fail "the internal slash did not split the path" "$(cat "$FG_TMP/err17")"; else pass "the internal slash did not split the path"; fi
