#!/usr/bin/env bash
# test-task-telemetry-contract.sh — Task 4: per-task telemetry persistence.
#
# RED-first: authored BEFORE the `# >>> zuvo:task-telemetry` fenced block is
# inserted at the end of Step 9b in skills/execute/SKILL.md. Until that fence
# exists every assertion below fails loudly (intended RED evidence).
#
# WHAT THIS PINS
# The [TELEMETRY] block skills/execute/SKILL.md already emits is printed to chat
# and then lost. The fence persists it as one JSON line per task in
# `zuvo/context/task-telemetry.jsonl`. That file is a DIAGNOSTIC, never a gate:
# a failed append must WARN and continue, never block the task.
#
# Asserts:
#   (a) SCHEMA      — the appended line is valid JSON whose key SET is exactly the
#                     key list documented in shared/includes/session-state.md.
#                     The count is DERIVED from that document, never hardcoded
#                     here — a test carrying its own copy of the schema is the
#                     drift CQ14 exists to prevent (plan G20). The doc rows are
#                     read between explicit `zuvo:telemetry-schema` markers, not
#                     "until the next `---`": a rule INSIDE the section would
#                     silently truncate the schema the test compares against.
#                     Key tokens are matched with the full documented alphabet
#                     (`[a-z][a-z0-9-]*`) and that alphabet is asserted, so a
#                     future key cannot fall out of BOTH sides of the diff and
#                     leave it spuriously empty.
#   (b) ARRAY       — `acceptance-verified` is a JSON array, built from ONE JSON
#                     argv value. A comma INSIDE an element must survive whole
#                     (an AC id or artifact path may legally contain one), and a
#                     value that is not JSON degrades to [] — never to a
#                     comma-split list.
#   (c) ROUND-TRIP  — adversarial values survive intact: a task name carrying `"`
#                     and an em-dash, a `verify` value carrying quotes/`=`/spaces,
#                     an `acceptance-verified` element carrying `@` and a comma.
#                     This is what the argv-passed heredoc (CQ31) buys; an
#                     interpolated shell string would corrupt or inject on every
#                     one of them.
#   (d) APPEND-ONLY — two runs produce exactly two RECORDS (counted by parsing,
#                     not by counting physical lines) and the pre-existing bytes
#                     are a byte-exact PREFIX of the file afterwards. Second run
#                     uses a new session-id but the same retro-session-id — the
#                     resume shape (plan G3).
#   (e) MKDIR       — the target directory does NOT exist beforehand and the file
#                     still appears. Highest-value case here: `open(...,"a")`
#                     raises FileNotFoundError on a missing dir, which degrades
#                     the whole change to "always [WARN], never persists" while
#                     every other assertion still passes.
#   (f) NO-PYTHON   — with python3 absent the block exits 0 and prints [WARN].
#                     Uses a SHADOW-PATH dir built FROM the fence's own derived
#                     command dependencies (python3 deliberately omitted), not
#                     PATH=/nonexistent — the latter also removes git/date and
#                     would test a different failure. Also a stub python3 exiting
#                     127: `command not found` and a non-zero child are different
#                     bytes through the same `|| echo` tail.
#   (g) SHAPE       — on the WARN path: exit 0 AND stdout is BYTE-EXACTLY the one
#                     documented [WARN] line (the expected text is extracted from
#                     the fence itself, so it cannot drift). On the success path:
#                     exit 0 and stdout completely silent. A `|| echo` bound to
#                     the wrong command is the realistic way this contract
#                     silently changes shape, and it is only visible as
#                     extra/missing stdout.
#   (h) PURITY      — running this test never mutates the repo working tree.
#   (i) ENUM        — documented closed sets are honoured by the written record.
#   (j) PLACEHOLDER — an unsubstituted run is DETECTABLY wrong: string fields keep
#                     their `<...>` marker and the int fields land as the `-1`
#                     sentinel (not a plausible-looking 0), while a well-formed
#                     record carries neither.
#   (k) CONCURRENCY — N runners appending to ONE file concurrently produce exactly
#                     N parseable records with N distinct task numbers. execute
#                     dispatches tasks in PARALLEL BATCHES, so an unlocked append
#                     interleaves two records inside one physical line and loses
#                     both.
#   (l) ROOT        — with ZUVO_OUTPUT_DIR unset the block resolves <git root>/zuvo
#                     (the same derivation execution-state.md uses) and, when no
#                     root resolves at all, takes the [WARN] path instead of
#                     writing into an arbitrary directory.
#   (m) DEPS        — the shadow PATH is built from the fence's OWN derived
#                     command set, and a run under that shadow WITH python3 must
#                     succeed. If the fence ever needs a command the derivation
#                     missed, this fails loudly instead of letting (f) pass for
#                     the wrong reason.
#
# NO ASSERTION MAY BE SILENTLY SKIPPED. Every group that depends on an artifact
# from an earlier group emits an explicit FAIL when that artifact is missing —
# a group that prints nothing at all is indistinguishable from a group that
# passed, and that is how a broken writer reads as green.
#
# awk-fence extraction + hermetic-runner idiom from tests/skill-suite/test-dev-push-gate.sh.
# bash 3.2-compatible (macOS default): no mapfile, no associative arrays.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/skills/execute/SKILL.md"
STATE_DOC="$ROOT/shared/includes/session-state.md"
FENCE='zuvo:task-telemetry'
SCHEMA_START='<!-- zuvo:telemetry-schema:start -->'
SCHEMA_END='<!-- zuvo:telemetry-schema:end -->'

# Hermetic git: the fixtures are throwaway dirs, but the block resolves its
# output root through `git rev-parse --show-toplevel` when ZUVO_OUTPUT_DIR is
# unset. Isolating config neutralises a global core.hooksPath / commit.gpgsign /
# init.templateDir leaking into anything this test runs.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }
# A dependent group whose input never materialised. Loud by construction: the
# alternative (printing nothing) is the silent-skip failure this suite forbids.
skipped() { printf 'FAIL: %s [assertion group did not run — treated as failure]\n' "$1"; fail=1; }

# Shell options skills/execute/SKILL.md's fenced blocks run under in production.
# The runner below is prefixed with these: without them the test executes the
# block with semantics production never uses (no -e, no -u, no pipefail), which
# can hide a real failure — an unset variable that would abort merely expands to
# empty. This mirrors the fix made to tests/skill-suite/test-dev-push-gate.sh.
SET_OPTS='set -euo pipefail'

TMP_ROOT="$(mktemp -d)"
_cleanup() { chmod -R u+w "$TMP_ROOT" 2>/dev/null; rm -rf "$TMP_ROOT"; }
trap _cleanup EXIT
trap '_cleanup; exit 1' INT TERM

# (h) baseline
GIT_BEFORE="$( (cd "$ROOT" && git status --porcelain) 2>/dev/null )"

if [ ! -f "$SKILL" ]; then
  bad "skills/execute/SKILL.md not found at $SKILL"
  echo "----"; echo "SOME FAILED"; exit 1
fi
if [ ! -f "$STATE_DOC" ]; then
  bad "shared/includes/session-state.md not found at $STATE_DOC"
  echo "----"; echo "SOME FAILED"; exit 1
fi

# The block under test IS a python3 program, and every schema assertion parses
# JSON. Without python3 this suite could only ever exercise case (f) — reporting
# green on a box where most groups never ran is exactly the silent-skip failure
# tests/skill-suite/test-dev-push-gate.sh made a hard error.
if ! command -v python3 >/dev/null 2>&1; then
  bad "python3 not on PATH — this suite cannot verify the telemetry schema"
  echo "----"; echo "SOME FAILED"; exit 1
fi

# ── fence markers: EXACTLY ONE PAIR, correctly ordered ────────────────────────
# head -1 per marker could pair a `>>>` with a `<<<` from a different (duplicated
# or half-deleted) fence, and the extractor would capture the wrong span — here,
# arbitrary prose from the middle of a SKILL.md, executed as bash.
marker_lines() { grep -Fn "$1" "$2" 2>/dev/null | cut -d: -f1; }
marker_count() { marker_lines "$1" "$2" | grep -c . ; }

fence_pair() {  # $1 = fence name, $2 = file → echoes "START END", rc 1 if unusable
  local _s _e _ns _ne
  _ns="$(marker_count "# >>> $1" "$2")"
  _ne="$(marker_count "# <<< $1" "$2")"
  if [ "$_ns" -ne 1 ] || [ "$_ne" -ne 1 ]; then
    printf 'MARKERS %s start=%s end=%s\n' "$1" "$_ns" "$_ne"
    return 1
  fi
  _s="$(marker_lines "# >>> $1" "$2")"
  _e="$(marker_lines "# <<< $1" "$2" | awk -v s="$_s" '$1 > s {print; exit}')"
  [ -n "$_e" ] || { printf 'MARKERS %s end-before-start\n' "$1"; return 1; }
  printf '%s %s\n' "$_s" "$_e"
}

PAIR="$(fence_pair "$FENCE" "$SKILL")" || true
F_START="$(printf '%s' "$PAIR" | grep -E '^[0-9]+ [0-9]+$' | cut -d' ' -f1)"
F_END="$(printf '%s' "$PAIR" | grep -E '^[0-9]+ [0-9]+$' | cut -d' ' -f2)"

if [ -n "$F_START" ] && [ -n "$F_END" ]; then
  pass "fenced $FENCE block present, exactly one >>>/<<< pair (lines $F_START/$F_END)"
else
  bad "fenced $FENCE block MISSING or not exactly one >>>/<<< pair — fence_pair said [$PAIR]"
fi

# ── placement: inside Step 9b, AFTER the printed telemetry block, and strictly
# BEFORE Step 10. Step 9 (the execution-state.md rewrite) is blocking-by-contract;
# a must-never-block write placed there invites the harden-into-a-gate drift this
# design forbids, so the boundary is asserted rather than trusted.
S9B_LINE="$(grep -nF '### Step 9b:' "$SKILL" | head -1 | cut -d: -f1)"
S10_LINE="$(grep -nF '### Step 10:' "$SKILL" | head -1 | cut -d: -f1)"
if [ -n "$F_START" ] && [ -n "$S9B_LINE" ] && [ -n "$S10_LINE" ] \
   && [ "$F_START" -gt "$S9B_LINE" ] && [ "$F_END" -lt "$S10_LINE" ]; then
  pass "fence ($F_START-$F_END) lies inside Step 9b ($S9B_LINE) and before Step 10 ($S10_LINE)"
else
  bad "fence must sit inside Step 9b: got fence=$F_START-$F_END step9b=$S9B_LINE step10=$S10_LINE"
fi

# ── HARD GUARD: never extract/execute an unbounded block ──────────────────────
if [ -z "$F_START" ] || [ -z "$F_END" ] || [ "$F_END" -le "$F_START" ]; then
  bad "fence markers absent/misordered (>>> '$F_START' <<< '$F_END') — refusing block extraction/execution"
  echo "----"; echo "SOME FAILED"; exit 1
fi

BLOCK="$(awk -v s="# >>> $FENCE" -v e="# <<< $FENCE" \
  'index($0,s){f=1;next} index($0,e){exit} f{print}' "$SKILL")"

if [ -z "$BLOCK" ]; then
  bad "extracted $FENCE block is EMPTY"
  echo "----"; echo "SOME FAILED"; exit 1
fi

# ── the documented [WARN] text, derived from the fence (never hardcoded) ──────
# Every WARN-path assertion below compares stdout against this COMPLETE string.
# A substring check ("contains [WARN]") would pass with debug echoes, a doubled
# warning, or a mangled message appended to it — all shape changes this contract
# exists to catch.
WARN_COUNT="$(printf '%s\n' "$BLOCK" | grep -c '^[[:space:]]*|| echo "\[WARN\]')"
WARN_EXPECTED="$(printf '%s\n' "$BLOCK" \
  | sed -n 's/^[[:space:]]*|| echo "\(\[WARN\].*\)"[[:space:]]*$/\1/p')"
if [ "$WARN_COUNT" -eq 1 ] && [ -n "$WARN_EXPECTED" ]; then
  pass "(g) fence carries exactly one '|| echo \"[WARN] …\"' tail; expected stdout derived from it"
else
  bad "(g) expected exactly one '|| echo \"[WARN] …\"' tail in the fence; found $WARN_COUNT, parsed [$WARN_EXPECTED]"
fi

# ── (a) SCHEMA SSOT: the documented key list ──────────────────────────────────
# Bounded by EXPLICIT markers, not "from the heading to the next `---`": a
# horizontal rule or a second heading inside the section would silently truncate
# the row set, and a truncated key list on BOTH sides still diffs clean.
# DOC_ROWS holds the full `| \`key\` | type | meaning |` lines — the (a) key-set
# check derives DOC_KEYS from it and the enum-membership check derives its
# allowed-value lists from the SAME lines. One parser, two consumers.
N_SCHEMA_START="$(grep -Fc "$SCHEMA_START" "$STATE_DOC")"
N_SCHEMA_END="$(grep -Fc "$SCHEMA_END" "$STATE_DOC")"
if [ "$N_SCHEMA_START" -eq 1 ] && [ "$N_SCHEMA_END" -eq 1 ]; then
  pass "(a) session-state.md carries exactly one zuvo:telemetry-schema start/end marker pair"
else
  bad "(a) expected exactly one zuvo:telemetry-schema start and end marker; got start=$N_SCHEMA_START end=$N_SCHEMA_END"
fi

DOC_ROWS="$TMP_ROOT/doc-rows.txt"
awk -v s="$SCHEMA_START" -v e="$SCHEMA_END" \
  'index($0,s){f=1;next} index($0,e){exit} f{print}' "$STATE_DOC" \
  | grep -E '^\|[[:space:]]*`[^`]+`[[:space:]]*\|' > "$DOC_ROWS"

DOC_KEYS="$TMP_ROOT/doc-keys.txt"
sed -E 's/^\|[[:space:]]*`([^`]+)`.*$/\1/' "$DOC_ROWS" | sort > "$DOC_KEYS"

DOC_KEY_COUNT="$(grep -c . "$DOC_KEYS")"
if [ "$DOC_KEY_COUNT" -gt 0 ]; then
  pass "(a) session-state.md documents $DOC_KEY_COUNT telemetry keys (count derived, not hardcoded)"
else
  bad "(a) no telemetry key rows found between the zuvo:telemetry-schema markers in session-state.md"
fi

# The written schema: the fence's own key list. Any backticked/quoted token is
# captured — matching only `[a-z-]+` on BOTH sides would let a key with a digit
# or an underscore drop out of the doc list AND the fence list at once, leaving
# a clean diff over an incomplete comparison.
BLOCK_KEYS="$TMP_ROOT/block-keys.txt"
printf '%s\n' "$BLOCK" \
  | awk '/^K = \[/ {f=1} f {print} f && /\]/ {exit}' \
  | grep -oE '"[^"]+"' | tr -d '"' | sort > "$BLOCK_KEYS"

# The documented key alphabet, asserted rather than assumed (see above).
BAD_ALPHA="$( { cat "$DOC_KEYS"; cat "$BLOCK_KEYS"; } | grep -vE '^[a-z][a-z0-9-]*$' | sort -u )"
if [ -z "$BAD_ALPHA" ]; then
  pass "(a) every documented and written key matches the documented alphabet [a-z][a-z0-9-]*"
else
  bad "(a) key(s) outside the documented alphabet [a-z][a-z0-9-]*: [$(printf '%s' "$BAD_ALPHA" | tr '\n' ' ')]"
fi

if [ -s "$BLOCK_KEYS" ] && diff -u "$DOC_KEYS" "$BLOCK_KEYS" >/dev/null 2>&1; then
  pass "(a) fence key list == session-state.md key list ($DOC_KEY_COUNT keys) — schema cannot drift"
else
  bad "(a) documented schema and written schema differ: $(diff -u "$DOC_KEYS" "$BLOCK_KEYS" 2>&1 | tr '\n' ' ')"
fi

# ── (m) the fence's OWN external command dependencies ─────────────────────────
# The shadow PATH below is built from THIS list rather than a hand-maintained
# whitelist. A hardcoded whitelist rots the moment the fence needs one more tool:
# the no-python3 case would then fail on the missing tool instead of on the
# missing interpreter, and pass for the wrong reason.
# Shell part = everything outside the python heredoc body. The body starts after
# the `|| echo` continuation line (the heredoc opener is line-continued into it)
# and ends at the `PY` terminator.
SHELL_PART="$TMP_ROOT/fence-shell.txt"
printf '%s\n' "$BLOCK" | awk '
  inbody { if ($0 ~ /^PY[[:space:]]*$/) { inbody = 0 } ; next }
  { print }
  /^[[:space:]]*\|\| echo/ { inbody = 1 }
' > "$SHELL_PART"

FENCE_TOKENS="$TMP_ROOT/fence-tokens.txt"
{
  # command position: first word of each non-comment, non-assignment line
  grep -vE '^[[:space:]]*#' "$SHELL_PART" \
    | grep -vE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' \
    | sed -E 's/^[[:space:]]+//' \
    | grep -oE '^[A-Za-z0-9_./-]+'
  # command substitutions anywhere on the line
  grep -oE '\$\([[:space:]]*[A-Za-z0-9_./-]+' "$SHELL_PART" \
    | sed -E 's/^\$\([[:space:]]*//'
} | sort -u > "$FENCE_TOKENS"

FENCE_DEPS="$TMP_ROOT/fence-deps.txt"
: > "$FENCE_DEPS"
while IFS= read -r _tok; do
  [ -n "$_tok" ] || continue
  # keep only tokens that resolve to a real external binary; shell keywords,
  # builtins and variable names resolve to nothing here and drop out.
  if [ "$(type -t "$_tok" 2>/dev/null || true)" = "file" ]; then
    printf '%s\n' "$_tok" >> "$FENCE_DEPS"
  fi
done < "$FENCE_TOKENS"
sort -u -o "$FENCE_DEPS" "$FENCE_DEPS"

DEP_LIST="$(tr '\n' ' ' < "$FENCE_DEPS")"
if grep -qx 'python3' "$FENCE_DEPS"; then
  pass "(m) fence command dependencies derived from the fence itself: [$DEP_LIST]"
else
  bad "(m) derived dependency set does not contain python3 — the derivation is broken, shadow PATH would be meaningless. Got [$DEP_LIST]"
fi

# build_shadow <dir> <include-python3: yes|no>
build_shadow() {
  local dir="$1" want_py="$2" t p
  mkdir -p "$dir"
  # `env` and `bash` are how the runner itself is launched under the shadow PATH,
  # so they belong to the harness, not to the fence's dependency set.
  for t in sh bash env; do
    p="$(command -v "$t" 2>/dev/null)" || continue
    [ -n "$p" ] && ln -sf "$p" "$dir/$t"
  done
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if [ "$t" = "python3" ] && [ "$want_py" != "yes" ]; then continue; fi
    p="$(command -v "$t" 2>/dev/null)" || continue
    [ -n "$p" ] && ln -sf "$p" "$dir/$t"
  done < "$FENCE_DEPS"
}

# ── hermetic runner ───────────────────────────────────────────────────────────
# production shell options + the extracted block body. Nothing else: the block is
# self-contained by contract (it must run at the end of Step 9b with no helper
# functions in scope).
RUNNER="$TMP_ROOT/runner.sh"
{
  printf '%s\n' "$SET_OPTS"
  printf '%s\n' "$BLOCK"
} > "$RUNNER"

# Adversarial values, used everywhere below. Each one is a value that an
# interpolated shell string would corrupt, truncate, or execute.
ADV_NAME='Tenant "extension" hardening — quotes & em-dash'
# Leading `-`: after `python3 -` every remaining word is argv, never re-parsed as
# an interpreter option. If the heredoc is ever "simplified" to `python3 -c "…"`
# with interpolated values, THIS is the value that turns into code execution.
ADV_VERIFY='-c npx vitest run "src/a b.spec.ts" --reporter=dot'
# ONE JSON array literal. The SECOND element carries a comma INSIDE it — the
# exact value `split(",")` corrupted into two array entries.
ADV_AC='["AC2@zuvo/proofs/task-4-report.md","AC5@zuvo/proofs/report, final (v2).md"]'
ADV_QUALITY='PASS cq=34/37@tenant.ts,35/37@guards.ts q=22/24@tenant.test.ts'

# run_block <outdir> <session-id> [extra env assignments...]
# Runs the fence with ZUVO_OUTPUT_DIR pointed at <outdir>. Captures stdout and
# stderr SEPARATELY: "no other output" is a statement about stdout, and a missing
# interpreter legitimately writes "command not found" to stderr.
# Extra assignments are appended LAST so a caller can OVERRIDE a default value —
# placed first they would be silently overwritten by the defaults below, and the
# caller's case would never actually run.
RC=0; OUT=''; ERR=''
run_block() {
  local outdir="$1" sid="$2"; shift 2
  local o="$TMP_ROOT/stdout.$$" e="$TMP_ROOT/stderr.$$"
  env ZUVO_OUTPUT_DIR="$outdir" \
      TT_AT="2026-08-02T10:00:00Z" \
      TT_SESSION_ID="$sid" \
      TT_RETRO_SESSION_ID="retro-20260802-1000" \
      TT_TASK="4" \
      TT_TASK_NAME="$ADV_NAME" \
      TT_SURFACE="integration" \
      TT_MODE="multi-agent" \
      TT_FALLBACK_PATH="none" \
      TT_WRITER_MODEL="opus" \
      TT_REVIEWER_ROUTE="review-alt" \
      TT_IMPLEMENTER_STATUS="DONE" \
      TT_SPEC_REVIEW="COMPLIANT" \
      TT_QUALITY_REVIEW="$ADV_QUALITY" \
      TT_ADVERSARIAL="PASS mode=code" \
      TT_VERIFY="$ADV_VERIFY" \
      TT_ACCEPTANCE_VERIFIED="$ADV_AC" \
      TT_CODESIFT="available" \
      TT_BACKLOG_ADDS="1" \
      TT_FAILURE_STRATEGY="halt" \
      "$@" \
      bash "$RUNNER" >"$o" 2>"$e"
  RC=$?
  OUT="$(cat "$o")"; ERR="$(cat "$e")"
  rm -f "$o" "$e"
}

# ── (e) MKDIR: target directory does not exist beforehand ─────────────────────
FIX1="$TMP_ROOT/fix1"
JSONL1="$FIX1/context/task-telemetry.jsonl"
if [ -e "$FIX1" ]; then bad "(e) fixture precondition broken: $FIX1 already exists"; fi
run_block "$FIX1" "exec-20260802-1000"
RC1=$RC; OUT1="$OUT"

if [ "$RC1" -eq 0 ] && [ -f "$JSONL1" ]; then
  pass "(e) missing target directory was created and the line landed (exit 0)"
else
  bad "(e) expected exit 0 + $JSONL1 to exist; got rc=$RC1 out=[$OUT1] err=[$ERR] ls=[$(ls -R "$FIX1" 2>&1)]"
fi

# ── (g) SHAPE, success path: stdout completely silent ─────────────────────────
if [ -z "$OUT1" ]; then
  pass "(g) success path is silent on stdout (no stray [WARN], no debug echoes)"
else
  bad "(g) success path printed to stdout: [$OUT1]"
fi

# Everything below needs the line to exist.
if [ -f "$JSONL1" ]; then
  # ── (a) SCHEMA: exact key set on the real record ────────────────────────────
  ACTUAL_KEYS="$TMP_ROOT/actual-keys.txt"
  if python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    rec = json.loads(fh.readline())
with open(sys.argv[2], "w", encoding="utf-8") as out:
    for k in sorted(rec):
        out.write(k + "\n")
' "$JSONL1" "$ACTUAL_KEYS" 2>"$TMP_ROOT/perr"; then
    if diff -u "$DOC_KEYS" "$ACTUAL_KEYS" >/dev/null 2>&1; then
      pass "(a) appended line is valid JSON with exactly the $DOC_KEY_COUNT documented keys"
    else
      bad "(a) key set mismatch vs session-state.md: $(diff -u "$DOC_KEYS" "$ACTUAL_KEYS" 2>&1 | tr '\n' ' ')"
    fi
  else
    bad "(a) appended line is not valid JSON: $(cat "$TMP_ROOT/perr") line=[$(head -1 "$JSONL1")]"
  fi

  # ── (i) ENUM MEMBERSHIP ──────────────────────────────────────────────────────
  # The field table documents CLOSED sets for several keys (mode, fallback-path,
  # implementer-status, spec-review, codesift, failure-strategy, ...) as a leading
  # `` `tok1` \| `tok2` \| ... `` run in the Meaning column. A malformed record —
  # e.g. an orchestrator that forgot to substitute a TT_* var — still appends
  # successfully today; nothing checks the VALUES land in the documented set.
  # This derives the allowed-value lists from DOC_ROWS (the same lines (a) already
  # isolated above — one parser, not a second copy) so the enum can never drift
  # from session-state.md. A token containing `<...>` (e.g. `degraded:<desc>`) is
  # a documented PREFIX pattern, not a literal value: matched by prefix-before-`<`,
  # exact string match otherwise.
  ENUM_OUT="$TMP_ROOT/enum_out.txt"
  if python3 -c '
import json, re, sys

def meaning_column(line):
    m = re.match(r"^\|[^|]*\|[^|]*\|(.*)\|\s*$", line.rstrip("\n"))
    if not m:
        return None
    return m.group(1).replace("\\|", "|").strip()

def leading_enum_tokens(cell):
    if not cell or cell[0] != "`":
        return None
    tokens, i, n = [], 0, len(cell)
    while i < n and cell[i] == "`":
        j = cell.find("`", i + 1)
        if j == -1:
            break
        tokens.append(cell[i + 1:j])
        i = j + 1
        while i < n and cell[i] == " ":
            i += 1
        if i < n and cell[i] == "|":
            i += 1
            while i < n and cell[i] == " ":
                i += 1
            continue
        break
    return tokens or None

def token_matches(token, value):
    idx = token.find("<")
    if idx != -1:
        return value.startswith(token[:idx])
    return value == token

doc_rows_path, record_path = sys.argv[1], sys.argv[2]
enums = {}
with open(doc_rows_path, encoding="utf-8") as fh:
    for line in fh:
        km = re.match(r"^\|\s*`([a-z][a-z0-9-]*)`", line)
        if not km:
            continue
        cell = meaning_column(line)
        if cell is None:
            continue
        tokens = leading_enum_tokens(cell)
        if tokens:
            enums[km.group(1)] = tokens

if not enums:
    print("NO-ENUMS-FOUND-IN-DOC")
    sys.exit(1)

rec = json.loads(open(record_path, encoding="utf-8").readline())
bad = []
for key, tokens in sorted(enums.items()):
    val = rec.get(key)
    if not isinstance(val, str) or not any(token_matches(t, val) for t in tokens):
        bad.append("%s=%r not in %r" % (key, val, tokens))

if bad:
    print("; ".join(bad))
    sys.exit(1)
print("%d enum-shaped keys validated (derived from doc, not hardcoded): %s"
      % (len(enums), ",".join(sorted(enums))))
' "$DOC_ROWS" "$JSONL1" >"$ENUM_OUT" 2>&1; then
    pass "(i) $(cat "$ENUM_OUT")"
  else
    bad "(i) enum membership failed against session-state.md-documented closed sets: $(cat "$ENUM_OUT")"
  fi

  # ── (b) ARRAY + (c) ROUND-TRIP + int types ──────────────────────────────────
  if python3 -c '
import json, sys
rec = json.loads(open(sys.argv[1], encoding="utf-8").readline())
name, verify, ac_json, quality = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
expected_ac = json.loads(ac_json)
ac = rec["acceptance-verified"]
assert isinstance(ac, list), "acceptance-verified is not a JSON array: %r" % (ac,)
assert ac == expected_ac, "acceptance-verified mis-parsed: %r != %r" % (ac, expected_ac)
assert len(ac) == 2, "comma inside an element split it: expected 2 entries, got %d (%r)" % (len(ac), ac)
assert "," in ac[1], "the element that CONTAINS a comma lost it: %r" % (ac[1],)
assert rec["task-name"] == name, "task-name corrupted: %r" % (rec["task-name"],)
assert rec["verify"] == verify, "verify corrupted: %r" % (rec["verify"],)
assert rec["quality-review"] == quality, "quality-review corrupted (per-file string must survive whole): %r" % (rec["quality-review"],)
assert isinstance(rec["task"], int), "task is not an int: %r" % (rec["task"],)
assert isinstance(rec["backlog-adds"], int), "backlog-adds is not an int: %r" % (rec["backlog-adds"],)
assert rec["failure-strategy"] == "halt", "failure-strategy default is not halt: %r" % (rec["failure-strategy"],)
' "$JSONL1" "$ADV_NAME" "$ADV_VERIFY" "$ADV_AC" "$ADV_QUALITY" 2>"$TMP_ROOT/perr2"; then
    pass "(b)(c) acceptance-verified is a JSON array whose comma-carrying element survives whole; quotes/em-dash/=/@ round-trip; task + backlog-adds are ints"
  else
    bad "(b)(c) round-trip failed: $(tail -3 "$TMP_ROOT/perr2" | tr '\n' ' ')"
  fi

  # ── (d) APPEND-ONLY: second run, resumed-session shape ──────────────────────
  # Byte-exact: snapshot the whole file, then require the new file to BEGIN with
  # those exact bytes. Comparing only `head -1` would miss a rewritten line 2, and
  # counting physical lines would let an embedded newline inflate or hide a record.
  SNAP="$TMP_ROOT/append-snapshot.bin"
  cp "$JSONL1" "$SNAP"
  run_block "$FIX1" "exec-20260802-1400"      # new session-id, same retro-session-id
  RC2=$RC

  APPEND_OUT="$TMP_ROOT/append_out.txt"
  if python3 -c '
import json, sys
prev = open(sys.argv[1], "rb").read()
now = open(sys.argv[2], "rb").read()
assert now.startswith(prev), "pre-existing bytes are NOT a prefix of the file after the second append (rewritten/truncated)"
tail = now[len(prev):]
assert tail.endswith(b"\n"), "appended chunk does not end with a newline: %r" % (tail,)
added = [l for l in tail.decode("utf-8").split("\n") if l.strip()]
assert len(added) == 1, "expected exactly ONE newly appended record, got %d" % len(added)
json.loads(added[0])
recs = [json.loads(l) for l in open(sys.argv[2], encoding="utf-8") if l.strip()]
assert len(recs) == 2, "expected 2 parseable records, got %d" % len(recs)
print("%d bytes appended, 1 new record, %d bytes of history byte-identical"
      % (len(tail), len(prev)))
' "$SNAP" "$JSONL1" >"$APPEND_OUT" 2>&1; then
    APPEND_OK=1
  else
    APPEND_OK=0
  fi

  if [ "$RC2" -eq 0 ] && [ "$APPEND_OK" -eq 1 ]; then
    pass "(d) second append → $(cat "$APPEND_OUT") (append-only, never rewritten)"
  else
    bad "(d) append-only violated: rc=$RC2 detail=[$(tail -3 "$APPEND_OUT" | tr '\n' ' ')]"
  fi

  if python3 -c '
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
assert len(recs) == 2, "expected 2 records, got %d" % len(recs)
assert recs[0]["session-id"] != recs[1]["session-id"], "session-id did not change across the simulated resume"
assert recs[0]["retro-session-id"] == recs[1]["retro-session-id"], "retro-session-id must be stable across a resume"
' "$JSONL1" 2>"$TMP_ROOT/perr3"; then
    pass "(d) both records parse; session-id differs, retro-session-id is one run identity"
  else
    bad "(d) resume identity check failed: $(tail -3 "$TMP_ROOT/perr3" | tr '\n' ' ')"
  fi
else
  skipped "(a) key set of the appended record — $JSONL1 was never created"
  skipped "(i) enum membership — $JSONL1 was never created"
  skipped "(b)(c) array + round-trip — $JSONL1 was never created"
  skipped "(d) append-only byte-exactness — $JSONL1 was never created"
  skipped "(d) resume identity — $JSONL1 was never created"
fi

# ── (b) a non-JSON acceptance-verified value degrades to [] ───────────────────
# NEVER to a comma-split list: that is the exact corruption this field's contract
# forbids, and "AC1,AC2" is precisely what the old writer would have split.
FIX_AC="$TMP_ROOT/fix-ac"
run_block "$FIX_AC" "exec-20260802-1700" "TT_ACCEPTANCE_VERIFIED=AC1,AC2"
RC_AC=$RC
JSONL_AC="$FIX_AC/context/task-telemetry.jsonl"
if [ "$RC_AC" -eq 0 ] && [ -f "$JSONL_AC" ] && python3 -c '
import json, sys
rec = json.loads(open(sys.argv[1], encoding="utf-8").readline())
ac = rec["acceptance-verified"]
assert ac == [], "non-JSON acceptance-verified must degrade to [], got %r" % (ac,)
' "$JSONL_AC" 2>"$TMP_ROOT/perr_ac"; then
  pass "(b) a non-JSON acceptance-verified value degrades to [] and never to a comma-split list"
else
  bad "(b) non-JSON acceptance-verified handling wrong: rc=$RC_AC detail=[$(tail -2 "$TMP_ROOT/perr_ac" 2>/dev/null | tr '\n' ' ')]"
fi

# ── (k) CONCURRENCY: N runners, ONE output file ───────────────────────────────
# zuvo:execute dispatches tasks in PARALLEL BATCHES, so this is the production
# shape, not a synthetic stress test. Without an exclusive lock two appends
# interleave inside one physical line and BOTH records are lost to a
# line-oriented reader — which is why the check parses every line rather than
# counting them.
CONC_N=12
FIX5="$TMP_ROOT/fix5"
JSONL5="$FIX5/context/task-telemetry.jsonl"
conc_one() {  # $1 = index
  local i="$1"
  env ZUVO_OUTPUT_DIR="$FIX5" \
      TT_AT="2026-08-02T10:00:0${i}Z" \
      TT_SESSION_ID="exec-conc-$i" \
      TT_RETRO_SESSION_ID="retro-20260802-1000" \
      TT_TASK="$i" \
      TT_TASK_NAME="$ADV_NAME" \
      TT_SURFACE="integration" \
      TT_MODE="multi-agent" \
      TT_FALLBACK_PATH="none" \
      TT_WRITER_MODEL="opus" \
      TT_REVIEWER_ROUTE="review-alt" \
      TT_IMPLEMENTER_STATUS="DONE" \
      TT_SPEC_REVIEW="COMPLIANT" \
      TT_QUALITY_REVIEW="$ADV_QUALITY" \
      TT_ADVERSARIAL="PASS mode=code" \
      TT_VERIFY="$ADV_VERIFY" \
      TT_ACCEPTANCE_VERIFIED="$ADV_AC" \
      TT_CODESIFT="available" \
      TT_BACKLOG_ADDS="1" \
      TT_FAILURE_STRATEGY="halt" \
      bash "$RUNNER" >"$TMP_ROOT/conc.$i.out" 2>"$TMP_ROOT/conc.$i.err"
  printf '%s\n' "$?" > "$TMP_ROOT/conc.$i.rc"
}

mkdir -p "$FIX5"
_i=1
while [ "$_i" -le "$CONC_N" ]; do
  conc_one "$_i" &
  _i=$((_i + 1))
done
wait

CONC_BADRC=0; CONC_NOISE=''
_i=1
while [ "$_i" -le "$CONC_N" ]; do
  [ "$(cat "$TMP_ROOT/conc.$_i.rc" 2>/dev/null || echo 99)" -eq 0 ] || CONC_BADRC=$((CONC_BADRC + 1))
  [ -s "$TMP_ROOT/conc.$_i.out" ] && CONC_NOISE="$CONC_NOISE $_i:$(cat "$TMP_ROOT/conc.$_i.out")"
  _i=$((_i + 1))
done

CONC_OUT="$TMP_ROOT/conc_out.txt"
if [ "$CONC_BADRC" -eq 0 ] && [ -z "$CONC_NOISE" ] && [ -f "$JSONL5" ] && python3 -c '
import json, sys
path, n = sys.argv[1], int(sys.argv[2])
raw = open(path, encoding="utf-8").read()
lines = [l for l in raw.split("\n") if l.strip()]
recs = []
for i, l in enumerate(lines, 1):
    try:
        recs.append(json.loads(l))
    except ValueError as exc:
        raise SystemExit("line %d is not valid JSON (interleaved append?): %s :: %r" % (i, exc, l[:200]))
if len(recs) != n:
    raise SystemExit("expected %d records, got %d (lost or merged appends)" % (n, len(recs)))
tasks = sorted(r["task"] for r in recs)
if tasks != list(range(1, n + 1)):
    raise SystemExit("task numbers not 1..%d — a record was lost or overwritten: %r" % (n, tasks))
if len(lines) != n:
    raise SystemExit("expected %d physical lines, got %d" % (n, len(lines)))
print("%d concurrent appends -> %d valid JSON records, task numbers 1..%d all present" % (n, len(recs), n))
' "$JSONL5" "$CONC_N" >"$CONC_OUT" 2>&1; then
  pass "(k) $(cat "$CONC_OUT")"
else
  bad "(k) concurrent appends corrupted the JSONL: badrc=$CONC_BADRC stdout-noise=[$CONC_NOISE] detail=[$(tail -3 "$CONC_OUT" 2>/dev/null | tr '\n' ' ')]"
fi

# ── (n)(o) fcntl PORTABILITY: defensive import, unlocked-append fallback ──────
# The fence imports `fcntl` (POSIX-only) inside a try/except and takes the lock
# only when it is available. These two groups pin BOTH sides of that branch so
# neither can silently regress to the unconditional `import fcntl` that turns
# an ImportError into "always [WARN], never persists" on a platform without it.

# (n) FCNTL-PRESENT: the normal case on this host. Assert the OBSERVABLE, not
# the internals — a small concurrent-append run still yields exactly N valid
# JSON records, which is only true when the exclusive lock actually serialised
# the appends (see (k) above for the full-size version of this same proof).
FCNTL_N=4
FIX_FCNTL_OK="$TMP_ROOT/fix-fcntl-ok"
JSONL_FCNTL_OK="$FIX_FCNTL_OK/context/task-telemetry.jsonl"
mkdir -p "$FIX_FCNTL_OK"
fcntl_ok_one() {  # $1 = index
  local i="$1"
  env ZUVO_OUTPUT_DIR="$FIX_FCNTL_OK" \
      TT_AT="2026-08-02T11:00:0${i}Z" \
      TT_SESSION_ID="exec-fcntl-ok-$i" \
      TT_RETRO_SESSION_ID="retro-20260802-1000" \
      TT_TASK="$i" \
      TT_TASK_NAME="$ADV_NAME" \
      TT_SURFACE="integration" \
      TT_MODE="multi-agent" \
      TT_FALLBACK_PATH="none" \
      TT_WRITER_MODEL="opus" \
      TT_REVIEWER_ROUTE="review-alt" \
      TT_IMPLEMENTER_STATUS="DONE" \
      TT_SPEC_REVIEW="COMPLIANT" \
      TT_QUALITY_REVIEW="$ADV_QUALITY" \
      TT_ADVERSARIAL="PASS mode=code" \
      TT_VERIFY="$ADV_VERIFY" \
      TT_ACCEPTANCE_VERIFIED="$ADV_AC" \
      TT_CODESIFT="available" \
      TT_BACKLOG_ADDS="1" \
      TT_FAILURE_STRATEGY="halt" \
      bash "$RUNNER" >"$TMP_ROOT/fcntl_ok.$i.out" 2>"$TMP_ROOT/fcntl_ok.$i.err"
  printf '%s\n' "$?" > "$TMP_ROOT/fcntl_ok.$i.rc"
}
_i=1
while [ "$_i" -le "$FCNTL_N" ]; do
  fcntl_ok_one "$_i" &
  _i=$((_i + 1))
done
wait

FCNTL_OK_BADRC=0
_i=1
while [ "$_i" -le "$FCNTL_N" ]; do
  [ "$(cat "$TMP_ROOT/fcntl_ok.$_i.rc" 2>/dev/null || echo 99)" -eq 0 ] || FCNTL_OK_BADRC=$((FCNTL_OK_BADRC + 1))
  _i=$((_i + 1))
done

if [ "$FCNTL_OK_BADRC" -eq 0 ] && [ -f "$JSONL_FCNTL_OK" ] && python3 -c '
import json, sys
path, n = sys.argv[1], int(sys.argv[2])
lines = [l for l in open(path, encoding="utf-8").read().split("\n") if l.strip()]
recs = [json.loads(l) for l in lines]
assert len(recs) == n, "expected %d records, got %d (lost or merged appends)" % (n, len(recs))
' "$JSONL_FCNTL_OK" "$FCNTL_N" 2>"$TMP_ROOT/perr_fcntl_ok"; then
  pass "(n) fcntl importable → $FCNTL_N concurrent appends still serialise into $FCNTL_N valid JSON records — the lock path was taken"
else
  bad "(n) fcntl-present concurrency check failed: badrc=$FCNTL_OK_BADRC detail=[$(tail -3 "$TMP_ROOT/perr_fcntl_ok" 2>/dev/null | tr '\n' ' ')]"
fi

# (o) FCNTL-ABSENT: simulate a platform where `import fcntl` raises ImportError
# via a PYTHONPATH shim that shadows the real (dynamically-loaded) module with
# one that always raises — verified against this host before being wired in
# (a bare `import fcntl` under this shim raises cleanly; the real module does
# not shadow). This is the assertion that fails today against an unconditional
# `import fcntl`: the record must STILL LAND — exit 0, valid JSON, no [WARN].
SHIM_DIR="$TMP_ROOT/fcntl-shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/fcntl.py" <<'PYEOF'
raise ImportError("fcntl intentionally unavailable (portability test shim)")
PYEOF

FIX_FCNTL_NO="$TMP_ROOT/fix-fcntl-no"
JSONL_FCNTL_NO="$FIX_FCNTL_NO/context/task-telemetry.jsonl"
run_block "$FIX_FCNTL_NO" "exec-fcntl-absent" "PYTHONPATH=$SHIM_DIR"
RC_FCNTL_NO=$RC; OUT_FCNTL_NO="$OUT"; ERR_FCNTL_NO="$ERR"

if [ "$RC_FCNTL_NO" -eq 0 ] && [ -z "$OUT_FCNTL_NO" ] && [ -f "$JSONL_FCNTL_NO" ] && python3 -c '
import json, sys
rec = json.loads(open(sys.argv[1], encoding="utf-8").readline())
assert rec["task"] == 4, "unexpected task number in fcntl-absent record: %r" % (rec["task"],)
' "$JSONL_FCNTL_NO" 2>"$TMP_ROOT/perr_fcntl_no"; then
  pass "(o) fcntl unimportable (PYTHONPATH shim raising ImportError) → record STILL lands: exit 0, valid JSON, silent stdout — no [WARN]"
else
  bad "(o) fcntl-absent handling wrong: rc=$RC_FCNTL_NO out=[$OUT_FCNTL_NO] err=[$ERR_FCNTL_NO] jsonl-exists=[$([ -f "$JSONL_FCNTL_NO" ] && echo yes || echo no)] detail=[$(tail -3 "$TMP_ROOT/perr_fcntl_no" 2>/dev/null | tr '\n' ' ')]"
fi

# ── (f)(g)(m) NO-PYTHON: shadow PATH built from the fence's own deps ──────────
# A shadow dir carrying ONLY what the block legitimately needs. PATH=/nonexistent
# would also strip git and date, so the block would die on a different command and
# the assertion would pass for the wrong reason.
SHADOW="$TMP_ROOT/bin"
build_shadow "$SHADOW" no
if [ -e "$SHADOW/python3" ]; then
  bad "(f) shadow PATH precondition broken: python3 present in $SHADOW"
fi

# (m) The same shadow WITH python3 must produce a successful append. If the fence
# needs a command the dependency derivation missed, this run fails and says so,
# instead of letting the no-python3 case below pass for the wrong reason.
SHADOW_FULL="$TMP_ROOT/bin-full"
build_shadow "$SHADOW_FULL" yes
FIX_M="$TMP_ROOT/fix-m"
run_block "$FIX_M" "exec-20260802-1800" "PATH=$SHADOW_FULL"
RC_M=$RC; OUT_M="$OUT"; ERR_M="$ERR"
if [ "$RC_M" -eq 0 ] && [ -f "$FIX_M/context/task-telemetry.jsonl" ] && [ -z "$OUT_M" ]; then
  pass "(m) shadow PATH covers every command the fence actually needs (run under it succeeds silently)"
else
  bad "(m) fence needs a command the derived shadow lacks — derived=[$DEP_LIST] rc=$RC_M out=[$OUT_M] err=[$ERR_M]"
fi

FIX2="$TMP_ROOT/fix2"
run_block "$FIX2" "exec-20260802-1500" "PATH=$SHADOW"
RC_NP=$RC; OUT_NP="$OUT"; ERR_NP="$ERR"

if [ "$RC_NP" -eq 0 ]; then
  pass "(f) python3 absent → block exits 0 (never a gate)"
else
  bad "(f) python3 absent → expected exit 0, got rc=$RC_NP out=[$OUT_NP] err=[$ERR_NP]"
fi

# (g) stdout is BYTE-EXACTLY the documented line — not "contains [WARN]". A `||
# echo` bound to the wrong command, a doubled warning, or debug output appended to
# it all show up here and nowhere else.
if [ "$OUT_NP" = "$WARN_EXPECTED" ]; then
  pass "(f)(g) python3 absent → stdout is byte-exactly the documented [WARN] line, nothing else"
else
  bad "(f)(g) python3 absent → stdout != the documented [WARN] line. expected=[$WARN_EXPECTED] got=[$OUT_NP]"
fi

if printf '%s\n' "$OUT_NP" "$ERR_NP" | grep -Fq 'BLOCKED'; then
  bad "(f) python3 absent → output contains a BLOCKED token; a failed append is a WARNING, never a blocked state"
else
  pass "(f) python3 absent → no BLOCKED token anywhere in stdout/stderr"
fi

# ── (f) stub python3 exiting 127 ──────────────────────────────────────────────
# `command not found` (no such binary) and a child that EXITS 127 travel different
# code paths in bash; both must reach the same `|| echo` tail.
SHADOW2="$TMP_ROOT/bin2"
build_shadow "$SHADOW2" no
printf '#!/usr/bin/env bash\nexit 127\n' > "$SHADOW2/python3"
chmod +x "$SHADOW2/python3"

FIX3="$TMP_ROOT/fix3"
run_block "$FIX3" "exec-20260802-1600" "PATH=$SHADOW2"
RC_127=$RC; OUT_127="$OUT"; ERR_127="$ERR"

if [ "$RC_127" -eq 0 ] && [ "$OUT_127" = "$WARN_EXPECTED" ]; then
  pass "(f)(g) stub python3 exiting 127 → exit 0, stdout byte-exactly the documented [WARN] line"
else
  bad "(f)(g) stub python3 exit 127 → expected rc=0 + exactly the documented [WARN] line; got rc=$RC_127 expected=[$WARN_EXPECTED] out=[$OUT_127] err=[$ERR_127]"
fi

# A failing interpreter must not leave an artifact behind AT ALL. "Exists but is
# empty" is not the contract: a zero-byte JSONL is a file a reader must now
# tolerate, and it is exactly what a writer that opens before it validates leaves.
if [ ! -e "$FIX3/context/task-telemetry.jsonl" ]; then
  pass "(f) failing interpreter left NO telemetry file at all (not even a zero-byte one)"
else
  bad "(f) failing interpreter left a file behind: size=$(wc -c < "$FIX3/context/task-telemetry.jsonl" 2>/dev/null) content=[$(cat "$FIX3/context/task-telemetry.jsonl" 2>/dev/null)]"
fi

# ── (l) OUTPUT ROOT with ZUVO_OUTPUT_DIR UNSET ────────────────────────────────
# Every other case here sets ZUVO_OUTPUT_DIR, so the fallback branch — the one
# production actually takes — would otherwise never execute.
run_block_noenvdir() {  # $1 = cwd to run in, rest = extra env assignments
  local cwd="$1"; shift
  local o="$TMP_ROOT/stdout.nd.$$" e="$TMP_ROOT/stderr.nd.$$"
  ( cd "$cwd" && env -u ZUVO_OUTPUT_DIR "$@" \
      TT_AT="2026-08-02T10:00:00Z" \
      TT_SESSION_ID="exec-20260802-1900" \
      TT_RETRO_SESSION_ID="retro-20260802-1000" \
      TT_TASK="7" \
      TT_TASK_NAME="$ADV_NAME" \
      TT_SURFACE="integration" \
      TT_MODE="multi-agent" \
      TT_FALLBACK_PATH="none" \
      TT_WRITER_MODEL="opus" \
      TT_REVIEWER_ROUTE="review-alt" \
      TT_IMPLEMENTER_STATUS="DONE" \
      TT_SPEC_REVIEW="COMPLIANT" \
      TT_QUALITY_REVIEW="$ADV_QUALITY" \
      TT_ADVERSARIAL="PASS mode=code" \
      TT_VERIFY="$ADV_VERIFY" \
      TT_ACCEPTANCE_VERIFIED="$ADV_AC" \
      TT_CODESIFT="available" \
      TT_BACKLOG_ADDS="1" \
      TT_FAILURE_STRATEGY="halt" \
      bash "$RUNNER" ) >"$o" 2>"$e"
  RC=$?
  OUT="$(cat "$o")"; ERR="$(cat "$e")"
  rm -f "$o" "$e"
}

# (l1) inside a git repo → <git root>/zuvo/context/task-telemetry.jsonl
GITFIX="$TMP_ROOT/gitfix"
mkdir -p "$GITFIX/sub/dir"
( cd "$GITFIX" && git init -q . ) >/dev/null 2>&1 || true
if [ -d "$GITFIX/.git" ]; then
  run_block_noenvdir "$GITFIX/sub/dir"
  RC_L1=$RC; OUT_L1="$OUT"
  if [ "$RC_L1" -eq 0 ] && [ -f "$GITFIX/zuvo/context/task-telemetry.jsonl" ] && [ -z "$OUT_L1" ]; then
    pass "(l) ZUVO_OUTPUT_DIR unset → resolved <git root>/zuvo, the same root execution-state.md uses"
  else
    bad "(l) ZUVO_OUTPUT_DIR unset in a git repo → expected <git root>/zuvo/context/task-telemetry.jsonl; rc=$RC_L1 out=[$OUT_L1] found=[$(ls -R "$GITFIX" 2>&1 | tr '\n' ' ')]"
  fi
else
  bad "(l) fixture precondition broken: could not git-init $GITFIX, the unset-ZUVO_OUTPUT_DIR branch was not exercised"
fi

# (l2) no ZUVO_OUTPUT_DIR and no git root → [WARN], and NOTHING written anywhere
NOGIT="$TMP_ROOT/nogit"
mkdir -p "$NOGIT"
if ( cd "$NOGIT" && GIT_CEILING_DIRECTORIES="$TMP_ROOT" git rev-parse --show-toplevel ) >/dev/null 2>&1; then
  bad "(l) fixture precondition broken: $NOGIT resolves a git root, the unresolvable-root branch was not exercised"
else
  run_block_noenvdir "$NOGIT" "GIT_CEILING_DIRECTORIES=$TMP_ROOT"
  RC_L2=$RC; OUT_L2="$OUT"
  STRAY="$(find "$NOGIT" -name 'task-telemetry.jsonl' 2>/dev/null)"
  if [ "$RC_L2" -eq 0 ] && [ "$OUT_L2" = "$WARN_EXPECTED" ] && [ -z "$STRAY" ]; then
    pass "(l) unresolvable output root → exit 0, the documented [WARN], and nothing written to an arbitrary directory"
  else
    bad "(l) unresolvable output root mishandled: rc=$RC_L2 expected=[$WARN_EXPECTED] out=[$OUT_L2] stray=[$STRAY]"
  fi
fi

# ── (j) UNSUBSTITUTED-PLACEHOLDER DETECTION ───────────────────────────────────
# The gap this closes: if an orchestrator forgets to fill a TT_* var, the fence's
# own `${TT_X:-<placeholder>}` default still appends SUCCESSFULLY — exit 0, no
# [WARN], nothing in the suite above notices, and the bad record is only
# discoverable by eyeballing the JSONL. Prove the record is DETECTABLY wrong in
# that case, and prove a well-formed record never looks like that.
#
# In bash, `${VAR:-default}` treats VAR unset OR set-to-empty identically, so
# passing every TT_* as an EMPTY assignment reproduces "forgot to substitute"
# without needing `env -u` (whose repeated-flag behavior is not portable across
# GNU/BSD env).
run_block_bare() {  # $1 = outdir
  local outdir="$1"
  local o="$TMP_ROOT/stdout.bare.$$" e="$TMP_ROOT/stderr.bare.$$"
  env ZUVO_OUTPUT_DIR="$outdir" \
      TT_AT= TT_SESSION_ID= TT_RETRO_SESSION_ID= TT_TASK= TT_TASK_NAME= \
      TT_SURFACE= TT_MODE= TT_FALLBACK_PATH= TT_WRITER_MODEL= TT_REVIEWER_ROUTE= \
      TT_IMPLEMENTER_STATUS= TT_SPEC_REVIEW= TT_QUALITY_REVIEW= TT_ADVERSARIAL= \
      TT_VERIFY= TT_ACCEPTANCE_VERIFIED= TT_CODESIFT= TT_BACKLOG_ADDS= TT_FAILURE_STRATEGY= \
      bash "$RUNNER" >"$o" 2>"$e"
  RC=$?
  OUT="$(cat "$o")"; ERR="$(cat "$e")"
  rm -f "$o" "$e"
}

FIX4="$TMP_ROOT/fix4"
JSONL4="$FIX4/context/task-telemetry.jsonl"
run_block_bare "$FIX4"
RC4=$RC

if [ "$RC4" -eq 0 ] && [ -f "$JSONL4" ]; then
  pass "(j) unsubstituted run still exits 0 and appends (diagnostic file, never a gate)"

  # Both marker shapes are derived from the fence source itself — not hardcoded
  # here — so the assertion tracks the fence if a field's default changes:
  #   string fields: TT_X="${TT_X:-<placeholder>}"  → the visible <...> marker
  #   int fields:    TT_X="${TT_X:--1}"             → the -1 sentinel, which parses
  #                  as an int (so the record lands) yet is impossible, unlike a
  #                  plausible-looking 0.
  # A field whose OWN default is a real value (fallback-path -> "none",
  # failure-strategy -> "halt", acceptance-verified -> []) is correctly excluded:
  # those defaults are legitimate by contract, not the silent-corruption case.
  PH_OUT="$TMP_ROOT/placeholder_out.txt"
  if python3 -c '
import json, re, sys

block_path, record_path = sys.argv[1], sys.argv[2]
block = open(block_path, encoding="utf-8").read()

expected = {}
for m in re.finditer(r"^(TT_[A-Z_]+)=\"\$\{\1:-(<[a-z-]+>)\}\"", block, re.M):
    key = m.group(1)[3:].lower().replace("_", "-")
    expected[key] = m.group(2)

int_sentinels = {}
for m in re.finditer(r"^(TT_[A-Z_]+)=\"\$\{\1:--1\}\"", block, re.M):
    key = m.group(1)[3:].lower().replace("_", "-")
    int_sentinels[key] = -1

if not expected:
    print("NO-PLACEHOLDER-DEFAULTS-FOUND-IN-FENCE")
    sys.exit(1)
if not int_sentinels:
    print("NO -1 INT SENTINEL DEFAULTS FOUND IN FENCE — a numeric field defaulting to 0 "
          "is indistinguishable from a real value and must not be reintroduced")
    sys.exit(1)

rec = json.loads(open(record_path, encoding="utf-8").readline())
bad = []
for key, placeholder in sorted(expected.items()):
    if rec.get(key) != placeholder:
        bad.append("%s=%r expected %r" % (key, rec.get(key), placeholder))
for key, sentinel in sorted(int_sentinels.items()):
    val = rec.get(key)
    if not isinstance(val, int) or val != sentinel:
        bad.append("%s=%r expected the %r int sentinel" % (key, val, sentinel))

if bad:
    print("; ".join(bad))
    sys.exit(1)
print("%d placeholder-defaulted fields carry their <...> marker and %d numeric fields carry the -1 sentinel: %s | %s"
      % (len(expected), len(int_sentinels),
         ",".join(sorted(expected)), ",".join(sorted(int_sentinels))))
' "$RUNNER" "$JSONL4" >"$PH_OUT" 2>&1; then
    pass "(j) $(cat "$PH_OUT")"
  else
    bad "(j) unsubstituted record did not carry its documented markers: $(cat "$PH_OUT")"
  fi
else
  bad "(j) unsubstituted run expected exit 0 + $JSONL4 to exist; got rc=$RC4 out=[$OUT] err=[$ERR]"
  skipped "(j) placeholder/sentinel markers on the unsubstituted record"
fi

# The other half of the same assertion: a WELL-FORMED record (JSONL1, fully
# substituted with adversarial values earlier) must carry NO `<...>`-shaped value
# and NO `-1` in a sentinel-bearing numeric field — this is the check that would
# have caught the silent case if it had fired against real telemetry.
if [ -f "$JSONL1" ]; then
  WF_OUT="$TMP_ROOT/wellformed_out.txt"
  if python3 -c '
import json, re, sys
rec = json.loads(open(sys.argv[1], encoding="utf-8").readline())
placeholder_re = re.compile(r"<[a-z][a-z-]*>")
bad = []
for k, v in rec.items():
    if isinstance(v, str) and placeholder_re.search(v):
        bad.append("%s=%r" % (k, v))
    elif isinstance(v, bool):
        continue
    elif isinstance(v, int) and v == -1:
        bad.append("%s=-1 (unsubstituted int sentinel in a well-formed record)" % k)
    elif isinstance(v, list):
        for item in v:
            if isinstance(item, str) and placeholder_re.search(item):
                bad.append("%s[]=%r" % (k, item))
if bad:
    print("; ".join(bad))
    sys.exit(1)
print("well-formed record carries no <...> placeholder and no -1 sentinel in any field")
' "$JSONL1" >"$WF_OUT" 2>&1; then
    pass "(j) $(cat "$WF_OUT")"
  else
    bad "(j) well-formed record unexpectedly contains an unsubstituted marker: $(cat "$WF_OUT")"
  fi
else
  skipped "(j) well-formed record carries no unsubstituted marker — $JSONL1 was never created"
fi

# ── (h) PURITY ────────────────────────────────────────────────────────────────
GIT_AFTER="$( (cd "$ROOT" && git status --porcelain) 2>/dev/null )"
if [ "$GIT_BEFORE" = "$GIT_AFTER" ]; then
  pass "(h) repo working tree unchanged by test run"
else
  bad "(h) test mutated the repo — before=[$GIT_BEFORE] after=[$GIT_AFTER]"
fi

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "ALL PASSED"
  exit 0
else
  echo "SOME FAILED"
  exit 1
fi
