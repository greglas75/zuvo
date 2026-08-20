#!/usr/bin/env bash
# Control-block bench gate — a skill edit that steers the pipeline is a change to
# behaviour, so it gets the regime production code gets: no merge without one
# measured comparative run.
#
# Why this exists (2026-08-20). A 29-line rewrite of write-tests Step 2's writer
# payload shipped to main on reasoning alone. Its first contact with the rig:
# 11.4M billed tokens and 290 turns against the reverted version's 941k and 46,
# for +1.0pp mutation kill. The reasoning was sound and the outcome was a 12x
# cost regression, because prose that reads like "carry five things" changes how
# thoroughly an agent works, not just how much text it holds. Nothing in the repo
# could have caught that except running it.
#
# What it gates: edits inside the CONTROL BLOCKS listed below — the sections that
# decide what an agent loads, how it classifies, and which gates it must pass.
# Everything else in a skill (wording, examples, docs) is untouched by this hook.
#
# Evidence contract: a bench record under memory/bench/ naming the changed file
# and carrying kill-rate + billed-token + turn-count columns for at least two
# arms. Content-keyed on the file's blob, exactly like the review-coverage
# artifact, so a record cannot be recycled across different edits.
#
# FAIL-OPEN by design: no git, no lib, malformed input, or any internal error
# exits 0. This gate exists to make the measurement habitual, not to become a
# new way for the toolchain to stop working.

set -uo pipefail

INPUT=$(cat 2>/dev/null || true)

_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -r "$_self_dir/lib/pipeline-gate-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$_self_dir/lib/pipeline-gate-lib.sh"
fi

command -v git >/dev/null 2>&1 || exit 0
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$REPO_ROOT" ] || exit 0

# Human pushes are exempt: a person who edits a control block and pushes it has
# made a judgement call and owns it. The gate is aimed at unattended agents,
# which is where an unmeasured behavioural change actually slips through.
if command -v pg_is_agent_env >/dev/null 2>&1; then
  pg_is_agent_env || exit 0
else
  [ -n "${CLAUDE_CODE_ENTRYPOINT:-}${CODEX_SANDBOX:-}${CURSOR_AGENT:-}" ] || exit 0
fi

if [ "${ZUVO_ALLOW_UNMEASURED_CONTROL_EDIT:-}" = "1" ]; then
  echo "zuvo control-block gate: ZUVO_ALLOW_UNMEASURED_CONTROL_EDIT=1 — bypassed (logged)." >&2
  printf '%s control-block-gate bypass %s\n' "$(date -u +%FT%TZ)" "$(git rev-parse --short HEAD 2>/dev/null)" \
    >> "${ZUVO_HOME:-$HOME/.zuvo}/gate-bypass.log" 2>/dev/null || true
  exit 0
fi

# ---- control blocks --------------------------------------------------------
# Headings whose text decides agent behaviour rather than describing it.
CONTROL_PATTERNS='UNIVERSAL WRITER ISOLATION|UNIVERSAL EXECUTOR ISOLATION|Mandatory File Loading|PHASE 0|PHASE 1|Conditional Load|Evaluate TOP-DOWN|Cross-Cutting Families|Critical gates|MANDATORY TOOL CALLS|Stack detection'

# ---- range ------------------------------------------------------------------
range_of_push() {
  # git pre-push stdin: "<local_ref> <local_sha> <remote_ref> <remote_sha>"
  printf '%s\n' "$INPUT" | while read -r _lref lsha _rref rsha; do
    case "$lsha" in ''|*[!0-9a-f]*) continue;; esac
    case "$rsha" in
      0000000*) printf '%s\n' "$lsha";;          # new branch: whole ref
      *)        printf '%s..%s\n' "$rsha" "$lsha";;
    esac
  done | head -1
}

RANGE=$(range_of_push)
[ -n "$RANGE" ] || RANGE=$(git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1 && echo '@{upstream}..HEAD' || echo '')
[ -n "$RANGE" ] || exit 0

CHANGED=$(git diff --name-only "$RANGE" -- 'skills/*/SKILL.md' 'shared/includes/*.md' 2>/dev/null) || exit 0
[ -n "$CHANGED" ] || exit 0

# ---- does the diff touch a control block? ----------------------------------
# git has no notion of markdown structure, so a hunk header carries no section
# name and cannot be trusted for this. Map each changed line back to the nearest
# preceding heading in the POST-EDIT file and test that instead.
HEAD_SHA=$(printf '%s' "$RANGE" | sed 's/.*\.\.//')
[ -n "$HEAD_SHA" ] || HEAD_SHA=HEAD

section_of_changed_lines() {
  local file="$1"
  local lines
  lines=$(git diff -U0 "$RANGE" -- "$file" 2>/dev/null \
          | awk '/^@@/ { if (match($0, /\+[0-9]+/)) print substr($0, RSTART+1, RLENGTH-1) }')
  [ -n "$lines" ] || return 1
  git show "$HEAD_SHA:$file" 2>/dev/null | awk -v want="$lines" -v pat="$CONTROL_PATTERNS" '
    BEGIN { n = split(want, W, "\n"); for (i = 1; i <= n; i++) if (W[i] != "") T[W[i] + 0] = 1 }
    /^#{1,6} / || /^\*\*[A-Z]/ { sec = $0 }
    { if (NR in T && sec ~ pat) { found = 1 } }
    END { exit(found ? 0 : 1) }'
}

TOUCHED=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # a control edit either lands inside a control section, or moves the heading
  # line itself (rename/removal of the block)
  if section_of_changed_lines "$f" \
     || git diff -U0 "$RANGE" -- "$f" 2>/dev/null | grep -qE "^[+-].*($CONTROL_PATTERNS)"; then
    TOUCHED="$TOUCHED$f"$'\n'
  fi
done <<< "$CHANGED"

[ -n "$TOUCHED" ] || exit 0

# ---- evidence ---------------------------------------------------------------
# One record per control edit, keyed on the post-edit blob of the changed file,
# so evidence for yesterday's payload cannot be reused for today's classifier.
BENCH_DIR="$REPO_ROOT/memory/bench"
MISSING=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  blob=$(git rev-parse "$(printf '%s' "$RANGE" | sed 's/.*\.\.//'):$f" 2>/dev/null | cut -c1-12)
  [ -n "$blob" ] || continue
  if ! grep -rqs -- "$blob" "$BENCH_DIR" 2>/dev/null; then
    MISSING="$MISSING  $f  (blob $blob)"$'\n'
  fi
done <<< "$TOUCHED"

[ -n "$MISSING" ] || exit 0

cat >&2 <<EOF

╭─ zuvo control-block gate ───────────────────────────────────────────────╮
│ A control block changed with no measured comparative run behind it.     │
╰─────────────────────────────────────────────────────────────────────────╯

Unmeasured control edits in this push:
$MISSING
A control block decides what the agent loads, how it classifies, and which
gates it must pass. Rewording one changes behaviour, not just text — the
2026-08-20 payload rewrite cost 12x tokens for +1.0pp kill-rate, and only
running it revealed that.

Required: one comparative rig run — the changed version against the version
it replaces, on at least one corpus case, reporting kill-rate, billed tokens
and turn count for both.

Record it as memory/bench/<slug>.md containing the post-edit blob id shown
above, then push again.

Human override (attributable, logged): ZUVO_ALLOW_UNMEASURED_CONTROL_EDIT=1
EOF
exit 1
