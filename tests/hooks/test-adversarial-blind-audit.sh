#!/usr/bin/env bash
#
# test-adversarial-blind-audit.sh — `adversarial-review.sh --mode blind-audit`: the blind coverage
# audit of ONE production file + its test file, run as a cross-vendor panel of isolated lanes
# (docs/specs/2026-09-25-blind-audit-panel-plan.md, Task 4 = input, isolation, panel dispatch).
#
# The decisions live in scripts/lib/blind-audit-panel.sh (tests/hooks/test-blind-audit-panel.sh pins
# them); this file pins the DRIVER's wiring of them, end to end:
#   A  input: --production/--test (+ --protocol) only in this mode, the other inputs refused, empty
#      input exit 5, binary (NUL) input exit 2, oversize exit 6 before any lane runs, the library
#      looked up next to the driver or in ~/.zuvo — and missing, the mode alone refuses;
#      `--list-providers` without the mode keeps HEAD's output byte for byte
#   B  `--provider <lane>` = a panel of one: at best degraded, exit 3; mock lanes only in the test
#      harness; a global ZUVO_REVIEW_PROVIDER does not shrink the panel
#   C  the whole file reaches every lane: no 30k cap, no chunking, no truncation; agy's argv exactly
#   D  over the argv limit, the argv lanes (agy, kimi) are dropped loudly; the stdin lanes still run;
#      agy's argument is measured WITH its no-tools line
#   E  panel size ZUVO_BLIND_AUDIT_PANEL (default 3), ZUVO_REVIEW_MAX_PROVIDERS ignored
#   F  agy pinned in the default random pick
#   G  host exclusion by VENDOR (Claude excludes claude — kept in the other modes); an unmapped host
#      fails closed
#   H  isolation per lane, proven by SPIES named after real lanes and run through the REAL runners
#   I  ZUVO_BLIND_AUDIT_ALLOWLIST narrows; it can never admit a lane whose isolation was never proven
#   K  agy is left out when its settings.json holds allow-rules (or cannot be read)
#   L  every candidate excluded → exit 1 WITH the reason (this mode and code mode)
# Mocks (tests/adversarial/mocks/mock-*) prove count and exit logic only; SPIES prove isolation. Every
# spy case asserts the spy's record exists before reading it, so a run that never dispatched cannot
# pass; every "did not run" assertion is paired with a lane that DID run in the same case.
#
# Hermetic: every driver run is `env -i` — a temp HOME/ZUVO_HOME/TMPDIR, the fixture CODEX_HOME with a
# DUMMY auth.json, ZUVO_CODEX_BIN/ZUVO_CODEX_APP_BIN=/nonexistent unless the case needs the codex spy,
# the provider-health bench off, every host signal absent unless the case sets one, and an explicit PATH
# of spies/mocks + symlinks to the real timeout/gtimeout/jq (tests/lib/hermetic-tools.sh). No real model
# CLI runs and nothing touches the network.
#
# Run (both shells; the DRIVER runs under the bash the narrowed PATH finds, /bin/bash):
#   TF_ALLOW_LOCAL=1 bash tests/hooks/test-adversarial-blind-audit.sh
#   TF_ALLOW_LOCAL=1 /bin/bash tests/hooks/test-adversarial-blind-audit.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd -P)"
AR="${ZUVO_TEST_AR:-$ROOT/scripts/adversarial-review.sh}"
LIB="$ROOT/scripts/lib/blind-audit-panel.sh"
ZMS="$ROOT/scripts/lib/model-subprocess.sh"
PROTO="$ROOT/shared/includes/blind-coverage-audit.md"
MOCKS="$ROOT/tests/adversarial/mocks"
FIXD="$ROOT/tests/hooks/fixtures/model-subprocess"
FXBA="$ROOT/tests/hooks/fixtures/blind-audit"
# agy's no-tool-use line, verbatim from the plan's Technical Decisions (the only wording tested live).
AGY_PREFIX='Do not invoke any tools, shell commands, or file operations. Respond with plain text only, using only the information given below.'
PASS=0; FAIL=0
ok()  { echo "  PASS $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
cut300() { if [ "${#1}" -gt 300 ]; then printf '%s…' "${1:0:300}"; else printf '%s' "$1"; fi; }
expect_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2], got [$(cut300 "$3")]"; fi; }
expect_has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 — [$2] not found in [$(cut300 "$3")]" ;; esac; }
expect_not() { case "$3" in *"$2"*) bad "$1 — [$2] found in [$(cut300 "$3")]" ;; *) ok "$1" ;; esac; }

echo "== adversarial --mode blind-audit (test bash $BASH_VERSION) =="
[ -f "$AR" ] || { echo "  FAIL driver not found: $AR"; exit 1; }
[ -f "$LIB" ] || { echo "  FAIL panel library not found: $LIB"; exit 1; }
command -v shasum >/dev/null 2>&1 || { echo "  FAIL shasum required (every prompt comparison is a sha256)"; exit 1; }

# ── hermetic sandbox ─────────────────────────────────────────────────────────
T_LOG="$(mktemp -d)" || { echo "  FAIL mktemp -d failed"; exit 1; }
[ -n "$T_LOG" ] && [ -d "$T_LOG" ] || { echo "  FAIL mktemp -d returned no directory"; exit 1; }
trap 'rm -rf "$T_LOG"' EXIT
# Physical: the spies record `pwd -P`, so every path compared with theirs must be physical too.
T="$(cd "$T_LOG" && pwd -P)" && [ -n "$T" ] || { echo "  FAIL cannot resolve the sandbox path"; exit 1; }

SHIM="$T/shim"; mkdir -p "$SHIM"
# shellcheck source=tests/lib/hermetic-tools.sh
. "$ROOT/tests/lib/hermetic-tools.sh"
hermetic_link_tools "$SHIM" timeout:gtimeout gtimeout:timeout jq
[ -e "$SHIM/timeout" ] || { echo "  FAIL no GNU timeout on this machine — the driver cannot run"; exit 1; }
[ -e "$SHIM/jq" ] || { echo "  FAIL no jq on this machine — the driver cannot run"; exit 1; }

# The spy must see the OLDPWD a real client would get: macOS /bin/sh (bash 3.2) drops an inherited
# OLDPWD at startup, dash keeps it (same selection as the lane golden).
keeps_oldpwd() { env OLDPWD=/ "$1" -c '[ "${OLDPWD:-}" = / ]' 2>/dev/null; }
SPY_SH=""
for _s in /bin/sh /bin/dash /usr/bin/dash; do
  if [ -x "$_s" ] && keeps_oldpwd "$_s"; then SPY_SH="$_s"; break; fi
done
# Put in front of the fixture spy's body: every call appends its first argument to <name>.calls, and
# the argv of the LAST call is kept NUL-separated in <name>.argv0 — agy takes the prompt as an
# argument, so its exact argv (element count included) can only be compared byte for byte.
# shellcheck disable=SC2016  # expanded by the spy, not here
SPY_PRE='[ -z "${SPY_DIR:-}" ] || { printf "%s\n" "${1:-}" >> "$SPY_DIR/${0##*/}.calls"; printf "%s\0" "$@" > "$SPY_DIR/${0##*/}.argv0"; } 2>/dev/null'
install_spy() {
  { if [ -n "$SPY_SH" ]; then printf '#!%s\n' "$SPY_SH"; else head -1 "$FIXD/spy-cli"; fi
    printf '%s\n' "$SPY_PRE"
    tail -n +2 "$FIXD/spy-cli"; } > "$1"
  chmod +x "$1"
}
SPY_BIN="$T/spybin"; WORK="$T/work"; SRC="$T/src"
mkdir -p "$SPY_BIN" "$WORK" "$SRC" "$T/tmp"
for _c in codex claude agy cursor-agent kimi muse qwen; do install_spy "$SPY_BIN/$_c"; done
FIX_CH="$T/codex-home"; cp -R "$FIXD/codex-home" "$FIX_CH"
BASE_PATH="$SHIM:/usr/bin:/bin"
MOCK_PATH="$MOCKS:$BASE_PATH"
SPY_PATH="$SPY_BIN:$MOCKS:$BASE_PATH"
H1="ZUVO_ADVERSARIAL_TEST_HARNESS=1"
if [ -n "$SPY_SH" ]; then echo "  note: spy interpreter $SPY_SH (keeps an inherited OLDPWD)"
else echo "  note: no sh here keeps an inherited OLDPWD — the OLDPWD checks are skipped"; fi

# ── the file pair under audit ────────────────────────────────────────────────
P="$SRC/sum.sh"; TT="$SRC/sum.test.sh"; EMPTYF="$SRC/empty.sh"
printf '#!/bin/sh\nsum_or_zero() {\n  [ -z "$1" ] && { echo 0; return 0; }\n  t=0; for n in $1; do t=$((t + n)); done\n  echo "$t"\n}\n' > "$P"
printf '#!/bin/sh\n. ./sum.sh\n[ "$(sum_or_zero "1 2 3")" = 6 ] || exit 1\n' > "$TT"
: > "$EMPTYF"
# 100-byte lines: 60000 bytes is twice the code mode's 30000-char cap; 130000 is over the 120000-byte
# argv limit; 400001 is one byte over the 400000-byte refusal limit.
lines100() { LC_ALL=C awk -v n="$1" 'BEGIN { for (j = 0; j < 85; j++) x = x "x"; for (i = 1; i <= n; i++) printf "# line %06d %s\n", i, x }'; }
BIG60="$SRC/big60k.sh";  lines100 600  > "$BIG60"
BIG130="$SRC/big130k.sh"; lines100 1300 > "$BIG130"
HUGE="$SRC/huge.sh"; { lines100 4000; printf 'x'; } > "$HUGE"
# 70000 × U+017C: 70000 CHARACTERS (under the limit if counted as chars) but 140000 BYTES (over it).
MBF="$SRC/multibyte.sh"; LC_ALL=C awk 'BEGIN { for (i = 0; i < 70000; i++) printf "\305\274"; printf "\n" }' > "$MBF"
_sz() { wc -c < "$1" | tr -d ' '; }
expect_eq "premise: the 60k file is 60000 bytes"   "60000"  "$(_sz "$BIG60")"
expect_eq "premise: the 130k file is 130000 bytes" "130000" "$(_sz "$BIG130")"
expect_eq "premise: the huge file is 400001 bytes" "400001" "$(_sz "$HUGE")"
expect_eq "premise: the multi-byte file is 140001 bytes" "140001" "$(_sz "$MBF")"

# The prompt the panel must receive, built by the library the driver loads (sourced in a clean shell).
prompt_of() { env -i PATH=/usr/bin:/bin HOME="$T" bash -c '. "$1" && bap_build_prompt "$2" "$3" "$4"' _ "$LIB" "$PROTO" "$1" "$2"; }
sha_of() { shasum -a 256 < "$1" | cut -d' ' -f1; }

# drive <tag> <PATH> [VAR=value ...] -- <driver args...> — one driver run from $WORK under `env -i`.
# HOME=$T/home-<tag> (a case may seed it first); stdin = $T/<tag>.in when present, a PIPE from
# $T/<tag>.pipe when present, else /dev/null. Output in $T/<tag>.out / .err; mocks log their calls to
# $T/<tag>.calls. DRIVE_AR runs another driver copy. Later VAR=value pairs override the defaults.
drive() {
  local tag="$1" path="$2" h="$T/home-$1" in=/dev/null rc=0 envs=(); shift 2
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  mkdir -p "$h"
  [ -f "$T/$tag.in" ] && in="$T/$tag.in"
  if [ -f "$T/$tag.pipe" ]; then
    cat "$T/$tag.pipe" | ( cd "$WORK" && env -i HOME="$h" ZUVO_HOME="$h/.zuvo" TMPDIR="$T/tmp" CODEX_HOME="$FIX_CH" \
        ZUVO_NO_CAFFEINATE=1 ZUVO_PROVIDER_BENCH=0 ZUVO_CODEX_BIN=/nonexistent ZUVO_CODEX_APP_BIN=/nonexistent \
        MOCK_CALL_LOG="$T/$tag.calls" PATH="$path" ${envs[@]+"${envs[@]}"} bash "${DRIVE_AR:-$AR}" "$@" ) \
      > "$T/$tag.out" 2> "$T/$tag.err" || rc=$?
  else
    ( cd "$WORK" && env -i HOME="$h" ZUVO_HOME="$h/.zuvo" TMPDIR="$T/tmp" CODEX_HOME="$FIX_CH" \
        ZUVO_NO_CAFFEINATE=1 ZUVO_PROVIDER_BENCH=0 ZUVO_CODEX_BIN=/nonexistent ZUVO_CODEX_APP_BIN=/nonexistent \
        MOCK_CALL_LOG="$T/$tag.calls" PATH="$path" ${envs[@]+"${envs[@]}"} bash "${DRIVE_AR:-$AR}" "$@" ) \
      < "$in" > "$T/$tag.out" 2> "$T/$tag.err" || rc=$?
  fi
  return "$rc"
}
out() { cat "$T/$1.out" 2>/dev/null; }
err() { cat "$T/$1.err" 2>/dev/null; }
calls() { tr '\n' ' ' 2>/dev/null < "$T/$1.calls" | sed 's/ $//'; }
ncalls() { if [ -f "$T/$1.calls" ]; then wc -l < "$T/$1.calls" | tr -d ' '; else echo 0; fi; }
# spy_dir <tag> — a fresh spy record dir for one run.
spy_dir() { rm -rf "$T/spy-$1"; mkdir -p "$T/spy-$1"; printf '%s' "$T/spy-$1"; }
rec() { printf '%s' "$T/spy-$1/$2.rec"; }
# rec_get <rec> <key> — the first value recorded under <key>.
rec_get() { awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1" 2>/dev/null; }
# rec_args <rec> — the recorded argv, one `arg=` element per line (a multi-line element is cut to its first line).
rec_args() { awk '/^arg=/ { print substr($0, 5) }' "$1" 2>/dev/null; }
# neutral <path> — a physical directory a lane may run in: not the checkout under review, not inside it,
# not the repository holding this test, not HOME.
neutral() {
  case "$1" in ''|"$WORK"|"$WORK"/*|"$ROOT"|"$ROOT"/*) return 1 ;; esac
  case "$1" in "$T"/home-*) return 1 ;; esac
  return 0
}

# ═══ A. input ════════════════════════════════════════════════════════════════
echo "-- A. input: flags, rejections, list, gates, library lookup"
rc=0; drive a1 "$MOCK_PATH" "$H1" -- --mode blind-audit --provider mock-strict-clean || rc=$?
expect_eq "A1 --mode blind-audit without --production/--test → exit 2" "2" "$rc"
expect_has "A1 …and stderr names --production" "--production" "$(err a1)"
expect_eq "A1 …and no lane ran" "0" "$(ncalls a1)"
rc=0; drive a1b "$MOCK_PATH" "$H1" -- --mode blind-audit --production "$P" --provider mock-strict-clean || rc=$?
expect_eq "A1b --production without --test → exit 2" "2" "$rc"
expect_has "A1b …and stderr names --test" "--test" "$(err a1b)"

rc=0; drive a2 "$MOCK_PATH" "$H1" -- --production "$P" --test "$TT" --provider mock-strict-clean || rc=$?
expect_eq "A2 --production/--test outside the mode (default code) → exit 2" "2" "$rc"
expect_has "A2 …and stderr says they belong to --mode blind-audit" "blind-audit" "$(err a2)"
expect_eq "A2 …and no lane ran" "0" "$(ncalls a2)"
rc=0; drive a2b "$MOCK_PATH" "$H1" -- --mode security --test "$TT" --provider mock-strict-clean || rc=$?
expect_eq "A2b --test with --mode security → exit 2" "2" "$rc"
rc=0; drive a2c "$MOCK_PATH" "$H1" -- --mode code --protocol "$PROTO" --provider mock-strict-clean || rc=$?
expect_eq "A2c --protocol with --mode code → exit 2" "2" "$rc"

BA=(--mode blind-audit --production "$P" --test "$TT")
rc=0; drive a3f "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean --files "$P" || rc=$?
expect_eq "A3 --files in the mode → exit 2" "2" "$rc"
expect_eq "A3 …and no lane ran" "0" "$(ncalls a3f)"
rc=0; drive a3fi "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean --file "$P" || rc=$?
expect_eq "A3 --file in the mode → exit 2" "2" "$rc"
rc=0; drive a3d "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean --diff HEAD~1 || rc=$?
expect_eq "A3 --diff in the mode → exit 2" "2" "$rc"
rc=0; drive a3a "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean --artifact "$T/art-a3.txt" || rc=$?
expect_eq "A3 --artifact in the mode → exit 2" "2" "$rc"
if [ -e "$T/art-a3.txt" ]; then bad "A3 …and no artifact is written"; else ok "A3 …and no artifact is written"; fi
rc=0; drive a3p "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean --append-artifact || rc=$?
expect_eq "A3 --append-artifact in the mode → exit 2" "2" "$rc"
printf 'diff --git a/x b/x\n+x\n' > "$T/a3s.pipe"
rc=0; drive a3s "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "A3 a diff piped on stdin in the mode → exit 2" "2" "$rc"
expect_has "A3 …and stderr says stdin is not read here" "stdin" "$(err a3s)"
expect_eq "A3 …and no lane ran" "0" "$(ncalls a3s)"
printf 'diff --git a/x b/x\n+x\n' > "$T/a3r.in"
rc=0; drive a3r "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "A3 a file redirected to stdin in the mode → exit 2" "2" "$rc"
# Control: the rejections above are about the flags, not about the run — the same run without them works.
rc=0; drive a3ok "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "A3 control: the same run without the refused input runs its lane (exit 3)" "3" "$rc"
expect_eq "A3 control: …the lane ran once" "mock-strict-clean" "$(calls a3ok)"

rc=0; drive a4 "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean codex-5.3 cursor-agent muse" \
  -- --list-providers --mode blind-audit || rc=$?
expect_eq "A4 --list-providers --mode blind-audit needs no --production/--test → exit 0" "0" "$rc"
expect_eq "A4 …and prints the panel candidates (cursor-agent/muse are never candidates here)" \
  "mock-strict-clean codex-5.3" "$(out a4 | tr '\n' ' ' | sed 's/ $//')"
expect_eq "A4 …and runs no lane" "0" "$(ncalls a4)"

# Byte-identity with HEAD. Captured from the UNMODIFIED driver (HEAD 35b9d7cf, 2026-09-27) under
# exactly these environments, before --mode blind-audit existed: `--list-providers` without the mode
# must not move by a byte — reviewer-preflight.sh parses it.
LIST_ENV=(ZUVO_CODEX_BIN="$SPY_BIN/codex" ZUVO_ADV_QWEN=1)
HEAD_LIST_NOHOST="$(printf 'cursor-agent\nagy\ncodex-5.3\nclaude\nmuse\nkimi\nqwen\n_')"
HEAD_LIST_HARNESS="$(printf 'codex-5.3\ncursor-agent\nmuse\nmock-strict-clean\n_')"
for _v in nohost:: claude:CLAUDECODE=1: harness:"$H1":; do
  _tag="a5-${_v%%:*}"; _e="${_v#*:}"; _e="${_e%:}"
  _envs=("${LIST_ENV[@]}"); [ -n "$_e" ] && _envs+=("$_e")
  [ "$_tag" = a5-harness ] && _envs+=(ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 cursor-agent muse mock-strict-clean")
  rc=0; drive "$_tag" "$SPY_PATH" "${_envs[@]}" -- --list-providers || rc=$?
  expect_eq "A5 --list-providers (no mode, ${_v%%:*}) → exit 0" "0" "$rc"
  _want="$HEAD_LIST_NOHOST"; [ "$_tag" = a5-harness ] && _want="$HEAD_LIST_HARNESS"
  expect_eq "A5 …stdout byte-identical to HEAD's (${_v%%:*})" "$_want" "$(cat "$T/$_tag.out"; printf _)"
done

cp "$EMPTYF" "$SRC/empty.test.sh"
rc=0; drive a6 "$MOCK_PATH" "$H1" -- --mode blind-audit --production "$EMPTYF" --test "$TT" --provider mock-strict-clean || rc=$?
expect_eq "A6 an empty production file → exit 5" "5" "$rc"
expect_eq "A6 …and no lane ran" "0" "$(ncalls a6)"
rc=0; drive a6b "$MOCK_PATH" "$H1" -- --mode blind-audit --production "$P" --test "$SRC/empty.test.sh" --provider mock-strict-clean || rc=$?
expect_eq "A6b an empty test file → exit 5" "5" "$rc"
rc=0; drive a6c "$MOCK_PATH" "$H1" -- --mode blind-audit --production "$SRC/nope.sh" --test "$TT" --provider mock-strict-clean || rc=$?
expect_eq "A6c a production file that does not exist → exit 2 (a usage error, not 'empty')" "2" "$rc"
expect_has "A6c …and stderr names the path" "nope.sh" "$(err a6c)"
expect_eq "A6c …and no lane ran" "0" "$(ncalls a6c)"
# A NUL byte cannot travel in a bash variable: the prompt would silently lose everything after it.
printf 'sum() { echo 1; }\n\000# after the NUL byte\n' > "$SRC/nul.sh"; cp "$SRC/nul.sh" "$SRC/nul.test.sh"
rc=0; drive a6d "$MOCK_PATH" "$H1" -- --mode blind-audit --production "$SRC/nul.sh" --test "$TT" --provider mock-strict-clean || rc=$?
expect_eq "A6d a production file holding a NUL byte → exit 2" "2" "$rc"
expect_has "A6d …stderr says binary input" "binary input" "$(err a6d)"
expect_has "A6d …and names the file" "nul.sh" "$(err a6d)"
expect_eq "A6d …and no lane ran" "0" "$(ncalls a6d)"
rc=0; drive a6e "$MOCK_PATH" "$H1" -- --mode blind-audit --production "$P" --test "$SRC/nul.test.sh" --provider mock-strict-clean || rc=$?
expect_eq "A6e a test file holding a NUL byte → exit 2, no lane ran" "2|0" "$rc|$(ncalls a6e)"
expect_has "A6e …stderr says binary input and names the test file" "nul.test.sh" "$(err a6e | awk '/binary input/')"

SD="$(spy_dir a7)"
rc=0; drive a7 "$SPY_PATH" "$H1" SPY_DIR="$SD" ZUVO_CODEX_BIN="$SPY_BIN/codex" ZUVO_BLIND_AUDIT_PANEL=5 \
  ZUVO_REVIEW_TEST_PROVIDERS="agy codex-5.3 mock-strict-clean" -- --mode blind-audit --production "$HUGE" --test "$TT" || rc=$?
expect_eq "A7 a 400001-byte production file → exit 6" "6" "$rc"
expect_eq "A7 …and no mock lane was invoked" "0" "$(ncalls a7)"
if [ -e "$(rec a7 agy)" ] || [ -e "$(rec a7 codex)" ]; then bad "A7 …and no spy lane was invoked (a .rec exists)"
else ok "A7 …and no spy lane was invoked (no .rec)"; fi
expect_has "A7 …and stderr names the byte limit" "400000" "$(err a7)"

printf 'no strict marker here\n' > "$SRC/bad-protocol.md"
rc=0; drive a8 "$MOCK_PATH" "$H1" -- "${BA[@]}" --protocol "$SRC/bad-protocol.md" --provider mock-strict-clean || rc=$?
expect_eq "A8 --protocol without an 'Audit mode: strict' line → exit 2" "2" "$rc"
expect_eq "A8 …and no lane ran" "0" "$(ncalls a8)"
# A protocol that DIFFERS from the repo's (one extra last line): a driver that ignored --protocol would
# still hand over a prompt starting with the repo protocol's first line.
{ cat "$PROTO"; printf 'Custom protocol marker: a8b-7f3a (this copy only)\n'; } > "$SRC/own-protocol.md"
mkdir -p "$T/a8b-stdin"
rc=0; drive a8b "$MOCK_PATH" "$H1" MOCK_STDIN_DIR="$T/a8b-stdin" ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-prompt mock-strict-clean" \
  -- "${BA[@]}" --protocol "$SRC/own-protocol.md" || rc=$?
_pn="$(_sz "$SRC/own-protocol.md")"
head -c "$_pn" "$T/a8b-stdin/mock-echo-prompt.stdin" > "$T/a8b-head" 2>/dev/null
if cmp -s "$SRC/own-protocol.md" "$T/a8b-head"; then ok "A8b the lane's prompt begins with the WHOLE --protocol file, byte for byte"
else bad "A8b the lane's prompt does not begin with the whole --protocol file ($(_sz "$T/a8b-head" 2>/dev/null || echo 0) of $_pn bytes match-checked)"; fi
expect_eq "A8b …and the production file's header follows it" "=== PRODUCTION FILE: sum.sh ===" \
  "$(tail -c +"$((_pn + 1))" "$T/a8b-stdin/mock-echo-prompt.stdin" 2>/dev/null | sed -n 2p)"
expect_eq "A8b the audit completed: one valid answer of two → exit 3" "3" "$rc"
expect_eq "A8b …the merged block is printed (line 1)" "Audit mode: strict" "$(out a8b | sed -n 1p)"
expect_has "A8b …with its panel line" "Audit panel: degraded valid=1/2" "$(out a8b | sed -n 2p)"

# The library next to the driver is not the only place it can come from, and without it only THIS mode
# refuses. A lone copy of the driver has no lib/ beside it and no ~/.zuvo copy in the temp HOME.
LONE="$T/lone"; mkdir -p "$LONE"; cp "$AR" "$LONE/adversarial-review.sh"
rc=0; DRIVE_AR="$LONE/adversarial-review.sh" drive a9 "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "A9 library missing → --mode blind-audit exits 2" "2" "$rc"
expect_has "A9 …naming the file it looked for" "blind-audit-panel.sh" "$(err a9)"
expect_eq "A9 …and no lane ran" "0" "$(ncalls a9)"
printf 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n' > "$T/a9c.in"
rc=0; DRIVE_AR="$LONE/adversarial-review.sh" drive a9c "$MOCK_PATH" "$H1" -- --mode code --dry-run --provider mock-strict-clean || rc=$?
expect_eq "A9 …while --mode code is unaffected (dry run exits 0)" "0" "$rc"
expect_not "A9 …and does not even mention the panel library" "blind-audit-panel" "$(err a9c)"
# Installed layout: the library (and the shared runner) in ~/.zuvo. Without the protocol there the mode
# still refuses — naming the protocol; with it, the panel runs.
mkdir -p "$T/home-a9i/.zuvo" "$T/home-a9j/.zuvo"
cp "$LIB" "$ZMS" "$T/home-a9i/.zuvo/"; cp "$LIB" "$ZMS" "$PROTO" "$T/home-a9j/.zuvo/"
rc=0; DRIVE_AR="$LONE/adversarial-review.sh" drive a9i "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "A9 library in ~/.zuvo but no protocol anywhere → exit 2" "2" "$rc"
expect_has "A9 …naming the protocol" "blind-coverage-audit.md" "$(err a9i)"
rc=0; DRIVE_AR="$LONE/adversarial-review.sh" drive a9j "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "A9 library + protocol in ~/.zuvo → the lone driver runs the panel (exit 3)" "3" "$rc"
expect_has "A9 …and prints the panel line" "Audit panel: degraded valid=1/1" "$(out a9j)"

# ═══ B. a panel of one ═══════════════════════════════════════════════════════
echo "-- B. --provider <lane> in this mode"
rc=0; drive b1 "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "B1 --provider mock-strict-clean → exit 3 (one valid answer = degraded)" "3" "$rc"
expect_eq "B1 …exactly that one lane ran, once" "mock-strict-clean" "$(calls b1)"
expect_eq "B1 …stdout line 1 is 'Audit mode: strict'" "Audit mode: strict" "$(out b1 | sed -n 1p)"
expect_has "B1 …line 2 is the panel line" "Audit panel: degraded valid=1/1" "$(out b1 | sed -n 2p)"
expect_has "B1 …the verdict is the lane's" "Coverage verdict: CLEAN" "$(out b1)"
SD="$(spy_dir b2)"
rc=0; drive b2 "$SPY_PATH" "$H1" SPY_DIR="$SD" -- "${BA[@]}" --provider cursor-agent || rc=$?
expect_eq "B2 --provider cursor-agent (isolation never proven) → no lane left, exit 1" "1" "$rc"
if [ -e "$(rec b2 cursor-agent)" ]; then bad "B2 …and cursor-agent never ran"; else ok "B2 …and cursor-agent never ran"; fi
expect_has "B2 …and stderr names it" "cursor-agent" "$(err b2)"
# mock-* lanes are the test harness's (run_mock's own gate): outside it the allowlist admits none.
rc=0; drive b3 "$MOCK_PATH" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "B3 without ZUVO_ADVERSARIAL_TEST_HARNESS a mock-* lane is not admitted → exit 1" "1" "$rc"
expect_has "B3 …stderr names it as excluded" "mock-strict-clean" "$(err b3 | awk '/xclud/')"
expect_eq "B3 …and it never ran" "0" "$(ncalls b3)"
# A global ZUVO_REVIEW_PROVIDER (a pin meant for code reviews) must not shrink the panel to one lane.
rc=0; drive b4 "$MOCK_PATH" "$H1" ZUVO_REVIEW_PROVIDER=mock-strict-clean \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix mock-strict-rewrite" -- "${BA[@]}" || rc=$?
expect_eq "B4 ZUVO_REVIEW_PROVIDER set: the whole panel still ran (3 lanes)" "3" "$(ncalls b4)"
expect_eq "B4 …a strict panel, exit 0" "0" "$rc"
expect_has "B4 …stderr says the variable is ignored in this mode" "ZUVO_REVIEW_PROVIDER" "$(err b4 | awk '/gnored/')"

# ═══ C. the whole file reaches the lane ═════════════════════════════════════
echo "-- C. whole files, no cap / chunk / truncation; agy's exact argv"
prompt_of "$BIG60" "$TT" > "$T/c-expected.prompt"
SD="$(spy_dir c1)"; mkdir -p "$T/c1-stdin"
rc=0; drive c1 "$SPY_PATH" "$H1" SPY_DIR="$SD" MOCK_STDIN_DIR="$T/c1-stdin" ZUVO_CODEX_BIN="$SPY_BIN/codex" \
  ZUVO_BLIND_AUDIT_PANEL=5 ZUVO_AGY_MODEL=agy-test-model ZUVO_AGY_FALLBACK_MODEL= \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-prompt codex-5.3 agy" -- --mode blind-audit --production "$BIG60" --test "$TT" || rc=$?
expect_eq "C1 premise: the expected prompt is bigger than the code mode's 30000-char cap" "yes" \
  "$([ "$(_sz "$T/c-expected.prompt")" -gt 60000 ] && echo yes || echo no)"
if [ -s "$T/c1-stdin/mock-echo-prompt.stdin" ]; then
  ok "C1 the echo mock ran (its stdin was kept)"
  expect_eq "C1 …it received bap_build_prompt's bytes exactly (sha256)" "$(sha_of "$T/c-expected.prompt")" "$(sha_of "$T/c1-stdin/mock-echo-prompt.stdin")"
else bad "C1 the echo mock never ran — $(err c1 | tail -3 | tr '\n' ' ')"; fi
_r="$(rec c1 codex)"
if [ -s "$_r" ]; then
  ok "C1 the codex spy ran through the real runner (.rec present)"
  expect_eq "C1 …its stdin is bap_build_prompt's bytes exactly (sha256)" "$(sha_of "$T/c-expected.prompt")" "$(rec_get "$_r" stdin_sha)"
else bad "C1 the codex spy never ran — $(err c1 | tail -3 | tr '\n' ' ')"; fi
_e="$(err c1)"
case "$_e" in *[Tt][Rr][Uu][Nn][Cc][Aa][Tt]*|*[Cc][Hh][Uu][Nn][Kk]*) bad "C1 no truncation/chunk line on stderr — [$(cut300 "$_e")]" ;;
  *) ok "C1 no truncation/chunk line on stderr" ;; esac
if [ -s "$SD/agy.argv0" ]; then
  ok "C1 the agy spy ran (argv kept)"
  { printf '%s\0' -p; printf '%s\n\n' "$AGY_PREFIX"; cat "$T/c-expected.prompt"; printf '\0%s\0%s\0' --model agy-test-model; } > "$T/c-agy.argv0"
  if cmp -s "$T/c-agy.argv0" "$SD/agy.argv0"; then
    ok "C1 agy argv is exactly: -p <no-tools line + blank line + the prompt> --model <model> (4 elements)"
  else
    bad "C1 agy argv differs from '-p <prefix+prompt> --model <model>': $(tr '\0' '\n' < "$SD/agy.argv0" | awk 'NR<=2 || /^--/' | head -8 | tr '\n' '|')"
  fi
else bad "C1 the agy spy never ran — $(err c1 | tail -3 | tr '\n' ' ')"; fi

# ═══ D. argv lanes over the argv limit ═══════════════════════════════════════
echo "-- D. over 120000 bytes the argv lanes are dropped, loudly"
for _v in d1:"$BIG130": d2:"$MBF":LC_ALL=en_US.UTF-8; do
  _tag="${_v%%:*}"; _rest="${_v#*:}"; _f="${_rest%%:*}"; _loc="${_rest#*:}"
  SD="$(spy_dir "$_tag")"
  _envs=("$H1" SPY_DIR="$SD" ZUVO_CODEX_BIN="$SPY_BIN/codex" ZUVO_BLIND_AUDIT_PANEL=5
         ZUVO_REVIEW_TEST_PROVIDERS="agy kimi codex-5.3 mock-strict-clean")
  [ -n "$_loc" ] && _envs+=("$_loc")
  rc=0; drive "$_tag" "$SPY_PATH" "${_envs[@]}" -- --mode blind-audit --production "$_f" --test "$TT" || rc=$?
  L="$_tag ($(basename "$_f")${_loc:+, $_loc})"
  if [ -s "$(rec "$_tag" codex)" ]; then ok "$L the stdin lane codex-5.3 still ran (.rec present)"
  else bad "$L the stdin lane codex-5.3 never ran — $(err "$_tag" | tail -3 | tr '\n' ' ')"; fi
  expect_eq "$L …and the stdin mock still ran" "mock-strict-clean" "$(calls "$_tag")"
  if [ -e "$(rec "$_tag" agy)" ] || [ -e "$(rec "$_tag" kimi)" ]; then bad "$L agy/kimi were not dispatched (a .rec exists)"
  else ok "$L agy/kimi were not dispatched"; fi
  _line="$(err "$_tag" | awk '/agy/ && /kimi/ && /120000/ { print; exit }')"
  if [ -n "$_line" ]; then ok "$L one stderr line names agy, kimi and the 120000-byte limit"
  else bad "$L no stderr line names agy + kimi + 120000 — [$(cut300 "$(err "$_tag")")]"; fi
  expect_eq "$L one valid answer → exit 3" "3" "$rc"
done
# agy's argument is the no-tools line + a blank line + the prompt: a prompt of EXACTLY 120000 bytes is
# at the limit (kimi's argument is the prompt alone — it may run), and agy's is over it.
EDGE="$SRC/edge.sh"; printf 'x' > "$EDGE"
_ovh=$(( $(prompt_of "$EDGE" "$TT" | wc -c) - 1 ))
lines100 1300 | head -c "$((120000 - _ovh))" > "$EDGE"
expect_eq "D3 premise: the prompt is exactly 120000 bytes" "120000" "$(prompt_of "$EDGE" "$TT" | wc -c | tr -d ' ')"
SD="$(spy_dir d3)"
rc=0; drive d3 "$SPY_PATH" "$H1" SPY_DIR="$SD" ZUVO_BLIND_AUDIT_PANEL=5 ZUVO_REVIEW_TEST_PROVIDERS="agy kimi mock-strict-clean" \
  -- --mode blind-audit --production "$EDGE" --test "$TT" || rc=$?
if [ -s "$(rec d3 kimi)" ]; then ok "D3 kimi (argument = the prompt, 120000 bytes) still ran"
else bad "D3 kimi never ran — $(err d3 | tail -3 | tr '\n' ' ')"; fi
if [ -e "$(rec d3 agy)" ]; then bad "D3 agy ran with a $((120000 + ${#AGY_PREFIX} + 2))-byte argument"
else ok "D3 agy (argument = no-tools line + blank line + prompt) was not dispatched"; fi
_line="$(err d3 | awk '/excluding/ && /agy/ && /120000/ { print; exit }')"
if [ -n "$_line" ]; then ok "D3 one stderr line names agy and the 120000-byte limit"; else bad "D3 no stderr line names agy + 120000 — [$(cut300 "$(err d3)")]"; fi
expect_not "D3 …and that line does not drop kimi" "kimi" "$_line"

# ═══ E. panel size ═══════════════════════════════════════════════════════════
echo "-- E. ZUVO_BLIND_AUDIT_PANEL (default 3); ZUVO_REVIEW_MAX_PROVIDERS ignored"
FIVE="mock-strict-clean mock-strict-fix mock-strict-rewrite mock-invalid-block mock-echo-prompt"
rc=0; drive e1 "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="$FIVE" ZUVO_REVIEW_PROVIDER_PICK=ranked \
  ZUVO_REVIEW_MAX_PROVIDERS=5 -- "${BA[@]}" || rc=$?
expect_eq "E1 5 candidates, ranked pick, ZUVO_REVIEW_MAX_PROVIDERS=5 → exactly 3 run" "3" "$(ncalls e1)"
expect_eq "E1 …the three ranked-first lanes ran (compared as a SET: they run in parallel, so call order is not an order)" \
  "mock-strict-clean mock-strict-fix mock-strict-rewrite" "$(calls e1 | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
expect_eq "E1 …the panel kept is in RANKING order (the fan-out line's list)" "mock-strict-clean mock-strict-fix mock-strict-rewrite" \
  "$(err e1 | awk '/Fan-out cap:/ { print; exit }' | sed -n 's/^[^(]*(\([^)]*\)).*/\1/p')"
expect_has "E1 …and the panel line keeps that order" "providers=mock-strict-clean,mock-strict-fix,mock-strict-rewrite " "$(out e1 | sed -n 2p)"
expect_eq "E1 …three valid answers → exit 0" "0" "$rc"
expect_has "E1 …the panel line says strict 3/3" "Audit panel: strict valid=3/3" "$(out e1)"
rc=0; drive e2 "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="$FIVE" ZUVO_BLIND_AUDIT_PANEL=5 -- "${BA[@]}" || rc=$?
expect_eq "E2 ZUVO_BLIND_AUDIT_PANEL=5 → all 5 run" "5" "$(ncalls e2)"
expect_has "E2 …3 valid of 5 (the invalid block and the echo do not count)" "valid=3/5" "$(out e2)"
rc=0; drive e3 "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="$FIVE" ZUVO_BLIND_AUDIT_PANEL=abc -- "${BA[@]}" || rc=$?
expect_eq "E3 ZUVO_BLIND_AUDIT_PANEL=abc → the default, 3 run" "3" "$(ncalls e3)"
expect_has "E3 …with a warning naming the variable" "ZUVO_BLIND_AUDIT_PANEL" "$(err e3)"

# ═══ F. agy pinned (default random pick) ═════════════════════════════════════
echo "-- F. agy is pinned in every random panel of 3"
_pin=0; _runs=0; _ok=0; _pinmsg=0
for _i in 1 2 3 4 5 6 7 8 9 10; do
  SD="$(spy_dir "f$_i")"; cp "$FXBA/clean.txt" "$SD/agy.reply"
  rc=0; drive "f$_i" "$SPY_PATH" "$H1" SPY_DIR="$SD" \
    ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix mock-strict-rewrite mock-invalid-block agy" \
    -- "${BA[@]}" || rc=$?
  _runs=$((_runs + 1))
  [ "$rc" = 0 ] && _ok=$((_ok + 1))
  if [ -s "$(rec "f$_i" agy)" ] && [ "$(( $(ncalls "f$_i") + 1 ))" = 3 ]; then _pin=$((_pin + 1)); fi
  [ -z "$(err "f$_i" | awk '/pinned: agy/')" ] || _pinmsg=$((_pinmsg + 1))
done
expect_eq "F1 agy ran in every one of 10 panels, each panel exactly 3 lanes" "10" "$_pin"
expect_eq "F1 …every panel had >= 2 valid answers (agy + a valid mock) → exit 0" "10" "$_ok"
expect_eq "F1 …every run's stderr names the pin ('pinned: agy')" "10" "$_pinmsg"

# ═══ G. host exclusion by vendor ═════════════════════════════════════════════
echo "-- G. host exclusion by vendor (--list-providers --mode blind-audit)"
GLIST="codex-5.3 codex-5.4 claude agy cursor-agent kimi kimi-api qwen openrouter-3"
BASELINE="codex-5.3 codex-5.4 claude agy kimi kimi-api qwen openrouter-3"
glist() { # glist <tag> [VAR=value...] — the post-exclusion candidates on one line; status = the driver's
  local tag="$1"; shift
  drive "$tag" "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="$GLIST" "$@" -- --list-providers --mode blind-audit
}
rc=0; glist g0 || rc=$?
expect_eq "G0 no host → exit 0" "0" "$rc"
expect_eq "G0 no host → every isolated lane (cursor-agent is not one)" "$BASELINE" "$(out g0 | tr '\n' ' ' | sed 's/ $//')"
without() { local x w; x=" $1 "; shift; for w in "$@"; do x="${x/ $w / }"; done; x="${x# }"; printf '%s' "${x% }"; }
for _v in "claude|CLAUDECODE=1|claude" \
          "codex-sandbox|CODEX_SANDBOX=seatbelt|codex-5.3 codex-5.4" \
          "codex-desktop|CODEX_INTERNAL_ORIGINATOR_OVERRIDE=Codex Desktop|codex-5.3 codex-5.4" \
          "codex-shell|CODEX_SHELL=1|codex-5.3 codex-5.4" \
          "codex-bundle|__CFBundleIdentifier=com.openai.codex|codex-5.3 codex-5.4" \
          "antigravity|ANTIGRAVITY_SESSION_ID=abc|agy" \
          "qwen|QWEN_CODE=1|qwen"; do
  _n="${_v%%|*}"; _r="${_v#*|}"; _set="${_r%%|*}"; _gone="${_r#*|}"
  rc=0; glist "g-$_n" "$_set" || rc=$?
  # shellcheck disable=SC2086  # _gone is a word list by design
  expect_eq "G $_n host ($_set) → exit 0, without: $_gone" "0|$(without "$BASELINE" $_gone)" \
    "$rc|$(out "g-$_n" | tr '\n' ' ' | sed 's/ $//')"
  expect_has "G $_n …stderr announces the exclusion" "auto-excluding" "$(err "g-$_n")"
done
rc=0; glist g-kimi PATH="$MOCK_PATH:$T/home-g-kimi/.kimi-code/bin" || rc=$?
expect_eq "G kimi host (its bin dir on PATH) → exit 0, without: kimi kimi-api" "0|$(without "$BASELINE" kimi kimi-api)" \
  "$rc|$(out g-kimi | tr '\n' ' ' | sed 's/ $//')"
rc=0; glist g-cursor VSCODE_GIT_ASKPASS_MAIN=/Applications/Cursor.app/Contents/askpass.sh || rc=$?
expect_eq "G cursor host → exit 0, the isolated list unchanged (cursor-agent was never a candidate)" "0|$BASELINE" \
  "$rc|$(out g-cursor | tr '\n' ' ' | sed 's/ $//')"
expect_has "G cursor …stderr names cursor-agent as auto-excluded" "auto-excluding cursor-agent" "$(err g-cursor)"
# An UNMAPPED host fails CLOSED: its own lane is excluded, with a WARN. detect_host_platform only ever
# names hosts the vendor table knows, so no production seam reaches that arm — it is reached through a
# MUTANT copy of the driver under test whose Qwen signal names a host the table has never seen
# ("qwen-next"), with the driver's lib/ beside it. Real qwen must then stay (no vendor is guessed).
MUT="$T/unmapped"; mkdir -p "$MUT/lib"; cp "$(dirname "$AR")"/lib/*.sh "$MUT/lib/"
if awk '{ if (index($0, "echo \"qwen\" && return")) { sub(/echo "qwen"/, "echo \"qwen-next\""); n++ } print }
        END { exit n != 1 }' "$AR" > "$MUT/adversarial-review.sh"; then
  ok "G unmapped premise: the mutant renames exactly one host signal (qwen → qwen-next)"
else bad "G unmapped premise: the Qwen host line was not found exactly once in $AR"; fi
rc=0; DRIVE_AR="$MUT/adversarial-review.sh" drive g-unmapped "$MOCK_PATH" "$H1" QWEN_CODE=1 \
  ZUVO_REVIEW_TEST_PROVIDERS="qwen codex-5.3" -- --list-providers --mode blind-audit || rc=$?
expect_eq "G unmapped host → exit 0, no vendor guessed (qwen and codex-5.3 stay)" "0|qwen codex-5.3" \
  "$rc|$(out g-unmapped | tr '\n' ' ' | sed 's/ $//')"
expect_has "G unmapped …its own lane is excluded" "auto-excluding qwen-next" "$(err g-unmapped)"
expect_has "G unmapped …with ONE warning naming it" "qwen-next" "$(err g-unmapped | awk '/WARN/')"
expect_eq "G unmapped …exactly one such warning" "1" "$(err g-unmapped | awk '/WARN/ && /qwen-next/ { n++ } END { print n + 0 }')"
# The vendor rule is THIS mode's: a code review on a Claude host keeps claude (it flips Opus<->Sonnet).
cp "$T/a9c.in" "$T/g-code.in"
rc=0; drive g-code "$MOCK_PATH" "$H1" CLAUDECODE=1 -- --mode code --dry-run --provider claude || rc=$?
expect_eq "G --mode code on a Claude host: the dry run exits 0" "0" "$rc"
expect_has "G --mode code on a Claude host still keeps claude" "KEPT as cross-model reviewer" "$(err g-code)"

# ═══ H. isolation per lane (spies through the real runners) ════════════════
echo "-- H. isolation: every lane run through its real runner, recorded by a spy"
SD="$(spy_dir h1)"
rc=0; drive h1 "$SPY_PATH" "$H1" SPY_DIR="$SD" ZUVO_CODEX_BIN="$SPY_BIN/codex" ZUVO_BLIND_AUDIT_PANEL=5 \
  ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 claude agy cursor-agent kimi" -- "${BA[@]}" || rc=$?
# codex-5.3 — access none: neutral cwd + OLDPWD, isolated CODEX_HOME, effort high, read-only, no tools.
_r="$(rec h1 codex)"
if [ -s "$_r" ]; then
  ok "H codex: the spy ran (.rec present)"
  _pwd="$(rec_get "$_r" pwd_P)"
  if neutral "$_pwd" && case "$_pwd" in "$T/tmp"/*) true ;; *) false ;; esac; then ok "H codex: cwd is a neutral dir under the run's TMPDIR"
  else bad "H codex: cwd [$_pwd] is not a neutral dir under $T/tmp"; fi
  if [ -n "$SPY_SH" ]; then expect_eq "H codex: OLDPWD is the neutral cwd (the checkout path is not handed over)" "$_pwd" "$(rec_get "$_r" OLDPWD_P)"; fi
  _ch="$(rec_get "$_r" CODEX_HOME)"
  if [ -n "$_ch" ] && [ "$_ch" != "$FIX_CH" ] && case "$_ch" in "$T/tmp"/*) true ;; *) false ;; esac; then ok "H codex: CODEX_HOME is an isolated copy, not the user's"
  else bad "H codex: CODEX_HOME [$_ch] is not an isolated dir under $T/tmp"; fi
  expect_has "H codex: model_reasoning_effort = \"high\" (ZUVO_CODEX_EFFORT_AUDIT)" 'config=model_reasoning_effort = "high"' "$(cat "$_r")"
  expect_has "H codex: sandbox_mode = \"read-only\"" 'config=sandbox_mode = "read-only"' "$(cat "$_r")"
  expect_has "H codex: shell, exec and image tools disabled (access none)" "shell_tool unified_exec view_image" \
    "$(rec_args "$_r" | awk 'p { print; p = 0 } $0 == "--disable" { p = 1 }' | tr '\n' ' ' | sed 's/ $//')"
else bad "H codex: the spy never ran — $(err h1 | tail -3 | tr '\n' ' ')"; fi
# claude — access none: no tools, safe mode, empty strict MCP config, no session, NOT skip-permissions.
_r="$(rec h1 claude)"
if [ -s "$_r" ]; then
  ok "H claude: the spy ran (.rec present)"
  _a="$(rec_args "$_r")"
  expect_eq "H claude: EVERY --tools is given an EMPTY list (a later one would override the first)" "arg=" \
    "$(awk 'p { print; p = 0 } $0 == "arg=--tools" { p = 1 }' "$_r" | sort -u)"
  for _f in --safe-mode --strict-mcp-config --no-session-persistence; do
    expect_has "H claude: $_f" "$_f" "$_a"
  done
  expect_not "H claude: no --dangerously-skip-permissions" "--dangerously-skip-permissions" "$_a"
  if neutral "$(rec_get "$_r" pwd_P)"; then ok "H claude: cwd is neutral"; else bad "H claude: cwd [$(rec_get "$_r" pwd_P)] is not neutral"; fi
  expect_has "H claude: the MCP config is empty" '{"mcpServers":{}}' "$(rec_get "$_r" mcp_content)"
else bad "H claude: the spy never ran — $(err h1 | tail -3 | tr '\n' ' ')"; fi
# agy — neutral cwd, argv without the permission-skipping flag (nor --mode plan / --sandbox).
_r="$(rec h1 agy)"
if [ -s "$_r" ]; then
  ok "H agy: the spy ran (.rec present)"
  _pwd="$(rec_get "$_r" pwd_P)"
  if neutral "$_pwd"; then ok "H agy: cwd is neutral"; else bad "H agy: cwd [$_pwd] is not neutral"; fi
  if [ -n "$SPY_SH" ]; then
    if neutral "$(rec_get "$_r" OLDPWD_P)"; then ok "H agy: OLDPWD is neutral too"; else bad "H agy: OLDPWD [$(rec_get "$_r" OLDPWD_P)] hands over a checkout path"; fi
  fi
  # Element by element (NUL-delimited — the prompt element spans many lines): no argument may START with
  # a forbidden flag, so `--mode=plan` / `--sandbox=true` are caught as well as the bare flags. `--mode`
  # is matched bare or with `=`: as a bare prefix it would also match the required `--model`.
  _n=0; _forb=""
  while IFS= read -r -d '' _el; do
    _n=$((_n + 1))
    case "$_el" in --dangerously-skip-permissions*|--sandbox*|--mode|--mode=*) _forb="$_forb ${_el%%[[:space:]]*}" ;; esac
  done < "$SD/agy.argv0"
  expect_eq "H agy: no argument starts with --dangerously-skip-permissions, --mode or --sandbox" "" "$_forb"
  expect_eq "H agy: exactly 4 argv elements (-p <prompt> --model <model>)" "4" "$_n"
  expect_eq "H agy: the first element is -p" "-p" "$(rec_args "$_r" | sed -n 1p)"
  if [ -f "$SD/agy.stdin" ] && [ ! -s "$SD/agy.stdin" ]; then ok "H agy: its stdin was empty (the prompt travels in its argument only)"
  else bad "H agy: its stdin was not empty ($(_sz "$SD/agy.stdin" 2>/dev/null || echo 'no record') bytes)"; fi
else bad "H agy: the spy never ran — $(err h1 | tail -3 | tr '\n' ' ')"; fi
# cursor-agent — never proven isolatable: no run at all in this mode.
if [ -e "$(rec h1 cursor-agent)" ]; then bad "H cursor-agent: it ran — its read tool is not scoped by --workspace"
else ok "H cursor-agent: never dispatched (isolation not provable, spike 2026-09-25)"; fi
expect_has "H cursor-agent: …and stderr names it as excluded" "cursor-agent" "$(err h1 | awk '/xclud|efus/')"
# kimi — runs from the run's own temp dir (where its tool-less agent file lives).
_r="$(rec h1 kimi)"
if [ -s "$_r" ]; then
  ok "H kimi: the spy ran (.rec present)"
  _af="$(awk 'p { print substr($0, 5); exit } $0 == "arg=--agent-file" { p = 1 }' "$_r")"
  # Logical PWD against the agent file's dir as the driver spelled both (that dir is gone by now, so
  # it cannot be made physical here); the physical pwd is then checked for neutrality.
  expect_eq "H kimi: cwd is the run's temp dir (where its agent file is)" "${_af%/*}" "$(rec_get "$_r" PWD)"
  _pwd="$(rec_get "$_r" pwd_P)"
  if neutral "$_pwd"; then ok "H kimi: …which is neutral"; else bad "H kimi: cwd [$_pwd] is not neutral"; fi
else bad "H kimi: the spy never ran — $(err h1 | tail -3 | tr '\n' ' ')"; fi

# ═══ I. the allowlist narrows, never widens ═════════════════════════════════
echo "-- I. ZUVO_BLIND_AUDIT_ALLOWLIST"
# codex and claude answer a valid block here, so the run's exit code says something (kimi's spy reply
# is not kimi's stream-json: that lane fails) — 2 valid of 3 → strict, exit 0.
SD="$(spy_dir i1)"; cp "$FXBA/clean.txt" "$SD/codex.reply"; cp "$FXBA/fix.txt" "$SD/claude.reply"
rc=0; drive i1 "$SPY_PATH" "$H1" SPY_DIR="$SD" ZUVO_CODEX_BIN="$SPY_BIN/codex" ZUVO_BLIND_AUDIT_PANEL=5 \
  ZUVO_BLIND_AUDIT_ALLOWLIST="codex-5.3 claude kimi" \
  ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 claude agy cursor-agent kimi" -- "${BA[@]}" || rc=$?
expect_eq "I1 the narrowed panel audited: codex-5.3 + claude valid of 3 → exit 0" "0" "$rc"
expect_has "I1 …panel line: strict, 2 valid of the 3 admitted lanes" "Audit panel: strict valid=2/3" "$(out i1)"
for _c in codex claude kimi; do
  if [ -s "$(rec i1 "$_c")" ]; then ok "I1 narrowed to codex-5.3 claude kimi: $_c ran"; else bad "I1 $_c never ran — $(err i1 | tail -3 | tr '\n' ' ')"; fi
done
for _c in agy cursor-agent; do
  if [ -e "$(rec i1 "$_c")" ]; then bad "I1 $_c ran although the allowlist leaves it out"; else ok "I1 $_c did not run"; fi
  expect_has "I1 …stderr names $_c as excluded" "$_c" "$(err i1 | awk '/xclud/')"
done
SD="$(spy_dir i2)"; cp "$FXBA/clean.txt" "$SD/agy.reply"
rc=0; drive i2 "$SPY_PATH" "$H1" SPY_DIR="$SD" ZUVO_CODEX_BIN="$SPY_BIN/codex" ZUVO_BLIND_AUDIT_PANEL=6 \
  ZUVO_BLIND_AUDIT_ALLOWLIST="agy cursor-agent muse" \
  ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 claude agy cursor-agent kimi muse" -- "${BA[@]}" || rc=$?
expect_eq "I2 agy alone admitted and valid → a panel of one, exit 3" "3" "$rc"
expect_has "I2 …panel line: degraded, 1 of 1" "Audit panel: degraded valid=1/1" "$(out i2)"
if [ -s "$(rec i2 agy)" ]; then ok "I2 'agy cursor-agent muse': agy (on the default list) runs"; else bad "I2 agy never ran — $(err i2 | tail -3 | tr '\n' ' ')"; fi
for _c in cursor-agent muse; do
  if [ -e "$(rec i2 "$_c")" ]; then bad "I2 $_c ran — an override WIDENED the allowlist"; else ok "I2 $_c still did not run (an override cannot widen)"; fi
  expect_has "I2 …stderr names $_c as refused" "$_c" "$(err i2 | awk '/efus/')"
done
for _c in codex claude kimi; do
  if [ -e "$(rec i2 "$_c")" ]; then bad "I2 $_c ran although the override leaves it out"; else ok "I2 $_c did not run (narrowed out)"; fi
done

# ═══ K. agy's own allow-rules ═══════════════════════════════════════════════
echo "-- K. ~/.gemini/antigravity-cli/settings.json"
for _v in k1:'{"permissions":{"allow":["Read(*)"]}}':out k2:'{"trustedWorkspaces":["/somewhere"]}':in \
          k3:'{"permissions":{"allow":[]}}':in k4:'{"permissions": nope':out; do
  _tag="${_v%%:*}"; _rest="${_v#*:}"; _json="${_rest%:*}"; _want="${_rest##*:}"
  mkdir -p "$T/home-$_tag/.gemini/antigravity-cli"; printf '%s\n' "$_json" > "$T/home-$_tag/.gemini/antigravity-cli/settings.json"
  SD="$(spy_dir "$_tag")"
  rc=0; drive "$_tag" "$SPY_PATH" "$H1" SPY_DIR="$SD" ZUVO_REVIEW_TEST_PROVIDERS="agy mock-strict-clean" -- "${BA[@]}" || rc=$?
  expect_eq "K $_tag ($_json): the mock lane ran" "mock-strict-clean" "$(calls "$_tag")"
  if [ "$_want" = out ]; then
    if [ -e "$(rec "$_tag" agy)" ]; then bad "K $_tag agy ran despite its settings"; else ok "K $_tag agy left out"; fi
    expect_has "K $_tag …stderr names the settings file" "$T/home-$_tag/.gemini/antigravity-cli/settings.json" "$(err "$_tag")"
  else
    if [ -s "$(rec "$_tag" agy)" ]; then ok "K $_tag agy admitted"; else bad "K $_tag agy never ran — $(err "$_tag" | tail -3 | tr '\n' ' ')"; fi
  fi
done

# ═══ L. no candidate left: exit 1 WITH the reason (both modes) ════════════════
# An exclusion that removes EVERY candidate used to kill the driver inside a `grep -v` pipeline
# (pipefail): exit 1 and not a word on stderr. The exit code stays 1; the reason must be printed.
echo "-- L. every candidate excluded: exit 1 and say which lanes went, and why"
rc=0; drive l1 "$SPY_PATH" "$H1" CLAUDECODE=1 -- "${BA[@]}" --provider claude || rc=$?
expect_eq "L1 blind-audit: --provider claude on a Claude host → exit 1" "1" "$rc"
expect_has "L1 …stderr says no tool is left" "No cross-provider review tool found" "$(err l1)"
expect_has "L1 …and names claude as the host's own lane" "auto-excluded: claude" "$(err l1)"
for _t in l2 l3 l4; do cp "$T/a9c.in" "$T/$_t.in"; done
rc=0; drive l2 "$SPY_PATH" "$H1" VSCODE_GIT_ASKPASS_MAIN=/Applications/Cursor.app/askpass.sh \
  -- --mode code --provider cursor-agent || rc=$?
expect_eq "L2 code mode: --provider cursor-agent on a Cursor host → exit 1" "1" "$rc"
expect_has "L2 …stderr says no tool is left" "No cross-provider review tool found" "$(err l2)"
expect_has "L2 …and names cursor-agent as the host's own lane" "auto-excluded: cursor-agent" "$(err l2)"
rc=0; drive l3 "$MOCK_PATH" "$H1" -- --mode code --provider mock-success --exclude mock-success || rc=$?
expect_eq "L3 code mode: --exclude removes the only lane → exit 1" "1" "$rc"
expect_has "L3 …stderr names it as excluded by --exclude" "Excluded by --exclude: mock-success" "$(err l3)"
expect_not "L3 …and does not blame the host" "auto-excluded" "$(err l3)"
rc=0; drive l4 "$MOCK_PATH" "$H1" -- --mode code --provider mock-success --exclude-last mock-success || rc=$?
expect_eq "L4 code mode: --exclude-last removes the only lane → exit 1" "1" "$rc"
expect_has "L4 …stderr says no tool is left" "No cross-provider review tool found" "$(err l4)"
expect_has "L4 …and names the --exclude-last removal" "--exclude-last" "$(err l4)"

echo "=== RESULT ==="
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
