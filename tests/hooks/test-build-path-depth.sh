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
# The rules are ANCHORED: each fires at the start of a line or after a character that cannot
# belong to a path. An unanchored `../../` rule eats the tail of any longer run and leaves a
# stray `../` in front of the target; anchored, a run of four or more `../`, or one glued to a
# `.` or a path character, is an unsupported depth and passes through unchanged.
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
# Each builder's replace_paths() is extracted with awk (brace depth) and evaluated in-process,
# and a recorded-seed property test feeds it generated path mixes. That direct call stays on
# purpose: the function in isolation, from each of the four builders, is the oracle input — a
# full build cannot show which rule rewrote a line. The public CLI backs it for kimi: the real
# build, through the shared dist cache (tests/lib/dist-build.sh, see test-dist-build-cache.sh),
# must turn every three-level reference in skills/*/references/ into a path that exists in the
# built tree; and the builder run on small fixture plugin dirs must fail, with its own message,
# on a missing library, a missing skill source and each validation a fixture can trip.
#
# Level: medium — temp files, one real build and a few fixture builds into mktemp directories;
# no network, no sleep.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

# Per-platform targets: root for shared/scripts/rules, the variable CLAUDE_PLUGIN_ROOT becomes,
# and the skills/ root (Antigravity keeps skills in its shared customization root, not under its
# own home). A builder with no entry here is reported loudly instead of going untested.
platform_home() {
  case "$1" in
    codex)       printf '%s' '~/.codex' ;;
    cursor)      printf '%s' '~/.cursor' ;;
    antigravity) printf '%s' '~/.gemini/antigravity' ;;
    kimi)        printf '%s' '~/.kimi-code' ;;
  esac
}
platform_env() {
  case "$1" in
    codex)       printf '%s' 'CODEX_HOME' ;;
    cursor)      printf '%s' 'CURSOR_HOME' ;;
    antigravity) printf '%s' 'GEMINI_HOME' ;;
    kimi)        printf '%s' 'KIMI_CODE_HOME' ;;
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
# (escaped or not, so a regressed unescaped rule is stripped too; bare, `^`-anchored or behind a
# `\([...]\)` left-context group). The `../` rules are the tail of the sed command, so a no-op
# rule closes the continuation.
reduce_def() {
  printf '%s\n' "$1" | awk '
    /^[[:space:]]+-e .s[|](\^|\\\(\[[^]]*\]\\\))?((\\)?[.](\\)?[.]\/)+/ { next }
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

# rewrite_file <platform> <in> <out>: that builder's replace_paths() over the exact bytes of <in>.
rewrite_file() {
  local def
  def="$(extract_def "$1")" || return 90
  (
    eval "$def"
    replace_paths < "$2" > "$3"
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
WORK="$(mktemp -d)" || { echo "FAIL: mktemp -d failed"; echo "RESULT: PASS=0 FAIL=1"; exit 1; }
trap 'rm -f "$FILES_LIST" "$CORPUS" "$IDX" "$OUT_REAL" "$OUT_RED"; rm -rf "$WORK"' EXIT
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

# ── recorded-seed property test ──────────────────────────────────────────────────────────
# Lines of 1-4 tokens joined by separators that hold no `.` or `/`. A supported token is
# <depth><dir>/<tail> for the five dirs; an unsupported one is a lookalike (another prefix such as
# four or five `../` or a run glued to `.` or `x/`, a `docs/` or `X<dir>` directory). Written line-aligned: .d3 (supported tokens at ../../../),
# .d2 (the same at ../../) and .want, built token by token as it is generated: the platform's
# literal target for a supported token, the token itself for an unsupported one. No regex, so
# no copy of the sed rules. The generator is MINSTD (x * 48271 mod 2^31-1), exact in awk's
# doubles on every awk, so a seed names the same cases everywhere.
SEED="${BPD_SEED:-48271}"
case "$SEED" in ''|*[!0-9]*) SEED=48271 ;; esac
CASES=400
read -r -d '' GEN_AWK <<'AWK_EOF' || true
function rnd(k) { x = (x * 48271) % 2147483647; return int(x / 2147483647 * k) }
BEGIN {
  x = seed % 2147483646 + 1
  nd = split("shared/includes shared scripts rules skills", dirs, " ")
  nt = split("a.md gate.md x/y.sh SKILL.md b-c_d.json", tails, " ")
  ns = 9; seps[1] = " "; seps[2] = "("; seps[3] = ")"; seps[4] = "`"; seps[5] = " then "
  seps[6] = ", "; seps[7] = "["; seps[8] = "]"; seps[9] = "\""
  nu = 11; ups[1] = ""; ups[2] = "./"; ups[3] = "../"; ups[4] = "ab/cd/"; ups[5] = "../../docs/"
  ups[6] = "../../../docs/"; ups[7] = "https://zuvo.dev/en/"; ups[8] = "../../../../"
  ups[9] = "../../../../../"; ups[10] = ".../../"; ups[11] = "x/../../"
  for (i = 1; i <= n; i++) {
    l3 = l2 = w = ""
    if (rnd(2)) { s = seps[1 + rnd(ns)]; l3 = l2 = w = s }
    k = 1 + rnd(4)
    for (j = 1; j <= k; j++) {
      d = dirs[1 + rnd(nd)]; t = tails[1 + rnd(nt)]
      if (rnd(2)) {
        sup++
        t3 = "../../../" d "/" t; t2 = "../../" d "/" t
        tw = (d == "skills" ? S : H "/" d) "/" t
      } else {
        uns++
        r = rnd(3)
        if (r == 0) t3 = ups[1 + rnd(nu)] d "/" t
        else if (r == 1) t3 = (rnd(2) ? "../../../" : "../../") "X" d "/" t
        else t3 = (rnd(2) ? "../../../" : "../../") "docs/" t
        t2 = tw = t3
      }
      s = (j < k || rnd(2)) ? seps[1 + rnd(ns)] : ""
      l3 = l3 t3 s; l2 = l2 t2 s; w = w tw s
    }
    print l3 > (out ".d3"); print l2 > (out ".d2"); print w > (out ".want")
  }
  print sup + 0, uns + 0
}
AWK_EOF

# first_diff <got> <want>: "line N: got [...] want [...]" for the first differing line, or nothing.
first_diff() {
  awk -v W="$2" '
    { if ((getline w < W) <= 0) w = "<none>"
      if ($0 != w) { print "line " NR ": got [" $0 "] want [" w "]"; done = 1; exit } }
    END { if (!done && (getline w < W) > 0) print "line " NR + 1 ": output ends early, want [" w "]" }' "$1"
}

# check_property <platform>: replace_paths over the generated lines — the literal per depth,
# depth invariance, idempotence and no `../~`.
check_property() {
  local platform="$1" h s def counts g="$WORK/prop-$1" d3 d2 again tilde
  h="$(platform_home "$platform")"; s="$(platform_skills "$platform")"
  counts="$(awk -v seed="$SEED" -v n="$CASES" -v H="$h" -v S="$s" -v out="$g" "$GEN_AWK")"
  case "$counts" in
    0\ *|*\ 0|'') bad "$platform: property (seed=$SEED) generator produced '$counts' supported/unsupported tokens"; return ;;
  esac
  def="$(extract_def "$platform")" || { bad "$platform: property (seed=$SEED) replace_paths() not extractable"; return; }
  eval "$def"
  replace_paths < "$g.d3" > "$g.r3"; replace_paths < "$g.d2" > "$g.r2"; replace_paths < "$g.r3" > "$g.rr"
  d3="$(first_diff "$g.r3" "$g.want")"; d2="$(first_diff "$g.r2" "$g.want")"; again="$(first_diff "$g.rr" "$g.r3")"
  tilde="$(awk 'index($0, "../~") { print "line " NR ": " $0; exit }' "$g.r3" "$g.r2")"
  if [ -z "$d3" ]; then pass "$platform: property (seed=$SEED, $CASES lines, ${counts% *} supported / ${counts#* } lookalike tokens): ../../../ paths -> the literal target, lookalikes unchanged"
  else bad "$platform: property (seed=$SEED) ../../../ input $d3"; fi
  if [ -z "$d2" ]; then pass "$platform: property (seed=$SEED): the same lines at ../../ give the same output (depth-invariant)"
  else bad "$platform: property (seed=$SEED) ../../ input $d2"; fi
  if [ -z "$again" ]; then pass "$platform: property (seed=$SEED): a second pass changes nothing (idempotent)"
  else bad "$platform: property (seed=$SEED) not idempotent — $again"; fi
  if [ -z "$tilde" ]; then pass "$platform: property (seed=$SEED): no output line contains '../~'"
  else bad "$platform: property (seed=$SEED) '../~' in output — $tilde"; fi
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
  e="$(platform_env "$platform")"
  if [ -z "$h" ] || [ -z "$s" ] || [ -z "$e" ]; then
    bad "$platform: builder has no expectation entry in this test (add it to platform_home/platform_skills/platform_env)"
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
  # Nor one level, no level, a dir without its slash, a lookalike dir, a missing parent, backslashes.
  for u in '../shared/includes/x.md' './rules/x.md' 'shared/includes/x.md' '../../shared' \
           '../../Xshared/x.md' '../../../Xskills/b/SKILL.md' '../../includes/x.md' '..\..\shared\x.md'; do
    expect "$platform" "$u" "$u"
  done
  # Unsupported depth: a run of four or five `../`, or a run glued to a dot or a path character,
  # is not a two- or three-level include. It comes back unchanged, never as a `../~` dead path.
  for u in '../../../../shared/includes/x.md' '../../../../shared/x.md' '../../../../scripts/x.sh' \
           '../../../../rules/x.md' '../../../../skills/b/SKILL.md' '../../../../../shared/x.md' \
           '.../../shared/x' '.../../../rules/x.md' 'a../../shared/x.md' 'docs/../../rules/x.md' \
           '(../../../../shared/x.md)'; do
    expect "$platform" "$u" "$u"
  done
  expect "$platform" "../../shared/a.md and ../../../../shared/b.md" "$h/shared/a.md and ../../../../shared/b.md"

  # The non-relative rules every builder shares: {plugin_root}, the env name, the reviewer driver.
  expect "$platform" "{plugin_root}/shared/includes/a.md" "$h/shared/includes/a.md"
  expect "$platform" "{plugin_root}/rules/a.md"           "$h/rules/a.md"
  expect "$platform" "{plugin_root}/skills/b/SKILL.md"    "$s/b/SKILL.md"
  expect "$platform" "{plugin_root}/scripts/x.sh"         "$h/scripts/x.sh"
  expect "$platform" "\${CLAUDE_PLUGIN_ROOT}/x"           "\${$e}/x"
  expect "$platform" '~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh' \
    "$h/scripts/adversarial-review.sh"

  # Empty input: no bytes in, no bytes out. Blank lines come back as they went in.
  : > "$WORK/empty.in"; printf '\n\n' > "$WORK/blank.in"; rm -f "$WORK/empty.out" "$WORK/blank.out"
  rc=0; rewrite_file "$platform" "$WORK/empty.in" "$WORK/empty.out" || rc=$?
  if [ "$rc" -eq 0 ] && [ -f "$WORK/empty.out" ] && [ ! -s "$WORK/empty.out" ]; then
    pass "$platform: empty input -> empty output, exit 0"
  else
    bad "$platform: empty input -> exit $rc, output file present: $([ -f "$WORK/empty.out" ] && echo yes || echo no)"
  fi
  rc=0; rewrite_file "$platform" "$WORK/blank.in" "$WORK/blank.out" || rc=$?
  if [ "$rc" -eq 0 ] && cmp -s "$WORK/blank.in" "$WORK/blank.out"; then
    pass "$platform: two blank lines in -> the same two blank lines out"
  else
    bad "$platform: blank-line input -> exit $rc, output differs from input"
  fi

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

  check_property "$platform"
done

# ── public CLI: the real kimi build ──────────────────────────────────────────────────────
# Through the dist cache helper (a replay when a sibling already built kimi this run), into a
# directory of our own. Kimi installs dist/kimi as ~/.kimi-code, so a rewritten path resolves
# when <dist>/<path> exists. Every three-level reference in skills/*/references/*.md is checked.
echo "== public CLI: tests/lib/dist-build.sh kimi =="
KD="$WORK/dist/kimi"; kh="$(platform_home kimi)"
build_rc=0
ZUVO_DIST_ROOT="$WORK/dist" bash "$ROOT/tests/lib/dist-build.sh" kimi > "$WORK/kimi-build.log" 2>&1 || build_rc=$?
n_src="$(find "$ROOT/skills" -path '*/references/*.md' | awk 'END { print NR }')"
n_dist="$(find "$KD/skills" -path '*/references/*.md' 2> /dev/null | awk 'END { print NR }')"
if [ "$build_rc" -eq 0 ] && [ "$n_src" -gt 0 ] && [ "$n_src" = "$n_dist" ]; then
  pass "kimi CLI: the build exits 0 and writes all $n_src skills/*/references/*.md files"
else
  bad "kimi CLI: build exit $build_rc, references files source $n_src / built $n_dist ($(tail -n 3 "$WORK/kimi-build.log" | tr '\n' ' '))"
fi
# skill/references/file <TAB> path after ../../../, one row per reference; a trailing dot is prose.
find "$ROOT/skills" -path '*/references/*.md' | sort | while IFS= read -r f; do
  awk -v rel="${f#"$ROOT"/skills/}" '{ s = $0
    while (match(s, /\.\.\/\.\.\/\.\.\/(shared|scripts|rules|skills)\/[A-Za-z0-9_.\/-]*[A-Za-z0-9_\/-]/)) {
      print rel "\t" substr(s, RSTART + 9, RLENGTH - 9); s = substr(s, RSTART + RLENGTH) } }' "$f"
done > "$WORK/refs.tsv"
nref=0; src_bad=""; out_bad=""; tgt_bad=""
while IFS="$(printf '\t')" read -r rf target; do
  nref=$((nref + 1))
  [ -e "$ROOT/$target" ] || src_bad="${src_bad:-$rf -> $target}"
  grep -qF -- "$kh/$target" "$KD/skills/$rf" 2> /dev/null || out_bad="${out_bad:-$rf -> $kh/$target}"
  [ -e "$KD/$target" ] || tgt_bad="${tgt_bad:-$rf -> $target}"
done < "$WORK/refs.tsv"
if [ "$nref" -gt 0 ] && [ -z "$src_bad" ]; then
  pass "kimi CLI: premise — $nref three-level references in skills/*/references/*.md, each resolving in the source tree"
else
  bad "kimi CLI: premise — $nref references, first one not resolving in the source: ${src_bad:-none}"
fi
if [ "$nref" -gt 0 ] && [ -z "$out_bad" ] && [ -z "$tgt_bad" ]; then
  pass "kimi CLI: all $nref are rewritten to $kh/<path> in the built file, and that path exists in the build"
else
  bad "kimi CLI: first reference not rewritten: ${out_bad:-none}; first one missing from the build: ${tgt_bad:-none}"
fi
find "$KD/skills" -path '*/references/*.md' 2> /dev/null | sort | while IFS= read -r f; do
  awk -v f="${f#"$KD"/}" '/[.][.]\/[.][.]\/[.][.]\/(shared|scripts|rules|skills)\// || index($0, "../~") { print f ":" FNR ": " $0; exit }' "$f"
done > "$WORK/left.txt"
left="$(sed -n 1p "$WORK/left.txt")"
if [ "$n_dist" -gt 0 ] && [ -z "$left" ]; then
  pass "kimi CLI: no built references file keeps a '../../../' include path or contains '../~'"
else
  bad "kimi CLI: built references ($n_dist files) still hold a relative or broken path — ${left:-no built files}"
fi

# ── public CLI: the kimi builder's own error paths, on fixture plugin dirs ───────────────
echo "== public CLI: kimi builder on fixture plugin dirs =="
KB="$ROOT/scripts/build-kimi-skills.sh"
FX="$WORK/fx"
mkdir -p "$FX/skills/fx" "$FX/shared/includes" "$FX/scripts/lib"
cp "$ROOT/scripts/lib/model-subprocess.sh" "$FX/scripts/lib/"
printf '# Fixture include\n' > "$FX/shared/includes/fixture.md"
printf -- '---\nname: fx\ndescription: fixture skill\n---\n# zuvo:fx\nRead `../../shared/includes/fixture.md`, then dispatch the work.\n' \
  > "$FX/skills/fx/SKILL.md"
# fixture <name>: a fresh copy of the valid fixture plugin, printed as its path.
fixture() { cp -R "$FX" "$WORK/fx-$1" && printf '%s' "$WORK/fx-$1"; }
# fx_build <name> <plugin dir> [builder]: the builder's CLI into its own dist; out/err/rc under $WORK.
fx_build() {
  local rc=0
  ZUVO_DIST_ROOT="$WORK/fxdist-$1" bash "${3:-$KB}" "$2" > "$WORK/$1.out" 2> "$WORK/$1.err" || rc=$?
  printf '%s' "$rc" > "$WORK/$1.rc"
}
# fails_with <name> <ERROR text> [platform]: rc 1, that `  ERROR:` line, and exactly one error in the verdict.
fails_with() {
  local rc last
  rc="$(cat "$WORK/$1.rc")"; last="$(awk 'NF { l = $0 } END { print l }' "$WORK/$1.out")"
  if [ "$rc" = 1 ] && grep -qxF -- "  ERROR: $2" "$WORK/$1.out" && [ "$last" = "BUILD FAILED: 1 error(s)" ]; then
    pass "${3:-kimi} fixture $1: rc 1, 'ERROR: $2', BUILD FAILED: 1 error(s)"
  else
    bad "${3:-kimi} fixture $1: rc $rc, last line '$last', ERROR lines: $(grep -F 'ERROR' "$WORK/$1.out" "$WORK/$1.err" | head -n 3 | tr '\n' ' ')"
  fi
}

fx_build base "$FX"
if [ "$(cat "$WORK/base.rc")" = 0 ] && grep -qxF "Build complete: $WORK/fxdist-base/kimi" "$WORK/base.out" \
   && [ -f "$WORK/fxdist-base/kimi/skills/fx/SKILL.md" ] && ! grep -qF 'ERROR' "$WORK/base.out"; then
  pass "kimi fixture base: the valid fixture builds (rc 0, Build complete, no ERROR) — each case below changes one thing"
else
  bad "kimi fixture base: rc $(cat "$WORK/base.rc") ($(tail -n 3 "$WORK/base.out" "$WORK/base.err" | tr '\n' ' '))"
fi

# A missing or incomplete library next to the builder stops it before it touches the dist.
mkdir -p "$WORK/kb-nolanes/lib" "$WORK/kb-emptylanes/lib"
for d in kb-nolanes kb-emptylanes; do
  cp "$KB" "$WORK/$d/" && cp "$ROOT/scripts/lib/portable.sh" "$WORK/$d/lib/"
done
: > "$WORK/kb-emptylanes/lib/reviewer-lanes.sh"
fx_build nolanes "$FX" "$WORK/kb-nolanes/build-kimi-skills.sh"
lib="$(cd "$WORK/kb-nolanes" && pwd)/lib/reviewer-lanes.sh"
if [ "$(cat "$WORK/nolanes.rc")" = 1 ] && [ ! -e "$WORK/fxdist-nolanes" ] \
   && [ "$(cat "$WORK/nolanes.err")" = "ERROR: reviewer-lanes.sh not found: $lib — the Kimi build cannot validate reviewer lanes without it" ]; then
  pass "kimi builder without lib/reviewer-lanes.sh: rc 1, names the missing library, writes no dist"
else
  bad "kimi builder without lib/reviewer-lanes.sh: rc $(cat "$WORK/nolanes.rc"), stderr: $(head -c 300 "$WORK/nolanes.err")"
fi
fx_build emptylanes "$FX" "$WORK/kb-emptylanes/build-kimi-skills.sh"
lib="$(cd "$WORK/kb-emptylanes" && pwd)/lib/reviewer-lanes.sh"
if [ "$(cat "$WORK/emptylanes.rc")" = 1 ] && [ ! -e "$WORK/fxdist-emptylanes" ] \
   && [ "$(cat "$WORK/emptylanes.err")" = "ERROR: zrl_require_fns is not defined after sourcing $lib — the library is missing or incomplete" ]; then
  pass "kimi builder with an empty lib/reviewer-lanes.sh: rc 1, says the library is incomplete, writes no dist"
else
  bad "kimi builder with an empty lib/reviewer-lanes.sh: rc $(cat "$WORK/emptylanes.rc"), stderr: $(head -c 300 "$WORK/emptylanes.err")"
fi
p="$(fixture nolib)"; rm -f "$p/scripts/lib/model-subprocess.sh"; fx_build nolib "$p"
if [ "$(cat "$WORK/nolib.rc")" = 1 ] && [ "$(cat "$WORK/nolib.err")" = "ERROR: scripts/lib/model-subprocess.sh is missing — the Kimi build's adversarial-review.sh cannot run its codex and claude lanes without it" ] \
   && ! grep -qF 'Build complete' "$WORK/nolib.out"; then
  pass "kimi fixture without scripts/lib/model-subprocess.sh: rc 1 with its message, no Build complete"
else
  bad "kimi fixture without scripts/lib/model-subprocess.sh: rc $(cat "$WORK/nolib.rc"), stderr: $(head -c 300 "$WORK/nolib.err")"
fi

# A skill directory without its SKILL.md aborts the build (awk cannot open it; the build runs with -e).
p="$(fixture nosource)"; mkdir -p "$p/skills/ghost"; fx_build nosource "$p"
if [ "$(cat "$WORK/nosource.rc")" = 2 ] && grep -qF "$p/skills/ghost/SKILL.md" "$WORK/nosource.err" \
   && grep -qF 'No such file or directory' "$WORK/nosource.err" && ! grep -qF 'Build complete' "$WORK/nosource.out"; then
  pass "kimi fixture with a skill dir but no SKILL.md: rc 2, the missing source named, no Build complete"
else
  bad "kimi fixture with no SKILL.md: rc $(cat "$WORK/nosource.rc"), stderr: $(head -c 300 "$WORK/nosource.err")"
fi

# Validation: each fixture trips exactly one check, which names itself.
p="$(fixture subtype)"; printf 'subagent_type: "nonsense"\n' >> "$p/skills/fx/SKILL.md"; fx_build subtype "$p"
fails_with subtype 'Unknown subagent_type values (not a Kimi builtin, no matching agent file):'
p="$(fixture noagent)"; mkdir -p "$p/skills/fx/agents"
printf -- '---\nname: team-lead\ndescription: fixture procedure\n---\nProcedure.\n' > "$p/skills/fx/agents/team-lead.md"
printf 'Then dispatch `agents/ghost.md`.\n' >> "$p/skills/fx/SKILL.md"; fx_build noagent "$p"
fails_with noagent 'fx: references missing agent file fx-ghost.md'
p="$(fixture nodispatch)"; mkdir -p "$p/skills/fx/agents"
printf -- '---\nname: team-lead\ndescription: fixture procedure\n---\nProcedure.\n' > "$p/skills/fx/agents/team-lead.md"
printf -- '---\nname: fx\ndescription: fixture skill\n---\n# zuvo:fx\nRead the include and do the work.\n' > "$p/skills/fx/SKILL.md"
fx_build nodispatch "$p"
fails_with nodispatch 'fx: ships agents/ but dist SKILL.md has no dispatch language left'
p="$(fixture pluginroot)"; printf 'cat "{plugin_root}/x"\n' > "$p/shared/includes/fx.sh"; fx_build pluginroot "$p"
fails_with pluginroot 'Residual {plugin_root} tokens:'
p="$(fixture envcompat)"; printf '# Environment\n### Codex\nInline.\n' > "$p/shared/includes/env-compat.md"; fx_build envcompat "$p"
fails_with envcompat 'env-compat.md lost its Kimi Code section — runs would fall back to inline dispatch'
p="$(fixture noincludes)"; rm -f "$p/shared/includes/fixture.md"; fx_build noincludes "$p"
fails_with noincludes "No shared include files found in $WORK/fxdist-noincludes/kimi/shared/includes/"

# Antigravity drives the same way once the fixture carries the two blind-audit reviewer agents it requires.
AG="$ROOT/scripts/build-antigravity-skills.sh"
p="$(fixture ag-base)"; mkdir -p "$p/skills/write-tests/agents"
cp "$ROOT/skills/write-tests/agents/blind-coverage-auditor.md" "$ROOT/skills/write-tests/agents/blind-coverage-auditor-alt.md" \
  "$p/skills/write-tests/agents/"
printf -- '---\nname: write-tests\ndescription: fixture skill\n---\n# zuvo:write-tests\nDispatch the blind coverage auditor.\n' \
  > "$p/skills/write-tests/SKILL.md"
fx_build ag-base "$p" "$AG"
if [ "$(cat "$WORK/ag-base.rc")" = 0 ] && grep -qxF "Build complete: $WORK/fxdist-ag-base/antigravity" "$WORK/ag-base.out" \
   && ! grep -qF 'ERROR' "$WORK/ag-base.out"; then
  pass "antigravity fixture ag-base: the valid fixture builds (rc 0, Build complete, no ERROR)"
else
  bad "antigravity fixture ag-base: rc $(cat "$WORK/ag-base.rc") ($(tail -n 3 "$WORK/ag-base.out" "$WORK/ag-base.err" | tr '\n' ' '))"
fi
cp -R "$p" "$WORK/fx-ag-noincludes" && rm -f "$WORK/fx-ag-noincludes/shared/includes/fixture.md"
fx_build ag-noincludes "$WORK/fx-ag-noincludes" "$AG"
fails_with ag-noincludes "No shared include files found in $WORK/fxdist-ag-noincludes/antigravity/shared/includes/" antigravity

printf 'RESULT: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
