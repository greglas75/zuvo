#!/usr/bin/env bash
# Tests pg_explain_uncovered (hooks/lib/pipeline-gate-lib.sh) and
# scripts/review-artifact-sync.sh.
#
# Contract under test: when the gate blocks, every uncovered file gets a
# distinguishable reason (proof-missing vs stale-content vs marker-missing vs
# space-separated files vs no-artifact) — because collapsing them into "no
# covering review" mis-diagnosed a real incident (2026-07-31: six data-lab
# refactor PRs read as "never reviewed" while their reviews existed with the
# proof in another checkout). The sync helper must move artifact+proof PAIRS
# and its --check must reject exactly the malformed headers the gate skips.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/hooks/lib/pipeline-gate-lib.sh"
SYNC="$ROOT/scripts/review-artifact-sync.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# The CI waiver would turn every missing-proof reason below into missing-optional.
unset PG_PROOF_OPTIONAL
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

newrepo(){ rm -rf "$TMP/r"; mkdir -p "$TMP/r/src" "$TMP/r/memory/reviews" "$TMP/r/zuvo/proofs"; cd "$TMP/r" || exit 1
  git init -q; git config user.email t@t; git config user.name t
  echo "export const a=1" > src/mod.ts; git add -A; git -c commit.gpgsign=false commit -qm base >/dev/null
  echo "export const b=2" >> src/mod.ts; git add -A; git -c commit.gpgsign=false commit -qm work >/dev/null
  BASE=$(git rev-parse HEAD~1); HEAD=$(git rev-parse HEAD); }
proof(){ : > zuvo/proofs/adv.txt; i=0; while [ $i -lt "$1" ]; do printf '###   REVIEW BY: P%s\n' "$i" >> zuvo/proofs/adv.txt; i=$((i+1)); done; }
# shellcheck source=/dev/null
. "$LIB"
explain(){ PG_REVIEW_PROOF_CUTOFF=1 pg_explain_uncovered "${BASE}..${HEAD}"; }
# A.md's reason line for src/mod.ts, as pg_explain_uncovered prints it.
because(){ printf '  src/mod.ts: a.md covers this content but %s' "$1"; }

echo "=== reason: proof file missing in THIS checkout (the data-lab incident) ==="
newrepo
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/GONE.txt\n' "$BASE" "$HEAD" > memory/reviews/a.md
touch memory/reviews/a.md
out="$(explain)"
if [ "$out" = "$(because "its proof 'zuvo/proofs/GONE.txt' is NOT in this checkout — artifact+proof travel as a PAIR: ~/.zuvo/review-artifact-sync.sh --from <checkout-that-ran-the-review> --to .")" ]; then
  ok "missing proof names the exact path and points at the PAIR sync, not a re-review"
else
  bad "missing proof reason: $out"
fi

echo "=== reason: proof truncated (the review never saw the whole change) ==="
# Bug: a truncated proof was reported as "<2 'REVIEW BY:' lines", sending the operator to re-save
# output that already had two providers instead of re-running the review whole.
newrepo; proof 2; printf 'input_truncated=true\n' >> zuvo/proofs/adv.txt
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$HEAD" > memory/reviews/a.md
out="$(explain)"
if [ "$out" = "$(because "its proof 'zuvo/proofs/adv.txt' records input_truncated=true — the reviewers never saw the whole change; re-run the review so every part is sent")" ]; then
  ok "truncated proof is named as truncated, not as a weak proof"
else
  bad "truncated-proof reason: $out"
fi

echo "=== reason: proof present but weak (one provider, no single-provider note) ==="
# Characterization guard: weak must keep its own text when the verdict replaces the old reader.
newrepo; proof 1
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$HEAD" > memory/reviews/a.md
out="$(explain)"
if [ "$out" = "$(because "its proof 'zuvo/proofs/adv.txt' has <2 'REVIEW BY:' lines and no single-provider note — save the genuine adversarial output")" ]; then
  ok "weak proof keeps its own text, distinct from the missing-proof text"
else
  bad "weak-proof reason: $out"
fi

echo "=== reason: the SECOND of two proofs is truncated ==="
# Bug: the explanation named the first (good) ref, so the operator re-checked the wrong file.
newrepo; proof 2; cp zuvo/proofs/adv.txt zuvo/proofs/b.txt; printf 'input_truncated=true\n' >> zuvo/proofs/b.txt
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt, zuvo/proofs/b.txt\n' "$BASE" "$HEAD" > memory/reviews/a.md
out="$(explain)"
if [ "$out" = "$(because "its proof 'zuvo/proofs/b.txt' records input_truncated=true — the reviewers never saw the whole change; re-run the review so every part is sent")" ]; then
  ok "a refused second proof is the one named"
else
  bad "second-ref truncation reason: $out"
fi

echo "=== reason: proof ref escapes the repo ==="
# Bug: an escaping ref fell through to the missing-proof text and sent the operator to sync it.
newrepo; proof 2
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: ../adv.txt\n' "$BASE" "$HEAD" > memory/reviews/a.md
out="$(explain)"
if [ "$out" = "$(because "its proof '../adv.txt' escapes the repo (absolute path, a .. segment or a symlink) — reference a repo-relative proof")" ]; then
  ok "an escaping ref is named as escaping"
else
  bad "escapes reason: $out"
fi

echo "=== reason: adversarial: value is prose ==="
# Bug: a prose value was reported as a missing proof file to sync.
newrepo; proof 2
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: not run (CLI providers unavailable)\n' "$BASE" "$HEAD" > memory/reviews/a.md
out="$(explain)"
if [ "$out" = "$(because "its adversarial: value 'not run (CLI providers unavailable)' is prose, not a proof path — reference the saved adversarial output file")" ]; then
  ok "a prose value is named as prose"
else
  bad "not-a-path reason: $out"
fi

echo "=== reason text carries no terminal control bytes from the header ==="
# Bug: an agent-written ref was echoed verbatim, so ESC sequences reached the operator's terminal.
newrepo; ESC="$(printf '\033')"
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/a%s[31mx.txt\n' "$BASE" "$HEAD" "$ESC" > memory/reviews/a.md
out="$(explain)"
if printf '%s' "$out" | grep -q "zuvo/proofs/a\[31mx.txt" && ! printf '%s' "$out" | grep -q "$ESC"; then
  ok "the echoed ref is stripped of ESC and still named"
else
  bad "control bytes in reason: $(printf '%s' "$out" | od -c | head -5)"
fi

echo "=== reason: stale content (file edited after review) ==="
newrepo; proof 2
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$BASE" > memory/reviews/a.md
touch memory/reviews/a.md
out="$(explain)"
if printf '%s' "$out" | grep -q 'reviewed DIFFERENT content'; then
  ok "blob mismatch reported as stale content needing a FRESH review"
else
  bad "stale-content reason: $out"
fi

echo "=== reason: artifact lists the file but lacks the marker ==="
newrepo; proof 2
printf 'range: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$HEAD" > memory/reviews/a.md
touch memory/reviews/a.md
out="$(explain)"
if printf '%s' "$out" | grep -q "lacks the '<!-- zuvo-review -->' marker"; then
  ok "marker-less artifact surfaced as a malformed header, not as 'never reviewed'"
else
  bad "marker-missing reason: $out"
fi

echo "=== reason: space-separated files list (comma parser can never match) ==="
newrepo; proof 2
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts src/other.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$HEAD" > memory/reviews/a.md
touch memory/reviews/a.md
out="$(explain)"
if printf '%s' "$out" | grep -q 'SPACE-separated'; then
  ok "space-separated files: list diagnosed by name"
else
  bad "space-separated reason: $out"
fi

echo "=== reason: nothing lists the file at all ==="
newrepo
out="$(explain)"
if printf '%s' "$out" | grep -q 'no artifact in memory/reviews/ lists this file'; then
  ok "genuinely-unreviewed content says so"
else
  bad "no-artifact reason: $out"
fi

echo "=== covered file prints NOTHING (no noise on the happy path) ==="
newrepo; proof 2
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$HEAD" > memory/reviews/a.md
touch memory/reviews/a.md
out="$(explain)"
if [ -z "$out" ]; then
  ok "fully covered range produces no explain output"
else
  bad "covered range still printed: $out"
fi

echo "=== sync: artifact + referenced proof travel as a PAIR ==="
newrepo; proof 2
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$HEAD" > memory/reviews/pair-slug.md
mkdir -p "$TMP/dst"; ( cd "$TMP/dst" && git init -q && git config user.email t@t && git config user.name t \
  && git -c commit.gpgsign=false commit -q --allow-empty -m init )
if bash "$SYNC" --from "$TMP/r" --to "$TMP/dst" --slug pair-slug >/dev/null 2>&1 \
   && [ -f "$TMP/dst/memory/reviews/pair-slug.md" ] && [ -f "$TMP/dst/zuvo/proofs/adv.txt" ]; then
  ok "sync copies both the artifact and its proof"
else
  bad "pair sync failed or left the proof behind"
fi

echo "=== sync: refuses to clobber a DIFFERENT existing file ==="
printf 'other content\n' > "$TMP/dst/memory/reviews/pair-slug.md"
if bash "$SYNC" --from "$TMP/r" --to "$TMP/dst" --slug pair-slug >/dev/null 2>&1; then
  bad "sync overwrote (or ignored) a conflicting destination artifact"
else
  grep -q 'other content' "$TMP/dst/memory/reviews/pair-slug.md" \
    && ok "conflicting destination file left untouched, non-zero exit" \
    || bad "conflicting file was clobbered"
fi

echo "=== sync: a cited proof missing at the source fails the sync ==="
# Bug: the sync reported success for a pair the destination's gate would refuse.
newrepo; proof 2
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt, zuvo/proofs/GONE.txt\n' \
  "$BASE" "$HEAD" > memory/reviews/half-slug.md
rm -rf "$TMP/dst2"; mkdir -p "$TMP/dst2"; ( cd "$TMP/dst2" && git init -q )
out="$(PG_REVIEW_PROOF_CUTOFF=1 bash "$SYNC" --from "$TMP/r" --to "$TMP/dst2" --slug half-slug 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [ -f "$TMP/dst2/zuvo/proofs/adv.txt" ] && printf '%s' "$out" | grep -q 'GONE.txt'; then
  ok "the present proof is copied, the missing one is named, and the sync exits 1"
else
  bad "half pair sync (rc=$rc): $out"
fi

echo "=== check: lints the malformed headers the gate silently skips ==="
newrepo; proof 2
printf 'range: %s..%s\nfiles: src/mod.ts\n' "$BASE" "$HEAD" > memory/reviews/nomarker.md
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts src/x.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$HEAD" > memory/reviews/spaces.md
out="$(bash "$SYNC" --check "$TMP/r" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'nomarker.md: missing' \
   && printf '%s' "$out" | grep -q 'spaces.md: files: is SPACE-separated'; then
  ok "--check fails loudly on marker-less and space-separated artifacts"
else
  bad "--check lint (rc=$rc): $out"
fi

echo "=== check --slug: lints only the matching artifact; empty match FAILs ==="
newrepo; proof 2
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$HEAD" > memory/reviews/current-run.md
printf 'range: broken\n' > memory/reviews/old-broken.md
out="$(bash "$SYNC" --check "$TMP/r" --slug current-run 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'current-run.md' \
   && ! printf '%s' "$out" | grep -q 'old-broken.md'; then
  ok "--slug scopes the lint to the current run's artifact (historical FAILs invisible)"
else
  bad "--check --slug scoping (rc=$rc): $out"
fi
out="$(bash "$SYNC" --check "$TMP/r" --slug no-such-slug 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "no artifact matching"; then
  ok "a slug matching nothing FAILs loudly (typo'd slug is never a silent pass)"
else
  bad "empty-slug-match FAIL (rc=$rc): $out"
fi

echo "=== check: a healthy pair passes ==="
newrepo; proof 2
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$HEAD" > memory/reviews/good.md
out="$(bash "$SYNC" --check "$TMP/r" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "OK   memory/reviews/good.md (proof: zuvo/proofs/adv.txt)" ]; then
  ok "--check passes a complete artifact+proof pair"
else
  bad "--check healthy pair (rc=$rc): $out"
fi

echo "=== check answers with the push gate's own verdict ==="
# art <ref-lines> — memory/reviews/t.md covering src/mod.ts, with the given proof header line(s).
art(){ printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\n%b\n' "$BASE" "$HEAD" "$1" > memory/reviews/t.md; }
# chk <id> <cutoff> <want_rc> <want_output> <bug> — runs --check on t.md alone; the whole output must match.
chk(){
  local out rc
  out="$(PG_REVIEW_PROOF_CUTOFF="$2" bash "$SYNC" --check "$TMP/r" --slug t.md 2>&1)"; rc=$?
  if [ "$rc" -eq "$3" ] && [ "$out" = "$4" ]; then ok "$1: rc=$rc — $5"
  else bad "$1: want rc=$3 [$4], got rc=$rc [$out] — $5"; fi
}
F="FAIL memory/reviews/t.md:"
TRUNC_TAIL="is truncated (input_truncated=true) — the reviewers never saw the whole change; re-run the review"
blind_proof(){ printf 'artifact_kind=adversarial-review\ncreated_at=2026-09-27T00:00:00Z\nstatus=ok\nmode=blind-audit\nREVIEW BY: A\nREVIEW BY: B\n---\nbody\n' > zuvo/proofs/adv.txt; }

newrepo; proof 2; printf 'input_truncated=true\n' >> zuvo/proofs/adv.txt; art 'adversarial: zuvo/proofs/adv.txt'
chk truncated 1 1 "$F proof 'zuvo/proofs/adv.txt' $TRUNC_TAIL" \
  "a truncated review passed --check while the gate refused it"
newrepo; blind_proof; art 'adversarial: zuvo/proofs/adv.txt'
chk blind-audit 1 1 "$F proof 'zuvo/proofs/adv.txt' is a blind-audit record (a blind-audit record, not a review) — cite the review's own adversarial output" \
  "a blind-audit record passed --check while the gate refused it"
newrepo; proof 2; art 'verdict: PASS'
chk no-ref 1 1 "$F no adversarial: proof line (no adversarial: proof path in the header) — post-cutoff artifacts without one grant no coverage" \
  "a post-cutoff artifact without a proof ref was only a WARN"
newrepo; proof 2; cp zuvo/proofs/adv.txt zuvo/proofs/b.txt; printf 'input_truncated=true\n' >> zuvo/proofs/b.txt
art 'adversarial: zuvo/proofs/adv.txt, zuvo/proofs/b.txt'
chk two-ref-comma 1 1 "$F proof 'zuvo/proofs/b.txt' $TRUNC_TAIL" \
  "only the first of two comma-listed proofs was checked"
newrepo; proof 2; printf 'REVIEW BY: P0\n' > zuvo/proofs/w.txt
art 'adversarial: zuvo/proofs/adv.txt\nadversarial: zuvo/proofs/w.txt'
chk two-ref-lines 1 1 "$F proof 'zuvo/proofs/w.txt' is weak: 1 REVIEW BY: line(s), no single-provider note — proof-of-work will reject it" \
  "a weak proof on a second adversarial: line was never read"
newrepo; art 'adversarial: zuvo/proofs/GONE.txt'
out="$(PG_PROOF_OPTIONAL=1 PG_REVIEW_PROOF_CUTOFF=1 bash "$SYNC" --check "$TMP/r" --slug t.md 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && [ "$out" = "$F proof 'zuvo/proofs/GONE.txt' is not in THIS checkout — the gate refuses it here; sync the pair (--from <checkout> --to .) or --restore" ] \
  && ok "PG_PROOF_OPTIONAL=1: a missing proof still FAILs --check (the CI waiver is not the local gate)" \
  || bad "PG_PROOF_OPTIONAL=1 waived a missing proof in --check (rc=$rc): $out"
newrepo; ESC="$(printf '\033')"; art "adversarial: zuvo/proofs/a${ESC}[31mx.txt"
out="$(PG_REVIEW_PROOF_CUTOFF=1 bash "$SYNC" --check "$TMP/r" --slug t.md 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'a\[31mx.txt' && ! printf '%s' "$out" | grep -q "$ESC" \
  && ok "an ESC byte in a ref never reaches the --check output" \
  || bad "control bytes in --check output (rc=$rc): $(printf '%s' "$out" | od -c | head -5)"
newrepo; art 'adversarial: zuvo/proofs/GONE.txt'
chk grandfathered 9999999999 0 'OK   memory/reviews/t.md (grandfathered: artifact older than the proof cutoff)' \
  "a grandfathered artifact was held to a stricter rule than the gate"

echo "=== check: the verdict comes from the gate lib beside the script, or not at all ==="
newrepo; proof 2; art 'adversarial: zuvo/proofs/adv.txt'
mkdir -p "$TMP/x/y/alone" "$TMP/emptyhome"
cp "$SYNC" "$ROOT/hooks/lib/path-contain.sh" "$TMP/x/y/alone/"
out="$(cd "$TMP/r" && HOME="$TMP/emptyhome" PG_LIB_LOADED=1 PG_REVIEW_PROOF_CUTOFF=1 \
  bash "$TMP/x/y/alone/review-artifact-sync.sh" --check 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "cannot compute the gate's verdict"; then
  ok "no reachable gate lib exits 2, even with PG_LIB_LOADED=1 in the environment"
else
  bad "no gate lib fell back to a weaker lint (rc=$rc): $out"
fi
out="$(HOME="$TMP/emptyhome" bash "$TMP/x/y/alone/review-artifact-sync.sh" --help 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q -- '--check' \
  && ok "--help still answers without the gate lib" || bad "--help without the lib (rc=$rc): $out"
# Bug guarded: a fixed line range cut the usage text short, or ran into code, after a header edit.
printf '%s' "$out" | grep -q -- '--from <src-checkout> --to <dst-checkout>' \
  && printf '%s' "$out" | grep -q 'each copied artifact at dst' && ! printf '%s' "$out" | grep -q 'case "' \
  && ok "--help prints the whole usage header and no code" || bad "--help truncated or ran into code: $out"

# A lib planted under ~/.claude/hooks/lib that proves everything must lose to the installed sibling.
FLAT="$TMP/flat"; PH="$TMP/plantedhome"; mkdir -p "$FLAT" "$PH/.claude/hooks/lib"
cp "$SYNC" "$LIB" "$ROOT/hooks/lib/path-contain.sh" "$FLAT/"
cp "$ROOT/hooks/lib/path-contain.sh" "$PH/.claude/hooks/lib/"
printf '%s\n' '. "$(dirname "${BASH_SOURCE[0]}")/path-contain.sh"' \
  'pg_artifact_proof_refs() { printf "zuvo/proofs/adv.txt\n"; }' \
  'pg_artifact_proof_verdict() { printf "proven\tzuvo/proofs/adv.txt\tplanted\n"; }' \
  'PG_LIB_LOADED=1' > "$PH/.claude/hooks/lib/pipeline-gate-lib.sh"
newrepo; proof 1; art 'adversarial: zuvo/proofs/adv.txt'
out="$(HOME="$PH" PG_REVIEW_PROOF_CUTOFF=1 bash "$FLAT/review-artifact-sync.sh" --check "$TMP/r" --slug t.md 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^FAIL memory/reviews/t.md'; then
  ok "the sibling gate lib wins over a planted ~/.claude/hooks/lib (no version skew, no forged pass)"
else
  bad "a planted ~/.claude/hooks/lib decided the verdict (rc=$rc): $out"
fi

echo "=== argument errors exit 2 with the reason and the usage ==="
# argrow <id> <want_first_stderr_line> <bug> -- <args...> — stdout empty, rc 2, stderr = reason + usage.
USAGE1="review-artifact-sync.sh — move review artifacts BETWEEN checkouts as PAIRS,"
argrow(){
  local id="$1" want="$2" bug="$3" out err rc; shift 4
  out="$(cd "$TMP" && bash "$SYNC" "$@" 2>"$TMP/arg.err")"; rc=$?
  err="$(sed -n '1,2p' "$TMP/arg.err")"
  if [ "$rc" -eq 2 ] && [ -z "$out" ] && [ "$err" = "$want
$USAGE1" ]; then ok "$id: rc=2, reason + usage on stderr — $bug"
  else bad "$id: want rc=2 [$want / $USAGE1], got rc=$rc stdout=[$out] stderr=[$err] — $bug"; fi
}
argrow from-no-value "Missing value for --from" "--from with no value looped on a failed shift 2 forever" -- --from
argrow slug-no-value "Missing value for --slug" "--slug with no value was swallowed and every artifact linted" -- --check --slug
argrow unknown-option "Unknown argument: --bogus" "an unknown option was ignored and the default mode ran" -- --check --bogus
argrow check-with-to "--check does not take --to (it inspects one checkout; use --slug to narrow)" \
  "--check silently ignored --to, so a wrong command looked like a passing check" -- --check --to "$TMP"

echo "=== PRECEDENCE: a malformed FRESH artifact must not be masked by a stale OLD one ==="
# The field failure (2026-08-06, reported after three wasted cycles): the operator
# was told "a fresh review is needed" for a review that had JUST been written. Every
# reason was already distinguishable in isolation — which is why the existing cases
# above all passed — but the RANKING preferred stale over malformed. memory/reviews/
# accumulates, so any previously-reviewed file has an older artifact listing it with
# different content; that stale reason masked the malformed header on the artifact
# the run had just produced. Re-reviewing wrote another malformed artifact and
# reproduced the identical message, forever.
#
# The rule this pins: a reason RE-REVIEWING REPAIRS (stale) must never outrank one
# it reproduces (missing marker, space-separated files:). Both artifacts present is
# the normal state, not a corner case, so isolation tests cannot catch this.
newrepo; proof 2
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$BASE" > memory/reviews/old.md
printf 'range: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$HEAD" > memory/reviews/fresh.md
out="$(explain)"
if printf '%s' "$out" | grep -q "lacks the '<!-- zuvo-review -->' marker"; then
  ok "marker-missing on the fresh artifact wins over stale-content on the old one"
else
  bad "stale masked the actionable marker reason: $out"
fi

newrepo; proof 2
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$BASE" > memory/reviews/old.md
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts other.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$HEAD" > memory/reviews/fresh.md
out="$(explain)"
if printf '%s' "$out" | grep -q "SPACE-separated"; then
  ok "space-separated on the fresh artifact wins over stale-content on the old one"
else
  bad "stale masked the actionable separator reason: $out"
fi

# The inverse must still hold: with no malformed artifact, stale is the right answer.
newrepo; proof 2
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$BASE" > memory/reviews/old.md
out="$(explain)"
if printf '%s' "$out" | grep -q "a fresh review is needed"; then
  ok "stale-content still reported when nothing is malformed (no regression)"
else
  bad "stale-content lost: $out"
fi

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
