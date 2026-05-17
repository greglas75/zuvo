#!/usr/bin/env bash
# test-flagship-skills.sh — Tasks 9-12: 4 flagship skills handle the new contract.

declare -A SKILLS=(
  [review]="$ROOT/skills/review/SKILL.md"
  [brainstorm]="$ROOT/skills/brainstorm/SKILL.md"
  [plan]="$ROOT/skills/plan/SKILL.md"
  [write-article]="$ROOT/skills/write-article/SKILL.md"
)

for skill_name in review brainstorm plan write-article; do
  start_test "$skill_name SKILL.md branches on partial/single-provider"
  file="${SKILLS[$skill_name]}"
  for term in 'status: "partial"' 'single_provider_only' 'timeout_count'; do
    if grep -qF -- "$term" "$file"; then
      pass "$skill_name contains: $term"
    else
      fail "$skill_name" "missing: $term"
    fi
  done
done
