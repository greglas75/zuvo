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
#   pg_uncovered_files   : 0 = computed (stdout = uncovered files, may be empty),
#                          2 = unknown/error, 3 = no production files in range
#   pg_allow_adhoc       : 0 = escape active, 1 = not
#   pg_is_agent_env      : 0 = agent invocation, 1 = human
#   pg_is_production      : 0 = production path, 1 = non-production

# --- thresholds (env-overridable) -------------------------------------------

# Shared path-containment rule (B-PATH-CONTAIN-SHARED-FN). Installed alongside this file, so
# `dirname` resolves it in the repo AND in ~/.claude/hooks/lib/.
_pgl_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
_pgl_agent_dir="$_pgl_dir"
if [ -r "$_pgl_dir/path-contain.sh" ]; then
  # shellcheck source=/dev/null
  . "$_pgl_dir/path-contain.sh"
fi

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

# _pgl_unpushed_commits <root> <tip> — the commits the @unpushed sentinel stands for: `<tip> --not
# --remotes`, MINUS TWINS. A twin is a non-merge commit whose `git patch-id --stable` equals that of a
# commit already on a remote but outside <tip>'s history: a cherry-pick or rebase of pushed work. Its
# change is on the remote already and cleared the gate there; counting it again demanded a review of
# content that had one — the review simply lived in another checkout's memory/reviews (2026-10-05:
# 26bef0d5/0eba8782, byte-identical to origin's reviewed 99035e07/a7224dc0, blocked a push).
#
# The remote side is bounded by date: a cherry-pick and a rebase both keep the AUTHOR date, so a twin's
# original was committed no earlier than the oldest un-pushed author date. When no remote commit falls in
# that window (the usual push), no patch-id is computed at all. A branch rebased from months back would
# widen the window to months of remote history, so the scan also stops after PG_TWIN_SCAN_MAX remote
# commits in git's walk order (default 500; 0 turns twin detection off; a value that is not 1-6
# digits falls back to 500 rather than reaching shell arithmetic).
#
# Failure directions: anything that goes wrong in the TWIN step (patch-id, the window, the cap) leaves
# the commit in the set — a twin missed is a review demanded. A failing base rev-list is rc 1, so a
# caller can tell "git failed" from "nothing un-pushed" (rc 0, no output).
_pgl_unpushed_commits() {
  local root="$1" tip="$2" all since twins max="${PG_TWIN_SCAN_MAX:-500}"
  case "$max" in ''|*[!0-9]*|???????*) max=500 ;; esac
  all="$(git -C "$root" rev-list "$tip" --not --remotes 2>/dev/null)" || return 1
  [ -n "$all" ] || return 0
  since="$(printf '%s\n' "$all" | git -C "$root" log --stdin --no-walk=unsorted --format=%at 2>/dev/null \
    | sort -n | head -1)"
  twins=""
  if [ -n "$since" ] && [ "$max" -gt 0 ] && [ -n "$(git -C "$root" rev-list -1 --no-merges --since="@$since" \
       --remotes --not "$tip" 2>/dev/null)" ]; then
    twins="$(awk 'NR == FNR { onremote[$1] = 1; next } ($1 in onremote) { print $2 }' \
      <(git -C "$root" -c log.showSignature=false -c color.ui=never log -p --no-merges --no-ext-diff \
          --max-count="$max" --since="@$since" --remotes --not "$tip" 2>/dev/null \
          | git -C "$root" patch-id --stable 2>/dev/null) \
      <(printf '%s\n' "$all" | git -C "$root" -c log.showSignature=false -c color.ui=never log --stdin \
          --no-walk=unsorted -p --no-merges --no-ext-diff 2>/dev/null | git -C "$root" patch-id --stable 2>/dev/null))"
  fi
  if [ -z "$twins" ]; then printf '%s\n' "$all"; return 0; fi
  awk 'NR == FNR { twin[$1] = 1; next } !($1 in twin)' <(printf '%s\n' "$twins") <(printf '%s\n' "$all")
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
    # `.zuvo/` (z KROPKA) to dowody generowane skryptem (np. T3A: `.zuvo/proofs/*.txt`).
    # Wzorzec `zuvo/*` ich nie lapal, wiec kazde odswiezenie dowodow dostawalo pelna
    # recenzje adwersaryjna tresci, ktorej nikt nie pisze recznie — kilkanascie plikow na
    # fale i godziny czekania przy pushu. Recenzujemy generator, nie jego wynik.
    .zuvo/*|*/.zuvo/*)                 return 1 ;;
    # Extensionless repo-metadata files. Without these the `*)` catch-all below
    # classifies them as production, so a pure release/metadata commit (which
    # bumps VERSION and nothing else — every other file in it is already excluded
    # as *.md/*.json) counts as production work and demands its own review
    # artifact. They carry no logic; excluding them keeps the gate on real code.
    # Build logic (Makefile, Dockerfile, *.sh) is deliberately NOT listed here.
    VERSION|*/VERSION)                 return 1 ;;
    CHANGELOG|*/CHANGELOG)             return 1 ;;
    LICENSE|*/LICENSE|LICENCE|*/LICENCE) return 1 ;;
    NOTICE|*/NOTICE)                   return 1 ;;
    AUTHORS|*/AUTHORS)                 return 1 ;;
    CONTRIBUTORS|*/CONTRIBUTORS)       return 1 ;;
    # CODEOWNERS is deliberately NOT exempt: it decides who must review what, so editing it
    # is a governance change and exactly the kind of edit the gate should still see.
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

# _pgl_range_optlike <range> — 0 when its base or head starts with `-`, which git would take as an option.
_pgl_range_optlike() {
  case "${1%%..*}" in -*) return 0 ;; esac
  case "${1##*..}" in -*) return 0 ;; esac
  return 1
}

# Production files changed in <range>. Returns 1 when git fails: an empty list then means "unknown".
pg_changed_production() {
  local range="$1" root f tip commits
  [ -n "$range" ] || return 1
  _pgl_range_optlike "$range" && return 1
  root="$(pg_repo_root)" || return 1
  # @unpushed sentinel: the topology-agnostic un-pushed file set via `git log -c --not --remotes`,
  # NOT a two-dot diff. `--not --remotes` excludes everything already on a remote (merged-in main,
  # develop-ahead, every merged branch) across ALL topologies without a base; `-c` keeps merge
  # conflict resolutions but not the merged-in content (Task 1 spike proved a-i). sort -u dedups a
  # file touched by several un-pushed commits.
  if [ "${range%%..*}" = "@unpushed" ]; then
    tip="${range##*..}"
    # The un-pushed commits minus cherry-picked/rebased twins of pushed ones (_pgl_unpushed_commits),
    # walked one by one (--no-walk). An EMPTY set must stop here: `git log --stdin` with nothing on
    # stdin falls back to HEAD and would report HEAD's files as un-pushed work.
    commits="$(_pgl_unpushed_commits "$root" "$tip")" || return 1
    [ -n "$commits" ] || return 0
    # -z: NUL-delimited, path-safe (matches the git-diff path below — a filename with a newline
    # cannot split a record). core.quotePath=false: unquoted UTF-8 paths.
    printf '%s\n' "$commits" \
      | git -C "$root" -c core.quotePath=false log --stdin --no-walk=unsorted --format= --name-only -z -c 2>/dev/null \
      | while IFS= read -r -d '' f; do [ -n "$f" ] && pg_is_production "$f" && printf '%s\n' "$f"; done \
      | sort -u
    [ "${PIPESTATUS[1]}" -eq 0 ] || return 1   # a failed git log is not an empty change set
    return 0
  fi
  # --no-renames: report renames as delete(old)+add(new) with CLEAN paths.
  # -z + core.quotePath=false: NUL-delimited, UNquoted paths, so filenames with
  # spaces/specials are classified correctly (git would otherwise quote them).
  git -C "$root" -c core.quotePath=false diff --name-only --no-renames -z "$range" 2>/dev/null \
    | while IFS= read -r -d '' f; do
        [ -n "$f" ] && pg_is_production "$f" && printf '%s\n' "$f"
      done
  [ "${PIPESTATUS[0]}" -eq 0 ] || return 1     # a failed git diff is not an empty change set
  return 0
}

# Total add+del across PRODUCTION files in <range> (binary files counted as 0).
# Optional 2nd arg: the range's production file set, already computed by the caller
# (pg_is_substantial) — saves a second `git log -c --not --remotes` walk. @unpushed only.
pg_changed_lines() {
  local range="$1" root a d p total=0 tip _pgl_prod_set _pgl_nl _pgl_commits
  [ -n "$range" ] || { printf '0\n'; return 0; }
  _pgl_range_optlike "$range" && { printf '0\n'; return 0; }
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
    tip="${range##*..}"; TAB=$(printf '\t')
    # Count lines ONLY for the files pg_changed_production reports. The two git forms disagree on
    # merges and the disagreement was unrecoverable: `--name-only -c` reports a merge's CONFLICT
    # RESOLUTIONS (so a clean merge contributes nothing, correctly), while `--numstat -c` reports a
    # row per file the merge TOUCHED — i.e. the merged-in content `--not --remotes` exists to
    # exclude. A branch whose own commits are docs/tests then measured production FILES = 0 and
    # production LINES = all of the base's advance, so pg_is_substantial demanded a review that
    # pg_range_reviewed could never grant: its `no production files -> nothing grants coverage`
    # guard returns 1 before reading any artifact. Permanently blocked, un-unblockable.
    # Measured 2026-09-19 on tgm-survey-platform: 1677 "production" lines, 0 production files.
    if [ "$#" -ge 2 ]; then _pgl_prod_set="$2"
    else _pgl_prod_set="$(pg_changed_production "$range" 2>/dev/null)" || _pgl_prod_set=""; fi
    [ -n "$_pgl_prod_set" ] || { printf '0\n'; return 0; }
    # Same commit set as pg_changed_production — twins excluded; empty must stop before `--stdin`.
    _pgl_commits="$(_pgl_unpushed_commits "$root" "$tip")" || _pgl_commits=""
    [ -n "$_pgl_commits" ] || { printf '0\n'; return 0; }
    _pgl_nl='
'
    # A merge's COMBINED numstat row is `a1<tab>d1<tab>a2<tab>d2<tab>…<tab>path` (one add/del pair
    # per parent). Parse path = LAST field and add/del = FIRST pair (churn vs parent-1 = the
    # conflict-resolution size), instead of `read -r a d p` which mis-binds path and silently
    # dropped every merge row — an UNDER-count for merge-conflict churn (adversarial-noted). A
    # non-merge row `a<tab>d<tab>path` parses identically. Binary rows ('-') count 0.
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      p=${row##*"$TAB"}
      # Membership in the production set above, not pg_is_production on the row: a merge row's
      # path IS production, which is precisely how the merged-in content used to be counted.
      case "$_pgl_nl$_pgl_prod_set$_pgl_nl" in *"$_pgl_nl$p$_pgl_nl"*) ;; *) continue ;; esac
      a=${row%%"$TAB"*}; rest=${row#*"$TAB"}; d=${rest%%"$TAB"*}
      [ "$a" = "-" ] && a=0; [ "$d" = "-" ] && d=0
      case "$a$d" in *[!0-9]*) continue ;; esac
      total=$(( total + a + d ))
    done < <(printf '%s\n' "$_pgl_commits" \
               | git -C "$root" -c core.quotePath=false log --stdin --no-walk=unsorted --format= --numstat -c \
                   2>/dev/null)
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
  local range="$1" nfiles=0 lines pset f
  [ -n "$range" ] || return 1                 # fail-open: no range → not substantial
  pg_repo_root >/dev/null 2>&1 || return 1    # fail-open: no repo

  pset="$(pg_changed_production "$range" 2>/dev/null)" || pset=""
  while IFS= read -r f; do [ -n "$f" ] && nfiles=$((nfiles + 1)); done <<PGS_FILES
$pset
PGS_FILES
  [ "$nfiles" -ge "$(pg_min_files)" ] 2>/dev/null && return 0

  lines="$(pg_changed_lines "$range" "$pset" 2>/dev/null)"
  [ -z "$lines" ] && lines=0
  [ "$lines" -ge "$(pg_min_lines)" ] 2>/dev/null && return 0

  return 1
}

# --- content-keyed review coverage ------------------------------------------
# Is the set of change files ⊆ the artifact's files: list (or files: == '*')?
# B-12: compare ENTRY BY ENTRY, never by substring-matching a re-joined string.
# The old form normalized the artifact's files: list into `,a,b,c,` and asked whether `,$cf,`
# occurred in it. That is lossy the moment a real path contains a comma: an artifact listing
# `src/a` and `b.js` normalizes to `,src/a,b.js,`, in which a query for the NEVER-REVIEWED file
# literally named `src/a,b.js` matches as a substring — so an unreviewed file read as COVERED,
# and coverage is what decides whether a push is gated. Demonstrated by probe, not theorised.
#
# Residual, and deliberate: the `files:` header is comma-separated, so a path containing a comma
# still cannot be EXPRESSED in it. What changes is the direction of the failure — such a path is
# now simply never covered (a fresh review is demanded) instead of being silently covered by two
# unrelated neighbours. Uncovered is the safe half of that pair.
pg_files_covered() {
  local change_files="$1" art_files="$2" cf ent found
  [ -n "$art_files" ] || return 1
  [ "$art_files" = "*" ] && return 0
  [ -n "$change_files" ] || return 1
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    found=0
    while IFS= read -r ent; do
      [ -n "$ent" ] || continue
      if [ "$ent" = "$cf" ]; then found=1; break; fi
    done <<ENTRIES
$(printf '%s' "$art_files" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
ENTRIES
    [ "$found" -eq 1 ] || return 1
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

# ---------------------------------------------------------------------------
# Proof-of-work for a review artifact (2026-07-23).
#
# The content-key proves an artifact is FRESH (its reviewed content == what is shipped), NOT
# that a review actually happened. A fabricated artifact — `range: <base>..HEAD`, `files: *`,
# the marker, zero review — passes trivially, because its head IS the push head so every
# blob matches itself. Demonstrated, and done in the field (an agent hit this gate, found the
# marker requirement, and just added the marker). So a NEW artifact must additionally reference
# a real cross-model adversarial run: the single most expensive thing to fake here, since it
# shells out to external provider CLIs.
#
# This cannot make coverage UNFORGEABLE — the referenced file is still agent-writable (extends
# B-gate-6: these gates are guardrails against drift, not a security boundary). It raises the
# cost of a fake from "one text edit" to "fabricate a convincing multi-provider transcript",
# which is a categorically more overt dishonest act.
#
# GRANDFATHER: enforced only for artifacts whose FILE mtime is >= PG_REVIEW_PROOF_CUTOFF
# (default 2026-07-23T00:00:00Z). Every artifact already on disk predates that, so this is
# forward-only and false-blocks nobody on rollout — measured: 0 pre-existing proofless
# artifacts newer than the cutoff back any unpushed work. (Residual: `touch -t <past>` on a new
# artifact backdates it under the cutoff — overt filesystem forgery, the same category as any
# other FS tampering this layer does not defend against.)
PG_REVIEW_PROOF_CUTOFF="${PG_REVIEW_PROOF_CUTOFF:-1784764800}"   # 2026-07-23T00:00:00Z

# Each proof is scanned on its own, so the caps bound the work one artifact can demand: refs
# evaluated, comma items split (empty and duplicate ones included), and ref text read.
PG_MAX_PROOF_REFS=16
PG_MAX_PROOF_ITEMS=64
PG_MAX_PROOF_HEADER_CHARS=4096

# pg_artifact_proof_refs <artifact> -> the refs cited from the first valued ref line to the end of
# its non-blank block; the body (retrospective `adversarial: pass1=… | …` lines) is never read.
# Prose values are printed whole, never split, so no fragment of one can pass as a path.
# rc 0 = read (no output = no ref) · 1 = artifact unreadable · 2 = over a cap.
# Bash, not awk: the scan's fault tests stub awk on PATH, which must not blind this reader too.
pg_artifact_proof_refs() {
  local _ppr_line _ppr_val _ppr_on=0 _ppr_out="$_PGL_NL" _ppr_n=0 _ppr_steps=0 _ppr_len=0 _ppr_cut
  local _ppr_lmax=$((PG_MAX_PROOF_HEADER_CHARS + 64))
  { [ -f "$1" ] && [ -r "$1" ]; } || return 1
  while IFS= read -r _ppr_line || [ -n "$_ppr_line" ]; do
    # The cut only bounds pattern work; a cut line that is (or may hide) a ref line is refused.
    _ppr_cut=0
    if [ "${#_ppr_line}" -gt "$_ppr_lmax" ]; then _ppr_line="${_ppr_line:0:$_ppr_lmax}"; _ppr_cut=1; fi
    case "$_ppr_line" in
      *[![:space:]]*) ;;
      *) [ "$_ppr_cut" -eq 0 ] || return 2; [ "$_ppr_on" -eq 1 ] && break; continue ;;
    esac
    _ppr_val="${_ppr_line#"${_ppr_line%%[![:space:]]*}"}"
    case "$_ppr_val" in
      adversarial:*) _ppr_val="${_ppr_val#adversarial:}" ;;
      adv-proof:*) _ppr_val="${_ppr_val#adv-proof:}" ;;
      *) continue ;;
    esac
    [ "$_ppr_cut" -eq 0 ] || return 2
    _ppr_val="${_ppr_val//$_PGL_CR/}"; _ppr_val="${_ppr_val//\`/}"
    _ppr_val="${_ppr_val#"${_ppr_val%%[![:space:]]*}"}"; _ppr_val="${_ppr_val%"${_ppr_val##*[![:space:]]}"}"
    [ -n "$_ppr_val" ] || continue
    _ppr_on=1
    _ppr_len=$((_ppr_len + ${#_ppr_val}))
    [ "$_ppr_len" -le "$PG_MAX_PROOF_HEADER_CHARS" ] || return 2
    _pgl_refs_add "$_ppr_val" || return 2
  done < "$1"
  printf '%s' "${_ppr_out#"$_PGL_NL"}"
}

# pg_proof_ref_is_prose <ref> — 0 when a ref holds whitespace, `;`, `(` or `|`: prose, not a written file.
pg_proof_ref_is_prose() {
  case "$1" in *[[:space:]]*|*';'*|*'('*|*'|'*) return 0 ;; esac
  return 1
}

# _pgl_refs_add <value> — splits one header value into the caller's _ppr_out (dynamic scope),
# counting into _ppr_steps / _ppr_n. rc 2 = a cap was exceeded. A value with any prose item is kept whole.
_pgl_refs_add() {
  local _pra_rest="$1," _pra_item _pra_items="" _pra_prose=0
  while [ "$_pra_prose" -eq 0 ] && [ -n "$_pra_rest" ]; do
    _ppr_steps=$((_ppr_steps + 1))
    [ "$_ppr_steps" -le "$PG_MAX_PROOF_ITEMS" ] || return 2
    _pra_item="${_pra_rest%%,*}"; _pra_rest="${_pra_rest#*,}"
    _pra_item="${_pra_item#"${_pra_item%%[![:space:]]*}"}"; _pra_item="${_pra_item%"${_pra_item##*[![:space:]]}"}"
    [ -n "$_pra_item" ] || continue
    if pg_proof_ref_is_prose "$_pra_item"; then _pra_prose=1; else _pra_items="$_pra_items$_pra_item$_PGL_NL"; fi
  done
  [ "$_pra_prose" -eq 0 ] || _pra_items="$1$_PGL_NL"
  while [ -n "$_pra_items" ]; do
    _pra_item="${_pra_items%%"$_PGL_NL"*}"; _pra_items="${_pra_items#*"$_PGL_NL"}"
    # Quoted inside the pattern, so `*`, `?` and `[` in a ref match literally.
    case "$_ppr_out" in *"$_PGL_NL$_pra_item$_PGL_NL"*) continue ;; esac
    _ppr_n=$((_ppr_n + 1))
    [ "$_ppr_n" -le "$PG_MAX_PROOF_REFS" ] || return 2
    _ppr_out="$_ppr_out$_pra_item$_PGL_NL"
  done
  return 0
}

# pg_artifact_proof_verdict <repo_root> <artifact_path> -> `<token>\t<ref>\t<detail>` per proof ref
# (ref `-` for the artifact itself). rc 0 only when grandfathered or EVERY ref is proven /
# missing-optional. Proven = >=2 `REVIEW BY:` lines, or 1 with an honest single-provider note.
pg_artifact_proof_verdict() {
  local _pv_root="$1" _pv_art="$2" _pv_mt _pv_refs _pv_rc=0 _pv_ref _pv_rest _pv_tok _pv_det _pv_bad=0 _pv_n=0
  # mtime, GNU-first then BSD, sanitized to digits. `stat -f %m` on GNU/Linux means
  # `--file-system` and prints a mount identifier, NOT the mtime — so BSD-first would put a
  # non-numeric value in _pv_mt and the `-lt` below would error on the CI host (Linux). Try
  # `stat -c %Y` (GNU) first, fall back to `stat -f %m` (BSD/macOS). Only an all-digit answer can
  # grandfather: an mtime that cannot be read counts as post-cutoff, so every proof is still checked.
  _pv_mt="$(stat -c %Y "$_pv_art" 2>/dev/null || stat -f %m "$_pv_art" 2>/dev/null)" || _pv_mt=""
  case "$_pv_mt" in ''|*[!0-9]*) _pv_mt="" ;; esac
  if [ -n "$_pv_mt" ] && [ "$_pv_mt" -lt "$PG_REVIEW_PROOF_CUTOFF" ] 2>/dev/null; then
    printf 'grandfathered\t-\tartifact older than the proof cutoff\n'; return 0
  fi
  _pv_refs="$(pg_artifact_proof_refs "$_pv_art")" || _pv_rc=$?
  case "$_pv_rc" in
    0) ;;
    2) printf 'too-many-refs\t-\tover %s refs, %s comma items or %s chars of refs\n' \
         "$PG_MAX_PROOF_REFS" "$PG_MAX_PROOF_ITEMS" "$PG_MAX_PROOF_HEADER_CHARS"; return 1 ;;
    *) printf 'no-ref\t-\tthe artifact cannot be read\n'; return 1 ;;
  esac
  if [ -z "$_pv_refs" ]; then
    printf 'no-ref\t-\tno adversarial: proof path in the header\n'; return 1
  fi
  # Parameter expansion, not a here-doc: a here-doc that cannot be created (full TMPDIR) would run
  # no iteration and fall through to "every ref passed". The count refuses that shape anyway.
  _pv_rest="$_pv_refs$_PGL_NL"
  while [ -n "$_pv_rest" ]; do
    _pv_ref="${_pv_rest%%"$_PGL_NL"*}"; _pv_rest="${_pv_rest#*"$_PGL_NL"}"
    [ -n "$_pv_ref" ] || continue
    _pv_n=$((_pv_n + 1))
    _pv_tok=scan-error; _pv_det="not evaluated"
    _pgl_proof_one "$_pv_root" "$_pv_ref"
    _pgl_clean "$_pv_ref"
    printf '%s\t%s\t%s\n' "$_pv_tok" "$_PGL_CLEAN" "$_pv_det"
    case "$_pv_tok" in proven|missing-optional) ;; *) _pv_bad=1 ;; esac
  done
  if [ "$_pv_n" -eq 0 ]; then
    printf 'no-ref\t-\tno proof ref was evaluated\n'; return 1
  fi
  return "$_pv_bad"
}

# _pgl_clean <text> -> _PGL_CLEAN: header text made safe to echo. Header values are agent-written,
# so control bytes (ESC, BEL, TAB, DEL …) are dropped and the length capped before any message.
# A result variable, not stdout, so the per-ref path forks nothing.
_pgl_clean() {
  _PGL_CLEAN="${1//[[:cntrl:]]/}"
  _PGL_CLEAN="${_PGL_CLEAN:0:200}"
}

# pg_artifact_proven <repo_root> <artifact_path> -> 0 = proven (or grandfathered), 1 = NOT.
pg_artifact_proven() { pg_artifact_proof_verdict "$1" "$2" >/dev/null; }

# _pgl_proof_one <repo_root> <ref> — the verdict for ONE proof ref. Sets the caller's _pv_tok and
# _pv_det (bash dynamic scope); every path that is not a clean scan exit 3 leaves a refusing token.
_pgl_proof_one() {
  local _po_path _po_out _po_rc=0
  if pg_proof_ref_is_prose "$2"; then _pv_tok=not-a-path; _pv_det="prose, not a proof path"; return 0; fi
  # NOTE: the bare literal `single_provider_only` (no file) is deliberately NOT accepted here —
  # it was a "type the magic words" bypass (write the field, skip the run). A genuine single-
  # provider run still PRODUCES a file with one `REVIEW BY:` line, which the >=1-provider +
  # honest-note path below accepts. So honest degraded needs a real file; only fabrication is
  # denied a shortcut.
  # Containment: a proof path must stay inside the repo — reject `..` traversal and absolute
  # paths, so an artifact cannot point coverage at an arbitrary file that happens to hold two
  # "REVIEW BY:" lines.
  # Reject an ABSOLUTE path, or a path SEGMENT that is exactly `..`. Testing for the substring
  # `..` instead denied coverage to every proof named with the `<base7>..<head7>` convention the
  # review skill prescribes for its own artifacts — `zuvo/proofs/fd57e11..fc0c83e-adversarial.txt`
  # is one filename segment containing dots, not a traversal, yet it failed containment and the
  # honest review that produced it granted no proof coverage. Fail-closed in the wrong place is
  # still wrong: it blocks real reviews while stopping nothing a segment check does not.
  # ONE implementation, shared (B-PATH-CONTAIN-SHARED-FN). This rule used to be written out here,
  # in review-artifact-sync.sh::lint_artifact and in ::do_sync — d568825 fixed two of the three and
  # the miss reopened a real traversal. A missing helper REJECTS rather than falls through: this
  # library is fail-open by design, but not about containment, where failing open means accepting
  # the traversal.
  if ! command -v path_contained >/dev/null 2>&1; then
    _pv_tok=no-containment; _pv_det="path_contained is not loaded"; return 0
  fi
  if ! path_contained "$1" "$2"; then
    _pv_tok=escapes; _pv_det="absolute, a .. segment, or a symlink out of the repo"; return 0
  fi
  _po_path="$1/$2"
  if [ ! -f "$_po_path" ]; then
    # Proof referenced but not in this checkout. This is the SERVER-SIDE / CI case: proof files
    # (zuvo/proofs/) are commonly gitignored, so a CI runner has the committed artifact but not
    # the proof. The proof-of-work is a LOCAL guardrail — it stops an agent FABRICATING an
    # artifact to slip past its own pre-push hook, where the proof file IS in the working tree.
    # CI is the "was this reviewed at all" backstop (content-key), not the proof layer, so the
    # CI entry script sets PG_PROOF_OPTIONAL=1 to degrade an absent proof to content-key rather
    # than block every push. Locally (unset) an absent proof is NOT proven — the hole stays shut
    # exactly where fabrication happens.
    if [ "${PG_PROOF_OPTIONAL:-}" = "1" ]; then
      _pv_tok=missing-optional; _pv_det="not in this checkout; PG_PROOF_OPTIONAL=1"
    else
      _pv_tok=missing; _pv_det="not in this checkout"
    fi
    return 0
  fi
  # ONE READ (P3C-13). Everything below is decided by a single awk pass over the proof: the
  # truncation flag, the blind-audit header scan, the REVIEW BY: count and the honest single-provider
  # note. They used to be four separate reads (grep, awk, grep -c, grep -qiE) of a file that could
  # change between them, and — the part that mattered — a reader that failed or skipped the file on
  # one read said nothing about what the next read saw: the scan could answer "no blind-audit header"
  # about a file it never read while the count, reading it fine, granted coverage (ADV-A116, P2-5).
  # One read cannot disagree with itself.
  #
  # A TRUNCATED review is not proof of anything about the part that was never sent (B-ADV-TRUNC).
  # adversarial-review.sh records `input_truncated=true` when it drops files past its char cap, and
  # the REVIEW BY: markers are still there — they attest that providers ran, not that they saw the
  # whole change. Counting markers alone therefore grants full coverage to a review that omitted,
  # in the observed 2026-07-31 case, the single largest file in the patch. The exit code now says
  # so too (4), but a gate must not depend on a caller having checked it: this is the one place
  # every consumer passes through. Matched on the CR-stripped line, like every other comparison in the
  # scan: the `grep -x` this replaced matched the raw line, so a CRLF-authored proof's
  # `input_truncated=true\r` was not refused — the truncation flag was the one thing CR-blind.
  #
  # A blind-audit run (write_artifact's `mode=blind-audit` header line, scripts/
  # adversarial-review.sh) is a coverage AUDIT, not a review — it can carry REVIEW BY: lines and
  # even a genuine multi-provider proof, but "we checked whether this was reviewed" must never
  # itself grant review coverage.
  #
  # HEADER-SCOPED, not a whole-file scan (fixed 2026-09-27, cross-model review: codex-5.3 +
  # cursor-agent). A bare `grep -qx` over the whole proof file also matched a BODY line that
  # merely quotes "mode=blind-audit" — a genuine code review OF this very feature is exactly such
  # a proof, and it was wrongly refused. mode= is only authoritative inside a write_artifact()
  # HEADER; an --append-artifact proof holds several records back to back, and every one is scanned,
  # not just the first, so a blind-audit pass appended after a real review still refuses. Tolerate a
  # trailing CR (CRLF-authored proof): the sub() runs on every record, before any comparison. No
  # other normalization — no case-folding, no leading-whitespace tolerance — since the driver
  # validates mode against a fixed enum and writes these lines exactly or it is not its output.
  #
  # WHAT COUNTS AS A HEADER (ADV-A117, then P2-4). A record starts only where write_artifact() can
  # start one — the first line of the file, or right after its `=== APPENDED PASS <UTC> ===`
  # separator — AND only with the driver's whole fixed prefix, one line each, in order:
  # artifact_kind=, created_at=<YYYY-MM-DDTHH:MM:SSZ>, status=, mode=. The first cut re-opened header
  # state on ANY artifact_kind= line; the second on artifact_kind= right after a marker — and a review
  # body that quoted the marker too (an explanation of --append-artifact, or a review of this gate
  # quoting its own fixtures: self-referentially likely, not hypothetical) still refused a genuine
  # multi-provider review. Requiring the complete sequence makes an accidental quote need five exact
  # consecutive lines, timestamps included. A prefix that breaks at any step is prose (state back to
  # 0). That prefix is only safe while it IS what the driver writes: tests/hooks/test-pipeline-gate-lib.sh
  # ("header contract") pins it against write_artifact()'s own source, and runs write_artifact() itself
  # to prove the scan reads its REAL output — because a drift there would stop real blind-audit proofs
  # from being recognised, the fail-OPEN direction.
  #
  # A RECORD COUNTS ONLY ONCE ITS HEADER CLOSES (P3C-16). After the prefix, write_artifact() writes
  # nothing but `key=value` and `REVIEW BY: X` lines up to its `---` (pinned by the same contract), so a
  # line of any other shape before that `---` means the "record" was a QUOTE — a review of this gate
  # quoting the marker and the whole four-line prefix, then carrying on in prose — and its mode= never
  # counts. A blind-audit mode= is therefore only PENDING until the `---` that closes its header, and
  # every mode=blind-audit line inside that header makes it pending (a duplicate mode= line included,
  # ADV-C83). Two edges fail closed on purpose: a header still open at END (a truncated proof) is taken
  # as a header, and so is a quote that reproduces the whole header up to its `---` — the one shape no
  # line-based reading can tell from the real thing.
  #
  # NO LINE IS SWALLOWED (P3C-10). A line that breaks a prefix, or ends a quoted header, only resets the
  # state — it is then dispatched like any other line (the record-start rule at the bottom), never
  # consumed by the rule that rejected it. Today such a line can never itself start a record (a start
  # needs the line before it to be a marker, and the line before it is a header line), so this does not
  # change a verdict; it keeps the scan correct if the start rule ever changes.
  #
  # EXIT STATUS (P2-5, ADV-A116). 3 = PROVEN, and nothing else is: not truncated, no blind-audit
  # header, and either >=2 REVIEW BY: lines or >=1 with an honest single-provider note (only one model
  # configured). 3 is deliberate: one-true-awk, gawk and mawk exit 2 on an I/O fault, a busybox-class
  # awk exits 1 when it cannot open its input, and a signal is 128+n — none of them is 3, so every
  # fault refuses. An awk that instead warns about an unreadable input, skips it and still runs END
  # counts zero REVIEW BY: lines there, which refuses too (the one-read rule above); the -r test first
  # makes an unreadable proof an explicit refusal rather than a consequence.
  # The refusals END itself decides carry their reason: 4 truncated, 5 blind-audit, 6 weak (the
  # REVIEW BY: count on stdout). Any other status is a fault and maps to scan-error.
  #
  # CAPTURE (P2-1). `|| _po_rc=$?` rather than a bare statement followed by `rc=$?`: a caller
  # that calls this as a plain statement under `set -e` would be killed by the scan's own non-zero
  # status before the rc was ever read.
  if [ ! -r "$_po_path" ]; then
    _pv_tok=unreadable; _pv_det="the proof file cannot be read"; return 0
  fi
  _po_out="$(awk '
    { line = $0; sub(/\r$/, "", line) }
    line == "input_truncated=true" { trunc = 1 }
    index($0, "REVIEW BY:") > 0 { n++ }
    tolower($0) ~ /single.provider|1 of|provider timed out|only.*provider/ { single = 1 }
    st == 1 { if (line ~ /^created_at=[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) { st = 2; prev = line; next } st = 0 }
    st == 2 { if (line ~ /^status=/) { st = 3; prev = line; next } st = 0 }
    st == 3 { if (line ~ /^mode=/) { st = 4; pend = (line == "mode=blind-audit"); prev = line; next } st = 0 }
    st == 4 && line == "---" { if (pend) found = 1; st = 0; pend = 0; prev = line; next }
    st == 4 && (line ~ /^[a-z_][a-z0-9_]*=/ || line ~ /^REVIEW BY: /) { if (line == "mode=blind-audit") pend = 1; prev = line; next }
    st == 4 { st = 0; pend = 0 }
    st == 0 && line ~ /^artifact_kind=/ && (NR == 1 || prev ~ /^=== APPENDED PASS [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z ===$/) { st = 1 }
    { prev = line }
    END {
      if (st == 4 && pend) found = 1
      if (trunc) exit 4
      if (found) exit 5
      if (n >= 2 || (n >= 1 && single)) exit 3
      print n + 0
      exit 6
    }
  ' "$_po_path" 2>/dev/null)" || _po_rc=$?
  case "$_po_rc" in
    3) _pv_tok=proven; _pv_det="cross-model proof" ;;
    4) _pv_tok=truncated; _pv_det="input_truncated=true" ;;
    5) _pv_tok=blind-audit; _pv_det="a blind-audit record, not a review" ;;
    6) _pv_tok=weak; _pv_det="${_po_out//[!0-9]/} REVIEW BY: line(s), no single-provider note" ;;
    *) _pv_tok=scan-error; _pv_det="proof scan exited $_po_rc" ;;
  esac
  return 0
}

# _pgl_proof_reason_msg <artifact_name> <token> <ref> <detail> — pg_explain_uncovered's text for a
# refusing verdict token; each names the repair that actually unblocks.
_pgl_proof_reason_msg() {
  local _prm_n _prm_r _prm_d _prm_c
  _pgl_clean "$1"; _prm_n="$_PGL_CLEAN"; _pgl_clean "$3"; _prm_r="$_PGL_CLEAN"; _pgl_clean "$4"; _prm_d="$_PGL_CLEAN"
  _prm_c="$_prm_n covers this content but"
  case "$2" in
    no-ref) printf '%s\n' "$_prm_c has NO adversarial: proof line — save the real adversarial output and reference it" ;;
    missing) printf '%s\n' "$_prm_c its proof '$_prm_r' is NOT in this checkout — artifact+proof travel as a PAIR: ~/.zuvo/review-artifact-sync.sh --from <checkout-that-ran-the-review> --to ." ;;
    weak) printf '%s\n' "$_prm_c its proof '$_prm_r' has <2 'REVIEW BY:' lines and no single-provider note — save the genuine adversarial output" ;;
    truncated) printf '%s\n' "$_prm_c its proof '$_prm_r' records input_truncated=true — the reviewers never saw the whole change; re-run the review so every part is sent" ;;
    blind-audit) printf '%s\n' "$_prm_c its proof '$_prm_r' is a blind-audit record — a coverage audit is not a review; cite the review's own adversarial output" ;;
    escapes) printf '%s\n' "$_prm_c its proof '$_prm_r' escapes the repo (absolute path, a .. segment or a symlink) — reference a repo-relative proof" ;;
    not-a-path) printf '%s\n' "$_prm_c its adversarial: value '$_prm_r' is prose, not a proof path — reference the saved adversarial output file" ;;
    too-many-refs) printf '%s\n' "$_prm_c cites more than $PG_MAX_PROOF_REFS proofs — cite at most $PG_MAX_PROOF_REFS" ;;
    no-containment) printf '%s\n' "$_prm_c the proof containment check (path-contain.sh) is not installed beside the gate library — reinstall zuvo" ;;
    unreadable) printf '%s\n' "$_prm_c its proof '$_prm_r' cannot be read — fix its permissions so the gate can count its REVIEW BY: lines" ;;
    scan-error) printf '%s\n' "$_prm_c its proof '$_prm_r' could not be scanned ($_prm_d) — the gate does not grant what it cannot verify" ;;
    *) printf '%s\n' "$_prm_c its proof '$_prm_r' was refused ($_prm_d) — the gate does not grant what it cannot verify" ;;
  esac
}

# _pgl_proof_failure_msg <root> <artifact> <artifact_name> — the message for the FIRST refusing ref.
# No refusing line found (or none parsed) still prints a refusal: this explains a block.
_pgl_proof_failure_msg() {
  local _pfm_rest _pfm_l _pfm_t _pfm_r _pfm_d
  _pfm_rest="$(pg_artifact_proof_verdict "$1" "$2" 2>/dev/null)$_PGL_NL"
  while [ -n "$_pfm_rest" ]; do
    _pfm_l="${_pfm_rest%%"$_PGL_NL"*}"; _pfm_rest="${_pfm_rest#*"$_PGL_NL"}"
    _pfm_t="${_pfm_l%%"$_PGL_TAB"*}"; _pfm_l="${_pfm_l#*"$_PGL_TAB"}"
    _pfm_r="${_pfm_l%%"$_PGL_TAB"*}"; _pfm_d="${_pfm_l#*"$_PGL_TAB"}"
    case "$_pfm_t" in proven|missing-optional|grandfathered|'') continue ;; esac
    _pgl_proof_reason_msg "$3" "$_pfm_t" "$_pfm_r" "$_pfm_d"; return 0
  done
  _pgl_proof_reason_msg "$3" scan-error "-" "no refusing ref reported"
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
#
# pg_file_covered_by_any <root> <reviews_dir> <head> <range> <file> -> 0 = covered, 1 = not.
#
# The PER-FILE half of the rule above, factored out so the two callers that need it —
# pg_range_reviewed (a verdict: is the whole range covered?) and pg_uncovered_files (an
# enumeration: which files are not?) — can never drift apart. Two copies of the blob /
# deletion matching would eventually disagree, and the callers act on the answer in
# OPPOSITE safety directions (block a push vs. skip a review), so a disagreement is
# precisely the bug that would go unnoticed until it shipped something unreviewed.
#
# Internal helper: arguments are supplied by callers that already validated the repo and
# the range. Every git failure inside resolves toward NOT covered, i.e. toward more review.
#
# Since 2026-09-27 this is a thin wrapper over the batched engine below (_pgl_uncovered), so
# the per-file rule has exactly ONE implementation shared by every caller.
pg_file_covered_by_any() {
  local _pfc_unc
  _pfc_unc="$(_pgl_uncovered "$1" "$2" "$3" "$4" "$5")" || return 1
  [ -z "$_pfc_unc" ]
}

# --- batched coverage engine (2026-09-27) ------------------------------------
# WHY BATCHED. The rule above used to run as a loop: for every changed production file, for
# every artifact in memory/reviews/, ~20-25 short-lived processes (grep, stat, sed, head, tr,
# realpath, git rev-parse …). Measured on tgm-survey-platform: 1566 artifacts × 36 changed
# files ≈ 1.2M process spawns, minutes per evaluation — and the Stop gate re-ran it at the end
# of EVERY turn, the commit nudge on every `git commit`, the push gate twice per push (PreToolUse
# + git-native). Most of the time went to process creation in the kernel plus the EDR scanning
# each exec, which is why it showed up as system time rather than as any one busy process.
#
# The same rule, evaluated in a constant number of processes:
#   1. ONE awk pass over every artifact's headers (marker / files: / range:, first occurrence,
#      exactly what the grep/sed/head calls extracted; it stops reading a file once all three
#      are found) joined against the changed-file set → the (file, artifact) pairs where the
#      artifact LISTS the file (entry-by-entry, B-12) or says files: *.
#   2. ONE `git cat-file --batch-check` resolving every blob either side of a comparison — the
#      current blob of each changed file and the blob each listing artifact reviewed.
#   3. pg_artifact_proven ONLY for pairs whose content already matches (memoized per artifact),
#      and the deletion ancestry checks only for deleted files — the expensive checks run on a
#      handful of candidates instead of on every artifact.
# The filters are pure conjunctions, so evaluating the cheap ones first changes no verdict.

_PGL_US="$(printf '\037')"
_PGL_CR="$(printf '\r')"
_PGL_TAB="$(printf '\t')"
_PGL_NL='
'

# Pass 1. stdin: changed files, one per line · ONE empty line · `stat` rows (key<TAB>path) · ONE
# <US> line · artifact paths in glob order.
# stdout: F<US>file  |  Q<US><rev>:<path>  |  L|S<US>file<US>artifact<US>marker<US>star<US>range
#   F = a changed file (input order) · Q = a blob query for cat-file (deduplicated)
#   L = artifact lists the file (or files: *) · S = explain-only hint: files: is SPACE-separated
#       and names the file, which the comma-splitting parser can never match
# Cover mode drops marker-less artifacts at the source; explain mode keeps them (it reports
# "marker missing" as a reason).
#
# HEADER CACHE (-v cache=<file>, empty = off). Reading ~3 header lines is nothing; OPENING 1566
# files is not — measured: `cat memory/reviews/*.md` 1.6 s wall at 12% CPU, i.e. waiting on the
# on-access scanner, not on the disk. So each artifact's parsed headers are kept keyed on its stat
# row (mtime to the nanosecond, size, inode), and an artifact is opened only when that row changed.
# Cached values are exactly what the parse below produced, so a hit changes no verdict. The file is
# rewritten (to <cache>.<pid>, renamed by the caller) only when something was re-parsed or removed.
_PGL_AWK_INDEX='
function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
function query(q) { if (!(q in asked)) { asked[q] = 1; printf "Q%s%s\n", US, q } }
function rec(kind, f) {
  printf "%s%s%s%s%s%s%s%s%s%s%s\n", kind, US, f, US, art, US, marker, US, star, US, range
  if (kind == "L" && marker && ahead != "") query(ahead ":" f)
}
BEGIN {
  US = "\037"; phase = 0; n = 0; nkeep = 0; dirty = 0; ncached = 0; nhit = 0
  srand(); now = srand()   # the second call returns the seed the first one took from the clock
  if (cache != "") {
    while ((getline l < cache) > 0) {
      if (split(l, c, US) != 5) continue
      ckey[c[2]] = c[1]; cmark[c[2]] = c[3]; cfiles[c[2]] = c[4]; crange[c[2]] = c[5]; ncached++
    }
    close(cache)
  }
}
phase == 0 {
  if ($0 == "") { phase = 1; next }
  if (!($0 in want)) { want[$0] = 1; cf[++n] = $0; printf "F%s%s\n", US, $0; query(head ":" $0) }
  next
}
phase == 1 {
  if ($0 == US) { phase = 2; next }
  t = index($0, "\t")
  if (t > 1) { skey[substr($0, t + 1)] = substr($0, 1, t - 1); nstat++ }
  next
}
{
  art = $0; key = (art in skey) ? skey[art] : ""
  if (key != "" && (art in ckey) && ckey[art] == key) {
    marker = cmark[art]; files = cfiles[art]; range = crange[art]; nhit++
  } else {
    marker = 0; hasf = 0; hasr = 0; files = ""; range = ""
    while ((getline line < art) > 0) {
      if (!marker && index(line, "<!-- zuvo-review -->")) marker = 1
      if (!hasf && line ~ /^files:/) { files = line; sub(/^files:[[:space:]]*/, "", files); hasf = 1 }
      if (!hasr && line ~ /^range:/) { range = line; sub(/^range:[[:space:]]*/, "", range); hasr = 1 }
      if (marker && hasf && hasr) break
    }
    close(art)
    if (key != "" && (key + 0) < now - 2) dirty = 1
  }
  # RACY-CLEAN GUARD (as git does for its index): keep only headers whose mtime is >= 2 s old.
  # File clocks are coarse (Linux stamps in ~4 ms ticks), so a same-size rewrite inside one tick
  # would keep the same key; once an entry is cached, any later write lands on a newer mtime.
  if (key != "" && (key + 0) < now - 2 && index(files range art, US) == 0)
    keep[++nkeep] = key US art US marker US files US range
  if (files == "" || (!explain && !marker)) next
  ahead = range; sub(/.*\.\./, "", ahead)
  star = (files == "*") ? 1 : 0
  if (star) { for (i = 1; i <= n; i++) rec("L", cf[i]); next }
  split("", seen)
  m = split(files, ent, ",")
  for (k = 1; k <= m; k++) {
    e = trim(ent[k])
    if (e != "" && (e in want) && !(e in seen)) { seen[e] = 1; rec("L", e) }
  }
  if (explain && index(files, ",") == 0 && index(files, " ") > 0)
    for (i = 1; i <= n; i++)
      if (!(cf[i] in seen) && index(" " files " ", " " cf[i] " ")) rec("S", cf[i])
}
END {
  if (cache == "" || tmp == "" || nstat == 0 || (!dirty && nhit == ncached)) exit 0
  for (i = 1; i <= nkeep; i++) print keep[i] > tmp
  close(tmp)
}'

# Pass 2. stdin: cat-file results (one per Q line, same order), a lone <US> line, then pass 1.
# stdout, grouped per changed file in input order, artifacts in glob order:
#   F<US>file<US>current_blob   then   C<US>kind<US>artifact<US>marker<US>star<US>range<US>reviewed_blob
# Cover mode keeps only the pairs that can still grant coverage: a marked artifact with a
# reviewed head whose blob EQUALS the current one — or, for a deleted file, one that lists it
# explicitly (the deletion rule never accepts files: *). Exit 2 if the result count does not
# match the query count: a misaligned join must never read as "covered".
_PGL_AWK_JOIN='
BEGIN { US = "\037"; FS = US; phase = 0; nr = 0; nq = 0; nf = 0 }
phase == 0 {
  if ($0 == US) { phase = 1; next }
  oid = ""
  if ($0 ~ /^[0-9a-f]+$/ || $0 ~ /^[0-9a-f]+ submodule$/) {
    oid = $0; sub(/ .*/, "", oid)
    if (length(oid) != 40 && length(oid) != 64) oid = ""
  }
  res[++nr] = oid
  next
}
$1 == "Q" { blob[$2] = res[++nq]; next }
$1 == "F" { order[++nf] = $2; next }
$1 == "L" || $1 == "S" { cnt[$2]++; row[$2, cnt[$2]] = $0; next }
END {
  if (nq != nr) exit 2
  for (i = 1; i <= nf; i++) {
    f = order[i]; bcur = blob[head ":" f]
    print "F" US f US bcur
    for (j = 1; j <= cnt[f]; j++) {
      split(row[f, j], p, US)
      kind = p[1]; art = p[3]; marker = p[4]; star = p[5]; range = p[6]
      ahead = range; sub(/.*\.\./, "", ahead)
      bart = (kind == "L" && marker == 1 && ahead != "") ? blob[ahead ":" f] : ""
      if (mode == "cover") {
        if (kind != "L" || marker != 1 || ahead == "") continue
        if (bcur != "") { if (bart != bcur) continue }
        else if (star == 1) continue
      }
      print "C" US kind US art US marker US star US range US bart
    }
  }
}'

# _pgl_join <root> <reviews_dir> <head> <files_newline_list> <cover|explain>
# Runs passes 1+2 with one cat-file in between: a constant handful of processes whatever the
# artifact count.
#
# The header cache is used only for the checkout's OWN memory/reviews/ and lives in its git dir
# (per worktree, never committed, never shipped with the artifacts). ZUVO_PG_INDEX_CACHE=0 turns
# it off. Any failure on the way (no git dir, stat unavailable, argument list too long) just means
# every artifact is parsed, as before.
_pgl_join() {
  local root="$1" reviews="$2" head="$3" files="$4" mode="$5" ex=0 idx res art cache="" tmp="" stats=""
  [ "$mode" = "explain" ] && ex=1
  if [ "${ZUVO_PG_INDEX_CACHE:-1}" != "0" ] && [ "$reviews" = "$root/memory/reviews" ] \
     && cache="$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null)" && [ -n "$cache" ]; then
    cache="$cache/zuvo-review-index.v1"; tmp="$cache.$$"
    # GNU first, BSD second (on GNU `stat -f` means --file-system — its output then matches no
    # path, i.e. a miss, never a wrong hit). Key = mtime to the ns : size : inode.
    stats="$(stat -c '%.9Y:%s:%i	%n' "$reviews"/*.md 2>/dev/null)" \
      || stats="$(stat -f '%Fm:%z:%i	%N' "$reviews"/*.md 2>/dev/null)" || stats=""
  else
    cache=""
  fi
  # `if`, not `[ … ] && …`: the hooks run under pipefail, and a group whose LAST test is false
  # (an empty reviews dir leaves the literal glob) would fail the pipeline and read as an error.
  idx="$(
    { printf '%s\n\n' "$files"
      if [ -n "$stats" ]; then printf '%s\n' "$stats"; fi
      printf '%s\n' "$_PGL_US"
      for art in "$reviews"/*.md; do if [ -e "$art" ]; then printf '%s\n' "$art"; fi; done
    } | LC_ALL=C awk -v head="$head" -v explain="$ex" -v cache="$cache" -v tmp="$tmp" "$_PGL_AWK_INDEX"
  )" || { [ -n "$tmp" ] && rm -f "$tmp"; return 2; }
  [ -n "$tmp" ] && [ -f "$tmp" ] && { mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp"; }
  res="$(printf '%s\n' "$idx" | LC_ALL=C sed -n "s/^Q$_PGL_US//p" \
         | git -C "$root" cat-file --batch-check='%(objectname)' 2>/dev/null)" || return 2
  printf '%s\n%s\n%s\n' "$res" "$_PGL_US" "$idx" \
    | LC_ALL=C awk -v head="$head" -v mode="$mode" "$_PGL_AWK_JOIN"
}

# pg_artifact_proven, memoized for one engine call: the memo lives in the CALLER's locals
# (_pgl_py / _pgl_pn, newline-delimited), so it never outlives the evaluation it serves.
_pgl_proven() {
  case "$_pgl_py" in *"$_PGL_NL$2$_PGL_NL"*) return 0 ;; esac
  case "$_pgl_pn" in *"$_PGL_NL$2$_PGL_NL"*) return 1 ;; esac
  if pg_artifact_proven "$1" "$2"; then _pgl_py="$_pgl_py$2$_PGL_NL"; return 0; fi
  _pgl_pn="$_pgl_pn$2$_PGL_NL"; return 1
}

# _pgl_uncovered <root> <reviews_dir> <head> <range> <files_newline_list>
# stdout: the files whose current content no proven artifact covers, in input order.
# rc 0 = computed · rc 2 = the batch could not be evaluated (callers pick their fail direction).
_pgl_uncovered() {
  local root="$1" reviews="$2" head="$3" range="$4" files="$5"
  local joined k a b c d e g cur="" bcur="" covered=1 delc="" delc_done=0 art_head art_base
  local _pgl_py="$_PGL_NL" _pgl_pn="$_PGL_NL"
  joined="$(_pgl_join "$root" "$reviews" "$head" "$files" cover)" || return 2
  while IFS="$_PGL_US" read -r k a b c d e g; do
    case "$k" in
      F)
        [ -n "$cur" ] && [ "$covered" -eq 0 ] && printf '%s\n' "$cur"
        cur="$a"; bcur="$b"; covered=0; delc=""; delc_done=0 ;;
      C)
        [ "$covered" -eq 1 ] && continue
        # b = artifact, e = its range. The join already proved the content matches.
        if [ -n "$bcur" ]; then
          _pgl_proven "$root" "$b" && covered=1       # post-cutoff artifact must cite a real adversarial run
          continue
        fi
        # bcur empty ⇒ the file is DELETED at head (no shippable content). A deletion is
        # COVERED when an artifact reviewed the SAME deletion: it lists the file EXPLICITLY
        # (not '*', filtered by the join) AND its reviewed range CONTAINS the exact commit that
        # deleted it — reachable from its head but NOT from its base. Content-keying alone cannot
        # tell two deletions of the same path apart; a same-path deletion reviewed in an
        # unrelated range/branch must not silently cover this one.
        if [ "$delc_done" -eq 0 ]; then
          delc_done=1
          # Resolve the deleting commit over the SAME commit set the range denotes. For the
          # @unpushed sentinel, `git log "@unpushed..HEAD"` is a bad revision — use the un-pushed
          # walk (HEAD --not --remotes); any real A..B range uses the two-dot form directly.
          if [ "${range%%..*}" = "@unpushed" ]; then
            delc="$(git -C "$root" log --diff-filter=D --no-renames --format=%H -c "${range##*..}" --not --remotes -- "$cur" 2>/dev/null | head -1)"
          else
            delc="$(git -C "$root" log --diff-filter=D --no-renames --format=%H "$range" -- "$cur" 2>/dev/null | head -1)"
          fi
        fi
        art_head="${e##*..}"; art_base="${e%%..*}"
        if [ -n "$delc" ] && [ -n "$art_base" ] && _pgl_proven "$root" "$b" \
           && git -C "$root" merge-base --is-ancestor "$delc" "$art_head" 2>/dev/null \
           && ! git -C "$root" merge-base --is-ancestor "$delc" "$art_base" 2>/dev/null; then
          covered=1
        fi ;;
    esac
  done <<EOF
$joined
EOF
  [ -n "$cur" ] && [ "$covered" -eq 0 ] && printf '%s\n' "$cur"
  return 0
}

pg_range_reviewed() {
  local range="$1" root reviews head change_files unc
  [ -n "$range" ] || return 2
  root="$(pg_repo_root)" || return 2
  head="${range##*..}"; [ -n "$head" ] || return 2
  git -C "$root" rev-parse --verify "${head}^{commit}" >/dev/null 2>&1 || return 2   # unresolvable → unknown
  reviews="$root/memory/reviews"
  [ -d "$reviews" ] || return 1            # repo present, no reviews dir → NOT covered

  change_files="$(pg_changed_production "$range" 2>/dev/null)" || return 1   # git failed → NOT covered
  [ -n "$change_files" ] || return 1       # no production files → nothing grants coverage

  # An engine failure resolves toward NOT covered, like every git failure in the per-file rule.
  unc="$(_pgl_uncovered "$root" "$reviews" "$head" "$range" "$change_files")" || return 1
  [ -z "$unc" ] && return 0                # every changed production file covered by content
  return 1
}

# pg_uncovered_files <range> — print, one path per line, the PRODUCTION files in <range>
# whose CURRENT content is NOT covered by any proven artifact. Same per-file rule as
# pg_range_reviewed, but it does not stop at the first miss: a caller can then SCOPE work
# to what is genuinely unreviewed instead of redoing the whole range. `zuvo:ship` Phase 2
# uses it to reuse the evidence a preceding zuvo:refactor / build / execute already
# produced, rather than re-reviewing content that was reviewed hours ago.
#
# Return codes carry the distinction stdout cannot:
#   0 — computed. stdout = uncovered files; EMPTY stdout means every production file in
#       the range is covered.
#   2 — could NOT compute (no repo, empty, option-shaped or unresolvable range, failing git). stdout empty.
#   3 — the range changed NO production files. stdout empty.
#
# EMPTY STDOUT IS AMBIGUOUS ON ITS OWN and must never be read as "all covered" without
# checking the code. Collapsing 2 into 0 would turn a git failure into a skipped review —
# the inversion of fail-open, since here the safe direction is MORE review, not less.
# (This is why the function does not simply "print nothing and return 0 on error": the
# caller cannot distinguish the two states through one channel.)
pg_uncovered_files() {
  local range="$1" root reviews head base change_files unc
  [ -n "$range" ] || return 2
  _pgl_range_optlike "$range" && return 2
  root="$(pg_repo_root)" || return 2
  head="${range##*..}"; [ -n "$head" ] || return 2
  git -C "$root" rev-parse --verify "${head}^{commit}" >/dev/null 2>&1 || return 2   # unresolvable → unknown
  # A bad base, or any failing git diff, must be 2: an empty list would read as rc 3.
  base="${range%%..*}"
  if [ "$base" != "@unpushed" ]; then
    git -C "$root" rev-parse --verify -q "${base}^{commit}" >/dev/null 2>&1 || return 2
  fi

  change_files="$(pg_changed_production "$range" 2>/dev/null)" || return 2
  [ -n "$change_files" ] || return 3       # nothing production changed → nothing to review

  # No reviews dir is NOT an error here: it means nothing is covered, so every production
  # file is emitted. (pg_range_reviewed returns 1 for the same state — same meaning, its
  # channel is a verdict rather than a list.)
  reviews="$root/memory/reviews"
  if [ ! -d "$reviews" ]; then
    printf '%s\n' "$change_files"
    return 0
  fi
  # An engine failure is "could NOT compute" (2) — never an empty list read as all-covered.
  unc="$(_pgl_uncovered "$root" "$reviews" "$head" "$range" "$change_files")" || return 2
  [ -n "$unc" ] && printf '%s\n' "$unc"
  return 0
}

# --- per-file block diagnostics ---------------------------------------------
# _pgl_shq <text> — <text> as one single-quoted shell word, safe to paste.
_pgl_shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# pg_explain_uncovered <range> — print WHY each uncovered production file is
# uncovered, one line per file. Purely informational (always returns 0, prints
# nothing on error): the VERDICT stays with pg_range_reviewed; this exists
# because "no covering review" collapses five different repair actions into one
# message — and that ambiguity mis-diagnosed a real incident as "review never
# happened" when the review existed and only its proof file wasn't in the
# pushing checkout (2026-07-31, six data-lab refactor PRs).
#
# Reasons, most-actionable first (per file, the CLOSEST failure is reported —
# an artifact that lists the file beats "no artifact"):
#   proof-missing     artifact matches, but its adversarial: proof file is not
#                     in THIS checkout → copy the artifact+proof PAIR
#                     (~/.zuvo/review-artifact-sync.sh), don't re-review
#   proof-weak        proof file present but <2 'REVIEW BY:' lines and no
#                     honest single-provider note → save the real adversarial
#                     output with --artifact, or re-run it
#   stale-content     artifact lists the file but reviewed DIFFERENT content
#                     (blob mismatch) → the file changed after review; fresh
#                     review needed for the new content
#   marker-missing    a memory/reviews file names this path but lacks the
#                     '<!-- zuvo-review -->' marker → malformed header, fix
#                     the header (~/.zuvo/review-artifact-sync.sh --check)
#   no-artifact       nothing in memory/reviews/ lists the file → this content
#                     was never reviewed; run the pipeline (zuvo:review/build)
pg_explain_uncovered() {
  local _peu_range="$1" _peu_root _peu_head _peu_reviews _peu_list _peu_unc _peu_show="" _peu_more=0
  local _peu_n=0 _peu_f _peu_joined k a b c d e g _peu_cur="" _peu_bcur="" _peu_best=0 _peu_why=""
  local _peu_ahead _peu_name _pgl_py="$_PGL_NL" _pgl_pn="$_PGL_NL"
  _peu_root="$(pg_repo_root 2>/dev/null)" || return 0
  _peu_head="${_peu_range##*..}"; [ -n "$_peu_head" ] || return 0
  _peu_reviews="$_peu_root/memory/reviews"

  _peu_list="$(pg_changed_production "$_peu_range" 2>/dev/null)" || return 0
  [ -n "$_peu_list" ] || return 0
  # Explain only what the verdict engine calls uncovered, and only the first 10 in detail: the
  # rest are COUNTED (the old per-file loop computed a full reason for every file just to count
  # it — the slowest thing a blocked push did). A failed engine explains the whole list.
  _peu_unc="$(_pgl_uncovered "$_peu_root" "$_peu_reviews" "$_peu_head" "$_peu_range" "$_peu_list")" \
    || _peu_unc="$_peu_list"
  while IFS= read -r _peu_f; do
    [ -n "$_peu_f" ] || continue
    _peu_n=$((_peu_n + 1))
    if [ "$_peu_n" -le 10 ]; then _peu_show="$_peu_show$_peu_f$_PGL_NL"; else _peu_more=$((_peu_more + 1)); fi
  done <<PEU_FILES
$_peu_unc
PEU_FILES
  [ -n "$_peu_show" ] || return 0
  _peu_joined="$(_pgl_join "$_peu_root" "$_peu_reviews" "$_peu_head" "${_peu_show%"$_PGL_NL"}" explain)" || return 0

  # rank: 0=covered(skip) 1=proof 2=malformed(marker/separator) 3=stale 4=none;
  # keep the BEST (lowest) reason; on a tie the first artifact in glob order wins.
  #
  # MALFORMED OUTRANKS STALE, and the order is the whole point (2026-08-06).
  # It used to be the other way round, which produced a loop: memory/reviews/
  # always accumulates older artifacts, so any previously-reviewed file had one
  # listing it with different content. That stale reason (then rank 2) masked
  # the malformed-header reason (then rank 3) on the artifact the run had JUST
  # written. The operator was told "a fresh review is needed", re-ran the
  # review, produced another artifact with the same malformed header, and got
  # the identical message — three cycles, reported from the field.
  #
  # The tie-break rule: a reason that RE-REVIEWING REPAIRS (stale) must never
  # outrank one that re-reviewing reproduces forever (missing marker,
  # space-separated files:). Show the message whose repair actually unblocks.
  while IFS="$_PGL_US" read -r k a b c d e g; do
    case "$k" in
      F)
        [ -n "$_peu_cur" ] && [ "$_peu_best" -ne 0 ] && printf '  %s: %s\n' "$_peu_cur" "$_peu_why"
        _peu_cur="$a"; _peu_bcur="$b"
        _peu_best=4; _peu_why="no artifact in memory/reviews/ lists this file — its content was never reviewed (run zuvo:review / a producing pipeline)" ;;
      C)
        # a = kind, b = artifact, c = marker, e = its range, g = the blob it reviewed
        [ "$_peu_best" -eq 0 ] && continue
        _peu_name="${b##*/}"
        if [ "$a" = "S" ]; then
          # malformed-separator hint: files line has spaces but no commas and
          # mentions this path → the parser (comma-split) can never match it
          if [ 2 -lt "$_peu_best" ]; then
            _peu_best=2
            _peu_why="$_peu_name lists it SPACE-separated — the gate splits files: on commas only; fix the header (~/.zuvo/review-artifact-sync.sh --check)"
          fi
        elif [ "$c" != "1" ]; then
          if [ 2 -lt "$_peu_best" ]; then
            _peu_best=2
            _peu_why="$_peu_name lists it but lacks the '<!-- zuvo-review -->' marker — malformed header, fix it (~/.zuvo/review-artifact-sync.sh --check)"
          fi
        elif [ -n "$_peu_bcur" ] && [ "$g" = "$_peu_bcur" ]; then
          # content matches — the ONLY remaining reason is the proof layer
          if _pgl_proven "$_peu_root" "$b"; then
            _peu_best=0; continue   # actually covered (caller race) — say nothing
          fi
          if [ 1 -lt "$_peu_best" ]; then
            _peu_best=1; _peu_why="$(_pgl_proof_failure_msg "$_peu_root" "$b" "$_peu_name")"
          fi
        elif [ 3 -lt "$_peu_best" ]; then
          _peu_ahead="${e##*..}"
          _peu_best=3
          _peu_why="$_peu_name lists it but reviewed DIFFERENT content (head ${_peu_ahead:-?}) — the file changed after that review; a fresh review is needed"
        fi ;;
    esac
  done <<PEU_JOINED
$_peu_joined
PEU_JOINED
  [ -n "$_peu_cur" ] && [ "$_peu_best" -ne 0 ] && printf '  %s: %s\n' "$_peu_cur" "$_peu_why"
  if [ "$_peu_more" -gt 0 ]; then
    printf '  ... and %s more uncovered file(s) not shown. Full list:\n' "$_peu_more"
    # Absolute path: ~/.zuvo is not on PATH, so a bare command name would not be found.
    # Arguments are single-quoted: a ref name may hold quotes, $( ) or backticks.
    # Both libraries beside the helper, or it exits 2: pipeline-gate-lib.sh and the path-contain.sh it loads.
    if [ -n "${HOME:-}" ] && [ -f "$HOME/.zuvo/pg-uncovered-files" ] && [ -x "$HOME/.zuvo/pg-uncovered-files" ] \
       && [ -f "$HOME/.zuvo/pipeline-gate-lib.sh" ] && [ -f "$HOME/.zuvo/path-contain.sh" ]; then
      printf '    %s %s\n' "$(_pgl_shq "$HOME/.zuvo/pg-uncovered-files")" "$(_pgl_shq "$_peu_range")"
    else
      printf '    bash -c %s _ %s %s\n' "'. \"\$1\" && pg_uncovered_files \"\$2\"'" \
        "$(_pgl_shq "$_pgl_dir/pipeline-gate-lib.sh")" "$(_pgl_shq "$_peu_range")"
    fi
  fi
  return 0
}

# --- escape valves / env detection ------------------------------------------
pg_allow_adhoc() {
  [ "${ZUVO_ALLOW_ADHOC:-}" = "1" ] && return 0
  return 1
}

pg_is_agent_env() {
  if [ -r "$_pgl_agent_dir/agent-env.sh" ]; then
    if . "$_pgl_agent_dir/agent-env.sh" 2>/dev/null && command -v zuvo_is_agent_env >/dev/null 2>&1; then
      zuvo_is_agent_env
      return $?
    fi
    echo "zuvo: agent detector failed to load -> fail-closed" >&2
    return 0
  fi
  # This helper is sourced by the pre-push gate.  Treating a missing detector as
  # "human" lets an agent skip the entire pipeline gate after a partial install
  # or a stale worktree copy.  The safe fallback is to classify the invocation
  # as agent-owned and make the normal gate explain what is missing.
  echo "zuvo: agent detector unavailable -> fail-closed" >&2
  return 0
}

# Marker so callers can verify the lib loaded. Read by pre-push-gate.sh,
# zuvo-stop-pipeline-gate.sh, pre-commit-adversarial-gate.sh and
# scripts/zuvo-pipeline-entry-ci.sh — never inside this file, hence the disable.
# shellcheck disable=SC2034
PG_LIB_LOADED=1
