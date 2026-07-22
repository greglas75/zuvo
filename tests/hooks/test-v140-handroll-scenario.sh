#!/usr/bin/env bash
# Task 3: the EXACT v1.4.0 failure — an Approved plan, hand-rolled (execute never run) — is now gated.
set -u
# Neutralize the developer's real git config. This machine sets a global
# core.hooksPath (the installed zuvo dispatcher), so without this a fixture repo
# inherits an OLD installed copy of the gate and can pass for the wrong reason.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/hooks/refactor-safety-gate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"; mkdir -p zuvo/plans docs/specs hooks/lib
git init -q; git config user.email t@t; git config user.name t
printf '#!/bin/sh\nexec "%s" pre-commit\n' "$GATE" > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
# An Approved plan whose Task 2 touches hooks/lib/refactor-gate-lib.sh (the real v1.4.0 file)
printf '# plan\n\n### Task 2\n**Files:** hooks/lib/refactor-gate-lib.sh\n' > docs/specs/x-plan.md
echo orig > hooks/lib/refactor-gate-lib.sh
ok=0

# HAND-ROLL: active-plan pending (execute NEVER started) -> committing a plan file must BLOCK
printf -- '---\nplan: docs/specs/x-plan.md\nstatus: pending\n---\n' > zuvo/plans/active-plan.md
echo change >> hooks/lib/refactor-gate-lib.sh; git add hooks/lib/refactor-gate-lib.sh
ZUVO_AI_RUN=1 git commit -q -m "hand-rolled fix" >/dev/null 2>&1
[ $? -ne 0 ] && echo "  ok hand-roll (pending plan) BLOCKED" || { echo "  FAIL hand-roll allowed"; ok=1; }

# EVASION: flip the pointer to in-progress but do NOTHING else. This is the cheap way around
# the gate — the status field is a free, unverified write — so it must NOT buy an exemption.
sed -i.bak 's/status: pending/status: in-progress/' zuvo/plans/active-plan.md; rm -f zuvo/plans/active-plan.md.bak
ZUVO_AI_RUN=1 git commit -q -m "flag-flip only" >/dev/null 2>&1
[ $? -ne 0 ] && echo "  ok flag-flip WITHOUT an execute run BLOCKED" || { echo "  FAIL flag-flip alone exempted"; ok=1; }
# Unstage so the next assertion stands on its own rather than inheriting this one's index state.
git reset -q >/dev/null 2>&1; git add hooks/lib/refactor-gate-lib.sh

# EXECUTE PATH: what zuvo:execute ACTUALLY does at start — flips the pointer AND writes
# execution-state.md (session-state.md WRITE protocol, steps 1+2). Then the commit is allowed.
mkdir -p zuvo/context
printf '# Execution State\n<!-- status: in-progress -->\n\nplan: docs/specs/x-plan.md\n' > zuvo/context/execution-state.md
ZUVO_AI_RUN=1 git commit -q -m "execute commit" >/dev/null 2>&1
[ $? -eq 0 ] && echo "  ok execute path (in-progress + execution-state) ALLOWED" || { echo "  FAIL execute path blocked"; ok=1; }

[ "$ok" = 0 ] && echo "ALL PASS" || { echo "FAILED"; exit 1; }
