#!/usr/bin/env bash
source "$(dirname "$0")/../seo-suite/assert.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
assert_contains "$ROOT/skills/using-zuvo/SKILL.md" "zuvo:benchmark"
assert_contains "$ROOT/.claude-plugin/plugin.json" "46 skills"
assert_contains "$ROOT/docs/skills.md" "benchmark"
pass "Benchmark wiring verified (routing + manifest + docs)"
