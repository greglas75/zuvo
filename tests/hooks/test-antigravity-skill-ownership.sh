#!/usr/bin/env bash
# `~/.gemini/config/skills` is Antigravity's SHARED customization root — the user's own
# skills and other tools' skills live there too. install_antigravity() used to `rm -rf`
# every directory whose name matched one of zuvo's 57 skills, and a dozen of those names
# are generic English words (review, docs, debug, design, backlog). A user's own `debug`
# skill was therefore deleted on every install, silently, while install reported success.
#
# The mirror defect: a name-keyed delete can never prune a skill zuvo RENAMED. The old
# name is absent from $DIST, so nothing ever targeted it and Antigravity kept loading a
# stale copy forever (this repo does rename skills — content-optimize -> content-expand).
#
# Both are fixed by keying on PROVENANCE (a `.zuvo-owned` marker written at install time),
# the same pattern install_codex() already uses for its TOMLs. These cases pin it.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

[ -f "$ROOT/scripts/install.sh" ] || { bad "install.sh missing"; echo "SOME FAILED"; exit 1; }

if [ ! -d "$ROOT/dist/antigravity/skills" ]; then
  pass "dist/antigravity not built — behavioural cases unobservable (skipped); source guards still run"
  SKIP_BEHAVIOUR=1
else
  SKIP_BEHAVIOUR=0
fi

if [ "$SKIP_BEHAVIOUR" -eq 0 ]; then
  H="$(mktemp -d)"
  trap 'rm -rf "$H"' EXIT
  AGS="$H/.gemini/config/skills"
  mkdir -p "$H/.gemini/antigravity" "$AGS"

  run_install() {
    ( cd "$ROOT" && HOME="$H" bash -c 'source scripts/install.sh >/dev/null 2>&1 || true; install_antigravity' 2>&1 )
  }

  # --- Run 1: no markers anywhere yet. Adopt by name ONCE (the previous behaviour, no
  #     worse), and stamp markers so every later run is provenance-checked.
  mkdir -p "$AGS/mine-only"; echo "MINE" > "$AGS/mine-only/SKILL.md"
  out1="$(run_install)"
  [ -d "$AGS/mine-only" ] \
    && pass "run 1: a non-colliding third-party skill is untouched" \
    || bad  "run 1: deleted a third-party skill it never installed (mine-only)"
  [ -f "$AGS/review/.zuvo-owned" ] \
    && pass "run 1: installed skills are stamped with an ownership marker" \
    || bad  "run 1: no .zuvo-owned marker written — later runs cannot tell ours from theirs"

  # --- Run 2: markers exist, so name is no longer evidence of ownership.
  #     (a) a NEW third-party dir whose name collides with a zuvo skill must survive;
  #     (b) a marked dir this release no longer ships must be pruned.
  rm -rf "$AGS/debug"; mkdir -p "$AGS/debug"; echo "MY OWN DEBUG" > "$AGS/debug/SKILL.md"
  mkdir -p "$AGS/content-optimize"; printf 'zuvo-owned\n' > "$AGS/content-optimize/.zuvo-owned"
  out2="$(run_install)"

  if [ -f "$AGS/debug/SKILL.md" ] && grep -q "MY OWN DEBUG" "$AGS/debug/SKILL.md" 2>/dev/null; then
    pass "run 2: a same-named directory without our marker is left to its owner"
  else
    bad "run 2: overwrote a third-party 'debug' skill — provenance check not applied"
  fi
  printf '%s\n' "$out2" | grep -qi "skipped 'debug'" \
    && pass "run 2: the skip is reported, not silent" \
    || bad  "run 2: skipped a skill without saying so — a silent no-op reads as success"
  [ -d "$AGS/content-optimize" ] \
    && bad  "run 2: an orphaned zuvo skill (renamed away) was not pruned — stays loaded forever" \
    || pass "run 2: a marked skill absent from this release is pruned"
  [ -d "$AGS/mine-only" ] \
    && pass "run 2: unrelated third-party skills still untouched" \
    || bad  "run 2: deleted an unrelated third-party skill"
fi

# --- Source guards: these survive on a machine where the behavioural half is skipped.
if grep -qE 'rm -rf "\$AG_SKILLS/\$\(basename' "$ROOT/scripts/install.sh"; then
  bad "install.sh deletes by basename again — the name-keyed wipe is back"
else
  pass "install.sh no longer deletes Antigravity skills by basename"
fi
if grep -q 'AG_MARKER=".zuvo-owned"' "$ROOT/scripts/install.sh"; then
  pass "ownership marker is still the key for deletion"
else
  bad "the .zuvo-owned marker is gone — deletion has no provenance check"
fi

echo "=== RESULT ==="
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
