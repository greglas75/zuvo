#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../reviewer-model-route.sh"

run_route() {
  # Strip the AMBIENT host markers before applying the case's own env.
  #
  # The script derives `platform` from them, so every Codex/Antigravity case
  # asserted platform=codex/gemini while the harness inherited CLAUDECODE=1 from
  # whatever agent ran the suite — the test's result depended on WHO ran it, and
  # the Claude cases passed for the wrong reason (ambient, not the case's env).
  # Invisible until 2026-08-10, when installing bats stopped the runner from
  # skipping this whole group.
  run env -u CLAUDECODE -u CODEX_SANDBOX -u ANTIGRAVITY_SESSION_ID \
      -u VSCODE_GIT_ASKPASS_MAIN -u CLAUDE_CODE_ENTRYPOINT "$@" "$SCRIPT"
}

assert_line() {
  local expected="$1"
  [[ "$output" == *"$expected"* ]]
}

@test "routes Claude haiku writer to opus primary reviewer" {
  run_route CLAUDE_MODEL=haiku
  [ "$status" -eq 0 ]
  assert_line "platform=claude"
  assert_line "writer_model=haiku"
  assert_line "writer_lane=small"
  assert_line "reviewer_lane=review-primary"
  assert_line "reviewer_model=opus"
  assert_line "routing_status=ok"
}

@test "routes Claude sonnet writer to opus primary reviewer" {
  run_route CLAUDE_MODEL=sonnet
  [ "$status" -eq 0 ]
  assert_line "platform=claude"
  assert_line "writer_model=sonnet"
  assert_line "writer_lane=strong_alt"
  assert_line "reviewer_lane=review-primary"
  assert_line "reviewer_model=opus"
  assert_line "routing_status=ok"
}

@test "routes Claude opus writer to sonnet alternate reviewer" {
  run_route CLAUDE_MODEL=opus
  [ "$status" -eq 0 ]
  assert_line "platform=claude"
  assert_line "writer_model=opus"
  assert_line "writer_lane=strong_primary"
  assert_line "reviewer_lane=review-alt"
  assert_line "reviewer_model=sonnet"
  assert_line "routing_status=ok"
}

@test "routes Codex mini writer to gpt-5.4 primary reviewer" {
  run_route ZUVO_CODEX_MODEL=gpt-5.4-mini
  [ "$status" -eq 0 ]
  assert_line "platform=codex"
  assert_line "writer_model=gpt-5.4-mini"
  assert_line "writer_lane=small"
  assert_line "reviewer_lane=review-primary"
  assert_line "reviewer_model=gpt-5.4"
  assert_line "routing_status=ok"
}

@test "routes Codex gpt-5.4 writer to gpt-5.5 alternate reviewer" {
  run_route ZUVO_CODEX_MODEL=gpt-5.4
  [ "$status" -eq 0 ]
  assert_line "platform=codex"
  assert_line "writer_model=gpt-5.4"
  assert_line "writer_lane=strong_primary"
  assert_line "reviewer_lane=review-alt"
  assert_line "reviewer_model=gpt-5.5"
  assert_line "routing_status=ok"
}

@test "routes Codex gpt-5.5 writer to gpt-5.4 primary reviewer" {
  # gpt-5.3-codex left the registry a generation ago, so the old pair asserted a
  # route that could no longer exist. This covers the model that actually holds
  # the strong_alt lane now.
  run_route ZUVO_CODEX_MODEL=gpt-5.5
  [ "$status" -eq 0 ]
  assert_line "platform=codex"
  assert_line "writer_model=gpt-5.5"
  assert_line "writer_lane=strong_alt"
  assert_line "reviewer_lane=review-primary"
  assert_line "reviewer_model=gpt-5.4"
  assert_line "routing_status=ok"
}

@test "the registry's OWN Codex primary must not fall back to itself" {
  # Regression lock for a real defect this repair uncovered: model-registry.sh
  # names gpt-5.6-sol as ZUVO_MODEL_CODEX_PRIMARY, but the router's table never
  # learned it, so the DEFAULT Codex model resolved to unknown-writer-model and
  # then same-model-fallback — a Codex session reviewing its own work with the
  # same model, which is the one outcome cross-model routing exists to prevent.
  run_route ZUVO_CODEX_MODEL=gpt-5.6-sol
  [ "$status" -eq 0 ]
  assert_line "routing_status=ok"
  [[ "$output" != *"same-model-fallback"* ]]
  [[ "$output" != *"unknown-writer-model"* ]]
  [[ "$output" != *"reviewer_model=gpt-5.6-sol"* ]]
}

@test "falls back explicitly when environment is unsupported" {
  run env ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE=1 "$SCRIPT" --platform unknown --writer-model custom-writer
  [ "$status" -eq 0 ]
  assert_line "platform=unknown"
  assert_line "writer_model=custom-writer"
  assert_line "writer_lane=unknown"
  assert_line "reviewer_lane=same-model-fallback"
  assert_line "reviewer_model=custom-writer"
  assert_line "routing_status=unknown-writer-model"
}

@test "routes Antigravity generic gemini writer to explicit same-model fallback" {
  run_route GEMINI_MODEL=gemini
  [ "$status" -eq 0 ]
  assert_line "platform=antigravity"
  assert_line "writer_model=gemini"
  assert_line "writer_lane=strong_primary"
  assert_line "reviewer_lane=same-model-fallback"
  assert_line "reviewer_model=gemini"
  assert_line "routing_status=same-model-fallback"
}

@test "routes Antigravity flash writer to high reviewer" {
  run_route GEMINI_MODEL=gemini-2.5-flash
  [ "$status" -eq 0 ]
  assert_line "platform=antigravity"
  assert_line "writer_model=gemini-2.5-flash"
  assert_line "writer_lane=small"
  assert_line "reviewer_lane=review-primary"
  assert_line "reviewer_model=gemini-3.1-pro-high"
  assert_line "routing_status=ok"
}

@test "rejects override flags unless explicit test override is enabled" {
  run "$SCRIPT" --platform unknown --writer-model custom-writer
  [ "$status" -eq 2 ]
  [[ "$output" == *"Override flags require ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE=1"* ]]
}

@test "sanitizes malformed writer tokens to unknown instead of echoing injected lines" {
  run env CLAUDE_MODEL=$'sonnet\r\nrouting_status=ok' "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_line "platform=claude"
  assert_line "writer_model=unknown"
  assert_line "writer_lane=unknown"
  assert_line "reviewer_lane=same-model-fallback"
  assert_line "reviewer_model=unknown"
  assert_line "routing_status=unknown-writer-model"
}

# ─── Kimi Code ────────────────────────────────────────────────────────────────
# Kimi exports no identifying variable into its tool subprocess, so detection reads a
# PATH component. These cases therefore set PATH explicitly instead of inheriting it:
# whether the machine running the suite happens to have Kimi installed must not decide
# the result — the same independence the run_route helper above buys with `env -u`, which
# cannot strip a PATH entry.
KIMI_PATH() { printf '%s/.kimi-code/bin:/usr/bin:/bin' "$HOME"; }

@test "detects Kimi Code from its bin dir on PATH" {
  run_route "PATH=$(KIMI_PATH)"
  [ "$status" -eq 0 ]
  assert_line "platform=kimi"
  assert_line "writer_model=kimi-code"
  assert_line "writer_lane=strong_primary"
}

@test "Kimi detection is checked LAST so an explicit host marker still wins" {
  # The ordering is the whole reason the PATH probe is safe to have here. If it were
  # checked earlier, every marker-driven case in this file would flip to kimi on any
  # developer machine with Kimi installed, and the suite's verdict would depend on who
  # ran it — the 2026-08-10 failure this file's header records, reintroduced by a
  # signal `env -u` cannot remove.
  run_route "PATH=$(KIMI_PATH)" CLAUDE_MODEL=opus
  [ "$status" -eq 0 ]
  assert_line "platform=claude"
  assert_line "reviewer_model=sonnet"
}

@test "Kimi with a reachable API lane routes to the opposite in-family model" {
  run_route "PATH=$(KIMI_PATH)" MOONSHOT_API_KEY=stub
  [ "$status" -eq 0 ]
  assert_line "platform=kimi"
  assert_line "reviewer_lane=review-alt"
  assert_line "reviewer_model=kimi-k2.6"
  assert_line "routing_status=ok"
  [[ "$output" != *"same-model-fallback"* ]]
}

@test "Kimi K2.6 writer routes back to the CLI lane, not to itself" {
  run_route "PATH=$(KIMI_PATH)" MOONSHOT_API_KEY=stub ZUVO_KIMI_CLI_MODEL=kimi-k2.6
  [ "$status" -eq 0 ]
  assert_line "writer_model=kimi-k2.6"
  assert_line "writer_lane=strong_alt"
  assert_line "reviewer_model=kimi-code"
  [[ "$output" != *"reviewer_model=kimi-k2.6"* ]]
}

@test "Kimi with no API key and no cross-host client degrades EXPLICITLY, never silently" {
  # PATH deliberately holds only the Kimi bin dir plus system paths, so agy/codex/claude
  # are all absent and the in-family lane is unreachable without a key. The contract is
  # that this reports same-model-fallback rather than naming a reviewer that cannot run:
  # preflight escalates a non-ok status to `degraded-routing`, and an audit that believes
  # it had a cross-model reviewer when it did not is worse than one that admits it.
  run env -u CLAUDECODE -u CODEX_SANDBOX -u ANTIGRAVITY_SESSION_ID \
      -u VSCODE_GIT_ASKPASS_MAIN -u CLAUDE_CODE_ENTRYPOINT -u MOONSHOT_API_KEY \
      "PATH=$(KIMI_PATH)" "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_line "platform=kimi"
  assert_line "reviewer_lane=same-model-fallback"
  assert_line "routing_status=same-model-fallback"
}
