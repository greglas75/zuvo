#!/usr/bin/env bats
# reviewer-model-builds.bats — the reviewer lanes, the model tiers and test-audit's dispatch calls in the
# Claude cache and in the four built dists (Codex, Cursor, Antigravity, Kimi).
#
# Test level: MEDIUM — real builds (scripts/build-*-skills.sh through tests/lib/dist-build.sh) of this
# tree and of fixture trees into a per-file temp dist root, and the real router as a subprocess. No
# install into a real HOME, no model call.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

# PER-FILE dist root (B-DIST-BUILD-RACE). The wipe below is necessary — every assertion must run
# against files THIS test's build materialized, never a tree left by a sibling — but wiping the
# SHARED $REPO_ROOT/dist is what made it a race: test-install-wiring.sh and test-kimi-build.sh
# build into the same tree, so this setup() could truncate a directory another file was asserting
# against. Red about twice in ten suite runs, and it produced two wrong conclusions in one session
# (a bisect that blamed an innocent registry change, and a "regression" that was not one) — both
# only caught by re-running in a git worktree with its own dist/.
#
# The builders now honour ZUVO_DIST_ROOT, so this file gets its own directory and the wipe touches
# nothing anyone else can see. Unset elsewhere, the default is the historical $REPO_ROOT/dist.
setup_file() {
  # TWO variables on purpose. ZUVO_DIST_SANDBOX is the directory this file created and is the ONLY
  # thing teardown removes; ZUVO_DIST_ROOT is where the builders write, INSIDE it.
  #
  # The first cut kept only ZUVO_DIST_ROOT and cleaned up with `rm -rf "$(dirname "$ZUVO_DIST_ROOT")"`.
  # That is a delete target computed by walking UP from a variable, and on 2026-08-18 a probe set
  # ZUVO_DIST_ROOT="$REPO_ROOT/dist" — so dirname was the repository, and teardown_file DELETED THE
  # WHOLE CHECKOUT, .git included. Recovered from an APFS local snapshot. Never derive an `rm -rf`
  # target with dirname; delete the exact path you created, and verify it is the one you created.
  ZUVO_DIST_SANDBOX="$(mktemp -d)"
  # A failed mktemp leaves this empty, which makes ZUVO_DIST_ROOT="/dist" — an absolute path the
  # builders would create and the setup() wipe would target. In a file whose teardown has already
  # destroyed this repository once, an unchecked mktemp is not a style point.
  [ -n "$ZUVO_DIST_SANDBOX" ] && [ -d "$ZUVO_DIST_SANDBOX" ] || {
    echo "setup_file: mktemp -d failed — refusing to run with an unset sandbox" >&2
    return 1
  }
  ZUVO_DIST_ROOT="$ZUVO_DIST_SANDBOX/dist"
  export ZUVO_DIST_SANDBOX ZUVO_DIST_ROOT
  # Every test here rebuilds into the ONE $ZUVO_DIST_ROOT (setup() wipes the four platform dirs):
  # the tests must never run concurrently. bats runs a file's tests sequentially unless invoked
  # with --jobs >1 (tests/run-all.sh does not); this keeps it so even under --jobs.
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
  mkdir -p "$ZUVO_DIST_ROOT"
}

teardown_file() {
  # Belt and braces on the guard above: remove it only if it still looks like the mktemp directory
  # this file made. A cleanup that cannot prove what it is deleting does not run.
  # The `$TMPDIR` arm is GONE, and its absence is the whole point. Written as
  #     /tmp/*|/var/folders/*|"${TMPDIR%/}"/*
  # an UNSET TMPDIR makes the third pattern `/*`, which matches every absolute path — so the guard
  # written specifically to stop this teardown deleting the repository would have permitted exactly
  # that. Verified: with `env -u TMPDIR`, ZUVO_DIST_SANDBOX=<repo root> MATCHED. Found by the
  # adversarial pass over the commit that added the guard, hours after the unguarded version had
  # already destroyed this checkout once.
  #
  # A guard whose safety depends on an environment variable being set is not a guard. These two
  # literal prefixes are where `mktemp -d` puts things on macOS and Linux; anything else is refused
  # out loud rather than removed.
  case "${ZUVO_DIST_SANDBOX:-}" in
    /tmp/*|/var/folders/*) [ -d "$ZUVO_DIST_SANDBOX" ] && rm -rf "$ZUVO_DIST_SANDBOX" ;;
    *) echo "teardown_file: refusing to remove unexpected sandbox '${ZUVO_DIST_SANDBOX:-}'" >&2 ;;
  esac
}

setup() {
  rm -rf "$ZUVO_DIST_ROOT/codex" "$ZUVO_DIST_ROOT/cursor" "$ZUVO_DIST_ROOT/antigravity" "$ZUVO_DIST_ROOT/kimi"
}

# ── The two guards above, FORCED ────────────────────────────────────────────────────────────────
# Both exist because of the 2026-08-18 whole-checkout deletion, and neither ran on a normal suite
# run: mktemp always succeeds and the sandbox always sits under a mktemp prefix. The cases at the
# end of this file drive them with the inputs they exist for. Each call runs inside bats' `run`
# subshell, so the file-level sandbox that teardown_file removes for real is never touched.
#
# The probe for "an existing directory outside /tmp and /var/folders" has to live somewhere real
# and absolute: a mktemp dir under the checkout's gitignored .zuvo/ (physical path — a checkout
# reached through /tmp → /private/tmp is still outside the literal prefixes). It is removed by
# teardown() below, which deletes only a path of exactly that shape.
GUARD_PROBE=""
GUARD_PARENT_CREATED=""
guard_parent() { printf '%s/.zuvo' "$(cd "$REPO_ROOT" && pwd -P)"; }
make_guard_probe() {
  local parent
  parent="$(guard_parent)"
  if [ ! -d "$parent" ]; then mkdir "$parent" && GUARD_PARENT_CREATED="$parent"; fi
  GUARD_PROBE="$(mktemp -d "$parent/guard-probe.XXXXXX")"
  if [ -z "$GUARD_PROBE" ] || [ ! -d "$GUARD_PROBE" ]; then
    echo "make_guard_probe: mktemp -d under $parent failed" >&2
    return 1
  fi
  case "$GUARD_PROBE" in
    /tmp/*|/var/folders/*) skip "this checkout lives under a mktemp prefix ($GUARD_PROBE): no outside path to probe with" ;;
  esac
  echo keep > "$GUARD_PROBE/sentinel"
}
teardown() {
  case "${GUARD_PROBE:-}" in
    "$(guard_parent)"/guard-probe.?*) rm -rf -- "$GUARD_PROBE" ;;
  esac
  if [ -n "${GUARD_PARENT_CREATED:-}" ]; then rmdir -- "$GUARD_PARENT_CREATED" 2>/dev/null || true; fi
  GUARD_PROBE=""; GUARD_PARENT_CREATED=""
  # A stub PATH a test exported for claude_materialize must never reach the next test.
  unset ZT_STUB_PATH
  # A directory a test made unreadable is readable again, so bats can remove its temp dir.
  if [ -n "${ZT_UNREADABLE:-}" ]; then chmod 755 "$ZT_UNREADABLE" 2>/dev/null || true; fi
  unset ZT_UNREADABLE
}
# output_has <text> — a failing assertion that prints what it looked at ([[ ]] alone is not an
# errexit trigger on every bash bats may run under).
output_has() {
  case "$output" in *"$1"*) return 0 ;; esac
  printf 'expected output to contain: %s\nactual output: %s\n' "$1" "$output" >&2
  return 1
}
output_lacks() {
  case "$output" in *"$1"*) printf 'output must not contain: %s\nactual output: %s\n' "$1" "$output" >&2; return 1 ;; esac
  return 0
}
# assert_line_order <marker1> <marker2> [...] — each marker's FIRST matching line in $output must
# come strictly AFTER the previous marker's line (an awk positional check on line number, not
# output_has's substring presence). Proves SECTION PLACEMENT: that the scan's stderr diagnostic
# prints under the "could not scan" part, before the "lanes it had found" heading, and that a hit
# prints after that heading — not merely that all three strings occur somewhere (fix round 4,
# Q11 TM4 variant: `2>"$lane_err"` mutated to `2>&1` in zrl_scan_and_report_lanes still prints every
# substring output_has checks for, because the merged stream still contains the diagnostic and the
# hit text; only their ORDER relative to the heading changes, which only a positional check catches).
assert_line_order() {
  local prev_ln=0 prev_marker="" marker ln
  for marker in "$@"; do
    ln=$(printf '%s\n' "$output" | awk -v m="$marker" 'index($0,m){print NR; exit}')
    if [ -z "$ln" ]; then
      printf 'assert_line_order: marker not found in output: [%s]\nactual output: %s\n' "$marker" "$output" >&2
      return 1
    fi
    if [ "$prev_ln" -ne 0 ] && [ "$ln" -le "$prev_ln" ]; then
      printf 'assert_line_order: [%s] at line %s did not come strictly after [%s] at line %s\nactual output: %s\n' \
        "$marker" "$ln" "$prev_marker" "$prev_ln" "$output" >&2
      return 1
    fi
    prev_ln=$ln
    prev_marker=$marker
  done
  return 0
}

# ── Lane words: materialised in agent FRONTMATTER only (plan C Task 3) ──────────────────────────
# `review-primary` / `review-alt` / `cross-vendor` are the ROUTER's lane names, and the router's
# consumers (these five documents) quote them to say what to do with the router's answer. Only an
# agent's frontmatter `model:` names a lane as a MODEL, and only there may an install or a build turn
# it into one. Rewriting them everywhere made every installed copy of these documents disagree with
# the router it documents (`reviewer_lane=review-alt` in the answer, `sonnet` in the doc).
LANE_DOCS="shared/includes/test-reviewer-routing.md shared/includes/env-compat.md shared/includes/session-state.md skills/execute/SKILL.md skills/retro/SKILL.md"
LANE_WORDS="review-primary review-alt cross-vendor"

# frontmatter_model <file> — the value of `model:` inside the file's LEADING `---` block, nothing else.
frontmatter_model() {
  awk 'NR == 1 { if ($0 !~ /^---\r?$/) exit; fm = 1; next }
       fm && /^---\r?$/ { exit }
       fm && /^model:/ { sub(/^model:[ \t]*/, ""); sub(/\r$/, ""); print; exit }' "$1"
}
# model_is <file> <want> — a failing assertion that names the file and what it found.
model_is() {
  local got
  got="$(frontmatter_model "$1")"
  [ "$got" = "$2" ] && return 0
  printf 'frontmatter model of %s: expected [%s], got [%s]\n' "$1" "$2" "$got" >&2
  return 1
}
# frontmatter_model_preference <file> — the value of `model_preference:` inside the file's LEADING
# `---` block (fix round 2, F9: Kimi's OWN key, read through the frontmatter boundary the way
# frontmatter_model reads `model:` — never a bare `rg` over the whole file, which cannot tell a
# real frontmatter key from a word appearing later in the body).
frontmatter_model_preference() {
  awk 'NR == 1 { if ($0 !~ /^---\r?$/) exit; fm = 1; next }
       fm && /^---\r?$/ { exit }
       fm && /^model_preference:/ { sub(/^model_preference:[ \t]*/, ""); sub(/\r$/, ""); print; exit }' "$1"
}
# model_preference_is <file> <want> — a failing assertion that names the file and what it found.
model_preference_is() {
  local got
  got="$(frontmatter_model_preference "$1")"
  [ "$got" = "$2" ] && return 0
  printf 'frontmatter model_preference of %s: expected [%s], got [%s]\n' "$1" "$2" "$got" >&2
  return 1
}
# docs_keep_lane_words <tree> — each of LANE_DOCS under <tree> still carries each of LANE_WORDS.
docs_keep_lane_words() {
  local doc word
  for doc in $LANE_DOCS; do
    [ -f "$1/$doc" ] || { printf 'missing from %s: %s\n' "$1" "$doc" >&2; return 1; }
    for word in $LANE_WORDS; do
      rg -q -F -- "$word" "$1/$doc" || { printf '%s lost the router word %s in %s\n' "$doc" "$word" "$1" >&2; return 1; }
    done
  done
}
# lane_word_count <file> — total occurrences of the three LANE_WORDS in <file> (0 if missing).
lane_word_count() {
  [ -f "$1" ] || { echo 0; return; }
  rg -c -F -e review-primary -e review-alt -e cross-vendor "$1" 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}'
}
# lane_word_count_unchanged <source-file> <dist-file> — a failing assertion (fix round 3, W11):
# the dist copy carries the SAME NUMBER of router lane words as the source, not just "at least
# one" — a build that dropped or duplicated some would still pass a bare presence check.
lane_word_count_unchanged() {
  local src_n dst_n
  src_n=$(lane_word_count "$1")
  dst_n=$(lane_word_count "$2")
  [ "$src_n" = "$dst_n" ] && [ "$src_n" -gt 0 ] && return 0
  printf 'lane word count changed: %s has %s, %s has %s\n' "$1" "$src_n" "$2" "$dst_n" >&2
  return 1
}
# lane_tomls_hold <dist-root> <primary-id> <alt-id> — every SOURCE agent whose frontmatter names a lane
# has a Codex TOML (found by the instructions path it points at, not by re-deriving the build's name
# prefixes) holding that lane's id. Both lanes must be seen, so an agent rename cannot make it vacuous.
lane_tomls_hold() {
  local md lane want skill name toml seen_primary=0 seen_alt=0
  # Two ids, each one non-empty token: an empty or blank-split argument cannot pass as "the registry's".
  [ "$#" -eq 3 ] && [ -n "$2" ] && [ -n "$3" ] && [ "$2" = "${2%%[[:space:]]*}" ] && [ "$3" = "${3%%[[:space:]]*}" ] \
    || { printf 'lane_tomls_hold: expected <root> <primary> <alt>, got [%s]\n' "$*" >&2; return 1; }
  for md in "$REPO_ROOT"/skills/*/agents/*.md; do
    lane="$(frontmatter_model "$md")"
    case "$lane" in
      review-primary) want="$2"; seen_primary=1 ;;
      review-alt)     want="$3"; seen_alt=1 ;;
      *) continue ;;
    esac
    skill="$(basename "$(dirname "$(dirname "$md")")")"
    name="$(basename "$md" .md)"
    toml="$(rg -l -F -x -- "Read your full instructions at ~/.codex/skills/$skill/agents/$name.md" "$1/codex/agents" || true)"
    [ -n "$toml" ] && [ "$(printf '%s\n' "$toml" | wc -l | tr -d ' ')" -eq 1 ] \
      || { printf 'expected exactly one TOML for %s/%s, got [%s]\n' "$skill" "$name" "$toml" >&2; return 1; }
    rg -q -F -x -- "model = \"$want\"" "$toml" \
      || { printf '%s (lane %s): expected model = "%s", got: %s\n' "$toml" "$lane" "$want" "$(rg -N '^model = ' "$toml")" >&2; return 1; }
  done
  [ "$seen_primary" -eq 1 ] && [ "$seen_alt" -eq 1 ] \
    || { echo "no source agent names both lanes — this check would be vacuous" >&2; return 1; }
}
# registry_ids — the Codex ids model-registry.sh gives in THIS environment (the same one the build under
# test inherits): the two review lanes as REG_PRIMARY and REG_ALT, and the three tiers as REG_OPUS
# (the primary), REG_SONNET (ZUVO_MODEL_CODEX_ALT) and REG_HAIKU (ZUVO_MODEL_CODEX_SMALL). Read from
# NAMED lines, and the call fails unless there are exactly four lines and every id is non-empty — no
# positional word splitting that could drop or merge a value.
registry_ids() {
  local out
  out="$(bash -c '. "$1"/shared/includes/model-registry.sh
    printf "primary=%s\nalt=%s\nsonnet=%s\nhaiku=%s\n" "$ZUVO_MODEL_CODEX_PRIMARY" "$ZUVO_MODEL_CODEX_REVIEW_ALT" \
      "$ZUVO_MODEL_CODEX_ALT" "$ZUVO_MODEL_CODEX_SMALL"' _ "$REPO_ROOT")" || return 1
  REG_PRIMARY="$(printf '%s\n' "$out" | sed -n 's/^primary=//p')"
  REG_ALT="$(printf '%s\n' "$out" | sed -n 's/^alt=//p')"
  REG_SONNET="$(printf '%s\n' "$out" | sed -n 's/^sonnet=//p')"
  REG_HAIKU="$(printf '%s\n' "$out" | sed -n 's/^haiku=//p')"
  REG_OPUS="$REG_PRIMARY"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 4 ] && [ -n "$REG_PRIMARY" ] && [ -n "$REG_ALT" ] \
    && [ -n "$REG_SONNET" ] && [ -n "$REG_HAIKU" ] \
    || { printf 'registry_ids: expected four non-empty ids, got [%s]\n' "$out" >&2; return 1; }
}
# claude_cache_copy <dir> — the three trees install_claude materialises lanes in, copied from the repo.
claude_cache_copy() {
  mkdir -p "$1"
  cp -R "$REPO_ROOT/skills" "$REPO_ROOT/shared" "$REPO_ROOT/rules" "$1/"
}
# claude_materialize <cache-root> — install.sh's own materialise + validate against <cache-root>.
# install.sh is SOURCED (its main run is guarded), and sourcing still runs its downgrade guard and the
# sleep-guard block, both of which read and write under $HOME — so HOME is a temp dir, never the real one.
# ZT_STUB_PATH (exported by a test, unset by teardown), when set, goes first on PATH for the two calls
# only. What sourcing install.sh prints on stderr is kept in a file and shown if the source fails.
claude_materialize() {
  local home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home"
  HOME="$home" bash -c 'if ! . "$1" >/dev/null 2>"$3"; then echo "sourcing install.sh failed:"; cat "$3"; exit 97; fi
    if [ -n "${ZT_STUB_PATH:-}" ]; then PATH="$ZT_STUB_PATH:$PATH"; fi
    materialize_claude_reviewer_lanes "$2" || { echo "materialize failed"; exit 98; }
    validate_claude_reviewer_lanes "$2"' _ "$REPO_ROOT/scripts/install.sh" "$1" "$BATS_TEST_TMPDIR/source-install.err"
}

# ── The lane grammar (scripts/lib/reviewer-lanes.sh), driven directly ────────────────────────────
LANES_LIB="$REPO_ROOT/scripts/lib/reviewer-lanes.sh"
# lanes <function> [args…] — one function of the lane library, in a fresh bash that sourced
# lib/portable.sh and then the library, in the order install.sh and the builds source them.
lanes() {
  bash -c '. "$1" || exit 97; . "$2" || exit 97; shift 2; "$@"' _ "$REPO_ROOT/scripts/lib/portable.sh" "$LANES_LIB" "$@"
}
# plant_lane_fixtures <dir> — frontmatter files, each with its model key on LINE 4.
#   HIT_REWRITTEN  the strict rewriter resolves them (and the lenient scan reports them unresolved);
#   HIT_REPORTED   the strict rewriter leaves them, the lenient scan reports them — so the Claude install
#                  FAILS on them rather than shipping an unresolved lane;
#   MISS_ALWAYS    neither grammar touches them: prose, a longer id, no frontmatter, a lane in a comment.
HIT_REWRITTEN="fx-plain fx-plainalt fx-comment fx-crlf"
HIT_REPORTED="fx-bom fx-indent fx-spaced fx-trail fx-cross fx-case fx-quoted fx-blank fx-flow fx-comma fx-block"
MISS_ALWAYS="fx-substr fx-body fx-nofm fx-commentlane fx-commentquoted"
plant_lane_fixtures() {
  local d="$1" n
  mkdir -p "$d"
  fm() { printf '%s\n' "$2" "name: $1" 'description: planted lane fixture' "$3" '---' '' 'Body text.' > "$d/$1.md"; }
  fm fx-plain         '---'   'model: review-primary'
  fm fx-plainalt      '---'   'model: review-alt'
  fm fx-comment       '---'   'model: review-primary # the lane review-alt, kept in the comment'
  printf -- '---\r\nname: fx-crlf\r\ndescription: planted lane fixture\r\nmodel: review-alt\r\n---\r\n' > "$d/fx-crlf.md"
  printf '\357\273\277---\nname: fx-bom\ndescription: planted lane fixture\nmodel: review-primary\n---\n' > "$d/fx-bom.md"
  fm fx-indent        '---'   '  model: review-alt'
  fm fx-spaced        '---'   'model : review-primary'
  fm fx-trail         '---  ' 'model: review-alt'
  fm fx-cross         '---'   'model: cross-vendor'
  fm fx-case          '---'   'model: Review-Primary'
  fm fx-quoted        '---'   'model: "review-alt"'
  # Blank lines BEFORE the opening `---`: the lenient scan still takes the block as frontmatter.
  printf '%s\n' '' '---' 'description: planted lane fixture' 'model: review-alt' '---' 'Body text.' > "$d/fx-blank.md"
  fm fx-flow          '---'   'model: [review-alt]'
  fm fx-comma         '---'   'model: x,review-alt'
  # A YAML block scalar: the value is on the next line, which a line scanner cannot read — reported
  # as unparsed rather than passed.
  printf '%s\n' '---' 'name: fx-block' 'description: planted lane fixture' 'model: >' '  review-alt' '---' > "$d/fx-block.md"
  fm fx-substr        '---'   'model: review-primary-test'
  fm fx-commentlane   '---'   'model: opus # was review-primary'
  fm fx-commentquoted '---'   'model: "opus" # review-alt'
  printf '%s\n' '---' 'name: fx-body' 'description: planted lane fixture' 'model: opus' '---' 'model: review-alt' > "$d/fx-body.md"
  printf '%s\n' 'name: fx-nofm' 'description: planted lane fixture' 'no frontmatter here' 'model: review-alt' > "$d/fx-nofm.md"
  for n in $HIT_REWRITTEN $HIT_REPORTED $MISS_ALWAYS; do [ -f "$d/$n.md" ] || { echo "fixture $n not planted" >&2; return 1; }; done
}
# toml_model_is <dist-root> <toml-name> <want> — that Codex agent TOML holds exactly model = "<want>".
toml_model_is() {
  local f="$1/codex/agents/$2.toml" got
  [ -f "$f" ] || { echo "no TOML: $f" >&2; return 1; }
  got="$(sed -n 's/^model = "\(.*\)"$/\1/p' "$f")"
  [ "$got" = "$3" ] && return 0
  printf '%s: expected model [%s], got [%s]\n' "$f" "$3" "$got" >&2
  return 1
}
# rewrite_of <original> <line-4> <actual> — <actual> is <original> BYTE FOR BYTE except that its line 4
# is exactly <line-4> (a CR in it included): the whole file compared, not one line.
rewrite_of() {
  local exp
  exp="$(mktemp "$BATS_TEST_TMPDIR/expected.XXXXXX")"
  awk -v l="$2" 'NR == 4 { print l; next } { print }' "$1" > "$exp"
  cmp "$exp" "$3" && return 0
  printf 'not the expected rewrite of %s:\n' "$1" >&2
  diff "$exp" "$3" | cat -v >&2
  return 1
}
# line4_is <file> <want> — the file's 4th line is exactly <want> (a CR in it included).
line4_is() {
  local got
  got="$(sed -n '4p' "$1")"
  [ "$got" = "$2" ] && return 0
  printf 'line 4 of %s: expected [%s], got [%s]\n' "$1" "$2" "$got" | cat -v >&2
  return 1
}
# awk_stub <dir> <mode> <path>… — an `awk` first on PATH that cannot read exactly the given paths (an
# argument EQUAL to one of them) and is the real awk for everything else. <mode> `before`: it exits 2
# at once, as an awk that cannot open its input does; `after`: the real awk reads every file first
# (so hits already found are printed) and the run then exits 2, as gawk does after an unreadable file.
awk_stub() {
  local dir="$1" mode="$2" real
  shift 2
  real="$(command -v awk)"
  mkdir -p "$dir"
  printf '%s\n' "$@" > "$dir/unreadable"
  printf '#!/bin/sh\nhit=""\nfor a in "$@"; do if grep -qxF -- "$a" "%s"; then hit="$a"; fi; done\nif [ -n "$hit" ] && [ "%s" = before ]; then echo "awk-stub: cannot read $hit" >&2; exit 2; fi\n"%s" "$@"\nrc=$?\nif [ -n "$hit" ]; then echo "awk-stub: cannot read $hit" >&2; exit 2; fi\nexit $rc\n' \
    "$dir/unreadable" "$mode" "$real" > "$dir/awk"
  chmod +x "$dir/awk"
}
# only_stub <dir> <tool> <path> — a <tool> (mv) first on PATH that refuses when its LAST argument is
# <path>, recording what it refused, and is the real tool for everything else.
only_stub() {
  local real
  real="$(command -v "$2")"
  mkdir -p "$1"
  printf '#!/bin/sh\nfor last in "$@"; do :; done\nif [ "$last" = "%s" ]; then echo "%s-stub: refused $last" >&2; echo "$last" >> "%s"; exit 1; fi\nexec "%s" "$@"\n' \
    "$3" "$2" "$1/refused" "$real" > "$1/$2"
  chmod +x "$1/$2"
}
# codex_fixture <dir> [full] — a copy of what the Codex build reads, with the build + helper beside it
# (the sanctioned way to build another tree — test-dist-build-cache.sh (7)). Default: ONE tiny skill
# (a build of seconds); `full`: every skill and hooks/ too.
codex_fixture() {
  local fk="$1"
  # Each step returns on failure itself: a per-platform scenario calls this as a condition (errexit off).
  mkdir -p "$fk/tests/lib" "$fk/scripts/lib" "$fk/skills" || return 1
  cp "$REPO_ROOT/tests/lib/dist-build.sh" "$fk/tests/lib/" || return 1
  cp "$REPO_ROOT/scripts/build-codex-skills.sh" "$fk/scripts/" || return 1
  cp "$REPO_ROOT"/scripts/lib/*.sh "$fk/scripts/lib/" || return 1
  cp -R "$REPO_ROOT/shared" "$REPO_ROOT/rules" "$REPO_ROOT/.codex-plugin" "$fk/" || return 1
  if [ "${2:-}" = full ]; then
    cp -R "$REPO_ROOT/skills" "$REPO_ROOT/hooks" "$fk/" || return 1
  else
    mkdir -p "$fk/skills/zz-min" || return 1
    printf '%s\n' '---' 'name: zz-min' 'description: minimal fixture skill' '---' '# zuvo:zz-min' '' 'Nothing to do.' > "$fk/skills/zz-min/SKILL.md"
  fi
}
# platform_fixture <dir> <cursor|antigravity|kimi> — the same idea as codex_fixture (a minimal
# copy of what the build reads, with the build + tests/lib/dist-build.sh beside it), generalized:
# none of these three reads a platform manifest the way the Codex build reads
# .codex-plugin/plugin.json, so there is nothing extra to copy.
# platform_fixture <dir> <cursor|antigravity|kimi> [full] — fix round 3, W5: the platform is
# ALLOWLISTED (a typo'd or future platform fails loudly, not with a confusing later error), and
# every cp/mkdir is checked (an unnoticed partial fixture used to produce misleading test
# failures far from the real cause). Default: ONE tiny skill (zz-min). `full`: every real skill
# (matching codex_fixture's `full` mode) -- needed when a test wants a genuine `status -eq 0`
# (fix round 3, W1): the minimal fixture has no write-tests skill, so the "Missing <Platform>
# blind audit reviewer agents" check always fires and no minimal-fixture build can ever exit 0.
platform_fixture() {
  local fk="$1" platform="$2"
  case "$platform" in
    cursor|antigravity|kimi) ;;
    *) echo "platform_fixture: unknown platform [$platform] (want cursor|antigravity|kimi)" >&2; return 1 ;;
  esac
  mkdir -p "$fk/tests/lib" "$fk/scripts/lib" "$fk/skills" || return 1
  cp "$REPO_ROOT/tests/lib/dist-build.sh" "$fk/tests/lib/" || return 1
  cp "$REPO_ROOT/scripts/build-$platform-skills.sh" "$fk/scripts/" || return 1
  cp "$REPO_ROOT"/scripts/lib/*.sh "$fk/scripts/lib/" || return 1
  cp -R "$REPO_ROOT/shared" "$REPO_ROOT/rules" "$fk/" || return 1
  if [ "${3:-}" = full ]; then
    cp -R "$REPO_ROOT/skills" "$REPO_ROOT/hooks" "$fk/" || return 1
  else
    mkdir -p "$fk/skills/zz-min" || return 1
    printf '%s\n' '---' 'name: zz-min' 'description: minimal fixture skill' '---' '# zuvo:zz-min' '' 'Nothing to do.' > "$fk/skills/zz-min/SKILL.md"
  fi
}
# plant_unrecognized_model_key_agent <agents-dir> <name> <lane> — a frontmatter model KEY none of the four
# builds' own per-agent transforms recognizes: `Model:` (capitalized) instead of `model:`. Every
# build's per-agent awk only matches column-0, lowercase `/^model:/`. Since fix round 1 (C1) this
# is caught EARLIER than the leftover scan: `zrl_frontmatter_model` is the same case-sensitive
# column-0 reader, so it reports "no readable model:" before adapt_agent_for_* is ever called — no
# dst file is written, so the leftover scan never even sees this one. (Before C1 it was the
# leftover scan's job; the word survived byte for byte into the dist and zrl_scan_md caught it
# there. See plant_rules_lane_fixture below for a fixture that still exercises the scan itself —
# an agent's C1 gate does not run over rules/.)
plant_unrecognized_model_key_agent() {
  local d="$1" name="$2" lane="$3"
  mkdir -p "$d"
  printf '%s\n' '---' "name: $name" 'description: planted lane fixture' "Model: $lane" '---' '' 'Body text.' > "$d/$name.md"
}
# plant_agent_fixture <agents-dir> <name> <model-line> — a single agent whose frontmatter `model:`
# line is exactly <model-line> (e.g. `model: gpt-weird`, `model: cross-vendor`, or nothing —
# `plant_agent_fixture "$d" "$n"` omits the line entirely, so line 4 is absent and the frontmatter
# closes after the description). Used to drive agent_model_known_{cursor,antigravity,kimi} (plan C
# Task 4 fix round 1, C1) and zrl_frontmatter_model's "no readable model:" path directly.
plant_agent_fixture() {
  local d="$1" name="$2" model_line="${3:-}"
  mkdir -p "$d"
  if [ -n "$model_line" ]; then
    printf '%s\n' '---' "name: $name" 'description: planted C1/D1 fixture' "$model_line" '---' '' 'Body text.' > "$d/$name.md"
  else
    printf '%s\n' '---' "name: $name" 'description: planted C1/D1 fixture' '---' '' 'Body text.' > "$d/$name.md"
  fi
}
# plant_rules_lane_fixture <rules-dir> <name> <lane> — a rules/*.md file (NOT an agent — no
# agent_model_known_* gate runs over rules/) whose own leading frontmatter names a lane as a
# `model:` value. None of the three builds' rules/ pipeline touches `model:` lines any more (fix
# round 1, C3: Cursor's leftover scan was missing $DIST/rules entirely; Antigravity's and Kimi's
# `replace_model_refs` had un-anchored `model: review-primary`/`model: review-alt` substitutions
# that silently resolved this exact fixture before the leftover scan ever ran, over rules/ and
# shared/includes/ alike — both removed), so the lane survives byte for byte into the dist and
# only the narrowed leftover scan (zrl_scan_md) catches it.
plant_rules_lane_fixture() {
  local d="$1" name="$2" lane="$3"
  mkdir -p "$d"
  printf '%s\n' '---' 'lane-doc: true' "model: $lane" '---' '' "# planted rules fixture ($name)" > "$d/$name.md"
}
# plant_dataonly_lookalike_agent <agents-dir> <name> <desc-word> — a REAL agent shaped exactly like
# skills/content-expand/agents/prose-quality-scorer.md: a readable `model: sonnet` PLUS a
# description containing <desc-word> (e.g. "registry" or "template" — the words the data-only
# heuristic's `is_data` check matches on `head -5`). Fix round 3 (A1) fixed the underlying bug this
# fixture drives (the skip ran BEFORE the model check and swallowed exactly this shape — confirmed
# via the real prose-quality-scorer.md, which shipped nowhere before A1); fix round 4 (Q11,
# N1-precise) found no fixture in this file actually exercised that shape through a real build —
# only the out-of-suite tally scripts did.
plant_dataonly_lookalike_agent() {
  local d="$1" name="$2" word="$3"
  mkdir -p "$d"
  printf '%s\n' '---' "name: $name" "description: \"Scores content against a PQ1-PQ18 $word and extracts a voice profile.\"" 'model: sonnet' 'tools:' '  - Read' '---' '' "# ${name}" '' 'Body text.' > "$d/$name.md"
}
# teardown_as <TMPDIR value | unset> <sandbox> — teardown_file against that sandbox.
teardown_as() {
  if [ "$1" = unset ]; then unset TMPDIR; else TMPDIR="$1"; export TMPDIR; fi
  ZUVO_DIST_SANDBOX="$2"
  teardown_file
}
# teardown_rm_spy <sandbox> — teardown_file with `rm` replaced by a recorder, TMPDIR unset: for
# targets a regressed guard would really delete (the repository itself), nothing can be removed.
# Recorded twice over: the shell function catches a bare `rm`, and a recording `rm` first on PATH
# catches `command rm`, which skips functions. Only an absolute path (/bin/rm) gets past both — which is
# why the test below proves the recorder intercepts BEFORE it hands teardown_file a dangerous target.
teardown_rm_spy() {
  unset TMPDIR
  mkdir -p "$BATS_TEST_TMPDIR/rm-spy"
  printf '#!/bin/sh\nprintf "RM-CALLED %%s\\n" "$*"\n' > "$BATS_TEST_TMPDIR/rm-spy/rm"
  chmod +x "$BATS_TEST_TMPDIR/rm-spy/rm"
  PATH="$BATS_TEST_TMPDIR/rm-spy:$PATH"
  rm() { printf 'RM-CALLED %s\n' "$*"; }
  ZUVO_DIST_SANDBOX="$1"
  teardown_file
}
# setup_file_with_shims <dir> — setup_file with <dir> first on PATH and no sandbox inherited;
# reports what it left in the two variables.
setup_file_with_shims() {
  local rc=0
  PATH="$1:$PATH"
  unset ZUVO_DIST_SANDBOX ZUVO_DIST_ROOT
  setup_file || rc=$?
  echo "AFTER sandbox=[${ZUVO_DIST_SANDBOX:-}] root=[${ZUVO_DIST_ROOT:-}]"
  return "$rc"
}

# --fresh on every build whose TREE the assertions read (plan C Task 3, fix round 1): under run-all a
# plain call REPLAYS whatever the first caller of the run built. The cache is keyed on the platform name
# alone, and this checkout's working tree is edited while suites run (concurrent agents), so a replay can
# certify a build of an earlier tree. --fresh always runs the real builder and refreshes the entry, so
# later callers replay THIS build. Standalone (no cache) it is the same single build as before.
@test "Codex build materializes reviewer lanes to concrete models" {
  run bash "$REPO_ROOT/tests/lib/dist-build.sh" --fresh codex
  [ "$status" -eq 0 ]

  local primary="$ZUVO_DIST_ROOT/codex/agents/write-tests-blind-coverage-auditor.toml"
  local alt="$ZUVO_DIST_ROOT/codex/agents/write-tests-blind-coverage-auditor-alt.toml"
  local fallback_primary="$ZUVO_DIST_ROOT/codex/agents/write-tests-adversarial-test-reviewer.toml"
  local fallback_alt="$ZUVO_DIST_ROOT/codex/agents/write-tests-adversarial-test-reviewer-alt.toml"

  [ -f "$primary" ]
  [ -f "$alt" ]
  [ -f "$fallback_primary" ]
  [ -f "$fallback_alt" ]
  run rg -n 'review-primary|review-alt' "$primary" "$alt" "$fallback_primary" "$fallback_alt"
  [ "$status" -eq 1 ]
  # DERIVE the expected models from the router instead of hardcoding them. The old
  # literals ("gpt-5.4" / "gpt-5.3-codex") were a FOURTH copy of the model list,
  # alongside model-registry.sh, the router table and the build itself — and
  # gpt-5.3-codex had already left the registry a generation earlier, so this
  # asserted a pairing that could no longer be produced. What is worth pinning is
  # that the BUILD and the ROUTER agree; a model rename should move both together
  # or fail here, not be re-typed in a third place.
  # Strip EVERY host marker, not just two. reviewer-model-route.sh picks the reviewer from
  # the detected HOST, so an ambient ANTIGRAVITY_SESSION_ID / VSCODE_GIT_ASKPASS_MAIN makes
  # these two probes answer with Gemini or Claude ids and the Codex assertions below fail —
  # the test's result would depend on WHICH IDE ran the suite. reviewer-model-route.bats:14
  # already strips the full set; this file stripped a subset until 2026-08-11.
  # The last three -u are the Codex Desktop signals the router now reads (zms_is_codex_host).
  # -u CLAUDE_MODEL / -u CODEX_MODEL: the router checks the Claude branch BEFORE the Codex
  # branch, so an ambient CLAUDE_MODEL (e.g. from whatever agent runs this suite) misroutes
  # every case here to platform=claude regardless of ZUVO_CODEX_MODEL. CODEX_MODEL is unused
  # by this router directly but cleared for the same who-ran-it independence as everywhere
  # else in this pair of files. PATH is pinned rather than inherited: the Codex branch this
  # helper exercises needs nothing on PATH (no external command runs before routing_status is
  # decided — see the router's own PATH=/nonexistent comment), so a narrow, explicit PATH
  # proves that rather than assuming it.
  # --fallback + ZUVO_CLAUDE_BIN=/nonexistent (plan C Task 1): a Codex host now routes CROSS-VENDOR to
  # Opus whenever a `claude` is installed, which is not what the Codex build materializes — the build's
  # agent lanes are the SAME-VENDOR pair. --fallback asks the router for exactly that in-family row,
  # whatever is installed on the machine running the suite; the seams are pinned so neither a claude on
  # /usr/bin (the farm ships one) nor the Codex app can decide it.
  route_codex() {
    env -u CLAUDECODE -u CLAUDE_MODEL -u CODEX_MODEL -u CODEX_SANDBOX -u ANTIGRAVITY_SESSION_ID \
        -u VSCODE_GIT_ASKPASS_MAIN -u CLAUDE_CODE_ENTRYPOINT \
        -u CODEX_SHELL -u CODEX_INTERNAL_ORIGINATOR_OVERRIDE -u __CFBundleIdentifier \
        "ZUVO_CODEX_MODEL=$1" ZUVO_CLAUDE_BIN=/nonexistent ZUVO_CODEX_BIN=/nonexistent \
        ZUVO_CODEX_APP_BIN=/nonexistent PATH=/usr/bin:/bin \
        bash "$REPO_ROOT/scripts/reviewer-model-route.sh" --fallback | sed -n 's/^reviewer_model=//p'
  }
  local want_primary want_alt
  want_primary="$(route_codex gpt-5.5)"
  want_alt="$(route_codex gpt-5.4)"
  [ -n "$want_primary" ]
  [ -n "$want_alt" ]
  [ "$want_primary" != "$want_alt" ]   # a build that collapsed both lanes to one model is broken
  run rg -n "model = \"$want_primary\"" "$primary" "$fallback_primary"
  [ "$status" -eq 0 ]
  run rg -n "model = \"$want_alt\"" "$alt" "$fallback_alt"
  [ "$status" -eq 0 ]

  # ANCHOR TO THE REGISTRY, not only to router<->build self-consistency. Deriving both
  # sides from the router proves those two agree, but says nothing about whether either
  # matches model-registry.sh — the actual source of truth. One find-and-replace typo
  # applied to the router AND the build together would keep them agreeing while both
  # drifted off the registry, and the check above would still pass. That is the narrow
  # circularity this closes: every model the build emits must be a model the registry
  # actually names.
  local reg_known
  # shellcheck disable=SC1091
  reg_known="$(bash -c '. "$1"/shared/includes/model-registry.sh
      printf "%s %s %s" "$ZUVO_MODEL_CODEX_PRIMARY" "$ZUVO_MODEL_CODEX_ALT" "$ZUVO_MODEL_CODEX_REVIEW_ALT"' _ "$REPO_ROOT")"
  [ -n "${reg_known// /}" ]
  # Membership, not positional equality: the registry names the LANES, the router decides
  # which lane reviews which writer, so pinning want_primary=="$reg_primary" would
  # over-specify routing policy and break on a legitimate lane swap. What must hold is
  # that the build cannot emit a model the registry has never heard of — the check that
  # caught gpt-5.5 being dispatched while absent from the "single source of model ids".
  [[ " $reg_known " == *" $want_primary "* ]] || false
  [[ " $reg_known " == *" $want_alt "* ]] || false

  # Lane -> registry id, POSITIONALLY (plan C Task 3). The membership check above stays about routing
  # policy; this is the build's own contract: `review-primary` IS ZUVO_MODEL_CODEX_PRIMARY and
  # `review-alt` IS ZUVO_MODEL_CODEX_REVIEW_ALT, for every agent that names a lane.
  registry_ids
  lane_tomls_hold "$ZUVO_DIST_ROOT" "$REG_PRIMARY" "$REG_ALT"
}

@test "Codex build takes the reviewer ids from the registry: an env override reaches every lane TOML" {
  # Its OWN dist root and no cache: a build with a swapped registry value must neither replay a cached
  # tree nor leave one behind for the other tests to replay.
  local root="$BATS_TEST_TMPDIR/dist-override"
  mkdir -p "$root"
  # ZUVO_MODEL_CODEX_ALT, not _REVIEW_ALT: the review lane DERIVES from it in the registry, so this also
  # proves the build reads the registry's derivation rather than a copy of the default. `gpt-x:1`: an id
  # the router's is_model_id accepts (a colon) must build too — the build uses the router's grammar.
  run env -u ZUVO_DIST_CACHE -u ZUVO_MODEL_CODEX_REVIEW_ALT ZUVO_DIST_ROOT="$root" \
      ZUVO_MODEL_CODEX_PRIMARY=gpt-test-x ZUVO_MODEL_CODEX_ALT=gpt-x:1 \
      bash "$REPO_ROOT/tests/lib/dist-build.sh" codex
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20 >&2; return 1; }
  run rg -N '^model = ' "$root/codex/agents/write-tests-blind-coverage-auditor.toml"
  [ "$output" = 'model = "gpt-test-x"' ] || { echo "blind-coverage-auditor.toml: $output" >&2; return 1; }
  lane_tomls_hold "$root" gpt-test-x gpt-x:1
}

@test "Codex build fails closed: a registry id that is not ONE model id stops it, naming the variable" {
  # Each run stops at the registry check, before the build touches its dist — seconds, not a build.
  local root="$BATS_TEST_TMPDIR/dist-badid" bad
  mkdir -p "$root"
  for bad in 'bad id' '-x' 'a/b' '.x' 'x$'; do
    run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" ZUVO_MODEL_CODEX_PRIMARY="$bad" \
        bash "$REPO_ROOT/tests/lib/dist-build.sh" codex
    [ "$status" -eq 1 ] || { printf 'id [%s] -> status %s\n%s\n' "$bad" "$status" "$output" >&2; return 1; }
    output_has "ZUVO_MODEL_CODEX_PRIMARY" || return 1
    output_has "is not a single model id" || return 1
    [ ! -e "$root/codex/agents" ] || { echo "id [$bad]: the build got as far as writing TOMLs" >&2; return 1; }
  done
  # The derived review-alt id is checked too, under ITS name.
  run env -u ZUVO_DIST_CACHE -u ZUVO_MODEL_CODEX_REVIEW_ALT ZUVO_DIST_ROOT="$root" ZUVO_MODEL_CODEX_ALT='gpt x' \
      bash "$REPO_ROOT/tests/lib/dist-build.sh" codex
  [ "$status" -eq 1 ]
  output_has "ZUVO_MODEL_CODEX_REVIEW_ALT"
  output_has "is not a single model id"
  # The tier ids are checked the same way, under THEIR names: `haiku` takes ZUVO_MODEL_CODEX_SMALL.
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" ZUVO_MODEL_CODEX_SMALL='gpt small' \
      bash "$REPO_ROOT/tests/lib/dist-build.sh" codex
  [ "$status" -eq 1 ]
  output_has "ZUVO_MODEL_CODEX_SMALL"
  output_has "is not a single model id"
  [ ! -e "$root/codex/agents" ]
}

@test "Codex build fails closed: no model registry in the tree it builds, or one that does not source — no build" {
  local fk="$BATS_TEST_TMPDIR/fixture-noreg" root="$BATS_TEST_TMPDIR/dist-noreg"
  codex_fixture "$fk"
  mkdir -p "$root"
  rm "$fk/shared/includes/model-registry.sh"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" codex
  [ "$status" -eq 1 ]
  output_has "model registry not found or unreadable: $fk/shared/includes/model-registry.sh"
  [ ! -e "$root/codex/agents" ]
  # Present, but it ends in a failure: nothing it may have set is trusted.
  printf '%s\n' 'ZUVO_MODEL_CODEX_PRIMARY=gpt-half-loaded' 'return 3' > "$fk/shared/includes/model-registry.sh"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" codex
  [ "$status" -eq 1 ]
  output_has "model registry could not be sourced: $fk/shared/includes/model-registry.sh"
  [ ! -e "$root/codex/agents" ]
}

# ── The Claude TIERS an agent names (haiku, sonnet, opus) take their Codex id from the registry, like
# the lanes: haiku -> ZUVO_MODEL_CODEX_SMALL, sonnet -> ZUVO_MODEL_CODEX_ALT, opus ->
# ZUVO_MODEL_CODEX_PRIMARY. The build used to write the literals gpt-5.4-mini / gpt-5.4 / gpt-5.5, and
# model-registry.sh records the first two as refused on the account: every non-reviewer agent shipped
# with a model that cannot run. Built twice — with the registry's own values, and with all three
# overridden to ids that exist nowhere in the build script — so a literal cannot pass either run.
@test "Codex build: haiku, sonnet and opus agents take the registry's small, alt and primary ids — never a literal" {
  local fk="$BATS_TEST_TMPDIR/codex-tiers" root="$BATS_TEST_TMPDIR/codex-tiers-dist" root2="$BATS_TEST_TMPDIR/codex-tiers-dist2" a t
  codex_fixture "$fk" full
  mkdir -p "$fk/skills/zz-tier/agents"
  printf '%s\n' '---' 'name: zz-tier' 'description: fixture skill for the tier map' '---' '# zuvo:zz-tier' '' \
    'Dispatch via Agent tool.' '' '**Model:** Sonnet' '**Model:** Opus' '**Model:** Haiku' > "$fk/skills/zz-tier/SKILL.md"
  a="$fk/skills/zz-tier/agents"
  for t in haiku sonnet opus; do plant_agent_fixture "$a" "t-$t" "model: $t"; done
  plant_agent_fixture "$a" t-pertask 'model: "per-task: sonnet for standard complexity, opus for complex"'
  printf '%s\n' '---' 'name: t-reasoning' 'description: planted reasoning agent' 'model: opus' 'reasoning: true' '---' '' 'Body.' > "$a/t-reasoning.md"

  plat_run_build "$fk" "$root" codex
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20 >&2; return 1; }
  registry_ids
  toml_model_is "$root" zz-tier-t-haiku "$REG_HAIKU"
  toml_model_is "$root" zz-tier-t-sonnet "$REG_SONNET"
  toml_model_is "$root" zz-tier-t-opus "$REG_OPUS"
  toml_model_is "$root" zz-tier-t-pertask "$REG_SONNET"
  # A reasoning agent on the opus tier runs the sonnet tier at xhigh effort.
  toml_model_is "$root" zz-tier-t-reasoning "$REG_SONNET"
  run grep -c '^model_reasoning_effort = "xhigh"$' "$root/codex/agents/zz-tier-t-reasoning.toml"
  [ "$output" = 1 ]
  # No TOML of the whole dist names a model the registry did not give — line by line, so an EMPTY
  # `model = ""` is judged too (a word-split loop would drop it and pass).
  run bash -c 'sed -n "s/^model = \"\(.*\)\"\$/\1/p" "$1"/codex/agents/*.toml | sort -u' _ "$root"
  [ "$status" -eq 0 ]
  [ -n "$output" ] || { echo "no TOML model line was read at all" >&2; return 1; }
  while IFS= read -r t; do
    # The empty id first: in the membership pattern below it would become two spaces, which never match.
    [ -n "$t" ] || { echo "a TOML names an empty model" >&2; return 1; }
    case " $REG_PRIMARY $REG_ALT $REG_SONNET $REG_HAIKU " in
      *" $t "*) ;;
      *) echo "a TOML names [$t], which is no registry id" >&2; return 1 ;;
    esac
  done <<< "$output"
  # The prose names the same ids as the TOMLs.
  run rg -F -x "**Model:** $REG_SONNET" "$root/codex/skills/zz-tier/SKILL.md"; [ "$status" -eq 0 ]
  run rg -F -x "**Model:** $REG_OPUS" "$root/codex/skills/zz-tier/SKILL.md"; [ "$status" -eq 0 ]
  run rg -F -x "**Model:** $REG_HAIKU" "$root/codex/skills/zz-tier/SKILL.md"; [ "$status" -eq 0 ]

  mkdir -p "$root2"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root2" ZUVO_MODEL_CODEX_SMALL=gpt-t-small ZUVO_MODEL_CODEX_ALT=gpt-t-alt \
      ZUVO_MODEL_CODEX_PRIMARY=gpt-t-primary bash "$fk/tests/lib/dist-build.sh" codex
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20 >&2; return 1; }
  toml_model_is "$root2" zz-tier-t-haiku gpt-t-small
  toml_model_is "$root2" zz-tier-t-sonnet gpt-t-alt
  toml_model_is "$root2" zz-tier-t-opus gpt-t-primary
  toml_model_is "$root2" zz-tier-t-pertask gpt-t-alt
  toml_model_is "$root2" zz-tier-t-reasoning gpt-t-alt
  run rg -F -x '**Model:** gpt-t-alt' "$root2/codex/skills/zz-tier/SKILL.md"; [ "$status" -eq 0 ]
  run rg -l -F -e 'gpt-5.4' -e 'gpt-5.5' "$root2/codex/agents"
  [ "$status" -eq 1 ] || { echo "a TOML still carries a literal tier id: $output" >&2; return 1; }
}

# ── The two review lanes normally name two models. A registry (or an override) that gives both the same
# id still builds — an account may have one model — but the build says so: the two blind-audit
# reviewers are then one model, which the router reports as same-model-fallback at run time.
@test "Codex build: review-primary and review-alt resolving to ONE id is a WARN naming it, not a silent pass" {
  local fk="$BATS_TEST_TMPDIR/codex-samelane" root="$BATS_TEST_TMPDIR/codex-samelane-dist"
  # The FULL fixture: the minimal one has no blind-audit reviewers, so its build always fails and a
  # "still builds" contract could not be checked at all.
  codex_fixture "$fk" full
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" ZUVO_MODEL_CODEX_PRIMARY=gpt-same ZUVO_MODEL_CODEX_REVIEW_ALT=gpt-same \
      bash "$fk/tests/lib/dist-build.sh" codex
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20 >&2; return 1; }
  output_has "WARN: review-primary and review-alt both resolve to gpt-same"
  toml_model_is "$root" write-tests-blind-coverage-auditor gpt-same
  toml_model_is "$root" write-tests-blind-coverage-auditor-alt gpt-same
  # The registry's own two ids, whatever the caller's environment pins: no WARN.
  run env -u ZUVO_DIST_CACHE -u ZUVO_MODEL_CODEX_PRIMARY -u ZUVO_MODEL_CODEX_REVIEW_ALT ZUVO_DIST_ROOT="$root" \
      bash "$fk/tests/lib/dist-build.sh" codex
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20 >&2; return 1; }
  output_lacks "both resolve to"
}

@test "Codex dist: prose keeps the router's lane words; only agent frontmatter names a model" {
  run bash "$REPO_ROOT/tests/lib/dist-build.sh" --fresh codex
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20 >&2; return 1; }
  docs_keep_lane_words "$ZUVO_DIST_ROOT/codex"
}

@test "Codex build: a lane left as a MODEL in any spelling fails the build; lane words in prose do not" {
  # A copy of the repo's build inputs with planted files. The Codex overlay is copied into the dist
  # verbatim, past every rewrite; the agent fixtures are the spellings of plant_lane_fixtures.
  local fk="$BATS_TEST_TMPDIR/fixture-repo" root="$BATS_TEST_TMPDIR/dist-fixture" fx n
  codex_fixture "$fk" full
  fx="$fk/skills/zz-lane-fixture/agents"
  mkdir -p "$root" "$fk/skills/zz-lane-fixture/codex"
  printf '%s\n' '---' 'name: zz-lane-fixture' 'description: planted fixture' 'model: review-primary' '---' \
    '# zuvo:zz-lane-fixture' '' 'Prose may quote the review-alt lane and the cross-vendor route.' \
    'model: review-alt' > "$fk/skills/zz-lane-fixture/codex/SKILL.codex.md"
  plant_lane_fixtures "$fx"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" codex
  [ "$status" -ne 0 ] || { printf '%s\n' "$output" | tail -20 >&2; return 1; }
  # THE ERROR COUNT, exactly as the build counts it: each agent the gate (zrl_agent_gate) refuses is ONE
  # error (its TOML is not written); every lane still standing as a model in the emitted files is one
  # error PER REFERENCE, as in the other three builds (zrl_scan_and_report_lanes).
  #   no readable model (5): fx-indent fx-spaced — no column-0 `model:`; fx-trail fx-blank fx-nofm — no
  #                          frontmatter starting on line 1 (the strict reader, after the BOM/CRLF
  #                          normalisation every build applies)
  #   not accepted      (8): fx-cross fx-case fx-flow fx-comma fx-block fx-substr, fx-quoted — a lane is
  #                          taken only as the whole, unquoted value (zrl_agent_model_known) — and
  #                          fx-commentquoted, a QUOTED tier (`"opus"`), refused as in the other three
  #                          builds (the Codex build used to strip the quotes and take it as opus)
  #   leftovers         (4): the overlay, fx-indent, fx-spaced, fx-trail — one error each
  # fx-bom RESOLVES: the gate reads the model through zrl_strip_bom_crlf, as Cursor/Antigravity/Kimi do.
  output_has "BUILD FAILED: 17 error(s)"
  for n in fx-indent fx-spaced fx-trail fx-blank fx-nofm; do
    output_has "$fx/$n.md has no readable \`model:\`" || return 1
  done
  for n in fx-cross fx-case fx-flow fx-comma fx-block fx-substr fx-quoted fx-commentquoted; do
    output_has "$fx/$n.md: model value '" || return 1
  done
  output_has "Abstract reviewer lanes remain in Codex dist (4 leftover reference(s) — a route word, or an unparsable value, in a frontmatter model key):"
  output_has "$root/codex/skills/zz-lane-fixture/SKILL.md:4:model: review-primary"
  for n in fx-indent fx-spaced fx-trail; do
    output_has "$root/codex/skills/zz-lane-fixture/agents/$n.md:4:" || return 1
  done
  output_lacks "Prose may quote the review-alt lane"
  output_lacks "SKILL.md:9:"
  # RESOLVED — the plain spellings every target takes — so named by no error, and their TOMLs carry the
  # registry's ids.
  for n in fx-plain fx-plainalt fx-comment fx-crlf fx-bom fx-body fx-commentlane; do
    output_lacks "/$n.md" || return 1
  done
  registry_ids
  for n in fx-plain fx-comment fx-bom; do toml_model_is "$root" "zz-lane-fixture-$n" "$REG_PRIMARY" || return 1; done
  for n in fx-plainalt fx-crlf; do toml_model_is "$root" "zz-lane-fixture-$n" "$REG_ALT" || return 1; done
}

@test "Codex build: an agent with no model it can map fails the build by name — never a default id" {
  local fk="$BATS_TEST_TMPDIR/fixture-nomodel" root="$BATS_TEST_TMPDIR/dist-nomodel" a
  codex_fixture "$fk"
  a="$fk/skills/zz-min/agents"
  mkdir -p "$root" "$a"
  printf '%s\n' '---' 'name: zz-nomodel' 'description: planted agent without a model' '---' 'Body.' > "$a/zz-nomodel.md"
  printf '%s\n' '---' 'name: zz-unknown' 'description: planted agent' 'model: gpt-4o' '---' 'Body.' > "$a/zz-unknown.md"
  # A value that looks like an `echo` option must be read as itself, never swallowed into `opus`.
  printf '%s\n' '---' 'name: zz-dashn' 'description: planted agent' 'model: -n opus' '---' 'Body.' > "$a/zz-dashn.md"
  # A key with nothing after it but blanks, a tab, or a CR is no model either.
  printf '%s\n' '---' 'name: zz-blankval' 'description: planted agent' 'model:   ' '---' 'Body.' > "$a/zz-blankval.md"
  printf -- '---\nname: zz-tabval\ndescription: planted agent\nmodel:\t\n---\nBody.\n' > "$a/zz-tabval.md"
  printf -- '---\r\nname: zz-crval\r\ndescription: planted agent\r\nmodel:\r\n---\r\nBody.\r\n' > "$a/zz-crval.md"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" codex
  [ "$status" -ne 0 ]
  for n in zz-nomodel zz-blankval zz-tabval zz-crval; do
    output_has "$a/$n.md has no readable \`model:\`" || return 1
    [ ! -e "$root/codex/agents/zz-min-$n.toml" ] || { echo "$n got a TOML" >&2; return 1; }
  done
  output_has "$a/zz-nomodel.md has no readable \`model:\`"
  output_has "$a/zz-unknown.md: model value 'gpt-4o' is not one the Codex build accepts"
  output_has "$a/zz-dashn.md: model value '-n opus' is not one the Codex build accepts"
  [ ! -e "$root/codex/agents/zz-min-zz-nomodel.toml" ]
  [ ! -e "$root/codex/agents/zz-min-zz-unknown.toml" ]
  [ ! -e "$root/codex/agents/zz-min-zz-dashn.toml" ]
}

@test "Codex build: every build rewrites every TOML — a rebuild with a new registry id carries it; two agents on one TOML fail" {
  local fk="$BATS_TEST_TMPDIR/fixture-rebuild" root="$BATS_TEST_TMPDIR/dist-rebuild"
  codex_fixture "$fk"
  mkdir -p "$root" "$fk/skills/zz-min/agents"
  printf '%s\n' '---' 'name: zz-reviewer' 'description: planted reviewer' 'model: review-primary' '---' 'Body.' \
    > "$fk/skills/zz-min/agents/zz-reviewer.md"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" ZUVO_MODEL_CODEX_PRIMARY=gpt-first-x \
      bash "$fk/tests/lib/dist-build.sh" codex
  toml_model_is "$root" zz-min-zz-reviewer gpt-first-x
  # The SAME root, a new id: the build clears its agents/ first, so no TOML survives from the last run.
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" ZUVO_MODEL_CODEX_PRIMARY=gpt-second-x \
      bash "$fk/tests/lib/dist-build.sh" codex
  toml_model_is "$root" zz-min-zz-reviewer gpt-second-x
  # Two agents whose TOML names collide (write-e2e's prefix is `e2e`), both with models the gate accepts:
  # one TOML would silently stand for both, and the second agent's own model would never reach a TOML.
  # The build names the collision and fails.
  mkdir -p "$fk/skills/write-e2e/agents" "$fk/skills/e2e/agents"
  printf '%s\n' '---' 'name: e2e' 'description: fixture' '---' '# zuvo:e2e' > "$fk/skills/e2e/SKILL.md"
  printf '%s\n' '---' 'name: write-e2e' 'description: fixture' '---' '# zuvo:write-e2e' > "$fk/skills/write-e2e/SKILL.md"
  printf '%s\n' '---' 'name: zz-dup' 'description: planted' 'model: sonnet' '---' > "$fk/skills/e2e/agents/zz-dup.md"
  printf '%s\n' '---' 'name: zz-dup' 'description: planted' 'model: opus' '---' > "$fk/skills/write-e2e/agents/zz-dup.md"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" codex
  [ "$status" -ne 0 ]
  output_has "e2e-zz-dup.toml would be written twice"
}

@test "Codex build: a registry id that is a route word is refused when the registry is read, before anything is written" {
  local fk="$BATS_TEST_TMPDIR/fixture-routeid" root="$BATS_TEST_TMPDIR/dist-routeid" word
  codex_fixture "$fk"
  mkdir -p "$root" "$fk/skills/zz-min/agents"
  printf '%s\n' '---' 'name: zz-reviewer' 'description: planted reviewer' 'model: review-primary' '---' 'Body.' \
    > "$fk/skills/zz-min/agents/zz-reviewer.md"
  for word in review-alt cross-vendor Review-Primary; do
    run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" ZUVO_MODEL_CODEX_PRIMARY="$word" \
        bash "$fk/tests/lib/dist-build.sh" codex
    [ "$status" -eq 1 ] || { printf '[%s] -> status %s\n' "$word" "$status" >&2; return 1; }
    output_has "ZUVO_MODEL_CODEX_PRIMARY from $fk/shared/includes/model-registry.sh is [$word], a route word, not a model id" || return 1
    [ ! -e "$root/codex" ] || { echo "[$word]: the build wrote $root/codex before refusing" >&2; return 1; }
  done
}

@test "Codex build fails closed: no agent TOML to scan, or a scan that cannot read, fails the build" {
  local fk="$BATS_TEST_TMPDIR/fixture-empty" root="$BATS_TEST_TMPDIR/dist-empty"
  # A tree with no agents: the TOML scan has nothing to look at, which must not read as clean.
  codex_fixture "$fk"
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" codex
  [ "$status" -ne 0 ]
  output_has "no agent TOMLs in $root/codex/agents to scan for unresolved reviewer lanes"
  # One agent whose EMITTED .md and TOML the scanner cannot read. The scans read everything else first,
  # so the lane an overlay leaves in its frontmatter is found before they stop: the build must fail on
  # the incomplete scans AND show what they had found (the TOML scan: nothing, so no such heading).
  fk="$BATS_TEST_TMPDIR/fixture-unscannable"; root="$BATS_TEST_TMPDIR/dist-unscannable"
  codex_fixture "$fk"
  mkdir -p "$root" "$fk/skills/zz-min/agents" "$fk/skills/zz-min/codex"
  printf '%s\n' '---' 'name: zz-unscannable' 'description: planted unscannable agent' 'model: sonnet' '---' 'Body.' \
    > "$fk/skills/zz-min/agents/zz-unscannable.md"
  printf '%s\n' '---' 'name: zz-min' 'description: overlay' 'model: review-alt' '---' 'Body.' > "$fk/skills/zz-min/codex/SKILL.codex.md"
  awk_stub "$BATS_TEST_TMPDIR/awk-stub" after \
    "$root/codex/skills/zz-min/agents/zz-unscannable.md" "$root/codex/agents/zz-min-zz-unscannable.toml"
  run env -u ZUVO_DIST_CACHE PATH="$BATS_TEST_TMPDIR/awk-stub:$PATH" ZUVO_DIST_ROOT="$root" \
      bash "$fk/tests/lib/dist-build.sh" codex
  [ "$status" -ne 0 ]
  output_has "awk-stub: cannot read $root/codex/agents/zz-min-zz-unscannable.toml"
  output_has "awk-stub: cannot read $root/codex/skills/zz-min/agents/zz-unscannable.md"
  output_has "could not scan the Codex dist for unresolved reviewer lanes (agent TOMLs):"
  output_has "could not scan the Codex dist for unresolved reviewer lanes:"
  # The markdown scan's diagnostic, then its heading, then the overlay's lane it had found — in order.
  assert_line_order "could not scan the Codex dist for unresolved reviewer lanes:" \
    "awk-stub: cannot read $root/codex/skills/zz-min/agents/zz-unscannable.md" \
    "lanes it had found before the scan stopped:" \
    "$root/codex/skills/zz-min/SKILL.md:4:model: review-alt"
  # The TOML scan had found nothing, so it shows no such heading of its own: exactly one in the log.
  [ "$(printf '%s\n' "$output" | grep -c 'lanes it had found before the scan stopped:')" -eq 1 ]
}

@test "Claude cache: lanes are materialised only in agent frontmatter; prose keeps the router's words" {
  local cache="$BATS_TEST_TMPDIR/claude-cache" agents src
  claude_cache_copy "$cache"
  agents="$cache/skills/write-tests/agents"
  # A lane word in an agent's BODY is prose about the lane, not the agent's model.
  printf '\nmodel: review-alt  <- a body line quoting a lane, not frontmatter\n' >> "$agents/blind-coverage-auditor.md"
  # A trailing comment on the model line is kept as written, lane words in it included.
  sed -i.bak 's/^model: review-alt$/model: review-alt # the review-primary pair/' "$agents/adversarial-test-reviewer-alt.md"
  rm "$agents/adversarial-test-reviewer-alt.md.bak"
  # A SYMLINKED agent, its target inside the cache's skills/ (a link out of it is refused — the symlink
  # tests below): the materialiser reads through the link and replaces the LINK with the resolved file;
  # it never writes through it (the target keeps its lane).
  src="$cache/skills/zz-link/src"
  mkdir -p "$src" "$cache/skills/zz-link/agents"
  printf '%s\n' '---' 'name: zz-link' 'description: symlinked agent' 'model: review-primary' '---' > "$src/zz-link.txt"
  ln -s ../src/zz-link.txt "$cache/skills/zz-link/agents/zz-link.md"
  run claude_materialize "$cache"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  model_is "$agents/blind-coverage-auditor.md" opus
  model_is "$agents/adversarial-test-reviewer.md" opus
  model_is "$agents/blind-coverage-auditor-alt.md" sonnet
  model_is "$agents/adversarial-test-reviewer-alt.md" 'sonnet # the review-primary pair'
  run rg -c -F -x 'model: review-alt  <- a body line quoting a lane, not frontmatter' "$agents/blind-coverage-auditor.md"
  [ "$output" = 1 ] || { echo "the body line was rewritten or duplicated: [$output]" >&2; return 1; }
  [ ! -L "$cache/skills/zz-link/agents/zz-link.md" ]
  model_is "$cache/skills/zz-link/agents/zz-link.md" opus
  model_is "$src/zz-link.txt" review-primary
  docs_keep_lane_words "$cache"
}

@test "Claude cache: no agent file to materialise, or a symlink out of the cache, fails the install" {
  local cache="$BATS_TEST_TMPDIR/claude-cache-empty"
  # A cache whose skills/ holds no skills/*/agents/*.md at all: an unmatched glob is no success.
  mkdir -p "$cache/skills/zz-noagents" "$cache/shared/includes" "$cache/rules"
  printf '%s\n' '---' 'name: zz-noagents' '---' > "$cache/skills/zz-noagents/SKILL.md"
  run claude_materialize "$cache"
  [ "$status" -ne 0 ]
  output_has "materialize failed"
  output_has "No agent file under $cache/skills/*/agents/"
  # A symlink whose target is OUTSIDE the scanned tree: refused, named, before anything is rewritten.
  cache="$BATS_TEST_TMPDIR/claude-cache-out"
  claude_cache_copy "$cache"
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  printf '%s\n' '---' 'name: zz-out' 'model: review-primary' '---' > "$BATS_TEST_TMPDIR/outside/zz-out.md"
  ln -s "$BATS_TEST_TMPDIR/outside/zz-out.md" "$cache/shared/includes/zz-out.md"
  run claude_materialize "$cache"
  [ "$status" -ne 0 ]
  output_has "symlink $cache/shared/includes/zz-out.md points outside $cache/shared"
  output_has "Could not scan the Claude cache for unresolved reviewer lanes"
  # …and an agent link out of skills/ is refused by the materialiser itself, before any rewrite.
  cache="$BATS_TEST_TMPDIR/claude-cache-agentout"
  claude_cache_copy "$cache"
  mkdir -p "$cache/skills/zz-out/agents"
  ln -s "$BATS_TEST_TMPDIR/outside/zz-out.md" "$cache/skills/zz-out/agents/zz-out.md"
  cp -Rp "$cache" "$cache.snap"
  run claude_materialize "$cache"
  [ "$status" -ne 0 ]
  output_has "materialize failed"
  output_has "symlink $cache/skills/zz-out/agents/zz-out.md points outside $cache/skills"
  diff -r "$cache.snap" "$cache"
}

@test "Claude cache: a lane left as a MODEL in any spelling, anywhere, fails the install naming file:line" {
  local cache="$BATS_TEST_TMPDIR/claude-cache" fx pristine="$BATS_TEST_TMPDIR/pristine" n
  claude_cache_copy "$cache"
  fx="$cache/skills/zz-lane-fixture/agents"
  plant_lane_fixtures "$fx"
  plant_lane_fixtures "$pristine"
  printf '%s\n' '---' 'name: zz-lane-fixture' 'model: review-alt' '---' 'body' > "$cache/shared/includes/zz-lane-fixture.md"
  # A lane behind a SYMLINK inside the scanned tree, in a file the materialiser does not own: the scan
  # follows the link, so it is reported under the link's own path.
  printf '%s\n' '---' 'name: zz-linked' 'model: review-primary' '---' > "$cache/shared/includes/lane-target.txt"
  ln -s lane-target.txt "$cache/shared/includes/zz-linked.md"
  run claude_materialize "$cache"
  [ "$status" -ne 0 ]
  # Every path below is ABSOLUTE, as the install prints them: HIT_REPORTED (11) + two shared includes.
  output_has "Abstract reviewer lanes remain in Claude cache: 13 leftover lane reference(s)"
  output_has "$cache/shared/includes/zz-lane-fixture.md:3:"
  output_has "$cache/shared/includes/zz-linked.md:3:"
  for n in $HIT_REPORTED; do output_has "$fx/$n.md:4:" || return 1; done
  for n in $HIT_REWRITTEN $MISS_ALWAYS; do output_lacks "$fx/$n.md:" || return 1; done
  output_lacks "lane-target.txt:"
  # …and what the strict rewriter DID take, it rewrote as a whole token, comment untouched — the WHOLE
  # file compared with its pristine copy, not only the line; what it did not take, it left byte for byte.
  rewrite_of "$pristine/fx-plain.md" 'model: opus' "$fx/fx-plain.md"
  rewrite_of "$pristine/fx-plainalt.md" 'model: sonnet' "$fx/fx-plainalt.md"
  rewrite_of "$pristine/fx-comment.md" 'model: opus # the lane review-alt, kept in the comment' "$fx/fx-comment.md"
  rewrite_of "$pristine/fx-crlf.md" "$(printf 'model: sonnet\r')" "$fx/fx-crlf.md"
  for n in $HIT_REPORTED $MISS_ALWAYS; do cmp "$pristine/$n.md" "$fx/$n.md" || return 1; done
}

@test "Claude cache fails closed: a scan that cannot read stops the install, and shows what it had found" {
  local cache="$BATS_TEST_TMPDIR/claude-cache"
  claude_cache_copy "$cache"
  printf '%s\n' '---' 'name: zz-unscannable' '---' 'body' > "$cache/shared/includes/zz-unscannable.md"
  printf '%s\n' '---' 'name: zz-lane' 'model: review-alt' '---' 'body' > "$cache/shared/includes/zz-lane.md"
  awk_stub "$BATS_TEST_TMPDIR/awk-stub" after "$cache/shared/includes/zz-unscannable.md"
  export ZT_STUB_PATH="$BATS_TEST_TMPDIR/awk-stub"
  run claude_materialize "$cache"
  [ "$status" -ne 0 ]
  output_has "awk-stub: cannot read $cache/shared/includes/zz-unscannable.md"
  output_has "Could not scan the Claude cache for unresolved reviewer lanes"
  output_has "found before it stopped"
  output_has "$cache/shared/includes/zz-lane.md:3:model: review-alt"
}

@test "Claude cache fails closed: a rewrite that cannot land stops the install at THAT file and changes nothing" {
  local cache="$BATS_TEST_TMPDIR/claude-cache-mv" snap="$BATS_TEST_TMPDIR/claude-cache-mv.snap" a target real_perl
  a="$cache/skills/zz-one/agents"
  mkdir -p "$a" "$cache/shared/includes" "$cache/rules"
  printf '%s\n' '---' 'name: aa-noop' 'model: sonnet' '---' > "$a/aa-noop.md"
  printf '%s\n' '---' 'name: mm-target' 'model: review-primary' '---' > "$a/mm-target.md"
  printf '%s\n' '---' 'name: zz-after' 'model: review-alt' '---' > "$a/zz-after.md"
  target="$a/mm-target.md"
  cp -Rp "$cache" "$snap"
  # mv refuses exactly one destination: the lane file between a file with nothing to resolve and one
  # the install must never reach.
  only_stub "$BATS_TEST_TMPDIR/mv-stub" mv "$target"
  export ZT_STUB_PATH="$BATS_TEST_TMPDIR/mv-stub"
  run claude_materialize "$cache"
  [ "$status" -ne 0 ]
  output_has "materialize failed"
  output_has "Could not resolve the reviewer lanes in $target — the install stops here"
  [ "$(cat "$BATS_TEST_TMPDIR/mv-stub/refused")" = "$target" ]
  # The WHOLE cache as it was: the refused file intact, the later one untouched, no temp file anywhere.
  diff -r "$snap" "$cache"
  # A rewriter that exits 0 but writes nothing: caught by the sanity check before anything moves.
  # The stub matches ONLY the rewriter's own invocation shape (`perl -pe ...`, fed real piped
  # content by the caller) and execs the REAL perl for anything else: materialize_claude_
  # reviewer_lanes also runs zrl_links_inside (`perl -e ... -- args`, no stdin piped at all) before
  # it ever reaches a rewrite, and a blanket "cat > /dev/null" stub that intercepted THAT call too
  # left it reading a stdin nobody closes -- a 60-minute hang in this exact test, diagnosed and
  # unblocked by hand (fix round 4, coordinator diagnosis of the round's first full-suite run).
  # `timeout` bounds even the matched branch, in case a future caller shape slips past the match;
  # it degrades to no bound (never to a blind stdin read) when `timeout` is not on PATH.
  real_perl="$(command -v perl)"
  mkdir -p "$BATS_TEST_TMPDIR/perl-stub"
  printf '#!/bin/sh\nif [ "$1" = "-pe" ]; then\n  if command -v timeout >/dev/null 2>&1; then timeout 5 cat > /dev/null; else cat > /dev/null; fi\n  exit 0\nfi\nexec "%s" "$@"\n' \
    "$real_perl" > "$BATS_TEST_TMPDIR/perl-stub/perl"
  chmod +x "$BATS_TEST_TMPDIR/perl-stub/perl"
  export ZT_STUB_PATH="$BATS_TEST_TMPDIR/perl-stub"
  run claude_materialize "$cache"
  [ "$status" -ne 0 ]
  output_has "Could not resolve the reviewer lanes in $a/aa-noop.md — the install stops here"
  output_has "came out empty"
  diff -r "$snap" "$cache"
}

@test "reviewer-lanes: the strict rewriter takes a whole lane token in a column-0 frontmatter model key, nothing else" {
  local d="$BATS_TEST_TMPDIR/fx" out="$BATS_TEST_TMPDIR/fx-out" n
  plant_lane_fixtures "$d"
  mkdir -p "$out"
  for n in $HIT_REWRITTEN $HIT_REPORTED $MISS_ALWAYS; do
    lanes zrl_rewrite_lanes P1 A1 < "$d/$n.md" > "$out/$n.md" || { echo "rewriter failed on $n" >&2; return 1; }
  done
  # BOTH replacement ids land, each on its own lane — and nothing else in the file moves.
  rewrite_of "$d/fx-plain.md" 'model: P1' "$out/fx-plain.md"
  rewrite_of "$d/fx-plainalt.md" 'model: A1' "$out/fx-plainalt.md"
  rewrite_of "$d/fx-comment.md" 'model: P1 # the lane review-alt, kept in the comment' "$out/fx-comment.md"
  rewrite_of "$d/fx-crlf.md" "$(printf 'model: A1\r')" "$out/fx-crlf.md"
  for n in $HIT_REPORTED $MISS_ALWAYS; do
    cmp -s "$d/$n.md" "$out/$n.md" || { echo "the strict rewriter changed $n" >&2; diff "$d/$n.md" "$out/$n.md" >&2; return 1; }
  done
  # The replacement ids are checked, so a caller cannot write a broken model key into a file.
  run lanes zrl_rewrite_lanes 'bad id' A1 < "$d/fx-plain.md"
  [ "$status" -ne 0 ]
  run lanes zrl_rewrite_lanes P1 'a;b' < "$d/fx-plain.md"
  [ "$status" -ne 0 ]
}

@test "reviewer-lanes: an in-place rewrite is atomic — concurrent calls do not collide, a bad rewrite changes nothing" {
  local d="$BATS_TEST_TMPDIR/conc" pristine="$BATS_TEST_TMPDIR/conc-pristine" stub="$BATS_TEST_TMPDIR/perl-gate" real
  plant_lane_fixtures "$d"
  plant_lane_fixtures "$pristine"
  real="$(command -v perl)"
  mkdir -p "$stub"
  # A perl that waits at a gate, so two rewrites of ONE file are both mid-flight at the same time.
  printf '#!/bin/sh\ntouch "%s/started.$$"\nwhile [ ! -e "%s/release" ]; do sleep 0.1; done\nexec "%s" "$@"\n' "$stub" "$stub" "$real" > "$stub/perl"
  chmod +x "$stub/perl"
  run env PATH="$stub:$PATH" bash -c '. "$1" || exit 97; . "$2" || exit 97
    zrl_rewrite_lanes_file P1 A1 "$3" & a=$!
    zrl_rewrite_lanes_file P1 A1 "$3" & b=$!
    n=0; while [ "$(ls "$4" | grep -c "^started\.")" -lt 2 ] && [ "$n" -lt 200 ]; do sleep 0.1; n=$((n + 1)); done
    touch "$4/release"
    wait "$a"; ra=$?; wait "$b"; rb=$?
    echo "ra=$ra rb=$rb"' _ "$REPO_ROOT/scripts/lib/portable.sh" "$LANES_LIB" "$d/fx-plain.md" "$stub"
  output_has "ra=0 rb=0"
  # After BOTH writers: the whole file is exactly one clean rewrite — not two interleaved, not truncated.
  rewrite_of "$pristine/fx-plain.md" 'model: P1' "$d/fx-plain.md"
  run ls -A "$d"
  output_lacks ".zrl"
  output_lacks "zrl-tmp"
  # A rewriter that exits 0 with nothing, or that loses a line: the file stays as it was, the call fails.
  mkdir -p "$BATS_TEST_TMPDIR/perl-empty" "$BATS_TEST_TMPDIR/perl-short"
  # Same hardening as the Claude-cache mv/perl test above (fix round 4): match the rewriter's own
  # `-pe` shape and exec the real perl for anything else, bounded by `timeout` when available. This
  # stub is only ever driven through zrl_rewrite_lanes_file directly here (never
  # materialize_claude_reviewer_lanes / zrl_links_inside), so it was never exposed to that hang --
  # matched narrowly anyway so a future reuse of this stub does not reintroduce it.
  printf '#!/bin/sh\nif [ "$1" = "-pe" ]; then\n  if command -v timeout >/dev/null 2>&1; then timeout 5 cat > /dev/null; else cat > /dev/null; fi\n  exit 0\nfi\nexec "%s" "$@"\n' "$real" > "$BATS_TEST_TMPDIR/perl-empty/perl"
  printf '#!/bin/sh\n"%s" "$@" | sed \x27$d\x27\n' "$real" > "$BATS_TEST_TMPDIR/perl-short/perl"
  chmod +x "$BATS_TEST_TMPDIR/perl-empty/perl" "$BATS_TEST_TMPDIR/perl-short/perl"
  cp -p "$d/fx-plainalt.md" "$BATS_TEST_TMPDIR/before.md"
  for stub in perl-empty perl-short; do
    run env PATH="$BATS_TEST_TMPDIR/$stub:$PATH" bash -c '. "$1" || exit 97; . "$2" || exit 97; zrl_rewrite_lanes_file P1 A1 "$3"' \
        _ "$REPO_ROOT/scripts/lib/portable.sh" "$LANES_LIB" "$d/fx-plainalt.md"
    [ "$status" -ne 0 ] || { echo "$stub: the call passed" >&2; return 1; }
    output_has "could not rewrite $d/fx-plainalt.md" || return 1
    cmp "$BATS_TEST_TMPDIR/before.md" "$d/fx-plainalt.md" || return 1
  done
  run ls -A "$d"
  output_lacks ".zrl"
}

@test "reviewer-lanes: an in-place rewrite keeps the mode, leaves a lane-free file untouched, and replaces only the first link" {
  local d="$BATS_TEST_TMPDIR/keep" pristine="$BATS_TEST_TMPDIR/keep-pristine" stub="$BATS_TEST_TMPDIR/mktemp-spy" real before after
  plant_lane_fixtures "$d"
  plant_lane_fixtures "$pristine"
  # The file's mode survives the rewrite (the temp file mktemp makes is 0600).
  chmod 0640 "$d/fx-plain.md"
  run lanes zrl_rewrite_lanes_file P1 A1 "$d/fx-plain.md"
  [ "$status" -eq 0 ]
  [ "$(ls -l "$d/fx-plain.md" | cut -c1-10)" = "-rw-r-----" ] || { ls -l "$d/fx-plain.md" >&2; return 1; }
  rewrite_of "$pristine/fx-plain.md" 'model: P1' "$d/fx-plain.md"
  # A file with no lane is not rewritten at all: same inode, same mtime, and no temp file is even made.
  real="$(command -v mktemp)"
  mkdir -p "$stub"
  printf '#!/bin/sh\necho "$*" >> "%s/calls"\nexec "%s" "$@"\n' "$stub" "$real" > "$stub/mktemp"
  chmod +x "$stub/mktemp"
  touch -t 202001010000 "$d/fx-body.md"
  before="$(ls -li "$d/fx-body.md" | awk '{print $1, $7, $8, $9}')"
  run env PATH="$stub:$PATH" bash -c '. "$1" || exit 97; . "$2" || exit 97; zrl_rewrite_lanes_file P1 A1 "$3"' \
      _ "$REPO_ROOT/scripts/lib/portable.sh" "$LANES_LIB" "$d/fx-body.md"
  [ "$status" -eq 0 ]
  after="$(ls -li "$d/fx-body.md" | awk '{print $1, $7, $8, $9}')"
  [ "$before" = "$after" ] || { echo "inode/mtime changed: [$before] -> [$after]" >&2; return 1; }
  [ ! -e "$stub/calls" ] || { echo "a temp file was made: $(cat "$stub/calls")" >&2; return 1; }
  cmp "$pristine/fx-body.md" "$d/fx-body.md"
  # A CHAIN of links inside the tree (link1 -> link2 -> file): the rewrite replaces link1 with the
  # resolved, rewritten file; link2 and the file it names are left exactly as they were.
  cp "$pristine/fx-plainalt.md" "$d/chain-target.txt"
  ln -s chain-target.txt "$d/chain2.md"
  ln -s chain2.md "$d/chain1.md"
  run lanes zrl_rewrite_lanes_file P1 A1 "$d/chain1.md"
  [ "$status" -eq 0 ]
  [ ! -L "$d/chain1.md" ]
  rewrite_of "$pristine/fx-plainalt.md" 'model: A1' "$d/chain1.md"
  [ -L "$d/chain2.md" ] && [ "$(readlink "$d/chain2.md")" = chain-target.txt ]
  cmp "$pristine/fx-plainalt.md" "$d/chain-target.txt"
}

@test "reviewer-lanes: the lenient validator reports every spelling of a lane model key, never prose or a longer id" {
  local d="$BATS_TEST_TMPDIR/fx" n
  plant_lane_fixtures "$d"
  # A symlinked .md INSIDE the scanned tree is followed — through a chain of two links, too — and
  # reported under each link's own path; the target (no .md name) is not scanned on its own.
  printf '%s\n' '---' 'name: zz-linked' 'model: review-primary' '---' > "$d/lane-target.txt"
  ln -s lane-target.txt "$d/fx-link2.md"
  ln -s fx-link2.md "$d/fx-link.md"
  run lanes zrl_scan_md "$d"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  for n in $HIT_REWRITTEN $HIT_REPORTED; do output_has "$d/$n.md:4:" || return 1; done
  output_has "$d/fx-link.md:3:"
  output_has "$d/fx-link2.md:3:"
  output_lacks "lane-target.txt:"
  output_has "$d/fx-block.md:4:model: >  [model value not parsed"
  for n in $MISS_ALWAYS; do output_lacks "$d/$n.md:" || return 1; done
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 17 ] || { printf 'expected 17 hits:\n%s\n' "$output" >&2; return 1; }
  # Other route words and letter cases are route words too; a model id that merely CONTAINS one is not.
  for n in review-primary Review-Alt CROSS-VENDOR in-family-fallback same-model-fallback routing-failed; do
    lanes zrl_is_route_word "$n" || { echo "[$n] not taken as a route word" >&2; return 1; }
  done
  for n in opus gpt-6-sol review-primary-test '' 'review-alt x'; do
    ! lanes zrl_is_route_word "$n" || { echo "[$n] taken as a route word" >&2; return 1; }
  done
  # …whatever IFS the caller left behind.
  run bash -c '. "$1" || exit 97; . "$2" || exit 97; IFS=,; zrl_is_route_word review-alt && echo ROUTE' _ \
      "$REPO_ROOT/scripts/lib/portable.sh" "$LANES_LIB"
  output_has ROUTE
}

@test "reviewer-lanes: TOML model keys are parsed in any quoting and spacing, by the scan and by the value reader" {
  local d="$BATS_TEST_TMPDIR/toml"
  mkdir -p "$d"
  printf '%s\n' 'name = "a"' 'model="review-alt"' > "$d/t-dq.toml"
  printf '%s\n' "model = 'Review-Primary'" > "$d/t-sq.toml"
  printf '%s\n' '  model   =   "cross-vendor"   # c' > "$d/t-sp.toml"
  printf '%s\n' 'model = "review-alt\"x"' > "$d/t-esc.toml"
  printf '%s\n' 'model = """review-alt"""' > "$d/t-triple.toml"
  printf '%s\n' 'model = """' 'review-alt' '"""' > "$d/t-multi.toml"
  printf '%s\n' 'model = "gpt-6-sol"' > "$d/t-ok.toml"
  printf '%s\n' 'model = "gpt-6-sol" # was review-alt' > "$d/t-okcomment.toml"
  printf '%s\n' 'name = "review-alt"' "model='gpt-x:1'" > "$d/t-name.toml"
  printf '%s\n' 'name = "no model key"' > "$d/t-none.toml"
  printf '%s\n' 'model = "gpt-6-sol"' 'model = "gpt-6-luna"' > "$d/t-dup.toml"
  run lanes zrl_scan_toml "$d"/*.toml
  [ "$status" -eq 0 ]
  output_has "$d/t-dq.toml:2:"
  output_has "$d/t-sq.toml:1:"
  output_has "$d/t-sp.toml:1:"
  output_has "$d/t-esc.toml:1:"
  output_has "$d/t-triple.toml:1:"
  # A multi-line value this line scanner cannot read is reported, never passed.
  output_has "$d/t-multi.toml:1:model = \"\"\"  [model value not parsed"
  output_lacks "t-ok.toml"
  output_lacks "t-okcomment.toml"
  output_lacks "t-name.toml"
  run lanes zrl_toml_model "$d/t-name.toml";  [ "$output" = gpt-x:1 ]
  run lanes zrl_toml_model "$d/t-sp.toml";    [ "$output" = cross-vendor ]
  run lanes zrl_toml_model "$d/t-dq.toml";    [ "$output" = review-alt ]
  run lanes zrl_toml_model "$d/t-ok.toml";    [ "$output" = gpt-6-sol ]
  run lanes zrl_toml_model "$d/t-none.toml";  [ "$status" -ne 0 ]
  # Duplicate keys are invalid TOML: an error (status 3), never "the first one wins".
  run lanes zrl_toml_model "$d/t-dup.toml"
  [ "$status" -eq 3 ]
  output_has "more than one model key"
  # A value the reader cannot parse is an error (status 4), never its first token: an unclosed quote,
  # a multi-line string.
  printf '%s\n' 'model = "gpt-6-sol' > "$d/t-unclosed.toml"
  run lanes zrl_toml_model "$d/t-unclosed.toml"
  [ "$status" -eq 4 ] || { echo "t-unclosed: status $status, output [$output]" >&2; return 1; }
  output_has "could not be read"
  run lanes zrl_toml_model "$d/t-multi.toml"
  [ "$status" -eq 4 ]
}

@test "reviewer-lanes: every scan fails closed — nothing to scan, a missing path, no file, a file it cannot read" {
  local d="$BATS_TEST_TMPDIR/fx"
  plant_lane_fixtures "$d"
  run lanes zrl_scan_md
  [ "$status" -ne 0 ]; output_has "nothing to scan"
  run lanes zrl_scan_md "$d" "$BATS_TEST_TMPDIR/no-such-dir"
  [ "$status" -ne 0 ]; output_has "scan path missing: $BATS_TEST_TMPDIR/no-such-dir"
  mkdir -p "$BATS_TEST_TMPDIR/no-md"
  printf 'x\n' > "$BATS_TEST_TMPDIR/no-md/readme.txt"
  run lanes zrl_scan_md "$BATS_TEST_TMPDIR/no-md"
  [ "$status" -ne 0 ]; output_has "no .md file under"
  run lanes zrl_scan_toml
  [ "$status" -ne 0 ]; output_has "no TOML to scan"
  run lanes zrl_scan_toml "$BATS_TEST_TMPDIR/no-such.toml"
  [ "$status" -ne 0 ]; output_has "scan path missing: $BATS_TEST_TMPDIR/no-such.toml"
  awk_stub "$BATS_TEST_TMPDIR/awk-stub" before "$d/fx-body.md"
  run env PATH="$BATS_TEST_TMPDIR/awk-stub:$PATH" bash -c '. "$1" || exit 97; . "$2" || exit 97; zrl_scan_md "$3"' \
      _ "$REPO_ROOT/scripts/lib/portable.sh" "$LANES_LIB" "$d"
  [ "$status" -ne 0 ]; output_has "awk-stub: cannot read $d/fx-body.md"; output_has "the scan of [$d] did not complete"
  run env PATH="$BATS_TEST_TMPDIR/awk-stub:$PATH" bash -c '. "$1" || exit 97; . "$2" || exit 97; zrl_scan_toml "$3"' \
      _ "$REPO_ROOT/scripts/lib/portable.sh" "$LANES_LIB" "$d/fx-body.md"
  [ "$status" -ne 0 ]; output_has "awk-stub: cannot read $d/fx-body.md"; output_has "the TOML scan did not complete"
}

@test "reviewer-lanes: the scan fails closed on what find cannot walk, a symlink cycle, and a link out of the tree" {
  local u="$BATS_TEST_TMPDIR/unreadable" l="$BATS_TEST_TMPDIR/loop" o="$BATS_TEST_TMPDIR/out-tree"
  # Every .md sits in a directory find cannot read: that is a failed walk, NEVER "no .md file".
  mkdir -p "$u/locked"
  printf '%s\n' '---' 'model: review-alt' '---' > "$u/locked/a.md"
  chmod 000 "$u/locked"
  export ZT_UNREADABLE="$u/locked"
  if [ -r "$u/locked" ]; then
    chmod 755 "$u/locked"
    skip "running as a user chmod 000 cannot lock out (root?)"
  fi
  run lanes zrl_scan_md "$u"
  chmod 755 "$u/locked"
  [ "$status" -ne 0 ]
  output_has "find could not walk [$u]"
  output_lacks "no .md file under"
  # A directory link to its own ancestor: a cycle — named, and failed, whatever this find does with it
  # (GNU find reports "File system loop"; macOS find silently skips it).
  mkdir -p "$l/d"
  printf '%s\n' '---' 'model: opus' '---' > "$l/d/a.md"
  ln -s .. "$l/d/up"
  run lanes zrl_scan_md "$l"
  [ "$status" -ne 0 ]
  output_has "symlink $l/d/up is a cycle"
  # A link whose target is OUTSIDE the scanned tree: named and failed — the scan never reads outside it.
  mkdir -p "$o/tree" "$o/elsewhere"
  printf '%s\n' '---' 'model: review-alt' '---' > "$o/elsewhere/x.md"
  printf '%s\n' '---' 'model: opus' '---' > "$o/tree/ok.md"
  ln -s ../elsewhere/x.md "$o/tree/away.md"
  run lanes zrl_scan_md "$o/tree"
  [ "$status" -ne 0 ]
  output_has "symlink $o/tree/away.md points outside $o/tree"
  output_lacks "x.md:2:"
  # A link that resolves nowhere: named and failed.
  ln -s nowhere.md "$o/tree/dangling.md"
  run lanes zrl_scan_md "$o/tree"
  [ "$status" -ne 0 ]
  output_has "symlink $o/tree/dangling.md does not resolve"
}

@test "reviewer-lanes: a model id is exactly what the router's is_model_id accepts, in every locale" {
  local id loc locales="C" u parity="$BATS_TEST_TMPDIR/id-parity.sh"
  for id in gpt-6-sol gpt-x:1 claude-opus-5-5 opus a.b_c 5x A0._:-Z9; do
    lanes zrl_is_model_id "$id" || { echo "[$id] rejected" >&2; return 1; }
  done
  for id in '' 'gpt x' '-x' '.x' ':x' 'a/b' 'x$' 'x*' 'x?' 'x=y' 'a;b' 'a&b' 'a`b' 'a$(b)' "$(printf 'gpt-\303\251')" "$(printf 'a\nb')"; do
    ! lanes zrl_is_model_id "$id" || { echo "[$id] accepted" >&2; return 1; }
  done
  # The WRAPPER forwards verbatim: zrl_is_model_id is a thin wrapper over zms_is_model_id (the one
  # model-id definition, scripts/lib/model-subprocess.sh), and must give the same verdict on every probe —
  # under LC_ALL=C and under a UTF-8 locale. This checks the wrapper only; that the router, preflight and
  # model-run have no id charset of their own is test-reviewer-preflight-isolation.sh 0g's job.
  {
    printf '. "%s" || exit 97\n' "$LANES_LIB"
    cat <<'PARITY'
declare -F zms_is_model_id >/dev/null || { echo "zms_is_model_id not defined after sourcing the lane library"; exit 1; }
rc=0
for p in gpt-6-sol gpt-x:1 opus A0._:-Z9 5x '' 'gpt x' '-x' '.x' ':x' 'a/b' 'x$' 'x*' 'x?' 'x=y' 'a;b' 'a&b' 'a`b' 'a$(b)' $'gpt-\xc3\xa9' $'a\nb' $'cr\rhere'; do
  r=0; z=0
  zms_is_model_id "$p" && r=1
  zrl_is_model_id "$p" && z=1
  if [ "$r" != "$z" ]; then printf 'MISMATCH [%q] zms=%s lanes=%s\n' "$p" "$r" "$z"; rc=1; fi
done
exit $rc
PARITY
  } > "$parity"
  u="$(locale -a 2>/dev/null | awk 'tolower($0) ~ /utf-?8/ && tolower($0) ~ /^en_us/ {print; exit}')"
  [ -n "$u" ] && locales="C $u"
  for loc in $locales; do
    run env LC_ALL="$loc" bash "$parity"
    [ "$status" -eq 0 ] || { echo "parity under $loc: $output" >&2; return 1; }
  done
}

@test "Cursor build degrades both reviewer lanes to inherit; prose keeps the router's lane words" {
  # env -u ZUVO_DIST_CACHE (W9): under tests/run-all.sh, ZUVO_DIST_CACHE names a cache SHARED
  # with every other test file. --fresh drops and rebuilds this platform's cache entry as a
  # side effect, which would race a concurrent reader of that same shared entry -- every
  # fixture test in this file already opts out for exactly this reason; this real-build test
  # must too.
  run env -u ZUVO_DIST_CACHE bash "$REPO_ROOT/tests/lib/dist-build.sh" --fresh cursor
  [ "$status" -eq 0 ]

  local primary="$ZUVO_DIST_ROOT/cursor/agents/write-tests-blind-coverage-auditor.md"
  local alt="$ZUVO_DIST_ROOT/cursor/agents/write-tests-blind-coverage-auditor-alt.md"
  local fallback_primary="$ZUVO_DIST_ROOT/cursor/agents/write-tests-adversarial-test-reviewer.md"
  local fallback_alt="$ZUVO_DIST_ROOT/cursor/agents/write-tests-adversarial-test-reviewer-alt.md"

  [ -f "$primary" ]
  [ -f "$alt" ]
  [ -f "$fallback_primary" ]
  [ -f "$fallback_alt" ]
  run rg -n 'review-primary|review-alt' "$primary" "$alt" "$fallback_primary" "$fallback_alt"
  [ "$status" -eq 1 ]
  run rg -n '^model: inherit$' "$primary" "$alt" "$fallback_primary" "$fallback_alt"
  [ "$status" -eq 0 ]
  # plan C Task 4: the build used to rewrite review-primary/review-alt/cross-vendor EVERYWHERE
  # (a dist-wide regex), so the installed copy of these router-vocabulary docs disagreed with the
  # router they document. Only agent frontmatter may resolve a lane to a model.
  docs_keep_lane_words "$ZUVO_DIST_ROOT/cursor"
}

@test "Antigravity build materializes reviewer lanes to Gemini tiers; prose keeps the router's lane words" {
  # env -u ZUVO_DIST_CACHE (W9): see the Cursor test above -- same shared-cache race.
  run env -u ZUVO_DIST_CACHE bash "$REPO_ROOT/tests/lib/dist-build.sh" --fresh antigravity
  [ "$status" -eq 0 ]

  local primary="$ZUVO_DIST_ROOT/antigravity/skills/write-tests/agents/blind-coverage-auditor.md"
  local alt="$ZUVO_DIST_ROOT/antigravity/skills/write-tests/agents/blind-coverage-auditor-alt.md"
  local fallback_primary="$ZUVO_DIST_ROOT/antigravity/skills/write-tests/agents/adversarial-test-reviewer.md"
  local fallback_alt="$ZUVO_DIST_ROOT/antigravity/skills/write-tests/agents/adversarial-test-reviewer-alt.md"

  [ -f "$primary" ]
  [ -f "$alt" ]
  [ -f "$fallback_primary" ]
  [ -f "$fallback_alt" ]
  run rg -n 'review-primary|review-alt' "$primary" "$alt" "$fallback_primary" "$fallback_alt"
  [ "$status" -eq 1 ]
  run rg -n '^model: gemini-3.1-pro-high$' "$primary" "$fallback_primary"
  [ "$status" -eq 0 ]
  run rg -n '^model: gemini-3.1-pro-low$' "$alt" "$fallback_alt"
  [ "$status" -eq 0 ]
  docs_keep_lane_words "$ZUVO_DIST_ROOT/antigravity"
}

@test "Kimi build materializes reviewer lanes to model_preference primary|secondary; prose keeps the router's lane words" {
  # env -u ZUVO_DIST_CACHE (W9/f5-87): this call ran without it, unlike every fixture test in
  # this file -- under tests/run-all.sh's shared ZUVO_DIST_CACHE, --fresh's drop-then-rebuild
  # of the "kimi" cache entry races any concurrent reader of that same shared entry. See the
  # Cursor test above for the reproduction.
  run env -u ZUVO_DIST_CACHE bash "$REPO_ROOT/tests/lib/dist-build.sh" --fresh kimi
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20 >&2; return 1; }

  local primary="$ZUVO_DIST_ROOT/kimi/agents/write-tests-blind-coverage-auditor.md"
  local alt="$ZUVO_DIST_ROOT/kimi/agents/write-tests-blind-coverage-auditor-alt.md"
  local fallback_primary="$ZUVO_DIST_ROOT/kimi/agents/write-tests-adversarial-test-reviewer.md"
  local fallback_alt="$ZUVO_DIST_ROOT/kimi/agents/write-tests-adversarial-test-reviewer-alt.md"

  [ -f "$primary" ]
  [ -f "$alt" ]
  [ -f "$fallback_primary" ]
  [ -f "$fallback_alt" ]
  run rg -n 'review-primary|review-alt' "$primary" "$alt" "$fallback_primary" "$fallback_alt"
  [ "$status" -eq 1 ]
  # No plain `model:` key survives — Kimi always RENAMES the key, never just resolves the value.
  run rg -n '^model:' "$primary" "$alt" "$fallback_primary" "$fallback_alt"
  [ "$status" -eq 1 ]
  run rg -n '^model_preference: primary$' "$primary" "$fallback_primary"
  [ "$status" -eq 0 ]
  run rg -n '^model_preference: secondary$' "$alt" "$fallback_alt"
  [ "$status" -eq 0 ]
  docs_keep_lane_words "$ZUVO_DIST_ROOT/kimi"
}

# ── plan C Task 8: test-audit's batch dispatch survives every build byte for byte ─────────────────
# Build regex transforms fail silently (Quality Strategy), and the builds rewrite paths, tool names,
# model words, host names and unicode across the whole SKILL.md. The shell of the dispatch lives in
# scripts/zuvo-home/test-audit-batch, installed once per machine as ~/.zuvo/test-audit-batch by
# install_zuvo_home (no build copies scripts/zuvo-home; tests/hooks/test-install-wiring.sh (12m) holds
# that the installed copy is byte-identical and runs). What a dist carries is the CALLS, run by the
# orchestrator as written — a `~/.zuvo` path turned into `~/.codex`, or a rewritten `"$PPID"`, would pass
# every prose check and break at run time. So the assertions are on the BUILT files:
#   - the setup call and the group call inside 1a, each exactly once, and BOTH 1a ```bash blocks, are
#     identical to the source's; so is 1d's save call block;
#   - the 1a heading still names Claude and Codex (the Kimi/Antigravity builds rewrite "Claude Code" to
#     their own host name, which would pull that host onto the model-run route — X7);
#   - the batch prompt include ships, and equals the SOURCE after the builds' own unicode normalisation
#     (normalize_unicode, one map shared by all four build scripts — read from build-codex-skills.sh,
#     never re-typed), byte for byte including the final newline.
# Sections are cut with a CommonMark fence tracker: a `### 1b.` inside a code block does not end 1a,
# and a call must be found INSIDE its section.
# The RED cases below plant a mangled dist and prove each assertion fails on it.
# TA_FENCE_AWK — the CommonMark fence tracker the helpers share (B1): 0-3 spaces then 3+
# backticks or tildes; a backtick opener carries no backtick in its info string; it closes only on
# the SAME character with a run at least as long; a trailing CR is ignored.
TA_FENCE_AWK='
function trimmed(s) { sub(/\r$/, "", s); sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function fstep(line,    l, s) {
  l = line; sub(/\r$/, "", l)
  if (!infc) {
    if (match(l, /^ ? ? ?(````*|~~~~*)/)) {
      s = substr(l, RSTART, RLENGTH); sub(/^ +/, "", s)
      if (substr(s, 1, 1) == "`" && index(substr(l, RSTART + RLENGTH), "`")) return 0
      fch = substr(s, 1, 1); flen = length(s); infc = 1; return 1
    }
    return 0
  }
  if (match(l, /^ ? ? ?(````*|~~~~*)[ \t]*$/)) {
    s = substr(l, RSTART, RLENGTH); sub(/^ +/, "", s); sub(/[ \t]+$/, "", s)
    if (substr(s, 1, 1) == fch && length(s) >= flen) { infc = 0; return 2 }
  }
  return 0
}
'
TA_SETUP_CALL='~/.zuvo/test-audit-batch setup --owner "$PPID" --nbatch "$NBATCH" --token "$RUN_TOKEN"'
TA_GROUP_CALL='~/.zuvo/test-audit-batch group --owner "$PPID" --nbatch "$NBATCH" --first "$FIRST" --token "$RUN_TOKEN"'
TA_SAVE_CALL='~/.zuvo/test-audit-batch save --batch "$N"'
# The release call is INLINE prose in 1a (the orchestrator runs it on every non-lock STOP), not a fenced
# command line, so it is matched as a substring — the same count on both sides.
TA_RELEASE_CALL='~/.zuvo/test-audit-batch release --owner "$PPID" --token'
# testaudit_section <file> <start-prefix> <end-prefix> — the section from the heading starting with
# <start-prefix> to the line before the one starting with <end-prefix>, headings inside fenced code
# ignored; exit 1 if absent/unterminated.
testaudit_section() {
  awk -v s="$2" -v e="$3" "$TA_FENCE_AWK"'
    { was = infc; st = fstep($0); outside = (!was && st == 0) }
    outside && index($0, s) == 1 { on = 1 }
    on && outside && index($0, e) == 1 { done = 1; exit }
    on { print }
    END { exit !(on && done) }' "$1"
}
testaudit_1a_section() { testaudit_section "$1" '### 1a.' '### 1b.'; }
testaudit_1d_section() { testaudit_section "$1" '### 1d.' '## Phase 2:'; }
# testaudit_call_count <section-text> <sub> — how many `~/.zuvo/test-audit-batch <sub> ` command lines
# the section holds INSIDE fenced code (a duplicated call must show; prose naming it does not count).
testaudit_call_count() {
  printf '%s\n' "$1" | awk -v c="~/.zuvo/test-audit-batch $2 " "$TA_FENCE_AWK"'
    { was = infc; st = fstep($0) }
    was && st == 0 && index($0, c) == 1 { n++ }
    END { print n + 0 }'
}
testaudit_bash_blocks() {  # every ```bash block of the section text on stdin, fences included (same tracker)
  awk "$TA_FENCE_AWK"'
    { was = infc; st = fstep($0) }
    st == 1 && trimmed($0) == "```bash" { b = 1 }
    b { print }
    b && st == 2 { b = 0 }
    END { exit (infc != 0) }'
}
# TA_NORM_MAP — the unicode normalisation the builds are observed to apply (B2), written out HERE,
# independently of the build scripts, and used as the oracle. The separate test below proves each
# build's own normalize_unicode() produces exactly this map on every character it lists.
testaudit_normalize() {
  sed -e 's/—/--/g' -e 's/–/-/g' -e 's/→/->/g' -e 's/✅/[x]/g' -e 's/❌/[ ]/g' -e 's/━/-/g' \
      -e 's/═/=/g' -e 's/≤/<=/g' -e 's/≥/>=/g' -e 's/≠/!=/g' -e 's/⚠️/[!]/g' -e 's/⚠/[!]/g' \
      -e 's/⏭️/[SKIP]/g' -e 's/⏭/[SKIP]/g' -e 's/❓/[?]/g'
}

# assert_testaudit_dist <label> <dist-root-of-one-platform>
assert_testaudit_dist() {
  local p="$1" dist="$2"
  local src="$REPO_ROOT/skills/test-audit/SKILL.md" built="$dist/skills/test-audit/SKILL.md"
  local isrc="$REPO_ROOT/shared/includes/test-audit-batch-prompt.md" ibuilt="$dist/shared/includes/test-audit-batch-prompt.md"
  local s1a b1a s1d b1d want got sub call n
  [ -f "$built" ] || { echo "$p: no built test-audit SKILL.md at $built" >&2; return 1; }
  b1a="$(testaudit_1a_section "$built")" || { echo "$p: section 1a (### 1a. .. ### 1b., outside code) not found in the built SKILL.md" >&2; return 1; }
  s1a="$(testaudit_1a_section "$src")" || { echo "source: section 1a not found" >&2; return 1; }
  for sub in setup group; do
    case "$sub" in setup) call="$TA_SETUP_CALL" ;; *) call="$TA_GROUP_CALL" ;; esac
    # One oracle on BOTH sides, prose included: the exact call line appears once in the whole section of
    # the source and once in the built one (a duplicate injected into prose shows), and exactly once
    # inside fenced code on each side.
    [ "$(printf '%s\n' "$s1a" | grep -cxF -- "$call")" -eq 1 ] \
      || { echo "source: section 1a does not hold the $sub call exactly once: $call" >&2; return 1; }
    [ "$(testaudit_call_count "$s1a" "$sub")" -eq 1 ] \
      || { echo "source: section 1a does not hold the $sub call exactly once inside fenced code" >&2; return 1; }
    n="$(testaudit_call_count "$b1a" "$sub")"
    [ "$n" -ge 1 ] || { echo "$p: built test-audit SKILL.md lost the '~/.zuvo/test-audit-batch $sub' call from section 1a" >&2; return 1; }
    [ "$n" -eq 1 ] || { echo "$p: section 1a holds $n '~/.zuvo/test-audit-batch $sub' calls, not exactly one" >&2; return 1; }
    printf '%s\n' "$b1a" | grep -qxF -- "$call" || {
      echo "$p: a test-audit-batch call was rewritten by the build — the $sub call is no longer: $call" >&2
      printf '%s\n' "$b1a" | grep -F -- "test-audit-batch $sub " >&2
      return 1
    }
    n="$(printf '%s\n' "$b1a" | grep -cxF -- "$call")"
    [ "$n" -eq 1 ] || { echo "$p: section 1a holds the exact $sub call line $n times (prose included), not once" >&2; return 1; }
  done
  n="$(printf '%s\n' "$s1a" | grep -cF -- "$TA_RELEASE_CALL")"
  [ "$n" -ge 1 ] || { echo "source: section 1a does not name the release call: $TA_RELEASE_CALL" >&2; return 1; }
  [ "$(printf '%s\n' "$b1a" | grep -cF -- "$TA_RELEASE_CALL")" -eq "$n" ] \
    || { echo "$p: the release call in section 1a was rewritten or lost by the build: $TA_RELEASE_CALL" >&2; return 1; }
  want="$(printf '%s\n' "$s1a" | testaudit_bash_blocks)"
  got="$(printf '%s\n' "$b1a" | testaudit_bash_blocks)"
  # Counted with the extractor's own trimmed() opener test, so a fence with trailing blanks counts the same.
  [ "$(printf '%s\n' "$want" | awk "$TA_FENCE_AWK"'{ st = fstep($0) } st == 1 && trimmed($0) == "```bash" { n++ } END { print n + 0 }')" -eq 2 ] \
    || { echo "source 1a does not hold exactly two bash blocks" >&2; return 1; }
  [ "$want" = "$got" ] || {
    echo "$p: a 1a bash block was rewritten by the build" >&2
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") >&2
    return 1
  }
  s1d="$(testaudit_1d_section "$src")" || { echo "source: section 1d not found" >&2; return 1; }
  b1d="$(testaudit_1d_section "$built")" || { echo "$p: section 1d (### 1d. .. ## Phase 2:, outside code) not found in the built SKILL.md" >&2; return 1; }
  want="$(printf '%s\n' "$s1d" | testaudit_bash_blocks)"
  got="$(printf '%s\n' "$b1d" | testaudit_bash_blocks)"
  printf '%s\n' "$want" | grep -qxF -- "$TA_SAVE_CALL" || { echo "source 1d does not hold the save call: $TA_SAVE_CALL" >&2; return 1; }
  [ "$want" = "$got" ] || {
    echo "$p: the 1d save call block was rewritten by the build" >&2
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") >&2
    return 1
  }
  grep -qF -- '### 1a. Claude and Codex hosts (`platform=claude` or `platform=codex`)' "$built" \
    || { echo "$p: the 1a heading no longer names Claude and Codex hosts: $(grep -m1 '^### 1a\.' "$built")" >&2; return 1; }
  [ -s "$ibuilt" ] || { echo "$p: shared/includes/test-audit-batch-prompt.md missing from the dist" >&2; return 1; }
  local norm="$BATS_TEST_TMPDIR/ta-norm-$p.md"
  testaudit_normalize < "$isrc" > "$norm" || return 1
  cmp -s "$norm" "$ibuilt" || {
    echo "$p: the include differs from the normalised source (beyond the builds' unicode map):" >&2
    diff "$norm" "$ibuilt" | head -20 >&2
    return 1
  }
}
assert_testaudit_dispatch_survives() { assert_testaudit_dist "$1" "$ZUVO_DIST_ROOT/$1"; }

@test "Codex build: test-audit's batch dispatch calls ship unchanged, with the batch prompt include" {
  run env -u ZUVO_DIST_CACHE bash "$REPO_ROOT/tests/lib/dist-build.sh" --fresh codex
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20 >&2; return 1; }
  assert_testaudit_dispatch_survives codex
}

@test "Cursor build: test-audit's batch dispatch calls ship unchanged, with the batch prompt include" {
  run env -u ZUVO_DIST_CACHE bash "$REPO_ROOT/tests/lib/dist-build.sh" --fresh cursor
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20 >&2; return 1; }
  assert_testaudit_dispatch_survives cursor
}

@test "Antigravity build: test-audit's batch dispatch calls ship unchanged, with the batch prompt include" {
  run env -u ZUVO_DIST_CACHE bash "$REPO_ROOT/tests/lib/dist-build.sh" --fresh antigravity
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20 >&2; return 1; }
  assert_testaudit_dispatch_survives antigravity
}

@test "Kimi build: test-audit's batch dispatch calls ship unchanged, with the batch prompt include" {
  run env -u ZUVO_DIST_CACHE bash "$REPO_ROOT/tests/lib/dist-build.sh" --fresh kimi
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20 >&2; return 1; }
  assert_testaudit_dispatch_survives kimi
}

# ── RED for the dist assertion itself: a fixture "dist" holding the SOURCE files passes, and each
# planted build mangling fails it — so a green dist result means something.
testaudit_fixture_dist() {  # testaudit_fixture_dist <dir> — a dist-shaped copy of the source files
  mkdir -p "$1/skills/test-audit" "$1/shared/includes"
  cp "$REPO_ROOT/skills/test-audit/SKILL.md" "$1/skills/test-audit/SKILL.md"
  testaudit_normalize < "$REPO_ROOT/shared/includes/test-audit-batch-prompt.md" > "$1/shared/includes/test-audit-batch-prompt.md"
}
# testaudit_planted <fixture-dir> — the plant took effect: the fixture's SKILL.md differs from the source.
testaudit_planted() {
  if cmp -s "$1/skills/test-audit/SKILL.md" "$REPO_ROOT/skills/test-audit/SKILL.md"; then
    echo "the plant did not change the fixture SKILL.md" >&2; return 1
  fi
}

@test "test-audit dist assertion: an unmangled fixture passes (control)" {
  local d="$BATS_TEST_TMPDIR/ta-ok"
  testaudit_fixture_dist "$d"
  run assert_testaudit_dist fixture "$d"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "test-audit dist assertion: fails on a ~/.zuvo -> ~/.codex rewrite of the group call" {
  local d="$BATS_TEST_TMPDIR/ta-path"
  testaudit_fixture_dist "$d"
  sed -i.bak 's|^~/.zuvo/test-audit-batch group |~/.codex/test-audit-batch group |' "$d/skills/test-audit/SKILL.md"
  testaudit_planted "$d"
  run assert_testaudit_dist fixture "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"lost the '~/.zuvo/test-audit-batch group' call from section 1a"* ]]
}

@test "test-audit dist assertion: fails on a rewritten argument of a call (the owner pid)" {
  local d="$BATS_TEST_TMPDIR/ta-arg"
  testaudit_fixture_dist "$d"
  sed -i.bak 's|^\(~/.zuvo/test-audit-batch setup --owner \)"\$PPID"|\1"\$\$"|' "$d/skills/test-audit/SKILL.md"
  testaudit_planted "$d"
  run assert_testaudit_dist fixture "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"a test-audit-batch call was rewritten by the build"* ]]
}

@test "test-audit dist assertion: fails on a rewritten line in a 1a bash block outside the call" {
  local d="$BATS_TEST_TMPDIR/ta-awk"
  testaudit_fixture_dist "$d"
  sed -i.bak 's|^FIRST=1 |FIRST=2 |' "$d/skills/test-audit/SKILL.md"
  testaudit_planted "$d"
  run assert_testaudit_dist fixture "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"a 1a bash block was rewritten by the build"* ]]
}

@test "test-audit dist assertion: fails on a rewritten 1d save call" {
  local d="$BATS_TEST_TMPDIR/ta-save"
  testaudit_fixture_dist "$d"
  sed -i.bak 's|^~/.zuvo/test-audit-batch save |~/.kimi-code/test-audit-batch save |' "$d/skills/test-audit/SKILL.md"
  testaudit_planted "$d"
  run assert_testaudit_dist fixture "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the 1d save call block was rewritten by the build"* ]]
}

@test "test-audit dist assertion: fails when the host-name rewrite reaches the 1a heading (X7)" {
  local d="$BATS_TEST_TMPDIR/ta-host"
  testaudit_fixture_dist "$d"
  sed -i.bak 's|^### 1a\. Claude and Codex hosts|### 1a. Kimi Code and Codex hosts|' "$d/skills/test-audit/SKILL.md"
  run assert_testaudit_dist fixture "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the 1a heading no longer names Claude and Codex hosts"* ]]
}

@test "test-audit dist assertion: fails on a changed ASCII line of the include, and on a missing include" {
  local d="$BATS_TEST_TMPDIR/ta-inc"
  testaudit_fixture_dist "$d"
  sed -i.bak 's|^Verification context: \[VERIFICATION CONTEXT\]$|Verification context: shell available|' "$d/shared/includes/test-audit-batch-prompt.md"
  run cmp -s "$d/shared/includes/test-audit-batch-prompt.md" "$REPO_ROOT/shared/includes/test-audit-batch-prompt.md"
  [ "$status" -ne 0 ]  # the plant took effect
  run assert_testaudit_dist fixture "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the include differs from the normalised source"* ]]
  rm "$d/shared/includes/test-audit-batch-prompt.md"
  run assert_testaudit_dist fixture "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"test-audit-batch-prompt.md missing from the dist"* ]]
}

@test "test-audit dist assertion (B2): fails on a changed NON-ASCII line and on a lost final newline of the include" {
  local d="$BATS_TEST_TMPDIR/ta-inc2" f
  testaudit_fixture_dist "$d"
  f="$d/shared/includes/test-audit-batch-prompt.md"
  # a line the builds normalise (it carries a dash) — changed beyond the map
  awk '!x && index($0, "AP25:") == 1 { sub(/AP25:/, "AP25 (edited):"); x = 1 } { print }' "$f" > "$f.new" && mv "$f.new" "$f"
  run assert_testaudit_dist fixture "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the include differs from the normalised source"* ]]
  testaudit_fixture_dist "$d"
  printf '%s' "$(cat "$f")" > "$f.new" && mv "$f.new" "$f"
  run assert_testaudit_dist fixture "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the include differs from the normalised source"* ]]
}

@test "test-audit dist assertion (B1): a ### 1b. inside a code block does not end section 1a; a call outside 1a is not found" {
  local d="$BATS_TEST_TMPDIR/ta-fence" f
  testaudit_fixture_dist "$d"
  f="$d/skills/test-audit/SKILL.md"
  run testaudit_1a_section "$f"
  [ "$status" -eq 0 ]
  # a fenced "### 1b." placed before the calls: the section must run past it, and the fixture still passes
  awk '!x && index($0, "**Setup") == 1 { print "```text"; print "### 1b. not a heading"; print "```"; print ""; x = 1 } { print }' "$f" > "$f.new" && mv "$f.new" "$f"
  testaudit_planted "$d"
  run testaudit_call_count "$(testaudit_1a_section "$f")" group
  [ "$output" = 1 ]
  # the group call moved below ### 1b.: it is not "inside 1a" any more
  testaudit_fixture_dist "$d"
  awk 'index($0, "~/.zuvo/test-audit-batch group ") == 1 { hold = $0; next } { print } index($0, "### 1b.") == 1 && hold != "" { print "```bash"; print hold; print "```" }' "$f" > "$f.new" && mv "$f.new" "$f"
  run assert_testaudit_dist fixture "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"lost the '~/.zuvo/test-audit-batch group' call from section 1a"* ]]
}

@test "test-audit dist assertion: a DELETED 1a heading fails by name (item 11)" {
  local d="$BATS_TEST_TMPDIR/ta-nohead" f
  testaudit_fixture_dist "$d"
  f="$d/skills/test-audit/SKILL.md"
  awk 'index($0, "### 1a.") == 1 { next } { print }' "$f" > "$f.new" && mv "$f.new" "$f"
  run assert_testaudit_dist fixture "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"section 1a (### 1a. .. ### 1b., outside code) not found in the built SKILL.md"* ]]
}

@test "test-audit dist assertion: a MISSING built SKILL.md fails by name (item 11)" {
  local d="$BATS_TEST_TMPDIR/ta-noskill"
  testaudit_fixture_dist "$d"
  rm "$d/skills/test-audit/SKILL.md"
  run assert_testaudit_dist fixture "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no built test-audit SKILL.md at"* ]]
}

@test "test-audit dist assertion (B1): a DUPLICATED group call inside 1a fails by name" {
  local d="$BATS_TEST_TMPDIR/ta-dup" f
  testaudit_fixture_dist "$d"
  f="$d/skills/test-audit/SKILL.md"
  awk '{ print } index($0, "~/.zuvo/test-audit-batch group ") == 1 { print }' "$f" > "$f.new" && mv "$f.new" "$f"
  run assert_testaudit_dist fixture "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"section 1a holds 2 '~/.zuvo/test-audit-batch group' calls"* ]]
}

@test "test-audit dist assertion: a group call DUPLICATED into 1a's prose (outside any fence) fails by name" {
  local d="$BATS_TEST_TMPDIR/ta-dup-prose" f
  testaudit_fixture_dist "$d"
  f="$d/skills/test-audit/SKILL.md"
  TA_CALL="$TA_GROUP_CALL" awk '{ print } index($0, "### 1a.") == 1 { print ""; print ENVIRON["TA_CALL"]; print "" }' "$f" > "$f.new" && mv "$f.new" "$f"
  testaudit_planted "$d"
  run assert_testaudit_dist fixture "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"section 1a holds the exact group call line 2 times (prose included), not once"* ]]
}

# sc_normalize_map <platform> — one platform of the @test below (run for each by each_platform).
sc_normalize_map() {
  local b="$1" fn
  fn="$(awk '/^normalize_unicode\(\)/,/^}/' "$REPO_ROOT/scripts/build-$b-skills.sh")"
  [ -n "$fn" ] || { echo "$b: normalize_unicode() not found" >&2; return 1; }
  run bash -c "$fn"'
normalize_unicode' <<< "$probe"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "$want" ] || { echo "$b: its map gives [$output], the test map [$want]" >&2; return 1; }
}
@test "test-audit build maps (B2): every build's own normalize_unicode() produces exactly the test's map" {
  local probe="— – → ✅ ❌ ━ ═ ≤ ≥ ≠ ⚠️ ⚠ ⏭️ ⏭ ❓ plain" want
  want="$(printf '%s\n' "$probe" | testaudit_normalize)"
  [ "$want" != "$probe" ]
  each_platform sc_normalize_map codex cursor antigravity kimi
}

# ── Per-platform scenarios, one @test each, looped over the builds they apply to. Every build takes
# an agent through the SAME gate (zrl_agent_gate in lib/reviewer-lanes.sh) and reports leftover lanes
# through the SAME helper, so one scenario is one test; each assertion names its platform.
# each_platform <scenario> <platform...> — runs `<scenario> <platform>` for EVERY platform, then fails
# naming each platform that failed: one broken build must not hide what the others do. A scenario runs as
# a condition (errexit is off inside it), so every assertion in one ends in its own `|| return 1`.
each_platform() {
  local _ep_fn="$1" _ep_p _ep_failed=""
  shift
  for _ep_p in "$@"; do
    "$_ep_fn" "$_ep_p" || { echo "^^ $_ep_fn: platform $_ep_p FAILED" >&2; _ep_failed="$_ep_failed $_ep_p"; }
  done
  [ -z "$_ep_failed" ] || { echo "$_ep_fn failed on:$_ep_failed" >&2; return 1; }
}
# plat_label <platform> — the name a build uses for itself in its messages.
plat_label() {
  case "$1" in
    codex) echo Codex ;; cursor) echo Cursor ;; antigravity) echo Antigravity ;; kimi) echo Kimi ;;
    *) echo "plat_label: unknown platform [$1]" >&2; return 1 ;;
  esac
}
# plat_fixture <dir> <platform> [full] — codex_fixture or platform_fixture, whichever the platform needs.
plat_fixture() {
  if [ "$2" = codex ]; then codex_fixture "$1" "${3:-}"; else platform_fixture "$@"; fi
}
# plat_run_build <fixture> <root> <platform> — the build of <fixture> into <root>, via `run` (sets
# $status/$output), never through the shared dist cache.
plat_run_build() {
  mkdir -p "$2"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$2" bash "$1/tests/lib/dist-build.sh" "$3"
}
# plat_agent_md <root> <platform> <skill> <name> — where a build writes an adapted agent.
plat_agent_md() {
  case "$2" in
    antigravity) printf '%s/antigravity/skills/%s/agents/%s.md' "$1" "$3" "$4" ;;
    *) printf '%s/%s/agents/%s-%s.md' "$1" "$2" "$3" "$4" ;;
  esac
}
# plat_resolved_is <file> <platform> <source-model> — the adapted agent's frontmatter holds what that
# platform resolves <source-model> (sonnet, a per-task descriptor, review-primary or review-alt) to.
plat_resolved_is() {
  case "$2:$3" in
    cursor:*) model_is "$1" inherit ;;
    antigravity:review-primary) model_is "$1" gemini-3.1-pro-high ;;
    antigravity:*) model_is "$1" gemini-3.1-pro-low ;;
    kimi:review-alt) model_preference_is "$1" secondary ;;
    kimi:*) model_preference_is "$1" primary ;;
    *) echo "plat_resolved_is: no expectation for [$2:$3]" >&2; return 1 ;;
  esac
}

# ── RED/GREEN: a lane in an agent frontmatter key none of the builds' own transforms recognizes
# still fails the build (plan C Task 4). plant_unrecognized_model_key_agent's `Model:` key spelling is
# invisible to every build's per-agent awk (case-sensitive, column-0 `/^model:/`) AND to
# `zrl_frontmatter_model` (the same case-sensitive column-0 reader) — so this is caught as "no readable
# model:" before any agent is adapted; no dst file is written. Paths are EXACT and anchored.
# sc_unrecognized_key <platform> — one platform of the @test below (run for each by each_platform).
sc_unrecognized_key() {
  local p="$1" fk root a out
  fk="$BATS_TEST_TMPDIR/$p-fixture"; root="$BATS_TEST_TMPDIR/$p-fixture-dist"
  plat_fixture "$fk" "$p" || return 1
  a="$fk/skills/zz-min/agents"
  plant_unrecognized_model_key_agent "$a" badlane review-alt || return 1
  plat_run_build "$fk" "$root" "$p"
  [ "$status" -ne 0 ] || { echo "$p: the build passed" >&2; return 1; }
  output_has "$a/badlane.md has no readable \`model:\` (a column-0 key in a frontmatter that starts on line 1) — the $(plat_label "$p") build does not guess one" || return 1
  # The refused agent never reaches the dist — a fact of the dist, not of the log (the build log never
  # prints a resolved frontmatter line, so a log-level negative would pass whatever was written).
  case "$p" in
    codex) out="$root/codex/agents/zz-min-badlane.toml" ;;
    *) out="$(plat_agent_md "$root" "$p" zz-min badlane)" ;;
  esac
  [ ! -e "$out" ] || { echo "$p: the refused agent was still written: $out" >&2; return 1; }
}
@test "every build: an agent frontmatter key none of the builds recognize fails the build, naming the file" {
  each_platform sc_unrecognized_key codex cursor antigravity kimi
}

# sc_no_model <platform> — one platform of the @test below (run for each by each_platform).
sc_no_model() {
  local p="$1" fk root a
  fk="$BATS_TEST_TMPDIR/$p-nomodel"; root="$BATS_TEST_TMPDIR/$p-nomodel-dist"
  plat_fixture "$fk" "$p" || return 1
  a="$fk/skills/zz-min/agents"
  plant_agent_fixture "$a" nomodel || return 1
  plat_run_build "$fk" "$root" "$p"
  [ "$status" -ne 0 ] || { echo "$p: the build passed" >&2; return 1; }
  output_has "$a/nomodel.md has no readable \`model:\` (a column-0 key in a frontmatter that starts on line 1) — the $(plat_label "$p") build does not guess one" || return 1
}
@test "every build: no readable model: at all fails by name (a frontmatter with no model key)" {
  each_platform sc_no_model codex cursor antigravity kimi
}

# ── RED/GREEN: a lane in a rules/ file's OWN frontmatter still fails the build. No agent gate runs
# over rules/, so this exercises the leftover scan directly. (Not Codex: its rules/ pass through the
# strict rewriter, which resolves exactly this spelling.)
# sc_rules_lane <platform> — one platform of the @test below (run for each by each_platform).
sc_rules_lane() {
  local p="$1" fk root lane
  fk="$BATS_TEST_TMPDIR/$p-rules-fixture"; root="$BATS_TEST_TMPDIR/$p-rules-fixture-dist"
  case "$p" in antigravity) lane=review-alt ;; *) lane=review-primary ;; esac
  platform_fixture "$fk" "$p" || return 1
  plant_rules_lane_fixture "$fk/rules" zz-lane-fixture "$lane" || return 1
  plat_run_build "$fk" "$root" "$p"
  [ "$status" -ne 0 ] || { echo "$p: the build passed" >&2; return 1; }
  output_has "Abstract reviewer lanes remain in $(plat_label "$p") dist (1 leftover reference(s) — a route word, or an unparsable value, in a frontmatter model key):" || return 1
  output_has "$root/$p/rules/zz-lane-fixture.md:3:model: $lane" || return 1
}
@test "Cursor/Antigravity/Kimi builds: a lane in rules/ frontmatter fails the build, naming the file" {
  each_platform sc_rules_lane cursor antigravity kimi
}

# ── Multi-hit counting. Two SEPARATE lane hits, in two different files, count as 2 (per instance),
# not a flat +1 for "the scan found something". zrl_scan_and_report_lanes is the one shared helper,
# so exercising it once, through Cursor, covers the counting itself.
@test "Cursor build: two leftover lane hits in two files count as 2, not a flat 1" {
  local fk="$BATS_TEST_TMPDIR/cursor-multi-lane" root="$BATS_TEST_TMPDIR/cursor-multi-lane-dist"
  platform_fixture "$fk" cursor
  plant_rules_lane_fixture "$fk/rules" zz-lane-one review-primary
  plant_rules_lane_fixture "$fk/rules" zz-lane-two review-alt
  plat_run_build "$fk" "$root" cursor
  [ "$status" -ne 0 ]
  output_has "Abstract reviewer lanes remain in Cursor dist (2 leftover reference(s) — a route word, or an unparsable value, in a frontmatter model key):"
  output_has "$root/cursor/rules/zz-lane-one.md:3:model: review-primary"
  output_has "$root/cursor/rules/zz-lane-two.md:3:model: review-alt"
  # EXACT total: the 2 lane hits plus the ONE unrelated "Missing Cursor blind audit reviewer agents"
  # every minimal (non-`full`) fixture always trips.
  output_has "BUILD FAILED: 3 error(s)"
}

# ── The same fixture shape in shared/includes/ — a SEPARATE tree from rules/, proving the scan covers
# both. A real, untouched shared include (env-compat.md, copied into every fixture) keeps exactly as
# many lane words as its source.
# sc_shared_lane <platform> — one platform of the @test below (run for each by each_platform).
sc_shared_lane() {
  local p="$1" fk root lane
  fk="$BATS_TEST_TMPDIR/$p-shared-fixture"; root="$BATS_TEST_TMPDIR/$p-shared-fixture-dist"
  case "$p" in antigravity) lane=review-primary ;; *) lane=review-alt ;; esac
  platform_fixture "$fk" "$p" || return 1
  plant_rules_lane_fixture "$fk/shared/includes" zz-shared-lane "$lane" || return 1
  plat_run_build "$fk" "$root" "$p"
  [ "$status" -ne 0 ] || { echo "$p: the build passed" >&2; return 1; }
  output_has "$root/$p/shared/includes/zz-shared-lane.md:3:model: $lane" || return 1
  lane_word_count_unchanged "$fk/shared/includes/env-compat.md" "$root/$p/shared/includes/env-compat.md" || return 1
}
@test "Cursor/Antigravity/Kimi builds: a lane in shared/includes/ frontmatter fails the build; a real include is untouched" {
  each_platform sc_shared_lane cursor antigravity kimi
}

# ── references/*.md nests under skills/<skill>/references/ in all three builds, inside the scanned
# $DIST/skills. A valid reference planted alongside the lane one stays present.
# sc_references_lane <platform> — one platform of the @test below (run for each by each_platform).
sc_references_lane() {
  local p="$1" fk root lane
  fk="$BATS_TEST_TMPDIR/$p-ref-fixture"; root="$BATS_TEST_TMPDIR/$p-ref-fixture-dist"
  case "$p" in antigravity) lane=review-alt ;; *) lane=review-primary ;; esac
  platform_fixture "$fk" "$p" || return 1
  mkdir -p "$fk/skills/zz-min/references" || return 1
  plant_rules_lane_fixture "$fk/skills/zz-min/references" zz-ref-lane "$lane" || return 1
  printf '%s\n' '# a valid reference doc' 'Nothing lane-shaped here.' > "$fk/skills/zz-min/references/zz-ref-ok.md" || return 1
  plat_run_build "$fk" "$root" "$p"
  [ "$status" -ne 0 ] || { echo "$p: the build passed" >&2; return 1; }
  output_has "$root/$p/skills/zz-min/references/zz-ref-lane.md:3:model: $lane" || return 1
  [ -f "$root/$p/skills/zz-min/references/zz-ref-ok.md" ] || { echo "$p: the valid reference is gone" >&2; return 1; }
}
@test "Cursor/Antigravity/Kimi builds: a lane in references/ frontmatter fails the build; a valid reference survives" {
  each_platform sc_references_lane cursor antigravity kimi
}

# ── RED: the FULL decorated/malformed-value matrix, all in ONE fixture skill so one build run proves
# every shape — in ALL FOUR builds, because all four gate an agent through zrl_agent_model_known: a lane
# only as the WHOLE, unquoted value, a tier only as an EXACT match (no first-word truncation — the Codex
# build used to take `sonnet extra`, `'sonnet'` and a bare `per-task` as gpt-5.4), and a route word
# inside a per-task descriptor is refused. A failed build's dist is unspecified, so nothing here asserts
# a survivor; the message quotes the value once, in single quotes.
# sc_malformed_matrix <platform> — one platform of the @test below (run for each by each_platform).
sc_malformed_matrix() {
  local p="$1" fk root a asrc label want n
  fk="$BATS_TEST_TMPDIR/$p-matrix"; root="$BATS_TEST_TMPDIR/$p-matrix-dist"
  label="$(plat_label "$p")"
  plat_fixture "$fk" "$p" || return 1
  a="$fk/skills/zz-min/agents"; asrc="$fk/skills/zz-min/agents"
  plant_agent_fixture "$a" gptweird 'model: gpt-weird' || return 1
  plant_agent_fixture "$a" crossvendor 'model: cross-vendor' || return 1
  plant_agent_fixture "$a" flowval 'model: [review-alt]' || return 1
  plant_agent_fixture "$a" commaval 'model: x,review-alt' || return 1
  plant_agent_fixture "$a" quotedlane 'model: "review-alt"' || return 1
  plant_agent_fixture "$a" quotedtier "model: 'sonnet'" || return 1
  plant_agent_fixture "$a" trailing 'model: sonnet extra' || return 1
  plant_agent_fixture "$a" unquotedpertask 'model: per-task' || return 1
  plant_agent_fixture "$a" lanepertask 'model: "per-task: review-primary"' || return 1
  plat_run_build "$fk" "$root" "$p"
  [ "$status" -ne 0 ] || { echo "$p: the build passed" >&2; return 1; }
  output_has "$asrc/gptweird.md: model value 'gpt-weird' is not one the $label build accepts" || return 1
  output_has "$asrc/crossvendor.md: model value 'cross-vendor' is not one the $label build accepts" || return 1
  output_has "$asrc/flowval.md: model value '[review-alt]' is not one the $label build accepts" || return 1
  output_lacks "[[review-alt]]" || return 1
  output_has "$asrc/commaval.md: model value 'x,review-alt' is not one the $label build accepts" || return 1
  output_has "$asrc/quotedlane.md: model value '\"review-alt\"' is not one the $label build accepts" || return 1
  output_has "$asrc/quotedtier.md: model value ''sonnet'' is not one the $label build accepts" || return 1
  output_has "$asrc/trailing.md: model value 'sonnet extra' is not one the $label build accepts" || return 1
  output_has "$asrc/unquotedpertask.md: model value 'per-task' is not one the $label build accepts" || return 1
  output_has "$asrc/lanepertask.md: model value '\"per-task: review-primary\"' is not one the $label build accepts" || return 1
  output_has "haiku, sonnet, opus, review-primary, review-alt, or a quoted \"per-task: …\" descriptor" || return 1
  # EXACT count: the 9 fixtures plus what every minimal fixture trips — for Cursor/Antigravity/Kimi
  # "Missing <Platform> blind audit reviewer agents"; for Codex "Missing Codex blind audit reviewer
  # TOMLs" and "no agent TOMLs … to scan" (every agent was refused, so none was written).
  case "$p" in codex) want=11 ;; *) want=10 ;; esac
  output_has "BUILD FAILED: $want error(s)" || return 1
  if [ "$p" = codex ]; then
    for n in gptweird crossvendor flowval commaval quotedlane quotedtier trailing unquotedpertask lanepertask; do
      [ ! -e "$root/codex/agents/zz-min-$n.toml" ] || { echo "codex: $n got a TOML" >&2; return 1; }
    done
  fi
}
@test "every build: every decorated or malformed model value fails by name, quoted once" {
  each_platform sc_malformed_matrix codex cursor antigravity kimi
}

# ── The flat-agent builds (Cursor `<skill-prefix>-<name>.md`, Codex `<skill-prefix>-<name>.toml`, Kimi
# `<skill-prefix>-<name>.md`): skill `zz-a` agent `b-c` and skill `zz-a-b` agent `c` land on ONE name
# (which of the two is written second depends on the glob's collation, so the message is matched up to
# the skill dir both paths share) —
# two adapted, one shipped, one never checked. Each build names that as an error of its own: Cursor and
# Codex at the second write ("would be written twice"), Kimi by the count its agent checks rely on
# (adapted vs shipped; its model:/model_preference checks read the shipped files). (A tree with no agent
# at all adapts none: nothing to check, and no such error — the second half, anchored on the build's own
# error total so it follows a build that ran to its end.)
# sc_flat_collision <platform> — one platform of the @test below (run for each by each_platform).
sc_flat_collision() {
  local p="$1" fk root want
  fk="$BATS_TEST_TMPDIR/$p-collide"; root="$BATS_TEST_TMPDIR/$p-collide-dist"
  plat_fixture "$fk" "$p" || return 1
  mkdir -p "$fk/skills/zz-a" "$fk/skills/zz-a-b" || return 1
  printf '%s\n' '---' 'name: zz-a' 'description: fixture skill' '---' '# zuvo:zz-a' '' 'Nothing to do.' > "$fk/skills/zz-a/SKILL.md" || return 1
  printf '%s\n' '---' 'name: zz-a-b' 'description: fixture skill' '---' '# zuvo:zz-a-b' '' 'Nothing to do.' > "$fk/skills/zz-a-b/SKILL.md" || return 1
  plant_agent_fixture "$fk/skills/zz-a/agents" b-c 'model: sonnet' || return 1
  plant_agent_fixture "$fk/skills/zz-a-b/agents" c 'model: haiku' || return 1
  plat_run_build "$fk" "$root" "$p"
  [ "$status" -ne 0 ] || { echo "$p: the build passed" >&2; return 1; }
  case "$p" in
    cursor) want="ERROR: agents/zz-a-b-c.md would be written twice — $fk/skills/zz-a" ;;
    codex) want="ERROR: zz-a-b-c.toml would be written twice — $fk/skills/zz-a" ;;
    kimi) want="ERROR: the build adapted 2 agent(s) but $root/kimi/agents holds 1 — the frontmatter model: key and model_preference checks cannot cover every adapted agent" ;;
  esac
  output_has "$want" || { echo "$p" >&2; return 1; }
  # No agent in the tree: none adapted, none to check, and neither error fires. The minimal fixture has
  # no blind-audit reviewers: Cursor fails on exactly that one error, Codex on that and "no agent TOMLs
  # to scan", and Kimi (which checks its reviewers only among shipped agents) completes with 0 agents.
  # Each summary is asserted, so the negative below follows a build that reached its end.
  fk="$BATS_TEST_TMPDIR/$p-noagents"; root="$BATS_TEST_TMPDIR/$p-noagents-dist"
  plat_fixture "$fk" "$p" || return 1
  plat_run_build "$fk" "$root" "$p"
  case "$p" in
    cursor) want="BUILD FAILED: 1 error(s)" ;; codex) want="BUILD FAILED: 2 error(s)" ;;
    kimi) want="Agents: 0 (flat in agents/)" ;;
  esac
  output_has "$want" || { echo "$p: the agent-free build did not reach its known summary [$want]" >&2; return 1; }
  output_lacks "cannot cover every adapted agent" || { echo "$p" >&2; return 1; }
  output_lacks "would be written twice" || { echo "$p" >&2; return 1; }
}
@test "flat-agent builds: two agents flattened onto one name fail by name — the agent checks never pass on less" {
  each_platform sc_flat_collision cursor codex kimi
}

# …and with agents present, both checks still find what they are for: a `model_preference:` the SOURCE
# wrote wrong (it never passes through the model: conversion) is named with its file and line.
@test "Kimi build: a model_preference written wrong in the source is still caught, named file:line" {
  local fk="$BATS_TEST_TMPDIR/kimi-badpref" root="$BATS_TEST_TMPDIR/kimi-badpref-dist" a
  platform_fixture "$fk" kimi
  a="$fk/skills/zz-min/agents"
  mkdir -p "$a"
  printf '%s\n' '---' 'name: badpref' 'description: planted agent' 'model: sonnet' 'model_preference: tertiary' '---' '' 'Body.' > "$a/badpref.md"
  plat_run_build "$fk" "$root" kimi
  [ "$status" -ne 0 ]
  output_has "Invalid model_preference values (must be primary|secondary):"
  # Named file:line — any line number (no pinned dist line: the adapted layout may move it).
  printf '%s\n' "$output" | grep -qF -- "$root/kimi/agents/zz-min-badpref.md:" \
    && printf '%s\n' "$output" | grep -qE -- 'zz-min-badpref\.md:[0-9]+:model_preference: tertiary$' \
    || { printf 'expected a file:line naming zz-min-badpref.md\nactual output: %s\n' "$output" >&2; return 1; }
  output_lacks "cannot cover every adapted agent"
}

# ── GREEN: an agent whose description contains "registry" or "template" (the data-only heuristic's
# own trigger words) but which has a VALID readable `model:` must still SHIP, in every build.
# Mutation proof (recorded, not auto-run): drop the `rc -ne 0` half of zrl_agent_gate's data-only
# condition — these agents go back to being silently skipped as "data-only" and this goes RED.
# sc_dataonly_lookalike <platform> — one platform of the @test below (run for each by each_platform).
sc_dataonly_lookalike() {
  local p="$1" fk root a n
  fk="$BATS_TEST_TMPDIR/$p-a1"; root="$BATS_TEST_TMPDIR/$p-a1-dist"
  # `full`: a minimal zz-min-only fixture always trips "Missing <Platform> blind audit reviewer
  # agents", so no build from one can exit 0.
  platform_fixture "$fk" "$p" full || return 1
  mkdir -p "$fk/skills/zz-green/agents" || return 1
  printf '%s\n' '---' 'name: zz-green' 'description: fixture skill for the A1/N1-precise test' '---' '# zuvo:zz-green' '' 'Dispatch via Agent tool.' > "$fk/skills/zz-green/SKILL.md" || return 1
  a="$fk/skills/zz-green/agents"
  plant_dataonly_lookalike_agent "$a" zz-registry-scorer registry || return 1
  plant_dataonly_lookalike_agent "$a" zz-template-scorer template || return 1
  plat_run_build "$fk" "$root" "$p"
  [ "$status" -eq 0 ] || { echo "$p:" >&2; printf '%s\n' "$output" | tail -20 >&2; return 1; }
  for n in zz-registry-scorer zz-template-scorer; do
    output_lacks "$n (data-only)" || return 1
    [ -f "$(plat_agent_md "$root" "$p" zz-green "$n")" ] || { echo "$p: $n did not ship" >&2; return 1; }
    plat_resolved_is "$(plat_agent_md "$root" "$p" zz-green "$n")" "$p" sonnet || return 1
  done
}
@test "Cursor/Antigravity/Kimi builds: an agent whose description says registry or template still ships" {
  each_platform sc_dataonly_lookalike cursor antigravity kimi
}

@test "Codex build: an agent whose description says registry or template still gets a TOML (A1/N1-precise)" {
  local fk="$BATS_TEST_TMPDIR/codex-a1" root="$BATS_TEST_TMPDIR/codex-a1-dist" a
  codex_fixture "$fk" full
  mkdir -p "$fk/skills/zz-green/agents"
  printf '%s\n' '---' 'name: zz-green' 'description: fixture skill for the A1/N1-precise test' '---' '# zuvo:zz-green' '' 'Dispatch via Agent tool.' > "$fk/skills/zz-green/SKILL.md"
  a="$fk/skills/zz-green/agents"
  plant_dataonly_lookalike_agent "$a" zz-registry-scorer registry
  plant_dataonly_lookalike_agent "$a" zz-template-scorer template
  plat_run_build "$fk" "$root" codex
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20 >&2; return 1; }
  output_lacks "zz-registry-scorer (data-only, no TOML)"
  output_lacks "zz-template-scorer (data-only, no TOML)"
  [ -f "$root/codex/agents/zz-green-zz-registry-scorer.toml" ]
  [ -f "$root/codex/agents/zz-green-zz-template-scorer.toml" ]
  registry_ids
  toml_model_is "$root" zz-green-zz-registry-scorer "$REG_SONNET"
  toml_model_is "$root" zz-green-zz-template-scorer "$REG_SONNET"
}

# ── GREEN: the per-task descriptor, a CRLF-terminated lane and a BOM-prefixed agent all resolve, in a
# clean build (so their dist files are guaranteed to exist). Every build reads the model through the
# BOM/CRLF-normalised strict reader (zrl_read_agent_model), so `review-alt\r` and a `\xef\xbb\xbf---`
# first line resolve exactly like their plain spellings. Codex is the fourth target: it used to read
# the raw file, so a BOM agent was "no readable model" there and built everywhere else.
# sc_green_resolve <platform> — one platform of the @test below (run for each by each_platform).
sc_green_resolve() {
  local p="$1" fk root a
  fk="$BATS_TEST_TMPDIR/$p-green"; root="$BATS_TEST_TMPDIR/$p-green-dist"
  # `full`: the real write-tests skill must be present for a genuine `status -eq 0`.
  plat_fixture "$fk" "$p" full || return 1
  mkdir -p "$fk/skills/zz-green/agents" || return 1
  printf '%s\n' '---' 'name: zz-green' 'description: fixture skill for the resolve-correctly test' '---' '# zuvo:zz-green' '' 'Dispatch via Agent tool.' > "$fk/skills/zz-green/SKILL.md" || return 1
  a="$fk/skills/zz-green/agents"
  plant_agent_fixture "$a" pertask 'model: "per-task: sonnet for standard complexity, opus for complex"' || return 1
  printf -- '---\r\nname: crlf\r\ndescription: planted CRLF fixture\r\nmodel: review-alt\r\n---\r\nBody.\r\n' > "$a/crlf.md" || return 1
  printf '\357\273\277---\nname: bom\ndescription: planted BOM fixture\nmodel: review-primary\n---\nBody.\n' > "$a/bom.md" || return 1
  plat_run_build "$fk" "$root" "$p"
  [ "$status" -eq 0 ] || { echo "$p:" >&2; printf '%s\n' "$output" | tail -20 >&2; return 1; }
  if [ "$p" = codex ]; then
    registry_ids || return 1
    toml_model_is "$root" zz-green-pertask "$REG_SONNET" || return 1
    toml_model_is "$root" zz-green-crlf "$REG_ALT" || return 1
    toml_model_is "$root" zz-green-bom "$REG_PRIMARY" || return 1
    # The adapted agent .md drops the model key, BOM or not: no lane survives into the dist.
    run rg -c 'review-primary|review-alt' "$root/codex/skills/zz-green/agents/bom.md" "$root/codex/skills/zz-green/agents/crlf.md"
    [ "$status" -eq 1 ] || { echo "codex: a lane survived in an adapted agent: $output" >&2; return 1; }
    return 0
  fi
  # per-task maps to the default tier in every build (antigravity gemini-3.1-pro-low, the same choice
  # build-codex-skills.sh's map_model makes) — never the `opus` its descriptor happens to mention.
  plat_resolved_is "$(plat_agent_md "$root" "$p" zz-green pertask)" "$p" per-task || return 1
  plat_resolved_is "$(plat_agent_md "$root" "$p" zz-green crlf)" "$p" review-alt || return 1
  plat_resolved_is "$(plat_agent_md "$root" "$p" zz-green bom)" "$p" review-primary || return 1
}
@test "every build: the per-task descriptor, a CRLF-terminated lane and a BOM-prefixed agent all resolve" {
  each_platform sc_green_resolve codex cursor antigravity kimi
}

# ── Cursor `readonly:` is derived from the agent's `tools:` list — read through zrl_strip_bom_crlf,
# so a BOM + CRLF agent that lists `- Write` is still recognized as a writer. Mutation proof: drop the
# zrl_strip_bom_crlf in adapt_agent_for_cursor's has_write pipe and `---\r` never opens the
# frontmatter, the tools list is never seen, and the writer comes out `readonly: true`.
@test "Cursor build: readonly is false for a BOM+CRLF agent that lists Write, true for a read-only one" {
  local fk="$BATS_TEST_TMPDIR/cursor-readonly" root="$BATS_TEST_TMPDIR/cursor-readonly-dist" a
  platform_fixture "$fk" cursor full
  mkdir -p "$fk/skills/zz-green/agents"
  printf '%s\n' '---' 'name: zz-green' 'description: fixture skill for the readonly test' '---' '# zuvo:zz-green' '' 'Dispatch via Agent tool.' > "$fk/skills/zz-green/SKILL.md"
  a="$fk/skills/zz-green/agents"
  printf '\357\273\277---\r\nname: writer\r\ndescription: planted writer\r\nmodel: sonnet\r\ntools:\r\n  - Read\r\n  - Write\r\n---\r\nBody.\r\n' > "$a/writer.md"
  printf '\357\273\277---\r\nname: reader\r\ndescription: planted reader\r\nmodel: sonnet\r\ntools:\r\n  - Read\r\n  - Grep\r\n---\r\nBody.\r\n' > "$a/reader.md"
  plat_run_build "$fk" "$root" cursor
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20 >&2; return 1; }
  run grep -c '^readonly: false$' "$root/cursor/agents/zz-green-writer.md"
  [ "$output" = 1 ] || { echo "writer: readonly false count [$output]" >&2; return 1; }
  run grep -c '^readonly: true$' "$root/cursor/agents/zz-green-reader.md"
  [ "$output" = 1 ] || { echo "reader: readonly true count [$output]" >&2; return 1; }
  # The tools list itself is dropped (not a Cursor key), CRs included.
  run rg -c $'\r|^tools:|^  - ' "$root/cursor/agents/zz-green-writer.md"
  [ "$status" -eq 1 ]
}

# ── An unreadable agent (chmod 000) reaches the gate's "could not be read" branch in EVERY build —
# never "no readable model:" and never the data-only skip (head/grep read nothing from an unreadable
# file, which the heuristic would take as "no description"). The Codex build used to probe it without
# the readability check and skipped it as data-only, silently. Skipped, never failed, when the test's
# own user cannot be locked out (root). The mode is restored in `teardown()` via ZT_UNREADABLE.
# sc_unreadable <platform> — one platform of the @test below (run for each by each_platform).
sc_unreadable() {
  local p="$1" fk root a
  fk="$BATS_TEST_TMPDIR/$p-g2"; root="$BATS_TEST_TMPDIR/$p-g2-dist"
  plat_fixture "$fk" "$p" || return 1
  a="$fk/skills/zz-min/agents"
  plant_agent_fixture "$a" unreadable 'model: sonnet' || return 1
  chmod 000 "$a/unreadable.md" || return 1
  export ZT_UNREADABLE="$a/unreadable.md"
  if [ -r "$a/unreadable.md" ]; then
    chmod 644 "$a/unreadable.md"
    skip "running as a user chmod 000 cannot lock out (root?)"
  fi
  plat_run_build "$fk" "$root" "$p"
  chmod 644 "$a/unreadable.md"
  [ "$status" -ne 0 ] || { echo "$p: the build passed" >&2; return 1; }
  output_has "$a/unreadable.md could not be read for its \`model:\`" || return 1
  output_lacks "no readable \`model:\`" || return 1
  output_lacks "unreadable (data-only" || return 1
}
@test "every build: an unreadable agent file fails with 'could not be read', never 'no readable model:'" {
  each_platform sc_unreadable codex cursor antigravity kimi
}

# ── A scan-FAILURE fixture (awk_stub) asserts the "could not scan" message carries the scanner's own
# stderr, AND that hits found before the scan stopped are shown separately, under their own label, in
# that order. Mutation proof recorded: reverting the capture to `2>&1` prints the diagnostic and the hit
# under the SAME block, and assert_line_order fails.
# sc_scan_failure <platform> — one platform of the @test below (run for each by each_platform).
sc_scan_failure() {
  local p="$1" fk root lane
  fk="$BATS_TEST_TMPDIR/$p-g3"; root="$BATS_TEST_TMPDIR/$p-g3-dist"
  case "$p" in antigravity) lane=review-alt ;; *) lane=review-primary ;; esac
  platform_fixture "$fk" "$p" || return 1
  plant_rules_lane_fixture "$fk/rules" zz-scan-ok "$lane" || return 1
  mkdir -p "$root/$p" || return 1
  # Order-independent by construction: awk_stub's "after" mode runs the REAL awk over the whole
  # argument list first (finding every hit wherever it falls) and only then fakes the failure.
  awk_stub "$BATS_TEST_TMPDIR/awk-stub-$p" after "$root/$p/skills/zz-min/SKILL.md" || return 1
  run env -u ZUVO_DIST_CACHE PATH="$BATS_TEST_TMPDIR/awk-stub-$p:$PATH" ZUVO_DIST_ROOT="$root" \
      bash "$fk/tests/lib/dist-build.sh" "$p"
  [ "$status" -ne 0 ] || { echo "$p: the build passed" >&2; return 1; }
  output_has "awk-stub: cannot read $root/$p/skills/zz-min/SKILL.md" || return 1
  output_has "could not scan the $(plat_label "$p") dist for unresolved reviewer lanes:" || return 1
  output_has "lanes it had found before the scan stopped:" || return 1
  output_has "$root/$p/rules/zz-scan-ok.md:3:model: $lane" || return 1
  assert_line_order "awk-stub: cannot read $root/$p/skills/zz-min/SKILL.md" \
    "lanes it had found before the scan stopped:" \
    "$root/$p/rules/zz-scan-ok.md:3:model: $lane" || return 1
}
@test "Cursor/Antigravity/Kimi builds: a scan failure prints the scanner's stderr AND any hits found before it stopped" {
  each_platform sc_scan_failure cursor antigravity kimi
}

# ── The library guard: every build checks, right after sourcing lib/reviewer-lanes.sh, that EVERY
# zrl_* function it calls (and every one the library itself lists in ZRL_FUNCS) is defined — so a
# truncated or renamed library fails loudly by name, before a file is written, never as a misleading
# "could not be read" (a missing zrl_strip_bom_crlf) or an exit status of 127 counted as 127 errors (a
# missing zrl_scan_and_report_lanes). The Codex build had no guard at all.
# sc_lib_guard <platform> — one platform of the @test below (run for each by each_platform).
sc_lib_guard() {
  local p="$1" fk root fn
  for fn in zrl_strip_bom_crlf zrl_scan_and_report_lanes; do
    fk="$BATS_TEST_TMPDIR/$p-guard-$fn"; root="$BATS_TEST_TMPDIR/$p-guard-$fn-dist"
    plat_fixture "$fk" "$p" || return 1
    # Rename the definition, so the function is simply absent from the sourced library.
    perl -0pi -e "s/^${fn}\\(\\)/${fn}_gone()/m" "$fk/scripts/lib/reviewer-lanes.sh" || return 1
    ! grep -q "^${fn}()" "$fk/scripts/lib/reviewer-lanes.sh" || { echo "$p: $fn still defined in the fixture" >&2; return 1; }
    plat_run_build "$fk" "$root" "$p"
    [ "$status" -eq 1 ] || { printf '%s/%s: status %s\n%s\n' "$p" "$fn" "$status" "$output" >&2; return 1; }
    output_has "ERROR: $fn is not defined after sourcing $fk/scripts/lib/reviewer-lanes.sh — the library is missing or incomplete" || return 1
    [ ! -e "$root/$p" ] || { echo "$p/$fn: the build got as far as creating its dist" >&2; return 1; }
  done
}
@test "every build: a lane library missing a function it calls is refused by name, before anything is built" {
  each_platform sc_lib_guard codex cursor antigravity kimi
}

# ── RED/GREEN: plan C Task 4 fix round 1, C2, split per F2 — two INDEPENDENT @tests, each with its
# own single fixture, instead of one test enshrining a dist file that carries both a correct
# `model_preference: primary` AND a stray `tertiary` line side by side.
@test "Kimi build: a model_preference:-only SOURCE agent (no model: key) fails at the C1 gate" {
  local fk="$BATS_TEST_TMPDIR/kimi-c2a" root="$BATS_TEST_TMPDIR/kimi-c2a-dist" a asrc
  platform_fixture "$fk" kimi
  a="$fk/skills/zz-min/agents"; asrc="$fk/skills/zz-min/agents"
  mkdir -p "$a"
  printf '%s\n' '---' 'name: bypass1' 'description: planted C2 fixture' 'model_preference: review-alt' '---' '' 'Body text.' > "$a/bypass1.md"
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" kimi
  [ "$status" -ne 0 ]
  output_has "$asrc/bypass1.md has no readable \`model:\` (a column-0 key in a frontmatter that starts on line 1) — the Kimi build does not guess one"
  [ ! -e "$root/kimi/agents/zz-min-bypass1.md" ]
}

@test "Kimi build: a VALID model: plus a stray pre-existing model_preference: fails at bad_pref" {
  local fk="$BATS_TEST_TMPDIR/kimi-c2b" root="$BATS_TEST_TMPDIR/kimi-c2b-dist" a
  platform_fixture "$fk" kimi
  a="$fk/skills/zz-min/agents"
  mkdir -p "$a"
  # model: sonnet passes C1; the pre-existing model_preference: line is not `/^model:/`, so
  # adapt_agent_for_kimi's awk copies it through UNCHANGED, side by side with the real conversion.
  printf '%s\n' '---' 'name: bypass2' 'description: planted C2 fixture' 'model: sonnet' 'model_preference: tertiary' '---' '' 'Body text.' > "$a/bypass2.md"
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" kimi
  [ "$status" -ne 0 ]
  output_has "Invalid model_preference values (must be primary|secondary):"
  output_has "$root/kimi/agents/zz-min-bypass2.md:"
  # No pinned dist line number (fix round 3, W6): read the shipped file directly for the stray
  # value instead of asserting exactly which line it landed on.
  run grep -c '^model_preference: tertiary$' "$root/kimi/agents/zz-min-bypass2.md"
  [ "$output" = "1" ]
}

# ── Q11 round 4, N4: `stray_model_keys` (build-kimi-skills.sh) has no fixture of its own. Same
# shape as bypass2 above, but for a DUPLICATE `model:`-looking key instead of a pre-existing
# `model_preference:`: `zrl_frontmatter_model` (C1) exits after the FIRST `/^model:/` line it sees
# in the frontmatter, so a real `model: sonnet` line ahead of it is enough to pass C1 and ship the
# agent. `adapt_agent_for_kimi`'s per-agent awk has no `exit` either, so it keeps scanning the rest
# of the frontmatter -- but its `/^model:/` match is exact-case, column-0, so a SECOND key spelled
# `Model:` (capitalized) falls through every specific `in_fm && /^...:/ ` branch to the generic
# `in_fm { print; next }` passthrough and survives byte for byte into the dist. That residual is
# exactly what `stray_model_keys`'s case-insensitive, indentation-tolerant scan exists to catch.
@test "Kimi build: a duplicate, differently-cased model key survives adapt_agent_for_kimi and fails at stray_model_keys" {
  local fk="$BATS_TEST_TMPDIR/kimi-n4" root="$BATS_TEST_TMPDIR/kimi-n4-dist" a
  platform_fixture "$fk" kimi
  a="$fk/skills/zz-min/agents"
  mkdir -p "$a"
  printf '%s\n' '---' 'name: straykey' 'description: planted N4 fixture' 'model: sonnet' 'Model: opus' '---' '' 'Body text.' > "$a/straykey.md"
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" kimi
  [ "$status" -ne 0 ]
  # C1 passed (the first, lowercase `model: sonnet` line resolves and is accepted) -- this is not
  # a "no readable model:" or bad_pref failure, it is the NEW stray-key scan.
  output_has "Kimi agent(s) still carry a frontmatter model: key (should be model_preference:):"
  output_has "$root/kimi/agents/zz-min-straykey.md:"
  # The real conversion of the first line still happened -- proves the failure is about the
  # SURVIVING duplicate, not a total failure to process the file.
  run grep -c '^model_preference: primary$' "$root/kimi/agents/zz-min-straykey.md"
  [ "$output" = "1" ]
  run grep -c '^Model: opus$' "$root/kimi/agents/zz-min-straykey.md"
  [ "$output" = "1" ]
}

# ── G1: unit tests for zrl_agent_model_known over the E1 matrix, driven directly (the `lanes`
# helper, already used by the reviewer-lanes: tests above) — independent of any build script.
@test "reviewer-lanes: zrl_agent_model_known accepts the exact tier/lane set and the quoted per-task descriptor" {
  local v
  for v in haiku sonnet opus review-primary review-alt; do
    run lanes zrl_agent_model_known "$v"
    [ "$status" -eq 0 ] || { echo "expected accept: [$v]" >&2; return 1; }
  done
  run lanes zrl_agent_model_known '"per-task: sonnet for standard complexity, opus for complex"'
  [ "$status" -eq 0 ]
  run lanes zrl_agent_model_known "'per-task: x'"
  [ "$status" -eq 0 ]
}

@test "reviewer-lanes: zrl_agent_model_known refuses every decorated, quoted-non-per-task, or trailing form" {
  local v
  for v in '"review-alt"' "'sonnet'" "sonnet extra" "per-task" "[review-alt]" "x,review-alt" \
           "" ">" "Review-Primary" "cross-vendor" "gpt-weird" '"sonnet"' " sonnet" "sonnet " \
           '"per-task: review-primary"' '"per-task: x" y"' '"per-task: sonnet, then cross-vendor"' \
           "\"per-task: x'"; do
    run lanes zrl_agent_model_known "$v"
    [ "$status" -ne 0 ] || { echo "expected reject: [$v]" >&2; return 1; }
  done
}

# The route-word check inside a per-task descriptor splits the descriptor into tokens. It must do so
# on blanks whatever IFS the caller left behind: under IFS=, or IFS=: the text " review-primary" used
# to stay ONE token (a leading blank included), which is no route word, so the descriptor passed.
@test "reviewer-lanes: zrl_agent_model_known refuses a route word in a per-task descriptor whatever IFS the caller left" {
  local ifs
  for ifs in ',' ':' $'\n'; do
    run bash -c '. "$1" || exit 97; . "$2" || exit 97; IFS="$3"; zrl_agent_model_known "$4"' _ \
        "$REPO_ROOT/scripts/lib/portable.sh" "$LANES_LIB" "$ifs" '"per-task: review-primary"'
    [ "$status" -ne 0 ] || { printf 'IFS=[%q]: a route word in the descriptor was accepted\n' "$ifs" >&2; return 1; }
    # …and the real descriptor still passes under the same IFS.
    run bash -c '. "$1" || exit 97; . "$2" || exit 97; IFS="$3"; zrl_agent_model_known "$4"' _ \
        "$REPO_ROOT/scripts/lib/portable.sh" "$LANES_LIB" "$ifs" '"per-task: sonnet for standard complexity, opus for complex"'
    [ "$status" -eq 0 ] || { printf 'IFS=[%q]: the real descriptor was refused\n' "$ifs" >&2; return 1; }
  done
}

# A signal that interrupts the leftover-lane report must fail it. The scan's own subshell is signalled
# (the stub scanner reports a hit, then TERMs/INTs its parent — the report's subshell — before it
# returns): a trap that only removes the temp files and returns lets the report continue over deleted
# files and exit 0, i.e. "no leftover lanes", from a scan that was never read.
# The shell under test is started through perl with the signal reset to its default: a suite started
# detached (`nohup … &`, as run-all is on the farm) hands INT and HUP down IGNORED, and bash can neither
# trap nor receive a signal that was ignored when it started — the case would then test the launcher.
@test "reviewer-lanes: a TERM or INT during the lane report fails it (143/130), never reads as 0 errors" {
  local sig want
  for sig in TERM INT; do
    case "$sig" in TERM) want=143 ;; INT) want=130 ;; esac
    run perl -e 'my $s = shift; $SIG{$s} = "DEFAULT"; exec { $ARGV[0] } @ARGV; exit 127' "$sig" \
      bash -c '. "$1" || exit 97; . "$2" || exit 97; sig="$3"
      zrl_scan_md() { printf "%s\n" "x.md:4:model: review-alt"; sh -c "kill -$sig \$PPID"; return 0; }
      zrl_scan_and_report_lanes Test /nonexistent
      echo "rc=$?"' _ "$REPO_ROOT/scripts/lib/portable.sh" "$LANES_LIB" "$sig"
    output_has "rc=$want" || { echo "SIG$sig" >&2; return 1; }
  done
}
@test "teardown_file guard: an existing sandbox outside /tmp and /var/folders is refused and survives (TMPDIR unset, or pointing at it)" {
  make_guard_probe
  # TMPDIR unset: the exact environment in which the removed `"${TMPDIR%/}"/*` arm became `/*`.
  run teardown_as unset "$GUARD_PROBE"
  [ "$status" -eq 0 ]
  output_has "teardown_file: refusing to remove unexpected sandbox '$GUARD_PROBE'"
  [ -f "$GUARD_PROBE/sentinel" ]
  # TMPDIR pointing at the probe's parent: the guard must not trust TMPDIR in either direction.
  run teardown_as "${GUARD_PROBE%/*}" "$GUARD_PROBE"
  [ "$status" -eq 0 ]
  output_has "teardown_file: refusing to remove unexpected sandbox '$GUARD_PROBE'"
  [ -f "$GUARD_PROBE/sentinel" ]
}

@test "teardown_file guard: the repository, its dist and .git, /, a relative path and an empty value are never removed" {
  local target ctl
  # Control FIRST: the recorder DOES see the removal of a sandbox under a mktemp prefix, so the
  # RM-CALLED checks below are able to fail. First, because it is the only proof the recorder
  # intercepts at all: were teardown_file's rm respelled past it AND the guard regressed, the loop
  # below would really delete the checkout — a control run after it would report that too late.
  ctl="$(mktemp -d /tmp/zuvo-guard-ctl.XXXXXX)"
  run teardown_rm_spy "$ctl"
  command rm -rf -- "$ctl"
  output_has "RM-CALLED -rf $ctl" || return 1
  output_lacks "refusing to remove" || return 1
  for target in "$REPO_ROOT" "$REPO_ROOT/dist" "$REPO_ROOT/.git" / dist ""; do
    run teardown_rm_spy "$target"
    [ "$status" -eq 0 ]
    output_has "teardown_file: refusing to remove unexpected sandbox '$target'"
    output_lacks "RM-CALLED"
  done
}

@test "setup_file guard: a failing mktemp -d, or one naming no directory, fails closed and creates nothing" {
  local shim="$BATS_TEST_TMPDIR/shim" calls="$BATS_TEST_TMPDIR/mkdir.calls" variant
  mkdir -p "$shim"
  # mkdir RECORDS instead of creating: a setup_file that got past its guard would `mkdir -p /dist`.
  printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$calls" > "$shim/mkdir"
  chmod +x "$shim/mkdir"
  for variant in 'exit 1' 'exit 0' 'echo /nonexistent/zuvo-dist-sandbox'; do
    printf '#!/bin/sh\n%s\n' "$variant" > "$shim/mktemp"
    chmod +x "$shim/mktemp"
    run setup_file_with_shims "$shim"
    [ "$status" -ne 0 ]
    output_has "setup_file: mktemp -d failed — refusing to run with an unset sandbox"
    output_has "root=[]"
    [ ! -e "$calls" ]
  done
}
