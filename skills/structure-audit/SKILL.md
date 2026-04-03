---
name: structure-audit
description: >
  Codebase structure and organization audit across 13 dimensions (SA1-SA13):
  directory consistency, naming conventions, folder depth, colocation, barrel
  exports, separation of concerns, file size distribution, dead code, complexity
  distribution, duplication, root organization, documentation, hotspots.
  Tool-driven with CodeSift primary and CLI fallbacks (cloc, knip, dep-cruiser,
  jscpd, eslint, git mining). Flags: full (default), [path], --naming, --size,
  --dead-code, --duplication, --hotspots, --quick, --fix.
---

# zuvo:structure-audit — Codebase Structure & Organization Audit

Quantitative structural health assessment across 13 measurable dimensions. Every finding is backed by tool output or grep evidence -- no subjective opinions without data. Generates a scored report with prioritized action items.

**Scope:** Periodic health checks, pre-refactor reconnaissance, onboarding orientation, post-sprint cleanup, release readiness.
**Out of scope:** Design patterns and SOLID (`zuvo:architecture`), per-file code quality (`zuvo:code-audit`), test quality (`zuvo:test-audit`), runtime performance (`zuvo:performance-audit`).

## Mandatory File Loading

Read these files before any work begins:

1. `{plugin_root}/shared/includes/codesift-setup.md` -- CodeSift discovery and tool selection
2. `{plugin_root}/shared/includes/env-compat.md` -- Agent dispatch and environment adaptation
3. `{plugin_root}/rules/file-limits.md` -- Size limits for SA7 file categorization

Print the checklist:

```
CORE FILES LOADED:
  1. codesift-setup.md   -- [READ | MISSING -> STOP]
  2. env-compat.md       -- [READ | MISSING -> STOP]
  3. file-limits.md      -- [READ | MISSING -> use defaults: 300L service, 200L component]
```

If file 1 or 2 is missing, STOP.

## Environment Compatibility

Read `{plugin_root}/shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

## CodeSift Integration

Read `{plugin_root}/shared/includes/codesift-setup.md` for the full initialization sequence.

**Summary:** Run the CodeSift setup from `codesift-setup.md` at skill start. CodeSift tools are the primary analysis engine for SA8 (dead code), SA9 (complexity), SA10 (duplication), and SA13 (hotspots). If unavailable, fall back to CLI tools and grep heuristics.

---

## Phase 0: Parse $ARGUMENTS and Detect Stack

### 0.1 Arguments

| Argument | Behavior | Dimensions |
|----------|----------|------------|
| `full` | Audit entire project (all 13 dimensions) | SA1-SA13 |
| `[path]` | Scope to specific directory | SA1-SA13 (scoped) |
| `--naming` | Naming conventions only | SA2 |
| `--size` | File size distribution only | SA7 |
| `--dead-code` | Dead code and barrel analysis | SA5 + SA8 |
| `--duplication` | Code duplication only | SA10 |
| `--hotspots` | Git-based hotspot analysis only | SA13 |
| `--quick` | Skip external tooling and git mining | SA1-SA8, SA11-SA12 (SA9/SA10/SA13 = N/A) |
| `--fix` | Auto-fix after audit: delete unused (high confidence), .gitignore, rename | All + fix phase |

Default: `full`

### 0.2 Stack Detection

Detect language, framework, and project type from config files. Be restrictive -- a few stray `.ts` files in a non-JS project do not make it TypeScript.

| Stack | Required signals | SA Impact |
|-------|-----------------|-----------|
| TypeScript | `package.json` AND (`tsconfig.json` OR >10 `.ts`/`.tsx` files) | Full JS/TS tooling (knip, dep-cruiser, madge, eslint) |
| JavaScript | `package.json` AND >10 `.js`/`.jsx` files AND no `tsconfig.json` | JS tools (knip, dep-cruiser, madge, eslint) |
| Next.js | JS/TS AND `next` in package.json deps | SA1: App Router conventions, SA3: deep routes expected |
| NestJS | TypeScript AND (`nest-cli.json` OR `@nestjs/core` in deps) | SA2: suffix conventions, SA1: module structure |
| Python | `pyproject.toml` OR `requirements.txt` AND >5 `.py` files | SA9: radon, SA8: vulture, no knip/madge |
| PHP | `composer.json` AND >5 `.php` files | SA9: phpmd, SA10: phpcpd |
| Monorepo | `turbo.json` OR `nx.json` OR `pnpm-workspace.yaml` | SA1: per-package evaluation |
| Generic | None of above | Grep-only analysis, JS/TS tools = N/A |

**Ignore for detection:** files in `dist/`, `node_modules/`, `coverage/`, `.next/`, `__pycache__/`, `.venv/`, `.git/`.

### 0.3 Source Root and Code Scope

Two separate concepts:

- **`$REPO_ROOT`** -- always `.` (project root). Used for SA11 (root org), SA12 (docs), .gitignore checks.
- **`$CODE_SCOPE`** -- directories containing source code to analyze. Used for SA1-SA10, SA13, and all tools.

**Detect `$CODE_SCOPE`:**

| Signal | CODE_SCOPE |
|--------|------------|
| `src/` exists with >5 code files | `src/` |
| `app/` exists with code (Next.js, no `src/`) | `app/` |
| `lib/` exists as main source dir | `lib/` |
| `backend/` + `frontend/` | Per-app: `backend/src/` and `frontend/src/` |
| `packages/*/src/` (monorepo) | Per-package |
| None of above but code files at root | `.` (project root) |

### 0.3.1 Build Code File List (ALWAYS)

Build a canonical file list as the single source of truth for all tools and analyses. Never let tools decide what to scan independently.

```bash
CODE_FILE_LIST="/tmp/structure-audit-code-files.txt"

find "$CODE_SCOPE" -type f \( \
  -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \
  -o -name "*.py" -o -name "*.php" -o -name "*.go" -o -name "*.rs" \
  -o -name "*.java" -o -name "*.rb" -o -name "*.swift" \) \
  -not -path "*/node_modules/*" -not -path "*/dist/*" -not -path "*/.next/*" \
  -not -path "*/coverage/*" -not -path "*/__pycache__/*" -not -path "*/.venv/*" \
  -not -path "*/.git/*" \
  > "$CODE_FILE_LIST"

CODE_FILE_COUNT=$(wc -l < "$CODE_FILE_LIST" 2>/dev/null || echo 0)
```

Derive unique directories for tools that need directory arguments:

```bash
CODE_DIR_LIST="/tmp/structure-audit-code-dirs.txt"
while IFS= read -r file; do
  dirname "$file"
done < "$CODE_FILE_LIST" | sort -u | head -20 > "$CODE_DIR_LIST"
```

### 0.4 Code Density Check

| Condition | Mode |
|-----------|------|
| `CODE_FILE_COUNT` >= 10 | **FULL AUDIT** -- all SA1-SA13 |
| `CODE_FILE_COUNT` = 1-9 | **LIMITED AUDIT** -- SA1-SA4, SA11-SA12 only. Print: "Scope has <10 code files. Running limited audit." |
| `CODE_FILE_COUNT` = 0 | **NO-CODE MODE** -- only markdown/config/docs. Run SA11 + SA12 only. Print: "No source code files. Running documentation audit only." |

Print:
```
Stack: [detected] | Framework: [detected] | Monorepo: [yes/no]
Code scope: [path] | Code files: [N] | Mode: [FULL/LIMITED/NO-CODE]
Dimensions: [which SA dimensions will run]
```

---

## Phase 1: Tool Execution

Run external tools. Save all outputs to `./audit-results/structure-audit-{YYYY-MM-DD}/`.

**Skip if:** `--quick` mode (SA9/SA10/SA13 = N/A), LIMITED/NO-CODE mode, or code density < 10.

**CodeSift is the primary engine.** Tools 1.2 (dead code), 1.4 (duplication), 1.5 (complexity) try CodeSift first. Phase 2 (hotspots) also uses CodeSift `analyze_hotspots` first. Fall back to CLI tools only if CodeSift is unavailable.

**JS/TS tool gate (fallback tools only):** Fallback tools 1.2 (knip) and 1.3 (dep-cruiser) require BOTH: (a) `package.json` exists, AND (b) stack detected as JavaScript or TypeScript. Tool 1.1 (cloc) and 1.4 fallback (jscpd) are stack-agnostic.

### 1.1 cloc (ALWAYS -- uses code file list)

```bash
npx cloc --json --by-file --list-file="$CODE_FILE_LIST"
```
Feeds: SA7 (file size distribution), SA13 (hotspot LOC component).
**Verify output:** check for `"SUM"` key in JSON, not exit code.

### 1.2 Dead Code Detection (SA5, SA8)

**PRIMARY (CodeSift):**
```
find_dead_code(repo, file_pattern="*.{ts,tsx}")
```
Parse: unused exports count, unused files list, confidence per entry.

**FALLBACK (no CodeSift) -- knip (JS/TS only):**
```bash
npx knip --reporter json
```
Fallback: grep-based export tracing (MEDIUM confidence).

### 1.3 dependency-cruiser (JS/TS only -- fallback tool)

**Gate:** `package.json` exists AND JS/TS stack detected. Otherwise: `N/A`.

```bash
tr '\n' '\0' < "$CODE_DIR_LIST" | xargs -0 npx --yes dependency-cruiser \
  --no-config --output-type err \
  --do-not-follow "node_modules" \
  --exclude "^(dist|docs|coverage|\.next)"
```
Feeds: SA6 (layer violations), SA8 (circular deps, orphans).
**Verify output:** check for "modules.*cruised" or violation text. `0 modules cruised` = TOOL_EMPTY.

### 1.4 Code Duplication (SA10)

**PRIMARY (CodeSift):**
```
find_clones(repo, min_similarity=0.7, file_pattern="*.{ts,tsx}")
```

**FALLBACK (no CodeSift) -- jscpd (all languages):**
```bash
tr '\n' '\0' < "$CODE_DIR_LIST" | xargs -0 npx --yes jscpd \
  --min-lines 10 --reporters json \
  --ignore "**/node_modules/**,**/dist/**,**/*.md,**/*.json" \
  --output ./audit-results/
```
**Verify output:** check `statistics.total.sources > 0` in JSON.

### 1.5 Complexity Distribution (SA9)

**PRIMARY (CodeSift):**
```
analyze_complexity(repo, top_n=20, file_pattern="*.{ts,tsx}")
```

**FALLBACK (no CodeSift) -- ESLint complexity (JS/TS only):**

Try in order, stop at first success:

1. **Project ESLint config (preferred):** Check for existing config. Use it with `--rule 'complexity: [warn, 15]'`.
2. **Standalone (plain JavaScript only):** `--no-config-lookup` on `.js`/`.jsx` files.
3. **Grep heuristic (last resort):** nesting depth via indentation analysis.

**Never use `--no-config-lookup` on `.ts`/`.tsx` files -- it cannot parse TypeScript without a parser config.**

### Tool Summary

After all tools, print:
```
Tools: cloc [OK/SKIP] | dead-code [CodeSift/knip/SKIP] | dep-cruiser [OK/SKIP] | duplication [CodeSift/jscpd/SKIP] | complexity [CodeSift/eslint/SKIP]
Code files scanned: [N] | Non-code excluded: [dirs]
```

---

## Phase 2: Git Mining (SA13)

**Skip if:** `--quick` mode, LIMITED/NO-CODE mode, git history < 3 months, or non-git repository. Mark SA13 as N/A.

**PRIMARY (CodeSift):**
```
analyze_hotspots(repo, since_days=180)
```
Parse: hotspot files (change frequency x complexity), temporal coupling pairs, churn scores.

**FALLBACK (no CodeSift):** Run git mining scripts directly.

### 2.1 Change Frequency

```bash
git log --since="6 months ago" --name-only --format="" -- $CODE_SCOPE | sort | uniq -c | sort -rn | head -30
```
Top 30 most-changed files. Combine with cloc LOC for hotspot score.

### 2.2 Temporal Coupling

Analyze co-change patterns among top 100 most-changed files. Flag pairs with >50% co-change rate in different modules.

### 2.3 Shotgun Surgery

Count unique directories per commit. Median > 3 directories indicates shotgun surgery.

### 2.4 Developer Congestion

For each hotspot file from 2.1, count unique authors. >5 authors on a low-health file is a congestion finding.

---

## Phase 3: Structural Analysis

Grep and Read based analysis for dimensions that do not need external tooling. Two-step detection: grep finds CANDIDATES, Read VERIFIES. Never score from grep alone.

**Scope:** All grep/glob commands target `$CODE_SCOPE` for SA1-SA10. SA11-SA12 use `$REPO_ROOT`.

### 3.1 SA1 -- Directory Pattern Consistency

1. List top-level directories under `$CODE_SCOPE`
2. Classify each as LAYER, FEATURE, INFRASTRUCTURE, or FRAMEWORK
3. Mixed patterns at same level = finding
4. Check framework conventions (Next.js: no pages/ alongside app/)

### 3.2 SA2 -- File Naming Conventions

1. Glob all source files. Classify filename case (kebab, camel, pascal, snake).
2. Mixed case in same directory = finding
3. Count .test.ts vs .spec.ts. Both > 10% = mixed convention.
4. Check type suffix consistency (.service.ts, .controller.ts)

### 3.3 SA3 -- Folder Depth and Nesting

1. Compute max and average depth from file tree (code files only)
2. Filter out framework-deep paths (Next.js App Router routes)
3. Directories with >50 source files = flat explosion
4. Single-file directories = unnecessary nesting

### 3.4 SA4 -- Colocation

1. For each test file, determine co-located (same dir) or centralized (__tests__/)
2. >20% in each category = mixed colocation
3. Check type files: centralized types/ vs co-located *.types.ts
4. Check constants/utils used by single module but stored centrally

### 3.5 SA5 -- Barrel Exports and Import Hygiene

**Skip if:** LIMITED or NO-CODE mode.

1. Count index.ts files. >30 exports = god barrel
2. Merge with dead code detection output for unused export counts
3. Check for barrel chains (index.ts re-exporting from another index.ts)
4. Grep for deep relative imports (>3 levels of ../)
5. Check tsconfig paths vs actual usage

### 3.6 SA6 -- Separation of Concerns (CRITICAL GATE)

**Skip if:** LIMITED or NO-CODE mode.

Run fitness function rules:
1. **F1:** ORM imports in .tsx/.vue files (CRITICAL if in components)
2. **F2:** Controller-to-controller imports
3. **F3:** Service importing from controller
4. **F4:** Test utility imports in production code
5. **F5:** fetch/axios in component files (not hooks)
6. **F6:** process.env outside config layer
7. **F7:** Module envy (>60% imports from single other module)

Each grep hit is a CANDIDATE. Read surrounding context to verify.

### 3.7 SA7 -- File Size Distribution (CRITICAL GATE)

**Skip if:** LIMITED or NO-CODE mode.

1. Use cloc per-file data. Exclude non-code files from size analysis.
2. Classify each file by type (component, service, hook, util)
3. Apply 1.2x tolerance factor, compare to category limit from file-limits.md
4. 3x+ = CRITICAL, 2-3x = HIGH, 1-2x = MEDIUM
5. Compute distribution: median, P90, P99, max
6. God module detection: >3x median files + generic name + high coupling

### 3.8 SA11 -- Configuration and Root Organization

**Uses `$REPO_ROOT`.**

1. Count root-level files. Categorize (essential, dotfiles, stale, artifacts)
2. Check for tracked temp files (.tmp-*, .env.local, *.log)
3. Check .gitignore completeness for detected stack
4. Check for scripts at root vs scripts/ directory

### 3.9 SA12 -- Documentation Structure

**Uses `$REPO_ROOT`.**

1. Check for README.md with setup instructions
2. Check for CHANGELOG.md
3. Check for docs/adr/ directory (if project >50 files)
4. Check for OpenAPI/Swagger spec (if API project)
5. Check for CONTRIBUTING.md (if >3 git contributors)

---

## Phase 4: Scoring

### 4.1 Per-Dimension Scoring

For each SA1-SA13:
1. Apply scoring rubric (0 = violated, 1 = weak, 2 = acceptable, 3 = strong)
2. Note N/A dimensions (exclude from denominator)
3. Provide 1-line evidence for each score
4. In LIMITED mode: SA5-SA10, SA13 are all N/A
5. In NO-CODE mode: SA1-SA10, SA13 are all N/A

### 4.2 Critical Gate Check

| Gate | Trigger | Result |
|------|---------|--------|
| SA6 = 0 | ORM in UI components, no service layer | FAIL |
| SA7 = 0 | 3+ production files exceed 3x category limit | FAIL |
| SA8 = 0 | Circular deps in core production modules (confirmed) | FAIL |

Any gate = 0 means overall grade = FAIL regardless of total score.
In LIMITED/NO-CODE mode, gates are N/A.

### 4.3 Total Score

```
raw_score = sum of all scored dimensions
available_max = 100 - sum of N/A dimension weights
normalized_score = (raw_score / available_max) * 100
```

### 4.4 Grade Assignment

| Range | Grade |
|-------|-------|
| >= 85 | A |
| 70-84 | B |
| 50-69 | C |
| < 50 | D |
| Any gate = 0 | FAIL |

### 4.5 SQALE Debt Ratio (secondary metric)

```
remediation_minutes = sum(LOW:5 + MEDIUM:15 + HIGH:30 + CRITICAL:60 per finding)
debt_ratio = remediation_minutes / (total_LOC * 30)
```

| Debt Ratio | Rating |
|-----------|--------|
| 0-5% | A |
| 6-10% | B |
| 11-20% | C |
| 21-50% | D |
| 51%+ | E |

---

## Phase 5: Report and Action Plan

### 5.1 Report Sections

1. **META** -- date, stack, scope, code files count, mode (FULL/LIMITED/NO-CODE), tools used, LOC count
2. **Score Table** -- SA1-SA13 with scores, max, gate status
3. **Critical Gates** -- PASS/FAIL with evidence for SA6, SA7, SA8
4. **Grade** -- letter grade + debt ratio
5. **Tool Outputs Summary** -- key numbers from each tool
6. **Findings** -- sorted by severity, with fix and effort estimates
7. **Cross-Cutting Patterns** -- compound risk patterns:
   - Structural bottleneck: SA7 god file + SA8 circular + SA13 hotspot
   - Hidden coupling: SA13 temporal coupling + SA6 module envy
   - Import pollution: SA5 god barrel + SA8 unused exports
   - Untestable hotspot: SA13 hotspot + SA7 oversized + SA4 no co-location
   - Missing abstraction: SA10 high duplication + SA13 shotgun surgery
   - Abandoned attic: SA8 dead code + SA11 stale config + SA11 temp files
8. **Hotspot Analysis** -- SA13 table (if applicable)
9. **Top 5 Action Items** -- sorted by Impact/Effort ratio
10. **Recommended Next Skills** -- based on findings

### 5.2 Save Report

```bash
mkdir -p audit-results
```

Save to: `audit-results/structure-audit-YYYY-MM-DD.md`

### 5.3 Backlog Integration

For HIGH and CRITICAL findings, persist to `memory/backlog.md`:
- Fingerprint format: `file|SA-dimension|check-id`
- Deduplicate against existing entries

### 5.4 Auto-Fix Mode (--fix)

**Only if `--fix` argument was provided.** After report generation:

| Fix Type | Condition | Action |
|----------|-----------|--------|
| Delete unused files | Dead code detection with HIGH confidence only | `rm` with confirmation |
| Add .gitignore patterns | Missing stack-specific patterns | Append to .gitignore |
| Rename convention violations | Clear case mismatch (1-3 files) | `git mv` with import updates |

**NEVER auto-fix:**
- Split oversized files (requires `zuvo:refactor`)
- Restructure directories (requires design decisions)
- Fix circular dependencies (requires `zuvo:architecture` analysis)
- Delete files with MEDIUM confidence

Confirm each fix with the user before executing.

---

## Next-Action Routing

| Finding | Action | Command |
|---------|--------|---------|
| SA5 Dead code CRITICAL | Remove dead code | `zuvo:structure-audit [path] --fix` |
| SA8 Circular dependencies | Architecture review | `zuvo:architecture --mode review [path]` |
| SA10 Excessive duplication | Extract shared code | `zuvo:refactor [file]` |
| SA13 Hot file (high churn + complexity) | Refactor hot file | `zuvo:refactor [file]` |
| SA7 God module detected | Split oversized file | `zuvo:refactor [file]` |
| SA6 Layer violations | Architecture analysis | `zuvo:architecture --mode review` |

---

## Run Log

Log this run to `~/.zuvo/runs.log` per `{plugin_root}/shared/includes/run-logger.md`:
- SKILL: `structure-audit`
- CQ_SCORE: `-`
- Q_SCORE: `-`
- VERDICT: PASS/WARN/FAIL from findings
- TASKS: number of files analyzed
- DURATION: `-`
- NOTES: scope summary (max 80 chars)
