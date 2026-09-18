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
# Five skills write these artifacts (review, build, execute, ship, write-tests — the set is
# derived from the tree, see the table in that include) and all five load
# shared/includes/review-artifact.md, so a written instruction there reaches every one of
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
# `*/memory/reviews/*.md` alone does NOT match a BARE relative path: the leading `*/` requires a
# literal slash before `memory`, so `memory/reviews/x.md` falls through and the artifact is never
# archived. The harness usually passes an absolute path, which is exactly why the first test of
# this hook missed it — it only fed absolute paths.
case "$path" in
  memory/reviews/*.md|*/memory/reviews/*.md) ;;
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
#
# `timeout` is GNU coreutils and stock macOS ships NEITHER it nor `gtimeout` — the documented
# target platform. Hard-coding it made the whole archive a no-op there, silently, which is the
# failure this hook exists to end. (The same mistake was fixed in scripts/stqa.sh earlier the same
# day and then written again here, so: a bound is a nice-to-have, running is not.)
name="${path##*/}"
TO=""
for _to in timeout gtimeout; do
  command -v "$_to" >/dev/null 2>&1 && { TO="$_to 20"; break; }
done
# Fail-open stays (a bookkeeping error must never block a tool call), but NOT silent. A silently
# broken archive is indistinguishable from a working one — which is precisely how 155 proofs were
# lost without anyone noticing, and repeating that shape inside the fix for it would be absurd.
# Every failure leaves a dated line in the archive's own log, so "the archive stopped working" is
# a question the log answers instead of a discovery made months later.
alog="${ZUVO_REVIEW_ARCHIVE:-$HOME/.zuvo/review-archive}/archive.log"
mkdir -p "$(dirname "$alog")" 2>/dev/null || true
if out=$($TO bash "$SYNC" --archive "$root" --slug "${name%.md}" 2>&1); then
  :
else
  rc=$?
  printf '%s	FAILED rc=%s	%s	%s
' "$(date -u +%FT%TZ)" "$rc" "$name" \
    "$(printf '%s' "$out" | tr '\n\t' '  ' | cut -c1-300)" >> "$alog" 2>/dev/null || true
fi
exit 0
