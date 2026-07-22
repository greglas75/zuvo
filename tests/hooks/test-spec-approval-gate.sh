#!/usr/bin/env bash
# Tests spec_approval_gate_check via the REAL entry (hooks/refactor-safety-gate.sh).
#
# Closes the brainstorm->plan hole: zuvo:plan does not STOP on an unapproved spec, it prints
# "Spec exists but is not approved. Using it as reference in inline mode." and proceeds
# (skills/plan/SKILL.md:63). The async path sets `Reviewed` on purpose and expects a HUMAN to
# flip it to Approved before planning — the exact hand-step an agent skips.
#
# Polarity is the load-bearing design decision, so it is tested hard. Of 147 specs carrying a
# status on this machine: 115 Approved, 19 draft/reviewed, the rest FREE-TEXT (`complete (MVP
# shipped)`, `Active — Wave 1`, `Ready for implementation`, `research / proposal`), plus 24
# with no status at all. "Not exactly Approved -> block" would false-block all of those, so
# ONLY an explicit draft/reviewed blocks.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/hooks/refactor-safety-gate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }
export ZUVO_HOME="$TMP/zuvohome"; mkdir -p "$ZUVO_HOME/run-markers"

HUMAN=(env -u ZUVO_AGENT -u ZUVO_AI_RUN -u CLAUDECODE -u CLAUDE_PLUGIN_ROOT \
       -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION -u CODEX_SANDBOX -u CODEX_WORKSPACE \
       -u CODEX_HOME -u CURSOR_TRACE_ID -u CURSOR_AGENT -u GEMINI_CLI -u ANTIGRAVITY \
       -u GEMINI_ANTIGRAVITY -u ANTIGRAVITY_SESSION_ID)

newrepo(){ rm -rf "$TMP/r"; mkdir -p "$TMP/r/zuvo/plans" "$TMP/r/docs/specs"; cd "$TMP/r"
  git init -q; git config user.email t@t; git config user.name t
  printf '#!/bin/sh\nexec "%s" pre-commit\n' "$GATE" > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
  # execution-state so the plan->execute gate is satisfied and cannot mask this gate's result
  mkdir -p zuvo/context
  printf '# Execution State\n<!-- status: in-progress -->\nplan: docs/specs/p-plan.md\n' > zuvo/context/execution-state.md
  printf -- '---\nplan: docs/specs/p-plan.md\nstatus: in-progress\n---\n' > zuvo/plans/active-plan.md; }

# $1 = the plan's **Spec:** value
planwith(){ printf '# plan\n\n**Spec:** %s\n\n### Task 1\n**Files:** app.ts\n' "$1" > docs/specs/p-plan.md; }
# $1 = verbatim status line written into the spec
spec(){ printf '# Spec\n\n%s\n\n> **spec_id:** s-1\n' "$1" > docs/specs/s.md; }

trycommit(){ echo "x$RANDOM" >> "$1"; git add "$1"; git commit -q -m t >/dev/null 2>&1; rc=$?
  [ $rc -ne 0 ] && git reset -q >/dev/null 2>&1; echo $rc; }
AI(){ ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit $1"; }

chmod +x "$GATE" "$ROOT/hooks/lib/refactor-gate-lib.sh" 2>/dev/null

echo "=== the hole: planning from a spec nobody approved ==="
newrepo; planwith "docs/specs/s.md"; spec "> **status:** Reviewed"
[ "$(AI app.ts)" -ne 0 ] && ok "BLOCK: spec still Reviewed (review converged != signed off)" || bad "Reviewed spec sailed through"
spec "> **status:** Draft"
[ "$(AI app.ts)" -ne 0 ] && ok "BLOCK: spec still Draft" || bad "Draft spec sailed through"
spec "> **status:** Approved"
[ "$(AI app.ts)" -eq 0 ] && ok "ALLOW once the user approves it" || bad "Approved spec blocked"

echo "=== dialects seen in the real corpus ==="
newrepo; planwith "docs/specs/s.md"
spec "**status:** Reviewed";        [ "$(AI app.ts)" -ne 0 ] && ok "bold, no blockquote" || bad "bold-only dialect missed"
spec "> **Status:** Draft";         [ "$(AI app.ts)" -ne 0 ] && ok "capitalised key" || bad "capitalised key missed"
spec "Status: Draft — do implementacji"; [ "$(AI app.ts)" -ne 0 ] && ok "plain key + trailing prose" || bad "plain+prose missed"
spec "> **status:** Reviewed  ";    [ "$(AI app.ts)" -ne 0 ] && ok "trailing whitespace" || bad "trailing whitespace missed"

echo "=== polarity: free-text and missing statuses must NOT block ==="
newrepo; planwith "docs/specs/s.md"
for s in "> **Status:** complete (MVP shipped)" \
         "Status: Active — Wave 1 locally integrated" \
         "> **status:** Ready for implementation" \
         "> **Status: research / proposal.** Supersedes the content design of"; do
  spec "$s"
  [ "$(AI app.ts)" -eq 0 ] && ok "free-text status passes: $(printf '%s' "$s" | cut -c1-34)…" || bad "false block on free-text: $s"
done
printf '# Spec\n\nNo status field at all.\n' > docs/specs/s.md
[ "$(AI app.ts)" -eq 0 ] && ok "spec with NO status passes (24 such on disk)" || bad "false block on status-less spec"

echo "=== inline mode is legitimate and must never block ==="
newrepo; spec "> **status:** Draft"
planwith "inline — no spec";  [ "$(AI app.ts)" -eq 0 ] && ok "'inline — no spec' passes" || bad "inline mode blocked"
planwith "none";              [ "$(AI app.ts)" -eq 0 ] && ok "'none' passes" || bad "none blocked"
printf '# plan\n\n### Task 1\n**Files:** app.ts\n' > docs/specs/p-plan.md
[ "$(AI app.ts)" -eq 0 ] && ok "plan with no **Spec:** line passes" || bad "spec-less plan blocked"

echo "=== scope: only files the plan actually claims ==="
newrepo; planwith "docs/specs/s.md"; spec "> **status:** Draft"
[ "$(AI unrelated.ts)" -eq 0 ] && ok "file outside the plan's **Files:** not blocked" || bad "unrelated file blocked"
printf '# plan\n\n**Spec:** docs/specs/s.md\n\nno files declared\n' > docs/specs/p-plan.md
[ "$(AI app.ts)" -eq 0 ] && ok "plan declaring no **Files:** claims nothing" || bad "blocked with no **Files:**"

echo "=== adversarial WARNINGs: shapes found in the real corpus ==="
# 6 real plans on this machine write the field as a dash bullet; the original leading-character
# class skipped them, so the gate silently never fired for those plans.
newrepo; spec "> **status:** Draft"
printf '# plan\n\n- **Spec:** docs/specs/s.md\n\n### Task 1\n**Files:** app.ts\n' > docs/specs/p-plan.md
[ "$(AI app.ts)" -ne 0 ] && ok "dash-bulleted '- **Spec:**' is read" || bad "dash-bulleted field skipped"
# Plans live in docs/specs/ and reference a sibling spec by bare filename.
newrepo; spec "> **status:** Reviewed"; planwith "s.md"
[ "$(AI app.ts)" -ne 0 ] && ok "spec path relative to the plan's own directory resolves" || bad "sibling-relative spec path missed"
# "inline"-prefixed REAL paths must not be mistaken for the no-spec mode.
newrepo; printf '# Spec\n\n> **status:** Draft\n' > docs/specs/inline-editor-spec.md
planwith "docs/specs/inline-editor-spec.md"
[ "$(AI app.ts)" -ne 0 ] && ok "path starting with 'inline' still checked (not no-spec mode)" || bad "inline-prefixed real path waved through"
# ...while the documented no-spec values still pass.
newrepo; spec "> **status:** Draft"; planwith "inline — no spec"
[ "$(AI app.ts)" -eq 0 ] && ok "'inline — no spec' still passes after tightening" || bad "no-spec mode regressed"
# Real corpus: every multi-word Draft/Reviewed status found on disk MEANS unapproved
# ("Draft for approval", "Draft after full agent/adversarial review, ready for human approval")
# — first-word matching is correct here, not an over-block.
newrepo; planwith "docs/specs/s.md"
spec "> **status:** Draft after full agent/adversarial review, ready for human approval"
[ "$(AI app.ts)" -ne 0 ] && ok "multi-word Draft status still blocks (real corpus shape)" || bad "multi-word Draft passed"

echo "=== fail-OPEN ==="
newrepo; planwith "docs/specs/MISSING.md"; spec "> **status:** Draft"
[ "$(AI app.ts)" -eq 0 ] && ok "spec path not on disk -> fail-open" || bad "missing spec file BLOCKED"
newrepo; planwith "docs/specs/s.md"; spec "> **status:** Draft"
rm -f zuvo/plans/active-plan.md
[ "$(AI app.ts)" -eq 0 ] && ok "no active-plan -> gate silent" || bad "blocked without an active plan"
newrepo; planwith "docs/specs/s.md"; spec "> **status:** Draft"
printf -- '---\nplan: docs/specs/p-plan.md\nstatus: completed\n---\n' > zuvo/plans/active-plan.md
[ "$(AI app.ts)" -eq 0 ] && ok "terminal plan status -> gate silent" || bad "completed plan still bound"

echo "=== escapes ==="
newrepo; planwith "docs/specs/s.md"; spec "> **status:** Draft"
[ "$("${HUMAN[@]}" bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "human committer bypass" || bad "human blocked"
newrepo; planwith "docs/specs/s.md"; spec "> **status:** Draft"
[ "$(ZUVO_AI_RUN=1 ZUVO_ALLOW_ADHOC=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "ZUVO_ALLOW_ADHOC escape" || bad "allow-adhoc did not escape"

echo "=== message is actionable ==="
newrepo; planwith "docs/specs/s.md"; spec "> **status:** Reviewed"
echo y >> app.ts; git add app.ts
msg=$(ZUVO_AI_RUN=1 git commit -m t 2>&1 || true); git reset -q >/dev/null 2>&1
printf '%s' "$msg" | grep -q "still 'reviewed'" && ok "names the actual status" || bad "status not named"
printf '%s' "$msg" | grep -q 'docs/specs/s.md' && ok "names the spec file" || bad "spec path missing"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
