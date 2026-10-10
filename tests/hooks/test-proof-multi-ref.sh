#!/usr/bin/env bash
# Tests the multi-ref proof verdict in hooks/lib/pipeline-gate-lib.sh: pg_artifact_proof_refs,
# pg_artifact_proof_verdict and the pg_artifact_proven wrapper the push/CI/Stop gates call.
#
# An artifact header may cite several proofs (repeated `adversarial:`/`adv-proof:` lines or a comma
# list). Each proof keeps its own metadata and must pass on its own; one failing proof refuses the
# whole artifact. Every row names the defect it catches.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/hooks/lib/pipeline-gate-lib.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null HOME="$TMP/home"
mkdir -p "$HOME"
unset PG_PROOF_OPTIONAL
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }
# shellcheck source=/dev/null
. "$LIB"

# mkproof <path> <kind> — good: 2 providers · weak: 1 provider · trunc: 2 providers but
# input_truncated=true · blind: a blind-audit record (write_artifact's fixed header prefix) ·
# unread: a good proof with mode 000.
mkproof() {
  case "$2" in
    good)  printf 'REVIEW BY: P1\nREVIEW BY: P2\n' > "$1" ;;
    unread) printf 'REVIEW BY: P1\nREVIEW BY: P2\n' > "$1"; chmod 000 "$1" ;;
    weak)  printf 'REVIEW BY: P1\n' > "$1" ;;
    trunc) printf 'input_truncated=true\nREVIEW BY: P1\nREVIEW BY: P2\n' > "$1" ;;
    blind) printf 'artifact_kind=%s\ncreated_at=%s\nstatus=%s\nmode=%s\nREVIEW BY: P1\nREVIEW BY: P2\n---\nbody\n' \
             adversarial-review 2026-10-10T00:00:00Z ok blind-audit > "$1" ;;
  esac
}

# summary <root> <artifact> — "token=ref, token=ref" from the verdict (refs never hold ", ").
summary() {
  pg_artifact_proof_verdict "$1" "$2" 2>/dev/null | awk -F '\t' '{ printf "%s%s=%s", (NR > 1 ? ", " : ""), $1, $2 }'
}

# row <id> <optional:0|1> <proofs "name=kind ..."> <header printf %b text> <want_rc> <want_summary> <bug>
row() {
  local id="$1" opt="$2" proofs="$3" header="$4" want_rc="$5" want="$6" bug="$7" r p rc got
  r="$TMP/row$id"; mkdir -p "$r/memory/reviews"
  for p in $proofs; do mkproof "$r/${p%%=*}" "${p#*=}"; done
  printf '<!-- zuvo-review -->\nrange: a..b\nfiles: *\n%b\n\nbody text\n' "$header" > "$r/memory/reviews/a.md"
  if [ "$opt" = 1 ]; then
    PG_PROOF_OPTIONAL=1 PG_REVIEW_PROOF_CUTOFF=1 pg_artifact_proven "$r" "$r/memory/reviews/a.md"; rc=$?
    got="$(PG_PROOF_OPTIONAL=1 PG_REVIEW_PROOF_CUTOFF=1 summary "$r" "$r/memory/reviews/a.md")"
  else
    PG_REVIEW_PROOF_CUTOFF=1 pg_artifact_proven "$r" "$r/memory/reviews/a.md"; rc=$?
    got="$(PG_REVIEW_PROOF_CUTOFF=1 summary "$r" "$r/memory/reviews/a.md")"
  fi
  if [ "$rc" = "$want_rc" ] && [ "$got" = "$want" ]; then
    ok "row $id: rc=$rc [$got] — $bug"
  else
    bad "row $id: want rc=$want_rc [$want], got rc=$rc [$got] — $bug"
  fi
}

echo "=== multi-ref verdict table ==="
row 1 0 "a.txt=good b.txt=trunc" 'adversarial: a.txt\nadversarial: b.txt' 1 \
  "proven=a.txt, truncated=b.txt" "only the first adversarial: line was read"
row 2 0 "a.txt=good b.txt=good" 'adversarial: a.txt, b.txt' 0 \
  "proven=a.txt, proven=b.txt" "a comma list was read as one path"
row 3 0 "a.txt=good b.txt=trunc" 'adversarial: a.txt,b.txt' 1 \
  "proven=a.txt, truncated=b.txt" "a truncated second proof in a comma list was ignored"
row 4 0 "a.txt=weak b.txt=weak" 'adversarial: a.txt, b.txt' 1 \
  "weak=a.txt, weak=b.txt" "REVIEW BY: counts were pooled across proof files"
row 5a 0 "a.txt=good b.txt=blind" 'adversarial: a.txt, b.txt' 1 \
  "proven=a.txt, blind-audit=b.txt" "a blind-audit proof hid behind a good one"
row 5b 0 "a.txt=good" 'adversarial: a.txt, ../x.txt' 1 \
  "proven=a.txt, escapes=../x.txt" "a traversal ref hid behind a good one"
row 5c 0 "a.txt=good" 'adversarial: a.txt, /etc/x.txt' 1 \
  "proven=a.txt, escapes=/etc/x.txt" "an absolute ref hid behind a good one"
row 6a 1 "" 'adversarial: ,' 1 \
  "no-ref=-" "an empty item became missing-optional and was proven in CI"
row 6b 1 "" 'adversarial: , ,' 1 \
  "no-ref=-" "empty items became missing-optional and were proven in CI"
row 7 0 "a.txt=good" 'adversarial: a.txt,,a.txt' 0 \
  "proven=a.txt" "a duplicate ref was evaluated twice or an empty item refused a good proof"
row 8 0 "a.txt=good" 'adversarial: a.txt, gone.txt' 1 \
  "proven=a.txt, missing=gone.txt" "a missing second proof was ignored locally"
row 9 1 "a.txt=good" 'adversarial: a.txt, gone.txt' 0 \
  "proven=a.txt, missing-optional=gone.txt" "CI refused a proof that is merely not checked in"
row 10 1 "b.txt=trunc" 'adversarial: b.txt, gone.txt' 1 \
  "truncated=b.txt, missing-optional=gone.txt" "PG_PROOF_OPTIONAL waived a proof that IS present"
row 11 1 "" 'adversarial: gone1.txt, gone2.txt' 0 \
  "missing-optional=gone1.txt, missing-optional=gone2.txt" "CI parity: every proof absent degrades to content-key"
row 12 0 "a.txt=good" 'adversarial: a.txt\n\nadversarial: pass1=mock(0,0,0) | cross_provider=true' 0 \
  "proven=a.txt" "the reader widened past the header block into the body"
row 13 1 "" 'notes: none\n\nadversarial: pass1=mock(0,0,0) | cross_provider=true' 1 \
  "not-a-path=pass1=mock(0,0,0) | cross_provider=true" \
  "comma-splitting prose yielded fragments CI waives as missing-optional"
row 14 0 "a.txt=good b.txt=good bad.txt=weak" 'adversarial: a.txt,b.txt\r\n\r\nadversarial: bad.txt\r' 0 \
  "proven=a.txt, proven=b.txt" "CR left in refs, or a CR-only line not taken as the header's end"
row 17 0 "a.txt=good b.txt=trunc" 'adversarial: a.txt\nadv-proof: b.txt' 1 \
  "proven=a.txt, truncated=b.txt" "an adv-proof: alias line in the same header was ignored"
row 19 0 "a.txt=good" 'adversarial: `a.txt`' 0 \
  "proven=a.txt" "a backticked ref kept its backticks and resolved to no file"
row 20 0 "a.txt=good" 'notes: none' 1 \
  "no-ref=-" "a post-cutoff artifact with no proof line was proven"
dups="$(i=0; while [ "$i" -lt 100 ]; do printf 'a.txt,'; i=$((i + 1)); done)"
row 22 0 "a.txt=good" "adversarial: $dups" 1 \
  "too-many-refs=-" "duplicate items were not counted, so the split work was unbounded"
row 23 0 "a.txt=good b.txt=good" 'adversarial: a.txt b.txt' 1 \
  "not-a-path=a.txt b.txt" "space-separated refs were read as one missing path and waived in CI"
row 24 0 "b.txt=good" 'adversarial:\nadv-proof: b.txt' 0 \
  "proven=b.txt" "an empty adversarial: line was taken as the anchor and the valued ref lost"
pad="$(i=0; while [ "$i" -lt 4200 ]; do printf ' '; i=$((i + 1)); done)"
row 25 0 "a.txt=good b.txt=trunc" "adversarial: a.txt$pad, b.txt" 1 \
  "too-many-refs=-" "an over-long ref line was cut silently and its trailing ref never checked"
# Root reads a mode-000 file, so the row cannot fail there and is skipped rather than passed.
if [ "$(id -u)" = 0 ]; then
  echo "  - row 28 skipped: running as root, a mode-000 proof is still readable"
else
  row 28 0 "a.txt=good b.txt=unread" 'adversarial: a.txt, b.txt' 1 \
    "proven=a.txt, unreadable=b.txt" "an unreadable second proof hid behind a good first one or was not named"
fi

echo "=== grandfathered artifact (mtime before the cutoff) ==="
r="$TMP/row15"; mkdir -p "$r/memory/reviews"
printf '<!-- zuvo-review -->\nadversarial: gone.txt, ../x\n' > "$r/memory/reviews/a.md"
touch -t 201901010000 "$r/memory/reviews/a.md"
PG_REVIEW_PROOF_CUTOFF=1600000000 pg_artifact_proven "$r" "$r/memory/reviews/a.md"; rc=$?
got="$(PG_REVIEW_PROOF_CUTOFF=1600000000 summary "$r" "$r/memory/reviews/a.md")"
[ "$rc" = 0 ] && [ "$got" = "grandfathered=-" ] \
  && ok "row 15: legacy artifact stays grandfathered whatever its refs say" \
  || bad "row 15: want rc=0 [grandfathered=-], got rc=$rc [$got] — legacy artifact false-blocked"

echo "=== more refs than PG_MAX_PROOF_REFS ==="
r="$TMP/row16"; mkdir -p "$r/memory/reviews"
refs=""; i=1
while [ "$i" -le 17 ]; do mkproof "$r/p$i.txt" good; refs="$refs${refs:+, }p$i.txt"; i=$((i + 1)); done
printf '<!-- zuvo-review -->\nadversarial: %s\n' "$refs" > "$r/memory/reviews/a.md"
PG_REVIEW_PROOF_CUTOFF=1 pg_artifact_proven "$r" "$r/memory/reviews/a.md"; rc=$?
got="$(PG_REVIEW_PROOF_CUTOFF=1 summary "$r" "$r/memory/reviews/a.md")"
[ "$rc" = 1 ] && [ "$got" = "too-many-refs=-" ] \
  && ok "row 16: 17 refs refused once as too-many-refs (unbounded per-artifact work)" \
  || bad "row 16: want rc=1 [too-many-refs=-], got rc=$rc [$got] — the ref cap is not enforced"

echo "=== exactly PG_MAX_PROOF_REFS refs is still allowed (cap boundary) ==="
r="$TMP/row18"; mkdir -p "$r/memory/reviews"
refs=""; want=""; i=1
while [ "$i" -le 16 ]; do
  mkproof "$r/p$i.txt" good; refs="$refs${refs:+, }p$i.txt"; want="$want${want:+, }proven=p$i.txt"; i=$((i + 1))
done
printf '<!-- zuvo-review -->\nadversarial: %s\n' "$refs" > "$r/memory/reviews/a.md"
PG_REVIEW_PROOF_CUTOFF=1 pg_artifact_proven "$r" "$r/memory/reviews/a.md"; rc=$?
got="$(PG_REVIEW_PROOF_CUTOFF=1 summary "$r" "$r/memory/reviews/a.md")"
[ "$rc" = 0 ] && [ "$got" = "$want" ] \
  && ok "row 18: 16 good refs are proven (the cap is not off by one)" \
  || bad "row 18: want rc=0 [$want], got rc=$rc [$got] — the cap refuses at its own limit"

echo "=== a 2000-item duplicate line is refused fast ==="
r="$TMP/row21"; mkdir -p "$r/memory/reviews"; mkproof "$r/a.txt" good
dups="$(i=0; while [ "$i" -lt 2000 ]; do printf 'a.txt,'; i=$((i + 1)); done)"
printf '<!-- zuvo-review -->\nadversarial: %s\n' "$dups" > "$r/memory/reviews/a.md"
start=$SECONDS
PG_REVIEW_PROOF_CUTOFF=1 pg_artifact_proven "$r" "$r/memory/reviews/a.md"; rc=$?
got="$(PG_REVIEW_PROOF_CUTOFF=1 summary "$r" "$r/memory/reviews/a.md")"; took=$((SECONDS - start))
[ "$rc" = 1 ] && [ "$got" = "too-many-refs=-" ] \
  && ok "row 21: 2000 duplicates refused as too-many-refs (took ${took}s; a slow hook is a fail-open hook)" \
  || bad "row 21: want rc=1 [too-many-refs=-], got rc=$rc [$got] — header size is unbounded"

echo "=== a glob character in a ref is matched literally ==="
# Bug: a dedup built as a glob pattern makes `a*` match the earlier `a.txt`, so it is never checked.
r="$TMP/glob"; mkdir -p "$r/memory/reviews"; mkproof "$r/a.txt" good; mkproof "$r/a*" trunc
printf '<!-- zuvo-review -->\nadversarial: a.txt, a*\n' > "$r/memory/reviews/a.md"
PG_REVIEW_PROOF_CUTOFF=1 pg_artifact_proven "$r" "$r/memory/reviews/a.md"; rc=$?
got="$(PG_REVIEW_PROOF_CUTOFF=1 summary "$r" "$r/memory/reviews/a.md")"
[ "$rc" = 1 ] && [ "$got" = "proven=a.txt, truncated=a*" ] \
  && ok "row 26: 'a*' after 'a.txt' is evaluated on its own and refused as truncated" \
  || bad "row 26: want rc=1 [proven=a.txt, truncated=a*], got rc=$rc [$got] — glob dedup skipped a ref"

echo "=== an unreadable mtime is not grandfathered ==="
# Bug: a failing stat became mtime 0, i.e. older than any cutoff, and skipped every proof check.
r="$TMP/nostat"; mkdir -p "$r/memory/reviews" "$TMP/nostat-bin"; mkproof "$r/b.txt" trunc
printf '#!/bin/sh\nexit 1\n' > "$TMP/nostat-bin/stat"; chmod +x "$TMP/nostat-bin/stat"
printf '<!-- zuvo-review -->\nadversarial: b.txt\n' > "$r/memory/reviews/a.md"
( PATH="$TMP/nostat-bin:$PATH" PG_REVIEW_PROOF_CUTOFF=1 pg_artifact_proven "$r" "$r/memory/reviews/a.md" ); rc=$?
got="$(PATH="$TMP/nostat-bin:$PATH" PG_REVIEW_PROOF_CUTOFF=1 summary "$r" "$r/memory/reviews/a.md")"
[ "$rc" = 1 ] && [ "$got" = "truncated=b.txt" ] \
  && ok "row 27: a failing stat leaves the artifact post-cutoff and its proof checked" \
  || bad "row 27: want rc=1 [truncated=b.txt], got rc=$rc [$got] — an unreadable mtime grandfathered the artifact"

echo "=== refs are printed one per line, newline-terminated ==="
# Bug: no trailing newline, so a caller's `while read` loop drops the last ref.
r="$TMP/refs"; mkdir -p "$r"
printf 'adversarial: a.txt, b.txt\n' > "$r/a.md"
got="$(pg_artifact_proof_refs "$r/a.md"; printf x)"
[ "$got" = "a.txt
b.txt
x" ] && ok "pg_artifact_proof_refs ends every ref with a newline" \
  || bad "pg_artifact_proof_refs output [$got] — want 'a.txt<NL>b.txt<NL>'"

echo "=== wiring: the coverage engine sees every ref ==="
# wire_fixture <dir> <kind of b.txt> — a fresh repo whose one artifact covers src/mod.ts and cites a
# good a.txt plus b.txt of the given kind; each check below builds its own.
wire_fixture() {
  mkdir -p "$1/src" "$1/memory/reviews" && cd "$1" || return 1
  git init -q && git config user.email t@t && git config user.name t
  echo "export const a=1" > src/mod.ts; git add -A; git -c commit.gpgsign=false commit -qm base >/dev/null
  echo "export const b=2" >> src/mod.ts; git add -A; git -c commit.gpgsign=false commit -qm work >/dev/null
  WBASE=$(git rev-parse HEAD~1); WHEAD=$(git rev-parse HEAD)
  mkproof "$1/a.txt" good; mkproof "$1/b.txt" "$2"
  printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: a.txt\nadversarial: b.txt\n' \
    "$WBASE" "$WHEAD" > memory/reviews/a.md
}
# Bug: pg_uncovered_files (via the _pgl_proven memo) still reads only the first ref, so a
# truncated second proof grants coverage to the file.
unc="$(wire_fixture "$TMP/wire-trunc" trunc && PG_REVIEW_PROOF_CUTOFF=1 pg_uncovered_files "${WBASE}..${WHEAD}")"; rc=$?
[ "$rc" = 0 ] && [ "$unc" = "src/mod.ts" ] \
  && ok "pg_uncovered_files lists a file whose only artifact cites a truncated second proof" \
  || bad "pg_uncovered_files: want rc=0 [src/mod.ts], got rc=$rc [$unc] — the engine is not wired to the multi-ref verdict"
# Positive control on its own fixture: without it the row above passes when nothing can be covered.
unc="$(wire_fixture "$TMP/wire-good" good && PG_REVIEW_PROOF_CUTOFF=1 pg_uncovered_files "${WBASE}..${WHEAD}")"; rc=$?
[ "$rc" = 0 ] && [ -z "$unc" ] \
  && ok "positive control: with both proofs good a fresh fixture is covered" \
  || bad "positive control: want rc=0 and no uncovered file, got rc=$rc [$unc] — the fixture cannot be covered at all"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
