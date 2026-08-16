#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

# Wipe before each case so every assertion below runs against files this test's own
# build (or its cache replay) materialized — never against a tree left by a sibling.
# The three `run bash .../dist-build.sh <p>` calls repopulate what this removes.
setup() {
  rm -rf "$REPO_ROOT/dist/codex" "$REPO_ROOT/dist/cursor" "$REPO_ROOT/dist/antigravity"
}

@test "Codex build materializes reviewer lanes to concrete models" {
  run bash "$REPO_ROOT/tests/lib/dist-build.sh" codex
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
  # Strip EVERY host marker, not just two. reviewer-model-route.sh picks the reviewer from
  # the detected HOST, so an ambient ANTIGRAVITY_SESSION_ID / VSCODE_GIT_ASKPASS_MAIN makes
  # these two probes answer with Gemini or Claude ids and the Codex assertions below fail —
  # the test's result would depend on WHICH IDE ran the suite. reviewer-model-route.bats:14
  # already strips the full set; this file stripped a subset until 2026-08-11.
  route_codex() {
    env -u CLAUDECODE -u CODEX_SANDBOX -u ANTIGRAVITY_SESSION_ID \
        -u VSCODE_GIT_ASKPASS_MAIN -u CLAUDE_CODE_ENTRYPOINT "ZUVO_CODEX_MODEL=$1" \
        bash "$REPO_ROOT/scripts/reviewer-model-route.sh" | sed -n 's/^reviewer_model=//p'
  }
  local want_primary want_alt
  want_primary="$(route_codex gpt-5.5)"
  want_alt="$(route_codex gpt-5.4)"
  [ -n "$want_primary" ]
  [ -n "$want_alt" ]
  [ "$want_primary" != "$want_alt" ]   # a build that collapsed both lanes to one model is broken
  run rg -n "model = \"$want_primary\"" "$primary" "$fallback_primary"
  [ "$status" -eq 0 ]
  run rg -n "model = \"$want_alt\"" "$alt" "$fallback_alt"
  [ "$status" -eq 0 ]

  # ANCHOR TO THE REGISTRY, not only to router<->build self-consistency. Deriving both
  # sides from the router proves those two agree, but says nothing about whether either
  # matches model-registry.sh — the actual source of truth. One find-and-replace typo
  # applied to the router AND the build together would keep them agreeing while both
  # drifted off the registry, and the check above would still pass. That is the narrow
  # circularity this closes: every model the build emits must be a model the registry
  # actually names.
  local reg_known
  # shellcheck disable=SC1091
  reg_known="$(bash -c '. "$1"/shared/includes/model-registry.sh
      printf "%s %s %s" "$ZUVO_MODEL_CODEX_PRIMARY" "$ZUVO_MODEL_CODEX_ALT" "$ZUVO_MODEL_CODEX_REVIEW_ALT"' _ "$REPO_ROOT")"
  [ -n "${reg_known// /}" ]
  # Membership, not positional equality: the registry names the LANES, the router decides
  # which lane reviews which writer, so pinning want_primary=="$reg_primary" would
  # over-specify routing policy and break on a legitimate lane swap. What must hold is
  # that the build cannot emit a model the registry has never heard of — the check that
  # caught gpt-5.5 being dispatched while absent from the "single source of model ids".
  [[ " $reg_known " == *" $want_primary "* ]]
  [[ " $reg_known " == *" $want_alt "* ]]
}

@test "Cursor build degrades both reviewer lanes to inherit" {
  run bash "$REPO_ROOT/tests/lib/dist-build.sh" cursor
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
  run bash "$REPO_ROOT/tests/lib/dist-build.sh" antigravity
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
