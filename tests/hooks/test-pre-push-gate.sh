#!/usr/bin/env bash
# Task 4 — pre-push gate. Feeds synthetic git-native pre-push stdin
# ("<localref> <localsha> <remoteref> <remotesha>") and asserts exit codes.
# Agent cases force ZUVO_AGENT=1 for determinism; the human case strips env.
set -u
# This suite exercises the CONTENT-KEY logic; the adversarial proof-of-work layer (added
# 2026-07-23) is covered by test-review-proof-gate.sh. Grandfather it off here so these
# fixtures test content-keying in isolation, exactly as they did before that layer existed.
export PG_REVIEW_PROOF_CUTOFF=99999999999

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/hooks/pre-push-gate.sh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
(
  cd "$TMP" || exit 1
  git init -q -b main 2>/dev/null || { git init -q; git symbolic-ref HEAD refs/heads/main; }
  git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
  echo base > base.txt; git add -A; git commit -qm base
) || { bad "fixture init"; echo "SOME FAILED"; exit 1; }
cd "$TMP" || exit 1
MAIN=$(git rev-parse HEAD)

# substantial feature: 3 prod files
git checkout -q -b feature
mkdir -p src; echo a > src/a.sh; echo b > src/b.sh; echo c > src/c.sh
git add -A; git commit -qm feat
FHEAD=$(git rev-parse HEAD)

# small: 1 prod file
echo tiny > src/tiny.sh; git add -A; git commit -qm tiny
SMALL=$(git rev-parse HEAD)

# docs-only (200 lines)
mkdir -p docs; for i in $(seq 1 200); do echo "l$i" >> docs/big.md; done
git add -A; git commit -qm docs
DOCS=$(git rev-parse HEAD)

ZEROS=0000000000000000000000000000000000000000

agent_gate() { ZUVO_AGENT=1 PG_REPO_ROOT="$TMP" bash "$GATE"; }     # stdin via pipe
human_gate() { env -i PATH="$PATH" PG_REPO_ROOT="$TMP" bash "$GATE"; }

# (a) substantial + unreviewed → exit 1
printf 'refs/heads/feature %s refs/heads/feature %s\n' "$FHEAD" "$MAIN" | agent_gate >/dev/null 2>&1
[ "$?" -eq 1 ] && pass "(a) substantial unreviewed push BLOCKED (exit 1)" || bad "(a) should block (exit 1)"

# (f) new branch (remote all-zeros) → merge-base..head, still evaluates → 1
printf 'refs/heads/feature %s refs/heads/feature %s\n' "$FHEAD" "$ZEROS" | agent_gate >/dev/null 2>&1
[ "$?" -eq 1 ] && pass "(f) new-branch uses merge-base, blocks unreviewed (exit 1)" || bad "(f) new-branch should evaluate+block"

# (e) escape valve → 0
printf 'refs/heads/feature %s refs/heads/feature %s\n' "$FHEAD" "$MAIN" | ZUVO_ALLOW_ADHOC=1 ZUVO_AGENT=1 PG_REPO_ROOT="$TMP" bash "$GATE" >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "(e) ZUVO_ALLOW_ADHOC=1 → pass (exit 0)" || bad "(e) adhoc escape should pass"

# (g) human push (no agent env) → 0 even though substantial+unreviewed
printf 'refs/heads/feature %s refs/heads/feature %s\n' "$FHEAD" "$MAIN" | human_gate >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "(g) human push exempt (exit 0)" || bad "(g) human push should pass"

# now make it reviewed: artifact covering the REAL range MAIN..FHEAD + files a/b/c
mkdir -p memory/reviews
cat > memory/reviews/cov.md <<ART
<!-- zuvo-review -->
range: $MAIN..$FHEAD
files: src/a.sh, src/b.sh, src/c.sh
verdict: PASS
-->
ART
# (b) reviewed → 0
printf 'refs/heads/feature %s refs/heads/feature %s\n' "$FHEAD" "$MAIN" | agent_gate >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "(b) reviewed range → pass (exit 0)" || bad "(b) reviewed should pass"

# (c) small range → 0
printf 'refs/heads/feature %s refs/heads/feature %s\n' "$SMALL" "$FHEAD" | agent_gate >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "(c) small (1-file) range → pass (exit 0)" || bad "(c) small range should pass"

# (d) docs-only → 0
printf 'refs/heads/feature %s refs/heads/feature %s\n' "$DOCS" "$SMALL" | agent_gate >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "(d) docs-only range → pass (exit 0)" || bad "(d) docs-only should pass"

# (h1) malformed stdin (not native, not 'git push') → fail-open 0
printf 'this is garbage not a pre-push line\n' | agent_gate >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "(h1) malformed stdin → fail-open (exit 0)" || bad "(h1) malformed should fail-open"

# (h2) native format but non-existent repo → fail-open 0
printf 'refs/heads/x %s refs/heads/x %s\n' "$FHEAD" "$MAIN" | ZUVO_AGENT=1 PG_REPO_ROOT="$TMP/nope-zzz" bash "$GATE" >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "(h2) non-existent repo → fail-open (exit 0)" || bad "(h2) no-repo should fail-open"

# (h3) garbled local sha (non-hex) → skip line → 0
printf 'refs/heads/feature NOTAHEXSHA refs/heads/feature %s\n' "$MAIN" | agent_gate >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "(h3) garbled sha line skipped → fail-open (exit 0)" || bad "(h3) garbled sha should skip"

# --- PreToolUse mode (Claude/Codex): content-keyed via merge-base..HEAD ---
# HEAD = the 3-prod-file commit, so merge-base(main)..HEAD = src/a,b,c only.
git checkout -q -B ptu "$FHEAD" 2>/dev/null
rm -f memory/reviews/cov.md
pj() { printf '{"command":"git push origin ptu"}'; }

# (p1) agent + substantial unreviewed → BLOCK (works for Claude AND Codex via PreToolUse)
pj | env ZUVO_AGENT=1 PG_REPO_ROOT="$TMP" bash "$GATE" >/dev/null 2>&1
[ "$?" -eq 1 ] && pass "(p1) PreToolUse: agent push substantial unreviewed → BLOCK (exit 1)" || bad "(p1) should block"

# (p2) content-covering artifact → pass (no redundant review)
mkdir -p memory/reviews
cat > memory/reviews/cov.md <<ART
<!-- zuvo-review -->
range: $MAIN..$FHEAD
files: *
verdict: PASS
-->
ART
pj | env ZUVO_AGENT=1 PG_REPO_ROOT="$TMP" bash "$GATE" >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "(p2) PreToolUse: content-covered → pass (exit 0)" || bad "(p2) covered should pass"

# (p3) ZUVO_ALLOW_ADHOC → pass
rm -f memory/reviews/cov.md
pj | env ZUVO_ALLOW_ADHOC=1 ZUVO_AGENT=1 PG_REPO_ROOT="$TMP" bash "$GATE" >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "(p3) PreToolUse: ZUVO_ALLOW_ADHOC=1 → pass (exit 0)" || bad "(p3) adhoc should pass"

# (p4) human (no agent env) → pass even though unreviewed (G8)
pj | env -i PATH="$PATH" PG_REPO_ROOT="$TMP" bash "$GATE" >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "(p4) PreToolUse: human push exempt (exit 0)" || bad "(p4) human should pass"

# (p5) legacy fallback when lib unavailable: point at a dir with no hooks/lib → runs.log path
NOLIB="$TMP/nolibhome"; mkdir -p "$NOLIB"
cp "$GATE" "$NOLIB/pre-push-gate.sh"   # copied alone → no sibling lib/ → PG_LIB_LOADED unset
printf '{"command":"git push origin ptu"}\n' | env HOME="$TMP/fakehome" ZUVO_AGENT=1 PG_REPO_ROOT="$TMP" bash "$NOLIB/pre-push-gate.sh" >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "(p5) lib-absent → legacy runs.log fallback (no runs.log → warn+pass)" || bad "(p5) legacy fallback regressed"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
