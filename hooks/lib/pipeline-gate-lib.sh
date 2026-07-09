#!/usr/bin/env bash
# hooks/lib/pipeline-gate-lib.sh
#
# Shared detection library for the zuvo pipeline-entry gates (pre-push, CI,
# commit-nudge, Stop-nudge). Pure functions, sourced by the gates.
#
# CONTRACT (see docs/specs/2026-06-27-pipeline-entry-enforcement-notes.md):
#   - The RANGE is ALWAYS an explicit argument. No function infers it from
#     session state, markers, or wall-clock. Callers supply the canonical
#     range (pre-push: git stdin; CI: PR/push range; nudges: merge-base..HEAD).
#   - The signal is CONTENT-keyed review coverage, not pipeline recency.
#     pg_range_reviewed asks "is THIS range/file-set reviewed?" — a review of
#     files X never whitelists unrelated files Y.
#   - FAIL-OPEN everywhere: malformed input / missing repo / git failure →
#     safe default (not-substantial / reviewed-unknown), never a hard abort.
#
# This file is SOURCED, so it must never `set -e`/`set -u`/`exit` — those would
# kill the host hook. All errors are signalled by return codes.
#
# Return-code conventions:
#   pg_is_substantial   : 0 = substantial (block-eligible), 1 = not
#   pg_range_reviewed    : 0 = covered, 1 = definitively NOT covered, 2 = unknown/error
#   pg_allow_adhoc       : 0 = escape active, 1 = not
#   pg_is_agent_env      : 0 = agent invocation, 1 = human
#   pg_is_production      : 0 = production path, 1 = non-production

# --- thresholds (env-overridable) -------------------------------------------
PG_MIN_FILES_DEFAULT=3
PG_MIN_LINES_DEFAULT=150

pg_min_files() { printf '%s\n' "${ZUVO_GATE_MIN_FILES:-$PG_MIN_FILES_DEFAULT}"; }
pg_min_lines() { printf '%s\n' "${ZUVO_GATE_MIN_LINES:-$PG_MIN_LINES_DEFAULT}"; }

# --- repo / branch helpers --------------------------------------------------
pg_repo_root() {
  if [ -n "${PG_REPO_ROOT:-}" ]; then printf '%s\n' "$PG_REPO_ROOT"; return 0; fi
  git rev-parse --show-toplevel 2>/dev/null || return 1
}

pg_default_branch() {
  local root db
  root="$(pg_repo_root)" || { printf '%s\n' "${ZUVO_DEFAULT_BRANCH:-main}"; return 0; }
  db="$(git -C "$root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
  [ -n "$db" ] || db="${ZUVO_DEFAULT_BRANCH:-main}"
  printf '%s\n' "$db"
}

# merge-base..HEAD range for best-effort nudges (NOT session state)
pg_mergebase_range() {
  local root db base
  root="$(pg_repo_root)" || return 1
  db="$(pg_default_branch)"
  base="$(git -C "$root" merge-base HEAD "$db" 2>/dev/null)" || return 1
  [ -n "$base" ] || return 1
  printf '%s..HEAD\n' "$base"
}

# Range of genuinely-NEW local work: commits reachable from HEAD but not from ANY
# remote-tracking branch. Already-pushed commits cleared the pre-push/CI gate in their
# own session — and their memory/reviews/ artifacts may live in a DIFFERENT checkout
# (memory/reviews is git-ignored, per-checkout), so re-scrutinizing them here is the
# develop-far-ahead-of-main false alarm: a fresh worktree branched off origin/develop
# dragged the whole develop..main delta in as "unreviewed". Only un-pushed local
# commits are this session's responsibility.
# Optional arg = tip ref (default HEAD), so the pre-push gate can pass the pushed sha.
#   exit 0 + "<base>..<tip>" → un-pushed local work to check
#   exit 1                   → no remote-tracking refs (caller falls back to merge-base)
#   exit 3                   → remotes exist but nothing un-pushed (caller: nothing to gate)
pg_unpushed_range() {
  local root tip="${1:-HEAD}"
  root="$(pg_repo_root)" || return 1
  [ -n "$(git -C "$root" for-each-ref --count=1 --format='%(refname)' refs/remotes 2>/dev/null)" ] || return 1  # no remotes → merge-base fallback
  [ -n "$(git -C "$root" rev-list "$tip" --not --remotes 2>/dev/null | head -1)" ] || return 3  # all pushed → nothing to gate
  # Emit the @unpushed SENTINEL — pg_changed_production/pg_changed_lines resolve it to the exact
  # un-pushed file/line set via `git log -c --not --remotes` (base-free, topology-complete). This
  # replaced the old per-topology base computation (fork-point / newest-remote-ancestor) and its
  # O(N)-over-remote-refs merge-base loop: `--not --remotes` excludes everything already on a remote
  # for ALL shapes (linear / develop-ahead / single- AND multi-merge / octopus) with no base to
  # mis-pick, so the whole class of range-scoping edge cases (and B-gate-multimerge) is closed.
  # `..$tip` keeps head-parsing (${range##*..}) working in every consumer unchanged.
  printf '@unpushed..%s\n' "$tip"
}

# --- classification ---------------------------------------------------------
# A path is PRODUCTION unless it matches a test/docs/config/generated pattern.
# Fail-toward-enforcement: anything not clearly non-production counts as prod.
pg_is_production() {
  local p="$1"
  [ -n "$p" ] || return 1
  case "$p" in
    tests/*|*/tests/*)                 return 1 ;;
    __tests__/*|*/__tests__/*)         return 1 ;;
    *.test.*|*.spec.*)                 return 1 ;;
    docs/*|*/docs/*)                   return 1 ;;
    *.md)                              return 1 ;;
    *.json|*.yaml|*.yml|*.toml)        return 1 ;;
    *.lock)                            return 1 ;;
    .*rc|*/.*rc)                       return 1 ;;
    zuvo/*|*/zuvo/*)                   return 1 ;;
    *)                                 return 0 ;;
  esac
}

# Read paths (args or stdin), print only the production ones.
pg_classify_files() {
  local f
  if [ "$#" -gt 0 ]; then
    for f in "$@"; do [ -n "$f" ] && pg_is_production "$f" && printf '%s\n' "$f"; done
  else
    while IFS= read -r f; do [ -n "$f" ] && pg_is_production "$f" && printf '%s\n' "$f"; done
  fi
}

# Production files changed in <range>.
pg_changed_production() {
  local range="$1" root f tip
  [ -n "$range" ] || return 1
  root="$(pg_repo_root)" || return 1
  # @unpushed sentinel: the topology-agnostic un-pushed file set via `git log -c --not --remotes`,
  # NOT a two-dot diff. `--not --remotes` excludes everything already on a remote (merged-in main,
  # develop-ahead, every merged branch) across ALL topologies without a base; `-c` keeps merge
  # conflict resolutions but not the merged-in content (Task 1 spike proved a-i). sort -u dedups a
  # file touched by several un-pushed commits.
  if [ "${range%%..*}" = "@unpushed" ]; then
    tip="${range##*..}"
    # -z: NUL-delimited, path-safe (matches the git-diff path below — a filename with a newline
    # cannot split a record). core.quotePath=false: unquoted UTF-8 paths.
    git -C "$root" -c core.quotePath=false log --format= --name-only -z -c "$tip" --not --remotes 2>/dev/null \
      | while IFS= read -r -d '' f; do [ -n "$f" ] && pg_is_production "$f" && printf '%s\n' "$f"; done \
      | sort -u
    return 0
  fi
  # --no-renames: report renames as delete(old)+add(new) with CLEAN paths.
  # -z + core.quotePath=false: NUL-delimited, UNquoted paths, so filenames with
  # spaces/specials are classified correctly (git would otherwise quote them).
  git -C "$root" -c core.quotePath=false diff --name-only --no-renames -z "$range" 2>/dev/null \
    | while IFS= read -r -d '' f; do
        [ -n "$f" ] && pg_is_production "$f" && printf '%s\n' "$f"
      done
}

# Total add+del across PRODUCTION files in <range> (binary files counted as 0).
pg_changed_lines() {
  local range="$1" root a d p total=0 tip
  [ -n "$range" ] || { printf '0\n'; return 0; }
  root="$(pg_repo_root)" || { printf '0\n'; return 0; }
  # @unpushed sentinel → un-pushed numstat via git log (mirrors pg_changed_production). The
  # numeric-first-field guard below skips a merge's combined-numstat rows safely (files carry the
  # merge signal via pg_changed_production); non-merge un-pushed lines sum correctly.
  #   SEMANTICS (deliberate, adversarial-noted): this is per-commit CHURN across the un-pushed
  #   commits, not a single final-range delta — a base-free log has no single boundary to diff
  #   against (that base is exactly what this rewrite removes). Churn ≥ final delta, so the only
  #   effect is that edit-then-revert across commits may cross the line threshold slightly sooner:
  #   a SAFE OVER-COUNT (more review, never less — never an under-scope). The authoritative gate
  #   signal is the exact FILE count (pg_changed_production, ≥MIN_FILES); the line threshold is the
  #   secondary trip. Merge conflict-resolution files still count toward FILES via
  #   pg_changed_production even when their combined-numstat rows are skipped here.
  if [ "${range%%..*}" = "@unpushed" ]; then
    tip="${range##*..}"
    while IFS=$'\t' read -r a d p; do
      [ -n "$p" ] || continue
      pg_is_production "$p" || continue
      [ "$a" = "-" ] && a=0; [ "$d" = "-" ] && d=0
      case "$a$d" in *[!0-9]*) continue ;; esac
      total=$(( total + a + d ))
    done < <(git -C "$root" -c core.quotePath=false log --format= --numstat -c "$tip" --not --remotes 2>/dev/null)
    printf '%s\n' "$total"; return 0
  fi
  while IFS=$'\t' read -r a d p; do
    [ -n "$p" ] || continue
    pg_is_production "$p" || continue
    [ "$a" = "-" ] && a=0
    [ "$d" = "-" ] && d=0
    case "$a$d" in *[!0-9]*) continue ;; esac
    total=$(( total + a + d ))
  done < <(git -C "$root" -c core.quotePath=false diff --numstat --no-renames "$range" 2>/dev/null)
  printf '%s\n' "$total"
}

# --- substantiality ---------------------------------------------------------
# 0 = substantial (>= MIN_FILES prod files OR >= MIN_LINES add+del), else 1.
pg_is_substantial() {
  local range="$1" nfiles lines
  [ -n "$range" ] || return 1                 # fail-open: no range → not substantial
  pg_repo_root >/dev/null 2>&1 || return 1    # fail-open: no repo

  nfiles="$(pg_changed_production "$range" 2>/dev/null | grep -c .)"
  [ -z "$nfiles" ] && nfiles=0
  [ "$nfiles" -ge "$(pg_min_files)" ] 2>/dev/null && return 0

  lines="$(pg_changed_lines "$range" 2>/dev/null)"
  [ -z "$lines" ] && lines=0
  [ "$lines" -ge "$(pg_min_lines)" ] 2>/dev/null && return 0

  return 1
}

# --- content-keyed review coverage ------------------------------------------
# Is the set of change files ⊆ the artifact's files: list (or files: == '*')?
pg_files_covered() {
  local change_files="$1" art_files="$2" cf norm
  [ -n "$art_files" ] || return 1
  [ "$art_files" = "*" ] && return 0
  [ -n "$change_files" ] || return 1
  # normalize art_files into ,a,b,c, — split on COMMA only (NOT spaces, so a
  # reviewed filename containing spaces stays intact), trimming surrounding ws.
  norm=",$(printf '%s' "$art_files" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | paste -sd, -),"
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    case "$norm" in *",$cf,"*) ;; *) return 1 ;; esac
  done <<EOF
$change_files
EOF
  return 0
}

# Blob hash of <path> at <ref> (a committish), via the repo at <root>. Empty if absent.
# --verify is MANDATORY: without it, `git rev-parse ref:missing` echoes the LITERAL
# "ref:missing" string (non-empty, even with 2>/dev/null) for a DELETED path instead of
# failing — which made every deleted file present a bogus, un-matchable "blob" and so look
# permanently "uncovered". A refactor deleting N files then wrongly blocked on all N.
pg_file_blob() {
  git -C "$1" rev-parse --verify "$2:$3" 2>/dev/null
}

# 0 = covered, 1 = definitively NOT covered, 2 = unknown/error (fail-open).
#
# CONTENT-KEYED coverage (by file CONTENT, not commit range): a change is covered
# iff EVERY changed production file's CURRENT content was reviewed by some artifact.
# A file F (current blob B at the change head) is covered by artifact A iff F is in
# A's files-set (or A.files == '*') AND F's blob at A's reviewed head equals B
# (i.e. the exact content A reviewed is what is being shipped).
#
# Why content, not range:
#   - "review already ran in the producing pipeline" (write-tests/build/execute)
#     → that skill wrote an artifact for the file's content → covered, NO redundant
#     standalone review needed.
#   - multi-agent SHARED branch: a push passes iff EVERY file in it was reviewed by
#     SOME pipeline — regardless of which agent authored which commit (the contaminated
#     merge-base..HEAD range no longer forces reviewing other agents' work).
#   - NO permanent whitelist: re-editing a reviewed file changes its blob → the old
#     artifact (different blob) no longer covers it → a fresh review is required.
#   - genuine freelance (raw Edit, no pipeline) → file's content unreviewed → blocked.
pg_range_reviewed() {
  local range="$1" root reviews head change_files f bcur art art_range art_files art_head bart this any=0
  [ -n "$range" ] || return 2
  root="$(pg_repo_root)" || return 2
  head="${range##*..}"; [ -n "$head" ] || return 2
  git -C "$root" rev-parse --verify "${head}^{commit}" >/dev/null 2>&1 || return 2   # unresolvable → unknown
  reviews="$root/memory/reviews"
  [ -d "$reviews" ] || return 1            # repo present, no reviews dir → NOT covered

  change_files="$(pg_changed_production "$range" 2>/dev/null)"
  [ -n "$change_files" ] || return 1       # no production files → nothing grants coverage

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    any=1
    # bcur empty ⇒ F is DELETED at head (no shippable content). A deletion is COVERED when
    # an artifact reviewed the SAME deletion — F in its files-set AND F also absent at its
    # reviewed head (so both blobs empty). --verify guarantees absent⇒empty, so a "" == ""
    # match is a genuine reviewed-deletion, never a stray literal string. Do NOT hard-block
    # on bcur empty (that made every reviewed deletion look "uncovered").
    bcur="$(pg_file_blob "$root" "$head" "$f")"
    this=0
    # For a DELETION (bcur empty), resolve the exact commit that removed F within THIS checked
    # range, so coverage can require the artifact's range to CONTAIN that specific commit —
    # content-keying alone cannot tell two deletions of the same path apart.
    delc=""
    [ -z "$bcur" ] && delc="$(git -C "$root" log --diff-filter=D --no-renames --format=%H "$range" -- "$f" 2>/dev/null | head -1)"
    for art in "$reviews"/*.md; do
      [ -e "$art" ] || continue
      grep -q '<!-- zuvo-review -->' "$art" 2>/dev/null || continue
      art_files="$(sed -n 's/^files:[[:space:]]*//p' "$art" 2>/dev/null | head -1)"
      pg_files_covered "$f" "$art_files" || continue          # F in artifact's files-set (or *)
      art_range="$(sed -n 's/^range:[[:space:]]*//p' "$art" 2>/dev/null | head -1)"
      art_head="${art_range##*..}"; [ -n "$art_head" ] || continue
      if [ -n "$bcur" ]; then
        bart="$(pg_file_blob "$root" "$art_head" "$f")"
        [ "$bart" = "$bcur" ] && { this=1; break; }          # existing file: SAME content (incl. files:*)
      else
        # DELETED file: covered iff the artifact EXPLICITLY lists F (not '*') AND its reviewed
        # range CONTAINS the exact commit that deleted F — delc reachable from art_head but NOT
        # from art_base. That ties coverage to THIS deletion; a same-path deletion reviewed in
        # an unrelated range/branch (or a files:'*' artifact) does not silently cover it.
        art_base="${art_range%%..*}"
        if [ "$art_files" != "*" ] && [ -n "$delc" ] && [ -n "$art_base" ] \
           && git -C "$root" merge-base --is-ancestor "$delc" "$art_head" 2>/dev/null \
           && ! git -C "$root" merge-base --is-ancestor "$delc" "$art_base" 2>/dev/null; then
          this=1; break
        fi
      fi
    done
    [ "$this" -eq 1 ] || return 1          # this file's current content is not reviewed → NOT covered
  done <<EOF
$change_files
EOF

  [ "$any" -eq 1 ] && return 0             # every changed production file covered by content
  return 1
}

# --- escape valves / env detection ------------------------------------------
pg_allow_adhoc() {
  [ "${ZUVO_ALLOW_ADHOC:-}" = "1" ] && return 0
  return 1
}

pg_is_agent_env() {
  [ "${ZUVO_AGENT:-0}" = "1" ] && return 0
  local v
  for v in CLAUDECODE CLAUDE_PLUGIN_ROOT CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION \
           CODEX_WORKSPACE CODEX_SANDBOX CODEX_HOME \
           CURSOR_AGENT CURSOR_TRACE_ID \
           GEMINI_CLI ANTIGRAVITY GEMINI_ANTIGRAVITY; do
    [ -n "${!v:-}" ] && return 0
  done
  return 1
}

# Marker so callers can verify the lib loaded.
PG_LIB_LOADED=1
