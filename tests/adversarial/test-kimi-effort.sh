#!/usr/bin/env bash
# test-kimi-effort.sh — the `kimi` lane sets thinking effort per call, not globally.
#
# The kimi CLI has no effort flag; effort lives in ~/.kimi-code/config.toml, which also drives
# the owner's interactive kimi. The lane therefore passes KIMI_MODEL_THINKING_EFFORT (the CLI's
# own env override) on the single call. Pinned here:
#   1. default is low (bench 2026-09-23: same marginal value as high, 4x faster, no timeouts)
#   2. ZUVO_KIMI_EFFORT overrides it
#   3. an unknown value falls back to low instead of reaching the CLI
#
# Everything runs against a FAKE `kimi` on PATH — no real endpoint, no quota spent.

ADV="$ROOT/scripts/adversarial-review.sh"
export ZUVO_ADVERSARIAL_TEST_HARNESS=1

KTMP="$HERE/.tmp/kimi-effort.$$"; mkdir -p "$KTMP/bin"
cleanup_kimi_effort() { rm -rf "$KTMP"; }
trap cleanup_kimi_effort EXIT

INPUT="$KTMP/input.py"
printf 'def f(x):\n    return x / 0\n' > "$INPUT"

cat > "$KTMP/bin/kimi" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${KIMI_MODEL_THINKING_EFFORT-<unset>}" > "$FAKE_KIMI_DIR/effort"
printf '{"role":"assistant","content":"SEVERITY: CRITICAL\\nFILE: input.py:2\\nISSUE: division by zero KIMI-FAKE-FINDING"}\n'
EOF
chmod +x "$KTMP/bin/kimi"

run_kimi_case() { # run_kimi_case <case> [ZUVO_KIMI_EFFORT value; omit = unset] -> recorded effort
  local c="$KTMP/$1"; mkdir -p "$c"
  local -a eff=(-u ZUVO_KIMI_EFFORT)
  [[ $# -ge 2 ]] && eff=(ZUVO_KIMI_EFFORT="$2")
  env -u CLAUDECODE -u CODEX_SANDBOX -u CODEX_SHELL -u KIMI_MODEL_THINKING_EFFORT "${eff[@]}" \
    PATH="$KTMP/bin:$PATH" FAKE_KIMI_DIR="$c" ZUVO_HOME="$c" \
    ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=25 \
    bash "$ADV" --provider kimi --mode code --files "$INPUT" > "$c/stdout" 2>"$c/stderr"
  cat "$c/effort" 2>/dev/null || printf '<not called>'
}

start_test "ke.1 kimi runs at effort=low by default"
assert_eq "low" "$(run_kimi_case k1)" "default effort"
assert_contains "$(cat "$KTMP/k1/stdout")" "KIMI-FAKE-FINDING" "the review still flows through"

start_test "ke.2 ZUVO_KIMI_EFFORT overrides the default"
assert_eq "high" "$(run_kimi_case k2 high)" "override high"
assert_eq "max"  "$(run_kimi_case k3 max)"  "override max"

start_test "ke.3 an unknown effort value falls back to low"
assert_eq "low" "$(run_kimi_case k4 'extreme; rm -rf /')" "invalid value never reaches the CLI"
