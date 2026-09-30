#!/usr/bin/env bash
# test-findings-ledger.sh — the per-finding ledger (~/.zuvo/adversarial-findings.log):
# --json reviews emit one row per fingerprinted finding, --record-disposition appends verdicts
# (a verdict judges the raises before it, keyed on project + fingerprint), --effectiveness joins
# the two per lane, and no failure of the ledger ever fails a review.
#
# Every case builds its OWN ledger from scratch (new_case + seed_*), so any case runs alone and in
# any order; nothing leaks from one case's verdicts into the next case's arithmetic.

ADV="$ROOT/scripts/adversarial-review.sh"
MOCKS="$HERE/mocks"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$MOCKS:$PATH"

# Projects live OUTSIDE the repository: the ledger keys on the main checkout's path, and anything
# under tests/ would resolve to this repository for both projects.
FL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/adv-findings.XXXXXX")"
trap 'chmod -R u+w "$FL_TMP" 2>/dev/null; rm -rf "$FL_TMP"' EXIT
# Stop git discovery at the temp root: were $TMPDIR inside some repository, PROJ_* would
# silently resolve to it instead of to themselves.
export GIT_CEILING_DIRECTORIES="$FL_TMP"
PROJ_A="$FL_TMP/proj-alpha"; PROJ_B="$FL_TMP/proj-beta"
mkdir -p "$PROJ_A" "$PROJ_B"
PA="$(cd "$PROJ_A" && pwd -P)"   # the key is the physical path (macOS: /var → /private/var)
RUNLOG="$FL_TMP/adversarial.log"
TENANT="auth.ts:12:missing-tenant-check"     # raised by lanes a (CRITICAL) and b (WARNING)
TOKEN="auth.ts:40:token-logged-plaintext"    # lane a only; its duplicate is CRITICAL
DBQ="db.ts:7:unbounded-query"                # lane b only, INFO

_case=0
new_case() { _case=$((_case + 1)); LEDGER="$FL_TMP/ledger-$_case.log"; }
# review <dir> <lanes> <args…> — a review of the empty fixture, run from <dir>, into $LEDGER.
review() {
  local dir="$1" lanes="$2"; shift 2
  ( cd "$dir" && ZUVO_FINDINGS_LOG_FILE="$LEDGER" ZUVO_ADVERSARIAL_LOG_FILE="$RUNLOG" \
      ZUVO_HOME="$FL_TMP/home" ZUVO_REVIEW_TEST_PROVIDERS="$lanes" \
      bash "$ADV" "$@" --files "$EMPTY" )   # default mode: every listed lane runs, 1 is fine
}
record() {
  local dir="$1"; shift
  ( cd "$dir" && ZUVO_FINDINGS_LOG_FILE="$LEDGER" ZUVO_HOME="$FL_TMP/home" bash "$ADV" "$@" )
}
seed_review()   { review "$PROJ_A" "mock-findings-a mock-findings-b" --json >/dev/null 2>&1; }
# The standard verdict history: TENANT fixed; TOKEN fixed, then corrected to rejected.
seed_verdicts() {
  record "$PROJ_A" --record-disposition "$TENANT" fixed --record-disposition "$TOKEN" fixed >/dev/null 2>&1
  record "$PROJ_A" --record-disposition "$TOKEN" rejected >/dev/null 2>&1
}
effectiveness() { EFF="$(record "$PROJ_A" --effectiveness 2>&1)"; }
# lane_col <provider> <field> — one column of an --effectiveness row. The model column is one
# token for the mock lanes ("unknown"), so the fields are: provider model raised CRIT fixed defer
# rejct open precision → 1..9.
lane_col() { printf '%s\n' "$EFF" | awk -v p="$1" -v f="$2" '$1 == p { print $f }'; }
rows_where() { awk -F'\t' "$1" "$LEDGER" 2>/dev/null | wc -l | tr -d ' '; }

start_test "FL.1 a --json review writes one row per distinct recordable fingerprint, per lane"
new_case
rc=0; seed_review || rc=$?
assert_eq "0" "$rc" "review exits 0"
assert_eq "date	run_id	mode	provider	model	fingerprint	severity	confidence	file	disposition	project" \
  "$(head -1 "$LEDGER")" "ledger header (11 columns, project last)"
assert_eq "0" "$(rows_where 'NR > 1 && NF != 11')" "every data row has 11 columns"
# lane a answers 6 findings: one duplicated id, one id-less, one flag-shaped, one with a tab → 2.
assert_eq "2" "$(rows_where '$4 == "mock-findings-a" && $10 == "new"')" "lane a: duplicate collapsed; id-less and unrecordable ids dropped"
assert_eq "2" "$(rows_where '$4 == "mock-findings-b" && $10 == "new"')" "lane b: both findings recorded"
tok=$(awk -F'\t' -v id="$TOKEN" '$4 == "mock-findings-a" && $6 == id { print $3 "|" $5 "|" $7 "|" $8 "|" $9 "|" $11 }' "$LEDGER")
assert_eq "code|unknown|CRITICAL|medium|auth.ts:40|$PA" "$tok" "mode, model, highest severity, confidence, file and project path recorded"

start_test "FL.2 a chunked result (JSON objects back to back) is one finding per id, at its highest severity"
new_case
review "$PROJ_A" "mock-findings-c" --json >/dev/null 2>&1 || true
assert_eq "2" "$(rows_where '$4 == "mock-findings-c" && $10 == "new"')" "two distinct ids across both objects"
assert_eq "CRITICAL" "$(awk -F'\t' '$6 == "api.ts:5:missing-rate-limit" { print $7 }' "$LEDGER")" "INFO in chunk 1, CRITICAL in chunk 2 → CRITICAL"

start_test "FL.3 a text-mode review records nothing (no fingerprints to key on)"
new_case
rc=0; review "$PROJ_A" "mock-findings-a mock-findings-b" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "text review ran"
assert_eq "0" "$(rows_where '$10 == "new"')" "no finding rows from a text review"

start_test "FL.4 --record-disposition: batch append, latest verdict wins, run id sanitized"
new_case; seed_review
out=$(ZUVO_RUN_ID="$(printf 'run\t7')" record "$PROJ_A" --record-disposition "$TENANT" fixed --record-disposition "$TOKEN" fixed 2>&1)
assert_contains "$out" "recorded 2 disposition(s) for project '$PA'" "batch of two recorded"
assert_eq "run_7" "$(awk -F'\t' -v id="$TENANT" '$6 == id && $10 == "fixed" { print $2 }' "$LEDGER")" "a tab in ZUVO_RUN_ID cannot split the row"
record "$PROJ_A" --record-disposition "$TOKEN" rejected >/dev/null 2>&1
assert_eq "rejected||" "$(awk -F'\t' -v id="$TOKEN" '$6 == id && $10 != "new" { v = $10 "|" $4 "|" $5 } END { print v }' "$LEDGER")" \
  "latest verdict row is last, provider/model left empty"

start_test "FL.5 a verdict for an id this project never raised is refused by name"
new_case; seed_review
before=$(wc -l < "$LEDGER" | tr -d ' ')
rc=0; out=$(record "$PROJ_B" --record-disposition "$DBQ" fixed 2>&1) || rc=$?
assert_eq "1" "$rc" "id raised only in proj-alpha, recorded from proj-beta → exit 1"
assert_contains "$out" "$DBQ" "the unrecorded id is named"
rc=0; out=$(record "$PROJ_A" --record-disposition "$TENANT" fixed --record-disposition "never:1:raised" fixed 2>&1) || rc=$?
assert_eq "1" "$rc" "mixed batch with one unknown id → exit 1"
assert_contains "$out" "recorded 1 disposition(s)" "the matched id in the batch is still recorded"
assert_eq "$((before + 1))" "$(wc -l < "$LEDGER" | tr -d ' ')" "exactly one verdict row added across both calls"

start_test "FL.6 malformed arguments are refused whole — nothing written"
new_case; seed_review
before=$(wc -l < "$LEDGER" | tr -d ' ')
for bad in "unknown-verdict" "flag-shaped" "carriage-return" "backslash" "empty" "missing-verdict"; do
  case "$bad" in
    unknown-verdict) args=(--record-disposition "$TENANT" fixed --record-disposition "$TOKEN" maybe) ;;
    flag-shaped)     args=(--record-disposition "--effectiveness" fixed) ;;
    carriage-return) args=(--record-disposition "$(printf 'a.ts:1:x\r')" fixed) ;;
    backslash)       args=(--record-disposition 'a.ts:1:back\slash' fixed) ;;
    empty)           args=(--record-disposition "" fixed) ;;
    missing-verdict) args=(--record-disposition "$TENANT") ;;
  esac
  rc=0; out=$(record "$PROJ_A" "${args[@]}" 2>&1) || rc=$?
  assert_eq "2" "$rc" "$bad → exit 2"
done
assert_contains "$out" "two values" "a missing verdict is named as such, not blamed on the fingerprint"
assert_eq "$before" "$(wc -l < "$LEDGER" | tr -d ' ')" "ledger unchanged after every refused call"

start_test "FL.7 --effectiveness: per-lane raised / CRIT / verdicts / precision"
new_case; seed_review; seed_verdicts; effectiveness
# lane a: TENANT (CRITICAL) fixed; TOKEN (CRITICAL) fixed, then rejected.
assert_eq "unknown" "$(lane_col mock-findings-a 2)" "model column"
assert_eq "2"   "$(lane_col mock-findings-a 3)" "a raised"
assert_eq "2"   "$(lane_col mock-findings-a 4)" "a CRIT (each finding at its highest severity)"
assert_eq "1"   "$(lane_col mock-findings-a 5)" "a fixed"
assert_eq "1"   "$(lane_col mock-findings-a 7)" "a rejected — the superseding verdict counts, not the first"
assert_eq "0"   "$(lane_col mock-findings-a 8)" "a open"
assert_eq "50%" "$(lane_col mock-findings-a 9)" "a precision = 1/2"
# lane b: shares TENANT (the verdict is credited to both lanes); DBQ never judged.
assert_eq "2"    "$(lane_col mock-findings-b 3)" "b raised"
assert_eq "0"    "$(lane_col mock-findings-b 4)" "b CRIT (its own severity: WARNING)"
assert_eq "1"    "$(lane_col mock-findings-b 5)" "b fixed (same fingerprint as a → same verdict)"
assert_eq "1"    "$(lane_col mock-findings-b 8)" "b open"
assert_eq "100%" "$(lane_col mock-findings-b 9)" "b precision excludes the open finding"

start_test "FL.8 deferred counts as real; a lane with nothing judged has no precision"
new_case; seed_review
record "$PROJ_A" --record-disposition "$DBQ" deferred >/dev/null 2>&1
effectiveness
assert_eq "1"    "$(lane_col mock-findings-b 6)" "b deferred"
assert_eq "100%" "$(lane_col mock-findings-b 9)" "b precision = (0 fixed + 1 deferred) / 1"
assert_eq "n/a"  "$(lane_col mock-findings-a 9)" "a: 0 judged → n/a, not 0%"

start_test "FL.9 a verdict judges only the raises BEFORE it"
new_case; seed_review; seed_verdicts; seed_review; effectiveness
# Both of a's findings were judged, so the re-raise opens two new, OPEN occurrences.
assert_eq "4"   "$(lane_col mock-findings-a 3)" "a: re-raise after a verdict is a new occurrence"
assert_eq "2"   "$(lane_col mock-findings-a 8)" "a: the new occurrences are open, not pre-judged"
assert_eq "50%" "$(lane_col mock-findings-a 9)" "a: precision unchanged by unjudged raises"
# b: TENANT was judged (new occurrence); DBQ never was → still ONE occurrence.
assert_eq "3"   "$(lane_col mock-findings-b 3)" "b: an unjudged finding re-raised stays one finding"
record "$PROJ_A" --record-disposition "$TOKEN" fixed >/dev/null 2>&1
effectiveness
assert_eq "1"   "$(lane_col mock-findings-a 7)" "a: the OLD occurrence keeps its rejected verdict"
assert_eq "67%" "$(lane_col mock-findings-a 9)" "a: 2 of 3 judged occurrences real"

start_test "FL.10 rows without the project column are ignored by the report"
new_case; seed_review
printf '2026-01-01T00:00:00Z\tr\tcode\tmock-findings-a\tunknown\tlegacy.ts:1:x\tCRITICAL\thigh\tlegacy.ts:1\tnew\n' >> "$LEDGER"
effectiveness
assert_eq "2" "$(lane_col mock-findings-a 3)" "a 10-column legacy row adds no raise"

start_test "FL.11 an empty ledger → --effectiveness exits 1 with the text-mode note"
new_case
rc=0; out=$(record "$PROJ_A" --effectiveness 2>&1) || rc=$?
assert_eq "1" "$rc" "no ledger → exit 1"
assert_contains "$out" "text-mode reviews carry no fingerprints" "says why it can be empty"

start_test "FL.12 an unwritable ledger never fails the review"
# The ledger's parent is a regular FILE: mkdir and the append fail for every user, root included.
: > "$FL_TMP/not-a-dir"
rc=0; out=$( cd "$PROJ_A" && ZUVO_FINDINGS_LOG_FILE="$FL_TMP/not-a-dir/findings.log" \
  ZUVO_ADVERSARIAL_LOG_FILE="$RUNLOG" ZUVO_HOME="$FL_TMP/home" \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-findings-a mock-findings-b" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null ) || rc=$?
assert_eq "0" "$rc" "review still exits 0"
assert_contains "$out" "$TENANT" "review output intact"

start_test "FL.13 mock lanes never write the REAL ledger"
FAKE_HOME="$FL_TMP/fakehome"; mkdir -p "$FAKE_HOME"
real_rows() { if [[ -f "$FAKE_HOME/.zuvo/adversarial-findings.log" ]]; then
  awk -F'\t' '$10 == "new"' "$FAKE_HOME/.zuvo/adversarial-findings.log" | wc -l | tr -d ' '; else echo 0; fi; }
rc=0; out=$( cd "$PROJ_A" && env -u ZUVO_HOME -u ZUVO_FINDINGS_LOG_FILE HOME="$FAKE_HOME" \
    ZUVO_ADVERSARIAL_LOG_FILE="$RUNLOG" ZUVO_REVIEW_TEST_PROVIDERS="mock-findings-a mock-findings-b" \
    bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null ) || rc=$?
# The review must have reached the ledger step, or "no rows" proves nothing.
assert_eq "0" "$rc" "review against the real home ran"
assert_contains "$out" "$TENANT" "lanes answered with fingerprinted findings"
assert_eq "0" "$(real_rows)" "no finding rows in \$HOME/.zuvo/adversarial-findings.log"
rc=0; ( cd "$PROJ_A" && env -u ZUVO_FINDINGS_LOG_FILE HOME="$FAKE_HOME" ZUVO_HOME="$FAKE_HOME/.zuvo" \
    ZUVO_ADVERSARIAL_LOG_FILE="$RUNLOG" ZUVO_REVIEW_TEST_PROVIDERS="mock-findings-a mock-findings-b" \
    bash "$ADV" --multi --json --files "$EMPTY" >/dev/null 2>&1 ) || rc=$?
assert_eq "0" "$rc" "review via an explicit ZUVO_HOME=\$HOME/.zuvo ran"
assert_eq "0" "$(real_rows)" "still no rows: that path IS the real ledger"

start_test "FL.14 a legacy 10-column header gets ONE schema marker, never a rewrite"
new_case
printf 'date\trun_id\tmode\tprovider\tmodel\tfingerprint\tseverity\tconfidence\tfile\tdisposition\n' > "$LEDGER"
for i in 1 2; do
  rc=0; review "$PROJ_A" "mock-findings-b" --json >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "legacy-ledger review $i ran"
done
assert_eq "1" "$(grep -c '^#schema' "$LEDGER")" "exactly one #schema marker after two writes"
assert_eq "date	run_id	mode	provider	model	fingerprint	severity	confidence	file	disposition" \
  "$(head -1 "$LEDGER")" "original header line left in place"
assert_eq "4" "$(rows_where '$10 == "new" && NF == 11')" "data rows written in the 11-column schema"

start_test "FL.15 a review in a linked worktree joins a verdict recorded from the main checkout"
new_case
REPO="$FL_TMP/repo-main"; WT="$FL_TMP/repo-wt"
( export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q "$REPO" && git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init \
    && git -C "$REPO" worktree add -q --detach "$WT" ) >/dev/null 2>&1
review "$WT" "mock-findings-b" --json >/dev/null 2>&1 || true
assert_eq "$(cd "$REPO" && pwd -P)" "$(awk -F'\t' '$10 == "new" { print $11 }' "$LEDGER" | sort -u)" \
  "every worktree finding keyed on the main checkout's path"
rc=0; record "$REPO" --record-disposition "$DBQ" deferred >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "verdict from the main checkout matched the worktree's finding"
EFF="$(record "$REPO" --effectiveness 2>&1)"
assert_eq "1" "$(lane_col mock-findings-b 6)" "the report counts it as deferred"

start_test "FL.16 --mode blind-audit writes no rows, even when a valid lane's reply carries findings JSON"
new_case
printf 'echo 1\n' > "$FL_TMP/prod.sh"; printf 'echo 2\n' > "$FL_TMP/prod.test.sh"
rc=0; out=$( cd "$PROJ_A" && ZUVO_FINDINGS_LOG_FILE="$LEDGER" ZUVO_ADVERSARIAL_LOG_FILE="$RUNLOG" \
  ZUVO_HOME="$FL_TMP/home" bash "$ADV" --mode blind-audit --production "$FL_TMP/prod.sh" \
  --test "$FL_TMP/prod.test.sh" --provider mock-strict-findings --json 2>/dev/null ) || rc=$?
assert_eq "3" "$rc" "one valid lane → degraded (exit 3), i.e. the lane WAS accepted"
assert_contains "$out" '"verdict": "FIX"' "the lane's strict block was merged"
assert_eq "0" "$(rows_where '$10 == "new"')" "no finding rows from a blind-audit run"

start_test "FL.17 a verdict that cannot be appended is an error, not a success"
new_case; seed_review
chmod 444 "$LEDGER"
# Precondition, not a branch: under root the mode bits do not stop the append, and this case
# would prove nothing — it must fail loudly there rather than pass or skip.
assert_eq "no" "$( ( : >> "$LEDGER" ) 2>/dev/null && echo yes || echo no)" "precondition: the ledger is really read-only (not running as root)"
rc=0; out=$(record "$PROJ_A" --record-disposition "$TENANT" fixed 2>&1) || rc=$?
chmod 644 "$LEDGER"
assert_eq "1" "$rc" "append failure → exit 1"
assert_contains "$out" "could not append" "names the failure"
assert_eq "0" "$(rows_where '$10 == "fixed"')" "no verdict row"

start_test "FL.18 a finding recorded with the fingerprint 'unknown' is not counted"
new_case; seed_review
printf '2026-01-01T00:00:00Z\tr\tcode\tmock-findings-a\tunknown\tunknown\tCRITICAL\thigh\tx\tnew\t%s\n' "$PA" >> "$LEDGER"
effectiveness
assert_eq "2" "$(lane_col mock-findings-a 3)" "the 'unknown' id adds no raise"
assert_eq "2" "$(lane_col mock-findings-a 4)" "and no CRITICAL"

start_test "FL.19 a clean --json review, or one whose reply is not JSON, leaves the ledger untouched"
new_case
rc=0; out=$(review "$PROJ_A" "mock-success" --json 2>/dev/null) || rc=$?
assert_eq "0" "$rc" "clean review ({\"findings\":[]}) exits 0"
assert_contains "$(printf '%s' "$out" | tr -d ' \n')" '"findings":[]' "the lane really answered clean"
assert_eq "no" "$([[ -e "$LEDGER" ]] && echo yes || echo no)" "no ledger file created — nothing to record, not even a header"
new_case
rc=0; review "$PROJ_A" "mock-findings-prose" --json >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "a prose reply (jq cannot parse it) does not fail the review"
assert_eq "no" "$([[ -e "$LEDGER" ]] && echo yes || echo no)" "and writes nothing"
