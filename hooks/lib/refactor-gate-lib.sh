#!/bin/sh
# refactor-gate-lib.sh — zuvo:refactor commit-boundary safety gate (core logic).
#
# The ONLY agent-independent, cross-harness bind for the refactor pipeline: a git
# hook reads the refactor CONTRACT (the artifact of record) and BLOCKS a commit/push
# whose staged/pushed files intersect an ACTIVE refactor whose Prove step is not
# recorded complete. Prose says "MANDATORY"; this makes it true regardless of which
# agent (or harness) is driving — git hooks fire for everyone.
#
# Proven by docs/specs/2026-06-30-refactor-skill-rebuild-plan.md Task 1 spike (6/6).
# POSIX sh, jq-free. Fail-OPEN by contract: callers exit 0 on any internal error so a
# broken/absent gate can NEVER brick a user's `git commit`.
#
# refactor_gate_check "<newline-separated file list>"  -> 0 allow, 1 block
#   Env:
#     ZUVO_CONTRACTS_DIR   contracts dir (default zuvo/contracts)
#     ZUVO_PLANS_DIR       plans dir (default zuvo/plans)
#     ZUVO_GATE_TTL_SEC    stale-contract bypass TTL seconds (default 86400)
#     ZUVO_GATE_GRACE      execute run-marker freshness window (default 21600 = 6h)
#     ZUVO_HOME            run-marker root (default $HOME/.zuvo)
#     AI-harness markers   see _is_agent_env() — ANY set => AI run; NONE => human => bypass

refactor_gate_check() {
  staged=$1
  cdir=${ZUVO_CONTRACTS_DIR:-zuvo/contracts}
  [ -d "$cdir" ] || return 0
  ttl=${ZUVO_GATE_TTL_SEC:-86400}
  blocked=0
  for c in "$cdir"/refactor-*.json; do
    [ -f "$c" ] || continue
    grep -q '"stage"[[:space:]]*:[[:space:]]*"COMPLETE"' "$c" && continue
    # intersect scope_fence with the file list.
    #  set -f: a '*'/'?' in a path must NOT glob-expand against the filesystem.
    #  grep -Fq --: fixed-string match — a '.'/'['/']' in a path is a literal, not a regex
    #  (BRE would let 'src/[i].ts' match the wrong fence entry, or fail to match its own).
    hit=0
    oldifs=$IFS; IFS='
'
    set -f
    for f in $staged; do
      [ -n "$f" ] || continue
      if grep -Fq -- "\"$f\"" "$c"; then hit=1; break; fi
    done
    set +f
    IFS=$oldifs
    [ "$hit" = 1 ] || continue
    # HUMAN BYPASS — the gate is for AI runs; never lock a human out
    if ! _is_agent_env; then
      echo "zuvo refactor-gate: human committer (no AI-harness env) -> bypass [$c]" >&2
      continue
    fi
    # STALE BYPASS — an abandoned (crashed/timed-out) run must not block anyone
    now=$(date +%s)
    mt=$(_mtime "$c" "$now")
    if [ $((now - mt)) -gt "$ttl" ]; then
      echo "zuvo refactor-gate: stale contract (> ${ttl}s) -> bypass [$c]" >&2
      continue
    fi
    # PROVE checks — the CONTRACT is the artifact (commit is LAST, so no fix-commit exists yet)
    ba=$(sed -n 's/.*"blind_audit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$c" | head -1)
    av=$(sed -n 's/.*"adversarial"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$c" | head -1)
    # characterization lock: the pin-down tests proven green on the PRE-refactor code,
    # recorded in the CONTRACT BEFORE any move edit. Prose alone was skipped in the field
    # (skill-eval 2026-07-09: CONTRACT written at PHASE-1, next touched only at prove-time)
    # — so the gate enforces the artifact, same as blind_audit/adversarial.
    ch=$(sed -n 's/.*"characterization"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$c" | head -1)
    case "$ba" in skipped|not_run|"") echo "BLOCK: refactor CONTRACT prove.blind_audit='$ba' not satisfied [$c]"; blocked=1 ;; esac
    case "$av" in skipped|not_run|"") echo "BLOCK: refactor CONTRACT prove.adversarial='$av' not satisfied [$c]"; blocked=1 ;; esac
    case "$ch" in skipped|not_run|"") echo "BLOCK: refactor CONTRACT prove.characterization='$ch' not satisfied — record the pin-down lock (tests green on PRE-refactor code) when the suite goes green, BEFORE the move [$c]"; blocked=1 ;; esac
    # regression-red proof: required ONLY when Phase 3.5 actually APPLIED a fix (the
    # disposition names a fix). Two consecutive skill-eval runs (2026-07-10) showed agents
    # substituting "the flip logically implies red" for an actual red run — gate the artifact.
    fd=$(sed -n 's/.*"findings_disposition"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$c" | head -1)
    case "$fd" in
      *fix*)
        rr=$(sed -n 's/.*"regression_red"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$c" | head -1)
        case "$rr" in skipped|not_run|"") echo "BLOCK: refactor CONTRACT prove.regression_red='$rr' not satisfied — findings_disposition='$fd' says a fix was applied, so the regression test's RED on the pre-fix code must be DEMONSTRATED (run it, capture the fail) and recorded [$c]"; blocked=1 ;; esac
        ;;
    esac
  done
  return $blocked
}

# ---------------------------------------------------------------------------
# Shared micro-helpers. Factored from idioms that were already duplicated in this
# file (and again in pipeline-gate-lib.sh) so the gate and its diagnostic
# (scripts/zuvo-phase.sh) can never drift into reading state differently.
# ---------------------------------------------------------------------------

# _mtime <file> <default> — portable epoch mtime (BSD stat | GNU stat | default).
# Factors the `stat -f %m || stat -c %Y || echo $now` chain used above.
_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || printf '%s' "$2"
}

# _is_agent_env — 0 when ANY AI-harness marker is set, 1 for a human shell.
# UNION of this lib's historical 5-var list and pipeline-gate-lib.sh's pg_is_agent_env()
# (13 vars), which had silently drifted apart: a Codex run exporting only CODEX_WORKSPACE, a
# Cursor run with only CURSOR_AGENT, or an Antigravity run read as "human" HERE and bypassed
# both gates entirely. A narrower list means an agent slips through, so this list may only ever
# be widened. POSIX sh: no ${!var} indirection (that is why the bash helper cannot be reused).
_is_agent_env() {
  [ "${ZUVO_AGENT:-0}" = "1" ] && return 0
  [ -n "${ZUVO_AI_RUN:-}" ] && return 0
  [ -n "${CLAUDECODE:-}${CLAUDE_PLUGIN_ROOT:-}${CLAUDE_CODE_ENTRYPOINT:-}${CLAUDE_CODE_SESSION:-}" ] && return 0
  [ -n "${CODEX_SANDBOX:-}${CODEX_WORKSPACE:-}${CODEX_HOME:-}" ] && return 0
  [ -n "${CURSOR_TRACE_ID:-}${CURSOR_AGENT:-}" ] && return 0
  [ -n "${GEMINI_CLI:-}${ANTIGRAVITY:-}${GEMINI_ANTIGRAVITY:-}${ANTIGRAVITY_SESSION_ID:-}" ] && return 0
  return 1
}

# _ap_field <file> <name> — read `name: value` from a zuvo state file in EITHER dialect the
# fleet actually writes: a plain / YAML-frontmatter line (`status: pending`) or an HTML comment
# (`<!-- status: pending -->`). session-state.md documented the COMMENT form while this gate
# only ever read the PLAIN one, so 8 of 19 live active-plan.md files parsed as empty and the
# gate silently fail-opened. Plain wins when both are present. Always exits 0; empty output
# means "not found" and every caller treats that as fail-OPEN.
# <name> is always an internal constant (status|plan|plan_file) — never file content — so it
# cannot inject sed syntax.
_ap_field() {
  _apf=$(sed -n "s/^$2:[[:space:]]*//p" "$1" 2>/dev/null | head -1 | tr -d '\r')
  if [ -z "$_apf" ]; then
    # Cut at the FIRST `-->` before capturing. The obvious `\(.*\)-->` is greedy, so a line
    # carrying two comments (`<!-- plan: p.md --> <!-- note: x -->`) captured everything up to
    # the LAST delimiter and yielded `p.md --> <!-- note: x`. _ap_status hid this because it
    # truncates at whitespace; _ap_plan must not truncate (paths may contain spaces), so the
    # polluted value reached the caller and the plan doc silently failed to resolve.
    _apf=$(sed -n "s/^[[:space:]]*<!--[[:space:]]*$2:[[:space:]]*//p" "$1" 2>/dev/null \
           | head -1 | sed 's/-->.*//' | sed 's/[[:space:]]*$//' | tr -d '\r')
  fi
  printf '%s' "$_apf"
}

# _ap_status <file> — status value, truncated at the first whitespace so `pending # note`,
# `pending\r` and `<!-- status: pending -->` all normalize to `pending`.
_ap_status() { _ap_field "$1" status | sed 's/^[[:space:]]*//; s/[[:space:]].*//'; }

# _ap_plan <file> — plan document path. `plan:` first, then the `plan_file:` alias seen in the
# wild (ResearchShieldNew). Trailing-trimmed, NOT whitespace-truncated: a path may contain spaces.
_ap_plan() {
  _app=$(_ap_field "$1" plan)
  [ -n "$_app" ] || _app=$(_ap_field "$1" plan_file)
  printf '%s' "$_app" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# _expand_plan_files — read a plan doc, emit ONE declared path per line, expanding
# `prefix/{a,b,c}` brace groups first.
# Splitting the raw text on commas shatters a brace group into `apps/api/{package.json`,
# `tsconfig.json`, `vitest.config.ts`, ... — bare basenames stripped of their directory, which
# then EXACT-MATCH unrelated repo-root files. A real VirtualTrainer plan yields 256 such tokens
# including bare `tsconfig.json` and `index.html`. This was dormant (the `in-progress` early
# return ran before it); making that state blockable reaches it, so it is fixed here.
# A token with no brace group, or with more than one, is emitted verbatim — worst case it
# matches nothing, which is fail-OPEN.
_expand_plan_files() {
  grep '^\*\*Files:\*\*' -- "$1" 2>/dev/null | tr -d '\r' | sed 's/^\*\*Files:\*\*//; s/`//g' | awk '
    function emit(t,  k, e, pre, inner, suf, parts, n, i, p) {
      gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t == "") return
      k = index(t, "{"); e = index(t, "}")
      if (k == 0 || e < k) { print t; return }                   # no group -> verbatim
      pre = substr(t, 1, k - 1)
      inner = substr(t, k + 1, e - k - 1)
      suf = substr(t, e + 1)
      # Nested OR sibling group -> verbatim. Expanding only the FIRST group of
      # `apps/{web,api}/src/{a.ts,b.ts}` would emit `apps/web/src/{a.ts,b.ts}` — a path that
      # matches nothing, silently dropping declared files from the gate while looking expanded.
      # Verbatim is the honest fail-open; partial expansion is a silent miss.
      if (index(inner, "{") > 0 || index(suf, "{") > 0) { print t; return }
      n = split(inner, parts, ",")
      for (i = 1; i <= n; i++) {
        p = parts[i]; gsub(/^[ \t]+|[ \t]+$/, "", p)
        if (p != "") print pre p suf
      }
    }
    {
      depth = 0; tok = ""
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        else if (c == "}") depth--
        else if (c == "," && depth <= 0) { emit(tok); tok = ""; continue }
        tok = tok c
      }
      emit(tok)
    }'
}

# plan_execute_gate_check — the plan→execute bind. If an Approved plan is not being executed and
# the staged/pushed files intersect the plan's declared **Files:**, BLOCK: the work must go
# through `zuvo:execute`, not be hand-rolled. Fail-OPEN on any missing/odd input.
#
# `status: in-progress` is NOT taken at face value. Flipping that field is a free, unverified
# write, so an agent could disarm the gate and hand-roll the rest of the plan. The exemption is
# now EARNED by evidence of a real run (execution-state.md, or a fresh execute run-marker) —
# uncorroborated `in-progress` falls through to the same check as `pending`.
plan_execute_gate_check() {
  staged=$1
  ap="${ZUVO_PLANS_DIR:-zuvo/plans}/active-plan.md"
  [ -f "$ap" ] || return 0
  st=$(_ap_status "$ap")
  case "$st" in
    pending) ;;                                     # never started -> always checked
    in-progress)
      # Corroborate. `git rev-parse` may fail (bare/odd checkout) -> fall back to $PWD.
      pg_root=$(git rev-parse --show-toplevel 2>/dev/null) || pg_root=""
      [ -n "$pg_root" ] || pg_root=$PWD
      # Pass the plan THIS pointer names (raw, as written — execution-state records it the same
      # way) so a leftover state file from a DIFFERENT plan cannot corroborate this one.
      if _execute_run_live "$pg_root" "$(_ap_plan "$ap")"; then
        return 0                                    # a real execute run owns these commits
      fi
      echo "zuvo plan-gate: active-plan.md says in-progress but no live zuvo:execute run" >&2
      echo "  (need an in-progress execution-state.md for THIS plan, or an execute run-marker," >&2
      echo "   either one modified within ${ZUVO_GATE_GRACE:-21600}s)" >&2
      ;;
    *) return 0 ;;                                  # completed / aborted / unparseable -> allow
  esac
  plan=$(_ap_plan "$ap")
  [ -n "$plan" ] || return 0                                      # fail-OPEN: no plan path
  # Resolve a RELATIVE plan path the same way scripts/zuvo-phase.sh inspect() does: repo-root
  # first, then cwd. A git hook usually runs at the worktree top, but not always (linked
  # worktrees, odd checkouts, a wrapper invoking the hook from elsewhere) — and if the two
  # resolve differently the doctor reports ARMED while the gate fail-opens on every commit,
  # which is precisely the silent-dead-gate the doctor exists to rule out.
  # Recomputed here rather than reusing pg_root: this lib is SOURCED, so a global set by an
  # earlier call in the same shell could belong to a different repo.
  case "$plan" in
    /*) : ;;
    *)  _pe_root=$(git rev-parse --show-toplevel 2>/dev/null) || _pe_root=""
        [ -n "$_pe_root" ] && [ -f "$_pe_root/$plan" ] && plan="$_pe_root/$plan" ;;
  esac
  [ -f "$plan" ] || return 0                                      # fail-OPEN: missing plan doc
  # One declared path per line, brace groups already expanded (see _expand_plan_files).
  plan_files=$(_expand_plan_files "$plan")
  [ -n "$(printf '%s' "$plan_files" | tr -d '[:space:]')" ] || return 0 # fail-OPEN: no **Files:**
  # HUMAN BYPASS — a human committing the plan's files is not hand-rolling AI work
  if ! _is_agent_env; then
    echo "zuvo plan-gate: human committer (no AI-harness env) -> bypass [$ap]" >&2
    return 0
  fi
  blocked=0; oldifs=$IFS; set -f            # set -f: a '*' in a path must not glob the filesystem
  # Both lists are newline-delimited now (the brace expander consumed the commas), so a filename
  # containing a SPACE survives as one token. A comma is NOT supported inside a filename: a
  # top-level comma is the **Files:** list separator, so `report,final.ts` tokenizes as two
  # paths. That is a fail-open miss (neither fragment matches a real staged path) — declaring
  # such a file in a plan simply leaves it ungated.
  IFS='
'
  for pf in $plan_files; do
    pf=$(printf '%s' "$pf" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')   # trim
    [ -n "$pf" ] || continue
    for sf in $staged; do [ "$sf" = "$pf" ] && { blocked=1; break; }; done  # exact, no regex/glob
    [ "$blocked" = 1 ] && break
  done
  IFS=$oldifs; set +f
  if [ "$blocked" = 1 ]; then
    if [ "$st" = "in-progress" ]; then
      echo "BLOCK: active-plan.md claims in-progress but no zuvo:execute run backs it ($plan) — run \`zuvo:execute\`, or if that plan is finished mark it \`status: completed\` in [$ap]"
    else
      echo "BLOCK: Approved plan is PENDING ($plan) — run \`zuvo:execute\`, do not hand-roll the implementation [$ap]"
    fi
  fi
  return $blocked
}

# _execute_run_live <repo_root> — 0 when a real zuvo:execute run owns the current commits.
# Two independent signals, either is sufficient; absence of both is "no evidence", never an error.

# _erl_state_ok <execution-state.md path> — 0 when that file exists and says in-progress.
# _ap_status (not a literal grep) so BOTH dialects count: real repos are split roughly 50/50
# between `status: in-progress` and `<!-- status: in-progress -->`. An HTML-comment-only grep —
# what pre-commit-adversarial-gate.sh:76 does — misses half of them, which here would false-block
# a genuinely LIVE execute run.
# _erl_state_ok <execution-state.md> <expected-plan> — 0 only when that file is credible
# corroboration for THIS plan, right now. Status alone is not enough:
#   * FRESHNESS — a crashed/abandoned run leaves `in-progress` on disk forever, which would
#     authenticate every future commit indefinitely. A genuinely live run rewrites this file
#     after every task commit (session-state.md WRITE protocol), so its mtime stays inside the
#     grace window; an abandoned one ages out. Same window as the run-marker.
#   * PLAN IDENTITY — a state file left over from a DIFFERENT plan says nothing about this one.
#     Compared only when the state file actually carries a `plan:` (older files may not) —
#     absent, fall back to freshness alone rather than fail closed on legacy state.
# Both were reported by the cross-model review as ways an unverified state file "permanently
# authenticates" a run; both are ordinary drift, not just adversarial cases.
_erl_state_ok() {
  [ -f "$1" ] || return 1
  [ "$(_ap_status "$1")" = "in-progress" ] || return 1
  _eso_age=$(( $(date +%s) - $(_mtime "$1" 0) ))
  [ "$_eso_age" -ge 0 ] && [ "$_eso_age" -le "$_erl_grace" ] || return 1
  _eso_plan=$(_ap_plan "$1")
  { [ -z "$_eso_plan" ] || [ -z "$2" ] || [ "$_eso_plan" = "$2" ]; } || return 1
  return 0
}

# _realpath <dir> — physical path with symlinks resolved; echoes the input unchanged if it
# does not exist. Load-bearing on macOS: `git rev-parse --show-toplevel` yields /private/var/...
# while $TMPDIR-derived paths read /var/..., so an exact string compare classifies a repo's OWN
# state as foreign and false-BLOCKs. Runs in a subshell, so it never moves the caller's cwd.
_realpath() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }

# _execute_run_live <repo_root> [expected-plan-path]
_execute_run_live() {
  _erl_root=$1
  _erl_want=${2:-}
  # Grace is resolved FIRST: _erl_state_ok below reads it, and computing it later left the
  # state-freshness check comparing against an empty/stale value.
  _erl_grace=$(printf '%s' "${ZUVO_GATE_GRACE:-21600}" | tr -cd '0-9')
  [ -n "$_erl_grace" ] || _erl_grace=21600
  _erl_now=$(date +%s)
  # (a) execution-state.md — the durable artifact zuvo:execute rewrites after every task commit.
  #
  # Every candidate MUST be repo-scoped. ZUVO_OUTPUT_DIR is a documented global override, so a
  # stale export left pointing at another project's zuvo/ would otherwise hand THIS repo a
  # forged "in-progress" and re-open the very bypass this corroboration closes (reproduced:
  # ZUVO_OUTPUT_DIR=<other-project>/zuvo made an unrelated repo return "live"). It is therefore
  # honored only when it resolves inside $_erl_root. State living outside the repo fails toward
  # BLOCK — the safe direction, and it still carries the ZUVO_ALLOW_ADHOC escape.
  # The run-marker branch below has always had this guard (`repo_root=` compare); branch (a)
  # was missing it.
  _erl_rootp=$(_realpath "$_erl_root")
  if [ -n "${ZUVO_OUTPUT_DIR:-}" ]; then
    case "$(_realpath "$ZUVO_OUTPUT_DIR")" in
      "$_erl_rootp"|"$_erl_rootp"/*)
        _erl_state_ok "$ZUVO_OUTPUT_DIR/context/execution-state.md" "$_erl_want" && return 0 ;;
    esac
  fi
  _erl_state_ok "$_erl_root/zuvo/context/execution-state.md" "$_erl_want" && return 0
  _erl_state_ok "$_erl_root/.zuvo/context/execution-state.md" "$_erl_want" && return 0  # legacy
  # (b) a fresh execute run-marker — covers the window between `zuvo:execute` starting and its
  # first state write. Same dir, field and grace default as hooks/pre-commit-adversarial-gate.sh;
  # mtime (not the start_ts text) keeps this POSIX and avoids that gate's BSD-only date parsing.
  _erl_dir="${ZUVO_HOME:-$HOME/.zuvo}/run-markers"
  [ -d "$_erl_dir" ] || return 1
  for _erl_m in "$_erl_dir"/execute-*.marker; do
    [ -f "$_erl_m" ] || continue
    _erl_mr=$(sed -n 's/^repo_root=//p' "$_erl_m" 2>/dev/null | head -1 | tr -d '\r')
    # Normalized compare: a marker written from a symlinked path (/tmp vs /private/tmp) must
    # still match its own repo, or a live run false-BLOCKs.
    [ -n "$_erl_mr" ] && [ "$(_realpath "$_erl_mr")" = "$_erl_rootp" ] || continue
    # Age must be inside [0, grace]. A NEGATIVE age (future mtime — clock step back, NTP
    # correction, VM snapshot restore, `touch -d`, or a forged marker) is always `-le` a
    # positive grace, so without the lower bound a long-dead marker reads as live until
    # wall-clock catches up: an unbounded bypass window. Note this fails the opposite way from
    # the stale-CONTRACT check above, where a future mtime errs toward BLOCKING (safe).
    _erl_age=$(( _erl_now - $(_mtime "$_erl_m" "$_erl_now") ))
    [ "$_erl_age" -ge 0 ] && [ "$_erl_age" -le "$_erl_grace" ] && return 0
  done
  return 1
}
