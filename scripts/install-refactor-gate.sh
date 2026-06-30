#!/bin/sh
# install-refactor-gate.sh — ensure the refactor commit-gate is active for a TARGET repo.
# Called by zuvo:refactor Phase 0. Idempotent, fail-open, never clobbers user hooks,
# never mutates a version-controlled hooksPath (Husky etc.).
#
# Targets the hooks dir git ACTUALLY uses (`git rev-parse --git-path hooks`, which
# honours core.hooksPath). In a zuvo-managed environment core.hooksPath is the global
# ~/.claude/hooks and install.sh has already wired the gate there (same MARK) → this
# no-ops. In a plain repo (no hooksPath) it installs into .git/hooks. Either way the
# gate fires for every commit and no-ops when the repo has no active refactor CONTRACT.
#
# Usage: install-refactor-gate.sh <gate-abs-path> [repo-root]
set -u
GATE_ABS=$1
REPO=${2:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}
MARK="# >>> zuvo:refactor-gate"

[ -n "$GATE_ABS" ] || { echo "[refactor-gate] no gate path given — skip"; exit 0; }
case "$GATE_ABS" in /*) : ;; *) echo "[refactor-gate] gate path must be absolute — skip"; exit 0 ;; esac
cd "$REPO" 2>/dev/null || { echo "[refactor-gate] repo unreadable — skip (fail-open)"; exit 0; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "[refactor-gate] not a git repo — skip"; exit 0; }
# Pick the hooks dir git will ACTUALLY run for this repo.
#  - unset hooksPath                      -> .git/hooks
#  - external hooksPath (e.g. zuvo's global ~/.claude/hooks dispatcher, which execs the
#    repo-local .git/hooks/<hook>)         -> .git/hooks  (the dispatcher bridges to it)
#  - in-repo hooksPath (Husky .husky/)     -> that dir, BUT never if it is version-controlled
hp=$(git config core.hooksPath 2>/dev/null || true)
HOOKS="$REPO/.git/hooks"
if [ -n "$hp" ]; then
  case "$hp" in /*) hpabs="$hp" ;; *) hpabs="$REPO/$hp" ;; esac
  case "$hpabs/" in
    "$REPO"/*)                                   # hooksPath lives inside the repo
      rel=${hpabs#"$REPO"/}
      if [ -n "$(git ls-files "$rel" 2>/dev/null)" ]; then
        echo "[refactor-gate] core.hooksPath ('$rel') is version-controlled — NOT auto-installing."
        echo "  Add to '$rel/pre-commit' and '$rel/pre-push':  [ -x \"$GATE_ABS\" ] && \"$GATE_ABS\" pre-commit|pre-push || exit 1"
        exit 0
      fi
      HOOKS="$hpabs"
      ;;
    *) HOOKS="$REPO/.git/hooks" ;;               # external hooksPath -> dispatcher bridges to .git/hooks
  esac
fi
mkdir -p "$HOOKS" 2>/dev/null || { echo "[refactor-gate] cannot write $HOOKS — skip (fail-open)"; exit 0; }

for mode in pre-commit pre-push; do
  f="$HOOKS/$mode"
  if [ -f "$f" ] && grep -q "$MARK" "$f" 2>/dev/null; then
    continue                                   # already wired (by install.sh global or a prior run)
  fi
  if [ -f "$f" ]; then
    echo "[refactor-gate] existing $mode hook (no zuvo marker) — not modified. To chain, add:"
    echo "    [ -x \"$GATE_ABS\" ] && \"$GATE_ABS\" $mode || exit 1"
    continue
  fi
  {
    echo "#!/bin/sh"
    echo "$MARK  (auto-installed by zuvo:refactor; fail-open)"
    echo "[ -x \"$GATE_ABS\" ] && exec \"$GATE_ABS\" $mode"
    echo "exit 0"
    echo "# <<< zuvo:refactor-gate"
  } > "$f"
  chmod +x "$f" 2>/dev/null || true
  echo "[refactor-gate] installed $mode -> $f"
done
exit 0
