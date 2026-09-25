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
  # The last three are the Codex Desktop signals zms_is_codex_host (scripts/lib/model-subprocess.sh)
  # also reads: without them, the whole suite run from inside Codex Desktop turns every
  # cursor/antigravity/kimi case into platform=codex.
  # -u CLAUDE_MODEL / -u CODEX_MODEL / -u ZUVO_CODEX_MODEL: the router checks the Claude
  # branch BEFORE the Codex branch, so an ambient CLAUDE_MODEL misroutes every Codex/
  # Antigravity/Kimi case to platform=claude, and an ambient CODEX_MODEL/ZUVO_CODEX_MODEL
  # can misroute the Codex-writer-model cases the same way — the same who-ran-it dependence
  # the header above already fixed for the other markers. PATH is pinned to what clean_env
  # (below) uses for the same reason: an ambient PATH entry (~/.kimi-code/bin) must not
  # decide a case that never meant to test Kimi detection. As with every marker here, the
  # case's OWN assignments in "$@" come after these and win — see the Kimi cases that pass
  # PATH/MOONSHOT_API_KEY/ZUVO_KIMI_CLI_MODEL explicitly, and the Codex-writer cases that
  # pass ZUVO_CODEX_MODEL explicitly: those still work because env applies same-named
  # assignments left to right, last one wins.
  run env -u CLAUDECODE -u CLAUDE_MODEL -u CODEX_MODEL -u ZUVO_CODEX_MODEL -u CODEX_SANDBOX \
      -u ANTIGRAVITY_SESSION_ID -u VSCODE_GIT_ASKPASS_MAIN -u CLAUDE_CODE_ENTRYPOINT \
      -u CODEX_SHELL -u CODEX_INTERNAL_ORIGINATOR_OVERRIDE -u __CFBundleIdentifier \
      PATH=/usr/bin:/bin "$@" "$SCRIPT"
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

@test "routes Codex mini writer to the gpt-6-sol primary reviewer" {
  run_route ZUVO_CODEX_MODEL=gpt-5.4-mini
  [ "$status" -eq 0 ]
  assert_line "platform=codex"
  assert_line "writer_model=gpt-5.4-mini"
  assert_line "writer_lane=small"
  assert_line "reviewer_lane=review-primary"
  assert_line "reviewer_model=gpt-6-sol"
  assert_line "routing_status=ok"
}

@test "routes Codex gpt-5.4 writer to the gpt-6-luna alternate reviewer" {
  run_route ZUVO_CODEX_MODEL=gpt-5.4
  [ "$status" -eq 0 ]
  assert_line "platform=codex"
  assert_line "writer_model=gpt-5.4"
  assert_line "writer_lane=strong_primary"
  assert_line "reviewer_lane=review-alt"
  assert_line "reviewer_model=gpt-6-luna"
  assert_line "routing_status=ok"
}

@test "routes Codex gpt-5.5 writer to the gpt-6-sol primary reviewer" {
  # gpt-5.3-codex left the registry a generation ago, so the old pair asserted a
  # route that could no longer exist. This covers the model that actually holds
  # the strong_alt lane now.
  run_route ZUVO_CODEX_MODEL=gpt-5.5
  [ "$status" -eq 0 ]
  assert_line "platform=codex"
  assert_line "writer_model=gpt-5.5"
  assert_line "writer_lane=strong_alt"
  assert_line "reviewer_lane=review-primary"
  assert_line "reviewer_model=gpt-6-sol"
  assert_line "routing_status=ok"
}

@test "the registry's OWN Codex primary must not fall back to itself" {
  # Regression lock for a real defect this repair uncovered: model-registry.sh
  # names gpt-5.6-sol as ZUVO_MODEL_CODEX_PRIMARY, but the router's table never
  # learned it, so the DEFAULT Codex model resolved to unknown-writer-model and
  # then same-model-fallback — a Codex session reviewing its own work with the
  # same model, which is the one outcome cross-model routing exists to prevent.
  # Since b9e9a912 the registry's primary is gpt-6-sol; the same lock now holds for it.
  run_route ZUVO_CODEX_MODEL=gpt-6-sol
  [ "$status" -eq 0 ]
  assert_line "routing_status=ok"
  [[ "$output" != *"same-model-fallback"* ]]
  [[ "$output" != *"unknown-writer-model"* ]]
  [[ "$output" != *"reviewer_model=gpt-6-sol"* ]]
  assert_line "reviewer_model=gpt-6-luna"
}

@test "the previous Codex primary (gpt-5.6-sol) still routes, to the alt lane" {
  run_route ZUVO_CODEX_MODEL=gpt-5.6-sol
  [ "$status" -eq 0 ]
  assert_line "routing_status=ok"
  assert_line "reviewer_model=gpt-6-luna"
}

@test "the registry's Codex alt (gpt-6-luna) is reviewed by the primary, never by itself" {
  run_route ZUVO_CODEX_MODEL=gpt-6-luna
  [ "$status" -eq 0 ]
  assert_line "writer_lane=strong_alt"
  assert_line "reviewer_lane=review-primary"
  assert_line "reviewer_model=gpt-6-sol"
  assert_line "routing_status=ok"
}

@test "routes the registry's small Codex model (gpt-5.6-luna) to the primary reviewer" {
  run_route ZUVO_CODEX_MODEL=gpt-5.6-luna
  [ "$status" -eq 0 ]
  assert_line "writer_lane=small"
  assert_line "reviewer_lane=review-primary"
  assert_line "reviewer_model=gpt-6-sol"
  assert_line "routing_status=ok"
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
  # The contract: report same-model-fallback rather than name a reviewer that cannot run.
  # Preflight escalates a non-ok status to `degraded-routing`, and an audit that believes
  # it had a cross-model reviewer when it did not is worse than one that admits it.
  #
  # HOME and PATH are both redirected into a scratch dir holding ONLY the Kimi bin marker.
  # The first version of this case kept `/usr/bin:/bin` on PATH and asserted in a comment
  # that "agy/codex/claude are all absent" — true on the machine I wrote it on, false on
  # the i9 farm, which ships /usr/bin/codex and /usr/bin/claude. It passed locally and
  # failed there: precisely the who-ran-it dependence this file's header exists to prevent,
  # reintroduced by me while adding a guard against it. Asserting client ABSENCE means
  # controlling the search path outright, not assuming a clean system.
  # `$BASH` (absolute path of the running shell), not the script directly: with PATH cut
  # down to the scratch dir, the `#!/usr/bin/env bash` shebang has nowhere to find `bash`
  # and the run dies with 127 before the router is ever reached. The router itself needs
  # no external command — it is builtins and parameter expansion all the way down — so an
  # explicit interpreter is all it takes to run under a PATH this narrow.
  local scratch="$BATS_TEST_TMPDIR/kimi-only"
  mkdir -p "$scratch/.kimi-code/bin"
  run env -u CLAUDECODE -u CODEX_SANDBOX -u ANTIGRAVITY_SESSION_ID \
      -u VSCODE_GIT_ASKPASS_MAIN -u CLAUDE_CODE_ENTRYPOINT -u MOONSHOT_API_KEY \
      -u CODEX_SHELL -u CODEX_INTERNAL_ORIGINATOR_OVERRIDE -u __CFBundleIdentifier \
      -u CLAUDE_MODEL -u CODEX_MODEL -u ZUVO_CODEX_MODEL \
      "HOME=$scratch" "PATH=$scratch/.kimi-code/bin" "$BASH" "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_line "platform=kimi"
  assert_line "reviewer_lane=same-model-fallback"
  assert_line "routing_status=same-model-fallback"
}

# ─── Codex host detection comes from scripts/lib/model-subprocess.sh ─────────
# zms_is_codex_host knows FOUR signals — the ones the adversarial driver has used since 2026-08.
# This router checked only CODEX_SANDBOX (plus its own ZUVO_CODEX_MODEL hint), and Codex Desktop
# exports the other three, not that one: a review started there resolved platform=unknown and
# fell back to the writer's own model. Every case below clears EVERY host signal and pins PATH
# before setting the one under test — the suite itself may run inside Claude Code, Codex Desktop,
# Zed (__CFBundleIdentifier=dev.zed.Zed) or with ~/.kimi-code/bin on PATH, and none of that may
# decide a verdict. The env is applied first; the case's own assignments come after it and win.
clean_env() {
  env -u CLAUDECODE -u CLAUDE_MODEL -u CLAUDE_CODE_ENTRYPOINT \
      -u CODEX_SANDBOX -u CODEX_SHELL -u CODEX_INTERNAL_ORIGINATOR_OVERRIDE -u __CFBundleIdentifier \
      -u CODEX_MODEL -u ZUVO_CODEX_MODEL -u ANTIGRAVITY_SESSION_ID -u VSCODE_GIT_ASKPASS_MAIN \
      -u CURSOR_AGENT_MODEL -u CURSOR_MODEL -u GEMINI_MODEL -u ANTIGRAVITY_MODEL \
      -u ZUVO_KIMI_CLI_MODEL -u ZUVO_KIMI_MODEL -u MOONSHOT_API_KEY \
      PATH=/usr/bin:/bin "$@"
}

# The router's contract (env-compat.md): exactly six lines, each key once, nothing else.
assert_six_keys() {
  local line key n=0 seen=" "
  while IFS= read -r line; do
    n=$((n + 1))
    key="${line%%=*}"
    case "$key" in platform|writer_model|writer_lane|reviewer_lane|reviewer_model|routing_status) ;; *) return 1 ;; esac
    case "$seen" in *" $key "*) return 1 ;; esac
    seen="$seen$key "
  done <<< "$output"
  [ "$n" -eq 6 ]
}

# The fail-closed sentinel of shared/includes/env-compat.md ("Failure mode contract"), verbatim.
routing_failed_sentinel() {
  printf '%s\n' platform=unknown writer_model=unknown writer_lane=unknown \
    reviewer_lane=same-model-fallback reviewer_model=unknown routing_status=routing-failed
}

@test "Codex host: CODEX_SANDBOX alone is a Codex host" {
  run clean_env CODEX_SANDBOX=seatbelt "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_six_keys
  assert_line "platform=codex"
}

@test "Codex host: CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' alone is a Codex host" {
  run clean_env "CODEX_INTERNAL_ORIGINATOR_OVERRIDE=Codex Desktop" "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_six_keys
  assert_line "platform=codex"
}

@test "Codex host: CODEX_SHELL=1 alone is a Codex host" {
  run clean_env CODEX_SHELL=1 "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_six_keys
  assert_line "platform=codex"
}

@test "Codex host: __CFBundleIdentifier=com.openai.codex alone is a Codex host" {
  run clean_env __CFBundleIdentifier=com.openai.codex "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_six_keys
  assert_line "platform=codex"
}

@test "Codex host: look-alike values are not a Codex host (the four-signal cases are not vacuous)" {
  # Another app's bundle id (the one this suite is often run from), CODEX_SHELL other than 1, and
  # a different originator: none of them may say Codex, or every case above passes for nothing.
  run clean_env __CFBundleIdentifier=dev.zed.Zed CODEX_SHELL=0 CODEX_INTERNAL_ORIGINATOR_OVERRIDE=codex_exec "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_six_keys
  assert_line "platform=unknown"
  assert_line "routing_status=unknown-writer-model"
}

@test "Codex host: the router's own ZUVO_CODEX_MODEL hint still identifies Codex" {
  # Not a host signal (the library does not know it) — the router's own writer-model hint, kept.
  run clean_env ZUVO_CODEX_MODEL=gpt-6-luna "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_line "platform=codex"
  assert_line "reviewer_model=gpt-6-sol"
}

@test "detection never runs a client: a sentinel codex is not executed and the router answers within 5 s" {
  # Host detection and the cursor/kimi client probes decide by name lookup only. A codex that
  # touches a file and then hangs would show up here as the file, as a timeout, or both.
  local t="$BATS_TEST_TMPDIR/sentinel" start
  mkdir -p "$t/bin"
  printf '#!/bin/sh\n: > "%s/invoked"\nsleep 30\n' "$t" > "$t/bin/codex"
  chmod +x "$t/bin/codex"
  start=$SECONDS
  run clean_env CODEX_SHELL=1 "ZUVO_CODEX_BIN=$t/bin/codex" "PATH=$t/bin:/usr/bin:/bin" "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_line "platform=codex"
  [ ! -e "$t/invoked" ]
  [ $((SECONDS - start)) -lt 5 ]
  start=$SECONDS
  run clean_env VSCODE_GIT_ASKPASS_MAIN=/Applications/Cursor.app/probe CURSOR_AGENT_MODEL=composer-2.5-fast \
      "ZUVO_CODEX_BIN=$t/bin/codex" "PATH=$t/bin:/usr/bin:/bin" "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_line "platform=cursor"
  [ ! -e "$t/invoked" ]
  [ $((SECONDS - start)) -lt 5 ]
}

@test "run_route is immune to an ambient Codex host: cursor/antigravity/kimi rows unchanged" {
  # The suite run from inside Codex Desktop: all three Desktop signals exported in the PARENT.
  # run_route must strip them, or every row below turns into platform=codex.
  export CODEX_SHELL=1 CODEX_INTERNAL_ORIGINATOR_OVERRIDE="Codex Desktop" __CFBundleIdentifier=com.openai.codex
  run_route GEMINI_MODEL=gemini-2.5-flash
  [ "$status" -eq 0 ]
  assert_line "platform=antigravity"
  assert_line "reviewer_model=gemini-3.1-pro-high"
  run_route VSCODE_GIT_ASKPASS_MAIN=/Applications/Cursor.app/probe CURSOR_AGENT_MODEL=composer-2.5-fast
  [ "$status" -eq 0 ]
  assert_line "platform=cursor"
  assert_line "writer_lane=small"
  run_route "PATH=$(KIMI_PATH)"
  [ "$status" -eq 0 ]
  assert_line "platform=kimi"
  assert_line "writer_model=kimi-code"
}

@test "library missing: the router alone prints exactly the fail-closed sentinel and exits 0" {
  # Copied alone into an empty dir, HOME without ~/.zuvo/model-subprocess.sh: no host answer may be
  # guessed without the one implementation that decides it. The sentinel is DATA for the caller
  # (reviewer-preflight.sh parses stdout and degrades on routing-failed), so the exit stays 0; the
  # reason goes to stderr. Both a Codex and a Claude host get the same answer: fail closed is not
  # host-dependent. /bin/bash: the oldest shell the router must run under (3.2 on macOS).
  local alone="$BATS_TEST_TMPDIR/alone" home="$BATS_TEST_TMPDIR/empty-home" host rc
  mkdir -p "$alone" "$home"
  cp "$SCRIPT" "$alone/reviewer-model-route.sh"
  routing_failed_sentinel > "$BATS_TEST_TMPDIR/want"
  for host in CODEX_SHELL=1 CLAUDE_MODEL=opus; do
    rc=0
    clean_env "HOME=$home" "$host" /bin/bash "$alone/reviewer-model-route.sh" \
      > "$BATS_TEST_TMPDIR/out" 2> "$BATS_TEST_TMPDIR/err" || rc=$?
    [ "$rc" -eq 0 ]
    diff -u "$BATS_TEST_TMPDIR/want" "$BATS_TEST_TMPDIR/out"
    [[ "$(cat "$BATS_TEST_TMPDIR/err")" == *"model-subprocess.sh"* ]]
  done
}

@test "library lookup is sibling first — <dir>/lib/ → <dir>/ → ~/.zuvo/ — and the library decides" {
  # The installed layouts: every host dir gets scripts/lib/ beside this file (install_runner_lib),
  # ~/.zuvo gets the flat copy. A DECOY that calls everything a Codex host sits in each LOWER
  # candidate: a clean env must still route as unknown, so the decoy was not the one loaded.
  local lib="$BATS_TEST_DIRNAME/../lib/model-subprocess.sh" base="$BATS_TEST_TMPDIR/layouts" layout d h
  [ -f "$lib" ]
  mkdir -p "$base"
  printf 'zms_is_codex_host() { return 0; }\n' > "$base/decoy.sh"
  for layout in lib flat home; do
    d="$base/$layout/scripts"; h="$base/$layout/home"
    mkdir -p "$d" "$h/.zuvo"
    cp "$SCRIPT" "$d/reviewer-model-route.sh"
    case "$layout" in
      lib)  mkdir -p "$d/lib"; cp "$lib" "$d/lib/model-subprocess.sh"
            cp "$base/decoy.sh" "$d/model-subprocess.sh"; cp "$base/decoy.sh" "$h/.zuvo/model-subprocess.sh" ;;
      flat) cp "$lib" "$d/model-subprocess.sh"; cp "$base/decoy.sh" "$h/.zuvo/model-subprocess.sh" ;;
      home) cp "$lib" "$h/.zuvo/model-subprocess.sh" ;;
    esac
    run clean_env "HOME=$h" /bin/bash "$d/reviewer-model-route.sh"
    [ "$status" -eq 0 ]
    assert_six_keys
    assert_line "platform=unknown"
    assert_line "routing_status=unknown-writer-model"
    run clean_env "HOME=$h" CODEX_SHELL=1 /bin/bash "$d/reviewer-model-route.sh"
    [ "$status" -eq 0 ]
    assert_line "platform=codex"
  done
  # Relative invocations resolve to the same directory (bash scripts/x.sh, bash x.sh from its dir).
  cd "$base/lib"
  run clean_env "HOME=$base/lib/home" /bin/bash scripts/reviewer-model-route.sh
  assert_line "platform=unknown"
  cd "$base/lib/scripts"
  run clean_env "HOME=$base/lib/home" /bin/bash reviewer-model-route.sh
  assert_line "platform=unknown"
  # And when the decoy IS the first candidate, it decides: the answer comes from the library, not
  # from a copy of the signals inside the router.
  d="$base/decoy-first/scripts"
  mkdir -p "$d/lib" "$base/decoy-first/home"
  cp "$SCRIPT" "$d/reviewer-model-route.sh"
  cp "$base/decoy.sh" "$d/lib/model-subprocess.sh"
  run clean_env "HOME=$base/decoy-first/home" /bin/bash "$d/reviewer-model-route.sh"
  [ "$status" -eq 0 ]
  assert_line "platform=codex"
}

@test "a library candidate that exists but does not load is named on stderr and the next one is used" {
  # Two ways to be broken: the file fails when sourced, or it loads and defines no zms_is_codex_host.
  local lib="$BATS_TEST_DIRNAME/../lib/model-subprocess.sh" kind d h rc
  for kind in fails empty; do
    d="$BATS_TEST_TMPDIR/broken-$kind/scripts"; h="$BATS_TEST_TMPDIR/broken-$kind/home"
    mkdir -p "$d/lib" "$h"
    cp "$SCRIPT" "$d/reviewer-model-route.sh"
    case "$kind" in
      fails) printf 'return 1\n' > "$d/lib/model-subprocess.sh" ;;
      empty) : > "$d/lib/model-subprocess.sh" ;;
    esac
    cp "$lib" "$d/model-subprocess.sh"
    rc=0
    clean_env "HOME=$h" CODEX_SHELL=1 /bin/bash "$d/reviewer-model-route.sh" \
      > "$BATS_TEST_TMPDIR/out" 2> "$BATS_TEST_TMPDIR/err" || rc=$?
    [ "$rc" -eq 0 ]
    [[ "$(cat "$BATS_TEST_TMPDIR/out")" == *"platform=codex"* ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/err")" == *"$d/lib/model-subprocess.sh"* ]]
  done
}
