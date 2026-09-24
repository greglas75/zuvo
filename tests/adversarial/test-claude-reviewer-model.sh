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

CTMP="$HERE/.tmp/claude-rev.$$"; mkdir -p "$CTMP/bin"
cleanup_crev() { rm -rf "$CTMP"; }
trap cleanup_crev EXIT

INPUT="$CTMP/input.py"
printf 'def f(x):\n    return x / 0\n' > "$INPUT"

cat > "$CTMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_CLAUDE_DIR/argv"
cat > /dev/null
printf 'SEVERITY: WARNING\nFILE: input.py:2\nISSUE: division by zero CLAUDE-FAKE\n'
EOF
chmod +x "$CTMP/bin/claude"

run_case() { # run_case <case> <env...> -> argv the fake claude received
  local c="$CTMP/$1"; shift; mkdir -p "$c"
  env -u CLAUDECODE -u CODEX_SANDBOX -u CODEX_SHELL -u CODEX_INTERNAL_ORIGINATOR_OVERRIDE \
      -u __CFBundleIdentifier -u QWEN_CODE -u CLAUDE_MODEL -u ZUVO_CLAUDE_REVIEWER_MODEL \
    "$@" PATH="$CTMP/bin:$PATH" FAKE_CLAUDE_DIR="$c" ZUVO_HOME="$c" ZUVO_PROVIDER_BENCH=0 \
    ZUVO_REVIEW_TIMEOUT=25 ZUVO_ADVERSARIAL_LOG_FILE="$c/adv.log" CODEX_MODEL=gpt-6-sol \
    bash "$ADV" --provider claude --mode code --files "$INPUT" > "$c/stdout" 2>"$c/stderr"
  cat "$c/argv" 2>/dev/null
}

start_test "cr.1 a Codex host gets Opus 5.5 at effort high"
out=$(run_case c1 CODEX_SANDBOX=1)
assert_contains "$out" "--model claude-opus-5-5" "Opus 5.5 reviews GPT-authored code"
assert_contains "$out" "--effort high" "at effort high"

start_test "cr.2 a Claude Code host (model unknown) keeps Sonnet — no self-review"
out=$(run_case c2 CLAUDECODE=1)
assert_contains "$out" "--model claude-sonnet-5" "Sonnet reviews the assumed Opus author"
case "$out" in
  *--effort*) assert_eq "no effort flag" "effort flag" "Sonnet runs at its default effort" ;;
  *)          assert_eq "ok" "ok" "no effort flag for Sonnet" ;;
esac

start_test "cr.3 an explicit Sonnet author gets Opus 5.5"
out=$(run_case c3 CLAUDECODE=1 CLAUDE_MODEL=claude-sonnet-5)
assert_contains "$out" "--model claude-opus-5-5" "Opus reviews Sonnet-authored code"

start_test "cr.4 the log row names the model that ran"
row=$(awk -F'\t' 'NF>=14 && $14=="claude"{print $4}' "$CTMP/c1/adv.log" | tail -1)
assert_eq "claude-opus-5-5" "$row" "ledger model column matches the reviewer"
