#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

setup() {
  rm -rf "$REPO_ROOT/dist/codex" "$REPO_ROOT/dist/cursor" "$REPO_ROOT/dist/antigravity"
}

@test "Codex build materializes reviewer lanes to concrete models" {
  run bash "$REPO_ROOT/scripts/build-codex-skills.sh" "$REPO_ROOT"
  [ "$status" -eq 0 ]

  local primary="$REPO_ROOT/dist/codex/agents/write-tests-blind-coverage-auditor.toml"
  local alt="$REPO_ROOT/dist/codex/agents/write-tests-blind-coverage-auditor-alt.toml"
  local fallback_primary="$REPO_ROOT/dist/codex/agents/write-tests-adversarial-test-reviewer.toml"
  local fallback_alt="$REPO_ROOT/dist/codex/agents/write-tests-adversarial-test-reviewer-alt.toml"

  [ -f "$primary" ]
  [ -f "$alt" ]
  [ -f "$fallback_primary" ]
  [ -f "$fallback_alt" ]
  run rg -n 'review-primary|review-alt' "$primary" "$alt" "$fallback_primary" "$fallback_alt"
  [ "$status" -eq 1 ]
  run rg -n 'model = "gpt-5.4"' "$primary" "$fallback_primary"
  [ "$status" -eq 0 ]
  run rg -n 'model = "gpt-5.3-codex"' "$alt" "$fallback_alt"
  [ "$status" -eq 0 ]
}

@test "Cursor build degrades both reviewer lanes to inherit" {
  run bash "$REPO_ROOT/scripts/build-cursor-skills.sh" "$REPO_ROOT"
  [ "$status" -eq 0 ]

  local primary="$REPO_ROOT/dist/cursor/agents/write-tests-blind-coverage-auditor.md"
  local alt="$REPO_ROOT/dist/cursor/agents/write-tests-blind-coverage-auditor-alt.md"
  local fallback_primary="$REPO_ROOT/dist/cursor/agents/write-tests-adversarial-test-reviewer.md"
  local fallback_alt="$REPO_ROOT/dist/cursor/agents/write-tests-adversarial-test-reviewer-alt.md"

  [ -f "$primary" ]
  [ -f "$alt" ]
  [ -f "$fallback_primary" ]
  [ -f "$fallback_alt" ]
  run rg -n 'review-primary|review-alt' "$primary" "$alt" "$fallback_primary" "$fallback_alt"
  [ "$status" -eq 1 ]
  run rg -n '^model: inherit$' "$primary" "$alt" "$fallback_primary" "$fallback_alt"
  [ "$status" -eq 0 ]
}

@test "Antigravity build materializes reviewer lanes to Gemini tiers" {
  run bash "$REPO_ROOT/scripts/build-antigravity-skills.sh" "$REPO_ROOT"
  [ "$status" -eq 0 ]

  local primary="$REPO_ROOT/dist/antigravity/skills/write-tests/agents/blind-coverage-auditor.md"
  local alt="$REPO_ROOT/dist/antigravity/skills/write-tests/agents/blind-coverage-auditor-alt.md"
  local fallback_primary="$REPO_ROOT/dist/antigravity/skills/write-tests/agents/adversarial-test-reviewer.md"
  local fallback_alt="$REPO_ROOT/dist/antigravity/skills/write-tests/agents/adversarial-test-reviewer-alt.md"

  [ -f "$primary" ]
  [ -f "$alt" ]
  [ -f "$fallback_primary" ]
  [ -f "$fallback_alt" ]
  run rg -n 'review-primary|review-alt' "$primary" "$alt" "$fallback_primary" "$fallback_alt"
  [ "$status" -eq 1 ]
  run rg -n '^model: gemini-3.1-pro-high$' "$primary" "$fallback_primary"
  [ "$status" -eq 0 ]
  run rg -n '^model: gemini-3.1-pro-low$' "$alt" "$fallback_alt"
  [ "$status" -eq 0 ]
}
