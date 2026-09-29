#!/usr/bin/env bats

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
# registry_ids — the two Codex review ids model-registry.sh gives in THIS environment (the same one
# the build under test inherits), as REG_PRIMARY and REG_ALT. Read from two NAMED lines, and the call
# fails unless there are exactly two lines and both ids are non-empty — no positional word splitting
# that could drop or merge a value.
registry_ids() {
  local out
  out="$(bash -c '. "$1"/shared/includes/model-registry.sh
    printf "primary=%s\nalt=%s\n" "$ZUVO_MODEL_CODEX_PRIMARY" "$ZUVO_MODEL_CODEX_REVIEW_ALT"' _ "$REPO_ROOT")" || return 1
  REG_PRIMARY="$(printf '%s\n' "$out" | sed -n 's/^primary=//p')"
  REG_ALT="$(printf '%s\n' "$out" | sed -n 's/^alt=//p')"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 2 ] && [ -n "$REG_PRIMARY" ] && [ -n "$REG_ALT" ] \
    || { printf 'registry_ids: expected two non-empty ids, got [%s]\n' "$out" >&2; return 1; }
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
  mkdir -p "$fk/tests/lib" "$fk/scripts/lib" "$fk/skills"
  cp "$REPO_ROOT/tests/lib/dist-build.sh" "$fk/tests/lib/"
  cp "$REPO_ROOT/scripts/build-codex-skills.sh" "$fk/scripts/"
  cp "$REPO_ROOT"/scripts/lib/*.sh "$fk/scripts/lib/"
  cp -R "$REPO_ROOT/shared" "$REPO_ROOT/rules" "$REPO_ROOT/.codex-plugin" "$fk/"
  if [ "${2:-}" = full ]; then
    cp -R "$REPO_ROOT/skills" "$REPO_ROOT/hooks" "$fk/"
  else
    mkdir -p "$fk/skills/zz-min"
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
}

@test "Codex build fails closed: no model registry in the tree it builds, no build" {
  local fk="$BATS_TEST_TMPDIR/fixture-noreg" root="$BATS_TEST_TMPDIR/dist-noreg"
  codex_fixture "$fk"
  mkdir -p "$root"
  rm "$fk/shared/includes/model-registry.sh"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" codex
  [ "$status" -eq 1 ]
  output_has "model registry not found: $fk/shared/includes/model-registry.sh"
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
  # THE ERROR COUNT, exactly as the build counts it: each agent whose model the build cannot map is ONE
  # error (its TOML is not written); every lane still standing as a model in the emitted files is ONE
  # error in all — the leftover scan lists those under a single ERROR line, with their number.
  #   no readable model (6): fx-indent fx-spaced — no column-0 `model:`; fx-bom fx-trail fx-blank
  #                          fx-nofm — no frontmatter starting on line 1 (the strict reader is the
  #                          Claude rewriter's grammar, so what that rewriter cannot take fails here too)
  #   not mappable      (7): fx-cross fx-case fx-flow fx-comma fx-block fx-substr, and fx-quoted — a
  #                          lane is taken only as the whole, unquoted value, as the Claude rewriter
  #                          takes it (never the old gpt-5.4 catch-all, never quote-stripping into a lane)
  #   leftovers         (1): the overlay, fx-bom, fx-indent, fx-spaced, fx-trail — 5 references
  output_has "BUILD FAILED: 14 error(s)"
  for n in fx-indent fx-spaced fx-bom fx-trail fx-blank fx-nofm; do
    output_has "$fx/$n.md has no readable \`model:\`" || return 1
  done
  for n in fx-cross fx-case fx-flow fx-comma fx-block fx-substr fx-quoted; do
    output_has "$fx/$n.md: model value [" || return 1
  done
  output_has "Abstract reviewer lanes remain in Codex dist: 5 leftover lane reference(s)"
  output_has "$root/codex/skills/zz-lane-fixture/SKILL.md:4:model: review-primary"
  for n in fx-bom fx-indent fx-spaced fx-trail; do
    output_has "$root/codex/skills/zz-lane-fixture/agents/$n.md:4:" || return 1
  done
  output_lacks "Prose may quote the review-alt lane"
  output_lacks "SKILL.md:9:"
  # RESOLVED — the plain spellings both targets take — so named by no error, and their TOMLs carry the
  # registry's ids.
  for n in fx-plain fx-plainalt fx-comment fx-crlf fx-body fx-commentlane fx-commentquoted; do
    output_lacks "/$n.md" || return 1
  done
  registry_ids
  for n in fx-plain fx-comment; do toml_model_is "$root" "zz-lane-fixture-$n" "$REG_PRIMARY" || return 1; done
  for n in fx-plainalt fx-crlf; do toml_model_is "$root" "zz-lane-fixture-$n" "$REG_ALT" || return 1; done
}

@test "Codex build: an agent with no model it can map fails the build by name — never the gpt-5.4 default" {
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
  output_has "$a/zz-unknown.md: model value [gpt-4o] is not one the Codex build maps"
  output_has "$a/zz-dashn.md: model value [-n opus] is not one the Codex build maps"
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
  # Two agents whose TOML names collide (write-e2e's prefix is `e2e`): one TOML would silently stand for
  # both, and the SECOND (write-e2e's, with a model no build maps) would never be checked. The build
  # names the collision and fails.
  mkdir -p "$fk/skills/write-e2e/agents" "$fk/skills/e2e/agents"
  printf '%s\n' '---' 'name: e2e' 'description: fixture' '---' '# zuvo:e2e' > "$fk/skills/e2e/SKILL.md"
  printf '%s\n' '---' 'name: write-e2e' 'description: fixture' '---' '# zuvo:write-e2e' > "$fk/skills/write-e2e/SKILL.md"
  printf '%s\n' '---' 'name: zz-dup' 'description: planted' 'model: sonnet' '---' > "$fk/skills/e2e/agents/zz-dup.md"
  printf '%s\n' '---' 'name: zz-dup' 'description: planted' 'model: cross-vendor' '---' > "$fk/skills/write-e2e/agents/zz-dup.md"
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
  # the incomplete scans AND show what they had found (the TOML scan: nothing).
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
  output_has "could not scan the Codex dist for unresolved reviewer lanes (agent TOMLs)"
  output_has "could not scan the Codex dist for unresolved reviewer lanes (markdown)"
  output_has "$root/codex/skills/zz-min/SKILL.md:4:model: review-alt"
  output_has "(it had found none before it stopped)"
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

@test "reviewer-lanes: a model id is exactly what the router's zms_is_model_id accepts, in every locale" {
  local id loc locales="C" u parity="$BATS_TEST_TMPDIR/id-parity.sh"
  for id in gpt-6-sol gpt-x:1 claude-opus-5-5 opus a.b_c 5x A0._:-Z9; do
    lanes zrl_is_model_id "$id" || { echo "[$id] rejected" >&2; return 1; }
  done
  for id in '' 'gpt x' '-x' '.x' ':x' 'a/b' 'x$' 'x*' 'x?' 'x=y' 'a;b' 'a&b' 'a`b' 'a$(b)' "$(printf 'gpt-\303\251')" "$(printf 'a\nb')"; do
    ! lanes zrl_is_model_id "$id" || { echo "[$id] accepted" >&2; return 1; }
  done
  # PARITY with the router's grammar (zms_is_model_id, which the router calls): extracted VERBATIM from
  # scripts/lib/model-subprocess.sh (never
  # restated here), both run over one probe list, and every probe must get the same verdict — under
  # LC_ALL=C and under a UTF-8 locale (the pattern of test-reviewer-preflight-isolation.sh 0g).
  {
    awk '/^ZMS_ID_ALNUM=/{f=1} f{print} f && /^}/{exit}' "$REPO_ROOT/scripts/lib/model-subprocess.sh"
    printf '. "%s"\n' "$LANES_LIB"
    cat <<'PARITY'
rc=0
for p in gpt-6-sol gpt-x:1 opus A0._:-Z9 5x '' 'gpt x' '-x' '.x' ':x' 'a/b' 'x$' 'x*' 'x?' 'x=y' 'a;b' 'a&b' 'a`b' 'a$(b)' $'gpt-\xc3\xa9' $'a\nb' $'cr\rhere'; do
  r=0; z=0
  zms_is_model_id "$p" && r=1
  zrl_is_model_id "$p" && z=1
  if [ "$r" != "$z" ]; then printf 'MISMATCH [%q] router=%s lanes=%s\n' "$p" "$r" "$z"; rc=1; fi
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

# ── RED/GREEN: a lane in an agent frontmatter key none of the builds' own transforms recognizes
# still fails the build (plan C Task 4, updated fix round 1/2). plant_unrecognized_model_key_agent's
# `Model:` key spelling is invisible to every build's own per-agent awk (case-sensitive, column-0
# `/^model:/` only) AND to `zrl_frontmatter_model` (the SAME case-sensitive column-0 reader) — so
# this is caught as "no readable model:" before adapt_agent_for_* is ever called; no dst file is
# written. Paths are EXACT and anchored (fix round 2, F4): the source glob
# `"$skill_dir/agents/"*.md` always doubles the slash after a skill directory (the outer glob
# `"$PLUGIN_DIR"/skills/*/` already ends in one) — `$asrc` below is built the same way so the
# assertion matches byte for byte, not a loose "agents/foo.md" substring.
@test "Cursor build: an agent frontmatter key none of the builds recognize fails the build, naming the file" {
  local fk="$BATS_TEST_TMPDIR/cursor-fixture" root="$BATS_TEST_TMPDIR/cursor-fixture-dist" a asrc
  platform_fixture "$fk" cursor
  a="$fk/skills/zz-min/agents"; asrc="$fk/skills/zz-min/agents"
  plant_unrecognized_model_key_agent "$a" badlane review-alt
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" cursor
  [ "$status" -ne 0 ]
  output_has "$asrc/badlane.md has no readable \`model:\` (a column-0 key in a frontmatter that starts on line 1) — the Cursor build does not guess one"
  # Contextual, not a bare common word (fix round 3, W13): the resolved-value SHAPE, not just
  # whether "inherit" appears anywhere in the log.
  output_lacks "model: inherit"
}

@test "Antigravity build: an agent frontmatter key none of the builds recognize fails the build, naming the file" {
  local fk="$BATS_TEST_TMPDIR/antigravity-fixture" root="$BATS_TEST_TMPDIR/antigravity-fixture-dist" a asrc
  platform_fixture "$fk" antigravity
  a="$fk/skills/zz-min/agents"; asrc="$fk/skills/zz-min/agents"
  plant_unrecognized_model_key_agent "$a" badlane review-primary
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" antigravity
  [ "$status" -ne 0 ]
  output_has "$asrc/badlane.md has no readable \`model:\` (a column-0 key in a frontmatter that starts on line 1) — the Antigravity build does not guess one"
  # Contextual, not a bare common word (fix round 3, W13): the resolved-value SHAPE.
  output_lacks "model: gemini-3.1-pro-high"
}

@test "Kimi build: an agent frontmatter key none of the builds recognize fails the build, naming the file" {
  local fk="$BATS_TEST_TMPDIR/kimi-fixture" root="$BATS_TEST_TMPDIR/kimi-fixture-dist" a asrc
  platform_fixture "$fk" kimi
  a="$fk/skills/zz-min/agents"; asrc="$fk/skills/zz-min/agents"
  plant_unrecognized_model_key_agent "$a" badlane review-alt
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" kimi
  [ "$status" -ne 0 ]
  output_has "$asrc/badlane.md has no readable \`model:\` (a column-0 key in a frontmatter that starts on line 1) — the Kimi build does not guess one"
  # Contextual, not a bare common word (fix round 3, W13): the resolved-value SHAPE.
  output_lacks "model_preference: secondary"
}

# ── F5: "no readable model:" (no key at all) for all three builds, each with its own EXACT
# anchored path and message.
@test "Cursor build: no readable model: at all fails by name (a frontmatter with no model key)" {
  local fk="$BATS_TEST_TMPDIR/cursor-nomodel" root="$BATS_TEST_TMPDIR/cursor-nomodel-dist" a asrc
  platform_fixture "$fk" cursor
  a="$fk/skills/zz-min/agents"; asrc="$fk/skills/zz-min/agents"
  plant_agent_fixture "$a" nomodel
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" cursor
  [ "$status" -ne 0 ]
  output_has "$asrc/nomodel.md has no readable \`model:\` (a column-0 key in a frontmatter that starts on line 1) — the Cursor build does not guess one"
}

@test "Antigravity build: no readable model: at all fails by name (a frontmatter with no model key)" {
  local fk="$BATS_TEST_TMPDIR/antigravity-nomodel" root="$BATS_TEST_TMPDIR/antigravity-nomodel-dist" a asrc
  platform_fixture "$fk" antigravity
  a="$fk/skills/zz-min/agents"; asrc="$fk/skills/zz-min/agents"
  plant_agent_fixture "$a" nomodel
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" antigravity
  [ "$status" -ne 0 ]
  output_has "$asrc/nomodel.md has no readable \`model:\` (a column-0 key in a frontmatter that starts on line 1) — the Antigravity build does not guess one"
}

@test "Kimi build: no readable model: at all fails by name (a frontmatter with no model key)" {
  local fk="$BATS_TEST_TMPDIR/kimi-nomodel" root="$BATS_TEST_TMPDIR/kimi-nomodel-dist" a asrc
  platform_fixture "$fk" kimi
  a="$fk/skills/zz-min/agents"; asrc="$fk/skills/zz-min/agents"
  plant_agent_fixture "$a" nomodel
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" kimi
  [ "$status" -ne 0 ]
  output_has "$asrc/nomodel.md has no readable \`model:\` (a column-0 key in a frontmatter that starts on line 1) — the Kimi build does not guess one"
}

# ── RED/GREEN: a lane in a rules/ file's OWN frontmatter still fails the build (plan C Task 4 fix
# round 1, C3/C4). No zrl_agent_model_known gate runs over rules/, so this exercises the leftover
# scan directly.
@test "Cursor build: a lane in rules/ frontmatter fails the build, naming the file" {
  local fk="$BATS_TEST_TMPDIR/cursor-rules-fixture" root="$BATS_TEST_TMPDIR/cursor-rules-fixture-dist"
  platform_fixture "$fk" cursor
  plant_rules_lane_fixture "$fk/rules" zz-lane-fixture review-primary
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" cursor
  [ "$status" -ne 0 ]
  output_has "Abstract reviewer lanes remain in Cursor dist (1 leftover reference(s) — a route word, or an unparsable value, in a frontmatter model key):"
  output_has "$root/cursor/rules/zz-lane-fixture.md:3:model: review-primary"
}

# ── Q11 round 4, N5: multi-hit counting. Two SEPARATE lane hits, in two different files, must be
# counted as 2 (per-instance, fix round 3's A10), not a flat +1 for "the scan found something".
# zrl_scan_and_report_lanes is the ONE shared helper all three builds call, so exercising it once
# through Cursor covers the counting logic itself; Antigravity's and Kimi's single-hit "(1 leftover
# reference(s)...)" wording is already covered by the tests directly below.
@test "Cursor build: two leftover lane hits in two files count as 2, not a flat 1" {
  local fk="$BATS_TEST_TMPDIR/cursor-multi-lane" root="$BATS_TEST_TMPDIR/cursor-multi-lane-dist"
  platform_fixture "$fk" cursor
  plant_rules_lane_fixture "$fk/rules" zz-lane-one review-primary
  plant_rules_lane_fixture "$fk/rules" zz-lane-two review-alt
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" cursor
  [ "$status" -ne 0 ]
  output_has "Abstract reviewer lanes remain in Cursor dist (2 leftover reference(s) — a route word, or an unparsable value, in a frontmatter model key):"
  output_has "$root/cursor/rules/zz-lane-one.md:3:model: review-primary"
  output_has "$root/cursor/rules/zz-lane-two.md:3:model: review-alt"
  # EXACT total (matching the W10 pattern): the 2 lane hits plus the ONE pre-existing, unrelated
  # "Missing Cursor blind audit reviewer agents" every minimal (non-`full`) fixture always trips.
  output_has "BUILD FAILED: 3 error(s)"
}

@test "Antigravity build: a lane in rules/ frontmatter fails the build, naming the file" {
  local fk="$BATS_TEST_TMPDIR/antigravity-rules-fixture" root="$BATS_TEST_TMPDIR/antigravity-rules-fixture-dist"
  platform_fixture "$fk" antigravity
  plant_rules_lane_fixture "$fk/rules" zz-lane-fixture review-alt
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" antigravity
  [ "$status" -ne 0 ]
  output_has "Abstract reviewer lanes remain in Antigravity dist (1 leftover reference(s) — a route word, or an unparsable value, in a frontmatter model key):"
  output_has "$root/antigravity/rules/zz-lane-fixture.md:3:model: review-alt"
}

@test "Kimi build: a lane in rules/ frontmatter fails the build, naming the file" {
  local fk="$BATS_TEST_TMPDIR/kimi-rules-fixture" root="$BATS_TEST_TMPDIR/kimi-rules-fixture-dist"
  platform_fixture "$fk" kimi
  plant_rules_lane_fixture "$fk/rules" zz-lane-fixture review-primary
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" kimi
  [ "$status" -ne 0 ]
  output_has "Abstract reviewer lanes remain in Kimi dist (1 leftover reference(s) — a route word, or an unparsable value, in a frontmatter model key):"
  output_has "$root/kimi/rules/zz-lane-fixture.md:3:model: review-primary"
}

# ── F7: the same fixture shape in shared/includes/ — a SEPARATE tree from rules/, proving the
# scan covers both, not just whichever one C3 originally named. A real, untouched shared include
# (env-compat.md, copied into every fixture by platform_fixture) stays present and unaffected —
# the "valid file survives" half of F7.
@test "Cursor build: a lane in shared/includes/ frontmatter fails the build; a real include is untouched" {
  local fk="$BATS_TEST_TMPDIR/cursor-shared-fixture" root="$BATS_TEST_TMPDIR/cursor-shared-fixture-dist"
  platform_fixture "$fk" cursor
  plant_rules_lane_fixture "$fk/shared/includes" zz-shared-lane review-alt
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" cursor
  [ "$status" -ne 0 ]
  output_has "$root/cursor/shared/includes/zz-shared-lane.md:3:model: review-alt"
  # fix round 3, W11: the SAME count of lane words survives, not just "at least one".
  lane_word_count_unchanged "$fk/shared/includes/env-compat.md" "$root/cursor/shared/includes/env-compat.md"
}

@test "Antigravity build: a lane in shared/includes/ frontmatter fails the build; a real include is untouched" {
  local fk="$BATS_TEST_TMPDIR/antigravity-shared-fixture" root="$BATS_TEST_TMPDIR/antigravity-shared-fixture-dist"
  platform_fixture "$fk" antigravity
  plant_rules_lane_fixture "$fk/shared/includes" zz-shared-lane review-primary
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" antigravity
  [ "$status" -ne 0 ]
  output_has "$root/antigravity/shared/includes/zz-shared-lane.md:3:model: review-primary"
  # fix round 3, W11: the SAME count of lane words survives, not just "at least one".
  lane_word_count_unchanged "$fk/shared/includes/env-compat.md" "$root/antigravity/shared/includes/env-compat.md"
}

@test "Kimi build: a lane in shared/includes/ frontmatter fails the build; a real include is untouched" {
  local fk="$BATS_TEST_TMPDIR/kimi-shared-fixture" root="$BATS_TEST_TMPDIR/kimi-shared-fixture-dist"
  platform_fixture "$fk" kimi
  plant_rules_lane_fixture "$fk/shared/includes" zz-shared-lane review-alt
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" kimi
  [ "$status" -ne 0 ]
  output_has "$root/kimi/shared/includes/zz-shared-lane.md:3:model: review-alt"
  # fix round 3, W11: the SAME count of lane words survives, not just "at least one".
  lane_word_count_unchanged "$fk/shared/includes/env-compat.md" "$root/kimi/shared/includes/env-compat.md"
}

# ── F7 + E3: references/*.md nests under skills/<skill>/references/ in all three builds (not a
# separate top-level $DIST/references — verified before writing this test: the SAME scan set that
# already covers $DIST/skills caught this fixture with ZERO code change, so no path was added for
# it). A valid reference file planted alongside the lane one stays present.
@test "Cursor build: a lane in references/ frontmatter fails the build; a valid reference survives" {
  local fk="$BATS_TEST_TMPDIR/cursor-ref-fixture" root="$BATS_TEST_TMPDIR/cursor-ref-fixture-dist"
  platform_fixture "$fk" cursor
  mkdir -p "$fk/skills/zz-min/references"
  plant_rules_lane_fixture "$fk/skills/zz-min/references" zz-ref-lane review-primary
  printf '%s\n' '# a valid reference doc' 'Nothing lane-shaped here.' > "$fk/skills/zz-min/references/zz-ref-ok.md"
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" cursor
  [ "$status" -ne 0 ]
  output_has "$root/cursor/skills/zz-min/references/zz-ref-lane.md:3:model: review-primary"
  [ -f "$root/cursor/skills/zz-min/references/zz-ref-ok.md" ]
}

@test "Antigravity build: a lane in references/ frontmatter fails the build; a valid reference survives" {
  local fk="$BATS_TEST_TMPDIR/antigravity-ref-fixture" root="$BATS_TEST_TMPDIR/antigravity-ref-fixture-dist"
  platform_fixture "$fk" antigravity
  mkdir -p "$fk/skills/zz-min/references"
  plant_rules_lane_fixture "$fk/skills/zz-min/references" zz-ref-lane review-alt
  printf '%s\n' '# a valid reference doc' 'Nothing lane-shaped here.' > "$fk/skills/zz-min/references/zz-ref-ok.md"
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" antigravity
  [ "$status" -ne 0 ]
  output_has "$root/antigravity/skills/zz-min/references/zz-ref-lane.md:3:model: review-alt"
  [ -f "$root/antigravity/skills/zz-min/references/zz-ref-ok.md" ]
}

@test "Kimi build: a lane in references/ frontmatter fails the build; a valid reference survives" {
  local fk="$BATS_TEST_TMPDIR/kimi-ref-fixture" root="$BATS_TEST_TMPDIR/kimi-ref-fixture-dist"
  platform_fixture "$fk" kimi
  mkdir -p "$fk/skills/zz-min/references"
  plant_rules_lane_fixture "$fk/skills/zz-min/references" zz-ref-lane review-primary
  printf '%s\n' '# a valid reference doc' 'Nothing lane-shaped here.' > "$fk/skills/zz-min/references/zz-ref-ok.md"
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" kimi
  [ "$status" -ne 0 ]
  output_has "$root/kimi/skills/zz-min/references/zz-ref-lane.md:3:model: review-primary"
  [ -f "$root/kimi/skills/zz-min/references/zz-ref-ok.md" ]
}

# ── RED: plan C Task 4 fix round 2, E1/E2/F1/F4/F6/F8 — the FULL decorated/malformed-value matrix,
# all in ONE fixture skill so one build run proves every shape. `zrl_agent_model_known` takes a
# lane only as the WHOLE, unquoted value and a tier only as an EXACT match (no first-word
# truncation) — Task 3's P9 rule: a quoted lane or tier fails exactly like an unquoted decorated
# one. Per F1: a failed build's dist is unspecified, so nothing here asserts a survivor's
# EXISTENCE — the companion "resolve correctly" tests below (a clean build) cover the positive
# case. Per F8: the message quotes the value once, in single quotes — no doubled brackets.
@test "Cursor build: every decorated or malformed model value fails by name, quoted once" {
  local fk="$BATS_TEST_TMPDIR/cursor-matrix" root="$BATS_TEST_TMPDIR/cursor-matrix-dist" a asrc
  platform_fixture "$fk" cursor
  a="$fk/skills/zz-min/agents"; asrc="$fk/skills/zz-min/agents"
  plant_agent_fixture "$a" gptweird 'model: gpt-weird'
  plant_agent_fixture "$a" crossvendor 'model: cross-vendor'
  plant_agent_fixture "$a" flowval 'model: [review-alt]'
  plant_agent_fixture "$a" commaval 'model: x,review-alt'
  plant_agent_fixture "$a" quotedlane 'model: "review-alt"'
  plant_agent_fixture "$a" quotedtier "model: 'sonnet'"
  plant_agent_fixture "$a" trailing 'model: sonnet extra'
  plant_agent_fixture "$a" unquotedpertask 'model: per-task'
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" cursor
  [ "$status" -ne 0 ]
  output_has "$asrc/gptweird.md: model value 'gpt-weird' is not one the Cursor build accepts"
  output_has "$asrc/crossvendor.md: model value 'cross-vendor' is not one the Cursor build accepts"
  output_has "$asrc/flowval.md: model value '[review-alt]' is not one the Cursor build accepts"
  output_lacks "[[review-alt]]"
  output_has "$asrc/commaval.md: model value 'x,review-alt' is not one the Cursor build accepts"
  output_has "$asrc/quotedlane.md: model value '\"review-alt\"' is not one the Cursor build accepts"
  output_has "$asrc/quotedtier.md: model value ''sonnet'' is not one the Cursor build accepts"
  output_has "$asrc/trailing.md: model value 'sonnet extra' is not one the Cursor build accepts"
  output_has "$asrc/unquotedpertask.md: model value 'per-task' is not one the Cursor build accepts"
  output_has "haiku, sonnet, opus, review-primary, review-alt, or a quoted \"per-task: …\" descriptor"
  # EXACT count (fix round 3, W10): the 8 named fixtures plus the ONE pre-existing, unrelated
  # "Missing Cursor blind audit reviewer agents" every minimal (non-`full`) fixture always trips
  # (no write-tests skill present) -- 9, not 8.
  output_has "BUILD FAILED: 9 error(s)"
}

@test "Antigravity build: every decorated or malformed model value fails by name, quoted once" {
  local fk="$BATS_TEST_TMPDIR/antigravity-matrix" root="$BATS_TEST_TMPDIR/antigravity-matrix-dist" a asrc
  platform_fixture "$fk" antigravity
  a="$fk/skills/zz-min/agents"; asrc="$fk/skills/zz-min/agents"
  plant_agent_fixture "$a" gptweird 'model: gpt-weird'
  plant_agent_fixture "$a" crossvendor 'model: cross-vendor'
  plant_agent_fixture "$a" flowval 'model: [review-alt]'
  plant_agent_fixture "$a" commaval 'model: x,review-alt'
  plant_agent_fixture "$a" quotedlane 'model: "review-alt"'
  plant_agent_fixture "$a" quotedtier "model: 'sonnet'"
  plant_agent_fixture "$a" trailing 'model: sonnet extra'
  plant_agent_fixture "$a" unquotedpertask 'model: per-task'
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" antigravity
  [ "$status" -ne 0 ]
  output_has "$asrc/gptweird.md: model value 'gpt-weird' is not one the Antigravity build accepts"
  output_has "$asrc/crossvendor.md: model value 'cross-vendor' is not one the Antigravity build accepts"
  output_has "$asrc/flowval.md: model value '[review-alt]' is not one the Antigravity build accepts"
  output_lacks "[[review-alt]]"
  output_has "$asrc/commaval.md: model value 'x,review-alt' is not one the Antigravity build accepts"
  output_has "$asrc/quotedlane.md: model value '\"review-alt\"' is not one the Antigravity build accepts"
  output_has "$asrc/quotedtier.md: model value ''sonnet'' is not one the Antigravity build accepts"
  output_has "$asrc/trailing.md: model value 'sonnet extra' is not one the Antigravity build accepts"
  output_has "$asrc/unquotedpertask.md: model value 'per-task' is not one the Antigravity build accepts"
  output_has "haiku, sonnet, opus, review-primary, review-alt, or a quoted \"per-task: …\" descriptor"
  output_has "BUILD FAILED: 9 error(s)"
}

@test "Kimi build: every decorated or malformed model value fails by name, quoted once" {
  local fk="$BATS_TEST_TMPDIR/kimi-matrix" root="$BATS_TEST_TMPDIR/kimi-matrix-dist" a asrc
  platform_fixture "$fk" kimi
  a="$fk/skills/zz-min/agents"; asrc="$fk/skills/zz-min/agents"
  plant_agent_fixture "$a" gptweird 'model: gpt-weird'
  plant_agent_fixture "$a" crossvendor 'model: cross-vendor'
  plant_agent_fixture "$a" flowval 'model: [review-alt]'
  plant_agent_fixture "$a" commaval 'model: x,review-alt'
  plant_agent_fixture "$a" quotedlane 'model: "review-alt"'
  plant_agent_fixture "$a" quotedtier "model: 'sonnet'"
  plant_agent_fixture "$a" trailing 'model: sonnet extra'
  plant_agent_fixture "$a" unquotedpertask 'model: per-task'
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" kimi
  [ "$status" -ne 0 ]
  output_has "$asrc/gptweird.md: model value 'gpt-weird' is not one the Kimi build accepts"
  output_has "$asrc/crossvendor.md: model value 'cross-vendor' is not one the Kimi build accepts"
  output_has "$asrc/flowval.md: model value '[review-alt]' is not one the Kimi build accepts"
  output_lacks "[[review-alt]]"
  output_has "$asrc/commaval.md: model value 'x,review-alt' is not one the Kimi build accepts"
  output_has "$asrc/quotedlane.md: model value '\"review-alt\"' is not one the Kimi build accepts"
  output_has "$asrc/quotedtier.md: model value ''sonnet'' is not one the Kimi build accepts"
  output_has "$asrc/trailing.md: model value 'sonnet extra' is not one the Kimi build accepts"
  output_has "$asrc/unquotedpertask.md: model value 'per-task' is not one the Kimi build accepts"
  output_has "haiku, sonnet, opus, review-primary, review-alt, or a quoted \"per-task: …\" descriptor"
  output_has "BUILD FAILED: 9 error(s)"
}

# ── GREEN: plan C Task 4 fix round 4 (Q11, N1-precise) — an agent whose description contains
# "registry" or "template" (the data-only heuristic's own trigger words) but which has a VALID
# readable `model:` must still SHIP, in every build. Mutation proof (recorded, not auto-run): remove
# only the `agent_model_rc -ne 0` half of the data-only skip's guard condition (keep `[ -r "$agent" ]`
# alone) in each build's per-agent loop — these agents go back to being silently skipped as
# "data-only", and the `[ -f ... ]` / TOML-existence assertions below go RED.
@test "Cursor build: an agent whose description says registry or template still ships (A1/N1-precise)" {
  local fk="$BATS_TEST_TMPDIR/cursor-a1" root="$BATS_TEST_TMPDIR/cursor-a1-dist" a
  # `full` (same reason as the per-task/CRLF GREEN tests above): a minimal zz-min-only fixture
  # always trips "Missing Cursor blind audit reviewer agents", so no build from one can exit 0.
  platform_fixture "$fk" cursor full
  mkdir -p "$fk/skills/zz-green/agents"
  printf '%s\n' '---' 'name: zz-green' 'description: fixture skill for the A1/N1-precise test' '---' '# zuvo:zz-green' '' 'Dispatch via Agent tool.' > "$fk/skills/zz-green/SKILL.md"
  a="$fk/skills/zz-green/agents"
  plant_dataonly_lookalike_agent "$a" zz-registry-scorer registry
  plant_dataonly_lookalike_agent "$a" zz-template-scorer template
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" cursor
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20 >&2; return 1; }
  output_lacks "zz-registry-scorer (data-only)"
  output_lacks "zz-template-scorer (data-only)"
  [ -f "$root/cursor/agents/zz-green-zz-registry-scorer.md" ]
  [ -f "$root/cursor/agents/zz-green-zz-template-scorer.md" ]
  model_is "$root/cursor/agents/zz-green-zz-registry-scorer.md" inherit
  model_is "$root/cursor/agents/zz-green-zz-template-scorer.md" inherit
}

@test "Antigravity build: an agent whose description says registry or template still ships (A1/N1-precise)" {
  local fk="$BATS_TEST_TMPDIR/antigravity-a1" root="$BATS_TEST_TMPDIR/antigravity-a1-dist" a
  platform_fixture "$fk" antigravity full
  mkdir -p "$fk/skills/zz-green/agents"
  printf '%s\n' '---' 'name: zz-green' 'description: fixture skill for the A1/N1-precise test' '---' '# zuvo:zz-green' '' 'Dispatch via Agent tool.' > "$fk/skills/zz-green/SKILL.md"
  a="$fk/skills/zz-green/agents"
  plant_dataonly_lookalike_agent "$a" zz-registry-scorer registry
  plant_dataonly_lookalike_agent "$a" zz-template-scorer template
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" antigravity
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20 >&2; return 1; }
  output_lacks "zz-registry-scorer (data-only)"
  output_lacks "zz-template-scorer (data-only)"
  [ -f "$root/antigravity/skills/zz-green/agents/zz-registry-scorer.md" ]
  [ -f "$root/antigravity/skills/zz-green/agents/zz-template-scorer.md" ]
  model_is "$root/antigravity/skills/zz-green/agents/zz-registry-scorer.md" gemini-3.1-pro-low
  model_is "$root/antigravity/skills/zz-green/agents/zz-template-scorer.md" gemini-3.1-pro-low
}

@test "Kimi build: an agent whose description says registry or template still ships (A1/N1-precise)" {
  local fk="$BATS_TEST_TMPDIR/kimi-a1" root="$BATS_TEST_TMPDIR/kimi-a1-dist" a
  platform_fixture "$fk" kimi full
  mkdir -p "$fk/skills/zz-green/agents"
  printf '%s\n' '---' 'name: zz-green' 'description: fixture skill for the A1/N1-precise test' '---' '# zuvo:zz-green' '' 'Dispatch via Agent tool.' > "$fk/skills/zz-green/SKILL.md"
  a="$fk/skills/zz-green/agents"
  plant_dataonly_lookalike_agent "$a" zz-registry-scorer registry
  plant_dataonly_lookalike_agent "$a" zz-template-scorer template
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" kimi
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20 >&2; return 1; }
  output_lacks "zz-registry-scorer (data-only)"
  output_lacks "zz-template-scorer (data-only)"
  [ -f "$root/kimi/agents/zz-green-zz-registry-scorer.md" ]
  [ -f "$root/kimi/agents/zz-green-zz-template-scorer.md" ]
  model_preference_is "$root/kimi/agents/zz-green-zz-registry-scorer.md" primary
  model_preference_is "$root/kimi/agents/zz-green-zz-template-scorer.md" primary
}

@test "Codex build: an agent whose description says registry or template still gets a TOML (A1/N1-precise)" {
  local fk="$BATS_TEST_TMPDIR/codex-a1" root="$BATS_TEST_TMPDIR/codex-a1-dist" a
  codex_fixture "$fk" full
  mkdir -p "$fk/skills/zz-green/agents"
  printf '%s\n' '---' 'name: zz-green' 'description: fixture skill for the A1/N1-precise test' '---' '# zuvo:zz-green' '' 'Dispatch via Agent tool.' > "$fk/skills/zz-green/SKILL.md"
  a="$fk/skills/zz-green/agents"
  plant_dataonly_lookalike_agent "$a" zz-registry-scorer registry
  plant_dataonly_lookalike_agent "$a" zz-template-scorer template
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" codex
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20 >&2; return 1; }
  output_lacks "zz-registry-scorer (data-only, no TOML)"
  output_lacks "zz-template-scorer (data-only, no TOML)"
  [ -f "$root/codex/agents/zz-green-zz-registry-scorer.toml" ]
  [ -f "$root/codex/agents/zz-green-zz-template-scorer.toml" ]
  run rg -F 'model = "gpt-5.4"' "$root/codex/agents/zz-green-zz-registry-scorer.toml"
  [ "$status" -eq 0 ]
  run rg -F 'model = "gpt-5.4"' "$root/codex/agents/zz-green-zz-template-scorer.toml"
  [ "$status" -eq 0 ]
}

# ── GREEN: plan C Task 4 fix round 2, E7/F6 — the per-task descriptor and a CRLF-terminated lane
# BOTH resolve correctly, in a clean build with no failing fixtures (so their dist files are
# guaranteed to exist — F1's "unspecified after a failure" concern does not apply here).
# `zrl_frontmatter_model` strips the trailing CR before handing back the value (verified directly
# against the library before writing this test), so `review-primary\r` materialises exactly like
# `review-primary`.
@test "Cursor build: the per-task descriptor and a CRLF-terminated lane both resolve correctly" {
  local fk="$BATS_TEST_TMPDIR/cursor-green" root="$BATS_TEST_TMPDIR/cursor-green-dist" a
  # `full` (fix round 3, W1): the real write-tests skill must be present for a genuine `status -eq
  # 0` -- a minimal (zz-min-only) fixture always trips "Missing Cursor blind audit reviewer
  # agents", so no build from one can ever exit 0 and this test could never really be green.
  platform_fixture "$fk" cursor full
  mkdir -p "$fk/skills/zz-green/agents"
  printf '%s\n' '---' 'name: zz-green' 'description: fixture skill for the resolve-correctly test' '---' '# zuvo:zz-green' '' 'Dispatch via Agent tool.' > "$fk/skills/zz-green/SKILL.md"
  a="$fk/skills/zz-green/agents"
  plant_agent_fixture "$a" pertask 'model: "per-task: sonnet for standard complexity, opus for complex"'
  printf -- '---\r\nname: crlf\r\ndescription: planted CRLF fixture\r\nmodel: review-primary\r\n---\r\nBody.\r\n' > "$a/crlf.md"
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" cursor
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20 >&2; return 1; }
  model_is "$root/cursor/agents/zz-green-pertask.md" inherit
  model_is "$root/cursor/agents/zz-green-crlf.md" inherit
}

@test "Antigravity build: the per-task descriptor and a CRLF-terminated lane both resolve correctly" {
  local fk="$BATS_TEST_TMPDIR/antigravity-green" root="$BATS_TEST_TMPDIR/antigravity-green-dist" a
  platform_fixture "$fk" antigravity full
  mkdir -p "$fk/skills/zz-green/agents"
  printf '%s\n' '---' 'name: zz-green' 'description: fixture skill for the resolve-correctly test' '---' '# zuvo:zz-green' '' 'Dispatch via Agent tool.' > "$fk/skills/zz-green/SKILL.md"
  a="$fk/skills/zz-green/agents"
  plant_agent_fixture "$a" pertask 'model: "per-task: sonnet for standard complexity, opus for complex"'
  printf -- '---\r\nname: crlf\r\ndescription: planted CRLF fixture\r\nmodel: review-alt\r\n---\r\nBody.\r\n' > "$a/crlf.md"
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" antigravity
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20 >&2; return 1; }
  # per-task now maps EXPLICITLY (fix round 3, A7) to gemini-3.1-pro-low, the same choice
  # build-codex-skills.sh's map_model makes for per-task -- not gemini-3.1-pro-high, which was
  # only ever reached by the $0 ~ /opus/ branch matching "opus for complex" as a substring.
  model_is "$root/antigravity/skills/zz-green/agents/pertask.md" gemini-3.1-pro-low
  model_is "$root/antigravity/skills/zz-green/agents/crlf.md" gemini-3.1-pro-low
}

@test "Kimi build: the per-task descriptor and a CRLF-terminated lane both resolve correctly" {
  local fk="$BATS_TEST_TMPDIR/kimi-green" root="$BATS_TEST_TMPDIR/kimi-green-dist" a
  platform_fixture "$fk" kimi full
  mkdir -p "$fk/skills/zz-green/agents"
  printf '%s\n' '---' 'name: zz-green' 'description: fixture skill for the resolve-correctly test' '---' '# zuvo:zz-green' '' 'Dispatch via Agent tool.' > "$fk/skills/zz-green/SKILL.md"
  a="$fk/skills/zz-green/agents"
  plant_agent_fixture "$a" pertask 'model: "per-task: sonnet for standard complexity, opus for complex"'
  printf -- '---\r\nname: crlf\r\ndescription: planted CRLF fixture\r\nmodel: review-alt\r\n---\r\nBody.\r\n' > "$a/crlf.md"
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" kimi
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20 >&2; return 1; }
  model_preference_is "$root/kimi/agents/zz-green-pertask.md" primary
  model_preference_is "$root/kimi/agents/zz-green-crlf.md" secondary
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

# ── G2 (Q11/TM6 mutation proof): a fixture agent made unreadable (chmod 000) reaches the
# `agent_model_rc -eq 2` branch. Skipped, never failed, when the test's own user cannot be locked
# out (root). Mode is restored in `teardown()` via ZT_UNREADABLE, even on a bats failure mid-test.
@test "Cursor build: an unreadable agent file fails with 'could not be read', never 'no readable model:'" {
  local fk="$BATS_TEST_TMPDIR/cursor-g2" root="$BATS_TEST_TMPDIR/cursor-g2-dist" a asrc
  platform_fixture "$fk" cursor
  a="$fk/skills/zz-min/agents"; asrc="$fk/skills/zz-min/agents"
  plant_agent_fixture "$a" unreadable 'model: sonnet'
  chmod 000 "$a/unreadable.md"
  export ZT_UNREADABLE="$a/unreadable.md"
  if [ -r "$a/unreadable.md" ]; then
    chmod 644 "$a/unreadable.md"
    skip "running as a user chmod 000 cannot lock out (root?)"
  fi
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" cursor
  [ "$status" -ne 0 ]
  output_has "$asrc/unreadable.md could not be read for its \`model:\`"
  output_lacks "no readable \`model:\`"
  output_lacks "data-only"
}

@test "Antigravity build: an unreadable agent file fails with 'could not be read', never 'no readable model:'" {
  local fk="$BATS_TEST_TMPDIR/antigravity-g2" root="$BATS_TEST_TMPDIR/antigravity-g2-dist" a asrc
  platform_fixture "$fk" antigravity
  a="$fk/skills/zz-min/agents"; asrc="$fk/skills/zz-min/agents"
  plant_agent_fixture "$a" unreadable 'model: sonnet'
  chmod 000 "$a/unreadable.md"
  export ZT_UNREADABLE="$a/unreadable.md"
  if [ -r "$a/unreadable.md" ]; then
    chmod 644 "$a/unreadable.md"
    skip "running as a user chmod 000 cannot lock out (root?)"
  fi
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" antigravity
  [ "$status" -ne 0 ]
  output_has "$asrc/unreadable.md could not be read for its \`model:\`"
  output_lacks "no readable \`model:\`"
  output_lacks "data-only"
}

@test "Kimi build: an unreadable agent file fails with 'could not be read', never 'no readable model:'" {
  local fk="$BATS_TEST_TMPDIR/kimi-g2" root="$BATS_TEST_TMPDIR/kimi-g2-dist" a asrc
  platform_fixture "$fk" kimi
  a="$fk/skills/zz-min/agents"; asrc="$fk/skills/zz-min/agents"
  plant_agent_fixture "$a" unreadable 'model: sonnet'
  chmod 000 "$a/unreadable.md"
  export ZT_UNREADABLE="$a/unreadable.md"
  if [ -r "$a/unreadable.md" ]; then
    chmod 644 "$a/unreadable.md"
    skip "running as a user chmod 000 cannot lock out (root?)"
  fi
  mkdir -p "$root"
  run env -u ZUVO_DIST_CACHE ZUVO_DIST_ROOT="$root" bash "$fk/tests/lib/dist-build.sh" kimi
  [ "$status" -ne 0 ]
  output_has "$asrc/unreadable.md could not be read for its \`model:\`"
  output_lacks "no readable \`model:\`"
  output_lacks "data-only"
}

# ── G3 (Q11/TM4 mutation proof): a scan-FAILURE fixture (awk_stub, the same tool the Codex test
# above uses) asserts the "could not scan" message carries the scanner's own stderr, AND that
# partial hits found before the scan stopped are shown separately, under their own label. Mutation
# proof recorded here: reverting the scan capture to `2>&1` (one variable, one label) makes BOTH
# assertions fail, because the diagnostic and the hit would print under the SAME "could not scan"
# block with no way to tell which is which — verified by hand against a `2>&1` copy of this block
# before writing the split version; not re-run automatically every suite run.
@test "Cursor build: a scan failure prints the scanner's stderr AND any hits found before it stopped" {
  local fk="$BATS_TEST_TMPDIR/cursor-g3" root="$BATS_TEST_TMPDIR/cursor-g3-dist"
  platform_fixture "$fk" cursor
  plant_rules_lane_fixture "$fk/rules" zz-scan-ok review-primary
  mkdir -p "$root/cursor"
  # Order-independent by construction (fix round 3, W2 — no sort added to zrl_scan_md itself:
  # find's own walk order is not guaranteed, but awk_stub's "after" mode does not rely on it. Its
  # generated stub runs the REAL awk over the WHOLE argument list first (finding every hit,
  # rules/zz-scan-ok.md included, wherever it falls in that list) and only THEN checks whether the
  # one registered path was among the args and fakes a failure for it — so which file "came first"
  # never matters here).
  awk_stub "$BATS_TEST_TMPDIR/awk-stub" after "$root/cursor/skills/zz-min/SKILL.md"
  run env -u ZUVO_DIST_CACHE PATH="$BATS_TEST_TMPDIR/awk-stub:$PATH" ZUVO_DIST_ROOT="$root" \
      bash "$fk/tests/lib/dist-build.sh" cursor
  [ "$status" -ne 0 ]
  output_has "awk-stub: cannot read $root/cursor/skills/zz-min/SKILL.md"
  output_has "could not scan the Cursor dist for unresolved reviewer lanes:"
  output_has "lanes it had found before the scan stopped:"
  output_has "$root/cursor/rules/zz-scan-ok.md:3:model: review-primary"
  # SECTION placement, not just presence (fix round 4, Q11 TM4 variant): the diagnostic must be
  # under "could not scan", strictly before the "lanes it had found" heading, and the hit strictly
  # after it.
  assert_line_order "awk-stub: cannot read $root/cursor/skills/zz-min/SKILL.md" \
    "lanes it had found before the scan stopped:" \
    "$root/cursor/rules/zz-scan-ok.md:3:model: review-primary"
}

@test "Antigravity build: a scan failure prints the scanner's stderr AND any hits found before it stopped" {
  local fk="$BATS_TEST_TMPDIR/antigravity-g3" root="$BATS_TEST_TMPDIR/antigravity-g3-dist"
  platform_fixture "$fk" antigravity
  plant_rules_lane_fixture "$fk/rules" zz-scan-ok review-alt
  mkdir -p "$root/antigravity"
  awk_stub "$BATS_TEST_TMPDIR/awk-stub" after "$root/antigravity/skills/zz-min/SKILL.md"
  run env -u ZUVO_DIST_CACHE PATH="$BATS_TEST_TMPDIR/awk-stub:$PATH" ZUVO_DIST_ROOT="$root" \
      bash "$fk/tests/lib/dist-build.sh" antigravity
  [ "$status" -ne 0 ]
  output_has "awk-stub: cannot read $root/antigravity/skills/zz-min/SKILL.md"
  output_has "could not scan the Antigravity dist for unresolved reviewer lanes:"
  output_has "lanes it had found before the scan stopped:"
  output_has "$root/antigravity/rules/zz-scan-ok.md:3:model: review-alt"
  assert_line_order "awk-stub: cannot read $root/antigravity/skills/zz-min/SKILL.md" \
    "lanes it had found before the scan stopped:" \
    "$root/antigravity/rules/zz-scan-ok.md:3:model: review-alt"
}

@test "Kimi build: a scan failure prints the scanner's stderr AND any hits found before it stopped" {
  local fk="$BATS_TEST_TMPDIR/kimi-g3" root="$BATS_TEST_TMPDIR/kimi-g3-dist"
  platform_fixture "$fk" kimi
  plant_rules_lane_fixture "$fk/rules" zz-scan-ok review-primary
  mkdir -p "$root/kimi"
  awk_stub "$BATS_TEST_TMPDIR/awk-stub" after "$root/kimi/skills/zz-min/SKILL.md"
  run env -u ZUVO_DIST_CACHE PATH="$BATS_TEST_TMPDIR/awk-stub:$PATH" ZUVO_DIST_ROOT="$root" \
      bash "$fk/tests/lib/dist-build.sh" kimi
  [ "$status" -ne 0 ]
  output_has "awk-stub: cannot read $root/kimi/skills/zz-min/SKILL.md"
  output_has "could not scan the Kimi dist for unresolved reviewer lanes"
  output_has "lanes it had found before the scan stopped:"
  output_has "$root/kimi/rules/zz-scan-ok.md:3:model: review-primary"
  assert_line_order "awk-stub: cannot read $root/kimi/skills/zz-min/SKILL.md" \
    "lanes it had found before the scan stopped:" \
    "$root/kimi/rules/zz-scan-ok.md:3:model: review-primary"
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
