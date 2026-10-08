#!/usr/bin/env bash
# install_files_atomic (scripts/install.d/copy.sh) and copy_hooks_lib_except_collisions, which uses it.
# Contract: usage, skipped sources, per-file accounting, partial failure; then a real bash script runs
# across an install — renamed into place it finishes its own code, and the plain-`cp` control runs the
# new code (docs/runbook/operating.md §5), which proves the scenario can see the defect at all.
#
# Level: medium — temporary filesystem and named pipes, no network, no sleep. Sourcing install.sh runs
# code, so HOME, ZDOTDIR, XDG_CONFIG_HOME and the git config point into the sandbox first, and the host
# overrides an installer reads (KIMI_CODE_HOME, CODEX_HOME, ZUVO_HOME) are unset.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" ZDOTDIR="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" \
  GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
unset KIMI_CODE_HOME CODEX_HOME ZUVO_HOME
mkdir -p "$HOME"
# shellcheck disable=SC1090
set +u; . "$ROOT/scripts/install.sh" >"$TMP/source.out" 2>&1 || { echo "  FAIL harness: install.sh did not source"; exit 1; }; set -u
trap 'rm -rf "$TMP"' EXIT   # again: whatever the sourced installer set, this suite's cleanup is the one that runs

PASS=0; FAIL=0
# Not ok()/fail(): install.sh defines those, and sourcing it would replace a same-named counter.
t_ok() { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
t_no() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
command_not_found_handle() { echo "  FAIL harness: unknown command '$1'"; FAIL=$((FAIL + 1)); return 127; }

SRC="$TMP/src"; mkdir -p "$SRC"
printf '#!/bin/sh\necho alpha\n' > "$SRC/alpha.sh"; chmod 755 "$SRC/alpha.sh"
printf 'beta = 1\n' > "$SRC/beta.py"; chmod 644 "$SRC/beta.py"
fresh_dst() { rm -rf "$TMP/dst"; mkdir -p "$TMP/dst"; }   # a new destination dir per case (Q19)
# run_ifa <args…> — the helper with its stderr kept apart; sets RC, ERR, and DELTA (the warning count it added).
run_ifa() {
  local before="${INSTALL_COPY_WARNINGS:-0}"
  RC=0; install_files_atomic "$@" 2>"$TMP/err" || RC=$?
  ERR="$(cat "$TMP/err")"; DELTA=$(( ${INSTALL_COPY_WARNINGS:-0} - before ))
}

echo "== usage =="
run_ifa
[ "$RC" -eq 2 ] && [ "$ERR" = '  WARN: install_files_atomic: usage: <label> <dst_dir> <src>…' ] && [ "$DELTA" -eq 0 ] \
  && t_ok "no arguments: status 2 and the usage line, nothing counted" \
  || t_no "no arguments: rc=$RC delta=$DELTA err=[$ERR]"
run_ifa "only-a-label"
[ "$RC" -eq 2 ] && [ "$DELTA" -eq 0 ] && t_ok "a label alone is a malformed call (status 2)" \
  || t_no "a label alone: rc=$RC delta=$DELTA"
fresh_dst
run_ifa "lbl" "$TMP/dst"
[ "$RC" -eq 0 ] && [ -z "$ERR" ] && [ "$DELTA" -eq 0 ] && [ -z "$(ls -A "$TMP/dst")" ] \
  && t_ok "a label and a destination with no sources is a valid call that installs nothing (status 0)" \
  || t_no "label + destination, no sources: rc=$RC delta=$DELTA err=[$ERR]"

echo "== installs =="
fresh_dst
run_ifa "lbl" "$TMP/dst" "$SRC/alpha.sh" "$SRC/beta.py"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && [ "$DELTA" -eq 0 ] && cmp -s "$SRC/alpha.sh" "$TMP/dst/alpha.sh" \
   && cmp -s "$SRC/beta.py" "$TMP/dst/beta.py" && [ -x "$TMP/dst/alpha.sh" ] && [ ! -x "$TMP/dst/beta.py" ] \
   && [ "$(LC_ALL=C ls -A "$TMP/dst" | tr '\n' ' ')" = 'alpha.sh beta.py ' ]; then
  t_ok "every source lands byte-identical, its exec bit follows the source, no temp is left, nothing is said"
else t_no "install of two sources: rc=$RC delta=$DELTA err=[$ERR] dst=[$(ls -A "$TMP/dst" | tr '\n' ' ')]"; fi

mkdir -p "$TMP/d s"; printf 'spaced\n' > "$SRC/a b.sh"
run_ifa "lbl" "$TMP/d s" "$SRC/a b.sh"
rm -f "$SRC/a b.sh"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && [ "$(cat "$TMP/d s/a b.sh")" = 'spaced' ]; then
  t_ok "a destination dir and a file name with spaces install as one word each"
else t_no "spaces in paths: rc=$RC err=[$ERR]"; fi

fresh_dst
run_ifa "lbl" "$TMP/dst" "$SRC"/*.nomatch "$SRC/absent.sh"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && [ "$DELTA" -eq 0 ] && [ -z "$(ls -A "$TMP/dst")" ]; then
  t_ok "a source that does not exist (an unmatched glob's literal pattern, a named file) is skipped without a word, as cp … || true was"
else t_no "unmatched glob: rc=$RC delta=$DELTA err=[$ERR]"; fi

fresh_dst; ln -s "$SRC/alpha.sh" "$TMP/alpha-link.sh"; : > "$SRC/empty.sh"
run_ifa "lbl" "$TMP/dst" "$TMP/alpha-link.sh" "$SRC/empty.sh"
rm -f "$TMP/alpha-link.sh" "$SRC/empty.sh"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && [ -f "$TMP/dst/alpha-link.sh" ] && [ ! -L "$TMP/dst/alpha-link.sh" ] \
   && cmp -s "$SRC/alpha.sh" "$TMP/dst/alpha-link.sh" && [ -f "$TMP/dst/empty.sh" ] && [ ! -s "$TMP/dst/empty.sh" ]; then
  t_ok "a symlinked source installs as a regular file with its target's bytes, and an empty source as an empty file"
else t_no "symlinked / empty source: rc=$RC err=[$ERR] dst=[$(ls -lA "$TMP/dst" | tr '\n' ' ')]"; fi

echo "== failures are named, counted and do not stop the rest =="
fresh_dst; mkdir "$TMP/dst/alpha.sh"
run_ifa "lbl" "$TMP/dst/" "$SRC/alpha.sh" "$SRC/beta.py"
want="  WARN: lbl — $TMP/dst/alpha.sh install failed: refused: the destination exists and is not a regular file"
if [ "$RC" -eq 1 ] && [ "$ERR" = "$want" ] && [ "$DELTA" -eq 1 ] && cmp -s "$SRC/beta.py" "$TMP/dst/beta.py" \
   && [ -d "$TMP/dst/alpha.sh" ] && [ -z "$(ls -A "$TMP/dst/alpha.sh")" ]; then
  t_ok "a refused file is one WARN (label, destination without a doubled slash, reason) and one count; the next file still installs"
else t_no "partial failure: rc=$RC delta=$DELTA err=[$ERR]"; fi

fresh_dst
printf 'not this one\n' > "$TMP/elsewhere.sh"; ln -s "$TMP/elsewhere.sh" "$TMP/dst/alpha.sh"
run_ifa "lbl" "$TMP/dst" "$SRC/alpha.sh"
if [ "$RC" -eq 1 ] && [ "$DELTA" -eq 1 ] && [ -L "$TMP/dst/alpha.sh" ] \
   && [ "$(cat "$TMP/elsewhere.sh")" = 'not this one' ] && [[ "$ERR" == *"refused: the destination is a symlink (to $TMP/elsewhere.sh)"* ]]; then
  t_ok "a symlinked destination with other bytes is refused and its target is left alone (cp wrote through it)"
else t_no "symlinked destination: rc=$RC delta=$DELTA err=[$ERR] target=[$(cat "$TMP/elsewhere.sh")]"; fi

fresh_dst; ln -s "$TMP/gone.sh" "$SRC/dangling.sh"
run_ifa "lbl" "$TMP/dst" "$SRC/dangling.sh"
rm -f "$SRC/dangling.sh"
if [ "$RC" -eq 1 ] && [ "$DELTA" -eq 1 ] && [ "$ERR" = "  WARN: lbl — $TMP/dst/dangling.sh install failed: source missing: $SRC/dangling.sh" ]; then
  t_ok "a dangling symlink source is a named miss, not a silent skip"
else t_no "dangling source: rc=$RC delta=$DELTA err=[$ERR]"; fi

fresh_dst
run_ifa "lbl" "$TMP/dst" "$SRC"
if [ "$RC" -eq 1 ] && [ "$DELTA" -eq 1 ] && [ "$ERR" = "  WARN: lbl — $TMP/dst/src install failed: source missing: $SRC" ] && [ ! -e "$TMP/dst/src" ]; then
  t_ok "a directory passed as a source (a loose glob) is a named miss, and nothing is created for it"
else t_no "directory source: rc=$RC delta=$DELTA err=[$ERR]"; fi

run_ifa "lbl" "$TMP/no-such-dir" "$SRC/alpha.sh" "$SRC/beta.py"
if [ "$RC" -eq 1 ] && [ "$DELTA" -eq 2 ] && [ ! -e "$TMP/no-such-dir" ] \
   && [ "$(printf '%s\n' "$ERR" | grep -c "install failed: the destination directory does not exist: $TMP/no-such-dir$")" -eq 2 ]; then
  t_ok "a missing destination directory is one named miss per file and is not created"
else t_no "missing destination dir: rc=$RC delta=$DELTA err=[$ERR]"; fi

echo "== the inode a reader holds =="
fresh_dst
printf 'version one\n' > "$TMP/v.txt"; run_ifa "lbl" "$TMP/dst" "$TMP/v.txt"
held=""; ino_before=""
if [ -f "$TMP/dst/v.txt" ]; then             # an exec redirection that fails would end this shell, not one case
  exec 9<"$TMP/dst/v.txt"
  ino_before="$(ls -i "$TMP/dst/v.txt" | awk '{print $1}')"
  printf 'version two, longer\n' > "$TMP/v.txt"; run_ifa "lbl" "$TMP/dst" "$TMP/v.txt"
  held="$(cat <&9)"; exec 9<&-
fi
ino_after="$(ls -i "$TMP/dst/v.txt" | awk '{print $1}')"
if [ "$RC" -eq 0 ] && [ "$held" = 'version one' ] && [ "$(cat "$TMP/dst/v.txt")" = 'version two, longer' ] \
   && [ "$ino_before" != "$ino_after" ]; then
  t_ok "a descriptor opened before the install still reads the old bytes; the path reads the new ones (a new inode)"
else t_no "held reader: held=[$held] now=[$(cat "$TMP/dst/v.txt")] inode $ino_before -> $ino_after"; fi

echo "== a bash script running across the install =="
# run_across <how> — install old run.sh, start it, wait (named pipe) until it is blocked mid-file, replace
# run.sh with a same-length version whose tail differs, release it, print what it printed and whether the
# install really happened (an atomic run that installed nothing would print OLD-TAIL too). Blocking on an
# EXTERNAL command matters: bash discards its read-ahead before it forks, so its next read goes to the file.
mk_script() { printf '#!/bin/bash\nprintf "start\\n"\nprintf "ready\\n" > "$2"\nhead -n 1 "$1" > /dev/null\nprintf "%s\\n"\n' "$1"; }
run_across() {
  local how="$1" d="$TMP/run-$1" out
  rm -rf "$d"; mkdir -p "$d/src" "$d/dst"
  mk_script OLD-TAIL > "$d/src/run.sh"; install_files_atomic "lbl" "$d/dst" "$d/src/run.sh" 2>/dev/null
  mk_script NEW-TAIL > "$d/src/run.sh"
  mkfifo "$d/go" "$d/ready"
  exec 7<>"$d/ready" 8<>"$d/go"          # read-write opens never block, and keep each pipe open
  bash "$d/dst/run.sh" "$d/go" "$d/ready" > "$d/out" 2>&1 &
  local pid=$! line=""
  if read -r -t 20 line <&7 && [ "$line" = ready ]; then
    case "$how" in
      atomic) install_files_atomic "lbl" "$d/dst" "$d/src/run.sh" 2>/dev/null ;;
      cp)     cp "$d/src/run.sh" "$d/dst/run.sh" ;;
    esac
  else
    echo "harness: the script never reported ready" > "$d/out.harness"
  fi
  printf 'go\n' >&8
  wait "$pid" 2>/dev/null
  exec 7<&- 8<&-
  if cmp -s "$d/src/run.sh" "$d/dst/run.sh"; then echo installed >> "$d/out.harness"
  else echo NOT-installed >> "$d/out.harness"; fi
  out="$(cat "$d/out" "$d/out.harness" 2>/dev/null | tr '\n' ' ')"
  printf '%s' "${out% }"
}
got="$(run_across atomic)"
[ "$got" = 'start OLD-TAIL installed' ] && t_ok "installed by rename, a running script finishes its own code (start OLD-TAIL), and the new file is in place" \
  || t_no "running script across an atomic install printed [$got]"
got="$(run_across cp)"
[ "$got" = 'start NEW-TAIL installed' ] && t_ok "control: the same run across a plain cp executes the NEW tail (start NEW-TAIL) — the scenario sees the defect" \
  || t_no "control run across plain cp printed [$got] — the scenario no longer reproduces the defect, so the case above proves nothing"

echo "== copy_hooks_lib_except_collisions =="
H="$TMP/hooks-lib"; L="$TMP/scripts-lib"; X="$TMP/host-lib"
mkdir -p "$H" "$L" "$X"
printf 'hook helper\n' > "$H/helper.sh"; printf 'hooks copy\n' > "$H/shared.sh"; printf 'print(1)\n' > "$H/tool.py"
printf 'runner copy\n' > "$L/shared.sh"; printf 'runner copy\n' > "$X/shared.sh"
printf 'fresh\n' > "$H/extra.sh"; printf 'stale\n' > "$X/extra.sh"   # already in the host lib, not in scripts/lib
before="${INSTALL_COPY_WARNINGS:-0}"; rc=0
copy_hooks_lib_except_collisions "$H" "$L" "$X" 2>"$TMP/err" || rc=$?
if [ "$rc" -eq 0 ] && [ -z "$(cat "$TMP/err")" ] && cmp -s "$H/helper.sh" "$X/helper.sh" && cmp -s "$H/tool.py" "$X/tool.py" \
   && [ "$(cat "$X/shared.sh")" = 'runner copy' ] && [ "$(cat "$X/extra.sh")" = 'fresh' ] \
   && [ "${INSTALL_COPY_WARNINGS:-0}" -eq "$before" ]; then
  t_ok "hooks/lib files land in the host lib (an older copy there is replaced), and only a name scripts/lib also ships keeps the runner's copy"
else t_no "copy_hooks_lib_except_collisions: rc=$rc err=[$(cat "$TMP/err")] shared=[$(cat "$X/shared.sh")]"; fi
mkdir "$X/helper2.sh"; printf 'second\n' > "$H/helper2.sh"
rc=0; copy_hooks_lib_except_collisions "$H" "$L" "$X" 2>"$TMP/err" || rc=$?
if [ "$rc" -eq 1 ] && [ "$(cat "$TMP/err")" = "  WARN: hooks/lib — $X/helper2.sh install failed: refused: the destination exists and is not a regular file" ]; then
  t_ok "a hooks/lib file that cannot install is named under the hooks/lib label and fails the call"
else t_no "copy_hooks_lib_except_collisions failure: rc=$rc err=[$(cat "$TMP/err")]"; fi
mkdir -p "$TMP/empty-hooks"; rc=0
copy_hooks_lib_except_collisions "$TMP/empty-hooks" "$L" "$TMP/nowhere" 2>"$TMP/err" || rc=$?
[ "$rc" -eq 0 ] && [ -z "$(cat "$TMP/err")" ] && [ ! -e "$TMP/nowhere" ] \
  && t_ok "an empty hooks/lib installs nothing and says nothing" \
  || t_no "empty hooks/lib: rc=$rc err=[$(cat "$TMP/err")]"

printf '  --- install files atomic: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
