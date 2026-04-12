# Retrospective Protocol

> Shared include — structured agent reflection after execution skill completion.

## Gate Check

```
ALWAYS write the retrospective. The only exception is if you literally did
nothing (e.g., skill aborted immediately, or you ran 1-2 tool calls total).

Do NOT skip because the file was "simple" or the tier was THIN — simple files
often have the most interesting friction (mock strategy, missing templates).
If you have ANY insight about the skill, the tools, or the process — write it.

IF you used more than ~200 tool calls in this session:
  SET degraded_context = true (cap each answer to 2 sentences below)
```

**Do not summarize what you did. Reflect on the experience of doing it.** Status reports are not retrospectives. Each answer must reference a specific moment of friction or insight during the task, not a property of the final artifact.

## Structured Questions

Fill these sections. Fields 1-4: at least 1 must be non-empty and artifact-grounded. Fields 5-9: always required.

### Part A: Friction (at least 1 of fields 1-4 non-empty)

| # | Field | Prompt | Grounding |
|---|-------|--------|-----------|
| 1 | `unclear` | What instruction or section in the skill did you have to interpret or guess? | Must reference a phase number, section name, or include file |
| 2 | `missing_context` | What information did you need but had to discover yourself? | Must reference a file path, framework behavior, or dependency |
| 3 | `most_turns` | Which sub-task consumed the most iterations? What would have prevented it? | Must include a count (turns, attempts, or minutes) |
| 4 | `missing_template` | What code pattern did you need but had to invent from scratch? | Must include the pattern name or a 1-line description |

### Part B: Infrastructure Status (always required)

| # | Field | Fill with |
|---|-------|-----------|
| 5 | `infra_status` | Telemetry block (see template below). Every line is mandatory — write `N/A` or `skipped` for lines that don't apply, never omit a line. |

Telemetry block template (key=value, one per line):
```
platform: <claude|codex|antigravity|cursor> | writer: <model> | reviewer: <model> | routing: <ok|same-model-fallback|unknown-writer-model|routing-failed>
codesift: <indexed(Nsymbols)|not_indexed|transport_closed_after_N|unavailable|N/A>
paths: shared=<ok|missing:file> scripts=<ok|missing:file> rules=<ok|missing:file>
extension_check: <ok|.test.ts->.spec.ts(renamed)|N/A>
blind_audit: <clean:strict|clean:degraded|fix:N|rewrite|skipped|blocked_infra> | provider=<name> | exit=<code> | rows=<N> | FULL=<N> PARTIAL=<N> NONE=<N>
adversarial: pass1=<provider>(NC,NW,NI) [pass2=<provider>(NC,NW,NI)] | cross_provider=<true|false|single_provider> | timeout=<Ns>
q_gates: <N>/19 (Q7=<0|1> Q11=<0|1> Q13=<0|1> Q15=<0|1> Q17=<0|1>)
tests: <N>/<N> pass | extension=<.spec.ts|.test.ts>
status: <PASS|FAILED|BLOCKED_INFRA> | failure_cause=<none|blind-audit-timeout|prod-bug|...>
```

### Part C: Gaps and Proposals (always required)

| # | Field | Fill with |
|---|-------|-----------|
| 6 | `skill_gaps` | Bullet list: what was missing or broken in the skill/includes. Each must name a file or section. |
| 7 | `missing_tools` | Bullet list: what tools/scripts would have helped but don't exist. |
| 8 | `worked_well` | What in the skill saved you time or prevented mistakes? May reference specific include, phase, or template. |
| 9 | `change_proposals` | Write up to 5 proposals. Categories: token waste, missing templates, pipeline overhead, false positive rules, missing patterns, include loading, adversarial tuning, gate applicability, infrastructure. Each: `FILE: / SECTION: / CONTENT:` with paste-ready code. Include ranking table. |

**Structural grounding check:** Each non-empty answer in fields 1-4 MUST contain at least one of: a file path with extension (e.g., `app.ts`), a phase/step number (e.g., `Phase 3`), or a numeric count (e.g., `6 turns`). Answers without any of these tokens are treated as empty.

**CRITICAL: Printing answers is NOT enough.** After filling fields 1-9 above, you MUST execute the bash commands in the Append Commands section below to write data to `~/.zuvo/retros.log` and `~/.zuvo/retros.md`. If you skip the bash append, the retrospective is lost. The retro is not done until both files are written.

## TSV Emit

After filling the structured questions, emit a `RETRO:` line and append to the retro log.

### Field Resolution

```bash
PROJECT=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
BRANCH=$(git branch --show-current 2>/dev/null || echo "-")
SHA7=$(git rev-parse --short HEAD 2>/dev/null || echo "-")
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
```

### TSV Format (17 fields, tab-separated)

```
RETRO: DATE\tSKILL\tPROJECT\tCODE_TYPE\tFRICTION_CATEGORY\tMISSING_TEMPLATE\tCONTEXT_GAP\tTURNS_WASTED\tTOOL_CALLS\tFILES_READ\tFILES_MODIFIED\tBRANCH\tSHA7\tBLIND_AUDIT\tADVERSARIAL\tCODESIFT\tROUTING_STATUS
```

| # | Field | Type | Values |
|---|-------|------|--------|
| 1 | DATE | ISO 8601 UTC | `2026-04-09T13:45:00Z` |
| 2 | SKILL | string | skill name without `zuvo:` prefix |
| 3 | PROJECT | string | basename of git root |
| 4 | CODE_TYPE | enum | `ORCHESTRATOR`, `DATA_SERVICE`, `PURE_FUNCTION`, `UI_COMPONENT`, `CONFIG`, `MIXED`, `OTHER` |
| 5 | FRICTION_CATEGORY | enum | `mock-strategy`, `ordering-template`, `context-missing`, `pipeline-heavy`, `framework-gotcha`, `unclear-instruction`, `skill-overhead`, `missing-pattern`, `false-positive-rule`, `scope-mismatch`, `infra-failure`, `no-friction`, `other`. **`no-friction` is ONLY valid if you have ZERO change proposals.** |
| 6 | MISSING_TEMPLATE | string (40 char max) | short description or `-` |
| 7 | CONTEXT_GAP | enum | `no-production-code`, `no-schema`, `no-env`, `no-test-fixture`, `no-framework-docs`, `none`, `other` |
| 8 | TURNS_WASTED | integer | Count retries, re-reads, false-positive deliberation, missing pattern invention, infra waits |
| 9 | TOOL_CALLS | integer | total tool calls in session (estimate) |
| 10 | FILES_READ | integer | distinct files read |
| 11 | FILES_MODIFIED | integer | files created or edited (include backlog, coverage, ALL touched files) |
| 12 | BRANCH | string | current git branch |
| 13 | SHA7 | string | short commit hash |
| 14 | BLIND_AUDIT | enum | `clean:strict`, `clean:degraded`, `fix:N`, `rewrite`, `skipped`, `blocked_infra`, `not_run` |
| 15 | ADVERSARIAL | enum | `clean`, `Nfindings`, `skipped`, `blocked`, `not_run`, `blocked:prod-bug` |
| 16 | CODESIFT | enum | `indexed`, `transport_closed`, `not_indexed`, `unavailable`, `N/A` |
| 17 | ROUTING_STATUS | enum | `ok`, `same-model-fallback`, `unknown-writer-model`, `routing-failed`, `N/A` |

## Markdown Emit

Append a section to the retro markdown file using this exact template:

```markdown
<!-- RETRO -->

## [DATE] [SKILL] [PROJECT] [TARGET_FILE]

### Telemetry
```
platform: ... | writer: ... | reviewer: ... | routing: ...
codesift: ...
paths: shared=... scripts=... rules=...
extension_check: ...
blind_audit: ... | provider=... | exit=... | rows=... | FULL=... PARTIAL=... NONE=...
adversarial: ... | cross_provider=... | timeout=...
q_gates: .../19 (Q7=... Q11=... Q13=... Q15=... Q17=...)
tests: .../... pass | extension=...
status: ... | failure_cause=...
```

### Friction
- **Unclear:** [field 1, or N/A]
- **Missing context:** [field 2, or N/A]
- **Most turns:** [field 3, or N/A]
- **Missing template:** [field 4, or N/A]

### Skill Gaps
- [bullet per gap — name the file/section that's missing or broken]

### Missing Tools
- [bullet per tool — what would have helped but doesn't exist]

### Worked Well
[field 8]

### Session Cost
- **Files read:** N
- **Files modified:** N
- **Tool calls:** N total (Read: N, Edit: N, Bash: N, ...)
- **Test runs:** N (pass: N, fail: N)
- **Adversarial passes:** N
- **Biggest waste:** [what consumed the most tokens/time for the least value]

### Change Proposals (ranked by impact, up to 5)

**1.** FILE: [path] | SECTION: [where]
CONTENT:
```
[paste-ready code or markdown to add]
```
RATIONALE: [which problem from above it solves]

(continue up to 5)

**Impact ranking:**

| # | Change | Token savings | Quality impact |
|---|--------|---------------|----------------|
| 1 | [short label] | ~NK/session | high/medium/low |
| 2 | ... | ... | ... |
```

If `degraded_context = true`, prefix the H2 header with `[DEGRADED-CONTEXT]` and cap each answer to 2 sentences.

## Append Commands

**Execute all bash variables and commands below in a single shell invocation.** Variables from Path Detection and Field Resolution must be available to the Append blocks.

### Path Detection

```bash
if [ -n "$CODEX_WORKSPACE" ] || ! mkdir -p ~/.zuvo 2>/dev/null || ! test -w ~/.zuvo; then
  RETRO_LOG="memory/zuvo-retros.log"
  RETRO_MD="memory/zuvo-retros.md"
else
  RETRO_LOG="$HOME/.zuvo/retros.log"
  RETRO_MD="$HOME/.zuvo/retros.md"
fi
```

### TSV Append + Rotation

```bash
# Create header if file doesn't exist
if [ ! -f "$RETRO_LOG" ]; then
  echo "# v2 DATE SKILL PROJECT CODE_TYPE FRICTION_CATEGORY MISSING_TEMPLATE CONTEXT_GAP TURNS_WASTED TOOL_CALLS FILES_READ FILES_MODIFIED BRANCH SHA7 BLIND_AUDIT ADVERSARIAL CODESIFT ROUTING_STATUS" > "$RETRO_LOG"
fi

# Append the RETRO: line value (without the RETRO: prefix)
echo "<tsv-line>" >> "$RETRO_LOG"

# Rotation: preserve header, keep last 100 data lines
LINE_COUNT=$(wc -l < "$RETRO_LOG")
if [ "$LINE_COUNT" -gt 101 ]; then
  head -1 "$RETRO_LOG" > "$RETRO_LOG.tmp.$$"
  tail -n 100 "$RETRO_LOG" >> "$RETRO_LOG.tmp.$$"
  mv "$RETRO_LOG.tmp.$$" "$RETRO_LOG"
fi
```

### Markdown Append + Rotation

```bash
# Append the markdown block (fill from the template above)
cat >> "$RETRO_MD" << 'RETRO_EOF'
<!-- RETRO -->

## ...filled template...
RETRO_EOF

# Rotation: keep last 100 entries
ENTRY_COUNT=$(grep -c '^<!-- RETRO -->' "$RETRO_MD" 2>/dev/null || echo 0)
if [ "$ENTRY_COUNT" -gt 100 ]; then
  awk '/^<!-- RETRO -->/{c++} c>=('"$ENTRY_COUNT"'-99){print}' "$RETRO_MD" > "$RETRO_MD.tmp.$$" && mv "$RETRO_MD.tmp.$$" "$RETRO_MD"
fi
```

## Enforcement Rules

- At least 1 of fields 1-4 must have a non-empty, structurally grounded answer (contains file path, phase number, or numeric count)
- Field 5 (infra_status) telemetry block is always required — every line filled, `N/A` for non-applicable
- Field 6 (skill_gaps) is always required — at least 1 bullet or explicit "none found"
- Field 7 (missing_tools) is always required — at least 1 bullet or explicit "none needed"
- Field 9 (change_proposals) is always required — at least 1, up to 5, ranked by impact. Each must use `FILE: / SECTION: / CONTENT: / RATIONALE:` format
- No code snippets or user data values in any field — only file paths, error types, phase numbers, and structured signals
