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
#         ~/.zuvo/adversarial-failures/<run_id>/)
#   3   — single_provider_only (--multi/--rotate with < 2 providers); in --mode blind-audit: DEGRADED
#   5   — NO REVIEWABLE MATERIAL: the payload carried nothing to judge, so nothing was sent to any
#         provider. NOT a review. Emitted for an empty/preamble-only code payload and for a
#         document below the per-mode minimum. It exists because these cases used to `exit 0`,
#         which every caller reads as "reviewed": a pass-2 payload whose `git diff` came back
#         empty (skills/review/SKILL.md:774) returned "0 findings" and wrote a REVIEW BY: line,
#         producing a push-gate proof for a review that never saw a line of code.
#   4   — review COMPLETED but the input was TRUNCATED: part of the change was never sent to any
#         provider. Findings are real; ABSENCE of findings proves nothing about the omitted files.
#         A caller must re-run over the omitted set (the artifact lists it) or split the input —
#         treating 4 as success reports a green review over code no model ever saw.
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
MONO_START="$(mono_now)"

# Seconds of this run the host spent suspended. Args: <wall_elapsed> <whole_run_budget>.
# Prints an integer; 0 means "no suspension detected".
#
# The budget argument MUST be the ceiling for the WHOLE run, not one provider's timeout.
# --single and --rotate walk their candidates sequentially, so N slow providers legitimately
# take N × the per-provider budget; measuring the fallback against a single provider's budget
# reported three genuinely-timed-out mock providers as "host suspended for ~16s … safe to
# repeat" (reproduced with python3 off PATH — i.e. exactly the Windows/Git-Bash environment
# this release also targets). A false `suspended` is not cosmetic: the calling skills are
# documented to retry it once, so it buys a wasted full retry cycle.
# Word-count of the dispatched-provider list. Extracted (B-dispatched-count-dup) because the
# same expression sat byte-identically in the all-failed branch and the success-path status
# derivation. The two are mutually exclusive at runtime so it was never a correctness bug — it
# was inconsistent with the rest of the change that introduced it, which extracted
# adversarial_log_row, preserve_failure_evidence and suspended_seconds for exactly this reason.
dispatched_count() { printf '%s\n' "$1" | wc -w | tr -d ' '; }

suspended_seconds() {
  local wall="$1" budget="$2" mono_end drift
  if [[ -n "$MONO_START" ]]; then
    mono_end="$(mono_now)"
    if [[ -n "$mono_end" ]]; then
      drift=$(( wall - (mono_end - MONO_START) ))
      [[ "$drift" -lt 0 ]] && drift=0
      printf '%d\n' "$drift"
      return 0
    fi
  fi
  # No monotonic source: infer. With the hard kill below, the honest ceiling on wall time is
  # the budget — anything at 2x+ was not spent computing. An estimate, never a measurement.
  if [[ "$budget" -gt 0 && "$wall" -gt $(( budget * 2 )) ]]; then
    printf '%d\n' $(( wall - budget ))
  else
    printf '0\n'
  fi
}
# Below this many seconds a drift is clock jitter / scheduling noise, not a suspend.
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

# ar_env_int <VAR> <default> — a whole-number knob from the environment: unset or empty → <default>; plain
# digits → that number (through ar_decimal, capped); anything else → <default> and a WARN naming the knob
# (the value sanitized, like the ZUVO_RUN_DEADLINE note). Stricter than ar_decimal on purpose: read
# leniently, ZUVO_REVIEW_TIMEOUT=10m (a valid `timeout` duration) would be 10 SECONDS. Every knob that
# reaches $(( )) or [ -gt ] goes through here or through ar_decimal: an arithmetic error on a raw value
# abandons the rest of the phase it is in, and `[ -gt ]` on one is just false — which turned the
# --mode plan circuit-breaker off for ZUVO_PLAN_ROUND_BUDGET=eight.
ar_env_int() {
  local name="$1" raw shown
  raw="${!name:-}"
  [[ -n "$raw" ]] || { printf '%s' "$2"; return 0; }
  if [[ "$raw" =~ ^[0-9]+$ ]]; then ar_decimal "$raw" "$2" "$AR_NUM_CAP"; return 0; fi
  shown="$(printf '%s' "$raw" | LC_ALL=C tr -cd 'a-zA-Z0-9._-' | cut -c1-20)" || shown=""
  echo "  WARN: $name='${shown:-(unprintable)}' is not a whole number — using $2" >&2
  printf '%s' "$2"
}

# ar_digest16 <text> — a short stable key for <text>: the first 16 characters of its SHA-1 (shasum, else
# sha1sum), else of its cksum, else <text> itself, reduced to [A-Za-z0-9]. It cannot fail: with every
# hasher missing, `x | shasum || x | sha1sum` exits 127, and under set -euo pipefail the assignment it
# feeds ends the run there, silently — what the --mode plan budget key did on a host with neither tool.
ar_digest16() {
  { printf '%s' "$1" | shasum 2>/dev/null || printf '%s' "$1" | sha1sum 2>/dev/null \
      || printf '%s' "$1" | cksum 2>/dev/null || printf '%s' "$1"; } | cut -c1-16 | tr -cd 'A-Za-z0-9'
}

# Sanitized like ZUVO_TIMEOUT_GRACE: a non-numeric override would silently evaluate to 0 in the
# arithmetic comparison below and class every run as suspended.
# shellcheck disable=SC2034  # read only by the modules (scripts/lib/adversarial-*.sh)
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
# made every candidate relative to the CWD, which is the repository under review.
_zuvo_src="${BASH_SOURCE[0]:-$0}"
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
# therefore never runs with modules from another install's directory, and never with half a set — nor with
# a complete set whose files come from two releases: install.sh writes adversarial-modules.cksum beside
# every set it installs, LAST, and a set that does not match its stamp is skipped (after waiting up to
# ZUVO_ADV_MODULE_STAMP_WAIT seconds, 10, for an install still copying) — an install interrupted between
# two modules, or a review started in the middle of one, would otherwise run code no single checkout ever
# held. A set with no stamp (a git checkout, the plugin cache, a copy a test made) loads as before. There is no
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
  run_openrouter run_claude run_kimi run_kimi_api run_muse run_qwen run_codestral"
_ar_module_error() {   # <what is wrong> — exit 2, the same code as any other refusal before a review
  echo "ERROR: adversarial-review cannot run — $1. Nothing was reviewed. Reinstall zuvo (./scripts/install.sh in the zuvo-plugin checkout, or update the plugin)." >&2
  exit 2
}
# _ar_stamp_matches <dir> — <dir>'s module set is the one its adversarial-modules.cksum was written for: the
# cksum of the modules read in AR_MODULES order. While it is not, wait (an install writes the stamp last);
# a stamp that is not a sum ("install-incomplete": the install knew a module failed) is refused at once.
_ar_stamp_wait="${ZUVO_ADV_MODULE_STAMP_WAIT:-10}"
case "$_ar_stamp_wait" in ''|*[!0-9]*) _ar_stamp_wait=10 ;; esac
_ar_stamp_matches() {
  local want got tries=$(( _ar_stamp_wait * 2 ))
  while :; do
    want="$(cat "$1/adversarial-modules.cksum" 2>/dev/null)" || want=""
    # shellcheck disable=SC2086  # module names, one word each
    got="$( (cd "$1" && cat $AR_MODULES) | cksum)" || got="unreadable"
    [ "$want" = "$got" ] && return 0
    case "$want" in ''|*[!0-9\ ]*) return 1 ;; esac
    [ "$tries" -gt 0 ] || return 1
    tries=$((tries - 1)); sleep 0.5
  done
}
AR_LIB_DIR="" _ar_lacking=""
for _ar_d in ${AR_SCRIPT_DIR:+"$AR_SCRIPT_DIR/lib" "$AR_SCRIPT_DIR"}; do
  _ar_miss=""
  for _ar_m in $AR_MODULES; do [ -f "$_ar_d/$_ar_m" ] || _ar_miss="${_ar_miss:+$_ar_miss }$_ar_m"; done
  if [ -n "$_ar_miss" ]; then
    _ar_lacking="${_ar_lacking:+$_ar_lacking; }$_ar_d/ lacks $_ar_miss"   # every candidate, in the order tried
  elif [ -f "$_ar_d/adversarial-modules.cksum" ] && ! _ar_stamp_matches "$_ar_d"; then
    _ar_lacking="${_ar_lacking:+$_ar_lacking; }$_ar_d/ holds a module set that does not match its install stamp (an install is running, was interrupted, or failed)"
  else
    AR_LIB_DIR="$_ar_d"; break
  fi
done
[ -n "$AR_LIB_DIR" ] || _ar_module_error "no usable set of its modules (scripts/lib/adversarial-*.sh) is beside it: ${_ar_lacking:-the script directory could not be resolved, so there was nowhere to look}"
# One literal `.` line per module, in AR_MODULES order: tests/lib/adversarial-driver.sh inlines each
# module at its line, so source assertions and the lint read the driver as the one program it was
# before the split (shellcheck -x would follow the modules but report nothing found inside them).
# `|| …`: a module that does not parse must not end the run with bash's own status and no word of why —
# `.` returns 2 for a syntax error anywhere in the file, which only an `||` can turn into this message
# (under errexit a bare `.` exits at once, ERR trap or not). The `||` also suspends errexit inside the
# module, which costs nothing because a module runs nothing at load: it only defines functions and sets
# its literal module-scope state, and test-adversarial-driver-modules.sh (3) sources each one under
# errexit, with no PATH, to hold it to that.
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
unset _ar_d _ar_m _ar_miss _ar_lacking _ar_f _ar_stamp_wait

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
