#!/usr/bin/env bash
# test-run-all-wiring.sh — wiring test for tests/run-all.sh (Task 4).
#
# RED-first: authored BEFORE tests/run-all.sh existed. When the runner is
# missing, every assertion below fails loudly (that is the intended RED
# evidence); once run-all.sh is implemented, all assertions must pass.
#
# Asserts (see Task 4 spec):
#   (a) STATIC   — every path in `--list` exists on disk; list is non-empty and
#                  covers the linter, hooks, the four suite e2es, benchmark and
#                  skill suites; the runner's own wiring test is excluded.
#   (b) AGGREGATE— a fixture suite dir (pass/fail/gulp-stdin/skip) yields exit 1
#                  and a PASS=2 FAIL=1 SKIP=1 summary, proving a FAIL does not
#                  abort AND a stdin-reading child cannot eat the child list.
#   (b2) SPACED  — a suites dir with a space in its name still runs (quoting).
#   (c) SCOPES   — fast excludes tests/adversarial/run.sh; full includes it;
#                  unset scope == fast.
#   (d) BAD ENV  — ZUVO_TEST_SCOPE=bogus exits 2 with a loud stderr message.
#   (e) BATS     — bats-absent marks the bats group SKIP-with-warn in --list and
#                  a fixture-scoped run does not depend on bats.
#   (f) NO SMOKE — smoke-fleet-audit.sh / smoke-resume.sh never appear in --list.
#
# Fixture idiom (mktemp + trap) adapted from tests/hooks/test-pipeline-gate-lib.sh.
# bash 3.2-compatible (macOS default).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER="$ROOT/tests/run-all.sh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

if [ ! -f "$RUNNER" ]; then
  echo "RED: $RUNNER does not exist yet — assertions below will fail (expected in RED phase)."
fi

# ── resolved lists (unset ZUVO_TEST_SCOPE so 'default' is genuinely unset) ─────
LIST_FAST="$(ZUVO_TEST_SCOPE=fast bash "$RUNNER" --list 2>/dev/null)"
LIST_FULL="$(ZUVO_TEST_SCOPE=full bash "$RUNNER" --list 2>/dev/null)"
LIST_DEFAULT="$(env -u ZUVO_TEST_SCOPE bash "$RUNNER" --list 2>/dev/null)"

# ── (a) STATIC: list shape + on-disk existence ────────────────────────────────
[ -n "$LIST_FAST" ] && pass "(a) fast --list is non-empty" || bad "(a) fast --list is empty"

for needle in \
  "scripts/validate-skills.sh" \
  "tests/hooks/" \
  "tests/seo-suite/test-suite-e2e.sh" \
  "tests/geo-suite/test-suite-e2e.sh" \
  "tests/pentest-suite/test-suite-e2e.sh" \
  "tests/infra-suite/test-suite-e2e.sh" \
  "tests/benchmark-suite" \
  "tests/skill-suite"; do
  if printf '%s\n' "$LIST_FAST" | grep -q -- "$needle"; then
    pass "(a) --list includes $needle"
  else
    bad "(a) --list MISSING $needle"
  fi
done

if printf '%s\n' "$LIST_FAST" | grep -q 'test-run-all-wiring.sh'; then
  bad "(a) --list must NOT include its own wiring test (recursion risk)"
else
  pass "(a) --list excludes the wiring test itself"
fi

missing=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in SKIP:*) continue ;; esac
  case "$line" in /*) p="$line" ;; *) p="$ROOT/$line" ;; esac
  [ -f "$p" ] || missing="$missing $line"
done < <(printf '%s\n' "$LIST_FAST")
if [ -z "$missing" ]; then
  pass "(a) every listed path exists on disk"
else
  bad "(a) --list references nonexistent path(s):$missing"
fi

# ── (b) SYNTHETIC AGGREGATION: a FAIL child does not abort the loop ───────────
FIX="$(mktemp -d)"
SPACED_BASE="$(mktemp -d)"
trap 'rm -rf "$FIX" "$SPACED_BASE"' EXIT
printf '#!/usr/bin/env bash\nexit 0\n'                        > "$FIX/pass.sh"
printf '#!/usr/bin/env bash\necho "boom from fail"\nexit 1\n' > "$FIX/fail.sh"
printf '#!/usr/bin/env bash\necho "SKIP: because"\nexit 0\n'  > "$FIX/skip.sh"
# gulp-stdin.sh sorts alphabetically BETWEEN fail.sh and skip.sh (f < g < p/s):
# if the runner lets children inherit the driver loop's stdin, its `cat` eats
# the remaining child list and pass.sh/skip.sh silently never run.
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n'        > "$FIX/gulp-stdin.sh"
chmod +x "$FIX"/*.sh

AGG_OUT="$(ZUVO_RUNALL_SUITES_DIR="$FIX" bash "$RUNNER" 2>&1)"
AGG_CODE=$?
[ "$AGG_CODE" -eq 1 ] && pass "(b) exit 1 when a child FAILs" || bad "(b) expected exit 1, got $AGG_CODE"
if printf '%s\n' "$AGG_OUT" | grep -q 'RESULT: PASS=2 FAIL=1 SKIP=1'; then
  pass "(b) summary is PASS=2 FAIL=1 SKIP=1"
else
  bad "(b) wrong summary: [$(printf '%s\n' "$AGG_OUT" | grep -i 'RESULT:' || echo none)]"
fi
for n in pass.sh fail.sh gulp-stdin.sh skip.sh; do
  if printf '%s\n' "$AGG_OUT" | grep -q "$n"; then
    pass "(b) child $n ran (loop did not abort / stdin not eaten)"
  else
    bad "(b) child $n did NOT run"
  fi
done

# ── (b2) SPACED suites dir: quoting must survive a space in the path ──────────
mkdir "$SPACED_BASE/with space"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SPACED_BASE/with space/pass.sh"
chmod +x "$SPACED_BASE/with space/pass.sh"
SP_OUT="$(ZUVO_RUNALL_SUITES_DIR="$SPACED_BASE/with space" bash "$RUNNER" 2>&1)"
SP_CODE=$?
[ "$SP_CODE" -eq 0 ] && pass "(b2) spaced suites dir exits 0" || bad "(b2) spaced suites dir exit $SP_CODE (want 0)"
if printf '%s\n' "$SP_OUT" | grep -q 'RESULT: PASS=1 FAIL=0 SKIP=0'; then
  pass "(b2) spaced suites dir summary PASS=1 FAIL=0 SKIP=0"
else
  bad "(b2) spaced dir wrong summary: [$(printf '%s\n' "$SP_OUT" | grep -i 'RESULT:' || echo none)]"
fi

# ── (c) SCOPES ────────────────────────────────────────────────────────────────
if printf '%s\n' "$LIST_FAST" | grep -q 'tests/adversarial/run.sh'; then
  bad "(c) fast scope must NOT list tests/adversarial/run.sh"
else
  pass "(c) fast scope excludes adversarial"
fi
if printf '%s\n' "$LIST_FULL" | grep -q 'tests/adversarial/run.sh'; then
  pass "(c) full scope includes adversarial"
else
  bad "(c) full scope must list tests/adversarial/run.sh"
fi
if [ "$LIST_DEFAULT" = "$LIST_FAST" ]; then
  pass "(c) default (unset) scope == fast"
else
  bad "(c) default scope differs from fast"
fi

# ── (d) BAD ENV: bogus scope → exit 2, loud stderr ────────────────────────────
BOGUS_ERR="$(ZUVO_TEST_SCOPE=bogus bash "$RUNNER" --list 2>&1 >/dev/null)"
BOGUS_CODE=$?
[ "$BOGUS_CODE" -eq 2 ] && pass "(d) bogus scope exits 2" || bad "(d) bogus scope exit $BOGUS_CODE (want 2)"
if printf '%s\n' "$BOGUS_ERR" | grep -qi 'ZUVO_TEST_SCOPE'; then
  pass "(d) bogus scope prints loud stderr naming ZUVO_TEST_SCOPE"
else
  bad "(d) bogus scope stderr not loud: [$BOGUS_ERR]"
fi

# ── (e) BATS presence/absence ─────────────────────────────────────────────────
if command -v bats >/dev/null 2>&1; then
  if printf '%s\n' "$LIST_FAST" | grep -q '\.bats'; then
    pass "(e) bats present → .bats paths listed"
  else
    bad "(e) bats present but no .bats path in --list"
  fi
else
  bats_line="$(printf '%s\n' "$LIST_FAST" | grep -i 'bats' || true)"
  if [ -n "$bats_line" ] && printf '%s\n' "$bats_line" | grep -qi 'SKIP'; then
    pass "(e) bats absent → bats group marked SKIP-warn in --list"
  else
    bad "(e) bats absent but --list has no SKIP-warn bats line: [$bats_line]"
  fi
fi
if printf '%s\n' "$AGG_OUT" | grep -qi 'bats'; then
  bad "(e) fixture-scoped run must not depend on / mention bats"
else
  pass "(e) fixture-scoped run is independent of bats"
fi

# ── (f) smoke harnesses never listed, for any scope ───────────────────────────
for scope in fast full; do
  L="$(ZUVO_TEST_SCOPE="$scope" bash "$RUNNER" --list 2>/dev/null)"
  for smoke in smoke-fleet-audit.sh smoke-resume.sh; do
    if printf '%s\n' "$L" | grep -q "$smoke"; then
      bad "(f) $smoke leaked into $scope --list"
    else
      pass "(f) $smoke absent from $scope --list"
    fi
  done
  if printf '%s\n' "$L" | grep -q 'security-corpus'; then
    bad "(f) security-corpus leaked into $scope --list"
  else
    pass "(f) security-corpus absent from $scope --list"
  fi
done

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "ALL PASSED"
  exit 0
else
  echo "SOME FAILED"
  exit 1
fi
