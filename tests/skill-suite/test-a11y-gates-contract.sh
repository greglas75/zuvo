#!/usr/bin/env bash
# test-a11y-gates-contract.sh — a11y-audit's critical gates (A2, A4) are decided by evidence, not by a score,
# and a gate static analysis cannot decide is CANNOT DETERMINE, which audit-postamble.md §1 row 3 turns into
# INCOMPLETE. Catches: a gate that PASSes (or fails on a made-up threshold) from grep alone.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/skills/a11y-audit/SKILL.md"
npass=0; nfail=0
has() { if grep -Fq -- "$2" "$SKILL"; then echo "  PASS $1"; npass=$((npass + 1)); else echo "  FAIL $1 — missing: $2"; nfail=$((nfail + 1)); fi; }
lacks() { if grep -Fq -- "$2" "$SKILL"; then echo "  FAIL $1 — still present: $2"; nfail=$((nfail + 1)); else echo "  PASS $1"; npass=$((npass + 1)); fi; }

has   "gates decided by evidence"        'Critical gates are decided by evidence, never by a score threshold.'
lacks "no A2 score threshold"            'A2 (Keyboard Navigation) < 6/12'
lacks "no A4 score threshold"            'A4 (Color & Contrast) < 5/10'
has   "PASS needs live evidence"         'PASS needs live evidence'
has   "undecided gate is CANNOT DETERMINE" '`CANNOT DETERMINE` (tokens, themes'
has   "proven keyboard trap is critical" 'A proven trap is a CRITICAL finding and fails A2.'
has   "undecided gate feeds row 3"        'a gate `CANNOT DETERMINE` is this skill'"'"'s coverage-gate FAIL (row 3)'
has   "trap needs no keyboard exit of any kind" 'no keyboard exit of any kind'
has   "undetermined check stays in possible" 'staying in `possible`'
has   "positive tabindex is a finding, not a gate FAIL" 'A positive `tabindex` (2.4.3) is a finding, not a gate FAIL.'
has   "gate combines across components"      'a gate is FAIL if any component fails'
has   "2.5.8 is the 24px AA target"      'Target size >= 24x24 CSS px (44x44 is AAA 2.5.5)'
lacks "2.5.8 not in the AAA list"        '2.4.9, 2.5.8, 3.1.5'
for sc in 2.4.11 2.5.7 3.2.6 3.3.7 3.3.8; do has "WCAG 2.2 criterion $sc is mapped" "| $sc |"; done

echo "RESULT: PASS=$npass FAIL=$nfail"
[ "$nfail" -eq 0 ]
