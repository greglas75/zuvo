#!/usr/bin/env bash
# test-task-telemetry-contract.sh — Task 4: per-task telemetry persistence.
# Test level: MEDIUM — the real fenced SKILL.md block, the router and the retro readers as
# subprocesses in temp dirs, plus document-vs-code contract checks; no network, no model CLI.
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
# Task 5 extends this suite to the READER side: `# >>> zuvo:retro-telemetry` in
# skills/retro/SKILL.md ("Phase 3b: Per-Task Telemetry"), which consumes the file
# this suite's writer cases above already pin. A bare `grep '^## Phase 3b'` would
# pass on any prose heading, so these cases instead extract and EXECUTE the fence
# against fixtures, exactly like the writer cases do:
#   (p) AGGREGATE   — a 3-record fixture (2 DONE/COMPLIANT/PASS, 1 BLOCKED/ISSUES
#                     FOUND/FAIL) yields the exact expected gate-failure counts,
#                     reviewer-route distribution, and implementer-status tally —
#                     asserted as an exact string, not "produced some output".
#   (q) SKIP-COUNT  — a fixture whose 2nd line is malformed JSON does not crash:
#                     the other two records are still aggregated, the skipped-line
#                     count is reported (skipped=1), and stderr is empty (no
#                     traceback for what the Reader Contract in session-state.md
#                     calls an expected, not exceptional, condition).
#   (r) MISSING     — a non-existent telemetry file prints the documented
#                     "No per-task telemetry found." note, byte-exact, and exits 0.
#   (s) ENUM        — a fixture carrying all three documented `failure-strategy`
#                     shapes (`halt`, `skip-and-continue`, `degraded:<desc>`) is
#                     tallied — `halt` and `skip-and-continue` under their exact
#                     keys, `degraded:<desc>` under the bucketed `degraded` key
#                     plus `degraded-distinct-descriptions=<N>` (see (x)).
#
# (q) alone did NOT cover the Reader Contract's own threat model: its only
# malformed line is plain ASCII garbage, which `except ValueError` around
# `json.loads` catches. The two corruption shapes that actually occur crash
# OUTSIDE such a guard, fall through to the coarse shell-level `|| echo`, and
# discard every record already parsed — uncounted in BOTH `records=` and
# `skipped=`, which is the silent data loss session-state.md forbids by name.
# Hence:
#   (t) NON-OBJECT  — `null`, a bare number and `[]` are VALID JSON that parse
#                     fine and then raise AttributeError at the first `.get`.
#                     Each must be a COUNTED skip; the surrounding records must
#                     still aggregate; exit 0; stderr empty.
#   (u) UTF8-TRUNC  — a record truncated mid em-dash: the exact "crash between
#                     write and fsync" case session-state.md names by example,
#                     and em-dashes are explicitly permitted in `task-name`. A
#                     text-mode `for raw in fh` decodes EAGERLY, so this raises
#                     UnicodeDecodeError from the ITERATION, before any per-line
#                     try is entered. Must be a COUNTED skip, not a fatal.
#   (v) NO-STRATEGY — a record with NO `failure-strategy` must NOT be tallied as
#                     `halt`. The writer always emits the field, so absence means
#                     an old or corrupt record; folding it into `halt` reports
#                     silence as a deliberate decision. `missing` is its own
#                     bucket, and a value outside the documented set is `unknown`.
#   (w) UNREADABLE  — an existing-but-unreadable file is handled INSIDE python: a
#                     specific unreadable-path message plus `records=0 skipped=0`,
#                     exit 0, empty stdout-only shape. Relying on the shell `||
#                     echo` here would report nothing about which path failed.
#   (x) DEGRADED    — `degraded:<desc>` is free text; one tally key per distinct
#                     description yields one entry per task and no signal on a
#                     long run. Several distinct descriptions must collapse to a
#                     single `degraded=<N>` with `degraded-distinct-descriptions`
#                     alongside.
#   (ab) MISSING-GATE — a record with NO spec-review/quality-review/adversarial
#                     keys at all must land in `gate-missing=`, never `gate-
#                     failures=`. Absence is not a declared failure.
#   (ac) NONSTRING-GATE — a JSON bool/int/object gate value (str(True)=="True",
#                     str(3)=="3") is malformed input, not a verdict, and must
#                     also land in `gate-missing=`, never get stringified into a
#                     passing or failing comparison.
#   (ad) CASE-SENSITIVE — a lowercased/mixed-case "pass ..." value must count as
#                     a gate FAILURE, pinning the deliberate case-sensitive
#                     `PASS`-prefix contract as a regression guard.
#   (ae) DEGRADED-CAP — 70 records with 70 DISTINCT `degraded:<desc>` tails must
#                     cap the tracked set at `DEGRADED_DESC_CAP` and report the
#                     remainder as an approximate `(+N more)` overflow, never
#                     grow the tracked set without bound.
#   (af) BLANK-LINE — a blank line and a whitespace-only line between two real
#                     records must count toward NEITHER `records=` nor
#                     `skipped=` — the ordinary trailing newline of an
#                     append-only file is not a record to begin with.
#   (y) READER SSOT — the reader's field-name literals are checked against the
#                     `zuvo:telemetry-schema` table, the same discipline the
#                     WRITER's `K = [...]` already follows. CONTAINMENT, not the
#                     writer's equality diff: the reader legitimately touches a
#                     SUBSET of the documented keys (6 of 19), so equality would
#                     be permanently red. `.get(key, default)` never raises on a
#                     renamed key, so without this a schema rename would make
#                     retro report 100% gate failure FOREVER, undetected. Also
#                     forbids an inline `.get("<key>"` literal, which would
#                     bypass the check.
#   (ag) ROUTE VOCABULARY — plan C Task 2 (docs/specs/2026-09-25-cross-vendor-
#                     reviewer-routing-plan.md). The router (scripts/reviewer-model-
#                     route.sh) gained lane `cross-vendor`, statuses `cross-vendor-
#                     unavailable` / `in-family-fallback` and a `--fallback` flag, so
#                     every consumer that names its vocabulary must say the same:
#                     the `reviewer-route` telemetry enum is EXACTLY the six values in
#                     $ROUTE_ENUM in session-state.md, execute/SKILL.md and the retro
#                     tally (and the retro reader counts each). The router's vocabulary
#                     is taken by RUNNING it over a matrix (every host, actual writer
#                     ids, client present/missing, --fallback, fail-closed, same-model
#                     and override paths); a source regex only cross-checks the matrix.
#                     Against those runs: env-compat.md's lane and status lists (two-
#                     way), its decision table (each answer is exactly one row matched
#                     on the ACTUAL writer id; every row is an answer), session-state's
#                     reviewer-route mapping (total, ok -> lane, degraded never clean),
#                     test-reviewer-routing.md Step 4 (per-row, only --fallback's
#                     statuses) and its Reviewer routing: template; Step 3.5's and
#                     Step 4's same-model rules and their stated reason; write-tests
#                     Step 5's serialized `:possibly-same-model` values.
#                     (retrospective.md field 17 + append-retro are pinned in
#                     tests/adversarial/test-append-retro-contract.sh.)
#   (z) NO-PYTHON   — mirrors the writer's (f)/(m) groups on the READER fence's
#     (reader)        own `|| echo "[WARN] per-task telemetry read failed …"`
#                     tail: a shadow PATH built from the reader fence's OWN
#                     derived command dependencies (git, python3 — python3
#                     omitted) reaches that fallback with NO fixture mutation,
#                     exactly like the writer's shadow-PATH technique. This
#                     closes a gap a prior round left open by conflating two
#                     different claims: that no fixture can reach the fallback
#                     (false — this group is the counter-proof) with the
#                     narrower, true claim that no DATA fixture can make python
#                     exit non-zero mid-loop (the exhaustive `except Exception`
#                     plus the unconditional `emit()`/`sys.exit(0)` make THAT
#                     path unreachable by design). Also covers the stub-python3-
#                     exits-127 variant, same discipline as the writer's (f).
# Every reader fixture sets ZUVO_OUTPUT_DIR explicitly (same pattern as run_block
# above), so none of it depends on `git rev-parse --show-toplevel` succeeding.
# Each new group asserts the EXACT `records=`/`skipped=` numbers, exit 0 and empty
# stderr — a reader that silently swallows is the failure mode here, so "it did
# not crash" is not an assertion.
#
# awk-fence extraction + hermetic-runner idiom from tests/skill-suite/test-dev-push-gate.sh.
# bash 3.2-compatible (macOS default): no mapfile, no associative arrays.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/skills/execute/SKILL.md"
STATE_DOC="$ROOT/shared/includes/session-state.md"
RETRO_SKILL="$ROOT/skills/retro/SKILL.md"
FENCE='zuvo:task-telemetry'
RETRO_FENCE='zuvo:retro-telemetry'
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
if [ ! -f "$RETRO_SKILL" ]; then
  bad "skills/retro/SKILL.md not found at $RETRO_SKILL"
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
# The capture is `[^"]*` (up to the CLOSING quote), not `.*` anchored at
# end-of-line: the tail legitimately carries a trailing `|| true` so that a
# failure of `echo` ITSELF cannot make the compound return non-zero. An
# end-anchored `.*"` stopped matching the moment that guard was added and
# silently produced an EMPTY expectation — which then made every WARN-path
# assertion below compare stdout against "", i.e. fail loudly rather than pass
# vacuously. Keeping the message capture quote-delimited decouples it from
# whatever follows the closing quote.
WARN_COUNT="$(printf '%s\n' "$BLOCK" | grep -c '^[[:space:]]*|| echo "\[WARN\]')"
WARN_EXPECTED="$(printf '%s\n' "$BLOCK" \
  | sed -n 's/^[[:space:]]*|| echo "\(\[WARN\][^"]*\)".*$/\1/p')"
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

# build_shadow <dir> <include-python3: yes|no> [deps-file, default $FENCE_DEPS]
# The deps-file parameter lets the same builder serve a DIFFERENT fence's derived
# dependency set (the reader fence's (z) group below) without hand-duplicating
# this function against a second hardcoded list.
build_shadow() {
  local dir="$1" want_py="$2" deps="${3:-$FENCE_DEPS}" t p
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
  done < "$deps"
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

# ══════════════════════════════════════════════════════════════════════════════
# Task 5 — READER: `# >>> zuvo:retro-telemetry` in skills/retro/SKILL.md
# ══════════════════════════════════════════════════════════════════════════════

# ── fence markers: EXACTLY ONE PAIR, correctly ordered ────────────────────────
RETRO_PAIR="$(fence_pair "$RETRO_FENCE" "$RETRO_SKILL")" || true
RF_START="$(printf '%s' "$RETRO_PAIR" | grep -E '^[0-9]+ [0-9]+$' | cut -d' ' -f1)"
RF_END="$(printf '%s' "$RETRO_PAIR" | grep -E '^[0-9]+ [0-9]+$' | cut -d' ' -f2)"

if [ -n "$RF_START" ] && [ -n "$RF_END" ]; then
  pass "fenced $RETRO_FENCE block present, exactly one >>>/<<< pair (lines $RF_START/$RF_END)"
else
  bad "fenced $RETRO_FENCE block MISSING or not exactly one >>>/<<< pair — fence_pair said [$RETRO_PAIR]"
fi

# ── placement: strictly between the Phase 3 and Phase 4 headings. This is a
# structural sanity check, NOT the verification for this task — a heading grep
# alone (`grep '^## Phase 3b'`) would pass on prose with no working fence, which
# is exactly what the executable cases below actually prove.
P3_LINE="$(grep -nF '## Phase 3: Skill Usage Trends' "$RETRO_SKILL" | head -1 | cut -d: -f1)"
P4_LINE="$(grep -nF '## Phase 4: Actionable Items' "$RETRO_SKILL" | head -1 | cut -d: -f1)"
if [ -n "$RF_START" ] && [ -n "$P3_LINE" ] && [ -n "$P4_LINE" ] \
   && [ "$RF_START" -gt "$P3_LINE" ] && [ "$RF_END" -lt "$P4_LINE" ]; then
  pass "fence ($RF_START-$RF_END) lies between Phase 3 ($P3_LINE) and Phase 4 ($P4_LINE) — 4/5/6 not renumbered"
else
  bad "fence must sit between Phase 3 and Phase 4: got fence=$RF_START-$RF_END phase3=$P3_LINE phase4=$P4_LINE"
fi

if [ -z "$RF_START" ] || [ -z "$RF_END" ] || [ "$RF_END" -le "$RF_START" ]; then
  bad "retro-telemetry fence markers absent/misordered (>>> '$RF_START' <<< '$RF_END') — refusing block extraction/execution"
  echo "----"; echo "SOME FAILED"; exit 1
fi

RETRO_BLOCK="$(awk -v s="# >>> $RETRO_FENCE" -v e="# <<< $RETRO_FENCE" \
  'index($0,s){f=1;next} index($0,e){exit} f{print}' "$RETRO_SKILL")"

if [ -z "$RETRO_BLOCK" ]; then
  bad "extracted $RETRO_FENCE block is EMPTY"
  echo "----"; echo "SOME FAILED"; exit 1
fi

# ── the documented missing-file note, derived from the fence (never hardcoded) ─
RETRO_NOTE_COUNT="$(printf '%s\n' "$RETRO_BLOCK" | grep -c '^[[:space:]]*echo "No per-task telemetry found\."$')"
RETRO_NOTE="$(printf '%s\n' "$RETRO_BLOCK" \
  | sed -n 's/^[[:space:]]*echo "\(No per-task telemetry found\.\)"[[:space:]]*$/\1/p')"
if [ "$RETRO_NOTE_COUNT" -eq 1 ] && [ -n "$RETRO_NOTE" ]; then
  pass "(r) fence carries exactly one missing-file echo; expected note derived from it: [$RETRO_NOTE]"
else
  bad "(r) expected exactly one missing-file echo in the fence; found $RETRO_NOTE_COUNT, parsed [$RETRO_NOTE]"
fi

RETRO_RUNNER="$TMP_ROOT/retro-runner.sh"
{
  printf '%s\n' "$SET_OPTS"
  printf '%s\n' "$RETRO_BLOCK"
} > "$RETRO_RUNNER"

# run_retro <outdir> [extra env assignments...] — ZUVO_OUTPUT_DIR IS the zuvo dir
# directly (report-output-location.md convention, same as run_block above), so
# the file the fence reads lives at <outdir>/context/task-telemetry.jsonl. Extra
# args (e.g. "PATH=$SHADOW") are forwarded to `env`, same shape as run_block's
# trailing "$@" — this is what lets the (z) group below run the reader fence
# under a shadow PATH without a second bespoke runner.
run_retro() {
  local outdir="$1"; shift
  local o="$TMP_ROOT/retro.stdout.$$" e="$TMP_ROOT/retro.stderr.$$"
  env ZUVO_OUTPUT_DIR="$outdir" "$@" bash "$RETRO_RUNNER" >"$o" 2>"$e"
  RC=$?
  OUT="$(cat "$o")"; ERR="$(cat "$e")"
  rm -f "$o" "$e"
}

# ── (p) AGGREGATE: 3 well-formed records → exact deterministic aggregate ──────
# Also doubles as (s) ENUM: all three documented failure-strategy shapes appear
# in this one fixture (halt, skip-and-continue, degraded:<desc>).
FIXP="$TMP_ROOT/retro-fixp"
mkdir -p "$FIXP/context"
cat > "$FIXP/context/task-telemetry.jsonl" <<'JSONL'
{"at":"2026-08-02T10:00:00Z","session-id":"exec-1","retro-session-id":"retro-1","task":1,"task-name":"A","surface":"api","mode":"multi-agent","fallback-path":"none","writer-model":"opus","reviewer-route":"review-primary","implementer-status":"DONE","spec-review":"COMPLIANT","quality-review":"PASS cq=1/1","adversarial":"PASS mode=code","verify":"x exit=0","acceptance-verified":[],"codesift":"available","backlog-adds":0,"failure-strategy":"halt"}
{"at":"2026-08-02T10:01:00Z","session-id":"exec-1","retro-session-id":"retro-1","task":2,"task-name":"B","surface":"api","mode":"multi-agent","fallback-path":"none","writer-model":"opus","reviewer-route":"review-alt","implementer-status":"BLOCKED","spec-review":"ISSUES FOUND","quality-review":"FAIL cq=0/1","adversarial":"FAIL mode=code","verify":"x exit=1","acceptance-verified":[],"codesift":"available","backlog-adds":0,"failure-strategy":"skip-and-continue"}
{"at":"2026-08-02T10:02:00Z","session-id":"exec-1","retro-session-id":"retro-1","task":3,"task-name":"C","surface":"api","mode":"multi-agent","fallback-path":"none","writer-model":"opus","reviewer-route":"review-primary","implementer-status":"DONE","spec-review":"COMPLIANT","quality-review":"PASS cq=1/1","adversarial":"PASS mode=code","verify":"x exit=0","acceptance-verified":[],"codesift":"available","backlog-adds":0,"failure-strategy":"degraded:no-agents"}
JSONL

EXPECTED_P='records=3 skipped=0
gate-failures spec-review=1 quality-review=1 adversarial=1
gate-missing spec-review=0 quality-review=0 adversarial=0
reviewer-route legacy:review-alt=1 legacy:review-primary=2
implementer-status BLOCKED=1 DONE=2
failure-strategy degraded=1 halt=1 skip-and-continue=1 degraded-distinct-descriptions=1'

run_retro "$FIXP"
RC_P=$RC; OUT_P="$OUT"; ERR_P="$ERR"

if [ "$RC_P" -eq 0 ] && [ "$OUT_P" = "$EXPECTED_P" ]; then
  pass "(p) 3-record fixture yields the exact deterministic aggregate (gate-failures, reviewer-route, implementer-status)"
else
  bad "(p) aggregate mismatch: rc=$RC_P expected=[$EXPECTED_P] got=[$OUT_P] stderr=[$ERR_P]"
fi

if [ "$RC_P" -eq 0 ] && [ -z "$ERR_P" ]; then
  pass "(p) well-formed aggregate wrote nothing to stderr"
else
  bad "(p) well-formed aggregate wrote to stderr (expected none): rc=$RC_P [$ERR_P]"
fi

# (s) All three documented shapes present and distinguishable. `degraded:<desc>`
# is deliberately BUCKETED (see (x)) — the assertion is that it is neither dropped
# nor merged into another bucket, not that its free text becomes a tally key.
if [ "$RC_P" -eq 0 ] && printf '%s' "$OUT_P" | grep -qF 'failure-strategy degraded=1 halt=1 skip-and-continue=1 degraded-distinct-descriptions=1'; then
  pass "(s) all three documented failure-strategy shapes tallied distinctly (halt, skip-and-continue, and the bucketed degraded + its distinct-description count)"
else
  bad "(s) failure-strategy distribution missing/merging one of the three documented shapes: got=[$OUT_P]"
fi

# ── (q) SKIP-COUNT: 2nd line malformed JSON does not crash ────────────────────
FIXQ="$TMP_ROOT/retro-fixq"
mkdir -p "$FIXQ/context"
cat > "$FIXQ/context/task-telemetry.jsonl" <<'JSONL'
{"at":"2026-08-02T10:00:00Z","session-id":"exec-1","retro-session-id":"retro-1","task":1,"task-name":"A","surface":"api","mode":"multi-agent","fallback-path":"none","writer-model":"opus","reviewer-route":"review-primary","implementer-status":"DONE","spec-review":"COMPLIANT","quality-review":"PASS cq=1/1","adversarial":"PASS mode=code","verify":"x exit=0","acceptance-verified":[],"codesift":"available","backlog-adds":0,"failure-strategy":"halt"}
{this line is not valid JSON at all
{"at":"2026-08-02T10:02:00Z","session-id":"exec-1","retro-session-id":"retro-1","task":3,"task-name":"C","surface":"api","mode":"multi-agent","fallback-path":"none","writer-model":"opus","reviewer-route":"review-primary","implementer-status":"DONE","spec-review":"COMPLIANT","quality-review":"PASS cq=1/1","adversarial":"PASS mode=code","verify":"x exit=0","acceptance-verified":[],"codesift":"available","backlog-adds":0,"failure-strategy":"halt"}
JSONL

EXPECTED_Q='records=2 skipped=1
gate-failures spec-review=0 quality-review=0 adversarial=0
gate-missing spec-review=0 quality-review=0 adversarial=0
reviewer-route legacy:review-primary=2
implementer-status DONE=2
failure-strategy halt=2'

run_retro "$FIXQ"
RC_Q=$RC; OUT_Q="$OUT"; ERR_Q="$ERR"

if [ "$RC_Q" -eq 0 ] && [ "$OUT_Q" = "$EXPECTED_Q" ]; then
  pass "(q) malformed 2nd line skipped — other 2 records still aggregated, skipped count reported (skipped=1)"
else
  bad "(q) skip-and-count mismatch: rc=$RC_Q expected=[$EXPECTED_Q] got=[$OUT_Q] stderr=[$ERR_Q]"
fi

if [ -z "$ERR_Q" ]; then
  pass "(q) no traceback on stderr for the malformed-line case"
else
  bad "(q) malformed-line case wrote to stderr (expected none): [$ERR_Q]"
fi

# ── (r) MISSING: non-existent telemetry file → the documented note, exit 0 ────
FIXR="$TMP_ROOT/retro-fixr"
mkdir -p "$FIXR"
if [ -e "$FIXR/context/task-telemetry.jsonl" ]; then
  bad "(r) fixture precondition broken: telemetry file already exists at $FIXR"
fi
run_retro "$FIXR"
RC_R=$RC; OUT_R="$OUT"; ERR_R="$ERR"

if [ "$RC_R" -eq 0 ] && [ "$OUT_R" = "$RETRO_NOTE" ] && [ -z "$ERR_R" ]; then
  pass "(r) missing telemetry file → exit 0, stdout is byte-exactly the documented note, no stderr"
else
  bad "(r) missing-file handling wrong: rc=$RC_R expected=[$RETRO_NOTE] got=[$OUT_R] stderr=[$ERR_R]"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Task 5 fix round — the corruption shapes (q) never covered, plus the reader's
# own schema SSOT. (q)'s single malformed line is plain ASCII garbage, which any
# `except ValueError` around `json.loads` catches; the shapes below crash OUTSIDE
# such a guard and discard every record already parsed.
# ══════════════════════════════════════════════════════════════════════════════

# One well-formed record generator, so each group below differs ONLY in the field
# under test. Hand-copying a 19-key JSON line per group is how a fixture ends up
# silently asserting something other than its comment claims.
#   $1 = task number
#   $2 = the `failure-strategy` fragment, spliced in verbatim. EMPTY omits the key
#        entirely — that is the (v) case, and it must stay expressible.
retro_rec() {
  printf '{"at":"2026-08-02T10:00:00Z","session-id":"exec-1","retro-session-id":"retro-1","task":%s,"task-name":"T%s","surface":"api","mode":"multi-agent","fallback-path":"none","writer-model":"opus","reviewer-route":"review-primary","implementer-status":"DONE","spec-review":"COMPLIANT","quality-review":"PASS cq=1/1","adversarial":"PASS mode=code","verify":"x exit=0","acceptance-verified":[],"codesift":"available","backlog-adds":0%s}\n' \
    "$1" "$1" "$2"
}

# Sanity-check the generator itself before five groups depend on it. A fixture
# builder that emits an unparseable line would make every group below report the
# reader's skip path while the comments claim it is exercising something else.
if printf '%s' "$(retro_rec 1 ',"failure-strategy":"halt"')" \
   | python3 -c 'import json,sys; r=json.loads(sys.stdin.read()); sys.exit(0 if r["failure-strategy"]=="halt" and r["task"]==1 else 1)' 2>/dev/null \
   && printf '%s' "$(retro_rec 2 '')" \
   | python3 -c 'import json,sys; r=json.loads(sys.stdin.read()); sys.exit(0 if "failure-strategy" not in r else 1)' 2>/dev/null; then
  pass "(t-x) fixture generator emits valid records and can genuinely OMIT failure-strategy"
else
  bad "(t-x) fixture generator is broken — the groups below would assert against malformed input"
fi

# ── (t) NON-OBJECT: valid JSON that is not an object ──────────────────────────
# `null`, a bare number and `[]` all parse fine, then raise AttributeError at the
# first `.get`. Each must be a COUNTED skip and the surrounding records must still
# aggregate — the whole per-line body has to be guarded, not just the parse.
FIXT="$TMP_ROOT/retro-fixt"
mkdir -p "$FIXT/context"
{
  retro_rec 1 ',"failure-strategy":"halt"'
  printf 'null\n'
  printf '3\n'
  printf '[]\n'
  retro_rec 2 ',"failure-strategy":"halt"'
} > "$FIXT/context/task-telemetry.jsonl"

EXPECTED_T='records=2 skipped=3
gate-failures spec-review=0 quality-review=0 adversarial=0
gate-missing spec-review=0 quality-review=0 adversarial=0
reviewer-route legacy:review-primary=2
implementer-status DONE=2
failure-strategy halt=2'

run_retro "$FIXT"
RC_T=$RC; OUT_T="$OUT"; ERR_T="$ERR"

if [ "$RC_T" -eq 0 ] && [ "$OUT_T" = "$EXPECTED_T" ] && [ -z "$ERR_T" ]; then
  pass "(t) null / bare number / [] are each a COUNTED skip (records=2 skipped=3), surrounding records still aggregate, exit 0, empty stderr"
else
  bad "(t) non-object lines mishandled: rc=$RC_T expected=[$EXPECTED_T] got=[$OUT_T] stderr=[$ERR_T]"
fi

# ── (u) UTF8-TRUNC: a record truncated mid em-dash ────────────────────────────
# The exact "crash between write and fsync" case. Text mode decodes EAGERLY, so
# `for raw in fh` raises UnicodeDecodeError from the ITERATION — before any
# per-line try is entered — and kills the read after records were already counted.
# Em-dashes are explicitly permitted in `task-name`, so this is a real record
# shape, not a synthetic byte soup.
FIXU="$TMP_ROOT/retro-fixu"
mkdir -p "$FIXU/context"
{
  retro_rec 1 ',"failure-strategy":"halt"'
  retro_rec 2 ',"failure-strategy":"halt"'
  # 0xE2 0x80 = the first TWO bytes of U+2014 EM DASH (0xE2 0x80 0x94). The third
  # byte is the one the kill took with it.
  printf '{"at":"2026-08-02T10:02:00Z","task-name":"Tenant hardening \xe2\x80'
} > "$FIXU/context/task-telemetry.jsonl"

# LOUD precondition: if this host's printf did not emit the raw bytes, the file is
# valid UTF-8 and the group would pass for the wrong reason (it would be testing
# (q)'s ASCII-garbage path again).
if python3 -c '
import sys
data = open(sys.argv[1], "rb").read()
tail = data.rsplit(b"\n", 1)[-1]
assert tail.endswith(b"\xe2\x80"), "fixture tail is not the truncated em-dash prefix: %r" % (tail[-8:],)
try:
    data.decode("utf-8")
except UnicodeDecodeError:
    sys.exit(0)
raise SystemExit("fixture decodes as valid UTF-8 — the truncation was not written")
' "$FIXU/context/task-telemetry.jsonl" 2>"$TMP_ROOT/perr_u"; then
  pass "(u) fixture precondition: trailing record really is truncated mid em-dash and the file is NOT valid UTF-8"

  EXPECTED_U='records=2 skipped=1
gate-failures spec-review=0 quality-review=0 adversarial=0
gate-missing spec-review=0 quality-review=0 adversarial=0
reviewer-route legacy:review-primary=2
implementer-status DONE=2
failure-strategy halt=2'

  run_retro "$FIXU"
  RC_U=$RC; OUT_U="$OUT"; ERR_U="$ERR"

  if [ "$RC_U" -eq 0 ] && [ "$OUT_U" = "$EXPECTED_U" ] && [ -z "$ERR_U" ]; then
    pass "(u) truncated multi-byte UTF-8 tail is a COUNTED skip (records=2 skipped=1) — the two records before it survive, exit 0, empty stderr"
  else
    bad "(u) truncated UTF-8 tail mishandled: rc=$RC_U expected=[$EXPECTED_U] got=[$OUT_U] stderr=[$ERR_U]"
  fi
else
  bad "(u) fixture precondition broken: $(tail -2 "$TMP_ROOT/perr_u" | tr '\n' ' ')"
  skipped "(u) truncated multi-byte UTF-8 tail is a counted skip"
fi

# ── (v) NO-STRATEGY: absence is `missing`, never `halt` ───────────────────────
# The writer ALWAYS emits failure-strategy, so an absent one means an old or
# corrupt record. Folding it into `halt` reports silence as a deliberate decision.
# A null value is the same shape (no declared strategy); a value outside the
# documented set is `unknown`.
FIXV="$TMP_ROOT/retro-fixv"
mkdir -p "$FIXV/context"
{
  retro_rec 1 ',"failure-strategy":"halt"'
  retro_rec 2 ''
  retro_rec 3 ',"failure-strategy":"retry-forever"'
  retro_rec 4 ',"failure-strategy":null'
} > "$FIXV/context/task-telemetry.jsonl"

EXPECTED_V='records=4 skipped=0
gate-failures spec-review=0 quality-review=0 adversarial=0
gate-missing spec-review=0 quality-review=0 adversarial=0
reviewer-route legacy:review-primary=4
implementer-status DONE=4
failure-strategy halt=1 missing=2 unknown=1'

run_retro "$FIXV"
RC_V=$RC; OUT_V="$OUT"; ERR_V="$ERR"

if [ "$RC_V" -eq 0 ] && [ "$OUT_V" = "$EXPECTED_V" ] && [ -z "$ERR_V" ]; then
  pass "(v) absent/null failure-strategy lands in the missing bucket (2) and an undocumented value in unknown (1) — halt stays at the ONE record that declared it"
else
  bad "(v) failure-strategy default mishandled: rc=$RC_V expected=[$EXPECTED_V] got=[$OUT_V] stderr=[$ERR_V]"
fi

# The same claim stated as the regression it guards: `halt=3` here would mean two
# silent records were reported as a deliberate halt.
if printf '%s' "$OUT_V" | grep -q 'failure-strategy .*halt=1' \
   && ! printf '%s' "$OUT_V" | grep -q 'halt=[234]'; then
  pass "(v) the two strategy-less records were NOT absorbed into the halt bucket"
else
  bad "(v) strategy-less records folded into halt — silence reported as a decision: got=[$OUT_V]"
fi

# ── (w) UNREADABLE: handled INSIDE python, not by the shell `|| echo` ─────────
# The expected message is derived from the fence (same discipline as $RETRO_NOTE
# and $WARN_EXPECTED), so it cannot drift into a hardcoded copy here.
RETRO_UNREADABLE_FMT="$(printf '%s\n' "$RETRO_BLOCK" \
  | sed -n 's/^[[:space:]]*print("\(per-task telemetry unreadable .*\)" % (exc,))[[:space:]]*$/\1/p')"
RETRO_ZERO_LINE="$(printf '%s\n' "$RETRO_BLOCK" \
  | sed -n 's/^[[:space:]]*print("\(records=0 skipped=0\)")[[:space:]]*$/\1/p')"

if [ -n "$RETRO_UNREADABLE_FMT" ] && [ -n "$RETRO_ZERO_LINE" ]; then
  pass "(w) fence carries an in-python unreadable-path message and a zero-count line; expected shape derived from it: [$RETRO_UNREADABLE_FMT] + [$RETRO_ZERO_LINE]"
else
  bad "(w) fence does not handle open() itself — expected a print(\"per-task telemetry unreadable …\" % (exc,)) plus a records=0 line; parsed fmt=[$RETRO_UNREADABLE_FMT] zero=[$RETRO_ZERO_LINE]"
fi

FIXW="$TMP_ROOT/retro-fixw"
mkdir -p "$FIXW/context"
retro_rec 1 ',"failure-strategy":"halt"' > "$FIXW/context/task-telemetry.jsonl"
chmod 000 "$FIXW/context/task-telemetry.jsonl"

# LOUD precondition: running as root (or on a filesystem ignoring the mode) makes
# the file readable anyway, and the group would silently test the happy path.
if [ -r "$FIXW/context/task-telemetry.jsonl" ] || cat "$FIXW/context/task-telemetry.jsonl" >/dev/null 2>&1; then
  bad "(w) fixture precondition broken: chmod 000 file is still readable (running as root?) — the unreadable branch was not exercised"
  skipped "(w) unreadable path is handled inside python with its counts intact"
elif [ -z "$RETRO_UNREADABLE_FMT" ] || [ -z "$RETRO_ZERO_LINE" ]; then
  skipped "(w) unreadable path shape — the expected message could not be derived from the fence"
else
  run_retro "$FIXW"
  RC_W=$RC; OUT_W="$OUT"; ERR_W="$ERR"

  W_OUT="$TMP_ROOT/retro_w_out.txt"
  if python3 -c '
import sys
got, fmt, zero, path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lines = got.split("\n")
assert len(lines) == 2, "expected exactly 2 stdout lines, got %d: %r" % (len(lines), lines)
head, tail = fmt.split("%s", 1)
assert lines[0].startswith(head), "line 1 does not start with the fence message: %r" % (lines[0],)
assert lines[0].endswith(tail), "line 1 does not end with the fence message: %r" % (lines[0],)
assert path in lines[0], "line 1 never names the path that failed: %r" % (lines[0],)
assert lines[1] == zero, "line 2 must be the zero-count line %r, got %r" % (zero, lines[1])
print("in-python unreadable handling: names the path, reports %r, no shell fallback" % (zero,))
' "$OUT_W" "$RETRO_UNREADABLE_FMT" "$RETRO_ZERO_LINE" "$FIXW/context/task-telemetry.jsonl" >"$W_OUT" 2>&1 \
     && [ "$RC_W" -eq 0 ] && [ -z "$ERR_W" ]; then
    pass "(w) $(cat "$W_OUT") (exit 0, empty stderr)"
  else
    bad "(w) unreadable file mishandled: rc=$RC_W stderr=[$ERR_W] got=[$OUT_W] detail=[$(tail -2 "$W_OUT" 2>/dev/null | tr '\n' ' ')]"
  fi
fi
chmod 644 "$FIXW/context/task-telemetry.jsonl" 2>/dev/null || true

# ── (x) DEGRADED: free-text descriptions must not become tally keys ───────────
# `degraded:<desc>` is free text. Keying the tally by it yields one entry per task
# on a long run — a distribution with no signal. The bucket collapses to a single
# `degraded` count with the distinct-description count alongside.
FIXX="$TMP_ROOT/retro-fixx"
mkdir -p "$FIXX/context"
{
  retro_rec 1 ',"failure-strategy":"degraded:no-agents"'
  retro_rec 2 ',"failure-strategy":"degraded:rate-limited"'
  retro_rec 3 ',"failure-strategy":"degraded:no-agents"'
  # A description carrying a comma and spaces: whatever the tally does with it
  # must not depend on its punctuation.
  retro_rec 4 ',"failure-strategy":"degraded:codesift missing, index stale"'
} > "$FIXX/context/task-telemetry.jsonl"

EXPECTED_X='records=4 skipped=0
gate-failures spec-review=0 quality-review=0 adversarial=0
gate-missing spec-review=0 quality-review=0 adversarial=0
reviewer-route legacy:review-primary=4
implementer-status DONE=4
failure-strategy degraded=4 degraded-distinct-descriptions=3'

run_retro "$FIXX"
RC_X=$RC; OUT_X="$OUT"; ERR_X="$ERR"

if [ "$RC_X" -eq 0 ] && [ "$OUT_X" = "$EXPECTED_X" ] && [ -z "$ERR_X" ]; then
  pass "(x) 4 degraded records / 3 distinct descriptions collapse to degraded=4 + degraded-distinct-descriptions=3 (exit 0, empty stderr)"
else
  bad "(x) degraded bucketing wrong: rc=$RC_X expected=[$EXPECTED_X] got=[$OUT_X] stderr=[$ERR_X]"
fi

# Stated as the regression: the free text must appear NOWHERE as a tally key.
if printf '%s' "$OUT_X" | grep -qE '(no-agents|rate-limited|index stale)='; then
  bad "(x) a free-text description became a tally key — one entry per task, no signal: got=[$OUT_X]"
else
  pass "(x) no free-text description leaked into the tally as its own key"
fi

# ── (ab) MISSING-GATE: absent gate fields land in gate-missing, never gate-failures ──
# A pre-schema or truncated record that never had spec-review/quality-review/adversarial
# at all must not inflate the failure tally — session-state.md's Reader contract gives
# these fields the same missing/unknown treatment failure-strategy already has.
FIXAB="$TMP_ROOT/retro-fixab"
mkdir -p "$FIXAB/context"
cat > "$FIXAB/context/task-telemetry.jsonl" <<'JSONL'
{"at":"2026-08-02T10:00:00Z","session-id":"exec-1","retro-session-id":"retro-1","task":1,"task-name":"A","surface":"api","mode":"multi-agent","fallback-path":"none","writer-model":"opus","reviewer-route":"review-primary","implementer-status":"DONE","verify":"x exit=0","acceptance-verified":[],"codesift":"available","backlog-adds":0,"failure-strategy":"halt"}
JSONL

EXPECTED_AB='records=1 skipped=0
gate-failures spec-review=0 quality-review=0 adversarial=0
gate-missing spec-review=1 quality-review=1 adversarial=1
reviewer-route legacy:review-primary=1
implementer-status DONE=1
failure-strategy halt=1'

run_retro "$FIXAB"
RC_AB=$RC; OUT_AB="$OUT"; ERR_AB="$ERR"

if [ "$RC_AB" -eq 0 ] && [ "$OUT_AB" = "$EXPECTED_AB" ] && [ -z "$ERR_AB" ]; then
  pass "(ab) a record with NO spec-review/quality-review/adversarial keys at all lands in gate-missing=1/1/1, NOT gate-failures — absence is not a declared failure"
else
  bad "(ab) missing-gate-field handling wrong: rc=$RC_AB expected=[$EXPECTED_AB] got=[$OUT_AB] stderr=[$ERR_AB]"
fi

# ── (ac) NONSTRING-GATE: a bool/int/object gate value is malformed, never a verdict ──
# str(True) == "True" and str(3) == "3" must never be compared against "PASS"/"COMPLIANT"
# as if they were real verdicts — that is the exact corruption this closes.
FIXACN="$TMP_ROOT/retro-fixacn"
mkdir -p "$FIXACN/context"
cat > "$FIXACN/context/task-telemetry.jsonl" <<'JSONL'
{"at":"2026-08-02T10:00:00Z","session-id":"exec-1","retro-session-id":"retro-1","task":1,"task-name":"A","surface":"api","mode":"multi-agent","fallback-path":"none","writer-model":"opus","reviewer-route":"review-primary","implementer-status":"DONE","spec-review":true,"quality-review":3,"adversarial":{"verdict":"PASS"},"verify":"x exit=0","acceptance-verified":[],"codesift":"available","backlog-adds":0,"failure-strategy":"halt"}
JSONL

EXPECTED_ACN='records=1 skipped=0
gate-failures spec-review=0 quality-review=0 adversarial=0
gate-missing spec-review=1 quality-review=1 adversarial=1
reviewer-route legacy:review-primary=1
implementer-status DONE=1
failure-strategy halt=1'

run_retro "$FIXACN"
RC_ACN=$RC; OUT_ACN="$OUT"; ERR_ACN="$ERR"

if [ "$RC_ACN" -eq 0 ] && [ "$OUT_ACN" = "$EXPECTED_ACN" ] && [ -z "$ERR_ACN" ]; then
  pass "(ac) a JSON bool/int/object gate value (spec-review=true, quality-review=3, adversarial={...}) is treated as malformed -> gate-missing, never stringified into a passing or failing verdict"
else
  bad "(ac) non-string gate value handling wrong: rc=$RC_ACN expected=[$EXPECTED_ACN] got=[$OUT_ACN] stderr=[$ERR_ACN]"
fi

# ── (ad) CASE-SENSITIVE: a lowercased PASS-prefix value must FAIL, not pass ──────────
# The writer always emits the literal uppercase "PASS ..."/"COMPLIANT" forms, so a
# lowercased or mixed-case value is itself a sign of a hand-edited/corrupt record.
# This pins the deliberate case-sensitive decision as a regression guard.
FIXCS="$TMP_ROOT/retro-fixcs"
mkdir -p "$FIXCS/context"
cat > "$FIXCS/context/task-telemetry.jsonl" <<'JSONL'
{"at":"2026-08-02T10:00:00Z","session-id":"exec-1","retro-session-id":"retro-1","task":1,"task-name":"A","surface":"api","mode":"multi-agent","fallback-path":"none","writer-model":"opus","reviewer-route":"review-primary","implementer-status":"DONE","spec-review":"COMPLIANT","quality-review":"pass cq=1/1","adversarial":"Pass mode=code","verify":"x exit=0","acceptance-verified":[],"codesift":"available","backlog-adds":0,"failure-strategy":"halt"}
JSONL

EXPECTED_CS='records=1 skipped=0
gate-failures spec-review=0 quality-review=1 adversarial=1
gate-missing spec-review=0 quality-review=0 adversarial=0
reviewer-route legacy:review-primary=1
implementer-status DONE=1
failure-strategy halt=1'

run_retro "$FIXCS"
RC_CS=$RC; OUT_CS="$OUT"; ERR_CS="$ERR"

if [ "$RC_CS" -eq 0 ] && [ "$OUT_CS" = "$EXPECTED_CS" ] && [ -z "$ERR_CS" ]; then
  pass "(ad) lowercase/mixed-case 'pass ...' values are counted as gate-failures (case-sensitive by contract), not silently accepted as passing"
else
  bad "(ad) case-sensitivity handling wrong: rc=$RC_CS expected=[$EXPECTED_CS] got=[$OUT_CS] stderr=[$ERR_CS]"
fi

# ── (ae) DEGRADED-CAP: distinct descriptions beyond the cap collapse to "+N more" ────
# 70 records, each with a DISTINCT degraded:<desc> tail. DEGRADED_DESC_CAP=64 in the
# fence, so the tracked set fills at 64 and the remaining 6 distinct descriptions must
# be reported as an approximate overflow, never grown into the set without bound.
FIXCAP="$TMP_ROOT/retro-fixcap"
mkdir -p "$FIXCAP/context"
: > "$FIXCAP/context/task-telemetry.jsonl"
_dc=1
while [ "$_dc" -le 70 ]; do
  retro_rec "$_dc" ",\"failure-strategy\":\"degraded:reason-$_dc\"" >> "$FIXCAP/context/task-telemetry.jsonl"
  _dc=$((_dc + 1))
done

EXPECTED_CAP='records=70 skipped=0
gate-failures spec-review=0 quality-review=0 adversarial=0
gate-missing spec-review=0 quality-review=0 adversarial=0
reviewer-route legacy:review-primary=70
implementer-status DONE=70
failure-strategy degraded=70 degraded-distinct-descriptions=64 (+6 more)'

run_retro "$FIXCAP"
RC_CAP=$RC; OUT_CAP="$OUT"; ERR_CAP="$ERR"

if [ "$RC_CAP" -eq 0 ] && [ "$OUT_CAP" = "$EXPECTED_CAP" ] && [ -z "$ERR_CAP" ]; then
  pass "(ae) 70 distinct degraded descriptions cap at 64 tracked + '(+6 more)' overflow — the tracked set never grows past the documented bound"
else
  bad "(ae) degraded-description cap handling wrong: rc=$RC_CAP expected=[$EXPECTED_CAP] got=[$OUT_CAP] stderr=[$ERR_CAP]"
fi

# ── (af) BLANK-LINE: blank/whitespace-only physical lines count toward NEITHER bucket ─
# A trailing newline (or a stray blank line) in an append-only file is not a record —
# it must not inflate skipped= (it isn't corrupt) or records= (it isn't a task).
FIXBL="$TMP_ROOT/retro-fixbl"
mkdir -p "$FIXBL/context"
{
  retro_rec 1 ',"failure-strategy":"halt"'
  printf '\n'
  printf '   \n'
  retro_rec 2 ',"failure-strategy":"halt"'
} > "$FIXBL/context/task-telemetry.jsonl"

EXPECTED_BL='records=2 skipped=0
gate-failures spec-review=0 quality-review=0 adversarial=0
gate-missing spec-review=0 quality-review=0 adversarial=0
reviewer-route legacy:review-primary=2
implementer-status DONE=2
failure-strategy halt=2'

run_retro "$FIXBL"
RC_BL=$RC; OUT_BL="$OUT"; ERR_BL="$ERR"

if [ "$RC_BL" -eq 0 ] && [ "$OUT_BL" = "$EXPECTED_BL" ] && [ -z "$ERR_BL" ]; then
  pass "(af) a blank line and a whitespace-only line between two real records count toward NEITHER records= nor skipped= (records=2 skipped=0)"
else
  bad "(af) blank-line handling wrong: rc=$RC_BL expected=[$EXPECTED_BL] got=[$OUT_BL] stderr=[$ERR_BL]"
fi

# ── (y) READER SSOT: the reader's field names diffed against session-state.md ─
# The WRITER's `K = [...]` is already diffed against the zuvo:telemetry-schema
# table by (a). The READER had no equivalent: `rec.get(key, default)` never raises
# on a renamed key, so a rename would make retro report 100% gate failure FOREVER
# and nothing would say so.
READER_KEYS="$TMP_ROOT/reader-keys.txt"
printf '%s\n' "$RETRO_BLOCK" \
  | sed -nE 's/^F_[A-Z_]+ = "([^"]+)".*$/\1/p' | sort -u > "$READER_KEYS"
READER_KEY_COUNT="$(grep -c . "$READER_KEYS")"

if [ "$READER_KEY_COUNT" -gt 0 ]; then
  pass "(y) reader declares $READER_KEY_COUNT telemetry field names as F_* literals (count derived from the fence)"
else
  bad "(y) no F_* = \"<key>\" declarations found in the retro fence — the reader has no schema SSOT to diff"
fi

# The reader legitimately touches a SUBSET of the documented keys, so this is a
# containment check, not an equality diff: every literal it reads must be a
# documented key. A rename in session-state.md then fails here instead of silently
# turning every gate into a failure.
if [ "$READER_KEY_COUNT" -gt 0 ] && [ "$DOC_KEY_COUNT" -gt 0 ]; then
  UNDOC="$(comm -23 "$READER_KEYS" "$DOC_KEYS" | tr '\n' ' ')"
  if [ -z "${UNDOC// /}" ]; then
    pass "(y) every reader field literal is a documented zuvo:telemetry-schema key ($READER_KEY_COUNT of $DOC_KEY_COUNT) — a schema rename cannot pass unnoticed"
  else
    bad "(y) reader reads field name(s) that session-state.md does not document: [$UNDOC]"
  fi
else
  skipped "(y) reader-vs-doc key containment — one of the two key lists is empty"
fi

# An inline `.get("<key>"` would bypass the SSOT entirely, so the literal form is
# forbidden outright. `.get(F_SPEC)` / `.get(key, 0)` are the permitted shapes.
# Whole-line comments are dropped first — the fence documents this very rule in
# prose, and a check that fires on its own documentation is unfixable. A `.get("`
# followed by a trailing comment is NOT a whole-line comment and is still caught.
INLINE_GETS="$(printf '%s\n' "$RETRO_BLOCK" \
  | grep -vE '^[[:space:]]*#' \
  | grep -nE '\.get\([[:space:]]*["'"'"']' || true)"
if [ -z "$INLINE_GETS" ]; then
  pass "(y) no inline .get(\"<key>\") literal in the reader — every field name goes through the F_* SSOT"
else
  bad "(y) inline .get(\"<key>\") literal bypasses the reader SSOT: [$(printf '%s' "$INLINE_GETS" | tr '\n' ' ')]"
fi

# ── (z) NO-PYTHON (reader): shadow PATH built from the READER fence's own deps ─
# A prior round claimed the reader's outer `|| echo "[WARN] …"` fallback was
# unfalsifiable without mutating the fence. It is not: the SAME shadow-PATH
# technique groups (f)/(m) already use for the WRITER fence reaches it here with
# zero mutation. The dependency set is DERIVED from the reader fence itself
# (never hand-listed), so a future dependency the fence gains fails loudly here
# instead of silently letting this group pass for the wrong reason.
RETRO_SHELL_PART="$TMP_ROOT/retro-fence-shell.txt"
printf '%s\n' "$RETRO_BLOCK" | awk '
  inbody { if ($0 ~ /^PY[[:space:]]*$/) { inbody = 0 } ; next }
  { print }
  /^[[:space:]]*\|\| echo/ { inbody = 1 }
' > "$RETRO_SHELL_PART"

RETRO_FENCE_TOKENS="$TMP_ROOT/retro-fence-tokens.txt"
{
  grep -vE '^[[:space:]]*#' "$RETRO_SHELL_PART" \
    | grep -vE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' \
    | sed -E 's/^[[:space:]]+//' \
    | grep -oE '^[A-Za-z0-9_./-]+'
  grep -oE '\$\([[:space:]]*[A-Za-z0-9_./-]+' "$RETRO_SHELL_PART" \
    | sed -E 's/^\$\([[:space:]]*//'
} | sort -u > "$RETRO_FENCE_TOKENS"

RETRO_FENCE_DEPS="$TMP_ROOT/retro-fence-deps.txt"
: > "$RETRO_FENCE_DEPS"
while IFS= read -r _tok; do
  [ -n "$_tok" ] || continue
  if [ "$(type -t "$_tok" 2>/dev/null || true)" = "file" ]; then
    printf '%s\n' "$_tok" >> "$RETRO_FENCE_DEPS"
  fi
done < "$RETRO_FENCE_TOKENS"
sort -u -o "$RETRO_FENCE_DEPS" "$RETRO_FENCE_DEPS"

RETRO_DEP_LIST="$(tr '\n' ' ' < "$RETRO_FENCE_DEPS")"
if grep -qx 'python3' "$RETRO_FENCE_DEPS"; then
  pass "(z) reader fence command dependencies derived from the fence itself: [$RETRO_DEP_LIST]"
else
  bad "(z) derived reader dependency set does not contain python3 — shadow PATH would be meaningless. Got [$RETRO_DEP_LIST]"
fi

# The documented [WARN] text, derived from the READER fence (never hardcoded) —
# same discipline as $WARN_EXPECTED (writer) and $RETRO_NOTE (missing-file) above.
RETRO_WARN_COUNT="$(printf '%s\n' "$RETRO_BLOCK" | grep -c '^[[:space:]]*|| echo "\[WARN\]')"
RETRO_WARN_EXPECTED="$(printf '%s\n' "$RETRO_BLOCK" \
  | sed -n 's/^[[:space:]]*|| echo "\(\[WARN\].*\)"[[:space:]]*$/\1/p')"
if [ "$RETRO_WARN_COUNT" -eq 1 ] && [ -n "$RETRO_WARN_EXPECTED" ]; then
  pass "(z) reader fence carries exactly one '|| echo \"[WARN] …\"' tail; expected stdout derived from it"
else
  bad "(z) expected exactly one '|| echo \"[WARN] …\"' tail in the reader fence; found $RETRO_WARN_COUNT, parsed [$RETRO_WARN_EXPECTED]"
fi

# A shadow WITH python3 (built from the SAME derived deps) must still succeed —
# mirrors the writer's (m): if the derivation missed a command, this fails loudly
# instead of letting the no-python3 case below pass for the wrong reason.
RETRO_SHADOW_FULL="$TMP_ROOT/retro-bin-full"
build_shadow "$RETRO_SHADOW_FULL" yes "$RETRO_FENCE_DEPS"
FIXZM="$TMP_ROOT/retro-fixzm"
mkdir -p "$FIXZM/context"
retro_rec 1 ',"failure-strategy":"halt"' > "$FIXZM/context/task-telemetry.jsonl"
EXPECTED_ZM='records=1 skipped=0
gate-failures spec-review=0 quality-review=0 adversarial=0
gate-missing spec-review=0 quality-review=0 adversarial=0
reviewer-route legacy:review-primary=1
implementer-status DONE=1
failure-strategy halt=1'
run_retro "$FIXZM" "PATH=$RETRO_SHADOW_FULL"
RC_ZM=$RC; OUT_ZM="$OUT"; ERR_ZM="$ERR"
if [ "$RC_ZM" -eq 0 ] && [ "$OUT_ZM" = "$EXPECTED_ZM" ] && [ -z "$ERR_ZM" ]; then
  pass "(z) shadow PATH covers every command the reader fence actually needs (run under it succeeds with the expected aggregate)"
else
  bad "(z) reader fence needs a command the derived shadow lacks — derived=[$RETRO_DEP_LIST] rc=$RC_ZM expected=[$EXPECTED_ZM] out=[$OUT_ZM] err=[$ERR_ZM]"
fi

# The no-python3 shadow itself.
RETRO_SHADOW="$TMP_ROOT/retro-bin"
build_shadow "$RETRO_SHADOW" no "$RETRO_FENCE_DEPS"
if [ -e "$RETRO_SHADOW/python3" ]; then
  bad "(z) shadow PATH precondition broken: python3 present in $RETRO_SHADOW"
fi

FIXZ="$TMP_ROOT/retro-fixz"
mkdir -p "$FIXZ/context"
retro_rec 1 ',"failure-strategy":"halt"' > "$FIXZ/context/task-telemetry.jsonl"

if [ -z "$RETRO_WARN_EXPECTED" ]; then
  skipped "(z) NO-PYTHON reader fallback (absent python3) — expected [WARN] text could not be derived from the fence"
else
  run_retro "$FIXZ" "PATH=$RETRO_SHADOW"
  RC_Z=$RC; OUT_Z="$OUT"; ERR_Z="$ERR"
  # Exact-equality (not "contains [WARN]") proves nothing else appears on stdout
  # — a `||` bound to the wrong command is the realistic way this silently
  # changes shape, and it is only visible as extra/missing stdout. Stderr is
  # NOT asserted empty here: bash itself writes "python3: command not found" to
  # stderr when resolving the absent binary (mirrors the writer's (f)/(g), which
  # makes the same call for the identical reason).
  if [ "$RC_Z" -eq 0 ] && [ "$OUT_Z" = "$RETRO_WARN_EXPECTED" ]; then
    pass "(z) reader python3 absent → exit 0, stdout byte-exactly the documented [WARN] line, nothing else on stdout"
  else
    bad "(z) reader python3 absent → expected rc=0 + exactly [$RETRO_WARN_EXPECTED]; got rc=$RC_Z out=[$OUT_Z] err=[$ERR_Z]"
  fi

  if printf '%s\n' "$OUT_Z" "$ERR_Z" | grep -Fq 'BLOCKED'; then
    bad "(z) reader python3 absent → output contains a BLOCKED token; a failed read is a WARNING, never a blocked state"
  else
    pass "(z) reader python3 absent → no BLOCKED token anywhere in stdout/stderr"
  fi
fi

# stub python3 exiting 127 — `command not found` (no such binary) and a child
# that EXITS 127 travel different code paths in bash; both must reach the same
# `|| echo` tail (mirrors the writer's (f) stub-127 case).
RETRO_SHADOW2="$TMP_ROOT/retro-bin2"
build_shadow "$RETRO_SHADOW2" no "$RETRO_FENCE_DEPS"
printf '#!/usr/bin/env bash\nexit 127\n' > "$RETRO_SHADOW2/python3"
chmod +x "$RETRO_SHADOW2/python3"

FIXZ2="$TMP_ROOT/retro-fixz2"
mkdir -p "$FIXZ2/context"
retro_rec 1 ',"failure-strategy":"halt"' > "$FIXZ2/context/task-telemetry.jsonl"

if [ -z "$RETRO_WARN_EXPECTED" ]; then
  skipped "(z) stub python3 exiting 127 (reader) — expected [WARN] text could not be derived from the fence"
else
  run_retro "$FIXZ2" "PATH=$RETRO_SHADOW2"
  RC_Z2=$RC; OUT_Z2="$OUT"; ERR_Z2="$ERR"
  if [ "$RC_Z2" -eq 0 ] && [ "$OUT_Z2" = "$RETRO_WARN_EXPECTED" ]; then
    pass "(z) stub python3 exiting 127 (reader) → exit 0, stdout byte-exactly the documented [WARN] line"
  else
    bad "(z) stub python3 exit 127 (reader) → expected rc=0 + exactly [$RETRO_WARN_EXPECTED]; got rc=$RC_Z2 out=[$OUT_Z2] err=[$ERR_Z2]"
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# (ag) ROUTE VOCABULARY — plan C Task 2: every consumer of the reviewer route
# speaks the router's lane and status vocabulary (see the header for the list).
# ══════════════════════════════════════════════════════════════════════════════
# The six telemetry values are the plan's decision and are pinned here on purpose;
# everything the ROUTER emits (lanes, statuses, rows) is taken from RUNNING it —
# never restated in this file.
ROUTE_ENUM='cross-vendor review-primary review-alt in-family-fallback same-model-fallback routing-failed'
ENV_COMPAT="$ROOT/shared/includes/env-compat.md"
ROUTING_DOC="$ROOT/shared/includes/test-reviewer-routing.md"
ROUTER="$ROOT/scripts/reviewer-model-route.sh"
REGISTRY="$ROOT/shared/includes/model-registry.sh"

# (ag-retro) the retro reader counts every value of the enum under its own key, and is
# cutover-aware: a record whose `at` is before the cross-vendor router (commit 83b6b48c,
# 2026-09-28T15:23:38Z) is tallied under `legacy:<value>`, one with no valid `at` under
# `undated:<value>`. The records are written with python/json (never sed over JSON): six
# post-cutover records, one a second BEFORE the instant, one AT it, and one with no `at`.
FIXAG="$TMP_ROOT/retro-fixag"
mkdir -p "$FIXAG/context"
python3 - "$FIXAG/context/task-telemetry.jsonl" "$ROUTE_ENUM" <<'JSONGEN'
import json, sys
path, enum = sys.argv[1], sys.argv[2].split()
base = {"session-id": "exec-1", "retro-session-id": "retro-1", "task-name": "T", "surface": "api", "mode": "multi-agent",
        "fallback-path": "none", "writer-model": "opus", "implementer-status": "DONE", "spec-review": "COMPLIANT",
        "quality-review": "PASS cq=1/1", "adversarial": "PASS mode=code", "verify": "x exit=0",
        "acceptance-verified": [], "codesift": "available", "backlog-adds": 0, "failure-strategy": "halt"}
recs = [(v, "2026-10-01T10:00:00Z") for v in enum]
recs += [("review-primary", "2026-09-28T15:23:37Z"), ("cross-vendor", "2026-09-28T15:23:38Z"), ("review-alt", None)]
with open(path, "w", encoding="utf-8") as fh:
    for i, (route, at) in enumerate(recs, 1):
        rec = {"at": at} if at else {}
        rec.update(base, task=i)
        rec["reviewer-route"] = route
        fh.write(json.dumps(rec) + "\n")
JSONGEN
EXPECTED_AG_ROUTE="reviewer-route cross-vendor=2 in-family-fallback=1 legacy:review-primary=1 review-alt=1 review-primary=1 routing-failed=1 same-model-fallback=1 undated:review-alt=1"
run_retro "$FIXAG"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] \
   && printf '%s\n' "$OUT" | grep -qxF "records=9 skipped=0" \
   && printf '%s\n' "$OUT" | grep -qxF "$EXPECTED_AG_ROUTE"; then
  pass "(ag) retro reader tallies each reviewer-route value under its own key, cutover-aware: [$EXPECTED_AG_ROUTE]"
else
  bad "(ag) retro reader did not tally the reviewer-route values across the cutover: rc=$RC expected line=[$EXPECTED_AG_ROUTE] out=[$OUT] err=[$ERR]"
fi

# (ag-docs) one python program RUNS the router and checks the documents against what it
# actually emits; it prints `ok<TAB>label` or `no<TAB>label<TAB>detail` per check and
# exits 0 unless it crashed. A crash, stray stderr, zero results or ANY other output line
# is itself a failure.
# The EXECUTED matrix is the authority on the router's vocabulary (every host, actual
# writer ids, every documented writer source, client present/missing, --fallback, the
# fail-closed, same-model and override paths). A regex over the router source is only a
# SUPPLEMENTARY cross-check that the matrix reaches every literal the source names — it can
# miss computed values, which is why it never defines the vocabulary.
AG_WORK="$TMP_ROOT/ag"
mkdir -p "$AG_WORK"
AG_OUT="$TMP_ROOT/ag.out"
AG_ERR="$TMP_ROOT/ag.err"
WRITE_TESTS_SKILL="$ROOT/skills/write-tests/SKILL.md"
python3 - "$STATE_DOC" "$SKILL" "$RETRO_SKILL" "$ENV_COMPAT" "$ROUTING_DOC" "$ROUTER" "$REGISTRY" "$AG_WORK" "$ROUTE_ENUM" \
  "$WRITE_TESTS_SKILL" >"$AG_OUT" 2>"$AG_ERR" <<'PY'
import datetime, os, re, shlex, shutil, signal, subprocess, sys, tempfile

(state_doc, execute_skill, retro_skill, env_compat, routing_doc,
 router, registry, work, enum_arg, write_tests_skill) = sys.argv[1:11]
EXPECTED = enum_arg.split()
KEYS = ["platform", "writer_model", "writer_lane", "reviewer_lane", "reviewer_model", "routing_status"]
HOSTS = ("claude", "codex", "cursor", "kimi", "antigravity", "unknown")
CALLER_SIDE = {"rate-limited"}  # env-compat: recorded by a CALLER whose dispatch was throttled; never a router answer
REG_VARS = ("ZUVO_MODEL_CODEX_PRIMARY", "ZUVO_MODEL_CODEX_ALT", "ZUVO_MODEL_CODEX_REVIEW_ALT",
            "ZUVO_MODEL_CODEX_SMALL", "ZUVO_MODEL_CLAUDE_REVIEWER_OPUS")
PLAIN_ID = r"[A-Za-z0-9][A-Za-z0-9._:-]*"
REPO = os.path.dirname(os.path.dirname(os.path.abspath(router)))
SENT = "@SENTINEL@"  # an env value that becomes THIS run's own sentinel client (a fresh path per run)
# ONE case rule for every document parsed here: table KEYWORDS (any, installed, missing, yes, no,
# ignored, runs, does not run, ...) compare case-insensitively; ids, lanes and statuses are
# case-sensitive, exactly as the router's `case` patterns are.


def say(ok, label, detail=""):
    label = str(label).replace("\t", " ").replace("\n", " ")
    detail = str(detail).replace("\t", " ").replace("\n", " ")[:1500] or "-"
    print("ok\t%s" % label if ok else "no\t%s\t%s" % (label, detail))


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def ticks(text):
    return re.findall(r"`([^`]+)`", text)


def norm(text):
    return " ".join(text.split())


def kw(cell):
    """The keyword a cell starts with, lowercased — the one case rule for table keywords."""
    return norm(cell).lower()


def strip_fences(text, name):
    """The document outside fenced code blocks (a fenced line reads as empty). An unclosed fence is a FAIL,
    never a silent blanking of the rest of the document."""
    out, fence, opened = [], None, 0
    for n, line in enumerate(text.splitlines(), 1):
        m = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if fence is None and m:
            fence, opened = m.group(1), n
            out.append("")
        elif fence is not None:
            if re.match(r"^ {0,3}%s{%d,}\s*$" % (re.escape(fence[0]), len(fence)), line):
                fence = None
            out.append("")
        else:
            out.append(line)
    say(fence is None, "%s: every fenced code block is closed" % name, "fence opened at line %d never closes" % opened)
    return "\n".join(out) if fence is None else ""


def doc(path):
    return strip_fences(read(path), os.path.basename(os.path.dirname(path)) + "/" + os.path.basename(path))


def section(text, heading):
    m = re.search(r"^%s[ \t]*\n(.*?)(?=^## |\Z)" % re.escape(heading), text, re.S | re.M)
    return m.group(1) if m else ""


def between(text, name):
    m = re.search(r"<!-- zuvo:%s:start -->(.*?)<!-- zuvo:%s:end -->" % (name, name), text, re.S)
    return m.group(1) if m else None


def paragraph(text, starts, stop_blank=True):
    """The text that begins with <starts>, up to the next bold label or heading — and, when <stop_blank>, the next
    blank line (a bold-labelled block may span several paragraphs: stop_blank=False)."""
    lines, out = text.splitlines(), None
    for line in lines:
        if out is None:
            if line.startswith(starts):
                out = [line]
            continue
        if (stop_blank and not line.strip()) or line.startswith("**") or line.startswith("#"):
            break
        out.append(line)
    return norm("\n".join(out)) if out else ""


def cells_of(line):
    return [c.strip() for c in re.split(r"(?<!\\)\|", line.strip())[1:-1]]


def table(text, name):
    """The rows of the ONE pipe table in <text> (header + separator dropped). A second table block — e.g. rows
    after a blank line — or a separator that is not all dashes is a FAIL, never a silently shorter table."""
    blocks, cur = [], None
    for line in text.splitlines():
        if line.lstrip().startswith("|"):
            if cur is None:
                cur = []
                blocks.append(cur)
            cur.append(line)
        else:
            cur = None
    ok = len(blocks) == 1 and len(blocks[0]) >= 2
    sep = cells_of(blocks[0][1]) if ok else []
    ok = ok and bool(sep) and all(c and re.fullmatch(r":?-+:?", c) for c in sep)
    say(ok, "%s: exactly one pipe table, header + dash separator, no row split off by a blank line" % name,
        "%d table block(s); separator %r" % (len(blocks), sep))
    return [cells_of(l) for l in blocks[0][2:]] if ok else []


def bullets(text):
    items, cur = [], None
    for line in text.splitlines():
        if line.startswith("- "):
            cur = [line]
            items.append(cur)
        elif cur is not None and line.startswith("  ") and line.strip():
            cur.append(line.strip())
        else:
            cur = None
    return [" ".join(i) for i in items]


def list_after(text, intro):
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.startswith(intro):
            block = []
            for nxt in lines[i + 1:]:
                if not nxt.strip():
                    if block:
                        break
                    continue
                block.append(nxt)
            return bullets("\n".join(block))
    return []


def base(model):
    """The id without its ONE optional trailing [ctx] suffix (letters/digits) — the router's writer-id shape (its
    same-model guard compares ids this way). Any other bracket use is not a valid id: None."""
    m = re.fullmatch(r"(%s)(\[[A-Za-z0-9]+\])?" % PLAIN_ID, model or "")
    return m.group(1) if m else None


def tokens_only(cell):
    """The ticked tokens of a cell that holds NOTHING but ticked tokens joined by commas / 'or'; None otherwise."""
    return ticks(cell) if re.fullmatch(r"`[^`]+`(\s*(,|,?\s*or)\s*`[^`]+`)*", cell.strip()) else None


def exact_enum(label, got):
    say(got == EXPECTED, label, "got %r, want exactly (in order) %r" % (got, EXPECTED))


def no_multi_backtick(name, text):
    say("``" not in text, "%s: no multi-backtick code span (the token parser reads single backticks only)" % name,
        "found ``")


def has_all(text, *needles):
    return all(n in text for n in needles)


# ── running the router: every run in its OWN temp dir (HOME, CODEX_HOME, its own sentinel client and client
# shim), removed in `finally`; the sentinel's log is checked for existence AND content after that run ──
LONE = os.path.join(work, "lone")  # the router with no runner library beside it and none in ~/.zuvo
os.makedirs(LONE, exist_ok=True)
shutil.copy(router, os.path.join(LONE, "reviewer-model-route.sh"))


def make_case(extra, clients=()):
    case = tempfile.mkdtemp(prefix="case-", dir=work)
    home = os.path.join(case, "home")
    os.makedirs(home)
    sentinel, log = os.path.join(case, "client"), os.path.join(case, "client-ran.log")
    with open(sentinel, "w") as fh:
        fh.write("#!/bin/sh\necho \"$0 $*\" >> %s\nexit 1\n" % shlex.quote(log))
    os.chmod(sentinel, 0o755)
    env = {"PATH": "/usr/bin:/bin", "HOME": home, "CODEX_HOME": os.path.join(home, "codex"),
           "ZUVO_CODEX_APP_BIN": "/nonexistent", "ZUVO_CODEX_BIN": "/nonexistent", "ZUVO_CLAUDE_BIN": "/nonexistent"}
    for k, v in extra.items():
        env[k] = sentinel if v == SENT else v.replace("@HOME@", home)
    if clients:
        shim = os.path.join(case, "shim")
        os.makedirs(shim)
        for c in clients:
            os.symlink(sentinel, os.path.join(shim, c))
        env["PATH"] = shim + ":" + env["PATH"]
    return case, env, log


def run(argv, env, log):
    """{'rc','out','err','ran'} or {'error','ran'}: its own process group (killed whole on timeout); the sentinel
    log is read on the error path too. A subprocess failure is a named FAIL, never a traceback."""
    def ran():
        return read(log) if os.path.exists(log) else ""
    try:
        p = subprocess.Popen(argv, env=env, cwd=env["HOME"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             start_new_session=True)
        try:
            so, se = p.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.communicate()
            return {"error": "timeout after 5s (process group killed)", "ran": ran()}
        return {"rc": p.returncode, "out": so.decode("utf-8"), "err": se.decode("utf-8"), "ran": ran()}
    except (OSError, UnicodeDecodeError) as exc:
        return {"error": "%s: %s" % (type(exc).__name__, exc), "ran": ran()}


def parse_route(stdout):
    """The six keys, or None: exactly the contract's keys, in order, each once (a duplicate key is a reject,
    never collapsed by a dict), each value non-empty with no blank before or after it."""
    pairs = [l.split("=", 1) for l in stdout.splitlines()]
    if [p[0] for p in pairs] != KEYS or any(len(p) != 2 or not p[1].strip() or p[1] != p[1].strip() for p in pairs):
        return None
    return dict(pairs)


def registry_under(env, log):
    """The registry ids as the router sees them: sourced under the SAME environment the router runs with."""
    r = run(["/bin/bash", "-c", '. "$1" || exit 1; for v in %s; do printf "%%s=%%s\\n" "$v" "${!v}"; done'
             % " ".join(REG_VARS), "_", registry], env, log)
    if "error" in r or r["rc"] != 0:
        return None
    return {"$" + k: v for k, _, v in (l.partition("=") for l in r["out"].splitlines())}


def once(argv_tail, extra, clients=()):
    """One router run outside the matrix (flags, --fallback syntax), in its own removed temp dir."""
    case, env, log = make_case(extra, clients)
    try:
        return run(["/bin/bash", router] + list(argv_tail), env, log)
    finally:
        shutil.rmtree(case, ignore_errors=True)


# T2/U6 self-test: the parser the whole matrix relies on rejects what the real router never prints
_ok6 = "platform=claude\nwriter_model=opus\nwriter_lane=strong_primary\nreviewer_lane=cross-vendor\nreviewer_model=gpt-x\nrouting_status=ok\n"
say(parse_route(_ok6) is not None
    and parse_route(_ok6.replace("writer_model=opus", "writer_model= opus")) is None
    and parse_route(_ok6.replace("writer_model=opus", "writer_model=opus ")) is None
    and parse_route(_ok6.replace("writer_model=opus", "writer_model=  ")) is None
    and parse_route(_ok6.replace("writer_model=opus", "writer_model=")) is None
    and parse_route(_ok6 + "routing_status=ok\n") is None
    and parse_route(_ok6.replace("platform=claude\n", "")) is None,
    "self-test: parse_route rejects a padded, blank or empty value, a duplicate key and a missing key", "")

results, crashes = [], []
FAILCLOSED_ERR = {  # the EXACT stderr line each fail-closed path prints (anchored; one line each, nothing else)
    "blank": [r"reviewer-model-route: ZUVO_MODEL_CODEX_PRIMARY from \S+ is not a single model id \(.+\) — routing failed closed"],
    "ctx": [r"reviewer-model-route: ZUVO_MODEL_CLAUDE_REVIEWER_OPUS from \S+ is not a single model id \(.+\) — routing failed closed"],
    "nolib": [re.escape("reviewer-model-route: model-subprocess.sh (shared host detection) not loaded from next to this "
                        "script or from ~/.zuvo — routing failed closed. Fix: ./scripts/install.sh")],
}


def route(label, host, writer, extra, args=(), cli="any", key=False, lone=False, failclosed=None, clients=()):
    """<writer> is the id the documented writer sources should yield for this run (None = none given)."""
    case, env, log = make_case(extra, clients)
    try:
        reg = registry_under(env, log)
        r = run(["/bin/bash", os.path.join(LONE, "reviewer-model-route.sh") if lone else router] + list(args), env, log)
    finally:
        shutil.rmtree(case, ignore_errors=True)
    rec = {"label": label, "host": host, "writer": writer, "cli": cli, "fb": "yes" if "--fallback" in args else "no",
           "key": key, "clients": tuple(clients), "reg": reg, "failclosed": failclosed, "ran": r["ran"]}
    if "error" in r:
        crashes.append("%s: %s" % (label, r["error"]))
        rec["out"] = None
    else:
        rec.update(rc=r["rc"], out=parse_route(r["out"]), raw=r["out"], stderr=r["err"])
    results.append(rec)
    return rec


reg0_run = make_case({})
try:
    reg0 = registry_under(reg0_run[1], reg0_run[2]) or {}
finally:
    shutil.rmtree(reg0_run[0], ignore_errors=True)
say(len(reg0) == len(REG_VARS) and all(re.fullmatch(PLAIN_ID, v or "") for v in reg0.values()),
    "registry ids resolve, each one plain id, under the router's own environment", reg0)
XV_CODEX, XV_OPUS = reg0.get("$ZUVO_MODEL_CODEX_PRIMARY", ""), reg0.get("$ZUVO_MODEL_CLAUDE_REVIEWER_OPUS", "")
# Claude-host writers: every tier shape, undetected ids, case, a [ctx] where no tier allows one, and the Codex
# reviewer's own id (reviewed by itself: the same-model guard, on the cross-vendor route).
CLAUDE_WRITERS = ["opus", "opus[1m]", "claude-opus", "claude-opus-5-5[1m]", "claude-3-opus-20240229", "claude-3-opus",
                  "sonnet", "claude-sonnet-5", "claude-3-5-sonnet-20241022", "haiku", "claude-haiku-4-5",
                  None, "", "unknown", "opus[", "op us", "opus ", "opus[1m][2m]", "Opus", "claude-opus[1m]", XV_CODEX]
CODEX_WRITERS = [XV_CODEX, reg0.get("$ZUVO_MODEL_CODEX_ALT"), reg0.get("$ZUVO_MODEL_CODEX_SMALL"), "gpt-5.6-sol", "gpt-5.4",
                 "gpt-5.5", "gpt-5.4-mini", None, "", "unknown", XV_CODEX.upper(), "opus", XV_OPUS, XV_OPUS + "[1m]"]
for fb in ((), ("--fallback",)):
    for host, signal_env, wvar, seam, writers in (
            ("claude", {"CLAUDECODE": "1"}, "CLAUDE_MODEL", "ZUVO_CODEX_BIN", CLAUDE_WRITERS),
            ("codex", {"CODEX_SHELL": "1"}, "ZUVO_CODEX_MODEL", "ZUVO_CLAUDE_BIN", CODEX_WRITERS)):
        for w in writers:
            for cli in ("installed", "missing"):
                e = dict(signal_env)
                if w is not None:
                    e[wvar] = w
                e[seam] = SENT if cli == "installed" else "/nonexistent"
                route("%s writer=%r cli=%s %s" % (host, w, cli, " ".join(fb)), host, w, e, fb, cli)
    # override paths (tests/smoke only) — the same table, reached through --platform / --writer-model
    gate = {"ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE": "1"}
    route("override claude opus", "claude", "opus", dict(gate, ZUVO_CODEX_BIN=SENT),
          ("--platform", "claude", "--writer-model", "opus") + fb, "installed")
    route("override claude no writer", "claude", None, dict(gate), ("--platform", "claude") + fb, "missing")
    route("override codex writer=unknown", "codex", "unknown", dict(gate),
          ("--platform", "codex", "--writer-model", "unknown") + fb, "missing")
    # The same-model guard IN-FAMILY: a registry whose primary is the alt makes the alt writer's reviewer itself.
    # Both --fallback settings run on purpose — they prove DIFFERENT overrides: without it the guard replaces a
    # `cross-vendor-unavailable` row, with it an `in-family-fallback` row (asserted below).
    route("same-model: Codex primary swapped to the alt, writer alt", "codex", reg0.get("$ZUVO_MODEL_CODEX_ALT"),
          {"CODEX_SHELL": "1", "ZUVO_CODEX_MODEL": reg0.get("$ZUVO_MODEL_CODEX_ALT", ""),
           "ZUVO_MODEL_CODEX_PRIMARY": reg0.get("$ZUVO_MODEL_CODEX_ALT", "")}, fb, "missing")
    # fail closed: an invalid registry id (a writer-style [ctx] suffix included) and a missing runner library. The
    # registry assigns `VAR="${VAR:-default}"`, so the environment value is the one the router reads.
    route("registry id not one plain id (blank)", "claude", None, {"CLAUDECODE": "1", "ZUVO_MODEL_CODEX_PRIMARY": "a b"},
          fb, failclosed="blank")
    route("registry id with a [ctx] suffix", "codex", None,
          {"CODEX_SHELL": "1", "ZUVO_MODEL_CLAUDE_REVIEWER_OPUS": XV_OPUS + "[1m]"}, fb, failclosed="ctx")
    route("no runner library", "claude", None, {"CLAUDECODE": "1"}, fb, lone=True, failclosed="nolib")
    # the other hosts (X7): Cursor, Kimi, Antigravity, and no host at all — client tie-break included
    for cli, clients in (("installed", ("agy",)), ("installed", ("codex", "claude")), ("installed", ("claude",)),
                         ("missing", ())):
        tag = "cli=%s[%s]" % (cli, ",".join(clients))
        route("cursor writer %s" % tag, "cursor", "composer-2.5-fast", {"CURSOR_AGENT_MODEL": "composer-2.5-fast"}, fb,
              cli, clients=clients)
        route("cursor no writer %s" % tag, "cursor", None, {"VSCODE_GIT_ASKPASS_MAIN": "/Applications/Cursor.app/x"}, fb,
              cli, clients=clients)
        route("cursor writer=agy %s" % tag, "cursor", "agy", {"CURSOR_AGENT_MODEL": "agy"}, fb, cli, clients=clients)
        for kw_ in ("kimi-code", "kimi-k2.6", "kimi-k2.7-code", "KIMI-K2.6"):
            route("kimi %s no key %s" % (kw_, tag), "kimi", kw_, {"ZUVO_KIMI_CLI_MODEL": kw_}, fb, cli, clients=clients)
            route("kimi %s key %s" % (kw_, tag), "kimi", kw_, {"ZUVO_KIMI_CLI_MODEL": kw_, "MOONSHOT_API_KEY": "k"}, fb,
                  cli, key=True, clients=clients)
    for g in ("gemini-3-flash", "gemini-2.5-flash-lite", "gemini-3.1-pro-low", "gemini-3.1-pro-low[1m]",
              "gemini-2.5-pro-low", "gemini-2.5-pro-lowx", "gemini-3.1-pro-high", "gemini-2.5-pro", "gemini",
              "Gemini-3-flash", "mystery-model"):
        route("antigravity %s" % g, "antigravity", g, {"ANTIGRAVITY_SESSION_ID": "1", "GEMINI_MODEL": g}, fb)
    # every documented SECONDARY writer source, and each precedence (Codex's CODEX_MODEL / config.toml are
    # pinned by tests/hooks/test-reviewer-route-cross-vendor.sh)
    route("cursor CURSOR_MODEL only", "cursor", "composer-2", {"CURSOR_MODEL": "composer-2"}, fb, "missing")
    route("cursor CURSOR_AGENT_MODEL beats CURSOR_MODEL", "cursor", "composer-2.5-fast",
          {"CURSOR_AGENT_MODEL": "composer-2.5-fast", "CURSOR_MODEL": "composer-2"}, fb, "missing")
    route("antigravity ANTIGRAVITY_MODEL only", "antigravity", "gemini-3.1-pro-high",
          {"ANTIGRAVITY_SESSION_ID": "1", "ANTIGRAVITY_MODEL": "gemini-3.1-pro-high"}, fb)
    route("antigravity GEMINI_MODEL beats ANTIGRAVITY_MODEL", "antigravity", "gemini-3-flash",
          {"GEMINI_MODEL": "gemini-3-flash", "ANTIGRAVITY_MODEL": "gemini-3.1-pro-high"}, fb)
    route("antigravity no model: the default tier", "antigravity", "gemini-3.1-pro-low", {"ANTIGRAVITY_SESSION_ID": "1"}, fb)
    route("kimi ZUVO_KIMI_MODEL only", "kimi", "kimi-k2.6", {"ZUVO_KIMI_MODEL": "kimi-k2.6"}, fb, "missing")
    route("kimi ZUVO_KIMI_CLI_MODEL beats ZUVO_KIMI_MODEL", "kimi", "kimi-code",
          {"ZUVO_KIMI_CLI_MODEL": "kimi-code", "ZUVO_KIMI_MODEL": "kimi-k2.6"}, fb, "missing")
    route("kimi from PATH alone: the default model", "kimi", "kimi-code", {"PATH": "@HOME@/.kimi-code/bin:/usr/bin:/bin"},
          fb, "missing")
    route("no host signal", "unknown", None, {}, fb)
# the same-model guard on the cross-vendor route (no --fallback there: --fallback never routes cross-vendor)
route("same-model: Claude host, writer = the Codex primary", "claude", XV_CODEX,
      {"CLAUDECODE": "1", "CLAUDE_MODEL": XV_CODEX, "ZUVO_CODEX_BIN": SENT}, (), "installed")
route("same-model: Codex host, writer = the Opus reviewer [1m]", "codex", XV_OPUS + "[1m]",
      {"CODEX_SHELL": "1", "ZUVO_CODEX_MODEL": XV_OPUS + "[1m]", "ZUVO_CLAUDE_BIN": SENT}, (), "installed")

say(not crashes, "every router run completed (no timeout, OS or decode error)", " | ".join(crashes))
ran = ["%s: %s" % (r["label"], r["ran"]) for r in results if r["ran"]]
say(not ran, "no run executed a client: each run's OWN sentinel left no log, error paths included (%d runs)"
    % len(results), ran)
bad_runs = ["%s: rc=%s stdout=%r stderr=%r" % (r["label"], r.get("rc"), r.get("raw"), r.get("stderr")) for r in results
            if "rc" in r and (r["rc"] != 0 or r["out"] is None or (not r["failclosed"] and r["stderr"]))]
say(not bad_runs, "every router run exits 0 with exactly the six keys, in order, each once, non-empty and unpadded "
    "(stderr only on the fail-closed paths)", " | ".join(bad_runs))
err_bad = []
for r in results:
    if r.get("failclosed") and "stderr" in r:
        lines, pats = r["stderr"].splitlines(), FAILCLOSED_ERR[r["failclosed"]]
        if len(lines) != len(pats) or not all(any(re.fullmatch(p, l) for l in lines) for p in pats):
            err_bad.append("%s: stderr %r, want exactly %r" % (r["label"], lines, pats))
say(not err_bad and any(r.get("failclosed") for r in results),
    "every fail-closed run prints EXACTLY its documented diagnostic on stderr, nothing else", " | ".join(err_bad))
say(all(r["reg"] for r in results), "registry resolved for every run under its own environment",
    [r["label"] for r in results if not r["reg"]])
left = [d for d in os.listdir(work) if d.startswith("case-")]
say(not left, "every per-run temp dir (HOME, CODEX_HOME, sentinel, client shim) was removed after its run", left)

OUT = [r for r in results if r.get("out")]
FB = [r for r in OUT if r["fb"] == "yes"]
lanes = sorted({r["out"]["reviewer_lane"] for r in OUT})
statuses = sorted({r["out"]["routing_status"] for r in OUT})
fb_lanes = sorted({r["out"]["reviewer_lane"] for r in FB})
fb_statuses = sorted({r["out"]["routing_status"] for r in FB})
combos = sorted({(r["out"]["reviewer_lane"], r["out"]["routing_status"]) for r in OUT})
fb_combos = sorted({(r["out"]["reviewer_lane"], r["out"]["routing_status"]) for r in FB})

# SUPPLEMENTARY cross-check (see the comment above the heredoc): the matrix reaches every literal the source names
src = read(router)
src_lanes = set(re.findall(r"(?:reviewer_lane|if_lane)=[\"']?([a-z][a-z-]*)", src))
src_statuses = set(re.findall(r"routing_status=[\"']?([a-z][a-z-]*)", src))
say(src_lanes <= set(lanes) and src_statuses <= set(statuses),
    "supplementary: the executed matrix reaches every lane and status literal the router source names",
    "unreached lanes %r, statuses %r" % (sorted(src_lanes - set(lanes)), sorted(src_statuses - set(statuses))))
say(not (set(statuses) & CALLER_SIDE), "the router never emits the caller-side rate-limited", statuses)
xv = sorted({r["out"]["routing_status"] for r in OUT if r["out"]["reviewer_lane"] == "cross-vendor"})
say(xv == ["ok"], "the router emits lane cross-vendor only with routing_status=ok", xv)
cvu = sorted({r["out"]["reviewer_lane"] for r in OUT if r["out"]["routing_status"] == "cross-vendor-unavailable"})
say(cvu and set(cvu) <= {"review-primary", "review-alt"},
    "cross-vendor-unavailable only ever comes with an in-family lane (review-primary / review-alt)", cvu)
smf = sorted({r["out"]["reviewer_lane"] for r in OUT if r["out"]["routing_status"] == "same-model-fallback"})
say(smf == ["same-model-fallback"], "routing_status=same-model-fallback only ever comes with lane same-model-fallback "
    "(the guard and the no-client arms set both)", smf)
for label, pick in (("unset", lambda r: r["writer"] is None), ("the literal `unknown`", lambda r: r["writer"] == "unknown")):
    hit = [r["label"] for r in OUT if r.get("host") in ("claude", "codex") and pick(r) and r["cli"] == "installed"
           and r["fb"] == "no" and not r["failclosed"] and r["out"]["reviewer_lane"] == "cross-vendor"]
    say(len(hit) >= 2, "a writer that is %s, with the other vendor's CLI present, is still routed cross-vendor" % label, hit)
notunk = [r["label"] for r in OUT if r["out"]["platform"] in ("claude", "codex") and r["out"]["reviewer_model"] == "unknown"]
say(not notunk, "over every run: a row with platform=claude or platform=codex never has reviewer_model=unknown (%d runs, "
    "overrides and empty writers included)" % len([r for r in OUT if r["out"]["platform"] in ("claude", "codex")]), notunk)
alias = sorted({r["out"]["reviewer_model"] for r in OUT if r["out"]["platform"] == "claude"
                and r["out"]["routing_status"] in ("cross-vendor-unavailable", "in-family-fallback", "unknown-writer-model")})
say(alias == ["opus", "sonnet"], "the Claude in-family reviewer is always the Agent-tool tier alias opus / sonnet, "
    "never a registry id", alias)
p = once(["--fallback"], {"CLAUDECODE": "1"})
po = parse_route(p.get("out", ""))
say(p.get("rc") == 0 and po is not None and po["routing_status"] == "unknown-writer-model",
    "router: --fallback needs no override gate (exit 0, a defined row)", p)
p2 = once(["--fallback", "--fallback"], {"CLAUDECODE": "1"})
say(p2.get("rc") == 0 and p2.get("out") == p.get("out"), "router: a repeated --fallback is accepted, same answer", p2)
for args in (["--fallback=x"], ["--fallback", "x"], ["--platform"], ["--writer-model"], ["--platform", ""],
             ["--platform", "--fallback"], ["--writer-model", "-x"]):
    r = once(args, {"ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE": "1", "CLAUDECODE": "1"})
    say(r.get("rc") == 2 and r.get("out") == "", "router: %r is a usage error (exit 2, nothing on stdout)" % (args,), r)
r = once(["--platform", "claude"], {"CLAUDECODE": "1"})
say(r.get("rc") == 2 and r.get("out") == "", "router: --platform without ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE=1 is refused (exit 2)", r)

# ── env-compat.md "Reviewer Model Routing" ───────────────────────────────────
sec = section(doc(env_compat), "## Reviewer Model Routing")
say(bool(sec), "env-compat.md has a Reviewer Model Routing section", "missing")
no_multi_backtick("env-compat.md Reviewer Model Routing", sec)
items = bullets(sec)
doc_lanes = [re.match(r"- `([^`]+)`", b).group(1) for b in list_after(sec, "Reviewer lanes") if re.match(r"- `([^`]+)`", b)]
say(sorted(doc_lanes) == lanes, "env-compat.md: the Reviewer lanes list is exactly the lanes the router emits",
    "doc %r, emitted %r" % (doc_lanes, lanes))
doc_statuses = [re.match(r"- `([^`]+)`", b).group(1) for b in list_after(sec, "Allowed routing statuses")
                if re.match(r"- `([^`]+)`", b)]
say(set(statuses) <= set(doc_statuses) and set(doc_statuses) <= set(statuses) | CALLER_SIDE,
    "env-compat.md: Allowed routing statuses = every emitted status, plus only the caller-side rate-limited",
    "doc %r, emitted %r" % (doc_statuses, statuses))
uwm = [b for b in list_after(sec, "Allowed routing statuses") if b.startswith("- `unknown-writer-model`")]
ENV_FACTS = (
    ("a known vendor is a known writer (plan C)", ("a known vendor is a known writer",)),
    ("--fallback is documented as NOT gated by the override variable",
     ("`--fallback`", "NOT gated by `ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE`")),
    ("--fallback takes no value: --fallback=<v> / --fallback <v> exit 2, a repeat is accepted (D5)",
     ("`--fallback`", "takes no value", "`--fallback=x`", "exit 2", "repeated")),
    ("ids match case-sensitively", ("case-sensitive",)),
    ("the Claude in-family reviewers are the tier aliases opus / sonnet, not registry ids (D1)",
     ("`opus`", "`sonnet`", "tier aliases", "not registry ids")),
    ("the router checks registry ids by charset only; the same-vendor check is downstream (D1/f3-15)",
     ("charset", "preflight", "`model-run`", "same vendor")),
    ("untrusted metadata: an unknown writer is still cross-vendor when the CLI is present (D2)",
     ("security boundary", "`cross-vendor`", "in-family")),
    ("the same-model guard cannot fire for an unknown writer; possibly-same-model marks it (D3)",
     ("no writer id to compare", "`:possibly-same-model`")),
    ("Cursor/Kimi pick the first of agy, codex, claude found on PATH (D4)",
     ("`agy`, then `codex`, then `claude`", "first one found")),
    ("placeholders are defined in writer-id characters, not 'any text' (D7)", ("writer-id characters",)),
    ("preflight: ok is preflight ok only when the route keeps its contract, else degraded-routing (D11)",
     ("`reviewer-preflight.sh`", "`degraded-routing`", "own vendor", "not `claude` or `codex`")),
    ("preflight (Task 6 post-cap): the six-key gate counts blank lines and rejects non-printable bytes; each "
     "violation prints its own diagnostic; the same-vendor guard checks the route's own platform= AND the host; a "
     "broken ok route never goes first; the routed canary uses the routed reviewer_model; the six trailing lines are "
     "the router's answer or the sentinel (P1-P5)",
     ("six-key gate", "blank lines counted", "printable ASCII only", "its own diagnostic line", "`platform=`",
      "detected independently", "never goes in front", "routed `reviewer_model`", "fail-closed sentinel",
      "`preflight_status` is the verdict")),
)
for label, needles in ENV_FACTS:
    say(any(has_all(b, *needles) for b in items) or has_all(norm(sec), *needles), "env-compat.md: " + label,
        "no bullet carries %r" % (needles,))
say("any text" not in sec, "env-compat.md: no placeholder is defined as 'any text' (D7)", "found 'any text'")
say(len(uwm) == 1 and "could not be identified" in uwm[0] and "differs from the writer" not in uwm[0],
    "env-compat.md: unknown-writer-model is defined uniformly — the writer could not be identified — with no claim "
    "that the reviewer differs from the writer (D3)", uwm)
charset = re.search(r"one id of the charset `([^`]+)`", norm(sec))
WRITER_RE = (charset.group(1) + r"(\[[A-Za-z0-9]+\])?") if charset else None
say(WRITER_RE is not None, "env-compat.md: the writer-id charset is stated", "missing 'one id of the charset `...`'")


def undetected(w):
    return w is None or w in ("", "unknown") or WRITER_RE is None or not re.fullmatch(WRITER_RE, w)


# the placeholders, as env-compat defines them: writer-id characters, never "any text" (D7)
CH, SUF = r"[A-Za-z0-9._:-]", r"(?:\[[A-Za-z0-9]+\])?"
PH = {"<ctx>": "[A-Za-z0-9]+", "<version>": CH + "+" + SUF, "<date>": CH + "+" + SUF, "<n>": "[0-9]" + CH + "*",
      "<rest>": CH + "*" + SUF}


def shape_re(shape):
    rx = re.escape(shape)
    for ph, sub in PH.items():
        rx = rx.replace(re.escape(ph), sub)
    return rx


def is_shape(t):
    return re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:\[\]-]*(<(ctx|version|n|date|rest)>[A-Za-z0-9._:\[\]-]*)*", t) is not None


tiers = {}
for cells in table(between(sec, "writer-tiers") or "", "env-compat.md writer tiers"):
    shapes = tokens_only(cells[2]) if len(cells) == 3 else None
    if len(cells) != 3 or not ticks(cells[0]) or not ticks(cells[1]) or not shapes or not all(is_shape(s) for s in shapes):
        say(False, "env-compat.md: writer-tier row is well formed", cells)
        continue
    tiers[ticks(cells[0])[0]] = (ticks(cells[1])[0], [shape_re(s) for s in shapes])
say(set(tiers) == {"opus", "sonnet", "haiku"}, "env-compat.md: the Claude writer tiers sit between zuvo:writer-tiers markers",
    sorted(tiers))


def tiers_of(w):
    return [t for t, (_, rxs) in tiers.items() if w is not None and any(re.fullmatch(rx, w) for rx in rxs)]


def expected_writer(r):
    """The writer_model the documented writer sources give this run: on Claude/Codex an undetected id is `unknown`;
    elsewhere the id the case set (Cursor with none: `unknown`); no host: `unknown`."""
    if r["host"] in ("claude", "codex"):
        return "unknown" if undetected(r["writer"]) else r["writer"]
    return r["writer"] if r["writer"] else "unknown"


# U2 / T19: every documented writer source, EXECUTED — writer ids verbatim or `unknown`, precedence, tier lanes
wbad, tbad = [], []
for r in OUT:
    if r["failclosed"]:
        continue
    w, o = r["writer"], r["out"]
    if o["platform"] != r["host"] or o["writer_model"] != expected_writer(r):
        wbad.append("%s -> platform=%s writer_model=%s, want %s/%s" % (r["label"], o["platform"], o["writer_model"],
                                                                     r["host"], expected_writer(r)))
    if r["host"] == "claude":
        found = [] if undetected(w) else tiers_of(w)
        if len(found) > 1:
            tbad.append("%s: %d tiers match %r (the tier table is ambiguous)" % (r["label"], len(found), found))
        elif o["writer_lane"] != (tiers[found[0]][0] if found else "unknown"):
            tbad.append("%s -> writer_lane=%s, tier table says %s" % (r["label"], o["writer_lane"],
                                                                      tiers[found[0]][0] if found else "unknown"))
say(not wbad, "writer sources, executed: each host, each documented source and precedence — a well-formed id is the "
    "writer verbatim, anything else is `unknown`", " | ".join(wbad))
say(tiers and not tbad, "env-compat.md writer tiers, executed: every Claude id matches at most ONE tier and the router "
    "classifies it as that tier's writer_lane (no tier -> unknown)", " | ".join(tbad))

# the decision table: parsed strictly, then used to PREDICT each run's answer
CLI_KW = {"installed": "installed", "missing": "missing", "any": "any", "—": "any"}
FB_KW = {"no": "no", "yes": "yes", "any": "any", "ignored": "any", "—": "any"}
OTHER = r"an id no other `([a-z]+)` row names"


def parse_drows(text, name):
    """(rows, malformed) for a decision table. A writer cell's 'an id no other `<host>` row names' must name one of
    the row's OWN hosts — a row that points at another host's rows is malformed, never followed."""
    rows_, bad_rows = [], []
    for cells in table(text, name):
        if len(cells) != 7:
            bad_rows.append(("7 cells", cells))
            continue
        host_cell, writer_cell, cli_cell, fb_cell, lane_cell, model_cell, status_cell = cells
        d = {"cells": cells, "hits": 0, "kind": "row", "hosts": [], "key": None, "other": None}
        if kw(host_cell).startswith("any host"):
            k = kw(host_cell)
            d["kind"] = ("guard" if "same-model guard" in k else "failclosed" if "fail-closed sentinel" in k
                         else "caller" if "caller-side" in k else None)
        else:
            d["hosts"] = [t for t in ticks(host_cell) if t in HOSTS]
            stray = [t for t in ticks(host_cell) if t not in HOSTS and t != "MOONSHOT_API_KEY"]
            if stray or not d["hosts"]:
                d["kind"] = None
            d["key"] = ("with" if "`kimi` with `MOONSHOT_API_KEY`" in host_cell
                        else "without" if "`kimi` without `MOONSHOT_API_KEY`" in host_cell else None)
        d["cli"] = CLI_KW.get(kw(cli_cell).split(" ")[0] if cli_cell else "")
        d["fb"] = FB_KW.get(kw(fb_cell).split(" ")[0] if fb_cell else "")
        lane, status = tokens_only(lane_cell), tokens_only(status_cell)
        d["lane"] = lane[0] if lane and len(lane) == 1 else None
        d["status"] = status[0] if status and len(status) == 1 else None
        wc = writer_cell
        d["wild"] = kw(wc).startswith("any") or wc == "—"
        other = re.search(OTHER, wc)
        bad = []
        if other:
            if other.group(1) in d["hosts"]:
                d["other"] = other.group(1)
            else:
                bad.append("'no other `%s` row' on a row for %r" % (other.group(1), d["hosts"]))
        wc_rest = re.sub(OTHER, "", wc)
        toks = []
        for t in ticks(wc_rest):
            if d["kind"] == "guard":  # the guard row's writer cell names the statuses it overrides, nothing else
                (toks if t in statuses or t == "[ctx]" else bad).append(("guarded", t) if t != "[ctx]" else ("ctx", t))
            elif "`%s` tier" % t in wc_rest and t in tiers:
                toks.append(("tier", t))
            elif t == "unknown":
                toks.append(("unknown", t))
            elif t.startswith("$") and t[1:] in REG_VARS:
                toks.append(("reg", t))
            elif is_shape(t) and "`%s` tier" % t not in wc_rest:
                toks.append(("shape", t))
            else:
                bad.append(t)
        d["wtoks"] = toks
        mk = kw(model_cell)
        if mk.startswith("the writer") and not ticks(model_cell):
            d["model"] = ("writer", None)
        elif mk.startswith("the would-be reviewer") and not ticks(model_cell):
            d["model"] = ("wouldbe", None)
        elif mk.startswith("the first of") and ticks(model_cell):
            d["model"] = ("set", ticks(model_cell))
        elif tokens_only(model_cell) and len(ticks(model_cell)) == 1:
            d["model"] = ("one", ticks(model_cell)[0])
        elif model_cell == "—" and d["kind"] == "caller":
            d["model"] = ("none", None)
        else:
            d["model"] = None
        if None in (d["kind"], d["cli"], d["fb"], d["lane"], d["status"], d["model"]) or bad \
                or not (d["wild"] or d["other"] or toks or wc == "—"):
            bad_rows.append(("unrecognised token or shape %r" % bad, cells))
            continue
        rows_.append(d)
    return rows_, bad_rows


def writer_hit(d, rows_, host, w, reg, depth=0):
    """Does <w> match row <d>'s writer cell? 'an id no other `<h>` row names' consults only the OTHER rows for the
    host <h> the cell names, by their own ticked ids — never their own 'no other' clause (depth guard)."""
    if depth > 1:
        return False
    if d["wild"] and depth == 0:
        return True
    for kind, t in d["wtoks"]:
        if kind == "tier" and w is not None and not undetected(w) and t in tiers_of(w):
            return True
        if kind == "unknown" and undetected(w):
            return True
        if kind == "reg" and w is not None and reg.get(t) == w:
            return True
        if kind == "shape" and w is not None and re.fullmatch(shape_re(t), w):
            return True
    if d["other"] and depth == 0 and not undetected(w):
        return not any(writer_hit(o, rows_, host, w, reg, depth + 1)
                       for o in rows_ if o is not d and o["kind"] == "row" and d["other"] in o["hosts"] and not o["wild"])
    return False


# T12 self-test: a row whose 'no other' clause names ANOTHER host is malformed; two rows that point at each other
# still terminate (the clause is never followed transitively)
st_rows, st_bad = parse_drows(
    "| h | w | c | f | l | m | s |\n|---|---|---|---|---|---|---|\n"
    "| `claude` | an id no other `codex` row names | missing | no | `review-alt` | `sonnet` | `unknown-writer-model` |\n"
    "| `kimi` | an id no other `kimi` row names | any | ignored | `review-alt` | `kimi-k2.6` | `ok` |\n"
    "| `kimi` | an id no other `kimi` row names | any | ignored | `review-alt` | `kimi-code` | `ok` |\n", "self-test table")
say(len(st_bad) == 1 and "no other `codex`" in str(st_bad[0]) and len(st_rows) == 2
    and writer_hit(st_rows[0], st_rows, "kimi", "kimi-x", {}) is True,
    "self-test: a 'no other `<host>`' clause for another host is malformed; mutually referring clauses terminate",
    (st_rows, st_bad))

rt = between(sec, "route-table")
say(rt is not None, "env-compat.md: the decision table sits between zuvo:route-table markers", "markers missing")
drows, malformed = parse_drows(rt or "", "env-compat.md decision table")
say(not malformed, "env-compat.md decision table: every row parses (known host/kind, cli, --fallback, one lane, one "
    "model form, one status; no unrecognised token coerced to 'any')", malformed)
guard = [d for d in drows if d["kind"] == "guard"]
guarded = {t for k, t in (guard[0]["wtoks"] if len(guard) == 1 else []) if k == "guarded"}
say(len(guard) == 1 and guarded == {"ok", "in-family-fallback", "cross-vendor-unavailable"}
    and "runs last" in kw(guard[0]["cells"][1]) and guard[0]["lane"] == guard[0]["status"] == "same-model-fallback",
    "env-compat.md: ONE same-model guard row, on any host, runs last over every ok / in-family-fallback / "
    "cross-vendor-unavailable row", [d["cells"] for d in guard])
say(not [d for d in drows if d["status"] in guarded and d["model"][0] not in ("one", "set")],
    "env-compat.md: every row the guard can override names its reviewer by id or client list, so the guard is "
    "predicted for every model form a guarded row uses", [d["cells"] for d in drows if d["status"] in guarded
                                                          and d["model"][0] not in ("one", "set")])
say(not [d for d in drows if set(d["hosts"]) & {"claude", "codex"} and d["model"] == ("one", "unknown")],
    "env-compat.md: no Claude/Codex row names reviewer_model `unknown` (the documented bullet, in the table)",
    [d["cells"] for d in drows if set(d["hosts"]) & {"claude", "codex"} and d["model"] == ("one", "unknown")])


def named_model(d, r):
    """The reviewer id the DOCUMENTED row names for this run — from the registry, the cell, the run's own client
    list, or the writer the documented sources give; never the router's own output (no circular oracle)."""
    form, v = d["model"]
    if form == "one":
        return r["reg"].get(v) if v.startswith("$") else v
    if form == "set":  # the first client, in the cell's order, that is on this run's PATH
        return next((c for c in v if c in r["clients"]), None)
    if form == "writer":
        return expected_writer(r)
    return None


def predict(r):
    """(row, overridden row, reviewer id) the documented table gives this run: the fail-closed row for a fail-closed
    run; otherwise the FIRST row (table order) matching host, Kimi key, client, --fallback and the ACTUAL writer
    id — replaced by the same-model guard row when that row's status is guarded and the reviewer it names IS the
    writer (compared without a [ctx] suffix)."""
    if r["failclosed"]:
        rows_ = [d for d in drows if d["kind"] == "failclosed"]
        return (rows_[0], None, named_model(rows_[0], r)) if rows_ else (None, None, None)
    for d in drows:
        if d["kind"] != "row" or r["host"] not in d["hosts"]:
            continue
        if d["key"] is not None and r["host"] == "kimi" and (d["key"] == "with") != r["key"]:
            continue
        if d["cli"] not in (r["cli"], "any") or d["fb"] not in (r["fb"], "any") \
                or not writer_hit(d, drows, r["host"], r["writer"], r["reg"]):
            continue
        named = named_model(d, r)
        if guard and d["status"] in guarded and named is not None and base(named) is not None \
                and base(named) == base(expected_writer(r)):
            return guard[0], d, named
        return d, None, named
    return None, None, None


mism, preds = [], {}
for r in OUT:
    d, over, named = predict(r)
    preds[id(r)] = (d, over, named)
    o = r["out"]
    if d is None:
        mism.append("%s: no documented row answers it (got %s/%s/%s)" % (r["label"], o["reviewer_lane"], o["reviewer_model"],
                                                                         o["routing_status"]))
        continue
    d["hits"] += 1
    if not (o["reviewer_lane"] == d["lane"] and o["routing_status"] == d["status"] and o["reviewer_model"] == named):
        mism.append("%s: the table predicts [%s] naming %s but the router says %s/%s/%s" % (
            r["label"], " | ".join(d["cells"]), named, o["reviewer_lane"], o["reviewer_model"], o["routing_status"]))
say(drows and not mism, "env-compat.md decision table PREDICTS every one of %d router answers — lane, status and the "
    "reviewer id, all from the doc (first matching row by host, key, client, --fallback and the ACTUAL writer id; "
    "then the same-model guard)" % len(OUT), " || ".join(mism))
unhit = [" | ".join(d["cells"]) for d in drows if d["hits"] == 0 and d["kind"] != "caller"]
say(drows and not unhit, "env-compat.md decision table: every row but the caller-side one is an answer the router gives",
    " || ".join(unhit))
swap = {r["fb"]: (preds[id(r)][1] or {}).get("status") for r in OUT if r["label"].startswith("same-model: Codex primary")}
say(swap == {"no": "cross-vendor-unavailable", "yes": "in-family-fallback"},
    "same-model guard, in-family: without --fallback it overrides a cross-vendor-unavailable row, with it an "
    "in-family-fallback row", swap)
caller_rows = [d for d in drows if d["kind"] == "caller"]
say(len(caller_rows) == 1 and caller_rows[0]["status"] == "rate-limited"
    and "not a router output row" in norm(sec) and "six-key" in norm(sec),
    "env-compat.md decision table: exactly one caller-side row, status rate-limited, stated as not a router output row "
    "(so the six-key rule does not apply to its — cells) (D8)", [d["cells"] for d in caller_rows])
pre = paragraph(sec, "Decision table (")
say("caller-side" in pre and "rate-limited" in pre, "env-compat.md: the table's preamble (the paragraph starting "
    "'Decision table (') names the caller-side row as the one the router never produces", pre)
unk_rows = [r["label"] for r in OUT if r["out"]["reviewer_model"] == "unknown" and preds[id(r)][2] != "unknown"]
say(not unk_rows, "reviewer_model=unknown only where the documented row names `unknown` (or the writer, when the "
    "writer is unknown)", unk_rows)
kimi_bad, kimi_n = [], 0
for r in OUT:
    if r.get("host") != "kimi" or not re.match(r"kimi (kimi-code|kimi-k2\.6|kimi-k2\.7-code|KIMI-K2\.6) (no key|key) ", r["label"]):
        continue
    kimi_n += 1
    w = r["writer"]
    want = ("kimi-code" if re.match(r"kimi-k2\.[0-9]", w) else "kimi-k2.6") if r["key"] else \
        next((c for c in ("agy", "codex", "claude") if c in r["clients"]), w)
    if r["out"]["reviewer_model"] != want:
        kimi_bad.append("%s (writer=%s key=%s fb=%s clients=%s) -> %s, want %s" % (
            r["label"], w, r["key"], r["fb"], r["clients"], r["out"]["reviewer_model"], want))
say(kimi_n == 64 and not kimi_bad,
    "Kimi, executed per (writer, key, --fallback, clients) — 64 runs: with MOONSHOT_API_KEY a kimi-k2.x writer is "
    "reviewed by kimi-code and any other id (case-sensitive) by kimi-k2.6; without one, by the first of agy, codex, "
    "claude on PATH, else by itself", "%d runs; %s" % (kimi_n, " | ".join(kimi_bad)))

# ── telemetry: session-state.md schema row + the CONJUNCTIVE reviewer-route mapping ─
state = doc(state_doc)
m = between(state, "telemetry-schema")
rows = [l for l in (m.splitlines() if m else []) if re.match(r"^\|\s*`reviewer-route`\s*\|", l)]
if len(rows) != 1:
    say(False, "session-state.md: exactly one reviewer-route schema row", "found %d" % len(rows))
else:
    cm = re.match(r"^\|[^|]*\|[^|]*\|(.*)\|\s*$", rows[0])
    cell = cm.group(1).replace("\\|", "|").strip() if cm else ""
    lead = re.match(r"^`[^`]+`(?:\s*\|\s*`[^`]+`)*", cell)
    exact_enum("session-state.md: the reviewer-route enum is exactly the six route values",
               ticks(lead.group(0)) if lead else [])
mp = between(state, "reviewer-route-map")
say(mp is not None, "session-state.md: the reviewer-route mapping sits between zuvo:reviewer-route-map markers", "missing")
no_multi_backtick("session-state.md reviewer-route mapping", mp or "")
rules, mbad = [], []
for cells in table(mp or "", "session-state.md reviewer-route mapping"):
    if len(cells) != 4:
        mbad.append(cells)
        continue
    caller = "caller-side" in kw(cells[0])
    ln = None if kw(cells[0]) == "any" else ([] if caller else tokens_only(cells[0]))
    st = tokens_only(cells[1])  # the status column is ALWAYS explicit: `any` is allowed in the lane column only
    val = tokens_only(cells[2])
    ok = (ln is None or all(t in lanes for t in ln)) and st is not None and all(t in statuses or t in CALLER_SIDE for t in st) \
        and val is not None and len(val) == 1 and val[0] in EXPECTED and (not caller or st == ["rate-limited"])
    if not ok:
        mbad.append(cells)
        continue
    rules.append({"cells": cells, "caller": caller, "lanes": ln, "statuses": st, "value": val[0], "hits": 0})
say(rules and not mbad, "session-state.md mapping: every rule names its routing_status explicitly, its reviewer_lane "
    "explicitly or as `any` (the lane column only), and ONE enum value", mbad)
wrong, produced = [], set()
for lane, status in combos:
    hit = [u for u in rules if not u["caller"] and (u["lanes"] is None or lane in u["lanes"]) and status in u["statuses"]]
    if len(hit) != 1:
        wrong.append("(%s,%s) matches %d rules, want exactly 1" % (lane, status, len(hit)))
        continue
    hit[0]["hits"] += 1
    v = hit[0]["value"]
    produced.add(v)
    if status == "ok" and v != lane:
        wrong.append("(%s,ok) -> %s (an ok route is recorded as its lane)" % (lane, v))
    elif status != "ok" and v in ("cross-vendor", "review-primary", "review-alt"):
        wrong.append("(%s,%s) -> %s (a degraded route must never read as a clean lane)" % (lane, status, v))
    elif status == "routing-failed" and v != "routing-failed":
        wrong.append("(%s,routing-failed) -> %s" % (lane, v))
say(rules and not wrong, "session-state.md mapping, conjunctive: each of the %d emitted (lane, status) combos matches "
    "EXACTLY one rule; ok -> its lane; degraded never a clean lane" % len(combos), " | ".join(wrong))
say(produced == set(EXPECTED), "every reviewer-route value is PRODUCED by some router run through the mapping (none is "
    "caller-side only), and the mapping produces nothing else", "produced %r, enum %r" % (sorted(produced), EXPECTED))
dead = [u["cells"] for u in rules if not u["caller"] and not u["hits"]]
say(rules and not dead, "session-state.md mapping: every router rule is reached by an emitted combo", dead)
crow = [u for u in rules if u["caller"]]
want_caller = caller_rows[0]["lane"] if len(caller_rows) == 1 else None
say(len(crow) == 1 and want_caller is not None and crow[0]["value"] == want_caller,
    "session-state.md mapping: the caller-side rate-limited maps to the lane env-compat documents for it (%s)" % want_caller,
    [(u["cells"], u["value"]) for u in crow])
tsec = section(state, "### `zuvo/context/task-telemetry.jsonl`")
say("`:possibly-same-model`" in tsec and "`Adversarial` field" in tsec,
    "session-state.md: says `possibly-same-model` lives in the write-tests Adversarial field, not in this enum", "missing")

# ── telemetry enum: execute/SKILL.md + retro/SKILL.md (+ the reader fence's cutover) ─
ex_bullets = [l for l in doc(execute_skill).splitlines() if l.startswith("- `reviewer-route`:")]
if len(ex_bullets) != 1:
    say(False, "execute/SKILL.md: exactly one `reviewer-route` telemetry bullet", "found %d" % len(ex_bullets))
else:
    lead = re.match(r"- `reviewer-route`:\s*((?:`[^`]+`\s*,\s*)*(?:or\s+)?`[^`]+`)", ex_bullets[0])
    exact_enum("execute/SKILL.md: the reviewer-route telemetry bullet lists exactly the six route values",
               ticks(lead.group(1)) if lead else [])
    say("session-state.md" in ex_bullets[0],
        "execute/SKILL.md: the reviewer-route bullet points at session-state.md for the mapping", ex_bullets[0])
rt_items = [b for b in bullets(doc(retro_skill)) if b.startswith("- **Reviewer-route distribution**")]
cut_doc = None
if len(rt_items) != 1:
    say(False, "retro/SKILL.md: exactly one Reviewer-route distribution bullet", "found %d" % len(rt_items))
else:
    par = re.search(r"tally by `reviewer-route` \(([^)]*)\)", rt_items[0])
    exact_enum("retro/SKILL.md: the Reviewer-route distribution lists exactly the six route values",
               ticks(par.group(1)) if par else [])
    cut = re.search(r"`at` earlier than `(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)`", rt_items[0])
    cut_doc = cut.group(1) if cut else None
    say(cut is not None and has_all(rt_items[0], "83b6b48c", "`legacy:", "`undated:"),
        "retro/SKILL.md: the cutover is one UTC instant on the record's `at` (commit 83b6b48c); older records are "
        "tallied under `legacy:<value>`, undated ones under `undated:<value>`", rt_items[0])
# The reader fence (a SCRIPT that tallies reviewer-route) carries the same instant; both must equal the commit's own
# time. The tally itself is pinned by the (ag-retro) fixture above, run through the fence.
fence_cut = re.search(r'^ROUTE_CUTOVER = "([^"]+)"', read(retro_skill), re.M)
say(fence_cut is not None and fence_cut.group(1) == cut_doc,
    "retro/SKILL.md: the reader fence's ROUTE_CUTOVER equals the documented instant", (fence_cut and fence_cut.group(1), cut_doc))
g = subprocess.run(["git", "-C", REPO, "show", "-s", "--format=%cI", "83b6b48c"], capture_output=True, text=True)
if g.returncode != 0:
    say(True, "retro cutover vs git: SKIPPED — commit 83b6b48c is not in this clone (%s)" % g.stderr.strip()[:120])
else:
    utc = datetime.datetime.fromisoformat(g.stdout.strip()).astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    say(utc == cut_doc, "retro cutover == git's committer time of 83b6b48c, in UTC (%s)" % utc, (utc, cut_doc))

# ── test-reviewer-routing.md ─────────────────────────────────────────────────
rd = doc(routing_doc)
s4 = section(rd, "## Adversarial routing (Step 4)")
no_multi_backtick("test-reviewer-routing.md Step 4", s4)
say("reviewer-model-route.sh --fallback" in norm(s4),
    "test-reviewer-routing.md Step 4: fallback-local takes its agent from `reviewer-model-route.sh --fallback`", "not named")
s4rows, s4bad_rows = [], []
for cells in table(s4, "test-reviewer-routing.md Step 4"):
    if len(cells) != 4:
        s4bad_rows.append(cells)
        continue
    catch = kw(cells[0]).startswith("any other")
    st = None if kw(cells[0]) == "any" or catch else tokens_only(cells[0])
    ln = None if kw(cells[1]) == "any" else tokens_only(cells[1])
    act = kw(cells[2])
    run_ = "no" if act.startswith("does not run") else "yes" if act.startswith("runs") else None
    if (st is None and kw(cells[0]) not in ("any",) and not catch) or (ln is None and kw(cells[1]) != "any") or run_ is None:
        s4bad_rows.append(cells)
        continue
    s4rows.append({"cells": cells, "catch": catch, "st": st, "ln": ln, "run": run_, "degraded": "degraded" in act,
                   "recd": tokens_only(cells[3].replace(" / ", ", ")), "hits": 0})
say(s4rows and not s4bad_rows, "test-reviewer-routing.md Step 4: every row parses (status and lane cells hold only "
    "tokens or `any`; the action starts with runs / does not run)", s4bad_rows)
named = sorted({t for r in s4rows if r["st"] for t in r["st"]})
say(s4rows and set(named) <= set(fb_statuses),
    "test-reviewer-routing.md Step 4: the table names only statuses --fallback emits (%s)" % ",".join(fb_statuses),
    "names %r not emitted under --fallback" % sorted(set(named) - set(fb_statuses)))
CLEAN = ["clean:fallback-local", "<n> findings:fallback-local"]
MARKED = ["clean:fallback-local:possibly-same-model", "<n> findings:fallback-local:possibly-same-model"]
# The expectation per answer is the doc's own: the rows for `ok` / `in-family-fallback` / `unknown-writer-model` with
# an in-family lane say "runs" (the last two DEGRADED); every other row — `routing-failed`, `same-model-fallback`,
# `unknown-writer-model` with lane `same-model-fallback` — says "does not run" with `SKIPPED_REVIEW`.
s4bad = []
for lane, status in fb_combos:
    hit = [r for r in s4rows if not r["catch"] and (r["st"] is None or status in r["st"]) and (r["ln"] is None or lane in r["ln"])]
    if len(hit) != 1:
        s4bad.append("(%s,%s) matches %d rows, want exactly 1" % (lane, status, len(hit)))
        continue
    r = hit[0]
    r["hits"] += 1
    if lane in ("review-primary", "review-alt") and status in ("ok", "in-family-fallback", "unknown-writer-model"):
        want = MARKED if status == "unknown-writer-model" else CLEAN
        if r["run"] != "yes" or sorted(r["recd"] or []) != sorted(want) or ((status != "ok") != r["degraded"]):
            s4bad.append("(%s,%s): runs%s, recorded exactly %r — row %r" % (lane, status, ", DEGRADED" if status != "ok" else "",
                                                                         want, r["cells"]))
    elif not (r["run"] == "no" and r["recd"] == ["SKIPPED_REVIEW"]):
        s4bad.append("(%s,%s): does not run, `SKIPPED_REVIEW` — row %r" % (lane, status, r["cells"]))
say(s4rows and not s4bad, "test-reviewer-routing.md Step 4: each --fallback answer matches EXACTLY one row, which says "
    "whether it runs and what is recorded (%d combos)" % len(fb_combos), " | ".join(s4bad))
s4dead = [r["cells"] for r in s4rows if not r["catch"] and not r["hits"]]
say(s4rows and not s4dead, "test-reviewer-routing.md Step 4: every row is reached by a --fallback answer", s4dead)
catch = [r for r in s4rows if r["catch"]]
say(len(catch) == 1 and catch[0]["run"] == "no" and catch[0]["recd"] == ["SKIPPED_REVIEW"],
    "test-reviewer-routing.md Step 4: any other answer is a contract violation that does not run", [r["cells"] for r in catch])
say("never recorded as cross-provider" in norm(s4).lower(),
    "test-reviewer-routing.md Step 4: fallback-local is never recorded as cross-provider", "phrase missing")
say(has_all(norm(s4), "Cursor, Antigravity and Kimi", "the ACTION"),
    "test-reviewer-routing.md Step 4: on Cursor / Antigravity / Kimi, `fallback-local` names the action, not a "
    "different route (D6)", "missing")
fbp = paragraph(rd, "**Fallback (driver exit", stop_blank=False)
say(bool(fbp), "test-reviewer-routing.md Step 3.5: the Fallback paragraph exists", "missing")
say("reviewer-model-route.sh --fallback" in fbp and "CURRENT router lanes" not in fbp,
    "test-reviewer-routing.md Step 3.5 fallback: the agent is chosen via `reviewer-model-route.sh --fallback`", fbp)
say("`review-primary` / `same-model-fallback` → `blind-coverage-auditor`" in fbp
    and "`review-alt` → `blind-coverage-auditor-alt`" in fbp and "`routing-failed`" in fbp and "BLOCKED_INFRA" in fbp,
    "test-reviewer-routing.md Step 3.5 fallback: lane -> agent mapping, a same-model lane RUNS the auditor, routing-failed -> BLOCKED_INFRA",
    fbp)
why = paragraph(rd, "**Same-model routes: Step 3.5 runs, Step 4 does not.**")
say(has_all(why, "Step 3.5", "Step 4"),
    "test-reviewer-routing.md: the rule for a same-model route differs between Step 3.5 and Step 4, and says why", why)
res = section(rd, "## Reviewer-model resolution (Step 3.5 fallback + Step 4)")
say("empty value" in norm(res), "test-reviewer-routing.md resolution: an EMPTY value is also routing-failed (D12)", "missing")
pre_sec = section(rd, "## Phase-0 preflight (BEFORE any test is written)")
drow = [l for l in pre_sec.splitlines() if l.startswith("| `degraded-routing` |")]
say(len(drow) == 1 and has_all(drow[0], "other than `ok`", "six-key gate", "breaks its own contract", "`platform=`",
                               "its own stderr line"),
    "test-reviewer-routing.md: the degraded-routing row names both causes — a non-ok status, and an ok route that "
    "breaks its own contract (D11)", drow)
cand = [b for b in bullets(rd) if b.startswith("- **Candidates**")]
say(len(cand) == 1 and has_all(cand[0], "`routing_status=ok`", "canaried FIRST", "routed `reviewer_model`",
                               "registry's canary model", "one canary per client", "never goes first",
                               "panel's alone"),
    "test-reviewer-routing.md: Candidates — on an ok route that keeps its contract the routed client is canaried "
    "FIRST with the routed reviewer_model, one canary per client; otherwise the panel's alone (D11)", cand)
say(has_all(norm(pre_sec), "trailing six lines", "raw answer", "six-key gate", "`routing-failed` sentinel",
            "`preflight_status`", "verdict"),
    "test-reviewer-routing.md: preflight's trailing six lines are the router's raw answer; preflight_status is the "
    "verdict (D11)", "missing")
# The template IS a fenced block (a ```text example of the line to print), so it is read from the raw file.
pl = [l for l in read(routing_doc).splitlines() if l.startswith("Reviewer routing:")]
tl = re.search(r"lane=<([^>]*)>", pl[0]) if len(pl) == 1 else None
ts = re.search(r"status=<([^>]*)>", pl[0]) if len(pl) == 1 else None
say(tl and ts and sorted(tl.group(1).split("|")) == sorted(fb_lanes) and sorted(ts.group(1).split("|")) == sorted(fb_statuses),
    "test-reviewer-routing.md: the Reviewer routing: template lists exactly the lanes and statuses --fallback emits",
    "template %r; emitted lanes %r statuses %r" % (pl, fb_lanes, fb_statuses))

# ── write-tests/SKILL.md Step 5: the Adversarial enum, both directions ────────
wt = doc(write_tests_skill)
adv = [l for l in wt.splitlines() if l.startswith("- Adversarial:")]
lead = re.match(r"- Adversarial:\s*((?:`[^`]+`\s*,\s*)*`[^`]+`)", adv[0]) if len(adv) == 1 else None
adv_vals = ticks(lead.group(1)) if lead else []
BASE_ADV = ["clean", "<n> findings", "skipped", "blocked", "not_run"]  # the values that never involve fallback-local
s4_recorded = sorted({t for r in s4rows for t in (r["recd"] or []) if t != "SKIPPED_REVIEW"})
say(sorted(adv_vals) == sorted(BASE_ADV + s4_recorded) and len(adv_vals) == len(set(adv_vals)),
    "write-tests/SKILL.md Step 5: the Adversarial enum is exactly the non-fallback values + every value Step 4 records",
    "Step 5 %r; want %r" % (adv_vals, sorted(BASE_ADV + s4_recorded)))
say(len(adv) == 1 and "`routing_status=unknown-writer-model`" in adv[0]
    and re.search(r"`skipped`, `blocked` and `not_run` never carry it", adv[0]) is not None,
    "write-tests/SKILL.md Step 5: the suffix is for routing_status=unknown-writer-model when fallback-local RAN, never on "
    "skipped/blocked/not_run", adv)
comp = [l for l in wt.splitlines() if "A file is complete only when" in l]
say(len(comp) == 1 and ":possibly-same-model" in comp[0],
    "write-tests/SKILL.md Step 5: file completeness requires the marker when it applies", comp)
left = [d for d in os.listdir(work) if d.startswith("case-")]
say(not left, "at the end: no per-run temp dir is left behind (matrix, flag and --fallback-syntax runs)", left)
sys.exit(0)
PY
AG_RC=$?
AG_N=0
while IFS= read -r _ag_line; do
  IFS="$(printf '\t')" read -r _ag_v _ag_label _ag_detail <<EOF
$_ag_line
EOF
  case "$_ag_v" in
    ok) pass "(ag) $_ag_label"; AG_N=$((AG_N + 1)) ;;
    no) bad "(ag) $_ag_label — $_ag_detail"; AG_N=$((AG_N + 1)) ;;
    *) bad "(ag) malformed checker output line (neither ok nor no): [$_ag_line]" ;;
  esac
done < "$AG_OUT"
if [ "$AG_RC" -ne 0 ] || [ -s "$AG_ERR" ] || [ "$AG_N" -eq 0 ]; then
  bad "(ag) the route-vocabulary checker itself failed: rc=$AG_RC results=$AG_N stderr=[$(tail -5 "$AG_ERR" | tr '\n' ' ')]"
fi

# ── (ah) ONE route vocabulary across the code that spells it ─────────────────
# session-state.md owns two vocabularies: the six-value `reviewer-route` enum (schema row) and, in the
# reviewer-route map, every (reviewer_lane, routing_status) the router can answer plus the caller-side
# `rate-limited`. Three pieces of code restate them and nothing tied them to the document:
# reviewer-lanes.sh's ZRL_ROUTE_WORDS (the route words a build must never take for a model), model-run's
# lane / status enums (its route-answer shape check), and append-retro's --routing enum. Each is read out
# of its source and compared as a SET with the document: a word added on one side only fails here.
AH_OUT="$TMP_ROOT/ah.out"; AH_ERR="$TMP_ROOT/ah.err"
python3 - "$STATE_DOC" "$ROOT/scripts/lib/reviewer-lanes.sh" "$ROOT/scripts/zuvo-home/model-run" \
  "$ROOT/scripts/zuvo-home/append-retro" >"$AH_OUT" 2>"$AH_ERR" <<'PY'
import re, sys

state_doc, lanes_lib, model_run, append_retro = sys.argv[1:5]


def say(ok, label, detail=""):
    print("ok\t%s" % label if ok else "no\t%s\t%s" % (label, str(detail).replace("\t", " ").replace("\n", " ")[:600] or "-"))


def read(p):
    with open(p, encoding="utf-8") as fh:
        return fh.read()


doc = read(state_doc)
row = [l for l in doc.splitlines() if l.startswith("| `reviewer-route` |")]
# The enum is the backticked words before the row's " — " explanation (its `\|` separators are escaped pipes).
route_enum = set(re.findall(r"`([a-z-]+)`", row[0].split(" — ")[0])) - {"reviewer-route"} if len(row) == 1 else set()
say(len(route_enum) == 6, "session-state.md: ONE reviewer-route schema row with a six-value enum", sorted(route_enum))
m = re.search(r"<!-- zuvo:reviewer-route-map:start -->(.*?)<!-- zuvo:reviewer-route-map:end -->", doc, re.S)
map_lanes, map_statuses = set(), set()
for line in (m.group(1).splitlines() if m else []):
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cells) < 4 or not cells[1].startswith("`"):
        continue
    map_lanes |= set(re.findall(r"`([a-z-]+)`", cells[0]))
    map_statuses |= set(re.findall(r"`([a-z-]+)`", cells[1]))
say(map_lanes and map_statuses, "session-state.md: the reviewer-route map names lanes and statuses", (map_lanes, map_statuses))
router_statuses = map_statuses - {"rate-limited"}

words = re.search(r'^ZRL_ROUTE_WORDS="([^"]*)"', read(lanes_lib), re.M)
zrl = set(words.group(1).split()) if words else set()
say(zrl == route_enum, "reviewer-lanes.sh ZRL_ROUTE_WORDS = session-state.md's reviewer-route enum",
    "lanes lib %r, doc %r" % (sorted(zrl), sorted(route_enum)))

mr = read(model_run)
lane_case = re.search(r'case "\$r_lane" in ([^)]*)\)', mr)
status_case = re.search(r'case "\$r_status" in ([^)]*)\)', mr)
mr_lanes = set(lane_case.group(1).split("|")) if lane_case else set()
mr_statuses = set(status_case.group(1).split("|")) if status_case else set()
say(mr_lanes == map_lanes, "model-run's reviewer_lane enum = the lanes of session-state.md's reviewer-route map",
    "model-run %r, doc %r" % (sorted(mr_lanes), sorted(map_lanes)))
say(mr_statuses == router_statuses, "model-run's routing_status enum = the map's statuses, less the caller-side rate-limited",
    "model-run %r, doc %r" % (sorted(mr_statuses), sorted(router_statuses)))
hdr = re.search(r"model-run: status=<([^>]*)>", mr)
hdr_st = set(hdr.group(1).split("|")) if hdr else set()
used_st = set(re.findall(r"finish [0-9]+ ([a-z]+)", mr)) | set(re.findall(r'finish "\$1" ([a-z]+)', mr))
say(hdr_st and hdr_st == used_st, "model-run: the status= values its header documents are exactly the ones it prints",
    "header %r, finish calls %r" % (sorted(hdr_st), sorted(used_st)))

ar = re.search(r'case "\$ROUTING" in\s*\n\s*([^)]*)\)', read(append_retro))
ar_set = set(ar.group(1).split("|")) if ar else set()
say(ar_set == map_statuses | {"N/A"}, "append-retro --routing enum = the map's statuses (rate-limited included) plus N/A",
    "append-retro %r, doc %r" % (sorted(ar_set), sorted(map_statuses | {"N/A"})))
PY
AH_RC=$?
AH_N=0
while IFS= read -r _ah_line; do
  IFS="$(printf '\t')" read -r _ah_v _ah_label _ah_detail <<EOF
$_ah_line
EOF
  case "$_ah_v" in
    ok) pass "(ah) $_ah_label"; AH_N=$((AH_N + 1)) ;;
    no) bad "(ah) $_ah_label — $_ah_detail"; AH_N=$((AH_N + 1)) ;;
    *) bad "(ah) malformed checker output line: [$_ah_line]" ;;
  esac
done < "$AH_OUT"
if [ "$AH_RC" -ne 0 ] || [ -s "$AH_ERR" ] || [ "$AH_N" -eq 0 ]; then
  bad "(ah) the vocabulary checker itself failed: rc=$AH_RC results=$AH_N stderr=[$(tail -5 "$AH_ERR" | tr '\n' ' ')]"
fi

# ── (h) PURITY ────────────────────────────────────────────────────────────────
# ── (aa) NEVER-A-GATE holds even when the WARN itself cannot be printed ───────
# The fence ends `python3 … || echo "[WARN] …" || true`. The trailing `|| true`
# looks redundant and is not: without it, a run whose stdout is closed or full
# makes `echo` fail, and the compound then returns NON-ZERO on the very path the
# contract says can never gate. Under `set -e`, or any caller that checks the
# status, a failed DIAGNOSTIC would abort the task.
#
# Asserted BEHAVIOURALLY (run it with stdout closed), not by grepping for the
# literal `|| true`: a shape assertion passes for any tail that merely looks
# right, and this contract is about the exit status, not the spelling. Verified
# to discriminate — deleting `|| true` from the fence turns this case RED while
# every other case in this file stays green (it was the ONLY thing that caught
# that regression, which is why it exists).
AA_STUB="$TMP_ROOT/bin-aa"
build_shadow "$AA_STUB" no
printf '#!/usr/bin/env bash\nexit 127\n' > "$AA_STUB/python3"
chmod +x "$AA_STUB/python3"
env ZUVO_OUTPUT_DIR="$TMP_ROOT/fix-aa" PATH="$AA_STUB" \
    TT_AT="2026-08-02T10:00:00Z" TT_SESSION_ID="exec-aa" \
    bash "$RUNNER" >&- 2>/dev/null
RC_AA=$?
if [ "$RC_AA" -eq 0 ]; then
  pass "(aa) append fails AND stdout is closed (echo cannot run) → still exit 0; a failed diagnostic can never gate"
else
  bad "(aa) closed stdout made the never-a-gate path return rc=$RC_AA — the WARN tail must not be able to fail the compound"
fi

# Captured HERE, after the LAST case that executes the fence — not earlier. It
# previously sat above case (aa), so (aa)'s own runner invocation was outside the
# purity window: a case that dirtied the repo would have gone unnoticed by the very
# assertion that exists to notice it. Any case added later must go ABOVE this line.
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
