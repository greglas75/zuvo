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
# The installer's TEXT is install.sh plus the scripts/install.d/ modules it sources.
. "$ROOT/tests/lib/installer-sources.sh"
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

# The registration, by OUTCOME: the real install_claude_home in a sandbox HOME (install.sh sourced, as
# the installer runs it) must leave exactly one PreToolUse matcher=Bash registration of this guard. A
# text match on the installer only proved a line was there, not that it registers anything.
REG="$(mktemp -d)"
mkdir -p "$REG/home/.claude"; printf '{}\n' > "$REG/home/.claude/settings.json"
env -i PATH="$PATH" HOME="$REG/home" TMPDIR="$REG" LANG=C LC_ALL=C GIT_CONFIG_GLOBAL="$REG/home/.gitconfig" \
  GIT_CONFIG_NOSYSTEM=1 bash -c 'set -euo pipefail; . "$1" >/dev/null 2>&1; install_claude_home' _ "$ROOT/scripts/install.sh" \
  > "$REG/install.out" 2>&1; reg_rc=$?
if [ "$reg_rc" -eq 0 ] && python3 - "$REG/home/.claude/settings.json" <<'PY'
import json, os, sys
groups = json.load(open(sys.argv[1]))['hooks']['PreToolUse']
hits = [h for g in groups if g.get('matcher') == 'Bash' for h in g['hooks']
        if os.path.basename(h.get('command', '')) == 'farm-no-local-tests.sh' and h.get('timeout') == 10]
assert len(hits) == 1, hits
PY
then
  pass "install_claude_home registers it, once, as PreToolUse matcher=Bash (timeout 10)"
else
  bad "install_claude_home did not register the guard as PreToolUse matcher=Bash: exit $reg_rc [$(grep -i 'farm' "$REG/install.out" | head -2 | tr '\n' '|')]"
fi
rm -rf "$REG"

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

# Execute the installer's settings merge — the real file, scripts/install.d/claude_settings.py, run
# with the farm guard's arguments — against a symlinked fixture. It used to be cut out of the
# installer's text by awk between two markers, which kept reading past the heredoc if one moved.
# This checks the behavior that matters: preserve the dotfile symlink, retain unrelated settings, and
# remain idempotent when the second run sees the normalized $HOME path written by the first.
printf '#!/bin/sh\nexec python3 "%s" "$1" "$2" PreToolUse Bash 10 farm-no-local-tests\n' \
  "$ROOT/scripts/install.d/claude_settings.py" > "$STUB/merge-settings.sh"
chmod +x "$STUB/merge-settings.sh"
# HOME is always the sandbox: the merge takes its lock under ~/.zuvo/locks, and nothing here may touch the real one.
merge_settings() { HOME="${MERGE_HOME:-$STUB/home}" "$STUB/merge-settings.sh" "$@"; }
printf '%s\n' '{"theme":"dark"}' > "$STUB/settings-target.json"
ln -s settings-target.json "$STUB/settings.json"
if merge_settings "$STUB/settings.json" "$STUB/farm-no-local-tests.sh" >/dev/null \
   && merge_settings "$STUB/settings.json" "$STUB/farm-no-local-tests.sh" >/dev/null \
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

mkdir -p "$STUB/home/.claude/hooks"
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash ~/.claude/hooks/farm-no-local-tests.sh"}]}]}}' \
  > "$STUB/tilde-settings.json"
if MERGE_HOME="$STUB/home" merge_settings "$STUB/tilde-settings.json" \
     "$STUB/home/.claude/hooks/farm-no-local-tests.sh" >/dev/null \
   && python3 - "$STUB/tilde-settings.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
entries = [hook for group in data['hooks']['PreToolUse'] for hook in group['hooks']]
assert sum(hook.get('command', '').endswith('farm-no-local-tests.sh') for hook in entries) == 1
PY
then
  pass "settings merge recognizes legacy tilde-form hook paths"
else
  bad "settings merge duplicates legacy tilde-form hook paths"
fi

printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"printf ~/.claude/hooks/farm-no-local-tests.sh"}]}]}}' \
  > "$STUB/argument-settings.json"
MERGE_HOME="$STUB/home" merge_settings "$STUB/argument-settings.json" \
  "$STUB/home/.claude/hooks/farm-no-local-tests.sh" >/dev/null
if python3 - "$STUB/argument-settings.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
entries = [hook for group in data['hooks']['PreToolUse'] for hook in group['hooks']]
assert sum(hook.get('command', '').endswith('farm-no-local-tests.sh') for hook in entries) == 2
PY
then
  pass "a path used only as an argument does not suppress hook registration"
else
  bad "a path used only as an argument suppressed hook registration"
fi

printf 'null\n' > "$STUB/malformed.json"
if merge_settings "$STUB/malformed.json" "$STUB/farm-no-local-tests.sh" >/dev/null 2>&1; then
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
# Package-manager maintenance and queries (2026-10-05: `npm -g outdated` was refused as ambiguous)
probe "global outdated check"           allow "npm -g outdated"
probe "view + global install"           allow "npm view @qwen-code/qwen-code version 2>&1; npm install -g @qwen-code/qwen-code@latest"
probe "a test script after a global flag" block "npm -g test"
# A non-shell heredoc is data: a JS template literal inside a python patch script is not a substitution
probe "backtick text inside a python heredoc" allow "$(printf '%s\n' "python3 - <<'P'" 's = "const x = `<b>go build ${y} check</b>`"' 'P')"
probe "a substitution running tests"     block 'echo "$(npm test)"'
probe "a shell heredoc running tests"    block "$(printf '%s\n' "bash <<'EOF'" 'echo $(npx vitest run)' 'EOF')"

# THE REGRESSION. One command, split across lines — not three commands.
probe "git add with backslash continuations" allow \
'git add shared/includes/a.md skills/b/SKILL.md \
        tests/hooks/test-external-cli-availability.sh'

# ...and a continuation must not become a laundering trick either.
probe "a real run hidden after a continuation" block \
'echo staging \
 && bash tests/run-all.sh'

# The bash fast path (2026-09-27) must stay a superset of the python matcher: quote-split names
# still reach it, and a harmless command skips it.
probe "quote-split runner name"         block 'v""itest run'
probe "a command naming no runner"      allow "ls -la /tmp"

# Every name the python matcher can refuse must also be a word in the fast-path list — adding a
# runner to RUNNERS/PMS/TASK_SUBCMDS without adding it to _fw would silently skip the matcher.
_fw_line=$(grep -E "^_fw='" "$GUARD")
_missing=""
for name in $(python3 - "$GUARD" <<'PYNAMES'
import re, sys
src = open(sys.argv[1]).read()
names = set()
for var in ("RUNNERS", "PMS"):
    m = re.search(var + r"\s*=\s*\{([^}]*)\}", src)
    names |= set(re.findall(r'"([^"]+)"', m.group(1)))
m = re.search(r"TASK_SUBCMDS\s*=\s*\{(.*?)\n\}", src, re.S)
names |= set(re.findall(r'"([A-Za-z0-9_-]+)"\s*:', m.group(1)))
print("\n".join(sorted(names)))
PYNAMES
); do
  case "$_fw_line" in *"|$name|"*|*"($name|"*|*"|$name)"*) ;; *) _missing="$_missing $name" ;; esac
done
[ -z "$_missing" ] && pass "every python runner name is in the bash fast-path list" \
  || bad "fast-path list is missing:$_missing — the python matcher would never see them"

# Linear on macOS /bin/bash 3.2: the quote-stripping once used ${x//[..]/}, which took >25 s on a
# 12 KB command there. A heredoc-sized quoted command must clear the guard quickly.
if [ -x /bin/bash ]; then
  _big=$(python3 -c 'print("echo " + " ".join("\"x%d\" '"'"'y'"'"'" % i for i in range(1500)))')
  _payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$_big")
  _t0=$(date +%s)
  printf '%s' "$_payload" | PATH="$STUB:$PATH" /bin/bash "$GUARD" >/dev/null 2>&1
  _dt=$(( $(date +%s) - _t0 ))
  [ "$_dt" -le 5 ] && pass "a ${#_big}-char quoted command clears the guard in ${_dt}s on /bin/bash" \
    || bad "a ${#_big}-char quoted command took ${_dt}s on /bin/bash — quote stripping went superlinear"
fi

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
