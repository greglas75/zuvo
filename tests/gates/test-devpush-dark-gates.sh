#!/usr/bin/env bash
# dev-push Step 0 must refuse a suite that exited 0 with gates DARK.
#
# `run-all.sh` counts SKIP as a non-failure — correct for a scope-based skip, dangerous for a gate
# that stood down because its tool is absent. Before this gate existed, `dev-push.sh` read only
# `$?`, so a machine without shellcheck released with the shell-lint check (309 files, hard zero
# errors + a zero-warning ratchet) silently off, and printed "Step 0: test suite green".
#
# Measured 2026-09-06 on the test-farm image: FIVE gates dark at once — shellcheck, the Python
# lint gate, the bats corpus, zsh, the classic-TS path — with the suite still exiting 0. That is
# not a farm quirk; it is what any thinner box does, including a fresh laptop.
#
# The test drives the REAL Step 0 region by extracting it and feeding it a fake `run-all.sh`, so
# it exercises the shipped code rather than a re-implementation of it.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEVPUSH="$ROOT/scripts/dev-push.sh"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

[ -f "$DEVPUSH" ] || { bad "dev-push.sh missing"; echo "SOME FAILED"; exit 1; }

# The markers are the contract: if someone renames them, this test must fail loudly rather than
# silently testing nothing.
if ! grep -q '^# >>> zuvo:test-gate' "$DEVPUSH" || ! grep -q '^# <<< zuvo:test-gate' "$DEVPUSH"; then
  bad "zuvo:test-gate markers not found in dev-push.sh — cannot extract Step 0"
  echo "SOME FAILED"; exit 1
fi
pass "Step 0 region is delimited by its markers"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# Harness: the extracted Step 0 plus the helpers it calls, and a stub suite whose output we control.
build_harness() {   # build_harness <suite-stdout-file> <suite-exit>
  mkdir -p "$TMP/tests"
  cp "$1" "$TMP/suite-output.txt"
  cat > "$TMP/tests/run-all.sh" <<EOF
#!/usr/bin/env bash
cat "$TMP/suite-output.txt"
exit $2
EOF
  chmod +x "$TMP/tests/run-all.sh"

  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo "ZUVO_DIR=\"$TMP\""
    # Same shapes as dev-push's own helpers; `fail` must exit non-zero.
    echo 'ok()   { echo "OK: $1"; }'
    echo 'warn() { echo "WARN: $1"; }'
    echo 'fail() { echo "FAIL: $1" >&2; exit 1; }'
    sed -n '/^# >>> zuvo:test-gate/,/^# <<< zuvo:test-gate/p' "$DEVPUSH"
  } > "$TMP/step0.sh"
  chmod +x "$TMP/step0.sh"
}

run_step0() { ( cd "$TMP" && bash "$TMP/step0.sh" >"$TMP/out.txt" 2>"$TMP/err.txt" ); echo $?; }

# ── 1. clean green run → proceeds ────────────────────────────────────────────
cat > "$TMP/green.txt" <<'EOF'
PASS: tests/hooks/test-a.sh (1s)
SKIP: tests/infra-suite/test-suite-e2e.sh (FULL scope only)
RESULT: PASS=126 FAIL=0 SKIP=1
ALL PASSED
EOF
build_harness "$TMP/green.txt" 0
rc=$(run_step0)
if [ "$rc" = "0" ] && grep -q 'no gate stood down' "$TMP/out.txt"; then
  pass "green suite with only a SCOPE skip proceeds"
else
  bad "green suite was refused (rc=$rc): $(tail -2 "$TMP/err.txt" "$TMP/out.txt" | tr '\n' ' ')"
fi

# ── 2. a tool-missing skip -> REFUSED ────────────────────────────────────────
# Each case is `label<TAB>verbatim SKIP line`. The label exists so the RESULT lines this test
# prints stay pure ASCII: the real SKIP strings contain an em dash, and slicing one for display
# with `cut -c` cuts BYTES under a non-UTF-8 locale, emitting a half character that made awk
# abort mid-run on the test farm. The fixtures keep the em dash (they must match production
# output byte for byte); only what we PRINT is constrained.
while IFS=$'\t' read -r label phrase; do
  [ -n "${label:-}" ] || continue
  { echo "PASS: tests/hooks/test-a.sh (1s)"; echo "$phrase"; echo "RESULT: PASS=110 FAIL=0 SKIP=1"; } > "$TMP/dark.txt"
  build_harness "$TMP/dark.txt" 0
  rc=$(run_step0)
  if [ "$rc" != "0" ] && grep -q 'never ran' "$TMP/err.txt"; then
    pass "refused a dark gate: $label"
  else
    bad "dark gate NOT refused (rc=$rc): $label"
  fi
done <<EOF
shellcheck$(printf '\t')SKIP: shellcheck is not installed — the shell lint gate did NOT run.
python-lint$(printf '\t')SKIP: neither ruff nor mypy installed — the Python lint gate did NOT run.
bats-corpus$(printf '\t')SKIP: scripts/tests/*.bats (bats not installed — group skipped)
zsh$(printf '\t')SKIP: zsh not available
classic-ts$(printf '\t')SKIP: no classic typescript module reachable — TS path not exercised on this machine
EOF

# The refusal must name the gate, or the operator cannot act on it.
{ echo "SKIP: shellcheck is not installed — the shell lint gate did NOT run."; echo "RESULT: PASS=1 FAIL=0 SKIP=1"; } > "$TMP/dark.txt"
build_harness "$TMP/dark.txt" 0
run_step0 >/dev/null
grep -q 'shellcheck' "$TMP/err.txt" \
  && pass "refusal names the gate that went dark" \
  || bad "refusal does not name the dark gate"

# ── 3. the escape hatch works, and is loud ───────────────────────────────────
rc=$( (cd "$TMP" && ZUVO_ALLOW_DARK_GATES=1 bash "$TMP/step0.sh" >"$TMP/out.txt" 2>"$TMP/err.txt"); echo $? )
if [ "$rc" = "0" ] && grep -q 'did NOT run' "$TMP/out.txt"; then
  pass "ZUVO_ALLOW_DARK_GATES=1 proceeds AND still prints the dark gates"
else
  bad "escape hatch broken (rc=$rc)"
fi

# ── 4. a real test failure still fails, and is not confused with a dark gate ──
{ echo "FAIL: tests/hooks/test-a.sh (exit 1)"; echo "RESULT: PASS=0 FAIL=1 SKIP=0"; echo "SOME FAILED"; } > "$TMP/red.txt"
build_harness "$TMP/red.txt" 1
rc=$(run_step0)
if [ "$rc" != "0" ] && grep -q 'Tests failed' "$TMP/err.txt"; then
  pass "a red suite still fails with the test-failure message"
else
  bad "red suite not reported as a test failure (rc=$rc)"
fi

# ── 5. ZUVO_SKIP_TESTS=1 still bypasses (unchanged behaviour) ────────────────
build_harness "$TMP/green.txt" 0
rc=$( (cd "$TMP" && ZUVO_SKIP_TESTS=1 bash "$TMP/step0.sh" >"$TMP/out.txt" 2>&1); echo $? )
[ "$rc" = "0" ] && grep -q 'Step 0 SKIPPED' "$TMP/out.txt" \
  && pass "ZUVO_SKIP_TESTS=1 bypass is unchanged" \
  || bad "ZUVO_SKIP_TESTS=1 bypass regressed (rc=$rc)"

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASSED"; exit 0; } || { echo "SOME FAILED"; exit 1; }
