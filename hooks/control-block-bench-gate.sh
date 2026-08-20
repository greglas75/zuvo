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
  # Mirror pipeline-gate-lib.sh::pg_is_agent_env exactly. A shorter list here is not a
  # smaller version of the same check — it is a documented way for an agent to be read
  # as human by unsetting three variables.
  _cb_agent=0
  for _v in ZUVO_AGENT CLAUDECODE CLAUDE_PLUGIN_ROOT CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION \
            CODEX_WORKSPACE CODEX_SANDBOX CODEX_HOME CURSOR_AGENT CURSOR_TRACE_ID \
            GEMINI_CLI ANTIGRAVITY GEMINI_ANTIGRAVITY ANTIGRAVITY_SESSION_ID ZUVO_AI_RUN; do
    [ -n "${!_v:-}" ] && { _cb_agent=1; break; }
  done
  [ "$_cb_agent" = "1" ] || exit 0
fi

if [ "${ZUVO_ALLOW_UNMEASURED_CONTROL_EDIT:-}" = "1" ]; then
  echo "zuvo control-block gate: ZUVO_ALLOW_UNMEASURED_CONTROL_EDIT=1 — bypassed (logged)." >&2
  # `$HOME` unset (minimal containers, some CI) would abort under `set -u` during the
  # redirect's expansion — before `|| true` can catch it — so the override would CRASH
  # and block the push it exists to permit.
  _cb_log="${ZUVO_HOME:-${HOME:-/tmp}/.zuvo}"
  mkdir -p "$_cb_log" 2>/dev/null || true
  printf '%s control-block-gate bypass %s\n' "$(date -u +%FT%TZ)" "$(git rev-parse --short HEAD 2>/dev/null)" \
    >> "$_cb_log/gate-bypass.log" 2>/dev/null || true
  exit 0
fi

# ---- control blocks --------------------------------------------------------
# Headings whose text decides agent behaviour rather than describing it.
CONTROL_PATTERNS='UNIVERSAL WRITER ISOLATION|UNIVERSAL EXECUTOR ISOLATION|Mandatory File Loading|PHASE 0|PHASE 1|Conditional Load|Evaluate TOP-DOWN|Cross-Cutting Families|Critical gates|MANDATORY TOOL CALLS|Stack detection'

# ---- ranges -----------------------------------------------------------------
# EVERY pushed ref, not the first. git does not order refs by sensitivity, so a
# harmless first ref would otherwise escort an unmeasured control edit through.
#
# A new branch (remote sha all-zeros) needs a real BASE. A lone SHA is not a range:
# `git diff --name-only <sha>` compares that commit to the WORKING TREE, so on a clean
# tree it prints nothing and the gate passes a branch it never inspected. Both providers
# of the 2026-08-20 adversarial pass found this independently.
EMPTY_TREE=$(git hash-object -t tree /dev/null 2>/dev/null)

ranges_of_push() {
  printf '%s\n' "$INPUT" | while read -r _lref lsha _rref rsha; do
    case "$lsha" in ''|*[!0-9a-f]*) continue;; esac
    case "$lsha" in 0000000*) continue;; esac        # ref deletion: nothing pushed
    case "$rsha" in
      0000000*)
        base=""
        for cand in origin/HEAD origin/main origin/master main master; do
          if git rev-parse --verify -q "$cand" >/dev/null 2>&1; then
            b=$(git merge-base "$cand" "$lsha" 2>/dev/null) && [ -n "$b" ] && { base="$b"; break; }
          fi
        done
        [ -n "$base" ] || base="$EMPTY_TREE"          # root commit: diff against nothing
        printf '%s..%s\n' "$base" "$lsha"
        ;;
      *)
        # A force push can name a remote sha this clone does not have; falling back to
        # the empty tree over-reports rather than under-reports, which is the safe side.
        if git cat-file -e "$rsha^{commit}" 2>/dev/null; then
          printf '%s..%s\n' "$rsha" "$lsha"
        else
          printf '%s..%s\n' "$EMPTY_TREE" "$lsha"
        fi
        ;;
    esac
  done
}

RANGES=$(ranges_of_push)
if [ -z "$RANGES" ]; then
  git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1 && RANGES='@{upstream}..HEAD'
fi
[ -n "$RANGES" ] || exit 0

# ---- does the diff touch a control block? ----------------------------------
# git has no notion of markdown structure, so a hunk header carries no section name.
# Map changed lines back to the nearest preceding heading instead — on BOTH sides:
# an addition is judged by the post-edit file, a deletion by the pre-edit one. Judging
# only the post-edit side lets a pure deletion inside a control block map to whatever
# section now occupies those line numbers, which is usually the next one along.
section_hit() {                      # section_hit <blob-ref> <lines...>
  local ref="$1"; shift
  local lines="$*"
  [ -n "$lines" ] || return 1
  git show "$ref" 2>/dev/null | awk -v want="$lines" -v pat="$CONTROL_PATTERNS" '
    BEGIN { n = split(want, W, " "); for (i = 1; i <= n; i++) if (W[i] != "") T[W[i] + 0] = 1 }
    /^```/ { fence = !fence; next }                       # a heading inside a fence is text
    !fence && (/^#{1,6} / || /^\*\*[A-Z]/) { sec = $0 }
    { if ((NR in T) && sec ~ pat) found = 1 }
    END { exit(found ? 0 : 1) }'
}

# Expand `@@ -a,b +c,d @@` into every touched line on the requested side. Taking only
# the hunk's first line tests one line out of d, so a hunk that starts in prose and
# continues into a control block reads as clean.
hunk_lines() {                       # hunk_lines <side:+|-> <range> <file>
  local side="$1" rng="$2" file="$3"
  git diff -U0 "$rng" -- "$file" 2>/dev/null | awk -v side="$side" '
    /^@@/ {
      if (match($0, side "[0-9]+(,[0-9]+)?")) {
        spec = substr($0, RSTART + 1, RLENGTH - 1)
        split(spec, P, ",")
        start = P[1] + 0; count = (2 in P) ? P[2] + 0 : 1
        for (i = 0; i < count; i++) print start + i
      }
    }'
}

TOUCHED=""
for RANGE in $RANGES; do
  CHANGED=$(git diff --name-only "$RANGE" -- 'skills/*/SKILL.md' 'shared/includes/*.md' 2>/dev/null) || continue
  [ -n "$CHANGED" ] || continue
  BASE_SHA=${RANGE%%..*}; HEAD_SHA=${RANGE##*..}
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$TOUCHED" in *"|$HEAD_SHA:$f|"*) continue;; esac
    added=$(hunk_lines '+' "$RANGE" "$f")
    removed=$(hunk_lines '-' "$RANGE" "$f")
    # shellcheck disable=SC2086  # deliberate: the line lists are passed as separate args
    if section_hit "$HEAD_SHA:$f" $added \
       || section_hit "$BASE_SHA:$f" $removed \
       || git diff -U0 "$RANGE" -- "$f" 2>/dev/null \
            | grep -qE "^[+-](#{1,6} |\*\*)[^\n]*($CONTROL_PATTERNS)"; then
      # the fallback is heading-shaped ONLY: prose that merely mentions "Stack detection"
      # is not a control edit, and a gate that cries wolf teaches people to override it
      TOUCHED="$TOUCHED|$HEAD_SHA:$f|"
    fi
  done <<< "$CHANGED"
done

[ -n "$TOUCHED" ] || exit 0

# ---- evidence ---------------------------------------------------------------
# Read the record from the PUSHED TREE, never the working tree: a record that exists
# only on the author's disk is not evidence anyone else can check, and pushing the skill
# commit while leaving the record uncommitted was a one-line bypass.
#
# And validate the record's CONTENT. Requiring only that the blob id appears somewhere
# under memory/bench/ makes a one-line placeholder sufficient — the exact ceremony this
# gate exists to prevent, reproduced inside the gate itself.
record_valid() {                     # record_valid <tree-ish> <blob>
  local tree="$1" blob="$2" file rec
  for file in $(git ls-tree -r --name-only "$tree" -- memory/bench/ 2>/dev/null); do
    rec=$(git show "$tree:$file" 2>/dev/null) || continue
    printf '%s' "$rec" | grep -qF -- "$blob" || continue
    # Parse the table STRUCTURALLY. Grepping for the words "kill", "billed" and "turns"
    # is satisfied by the header row itself — the adversarial pass on the previous fix
    # produced a passing record consisting of nothing but a blob id and an empty table.
    # A record counts only if at least two DATA rows carry three numbers each.
    printf '%s' "$rec" | awk '
      /^[[:space:]]*\|/ {
        line = $0
        gsub(/^[[:space:]]*\|/, "", line); gsub(/\|[[:space:]]*$/, "", line)
        if (line ~ /^[[:space:]:|-]+$/) next            # separator row
        n = split(line, C, "|")
        nums = 0
        for (i = 1; i <= n; i++) {
          cell = C[i]; gsub(/[[:space:]*`]/, "", cell)
          # a measurement: 87.9% | 941k | 3,440k | 46 | 0.879
          if (cell ~ /^[0-9][0-9,.]*(%|[kKmM])?$/) nums++
        }
        if (nums >= 3) rows++
      }
      END { exit(rows >= 2 ? 0 : 1) }' || continue
    printf '%s' "$file"; return 0
  done
  return 1
}

MISSING=""
for entry in $(printf '%s' "$TOUCHED" | tr '|' '\n' | grep -v '^$' | sort -u); do
  tree=${entry%%:*}; f=${entry#*:}
  blob=$(git rev-parse "$tree:$f" 2>/dev/null | cut -c1-12)
  [ -n "$blob" ] || continue
  record_valid "$tree" "$blob" >/dev/null || MISSING="$MISSING  $f  (blob $blob)"$'\n'
done

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
