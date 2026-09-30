#!/usr/bin/env bash
# scripts/lib/reviewer-lanes.sh — the reviewer-LANE grammar, kept in ONE place (plan C Task 3).
#
# `review-primary` and `review-alt` are the router's lane names (reviewer-model-route.sh answers
# `reviewer_lane=…`), and the documents that consume the router quote them, together with
# `cross-vendor`, `in-family-fallback`, `same-model-fallback` and `routing-failed`, to say what to do
# with an answer. Only an AGENT's frontmatter `model:` names a lane as a model, and only there may an
# install or a build turn it into one. Sourced by scripts/install.sh (the Claude cache) and by all four
# non-Claude builds (build-{codex,cursor,antigravity,kimi}-skills.sh), after lib/portable.sh, from
# beside themselves. It uses nothing from portable.sh.
#
# What it provides:
#   grammar     zrl_is_model_id, zrl_is_route_word, zrl_agent_model_known (the model values a build accepts)
#   rewrite     zrl_rewrite_lanes, zrl_rewrite_lanes_file (the strict rewriter, stdin or in place)
#   read        zrl_frontmatter_model (the strict reader), zrl_strip_bom_crlf, zrl_read_agent_model,
#               zrl_toml_model
#   agent gate  zrl_agent_gate (read, data-only test, accept/refuse with the ERROR line),
#               zrl_agent_is_data_only
#   scans       zrl_scan_md, zrl_scan_toml, zrl_links_inside (the lenient validators)
#   reporting   zrl_scan_and_report_lanes, zrl_scan_and_report_toml_lanes, zrl_count_refs, zrl_show_refs
#   bootstrap   zrl_require_fns (a caller's check that sourcing defined what it calls)
#
# TWO grammars, deliberately different, so one cannot hide the other's blind spot:
#   the REWRITER is strict: the one shape this repo's agent files use. Line 1 is `---` (a trailing CR
#     tolerated), the block ends at the next `---`, and a column-0 `model:` whose WHOLE value is
#     `review-primary` or `review-alt`, optionally followed by a ` # comment` that is left as written.
#   the VALIDATORS are lenient: any spelling a YAML or TOML reader could still take as a model key (a
#     BOM, blank lines before `---`, blanks after it, a CR, indentation, blanks before the `:`/`=`, a
#     quoted key or value, any letter case), and EVERY token of its value — split on anything that is
#     not a model-id character, so `[review-alt]` and `x,review-alt` are caught — checked against
#     ZRL_ROUTE_WORDS. A comment (`#` at the start of the value or after a blank) is not part of the
#     value, so `model: opus # was review-alt` passes. A value a line scanner cannot read (empty, a YAML
#     block scalar `|`/`>`, an unclosed quote, a TOML multi-line string) is REPORTED as unparsed: the
#     scan fails closed, never open. `review-primary-test` is one token and no lane.
#   A file the rewriter could not parse is therefore reported, and the install or build fails on it; it
#   never passes unrewritten.
#   The STRICT READER (zrl_frontmatter_model) is the rewriter's grammar read-only: the Codex build takes
#   an agent's model through it, so the two targets accept and refuse the same agents.
# Frontmatter starts the file (its first non-blank line is `---`): a `model:` line in any other file is
# prose, which may name a lane.
#
# SYMLINKS are followed the same way everywhere, and only INSIDE the tree being read: the rewriter reads
# through a link and replaces the LINK with the rewritten file (it never writes through it — a link in
# the cache may point into a source checkout); the scans follow links (find -L), so a lane behind a link
# is reported like any other. A link that resolves outside the tree, resolves nowhere, or points at its
# own directory or an ancestor (a cycle) fails the scan by name (zrl_links_inside); the Claude install
# runs the same check over skills/ before it rewrites anything.
#
# Definitions only; no output when sourced; bash 3.2; independent of the caller's IFS.
# install_runner_lib / zuvo_ship_runner_lib ship every file of scripts/lib/ to every host, where
# nothing sources this one: inert there.

# Every function this library defines, the internal `_zrl_*` ones included. Kept FIRST, with zrl_require_fns, so a library cut short anywhere
# below still carries the list that names what it lost.
ZRL_FUNCS="zrl_is_model_id zrl_is_route_word zrl_rewrite_lanes zrl_rewrite_lanes_file zrl_frontmatter_model
zrl_strip_bom_crlf zrl_agent_model_known zrl_read_agent_model zrl_agent_is_data_only zrl_agent_gate
zrl_links_inside zrl_scan_md zrl_scan_toml zrl_toml_model zrl_count_refs zrl_show_refs
zrl_scan_and_report_lanes zrl_scan_and_report_toml_lanes zrl_require_fns _zrl_awk _zrl_paths_exist _zrl_scan_report"

# zrl_require_fns <library-path> [function…] — status 0 when every function of ZRL_FUNCS and every one
# named is defined as a shell FUNCTION (declare -F: `command -v` would also take a PATH binary or an
# alias of that name); otherwise one ERROR line per missing function on stderr, and status 1. A build
# calls it right after sourcing, naming the functions it calls, so a truncated or renamed library fails
# there by name — not mid-build as "command not found", a status of 127 counted as 127 errors, or a
# misleading "could not be read". The caller checks `declare -F zrl_require_fns` first.
zrl_require_fns() {
  local IFS=$' \t\n' lib="$1" fn missing=0 seen=" "
  shift
  for fn in $ZRL_FUNCS "$@"; do
    case "$seen" in *" $fn "*) continue ;; esac
    seen="$seen$fn "
    if ! declare -F "$fn" >/dev/null 2>&1; then
      echo "ERROR: $fn is not defined after sourcing $lib — the library is missing or incomplete" >&2
      missing=1
    fi
  done
  return "$missing"
}

# The router's route vocabulary (the `reviewer-route` enum in shared/includes/session-state.md). None of
# these is a model; the first two are the only ones an install or a build may resolve to one.
ZRL_ROUTE_WORDS="review-primary review-alt cross-vendor in-family-fallback same-model-fallback routing-failed"

# A model id is what the router accepts: ONE definition, zms_is_model_id in model-subprocess.sh, the file
# beside this one wherever scripts/lib/ is shipped (install_runner_lib, zuvo_ship_runner_lib copy the
# whole directory). Sourcing it here is safe: it runs no command at source time — it defines its zms_*
# functions and constants, and its one assignment to the caller is LANG=C, exported only when the shell has
# neither LC_ALL nor LANG (see model-subprocess.sh for why and what it changes) — and no build or install script
# defines a zms_ name of its own. Without it,
# no id can be judged, so this library stops here (status 1) rather than guess. The id alphabet
# (ZMS_ID_ALNUM) is read from there too, by zrl_agent_model_known's tokenizer: it has no copy here.
_zrl_dir="${BASH_SOURCE[0]:-$0}"
case "$_zrl_dir" in */*) _zrl_dir="${_zrl_dir%/*}" ;; *) _zrl_dir=. ;; esac
# shellcheck source=scripts/lib/model-subprocess.sh
if ! . "$_zrl_dir/model-subprocess.sh" || ! declare -F zms_is_model_id >/dev/null 2>&1 || [ -z "${ZMS_ID_ALNUM:-}" ]; then
  echo "ERROR: reviewer lanes: $_zrl_dir/model-subprocess.sh (the one model-id definition) could not be loaded" >&2
  unset _zrl_dir
  return 1
fi
unset _zrl_dir

# zrl_is_model_id <value> — status 0 when <value> is one model id.
zrl_is_model_id() { zms_is_model_id "$@"; }

# zrl_is_route_word <value> — status 0 when <value>, in any letter case, is one of ZRL_ROUTE_WORDS.
zrl_is_route_word() {
  local IFS=' ' v w
  v="$(printf '%s' "${1:-}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  for w in $ZRL_ROUTE_WORDS; do
    [ "$v" = "$w" ] && return 0
  done
  return 1
}

# ── the strict REWRITER ─────────────────────────────────────────────────────────────────────────────
# $fm: inside the frontmatter. Opened only by `---` on line 1, closed by the next `---`, never reopened
# (a later `---` is a markdown rule). The lookahead takes the value only when nothing but blanks or a
# blank-separated comment follows it, so `review-primary-test` and `review-primary#x` are left alone.
ZRL_REWRITE_PL='
  if ($. == 1) { $fm = /^---\r?$/ ? 1 : 0 }
  elsif ($fm && /^---\r?$/) { $fm = 0 }
  elsif ($fm) {
    s/^(model:[ \t]*)review-primary(?=(?:[ \t]+#.*|[ \t]*)\r?$)/$1$ENV{ZRL_PRIMARY}/
      or s/^(model:[ \t]*)review-alt(?=(?:[ \t]+#.*|[ \t]*)\r?$)/$1$ENV{ZRL_ALT}/;
  }
'

# zrl_rewrite_lanes <primary-id> <alt-id> — stdin to stdout: the lanes resolved, nothing else changed.
# Both ids must be model ids, so a caller cannot write a broken model key into a file.
zrl_rewrite_lanes() {
  if ! zrl_is_model_id "${1:-}" || ! zrl_is_model_id "${2:-}"; then
    echo "reviewer lanes: the lane ids must each be one model id, got [${1:-}] [${2:-}]" >&2
    return 2
  fi
  ZRL_PRIMARY="$1" ZRL_ALT="$2" perl -pe "$ZRL_REWRITE_PL"
}

# zrl_rewrite_lanes_file <primary-id> <alt-id> <file> — the same, in place, atomically. It runs in its
# own subshell, so its traps are its own and never replace the caller's. The result goes to a
# `mktemp` file in the file's own directory (unique per call, so concurrent rewrites of one file never
# share it; the same filesystem, so the final rename is atomic), carrying the file's permissions. It
# must be non-empty when the input was and keep the line count (the rewriter only substitutes inside
# lines) — otherwise nothing moves. A file with nothing to resolve is not touched at all: no temp file
# is made, and it keeps its inode and mtime. On ANY failure, including a HUP/INT/TERM mid-way, the temp
# file is removed and the file is left exactly as it was.
zrl_rewrite_lanes_file() (
  file="${3:-}"
  tmp=""
  trap 'if [ -n "$tmp" ]; then rm -f -- "$tmp"; fi' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  _zrl_fail() {
    echo "reviewer lanes: could not rewrite $file — $1; left as it was" >&2
    exit 1
  }
  [ -f "$file" ] || _zrl_fail "it is not a file"
  # Nothing to resolve (the rewrite equals the file): done, before any temp file exists. Anything else —
  # a difference, a failed rewriter, a broken pipe — takes the checked path below.
  if zrl_rewrite_lanes "${1:-}" "${2:-}" < "$file" 2>/dev/null | cmp -s -- - "$file"; then exit 0; fi
  tmp="$(mktemp "$(dirname -- "$file")/.zrl.XXXXXX")" || { tmp=""; _zrl_fail "no temp file could be made beside it"; }
  cp -p -- "$file" "$tmp" || _zrl_fail "its permissions could not be carried over"
  zrl_rewrite_lanes "${1:-}" "${2:-}" < "$file" > "$tmp" || _zrl_fail "the rewriter failed"
  if [ -s "$file" ] && [ ! -s "$tmp" ]; then _zrl_fail "the rewrite came out empty"; fi
  in_lines=$(($(wc -l < "$file")))
  out_lines=$(($(wc -l < "$tmp")))
  [ "$in_lines" -eq "$out_lines" ] || _zrl_fail "the rewrite changed the line count ($in_lines -> $out_lines)"
  cmp -s -- "$file" "$tmp" && exit 0
  mv -f -- "$tmp" "$file" || _zrl_fail "the result could not be put in place"
  tmp=""
  exit 0
)

# zrl_frontmatter_model <file> — the STRICT READER: the rewriter's grammar, read-only. Prints the value of
# the first column-0 `model:` inside a frontmatter that starts on LINE 1 (`---`, a CR tolerated) and ends
# at the next `---` — the whole frontmatter, however long — with the CR, a blank-separated `# comment` and
# the outer blanks removed; quotes are kept, so the caller sees the value as written. Status 0 found,
# 1 none: no such frontmatter, no model key in it, or a key with nothing but blanks, a tab or a CR after
# it (an empty model is no model); 2 the file could not be read.
zrl_frontmatter_model() {
  local f="${1:?zrl_frontmatter_model: <file>}"
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    echo "reviewer lanes: cannot read $f" >&2
    return 2
  fi
  LC_ALL=C awk '
    NR == 1 { if ($0 !~ /^---\r?$/) exit; next }
    /^---\r?$/ { exit }
    /^model:/ {
      v = $0
      # The comment goes BEFORE the blanks after the key: with the blanks gone first, a key followed only
      # by a comment (`model:   # tbd`) kept `# tbd` as its value instead of being empty.
      sub(/\r$/, "", v); sub(/^model:/, "", v); sub(/[ \t]+#.*$/, "", v); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (v != "") { print v; found = 1 }
      exit
    }
    END { exit found ? 0 : 1 }' "$f"
}

# zrl_strip_bom_crlf — stdin to stdout: strip a leading UTF-8 BOM and every `\r`. The per-agent
# transforms in build-cursor-skills.sh, build-antigravity-skills.sh and build-kimi-skills.sh each
# read an agent file through their own awk, whose frontmatter boundary is `/^---$/` — a BOM or a
# CRLF line ending makes line 1 read as `\xef\xbb\xbf---` or `---\r`, neither of which is literally
# `---`, so the awk never recognizes the frontmatter at all and the WHOLE file (including its
# `model:` line) falls through unconverted. Piping every agent source through this ONCE, before
# that awk ever sees it, means the awk needs no `\r?` tolerance of its own and always emits LF-only
# output — one normalization instead of a `\r?` in every regex of three separate awk programs,
# which handled CRLF and never a BOM.
zrl_strip_bom_crlf() {
  LC_ALL=C sed $'1s/^\xef\xbb\xbf//' | LC_ALL=C tr -d '\r'
}

# zrl_agent_model_known <value> — the ONE frontmatter `model:` value grammar every non-Claude build
# accepts before it may resolve or ship an agent (each build used to carry its own byte-identical
# copy). Takes the value exactly as zrl_frontmatter_model hands it back — quotes
# kept, comment/CR/outer-blanks already gone — and does no further trimming itself, so a value
# still carrying whitespace or a CR the reader did NOT strip is refused here too, byte for byte.
#
# EXACT whole-value match only — no first-word truncation, no substring — checked against every
# real agent's frontmatter in skills/*/agents/*.md (44 `sonnet`, 2 `review-primary`, 2
# `review-alt`, one quoted descriptor):
#   haiku | sonnet | opus | review-primary | review-alt      — unquoted, byte-exact
#   "per-task: …" | 'per-task: …'                            — the ONE quoted shape accepted
#
# The per-task shape is quoted in the one real agent that uses it (execute/agents/implementer.md:
# `model: "per-task: sonnet for standard complexity, opus for complex"`) because YAML requires
# quoting a plain scalar that contains ": " (colon-space) — an unquoted `per-task: sonnet …` would
# not parse as this key's single value. Quoting anything else is refused — `"review-alt"` and
# `'sonnet'` both fail: a quoted lane or tier is never the value the
# router or a build writes, so accepting one here would silently take a malformed source file
# instead of failing it by name. `per-task` with no colon, `sonnet <anything else>`, and a
# decorated lane (`[review-alt]`, `x,review-alt`) all fail for the same reason: only the whole,
# exact value zuvo's own agents actually use is accepted, everything else fails by name.
#
# The per-task shape is checked STRICTLY (a prefix match alone would take a value with a smuggled
# second quote, `"per-task: x" y"`, or a route word used as a descriptor word,
# `"per-task: review-primary"`, as if they were the one real descriptor):
#   1. exactly ONE matching pair of outer quotes (both `"` or both `'`) — stripped once, and the
#      inner text must not contain that SAME quote character again anywhere. A genuine per-task
#      value never re-quotes itself; a second occurrence means the value is not what it claims —
#      `"per-task: x" y"` no longer reads as one YAML scalar at all.
#   2. what remains after the quotes starts with `per-task:` (the colon is mandatory — `per-task`
#      alone is refused).
#   3. no TOKEN of the text after `per-task:` — split on anything that is not an id character,
#      the SAME tokenizer the lenient scanner's names_lane() uses — is itself a router lane name
#      (zrl_is_route_word, case-insensitive). `"per-task: review-primary"` names a lane as if it
#      were prose describing a tier, which is exactly the shape a genuinely unresolved lane would
#      take if it hid inside a free-text descriptor; it fails here rather than shipping.
zrl_agent_model_known() {
  # IFS is local and blank-only: the token loop below splits on the blanks tr leaves, whatever IFS the
  # caller has (under IFS=, a descriptor's " review-primary" stayed one token and passed).
  local IFS=' ' value="${1:-}" quote inner rest token normalized
  case "$value" in
    haiku|sonnet|opus|review-primary|review-alt) return 0 ;;
  esac
  case "$value" in
    \"*\") quote='"' ;;
    \'*\') quote="'" ;;
    *) return 1 ;;
  esac
  # Strip exactly the one leading and one trailing character already confirmed to be the quote.
  inner="${value#?}"
  inner="${inner%?}"
  case "$inner" in
    *"$quote"*) return 1 ;;
  esac
  case "$inner" in
    per-task:*) ;;
    *) return 1 ;;
  esac
  rest="${inner#per-task:}"
  normalized="$(printf '%s' "$rest" | LC_ALL=C tr -c "$ZMS_ID_ALNUM._:-" ' ')"
  for token in $normalized; do
    [ -n "$token" ] || continue
    zrl_is_route_word "$token" && return 1
  done
  return 0
}

# ── the per-agent GATE every non-Claude build runs ──────────────────────────────────────────────────
# zrl_read_agent_model <file> — the STRICT READER over a BOM/CRLF-normalised copy of <file>: prints the
# model value; the status is zrl_frontmatter_model's (0 found, 1 none, 2 <file> unreadable), or 4 when
# the temp copy could not be made or written (no temp file, a full disk) — a fault of the build's
# environment, never reported as an unreadable agent. The copy exists because zrl_frontmatter_model
# tolerates a trailing CR but not a leading BOM (its contract, shared with install.sh), while an agent
# with either is still resolvable once normalised — the same normalisation the builds' per-agent
# transforms read through.
zrl_read_agent_model() {
  local f="${1:?zrl_read_agent_model: <file>}" tmp rc=0
  # <file> is opened for reading on its own first, so a failure of the copy below can only be the write.
  if [ ! -f "$f" ] || ! { : < "$f"; } 2>/dev/null; then return 2; fi
  tmp="$(mktemp)" || return 4
  if zrl_strip_bom_crlf < "$f" > "$tmp" 2>/dev/null; then
    zrl_frontmatter_model "$tmp" || rc=$?
  else
    rc=4
  fi
  rm -f "$tmp"
  return "$rc"
}

# zrl_agent_is_data_only <file> — status 0 when <file> looks like a data file kept beside the agents
# (a redirect stub, a template, a registry, column definitions, or no `description:` in its first 20
# lines). Only meaningful for a READABLE file with no readable model: head/grep read nothing from an
# unreadable one, which would look like "no description" (zrl_agent_gate checks both first).
zrl_agent_is_data_only() {
  local f="$1" is_redirect has_desc is_data
  is_redirect=$(head -5 "$f" | grep -ci "REDIRECT\|canonical.*moved" || true)
  has_desc=$(head -20 "$f" | grep -c "^description:" || true)
  is_data=$(head -5 "$f" | grep -ci "template\|registry\|column definitions" || true)
  [ "${is_redirect:-0}" -gt 0 ] || [ "${has_desc:-0}" -eq 0 ] || [ "${is_data:-0}" -gt 0 ]
}

# zrl_agent_gate <build-label> <agent-file> — whether a build may adapt this agent, decided the same way
# in all four non-Claude builds. The model is read ONCE (zrl_read_agent_model): a file whose frontmatter
# has a readable `model:` is an AGENT, whatever its description says (skills/content-expand/agents/
# prose-quality-scorer.md is a real agent whose description says "registry"); only a readable file with
# no readable model is tested as data-only. Status:
#   0   accepted — ZRL_AGENT_MODEL holds its value, one zrl_agent_model_known takes;
#   10  data-only — the caller skips it with its own message;
#   1   refused — the ERROR line, naming the file and <build-label>, is already on stdout (the build log,
#       in order); a temp copy that could not be made or written is reported on stderr, as that and not
#       as an unreadable agent.
# Each zrl_frontmatter_model status has its own message; a status outside its contract is reported by
# number, never folded into "no readable model:".
zrl_agent_gate() {
  local label="$1" f="$2" rc=0
  ZRL_AGENT_MODEL=""
  ZRL_AGENT_MODEL="$(zrl_read_agent_model "$f")" || rc=$?
  if [ "$rc" -eq 4 ]; then
    echo "  ERROR: could not make or write a temp copy of $f to read its \`model:\` (mktemp or the write failed — a full or missing temp dir?); the file itself is readable" >&2
    return 1
  fi
  if [ "$rc" -ne 0 ] && [ -r "$f" ] && zrl_agent_is_data_only "$f"; then
    return 10
  fi
  case "$rc" in
    0) ;;
    2) echo "  ERROR: $f could not be read for its \`model:\`"; return 1 ;;
    1) echo "  ERROR: $f has no readable \`model:\` (a column-0 key in a frontmatter that starts on line 1) — the $label build does not guess one"; return 1 ;;
    *) echo "  ERROR: $f: zrl_frontmatter_model returned an unexpected status ($rc) — the $label build does not guess what that means"; return 1 ;;
  esac
  if ! zrl_agent_model_known "$ZRL_AGENT_MODEL"; then
    echo "  ERROR: $f: model value '$ZRL_AGENT_MODEL' is not one the $label build accepts (haiku, sonnet, opus, review-primary, review-alt, or a quoted \"per-task: …\" descriptor)"
    return 1
  fi
}

# ── the lenient VALIDATORS ──────────────────────────────────────────────────────────────────────────
# One awk program, three modes: `md` (a model key inside the leading frontmatter block of a .md), `toml`
# (a model key on any line of a TOML), `value` (the TOML's model value, case kept). `md`/`toml` print
# FILENAME:FNR:line for each hit, and add `  [model value not parsed - failing closed]` to a line whose
# value they could not read. `value` exits 1 (no model key), 3 (more than one) or 4 (value not read).
# Run under LC_ALL=C: bytes, so the BOM test and tolower are exact. Only POSIX awk: verified identical
# under BWK awk (macOS), gawk and mawk.
ZRL_SCAN_AWK='
BEGIN {
  bom = "\357\273\277"
  NOKEY = "\001"
  n = split(words, w, " ")
  for (i = 1; i <= n; i++) lane[w[i]] = 1
  keyq = "[\"" sq "]?"
}
# model_value(line, sep) — the value of a model key, comment and outer blanks removed; NOKEY if none.
function model_value(line, sep,    v) {
  if (!match(tolower(line), "^[ \t]*" keyq "model" keyq "[ \t]*" sep)) return NOKEY
  v = substr(line, RLENGTH + 1)
  if (match(v, /(^|[ \t])#/)) v = substr(v, 1, RSTART - 1)
  sub(/^[ \t]+/, "", v)
  sub(/[ \t]+$/, "", v)
  return v
}
# unparsed(v) — 1 when a line scanner cannot read the value: empty, a block scalar, an unclosed quote,
# an unclosed triple-quoted string.
function unparsed(v,    q) {
  if (v == "") return 1
  if (v ~ /^[|>]/) return 1
  q = substr(v, 1, 3)
  if (q == "\"\"\"" || q == sq sq sq) return index(substr(v, 4), q) == 0
  q = substr(v, 1, 1)
  if (q == "\"" || q == sq) return index(substr(v, 2), q) == 0
  return 0
}
# names_lane(v) — 1 when ANY token of the value, split on every non-id character, is a route word.
function names_lane(v,    t, n, i) {
  n = split(tolower(v), t, /[^a-z0-9._:-]+/)
  for (i = 1; i <= n; i++) if (t[i] in lane) return 1
  return 0
}
FNR == 1 {
  state = (mode == "md") ? 0 : 1
  if (substr($0, 1, 3) == bom) $0 = substr($0, 4)
}
{ line = $0; sub(/\r$/, "", line) }
mode == "md" && state == 0 {
  if (line ~ /^[ \t]*$/) next
  state = (line ~ /^---[ \t]*$/) ? 1 : 2
  next
}
mode == "md" && state == 1 && line ~ /^(---|\.\.\.)[ \t]*$/ { state = 2; next }
mode == "value" {
  v = model_value(line, "=")
  if (v == NOKEY) next
  if (++keys == 1) {
    # A value it cannot parse (an unclosed quote, a multi-line string) is no value — exit 4 below —
    # never whatever its first token happens to be.
    first = unparsed(v) ? "" : v
    gsub(/"/, " ", first); gsub(sq, " ", first)
    sub(/^[ \t]+/, "", first)
    if (match(first, /^[^ \t]+/)) first = substr(first, 1, RLENGTH); else first = ""
  }
  next
}
state == 1 {
  v = model_value(line, (mode == "md") ? ":" : "=")
  if (v == NOKEY) next
  if (unparsed(v)) print FILENAME ":" FNR ":" $0 "  [model value not parsed - failing closed]"
  else if (names_lane(v)) print FILENAME ":" FNR ":" $0
}
END {
  if (mode == "value") {
    if (keys == 0) exit 1
    if (keys > 1) exit 3
    if (first == "") exit 4
    print first
  }
}
'

# _zrl_awk <mode> <file>… — the program above, byte-exact.
_zrl_awk() {
  local mode="$1"
  shift
  LC_ALL=C awk -v mode="$mode" -v sq="'" -v words="$ZRL_ROUTE_WORDS" "$ZRL_SCAN_AWK" "$@"
}

# _zrl_paths_exist <path>… — every path exists (a file, a directory, or a link to one); else say which.
_zrl_paths_exist() {
  local p
  for p in "$@"; do
    if [ ! -e "$p" ]; then
      echo "reviewer lanes: scan path missing: $p" >&2
      return 1
    fi
  done
}

# zrl_links_inside <path>… — every symlink under each DIRECTORY path (walked without following links)
# must resolve to something that exists INSIDE that path, and a directory link must not point at its own
# directory or an ancestor of it (a cycle, which GNU find reports and macOS find silently skips). Each
# offender is named on stderr; status 1 when there is one. Perl (already the rewriter's dependency):
# File::Find to walk, Cwd::abs_path to resolve the whole chain of links.
ZRL_LINKS_PL='
use strict; use warnings; use File::Find; use Cwd qw(abs_path);
my $bad = 0;
for my $root (@ARGV) {
  next unless -d $root;
  my $real = abs_path($root);
  find({ no_chdir => 1, wanted => sub {
    my $link = $File::Find::name;
    return unless -l $link;
    my $t = abs_path($link);
    if (!defined $t || !-e $t) {
      print STDERR "reviewer lanes: symlink $link does not resolve\n"; $bad = 1; return;
    }
    if ($t ne $real && index($t, "$real/") != 0) {
      print STDERR "reviewer lanes: symlink $link points outside $root ($t)\n"; $bad = 1; return;
    }
    if (-d $t) {
      (my $dir = $link) =~ s{/[^/]*$}{};
      my $rdir = abs_path($dir);
      if (defined $rdir && index("$rdir/", "$t/") == 0) {
        print STDERR "reviewer lanes: symlink $link is a cycle (it points at $t, its own directory or an ancestor)\n";
        $bad = 1;
      }
    }
  } }, $root);
}
exit $bad;
'
zrl_links_inside() {
  perl -e "$ZRL_LINKS_PL" -- "$@"
}

# zrl_scan_md <path>… — every .md under the paths (files or directories, recursively, links followed
# inside them): print FILENAME:LINE:TEXT for each frontmatter model key naming a route word, or one it
# cannot read. Status 0 when the scan ran (hits or not); 2 when it did not: no path, a missing path, a
# symlink out of the tree / nowhere / in a cycle, a walk find could not finish (an unreadable directory),
# no .md file at all (the caller expected some), or a file it could not read. ONE find run lists the
# files — its own status checked, never read as "no files" — and awk reads them through xargs; a subshell,
# so the list's temp file is always removed.
zrl_scan_md() (
  list=""
  trap 'if [ -n "$list" ]; then rm -f -- "$list"; fi' EXIT
  if [ "$#" -eq 0 ]; then
    echo "reviewer lanes: nothing to scan (no path given)" >&2
    exit 2
  fi
  _zrl_paths_exist "$@" || exit 2
  if ! zrl_links_inside "$@"; then
    echo "reviewer lanes: the scan of [$*] refuses the symlinks named above" >&2
    exit 2
  fi
  list="$(mktemp "${TMPDIR:-/tmp}/zrl-scan.XXXXXX")" || { list=""; echo "reviewer lanes: no temp file for the scan list" >&2; exit 2; }
  if ! find -L "$@" -type f -name '*.md' -print0 > "$list"; then
    echo "reviewer lanes: find could not walk [$*] (its error is above)" >&2
    exit 2
  fi
  if [ ! -s "$list" ]; then
    echo "reviewer lanes: no .md file under [$*] to scan" >&2
    exit 2
  fi
  if ! xargs -0 env LC_ALL=C awk -v mode=md -v sq="'" -v words="$ZRL_ROUTE_WORDS" "$ZRL_SCAN_AWK" < "$list"; then
    echo "reviewer lanes: the scan of [$*] did not complete" >&2
    exit 2
  fi
)

# zrl_scan_toml <file>… — the same for TOML model keys (`model = "…"` in any quoting and spacing).
# Status 0 when it ran, 2 when there was nothing to scan, a path is missing, or a file could not be read.
zrl_scan_toml() {
  if [ "$#" -eq 0 ]; then
    echo "reviewer lanes: no TOML to scan" >&2
    return 2
  fi
  _zrl_paths_exist "$@" || return 2
  if ! _zrl_awk toml "$@"; then
    echo "reviewer lanes: the TOML scan did not complete" >&2
    return 2
  fi
}

# zrl_toml_model <file> — print the TOML's model value (quotes and spacing dropped, case kept). Status 1
# when it has no model key, 3 when it has more than one (duplicate keys are invalid TOML — never "the
# first one wins"), 4 when the value could not be read.
zrl_toml_model() {
  local rc=0 out
  out="$(_zrl_awk value "${1:?zrl_toml_model: <file>}")" || rc=$?
  case "$rc" in
    0) printf '%s\n' "$out" ;;
    1) echo "reviewer lanes: $1 has no model key" >&2 ;;
    3) echo "reviewer lanes: $1 has more than one model key (duplicate keys are invalid TOML)" >&2 ;;
    4) echo "reviewer lanes: $1 has a model value that could not be read" >&2 ;;
    *) echo "reviewer lanes: $1 could not be read" >&2 ;;
  esac
  return "$rc"
}

# zrl_count_refs <refs> — how many scan hits (non-empty lines) <refs> holds.
zrl_count_refs() {
  printf '%s\n' "${1:-}" | awk 'NF { n++ } END { print n + 0 }'
}

# zrl_show_refs <refs> [indent] — print scan hits, at most 20 of them, and how many more there were.
zrl_show_refs() {
  local n
  n=$(($(printf '%s\n' "${1:-}" | wc -l)))
  printf '%s\n' "${1:-}" | head -n 20 | sed "s/^/${2:-}/"
  if [ "$n" -gt 20 ]; then
    echo "${2:-}… and $((n - 20)) more"
  fi
}

# zrl_scan_and_report_lanes <platform-label> <path>… — the leftover-lane scan of a dist's markdown
# (zrl_scan_md) and its report, ONE implementation for all four non-Claude builds, so they report in
# one wording. zrl_scan_and_report_toml_lanes <platform-label> <toml>… — the same for agent TOMLs
# (zrl_scan_toml; the Codex build). Both run _zrl_scan_report in a SUBSHELL: its temp files and traps
# are its own, set up after entering it, so they never touch the caller script's own traps.
#
# Prints its ERROR lines to stdout as it goes (the caller's own stdout, so they land in the build log
# in order) and returns the number of errors found as its exit status: a leftover-lane hit counts once
# PER REFERENCE, plus one more when the scan wrote to stderr on an otherwise successful run (stderr
# from the scan is its own failure path, never a warning), and a scan that did not complete is 1 —
# capped at 200 so a pathological dist cannot wrap the status around into a smaller, wrong count. A
# HUP/INT/TERM ends it with 129/130/143 — never with the count it had so far, which could be 0. THE
# CALLER MUST NOT run it as a bare statement under `set -e` (a non-zero status would abort the script);
# capture it with `|| n=$?` and add the result to its own error counter:
#   n=0; zrl_scan_and_report_lanes Cursor "$DIST/skills" "$DIST/rules" || n=$?; errors=$((errors + n))
zrl_scan_and_report_lanes() {
  local platform="$1"
  shift
  _zrl_scan_report "$platform" zrl_scan_md "" "a frontmatter model key" "$@"
}
zrl_scan_and_report_toml_lanes() {
  local platform="$1"
  shift
  _zrl_scan_report "$platform" zrl_scan_toml " (agent TOMLs)" "an agent TOML model key" "$@"
}

# _zrl_scan_report <platform-label> <scanner> <scope-note> <where> <path>… — see above.
_zrl_scan_report() (
  platform="$1" scanner="$2" scope="$3" where="$4" lane_out="" lane_err="" n=0
  shift 4
  trap 'rm -f "$lane_out" "$lane_err"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  lane_out="$(mktemp)" || { lane_out=""; echo "  ERROR: could not create a temp file for the reviewer-lane scan" >&2; exit 1; }
  lane_err="$(mktemp)" || { lane_err=""; echo "  ERROR: could not create a temp file for the reviewer-lane scan" >&2; exit 1; }
  if "$scanner" "$@" >"$lane_out" 2>"$lane_err"; then
    if [ -s "$lane_out" ]; then
      lane_refs="$(cat "$lane_out")"
      # N leftover references are N errors, not one: the tally shows how widespread the problem is.
      n=$((n + $(zrl_count_refs "$lane_refs")))
      echo "  ERROR: Abstract reviewer lanes remain in $platform dist$scope ($(zrl_count_refs "$lane_refs") leftover reference(s) — a route word, or an unparsable value, in $where):"
      zrl_show_refs "$lane_refs" "    "
    fi
    if [ -s "$lane_err" ]; then
      echo "  ERROR: the reviewer-lane scan wrote to stderr on an otherwise successful run:"
      sed 's/^/    /' "$lane_err"
      n=$((n + 1))
    fi
  else
    echo "  ERROR: could not scan the $platform dist for unresolved reviewer lanes$scope:"
    sed 's/^/    /' "$lane_err"
    if [ -s "$lane_out" ]; then
      echo "    lanes it had found before the scan stopped:"
      sed 's/^/      /' "$lane_out"
    fi
    n=1
  fi
  [ "$n" -gt 200 ] && n=200
  exit "$n"
)
