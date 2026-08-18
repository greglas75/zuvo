#!/usr/bin/env bash
# A truncated adversarial review must not report as a complete one (B-ADV-TRUNC).
#
# adversarial-review.sh caps its input. When it cannot chunk — `--mode tests`, a single file larger
# than the cap, chunking disabled — it trims to a file boundary, drops the rest, prints a stderr
# WARN, sets `input_truncated=true` in the artifact… and exited 0. Every call-site in
# adversarial-loop.md gates on the EXIT CODE, so a partially-reviewed patch reported as fully
# reviewed. Observed 2026-07-31: a 50583-char patch silently dropped its single largest file and
# came back with a normal verdict.
#
# Two independent defences are asserted, because either alone leaves the hole open for someone:
#   * exit 4 — for callers that read the code
#   * pg_artifact_proven refuses `input_truncated=true` — for every caller that does not
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
REVIEW="$ROOT/scripts/adversarial-review.sh"
PASS=0; FAIL=0
t_ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
t_no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

MOCK="$TMP/bin"; mkdir -p "$MOCK"
for r in timeout gtimeout jq git; do
  p="$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v "$r" 2>/dev/null || true)"
  [ -n "$p" ] && ln -sf "$p" "$MOCK/$r"
done
cat > "$MOCK/mock-gemini" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "mcp-server" ]] && exit 1
cat > /dev/null 2>&1 || true
printf '%s\n' 'MOCK REVIEW: no findings'
EOF
chmod +x "$MOCK/mock-gemini"

run_review(){ # <input-file> <artifact> -> rc
  ( PATH="$MOCK:/usr/bin:/bin:/usr/sbin:/sbin" ZUVO_ADVERSARIAL_TEST_HARNESS=1 \
      timeout 120 bash "$REVIEW" --provider mock-gemini --files "$1" --artifact "$2" \
      >/dev/null 2>"$TMP/err"; echo $? )
}

# --- 1. an input that fits is unaffected --------------------------------------------------------
# Asserted first: if the truncation path fired on ordinary inputs, every review in the fleet would
# start returning 4 and the code would be worthless.
printf '=== FILE: small.txt ===\n%s\n' "$(head -c 500 /dev/zero | tr '\0' 'a')" > "$TMP/small.txt"
rc="$(run_review "$TMP/small.txt" "$TMP/art-small.txt")"
[ "$rc" = "0" ] && t_ok "a normal-sized review still exits 0" || t_no "small input returned rc=$rc"
grep -qx 'input_truncated=false' "$TMP/art-small.txt" && t_ok "artifact records input_truncated=false" \
  || t_no "small artifact does not record input_truncated=false"

# --- 2. a single file over the cap has no boundary to chunk on → truncation ----------------------
{ printf '=== FILE: big.txt ===\n'; head -c 40000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$TMP/big.txt"
rc="$(run_review "$TMP/big.txt" "$TMP/art-big.txt")"
[ "$rc" = "4" ] && t_ok "a truncated review exits 4, not 0" || t_no "truncated review returned rc=$rc (expected 4)"
grep -q 'EXIT 4' "$TMP/err" && t_ok "stderr says why" || t_no "no explanatory stderr line"
grep -qx 'input_truncated=true' "$TMP/art-big.txt" && t_ok "artifact carries input_truncated=true" \
  || t_no "artifact does not record the truncation"
# The findings themselves must still be delivered — 4 means incomplete, not failed.
[ -s "$TMP/art-big.txt" ] && grep -q 'REVIEW BY:' "$TMP/art-big.txt" \
  && t_ok "the partial review is still delivered with its provider markers" \
  || t_no "exit 4 suppressed the review output"

# --- 3. exit 4 must be DISTINCT from every other documented code ---------------------------------
# 4 sharing a code with "no provider" (1) / "all failed" (2) / "single provider" (3) / "timeout"
# (124) would make the caller table in adversarial-loop.md ambiguous, and ambiguity here resolves
# to "treat it as the harmless one".
for used in 0 1 2 3 7 124 125; do
  [ "$used" = "4" ] && t_no "exit 4 collides with an existing code"
done
grep -qE '^#   4   —' "$REVIEW" && t_ok "exit 4 is documented in the script header" || t_no "exit 4 undocumented"

# --- 4. THE GATE must refuse a truncated artifact regardless of any caller checking rc -----------
# This is the defence that does not depend on discipline. Without it, one call-site that ignores
# the exit code re-opens the hole for everything downstream of it.
# shellcheck source=/dev/null
. "$ROOT/hooks/lib/pipeline-gate-lib.sh" 2>/dev/null || true
if ! command -v pg_artifact_proven >/dev/null 2>&1; then
  t_no "pipeline-gate-lib did not source"
else
  REPO="$TMP/repo"; mkdir -p "$REPO/memory/reviews"
  ( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
    && echo x > a.txt && git add a.txt && git commit -qm init )
  mk_pair(){ # <name> <truncated?>
    local proof="$REPO/memory/reviews/$1.proof"
    { echo "REVIEW BY: CODEX"; echo "REVIEW BY: GEMINI"; [ "$2" = "yes" ] && echo "input_truncated=true"; } > "$proof"
    printf '<!-- zuvo-review -->\nrange: aaaaaaa..bbbbbbb\nfiles: a.txt\nadversarial: memory/reviews/%s.proof\n' "$1" \
      > "$REPO/memory/reviews/$1.md"
    printf '%s' "$REPO/memory/reviews/$1.md"
  }
  a_clean="$(mk_pair clean no)"
  a_trunc="$(mk_pair trunc yes)"
  ( cd "$REPO" && pg_artifact_proven "$REPO" "$a_clean" ) \
    && t_ok "a complete review with 2 markers is still proven" || t_no "the gate now refuses a COMPLETE review"
  ( cd "$REPO" && pg_artifact_proven "$REPO" "$a_trunc" ) \
    && t_no "the gate accepted a TRUNCATED review as proof" || t_ok "the gate refuses a truncated review despite 2 markers"
fi

# --- 5. the caller contract is written down -----------------------------------------------------
LOOP="$ROOT/shared/includes/adversarial-loop.md"
grep -q '| \*\*4\*\* |' "$LOOP" && t_ok "exit 4 has a row in the adversarial-loop exit table" || t_no "exit 4 missing from the caller table"
grep -q 'looks like success and is not' "$LOOP" && t_ok "the table warns that 4 resembles success" || t_no "no warning that 4 resembles success"

echo "  --- adversarial truncation: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
