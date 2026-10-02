#!/usr/bin/env bash
# Platform builds must rewrite the THREE-level relative include paths — and nothing else.
#
# skills/<x>/references/*.md and skills/<x>/agents/*.md reach the shared includes with
# `../../../shared/includes/...` (SKILL.md itself uses two levels). The Codex and Cursor
# builders rewrite both depths. The Antigravity and Kimi builders only knew `../../`, and
# because their rules are unanchored sed patterns, `../../../shared/x.md` came out as
# `../~/.gemini/antigravity/shared/x.md` — a dead path, so every include loaded from a
# references/ or agents/ file silently failed to resolve on those two platforms.
#
# The rule ORDER matters as much as the rules: the five `../../../` rules must run BEFORE
# the `../../` rules, otherwise the shorter pattern eats the tail of the longer one and
# leaves a stray `../` in front of the rewritten target.
#
# The dots matter too: in a sed BRE an unescaped `.` is a wildcard, so `../../skills/`
# also matched `ev/en/skills/` and turned the shipped URL
# `https://zuvo.dev/en/skills/seo-audit` into `https://zuvo.d~/.gemini/config/skills/seo-audit`.
# Synthetic inputs alone missed that, so the shipped skills/, shared/ and rules/ markdown
# goes through every builder against a DIFFERENTIAL ORACLE: the builder's own function with
# the `../` rules removed, followed by a literal (no-regex) rewrite of those paths. For every
# line, real output must equal oracle output — a wildcard match, a wrong order or a missing
# rule shows up as a difference, with no list of "legitimate" changes to maintain.
#
# Each builder's replace_paths() is extracted with awk (brace depth) and evaluated — the
# builders themselves are never run (a full build is slow and the shared dist cache owns
# that, see test-dist-build-cache.sh).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

# Per-platform targets: root for shared/scripts/rules, and the skills/ root (Antigravity
# keeps skills in its shared customization root, not under its own home). A builder with no
# entry here is reported loudly instead of going untested.
platform_home() {
  case "$1" in
    codex)       printf '%s' '~/.codex' ;;
    cursor)      printf '%s' '~/.cursor' ;;
    antigravity) printf '%s' '~/.gemini/antigravity' ;;
    kimi)        printf '%s' '~/.kimi-code' ;;
  esac
}
platform_skills() {
  case "$1" in
    codex)       printf '%s' '~/.codex/skills' ;;
    cursor)      printf '%s' '~/.cursor/skills' ;;
    antigravity) printf '%s' '~/.gemini/config/skills' ;;
    kimi)        printf '%s' '~/.kimi-code/skills' ;;
  esac
}

# extract_def <platform>: print the builder's replace_paths() definition, or fail. Taken by
# brace depth from the definition line; exactly one definition line, a closing `}` as the
# last line, fewer than 60 lines and a clean `bash -n` — a broken extraction would otherwise
# hand `eval` part of the builder, which would RUN it. ({plugin_root} is balanced per line.)
extract_def() {
  local src="$ROOT/scripts/build-$1-skills.sh" count def last n
  count="$(grep -c '^replace_paths() *{' "$src")"
  [ "$count" = "1" ] || return 1
  def="$(awk '
    !on && /^replace_paths\(\) *\{/ { on = 1 }
    on {
      print
      line = $0
      o = gsub(/\{/, "{", line); c = gsub(/\}/, "}", line)
      depth += o - c
      if (depth <= 0) exit
    }' "$src")"
  last="$(printf '%s\n' "$def" | tail -n 1)"
  [ "$last" = "}" ] || return 1
  n="$(printf '%s\n' "$def" | wc -l)"
  [ "$((n + 0))" -lt 60 ] || return 1
  printf '%s\n' "$def" | bash -n 2> /dev/null || return 1
  printf '%s\n' "$def"
}

# reduce_def <definition>: the same function, renamed reduced_paths, without the `../` rules
# (escaped or not, so a regressed unescaped rule is stripped too).
# The `../` rules are the tail of the sed command, so a no-op rule closes the continuation.
reduce_def() {
  printf '%s\n' "$1" | awk '
    /^[[:space:]]+-e .s[|]((\\)?[.](\\)?[.]\/)+/ { next }
    /^\}$/ { print "    -e '"'"'s/^$//'"'"'" }
    { sub(/^replace_paths\(\)/, "reduced_paths()"); print }'
}

# unescaped_dot_rules <definition>: print every `-e 's|<pattern>|...|'` rule whose pattern side
# holds a `.` not preceded by a backslash — in a sed BRE that dot is a wildcard.
unescaped_dot_rules() {
  printf '%s\n' "$1" | awk '
    /^[[:space:]]+-e .s[|]/ {
      line = $0
      sub(/^[[:space:]]+-e .s[|]/, "", line)
      lhs = substr(line, 1, index(line, "|") - 1)
      if (lhs ~ /(^|[^\\])[.]/) print $0
    }'
}

# rewrite <platform> <text>: run <text> through that builder's replace_paths().
rewrite() {
  local def
  def="$(extract_def "$1")" || { printf 'NO-FUNCTION\n'; return 0; }
  (
    eval "$def"
    printf '%s\n' "$2" | replace_paths
  )
}

# expect <platform> <input> <expected-output>
expect() {
  local platform="$1" input="$2" want="$3" got
  got="$(rewrite "$platform" "$input")"
  if [ "$got" = "$want" ]; then
    pass "$platform: $input -> $want"
  else
    bad "$platform: $input -> got '$got', want '$want'"
  fi
}

# ── the shipped corpus ───────────────────────────────────────────────────────────────────
# Enumerated once; the farm mirror has no .git, so no git ls-files. CORPUS holds every line
# of every file (awk normalises a missing final newline so files cannot fuse), IDX holds
# "file:line" for each corpus line, in the same order.
FILES_LIST="$(mktemp)"; CORPUS="$(mktemp)"; IDX="$(mktemp)"; OUT_REAL="$(mktemp)"; OUT_RED="$(mktemp)"
trap 'rm -f "$FILES_LIST" "$CORPUS" "$IDX" "$OUT_REAL" "$OUT_RED"' EXIT
find "$ROOT/skills" "$ROOT/shared" "$ROOT/rules" -name '*.md' 2> /dev/null | sort > "$FILES_LIST"
FILE_COUNT="$(wc -l < "$FILES_LIST")"
xargs awk -v idx="$IDX" -v root="$ROOT/" '
  { f = FILENAME; sub("^" root, "", f); print f ":" FNR >> idx; print }' < "$FILES_LIST" > "$CORPUS"
CORPUS_LINES="$(wc -l < "$CORPUS")"
ELIGIBLE_LINES="$(awk '/[.][.]\/[.][.]\/(shared|scripts|rules|skills)\//' "$CORPUS" | wc -l)"

# The oracle + comparison. Reads OUT_REAL (the real function's output) as the main input and
# the other three streams line-for-line: idx, the input, and the reduced function's output,
# which it rewrites literally (index()/substr(), no regex) for ../../../ then ../../.
read -r -d '' CMP_AWK <<'AWK_EOF' || true
function repl(s, from, to,    out, i) {
  out = ""
  while ((i = index(s, from)) > 0) {
    out = out substr(s, 1, i - 1) to
    s = substr(s, i + length(from))
  }
  return out s
}
function lit(s,    d, k, from, to) {
  for (d = 1; d <= 2; d++)
    for (k = 1; k <= 5; k++) {
      from = pre[d] dirs[k] "/"
      to = (dirs[k] == "skills") ? S "/" : H "/" dirs[k] "/"
      s = repl(s, from, to)
    }
  return s
}
function clip(s) { return length(s) > 200 ? substr(s, 1, 200) "..." : s }
BEGIN {
  pre[1] = "../../../"; pre[2] = "../../"
  dirs[1] = "shared/includes"; dirs[2] = "shared"; dirs[3] = "scripts"; dirs[4] = "rules"; dirs[5] = "skills"
}
{
  real = $0
  getline where < IDXF
  getline input < INF
  getline reduced < REDF
  want = lit(reduced)
  if (index(real, "../~")) { na++; if (!A) { print "A " where ": " clip(real); A = 1 } }
  if (real != want)        { nb++; if (!B) { print "B " where ": in  " clip(input) " | got " clip(real) " | want " clip(want); B = 1 } }
  if (real ~ /[.][.]\/[.][.]\/(shared|scripts|rules|skills)\//) { nc++; if (!C) { print "C " where ": " clip(real); C = 1 } }
}
END { print "N " na + 0 " " nb + 0 " " nc + 0 }
AWK_EOF

# check_real <platform>: the real-content checks.
check_real() {
  local platform="$1" h s def rdef rc_real rc_red rc_cmp in_lines real_lines res
  h="$(platform_home "$platform")"
  s="$(platform_skills "$platform")"
  def="$(extract_def "$platform")" || { bad "$platform: real content unobservable — replace_paths() not extractable"; return; }
  rdef="$(reduce_def "$def")"
  eval "$def"
  eval "$rdef"
  # The oracle must really have dropped the `../` rules, or check (b) is a tautology.
  if [ "$(printf '%s\n' '../../../shared/includes/a.md' '../../skills/b' | reduced_paths)" \
       != "$(printf '%s\n' '../../../shared/includes/a.md' '../../skills/b')" ]; then
    bad "$platform: real content (non-vacuity) the reduced oracle still rewrites '../' paths — the rule filter missed them"
    return
  fi

  replace_paths < "$CORPUS" > "$OUT_REAL"; rc_real=$?
  reduced_paths < "$CORPUS" > "$OUT_RED"; rc_red=$?
  in_lines="$(wc -l < "$CORPUS")"
  real_lines="$(wc -l < "$OUT_REAL")"
  if [ "$rc_real" -ne 0 ] || [ "$rc_red" -ne 0 ] || [ "$((in_lines + 0))" -ne "$((real_lines + 0))" ] \
     || [ "$((in_lines + 0))" -ne "$(($(wc -l < "$OUT_RED") + 0))" ]; then
    bad "$platform: real content (non-vacuity) replace_paths exit $rc_real/$rc_red, lines in $in_lines out $real_lines"
    return
  fi
  pass "$platform: replace_paths exits 0 and keeps all $in_lines corpus lines"

  res="$(awk -v H="$h" -v S="$s" -v IDXF="$IDX" -v INF="$CORPUS" -v REDF="$OUT_RED" "$CMP_AWK" "$OUT_REAL")"
  rc_cmp=$?
  local a b c n
  a="$(printf '%s\n' "$res" | sed -n 's/^A //p')"
  b="$(printf '%s\n' "$res" | sed -n 's/^B //p')"
  c="$(printf '%s\n' "$res" | sed -n 's/^C //p')"
  n="$(printf '%s\n' "$res" | sed -n 's/^N //p')"
  if [ "$rc_cmp" -ne 0 ] || [ -z "$n" ]; then
    bad "$platform: real content — compare produced no N summary (awk exit $rc_cmp)"
    return
  fi
  if [ -z "$a" ]; then pass "$platform: real content ($FILE_COUNT files): no output line contains '../~'"
  else bad "$platform: real content (a) '../~' in output — $a (counts a b c: $n)"; fi
  if [ -z "$b" ]; then pass "$platform: real content: every line equals the literal oracle (reduced builder + literal ../ rewrite)"
  else bad "$platform: real content (b) differs from the oracle — $b (counts a b c: $n)"; fi
  if [ -z "$c" ]; then pass "$platform: real content: no '../../{shared,scripts,rules,skills}/' survives"
  else bad "$platform: real content (c) relative path survived — $c (counts a b c: $n)"; fi
}

# Non-vacuity of the corpus itself: enough files, and real eligible relative paths in it, so
# the property checks below cannot be trivially green.
if [ "$((FILE_COUNT + 0))" -lt 50 ]; then
  bad "real content: only $FILE_COUNT markdown files under skills/, shared/ and rules/ — enumeration broken"
elif [ "$((ELIGIBLE_LINES + 0))" -lt 1 ]; then
  bad "real content: no corpus line contains an eligible '../../' path — the checks would be vacuous"
else
  pass "corpus: $FILE_COUNT files, $CORPUS_LINES lines, $ELIGIBLE_LINES lines with an eligible '../../' path"
fi

# Derive the platform list from the filesystem; the four known builders must all be present.
PLATFORMS=""
for f in "$ROOT"/scripts/build-*-skills.sh; do
  [ -f "$f" ] || continue
  p="${f##*/build-}"
  p="${p%-skills.sh}"
  PLATFORMS="$PLATFORMS $p"
done
for p in codex cursor antigravity kimi; do
  case " $PLATFORMS " in
    *" $p "*) ;;
    *) bad "$p: builder scripts/build-$p-skills.sh missing" ;;
  esac
done

for platform in $PLATFORMS; do
  h="$(platform_home "$platform")"
  s="$(platform_skills "$platform")"
  if [ -z "$h" ] || [ -z "$s" ]; then
    bad "$platform: builder has no expectation entry in this test (add it to platform_home/platform_skills)"
    continue
  fi

  if extract_def "$platform" > /dev/null; then
    pass "$platform: replace_paths() extracted (one definition, closed, < 60 lines, bash -n clean)"
  else
    bad "$platform: replace_paths() not found by the extraction"
    continue
  fi

  # Static guard: no pattern side may hold a wildcard dot (covers rules no input above hits).
  offenders="$(unescaped_dot_rules "$(extract_def "$platform")")"
  if [ -z "$offenders" ]; then
    pass "$platform: every sed pattern in replace_paths() escapes its dots"
  else
    bad "$platform: unescaped '.' in a sed pattern — $offenders"
  fi

  # Three-level (references/ and agents/ files) and two-level (SKILL.md) forms, all five dirs.
  for depth in '../../../' '../../'; do
    expect "$platform" "${depth}shared/includes/gate.md" "$h/shared/includes/gate.md"
    expect "$platform" "${depth}shared/schema.json"      "$h/shared/schema.json"
    expect "$platform" "${depth}scripts/run.sh"          "$h/scripts/run.sh"
    expect "$platform" "${depth}rules/cq-patterns.md"    "$h/rules/cq-patterns.md"
    expect "$platform" "${depth}skills/build/SKILL.md"   "$s/build/SKILL.md"
  done

  # Both depths on one line, inside prose, and inside a markdown link.
  expect "$platform" "Read ../../../shared/includes/a.md then ../../rules/b.md." \
    "Read $h/shared/includes/a.md then $h/rules/b.md."
  expect "$platform" "[gate](../../../shared/includes/gate.md)" "[gate]($h/shared/includes/gate.md)"

  # Lookalikes must come back byte-identical: the dots in the rules are literal, so a
  # wildcard match inside a URL, a plain path or a `~/Xclaude/` home-like path is corruption.
  expect "$platform" "https://zuvo.dev/en/skills/seo-audit" "https://zuvo.dev/en/skills/seo-audit"
  for dir in shared/includes shared scripts rules skills; do
    for prefix in ab/cd/ef/ ab/cd/; do
      expect "$platform" "${prefix}${dir}/x.md" "${prefix}${dir}/x.md"
    done
  done
  expect "$platform" '~/Xclaude/x.md'                     '~/Xclaude/x.md'
  expect "$platform" '~/Xclaude/skills/x.md'              '~/Xclaude/skills/x.md'
  expect "$platform" '$HOME/Xclaude/x.md'                 '$HOME/Xclaude/x.md'
  expect "$platform" '~/Xclaude/plugins/cache/zuvo-marketplace/zuvo/1/scripts/adversarial-review.sh' \
    '~/Xclaude/plugins/cache/zuvo-marketplace/zuvo/1/scripts/adversarial-review.sh'
  expect "$platform" '~/Xclaude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh' \
    '~/Xclaude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh'
  # Relative paths outside the allowlist are not ours to rewrite.
  expect "$platform" "../../../docs/x.md" "../../../docs/x.md"
  expect "$platform" "../../docs/x.md"    "../../docs/x.md"

  # Whatever the input, a rewritten path may never keep a stray `../` before the target.
  all="$(printf '%s\n' \
    '../../../shared/includes/a.md' '../../../shared/b.md' '../../../scripts/c.sh' \
    '../../../rules/d.md' '../../../skills/e/SKILL.md' '../../shared/includes/a.md' \
    '../../scripts/c.sh' '../../rules/d.md' '../../skills/e/SKILL.md')"
  out="$(rewrite "$platform" "$all")"
  case "$out" in
    *'../~'*) bad "$platform: output still contains '../~'" ;;
    *)        pass "$platform: no output contains '../~'" ;;
  esac
  case "$out" in
    *'../../'*) bad "$platform: a relative '../../' survived the rewrite" ;;
    *)          pass "$platform: no relative '../../' survives the rewrite" ;;
  esac

  # The shipped files themselves.
  check_real "$platform"
done

printf 'RESULT: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
