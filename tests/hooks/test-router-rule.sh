#!/usr/bin/env bash
# Task 12 — assert the using-zuvo router routes production-code changes through
# the pipeline at the SAME threshold the lib enforces, forbids ad-hoc multi-file
# implementation, and names the push/CI gates as the enforcement.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
F="$ROOT/skills/using-zuvo/SKILL.md"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

[ -f "$F" ] || { echo "FAIL: using-zuvo/SKILL.md missing"; exit 1; }

grep -qiE 'route[s]? .*through the pipeline|production-code work routes' "$F" \
  && pass "routes production-code work through the pipeline" || bad "missing 'route through pipeline' rule"

grep -qE 'zuvo:build' "$F" && grep -qE 'zuvo:execute' "$F" \
  && pass "names zuvo:build + zuvo:execute as the pipeline entry" || bad "missing zuvo:build/zuvo:execute"

# threshold matches the lib contract: 3 files / 150 lines + the env knobs
grep -qE 'ZUVO_GATE_MIN_FILES' "$F" && grep -qE 'ZUVO_GATE_MIN_LINES' "$F" \
  && pass "cites env-override knobs (ZUVO_GATE_MIN_FILES/LINES)" || bad "missing threshold env knobs"
grep -qE '3 production files|≥3 production|>=3 production' "$F" && grep -qE '150' "$F" \
  && pass "cites the exact threshold (3 files OR 150 lines)" || bad "missing 3-files/150-lines threshold"

# forbids ad-hoc + names the enforcement layers
grep -qiE 'do NOT implement a substantial production-code change ad-hoc|freelance' "$F" \
  && pass "forbids ad-hoc/freelance production-code change" || bad "missing ad-hoc prohibition"
grep -qiE 'pre-push gate' "$F" && grep -qiE 'CI gate' "$F" \
  && pass "names pre-push + CI as the enforcement" || bad "missing pre-push/CI enforcement mention"
grep -qiE 'ZUVO_ALLOW_ADHOC|adhoc-approved' "$F" \
  && pass "documents the escape valve" || bad "missing escape valve"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
