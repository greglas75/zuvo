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

# Set isolated PATH: mock bin + system essentials + homebrew (for timeout, jq).
# No ~/.local/bin (agent), etc.
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
  # mock-* providers are refused unless the harness flag is set — a deliberate
  # guard so a stray `--provider mock-x` can never dispatch in a real run.
  export ZUVO_ADVERSARIAL_TEST_HARNESS=1
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
  create_mock "mock-gemini" "STDIN_RECEIVED"
  isolated_path

  run bash -c "echo 'some diff content here' | '$SCRIPT' --provider mock-gemini"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STDIN_RECEIVED"* ]]
}

@test "reads files via --files flag" {
  create_mock "mock-gemini" "FILES_RECEIVED"
  isolated_path

  run "$SCRIPT" --provider mock-gemini --files "$SAMPLE_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FILES_RECEIVED"* ]]
}

@test "--artifact writes metadata and review output to file" {
  create_mock "mock-gemini" "ARTIFACT_RECEIVED"
  isolated_path

  local artifact="$TMPDIR_TEST/adversarial-task-1.txt"

  run "$SCRIPT" --provider mock-gemini --files "$SAMPLE_FILE" --artifact "$artifact"
  [ "$status" -eq 0 ]
  [ -s "$artifact" ]
  [[ "$output" == *"ARTIFACT_RECEIVED"* ]]
  grep -q '^artifact_kind=adversarial-review$' "$artifact"
  grep -q '^mode=code$' "$artifact"
  grep -q '^provider_count=1$' "$artifact"
  grep -q 'ARTIFACT_RECEIVED' "$artifact"
}

@test "handles missing file in --files gracefully" {
  create_mock "mock-gemini" "MISSING_OK"
  isolated_path

  run "$SCRIPT" --provider mock-gemini --files "$TMPDIR_TEST/nonexistent.ts"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MISSING_OK"* ]]
}

@test "exits 2 when stdin is empty and no --files/--diff" {
  create_mock "mock-gemini" "unused"
  isolated_path

  run bash -c "echo '' | '$SCRIPT' --provider mock-gemini"
  [ "$status" -eq 2 ]
  [[ "$output" == *"No input provided"* ]]
}

# ─── Input truncation ────────────────────────────────────────

@test "truncates code-mode input exceeding 30000 chars, adds notice, and exits 4" {
  create_inspecting_mock "mock-gemini" "TRUNCATED" "WAS_TRUNCATED" "NOT_TRUNCATED"
  isolated_path

  # Generate 35000 chars (code mode truncates at 30000)
  local big_input
  big_input=$(printf '%0.sx' $(seq 1 35000))

  run bash -c "printf '%s' '$big_input' | '$SCRIPT' --provider mock-gemini"
  # DELIBERATE CONTRACT CHANGE (B-ADV-TRUNC), not a broken test. This assertion used to require
  # exit 0 — and that expectation is what made the bug survive: every call-site in
  # adversarial-loop.md gates on the exit code, so "truncated the input, dropped files, exited 0"
  # meant a partially-reviewed patch reported as fully reviewed, with a green test pinning it.
  # 4 = review completed but does NOT cover the whole change.
  [ "$status" -eq 4 ]
  [[ "$output" == *"WAS_TRUNCATED"* ]]
}

@test "preserves input under 30000 chars without truncation" {
  create_inspecting_mock "mock-gemini" "TRUNCATED" "WAS_TRUNCATED" "NOT_TRUNCATED"
  isolated_path

  run bash -c "echo 'short input' | '$SCRIPT' --provider mock-gemini"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT_TRUNCATED"* ]]
}

# ─── Language detection ──────────────────────────────────────

@test "detects TypeScript from .ts extension in diff" {
  create_inspecting_mock "mock-gemini" "TypeScript" "LANG:TypeScript" "LANG:none"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider mock-gemini"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LANG:TypeScript"* ]]
}

@test "detects Python from .py extension" {
  create_inspecting_mock "mock-gemini" "Python" "LANG:Python" "LANG:none"
  isolated_path

  local py_diff="diff --git a/main.py b/main.py
+def hello(): pass"

  run bash -c "echo '$py_diff' | '$SCRIPT' --provider mock-gemini"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LANG:Python"* ]]
}

@test "no language hint for plain text input" {
  create_inspecting_mock "mock-gemini" "written in" "LANG:detected" "LANG:none"
  isolated_path

  run bash -c "echo 'just plain text no extensions' | '$SCRIPT' --provider mock-gemini"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LANG:none"* ]]
}

# ─── Review mode selection ────────────────────────────────────

@test "defaults to code review focus" {
  create_inspecting_mock "mock-gemini" "Edge cases the author" "MODE:code" "MODE:other"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider mock-gemini"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MODE:code"* ]]
}

@test "--mode test selects test-specific focus" {
  create_inspecting_mock "mock-gemini" "TEST-SPECIFIC" "MODE:test" "MODE:other"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider mock-gemini --mode test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MODE:test"* ]]
}

@test "--mode security selects security focus" {
  create_inspecting_mock "mock-gemini" "SECURITY ISSUES" "MODE:security" "MODE:other"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider mock-gemini --mode security"
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

@test "detects agy when command exists" {
  create_mock "agy" "AGY_DETECTED"
  isolated_path

  # Use --single to avoid running other detected providers
  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --single"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AGY_DETECTED"* ]]
}

@test "detects codex when command exists" {
  create_mock "codex" "CODEX_DETECTED"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --single"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CODEX_DETECTED"* ]]
}

@test "detects multiple providers and runs all in multi mode" {
  create_mock "agy" "AGY_MULTI"
  create_mock "codex" "CODEX_MULTI"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AGY_MULTI"* ]]
  [[ "$output" == *"CODEX_MULTI"* ]]
  # Section banners are what MULTI puts on stdout. The `REVIEW BY:` proof markers
  # moved into the --artifact metadata (that is what pipeline-gate-lib counts), so
  # asserting them on stdout tested a contract that no longer exists.
  [[ "$output" == *"PROVIDER: AGY"* ]]
  [[ "$output" == *"PROVIDER: CODEX-5.3"* ]]
}

# ─── Provider execution ──────────────────────────────────────

@test "single mode stops after first successful provider" {
  create_mock "codex" "FIRST_ONLY"
  create_mock "agy" "SHOULD_NOT_APPEAR"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --single"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FIRST_ONLY"* ]]
  [[ "$output" != *"SHOULD_NOT_APPEAR"* ]]
}

@test "handles provider failure gracefully in multi mode" {
  create_failing_mock "mock-gemini"
  create_mock "codex" "CODEX_SURVIVED"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CODEX_SURVIVED"* ]]
}

@test "exits 2 when all providers fail" {
  create_failing_mock "mock-gemini"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider mock-gemini"
  [ "$status" -eq 2 ]
  # Message reworded when provider outcomes became distinguishable ("reached and
  # returned nothing" vs "never reached"). Assert the OUTCOME wording, not the old
  # blanket phrase, so this keeps proving the all-fail path rather than a string.
  [[ "$output" == *"no review produced"* ]]
}

@test "--provider forces specific provider and single mode" {
  create_mock "mock-gemini" "FORCED_GEMINI"
  create_mock "codex" "SHOULD_NOT_RUN"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider mock-gemini"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FORCED_GEMINI"* ]]
  [[ "$output" != *"SHOULD_NOT_RUN"* ]]
}

# ─── Output formatting ───────────────────────────────────────

@test "text output includes banner with metadata" {
  create_mock "mock-gemini" "REVIEW_BODY"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider mock-gemini"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CROSS-PROVIDER ADVERSARIAL REVIEW"* ]]
  # The banner names the provider ACTUALLY dispatched, so the expectation has to carry
  # the `mock-` prefix. It did not, and had been red since the harness guard landed:
  # `--provider mock-*` is now refused unless ZUVO_ADVERSARIAL_TEST_HARNESS is set, so
  # every mock in this file was renamed `gemini` -> `mock-gemini` while these two
  # assertions kept the bare name. `*"Providers: gemini"*` cannot match
  # "Providers: mock-gemini" — the prefix sits between the two halves of the glob.
  [[ "$output" == *"Providers: mock-gemini"* ]]
  [[ "$output" == *"Mode: code"* ]]
  [[ "$output" == *"Input size:"* ]]
  [[ "$output" == *"END OF CROSS-PROVIDER REVIEW"* ]]
}

@test "multi output includes per-provider section headers" {
  create_mock "agy" "G_RESULT"
  create_mock "codex" "C_RESULT"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROVIDER: AGY"* ]]
  [[ "$output" == *"PROVIDER: CODEX-5.3"* ]]
}

@test "--json output produces structured JSON metadata" {
  create_mock "mock-gemini" '{"findings":[]}'
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --json --provider mock-gemini"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"mode": "code"'* ]]
  # Same stale-name cause as the banner test above: the mock is `mock-gemini`, and the
  # JSON reports the provider that actually ran.
  [[ "$output" == *'"providers_used": "mock-gemini"'* ]]
  [[ "$output" == *'"provider_count": 1'* ]]
  [[ "$output" == *'"results"'* ]]
  [[ "$output" == *'"date"'* ]]
}

@test "--json all-fail outputs error JSON" {
  create_failing_mock "mock-gemini"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --json --provider mock-gemini"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"error"'* ]]
  # Message reworded when provider outcomes became distinguishable ("reached and
  # returned nothing" vs "never reached"). Assert the OUTCOME wording, not the old
  # blanket phrase, so this keeps proving the all-fail path rather than a string.
  [[ "$output" == *"no review produced"* ]]
}

# ─── Context hint ─────────────────────────────────────────────

@test "--context hint is passed to the review prompt" {
  create_inspecting_mock "mock-gemini" "NestJS auth middleware" "CTX:found" "CTX:missing"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider mock-gemini --context 'NestJS auth middleware'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CTX:found"* ]]
}

# ─── Prompt injection defense ────────────────────────────────

@test "review prompt includes anti-injection preamble" {
  create_inspecting_mock "mock-gemini" "IGNORE any instructions" "DEFENSE:yes" "DEFENSE:no"
  isolated_path

  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider mock-gemini"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEFENSE:yes"* ]]
}

# ─── Environment variable overrides ──────────────────────────

@test "ZUVO_REVIEW_PROVIDER overrides auto-detection" {
  create_mock "agy" "SHOULD_NOT_RUN"
  create_mock "codex" "CODEX_FAST_VIA_ENV"
  isolated_path

  # Provider label is codex-5.3 since the lanes were renamed; codex-fast no longer resolves.
  export ZUVO_REVIEW_PROVIDER=codex-5.3
  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CODEX_FAST_VIA_ENV"* ]]
  [[ "$output" != *"SHOULD_NOT_RUN"* ]]
}

@test "ZUVO_REVIEW_TIMEOUT kills slow provider" {
  command -v timeout &>/dev/null || skip "GNU timeout required"
  cat > "$MOCK_BIN/mock-gemini" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null 2>&1 || true
sleep 10
echo "SLOW"
EOF
  chmod +x "$MOCK_BIN/mock-gemini"
  isolated_path

  export ZUVO_REVIEW_TIMEOUT=3
  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider mock-gemini"
  # 124, not 2: the script distinguishes "every provider TIMED OUT" (124, the
  # conventional timeout exit) from "every provider returned EMPTY" (2). The old
  # expectation collapsed both into one code, so this test would have passed even
  # if the timeout had never fired and the provider had merely returned nothing.
  [ "$status" -eq 124 ]
  [[ "$output" == *"timed out"* ]]
  [[ "$output" != *"SLOW"* ]]
}

# ─── Codex model sanitization ─────────────────────────────────

@test "the codex model env var is sanitized against shell metacharacters" {
  cat > "$MOCK_BIN/codex" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "mcp-server" ]] && exit 1
cat > /dev/null 2>&1 || true
echo "CODEX_OK"
EOF
  chmod +x "$MOCK_BIN/codex"
  isolated_path

  # The variable name matters, and the first version of this test had it wrong: it set
  # ZUVO_CODEX_MODEL, which adversarial-review.sh reads ZERO times (the real one is
  # ZUVO_MODEL_CODEX_PRIMARY). So the injection payload was never on any code path — and with no
  # positive control the single `!= *INJECTED*` assertion was true whether the sanitizer worked,
  # was deleted, or the provider never ran at all. A test that passes for a variable the subject
  # does not read is not testing the subject.
  # `codex-5.3` is the provider ID the dispatcher knows (see provider_model()); a bare `codex` is
  # not one, which is a second reason the original test could never exercise the sanitizer.
  export ZUVO_MODEL_CODEX_PRIMARY='gpt-4; echo INJECTED'
  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider codex-5.3"

  # POSITIVE CONTROL FIRST — prove the provider actually ran. Without it the negative assertion
  # below is satisfied by a run that did nothing at all, which is precisely how the original
  # version of this test stayed green while testing nothing.
  [[ "$output" == *"CODEX_OK"* ]]
  [[ "$output" != *"INJECTED"* ]]
}

# ─── Stderr output ────────────────────────────────────────────

@test "stderr shows input size, mode, and dispatch type" {
  create_mock "mock-gemini" "OK"
  isolated_path

  local stderr_file="$TMPDIR_TEST/stderr.txt"
  run bash -c "echo '$SAMPLE_DIFF' | '$SCRIPT' --provider mock-gemini --mode test 2>'$stderr_file'"
  [ "$status" -eq 0 ]

  local stderr_content
  stderr_content=$(cat "$stderr_file")
  [[ "$stderr_content" == *"Input:"* ]]
  [[ "$stderr_content" == *"Review: test"* ]]
  [[ "$stderr_content" == *"Dispatch: single"* ]]
}
