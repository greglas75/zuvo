#!/usr/bin/env bash
#
# test-adversarial-agreement.sh — lane agreement in scripts/adversarial-review.sh
# (scripts/lib/adversarial-agreement.sh, plan docs/specs/2026-10-11-review-learning-loop-plan.md Task 7).
#
# Findings several lanes raised on the same lines of the same file predict a real defect better than any one
# lane's severity. The driver groups them: the file normalised (`./a.py` is `a.py`, `:line` split off), lines
# chained within ±ZUVO_ADV_AGREE_WINDOW (default 5, single linkage), each lane counted once per group, a
# finding with no file or no line never merged. The groups are an additive top-level `agreement` key of the
# --json document; a text review prints a short block on STDERR after the VERDICTS hint, so its stdout stays
# byte-identical. The blind-audit document never gains the key.
#
# Hermetic: every driver run is `env -i`, temp HOME/ZUVO_HOME/TMPDIR/ledger, the test's own mock lanes, and a
# PATH whose first entry holds python3/python stubs that fail (exit 127) — the driver needs jq only.
#
# Run: TF_ALLOW_LOCAL=1 bash tests/hooks/test-adversarial-agreement.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd -P)"
AR="${ZUVO_TEST_AR:-$ROOT/scripts/adversarial-review.sh}"
REPO_MOCKS="$ROOT/tests/adversarial/mocks"
PASS=0; FAIL=0
ok()  { echo "  PASS $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
cut300() { if [ "${#1}" -gt 300 ]; then printf '%s…' "${1:0:300}"; else printf '%s' "$1"; fi; }
expect_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2], got [$(cut300 "$3")]"; fi; }
expect_has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 — [$2] not found in [$(cut300 "$3")]" ;; esac; }
expect_not() { case "$3" in *"$2"*) bad "$1 — [$2] found in [$(cut300 "$3")]" ;; *) ok "$1" ;; esac; }
# die <what> — a broken premise (a driver copy, a copied library): every later run would test a broken copy.
die() { bad "$1 — stopping: later cases would run a broken copy"; echo; echo "RESULT: $PASS passed, $FAIL failed"; exit 1; }

echo "== adversarial lane agreement (test bash $BASH_VERSION) =="
[ -f "$AR" ] || { echo "  FAIL driver not found: $AR"; exit 1; }
T_RAW="$(mktemp -d)" || { echo "  FAIL mktemp -d failed"; exit 1; }
if [ -n "${KEEP_T:-}" ]; then echo "  note: sandbox kept: $T_RAW"; else trap 'rm -rf "$T_RAW"' EXIT; fi
T="$(cd "$T_RAW" && pwd -P)" && [ -n "$T" ] || { echo "  FAIL cannot resolve the sandbox path"; exit 1; }

# shellcheck source=tests/lib/hermetic-tools.sh
. "$ROOT/tests/lib/hermetic-tools.sh"
# shellcheck source=tests/lib/adversarial-driver.sh
. "$ROOT/tests/lib/adversarial-driver.sh"
SHIM="$T/shim"; PYOFF="$T/pyoff"; MOCKS="$T/mocks"; WORK="$T/work"
mkdir -p "$SHIM" "$PYOFF" "$MOCKS" "$WORK" "$T/tmp"
hermetic_link_tools "$SHIM" timeout:gtimeout gtimeout:timeout jq
[ -e "$SHIM/timeout" ] || { echo "  FAIL no GNU timeout on this machine — the driver cannot run"; exit 1; }
[ -e "$SHIM/jq" ] || { echo "  FAIL no jq on this machine — the driver cannot run"; exit 1; }
# python3 "off PATH": /usr/bin holds one on macOS, so the first PATH entry shadows it with a stub that logs and fails.
for _py in python3 python; do printf '#!/bin/sh\nexit 127\n' > "$PYOFF/$_py"; chmod +x "$PYOFF/$_py"; done
RUN_PATH="$PYOFF:$MOCKS:$REPO_MOCKS:$SHIM:/usr/bin:/bin"

# mock_json <name> <findings JSON array> — a lane answering one JSON review.
mock_json() {
  { printf '#!/bin/sh\ncat >/dev/null\n'; printf "cat <<'JSON'\n{\"findings\":%s}\nJSON\n" "$2"; } > "$MOCKS/$1"
  chmod +x "$MOCKS/$1"
}
f() { printf '{"id":"%s","severity":"%s","confidence":"high","file":"%s","issue":"x","fix":"y","disposition":"new"}' "$1" "$2" "$3"; }

# Lane a: the auth.ts cluster twice (counted once), z/x/y line pairs, "unknown", other.ts, a lone WARNING.
# Lane b: `./auth.ts` in the cluster, the pairs' far ends, "unknown", auth.ts with NO line. Lane c: edges, a lone INFO.
mock_json mock-agree-a "[$(f a-auth-10 CRITICAL auth.ts:10),$(f a-auth-13 info auth.ts:13),$(f a-z-1 INFO z.ts:1),$(f a-x-100 WARNING x.ts:100),$(f a-y-200 INFO y.ts:200),$(f a-unk WARNING unknown),$(f a-other-12 INFO other.ts:12),$(f a-lone WARNING lone.ts:3)]"
mock_json mock-agree-b "[$(f b-auth-12 WARNING ./auth.ts:12),$(f b-z-5 INFO z.ts:5),$(f b-x-106 INFO x.ts:106),$(f b-y-205 INFO y.ts:205),$(f b-unk WARNING unknown),$(f b-noline CRITICAL auth.ts)]"
mock_json mock-agree-c "[$(f c-auth-15 INFO auth.ts:15),$(f c-z-9 INFO z.ts:9),$(f c-solo INFO solo.ts:4)]"
# A lane answering the TEXT format (findings_text_rows' path), on auth.ts:11 — inside lane a's cluster.
printf '#!/bin/sh\ncat >/dev/null\nprintf "%%s\\n" "SEVERITY: WARNING" "CONFIDENCE: high" "FILE: auth.ts:11" "ID: auth.ts:11:text-lane" "ISSUE: x"\n' > "$MOCKS/mock-agree-t"
chmod +x "$MOCKS/mock-agree-t"

DIFF="$T/in.diff"
printf 'diff --git a/auth.ts b/auth.ts\n--- a/auth.ts\n+++ b/auth.ts\n@@ -10,3 +10,3 @@\n-const a = 1\n+const a = 2\n' > "$DIFF"

# drive <tag> <lanes> [VAR=value ...] -- <driver args...> — one run from $WORK under `env -i`, stdin = $DIFF
# (DRIVE_IN overrides it); stdout/stderr in $T/<tag>.out/.err; status = the driver's.
drive() {
  local tag="$1" lanes="$2" h="$T/home-$1" rc=0 envs=(); shift 2
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  mkdir -p "$h/.zuvo"
  ( cd "$WORK" && env -i HOME="$h" ZUVO_HOME="$h/.zuvo" TMPDIR="$T/tmp" LANG=C PATH="$RUN_PATH" \
      GIT_CEILING_DIRECTORIES="$T" ZUVO_NO_CAFFEINATE=1 ZUVO_PROVIDER_BENCH=0 ZUVO_ADVERSARIAL_TEST_HARNESS=1 \
      ZUVO_CODEX_BIN=/nonexistent ZUVO_CODEX_APP_BIN=/nonexistent ZUVO_REVIEW_TEST_PROVIDERS="$lanes" \
      ZUVO_FINDINGS_LOG_FILE="$T/ledger-$tag.log" ZUVO_ADVERSARIAL_LOG_FILE="$T/adv-$tag.log" \
      ${envs[@]+"${envs[@]}"} bash "${DRIVE_AR:-$AR}" "$@" ) < "${DRIVE_IN:-$DIFF}" > "$T/$tag.out" 2> "$T/$tag.err" || rc=$?
  return "$rc"
}
out() { cat "$T/$1.out" 2>/dev/null; }
err() { cat "$T/$1.err" 2>/dev/null; }
# group <tag> <jq filter selecting one group> <jq expression over it> — e.g. group j1 '.file == "auth.ts"' '.n_lanes'
group() { jq -c "[.agreement[] | select($2)] | if length == 1 then .[0] | $3 else \"groups:\\(length)\" end" "$T/$1.out" 2>&1; }

echo "-- 1. --json: grouping"
rc=0; drive j1 "mock-agree-a mock-agree-b mock-agree-c" -- --mode code --json || rc=$?
expect_eq "J1 a three-lane --json review exits 0" "0" "$rc"
expect_eq "J1 …stdout is ONE JSON document with an agreement array" "1|array" "$(jq -sr '"\(length)|\(.[0].agreement | type)"' "$T/j1.out" 2>&1)"
# The cluster: a@10, a@13, b@./auth.ts:12, c@15 — all within 5 of a neighbour.
expect_eq "J1 3 lanes within ±5 lines of auth.ts → ONE group of 3 lanes (lane a's two findings count once)" \
  '{"file":"auth.ts","line_lo":10,"line_hi":15,"n_lanes":3,"lanes":["mock-agree-a","mock-agree-b","mock-agree-c"],"ids":["a-auth-10","a-auth-13","b-auth-12","c-auth-15"],"max_severity":"CRITICAL"}' \
  "$(group j1 '.file == "auth.ts" and .line_lo != null' '.')"
expect_eq "J1 ./auth.ts is auth.ts: no group is keyed ./auth.ts" "0" "$(jq '[.agreement[] | select(.file | startswith("./"))] | length' "$T/j1.out" 2>&1)"
expect_eq "J1 single linkage: z.ts 1, 5, 9 chain into one group (1 and 9 are 8 apart)" "3|1|9" \
  "$(group j1 '.file == "z.ts"' '"\(.n_lanes)|\(.line_lo)|\(.line_hi)"' | tr -d '"')"
expect_eq "J1 lines 6 apart (x.ts 100/106) stay two groups" "2" "$(jq '[.agreement[] | select(.file == "x.ts")] | length' "$T/j1.out" 2>&1)"
expect_eq "J1 lines exactly 5 apart (y.ts 200/205) are one group of 2 lanes" "2|200|205" \
  "$(group j1 '.file == "y.ts"' '"\(.n_lanes)|\(.line_lo)|\(.line_hi)"' | tr -d '"')"
expect_eq "J1 another file at the same line (other.ts:12) is its own group" "1|mock-agree-a" \
  "$(group j1 '.file == "other.ts"' '"\(.n_lanes)|\(.lanes | join(","))"' | tr -d '"')"
expect_eq "J1 two lanes' \"unknown\" findings never merge: two groups of one lane" "1,1" \
  "$(jq -r '[.agreement[] | select(.file == "unknown") | .n_lanes] | map(tostring) | join(",")' "$T/j1.out" 2>&1)"
expect_eq "J1 auth.ts with no line never joins the auth.ts cluster: its own group, no line" "1|null|b-noline" \
  "$(group j1 '.file == "auth.ts" and .line_lo == null' '"\(.n_lanes)|\(.line_lo)|\(.ids | join(","))"' | tr -d '"')"
expect_eq "J1 every finding of every lane is in exactly one group (8 + 6 + 3 ids)" "17" \
  "$(jq '[.agreement[].ids[]] | length' "$T/j1.out" 2>&1)"
expect_eq "J1 sorted by n_lanes, then severity: 3,3,2,1(CRITICAL),1(WARNING)×4,1(INFO)×3" \
  "3:CRITICAL 3:INFO 2:INFO 1:CRITICAL 1:WARNING 1:WARNING 1:WARNING 1:WARNING 1:INFO 1:INFO 1:INFO" \
  "$(jq -r '[.agreement[] | "\(.n_lanes):\(.max_severity)"] | join(" ")' "$T/j1.out" 2>&1)"
expect_eq "J1 max_severity is the group's highest, whatever its case (a-auth-13 says \"info\")" "CRITICAL" \
  "$(group j1 '.file == "auth.ts" and .line_lo != null' '.max_severity' | tr -d '"')"
expect_eq "J1 the pinned keys are still there, results untouched" "mock-agree-a mock-agree-b mock-agree-c|8" \
  "$(jq -r '"\(.results | keys | join(" "))|\(.results["mock-agree-a"].findings | length)"' "$T/j1.out" 2>&1)"
expect_eq "J1 agreement is the document's LAST key (additive)" "agreement" "$(jq -r 'keys_unsorted | last' "$T/j1.out" 2>&1)"
expect_not "J1 a --json run prints no AGREEMENT block on stderr (the document carries it)" "AGREEMENT:" "$(err j1)"

echo "-- 2. the window, a text-format lane, a lane with no findings"
rc=0; drive j2 "mock-agree-a mock-agree-b" ZUVO_ADV_AGREE_WINDOW=6 -- --mode code --json || rc=$?
expect_eq "J2 exits 0" "0" "$rc"
expect_eq "J2 ZUVO_ADV_AGREE_WINDOW=6 joins x.ts 100/106" "2|100|106" \
  "$(group j2 '.file == "x.ts"' '"\(.n_lanes)|\(.line_lo)|\(.line_hi)"' | tr -d '"')"
rc=0; drive j3 "mock-agree-a mock-agree-t mock-findings-prose" -- --mode code --json || rc=$?
expect_eq "J3 exits 0" "0" "$rc"
expect_eq "J3 a lane answering the TEXT format joins the JSON lane's cluster (auth.ts 10-13)" \
  "2|10|13|mock-agree-a,mock-agree-t|auth.ts:11:text-lane" \
  "$(group j3 '.file == "auth.ts" and .line_lo != null' '"\(.n_lanes)|\(.line_lo)|\(.line_hi)|\(.lanes | join(","))|\(.ids[-1])"' | tr -d '"')"
expect_eq "J3 a prose-only lane adds no group and breaks none (7 groups: lane a's 8 findings, its auth.ts pair one)" "7" \
  "$(jq '.agreement | length' "$T/j3.out" 2>&1)"

echo "-- 3. text mode: stdout byte-identical, the block on stderr after VERDICTS"
# The text-format lane (mock-agree-t) is what records a ledger ID in text mode, so the VERDICTS hint is drawn.
# The same review through two copies of the driver laid out alike: one with the real agreement module, one whose
# agreement functions do nothing. Their stdout must match byte for byte (bar the Date line).
adv_driver_copy "$AR" "$T/real/adversarial-review.sh" lib >/dev/null 2>&1 || die "premise: adv_driver_copy (real) failed"
adv_driver_copy "$AR" "$T/stub/adversarial-review.sh" lib >/dev/null 2>&1 || die "premise: adv_driver_copy (stub) failed"
# The shared runner too: without it the driver discards every short answer as unverifiable.
cp "$ROOT/scripts/lib/model-subprocess.sh" "$T/real/lib/" && cp "$ROOT/scripts/lib/model-subprocess.sh" "$T/stub/lib/" \
  || die "premise: model-subprocess.sh could not be copied beside the drivers"
printf '# shellcheck shell=bash\n_ar_agreement_json() { printf "[]" > "$2"; }\n_ar_print_agreement() { :; }\n' \
  > "$T/stub/lib/adversarial-agreement.sh"
rc=0; DRIVE_AR="$T/real/adversarial-review.sh" drive t1 "mock-agree-a mock-agree-b mock-agree-c mock-agree-t" -- --mode code || rc=$?
expect_eq "T1 a text review exits 0" "0" "$rc"
rc=0; DRIVE_AR="$T/stub/adversarial-review.sh" drive t0 "mock-agree-a mock-agree-b mock-agree-c mock-agree-t" -- --mode code || rc=$?
expect_eq "T0 …and with the agreement module stubbed out" "0" "$rc"
expect_has "T1 premise: stdout is the review (ends with its banner)" "END OF CROSS-PROVIDER REVIEW" "$(out t1)"
if [ -s "$T/t1.out" ] && cmp -s <(grep -v '^Date: ' "$T/t1.out") <(grep -v '^Date: ' "$T/t0.out"); then
  ok "T1 text stdout is byte-identical to the run without agreement (Date line aside)"
else
  bad "T1 text stdout differs from the run without agreement: $(cut300 "$(diff <(grep -v '^Date: ' "$T/t0.out") <(grep -v '^Date: ' "$T/t1.out") 2>&1)")"
fi
expect_not "T1 …and holds no AGREEMENT block" "AGREEMENT" "$(out t1)"
_e="$(err t1)"
expect_has "T1 stderr: the AGREEMENT block names the 4-lane cluster" "4 lanes  CRITICAL  auth.ts:10-15" "$_e"
expect_has "T1 …and the 2-lane pair" "2 lanes  INFO  y.ts:200-205" "$_e"
expect_not "T1 …and lists no single-lane location" "other.ts" "$_e"
v_line="$(printf '%s\n' "$_e" | awk '/^VERDICTS:/ { print NR; exit }')"
a_line="$(printf '%s\n' "$_e" | awk '/^AGREEMENT:/ { print NR; exit }')"
if [ -n "$v_line" ] && [ -n "$a_line" ] && [ "$a_line" -gt "$v_line" ]; then ok "T1 the block comes after the VERDICTS hint ($v_line < $a_line)"
else bad "T1 the block is not after the VERDICTS hint (VERDICTS line ${v_line:-none}, AGREEMENT line ${a_line:-none})"; fi
rc=0; drive t2 "mock-agree-c mock-findings-c" -- --mode code || rc=$?
expect_eq "T2 a text review where no two lanes agree exits 0" "0" "$rc"
expect_not "T2 …and prints no AGREEMENT block" "AGREEMENT" "$(err t2)"

echo "-- 4. a failing jq never fails the review"
# The driver runs under errexit + pipefail: an agreement step that failed unguarded would end the run with no
# output. The module, sourced alone with the driver's helpers stubbed and a jq that always fails.
BADJQ="$T/badjq"; mkdir -p "$BADJQ" "$T/e1"
printf '#!/bin/sh\nexit 5\n' > "$BADJQ/jq"; chmod +x "$BADJQ/jq"
printf '{"findings":[]}' > "$T/e1/result_lane-x.txt"
rc=0; e1_out="$(env -i PATH="$BADJQ:/usr/bin:/bin" LANG=C bash -c 'set -euo pipefail
  . "$1"; PROVIDERS="lane-x"; JSON_TMPDIR="$2"
  lane_ok() { return 0; }; result_json_text() { cat "$1"; }; findings_text_rows() { :; }; ar_env_int() { printf 5; }
  _ar_agreement_json "" "$2/agreement.json"; _ar_print_agreement "$2/agreement.json"; echo reached-end' \
  _ "$ROOT/scripts/lib/adversarial-agreement.sh" "$T/e1" 2> "$T/e1.err")" || rc=$?
expect_eq "E1 a failing jq: the caller carries on (status 0, the next statement runs)" "0|reached-end" "$rc|$e1_out"
expect_eq "E1 …the agreement file says null, not an empty agreement" "null" "$(cat "$T/e1/agreement.json" 2>/dev/null)"
expect_has "E1 …and stderr says it could not be computed" "lane agreement could not be computed" "$(cat "$T/e1.err")"

echo "-- 5. review fixes: path split, empty, bad rows, missing file, empty JSON, placeholders, control chars"
# unit <stdin file> <shell snippet> — the module sourced alone under errexit + pipefail, real jq, the driver's
# helpers stubbed; prints what the snippet prints.
unit() {
  env -i PATH="$SHIM:/usr/bin:/bin" LANG=C TMPDIR="$T/tmp" FTR_ROWS="${FTR_ROWS:-}" bash -c 'set -euo pipefail
    . "$1"; lane_ok() { return 0; }; ar_env_int() { printf 5; }
    result_json_text() { cat "$1"; }; findings_text_rows() { printf "%b" "${FTR_ROWS:-}"; }
    eval "$2"' _ "$ROOT/scripts/lib/adversarial-agreement.sh" "$2" < "$1" 2>&1
}
# Bug: a path holding a colon, or a line range with an en dash, split at the wrong colon or not at all — the
# same location never grouped (the ledger's split_file takes only the LAST :<line>[-<line>]).
mock_json mock-split-p "[$(f p1 WARNING a:b.ts:12),$(f p2 INFO 'ab.ts:12–14')]"
mock_json mock-split-q "[$(f q1 WARNING a:b.ts:13),$(f q2 INFO ab.ts:13)]"
mock_json mock-split-r "[$(f r1 INFO a:b.ts:14)]"
rc=0; drive s1 "mock-split-p mock-split-q mock-split-r" -- --mode code --json || rc=$?
expect_eq "S1 exits 0" "0" "$rc"
expect_eq "S1 a path with a colon (a:b.ts:12/13/14) is one 3-lane group of file a:b.ts" "3|12|14" \
  "$(group s1 '.file == "a:b.ts"' '"\(.n_lanes)|\(.line_lo)|\(.line_hi)"' | tr -d '"')"
expect_eq "S1 an en-dash range (ab.ts:12–14) is located at 12 and joins ab.ts:13" "2|12|13" \
  "$(group s1 '.file == "ab.ts"' '"\(.n_lanes)|\(.line_lo)|\(.line_hi)"' | tr -d '"')"
# Bug: no finding in any lane read as "agreement could not be computed" (null + WARN) instead of none.
mock_json mock-empty-1 "[]"; mock_json mock-empty-2 "[]"
rc=0; drive s2 "mock-empty-1 mock-empty-2" -- --mode code --json || rc=$?
expect_eq "S2 zero findings in every lane: exit 0, agreement is [] (not null)" "0|[]" "$rc|$(jq -c .agreement "$T/s2.out" 2>&1)"
expect_not "S2 …and no could-not-compute WARN" "could not be computed" "$(err s2)"
# Bug: one row with a null file or a non-string severity aborted the whole jq — agreement null for every lane.
printf '%s\n' '{"lane":"a","file":null,"severity":null,"id":null}' '{"lane":"b","file":"q.ts:3","severity":"INFO","id":"x"}' \
  '{"lane":"c","file":"q.ts:4","severity":7,"id":"y"}' '{"file":5}' > "$T/u3.in"
expect_eq "S3 bad rows become unlocated singletons; the q.ts pair still groups (3 groups, q.ts 2 lanes INFO)" "3|2|INFO" \
  "$(unit "$T/u3.in" '_ar_agreement_group 5 | jq -r "\"\(length)|\(.[0].n_lanes)|\(.[0].max_severity)\""')"
printf 'prose only\n' > "$T/u3b.in"
expect_eq "S3 a text-fallback row with missing columns: one unlocated group, no abort" "1|null" \
  "$(FTR_ROWS='d\tr\tm\tp\tmo\tid-only' unit "$T/u3b.in" 'f="$(mktemp)"; cat > "$f"; _ar_agreement_findings L "$f" | _ar_agreement_group 5 | jq -r "\"\(length)|\(.[0].line_lo)\""')"
# Bug: an unwritten, blocked or garbage agreement file made the --json document fail (--slurpfile).
for _k in missing dir garbage; do
  adv_driver_copy "$AR" "$T/af-$_k/adversarial-review.sh" lib >/dev/null 2>&1 || die "premise: adv_driver_copy ($_k) failed"
  cp "$ROOT/scripts/lib/model-subprocess.sh" "$T/af-$_k/lib/" || die "premise: model-subprocess.sh not copied ($_k)"
done
printf '\n_ar_agreement_json() { :; }\n' >> "$T/af-missing/lib/adversarial-agreement.sh"
printf '\n_ar_agreement_json() { mkdir -p "$2"; }\n' >> "$T/af-dir/lib/adversarial-agreement.sh"
printf '\n_ar_agreement_json() { printf "not json" > "$2"; }\n' >> "$T/af-garbage/lib/adversarial-agreement.sh"
for _k in missing dir garbage; do
  rc=0; DRIVE_AR="$T/af-$_k/adversarial-review.sh" drive "af-$_k" "mock-agree-a mock-agree-b" -- --mode code --json || rc=$?
  expect_eq "S4 agreement file $_k: exit 0, one valid document, agreement null, both lanes' results kept" "0|true" \
    "$rc|$(jq -s 'length == 1 and .[0].agreement == null and (.[0].results | length) == 2' "$T/af-$_k.out" 2>&1)"
done
# Bug: a JSON answer with an EMPTY findings array fell through to text parsing and picked up prose SEVERITY lines.
printf '#!/bin/sh\ncat >/dev/null\nprintf "%%s\\n" "Notes: SEVERITY: WARNING" "SEVERITY: WARNING" "FILE: q.ts:3" "ID: q.ts:3:prose-only" "" "\\`\\`\\`json" "{\\"findings\\":[]}" "\\`\\`\\`"\n' > "$MOCKS/mock-mixed"
chmod +x "$MOCKS/mock-mixed"
mock_json mock-q3 "[$(f q3 INFO q.ts:3)]"
rc=0; drive s5 "mock-mixed mock-q3" -- --mode code --json || rc=$?
expect_eq "S5 premise: the mixed lane's answer is the empty JSON review" "0|0" "$rc|$(jq '.results["mock-mixed"].findings | length' "$T/s5.out" 2>&1)"
expect_eq "S5 an empty JSON findings array is not re-read as text: q.ts:3 is one lane" "1|mock-q3" \
  "$(group s5 '.file == "q.ts"' '"\(.n_lanes)|\(.lanes | join(","))"' | tr -d '"')"
# Bug: placeholder paths with a line (n/a:12) or a bare :12 grouped as if they were a location.
printf '%s\n' '{"lane":"a","file":"n/a:12","severity":"INFO","id":"1"}' '{"lane":"b","file":"n/a:12","severity":"INFO","id":"2"}' \
  '{"lane":"a","file":":12","severity":"INFO","id":"3"}' '{"lane":"b","file":":12","severity":"INFO","id":"4"}' \
  '{"lane":"c","file":"none:12","severity":"INFO","id":"5"}' > "$T/u6.in"
expect_eq "S6 a numeric line with no real path stays unlocated: 5 singletons, none with a line" "5|0" \
  "$(unit "$T/u6.in" '_ar_agreement_group 5 | jq -r "\"\(length)|\([.[] | select(.line_lo != null)] | length)\""')"
# Bug: a lane-controlled file name carrying terminal escapes was printed raw to the user's terminal.
mock_json mock-evil-1 "[$(f e1 WARNING 'ev\u001b[2Jil.ts:5')]"
mock_json mock-evil-2 "[$(f e2 WARNING 'ev\u001b[2Jil.ts:6')]"
rc=0; drive s7 "mock-evil-1 mock-evil-2" -- --mode code || rc=$?
expect_has "S7 the agreement block names the location with its control characters stripped" "2 lanes  WARNING  ev[2Jil.ts:5-6" "$(err s7)"
expect_eq "S7 …and stderr carries no ESC byte" "0" "$(LC_ALL=C tr -cd '\033' < "$T/s7.err" | wc -c | tr -d ' ')"

# Bug: two lanes whose files are unlocatable in DIFFERENT ways (bad line, no line, bare colon, blank, placeholder
# in any case, placeholder with a line) merged into one "agreement" group.
: > "$T/u8.in"
for _l in a b; do
  for _fv in 'a.ts:abc' 'a.ts' ':' '  ' 'UNKNOWN' 'None:3'; do
    printf '{"lane":"%s","file":"%s","severity":"WARNING","id":"%s-%s"}\n' "$_l" "$_fv" "$_l" "$_fv" >> "$T/u8.in"
  done
done
expect_eq "S8 twelve unlocatable findings from two lanes: twelve singletons, none with a line" "12|1|0" \
  "$(unit "$T/u8.in" '_ar_agreement_group 5 | jq -r "\"\(length)|\([.[].n_lanes] | max)|\([.[] | select(.line_lo != null)] | length)\""')"

echo "-- 6. blind audit, python"
SRC="$T/src"; mkdir -p "$SRC"
printf '#!/bin/sh\nsum() { echo $(($1 + $2)); }\n' > "$SRC/sum.sh"
printf '#!/bin/sh\n. ./sum.sh\n[ "$(sum 1 2)" = 3 ] || exit 1\n' > "$SRC/sum.test.sh"
rc=0; DRIVE_IN=/dev/null drive b1 "mock-strict-clean mock-strict-fix" -- --mode blind-audit --production "$SRC/sum.sh" --test "$SRC/sum.test.sh" --json || rc=$?
expect_eq "B1 premise: a blind audit of two valid lanes exits 0" "0" "$rc$( [ "$rc" = 0 ] || printf ' %s' "$(err b1 | tail -3)")"
expect_eq "B1 the blind-audit document keeps exactly its keys (no agreement)" \
  "excluded_argv_lanes merged_block mode prompt_bytes provider_outcomes results status valid_providers verdict" \
  "$(jq -r 'keys | join(" ")' "$T/b1.out" 2>&1)"
# Every run above went through this PATH, so each assertion on .agreement held with no working python.
expect_eq "P1 premise: python3 on the runs' PATH is the failing stub" "$PYOFF/python3|127" \
  "$(PATH="$RUN_PATH" command -v python3)|$(PATH="$RUN_PATH" python3 -c 'print(1)' >/dev/null 2>&1; echo $?)"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
