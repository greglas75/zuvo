#!/usr/bin/env bash
# test-adversarial-flag-contract.sh — every adversarial-review flag a skill DOCUMENTS
# must exist in the script's parser, with the arity the docs use.
#
# Regression under contract (2026-08-07 .. 2026-08-09, six ship retros before anyone fixed it).
# skills/review/SKILL.md §1.3 documented the rotation passes as
#     ... | adversarial-review --rotate --mode code --append-artifact "$ADV_PROOF"
# while the parser's arm was `--append-artifact) APPEND_ARTIFACT=true; shift ;;` — no value.
# The path therefore fell through to `*) Unknown argument` → exit 2, so the pass ran NO review
# and wrote NO proof file. The failure surfaced a phase later as a push blocked for "missing
# adversarial proof", which points at the artifact, not at the flag that never ran. Reported from
# uptime #74, i9-farma, rs_be #263, tgm-survey-tester #49, Helper #97 and stages-actions — six
# independent runs, each re-diagnosing it from scratch, because nothing mechanical compared the
# documented command line against the parser.
#
# This test is that comparison. It also catches the phantom-flag class (`--all-providers`, which
# review/SKILL.md warns about in prose) with no prose required.
#
# Scope/limits, stated so a green run is not over-read:
#   - single-line invocations only (a flag split across a `\` continuation is not checked)
#   - only lines where the command token appears BEFORE the flags, so prose that merely mentions
#     a flag in backticks is ignored
#   - tokenization stops at a shell operator (| > >> ; && ||), so `--help | grep -- --multi`
#     checks `--help` and nothing after the pipe
#
# bash 3.2-compatible (macOS default): no mapfile, no associative arrays.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/adversarial-review.sh"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

if [ ! -f "$SCRIPT" ]; then
  bad "scripts/adversarial-review.sh not found"
  exit 1
fi

# ─── (a) build the flag inventory from the parser itself ─────────────────────
# Classification comes from what the arm does, not from a hand-kept list here — a list would rot
# exactly like the docs did. VALUE = `shift 2` only, BOOL = `shift` only, OPT = both (a flag whose
# value is optional). Arms are `    --flag)` / `    --a|--b)` at the head of the case body.
INVENTORY="$(awk '
  /^[[:space:]]*--[a-z0-9-]+[|)]/ {
    if (flag != "") { emit() }
    line = $0
    sub(/\).*/, "", line); gsub(/[[:space:]]/, "", line)
    flag = line; body = $0; next
  }
  flag != "" { body = body " " $0 }
  /;;[[:space:]]*$/ && flag != "" { emit() }
  function emit(   kind, n, i, parts, total, two, bare, tmp) {
    # Count shifts rather than pattern-matching their position: `shift 2` consumes a value,
    # a bare `shift` does not, and an arm holding BOTH is a flag whose value is optional.
    tmp = body
    total = gsub(/shift/, "shift", tmp)
    tmp = body
    two = gsub(/shift 2/, "shift 2", tmp)
    bare = total - two
    kind = "BOOL"
    if (two > 0 && bare > 0) kind = "OPT"
    else if (two > 0)        kind = "VALUE"
    n = split(flag, parts, "|")
    for (i = 1; i <= n; i++) if (parts[i] ~ /^-/) print parts[i] "\t" kind
    flag = ""; body = ""
  }
' "$SCRIPT" | sort -u)"

# `--append-artifact` takes an OPTIONAL value (canonical: `--artifact P --append-artifact`;
# legacy one-arg alias: `--append-artifact P`). The awk heuristic above can only see shifts, so
# pin the three flags whose contract the tests actually depend on, and fail loudly if the parser
# stops agreeing with the pin.
check_kind() {  # check_kind FLAG EXPECTED
  local got
  got="$(printf '%s\n' "$INVENTORY" | awk -F'\t' -v f="$1" '$1==f {print $2}' | head -1)"
  if [ -z "$got" ]; then
    bad "(a) $1 is not a parser arm in adversarial-review.sh"
  elif [ "$got" != "$2" ]; then
    bad "(a) $1 parses as $got, the docs contract says $2"
  else
    pass "(a) $1 → $2"
  fi
}
check_kind --artifact VALUE
check_kind --append-artifact OPT
check_kind --json BOOL

# ─── (b) documented invocations must type-check against that inventory ───────
kind_of() { printf '%s\n' "$INVENTORY" | awk -F'\t' -v f="$1" '$1==f {print $2}' | head -1; }

_doc_fails=0
_doc_lines=0
for f in "$ROOT"/skills/*/SKILL.md "$ROOT"/skills/*/agents/*.md "$ROOT"/shared/includes/*.md; do
  [ -f "$f" ] || continue
  # Only lines that INVOKE the script. `grep -n` keeps the line number for the failure message.
  while IFS= read -r hit; do
    lineno="${hit%%:*}"
    text="${hit#*:}"
    # keep only what follows the command token
    rest="${text#*adversarial-review}"
    # cut at the first shell operator — anything after it is a different command
    rest="$(printf '%s' "$rest" | sed 's/[|;>&].*//')"
    # strip markdown/quoting noise so `--artifact "$P"` tokenizes as two words
    rest="$(printf '%s' "$rest" | tr '`"'"'" '   ')"
    _doc_lines=$((_doc_lines + 1))
    set -- $rest
    while [ "$#" -gt 0 ]; do
      tok="$1"
      # A token that is pure punctuation means the line stopped being a command and became
      # prose ("run `... --doctor`, then read the output"). Stop rather than read the comma
      # as an argument — otherwise every sentence mentioning a flag reads as a defect.
      [ -n "$(printf '%s' "$tok" | tr -d '.,;:()')" ] || break
      case "$tok" in
        --*)
          k="$(kind_of "$tok")"
          nxt="${2:-}"
          # trailing prose punctuation is not an argument
          [ -n "$(printf '%s' "$nxt" | tr -d '.,;:()')" ] || nxt=""
          case "$k" in
            "")
              bad "(b) ${f#"$ROOT"/}:$lineno documents $tok — no such flag in the parser (phantom flag → exit 2, zero coverage)"
              _doc_fails=$((_doc_fails + 1)) ;;
            BOOL)
              case "$nxt" in
                ""|--*) ;;
                *) bad "(b) ${f#"$ROOT"/}:$lineno passes a value to the boolean flag $tok ('$nxt') — the parser rejects it with 'Unknown argument: $nxt' and the whole pass exits 2"
                   _doc_fails=$((_doc_fails + 1)) ;;
              esac ;;
            VALUE)
              case "$nxt" in
                ""|--*) bad "(b) ${f#"$ROOT"/}:$lineno uses $tok with no value — the parser requires one"
                        _doc_fails=$((_doc_fails + 1)) ;;
              esac ;;
          esac ;;
      esac
      shift
    done
  done <<EOF
$(grep -n 'adversarial-review' "$f" 2>/dev/null | grep -v 'adversarial-review\.sh"\?$')
EOF
done

if [ "$_doc_lines" -eq 0 ]; then
  bad "(b) scanned zero invocation lines — the scan is broken, not the docs"
elif [ "$_doc_fails" -eq 0 ]; then
  pass "(b) $_doc_lines documented invocation lines type-check against the parser"
fi

# ─── (c) the canonical proof pair must survive a real parse ──────────────────
# (a) and (b) are static. This runs the script for both accepted shapes and for the
# conflicting one, because "the arm exists" and "the command works" are different claims.
_t="$(mktemp -d)"
trap 'rm -rf "$_t"' EXIT
_in='diff --git a/x b/x
+foo'

printf '%s\n' "$_in" | bash "$SCRIPT" --dry-run --mode code --artifact "$_t/p.txt" --append-artifact >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "(c) canonical '--artifact P --append-artifact' parses" \
               || bad "(c) canonical '--artifact P --append-artifact' does NOT parse"

printf '%s\n' "$_in" | bash "$SCRIPT" --dry-run --mode code --append-artifact "$_t/p.txt" >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "(c) legacy alias '--append-artifact P' parses" \
               || bad "(c) legacy alias '--append-artifact P' does NOT parse — every already-written retro and cached skill copy uses this shape"

printf '%s\n' "$_in" | bash "$SCRIPT" --dry-run --mode code --artifact "$_t/a.txt" --append-artifact "$_t/b.txt" >/dev/null 2>&1
[ "$?" -eq 2 ] && pass "(c) two DIFFERENT artifact paths is a loud error, not a silent pick" \
               || bad "(c) conflicting --artifact/--append-artifact paths did not exit 2"

# ─── (d) the DOCS must teach the canonical pair, not the tolerated alias ─────
# The parser accepts `--append-artifact PATH` so that six retros' worth of muscle memory and every
# stale cached skill copy keep working. That tolerance is a compatibility shim, not the contract:
# a doc example teaching the one-arg form re-teaches the shape that had no proof-of-work behind it
# for two days. Every documented line that appends must also name the artifact it appends to.
_d_fails=0
for f in "$ROOT"/skills/*/SKILL.md "$ROOT"/skills/*/agents/*.md "$ROOT"/shared/includes/*.md; do
  [ -f "$f" ] || continue
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    lineno="${hit%%:*}"; text="${hit#*:}"
    case "$text" in
      *--append-artifact*)
        case "$text" in
          *--artifact*) ;;
          *) bad "(d) ${f#"$ROOT"/}:$lineno documents --append-artifact without --artifact — write the canonical '--artifact P --append-artifact' pair"
             _d_fails=$((_d_fails + 1)) ;;
        esac ;;
    esac
  done <<EOF
$(grep -n 'adversarial-review.*--append-artifact' "$f" 2>/dev/null)
EOF
done
[ "$_d_fails" -eq 0 ] && pass "(d) every documented append passes --artifact alongside it"

exit "$fail"
