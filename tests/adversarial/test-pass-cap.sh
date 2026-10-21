# test-pass-cap.sh — the driver's hard cap of 3 adversarial passes per change (ar_check_pass_cap,
# scripts/lib/adversarial-ledger.sh; shared/includes/adversarial-loop.md Step 5).
#
# The defect it guards: an agent re-running full passes over one change without end. A pass counts against
# the current one when it ran in the same repository (any worktree), on the same branch, within 7 days (3 h on a
# shared default branch), over files sharing at least half of the smaller file set with the files under review now.
# Sourced by run.sh.

ADV="$ROOT/scripts/adversarial-review.sh"
export ZUVO_ADVERSARIAL_TEST_HARNESS=1
# The cases below count across sessions (cron, CI); the suite's own agent session must not leak in. PC.11 sets one.
unset ZUVO_ADV_SESSION CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID CODEX_SESSION_ID
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

start_test "PC.3 mostly other files, another branch, and a pass older than 3 h on main are new scopes"
pc_run "$H1" mock-echo-files c.ts d.ts e.ts; rc=$?
assert_exit_code "0" "$rc" "a review of other files (c, d, e) is another change"
git -C "$PC_TMP/repo" checkout -q -b other
pc_run "$H1" mock-echo-files a.ts b.ts; rc=$?
assert_exit_code "0" "$rc" "the same files on another branch are another change"
git -C "$PC_TMP/repo" checkout -q main
H3="$PC_TMP/h3"; mkdir -p "$H3"
old=$(( $(date +%s) - 4 * 3600 ))
root="$(cd "$PC_TMP/repo" && git rev-parse --path-format=absolute --git-common-dir)"
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

# The 28-pass PR (tgm-survey-platform, 2026-10-15/16): every pass used another --diff base, so no earlier file set
# held all of the next one, and farm waits spread the passes past a 3 h window.
start_test "PC.7 on a feature branch, re-based and wider passes of one change count, and the window is 7 days"
git -C "$PC_TMP/repo" checkout -q -b feature/x
H7="$PC_TMP/h7"; mkdir -p "$H7"
pc_run "$H7" mock-echo-files a.ts b.ts; pc_run "$H7" mock-echo-files b.ts c.ts; pc_run "$H7" mock-echo-files a.ts c.ts d.ts
pc_run "$H7" mock-echo-files a.ts b.ts c.ts d.ts e.ts; rc=$?
assert_exit_code "7" "$rc" "a fourth pass over a wider, re-based file set of the same change is refused"
H7b="$PC_TMP/h7b"; mkdir -p "$H7b"
root="$(cd "$PC_TMP/repo" && git rev-parse --path-format=absolute --git-common-dir)"
for i in 1 2 3; do printf '%s\tday-%s\t%s\tfeature/x\ta.ts\n' "$(( $(date +%s) - 3 * 86400 ))" "$i" "$root" >> "$H7b/adversarial-passes.tsv"; done
pc_run "$H7b" mock-echo-files a.ts; rc=$?
assert_exit_code "7" "$rc" "three passes three days ago still cap a feature branch"
H7c="$PC_TMP/h7c"; mkdir -p "$H7c"
for i in 1 2 3; do printf '%s\tweek-%s\t%s\tfeature/x\ta.ts\n' "$(( $(date +%s) - 8 * 86400 ))" "$i" "$root" >> "$H7c/adversarial-passes.tsv"; done
pc_run "$H7c" mock-echo-files a.ts; rc=$?
assert_exit_code "0" "$rc" "eight days ago is outside the window"
git -C "$PC_TMP/repo" checkout -q main

# Bug caught: a second worktree of the branch reading as another repository, so each worktree got three passes.
start_test "PC.8 a second worktree of the same branch is the same change"
git -C "$PC_TMP/repo" branch -q feature/wt
git -C "$PC_TMP/repo" worktree add -q "$PC_TMP/wt2" feature/wt
H8="$PC_TMP/h8"; mkdir -p "$H8"
for i in 1 2 3; do (cd "$PC_TMP/wt2" && pc_diff a.ts | ZUVO_HOME="$H8" ZUVO_ADV_PASS_CAP_TEST=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-echo-files \
  bash "$ADV" --single --mode code) >/dev/null 2>&1; done
mkdir -p "$PC_TMP/wt3"; git -C "$PC_TMP/repo" worktree remove --force "$PC_TMP/wt2" >/dev/null 2>&1
git -C "$PC_TMP/repo" worktree add -q "$PC_TMP/wt3/w" feature/wt
(cd "$PC_TMP/wt3/w" && pc_diff a.ts | ZUVO_HOME="$H8" ZUVO_ADV_PASS_CAP_TEST=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-echo-files \
  bash "$ADV" --single --mode code) >/dev/null 2>&1; rc=$?
assert_exit_code "7" "$rc" "the fourth pass, from another worktree of feature/wt, is refused"
git -C "$PC_TMP/repo" worktree remove --force "$PC_TMP/wt3/w" >/dev/null 2>&1

# Bug caught: an agent that never loaded adversarial-loop.md not knowing which pass it is on.
start_test "PC.9 every pass names its number, on stderr and in the artifact"
H9="$PC_TMP/h9"; mkdir -p "$H9"
(cd "$PC_TMP/repo" && pc_diff q.ts | ZUVO_HOME="$H9" ZUVO_ADV_PASS_CAP_TEST=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-echo-files \
  bash "$ADV" --single --mode code --artifact "$PC_TMP/art9.txt") >/dev/null 2>"$PC_TMP/err9"
assert_contains "$(cat "$PC_TMP/err9")" "adversarial pass 1 of 3" "stderr names pass 1"
assert_contains "$(cat "$PC_TMP/art9.txt" 2>/dev/null)" "adversarial_pass=1/3" "the artifact records it"

# Bug caught: every detached-HEAD review of a repository counted under the one key "detached", so a review host
# that checks each PR out detached refused the fourth UNRELATED PR touching the same files (exit 7).
start_test "PC.10 detached reviews of unrelated changes do not share a counter; fix commits on one change do"
pc_git() { git -C "$PC_TMP/repo" -c user.email=t@t -c user.name=t "$@"; }
pc_git update-ref refs/remotes/origin/main "$(pc_git rev-parse main)"
pc_git checkout -q --detach main; pc_git commit -q --allow-empty -m change-a; PC_A="$(pc_git rev-parse HEAD)"
H10="$PC_TMP/h10"; mkdir -p "$H10"
r=""; for i in 1 2 3; do pc_run "$H10" mock-echo-files a.ts b.ts; r="$r$?,"; done
assert_eq "0,0,0," "$r" "change A, detached: passes 1-3 are reviewed"
pc_git checkout -q --detach main; pc_git commit -q --allow-empty -m change-b
pc_run "$H10" mock-echo-files a.ts b.ts; rc=$?
assert_exit_code "0" "$rc" "change B, detached, same files: its own first pass, not A's fourth"
pc_git checkout -q --detach "$PC_A"; pc_git commit -q --allow-empty -m fix-on-a
pc_run "$H10" mock-echo-files a.ts; rc=$?
assert_exit_code "7" "$rc" "a fix commit on change A is still A: pass 4 refused"
(cd "$PC_TMP/repo" && pc_diff a.ts | ZUVO_HOME="$H10" ZUVO_ADV_PASS_KEY=pr-42 ZUVO_ADV_PASS_CAP_TEST=1 \
  ZUVO_REVIEW_TEST_PROVIDERS=mock-echo-files bash "$ADV" --single --mode code) >/dev/null 2>&1; rc=$?
assert_exit_code "0" "$rc" "ZUVO_ADV_PASS_KEY names another change: reviewed"
# Bug caught: a key stripped to its allowed characters made "pr#42" and "pr?42" one change.
pc_key_run() { (cd "$PC_TMP/repo" && pc_diff a.ts | ZUVO_HOME="$H10" ZUVO_ADV_PASS_KEY="$1" ZUVO_ADV_PASS_CAP_TEST=1 \
  ZUVO_REVIEW_TEST_PROVIDERS=mock-echo-files bash "$ADV" --single --mode code) >/dev/null 2>&1; }
r=""; for i in 1 2 3; do pc_key_run 'pr#42'; r="$r$?,"; done
assert_eq "0,0,0," "$r" "key pr#42: passes 1-3 are reviewed"
pc_key_run 'pr#42'; rc=$?
assert_exit_code "7" "$rc" "key pr#42: pass 4 refused"
pc_key_run 'pr?42'; rc=$?
assert_exit_code "0" "$rc" "key pr?42 is another change, not pr#42 with a character lost"
pc_git checkout -q main

# Bug caught (owner 2026-10-20): three passes of one review session spent the branch's 7-day cap, so a later
# session could not review the 6-line fix it made to that change. Inside a session the cap still holds.
start_test "PC.11 with a known agent session only that session's passes count"
git -C "$PC_TMP/repo" checkout -q -b feature/s
H11="$PC_TMP/h11"; mkdir -p "$H11"
r=""; for i in 1 2 3; do ZUVO_ADV_SESSION=s-one pc_run "$H11" mock-echo-files a.ts; r="$r$?,"; done
assert_eq "0,0,0," "$r" "session one: passes 1-3 are reviewed"
ZUVO_ADV_SESSION=s-one pc_run "$H11" mock-echo-files a.ts; rc=$?
assert_exit_code "7" "$rc" "session one: pass 4 is refused"
assert_contains "$(cat "$PC_TMP/err")" "in this session" "the refusal says the count is this session's"
ZUVO_ADV_SESSION=s-two pc_run "$H11" mock-echo-files a.ts; rc=$?
assert_exit_code "0" "$rc" "session two reviews the same files: session one's passes do not cap it"
CLAUDE_CODE_SESSION_ID=s-one pc_run "$H11" mock-echo-files a.ts; rc=$?
assert_exit_code "7" "$rc" "Claude Code's session id names the same session"
git -C "$PC_TMP/repo" checkout -q main

# Bug caught (tgm-flux RD-7585, 2026-10-21): a pass run without --artifact counted against the cap but left no
# proof, so an agent that reviewed three times that way was refused a fourth (exit 7) and held nothing the pre-push
# gate accepts. A counted pass writes its proof to zuvo/proofs/ itself, and the refusal names the proofs.
start_test "PC.12 a counted pass without --artifact leaves a proof, and the cap refusal names the proofs"
H12="$PC_TMP/h12"; mkdir -p "$H12"
pc_run "$H12" mock-echo-files p.ts; rc=$?
assert_exit_code "0" "$rc" "pass 1 without --artifact is reviewed"
pc_proof="$(cut -f7 "$H12/adversarial-passes.tsv" 2>/dev/null | head -n 1)"
case "$pc_proof" in */repo/zuvo/proofs/auto-main-*.txt) pass "the ledger row records the proof under zuvo/proofs/" ;;
  *) fail "the ledger row records the proof under zuvo/proofs/" "column 7: '$pc_proof'" ;; esac
assert_contains "$(cat "$pc_proof" 2>/dev/null)" "REVIEW BY: MOCK-ECHO-FILES" "the proof carries the gate's REVIEW BY: line"
assert_contains "$(cat "$PC_TMP/err")" "zuvo/proofs/auto-main-" "the run prints where its proof is"
pc_run "$H12" mock-echo-files p.ts; pc_run "$H12" mock-echo-files p.ts
pc_run "$H12" mock-echo-files p.ts; rc=$?
assert_exit_code "7" "$rc" "pass 4 is refused"
assert_eq "3" "$(grep -c 'zuvo/proofs/auto-main-' "$PC_TMP/err")" "the refusal lists the proof of each of the three passes"
assert_contains "$(cat "$PC_TMP/err")" "${pc_proof##*/repo/}" "the refusal names pass 1's proof by its repository path"
# The content-keyed gate matches reviewed_blob= ids: a --files proof without them covers nothing.
printf 'export const v = 1;\n' > "$PC_TMP/repo/blob.ts"
(cd "$PC_TMP/repo" && ZUVO_HOME="$H12" ZUVO_ADV_PASS_CAP_TEST=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-echo-files \
  bash "$ADV" --single --mode code --files blob.ts) >/dev/null 2>&1; rc=$?
assert_exit_code "0" "$rc" "a --files pass without --artifact is reviewed"
pc_proof="$(awk -F'\t' '$5 == "blob.ts" { print $7 }' "$H12/adversarial-passes.tsv" | head -n 1)"
assert_contains "$(cat "$pc_proof" 2>/dev/null)" "reviewed_blob=$(git -C "$PC_TMP/repo" hash-object blob.ts)" \
  "its proof records the reviewed file's blob"
# Bug caught (adversarial review of this fix): the default proof sits in ARTIFACT_PATH, whose write failure exits 2 —
# an unwritable zuvo/proofs/ turned a finished review the caller never asked to save into a failed run.
printf 'not a directory\n' > "$PC_TMP/notadir"
(cd "$PC_TMP/repo" && pc_diff w.ts | ZUVO_OUTPUT_DIR="$PC_TMP/notadir/out" ZUVO_HOME="$H12" ZUVO_ADV_PASS_CAP_TEST=1 \
  ZUVO_REVIEW_TEST_PROVIDERS=mock-echo-files bash "$ADV" --single --mode code) > "$PC_TMP/out" 2> "$PC_TMP/err"; rc=$?
assert_exit_code "0" "$rc" "an unwritable default proof location leaves the review's exit 0"
assert_contains "$(cat "$PC_TMP/err")" "proof could not be written" "and says the proof is missing"
# Bug caught: AR_AUTO_PROOF inherited from the environment made an unwritable --artifact the caller asked for a warning.
(cd "$PC_TMP/repo" && pc_diff w2.ts | AR_AUTO_PROOF=1 ZUVO_HOME="$H12" ZUVO_ADV_PASS_CAP_TEST=1 \
  ZUVO_REVIEW_TEST_PROVIDERS=mock-echo-files bash "$ADV" --single --mode code --artifact "$PC_TMP/notadir/p.txt") >/dev/null 2>&1; rc=$?
assert_exit_code "2" "$rc" "an unwritable --artifact still fails the run, whatever the environment says"
H12b="$PC_TMP/h12b"; mkdir -p "$H12b"
(cd "$PC_TMP/repo" && pc_big x.ts y.ts z.ts | ZUVO_HOME="$H12b" ZUVO_ADV_PASS_CAP_TEST=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-echo-files \
  bash "$ADV" --single --mode code) >/dev/null 2>&1
pc_proof="$(cut -f7 "$H12b/adversarial-passes.tsv" 2>/dev/null | sort -u)"
assert_eq "1" "$(printf '%s\n' "$pc_proof" | grep -c .)" "every part of a chunked pass records the one proof"
assert_ne "0" "$(grep -c '^REVIEW BY:' "$pc_proof" 2>/dev/null)" "the chunked pass's proof holds the parts' reviews"

# Bug caught (tgm-flux RD-7585): a run with no session id counted every session's passes, so an independent reviewer
# without one inherited the author's spent cap. An id-less run counts the passes of its own agent process (the
# nearest ancestor that is an agent CLI), so an agent that drops its session id is still capped.
start_test "PC.13 an id-less run counts its own agent process's passes, not another agent's"
git -C "$PC_TMP/repo" checkout -q -b feature/t
H13="$PC_TMP/h13"; mkdir -p "$H13"
# One long-lived "agent" process runs passes in turn: "-" = no session id, anything else = that session id.
cat > "$PC_TMP/agent.sh" <<'AGENT'
adv="$1" home="$2"; shift 2
for s in "$@"; do
  if [ "$s" = - ]; then
    printf 'diff --git a/t.ts b/t.ts\n@@ -1 +1 @@\n-a\n+b\n' | env -u ZUVO_ADV_SESSION ZUVO_HOME="$home" ZUVO_ADV_PASS_CAP_TEST=1 \
      ZUVO_REVIEW_TEST_PROVIDERS=mock-echo-files bash "$adv" --single --mode code >/dev/null 2>&1
  else
    printf 'diff --git a/t.ts b/t.ts\n@@ -1 +1 @@\n-a\n+b\n' | ZUVO_ADV_SESSION="$s" ZUVO_HOME="$home" ZUVO_ADV_PASS_CAP_TEST=1 \
      ZUVO_REVIEW_TEST_PROVIDERS=mock-echo-files bash "$adv" --single --mode code >/dev/null 2>&1
  fi
  printf '%s,' "$?"
done
AGENT
# exec -a: the process is named like the agent CLI it stands for, which is how the driver finds it.
pc_agent() { local name="$1"; shift; (cd "$PC_TMP/repo" && exec -a "$name" bash "$PC_TMP/agent.sh" "$ADV" "$H13" "$@"); }
assert_eq "0,0,0,7," "$(pc_agent claude author author author -)" \
  "the author's fourth pass, its session id dropped, is still refused"
assert_eq "0," "$(pc_agent codex -)" "an id-less reviewer in another agent process is not capped by the author's passes"
git -C "$PC_TMP/repo" checkout -q main
