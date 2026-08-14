#!/usr/bin/env bash
# Two more farm-reported skill gaps:
#   zuvo:review     — auditors read a FROZEN, unwritable checkout; the fix loop keeps the live tree.
#   zuvo:mutation-test — content anchors instead of line numbers, and a checkpoint after every
#                        mutation so a killed run resumes instead of redoing 50 expensive steps.
#
# WHAT THIS FILE CAN AND CANNOT PROVE, stated up front so nobody reads more into a green run:
#   * The review block is real shell, so it is EXTRACTED and EXECUTED against a real repo — creation,
#     unwritability and teardown are behaviourally verified.
#   * mutation-test ships no executable; its anchors/checkpoint are a CONTRACT an agent follows.
#     Those assertions are structural (the contract is stated, completely, and in the right phase).
#     A structural assertion cannot prove an agent obeys — it proves the instruction it would have
#     to disobey exists and is unambiguous. That is the honest ceiling here.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REV="$ROOT/skills/review/SKILL.md"
MUT="$ROOT/skills/mutation-test/SKILL.md"
TMP="$(mktemp -d)"
cleanup(){ chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
fails=0
ok(){ echo "  ✓ $1"; }
bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

echo "=== review: read-only audit checkout (executed) ==="

BLOCK=$(awk '/^REVIEW_TREE=\$\(mktemp -d\)/,/^fi$/' "$REV")
[ -n "$BLOCK" ] && ok "audit-checkout block extracted from the skill" \
                || bad "could not extract the audit-checkout block — re-anchor this test"

mkdir -p "$TMP/r"; cd "$TMP/r"
git init -q; git config user.email t@t; git config user.name t
echo a > f; git add f; git commit -qm base
REVIEWED_THROUGH=$(git rev-parse HEAD); export REVIEWED_THROUGH

OUT=$(sh -c "$BLOCK"'; echo "TREE=$REVIEW_TREE"' 2>&1)
TREE=$(printf '%s' "$OUT" | sed -n 's/^TREE=//p' | tail -1)
case "$OUT" in *"read-only @"*) ok "reports a read-only tree pinned to the reviewed SHA" ;;
  *"live checkout"*) bad "fell back to the live checkout in a clean repo — the worktree path is broken" ;;
  *) bad "no audit-tree verdict printed at all; got: ${OUT:-<empty>}" ;; esac

if [ -n "$TREE" ] && [ -d "$TREE" ]; then
  ok "audit worktree exists on disk"
  # The point of the whole change: an auditor CANNOT write here.
  if (echo x > "$TREE/should-fail") 2>/dev/null; then
    bad "the audit tree is WRITABLE — this is convention again, not enforcement"
  else
    ok "the audit tree rejects writes (enforcement, not etiquette)"
  fi
  [ "$(cd "$TREE" && git rev-parse HEAD)" = "$REVIEWED_THROUGH" ] \
    && ok "the audit tree is pinned to REVIEWED_THROUGH" || bad "audit tree is not at the reviewed commit"

  # Teardown must work THROUGH the read-only bit it set, or every aborted review leaks a worktree
  # that git keeps listing and the user cannot delete without knowing to chmod first.
  chmod -R u+w "$TREE" 2>/dev/null && git worktree remove --force "$TREE" 2>/dev/null
  [ -d "$TREE" ] && bad "documented teardown did not remove the audit tree" \
                 || ok "documented teardown removes it despite the read-only bit"
  git worktree list | grep -q "$TREE" && bad "worktree still registered after teardown" \
                                      || ok "no stale worktree registration left behind"
else
  bad "no audit worktree was created"
fi

cd "$ROOT"
grep -q 'audit_tree:' "$REV" && ok "Validity Gate carries an audit_tree field" \
                             || bad "the verdict never records which tree the auditors read"
grep -q 'Do NOT use this for the fix loop' "$REV" \
  && ok "the fix loop is explicitly kept on the live checkout" \
  || bad "nothing stops Phase 4 committing inside a detached frozen tree"

echo "=== mutation-test: anchors + checkpoint (contract assertions) ==="

grep -q '^| `continue` |' "$MUT" && ok "'continue' is a documented argument" || bad "'continue' missing from the argument table"

for field in 'symbol' 'original_norm' 'occurrence' 'file_sha'; do
  grep -q "\`$field\`" "$MUT" && ok "anchor field documented: $field" || bad "anchor field missing: $field"
done
grep -q 'collapsed to one space' "$MUT" \
  && ok "normalization is defined (a reformat must not invalidate every anchor)" \
  || bad "no normalization rule — anchors would die on the next formatter run"

# All three resolution outcomes must be named, especially the one that must NOT be guessed.
grep -q 'relocated(' "$MUT" && ok "relocation outcome is recorded, not silent" || bad "relocation is not recorded"
grep -qi 'SKIP this mutation' "$MUT" && ok "an unresolvable anchor SKIPS rather than applying at a stale line" \
  || bad "nothing forbids applying a mutation at a stale line — it would corrupt a different statement"
grep -q 'not a score' "$MUT" && ok "a skipped mutation cannot be averaged away into a score" \
  || bad "a partial plan could still be reported as a score"

grep -q 'applied_to' "$MUT" && ok "checkpoint records the in-flight mutation (crash safety)" \
  || bad "no record of a mutation left on disk by a killed run"
grep -q 'After each mutation resolves' "$MUT" \
  && ok "the checkpoint is written per mutation, not batched at the end" \
  || bad "checkpoint timing unspecified — a killed run still loses everything"
grep -q 'never silently treat `continue` as' "$MUT" \
  && ok "'continue' with no state file must not masquerade as a fresh full run" \
  || bad "resume-vs-fresh scores could be conflated"

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $fails"; exit 1; fi
