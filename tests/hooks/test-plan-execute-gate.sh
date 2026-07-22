#!/usr/bin/env bash
# Tests plan_execute_gate_check via the REAL entry (hooks/refactor-safety-gate.sh).
# Mechanism cases + DIALECT matrix + in-progress corroboration + human-bypass + ALLOW_ADHOC
# + proof BOTH checks run in the entry.
#
# DIALECT MATRIX is load-bearing: the original fixture wrote only the plain `status:` line —
# the dialect the READER already understood — so 12 green tests coexisted with a gate that was
# blind on 8 of 19 real repos (session-state.md documents the `<!-- status: -->` form, and
# `plan_file:` occurs in the wild). A fixture must speak the WRITER's dialects.
set -u
# Neutralize the developer's real git config. This machine sets a global
# core.hooksPath (the installed zuvo dispatcher), so without this a fixture repo
# inherits an OLD installed copy of the gate and can pass for the wrong reason.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/hooks/refactor-safety-gate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

# Run-markers must never be read from the developer's real ~/.zuvo during a test.
export ZUVO_HOME="$TMP/zuvohome"; mkdir -p "$ZUVO_HOME/run-markers"

# Every var _is_agent_env() inspects — a "human" fixture must clear ALL of them, otherwise it
# is really testing "agent with some vars missing" (this is what silently broke when the
# detection list was widened to match pipeline-gate-lib.sh's).
HUMAN=(env -u ZUVO_AGENT -u ZUVO_AI_RUN -u CLAUDECODE -u CLAUDE_PLUGIN_ROOT \
       -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION -u CODEX_SANDBOX -u CODEX_WORKSPACE \
       -u CODEX_HOME -u CURSOR_TRACE_ID -u CURSOR_AGENT -u GEMINI_CLI -u ANTIGRAVITY \
       -u GEMINI_ANTIGRAVITY -u ANTIGRAVITY_SESSION_ID)

newrepo(){ rm -rf "$TMP/r"; mkdir -p "$TMP/r/zuvo/plans" "$TMP/r/docs/specs" "$TMP/r/zuvo/contracts"; cd "$TMP/r"
  git init -q; git config user.email t@t; git config user.name t; }
install_hook(){ printf '#!/bin/sh\nexec "%s" pre-commit\n' "$GATE" > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit; }

# --- active-plan.md writers, one per dialect seen in the fleet -------------------------
ap(){ printf -- '---\nplan: %s\nstatus: %s\n---\n' "$1" "$2" > zuvo/plans/active-plan.md; }        # YAML frontmatter
ap_comment(){ printf '# Active Plan\n<!-- status: %s -->\n\nplan: %s\ntasks: 3\n' "$2" "$1" > zuvo/plans/active-plan.md; }  # session-state.md's documented form
ap_planfile(){ printf '# Active Plan Pointer\n\nstatus: %s\nplan_file: %s\n' "$2" "$1" > zuvo/plans/active-plan.md; }        # ResearchShieldNew form

planfiles(){ printf '# plan\n\n### Task 1\n**Files:** %s\n' "$1" > docs/specs/p-plan.md; }
# corroboration fixtures
es(){ mkdir -p zuvo/context; printf '# Execution State\n<!-- status: %s -->\n\nplan: docs/specs/p-plan.md\n' "$1" > zuvo/context/execution-state.md; }
es_plain(){ mkdir -p zuvo/context; printf '# Execution State\n\nstatus: %s\nplan: docs/specs/p-plan.md\n' "$1" > zuvo/context/execution-state.md; }
marker(){ printf 'start_ts=x\nskill=execute\nrepo_root=%s\n' "$(git rev-parse --show-toplevel)" \
  > "$ZUVO_HOME/run-markers/execute-t-abc1234-1-1.marker"; }

# Unstage on a blocked commit so the next case starts clean (a blocked commit leaves its file
# in the index, which used to cascade a single failure into the following assertions).
trycommit(){ echo "x$RANDOM" >> "$1"; git add "$1"; git commit -q -m t >/dev/null 2>&1; rc=$?
  [ $rc -ne 0 ] && git reset -q >/dev/null 2>&1; echo $rc; }
AI(){ ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit $1"; }

chmod +x "$GATE" "$ROOT/hooks/lib/refactor-gate-lib.sh" 2>/dev/null

echo "=== plan→execute gate (6 mechanism cases) ==="
newrepo; install_hook; planfiles "app.ts"
ap docs/specs/p-plan.md pending
[ "$(AI app.ts)" -ne 0 ] && ok "1 BLOCK pending+planfile" || bad "1 BLOCK"
ap docs/specs/p-plan.md in-progress; es in-progress
[ "$(AI app.ts)" -eq 0 ] && ok "2 ALLOW in-progress + live execution-state" || bad "2 in-progress"
rm -rf zuvo/context
ap docs/specs/p-plan.md pending
[ "$(AI other.ts)" -eq 0 ] && ok "3 ALLOW pending+non-plan-file" || bad "3 non-plan-file"
rm -f zuvo/plans/active-plan.md
[ "$(AI app.ts)" -eq 0 ] && ok "4 ALLOW no active-plan" || bad "4 no-plan"
ap docs/specs/MISSING-plan.md pending
[ "$(AI app.ts)" -eq 0 ] && ok "5 fail-OPEN missing plan doc" || bad "5 missing-doc"
printf '# plan\nno files\n' > docs/specs/p-plan.md; ap docs/specs/p-plan.md pending
[ "$(AI app.ts)" -eq 0 ] && ok "6 fail-OPEN empty **Files:**" || bad "6 empty-files"

echo "=== DIALECT MATRIX: every writer dialect must be readable by the gate ==="
for d in ap ap_comment ap_planfile; do
  newrepo; install_hook; planfiles "app.ts"; $d docs/specs/p-plan.md pending
  [ "$(AI app.ts)" -ne 0 ] && ok "BLOCK pending via $d" || bad "$d pending not read (gate blind)"
  $d docs/specs/p-plan.md completed
  [ "$(AI app.ts)" -eq 0 ] && ok "ALLOW completed via $d" || bad "$d completed misread"
done
newrepo; install_hook; planfiles "app.ts"
printf '# Active Plan\n<!-- status: pending -->\r\n\r\nplan: docs/specs/p-plan.md\r\n' > zuvo/plans/active-plan.md
[ "$(AI app.ts)" -ne 0 ] && ok "BLOCK comment-dialect with CRLF" || bad "CRLF comment-dialect bypass"

echo "=== in-progress corroboration (the earned exemption) ==="
newrepo; install_hook; planfiles "app.ts"; ap docs/specs/p-plan.md in-progress
[ "$(AI app.ts)" -ne 0 ] && ok "BLOCK in-progress with NO evidence (flip-and-handroll)" || bad "uncorroborated in-progress allowed"
es in-progress
[ "$(AI app.ts)" -eq 0 ] && ok "ALLOW in-progress + execution-state (comment dialect)" || bad "comment-dialect execution-state not honored"
rm -rf zuvo/context; es_plain in-progress
[ "$(AI app.ts)" -eq 0 ] && ok "ALLOW in-progress + execution-state (PLAIN dialect)" || bad "plain-dialect execution-state not honored"
rm -rf zuvo/context; es completed
[ "$(AI app.ts)" -ne 0 ] && ok "BLOCK in-progress + execution-state says completed" || bad "completed execution-state wrongly corroborated"
rm -rf zuvo/context; marker
[ "$(AI app.ts)" -eq 0 ] && ok "ALLOW in-progress + fresh run-marker" || bad "fresh marker not honored"
touch -t 200001010000 "$ZUVO_HOME/run-markers/execute-t-abc1234-1-1.marker"
[ "$(AI app.ts)" -ne 0 ] && ok "BLOCK in-progress + STALE run-marker" || bad "stale marker still exempts"
printf 'repo_root=/some/other/repo\n' > "$ZUVO_HOME/run-markers/execute-t-abc1234-1-1.marker"
[ "$(AI app.ts)" -ne 0 ] && ok "BLOCK in-progress + marker for a DIFFERENT repo" || bad "foreign marker exempts"
rm -f "$ZUVO_HOME/run-markers/"*.marker

# CQ-audit CRITICAL: ZUVO_OUTPUT_DIR is a documented global override, so a stale export aimed at
# another project's zuvo/ must NOT corroborate this repo. It previously did — forging
# "in-progress" and re-opening the bypass this whole check exists to close.
mkdir -p "$TMP/foreign/zuvo/context"
printf '# Execution State\n<!-- status: in-progress -->\n' > "$TMP/foreign/zuvo/context/execution-state.md"
r=$(ZUVO_AI_RUN=1 ZUVO_OUTPUT_DIR="$TMP/foreign/zuvo" bash -c "$(declare -f trycommit); trycommit app.ts")
[ "$r" -ne 0 ] && ok "BLOCK in-progress + FOREIGN ZUVO_OUTPUT_DIR (no cross-repo forgery)" || bad "foreign ZUVO_OUTPUT_DIR corroborates (bypass)"
# ...but an in-repo ZUVO_OUTPUT_DIR is still honored, so the documented override keeps working.
mkdir -p "$TMP/r/custom-out/context"
printf '# Execution State\n<!-- status: in-progress -->\n' > "$TMP/r/custom-out/context/execution-state.md"
r=$(ZUVO_AI_RUN=1 ZUVO_OUTPUT_DIR="$TMP/r/custom-out" bash -c "$(declare -f trycommit); trycommit app.ts")
[ "$r" -eq 0 ] && ok "ALLOW in-progress + in-repo ZUVO_OUTPUT_DIR (override still works)" || bad "in-repo ZUVO_OUTPUT_DIR ignored"

echo "=== adversarial CRITICALs: state must be FRESH and for THIS plan ==="
# A crashed run leaves execution-state at in-progress forever. Status alone would authenticate
# every future commit indefinitely; a live run rewrites this file after each task, so mtime is
# the discriminator.
newrepo; install_hook; planfiles "app.ts"; ap docs/specs/p-plan.md in-progress; es in-progress
touch -t 202001010000 zuvo/context/execution-state.md
[ "$(AI app.ts)" -ne 0 ] && ok "BLOCK in-progress + STALE execution-state (no forever-auth)" || bad "stale execution-state authenticates forever"
# A state file left over from a DIFFERENT plan says nothing about this one.
es in-progress; sed -i.bak 's|plan: docs/specs/p-plan.md|plan: docs/specs/SOME-OTHER-plan.md|' zuvo/context/execution-state.md; rm -f zuvo/context/*.bak
[ "$(AI app.ts)" -ne 0 ] && ok "BLOCK in-progress + execution-state for a DIFFERENT plan" || bad "cross-plan state corroborates"
es in-progress
[ "$(AI app.ts)" -eq 0 ] && ok "ALLOW in-progress + fresh state for THIS plan" || bad "matching fresh state rejected"
# Legacy state files carry no plan: field — must still corroborate rather than fail closed.
mkdir -p zuvo/context; printf '# Execution State\n<!-- status: in-progress -->\n' > zuvo/context/execution-state.md
[ "$(AI app.ts)" -eq 0 ] && ok "ALLOW legacy execution-state with no plan: field" || bad "legacy state fails closed"

echo "=== adversarial: greedy HTML-comment capture ==="
newrepo; install_hook; planfiles "app.ts"
printf '# Active Plan\n<!-- status: pending -->\n<!-- plan: docs/specs/p-plan.md --> <!-- note: x -->\n' > zuvo/plans/active-plan.md
[ "$(AI app.ts)" -ne 0 ] && ok "BLOCK when plan: comment is followed by another comment" || bad "greedy capture polluted the plan path"

echo "=== adversarial findings: clock skew + sibling brace groups ==="
# A FUTURE-dated marker (clock step back / NTP correction / forged file) must NOT read as live:
# a negative age is always <= a positive grace, which would be an unbounded bypass window.
newrepo; install_hook; planfiles "app.ts"; ap docs/specs/p-plan.md in-progress; marker
touch -t 209901010000 "$ZUVO_HOME/run-markers/execute-t-abc1234-1-1.marker"
[ "$(AI app.ts)" -ne 0 ] && ok "BLOCK in-progress + FUTURE-dated marker (no clock-skew bypass)" || bad "future marker exempts (unbounded window)"
rm -f "$ZUVO_HOME/run-markers/"*.marker
# Sibling brace groups must stay VERBATIM (fail-open), never half-expanded into a path that
# matches nothing while appearing handled.
newrepo; install_hook
printf '# plan\n\n### Task 1\n**Files:** `apps/{web,api}/src/{a.ts,b.ts}`\n' > docs/specs/p-plan.md
ap docs/specs/p-plan.md pending; mkdir -p apps/web/src apps/api/src
[ "$(AI apps/web/src/a.ts)" -eq 0 ] && ok "sibling brace groups fail OPEN, not half-expanded" || bad "half-expanded sibling group produced a match"

echo "=== fail-OPEN contract (a gate must never brick a commit) ==="
newrepo; install_hook; planfiles "app.ts"
printf 'garbage with no recognizable fields at all\n' > zuvo/plans/active-plan.md
[ "$(AI app.ts)" -eq 0 ] && ok "fail-OPEN unparseable active-plan" || bad "unparseable active-plan BLOCKED (contract broken)"
printf -- '---\nplan: docs/specs/p-plan.md\nstatus: weird-unknown-state\n---\n' > zuvo/plans/active-plan.md
[ "$(AI app.ts)" -eq 0 ] && ok "fail-OPEN unknown status value" || bad "unknown status BLOCKED (contract broken)"

echo "=== brace-group **Files:** expands to real paths (no bare-basename false match) ==="
newrepo; install_hook
printf '# plan\n\n### Task 1\n**Files:** `apps/api/{package.json,tsconfig.json}`, `README.md`\n' > docs/specs/p-plan.md
ap docs/specs/p-plan.md pending
mkdir -p apps/api
[ "$(AI tsconfig.json)" -eq 0 ] && ok "root tsconfig.json NOT matched by apps/api/{...} group" || bad "bare-basename false match (brace split)"
[ "$(AI apps/api/tsconfig.json)" -ne 0 ] && ok "apps/api/tsconfig.json IS matched (prefix preserved)" || bad "brace member lost its prefix"

echo "=== human-bypass + ALLOW_ADHOC (must survive every new path) ==="
newrepo; install_hook; planfiles "app.ts"; ap docs/specs/p-plan.md pending
[ "$("${HUMAN[@]}" bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "human committer bypass (pending)" || bad "human-bypass pending"
ap docs/specs/p-plan.md in-progress
[ "$("${HUMAN[@]}" bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "human committer bypass (uncorroborated in-progress)" || bad "human-bypass in-progress"
newrepo; install_hook; planfiles "app.ts"; ap docs/specs/p-plan.md pending
[ "$(ZUVO_AI_RUN=1 ZUVO_ALLOW_ADHOC=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "ZUVO_ALLOW_ADHOC escape (pending)" || bad "allow-adhoc pending"
ap docs/specs/p-plan.md in-progress
[ "$(ZUVO_AI_RUN=1 ZUVO_ALLOW_ADHOC=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "ZUVO_ALLOW_ADHOC escape (uncorroborated in-progress)" || bad "allow-adhoc in-progress"

echo "=== widened agent detection: EVERY harness var alone must count as an AI run ==="
# All 15, not a subset. An audit mutation that broke 5 of the untested branches passed the whole
# suite: `HUMAN` unsets them collectively, and every agent case sets ZUVO_AI_RUN, so a single
# dead branch was invisible. A dead branch means that harness silently bypasses the gate.
for v in ZUVO_AGENT ZUVO_AI_RUN CLAUDECODE CLAUDE_PLUGIN_ROOT CLAUDE_CODE_ENTRYPOINT \
         CLAUDE_CODE_SESSION CODEX_SANDBOX CODEX_WORKSPACE CODEX_HOME CURSOR_TRACE_ID \
         CURSOR_AGENT GEMINI_CLI ANTIGRAVITY GEMINI_ANTIGRAVITY ANTIGRAVITY_SESSION_ID; do
  newrepo; install_hook; planfiles "app.ts"; ap docs/specs/p-plan.md pending
  r=$("${HUMAN[@]}" "$v=1" bash -c "$(declare -f trycommit); trycommit app.ts")
  [ "$r" -ne 0 ] && ok "$v alone => AI run (gate armed)" || bad "$v alone read as human (silent bypass)"
done

echo "=== drift guard: the HUMAN fixture must track _is_agent_env's var list ==="
# Structural, not hand-maintained: extract the var names from the production function and diff
# them against the fixture. Catches BOTH directions — a var added to the lib but not the fixture
# (human cases would silently stop being human) and one removed from the lib but still unset here.
LIB_VARS=$(sed -n '/^_is_agent_env()/,/^}/p' "$ROOT/hooks/lib/refactor-gate-lib.sh" \
  | grep -oE '\$\{[A-Z][A-Z0-9_]*' | sed 's/^\${//' | sort -u)
FIX_VARS=$(printf '%s\n' "${HUMAN[@]}" | grep -xE '[A-Z][A-Z0-9_]*' | sort -u)
if [ "$LIB_VARS" = "$FIX_VARS" ]; then
  ok "HUMAN fixture covers exactly the $(printf '%s\n' "$LIB_VARS" | grep -c .) vars _is_agent_env checks"
else
  bad "agent-env var drift: $(diff <(printf '%s\n' "$LIB_VARS") <(printf '%s\n' "$FIX_VARS") | tr '\n' ' ')"
fi

echo "=== BOTH checks active in the entry: refactor CONTRACT violation still blocks ==="
newrepo; install_hook
printf '{"stage":"PHASE-3","scope_fence":["app.ts"],"prove":{"blind_audit":"skipped","adversarial":"clean","findings_disposition":"none"}}' > zuvo/contracts/refactor-a.json
[ "$(AI app.ts)" -ne 0 ] && ok "refactor gate still blocks alongside plan gate" || bad "refactor gate (regression)"

echo "=== regression: CRLF status still blocks (no fail-open bypass) ==="
newrepo; install_hook; planfiles "app.ts"
printf -- '---\r\nplan: docs/specs/p-plan.md\r\nstatus: pending\r\n---\r\n' > zuvo/plans/active-plan.md
[ "$(AI app.ts)" -ne 0 ] && ok "CRLF active-plan still blocks" || bad "CRLF bypass (regressed)"

echo "=== regression: plan filename with a space is gated (not word-split) ==="
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
[ "$r" -ne 0 ] && ok "file from 2nd task's **Files:** blocked" || bad "multi-task plan bypassed"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
