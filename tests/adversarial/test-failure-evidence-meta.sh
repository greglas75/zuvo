#!/usr/bin/env bash
# test-failure-evidence-meta.sh — the failure ledger must say WHICH kind of nothing happened.
#
# `~/.zuvo/adversarial-failures/<run>/meta.txt` is what anyone diagnosing a lane reads. Its
# `provider_outcomes` field used to collapse two opposite situations into one word:
#
#   every provider was tried and returned nothing   -> a verdict about the providers
#   the run was KILLED before results were collected -> no verdict about anything
#
# preserve_failure_evidence runs from the EXIT trap, so an outer `timeout`, a reaped process
# group or a Ctrl-C arrives with PROVIDER_OUTCOMES still empty and wrote `none` — the same word
# the first case writes. Measured over the saved evidence: 93 of 259 directories said `none`,
# and one of them holds a provider stderr reporting 11088 input / 3175 output tokens. Real work,
# discarded, filed as "nobody answered". A lane diagnosed from that ledger is diagnosed from
# runs where it was never actually judged.
#
# DISPATCHED_LIST separates them: it is appended as each provider STARTS.
#
# Cases 5-8 pin the rest of preserve_failure_evidence (scripts/lib/adversarial-run.sh): when it keeps
# NOTHING (a provider answered, evidence already saved, no temp dir, no stderr), what counts as stderr, the
# mode it keeps it at, and the prune that must run before every early return.

ADV="$ROOT/scripts/adversarial-review.sh"
MOCKS="$HERE/mocks"
EMPTY="$ADV_TEST_EMPTY"
export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$MOCKS:$PATH"

FE="$ADV_TEST_HOME/fe"; rm -rf "$FE"; mkdir -p "$FE"

meta_of() { # meta_of <home> -> the newest run's meta.txt
  local d; d=$(ls -dt "$1"/adversarial-failures/*/ 2>/dev/null | head -1)
  [ -n "$d" ] && cat "$d/meta.txt" 2>/dev/null
}
field_of() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }   # field_of <meta> <key> -> its value
evidence_dirs() { find "$1/adversarial-failures" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }
fe_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }   # GNU first: on Linux `stat -f` is a filesystem report

# ─── 1. a provider that ran and gave nothing is NAMED, not collapsed ──────
start_test "fe.1 a provider that answered with nothing is recorded by name"
H="$FE/tried"; mkdir -p "$H"
ZUVO_HOME="$H" ZUVO_REVIEW_TEST_PROVIDERS="mock-fail" ZUVO_PROVIDER_BENCH=0 \
  bash "$ADV" --mode code --files "$EMPTY" >/dev/null 2>&1
m=$(meta_of "$H")
# The field itself, exactly: a silent exit 1 is `empty` for that lane — never `none` or `interrupted`.
assert_eq "mock-fail:empty" "$(field_of "$m" provider_outcomes)" "the outcome is the provider's own verdict, by name"
# The all-fail path saves the evidence early and the EXIT trap calls the function again: the second call
# returns at "already saved" (run.sh:234) — one directory for the run, never a second copy.
assert_eq "1" "$(evidence_dirs "$H")" "one evidence directory for the run (the trap's second call keeps nothing more)"

# ─── 2. the dispatch list is recorded, so the kill case is reconstructable ─
start_test "fe.2 meta records which providers were dispatched"
# Its own run and home, so it runs alone and fails apart from fe.1.
H1b="$FE/dispatched"; mkdir -p "$H1b"
ZUVO_HOME="$H1b" ZUVO_REVIEW_TEST_PROVIDERS="mock-fail" ZUVO_PROVIDER_BENCH=0 \
  bash "$ADV" --mode code --files "$EMPTY" >/dev/null 2>&1
m1b=$(meta_of "$H1b")
assert_contains "$m1b" "dispatched=" "dispatched= field present"
assert_contains "$m1b" "dispatched=mock-fail" "…and names the provider that started"
assert_eq "mock-fail" "$(field_of "$m1b" dispatched)" "…and only it, exactly (run.sh:268)"

# ─── 3. THE REGRESSION: killed mid-flight must not read as 'none' ─────────
# Reproduced the way it actually happens — the process is killed while a provider is still
# running, which is what an outer `timeout` or a reaped process group does. With the old code
# this wrote `provider_outcomes=none`, indistinguishable from case 1.
start_test "fe.3 a run killed mid-flight reads as 'interrupted', never 'none'"
H2="$FE/killed"; mkdir -p "$H2" "$FE/bin"
# The lane marks the moment it STARTS — the driver has added it to the dispatch list by then — and then
# hangs as the sleeper itself (exec), so the kill lands mid-flight by a handshake, not after a guessed delay.
cat > "$FE/bin/mock-hang-marked" <<'EOF'
#!/bin/sh
: > "$FE_STARTED"
cat > /dev/null
exec sleep 120
EOF
chmod +x "$FE/bin/mock-hang-marked"
rm -f "$FE/started"
FE_STARTED="$FE/started" PATH="$FE/bin:$PATH" ZUVO_HOME="$H2" ZUVO_REVIEW_TEST_PROVIDERS="mock-hang-marked" \
  ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=120 bash "$ADV" --mode code --files "$EMPTY" >/dev/null 2>&1 &
adv_pid=$!
for _ in $(seq 1 300); do [ -e "$FE/started" ] && break; sleep 0.1; done
if [ -e "$FE/started" ]; then pass "premise: the lane was running when the run was killed"
else fail "premise: the lane never started within 30 s — the kill below is not mid-flight"; fi
kill -TERM "$adv_pid" 2>/dev/null
wait "$adv_pid" 2>/dev/null; fe3_rc=$?
assert_exit_code "143" "$fe3_rc" "an outside TERM ends the run as 143 (run.sh:360), the state the trap then records"
m2=$(meta_of "$H2")
# Empty when the kill path wrote no evidence at all — a different failure, and it fails here too.
assert_eq "interrupted" "$(field_of "$m2" provider_outcomes)" "a killed run's outcome is exactly 'interrupted'"
assert_eq "mock-hang-marked" "$(field_of "$m2" dispatched)" "…and the lane it was waiting on is on the dispatch list"

# ─── the function itself, with the state each case leaves ────────────────
# A whole run cannot reach most of the cases below — evidence is kept only when a lane left stderr behind,
# and only a dispatched lane does — so preserve_failure_evidence is called as the EXIT trap calls it: the
# program's own function (assembled from the modules, never restated), in a subshell, with the run state set.
. "$ROOT/tests/lib/adversarial-driver.sh"   # preserve_failure_evidence lives in a module: read the whole program
fe_fns=""
if adv_driver_source "$ADV" > "$FE/program.sh"; then
  fe_fns="$(grep '^AR_NUM_CAP=' "$FE/program.sh"
    for f in ar_decimal ar_env_int preserve_failure_evidence; do
      awk -v f="$f" '$0 ~ "^" f "\\(\\) \\{" { on = 1 } on { print } on && /^}/ { exit }' "$FE/program.sh"
    done)"
fi
# pfe_in <home> [VAR=value ...] -> the FAILURE_EVIDENCE_DIR preserve_failure_evidence leaves, for a run whose
# temp dir is <home>/tmp (the case lays out what is in it). The defaults are a run in which nothing was
# dispatched and no provider answered; each VAR=value overrides one of them. Status 97: the function could
# not be loaded. With PFE_ERREXIT=1 the function runs under the driver's own `set -euo pipefail` (its caller
# on the all-fail path, report.sh:219, runs with errexit on): a non-zero return then ends the subshell with
# that status before anything is printed — so status 0 and the directory printed mean the function returned 0.
pfe_in() {
  local h="$1" a; shift
  # shellcheck disable=SC2034  # every global below is read by the eval'd preserve_failure_evidence
  ( eval "$fe_fns" || exit 97
    declare -F preserve_failure_evidence >/dev/null || exit 97
    ZUVO_HOME="$h"; JSON_TMPDIR="$h/tmp"; RUN_ID="fe-run"; REVIEW_MODE=code; MULTI_MODE=single
    PROVIDERS=mock-x; PROVIDER_TIMEOUT=120; PROVIDER_COUNT=0; FAILURE_EVIDENCE_DIR=""
    DISPATCHED_LIST=""; PROVIDER_OUTCOMES=""
    for a in "$@"; do printf -v "${a%%=*}" '%s' "${a#*=}"; done
    [[ "${PFE_ERREXIT:-}" != 1 ]] || set -euo pipefail
    preserve_failure_evidence
    printf '%s' "$FAILURE_EVIDENCE_DIR" )
}
# fe_home <case> [stderr-file ...] -> a fresh home whose tmp/ holds the named (empty) stderr files.
fe_home() {
  local h="$FE/pfe-$1" f; shift
  rm -rf "$h"; mkdir -p "$h/tmp"
  for f in "$@"; do : > "$h/tmp/$f"; done
  printf '%s' "$h"
}

# ─── 4. nothing dispatched at all still reads as 'none' ───────────────────
# The word keeps its original meaning for the case it was right about; otherwise the fix would
# just move the ambiguity somewhere else.
start_test "fe.4 'none' survives for the case it actually describes"
if [[ -z "$fe_fns" ]]; then
  fail "the program text could not be assembled (reason above)"
else
  # pfe <case> <dispatched> <outcomes> -> provider_outcomes= of the meta.txt the function writes for a lane
  # that left a stderr file behind.
  pfe() {
    local h; h="$(fe_home "$1" provider_mock-x.stderr)"
    pfe_in "$h" "RUN_ID=fe4-$1" "DISPATCHED_LIST=$2" "PROVIDER_OUTCOMES=$3" >/dev/null
    field_of "$(cat "$h/adversarial-failures/fe4-$1/meta.txt" 2>/dev/null)" provider_outcomes
  }
  assert_eq "none" "$(pfe none "" "")" "nothing dispatched: 'none'"
  assert_eq "interrupted" "$(pfe killed mock-x "")" "dispatched, no outcome yet: 'interrupted'"
  assert_eq "mock-x:empty" "$(pfe judged mock-x mock-x:empty)" "an outcome recorded: the outcome itself"
fi

# ─── 5. when there is nothing to keep, nothing is kept ────────────────────
start_test "fe.5 a run in which a provider answered keeps no evidence (whole run)"
H5="$FE/answered"; mkdir -p "$H5"
ZUVO_HOME="$H5" ZUVO_REVIEW_TEST_PROVIDERS="mock-success" ZUVO_PROVIDER_BENCH=0 \
  bash "$ADV" --mode code --files "$EMPTY" >/dev/null 2>&1; fe5_rc=$?
assert_exit_code "0" "$fe5_rc" "premise: the review completed"
assert_eq "0" "$(evidence_dirs "$H5")" "no evidence directory: a review exists (run.sh:235)"

start_test "fe.5b each early return keeps nothing and claims nothing"
if [[ -z "$fe_fns" ]]; then
  fail "the program text could not be assembled (reason above)"
else
  # run.sh:235 — a provider answered: its stderr is not failure evidence.
  h="$(fe_home answered provider_mock-x.stderr)"
  assert_eq "" "$(pfe_in "$h" PROVIDER_COUNT=1 DISPATCHED_LIST=mock-x PROVIDER_OUTCOMES=mock-x:ok)" "a provider answered: no evidence dir is reported"
  assert_eq "0" "$(evidence_dirs "$h")" "…and none is written"
  # run.sh:234 — already saved (the fail path calls it before the trap does): the first save stands.
  h="$(fe_home saved provider_mock-x.stderr)"
  assert_eq "$FE/earlier-save" "$(pfe_in "$h" "FAILURE_EVIDENCE_DIR=$FE/earlier-save")" "already saved: the earlier directory stays the answer"
  assert_eq "0" "$(evidence_dirs "$h")" "…and no second copy is written"
  # run.sh:236 — the temp dir is gone (cleanup removed it, or it was never made).
  h="$(fe_home notmp)"
  assert_eq "" "$(pfe_in "$h" "JSON_TMPDIR=$h/gone")" "no temp dir: no evidence dir is reported"
  assert_eq "0" "$(evidence_dirs "$h")" "…and none is written"
  # run.sh:240-244 — a temp dir with no provider stderr: nothing a reader could diagnose from.
  h="$(fe_home nostderr)"; : > "$h/tmp/result_mock-x.txt"
  assert_eq "" "$(pfe_in "$h" DISPATCHED_LIST=mock-x)" "no stderr file: no evidence dir is reported"
  assert_eq "0" "$(evidence_dirs "$h")" "…and none is written"
fi

# ─── 6. either stderr shape is evidence, and it is copied ─────────────────
start_test "fe.6 an err_*.txt alone is evidence (the glob test, not ls) and is copied with the meta"
if [[ -z "$fe_fns" ]]; then
  fail "the program text could not be assembled (reason above)"
else
  # run.sh:237-243: `ls a* b*` bailed when EITHER pattern missed; the glob test keeps a lane that left
  # err_ but no provider_ stderr. run.sh:261 copies it.
  h="$(fe_home erronly err_mock-x.txt)"; printf 'quota exceeded\n' > "$h/tmp/err_mock-x.txt"
  assert_eq "$h/adversarial-failures/fe-run" "$(pfe_in "$h" DISPATCHED_LIST=mock-x PROVIDER_OUTCOMES=mock-x:quota)" \
    "the evidence dir is <home>/adversarial-failures/<run id>"
  assert_eq "quota exceeded" "$(cat "$h/adversarial-failures/fe-run/err_mock-x.txt" 2>/dev/null)" "the lane's stderr is copied verbatim"
  assert_eq "mock-x:quota" "$(field_of "$(cat "$h/adversarial-failures/fe-run/meta.txt" 2>/dev/null)" provider_outcomes)" \
    "…beside a meta.txt with the recorded outcome"
fi

# ─── 7. kept third-party stderr is private ────────────────────────────────
start_test "fe.7 the evidence root and the run's dir are 0700, even when the root pre-existed looser"
if [[ -z "$fe_fns" ]]; then
  fail "the program text could not be assembled (reason above)"
else
  # run.sh:253-257: `mkdir -m` sets the mode only on what it creates — the chmod tightens a root left over
  # from a pre-0700 run. An auth failure can print a token; it is kept for a week.
  h="$(fe_home private provider_mock-x.stderr)"; mkdir -p "$h/adversarial-failures"; chmod 755 "$h/adversarial-failures"
  pfe_in "$h" DISPATCHED_LIST=mock-x PROVIDER_OUTCOMES=mock-x:auth >/dev/null
  assert_eq "700" "$(fe_mode "$h/adversarial-failures")" "the pre-existing 755 root is tightened to 700"
  assert_eq "700" "$(fe_mode "$h/adversarial-failures/fe-run")" "the run's evidence dir is 700"
fi

# ─── 8. the prune runs before every early return ──────────────────────────
start_test "fe.8 a run that keeps nothing still prunes evidence older than ZUVO_FAILURE_EVIDENCE_DAYS"
if [[ -z "$fe_fns" ]]; then
  fail "the program text could not be assembled (reason above)"
else
  # run.sh:231-233 sit ABOVE every return: behind `PROVIDER_COUNT > 0 && return` the prune almost never ran,
  # and the directory reached back 8 days past a correct-looking 7-day prune.
  h="$(fe_home prune provider_mock-x.stderr)"
  mkdir -p "$h/adversarial-failures/old-run" "$h/adversarial-failures/young-run"
  python3 -c 'import os,sys,time
for p, days in ((sys.argv[1], 10), (sys.argv[2], 1)):
    t = time.time() - days * 86400; os.utime(p, (t, t))' "$h/adversarial-failures/old-run" "$h/adversarial-failures/young-run"
  ZUVO_FAILURE_EVIDENCE_DAYS=7 pfe_in "$h" PROVIDER_COUNT=1 PROVIDER_OUTCOMES=mock-x:ok >/dev/null
  assert_eq "young-run" "$(ls "$h/adversarial-failures" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')" \
    "the 10-day-old dir is pruned, the 1-day-old one kept — by a call that returned early"
fi

# ─── 9. evidence that cannot be written: fail-open, and the run keeps its own status ──
# preserve_failure_evidence (run.sh:253, :256, :261-262) never fails its caller: the evidence root or the run's
# dir it cannot make ends it with status 0 and no directory claimed (FAILURE_EVIDENCE_DIR stays empty), and a
# copy that fails is passed over (`|| true`) — the meta.txt is still written and the dir is still the answer
# (:290-291). The all-fail path calls it with errexit on (report.sh:219), so a non-zero return there would end
# the run before it says why it failed, with the wrong status.
# fe_cp_shim <dir> — a `cp` in <dir> that refuses every copy into an adversarial-failures/ path (status 1) and
# execs the real cp for anything else: in the driver, only these evidence copies take such a path.
fe_cp_shim() {
  mkdir -p "$1"
  printf '#!/bin/sh\nfor a in "$@"; do case "$a" in */adversarial-failures/*) echo "cp shim: refused $a" >&2; exit 1 ;; esac; done\nexec %s "$@"\n' \
    "$(command -v cp)" > "$1/cp"
  chmod +x "$1/cp"
}
start_test "fe.9 an evidence dir that cannot be made, or a copy that fails, never fails the caller"
if [[ -z "$fe_fns" ]]; then
  fail "the program text could not be assembled (reason above)"
else
  # run.sh:253 — the evidence root cannot be made (a regular file holds its name): status 0, no dir claimed.
  h="$(fe_home noroot provider_mock-x.stderr)"; : > "$h/adversarial-failures"
  fe9_dir="$(PFE_ERREXIT=1 pfe_in "$h" DISPATCHED_LIST=mock-x PROVIDER_OUTCOMES=mock-x:empty)"; fe9_rc=$?
  assert_eq "0|" "$fe9_rc|$fe9_dir" "no evidence root: the function returns 0 under errexit and claims no dir (run.sh:253)"
  assert_eq "file 0" "$([ -f "$h/adversarial-failures" ] && echo file) $(wc -c < "$h/adversarial-failures" | tr -d ' ')" \
    "…and the empty regular file in the root's place is left as it was"
  # run.sh:256 — the root is made, the run's dir is not (a regular file holds <root>/<run id>).
  h="$(fe_home nodest provider_mock-x.stderr)"; mkdir -p "$h/adversarial-failures"; : > "$h/adversarial-failures/fe-run"
  fe9_dir="$(PFE_ERREXIT=1 pfe_in "$h" DISPATCHED_LIST=mock-x PROVIDER_OUTCOMES=mock-x:empty)"; fe9_rc=$?
  assert_eq "0|" "$fe9_rc|$fe9_dir" "no run dir: the function returns 0 under errexit and claims no dir (run.sh:256)"
  assert_eq "file 0 700" "$([ -f "$h/adversarial-failures/fe-run" ] && echo file) $(wc -c < "$h/adversarial-failures/fe-run" | tr -d ' ') $(fe_mode "$h/adversarial-failures")" \
    "…the file in the dir's place is untouched, and the root was still tightened to 700 (run.sh:254)"
  # run.sh:261-262 — both copies fail: passed over, the meta is still written and the dir is the answer.
  h="$(fe_home nocopy err_mock-x.txt provider_mock-x.stderr)"; printf 'quota exceeded\n' > "$h/tmp/err_mock-x.txt"
  fe_cp_shim "$FE/cp-shim"
  fe9_dir="$(PATH="$FE/cp-shim:$PATH" PFE_ERREXIT=1 pfe_in "$h" DISPATCHED_LIST=mock-x PROVIDER_OUTCOMES=mock-x:quota)"; fe9_rc=$?
  assert_eq "0|$h/adversarial-failures/fe-run" "$fe9_rc|$fe9_dir" "copies refused: the function returns 0 under errexit with the run's dir (run.sh:261-262, :291)"
  assert_eq "meta.txt" "$(ls "$h/adversarial-failures/fe-run" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')" \
    "premise: the shim refused both copies — the dir holds the meta.txt alone"
  assert_eq "mock-x:quota mock-x" \
    "$(m9="$(cat "$h/adversarial-failures/fe-run/meta.txt" 2>/dev/null)"; printf '%s %s' "$(field_of "$m9" provider_outcomes)" "$(field_of "$m9" dispatched)")" \
    "…a meta.txt with the run's outcome and dispatch list (run.sh:263-290)"
fi

start_test "fe.10 a whole run whose evidence cannot be kept still ends as the failure it is (exit 2, said why)"
# The all-fail path through the real driver: mock-fail answers nothing, so the run is FINAL_STATUS=error, exit 2
# (report.sh:214, :269). The evidence root's name is taken by a regular file: nothing is kept, the run says
# nothing about evidence (no "stderr kept in", report.sh:238; evidence_dir "", :250) — and keeps its own exit.
H10="$FE/noroot-run"; rm -rf "$H10"; mkdir -p "$H10"; : > "$H10/adversarial-failures"
fe10_out="$(ZUVO_HOME="$H10" ZUVO_REVIEW_TEST_PROVIDERS="mock-fail" ZUVO_PROVIDER_BENCH=0 \
  bash "$ADV" --mode code --json --files "$EMPTY" 2>"$FE/noroot-run.err")"; fe10_rc=$?
assert_exit_code "2" "$fe10_rc" "the run exits with its own status: 2, every provider failed (report.sh:214)"
assert_eq "ERROR: no review produced — every provider was reached and returned no review. Tried: mock-fail (outcomes: mock-fail:empty)" \
  "$(grep '^ERROR: no review produced' "$FE/noroot-run.err")" "the run says why it failed, and claims no kept stderr (report.sh:238, :262)"
assert_eq "error||every provider was reached and returned no review|mock-fail:empty" \
  "$(printf '%s' "$fe10_out" | jq -r '"\(.status)|\(.evidence_dir)|\(.note)|\(.provider_outcomes)"' 2>/dev/null)" \
  "the JSON: status error, evidence_dir empty, the note without a kept-stderr clause (report.sh:250)"
assert_eq "file" "$([ -f "$H10/adversarial-failures" ] && echo file)" "…and the regular file in the root's place is still a file"
# The copies fail instead (the cp shim): the run still exits 2, and its evidence dir holds the meta.txt.
H10b="$FE/nocopy-run"; rm -rf "$H10b"; mkdir -p "$H10b"; fe_cp_shim "$FE/cp-shim"
fe10b_out="$(PATH="$FE/cp-shim:$PATH" ZUVO_HOME="$H10b" ZUVO_REVIEW_TEST_PROVIDERS="mock-fail" ZUVO_PROVIDER_BENCH=0 \
  bash "$ADV" --mode code --json --files "$EMPTY" 2>"$FE/nocopy-run.err")"; fe10b_rc=$?
assert_exit_code "2" "$fe10b_rc" "copies refused: the run still exits 2"
fe10b_dir="$(ls -d "$H10b"/adversarial-failures/*/ 2>/dev/null | head -1)"; fe10b_dir="${fe10b_dir%/}"
assert_eq "meta.txt" "$(ls "$fe10b_dir" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')" "premise: the copies were refused — the run's evidence dir holds the meta.txt alone"
assert_eq "mock-fail:empty|mock-fail" "$(m10="$(cat "$fe10b_dir/meta.txt" 2>/dev/null)"; printf '%s|%s' "$(field_of "$m10" provider_outcomes)" "$(field_of "$m10" dispatched)")" \
  "…with the run's outcome and dispatch list"
assert_eq "error|mock-fail:empty|$fe10b_dir" "$(printf '%s' "$fe10b_out" | jq -r '"\(.status)|\(.provider_outcomes)|\(.evidence_dir)"' 2>/dev/null)" \
  "the JSON points at that dir (report.sh:250)"
