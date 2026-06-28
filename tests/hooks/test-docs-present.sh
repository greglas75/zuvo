#!/usr/bin/env bash
# Task 13 — assert the docs cover the pipeline-entry enforcement: layer table
# (CI=guarantee, pre-push=primary local, commit/Stop=nudges), how to enable CI,
# the escapes, the thresholds + env overrides, and an explicit honest-limits para.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIPE="$ROOT/docs/pipeline.md"
CLAUDE="$ROOT/CLAUDE.md"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

for f in "$PIPE" "$CLAUDE"; do [ -f "$f" ] || { bad "missing: ${f##*/}"; }; done

# escapes documented in BOTH
grep -qiE 'ZUVO_ALLOW_ADHOC|adhoc-approved' "$CLAUDE" && pass "CLAUDE.md documents an escape valve" || bad "CLAUDE.md missing escape"
grep -qiE 'ZUVO_ALLOW_ADHOC' "$PIPE" && grep -qiE 'adhoc-approved' "$PIPE" \
  && pass "pipeline.md documents both escapes (local + CI label)" || bad "pipeline.md missing an escape"

# layer roles
grep -qiE 'guarantee' "$PIPE" && grep -qiE 'pre-push' "$PIPE" && grep -qiE 'nudge' "$PIPE" \
  && pass "pipeline.md describes CI=guarantee / pre-push / nudges" || bad "pipeline.md missing layer roles"
grep -qiE 'CI gate' "$PIPE" && pass "pipeline.md names the CI gate" || bad "pipeline.md missing CI gate"

# how to enable CI
grep -qiE 'github/workflows|cp ci/zuvo-pipeline-entry\.yml|Enabling the CI gate' "$PIPE" \
  && pass "pipeline.md has the enable-CI how-to" || bad "pipeline.md missing enable-CI how-to"

# thresholds + env overrides
grep -qE 'ZUVO_GATE_MIN_FILES' "$PIPE" && grep -qE 'ZUVO_GATE_MIN_LINES' "$PIPE" \
  && pass "pipeline.md documents thresholds + env overrides" || bad "pipeline.md missing thresholds"
grep -qE '3 production files|≥3 production|>=3 production' "$PIPE" && grep -qE '150' "$PIPE" \
  && pass "pipeline.md states the 3-files/150-lines threshold" || bad "pipeline.md missing exact threshold"

# explicit honest-limits paragraph
grep -qiE 'Honest limits|honest about' "$PIPE" && pass "pipeline.md has an honest-limits section" || bad "pipeline.md missing honest-limits"
grep -qiE 'fail.open' "$PIPE" && pass "pipeline.md states fail-open philosophy" || bad "pipeline.md missing fail-open"
grep -qiE 'unbypassable|only unbypassable' "$PIPE" && pass "pipeline.md states CI is the only unbypassable layer" || bad "pipeline.md missing unbypassable note"
grep -qiE 'bypassable by design|best-effort' "$PIPE" && pass "pipeline.md states nudges bypassable by design" || bad "pipeline.md missing nudge-bypassable note"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
