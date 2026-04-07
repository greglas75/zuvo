#!/usr/bin/env bash
source "$(dirname "$0")/../seo-suite/assert.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/benchmark.sh"
SKILL="$ROOT/skills/benchmark/SKILL.md"
SCHEMA="$ROOT/shared/includes/benchmark-output-schema.md"
# benchmark.sh has the new flag
assert_contains "$SCRIPT" "with-test-adversarial"
assert_contains "$SCRIPT" "WITH_TEST_ADVERSARIAL"
# SKILL.md documents the flag and round 4
assert_contains "$SKILL" "--with-test-adversarial"
assert_contains "$SKILL" "Round 4"
assert_contains "$SKILL" "test_adversarial_delta"
# Schema has the new field
assert_contains "$SCHEMA" "test_adversarial_delta"
pass "Round 4 adversarial-on-tests contracts verified"
