#!/usr/bin/env bash
# PostToolUse hook (Write|Edit) — archive a review artifact and its proof the moment the
# artifact is written, outside every checkout.
#
# WHY A HOOK AND NOT A LINE IN THE SKILL. Review coverage is TWO files: the
# memory/reviews/*.md artifact and the zuvo/proofs/… file its `adversarial:` header names.
# `zuvo/` is gitignored, so both are per-checkout — and a proof written inside a worktree is
# destroyed by `git worktree remove`, with no copy anywhere. Measured 2026-09-18 on
# tgm-survey-platform: 158 artifacts pointed at a missing proof, and a search across 243
# checkouts and 3811 proof filenames recovered 3 of them. The other 155 reviews genuinely
# happened and their evidence no longer exists on the machine.
#
# Five skills write these artifacts (review, build, execute, ship, write-tests) and all five
# load shared/includes/review-artifact.md, so a written instruction there reaches every one of
# them — and would still be a thing an agent has to remember at the end of a long run, which is
# exactly the failure mode that produced the 155. A PostToolUse hook does not depend on
# remembering: the write itself triggers it.
#
# Fail-open and silent by design: this is bookkeeping, and a bookkeeping error must never block
# a tool call or add noise to a session. Every failure path exits 0.
set -uo pipefail

input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$path" ] || exit 0

# Only review artifacts. Matching on the directory (not the extension alone) keeps this off every
# other .md the session writes.
case "$path" in
  */memory/reviews/*.md) ;;
  *) exit 0 ;;
esac
[ -f "$path" ] || exit 0

# The artifact only grants coverage once it carries the marker; archiving a half-written file is
# pointless, and the write that adds the marker will trigger this hook again.
grep -q '<!-- zuvo-review -->' "$path" 2>/dev/null || exit 0

root=$(git -C "$(dirname "$path")" rev-parse --show-toplevel 2>/dev/null) || exit 0

# Resolve the helper. The order matters and the last two are the ones that make this work at
# all on a host where `install.sh` has never run: $root is the repo the ARTIFACT lives in — a
# product repo, which has no scripts/review-artifact-sync.sh — so resolving only against $HOME
# and $root meant the hook silently did nothing wherever ~/.zuvo was absent. The shipped copy
# sits next to this hook, one level up, and that is always present because it travels with the
# hook itself.
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
SYNC=""
for cand in "$HOME/.zuvo/review-artifact-sync.sh" \
            "${CLAUDE_PLUGIN_ROOT:-}/scripts/review-artifact-sync.sh" \
            "$_self_dir/../scripts/review-artifact-sync.sh" \
            "$root/scripts/review-artifact-sync.sh"; do
  [ -n "$cand" ] && [ -f "$cand" ] && { SYNC="$cand"; break; }
done
[ -n "$SYNC" ] || exit 0

# An older installed copy has no --archive mode; prefer a shipped copy that does rather than
# calling it and having it exit 2 into /dev/null.
if ! grep -q -- '--archive' "$SYNC" 2>/dev/null; then
  for cand in "${CLAUDE_PLUGIN_ROOT:-}/scripts/review-artifact-sync.sh" \
              "$_self_dir/../scripts/review-artifact-sync.sh"; do
    [ -n "$cand" ] && [ -f "$cand" ] && grep -q -- '--archive' "$cand" 2>/dev/null && { SYNC="$cand"; break; }
  done
fi

# Archive THIS pair only (--slug), not the whole repo: the hook fires on every artifact write and
# a full sweep would re-copy hundreds of pairs each time.
name="${path##*/}"
timeout 20 bash "$SYNC" --archive "$root" --slug "${name%.md}" >/dev/null 2>&1 || true
exit 0
