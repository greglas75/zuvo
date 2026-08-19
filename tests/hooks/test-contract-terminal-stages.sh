#!/usr/bin/env bash
# test-contract-terminal-stages.sh — a HALTED refactor must release its fence.
#
# Field report 2026-08-07: six BLOCKED refactor contracts from earlier sessions
# kept blocking commits, and the operator's escape was to reopen a live contract
# and widen its fence to cover the file they wanted to commit. That is a scope
# stretch the gate should never have made attractive — the gate's own design says
# a fence is the set of files a refactor is touching, not a permission list.
#
# Cause: both gates recognised exactly one terminal stage, `COMPLETE`. The gate
# exists to stop an IN-FLIGHT refactor being committed around; a run that hit a
# hard blocker and halted is not in flight. So `BLOCKED` (and `ABORTED`) held the
# fence until the contract's mtime aged past the 24h TTL.
#
# `EXECUTION_COMPLETE` is deliberately NOT terminal — skills/refactor/SKILL.md:220
# uses it for `no-commit` runs so `continue` can resume, i.e. still in flight.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/hooks/lib/refactor-gate-lib.sh"
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

probe() { # probe <stage> -> rc of the scope guard on an UNRELATED file
  local stage="$1" t; t=$(mktemp -d)
  ( cd "$t" || exit 1; git init -q .; git config user.email t@t; git config user.name t
    mkdir -p zuvo/contracts src; : > src/a.ts; : > src/unrelated.ts
    printf '{"stage":"%s","scope_fence":["src/a.ts"],"blind_audit":"clean:strict","adversarial":"clean","characterization":"green"}\n' \
      "$stage" > zuvo/contracts/refactor-x.json
    export CLAUDE_CODE=1   # agent env: the human bypass must not mask the result
    # shellcheck source=/dev/null
    . "$LIB" 2>/dev/null
    refactor_scope_gate_check "src/unrelated.ts" >/dev/null 2>&1; echo $? )
  rm -rf "$t"
}

echo "=== terminal stages release the fence ==="
for st in BLOCKED ABORTED COMPLETE; do
  rc=$(probe "$st")
  [ "$rc" = "0" ] && ok "$st releases the fence (unrelated commit allowed)" \
                  || bad "$st still blocks unrelated work (rc=$rc) — a halted refactor holds the repo"
done

echo "=== an in-flight refactor still blocks (the gate must keep working) ==="
for st in PHASE-1 PHASE-2 EXECUTION_COMPLETE; do
  rc=$(probe "$st")
  [ "$rc" = "1" ] && ok "$st still fences unrelated files" \
                  || bad "$st stopped fencing (rc=$rc) — the fix disabled the gate instead of narrowing it"
done

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
