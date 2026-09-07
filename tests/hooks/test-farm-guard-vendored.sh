#!/usr/bin/env bash
# The farm guard must live HERE, be registered by install.sh, and redirect without crying wolf.
#
# It spent its first week unregistered (a guard nobody wired up is a comment) and its whole life
# untracked at ~/.claude/hooks/ — unreviewable, and one machine rebuild from gone. Its own defect
# is why that mattered: it split commands on raw newlines without joining backslash continuations,
# so the last line of
#     git add a.md b.md \
#         tests/hooks/x.sh
# became a segment whose first word IS a test path, and a plain `git add` was refused. A gate that
# fires on staging a file is one people learn to route around, which costs more than it saves.
#
# Pure file analysis plus direct invocations of the guard with synthetic payloads — no suite is
# started by this test, so it is valid on the farm (docs/runbook/testing.md §5).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/hooks/farm-no-local-tests.sh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

if [ -x "$GUARD" ] && bash -n "$GUARD" 2>/dev/null; then
  pass "the guard is vendored in hooks/ and parses"
else
  bad "hooks/farm-no-local-tests.sh missing, not executable, or does not parse"
  echo; echo "FAILURES PRESENT"; exit 1
fi

if grep -q 'farm-no-local-tests registered in ~/.claude/settings.json' "$ROOT/scripts/install.sh" \
   && grep -q "ptu.append({'matcher': 'Bash'" "$ROOT/scripts/install.sh"; then
  pass "install.sh registers it as PreToolUse matcher=Bash"
else
  bad "install.sh does not register the guard — it would ship as an inert file again"
fi

# Behaviour. Exit 0 = allowed through; non-zero = refused.
#
# Hermetic on purpose, so the same assertions hold on the farm as on the workstation:
#   * a stub `rt` on PATH — the guard exits 0 when `rt` is absent (nowhere to redirect to), which
#     is correct on a farm host and would otherwise make every "block" case vacuously pass there;
#   * TF_ALLOW_LOCAL and FARM_HOOK_OFF cleared — this test is often RUN under TF_ALLOW_LOCAL=1,
#     and inheriting it would disable the very thing being measured. A test that passes because
#     its subject was switched off is worse than no test.
STUB="$(mktemp -d)"
printf '#!/bin/sh\nexit 0\n' > "$STUB/rt"; chmod +x "$STUB/rt"
trap 'rm -rf "$STUB"' EXIT

# Execute the installer's exact settings merge against a symlinked fixture. This checks the
# behavior that matters: preserve the dotfile symlink, retain unrelated settings, and remain
# idempotent when the second run sees the normalized $HOME path written by the first.
awk '/^import json, sys, os, stat, tempfile$/ {copy=1} copy && /^PYEOF$/ {exit} copy {print}' \
  "$ROOT/scripts/install.sh" > "$STUB/merge-settings.py"
printf '%s\n' '{"theme":"dark"}' > "$STUB/settings-target.json"
ln -s settings-target.json "$STUB/settings.json"
if python3 "$STUB/merge-settings.py" "$STUB/settings.json" "$STUB/farm-no-local-tests.sh" >/dev/null \
   && python3 "$STUB/merge-settings.py" "$STUB/settings.json" "$STUB/farm-no-local-tests.sh" >/dev/null \
   && [ -L "$STUB/settings.json" ] \
   && python3 - "$STUB/settings-target.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
entries = [hook for group in data['hooks']['PreToolUse'] for hook in group['hooks']]
assert data['theme'] == 'dark'
assert sum(hook.get('command', '').endswith('farm-no-local-tests.sh') for hook in entries) == 1
PY
then
  pass "settings merge preserves symlinks, unrelated fields, and idempotency"
else
  bad "settings merge breaks symlinks, unrelated fields, or idempotency"
fi

printf 'null\n' > "$STUB/malformed.json"
if python3 "$STUB/merge-settings.py" "$STUB/malformed.json" "$STUB/farm-no-local-tests.sh" >/dev/null 2>&1; then
  bad "settings merge accepts a non-object root"
elif [ "$(cat "$STUB/malformed.json")" = null ]; then
  pass "settings merge rejects malformed schema without rewriting it"
else
  bad "settings merge changed malformed input before rejecting it"
fi

probe() {  # <label> <expect: allow|block> <command text>
  local label="$1" expect="$2" cmd="$3" rc
  printf '%s' "$cmd" | python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))' \
    | env -u TF_ALLOW_LOCAL -u FARM_HOOK_OFF PATH="$STUB:$PATH" bash "$GUARD" >/dev/null 2>&1
  rc=$?
  if [ "$expect" = "block" ]; then
    [ "$rc" -ne 0 ] && pass "blocks: $label" || bad "did NOT block: $label"
  else
    [ "$rc" -eq 0 ] && pass "allows: $label" || bad "wrongly blocked: $label"
  fi
}

probe "a local bash harness"            block "bash tests/run-all.sh"
probe "a bare runner"                   block "npx vitest run"
probe "quoted runner"                   block '"vitest" run'
probe "shell -c runner"                 block 'bash -c "pytest"'
probe "backgrounded runner"             block "sleep 1 & vitest"
probe "package-manager filter"          block "pnpm --filter app test"
probe "task runner run"                 block "turbo run test"
probe "runner after fake opt-out"        block "echo TF_ALLOW_LOCAL=1; pytest"
probe "explicit leading opt-out"         allow "TF_ALLOW_LOCAL=1 pytest"
probe "the same harness through rt"     allow "rt --light bash tests/run-all.sh"
probe "a syntax check"                  allow "bash -n tests/run-all.sh"
probe "merely naming a test file"       allow "git add tests/hooks/test-x.sh"

# THE REGRESSION. One command, split across lines — not three commands.
probe "git add with backslash continuations" allow \
'git add shared/includes/a.md skills/b/SKILL.md \
        tests/hooks/test-external-cli-availability.sh'

# ...and a continuation must not become a laundering trick either.
probe "a real run hidden after a continuation" block \
'echo staging \
 && bash tests/run-all.sh'

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
