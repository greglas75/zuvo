#!/usr/bin/env bash
# scripts/lib/reviewer-lanes.sh — the reviewer-LANE grammar, kept in ONE place (plan C Task 3).
#
# `review-primary` and `review-alt` are the router's lane names (reviewer-model-route.sh answers
# `reviewer_lane=…`), and the documents that consume the router quote them, together with
# `cross-vendor`, `in-family-fallback`, `same-model-fallback` and `routing-failed`, to say what to do
# with an answer. Only an AGENT's frontmatter `model:` names a lane as a model, and only there may an
# install or a build turn it into one. Sourced by scripts/install.sh (the Claude cache) and by all four
# dist builds (scripts/build-{codex,cursor,antigravity,kimi}-skills.sh), from beside themselves; the
# Cursor, Antigravity and Kimi builds also share its per-agent model gate (zrl_read_agent_model,
# zrl_check_agent_model). It uses nothing from portable.sh.
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

# The router's route vocabulary (the `reviewer-route` enum in shared/includes/session-state.md). None of
# these is a model; the first two are the only ones an install or a build may resolve to one.
ZRL_ROUTE_WORDS="review-primary review-alt cross-vendor in-family-fallback same-model-fallback routing-failed"

# The router's grammar (zms_is_model_id in model-subprocess.sh), character for character: one plain token, starting
# with a letter or digit, then letters, digits, `.`, `_`, `:` or `-`. The letters are spelled out rather
# than written as a range, which a bash 3.2 case pattern resolves by locale collation.
ZRL_ID_ALNUM='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'

# zrl_is_model_id <value> — status 0 when <value> is one model id.
zrl_is_model_id() {
  case "${1:-}" in
    ""|[!$ZRL_ID_ALNUM]*|*[!$ZRL_ID_ALNUM._:-]*) return 1 ;;
  esac
  return 0
}

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
      sub(/\r$/, "", v); sub(/^model:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v)
      if (v != "") { print v; found = 1 }
      exit
    }
    END { exit found ? 0 : 1 }' "$f"
}

# zrl_strip_bom_crlf — stdin to stdout: strip a leading UTF-8 BOM and every `\r` (plan C Task 4
# fix round 3, A3). The per-agent transforms in build-cursor-skills.sh, build-antigravity-skills.sh
# and build-kimi-skills.sh each read an agent file through their own awk, whose frontmatter
# boundary is `/^---$/` — a BOM or a CRLF line ending makes line 1 read as `\xef\xbb\xbf---` or
# `---\r`, neither of which is literally `---`, so the awk never recognizes the frontmatter at all
# and the WHOLE file (including its `model:` line) falls through unconverted. Piping every agent
# source through this ONCE, before that awk ever sees it, means the awk needs no `\r?` tolerance
# of its own and always emits LF-only output — one normalization instead of a `\r?` scattered
# through three separate regex sets (round 2's fix, which this replaces).
zrl_strip_bom_crlf() {
  LC_ALL=C sed $'1s/^\xef\xbb\xbf//' | LC_ALL=C tr -d '\r'
}

# zrl_agent_model_known <value> — plan C Task 4 fix round 2 (G1/E1): the ONE frontmatter `model:`
# value grammar every non-Claude build accepts before it may resolve or ship an agent, replacing
# three byte-identical `agent_model_known_{cursor,antigravity,kimi}` copies (CQ14/CQ20 in the
# round-1 quality review). Takes the value exactly as zrl_frontmatter_model hands it back — quotes
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
# `'sonnet'` both fail, matching Task 3's P9 rule that a quoted lane or tier is never the value the
# router or a build writes, so accepting one here would silently take a malformed source file
# instead of failing it by name. `per-task` with no colon, `sonnet <anything else>`, and a
# decorated lane (`[review-alt]`, `x,review-alt`) all fail for the same reason: only the whole,
# exact value zuvo's own agents actually use is accepted, everything else fails by name.
#
# The per-task shape is checked STRICTLY (fix round 3, A6 — a first cut accepted any prefix match,
# which took a value with a smuggled second quote, `"per-task: x" y"`, or a route word used as a
# descriptor word, `"per-task: review-primary"`, as if they were the one real descriptor):
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
  local value="${1:-}" quote inner rest token normalized IFS=' '   # word-split below, whatever IFS the caller has
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
  normalized="$(printf '%s' "$rest" | LC_ALL=C tr -c "$ZRL_ID_ALNUM._:-" ' ')"
  for token in $normalized; do
    [ -n "$token" ] || continue
    zrl_is_route_word "$token" && return 1
  done
  return 0
}

# ── the per-agent model gate the Cursor, Antigravity and Kimi builds share ─────────────────────────
# These three builds used to carry the same ~40-line block each (read, then classify and report) and
# the same 17-line library guard; only the platform name differed. One copy lives here now, so a fix
# to the reader's contract lands in all three builds at once. The data-only skip stays in each build,
# BETWEEN the two calls below: it needs the read's status, and whether a file is data or an agent is
# the build's question, not the grammar's.

# zrl_read_agent_model <agent> — the agent's `model:` through the STRICT READER, read from a
# BOM/CRLF-normalized COPY (zrl_frontmatter_model tolerates a trailing CR but not a leading BOM — its
# contract, shared with install.sh and the Codex build, is left as it is). A file whose leading
# frontmatter has a READABLE model: is an agent regardless of what its description says, so callers
# read ONCE, before any data-only heuristic, and use the result for both.
# Prints the value on success. Status: zrl_frontmatter_model's own (0 read, 1 no/empty model key,
# 2 unreadable — also when $agent itself cannot be opened, the same status its [ ! -r ] check gives),
# or 3 when no temp file could be created. Nothing is printed on a non-zero status.
zrl_read_agent_model() {
  local agent="$1" tmp value rc=0
  tmp="$(mktemp)" || return 3
  if zrl_strip_bom_crlf < "$agent" > "$tmp" 2>/dev/null; then
    value=$(zrl_frontmatter_model "$tmp") || rc=$?
  else
    rc=2
  fi
  rm -f "$tmp"
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s\n' "$value"
}

# zrl_check_agent_model <platform> <agent> <read-status> <value> — 0 when the build can use this
# agent's model; otherwise prints the ERROR line naming <agent> and returns 1. Every read status gets
# its own message: 2 unreadable, 1 no model key or an empty one, 3 no temp file; a status outside that
# contract is reported by number rather than folded into "no readable model:", so a future change to
# the reader cannot be silently misdiagnosed. A read value that zrl_agent_model_known refuses is named.
zrl_check_agent_model() {
  local platform="$1" agent="$2" rc="$3" value="${4:-}"
  case "$rc" in
    0) ;;
    1) echo "  ERROR: $agent has no readable \`model:\` (a column-0 key in a frontmatter that starts on line 1) — the $platform build does not guess one"; return 1 ;;
    2) echo "  ERROR: $agent could not be read for its \`model:\`"; return 1 ;;
    3) echo "  ERROR: could not create a temp file to read $agent" >&2; return 1 ;;
    *) echo "  ERROR: $agent: zrl_frontmatter_model returned an unexpected status ($rc) — the $platform build does not guess what that means"; return 1 ;;
  esac
  if ! zrl_agent_model_known "$value"; then
    echo "  ERROR: $agent: model value '$value' is not one the $platform build accepts (haiku, sonnet, opus, review-primary, review-alt, or a quoted \"per-task: …\" descriptor)"
    return 1
  fi
}

# zrl_require_functions <lib-path> <fn>… — after sourcing this library, confirm it defined what the
# caller uses; a truncated or renamed library then fails loudly at load, not with a confusing
# "command not found" mid-build. declare -F, not `command -v`: command -v also matches a PATH binary
# or an alias of the same name, so a broken library plus a coincidental PATH entry would pass.
# The CALLER must first check that this function itself exists (it is part of what may be missing).
zrl_require_functions() {
  local lib="$1" fn
  shift
  for fn in "$@"; do
    if ! declare -F "$fn" >/dev/null 2>&1; then
      echo "ERROR: $fn is not defined after sourcing $lib — the library is missing or incomplete" >&2
      return 1
    fi
  done
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
# Only `---` closes it, as in the strict rewriter — NOT the YAML document-end marker `...`: a scanner that stopped earlier
# than the rewriter would miss a `model:` between the two that the harness still reads as frontmatter.
mode == "md" && state == 1 && line ~ /^---[ \t]*$/ { state = 2; next }
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
  # Without perl nothing was walked: say THAT, rather than let callers report "the symlinks named
  # above" when none were named. Still status 1 — an unchecked tree is not a clean one.
  if ! command -v perl >/dev/null 2>&1; then
    echo "  ✗ perl not found — the symlink containment check could not run (it walks the tree with perl)" >&2
    return 1
  fi
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

# zrl_scan_and_report_lanes <platform-label> <path>… — plan C Task 4 fix round 3 (A4/W12): the
# scan-and-report block every non-Claude build ran inline, now ONE shared implementation instead
# of three near-identical copies that had drifted to slightly different wording (W12: the tests
# assert ONE wording, here). Runs the scan capture in a SUBSHELL (A4): the temp files and their
# cleanup trap are entirely local to it, created AFTER entering the subshell and setting the trap,
# so they never touch the caller script's own EXIT/INT/TERM trap (or get clobbered by one the
# caller sets later, or leak past a caller trap that replaces its own before this returns).
#
# Prints its ERROR lines to stdout as it goes (the caller's own stdout, so they land in the build
# log in order) and returns the number of errors found as its exit status: a leftover-lane hit
# counts once PER REFERENCE (fix round 3, A10 — cheap here, since zrl_count_refs already computes
# that number for the message itself) plus one more for an unexpected-stderr hit (fix round 3, A2:
# stderr on an otherwise successful scan fails closed, it is never a warning — zrl_scan_md writes
# to stderr only on its own failure paths) — independent, and can both fire in the same successful
# scan — capped at 200 so a pathological dist cannot wrap the exit status around into a smaller,
# wrong count. THE CALLER MUST NOT run this as a bare statement under `set -e` (a non-zero status
# would abort the script); capture it with `|| n=$?` and add the result to its own error counter:
#   n=0; zrl_scan_and_report_lanes Cursor "$DIST/skills" "$DIST/rules" || n=$?; errors=$((errors + n))
zrl_scan_and_report_lanes() (
  local platform="$1" lane_out lane_err lane_refs n=0
  shift
  lane_out="$(mktemp)" || { echo "  ERROR: could not create a temp file for the reviewer-lane scan" >&2; exit 1; }
  lane_err="$(mktemp)" || { rm -f "$lane_out"; echo "  ERROR: could not create a temp file for the reviewer-lane scan" >&2; exit 1; }
  # EXIT cleans up; INT/TERM must also END the subshell (as in zrl_rewrite_lanes_file) — a trap that
  # only removed the files let a signalled scan carry on and report a clean pass on nothing.
  trap 'rm -f "$lane_out" "$lane_err"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if zrl_scan_md "$@" >"$lane_out" 2>"$lane_err"; then
    if [ -s "$lane_out" ]; then
      lane_refs="$(cat "$lane_out")"
      # Count per offending INSTANCE, not per category (fix round 3, A10 -- cheap here since
      # zrl_count_refs already computes this number for the message itself): N leftover
      # references is N errors, not one, so the caller's error tally reflects how widespread the
      # problem is, not just that it exists.
      n=$((n + $(zrl_count_refs "$lane_refs")))
      echo "  ERROR: Abstract reviewer lanes remain in $platform dist ($(zrl_count_refs "$lane_refs") leftover reference(s) — a route word, or an unparsable value, in a frontmatter model key):"
      zrl_show_refs "$lane_refs" "    "
    fi
    if [ -s "$lane_err" ]; then
      echo "  ERROR: the reviewer-lane scan wrote to stderr on an otherwise successful run:"
      sed 's/^/    /' "$lane_err"
      n=$((n + 1))
    fi
  else
    echo "  ERROR: could not scan the $platform dist for unresolved reviewer lanes:"
    sed 's/^/    /' "$lane_err"
    if [ -s "$lane_out" ]; then
      echo "    lanes it had found before the scan stopped:"
      sed 's/^/      /' "$lane_out"
    fi
    n=1
  fi
  # Exit status carries the count back to the caller (see the header comment) -- capped well under
  # 256 so a pathological dist cannot wrap the count around into a smaller, wrong one.
  [ "$n" -gt 200 ] && n=200
  exit "$n"
)
