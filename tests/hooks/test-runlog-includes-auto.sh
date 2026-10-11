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
  echo 'set -eu'   # append-runlog runs under set -eu; the lifted block must see the same options
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
  # sessions' files and reporting a pass.
  #
  # The guard RETURNS non-zero; it does not call `bad` itself. Every caller runs this function
  # inside `$( )`, which is a subshell — a `fail=1` set in there dies with it, so the guard would
  # have been unable to fail the suite. That is the same shape as the defects this suite exists to
  # catch, which is why it is spelled out rather than quietly fixed.
  grep -q "$TRACKDIR" "$TMP/probe.sh" || return 3
  bash "$TMP/probe.sh" 2> "$TMP/err"     # stderr kept, not discarded
}

# ── 1. one tracker: AUTO expands, duplicates collapse BY NAME ────────────────
printf 'cq-patterns:27396\nenv-compat:1538\ncq-patterns:27400\n' > "$TRACKDIR/zuvo-includes-one.txt"
got=$(run_block); rc=$?
[ "$rc" = 3 ] && bad "the tracker path was not substituted — append-runlog's glob must have been renamed"
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
got=$(run_block); rc=$?
[ "$rc" = 3 ] && bad "substitution guard tripped in the two-tracker case"
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
got=$(ZUVO_INCLUDES_FILE="$TMP/explicit.txt" run_block); rc=$?
[ "$rc" = 3 ] && bad "substitution guard tripped in the explicit-file case"
[ "$got" = "explicit:42" ] \
  && pass "ZUVO_INCLUDES_FILE is used verbatim even when the glob is ambiguous" \
  || bad "explicit tracker ignored — got '$got'"

# ── 5a. ZUVO_INCLUDES_FILE naming a file that does not exist → '-', not a foreign tracker ──
# Bug: a session that has read no include yet (or whose idle tracker was pruned) has an exported
# name with no file behind it; falling through to the glob folds the one other session's tracker
# into this run's append-only row.
rm -f "$TRACKDIR"/zuvo-includes-*.txt
printf 'foreign-only:7\n' > "$TRACKDIR/zuvo-includes-foreign-only.txt"
got=$(ZUVO_INCLUDES_FILE="$TMP/not-yet-written.txt" run_block); rc=$?
[ "$rc" = 3 ] && bad "substitution guard tripped in the missing-named-file case"
[ "$got" = "-" ] \
  && pass "ZUVO_INCLUDES_FILE naming a missing file → '-', never another session's tracker" \
  || bad "field 12 became '$got' — a named-but-missing tracker fell through to the glob"

# ── 5b. a field 12 that is NOT `AUTO` must survive untouched ─────────────────
# The safety property the whole feature rests on: expansion is opt-in per row, so a caller that
# composed its own INCLUDES value must get that value back. Only the `AUTO` branch was ever
# exercised, so a block that clobbered a real value would have passed this suite — the same shape
# as the merge bug in case 4, just from the other direction.
MANUAL=$(printf '2026-08-26T10:00:00Z\tbuild\tp\t34/37\t16/19\tPASS\t4\tstandard\tprobe\tmain\tabc1234\thand:1|written:2\tSTANDARD')
printf 'should-not-appear:1\n' > "$TRACKDIR/zuvo-includes-one.txt"
got=$( { printf 'RUN_LINE=$(printf "%%s" %s)\n' "'$MANUAL'"
         extract_block
         printf 'printf "%%s" "$RUN_LINE" | awk -F"\\t" "{print \\$12}"\n'; } > "$TMP/p4.sh"
       bash "$TMP/p4.sh" 2>/dev/null )
[ "$got" = "hand:1|written:2" ] \
  && pass "a field 12 that is not AUTO is left exactly as the caller wrote it" \
  || bad "a hand-written INCLUDES value was rewritten to '$got'"

# ── 6. no tracker at all → '-', never empty ──────────────────────────────────
# An empty field 12 would still be 13 columns and would read as "no includes recorded" rather than
# "the tracker was not there".
rm -f "$TRACKDIR"/zuvo-includes-*.txt
got=$(run_block); rc=$?
[ "$rc" = 3 ] && bad "substitution guard tripped in the no-tracker case"
[ "$got" = "-" ] && pass "with no tracker the field is '-', not empty" \
  || bad "field 12 became '$got' with no tracker present"

# ── 7. session-start names this session's tracker in CLAUDE_ENV_FILE ────────
# Without it nothing sets ZUVO_INCLUDES_FILE, and with concurrent sessions AUTO can only yield `-`.
SID="rd1039-$$"
mkdir -p "$TMP/home" "$TMP/zuvo-home"
run_ss() {   # run_ss <env-file or ""> < stdin → stdout of the real hook, sandboxed HOME/ZUVO_HOME
  ( cd "$TMP" && env -u CURSOR_PLUGIN_ROOT -u CODEX_PLUGIN_ROOT -u GEMINI_PROJECT_DIR -u ZUVO_OUTPUT_DIR \
      HOME="$TMP/home" ZUVO_HOME="$TMP/zuvo-home" GIT_CONFIG_GLOBAL=/dev/null \
      CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_ENV_FILE="$1" bash "$ROOT/hooks/session-start" )
}
ss_input() { printf '{"session_id":"%s","source":"startup"}' "$1" > "$TMP/ss-in.json"; }

ss_input "$SID"
run_ss "" < "$TMP/ss-in.json" > "$TMP/ss-plain.out" 2>/dev/null
run_ss "$TMP/env" < "$TMP/ss-in.json" > "$TMP/ss-env.out" 2>/dev/null; rc=$?
run_ss "$TMP/env" < "$TMP/ss-in.json" > /dev/null 2>&1          # clear/compact re-runs on the same file
want="export ZUVO_INCLUDES_FILE='/tmp/zuvo-includes-$SID.txt'"
[ "$rc" = 0 ] && [ "$(cat "$TMP/env" 2>/dev/null)" = "$want" ] \
  && pass "(a) session-start writes exactly one export naming this session's tracker" \
  || bad "(a) env file after two starts: '$(cat "$TMP/env" 2>/dev/null)' (rc=$rc)"
# Guard against a vacuous match: two crashed runs would also compare equal.
python3 -c 'import json,sys; json.load(open(sys.argv[1]))["hookSpecificOutput"]' "$TMP/ss-plain.out" 2>/dev/null \
  && cmp -s "$TMP/ss-plain.out" "$TMP/ss-env.out" \
  && pass "(a) the context payload on stdout is byte-identical with and without CLAUDE_ENV_FILE" \
  || bad "(a) stdout differs or is not the JSON payload — the env block leaked onto stdout"

for unsafe in '../x' "a'b"; do
  ss_input "$unsafe"
  run_ss "$TMP/env-unsafe" < "$TMP/ss-in.json" > /dev/null 2>&1
done
! grep -q ZUVO_INCLUDES_FILE "$TMP/env-unsafe" 2>/dev/null \
  && pass "(b) session ids that could leave /tmp or break the quoting write no export" \
  || bad "(b) an unsafe session id reached the env file: $(cat "$TMP/env-unsafe")"

# Bug: an id that fails the allowlist reaches a /tmp path or the env file.
for name in no-key non-json numeric empty id-129-chars trailing-newline; do
  case "$name" in
    no-key)           payload='{"source":"startup"}' ;;
    non-json)         payload='not json at all' ;;
    numeric)          payload='{"session_id":12345}' ;;
    empty)            payload='{"session_id":""}' ;;
    id-129-chars)     payload=$(printf '{"session_id":"%s"}' "$(printf 'a%.0s' $(seq 1 129))") ;;
    trailing-newline) payload='{"session_id":"abc\n"}' ;;
  esac
  printf '%s' "$payload" > "$TMP/ss-in.json"
  run_ss "$TMP/env-bad-$name" < "$TMP/ss-in.json" > "$TMP/ss-bad.out" 2>/dev/null
  ! grep -q ZUVO_INCLUDES_FILE "$TMP/env-bad-$name" 2>/dev/null && cmp -s "$TMP/ss-plain.out" "$TMP/ss-bad.out" \
    && pass "(b) payload '$name' writes no export and leaves stdout unchanged" \
    || bad "(b) payload '$name' wrote '$(cat "$TMP/env-bad-$name" 2>/dev/null)' or changed stdout"
done

ss_input "$SID"
run_ss "$TMP/no-such-dir/env" < "$TMP/ss-in.json" > "$TMP/ss-nodir.out" 2>/dev/null; rc=$?
[ "$rc" = 0 ] && cmp -s "$TMP/ss-plain.out" "$TMP/ss-nodir.out" \
  && pass "(b) an unwritable env file does not cost the session its context payload" \
  || bad "(b) unwritable CLAUDE_ENV_FILE failed the hook (rc=$rc) or changed its stdout"

printf 'export FOO=bar' > "$TMP/env-nonl"
run_ss "$TMP/env-nonl" < "$TMP/ss-in.json" > /dev/null 2>&1
got=$( . "$TMP/env-nonl" 2>/dev/null; printf '%s|%s' "${FOO:-}" "${ZUVO_INCLUDES_FILE:-}" )
[ "$got" = "bar|/tmp/zuvo-includes-$SID.txt" ] \
  && pass "(b) an env file without a trailing newline keeps its export and gains ours as a separate line" \
  || bad "(b) the two exports merged into one line — sourcing gave '$got'"

# The fifo is opened read-write first, so the open cannot block and the timing measures the read.
mkfifo "$TMP/held-stdin"
exec 3<>"$TMP/held-stdin"
t0=$(date +%s)
run_ss "$TMP/env-held" <&3 > /dev/null 2>&1; rc=$?
t1=$(date +%s)
exec 3>&-
[ "$rc" = 0 ] && [ $((t1 - t0)) -le 4 ] \
  && pass "(c) stdin held open without EOF: session-start still returns within 4 s" \
  || bad "(c) session-start took $((t1 - t0)) s (rc=$rc) on a stdin that never closes"

# ── 8. end to end: the exported name selects this session among several trackers ──
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: (d)/(e) NOT VERIFIED on this host — track-includes.sh needs jq, which is missing"
else
  TI_COPY="$TMP/track-includes.sh"
  sed "s|^_inc_dir=/tmp\$|_inc_dir=$TRACKDIR|" "$ROOT/hooks/track-includes.sh" > "$TI_COPY"
  mkdir -p "$TMP/plugin/shared/includes"
  printf 'x%.0s' $(seq 1 42) > "$TMP/plugin/shared/includes/demo.md"
  read_as() { printf '{"session_id":"%s","tool_input":{"file_path":"%s"}}' "$1" "$TMP/plugin/shared/includes/demo.md" \
                | bash "$TI_COPY"; }
  envline=$(cat "$TMP/env" 2>/dev/null)
  # Same rule as run_block's guard: an unrepointed copy would write and prune in the real /tmp.
  if ! grep -q "$TRACKDIR" "$TI_COPY" || grep -q '/tmp/zuvo-includes' "$TI_COPY"; then
    bad "(d)(e) track-includes.sh has no single _inc_dir=/tmp to repoint — no seam, no prune"
  else
    case "$envline" in
      "export ZUVO_INCLUDES_FILE='/tmp/"*)
        printf '%s\n' "$envline" | sed "s|='/tmp/|='$TRACKDIR/|" > "$TMP/env.local"
        read_as "$SID"
        printf 'foreign:1\n' > "$TRACKDIR/zuvo-includes-foreign-a.txt"
        printf 'foreign:2\n' > "$TRACKDIR/zuvo-includes-foreign-b.txt"
        got=$(. "$TMP/env.local" && run_block); rc=$?
        [ "$rc" != 3 ] && [ "$got" = "demo:42" ] \
          && pass "(d) with 3 trackers the sourced env file makes INCLUDES this session's list" \
          || bad "(d) field 12 became '$got' (rc=$rc) with this session's tracker named in the env file" ;;
      *) bad "(d) env file holds no /tmp export to repoint: '$envline'" ;;
    esac

    # ── 9. a new session's first Read prunes trackers idle for more than a day ──
    ago() { python3 -c 'import sys,time; print(time.strftime("%Y%m%d%H%M.%S", time.localtime(time.time() - float(sys.argv[1]) * 3600)))' "$1"; }
    printf 'stale:1\n' > "$TRACKDIR/zuvo-includes-stale.txt"; touch -t "$(ago 48)" "$TRACKDIR/zuvo-includes-stale.txt"
    printf 'live:1\n'  > "$TRACKDIR/zuvo-includes-live.txt";  touch -t "$(ago 23)" "$TRACKDIR/zuvo-includes-live.txt"
    printf 'notes\n'   > "$TRACKDIR/notes-old.txt";           touch -t "$(ago 48)" "$TRACKDIR/notes-old.txt"
    read_as "rd1039-new-$$"
    [ ! -e "$TRACKDIR/zuvo-includes-stale.txt" ] \
      && pass "(e) a tracker idle for 2 days is pruned on a new session's first Read" \
      || bad "(e) the 2-day-old tracker survived — stale trackers keep AUTO ambiguous forever"
    [ -e "$TRACKDIR/zuvo-includes-live.txt" ] && [ -e "$TRACKDIR/zuvo-includes-foreign-a.txt" ] \
      && [ -e "$TRACKDIR/notes-old.txt" ] && [ -e "$TRACKDIR/zuvo-includes-rd1039-new-$$.txt" ] \
      && pass "(e) trackers active within the day, non-tracker files and the new tracker survive the prune" \
      || bad "(e) the prune removed a file it must keep: $(ls "$TRACKDIR")"
  fi
fi

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
