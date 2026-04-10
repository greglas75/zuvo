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

Fill these 7 fields. At least 1 of fields 1-4 must be non-empty and artifact-grounded. Field 6 and 7 are always required.

| # | Field | Prompt | Grounding |
|---|-------|--------|-----------|
| 1 | `unclear` | What instruction or section in the skill did you have to interpret or guess? | Must reference a phase number, section name, or include file |
| 2 | `missing_context` | What information did you need but had to discover yourself? | Must reference a file path, framework behavior, or dependency |
| 3 | `most_turns` | Which sub-task consumed the most iterations? What would have prevented it? | Must include a count (turns, attempts, or minutes) |
| 4 | `missing_template` | What code pattern did you need but had to invent from scratch? | Must include the pattern name or a 1-line description |
| 5 | `worked_well` | What in the skill saved you time or prevented mistakes? | May reference specific include, phase, or template |
| 6 | `change_proposals` | Write exactly 5 proposals. Not 1, not 3 — five. Categories: token waste, missing templates, pipeline overhead, false positive rules, missing patterns, include loading, adversarial tuning, gate applicability. Review what you told the user during this session — every insight you shared inline MUST appear here. Each proposal: `FILE: / SECTION: / CONTENT:` with paste-ready code. Include ranking table at the end (token savings + quality impact). | Each must name a file path and include the actual content to add — "add a section about X" is rejected, show the section |
| 7 | `session_cost` | Estimate session costs. Use `/cost` if available, otherwise estimate from activity. | Must include: tool call count, files read, files modified |

**Structural grounding check:** Each non-empty answer in fields 1-4 MUST contain at least one of: a file path with extension (e.g., `app.ts`), a phase/step number (e.g., `Phase 3`), or a numeric count (e.g., `6 turns`). Answers without any of these tokens are treated as empty.

**CRITICAL: Printing answers is NOT enough.** After filling fields 1-7 above, you MUST execute the bash commands in the Append Commands section below to write data to `~/.zuvo/retros.log` and `~/.zuvo/retros.md`. If you skip the bash append, the retrospective is lost. The retro is not done until both files are written.

## TSV Emit

After filling the structured questions, emit a `RETRO:` line and append to the retro log.

### Field Resolution

```bash
PROJECT=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
BRANCH=$(git branch --show-current 2>/dev/null || echo "-")
SHA7=$(git rev-parse --short HEAD 2>/dev/null || echo "-")
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
```

### TSV Format (13 fields, tab-separated)

```
RETRO: DATE\tSKILL\tPROJECT\tCODE_TYPE\tFRICTION_CATEGORY\tMISSING_TEMPLATE\tCONTEXT_GAP\tTURNS_WASTED\tTOOL_CALLS\tFILES_READ\tFILES_MODIFIED\tBRANCH\tSHA7
```

| # | Field | Type | Values |
|---|-------|------|--------|
| 1 | DATE | ISO 8601 UTC | `2026-04-09T13:45:00Z` |
| 2 | SKILL | string | skill name without `zuvo:` prefix |
| 3 | PROJECT | string | basename of git root |
| 4 | CODE_TYPE | enum | `ORCHESTRATOR` (coordinates 3+ modules), `DATA_SERVICE` (data access/transformation), `PURE_FUNCTION` (no side effects), `UI_COMPONENT` (renders UI), `CONFIG` (configuration), `MIXED` (multiple types), `OTHER` |
| 5 | FRICTION_CATEGORY | enum | `mock-strategy`, `ordering-template`, `context-missing`, `pipeline-heavy`, `framework-gotcha`, `unclear-instruction`, `no-friction`, `other` |
| 6 | MISSING_TEMPLATE | string (40 char max) | short description or `-` |
| 7 | CONTEXT_GAP | enum | `no-production-code`, `no-schema`, `no-env`, `no-test-fixture`, `no-framework-docs`, `none`, `other` |
| 8 | TURNS_WASTED | integer | estimated turns lost to friction, or `0` |
| 9 | TOOL_CALLS | integer | total tool calls in session (estimate) |
| 10 | FILES_READ | integer | distinct files read |
| 11 | FILES_MODIFIED | integer | files created or edited |
| 12 | BRANCH | string | current git branch |
| 13 | SHA7 | string | short commit hash |

## Markdown Emit

Append a section to the retro markdown file using this exact template:

```markdown
<!-- RETRO -->

## [DATE] [SKILL] [PROJECT] [TARGET_FILE]

### Unclear
[answer to field 1, or "N/A"]

### Missing Context
[answer to field 2, or "N/A"]

### Most Turns
[answer to field 3, or "N/A"]

### Missing Template
[answer to field 4, or "N/A"]

### Worked Well
[answer to field 5, or "N/A"]

### Session Cost
- **Files read:** N
- **Files modified:** N
- **Tool calls:** N total (Read: N, Edit: N, Bash: N, Grep: N, ...)
- **Test runs:** N (pass: N, fail: N)
- **Adversarial passes:** N
- **Token breakdown:**

| Category | Gross | With cache | Notes |
|----------|-------|------------|-------|
| System prompt + rules + includes | ~NK | ~NK | cached after turn 1 |
| Production code reads | ~NK | ~NK | one-time reads |
| Conversation context (cumulative) | ~NK | ~NK | grows per turn |
| Output total | ~NK | ~NK | not cacheable |

- **Biggest waste:** [what consumed the most tokens for the least value — e.g., "system prompt 15K × 17 turns = 255K gross, but cache reduces to ~50K"]

### Change Proposals (ranked by impact, up to 5)

**1.** FILE: [path] | SECTION: [where]
CONTENT:
```
[paste-ready code or markdown to add — not a description, the actual content]
```
RATIONALE: [which problem from above it solves]

**2.** FILE: [path] | SECTION: [where]
CONTENT:
```
[actual content]
```
RATIONALE: [...]

(continue up to 5 if warranted)

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
  echo "# v1 DATE SKILL PROJECT CODE_TYPE FRICTION_CATEGORY MISSING_TEMPLATE CONTEXT_GAP TURNS_WASTED TOOL_CALLS FILES_READ FILES_MODIFIED BRANCH SHA7" > "$RETRO_LOG"
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
- Field 6 (change proposals) is always required — at least 1, up to 5, ranked by impact. Each must use `FILE: / SECTION: / CONTENT: / RATIONALE:` format
- Field 7 (session cost) is always required with tool call count, files read, files modified, token breakdown table, and biggest waste insight
- No code snippets or user data values in any field — only file paths, error types, phase numbers, and structured signals
