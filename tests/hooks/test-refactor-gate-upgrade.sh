#!/usr/bin/env bash
# Hermetic integration regression: cache eviction must neither brick commits nor skip a live gate.
set -euo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG ZUVO_DISPATCH_ACTIVE
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home's space" GATE_LOG="$TMP/gate.log"
CACHE="$HOME/.claude/plugins/cache/zuvo-marketplace/zuvo"
mkdir -p "$HOME" "$TMP/repo"
cd "$TMP/repo"
git init -q
git config user.email test@example.invalid
git config user.name test
git commit -q --allow-empty -m initial
fails=0
ok(){ echo "  ✓ $1"; }
bad(){ echo "  ✗ $1"; fails=$((fails+1)); }
make_gate(){
  mkdir -p "$1/hooks"
  cat > "$1/hooks/refactor-safety-gate.sh" <<'GATE'
#!/bin/sh
printf '%s\n' "$@" > "$GATE_LOG"
cat > "$GATE_LOG.stdin"
exit 23
GATE
  chmod +x "$1/hooks/refactor-safety-gate.sh"
}
make_gate "$CACHE/1.6.98"
sh "$ROOT/scripts/install-refactor-gate.sh" "$CACHE/1.6.98/hooks/refactor-safety-gate.sh" "$PWD"
make_gate "$CACHE/1.6.100"
# Leave the registry stale too: an upgrade can delete the previous install before refreshing it.
printf '{"plugins":{"zuvo@zuvo-marketplace":[{"installPath":"%s"}]}}\n' "$CACHE/1.6.98" > "$HOME/.claude/plugins/installed_plugins.json"
rm -rf "$CACHE/1.6.98"
: > "$GATE_LOG"
before=$(git rev-parse HEAD)
code=0
git commit -q --allow-empty -m upgraded > "$TMP/commit.out" 2>&1 || code=$?
if [ "$code" -ne 0 ] && [ "$(git rev-parse HEAD)" = "$before" ] && grep -Fxq pre-commit "$GATE_LOG"; then
  ok 'upgrade executes the new gate and preserves its commit rejection after the old directory is deleted'
else cat "$TMP/commit.out"; bad 'upgrade stranded the installed commit hook'; fi
printf 'refs/heads/main abc refs/heads/main def\n' > "$TMP/refs"
code=0
.git/hooks/pre-push origin 'space remote' < "$TMP/refs" || code=$?
if [ "$code" -eq 23 ] && cmp -s "$TMP/refs" "$GATE_LOG.stdin" && grep -Fxq 'space remote' "$GATE_LOG"; then
  ok 'runtime dispatch preserves push arguments, stdin and gate status'
else bad 'runtime dispatch lost the push contract'; fi
# A reinstall must migrate an old generated wrapper even after its release vanished.
python3 - "$PWD/.git/hooks/pre-commit" "$CACHE/1.6.98/hooks/refactor-safety-gate.sh" <<'PY'
from pathlib import Path
import shlex
import sys
Path(sys.argv[1]).write_text('#!/bin/sh\n# >>> zuvo:refactor-gate\nexec '
                           + shlex.quote(sys.argv[2]) + ' pre-commit "$@"\n# <<< zuvo:refactor-gate\n')
PY
sh "$ROOT/scripts/install-refactor-gate.sh" "$CACHE/1.6.100/hooks/refactor-safety-gate.sh" "$PWD"
: > "$GATE_LOG"
code=0
.git/hooks/pre-commit || code=$?
if [ "$code" -eq 23 ] && grep -Fxq pre-commit "$GATE_LOG"; then
  ok 'reinstall migrates an exact legacy wrapper after its pinned version disappears'
else bad 'legacy wrapper remained pinned'; fi
# The dispatcher template itself must also remain upgradeable without clobbering foreign hooks.
mkdir -p "$TMP/new-installer"
cp "$ROOT/scripts/install-refactor-gate.sh" "$TMP/new-installer/"
cp "$ROOT/hooks/refactor-gate-dispatch.sh" "$TMP/new-installer/"
printf '\n# new dispatcher revision\n' >> "$TMP/new-installer/refactor-gate-dispatch.sh"
code=0
sh "$TMP/new-installer/install-refactor-gate.sh" "$CACHE/1.6.100/hooks/refactor-safety-gate.sh" "$PWD" > "$TMP/reinstall.out" 2>&1 || code=$?
if [ "$code" -eq 0 ] && grep -q '^# new dispatcher revision$' .git/hooks/pre-commit; then
  ok 'reinstall refreshes an installer-owned embedded dispatcher after its template changes'
else cat "$TMP/reinstall.out"; bad 'embedded dispatcher could not be updated'; fi
# SHA siblings and incomplete newest versions must not hide the usable numeric release.
make_gate "$CACHE/1.6.9"
printf '#!/bin/sh\nexit 91\n' > "$CACHE/1.6.9/hooks/refactor-safety-gate.sh"
make_gate "$CACHE/99deadbeef"
printf '#!/bin/sh\nexit 92\n' > "$CACHE/99deadbeef/hooks/refactor-safety-gate.sh"
mkdir -p "$CACHE/2.0.0/hooks"
: > "$GATE_LOG"
code=0
.git/hooks/pre-commit || code=$?
if [ "$code" -eq 23 ] && grep -Fxq pre-commit "$GATE_LOG"; then
  ok 'cache selection ignores SHA directories and incomplete releases'
else bad 'cache selection chose an invalid release'; fi
# A present gate with a broken interpreter must warn and fall back, preserving the next gate status.
printf '#!/no/such/zuvo-interpreter\n' > "$CACHE/2.0.0/hooks/refactor-safety-gate.sh"
chmod +x "$CACHE/2.0.0/hooks/refactor-safety-gate.sh"
code=0
.git/hooks/pre-commit 2> "$TMP/broken.err" || code=$?
if [ "$code" -eq 23 ] && grep -q 'WARNING.*2.0.0' "$TMP/broken.err"; then
  ok 'unlaunchable newest gate warns and falls back without hiding a real rejection'
else bad 'broken newest gate blocked commits or fell back silently'; fi
rm "$CACHE/2.0.0/hooks/refactor-safety-gate.sh"
# An explicit current pointer wins; a dangling pointer must recover to the cache.
mkdir -p "$HOME/.zuvo"
ln -s "$CACHE/1.6.9" "$HOME/.zuvo/current"
code=0
.git/hooks/pre-commit || code=$?
[ "$code" -eq 91 ] && ok 'current pointer overrides the numeric cache' || bad 'current pointer ignored'
rm -rf "$CACHE/1.6.9"
printf '{broken json\n' > "$HOME/.claude/plugins/installed_plugins.json"
: > "$GATE_LOG"
code=0
.git/hooks/pre-commit || code=$?
if [ "$code" -eq 23 ] && grep -Fxq pre-commit "$GATE_LOG"; then
  ok 'dangling current pointer and corrupt registry recover to the newest usable release'
else bad 'stale metadata stranded the hook'; fi
# Exercise the installed shared script through the real installer helper, without global git writes.
export ZUVO_DIR="$ROOT"
source "$ROOT/scripts/install.d/hooks.sh"
install_hook_tree "$HOME/.claude/hooks"
rm "$HOME/.zuvo/current"
ln -s "$HOME/.claude" "$HOME/.zuvo/current"
: > "$GATE_LOG"
code=0
"$HOME/.claude/hooks/refactor-safety-gate.sh" pre-commit || code=$?
if [ "$code" -eq 23 ] && grep -Fxq pre-commit "$GATE_LOG"; then
  ok 'global installed hook resolves the current gate at invocation'
else bad 'global installed hook did not run the cached gate'; fi
# The worktree-private wrapper embeds the same resolver and retains the original hook chain.
cp "$ROOT/hooks/git-dispatch/pre-commit" "$ROOT/hooks/git-dispatch/pre-push" "$HOME/.claude/hooks/"
chmod +x "$HOME/.claude/hooks/pre-commit" "$HOME/.claude/hooks/pre-push"
git config core.hooksPath "$HOME/.claude/hooks"
git config extensions.worktreeConfig true
git worktree add -q -b linked "$TMP/linked"
cd "$TMP/linked"
sh "$ROOT/scripts/install-refactor-gate.sh" "$CACHE/1.6.100/hooks/refactor-safety-gate.sh" "$PWD"
private_hooks=$(git config --worktree --get core.hooksPath)
sh "$TMP/new-installer/install-refactor-gate.sh" "$CACHE/1.6.100/hooks/refactor-safety-gate.sh" "$PWD"
if grep -q '^# new dispatcher revision$' "$private_hooks/pre-commit" \
    && grep -q '^# new dispatcher revision$' "$private_hooks/pre-push"; then
  ok 'private reinstall refreshes both digest-verified wrappers when the dispatcher changes'
else bad 'private wrappers did not receive the dispatcher revision'; fi
# Exact legacy private wrappers must migrate even when their cache is gone.
python3 - "$private_hooks" "$HOME/.claude/hooks" "$CACHE/1.6.98/hooks/refactor-safety-gate.sh" <<'PY'
from pathlib import Path
import shlex
import sys
private, origin = (Path(value) for value in sys.argv[1:3])
gate = shlex.quote(sys.argv[3])
prefix = '#!/bin/sh\n# zuvo:private-refactor-gate\n'
original = shlex.quote(str(origin / 'pre-commit'))
(private / 'pre-commit').write_text(prefix + f'{gate} pre-commit "$@" </dev/null || exit $?\n'
                                  + f'if [ -x {original} ]; then exec {original} "$@"; fi\n')
original = shlex.quote(str(origin / 'pre-push'))
(private / 'pre-push').write_text(prefix + '''refs=$(mktemp) || exit 2
trap 'rm -f "$refs"' EXIT
trap 'exit 2' HUP INT TERM
cat > "$refs" || exit 2
''' + f'{gate} pre-push "$@" < "$refs" || exit $?\n'
    + f'if [ -x {original} ]; then {original} "$@" < "$refs"; else exit 0; fi\n')
PY
code=0
sh "$ROOT/scripts/install-refactor-gate.sh" "$CACHE/1.6.100/hooks/refactor-safety-gate.sh" "$PWD" > "$TMP/private-legacy.out" 2>&1 || code=$?
if [ "$code" -eq 0 ] && grep -q '^# zuvo:runtime-dispatch-sha256=' "$private_hooks/pre-commit" \
    && grep -q '^# zuvo:runtime-dispatch-sha256=' "$private_hooks/pre-push"; then
  ok 'private reinstall migrates both exact legacy wrappers after the pinned cache is deleted'
else cat "$TMP/private-legacy.out"; bad 'legacy private wrappers remained pinned'; fi
# A private wrapper with edits beyond the generated body is foreign content.
printf '\n# user customization\n' >> "$private_hooks/pre-commit"
cp "$private_hooks/pre-commit" "$TMP/private-customized"
code=0
sh "$ROOT/scripts/install-refactor-gate.sh" "$CACHE/1.6.100/hooks/refactor-safety-gate.sh" "$PWD" > "$TMP/private-refresh.out" 2>&1 || code=$?
if [ "$code" -eq 2 ] && cmp -s "$private_hooks/pre-commit" "$TMP/private-customized"; then
  ok 'private upgrade preserves a customized wrapper instead of trusting its marker'
else cat "$TMP/private-refresh.out"; bad 'private upgrade overwrote foreign edits'; fi
# Restore the known generated fixture so the cache-eviction check exercises it.
cp "$TMP/private-customized" "$private_hooks/pre-commit"
python3 - "$private_hooks/pre-commit" <<'PY'
from pathlib import Path
import sys
hook = Path(sys.argv[1])
hook.write_text(hook.read_text().removesuffix('\n# user customization\n'))
PY
mv "$CACHE/1.6.100" "$CACHE/1.6.101"
: > "$GATE_LOG"
code=0
git commit -q --allow-empty -m upgraded-private > "$TMP/private.out" 2>&1 || code=$?
if [ "$code" -ne 0 ] && grep -Fxq pre-commit "$GATE_LOG"; then
  ok 'private worktree hook also survives an upgrade without reinstalling'
else cat "$TMP/private.out"; bad 'private hook lost its runtime gate'; fi
rm -rf "$CACHE"
code=0
"$TMP/repo/.git/hooks/pre-commit" > "$TMP/missing.out" 2> "$TMP/missing.err" || code=$?
if [ "$code" -eq 0 ] && [ ! -s "$TMP/missing.out" ] && grep -q 'WARNING.*fail-open' "$TMP/missing.err" && grep -q 'claude plugin install zuvo@zuvo-marketplace' "$TMP/missing.err"; then
  ok 'missing plugin fails open with a repair command on stderr'
else cat "$TMP/missing.err"; bad 'missing plugin blocked commits or omitted its warning'; fi
code=0
PATH="$TMP/no-python" "$TMP/repo/.git/hooks/pre-commit" 2> "$TMP/python.err" || code=$?
if [ "$code" -eq 0 ] && grep -q 'WARNING.*Python.*fail-open' "$TMP/python.err"; then
  ok 'missing Python warns and fails open before invoking the resolver'
else bad 'missing Python blocked the commit'; fi
[ "$fails" -eq 0 ] || { echo "$fails FAILED"; exit 1; }
echo 'ALL PASS'
