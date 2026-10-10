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

probe() {  # <label> <expect: allow|block> <command text>; PROBE_TIMEOUT=N caps the guard at N s
  local label="$1" expect="$2" cmd="$3" rc
  local -a run=(bash "$GUARD")
  [ -n "${PROBE_TIMEOUT:-}" ] && run=(timeout "$PROBE_TIMEOUT" bash "$GUARD")
  printf '%s' "$cmd" | python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))' \
    | env -u TF_ALLOW_LOCAL -u FARM_HOOK_OFF PATH="$STUB:$PATH" "${run[@]}" >/dev/null 2>&1
  rc=$?
  if [ -n "${PROBE_TIMEOUT:-}" ] && [ "$rc" -eq 124 ]; then
    bad "the guard hung past the ${PROBE_TIMEOUT}s ceiling: $label"; return
  fi
  # exactly 2: a matcher crash refuses too, but python failing to start or the hook timing out
  # still lets the command through (exit 0), and any other non-zero is not a refusal
  if [ "$expect" = "block" ]; then
    [ "$rc" -eq 2 ] && pass "blocks: $label" || bad "did NOT block (rc=$rc): $label"
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
# An UNQUOTED heredoc is expanded by the shell: a substitution in its body really runs
probe "substitution in an unquoted cat heredoc" block "$(printf '%s\n' "cat <<EOF" 'result: $(npx vitest run)' 'EOF')"
probe "same text in a quoted heredoc is data"   allow "$(printf '%s\n' "cat <<'EOF'" 'result: $(npx vitest run)' 'EOF')"
# the body ends at the delimiter alone on its line, not at an indented look-alike: the old
# `^\s*EOF\s*$` ended this quoted body early and scanned the data line after it as shell
probe "indented look-alike does not end the body" allow "$(printf '%s\n' "cat <<'EOF'" '  EOF' 'x $(npx vitest run)' 'EOF')"
probe "tab-indented closer ends a <<- body"       allow "$(printf '%s\n' "cat <<-'EOF'" 'x $(npx vitest run)' $'\tEOF')"
probe "a heredoc fed to /bin/bash"                block "$(printf '%s\n' "/bin/bash <<'EOF'" 'npx vitest run' 'EOF')"
probe "a heredoc fed to /usr/bin/env bash"         block "$(printf '%s\n' "/usr/bin/env bash <<'EOF'" 'npx vitest run' 'EOF')"
probe "a heredoc fed to ksh"                       block "$(printf '%s\n' "ksh <<'EOF'" 'npx vitest run' 'EOF')"
probe "same look-alike in a bash heredoc runs"    block "$(printf '%s\n' "bash <<'EOF'" '  EOF' 'npx vitest run' 'EOF')"

# Only what the shell would expand counts. Each ALLOW below has a BLOCK sibling of the same shape,
# so a matcher that crashes (and fails open) or stops scanning shows red.
# Bug: data fed to a non-shell interpreter read as a command.
probe "python heredoc printing a runner name"     allow "$(printf '%s\n' 'python3 - <<EOF' 'print("npm test")' 'EOF')"
# Bug: the opener line's tail was swallowed together with the body.
probe "a runner after a python heredoc opener"    block "$(printf '%s\n' 'python3 - <<EOF; npm test' 'print(1)' 'EOF')"
probe "a substitution after a quoted opener"      block "$(printf '%s\n' "cat <<'EOF'; echo \$(npm test)" 'data' 'EOF')"
# Bug: text after the delimiter hid a heredoc fed to bash.
probe "a bash heredoc with a redirect after it"   block "$(printf '%s\n' 'bash <<EOF >/dev/null' 'npm test' 'EOF')"
probe "a bash heredoc running a runner"           block "$(printf '%s\n' 'bash <<EOF' 'npm test' 'EOF')"
# Bug: an escaped substitution in an unquoted body is literal text, not a run.
probe "escaped \$( in an unquoted body"            allow "$(printf '%s\n' 'cat <<EOF' '\$(npm test)' 'EOF')"
probe "escaped backslash then a live \$("           block "$(printf '%s\n' 'cat <<EOF' '\\$(npm test)' 'EOF')"
probe "escaped backticks in an unquoted body"     allow "$(printf '%s\n' 'cat <<EOF' '\`npx vitest run\`' 'EOF')"
probe "live backticks in an unquoted body"        block "$(printf '%s\n' 'cat <<EOF' '`npx vitest run`' 'EOF')"
# Bug: single-quoted and $'...' text is never expanded.
probe "a substitution inside single quotes"       allow "grep 'echo \$(npm test)' f"
probe "a live substitution after single quotes"   block "echo 'x' \"\$(npm test)\""
probe "backticks inside single quotes"            allow "echo 'see \`npm test\`'"
probe "backticks inside double quotes"            block "echo \"see \`npm test\`\""
probe "a substitution inside \$'...'"              allow "echo \$'it\\'s \$(npm test)'"
probe "an escaped quote in \$'...' then a live \$(" block "echo \$'a\\'b' \"\$(npm test)\""
probe "an escaped \$( in double quotes"            allow 'echo "\$(npm test)"'
probe "a bare substitution"                       block 'echo $(npm test)'
# Bug: an apostrophe in a comment opened a quote that hid the next line.
probe "a comment apostrophe, then a substitution" block "$(printf '%s\n' "ls # don't" 'echo "$(npm test)"')"
# Bug: a quoted body was searched for heredoc openers of its own.
probe "an opener piped to bash inside quoted data" allow "$(printf '%s\n' "cat <<'EOF'" 'cat <<X | bash' 'npm test' 'X' 'EOF')"
probe "a heredoc piped to bash"                   block "$(printf '%s\n' 'cat <<EOF | bash' 'npm test' 'EOF')"
# Bug: a heredoc body counted as part of the substitution that holds it.
probe "a commit message heredoc naming a runner"  allow "$(printf '%s\n' "git commit -m \"\$(cat <<'EOF'" 'run npm test first' 'EOF' ')"')"
probe "a heredoc inside bash -c \"\$(...)\""        block "$(printf '%s\n' 'bash -c "$(cat <<EOF' 'npm test' 'EOF' ')"')"
# Bug: a << inside quotes taken for an opener, swallowing the next line as its body.
probe "a quoted << then a runner"                 block "$(printf '%s\n' 'grep "<<EOF" f' 'npm test')"

# Bug: `#` read as a comment where it is inside a word, hiding the live backticks after it.
probe "# right after a closing \$(...)"            block 'echo $(echo a)#`npm test`'
probe "# right after an escaped space"            block 'echo a\ #`npm test`'
probe "a real comment holding backticks"          allow 'echo a #`npm test`'
# Bug: a " nested inside ${...} closed the double quotes early.
probe "nested quotes in \${...} inside dq"         block "echo \"\${x:-\"'\"}\" \$(npm test) \"'\""
# Bug: an unterminated body was put back as command text; bash reads it to the end and expands it.
probe "an unterminated body with a live \$("       block "$(printf '%s\n' 'cat <<EOF' "it's \$(npm test)")"
probe "an unterminated body with live backticks"  block "$(printf '%s\n' 'cat <<EOF' "it's \`npm test\`")"
# Bug: body substitutions ignored escapes and quotes inside the substitution.
probe "escaped backticks nested in backticks"     block "$(printf '%s\n' 'cat <<EOF' '`echo \`true\`; npm test`' 'EOF')"
probe "a quoted ) inside a body \$(...)"           block "$(printf '%s\n' 'cat <<EOF' '$(echo ")"; npm test)' 'EOF')"
probe "an escaped ) inside a body \$(...)"         block "$(printf '%s\n' 'cat <<EOF' '$(echo \); npm test)' 'EOF')"
# Bug: wrapper and assignment forms in front of a shell hid that the shell reads the heredoc.
probe "env X=1 bash heredoc"                      block "$(printf '%s\n' 'env X=1 bash <<EOF' 'npm test' 'EOF')"
probe "X=1 bash heredoc"                          block "$(printf '%s\n' 'X=1 bash <<EOF' 'npm test' 'EOF')"
probe "( bash heredoc"                            block "$(printf '%s\n' '( bash <<EOF' 'npm test' 'EOF' ')')"
probe "timeout 60 bash heredoc"                   block "$(printf '%s\n' 'timeout 60 bash <<EOF' 'npm test' 'EOF')"
probe "eval of a quoted heredoc"                  block "$(printf '%s\n' "eval \"\$(cat <<'EOF'" 'npm test' 'EOF' ')"')"
# Bug: a pipe to a shell after the body, or on a continued opener line, was not seen.
probe "a dangling pipe to bash after the body"    block "$(printf '%s\n' 'cat <<EOF |' 'npm test' 'EOF' 'bash')"
probe "a pipe to bash on a continued opener line" block "$(printf '%s\n' "cat <<EOF \\" '| bash' 'npm test' 'EOF')"
# Bug: an arithmetic shift taken for a heredoc opener swallowed the next line as its body.
probe "an arithmetic << then a runner"            block "$(printf '%s\n' 'echo $((1<<2))' 'npm test' '2')"
probe "an attached here-string to bash"           block 'bash <<<"npm test"'
# Bug: the ) ending a case pattern closed the substitution.
probe "a case pattern inside \$(...)"              block 'echo "$(case x in x) npm test;; esac)"'
# Bug: ${...} and $[...] are one unit: no comment and no heredoc opener inside them.
probe "# inside an unquoted \${...}"               block 'echo ${x:-a #}`npm test`'
probe "<< inside an unquoted \${...}"              block "$(printf '%s\n' 'echo ${x:-<<A}' 'npm test' 'A}')"
probe "<< inside \$[...] arithmetic"               block "$(printf '%s\n' 'echo $[1<<2]' 'npm test' '2]')"
# Bug: the shell word was missed behind a redirect, quoting, $SHELL or many assignments.
probe "a redirect before the shell word"          block "$(printf '%s\n' '<<EOF bash' 'npm test' 'EOF')"
probe "2>/dev/null before the shell word"         block "$(printf '%s\n' '2>/dev/null bash <<EOF' 'npm test' 'EOF')"
probe "a redirect before a non-shell command"     allow "$(printf '%s\n' '2>/dev/null cat <<EOF' 'npm test' 'EOF')"
probe "a backslash inside the shell word"         block "$(printf '%s\n' 'ba\sh <<EOF' 'npm test' 'EOF')"
probe "empty quotes inside the shell word"        block "$(printf '%s\n' "b''ash <<EOF" 'npm test' 'EOF')"
probe "\$SHELL reading a heredoc"                  block "$(printf '%s\n' '$SHELL <<EOF' 'npm test' 'EOF')"
probe "a heredoc piped to \$SHELL"                 block "$(printf '%s\n' 'cat <<EOF | $SHELL' 'npm test' 'EOF')"
probe "ten assignments before bash"               block "$(printf '%s\n' 'V0=1 V1=1 V2=1 V3=1 V4=1 V5=1 V6=1 V7=1 V8=1 V9=1 bash <<EOF' 'npm test' 'EOF')"
# Bug: a comment, a blank line or |& hid a dangling pipe into a shell.
probe "a dangling pipe, then a comment"           block "$(printf '%s\n' 'cat <<EOF | # c' 'npm test' 'EOF' 'bash')"
probe "a dangling pipe, then a blank line"        block "$(printf '%s\n' 'cat <<EOF |' 'npm test' 'EOF' '' 'bash')"
probe "a dangling |&"                             block "$(printf '%s\n' 'cat <<EOF |&' 'npm test' 'EOF' 'bash')"
# Bug: a shell-fed body or a live substitution only got the regex check, not the command analysis.
probe "a test script in a bash heredoc"           block "$(printf '%s\n' 'bash <<EOF' './tests/run-all.sh' 'EOF')"
probe "a test script piped to bash"               block "$(printf '%s\n' 'cat <<EOF | bash' './tests/run-all.sh' 'EOF')"
probe "a test script in a quoted substitution"    block 'echo "$(./tests/run-all.sh)"'
# Bug: quotes and backslashes split a runner name the shell joins back.
probe "a backslash inside a substituted runner"   block 'echo "$(npm te\st)"'
probe "quotes inside a substituted runner"        block 'echo "$(vi"test" run)"'
probe "a here-string to ksh"                      block 'ksh <<<"npm test"'
# Bug: a package-manager word and a task word on different lines read as one command.
probe "npm ci, then test -f, in a bash heredoc"   allow "$(printf '%s\n' 'bash <<EOF' 'npm ci' 'test -f x' 'EOF')"
probe "npm ci, then npm test, in a bash heredoc"  block "$(printf '%s\n' 'bash <<EOF' 'npm ci' 'npm test' 'EOF')"
probe "a runner word as a plain argument"         allow "echo npm"
# Bug: a -c string, an eval argument or a here-string is a command line, yet ( ) ` and $( did not
# end a word before a runner, and only the regex check, not the command analysis, read it.
probe "bash -c with a runner in \$(...)"           block "bash -c 'echo \$(vitest run)'"
probe "bash -c with a runner in backticks"        block "bash -c 'x=\`vitest\`'"
probe "bash -c with a runner in a subshell"       block "bash -c '(vitest run)'"
probe "bash -c with cd && runner in a subshell"   block "bash -c '(cd pkg && vitest)'"
probe "bash -c running a test script, then more" block "bash -c './foo-test.sh && echo ok'"
probe "eval of a subshell runner"                 block "eval '(vitest run)'"
probe "a here-string with a runner in \$(...)"     block "bash <<<'echo \$(vitest)'"
probe "bash -c printing a word"                   allow "bash -c 'echo hello'"
probe "bash -c grepping for a runner name"        allow 'bash -c "git log --grep=vitest"'
# Bug: the quick check of a -c string turned a quoted ( into a word boundary.
probe "bash -c echoing a parenthesised runner"    allow "bash -c 'echo \"Test runners: (vitest)\"'"
# Bug: the positional parameters after a -c string were read as part of the command.
probe "a runner name as a positional parameter"   allow "bash -c 'echo hello' vitest"
probe "a -c string echoing its positional arg"    allow "sh -c 'echo \"\$1\"' _ \"go test\""
# Bug: a positional parameter in command position runs the word bound to it.
probe "a runner bound to \$1 of a -c string"        block "bash -c '\$1' _ 'npm test'"
probe "a runner bound to \"\$@\" of a -c string"     block "bash -c '\"\$@\"' _ npx vitest"
probe "a runner bound to \${2} of a -c string"      block "bash -c 'cd x && \${2} run' _ y vitest"
# Bug: an option value (-o pipefail) ended the option scan, hiding -c and the script after it.
probe "bash -o pipefail -c runner"                block "bash -o pipefail -c 'pytest'"
probe "bash -eo pipefail running a test script"   block "bash -eo pipefail tests/run-all.sh"
# Bug: a here-string token was taken for the script, hiding the script bash really runs.
probe "a test script after a here-string"         block "bash <<<'echo ok' tests/run-all.sh"
probe "a test script after a bare here-string"    block "bash <<< 'echo ok' tests/run-all.sh"
# Bug: a bare here-string handed the analysis one word, where the refusal check reads them all.
probe "a test script in a here-string's words"    block "bash <<< 'echo' '(./foo.spec.sh)'"
# Bug: past the nesting cap the analysis stopped silently; it must refuse instead.
probe "a test script under nine bash -c layers"   block "$(python3 -c '
s = "./foo.spec.sh && echo ok"
for _ in range(9):
    s = "bash -c \"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
print(s)')"
# Bug: an internal error in the matcher let the command through. The test-only switch can only refuse.
_crash_msg=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo npm"}}' \
  | env -u TF_ALLOW_LOCAL -u FARM_HOOK_OFF FARM_HOOK_TEST_CRASH=1 PATH="$STUB:$PATH" bash "$GUARD" 2>&1 >/dev/null)
_crash_rc=$?
case "$_crash_rc:$_crash_msg" in
  2:*"could not parse"*TF_ALLOW_LOCAL=1*) pass "a matcher crash refuses (exit 2) and names the way through" ;;
  *) bad "a matcher crash did not refuse with the parse message (rc=$_crash_rc)" ;;
esac

command -v timeout >/dev/null 2>&1 || bad "coreutils timeout is missing: a hung guard would hang this suite"
timed_probe() {  # <label> <expect> <command text>: the verdict, and within 5 s; a hang fails at 30 s
  local t0=$SECONDS
  PROBE_TIMEOUT=30 probe "$1" "$2" "$3"
  [ $((SECONDS - t0)) -le 5 ] && pass "within 5s: $1" || bad "took $((SECONDS - t0))s: $1"
}
# Linear time: a 12 KB unquoted body is scanned to its end, and its last line still blocks.
_body=$(python3 -c 'print("\n".join("row %04d: \"q\" x \\$HOME $(date) y" % i for i in range(380)))')
_heredoc=$(printf 'cat <<EOF\n%s\n%s\nEOF' "$_body" '$(npm test)')
[ "${#_heredoc}" -ge 12000 ] || bad "the heredoc perf payload is under 12000 chars"
timed_probe "a ${#_heredoc}-char unquoted body ending in a live substitution" block "$_heredoc"
# Bug: every nested $( was rescanned on its own, quadratic in the nesting.
timed_probe "12000 nested \$( and no runner" allow "$(python3 -c 'print("npm ci\necho " + "$(" * 12000 + "x" + ")" * 12000)')"
# Bug: the command word was re-read from the segment start for every opener on the line.
timed_probe "200 KB of blanks, then 8000 openers" allow "$(python3 -c 'print("npm ci; " + " " * 200000 + "cat " + "<<A " * 8000)')"
timed_probe "the same line ending in a runner"   block "$(python3 -c 'print("npm ci; " + " " * 200000 + "cat " + "<<A " * 8000 + "; npm test")')"
timed_probe "8000 nested \$( around a runner" block "$(python3 -c 'print("echo " + "$(" * 8000 + "npm test" + ")" * 8000)')"
# Bug: binding one long word to many $1 grows the text quadratically; past its budget the guard refuses.
timed_probe "5000 \$1 bound to a 100 KB word"      block "$(python3 -c 'print("bash -c \"" + "$1 " * 5000 + "\" _ " + "a" * 100000)')"
# Bug: the package-manager pattern backtracked exponentially in the number of arguments.
timed_probe "npm with 30 arguments and no script" allow "$(python3 -c 'print("echo \"$(npm " + "a " * 30 + ";)\"")')"
timed_probe "npm with 30 arguments, then test"    block "$(python3 -c 'print("echo \"$(npm " + "a " * 30 + "test;)\"")')"

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
