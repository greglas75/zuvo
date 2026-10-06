# test-input-chunking.sh — auto-chunking of oversized input (adversarial-review.sh).
#
# The regression under contract: 32% of all logged runs hit MAX_CHARS=30000 and,
# before the WARN landed, the overflow was truncated SILENTLY — a 543KB range
# dropped the file holding five CRITICALs. The fix: input over the cap is split
# at FILE boundaries and the script re-invokes itself per chunk (ZUVO_ADV_CHUNK
# recursion guard), so EVERY file is reviewed at full fidelity. mock-echo-files
# reports exactly which files reached the provider — visibility is the property
# silent truncation destroyed.
# Sourced by run.sh.

ADV="$ROOT/scripts/adversarial-review.sh"
MOCKS="$HERE/mocks"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$MOCKS:$PATH"
export ZUVO_HOME="$ADV_TEST_HOME/zuvo-home"
mkdir -p "$ZUVO_HOME"

CK_TMP="$ADV_TEST_HOME/chunking"
rm -rf "$CK_TMP"; mkdir -p "$CK_TMP/src"

# Synthetic --files corpus: 5 files x ~10700 chars = ~53.7k > 30000 cap. Unique
# marker per file so provider visibility is attributable. Two whole files fit under
# the cap, so the split is exactly 3 chunks (2 + 2 + 1 files).
FILE_LIST=""
for i in 1 2 3 4 5; do
  f="$CK_TMP/src/module-$i.ts"
  { printf '// MARKER-FILE-%d\n' "$i"
    j=1
    while [ "$j" -le 120 ]; do
      printf 'export function fn_%d_%d(a: number): number { return a * %d + %d; } // pad pad pad pad pad\n' "$i" "$j" "$i" "$j"
      j=$((j + 1))
    done
  } > "$f"
  FILE_LIST="${FILE_LIST}${f}"$'\n'
done

# ─── 1: oversized input is chunked, never truncated ───────────────────────────

start_test "CK.1 over-cap --files input chunks at file boundaries, no truncation"
ck1_out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --files "$FILE_LIST" 2>"$CK_TMP/err1"); rc=$?
assert_eq "0" "$rc" "aggregate exit code"
# The output the run printed: each part's review under its own banner, numbered i/N in order (ar_chunk_input,
# adversarial-input.sh) — three parts, each reviewed once.
assert_eq "=== ADVERSARIAL CHUNK 1/3 ===|=== ADVERSARIAL CHUNK 2/3 ===|=== ADVERSARIAL CHUNK 3/3 ===" \
  "$(printf '%s\n' "$ck1_out" | grep '^=== ADVERSARIAL CHUNK ' | tr '\n' '|' | sed 's/|$//')" \
  "stdout carries the three part banners, 1/3 to 3/3, once each and in order"
grep -q 'CHUNKED INPUT:' "$CK_TMP/err1" \
  && pass "CHUNKED INPUT banner printed" || fail "no CHUNKED INPUT banner" "$(head -3 "$CK_TMP/err1")"
grep -q 'WARN: input truncated' "$CK_TMP/err1" \
  && fail "truncation WARN still fired alongside chunking" || pass "no truncation WARN"
# The aggregate line, exactly (ar_chunk_input's CHUNKED: summary): three parts, all reviewed — no other count
# printed.
assert_eq "CHUNKED: 3 chunks — 3 ok, 0 failed. Aggregate exit: 0." "$(grep '^CHUNKED: ' "$CK_TMP/err1")" \
  "the summary counts three reviewed parts and nothing else"

# ─── 2: the silent-drop regression — EVERY file reaches a provider ────────────

start_test "CK.2 all files visible to providers across chunks"
# Its own run: reading CK.1's output tied this case to CK.1 — it could neither run alone nor fail apart.
ck2_out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --files "$FILE_LIST" 2>"$CK_TMP/err2a"); rc=$?
assert_eq "0" "$rc" "the run whose output is read here completed: exit 0"
missing=""
for i in 1 2 3 4 5; do
  printf '%s' "$ck2_out" | grep -q "module-$i.ts" || missing="$missing module-$i.ts"
done
if [[ -z "$missing" ]]; then
  pass "5/5 files seen (the 543KB silent-drop cannot recur)"
else
  fail "files never seen by any provider" "$missing"
fi
n_banners=$(printf '%s' "$ck2_out" | grep -c '^=== ADVERSARIAL CHUNK [0-9]*/[0-9]* ===')
assert_eq "3" "$n_banners" "output carries one banner per chunk: 3 (2 + 2 + 1 files)"
# Which files each part's provider saw, under that part's banner (ar_chunk_input): the split is at whole
# files, in order — a file in two parts, or in none, is the defect this suite exists for.
ck2_seen=$(printf '%s\n' "$ck2_out" | awk '
  /^=== ADVERSARIAL CHUNK [0-9]+\/[0-9]+ ===$/ { split($4, p, "/"); c = p[1]; next }
  /^module-[0-9]+\.ts$/ { seen[c] = seen[c] (seen[c] == "" ? "" : " ") $0 }
  END { for (i = 1; i <= 3; i++) printf "%s%d:%s", (i > 1 ? "|" : ""), i, seen[i] }')
assert_eq "1:module-1.ts module-2.ts|2:module-3.ts module-4.ts|3:module-5.ts" "$ck2_seen" \
  "each part's provider saw exactly its own whole files"

# ─── 3: dry-run prints the plan, dispatches nothing ───────────────────────────

start_test "CK.3 dry-run shows chunk plan without invoking providers"
out2=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --dry-run --files "$FILE_LIST" 2>"$CK_TMP/err2"); rc=$?
assert_eq "0" "$rc" "dry-run exit"
grep -q 'chunk plan' "$CK_TMP/err2" && pass "plan printed" || fail "no chunk plan" "$(head -3 "$CK_TMP/err2")"
printf '%s' "$out2" | grep -q 'SEEN FILES' \
  && fail "dry-run dispatched a provider" || pass "no provider dispatched"

# ─── 4: opt-outs restore the legacy truncate path ──────────────────────────────

start_test "CK.4 --no-chunk falls back to loud truncation"
ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --no-chunk --files "$FILE_LIST" >/dev/null 2>"$CK_TMP/err3"; rc=$?
assert_eq "4" "$rc" "a review over a truncated input exits 4, never 0"
grep -q 'WARN: input truncated' "$CK_TMP/err3" && ! grep -q 'CHUNKED INPUT:' "$CK_TMP/err3" \
  && pass "flag opt-out truncates with WARN" || fail "flag opt-out path" "$(grep -E 'WARN|CHUNKED' "$CK_TMP/err3" | head -2)"

start_test "CK.5 ZUVO_ADV_NO_CHUNK=1 env opt-out"
ZUVO_ADV_NO_CHUNK=1 ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --files "$FILE_LIST" >/dev/null 2>"$CK_TMP/err4"; rc=$?
assert_eq "4" "$rc" "truncated review: exit 4"
grep -q 'WARN: input truncated' "$CK_TMP/err4" && ! grep -q 'CHUNKED INPUT:' "$CK_TMP/err4" \
  && pass "env opt-out truncates with WARN" || fail "env opt-out path" "$(grep -E 'WARN|CHUNKED' "$CK_TMP/err4" | head -2)"

# ─── 5: recursion guard — a child never chunks again ──────────────────────────

start_test "CK.6 ZUVO_ADV_CHUNK set -> child takes the truncate path"
ZUVO_ADV_CHUNK="1/1" ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --files "$FILE_LIST" >/dev/null 2>"$CK_TMP/err5"; rc=$?
assert_eq "4" "$rc" "the child reviews its truncated input: exit 4"
grep -q 'WARN: input truncated' "$CK_TMP/err5" && ! grep -q 'CHUNKED INPUT:' "$CK_TMP/err5" \
  && pass "no infinite recursion possible" || fail "recursion guard" "$(grep -E 'WARN|CHUNKED' "$CK_TMP/err5" | head -2)"

# ─── 6: under-cap input is untouched ──────────────────────────────────────────

start_test "CK.7 small input takes the normal single-pass path"
out6=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --files "$CK_TMP/src/module-1.ts" 2>"$CK_TMP/err6"); rc=$?
assert_eq "0" "$rc" "a whole review: exit 0"
assert_contains "$out6" "module-1.ts" "…of the one file, which reached the provider"
! grep -q 'CHUNKED INPUT:' "$CK_TMP/err6" && ! grep -q 'WARN: input truncated' "$CK_TMP/err6" \
  && pass "no chunking, no truncation" || fail "small input mis-handled" "$(grep -E 'WARN|CHUNKED' "$CK_TMP/err6" | head -2)"

# ─── 7: JSON mode wraps chunk results in ONE object ───────────────────────────

start_test "CK.8 JSON output is {chunked:true, chunks:N, results:[...]}"
out7=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success" bash "$ADV" --single --json --files "$FILE_LIST" 2>/dev/null); rc=$?
assert_eq "0" "$rc" "every chunk reviewed: exit 0"
if printf '%s' "$out7" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('chunked') is True and d.get('chunks')==3 and isinstance(d.get('results'),list) and len(d['results'])==3" 2>/dev/null; then
  pass "wrapper object valid: chunks 3, one result per chunk"
else
  fail "JSON wrapper malformed" "$(printf '%s' "$out7" | head -c 160)"
fi
# Each result is that part's own review document, not just an entry (ar_chunk_input): every part ran its one
# lane, which answered.
assert_eq "ok mock-success:ok mock-success 1|ok mock-success:ok mock-success 1|ok mock-success:ok mock-success 1" \
  "$(printf '%s' "$out7" | jq -r '[.results[] | "\(.status) \(.provider_outcomes) \(.providers_used) \(.provider_count)"] | join("|")' 2>/dev/null)" \
  "each of the 3 results is a completed review by mock-success"

# ─── 8: repeatable --file (field retro 2026-08-02: newline-quoting bit twice) ──

start_test "CK.10 repeatable --file collects multiple paths without quoting ambiguity"
out10=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single \
  --file "$CK_TMP/src/module-1.ts" --file "$CK_TMP/src/module-2.ts" 2>/dev/null); rc=$?
assert_eq "0" "$rc" "two --file paths: a whole review, exit 0"
if printf '%s' "$out10" | grep -q 'module-1.ts' && printf '%s' "$out10" | grep -q 'module-2.ts'; then
  pass "both --file paths reached the provider"
else
  fail "--file paths not both visible" "$(printf '%s' "$out10" | head -c 160)"
fi
ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --file --json >/dev/null 2>&1
assert_eq "2" "$?" "--file with a flag-shaped value exits 2 (no silent swallow)"

# ─── 9: one artifact accumulates every chunk's evidence ───────────────────────

start_test "CK.9 --artifact holds evidence from ALL chunks"
ART="$CK_TMP/proof.txt"
ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --files "$FILE_LIST" --artifact "$ART" >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "every chunk reviewed: exit 0"
if [[ -f "$ART" ]]; then
  seen=0
  for i in 1 2 3 4 5; do grep -q "module-$i.ts" "$ART" && seen=$((seen+1)); done
  assert_eq "5" "$seen" "files evidenced in the single artifact"
else
  fail "artifact file not written"
fi

# ─── 11: DOCUMENT modes chunk at section headings, not truncate ────────────────
#
# Until 2026-08-03 spec/plan/audit/migrate were chunk-EXEMPT, on the reasoning
# that a document is "one artifact, no boundaries to cut at". Measured cost of
# that reasoning in ~/.zuvo/adversarial.log: 264 of 1,601 doc-mode runs hit the
# 50K cap and were silently cut, so ~16% of plan reviews judged ~60% of a plan
# with no way to know which 40% they never saw. These cases pin the fix.

CK_DOC="$CK_TMP/doc"; mkdir -p "$CK_DOC"
# 3 real plan task sections (25k each = 75k > the 50000 doc cap) + 4 DECOY headings
# inside a fenced bash block. A naive `^##+ ` counter sees 7 boundaries; a
# fence-aware one sees 3. Plans are full of fenced bash, so this is the case
# that decides whether the split is usable at all.
{ printf '# Plan Title\n\n### Task 1: Alpha\n'
  awk 'BEGIN{for(i=0;i<25000;i++)printf "a"}'
  printf '\n\n```bash\n## decoy one\n## decoy two\n#### decoy three\n## decoy four\n```\n\n### Task 2: Beta\n'
  awk 'BEGIN{for(i=0;i<25000;i++)printf "b"}'
  printf '\n\n### Task 3: Gamma\n'
  awk 'BEGIN{for(i=0;i<25000;i++)printf "c"}'
  printf '\n'; } > "$CK_DOC/plan.md"

# ck_plan_dry_run <stderr file> — the chunk plan of a dry run over plan.md, its stderr in <stderr file>; status =
# the driver's. CK.12 and CK.13 each make their own, so each runs alone and fails apart from CK.11.
ck_plan_dry_run() { bash "$ADV" --mode plan --dry-run < "$CK_DOC/plan.md" >/dev/null 2>"$1"; }

start_test "CK.11 plan mode chunks at task headings instead of truncating"
ck_plan_dry_run "$CK_DOC/err"; rc=$?
assert_eq "0" "$rc" "the chunk plan of a dry run: exit 0"
grep -q 'CHUNKED INPUT:' "$CK_DOC/err" && ! grep -q 'WARN: input truncated' "$CK_DOC/err" \
  && pass "doc input chunked, not truncated" \
  || fail "doc mode still truncates" "$(grep -E 'CHUNKED|truncated' "$CK_DOC/err" | head -2)"

start_test "CK.12 no content is lost — chunk sizes sum to the input"
ck_plan_dry_run "$CK_DOC/err12"; rc=$?
assert_eq "0" "$rc" "premise: this case's own dry run printed its chunk plan (exit 0)"
# ar_chunk_input's dry-run plan — one "chunk-NNN: <bytes> chars" line per part; three parts, so the sum below
# is over all of them.
assert_eq "3" "$(grep -cE '^  chunk-[0-9]+: [0-9]+ chars, ' "$CK_DOC/err12")" "premise: the plan lists three parts"
doc_size=$(wc -c < "$CK_DOC/plan.md" | tr -d ' ')
sum=$(awk '/chunk-[0-9]+: [0-9]+ chars/ { for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/ && $(i+1) ~ /^chars/) s += $i } END { print s+0 }' "$CK_DOC/err12")
# Exactly the file: the input as read drops the file's final newline, and the splitter writes every
# chunk as whole lines (each ending in one), so the parts add up to the file byte for byte. Fewer bytes
# is content lost; more is content sent twice.
assert_eq "$doc_size" "$sum" "chunk bytes sum to the input exactly (nothing dropped, nothing doubled)"

start_test "CK.13 headings inside code fences are NOT boundaries"
ck_plan_dry_run "$CK_DOC/err13"; rc=$?
assert_eq "0" "$rc" "premise: this case's own dry run printed its chunk plan (exit 0)"
naive=$(awk '/^##+ /{n++} END{print n+0}' "$CK_DOC/plan.md")
chunks=$(grep -c 'chunk-[0-9]*:' "$CK_DOC/err13")
assert_eq "7" "$naive" "decoy corpus really does fool a naive counter"
assert_eq "3" "$chunks" "fence-aware split yields one chunk per REAL section"
# The plan's per-chunk count uses the same fence-aware rule (_ck_count_units): ONE section each — the
# decoy headings inside chunk 1's fence are not sections.
assert_eq "3" "$(grep -cE 'chunk-[0-9]+: [0-9]+ chars, sections: 1$' "$CK_DOC/err13")" "every chunk reports one section (fenced decoys not counted)"

start_test "CK.14 the per-chunk note says 'document', not 'files'"
# Self-contained: it reads only the program text it assembles here, nothing CK.11-CK.13 wrote.
# A plan reviewer told that sibling FILES exist elsewhere reports the document as
# truncated or flags cross-references it cannot see. The note must match reality.
# NB: the verdict must come back through pass/fail — a python `print("PASS")`
# is invisible to the harness and would gate nothing while looking green.
. "$ROOT/tests/lib/adversarial-driver.sh"   # the chunking phase lives in a module: hand python the whole program
if ! adv_driver_source "$ADV" > "$CK_TMP/driver-source.sh"; then
  fail "chunk note wording" "the program text could not be assembled (reason above)"
elif python3 - "$CK_TMP/driver-source.sh" <<'PY'
import re,sys
s=open(sys.argv[1],encoding='utf-8',errors='replace').read()
doc_note = 'of ONE document split at section headings' in s
guarded  = re.search(r'_ck_fence.*-eq 1.*\n(.*\n)*?\s*_ck_note=.*ONE document', s) is not None
sys.exit(0 if (doc_note and guarded) else 1)
PY
then pass "doc-specific chunk note present and gated on doc mode"
else fail "chunk note wording" "expected a doc-mode-gated 'ONE document split at section headings' note"
fi

start_test "CK.15 a small document is left alone"
# A VALID plan under the cap (3 tasks — the plan minimum). A 1-task fragment would exit 5 at the material
# check, which runs before chunking, and "not chunked" would then hold for any chunker.
{ printf '# Small Plan\n\n'
  for t in 1 2 3; do printf '### Task %d: Step\n' "$t"; awk 'BEGIN{for(i=0;i<1000;i++)printf "s"}'; printf '\n\n'; done
} > "$CK_DOC/small.md"
small_out=$(bash "$ADV" --mode plan --dry-run < "$CK_DOC/small.md" 2>"$CK_DOC/err_small"); rc=$?
assert_eq "0" "$rc" "an under-cap plan passes the material check (dry run: exit 0)"
assert_contains "$small_out" "### Task 3: Step" "…and goes whole into the one prompt"
grep -q 'CHUNKED INPUT:' "$CK_DOC/err_small" \
  && fail "under-cap document was chunked" "$(head -2 "$CK_DOC/err_small")" \
  || pass "under-cap document not chunked"

start_test "CK.16 code mode still splits at FILE boundaries (no cross-mode regression)"
bash "$ADV" --single --dry-run --files "$FILE_LIST" >/dev/null 2>"$CK_DOC/err_code"; rc=$?
assert_eq "0" "$rc" "the chunk plan of a dry run: exit 0"
grep -q 'chunks at file boundaries' "$CK_DOC/err_code" \
  && pass "code mode boundary unchanged" \
  || fail "code-mode boundary changed" "$(grep 'CHUNKED INPUT' "$CK_DOC/err_code" | head -1)"

# ─── 12: the AGGREGATE of mixed part outcomes (ar_chunk_input) ────────────────
#
# Every case above has parts that all end the same way. The aggregate is where the parts' exit codes are
# merged, and each rule below was a defect once: a failed part's 2 lost to a cut part's 4 (the run read
# "completed over truncated input" with the failed part's files on no list), a no-material part was
# folded into success, a part never started for want of time was counted as reviewed. One lane decides
# per part from the prompt it is sent: MARKER-FAIL → silent exit 1 (that part's review FAILS, exit 2),
# MARKER-SLOW → answers after 3 s, anything else → answers at once.
mkdir -p "$CK_TMP/bin"
cat > "$CK_TMP/bin/mock-chunkfate" <<'MOCK'
#!/usr/bin/env bash
p="$(cat)"
case "$p" in *MARKER-FAIL*) exit 1 ;; esac
case "$p" in *MARKER-SLOW*) sleep 3 ;; esac
echo '{"findings":[]}'
MOCK
chmod +x "$CK_TMP/bin/mock-chunkfate"
CK_MIX="$CK_TMP/mixed"; mkdir -p "$CK_MIX"
# ck_ts_file <path> <marker> <lines> — a .ts file whose first line carries <marker>; 400 lines ≈ 33.4k
# chars, one section over the 30000 cap by itself (its part is reviewed with its input cut: exit 4).
ck_ts_file() {
  printf '// %s\n' "$2" > "$1"
  awk -v n="$3" 'BEGIN { for (i = 0; i < n; i++) printf "export const v%d = %d; // padding padding padding padding padding padding padding\n", i, i }' >> "$1"
}
# ck_diff_section <name> <lines> — one file of a diff (a chunk boundary), about 64 chars a line.
ck_diff_section() {
  printf 'diff --git a/%s b/%s\n@@ -0,0 +1 @@\n' "$1" "$1"
  awk -v n="$2" 'BEGIN { for (i = 0; i < n; i++) printf "+line %d padding padding padding padding padding padding padding\n", i }'
}
# ck_prose — ~21.5k chars of prose with no diff header, hunk or `=== FILE:` line: the preamble (sec-0000),
# packed alone into part 1 — a part with no material (child exits 5) while the whole input still holds diffs.
ck_prose() { awk 'BEGIN { for (i = 0; i < 300; i++) printf "Release notes line %d of prose with no file header at all, just words.\n", i }'; }

start_test "CK.17 a FAILED part beside a CUT one: the aggregate is the failure's 2, never the cut's 4"
ck_ts_file "$CK_MIX/big.ts" MARKER-BIG 400
printf '// MARKER-FAIL\nexport const s = 1;\n' > "$CK_MIX/fail.ts"
PATH="$CK_TMP/bin:$PATH" ZUVO_REVIEW_TEST_PROVIDERS="mock-chunkfate" bash "$ADV" --single --files "$CK_MIX/big.ts
$CK_MIX/fail.ts" >/dev/null 2>"$CK_MIX/err17"; rc=$?
# ar_chunk_input counts the parts apart, and its aggregate keeps the failure's code when a part FAILED.
assert_exit_code "2" "$rc" "a part with no review at all outranks a part reviewed with its input cut"
assert_contains "$(cat "$CK_MIX/err17")" "[chunk 1/2]   EXIT 4: input was truncated" "premise: part 1 really was reviewed with its input cut"
assert_eq "CHUNKED: 2 chunks — 0 ok, 1 failed, 1 reviewed with input cut. Aggregate exit: 2." \
  "$(grep '^CHUNKED: ' "$CK_MIX/err17")" "the summary names the cut part apart from the failed one (ar_chunk_input)"

start_test "CK.18 a part with NO MATERIAL beside a reviewed one: partial coverage, exit 4 — never 0"
{ ck_prose; ck_diff_section x.ts 150; ck_diff_section y.ts 150; } > "$CK_MIX/nomat.diff"
ZUVO_REVIEW_TEST_PROVIDERS="mock-success" bash "$ADV" --single < "$CK_MIX/nomat.diff" >/dev/null 2>"$CK_MIX/err18"; rc=$?
# ar_chunk_input counts the 5 on its own, and its partial-coverage check turns "some reviewed, one never
# judged" into exit 4.
assert_exit_code "4" "$rc" "one part never judged: the run does not report the range as reviewed"
assert_contains "$(cat "$CK_MIX/err18")" "[chunk 1/2] Adversarial review: NO REVIEWABLE MATERIAL" "premise: part 1 (the preamble) had no material"
assert_eq "CHUNKED: 2 chunks — 1 reviewed, 1 never judged (1 with no material, 0 not started). Partial coverage: exit 4." \
  "$(grep '^CHUNKED: ' "$CK_MIX/err18")" "the partial-coverage line counts the reviewed and the never-judged parts"
ck18_json=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success" bash "$ADV" --single --json < "$CK_MIX/nomat.diff" 2>/dev/null); rc=$?
assert_exit_code "4" "$rc" "the JSON form of the same run: exit 4"
# ar_chunk_input: the part that wrote nothing gets an explicit placeholder at its own index.
assert_eq '{"chunk":1,"status":"no_material","reviewed":false}' \
  "$(printf '%s' "$ck18_json" | jq -c '.results[0]' 2>/dev/null)" "results[0] is the no-material placeholder for part 1"
assert_eq "2 ok mock-success:ok" \
  "$(printf '%s' "$ck18_json" | jq -r '"\(.chunks) \(.results[1].status) \(.results[1].provider_outcomes)"' 2>/dev/null)" \
  "results[1] is part 2's own completed review"

start_test "CK.19 a CUT part beside a NO-MATERIAL one: exit 4, never the 'NONE carried reviewable material' 5"
{ ck_prose; ck_diff_section x.ts 600; ck_diff_section y.ts 600; } > "$CK_MIX/nomatcut.diff"
ZUVO_REVIEW_TEST_PROVIDERS="mock-success" bash "$ADV" --single < "$CK_MIX/nomatcut.diff" >/dev/null 2>"$CK_MIX/err19"; rc=$?
# ar_chunk_input exits 5 only when NO part was reviewed — a part reviewed with its input cut WAS reviewed.
# Its cut-part rule makes the cut parts' 4 the aggregate, so its partial-coverage check (rc 0 only) does not
# apply either.
assert_exit_code "4" "$rc" "two parts reviewed with their input cut, one never judged: exit 4"
if grep -q 'NONE carried reviewable material' "$CK_MIX/err19"; then
  fail "the run is not reported as reviewing nothing" "$(grep '^CHUNKED' "$CK_MIX/err19")"
else
  pass "the run is not reported as reviewing nothing"
fi
assert_eq "CHUNKED: 3 chunks — 0 ok, 0 failed, 2 reviewed with input cut, 1 with no material (NOT reviewed). Aggregate exit: 4." \
  "$(grep '^CHUNKED: ' "$CK_MIX/err19")" "the summary counts the cut parts and the no-material part"

start_test "CK.20 ZUVO_RUN_DEADLINE spent before a part could start: that part is NOT started, never counted"
# A part starts only with at least LANE_MIN_RETRY_SECONDS of the deadline left (ar_chunk_input), read
# from the program, not restated. Deadline = that + 2: part 1 starts whatever second the clock is in,
# and takes 3 s (MARKER-SLOW), so parts 2 and 3 have at most that - 1 left. No upper time bound decides
# anything here: `sleep 3` only ever lasts AT LEAST 3 s.
. "$ROOT/tests/lib/adversarial-driver.sh"   # its own load, not CK.14's: adv_driver_source assembles the program
ck_min=$(adv_driver_source "$ADV" 2>/dev/null | sed -n 's/^LANE_MIN_RETRY_SECONDS=\([0-9][0-9]*\).*/\1/p' | head -1)
if [[ -z "$ck_min" ]]; then
  fail "premise: LANE_MIN_RETRY_SECONDS read from the program" "no ^LANE_MIN_RETRY_SECONDS=<n> line in the assembled program"
else
  ck_ts_file "$CK_MIX/slow1.ts" MARKER-SLOW 220
  ck_ts_file "$CK_MIX/fast2.ts" MARKER-TWO 220
  ck_ts_file "$CK_MIX/fast3.ts" MARKER-THREE 220
  ck20_dl=$(( ck_min + 2 ))
  ck20_json=$(PATH="$CK_TMP/bin:$PATH" ZUVO_RUN_DEADLINE="$ck20_dl" ZUVO_REVIEW_TEST_PROVIDERS="mock-chunkfate" \
    bash "$ADV" --single --json --files "$CK_MIX/slow1.ts
$CK_MIX/fast2.ts
$CK_MIX/fast3.ts" 2>"$CK_MIX/err20"); rc=$?
  # ar_chunk_input's partial-coverage check: parts never started are never judged — partial coverage, exit 4.
  assert_exit_code "4" "$rc" "two parts never started: the run does not report the range as reviewed"
  assert_eq "2" "$(grep -cE "^  \[chunk [23]/3\] not started — [0-9]+s left of ZUVO_RUN_DEADLINE=${ck20_dl}\$" "$CK_MIX/err20")" \
    "each part left out says so, with the deadline it ran out of (ar_chunk_input)"
  assert_eq "CHUNKED: 3 chunks — 1 reviewed, 2 never judged (0 with no material, 2 not started). Partial coverage: exit 4." \
    "$(grep '^CHUNKED: ' "$CK_MIX/err20")" "the summary counts the not-started parts as never judged"
  # ar_chunk_input: the not-started placeholder is that part's result, at its own index.
  assert_eq 'ok|{"chunk":2,"status":"not_started","reviewed":false}|{"chunk":3,"status":"not_started","reviewed":false}' \
    "$(printf '%s' "$ck20_json" | jq -r '[.results[0].status, (.results[1] | tojson), (.results[2] | tojson)] | join("|")' 2>/dev/null)" \
    "results: part 1's review, then a not_started placeholder for parts 2 and 3"
fi
