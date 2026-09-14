#!/usr/bin/env bash
# Hermetic integration tests: Git itself executes the installed commit hook.
set -eu
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL="$ROOT/scripts/install-refactor-gate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GATE_LOG="$TMP/gate.log"
fails=0
serial=0
ok(){ echo "  ✓ $1"; }
bad(){ echo "  ✗ $1"; fails=$((fails+1)); }
newrepo(){
  serial=$((serial+1)); repo="$TMP/repo $serial"
  mkdir -p "$repo"; cd "$repo"
  git init -q; git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m initial
  : > "$GATE_LOG"
}
make_gate(){
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'GATE'
#!/bin/sh
printf '%s|%s\n' "$1" "$(pwd -P)" >> "$GATE_LOG"
exit 23
GATE
  chmod +x "$1"
}
installed(){
  if sh "$INSTALL" "$gate" "$repo" > "$TMP/install.out" 2>&1; then ok "$1";
  else cat "$TMP/install.out"; bad "$1"; fi
}
unavailable(){
  local code=0
  sh "$INSTALL" "$gate" "$repo" > "$TMP/install.out" 2>&1 || code=$?
  if [ "$code" -ne 0 ] && grep -q 'unavailable' "$TMP/install.out"; then ok "$1";
  else cat "$TMP/install.out"; bad "$1"; fi
}
blocked(){
  local before after
  before=$(git rev-parse HEAD); : > "$GATE_LOG"
  if git commit --allow-empty -qm probe > "$TMP/commit.out" 2>&1; then bad "$1 (commit succeeded)"; return; fi
  after=$(git rev-parse HEAD)
  if [ "$before" = "$after" ] && grep -Fxq "pre-commit|$(pwd -P)" "$GATE_LOG"; then ok "$1";
  else cat "$TMP/commit.out"; bad "$1 (gate did not execute)"; fi
}
managed(){
  dispatch="$TMP/dispatcher $serial"
  mkdir -p "$dispatch"
  cp "$ROOT/hooks/git-dispatch/pre-commit" "$ROOT/hooks/git-dispatch/pre-push" "$dispatch/"
  chmod +x "$dispatch/pre-commit" "$dispatch/pre-push"
  git config core.hooksPath "$dispatch"
}

# Shell metacharacters must be literal even when Git launches the generated hook.
gate="$TMP/gate's dir/\$(touch injected) gate.sh"; make_gate "$gate"
echo '=== refactor-gate installation and real Git commits ==='
newrepo
saved_repo="$repo"; repo="$TMP/not a repository"; mkdir "$repo"
unavailable 'non-repository installation reports unavailable without a traceback'
if grep -q 'Traceback' "$TMP/install.out"; then bad 'non-repository raised traceback'; fi
repo="$saved_repo"
installed 'ordinary repository installs both hooks'
blocked 'ordinary Git commit executes quoted absolute gate'
[ ! -e injected ] && ok 'gate path does not execute shell substitutions' || bad 'shell substitution'
cp .git/hooks/pre-commit "$TMP/before"
installed 'reinstall succeeds for usable existing hook'
cmp -s .git/hooks/pre-commit "$TMP/before" && ok 'reinstall preserves existing bytes' || bad 'idempotence'
: > "$GATE_LOG"
code=0; .git/hooks/pre-push origin example </dev/null || code=$?
[ "$code" -eq 23 ] && grep -q '^pre-push|' "$GATE_LOG" && ok 'push hook propagates gate failure' || bad 'push hook'

# Installing from the main checkout also gates its linked worktree.
main="$repo"; linked="$TMP/linked existing"
git worktree add -q -b linked "$linked"
cd "$linked"; repo="$linked"
installed 'linked checkout recognizes common hooks'
blocked 'Git commit from linked worktree runs common hook'

# Only the linked checkout invokes the installer; .git there is a file.
newrepo; main="$repo"; linked="$TMP/linked only"
git worktree add -q -b linked "$linked"
cd "$linked"; repo="$linked"
installed 'linked-only install succeeds'
[ -x "$main/.git/hooks/pre-commit" ] && ok 'linked-only installation targets common Git hooks' || bad 'common hook path'
blocked 'linked-only Git commit is gated'
cd "$main"; blocked 'common installation also gates main checkout'

for kind in relative absolute; do
  newrepo
  mkdir custom
  if [ "$kind" = relative ]; then git config core.hooksPath custom; else git config core.hooksPath "$repo/custom"; fi
  installed "untracked $kind custom hooks path installs"
  blocked "$kind custom path actually gates Git commit"
done

newrepo
printf '#!/bin/sh\necho mine\nexit 0\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit; cp .git/hooks/pre-commit "$TMP/before"
unavailable 'unrelated existing hook reports incomplete installation'
cmp -s .git/hooks/pre-commit "$TMP/before" && ok 'unrelated existing hook preserved' || bad 'user hook overwritten'
[ -x .git/hooks/pre-push ] && ok 'available push hook still installed' || bad 'push missing'

newrepo; installed 'setup non-executable generated hook'
chmod -x .git/hooks/pre-commit
unavailable 'marker with missing executable bit is not reported active'
[ ! -x .git/hooks/pre-commit ] && ok 'existing permissions preserved' || bad 'permissions changed'

newrepo
printf '#!/bin/sh\n# >>> zuvo:refactor-gate\nexit 0\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
unavailable 'comment marker alone cannot claim an active gate'

newrepo; mkdir .husky
printf '#!/bin/sh\nexit 0\n' > .husky/pre-commit
chmod +x .husky/pre-commit
git add .husky/pre-commit; git commit -qm husky
git config core.hooksPath .husky
cp .husky/pre-commit "$TMP/before"
unavailable 'versioned hooks path reports unavailable'
cmp -s .husky/pre-commit "$TMP/before" && [ ! -e .husky/pre-push ] && ok 'versioned hooks directory remains untouched' || bad 'versioned hooks mutated'

newrepo; mkdir untracked-hooks
ln -s untracked-hooks tracked-hook-link
git add tracked-hook-link; git commit -qm tracked-link
git config core.hooksPath tracked-hook-link
unavailable 'tracked hook-path symlink cannot disguise an untracked target'
[ ! -e untracked-hooks/pre-commit ] && [ ! -e untracked-hooks/pre-push ] && ok 'tracked symlink target preserved' || bad 'tracked symlink target mutated'

newrepo; mkdir tracked-parent
ln -s tracked-parent hook-parent
git add hook-parent; git commit -qm tracked-parent-link
git config core.hooksPath hook-parent/nested
unavailable 'tracked ancestor symlink cannot disguise nested hooks'
[ ! -e tracked-parent/nested ] && ok 'tracked ancestor target preserved' || bad 'tracked ancestor mutated'

newrepo
ln -s unrelated-loop unrelated-loop
git add unrelated-loop
git commit -qm unrelated-symlink
installed 'unrelated tracked symlink does not interfere with default Git hooks'
blocked 'default Git hook works with unrelated tracked symlink'

newrepo; outside="$TMP/unmanaged"; mkdir "$outside"
git config core.hooksPath "$outside"
unavailable 'empty external hooks path cannot falsely assume a dispatcher'
[ ! -e "$outside/pre-commit" ] && [ ! -e .git/hooks/pre-commit ] && ok 'unmanaged external directory preserved without inactive local install' || bad 'external hooks mutated'
printf '#!/bin/sh\n# zuvo global pre-commit dispatcher\nexit 0\n' > "$outside/pre-commit"
chmod +x "$outside/pre-commit"
unavailable 'dispatcher comment does not establish a bridge'

newrepo; outside="$TMP/symlink outside"; mkdir "$outside"
ln -s "$outside" hooks-link; git config core.hooksPath hooks-link
unavailable 'relative symlink escape is treated as external'
[ ! -e "$outside/pre-commit" ] && ok 'symlink target untouched' || bad 'symlink escape wrote external hook'

newrepo; managed
oldgate="$gate"; gate="$dispatch/refactor-safety-gate.sh"; make_gate "$gate"
cp "$dispatch/pre-commit" "$TMP/before"
installed 'existing Zuvo dispatcher gains a persistent local guard'
blocked 'existing managed dispatcher gates a real commit'
cmp -s "$dispatch/pre-commit" "$TMP/before" && [ -x .git/hooks/pre-commit ] && ok 'shared dispatcher preserved with executable local guard' || bad 'shared dispatcher or local guard'
rm "$gate"
head_before=$(git rev-parse HEAD)
if git commit -qm missing-dispatch-gate --allow-empty > "$TMP/commit.out" 2>&1; then
  bad 'managed dispatcher allowed commit after its gate disappeared'
elif [ "$(git rev-parse HEAD)" = "$head_before" ] && grep -Fq "$gate" "$TMP/commit.out"; then
  ok 'real dispatcher rejects commit after sibling gate removal through local guard'
else
  cat "$TMP/commit.out"; bad 'missing dispatcher gate rejection did not preserve HEAD or identify gate'
fi
cmp -s "$dispatch/pre-commit" "$TMP/before" && ok 'gate removal test leaves shared dispatcher intact' || bad 'dispatcher changed'
gate="$oldgate"

newrepo; managed; main="$repo"; linked="$TMP/linked dispatcher"
git worktree add -q -b linked "$linked"
cd "$linked"; repo="$linked"
installed 'dispatcher without sibling gate bridges linked-only local installation'
blocked 'managed dispatcher reaches linked worktree common hook'
[ ! -e "$dispatch/refactor-safety-gate.sh" ] && ok 'missing shared gate is not installed globally' || bad 'global gate mutation'

newrepo; managed
saved="$gate"; gate="$dispatch/refactor-safety-gate.sh"; make_gate "$gate"
links="$TMP/dispatcher links"; mkdir "$links"
ln -s "$dispatch/pre-commit" "$links/pre-commit"
ln -s "$dispatch/pre-push" "$links/pre-push"
git config core.hooksPath "$links"
installed 'symlinked dispatcher resolves its own gate directory'
blocked 'symlinked dispatcher gates a real commit'
# The shipped dispatcher only follows eight links; longer chains are not usable.
previous="$dispatch/pre-commit"
for i in {1..9}; do ln -s "$previous" "$links/link$i"; previous="$links/link$i"; done
rm "$links/pre-commit"; ln -s "$previous" "$links/pre-commit"
unavailable 'dispatcher symlink depth limit cannot falsely report active'
gate="$saved"

newrepo; managed
chmod -x "$dispatch/pre-commit"
unavailable 'non-executable dispatcher cannot claim success'
[ ! -x "$dispatch/pre-commit" ] && ok 'external dispatcher permissions preserved' || bad 'external chmod'

newrepo; saved="$gate"; gate="$TMP/missing"
unavailable 'missing gate is an installation failure'
gate=''; unavailable 'empty gate argument is an installation failure'
gate=relative; unavailable 'relative gate argument is an installation failure'
gate="$saved"; chmod -x "$gate"
unavailable 'non-executable gate is an installation failure'
chmod +x "$gate"
installed 'setup gate that disappears after installation'
rm "$gate"
if git commit -qm vanished --allow-empty > "$TMP/commit.out" 2>&1; then bad 'removed gate silently allowed commit';
else ok 'removed gate does not silently allow commit'; fi
unavailable 'existing marker cannot hide a removed gate'

# Shared hooks must survive a linked checkout's private activation.
gate="$TMP/private gate.sh"; make_gate "$gate"
newrepo; managed; main="$repo"; linked="$TMP/private linked"
git config extensions.worktreeConfig true
git worktree add -q -b private-linked "$linked"
mkdir -p "$main/.git/hooks"
printf '#!/bin/sh\nprintf "shared\\n" >> "$GATE_LOG"\nexit 0\n' > "$main/.git/hooks/pre-commit"
chmod +x "$main/.git/hooks/pre-commit"
cp "$main/.git/hooks/pre-commit" "$TMP/shared-before"
cp "$main/.git/config" "$TMP/config-before"
cd "$linked"; repo="$linked"
installed 'private activation coexists with shared project and dispatcher hooks'
blocked 'private guard blocks an actual commit in linked checkout'
cmp -s "$main/.git/config" "$TMP/config-before" && ok 'shared Git config unchanged' || bad 'shared config mutated'
cmp -s "$main/.git/hooks/pre-commit" "$TMP/shared-before" && ok 'shared project hook unchanged' || bad 'shared hook mutated'
private_hooks=$(git config --worktree --get core.hooksPath || true)
if [ -n "$private_hooks" ]; then
  cp "$private_hooks/pre-commit" "$TMP/private-before"
  installed 'private activation is idempotent'
  cmp -s "$private_hooks/pre-commit" "$TMP/private-before" && ok 'private reinstall preserves hook bytes' || bad 'private reinstall'
  if python3 - "$private_hooks/origin" "$dispatch" <<'PY'
import json
import os
import sys
# The installer records the CANONICAL path (Path.resolve()); on macOS mktemp lives under
# /var, a symlink to /private/var, so compare canonical forms, not spellings.
with open(sys.argv[1], encoding="utf-8") as stream:
    assert os.path.realpath(json.load(stream)) == os.path.realpath(sys.argv[2])
PY
  then ok 'private origin is stored without lossy path delimiters'; else bad 'private origin encoding'; fi
  printf 'user-owned\n' > "$private_hooks/custom-data"
  old_private_gate="$gate"; gate="$TMP/private gate upgraded.sh"; make_gate "$gate"
  installed 'managed private wrappers refresh when the gate moves'
  ! cmp -s "$private_hooks/pre-commit" "$TMP/private-before" && ok 'owned wrapper was refreshed' || bad 'stale owned wrapper preserved'
  grep -Fxq user-owned "$private_hooks/custom-data" && ok 'unrelated private entry survived refresh' || bad 'unrelated private entry lost'
  blocked 'refreshed private wrapper executes the relocated gate'
  cp "$private_hooks/origin" "$TMP/private-origin"
  printf '\377' > "$private_hooks/origin"
  unavailable 'malformed private origin reports unavailable'
  ! grep -q Traceback "$TMP/install.out" && ok 'malformed private origin has no traceback' || bad 'malformed origin traceback'
  cp "$TMP/private-origin" "$private_hooks/origin"
  gate="$old_private_gate"
else
  bad 'private worktree hooksPath missing'
fi
# A command-scope override must not make a failed verification leave latent worktree config.
git config --worktree core.hooksPath "$dispatch"
cp "$private_hooks/pre-commit" "$TMP/private-before-rollback"
code=0
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$dispatch" \
  sh "$INSTALL" "$gate" "$repo" > "$TMP/install.out" 2>&1 || code=$?
if [ "$code" -ne 0 ] && [ "$(git config --worktree --get core.hooksPath)" = "$dispatch" ] \
    && cmp -s "$private_hooks/pre-commit" "$TMP/private-before-rollback"; then
  ok 'failed override verification restores prior worktree hooksPath'
else cat "$TMP/install.out"; bad 'worktree hooksPath rollback'; fi
git config --worktree --add core.hooksPath "$TMP/second hooks value"
before_values=$(git config --worktree --get-all core.hooksPath)
code=0
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$dispatch" \
  sh "$INSTALL" "$gate" "$repo" > "$TMP/install.out" 2>&1 || code=$?
after_values=$(git config --worktree --get-all core.hooksPath)
if [ "$code" -ne 0 ] && [ "$after_values" = "$before_values" ]; then
  ok 'rollback preserves duplicate worktree hooksPath values in order'
else cat "$TMP/install.out"; bad 'duplicate worktree hooksPath rollback'; fi
git config --worktree --unset-all core.hooksPath
code=0
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$dispatch" \
  sh "$INSTALL" "$gate" "$repo" > "$TMP/install.out" 2>&1 || code=$?
if [ "$code" -ne 0 ] && ! git config --worktree --get core.hooksPath >/dev/null 2>&1; then
  ok 'failed override verification removes newly-created worktree setting'
else cat "$TMP/install.out"; bad 'new worktree hooksPath rollback'; fi
installed 'private activation recovers after an overriding config disappears'
cd "$main"; : > "$GATE_LOG"
git commit -q --allow-empty -m unaffected-main
grep -Fxq shared "$GATE_LOG" && ! grep -q '^pre-commit|' "$GATE_LOG" && ok 'main retains its original hook chain' || bad 'main changed'
cd "$linked"
# Passing guard must still execute the old hooks, including hook types we do not gate.
printf '#!/bin/sh\nprintf "guard:%%s\\n" "$1" >> "$GATE_LOG"\n[ "$1" != pre-push ] || cat > "$GATE_LOG.guard-stdin"\n' > "$gate"
printf '#!/bin/sh\ncat > "$GATE_LOG.original-stdin"\nprintf "%%s\\n" "$@" > "$GATE_LOG.args"\nexit 19\n' > "$main/.git/hooks/pre-push"
chmod +x "$main/.git/hooks/pre-push"
mkdir "$dispatch/lib"
printf '#!/bin/sh\nprintf "message-hook\\n" >> "$GATE_LOG"\nexit 0\n' > "$dispatch/lib/check.sh"
printf '#!/bin/sh\nexec sh "$(dirname "$0")/lib/check.sh" "$@"\n' > "$dispatch/commit-msg"
chmod +x "$dispatch/commit-msg"
: > "$GATE_LOG"
git commit --allow-empty -qm chained
grep -Fxq shared "$GATE_LOG" && grep -Fxq message-hook "$GATE_LOG" && ok 'guard preserves old commit chain and later-added commit-msg hook' || bad 'hook chain lost'
printf 'refs/heads/a a refs/heads/b b\nrefs/heads/c c refs/heads/d d\n' > "$TMP/refs"
code=0
git hook run --to-stdin="$TMP/refs" pre-push -- origin 'space remote' || code=$?
if [ "$code" -ne 0 ] && cmp -s "$TMP/refs" "$GATE_LOG.guard-stdin" && cmp -s "$TMP/refs" "$GATE_LOG.original-stdin" && grep -Fxq 'space remote' "$GATE_LOG.args"; then
  ok 'push preserves stdin/arguments for both checks and propagates original failure'
else bad 'push forwarding'; fi
# Gate removal must not silently disable the private guard.
rm "$gate"
before=$(git rev-parse HEAD)
if git commit --allow-empty -qm missing-private-gate > "$TMP/commit.out" 2>&1; then bad 'removed private gate allowed commit';
elif [ "$before" = "$(git rev-parse HEAD)" ]; then ok 'removed private gate blocks commit'; else bad 'removed private gate changed HEAD'; fi

echo '=== RESULT ==='
if [ "$fails" -eq 0 ]; then echo 'ALL PASS'; else echo "$fails FAILED"; exit 1; fi
