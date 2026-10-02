#!/usr/bin/env bash
# test-review-access.sh — ZUVO_REVIEW_ACCESS, and the model each lane reports in --json.
#
# A review lane runs its client with `--access agent` by default: the reviewer may open the repo to
# check a finding. In CI the repo IS the code under review, and an agent prompt-injected by that
# code could edit it before the verdict is computed — rdesigner's ai-review step needs the reviewer
# held back. Pinned here, on the claude lane (the codex lane takes the same review_access call):
#   1. unset          -> agent (unchanged default: --dangerously-skip-permissions)
#   2. read           -> Read/Grep/Glob over the repo root, no skip-permissions
#   3. none           -> no tools at all
#   4. an unknown value -> read (whoever set it wanted the reviewer held back)
#   5. --json reports the model each answering lane ran and the access it had — a caller that
#      pinned a model can check it was honoured (rdesigner's claude lane ran Sonnet for a day while
#      its config said Opus, because the pin it used was not the one this host branch reads).
# Runs against a FAKE `claude` on PATH — nothing is sent anywhere.

ADV="$ROOT/scripts/adversarial-review.sh"
assert_not_contains() { # local: assert.sh has the positive form only
  local haystack="$1" needle="$2" label="${3:-does not contain}"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$label"; else fail "$label" "haystack contained <$needle>"; fi
}
export ZUVO_ADVERSARIAL_TEST_HARNESS=1

RTMP="$HERE/.tmp/review-access.$$"; mkdir -p "$RTMP/bin" "$RTMP/repo"
cleanup_ra() { rm -rf "$RTMP"; }
trap cleanup_ra EXIT
git -C "$RTMP/repo" init -q
REPO=$(cd "$RTMP/repo" && pwd -P)

INPUT="$RTMP/repo/input.py"
printf 'def f(x):\n    return x / 0\n' > "$INPUT"

cat > "$RTMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_CLAUDE_DIR/argv"
cat > /dev/null
printf 'SEVERITY: WARNING\nFILE: input.py:2\nISSUE: division by zero CLAUDE-FAKE\n'
EOF
chmod +x "$RTMP/bin/claude"

run_case() { # run_case <case> [--json] <env...> -> argv the fake claude received; stdout kept in <case>/stdout
  local c="$RTMP/$1" json=""; shift; mkdir -p "$c"
  if [ "${1:-}" = "--json" ]; then json="--json"; shift; fi
  ( cd "$RTMP/repo" && env -u CLAUDECODE -u CODEX_SANDBOX -u CODEX_SHELL -u CODEX_INTERNAL_ORIGINATOR_OVERRIDE \
      -u __CFBundleIdentifier -u QWEN_CODE -u CLAUDE_MODEL -u ZUVO_CLAUDE_REVIEWER_MODEL -u ZUVO_REVIEW_ACCESS \
      "$@" PATH="$RTMP/bin:$PATH" FAKE_CLAUDE_DIR="$c" ZUVO_HOME="$c" ZUVO_PROVIDER_BENCH=0 \
      ZUVO_REVIEW_TIMEOUT=25 ZUVO_ADVERSARIAL_LOG_FILE="$c/adv.log" \
      bash "$ADV" --provider claude --mode code $json --files "$INPUT" > "$c/stdout" 2>"$c/stderr" )
  cat "$c/argv" 2>/dev/null
}

start_test "ra.1 unset keeps the agent default"
out=$(run_case a1)
assert_contains "$out" "--dangerously-skip-permissions" "agent access, as before"

start_test "ra.2 read: Read/Grep/Glob over the repo root, nothing written"
out=$(run_case a2 ZUVO_REVIEW_ACCESS=read)
assert_contains "$out" "--tools Read,Grep,Glob" "read-only tools"
assert_contains "$out" "--add-dir $REPO" "rooted at the repository the review runs in"
assert_not_contains "$out" "--dangerously-skip-permissions" "no skip-permissions"

start_test "ra.3 none: no tools"
out=$(run_case a3 ZUVO_REVIEW_ACCESS=none)
assert_contains "$out" "--safe-mode" "the isolated client"
assert_not_contains "$out" "--dangerously-skip-permissions" "no skip-permissions"
assert_not_contains "$out" "Read,Grep,Glob" "and no read tools either"

start_test "ra.4 an unknown value is read, not agent"
out=$(run_case a4 ZUVO_REVIEW_ACCESS=readonly)
assert_contains "$out" "--tools Read,Grep,Glob" "held back"
assert_not_contains "$out" "--dangerously-skip-permissions" "never the permissive default"

start_test "ra.5 --json names each lane's model and the access it had"
out=$(run_case a5 --json ZUVO_REVIEW_ACCESS=read ZUVO_CLAUDE_REVIEWER_MODEL=claude-opus-5-5 ZUVO_CLAUDE_REVIEWER_OPUS_EFFORT=medium)
assert_contains "$out" "--model claude-opus-5-5" "the pinned model ran"
assert_contains "$out" "--effort medium" "at the pinned effort"
assert_eq "claude-opus-5-5" "$(jq -r '.models.claude // empty' "$RTMP/a5/stdout")" "models.claude reports it"
assert_eq "read" "$(jq -r '.review_access // empty' "$RTMP/a5/stdout")" "review_access reports the access"
