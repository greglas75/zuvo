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

echo '=== RESULT ==='
if [ "$fails" -eq 0 ]; then echo 'ALL PASS'; else echo "$fails FAILED"; exit 1; fi
