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
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "  FAIL harness: mktemp -d failed"; exit 1; }

# A SANDBOXED HOME for the whole run, set before install.sh is sourced. Sourcing it RUNS code, not only
# definitions: its downgrade guard reads $HOME/.zuvo/.installed-from (and on a mismatch refuses — it
# used to `exit`, killing THIS shell), and until the sleep guard moved inside the main-run guard,
# sourcing also wrote $HOME/.zuvo/zuvo-sleep-guard.zsh and appended to $HOME/.zshenv. This suite used to
# source it twice with the CALLER's real HOME: every run refreshed the real ~/.zuvo/zuvo-sleep-guard.zsh,
# and a machine whose ~/.zshenv lacked the marker would have had it appended. So every variable that
# install.sh, or a zsh or git it starts, resolves a dotfile through points into $TMP — HOME, ZDOTDIR
# (zsh), XDG_CONFIG_HOME and GIT_CONFIG_GLOBAL (git) — and the host overrides that could aim an install
# step somewhere else are dropped. Section 9 proves it: this very file, started with HOME at an empty
# sentinel dir, leaves that dir empty.
SANDBOX_HOME="$TMP/home"
mkdir -p "$SANDBOX_HOME" || { echo "  FAIL harness: cannot create the sandbox HOME"; exit 1; }
export HOME="$SANDBOX_HOME" ZDOTDIR="$SANDBOX_HOME" XDG_CONFIG_HOME="$SANDBOX_HOME/.config" \
  GIT_CONFIG_GLOBAL="$SANDBOX_HOME/.gitconfig" GIT_CONFIG_NOSYSTEM=1
unset KIMI_CODE_HOME CODEX_HOME ZUVO_HOME ZUVO_SHIM_PATH ZUVO_INSTALL_GIT_SHIM ZUVO_UNINSTALL_GIT_SHIM

# install.sh guards its main body so it can be sourced for exactly this purpose.
# shellcheck disable=SC1090
if ! ( set +u; . "$INSTALL" ) >/dev/null 2>&1; then
  t_no "install.sh is not sourceable (main-run guard broken)"; echo "  --- install copy-verify: PASS=$PASS FAIL=$FAIL"; exit 1
fi
t_ok "install.sh sources cleanly without running the install"

# Pull the helper into this shell.
# shellcheck disable=SC1090
set +u; . "$INSTALL" >/dev/null 2>&1; set -u

# The sourced installer resolved HOME to the sandbox — its downgrade-guard stamp path is computed from
# $HOME at source time — and sourcing it WROTE nothing there: the sleep guard runs only when install.sh
# is executed now (it used to sit below the main-run guard and run on every source).
if [ "${_zuvo_install_stamp:-}" = "$SANDBOX_HOME/.zuvo/.installed-from" ] \
   && [ ! -e "$SANDBOX_HOME/.zuvo/zuvo-sleep-guard.zsh" ] && [ ! -e "$SANDBOX_HOME/.zshenv" ]; then
  t_ok "the sourced install.sh saw HOME = the sandbox (its stamp path) and sourcing wrote nothing into it"
else
  t_no "sourcing install.sh — stamp path [${_zuvo_install_stamp:-}], sleep guard written: $([ -e "$SANDBOX_HOME/.zuvo/zuvo-sleep-guard.zsh" ] && echo YES || echo no), .zshenv written: $([ -e "$SANDBOX_HOME/.zshenv" ] && echo YES || echo no)"
fi

command -v verify_copied >/dev/null 2>&1 && t_ok "verify_copied is defined" || { t_no "verify_copied missing"; echo "  --- install copy-verify: PASS=$PASS FAIL=$FAIL"; exit 1; }

SRC="$TMP/src"; DST="$TMP/dst"; mkdir -p "$SRC" "$DST"
echo "real content" > "$SRC/present-and-copied.sh"
echo "real content" > "$DST/present-and-copied.sh"
echo "real content" > "$SRC/present-but-lost.sh"          # source exists, never reached dst
echo "real content" > "$SRC/present-but-truncated.sh"
: > "$DST/present-but-truncated.sh"                        # 0 bytes = failed copy
printf 'new source bytes\n' > "$SRC/present-but-stale.sh"
printf 'old source bytes\n' > "$DST/present-but-stale.sh"   # same LENGTH, other bytes: only a content check sees it
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
if verify_copied lbl "$SRC" "$DST" present-but-lost.sh >"$TMP/lost.out" 2>&1; then
  t_no "a lost file returned SUCCESS — this is the defect"
else
  t_ok "a lost file returns non-zero"
fi
[ "$INSTALL_VERIFY_MISSING" -eq 1 ] && t_ok "lost file counted once" || t_no "counter is $INSTALL_VERIFY_MISSING, expected 1"
case "$INSTALL_VERIFY_DETAIL" in *present-but-lost.sh*) t_ok "detail names the missing path";; *) t_no "detail does not name the file";; esac
case "$(cat "$TMP/lost.out")" in *'lbl: 1 file(s) did NOT install'*) t_ok "failure message names the copy failure";; *) t_no "failure message misstates the copy result";; esac

# --- 3. a 0-byte destination is a failed copy, not a copy -----------------------------------
# `cp` can create the target and then fail (disk full, interrupted). `-e` would call that success.
INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""
verify_copied lbl "$SRC" "$DST" present-but-truncated.sh >/dev/null 2>&1
[ "$INSTALL_VERIFY_MISSING" -eq 1 ] && t_ok "0-byte destination counted as a failure (bytes compared, not presence)" || t_no "empty file accepted as installed"

# --- 3b. a stale nonempty destination is a failed copy ----------------------------------------
# Existence and size alone cannot prove that the installed helper has the current bytes.
INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""
if verify_copied lbl "$SRC" "$DST" present-but-stale.sh >"$TMP/stale.out" 2>&1; then
  t_no "stale nonempty destination returned success"
else
  t_ok "stale nonempty destination returns non-zero"
fi
[ "$INSTALL_VERIFY_MISSING" -eq 1 ] && t_ok "stale destination counted once" || t_no "stale destination counter is $INSTALL_VERIFY_MISSING"
case "$INSTALL_VERIFY_DETAIL" in *present-but-stale.sh*) t_ok "stale destination named in detail";; *) t_no "stale destination absent from detail";; esac

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
# The installer's TEXT is install.sh plus the scripts/install.d/ modules it sources.
. "$ROOT/tests/lib/installer-sources.sh"
src="$(installer_text)"
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
# A here-string, not `printf … |`: the scan exits at the summary's own `fi`, and since the installer's
# text became install.sh + scripts/install.d/*.sh, ~2400 module lines follow that `fi` — more than a
# pipe buffer — so the writer took SIGPIPE and `set -o pipefail` reported 141 for a correct summary.
if summary_exits_nonzero <<<"$src"; then
  t_ok "install exits non-zero when a copy is missing"
else
  t_no "summary does not exit non-zero"
fi

# --- 6b. BEHAVIOURAL backstop: the REAL installer, run as a process (P3C-37) ---------------------
# summary_exits_nonzero re-parses bash control flow with line-anchored regexes. It has been patched for
# three rounds of shapes it misread (P2-94, P2-96, then the sixteen of P3C-37..52 — a fused `fi; exit 1`
# line reads as "no exit", a condition it never evaluates reads as "exits"), and it will misread the
# next one. What it stands in for is a property of a RUN: a file that did not reach its destination
# makes install.sh EXIT non-zero. Nothing else checked that — every other INSTALL INCOMPLETE check in
# this repo SOURCES install.sh, which skips its main-run guard and so never executes the real `exit 1`.
# So install.sh is run here for real, as a subprocess, once clean and once with one destination made
# uncopiable, and its ACTUAL exit status is read. The scan above stays as a fast static cross-check;
# this is the authority.
#
# Fully sandboxed — install.sh has machine-global side effects: `env -i`, and HOME, TMPDIR, git's global
# config and ZUVO_DIST_ROOT all under $TMP (the isolation tests/hooks/test-install-wiring.sh's
# host_install uses). The target is `codex` in a HOME with NO ~/.codex, so install_codex skips itself (no
# build), and the run is the validators, install_zuvo_home, the install stamp, the cross-provider check
# (`command -v` lookups only — no client is ever run) and the summary; install_zuvo_home writes nothing
# outside $HOME, and install_git_shim is opt-in through variables env -i clears. The plant is (12b)'s
# technique in test-install-wiring.sh: a DIRECTORY where ~/.zuvo/model-subprocess.sh has to land, which
# install_file_atomic refuses to replace — a file present in the repo that cannot reach its destination.
# run_install <home> — `install.sh codex`, executed, in that sandbox; its output to <home>.log, its own
# exit status returned.
run_install() {
  mkdir -p "$1/tmp" || return 99
  env -i HOME="$1" TMPDIR="$1/tmp" PATH="$PATH" GIT_CONFIG_GLOBAL="$1/.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
    ZUVO_DIST_ROOT="$1/dist" "$BASH" "$INSTALL" codex > "$1.log" 2>&1
}
_ri_tail() { tail -4 "$1.log" 2>/dev/null | tr '\n' '|'; }
IH_OK="$TMP/install-home-clean"; mkdir -p "$IH_OK"
run_install "$IH_OK"; ih_ok_rc=$?
# The install stamp is written only when the source has a git revision (a git-less source — the farm's
# synced mirror — records none, by design: test-install-downgrade-guard.sh).
if git -C "$ROOT" rev-parse HEAD >/dev/null 2>&1; then _ih_stamp_ok() { [ -f "$1" ]; }; else _ih_stamp_ok() { [ ! -e "$1" ]; }; fi
if [ "$ih_ok_rc" -eq 0 ] && ! grep -q 'INSTALL INCOMPLETE' "$IH_OK.log" && _ih_stamp_ok "$IH_OK/.zuvo/.installed-from" \
   && [ -f "$IH_OK/.zuvo/model-subprocess.sh" ]; then
  t_ok "real install.sh run, clean sandbox HOME: exit 0, no INSTALL INCOMPLETE, and it installed into the sandbox (P3C-37)"
else
  t_no "real install.sh run, clean sandbox HOME: exit $ih_ok_rc — want 0, no INSTALL INCOMPLETE, the stamp and ~/.zuvo/model-subprocess.sh under $IH_OK; the planted case below proves nothing without this [$(_ri_tail "$IH_OK")] (P3C-37)"
fi
IH_BAD="$TMP/install-home-planted"; mkdir -p "$IH_BAD/.zuvo/model-subprocess.sh"
run_install "$IH_BAD"; ih_bad_rc=$?
if [ "$ih_bad_rc" -ne 0 ] && grep -q 'INSTALL INCOMPLETE' "$IH_BAD.log"; then
  t_ok "real install.sh run, one destination uncopiable: the PROCESS exits $ih_bad_rc with INSTALL INCOMPLETE (P3C-37)"
else
  t_no "real install.sh run, one destination uncopiable: exit $ih_bad_rc, INSTALL INCOMPLETE $(grep -q 'INSTALL INCOMPLETE' "$IH_BAD.log" && echo printed || echo 'NOT printed') — a copy that did not land let the installer report success [$(_ri_tail "$IH_BAD")] (P3C-37)"
fi
# …and it is the SUMMARY that failed it, naming the file — not some earlier abort: the run reached the
# cross-provider check (the last section before the summary; it prints on every path) and the detail
# names the planted destination. Not the DONE banner: DONE and the install stamp now come AFTER the
# summary, so a failed install prints neither (test-install-downgrade-guard.sh) — their absence here is
# the other half of the proof, not a gap in it.
if grep -qE 'Cross-provider check:|No adversarial review providers found' "$IH_BAD.log" \
   && grep -qF "$IH_BAD/.zuvo/model-subprocess.sh" "$IH_BAD.log" \
   && ! grep -q '^  DONE$' "$IH_BAD.log" && [ ! -e "$IH_BAD/.zuvo/.installed-from" ]; then
  t_ok "real install.sh run: the whole install ran to its summary, which names the file that did not land — and it neither printed DONE nor wrote the install stamp (P3C-37)"
else
  t_no "real install.sh run: the cross-provider check never ran, the planted destination is not named, or a FAILED install printed DONE / wrote .installed-from [$(_ri_tail "$IH_BAD")] (P3C-37)"
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
# Exercise the guard itself: a source-text check alone stays green when the
# condition is disabled while its diagnostic string remains in the file.
DEBRIS_REPO="$TMP/debris-repo"
mkdir -p "$DEBRIS_REPO/scripts/lib" "$DEBRIS_REPO/skills/tmp-leftover" "$TMP/debris-home"
cp "$INSTALL" "$DEBRIS_REPO/scripts/install.sh"
cp "$ROOT/scripts/lib/portable.sh" "$DEBRIS_REPO/scripts/lib/portable.sh"
# install.sh refuses to run without its lane library (and the runner library that library sources);
# without them the run stops at that check, before the debris guard this case exercises.
cp "$ROOT/scripts/lib/reviewer-lanes.sh" "$ROOT/scripts/lib/model-subprocess.sh" "$DEBRIS_REPO/scripts/lib/"
# …and its modules: install.sh loads scripts/install.d/ before the debris guard, and refuses without them.
cp -R "$ROOT/scripts/install.d" "$DEBRIS_REPO/scripts/"
debris_rc=0
HOME="$TMP/debris-home" bash "$DEBRIS_REPO/scripts/install.sh" codex >"$TMP/debris.out" 2>&1 || debris_rc=$?
if [ "$debris_rc" -ne 0 ] && grep -q 'refusing to install: test debris in skills/' "$TMP/debris.out" && \
   ! grep -q 'Installing zuvo' "$TMP/debris.out" && [ -z "$(ls -A "$TMP/debris-home")" ]; then
  t_ok "debris guard stops a direct install before copying anything"
else
  t_no "debris guard did not stop direct installation (rc=$debris_rc)"
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
cp_rc=0
cp_warn "label" "$CS/present.txt" "$CD/present.txt" 2>"$TMP/cw.err" || cp_rc=$?
{ [ "$cp_rc" -eq 0 ] && [ ! -s "$TMP/cw.err" ] && [ "$INSTALL_COPY_WARNINGS" -eq 0 ] && cmp -s "$CS/present.txt" "$CD/present.txt"; } \
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
# The scripts copies count too: they go through install_files_atomic (rename into place, because a
# session may be running the cached driver), which keeps cp_warn's warn-and-count accounting.
n_cpwarn="$(printf '%s\n' "$loop" | grep -vE '^[[:space:]]*#' | grep -cE '(cp_warn|install_files_atomic) ' || true)"
[ "${n_cpwarn:-0}" -ge 8 ] && t_ok "cache loop routes $n_cpwarn copies through cp_warn or install_files_atomic" \
  || t_no "only $n_cpwarn cp_warn / install_files_atomic call sites in the cache loop"
# …and the three script copies, by name: these are the files a running session executes from the cache.
# A file, not a pipe: under pipefail an early `grep -q` exit SIGPIPEs the writer and fails a present pin.
printf '%s\n' "$loop" | grep -vE '^[[:space:]]*#' > "$TMP/cache-loop.txt"
for _pin in 'install_files_atomic "scripts/install.d" "$CACHE_DIR/scripts/install.d"' \
            'install_files_atomic "scripts/*.py" "$CACHE_DIR/scripts"' \
            'install_files_atomic "scripts/*.sh" "$CACHE_DIR/scripts"'; do
  grep -qF "$_pin" "$TMP/cache-loop.txt" \
    && t_ok "cache loop installs by rename: $_pin" \
    || t_no "cache loop lost: $_pin"
done

# --- 9. this suite never writes into the HOME it was started with ---------------------------------
# The sandbox at the top is only as good as its coverage, and the next edit to this file could source
# or run install.sh before it, or reach a dotfile through a variable it does not redirect. So the
# whole file runs again here, as a child, started with HOME — and ZDOTDIR, XDG_CONFIG_HOME and
# GIT_CONFIG_GLOBAL, the other ways to a dotfile — all pointing at an EMPTY sentinel directory; after
# it, the sentinel must still be empty. Any write the suite makes through the HOME it was handed,
# today's or a future one's, lands there and fails this. (ZUVO_ICV_SENTINEL_INNER stops the child from
# recursing.)
if [ "${ZUVO_ICV_SENTINEL_INNER:-}" != 1 ]; then
  SELF="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/$(basename "${BASH_SOURCE[0]:-$0}")"
  SENT="$TMP/sentinel-home"; mkdir -p "$SENT"
  env ZUVO_ICV_SENTINEL_INNER=1 HOME="$SENT" ZDOTDIR="$SENT" XDG_CONFIG_HOME="$SENT/.config" \
    GIT_CONFIG_GLOBAL="$SENT/.gitconfig" "$BASH" "$SELF" > "$TMP/sentinel-run.log" 2>&1
  sent_rc=$?
  if ! grep -q -- '--- install copy-verify:' "$TMP/sentinel-run.log"; then
    t_no "sentinel run: the suite, started with HOME at the sentinel, did not run to its summary (rc=$sent_rc) — the check below would prove nothing [$(tail -3 "$TMP/sentinel-run.log" | tr '\n' '|')]"
  elif [ "$sent_rc" -ne 0 ]; then
    t_no "sentinel run: the suite started with HOME at the sentinel failed (rc=$sent_rc) — $(grep -- '  FAIL' "$TMP/sentinel-run.log" | head -3 | tr '\n' '|')"
  else
    t_ok "sentinel run: the suite, started with HOME at a sentinel dir, runs to its summary and passes"
  fi
  if [ -d "$SENT" ] && [ -z "$(ls -A "$SENT" 2>/dev/null)" ]; then
    t_ok "sentinel run: NOTHING was written into the HOME the suite was started with — every install.sh source and run went to the sandbox"
  else
    t_no "sentinel run: the suite wrote into the HOME it was started with: [$(ls -A "$SENT" 2>/dev/null | tr '\n' ' ')] — a real run writes those into the caller's real HOME"
  fi
fi

echo "  --- install copy-verify: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
