#!/usr/bin/env bash
source "$(dirname "$0")/../seo-suite/assert.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/skills/agent-benchmark/SKILL.md"
assert_file_exists "$SKILL"
assert_contains "$SKILL" "name: agent-benchmark"
# 4 rounds
assert_contains "$SKILL" "Round 1"
assert_contains "$SKILL" "Round 2"
assert_contains "$SKILL" "Round 3"
assert_contains "$SKILL" "Round 4"
# Agent writes code itself
assert_contains "$SKILL" "YOU write"
assert_contains "$SKILL" "Write tool"
# Adversarial multi-provider (no --single)
assert_contains "$SKILL" "adversarial-review.sh"
assert_contains "$SKILL" "Multi-provider"
# Adversarial run commands should NOT include --single flag
! grep -q '\-\-single' "$SKILL" || fail "adversarial commands should NOT use --single"
# Output artifacts
assert_contains "$SKILL" "r1-OrderService.ts"
assert_contains "$SKILL" "r2-OrderService.ts"
assert_contains "$SKILL" "r3-OrderService.test.ts"
assert_contains "$SKILL" "r4-OrderService.test.ts"
assert_contains "$SKILL" "agent-benchmark.json"
# Corpus references
assert_contains "$SKILL" "task-code.md"
assert_contains "$SKILL" "task-tests.md"
pass "agent-benchmark SKILL.md contract verified"
