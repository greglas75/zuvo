---
name: backlog
description: >
  Manage the project's tech debt backlog. Add, list, fix, wontfix, delete,
  prioritize, and suggest batch actions on tracked issues. Used by audit
  and review skills to persist findings, and directly by users to manage
  accumulated debt. Modes: list [category], add [description], fix B-{N},
  wontfix B-{N} [reason], delete B-{N}, stats, prioritize, suggest.
---

# zuvo:backlog — Tech Debt Management

Add, list, and manage backlog items. The backlog tracks technical debt discovered by audit skills, review agents, and manual entries.

**Backlog location:** `memory/backlog.md` in the project root. If `memory/` does not exist, create it. If the file does not exist, create it from the template at the bottom of this skill.

**Scope:** Managing the tech debt backlog -- viewing, adding, resolving, prioritizing, and suggesting batch actions.
**Out of scope:** Actually fixing the issues (use `zuvo:fix-tests`, `zuvo:refactor`, or the suggested command from `suggest` mode).

## Argument Parsing

| Input | Action |
|-------|--------|
| _(empty)_ or `list` | Show all OPEN items as a summary table |
| `list category:[x]` | Show OPEN items filtered by category (code/test/arch/dep/doc/infra) |
| `list all` | Show all items including RESOLVED and WONTFIX |
| `add` | Interactive: ask what to add, then append |
| `add [description]` | Parse natural language description, add to backlog |
| `fix B-{N}` | Mark item as RESOLVED |
| `wontfix B-{N} [reason]` | Mark item as WONTFIX with reason |
| `delete B-{N}` | Remove item (show details, ask confirmation) |
| `delete B-{N} --force` | Remove without confirmation |
| `delete all-resolved` | Remove all RESOLVED + WONTFIX items (ask confirmation) |
| `stats` | Show counts by severity and category |
| `prioritize` | Score and rank all OPEN items by urgency |
| `suggest` | Group items by pattern, propose batch fix commands |

---

## Run Logging

Read `../../shared/includes/run-logger.md` for log format and file path resolution.
Read `../../shared/includes/retrospective.md` for log format and file path resolution.

## CodeSift Integration

Read `../../shared/includes/codesift-setup.md` for initialization.

**Key tools for this skill:**

| Command | Task | CodeSift tool | Fallback |
|---------|------|--------------|----------|
| suggest | Find undiscovered TODO/FIXME debt | `search_text(repo, query="TODO\|FIXME\|HACK", regex=true)` | Grep |
| suggest | Context around TODO markers | `find_and_show(repo, query=<function>, include_refs=true)` | Read the file |
| prioritize | Count references to affected function | `find_references(repo, symbol_name=<fn>)` | Skip (score from description only) |
| prioritize | Blast radius of recent items | `impact_analysis(repo, since="HEAD~10", depth=2)` | Skip |
| fix | Find related code when planning a fix | `search_symbols(repo, query=<keyword>)` | Grep |
| fix | Batch-read related functions | `get_symbols(repo, symbol_ids=[...])` | Multiple Read calls |

---

## Backlog Schema

All interactions use these columns:

| Column | Description | Set by |
|--------|-------------|--------|
| ID | `B-{N}` sequential | Auto |
| Status | OPEN, RESOLVED, WONTFIX | Auto (default: OPEN) |
| Fingerprint | Dedup key (see format below) | Auto |
| File | File path | Required |
| Problem | Short description | Required |
| Severity | CRITICAL, HIGH, MEDIUM, LOW | Required |
| Category | Code, Test, Architecture, Dependency, Documentation, Infrastructure | Required |
| Source | Which skill added it | Auto |
| Seen | Occurrence count | Auto |
| Added | Date first added (YYYY-MM-DD) | Auto |

### Fingerprint Formats

- From audit skills: `file|rule_id|signature` (e.g., `auth.service.ts|cq8|missing-try-catch`)
- From test audit: `file|pattern_id|signature` (e.g., `auth.test.ts|p-41|loading-only`)
- Manual add: `file|manual|first-3-words-slugified` (e.g., `auth.ts|manual|missing-rate-limiting`)

All fingerprint components are lowercase, trimmed, with leading `./` stripped from paths.

### Listing View (compact)

Default view shows: `ID | Severity | File | Problem | Seen`

---

## Adding Items

When adding (interactive or from description):

1. Read the current `memory/backlog.md`
2. Determine the next `B-{N}` ID
3. If natural language input, extract:
   - **File** (ask if not apparent from description)
   - **Problem** (short description)
   - **Severity** (infer from keywords -- see inference rules)
   - **Category** (infer from file path)
4. Compute fingerprint per the schema format
5. Dedup check: search the Fingerprint column for a match
   - Match found: increment Seen count, keep highest severity, update date. Do NOT create a duplicate.
   - No match: append new row with all schema columns
6. Confirm what was added

### Batch Add

If the user provides multiple issues (numbered list, bullets, or comma-separated), add them all in one pass. Show a summary table for confirmation before writing.

### Auto-Inference Rules

Do not ask per-item for batch adds. Infer missing fields:

- **Severity:** `race condition`, `security`, `data loss` -> HIGH. `any type`, `missing test` -> MEDIUM. `typo`, `naming` -> LOW.
- **Category:** `*.test.*` -> Test. `*.service.*`, `*.controller.*` -> Code. `docker*`, `*.yml` -> Infrastructure.
- **Source:** `manual`
- **Seen:** 1
- **Added:** today's date

---

## Resolving Items

`fix` and `wontfix` mark the status column -- they do not delete the row. This preserves decision history.

- `fix B-{N}`: verify exists (error if not), set Status to RESOLVED
- `wontfix B-{N} [reason]`: verify exists, set Status to WONTFIX, append reason to Problem column
- `delete B-{N}`: verify exists, show item details, ask "Delete? (y/n)". With `--force`, skip confirmation.
- `delete all-resolved`: count RESOLVED + WONTFIX items, show count, ask confirmation, then remove matching rows

**Growth control:** When RESOLVED + WONTFIX items exceed 50, prune the oldest RESOLVED items. Keep WONTFIX indefinitely (they document decisions).

---

## Listing Items

Default (`list`): show OPEN items only.

```
TECH DEBT BACKLOG -- [project name]
-----
| ID   | Severity | File                    | Problem                  | Seen |
|------|----------|-------------------------|--------------------------|------|
| B-1  | MEDIUM   | auth.service.ts         | catch(err: any)          | 3x   |
| B-2  | HIGH     | payout.service.ts       | Race condition in claim  | 1x   |
-----
OPEN: X items (C: _, H: _, M: _, L: _)
```

---

## Stats

```
BACKLOG STATS
-----
OPEN:      X items
  CRITICAL:  _
  HIGH:      _
  MEDIUM:    _
  LOW:       _

By category:
  Code: _  Test: _  Architecture: _
  Dependency: _  Documentation: _  Infrastructure: _

Top files (by item count, top 5):
  1. services/payout.service.ts (3 items)
  2. handlers/webhook.ts (2 items)
-----
```

---

## Prioritize

Score each OPEN item to produce a ranked list. The scoring formula:

```
Priority Score = (Impact + Risk) x (6 - Effort)
```

| Dimension | 1 | 3 | 5 |
|-----------|---|---|---|
| Impact | Rarely slows work | Sometimes blocks development | Slows the team every day |
| Risk | Nice to have | Regressions possible | Security or data loss risk |
| Effort | Multiple days | About a week | A month or more |

Score range: 2 (low priority) to 50 (fix immediately).

**CodeSift-enhanced scoring:** When indexed, use `find_references(repo, symbol_name=<function>)` to count callers. Higher reference count means larger blast radius, which increases Impact and Risk scores.

Output:

```
PRIORITIZED BACKLOG
-----
| Rank | ID   | Score | Impact | Risk | Effort | Problem               |
|------|------|-------|--------|------|--------|-----------------------|
| 1    | B-2  | 40    | 5      | 5    | 2      | Race condition payout |
| 2    | B-1  | 24    | 4      | 4    | 3      | catch(err: any)       |
-----
```

---

## Suggest

Analyze all OPEN items by pattern and propose batch actions.

**CodeSift-enhanced discovery:** Before analyzing existing items, scan for undiscovered debt:
- `search_text(repo, query="TODO|FIXME|HACK|WORKAROUND", regex=true)` to find inline markers not yet tracked
- Cross-reference with existing fingerprints to avoid duplicates
- If CodeSift unavailable, analyze only existing backlog items

### Pattern Matching

| Condition | Suggested action |
|-----------|-----------------|
| 3+ items with the same CQ gate failure | `zuvo:code-audit [files]` or direct batch fix |
| 3+ items from test-audit with same pattern ID | `zuvo:fix-tests --pattern [ID] [path]` |
| 3+ items in the same module | `zuvo:refactor [module]` |
| 5+ low-tier items | `zuvo:code-audit --deep [path]` |
| No OPEN items | "Backlog is clear. Consider a periodic audit." |

If multiple patterns match the same items, show all matching suggestions.

Output:

```
BACKLOG SUGGESTIONS
-----
Pattern: CQ8=0 in 5 files          -> zuvo:code-audit src/services/
Pattern: P-41 in 4 test files       -> zuvo:fix-tests --pattern P-41 src/
Hotspot: offer.service.ts (6 items) -> zuvo:refactor src/offer/offer.service.ts
-----
```

---

## Error Handling

| Situation | Response |
|-----------|----------|
| `fix B-99` but B-99 not found | "B-99 not found. Run `zuvo:backlog list` to see current items." |
| `list` but backlog is empty | "Backlog is empty. Use `zuvo:backlog add` to track issues." |
| `add` with vague description (no file) | Ask for file path and specific problem |
| `prioritize` with 0-1 items | "Only N item(s) -- no ranking needed." |
| `suggest` with 0 items | "Backlog is clear. Consider scheduling a periodic audit." |

---

## Tech Debt Categories

| Alias | Category | Examples |
|-------|----------|----------|
| code | Code | Duplicated logic, magic numbers, any-types |
| arch | Architecture | Wrong data store, monolith boundaries |
| test | Test | Low coverage, flaky tests, missing integration tests |
| dep | Dependency | Outdated libraries, CVEs, unmaintained packages |
| doc | Documentation | Missing runbooks, outdated READMEs |
| infra | Infrastructure | Manual deploys, no monitoring, missing IaC |

---

## Completion

After completing any action, print:

```
BACKLOG COMPLETE
-----
Action: [list | add | fix | wontfix | delete | stats | prioritize | suggest]
Run: <ISO-8601-Z>	backlog	<project>	-	-	<VERDICT>	-	<DURATION>	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
-----
```


### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

`<DURATION>`: use the action label (`list`, `add`, `fix`, `wontfix`, `delete`, `stats`, `prioritize`, or `suggest`).

---

## Backlog Template

When `memory/backlog.md` does not exist, create it from this template:

```markdown
# Tech Debt Backlog

> Maintained by zuvo:review, zuvo:build, zuvo:code-audit, zuvo:test-audit, zuvo:write-tests, zuvo:fix-tests, zuvo:backlog.

| ID | Status | Fingerprint | File | Problem | Severity | Category | Source | Seen | Added |
|----|--------|-------------|------|---------|----------|----------|--------|------|-------|
```
