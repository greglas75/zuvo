# test-pass-cap.sh — the driver's hard cap of 3 adversarial passes per change (ar_check_pass_cap,
# scripts/lib/adversarial-ledger.sh; shared/includes/adversarial-loop.md Step 5).
#
# The defect it guards: an agent re-running full passes over one change without end. A pass counts against
# the current one when it ran in the same repository, on the same branch, within 3 h, over files that include
# every file under review now (the same scope, or a fix delta of it).
# Sourced by run.sh.

ADV="$ROOT/scripts/adversarial-review.sh"
export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$HERE/mocks:$PATH"
PC_TMP="$ADV_TEST_HOME/pass-cap"
rm -rf "$PC_TMP"; mkdir -p "$PC_TMP/repo"
git -C "$PC_TMP/repo" init -q -b main
git -C "$PC_TMP/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# pc_diff <file>... — a small diff touching each named file.
pc_diff() {
  local f
  for f in "$@"; do printf 'diff --git a/%s b/%s\n@@ -1 +1 @@\n-old line in %s\n+new line in %s\n' "$f" "$f" "$f" "$f"; done
}
# pc_run <home> <provider> <file>... — one pass from inside the repo; stdout to $PC_TMP/out, stderr to
# $PC_TMP/err; status = the driver's. The cap is under test, so ZUVO_ADV_PASS_CAP_TEST=1 makes it count.
pc_run() {
  local home="$1" prov="$2"; shift 2
  (cd "$PC_TMP/repo" && pc_diff "$@" | ZUVO_HOME="$home" ZUVO_ADV_PASS_CAP_TEST=1 ZUVO_REVIEW_TEST_PROVIDERS="$prov" \
    bash "$ADV" --single --mode code) > "$PC_TMP/out" 2> "$PC_TMP/err"
}

start_test "PC.1 a fourth pass over the same files is refused with exit 7, and no provider sees it"
H1="$PC_TMP/h1"; mkdir -p "$H1"
r=""; for i in 1 2 3; do pc_run "$H1" mock-echo-files a.ts b.ts; r="$r$?,"; done
assert_eq "0,0,0," "$r" "passes 1-3 are reviewed"
grep -q 'pass 3 of 3' "$PC_TMP/err" && pass "pass 3 says it is the last" || fail "pass 3 says it is the last" "$(tail -3 "$PC_TMP/err")"
pc_run "$H1" mock-echo-files a.ts b.ts; rc=$?
assert_exit_code "7" "$rc" "pass 4 is refused"
assert_contains "$(cat "$PC_TMP/err")" "PASS CAP: 3 adversarial passes already reviewed these files on main" "the refusal names the count and the branch"
assert_eq "" "$(cat "$PC_TMP/out")" "nothing reached a provider (no SEEN FILES output)"

start_test "PC.2 a fix delta (a subset of the reviewed files) counts against the same change"
H2="$PC_TMP/h2"; mkdir -p "$H2"
pc_run "$H2" mock-echo-files a.ts b.ts; r0=$?; pc_run "$H2" mock-echo-files a.ts; r1=$?
pc_run "$H2" mock-echo-files a.ts; r2=$?
assert_eq "0,0,0" "$r0,$r1,$r2" "the full pass and two fix deltas are reviewed"
pc_run "$H2" mock-echo-files a.ts; rc=$?
assert_exit_code "7" "$rc" "a third fix delta is pass 4 of the change: refused"

start_test "PC.3 a WIDER review, another branch, and a pass older than 3 h are new scopes"
pc_run "$H1" mock-echo-files a.ts b.ts c.ts; rc=$?
assert_exit_code "0" "$rc" "a review that adds c.ts is not capped by the passes over a.ts and b.ts"
git -C "$PC_TMP/repo" checkout -q -b other
pc_run "$H1" mock-echo-files a.ts b.ts; rc=$?
assert_exit_code "0" "$rc" "the same files on another branch are another change"
git -C "$PC_TMP/repo" checkout -q main
H3="$PC_TMP/h3"; mkdir -p "$H3"
old=$(( $(date +%s) - 4 * 3600 ))
root="$(cd "$PC_TMP/repo" && git rev-parse --show-toplevel)"
for i in 1 2 3; do printf '%s\told-%s\t%s\tmain\ta.ts\n' "$old" "$i" "$root" >> "$H3/adversarial-passes.tsv"; done
pc_run "$H3" mock-echo-files a.ts; rc=$?
assert_exit_code "0" "$rc" "three passes from 4 h ago do not cap a new one"
H3b="$PC_TMP/h3b"; mkdir -p "$H3b"
for i in 1 2 3; do printf '%s\tnew-%s\t%s\tmain\ta.ts\n' "$(date +%s)" "$i" "$root" >> "$H3b/adversarial-passes.tsv"; done
pc_run "$H3b" mock-echo-files a.ts; rc=$?
assert_exit_code "7" "$rc" "control: the same three rows written now do cap it"

start_test "PC.4 a pass that reviewed nothing does not count"
H4="$PC_TMP/h4"; mkdir -p "$H4"
for i in 1 2 3; do pc_run "$H4" mock-fail a.ts; done
pc_run "$H4" mock-echo-files a.ts; rc=$?
assert_exit_code "0" "$rc" "three failed passes leave the cap untouched"
assert_eq "1" "$(wc -l < "$H4/adversarial-passes.tsv" | tr -d ' ')" "only the reviewed pass is in the ledger"

start_test "PC.5 a chunked pass counts once, whatever its number of parts"
H5="$PC_TMP/h5"; mkdir -p "$H5"
# Three ~14k-char files: over the 30000 cap together, so the pass splits into parts.
pc_big() { local f; for f in "$@"; do printf 'diff --git a/%s b/%s\n@@ -0,0 +1 @@\n' "$f" "$f"
  awk 'BEGIN { for (i = 0; i < 220; i++) printf "+line %d padding padding padding padding padding padding\n", i }'; done; }
(cd "$PC_TMP/repo" && pc_big x.ts y.ts z.ts | ZUVO_HOME="$H5" ZUVO_ADV_PASS_CAP_TEST=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-echo-files \
  bash "$ADV" --single --mode code) >/dev/null 2>"$PC_TMP/err5"; rc=$?
assert_exit_code "0" "$rc" "the chunked pass is reviewed"
grep -q 'CHUNKED INPUT:' "$PC_TMP/err5" && pass "premise: the pass was chunked" || fail "premise: the pass was chunked" "$(head -3 "$PC_TMP/err5")"
assert_eq "1" "$(cut -f2 "$H5/adversarial-passes.tsv" | sort -u | wc -l | tr -d ' ')" "every part recorded under one pass id"
pc_run "$H5" mock-echo-files x.ts; r1=$?; pc_run "$H5" mock-echo-files x.ts; r2=$?
assert_eq "0,0" "$r1,$r2" "passes 2 and 3 after the chunked pass 1 are reviewed"
pc_run "$H5" mock-echo-files x.ts; rc=$?
assert_exit_code "7" "$rc" "pass 4 is refused"

start_test "PC.6 a test-harness run neither counts nor is capped unless the suite tests the cap"
H6="$PC_TMP/h6"; mkdir -p "$H6"
for i in 1 2 3 4; do
  (cd "$PC_TMP/repo" && pc_diff a.ts | ZUVO_HOME="$H6" ZUVO_REVIEW_TEST_PROVIDERS=mock-echo-files bash "$ADV" --single --mode code) >/dev/null 2>&1
  rc=$?
done
assert_exit_code "0" "$rc" "a fourth mock-only run is reviewed"
[[ -e "$H6/adversarial-passes.tsv" ]] && fail "mock-only runs leave no ledger" "$(cat "$H6/adversarial-passes.tsv")" || pass "mock-only runs leave no ledger"
