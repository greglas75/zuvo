#!/usr/bin/env bash
# Regression contract for the production-to-test evidence gate in write-tests.
#
# Architecture under contract (post inventory-first rework):
#   - the inventory is frozen BEFORE any test is written (Step 1.6/1.7)
#   - the coverage gate is EXECUTABLE (scripts/test-coverage-gate.py), not prose
#   - reviewer infrastructure is preflighted in Phase 0 (scripts/reviewer-preflight.sh)
#   - the eval corpus carries BOTH the small controller regression (id 3) and a
#     realistic 22-method controller with disk-artifact assertions (id 4)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/skills/write-tests/SKILL.md"
EVALS="$ROOT/evals/write-tests.evals.json"
ROUTING="$ROOT/shared/includes/test-reviewer-routing.md"
BLIND="$ROOT/shared/includes/blind-coverage-audit.md"
RETRO="$ROOT/shared/includes/retrospective.md"
MODELREG="$ROOT/shared/includes/model-registry.sh"
CROSSPROV="$ROOT/shared/includes/cross-provider-review.md"
fail=0

pass() { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

require_text_in() {
  file="$1"
  needle="$2"
  label="$3"
  if [ ! -r "$file" ]; then
    bad "$label (file unreadable: $file)"
    return
  fi
  if grep -qF -- "$needle" "$file"; then
    pass "$label"
  else
    bad "$label"
  fi
}

require_absent_in() {
  file="$1"
  needle="$2"
  label="$3"
  if [ ! -r "$file" ]; then
    bad "$label (file unreadable: $file)"
    return
  fi
  if grep -qF -- "$needle" "$file"; then
    bad "$label"
  else
    pass "$label"
  fi
}

# require_row_in <file> <exit-code> <must-contain-substring> <label> — anchors an
# assertion to the table ROW whose first cell is exactly "`<exit-code>`" (line
# starts with "| `<code>` "), not to the phrase anywhere in the document. A
# phrase-anywhere check cannot tell "this exit code's row says X" from "X
# happens to appear somewhere else in the file".
require_row_in() {
  file="$1"
  code="$2"
  needle="$3"
  label="$4"
  if [ ! -r "$file" ]; then
    bad "$label (file unreadable: $file)"
    return
  fi
  prefix="| \`${code}\` "
  # ADV-C77: `{ print; exit }` stops at the FIRST matching row, so a stale duplicate row left
  # behind by a future table edit would be silently validated against whichever copy happens to
  # come first, never flagged. Count matches before extracting; more than one is itself a failure.
  _rr_n="$(awk -v p="$prefix" 'index($0, p) == 1 { c++ } END { print c + 0 }' "$file")"
  if [ "$_rr_n" -gt 1 ]; then
    bad "$label ($_rr_n rows start with '$prefix', want exactly 1 — a stale duplicate row?)"
    return
  fi
  row="$(awk -v p="$prefix" 'index($0, p) == 1 { print; exit }' "$file")"
  if [ -z "$row" ]; then
    bad "$label (no row starts with '$prefix')"
    return
  fi
  case "$row" in
    *"$needle"*) pass "$label" ;;
    *) bad "$label (row found but missing '$needle': $row)" ;;
  esac
}

# require_absent_repo <needle> <label> <dir...> — greps recursively for <needle>
# across the given directories and passes ONLY when it is genuinely absent
# (grep exit 1 = no match). grep exit >=2 (e.g. a directory that does not
# exist) is a BROKEN check, not proof of absence — treating every nonzero
# status as "absent" would make a typo'd/missing directory silently pass (T1).
require_absent_repo() {
  needle="$1"
  label="$2"
  shift 2
  grep -rlF -- "$needle" "$@" > /dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "$label"
  elif [ "$rc" -eq 1 ]; then
    pass "$label"
  else
    bad "$label (grep errored, exit $rc — checked dir(s) may not exist: $*)"
  fi
}

require_text() {
  needle="$1"
  label="$2"
  if grep -qF -- "$needle" "$SKILL"; then
    pass "$label"
  else
    bad "$label"
  fi
}

# ── prose contract (strings the pipeline and other suites key on) ─────────────
# The step used to be headed "LOCAL COVERAGE GATE" and to spell out four separate
# fix-and-rerun loops. It is now one command with one verdict, so the contract is the
# command and its terminal states -- a heading is a name, and naming it here again would
# just re-break this test the next time the step is renamed.
require_text "~/.zuvo/verify-tests" "skill runs verification through the single-verdict helper"
require_text "BUDGET EXHAUSTED" "the helper owns the stop condition, not the agent's judgement"
require_text "every public entry point" "gate inventories every public entry point"
require_text "test-file:line" "gate requires line-level test evidence"
require_text "Uncovered owned rows: 0" "gate has a deterministic zero-gap condition"
require_text "Q7=1 and Q11=1" "critical error and branch gates are fail-closed"
require_text "BLOCKED_INCOMPLETE" "incomplete local evidence has a non-success state"
require_text "BLOCKED_INFRA" "reviewer infrastructure failure has a non-success state"
require_text "WRITE-TESTS COMPLETE" "completion report remains explicitly gated"

# ── executable-gate contract ──────────────────────────────────────────────────
require_text "test-coverage-gate.py" "skill invokes the executable validator"
require_text "reviewer-preflight.sh" "skill preflights reviewer infrastructure in Phase 0"
require_text "Production Surface Inventory" "skill has an inventory step"
require_text "INVENTORY FROZEN" "inventory is frozen with printed metrics"
require_text "zuvo:test-audit" "final quality audit dispatches the real test-audit skill"
require_text "Tier A" "final audit targets tier A with fix-in-run"
require_text "Do not run \`tsc\` yourself" "skill forbids the ad-hoc project-wide typecheck"

if [ -f "$ROOT/scripts/test-coverage-gate.py" ] && [ -x "$ROOT/scripts/test-coverage-gate.py" ]; then
  pass "scripts/test-coverage-gate.py exists and is executable"
else
  bad "scripts/test-coverage-gate.py exists and is executable"
fi

if [ -f "$ROOT/scripts/reviewer-preflight.sh" ] && [ -x "$ROOT/scripts/reviewer-preflight.sh" ]; then
  pass "scripts/reviewer-preflight.sh exists and is executable"
else
  bad "scripts/reviewer-preflight.sh exists and is executable"
fi

# The executable-bit checks above prove the files are there and runnable in principle, but not
# that they PARSE — a syntax-breaking edit to either would only surface at runtime, past this
# suite. Prove they at least parse: a python3 -m py_compile / bash -n failure must FAIL this suite.
# ast.parse, not `python3 -m py_compile`: py_compile's CLI has no in-memory/discard mode (its own
# cfile="/dev/null" path refuses on purpose — "will be changed into a regular one" — and its
# default writes a .pyc into scripts/__pycache__/ on every run of this suite). ast.parse proves the
# exact same thing (a syntax error raises) with no side effect on the tree.
_pyerr="$(python3 -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1])' \
  "$ROOT/scripts/test-coverage-gate.py" 2>&1)"
if [ $? -eq 0 ]; then
  pass "scripts/test-coverage-gate.py parses (python3 ast.parse)"
else
  bad "scripts/test-coverage-gate.py fails to parse (python3 ast.parse): $_pyerr"
fi

_bnerr="$(bash -n "$ROOT/scripts/reviewer-preflight.sh" 2>&1)"
if [ $? -eq 0 ]; then
  pass "scripts/reviewer-preflight.sh parses (bash -n)"
else
  bad "scripts/reviewer-preflight.sh fails to parse (bash -n): $_bnerr"
fi

for inc in test-inventory-protocol coverage-manifest-schema test-reviewer-routing test-bugfix-protocol test-mutation-probes; do
  if [ -f "$ROOT/shared/includes/$inc.md" ]; then
    pass "shared/includes/$inc.md exists"
  else
    bad "shared/includes/$inc.md exists"
  fi
done

# ── content contract for the four EXISTENCE-only includes above (test-reviewer-routing.md is
#    excluded — it already gets deep, row-anchored checks below via $ROUTING). Each of these four
#    could be emptied and the loop above would still pass; anchor to specific section headings and
#    required field names read from the files themselves, so an emptied file fails HERE.
INVPROTO="$ROOT/shared/includes/test-inventory-protocol.md"
require_text_in "$INVPROTO" "## Step 1.6 — Build and freeze the inventory (BEFORE the test contract)" \
  "test-inventory-protocol.md: Step 1.6 heading"
require_text_in "$INVPROTO" "## Step 1.7 — Validate the freeze" \
  "test-inventory-protocol.md: Step 1.7 heading"
require_text_in "$INVPROTO" "## Split rule for large files (mandatory, not advisory)" \
  "test-inventory-protocol.md: split-rule heading"
require_text_in "$INVPROTO" "## Step 2.5 — Map tests to the FROZEN inventory" \
  "test-inventory-protocol.md: Step 2.5 heading"
require_text_in "$INVPROTO" "public entry points:" \
  "test-inventory-protocol.md: freeze summary names public entry points"
require_text_in "$INVPROTO" "owned branch rows:" \
  "test-inventory-protocol.md: freeze summary names owned branch rows"
require_text_in "$INVPROTO" "owned error paths:" \
  "test-inventory-protocol.md: freeze summary names owned error paths"

SCHEMADOC="$ROOT/shared/includes/coverage-manifest-schema.md"
require_text_in "$SCHEMADOC" "## Location" "coverage-manifest-schema.md: Location heading"
require_text_in "$SCHEMADOC" "## Schema" "coverage-manifest-schema.md: Schema heading"
require_text_in "$SCHEMADOC" '"schema": "zuvo-coverage-manifest/v1"' \
  "coverage-manifest-schema.md: schema field name pinned"
require_text_in "$SCHEMADOC" '"production_sha256"' "coverage-manifest-schema.md: production_sha256 field pinned"
require_text_in "$SCHEMADOC" '"quality_gates"' "coverage-manifest-schema.md: quality_gates field pinned"
require_text_in "$SCHEMADOC" '"status": "inventory|final"' "coverage-manifest-schema.md: status field pinned"
require_text_in "$SCHEMADOC" '### `verification` — the receipt (required at `status: final`)' \
  "coverage-manifest-schema.md: verification-receipt heading"
require_text_in "$SCHEMADOC" "## Exit codes (act on them, never reinterpret)" \
  "coverage-manifest-schema.md: exit-codes heading"
require_text_in "$SCHEMADOC" "## Non-negotiables" "coverage-manifest-schema.md: non-negotiables heading"

BUGFIXPROTO="$ROOT/shared/includes/test-bugfix-protocol.md"
require_text_in "$BUGFIXPROTO" "## Disposition is fix-SCOPE, not severity" \
  "test-bugfix-protocol.md: disposition heading"
require_text_in "$BUGFIXPROTO" "## Characterization-first (keeps Step 2 green without lying)" \
  "test-bugfix-protocol.md: characterization-first heading"
require_text_in "$BUGFIXPROTO" "## Stacked-commit structure (preserves characterization purity)" \
  "test-bugfix-protocol.md: stacked-commit heading"
require_text_in "$BUGFIXPROTO" "## After the fix" "test-bugfix-protocol.md: after-the-fix heading"
require_text_in "$BUGFIXPROTO" "**Commit 1**" "test-bugfix-protocol.md: Commit 1 named"
require_text_in "$BUGFIXPROTO" "**Commit 2**" "test-bugfix-protocol.md: Commit 2 named"

MUTPROBES="$ROOT/shared/includes/test-mutation-probes.md"
require_text_in "$MUTPROBES" "## First: is a real mutation runner already configured here?" \
  "test-mutation-probes.md: native-runner-detection heading"
require_text_in "$MUTPROBES" "## When" "test-mutation-probes.md: When heading"
require_text_in "$MUTPROBES" "## Probe classes" "test-mutation-probes.md: probe-classes heading"
require_text_in "$MUTPROBES" "## Protocol (byte-restore, no git commands)" \
  "test-mutation-probes.md: protocol heading"
require_text_in "$MUTPROBES" "## Recording" "test-mutation-probes.md: recording heading"
require_text_in "$MUTPROBES" "MUTATION PROBES:" "test-mutation-probes.md: recording format names MUTATION PROBES"
require_text_in "$MUTPROBES" "native:" "test-mutation-probes.md: recording format names the native-runner score"

# ── ordering: the inventory step must precede the write step ──────────────────
inv_line="$(grep -nF 'Step 1.6: Production Surface Inventory' "$SKILL" | head -1 | cut -d: -f1)"
write_line="$(grep -nF '### Step 2: Write' "$SKILL" | head -1 | cut -d: -f1)"
if [ -n "$inv_line" ] && [ -n "$write_line" ] && [ "$inv_line" -lt "$write_line" ]; then
  pass "inventory (Step 1.6) precedes writing (Step 2) in the pipeline"
else
  bad "inventory (Step 1.6) precedes writing (Step 2) in the pipeline (inv=$inv_line write=$write_line)"
fi

# ── eval corpus: small controller regression (id 3) ───────────────────────────
if python3 - "$EVALS" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

matching = [case for case in data["evals"] if case["id"] == 3]
if len(matching) != 1:
    raise SystemExit(1)

case = matching[0]
joined = " ".join(case["assertions"]).lower()
required = (
    "every public controller method",
    "test-file:line",
    "outputs no write-tests complete",
)
if not all(term in joined for term in required):
    raise SystemExit(1)
PY
then
  pass "eval corpus contains the multi-method controller regression"
else
  bad "eval corpus contains the multi-method controller regression"
fi

# ── eval corpus: realistic 22-method controller with artifact assertions (id 4)
if python3 - "$EVALS" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

matching = [case for case in data["evals"] if case["id"] == 4]
if len(matching) != 1:
    raise SystemExit(1)

case = matching[0]

# The fixture must be the realistic surface: 20+ public methods including the
# indirectly-called and the easy-to-miss ones, fire-and-forget, catch-fallback.
fixtures = case.get("fixtures", [])
if len(fixtures) != 1:
    raise SystemExit(1)
content = fixtures[0]["content"]
for marker in ("buildExportRow", "verifyWebhookSignature", "healthcheck",
               "void this.audit.record", "syncProfile", "syncProfiles",
               "summary", "summarize"):
    if marker not in content:
        raise SystemExit(1)
import re
methods = re.findall(r"^  (?:async \*?|)([a-zA-Z]\w*)\(", content, re.M)
public_methods = [m for m in methods if m != "constructor"]
if len(public_methods) < 20:
    raise SystemExit(1)

# Assertions must grade disk artifacts, not only transcript vibes.
joined = " ".join(case["assertions"]).lower()
required = (
    "uncovered owned rows: 0",
    "coverage.json",
    "before creating any test file",
    "sibling spec",
    "mutation probes",
    "outputs no write-tests complete",
)
if not all(term in joined for term in required):
    raise SystemExit(1)
PY
then
  pass "eval corpus contains the realistic large-controller eval with artifact assertions"
else
  bad "eval corpus contains the realistic large-controller eval with artifact assertions"
fi

# ── Plan B Task 9: Step 3.5 runs the blind-audit panel, no routing condition ──

# T2: require_text_in / require_absent_in must FAIL CLOSED on a missing or
# unreadable file, never a vacuous pass because grep's "no such file" exit
# code reads the same as its "no match" exit code. Proven with a path that is
# guaranteed not to exist. The probes' own expected FAIL is captured into a
# local flag and discarded (fail is restored) BEFORE the meta pass/bad call,
# so a real regression in the helper still fails the whole suite. Each probe's
# stdout is silenced (> /dev/null): a passing suite must never print a line
# starting with "FAIL:" — run-all output, triage greps and humans read it
# literally — so only the meta pass/bad lines below are allowed to print.
# ADV-C75: the precondition check must run — and its bad(), if it fires, must stick — BEFORE
# _prior_fail is captured. The old order captured _prior_fail FIRST, then let a precondition
# failure's bad() set the real $fail, only to immediately overwrite it with `fail=0` for the probe
# and then discard it entirely at the final `fail="$_prior_fail"` restore — silently swallowing a
# genuine precondition failure instead of surfacing it in the suite's own verdict.
_missing="$ROOT/tests/skill-suite/.nonexistent-task9-selftest"
if [ -e "$_missing" ]; then
  bad "T2 self-test precondition: $_missing must not exist"
fi

_prior_fail="$fail"
fail=0
require_text_in "$_missing" "anything" "probe (expected FAIL — proves fail-closed on a missing file)" > /dev/null
_probe1_failed=$fail

fail=0
require_absent_in "$_missing" "anything" "probe (expected FAIL — proves fail-closed on a missing file)" > /dev/null
_probe2_failed=$fail

fail="$_prior_fail"

if [ "$_probe1_failed" -eq 1 ]; then
  pass "require_text_in fails closed on a missing file (not a vacuous pass)"
else
  bad "require_text_in fails closed on a missing file (not a vacuous pass)"
fi
if [ "$_probe2_failed" -eq 1 ]; then
  pass "require_absent_in fails closed on a missing file (not a vacuous pass)"
else
  bad "require_absent_in fails closed on a missing file (not a vacuous pass)"
fi

# require_absent_repo must FAIL (not vacuously pass) when grep cannot even run
# its search (a missing directory: grep exit >=2), the same discipline as
# above applied to a repo-wide `grep -r` instead of a single-file grep. Same
# capture-and-restore pattern; probe's own stdout silenced.
# ADV-C75: same fix as the T2 block above — precondition first, _prior_fail captured after.
_missing_dir="$ROOT/tests/skill-suite/.nonexistent-task9-dir"
if [ -e "$_missing_dir" ]; then
  bad "self-test precondition: $_missing_dir must not exist"
fi

_prior_fail="$fail"
fail=0
require_absent_repo "anything" "probe (expected FAIL — proves a grep error is not treated as absence)" "$_missing_dir" > /dev/null
_probe3_failed=$fail

fail="$_prior_fail"

if [ "$_probe3_failed" -eq 1 ]; then
  pass "require_absent_repo fails (not a vacuous pass) when the searched directory does not exist"
else
  bad "require_absent_repo fails (not a vacuous pass) when the searched directory does not exist"
fi

# --production/--test must be inside the SAME code block as the primary
# `--mode blind-audit` invocation, not just present anywhere in the doc. The
# literal `--mode blind-audit \` (trailing backslash, no --provider on the
# same line) matches ONLY that invocation line — the out-of-band "panel of
# one" block reads `--mode blind-audit --provider <candidate> \` instead, so
# this anchor cannot accidentally match it. The block is scanned with awk
# from the anchor line to the CLOSING code fence (not a fixed `grep -A4`
# window): a fixed window silently stops "seeing" the block once it grows
# past 4 lines, which would false-fail this check the next time the
# invocation gains a line, for a reason that has nothing to do with the
# actual doc contract.
# ADV-C76: require the anchor to be found INSIDE an open code fence, not just anywhere in the
# file. The anchor string is a highly specific multi-token literal unlikely to appear outside the
# intended block today, but nothing previously stopped a future prose mention of the same flag
# combination (e.g. describing it outside a fence) from being mistaken for the real invocation.
_mode_anchor='--mode blind-audit \'
if grep -qF -- "$_mode_anchor" "$ROUTING"; then
  pass "test-reviewer-routing.md has the primary --mode blind-audit invocation line"
  _mode_block="$(awk -v anchor="$_mode_anchor" '
    { if ($0 ~ /^```/) { if (found) { print; exit } in_fence = !in_fence; next } }
    found { print; next }
    in_fence && index($0, anchor) > 0 { found = 1; print; next }
  ' "$ROUTING")"
  case "$_mode_block" in
    *'--production'*) pass "test-reviewer-routing.md: --production is inside the --mode blind-audit code block" ;;
    *) bad "test-reviewer-routing.md: --production is inside the --mode blind-audit code block" ;;
  esac
  case "$_mode_block" in
    *'--test'*) pass "test-reviewer-routing.md: --test is inside the --mode blind-audit code block" ;;
    *) bad "test-reviewer-routing.md: --test is inside the --mode blind-audit code block" ;;
  esac
else
  bad "test-reviewer-routing.md has the primary --mode blind-audit invocation line"
  bad "test-reviewer-routing.md: --production is inside the --mode blind-audit code block"
  bad "test-reviewer-routing.md: --test is inside the --mode blind-audit code block"
fi

# skills/write-tests/SKILL.md — outcome table keys off the panel's own line,
# not off routing; the Bash call is given enough headroom to outlive the driver.
require_text_in "$SKILL" '`Audit panel: strict` + `CLEAN`' \
  "SKILL.md Step 3.5 table: strict panel + CLEAN -> clean:strict"
require_text_in "$SKILL" '`Audit panel: degraded` + `CLEAN`' \
  "SKILL.md Step 3.5 table: degraded panel + CLEAN -> clean:degraded"
require_absent_in "$SKILL" "routing ok" \
  "SKILL.md Step 3.5 table no longer says 'routing ok'"
require_absent_in "$SKILL" "degraded routing" \
  "SKILL.md Step 3.5 table no longer says 'degraded routing'"
require_text_in "$SKILL" "timeout: 600000" \
  "SKILL.md Step 3.5 Bash call carries timeout: 600000"
require_text_in "$SKILL" "wait for the completion notification and read the output file" \
  "SKILL.md Step 3.5: a background move is wait-and-read, never BLOCKED_INFRA"
require_text_in "$SKILL" "never above 585" \
  "SKILL.md Step 3.5: whole-run deadline documented as never above 585s (D6)"
require_text_in "$SKILL" "Driver exit / verdict | What happens (Step 4)" \
  "SKILL.md Step 3.5 table header names what the columns hold (E5.1)"
require_text_in "$SKILL" "its own verdict then follows" \
  "SKILL.md Step 3.5: exit 1/2/124 rows route the fallback auditor's own verdict through the verdict rows, with a path to Step 4 (E5.2)"
require_text_in "$SKILL" "the RE-RUN's exit is then handled by this same table" \
  "SKILL.md Step 3.5 exit table row 125: the re-run's own exit is handled by this same table (E4)"
require_text_in "$SKILL" "the out-of-band check also finds nothing" \
  "SKILL.md Step 3.5: preflight no-provider/canary-failed counts only once the out-of-band check also finds nothing, matching the routing doc (E5.3)"

# shared/includes/test-reviewer-routing.md — panel invocation replaces the
# lane-agent table and the fresh-subprocess wrapper. Exit-table assertions are
# anchored to their ROW (require_row_in), never to a phrase anywhere in the
# doc, so exit 124's row must itself say "fall back" and exit 125's row must
# itself say "re-run" (T3) rather than those words merely occurring somewhere.
require_text_in "$ROUTING" "--mode blind-audit" \
  "test-reviewer-routing.md names adversarial-review --mode blind-audit"
require_row_in "$ROUTING" 0 "strict" \
  "test-reviewer-routing.md exit table row 0 (strict)"
require_row_in "$ROUTING" 3 "degraded" \
  "test-reviewer-routing.md exit table row 3 (degraded)"
require_row_in "$ROUTING" 2 "no valid panel answer" \
  "test-reviewer-routing.md exit table row 2"
require_row_in "$ROUTING" 1 "no provider lane" \
  "test-reviewer-routing.md exit table row 1"
require_row_in "$ROUTING" 124 "fall back" \
  "test-reviewer-routing.md exit table row 124 says fall back (D1/D2)"
require_row_in "$ROUTING" 125 "re-run" \
  "test-reviewer-routing.md exit table row 125 says re-run (D1)"
require_row_in "$ROUTING" 125 "handled by this" \
  "test-reviewer-routing.md exit table row 125: the re-run's own exit is handled by this same table (E4)"
require_row_in "$ROUTING" 5 "unauditable" \
  "test-reviewer-routing.md exit table row 5"
require_row_in "$ROUTING" 6 "byte cap" \
  "test-reviewer-routing.md exit table row 6"
require_absent_in "$ROUTING" "reviewer_lane=review-primary" \
  "test-reviewer-routing.md: old lane->agent table (reviewer_lane=review-primary) is gone"
require_absent_in "$ROUTING" "Canonical fresh-subprocess fallback" \
  "test-reviewer-routing.md: Canonical fresh-subprocess fallback section is gone"
require_absent_in "$ROUTING" "Known client health" \
  "test-reviewer-routing.md: Known client health table is gone"
require_absent_in "$ROUTING" "Gemini 3.1 Pro (High)" \
  "test-reviewer-routing.md: stale Gemini 3.1 Pro (High) default is gone"
require_absent_in "$ROUTING" '-p "$(cat /tmp/blind-in.txt)"' \
  "test-reviewer-routing.md: hand-rolled agy -p \"\$(cat /tmp/blind-in.txt)\" block is gone"
require_text_in "$ROUTING" 'ZUVO_BASE="$(~/.zuvo/zuvo-base)"' \
  "test-reviewer-routing.md resolves \$ZUVO_BASE via ~/.zuvo/zuvo-base"
require_text_in "$ROUTING" "also documents the pre-1.6.72 fallback" \
  "test-reviewer-routing.md: env-compat.md (not the helper) documents the pre-1.6.72 fallback (D7)"
require_text_in "$ROUTING" "On exit 0/3 print the merged block's second line" \
  "test-reviewer-routing.md: the Audit panel: line is only printed on exit 0/3 (D5)"
require_text_in "$ROUTING" "On exit 2 stdout is EMPTY" \
  "test-reviewer-routing.md: exit 2 has no merged-block line to print (D5)"
require_text_in "$ROUTING" '[ -n "$ZUVO_BASE" ] ||' \
  "test-reviewer-routing.md: ZUVO_BASE resolver is followed by an empty-value guard (E1)"
require_text_in "$ROUTING" "~/.zuvo/zuvo-base --why" \
  "test-reviewer-routing.md: the guard's message names ~/.zuvo/zuvo-base --why (E1)"

# shared/includes/cross-provider-review.md — same guard, same env-compat.md
# pointer as test-reviewer-routing.md (E1). The pointer was lost when the
# now-resolved B-zuvo-base-fallback-in-two-includes backlog entry was deleted.
require_text_in "$CROSSPROV" '[ -n "$ZUVO_BASE" ] ||' \
  "cross-provider-review.md: ZUVO_BASE resolver is followed by an empty-value guard (E1)"
require_text_in "$CROSSPROV" "~/.zuvo/zuvo-base --why" \
  "cross-provider-review.md: the guard's message names ~/.zuvo/zuvo-base --why (E1)"
require_text_in "$CROSSPROV" "also documents the pre-1.6.72 fallback" \
  "cross-provider-review.md: env-compat.md fallback pointer restored, same words as test-reviewer-routing.md (E1)"

# D3/D4 vocabulary: the fallback's VERDICT uses the normal clean:degraded/fix/
# rewrite values; only the retrospective panel= field says HOW it was reached
# (fallback:same-vendor). The old degraded:same-vendor compound token and the
# "genuinely cross-model — not clean:degraded" contradiction must be gone
# everywhere under skills/ and shared/, not just in this one file.
require_absent_repo "degraded:same-vendor" \
  "no 'degraded:same-vendor' string remains anywhere in skills/ or shared/ (D3)" \
  "$ROOT/skills" "$ROOT/shared"
require_absent_repo "genuinely cross-model — not" \
  "no 'genuinely cross-model -- not clean:degraded' contradiction remains (D4)" \
  "$ROOT/skills" "$ROOT/shared"

# shared/includes/blind-coverage-audit.md — assertions target the NEW "Panel
# merge" section itself, not the pre-existing "Audit mode: strict" template
# line (T5): that line already existed before Task 9 and proves nothing about
# this round's work. The anti-echo template row check is kept as a regression
# guard that the new section did not corrupt the fenced block above it.
require_text_in "$BLIND" "## Panel merge" \
  "blind-coverage-audit.md has the new Panel merge section (T5)"
require_text_in "$BLIND" "Audit panel: strict|degraded valid=<k>/<m>" \
  "blind-coverage-audit.md documents the panel-merge Audit panel: line"
require_text_in "$BLIND" "never produces this line itself" \
  "blind-coverage-audit.md: a single auditor never emits the Audit panel: line itself"
require_text_in "$BLIND" '| B1 | branch | 18-24 | owned | FULL | file.test.ts:42-58 | verifies empty guard |' \
  "blind-coverage-audit.md anti-echo template row is intact (regression guard)"

# shared/includes/retrospective.md — blind_audit telemetry line reports the
# panel outcome, not a single provider name. Both copies of the line (the
# Field-5 template and the Markdown Emit template) must be byte-identical,
# carry the D3 vocabulary (fallback:same-vendor, none), and point to the
# routing doc for the panel/rows/exit rules — that prose now LIVES in
# test-reviewer-routing.md (moved out to keep this file inside the
# tests/adversarial/test-retro-enum-contract.sh T2.4 line budget: BASE 315 +
# BUDGET 15 = 330; check it here too so a future addition can't silently blow
# that budget again without this suite catching it first).
_retro_blind_lines="$(grep '^blind_audit:' "$RETRO")"
_retro_blind_count="$(printf '%s\n' "$_retro_blind_lines" | grep -c '^blind_audit:')"
if [ "$_retro_blind_count" -eq 2 ]; then
  pass "retrospective.md has exactly 2 blind_audit: template lines"
  _retro_l1="$(printf '%s\n' "$_retro_blind_lines" | sed -n '1p')"
  _retro_l2="$(printf '%s\n' "$_retro_blind_lines" | sed -n '2p')"
  if [ "$_retro_l1" = "$_retro_l2" ]; then
    pass "retrospective.md's two blind_audit: template lines are byte-identical (D3)"
  else
    bad "retrospective.md's two blind_audit: template lines are byte-identical (D3)"
  fi
else
  bad "retrospective.md has exactly 2 blind_audit: template lines (found $_retro_blind_count)"
fi
require_text_in "$RETRO" "panel=<strict|degraded|fallback:same-vendor|none>" \
  "retrospective.md blind_audit panel field includes fallback:same-vendor and none (D3)"
require_absent_in "$RETRO" "FULL=<N> PARTIAL=<N> NONE=<N>" \
  "retrospective.md blind_audit line no longer carries the per-file FULL/PARTIAL/NONE tally"
require_text_in "$RETRO" '# panel/rows/exit: test-reviewer-routing.md "Retro blind_audit: fields"' \
  "retrospective.md blind_audit line points to the routing doc for the panel/rows/exit rules"
_retro_lines_now="$(wc -l < "$RETRO" | tr -d ' ')"
if [ "$_retro_lines_now" -le 330 ]; then
  pass "retrospective.md stays <= 330 lines ($_retro_lines_now) — the test-retro-enum-contract.sh T2.4 budget"
else
  bad "retrospective.md stays <= 330 lines (found $_retro_lines_now — over the test-retro-enum-contract.sh T2.4 budget)"
fi

# shared/includes/test-reviewer-routing.md — the panel/rows/exit rules the
# retrospective line points to now live here, next to the invocation itself.
require_text_in "$ROUTING" 'Retro `blind_audit:` fields' \
  "test-reviewer-routing.md has the Retro blind_audit: fields subsection (E2/E3 moved here)"
require_text_in "$ROUTING" "is N from the audit output's own" \
  "test-reviewer-routing.md: rows= is sourced from whichever audit output exists, not just the merged block (E2)"
require_text_in "$ROUTING" "fallback auditor's block on \`fallback:same-vendor\`" \
  "test-reviewer-routing.md: rows= also covers the fallback auditor's block (same protocol, same line) (E2)"
require_text_in "$ROUTING" "it is the RE-RUN's exit" \
  "test-reviewer-routing.md: exit= after a 125 re-run is the re-run's own exit (E3)"
require_text_in "$ROUTING" "for a fallback it is the driver exit that" \
  "test-reviewer-routing.md: exit= for a fallback is the driver exit that triggered it (E3)"

# shared/includes/model-registry.sh — "Sourced by" comment must not claim the
# now-thin blind-audit-codex.sh wrapper still sources this file directly.
require_absent_in "$MODELREG" \
  "Sourced by: adversarial-review.sh, benchmark.sh, blind-audit-codex.sh, and scripts/lib/model-subprocess.sh" \
  "model-registry.sh 'Sourced by' comment no longer lists blind-audit-codex.sh as a direct sourcer"

exit "$fail"
