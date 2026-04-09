# Retrospective Feedback Loop — Design Specification

> **spec_id:** 2026-04-09-retrospective-feedback-loop-1345
> **topic:** Structured agent retrospective after skill execution for systematic skill quality improvement
> **status:** Reviewed
> **created_at:** 2026-04-09T13:45:00Z
> **approved_at:** null
> **approval_mode:** interactive
> **author:** zuvo:brainstorm

## Problem Statement

After 8 iterations of `write-tests` on `app.ts`, four independent adversarial agents produced feedback. Their retrospective insights (process friction, missing templates, skill gaps) were **more valuable than 4 passes of adversarial code review**. But this feedback was ad-hoc, manual, and one-time — the insights are lost after the session.

The root cause: adversarial review evaluates the **artifact** (is this code good?), but retrospective evaluates the **process** (what was hard? what was missing in the skill?). Only the executing agent has subjective experience of the task — what it tried and abandoned, where it got stuck, what template it had to invent from scratch. This experience data is currently discarded.

**Specific observed gaps from the app.ts session:**
1. No agent identified that `vi.hoisted` log array template was missing — they described the *category* of problem (ordering tests) but not the *specific pattern* that solves it
2. Agents produce rules ("test middleware order") but not templates (the actual code to do it) — the same gap that caused testing-slim's quality regression (5/10 vs 9/10)
3. Multi-agent debate returns variations of mainstream feedback; unique insights (like caller analysis) come from one agent and get outvoted

**Without this system:** skill improvements are based on intuition ("I think we need more templates"). **With this system:** measurable evidence that change X reduces friction Y across N sessions.

## Design Decisions

### D1: Hybrid output (TSV + markdown)

**Chosen:** Each retrospective produces both a TSV line (to `~/.zuvo/retros.log`) and a markdown block (appended to `~/.zuvo/retros.md`).

**Why:** TSV gives instant frequency analysis via `cut | sort | uniq -c`. Markdown captures the nuance, specific templates, and concrete change proposals that TSV can't encode. The TSV is the metric, the markdown is the evidence.

**Rejected:** TSV-only (loses nuance — can't encode "I invented vi.hoisted log array from scratch"). Markdown-only (requires LLM pass or manual reading to aggregate patterns across 50+ sessions).

### D2: Opt-in per skill via shared include

**Chosen:** New `shared/includes/retrospective.md` referenced by each participating SKILL.md in its Mandatory File Loading section. Initial rollout to 8 execution skills.

**Why:** Matches existing include pattern (like `adversarial-loop.md`). No central list to maintain. Each skill opts in by adding one line. The retrospective template is execution-biased ("what template was missing?") — audit skills would need different questions, so opt-in prevents bad data from ill-fitting skills.

**Rejected:** Global injection into all 49 skills (produces garbage retros for checklist-style audits where template questions don't apply). Threshold-only filtering (60s/5 tool calls doesn't distinguish execution from audit work).

### D3: Single global files with PROJECT field

**Chosen:** `~/.zuvo/retros.log` (TSV) and `~/.zuvo/retros.md` (markdown) are global, not per-project. Each entry includes a PROJECT field for filtering.

**Why:** Cross-project analysis is where the strongest signal emerges. "ORCHESTRATOR mock strategy" appearing in retros from 3 different projects = systemic skill gap, not project-specific. Same design as `runs.log`.

### D4: Manual consumption

**Chosen:** No auto-aggregation skill. User greps/cuts the log manually and decides what to optimize.

**Why:** At this stage, the priority is collecting high-quality data. Auto-aggregation can be added later (e.g., `zuvo:retro --skill-quality` flag) once 30+ retros prove the data is valuable.

### D5: Retrospective before terminal block, not inside it

**Chosen:** The retrospective section executes as a new step immediately before the skill's terminal output block (`BUILD COMPLETE`, `WRITE-TESTS COMPLETE`, etc.). The `RETRO:` TSV line is emitted alongside the `Run:` line but appended to a separate file.

**Why:** The `Run:` line format is frozen (11-field TSV, backward compatible). Retrospective data doesn't fit the existing schema. Separate file joinable via `SKILL+PROJECT+SHA7` (SHA7 is constant within a session since no commit happens between retro and run log).

### D6: Evidence-grounded reflection, not summary

**Chosen:** Every retrospective question requires a concrete artifact reference (file path, error message, phase number, tool call count). Answers without artifact references are flagged as generic and don't count toward the minimum-1 requirement.

**Why:** Mirrors adversarial-loop.md evidence standard (no `file:line` = downgrade to INFO). Prevents "everything was clear" syndrome. The Reflexion framework research confirms: anchoring reflection to concrete artifacts outperforms open-ended prompts.

**Anti-pattern explicitly prohibited:** "Do not summarize what you did. Reflect on the experience of doing it." Status reports ("tested 11 functions, 19/19 Q gates") are not retrospectives.

## Solution Overview

```
Skill execution completes
        │
        ▼
┌─────────────────────────┐
│  Retrospective Step     │  ← same agent, same context
│  (shared include)       │
│                         │
│  1. Fill 6 structured   │
│     questions            │
│  2. Emit RETRO: TSV     │
│     → retros.log        │
│  3. Emit markdown block │
│     → retros.md         │
└─────────────────────────┘
        │
        ▼
┌─────────────────────────┐
│  Terminal block          │
│  (BUILD COMPLETE etc.)  │
│  Run: line → runs.log   │
└─────────────────────────┘
```

The retrospective is executed by the **same agent** that just completed the task — this is critical. A post-hoc agent reading the transcript can reconstruct *what happened* but not *what was hard* or *what the agent tried and abandoned*. Subjective experience markers require the original executor.

## Detailed Design

### New File: `shared/includes/retrospective.md`

The shared include loaded by participating skills. Contains:

#### Gate Check

```
IF the task was trivial (agent's subjective assessment: fewer than ~5 distinct
tool calls used during the task, or the work took under ~1 minute of effort):
  SKIP retrospective entirely
  PRINT: "RETRO: skipped (trivial session)"
```

**Measurement approach:** The agent uses its own subjective estimate — no external metrics infrastructure required. This is an honest approximation: agents can reliably distinguish "I ran 3 tool calls" from "I spent 15 minutes iterating on mock strategy." If in doubt, write the retro — a slightly noisy entry is better than a lost data point.

#### Structured Questions (6 fields)

Each question has:
- A **prompt** (what to answer)
- A **grounding requirement** (must reference specific artifact)
- A **minimum** (at least 1 non-empty answer required for fields 1-4)

| # | Field | Prompt | Grounding |
|---|-------|--------|-----------|
| 1 | `unclear` | What instruction or section in the skill did you have to interpret or guess? | Must reference a phase number, section name, or include file |
| 2 | `missing_context` | What information did you need but had to discover yourself? | Must reference a file path, framework behavior, or dependency |
| 3 | `most_turns` | Which sub-task consumed the most iterations? What would have prevented it? | Must include a count (turns, attempts, or minutes) |
| 4 | `missing_template` | What code pattern did you need but had to invent from scratch? | Must include the pattern name or a 1-line description of what it does |
| 5 | `worked_well` | What in the skill saved you time or prevented mistakes? | May reference specific include, phase, or template |
| 6 | `change_proposal` | ONE specific edit to ONE specific file. Format: `FILE: / SECTION: / CONTENT: / RATIONALE:` | Must be actionable — "improve docs" is rejected |

**Enforcement:** At least 1 of fields 1-4 must have a non-empty, artifact-grounded answer. Field 5 is encouraged but optional. Field 6 (change proposal) is always required and must use the `FILE: / SECTION: / CONTENT: / RATIONALE:` format.

**Explicit prohibition:** "Sections that just describe the end result will be rejected. Each answer must reference a specific moment of friction or insight during the task, not a property of the final artifact."

**Structural grounding check:** Each non-empty answer in fields 1-4 MUST contain at least one of: a file path with extension (e.g., `app.ts`), a phase/step number (e.g., `Phase 3`), or a numeric count (e.g., `6 turns`). Answers without any of these tokens are treated as empty and don't count toward the minimum-1 requirement. This converts subjective grounding into a parseable constraint.

#### TSV Output

After filling the structured questions, emit a single TSV line:

```
RETRO: DATE\tSKILL\tPROJECT\tCODE_TYPE\tFRICTION_CATEGORY\tMISSING_TEMPLATE\tCONTEXT_GAP\tTURNS_WASTED\tBRANCH\tSHA7
```

| # | Field | Type | Values |
|---|-------|------|--------|
| 1 | DATE | ISO 8601 UTC | `2026-04-09T13:45:00Z` |
| 2 | SKILL | string | `write-tests` |
| 3 | PROJECT | string | basename of git root |
| 4 | CODE_TYPE | enum | `ORCHESTRATOR` (coordinates 3+ modules/middleware), `DATA_SERVICE` (primary role is data access/transformation), `PURE_FUNCTION` (no side effects, input→output), `UI_COMPONENT` (renders UI, handles user interaction), `CONFIG` (configuration/setup), `MIXED` (multiple types in one file), `OTHER` |
| 5 | FRICTION_CATEGORY | enum | `mock-strategy`, `ordering-template`, `context-missing`, `pipeline-heavy`, `framework-gotcha`, `unclear-instruction`, `no-friction`, `other` |
| 6 | MISSING_TEMPLATE | string (40 char max) | short description or `-` |
| 7 | CONTEXT_GAP | enum | `no-production-code`, `no-schema`, `no-env`, `no-test-fixture`, `no-framework-docs`, `none`, `other` |
| 8 | TURNS_WASTED | integer | estimated turns lost to friction, or `0` |
| 9 | BRANCH | string | current git branch |
| 10 | SHA7 | string | short commit hash |

The `RETRO:` prefix (like `Run:`) triggers file append. Agent appends the line (without prefix) to `~/.zuvo/retros.log`.

#### Markdown Output

Append a section to `~/.zuvo/retros.md`:

```markdown
<!-- RETRO -->

## [DATE] [SKILL] [PROJECT] [TARGET_FILE]

### Unclear
[answer to field 1]

### Missing Context
[answer to field 2]

### Most Turns
[answer to field 3]

### Missing Template
[answer to field 4]

### Worked Well
[answer to field 5]

### Change Proposal
FILE: [path]
SECTION: [where]
CONTENT: [what to add]
RATIONALE: [which problem from above it solves]
```

#### Context Exhaustion Marker

If the session exceeded 200 tool calls, prefix the markdown section header with `[DEGRADED-CONTEXT]` and cap each answer to 2 sentences. This acknowledges that the agent's recall may be impaired after very long sessions.

### Skill Modifications

Add retrospective include reference to the Mandatory File Loading section of these 8 skills:

| Skill | Insert Point | Terminal Block |
|-------|-------------|----------------|
| `build` | After Phase 4.6 (adversarial), before Phase 4.7 (terminal) | `BUILD COMPLETE` |
| `write-tests` | After Step 5 (knowledge curation), before terminal | `WRITE-TESTS COMPLETE` |
| `review` | After knowledge curation, before terminal | `REVIEW COMPLETE` |
| `refactor` | Before `FULL COMPLETE` / `BATCH COMPLETE` | `REFACTOR COMPLETE` |
| `debug` | After Phase 4.5/4.6 (CQ/Q eval), before terminal | `DEBUG COMPLETE` |
| `execute` | After task completion, before terminal | `EXECUTE COMPLETE` |
| `fix-tests` | After pattern fix verification, before terminal | `FIX-TESTS COMPLETE` |
| `write-e2e` | After quality gates, before terminal | `WRITE-E2E COMPLETE` |

Each skill adds one line to its Mandatory File Loading checklist:

```
N. ../../shared/includes/retrospective.md -- RETRO PROTOCOL
```

And one step before its terminal block:

```
## Step N: Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed to terminal block.
```

### Storage

| File | Format | Location | Rotation |
|------|--------|----------|----------|
| `retros.log` | TSV, 10 fields per line | `~/.zuvo/retros.log` | 100 entries max, oldest pruned on write |
| `retros.md` | Markdown, `<!-- RETRO -->` delimited sections | `~/.zuvo/retros.md` | 100 entries max, oldest pruned on write |

**Rotation mechanism:** Before appending, count existing entries. If >= 100, prune the oldest. Follow the same shell pattern as `run-logger.md`:

```bash
# TSV rotation (preserve header, keep last 100 data lines):
LINE_COUNT=$(wc -l < "$RETRO_LOG" 2>/dev/null || echo 0)
if [ "$LINE_COUNT" -gt 101 ]; then
  head -1 "$RETRO_LOG" > "$RETRO_LOG.tmp"
  tail -n 100 "$RETRO_LOG" >> "$RETRO_LOG.tmp"
  mv "$RETRO_LOG.tmp" "$RETRO_LOG"
fi

# Markdown rotation (count entry delimiters):
ENTRY_COUNT=$(grep -c '^<!-- RETRO -->' "$RETRO_MD" 2>/dev/null || echo 0)
if [ "$ENTRY_COUNT" -gt 100 ]; then
  # Keep last 100 entries
  awk '/^<!-- RETRO -->/{c++} c>=(TOTAL-99){print}' TOTAL="$ENTRY_COUNT" "$RETRO_MD" > "$RETRO_MD.tmp" && mv "$RETRO_MD.tmp" "$RETRO_MD"
fi
```

Note: In the markdown file, each entry starts with `<!-- RETRO -->` as a unique delimiter (not `---`, which can appear in change proposal content). There is no schema header in the markdown file (only in retros.log).

**Codex App (cloud):** Falls back to `memory/zuvo-retros.log` and `memory/zuvo-retros.md` using the same detection logic as `run-logger.md`.

### Schema Versioning

First line of `retros.log` is a header comment:

```
# v1 DATE SKILL PROJECT CODE_TYPE FRICTION_CATEGORY MISSING_TEMPLATE CONTEXT_GAP TURNS_WASTED BRANCH SHA7
```

If the schema changes, bump to `v2` and add migration notes to `retrospective.md`. This prevents silent corruption of historical data.

## Edge Cases

| Edge Case | Handling |
|-----------|----------|
| Abandoned session (user cancels mid-task) | No retrospective — gate requires terminal block to be reached |
| Trivial session (<60s or <5 tool calls) | Skip with "RETRO: skipped" message |
| Multi-skill session (write-tests then review) | Each skill writes its own retro entry independently |
| Context exhaustion (>200 tool calls) | `[DEGRADED-CONTEXT]` marker, 2-sentence cap per answer |
| No `~/.zuvo/` directory | Create it (same as run-logger.md) |
| Codex App / cloud environment | Fall back to `memory/` path |
| Retrospective quality decay over time | Evidence grounding requirement prevents template-fill; minimum 1 artifact reference enforced |
| retros.log doesn't exist yet | Create with header comment on first write |
| Privacy (file paths in retros) | Local-only storage, no code snippets, only paths and error types |
| Duplicate retro (same skill+file in 2-min window) | No dedup — each invocation is independent, duplicate data is signal not noise |

## Acceptance Criteria

1. A retrospective entry is written if and only if the skill reaches its terminal output block AND the agent's subjective assessment is that the session was non-trivial (roughly: more than ~5 tool calls or ~1 minute of effort).
2. Each retrospective produces exactly one TSV line in `retros.log` and one markdown section in `retros.md`.
3. The TSV line contains all 10 fields with valid enum values (no free-text in enum columns).
4. At least 1 of fields 1-4 has a non-empty, artifact-grounded answer; field 6 (change proposal) is populated using the required format.
5. Field 6 (change proposal) uses the `FILE: / SECTION: / CONTENT: / RATIONALE:` format.
6. `retros.log` and `retros.md` do not exceed 100 entries; rotation prunes the oldest.
7. When retrospective.md is not loaded by a skill (not in Mandatory File Loading), no retrospective is produced and no error occurs.
8. `retros.log` first line is a version header; schema changes bump the version.
9. Sessions exceeding 200 tool calls produce entries flagged with `[DEGRADED-CONTEXT]`.
10. No retrospective entry contains code snippets or user data values — only file paths, error types, phase numbers, and structured signals.
11. The `RETRO:` TSV line is joinable with `runs.log` via `SKILL+PROJECT+SHA7` (SHA7 is constant within a session).
12. `grep -v '^#' retros.log | cut -f5 | sort | uniq -c | sort -rn` produces a valid frequency ranking of FRICTION_CATEGORY across all collected retros.

## Cost Analysis

### Per-session overhead

| Cost type | Estimate | Notes |
|-----------|----------|-------|
| **Token output** | ~200-300 tokens | 6 structured answers (~150 tok) + TSV line (~30 tok) + markdown formatting (~50 tok) |
| **Token input** | ~800-1000 tokens | Loading `retrospective.md` shared include into context |
| **Agent time** | ~1-2 minutes | Reflection + two file appends (Bash calls) |
| **Tool calls** | 2-3 | One Bash for TSV append, one for markdown append, optional rotation check |
| **Context window** | ~1000 tokens permanently consumed | The include is loaded at Phase 0 and stays in context for the entire session |

### Cumulative overhead per skill run

A typical `write-tests` session costs ~50K-150K tokens total (reading production code, writing tests, adversarial review, etc.). The retrospective adds ~1.5K tokens (input + output) = **~1-3% overhead** on a typical session.

Agent time: a typical session runs 10-20 minutes. Retrospective adds 1-2 minutes = **~5-10% time overhead**.

### Storage cost

| File | Growth rate | Cap | Steady-state size |
|------|-------------|-----|-------------------|
| `retros.log` | ~150 bytes/entry | 100 entries | ~15 KB max |
| `retros.md` | ~500 bytes/entry | 100 entries | ~50 KB max |

Both files combined never exceed ~65 KB. Negligible disk impact.

### Break-even analysis

The retrospective costs ~1.5K tokens per session. One skill optimization driven by retro data (e.g., adding vi.hoisted template to testing.md) saves 8+ turns × ~2K tokens/turn = **~16K tokens per future session** where that friction would have occurred. At 10 sessions affected, the ROI is ~100x the cumulative retro cost.

Even if only 1 in 10 retrospectives leads to an actionable skill improvement, the system pays for itself after ~20 sessions.

## Out of Scope

- **Auto-aggregation skill** — no `zuvo:retro --skill-quality` or automated analysis. Manual grep for now.
- **Post-session hook for objective metrics** — the hook infrastructure exists (Stop hook in settings.local.json) but collecting tool call counts, duration, and test run history requires transcript parsing. Deferred to a future spec after retro data proves valuable.
- **Audit skill retrospectives** — code-audit, test-audit, etc. need different questions. Deferred until execution skill retros are validated.
- **Cross-session trend visualization** — no charts, dashboards, or reports. Raw files only.
- **Retrospective for brainstorm/plan** — design skills have different friction patterns. Deferred.
- **Automatic skill modification based on retro data** — human reads retros, human decides what to change.

## Open Questions

None — all design decisions were resolved during Phase 2 dialogue. Reviewer issues (C4 join key, C6 rotation mechanism, C8 enforcement threshold, C10 gate check metrics) resolved in revision 1. Adversarial issues (header-preserving rotation, `<!-- RETRO -->` delimiter, subjective gate in AC1, AC12 grep fix, structural grounding check, CODE_TYPE definitions) resolved in revision 2.
