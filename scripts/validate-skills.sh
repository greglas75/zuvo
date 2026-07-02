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
#                reference present, no literal '{plugin_root}' token.
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

# --- Task 3 checks (include-integrity, count-consistency) appended below ---

echo "ERRORS: $ERRORS  WARNINGS: $WARNINGS"
[ "$ERRORS" -gt 0 ] && exit 1
exit 0
