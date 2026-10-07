#!/usr/bin/env bash
# scripts/install.d/copy.sh — part of scripts/install.sh, which sources it; not runnable alone.
# Copy primitives every host installer uses: verify_copied, install_file_atomic, install_runner_lib,
# the hooks/lib vs scripts/lib name-collision guards, and the prune of what a release no longer ships.

# verify_copied <label> <src_dir> <dst_dir> <name> [<name>…]
verify_copied() {
  local label="$1" src="$2" dst="$3"; shift 3
  local n miss=0
  for n in "$@"; do
    [ -f "$src/$n" ] || continue          # never attempted — not a failure
    # Bytes, not presence: existing content may be from an older release, and a 0-byte copy of a
    # non-empty source differs too. (Not `-s`: an EMPTY source copied as empty is a correct copy.)
    if [ ! -f "$dst/$n" ] || ! cmp -s "$src/$n" "$dst/$n"; then
      miss=$((miss + 1))
      INSTALL_VERIFY_DETAIL="${INSTALL_VERIFY_DETAIL}
      $label: $dst/$n"
    fi
  done
  if [ "$miss" -gt 0 ]; then
    INSTALL_VERIFY_MISSING=$((INSTALL_VERIFY_MISSING + miss))
    fail "$label: $miss file(s) did NOT install — see the summary below"
    return 1
  fi
  return 0
}

# install_file_atomic <src> <dst> — put ONE file at <dst>, atomically, every step checked. Status 0
# and no output when <dst> ends up a regular file byte-identical to <src>; otherwise status 1 and the
# reason on stdout (for the caller's INSTALL_VERIFY_DETAIL). In order:
#   - a symlinked <dst> is the user's choice (a dotfile manager, a dev link into a checkout): `mv`
#     would replace the LINK with a copy, turning a live link into a stale file while its target never
#     changed. One that already reaches the source's bytes (and exec bit) is left alone, status 0; any
#     other is refused, naming where it points;
#   - refuse a <dst> that exists and is not a regular file: `mv -f tmp <a directory>` moves the temp
#     INTO the directory and returns 0 — the file never lands and the directory gains a stray;
#   - mktemp the temp IN <dst>'s directory (same filesystem, so mv is a rename — a reader never sees
#     a half-written file). mktemp creates it exclusively under an unpredictable name; a fixed
#     `.name.tmp.$$` can be pre-planted as a symlink that `cp` follows and `mv` then installs;
#   - cp into it, and cmp the TEMP against <src> — BEFORE anything replaces <dst>. A copy that
#     "succeeds" with the wrong bytes (truncated, disk full mid-write) is caught while <dst> still
#     holds whatever it held; the first version checked only after the mv, when a corrupted copy had
#     already replaced a good file;
#   - chmod it (mktemp makes it 0600; the exec bit follows the source), mv it over <dst>;
#   - <dst> a directory NOW: the check above is not atomic with the mv, and one that became a directory
#     in between got the temp moved INTO it. The temp is taken back out and the cause named;
#   - cmp <src> <dst> once more: what a reader now opens at <dst> is what was checked.
# The verdict is the steps, not a final cmp alone: a cmp against a destination that ALREADY held the
# right bytes from an earlier install passed while every step had failed. A failure after mktemp
# removes the temp. Safe under the caller's `set -e` (call it in an `if`).
install_file_atomic() {
  local src="$1" dst="$2" tmp mode=644
  if [ ! -f "$src" ]; then printf 'source missing: %s' "$src"; return 1; fi
  if [ -L "$dst" ]; then
    if [ -f "$dst" ] && cmp -s "$src" "$dst" && { [ ! -x "$src" ] || [ -x "$dst" ]; }; then return 0; fi
    printf 'refused: the destination is a symlink (to %s) — remove it, or point it at the current file' "$(readlink "$dst" 2>/dev/null)"
    return 1
  fi
  if [ -e "$dst" ] && [ ! -f "$dst" ]; then printf 'refused: the destination exists and is not a regular file'; return 1; fi
  if ! tmp="$(mktemp "${dst%/*}/.${dst##*/}.XXXXXX" 2>/dev/null)"; then printf 'mktemp failed (in %s)' "${dst%/*}"; return 1; fi
  if ! cp "$src" "$tmp" 2>/dev/null; then rm -f "$tmp"; printf 'cp failed'; return 1; fi
  if ! cmp -s "$src" "$tmp"; then rm -f "$tmp"; printf 'content check failed (the copy differs from the source; the destination was left as it was)'; return 1; fi
  if [ -x "$src" ]; then mode=755; fi
  if ! chmod "$mode" "$tmp" 2>/dev/null; then rm -f "$tmp"; printf 'chmod failed'; return 1; fi
  if ! mv -f "$tmp" "$dst" 2>/dev/null; then rm -f "$tmp"; printf 'mv failed'; return 1; fi
  if [ -d "$dst" ]; then
    rm -f "$dst/${tmp##*/}"
    printf 'refused: the destination became a directory during the install (the temp was taken back out of it)'
    return 1
  fi
  if ! cmp -s "$src" "$dst"; then printf 'content check failed after the move (the installed bytes differ from the source)'; return 1; fi
  return 0
}
# ADV_DRIVER_SRC — this checkout's adversarial driver, for the functions that only READ it (its module list,
# its stamp), so test-install-wiring (14b)'s "names the driver's file" keeps meaning "copies the driver".
ADV_DRIVER_SRC="$ZUVO_DIR/scripts/adversarial-review.sh"
# _adv_module_names — the adversarial driver's modules (its AR_MODULES, read from this checkout's
# driver), one per line; nothing when the list cannot be read, when it holds a name that is not a plain file name
# (letters, digits, '.', '_', '-'; not starting with '-', not all dots), or when anything but a comment follows its
# closing quote: the names are word-split into test and cat paths, so a list that could expand, climb or read as
# an option, or that bash would read differently, is treated as no list at all.
_adv_module_names() {
  awk '!f && /^[[:space:]]*AR_MODULES="/ { f = 1; sub(/^[[:space:]]*AR_MODULES="/, "") }
    f { l = $0; r = l; d = sub(/".*$/, "", l)
        if (d) { sub(/^[^"]*"/, "", r); if (r !~ /^[[:space:]]*(#.*)?$/) bad = 1 }
        n = split(l, w, /[[:space:]]+/)
        for (i = 1; i <= n; i++) if (w[i] != "") { if (w[i] !~ /^[A-Za-z0-9._][A-Za-z0-9._-]*$/ || w[i] ~ /^[.]+$/) bad = 1; out[++k] = w[i] }
        if (d) exit }
    END { if (!bad) for (i = 1; i <= k; i++) print out[i] }' \
    "$ADV_DRIVER_SRC" 2>/dev/null
}

# install_adv_module_stamp <label> <src_dir> <dst_dir> <ok 1|0> — after the driver's modules were copied from
# <src_dir> into <dst_dir>, write <dst_dir>/adversarial-modules.cksum: the cksum of this checkout's driver
# ($ADV_DRIVER_SRC, which every target installs byte for byte) and of the modules as <src_dir> holds them, or
# "install-incomplete" (<ok> 0, a module list that cannot be read, a set whose sum cannot be taken). Written LAST and
# atomically, so the loader never runs a set half old, half new. Status 1 (counted, named) for a miss this function
# finds — a module the source lacks though <ok> said 1, a set that cannot be summed, a clean set's stamp that
# cannot be written. After a miss the caller reported (<ok> 0) and already counted, a stamp that cannot be
# written is only warned and the status is 0. A module list that cannot be read is this function's miss whenever a
# destination exists to stamp (no caller counts it before calling: install_zuvo_home_modules stops before it). A
# destination that does not exist (its mkdir failed, every file already counted) is status 0.
install_adv_module_stamp() {
  local label="$1" src="$2" dst="$3" ok="$4" names tmp reason
  names="$(_adv_module_names)"
  [ -d "$dst" ] || return 0
  local m rc=0 err was_ok="$ok"
  if [ -z "$names" ]; then
    # Without the list nothing can be summed or vouched for: counted, and the set goes to the install-incomplete
    # marker below like any other miss (a marker that cannot be written there is said, and the status stays 1).
    if [ -r "$ADV_DRIVER_SRC" ]; then reason="no AR_MODULES list, or a name in it that is not a plain file name"
    else reason="the driver cannot be read"; fi
    _runner_lib_miss "$label" "$dst/adversarial-modules.cksum" "no usable AR_MODULES list in $ADV_DRIVER_SRC ($reason) — the set cannot be stamped"
    ok=0; rc=1
  fi
  # Every module must be there, or the stamp would sum a set no install holds. Where the set is copied
  # (install_runner_lib, install_zuvo_home_modules) such a miss is counted and <ok> is already 0; every one the
  # caller did not report (<ok> 1 on entry) is counted here.
  for m in $names; do
    [ -f "$src/$m" ] && continue
    if [ "$was_ok" = 1 ]; then
      _runner_lib_miss "$label" "$dst/$m" "source missing: $src/$m — the driver beside it will refuse that module set"
      rc=1
    fi
    ok=0
  done
  if ! tmp="$(mktemp 2>/dev/null)"; then
    [ "$ok" = 1 ] || { warn "$label: adversarial-modules.cksum not written (mktemp failed)"; return "$rc"; }
    _runner_lib_miss "$label" "$dst/adversarial-modules.cksum" "mktemp failed — the driver beside it will refuse that module set"
    return 1
  fi
  # shellcheck disable=SC2086,SC2069  # module names, one word each; stderr into $err, the sum into $tmp
  # The driver's bytes first, then the modules', as the loader sums them: an install caught between the modules
  # and the driver never pairs an old bootstrap with new modules that call functions it lacks.
  if [ "$ok" = 1 ] && ! err="$( ( set -o pipefail; { cat "$ADV_DRIVER_SRC" && cd "$src" && cat -- $names; } | cksum ) 2>&1 > "$tmp" )"; then
    # Every module copied, yet the set cannot be summed (a file unreadable, cksum failing): nothing upstream
    # counted a miss, so it is counted here, or the install would report success over a set the driver refuses.
    _runner_lib_miss "$label" "$dst/adversarial-modules.cksum" "the driver and its modules could not be summed${err:+ (${err%%$'\n'*})} — the driver beside it will refuse that module set"
    ok=0; rc=1
  fi
  if [ "$ok" != 1 ] && ! printf 'install-incomplete\n' 2>/dev/null > "$tmp"; then
    rm -f "$tmp"
    warn "$label: $dst/adversarial-modules.cksum could not be marked install-incomplete (the marker could not be written to its temp file $tmp)"
    return "$rc"
  fi
  if ! reason="$(install_file_atomic "$tmp" "$dst/adversarial-modules.cksum")"; then
    rm -f "$tmp"
    # After a miss (a module, or the sum) this refusal is already counted. A refusal before the move leaves the
    # previous stamp: it matches the set only if this run changed none of its bytes, and the driver refuses any
    # other set until a reinstall. After a clean set it is news: the driver will refuse that set until a reinstall.
    if [ "$ok" = 1 ]; then
      _runner_lib_miss "$label" "$dst/adversarial-modules.cksum" "$reason — the driver beside it will refuse that module set"
      return 1
    fi
    warn "$label: adversarial-modules.cksum could not be marked install-incomplete either ($reason)"
    return "$rc"
  fi
  rm -f "$tmp"
  return "$rc"
}

# install_runner_lib <label> <src_lib_dir> <dst_scripts_dir> — ship the shared script libraries, EVERY
# regular file of <src_lib_dir> (scripts/lib/, or a build's dist/<platform>/scripts/lib/), into
# <dst_scripts_dir>/lib/: the first place the adversarial driver copied into <dst_scripts_dir> looks
# for its runner, model-subprocess.sh (<dir>/lib/ → <dir>/ → ~/.zuvo/). Every host that gets its own
# copy of the driver (~/.codex/scripts, ~/.cursor/scripts, ~/.gemini/antigravity/scripts,
# ~/.kimi-code/scripts) gets its libraries through here, and so does ~/.zuvo/lib/ (install_zuvo_home),
# so a driver and its libraries always come from the same install. ~/.zuvo alone is not enough:
# `install.sh claude` refreshes ~/.zuvo and leaves ~/.codex/scripts as it was, and a host driver that
# could only reach ~/.zuvo would run against a library from a different install. Every Claude cache
# dir gets its scripts/lib/ through here too.
#
# The whole directory, not a list of names: a library added to scripts/lib/ later (Plan B's
# blind-audit-panel.sh) must reach every host with no installer change, not go silently missing.
#
# Every file goes through install_file_atomic (a review starting mid-install must never source a
# half-written file), and every miss is counted and named for the INSTALL INCOMPLETE summary with the
# step that failed — never swallowed. One miss does not stop the other files. model-subprocess.sh is
# REQUIRED: a source dir without it is a miss (the driver cannot work without it; a driver that
# lacks it still starts, warns once, and loses its codex and claude lanes). Status 0 all installed,
# 1 not.
install_runner_lib() {
  local label="$1" src="$2" dst="$3/lib" f reason rc=0 mkdir_err="" mod_ok=1 names
  if ! mkdir -p "$dst" 2>/dev/null; then mkdir_err="mkdir failed: $dst"; fi
  if [ ! -f "$src/model-subprocess.sh" ]; then
    _runner_lib_miss "$label" "$dst/model-subprocess.sh" "source missing: $src/model-subprocess.sh"
    rc=1
  fi
  names=" $(_adv_module_names | tr '\n' ' ')"
  for f in "$src"/*; do
    [ -f "$f" ] || continue
    if [ -n "$mkdir_err" ]; then
      reason="$mkdir_err"
    elif reason="$(install_file_atomic "$f" "$dst/${f##*/}")"; then
      continue
    fi
    _runner_lib_miss "$label" "$dst/${f##*/}" "$reason"
    rc=1
    case "$names" in *" ${f##*/} "*) mod_ok=0 ;; esac
  done
  # A module the driver names but the source lacks escapes the glob above: counted here, by name.
  for f in $names; do
    [ -f "$src/$f" ] && continue
    _runner_lib_miss "$label" "$dst/$f" "source missing: $src/$f"
    rc=1; mod_ok=0
  done
  # The adversarial driver's modules, as a SET: their stamp, written after every one of them.
  install_adv_module_stamp "$label" "$src" "$dst" "$mod_ok" || rc=1
  return "$rc"
}

# lib_name_collisions <hooks_lib_dir> <scripts_lib_dir> — every file name (space-separated, empty when
# none) that BOTH would put into one <host>/scripts/lib/: the Codex and Cursor installs copy
# hooks/lib/*.sh|*.py into the same directory install_runner_lib fills from scripts/lib/, so a shared
# name silently replaces a runner library with a hook helper (or the other way round).
lib_name_collisions() {
  local f out=""
  for f in "$1"/*.sh "$1"/*.py; do
    [ -f "$f" ] || continue
    if [ -e "$2/${f##*/}" ]; then out="$out ${f##*/}"; fi
  done
  printf '%s' "${out# }"
}

# guard_lib_collisions <label> <hooks_lib_dir> <scripts_lib_dir> <dst_lib_dir> — fail LOUDLY on any
# collision lib_name_collisions finds: each name is an install miss (INSTALL INCOMPLETE), named with
# the destination it corrupts. Status 0 none, 1 some. Cheap: two directory listings, no copy.
guard_lib_collisions() {
  local label="$1" c n
  c="$(lib_name_collisions "$2" "$3")"
  [ -z "$c" ] && return 0
  for n in $c; do
    INSTALL_VERIFY_MISSING=$((INSTALL_VERIFY_MISSING + 1))
    INSTALL_VERIFY_DETAIL="${INSTALL_VERIFY_DETAIL}
      $label: $4/$n — hooks/lib/$n and scripts/lib/$n share a name, and one copy replaces the other"
  done
  fail "$label: hooks/lib/ and scripts/lib/ both ship [$c] into $4 — one silently replaces the other (rename one of them)"
  return 1
}

# copy_hooks_lib_except_collisions <hooks_lib_dir> <scripts_lib_dir> <dst_lib_dir> — hooks/lib/*.sh|*.py into
# <dst>, SKIPPING any name scripts/lib/ also ships. guard_lib_collisions already failed the install loudly
# for those; copying them anyway would still overwrite the runner library install_runner_lib put there
# (model-subprocess.sh & co.), breaking the adversarial driver's codex/claude lanes until the rename.
copy_hooks_lib_except_collisions() {
  local f rc=0
  for f in "$1"/*.sh "$1"/*.py; do
    [ -f "$f" ] || continue
    [ -e "$2/${f##*/}" ] && continue
    cp "$f" "$3/" || rc=1
  done
  return "$rc"
}

# prune_absent <label> <src_dir> <dst_dir> <d|f> [<keep>...] — remove from <dst_dir> every directory (d) or
# file (f) that <src_dir> no longer has, except the names in <keep>: files the installer itself writes
# there and no source has (the driver modules' install stamp, adversarial-modules.cksum). ONLY for a destination zuvo alone writes (a Claude cache dir, the Codex
# plugin cache): the copies into those only add and overwrite, and a new version dir is seeded from the
# previous one, so without this a retired skill or script stays installed and loaded indefinitely.
# Call it AFTER the copy, so a failed copy never leaves a tree that lost entries and gained nothing.
# Guards: a symlinked <dst> is refused; a source with no entry of that kind prunes nothing; and a run
# that would remove more than 3 entries AND more than half of those considered is refused as a
# partial source.
# Always status 0 — pruning is cleanup, never a reason to abort the other cache dirs; failures warn.
prune_absent() {
  local label="$1" src="$2" dst="$3" kind="$4" e k have=0 total=0
  local -a gone=() keep=("${@:5}")
  [ -d "$src" ] && [ -d "$dst" ] || return 0
  if [ -L "$dst" ]; then warn "prune $label: $dst is a symlink — not pruned"; return 0; fi
  for e in "$src"/*; do
    if { [ "$kind" = d ] && [ -d "$e" ]; } || { [ "$kind" = f ] && [ -f "$e" ]; }; then have=1; break; fi
  done
  [ "$have" -eq 1 ] || return 0
  for e in "$dst"/*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    if [ "$kind" = d ]; then
      [ -d "$e" ] && [ ! -L "$e" ] || continue
    else
      [ -L "$e" ] || { [ -f "$e" ] && [ ! -d "$e" ]; } || continue
    fi
    for k in ${keep[@]+"${keep[@]}"}; do [ "${e##*/}" = "$k" ] && continue 2; done
    total=$((total + 1))
    [ -e "$src/${e##*/}" ] || [ -L "$src/${e##*/}" ] || gone+=("$e")
  done
  _prune_apply "$label" "$total" ${gone[@]+"${gone[@]}"}
  return 0
}

# prune_retired_skills <label> <src_skills_dir> <dst_skills_dir> — prune_absent for a skills directory
# zuvo SHARES with the user and other packages (~/.codex/skills): a directory goes only when the source
# no longer ships it AND the first heading after the frontmatter of its (non-symlinked) SKILL.md is
# `# zuvo:<that name>`, alone or followed by a space — compared as a string, never as a pattern. That
# heading is what every zuvo skill carries, so skills retired before this existed are found too, and
# anyone else's skill is left alone. Same guards and status as prune_absent.
prune_retired_skills() {
  local label="$1" src="$2" dst="$3" e name head have=0 total=0
  local -a gone=()
  [ -d "$src" ] && [ -d "$dst" ] || return 0
  if [ -L "$dst" ]; then warn "prune $label: $dst is a symlink — not pruned"; return 0; fi
  for e in "$src"/*/; do [ -d "$e" ] && { have=1; break; }; done
  [ "$have" -eq 1 ] || return 0
  for e in "$dst"/*/; do
    [ -d "$e" ] && [ ! -L "${e%/}" ] || continue
    name="${e%/}"; name="${name##*/}"
    [ -f "$e/SKILL.md" ] && [ ! -L "$e/SKILL.md" ] || continue
    head="$(awk 'NR == 1 && /^---/ { fm = 1; next } fm && /^---/ { fm = 0; next } !fm && /^# / { print; exit }' \
            "$e/SKILL.md" 2>/dev/null || true)"
    case "$head" in "# zuvo:$name"|"# zuvo:$name "*) ;; *) continue ;; esac
    total=$((total + 1))
    [ -e "$src/$name" ] || gone+=("${e%/}")
  done
  _prune_apply "zuvo skill(s) in $label" "$total" ${gone[@]+"${gone[@]}"}
  return 0
}

# _prune_apply <label> <considered> <path>… — remove the paths, unless they are most of what was
# considered (a partial source looks exactly like "everything was retired"); name every failure.
_prune_apply() {
  local label="$1" total="$2" p n=0; shift 2
  [ "$#" -gt 0 ] || return 0
  if [ "$#" -gt 3 ] && [ $(( $# * 2 )) -gt "$total" ]; then
    warn "prune $label: would remove $# of $total entries — looks like a partial source, nothing removed"
    return 0
  fi
  for p in "$@"; do
    if rm -rf -- "${p:?}" 2>/dev/null; then n=$((n + 1))
    else warn "prune $label: could not remove $p"; INSTALL_COPY_WARNINGS=$((INSTALL_COPY_WARNINGS + 1)); fi
  done
  [ "$n" -eq 0 ] || echo "  pruned $n retired $label"
}

# _runner_lib_miss <label> <dst_path> <reason> — count and name one library that did not install.
_runner_lib_miss() {
  local lanes=""
  case "$2" in */model-subprocess.sh) lanes=" — the driver beside it loses its codex and claude review lanes" ;; esac
  INSTALL_VERIFY_MISSING=$((INSTALL_VERIFY_MISSING + 1))
  INSTALL_VERIFY_DETAIL="${INSTALL_VERIFY_DETAIL}
      $1: $2 — $3"
  fail "$1: ${2##*/} did NOT install ($3)$lanes"
}
