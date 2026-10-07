#!/usr/bin/env bash
# adversarial-review.sh — Cross-provider adversarial code review
#
# Auto-detects available review providers and runs an adversarial review of the
# given diff or files. Detection order (detect_providers): codex-5.3 (OpenAI) →
# agy (Google/Antigravity) → cursor-agent (Cursor) → kimi (Moonshot K3, OAuth CLI;
# kimi-api curl fallback needs MOONSHOT_API_KEY) → claude (Anthropic). A genuine
# cross-model pass needs ≥2 vendors; verify what actually works with --doctor.
#
# Usage:
#   git diff HEAD~1 | ./scripts/adversarial-review.sh
#   ./scripts/adversarial-review.sh --files "src/auth.ts src/user.ts"
#   ./scripts/adversarial-review.sh --diff HEAD~3
#   ./scripts/adversarial-review.sh --provider kimi --diff HEAD~1
#   ./scripts/adversarial-review.sh --doctor        # live auth probe of every detected provider
#   ./scripts/adversarial-review.sh --mode blind-audit --production src/x.sh --test tests/x.test.sh
#
# Exit codes (--mode blind-audit: 0 strict, 3 degraded, 2 no valid answer, 6 too large — see --help):
#   0   — review completed (output on stdout)
#   1   — no review provider available
#   2   — every provider was reached and produced no review (stderr kept under
#         ~/.zuvo/adversarial-failures/<run_id>/); also a usage error, or missing or broken driver modules
#   3   — single_provider_only (--multi/--rotate with < 2 providers); in --mode blind-audit: DEGRADED
#   5   — NO REVIEWABLE MATERIAL (empty/preamble-only payload, a document under its mode's minimum): not a review
#   4   — review COMPLETED over a TRUNCATED input: never success — the omitted files (listed) went unreviewed
#   6   — --mode blind-audit only: the prompt is over ZUVO_BLIND_AUDIT_MAX_BYTES, nothing was sent
#   124 — everything timed out, or the whole-run deadline fired
#   125 — the HOST was suspended mid-run (lid close / sleep). Not a provider fault; retry.

set -euo pipefail

# ─── Timing ────────────────────────────────────────────────────
# shellcheck disable=SC2034  # read only by the modules (scripts/lib/adversarial-*.sh)
START_TIME=$(date +%s)

# Monotonic companion to START_TIME. The monotonic clock does NOT advance while the host is
# suspended (macOS: CLOCK_UPTIME_RAW, Linux: CLOCK_MONOTONIC), so wall_delta - mono_delta is
# the number of seconds this run spent asleep. Without it a closed laptop lid is
# indistinguishable from five dead providers — field case 2026-07-30: run started 11:52, lid
# shut 11:53 ('Clamshell Sleep' in pmset), host woke 13:32, every provider came back empty
# after 5998s and the skill reported it as "all provider infrastructure blocked". python3 is
# optional here; without it elapsed_suspended falls back to a budget-overshoot estimate.
mono_now() { python3 -c 'import time;print(int(time.monotonic()))' 2>/dev/null || echo ""; }
# shellcheck disable=SC2034  # read only by the modules (scripts/lib/adversarial-*.sh)
MONO_START="$(mono_now)"

# ar_decimal <raw> <no-digits-default> [10+-digit-cap] — a number from outside (env knob, state file) as
# plain DECIMAL digits: non-digits dropped, leading zeros stripped — bash arithmetic reads `0060` as
# octal 48 and dies on `08` ("value too great for base") — all zeros → 0, no digit at all →
# <no-digits-default>, silently: "my-host" is no number, not a negative one. A `-` anywhere BEFORE the
# first digit is a sign and is refused (→ <no-digits-default>, WARN) rather than silently dropped: `tr
# -cd` would otherwise turn "-5" into "5", flipping the sign with no diagnostic — and " -5" / "\t-5"
# too, which a `-*` test on the raw value missed. So is a Unicode minus there (U+2212 −, U+FE63 ﹣,
# U+FF0D －): matched as its UTF-8 BYTES, so LC_ALL=C and bash 3.2 see it too, and read as `-`. The
# WARN shows the value sanitized and capped (it is unvalidated env/file input, never echoed raw — the
# same idiom as the ZUVO_RUN_DEADLINE NOTE).
# [10+-digit-cap] is OPTIONAL and OFF by default: a raw UNIX TIMESTAMP (the agy cooldown file) is
# legitimately 10+ digits and must never be truncated into a bogus PAST date. Callers that read a
# bounded DURATION (a timeout, a grace period, a deadline) pass a cap (999999999, the same one the
# library's own `_bap_secs`/`_bap_knob` apply) so an extreme value cannot wrap bash's integer
# arithmetic or a later `[[ -gt ]]` comparison; callers that read a point in time pass none.
# The ONE normaliser for every such number that reaches $(( )) or [[ -gt ]], so the sites cannot drift.
# AR_NUM_CAP is that cap, named once: nine digits — far above any real duration or input size, far
# below where bash's 64-bit arithmetic wraps. Also the "no size limit" value for blind-audit's MAX_CHARS.
AR_NUM_CAP=999999999
ar_decimal() {
  local v cap="${3:-}" raw="${1:-}" lead m
  lead="${raw%%[0-9]*}"   # everything before the first digit
  [[ "$lead" != "$raw" ]] || lead=""   # no digit at all: no sign to read, the default below
  for m in $'\xe2\x88\x92' $'\xef\xb9\xa3' $'\xef\xbc\x8d'; do lead="${lead//"$m"/-}"; done
  case "$lead" in
    *-*)
      # LC_ALL=C: BSD tr aborts on an invalid byte sequence under a UTF-8 locale; `|| v=""` keeps any
      # failure of this display-only pipeline from taking the run down under `set -euo pipefail`.
      v="$(printf '%s' "$lead${raw#"${raw%%[0-9]*}"}" | LC_ALL=C tr -cd 'a-zA-Z0-9._-' | cut -c1-20)" || v=""
      echo "ar_decimal: WARN: '${v:-(unprintable)}' is negative — using ${2:-no value}" >&2
      printf '%s' "$2"; return 0 ;;
  esac
  # LC_ALL=C and `|| v=""`: the same two guards as above, on the main path — a caller that runs this
  # directly (not in `$( )`, where errexit is off) must get the default, never an aborted run.
  v="$(printf '%s' "$raw" | LC_ALL=C tr -cd '0-9')" || v=""
  [[ -n "$v" ]] || { printf '%s' "$2"; return 0; }
  v="${v#"${v%%[!0]*}"}"; v="${v:-0}"
  [[ -z "$cap" ]] || case "$v" in ??????????*) v="$cap" ;; esac
  printf '%s' "$v"
}

# ar_env_int <VAR> <default> [<min>] — a whole-number knob: unset/empty → <default>; digits → that number
# (ar_decimal, capped), or <default> + WARN below <min>; anything else (`10m`) → <default> + WARN. Every knob
# reaching $(( )) or [ -gt ] goes through here or ar_decimal: an arithmetic error on a raw value abandons the
# rest of its phase, and `[ -gt ]` on one is just false (ZUVO_PLAN_ROUND_BUDGET=eight once disabled a breaker).
ar_env_int() {
  local name="$1" raw shown
  raw="${!name:-}"
  [[ -n "$raw" ]] || { printf '%s' "$2"; return 0; }
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    shown="$(ar_decimal "$raw" "$2" "$AR_NUM_CAP")"
    if [[ -n "${3:-}" && "$shown" -lt "$3" ]]; then
      echo "  WARN: $name=$shown is below its minimum of $3 — using $2" >&2
      shown="$2"
    fi
    printf '%s' "$shown"; return 0
  fi
  shown="$(printf '%s' "$raw" | LC_ALL=C tr -cd 'a-zA-Z0-9._-' | cut -c1-20)" || shown=""
  echo "  WARN: $name='${shown:-(unprintable)}' is not a whole number — using $2" >&2
  printf '%s' "$2"
}

# ar_repo_root — the checkout's top level, else the physical CWD, else "unknown-cwd"; it cannot fail.
ar_repo_root() { git rev-parse --show-toplevel 2>/dev/null || pwd -P 2>/dev/null || printf '%s' unknown-cwd; }

# ar_digest16 <text> — a short stable key for <text>: 16 characters of its SHA-1 (shasum, else sha1sum), else of
# its cksum, else — no hash tool — <text>'s last 48 characters sanitized (not injective). It cannot fail.
ar_digest16() {
  local d
  d="$( { printf '%s' "$1" | shasum 2>/dev/null || printf '%s' "$1" | sha1sum 2>/dev/null \
      || printf '%s' "$1" | cksum 2>/dev/null; } | cut -c1-16 | tr -cd 'A-Za-z0-9')" || d=""
  # No hash tool at all: the input's own END, sanitized — its start is shared by every repository under one parent.
  [[ -n "$d" ]] || d="$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_' | tail -c 48)"
  printf '%s' "${d:-default}"
}

# Sanitized like ZUVO_TIMEOUT_GRACE: a non-numeric override would silently evaluate to 0 in the
# arithmetic comparison below and class every run as suspended.
# shellcheck disable=SC2034  # read only by the modules (scripts/lib/adversarial-*.sh)
# Below this many seconds a drift is clock jitter / scheduling noise, not a suspend.
SUSPEND_THRESHOLD="$(ar_decimal "${ZUVO_SUSPEND_THRESHOLD:-60}" 60 "$AR_NUM_CAP")"

# ─── Hard timeout ───────────────────────────────────────────────
# `timeout N cmd` only sends SIGTERM. A provider CLI that ignores or slow-walks TERM then runs
# unbounded, and the caller blocks with it. Measured over 30 days of ~/.zuvo/adversarial.log:
# 94 of 5989 runs (1.6%) blew past their 240/360s budget, worst case 34273s (9.5 hours).
# -k escalates to SIGKILL after a grace period, and because GNU timeout puts the child in its
# own process group the kill reaches grandchildren still holding the output pipe open.
ZUVO_TIMEOUT_GRACE="$(ar_decimal "${ZUVO_TIMEOUT_GRACE:-15}" 15 "$AR_NUM_CAP")"
TIMEOUT_KILL_FLAG=""
# shellcheck disable=SC2034  # read only by the modules (scripts/lib/adversarial-*.sh)
if command -v timeout >/dev/null 2>&1 && timeout -k 1 1 true >/dev/null 2>&1; then
  # Word-split on purpose: a controlled two-token literal, not user input.
  TIMEOUT_KILL_FLAG="-k $ZUVO_TIMEOUT_GRACE"
fi

# ─── Configuration ──────────────────────────────────────────────

# Central model registry — single source of truth for concrete model ids (agy/codex/claude/cursor).
# Sourced fail-safe: if it is missing, every usage below keeps an inline `:-<id>` fallback.
# The registry lives in DIFFERENT places depending on how this script was installed, and for a
# long time only one of them was tried — so on the path that actually runs (~/.zuvo/adversarial-
# review) `../shared/includes/` resolves to ~/shared/includes/, which does not exist. The registry
# was therefore never loaded there: every value came from the in-script fallbacks, and editing
# model-registry.sh alone changed NOTHING at runtime. Silent, because a missing file is skipped.
# Try every layout, first hit wins:
#   repo / plugin cache : <dir>/../shared/includes/model-registry.sh
#   flat ~/.zuvo install: <dir>/model-registry.sh
# <dir> is resolved the way the router and the preflight resolve theirs (one method, three copies —
# the library cannot resolve the path it is being looked up by): from BASH_SOURCE by parameter
# expansion — a bare name only when that file is in $PWD (bash opened it from there; a PATH-searched
# script is recorded with its full path) — then made PHYSICAL with `cd -P` + `pwd -P`. Builtins only.
# Empty when it cannot be resolved, and then nothing is looked up beside it: the old fallback "."
# made every candidate relative to the CWD, which is the repository under review. Never $0 under bash: under
# `bash -s` it is the shell's own name, and a file called `bash` in the CWD would make the CWD this directory.
_zuvo_src="${BASH_SOURCE[0]:-}"
[ -n "${BASH_VERSION:-}" ] || _zuvo_src="$0"
_zuvo_dir=""
case "$_zuvo_src" in
  */*) _zuvo_dir="${_zuvo_src%/*}"; [ -n "$_zuvo_dir" ] || _zuvo_dir=/ ;;
  ?*)  if [ -n "${PWD:-}" ] && [ -f "$PWD/$_zuvo_src" ]; then _zuvo_dir="$PWD"; fi ;;
esac
if [ -n "$_zuvo_dir" ]; then _zuvo_dir="$(CDPATH='' cd -P -- "$_zuvo_dir" 2>/dev/null && pwd -P)" || _zuvo_dir=""; fi
# Order matters, and the `..` candidate is guarded rather than merely last. From ~/.zuvo the
# expression `<dir>/../shared/includes/model-registry.sh` resolves to $HOME/shared/includes/... —
# OUTSIDE the install root, in a directory any process can create. This file is SOURCED, so a
# planted file there would execute as us on every review. The path is only meaningful in the
# repo/cache layout, so it is used ONLY when it stays inside the install tree (i.e. the parent
# also holds the scripts/ directory this file ships in).
_zuvo_regs=("$HOME/.zuvo/model-registry.sh")
if [ -n "$_zuvo_dir" ]; then _zuvo_regs+=("$_zuvo_dir/model-registry.sh"); fi
for _zuvo_reg in "${_zuvo_regs[@]}"; do
  if [ -f "$_zuvo_reg" ]; then . "$_zuvo_reg"; _zuvo_reg_loaded=1; break; fi
done
if [ -z "${_zuvo_reg_loaded:-}" ] && [ -n "$_zuvo_dir" ] && [ -d "$_zuvo_dir/../shared/includes" ] \
   && [ -d "$_zuvo_dir/../skills" ]; then
  _zuvo_reg="$_zuvo_dir/../shared/includes/model-registry.sh"
  [ -f "$_zuvo_reg" ] && . "$_zuvo_reg"
fi

# Shared reviewer runner — scripts/lib/model-subprocess.sh (zms_*): host detection, codex/claude
# resolution, the isolated CODEX_HOME, timeout + reap, the auth-stub and CLI-version guards. One
# copy for the driver, the router and the preflight (three used to disagree). Sibling first, so a
# checkout never runs what an older install left in ~/.zuvo: <dir>/lib/ → <dir>/ (flat) → ~/.zuvo/.
# A candidate LOADS only when it sources AND defines every zms_* function this file calls (the same
# check the router and the preflight make, each for its own list): an older or truncated copy that
# sources cleanly but lacks one would otherwise be accepted, and its first missing call would be a
# "command not found" in the middle of a review. The list is unset before each candidate, so what a
# half-loaded earlier candidate defined cannot pass for this one. A rejected candidate is WARNed about
# by name, never skipped silently.
# Missing: ONE warning, then codex/claude fail loudly when dispatched (runner_ready) with the outcome
# `no-runner` — still listed (PATH only) so the failure shows in the outcomes, but never counted
# against the lane in the provider-health ledger (a broken install is not a broken lane); the
# auth-stub filter fails CLOSED as `unverified` (exclude_auth_stub); codex host detection is off
# (detect_host_platform), so a Codex host is not excluded from reviewing itself — moot while its lanes
# cannot run; every other lane runs — a review from the other vendors beats none.
# Sibling paths only when the script dir resolved: a relative candidate would source
# lib/model-subprocess.sh out of the CWD — the repository under review.
_zms_dir="$_zuvo_dir" _zms_repo="" _zms_who="  "
_zms_fns="zms_client_available zms_is_codex_host zms_codex_host_model zms_codex_cli_guard zms_run_codex zms_run_claude zms_is_auth_stub"
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
# None loaded: the list goes once more, so nothing the LAST rejected candidate defined stays callable —
# every call site checks ZMS_LOADED today, and a half-loaded function must not be there for one that forgets.
# shellcheck disable=SC2086  # one function name per word, by design
[ -n "$ZMS_LOADED" ] || unset -f $_zms_fns
[ -n "$ZMS_LOADED" ] || echo "  WARN: model-subprocess.sh (the shared codex/claude runner) not loaded from next to ${_zuvo_dir:-<the script dir, unresolved>} or from ~/.zuvo — the codex and claude lanes will fail (outcome no-runner, not held against them in the provider-health ledger), codex host detection is off (a Codex host is not excluded from reviewing itself), and short outputs (≤600 B) from any lane are excluded as unverified (no auth check possible); other lanes still run. Fix: ./scripts/install.sh" >&2
AR_SCRIPT_DIR="$_zuvo_dir"   # --mode blind-audit looks up its panel library and protocol from here
AR_SELF="${_zuvo_dir:+$_zuvo_dir/}${_zuvo_src##*/}"   # this file: the module-set stamp sums it with its modules
unset _zuvo_src _zuvo_dir _zuvo_regs _zuvo_reg_loaded _zms_fns _zms_dir _zms_repo _zms_who

# runner_ready <lane> — true when the shared runner is loaded; otherwise the named error that makes a
# codex/claude lane fail loudly (in its own stderr, which the failure evidence keeps), a no-runner
# marker the outcome collection reads (the lane could not RUN — it was not asked and did not fail, so
# it is `no-runner`, never `empty`: an `empty` would bench a healthy lane in the PERSISTENT ledger long
# after the install is fixed), and status 2. Checked FIRST in every codex/claude lane — before a model
# is chosen or a NOTE about the choice is printed.
runner_ready() {
  [[ -n "$ZMS_LOADED" ]] && return 0
  echo "  ERROR: $1 cannot run — the shared runner model-subprocess.sh was not loaded at startup (reinstall: ./scripts/install.sh)" >&2
  if [[ -n "${JSON_TMPDIR:-}" && -d "$JSON_TMPDIR" ]]; then : > "$JSON_TMPDIR/norunner_$1" 2>/dev/null || true; fi
  return 2
}

# client_available <codex|claude> — detection by the runner's own resolver, so a lane is offered
# exactly when it can be run: ZUVO_CODEX_BIN / ZUVO_CLAUDE_BIN (a set value is final), PATH, and for
# codex the Codex.app bundle. Never executes the client. Without the runner: PATH only, so the lane
# is still listed and its failure stays visible in the outcomes instead of silently leaving the panel.
client_available() {
  if [[ -n "$ZMS_LOADED" ]]; then zms_client_available "$1"; else command -v "$1" &>/dev/null; fi
}

# ─── Driver modules ─────────────────────────────────────────────
# Everything after the bootstrap above lives in scripts/lib/adversarial-*.sh, one module per
# responsibility (each module's header says what it holds and which phases it defines). This file keeps
# the clock, the number normaliser, the model registry, the shared runner and the order the phases run
# in: Main, at the end.
#
# The modules come from ONE directory: the first of <script dir>/lib/ (the repo, the plugin cache, every
# host install, ~/.zuvo/lib) and <script dir>/ (a flat copy) that holds every one of them. A driver
# therefore never runs with modules from another install, half a set, or a set from two releases: install.sh
# writes adversarial-modules.cksum LAST beside every set, and a set not matching it is skipped after waiting
# ZUVO_ADV_MODULE_STAMP_WAIT for an install still copying. An unstamped set (a checkout) loads. There is no
# ~/.zuvo fallback, unlike model-subprocess.sh: without that library two lanes are lost, so finding it
# elsewhere is worth the version risk — these modules ARE the program, and modules found in some other
# install would run a review whose code no single checkout ever held. A copy of this file without its
# modules stops here with exit 2, before any input is read or any provider is asked; so does a module
# that fails to load, or a set that lacks a function Main or the lane router calls (a partial or older
# copy). tests/hooks/test-adversarial-driver-modules.sh pins this contract and keeps AR_REQUIRED_FNS
# equal to what Main and the router actually call.
AR_MODULES="adversarial-cli.sh adversarial-ledger.sh adversarial-input.sh adversarial-prompt.sh
  adversarial-providers.sh adversarial-lanes.sh adversarial-lanes-http.sh adversarial-dispatch.sh
  adversarial-run.sh adversarial-blind-audit.sh adversarial-report.sh"
AR_REQUIRED_FNS="ar_init_options ar_init_failure_cache ar_parse_args ar_reconcile_append_artifact
  ar_init_findings_ledger ar_cmd_record_disposition ar_cmd_effectiveness ar_resolve_provider_env
  ar_validate_mode ar_ba_setup ar_check_plan_budget ar_guard_file_list ar_collect_input
  ar_set_input_cap ar_set_chunk_boundary ar_check_material ar_chunk_input ar_truncate_input
  _tamper_capture ar_detect_language ar_select_focus ar_set_output_instruction
  ar_compose_review_prompt ar_exclude_host_lanes ar_list_providers_if_asked
  ar_resolve_candidates ar_apply_excludes ar_ba_filter_lanes ar_apply_exclude_last
  ar_skip_auth_cached ar_bench_failing_lanes ar_cap_fanout ar_require_providers
  ar_resolve_dispatch_mode ar_run_doctor ar_preflight ar_dry_run ar_init_run_state
  ar_init_run_log init_log_header ar_install_traps ar_arm_deadline ar_dispatch_lanes
  ar_ba_validate_answers ar_update_provider_health ar_ba_report ar_report_no_review
  ar_count_findings ar_warn_clean_large_input ar_build_output ar_emit_output ar_log_run
  ar_log_summary_and_exit run_mock run_codex_54 run_codex_53 run_cursor_agent run_agy
  run_openrouter run_byteplus run_claude run_kimi run_kimi_api run_muse run_qwen run_codestral"
_ar_module_error() {   # <what is wrong> — exit 2, the same code as any other refusal before a review
  echo "ERROR: adversarial-review cannot run — $1. Nothing was reviewed. Reinstall zuvo (./scripts/install.sh in the zuvo-plugin checkout, or update the plugin)." >&2
  exit 2
}
# _ar_stamp_matches <dir> — <dir>'s set matches its stamp; waits while it does not, but refuses a non-sum at once.
_ar_stamp_wait="$(ar_env_int ZUVO_ADV_MODULE_STAMP_WAIT 10)"   # through the normaliser: `08` is 8, not an octal error
# This file's bytes, read ONCE, before any waiting: a driver started during an install must not pair its old
# bootstrap with modules stamped for the new one. (The trailing x keeps trailing newlines through `$( )`.)
_ar_self_bytes=""
[ -z "$AR_SELF" ] || _ar_self_bytes="$(cat "$AR_SELF" 2>/dev/null && printf x)" || _ar_self_bytes=""
_ar_stamp_matches() {
  local want got tries=$(( _ar_stamp_wait * 2 ))
  while :; do
    want="$(cat "$1/adversarial-modules.cksum" 2>/dev/null)" || want=""
    # shellcheck disable=SC2086  # module names, one word each
    if [ -n "$_ar_self_bytes" ]; then
      got="$( { printf '%s' "${_ar_self_bytes%x}" && (cd "$1" && cat $AR_MODULES); } | cksum)" || got="unreadable"
    else
      got="unreadable"
    fi
    [ "$want" = "$got" ] && return 0
    case "$want" in ''|*[!0-9\ ]*) return 1 ;; esac
    [ "$tries" -gt 0 ] || return 1
    tries=$((tries - 1)); sleep 0.5
  done
}
AR_LIB_DIR="" _ar_lacking="" _ar_skipped=""
for _ar_d in ${AR_SCRIPT_DIR:+"$AR_SCRIPT_DIR/lib" "$AR_SCRIPT_DIR"}; do
  _ar_miss=""
  for _ar_m in $AR_MODULES; do [ -f "$_ar_d/$_ar_m" ] || _ar_miss="${_ar_miss:+$_ar_miss }$_ar_m"; done
  if [ -n "$_ar_miss" ]; then
    _ar_lacking="${_ar_lacking:+$_ar_lacking; }$_ar_d/ lacks $_ar_miss"   # every candidate, in the order tried
  elif [ -f "$_ar_d/adversarial-modules.cksum" ] && ! _ar_stamp_matches "$_ar_d"; then
    _ar_lacking="${_ar_lacking:+$_ar_lacking; }$_ar_d/ holds a module set that does not match its install stamp (an install is running, was interrupted, or failed)"
    _ar_skipped="${_ar_skipped:+$_ar_skipped, }$_ar_d/"
  else
    AR_LIB_DIR="$_ar_d"; break
  fi
done
unset _ar_self_bytes
[ -n "$AR_LIB_DIR" ] || _ar_module_error "no usable set of its modules (scripts/lib/adversarial-*.sh) is beside it: ${_ar_lacking:-the script directory could not be resolved, so there was nowhere to look}"
# A set skipped for its stamp cost this run the wait and is worth a reinstall: say so, once.
[ -z "$_ar_skipped" ] || echo "  NOTE: adversarial driver modules taken from $AR_LIB_DIR/ — skipped $_ar_skipped (out of step with its install stamp; reinstall zuvo to repair it)" >&2
# One literal `.` line per module, in AR_MODULES order: tests/lib/adversarial-driver.sh inlines each
# module at its line, so source assertions and the lint read the driver as the one program it was
# before the split (shellcheck -x would follow the modules but report nothing found inside them).
# `|| …`: `.` returns 2 for a syntax error in a module, and only an `||` turns that into this message (a bare
# `.` under errexit exits at once). It suspends errexit in the module, free: a module runs nothing at load.
. "$AR_LIB_DIR/adversarial-cli.sh" || _ar_module_error "$AR_LIB_DIR/adversarial-cli.sh did not load"
. "$AR_LIB_DIR/adversarial-ledger.sh" || _ar_module_error "$AR_LIB_DIR/adversarial-ledger.sh did not load"
. "$AR_LIB_DIR/adversarial-input.sh" || _ar_module_error "$AR_LIB_DIR/adversarial-input.sh did not load"
. "$AR_LIB_DIR/adversarial-prompt.sh" || _ar_module_error "$AR_LIB_DIR/adversarial-prompt.sh did not load"
. "$AR_LIB_DIR/adversarial-providers.sh" || _ar_module_error "$AR_LIB_DIR/adversarial-providers.sh did not load"
. "$AR_LIB_DIR/adversarial-lanes.sh" || _ar_module_error "$AR_LIB_DIR/adversarial-lanes.sh did not load"
. "$AR_LIB_DIR/adversarial-lanes-http.sh" || _ar_module_error "$AR_LIB_DIR/adversarial-lanes-http.sh did not load"
. "$AR_LIB_DIR/adversarial-dispatch.sh" || _ar_module_error "$AR_LIB_DIR/adversarial-dispatch.sh did not load"
. "$AR_LIB_DIR/adversarial-run.sh" || _ar_module_error "$AR_LIB_DIR/adversarial-run.sh did not load"
. "$AR_LIB_DIR/adversarial-blind-audit.sh" || _ar_module_error "$AR_LIB_DIR/adversarial-blind-audit.sh did not load"
. "$AR_LIB_DIR/adversarial-report.sh" || _ar_module_error "$AR_LIB_DIR/adversarial-report.sh did not load"
for _ar_f in $AR_REQUIRED_FNS; do
  declare -F "$_ar_f" >/dev/null || _ar_module_error "$_ar_f is not defined by the modules in $AR_LIB_DIR (a partial or older copy)"
done
unset _ar_d _ar_m _ar_miss _ar_lacking _ar_skipped _ar_f _ar_stamp_wait

# ─── Main ──────────────────────────────────────────────────────
# The phases, in the order they run. Each holds the driver's former top-level code unchanged (the
# comments inside say why that code is what it is). Beside each: the scripts/lib/adversarial-<name>.sh
# module that defines it.
# Several end the run themselves (exit) — --help, the ledger subcommands, --list-providers, --doctor,
# --dry-run, chunked input, a refused or empty input, no provider, blind audit, no review.
ar_init_options                   # cli
ar_init_failure_cache             # providers
ar_parse_args "$@"                # cli
ar_reconcile_append_artifact      # cli
ar_init_findings_ledger           # ledger
ar_cmd_record_disposition         # ledger
ar_cmd_effectiveness              # ledger
ar_resolve_provider_env           # cli
ar_validate_mode                  # cli
ar_ba_setup                       # blind-audit
ar_check_plan_budget              # cli
ar_guard_file_list                # input
ar_collect_input                  # input
ar_set_input_cap                  # input
ar_set_chunk_boundary             # input
ar_check_material                 # input
ar_chunk_input                    # input
ar_truncate_input                 # input
_tamper_capture                   # input
ar_detect_language                # prompt
ar_select_focus                   # prompt
ar_set_output_instruction         # prompt
ar_compose_review_prompt          # prompt
ar_exclude_host_lanes             # providers
ar_list_providers_if_asked        # providers
ar_resolve_candidates             # providers
ar_apply_excludes                 # providers
ar_ba_filter_lanes                # blind-audit
ar_apply_exclude_last             # providers
ar_skip_auth_cached               # providers
ar_bench_failing_lanes            # providers
ar_cap_fanout                     # providers
ar_require_providers              # providers
ar_resolve_dispatch_mode          # providers
ar_run_doctor                     # run
ar_preflight                      # run
ar_dry_run                        # run
ar_init_run_state                 # run
ar_install_traps                  # run
ar_init_run_log                   # ledger
init_log_header                   # ledger
ar_arm_deadline                   # run
ar_dispatch_lanes                 # dispatch
ar_ba_validate_answers            # blind-audit
ar_update_provider_health         # ledger
ar_ba_report                      # blind-audit
ar_report_no_review               # report
ar_count_findings                 # report
ar_warn_clean_large_input         # report
ar_build_output                   # report
ar_emit_output                    # report
ar_log_run                        # report
ar_log_summary_and_exit           # report
