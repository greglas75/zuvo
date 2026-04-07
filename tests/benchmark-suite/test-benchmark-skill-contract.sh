#!/usr/bin/env bash
source "$(dirname "$0")/../seo-suite/assert.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/skills/benchmark/SKILL.md"
assert_file_exists "$SKILL"
# Frontmatter
assert_contains "$SKILL" "name: benchmark"
# Argument table has all flags
assert_contains "$SKILL" "--diff"
assert_contains "$SKILL" "--files"
assert_contains "$SKILL" "--prompt"
assert_contains "$SKILL" "--provider"
assert_contains "$SKILL" "--show-costs"
assert_contains "$SKILL" "--compare"
assert_contains "$SKILL" "--replay-last"
assert_contains "$SKILL" "--json"
# Phase markers
assert_contains "$SKILL" "Phase 0"
assert_contains "$SKILL" "Phase 1"
assert_contains "$SKILL" "Phase 2"
assert_contains "$SKILL" "Phase 3"
assert_contains "$SKILL" "Phase 4"
# Meta-judge opposite-model selection
assert_contains "$SKILL" "opus"
assert_contains "$SKILL" "sonnet"
assert_contains "$SKILL" "opposite"
# Output block
assert_contains "$SKILL" "BENCHMARK COMPLETE"
# Run log
assert_contains "$SKILL" "Run:"
# Compare flag
assert_contains "$SKILL" "--compare"
# Schema reference
assert_contains "$SKILL" "benchmark-output-schema"
# Corpus mode flags
assert_contains "$SKILL" "--mode corpus"
assert_contains "$SKILL" "--with-tests"
assert_contains "$SKILL" "--with-adversarial"
assert_contains "$SKILL" "--with-static-checks"
# Multi-round phases
assert_contains "$SKILL" "Round 1"
assert_contains "$SKILL" "Round 3"
assert_contains "$SKILL" "adversarial"
# Corpus task file references
assert_contains "$SKILL" "benchmark-corpus/task-code.md"
assert_contains "$SKILL" "benchmark-corpus/task-tests.md"
# Extended leaderboard columns
assert_contains "$SKILL" "code_score"
assert_contains "$SKILL" "test_score"
assert_contains "$SKILL" "compile_ok"
assert_contains "$SKILL" "tests_pass"
assert_contains "$SKILL" "self_eval_bias"
assert_contains "$SKILL" "adversarial_delta"
# Multi-round tmpdir structure
assert_contains "$SKILL" "round1_"
assert_contains "$SKILL" "round3_"
pass "SKILL.md default mode contract verified"
