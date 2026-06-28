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
  local range="$1" root f
  [ -n "$range" ] || return 1
  root="$(pg_repo_root)" || return 1
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
  local range="$1" root a d p total=0
  [ -n "$range" ] || { printf '0\n'; return 0; }
  root="$(pg_repo_root)" || { printf '0\n'; return 0; }
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
pg_file_blob() {
  git -C "$1" rev-parse "$2:$3" 2>/dev/null
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
    bcur="$(pg_file_blob "$root" "$head" "$f")"
    [ -n "$bcur" ] || { return 1; }        # file gone/unreadable at head → not coverable → block
    this=0
    for art in "$reviews"/*.md; do
      [ -e "$art" ] || continue
      grep -q '<!-- zuvo-review -->' "$art" 2>/dev/null || continue
      art_files="$(sed -n 's/^files:[[:space:]]*//p' "$art" 2>/dev/null | head -1)"
      pg_files_covered "$f" "$art_files" || continue          # F in artifact's files-set (or *)
      art_range="$(sed -n 's/^range:[[:space:]]*//p' "$art" 2>/dev/null | head -1)"
      art_head="${art_range##*..}"; [ -n "$art_head" ] || continue
      bart="$(pg_file_blob "$root" "$art_head" "$f")"
      [ -n "$bart" ] && [ "$bart" = "$bcur" ] && { this=1; break; }   # SAME content reviewed
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
