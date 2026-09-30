#!/usr/bin/env bash
#
# smoke-cross-vendor.sh — Plan C whole-feature smoke: a Claude writer is reviewed by Codex, `model-run`
# runs the routed reviewer isolated, and test-audit dispatches to it in every dist
# (docs/specs/2026-09-25-cross-vendor-reviewer-routing-plan.md, "Whole-feature Smoke Proofs"):
#   SMOKE-C1  the router routes a Claude writer to Codex and NEVER executes the client (a sentinel fake
#             that would touch a marker); codex missing -> unknown-writer-model; --fallback with a KNOWN
#             writer (CLAUDE_MODEL=opus) -> in-family-fallback (with the writer unset it is
#             unknown-writer-model — Technical Decisions, amended 2026-09-28);
#   SMOKE-C2  test-model-run.sh and test-install-wiring.sh (model-run's contract; the INSTALLED ~/.zuvo
#             layout);
#   SMOKE-C3  every dist (codex cursor antigravity kimi) is built into a PRIVATE root and its test-audit
#             SKILL.md carries the batch dispatch (the ~/.zuvo/test-audit-batch group call, which runs
#             model-run); then reviewer-model-builds.bats;
#   SMOKE-C4  LIVE, only with ZUVO_LIVE_SMOKE=1 (otherwise `SKIP live`): one real test-audit batch through
#             Codex, prompted exactly as test-audit Phase 1a builds it (the prompt, the listing and the
#             --require/--reject patterns come from scripts/zuvo-home/test-audit-batch, sourced), and
#             probe P5 (a nested `claude -p` from inside `codex exec`, the Codex-host arm) re-run.
#
# Test level: LARGE when live (one real model call and a nested CLI), MEDIUM otherwise (real router,
# real builds, chained suites; no model).
#
# NOT SELF-TESTED: the C4 live arm — c4_prepare, c4_live_batch, c4_p5 — and the exit-75 (BLOCKED_INFRA)
# classification in c4_live_batch / smoke_verdict run ONLY with ZUVO_LIVE_SMOKE=1. A default run never
# executes them, so a default PASS says nothing about them: no test plants a timeout / auth / unavailable
# status to prove the 75-versus-1 split. Read a live run's own output for that.
#
# Exit: 0 every executed part passed | 75 the live part failed ONLY on provider infrastructure
#       (model-run status=timeout|auth|unavailable, or P5 timing out / hitting a login wall) — report it as
#       BLOCKED_INFRA, it is not a code failure | 1 anything else, or no check executed.
#       An `unavailable` whose route= names a DEFECT (no-runner, no-router, no-timeout, malformed,
#       same-vendor, routing-failed) is not infrastructure: it is exit 1.
#
# The proof log is written by the script itself to zuvo/proofs/smoke-plan-c.txt (ZUVO_SMOKE_PROOF
# overrides the path). It carries status lines and Tier lines, never a model's answer text.
#
# Named smoke-* on purpose: run-all.sh globs tests/hooks/test-*.sh, which already runs the suites chained
# here; this file would only run them a second time (and SMOKE-C4 spends a real model call).
#
# Run (bash 3.2 and 5.x):
#   TF_ALLOW_LOCAL=1 bash tests/hooks/smoke-cross-vendor.sh
#   TF_ALLOW_LOCAL=1 ZUVO_LIVE_SMOKE=1 bash tests/hooks/smoke-cross-vendor.sh
#
# SOURCEABLE: a direct run re-executes itself to tee the proof log; sourcing only defines the functions.
set -u
_SMOKE_MAIN=0
[ "${BASH_SOURCE[0]:-$0}" = "$0" ] && _SMOKE_MAIN=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd -P)"
cd "$ROOT" || { echo "smoke: cannot cd to $ROOT" >&2; exit 2; }

if [ "$_SMOKE_MAIN" -eq 1 ] && [ -z "${_SMOKE_INNER:-}" ]; then
  PROOF="${ZUVO_SMOKE_PROOF:-$ROOT/zuvo/proofs/smoke-plan-c.txt}"
  mkdir -p "$(dirname "$PROOF")" || exit 2
  ptmp="$PROOF.tmp.$$"
  _SMOKE_INNER=1 bash "$0" "$@" 2>&1 | tee "$ptmp"
  rc="${PIPESTATUS[0]}"
  mv -f "$ptmp" "$PROOF" || rc=1
  echo "proof written: $PROOF"
  exit "$rc"
fi

EXECUTED=0; PASSED=0; FAILED=0; INFRA=0
SCRATCH=()   # every private directory this run made; removed at exit when the run passed

mkscratch() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/smoke-cv.XXXXXX")" || return 1
  SCRATCH+=("$d")
  printf '%s\n' "$d"
}
# Only a directory this run created (a mktemp result under a temp prefix) is ever removed.
cleanup_scratch() {
  local d
  [ "$FAILED" -eq 0 ] || { [ "${#SCRATCH[@]}" -eq 0 ] || echo "kept for inspection: ${SCRATCH[*]}"; return 0; }
  for d in ${SCRATCH[@]+"${SCRATCH[@]}"}; do
    case "$d" in
      /tmp/smoke-cv.*|/private/tmp/smoke-cv.*|/var/folders/*/smoke-cv.*|/private/var/folders/*/smoke-cv.*|"${TMPDIR:-/nonexistent}"/smoke-cv.*)
        [ -d "$d" ] && rm -rf "$d" ;;
    esac
  done
}
trap 'cleanup_scratch' EXIT

# chk <id> <what> <rc> [detail] — one executed check.
chk() {
  EXECUTED=$((EXECUTED+1))
  if [ "$3" -eq 0 ]; then
    echo "  PASS $1 $2"; PASSED=$((PASSED+1))
  else
    echo "  FAIL $1 $2${4:+ — $4}"; FAILED=$((FAILED+1))
  fi
}
# infra <id> <what> <detail> — a live check that failed on provider infrastructure only.
infra() {
  EXECUTED=$((EXECUTED+1)); INFRA=$((INFRA+1))
  echo "  INFRA $1 $2 — $3"
}

hasline() { printf '%s\n' "$1" | awk -v l="$2" '$0 == l { f = 1 } END { exit !f }'; }
nlines()  { printf '%s\n' "$1" | awk 'END { print NR }'; }

# suite <id> <path> — run a chained suite and demand proof of work: exit 0 alone would also be the
# verdict of a suite that skipped every case. It must report at least one PASS and no FAIL line.
suite() {
  local id="$1" f="$2" out rc np nf
  if [ ! -f "$ROOT/$f" ]; then chk "$id" "$f exists" 1 "missing"; return 0; fi
  out="$(mktemp "${TMPDIR:-/tmp}/smoke-suite.XXXXXX")" || { chk "$id" "$f" 1 "mktemp failed"; return 0; }
  bash "$f" > "$out" 2>&1
  rc=$?
  tail -n 3 "$out"
  np="$(awk '/^[[:space:]]*PASS[: ]/ { n++ } END { print n+0 }' "$out")"
  nf="$(awk '/^[[:space:]]*FAIL[: ]/ { n++ } END { print n+0 }' "$out")"
  rm -f "$out"
  if [ "$rc" -ne 0 ]; then chk "$id" "bash $f exits 0" 1 "exit $rc, PASS=$np FAIL=$nf"; return 0; fi
  if [ "$np" -eq 0 ] || [ "$nf" -ne 0 ]; then chk "$id" "bash $f proves work" 1 "exit 0 but PASS=$np FAIL=$nf"; return 0; fi
  chk "$id" "bash $f exits 0 (PASS=$np FAIL=0)" 0
}

# ── SMOKE-C1 ──────────────────────────────────────────────────────────────────────────────────────────
# route [VAR=value]... [-- <router args>] — the router on a Claude Code host with every other host signal
# cleared and PATH narrowed (it must work without a real codex anywhere; ZUVO_CODEX_BIN is what it may look at).
route() {
  local kv=() args=()
  while [ $# -gt 0 ]; do
    case "$1" in --) shift; args=("$@"); break ;; *) kv+=("$1"); shift ;; esac
  done
  env -u CLAUDE_MODEL -u CODEX_SANDBOX -u CODEX_SHELL -u CODEX_INTERNAL_ORIGINATOR_OVERRIDE -u __CFBundleIdentifier \
      -u ZUVO_CODEX_MODEL -u CODEX_MODEL -u ANTIGRAVITY_SESSION_ID -u CURSOR_AGENT_MODEL -u VSCODE_GIT_ASKPASS_MAIN \
      -u ZUVO_CLAUDE_BIN -u ZUVO_CODEX_BIN \
      PATH=/usr/bin:/bin CLAUDECODE=1 ZUVO_CODEX_APP_BIN=/nonexistent ${kv[@]+"${kv[@]}"} \
      /bin/bash "$ROOT/scripts/reviewer-model-route.sh" ${args[@]+"${args[@]}"}
}

smoke_c1() {
  local F out
  F="$(mkscratch)" || { chk C1.0 "scratch dir" 1 "mktemp failed"; return 0; }
  printf '#!/bin/sh\ntouch "%s/invoked"; exit 0\n' "$F" > "$F/codex"; chmod +x "$F/codex"

  # 1 — base case: cross-vendor, six lines, the writer is honestly unknown, the client is never executed.
  out="$(route ZUVO_CODEX_BIN="$F/codex")"
  hasline "$out" 'reviewer_lane=cross-vendor'; chk C1.1a "Claude host -> reviewer_lane=cross-vendor" $? "$out"
  hasline "$out" 'reviewer_model=gpt-6-sol';   chk C1.1b "reviewer_model=gpt-6-sol" $? "$out"
  hasline "$out" 'writer_model=unknown';       chk C1.1c "unset CLAUDE_MODEL -> writer_model=unknown" $? "$out"
  hasline "$out" 'routing_status=ok';          chk C1.1d "routing_status=ok" $? "$out"
  if [ "$(nlines "$out")" -eq 6 ]; then chk C1.1e "exactly six lines" 0; else chk C1.1e "exactly six lines" 1 "$(nlines "$out") lines"; fi
  if [ ! -e "$F/invoked" ]; then chk C1.1f "the router never executed the client" 0; else chk C1.1f "the router never executed the client" 1; fi

  # 2 — codex gone: no cross-vendor reviewer, and no writer to choose an in-family one by.
  rm -f "$F/invoked"
  out="$(route ZUVO_CODEX_BIN=/nonexistent)"
  hasline "$out" 'routing_status=unknown-writer-model'; chk C1.2 "ZUVO_CODEX_BIN=/nonexistent -> unknown-writer-model" $? "$out"

  # 3 — --fallback: a KNOWN writer gets the in-family degraded reviewer; an unknown one is unknown.
  out="$(route ZUVO_CODEX_BIN="$F/codex" CLAUDE_MODEL=opus -- --fallback 2>/dev/null)"
  hasline "$out" 'routing_status=in-family-fallback'; chk C1.3a "--fallback, CLAUDE_MODEL=opus -> in-family-fallback" $? "$out"
  out="$(route ZUVO_CODEX_BIN="$F/codex" -- --fallback 2>/dev/null)"
  hasline "$out" 'routing_status=unknown-writer-model'; chk C1.3b "--fallback, writer unset -> unknown-writer-model" $? "$out"
  [ ! -e "$F/invoked" ];                       chk C1.3c "--fallback never executed the client either" $?
}

# ── SMOKE-C2 ──────────────────────────────────────────────────────────────────────────────────────────
smoke_c2() {
  suite C2.1 tests/hooks/test-model-run.sh
  suite C2.2 tests/hooks/test-install-wiring.sh
}

# ── SMOKE-C3 ──────────────────────────────────────────────────────────────────────────────────────────
smoke_c3() {
  local S p rc f out np nf
  S="$(mkscratch)" || { chk C3.0 "scratch dir" 1 "mktemp failed"; return 0; }
  for p in codex cursor antigravity kimi; do
    # A PRIVATE root and no per-run cache: a cache would replay (or poison) another test's tree.
    env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$S" bash tests/lib/dist-build.sh "$p" > "$S/build-$p.log" 2>&1
    rc=$?
    chk "C3.$p.build" "dist-build.sh $p exits 0" "$rc" "$(tail -n 3 "$S/build-$p.log" | tr '\n' '|')"
    f="$S/$p/skills/test-audit/SKILL.md"
    if [ -f "$f" ]; then
      awk 'index($0, "~/.zuvo/test-audit-batch group --owner \"$PPID\" --nbatch \"$NBATCH\" --first \"$FIRST\" --token \"$RUN_TOKEN\"") == 1 { f = 1 } END { exit !f }' "$f"
      chk "C3.$p.dispatch" "$p dist test-audit SKILL.md carries the '~/.zuvo/test-audit-batch group …' call unchanged" $?
    else
      chk "C3.$p.dispatch" "$p dist has skills/test-audit/SKILL.md" 1 "missing: $f"
    fi
  done
  command -v bats >/dev/null 2>&1 || { chk C3.bats "bats is installed" 1 "not on PATH"; return 0; }
  out="$S/bats.out"
  bats scripts/tests/reviewer-model-builds.bats > "$out" 2>&1
  rc=$?
  tail -n 2 "$out"
  np="$(awk '/^ok / { n++ } END { print n+0 }' "$out")"
  nf="$(awk '/^not ok / { n++ } END { print n+0 }' "$out")"
  if [ "$rc" -eq 0 ] && [ "$np" -gt 0 ] && [ "$nf" -eq 0 ]; then chk C3.bats "reviewer-model-builds.bats (ok=$np not-ok=0)" 0
  else chk C3.bats "reviewer-model-builds.bats" 1 "exit $rc, ok=$np not-ok=$nf"; fi
}

# ── SMOKE-C4 (live) ───────────────────────────────────────────────────────────────────────────────────
# c4_load_batch_script — the functions and patterns of scripts/zuvo-home/test-audit-batch (the script
# test-audit Phase 1a runs), sourced: it defines and runs nothing when sourced. The prompt, the listing
# and the --require/--reject patterns this smoke uses are therefore the script's own, and cannot drift
# from what Phase 1a does. Status 1 when it does not load or lacks something used here.
c4_load_batch_script() {
  local fn
  # shellcheck source=scripts/zuvo-home/test-audit-batch
  . "$ROOT/scripts/zuvo-home/test-audit-batch" || return 1
  for fn in tab_build_prompt tab_prompt_ok tab_listing_ok tab_render_listing tab_gate; do
    declare -F "$fn" >/dev/null || return 1
  done
  [ -n "${TAB_REQUIRE:-}" ] && [ -n "${TAB_REJECT:-}" ] && [ -n "${TAB_CLIENT_TIMEOUT:-}" ]
}

# c4_prepare <dir> — the per-batch prompt and listing, built by the script's own functions. Leaves
# <dir>/batch-1.prompt, batch-1.files, batch-1.list; records its checks. Returns non-zero when the
# prepared inputs cannot be trusted (the live call is then not made).
c4_prepare() {
  local D="$1" inc="$ROOT/shared/includes/test-audit-batch-prompt.md"
  local t prod rc last same
  # Any failure here aborts the preparation: a live call with an empty --require/--reject, or with a
  # function missing, would test nothing the script really does.
  c4_load_batch_script; rc=$?
  chk C4.0a "scripts/zuvo-home/test-audit-batch loads when sourced, with its prompt, listing and gate functions and its patterns" "$rc"
  [ "$rc" -eq 0 ] || return 1

  tab_build_prompt "$inc" "$D/batch-1.prompt"; rc=$?
  [ "$rc" -eq 0 ] && [ -s "$D/batch-1.prompt" ]
  chk C4.0b "the script builds a valid prompt from the include (exit 0, non-empty prompt)" $? "rc=$rc"
  [ -s "$D/batch-1.prompt" ] || return 1
  tab_prompt_ok "$D/batch-1.prompt"
  chk C4.0c "the script's validator accepts the prompt (no placeholder, VC set, OUTPUT LINE FORMAT rule)" $?
  { cat "$D/batch-1.prompt"; echo '[BATCH FILE LIST]'; } > "$D/neg.prompt"
  if tab_prompt_ok "$D/neg.prompt"; then chk C4.0d "the validator rejects a prompt with the placeholder left" 1 "accepted"
  else chk C4.0d "the validator rejects a prompt with the placeholder left" 0; fi
  last="$(tail -n 1 "$D/batch-1.prompt")"
  if [ "$last" = 'Files to audit:' ]; then chk C4.0e "the prompt ends with 'Files to audit:' (the listing lands where the placeholder stood)" 0; else chk C4.0e "the prompt ends with 'Files to audit:' (the listing lands where the placeholder stood)" 1 "last line: $last"; fi
  cmp -s "$D/batch-1.prompt" "$inc" && same=1 || same=0
  if [ "$same" -eq 0 ]; then chk C4.0f "the prompt is NOT the raw include (fences and heading stripped)" 0; else chk C4.0f "the prompt is NOT the raw include (fences and heading stripped)" 1; fi
  awk 'index($0, "```") == 1 || index($0, "### Agent Prompt") == 1 { bad = 1 } END { exit bad }' "$D/batch-1.prompt"
  chk C4.0g "no fence and no heading line survives in the prompt" $?

  # The listing: <absolute test path> TAB <absolute production path>, checked and rendered by the script's
  # own functions — the ones the group call runs.
  t="$ROOT/tests/hooks/test-log-ideas.sh"; prod="$ROOT/scripts/zuvo-home/log-ideas"
  if { [ -f "$t" ] && [ -f "$prod" ]; }; then chk C4.0h "the small real test and its target exist" 0; else chk C4.0h "the small real test and its target exist" 1 "$t / $prod"; fi
  printf '%s\t%s\n' "$t" "$prod" > "$D/batch-1.files"
  tab_listing_ok "$D/batch-1.files"
  chk C4.0i "the script accepts the listing: two TAB fields, absolute test path, absolute production path" $?
  printf 'rel/t.test.sh\t%s\n' "$prod" > "$D/neg.files"
  if tab_listing_ok "$D/neg.files"; then chk C4.0j "the script refuses a listing with a relative test path" 1 "accepted"
  else chk C4.0j "the script refuses a listing with a relative test path" 0; fi
  tab_render_listing "$D/batch-1.files" > "$D/batch-1.list"
  if [ "$(cat "$D/batch-1.list")" = "$t (production: $prod)" ]; then chk C4.0k "batch-1.list is '<test> (production: <target>)'" 0; else chk C4.0k "batch-1.list is '<test> (production: <target>)'" 1; fi
  return 0
}

# c4_live_batch <dir> — one real batch through the REPO model-run, from a Claude Code host, with the
# script's own --require / --reject / client budget (c4_prepare sourced them). Records its checks (or INFRA).
c4_live_batch() {
  local D="$1" rc st status route el0 el exp tiers
  # shellcheck source=/dev/null
  . "$ROOT/shared/includes/model-registry.sh"
  exp="model-run: status=ok client=codex model=${ZUVO_MODEL_CODEX_PRIMARY} effort=${ZUVO_CODEX_EFFORT_AUDIT} route=cross-vendor"
  el0=$SECONDS
  env -u CODEX_SANDBOX -u CODEX_SHELL -u CODEX_INTERNAL_ORIGINATOR_OVERRIDE -u __CFBundleIdentifier CLAUDECODE=1 \
    bash "$ROOT/scripts/zuvo-home/model-run" --route --mode audit --access read --read-root "$ROOT" \
      --prompt-file "$D/batch-1.prompt" --append-file "$D/batch-1.list" \
      --require "$TAB_REQUIRE" \
      --reject "$TAB_REJECT" \
      --timeout "$TAB_CLIENT_TIMEOUT" --out "$D/batch-1.md" 2> "$D/batch-1.status"
  rc=$?
  el=$((SECONDS - el0))
  st="$(awk 'index($0, "model-run: status=") == 1 { l = $0 } END { print l }' "$D/batch-1.status")"
  echo "  model-run exit=$rc wall=${el}s"
  echo "  status line: ${st:-<none>}"
  if [ "$rc" -ne 0 ]; then
    status="${st#model-run: status=}"; status="${status%% *}"; route="${st##* route=}"
    case "$status:$route" in
      *:no-runner|*:no-router|*:no-timeout|*:malformed|*:same-vendor|*:routing-failed)
        chk C4.1 "live batch through model-run --route" 1 "exit $rc, $st (a defect, not provider infrastructure)" ;;
      timeout:*|auth:*|unavailable:*)
        infra C4.1 "live batch through model-run --route" "exit $rc, $st" ;;
      *) chk C4.1 "live batch through model-run --route" 1 "exit $rc, ${st:-no status line}" ;;
    esac
    return 0
  fi
  chk C4.1a "model-run exits 0" 0
  if [ "$st" = "$exp" ]; then chk C4.1b "stderr status line is '$exp'" 0; else chk C4.1b "stderr status line is '$exp'" 1 "got: $st"; fi
  if [ "$(awk 'END { print NR }' "$D/batch-1.status")" -ge 1 ]; then chk C4.1c "the status line is the last stderr line" 0; else chk C4.1c "the status line is the last stderr line" 1; fi
  if [ -f "$D/batch-1.md" ]; then chk C4.1d "--out wrote batch-1.md" 0; else chk C4.1d "--out wrote batch-1.md" 1; fi
  tiers="$(awk '/^Tier: ([ABCD]|INCOMPLETE)( |$)/' "$D/batch-1.md" 2>/dev/null)"
  if [ -n "$tiers" ]; then chk C4.1e "batch-1.md has a column-0 'Tier: <A|B|C|D|INCOMPLETE>' line" 0; else chk C4.1e "batch-1.md has a column-0 'Tier: <A|B|C|D|INCOMPLETE>' line" 1 "none"; fi
  echo "  Tier line(s): $(printf '%s' "$tiers" | tr '\n' '|')"
  tab_gate "$D/batch-1.files" "$D/batch-1.md" 2>/dev/null
  chk C4.1f "the report passes the script's DONE gate: a '### <absolute test path>' section with a verdict line for the listed file" $?
  return 0
}

# c4_p5 <dir> — probe P5: a nested `claude -p` from inside `codex exec` answers 42 (the Codex-host arm).
c4_p5() {
  local D="$1/p5" model reviewer rc ans crc
  mkdir -p "$D" || { chk C4.2 "P5 scratch dir" 1 "mkdir failed"; return 0; }
  # shellcheck source=/dev/null
  . "$ROOT/shared/includes/model-registry.sh"
  reviewer="${ZUVO_MODEL_CLAUDE_REVIEWER_OPUS}"
  cat > "$D/inner.sh" <<INNER
#!/bin/bash
# Runs INSIDE codex exec: a nested claude -p, its stdout / stderr / exit code left in files (the ground
# truth is read from these, not from what codex reports).
d="\$(cd "\$(dirname "\$0")" && pwd)"
printf 'What is the product of 6 and 7? Reply with the number only.' | claude -p --model $reviewer --safe-mode --tools "" --strict-mcp-config --mcp-config '{"mcpServers":{}}' --no-session-persistence > "\$d/claude.out" 2> "\$d/claude.err"
echo \$? > "\$d/claude.rc"
INNER
  printf 'This is a connectivity probe. Use your shell tool to run exactly this one command and nothing else:\n\nbash %s/inner.sh\n\nThen reply with the command'"'"'s complete output, verbatim, and nothing else. Do not run any other command.\n' "$D" > "$D/prompt.txt"
  (
    # A Codex session has no Claude Code variables: the nested claude must not inherit the host's.
    for v in $(env | awk -F= '/^(CLAUDECODE|CLAUDE_CODE_[A-Z_]*|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_MODEL)=/ { print $1 }'); do unset "$v"; done
    # shellcheck source=/dev/null
    . "$ROOT/scripts/lib/model-subprocess.sh" || exit 90
    model="$(zms_codex_cli_guard "$ZUVO_MODEL_CODEX_PRIMARY")" || exit 91
    zms_run_codex --model "$model" --effort low --access agent --prompt-file "$D/prompt.txt" --timeout 240 \
      --stderr-file "$D/codex.err" > "$D/codex.out"
  )
  rc=$?
  ans=""; [ -f "$D/claude.out" ] && ans="$(tr -d '[:space:]' < "$D/claude.out")"
  crc=""; [ -f "$D/claude.rc" ] && crc="$(tr -d '[:space:]' < "$D/claude.rc")"
  echo "  P5 codex exit=$rc nested claude answered='$ans' nested exit='${crc:-none}' (claude model $reviewer)"
  if [ "$ans" = 42 ] && [ "$crc" = 0 ]; then chk C4.2 "P5: a nested claude -p from inside codex exec answers 42" 0; return 0; fi
  # Provider infrastructure only: codex timed out, or either side hit a login wall.
  # shellcheck source=/dev/null
  . "$ROOT/scripts/lib/model-subprocess.sh"
  if [ "$rc" -eq 124 ] || zms_is_auth_stub "$D/claude.err" || zms_is_auth_stub "$D/claude.out" || zms_is_auth_stub "$D/codex.err"; then
    infra C4.2 "P5: a nested claude -p from inside codex exec answers 42" "codex exit $rc, nested exit '${crc:-none}', answer '$ans' (timeout or login wall)"
  else
    chk C4.2 "P5: a nested claude -p from inside codex exec answers 42" 1 "codex exit $rc, nested exit '${crc:-none}', answer '$ans' — the documented cross-vendor-unavailable condition is not implemented"
  fi
}

smoke_c4() {
  local T
  if [ "${ZUVO_LIVE_SMOKE:-}" != 1 ]; then echo "  SKIP live (set ZUVO_LIVE_SMOKE=1 to spend one real model call)"; return 0; fi
  T="$(mkscratch)" || { chk C4.0 "scratch dir" 1 "mktemp failed"; return 0; }
  if c4_prepare "$T"; then
    c4_live_batch "$T"
    c4_p5 "$T"
  else
    echo "  the prepared inputs cannot be trusted — the live call is not made"
  fi
}

# smoke_verdict — the final verdict from the counters; EXITS.
smoke_verdict() {
  echo "=== RESULT ==="
  echo "RESULT: EXECUTED=$EXECUTED PASS=$PASSED FAIL=$FAILED INFRA=$INFRA"
  if [ "$EXECUTED" -eq 0 ]; then echo "SMOKE FAIL: no check executed"; exit 1; fi
  if [ "$FAILED" -ne 0 ]; then echo "SMOKE FAIL"; exit 1; fi
  if [ "$INFRA" -ne 0 ]; then echo "SMOKE BLOCKED_INFRA: the live part failed only on provider infrastructure (exit 75)"; exit 75; fi
  echo "SMOKE PASS"
  exit 0
}

if [ "$_SMOKE_MAIN" -eq 1 ]; then
  echo "# smoke-cross-vendor — Plan C ($(date -u +%Y-%m-%dT%H:%M:%SZ)) HEAD=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null) live=${ZUVO_LIVE_SMOKE:-0}"
  for f in scripts/reviewer-model-route.sh scripts/zuvo-home/model-run scripts/lib/model-subprocess.sh \
           tests/hooks/test-model-run.sh tests/hooks/test-install-wiring.sh scripts/tests/reviewer-model-builds.bats \
           tests/lib/dist-build.sh skills/test-audit/SKILL.md shared/includes/test-audit-batch-prompt.md \
           scripts/zuvo-home/test-audit-batch; do
    if [ ! -f "$ROOT/$f" ]; then echo "  FAIL: required file $f is missing — smoke not run"; FAILED=$((FAILED+1)); fi
  done
  [ "$FAILED" -eq 0 ] || smoke_verdict
  echo "=== SMOKE-C1 — a Claude writer is routed to Codex without the router executing anything ==="
  smoke_c1
  echo "=== SMOKE-C2 — model-run runs the routed reviewer isolated, refuses a non-ok route, works from ~/.zuvo ==="
  smoke_c2
  echo "=== SMOKE-C3 — every dist carries the new dispatch and the router's lane words ==="
  smoke_c3
  echo "=== SMOKE-C4 — live: one real test-audit batch through Codex, and the Codex->Opus direction (P5) ==="
  smoke_c4
  smoke_verdict
fi
