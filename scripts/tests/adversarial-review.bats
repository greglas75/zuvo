#!/usr/bin/env bats
# Tests for adversarial-review.sh
#
# Run: bats scripts/tests/adversarial-review.bats
# Requires: bats-core (brew install bats-core)
#
# Strategy: Most tests use --provider to force a single mock provider and
# bypass detect_providers entirely. This avoids hangs from real CLIs
# (Codex.app, agent, ollama) being detected on the test machine.
# Provider-detection tests use an isolated PATH with all providers mocked.

SCRIPT="$BATS_TEST_DIRNAME/../adversarial-review.sh"

# ─── Setup / teardown ─────────────────────────────────────────

setup() {
  TMPDIR_TEST=$(mktemp -d)
  MOCK_BIN="$TMPDIR_TEST/bin"
  mkdir -p "$MOCK_BIN"
  ORIG_PATH="$PATH"

  # Sample diff content (TypeScript, small)
  SAMPLE_DIFF="diff --git a/src/auth.ts b/src/auth.ts
--- a/src/auth.ts
+++ b/src/auth.ts
@@ -10,3 +10,5 @@
 export function checkToken(token: string) {
   if (!token) return false;
+  if (token.length < 8) return false;
+  return jwt.verify(token, SECRET);
 }"

  SAMPLE_FILE="$TMPDIR_TEST/sample.ts"
  echo 'export function greet(name: string) { return "hello"; }' > "$SAMPLE_FILE"
}

teardown() {
  export PATH="$ORIG_PATH"
  rm -rf "$TMPDIR_TEST"
}

# ─── Helpers ──────────────────────────────────────────────────

# Create a mock provider that outputs a fixed string.
# Codex mocks reject "mcp-server" subcommand to avoid MCP mode detection.
create_mock() {
  local name="$1"
  local output="$2"
  cat > "$MOCK_BIN/$name" <<EOF
#!/usr/bin/env bash
# Reject MCP server probe (detect_providers calls "codex mcp-server --help")
[[ "\$1" == "mcp-server" ]] && exit 1
cat > /dev/null 2>&1 || true
printf '%s\n' '$output'
EOF
  chmod +x "$MOCK_BIN/$name"
}

# Create a mock provider that inspects its stdin and responds conditionally.
create_inspecting_mock() {
  local name="$1"
  local grep_pattern="$2"
  local if_match="$3"
  local if_no_match="$4"
  cat > "$MOCK_BIN/$name" <<EOF
#!/usr/bin/env bash
[[ "\$1" == "mcp-server" ]] && exit 1
input=\$(cat 2>/dev/null || true)
if echo "\$input" | grep -q '$grep_pattern'; then
  echo '$if_match'
else
  echo '$if_no_match'
fi
EOF
  chmod +x "$MOCK_BIN/$name"
}

# Create a mock that exits non-zero (provider failure).
create_failing_mock() {
  local name="$1"
  cat > "$MOCK_BIN/$name" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null 2>&1 || true
exit 1
EOF
  chmod +x "$MOCK_BIN/$name"
}

# Set isolated PATH: mock bin + system essentials only.
# No /opt/homebrew/bin (ollama), ~/.local/bin (agent), etc.
isolated_path() {
  export PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
}

# ─── Help & usage ─────────────────────────────────────────────

@test "--help prints usage and exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: adversarial-review.sh"* ]]
  [[ "$output" == *"--provider"* ]]
  [[ "$output" == *"--mode"* ]]
  [[ "$output" == *"--json"* ]]
}

@test "-h prints usage and exits 0" {
  run "$SCRIPT" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "unknown flag exits 2 with error message" {
  run "$SCRIPT" --bogus-flag
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown argument: --bogus-flag"* ]]
}

# ─── Input modes ──────────────────────────────────────────────

@test "reads diff from stdin" {
  create_mock "gemini" "STDIN_RECEIVED"
  isolated_path

  run bash -c "echo 'some diff content here' | '$SCRIPT' --provider gemini"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STDIN_RECEIVED"* ]]
}

@test "reads files via --files flag" {
  create_mock "gemini" "FILES_RECEIVED"
  isolated_path

  run "$SCRIPT" --provider gemini --files "$SAMPLE_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FILES_RECEIVED"* ]]
}

@test "handles missing file in --files gracefully" {
  create_mock "gemini" "MISSING_OK"
  isolated_path

  run "$SCRIPT" --provider gemini --files "$TMPDIR_TEST/nonexistent.ts"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MISSING_OK"* ]]
}

@test "exits 2 when stdin is empty and no --files/--diff" {
  create_mock "gemini" "unused"
  isolated_path

  run bash -c "echo '' | '$SCRIPT' --provider gemini"
  [ "$status" -eq 2 ]
  [[ "$output" == *"No input provided"* ]]
}

# ─── Input truncation ────────────────────────────────────────

@test "truncates input exceeding 15000 chars and adds notice" {
  create_inspecting_mock "gemini" "TRUNCATED" "WAS_TRUNCATED" "NOT_TRUNCATED"
  isolated_path

  # Generate 20000 chars
  local big_input
  big_input=$(printf '%0.sx' $(seq 1 20000))

  run bash -c "printf '%s' '$big_input' | '$SCRIPT' --provider gemini"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WAS_TRUNCATED"* ]]
}

@test "preserves input under 15000 chars without truncation" {
  create_inspecting_mock "gemini" "TRUNCATED" "WAS_TRUNCATED" "NOT_TRUNCATED"
  isolated_path

  run bash -c "echo 'short input' | '$SCRIPT' --provider gemini"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT_TRUNCATED"* ]]
}

# ─── Language detection ──────────────────────────────────────

@test "detects TypeScript from .ts extension in diff" {
  create_inspecting_mock "gemini" "TypeScript" "LANG:TypeScript" "LANG:none"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider gemini"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LANG:TypeScript"* ]]
}

@test "detects Python from .py extension" {
  create_inspecting_mock "gemini" "Python" "LANG:Python" "LANG:none"
  isolated_path

  local py_diff="diff --git a/main.py b/main.py
+def hello(): pass"

  run bash -c "echo '$py_diff' | '$SCRIPT' --provider gemini"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LANG:Python"* ]]
}

@test "no language hint for plain text input" {
  create_inspecting_mock "gemini" "written in" "LANG:detected" "LANG:none"
  isolated_path

  run bash -c "echo 'just plain text no extensions' | '$SCRIPT' --provider gemini"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LANG:none"* ]]
}

# ─── Review mode selection ────────────────────────────────────

@test "defaults to code review focus" {
  create_inspecting_mock "gemini" "Edge cases the author" "MODE:code" "MODE:other"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider gemini"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MODE:code"* ]]
}

@test "--mode test selects test-specific focus" {
  create_inspecting_mock "gemini" "TEST-SPECIFIC" "MODE:test" "MODE:other"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider gemini --mode test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MODE:test"* ]]
}

@test "--mode security selects security focus" {
  create_inspecting_mock "gemini" "SECURITY ISSUES" "MODE:security" "MODE:other"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider gemini --mode security"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MODE:security"* ]]
}

# ─── Provider detection ───────────────────────────────────────

@test "exits 1 when no providers available" {
  # Codex.app at hardcoded path bypasses PATH — skip if installed
  if [[ -x "/Applications/Codex.app/Contents/Resources/codex" ]]; then
    skip "Codex.app installed at hardcoded path — cannot isolate"
  fi
  # Empty mock bin, minimal PATH — no providers detectable
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No cross-provider review tool found"* ]]
}

@test "detects gemini when command exists" {
  create_mock "gemini" "GEMINI_DETECTED"
  isolated_path

  # Use --single to avoid running other detected providers
  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --single"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GEMINI_DETECTED"* ]]
}

@test "detects codex when command exists" {
  create_mock "codex" "CODEX_DETECTED"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --single"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CODEX_DETECTED"* ]]
}

@test "detects multiple providers and runs all in multi mode" {
  create_mock "gemini" "GEMINI_MULTI"
  create_mock "codex" "CODEX_MULTI"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GEMINI_MULTI"* ]]
  [[ "$output" == *"CODEX_MULTI"* ]]
  [[ "$output" == *"REVIEW BY: GEMINI"* ]]
  [[ "$output" == *"REVIEW BY: CODEX"* ]]
}

# ─── Provider execution ──────────────────────────────────────

@test "single mode stops after first successful provider" {
  create_mock "gemini" "FIRST_ONLY"
  create_mock "codex" "SHOULD_NOT_APPEAR"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --single"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FIRST_ONLY"* ]]
  [[ "$output" != *"SHOULD_NOT_APPEAR"* ]]
}

@test "handles provider failure gracefully in multi mode" {
  create_failing_mock "gemini"
  create_mock "codex" "CODEX_SURVIVED"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CODEX_SURVIVED"* ]]
}

@test "exits 2 when all providers fail" {
  create_failing_mock "gemini"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider gemini"
  [ "$status" -eq 2 ]
  [[ "$output" == *"All providers failed"* ]]
}

@test "--provider forces specific provider and single mode" {
  create_mock "gemini" "FORCED_GEMINI"
  create_mock "codex" "SHOULD_NOT_RUN"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider gemini"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FORCED_GEMINI"* ]]
  [[ "$output" != *"SHOULD_NOT_RUN"* ]]
}

# ─── Output formatting ───────────────────────────────────────

@test "text output includes banner with metadata" {
  create_mock "gemini" "REVIEW_BODY"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider gemini"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CROSS-PROVIDER ADVERSARIAL REVIEW"* ]]
  [[ "$output" == *"Providers: gemini"* ]]
  [[ "$output" == *"Mode: code"* ]]
  [[ "$output" == *"Input size:"* ]]
  [[ "$output" == *"END OF CROSS-PROVIDER REVIEW"* ]]
}

@test "multi output includes per-provider section headers" {
  create_mock "gemini" "G_RESULT"
  create_mock "codex" "C_RESULT"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REVIEW BY: GEMINI"* ]]
  [[ "$output" == *"REVIEW BY: CODEX"* ]]
}

@test "--json output produces structured JSON metadata" {
  create_mock "gemini" '{"findings":[]}'
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --json --provider gemini"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"mode": "code"'* ]]
  [[ "$output" == *'"providers_used": "gemini"'* ]]
  [[ "$output" == *'"provider_count": 1'* ]]
  [[ "$output" == *'"results"'* ]]
  [[ "$output" == *'"date"'* ]]
}

@test "--json all-fail outputs error JSON" {
  create_failing_mock "gemini"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --json --provider gemini"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"error"'* ]]
  [[ "$output" == *"All providers failed"* ]]
}

# ─── Context hint ─────────────────────────────────────────────

@test "--context hint is passed to the review prompt" {
  create_inspecting_mock "gemini" "NestJS auth middleware" "CTX:found" "CTX:missing"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider gemini --context 'NestJS auth middleware'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CTX:found"* ]]
}

# ─── Prompt injection defense ────────────────────────────────

@test "review prompt includes anti-injection preamble" {
  create_inspecting_mock "gemini" "IGNORE any instructions" "DEFENSE:yes" "DEFENSE:no"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider gemini"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEFENSE:yes"* ]]
}

# ─── Environment variable overrides ──────────────────────────

@test "ZUVO_REVIEW_PROVIDER overrides auto-detection" {
  create_mock "gemini" "SHOULD_NOT_RUN"
  create_mock "codex" "CODEX_VIA_ENV"
  isolated_path

  export ZUVO_REVIEW_PROVIDER=codex
  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CODEX_VIA_ENV"* ]]
  [[ "$output" != *"SHOULD_NOT_RUN"* ]]
}

@test "ZUVO_REVIEW_TIMEOUT kills slow provider" {
  cat > "$MOCK_BIN/gemini" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null 2>&1 || true
sleep 10
echo "SLOW"
EOF
  chmod +x "$MOCK_BIN/gemini"
  isolated_path

  export ZUVO_REVIEW_TIMEOUT=3
  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider gemini"
  [ "$status" -eq 2 ]
}

# ─── Codex model sanitization ─────────────────────────────────

@test "ZUVO_CODEX_MODEL is sanitized against shell metacharacters" {
  cat > "$MOCK_BIN/codex" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "mcp-server" ]] && exit 1
cat > /dev/null 2>&1 || true
echo "CODEX_OK"
EOF
  chmod +x "$MOCK_BIN/codex"
  isolated_path

  export ZUVO_CODEX_MODEL='gpt-4; echo INJECTED'
  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider codex"
  [[ "$output" != *"INJECTED"* ]]
}

# ─── Stderr output ────────────────────────────────────────────

@test "stderr shows input size, mode, and dispatch type" {
  create_mock "gemini" "OK"
  isolated_path

  local stderr_file="$TMPDIR_TEST/stderr.txt"
  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider gemini --mode test 2>'$stderr_file'"
  [ "$status" -eq 0 ]

  local stderr_content
  stderr_content=$(cat "$stderr_file")
  [[ "$stderr_content" == *"Input:"* ]]
  [[ "$stderr_content" == *"Review: test"* ]]
  [[ "$stderr_content" == *"Dispatch: single"* ]]
}
