#!/usr/bin/env bash
# install.sh copy verification (B-install-sh-copy-verification).
#
# Every named-script copy in the installer ends in `cp … 2>/dev/null || true`, then the block
# prints `ok "Scripts installed"` unconditionally. The `|| true` is intentional (a partial install
# must not abort the other four hosts) — but combined with an unconditional success line it means a
# FAILED copy is reported as a success, and the first symptom is a skill dying at runtime on a
# missing helper, in another repo, hours later. Same class as the stale-installPath and
# plugin-disabled gotchas: the installer said ✓ and the file was not there.
#
# These assertions pin the fix's two load-bearing properties:
#   * a source that exists but did not reach the destination is LOUD and exits non-zero
#   * a source that does not exist is NOT reported — it was never supposed to be copied, so the
#     check cannot cry wolf on optional files (which is what would get it ignored or deleted)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"
PASS=0; FAIL=0
# NOT named ok()/no(): this test SOURCES install.sh, which defines its own ok()/warn()/fail().
# First cut used ok() and the source silently replaced it — 17 assertions printed install.sh's
# green tick and incremented nothing, so the summary read PASS=1 for a fully passing run. A test
# whose own counter can be overwritten by the thing under test cannot report on it.
# A misspelled helper is not caught by `set -u`: bash prints "command not found", returns 127, and
# the counters never move — so a file full of broken assertions summarises as FAIL=0. That happened
# in this repo (11 assertions calling a helper the file did not define). This makes it a real failure.
command_not_found_handle(){ echo "  FAIL harness: unknown command '$1'"; FAIL=$((FAIL+1)); return 127; }
t_ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
t_no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# install.sh guards its main body so it can be sourced for exactly this purpose.
# shellcheck disable=SC1090
if ! ( set +u; . "$INSTALL" ) >/dev/null 2>&1; then
  t_no "install.sh is not sourceable (main-run guard broken)"; echo "  --- install copy-verify: PASS=$PASS FAIL=$FAIL"; exit 1
fi
t_ok "install.sh sources cleanly without running the install"

# Pull the helper into this shell.
# shellcheck disable=SC1090
set +u; . "$INSTALL" >/dev/null 2>&1; set -u

command -v verify_copied >/dev/null 2>&1 && t_ok "verify_copied is defined" || { t_no "verify_copied missing"; echo "  --- install copy-verify: PASS=$PASS FAIL=$FAIL"; exit 1; }

SRC="$TMP/src"; DST="$TMP/dst"; mkdir -p "$SRC" "$DST"
echo "real content" > "$SRC/present-and-copied.sh"
echo "real content" > "$DST/present-and-copied.sh"
echo "real content" > "$SRC/present-but-lost.sh"          # source exists, never reached dst
echo "real content" > "$SRC/present-but-truncated.sh"
: > "$DST/present-but-truncated.sh"                        # 0 bytes = failed copy
# absent-from-repo.sh exists in neither

# --- 1. the happy path is silent and returns 0 --------------------------------------------------
INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""
if out="$(verify_copied lbl "$SRC" "$DST" present-and-copied.sh 2>&1)"; then
  [ -z "$out" ] && t_ok "a successful copy produces no noise" || t_no "clean case printed: $out"
else
  t_no "clean case returned non-zero"
fi
[ "$INSTALL_VERIFY_MISSING" -eq 0 ] && t_ok "clean case leaves the counter at 0" || t_no "counter moved on a clean case"

# --- 2. THE BUG: source present, destination missing --------------------------------------------
INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""
if verify_copied lbl "$SRC" "$DST" present-but-lost.sh >/dev/null 2>&1; then
  t_no "a lost file returned SUCCESS — this is the defect"
else
  t_ok "a lost file returns non-zero"
fi
[ "$INSTALL_VERIFY_MISSING" -eq 1 ] && t_ok "lost file counted once" || t_no "counter is $INSTALL_VERIFY_MISSING, expected 1"
case "$INSTALL_VERIFY_DETAIL" in *present-but-lost.sh*) t_ok "detail names the missing path";; *) t_no "detail does not name the file";; esac

# --- 3. a 0-byte destination is a failed copy, not a copy -----------------------------------
# `cp` can create the target and then fail (disk full, interrupted). `-e` would call that success.
INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""
verify_copied lbl "$SRC" "$DST" present-but-truncated.sh >/dev/null 2>&1
[ "$INSTALL_VERIFY_MISSING" -eq 1 ] && t_ok "0-byte destination counted as a failure (-s, not -e)" || t_no "empty file accepted as installed"

# --- 4. NO FALSE ALARMS on a file that is not in the repo ---------------------------------------
# This is what keeps the check credible; a verifier that fires on optional files gets ignored.
INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""
if verify_copied lbl "$SRC" "$DST" absent-from-repo.sh >/dev/null 2>&1; then
  t_ok "a file absent from the source is not reported"
else
  t_no "absent source produced a false alarm"
fi
[ "$INSTALL_VERIFY_MISSING" -eq 0 ] && t_ok "absent source leaves the counter at 0" || t_no "false-alarm counter moved"

# --- 5. several missing files accumulate rather than short-circuiting ----------------------------
INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""
verify_copied lbl "$SRC" "$DST" present-but-lost.sh present-but-truncated.sh present-and-copied.sh >/dev/null 2>&1
[ "$INSTALL_VERIFY_MISSING" -eq 2 ] && t_ok "both failures counted, the good file ignored" || t_no "expected 2, got $INSTALL_VERIFY_MISSING"

# --- 6. the installer actually CALLS it, on every host, and exits non-zero -----------------------
src="$(cat "$INSTALL")"
n_calls="$(printf '%s\n' "$src" | grep -c 'verify_copied "' || true)"
[ "$n_calls" -ge 5 ] && t_ok "verify_copied wired into every host block ($n_calls call sites)" || t_no "only $n_calls call sites — a host is unverified"
for h in "codex scripts" "cursor scripts" "antigravity scripts" "kimi scripts"; do
  case "$src" in *"verify_copied \"$h\""*) t_ok "wired: $h";; *) t_no "not wired: $h";; esac
done
case "$src" in *'INSTALL INCOMPLETE'*) t_ok "final summary exists";; *) t_no "no final summary";; esac
# The summary must exit non-zero — printing a red line and exiting 0 leaves CI and callers green,
# which is the same silence in a different colour.
#
# ONE awk, no `| grep -q`: anchored to the CODE line `fail "INSTALL INCOMPLETE` (never a comment —
# several comments elsewhere in the file mention those two words without the `fail "` prefix, and
# an anchor on the bare phrase pulled in ~2200 unrelated lines, including a comment near :742 that
# itself contains the string "exit 1"). Two defects that anchor produced: (a) `grep -q` exits the
# instant it hits ANY "exit 1" substring in that huge range — including inside a comment — so it can
# PASS VACUOUSLY on prose, never proving the real summary exits non-zero; (b) under `set -o
# pipefail`, `grep -q`'s early exit sends SIGPIPE to awk before awk finishes writing the rest of a
# ~100 KB file, and awk's own non-zero (SIGPIPE) status became the pipeline's status — a FALSE FAIL
# on a perfectly correct install.sh. Scanning to the next `^fi$` and requiring a NON-comment line
# that is exactly `exit 1` in between fixes both: the match is anchored to code, and there is no
# early-exiting `grep -q` left in the pipe for pipefail to punish.
# I1: the `fi` terminator is matched on the SAME stripped `line` the anchor uses (not raw `$0`) — an
# indented `fi` must still close the block, or the scan silently runs past it into unrelated code,
# an inconsistency between the anchor's and the terminator's basis. `exit 1` is accepted followed by
# whitespace, `;`, `#` or end of line — `exit 1;` and `exit 1 # comment` are still exactly `exit 1`.
# ADV-C6/C8: the terminator gets the SAME `;`/`#`/whitespace tolerance as the `exit 1` match above —
# a strict `^fi$` only recognizes a bare `fi` alone on a line; a `fi;` or `fi # comment` style at the
# real block's close would fail to terminate there, and the scan would run on into whatever code
# follows (this file already has an unrelated `fi  # end main run guard …` two lines later) until
# some LATER, unrelated `fi` stops it — reopening exactly the "~2200 unrelated lines, including a
# comment that itself contains exit 1" false-pass class the anchor fix above was written to close.
# P2-94: the block ends where its OWN `fi` closes it, tracked by if/fi NESTING DEPTH — not at the
# first `fi` of any depth. A nested `if … fi` between the anchor and `exit 1` used to end the scan at
# the INNER `fi` (a false FAIL on a correct install.sh); and an `exit 1` sitting inside such a nested
# block is conditional, so it must not count as the summary's own exit (a false PASS). Only an
# `exit 1` at the summary block's own depth counts. A one-line `if …; then …; fi` opens and closes on
# the same line and leaves the depth alone.
# P2-96: no `$` anchor nested inside an alternation (`(…|$)` is formally unspecified outside "last
# character of the whole pattern" in POSIX ERE): "exactly X" is an equality test, "X then a
# separator" a separate regex.
# summary_exits_nonzero — reads install.sh source on stdin; 0 when the INSTALL INCOMPLETE summary
# block exits 1 unconditionally, 1 otherwise. A function, so the self-tests below can feed it the
# shapes the real file does not have today.
summary_exits_nonzero() {
  awk '
    function is_exit1(l) { return l == "exit 1" || l ~ /^exit 1[ \t;#]/ }
    function is_fi(l)    { return l == "fi" || l ~ /^fi[ \t;#]/ }
    function opens_if(l) { return l == "if" || l ~ /^if[ \t]/ }
    function inline_fi(l) { return l ~ /;[ \t]*fi$/ || l ~ /;[ \t]*fi[ \t;#]/ }
    {
      line = $0
      sub(/^[ \t]*/, "", line)
    }
    # The anchor itself must be CODE, not prose: install.sh has comments mentioning "INSTALL
    # INCOMPLETE" in prose well before the real summary block (lines 240, 279), and a comment
    # anchor there is what pulled in the ~2200-line range this fix replaces. The anchor line sits
    # INSIDE the summary `if`, so the scan starts at depth 1.
    !on && line ~ /fail "INSTALL INCOMPLETE/ && line !~ /^#/ { on = 1; depth = 1; next }
    on && line !~ /^#/ {
      if (opens_if(line)) { if (!inline_fi(line)) depth++; next }
      if (is_fi(line)) { if (--depth == 0) exit; next }
      if (depth == 1 && is_exit1(line)) hit = 1
    }
    END { exit (hit ? 0 : 1) }
  '
}
# Self-tests: the shapes P2-94/P2-96 are about, none of which install.sh has today — each must get
# the verdict it deserves, so a scan that regressed to "first fi of any depth" fails here, not on the
# day someone nests an `if` in the real summary.
_sen_hdr='if [ "${INSTALL_VERIFY_MISSING:-0}" -gt 0 ]; then
  fail "INSTALL INCOMPLETE — detail"'
printf '%s\n  echo detail\n  exit 1\nfi\n' "$_sen_hdr" | summary_exits_nonzero \
  && t_ok "summary scan: a flat block ending in exit 1 passes" || t_no "summary scan: a flat block ending in exit 1 was not recognised"
printf '%s\n  if [ -n "$X" ]; then\n    echo nested\n  fi\n  exit 1\nfi\n' "$_sen_hdr" | summary_exits_nonzero \
  && t_ok "summary scan: a NESTED if/fi before exit 1 does not end the block early (P2-94)" \
  || t_no "summary scan: the nested fi ended the scan before the real exit 1 — a false FAIL (P2-94)"
printf '%s\n  if [ -n "$X" ]; then\n    exit 1\n  fi\n  echo done\nfi\n' "$_sen_hdr" | summary_exits_nonzero \
  && t_no "summary scan: an exit 1 inside a NESTED if was counted as the summary's own — a false PASS (P2-94)" \
  || t_ok "summary scan: an exit 1 that is only conditional (inside a nested if) does not count (P2-94)"
printf '%s\n  [ -n "$X" ] && echo y; if true; then echo one-liner; fi\n  if [ -n "$Y" ]; then echo a; fi\n  exit 1;\nfi\n' "$_sen_hdr" | summary_exits_nonzero \
  && t_ok "summary scan: one-line if…fi leaves the depth alone; exit 1; with a separator counts" \
  || t_no "summary scan: a one-line if…fi or 'exit 1;' was mis-scanned"
printf '%s\n  echo detail\nfi # end summary\nexit 1\n' "$_sen_hdr" | summary_exits_nonzero \
  && t_no "summary scan: an exit 1 AFTER the block's own 'fi # comment' close was counted" \
  || t_ok "summary scan: the block ends at its own 'fi # comment' — a later exit 1 does not count"
printf '%s\n  fixup_state\n  exit 12\n  # exit 1 in a comment\nfi\n' "$_sen_hdr" | summary_exits_nonzero \
  && t_no "summary scan: 'fixup_state' ended the block, or 'exit 12'/a commented exit 1 counted (P2-96)" \
  || t_ok "summary scan: 'fixup_state' is not a fi, 'exit 12' is not exit 1, a comment is not code (P2-96)"
if printf '%s\n' "$src" | summary_exits_nonzero; then
  t_ok "install exits non-zero when a copy is missing"
else
  t_no "summary does not exit non-zero"
fi

# --- 7. install must refuse to carry test debris out of the repo (B-REFGUARD) -------------------
# skills/* is copied into FIVE destinations. When the references-guard test still built its fixture
# in the real tree, an overlapping install carried it out and left it in the Claude Code plugin
# cache under two versions at once (59 installed skill dirs against 57 in source). The test is
# sandboxed now; this is the backstop, and it is ONE check before any build rather than a filter in
# each copy loop — a guard repeated five times is five places to forget the sixth path.
case "$src" in
  *'refusing to install: test debris'*) t_ok "install has a debris backstop" ;;
  *) t_no "no debris backstop in install.sh" ;;
esac
# It must run BEFORE the first copy, or it is a report rather than a guard.
_dbg_line="$(printf '%s\n' "$src" | grep -n 'refusing to install: test debris' | head -1 | cut -d: -f1)"
_cp_line="$(printf '%s\n' "$src" | grep -n 'cp -r "\$skill_dir"' | head -1 | cut -d: -f1)"
if [ -n "$_dbg_line" ] && [ -n "$_cp_line" ] && [ "$_dbg_line" -lt "$_cp_line" ]; then
  t_ok "the debris check precedes the first skills copy"
else
  t_no "debris check at line ${_dbg_line:-?} does not precede the first copy at ${_cp_line:-?}"
fi
# And it must not fire on a clean tree, or every install breaks.
if compgen -G "$ROOT/skills/tmp-*" >/dev/null 2>&1; then
  t_no "the repo currently HAS debris in skills/ — $(echo "$ROOT"/skills/tmp-*)"
else
  t_ok "the repo's skills/ is free of tmp-* debris"
fi

# --- 8. the cache-loop copies must not swallow their failures (B-INSTALL-COPY-IDIOM) -----------
# install_claude()'s `for CACHE_DIR` loop repeated `cp … 2>/dev/null || true` ten times. The
# duplication is the small half; the swallow is the big half — it is the mechanism that let the
# Claude plugin manifest go stale for ~40 releases with no signal, because install.sh printed OK
# whether or not any given copy happened.
command -v cp_warn >/dev/null 2>&1 && t_ok "cp_warn is defined" || t_no "cp_warn missing"

CS="$TMP/cw_src"; CD="$TMP/cw_dst"; mkdir -p "$CS" "$CD"
echo real > "$CS/present.txt"

# NOT `out="$(cp_warn …)"`: command substitution runs the function in a SUBSHELL, so the counter it
# increments dies with that subshell and every count assertion below reads 0. Stderr goes to a file
# and the call stays in THIS shell.
INSTALL_COPY_WARNINGS=0
cp_warn "label" "$CS/present.txt" "$CD/present.txt" 2>"$TMP/cw.err"
{ [ ! -s "$TMP/cw.err" ] && [ "$INSTALL_COPY_WARNINGS" -eq 0 ] && [ -s "$CD/present.txt" ]; } \
  && t_ok "a successful copy is silent and copies" || t_no "clean copy misbehaved: '$(cat "$TMP/cw.err")'"

# A glob that matched nothing is NOT a failure — `cp src/*.py dst/` with no .py files hands cp the
# literal pattern. Same rule as verify_copied: a check that cries wolf gets ignored.
INSTALL_COPY_WARNINGS=0
cp_warn "label" "$CS"/*.nomatch "$CD/" 2>"$TMP/cw.err"
[ "$INSTALL_COPY_WARNINGS" -eq 0 ] && [ ! -s "$TMP/cw.err" ] \
  && t_ok "an unmatched glob is not reported as a failure" || t_no "unmatched glob produced a false alarm"

# THE DEFECT: a real failure must be visible and counted.
INSTALL_COPY_WARNINGS=0
mkdir -p "$CD/ro"; chmod a-w "$CD/ro"
cp_warn "ro-label" "$CS/present.txt" "$CD/ro/x.txt" 2>"$TMP/cw.err"
chmod u+w "$CD/ro"
out="$(cat "$TMP/cw.err")"
case "$out" in
  *"WARN"*"ro-label"*) [ "$INSTALL_COPY_WARNINGS" -eq 1 ] && t_ok "a failed copy WARNs and is counted" \
      || t_no "warned but did not count (counter=$INSTALL_COPY_WARNINGS)" ;;
  *) t_no "a failed copy was swallowed: '$out'" ;;
esac

# …and it must stay NON-FATAL: one cache dir failing must not abort the other four hosts.
INSTALL_COPY_WARNINGS=0
mkdir -p "$CD/ro2"; chmod a-w "$CD/ro2"
cp_warn "l" "$CS/present.txt" "$CD/ro2/x.txt" >/dev/null 2>&1
rc=$?; chmod u+w "$CD/ro2"
[ "$rc" -eq 0 ] && t_ok "cp_warn returns 0 so a partial install still finishes" || t_no "cp_warn returned $rc"

# No `cp … || true` may remain in the cache loop, or the shape is back.
loop="$(printf '%s\n' "$src" | awk '/for CACHE_DIR in/,/^  done$/')"
n_swallow="$(printf '%s\n' "$loop" | grep -c 'cp .*|| true' || true)"
[ "${n_swallow:-0}" -eq 0 ] && t_ok "no swallowing cp left in the cache loop" \
  || t_no "$n_swallow swallowing cp call(s) remain in the cache loop"
n_cpwarn="$(printf '%s\n' "$loop" | grep -c 'cp_warn ' || true)"
[ "${n_cpwarn:-0}" -ge 8 ] && t_ok "cache loop routes $n_cpwarn copies through cp_warn" \
  || t_no "only $n_cpwarn cp_warn call sites in the cache loop"

echo "  --- install copy-verify: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
