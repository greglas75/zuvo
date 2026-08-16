#!/usr/bin/env bash
# tests/lib/dist-build.sh memoizes the four platform builds once per suite run. That
# is a speedup (six 18-31s builds became four) but it is also a NEW WAY FOR A TEST TO
# GO VACUOUS: test-kimi-build.sh's first assertion is "the kimi build exits 0", and if
# a replay ever returned 0 unconditionally, that assertion would pass on a build that
# never ran and never could. The cases below pin the properties that keep the callers
# honest — the replayed exit code and log are the BUILD's, not the cache's.
#
# These are deliberately synthetic: they write cache entries by hand rather than
# running a real 57-skill build, so the file stays in the sub-second tier where it can
# run on every change.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/tests/lib/dist-build.sh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

[ -f "$HELPER" ] || { bad "tests/lib/dist-build.sh missing"; echo "SOME FAILED"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── (1) a cached FAILURE replays as a failure ────────────────────────────────
# The property that keeps "(1) build-kimi-skills.sh exits 0" a real assertion.
C1="$TMP/c1"; mkdir -p "$C1"
printf 'boom: validation failed\n' > "$C1/kimi.log"
printf '1' > "$C1/kimi.rc"
out="$(ZUVO_DIST_CACHE="$C1" bash "$HELPER" kimi 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [ "$out" = "boom: validation failed" ]; then
  pass "(1) a cached non-zero build replays its exit code and log verbatim"
else
  bad "(1) cached failure did not replay (rc=$rc, out=[$out]) — callers asserting 'build exits 0' would pass vacuously"
fi

# ── (2) a cached SUCCESS replays 0 plus the exact log bytes ──────────────────
C2="$TMP/c2"; mkdir -p "$C2"
printf 'line one\nline two\n' > "$C2/kimi.log"
printf '0' > "$C2/kimi.rc"
out="$(ZUVO_DIST_CACHE="$C2" bash "$HELPER" kimi 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "line one
line two" ]; then
  pass "(2) a cached success replays exit 0 and the full log"
else
  bad "(2) cached success replayed wrong (rc=$rc)"
fi

# ── (3) the replay MATERIALIZES dist/<platform> ──────────────────────────────
# reviewer-model-builds.bats wipes dist/{codex,cursor,antigravity} in its per-test
# setup() and then asserts on files inside them. A replay that restored only the log
# would leave every one of those `[ -f ... ]` checks failing, so the tree copy is not
# an optimization detail — it is what makes the cache substitutable for a build.
C3="$TMP/c3"; mkdir -p "$C3/kimi.tree/skills/demo"
printf 'hello\n' > "$C3/kimi.tree/skills/demo/SKILL.md"
printf '0' > "$C3/kimi.rc"
: > "$C3/kimi.log"
DEST="$ROOT/dist/kimi"
SAVED=""
if [ -d "$DEST" ]; then SAVED="$TMP/saved-kimi"; mv "$DEST" "$SAVED"; fi
ZUVO_DIST_CACHE="$C3" bash "$HELPER" kimi >/dev/null 2>&1
if [ -f "$DEST/skills/demo/SKILL.md" ] && grep -q hello "$DEST/skills/demo/SKILL.md" 2>/dev/null; then
  pass "(3) replay materializes dist/<platform> on disk, not just the log"
else
  bad "(3) replay left no dist tree — tests asserting on built files would all fail"
fi
rm -rf "$DEST"
[ -n "$SAVED" ] && mv "$SAVED" "$DEST"

# ── (4) a half-written entry (log, no .rc sentinel) is NOT trusted ───────────
# The .rc file is written last precisely so an interrupted or killed build cannot be
# replayed as if it had completed. Asserted on the SOURCE: exercising it for real
# would mean running a full build, which is the cost this whole helper exists to avoid.
rc_line="$(grep -n 'printf .%s. "\$rc" > "\$RC"' "$HELPER" | head -1 | cut -d: -f1)"
tree_line="$(grep -n 'mv "\$TREE.tmp' "$HELPER" | head -1 | cut -d: -f1)"
if [ -n "$rc_line" ] && [ -n "$tree_line" ] && [ "$rc_line" -gt "$tree_line" ]; then
  pass "(4) the .rc sentinel is written after the tree snapshot (a killed build cannot replay as complete)"
else
  bad "(4) .rc is no longer written last (rc@${rc_line:-?}, tree@${tree_line:-?}) — a partial cache entry can be replayed as a finished build"
fi

# ── (5) an unknown platform is a loud usage error, never a silent success ────
out="$(ZUVO_DIST_CACHE="$C2" bash "$HELPER" not-a-platform 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
  pass "(5) an unknown platform exits 2 (usage), not 0"
else
  bad "(5) unknown platform returned $rc — a typo'd platform name would read as a passing build"
fi

# ── (6) no test may call a builder directly any more ─────────────────────────
# The dedup only holds while every caller goes through the helper. One reintroduced
# direct `bash scripts/build-<p>-skills.sh` puts a redundant full build back into the
# suite, and — worse — a builder writing dist/ mid-run can truncate the tree another
# child is asserting against (B-DIST-BUILD-RACE). Grep, so the guard cannot rot.
#
# test-antigravity-skill-ownership.sh is the one legitimate exception: it runs the real
# install_antigravity against an ISOLATED repo copy of four skills, so it never touches
# $ROOT/dist and its build is already small.
offenders=""
for f in "$ROOT"/tests/hooks/test-*.sh "$ROOT"/tests/skill-suite/test-*.sh "$ROOT"/scripts/tests/*.bats; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in
    test-antigravity-skill-ownership.sh|test-dist-build-cache.sh) continue ;;
  esac
  if grep -qE '(bash|run bash)[^|;]*scripts/build-[a-z]+-skills\.sh' "$f"; then
    offenders="$offenders $(basename "$f")"
  fi
done
if [ -z "$offenders" ]; then
  pass "(6) no test invokes a platform builder directly — all go through the cache helper"
else
  bad "(6) direct builder invocation is back in:$offenders (use tests/lib/dist-build.sh <platform>)"
fi

echo "=== RESULT ==="
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
