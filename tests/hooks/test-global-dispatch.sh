#!/usr/bin/env bash
# Tests hooks/git-dispatch/{pre-push,pre-commit} — the GLOBAL core.hooksPath dispatchers.
# Contract: run repo-local hook first WITHOUT exec (rc propagates), then ALWAYS chain the
# zuvo gates from the dispatcher's own dir; fail-open when gates missing; stdin fed once.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }
REFLINE='refs/heads/main 1111111111111111111111111111111111111111 refs/heads/main 2222222222222222222222222222222222222222'

# Build a fake installed-hooks dir (dispatcher chains gates from ITS OWN dir) + a temp repo.
# newenv <blocking|g8|adhoc|recorder|none>  -> sets HD (hooks dir) and enters a fresh repo
newenv() {
  mode=$1
  HD="$TMP/hooksdir"; rm -rf "$HD"; mkdir -p "$HD"
  cp "$ROOT/hooks/git-dispatch/pre-push" "$HD/pre-push" 2>/dev/null
  cp "$ROOT/hooks/git-dispatch/pre-commit" "$HD/pre-commit" 2>/dev/null
  chmod +x "$HD"/* 2>/dev/null
  case "$mode" in
    blocking)  # both gates block with a token
      printf '#!/bin/sh\necho "GATE-BLOCK pipeline" >&2\nexit 1\n' > "$HD/pre-push-gate.sh"
      printf '#!/bin/sh\necho "BLOCK: workgate" >&2\nexit 1\n' > "$HD/refactor-safety-gate.sh" ;;
    g8)        # gates honor human-exempt (G8) + ZUVO_ALLOW_ADHOC, else block
      printf '#!/bin/sh\n[ -z "${ZUVO_AI_RUN:-}${CLAUDECODE:-}" ] && exit 0\n[ "${ZUVO_ALLOW_ADHOC:-}" = 1 ] && exit 0\necho "GATE-BLOCK pipeline" >&2\nexit 1\n' > "$HD/pre-push-gate.sh"
      printf '#!/bin/sh\nexit 0\n' > "$HD/refactor-safety-gate.sh" ;;
    recorder)  # gate records exactly what it receives on stdin, exits 0
      printf '#!/bin/sh\ncat > "%s/received.txt"\nexit 0\n' "$TMP" > "$HD/pre-push-gate.sh"
      printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$HD/refactor-safety-gate.sh" ;;
    none) ;;   # no gate scripts at all (fail-open case)
  esac
  chmod +x "$HD"/*.sh 2>/dev/null
  rm -rf "$TMP/r"; mkdir -p "$TMP/r"; cd "$TMP/r"
  git init -q; git config user.email t@t; git config user.name t
  echo x > f; git add f; git commit -q -m base
}

echo "=== pre-push dispatcher (8 cases) ==="
# (1) no local hook + agent env + blocking gate -> blocked with gate token
newenv blocking
err=$(printf '%s\n' "$REFLINE" | ZUVO_AI_RUN=1 "$HD/pre-push" 2>&1); rc=$?
{ [ $rc -ne 0 ] && printf '%s' "$err" | grep -q 'GATE-BLOCK'; } && ok "1 no-local: gate blocks (exit $rc)" || bad "1 (rc=$rc err=$err)"

# (2) local hook exits 7 + passing gates -> local failure propagates
newenv recorder
printf '#!/bin/sh\necho LOCAL-FAIL >&2\nexit 7\n' > .git/hooks/pre-push; chmod +x .git/hooks/pre-push
err=$(printf '%s\n' "$REFLINE" | ZUVO_AI_RUN=1 "$HD/pre-push" 2>&1); rc=$?
{ [ $rc -ne 0 ] && printf '%s' "$err" | grep -q 'LOCAL-FAIL'; } && ok "2 local-fail propagates (exit $rc)" || bad "2 (rc=$rc)"

# (3) local hook passes + blocking gate -> STILL blocked (exec-shadowing is dead)
newenv blocking
printf '#!/bin/sh\nexit 0\n' > .git/hooks/pre-push; chmod +x .git/hooks/pre-push
err=$(printf '%s\n' "$REFLINE" | ZUVO_AI_RUN=1 "$HD/pre-push" 2>&1); rc=$?
{ [ $rc -ne 0 ] && printf '%s' "$err" | grep -q 'GATE-BLOCK'; } && ok "3 gates run AFTER passing local (exit $rc)" || bad "3 (rc=$rc)"

# (4) human env (no AI markers) + G8-honoring gate -> exempt, exit 0
newenv g8
rc=$(printf '%s\n' "$REFLINE" | env -u ZUVO_AI_RUN -u CLAUDECODE -u ZUVO_ALLOW_ADHOC "$HD/pre-push" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 0 ] && ok "4 human exempt (G8 passthrough)" || bad "4 (rc=$rc)"

# (5) empty stdin -> exit 0 and recorder gate receives NOTHING (no synthetic blank ref)
newenv recorder
: > "$TMP/received.txt"
rc=$(printf '' | ZUVO_AI_RUN=1 "$HD/pre-push" >/dev/null 2>&1; echo $?)
{ [ "$rc" -eq 0 ] && [ ! -s "$TMP/received.txt" ]; } && ok "5 empty stdin: no synthetic ref" || bad "5 (rc=$rc size=$(wc -c < "$TMP/received.txt"))"

# (6) gates absent -> fail-open exit 0
newenv none
rc=$(printf '%s\n' "$REFLINE" | ZUVO_AI_RUN=1 "$HD/pre-push" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 0 ] && ok "6 fail-open (no gates)" || bad "6 (rc=$rc)"

# (7) recursion guard: local hook symlinked to the dispatcher itself -> terminates (no fork bomb)
newenv recorder
ln -s "$HD/pre-push" .git/hooks/pre-push
rc=$(printf '%s\n' "$REFLINE" | ZUVO_AI_RUN=1 timeout 10 "$HD/pre-push" >/dev/null 2>&1; echo $?)
[ "$rc" -ne 124 ] && ok "7 recursion terminates (exit $rc, not timeout)" || bad "7 fork bomb (timeout)"

# (8) ZUVO_ALLOW_ADHOC=1 + agent env + blocking-unless-adhoc gate -> escape passes through
newenv g8
rc=$(printf '%s\n' "$REFLINE" | ZUVO_AI_RUN=1 ZUVO_ALLOW_ADHOC=1 "$HD/pre-push" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 0 ] && ok "8 ZUVO_ALLOW_ADHOC passthrough" || bad "8 (rc=$rc)"

# (9) WORKTREE: local hook lives in the COMMON gitdir; dispatcher must find it from the worktree
newenv recorder
printf '#!/bin/sh\necho WT-LOCAL-FAIL >&2\nexit 7\n' > .git/hooks/pre-push; chmod +x .git/hooks/pre-push
git branch -q wt-branch; git worktree add -q "$TMP/wt" wt-branch 2>/dev/null
cd "$TMP/wt"
err=$(printf '%s\n' "$REFLINE" | ZUVO_AI_RUN=1 "$HD/pre-push" 2>&1); rc=$?
{ [ $rc -ne 0 ] && printf '%s' "$err" | grep -q 'WT-LOCAL-FAIL'; } && ok "9 worktree: common-gitdir local hook found + propagates (exit $rc)" || bad "9 (rc=$rc err=$err)"
cd "$TMP/r"; git worktree remove -f "$TMP/wt" 2>/dev/null

echo "=== pre-commit dispatcher (7 cases) ==="
# helper: real refactor-safety-gate + lib into HD (pre-commit cases use the REAL work-gate)
realgate() { cp "$ROOT/hooks/refactor-safety-gate.sh" "$HD/"; mkdir -p "$HD/lib"; cp "$ROOT/hooks/lib/refactor-gate-lib.sh" "$HD/lib/"; chmod +x "$HD"/*.sh "$HD"/lib/*.sh; }

# (1) no local hook + agent env + prove-skipped refactor CONTRACT -> work-gate BLOCKs
newenv none; realgate
mkdir -p zuvo/contracts
printf '{"stage":"PHASE-3","scope_fence":["app.ts"],"prove":{"blind_audit":"skipped","adversarial":"clean","findings_disposition":"none"}}' > zuvo/contracts/refactor-a.json
echo y > app.ts; git add app.ts
err=$(ZUVO_AI_RUN=1 "$HD/pre-commit" 2>&1); rc=$?
{ [ $rc -ne 0 ] && printf '%s' "$err" | grep -q 'BLOCK:'; } && ok "p1 CONTRACT prove-skip blocked (exit $rc)" || bad "p1 (rc=$rc err=$err)"

# (2) local pre-commit exits 7 -> propagates (no exec-swallow)
newenv none; realgate
printf '#!/bin/sh\necho PC-LOCAL-FAIL >&2\nexit 7\n' > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
err=$(ZUVO_AI_RUN=1 "$HD/pre-commit" 2>&1); rc=$?
{ [ $rc -ne 0 ] && printf '%s' "$err" | grep -q 'PC-LOCAL-FAIL'; } && ok "p2 local-fail propagates" || bad "p2 (rc=$rc)"

# (3) local passes + PENDING plan intersecting staged -> plan->execute bind blocks
newenv none; realgate
printf '#!/bin/sh\nexit 0\n' > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
mkdir -p zuvo/plans docs/specs
printf '# plan\n\n### Task 1\n**Files:** app.ts\n' > docs/specs/p-plan.md
printf -- '---\nplan: docs/specs/p-plan.md\nstatus: pending\n---\n' > zuvo/plans/active-plan.md
echo y > app.ts; git add app.ts
err=$(ZUVO_AI_RUN=1 "$HD/pre-commit" 2>&1); rc=$?
{ [ $rc -ne 0 ] && printf '%s' "$err" | grep -q 'zuvo:execute'; } && ok "p3 pending-plan bind blocks after passing local" || bad "p3 (rc=$rc err=$err)"

# (4) human env (no AI markers) -> gate bypasses, exit 0
newenv none; realgate
mkdir -p zuvo/contracts
printf '{"stage":"PHASE-3","scope_fence":["app.ts"],"prove":{"blind_audit":"skipped","adversarial":"clean","findings_disposition":"none"}}' > zuvo/contracts/refactor-a.json
echo y > app.ts; git add app.ts
rc=$(env -u ZUVO_AI_RUN -u CLAUDECODE -u CURSOR_TRACE_ID -u CODEX_SANDBOX -u ANTIGRAVITY_SESSION_ID "$HD/pre-commit" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 0 ] && ok "p4 human exempt" || bad "p4 (rc=$rc)"

# (5) gate absent -> fail-open exit 0
newenv none
rc=$(ZUVO_AI_RUN=1 "$HD/pre-commit" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 0 ] && ok "p5 fail-open (no gate)" || bad "p5 (rc=$rc)"

# (6) recursion guard: local pre-commit symlinked to dispatcher -> terminates
newenv none; realgate
ln -s "$HD/pre-commit" .git/hooks/pre-commit
rc=$(ZUVO_AI_RUN=1 timeout 10 "$HD/pre-commit" >/dev/null 2>&1; echo $?)
[ "$rc" -ne 124 ] && ok "p6 recursion terminates (exit $rc)" || bad "p6 fork bomb"

# (7) HANG-GUARD: stdin = open-but-silent pipe; a re-introduced input=$(cat) would timeout(124)
newenv none; realgate
mkfifo "$TMP/silent.fifo"
( exec 3>"$TMP/silent.fifo"; sleep 8 ) &   # hold the write end open, send nothing
holder=$!
rc=$(ZUVO_AI_RUN=1 timeout 5 "$HD/pre-commit" < "$TMP/silent.fifo" >/dev/null 2>&1; echo $?)
kill $holder 2>/dev/null; rm -f "$TMP/silent.fifo"
[ "$rc" -ne 124 ] && ok "p7 hang-guard: completes with silent-open stdin (exit $rc)" || bad "p7 HANGS on stdin (cat regression)"

# (p8) SYMLINK-INSTALL: dispatcher symlinked INTO .git/hooks (git invokes the symlink) must still
# resolve its OWN dir for the gates (a raw dirname $0 would look in .git/hooks -> silent fail-open)
newenv none; realgate
mkdir -p zuvo/contracts
printf '{"stage":"PHASE-3","scope_fence":["app.ts"],"prove":{"blind_audit":"skipped","adversarial":"clean","findings_disposition":"none"}}' > zuvo/contracts/refactor-a.json
echo y > app.ts; git add app.ts
ln -s "$HD/pre-commit" .git/hooks/pre-commit
err=$(ZUVO_AI_RUN=1 timeout 10 .git/hooks/pre-commit 2>&1); rc=$?
{ [ $rc -ne 0 ] && [ $rc -ne 124 ] && printf '%s' "$err" | grep -q 'BLOCK:'; } && ok "p8 symlink-install still finds gates + blocks (exit $rc)" || bad "p8 (rc=$rc err=$err)"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
