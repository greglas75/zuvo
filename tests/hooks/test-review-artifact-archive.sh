#!/usr/bin/env bash
# Contract for archiving a review artifact's proof.
#
# The defect this guards: coverage is TWO files, both gitignored and per-checkout, so a proof
# written inside a worktree dies with `git worktree remove`. Measured 2026-09-18 on
# tgm-survey-platform — 158 artifacts pointing at a missing proof, 3 recoverable across 243
# checkouts and 3811 proof filenames. The remedy has to fire WITHOUT anyone remembering it,
# which is why it is a PostToolUse hook and not a sentence in five SKILL.md files.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/zuvo-archive-review-artifact.sh"
SYNC="$ROOT/scripts/review-artifact-sync.sh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
[ -f "$HOOK" ] || { bad "hooks/zuvo-archive-review-artifact.sh missing"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export ZUVO_REVIEW_ARCHIVE="$TMP/archive"
# Sandbox HOME: the hook prefers ~/.zuvo/review-artifact-sync.sh, which must not stand in for this tree.
export HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null PG_REVIEW_PROOF_CUTOFF=1
mkdir -p "$HOME"; unset CLAUDE_PLUGIN_ROOT

# A throwaway repo with one artifact + proof pair.
REPO="$TMP/repo"; mkdir -p "$REPO/memory/reviews" "$REPO/zuvo/proofs"
git -C "$REPO" init -q 2>/dev/null
printf 'REVIEW BY: a\nREVIEW BY: b\n' > "$REPO/zuvo/proofs/p-adversarial.txt"
cat > "$REPO/memory/reviews/aaa..bbb-demo.md" <<'ART'
<!-- zuvo-review -->
range: aaaaaaa..bbbbbbb
files: src/one.ts
adversarial: zuvo/proofs/p-adversarial.txt
verdict: APPROVE
-->
ART
fire() { jq -cn --arg p "$1" '{tool_input:{file_path:$p}}' | bash "$HOOK" >/dev/null 2>&1; printf '%s' "$?"; }

# 1. Writing the artifact archives the PAIR — no one had to remember.
rc=$(fire "$REPO/memory/reviews/aaa..bbb-demo.md")
if [ "$rc" = "0" ] && [ -f "$ZUVO_REVIEW_ARCHIVE/repo/reviews/aaa..bbb-demo.md" ] \
   && [ -f "$ZUVO_REVIEW_ARCHIVE/repo/proofs/aaa..bbb-demo/zuvo/proofs/p-adversarial.txt" ]; then
  pass "writing an artifact archives both it and its proof"
else bad "the pair was not archived (hook rc=$rc) — the proof still dies with its worktree"; fi

# 2. The proof is keyed by ARTIFACT, not by its own filename. Proof names are NOT unique (a run
# passing a fixed --artifact name collides with every other run that did the same), and keying on
# the basename would let --restore hand an artifact somebody else's proof — manufacturing
# coverage, which is worse than the missing proof it set out to fix.
mkdir -p "$REPO/memory/reviews"
printf 'REVIEW BY: x\nREVIEW BY: y\nDIFFERENT\n' > "$REPO/zuvo/proofs/p-adversarial.txt.2"
cat > "$REPO/memory/reviews/ccc..ddd-other.md" <<'ART'
<!-- zuvo-review -->
range: ccccccc..ddddddd
files: src/two.ts
adversarial: zuvo/proofs/p-adversarial.txt.2
verdict: APPROVE
-->
ART
fire "$REPO/memory/reviews/ccc..ddd-other.md" >/dev/null
if [ -f "$ZUVO_REVIEW_ARCHIVE/repo/proofs/ccc..ddd-other/zuvo/proofs/p-adversarial.txt.2" ] \
   && cmp -s "$ZUVO_REVIEW_ARCHIVE/repo/proofs/aaa..bbb-demo/zuvo/proofs/p-adversarial.txt" "$REPO/zuvo/proofs/p-adversarial.txt"; then
  pass "each proof is stored under its own artifact, so two runs cannot overwrite each other"
else bad "proofs share a namespace — --restore could hand back the wrong one"; fi

# 3. Restore brings the right file back, byte for byte.
rm -f "$REPO/zuvo/proofs/p-adversarial.txt"
bash "$SYNC" --restore "$REPO" >/dev/null 2>&1
if [ -f "$REPO/zuvo/proofs/p-adversarial.txt" ] \
   && cmp -s "$REPO/zuvo/proofs/p-adversarial.txt" "$ZUVO_REVIEW_ARCHIVE/repo/proofs/aaa..bbb-demo/zuvo/proofs/p-adversarial.txt"; then
  pass "--restore returns the artifact's own proof, byte for byte"
else bad "--restore did not return the correct proof"; fi

# write_art <name> <header-lines> — an artifact whose proof header is <header-lines> (printf %b).
write_art() { printf '<!-- zuvo-review -->\nrange: aaaaaaa..bbbbbbb\nfiles: src/one.ts\n%b\nverdict: APPROVE\n' "$2" \
  > "$REPO/memory/reviews/$1.md"; }
AR="$ZUVO_REVIEW_ARCHIVE/repo/proofs"

# Same basename: two proofs sharing one. Bug: a basename key stores one and hands it back for both —
# manufactured coverage for the second review.
mkdir -p "$REPO/zuvo/proofs/a" "$REPO/zuvo/proofs/b" "$TMP/orig"
printf 'REVIEW BY: a1\nREVIEW BY: a2\n' > "$REPO/zuvo/proofs/a/adv.txt"
printf 'REVIEW BY: b1\nREVIEW BY: b2\nB\n' > "$REPO/zuvo/proofs/b/adv.txt"
cp "$REPO/zuvo/proofs/a/adv.txt" "$TMP/orig/a.txt"; cp "$REPO/zuvo/proofs/b/adv.txt" "$TMP/orig/b.txt"
write_art sss..ttt-same 'adversarial: zuvo/proofs/a/adv.txt\nadversarial: zuvo/proofs/b/adv.txt'
fire "$REPO/memory/reviews/sss..ttt-same.md" >/dev/null
rm -f "$REPO/zuvo/proofs/a/adv.txt" "$REPO/zuvo/proofs/b/adv.txt"
bash "$SYNC" --restore "$REPO" --slug sss..ttt-same >/dev/null 2>&1
if cmp -s "$REPO/zuvo/proofs/a/adv.txt" "$TMP/orig/a.txt" && cmp -s "$REPO/zuvo/proofs/b/adv.txt" "$TMP/orig/b.txt"; then
  pass "two proofs with one basename are archived and restored each byte for byte"
else bad "same-basename proofs were not both archived and restored to their own paths"; fi

# adv-proof alias. Bug: the adv-proof: alias the gate accepts was never archived.
printf 'REVIEW BY: x\nREVIEW BY: y\n' > "$REPO/zuvo/proofs/alias.txt"
write_art uuu..vvv-alias 'adv-proof: zuvo/proofs/alias.txt'
fire "$REPO/memory/reviews/uuu..vvv-alias.md" >/dev/null
[ -f "$AR/uuu..vvv-alias/zuvo/proofs/alias.txt" ] && pass "an adv-proof: ref is archived" \
  || bad "the adv-proof: alias was ignored by --archive"

# Comma list. Bug: a comma-listed header was read as one prose value and archived nothing.
printf 'REVIEW BY: x\nREVIEW BY: y\nA\n' > "$REPO/zuvo/proofs/ca.txt"
printf 'REVIEW BY: x\nREVIEW BY: y\nB\n' > "$REPO/zuvo/proofs/cb.txt"
write_art www..xxx-comma 'adversarial: zuvo/proofs/ca.txt, zuvo/proofs/cb.txt'
fire "$REPO/memory/reviews/www..xxx-comma.md" >/dev/null
[ -f "$AR/www..xxx-comma/zuvo/proofs/ca.txt" ] && [ -f "$AR/www..xxx-comma/zuvo/proofs/cb.txt" ] \
  && pass "every comma-listed proof is archived" || bad "a comma-listed proof header archived nothing"

# Legacy layout: an archive written before path keys holds <stem>/<basename> of the FIRST ref only. Bug guarded:
# restore stops reading it, or hands that one file to a later ref that shares its basename.
mkdir -p "$AR/kkk..lll-legacy"
printf 'REVIEW BY: l1\nREVIEW BY: l2\n' > "$AR/kkk..lll-legacy/p.txt"
write_art kkk..lll-legacy 'adversarial: zuvo/proofs/x/p.txt\nadversarial: zuvo/proofs/y/p.txt'
bash "$SYNC" --restore "$REPO" --slug kkk..lll-legacy >/dev/null 2>&1
if cmp -s "$REPO/zuvo/proofs/x/p.txt" "$AR/kkk..lll-legacy/p.txt" && [ ! -e "$REPO/zuvo/proofs/y/p.txt" ]; then
  pass "a legacy-keyed archive restores the first ref only"
else bad "legacy restore: first ref not restored, or its file handed to the second ref too"; fi

# Escaping second ref. Bug guarded: containment checked on the first ref only, so a later `../` ref
# reads outside the repo on archive and writes outside it on restore.
printf 'REVIEW BY: x\nREVIEW BY: y\n' > "$REPO/zuvo/proofs/first.txt"
printf 'OUTSIDE-CANARY\n' > "$TMP/outside.txt"
write_art ooo..ppp-escape 'adversarial: zuvo/proofs/first.txt\nadversarial: ../outside.txt'
fire "$REPO/memory/reviews/ooo..ppp-escape.md" >/dev/null
if [ -f "$AR/ooo..ppp-escape/zuvo/proofs/first.txt" ] && [ ! -e "$AR/outside.txt" ]; then
  pass "archive copies the contained first ref and reads nothing through the escaping second one"
else bad "archive: first ref missing, or the ../ ref was read from outside the repo"; fi
rm -f "$TMP/outside.txt"; printf 'PLANTED\n' > "$AR/outside.txt"
bash "$SYNC" --restore "$REPO" --slug ooo..ppp-escape >/dev/null 2>&1
[ ! -e "$TMP/outside.txt" ] && pass "restore writes nothing above the repo for an escaping second ref" \
  || bad "restore wrote ../outside.txt above the repo"

# Over the ref cap. Bug: an artifact citing more proofs than the gate reads archived 0 of them silently.
caps=""; i=1; while [ "$i" -le 17 ]; do caps="${caps}adversarial: zuvo/proofs/cap$i.txt\n"; i=$((i + 1)); done
write_art qqq..rrr-cap "$caps"
out="$(bash "$SYNC" --archive "$REPO" --slug qqq..rrr-cap 2>&1)"
printf '%s' "$out" | grep -q 'qqq..rrr-cap.md.*cap' && pass "an over-cap proof header is named in the archive output" \
  || bad "an over-cap proof header archived nothing and said nothing: $out"

# 3b. A BARE RELATIVE path must archive too. The first version of this test only ever fed absolute
# paths, so it passed while `*/memory/reviews/*.md` silently failed to match `memory/reviews/x.md`
# — the leading `*/` requires a literal slash before `memory`. A test that only exercises the easy
# shape of an input is how a pattern bug ships green.
rm -rf "$ZUVO_REVIEW_ARCHIVE/repo/reviews/ggg..hhh-rel.md"
cp "$REPO/memory/reviews/aaa..bbb-demo.md" "$REPO/memory/reviews/ggg..hhh-rel.md"
( cd "$REPO" && jq -cn '{tool_input:{file_path:"memory/reviews/ggg..hhh-rel.md"}}' | bash "$HOOK" >/dev/null 2>&1 )
if [ -f "$ZUVO_REVIEW_ARCHIVE/repo/reviews/ggg..hhh-rel.md" ]; then
  pass "a bare relative artifact path is archived, not silently skipped"
else bad "a relative path fell through the case pattern — the archive never ran"; fi

# 3c. The hook must not depend on a binary stock macOS does not ship. `timeout` is GNU coreutils;
# neither it nor gtimeout exists on a clean macOS, and hard-coding it made the archive a silent
# no-op there — the exact failure the hook exists to end.
if grep -qE 'for _to in timeout gtimeout' "$HOOK"; then
  pass "the timeout wrapper degrades to running unbounded instead of not running"
else bad "the hook hard-depends on \`timeout\`; stock macOS has neither it nor gtimeout"; fi

# 3d. A FAILING archive must stay fail-open AND leave a trace. Silence here would reproduce the
# very shape that lost 155 proofs: an archive that stopped working and looked exactly like one
# that was working.
badrepo="$TMP/badrepo"; mkdir -p "$badrepo/memory/reviews"; git -C "$badrepo" init -q 2>/dev/null
cp "$REPO/memory/reviews/aaa..bbb-demo.md" "$badrepo/memory/reviews/iii..jjj-fail.md"
ZUVO_REVIEW_ARCHIVE="/dev/null/cannot-exist" jq -cn --arg p "$badrepo/memory/reviews/iii..jjj-fail.md" \
  '{tool_input:{file_path:$p}}' | ZUVO_REVIEW_ARCHIVE="/dev/null/cannot-exist" bash "$HOOK" >/dev/null 2>&1
rc=$?
if [ "$rc" = "0" ]; then pass "an archive failure never blocks the tool call (fail-open)"
else bad "the hook exited $rc on a failed archive — bookkeeping must not block a tool call"; fi
if grep -q 'FAILED rc=' "$HOOK"; then
  pass "a failed archive is recorded rather than swallowed"
else bad "archive failures are discarded to /dev/null — a broken archive looks exactly like a working one"; fi

# 4. An unmarked artifact is not archived — it grants no coverage, and a half-written file will
# trigger the hook again on the write that adds the marker.
printf 'no marker here\n' > "$REPO/memory/reviews/eee..fff-draft.md"
fire "$REPO/memory/reviews/eee..fff-draft.md" >/dev/null
if [ ! -f "$ZUVO_REVIEW_ARCHIVE/repo/reviews/eee..fff-draft.md" ]; then
  pass "an artifact without the zuvo-review marker is skipped"
else bad "a markerless artifact was archived"; fi

# 5. The hook must be wired for Write AND Edit, or it only fires on some of the writes.
python3 - "$ROOT/hooks/hooks.json" <<'PY' && pass "hooks.json registers it on Write|Edit" || bad "not registered on Write|Edit in hooks.json"
import json,sys
d=json.load(open(sys.argv[1]))
ok=any('zuvo-archive-review-artifact' in json.dumps(e) and 'Write' in e.get('matcher','') and 'Edit' in e.get('matcher','')
       for e in d['hooks']['PostToolUse'])
sys.exit(0 if ok else 1)
PY

# 6. Every skill that writes an artifact must document the manual fallback, because the hook is
# Claude-Code-only — Codex/Cursor/Antigravity/Kimi have no PostToolUse path to it. All five load
# review-artifact.md, so the instruction belongs there once.
if grep -q -- '--archive' "$ROOT/shared/includes/review-artifact.md"; then
  pass "the shared artifact contract carries the manual --archive fallback"
else bad "review-artifact.md never mentions --archive — non-Claude hosts silently keep losing proofs"; fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
