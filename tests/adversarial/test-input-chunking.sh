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

start_test "CK.14 each part of a split document is told it is ONE document, never that sibling files exist"
# A plan reviewer told that sibling FILES are reviewed elsewhere reports the document as truncated or flags
# cross-references it cannot see. The lane echoes the prompt it received, so the Context line each part
# actually carried is read here: "part i/3 of ONE document", and no "sibling files" wording.
ck14_out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-prompt" bash "$ADV" --single --mode plan < "$CK_DOC/plan.md" 2>"$CK_DOC/err14"); rc=$?
assert_eq "0" "$rc" "every part of the plan reviewed: exit 0"
assert_eq "1/3 2/3 3/3|0" \
  "$(printf '%s\n' "$ck14_out" | sed -n 's#^Context: \[part \([0-9]*/[0-9]*\) of ONE document split at section headings.*#\1#p' | tr '\n' ' ' | sed 's/ $//')|$(printf '%s\n' "$ck14_out" | grep -c '^Context: .*sibling files')" \
  "parts 1/3 to 3/3 each carry the one-document note, none the sibling-files note"
# Control: a chunked CODE diff (two files, each over half the cap) must never be told it is one document.
for f in a b; do
  printf 'diff --git a/%s.ts b/%s.ts\n--- a/%s.ts\n+++ b/%s.ts\n@@ -0,0 +1,400 @@\n' "$f" "$f" "$f" "$f"
  awk -v f="$f" 'BEGIN{for(i=0;i<400;i++) printf "+export const %s%d = \"%s\";\n", f, i, "xxxxxxxxxxxxxxxxxxxxxxxx"}'
done > "$CK_DOC/code14.diff"
ck14c=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-prompt" bash "$ADV" --single --mode code < "$CK_DOC/code14.diff" 2>"$CK_DOC/err14c"); rc=$?
assert_eq "0|2|0" "$rc|$(printf '%s\n' "$ck14c" | grep -c '^Context: .*sibling files')|$(printf '%s\n' "$ck14c" | grep -c '^Context: .*ONE document')" \
  "a chunked code diff: both chunks carry the sibling-files note, neither the one-document note"

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
assert_exit_code "4" "$rc" "two parts reviewed with their input cut, one with no material: exit 4"
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

# ─── 13: the caps and the packing rule (ar_set_input_cap, ar_chunk_input) ──────

start_test "CK.21 a document over the code cap but under the document cap goes whole: not chunked, not cut"
# ar_set_input_cap gives the document modes (spec/plan/audit/migrate) a 50000-char cap where code has 30000.
# A 3-task plan of ~36k chars sits between the two, so it is one prompt, exactly as written.
{ printf '# Mid Plan\n\n'
  for t in 1 2 3; do printf '### Task %d: Step\n' "$t"; awk 'BEGIN{for(i=0;i<12000;i++)printf "m"}'; printf '\n\n'; done
} > "$CK_DOC/mid.md"
mid_size=$(wc -c < "$CK_DOC/mid.md" | tr -d ' ')
if [[ "$mid_size" -gt 30000 && "$mid_size" -lt 50000 ]]; then pass "premise: the plan ($mid_size chars) is between the two caps"
else fail "premise: the plan is between the two caps" "size $mid_size"; fi
mid_out=$(bash "$ADV" --mode plan --dry-run < "$CK_DOC/mid.md" 2>"$CK_DOC/err_mid"); rc=$?
assert_eq "0" "$rc" "the dry run of the plan: exit 0"
if grep -qE 'CHUNKED INPUT:|WARN: input truncated' "$CK_DOC/err_mid"; then
  fail "the plan is neither chunked nor truncated" "$(grep -E 'CHUNKED|truncated' "$CK_DOC/err_mid" | head -2)"
else
  pass "the plan is neither chunked nor truncated"
fi
assert_contains "$mid_out" "### Task 3: Step" "the whole plan, last task included, is in the one prompt"

start_test "CK.22 ZUVO_ADV_MAX_CHARS under its 2000 minimum is refused with a WARN, never used as the cap"
# ar_set_input_cap reads the override through ar_env_int with a floor of 2000: under it, the chunk budget
# (the cap less the per-chunk note's headroom) would be nothing but note. 2000 itself is accepted — the
# control — and a dry run applies it (the one ~10.7k-char file is cut), so 1999 not cutting is the floor.
ZUVO_ADV_MAX_CHARS=1999 bash "$ADV" --single --dry-run --files "$CK_TMP/src/module-1.ts" >/dev/null 2>"$CK_TMP/err22"; rc=$?
assert_eq "0" "$rc" "the dry run under ZUVO_ADV_MAX_CHARS=1999: exit 0"
assert_contains "$(cat "$CK_TMP/err22")" "ZUVO_ADV_MAX_CHARS=1999 is below its minimum of 2000 — using 30000" "the WARN names the floor and the cap used instead"
if grep -qE 'CHUNKED INPUT:|WARN: input truncated' "$CK_TMP/err22"; then
  fail "the refused value cuts nothing" "$(grep -E 'CHUNKED|truncated' "$CK_TMP/err22" | head -2)"
else
  pass "the refused value cuts nothing"
fi
ZUVO_ADV_MAX_CHARS=2000 bash "$ADV" --single --dry-run --files "$CK_TMP/src/module-1.ts" >/dev/null 2>"$CK_TMP/err22b"; rc=$?
assert_eq "0" "$rc" "control: the dry run under ZUVO_ADV_MAX_CHARS=2000: exit 0"
assert_contains "$(cat "$CK_TMP/err22b")" "WARN: input truncated" "control: 2000 is accepted and is the cap the file is cut to"

start_test "CK.23 sections that fill the chunk budget exactly share one chunk"
# ar_chunk_input packs sections greedily into chunks of at most the budget: the cap less
# CHUNK_NOTE_HEADROOM_CHARS (read from the program, not restated). Three diff sections of exactly half the
# budget each: the first two fill a chunk to the budget exactly and stay together, the third starts the next.
. "$ROOT/tests/lib/adversarial-driver.sh"   # its own load: adv_driver_source assembles the program
ck_room=$(adv_driver_source "$ADV" 2>/dev/null | sed -n 's/^CHUNK_NOTE_HEADROOM_CHARS=\([0-9][0-9]*\).*/\1/p' | head -1)
if [[ -z "$ck_room" ]]; then
  fail "premise: CHUNK_NOTE_HEADROOM_CHARS read from the program" "no ^CHUNK_NOTE_HEADROOM_CHARS=<n> line in the assembled program"
else
  ck23_cap=$(( ck_room + 4000 ))   # a 4000-char budget: two 2000-char sections fill it exactly
  python3 - "$CK_MIX/exact.diff" 2000 <<'PY'
import sys
path, size = sys.argv[1], int(sys.argv[2])
parts = []
for k in (1, 2, 3):
    s = f"diff --git a/f{k}.ts b/f{k}.ts\n@@ -0,0 +1 @@\n"
    while len(s) + 3 <= size - 10:
        s += "+x\n"
    s += "+" + "y" * (size - len(s) - 2) + "\n"
    assert len(s) == size, len(s)
    parts.append(s)
open(path, "w").write("".join(parts))
PY
  ZUVO_ADV_MAX_CHARS="$ck23_cap" bash "$ADV" --dry-run < "$CK_MIX/exact.diff" >/dev/null 2>"$CK_MIX/err23"; rc=$?
  assert_eq "0" "$rc" "the chunk plan of a dry run: exit 0"
  assert_eq "chunk-001: 4000 chars, files: 2|chunk-002: 2000 chars, files: 1" \
    "$(sed -n 's/^  \(chunk-[0-9]*: .*\)$/\1/p' "$CK_MIX/err23" | tr '\n' '|' | sed 's/|$//')" \
    "two parts: the first holds the two sections that fill the budget exactly"
fi

start_test "CK.24 each part is handed what is LEFT of ZUVO_RUN_DEADLINE, not the whole of it"
# ar_chunk_input runs each part as a child with ZUVO_RUN_DEADLINE set to the deadline less the time the parts
# before it took, so N parts cannot take N times the budget. The lane records the value its part's run was
# given; part 1 takes at least 2 s (MARKER-SLOW), so part 2 is handed at most the deadline less 2. Only that
# lower bound on part 1's time decides anything — `sleep 2` lasts AT LEAST 2 s.
cat > "$CK_TMP/bin/mock-deadline-seen" <<'MOCK'
#!/usr/bin/env bash
p="$(cat)"
printf '%s\n' "${ZUVO_RUN_DEADLINE-<unset>}" >> "$CK_DL_LOG"
case "$p" in *MARKER-SLOW*) sleep 2 ;; esac
echo '{"findings":[]}'
MOCK
chmod +x "$CK_TMP/bin/mock-deadline-seen"
ck_ts_file "$CK_MIX/dl-slow1.ts" MARKER-SLOW 220
ck_ts_file "$CK_MIX/dl-fast2.ts" MARKER-TWO 220
: > "$CK_MIX/dl24.log"
CK_DL_LOG="$CK_MIX/dl24.log" PATH="$CK_TMP/bin:$PATH" ZUVO_RUN_DEADLINE=600 ZUVO_REVIEW_TEST_PROVIDERS="mock-deadline-seen" \
  bash "$ADV" --single --files "$CK_MIX/dl-slow1.ts
$CK_MIX/dl-fast2.ts" >/dev/null 2>"$CK_MIX/err24"; rc=$?
assert_exit_code "0" "$rc" "both parts reviewed: exit 0"
assert_eq "CHUNKED: 2 chunks — 2 ok, 0 failed. Aggregate exit: 0." "$(grep '^CHUNKED: ' "$CK_MIX/err24")" "premise: two parts, both run"
ck24_p1=$(sed -n 1p "$CK_MIX/dl24.log"); ck24_p2=$(sed -n 2p "$CK_MIX/dl24.log")
if [[ "$ck24_p1" =~ ^[0-9]+$ && "$ck24_p1" -le 600 && "$ck24_p1" -gt 0 ]]; then pass "part 1 is handed at most the deadline ($ck24_p1 of 600)"
else fail "part 1 is handed at most the deadline" "part 1 saw <$ck24_p1>"; fi
if [[ "$ck24_p2" =~ ^[0-9]+$ && "$ck24_p2" -le 598 && "$ck24_p2" -gt 0 ]]; then pass "part 2 is handed what part 1 left ($ck24_p2 of 600)"
else fail "part 2 is handed what part 1 left (at most 598 of 600)" "part 2 saw <$ck24_p2>"; fi

start_test "CK.25 a glob-shaped --exclude reaches every part as typed, never expanded against the CWD"
# --exclude takes lane NAMES, matched whole; ar_chunk_input forwards each one to the parts with pathname
# expansion off. Run from a directory holding a file named exactly like a lane, 'mock-succes?' would
# otherwise expand to that file's name and the parts would drop the lane the parent kept (here --multi then
# has one lane left). The value names no lane, so every part runs both, as the parent would.
mkdir -p "$CK_MIX/globcwd"; : > "$CK_MIX/globcwd/mock-success"
ck25_json=$(cd "$CK_MIX/globcwd" && ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-echo-files" \
  bash "$ADV" --multi --json --exclude 'mock-succes?' --files "$FILE_LIST" 2>"$CK_MIX/err25"); rc=$?
assert_exit_code "0" "$rc" "every part reviewed by both lanes: exit 0"
assert_eq "3|mock-success, mock-echo-files|mock-success, mock-echo-files|mock-success, mock-echo-files" \
  "$(printf '%s' "$ck25_json" | jq -r '[(.chunks | tostring), (.results[] | .providers_used)] | join("|")' 2>/dev/null)" \
  "each of the 3 parts ran both lanes: the glob excluded nothing"

# ─── 14: one file over the cap is split at its hunks (ar_chunk_input, _ck_split_hunks) ───
#
# A diff of ONE file has a single file boundary, so the file split had nothing to cut at and the input was
# truncated: the tail hunks reached no reviewer and the proof recorded input_truncated=true, which the push
# gate refuses. The lane below keeps every call's prompt as its own numbered file, so each part a run sends
# is seen — a one-file echo keeps only the last part.
mkdir -p "$CK_TMP/bin"
cat > "$CK_TMP/bin/mock-partlog" <<'MOCK'
#!/usr/bin/env bash
n=1
while ! ( set -C; : > "$CK_PART_DIR/$n.in" ) 2>/dev/null; do
  n=$((n + 1)); [ "$n" -le 999 ] || { echo "mock-partlog: cannot create a part file in $CK_PART_DIR" >&2; exit 1; }
done
cat > "$CK_PART_DIR/$n.in"
echo '{"findings":[]}'
MOCK
chmod +x "$CK_TMP/bin/mock-partlog"
CK_HK="$CK_TMP/hunks"; mkdir -p "$CK_HK"

# ck_hunk_diff <path> <tag> <size>... — one file's diff with one hunk per <size> (chars, about); hunk k ends with
# the line `+MARKER-<tag>-H<k>`, so a marker seen proves its whole hunk reached a part.
ck_hunk_diff() {
  local p="$1" tag="$2" k=0 s
  shift 2
  printf 'diff --git a/%s b/%s\nindex 1111111..2222222 100644\n--- a/%s\n+++ b/%s\n' "$p" "$p" "$p" "$p"
  for s in "$@"; do
    k=$((k + 1))
    awk -v k="$k" -v s="$s" -v tag="$tag" 'BEGIN {
      printf "@@ -%d,1 +%d,2 @@\n", k * 1000, k * 1000
      n = 0
      while (n < s) { l = sprintf("+hunk %d line padding padding padding padding padding padding\n", k); printf "%s", l; n += length(l) }
      printf "+MARKER-%s-H%d\n", tag, k }'
  done
}
# ck_run_parts <case> <stdin file> [driver args...] — a --single review by mock-partlog, its prompts kept in
# $CK_HK/parts-<case>/<n>.in, stderr in $CK_HK/err-<case>, the artifact $CK_HK/art-<case>; status = the driver's.
ck_run_parts() {
  local c="$1" in="$2"
  shift 2
  mkdir -p "$CK_HK/parts-$c"
  CK_PART_DIR="$CK_HK/parts-$c" PATH="$CK_TMP/bin:$PATH" ZUVO_REVIEW_TEST_PROVIDERS="mock-partlog" \
    bash "$ADV" --single --artifact "$CK_HK/art-$c" "$@" < "$in" >/dev/null 2>"$CK_HK/err-$c"
}
# ck_part_count <case> — how many prompts the lane received.
ck_part_count() { local n=0; while [[ -f "$CK_HK/parts-$1/$((n + 1)).in" ]]; do n=$((n + 1)); done; echo "$n"; }
# ck_marker_counts <case> <tag> <hunks> — "<tag>-H1=<n> …": in how many lines across all prompts each marker is.
# Counted file by file: a prompt ends without a newline, so concatenated prompts would glue its last line to the next.
ck_marker_counts() {
  local k=1 out="" c f
  while [[ "$k" -le "$3" ]]; do
    c=0
    for f in "$CK_HK/parts-$1"/*.in; do
      [[ -f "$f" ]] && c=$((c + $(grep -cxF -- "+MARKER-$2-H$k" "$f")))
    done
    out="${out:+$out }$2-H$k=$c"; k=$((k + 1))
  done
  echo "$out"
}
# ck_headerless_parts <case> <path> <tag> — the prompts holding a hunk of <path> (a +MARKER-<tag>- line) without its
# whole diff header (diff --git, ---, +++), by number; empty = every such part names its file.
ck_headerless_parts() {
  local f out=""
  for f in "$CK_HK/parts-$1"/*.in; do
    [[ -f "$f" ]] && grep -q "^+MARKER-$3-H" "$f" || continue
    grep -qxF -- "diff --git a/$2 b/$2" "$f" && grep -qxF -- "--- a/$2" "$f" && grep -qxF -- "+++ b/$2" "$f" \
      || out="${out:+$out }$(basename "$f" .in)"
  done
  echo "$out"
}
# ck_part_notes <case> — each prompt's hunk note (the "hunks a-b of N of <path>" its Context line names), in call
# order, joined by "|"; a prompt with no such note contributes an empty field.
ck_part_notes() {
  local n=1 out="" sep=""
  while [[ -f "$CK_HK/parts-$1/$n.in" ]]; do
    out="$out$sep$(sed -n 's/^Context: .*\(hunks [0-9]*-[0-9]* of [0-9]* of [^];]*\).*$/\1/p' "$CK_HK/parts-$1/$n.in" | head -1)"
    sep="|"; n=$((n + 1))
  done
  echo "$out"
}

start_test "CK.26 one file over the cap with 3 hunks is split at its hunks, never cut"
ck_hunk_diff big.sh BIG 12000 12000 12000 > "$CK_HK/one.diff"
ck_run_parts 26 "$CK_HK/one.diff"; rc=$?
assert_exit_code "0" "$rc" "every part reviewed whole: exit 0 (the unsplit file was cut: exit 4)"
if grep -q 'input_truncated=true' "$CK_HK/art-26" 2>/dev/null; then
  fail "the proof records no truncation" "$(grep -c 'input_truncated=true' "$CK_HK/art-26") input_truncated=true record(s)"
else
  pass "the proof records no truncation"
fi
assert_eq "2" "$(ck_part_count 26)" "two parts: hunks 1-2 fill one, hunk 3 the next"
assert_eq "" "$(ck_headerless_parts 26 big.sh BIG)" "every part repeats the file's diff --git/---/+++ header"
assert_eq "BIG-H1=1 BIG-H2=1 BIG-H3=1" "$(ck_marker_counts 26 BIG 3)" "each hunk reached exactly one part, whole"
assert_eq "hunks 1-2 of 3 of big.sh|hunks 3-3 of 3 of big.sh" "$(ck_part_notes 26)" "each part's note names the hunks it holds"

start_test "CK.27 beside small files, the one file over the cap is split at its hunks"
{ ck_hunk_diff a.sh A 2000; ck_hunk_diff big.sh BIG 12000 12000 12000; ck_hunk_diff c.sh C 2000; } > "$CK_HK/three.diff"
ck_run_parts 27 "$CK_HK/three.diff"; rc=$?
assert_exit_code "0" "$rc" "every part reviewed whole: exit 0 (the big file's part was cut: exit 4)"
if grep -q 'input_truncated=true' "$CK_HK/art-27" 2>/dev/null; then
  fail "the proof records no truncation" "$(grep -c 'input_truncated=true' "$CK_HK/art-27") input_truncated=true record(s)"
else
  pass "the proof records no truncation"
fi
assert_eq "" "$(ck_headerless_parts 27 big.sh BIG)" "every part holding a big.sh hunk repeats big.sh's header"
assert_eq "BIG-H1=1 BIG-H2=1 BIG-H3=1|A-H1=1|C-H1=1" \
  "$(ck_marker_counts 27 BIG 3)|$(ck_marker_counts 27 A 1)|$(ck_marker_counts 27 C 1)" "every hunk of every file reached exactly one part"
assert_eq "hunks 1-2 of 3 of big.sh|hunks 3-3 of 3 of big.sh" "$(ck_part_notes 27)" "each part's note names the big file's hunks it holds"

start_test "CK.28 one hunk over the cap by itself: only that hunk is cut, the others reach a part whole"
ck_hunk_diff big.sh BIG 2000 35000 2000 > "$CK_HK/onebig.diff"
ck_run_parts 28 "$CK_HK/onebig.diff"; rc=$?
# Owner decision: a single hunk over the cap cannot be split further, so its part is truncated and says so.
assert_exit_code "4" "$rc" "a part reviewed with its input cut: exit 4"
assert_contains "$(cat "$CK_HK/art-28" 2>/dev/null)" "input_truncated=true" "the proof records the truncation"
assert_eq "BIG-H1=1 BIG-H2=0 BIG-H3=1" "$(ck_marker_counts 28 BIG 3)" "hunks 1 and 3 reached a part whole; only hunk 2 was cut"

start_test "CK.29 '@@ ' lines inside a --files section are file content, never hunk boundaries"
{ k=1; while [[ "$k" -le 3 ]]; do
    printf '@@ -%d +%d @@\n' "$k" "$k"
    awk -v k="$k" 'BEGIN { for (i = 0; i < 180; i++) printf "raw text %d padding padding padding padding padding padding\n", k }'
    k=$((k + 1))
  done; } > "$CK_HK/notes.txt"
ZUVO_REVIEW_TEST_PROVIDERS="mock-success" bash "$ADV" --single --files "$CK_HK/notes.txt" >/dev/null 2>"$CK_HK/err-29"; rc=$?
# Splitting it would hand each part a fragment with no file header, read as a file of its own.
assert_exit_code "4" "$rc" "one --files section over the cap is truncated: exit 4"
if grep -q 'CHUNKED INPUT:' "$CK_HK/err-29"; then
  fail "the --files section is not split" "$(grep 'CHUNKED INPUT:' "$CK_HK/err-29")"
else
  pass "the --files section is not split"
fi
# Beside a second file the input does chunk at file boundaries, so the hunk split sees the --files section too.
printf 'small file\n' > "$CK_HK/small.txt"
ZUVO_REVIEW_TEST_PROVIDERS="mock-success" bash "$ADV" --single --files "$CK_HK/notes.txt
$CK_HK/small.txt" >/dev/null 2>"$CK_HK/err-29b"; rc=$?
assert_exit_code "4" "$rc" "chunked beside a small file, the --files section's part is truncated: exit 4"
assert_contains "$(cat "$CK_HK/err-29b")" "CHUNKED INPUT:" "premise: the two-file input chunks"
if grep -q 'hunk boundaries' "$CK_HK/err-29b"; then
  fail "the chunked --files section is not split at its '@@ ' lines" "$(grep 'CHUNKED INPUT:' "$CK_HK/err-29b")"
else
  pass "the chunked --files section is not split at its '@@ ' lines"
fi

start_test "CK.30 a ~300-char path: the parts stay under the cap with its header repeated, the note stays short"
ck30_path="src/$(awk 'BEGIN { for (i = 0; i < 29; i++) printf "segment%02d/", i }')long.sh"
# Two hunks fit the budget, but not with this path's ~1.2k-char header repeated in front of them.
ck_hunk_diff "$ck30_path" LONG 14600 14600 14600 > "$CK_HK/long.diff"
ck_run_parts 30 "$CK_HK/long.diff"; rc=$?
assert_exit_code "0" "$rc" "every part reviewed whole: exit 0"
if grep -q 'WARN: input truncated' "$CK_HK/err-30"; then
  fail "no part was cut" "$(grep 'input truncated' "$CK_HK/err-30" | head -2)"
else
  pass "no part was cut"
fi
assert_eq "LONG-H1=1 LONG-H2=1 LONG-H3=1" "$(ck_marker_counts 30 LONG 3)" "each hunk reached exactly one part"
assert_eq "" "$(ck_headerless_parts 30 "$ck30_path" LONG)" "every part repeats the long header"
# The longest Context line any part carried, in characters: the note stays inside its headroom.
ck30_note=$(python3 - "$CK_HK/parts-30" <<'PY'
import glob, sys
m = 0
for f in glob.glob(sys.argv[1] + "/*.in"):
    for line in open(f, encoding="utf-8", errors="replace"):
        if line.startswith("Context: "):
            m = max(m, len(line.rstrip("\n")) - len("Context: "))
print(m)
PY
)
assert_le "400" "${ck30_note:-999}" "every part's note is at most 400 characters"
assert_contains "$(ck_part_notes 30)" "hunks 1-1 of 3 of ..." "the note names the hunks with the path's tail"

start_test "CK.31 a file's lifecycle-context trailer reaches every part of it exactly once"
{ ck_hunk_diff big.sh BIG 12000 12000 12000
  printf '=== CONTEXT: big.sh - lifecycle definitions outside the changed hunks (unchanged; reference only, NOT part of this diff) ===\n'
  printf '3: trap cleanup EXIT\n10: cleanup() { printf done; }\n=== END CONTEXT ===\n'; } > "$CK_HK/trailer.diff"
ck_run_parts 31 "$CK_HK/trailer.diff"; rc=$?
assert_exit_code "0" "$rc" "every part reviewed whole: exit 0"
ck31=""
for f in "$CK_HK/parts-31"/*.in; do
  [[ -f "$f" ]] || continue
  ck31="${ck31:+$ck31|}$(basename "$f" .in):$(grep -c '^=== CONTEXT: big.sh - ' "$f")/$(grep -cxF '3: trap cleanup EXIT' "$f")/$(grep -cxF '=== END CONTEXT ===' "$f")"
done
assert_eq "1:1/1/1|2:1/1/1" "$ck31" "both parts carry the trailer's opening, a definition and its closing once"

start_test "CK.32 exactly two hunks over the cap together: split into one hunk per part"
# The first hunk is a unit like the others: miscounting it leaves a two-hunk file under the split's minimum.
ck_hunk_diff two.sh TWO 18000 18000 > "$CK_HK/two.diff"
ck_run_parts 32 "$CK_HK/two.diff"; rc=$?
assert_exit_code "0" "$rc" "both parts reviewed whole: exit 0"
if grep -q 'input_truncated=true' "$CK_HK/art-32" 2>/dev/null; then
  fail "the proof records no truncation" "$(grep -c 'input_truncated=true' "$CK_HK/art-32") input_truncated=true record(s)"
else
  pass "the proof records no truncation"
fi
assert_eq "" "$(ck_headerless_parts 32 two.sh TWO)" "both parts repeat the file's header"
assert_eq "TWO-H1=1 TWO-H2=1" "$(ck_marker_counts 32 TWO 2)" "each hunk reached exactly one part, whole"
assert_eq "hunks 1-1 of 2 of two.sh|hunks 2-2 of 2 of two.sh" "$(ck_part_notes 32)" "one hunk per part"

start_test "CK.33 an added line reading '=== CONTEXT: …' is hunk content, never the trailer"
# Only a column-0 '=== CONTEXT: ' opens the trailer; read anywhere else, the hunks after it would be
# repeated in every part as if they were context.
ck_hunk_diff fake.sh FAKE 12000 12000 12000 \
  | awk '{ print } /^\+MARKER-FAKE-H1$/ { print "+=== CONTEXT: fake.sh - an added line, not a trailer ===" }' > "$CK_HK/fake.diff"
ck_run_parts 33 "$CK_HK/fake.diff"; rc=$?
assert_exit_code "0" "$rc" "every part reviewed whole: exit 0"
assert_eq "FAKE-H1=1 FAKE-H2=1 FAKE-H3=1" "$(ck_marker_counts 33 FAKE 3)" "each hunk reached exactly one part"
ck33=0
for f in "$CK_HK/parts-33"/*.in; do
  [[ -f "$f" ]] && ck33=$((ck33 + $(grep -cxF -- '+=== CONTEXT: fake.sh - an added line, not a trailer ===' "$f")))
done
assert_eq "1" "$ck33" "the added line reached one part, with its hunk"

start_test "CK.34 a trailer too big to repeat: each part is cut in the trailer, every hunk still reaches a part whole"
# The trailer follows the hunks, so a part over the cap loses trailer text, never a hunk. Leaving the file
# whole instead would cut it once at the cap and drop hunks 2 and 3 from the review.
{ ck_hunk_diff big.sh BIG 20000 20000 20000
  printf '=== CONTEXT: big.sh - lifecycle definitions outside the changed hunks (unchanged; reference only, NOT part of this diff) ===\n'
  awk 'BEGIN { for (i = 1; i <= 520; i++) printf "%d: context line padding padding padding padding padding\n", i }'
  printf '=== END CONTEXT ===\n'; } > "$CK_HK/bigtrailer.diff"
ck_run_parts 34 "$CK_HK/bigtrailer.diff"; rc=$?
assert_exit_code "4" "$rc" "parts reviewed with their trailer cut: exit 4"
assert_contains "$(cat "$CK_HK/art-34" 2>/dev/null)" "input_truncated=true" "the proof records the truncation"
assert_eq "BIG-H1=1 BIG-H2=1 BIG-H3=1" "$(ck_marker_counts 34 BIG 3)" "every hunk reached a part whole"

start_test "CK.35 a hunk split that fails midway leaves the file whole: no partial part is reviewed"
# An awk that writes one part and then fails, for the split's call only (the one passing out=<section>).
ck_real_awk=$(command -v awk)
mkdir -p "$CK_TMP/shimbin"
{ printf '#!/usr/bin/env bash\n'
  printf 'for a in "$@"; do case "$a" in out=*) printf "+MARKER-SHIM-PART\\n" > "${a#out=}-p0001"; exit 1 ;; esac; done\n'
  printf 'exec %q "$@"\n' "$ck_real_awk"; } > "$CK_TMP/shimbin/awk"
chmod +x "$CK_TMP/shimbin/awk"
ck_hunk_diff big.sh BIG 12000 12000 12000 > "$CK_HK/shim.diff"
mkdir -p "$CK_HK/parts-35"
CK_PART_DIR="$CK_HK/parts-35" PATH="$CK_TMP/shimbin:$CK_TMP/bin:$PATH" ZUVO_REVIEW_TEST_PROVIDERS="mock-partlog" \
  bash "$ADV" --single --artifact "$CK_HK/art-35" < "$CK_HK/shim.diff" >/dev/null 2>"$CK_HK/err-35"; rc=$?
assert_exit_code "4" "$rc" "the whole file, reviewed with its input cut: exit 4"
assert_eq "1" "$(ck_part_count 35)" "one prompt: the section left whole"
ck35=0
for f in "$CK_HK/parts-35"/*.in; do
  [[ -f "$f" ]] && ck35=$((ck35 + $(grep -c 'MARKER-SHIM-PART' "$f")))
done
assert_eq "0" "$ck35" "the partial part the failed split wrote reached no reviewer"

start_test "CK.36 an opt-out keeps one multi-hunk file over the cap in one run: truncated, never split at its hunks"
# The hunk arm of the chunk gate must honour --no-chunk and ZUVO_ADV_NO_CHUNK=1 like the file arm (CK.4, CK.5):
# a caller that asked for one run gets one prompt, cut at the cap, and the proof says so.
# ck36_state <case> <rc> — "rc|prompts|CHUNKED banners|cut in proof|hunk markers seen".
ck36_state() {
  printf '%s|%s|%s|%s|%s' "$2" "$(ck_part_count "$1")" "$(grep -c 'CHUNKED INPUT:' "$CK_HK/err-$1")" \
    "$(grep -q 'input_truncated=true' "$CK_HK/art-$1" 2>/dev/null && echo cut || echo whole)" "$(ck_marker_counts "$1" BIG 3)"
}
ck_hunk_diff big.sh BIG 12000 12000 12000 > "$CK_HK/optout.diff"
ck_run_parts 36a "$CK_HK/optout.diff" --no-chunk; rc=$?
assert_eq "4|1|0|cut|BIG-H1=1 BIG-H2=1 BIG-H3=0" "$(ck36_state 36a "$rc")" \
  "--no-chunk: exit 4, one prompt, no split, the cut recorded, hunk 3 past the cap"
ZUVO_ADV_NO_CHUNK=1 ck_run_parts 36b "$CK_HK/optout.diff"; rc=$?
assert_eq "4|1|0|cut|BIG-H1=1 BIG-H2=1 BIG-H3=0" "$(ck36_state 36b "$rc")" \
  "ZUVO_ADV_NO_CHUNK=1: exit 4, one prompt, no split, the cut recorded, hunk 3 past the cap"
