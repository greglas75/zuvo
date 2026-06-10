#!/usr/bin/env bash
# Security-corpus detection scorer.
#
# zuvo:pentest and zuvo:security-audit are LLM skills, NOT CLIs — bash cannot
# invoke them. So this is a SCORER, not a skill-runner. A separate (agent or
# manual) step runs the skills on each fixture and dumps the resulting
# findings.json as  <findings_dir>/<class>-vulnerable.json  and
# <findings_dir>/<class>-clean.json . This script then asserts, per manifest:
#   - the vulnerable twin's findings contain the expected finding_type  (true positive)
#   - the clean twin's findings do NOT contain it                       (no false positive)
# Exit 0 iff every manifested class passes both checks.
#
# A scorer's cardinal sin is a false GREEN. So: a malformed manifest, an
# unreadable/invalid findings file, or zero evaluated classes all FAIL loudly —
# never silently pass.
#
# Usage:
#   run.sh [--manifest <path>] [--findings <dir>] [--classes a,b,c]
#   run.sh --self-test          # meta-check: prove the scorer logic itself works
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$HERE/manifest.json"
FINDINGS_DIR=""
CLASSES_FILTER=""
SELF_TEST=0
REQUIRE_PROV=0   # --require-provenance: absent source_fixture FAILS (not warns).
                 # The CI/smoke gate (Task 18) runs strict; incremental task runs default lax.

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)            MANIFEST="$2"; shift 2 ;;
    --findings)            FINDINGS_DIR="$2"; shift 2 ;;
    --classes)             CLASSES_FILTER=",$2,"; shift 2 ;;
    --require-provenance)  REQUIRE_PROV=1; shift ;;
    --self-test)           SELF_TEST=1; shift ;;
    *) echo "run.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "run.sh: jq required" >&2; exit 2; }

# valid_findings <file> -> 0 iff the file parses as JSON AND `.findings` is an array.
# A non-array .findings (e.g. {"findings":"x"}) parses but is not real skill output.
valid_findings() { jq -e '(.findings | type) == "array"' -- "$1" >/dev/null 2>&1; }

# has_type <findings.json> <finding_type> -> 0 if any finding carries it under
# `.type` OR `.finding_type`. Both keys are checked independently — a present-but-
# different `.type` must NOT mask a correct `.finding_type` (so `or`, not `//`).
has_type() { jq -e --arg t "$2" 'any(.findings[]?; .type == $t or .finding_type == $t)' -- "$1" >/dev/null 2>&1; }

# provenance <findings.json> <expected_fixture_path> -> 0 unless an explicit
# `.meta.source_fixture` is present AND mismatches the manifest path. Absent
# provenance warns (Tasks 6/7 skill-run step should populate it) but does not
# block; a PRESENT-and-WRONG source is a hard fail — that is the anti-fake-green bind.
provenance() { # <file> <expected>
  local got="" exp="$2"
  got="$(jq -r '.meta.source_fixture // empty' -- "$1" 2>/dev/null)"
  if [ -z "$got" ]; then return 2; fi          # absent -> caller warns
  got="${got%/}"; exp="${exp%/}"               # normalize trailing slash
  # Precise path-suffix match at a path boundary — NOT a loose substring, so
  # "xxe/vulnerable_FAKE" or "fake-xxe/vulnerable" do NOT satisfy "xxe/vulnerable".
  case "$got" in "$exp"|*"/$exp") return 0 ;; *) return 1 ;; esac
}

score() { # <manifest> <findings_dir>
  local man="$1" fdir="$2" rc=0 n=0 pass=0 rows
  # Read manifest via a var with an explicit exit-code check — NOT process
  # substitution, which would mask a jq parse failure and exit 0 (false green).
  rows="$(jq -r '.classes[] | [.class, .finding_type] | @tsv' "$man")" \
    || { echo "FATAL $man: manifest is not valid JSON / unreadable" >&2; return 1; }
  local cls ft v c
  while IFS=$'\t' read -r cls ft; do
    [ -n "$cls" ] || continue
    [ -n "$CLASSES_FILTER" ] && case "$CLASSES_FILTER" in *",$cls,"*) ;; *) continue ;; esac
    n=$((n+1))
    v="$fdir/$cls-vulnerable.json"; c="$fdir/$cls-clean.json"
    if [ ! -f "$v" ] || [ ! -f "$c" ]; then
      echo "MISS  $cls: findings json absent (run the skill on this fixture first)"; rc=1; continue
    fi
    if ! valid_findings "$v" || ! valid_findings "$c"; then
      echo "BADJSON $cls: a findings file is not valid skill output (.findings not an array) — NOT a clean pass"; rc=1; continue
    fi
    # Provenance bind (anti-fake-green): a present-but-wrong source_fixture fails;
    # absent provenance warns so a hand-written findings file is at least visible.
    local vp cp
    vp="$(jq -r --arg k "$cls" '.classes[]|select(.class==$k)|.vulnerable_path' "$man")"
    cp="$(jq -r --arg k "$cls" '.classes[]|select(.class==$k)|.clean_path' "$man")"
    local pv=0
    provenance "$v" "$vp"; case $? in
      1) echo "PROV  $cls: vulnerable findings.source_fixture != $vp"; rc=1; pv=1 ;;
      2) if [ "$REQUIRE_PROV" = 1 ]; then echo "PROV  $cls: vulnerable findings has no .meta.source_fixture (strict)"; rc=1; pv=1
         else echo "warn  $cls: vulnerable findings has no .meta.source_fixture (provenance unverified)"; fi ;;
    esac
    provenance "$c" "$cp"; case $? in
      1) echo "PROV  $cls: clean findings.source_fixture != $cp"; rc=1; pv=1 ;;
      2) if [ "$REQUIRE_PROV" = 1 ]; then echo "PROV  $cls: clean findings has no .meta.source_fixture (strict)"; rc=1; pv=1
         else echo "warn  $cls: clean findings has no .meta.source_fixture (provenance unverified)"; fi ;;
    esac
    [ "$pv" = 1 ] && continue
    if ! has_type "$v" "$ft"; then echo "FN    $cls: vulnerable twin missing '$ft'"; rc=1; continue; fi
    if has_type "$c" "$ft";  then echo "FP    $cls: clean twin wrongly flagged '$ft'"; rc=1; continue; fi
    echo "OK    $cls ($ft)"; pass=$((pass+1))
  done <<< "$rows"
  if [ "$n" -eq 0 ]; then
    echo "FATAL: 0 classes evaluated (empty manifest or --classes matched nothing) — refusing to report green" >&2
    return 1
  fi
  echo "----- $pass/$n classes detected cleanly -----"
  return $rc
}

self_test() {
  local tmp man fdir; tmp="$(mktemp -d)" || { echo "SELF-TEST FAIL: mktemp"; return 1; }
  trap 'rm -rf "$tmp"' RETURN
  man="$tmp/m.json"; fdir="$tmp/f"; mkdir -p "$fdir"
  printf '{"classes":[{"class":"st","finding_type":"st_v","vulnerable_path":"x","clean_path":"y","stack":"generic"}]}' > "$man"
  printf '{"findings":[{"type":"st_v"}]}' > "$fdir/st-vulnerable.json"
  printf '{"findings":[]}'                > "$fdir/st-clean.json"
  score "$man" "$fdir" >/dev/null 2>&1 || { echo "SELF-TEST FAIL: rejected a correct pair"; return 1; }
  # alternate key spelling must also be detected
  printf '{"findings":[{"finding_type":"st_v"}]}' > "$fdir/st-vulnerable.json"
  score "$man" "$fdir" >/dev/null 2>&1 || { echo "SELF-TEST FAIL: did not honor .finding_type key"; return 1; }
  printf '{"findings":[]}' > "$fdir/st-vulnerable.json"
  score "$man" "$fdir" >/dev/null 2>&1 && { echo "SELF-TEST FAIL: accepted a false negative"; return 1; }
  printf '{"findings":[{"type":"st_v"}]}' > "$fdir/st-vulnerable.json"
  printf '{"findings":[{"type":"st_v"}]}' > "$fdir/st-clean.json"
  score "$man" "$fdir" >/dev/null 2>&1 && { echo "SELF-TEST FAIL: accepted a false positive"; return 1; }
  # invalid JSON on the clean twin must FAIL, not pass as "clean"
  printf '{"findings":[{"type":"st_v"}]}' > "$fdir/st-vulnerable.json"
  printf 'NOT JSON{'                      > "$fdir/st-clean.json"
  score "$man" "$fdir" >/dev/null 2>&1 && { echo "SELF-TEST FAIL: invalid-JSON twin scored as clean"; return 1; }
  # non-array .findings parses as JSON but is not real skill output → FAIL
  printf '{"findings":[{"type":"st_v"}]}' > "$fdir/st-vulnerable.json"
  printf '{"findings":"st_v"}'            > "$fdir/st-clean.json"
  score "$man" "$fdir" >/dev/null 2>&1 && { echo "SELF-TEST FAIL: non-array .findings scored as clean"; return 1; }
  # present-but-WRONG provenance must FAIL (anti-fake-green); a stale source_fixture
  printf '{"meta":{"source_fixture":"WRONG/path"},"findings":[{"type":"st_v"}]}' > "$fdir/st-vulnerable.json"
  printf '{"findings":[]}'                                                        > "$fdir/st-clean.json"
  score "$man" "$fdir" >/dev/null 2>&1 && { echo "SELF-TEST FAIL: wrong source_fixture scored as pass"; return 1; }
  # substring-evasion: a path that merely CONTAINS the expected must NOT pass
  # (manifest vulnerable_path for class st is "x"; "x_FAKE" must be rejected)
  printf '{"meta":{"source_fixture":"x_FAKE"},"findings":[{"type":"st_v"}]}' > "$fdir/st-vulnerable.json"
  printf '{"findings":[]}'                                                   > "$fdir/st-clean.json"
  score "$man" "$fdir" >/dev/null 2>&1 && { echo "SELF-TEST FAIL: substring-evasion source_fixture scored as pass"; return 1; }
  # a correct path-suffix provenance must PASS
  printf '{"meta":{"source_fixture":"tests/security-corpus/x"},"findings":[{"type":"st_v"}]}' > "$fdir/st-vulnerable.json"
  printf '{"meta":{"source_fixture":"tests/security-corpus/y"},"findings":[]}'                 > "$fdir/st-clean.json"
  score "$man" "$fdir" >/dev/null 2>&1 || { echo "SELF-TEST FAIL: correct path-suffix provenance rejected"; return 1; }
  # --require-provenance: absent source_fixture must FAIL (closes the fabricated-findings hole)
  printf '{"findings":[{"type":"st_v"}]}' > "$fdir/st-vulnerable.json"
  printf '{"findings":[]}'                > "$fdir/st-clean.json"
  ( REQUIRE_PROV=1; score "$man" "$fdir" >/dev/null 2>&1 ) && { echo "SELF-TEST FAIL: strict mode passed absent provenance"; return 1; }
  echo "SELF-TEST PASS: FN + FP + bad-JSON + non-array + dual-key + bad-provenance caught; correct pair accepted"; return 0
}

if [ "$SELF_TEST" = 1 ]; then self_test; exit $?; fi
[ -n "$FINDINGS_DIR" ] || { echo "run.sh: --findings <dir> required (or --self-test)" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "run.sh: manifest not found: $MANIFEST" >&2; exit 2; }
score "$MANIFEST" "$FINDINGS_DIR"
