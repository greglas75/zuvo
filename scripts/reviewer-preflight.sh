#!/usr/bin/env bash
#
# reviewer-preflight.sh — cheap canary for the write-tests review infrastructure.
#
# Run this BEFORE writing any test. It answers one question early: "will the
# blind coverage audit be able to run at the end of this pipeline?" — so a
# broken reviewer route / missing client / dead model is surfaced up front
# (run marked DRAFT/BLOCKED_INFRA from the start) instead of after an hour of
# test writing, which is how the `supports_reasoning_summaries` failure
# invalidated a finished run.
#
# Checks, in order (cheapest first):
#   1. routing   — reviewer-model-route.sh resolves the 6-key contract in <=5s. When it resolves
#                  routing_status=ok (a genuine cross-vendor route), the CLIENT that serves
#                  reviewer_model (zms_client_for_model, the same mapping the router itself uses)
#                  is probed FIRST in step 3 below, ahead of the panel's own order — that is the
#                  reviewer the pipeline will actually use, wherever the panel happens to rank it.
#                  Any other routing_status never adds a candidate here: the in-family fallback
#                  names a same-vendor model, which the panel already excludes as self-review.
#   2. client    — candidates are exactly `adversarial-review(.sh) --list-providers
#                  --mode blind-audit`'s post-exclusion panel list (mapped to this
#                  script's client names — see pf_map_lane below), the SAME list the
#                  blind coverage audit at the end of this pipeline will actually use.
#                  Preflight keeps no exclusion logic of its own: the driver already
#                  applies vendor host exclusion (a Codex host drops codex-5.3/5.4, a
#                  Claude host drops claude, …), the isolation allowlist that decides
#                  which lanes a blind audit may ever run (cursor-agent and gemini are
#                  not on it and so can never be candidates here), and the argv/agy-
#                  settings drops. Driver missing, or its listing failing, fails this
#                  script CLOSED (no-provider) — never a private fallback list that
#                  could drift from what the audit actually dispatches. The listing
#                  is bounded by $ZUVO_PREFLIGHT_PANEL_TIMEOUT (20s; whole seconds,
#                  1..120 — 0 would mean "no bound" to GNU timeout, so it and any
#                  other value outside that range are a usage error, exit 2) — by
#                  GNU timeout, or by this script's own watchdog on a PATH with none;
#                  a budget that fires is exit 124 either way. Availability
#                  within that list is zms_client_available (the shared runner's own
#                  resolver), so a client counts exactly when the runner could start
#                  it: ZUVO_CODEX_BIN / ZUVO_CLAUDE_BIN (a SET value is final — even
#                  /nonexistent), then PATH, then the Codex.app fallback.
#   3. canary    — OPTIONAL real model round-trip, each client bounded by
#                  $ZUVO_PREFLIGHT_TIMEOUT (60s). The prompt asks for a COMPUTED
#                  answer ("the product of 6 and 7, digits only"); a canary passes
#                  only when the client EXITS 0 and a line of its stdout reads 42
#                  (blanks, markdown emphasis/backticks and a trailing period
#                  around it trimmed — "142" or "The answer is 42" do not count).
#                  A 42 followed by a crash or by a hang the timeout ended does
#                  not count either. The prompt never contains the answer: the
#                  old canary asked the client to repeat the token
#                  ZUVO_PREFLIGHT_OK and grepped for it, so a client that merely
#                  echoed its input passed. Candidates are tried in order until
#                  one passes. Without GNU timeout (timeout/gtimeout) NO canary
#                  runs — each is named on stderr. Every canary runs isolated:
#                    codex/claude  — zms_run_codex / zms_run_claude --access none:
#                                    neutral cwd, own CODEX_HOME (auth.json + a
#                                    minimal config.toml, no MCP servers), strict
#                                    EMPTY MCP config for claude, no tools;
#                                    model/effort = what the blind audit uses
#                                    (codex: ZUVO_CODEX_MODEL → registry
#                                    ZUVO_MODEL_CODEX_PRIMARY, effort
#                                    ZUVO_BLIND_AUDIT_EFFORT → ZUVO_CODEX_EFFORT_AUDIT;
#                                    claude: ZUVO_CLAUDE_AUDIT_MODEL → registry
#                                    ZUVO_MODEL_CLAUDE_REVIEWER_OPUS); no model id
#                                    = that canary fails, named on stderr
#                    agy / cursor-agent / kimi / gemini — from a neutral temp cwd
#                                    (never the caller's repository), under GNU
#                                    timeout, stdin from /dev/null (gemini: the
#                                    prompt file) — never the caller's stdin.
#                  Skipped with --no-canary or ZUVO_PREFLIGHT_NO_CANARY=1
#                  (routing+client alone already catch the common failures).
#
# Shared runner: scripts/lib/model-subprocess.sh, found the way the router and the
# adversarial driver find it — <this dir>/lib/model-subprocess.sh →
# <this dir>/model-subprocess.sh → ~/.zuvo/model-subprocess.sh. A candidate that
# exists but does not load is named on stderr and the next one is tried.
# NONE loads → fail CLOSED: preflight_status=no-provider, provider=none, exit 1,
# one stderr line naming model-subprocess.sh, and no client is run. Without it no
# reviewer can be judged available the way the runners resolve it, nor canaried in
# isolation, so "reachable" would be a guess. (The router, missing it, prints its
# routing-failed sentinel as data — passed through below — and exits 0; preflight's
# job is the verdict, and the verdict is "unavailable".)
#
# Output: KEY=VALUE lines on stdout (stable contract, one per line):
#   preflight_status=ok|degraded-routing|no-provider|canary-failed
#   provider=<the client that answered | the first candidate | none>
#   + the six reviewer-model-route.sh keys, passed through
# The trailing six lines are the ROUTER's raw answer, forwarded verbatim, even when
# preflight_status disagrees with them (e.g. routing_status=ok can appear right next to
# preflight_status=degraded-routing on a contract-violation verdict — see emit_and_exit and the
# verdict switch, section 4). preflight_status is the one field callers act on; the six-key block
# is not re-validated for a reader and must not be read as agreeing with it.
# stderr: diagnostics only — one line per failed canary (client and why), never the
#   client's own output.
#
# Exit codes:
#   0  review infrastructure reachable (status ok OR degraded-routing —
#      degraded routing still permits a same-model-fallback audit)
#   1  review infrastructure unavailable (no-provider / canary-failed) —
#      caller must mark the run BLOCKED_INFRA from the start
#   2  usage error
set -uo pipefail

# This script's directory, PHYSICAL — resolved the way the driver and the router resolve theirs (one
# method, three copies: the library cannot resolve the path it is being looked up by): from BASH_SOURCE
# by parameter expansion — a bare name only when that file is in $PWD (bash opened it from there) —
# then `cd -P` + `pwd -P`, builtins only. The logical `cd` + `pwd` it replaces folded a `..` after a
# symlinked directory LEXICALLY — into a directory this file is not in, whose lib/ it then sourced.
# Empty when it cannot be resolved: nothing is then looked up or run beside it (an empty prefix would
# make every sibling path a file at the filesystem root).
_pf_src="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR=""
case "$_pf_src" in
  */*) SCRIPT_DIR="${_pf_src%/*}"; [ -n "$SCRIPT_DIR" ] || SCRIPT_DIR=/ ;;
  ?*)  if [ -n "${PWD:-}" ] && [ -f "$PWD/$_pf_src" ]; then SCRIPT_DIR="$PWD"; fi ;;
esac
if [ -n "$SCRIPT_DIR" ]; then SCRIPT_DIR="$(CDPATH='' cd -P -- "$SCRIPT_DIR" 2>/dev/null && pwd -P)" || SCRIPT_DIR=""; fi
unset _pf_src
ROUTE_SCRIPT=""
if [ -n "$SCRIPT_DIR" ]; then ROUTE_SCRIPT="$SCRIPT_DIR/reviewer-model-route.sh"; fi
CANARY=1
TIMEOUT_SECONDS="${ZUVO_PREFLIGHT_TIMEOUT:-60}"
[ "${ZUVO_PREFLIGHT_NO_CANARY:-0}" = "1" ] && CANARY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --no-canary) CANARY=0; shift ;;
    --canary) CANARY=1; shift ;;
    -h|--help)
      # The whole header comment, however long it grows.
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2 ;;
  esac
done

# Leading zeros go: the runners take the value as seconds and refuse a leading 0, so "060" would
# have passed here and then failed every codex/claude canary as "could not start".
if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "Invalid ZUVO_PREFLIGHT_TIMEOUT: $TIMEOUT_SECONDS" >&2
  exit 2
fi
_pf_given="$TIMEOUT_SECONDS"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS#"${TIMEOUT_SECONDS%%[!0]*}"}"
if [ -z "$TIMEOUT_SECONDS" ]; then
  echo "Invalid ZUVO_PREFLIGHT_TIMEOUT: $_pf_given" >&2
  exit 2
fi
unset _pf_given

# GNU timeout under either name (macOS ships none; Homebrew coreutils installs both).
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
KILL_GRACE=5

# ADV-A92: the panel listing (`adversarial-review --list-providers --mode blind-audit`, a
# no-model-call listing operation) is bounded generously at 20s by default, but a fixed timeout
# cannot tell "slow" from "broken" — make it tunable rather than requiring an edit to this script
# for a host where that bound genuinely needs to move.
# P2-33: tunable, but always a BOUND. GNU timeout reads a duration of 0 as "no timeout at all", so
# `=0` silently removed the very ceiling this knob exists to tune — and a huge value does the same
# in practice. Digits only, leading zeros dropped (as for ZUVO_PREFLIGHT_TIMEOUT above: "020" is
# 20), then 1..PANEL_LIST_TIMEOUT_MAX; anything else is refused before any listing runs. 120s is six
# times the default for an operation that makes no model call — past that, "slow" is "broken".
PANEL_LIST_TIMEOUT_MAX=120
PANEL_LIST_TIMEOUT="${ZUVO_PREFLIGHT_PANEL_TIMEOUT:-20}"
_pf_given="$PANEL_LIST_TIMEOUT"
if [[ "$PANEL_LIST_TIMEOUT" =~ ^[0-9]+$ ]]; then
  PANEL_LIST_TIMEOUT="${PANEL_LIST_TIMEOUT#"${PANEL_LIST_TIMEOUT%%[!0]*}"}"
else
  PANEL_LIST_TIMEOUT=""
fi
# Length first: a 40-digit value must be refused as too large, not overflow the -gt below.
if [ -z "$PANEL_LIST_TIMEOUT" ] || [ "${#PANEL_LIST_TIMEOUT}" -gt 3 ] \
   || [ "$PANEL_LIST_TIMEOUT" -gt "$PANEL_LIST_TIMEOUT_MAX" ]; then
  echo "Invalid ZUVO_PREFLIGHT_PANEL_TIMEOUT: $_pf_given (want whole seconds, 1..$PANEL_LIST_TIMEOUT_MAX)" >&2
  exit 2
fi
unset _pf_given

# run_with_timeout <secs> <cmd...> — for this script's OWN helpers (the router, the driver's
# --list-providers): bounded ALWAYS — by GNU timeout when there is one, by preflight's own watchdog
# (_pf_run_bounded) when there is not. It used to run the command as-is without GNU timeout (P3C-2),
# and stock macOS ships none, so there the listing ran unbounded: a wedged driver hung preflight, and
# the write-tests Phase 0 waiting on it. Either way a budget that fires is status 124. Model clients
# never go through here — see run_neutral (without GNU timeout they are not run at all).
run_with_timeout() {
  local secs="$1"; shift
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" -k "$KILL_GRACE" "$secs" "$@"
  else
    _pf_run_bounded "$secs" "$@"
  fi
}

# _pf_tree <pid> — <pid> and every descendant still attached to it by parent pid, one per line: the
# ps walk scripts/lib/model-subprocess.sh's _zms_reap uses. Only <pid> when ps cannot be read.
_pf_tree() {
  printf '%s\n' "$1"
  ps -A -o pid= -o ppid= 2>/dev/null | awk -v r="$1" '{ k[$2] = k[$2] " " $1 }
    END { q = k[r]; while (q != "") { n = split(q, a, " "); q = ""; for (j = 1; j <= n; j++) { print a[j]; q = q k[a[j]] } } }'
}

# _pf_run_bounded <secs> <cmd...> — run_with_timeout's bash-native bound, for a PATH with no GNU
# timeout. The command runs in the background (stdin /dev/null, as a non-interactive shell gives a
# background job anyway). A watchdog subshell sleeps <secs>, then TERMs the command AND its
# descendants — collected BEFORE the TERM, while they are still attached: a grandchild left alive
# keeps the caller's `$(...)` pipe open, and the substitution would wait for it however dead its
# parent is — gives them up to KILL_GRACE seconds, and KILLs whatever is left. The watchdog's own
# stdio is /dev/null for the same pipe reason (the driver's deadline watchdog does the same). A
# command that finishes first takes the watchdog down WITH its pending sleep — the watchdog's own tree,
# killed as a whole (killing the subshell alone would reparent the sleep and leave it idling out the
# budget), with a TERM trap inside it as a second line for a host where ps cannot be read. Status: the
# command's own, or 124 — GNU timeout's status for a budget that fired, so callers read one contract
# (a TERM or KILL death at or past <secs> is the watchdog's; one before it is not, and keeps its own).
_pf_run_bounded() {
  local secs="$1" cmd wd rc t0
  shift
  t0=$SECONDS
  "$@" < /dev/null &
  cmd=$!
  (
    s=""
    trap '[ -z "$s" ] || kill "$s" 2>/dev/null; exit 0' TERM
    sleep "$secs" & s=$!; wait "$s"; s=""
    tree="$(_pf_tree "$cmd")"
    # shellcheck disable=SC2086  # one pid per word, by design
    kill -TERM $tree 2>/dev/null
    i=0
    while [ "$i" -lt "$KILL_GRACE" ]; do
      alive=""
      for p in $tree; do kill -0 "$p" 2>/dev/null && alive=1; done
      [ -n "$alive" ] || exit 1
      sleep 1 & s=$!; wait "$s"; s=""
      i=$((i + 1))
    done
    # shellcheck disable=SC2086  # one pid per word, by design
    kill -KILL $tree 2>/dev/null
    exit 1
  ) < /dev/null > /dev/null 2>&1 &
  wd=$!
  wait "$cmd"; rc=$?
  if { [ "$rc" -eq 143 ] || [ "$rc" -eq 137 ]; } && [ $((SECONDS - t0)) -ge "$secs" ]; then
    wait "$wd" 2>/dev/null   # the watchdog fired: let it finish its reap (bounded by KILL_GRACE)
    echo "stopped after ${secs}s by reviewer-preflight's own watchdog (no GNU timeout on PATH — brew install coreutils)" >&2
    return 124
  fi
  # shellcheck disable=SC2046  # one pid per word, by design
  kill -TERM $(_pf_tree "$wd") 2>/dev/null
  wait "$wd" 2>/dev/null
  return "$rc"
}

emit_and_exit() {
  # emit_and_exit <status> <provider> <exit-code> [route-output]
  #
  # REJECTED (adversarial pass 3, f2-10): `route` is passed through VERBATIM, including its own
  # `routing_status=` line, even on a degraded/contract-broken verdict where `preflight_status`
  # disagrees with it — deliberate, not a gap. No consumer in this repo reads `routing_status` off
  # preflight's stdout: both (skills/write-tests/SKILL.md:247, shared/includes/
  # test-reviewer-routing.md:39-43) act on `preflight_status` (the line above) and the exit code
  # only. Full reasoning at the verdict switch, section 4, where PF_ROUTE_CONTRACT_BROKEN decides
  # what `preflight_status` actually says.
  local status="$1" provider="$2" code="$3" route="${4:-}"
  printf 'preflight_status=%s\n' "$status"
  printf 'provider=%s\n' "$provider"
  if [ -n "$route" ]; then
    printf '%s\n' "$route"
  else
    printf 'platform=unknown\nwriter_model=unknown\nwriter_lane=unknown\n'
    printf 'reviewer_lane=same-model-fallback\nreviewer_model=unknown\nrouting_status=routing-failed\n'
  fi
  exit "$code"
}

# _pf_panel_err_signal <sig> — INT/TERM handler for the narrow window while the panel listing's
# stderr-capture temp file exists (F3): remove the file, restore <sig>'s OWN default disposition,
# then re-send <sig> to this process. Without the restore-and-re-raise, a caught TERM would just
# run the handler and leave preflight running past the signal it was told to die on — the trap
# must not swallow the kill, only make sure it does not leak a temp file on the way out.
_pf_panel_err_signal() {
  rm -f "${_pf_err_file:-}" 2>/dev/null
  trap - "$1"
  kill -s "$1" "$$"
}

# ── 0. the shared runner (sibling first, like the router and the driver) ───────
# The same lookup as theirs: <dir>/lib/ → <dir>/ → ~/.zuvo/, sibling candidates only when SCRIPT_DIR
# resolved (empty, they would be /lib/model-subprocess.sh and /model-subprocess.sh — files at the
# filesystem root, SOURCED here). A candidate LOADS only when it sources AND defines every function this
# file calls. The list is unset before each candidate, so what a half-loaded earlier one defined cannot
# pass for this one; a rejected candidate is WARNed by name. (Codex-host exclusion for the PANEL is
# the driver's own doing, through its own model-subprocess.sh copy — this script makes no candidate-
# filtering host check of its own, CQ14. zms_is_codex_host is loaded anyway: since adversarial pass 2
# (S1) it is also used, narrowly, by the routed-client same-vendor guard in section 1a below — a
# check on ROUTED_CLIENT, a value the ROUTER produced, never on the panel/CANDIDATES list. The
# source-lint in this script's test file pins that narrower scope.)
ZMS_LOADED=""
_pf_fns="zms_client_available zms_run_codex zms_run_claude zms_source_registry zms_is_auth_stub zms_client_for_model zms_is_codex_host zms_is_model_id zms_route_values_ok zms_is_writer_id"
_pf_cands=()
if [ -n "$SCRIPT_DIR" ]; then _pf_cands=("$SCRIPT_DIR/lib/model-subprocess.sh" "$SCRIPT_DIR/model-subprocess.sh"); fi
if [ -n "${HOME:-}" ]; then _pf_cands+=("$HOME/.zuvo/model-subprocess.sh"); fi
for _pf_lib in ${_pf_cands[@]+"${_pf_cands[@]}"}; do
  [ -f "$_pf_lib" ] || continue
  # shellcheck disable=SC2086  # one function name per word, by design
  unset -f $_pf_fns
  _pf_ok=0
  # shellcheck source=/dev/null
  if . "$_pf_lib"; then
    _pf_ok=1
    for _pf_fn in $_pf_fns; do declare -F "$_pf_fn" >/dev/null || _pf_ok=0; done
  fi
  if [ "$_pf_ok" -eq 1 ]; then ZMS_LOADED="$_pf_lib"; break; fi
  echo "reviewer-preflight: WARN: $_pf_lib exists but did not load the shared runner ($_pf_fns) — trying the next candidate" >&2
done
unset _pf_cands _pf_lib _pf_fns _pf_fn _pf_ok

# ── 1. routing ────────────────────────────────────────────────────────────────
ROUTE_OUT=""
ROUTING_STATUS="routing-failed"
if [ -x "$ROUTE_SCRIPT" ] || [ -f "$ROUTE_SCRIPT" ]; then
  ROUTE_OUT="$(run_with_timeout 5 bash "$ROUTE_SCRIPT" 2>/dev/null)" || ROUTE_OUT=""
fi
if [ -n "$ROUTE_OUT" ]; then
  # validate the strict 6-key single-line contract
  keys_ok=1
  # S4 (adversarial pass 2, F11 CLAUDE / F16 MUSE / F19 MUSE): collect the OFFENDING keys and
  # their actual counts as the loop runs, so the diagnostic below names a duplicate ("reviewer_
  # model=2") distinctly from a missing key ("writer_lane=0") — the plain total-line-count message
  # this replaced could not tell them apart (a duplicate paired with a compensating omission can
  # leave $n_lines at exactly 6, reading as "nothing wrong" even though two keys are each off by
  # one in opposite directions).
  _pf_bad_keys=""
  for key in platform writer_model writer_lane reviewer_lane reviewer_model routing_status; do
    n="$(printf '%s\n' "$ROUTE_OUT" | grep -c "^${key}=")" || n=0
    if [ "$n" -ne 1 ]; then
      keys_ok=0
      _pf_bad_keys="${_pf_bad_keys:+$_pf_bad_keys, }$key=$n"
    fi
  done
  # P4 (adversarial pass 3, f2-4): count ALL lines, blank ones included. `grep -c .` only counts
  # NON-empty lines, so a smuggled blank line (`a\n\nb`) never moved this count at all — a
  # well-formed 6-key block with one extra blank line inserted anywhere (7 physical lines) used to
  # read as "6 lines, nothing wrong" here. awk's NR counts every line record regardless of content.
  n_lines="$(printf '%s\n' "$ROUTE_OUT" | awk 'END{print NR}')" || n_lines=0
  [ "$n_lines" -eq 6 ] || keys_ok=0
  # P4 (f2-11): reject a CR or any other non-printable byte anywhere in the block. A field no OTHER
  # check in this script re-validates (writer_lane, reviewer_lane — unlike platform= and
  # reviewer_model=, which the S1/Q2 checks below happen to re-check independently) could otherwise
  # carry a trailing `\r` or a stray control byte straight through to routing_status=ok undetected.
  # Checked under the C locale so a multi-byte UTF-8 sequence also trips it (each of its
  # continuation bytes falls outside the printable-ASCII-plus-newline range `[ -~\n]`).
  _pf_nonprintable=0
  if printf '%s' "$ROUTE_OUT" | LC_ALL=C awk '/[^ -~\n]/{f=1} END{exit(f?0:1)}'; then
    keys_ok=0
    _pf_nonprintable=1
  fi
  if [ "$keys_ok" -eq 1 ]; then
    ROUTING_STATUS="$(printf '%s\n' "$ROUTE_OUT" | sed -n 's/^routing_status=//p')"
  else
    _pf_issue_note=""
    if [ -n "$_pf_bad_keys" ]; then _pf_issue_note="per-key counts off: $_pf_bad_keys"; fi
    if [ "$_pf_nonprintable" -eq 1 ]; then
      _pf_issue_note="${_pf_issue_note:+$_pf_issue_note; }a non-printable byte (CR or control char) was found"
    fi
    echo "reviewer-preflight: reviewer-model-route.sh output failed the six-key contract (want exactly one line per key, 6 lines total, printable ASCII only; got $n_lines lines${_pf_issue_note:+, $_pf_issue_note}) — routing failed closed" >&2
    ROUTE_OUT=""
  fi
  unset _pf_bad_keys _pf_nonprintable _pf_issue_note
fi

if [ -z "$ZMS_LOADED" ]; then
  echo "reviewer-preflight: model-subprocess.sh (the shared reviewer runner) not loaded from next to this script ($SCRIPT_DIR/lib, $SCRIPT_DIR) or from ~/.zuvo — no reviewer can be checked the way the runners resolve it, nor canaried in isolation; failing closed (no-provider). Fix: ./scripts/install.sh" >&2
  emit_and_exit "no-provider" "none" 1 "$ROUTE_OUT"
fi

# The routed model must be ONE reviewer id (zms_is_model_id, the router's own grammar, from
# scripts/lib/model-subprocess.sh) before it is handed to zms_client_for_model, whose own `gpt-*` /
# `claude-*` globs would otherwise happily match a metacharacter payload trailing a valid prefix.

# ── 1a. the routed client (plan C Task 6, hardened after adversarial pass 1 — Q1/Q2/Q3) — tried
# BEFORE the panel candidates below, but ONLY when the router genuinely resolved a cross-vendor
# reviewer (routing_status=ok). Any OTHER status can still name a same-VENDOR reviewer — the
# in-family fallback table (Claude opus<->sonnet, the registry's Codex primary<->review-alt pair)
# reviews a Claude writer with another Claude model, a Codex writer with another Codex model — and
# that client is the host's OWN vendor, exactly what the driver's blind-audit panel already
# excludes to prevent self-review (host-vendor exclusion, section 2 below). Inserting it here on a
# non-ok status would reopen that hole. The client is derived from the reviewer model the SAME way
# the router derives it (zms_client_for_model) — never a second mapping that could drift from the
# router's own.
#
# The gap the router's own comment ASSUMES away (F11 CLAUDE / F13 MUSE / F12, CRITICAL): the
# router and the panel driver are independent code paths that can disagree about what "this
# host's own vendor" means, or about anything else that would keep a client off the panel (the
# isolation allowlist, an argv/settings drop). Investigated (Q1) before deciding: `provider=` has
# exactly two consumers in this repo (skills/write-tests/SKILL.md, shared/includes/
# test-reviewer-routing.md) and BOTH invoke this script only for its exit code / preflight_status
# — neither one parses `provider=` as a blind-audit panel lane (grep confirms no `field provider`-
# style read anywhere outside this script's own test file). So the decision rule's third branch
# applies: no consumer depends on `provider=` naming a panel-eligible client, and the routed
# client IS the reviewer `model-run --route` (Tasks 5/8) really uses — canarying it first, even
# when the panel would not have offered it, is the plan's own intent (X2). The prepend stays a
# UNION with the panel, not an intersection.
#
# What's added as defense in depth regardless of that decision (the "Either way" items): a
# same-vendor guard below (never trust "ok" alone to mean cross-vendor), and PF_ROUTE_CONTRACT_
# BROKEN, which downgrades the final verdict to degraded-routing whenever "ok" cannot actually be
# honoured (Q2/Q3) — an ok route that names a broken/unmapped/same-vendor reviewer is a contract
# violation, never a silent pass-through that still reports preflight_status=ok while nothing
# named by the route was ever canaried.
ROUTED_CLIENT=""
PF_ROUTED_MODEL=""
PF_ROUTE_CONTRACT_BROKEN=0
# S3 (adversarial pass 2, F14 CLAUDE / F17 MUSE): "routing_status=ok with an empty ROUTE_OUT" is
# IMPOSSIBLE by construction, not by convention — proof: ROUTING_STATUS is reassigned from its
# "routing-failed" default in EXACTLY one place, the `if [ "$keys_ok" -eq 1 ]` arm a few lines up,
# which reads it FROM $ROUTE_OUT — and that arm's sibling (`else`) is the ONLY place that clears
# $ROUTE_OUT, which does NOT touch $ROUTING_STATUS. So the two either both hold their pre-parse
# values (ROUTE_OUT="", ROUTING_STATUS="routing-failed") or both hold post-parse values
# (ROUTE_OUT = the validated 6-line block, ROUTING_STATUS = read from it) — never a "ok" from one
# paired with an empty from the other. Asserted anyway, defensively: a future refactor that broke
# this pairing would otherwise silently skip every Q1-Q3 check below and let the verdict switch
# emit preflight_status=ok with nothing ever routed or canaried.
if [ "$ROUTING_STATUS" = "ok" ] && [ -z "$ROUTE_OUT" ]; then
  echo "reviewer-preflight: INTERNAL: routing_status=ok with an empty ROUTE_OUT — this pairing is meant to be impossible by construction (see the comment above this check); degrading defensively" >&2
  PF_ROUTE_CONTRACT_BROKEN=1
fi
if [ "$ROUTING_STATUS" = "ok" ] && [ -n "$ROUTE_OUT" ]; then
  # Q2 (F2/F8/F15/F6): exactly ONE reviewer_model= value — the first match, `q`uit right after —
  # never every matching line. Honestly: this is NOT a second, independently-exercised line of
  # defense today. Mutation testing (quality review iter 3, M14: dropping `;q;` here) survived
  # every test in this suite, because the six-key gate above (~:319-341) already requires exactly
  # one reviewer_model= line before ROUTING_STATUS can ever read "ok" — a duplicate never reaches
  # this line with routing_status=ok at all, so no test can exercise the `;q;` without first
  # bypassing that gate. It stays anyway as a belt: cheap insurance for the day the six-key gate's
  # own guarantee changes (loosens, moves, or is refactored away), not proof of a defense actually
  # exercised now.
  _pf_routed_model="$(printf '%s\n' "$ROUTE_OUT" | sed -n '/^reviewer_model=/{s/^reviewer_model=//;p;q;}')"
  if [ -n "$_pf_routed_model" ] && ! zms_is_model_id "$_pf_routed_model"; then
    echo "reviewer-preflight: routing_status=ok but reviewer_model is not a single valid model id ($(printf '%q' "$_pf_routed_model")) — the six-key contract is violated; degrading" >&2
    _pf_routed_model=""
    PF_ROUTE_CONTRACT_BROKEN=1
  fi
  # Q3 (F3/F7/F10/F14/F1/F9): routing_status=ok REQUIRES a usable reviewer_model — an "ok" route
  # with none (empty, or the charset reject above) is a contract violation, never a silent
  # fall-through to plain panel order while still reporting preflight_status=ok.
  #
  # P5 (adversarial pass 3, f2-15): every independent violation below prints its OWN line —
  # none of these diagnostics is gated on `PF_ROUTE_CONTRACT_BROKEN -eq 0` any more. Each `if` here
  # runs at most once regardless (no loop), so dropping that guard cannot double-print a single
  # violation; what it fixes is a SECOND, DIFFERENT violation (e.g. reviewer_model empty AND
  # platform malformed, on the same broken route) being silently swallowed because an earlier one
  # already flipped the flag — a caller diagnosing one problem, fixing it, and hitting the OTHER
  # one it was never told about.
  if [ -z "$_pf_routed_model" ]; then
    echo "reviewer-preflight: routing_status=ok but reviewer_model is empty — the six-key contract is violated; degrading" >&2
    PF_ROUTE_CONTRACT_BROKEN=1
  else
    ROUTED_CLIENT="$(zms_client_for_model "$_pf_routed_model" 2>/dev/null)" || ROUTED_CLIENT=""
    if [ -z "$ROUTED_CLIENT" ]; then
      echo "reviewer-preflight: routing_status=ok but no client serves reviewer_model=$_pf_routed_model (zms_client_for_model) — degrading" >&2
      PF_ROUTE_CONTRACT_BROKEN=1
    elif [ "$ROUTED_CLIENT" != codex ] && [ "$ROUTED_CLIENT" != claude ]; then
      # S2 (adversarial pass 2, F10 BYTEPLUS): never trust the Q4 dedup-spelling agreement (section
      # 2 below) to hold forever — a future zms_client_for_model returning anything but these two
      # literals is a contract violation on ITS OWN, caught here before it can ever reach the
      # dedup/prepend logic, not assumed compatible with it.
      echo "reviewer-preflight: routing_status=ok but zms_client_for_model mapped reviewer_model=$_pf_routed_model to $(printf '%q' "$ROUTED_CLIENT"), not codex or claude — degrading" >&2
      ROUTED_CLIENT=""
      PF_ROUTE_CONTRACT_BROKEN=1
    else
      # P3 (adversarial pass 3, f2-7 CLAUDE): the canary loop (section 3) will use THIS exact
      # model — the one the route actually named — for the routed client's own attempt, instead of
      # the panel's generic registry model. Kept alive past this block (never unset below) so it
      # survives to section 3; cleared alongside ROUTED_CLIENT by the P1 blanket-clear if ANY later
      # check in this block still finds a violation.
      PF_ROUTED_MODEL="$_pf_routed_model"
    fi
  fi
  # S1 platform validation (adversarial pass 2, F1/F8/F9/F12/F15/F2): routing_status=ok promises a
  # Claude/Codex cross-vendor route (route_vendor_host in reviewer-model-route.sh only ever reports
  # "ok" for platform claude or codex) — a platform value that is empty, wrong case, padded with
  # whitespace, or any other token is ALREADY a broken contract, independent of whatever
  # reviewer_model/ROUTED_CLIENT ended up being. Exact-match only (no trim/case-fold): a route that
  # cannot even spell its own platform correctly is not a route to patch up and accept. Kept alive
  # (not unset here) — P2 below reuses the validated value.
  _pf_platform="$(printf '%s\n' "$ROUTE_OUT" | sed -n '/^platform=/{s/^platform=//;p;q;}')"
  case "$_pf_platform" in
    claude|codex) : ;;
    *)
      echo "reviewer-preflight: routing_status=ok but platform is not claude or codex ($(printf '%q' "$_pf_platform")) — the six-key contract is violated; degrading" >&2
      PF_ROUTE_CONTRACT_BROKEN=1
      ;;
  esac
  # The rest of the answer, through the ONE value check model-run applies (zms_route_values_ok): the
  # router's enums for writer_lane / reviewer_lane / routing_status and the id shapes of writer_model /
  # reviewer_model. Without it an `ok` answer with an empty or out-of-enum writer_lane or reviewer_lane
  # — values nothing above re-reads — passed here while model-run refused the same answer as malformed.
  # Its own line, like every check in this block (P5): the specific messages above stay as they are.
  _pf_v() { printf '%s\n' "$ROUTE_OUT" | sed -n "/^$1=/{s/^$1=//;p;q;}"; }
  if ! zms_route_values_ok "$(_pf_v platform)" "$(_pf_v writer_model)" "$(_pf_v writer_lane)" \
         "$(_pf_v reviewer_lane)" "$(_pf_v reviewer_model)" "$(_pf_v routing_status)"; then
    echo "reviewer-preflight: routing_status=ok but a value is empty or outside its contract (enum, id or writer-id shape) — the check model-run applies; degrading" >&2
    PF_ROUTE_CONTRACT_BROKEN=1
  fi
  unset -f _pf_v
  # Q1/S1/P2 same-vendor guard (defense in depth; the router's "ok" should already guarantee
  # cross-vendor — route_vendor_host only reports ok when the OTHER vendor's CLI is available).
  # P2 (adversarial pass 3, f2-1 / f2-8 MUSE CRITICAL / f2-14): the OLD guard fired only when a
  # HOST signal was independently detected (CLAUDECODE / zms_is_codex_host) — it failed OPEN with
  # no host signals at all (a router running somewhere neither is set, or a test/stub harness).
  # Now ROUTED_CLIENT is also compared against the route's OWN `platform=` — by the time this runs
  # it is guaranteed to be exactly `claude` or `codex` (the S1 check just above; a malformed value
  # already set PF_ROUTE_CONTRACT_BROKEN=1 and never reaches a false "match" here since neither
  # branch of the OR below can equal a value that isn't literally claude/codex). A client naming
  # ITS OWN platform is never a cross-vendor reviewer, independent of whether a host signal is
  # present: the router's "ok" promises the OTHER vendor, so `reviewer_model` resolving to the
  # SAME vendor as the writer breaks the contract on its own, host signals or not. The host-vendor
  # half stays too (defense in depth — a router that lies about `platform=` while still routing to
  # THIS host's real vendor, F1 CURSOR CRITICAL from pass 2, is still caught independently).
  if [ -n "$ROUTED_CLIENT" ]; then
    _pf_host_vendor=""
    if [ "${CLAUDECODE:-}" = "1" ]; then
      _pf_host_vendor="claude"
    elif zms_is_codex_host; then
      _pf_host_vendor="codex"
    fi
    if { [ -n "$_pf_host_vendor" ] && [ "$ROUTED_CLIENT" = "$_pf_host_vendor" ]; } \
       || [ "$ROUTED_CLIENT" = "$_pf_platform" ]; then
      echo "reviewer-preflight: routing_status=ok named $ROUTED_CLIENT as the reviewer, but that is the WRITER's own vendor (platform=$_pf_platform${_pf_host_vendor:+, host independently detected as $_pf_host_vendor}) — same vendor, not cross-vendor; degrading" >&2
      ROUTED_CLIENT=""
      PF_ROUTE_CONTRACT_BROKEN=1
    fi
    unset _pf_host_vendor
  fi
  unset _pf_platform
  # P1 (adversarial pass 3, f2-3 / f2-9): ONE rule, applied in ONE place after every check above —
  # a broken "ok" route NEVER prepends a client. Every individual violation above (empty/invalid
  # reviewer_model, an unmapped or non-codex/claude client, a malformed platform=, same-vendor)
  # already sets PF_ROUTE_CONTRACT_BROKEN=1, but several of them (platform=, the host-vendor guard)
  # used to run AFTER ROUTED_CLIENT was already set from an EARLIER, successful check — leaving it
  # non-empty even though the route as a WHOLE was invalid, so it still got prepended and canaried
  # first. This is the single, final gate: nothing downstream ever sees a ROUTED_CLIENT/
  # PF_ROUTED_MODEL pair that survived any violation.
  if [ "$PF_ROUTE_CONTRACT_BROKEN" -eq 1 ]; then
    ROUTED_CLIENT=""
    PF_ROUTED_MODEL=""
  fi
  unset _pf_routed_model
fi

# ── 2. audit client availability (candidates = the driver's blind-audit panel) ─
# Preflight keeps no exclusion logic of its own (CQ14 — one exclusion implementation): the
# driver's own `--list-providers --mode blind-audit` already applies vendor host exclusion
# (a Codex host drops codex-5.3/5.4, a Claude host drops claude, an Antigravity host drops
# agy+gemini, a Cursor host drops cursor-agent, …), the isolation allowlist that decides
# which lanes a blind audit may EVER run (bap_allowlist — it can only NARROW, never widen:
# cursor-agent and gemini are not on it, so they can never be candidates here, no matter what
# this script's own host-detection used to think), and the argv/agy-settings drops — then
# prints the post-exclusion list, one lane per line, exit 0. A second, hand-written exclusion
# list here could silently drift from what the blind audit actually dispatches: X2 exists to
# close exactly that drift (the old inline fallback list here once named `gemini`, dead at the
# account level, and knew nothing about cursor-agent, kimi or the Codex.app fallback the driver
# already handles).
#
# Driver lookup: sibling first, like ROUTE_SCRIPT and the shared runner above — the repo, every
# Claude-Code cache dir, ~/.codex/scripts and ~/.cursor/scripts all keep adversarial-review.sh as
# this file's `.sh` sibling (scripts/install.sh). ~/.zuvo/adversarial-review (no `.sh` —
# install.sh renames it there when it installs scripts/zuvo-home/*, alongside its own
# ~/.zuvo/lib/blind-audit-panel.sh) is the fallback candidate, so the lookup works whether this
# script is sitting in the repo/cache/host-scripts layout or on its own next to nothing.
ADV_CANDS=()
if [ -n "$SCRIPT_DIR" ]; then ADV_CANDS+=("$SCRIPT_DIR/adversarial-review.sh"); fi
if [ -n "${HOME:-}" ]; then ADV_CANDS+=("$HOME/.zuvo/adversarial-review"); fi
ADV=""
for _pf_adv in ${ADV_CANDS[@]+"${ADV_CANDS[@]}"}; do
  if [ -f "$_pf_adv" ]; then ADV="$_pf_adv"; break; fi
done
unset _pf_adv ADV_CANDS

if [ -z "$ADV" ]; then
  echo "reviewer-preflight: adversarial-review(.sh) — the panel driver whose --list-providers --mode blind-audit is this script's ONLY source of candidates — not found next to this script ($SCRIPT_DIR) or at ~/.zuvo/adversarial-review; failing closed (no-provider), never a private fallback list. Fix: ./scripts/install.sh" >&2
  emit_and_exit "no-provider" "none" 1 "$ROUTE_OUT"
fi

PANEL_OUT=""
PANEL_RC=0
# The driver's stderr is captured to a file, not discarded: on a listing failure its first
# NON-EMPTY line (F4 — a driver whose stderr opens with a blank line must not fall back to the
# generic message; awk's NF is false on a blank OR whitespace-only line, so both are skipped, and
# the `|| :` after it means a read failure never aborts preflight under `set -uo pipefail`) goes
# straight into the fail-closed message below via `printf '%s\n'`, never `echo` (F5 — echo can
# reinterpret a backslash in the driver's own text under xpg_echo/posix mode; printf's `%s` never
# reinterprets its argument), so the operator does not have to re-run the driver by hand to learn
# why. A mktemp failure degrades to the old discard-and-generic-message behaviour rather than
# aborting preflight over a diagnostics nicety.
#
# F3: the listing can run up to 20s (run_with_timeout below) — a kill during that window must not
# leak this temp file. EXIT/INT/TERM are trapped for exactly this window: armed right before the
# listing runs, disarmed (and whatever trap was already registered for each signal restored) right
# after the file is removed below, so the LATER `trap 'rm -rf "$WORK"' EXIT` (the canary work dir)
# is never clobbered by a stale handler left over from here.
PANEL_ERR_LINE=""
if _pf_err_file="$(mktemp "${TMPDIR:-/tmp}/zuvo-preflight-panel-err.XXXXXX" 2>/dev/null)" && [ -n "$_pf_err_file" ]; then
  _pf_prev_trap_exit="$(trap -p EXIT)"
  _pf_prev_trap_int="$(trap -p INT)"
  _pf_prev_trap_term="$(trap -p TERM)"
  trap 'rm -f "${_pf_err_file:-}" 2>/dev/null' EXIT
  trap '_pf_panel_err_signal INT' INT
  trap '_pf_panel_err_signal TERM' TERM
  PANEL_OUT="$(run_with_timeout "$PANEL_LIST_TIMEOUT" bash "$ADV" --list-providers --mode blind-audit 2>"$_pf_err_file")" || PANEL_RC=$?
  PANEL_ERR_LINE="$(awk 'NF { print; exit }' "$_pf_err_file" 2>/dev/null)" || PANEL_ERR_LINE=""
  rm -f "$_pf_err_file"
  trap - EXIT INT TERM
  eval "${_pf_prev_trap_exit:-:}"
  eval "${_pf_prev_trap_int:-:}"
  eval "${_pf_prev_trap_term:-:}"
  unset _pf_prev_trap_exit _pf_prev_trap_int _pf_prev_trap_term
else
  PANEL_OUT="$(run_with_timeout "$PANEL_LIST_TIMEOUT" bash "$ADV" --list-providers --mode blind-audit 2>/dev/null)" || PANEL_RC=$?
fi
unset _pf_err_file
if [ "$PANEL_RC" -ne 0 ]; then
  if [ -n "$PANEL_ERR_LINE" ]; then
    printf '%s\n' "reviewer-preflight: $ADV --list-providers --mode blind-audit exited $PANEL_RC: $PANEL_ERR_LINE — the panel candidate list could not be computed; failing closed (no-provider)." >&2
  else
    echo "reviewer-preflight: $ADV --list-providers --mode blind-audit exited $PANEL_RC — the panel candidate list could not be computed; failing closed (no-provider)." >&2
  fi
  emit_and_exit "no-provider" "none" 1 "$ROUTE_OUT"
fi

# pf_map_lane <driver-lane> — the driver's panel lane name to THIS script's client/canary name.
# Only codex's model tiers collapse: one CLI answers to every codex-5 tier, and one canary per
# client is the budget (dedup below). A tier is `codex-5` followed by any number of `.<digits>`
# segments and nothing else:
#   * a pattern, not an enumerated pair (ADV-A87), so a future codex-5.5+ tier still collapses
#     instead of silently losing its canary;
#   * the minor tier is OPTIONAL (P2-39) — the old `codex-5.*` glob needed a literal `.`, so a bare
#     `codex-5` lane id fell through unmapped and read as a missing provider;
#   * as many numeric segments as a tier id carries (P3C-7) — `codex-5.4.1` is the same CLI; the
#     one-optional-segment form it replaces passed a three-part tier through unmapped, where the old
#     glob had collapsed it;
#   * every segment DIGITS ONLY, anchored at the end (P2-35) — the glob's `*` also swallowed a
#     suffixed lane (a future codex-5.4-api / -alt), a different execution path that must keep its
#     own name exactly as kimi-api does.
# Every other lane passes through unchanged — kimi-api in particular must NOT collapse into `kimi`:
# it is a curl fallback (MOONSHOT_API_KEY), a different execution path from the kimi CLI, and
# folding the two together would let an available kimi CLI wrongly vouch for a candidate the
# driver picked as kimi-api.
pf_map_lane() {
  local _pf_codex_tier='^codex-5(\.[0-9]+)*$'
  if [[ "$1" =~ $_pf_codex_tier ]]; then
    printf 'codex\n'
  else
    printf '%s\n' "$1"
  fi
}

# Map + dedup, in the driver's order — into a bash ARRAY, never a space-joined string. A lane
# name is never expected to hold a space or a glob character, but if the driver ever printed one
# (a bug there, a future lane with a stray character), `for x in $PANEL_OUT` / `for x in
# $DETECTED` would silently word-split or glob-expand it against files in $PWD — a plain
# `while IFS= read -r` loop over the driver's newline-delimited output, and a quoted array from
# there on, cannot. Lanes the panel can include that this script has no canary for (kimi-api,
# qwen, codestral, openrouter*, byteplus* — several of them HTTP/API-key lanes with no CLI to
# bound and run) still pass through zms_client_available like any other name; none of them
# resolve to a binary on PATH, so they simply never become a CANDIDATE, and if one ever did, the
# canary loop's own "no canary is defined for this client" arm already handles it — nothing new
# needed to keep behaviour for the clients this script already canaries (codex, claude, agy, kimi).
#
# F6: each line is cleaned up BEFORE pf_map_lane — a trailing CR (a CRLF-terminated listing, e.g.
# from a driver invoked through a tool that normalizes line endings) is stripped first (works on
# bash 3.2, no external command), then surrounding blanks are trimmed and a whitespace-only line is
# skipped, same as an empty one: incidental padding around a real lane name must not turn into a
# distinct, non-matching "candidate" that then silently fails availability instead of being read as
# the lane it plainly is.
DETECTED=()
while IFS= read -r _pf_lane || [ -n "$_pf_lane" ]; do
  _pf_lane="${_pf_lane%$'\r'}"
  _pf_lane="${_pf_lane#"${_pf_lane%%[![:space:]]*}"}"
  _pf_lane="${_pf_lane%"${_pf_lane##*[![:space:]]}"}"
  [ -n "$_pf_lane" ] || continue
  _pf_client="$(pf_map_lane "$_pf_lane")"
  _pf_dup=0
  for _pf_seen in ${DETECTED[@]+"${DETECTED[@]}"}; do
    [ "$_pf_seen" = "$_pf_client" ] && { _pf_dup=1; break; }
  done
  [ "$_pf_dup" -eq 1 ] || DETECTED+=("$_pf_client")
done <<< "$PANEL_OUT"
unset _pf_lane _pf_client _pf_dup _pf_seen PANEL_OUT PANEL_RC PANEL_ERR_LINE

# Plan C Task 6: the routed client goes AHEAD of the panel's own order — prepended, not appended,
# so it is the first element the availability/dedup loop below sees regardless of where (or
# whether) the panel itself lists it. The dedup loop below is unchanged: it skips any later
# occurrence of the same name once a candidate has been added to CANDIDATES, so a routed client
# that is ALSO on the panel (the normal case — cross-vendor always names the OTHER vendor, which
# the panel already includes) is still canaried exactly once, never twice.
#
# Q4 (adversarial pass 1, F16 MUSE): that dedup only holds if ROUTED_CLIENT and a panel-derived
# DETECTED entry spell the SAME vendor the SAME way. Verified, not assumed: zms_client_for_model
# (scripts/lib/model-subprocess.sh) returns exactly the literal `codex` or `claude` — its only two
# non-failing arms (`gpt-*|o[0-9]*|codex-*` -> codex; `claude-*|opus*|sonnet*|haiku*` -> claude; it
# never names agy/cursor-agent/kimi, since cross-vendor routing only ever targets Claude or Codex,
# never a third vendor). pf_map_lane above folds every `codex-5(\.[0-9]+)*` panel lane to that same
# literal `codex` and passes `claude` through UNCHANGED — token-for-token identical to what
# zms_client_for_model returns. The two already agree; no canonicalization needed.
if [ -n "$ROUTED_CLIENT" ]; then
  DETECTED=("$ROUTED_CLIENT" ${DETECTED[@]+"${DETECTED[@]}"})
fi

# Availability is the runner's own answer, never a second `command -v`: that one missed a client
# pinned by ZUVO_CODEX_BIN / ZUVO_CLAUDE_BIN off the PATH (or only in Codex.app) and, worse,
# accepted a codex on PATH that ZUVO_CODEX_BIN=/nonexistent had switched off. Same array
# discipline as DETECTED above — quoted expansion only, no word-splitting on a candidate name.
CANDIDATES=()
for candidate in ${DETECTED[@]+"${DETECTED[@]}"}; do
  _pf_dup=0
  for _pf_seen in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
    [ "$_pf_seen" = "$candidate" ] && { _pf_dup=1; break; }
  done
  [ "$_pf_dup" -eq 1 ] && continue
  zms_client_available "$candidate" 2>/dev/null && CANDIDATES+=("$candidate")
done
unset _pf_dup _pf_seen

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  emit_and_exit "no-provider" "none" 1 "$ROUTE_OUT"
fi
PROVIDER="${CANDIDATES[0]}"

# ── 3. optional canary round-trip ─────────────────────────────────────────────
# reply_has_answer <file> — true when some line of the reply, once CR, surrounding blanks, markdown
# emphasis/backticks and a trailing period are trimmed, reads exactly 42. Only the client's STDOUT is
# ever checked: codex writes the prompt back on stderr ("user\n<prompt>") by design.
reply_has_answer() {
  awk '{ gsub(/\r/, ""); sub(/^[[:space:]*_`]+/, ""); sub(/[[:space:]*_`.]+$/, "")
         if ($0 == "42") found = 1 }
       END { exit(found ? 0 : 1) }' "$1" 2>/dev/null
}

# run_neutral <out> <err> <in> <client> [args...] — a client the shared runner does not cover, started
# from the neutral temp cwd (OLDPWD pointed there too, so the caller's repository is not handed over
# through it), stdin from <in> — /dev/null unless the client takes its prompt there — and bounded by
# GNU timeout with a KILL after the grace. Never the caller's stdin: under timeout the client leads its
# own process group, so reading an inherited terminal stops it (SIGTTIN) until the budget ends, and an
# inherited pipe hands it the caller's input. The client is resolved to an absolute path BEFORE the cd,
# as zms_client_available resolved it. Only called with GNU timeout present (the canary loop checks).
# Status: the client's own, 124/137 timed out, 127 not found.
run_neutral() {
  local out="$1" err="$2" in="$3" bin
  shift 3
  bin="$(type -P "$1")" || return 127
  case "$bin" in /*) ;; *) bin="$PWD/$bin" ;; esac
  shift
  ( cd "$NEUTRAL_CWD" || exit 2
    export OLDPWD="$NEUTRAL_CWD"
    exec "$TIMEOUT_BIN" -k "$KILL_GRACE" "$TIMEOUT_SECONDS" "$bin" "$@" ) < "$in" > "$out" 2> "$err"
}

# canary_failed_note <client> <status> <out> <err> — one stderr line saying why a canary did not pass.
# Never the client's output itself: its stderr can carry account details.
canary_failed_note() {
  local why
  case "$2" in
    124|137) why="timed out after ${TIMEOUT_SECONDS}s" ;;
    127)     why="client not found" ;;
    0)       why="exit 0, no line reading 42 in the reply" ;;
    *)       if reply_has_answer "$3"; then why="exit $2 — a 42 from a client that failed does not count"
             else why="exit $2, no line reading 42 in the reply"; fi ;;
  esac
  if zms_is_auth_stub "$3" || zms_is_auth_stub "$4"; then why="$why (the reply is an auth error — log the client in)"; fi
  echo "reviewer-preflight: canary $1 failed: $why" >&2
}

if [ "$CANARY" -eq 1 ]; then
  PROMPT="Reply with the product of 6 and 7, digits only."
  if ! WORK="$(mktemp -d "${TMPDIR:-/tmp}/zuvo-preflight.XXXXXX")" || [ -z "$WORK" ]; then
    echo "reviewer-preflight: cannot create a temp dir under ${TMPDIR:-/tmp} — no canary could run" >&2
    emit_and_exit "canary-failed" "$PROVIDER" 1 "$ROUTE_OUT"
  fi
  trap 'rm -rf "$WORK"' EXIT
  # Physical and absolute: the runners resolve relative paths themselves, run_neutral's cd does not.
  if _pf_abs="$(cd "$WORK" && pwd -P)" && [ -n "$_pf_abs" ]; then
    WORK="$_pf_abs"
  else
    echo "reviewer-preflight: cannot resolve the canary work dir $WORK" >&2
    emit_and_exit "canary-failed" "$PROVIDER" 1 "$ROUTE_OUT"
  fi
  unset _pf_abs
  NEUTRAL_CWD="$WORK/cwd"
  PROMPT_FILE="$WORK/prompt.txt"
  if ! { mkdir -p "$NEUTRAL_CWD" && printf '%s\n' "$PROMPT" > "$PROMPT_FILE"; }; then
    echo "reviewer-preflight: cannot prepare the canary work dir $WORK" >&2
    emit_and_exit "canary-failed" "$PROVIDER" 1 "$ROUTE_OUT"
  fi

  # Model ids come from the registry (sibling first, then ~/.zuvo), the same ones the blind audit
  # uses — a canary on another model would vouch for a call the audit never makes.
  zms_source_registry >/dev/null 2>&1 || :
  CODEX_CANARY_MODEL="${ZUVO_CODEX_MODEL:-${ZUVO_MODEL_CODEX_PRIMARY:-}}"
  CODEX_CANARY_EFFORT="${ZUVO_BLIND_AUDIT_EFFORT:-${ZUVO_CODEX_EFFORT_AUDIT:-}}"
  CLAUDE_CANARY_MODEL="${ZUVO_CLAUDE_AUDIT_MODEL:-${ZUVO_MODEL_CLAUDE_REVIEWER_OPUS:-}}"

  # Try EVERY available candidate, not just the first. A dead account on the
  # first client is not evidence that cross-model review is unavailable — a
  # client's status is account-level and changes without notice, so re-verify
  # it per run rather than assuming a prior measurement still holds. (`gemini`
  # can never actually reach this loop as a candidate: it is not on the
  # blind-audit isolation allowlist, so the driver excludes it long before
  # preflight ever sees it.) Stopping at the first failure is what turned "one
  # bad account" into a whole-run degrade.
  CANARY_OK=""
  n=0
  for cand in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
    n=$((n + 1))
    out="$WORK/out.$n"; err="$WORK/err.$n"; rc=0
    : > "$out"; : > "$err"
    # Every canary is bounded — codex/claude by the runner, the rest by run_neutral, both through GNU
    # timeout. Without it none is run: an unbounded canary is the hang this preflight exists to report,
    # not to reproduce. Checked here, per client, so each one is named rather than failing as "exit 2".
    if [ -z "$TIMEOUT_BIN" ]; then
      echo "reviewer-preflight: canary $cand not run: GNU timeout required (timeout or gtimeout on PATH; macOS: brew install coreutils)" >&2
      continue
    fi
    # P3 (adversarial pass 3, f2-7 CLAUDE): when THIS candidate is the routed one, canary it with
    # the model the route actually named (PF_ROUTED_MODEL, section 1a) — the task's own commit
    # promise is "check the reviewer the route will actually use", not a same-vendor-tier stand-in
    # from the registry. Every OTHER candidate (the panel's own order) keeps the generic registry
    # model, unchanged.
    _pf_codex_model="$CODEX_CANARY_MODEL"
    _pf_claude_model="$CLAUDE_CANARY_MODEL"
    if [ "$cand" = "$ROUTED_CLIENT" ] && [ -n "$PF_ROUTED_MODEL" ]; then
      case "$cand" in
        codex)  _pf_codex_model="$PF_ROUTED_MODEL" ;;
        claude) _pf_claude_model="$PF_ROUTED_MODEL" ;;
      esac
    fi
    case "$cand" in
      codex)
        if [ -z "$_pf_codex_model" ]; then
          echo "reviewer-preflight: canary codex not run: no model id (model-registry.sh not found and ZUVO_CODEX_MODEL unset)" >&2
          continue
        fi
        cargs=(--model "$_pf_codex_model" --access none --prompt-file "$PROMPT_FILE"
               --timeout "$TIMEOUT_SECONDS" --stderr-file "$err")
        if [ -n "$CODEX_CANARY_EFFORT" ]; then cargs+=(--effort "$CODEX_CANARY_EFFORT"); fi
        zms_run_codex "${cargs[@]}" > "$out" || rc=$?
        ;;
      claude)
        if [ -z "$_pf_claude_model" ]; then
          echo "reviewer-preflight: canary claude not run: no model id (model-registry.sh not found and ZUVO_CLAUDE_AUDIT_MODEL unset)" >&2
          continue
        fi
        zms_run_claude --model "$_pf_claude_model" --access none --prompt-file "$PROMPT_FILE" \
          --timeout "$TIMEOUT_SECONDS" --stderr-file "$err" > "$out" || rc=$?
        ;;
      gemini)
        # Kept for defense in depth, but currently unreachable: gemini is not on the driver's
        # blind-audit isolation allowlist (bap_allowlist), so it can never be a candidate here —
        # see pf_map_lane above. The prompt on stdin — and nothing else there.
        run_neutral "$out" "$err" "$PROMPT_FILE" gemini --allowed-mcp-server-names __NONE__ -p "" || rc=$?
        ;;
      agy)
        # prompt as an ARGUMENT, never stdin — piping stdin hangs this client
        # (documented at scripts/adversarial-review.sh, the agy dispatch block).
        run_neutral "$out" "$err" /dev/null agy -p "$PROMPT" || rc=$?
        ;;
      cursor-agent)
        # Kept for defense in depth, but currently unreachable: cursor-agent is not on the
        # driver's blind-audit isolation allowlist either — see pf_map_lane above.
        run_neutral "$out" "$err" /dev/null cursor-agent -p "$PROMPT" || rc=$?
        ;;
      kimi)
        run_neutral "$out" "$err" /dev/null kimi -p "$PROMPT" || rc=$?
        ;;
      *)
        echo "reviewer-preflight: canary $cand not run: no canary is defined for this client" >&2
        continue
        ;;
    esac
    # Both, or it did not pass: a client that printed 42 and then crashed, or hung until the timeout
    # killed it, is not a reviewer the blind audit can run — it would crash or hang there too.
    if [ "$rc" -eq 0 ] && reply_has_answer "$out"; then
      CANARY_OK="$cand"; PROVIDER="$cand"; break
    fi
    canary_failed_note "$cand" "$rc" "$out" "$err"
  done

  if [ -z "$CANARY_OK" ]; then
    emit_and_exit "canary-failed" "$PROVIDER" 1 "$ROUTE_OUT"
  fi
fi

# ── verdict ───────────────────────────────────────────────────────────────────
# Q2/Q3: routing_status=ok is not enough on its own any more — PF_ROUTE_CONTRACT_BROKEN (set in
# section 1a above) means the route named a reviewer that could not actually be resolved, mapped,
# or was the writer's own vendor. That is a contract violation, mapped the SAME way any other
# non-ok routing_status already is — never a silent "ok" for a route nothing downstream honoured.
#
# REJECTED (adversarial pass 2, F3/F21): on the degraded-on-contract-violation arm below, ROUTE_OUT
# is still passed through to emit_and_exit VERBATIM — including its own `routing_status=ok` line —
# even though `preflight_status` now reads degraded-routing. This is deliberate, not an oversight:
# passing ROUTE_OUT through unedited is the documented contract (this script never rewrites the
# router's own output), and `provider=`/`routing_status=` inside that block have exactly two
# consumers in this repo (skills/write-tests/SKILL.md:247, shared/includes/test-reviewer-routing.md
# :36), both of which act ONLY on `preflight_status` (the line ABOVE the passthrough) and the exit
# code — never on `routing_status` from inside the passthrough block. Rewriting the passthrough to
# "fix" a field no consumer reads would be a change with no reader, not a safety improvement.
case "$ROUTING_STATUS" in
  ok) if [ "$PF_ROUTE_CONTRACT_BROKEN" -eq 0 ]; then
        emit_and_exit "ok" "$PROVIDER" 0 "$ROUTE_OUT"
      else
        emit_and_exit "degraded-routing" "$PROVIDER" 0 "$ROUTE_OUT"
      fi ;;
  *)  emit_and_exit "degraded-routing" "$PROVIDER" 0 "$ROUTE_OUT" ;;
esac
