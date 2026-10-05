#!/usr/bin/env bash
# test-bench-harness.sh — scripts/bench/ (the adversarial-reviewer benchmark harness).
# No network, no real judge: the judge CLI is a stub on PATH and the driver is a stub script.
# Each case pins a defect that corrupted a real measurement (see scripts/bench/judge.sh header).
source "$(dirname "$0")/../seo-suite/assert.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
B="$ROOT/scripts/bench"
T=$(mktemp -d "${TMPDIR:-/tmp}/bench-harness.XXXXXX")
trap 'rm -rf "$T"' EXIT
export BENCH_HOME="$T/bench"
P1=1700000001-1; P2=1700000002-2
mkdir -p "$BENCH_HOME"/{judge2/$P1,judge2/$P2,or/raw,subs,shim} "$T/bin"
printf 'diff --git a/a.ts b/a.ts\n+one\n' > "$BENCH_HOME/judge2/$P1/CODE.diff"
printf 'diff --git a/b.ts b/b.ts\n+two\n' > "$BENCH_HOME/judge2/$P2/CODE.diff"
printf '## %s a.ts\n- slug-a\n## %s b.ts\n- slug-b\n' "$P1" "$P2" > "$BENCH_HOME/judge2/DEFECT_VOCAB.md"
printf '{"ok":[{"diff":"/nonexistent/%s.diff"}],"fail":[{"diff":"/nonexistent/%s.diff"}]}\n' "$P1" "$P2" > "$BENCH_HOME/sel.json"
FINDING='SEVERITY: WARNING
CONFIDENCE: high
FILE: a.ts:1
ISSUE: a real looking issue long enough to pass the 120-byte emptiness floor of the judge
SUGGESTED FIX: fix it'

# ---- judge stub: answers with one TSV row naming which findings file it was shown ---------------
cat > "$T/bin/judge-stub" <<'STUB'
#!/usr/bin/env bash
echo x >> "$BENCH_STUB_CALLS"
prompt=""; model=""
while [ $# -gt 0 ]; do
  [ "$1" = "-p" ] && prompt="$2"
  [ "$1" = "--model" ] && model="$2"
  shift
done
printf '%s\n' "$model" >> "$BENCH_STUB_CALLS.models"
printf '%s' "$prompt" > "$BENCH_STUB_CALLS.prompt"
case "$prompt" in *NOT-TSV-PLEASE*) echo "I cannot help with that."; exit 0 ;; esac
case "$prompt" in *FAIL-JUDGE*) [ -f "$BENCH_STUB_HEAL" ] || { printf 'WARNING\tREAL\tslug-a\treused\tpartial\n'; exit 1; } ;; esac
case "$prompt" in *BADROW*) printf 'WARNING\tMAYBE\tslug-a\treused\tbad\nWARNING\tREAL\t-\treused\tno-slug\n'; printf 'WARNING\tFALSE_POSITIVE\t-\t-\tfine\n'; exit 0 ;; esac
src=OWN; case "$prompt" in *NEIGHBOUR-FILE*) src=NEIGHBOUR ;; esac
printf 'WARNING\tREAL\tslug-a\treused\tjudged-%s\n' "$src"
STUB
chmod +x "$T/bin/judge-stub"
export BENCH_JUDGE_CLI="$T/bin/judge-stub" BENCH_STUB_CALLS="$T/calls" BENCH_STUB_HEAL="$T/heal"
: > "$BENCH_STUB_CALLS"
calls() { wc -l < "$BENCH_STUB_CALLS" | tr -d ' '; }

# ==== judge.sh — exact file next to a neighbouring label =========================================
# old glob `vendor_model-*-<id>` sorted vendor_model-mini-ok-… BEFORE vendor_model-ok-…
printf '%s\nOWN-FILE\n' "$FINDING" > "$BENCH_HOME/or/raw/vendor_model-ok-$P1.txt"
printf '%s\nNEIGHBOUR-FILE\n' "$FINDING" > "$BENCH_HOME/or/raw/vendor_model-mini-ok-$P1.txt"
# packet 2: findings, then a trailing NO ISSUES FOUND line — must be JUDGED, not skipped
printf '%s\n\nNO ISSUES FOUND.\n' "$FINDING" > "$BENCH_HOME/or/raw/vendor_model-fail-$P2.txt"
bash "$B/judge.sh" vendor/model --source or > "$T/j1.log" 2>&1 || fail "judge.sh or exited non-zero: $(cat "$T/j1.log")"
V="$BENCH_HOME/judge2/verdicts-vendor_model.tsv"
assert_file_exists "$V"
assert_equals "$P1	vendor/model	WARNING	REAL	slug-a	reused	judged-OWN" "$(awk -F'\t' -v id="$P1" '$1==id' "$V")" \
  "packet 1's verdict row: exact TSV (packet, label, severity, verdict, slug, new_slug, reason) from the label's OWN file"
assert_equals "input	model	severity	verdict	defect_id	new_slug	reason" "$(head -1 "$V")" "verdicts header"
! grep -q "judged-NEIGHBOUR" "$V" || fail "judge read the neighbouring label's file (aion-3.5 → aion-3.5-mini defect)"
grep -q "^$P2	" "$V" || fail "findings followed by 'NO ISSUES FOUND' were skipped instead of judged"
assert_equals 2 "$(calls)" "two packets → two judge calls"
# the last call judged packet 2: its prompt holds packet 2's slug and NOT packet 1's
assert_contains "$BENCH_STUB_CALLS.prompt" "- slug-b"
! grep -q -- "- slug-a" "$BENCH_STUB_CALLS.prompt" || fail "the judge prompt carried another packet's vocabulary (a slug from a foreign diff fakes shared coverage)"
assert_contains "$BENCH_STUB_CALLS.prompt" "+two"
! grep -q -- "+one" "$BENCH_STUB_CALLS.prompt" || fail "the judge prompt carried another packet's diff"
pass "judge.sh: exact findings file; findings + trailing NO ISSUES are judged; vocabulary cut to the packet"

# re-run: both packets have verdicts → no new judge call
bash "$B/judge.sh" vendor/model --source or > /dev/null 2>&1
assert_equals 2 "$(calls)" "re-run must not judge already-judged packets"
# cached raw answer is reused when verdicts are lost (paid call not repeated)
head -1 "$V" > "$V.tmp" && mv "$V.tmp" "$V"
bash "$B/judge.sh" vendor/model --source or > "$T/j2.log" 2>&1
assert_equals 2 "$(calls)" "a cached judge answer must be reused, not paid for again"
assert_contains "$T/j2.log" "[z dysku] $P1"
pass "judge.sh: resumes and reuses cached judge answers"

# ==== judge.sh — clean detection on CLI (driver-wrapped) outputs ==================================
wrap() { printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
  "===============================================================" "CROSS-PROVIDER ADVERSARIAL REVIEW" \
  "===============================================================" "Providers: codex-5.3 (1 total)" "Mode: code" \
  "Input size: 6132 chars" "Date: 2026-09-23T16:51:51Z" "===============================================================" "$1" \
  "END OF CROSS-PROVIDER REVIEW"; }
wrap "NO ISSUES FOUND." > "$BENCH_HOME/subs/lab-$P1.out"
wrap "$FINDING" > "$BENCH_HOME/subs/lab-$P2.out"
: > "$BENCH_STUB_CALLS"
bash "$B/judge.sh" lab --source cli > "$T/j3.log" 2>&1
assert_contains "$T/j3.log" "[czysty/pusty] $P1"
assert_equals 1 "$(calls)" "only the packet with a finding is sent to the judge"
grep -q "^$P2	lab	" "$BENCH_HOME/judge2/verdicts-lab.tsv" || fail "wrapped answer with findings not judged"
pass "judge.sh: wrapped NO ISSUES = clean, wrapped findings = judged"

# tiny answer (< 120 B) is clean; missing answer is reported, not judged
printf 'ok\n' > "$BENCH_HOME/or/raw/tiny-ok-$P1.txt"
: > "$BENCH_STUB_CALLS"
bash "$B/judge.sh" tiny --source or > "$T/j4.log" 2>&1
assert_contains "$T/j4.log" "[czysty/pusty] $P1"
assert_contains "$T/j4.log" "[brak] $P2"
assert_equals 0 "$(calls)" "empty and missing answers must not reach the judge"
pass "judge.sh: tiny answers are clean, missing answers are reported"
printf '%s\n' "This answer is long enough to hold a finding but uses no recognised marker at all; it describes a stale cache read in prose only, which the judge must see." > "$BENCH_HOME/or/raw/prose-ok-$P1.txt"
: > "$BENCH_HOME/or/raw/prose-fail-$P2.txt"
: > "$BENCH_STUB_CALLS"
bash "$B/judge.sh" prose --source or > "$T/j15.log" 2>&1
assert_equals 1 "$(calls)" "a long answer with no marker and no NO ISSUES must go to the judge"
assert_contains "$T/j15.log" "[brak] $P2"
pass "judge.sh: unmarked long answers are judged; a 0-byte answer counts as missing"

# a judge reply without one TSV row is rejected loudly and writes no verdict
printf '%s\nNOT-TSV-PLEASE\n' "$FINDING" > "$BENCH_HOME/or/raw/rej-ok-$P1.txt"
bash "$B/judge.sh" rej --source or > "$T/j5.log" 2>&1
assert_contains "$T/j5.log" "judge returned no TSV row for $P1"
! grep -q "^$P1	" "$BENCH_HOME/judge2/verdicts-rej.tsv" || fail "unparsable judge reply produced a verdict row"
ls "$BENCH_HOME/judge2/raw/claude-opus-5/rejected/rej-$P1".*.txt >/dev/null 2>&1 || fail "rejected reply not kept"
pass "judge.sh: unparsable judge reply is kept in rejected/, no verdict written"

# findings without a SEVERITY header (nemotron writes `**CRITICAL …`) + closing NO ISSUES → judged
printf '**CRITICAL** — %s\n\nNO ISSUES FOUND.\n' "a race between two writers of the same results file that loses rows" > "$BENCH_HOME/or/raw/nemo-ok-$P1.txt"
: > "$BENCH_STUB_CALLS"
bash "$B/judge.sh" nemo --source or > "$T/j6.log" 2>&1
assert_equals 1 "$(calls)" "a '**CRITICAL' finding followed by NO ISSUES must be judged"
pass "judge.sh: findings without a SEVERITY header are still findings"

# a judge call that exits non-zero: no verdict, no cache; the next run judges the packet
printf '%s\nFAIL-JUDGE\n' "$FINDING" > "$BENCH_HOME/or/raw/flaky-ok-$P1.txt"
bash "$B/judge.sh" flaky --source or > "$T/j7.log" 2>&1
assert_contains "$T/j7.log" "(exit 1)"
! grep -q "^$P1	" "$BENCH_HOME/judge2/verdicts-flaky.tsv" || fail "a failed judge call produced a verdict"
! ls "$BENCH_HOME/judge2/raw/claude-opus-5/flaky-$P1"-*.txt >/dev/null 2>&1 || fail "a failed judge call was cached"
touch "$BENCH_STUB_HEAL"
bash "$B/judge.sh" flaky --source or > "$T/j8.log" 2>&1
grep -q "^$P1	flaky	" "$BENCH_HOME/judge2/verdicts-flaky.tsv" || fail "the packet must be judged once the judge works again"
pass "judge.sh: a failed judge call is neither a verdict nor a cache entry"

# invalid verdict rows are dropped with a warning; valid ones kept
printf '%s\nBADROW\n' "$FINDING" > "$BENCH_HOME/or/raw/badrow-ok-$P1.txt"
bash "$B/judge.sh" badrow --source or > "$T/j9.log" 2>&1
assert_contains "$T/j9.log" "2 judge row(s) dropped"
assert_equals 1 "$(awk -F'\t' -v id="$P1" '$1==id' "$BENCH_HOME/judge2/verdicts-badrow.tsv" | wc -l | tr -d ' ')" "only the valid FALSE_POSITIVE row may be kept"
pass "judge.sh: rows with an unknown verdict or a REAL without a slug are dropped"

# one judge per label
mkdir "$BENCH_HOME/judge2/.lock-vendor_model"
rc=0; bash "$B/judge.sh" vendor/model --source or > /dev/null 2>&1 || rc=$?
rmdir "$BENCH_HOME/judge2/.lock-vendor_model"
assert_equals 3 "$rc" "a second judge on the same label must refuse (exit 3)"
mkdir "$BENCH_HOME/judge2/.lock-vendor_model"; echo 999999 > "$BENCH_HOME/judge2/.lock-vendor_model/pid"
rc=0; bash "$B/judge.sh" vendor/model --source or > "$T/j10.log" 2>&1 || rc=$?
assert_equals 0 "$rc" "a lock left by a dead PID must be reclaimed"
assert_contains "$T/j10.log" "reclaimed the stale lock of dead PID 999999"
[ ! -d "$BENCH_HOME/judge2/.lock-vendor_model" ] || fail "the lock must be released on exit"
pass "judge.sh: a concurrent judge is refused; a dead owner's lock is reclaimed"

# a flag without its value must not loop forever; a judge model must not be a path
rc=0; python3 -c 'import subprocess,sys; sys.exit(subprocess.run(["bash",sys.argv[1],"x","--source"],timeout=10,capture_output=True).returncode)' "$B/judge.sh" || rc=$?
assert_equals 2 "$rc" "a dangling --source must be a usage error, not a hang"
for bad in ../../etc '' '.hidden' 'has space' 'a/b' 'semi;colon'; do
  rc=0; bash "$B/judge.sh" x --source or --judge-model "$bad" > /dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "judge model '$bad' must be refused"
done
pass "judge.sh: dangling flags and path-like judge models are refused"

# a cached judge answer that holds no valid row is not reused: the judge is called again
mkdir -p "$BENCH_HOME/judge2/raw/claude-opus-5"
printf '%s\n' "$FINDING" > "$BENCH_HOME/or/raw/recache-ok-$P1.txt"
key=$(cksum < "$BENCH_HOME/or/raw/recache-ok-$P1.txt" | awk '{print $1}')
printf 'garbage, not TSV\n' > "$BENCH_HOME/judge2/raw/claude-opus-5/recache-$P1-$key.txt"
: > "$BENCH_STUB_CALLS"
bash "$B/judge.sh" recache --source or > "$T/j11.log" 2>&1
assert_equals 1 "$(calls)" "an unusable cached answer must be replaced by a fresh judge call"
grep -q "^$P1	recache	" "$BENCH_HOME/judge2/verdicts-recache.tsv" || fail "the fresh answer must become the verdict"
pass "judge.sh: an unusable cached judge answer is not reused"

# another judge model: passed to the CLI and cached in its own directory
: > "$BENCH_STUB_CALLS.models"
printf '%s\n' "$FINDING" > "$BENCH_HOME/or/raw/fable-ok-$P1.txt"
bash "$B/judge.sh" fable --source or --judge-model claude-fable-5-1 > /dev/null 2>&1
assert_equals "claude-fable-5-1" "$(tail -1 "$BENCH_STUB_CALLS.models")" "--judge-model must reach the judge CLI"
ls "$BENCH_HOME/judge2/raw/claude-fable-5-1/fable-$P1"-*.txt >/dev/null 2>&1 || fail "the fable answer must be cached under its own model"
! ls "$BENCH_HOME/judge2/raw/claude-opus-5/fable-$P1"-*.txt >/dev/null 2>&1 || fail "a judge model's answers must not land in another model's cache"
pass "judge.sh: --judge-model reaches the CLI and keeps its own cache"

# missing corpus, missing vocabulary, missing judge CLI: loud usage errors, nothing judged
rc=0; BENCH_HOME="$T/nowhere" bash "$B/judge.sh" x --source or > "$T/j12.log" 2>&1 || rc=$?
assert_equals 2 "$rc" "a missing corpus must exit 2"
assert_contains "$T/j12.log" "no corpus"
mv "$BENCH_HOME/judge2/DEFECT_VOCAB.md" "$T/vocab.bak"
rc=0; bash "$B/judge.sh" x --source or > "$T/j13.log" 2>&1 || rc=$?
mv "$T/vocab.bak" "$BENCH_HOME/judge2/DEFECT_VOCAB.md"
assert_equals 2 "$rc" "a missing vocabulary must exit 2"
assert_contains "$T/j13.log" "DEFECT_VOCAB.md"
rc=0; BENCH_JUDGE_CLI="$T/bin/no-such-judge" bash "$B/judge.sh" x --source or > "$T/j14.log" 2>&1 || rc=$?
assert_equals 2 "$rc" "a missing judge CLI must exit 2"
assert_contains "$T/j14.log" "not on PATH"
pass "judge.sh: missing corpus, vocabulary or judge CLI are usage errors"

# a cached answer belongs to the findings it judged: new findings under the same label are judged anew
head -1 "$V" > "$V.tmp" && awk -F'\t' -v id="$P2" 'NR>1 && $1==id' "$V" >> "$V.tmp" && mv "$V.tmp" "$V"
printf '%s\nOWN-FILE second run with different findings\n' "$FINDING" > "$BENCH_HOME/or/raw/vendor_model-ok-$P1.txt"
: > "$BENCH_STUB_CALLS"
bash "$B/judge.sh" vendor/model --source or > "$T/j16.log" 2>&1
assert_equals 1 "$(calls)" "changed findings must not reuse the judge answer of the old findings"
! grep -q "\[z dysku\] $P1" "$T/j16.log" || fail "the old cached answer was reused for new findings"
pass "judge.sh: the judge cache is keyed by the findings, not only by label and packet"

# INFO-only findings (no SEVERITY header) followed by NO ISSUES are findings, not a clean answer
printf '[INFO] %s\n\nNO ISSUES FOUND.\n' "a log line leaks the absolute path of the benchmark home directory on every call" > "$BENCH_HOME/or/raw/infoonly-ok-$P1.txt"
: > "$BENCH_STUB_CALLS"
bash "$B/judge.sh" infoonly --source or > /dev/null 2>&1
assert_equals 1 "$(calls)" "an INFO finding must be judged"
pass "judge.sh: INFO findings count as findings"

# labels: a '/' label has no CLI answers; unsafe characters are refused
rc=0; bash "$B/judge.sh" a/b --source cli > "$T/j17.log" 2>&1 || rc=$?
assert_equals 2 "$rc" "a '/' label with --source cli must be refused"
assert_contains "$T/j17.log" "--source or"
for bad in 'has space' '../x' '/abs' 'semi;colon'; do
  rc=0; bash "$B/judge.sh" "$bad" --source or > /dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "label '$bad' must be refused"
done
pass "judge.sh: labels are validated; '/' labels are OpenRouter-only"

# usage errors
bash "$B/judge.sh" x > /dev/null 2>&1 && fail "judge.sh without --source must fail"
bash "$B/judge.sh" x --source nope > /dev/null 2>&1 && fail "judge.sh with a bad --source must fail"
pass "judge.sh: usage errors exit non-zero"

# ==== evaluate-model.py — missed reviews on wrapped output, reference never contains the candidate
out=$(python3 "$B/evaluate-model.py" lab)
printf '%s\n' "$out" | grep -q "przegapione review  : 1/2" || fail "wrapped NO ISSUES must count as a missed review: $out"
out=$(python3 "$B/evaluate-model.py" vendor/model)
printf '%s\n' "$out" | grep -q "przegapione review  : 0/2" || fail "findings + trailing NO ISSUES is not a missed review: $out"
printf 'model\tseverity\tverdict\tspeculative\tdefect_id\treason\nkimi\tWARNING\tREAL\tfalse\tslug-a\tr\ncursor-agent\tWARNING\tREAL\tfalse\tslug-b\tr\n' \
  > "$BENCH_HOME/judge2/$P1/VERDICT_OPUS.tsv"
out=$(python3 "$B/evaluate-model.py" kimi)
printf '%s\n' "$out" | grep -q "dokłada NOWE: 1" || fail "a reference-set member must be measured against the OTHER members, got: $out"
printf '%s\n' "$out" | grep -q "wsadow z werdyktami : 1/2" || fail "a round-1 model's judged packets = packets it has rows in, not the corpus size: $out"
printf 'input\tmodel\tseverity\tverdict\tdefect_id\tnew_slug\treason\n%s\tcursor-agent\tWARNING\tFALSE_POSITIVE\t-\t-\tr\n' "$P2" > "$BENCH_HOME/judge2/verdicts-cursor-agent.tsv"
out=$(python3 "$B/evaluate-model.py" cursor-agent)
printf '%s\n' "$out" | grep -q "REAL / FP           : 0 / 1" || fail "an existing verdicts file must win over round-1 packets even with no REAL row: $out"
printf 'HTTP Error 429: Too Many Requests\n' > "$BENCH_HOME/or/raw/infra_lab-ok-$P1.txt"
printf '%s\n' "$FINDING" > "$BENCH_HOME/or/raw/infra_lab-fail-$P2.txt"
printf 'infra/lab\tok\t%s\t9\terr:HTTPError\tunparsed\t0\t2\t0\t0\t0\n' "$P1" >> "$BENCH_HOME/or/results.tsv"
out=$(python3 "$B/evaluate-model.py" infra/lab)
printf '%s\n' "$out" | grep -q "przegapione review  : 0/1" || fail "an infrastructure error is not the model's miss: $out"
printf '%s\n' "$out" | grep -q "błędy infrastruktury: 1" || fail "infrastructure errors must be reported separately: $out"
printf 'infra/lab\tok\t%s\t9\terr:TimeoutError\tunparsed\t0\t295\t0\t0\t0\n' "$P1" >> "$BENCH_HOME/or/results.tsv"
out=$(BENCH_TIMEOUT=300 python3 "$B/evaluate-model.py" infra/lab)
! printf '%s\n' "$out" | grep -q "błędy infrastruktury" || fail "with BENCH_TIMEOUT=300 an error at 295 s is a timeout (model), not infrastructure: $out"
out=$(python3 "$B/evaluate-model.py" infra/lab)
printf '%s\n' "$out" | grep -q "błędy infrastruktury: 1" || fail "with the default 900 s timeout an error at 295 s is infrastructure: $out"
python3 "$B/evaluate-model.py" > /dev/null 2>&1 && fail "evaluate-model.py without a label must fail"
pass "evaluate-model.py: wrapped empty answers counted; candidate excluded from its own reference"

# ==== bench-or.py — refuses a live driver, parses specs, plans without network ====================
unset ADV
python3 "$B/bench-or.py" --models a/b --plan > "$T/o1.log" 2>&1 && fail "bench-or.py must refuse to run without ADV"
assert_contains "$T/o1.log" "FROZEN copy"
ADV="$ROOT/scripts/adversarial-review.sh" python3 "$B/bench-or.py" --models a/b --plan > "$T/o2.log" 2>&1 \
  && fail "bench-or.py must refuse the live repo driver"
assert_contains "$T/o2.log" "LIVE driver"
printf '#!/usr/bin/env bash\n' > "$T/frozen.sh"
export ADV="$T/frozen.sh"
python3 "$B/bench-or.py" --models a/b --plan > "$T/o0.log" 2>&1 && fail "bench-or.py must refuse to run without the prompt shim"
assert_contains "$T/o0.log" "shim/agy"
printf '#!/usr/bin/env bash\n' > "$BENCH_HOME/shim/agy"; chmod +x "$BENCH_HOME/shim/agy"
python3 "$B/bench-or.py" --models 'no-slash' --plan > /dev/null 2>&1 && fail "a model id without vendor/ must be rejected"
python3 "$B/bench-or.py" --models a/b a/b --plan > /dev/null 2>&1 && fail "duplicate labels must be rejected"
python3 "$B/bench-or.py" --models '../../x=a/b' --plan > /dev/null 2>&1 && fail "a label that escapes or/raw must be rejected"
# done rows: an ok row and a timeout row count as done, an error row does not
printf 'x/y~r2\tok\t%s\t9\tok\tparsed\t1\t30\t1\t1\t0\n' "$P1" > "$BENCH_HOME/or/results.tsv"
printf 'x/y~r2\tfail\t%s\t9\terr:TimeoutError\tunparsed\t0\t899\t0\t0\t0\n' "$P2" >> "$BENCH_HOME/or/results.tsv"
printf 'v/w@low\tok\t%s\t9\terr:HTTPError\tunparsed\t0\t2\t0\t0\t0\n' "$P1" >> "$BENCH_HOME/or/results.tsv"
python3 "$B/bench-or.py" --models 'x/y~r2=x/y' 'v/w@low' --plan > "$T/o3.log" 2>&1 || fail "bench-or.py --plan failed: $(cat "$T/o3.log")"
grep -q "^x/y~r2	x/y	effort=-	to-do=0/2" "$T/o3.log" || fail "ok + timeout rows must both count as done: $(cat "$T/o3.log")"
grep -q "^v/w@low	v/w	effort=low	to-do=2/2" "$T/o3.log" || fail "an error row must be retried; @effort must be parsed: $(cat "$T/o3.log")"
printf 'm/n\tok\t%s\t9\t\tparsed\t1\t30\t1\t1\t0\n' "$P1" >> "$BENCH_HOME/or/results.tsv"
python3 "$B/bench-or.py" --models m/n --plan > "$T/o4.log" 2>&1
grep -q "^m/n	m/n	effort=-	to-do=2/2" "$T/o4.log" || fail "a malformed row (empty status) must not count as done: $(cat "$T/o4.log")"
cp "$BENCH_HOME/sel.json" "$T/sel.bak"
printf '{"ok":[{"diff":"%s"}],"fail":[{"diff":"%s"}]}\n' "$BENCH_HOME/judge2/$P1/CODE.diff" "$BENCH_HOME/judge2/$P2/CODE.diff" > "$BENCH_HOME/sel.json"
python3 "$B/bench-or.py" --models 'x/y~r2=x/y' --plan > "$T/o5.log" 2>&1
grep -q "^x/y~r2	x/y	effort=-	to-do=0/2" "$T/o5.log" || fail "judge2/<id>/CODE.diff paths must map to packet ids, not 'CODE': $(cat "$T/o5.log")"
cp "$T/sel.bak" "$BENCH_HOME/sel.json"
pass "bench-or.py: frozen driver enforced, specs parsed, timeout is a result, errors are retried"

# ==== run-lane.sh — guards, a run on a stub driver, resume =========================================
( unset ADV; bash "$B/run-lane.sh" lab2 codex-5.3 > "$T/r0.log" 2>&1 ) && fail "run-lane.sh must refuse a missing ADV"
ADV="$ROOT/scripts/adversarial-review.sh" bash "$B/run-lane.sh" lab2 codex-5.3 > "$T/r1.log" 2>&1 && fail "run-lane.sh must refuse the live driver"
assert_contains "$T/r1.log" "LIVE driver"
bash "$B/run-lane.sh" 'a/b' codex-5.3 > /dev/null 2>&1 && fail "a label with '/' must be refused"
bash "$B/run-lane.sh" lab2 codex-5.3 notenv > /dev/null 2>&1 && fail "extra args must be ENV=value"
cat > "$T/frozen.sh" <<'DRV'
#!/usr/bin/env bash
art=""; prov=""
while [ $# -gt 0 ]; do case "$1" in --artifact) art="$2"; shift 2 ;; --provider) prov="$2"; shift 2 ;; *) shift ;; esac; done
cat > /dev/null
echo "SEVERITY: WARNING model=${ZUVO_CODEX_EFFORT_PRIMARY:-unset}"
printf 'provider_outcomes=other:fail,%s:ok\ntotal_findings=3\n' "$prov" > "$art"
DRV
chmod +x "$T/frozen.sh"
bash "$B/run-lane.sh" lab2 codex-5.3 ZUVO_CODEX_EFFORT_PRIMARY=none > "$T/r2.log" 2>&1 || fail "run-lane.sh failed: $(cat "$T/r2.log")"
R="$BENCH_HOME/subs/results-lab2.tsv"
grep -q "^lab2	ok	$P1	ok	3	" "$R" || fail "status must be THIS provider's outcome, not the first one: $(cat "$R")"
assert_contains "$BENCH_HOME/subs/lab2-$P1.out" "model=none"
assert_contains "$T/r2.log" "LANE_DONE lab2"
bash "$B/run-lane.sh" lab2 codex-5.3 > /dev/null 2>&1
assert_equals 3 "$(wc -l < "$R" | tr -d ' ')" "a resumed run must skip packets that already have output"
printf 'lab2\tfail\t%s\tnone\t0\t5\n' "$P2" >> "$R"
bash "$B/run-lane.sh" lab2 codex-5.3 > "$T/r3.log" 2>&1
assert_contains "$T/r3.log" "lab2 $P2 ok"
! grep -q "lab2 $P1" "$T/r3.log" || fail "a packet with a real result must not be re-run"
pass "run-lane.sh: a packet whose last status is 'none' (no provider outcome) is re-run"
mkdir "$BENCH_HOME/subs/.lock-lab2"; echo $$ > "$BENCH_HOME/subs/.lock-lab2/pid"
rc=0; bash "$B/run-lane.sh" lab2 codex-5.3 > /dev/null 2>&1 || rc=$?
rm -f "$BENCH_HOME/subs/.lock-lab2/pid"; rmdir "$BENCH_HOME/subs/.lock-lab2"
assert_equals 3 "$rc" "a second runner on the same label must refuse while the first is alive"
pass "run-lane.sh: one runner per label"
pass "run-lane.sh: guards, env passed to the driver, per-provider status, resume"

# ==== bench-model.sh — usage =======================================================================
bash "$B/bench-model.sh" nope > /dev/null 2>&1 && fail "bench-model.sh with an unknown lane must fail"
pass "bench-model.sh: unknown lane rejected"
