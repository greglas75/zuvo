#!/bin/bash
# Static validator for the compressed response protocol rollout.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROTOCOL="$ROOT/shared/includes/compressed-response-protocol.md"
HOOK="$ROOT/hooks/session-start"
ROUTER="$ROOT/skills/using-zuvo/SKILL.md"
CONFIG_DOC="$ROOT/docs/configuration.md"
GETTING_STARTED="$ROOT/docs/getting-started.md"
EVAL_SCRIPT="$ROOT/scripts/eval-response-protocol.sh"
MANIFEST="$ROOT/tests/fixtures/response-protocol/manifest.json"

ERRORS=0

pass() {
  echo "OK: $1"
}

fail() {
  echo "FAIL: $1"
  ERRORS=$((ERRORS + 1))
}

require_file() {
  if [ -f "$1" ]; then
    pass "Found $(basename "$1")"
  else
    fail "Missing required file: $1"
  fi
}

expect_text() {
  local needle="$1"
  local file="$2"
  local label="$3"
  if grep -Fq -- "$needle" "$file"; then
    pass "$label"
  else
    fail "$label"
  fi
}

echo "=== Response Protocol Validator ==="
echo ""

for file in \
  "$PROTOCOL" "$HOOK" "$ROUTER" "$CONFIG_DOC" "$GETTING_STARTED" \
  "$EVAL_SCRIPT" "$MANIFEST"; do
  require_file "$file"
done

echo ""
echo "--- Protocol Contract ---"
expect_text "Zuvo Compressed Response Protocol (v1)" "$PROTOCOL" "Protocol title present"
expect_text "## Override Order" "$PROTOCOL" "Protocol documents override order"
expect_text '`STANDARD`' "$PROTOCOL" "Protocol documents STANDARD mode"
expect_text '`TERSE`' "$PROTOCOL" "Protocol documents TERSE mode"
expect_text '`STRUCTURED_TERSE`' "$PROTOCOL" "Protocol documents STRUCTURED_TERSE mode"
expect_text "[...truncated...]" "$PROTOCOL" "Protocol documents truncation escape hatch"
expect_text "quoted error strings" "$PROTOCOL" "Protocol protects quoted error strings"
expect_text "conf: confirmed" "$PROTOCOL" "Protocol documents confidence markers"

echo ""
echo "--- Hook Wiring ---"
expect_text "PROTOCOL_FILE" "$HOOK" "session-start defines protocol file"
expect_text "ZUVO_RESPONSE_PROTOCOL" "$HOOK" "session-start reads kill switch"
expect_text "compressed-response-protocol.md" "$HOOK" "session-start references protocol include"
expect_text "response-style contract" "$HOOK" "session-start injects protocol section"

on_output="$(cd "$ROOT" && CODEX_PLUGIN_ROOT=1 bash ./hooks/session-start 2>/dev/null || true)"
off_output="$(cd "$ROOT" && CODEX_PLUGIN_ROOT=1 ZUVO_RESPONSE_PROTOCOL=off bash ./hooks/session-start 2>/dev/null || true)"

if [ -n "$on_output" ] && printf '%s' "$on_output" | python3 -m json.tool >/dev/null 2>&1; then
  pass "session-start emits valid JSON"
else
  fail "session-start emits valid JSON"
fi

if printf '%s' "$on_output" | grep -Fq "Zuvo Compressed Response Protocol (v1)"; then
  pass "session-start injects protocol when enabled"
else
  fail "session-start injects protocol when enabled"
fi

if printf '%s' "$off_output" | grep -Fq "Zuvo Compressed Response Protocol (v1)"; then
  fail "session-start removes protocol when kill switch is off"
else
  pass "session-start removes protocol when kill switch is off"
fi

if printf '%s' "$off_output" | grep -Fq "Zuvo Skill Router"; then
  pass "session-start keeps router when protocol is disabled"
else
  fail "session-start keeps router when protocol is disabled"
fi

echo ""
echo "--- Router + Docs ---"
expect_text "## Response Surface Policy" "$ROUTER" "Router documents response surface policy"
expect_text "legacy verbosity in degraded mode" "$ROUTER" "Router documents degraded-mode limitation"
expect_text "compressed-response-protocol.md" "$CONFIG_DOC" "Configuration docs mention protocol include"
expect_text "ZUVO_RESPONSE_PROTOCOL=off" "$CONFIG_DOC" "Configuration docs mention kill switch"
expect_text "degraded mode" "$CONFIG_DOC" "Configuration docs mention degraded mode"
expect_text "compressed-response-protocol.md" "$GETTING_STARTED" "Getting started docs mention protocol include"
expect_text "ZUVO_RESPONSE_PROTOCOL=off" "$GETTING_STARTED" "Getting started docs mention kill switch"
expect_text "degraded mode" "$GETTING_STARTED" "Getting started docs mention degraded mode"

echo ""
echo "--- Fixture Manifest ---"
if python3 - "$MANIFEST" <<'PY'
import json
import sys

manifest_path = sys.argv[1]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)

samples = manifest.get("samples", [])
if len(samples) != 10:
    raise SystemExit(1)

protected_final_blocks = sum(1 for sample in samples if sample.get("protected_heading"))
if protected_final_blocks < 2:
    raise SystemExit(2)
PY
then
  pass "Manifest contains 10 samples and 2 protected final blocks"
else
  fail "Manifest contains 10 samples and 2 protected final blocks"
fi

echo ""
echo "--- Eval Script Contracts ---"
expect_text "--scenario verbose-override" "$EVAL_SCRIPT" "Eval script exposes verbose-override scenario"
expect_text "--scenario readability-sheet" "$EVAL_SCRIPT" "Eval script exposes readability-sheet scenario"
expect_text "token proxy" "$EVAL_SCRIPT" "Eval script documents token proxy counting"
expect_text "mode_matches" "$EVAL_SCRIPT" "Eval script reports mode matches"

echo ""
echo "=== Summary ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "PASS: compressed response protocol wiring validated"
  exit 0
fi

echo "FAIL: $ERRORS validation errors found"
exit 1
