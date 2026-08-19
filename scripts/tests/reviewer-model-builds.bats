#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

# PER-FILE dist root (B-DIST-BUILD-RACE). The wipe below is necessary — every assertion must run
# against files THIS test's build materialized, never a tree left by a sibling — but wiping the
# SHARED $REPO_ROOT/dist is what made it a race: test-install-wiring.sh and test-kimi-build.sh
# build into the same tree, so this setup() could truncate a directory another file was asserting
# against. Red about twice in ten suite runs, and it produced two wrong conclusions in one session
# (a bisect that blamed an innocent registry change, and a "regression" that was not one) — both
# only caught by re-running in a git worktree with its own dist/.
#
# The builders now honour ZUVO_DIST_ROOT, so this file gets its own directory and the wipe touches
# nothing anyone else can see. Unset elsewhere, the default is the historical $REPO_ROOT/dist.
setup_file() {
  # TWO variables on purpose. ZUVO_DIST_SANDBOX is the directory this file created and is the ONLY
  # thing teardown removes; ZUVO_DIST_ROOT is where the builders write, INSIDE it.
  #
  # The first cut kept only ZUVO_DIST_ROOT and cleaned up with `rm -rf "$(dirname "$ZUVO_DIST_ROOT")"`.
  # That is a delete target computed by walking UP from a variable, and on 2026-08-18 a probe set
  # ZUVO_DIST_ROOT="$REPO_ROOT/dist" — so dirname was the repository, and teardown_file DELETED THE
  # WHOLE CHECKOUT, .git included. Recovered from an APFS local snapshot. Never derive an `rm -rf`
  # target with dirname; delete the exact path you created, and verify it is the one you created.
  ZUVO_DIST_SANDBOX="$(mktemp -d)"
  ZUVO_DIST_ROOT="$ZUVO_DIST_SANDBOX/dist"
  export ZUVO_DIST_SANDBOX ZUVO_DIST_ROOT
  mkdir -p "$ZUVO_DIST_ROOT"
}

teardown_file() {
  # Belt and braces on the guard above: remove it only if it still looks like the mktemp directory
  # this file made. A cleanup that cannot prove what it is deleting does not run.
  # The `$TMPDIR` arm is GONE, and its absence is the whole point. Written as
  #     /tmp/*|/var/folders/*|"${TMPDIR%/}"/*
  # an UNSET TMPDIR makes the third pattern `/*`, which matches every absolute path — so the guard
  # written specifically to stop this teardown deleting the repository would have permitted exactly
  # that. Verified: with `env -u TMPDIR`, ZUVO_DIST_SANDBOX=<repo root> MATCHED. Found by the
  # adversarial pass over the commit that added the guard, hours after the unguarded version had
  # already destroyed this checkout once.
  #
  # A guard whose safety depends on an environment variable being set is not a guard. These two
  # literal prefixes are where `mktemp -d` puts things on macOS and Linux; anything else is refused
  # out loud rather than removed.
  case "${ZUVO_DIST_SANDBOX:-}" in
    /tmp/*|/var/folders/*) [ -d "$ZUVO_DIST_SANDBOX" ] && rm -rf "$ZUVO_DIST_SANDBOX" ;;
    *) echo "teardown_file: refusing to remove unexpected sandbox '${ZUVO_DIST_SANDBOX:-}'" >&2 ;;
  esac
}

setup() {
  rm -rf "$ZUVO_DIST_ROOT/codex" "$ZUVO_DIST_ROOT/cursor" "$ZUVO_DIST_ROOT/antigravity"
}

@test "Codex build materializes reviewer lanes to concrete models" {
  run bash "$REPO_ROOT/tests/lib/dist-build.sh" codex
  [ "$status" -eq 0 ]

  local primary="$ZUVO_DIST_ROOT/codex/agents/write-tests-blind-coverage-auditor.toml"
  local alt="$ZUVO_DIST_ROOT/codex/agents/write-tests-blind-coverage-auditor-alt.toml"
  local fallback_primary="$ZUVO_DIST_ROOT/codex/agents/write-tests-adversarial-test-reviewer.toml"
  local fallback_alt="$ZUVO_DIST_ROOT/codex/agents/write-tests-adversarial-test-reviewer-alt.toml"

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

  local primary="$ZUVO_DIST_ROOT/cursor/agents/write-tests-blind-coverage-auditor.md"
  local alt="$ZUVO_DIST_ROOT/cursor/agents/write-tests-blind-coverage-auditor-alt.md"
  local fallback_primary="$ZUVO_DIST_ROOT/cursor/agents/write-tests-adversarial-test-reviewer.md"
  local fallback_alt="$ZUVO_DIST_ROOT/cursor/agents/write-tests-adversarial-test-reviewer-alt.md"

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

  local primary="$ZUVO_DIST_ROOT/antigravity/skills/write-tests/agents/blind-coverage-auditor.md"
  local alt="$ZUVO_DIST_ROOT/antigravity/skills/write-tests/agents/blind-coverage-auditor-alt.md"
  local fallback_primary="$ZUVO_DIST_ROOT/antigravity/skills/write-tests/agents/adversarial-test-reviewer.md"
  local fallback_alt="$ZUVO_DIST_ROOT/antigravity/skills/write-tests/agents/adversarial-test-reviewer-alt.md"

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
