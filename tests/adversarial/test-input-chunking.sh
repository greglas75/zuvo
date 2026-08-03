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

# Synthetic --files corpus: 5 files x ~9000 chars = ~45k > 30000 cap. Unique
# marker per file so provider visibility is attributable.
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
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --files "$FILE_LIST" 2>"$CK_TMP/err1"); rc=$?
assert_eq "0" "$rc" "aggregate exit code"
grep -q 'CHUNKED INPUT:' "$CK_TMP/err1" \
  && pass "CHUNKED INPUT banner printed" || fail "no CHUNKED INPUT banner" "$(head -3 "$CK_TMP/err1")"
grep -q 'WARN: input truncated' "$CK_TMP/err1" \
  && fail "truncation WARN still fired alongside chunking" || pass "no truncation WARN"

# ─── 2: the silent-drop regression — EVERY file reaches a provider ────────────

start_test "CK.2 all files visible to providers across chunks"
missing=""
for i in 1 2 3 4 5; do
  printf '%s' "$out" | grep -q "module-$i.ts" || missing="$missing module-$i.ts"
done
if [[ -z "$missing" ]]; then
  pass "5/5 files seen (the 543KB silent-drop cannot recur)"
else
  fail "files never seen by any provider" "$missing"
fi
n_banners=$(printf '%s' "$out" | grep -c '^=== ADVERSARIAL CHUNK [0-9]*/[0-9]* ===')
[[ "$n_banners" -ge 2 ]] \
  && pass "output carries $n_banners chunk banners (>=2)" \
  || fail "expected >=2 chunk banners" "got $n_banners"

# ─── 3: dry-run prints the plan, dispatches nothing ───────────────────────────

start_test "CK.3 dry-run shows chunk plan without invoking providers"
out2=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --dry-run --files "$FILE_LIST" 2>"$CK_TMP/err2"); rc=$?
assert_eq "0" "$rc" "dry-run exit"
grep -q 'chunk plan' "$CK_TMP/err2" && pass "plan printed" || fail "no chunk plan" "$(head -3 "$CK_TMP/err2")"
printf '%s' "$out2" | grep -q 'SEEN FILES' \
  && fail "dry-run dispatched a provider" || pass "no provider dispatched"

# ─── 4: opt-outs restore the legacy truncate path ──────────────────────────────

start_test "CK.4 --no-chunk falls back to loud truncation"
ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --no-chunk --files "$FILE_LIST" >/dev/null 2>"$CK_TMP/err3" || true
grep -q 'WARN: input truncated' "$CK_TMP/err3" && ! grep -q 'CHUNKED INPUT:' "$CK_TMP/err3" \
  && pass "flag opt-out truncates with WARN" || fail "flag opt-out path" "$(grep -E 'WARN|CHUNKED' "$CK_TMP/err3" | head -2)"

start_test "CK.5 ZUVO_ADV_NO_CHUNK=1 env opt-out"
ZUVO_ADV_NO_CHUNK=1 ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --files "$FILE_LIST" >/dev/null 2>"$CK_TMP/err4" || true
grep -q 'WARN: input truncated' "$CK_TMP/err4" && ! grep -q 'CHUNKED INPUT:' "$CK_TMP/err4" \
  && pass "env opt-out truncates with WARN" || fail "env opt-out path" "$(grep -E 'WARN|CHUNKED' "$CK_TMP/err4" | head -2)"

# ─── 5: recursion guard — a child never chunks again ──────────────────────────

start_test "CK.6 ZUVO_ADV_CHUNK set -> child takes the truncate path"
ZUVO_ADV_CHUNK="1/1" ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --files "$FILE_LIST" >/dev/null 2>"$CK_TMP/err5" || true
grep -q 'WARN: input truncated' "$CK_TMP/err5" && ! grep -q 'CHUNKED INPUT:' "$CK_TMP/err5" \
  && pass "no infinite recursion possible" || fail "recursion guard" "$(grep -E 'WARN|CHUNKED' "$CK_TMP/err5" | head -2)"

# ─── 6: under-cap input is untouched ──────────────────────────────────────────

start_test "CK.7 small input takes the normal single-pass path"
ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --files "$CK_TMP/src/module-1.ts" >/dev/null 2>"$CK_TMP/err6" || true
! grep -q 'CHUNKED INPUT:' "$CK_TMP/err6" && ! grep -q 'WARN: input truncated' "$CK_TMP/err6" \
  && pass "no chunking, no truncation" || fail "small input mis-handled" "$(grep -E 'WARN|CHUNKED' "$CK_TMP/err6" | head -2)"

# ─── 7: JSON mode wraps chunk results in ONE object ───────────────────────────

start_test "CK.8 JSON output is {chunked:true, chunks:N, results:[...]}"
out7=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success" bash "$ADV" --single --json --files "$FILE_LIST" 2>/dev/null) || true
if printf '%s' "$out7" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('chunked') is True and d.get('chunks',0)>=2 and isinstance(d.get('results'),list)" 2>/dev/null; then
  pass "wrapper object valid"
else
  fail "JSON wrapper malformed" "$(printf '%s' "$out7" | head -c 160)"
fi

# ─── 8: repeatable --file (field retro 2026-08-02: newline-quoting bit twice) ──

start_test "CK.10 repeatable --file collects multiple paths without quoting ambiguity"
out10=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single \
  --file "$CK_TMP/src/module-1.ts" --file "$CK_TMP/src/module-2.ts" 2>/dev/null) || true
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
ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-files" bash "$ADV" --single --files "$FILE_LIST" --artifact "$ART" >/dev/null 2>&1 || true
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
# 3 real h2 sections (25k each = 75k > the 50000 doc cap) + 4 DECOY headings
# inside a fenced bash block. A naive `^##+ ` counter sees 7 boundaries; a
# fence-aware one sees 3. Plans are full of fenced bash, so this is the case
# that decides whether the split is usable at all.
{ printf '# Plan Title\n\n## Alpha\n'
  awk 'BEGIN{for(i=0;i<25000;i++)printf "a"}'
  printf '\n\n```bash\n## decoy one\n## decoy two\n#### decoy three\n## decoy four\n```\n\n## Beta\n'
  awk 'BEGIN{for(i=0;i<25000;i++)printf "b"}'
  printf '\n\n## Gamma\n'
  awk 'BEGIN{for(i=0;i<25000;i++)printf "c"}'
  printf '\n'; } > "$CK_DOC/plan.md"

start_test "CK.11 plan mode chunks at h2 headings instead of truncating"
bash "$ADV" --mode plan --dry-run < "$CK_DOC/plan.md" >/dev/null 2>"$CK_DOC/err" || true
grep -q 'CHUNKED INPUT:' "$CK_DOC/err" && ! grep -q 'WARN: input truncated' "$CK_DOC/err" \
  && pass "doc input chunked, not truncated" \
  || fail "doc mode still truncates" "$(grep -E 'CHUNKED|truncated' "$CK_DOC/err" | head -2)"

start_test "CK.12 no content is lost — chunk sizes sum to the input"
doc_size=$(wc -c < "$CK_DOC/plan.md" | tr -d ' ')
sum=$(awk '/chunk-[0-9]+: [0-9]+ chars/ { for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/ && $(i+1) ~ /^chars/) s += $i } END { print s+0 }' "$CK_DOC/err")
# >= size-64: the splitter re-emits whole lines, so the sum can exceed the byte
# count by a trailing newline per chunk; it must never be LESS.
[[ "$sum" -ge $((doc_size - 64)) ]] \
  && pass "chunk bytes ${sum} >= input ${doc_size} (nothing dropped)" \
  || fail "content lost in doc chunking" "chunks=${sum} input=${doc_size}"

start_test "CK.13 headings inside code fences are NOT boundaries"
naive=$(awk '/^##+ /{n++} END{print n+0}' "$CK_DOC/plan.md")
chunks=$(grep -c 'chunk-[0-9]*:' "$CK_DOC/err")
assert_eq "7" "$naive" "decoy corpus really does fool a naive counter"
assert_eq "3" "$chunks" "fence-aware split yields one chunk per REAL section"

start_test "CK.14 the per-chunk note says 'document', not 'files'"
# A plan reviewer told that sibling FILES exist elsewhere reports the document as
# truncated or flags cross-references it cannot see. The note must match reality.
# NB: the verdict must come back through pass/fail — a python `print("PASS")`
# is invisible to the harness and would gate nothing while looking green.
if python3 - "$ADV" <<'PY'
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
head -c 4000 "$CK_DOC/plan.md" > "$CK_DOC/small.md"
bash "$ADV" --mode plan --dry-run < "$CK_DOC/small.md" >/dev/null 2>"$CK_DOC/err_small" || true
grep -q 'CHUNKED INPUT:' "$CK_DOC/err_small" \
  && fail "under-cap document was chunked" "$(head -2 "$CK_DOC/err_small")" \
  || pass "under-cap document not chunked"

start_test "CK.16 code mode still splits at FILE boundaries (no cross-mode regression)"
bash "$ADV" --single --dry-run --files "$FILE_LIST" >/dev/null 2>"$CK_DOC/err_code" || true
grep -q 'chunks at file boundaries' "$CK_DOC/err_code" \
  && pass "code mode boundary unchanged" \
  || fail "code-mode boundary changed" "$(grep 'CHUNKED INPUT' "$CK_DOC/err_code" | head -1)"
