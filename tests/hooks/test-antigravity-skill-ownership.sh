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

# Gate on what the test actually NEEDS — the builder — not on `$ROOT/dist/`. The behavioural
# half runs install.sh from an isolated repo copy that builds its own dist (see below), so a
# missing or stale `$ROOT/dist/` says nothing about whether these cases can run. Gating on it
# was left over from the pre-isolation version and silently skipped the behavioural half in a
# checkout that had never built — including this test's own positive control, which then
# "passed" the interesting cases by never running them.
if [ ! -f "$ROOT/scripts/build-antigravity-skills.sh" ]; then
  pass "build-antigravity-skills.sh absent — behavioural cases unobservable (skipped); source guards still run"
  SKIP_BEHAVIOUR=1
else
  SKIP_BEHAVIOUR=0
fi

if [ "$SKIP_BEHAVIOUR" -eq 0 ]; then
  H="$(mktemp -d)"
  trap 'rm -rf "$H"' EXIT
  AGS="$H/.gemini/config/skills"
  mkdir -p "$H/.gemini/antigravity" "$AGS"

  # ISOLATED REPO COPY — not a nicety, the fix for a real flake.
  #
  # `install_antigravity` rebuilds `$ZUVO_DIR/dist/antigravity` on every call, and ZUVO_DIR is
  # derived from install.sh's own location (scripts/install.sh:19), so it cannot be redirected
  # with an env var. Meanwhile other children of run-all.sh build into — and `rm -rf` — that same
  # `dist/` tree. This test therefore asserted on a directory a sibling test could truncate
  # underneath it: green standalone, red roughly 2 runs in 10, and red inside the suite. That is
  # B-DIST-BUILD-RACE in a new place.
  #
  # A completeness guard was the first thing I tried and it was the wrong shape: tolerating the
  # race rather than removing it, and it quietly turned the whole test into a no-op. Copying the
  # repo gives the test its OWN dist/, so no sibling can reach it and every run is deterministic.
  # Copy only the skills the assertions NAME. install_antigravity rebuilds the whole
  # distribution on every call and this test calls it twice, so the copy size is the runtime:
  # all 57 skills cost 259s (measured 2026-08-13) — for a test whose entire subject is two
  # directory names. `review` must exist so run 1 has something to stamp; `debug` must exist so
  # run 2 has a name that COLLIDES with the third-party dir it must refuse to overwrite. The
  # rest contribute nothing but build time. A fourth is copied so the build is not a degenerate
  # one-skill case.
  REPO="$(mktemp -d)"
  trap 'rm -rf "$H" "$REPO"' EXIT
  for d in scripts shared rules; do
    [ -d "$ROOT/$d" ] && cp -R "$ROOT/$d" "$REPO/$d"
  done
  # `write-tests` is not optional here even though no assertion mentions it: the Antigravity
  # build VALIDATES its output and fails with "Missing Antigravity blind audit reviewer agents"
  # unless skills/write-tests/agents/blind-coverage-auditor{,-alt}.md are present
  # (scripts/build-antigravity-skills.sh:588-592). Dropping it made the build fail, install copy
  # nothing, and three assertions go red for a reason that had nothing to do with ownership.
  mkdir -p "$REPO/skills"
  for s in review debug docs write-tests; do
    [ -d "$ROOT/skills/$s" ] && cp -R "$ROOT/skills/$s" "$REPO/skills/$s"
  done
  mkdir -p "$REPO/.claude-plugin"
  [ -f "$ROOT/.claude-plugin/plugin.json" ] && cp "$ROOT/.claude-plugin/plugin.json" "$REPO/.claude-plugin/"

  run_install() {
    ( cd "$REPO" && HOME="$H" bash -c 'source scripts/install.sh >/dev/null 2>&1 || true; install_antigravity' 2>&1 )
  }

  # --- Run 1: no markers anywhere yet. Adopt by name ONCE (the previous behaviour, no
  #     worse), and stamp markers so every later run is provenance-checked.
  mkdir -p "$AGS/mine-only"; echo "MINE" > "$AGS/mine-only/SKILL.md"
  run_install >/dev/null 2>&1
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
