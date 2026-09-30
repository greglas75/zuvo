#!/usr/bin/env bash
# test-findings-ledger.sh — the per-finding ledger (~/.zuvo/adversarial-findings.log):
# --json reviews emit one row per fingerprinted finding, --record-disposition appends verdicts
# (latest wins, keyed on project + fingerprint), --effectiveness joins the two per model, and no
# failure of the ledger ever fails a review.

ADV="$ROOT/scripts/adversarial-review.sh"
MOCKS="$HERE/mocks"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$MOCKS:$PATH"

# Projects live OUTSIDE the repository: the ledger keys on the git toplevel's basename, and
# anything under tests/ would resolve to "zuvo-plugin" for both projects.
FL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/adv-findings.XXXXXX")"
trap 'chmod -R u+w "$FL_TMP" 2>/dev/null; rm -rf "$FL_TMP"' EXIT
# Stop git discovery at the temp root: were $TMPDIR inside some repository, PROJ_* would
# silently resolve to it instead of to themselves.
export GIT_CEILING_DIRECTORIES="$FL_TMP"
PROJ_A="$FL_TMP/proj-alpha"; PROJ_B="$FL_TMP/proj-beta"
mkdir -p "$PROJ_A" "$PROJ_B"
# The ledger's project key is the physical path (macOS: /var → /private/var).
PA="$(cd "$PROJ_A" && pwd -P)"
LEDGER="$FL_TMP/findings.log"
RUNLOG="$FL_TMP/adversarial.log"

# review <dir> <args…> — a two-lane review of the empty fixture, run from <dir>.
review() {
  local dir="$1"; shift
  ( cd "$dir" && ZUVO_FINDINGS_LOG_FILE="$LEDGER" ZUVO_ADVERSARIAL_LOG_FILE="$RUNLOG" \
      ZUVO_HOME="$FL_TMP/home" ZUVO_REVIEW_TEST_PROVIDERS="mock-findings-a mock-findings-b" \
      bash "$ADV" --multi "$@" --files "$EMPTY" )
}
record() {
  local dir="$1"; shift
  ( cd "$dir" && ZUVO_FINDINGS_LOG_FILE="$LEDGER" ZUVO_HOME="$FL_TMP/home" bash "$ADV" "$@" )
}
# lane_col <provider> <field> — one column of the --effectiveness row for a lane
# (provider model raised CRIT fixed defer rejct open precision → fields 1..9).
lane_col() { printf '%s\n' "$EFF" | awk -v p="$1" -v f="$2" '$1 == p { print $f }'; }

start_test "FL.1 --json review writes one row per distinct fingerprint, per lane"
rc=0; review "$PROJ_A" --json >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "review exits 0"
assert_eq "0" "$(awk -F'\t' 'NR > 1 && NF != 11' "$LEDGER" | wc -l | tr -d ' ')" "every data row has 11 columns"
assert_eq "date	run_id	mode	provider	model	fingerprint	severity	confidence	file	disposition	project" \
  "$(head -1 "$LEDGER")" "ledger header (11 columns, project last)"
a_rows=$(awk -F'\t' '$4 == "mock-findings-a" && $10 == "new"' "$LEDGER" | wc -l | tr -d ' ')
b_rows=$(awk -F'\t' '$4 == "mock-findings-b" && $10 == "new"' "$LEDGER" | wc -l | tr -d ' ')
# lane a: 6 findings — one duplicated id, one id-less, one flag-shaped, one holding a tab → 2 rows.
assert_eq "2" "$a_rows" "lane a: duplicate collapsed; id-less and unrecordable ids dropped"
assert_eq "2" "$b_rows" "lane b: both findings recorded"
tok=$(awk -F'\t' '$4 == "mock-findings-a" && $6 == "auth.ts:40:token-logged-plaintext" { print $7 "|" $8 "|" $9 "|" $11 }' "$LEDGER")
assert_eq "CRITICAL|medium|auth.ts:40|$PA" "$tok" "duplicate kept at its HIGHEST severity; file and project path recorded"

start_test "FL.2 text-mode review records nothing (no fingerprints to key on)"
before=$(wc -l < "$LEDGER" | tr -d ' ')
review "$PROJ_A" >/dev/null 2>&1 || true
assert_eq "$before" "$(wc -l < "$LEDGER" | tr -d ' ')" "ledger unchanged by a text review"

start_test "FL.3 --record-disposition: batch append, latest verdict wins"
out=$(record "$PROJ_A" --record-disposition "auth.ts:12:missing-tenant-check" fixed \
                       --record-disposition "auth.ts:40:token-logged-plaintext" fixed 2>&1)
assert_contains "$out" "recorded 2 disposition(s) for project '$PA'" "batch of two recorded"
record "$PROJ_A" --record-disposition "auth.ts:40:token-logged-plaintext" rejected >/dev/null 2>&1
v=$(awk -F'\t' '$6 == "auth.ts:40:token-logged-plaintext" && $10 != "new" { print $10 "|" $4 "|" $5 }' "$LEDGER" | tail -1)
assert_eq "rejected||" "$v" "verdict row appended, provider/model left empty"
# A verdict from ANOTHER project joins nothing: refused by name, never recorded as success.
before=$(wc -l < "$LEDGER" | tr -d ' ')
rc=0; out=$(record "$PROJ_B" --record-disposition "db.ts:7:unbounded-query" fixed 2>&1) || rc=$?
assert_eq "1" "$rc" "unmatched id from another project → exit 1"
assert_contains "$out" "db.ts:7:unbounded-query" "the unrecorded id is named"
assert_eq "$before" "$(wc -l < "$LEDGER" | tr -d ' ')" "no verdict row written for it"

start_test "FL.4 invalid batch is refused whole — nothing written"
before=$(wc -l < "$LEDGER" | tr -d ' ')
rc=0; record "$PROJ_A" --record-disposition "x.ts:1:ok" fixed --record-disposition "y.ts:2:bad" maybe >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "unknown verdict → exit 2"
rc=0; record "$PROJ_A" --record-disposition "--effectiveness" fixed >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "flag-shaped fingerprint → exit 2"
rc=0; record "$PROJ_A" --record-disposition "$(printf 'a.ts:1:x\r')" fixed >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "control character (CR) in fingerprint → exit 2"
rc=0; record "$PROJ_A" --record-disposition 'a.ts:1:back\slash' fixed >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "backslash in fingerprint → exit 2 (would not survive the join)"
rc=0; out=$(record "$PROJ_A" --record-disposition "a.ts:1:x" 2>&1) || rc=$?
assert_eq "2" "$rc" "missing verdict → exit 2"
assert_contains "$out" "two values" "missing verdict is named as such, not blamed on the fingerprint"
assert_eq "$before" "$(wc -l < "$LEDGER" | tr -d ' ')" "ledger unchanged after refused batches"

start_test "FL.5 --effectiveness: per-lane raised / CRIT / verdicts / precision"
EFF=$(record "$PROJ_A" --effectiveness 2>&1)
# lane a: tenant-check (CRITICAL) fixed; token-logged fixed then REJECTED → 1 fixed, 1 rejected.
assert_eq "2"   "$(lane_col mock-findings-a 3)" "a raised"
assert_eq "2"   "$(lane_col mock-findings-a 4)" "a CRIT (token-logged counted at its highest severity)"
assert_eq "1"   "$(lane_col mock-findings-a 5)" "a fixed"
assert_eq "1"   "$(lane_col mock-findings-a 7)" "a rejected (superseded verdict counts, not the first)"
assert_eq "50%" "$(lane_col mock-findings-a 9)" "a precision = 1/2"
# lane b: shares tenant-check (credited too); db.ts was never judged (proj-beta's verdict was refused).
assert_eq "2"    "$(lane_col mock-findings-b 3)" "b raised"
assert_eq "0"    "$(lane_col mock-findings-b 4)" "b CRIT (its own severity, WARNING)"
assert_eq "1"    "$(lane_col mock-findings-b 5)" "b fixed (same fingerprint as a → same verdict)"
assert_eq "1"    "$(lane_col mock-findings-b 8)" "b open: another project's verdict does not apply"
assert_eq "100%" "$(lane_col mock-findings-b 9)" "b precision excludes the open finding"

start_test "FL.6 a verdict judges only the raises BEFORE it"
review "$PROJ_A" --json >/dev/null 2>&1 || true
EFF=$(record "$PROJ_A" --effectiveness 2>&1)
# Both of a's findings were judged, so the re-raise opens two new, OPEN occurrences.
assert_eq "4"   "$(lane_col mock-findings-a 3)" "a: re-raise after a verdict is a new occurrence"
assert_eq "2"   "$(lane_col mock-findings-a 8)" "a: the new occurrences are open, not pre-judged"
assert_eq "50%" "$(lane_col mock-findings-a 9)" "a: precision unchanged by unjudged raises"
# b: tenant-check was judged (new occurrence); db.ts never was → still ONE occurrence.
assert_eq "3"   "$(lane_col mock-findings-b 3)" "b: an unjudged finding re-raised stays one finding"
record "$PROJ_A" --record-disposition "auth.ts:40:token-logged-plaintext" fixed >/dev/null 2>&1
EFF=$(record "$PROJ_A" --effectiveness 2>&1)
assert_eq "1"   "$(lane_col mock-findings-a 7)" "a: the OLD occurrence keeps its rejected verdict"
assert_eq "67%" "$(lane_col mock-findings-a 9)" "a: 2 of 3 judged occurrences real"

start_test "FL.7 empty ledger → --effectiveness exits 1 with the text-mode note"
rc=0; out=$(ZUVO_FINDINGS_LOG_FILE="$FL_TMP/none.log" bash "$ADV" --effectiveness 2>&1) || rc=$?
assert_eq "1" "$rc" "no ledger → exit 1"
assert_contains "$out" "text-mode reviews carry no fingerprints" "says why it can be empty"

start_test "FL.8 unwritable ledger never fails the review"
mkdir -p "$FL_TMP/ro"; chmod 500 "$FL_TMP/ro"
# root ignores the mode bits; then this case cannot fail the write and would prove nothing.
if ( : > "$FL_TMP/ro/probe" ) 2>/dev/null; then rm -f "$FL_TMP/ro/probe"; RO_OK=0; else RO_OK=1; fi
rc=0; out=$( cd "$PROJ_A" && ZUVO_FINDINGS_LOG_FILE="$FL_TMP/ro/sub/findings.log" \
  ZUVO_ADVERSARIAL_LOG_FILE="$RUNLOG" ZUVO_HOME="$FL_TMP/home" \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-findings-a mock-findings-b" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null ) || rc=$?
chmod 700 "$FL_TMP/ro"
if [[ "$RO_OK" == 1 ]]; then
  assert_eq "0" "$rc" "review still exits 0"
  assert_contains "$out" "missing-tenant-check" "review output intact"
  assert_eq "no" "$([[ -e "$FL_TMP/ro/sub/findings.log" ]] && echo yes || echo no)" "the write really failed"
else
  pass "FL.8 skipped: running as root, the directory cannot be made unwritable"
fi

start_test "FL.9 mock lanes never write the REAL ledger"
FAKE_HOME="$FL_TMP/fakehome"; mkdir -p "$FAKE_HOME"
rc=0; out=$( cd "$PROJ_A" && env -u ZUVO_HOME -u ZUVO_FINDINGS_LOG_FILE HOME="$FAKE_HOME" \
    ZUVO_ADVERSARIAL_LOG_FILE="$RUNLOG" ZUVO_REVIEW_TEST_PROVIDERS="mock-findings-a mock-findings-b" \
    bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null ) || rc=$?
# The review must have run to the ledger step, or "no rows" proves nothing.
assert_eq "0" "$rc" "review against the real home ran"
assert_contains "$out" "missing-tenant-check" "lanes answered with fingerprinted findings"
n=0; [[ -f "$FAKE_HOME/.zuvo/adversarial-findings.log" ]] && \
  n=$(awk -F'\t' '$10 == "new"' "$FAKE_HOME/.zuvo/adversarial-findings.log" | wc -l | tr -d ' ')
assert_eq "0" "$n" "no finding rows at all in \$HOME/.zuvo/adversarial-findings.log"
# Reaching the real ledger through an explicit ZUVO_HOME is still the real ledger.
rc=0; ( cd "$PROJ_A" && env -u ZUVO_FINDINGS_LOG_FILE HOME="$FAKE_HOME" ZUVO_HOME="$FAKE_HOME/.zuvo" \
    ZUVO_ADVERSARIAL_LOG_FILE="$RUNLOG" ZUVO_REVIEW_TEST_PROVIDERS="mock-findings-a mock-findings-b" \
    bash "$ADV" --multi --json --files "$EMPTY" >/dev/null 2>&1 ) || rc=$?
assert_eq "0" "$rc" "review via explicit ZUVO_HOME ran"
n=0; [[ -f "$FAKE_HOME/.zuvo/adversarial-findings.log" ]] && \
  n=$(awk -F'\t' '$10 == "new"' "$FAKE_HOME/.zuvo/adversarial-findings.log" | wc -l | tr -d ' ')
assert_eq "0" "$n" "no mock rows when ZUVO_HOME points at the real ~/.zuvo"

start_test "FL.10 legacy 10-column header gets ONE schema marker, never a rewrite"
OLD="$FL_TMP/legacy.log"
printf 'date\trun_id\tmode\tprovider\tmodel\tfingerprint\tseverity\tconfidence\tfile\tdisposition\n' > "$OLD"
for i in 1 2; do
  rc=0; ( cd "$PROJ_A" && ZUVO_FINDINGS_LOG_FILE="$OLD" ZUVO_ADVERSARIAL_LOG_FILE="$RUNLOG" ZUVO_HOME="$FL_TMP/home" \
      ZUVO_REVIEW_TEST_PROVIDERS="mock-findings-b" bash "$ADV" --json --files "$EMPTY" >/dev/null 2>&1 ) || rc=$?
  assert_eq "0" "$rc" "legacy-ledger review $i ran"
done
assert_eq "4" "$(awk -F'\t' '$10 == "new" && NF == 11' "$OLD" | wc -l | tr -d ' ')" "data rows written in the 11-column schema"
assert_eq "1" "$(grep -c '^#schema' "$OLD")" "exactly one #schema marker after two writes"
assert_eq "date	run_id	mode	provider	model	fingerprint	severity	confidence	file	disposition" \
  "$(head -1 "$OLD")" "original header line left in place"

start_test "FL.11 a review in a linked worktree joins a verdict recorded from the main checkout"
REPO="$FL_TMP/repo-main"; WT="$FL_TMP/repo-wt"
( export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q "$REPO" && git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init \
    && git -C "$REPO" worktree add -q --detach "$WT" ) >/dev/null 2>&1
WL="$FL_TMP/wt-ledger.log"
( cd "$WT" && ZUVO_FINDINGS_LOG_FILE="$WL" ZUVO_ADVERSARIAL_LOG_FILE="$RUNLOG" ZUVO_HOME="$FL_TMP/home" \
    ZUVO_REVIEW_TEST_PROVIDERS="mock-findings-b" bash "$ADV" --json --files "$EMPTY" >/dev/null 2>&1 ) || true
rc=0; ( cd "$REPO" && ZUVO_FINDINGS_LOG_FILE="$WL" ZUVO_HOME="$FL_TMP/home" bash "$ADV" \
    --record-disposition "db.ts:7:unbounded-query" deferred >/dev/null 2>&1 ) || rc=$?
assert_eq "0" "$rc" "verdict from the main checkout matched the worktree's finding"
assert_eq "$(cd "$REPO" && pwd -P)" "$(awk -F'\t' '$10 == "new" { print $11 }' "$WL" | sort -u)" \
  "every worktree finding keyed on the main checkout's path"

