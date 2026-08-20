#!/usr/bin/env bash
# Proves the control-block gate does BOTH halves of its job: it blocks an
# unmeasured control edit, and it stays out of the way of everything else.
# A gate that only ever passes is indistinguishable from a gate that is broken,
# which is why the red case is asserted first.
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/hooks/control-block-bench-gate.sh"
PASS=0; FAIL=0
ok()   { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

setup_repo() {
  rm -rf "$WORK/repo"; mkdir -p "$WORK/repo/skills/write-tests" "$WORK/repo/memory/bench"
  cd "$WORK/repo" || exit 1
  git init -q .; git config user.email t@t; git config user.name t
  cat > skills/write-tests/SKILL.md <<'EOF'
# zuvo:write-tests

### Step 2: Write

**UNIVERSAL WRITER ISOLATION (every file, every tier).** Writing executes in a
FRESH context whose entire payload is: contract + source + runner command.

## Notes

Some prose that steers nothing.
EOF
  git add -A; git commit -qm base
  git branch -q -M main
  git remote add origin "$WORK/remote" 2>/dev/null || true
  REMOTE_SHA=$(git rev-parse HEAD)
}

# stdin in git pre-push shape; agent env forced so the gate does not exempt us
run_hook() {
  printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$REMOTE_SHA" \
    | CLAUDE_CODE_ENTRYPOINT=cli bash "$HOOK" 2>"$WORK/err"; echo $?
}

echo "== control-block bench gate =="

# 1. control block edited, no bench record -> BLOCK
setup_repo
sed -i.bak 's/contract + source + runner command/contract + source + runner command + stack includes/' \
  skills/write-tests/SKILL.md && rm -f skills/write-tests/SKILL.md.bak
git commit -qam "edit control block"
rc=$(run_hook)
[ "$rc" = "1" ] && ok "blocks an unmeasured control-block edit" \
                || bad "did NOT block an unmeasured control-block edit (rc=$rc)"
grep -q "control-block gate" "$WORK/err" 2>/dev/null \
  && ok "explains itself on stderr" || bad "no explanation printed"

# 2. same edit, bench record naming the post-edit blob -> PASS
blob=$(git rev-parse "HEAD:skills/write-tests/SKILL.md" | cut -c1-12)
cat > memory/bench/payload.md <<REC
# bench
blob $blob

| arm | kill | billed | turns |
|---|---|---|---|
| before | 87.9% | 941k | 46 |
| after | 88.9% | 3440k | 128 |
REC
git add -A; git commit -qm "bench record"   # committed on purpose: the gate reads the PUSHED tree
rc=$(run_hook)
[ "$rc" = "0" ] && ok "passes once a bench record names the post-edit blob" \
                || bad "still blocked despite bench evidence (rc=$rc)"

# 3. a bench record for a DIFFERENT blob must not satisfy a new edit
sed -i.bak 's/+ stack includes/+ stack includes and more/' skills/write-tests/SKILL.md \
  && rm -f skills/write-tests/SKILL.md.bak
git commit -qam "second control edit, stale evidence"
rc=$(run_hook)
[ "$rc" = "1" ] && ok "stale evidence does not carry to a new edit (content-keyed)" \
                || bad "stale bench record satisfied a different edit (rc=$rc)"

# 4. non-control prose in the same file -> PASS
setup_repo
sed -i.bak 's/Some prose that steers nothing./Some prose, reworded./' skills/write-tests/SKILL.md \
  && rm -f skills/write-tests/SKILL.md.bak
git commit -qam "reword prose"
rc=$(run_hook)
[ "$rc" = "0" ] && ok "ignores edits outside a control block" \
                || bad "blocked a harmless prose edit (rc=$rc)"

# 5. human push (no agent env) -> PASS even unmeasured
setup_repo
sed -i.bak 's/contract + source + runner command/contract + source + runner + X/' \
  skills/write-tests/SKILL.md && rm -f skills/write-tests/SKILL.md.bak
git commit -qam "human control edit"
rc=$(printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$REMOTE_SHA" \
      | env -u CLAUDECODE -u CLAUDE_PLUGIN_ROOT -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION \
            -u CODEX_WORKSPACE -u CODEX_SANDBOX -u CODEX_HOME -u CURSOR_AGENT -u CURSOR_TRACE_ID \
            -u GEMINI_CLI -u ANTIGRAVITY -u GEMINI_ANTIGRAVITY -u ANTIGRAVITY_SESSION_ID \
            -u ZUVO_AI_RUN -u ZUVO_AGENT bash "$HOOK" >/dev/null 2>&1; echo $?)
[ "$rc" = "0" ] && ok "exempts human pushes" || bad "blocked a human push (rc=$rc)"

# 6. explicit override -> PASS, and is logged
rc=$(printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$REMOTE_SHA" \
      | CLAUDE_CODE_ENTRYPOINT=cli ZUVO_ALLOW_UNMEASURED_CONTROL_EDIT=1 ZUVO_HOME="$WORK" \
        bash "$HOOK" >/dev/null 2>&1; echo $?)
[ "$rc" = "0" ] && ok "honours the attributable override" || bad "override ignored (rc=$rc)"
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z control-block-gate bypass [0-9a-f]+$' \
  "$WORK/gate-bypass.log" 2>/dev/null \
  && ok "override log carries timestamp + reason + sha" \
  || bad "override log content wrong: $(head -1 "$WORK/gate-bypass.log" 2>/dev/null)"

# 8. NEW BRANCH (remote sha all-zeros) must still be inspected.
#    Both adversarial providers found this independently: a lone SHA is not a range,
#    so `git diff --name-only <sha>` compared the commit to the working tree and a
#    clean tree made the gate pass a branch it never looked at.
setup_repo
git checkout -q -b feat                            # a branch that actually diverges from main
sed -i.bak 's/contract + source + runner command/contract + source + runner + newbranch/' \
  skills/write-tests/SKILL.md && rm -f skills/write-tests/SKILL.md.bak
git commit -qam "control edit on a new branch"
rc=$(printf 'refs/heads/feat %s refs/heads/feat 0000000000000000000000000000000000000000\n' \
      "$(git rev-parse HEAD)" | CLAUDE_CODE_ENTRYPOINT=cli bash "$HOOK" >/dev/null 2>&1; echo $?)
[ "$rc" = "1" ] && ok "inspects a new-branch push (zero remote sha)" \
                || bad "new-branch push escaped the gate (rc=$rc)"

# 9. evidence must live in the PUSHED TREE, not just on disk
setup_repo
sed -i.bak 's/contract + source + runner command/contract + source + runner + uncommitted/' \
  skills/write-tests/SKILL.md && rm -f skills/write-tests/SKILL.md.bak
git commit -qam "control edit"
blob=$(git rev-parse "HEAD:skills/write-tests/SKILL.md" | cut -c1-12)
cat > memory/bench/uncommitted.md <<REC
# bench
blob $blob

| arm | kill | billed | turns |
|---|---|---|---|
| before | 80% | 100k | 10 |
| after | 85% | 120k | 12 |
REC
rc=$(run_hook)                                     # deliberately NOT committed
[ "$rc" = "1" ] && ok "an uncommitted bench record is not evidence" \
                || bad "working-tree-only record satisfied the gate (rc=$rc)"

# 10. a record must carry the metrics, not merely the blob id
setup_repo
sed -i.bak 's/contract + source + runner command/contract + source + runner + placeholder/' \
  skills/write-tests/SKILL.md && rm -f skills/write-tests/SKILL.md.bak
git commit -qam "control edit"
blob=$(git rev-parse "HEAD:skills/write-tests/SKILL.md" | cut -c1-12)
printf 'blob %s\n' "$blob" > memory/bench/placeholder.md
git add -A; git commit -qm "placeholder evidence"
rc=$(run_hook)
[ "$rc" = "1" ] && ok "a blob-only placeholder is not evidence" \
                || bad "placeholder record satisfied the gate (rc=$rc)"

# 11. prose that merely MENTIONS a control-block name is not a control edit
setup_repo
printf '\nSome prose about Stack detection in passing.\n' >> skills/write-tests/SKILL.md
git commit -qam "prose mentioning a control-block name"
rc=$(run_hook)
[ "$rc" = "0" ] && ok "prose naming a control block is not a control edit" \
                || bad "false positive on prose mentioning a control block (rc=$rc)"

# 12. MULTI-REF push: a clean first ref must not escort a dirty second one through.
#     git gives no ordering guarantee, so `head -1` was a coin flip on which ref got checked.
setup_repo
git checkout -q -b clean_branch
printf '\nHarmless note.\n' >> skills/write-tests/SKILL.md
git commit -qam "clean ref"
CLEAN_SHA=$(git rev-parse HEAD)
git checkout -q main
git checkout -q -b dirty_branch
sed -i.bak 's/contract + source + runner command/contract + source + runner + multiref/' \
  skills/write-tests/SKILL.md && rm -f skills/write-tests/SKILL.md.bak
git commit -qam "unmeasured control edit on a second ref"
rc=$( { printf 'refs/heads/clean %s refs/heads/clean %s\n' "$CLEAN_SHA" "$REMOTE_SHA"
        printf 'refs/heads/dirty %s refs/heads/dirty %s\n' "$(git rev-parse HEAD)" "$REMOTE_SHA"
      } | CLAUDE_CODE_ENTRYPOINT=cli bash "$HOOK" >/dev/null 2>&1; echo $?)
[ "$rc" = "1" ] && ok "checks every ref of a multi-ref push" \
                || bad "a later ref escaped the gate (rc=$rc)"

# 13. shared/includes/*.md is a gated target too, not only skills/*/SKILL.md
setup_repo
mkdir -p shared/includes
cat > shared/includes/test-contract.md <<'INC'
# Test contract

## Mandatory File Loading

Load the contract, the source, and the runner command.
INC
git add -A; git commit -qm "add an include"
REMOTE_SHA=$(git rev-parse HEAD)
sed -i.bak 's/Load the contract, the source, and the runner command./Load the contract, the source, the runner command, and the stack files./' \
  shared/includes/test-contract.md && rm -f shared/includes/test-contract.md.bak
git commit -qam "control edit inside an include"
rc=$(run_hook)
[ "$rc" = "1" ] && ok "gates shared/includes/*.md, not only skills/*/SKILL.md" \
                || bad "an include's control block was not gated (rc=$rc)"

# 14. genuinely empty stdin takes a different path than malformed stdin
setup_repo
rc=$(printf '' | CLAUDE_CODE_ENTRYPOINT=cli bash "$HOOK" >/dev/null 2>&1; echo $?)
[ "$rc" = "0" ] && ok "fails open on empty stdin" || bad "blocked on empty stdin (rc=$rc)"

# 7. fail-open outside a git repo
rc=$(cd "$WORK" && printf 'x\n' | CLAUDE_CODE_ENTRYPOINT=cli bash "$HOOK" >/dev/null 2>&1; echo $?)
[ "$rc" = "0" ] && ok "fails open outside a repo" || bad "did not fail open (rc=$rc)"

echo
echo "=== RESULT ==="
[ "$FAIL" -eq 0 ] && { echo "ALL PASS ($PASS)"; exit 0; }
echo "FAILURES: $FAIL of $((PASS+FAIL))"; exit 1
