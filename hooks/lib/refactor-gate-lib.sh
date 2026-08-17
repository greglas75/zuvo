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

# _prove_field <contract-json> <field> — the value of prove.<field>, and ONLY prove.<field>.
#
# Every prove check used to be `sed -n 's/.*"<field>"…/\1/p' "$c" | head -1`, which searches the
# WHOLE FILE and takes the first hit. The agent writes this contract, so it could add a decoy
# object anywhere above `prove` and walk through the gate:
#
#   { "previous_attempt": { "test_quality": "PASS:A:zuvo/audits/x.md" },
#     "prove": { "test_quality": "not_run" } }        <-- gate read the decoy, returned 0
#
# Verified 2026-08-13 against this file: that contract passed with every real prove value at
# `not_run`. It defeated the v4 fields AND the pre-existing blind_audit / adversarial /
# characterization checks — i.e. the whole "only agent-independent bind" was one JSON key away
# from being decorative, and the agent it polices is the one holding the pen. That is the
# agent-typable bypass this repo removes on sight, so the fix belongs to the CLASS: both
# functions below now read through here, and neither can be spoofed by a sibling key.
#
# jq-free by this file's contract, so the object is walked in awk: find "prove", take its `{`,
# track depth while respecting quotes and backslash escapes, stop at the matching `}`.
_prove_field() {
  _pf_c=$1; _pf_k=$2
  tr -d '\n' < "$_pf_c" 2>/dev/null | awk -v key="$_pf_k" '
    {
      s = $0
      p = index(s, "\"prove\"")
      if (p == 0) exit
      s = substr(s, p)
      b = index(s, "{")
      if (b == 0) exit
      s = substr(s, b)
      depth = 0; inq = 0; esc = 0; n = length(s); obj = ""
      for (i = 1; i <= n; i++) {
        ch = substr(s, i, 1)
        obj = obj ch
        if (inq) {
          if (esc)             { esc = 0 }
          else if (ch == "\\") { esc = 1 }
          else if (ch == "\"") { inq = 0 }
        } else {
          if (ch == "\"")      { inq = 1 }
          else if (ch == "{")  { depth++ }
          else if (ch == "}")  { depth--; if (depth == 0) break }
        }
      }
      # obj is now the prove object text; pull the field out of THAT, not out of the file.
      k = index(obj, "\"" key "\"")
      if (k == 0) exit
      rest = substr(obj, k + length(key) + 2)
      c = index(rest, ":")
      if (c == 0) exit
      rest = substr(rest, c + 1)
      q = index(rest, "\"")
      if (q == 0) exit
      rest = substr(rest, q + 1)
      out = ""; esc = 0
      for (i = 1; i <= length(rest); i++) {
        ch = substr(rest, i, 1)
        if (esc)             { out = out ch; esc = 0 }
        else if (ch == "\\") { esc = 1 }
        else if (ch == "\"") { break }
        else                 { out = out ch }
      }
      print out
    }' 2>/dev/null | head -1
}

refactor_gate_check() {
  staged=$1
  cdir=${ZUVO_CONTRACTS_DIR:-zuvo/contracts}
  [ -d "$cdir" ] || return 0
  ttl=${ZUVO_GATE_TTL_SEC:-86400}
  blocked=0
  for c in "$cdir"/refactor-*.json; do
    [ -f "$c" ] || continue
    # TERMINAL stages — the gate exists to protect an IN-FLIGHT refactor from being
    # committed around. A refactor that stopped is not in flight. `BLOCKED` is a
    # terminal outcome (the run hit a hard blocker and halted), but only `COMPLETE`
    # was recognised, so a blocked contract kept its fence enforced until its mtime
    # aged past the 24h TTL. Reported 2026-08-07: six BLOCKED contracts from earlier
    # sessions, each still holding its fence, and the operator's escape was to widen
    # a live contract's fence to cover the file it wanted to commit — a scope stretch
    # the gate should never have made attractive.
    # `EXECUTION_COMPLETE` is deliberately NOT here: skills/refactor/SKILL.md:220 uses
    # it for `no-commit` runs precisely so `continue` can resume, i.e. still in flight.
    grep -qE '"stage"[[:space:]]*:[[:space:]]*"(COMPLETE|BLOCKED|ABORTED)"' "$c" && continue
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
    ba=$(_prove_field "$c" blind_audit)
    av=$(_prove_field "$c" adversarial)
    # characterization lock: the pin-down tests proven green on the PRE-refactor code,
    # recorded in the CONTRACT BEFORE any move edit. Prose alone was skipped in the field
    # (skill-eval 2026-07-09: CONTRACT written at PHASE-1, next touched only at prove-time)
    # — so the gate enforces the artifact, same as blind_audit/adversarial.
    ch=$(_prove_field "$c" characterization)
    case "$ba" in skipped|not_run|"") echo "BLOCK: refactor CONTRACT prove.blind_audit='$ba' not satisfied [$c]"; blocked=1 ;; esac
    case "$av" in skipped|not_run|"") echo "BLOCK: refactor CONTRACT prove.adversarial='$av' not satisfied [$c]"; blocked=1 ;; esac
    case "$ch" in skipped|not_run|"") echo "BLOCK: refactor CONTRACT prove.characterization='$ch' not satisfied — record the pin-down lock (tests green on PRE-refactor code) when the suite goes green, BEFORE the move [$c]"; blocked=1 ;; esac
    # regression-red proof: required ONLY when Phase 3.5 actually APPLIED a fix (the
    # disposition names a fix). Two consecutive skill-eval runs (2026-07-10) showed agents
    # substituting "the flip logically implies red" for an actual red run — gate the artifact.
    fd=$(_prove_field "$c" findings_disposition)
    case "$fd" in
      *fix*)
        rr=$(_prove_field "$c" regression_red)
        case "$rr" in skipped|not_run|"") echo "BLOCK: refactor CONTRACT prove.regression_red='$rr' not satisfied — findings_disposition='$fd' says a fix was applied, so the regression test's RED on the pre-fix code must be DEMONSTRATED (run it, capture the fail) and recorded [$c]"; blocked=1 ;; esac
        ;;
    esac
  done
  return $blocked
}

# refactor_prove_v4_check — the two proofs that can only exist AFTER the commits.
#
# Separate from refactor_gate_check on purpose, and the separation is the whole design:
#
#   * PRE-PUSH ONLY. Phase 3.6 (test-quality) and its Step 0 (per-module coverage) run AFTER the
#     Phase 3.5 commits — skills/refactor/SKILL.md:1022 commits, :1049 is Phase 3.6. Enforcing
#     these at pre-commit blocks the very commit that must happen before they can be filled: a
#     deadlock with no exit, on the DEFAULT path of every refactor. The first draft of this change
#     did exactly that and a repro caught it. `git push` is the first boundary at which both are
#     knowable, and it is still before the code reaches anyone else.
#   * TERMINAL STAGES ARE NOT SKIPPED HERE. refactor_gate_check skips COMPLETE/BLOCKED because it
#     protects an in-flight refactor. This check is the opposite: COMPLETE is exactly the state a
#     finished refactor is in when it reaches `git push`, so skipping it would mean the field is
#     enforced nowhere at all. The TTL below still ages out abandoned contracts, so a months-old
#     COMPLETE contract cannot block pushes forever.
#
# Why these two fields, measured 2026-08-12 over 413 COMPLETE refactor contracts on this machine:
# the fields a hook blocks on are recorded 96-97% of the time; prove.test_quality, which only
# prose called HARD, was recorded in 3% (33% in August). Phase 3.6 was not being skipped by bad
# agents — it was unenforced, and unenforced is indistinguishable from optional.
# prove.split_coverage is new for the same reason: rs_be PR #291 split a service into 7 modules
# holding 2586 lines and shipped with zero specs for them, past every gate, because no gate asked
# about the files a refactor CREATES (characterization can only cover the pre-split surface).
refactor_prove_v4_check() {
  [ "${ZUVO_GATE_MODE:-pre-commit}" = "pre-push" ] || return 0
  rpv_staged=$1
  rpv_dir=${ZUVO_CONTRACTS_DIR:-zuvo/contracts}
  [ -d "$rpv_dir" ] || return 0
  rpv_ttl=$(printf '%s' "${ZUVO_GATE_TTL_SEC:-86400}" | tr -cd '0-9')
  [ -n "$rpv_ttl" ] || rpv_ttl=86400
  rpv_blocked=0
  for rpv_c in "$rpv_dir"/refactor-*.json; do
    [ -f "$rpv_c" ] || continue
    _is_agent_env || continue
    rpv_now=$(date +%s)
    rpv_mt=$(_mtime "$rpv_c" "$rpv_now")
    [ $((rpv_now - rpv_mt)) -gt "$rpv_ttl" ] && continue
    # version >= 4 only. A run started by an older installed skill writes v3 and is judged by v3
    # rules, so an in-flight refactor is never blocked by a field its own version never knew
    # about — self-migrating rollout, no flag day. The quote-tolerant parse matters: contracts in
    # the field carry "version": 4 AND "version": "4", and a digits-only sed read the string form
    # as absent and let it straight through.
    rpv_cv=$(grep -o '"version"[[:space:]]*:[[:space:]]*"\{0,1\}[0-9][0-9]*' "$rpv_c" 2>/dev/null | head -1 | tr -cd '0-9')
    case "$rpv_cv" in ''|*[!0-9]*) continue ;; esac
    [ "$rpv_cv" -ge 4 ] 2>/dev/null || continue
    # only judge a contract whose fence this push actually touches
    rpv_hit=0
    rpv_oldifs=$IFS; IFS='
'
    set -f
    for rpv_f in $rpv_staged; do
      [ -n "$rpv_f" ] || continue
      if grep -Fq -- "\"$rpv_f\"" "$rpv_c"; then rpv_hit=1; break; fi
    done
    set +f
    IFS=$rpv_oldifs
    [ "$rpv_hit" = 1 ] || continue

    rpv_tq=$(_prove_field "$rpv_c" test_quality)
    # PASS/WARN/N/A is the vocabulary Phase 3.6 prints — but shape alone still accepts a story.
    # "WARN:substituted-inline" (a value a field run invented twice) matches WARN:* perfectly.
    # So PASS/WARN must carry the third field, the on-disk zuvo/audits/ report, and that file
    # must EXIST: the report is the expensive thing to fake, which is exactly why it is the
    # proof-of-dispatch. N/A needs no report — nothing test-shaped happened.
    case "$rpv_tq" in
      N/A|N/A:*) ;;
      PASS:*:*|WARN:*:*)
        rpv_rep=${rpv_tq#*:}; rpv_rep=${rpv_rep#*:}
        case "$rpv_rep" in
          ''|/*|*..*) echo "BLOCK: refactor CONTRACT prove.test_quality='$rpv_tq' — the report path must be repo-relative and contain no '..' [$rpv_c]"; rpv_blocked=1 ;;
          *) [ -f "$rpv_rep" ] || { echo "BLOCK: refactor CONTRACT prove.test_quality='$rpv_tq' — the named test-audit report does not exist at '$rpv_rep'. The gate is satisfied by the REPORT, not by the claim; inline Q-rescoring is a substituted gate [$rpv_c]"; rpv_blocked=1; } ;;
        esac
        ;;
      *) echo "BLOCK: refactor CONTRACT prove.test_quality='$rpv_tq' not satisfied — Phase 3.6 must dispatch the REAL zuvo:test-audit and record '<PASS|WARN|N/A>:<worst tier>:<report path>' [$rpv_c]"; rpv_blocked=1 ;;
    esac

    # split_coverage must agree with modules_created, which Phase 3 wrote earlier — before the
    # agent knew this check existed. Without the cross-check the field accepts any non-empty
    # string ("N/A" after a 7-module split, "TODO", " "), i.e. it would police only an agent
    # honest enough to write "not_run". Making the numerator match forces a lie to be told twice,
    # backwards in time. Walker is the scope_fence one below, keyed on modules_created.
    # ANCHOR THE ARRAY TO ITS KEY FIRST. The walker below takes the first `[` after
    # "modules_created"; if the field is `null` (or any non-array scalar) it would sail past and
    # parse the NEXT array in the file — `progress: [...]` — as if those were created modules.
    # Verified: `"modules_created": null` + a 3-entry `progress` produced "created 3 module(s)"
    # and BLOCKED a push that was entirely honest. In a file whose contract is fail-OPEN that is
    # the worst possible direction to be wrong in. The sibling scope_fence walker already had
    # this guard (see refactor_scope_gate_check); this one was adapted without it.
    # No anchored array => nothing was recorded as created => count 0, which still requires
    # split_coverage to be N/A or 0/0 and so keeps the honest-value check alive.
    if grep -q '"modules_created"[[:space:]]*:[[:space:]]*\[' "$rpv_c" 2>/dev/null; then
    rpv_mods=$(tr -d '\n' < "$rpv_c" 2>/dev/null | awk '
      { s = $0
        k = index(s, "\"modules_created\""); if (k == 0) exit
        s = substr(s, k); b = index(s, "["); if (b == 0) exit
        s = substr(s, b + 1); inq = 0; esc = 0; cur = ""; n = length(s)
        for (i = 1; i <= n; i++) { ch = substr(s, i, 1)
          if (inq) { if (esc) { cur = cur ch; esc = 0 }
                     else if (ch == "\\") { esc = 1 }
                     else if (ch == "\"") { inq = 0; if (cur != "") print cur; cur = "" }
                     else { cur = cur ch } }
          else { if (ch == "\"") { inq = 1; cur = "" } else if (ch == "]") { exit } } } }' | grep -c . )
    else
      rpv_mods=0
    fi
    case "$rpv_mods" in ''|*[!0-9]*) rpv_mods=0 ;; esac
    rpv_sc=$(_prove_field "$rpv_c" split_coverage)
    rpv_num=$(printf '%s' "$rpv_sc" | sed -n 's|^\([0-9][0-9]*\)/[0-9][0-9]*:..*$|\1|p')
    if [ "$rpv_mods" -eq 0 ]; then
      case "$rpv_sc" in
        N/A|N/A:*|0/0:*) ;;
        *) echo "BLOCK: refactor CONTRACT prove.split_coverage='$rpv_sc' — modules_created is empty, so the only honest values are 'N/A' or '0/0:<why>' [$rpv_c]"; rpv_blocked=1 ;;
      esac
    elif [ -z "$rpv_num" ]; then
      echo "BLOCK: refactor CONTRACT prove.split_coverage='$rpv_sc' not satisfied — this refactor created $rpv_mods module(s), so 'N/A' is false. Record '<created>/<with_own_spec>:<disposition>' after giving every path in modules_created a test that imports it DIRECTLY, or a NAMED out-of-fence/user-declined backlog entry [$rpv_c]"
      rpv_blocked=1
    elif [ "$rpv_num" -ne "$rpv_mods" ] 2>/dev/null; then
      echo "BLOCK: refactor CONTRACT prove.split_coverage='$rpv_sc' disagrees with modules_created ($rpv_mods entries) — the created count must match the list Phase 3 recorded [$rpv_c]"
      rpv_blocked=1
    fi
  done
  return $rpv_blocked
}

# refactor_scope_gate_check — the OFF-CONTRACT bind, and the reason it exists.
#
# refactor_gate_check above only inspects a file that is INSIDE some contract's scope_fence.
# That leaves the actual field failure wide open: the agent runs `zuvo:refactor` once (contract
# for file A), then keeps refactoring B, C, D… by hand. None of them is in any fence, so the
# gate is silent for every one of them. Observed 2026-07-22: one run of the skill, then ~39
# hand-rolled changes reported as "done, verified" — commits on a red suite, UI rewritten with
# no verification, a coverage gate argued past in prose.
#
# The mechanism is not dishonesty, it is CONTEXT. skills/refactor/SKILL.md is 861 lines plus
# ~10 includes, injected ONCE at invocation; nothing re-injects it. After compaction the agent
# is running a SUMMARY of the skill ("I do refactors with an ETAP process") — the 28 CQ gates,
# the blind audit, the characterization lock are simply not in the window any more. Prose
# cannot fix that: you cannot obey a MANDATORY line that no longer exists in your context.
#
# So this gate is not a punishment for cheating — it is a CONTEXT-RELOAD TRIGGER. While a
# refactor is active in this repo, a source file outside every fence blocks the commit, and
# the only way to obtain a fence for it is to invoke the skill on it — which re-injects those
# 861 lines at exactly the moment they are needed.
#
# Deliberately narrow, because a false block on 68 repos is worse than a missed one:
#   * only fires when an ACTIVE contract exists (not COMPLETE, not past ZUVO_GATE_TTL_SEC)
#   * only source-code files (docs/config/state/lockfiles never block)
#   * human committers and ZUVO_ALLOW_ADHOC=1 bypass unchanged
#   * any parse problem returns 0 (fail-OPEN is still the contract)
refactor_scope_gate_check() {
  rsg_staged=$1
  rsg_cdir=${ZUVO_CONTRACTS_DIR:-zuvo/contracts}
  [ -d "$rsg_cdir" ] || return 0
  # Sanitize TTL: a non-numeric ZUVO_GATE_TTL_SEC would make the arithmetic below a shell
  # error, which under a caller's `set -e` turns this fail-OPEN gate into an abort.
  rsg_ttl=$(printf '%s' "${ZUVO_GATE_TTL_SEC:-86400}" | tr -cd '0-9')
  [ -n "$rsg_ttl" ] || rsg_ttl=86400
  rsg_now=$(date +%s)

  # Is a refactor genuinely in flight? Collect the fences of every ACTIVE contract.
  rsg_active=0
  rsg_fences=""
  for rsg_c in "$rsg_cdir"/refactor-*.json; do
    [ -f "$rsg_c" ] || continue
    # Same terminal set as the prove gate above — see the comment there. This is the
    # scope guard ("every staged file must sit in some fence"), which is the one that
    # actually blocked unrelated work: a halted refactor made every later commit prove
    # membership in a fence nobody was working inside.
    grep -qE '"stage"[[:space:]]*:[[:space:]]*"(COMPLETE|BLOCKED|ABORTED)"' "$rsg_c" && continue
    [ $(( rsg_now - $(_mtime "$rsg_c" "$rsg_now") )) -gt "$rsg_ttl" ] && continue  # abandoned run
    rsg_active=1
    # An active contract whose scope_fence cannot be read (malformed JSON, field absent) makes
    # the in-scope set UNKNOWN — and this gate's whole judgement is "file is outside every
    # fence". Unknown scope must therefore fail OPEN, not block every source file in the repo.
    grep -q '"scope_fence"[[:space:]]*:[[:space:]]*\[' "$rsg_c" || {
      echo "zuvo refactor-scope: contract has no readable scope_fence -> fail-open [$rsg_c]" >&2
      return 0
    }
    # Extract the scope_fence array's quoted entries, QUOTE-AWARE.
    #
    # The obvious sed (`\[\([^]]*\)\]`) is wrong: `[^]]*` cannot cross a `]`, so it stops at the
    # first one ANYWHERE after the array opens — including a `]` inside a filename. Next.js /
    # Nuxt / SvelteKit dynamic routes (`app/[id]/page.tsx`, `[...slug].ts`) are exactly that,
    # and they are common across this fleet. Measured on `["app/[id]/page.tsx","src/normal.ts"]`
    # the sed returned NOTHING: every fence entry vanished, so either the gate went silently
    # dead (empty set -> fail-open) or, with a different entry order, real in-scope files read
    # as off-fence and got FALSE-BLOCKED — a block on the very refactor in flight.
    #
    # So walk the text instead: after "scope_fence", take the first `[`, then collect quoted
    # strings until a `]` seen OUTSIDE quotes. A `]` inside a filename is just a character.
    # Backslash escapes are honoured so `\"` cannot end a path early.
    rsg_fences="$rsg_fences
$(tr -d '\n' < "$rsg_c" | awk '
  {
    s = $0
    k = index(s, "\"scope_fence\"")
    if (k == 0) exit
    s = substr(s, k)
    b = index(s, "[")
    if (b == 0) exit
    s = substr(s, b + 1)
    inq = 0; esc = 0; cur = ""
    n = length(s)
    for (i = 1; i <= n; i++) {
      ch = substr(s, i, 1)
      if (inq) {
        if (esc)            { cur = cur ch; esc = 0 }
        else if (ch == "\\") { esc = 1 }
        else if (ch == "\"") { inq = 0; if (cur != "") print cur; cur = "" }
        else                 { cur = cur ch }
      } else {
        if (ch == "\"")      { inq = 1; cur = "" }
        else if (ch == "]")  { exit }
      }
    }
  }')"
  done
  [ "$rsg_active" = 1 ] || return 0                      # no refactor in flight -> nothing to bind
  # Same reasoning as the per-contract guard above, applied to the collected set: no fence
  # entries at all means the in-scope set is unknown, so every file would look off-contract.
  [ -n "$(printf '%s' "$rsg_fences" | tr -d '[:space:]')" ] || {
    echo "zuvo refactor-scope: active contract(s) yielded no fence paths -> fail-open" >&2
    return 0
  }

  if ! _is_agent_env; then
    echo "zuvo refactor-scope: human committer -> bypass" >&2
    return 0
  fi

  rsg_off=""; rsg_oldifs=$IFS; set -f
  IFS='
'
  for rsg_f in $rsg_staged; do
    [ -n "$rsg_f" ] || continue
    # Only source code can be "refactored". Everything else is noise for this gate.
    case "$rsg_f" in
      *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.py|*.go|*.rs|*.java|*.kt|*.rb|*.php|*.swift|*.c|*.h|*.cc|*.cpp|*.sh|*.vue|*.svelte|*.astro) ;;
      *) continue ;;
    esac
    case "$rsg_f" in
      node_modules/*|*/node_modules/*|dist/*|*/dist/*|build/*|*/build/*|vendor/*|*/vendor/*|.git/*|*/.git/*) continue ;;
    esac
    # Test files are never "refactoring around the gate" — and blocking them made two of this
    # skill's own mandates unsatisfiable at once. Phase 3.6 Step 0 orders a `test(<scope>):` commit
    # for every module the split created, and Phase 3.5 orders regression tests for every fix; both
    # produce NEW spec files that are in no fence by construction, because the fence lists
    # PRODUCTION files (SKILL.md:855 keeps it that way so the adversarial payload stays
    # production-only). Before this exemption the gate blocked the commit it had just demanded, and
    # the only escapes were widening the fence with test paths — the scope stretch this gate exists
    # to discourage — or ZUVO_ALLOW_ADHOC, an agent-typable bypass.
    case "$rsg_f" in
      *.spec.*|*.test.*|__tests__/*|*/__tests__/*|tests/*|*/tests/*|test/*|*/test/*|*_test.go|*_test.py|test_*.py|*Test.java|*Test.kt|*Spec.php|*Test.php) continue ;;
    esac
    rsg_hit=0
    for rsg_p in $rsg_fences; do
      [ -n "$rsg_p" ] || continue
      [ "$rsg_p" = "$rsg_f" ] && { rsg_hit=1; break; }   # exact compare, no regex/glob
    done
    [ "$rsg_hit" = 0 ] && rsg_off="$rsg_off $rsg_f"
  done
  IFS=$rsg_oldifs; set +f

  [ -n "$rsg_off" ] || return 0
  echo "BLOCK: a zuvo:refactor is ACTIVE in this repo, but these files are in no contract's scope_fence:"
  for rsg_p in $rsg_off; do echo "         $rsg_p"; done
  echo "       Refactoring them outside the skill skips the parts that are NOT in your context"
  echo "       right now: characterization tests proven green on the PRE-refactor code, the"
  echo "       independent blind audit, cross-model adversarial, and the per-file backup branch."
  echo "       Run \`zuvo:refactor <file>\` for each — that re-loads the protocol and writes the"
  echo "       contract. If the active refactor is finished, mark its contract stage COMPLETE"
  echo "       (or BLOCKED if it halted — both are terminal and release the fence)."
  return 1
}

# ---------------------------------------------------------------------------
# Shared micro-helpers. Factored from idioms that were already duplicated in this
# file (and again in pipeline-gate-lib.sh) so the gate and its diagnostic
# (scripts/zuvo-phase.sh) can never drift into reading state differently.
# ---------------------------------------------------------------------------

# _mtime <file> <default> — portable epoch mtime (GNU stat | BSD stat | default).
#
# ORDER IS LOAD-BEARING, and BSD-first was silently fatal on Linux. `stat -f` on GNU means
# --file-system, not "format": `stat -f %m <file>` SUCCEEDS there and prints a filesystem value,
# so the `||` fallback never fires and a non-mtime number (or a non-numeric one) flows into the
# `$((now - mt))` arithmetic below. Under a caller's `set -e` that is an abort — i.e. the whole
# gate died on Linux before reaching any prove check, which is the entire self-hosted runner
# fleet. Measured on the farm: the same suite that is 20/20 on macOS reported `Illegal number:`
# and 5 failures there, and the gate code was never reached at all.
#
# So: GNU first, BSD second, and sanitize to digits so a stray value can never break arithmetic.
# Identical to the form pipeline-gate-lib.sh:278-283 already carries with the same reasoning —
# that file got it right, these did not, and the divergence is what this comment now prevents.
_mtime() {
  _mt_v="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf '%s' "$2")"
  _mt_v="$(printf '%s' "$_mt_v" | tr -cd '0-9')"
  [ -n "$_mt_v" ] || _mt_v="$(printf '%s' "$2" | tr -cd '0-9')"
  [ -n "$_mt_v" ] || _mt_v=0
  printf '%s' "$_mt_v"
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
  # `^[[:space:]]*` on the PLAIN dialect too (B-gate-7). The comment dialect below already
  # tolerated leading whitespace; the plain one was anchored hard to column 0, so an indented
  # `  status: pending` matched NEITHER branch and fail-opened — the third real-world dialect
  # variant found in the wild after `<!-- status: -->` and bare `status:`.
  _apf=$(sed -n "s/^[[:space:]]*$2:[[:space:]]*//p" "$1" 2>/dev/null | head -1 | tr -d '\r')
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
      # Strip a TRAILING parenthetical annotation (B-gate-5, second half). Keeping the commas
      # inside it was only half the job: `svc.ts (modify — line 559, extract helper)` is still
      # not a path, so it matches no changed file and the declared entry stays invisible to the
      # gate. Trailing only, and only when something precedes it, so a path that legitimately
      # contains parentheses is untouched. This makes MORE declared files resolvable, i.e. it
      # moves the gate toward blocking, which is the direction it is supposed to fail in.
      if (match(t, /[ \t]+\([^()]*\)$/)) t = substr(t, 1, RSTART - 1)
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
      # depth tracks BOTH brace groups and parenthetical annotations (B-gate-5). Plans in the
      # wild annotate entries inline — `svc.ts (modify — line 559, extract helper)` — and 136
      # such commas were counted in real plan files. Tracking only {} split that entry into
      # `svc.ts (modify — line 559` and `extract helper)`, neither of which is a path, so the
      # declared file silently vanished from what the gate can see. Fail-open only (it can never
      # cause a false BLOCK) but it is exactly a silent under-scope, which is the failure this
      # gate exists to prevent. NB: no apostrophes in this block — the whole awk program is
      # single-quoted, so one would terminate it.
      depth = 0; paren = 0; tok = ""
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        else if (c == "}") depth--
        else if (c == "(") paren++
        else if (c == ")") { if (paren > 0) paren-- }
        else if (c == "," && depth <= 0 && paren <= 0) { emit(tok); tok = ""; continue }
        tok = tok c
      }
      emit(tok)
    }'
}

# _plan_intersects <plan-doc> <staged> — 0 when a staged file is one of the plan's declared
# **Files:**. Factored so the plan→execute bind and the spec-approval bind cannot drift into
# judging "is this commit covered by the plan?" differently.
_plan_intersects() {
  _pi_files=$(_expand_plan_files "$1")
  [ -n "$(printf '%s' "$_pi_files" | tr -d '[:space:]')" ] || return 1   # no **Files:** -> no claim
  # Save the caller's glob state instead of forcing it off on return — a caller that had
  # `set -f` active would otherwise get pathname expansion silently re-enabled underneath it.
  case "$-" in *f*) _pi_hadf=1 ;; *) _pi_hadf=0 ;; esac
  _pi_hit=1; _pi_oldifs=$IFS; set -f      # set -f: a '*' in a path must not glob the filesystem
  IFS='
'
  for _pi_p in $_pi_files; do
    _pi_p=$(printf '%s' "$_pi_p" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$_pi_p" ] || continue
    for _pi_s in $2; do [ "$_pi_s" = "$_pi_p" ] && { _pi_hit=0; break; }; done  # exact, no regex
    [ "$_pi_hit" = 0 ] && break
  done
  IFS=$_pi_oldifs; [ "$_pi_hadf" = 1 ] || set +f
  return $_pi_hit
}

# _spec_status <spec-doc> — the spec's status, lowercased, first word only.
# Specs use a THIRD dialect, distinct from active-plan.md and execution-state.md: the
# brainstorm template emits a blockquoted bold field, `> **status:** Approved`. Real files on
# disk also carry `> **Status:** complete (MVP shipped)`, `Status: Active — ...`,
# `**status:** Ready for implementation` — hence "first word, lowercased" rather than an exact
# match, and hence the caller blocks only on an explicit draft/reviewed (see below).
_spec_status() {
  sed -n 's/^[[:space:]>*+-]*[Ss][Tt][Aa][Tt][Uu][Ss]:[[:space:]*]*//p' "$1" 2>/dev/null \
    | head -1 | tr -d '\r*' | tr 'A-Z' 'a-z' | sed 's/[^a-z].*//'
}

# spec_approval_gate_check — the brainstorm->plan bind.
#
# `zuvo:plan` does NOT stop when the spec is unapproved: it prints "Spec exists but is not
# approved. Using it as reference in inline mode." and carries on (skills/plan/SKILL.md:63).
# The async path is worse by design — a converged review sets `Reviewed`, NOT `Approved`, and
# the human is expected to flip it by hand before planning. That hand-flip is exactly the step
# an agent skips. Live example on this machine the same day this was written:
# ResearchShieldNew/2026-07-22-adaptive-interactive-challenges-spec.md sits at `reviewed` with
# its run log saying "change status to Approved before running zuvo:plan" — and nothing stopped
# anyone from planning and executing straight past it.
#
# So: when the work being committed is claimed by a plan whose spec is EXPLICITLY unapproved,
# block. Approval is the user's decision; an agent must not inherit it by proceeding.
#
# Polarity is deliberately inverted from "must equal Approved". Of 147 specs with a status on
# this machine, 115 are Approved, 19 are draft/reviewed, and the rest are free-text (`complete
# (MVP shipped)`, `Active — Wave 1`, `Ready for implementation`), plus 24 specs with no status
# at all. A "not exactly Approved -> block" rule would false-block all of those. Only an
# explicit `draft` or `reviewed` blocks; unknown, free-text, missing and unreadable all pass.
spec_approval_gate_check() {
  sag_staged=$1
  sag_ap="${ZUVO_PLANS_DIR:-zuvo/plans}/active-plan.md"
  [ -f "$sag_ap" ] || return 0
  case "$(_ap_status "$sag_ap")" in pending|in-progress) ;; *) return 0 ;; esac   # only live plans
  sag_plan=$(_ap_plan "$sag_ap")
  [ -n "$sag_plan" ] || return 0
  sag_root=$(git rev-parse --show-toplevel 2>/dev/null) || sag_root=""
  case "$sag_plan" in
    /*) : ;;
    *)  [ -n "$sag_root" ] && [ -f "$sag_root/$sag_plan" ] && sag_plan="$sag_root/$sag_plan" ;;
  esac
  [ -f "$sag_plan" ] || return 0                                  # fail-OPEN: no plan doc

  # The plan names its spec as `**Spec:** <path>` (backticks optional). `inline — no spec` is a
  # legitimate, documented mode — planning without a spec is allowed, so it must never block.
  # `-`/`+` in the leading class: 6 real plans on this machine write `- **Spec:** <path>`,
  # which the original class silently skipped (fail-open, so a missed block not a false one).
  sag_spec=$(sed -n 's/^[[:space:]>*+-]*\**[Ss]pec:\**[[:space:]]*//p' "$sag_plan" 2>/dev/null \
             | head -1 | tr -d '\r`' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$sag_spec" ] || return 0
  # "inline — no spec" / "none" are documented no-spec modes. Match them only when the value
  # is NOT a path: a real spec at `inline-editor-spec.md` starts with "inline" too, and the
  # loose prefix would have waved it through.
  case "$sag_spec" in
    *.md|*/*) : ;;                                    # looks like a path -> keep checking
    [Ii]nline*|[Nn]one*|-|"") return 0 ;;
  esac
  # Resolve relative to the repo root OR to the plan document's own directory — plans live in
  # docs/specs/ and commonly reference a sibling spec by bare filename.
  case "$sag_spec" in
    /*) : ;;
    *)  if [ -n "$sag_root" ] && [ -f "$sag_root/$sag_spec" ]; then sag_spec="$sag_root/$sag_spec"
        elif [ -f "$(dirname "$sag_plan")/$sag_spec" ]; then sag_spec="$(dirname "$sag_plan")/$sag_spec"
        fi ;;
  esac
  [ -f "$sag_spec" ] || return 0                                  # fail-OPEN: spec not on disk

  sag_st=$(_spec_status "$sag_spec")
  case "$sag_st" in draft|reviewed) ;; *) return 0 ;; esac         # approved / free-text / absent

  _plan_intersects "$sag_plan" "$sag_staged" || return 0          # commit not claimed by this plan
  if ! _is_agent_env; then
    echo "zuvo spec-gate: human committer -> bypass [$sag_spec]" >&2
    return 0
  fi
  echo "BLOCK: this work is planned from a spec that is still '$sag_st', not Approved."
  echo "         spec: $sag_spec"
  echo "         plan: $sag_plan"
  echo "       Approval is the USER's decision. 'Reviewed' means the review converged, not that"
  echo "       anyone signed off — zuvo:plan would silently downgrade to inline mode rather than"
  echo "       stop. Have the user approve the spec (status: Approved), or re-plan without it if"
  echo "       the spec is genuinely not the source of truth."
  return 1
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
