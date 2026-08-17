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
    tip="${range##*..}"; TAB=$(printf '\t')
    # A merge's COMBINED numstat row is `a1<tab>d1<tab>a2<tab>d2<tab>…<tab>path` (one add/del pair
    # per parent). Parse path = LAST field and add/del = FIRST pair (churn vs parent-1 = the
    # conflict-resolution size), instead of `read -r a d p` which mis-binds path and silently
    # dropped every merge row — an UNDER-count for merge-conflict churn (adversarial-noted). A
    # non-merge row `a<tab>d<tab>path` parses identically. Binary rows ('-') count 0.
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      p=${row##*"$TAB"}
      pg_is_production "$p" || continue
      a=${row%%"$TAB"*}; rest=${row#*"$TAB"}; d=${rest%%"$TAB"*}
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

# pg_artifact_proven <repo_root> <artifact_path> -> 0 = proven (or grandfathered), 1 = NOT.
# Proven when the artifact carries `adversarial: <path>` (alias `adv-proof:`) whose target
# resolves under the repo and either holds >=2 `REVIEW BY:` provider lines (real cross-model)
# OR an explicit honest single-provider marker (`single_provider_only` / `SINGLE PROVIDER`) —
# the same degraded value the review skill is allowed to record when only one model exists.
pg_artifact_proven() {
  # `local` on the _pap_* set (B-13). The prefix is POSIX-style namespacing, which is why the
  # leak was harmless in practice — every one is reassigned before use on each call. But this
  # library is SOURCED into a live hook shell, so the names persisted in the caller after the
  # function returned, and the sibling omission one function away (delc/art_base in
  # pg_range_reviewed) was worth fixing during the coverage-reuse extraction. Same class, so
  # same treatment; the file already assumes bash elsewhere (${!var} in pg_is_agent_env).
  local _pap_root _pap_art _pap_mt _pap_ref _pap_n
  _pap_root="$1"; _pap_art="$2"
  # mtime, GNU-first then BSD, sanitized to digits. `stat -f %m` on GNU/Linux means
  # `--file-system` and prints a mount identifier, NOT the mtime — so BSD-first would put a
  # non-numeric value in _pap_mt and the `-lt` below would error on the CI host (Linux). Try
  # `stat -c %Y` (GNU) first, fall back to `stat -f %m` (BSD/macOS), and strip to digits so a
  # stray value can never break the comparison.
  _pap_mt="$(stat -c %Y "$_pap_art" 2>/dev/null || stat -f %m "$_pap_art" 2>/dev/null || echo 0)"
  _pap_mt="$(printf '%s' "$_pap_mt" | tr -cd '0-9')"; [ -n "$_pap_mt" ] || _pap_mt=0
  [ "$_pap_mt" -lt "$PG_REVIEW_PROOF_CUTOFF" ] && return 0        # legacy -> grandfathered
  # Two passes, not `\(a\|b\)`: BSD sed (macOS) has no `\|` alternation in BRE.
  _pap_ref="$(sed -n 's/^[[:space:]]*adversarial:[[:space:]]*//p' "$_pap_art" 2>/dev/null | head -1)"
  [ -n "$_pap_ref" ] || _pap_ref="$(sed -n 's/^[[:space:]]*adv-proof:[[:space:]]*//p' "$_pap_art" 2>/dev/null | head -1)"
  _pap_ref="$(printf '%s' "$_pap_ref" | tr -d '\r`' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$_pap_ref" ] || return 1                                  # post-cutoff, no proof ref
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
  case "$_pap_ref" in
    /*) return 1 ;;
  esac
  case "/$_pap_ref" in
    */../*|*/..) return 1 ;;
  esac
  _pap_ref="$_pap_root/$_pap_ref"
  if [ ! -f "$_pap_ref" ]; then
    # Proof referenced but not in this checkout. This is the SERVER-SIDE / CI case: proof files
    # (zuvo/proofs/) are commonly gitignored, so a CI runner has the committed artifact but not
    # the proof. The proof-of-work is a LOCAL guardrail — it stops an agent FABRICATING an
    # artifact to slip past its own pre-push hook, where the proof file IS in the working tree.
    # CI is the "was this reviewed at all" backstop (content-key), not the proof layer, so the
    # CI entry script sets PG_PROOF_OPTIONAL=1 to degrade an absent proof to content-key rather
    # than block every push. Locally (unset) an absent proof is NOT proven — the hole stays shut
    # exactly where fabrication happens.
    [ "${PG_PROOF_OPTIONAL:-}" = "1" ] && return 0
    return 1
  fi
  _pap_n="$(grep -c 'REVIEW BY:' "$_pap_ref" 2>/dev/null | head -1)"; _pap_n="${_pap_n:-0}"
  [ "$_pap_n" -ge 2 ] && return 0
  # A single provider genuinely producing output is honest too (only one model configured).
  [ "$_pap_n" -ge 1 ] && grep -qiE 'single.provider|1 of|provider timed out|only.*provider' "$_pap_ref" 2>/dev/null && return 0
  return 1
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
pg_file_covered_by_any() {
  local root="$1" reviews="$2" head="$3" range="$4" f="$5"
  local bcur delc art art_files art_range art_head art_base bart
  # bcur empty ⇒ F is DELETED at head (no shippable content). A deletion is COVERED when
  # an artifact reviewed the SAME deletion — F in its files-set AND F also absent at its
  # reviewed head (so both blobs empty). --verify guarantees absent⇒empty, so a "" == ""
  # match is a genuine reviewed-deletion, never a stray literal string. Do NOT hard-block
  # on bcur empty (that made every reviewed deletion look "uncovered").
  bcur="$(pg_file_blob "$root" "$head" "$f")"
  # For a DELETION (bcur empty), resolve the exact commit that removed F within THIS checked
  # range, so coverage can require the artifact's range to CONTAIN that specific commit —
  # content-keying alone cannot tell two deletions of the same path apart.
  delc=""
  if [ -z "$bcur" ]; then
    # Resolve the deleting commit over the SAME commit set the range denotes. For the @unpushed
    # sentinel, `git log "@unpushed..HEAD"` is a bad revision — use the un-pushed walk
    # (HEAD --not --remotes); any real A..B range uses the two-dot form directly.
    if [ "${range%%..*}" = "@unpushed" ]; then
      delc="$(git -C "$root" log --diff-filter=D --no-renames --format=%H -c "${range##*..}" --not --remotes -- "$f" 2>/dev/null | head -1)"
    else
      delc="$(git -C "$root" log --diff-filter=D --no-renames --format=%H "$range" -- "$f" 2>/dev/null | head -1)"
    fi
  fi
  for art in "$reviews"/*.md; do
    [ -e "$art" ] || continue
    grep -q '<!-- zuvo-review -->' "$art" 2>/dev/null || continue
    pg_artifact_proven "$root" "$art" || continue           # post-cutoff artifact must cite a real adversarial run
    art_files="$(sed -n 's/^files:[[:space:]]*//p' "$art" 2>/dev/null | head -1)"
    pg_files_covered "$f" "$art_files" || continue          # F in artifact's files-set (or *)
    art_range="$(sed -n 's/^range:[[:space:]]*//p' "$art" 2>/dev/null | head -1)"
    art_head="${art_range##*..}"; [ -n "$art_head" ] || continue
    if [ -n "$bcur" ]; then
      bart="$(pg_file_blob "$root" "$art_head" "$f")"
      [ "$bart" = "$bcur" ] && return 0                     # existing file: SAME content (incl. files:*)
    else
      # DELETED file: covered iff the artifact EXPLICITLY lists F (not '*') AND its reviewed
      # range CONTAINS the exact commit that deleted F — delc reachable from art_head but NOT
      # from art_base. That ties coverage to THIS deletion; a same-path deletion reviewed in
      # an unrelated range/branch (or a files:'*' artifact) does not silently cover it.
      art_base="${art_range%%..*}"
      if [ "$art_files" != "*" ] && [ -n "$delc" ] && [ -n "$art_base" ] \
         && git -C "$root" merge-base --is-ancestor "$delc" "$art_head" 2>/dev/null \
         && ! git -C "$root" merge-base --is-ancestor "$delc" "$art_base" 2>/dev/null; then
        return 0
      fi
    fi
  done
  return 1
}

pg_range_reviewed() {
  local range="$1" root reviews head change_files f any=0
  [ -n "$range" ] || return 2
  root="$(pg_repo_root)" || return 2
  head="${range##*..}"; [ -n "$head" ] || return 2
  git -C "$root" rev-parse --verify "${head}^{commit}" >/dev/null 2>&1 || return 2   # unresolvable → unknown
  reviews="$root/memory/reviews"
  [ -d "$reviews" ] || return 1            # repo present, no reviews dir → NOT covered

  change_files="$(pg_changed_production "$range" 2>/dev/null)"
  [ -n "$change_files" ] || return 1       # no production files → nothing grants coverage

  # A here-doc-fed `while` is NOT a subshell (a pipe would be), so `return 1` below returns
  # from the FUNCTION on the first uncovered file — that early exit is the verdict.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    any=1
    pg_file_covered_by_any "$root" "$reviews" "$head" "$range" "$f" \
      || return 1                          # this file's current content is not reviewed → NOT covered
  done <<EOF
$change_files
EOF

  [ "$any" -eq 1 ] && return 0             # every changed production file covered by content
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
#   2 — could NOT compute (no repo, empty or unresolvable range). stdout empty.
#   3 — the range changed NO production files. stdout empty.
#
# EMPTY STDOUT IS AMBIGUOUS ON ITS OWN and must never be read as "all covered" without
# checking the code. Collapsing 2 into 0 would turn a git failure into a skipped review —
# the inversion of fail-open, since here the safe direction is MORE review, not less.
# (This is why the function does not simply "print nothing and return 0 on error": the
# caller cannot distinguish the two states through one channel.)
pg_uncovered_files() {
  local range="$1" root reviews head change_files f any=0
  [ -n "$range" ] || return 2
  root="$(pg_repo_root)" || return 2
  head="${range##*..}"; [ -n "$head" ] || return 2
  git -C "$root" rev-parse --verify "${head}^{commit}" >/dev/null 2>&1 || return 2   # unresolvable → unknown

  change_files="$(pg_changed_production "$range" 2>/dev/null)"
  [ -n "$change_files" ] || return 3       # nothing production changed → nothing to review

  # No reviews dir is NOT an error here: it means nothing is covered, so every production
  # file is emitted. (pg_range_reviewed returns 1 for the same state — same meaning, its
  # channel is a verdict rather than a list.)
  reviews="$root/memory/reviews"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    any=1
    if [ -d "$reviews" ]; then
      pg_file_covered_by_any "$root" "$reviews" "$head" "$range" "$f" && continue
    fi
    printf '%s\n' "$f"
  done <<EOF
$change_files
EOF

  [ "$any" -eq 1 ] || return 3
  return 0
}

# --- per-file block diagnostics ---------------------------------------------
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
  _peu_range="$1"
  _peu_root="$(pg_repo_root 2>/dev/null)" || return 0
  _peu_head="${_peu_range##*..}"; [ -n "$_peu_head" ] || return 0
  _peu_reviews="$_peu_root/memory/reviews"
  _peu_shown=0; _peu_more=0

  pg_changed_production "$_peu_range" 2>/dev/null | while IFS= read -r _peu_f; do
    [ -n "$_peu_f" ] || continue
    _peu_bcur="$(pg_file_blob "$_peu_root" "$_peu_head" "$_peu_f")"
    # rank: 0=covered(skip) 1=proof 2=malformed(marker/separator) 3=stale 4=none;
    # keep the BEST (lowest) reason.
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
    _peu_best=4; _peu_why="no artifact in memory/reviews/ lists this file — its content was never reviewed (run zuvo:review / a producing pipeline)"
    for _peu_art in "$_peu_reviews"/*.md; do
      [ -e "$_peu_art" ] || continue
      _peu_files="$(sed -n 's/^files:[[:space:]]*//p' "$_peu_art" 2>/dev/null | head -1)"
      pg_files_covered "$_peu_f" "$_peu_files" || {
        # malformed-separator hint: files line has spaces but no commas and
        # mentions this path → the parser (comma-split) can never match it
        case "$_peu_files" in
          *,*) : ;;
          *" "*) case " $_peu_files " in *" $_peu_f "*)
                   if [ 2 -lt "$_peu_best" ]; then
                     _peu_best=2
                     _peu_why="$(basename "$_peu_art") lists it SPACE-separated — the gate splits files: on commas only; fix the header (~/.zuvo/review-artifact-sync.sh --check)"
                   fi ;;
                 esac ;;
        esac
        continue
      }
      if ! grep -q '<!-- zuvo-review -->' "$_peu_art" 2>/dev/null; then
        if [ 2 -lt "$_peu_best" ]; then
          _peu_best=2
          _peu_why="$(basename "$_peu_art") lists it but lacks the '<!-- zuvo-review -->' marker — malformed header, fix it (~/.zuvo/review-artifact-sync.sh --check)"
        fi
        continue
      fi
      _peu_arange="$(sed -n 's/^range:[[:space:]]*//p' "$_peu_art" 2>/dev/null | head -1)"
      _peu_ahead="${_peu_arange##*..}"
      _peu_bart=""; [ -n "$_peu_ahead" ] && _peu_bart="$(pg_file_blob "$_peu_root" "$_peu_ahead" "$_peu_f")"
      if [ -n "$_peu_bcur" ] && [ "$_peu_bart" = "$_peu_bcur" ]; then
        # content matches — the ONLY remaining reason is the proof layer
        if pg_artifact_proven "$_peu_root" "$_peu_art"; then
          _peu_best=0; break   # actually covered (caller race) — say nothing
        fi
        _peu_ref="$(sed -n 's/^[[:space:]]*adversarial:[[:space:]]*//p' "$_peu_art" 2>/dev/null | head -1)"
        [ -n "$_peu_ref" ] || _peu_ref="$(sed -n 's/^[[:space:]]*adv-proof:[[:space:]]*//p' "$_peu_art" 2>/dev/null | head -1)"
        if [ -z "$_peu_ref" ]; then
          _peu_msg="$(basename "$_peu_art") covers this content but has NO adversarial: proof line — save the real adversarial output and reference it"
        elif [ ! -f "$_peu_root/$_peu_ref" ]; then
          _peu_msg="$(basename "$_peu_art") covers this content but its proof '$_peu_ref' is NOT in this checkout — artifact+proof travel as a PAIR: ~/.zuvo/review-artifact-sync.sh --from <checkout-that-ran-the-review> --to ."
        else
          _peu_msg="$(basename "$_peu_art") covers this content but its proof '$_peu_ref' has <2 'REVIEW BY:' lines and no single-provider note — save the genuine adversarial output"
        fi
        if [ 1 -lt "$_peu_best" ]; then _peu_best=1; _peu_why="$_peu_msg"; fi
      else
        if [ 3 -lt "$_peu_best" ]; then
          _peu_best=3
          _peu_why="$(basename "$_peu_art") lists it but reviewed DIFFERENT content (head ${_peu_ahead:-?}) — the file changed after that review; a fresh review is needed"
        fi
      fi
    done
    [ "$_peu_best" -eq 0 ] && continue
    if [ "$_peu_shown" -lt 10 ]; then
      printf '  %s: %s\n' "$_peu_f" "$_peu_why"
      _peu_shown=$((_peu_shown + 1))
    else
      _peu_more=$((_peu_more + 1))
    fi
  done
  # NOTE: _peu_shown/_peu_more live in the pipeline subshell; the trailing count
  # is best-effort and intentionally omitted rather than double-counted.
  return 0
}

# --- escape valves / env detection ------------------------------------------
pg_allow_adhoc() {
  [ "${ZUVO_ALLOW_ADHOC:-}" = "1" ] && return 0
  return 1
}

# KEEP THIS LIST IN SYNC WITH refactor-gate-lib.sh :: _is_agent_env.
# They cannot share code (this one uses bash ${!var}, the other is POSIX), so the ONLY thing
# keeping them together is the drift guard in tests/hooks/test-pipeline-gate-lib.sh. That guard
# exists because the lists HAD already drifted: this function was missing ZUVO_AI_RUN and
# ANTIGRAVITY_SESSION_ID, and ZUVO_AI_RUN is the repo's OWN canonical agent marker — set by
# skills/refactor/SKILL.md and refactor-gate-lib.sh. The consequence was not cosmetic:
# hooks/pre-push-gate.sh reads `pg_is_agent_env || return 0  # human push exempt`, so a run
# marked ZUVO_AI_RUN=1 was classified HUMAN and skipped the pipeline-entry gate entirely, while
# the refactor gate correctly saw it as an agent. A fail-open in the layer whose whole job is to
# fail closed. Measured 2026-08-16 before the fix; adding a variable to one list and not the
# other is how it happened, so add to BOTH or the guard will tell you.
pg_is_agent_env() {
  [ "${ZUVO_AGENT:-0}" = "1" ] && return 0
  local v
  for v in CLAUDECODE CLAUDE_PLUGIN_ROOT CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION \
           CODEX_WORKSPACE CODEX_SANDBOX CODEX_HOME \
           CURSOR_AGENT CURSOR_TRACE_ID \
           GEMINI_CLI ANTIGRAVITY GEMINI_ANTIGRAVITY ANTIGRAVITY_SESSION_ID \
           ZUVO_AI_RUN; do
    [ -n "${!v:-}" ] && return 0
  done
  return 1
}

# Marker so callers can verify the lib loaded.
PG_LIB_LOADED=1
