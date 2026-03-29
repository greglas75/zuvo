# Implementation Plan: Audit-to-Fix Pipeline & SEO Audit Modernization

**Spec:** docs/specs/2026-03-28-audit-fix-pipeline-spec.md
**Created:** 2026-03-28
**Tasks:** 7
**Estimated complexity:** 5 standard, 2 complex

## Architecture Summary

6 files across 3 phases. All markdown/prompt engineering — no production code, no test framework.

- **Phase 1:** Parallel agent dispatch in seo-audit (3 new agent files + SKILL.md refactor)
- **Phase 2:** JSON output alongside markdown (audit-output-schema.md + SKILL.md Phase 6 addition)
- **Phase 3:** New seo-fix skill (single SKILL.md + router update)

Data flow: `seo-audit SKILL.md` dispatches 3 agents → merges findings → writes `.md` + `.json` → `seo-fix SKILL.md` reads `.json` → applies fixes by safety tier → reports + backlog.

Files modified: `skills/seo-audit/SKILL.md` (refactored)
Files created: `skills/seo-audit/agents/seo-technical.md`, `seo-content.md`, `seo-assets.md`, `shared/includes/audit-output-schema.md`, `skills/seo-fix/SKILL.md`
Files updated: `skills/using-zuvo/SKILL.md` (1 routing entry)

## Technical Decisions

- **Single-agent seo-fix** (not 4 agents) — follows fix-tests pattern, sequential safety tiers don't benefit from parallelism
- **Inline template registry** in seo-fix SKILL.md — ~120 lines, keeps cohesion, avoids 5-file framework-fixes/ directory
- **3 agent groups** per spec: Technical (D1,D4,D5,D11,D12,D13), Content (D7,D9,D10), Assets (D2,D3,D6,D8)
- **Shared audit-output-schema.md** — enables zuvo-wide JSON adoption by other audits
- **No new dependencies** — all patterns exist in codebase (multi-agent dispatch, backlog protocol, env-compat)

## Quality Strategy

- **No CQ gates** — markdown project, no production code
- **No TDD** — no test framework, no runtime
- **Verification = spec compliance + cross-file consistency:**
  1. All 13 dimensions D1-D13 assigned exactly once across 3 agents
  2. JSON schema fields match between audit-output-schema.md, seo-audit Phase 6, and seo-fix Phase 0
  3. Template registry fix_types match across: registry table, safety classification, parameter schema
  4. Agent input/output format matches dispatcher expectations
  5. Existing markdown report format unchanged (backward compatible)
- **Highest risk:** seo-fix template registry alignment (3 tables must agree)
- **Second risk:** seo-audit Phase 4 merge logic (3 agent outputs → unified findings)

## Agent count

7 dispatched agents across plan(3: architect, tech-lead, qa-engineer + 1: plan-reviewer) + execute(3: implementer, quality-reviewer, spec-reviewer).

---

## Task Breakdown

### Task 1: Create shared audit-output-schema.md
**Files:** `shared/includes/audit-output-schema.md` (new)
**Complexity:** standard
**Dependencies:** none
**Model routing:** Sonnet

**Description:** Define the zuvo-wide JSON schema for audit output. This is the contract between seo-audit (producer) and seo-fix + CI (consumers).

**Content to write:**

```markdown
# Audit Output Schema (v1.0)

> Standard JSON output format for zuvo audit skills.
> Produced alongside markdown reports in `audit-results/`.

## File naming

`audit-results/[skill-name]-YYYY-MM-DD.json`

Auto-increment with `-N` suffix if same-day file exists.

## Required fields (every audit skill)

| Field | Type | Description |
|-------|------|-------------|
| `version` | string | Schema version, e.g. "1.0" |
| `skill` | string | Skill name, e.g. "seo-audit" |
| `timestamp` | string | ISO 8601 with timezone, e.g. "2026-03-28T14:30:00Z" |
| `project` | string | Absolute path to project root |
| `args` | string | Arguments passed to the audit |
| `stack` | string | Detected tech stack |
| `result` | string | "PASS" or "FAIL" |
| `score.overall` | number | 0-100 |
| `score.tier` | string | "A", "B", "C", "D", or "FAIL" |
| `critical_gates` | array | [{ id, name, status, evidence }] |
| `findings` | array | [{ id, dimension, check, status, severity, priority, evidence, file, line }] |

## Optional fields (fix-capable audits)

| Field | Type | Description |
|-------|------|-------------|
| `score.sub_scores` | object | Skill-specific sub-scores (e.g. seo, geo, tech) |
| `findings[].fix_type` | string | Maps to downstream fix skill template |
| `findings[].fix_safety` | string | "SAFE", "MODERATE", or "DANGEROUS" |
| `findings[].fix_params` | object | Framework-specific parameters for the fix template |
| `summary` | object | Aggregated counts: findings_count, quick_wins, fixable |

## Example (seo-audit)

[Include the full JSON example from spec lines 163-212]

## Versioning

- Adding optional fields = minor bump (1.1) — backward compatible
- Changing required fields = major bump (2.0) — old files ignored by consumers
```

- [ ] Write: Create `shared/includes/audit-output-schema.md` with the content above, including the full JSON example from the spec
- [ ] Verify: `grep -c "Required\|Optional\|version\|skill\|timestamp\|findings" shared/includes/audit-output-schema.md` — expected: 10+
- [ ] Verify: JSON example in file is valid — extract with `grep -A 50 '```json' shared/includes/audit-output-schema.md | head -50 | python3 -c "import sys,json; json.load(sys.stdin)"`
- [ ] Commit: "add zuvo-wide audit output JSON schema (v1.0) for CI gates and fix skill consumption"

---

### Task 2: Create seo-audit agent — seo-technical.md
**Files:** `skills/seo-audit/agents/seo-technical.md` (new)
**Complexity:** standard
**Dependencies:** none
**Model routing:** Sonnet

**Description:** Agent instruction file for Group A (Technical): D1 (meta tags), D4 (sitemap), D5 (crawlers), D11 (security), D12 (i18n), D13 (monitoring).

**Structure to follow (from spec agent template):**

```markdown
# Agent: SEO Technical (Group A)

## Setup
- Read codesift-setup.md (discover tools independently)
- Do NOT re-detect stack — receive detected stack from dispatcher

## Input (from dispatcher)
- detected_stack: string (astro | nextjs | hugo | wordpress | react | html)
- file_paths: string[] (config files, robots.txt, head templates)
- codesift_repo: string | null

## Dimensions to evaluate
D1 — Meta Tags and On-Page SEO
D4 — Sitemap
D5 — AI Crawlers and Crawlability
D11 — Security and Technical
D12 — Internationalization
D13 — Monitoring

## Checks per dimension
[For each dimension, list the specific checks from seo-audit SKILL.md Phase 2]

## Output format
For each dimension:
  - dimension_id: string (e.g. "D1")
  - score: number (0-100)
  - checks_total: number
  - checks_passed: number
  - findings: Finding[]

Each Finding:
  - id: string (temporary, main agent assigns final sequential IDs)
  - dimension: string
  - check: string
  - status: "PASS" | "PARTIAL" | "FAIL"
  - severity: "HIGH" | "MEDIUM" | "LOW"
  - seo_impact: 1-3
  - business_impact: 1-3
  - effort: 1-3
  - priority: number (calculated)
  - evidence: string
  - file: string | null
  - line: number | null
  - fix_type: string (from template registry)
  - fix_safety: "SAFE" | "MODERATE" | "DANGEROUS"
  - fix_params: object
```

- [ ] Write: Create `skills/seo-audit/agents/seo-technical.md` — copy the dimension check details from seo-audit SKILL.md sections D1, D4, D5, D11, D12, D13 into the agent's "Checks per dimension" section
- [ ] Verify: `grep -c "^D[0-9]" skills/seo-audit/agents/seo-technical.md` — expected: 6 (D1, D4, D5, D11, D12, D13)
- [ ] Verify: `grep "fix_type\|fix_safety\|fix_params" skills/seo-audit/agents/seo-technical.md | wc -l` — expected: 3+
- [ ] Commit: "add seo-technical agent for parallel audit of D1, D4, D5, D11, D12, D13"

---

### Task 3: Create seo-audit agents — seo-content.md and seo-assets.md
**Files:** `skills/seo-audit/agents/seo-content.md` (new), `skills/seo-audit/agents/seo-assets.md` (new)
**Complexity:** standard
**Dependencies:** Task 2 (follow same structure)
**Model routing:** Sonnet

**Description:** Two more agent files following the same template as Task 2.

**seo-content.md:** Group B — D7 (internal linking), D9 (content quality), D10 (GEO readiness)
- Input: detected stack, content directory paths, page list
- Checks: word counts, heading hierarchy, answer-first structure, llms.txt, E-E-A-T signals, freshness

**seo-assets.md:** Group C — D2 (OG/social), D3 (JSON-LD), D6 (images), D8 (performance)
- Input: detected stack, layout/template paths, asset paths
- Checks: OG tags, twitter:card, JSON-LD presence/SSR, image alt/lazy/format, font loading, bundle size

- [ ] Write: Create `skills/seo-audit/agents/seo-content.md` with D7, D9, D10 checks
- [ ] Write: Create `skills/seo-audit/agents/seo-assets.md` with D2, D3, D6, D8 checks
- [ ] Verify: `grep -c "^D[0-9]" skills/seo-audit/agents/seo-content.md` — expected: 3 (D7, D9, D10)
- [ ] Verify: `grep -c "^D[0-9]" skills/seo-audit/agents/seo-assets.md` — expected: 4 (D2, D3, D6, D8)
- [ ] Verify: All 13 dimensions covered — `grep -h "^D[0-9]" skills/seo-audit/agents/*.md | sort -t'D' -k2 -n | uniq | wc -l` — expected: 13
- [ ] Commit: "add seo-content (D7,D9,D10) and seo-assets (D2,D3,D6,D8) agents for parallel audit"

---

### Task 4: Refactor seo-audit SKILL.md — Phase 2 agent dispatch + Phase 6 JSON output
**Files:** `skills/seo-audit/SKILL.md` (modified)
**Complexity:** complex
**Dependencies:** Task 1 (schema), Task 2-3 (agents)
**Model routing:** Opus

**Description:** Two modifications to the existing seo-audit SKILL.md:

**4a. Phase 2 refactor — agent dispatch:**

Replace the current Phase 2 (sequential 13-dimension audit) with parallel agent dispatch:

```markdown
## Phase 2: Code Audit (Parallel Agent Dispatch)

Dispatch 3 agents in parallel. Each agent evaluates its assigned dimensions independently.

### Agent dispatch

Refer to `../../shared/includes/env-compat.md` for dispatch patterns.

**Claude Code:** Use the Agent tool to run all three in parallel:

Agent 1: SEO Technical (Group A)
  model: "sonnet"
  type: "Explore"
  instructions: [read agents/seo-technical.md]
  input: detected_stack, config file paths, codesift_repo

Agent 2: SEO Content (Group B)
  model: "sonnet"
  type: "Explore"
  instructions: [read agents/seo-content.md]
  input: detected_stack, content directory paths, codesift_repo

Agent 3: SEO Assets (Group C)
  model: "sonnet"
  type: "Explore"
  instructions: [read agents/seo-assets.md]
  input: detected_stack, layout/template paths, codesift_repo

**Codex / Cursor:** Follow env-compat.md fallback patterns.

### Merge logic

After all agents complete:
1. Concatenate findings arrays from all 3 agents
2. Assign sequential finding IDs (F1, F2, F3, ...)
3. Each agent returns dimension scores — pass through unchanged to Phase 4
4. If an agent fails: log error, proceed with available results, note gap
```

**4b. Phase 6 addition — JSON output:**

After the existing Phase 6 markdown report section, add:

```markdown
### Phase 6.2: JSON Output

After saving the markdown report, also save structured JSON:

File: `audit-results/seo-audit-YYYY-MM-DD.json`

Schema: see `../../shared/includes/audit-output-schema.md`

Serialize the following from Phase 4 scoring results:
- version: "1.0"
- skill: "seo-audit"
- timestamp: current ISO 8601
- project: working directory
- args: parsed arguments from Phase 0
- stack: detected stack from Phase 0
- result: "PASS" or "FAIL" (from critical gate evaluation)
- score: { overall, tier, sub_scores: { seo, geo, tech } }
- critical_gates: all 6 gates with status and evidence
- findings: all findings with fix_type, fix_safety, fix_params populated
- summary: { findings_count, quick_wins, fixable }

Auto-increment filename with `-N` suffix if same-day file exists.
```

**Important:** Phases 0, 1, 3, 4, 5, 7 must remain UNCHANGED. Only Phase 2 body and Phase 6 get additions.

- [ ] Write: Refactor Phase 2 in `skills/seo-audit/SKILL.md` — replace sequential dimension checks with agent dispatch pattern
- [ ] Write: Add Phase 6.2 (JSON output) after existing Phase 6 markdown section
- [ ] Verify: `grep -c "^## Phase [01345]" skills/seo-audit/SKILL.md` — expected: 5 (unchanged phases still present)
- [ ] Verify: `grep "Agent 1\|Agent 2\|Agent 3" skills/seo-audit/SKILL.md | wc -l` — expected: 3
- [ ] Verify: `grep "seo-technical\|seo-content\|seo-assets" skills/seo-audit/SKILL.md | wc -l` — expected: 3+
- [ ] Verify: `grep "audit-output-schema.md" skills/seo-audit/SKILL.md` — expected: 1+ (references schema)
- [ ] Verify: `grep "\.json" skills/seo-audit/SKILL.md | grep "audit-results"` — expected: 1+ (JSON output path)
- [ ] Commit: "refactor seo-audit Phase 2 for parallel agent dispatch + add JSON output in Phase 6"

---

### Task 5: Create seo-fix SKILL.md
**Files:** `skills/seo-fix/SKILL.md` (new)
**Complexity:** complex
**Dependencies:** Task 1 (schema), Task 4 (JSON output)
**Model routing:** Opus

**Description:** The new seo-fix skill. Single file, ~370 lines. Reads audit JSON, applies fixes by safety tier.

**Full structure:**

```markdown
---
name: seo-fix
description: >
  Apply fixes from seo-audit findings. Reads audit JSON, classifies fixes by
  safety tier (SAFE/MODERATE/DANGEROUS), applies templates per framework.
  Supports Astro, Next.js, Hugo. Modes: default (SAFE only), --auto (SAFE+MODERATE),
  --all (all tiers, requires confirmation), --dry-run, --finding F1,F3, --category sitemap.
---

# zuvo:seo-fix — Apply SEO Audit Fixes

[Copy Phase 0-5 content from spec Phase 3 section, including:]
- Phase 0: Load Findings (locate JSON, validate age, print summary)
- Phase 1: Detect Framework & Targets (stack detection, template registry, safety classification, fix params schema)
- Phase 2: Apply Fixes (SAFE auto → MODERATE with validation → DANGEROUS report-only)
- Phase 3: Verify (build check, critical gate re-check)
- Phase 4: Report (fix report format)
- Phase 5: Update Backlog (fingerprint dedup, backlog protocol)

[Include these tables from spec:]
- Template Registry (22 rows)
- Safety classification per framework (11 rows)
- Fix Parameters Schema (11 rows)

[Include mandatory file loading checklist:]
1. shared/includes/codesift-setup.md
2. shared/includes/env-compat.md
3. shared/includes/backlog-protocol.md

[Include safety gates:]
- GATE 1: DANGEROUS fixes require --all flag + user confirmation
- GATE 2: Build verification after fixes
```

- [ ] Write: Create `skills/seo-fix/SKILL.md` with all 6 phases from the spec
- [ ] Verify: Template registry completeness — `grep -E "sitemap-add|json-ld-add|meta-og-add|robots-fix|llms-txt-add|headers-add|canonical-fix|font-display-add|lang-attr-add|alt-text-add|viewport-add" skills/seo-fix/SKILL.md | wc -l` — expected: 20+ (each appears in multiple tables)
- [ ] Verify: Safety tiers in correct order — `grep -n "SAFE fixes\|MODERATE fixes\|DANGEROUS fixes" skills/seo-fix/SKILL.md` — SAFE line < MODERATE line < DANGEROUS line
- [ ] Verify: All 3 tables present — `grep -c "Template Registry\|Safety classification\|Fix Parameters Schema" skills/seo-fix/SKILL.md` — expected: 3
- [ ] Verify: Backlog protocol referenced — `grep "backlog-protocol.md" skills/seo-fix/SKILL.md` — expected: 1+
- [ ] Verify: JSON field names match schema — `grep "fix_type\|fix_safety\|fix_params" skills/seo-fix/SKILL.md | wc -l` — expected: 10+
- [ ] Commit: "add zuvo:seo-fix skill — audit-to-fix pipeline with 3-tier safety model"

---

### Task 6: Register seo-fix in using-zuvo router
**Files:** `skills/using-zuvo/SKILL.md` (modified)
**Complexity:** standard
**Dependencies:** Task 5
**Model routing:** Sonnet

**Description:** Add seo-fix to the routing table in Priority 2 (Task skills), after `zuvo:fix-tests`.

**Change:** Add one row to the Priority 2 Task table:

```markdown
| Fix SEO audit findings, apply SEO fixes | `zuvo:seo-fix` |
```

- [ ] Write: Add the routing entry to `skills/using-zuvo/SKILL.md` in the Priority 2 table
- [ ] Verify: `grep "seo-fix" skills/using-zuvo/SKILL.md` — expected: 1+
- [ ] Verify: Entry is in Priority 2 section — `grep -B 5 "seo-fix" skills/using-zuvo/SKILL.md | grep "Priority 2\|Task"` — expected: match
- [ ] Commit: "register zuvo:seo-fix in skill router (Priority 2 — Task)"

---

### Task 7: Cross-file consistency verification
**Files:** all 6 files from Tasks 1-6
**Complexity:** standard
**Dependencies:** Tasks 1-6
**Model routing:** Sonnet

**Description:** Final verification pass. No new files created. Run all cross-file consistency checks.

- [ ] Verify: All 13 dimensions covered across 3 agents — `grep -h "^D[0-9]" skills/seo-audit/agents/*.md | sort | uniq | wc -l` — expected: 13
- [ ] Verify: No dimension appears in 2+ agents — `grep -h "^D[0-9]" skills/seo-audit/agents/*.md | sort | uniq -d` — expected: empty
- [ ] Verify: JSON schema doc field names match seo-audit Phase 6 output — compare `grep '"[a-z_]*"' shared/includes/audit-output-schema.md` with `grep '"[a-z_]*"' skills/seo-audit/SKILL.md`
- [ ] Verify: seo-fix fix_types match between template registry, safety table, and params schema — run diff on extracted fix_type lists from all 3 tables
- [ ] Verify: seo-fix reads correct JSON path — `grep "audit-results/seo-audit" skills/seo-fix/SKILL.md` — expected: 1+
- [ ] Verify: seo-audit writes correct JSON path — `grep "audit-results/seo-audit.*\.json" skills/seo-audit/SKILL.md` — expected: 1+
- [ ] Verify: Agent instruction files reference codesift-setup.md — `grep -l "codesift-setup" skills/seo-audit/agents/*.md | wc -l` — expected: 3
- [ ] Verify: Backward compatibility — existing Phase 0, 1, 3, 4, 5 headers unchanged in seo-audit SKILL.md
- [ ] Commit: "verify cross-file consistency across audit-fix pipeline (all checks pass)"
