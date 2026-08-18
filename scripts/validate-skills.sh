#!/usr/bin/env bash
#
# validate-skills.sh — structural lint for skills/<name>/SKILL.md conformance.
#
# Two-tier severity, accumulate-and-report (never abort on the first problem):
#   ERROR  — hard conformance break; fails the run (exit 1).
#   WARN   — advisory convention gap; reported but does NOT fail the run.
#
# ERROR checks : frontmatter (opening/closing '---', name matches dir,
#                description present), H1 == '# zuvo:<dir>', run-logger
#                reference present, no literal '{plugin_root}' token,
#                include-integrity (every ../../shared/includes|rules/*.md
#                token resolves on disk), references-layout (references/ is
#                flat — the platform builds copy one level only),
#                count-consistency (declared skill counts in plugin
#                manifests/docs/router match actual dirs),
#                category-consistency (every SKILL.md declares a 'category:'
#                that is a row of the '| Category | Count |' tables, and each
#                row's Count equals the number of skills declaring it — the
#                column used to be summed but never compared; a doc that EXISTS
#                without its table, or a label repeated across rows, is an
#                ERROR, not a skip).
# WARN checks  : an arg-parsing signal is present, a Mandatory File Loading
#                section is present.
#
# Usage:
#   scripts/validate-skills.sh              # lint the whole repo (default root)
#   scripts/validate-skills.sh --root DIR   # lint a fixture/other tree
#   scripts/validate-skills.sh --print-count [--root DIR]
#   scripts/validate-skills.sh --root DIR --print-count
#                                           # print ONLY the skill count, exit 0
#                                           # (flag order is irrelevant)
#
# Exit codes: 0 = clean (WARNs allowed), 1 = conformance ERRORs found,
#             2 = usage error (unknown flag, or a root — explicit OR implicit —
#                 that is missing/has no skills/ while --print-count is asked).
#
# bash 3.2-compatible (macOS default): no mapfile, no associative arrays.

set -uo pipefail

# --- argument parsing (order-independent) ---
# Parsed in a LOOP so `--print-count --root DIR` and `--root DIR --print-count`
# are the same invocation. The first cut only recognised --print-count as $1,
# which made the second form die with "unexpected extra arguments" — a caller
# that appends flags (CI, dev-push.sh) hit a hard exit 2 for a documented
# combination.
# --print-count is ACTED ON far below, after the checks are defined and after
# the skills/ guard, so a root without skills/ still exits 2 instead of
# confidently printing 0.
usage_line() { echo "Usage: $0 [--print-count] [--root <path>]" >&2; }

PRINT_COUNT=0
ROOT_EXPLICIT=0
ROOT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --print-count)
      PRINT_COUNT=1
      shift
      ;;
    --root)
      if [ "$#" -lt 2 ]; then
        echo "ERROR: --root requires a value" >&2
        usage_line
        exit 2
      fi
      # A second --root used to silently last-win (ROOT overwritten with no
      # complaint), which is exactly the kind of invocation a caller building
      # up flags programmatically (or fat-fingering a copy-paste) would never
      # notice went wrong. Reject it the same way every other malformed
      # invocation is rejected: loud, exit 2, before any lint work happens.
      if [ "$ROOT_EXPLICIT" -eq 1 ]; then
        echo "ERROR: --root specified more than once" >&2
        usage_line
        exit 2
      fi
      ROOT="$2"
      ROOT_EXPLICIT=1
      shift 2
      ;;
    *)
      # Both historical exit-2 messages are preserved verbatim: a stray token
      # AFTER --root <dir> has always been reported as "unexpected extra
      # arguments", anything else as "unknown argument".
      if [ "$ROOT_EXPLICIT" -eq 1 ]; then
        echo "ERROR: unexpected extra arguments: $*" >&2
      else
        echo "ERROR: unknown argument: $1" >&2
      fi
      usage_line
      exit 2
      ;;
  esac
done

if [ "$ROOT_EXPLICIT" -eq 1 ]; then
  if [ ! -d "$ROOT" ]; then
    echo "ERROR: --root path does not exist: $ROOT" >&2
    exit 2
  fi
else
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
SKILLS_DIR="$ROOT/skills"

# --- exemption lists (named so the exceptions are explicit, not magic) ---
H1_EXEMPT="using-zuvo"
RUNLOGGER_EXEMPT="using-zuvo worktree"
ARGPARSE_EXEMPT="brainstorm receive-review worktree using-zuvo"
MFL_EXEMPT="using-zuvo worktree"

# arg-parsing signals: any one satisfies the WARN check.
ARGPARSE_SIGNAL='(^#+[[:space:]]+(Argument Parsing|Arguments|Input Resolution|Execution Modes|Invocation Format))|(^#+.*Parse \$ARGUMENTS)'

# field separator for the 'count<TAB>label' rows the category helpers exchange;
# a tab is used because category labels contain spaces
TAB="$(printf '\t')"

# --- counters + reporters ---
ERRORS=0
WARNINGS=0
fail_err()  { echo "ERROR: $1"; ERRORS=$((ERRORS + 1)); }
fail_warn() { echo "WARN: $1";  WARNINGS=$((WARNINGS + 1)); }
pass()      { [ -n "${ZUVO_LINT_VERBOSE:-}" ] && echo "OK: $1"; return 0; }

# --- small helpers ---
skill_dir() { basename "$(dirname "$1")"; }

skill_name_of() {
  # first path segment under skills/ (works for SKILL.md and agents/*.md)
  local rel="${1#"$SKILLS_DIR"/}"
  printf '%s' "${rel%%/*}"
}

is_exempt() {
  local dir="$1" list="$2" item
  for item in $list; do
    [ "$item" = "$dir" ] && return 0
  done
  return 1
}

strip() {
  # trim surrounding whitespace, then one layer of matching quotes
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  case "$s" in
    \"*\") s="${s#\"}"; s="${s%\"}" ;;
    \'*\') s="${s#\'}"; s="${s%\'}" ;;
  esac
  printf '%s' "$s"
}

fm_value() {
  # first value of a top-level frontmatter key (between the two '---' fences);
  # CRLF-safe: strips a trailing carriage return before printing.
  local key="$1" file="$2"
  awk -v pat="^${key}:" '
    NR==1                     { next }
    /^---[[:space:]]*$/       { exit }
    $0 ~ pat                  { v=$0; sub(pat"[[:space:]]*","",v); sub(/\r$/,"",v); print v; exit }
  ' "$file"
}

# --- ERROR: frontmatter fence + name-matches-dir + description present ---
check_frontmatter() {
  local f dir name desc
  for f in "$SKILLS_DIR"/*/SKILL.md; do
    [ -f "$f" ] || continue
    dir="$(skill_dir "$f")"
    if [ "$(head -n1 "$f" | tr -d '\r')" != "---" ]; then
      fail_err "$dir: SKILL.md must open with a '---' frontmatter fence"
      continue
    fi
    if ! awk 'NR>1 && /^---[[:space:]]*$/{f=1; exit} END{exit !f}' "$f"; then
      fail_err "$dir: frontmatter has no closing '---' fence"
      continue
    fi
    name="$(strip "$(fm_value name "$f")")"
    if [ -z "$name" ]; then
      fail_err "$dir: frontmatter missing 'name:' field"
    elif [ "$name" != "$dir" ]; then
      fail_err "$dir: frontmatter name '$name' does not match directory '$dir'"
    else
      pass "$dir: frontmatter name matches directory"
    fi
    desc="$(strip "$(fm_value description "$f")")"
    [ -n "$desc" ] || fail_err "$dir: frontmatter missing/empty 'description:' field"
  done
}

# --- ERROR: H1 must be '# zuvo:<dir>' (optionally with a ' — <title>' suffix) ---
check_h1() {
  local f dir h1 expect
  for f in "$SKILLS_DIR"/*/SKILL.md; do
    [ -f "$f" ] || continue
    dir="$(skill_dir "$f")"
    if is_exempt "$dir" "$H1_EXEMPT"; then
      pass "$dir: H1 exempt"; continue
    fi
    h1="$(grep -m1 '^# ' "$f" | tr -d '\r' || true)"
    expect="# zuvo:$dir"
    if [ "$h1" = "$expect" ] || [ "${h1#"$expect "}" != "$h1" ]; then
      pass "$dir: H1 ok"
    else
      fail_err "$dir: H1 must be '$expect' (optionally '$expect — <title>'), found '${h1:-<none>}'"
    fi
  done
}

# --- WARN: at least one arg-parsing signal should be present ---
check_arg_parsing() {
  local f dir
  for f in "$SKILLS_DIR"/*/SKILL.md; do
    [ -f "$f" ] || continue
    dir="$(skill_dir "$f")"
    is_exempt "$dir" "$ARGPARSE_EXEMPT" && continue
    if grep -Eq -- "$ARGPARSE_SIGNAL" "$f"; then
      pass "$dir: arg-parsing signal present"
    else
      fail_warn "$dir: no arg-parsing signal (## Argument Parsing / ## Arguments / etc.)"
    fi
  done
}

# --- WARN: a Mandatory File Loading section should be present ---
check_mfl() {
  local f dir
  for f in "$SKILLS_DIR"/*/SKILL.md; do
    [ -f "$f" ] || continue
    dir="$(skill_dir "$f")"
    is_exempt "$dir" "$MFL_EXEMPT" && continue
    if grep -qi 'Mandatory File Loading' "$f"; then
      pass "$dir: MFL section present"
    elif ! grep -qE '\.\./\.\./(shared/includes|rules)/' "$f"; then
      pass "$dir: MFL n/a (loads no shared includes)"
    elif [ -z "$(grep -oE '\.\./\.\./(shared/includes|rules)/[a-z0-9-]+\.md' "$f" \
                 | grep -vE '(retrospective|run-logger)\.md' | head -1)" ]; then
      # A bootstrap block says "read these BEFORE you start". A skill whose only shared includes
      # are retrospective.md and run-logger.md has nothing to load at start — both run at
      # COMPLETION. Demanding the block there would document something untrue, so this is a
      # pass with a stated reason rather than a warning nobody can action.
      pass "$dir: MFL n/a (only end-of-run includes: retrospective/run-logger)"
    else
      fail_warn "$dir: no 'Mandatory File Loading' section"
    fi
  done
}

# --- ERROR: every skill must reference the shared run-logger include ---
check_run_logger() {
  local f dir
  for f in "$SKILLS_DIR"/*/SKILL.md; do
    [ -f "$f" ] || continue
    dir="$(skill_dir "$f")"
    is_exempt "$dir" "$RUNLOGGER_EXEMPT" && continue
    if grep -qF 'run-logger.md' "$f"; then
      pass "$dir: run-logger include referenced"
    else
      fail_err "$dir: no 'run-logger.md' include reference (expected ../../shared/includes/run-logger.md)"
    fi
  done
}

# --- ERROR: no markdown file under skills/ may contain the {plugin_root} token ---
check_plugin_root() {
  local f skill rel
  # null-delimited so filenames with newlines/spaces cannot break the loop
  while IFS= read -r -d '' f; do
    if grep -Fq -- '{plugin_root}' "$f"; then
      skill="$(skill_name_of "$f")"
      rel="${f#"$ROOT"/}"
      fail_err "$skill: $rel contains literal '{plugin_root}' (use ../../ relative paths)"
    fi
  done < <(find "$SKILLS_DIR" -type f -name '*.md' -print0)
}

# --- Task 3 checks (include-integrity, count-consistency) ---

# include tokens checked: any file under shared/includes/ or rules/, INCLUDING
# subdirectory references like banned-vocabulary/core.md. Placeholder segments
# (<resolved-lang>.md, {stack}.md) contain chars outside the class and are
# deliberately never matched.
# Broad (\.\./)+ prefix so ../../../ forms are captured WHOLE — a narrow
# \.\./\.\./ pattern substring-truncates them and silently passes them.
INCLUDE_TOKEN_RE='(\.\./)+(shared/includes|rules)(/[A-Za-z0-9._-]+)+\.md'
INCLUDE_INTEGRITY_OK=0
COUNT_CONSISTENCY_OK=0
ACTUAL_SKILLS=0

# routing-table tokens that are NOT skills (PR labels etc.) — filtered before
# comparing the routed-skill count against the actual skill count
ROUTING_NONSKILL_TOKENS="zuvo:adhoc-approved"

# --- ERROR: every shared/includes|rules include token must exist on disk ---
# --- AND use the canonical depth for the referencing file's level ---
check_include_integrity() {
  local before="$ERRORS" f tok rel fileloc skill deep canon
  while IFS= read -r -d '' f; do
    fileloc="${f#"$SKILLS_DIR"/}"   # e.g. build/SKILL.md or refactor/agents/x.md
    skill="$(skill_name_of "$f")"
    # DEPTH RULE (filesystem-correct everywhere; 2026-08 rewrite): every token
    # must reach the repo root RELATIVE TO THE REFERENCING FILE.
    #   SKILL.md-level files sit 2 levels below the root → ../../
    #   agents/ and references/ files sit 3 levels below  → ../../../
    # The former waiver ("root-anchored ../../ accepted in agents/") is GONE:
    # two coexisting conventions let 4 agent files silently point at
    # skills/shared/… (fixed 2026-08-01). Nested references/ subdirs still get
    # their own hard ERROR in check_references_layout.
    # sort -u dedupes repeated identical tokens per file (no ERROR spam).
    # Nested references/ subdirs are architecturally unshippable and get their
    # hard ERROR in check_references_layout; any depth advice for them would be
    # bogus (they sit 3+ levels below skills/), so skip the include checks.
    case "${fileloc#*/}" in
      references/*/*) continue ;;
    esac
    deep=0
    [ "${fileloc#*/*/}" != "$fileloc" ] && deep=1   # ≥2 levels below skills/
    canon="../../"
    [ "$deep" -eq 1 ] && canon="../../../"
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      case "$tok" in
        ../../../../*)
          fail_err "$skill: non-canonical include depth (must be $canon): $tok in ${f#"$ROOT"/}" ;;
        ../../../*)
          if [ "$deep" -eq 0 ]; then
            fail_err "$skill: non-canonical include depth (must be $canon): $tok in ${f#"$ROOT"/}"
          else
            rel="${tok#../../../}"
            [ -f "$ROOT/$rel" ] \
              || fail_err "$skill: dangling include $tok in ${f#"$ROOT"/} (no $rel under root)"
          fi ;;
        ../../*)
          rel="${tok#../../}"
          if [ "$deep" -eq 1 ]; then
            # Two DISTINCT defects, reported separately so the message is never
            # misleading:
            #   depth wrong  — target exists at root, the token just needs one
            #                  more ../ ; suggest the fix
            #   dangling     — target exists NOWHERE; a depth suggestion would
            #                  send the reader chasing a file that isn't there
            if [ -f "$ROOT/$rel" ]; then
              fail_err "$skill: wrong-depth include $tok in ${f#"$ROOT"/} (agents/ and references/ resolve relative to their own dir — use ../../../$rel)"
            else
              fail_err "$skill: dangling include $tok in ${f#"$ROOT"/} (no $rel relative to the file or under root)"
            fi
          else
            [ -f "$ROOT/$rel" ] \
              || fail_err "$skill: dangling include $tok in ${f#"$ROOT"/} (no $rel under root)"
          fi ;;
        *)
          fail_err "$skill: non-canonical include depth (must be $canon): $tok in ${f#"$ROOT"/}" ;;
      esac
    done < <(grep -oE -- "$INCLUDE_TOKEN_RE" "$f" | sort -u)

    # B-validator-placeholder-prefix: a PLACEHOLDER include (…/languages/<resolved-lang>.md,
    # …/{stack}.md) is deliberately excluded from the check above — the filename is only known at
    # runtime, so it cannot be stat-ed. But the STATIC part in front of the placeholder is a real
    # directory, and a typo there is exactly as fatal as a dangling include and exactly as silent:
    # the skill resolves nothing at runtime and degrades without saying so. Verify the directory.
    while IFS= read -r ptok; do
      [ -n "$ptok" ] || continue
      pdir="${ptok%/*}"                       # strip the <placeholder>.md leaf
      prel="${pdir#"${pdir%%shared/*}"}"      # keep from shared/… onward
      case "$prel" in shared/*|rules/*) ;; *) prel="${pdir#*rules/}"; prel="rules/$prel" ;; esac
      [ -d "$ROOT/$prel" ] \
        || fail_err "$skill: placeholder include $ptok in ${f#"$ROOT"/} — static prefix $prel is not a directory under root"
    done < <(grep -oE -- '(\.\./)+(shared/includes|rules)(/[A-Za-z0-9._-]+)*/[<{][^>}]*[>}][A-Za-z0-9._-]*\.md' "$f" | sort -u)
  done < <(find "$SKILLS_DIR" -type f -name '*.md' -print0)
  [ "$ERRORS" -eq "$before" ] && INCLUDE_INTEGRITY_OK=1
}

# --- ERROR: references/ must be FLAT — nested subdirs never reach any dist ---
# All three platform builds copy exactly one level, non-recursively:
#   for ref in "$skill_dir/references/"*.md   (build-codex-skills.sh,
#   build-cursor-skills.sh, build-antigravity-skills.sh)
# So a file at skills/<name>/references/sub/x.md — or a references/ dir that is
# not directly under the skill — is not merely mis-validated, it is
# architecturally unshippable: it exists in the repo and reaches no platform.
# Fail loudly at lint time instead of silently dropping it at build time.
check_references_layout() {
  local f fileloc rest
  while IFS= read -r -d '' f; do
    fileloc="${f#"$SKILLS_DIR"/}"
    case "$fileloc" in */references/*) ;; *) continue ;; esac
    rest="${fileloc#*/}"             # everything below skills/<name>/
    case "$rest" in
      references/*/*)
        fail_err "$(skill_name_of "$f"): unsupported references/ layout ${f#"$ROOT"/} — platform builds copy skills/<name>/references/*.md ONE level only, so nested references/ subdirs never ship" ;;
      references/*) ;;               # the supported flat layout
      *)
        fail_err "$(skill_name_of "$f"): unsupported references/ layout ${f#"$ROOT"/} — platform builds copy skills/<name>/references/*.md ONE level only, so a references/ dir nested elsewhere never ships" ;;
    esac
  done < <(find "$SKILLS_DIR" -type f -name '*.md' -print0)
}

# --- count-consistency helpers ---
count_actual_skills() {
  local n=0 d
  for d in "$SKILLS_DIR"/*/; do
    [ -f "${d}SKILL.md" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

first_skills_num() {
  # first '<N> skills' number in stdin; empty if absent
  grep -oE '[0-9]+ skills' | head -n1 | grep -oE '^[0-9]+'
}

cc_assert() {
  # cc_assert <file-label> <what> <extracted-value> [expected]
  # Empty value = anchor not present in this tree (fixture roots) → skip.
  # expected defaults to the actual skill-dir count.
  local file="$1" what="$2" val="$3" expect="${4:-$ACTUAL_SKILLS}"
  [ -n "$val" ] || return 0
  if [ "$val" != "$expect" ]; then
    fail_err "count-consistency: $file: $what says $val, expected $expect (actual skill dirs: $ACTUAL_SKILLS)"
  else
    pass "count-consistency: $file $what = $expect"
  fi
}

json_string_field() {
  # print a string field from a JSON file; supports dotted paths for nested
  # keys (e.g. 'interface.longDescription'); empty on error or missing hop.
  # python3 preferred (repo precedent: install.sh / dev-push.sh parse JSON
  # with python3); line-grep approximation kept as fallback (matches the
  # LAST path segment anywhere in the file, so it is nesting-agnostic).
  local file="$1" key="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
obj = json.load(open(sys.argv[1], encoding="utf-8"))
for k in sys.argv[2].split("."):
    obj = obj.get(k) if isinstance(obj, dict) else None
print(obj if isinstance(obj, str) else "")
' "$file" "$key" 2>/dev/null
  else
    grep -- "\"${key##*.}\"" "$file" | head -n1
  fi
}

# THE single expression of the '| Category | Count |' header anchor (CQ14).
# Written with a bracketed [|] rather than a backslash-escaped \| so the SAME
# string is a valid ERE for BOTH consumers: `grep -E` below and awk's dynamic
# regex in category_rows (which receives it via -v and would otherwise have to
# survive awk's escape processing of '\|', whose result is implementation-
# defined — gawk warns, and a degraded '|' would turn the anchor into an
# alternation that matches EVERY line).
# It previously existed twice: this constant plus an inline copy inside the awk
# body. Two expressions of one anchor drift; there is now exactly one.
CATEGORY_TABLE_HEADER_RE='^[|] *Category *[|] *Count *[|]'

# Sentinel emitted by category_rows for a malformed mid-table line (see below).
# Deliberately carries NO tab character, so every TAB-split consumer downstream
# (category_labels, category_dup_labels, category_count_of — all gated on
# `NF > 1` against $TAB) ignores it for free without a second table walker.
MALFORMED_ROW_MARKER='##CATEGORY-TABLE-MALFORMED##'

has_category_table() {
  grep -qE -- "$CATEGORY_TABLE_HEADER_RE" "$1"
}

category_rows() {
  # ONE walker over the '| Category | Count |' table, two consumers
  # (count-consistency sums it, category-consistency compares it row by row).
  # Emits 'count<TAB>label' per data row: starts after the header, stops at the
  # bold '**Total**' row, a markdown heading line, or EOF. The |---|---|
  # separator row yields an empty count and is dropped.
  # Not every real table has a '**Total**' row — CLAUDE.md's '## Skill
  # categories' table ends at the next '## ' heading with no Total line, while
  # docs/skills.md's DOES have one. A heading is an unambiguous, structural end
  # of the table's section, so it terminates the walk cleanly (same as Total),
  # never flagged as malformed.
  # Blank lines INSIDE the table are skipped, not treated as the end: a stray
  # empty line mid-table used to truncate the walk and silently drop every row
  # after it, producing a partial tally that still compared "successfully".
  # A non-blank, non-row, non-heading line mid-table (stray prose) is the SAME
  # defect class, half-fixed: it is now ALSO skipped rather than truncating the
  # walk (rows after it are never silently dropped), but the table IS
  # malformed, so a no-tab marker line ('MALFORMED_ROW_MARKER:<lineno>') is
  # emitted for it. category_malformed_lines() below pulls those back out for
  # a loud, file-and-line-numbered ERROR — never a silently-accepted partial
  # table.
  # Labels are carried WHOLE — they contain spaces ('Infra audits') and a slash
  # ('Code/Test audits'), so they are only ever compared with [ "$a" = "$b" ]
  # or grep -Fx, never spliced into a regex, a sed script or a case glob.
  awk -F'|' -v tab="$TAB" -v hdr="$CATEGORY_TABLE_HEADER_RE" -v marker="$MALFORMED_ROW_MARKER" '
    $0 ~ hdr                       { in_t=1; next }
    in_t && /\*\*Total\*\*/        { exit }
    in_t && /^#/                   { exit }
    in_t && /^[[:space:]]*$/       { next }
    in_t && /^\|/ {
      label=$2; count=$3
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", label)
      gsub(/[^0-9]/, "", count)
      if (count != "" && label != "") print count tab label
      next
    }
    in_t                           { print marker ":" NR; next }
  ' "$1"
}

category_malformed_lines() {
  # category_malformed_lines <category_rows output> → the line numbers of any
  # malformed mid-table rows found in that SAME walk (no second awk pass over
  # the table — one walker, filtered two ways). Empty when the table is clean.
  local rows="$1" line
  while IFS= read -r line; do
    case "$line" in
      "$MALFORMED_ROW_MARKER":*) printf '%s\n' "${line#"$MALFORMED_ROW_MARKER":}" ;;
    esac
  done <<< "$rows"
}

sum_category_table() {
  # sum of the Count column, derived from the shared walker
  category_rows "$1" | awk '{ sum += $1 } END { print sum + 0 }'
}

cc_json_skills_count() {
  # extract '<N> skills' from a JSON field and assert it; the file is known
  # to exist here, so an EMPTY extraction means the field vanished or lost
  # its count — fail LOUD instead of letting the check go silently inert.
  local file="$1" key="$2" v
  v="$(json_string_field "$ROOT/$file" "$key" | first_skills_num)"
  if [ -z "$v" ]; then
    fail_err "count-consistency: $file: expected field $key not found (check went inert?)"
    return 0
  fi
  cc_assert "$file" "$key" "$v"
}

# --- count sources (a): plugin manifests + package.json description fields ---
# NOTE: description is TOP-LEVEL in all three files; codex longDescription is
# NESTED at interface.longDescription (verified 2026-07 on the real manifest).
cc_check_json_files() {
  local f
  for f in ".claude-plugin/plugin.json" "package.json"; do
    [ -f "$ROOT/$f" ] || continue
    cc_json_skills_count "$f" "description"
  done
  f=".codex-plugin/plugin.json"
  if [ -f "$ROOT/$f" ]; then
    cc_json_skills_count "$f" "description"
    cc_json_skills_count "$f" "interface.longDescription"
  fi
}

# --- count source (b): docs/skills.md intro + category table + Total row ---
cc_check_docs_skills() {
  local f="$ROOT/docs/skills.md" v
  [ -f "$f" ] || return 0
  v="$(first_skills_num < "$f")"
  cc_assert "docs/skills.md" "intro" "$v"
  if has_category_table "$f"; then
    cc_assert "docs/skills.md" "category-table sum" "$(sum_category_table "$f")"
  fi
  v="$(awk -F'|' '/^\| *\*\*Total\*\*/ { gsub(/[^0-9]/, "", $3); print $3; exit }' "$f")"
  cc_assert "docs/skills.md" "Total row" "$v"
}

# --- count source (c): using-zuvo banner + routing table ---
cc_check_using_zuvo() {
  local f="$SKILLS_DIR/using-zuvo/SKILL.md" v
  [ -f "$f" ] || return 0
  v="$(grep -E -- '^> \*\*Zuvo' "$f" | head -n1 \
    | grep -oE '\| *[0-9]+ skills' | grep -oE '[0-9]+' | head -n1)"
  cc_assert "skills/using-zuvo/SKILL.md" "banner" "$v"
  # Routing table: unique zuvo:<name> tokens between '## Routing Table' and
  # the next '^## ' heading, minus known non-skill tokens (PR labels listed
  # in ROUTING_NONSKILL_TOKENS). The router (using-zuvo) is not routed in
  # its own table, so the filtered count is compared against ACTUAL - 1.
  # EMPIRICAL (2026-07, this repo): 54 raw unique tokens = 53 routed skills
  # + zuvo:adhoc-approved; filtered 53 == 54 - 1.
  if grep -qE '^##[[:space:]]+Routing Table' "$f"; then
    local nonskill_pat
    nonskill_pat="$(printf '%s' "$ROUTING_NONSKILL_TOKENS" | tr ' ' '|')"
    v="$(awk '/^##[[:space:]]+Routing Table/ {t=1; next} t && /^## / {exit} t' "$f" \
      | grep -oE 'zuvo:[a-z][a-z0-9-]*' | sort -u \
      | grep -vE "^(${nonskill_pat})\$" | wc -l | tr -d ' ')"
    cc_assert "skills/using-zuvo/SKILL.md" "routing-table routed skills" "$v" "$((ACTUAL_SKILLS - 1))"
  fi
}

# --- count source (d): CLAUDE.md '(N total)' anchors + category table ---
cc_check_claude_md() {
  local f="$ROOT/CLAUDE.md" v
  [ -f "$f" ] || return 0
  # only '(N total)' anchors on skill-related lines are counted (both real
  # anchors match '[Ss]kill': "skill definitions (54 total)" and
  # "## Skill categories (54 total)") — unrelated "(N total)" prose is ignored
  while IFS= read -r v; do
    cc_assert "CLAUDE.md" "'(N total)' anchor" "$v"
  done < <(grep -E '[Ss]kill' "$f" | grep -oE '\([0-9]+ total\)' | grep -oE '[0-9]+')
  if has_category_table "$f"; then
    cc_assert "CLAUDE.md" "category-table sum" "$(sum_category_table "$f")"
  fi
}

# --- count source (e): README.md — EVERY '<N> skills'/'<N> Skills' mention ---
# README was the 8th place carrying the count and the only one no check
# covered — it sat at "55 skills" while everything else said 56 (found
# 2026-08-01). A first-match-only check then missed two MORE stale 55s
# further down ("= 55" breakdown, "[All 55 Skills]"), so every occurrence
# is asserted, mirroring the CLAUDE.md multi-anchor loop.
# DELIBERATE strictness: a future phrase like "5 pipeline skills" would fail
# this check — that loud false positive is preferred over the silent drift
# that already happened twice; reword such prose (e.g. "pipeline skills: 5").
cc_check_readme() {
  local f="$ROOT/README.md" v
  [ -f "$f" ] || return 0
  while IFS= read -r v; do
    cc_assert "README.md" "'<N> skills' mention" "$v"
  done < <(grep -ioE '[0-9]+ skills' "$f" | grep -oE '[0-9]+')
}

# --- ERROR: every declared skill count must equal the actual dir count ---
check_count_consistency() {
  local before="$ERRORS"
  ACTUAL_SKILLS="$(count_actual_skills)"
  cc_check_json_files
  cc_check_docs_skills
  cc_check_using_zuvo
  cc_check_claude_md
  cc_check_readme
  [ "$ERRORS" -eq "$before" ] && COUNT_CONSISTENCY_OK=1
}

# --- category-consistency ---------------------------------------------------
# `category:` in SKILL.md frontmatter is REPO-SIDE DOCUMENTATION ONLY. All three
# platform builds rewrite the frontmatter and drop every key they do not emit —
# the `in_fm { next }` catch-all at build-codex-skills.sh:298,
# build-cursor-skills.sh:154 and build-antigravity-skills.sh:177 — so
# `category:` never reaches a dist and is not a runtime contract. It exists so
# the per-category Count column in docs/skills.md and CLAUDE.md has a machine-
# checkable single source of truth: count-consistency only ever SUMMED that
# column, so any distribution passed as long as the total held.
CATEGORY_TABLE_FILES="docs/skills.md CLAUDE.md README.md"
CATEGORY_STATUS=""

# --- ERROR: a category-table file may declare at most ONE '| Category | Count |'
# anchor line. Both consumers of that anchor — sum_category_table (count-
# consistency) and category_rows (category-consistency) — are ONE walker each,
# and that walker's awk state machine locks onto the FIRST header match
# (`$0 ~ hdr { in_t=1; next }`) and never re-arms, so a second table anywhere
# below it is silently invisible to both: its rows are counted nowhere and
# compared against nothing. Rather than teach the one walker to also handle
# N tables per file (which would have to reinvent Total-vs-heading
# termination per table, doubling the surface this file's own history shows
# is easy to get subtly wrong — see the CLAUDE.md-vs-docs/skills.md comment
# on category_rows), a second anchor is treated as a doc defect and reported
# loudly. This keeps the real two files working unchanged (each has exactly
# one anchor today) while turning the silent-ignore into a loud ERROR the
# moment a second table appears.
check_category_table_uniqueness() {
  local f fpath n
  for f in $CATEGORY_TABLE_FILES; do
    fpath="$ROOT/$f"
    [ -f "$fpath" ] || continue
    n="$(grep -cE -- "$CATEGORY_TABLE_HEADER_RE" "$fpath")"
    if [ "$n" -gt 1 ]; then
      fail_err "category-consistency: $f contains $n '| Category | Count |' table anchors — only the first is validated (both count- and category-consistency stop at the first table); consolidate into one table or remove the extra"
    fi
  done
}

category_tally() {
  # every declared category across skills/*/SKILL.md, as 'count<TAB>label'
  local f label
  for f in "$SKILLS_DIR"/*/SKILL.md; do
    [ -f "$f" ] || continue
    label="$(strip "$(fm_value category "$f")")"
    [ -n "$label" ] && printf '%s\n' "$label"
  done | sort | uniq -c \
       | awk -v tab="$TAB" '{ c=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); print c tab $0 }'
}

category_labels() {
  # the label column of 'count<TAB>label' lines, deduped, blanks dropped
  printf '%s\n' "$1" | awk -F"$TAB" 'NF > 1 && $2 != "" { print $2 }' | sort -u
}

category_dup_labels() {
  # labels that appear on MORE THAN ONE row of a 'count<TAB>label' block.
  # DECISION (finding 5): a duplicated label is an ERROR, not something to
  # aggregate. Aggregating would let '| Core | 2 |' + '| Core | 2 |' silently
  # satisfy a 4-skill Core category while the table reads as two contradictory
  # rows to every human; the doc defect is the thing worth reporting. This also
  # means category_count_of's first-match-wins is never ambiguous in a tree that
  # passes the lint — the ambiguity is reported before it can be relied on.
  printf '%s\n' "$1" | awk -F"$TAB" 'NF > 1 && $2 != "" { print $2 }' | sort | uniq -d
}

category_count_of() {
  # category_count_of <label> <'count<TAB>label' lines> → that label's count,
  # or empty when the label is absent from the given side.
  # First match wins; duplicates are rejected up-front by category_dup_labels.
  local want="$1" rows="$2" c l
  while IFS="$TAB" read -r c l; do
    [ "$l" = "$want" ] || continue
    printf '%s' "$c"
    return 0
  done <<< "$rows"
  return 1
}

check_category_table() {
  # compare ONE doc's Count column against the frontmatter tally, label by
  # label, over the union of both sides so a row missing from either is caught
  local file="$1" rows="$2" tally="$3" label declared actual
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    declared="$(category_count_of "$label" "$rows")"
    actual="$(category_count_of "$label" "$tally")"
    [ -n "$declared" ] || declared=0
    [ -n "$actual" ] || actual=0
    if [ "$declared" != "$actual" ]; then
      fail_err "category-consistency: $file: category '$label' says $declared, actual SKILL.md 'category:' tally is $actual"
    else
      pass "category-consistency: $file: $label = $actual"
    fi
  done <<< "$(printf '%s\n%s\n' "$(category_labels "$rows")" "$(category_labels "$tally")" | sort -u)"
}

# --- ERROR: declared categories must match the category tables ---
check_categories() {
  local before="$ERRORS" tally f fpath rows all_labels="" tables=0 present=0 dup dir label ncat
  tally="$(category_tally)"

  for f in $CATEGORY_TABLE_FILES; do
    fpath="$ROOT/$f"
    [ -f "$fpath" ] || continue
    present=$((present + 1))
    if ! has_category_table "$fpath"; then
      # A file that EXISTS but lost its table is a defect, never a skip: the
      # old `tables == 0` skip covered this case too, so deleting the table
      # from docs/skills.md and CLAUDE.md silently disabled every per-category
      # assertion and the run still printed green.
      fail_err "category-consistency: $f exists but has no '| Category | Count |' table — deleting it would silently disable every per-category check"
      continue
    fi
    tables=$((tables + 1))
    rows="$(category_rows "$fpath")"
    while IFS= read -r mline; do
      [ -n "$mline" ] || continue
      fail_err "category-consistency: $f: line $mline is inside the category table but is neither blank nor a table row — malformed table (rows after it were still parsed, not silently dropped)"
    done <<< "$(category_malformed_lines "$rows")"
    while IFS= read -r dup; do
      [ -n "$dup" ] || continue
      fail_err "category-consistency: $f: category '$dup' appears on more than one row of the category table"
    done <<< "$(category_dup_labels "$rows")"
    all_labels="$(printf '%s\n%s\n' "$all_labels" "$(category_labels "$rows")")"
    check_category_table "$f" "$rows" "$tally"
  done

  if [ "$tables" -eq 0 ]; then
    if [ "$present" -gt 0 ]; then
      # Every present file already produced its own ERROR above. There is no
      # label set to compare skills against, so the per-skill loop would only
      # add one bogus "not a row of the category table" line per skill; the
      # named file ERRORs are the actionable verdict.
      return 0
    fi
    # Anchor-absent skip (the cc_assert idiom), now RESERVED for roots where
    # NONE of $CATEGORY_TABLE_FILES exists — the fixture-root case it was
    # designed for. Reported LOUDLY rather than silently, and the contract test
    # asserts the real repo never prints this line.
    # The message spells out exactly what "n/a" disables: not just the table
    # comparison itself, but EVERY per-skill check that depends on it — the
    # 'category:' presence check and the unlisted-label check both live inside
    # the per-skill loop below, which never runs when there is no label set to
    # compare against. Without this a reader could mistake "n/a" for "checked,
    # nothing wrong" instead of "not checked at all".
    CATEGORY_STATUS="category-consistency: n/a (no category table in $ROOT; per-skill 'category:' presence/label checks were skipped too)"
    return 0
  fi

  all_labels="$(printf '%s\n' "$all_labels" | awk 'NF' | sort -u)"

  for fpath in "$SKILLS_DIR"/*/SKILL.md; do
    [ -f "$fpath" ] || continue
    dir="$(skill_dir "$fpath")"
    label="$(strip "$(fm_value category "$fpath")")"
    if [ -z "$label" ]; then
      fail_err "category-consistency: $dir: missing 'category:' in SKILL.md frontmatter"
    elif ! printf '%s\n' "$all_labels" | grep -Fxq -- "$label"; then
      fail_err "category-consistency: $dir: category '$label' is not a row of the category table in $CATEGORY_TABLE_FILES"
    else
      pass "category-consistency: $dir: $label"
    fi
  done

  if [ "$ERRORS" -eq "$before" ]; then
    ncat="$(printf '%s\n' "$all_labels" | awk 'NF' | wc -l | tr -d ' ')"
    CATEGORY_STATUS="category-consistency: OK ($ncat categories)"
  fi
}

# --- run ---
if [ ! -d "$SKILLS_DIR" ]; then
  # --print-count has exactly TWO possible outcomes on every path: one integer
  # line on stdout + rc 0, or this error on stderr + rc 2. It must never fall
  # through into the lint's "nothing to lint" success branch — a caller doing
  # N="$(validate-skills.sh --print-count)" would silently bind N to a two-line
  # lint summary while rc claimed success, which is the exact poisoning the flag
  # exists to prevent. The implicit root is no different from an explicit one
  # here: no skills/ means there is no count to print.
  if [ "$ROOT_EXPLICIT" -eq 1 ] || [ "$PRINT_COUNT" -eq 1 ]; then
    # an explicitly requested root (or any count request) without skills/ is a
    # user error, not a clean pass
    echo "ERROR: no skills/ directory under $ROOT — nothing to lint" >&2
    exit 2
  fi
  echo "ERRORS: 0  WARNINGS: 0"
  echo "no skills/ directory under $ROOT — nothing to lint"
  exit 0
fi

if [ "$PRINT_COUNT" -eq 1 ]; then
  # Deliberately BEFORE any check runs: a caller asking "how many skills are
  # there?" must get the number even while the tree is failing the lint, so an
  # unrelated ERROR can never poison the answer. Exactly the integer + '\n'.
  printf '%s\n' "$(count_actual_skills)"
  exit 0
fi

check_frontmatter
check_h1
check_arg_parsing
check_mfl
check_run_logger
check_plugin_root
check_include_integrity
check_references_layout
check_category_table_uniqueness
check_count_consistency
check_categories

[ "$INCLUDE_INTEGRITY_OK" -eq 1 ] && echo "include-integrity: OK"
[ "$COUNT_CONSISTENCY_OK" -eq 1 ] && echo "count-consistency: OK ($ACTUAL_SKILLS)"
[ -n "$CATEGORY_STATUS" ] && echo "$CATEGORY_STATUS"

# --- skill structure: mis-paired fences + loading-list integrity ---
# Both defect classes survived careful manual reading of the same files. A fence
# closed in the WRONG PLACE still passes a parity count, and a duplicate ordinal
# in a loading list is what hid three skills printing a file as READ that their
# prose never told the agent to open. Mechanical or not caught at all.
if [ -f "$ROOT/scripts/check-skill-structure.py" ]; then
  # Capture once — running the checker twice (silently for the exit code, then
  # again for the output) doubled the work over 107 files for nothing.
  if _css_out="$(python3 "$ROOT/scripts/check-skill-structure.py" 2>&1)"; then
    echo "skill-structure: OK"
  else
    printf '%s\n' "$_css_out"
    ERRORS=$((ERRORS + 1))
  fi
  unset _css_out
else
  # Absent is legitimate for a fixture tree (--root DIR), so this is not an
  # ERROR — but it must never be SILENT. A missing linter that prints nothing is
  # indistinguishable from a linter that found nothing, which is the fail-open
  # shape this whole release exists to remove.
  echo "skill-structure: SKIP (scripts/check-skill-structure.py not present under $ROOT)"
fi

# --- gate registry: every GENERATED region must match shared/includes/gate-registry.md ---
# Without this, the registry is just a seventh copy. Editing a generated region instead of the
# registry is the exact failure mode that let CQ14 lose three clauses and CQ28 stay inverted.
if [ -f "$ROOT/scripts/gen-gate-copies.py" ]; then
  if python3 "$ROOT/scripts/gen-gate-copies.py" >/dev/null 2>&1; then
    echo "gate-registry: OK (all generated regions fresh)"
  else
    echo "ERROR: gate regions are stale — run: python3 scripts/gen-gate-copies.py --write"
    ERRORS=$((ERRORS + 1))
  fi
else
  echo "gate-registry: SKIP (scripts/gen-gate-copies.py not present under $ROOT)"
fi

echo "ERRORS: $ERRORS  WARNINGS: $WARNINGS"
[ "$ERRORS" -gt 0 ] && exit 1
exit 0
