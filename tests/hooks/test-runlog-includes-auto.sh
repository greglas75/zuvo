#!/usr/bin/env bash
# Field 12 (INCLUDES) expands from `AUTO` inside append-runlog — and refuses to guess.
#
# Why this exists. The field was hand-composed once per run, from one of TWO commands the same
# document gave: `sort -t: -k1,1 -u` (dedupe by include NAME) and `sort -u` (dedupe by whole LINE).
# They differ whenever one include is recorded twice with different byte counts. Measured across
# 4,541 real rows, 97 (2%) do.
#
# The second contract is the one review added, and it is the more important one. The tracker is
# `/tmp/zuvo-includes-<session_id>.txt`, nothing ever deletes those, and this helper does not know
# its own session id — so a bare glob folds EVERY session that ever ran on this machine into one
# run's row. Two reviewers found it independently and it reproduced on the spot. runs.log is
# append-only: a merged row cannot be corrected and cannot be distinguished from a correct one.
# So ambiguity must resolve to `-`, never to a merge.
#
# The trackers live inside the per-test $TMP, not in /tmp under a PID-predictable name. The previous
# version trapped `rm -rf /tmp/zuvo-includes-autotest-*.txt`, which deletes a CONCURRENT test run's
# files — flagged CRITICAL by two providers, and this suite does run in parallel.
#
# bash 3.2-compatible (macOS default).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/scripts/zuvo-home/append-runlog"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

[ -f "$BIN" ] || { bad "scripts/zuvo-home/append-runlog does not exist"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT          # only this run's directory — never a shared wildcard
TRACKDIR="$TMP/trackers"
mkdir -p "$TRACKDIR"

LINE=$(printf '2026-08-26T10:00:00Z\tbuild\tp\t34/37\t16/19\tPASS\t4\tstandard\tprobe\tmain\tabc1234\tAUTO\tSTANDARD')

# Run ONLY the expansion block, lifted from the script by its own markers, with the production glob
# repointed at this run's directory. Exercising the whole binary would drag in the retro gate, which
# is a different contract with its own test.
#
# The extraction is bounded by an explicit END marker rather than by the first `^fi$`: the block now
# contains nested `if`s, and the old first-`fi` rule would truncate it into a syntax error that
# `2>/dev/null` then hid. Both were reported as WARNINGs; this is the fix for the pair.
extract_block() {
  awk '/^# Substituted in awk/{f=1} f{print} f&&/^# END AUTO-EXPANSION$/{exit}' "$BIN" \
    | sed "s|/tmp/zuvo-includes-\*\.txt|$TRACKDIR/zuvo-includes-*.txt|g"
}

run_block() {   # run_block  → echoes field 12; stderr captured in $TMP/err
  {
    printf 'RUN_LINE=$(printf "%%s" %s)\n' "'$LINE'"
    extract_block
    printf 'printf "%%s" "$RUN_LINE" | awk -F"\\t" "{print \\$12}"\n'
  } > "$TMP/probe.sh"
  # Guard the substitution itself: if the glob in append-runlog is ever renamed, the sed above
  # silently no-ops and every case below would run against the REAL /tmp, quietly reading other
  # sessions' files and reporting a pass. Assert the rewrite landed before trusting any result.
  if ! grep -q "$TRACKDIR" "$TMP/probe.sh"; then
    bad "the tracker path was not substituted — the block's glob must have been renamed"
    return 1
  fi
  bash "$TMP/probe.sh" 2> "$TMP/err"     # stderr kept, not discarded
}

# ── 1. one tracker: AUTO expands, duplicates collapse BY NAME ────────────────
printf 'cq-patterns:27396\nenv-compat:1538\ncq-patterns:27400\n' > "$TRACKDIR/zuvo-includes-one.txt"
got=$(run_block)
case "$got" in
  *cq-patterns*env-compat*|*env-compat*cq-patterns*)
    n=$(printf '%s' "$got" | tr '|' '\n' | grep -c '^cq-patterns:')
    [ "$n" -eq 1 ] \
      && pass "AUTO expands and a repeated include appears once, not twice" \
      || bad "cq-patterns appeared $n times — deduped by line, not by name: $got" ;;
  *) bad "AUTO did not expand: '$got' (stderr: $(cat "$TMP/err"))" ;;
esac

# ── 2. the separator inside the VALUE does not break the substitution ────────
printf '%s' "$got" | grep -q '|' \
  && pass "a value containing the field separator survives substitution" \
  || bad "the multi-entry value collapsed: '$got'"

# ── 3. the row keeps its shape ───────────────────────────────────────────────
fields=$( { printf 'RUN_LINE=$(printf "%%s" %s)\n' "'$LINE'"
            extract_block
            printf 'printf "%%s" "$RUN_LINE" | awk -F"\\t" "{print NF}"\n'; } > "$TMP/p2.sh"
          bash "$TMP/p2.sh" 2>/dev/null )
[ "$fields" = "13" ] && pass "the expanded row still has exactly 13 fields" \
  || bad "field count became '$fields' — runs.log requires 13"

# ── 4. TWO trackers: refuse to guess ─────────────────────────────────────────
# The whole point. Before this, a second session's file was silently merged into this row.
printf 'other-session:999\n' > "$TRACKDIR/zuvo-includes-two.txt"
got=$(run_block)
[ "$got" = "-" ] \
  && pass "two trackers → '-' rather than a silent merge of another session's includes" \
  || bad "field 12 became '$got' with two trackers present — the merge bug is back"
grep -q "cannot tell which belongs to this run" "$TMP/err" \
  && pass "the ambiguous case explains itself on stderr" \
  || bad "no diagnostic printed when the tracker was ambiguous"

# ── 5. an explicit ZUVO_INCLUDES_FILE wins over the glob ─────────────────────
# The escape for a caller that DOES know its session — and it must work while the glob is ambiguous,
# which is the only situation where it matters.
printf 'explicit:42\n' > "$TMP/explicit.txt"
got=$(ZUVO_INCLUDES_FILE="$TMP/explicit.txt" run_block)
[ "$got" = "explicit:42" ] \
  && pass "ZUVO_INCLUDES_FILE is used verbatim even when the glob is ambiguous" \
  || bad "explicit tracker ignored — got '$got'"

# ── 6. no tracker at all → '-', never empty ──────────────────────────────────
# An empty field 12 would still be 13 columns and would read as "no includes recorded" rather than
# "the tracker was not there".
rm -f "$TRACKDIR"/zuvo-includes-*.txt
got=$(run_block)
[ "$got" = "-" ] && pass "with no tracker the field is '-', not empty" \
  || bad "field 12 became '$got' with no tracker present"

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
