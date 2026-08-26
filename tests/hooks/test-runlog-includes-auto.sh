#!/usr/bin/env bash
# Field 12 (INCLUDES) expands from `AUTO` inside append-runlog.
#
# Why this exists. The field was hand-composed once per run, from one of TWO commands the same
# document gave: `sort -t: -k1,1 -u` (dedupe by include NAME) and `sort -u` (dedupe by whole LINE).
# They differ whenever one include is recorded twice with different byte counts — the second keeps
# both and the field carries a repeated key. Measured across 4,541 real rows, 97 (2%) do.
#
# Small on its own, and the point is not the 2%: there is no reason for a machine-derivable field to
# be assembled by hand at all, and no reason for a document to give two answers about it.
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
trap 'rm -rf "$TMP" /tmp/zuvo-includes-autotest-*.txt' EXIT

# Run ONLY the expansion block, lifted from the script by its own marker comment. Exercising the
# whole binary would drag in the retro gate, which is a different contract with its own test.
extract_block() {
  awk '/^# Substituted in awk/{f=1} f{print} f&&/^fi$/{exit}' "$BIN"
}

run_case() { # run_case <includes-file-contents> ; echoes field 12
  printf '%s' "$1" > "/tmp/zuvo-includes-autotest-$$.txt"
  {
    printf 'RUN_LINE=$(printf "%%s" %s)\n' "'$LINE'"
    extract_block | sed "s|/tmp/zuvo-includes-\*\.txt|/tmp/zuvo-includes-autotest-$$.txt|"
    printf 'printf "%%s" "$RUN_LINE" | awk -F"\\t" "{print \\$12}"\n'
  } > "$TMP/probe.sh"
  bash "$TMP/probe.sh" 2>/dev/null
}

LINE=$(printf '2026-08-26T10:00:00Z\tbuild\tp\t34/37\t16/19\tPASS\t4\tstandard\tprobe\tmain\tabc1234\tAUTO\tSTANDARD')

# ── 1. AUTO expands, and duplicates collapse BY NAME ─────────────────────────
got=$(run_case 'cq-patterns:27396
env-compat:1538
cq-patterns:27400
')
case "$got" in
  *cq-patterns*env-compat*|*env-compat*cq-patterns*)
    n=$(printf '%s' "$got" | tr '|' '\n' | grep -c '^cq-patterns:')
    [ "$n" -eq 1 ] \
      && pass "AUTO expands and a repeated include appears once, not twice" \
      || bad "cq-patterns appeared $n times — deduped by line, not by name: $got" ;;
  *) bad "AUTO did not expand: '$got'" ;;
esac

# ── 2. the separator inside the VALUE does not break the substitution ────────
# The value is a pipe-separated list. A `sed "s|marker|$value|"` breaks on the first `|` inside it,
# which is exactly how the first version of this failed — caught here rather than in the wild.
printf '%s' "$got" | grep -q '|' \
  && pass "a value containing the field separator survives substitution" \
  || bad "the multi-entry value collapsed: '$got'"

# ── 3. the row keeps its shape ───────────────────────────────────────────────
# runs.log is a strict 13-field TSV and append-runlog rejects anything else, so an expansion that
# adds or drops a field would be rejected downstream with a message about the schema rather than
# about this.
fields=$( { printf 'RUN_LINE=$(printf "%%s" %s)\n' "'$LINE'"
            printf '%s' "$(printf 'a:1\n' > "/tmp/zuvo-includes-autotest-$$.txt"; extract_block | sed "s|/tmp/zuvo-includes-\*\.txt|/tmp/zuvo-includes-autotest-$$.txt|")"
            printf '\nprintf "%%s" "$RUN_LINE" | awk -F"\\t" "{print NF}"\n'; } > "$TMP/p2.sh"; bash "$TMP/p2.sh" 2>/dev/null)
[ "$fields" = "13" ] && pass "the expanded row still has exactly 13 fields" \
  || bad "field count became '$fields' — runs.log requires 13"

# ── 4. no tracker files → the field becomes `-`, never empty ─────────────────
# An empty field 12 would still be 13 columns and would silently read as "no includes recorded"
# rather than "the tracker was not there".
rm -f "/tmp/zuvo-includes-autotest-$$.txt"
got=$( { printf 'RUN_LINE=$(printf "%%s" %s)\n' "'$LINE'"
         extract_block | sed "s|/tmp/zuvo-includes-\*\.txt|/tmp/zuvo-includes-autotest-missing-$$.txt|"
         printf 'printf "%%s" "$RUN_LINE" | awk -F"\\t" "{print \\$12}"\n'; } > "$TMP/p3.sh"; bash "$TMP/p3.sh" 2>/dev/null)
[ "$got" = "-" ] && pass "with no tracker the field is '-', not empty" \
  || bad "field 12 became '$got' with no tracker present"

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
