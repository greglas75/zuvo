#!/usr/bin/env bash
#
# test-registry-integrity.sh — suite wrapper around scripts/audit-registry-integrity.py.
#
# Exists so the cross-registry referential checks run in EVERY suite pass rather than only when
# someone remembers the runbook. The checks catch the class the structural linter cannot see:
# an ID one registry references and another never defines (dangling pentest probe templates,
# undefined finding types, fix types no check can emit, missing severity-vocabulary rows).
#
# Exit: 0 all clean | 1 any finding.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/audit-registry-integrity.py"

fail=0
pass() { echo "PASS: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: registry-integrity (python3 not installed)"
  exit 0
fi
if [ ! -f "$SCRIPT" ]; then
  bad "scripts/audit-registry-integrity.py is missing — the check cannot run"
  echo "=== RESULT ==="; echo "SOME FAILED"; exit 1
fi

out="$(python3 "$SCRIPT" --strict 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  pass "registry integrity (probes, finding types, safe patterns, check/fix pairs, severity rows)"
else
  bad "registry integrity violations:"
  printf '%s\n' "$out" | sed 's/^/      /'
fi

# The script must stay wired into the runbook — a check nobody knows about decays.
if grep -q 'audit-registry-integrity.py' "$ROOT/docs/runbook/testing.md" 2>/dev/null; then
  pass "runbook documents the integrity check"
else
  bad "docs/runbook/testing.md no longer references audit-registry-integrity.py"
fi

echo "=== RESULT ==="
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
