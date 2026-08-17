#!/usr/bin/env bash
# Tests scripts/zuvo-phase.sh — the diagnostic that answers "can the gate read this repo's
# state?". Its whole value is catching a BLIND gate, so the BLIND cases are the load-bearing
# ones: a doctor that reports ARMED on an unreadable pointer is worse than no doctor.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PHASE="$ROOT/scripts/zuvo-phase.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }
export ZUVO_HOME="$TMP/zuvohome"; mkdir -p "$ZUVO_HOME/run-markers"

newrepo(){ rm -rf "$TMP/r"; mkdir -p "$TMP/r/zuvo/plans" "$TMP/r/docs/specs"; cd "$TMP/r"
  git init -q; git config user.email t@t; git config user.name t
  printf '# plan\n\n### Task 1\n**Files:** app.ts\n' > docs/specs/p-plan.md; }
run(){ sh "$PHASE" "$@" 2>&1; }
rc(){ sh "$PHASE" "$@" >/dev/null 2>&1; echo $?; }

chmod +x "$PHASE" 2>/dev/null

echo "=== verdicts ==="
newrepo
[ "$(rc doctor)" -eq 0 ] && ok "IDLE: no active-plan.md -> exit 0 (absence is not a fault)" || bad "no-pointer exit"
run doctor | grep -q IDLE && ok "IDLE reported" || bad "IDLE not reported"

printf -- '---\nplan: docs/specs/p-plan.md\nstatus: pending\n---\n' > zuvo/plans/active-plan.md
[ "$(rc doctor)" -eq 0 ] && ok "ARMED: plain dialect -> exit 0" || bad "plain-dialect exit"
run doctor | grep -q ARMED && ok "ARMED reported (plain)" || bad "ARMED not reported (plain)"

printf '# Active Plan\n<!-- status: pending -->\n\nplan: docs/specs/p-plan.md\n' > zuvo/plans/active-plan.md
run doctor | grep -q ARMED && ok "ARMED reported (comment dialect)" || bad "comment dialect misread"

printf '# Active Plan Pointer\n\nstatus: pending\nplan_file: docs/specs/p-plan.md\n' > zuvo/plans/active-plan.md
run doctor | grep -q ARMED && ok "ARMED reported (plan_file alias)" || bad "plan_file alias misread"
run status | grep -q 'plan_file' && ok "status names the plan_file dialect" || bad "dialect not surfaced"

echo "=== BLIND cases (the ones that matter) ==="
printf 'total garbage, no fields\n' > zuvo/plans/active-plan.md
[ "$(rc doctor)" -ne 0 ] && ok "BLIND: unreadable pointer -> non-zero exit" || bad "unreadable pointer reported healthy"
run doctor | grep -q BLIND && ok "BLIND reported for unreadable pointer" || bad "BLIND not reported"

printf -- '---\nplan: docs/specs/GONE.md\nstatus: pending\n---\n' > zuvo/plans/active-plan.md
run doctor | grep -q BLIND && ok "BLIND: plan doc missing on disk" || bad "missing plan doc not flagged"

printf '# plan\nno files declared\n' > docs/specs/p-plan.md
printf -- '---\nplan: docs/specs/p-plan.md\nstatus: pending\n---\n' > zuvo/plans/active-plan.md
run doctor | grep -q BLIND && ok "BLIND: plan declares no **Files:**" || bad "no-**Files:** not flagged"

echo "=== stale in-progress is surfaced, not hidden ==="
newrepo
printf -- '---\nplan: docs/specs/p-plan.md\nstatus: in-progress\n---\n' > zuvo/plans/active-plan.md
run doctor | grep -q STALE && ok "stale in-progress (no execute evidence) flagged" || bad "stale in-progress not flagged"
mkdir -p zuvo/context
printf '# Execution State\n<!-- status: in-progress -->\n' > zuvo/context/execution-state.md
run doctor | grep -q 'live execute run' && ok "live execute run recognized" || bad "live run not recognized"

echo "=== normalize ==="
newrepo
printf '# Active Plan\n<!-- status: pending -->\n\nplan: docs/specs/p-plan.md\nspec_id: keep-me\n' > zuvo/plans/active-plan.md
before=$(cat zuvo/plans/active-plan.md)
run normalize | grep -q 'dry run' && ok "normalize defaults to a dry run" || bad "normalize not dry by default"
[ "$(cat zuvo/plans/active-plan.md)" = "$before" ] && ok "dry run left the file untouched" || bad "dry run WROTE to disk"
run normalize --write >/dev/null
grep -qx 'status: pending' zuvo/plans/active-plan.md && ok "--write emits a plain status: line" || bad "--write did not canonicalize status"
grep -qx 'plan: docs/specs/p-plan.md' zuvo/plans/active-plan.md && ok "--write emits a plain plan: line" || bad "--write did not canonicalize plan"
grep -q 'spec_id: keep-me' zuvo/plans/active-plan.md && ok "--write preserved unrelated fields" || bad "--write DROPPED other fields"
grep -c '^# Active Plan' zuvo/plans/active-plan.md | grep -qx 1 && ok "--write did not duplicate the heading" || bad "heading duplicated"
run normalize | grep -q 'already canonical' && ok "normalize is idempotent" || bad "not idempotent"
[ "$(rc doctor)" -eq 0 ] && ok "repo is ARMED after normalize" || bad "still not armed after normalize"

printf 'garbage\n' > zuvo/plans/active-plan.md
[ "$(rc normalize --write)" -ne 0 ] && ok "normalize refuses an unparseable pointer (non-zero)" || bad "normalize invented fields from garbage"

# CQ-audit FIX-NOW: mv replaces the directory entry, so a symlinked pointer would be silently
# converted to a regular file while the real target went stale.
newrepo
printf '# Active Plan\n<!-- status: pending -->\n\nplan: docs/specs/p-plan.md\n' > "$TMP/shared-pointer.md"
ln -s "$TMP/shared-pointer.md" zuvo/plans/active-plan.md
[ "$(rc normalize --write)" -ne 0 ] && ok "normalize refuses a symlinked pointer" || bad "normalize clobbered a symlink"
[ -L zuvo/plans/active-plan.md ] && ok "symlink left intact" || bad "symlink replaced by a regular file"

# CQ-audit FIX-NOW: a fresh temp file carries umask permissions; mv keeps the SOURCE's mode, so
# a restrictive pointer silently became world-readable.
newrepo
printf '# Active Plan\n<!-- status: pending -->\n\nplan: docs/specs/p-plan.md\n' > zuvo/plans/active-plan.md
chmod 600 zuvo/plans/active-plan.md
run normalize --write >/dev/null 2>&1
mode=$(stat -f %Lp zuvo/plans/active-plan.md 2>/dev/null || stat -c %a zuvo/plans/active-plan.md 2>/dev/null)
[ "$mode" = "600" ] && ok "normalize --write preserved file mode ($mode)" || bad "mode changed 600 -> $mode"

echo "=== fleet sweep ==="
mkdir -p "$TMP/fleet/a" "$TMP/fleet/b"
( cd "$TMP/fleet/a" && git init -q && mkdir -p zuvo/plans docs/specs \
  && printf '# plan\n\n### T\n**Files:** x.ts\n' > docs/specs/p.md \
  && printf -- '---\nplan: docs/specs/p.md\nstatus: pending\n---\n' > zuvo/plans/active-plan.md )
( cd "$TMP/fleet/b" && git init -q && mkdir -p zuvo/plans && printf 'junk\n' > zuvo/plans/active-plan.md )
cd "$TMP/r"
out=$(ZUVO_PHASE_ROOTS="$TMP/fleet/*" run doctor --all)
printf '%s' "$out" | grep -q 'armed: 1' && ok "sweep counts the armed repo" || bad "sweep armed count"
printf '%s' "$out" | grep -q 'blind: 1' && ok "sweep counts the blind repo" || bad "sweep blind count"
[ "$(ZUVO_PHASE_ROOTS="$TMP/fleet/*" rc doctor --all)" -ne 0 ] && ok "sweep exits non-zero when any repo is BLIND" || bad "sweep hid a blind repo in its exit code"

# A linked worktree carries `.git` as a FILE — an earlier `[ -d ]` test silently skipped 6 real
# worktrees, and a sweep that quietly omits repos reads as "all clear".
( cd "$TMP/fleet/a" && git add -A >/dev/null 2>&1; git -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
  git worktree add -q "$TMP/fleet/wt" -b wtbranch >/dev/null 2>&1 )
if [ -f "$TMP/fleet/wt/.git" ]; then
  out=$(ZUVO_PHASE_ROOTS="$TMP/fleet/*" run doctor --all)
  printf '%s' "$out" | grep -q 'armed: 2' && ok "sweep includes linked worktrees (.git is a file)" || bad "linked worktree skipped by sweep"
else
  echo "  - worktree fixture unavailable, skipped"
fi

# CQ-audit FIX-NOW: a repo whose PATH contains a space used to vanish from the sweep entirely —
# counted in neither armed, blind, nor idle — because the pattern was expanded a second time
# under the default IFS. Silent omission is the one failure a diagnostic must never have.
mkdir -p "$TMP/spacefleet/My Project/zuvo/plans" "$TMP/spacefleet/My Project/docs/specs"
( cd "$TMP/spacefleet/My Project" && git init -q \
  && printf '# plan\n\n### T\n**Files:** x.ts\n' > docs/specs/p.md \
  && printf 'status: pending\nplan: docs/specs/p.md\n' > zuvo/plans/active-plan.md )
out=$(ZUVO_PHASE_ROOTS="$TMP/spacefleet/*" run doctor --all)
printf '%s' "$out" | grep -q 'armed: 1' && ok "repo path containing a space is swept, not dropped" || bad "space-named repo vanished from sweep"

echo "=== usage ==="
[ "$(rc bogus-command)" -eq 2 ] && ok "unknown command -> exit 2" || bad "unknown command exit code"


echo "=== prose **Files:** must not read as ARMED (B-gate-4) ==="
# Six repos share a spec whose **Files:** lines are prose. Every fragment counted as a declared
# path, so the doctor said ARMED with a file count the gate could never match. False confidence
# is worse than BLIND: BLIND tells you to fix the pointer, an inflated ARMED says all is well.
newrepo
printf 'status: pending\nplan: docs/specs/p-plan.md\n' > zuvo/plans/active-plan.md

printf '# plan\n\n### Task 1\n**Files:** src/a.ts, src/b.ts\n' > docs/specs/p-plan.md
_o=$(bash "$PHASE" doctor 2>&1)
printf '%s' "$_o" | grep -q 'ARMED (' && printf '%s' "$_o" | grep -q 'files=2' \
  && ok "pure paths -> ARMED with the real count" || bad "pure paths should be ARMED files=2 (got: $(printf '%s' "$_o" | grep -m1 ARMED))"

printf '# plan\n\n### Task 1\n**Files:** src/a.ts, the reporting module and its helpers, src/b.ts\n' > docs/specs/p-plan.md
_o=$(bash "$PHASE" doctor 2>&1)
printf '%s' "$_o" | grep -q 'ARMED-PARTIAL' && printf '%s' "$_o" | grep -q 'files=2 of 3' \
  && ok "mixed paths+prose -> ARMED-PARTIAL, both counts shown" || bad "mixed should be ARMED-PARTIAL 2 of 3 (got: $(printf '%s' "$_o" | grep -m1 -E 'ARMED|BLIND'))"

printf '# plan\n\n### Task 1\n**Files:** the reporting module, all of its helpers\n' > docs/specs/p-plan.md
_o=$(bash "$PHASE" doctor 2>&1)
printf '%s' "$_o" | grep -q 'BLIND' && printf '%s' "$_o" | grep -q 'none path-shaped' \
  && ok "prose only -> BLIND, not a falsely confident ARMED" || bad "prose-only should be BLIND (got: $(printf '%s' "$_o" | grep -m1 -E 'ARMED|BLIND'))"

printf '# plan\n\n### Task 1\n**Files:** the reporting module, all of its helpers\n' > docs/specs/p-plan.md
_o=$(bash "$PHASE" doctor 2>&1)
printf '%s' "$_o" | grep -q 'prose' && ! printf '%s' "$_o" | grep -q 'normalize --write' \
  && ok "prose BLIND advises rewriting **Files:**, NOT the pointer fix that cannot help it" \
  || bad "prose BLIND still advises normalize --write — that rewrites the pointer, not the plan; reader loops"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
