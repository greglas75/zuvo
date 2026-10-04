#!/usr/bin/env bash
# install-manifest.sh — run scripts/install.sh in sandbox HOMEs and print a normalized manifest of
# everything it did: exit status, output, and every file/link it left behind (mode + content hash).
#
# Why: install.sh writes into five hosts and ~/.zuvo, and most of what it does is only visible as
# files on disk. Its own tests grep its text or call single functions; nothing captured the whole
# effect. This prints that effect in a form two runs can be DIFFED, so a change that must not alter
# behaviour (a refactor, a move into scripts/install.d/) can be compared against the tree before it:
#
#   rt --light bash tests/lib/install-manifest.sh > before.txt      # on the old tree
#   rt --light bash tests/lib/install-manifest.sh > after.txt       # on the new tree
#   diff before.txt after.txt                                       # empty = same behaviour
#
# Not named test-*.sh on purpose: run-all must not pick it up. It is a comparison tool, not a
# verdict — its absolute checks (the PASS/FAIL lines) only guard against a vacuous comparison where
# both trees fail the same way early.
#
# Everything runs under a temp HOME, a temp git config and a temp dist root: nothing touches the
# real ~/.claude, ~/.zuvo, ~/.zshenv, ~/.gitconfig or the repo's dist/.
#
# Normalization (so two runs of the SAME tree print the same bytes, and two checkouts of it too):
# umask-controlled group/other write bits are dropped from modes; sandbox paths become <HOME>,
# <TMP>, <REPO>; ISO timestamps, epoch stamps and pid-suffixed temp names are masked. Installed
# copies of install.sh (it ships flat into the plugin cache) are reported as same-as-source or
# DIFFERS instead of by hash — the installer is the file a refactor of the installer changes, but
# a copy that is not the source is still caught. .pyc files are listed unhashed: their header
# carries the source mtime.
#
# Usage: install-manifest.sh [scenario...]     (default: all scenarios, in order)
set -u
# One umask for everything this harness and the installer create — the sandbox HOMEs, TMPDIRs and every
# installed file — so a mode in the manifest is the installer's decision, not the farm host's umask.
umask 022

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL="${ZUVO_MANIFEST_INSTALL:-$ROOT/scripts/install.sh}"
[ -n "${BASH:-}" ] || BASH="$(command -v bash)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "FAIL: mktemp -d failed"; echo "RESULT: PASS=0 FAIL=1"; exit 1; }

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/package.json")"

# A HOME in which every host install_* looks for is present, so every installer runs its real path.
make_home() {
  local h="$1"
  # Two older cache dirs, shaped like ones Claude Code created (install_claude syncs into every
  # existing dir and refuses one without shared/includes and rules). Two, so the keep-current-plus-
  # previous pruning has one to remove: 0.0.1 must go, 0.0.2 and the current version must stay.
  local seed v
  for v in 0.0.1 0.0.2; do
    seed="$h/.claude/plugins/cache/zuvo-marketplace/zuvo/$v"
    mkdir -p "$seed/skills/old-skill" "$seed/shared/includes" "$seed/rules" "$seed/scripts" "$seed/bin" "$seed/docs"
    printf '# old seed %s\n' "$v" > "$seed/skills/old-skill/SKILL.md"
  done
  mkdir -p "$h/.codex/skills" "$h/.codex/agents" "$h/.cursor/skills" "$h/.cursor/agents" \
           "$h/.gemini/antigravity" "$h/.kimi-code" "$h/.config"
  printf '{\n  "plugins": {\n    "zuvo@zuvo-marketplace": [\n      {"version": "0.0.1", "gitCommitSha": "0000000"}\n    ]\n  }\n}\n' \
    > "$h/.claude/plugins/installed_plugins.json"
  printf '{}\n' > "$h/.claude/settings.json"
  printf '# kimi config\n' > "$h/.kimi-code/config.toml"
}

# Run install.sh with an isolated environment. PATH is the caller's (the builds need python3/jq),
# but no provider CLI is expected on it; whatever is there is the same for both trees.
# Each scenario gets its OWN TMPDIR (<home>.tmp), walked like HOME: a file the installer leaves in
# TMPDIR is part of what it did. And a fixed umask 022, so every mode is recorded exactly — modes used
# to be masked with ~0o022 to hide the checkout's umask, which also hid a 0644 -> 0666 change.
run_install() {
  local h="$1"; shift
  mkdir -p "$h.tmp"
  ( umask 022
    env -i PATH="$PATH" HOME="$h" TMPDIR="$h.tmp" LANG=C LC_ALL=C \
      GIT_CONFIG_GLOBAL="$h/.gitconfig" GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$h/.config" \
      ZUVO_DIST_ROOT="$h.dist" "$BASH" "$INSTALL" "$@" > "$h.out" 2>&1 )
  echo $?
}

# The masks every normalization applies — the output, file names, file bodies — in ONE place: the
# tree used fewer of them than the output did, so a body holding a `.tmp.<pid>` name or a dated backup
# name hashed differently on every run.
MASKS_PY='
import re
def mask_paths(t, home, work, root):
    return (t.replace(home + ".dist", "<DIST>").replace(home + ".tmp", "<TMPDIR>").replace(home, "<HOME>")
             .replace(work, "<TMP>").replace(root, "<REPO>"))
def mask(t):
    t = re.sub(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z?", "<TS>", t)
    t = re.sub(r"\d{8}-\d{6}", "<TS>", t)
    t = re.sub(r"\.(tmp|zuvo-tmp)\.\d+", r".\1.<PID>", t)
    t = re.sub(r"(bundle)\.[A-Za-z0-9]{6}\b", r"\1.<RAND>", t)
    return re.sub(r"(asserted_at=)\d+", r"\1<EPOCH>", t)
'

# Normalize a text file: sandbox paths, timestamps, pids. (A file argument, not stdin: the
# heredoc below IS python's stdin.)
normalize() {
  local h="$1" file="$2"
  python3 - "$h" "$WORK" "$ROOT" "$file" "$MASKS_PY" <<'PYEOF'
import sys
home, work, root, path, masks = sys.argv[1:6]
exec(masks)
with open(path, encoding='utf-8', errors='replace') as f:
    text = f.read()
for line in text.splitlines():
    print(mask(mask_paths(line, home, work, root)))
PYEOF
}

# Every file, symlink and directory (with its mode) under the sandbox HOME, its TMPDIR and the dist
# root, normalized.
tree_manifest() {
  local h="$1"
  python3 - "$h" "$WORK" "$ROOT" "$INSTALL" "$MASKS_PY" <<'PYEOF'
import hashlib, os, stat, sys
home, work, root, installer, masks = sys.argv[1:6]
exec(masks)
with open(installer, 'rb') as f:
    installer_bytes = f.read()
def norm_text(b):
    return mask(mask_paths(b.decode('utf-8', 'surrogateescape'), home, work, root)).encode('utf-8', 'surrogateescape')
def norm_name(p):
    return mask(p)
rows = []
for base, label in ((home, '<HOME>'), (home + '.tmp', '<TMPDIR>'), (home + '.dist', '<DIST>')):
    if not os.path.isdir(base):
        continue
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames.sort()
        rel_dir = os.path.relpath(dirpath, base)
        # Every directory, with its mode — only EMPTY ones used to be listed, so the mode of a populated
        # directory (~/.claude/hooks, ~/.zuvo) could change unseen.
        rows.append('dir  %o %s/%s/' % (stat.S_IMODE(os.lstat(dirpath).st_mode), label, norm_name(rel_dir)))
        for name in list(dirnames):
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                rows.append('link %s/%s -> %s' % (label, norm_name(os.path.relpath(full, base)),
                                                  norm_text(os.fsencode(os.readlink(full))).decode(errors='replace')))
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = norm_name(os.path.relpath(full, base))
            if os.path.islink(full):
                rows.append('link %s/%s -> %s' % (label, rel, norm_text(os.fsencode(os.readlink(full))).decode(errors='replace')))
                continue
            st = os.lstat(full)
            if not stat.S_ISREG(st.st_mode):
                rows.append('special %s/%s' % (label, rel))
                continue
            mode = stat.S_IMODE(st.st_mode)   # exact: run_install fixes the umask
            if name == 'install.sh':
                with open(full, 'rb') as f:
                    digest = '<installer:same-as-source>' if f.read() == installer_bytes else '<installer:DIFFERS>'
            elif name.endswith('.pyc'):
                digest = '<pyc>'   # the header embeds the source mtime, which is the install time
            else:
                with open(full, 'rb') as f:
                    digest = hashlib.sha256(norm_text(f.read())).hexdigest()[:16]
            rows.append('file %o %s/%s %s' % (mode, label, rel, digest))
for row in sorted(rows):
    print(row)
PYEOF
}

# Print one scenario: exit status, normalized output, normalized tree.
emit() {
  local name="$1" h="$2" rc="$3"
  printf '=== SCENARIO %s exit=%s\n--- output\n' "$name" "$rc"
  normalize "$h" "$h.out" || bad "$name: normalizing the output failed"
  printf -- '--- tree\n'
  tree_manifest "$h" || bad "$name: walking the installed tree failed"
  if [ -f "$h/.gitconfig" ]; then
    printf -- '--- gitconfig\n'
    normalize "$h" "$h/.gitconfig"
  fi
}

count_dirs() { find "$1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }
settings_has() {  # <settings.json> <event> <script basename>
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json, sys
try:
    groups = json.load(open(sys.argv[1])).get('hooks', {}).get(sys.argv[2], [])
    sys.exit(0 if any(h.get('command', '').endswith(sys.argv[3]) for g in groups for h in g.get('hooks', [])) else 1)
except (OSError, ValueError, AttributeError):
    sys.exit(2)
PYEOF
}

printf '# install-manifest: bash %s, %s, %s\n' "$BASH_VERSION" "$(python3 --version 2>&1)" "$(uname -s)"

# --- full: a fresh `install.sh all` into a HOME where every host exists -----------------------
scenario_full() {
  local h="$WORK/full"; make_home "$h"
  local rc; rc=$(run_install "$h" all)
  emit full "$h" "$rc"
  local cache="$h/.claude/plugins/cache/zuvo-marketplace/zuvo/$VERSION"
  [ "$rc" = 0 ] && pass "full: install.sh all exits 0" || bad "full: install.sh all exited $rc"
  [ "$(count_dirs "$cache/skills")" -ge 50 ] && pass "full: claude cache v$VERSION has the skill set" \
    || bad "full: claude cache v$VERSION has $(count_dirs "$cache/skills") skill dirs"
  local d
  # Antigravity's skills live under ~/.gemini/config/skills; Cursor's are not copied at all when the
  # Claude cache exists (Cursor reads that one), so its shared includes are the witness.
  for d in .codex/skills .gemini/config/skills .kimi-code/skills; do
    [ "$(count_dirs "$h/$d")" -ge 50 ] && pass "full: $d populated" || bad "full: $d has $(count_dirs "$h/$d") dirs"
  done
  [ "$(find "$h/.cursor/shared/includes" -type f 2>/dev/null | wc -l)" -ge 50 ] \
    && grep -qE 'Duplicate skills/agents removed|Skills and agents not copied' "$h.out" \
    && [ "$(count_dirs "$h/.cursor/skills")" -eq 0 ] \
    && pass "full: cursor gets shared includes and drops duplicate skills" || bad "full: cursor install incomplete"
  for d in adversarial-review lib/model-subprocess.sh refactor-contract; do
    [ -e "$h/.zuvo/$d" ] && pass "full: ~/.zuvo/$d installed" || bad "full: ~/.zuvo/$d missing"
  done
  local ev
  for ev in "Stop zuvo-stop-retro-sweep.sh" "PostToolUse skill-usage-logger.sh" \
            "PreToolUse farm-no-local-tests.sh" "SessionStart zuvo-plugin-enable-guard.sh"; do
    # shellcheck disable=SC2086
    settings_has "$h/.claude/settings.json" $ev && pass "full: settings.json registers ${ev#* }" \
      || bad "full: settings.json does not register ${ev#* }"
  done
  [ -x "$h/.claude/hooks/pre-push" ] && pass "full: global git dispatcher installed" || bad "full: ~/.claude/hooks/pre-push missing"
  grep -q "hooksPath = $h/.claude/hooks" "$h/.gitconfig" 2>/dev/null \
    && pass "full: core.hooksPath wired to the sandbox hooks dir" || bad "full: core.hooksPath not wired"
  local kept; kept="$(cd "$h/.claude/plugins/cache/zuvo-marketplace/zuvo" && ls -d -- */ 2>/dev/null | tr -d / | sort | tr '\n' ' ')"
  [ "$kept" = "0.0.2 $VERSION " ] && pass "full: cache keeps exactly current + previous (0.0.1 pruned)" \
    || bad "full: cache dirs after install: [$kept], want [0.0.2 $VERSION ]"
}

# --- rerun: the same install a second time (idempotency paths) --------------------------------
scenario_rerun() {
  local h="$WORK/rerun"; make_home "$h"
  local rc1 rc; rc1=$(run_install "$h" all)
  [ "$rc1" = 0 ] && pass "rerun: first install.sh all exits 0" || bad "rerun: first install exited $rc1"
  rc=$(run_install "$h" all)                       # $h.out now holds the SECOND run
  emit rerun "$h" "$rc"
  [ "$rc" = 0 ] && pass "rerun: second install.sh all exits 0" || bad "rerun: second install exited $rc"
  local n; n=$(grep -c 'already registered' "$h.out")
  [ "$n" -eq 4 ] && pass "rerun: all four settings.json hooks report already registered (once each)" \
    || bad "rerun: only $n 'already registered' lines"
}

# --- nosettings: no ~/.claude/settings.json -> every registration warns, nothing created ------
scenario_nosettings() {
  local h="$WORK/nosettings"; make_home "$h"; rm -f "$h/.claude/settings.json"
  local rc; rc=$(run_install "$h" claude)
  emit nosettings "$h" "$rc"
  local n; n=$(grep -c 'settings.json not found' "$h.out")
  [ "$n" -ge 4 ] && pass "nosettings: four registrations warn settings.json not found" || bad "nosettings: $n warnings"
  [ ! -e "$h/.claude/settings.json" ] && pass "nosettings: settings.json not created" || bad "nosettings: settings.json was created"
}

# --- malformed: settings.json that is not JSON -> merges refuse, file left byte-identical -----
scenario_malformed() {
  local h="$WORK/malformed"; make_home "$h"; printf '{ not json\n' > "$h/.claude/settings.json"
  local rc; rc=$(run_install "$h" claude)
  emit malformed "$h" "$rc"
  local n; n=$(grep -c 'is malformed' "$h.out")
  [ "$n" -ge 4 ] && pass "malformed: four merges refuse a malformed settings.json" || bad "malformed: $n refusals"
  [ "$(cat "$h/.claude/settings.json")" = '{ not json' ] && pass "malformed: settings.json left untouched" \
    || bad "malformed: settings.json was modified"
}

# --- badtarget: an unknown target prints usage and exits 1 ------------------------------------
scenario_badtarget() {
  local h="$WORK/badtarget"; make_home "$h"
  local rc; rc=$(run_install "$h" nosuchhost)
  emit badtarget "$h" "$rc"
  [ "$rc" = 1 ] && grep -q '^Usage: ' "$h.out" && pass "badtarget: usage + exit 1" || bad "badtarget: exit $rc"
}

# --- nocache: `claude` with no plugin cache fails before touching anything else ---------------
scenario_nocache() {
  local h="$WORK/nocache"; make_home "$h"; rm -rf "$h/.claude/plugins/cache"
  local rc; rc=$(run_install "$h" claude)
  emit nocache "$h" "$rc"
  [ "$rc" != 0 ] && grep -q 'Plugin cache not found' "$h.out" && pass "nocache: install_claude refuses (exit $rc)" \
    || bad "nocache: exit $rc"
}

# --- sourced: what sourcing install.sh defines and sets (tests source it) ---------------------
# SOURCED_FUNCS: the functions the tests CALL after sourcing (each must be defined). The scenario also
# prints EVERY function sourcing defines, derived, so a function added or removed shows in the manifest
# without anyone remembering to list it.
SOURCED_FUNCS="ok warn fail dist_root cp_warn verify_copied install_file_atomic install_runner_lib
lib_name_collisions guard_lib_collisions _runner_lib_miss install_hook_tree install_git_dispatchers
install_pipeline_artifacts install_git_shim materialize_claude_reviewer_lanes validate_claude_reviewer_lanes
install_claude install_refactor_radar_bundle _zuvo_home_drop_stale install_zuvo_home install_claude_home
install_codex install_cursor install_antigravity install_kimi"
scenario_sourced() {
  local h="$WORK/sourced"; make_home "$h"
  mkdir -p "$h.tmp"
  ( umask 022
    env -i PATH="$PATH" HOME="$h" TMPDIR="$h.tmp" LANG=C LC_ALL=C GIT_CONFIG_GLOBAL="$h/.gitconfig" \
      GIT_CONFIG_NOSYSTEM=1 ZUVO_DIST_ROOT="$h.dist" INSTALL="$INSTALL" FUNCS="$SOURCED_FUNCS" "$BASH" -c '
    set -u
    before=" $(compgen -A function | tr "\n" " ")"
    . "$INSTALL" probe-arg; rc=$?
    echo "source rc=$rc"
    for f in $FUNCS; do declare -F "$f" >/dev/null && echo "defined $f" || echo "MISSING $f"; done
    for f in $(compgen -A function | sort); do
      case "$before" in *" $f "*) ;; *) echo "function $f" ;; esac
    done
    for v in ZUVO_DIR TARGET VERSION INSTALL_VERIFY_MISSING INSTALL_VERIFY_DETAIL INSTALL_COPY_WARNINGS \
             _zuvo_install_stamp GREEN YELLOW RED NC; do
      printf "var %s=%q\n" "$v" "${!v-<unset>}"
    done
    case $- in *e*) echo "errexit on" ;; *) echo "errexit off" ;; esac
  ' > "$h.out" 2>&1 )
  local rc=$?
  emit sourced "$h" "$rc"
  local want got; want=$(printf '%s\n' $SOURCED_FUNCS | grep -c .); got=$(grep -c '^defined ' "$h.out")
  [ "$rc" = 0 ] && [ "$got" = "$want" ] && pass "sourced: all $want functions the tests call are defined after sourcing" \
    || bad "sourced: shell exit $rc, $got of $want functions defined"
  grep -q '^source rc=0$' "$h.out" && pass "sourced: sourcing returns 0" || bad "sourced: $(grep '^source rc' "$h.out")"
}

SCENARIOS="${*:-full rerun nosettings malformed badtarget nocache sourced}"
for s in $SCENARIOS; do
  declare -F "scenario_$s" >/dev/null || { bad "unknown scenario: $s"; continue; }
  "scenario_$s"
done

printf 'RESULT: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
