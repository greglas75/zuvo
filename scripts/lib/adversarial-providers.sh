# shellcheck shell=bash
# adversarial-providers.sh — which lanes run: the run's auth-failure cache, host detection (no lane
# reviews its own host), client detection in measured priority order, the candidate set and every
# exclusion applied to it (--exclude, host, --exclude-last, auth cache, health bench), the fan-out cap,
# each lane's model and review access, and the dispatch mode (multi/single/rotate, the D3 refusal).
# Sourced by scripts/adversarial-review.sh only; never executed.
#
# Phases: ar_init_failure_cache, ar_exclude_host_lanes, ar_list_providers_if_asked,
# ar_resolve_candidates, ar_apply_excludes, ar_apply_exclude_last, ar_skip_auth_cached,
# ar_bench_failing_lanes, ar_cap_fanout, ar_require_providers, ar_resolve_dispatch_mode.
#
# Phase bodies sit at column 0, as the top-level code they were cut from: indenting them would change the
# multi-line prompt strings and heredocs several carry. Each runs once, from the driver's Main.
# Linted as part of the whole program: tests/hooks/test-adversarial-driver-modules.sh runs shellcheck on
# the driver with every module inlined (the repo's shellcheck gate skips files without a shebang).

# ar_init_failure_cache — PROVIDER_FAIL_CACHE — the run-scoped auth-failure cache a rotation's invocations share.
# lanes_filter keep|drop <list> <names> — the words of <list> that are (keep) or are not (drop) among <names>,
# whole names only, in order; never globbed (`clau*` must not match a file named claude). Call it in $( ).
lanes_filter() {
  local how="$1" list="$2" names="$3" l n hit out="" noglob=0 IFS=$' \t\n'   # split on blanks, whatever IFS the caller has
  case $- in *f*) noglob=1 ;; esac
  set -f
  for l in $list; do
    hit=0
    for n in $names; do [[ "$l" == "$n" ]] && { hit=1; break; }; done
    if [[ "$how" == keep ]]; then [[ "$hit" -eq 0 ]] || out="${out:+$out }$l"
    else [[ "$hit" -eq 1 ]] || out="${out:+$out }$l"; fi
  done
  [[ "$noglob" -eq 1 ]] || set +f
  printf '%s' "$out"
}

ar_init_failure_cache() {
# Run-scoped provider-failure cache. A rotation is N separate invocations of this script, so a
# provider whose auth/subscription is dead costs the full per-provider timeout on EVERY pass
# unless the failure is remembered between them. Keyed by ZUVO_RUN_ID when the caller sets one,
# else by the repository (a digest of its path). Entries expire after ZUVO_AUTH_CACHE_TTL (_ar_auth_cached_lanes).
# No date component: a rotation that straddles UTC midnight would otherwise silently get a fresh
# key and re-probe every provider it had just proven dead. The dir is per-boot temp storage, so it
# is naturally short-lived without a date in the name.
# `|| pwd` is load-bearing, not defensive noise. `git rev-parse --show-toplevel`
# exits 128 outside a work tree; `set -o pipefail` propagates that through the
# `| tr` pipeline and `set -e` then kills the script — right here, before a
# single byte of output. The `2>/dev/null` here made it WORSE by hiding git's own
# "not a git repository" message, so the whole run looked like a silent rc=128
# with empty stdout AND empty stderr, on every invocation from a non-repo CWD.
# Measured 2026-08-04: reproduced identically on macOS and on burst-i9, and it is
# why that host's adversarial.log showed `provider=none / all-failed` — the run
# never reached provider detection at all, so a year of "the CI box has no
# providers" was a misdiagnosis. The --mode plan budget's repo key (ar_check_plan_budget) already had the
# `|| pwd` fallback; this line did not.
# The path is HASHED, not slash-substituted. `tr / _` is not injective: `/a/b`
# and `/a_b` both become `_a_b`, and the later `${...//[^A-Za-z0-9._-]/_}`
# collapses more characters still — so two unrelated project roots could share
# one PROVIDER_FAIL_CACHE and one project's "this provider is dead" verdict would
# suppress probing in the other. Hashing also bounds the filename: the raw
# fallback embedded the entire CWD, which outside a repo is arbitrarily deep and
# can exceed NAME_MAX on a long path. Four reviewers flagged the collision
# independently. A short hex digest is collision-safe enough for a per-boot
# diagnostic cache and is a fixed 16 chars regardless of input.
# The final `printf` is what makes this statement UNFAILABLE, and that is the
# whole point. `git || pwd` still dies if BOTH fail — and `pwd` does fail, on a
# deleted or unmounted CWD, which is a real condition on CI boxes with tmpdir
# reapers or dropped network mounts. Under `set -euo pipefail` a failing command
# substitution kills the assignment, reproducing the exact rc/empty-output shape
# this line was rewritten to eliminate. A guard that only covers the failure you
# already knew about is the defect class, not the fix for it.
_ar_path_for_key="$(ar_repo_root)"
# ar_digest16 (the driver's bootstrap) cannot fail either, even with no hash tool at all; the `nokey` guard
# below covers a real digest that sanitizes to empty. The --mode plan budget keys its file through it too.
_ar_digest="$(ar_digest16 "${_ar_path_for_key:-unknown}")"
_ar_cache_key="${ZUVO_RUN_ID:-$_ar_digest}"
[ -n "$_ar_cache_key" ] || _ar_cache_key="nokey$$"
# Own the directory before writing into it. A predictable name under a world-writable /tmp lets
# another user on the host pre-create it as a SYMLINK, and then `>>` appends to — or `: >`
# truncates — whatever it points at (CWE-59). zuvo runs on shared VPS hosts where that is a real
# neighbour, not a theoretical one. `mkdir -p` succeeds on an existing path, so the checks after it refuse
# one that is a symlink, not a directory, or someone else's: a hostile pre-create turns the cache OFF for
# the run rather than writing through it — never to a private mktemp dir, which the rotation's next
# invocation could not share.
_ar_cache_dir="${TMPDIR:-/tmp}/zuvo-adv-$(id -u)"
# shellcheck disable=SC2174  # tightened unconditionally by the chmod below the fi
if ! mkdir -m 700 -p "$_ar_cache_dir" 2>/dev/null \
   || [ -L "$_ar_cache_dir" ] || [ ! -d "$_ar_cache_dir" ] || [ ! -O "$_ar_cache_dir" ]; then
  echo "  NOTE: $_ar_cache_dir is not this user's private directory — the run's auth-failure cache is off" >&2
  _ar_cache_dir=""
fi
# `mkdir -m` only sets the mode on what it creates, so a directory surviving from a pre-0700
# release keeps its looser mode and passes every check above. Tighten unconditionally.
[ -n "$_ar_cache_dir" ] && chmod 700 "$_ar_cache_dir" 2>/dev/null
PROVIDER_FAIL_CACHE="${_ar_cache_dir:+$_ar_cache_dir/}failed-providers.${_ar_cache_key//[^A-Za-z0-9._-]/_}"
# No private dir => no cache, rather than a write to a guessable path.
[ -n "$_ar_cache_dir" ] || PROVIDER_FAIL_CACHE="/dev/null"
return 0
}

# ─── Host platform detection (prevent self-review) ────────────────

detect_host_platform() {
  # Returns the provider name that matches the HOST IDE/CLI.
  # Self-review (Gemini reviewing Gemini, Codex reviewing Codex) produces
  # low-value findings and can cause auth/process conflicts.

  # Claude Code: sets CLAUDECODE=1
  [[ "${CLAUDECODE:-}" == "1" ]] && echo "claude" && return

  # Codex CLI / Codex Desktop — any of the four host signals (zms_is_codex_host). Without the shared
  # runner the codex lanes cannot run at all, so there is nothing to exclude.
  if [[ -n "$ZMS_LOADED" ]] && zms_is_codex_host; then
    # Like claude, codex has multiple models (gpt-5.4 "codex-5.4" vs gpt-5.5
    # "codex-5.3"). Exclude only the SAME model as the host so a DIFFERENT codex model still
    # reviews cross-model, instead of dropping codex wholesale. The host model is CODEX_MODEL or
    # the TOP-LEVEL model= of config.toml (zms_codex_host_model — a `[profiles.*]` model= is not
    # the active one); default to the newer model when unknown, so the spark reviewer (codex-5.3,
    # in the auto-list) stays.
    local hm=""
    hm="$(zms_codex_host_model)" || hm=""
    case "$hm" in
      *spark*|*5.3*) echo "codex-5.3" && return ;;   # host = spark -> exclude spark
      "") # unknown host model -> default to newer (keep spark as reviewer), but do NOT be SILENT
          echo "  NOTE: codex host model unknown (no CODEX_MODEL / no top-level model= in config.toml) — assuming gpt-5.4, reviewing with spark codex-5.3. Export CODEX_MODEL to guarantee cross-model (a spark host here would be spark-reviews-spark)." >&2
          echo "codex-5.4" && return ;;
      *)  echo "codex-5.4" && return ;;              # host = 5.4/5.5 -> exclude 5.4 (spark stays as reviewer)
    esac
  fi

  # Qwen Code: its shell tool exports QWEN_CODE=1 into every command it runs (read from the
  # v0.20.0 bundle, the same env block that sets TERM). A review launched from inside Qwen Code
  # must not hand the diff back to Qwen. This function answers with the FIRST host it recognises,
  # so the order is the rule: a CLI's own variable (CLAUDECODE, the Codex signals, QWEN_CODE) names
  # the process that is actually running and outranks both the IDE terminal it may sit in (the
  # VSCODE_GIT_ASKPASS_MAIN checks below — Qwen Code run inside a Cursor terminal used to be
  # reported as Cursor, so qwen was never excluded) and the Kimi PATH heuristic.
  # Like the Antigravity and Kimi hosts below, every lane that reaches the host's model goes: the
  # `openrouter` lane's default model is a Qwen model, and through it Qwen would review Qwen.
  if [[ "${QWEN_CODE:-}" == "1" ]]; then
    # Matched by model FAMILY anywhere in the id, any case — an author prefix other than `qwen/`
    # still serves a Qwen model.
    case "$(lane_model openrouter)" in
      *[Qq][Ww][Ee][Nn]*) echo "qwen openrouter" ;;
      *)                  echo "qwen" ;;
    esac
    return
  fi

  # Antigravity (Google IDE): VS Code fork with Antigravity in app paths. The host's own model is
  # Gemini. A host is a SET of clients, not one name, so this returns every lane that could reach
  # that model. Be precise about which are live HERE: `agy` is a real provider in this script;
  # `gemini` is NOT (see the lane router, _dispatch_provider_inner — no `gemini`, no `run_gemini`, and the
  # `gemini-api` curl lane was dropped 2026-08-04 with the free-tier CLI). It is named anyway as a
  # defensive placeholder — filtered against a list that cannot contain it, and the hole stays shut
  # if `gemini` is ever re-added. The live instance of this bug is in blind-audit-codex.sh, which
  # DOES dispatch `gemini`: excluding only `gemini` there left `agy` free to audit its own host,
  # exclusion applied and announced (fixed 2026-08-11 as HOST_EXCLUDE="gemini agy").
  if [[ "${VSCODE_GIT_ASKPASS_MAIN:-}" == *"Antigravity"* ]] \
     || [[ "${VSCODE_GIT_ASKPASS_MAIN:-}" == *"antigravity"* ]] \
     || [[ -n "${ANTIGRAVITY_SESSION_ID:-}" ]]; then
    echo "agy gemini" && return
  fi

  # Cursor: VS Code fork with Cursor in app paths
  if [[ "${VSCODE_GIT_ASKPASS_MAIN:-}" == *"Cursor"* ]] \
     || [[ "${VSCODE_GIT_ASKPASS_MAIN:-}" == *"cursor"* ]]; then
    echo "cursor-agent" && return
  fi

  # Kimi Code: unlike every other host, it exports NO identifying variable into the tool
  # subprocess — verified empirically 2026-08-12 by dumping `env` from inside its own Bash
  # tool (v0.35.0): the ONLY difference is that it prepends its bin dir to PATH. So that is
  # the signal, checked last because it is the weakest one.
  #
  # BOTH kimi lanes are excluded, not just `kimi`. Naming one and leaving the other is the
  # exact bug the Antigravity comment above records (excluding `gemini` left `agy` auditing
  # its own host); `kimi-api` reaches the same model by a different route.
  #
  # Known false-positive, accepted deliberately: a user with ~/.kimi-code/bin in their login
  # PATH is detected as Kimi anywhere. That costs one reviewer and can NEVER cause
  # self-review — the failure this whole function exists to prevent — so it errs safe.
  case ":${PATH}:" in
    *":$HOME/.kimi-code/bin:"*) echo "kimi kimi-api" && return ;;
  esac

  echo ""
}

# ar_exclude_host_lanes — HOST_PROVIDER and the lanes excluded so the host never reviews itself.
ar_exclude_host_lanes() {
HOST_PROVIDER=$(detect_host_platform)
# --mode blind-audit excludes the host's whole VENDOR (bap_vendor_excluded): the audit is cross-vendor,
# so a Claude host drops claude as well — the Opus<->Sonnet flip below is for the review modes only.
_host_lanes="$HOST_PROVIDER"; HOST_EXCLUDED=""
if [[ "$REVIEW_MODE" == blind-audit && -n "$HOST_PROVIDER" ]]; then
  case "$HOST_PROVIDER" in
    claude) _ba_host=claude ;;  codex-*) _ba_host=codex ;;  agy*) _ba_host=antigravity ;;
    cursor-agent) _ba_host=cursor ;;  kimi*) _ba_host=kimi ;;  qwen*) _ba_host=qwen ;;  *) _ba_host="" ;;
  esac
  # The vendor's lanes ADD to the lanes detection named, never replace them: a Qwen host also names
  # `openrouter` while that lane serves a Qwen model, and the vendor table alone would let it audit.
  if [[ -n "$_ba_host" ]]; then _host_lanes="$HOST_PROVIDER $(bap_vendor_excluded "$_ba_host")"
  else echo "  WARN: blind audit: host '$HOST_PROVIDER' has no vendor mapping — excluding only its own lane (fail closed)" >&2; fi
fi
# NB: this used to also require `-z "$EXCLUDE_PROVIDER"`, so passing --exclude for an
# unrelated reason (rotation) silently turned self-review prevention OFF and let the host
# audit its own output. Host exclusion is a safety property, not a default to be displaced
# by a user flag — it now ADDS to the set. ar_apply_excludes already documented this as the
# intended behaviour ("host auto-exclusion + --exclude flag").
if [[ -n "$HOST_PROVIDER" ]]; then
  if [[ "$HOST_PROVIDER" == "claude" && "$REVIEW_MODE" != blind-audit ]]; then
    # KEEP claude on a Claude host: run_claude reviews with the OPPOSITE model
    # (Opus author -> Sonnet reviewer, and vice versa), so it is genuinely cross-model,
    # NOT self-review. Excluding it threw away the local Opus<->Sonnet independent check
    # and degraded to single_provider_only when external CLIs were down. agy/codex/cursor
    # DO review with the same model as their host IDE, so those stay auto-excluded below.
    echo "  Host detected: claude -- KEPT as cross-model reviewer (run_claude flips Opus<->Sonnet)" >&2
  else
    # HOST_PROVIDER may name SEVERAL clients (Antigravity fronts both `agy` and `gemini`),
    # so iterate — a scalar test here would compare against the literal "agy gemini".
    _added="$(lanes_filter drop "$_host_lanes" "$EXCLUDE_PROVIDER")"
    EXCLUDE_PROVIDER="${EXCLUDE_PROVIDER:+$EXCLUDE_PROVIDER${_added:+ }}$_added"
    HOST_EXCLUDED="$_added"   # appended AFTER --exclude's lanes: the no-provider message splits on that
    if [[ -n "$_added" ]]; then
      echo "  Host detected: $HOST_PROVIDER -- auto-excluding $_added to prevent self-review" >&2
    else
      echo "  Host detected: $HOST_PROVIDER -- already excluded by --exclude, no change" >&2
    fi
  fi
fi
return 0
}

# ─── Provider detection ─────────────────────────────────────────

detect_providers() {
  # Test-only escape hatch (must be first): when BOTH ZUVO_ADVERSARIAL_TEST_HARNESS=1
  # AND ZUVO_REVIEW_TEST_PROVIDERS are set, bypass CLI auto-detection and return the
  # configured list verbatim. Two-variable guard prevents accidental activation by a
  # single leaked/compromised env var. Used only by tests/adversarial/ harness.
  if [[ "${ZUVO_ADVERSARIAL_TEST_HARNESS:-}" == "1" && -n "${ZUVO_REVIEW_TEST_PROVIDERS:-}" ]]; then
    echo "$ZUVO_REVIEW_TEST_PROVIDERS"
    return 0
  fi

  # Returns space-separated list of available providers in MEASURED priority order.
  #
  # The order is not taste — it is the ranking measured over ~43k provider invocations in
  # ~/.zuvo/adversarial.log (30 days to 2026-08-19, mock + fixture rows excluded, and
  # `not-attempted` rows excluded from the denominator so a provider is judged only on the
  # calls it actually received):
  #
  #   provider  attempted  ok%  timeout%  empty%  find/ok  crit/ok  CRIT PER ATTEMPT  p50   p90
  #   cursor         5648  87%       2%     11%     6.85     1.02        0.89          53s   93s
  #   agy            5489  53%       9%     38%     4.89     1.42        0.75          69s  200s
  #   claude         5286  97%       3%      0%     2.05     0.39        0.38         145s  240s
  #   kimi           5299  48%      11%     41%     5.12     0.65        0.31         133s  208s
  #   codex          5946  87%       1%     12%     2.44     0.33        0.29          38s   61s
  #
  # cursor-agent leads on every axis that matters (yield, reliability, latency). agy finds the
  # densest CRITICALs but is the flakiest and owns the slow tail. codex finds little but costs
  # 38s and almost never fails — cheap breadth, which is why it holds the third slot over the
  # nominally higher-yield claude: subset simulation over the same window shows
  # agy+codex+cursor covering 91.9% of runs that produced ANY critical and 90.6% of runs that
  # produced any finding, versus 91.4%/83.1% for agy+claude+cursor. claude and kimi rank last:
  # claude is the lowest-yield reviewer AND sets the wall-clock in 30-36% of runs, kimi returns
  # nothing 41% of the time.
  #
  # This order also drives --single (first success wins) and --rotate (pool to shuffle), so a
  # 1-provider host now gets the best reviewer rather than merely the first-installed one.
  local providers=""

  # 1. cursor-agent — highest yield AND highest reliability AND fast (p50 53s)
  command -v cursor-agent &>/dev/null && providers="cursor-agent"

  # 2. Google Gemini — agy (Antigravity CLI, paid) only. The free `gemini` CLI is dead for
  #    individuals (IneligibleTierError: UNSUPPORTED_CLIENT -> "migrate to Antigravity") and the
  #    gemini-api curl fallback needs a billing-enabled GEMINI_API_KEY that nothing in this fleet
  #    provisions — both lanes were pure dead weight, removed 2026-08-04. agy is now the ONLY
  #    Gemini path, so the self-review guard collapses to excluding just that one provider: on an
  #    Antigravity host (HOST_PROVIDER=agy) skip it, exactly like the cursor/codex self-exclusions
  #    around it. Densest CRITICALs of any provider (1.42/ok) — worth its 38% empty rate.
  if [[ "${HOST_PROVIDER:-}" != "agy" ]] && command -v agy &>/dev/null; then
    providers="${providers:+$providers }agy"
  fi

  # 3. codex-5.3 — low yield but 87% ok at p50 38s, and a third vendor (OpenAI). Cheap breadth.
  #    Found the way run_codex will run it (client_available): ZUVO_CODEX_BIN, PATH, Codex.app.
  client_available codex && providers="${providers:+$providers }codex-5.3"
  # codex-5.4 is the HOST-FLIP SUBSTITUTE again, not a standing second slot — reverted
  # 2026-09-23 to one lane per vendor.
  #
  # It was promoted to the auto-list on 2026-09-01 because gpt-5.4 measured BETTER than the
  # primary (56 REAL @90% vs 42, 20/20 vs 18/20). That model no longer exists on this account,
  # the lane has been repointed twice since (gpt-5.5, now gpt-6-luna), and the measurement that
  # justified the promotion did not travel with it. Re-measured 2026-09-23, same 20 diffs, same
  # Opus judge: primary (gpt-6-sol/none) 38 REAL and 5 defects nobody else finds; this lane
  # (gpt-6-luna/medium) 14 REAL and 2. The ordering is now reversed.
  #
  # Two codex lanes are two of the five fan-out slots spent on ONE vendor and ONE account, and
  # this project already settled that question: the Gemini lane rejected running two models for
  # +9 unique defects because "cross-VENDOR spread is where the coverage comes from"
  # (model-registry.sh). +2 does not clear a bar that +9 failed. A weak lane is not free — it
  # displaces a stronger one from a fixed-size panel.
  #
  # NOT auto-offered at all, including on a codex host. The host-flip argument for keeping it
  # there does not survive being stated plainly: on a codex host, self-review exclusion removes
  # codex-5.3, and adding codex-5.4 back puts a SECOND OpenAI model in a panel whose whole job
  # is to not be the host's model. The remaining ten lanes are a stronger cross-model review
  # than one of them being OpenAI again.
  #
  # The flip exists from when this driver had a handful of providers and losing one risked
  # `single_provider_only` (exit 3). With eleven lanes that risk is gone, so the flip now buys
  # a worse panel to solve a problem that no longer occurs.
  #
  # The lane itself stays defined and reachable by `--provider codex-5.4` — the name is a token
  # in ~/.zuvo/adversarial.log, in the health ledger and in tests, so it is kept rather than
  # deleted. Verified 2026-09-23: WORKING, 23s, gpt-6-luna.

  # 4. openrouter — PAID, and therefore opt-in by an explicit env flag, never by key presence.
  # A key file on disk is not consent to spend on every review: this one exists because of a
  # benchmark, and auto-detecting on it would silently turn a free pipeline into a metered one.
  # ZUVO_ADV_OPENROUTER=1 is a deliberate act a human performs once; the key alone is not.
  # Default roster: openrouter-alt (mimo-v2.6-flash), openrouter-3 (mercury), openrouter-4 (gpt-oss) — models from model-registry.sh.
  # glm-5.3 is in NEITHER — it is reachable only by ZUVO_MODEL_OPENROUTER_ALT=z-ai/glm-5.3
  # with an explicit --provider. It cost $0.134 per call against muse's $0.035 and, at 363s
  # against the ceiling, 36% of those calls were metered and returned nothing.
  # Removing a model from the PRIMARY slot does not remove it from the run — the alt slot is
  # a second list and has to be checked too. That mistake kept glm billing for two extra days.
  #
  # Cost, measured in PRODUCTION rather than in the benchmark (2026-09-05, one day):
  #   glm-5.3   143 calls, 72% returned findings, $12.10 billed
  #   qwen3.8   91 calls,  35% returned findings (46 empty, 13 timeouts)
  # glm earns its findings and costs too much to leave always on; qwen is cheap and mostly
  # does not answer, because it averages 336s against this script's 400s PROVIDER_TIMEOUT.
  # Hence: the flag stays OFF by default fleet-wide and is set per run when a review earns it.
  # The benchmark rated qwen a bargain because it ran under a 900s ceiling — a benchmark
  # ceiling looser than production turns a latency problem into an invisible one.
  # 2026-09-23: the lane list narrowed from four to TWO, because two of the four stopped being
  # worth their price the moment the same models became reachable without a meter:
  #   openrouter      qwen/qwen3.8-flash        $0.0331/call  -> DROPPED: the `qwen` lane runs
  #                                                              Qwen directly on the owner's
  #                                                              Alibaba plan (ZUVO_ADV_QWEN=1).
  #   openrouter-alt  deepseek/deepseek-v4.1-flash $0.0241/call -> DROPPED: byteplus-alt runs
  #                                                              deepseek inside the prepaid
  #                                                              BytePlus plan, at no meter.
  #   openrouter-3    inception/mercury-2.5-preview $0.0007/call -> KEPT
  #   openrouter-4    openai/gpt-oss-120b           $0.0008/call -> KEPT
  # The two kept lanes each contribute 13 defects the free set does not find, for less than a
  # tenth of a cent per call. Their precision (28-32%) is bad and does not disqualify them here:
  # a false positive dies in triage, a missed defect ships, and at this price the asymmetry is
  # the whole argument. The two dropped lanes were paying a meter for coverage already owned.
  #
  # Override with ZUVO_ADV_OPENROUTER_LANES="openrouter openrouter-alt" to bring them back for
  # one run — the models are unchanged in model-registry.sh, only the default roster moved.
  # 2026-10-07: openrouter-alt is back in the default roster with a NEW model, xiaomi/mimo-v2.6-flash —
  # +17 defects over the production lineup at ~$0.0063 per review (benchmark 2026-10-04/05, 92%/83%
  # precision). The two ultra-cheap lanes stay: they are coverage, and a third lane does not replace them.
  if [[ "${ZUVO_ADV_OPENROUTER:-0}" == "1" ]]; then
    if [[ -n "${OPENROUTER_API_KEY:-}" || -f "$HOME/.zuvo/openrouter.key" ]]; then
      providers="${providers:+$providers }${ZUVO_ADV_OPENROUTER_LANES:-openrouter-alt openrouter-3 openrouter-4}"
    else
      echo "  NOTE: ZUVO_ADV_OPENROUTER=1 but no key (env OPENROUTER_API_KEY or ~/.zuvo/openrouter.key) — lane skipped" >&2
    fi
  fi

  # 4b. BytePlus ModelArk Coding Plan — a PREPAID subscription, not metered, so the cost shape
  # is the opposite of OpenRouter's: a review costs nothing extra until the plan's quota runs
  # out, and then it hard-stops rather than spilling onto the account balance ("Other packages
  # or account balances will not be consumed" — the vendor's FAQ). Still opt-in by an explicit
  # flag, for a different reason than price: that quota is SHARED with whatever the owner points
  # at the same plan (their own Claude Code, Cursor, …), and a fleet doing hundreds of reviews a
  # day would be spending someone's coding allowance without being asked.
  # Headroom, from the plan's own limits: Lite ~1,200 requests / 5h, Pro ~6,000. Measured fleet
  # peak is 640 agy calls in a day, so Lite carries a standing lane with room to spare — unlike
  # Antigravity, whose ~12 calls / 5h made it a fallback only.
  if [[ "${ZUVO_ADV_BYTEPLUS:-0}" == "1" ]]; then
    if [[ -n "${BYTEPLUS_API_KEY:-}" || -f "${ZUVO_BYTEPLUS_KEY_FILE:-$HOME/.zuvo/byteplus.key}" ]]; then
      # byteplus-alt (deepseek-v4-flash) is out of the default set since 2026-09-25: 36% precision
      # on the 20-input bench, 3 defects no other lane finds, and 41 timeouts in 288 calls over
      # the preceding 24 h. Still reachable by name, or back via ZUVO_ADV_BYTEPLUS_LANES.
      providers="${providers:+$providers }${ZUVO_ADV_BYTEPLUS_LANES:-byteplus byteplus-3}"
    else
      echo "  NOTE: ZUVO_ADV_BYTEPLUS=1 but no key (~/.zuvo/byteplus.key) — lane skipped" >&2
    fi
  fi

  # 4. claude — opposite-model reviewer (Anthropic; run_claude flips Opus<->Sonnet). Most
  #    reliable client on the box, but the lowest-yield reviewer and the usual wall-clock setter.
  client_available claude && providers="${providers:+$providers }claude"

  # 4c. Muse Code (`muse`) — a CLI, so no metered hop and no key to manage. Its model family
  # measured 73% precision and +15 unique defects on the shared 20-diff bench (third best in the
  # field), which is well above every lane below it here. Placed after the free/plan lanes and
  # before kimi on that number. No self-review guard is needed: no host in this fleet runs under
  # Muse, and it is a distinct vendor from claude/codex/cursor/agy.
  command -v muse &>/dev/null && providers="${providers:+$providers }muse"

  # 5. Moonshot Kimi — strict priority: kimi CLI (OAuth subscription, K3) > kimi-api (curl,
  #    needs MOONSHOT_API_KEY). Distinct vendor/model family from every host we run under
  #    (claude/codex/cursor/agy) — no self-review guard. Last: returns nothing 41% of the time.
  if command -v kimi &>/dev/null; then
    providers="${providers:+$providers }kimi"
  elif [[ -n "${MOONSHOT_API_KEY:-}" ]]; then
    providers="${providers:+$providers }kimi-api"
  fi

  # 6. Qwen Code CLI on an Alibaba Model Studio plan (Token Plan or Coding Plan) — opt-in, never
  #    by presence alone. Two reasons, and price is not one of them (both plans are prepaid and
  #    hard-stop when spent):
  #      * Coding Plan's terms: "Do not use the plan's API key for automated scripts … or any
  #        non-interactive, batch-calling scenarios. Such use … may result in the suspension of
  #        your subscription or the disabling of your API key." Going through the vendor's own
  #        coding CLI is the least-bad route, not a sanctioned one — that is the owner's call to
  #        make once, not something a `qwen` binary on PATH should decide for them;
  #        (Token Plan's docs carry no such clause, but the lane cannot tell which plan it is on.)
  #      * the quota is shared with the owner's interactive use.
  if [[ "${ZUVO_ADV_QWEN:-0}" == "1" ]]; then
    if command -v qwen &>/dev/null; then
      providers="${providers:+$providers }qwen"
    else
      echo "  NOTE: ZUVO_ADV_QWEN=1 but no qwen CLI on PATH (npm i -g @qwen-code/qwen-code) — lane skipped" >&2
    fi
  fi

  # Manual-only providers (use --provider <name>):
  # codex-5.4 — slower, overlaps with 5.3
  # codestral — requires CODESTRAL_API_KEY, weaker findings

  echo "$providers"
}

# ar_list_providers_if_asked — --list-providers (review modes): print the detected clients and exit 0.
ar_list_providers_if_asked() {
# Single source of client detection, exposed as a query. reviewer-preflight.sh kept
# its own hand-written `for candidate in codex gemini agy claude`, which knew nothing
# about cursor-agent or kimi and nothing about the /Applications/Codex.app fallback —
# so the blind audit could reach fewer reviewers than the adversarial pass on the SAME
# machine. Model IDs were unified into shared/includes/model-registry.sh long ago;
# client DETECTION never was. Placed here because bash needs the function defined
# before it is called, and input collection above already skips for this flag.
# (--mode blind-audit lists AFTER its exclusions instead — below: its candidates are the panel's.)
if [[ "$LIST_PROVIDERS" == "true" && "$REVIEW_MODE" != blind-audit ]]; then
  detect_providers | tr ' ' '\n' | sed '/^$/d'
  exit 0
fi
return 0
}

# ar_resolve_candidates — PROVIDERS from a validated --provider or from detection; DETECTED_PROVIDERS.
ar_resolve_candidates() {
if [[ -n "$PROVIDER" ]]; then
  # Reject an unknown provider HERE, loudly, instead of letting it flow into
  # dispatch where the `*)` arm just `return 1`s and the run reports the generic
  # "all providers failed". That message sends you looking for an auth or network
  # problem when the real cause is a typo — or, since 2026-08-04, a name that no
  # longer exists: `--provider gemini` was valid for a long time and is in
  # muscle memory, so the removal makes this the most likely wrong value anyone
  # passes. Naming the removed lane explicitly turns a dead end into a redirect.
  case "$PROVIDER" in
    gemini|gemini-api)
      echo "ERROR: provider '$PROVIDER' was removed on 2026-08-04." >&2
      echo "  Google discontinued the free gemini CLI for individuals; use 'agy'" >&2
      echo "  (Antigravity), which is the sanctioned Gemini channel." >&2
      exit 2 ;;
    codex-5.3|codex-5.4|agy|cursor-agent|kimi|kimi-api|codestral|claude|openrouter|openrouter-alt|openrouter-3|openrouter-4|byteplus|byteplus-alt|byteplus-3|muse|qwen) ;;
    # `mock-*` is the test harness's provider namespace (tests/adversarial/mocks/,
    # reachable only under ZUVO_ADVERSARIAL_TEST_HARNESS). The first cut of this
    # allowlist omitted it and broke D3.4, which drives `--provider mock-success`
    # directly — a validation that rejects the suite exercising it is a worse bug
    # than the typo it was added to catch.
    mock-*) ;;
    *)
      echo "ERROR: unknown provider '$PROVIDER'." >&2
      echo "  Valid: codex-5.3, codex-5.4, agy, cursor-agent, kimi, kimi-api, codestral, claude, muse, qwen" >&2
      exit 2 ;;
  esac
  PROVIDERS="$PROVIDER"
else
  PROVIDERS=$(detect_providers)
fi
DETECTED_PROVIDERS="$PROVIDERS"   # before any exclusion: the no-provider message names what was excluded
return 0
}

# ARGV_PROMPT_LANES — lanes whose client takes the review prompt, and so the diff, as an ARGUMENT (neither CLI
# reads one from a file), readable through ps by every user of the host. ZUVO_SHARED_HOST=1 leaves them out.
ARGV_PROMPT_LANES="agy kimi"

# ar_apply_excludes — drop the --exclude and host-excluded lanes from PROVIDERS.
ar_apply_excludes() {
# Apply EXCLUDE_PROVIDER globally (host auto-exclusion + --exclude flag).
# Previously only applied in --rotate mode — now filters in ALL modes.
if [[ -n "$EXCLUDE_PROVIDER" && -n "$PROVIDERS" ]]; then
  # EXCLUDE_PROVIDER is a SET (space-separated), matched by whole name (names hold regex-active characters:
  # codex-5.4); excluding EVERY candidate leaves an empty list for the no-provider message below.
  PROVIDERS="$(lanes_filter drop "$PROVIDERS" "$EXCLUDE_PROVIDER")"
fi
if [[ "${ZUVO_SHARED_HOST:-0}" == "1" && -n "$PROVIDERS" ]]; then
  _ar_argv="$(lanes_filter keep "$PROVIDERS" "$ARGV_PROMPT_LANES")"
  if [[ -n "$_ar_argv" ]]; then
    PROVIDERS="$(lanes_filter drop "$PROVIDERS" "$ARGV_PROMPT_LANES")"
    echo "  NOTE: ZUVO_SHARED_HOST=1 — not running $_ar_argv (the client takes the diff as an argument, readable through ps)" >&2
  fi
fi
return 0
}

# ar_apply_exclude_last — --exclude-last: drop the provider the previous rotation pass used.
ar_apply_exclude_last() {
# D4: --exclude-last filters out the named provider for cross-call rotation
# (caller threads providers_used[0] from prior JSON output back as --exclude-last).
# Validates: if non-empty and not in current PROVIDERS, log stderr warning but
# proceed (allows stale rotation state to not break the call).
if [[ -n "$EXCLUDE_LAST" && -n "$PROVIDERS" ]]; then
  if [[ -n "$(lanes_filter keep "$PROVIDERS" "$EXCLUDE_LAST")" ]]; then
    PROVIDERS="$(lanes_filter drop "$PROVIDERS" "$EXCLUDE_LAST")"
    echo "  Excluding from rotation: $EXCLUDE_LAST (--exclude-last)" >&2; EXCLUDE_LAST_APPLIED="$EXCLUDE_LAST"
  else
    echo "  WARN: --exclude-last value not in current provider list: $EXCLUDE_LAST (proceeding with full set)" >&2
  fi
fi
return 0
}

# ar_skip_auth_cached — drop lanes this run already found unauthenticated (never every lane).
ar_skip_auth_cached() {
# Run-scoped auth-failure cache: drop providers already proven unauthenticated in THIS run.
# A rotation is N invocations; without this, a dead subscription burns the full per-provider
# timeout on every one of them. Never filters down to zero — if every candidate is cached as
# failed, the cache is stale (subscription restored, token refreshed), so ignore it and retry:
# a slow review beats a review that silently stops running.
CACHED_FAILED=""
_fresh_auth="$(_ar_auth_cached_lanes)" || _fresh_auth=""
if [[ -n "$_fresh_auth" && -n "$PROVIDERS" ]]; then
  _kept="$(lanes_filter drop "$PROVIDERS" "$_fresh_auth")"
  if [[ -n "$_kept" ]]; then
    CACHED_FAILED="$(lanes_filter keep "$PROVIDERS" "$_fresh_auth")"
    [[ -n "$CACHED_FAILED" ]] && echo "  Skipping (auth failed earlier this run): $CACHED_FAILED" >&2
    PROVIDERS="$_kept"
  else
    echo "  WARN: every provider is in the run's auth-failure cache — ignoring it and retrying all." >&2
    : > "$PROVIDER_FAIL_CACHE"
  fi
fi
return 0
}

# Which Claude reviews. Opus only when the author is provably NOT Opus; Sonnet otherwise.
#   * host is another vendor (codex, kimi, qwen, cursor-agent, agy) -> the author is not a Claude
#     model at all, so Opus cannot be self-review. Until 2026-09-25 this case was never checked:
#     the rule looked only at CLAUDE_MODEL, which nobody sets, so every one of 850 claude-lane
#     calls on record went to Sonnet — including reviews launched from Codex, where the
#     strongest reviewer measured (Opus 5.5 high: +40 / 88% on the 20-input bench) was safe.
#   * CLAUDE_MODEL names sonnet/haiku -> Sonnet/Haiku author, Opus reviews.
#   * otherwise (Claude Code host, CLAUDE_MODEL unset) -> assume the common Opus author and review
#     with Sonnet: the safe default, since Opus-reviews-Opus is self-review.
# Prints "<model>" or "<model>\t<effort>". Used by run_claude AND provider_model, so the log row
# names the model that actually ran.
#
# Defined at module scope, so it exists before any phase reaches it through provider_model.
claude_reviewer_model() {
  if { [[ -n "${HOST_PROVIDER:-}" && "${HOST_PROVIDER}" != "claude" ]]; } \
     || [[ "${CLAUDE_MODEL:-}" == *sonnet* || "${CLAUDE_MODEL:-}" == *haiku* ]]; then
    printf '%s\n' "${ZUVO_MODEL_CLAUDE_REVIEWER_OPUS:-claude-opus-5-5}"
  else
    printf '%s\n' "${ZUVO_CLAUDE_REVIEWER_MODEL:-${ZUVO_MODEL_CLAUDE_REVIEWER_SONNET:-claude-sonnet-5-5}}"
  fi
}

# review_access — fills the CALLER's `access` array for a codex/claude review lane (bash scopes the
# assignment to the caller's `local access`). `read` needs a root: the repository the review runs in,
# or this directory outside one. Unknown values fall to `read`, the safer of the two non-defaults:
# whoever set the variable wanted the reviewer held back.
review_access() {
  case "${ZUVO_REVIEW_ACCESS:-agent}" in
    agent) access=(--access agent) ;;
    none)  access=(--access none) ;;
    read)  access=(--access read --read-root "$(ar_repo_root)") ;;
    *)     access=(--access read --read-root "$(ar_repo_root)") ;;
  esac
}
review_access_name() {
  case "${ZUVO_REVIEW_ACCESS:-agent}" in agent|none|read) echo "${ZUVO_REVIEW_ACCESS:-agent}" ;; *) echo read ;; esac
}

# lane_model <lane> — the model a lane is CONFIGURED to run: its env variable, which model-registry.sh sets to
# the measured default (and says why), else the fallback written here for a run whose registry did not load.
# The lanes, the router and provider_model all read it.
lane_model() {
  case "$1" in
    codex-5.4)    echo "${ZUVO_MODEL_CODEX_ALT:-gpt-6-luna}" ;;
    codex-5.3)    echo "${ZUVO_MODEL_CODEX_PRIMARY:-gpt-6-sol}" ;;
    agy)          echo "${ZUVO_AGY_MODEL:-${ZUVO_MODEL_AGY:-Gemini 3.8 Flash (Medium)}}" ;;
    openrouter)   echo "${ZUVO_OPENROUTER_MODEL:-${ZUVO_MODEL_OPENROUTER:-qwen/qwen3.8-flash}}" ;;
    openrouter-alt) echo "${ZUVO_MODEL_OPENROUTER_ALT:-xiaomi/mimo-v2.6-flash}" ;;
    openrouter-3) echo "${ZUVO_MODEL_OPENROUTER_3:-inception/mercury-2.5-preview}" ;;
    openrouter-4) echo "${ZUVO_MODEL_OPENROUTER_4:-openai/gpt-oss-120b}" ;;
    byteplus)     echo "${ZUVO_MODEL_BYTEPLUS:-glm-5.3-flash}" ;;
    byteplus-alt) echo "${ZUVO_MODEL_BYTEPLUS_ALT:-deepseek-v4-flash}" ;;
    byteplus-3)   echo "${ZUVO_MODEL_BYTEPLUS_3:-dola-seed-2.0-code}" ;;
    muse)         echo "${ZUVO_MUSE_MODEL:-${ZUVO_MODEL_MUSE:-muse-spark-1.3}}" ;;
    qwen)         echo "${ZUVO_QWEN_MODEL:-${ZUVO_MODEL_QWEN:-qwen3.8-flash}}" ;;
    codestral)    echo "${ZUVO_CODESTRAL_MODEL:-codestral-latest}" ;;
    kimi-api)     echo "${ZUVO_KIMI_MODEL:-${ZUVO_MODEL_KIMI:-kimi-k2.6}}" ;;
    kimi)         echo "${ZUVO_KIMI_CLI_MODEL:-${ZUVO_MODEL_KIMI_CLI:-kimi-code/k3-256k}}" ;;
    cursor-agent) echo "${ZUVO_CURSOR_MODEL:-${ZUVO_MODEL_CURSOR:-composer-2.5-fast}}" ;;
    claude)       claude_reviewer_model ;;
    *)            echo "unknown" ;;
  esac
}

# provider_model <lane> — the model a lane RAN, as it recorded it, else lane_model (before it runs: the bench, --doctor).
provider_model() {
  case "$1" in
    codex-5.4|codex-5.3)
                  # What codex_cli_guard left of the configured model, as run_codex recorded it.
                  _ar_recorded_model "codex-effective-model-$1" && return 0 ;;
    agy)          # The lane can switch models mid-run when the primary is out of quota, and the
                  # log row, the health ledger and every future bench are keyed on the MODEL. A
                  # run that fell back and still recorded the primary would read as "Gemini
                  # answered ok in 12s" while Gemini was out of quota for 17 hours and Opus 4.6
                  # wrote the review — measured 2026-09-22, the first live run after the fallback
                  # shipped. Passed through a FILE, not a variable: providers are dispatched in
                  # subshells, so an exported name set inside run_agy never reaches this caller.
                  _ar_recorded_model agy-effective-model && return 0 ;;
  esac
  lane_model "$1"
}

# _ar_recorded_model <file> — the model a lane recorded once it ran; status 1 if none, blank or with a control char.
_ar_recorded_model() {
  local m
  [[ -n "${JSON_TMPDIR:-}" ]] || return 1
  m="$(cat "$JSON_TMPDIR/$1" 2>/dev/null)" || return 1
  [[ -n "${m//[[:space:]]/}" && "$m" != *[[:cntrl:]]* ]] || return 1
  printf '%s\n' "$m"
}

# ledger_model <lane> — the model the health ledger keys a lane on, read by the bench BEFORE the run and the
# record AFTER: the model that ran (provider_model), except for codex, whose configured model codex_cli_guard
# lowers the same way on every run of this host — a bench before the run knows only the configured one.
ledger_model() {
  case "$1" in
    codex-5.4|codex-5.3) lane_model "$1" ;;
    *)                   provider_model "$1" ;;
  esac
}

# lane_model_ok <lane> <id> — an id that is empty, flag-like (a leading -) or has characters outside
# [a-zA-Z0-9._/@:-] is refused with a WARN, status 1 — never repaired into a model the label does not name.
lane_model_ok() {
  case "$2" in
    ""|-*|*[!a-zA-Z0-9._/@:-]*)
      echo "  WARN: $1 model id '${2//[[:cntrl:]]/?}' is empty, flag-like or has characters outside [a-zA-Z0-9._/@:-] — refusing" >&2
      return 1 ;;
  esac
}

# ar_bench_failing_lanes — ALL_DETECTED_PROVIDERS, then bench the lanes the health ledger shows failing.
ar_bench_failing_lanes() {
# Pelna lista wykrytych dostawcow, zanim bench i limit fan-outu ja zwezą. --doctor musi
# widziec KOMPLET: to diagnostyka, a probkowanie w diagnostyce daje najgorszy mozliwy wynik —
# raport, ktory wyglada na pelny i nim nie jest. Zmierzone 2026-09-11: doktor zbadal 5 z 9
# i wypisal "usable providers: 5 / 5", pomijajac m.in. kimi — czyli dokladnie tego recenzenta,
# ktorego brak wywolal cala diagnoze.
ALL_DETECTED_PROVIDERS="$PROVIDERS"

# ─── Bench providers with a persistent failure record ───────────────────────
# Applied BEFORE the fan-out cap so a benched provider's slot is drawn by a healthy one.
# Three rules, each of which exists because the obvious version of this is a trap:
#
#  1. COOLDOWN, not a ban. A provider is benched for ZUVO_PROVIDER_BENCH_COOLDOWN (default 6h)
#     after its Nth consecutive failure, then gets one probe. A permanent ban would mean a
#     restored subscription or a transient outage silently costs a reviewer forever, and
#     nothing in the system would ever tell you.
#  2. The counter resets ONLY on a real ok. A probe that fails again re-arms the cooldown, so
#     a genuinely dead lane is asked roughly four times a day instead of on every run.
#  3. NEVER bench everything — same fail-open rule as the auth cache. If every candidate is
#     benched the ledger is more likely wrong than the whole fleet being down; a slow review
#     beats a review that silently stopped running.
# The PINNED provider is benched too. Pinning a corpse is worse than not pinning at all.
# Under the test harness the ledger must NOT be shared (one case's mock failures would bench the next): no
# ledger (empty path: no bench, nothing recorded); a test that examines benching passes ZUVO_PROVIDER_HEALTH_FILE.
if [[ -n "${ZUVO_PROVIDER_HEALTH_FILE:-}" ]]; then
  PROVIDER_HEALTH_FILE="$ZUVO_PROVIDER_HEALTH_FILE"
elif [[ "${ZUVO_ADVERSARIAL_TEST_HARNESS:-0}" == "1" ]]; then
  PROVIDER_HEALTH_FILE=""
else
  # ZUVO_HOME like the run log and the failure evidence: a test that sets it no longer writes the
  # real ~/.zuvo ledger (default unchanged).
  PROVIDER_HEALTH_FILE="${ZUVO_HOME:-$HOME/.zuvo}/provider-health.tsv"
fi
# Its directory first: when it does not exist yet every ledger write fails SILENTLY — never benched.
if [[ -n "$PROVIDER_HEALTH_FILE" && ! -f "$PROVIDER_HEALTH_FILE" ]]; then
  case "$PROVIDER_HEALTH_FILE" in */?*) mkdir -p -- "${PROVIDER_HEALTH_FILE%/*}" 2>/dev/null || true ;; esac
  : > "$PROVIDER_HEALTH_FILE" 2>/dev/null || true
fi
_bench_thr="$(ar_env_int ZUVO_PROVIDER_BENCH_THRESHOLD 3)"
_bench_cd="$(ar_env_int ZUVO_PROVIDER_BENCH_COOLDOWN 21600)"
# SOFT cooldown — the same ledger, a shorter bench, for failures that are not the lane's fault.
#
# Measured 2026-09-22: codex-5.3 and codex-5.4 both flipped from `ok` to `empty` in the SAME
# second (09:36:46) and returned in 6s. Two different models, one instant, a fast local error —
# a CLI/account hiccup that lasted ~15 minutes. The flat 6h cooldown then held BOTH OpenAI lanes
# out of every review for six hours; a probe an hour later answered in 11s. Six benched pairs
# out of fourteen were in that state when this was written, two of them healthy.
#
# A timeout is different in kind and keeps the full cooldown: a lane that cannot finish inside
# PROVIDER_TIMEOUT is structurally wrong for this pipeline, not unlucky (qwen3.8-flash, 4 runs
# at exactly 500s). So is an auth failure, and an exhausted plan (`quota`: kimi's 5-hour window
# at best, its weekly one at worst — a soft 45-min retry would just spend a call on a known
# refusal). And a lane that has failed many times running is not
# having a bad minute — past _bench_hard_at consecutive failures the full cooldown returns
# (kimi: 32 consecutive empties).
_bench_cd_soft="$(ar_env_int ZUVO_PROVIDER_BENCH_COOLDOWN_SOFT 2700)"
_bench_hard_at="$(ar_env_int ZUVO_PROVIDER_BENCH_HARD_AFTER 8)"
if [[ "${ZUVO_PROVIDER_BENCH:-1}" == "1" && -s "$PROVIDER_HEALTH_FILE" && -n "$PROVIDERS" ]]; then
  _now=$(date +%s)
  # Keyed on the (lane, model) PAIR (ledger_model): a failure belongs to the MODEL, and a new model is a new reviewer.
  _pairs=""
  for _bp in $PROVIDERS; do
    _pairs="${_pairs}${_bp}	$(ledger_model "$_bp")
"
  done
  # Column 5 (last outcome) is OPTIONAL: rows written before it existed have four fields and
  # get the soft cooldown, which is the safe direction — a healthy lane returns sooner and a
  # broken one re-benches itself on its next failure at the cost of one cheap call.
  _benched=$(printf '%s' "$_pairs" | awk -F'\t' -v thr="$_bench_thr" -v cd="$_bench_cd" \
      -v cds="$_bench_cd_soft" -v hard="$_bench_hard_at" \
      -v now="$_now" -v hf="$PROVIDER_HEALTH_FILE" '
    BEGIN{ while((getline l < hf) > 0){ n=split(l, f, "\t")
             if(n<4 || f[3]+0 < thr) continue
             last = (n>=5 ? f[5] : "")
             wait = (last=="timeout" || last=="auth" || last=="quota" || f[3]+0 >= hard) ? cd : cds
             # A failure dated after now (written before the clock was set back) does not bench the
             # lane: its "age" is negative, which passed `< wait` for however far the clock had moved.
             if(f[4]+0 <= now && (now - f[4]) < wait) bad[f[1] SUBSEP f[2]]=1 }
           close(hf) }
    NF>=2 && (($1 SUBSEP $2) in bad) { print $1 }')
  if [[ -n "$_benched" ]]; then
    _healthy="$(lanes_filter drop "$PROVIDERS" "$_benched")"
    _dropped="$(lanes_filter keep "$PROVIDERS" "$_benched")"
    if [[ -n "$_healthy" && -n "$_dropped" ]]; then
      PROVIDERS="$_healthy"
      echo "  Benched (>=${_bench_thr} consecutive failures; retried after $((_bench_cd_soft/60))min, or $((_bench_cd/3600))h for a timeout/auth failure or >=${_bench_hard_at} in a row): $_dropped" >&2
    elif [[ -z "$_healthy" ]]; then
      echo "  WARN: every provider is benched — ignoring the health ledger and retrying all." >&2
    fi
  fi
fi
return 0
}

# _ar_rows <rows> <match col> <set> <in|out> <print col> — the <print col> of each "<index><TAB><name>" row
# whose <match col> is (in) or is not (out) one of <set> (words separated by blanks or commas).
_ar_rows() {
  printf '%s\n' "$1" | awk -F'\t' -v mc="$2" -v s="$3" -v want="$4" -v pc="$5" '
    BEGIN { n = split(s, a, /[ ,]+/); for (i = 1; i <= n; i++) if (a[i] != "") S[a[i]] = 1 }
    NF >= 2 && ((($mc) in S) == (want == "in")) { print $pc }'
}

# ar_cap_fanout — cap the fan-out: pinned lanes first, the remaining slots sampled at random.
ar_cap_fanout() {
# ─── Fan-out cap ────────────────────────────────────────────────────────────
# WHY: every available provider used to run, and five are installed here, so a single review
# fanned out to 5 CLIs. Measured over 30 days (~/.zuvo/adversarial.log): 9,613 adversarial
# invocations = 43,228 provider calls = 890M chars shipped to external providers and 387 hours
# of summed wall-clock, for 891 skill runs in the last week alone (~2.5 adversarial passes per
# skill run, ~12.6 provider calls). Capping at 5 bounds that per run. The cap SAMPLES the
# survivors at random rather than keeping the top N: bounding cost per run is its job, and
# permanently retiring the tail of the ranking is not. Truncation did the latter for free and
# nobody noticed until a billing graph showed one paid lane on every review — see the sampling
# block below for the numbers.
#
# Applied LAST, after host auto-exclusion / --exclude / --exclude-last / the auth-fail cache,
# so the sample is drawn from the providers still standing rather than from a set chosen
# before the host reviewer was removed. Skipped only for an explicit --provider (already one).
# It DOES apply to the test harness's injected list — that list stands in for what
# detect_providers() would return, so exempting it would leave the cap untestable; every
# existing suite injects <= 3 mocks and is unaffected.
_AR_CAP_VAR=ZUVO_REVIEW_MAX_PROVIDERS; _AR_CAP_DEFAULT=5
# --mode blind-audit sizes its PANEL instead (default 3; the global cap is ignored): pins + random fill.
if [[ "$REVIEW_MODE" == blind-audit ]]; then _AR_CAP_VAR=ZUVO_BLIND_AUDIT_PANEL; _AR_CAP_DEFAULT=3; fi
if [[ -z "$PROVIDER" && -n "$PROVIDERS" ]]; then
  # Through ar_env_int, minimum 1: `08` is 8, and a value that is not a number gets a WARN, never no cap.
  _AR_MAX_PROVIDERS="$(ar_env_int "$_AR_CAP_VAR" "$_AR_CAP_DEFAULT" 1)"
  _ar_avail=$(echo "$PROVIDERS" | wc -w | tr -d ' ')
  if [[ "$_ar_avail" -gt "$_AR_MAX_PROVIDERS" ]]; then
    # SAMPLED at random, not truncated to the top N. Truncation made the cap pick the SAME
    # providers on every single run: with 8 available and a cap of 5, ranks 6-8 (claude, kimi,
    # openrouter-alt) never executed once, so three configured reviewers were dead weight and
    # the paid openrouter lane at rank 5 billed on 100% of reviews ($12.10 of GLM 5.3 on
    # 2026-09-05 alone). A cap is meant to bound COST PER RUN, not to permanently retire the
    # tail of the ranking — over many runs every provider should get its turn, which is also
    # what keeps cross-model coverage from collapsing onto one fixed set of blind spots.
    # Sample first, then re-emit in ranking order so logs and --single stay readable.
    # Sample by INDEX, never by name. Filtering the list against a set of kept NAMES keeps
    # every duplicate of a kept name, so a list like "a a a b b" with cap 3 came back with all
    # five and the cap silently stopped existing. Production names are unique and the test
    # harness's are not, which is precisely the sort of gap that ships.
    _ar_idx=$(echo "$PROVIDERS" | tr ' ' '\n' | sed '/^$/d' | nl -ba -w1 -s'	')
    #
    # PINNED providers bypass the draw and always take a slot when they are present.
    # agy (Gemini 3.8 Flash) is pinned because it is the highest measured MARGINAL
    # contributor in the set: 32 defects that no other provider finds, against 17 for the
    # model it replaced (20 diffs, Opus-judged, shared defect vocabulary, 2026-09-05).
    # Leaving the biggest unique contributor to a coin flip loses coverage that nothing
    # else in the set can recover. Pinning is deliberately NOT "rank 1 always wins": it is
    # a per-provider decision backed by a marginal-coverage number, and the rest of the
    # slots stay random so the tail keeps getting its turn.
    # cursor-agent is pinned beside it (2026-09-25): the second-largest unique contributor in the
    # current set (17 defects no other lane finds), 100% ok over 367 calls in 24 h, 51 s median,
    # slowest lane in 7 of 367 runs — so pinning it costs no wall clock. It replaced a same-day pin
    # of qwen3.8-flash, which timed out at 500 s on 3 of 4 real 24-30k-char diffs: a pinned lane
    # that hangs sets the wall clock of EVERY run. Bench numbers on smaller inputs did not show it.
    # Override with ZUVO_REVIEW_PIN_PROVIDERS="a b" or "" to pin nothing.
    _ar_pin="${ZUVO_REVIEW_PIN_PROVIDERS-agy cursor-agent}"
    if [[ "${ZUVO_REVIEW_PROVIDER_PICK:-random}" == "ranked" ]]; then
      _ar_keep_idx=$(printf '%s\n' "$_ar_idx" | head -n "$_AR_MAX_PROVIDERS" | cut -f1)
    else
      # Pinned first (capped, in ranking order), then fill the remaining slots at random
      # from everything else. sort -R exists on BSD sort; --random-source does NOT, so the
      # reproducible path for tests is ZUVO_REVIEW_PROVIDER_PICK=ranked, never a seed.
      _ar_pin_idx=$(_ar_rows "$_ar_idx" 2 "$_ar_pin" in 1 | head -n "$_AR_MAX_PROVIDERS")
      _ar_pin_n=$(printf '%s' "$_ar_pin_idx" | grep -c . || true)
      _ar_fill=$(( _AR_MAX_PROVIDERS - _ar_pin_n ))
      if [[ "$_ar_fill" -gt 0 ]]; then
        _ar_rest_idx=$(_ar_rows "$_ar_idx" 2 "$_ar_pin" out 1 | sort -R | head -n "$_ar_fill")
      else
        _ar_rest_idx=""
      fi
      _ar_keep_idx=$(printf '%s\n%s\n' "$_ar_pin_idx" "$_ar_rest_idx" | sed '/^$/d' | sort -n)
    fi
    # Re-emit in ranking order: --single takes the head of this list, so a randomly ordered
    # sample would quietly turn --single into --rotate.
    _ar_sel=$(printf '%s\n' "$_ar_keep_idx" | tr '\n' ',' | sed 's/,$//')
    PROVIDERS=$(_ar_rows "$_ar_idx" 1 "$_ar_sel" in 2 | tr '\n' ' ' | sed 's/ *$//')
    _ar_dropped=$(_ar_rows "$_ar_idx" 1 "$_ar_sel" out 2 | tr '\n' ' ' | sed 's/ *$//')
    _ar_pinned_names=$(_ar_rows "$_ar_idx" 2 "${_ar_pin:-}" in 2 | tr '\n' ' ' | sed 's/ *$//')
    if [[ -n "$_ar_pinned_names" ]]; then
      echo "  Fan-out cap: $_AR_MAX_PROVIDERS of $_ar_avail ($PROVIDERS) — pinned: $_ar_pinned_names, rest sampled at random; not running this time: $_ar_dropped" >&2
    else
      echo "  Fan-out cap: $_AR_MAX_PROVIDERS of $_ar_avail sampled at random ($PROVIDERS); not running this time: $_ar_dropped" >&2
    fi
    echo "  (size with $_AR_CAP_VAR=N; ZUVO_REVIEW_PROVIDER_PICK=ranked for the old top-N behaviour)" >&2
  fi
fi
return 0
}

# ar_require_providers — ATTEMPTED_COUNT; no candidate left exits 1 with install hints.
ar_require_providers() {
# D2: ATTEMPTED_COUNT = post-exclusion candidate count. Used by JSON status logic
# and observability log. Set early so we have it regardless of which exit path runs.
ATTEMPTED_COUNT=$(echo "$PROVIDERS" | wc -w | tr -d ' ')

if [[ -z "$PROVIDERS" ]]; then
  echo "ERROR: No cross-provider review tool found." >&2
  # Which exclusion took which lanes (the host's are appended after --exclude's — see HOST_EXCLUDED).
  # A word-removal loop, not a `%` suffix trim: EXCLUDE_PROVIDER and HOST_EXCLUDED are both
  # space-separated lane lists, and a plain suffix trim only removes an EXACT trailing substring —
  # word order or overlap can leave a host-excluded lane misreported as user-excluded.
  _user_excl="$(lanes_filter drop "$EXCLUDE_PROVIDER" "$HOST_EXCLUDED")"
  [[ -z "$HOST_EXCLUDED" ]] || echo "Host platform auto-excluded: $HOST_EXCLUDED (self-review prevention)." >&2
  [[ -z "$_user_excl" ]] || echo "Excluded by --exclude: $_user_excl." >&2
  [[ -z "${EXCLUDE_LAST_APPLIED:-}" ]] || echo "Excluded by --exclude-last: $EXCLUDE_LAST_APPLIED (cross-call rotation)." >&2
  [[ -z "${BA_DROPPED:-}" ]] || echo "Excluded by the blind audit's own rules: $BA_DROPPED (reasons above)." >&2
  [[ -z "$DETECTED_PROVIDERS" ]] || echo "Every candidate ($DETECTED_PROVIDERS) was excluded — install a DIFFERENT vendor's CLI, or drop the exclusion:" >&2
  echo "" >&2
  cat >&2 <<'EOF'
Install one of these (in order of recommendation):

  1. Codex CLI (fastest, needs ChatGPT sub):
     npm install -g @openai/codex
     codex    # first run: login with ChatGPT

  2. agy — Antigravity CLI (Google's sanctioned Gemini channel, paid; the free
     `gemini` CLI is dead for individuals — IneligibleTierError):
     curl -fsSL https://antigravity.google/cli/install.sh | bash
     agy      # first run: login with Google account

  3. Claude CLI (needs Anthropic account):
     Already installed if you use Claude Code.

  4. Kimi CLI (Moonshot, OAuth subscription):
     See https://kimi.moonshot.ai for the CLI install, then `kimi` to log in.

  5. Codestral API (Mistral coding model):
     export CODESTRAL_API_KEY=<key from console.mistral.ai>
EOF
  exit 1
fi
return 0
}

# ar_resolve_dispatch_mode — MULTI_MODE and REQUESTED_MODE; --multi/--rotate with <2 lanes exits 3; --rotate shuffles.
ar_resolve_dispatch_mode() {
# ─── Determine mode ────────────────────────────────────────────

# Capture caller's original intent before mode normalization (rotate→single).
# Used by D3 single-provider refusal: --multi/--rotate signal explicit diversity
# request; falling back silently to single-provider violates that intent.
REQUESTED_MODE="$MULTI_MODE"
[[ "$REVIEW_MODE" != blind-audit || ! "$MULTI_MODE" =~ ^(single|rotate)$ ]] \
  || echo "  NOTE: --$MULTI_MODE is ignored in --mode blind-audit — the panel always runs in parallel" >&2

# If --provider is set, always single. Otherwise: default is multi.
# REQUESTED_MODE intentionally stays empty for the implicit-default case so D3
# refusal only fires when the user EXPLICITLY asked for diversity (--multi or
# --rotate). Implicit-default with 1 provider keeps the historical best-effort
# behavior (run the single provider, no surprise).
if [[ -n "$PROVIDER" ]]; then
  MULTI_MODE="single"
  REQUESTED_MODE="single"   # explicit --provider opts into single-provider risk
elif [[ -z "$MULTI_MODE" ]]; then
  MULTI_MODE="multi"
  # REQUESTED_MODE stays empty — see comment above.
fi
# --mode blind-audit always runs its panel in parallel; no D3 refusal (a panel of one is `degraded`, exit 3).
if [[ "$REVIEW_MODE" == blind-audit ]]; then MULTI_MODE="multi"; REQUESTED_MODE=""; fi

# D3: hard refusal when post-exclusion provider count < 2 AND caller EXPLICITLY
# requested multi-provider diversity (--multi or --rotate). Implicit-default does
# NOT refuse — REQUESTED_MODE stays empty in that path so a 1-provider host keeps
# the historical best-effort behavior. Exit code 3 = single_provider_only domain
# error (distinct from 1=no-provider, 2=provider-failed, 124=timeout).
if [[ "$ATTEMPTED_COUNT" -lt 2 && "$REQUESTED_MODE" =~ ^(multi|rotate)$ ]]; then
  cat >&2 <<EOF
ERROR: single_provider_only — --${REQUESTED_MODE} requires 2+ providers but only $ATTEMPTED_COUNT available after exclusions${EXCLUDE_PROVIDER:+ (host/--exclude: $EXCLUDE_PROVIDER)}.
Options:
  1. Install a second provider (codex, agy, cursor-agent, kimi, or claude CLI)
  2. Use --single to accept single-provider review explicitly
  3. Use --provider <name> to bypass multi-provider intent
EOF
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    jq -n \
      --arg status "single_provider_only" \
      --arg mode "$REVIEW_MODE" \
      --arg requested "$REQUESTED_MODE" \
      --arg providers "$PROVIDERS" \
      --argjson attempted "$ATTEMPTED_COUNT" \
      --arg excluded "$EXCLUDE_PROVIDER" \
      --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{status: $status, mode: $mode, requested: $requested, providers_available: $providers, attempted_count: $attempted, excluded: $excluded, findings: [], date: $date}'
  fi
  exit 3
fi

# Rotate mode: shuffle the provider list, then behave like single (--exclude: ar_apply_excludes).
if [[ "$MULTI_MODE" == "rotate" ]]; then
  PROVIDERS=$(echo "$PROVIDERS" | tr ' ' '\n' | sort -R | tr '\n' ' ' | sed 's/ *$//')
  MULTI_MODE="single"
fi
return 0
}
