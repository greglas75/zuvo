#!/usr/bin/env bash
# test-plan-dag-failure-strategy.sh — Task 7 RED/GREEN.
#
# WHY THIS LIVES IN tests/skill-suite/ AND NOT tests/adversarial/
# ---------------------------------------------------------------
# The older verify-plan-dag suites (tests/adversarial/test-verify-plan-dag.sh,
# tests/adversarial/test-install-verify-plan-dag.sh) run only in the FULL scope
# and depend on the adversarial harness ($ROOT, $ADV_TEST_HOME, start_test,
# assert_eq). This suite is deliberately standalone and lives in skill-suite,
# which `tests/run-all.sh` auto-discovers (`emit_glob "tests/skill-suite/test-*.sh"`)
# and runs in the DEFAULT `fast` scope. `scripts/zuvo-home/verify-plan-dag` is
# installed to ~/.zuvo/ and is therefore executed by EVERY project on the
# machine: a regression in its marker matching must surface on the fast path,
# not only when someone remembers to run the full suite. Do NOT "consolidate"
# this file back into the adversarial suite.
#
# Asserts the declared-failure-strategy contract (skills/plan/SKILL.md rule 20):
#   (a) `skip-and-continue` on a task nothing depends on          → exit 0
#   (b) `skip-and-continue` on a depended-on task                 → exit 1, text
#       message names the offending task AND every dependent, and `--json`
#       carries a populated `failure_strategy_violations` entry
#   (c) an unrecognised value (`**Failure:** maybe`)              → exit 1, NOT 2
#       (exit 2 is contractually "cannot parse the plan at all"; conflating the
#       two makes the linter read as crashing, which is how authors disable it)
#   (d) no `**Failure:**` line anywhere                           → exit 0
#       (the backward-compatibility guarantee — asserted, never assumed)
#   (e) `**Failure:** degraded: fix later, then re-run`           → exit 0
#       the free text carries a comma and must be discarded WHOLE: never
#       tokenised, never split on `,` (that is what keeps the Dependencies
#       parser's non-numeric-token exit-2 landmine unreachable from this path)
#   (f) near-miss spellings — one fixture per real-world spelling measured
#       across ~/DEV: `**Failure paths:`, `**Failure handling (W1):`,
#       `**Failure modes:`, `**Failure-path unit:`, `**Failure Mode row`,
#       `**Failure case (cross-model finding):` → all exit 0, none classified
#   (g) a `skip-and-continue` line adds NOTHING to the graph: task count and
#       edge count identical with and without the line
#   (h) cross-file enum parity: the token union in rule 20 of
#       skills/plan/SKILL.md diffs clean against the parser's classifier tokens
#   (i) a present-but-blank `**Failure:**`                        → exit 1
#       (omitting the line means `halt`; writing it blank is an authoring error)
#   (j) anchoring: a mid-line prose mention is NOT a declaration and must not
#       shadow a later real one; an inline `·`-bulleted field IS a declaration
#
# Harness idioms copied from tests/skill-suite/test-dev-push-gate.sh:
# `set -uo pipefail`, ONE `mktemp -d` root + `trap` cleanup, and a purity check.
# bash 3.2-compatible (macOS default): no mapfile, no associative arrays. No git
# fixtures are created and no `git` is invoked at all, so GIT_CONFIG_GLOBAL /
# GIT_CONFIG_SYSTEM neutering is not needed here.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
V="$ROOT/scripts/zuvo-home/verify-plan-dag"
SKILL="$ROOT/skills/plan/SKILL.md"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

SUM_BEFORE="$(cksum "$V" "$SKILL" 2>/dev/null)"

TMP_ROOT="$(mktemp -d)"
_cleanup() { rm -rf "$TMP_ROOT"; }
trap _cleanup EXIT
trap '_cleanup; exit 1' INT TERM

if [ ! -x "$V" ]; then
  bad "verify-plan-dag not found or not executable at $V"
  echo "SOME FAILED"; exit 1
fi

# ── helpers ───────────────────────────────────────────────────────────────────
BULLET=$'\xc2\xb7'          # · U+00B7, the inline metadata separator

mk() {                      # mk <name> <<'EOF' … EOF  → echoes fixture path
  local p="$TMP_ROOT/$1.md"
  cat > "$p"
  printf '%s' "$p"
}

RC=0; OUT=""
run() {                     # run <plan> [--json] → sets RC / OUT
  local p="$1"; shift
  OUT="$("$V" "$@" "$p" 2>&1)"; RC=$?
}

# Extract the body of a JSON array field (no brackets/strings nesting in these
# fixtures, so a depth counter over `[`/`]` is sufficient). Avoids a jq dep.
json_array() {              # json_array <json> <key> → array body on stdout
  printf '%s' "$1" | awk -v key="$2" '
    {
      k = "\"" key "\":["
      p = index($0, k)
      if (p == 0) { exit 1 }
      rest = substr($0, p + length(k))
      depth = 1; out = ""
      for (i = 1; i <= length(rest); i++) {
        c = substr(rest, i, 1)
        if (c == "[") depth++
        else if (c == "]") { depth--; if (depth == 0) break }
        out = out c
      }
      print out
    }'
}

expect_rc() {               # expect_rc <want> <label>
  if [ "$RC" -eq "$1" ]; then pass "$2 (rc=$RC)"
  else bad "$2 — expected rc $1, got $RC; output: $OUT"; fi
}

# ── (d) no **Failure:** line at all → exit 0 (backward compatibility) ─────────
P_NONE=$(mk none <<'EOF'
### Task 1: alpha
**Dependencies:** none
### Task 2: beta
**Dependencies:** Task 1
### Task 3: gamma
**Dependencies:** Task 1, Task 2
EOF
)
run "$P_NONE"
expect_rc 0 "(d) plan with no **Failure:** line lints clean"

# ── (a) skip-and-continue on an in-degree-zero task → exit 0 ─────────────────
P_A=$(mk skip_leaf <<'EOF'
### Task 1: alpha
**Dependencies:** none
### Task 2: beta
**Dependencies:** Task 1
### Task 3: gamma
**Dependencies:** Task 1
**Failure:** skip-and-continue
EOF
)
run "$P_A"
expect_rc 0 "(a) skip-and-continue on a task nothing depends on"

run "$P_A" --json
if printf '%s' "$OUT" | /usr/bin/grep -qF '"failure_strategy_violations":[]'; then
  pass "(a) --json emits an empty failure_strategy_violations array"
else
  bad "(a) --json missing/populated failure_strategy_violations: $OUT"
fi

# ── (b) skip-and-continue on a depended-on task → exit 1 + named dependents ──
P_B=$(mk skip_depended <<'EOF'
### Task 1: alpha
**Dependencies:** none
**Failure:** skip-and-continue
### Task 2: beta
**Dependencies:** Task 1
### Task 3: gamma
**Dependencies:** Task 1
EOF
)
run "$P_B"
expect_rc 1 "(b) skip-and-continue on a depended-on task is a violation"

FSLINE="$(printf '%s\n' "$OUT" | /usr/bin/grep -i 'failure' | /usr/bin/grep -v '^verify-plan-dag: ' | head -1)"
if [ -z "$FSLINE" ]; then
  bad "(b) no failure-strategy line in text output: $OUT"
else
  ok=1
  case "$FSLINE" in *"Task 1"*) ;; *) ok=0 ;; esac
  case "$FSLINE" in *"Task 2"*) ;; *) ok=0 ;; esac
  case "$FSLINE" in *"Task 3"*) ;; *) ok=0 ;; esac
  if [ "$ok" -eq 1 ]; then
    pass "(b) message names the offending task and BOTH dependents: $FSLINE"
  else
    bad "(b) message must name Task 1 + dependents Task 2 and Task 3; got: $FSLINE"
  fi
fi

run "$P_B" --json
expect_rc 1 "(b) --json exits 1 too"
FSV="$(json_array "$OUT" failure_strategy_violations)"
if [ -z "$FSV" ]; then
  bad "(b) --json failure_strategy_violations is empty/absent — an invalid plan with zero causes: $OUT"
else
  ok=1
  case "$OUT" in *'"valid":false'*) ;; *) ok=0; bad "(b) --json valid must be false" ;; esac
  case "$FSV" in *'"task":1'*) ;; *) ok=0; bad "(b) --json entry must name task 1; got: $FSV" ;; esac
  DEPARR="$(json_array "$FSV" dependents)"
  case "$DEPARR" in
    *2*) case "$DEPARR" in *3*) ;; *) ok=0; bad "(b) --json dependents missing 3: $FSV" ;; esac ;;
    *) ok=0; bad "(b) --json dependents missing 2: $FSV" ;;
  esac
  [ "$ok" -eq 1 ] && pass "(b) --json carries a populated failure_strategy_violations entry: $FSV"
fi

# ── (c) unrecognised value → exit 1, NOT 2 ───────────────────────────────────
P_C=$(mk unrecognised <<'EOF'
### Task 1: alpha
**Dependencies:** none
**Failure:** maybe
### Task 2: beta
**Dependencies:** Task 1
EOF
)
run "$P_C"
expect_rc 1 "(c) unrecognised failure value is a violation, not a parse error"
case "$OUT" in
  *maybe*) pass "(c) message quotes the offending value" ;;
  *) bad "(c) message should quote the offending value; got: $OUT" ;;
esac

# ── (i) present-but-blank **Failure:** → exit 1 ──────────────────────────────
P_I=$(mk blank <<'EOF'
### Task 1: alpha
**Dependencies:** none
**Failure:**
### Task 2: beta
**Dependencies:** Task 1
EOF
)
run "$P_I"
expect_rc 1 "(i) a present-but-blank **Failure:** is a plan defect, not a silent halt"

# Written with printf so the trailing whitespace after the marker is real and
# cannot be stripped by an editor or by a heredoc reflow.
P_I2="$TMP_ROOT/blank_ws.md"
printf '### Task 1: alpha\n**Dependencies:** none\n**Failure:**   \n### Task 2: beta\n**Dependencies:** Task 1\n' > "$P_I2"
run "$P_I2"
expect_rc 1 "(i) whitespace-only **Failure:** value is likewise a defect"

# ── (e) degraded: free text with a comma → exit 0, discarded whole ───────────
P_E=$(mk degraded <<'EOF'
### Task 1: alpha
**Dependencies:** none
**Failure:** degraded: fix later, then re-run
### Task 2: beta
**Dependencies:** Task 1
**Failure:** degraded: partial index, no embeddings, Task 3 handles it
### Task 3: gamma
**Dependencies:** Task 2
**Failure:** halt
EOF
)
run "$P_E"
expect_rc 0 "(e) degraded: description containing commas is never tokenised"
case "$OUT" in
  *"malformed"*) bad "(e) degraded description reached the dependency tokeniser: $OUT" ;;
  *) pass "(e) no malformed-token diagnostic — description discarded unread" ;;
esac

# ── (k) --json survives raw control characters in a **Failure:** value ───────
# json_esc must escape the full JSON control range (0x00-0x1F), not just `"`
# and `\`. A literal TAB (or any other control byte) landing in an authored
# value — e.g. pasted from a terminal — must not produce output that
# `json.loads` rejects with "Invalid control character".
if command -v python3 >/dev/null 2>&1; then
  P_K="$TMP_ROOT/ctrlchar.md"
  printf '### Task 1: alpha\n**Dependencies:** none\n**Failure:** ba%sd%sx\n### Task 2: beta\n**Dependencies:** Task 1\n' \
    "$(printf '\t')" "$(printf '\013')" > "$P_K"
  run "$P_K" --json
  if printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
    pass "(k) --json output with a raw TAB + vertical-tab in a value is valid JSON"
  else
    bad "(k) --json output is NOT valid JSON when the value contains raw control bytes: $OUT"
  fi
  case "$OUT" in
    *'\t'*) pass "(k) the TAB is escaped as \\t in the JSON output" ;;
    *) bad "(k) expected an escaped \\t in the JSON output: $OUT" ;;
  esac
else
  echo "SKIP: (k) python3 not found — cannot validate --json control-character escaping"
fi

# ── (f) near-miss spellings: none is a declaration ───────────────────────────
# Real spellings measured across 3,136 plan files under ~/DEV (46 near misses in
# 17 spellings, 0 exact literals). Each carries a value that WOULD be a
# violation if the marker matched loosely, so a loose matcher cannot pass here.
nearmiss_case() {           # nearmiss_case <slug> <marker-line>
  # Separate `local` statements on purpose: bash expands every word of a single
  # `local a=$1 b=$a` BEFORE applying any assignment, so `$slug` would be unset.
  local slug="$1"
  local marker="$2"
  local p="$TMP_ROOT/nm_$slug.md"
  {
    printf '### Task 1: alpha\n**Dependencies:** none\n'
    printf '%s\n' "$marker"
    printf '### Task 2: beta\n**Dependencies:** Task 1\n'
  } > "$p"
  run "$p"
  if [ "$RC" -eq 0 ]; then pass "(f) near-miss ignored: $marker"
  else bad "(f) near-miss classified as a declaration (rc=$RC): $marker → $OUT"; fi
}
nearmiss_case paths    '**Failure paths:** skip-and-continue, then retry'
nearmiss_case handling '**Failure handling (W1):** skip-and-continue'
nearmiss_case modes    '**Failure modes:** maybe, unknown, other'
nearmiss_case pathunit '**Failure-path unit:** skip-and-continue'
nearmiss_case moderow  '**Failure Mode row** — skip-and-continue'
nearmiss_case crossmod '**Failure case (cross-model finding):** maybe'

# ── (j) anchoring: prose mention is not a declaration and must not shadow ────
P_J=$(mk prose <<'EOF'
### Task 1: alpha
**Dependencies:** none
Some narrative that mentions **Failure:** maybe in passing.
**Failure:** halt
### Task 2: beta
**Dependencies:** Task 1
EOF
)
run "$P_J"
expect_rc 0 "(j) mid-line prose mention is ignored and does not shadow the real line"

P_J2=$(mk bullet <<EOF
### Task 1: alpha
**Surface:** config ${BULLET} **Failure:** skip-and-continue ${BULLET} **Execution routing:** deep
**Dependencies:** none
### Task 2: beta
**Dependencies:** Task 1
EOF
)
run "$P_J2"
expect_rc 1 "(j) an inline ${BULLET}-bulleted **Failure:** IS a declaration (and is cut at the next bullet)"
case "$OUT" in
  *"Execution routing"*) bad "(j) inline value was not cut at the next ${BULLET} bullet: $OUT" ;;
  *) pass "(j) inline value cut at the next ${BULLET} bullet" ;;
esac

# ── (g) the enum never touches the graph ─────────────────────────────────────
# g1: a clean fixture — the ENTIRE --json payload is byte-identical with and
# without the line (same plan path both runs), so task count, cycles,
# forward_refs and missing_deps cannot have moved.
G1="$TMP_ROOT/graph_clean.md"
cat > "$G1" <<'EOF'
### Task 1: alpha
**Dependencies:** none
**Failure:** skip-and-continue
### Task 2: beta
**Dependencies:** none
### Task 3: gamma
**Dependencies:** Task 1, Task 2
EOF
# Task 1 IS depended on here, so strip it down to an in-degree-zero declarer:
cat > "$G1" <<'EOF'
### Task 1: alpha
**Dependencies:** none
### Task 2: beta
**Dependencies:** Task 1
### Task 3: gamma
**Dependencies:** Task 1, Task 2
**Failure:** skip-and-continue
EOF
run "$G1" --json; J_WITH="$OUT"; RC_WITH=$RC
/usr/bin/grep -vF '**Failure:**' "$G1" > "$G1.tmp" && mv "$G1.tmp" "$G1"
run "$G1" --json; J_WITHOUT="$OUT"; RC_WITHOUT=$RC
if [ "$J_WITH" = "$J_WITHOUT" ] && [ "$RC_WITH" -eq "$RC_WITHOUT" ]; then
  pass "(g) clean fixture: --json byte-identical with and without the line"
else
  bad "(g) --json differs with/without the line:
  with:    $J_WITH
  without: $J_WITHOUT"
fi

# g2: every dependency edge points forward, so `forward_refs` enumerates EVERY
# edge in the graph — an explicit edge-count assertion, not an inference.
G2="$TMP_ROOT/graph_edges.md"
cat > "$G2" <<'EOF'
### Task 1: alpha
**Dependencies:** Task 2
**Failure:** skip-and-continue
### Task 2: beta
**Dependencies:** Task 3
### Task 3: gamma
**Dependencies:** none
EOF
run "$G2" --json; E_WITH="$OUT"
/usr/bin/grep -vF '**Failure:**' "$G2" > "$G2.tmp" && mv "$G2.tmp" "$G2"
run "$G2" --json; E_WITHOUT="$OUT"
count_edges() { json_array "$1" forward_refs | tr ',' '\n' | /usr/bin/grep -c '"task"'; }
NW="$(count_edges "$E_WITH")"; NO="$(count_edges "$E_WITHOUT")"
TW="$(printf '%s' "$E_WITH"    | /usr/bin/sed -n 's/.*"tasks":\([0-9]*\).*/\1/p')"
TO="$(printf '%s' "$E_WITHOUT" | /usr/bin/sed -n 's/.*"tasks":\([0-9]*\).*/\1/p')"
if [ "$NW" = "2" ] && [ "$NO" = "2" ] && [ "$TW" = "3" ] && [ "$TO" = "3" ]; then
  pass "(g) edge count 2 and task count 3, identical with and without the line"
else
  bad "(g) counts moved — edges with=$NW without=$NO (want 2/2), tasks with=$TW without=$TO (want 3/3)"
fi

# ── (h) cross-file enum parity with skills/plan/SKILL.md rule 20 ─────────────
# Independent extractions on both sides:
#   SKILL.md → the backticked `**Failure:** a | b | c` union quoted INSIDE rule
#              20 (the authoring contract), split on `|`, each token cut at the
#              first `:`/`<` so `degraded:<one-line description>` → `degraded`.
#   parser   → the fstrat assignment tokens inside the `failure-enum` fence.
skill_enum() {
  awk '
    /^20\. \*\*Failure strategy/ { inrule = 1 }
    inrule && /^21\. \*\*/       { inrule = 0 }
    inrule {
      s = $0
      while (match(s, /`\*\*Failure:\*\*[^`]*`/)) {
        u = substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)
        if (index(u, "|") == 0) continue           # a bare marker mention
        sub(/^`\*\*Failure:\*\*/, "", u)
        sub(/`$/, "", u)
        nt = split(u, toks, "|")
        for (i = 1; i <= nt; i++) {
          t = toks[i]
          sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
          p = index(t, ":"); if (p > 0) t = substr(t, 1, p - 1)
          p = index(t, "<"); if (p > 0) t = substr(t, 1, p - 1)
          sub(/[[:space:]]+$/, "", t)
          if (t != "") print t
        }
      }
    }' "$SKILL" | sort -u
}
parser_enum() {
  awk '
    /# >>> failure-enum/ { inf = 1; next }
    /# <<< failure-enum/ { inf = 0 }
    inf {
      s = $0
      p = index(s, "fstrat[cur] =")
      if (p == 0) next
      t = substr(s, p)
      if (match(t, /"[^"]*"/)) {
        v = substr(t, RSTART + 1, RLENGTH - 2)
        if (v != "" && v != "?") print v
      }
    }' "$V" | sort -u
}
SE="$(skill_enum)"; PE="$(parser_enum)"
if [ -z "$SE" ]; then
  bad "(h) extracted no enum tokens from rule 20 of $SKILL"
elif [ -z "$PE" ]; then
  bad "(h) extracted no classifier tokens from the failure-enum fence in $V"
elif [ "$SE" = "$PE" ]; then
  pass "(h) enum parity: $(printf '%s' "$SE" | tr '\n' ' ')"
else
  bad "(h) enum drift between skills/plan/SKILL.md rule 20 and the parser:
$(diff <(printf '%s\n' "$SE") <(printf '%s\n' "$PE"))"
fi
if [ "$(printf '%s\n' "$SE" | /usr/bin/grep -c .)" = "3" ]; then
  pass "(h) rule 20 names exactly three tokens"
else
  bad "(h) rule 20 must name exactly three tokens; got: $(printf '%s' "$SE" | tr '\n' ' ')"
fi

# ── --help documents the field, and terminates at the header (self-scanning) ─
# `--help` scans the header comment block until the first non-`#` line, so it
# never needs a hardcoded range re-synced when the block grows. Assert both
# the new content AND the last line of the block.
HELP="$("$V" --help 2>&1)"
if printf '%s' "$HELP" | /usr/bin/grep -qF '**Failure:**' \
   && printf '%s' "$HELP" | /usr/bin/grep -qF 'Portable to macOS'; then
  pass "--help documents **Failure:** and is not truncated"
else
  bad "--help must document **Failure:** and still print the whole header block; got:
$HELP"
fi

# --help must stop AT the header — it must not spill into the script body
# (shell code, awk source, LC_ALL, the shebang line itself). This is the
# behavior a hardcoded `sed -n 'A,Bp'` range cannot self-verify: it has no
# way to know it ran past the comment block into code.
if printf '%s' "$HELP" | /usr/bin/grep -qE '^#!|LC_ALL|awk -v json|^function '; then
  bad "--help output ran past the header comment block into script code: $HELP"
else
  pass "--help output stops at the header and does not leak script code"
fi

# ── (l) unreadable plan file → exit 2 (IO error), not exit 1 (content) ───────
# `[ ! -f "$PLAN" ]` alone lets a permission-denied file fall through to the
# shell's own `< "$PLAN"` redirect failure — rc=1, no `verify-plan-dag:`
# prefix, and an IO error (contractually exit 2) reads as a content
# violation (exit 1). Root can read anything regardless of mode bits, so this
# case cannot be enforced when running as root — skip rather than false-pass.
if [ "$(id -u)" -eq 0 ]; then
  echo "SKIP: (l) running as root — permission bits cannot be enforced, skipping unreadable-plan test"
else
  P_L="$TMP_ROOT/unreadable.md"
  printf '### Task 1: alpha\n**Dependencies:** none\n' > "$P_L"
  chmod 000 "$P_L"
  run "$P_L"
  chmod 644 "$P_L"   # restore before cleanup so trap rm -rf is unaffected
  expect_rc 2 "(l) unreadable plan file is an IO error (exit 2), not a content violation"
  case "$OUT" in
    *"verify-plan-dag:"*"permission denied"*) pass "(l) message is prefixed and names permission denied" ;;
    *) bad "(l) expected a 'verify-plan-dag: ... permission denied' message; got: $OUT" ;;
  esac
fi

# ── purity: this test never writes into the repo ─────────────────────────────
# NOT a whole-repo `git status` diff (the idiom in test-dev-push-gate.sh): this
# suite is routinely run inside a worktree while sibling agents edit other
# files, and a whole-repo snapshot turns their unrelated writes into a failure
# of THIS test. The property that actually matters is asserted directly and
# deterministically instead: every fixture lands outside the repo, and both
# files the suite reads are byte-identical afterwards.
case "$TMP_ROOT" in
  "$ROOT"/*|"$ROOT") bad "fixture root $TMP_ROOT is inside the repo" ;;
  *)                 pass "every fixture lives outside the repo ($TMP_ROOT)" ;;
esac
SUM_AFTER="$(cksum "$V" "$SKILL" 2>/dev/null)"
if [ "$SUM_BEFORE" = "$SUM_AFTER" ]; then
  pass "the parser and skills/plan/SKILL.md are byte-unchanged by this run"
else
  bad "this run modified its own inputs — before=[$SUM_BEFORE] after=[$SUM_AFTER]"
fi

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "ALL PASSED"
  exit 0
else
  echo "SOME FAILED"
  exit 1
fi
