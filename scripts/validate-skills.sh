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
#                token resolves on disk), count-consistency (declared skill
#                counts in plugin manifests/docs/router match actual dirs).
# WARN checks  : an arg-parsing signal is present, a Mandatory File Loading
#                section is present.
#
# Usage:
#   scripts/validate-skills.sh              # lint the whole repo (default root)
#   scripts/validate-skills.sh --root DIR   # lint a fixture/other tree
#
# Exit codes: 0 = clean (WARNs allowed), 1 = conformance ERRORs found,
#             2 = usage error (unknown flag, or --root missing/without skills/).
#
# bash 3.2-compatible (macOS default): no mapfile, no associative arrays.

set -uo pipefail

# --- root resolution (banned-vocabulary form, hardened arg handling) ---
ROOT_EXPLICIT=0
if [[ "${1:-}" == "--root" ]]; then
  if [ "$#" -lt 2 ]; then
    echo "ERROR: --root requires a value" >&2
    echo "Usage: $0 [--root <path>]" >&2
    exit 2
  fi
  ROOT="$2"
  ROOT_EXPLICIT=1
  if [ "$#" -gt 2 ]; then
    echo "ERROR: unexpected extra arguments: ${*:3}" >&2
    echo "Usage: $0 [--root <path>]" >&2
    exit 2
  fi
  if [ ! -d "$ROOT" ]; then
    echo "ERROR: --root path does not exist: $ROOT" >&2
    exit 2
  fi
elif [ -n "${1:-}" ]; then
  echo "ERROR: unknown argument: $1" >&2
  echo "Usage: $0 [--root <path>]" >&2
  exit 2
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

# include tokens checked: files DIRECTLY under shared/includes/ or rules/
# (subdirectory references like banned-vocabulary/core.md are out of scope).
# Broad (\.\./)+ prefix so ../../../ forms are captured WHOLE — a narrow
# \.\./\.\./ pattern substring-truncates them and silently passes them.
INCLUDE_TOKEN_RE='(\.\./)+(shared/includes|rules)/[A-Za-z0-9._-]+\.md'
INCLUDE_INTEGRITY_OK=0
COUNT_CONSISTENCY_OK=0
ACTUAL_SKILLS=0

# routing-table tokens that are NOT skills (PR labels etc.) — filtered before
# comparing the routed-skill count against the actual skill count
ROUTING_NONSKILL_TOKENS="zuvo:adhoc-approved"

# --- ERROR: every shared/includes|rules include token must exist on disk ---
# --- AND use the canonical depth for the referencing file's level ---
check_include_integrity() {
  local before="$ERRORS" f tok rel fileloc skill
  while IFS= read -r -d '' f; do
    fileloc="${f#"$SKILLS_DIR"/}"   # e.g. build/SKILL.md or refactor/agents/x.md
    skill="$(skill_name_of "$f")"
    # RESOLUTION RULE: ../../ tokens resolve against $ROOT — NEVER relative
    # to the referencing file's dirname (agents/*.md mostly use the same
    # root-anchored ../../ convention one level deeper; dirname-relative
    # resolution would produce ~87 false positives on this repo).
    # DEPTH RULE (empirical 2026-07, 15 tokens verified): ../../../ appears
    # ONLY in agent-level files (>=2 levels below skills/), where it is
    # filesystem-correct (three levels up IS the repo root) — accepted there,
    # still root-resolved. In a SKILL.md-level file, or at any other depth
    # (../ or ../../../../), it is a non-canonical-depth ERROR.
    # sort -u dedupes repeated identical tokens per file (no ERROR spam).
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      case "$tok" in
        ../../../../*)
          fail_err "$skill: non-canonical include depth (must be ../../): $tok in ${f#"$ROOT"/}" ;;
        ../../../*)
          if [ "${fileloc#*/*/}" = "$fileloc" ]; then
            # fewer than 2 path levels below skills/ → SKILL.md level → too deep
            fail_err "$skill: non-canonical include depth (must be ../../): $tok in ${f#"$ROOT"/}"
          else
            rel="${tok#../../../}"
            [ -f "$ROOT/$rel" ] \
              || fail_err "$skill: dangling include $tok in ${f#"$ROOT"/} (no $rel under root)"
          fi ;;
        ../../*)
          rel="${tok#../../}"
          [ -f "$ROOT/$rel" ] \
            || fail_err "$skill: dangling include $tok in ${f#"$ROOT"/} (no $rel under root)" ;;
        *)
          fail_err "$skill: non-canonical include depth (must be ../../): $tok in ${f#"$ROOT"/}" ;;
      esac
    done < <(grep -oE -- "$INCLUDE_TOKEN_RE" "$f" | sort -u)
  done < <(find "$SKILLS_DIR" -type f -name '*.md' -print0)
  [ "$ERRORS" -eq "$before" ] && INCLUDE_INTEGRITY_OK=1
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

sum_category_table() {
  # sum of the Count column after the '| Category | Count |' header row,
  # excluding the bold '**Total**' row; stops at the end of the table
  awk -F'|' '
    /^\| *Category *\| *Count *\|/ { in_t=1; next }
    in_t && /\*\*Total\*\*/        { exit }
    in_t && /^\|/                  { v=$3; gsub(/[^0-9]/,"",v); if (v != "") sum += v; next }
    in_t                           { exit }
    END                            { print sum + 0 }
  ' "$1"
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
  if grep -qE '^\| *Category *\| *Count *\|' "$f"; then
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
  if grep -qE '^\| *Category *\| *Count *\|' "$f"; then
    cc_assert "CLAUDE.md" "category-table sum" "$(sum_category_table "$f")"
  fi
}

# --- ERROR: every declared skill count must equal the actual dir count ---
check_count_consistency() {
  local before="$ERRORS"
  ACTUAL_SKILLS="$(count_actual_skills)"
  cc_check_json_files
  cc_check_docs_skills
  cc_check_using_zuvo
  cc_check_claude_md
  [ "$ERRORS" -eq "$before" ] && COUNT_CONSISTENCY_OK=1
}

# --- run ---
if [ ! -d "$SKILLS_DIR" ]; then
  if [ "$ROOT_EXPLICIT" -eq 1 ]; then
    # an explicitly requested root without skills/ is a user error, not a clean pass
    echo "ERROR: no skills/ directory under $ROOT — nothing to lint" >&2
    exit 2
  fi
  echo "ERRORS: 0  WARNINGS: 0"
  echo "no skills/ directory under $ROOT — nothing to lint"
  exit 0
fi

check_frontmatter
check_h1
check_arg_parsing
check_mfl
check_run_logger
check_plugin_root
check_include_integrity
check_count_consistency

[ "$INCLUDE_INTEGRITY_OK" -eq 1 ] && echo "include-integrity: OK"
[ "$COUNT_CONSISTENCY_OK" -eq 1 ] && echo "count-consistency: OK ($ACTUAL_SKILLS)"

echo "ERRORS: $ERRORS  WARNINGS: $WARNINGS"
[ "$ERRORS" -gt 0 ] && exit 1
exit 0
