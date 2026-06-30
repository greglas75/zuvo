#!/usr/bin/env bash
# Tests plan_execute_gate_check via the REAL entry (hooks/refactor-safety-gate.sh).
# 6 mechanism cases + human-bypass + ALLOW_ADHOC + proof BOTH checks run in the entry.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/hooks/refactor-safety-gate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }
newrepo(){ rm -rf "$TMP/r"; mkdir -p "$TMP/r/zuvo/plans" "$TMP/r/docs/specs" "$TMP/r/zuvo/contracts"; cd "$TMP/r"
  git init -q; git config user.email t@t; git config user.name t; }
install_hook(){ printf '#!/bin/sh\nexec "%s" pre-commit\n' "$GATE" > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit; }
ap(){ printf -- '---\nplan: %s\nstatus: %s\n---\n' "$1" "$2" > zuvo/plans/active-plan.md; }
planfiles(){ printf '# plan\n\n### Task 1\n**Files:** %s\n' "$1" > docs/specs/p-plan.md; }
trycommit(){ echo "x$RANDOM" >> "$1"; git add "$1"; git commit -q -m t >/dev/null 2>&1; echo $?; }

chmod +x "$GATE" "$ROOT/hooks/lib/refactor-gate-lib.sh" 2>/dev/null
echo "=== plan→execute gate (6 mechanism cases) ==="
newrepo; install_hook; planfiles "app.ts"
ap docs/specs/p-plan.md pending
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -ne 0 ] && ok "1 BLOCK pending+planfile" || bad "1 BLOCK"
ap docs/specs/p-plan.md in-progress
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "2 ALLOW in-progress" || bad "2 in-progress"
ap docs/specs/p-plan.md pending
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit other.ts")" -eq 0 ] && ok "3 ALLOW pending+non-plan-file" || bad "3 non-plan-file"
rm -f zuvo/plans/active-plan.md
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "4 ALLOW no active-plan" || bad "4 no-plan"
ap docs/specs/MISSING-plan.md pending
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "5 fail-OPEN missing plan doc" || bad "5 missing-doc"
printf '# plan\nno files\n' > docs/specs/p-plan.md; ap docs/specs/p-plan.md pending
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "6 fail-OPEN empty **Files:**" || bad "6 empty-files"

echo "=== human-bypass + ALLOW_ADHOC ==="
newrepo; install_hook; planfiles "app.ts"; ap docs/specs/p-plan.md pending
[ "$(env -u ZUVO_AI_RUN -u CLAUDECODE -u CURSOR_TRACE_ID -u CODEX_SANDBOX bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "human committer bypass" || bad "human-bypass"
newrepo; install_hook; planfiles "app.ts"; ap docs/specs/p-plan.md pending
[ "$(ZUVO_AI_RUN=1 ZUVO_ALLOW_ADHOC=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "ZUVO_ALLOW_ADHOC escape" || bad "allow-adhoc"

echo "=== BOTH checks active in the entry: refactor CONTRACT violation still blocks ==="
newrepo; install_hook
printf '{"stage":"PHASE-3","scope_fence":["app.ts"],"prove":{"blind_audit":"skipped","adversarial":"clean","findings_disposition":"none"}}' > zuvo/contracts/refactor-a.json
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -ne 0 ] && ok "refactor gate still blocks alongside plan gate" || bad "refactor gate (regression)"

echo "=== regression: CRLF status still blocks (no fail-open bypass) ==="
newrepo; install_hook; planfiles "app.ts"
printf -- '---\r\nplan: docs/specs/p-plan.md\r\nstatus: pending\r\n---\r\n' > zuvo/plans/active-plan.md
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -ne 0 ] && ok "CRLF active-plan still blocks" || bad "CRLF bypass (regressed)"

echo "=== regression: plan filename with a space is gated (comma-split, not word-split) ==="
newrepo; install_hook; planfiles "my file.ts"
ap docs/specs/p-plan.md pending
echo y >> "my file.ts"; git add "my file.ts"
r=$(ZUVO_AI_RUN=1 git commit -q -m t >/dev/null 2>&1; echo $?)
[ "$r" -ne 0 ] && ok "spaced plan filename blocked (no word-split bypass)" || bad "spaced filename bypassed"

echo "=== regression: multi-task plan (many **Files:** lines) gates files from ANY task ==="
newrepo; install_hook
printf '# plan\n\n### Task 1\n**Files:** a.ts\n\n### Task 2\n**Files:** b.ts, c.ts\n' > docs/specs/p-plan.md
ap docs/specs/p-plan.md pending
echo y >> c.ts; git add c.ts
r=$(ZUVO_AI_RUN=1 git commit -q -m t >/dev/null 2>&1; echo $?)
[ "$r" -ne 0 ] && ok "file from 2nd task's **Files:** blocked (newline+comma split)" || bad "multi-task plan bypassed"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
