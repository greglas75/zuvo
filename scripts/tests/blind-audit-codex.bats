#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../blind-audit-codex.sh"

setup() {
  TMPDIR_TEST=$(mktemp -d)
  MOCK_BIN="$TMPDIR_TEST/bin"
  mkdir -p "$MOCK_BIN"
  ORIG_PATH="$PATH"

  PROTOCOL_FILE="$TMPDIR_TEST/blind-coverage-audit.md"
  PRODUCTION_FILE="$TMPDIR_TEST/example.ts"
  TEST_FILE="$TMPDIR_TEST/example.test.ts"

  cat > "$PROTOCOL_FILE" <<'EOF'
Audit mode: strict
Coverage verdict:
INVENTORY COMPLETE:
| id | kind | production lines | owned_or_delegated | coverage | test evidence | notes |
EOF

  cat > "$PRODUCTION_FILE" <<'EOF'
export function add(a, b) {
  return a + b;
}
EOF

  cat > "$TEST_FILE" <<'EOF'
it('adds numbers', () => {
  expect(add(1, 2)).toBe(3);
});
EOF
}

teardown() {
  export PATH="$ORIG_PATH"
  rm -rf "$TMPDIR_TEST"
}

isolated_path() {
  # Isolated PATH: mocks + system essentials ONLY.
  #
  # /opt/homebrew/bin used to be appended here for `timeout` (macOS ships none),
  # and that quietly un-isolated the whole suite: the REAL codex lives there, the
  # script picks the first available client rather than one named by the *_MODEL
  # env var, so every test that mocks a NON-codex provider ran the real codex
  # instead and failed with its account error. Invisible until 2026-08-10, when
  # installing bats stopped the runner from skipping this group entirely.
  #
  # Fix: shim the few real binaries we need INTO the mock dir, so the mock dir can
  # be the only non-system entry. A tool that is genuinely absent stays absent —
  # the script's own no-timeout fallback covers it.
  local _real
  for _real in timeout gtimeout jq; do
    if [ ! -e "$MOCK_BIN/$_real" ]; then
      _p="$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v "$_real" 2>/dev/null || true)"
      [ -n "$_p" ] && ln -sf "$_p" "$MOCK_BIN/$_real"
    fi
  done
  export PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin"

  # Neutralise HOST auto-exclusion. The script deliberately refuses to audit with
  # the client it is RUNNING under (CLAUDECODE=1 -> skip claude, etc.), which is
  # correct behaviour and separately tested below. Left set, it made the claude
  # case unpassable from inside Claude Code and passable elsewhere — a test whose
  # result depended on who ran it.
  unset CLAUDECODE CODEX_SANDBOX ANTIGRAVITY_SESSION_ID VSCODE_GIT_ASKPASS_MAIN
}

valid_block() {
  cat <<'EOF'
Audit mode: strict
Coverage verdict: CLEAN
INVENTORY COMPLETE: 1 rows
| id | kind | production lines | owned_or_delegated | coverage | test evidence | notes |
| 1 | branch | 1-2 | owned | FULL | example.test.ts:1 | ok |
EOF
}

create_codex_mock() {
  cat > "$MOCK_BIN/codex" <<'EOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
cat > /dev/null
cat > "$out" <<'BLOCK'
Audit mode: strict
Coverage verdict: CLEAN
INVENTORY COMPLETE: 1 rows
| id | kind | production lines | owned_or_delegated | coverage | test evidence | notes |
| 1 | branch | 1-2 | owned | FULL | example.test.ts:1 | ok |
BLOCK
EOF
  chmod +x "$MOCK_BIN/codex"
}

create_gemini_mock() {
  cat > "$MOCK_BIN/gemini" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
cat <<'BLOCK'
Audit mode: strict
Coverage verdict: CLEAN
INVENTORY COMPLETE: 1 rows
| id | kind | production lines | owned_or_delegated | coverage | test evidence | notes |
| 1 | branch | 1-2 | owned | FULL | example.test.ts:1 | ok |
BLOCK
EOF
  chmod +x "$MOCK_BIN/gemini"
}

create_claude_mock() {
  cat > "$MOCK_BIN/claude" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
cat <<'BLOCK'
Audit mode: strict
Coverage verdict: CLEAN
INVENTORY COMPLETE: 1 rows
| id | kind | production lines | owned_or_delegated | coverage | test evidence | notes |
| 1 | branch | 1-2 | owned | FULL | example.test.ts:1 | ok |
BLOCK
EOF
  chmod +x "$MOCK_BIN/claude"
}

@test "uses codex provider and accepts strict out.txt" {
  create_codex_mock
  isolated_path

  run env ZUVO_CODEX_MODEL=gpt-5.4 "$SCRIPT" \
    --protocol "$PROTOCOL_FILE" \
    --production "$PRODUCTION_FILE" \
    --test "$TEST_FILE" \
    --timeout 5

  [ "$status" -eq 0 ]
  [[ "$output" == *"Coverage verdict: CLEAN"* ]]
}

@test "uses gemini provider and accepts stdout strict block" {
  create_gemini_mock
  isolated_path

  run env GEMINI_MODEL=gemini "$SCRIPT" \
    --protocol "$PROTOCOL_FILE" \
    --production "$PRODUCTION_FILE" \
    --test "$TEST_FILE" \
    --timeout 5

  [ "$status" -eq 0 ]
  [[ "$output" == *"Coverage verdict: CLEAN"* ]]
}

@test "uses claude provider and accepts stdout strict block" {
  create_claude_mock
  isolated_path

  run env CLAUDE_MODEL=sonnet "$SCRIPT" \
    --protocol "$PROTOCOL_FILE" \
    --production "$PRODUCTION_FILE" \
    --test "$TEST_FILE" \
    --timeout 5

  [ "$status" -eq 0 ]
  [[ "$output" == *"Coverage verdict: CLEAN"* ]]
}

@test "host auto-exclusion: CLAUDECODE=1 refuses to blind-audit with claude" {
  # The behaviour the neutralisation above removes from the other cases, pinned
  # here on its own: a claude host must not review its own work, even when claude
  # is the only client available.
  create_claude_mock
  isolated_path

  run env CLAUDECODE=1 CLAUDE_MODEL=sonnet "$SCRIPT" \
    --protocol "$PROTOCOL_FILE" \
    --production "$PRODUCTION_FILE" \
    --test "$TEST_FILE" \
    --timeout 5

  [ "$status" -ne 0 ]
  # Assert the REASON, not merely a non-zero exit: any crash would satisfy the
  # exit code alone, so this must name the exclusion the test exists to prove.
  [[ "$output" == *"Host detected: claude"* ]]
  [[ "$output" == *"auto-excluding"* ]]
  [[ "$output" != *"Coverage verdict: CLEAN"* ]]
}
