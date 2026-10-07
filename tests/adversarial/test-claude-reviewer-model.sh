#!/usr/bin/env bash
# test-claude-reviewer-model.sh — which Claude reviews, by host.
#
# Until 2026-09-25 the `claude` lane chose its model from CLAUDE_MODEL alone. Nobody sets it, so all
# 850 claude-lane calls on record went to Sonnet — including reviews launched from Codex, where the
# author is GPT and the strongest reviewer measured (Opus 5.5 at effort high) is not self-review.
# Pinned here:
#   1. host = another vendor (Codex)     -> Opus 5.5, --effort high
#   2. host = Claude Code, model unknown -> Sonnet, no --effort (Opus-reviews-Opus is self-review)
#   3. CLAUDE_MODEL names Sonnet         -> Opus 5.5, --effort high
#   4. the log row names the model that actually ran
# Runs against a FAKE `claude` on PATH — nothing is sent anywhere.

ADV="$ROOT/scripts/adversarial-review.sh"
export ZUVO_ADVERSARIAL_TEST_HARNESS=1
assert_not_contains() { # local: assert.sh has the positive form only
  local haystack="$1" needle="$2" label="${3:-does not contain}"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$label"; else fail "$label" "haystack contained <$needle>"; fi
}

CTMP="$HERE/.tmp/claude-rev.$$"; mkdir -p "$CTMP/bin"
cleanup_crev() { rm -rf "$CTMP"; }
trap cleanup_crev EXIT

INPUT="$CTMP/input.py"
printf 'def f(x):\n    return x / 0\n' > "$INPUT"

# The fake records its argv twice: joined (argv) and one element per line (argv.lines). The checks below
# read single ELEMENTS — a substring of the joined line would let `--model claude-sonnet-5` match a longer
# id such as claude-sonnet-5-1. It also keeps the prompt it was given on stdin (stdin): the driver built that,
# not the fake.
cat > "$CTMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_CLAUDE_DIR/argv"
printf '%s\n' "$@" > "$FAKE_CLAUDE_DIR/argv.lines"
cat > "$FAKE_CLAUDE_DIR/stdin"
printf 'SEVERITY: WARNING\nFILE: input.py:2\nISSUE: division by zero CLAUDE-FAKE\n'
EOF
chmod +x "$CTMP/bin/claude"

run_case() { # run_case <case> <env...> -> argv the fake claude received; the driver's exit code in <case>/rc
  local c="$CTMP/$1"; shift; mkdir -p "$c"
  env -u CLAUDECODE -u CODEX_SANDBOX -u CODEX_SHELL -u CODEX_INTERNAL_ORIGINATOR_OVERRIDE \
      -u __CFBundleIdentifier -u QWEN_CODE -u CLAUDE_MODEL -u ZUVO_CLAUDE_REVIEWER_MODEL \
    "$@" PATH="$CTMP/bin:$PATH" FAKE_CLAUDE_DIR="$c" ZUVO_HOME="$c" ZUVO_PROVIDER_BENCH=0 \
    ZUVO_REVIEW_TIMEOUT=25 ZUVO_ADVERSARIAL_LOG_FILE="$c/adv.log" CODEX_MODEL=gpt-6-sol \
    bash "$ADV" --provider claude --mode code --files "$INPUT" > "$c/stdout" 2>"$c/stderr"
  echo "$?" > "$c/rc"
  cat "$c/argv" 2>/dev/null
}
# argv_after <case> <flag> -> the argv element right after <flag> ("<absent>" when <flag> is not an element).
argv_after() {
  awk -v f="$2" 'hit { print; found = 1; exit } $0 == f { hit = 1 } END { if (!found) print "<absent>" }' \
    "$CTMP/$1/argv.lines" 2>/dev/null
}
# argv_count <case> <flag> -> how many argv elements are exactly <flag>.
argv_count() { awk -v f="$2" '$0 == f { n++ } END { print n + 0 }' "$CTMP/$1/argv.lines" 2>/dev/null; }
# ran_and_answered <case> — the driver itself: exit 0, and the fake's review is what it printed. That last check
# only finds the fake's own words again, so the checks after it read what the DRIVER produced around and before
# them: the prompt it sent the lane, the header that credits the lane, and the frame the review sits in.
ran_and_answered() {
  assert_exit_code "0" "$(cat "$CTMP/$1/rc")" "the driver exits 0"
  assert_contains "$(cat "$CTMP/$1/stdout")" "division by zero CLAUDE-FAKE" "…and prints the claude lane's review"
  # ar_compose_review_prompt (adversarial-prompt.sh) + lanes.sh:206-207: the prompt ends with the input
  # section — the reviewed file under its header, byte for byte (no trailing newline: the prompt file is
  # written with printf '%s').
  assert_eq "--- CODE TO REVIEW ---|=== FILE: input.py ===|def f(x):|    return x / 0" \
    "$(tail -n 4 "$CTMP/$1/stdin" 2>/dev/null | tr '\n' '|')" "the prompt the lane got ends with the reviewed file, exactly"
  # ar_build_output (adversarial-report.sh): the text report credits the one lane that answered, and frames
  # its review.
  assert_eq "Providers: claude (1 total)|Mode: code" "$(sed -n '4,5p' "$CTMP/$1/stdout" | tr '\n' '|' | sed 's/|$//')" \
    "the report's header credits the claude lane, one in total, in code mode"
  assert_eq "SEVERITY: WARNING|FILE: input.py:2|ISSUE: division by zero CLAUDE-FAKE|===============================================================|END OF CROSS-PROVIDER REVIEW" \
    "$(sed -n '9,$p' "$CTMP/$1/stdout" | sed '$d' | tr '\n' '|' | sed 's/|$//')" \
    "the review sits whole between the header and the closing banner — nothing added, nothing lost"
}

start_test "cr.1 a Codex host gets Opus 5.5 at effort high"
out=$(run_case c1 CODEX_SANDBOX=1)
assert_contains "$out" "--model claude-opus-5-5" "Opus 5.5 reviews GPT-authored code"
assert_contains "$out" "--effort high" "at effort high"
# Exact elements (claude_reviewer_model in adversarial-providers.sh, lanes.sh:195): the model is this id, not
# one that merely starts with it.
assert_eq "claude-opus-5-5" "$(argv_after c1 --model)" "the --model element is exactly claude-opus-5-5"
assert_eq "high" "$(argv_after c1 --effort)" "the --effort element is exactly high"
assert_not_contains "$(cat "$CTMP/c1/stderr")" "no recognized Opus token" \
  "no Sonnet-default note for an Opus reviewer (claude_lane_note, lanes.sh:182)"
ran_and_answered c1

start_test "cr.2 a Claude Code host (model unknown) keeps Sonnet — no self-review"
out=$(run_case c2 CLAUDECODE=1)
assert_contains "$out" "--model claude-sonnet-5" "Sonnet reviews the assumed Opus author"
assert_eq "claude-sonnet-5" "$(argv_after c2 --model)" "the --model element is exactly claude-sonnet-5 (claude_reviewer_model)"
assert_eq "0" "$(argv_count c2 --effort)" "no --effort element at all: Sonnet runs at its default (lanes.sh:195)"
assert_not_contains "$out" "--effort" "…nor the flag anywhere in the joined argv"
# A heuristic, not proof — so the run SAYS it: on the driver's own stderr, where the user sees it (inside
# the lane it went to a captured file nobody reads when the lane succeeds).
assert_contains "$(cat "$CTMP/c2/stderr")" "CLAUDE_MODEL='unset' has no recognized Opus token" "the Sonnet default is said on the driver's stderr"
# The whole line, once (claude_lane_note, lanes.sh:182-183 — called as the lane starts, in ar_dispatch_lanes):
# what it assumes, what it does, and how to make the check cross-model.
assert_eq "1" "$(grep -cFx "  NOTE: CLAUDE_MODEL='unset' has no recognized Opus token — assuming Opus author, reviewing with Sonnet. Export CLAUDE_MODEL=<host-model> to guarantee a cross-model check (a Sonnet author here would be Sonnet-reviews-Sonnet)." "$CTMP/c2/stderr")" \
  "…exactly that note, exactly once"
ran_and_answered c2

start_test "cr.3 an explicit Sonnet author gets Opus 5.5"
out=$(run_case c3 CLAUDECODE=1 CLAUDE_MODEL=claude-sonnet-5)
assert_contains "$out" "--model claude-opus-5-5" "Opus reviews Sonnet-authored code"
assert_eq "claude-opus-5-5" "$(argv_after c3 --model)" "the --model element is exactly claude-opus-5-5"
assert_eq "high" "$(argv_after c3 --effort)" "…at effort high: the Opus reviewer's effort holds for a Sonnet author too"
assert_not_contains "$(cat "$CTMP/c3/stderr")" "no recognized Opus token" "a named Sonnet author draws no Sonnet-default note"
ran_and_answered c3

start_test "cr.4 the log row names the model that ran"
# Its own run, so the case runs alone. The columns are found by NAME in the
# header the driver writes as the log's first line (LOG_HEADER, ledger.sh:270-273) — not as fixed numbers.
run_case c4 CODEX_SANDBOX=1 >/dev/null
assert_exit_code "0" "$(cat "$CTMP/c4/rc")" "premise: the run completed"
cr4_cols=$(head -1 "$CTMP/c4/adv.log" 2>/dev/null | awk -F'\t' '{
  for (i = 1; i <= NF; i++) { if ($i == "model") m = i; if ($i == "provider") p = i; if ($i == "outcome") o = i }
  print m + 0, p + 0, o + 0 }')
read -r cr4_m cr4_p cr4_o <<< "$cr4_cols"
if [[ "$cr4_m" -gt 0 && "$cr4_p" -gt 0 && "$cr4_o" -gt 0 ]]; then
  pass "premise: the log's header names its model, provider and outcome columns"
else
  fail "premise: the log's header names its model, provider and outcome columns" "header: $(head -1 "$CTMP/c4/adv.log" 2>/dev/null)"
fi
row=$(awk -F'\t' -v m="$cr4_m" -v p="$cr4_p" -v o="$cr4_o" 'NR > 1 && $p == "claude" { r = $m " " $o } END { print r }' "$CTMP/c4/adv.log" 2>/dev/null)
assert_eq "claude-opus-5-5 ok" "$row" "ledger model column matches the reviewer, and the lane's outcome is ok"
