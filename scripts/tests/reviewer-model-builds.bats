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
  # DERIVE the expected models from the router instead of hardcoding them. The old
  # literals ("gpt-5.4" / "gpt-5.3-codex") were a FOURTH copy of the model list,
  # alongside model-registry.sh, the router table and the build itself — and
  # gpt-5.3-codex had already left the registry a generation earlier, so this
  # asserted a pairing that could no longer be produced. What is worth pinning is
  # that the BUILD and the ROUTER agree; a model rename should move both together
  # or fail here, not be re-typed in a third place.
  local want_primary want_alt
  want_primary="$(env -u CLAUDECODE -u CODEX_SANDBOX ZUVO_CODEX_MODEL=gpt-5.5 \
      bash "$REPO_ROOT/scripts/reviewer-model-route.sh" | sed -n 's/^reviewer_model=//p')"
  want_alt="$(env -u CLAUDECODE -u CODEX_SANDBOX ZUVO_CODEX_MODEL=gpt-5.4 \
      bash "$REPO_ROOT/scripts/reviewer-model-route.sh" | sed -n 's/^reviewer_model=//p')"
  [ -n "$want_primary" ]
  [ -n "$want_alt" ]
  [ "$want_primary" != "$want_alt" ]   # a build that collapsed both lanes to one model is broken
  run rg -n "model = \"$want_primary\"" "$primary" "$fallback_primary"
  [ "$status" -eq 0 ]
  run rg -n "model = \"$want_alt\"" "$alt" "$fallback_alt"
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
