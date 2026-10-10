#!/usr/bin/env bash
# test-review-pipeline-smoke.sh — SMOKE1: one oversized shell change goes through the whole review
# pipeline — build-review-patch | adversarial-review.sh --multi, a review artifact citing two proofs,
# review-artifact-sync.sh --check and pg-uncovered-files — and every tool agrees on the verdict.
#
# It catches the cross-tool defects no single tool's test sees: a lifecycle trailer that breaks hunk
# packing, a split review whose proof the gate still refuses, a classifier that disagrees with --check.
#
# ZUVO_ADV_NO_CHUNK and ZUVO_REVIEW_PATCH_NO_CONTEXT are deliberately passed through from the caller:
# setting either one replays the behaviour before the hunk split or the lifecycle trailer, and the
# assertions guarding that half must then fail.
#
# Standalone dialect (pass()/bad(), final ALL PASS). bash 3.2-safe.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BRP="$ROOT/scripts/zuvo-home/build-review-patch"
ADV="$ROOT/scripts/adversarial-review.sh"
RAS="$ROOT/scripts/review-artifact-sync.sh"
PUF="$ROOT/scripts/zuvo-home/pg-uncovered-files"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }
die()  { printf 'FAIL: setup: %s\n' "$1"; echo "SOME FAILED"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
export GIT_CONFIG_GLOBAL=/dev/null PG_REVIEW_PROOF_CUTOFF=1 HOME="$TMP/home" ZUVO_HOME="$TMP/home/.zuvo"
mkdir -p "$ZUVO_HOME"
# ZUVO_ADV_CHUNK would make the driver act as a chunk child; PG_PROOF_OPTIONAL is the CI waiver.
unset ZUVO_ADV_CHUNK PG_REPO_ROOT PG_PROOF_OPTIONAL ZUVO_OUTPUT_DIR

# ── fixture: a committed script with its trap and cleanup at the top, then three regions far apart ──
R="$TMP/repo"
mkdir -p "$R" || die "mkdir $R"
(
  cd "$R" || exit 1
  git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; } || exit 1
  git config user.email t@t.t && git config user.name t && git config commit.gpgsign false || exit 1
  printf 'zuvo/\nmemory/reviews/\n' > .gitignore
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' 'cleanup() {' '  kill -- -"$pg" 2>/dev/null' '}' 'trap cleanup EXIT INT TERM'
    for k in 1 2 3; do
      i=1; while [ "$i" -le 20 ]; do printf ': filler %d.%d\n' "$k" "$i"; i=$((i + 1)); done
      printf ': region %d\n' "$k"
    done
    printf ': tail\n'
  } > dev-stack.sh
  git add -A && git commit -qm base || exit 1
  # Each region grows by 150 lines of ~80 chars and one unique marker line: three hunks of ~12k chars, one file
  # over the 30k cap.
  awk '/^: region [0-9]$/ { for (i = 1; i <= 150; i++) printf "echo \"region %s line %d padding padding padding padding padding padding padding\"\n", $3, i; printf "echo \"MARKER-H%s\"\n", $3; next } { print }' \
    dev-stack.sh > dev-stack.sh.new && mv dev-stack.sh.new dev-stack.sh || exit 1
  git add dev-stack.sh && git commit -qm work || exit 1
) >/dev/null 2>&1 || die "fixture repo could not be built"
BASE="$(git -C "$R" rev-parse HEAD~1)" || die "no base commit"
HEAD_SHA="$(git -C "$R" rev-parse HEAD)" || die "no head commit"

# ── two lanes that keep every call's prompt as its own numbered file, so every part sent is seen ──
BIN="$TMP/bin"; PARTS="$TMP/parts"
mkdir -p "$BIN" "$PARTS/mock-partlog-a" "$PARTS/mock-partlog-b" || die "mkdir lanes"
cat > "$BIN/mock-partlog-a" <<'MOCK'
#!/usr/bin/env bash
d="$SMOKE_PART_DIR/${0##*/}"
n=1
while ! ( set -C; : > "$d/$n.in" ) 2>/dev/null; do
  n=$((n + 1)); [ "$n" -le 999 ] || { echo "${0##*/}: cannot create a part file in $d" >&2; exit 1; }
done
cat > "$d/$n.in"
echo '{"findings":[]}'
MOCK
cp "$BIN/mock-partlog-a" "$BIN/mock-partlog-b" && chmod +x "$BIN/mock-partlog-a" "$BIN/mock-partlog-b" \
  || die "lane mocks"

# ── the review: the patch piped straight into the driver, as the review skill runs it ──
mkdir -p "$R/zuvo/proofs" "$R/memory/reviews" || die "mkdir proof dirs"
(
  cd "$R" || exit 1
  bash "$BRP" --base "$BASE" 2>"$TMP/brp.err" \
    | PATH="$BIN:$PATH" SMOKE_PART_DIR="$PARTS" ZUVO_ADVERSARIAL_TEST_HARNESS=1 \
      ZUVO_REVIEW_TEST_PROVIDERS="mock-partlog-a mock-partlog-b" \
      bash "$ADV" --multi --mode code --artifact zuvo/proofs/smoke-adversarial.txt >"$TMP/adv.out" 2>"$TMP/adv.err"
  printf '%s %s\n' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}" > "$TMP/rcs"
)
read -r BRP_RC ADV_RC < "$TMP/rcs" || die "pipeline statuses not recorded"
[ "$BRP_RC" = 0 ] || die "build-review-patch exited $BRP_RC: $(tr '\n' '|' < "$TMP/brp.err")"
PROOF="$R/zuvo/proofs/smoke-adversarial.txt"

# part_count <lane> — how many prompts the lane received.
part_count() { local n=0; while [ -f "$PARTS/$1/$((n + 1)).in" ]; do n=$((n + 1)); done; echo "$n"; }
NA="$(part_count mock-partlog-a)"; NB="$(part_count mock-partlog-b)"

# (1) Bug: one file over the cap is reviewed as a single cut prompt, or a lane misses a part.
if [ "$ADV_RC" = 0 ] && [ "$NA" -ge 2 ] && [ "$NA" = "$NB" ]; then
  pass "(1) the driver exits 0 and each lane reviews the one oversized file in $NA parts"
else
  bad "(1) driver rc=$ADV_RC, parts per lane a=$NA b=$NB — want rc 0 and the same >= 2 parts in both lanes (stderr: $(tail -3 "$TMP/adv.err" | tr '\n' '|'))"
fi

# (2) Bug: the tail hunks are cut and the proof says input_truncated=true, which the gate refuses.
if [ ! -s "$PROOF" ]; then
  bad "(2) no proof written at zuvo/proofs/smoke-adversarial.txt"
elif grep -qx 'input_truncated=true' "$PROOF"; then
  bad "(2) the proof records input_truncated=true — part of the change never reached a reviewer"
else
  pass "(2) the proof records no input_truncated=true"
fi

# block_counts <part> — "<blocks>/<trap lines>/<kill lines>": how many dev-stack.sh lifecycle blocks the prompt
# holds, and how many numbered trap-registration and cleanup-kill lines sit inside them.
block_counts() {
  awk '
    index($0, "=== CONTEXT: dev-stack.sh - ") == 1 { h++; inb = 1; next }
    $0 == "=== END CONTEXT ===" { inb = 0; next }
    inb && /^[0-9]+: trap cleanup EXIT INT TERM$/ { t++ }
    inb && /^[0-9]+: +kill -- -"\$pg" 2>\/dev\/null$/ { k++ }
    END { printf "%d/%d/%d", h, t, k }' "$1"
}

# (3) Bug: a part's reviewer sees the hunks without the trap/cleanup definitions they depend on — no block, an
# empty or cut block, or the block twice because it was packed as a hunk.
PER=""; WANT=""
for lane in mock-partlog-a mock-partlog-b; do
  n=1
  while [ -f "$PARTS/$lane/$n.in" ]; do
    PER="$PER${PER:+ }$(block_counts "$PARTS/$lane/$n.in")"
    WANT="$WANT${WANT:+ }1/1/1"
    n=$((n + 1))
  done
done
if [ -n "$PER" ] && [ "$PER" = "$WANT" ]; then
  pass "(3) every part, in both lanes, holds one lifecycle block with the trap line and the cleanup kill line once each"
else
  bad "(3) blocks/trap/kill per part=[$PER] — want one block holding both definitions in every part (want [$WANT])"
fi

# (4) Bug: the split drops a hunk (a reviewer never sees it) or packs one into two parts (reviewed twice, as two
# fragments).
HUNKS=""
for lane in mock-partlog-a mock-partlog-b; do
  for k in 1 2 3; do
    c=0
    for f in "$PARTS/$lane"/*.in; do
      [ -f "$f" ] && c=$((c + $(grep -cxF "+echo \"MARKER-H$k\"" "$f")))
    done
    HUNKS="$HUNKS${HUNKS:+ }${lane#mock-partlog-}:H$k=$c"
  done
done
if [ "$HUNKS" = "a:H1=1 a:H2=1 a:H3=1 b:H1=1 b:H2=1 b:H3=1" ]; then
  pass "(4) each of the three hunks reached exactly one part in each lane"
else
  bad "(4) hunk marker counts [$HUNKS] — want every hunk in exactly one part per lane"
fi

# ── the artifact: the driver's proof plus a second good proof, as a merged review cites them ──
printf 'REVIEW BY: P1\nREVIEW BY: P2\n' > "$R/zuvo/proofs/second.txt"
ART="memory/reviews/$(printf '%.7s' "$BASE")..$(printf '%.7s' "$HEAD_SHA")-smoke.md"
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: dev-stack.sh\nadversarial: zuvo/proofs/smoke-adversarial.txt, zuvo/proofs/second.txt\n' \
  "$BASE" "$HEAD_SHA" > "$R/$ART"

CHK="$(cd "$R" && bash "$RAS" --check . --slug smoke 2>&1)"; CHK_RC=$?
# (5) Bug: --check refuses a split review's proof, or answers differently from the gate.
if [ "$CHK_RC" = 0 ] && printf '%s\n' "$CHK" | grep -q "^OK   $ART "; then
  pass "(5) review-artifact-sync --check passes the two-proof artifact: rc 0, OK line"
else
  bad "(5) --check rc=$CHK_RC, output [$(printf '%s' "$CHK" | tr '\n' '|')] — want rc 0 and 'OK   $ART'"
fi

UNC="$(cd "$R" && bash "$PUF" "$BASE..HEAD" 2>"$TMP/puf.err")"; UNC_RC=$?
# (6) Bug: the push gate's classifier still counts the reviewed script as uncovered.
if [ "$UNC_RC" = 0 ] && [ -z "$UNC" ]; then
  pass "(6) pg-uncovered-files exits 0 with nothing uncovered"
else
  bad "(6) pg-uncovered-files rc=$UNC_RC, listed [$(printf '%s' "$UNC" | tr '\n' ' ')] — want rc 0 and empty output (stderr: $(tr '\n' '|' < "$TMP/puf.err"))"
fi

# ── one cited proof goes bad: both readers must refuse the whole artifact ──
cp "$PROOF" "$TMP/first-proof.before" 2>/dev/null; SNAP_RC=$?
printf 'input_truncated=true\n' >> "$R/zuvo/proofs/second.txt"

CHK2="$(cd "$R" && bash "$RAS" --check . --slug smoke 2>&1)"; CHK2_RC=$?
# (7) Bug: --check passes an artifact because its FIRST proof is good while another cited one is truncated.
if [ "$CHK2_RC" = 1 ] && printf '%s\n' "$CHK2" | grep '^FAIL ' | grep -q 'zuvo/proofs/second.txt'; then
  pass "(7) a truncated second proof makes --check exit 1 with a FAIL line naming second.txt"
else
  bad "(7) --check rc=$CHK2_RC, output [$(printf '%s' "$CHK2" | tr '\n' '|')] — want rc 1 and a FAIL line naming zuvo/proofs/second.txt"
fi

UNC2="$(cd "$R" && bash "$PUF" "$BASE..HEAD" 2>"$TMP/puf2.err")"; UNC2_RC=$?
# (8) Bug: the classifier honours the good proof alone and keeps the script covered.
if [ "$UNC2_RC" = 0 ] && [ "$UNC2" = "dev-stack.sh" ]; then
  pass "(8) with the second proof truncated, pg-uncovered-files lists dev-stack.sh"
else
  bad "(8) pg-uncovered-files rc=$UNC2_RC, listed [$(printf '%s' "$UNC2" | tr '\n' ' ')] — want rc 0 and exactly dev-stack.sh"
fi

# (9) Bug: refusing the artifact rewrote the first, good proof — a later review of the same change would
# cite evidence the refusal had changed.
if [ "$SNAP_RC" = 0 ] && cmp -s "$PROOF" "$TMP/first-proof.before"; then
  pass "(9) the first proof is byte-for-byte unchanged after the second is flipped and both readers refuse"
else
  bad "(9) zuvo/proofs/smoke-adversarial.txt changed while the second proof was flipped and re-checked"
fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "SOME FAILED"; exit 1
