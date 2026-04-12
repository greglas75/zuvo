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
  export PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
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
