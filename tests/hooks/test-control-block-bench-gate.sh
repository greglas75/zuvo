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
  cd "$WORK/repo"
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
printf '# bench\nblob %s\nkill 87.9%%/88.9%% billed 941k/3440k turns 46/128\n' "$blob" \
  > memory/bench/payload.md
git add -A; git commit -qm "bench record"
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
[ -s "$WORK/gate-bypass.log" ] && ok "override is logged" || bad "override not logged"

# 7. fail-open outside a git repo
rc=$(cd "$WORK" && printf 'x\n' | CLAUDE_CODE_ENTRYPOINT=cli bash "$HOOK" >/dev/null 2>&1; echo $?)
[ "$rc" = "0" ] && ok "fails open outside a repo" || bad "did not fail open (rc=$rc)"

echo
echo "=== RESULT ==="
[ "$FAIL" -eq 0 ] && { echo "ALL PASS ($PASS)"; exit 0; }
echo "FAILURES: $FAIL of $((PASS+FAIL))"; exit 1
