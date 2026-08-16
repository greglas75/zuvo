#!/usr/bin/env bash
#
# run-all.sh — aggregate test runner for the zuvo-plugin repo.
#
# Runs the repo's shell + bats test suites in one pass, counting PASS / SKIP /
# FAIL independently. A FAIL in one child NEVER aborts the run (the whole suite
# always completes) — SKIP is a first-class outcome, not a failure.
#
# Usage:
#   tests/run-all.sh            # run every child in the active scope
#   tests/run-all.sh --list     # print the resolved child paths (one per line)
#
# Env vars:
#   ZUVO_TEST_SCOPE=fast|full   scope selector (default: fast). Empty == fast.
#                               'full' additionally runs tests/adversarial/run.sh.
#   ZUVO_RUNALL_SUITES_DIR=DIR  test-injection override: when set, the child list
#                               is exactly DIR/*.sh (scope + built-in list ignored).
#
# Exit codes:
#   0  every child passed (SKIPs allowed)
#   1  at least one child FAILed
#   2  usage error (unknown arg) or bad env (ZUVO_TEST_SCOPE not fast|full)
#
# bash 3.2-compatible (macOS default): no mapfile, no associative arrays.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Sentinel emitted (instead of a path) when the bats corpus must be run but no
# `bats` runner is installed — rendered as a single SKIP-with-warn line.
BATS_SKIP_SENTINEL="@@BATS_GROUP_SKIP@@"
BATS_SKIP_MSG="SKIP: scripts/tests/*.bats (bats not installed — group skipped)"

# ── recursion guard (exit 3) ─────────────────────────────────────────────────
# Two children of this runner invoke this runner: smoke-skill-testing.sh (fast
# scope) and smoke-write-e2e-v2.sh (FULL scope, from inside a fast run). Their
# intent is legitimate — they exist to verify the runner works — but the effect
# was that every "one" suite run executed the whole suite two or three times,
# nested. Nobody saw it because this script reports PASS/FAIL counts and not a
# single timing, so the amplification only ever surfaced as "the suite is slow"
# (10-15 min locally) and as the runbook's §5 row about smoke-skill-testing
# racing concurrent commits — a symptom written down without its cause.
#
# The guard lives HERE rather than in the two callers so a third caller cannot
# reintroduce it. Exit code 3 is deliberate and distinct: exiting 0 would hand
# the caller a green "the suite passed" it never ran, and exiting 1 would report
# a failure that did not happen. A caller that does not know code 3 gets a loud
# non-zero, which is the safe default.
if [ -n "${ZUVO_RUNALL_DEPTH:-}" ]; then
  echo "SKIP: nested tests/run-all.sh invocation (depth=${ZUVO_RUNALL_DEPTH}) — refusing to re-run the whole suite inside itself." >&2
  echo "      The outer run already covers these children. Callers that legitimately verify the runner should treat exit 3 as 'skipped: nested'." >&2
  exit 3
fi
export ZUVO_RUNALL_DEPTH=1

# ── arg parsing (loud exit 2 on anything unexpected; cf. validate-skills.sh) ──
MODE="run"
if [ "$#" -gt 0 ]; then
  case "$1" in
    --list) MODE="list" ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      echo "Usage: [ZUVO_TEST_SCOPE=fast|full] $0 [--list]" >&2
      exit 2 ;;
  esac
  if [ "$#" -gt 1 ]; then
    echo "ERROR: unexpected extra arguments: ${*:2}" >&2
    echo "Usage: [ZUVO_TEST_SCOPE=fast|full] $0 [--list]" >&2
    exit 2
  fi
fi

# ── scope validation (empty/unset → fast; anything else → loud exit 2) ────────
SCOPE="${ZUVO_TEST_SCOPE:-fast}"
[ -n "$SCOPE" ] || SCOPE="fast"
case "$SCOPE" in
  fast|full) ;;
  *)
    echo "ERROR: ZUVO_TEST_SCOPE must be 'fast' or 'full' (got: '$SCOPE')" >&2
    echo "Usage: [ZUVO_TEST_SCOPE=fast|full] $0 [--list]" >&2
    exit 2 ;;
esac

# ── per-run distribution cache ────────────────────────────────────────────────
# Six of this suite's children each ran a full `build-<platform>-skills.sh` over all
# 57 skills (18-31s apiece) even though only four distinct platforms exist, so two of
# those builds recomputed, byte for byte, what a sibling had already produced from the
# identical tree. tests/lib/dist-build.sh memoizes per platform against this directory;
# see that file for the contract and for the dist/ race this also removes.
#
# The directory is created and destroyed per run, so the cache cannot outlive one
# invocation and cannot be stale with respect to the working tree. A pre-set
# ZUVO_DIST_CACHE is honoured and NOT deleted (harness-supplied cache, caller's to
# manage); an unwritable mktemp is not fatal — children fall back to real builds.
if [ -z "${ZUVO_DIST_CACHE:-}" ]; then
  if ZUVO_DIST_CACHE="$(mktemp -d 2>/dev/null)"; then
    export ZUVO_DIST_CACHE
    trap 'rm -rf "$ZUVO_DIST_CACHE"' EXIT INT TERM
  else
    unset ZUVO_DIST_CACHE
    echo "WARN: could not create a dist cache dir — every child will rebuild from scratch." >&2
  fi
else
  export ZUVO_DIST_CACHE
fi

# Hermetic gate-test env: strip ambient escape-hatch / agent markers so the gate suites'
# "should block" assertions are not spuriously bypassed by a caller's environment. Each
# suite still sets these per-assertion (local prefix) where it means to. Without this, a
# release run invoked as `ZUVO_ALLOW_ADHOC=1 ./scripts/release.sh` leaks the escape into
# every gate suite and fails all block assertions (observed 2026-07-03).
unset ZUVO_ALLOW_ADHOC ZUVO_AGENT ZUVO_AI_RUN 2>/dev/null || true

# ── child-list assembly ───────────────────────────────────────────────────────

# emit_glob GLOB [EXCLUDE_BASENAME]
# Print repo-relative paths for existing files matching GLOB (relative to ROOT),
# one per line, skipping EXCLUDE_BASENAME if given. bash-3.2 safe: a glob with no
# match yields the literal pattern, which the `-f` guard drops.
emit_glob() {
  local pat="$1" excl="${2:-}" f base
  # "$ROOT" quoted (a spaced checkout path must not word-split); $pat left
  # unquoted on purpose so it still globs.
  for f in "$ROOT"/$pat; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    if [ -n "$excl" ] && [ "$base" = "$excl" ]; then
      continue
    fi
    printf '%s\n' "${f#"$ROOT"/}"
  done
}

# build_child_list — emit one spec per line: either a repo-relative child path,
# an absolute fixture path, or BATS_SKIP_SENTINEL.
build_child_list() {
  # Test-injection: ZUVO_RUNALL_SUITES_DIR replaces the entire built-in list.
  if [ -n "${ZUVO_RUNALL_SUITES_DIR:-}" ]; then
    local f
    for f in "$ZUVO_RUNALL_SUITES_DIR"/*.sh; do
      if [ -f "$f" ]; then printf '%s\n' "$f"; fi
    done
    return 0
  fi

  # 1. skill structure linter
  emit_glob "scripts/validate-skills.sh"
  # 2. hook unit tests. The `test-*.sh` glob never matches `smoke-*.sh`, so the
  #    smoke-pipeline-entry.sh / smoke-global-dispatch.sh harnesses are already
  #    excluded (they require a live/slow context and are not unit tests).
  emit_glob "tests/hooks/test-*.sh"
  # 3. per-domain suite e2e drivers
  emit_glob "tests/seo-suite/test-suite-e2e.sh"
  emit_glob "tests/geo-suite/test-suite-e2e.sh"
  emit_glob "tests/pentest-suite/test-suite-e2e.sh"
  # infra-suite is FULL-SCOPE ONLY. It starts three Docker containers
  # (sshd-misconfigured, sshd-hardened, socks-proxy) and drives real SSH through them —
  # an infrastructure integration test, not a unit test. Measured 2026-08-13: it alone
  # runs 400s+ of a 792s (13.2 min) fast run, i.e. over HALF the default suite, while its
  # siblings in that group cost 0-2s each. That cost was invisible because this runner
  # prints PASS/FAIL counts and no timings, so "the suite is slow" never had a suspect.
  # It also cannot pass without a working Docker daemon, so on any machine or CI lane
  # without one it turns the default run red for a reason unrelated to the code.
  # Run it with ZUVO_TEST_SCOPE=full, or directly.
  if [ "$SCOPE" = "full" ]; then
    emit_glob "tests/infra-suite/test-suite-e2e.sh"
  fi
  # 3b. gate/registry invariant tests. These were NOT in the child list until
  #     2026-08-01 — test-gate-consistency.sh existed for weeks and only ran when
  #     somebody remembered the runbook, which is exactly how a guard rots.
  emit_glob "tests/gates/test-*.sh"
  # 4. benchmark suite
  emit_glob "tests/benchmark-suite/test-*.sh"
  # 5. skill suite — EXCLUDE this runner's own wiring test: it invokes run-all.sh,
  #    so including it here would make run-all.sh recurse into itself.
  emit_glob "tests/skill-suite/test-*.sh" "test-run-all-wiring.sh"
  # 6. bats corpus — only when a `bats` runner exists; otherwise one SKIP-warn
  #    line stands in for the whole group (never a hard failure).
  if command -v bats >/dev/null 2>&1; then
    emit_glob "scripts/tests/*.bats"
  else
    printf '%s\n' "$BATS_SKIP_SENTINEL"
  fi
  # 7. full scope adds the adversarial suite driver (heavier; opt-in).
  if [ "$SCOPE" = "full" ]; then
    emit_glob "tests/adversarial/run.sh"
  fi
  # NOTE: tests/infra-suite/smoke-*.sh, tests/security-corpus/* are deliberately
  # never enumerated here (Phase-Final / corpus harnesses, run manually).
  return 0
}

# ── --list mode ───────────────────────────────────────────────────────────────
if [ "$MODE" = "list" ]; then
  while IFS= read -r spec; do
    if [ "$spec" = "$BATS_SKIP_SENTINEL" ]; then
      echo "$BATS_SKIP_MSG"
    else
      printf '%s\n' "$spec"
    fi
  done < <(build_child_list)
  exit 0
fi

# ── run mode ──────────────────────────────────────────────────────────────────
TOTAL_PASS=0
TOTAL_SKIP=0
TOTAL_FAIL=0
FAILED_NAMES=""   # newline-separated (child paths may contain spaces)

# Per-child wall-clock, as "<seconds><TAB><name>" lines. This runner reported PASS/FAIL
# counts and not one timing for its whole life, so "the suite is slow" was a complaint
# that could never name a suspect: a single Docker-driven child burning over half the
# run sat in the default scope unnoticed, and so did six redundant distribution builds.
# Both were found by hand-timing files one at a time. Recording it here means the next
# regression announces itself in the summary instead of waiting for someone to suspect it.
TIMINGS=""
RUN_START="$(date +%s)"

# run_one SPEC — run a single child, classify PASS/SKIP/FAIL, update counters.
#
# Aggregation idiom adapted from tests/infra-suite/test-suite-e2e.sh run_test()
# (CQ14): `set +e` around the capture so a non-zero child never aborts the
# driver; classify by exit code plus a first-non-empty-line "^SKIP:" sniff.
run_one() {
  local spec="$1" path name output exit_code first_line t0 t1 elapsed
  case "$spec" in
    /*) path="$spec" ;;
    *)  path="$ROOT/$spec" ;;
  esac
  name="${spec#"$ROOT"/}"

  echo "--- Running: $name ---"
  if [ ! -f "$path" ]; then
    echo "FAIL: $name (file not found)"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    FAILED_NAMES="${FAILED_NAMES}${name}
"
    return
  fi

  # </dev/null: children run inside the while-read loop over the child list —
  # without the redirect, a child that reads stdin would consume the remaining
  # list and silently skip every subsequent child.
  t0="$(date +%s)"
  set +e
  case "$path" in
    *.bats) output="$(bats "$path" </dev/null 2>&1)" ;;
    *)      output="$(bash "$path" </dev/null 2>&1)" ;;
  esac
  exit_code=$?
  set -e
  t1="$(date +%s)"
  elapsed=$((t1 - t0))
  TIMINGS="${TIMINGS}${elapsed}	${name}
"

  echo "$output"

  if [ "$exit_code" -eq 0 ]; then
    first_line="$(echo "$output" | grep -m1 . || true)"
    if echo "$first_line" | grep -q '^SKIP:'; then
      echo "SKIP: $name (${elapsed}s)"
      TOTAL_SKIP=$((TOTAL_SKIP + 1))
    else
      echo "PASS: $name (${elapsed}s)"
      TOTAL_PASS=$((TOTAL_PASS + 1))
    fi
  else
    # Format is load-bearing and must stay byte-identical: smoke-skill-testing.sh:73
    # extracts failed FILES with `sed -n 's/^FAIL: \(.*\) (exit [0-9][0-9]*).*$/\1/p'`,
    # which needs the `)` immediately after the digits. Appending the elapsed time here
    # (`(exit 1, 5s)`) makes that sed match nothing, so the smoke stops recognising its
    # own KNOWN-BASELINE row and reports FATAL instead. The duration for a failed child
    # is still recorded — it appears in the slowest-children table below.
    echo "FAIL: $name (exit $exit_code)"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    FAILED_NAMES="${FAILED_NAMES}${name}
"
  fi
  echo ""
}

while IFS= read -r spec; do
  [ -n "$spec" ] || continue
  if [ "$spec" = "$BATS_SKIP_SENTINEL" ]; then
    echo "--- Running: scripts/tests/*.bats ---"
    echo "$BATS_SKIP_MSG"
    echo ""
    TOTAL_SKIP=$((TOTAL_SKIP + 1))
    continue
  fi
  run_one "$spec"
done < <(build_child_list)

# ── summary ───────────────────────────────────────────────────────────────────
RUN_ELAPSED=$(( $(date +%s) - RUN_START ))

echo "=== slowest children (wall clock) ==="
printf '%s' "$TIMINGS" | sort -rn | head -10 | while IFS='	' read -r secs n; do
  [ -n "${n:-}" ] || continue
  printf '  %5ss  %s\n' "$secs" "$n"
done
echo "  total: ${RUN_ELAPSED}s"
echo ""

echo "=== zuvo test run (scope: $SCOPE) ==="
echo "RESULT: PASS=$TOTAL_PASS FAIL=$TOTAL_FAIL SKIP=$TOTAL_SKIP"
if [ "$TOTAL_FAIL" -gt 0 ]; then
  echo "FAILED children:"
  printf '%s' "$FAILED_NAMES" | while IFS= read -r n; do
    echo "  - $n"
  done
  exit 1
fi
echo "ALL PASSED (SKIPs do not count as failures)"
exit 0
