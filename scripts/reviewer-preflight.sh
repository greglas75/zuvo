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
#   1. routing   — reviewer-model-route.sh resolves the 6-key contract in <=5s (judged on its bytes
#                  by zms_route_contract_ok, the check model-run applies too). When it resolves
#                  routing_status=ok on a claude or codex platform (a cross-vendor route), the CLIENT
#                  that serves reviewer_model (zms_client_for_model, the same mapping the router
#                  itself uses) is probed FIRST in step 3 below, ahead of the panel's own order — that
#                  is the reviewer the pipeline will actually use. An ok from a cursor, kimi or
#                  antigravity host is the router's own answer and adds no candidate.
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

# The panel listing (`adversarial-review --list-providers --mode blind-audit`, no model call) is
# bounded at 20s by default and tunable, but always a BOUND: GNU timeout reads 0 as "no timeout at
# all". Digits only, leading zeros dropped, then 1..PANEL_LIST_TIMEOUT_MAX (six times the default —
# past that, "slow" is "broken"); anything else is refused before any listing runs.
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
# (_pf_run_bounded) when there is not — stock macOS ships none, and an unbounded listing let a wedged
# driver hang preflight. Either way a budget that fires is status 124. Model clients never go through
# here — see run_neutral (without GNU timeout they are not run at all).
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
  # emit_and_exit <status> <provider> <exit-code> [route-output] — `route` is passed through
  # VERBATIM, its own `routing_status=` line included, even where `preflight_status` disagrees with it:
  # this script never rewrites the router's answer, and its consumers (skills/write-tests/SKILL.md,
  # shared/includes/test-reviewer-routing.md) act on `preflight_status` and the exit code only.
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

# _pf_panel_err_signal <sig> — INT/TERM handler for the narrow windows while a temp file exists: the
# router's answer (section 1) or the panel listing's stderr capture. Remove the file, restore
# <sig>'s OWN default disposition, then re-send <sig> to this process. Without the restore-and-re-raise,
# a caught TERM would just run the handler and leave preflight running past the signal it was told to
# die on — the trap must not swallow the kill, only make sure it does not leak a temp file on the way out.
_pf_panel_err_signal() {
  rm -f "${_pf_err_file:-}" "${_pf_route_file:-}" 2>/dev/null
  trap - "$1"
  kill -s "$1" "$$"
}

# ── 0. the shared runner (sibling first, like the router and the driver) ───────
# Sibling candidates only when SCRIPT_DIR resolved (empty, they would be files at the filesystem root,
# SOURCED here). The panel's host exclusion is the driver's alone; zms_is_codex_host is used here only by
# the routed-client same-vendor guard (zms_route_same_vendor, section 1a), a check on a value the ROUTER
# produced — the source-lint in this script's test file pins that scope.
_zms_dir="$SCRIPT_DIR" _zms_repo="" _zms_who="reviewer-preflight: "
_zms_fns="zms_client_available zms_run_codex zms_run_claude zms_source_registry zms_is_auth_stub zms_client_for_model zms_is_model_id zms_is_writer_id zms_route_contract_ok zms_route_values_ok zms_route_same_vendor"
# zms-locate:begin — the ONE runner-lib candidate order, byte-identical in every consumer (the router,
# the preflight, model-run, the adversarial driver; tests/hooks/test-reviewer-preflight-isolation.sh
# compares the four): <dir>/lib/ → <dir>/ (flat) → <repo>/scripts/lib/ (model-run in a checkout) →
# ~/.zuvo/. Inputs _zms_dir and _zms_repo (empty: no such candidate), _zms_fns, _zms_who; output
# ZMS_LOADED. A candidate loads only when it sources AND defines every function in _zms_fns — unset
# before each try, so what a half-loaded earlier one defined cannot pass for it; a rejected one is named.
ZMS_LOADED=""
_zms_cands=()
if [ -n "$_zms_dir" ]; then _zms_cands=("$_zms_dir/lib/model-subprocess.sh" "$_zms_dir/model-subprocess.sh"); fi
if [ -n "$_zms_repo" ]; then _zms_cands+=("$_zms_repo/scripts/lib/model-subprocess.sh"); fi
if [ -n "${HOME:-}" ]; then _zms_cands+=("$HOME/.zuvo/model-subprocess.sh"); fi
for _zms_lib in ${_zms_cands[@]+"${_zms_cands[@]}"}; do
  [ -f "$_zms_lib" ] || continue
  # shellcheck disable=SC2086  # one function name per word, by design
  unset -f $_zms_fns
  _zms_ok=0
  # shellcheck source=/dev/null
  if . "$_zms_lib"; then
    _zms_ok=1
    for _zms_fn in $_zms_fns; do declare -F "$_zms_fn" >/dev/null || _zms_ok=0; done
  fi
  if [ "$_zms_ok" -eq 1 ]; then ZMS_LOADED="$_zms_lib"; break; fi
  printf '%sWARN: %s exists but did not load the shared runner (%s) — trying the next candidate\n' "$_zms_who" "$_zms_lib" "$_zms_fns" >&2
done
unset _zms_cands _zms_lib _zms_fn _zms_ok
# zms-locate:end
unset _zms_dir _zms_repo _zms_who _zms_fns

if [ -z "$ZMS_LOADED" ]; then
  echo "reviewer-preflight: model-subprocess.sh (the shared reviewer runner) not loaded from next to this script ($SCRIPT_DIR/lib, $SCRIPT_DIR) or from ~/.zuvo — no reviewer can be checked the way the runners resolve it, nor canaried in isolation; failing closed (no-provider). Fix: ./scripts/install.sh" >&2
  emit_and_exit "no-provider" "none" 1
fi

# ── 1. routing ────────────────────────────────────────────────────────────────
# The router's answer goes to a FILE and is judged on its bytes by zms_route_contract_ok — the check
# model-run applies too, so the two never disagree about a well-formed answer. A command substitution
# would drop trailing blank lines (and NULs) before any check could see them. An answer that fails the
# six-key gate, a router that cannot be run, or a temp file that cannot be made: routing failed closed,
# the fail-closed sentinel is passed through. The temp file lives only while the router runs (≤5 s);
# INT/TERM in that window remove it on the way out, as the panel listing's capture does below.
ROUTE_OUT=""
ROUTING_STATUS="routing-failed"
if [ -n "$ROUTE_SCRIPT" ] && [ -f "$ROUTE_SCRIPT" ]; then
  if _pf_route_file="$(mktemp "${TMPDIR:-/tmp}/zuvo-preflight-route.XXXXXX" 2>/dev/null)" && [ -n "$_pf_route_file" ]; then
    _pf_prev_trap_exit="$(trap -p EXIT)"
    _pf_prev_trap_int="$(trap -p INT)"
    _pf_prev_trap_term="$(trap -p TERM)"
    trap 'rm -f "${_pf_route_file:-}" 2>/dev/null' EXIT
    trap '_pf_panel_err_signal INT' INT
    trap '_pf_panel_err_signal TERM' TERM
    if run_with_timeout 5 bash "$ROUTE_SCRIPT" > "$_pf_route_file" 2>/dev/null; then
      if _pf_why="$(zms_route_contract_ok "$_pf_route_file")"; then
        ROUTE_OUT="$(cat "$_pf_route_file")" || ROUTE_OUT=""
        if [ -n "$ROUTE_OUT" ]; then ROUTING_STATUS="$(printf '%s\n' "$ROUTE_OUT" | sed -n 's/^routing_status=//p')"; fi
      else
        echo "reviewer-preflight: reviewer-model-route.sh output failed the six-key contract (want exactly one line per key, 6 lines total, no empty value, printable ASCII only, newline-terminated; $_pf_why) — routing failed closed" >&2
      fi
    fi
    rm -f "$_pf_route_file"
    trap - EXIT INT TERM
    eval "${_pf_prev_trap_exit:-:}"
    eval "${_pf_prev_trap_int:-:}"
    eval "${_pf_prev_trap_term:-:}"
    unset _pf_prev_trap_exit _pf_prev_trap_int _pf_prev_trap_term _pf_why
  else
    echo "reviewer-preflight: cannot create a temp file under ${TMPDIR:-/tmp} for the router's answer — routing failed closed" >&2
  fi
  unset _pf_route_file
fi

# ── 1a. the route's own contract, and the routed client ─────────────────────────
# routing_status=ok is judged by the route's platform:
#   claude / codex        a CROSS-VENDOR route. Its reviewer_model must be one id that a codex or claude
#                         CLI serves (zms_client_for_model, the router's own mapping) and never the
#                         writer's own vendor — the route's platform=, or the host vendor detected
#                         independently (CLAUDECODE / the Codex host signals). That client is canaried
#                         FIRST, ahead of the panel's order, with the routed model: it is the reviewer
#                         `model-run --route` really uses. The prepend is a UNION with the panel, not an
#                         intersection — `provider=`'s two consumers (skills/write-tests/SKILL.md,
#                         shared/includes/test-reviewer-routing.md) act only on preflight_status and the
#                         exit code, never on provider= as a panel lane.
#   cursor / kimi /       the ROUTER's own answer, accepted as it stands. Their
#   antigravity           reviewer is a cross-host client or an in-family model (agy, kimi-k2.6,
#                         gemini-3.1-pro-high) that no codex/claude CLI serves, so there is no routed client
#                         to put first; the panel canaries by its own order.
#   anything else         (empty, another case, padded, unknown) a broken contract.
# A broken ok route → preflight_status=degraded-routing, each violation on its own stderr line, and its
# client never goes first. Any other status never adds a candidate: the in-family fallback names a
# same-vendor model, which the panel already excludes as self-review.
ROUTED_CLIENT=""
PF_ROUTED_MODEL=""
PF_ROUTE_CONTRACT_BROKEN=0
# ROUTING_STATUS leaves "routing-failed" only in the arm above that also set ROUTE_OUT from the same
# validated answer, so "ok with no answer" cannot happen. Asserted anyway: a refactor that broke the
# pairing would otherwise skip every check below and report ok with nothing routed.
if [ "$ROUTING_STATUS" = "ok" ] && [ -z "$ROUTE_OUT" ]; then
  echo "reviewer-preflight: INTERNAL: routing_status=ok with an empty ROUTE_OUT — this pairing is meant to be impossible by construction (see the comment above this check); degrading defensively" >&2
  PF_ROUTE_CONTRACT_BROKEN=1
fi
if [ "$ROUTING_STATUS" = "ok" ] && [ -n "$ROUTE_OUT" ]; then
  # The six-key gate already guarantees exactly one line per key with a non-empty value; `q` reads the
  # first match all the same.
  _pf_routed_model="$(printf '%s\n' "$ROUTE_OUT" | sed -n '/^reviewer_model=/{s/^reviewer_model=//;p;q;}')"
  _pf_platform="$(printf '%s\n' "$ROUTE_OUT" | sed -n '/^platform=/{s/^platform=//;p;q;}')"
  # One id, on every platform: a value that fails this is never handed to zms_client_for_model, whose
  # `gpt-*` / `claude-*` globs would match a metacharacter payload after a valid-looking prefix.
  if [ -n "$_pf_routed_model" ] && ! zms_is_model_id "$_pf_routed_model"; then
    echo "reviewer-preflight: routing_status=ok but reviewer_model is not a single valid model id ($(printf '%q' "$_pf_routed_model")) — the six-key contract is violated; degrading" >&2
    _pf_routed_model=""
    PF_ROUTE_CONTRACT_BROKEN=1
  fi
  case "$_pf_platform" in
    claude|codex)
      if [ -z "$_pf_routed_model" ]; then
        # Reached when the id check above cleared it (the six-key gate refuses an empty value).
        echo "reviewer-preflight: routing_status=ok but reviewer_model is empty — the six-key contract is violated; degrading" >&2
        PF_ROUTE_CONTRACT_BROKEN=1
      else
        ROUTED_CLIENT="$(zms_client_for_model "$_pf_routed_model" 2>/dev/null)" || ROUTED_CLIENT=""
        if [ -z "$ROUTED_CLIENT" ]; then
          echo "reviewer-preflight: routing_status=ok but no client serves reviewer_model=$_pf_routed_model (zms_client_for_model) — degrading" >&2
          PF_ROUTE_CONTRACT_BROKEN=1
        elif [ "$ROUTED_CLIENT" != codex ] && [ "$ROUTED_CLIENT" != claude ]; then
          # The dedup against the panel (section 2) relies on these two literals; anything else is a
          # violation on its own, never assumed compatible.
          echo "reviewer-preflight: routing_status=ok but zms_client_for_model mapped reviewer_model=$_pf_routed_model to $(printf '%q' "$ROUTED_CLIENT"), not codex or claude — degrading" >&2
          ROUTED_CLIENT=""
          PF_ROUTE_CONTRACT_BROKEN=1
        else
          # The routed client's own canary (section 3) uses THIS model, not the registry's generic one.
          PF_ROUTED_MODEL="$_pf_routed_model"
        fi
      fi
      # `ok` promises the OTHER vendor: a client of the route's own platform, or of the host's vendor
      # (a router that lies about platform=), is never a cross-vendor reviewer.
      if [ -n "$ROUTED_CLIENT" ] && _pf_host_vendor="$(zms_route_same_vendor "$ROUTED_CLIENT" "$_pf_platform")"; then
        echo "reviewer-preflight: routing_status=ok named $ROUTED_CLIENT as the reviewer, but that is the WRITER's own vendor (platform=$_pf_platform${_pf_host_vendor:+, host independently detected as $_pf_host_vendor}) — same vendor, not cross-vendor; degrading" >&2
        PF_ROUTE_CONTRACT_BROKEN=1
      fi
      unset _pf_host_vendor
      ;;
    cursor|kimi|antigravity) : ;;
    *)
      echo "reviewer-preflight: routing_status=ok but platform is not claude or codex, nor a cursor, kimi or antigravity host ($(printf '%q' "$_pf_platform")) — the six-key contract is violated; degrading" >&2
      PF_ROUTE_CONTRACT_BROKEN=1
      ;;
  esac
  # The rest of the answer, through the ONE value check model-run applies (zms_route_values_ok): the
  # router's enums for writer_lane / reviewer_lane / routing_status and the id shapes of writer_model /
  # reviewer_model. Without it an `ok` answer with an out-of-enum writer_lane or reviewer_lane, or a
  # writer_model that is no writer id — values nothing above re-reads — passed here while model-run
  # refused the same answer as malformed. It runs AFTER the specific checks above, on its own line, so
  # their messages stay as they are (an empty value never gets this far: the six-key gate refuses it).
  _pf_v() { printf '%s\n' "$ROUTE_OUT" | sed -n "/^$1=/{s/^$1=//;p;q;}"; }
  if ! zms_route_values_ok "$(_pf_v platform)" "$(_pf_v writer_model)" "$(_pf_v writer_lane)" \
         "$(_pf_v reviewer_lane)" "$(_pf_v reviewer_model)" "$(_pf_v routing_status)"; then
    echo "reviewer-preflight: routing_status=ok but a value is outside its contract (enum, id or writer-id shape) — the check model-run applies; degrading" >&2
    PF_ROUTE_CONTRACT_BROKEN=1
  fi
  unset -f _pf_v
  # ONE rule, in one place after every check: a broken ok route never puts a client first.
  if [ "$PF_ROUTE_CONTRACT_BROKEN" -eq 1 ]; then
    ROUTED_CLIENT=""
    PF_ROUTED_MODEL=""
  fi
  unset _pf_routed_model _pf_platform
fi

# ── 2. audit client availability (candidates = the driver's blind-audit panel) ─
# Preflight keeps no exclusion logic of its own (CQ14 — one exclusion implementation): the driver's
# `--list-providers --mode blind-audit` already applies vendor host exclusion, the isolation allowlist
# (bap_allowlist: cursor-agent and gemini can never be candidates) and the argv/agy-settings drops, and
# prints the post-exclusion list, one lane per line. A hand-written list here would drift from what the
# blind audit actually dispatches.
#
# Driver lookup: this file's `.sh` sibling (the repo, every Claude-Code cache dir, ~/.codex/scripts,
# ~/.cursor/scripts), then ~/.zuvo/adversarial-review (installed there without the `.sh`).
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
# The driver's stderr is captured to a file: on a listing failure its first NON-EMPTY line (a blank
# or whitespace-only first line is skipped) goes into the fail-closed message through `printf '%s'`,
# never `echo`, which could reinterpret a backslash in the driver's text. A mktemp failure only loses
# that line. The listing can run up to its budget, so EXIT/INT/TERM are trapped for exactly that window
# and the earlier traps restored after it — the later canary-dir EXIT trap is never clobbered.
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
# segments and nothing else — a pattern, so a future tier (codex-5.5, a bare codex-5, codex-5.4.1)
# still collapses; digits only and anchored, so a suffixed lane (a future codex-5.4-api), a different
# execution path, keeps its own name exactly as kimi-api does.
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

# Map + dedup, in the driver's order — into a bash ARRAY read line by line, never a space-joined
# string, so a lane name with a stray blank or glob character is never word-split or glob-expanded.
# Lanes with no canary here (kimi-api, qwen, openrouter*, … — HTTP/API-key lanes) resolve to no binary,
# so they never become a candidate. Each line loses a trailing CR and surrounding blanks first, and a
# blank line is skipped: padding around a real lane name must not read as a different candidate.
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

# The routed client goes AHEAD of the panel's own order, wherever (or whether) the panel lists it; the
# dedup below keeps one canary per client. That dedup relies on one spelling: zms_client_for_model
# returns exactly `codex` or `claude`, and pf_map_lane folds every codex tier to `codex` and passes
# `claude` through unchanged.
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
    # The routed candidate is canaried with the model the route named (PF_ROUTED_MODEL) — the reviewer
    # the pipeline will actually use; every other candidate keeps the registry's model.
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
# routing_status=ok is not enough on its own: PF_ROUTE_CONTRACT_BROKEN (section 1a) means the route named
# a reviewer that could not be resolved or mapped, was the writer's own vendor, or came from an unknown
# platform — mapped like any other non-ok status. The router's answer is still passed through verbatim
# (see emit_and_exit).
case "$ROUTING_STATUS" in
  ok) if [ "$PF_ROUTE_CONTRACT_BROKEN" -eq 0 ]; then
        emit_and_exit "ok" "$PROVIDER" 0 "$ROUTE_OUT"
      else
        emit_and_exit "degraded-routing" "$PROVIDER" 0 "$ROUTE_OUT"
      fi ;;
  *)  emit_and_exit "degraded-routing" "$PROVIDER" 0 "$ROUTE_OUT" ;;
esac
