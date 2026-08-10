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
