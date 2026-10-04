#!/usr/bin/env bash
# tests/lib/adversarial-driver.sh — scripts/adversarial-review.sh as a TEST sees it since the driver was
# split into modules (scripts/lib/adversarial-*.sh, loaded by the driver's "Driver modules" section).
#
# Two needs changed with the split, and each has one function here so no suite grows its own copy:
#   * a SOURCE assertion ("the driver contains X", "the driver never does Y") must read the whole
#     program, not the driver file alone — against the bare file an absence check passes vacuously,
#     because the code it guards now lives in a module;
#   * a suite that lays out a driver COPY must copy its modules with it — a copy of the file alone
#     exits 2 at the module check before reaching anything the suite means to test.
#
#   adv_driver_modules <driver>
#       The module file names <driver> loads (its AR_MODULES), one per line.
#   adv_driver_module_dir <driver>
#       The directory those modules are in for <driver>: <dir>/lib, else <dir> — the loader's own order,
#       first directory holding every module. Status 1 (nothing printed) when neither does, or when
#       <driver> names no modules at all (an empty list would make any directory "complete").
#   adv_driver_source <driver>
#       <driver> with each module inlined at its `. "$AR_LIB_DIR/<module>"` line: the one program text
#       the single-file driver used to be (plus module headers and the phase wrappers). Status 1, with
#       the reason on stderr, when a module is missing or unreadable, when a line sources from
#       $AR_LIB_DIR in a shape this cannot inline, or when the modules inlined are not exactly AR_MODULES,
#       in its order — a program text with a module silently left out would let an absence check pass.
#   adv_driver_copy <driver> <dest> [lib|flat]
#       Copy <driver> to the path <dest> (made executable) and its modules beside it: into
#       <dest dir>/lib/ (default — the repo, cache and host layout) or <dest dir>/ (flat). Nothing else is
#       copied: model-subprocess.sh, blind-audit-panel.sh and the registry stay each suite's own choice.
#   adv_driver_file_with <driver> <text>
#       The one file — <driver> or one of its modules — with a line containing <text>, exactly one such
#       line across all of them. Status 1 (and the count on stderr) otherwise. For a suite that mutates one
#       line of the program: it must change the file the line is in.
#
# Sourced, never executed; defines these functions only. bash 3.2-compatible.

adv_driver_modules() {
  awk '/^AR_MODULES="/ { f = 1; sub(/^AR_MODULES="/, "") }
       f { line = $0; done = sub(/".*$/, "", line); n = split(line, w, /[[:space:]]+/)
           for (i = 1; i <= n; i++) if (w[i] != "") print w[i]
           if (done) exit }' "$1"
}

adv_driver_module_dir() {
  local d c m ok mods
  mods="$(adv_driver_modules "$1")"
  [ -n "$mods" ] || return 1
  d="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || return 1
  for c in "$d/lib" "$d"; do
    ok=1
    for m in $mods; do [ -f "$c/$m" ] || { ok=0; break; }; done
    if [ "$ok" -eq 1 ]; then printf '%s\n' "$c"; return 0; fi
  done
  return 1
}

adv_driver_source() {
  local md want
  md="$(adv_driver_module_dir "$1")" || { echo "adv_driver_source: no module directory beside $1" >&2; return 1; }
  want="$(adv_driver_modules "$1" | tr '\n' ' ')"
  awk -v md="$md" -v want="$want" '
    /^[[:space:]]*(\.|source)[[:space:]].*AR_LIB_DIR/ {
      if (!match($0, /^\. "\$AR_LIB_DIR\/[^"\/]+"/)) {
        print "adv_driver_source: cannot inline this module line: " $0 > "/dev/stderr"; bad = 1; next
      }
      f = substr($0, RSTART + 15, RLENGTH - 16); first = 1; got = 0
      while ((r = (getline line < (md "/" f))) > 0) {
        got = 1
        if (first && line == "# shellcheck shell=bash") { first = 0; continue }
        first = 0; print line
      }
      if (r < 0 || !got) { print "adv_driver_source: cannot read " md "/" f > "/dev/stderr"; bad = 1 }
      close(md "/" f); got_list = got_list f " "; next
    }
    { print }
    END {
      if (got_list != want) { print "adv_driver_source: inlined [" got_list "], AR_MODULES names [" want "]" > "/dev/stderr"; bad = 1 }
      exit bad
    }' "$1"
}

adv_driver_copy() {
  local src="$1" dest="$2" layout="${3:-lib}" md to m
  md="$(adv_driver_module_dir "$src")" || { echo "adv_driver_copy: no module directory beside $src" >&2; return 1; }
  to="$(dirname "$dest")"; [ "$layout" = flat ] || to="$to/lib"
  mkdir -p "$(dirname "$dest")" "$to" || return 1
  cp "$src" "$dest" && chmod +x "$dest" || return 1
  for m in $(adv_driver_modules "$src"); do cp "$md/$m" "$to/$m" || return 1; done
}

adv_driver_file_with() {
  local md m f n total=0 hit=""
  md="$(adv_driver_module_dir "$1")" || return 1
  # Module NAMES are single words; the paths are built here, so a directory with a space stays one path.
  for m in "" $(adv_driver_modules "$1"); do
    if [ -z "$m" ]; then f="$1"; else f="$md/$m"; fi
    n="$(ADV_DFW_TEXT="$2" awk 'index($0, ENVIRON["ADV_DFW_TEXT"]) { c++ } END { print c + 0 }' "$f")" \
      || { echo "adv_driver_file_with: cannot read $f" >&2; return 1; }
    total=$((total + n)); [ "$n" -eq 0 ] || hit="$f"
  done
  if [ "$total" -ne 1 ]; then echo "adv_driver_file_with: the line occurs $total time(s), not once" >&2; return 1; fi
  printf '%s\n' "$hit"
}
