---
name: review
description: >
  Structured code review with parallel audit agents, confidence-scored triage,
  and optional auto-fix. Examines uncommitted changes, staged diffs, commit
  ranges, or specific paths. Produces a tiered report (MUST-FIX / RECOMMENDED /
  NIT) backed by evidence, then optionally applies fixes with verification.
codesift_tools:
  always:
    # Stack detection (used by codesift-setup orchestrator)
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    # Diff-specific (review's headline tools — work on uncommitted/staged/commit-range diffs)
    - review_diff           # COMPOUND: 9 parallel checks on git diff (security, dead code, complexity, etc.)
    - changed_symbols       # which symbols added/modified/deleted in range
    - diff_outline          # structural diff per file (signatures only — no body churn noise)
    - impact_analysis       # blast radius + affected_tests for the changed surface
    # Reading the changed code in context
    - get_symbol            # read one changed symbol
    - get_symbols           # read 2+ changed symbols (batch — preferred)
    - get_file_outline      # file-level structure of touched files
    - find_references       # who calls the changed function (regression risk)
    - trace_call_chain      # downstream impact (--deep mode)
    # Pattern + safety scans applied to the diff
    - audit_scan            # COMPOUND: find_dead_code + search_patterns + find_clones + analyze_complexity (--deep)
    - search_patterns       # CQ8 empty-catch + CAP anti-patterns introduced
    - scan_secrets          # CAP5 hardcoded-secret pre-scan (always run on diff)
    # Cross-cutting search (fallback when symbol-aware tools miss)
    - search_text
    - search_symbols
    - get_file_tree
  # Same `by_stack` shape as code-audit — review benefits from framework-aware
  # checks applied to the diff (e.g. a Next.js route change should run
  # framework_audit and nextjs_route_map; a Yii controller change should run
  # php_security_scan + resolve_php_service). Orchestrator (codesift-setup.md
  # Step 2.5) matches keys against analyze_project + dep manifests with same
  # 6 rules used by code-audit, including rule #6 hybrid handling.
  by_stack:
    # Languages
    typescript:
      - get_type_info              # TS-only: type inference for changed signatures
      - resolve_constant_value      # TS+Python: resolve constants and function defaults through alias/import chains
    javascript: []                 # symmetric placeholder; no JS-only tools yet
    python:
      - python_audit
      - analyze_async_correctness
      - resolve_constant_value      # TS+Python: resolve constants and function defaults through alias/import chains
    php:
      - php_project_audit
      - php_security_scan
    kotlin:
      - analyze_sealed_hierarchy
      - find_extension_functions
      - trace_flow_chain
      - trace_suspend_chain
      - trace_compose_tree
      - analyze_compose_recomposition
      - trace_hilt_graph
      - trace_room_schema
      - analyze_kmp_declarations
      - extract_kotlin_serialization_contract
    # JS/TS frameworks
    nestjs:
      - nest_audit
    nextjs:
      - framework_audit
      - nextjs_route_map
    astro:
      - astro_audit
      - astro_actions_audit
      - astro_hydration_audit
      - astro_middleware
      - astro_sessions
      - astro_image_audit
      - astro_svg_components
    hono:
      - analyze_hono_app
      - audit_hono_security
    express: []                    # generic CodeSift covers; key acknowledged
    fastify: []
    react:
      - react_quickstart
      - analyze_hooks
      - analyze_renders
    # Python sub-frameworks
    django:
      - analyze_django_settings
      - effective_django_view_security
      - taint_trace
    fastapi:
      - trace_fastapi_depends
      - get_pydantic_models
    flask:
      - find_framework_wiring
    jest: []                       # generic CodeSift covers
    # PHP sub-frameworks
    yii:
      - resolve_php_service
    # ORMs / databases
    prisma:
      - analyze_prisma_schema
    sql:
      - sql_audit
    postgres:
      - migration_lint
---

# zuvo:review

Triage the diff, audit it through independent lenses, confidence-score every finding, run cross-model adversarial validation, and deliver a verdict. No separate "go" step required -- the review runs end to end.

## Mandatory File Loading

### PHASE 0 — Bootstrap (always, before reading any input)

```
  1. ../../shared/includes/codesift-setup.md      -- [READ | MISSING -> STOP]
```

This is the ONLY file loaded before reading the diff.

### PHASE 0.5 — Classify (read diff, determine content type)

After CodeSift setup, read the git diff. Classify content type:
- **prod-only:** diff touches production files only (no `*.test.*`, `*.spec.*`)
- **test-only:** diff touches test files only
- **mixed:** diff touches both production and test files

Print: `[CLASSIFIED] Diff type: {prod-only|test-only|mixed}`

### PHASE 1 — Conditional Load (based on diff type)

| Include | prod-only | test-only | mixed |
|---------|-----------|-----------|-------|
| `../../shared/includes/env-compat.md` | Full | Full | Full |
| `../../shared/includes/quality-gates.md` | CQ1-CQ29 section only* | Q1-Q19 section only** | Full |
| `../../shared/includes/cross-provider-review.md` | Full | Full | Full |
| `../../rules/cq-patterns.md` or `cq-patterns-core.md` | Per code type*** | **SKIP** | Per code type*** |
| `../../rules/cq-checklist.md` | TIER 1+ | **SKIP** | TIER 1+ |
| `../../rules/testing.md` | **SKIP** | Full | Full |
| `../../rules/security.md` | If security signals | **SKIP** | If security signals |

\* **CQ section only:** Read from start of file to the `## Q1-Q19` heading. Skip Q section.
\*\* **Q section only:** Read from `## Q1-Q19: Test Quality Gates` heading to end of file. Skip CQ section.
\*\*\* **cq-patterns loading rule:** After Step 1 (classify code type), check the "High-Risk Gates by Code Type" table in `cq-checklist.md`. If the code type has <=10 relevant gates, load `cq-patterns-core.md` (~500 tok) instead of `cq-patterns.md` (~8.4K tok).

Print loaded files:
```
PHASE 1 — LOADED:
  [list with READ/SKIP status per file and section qualifiers]
```

### Optional Files (loaded if available, degraded if missing)

```
  ../../shared/includes/knowledge-prime.md   -- [READ | MISSING -> degraded]
  ../../shared/includes/knowledge-curate.md  -- [READ | MISSING -> degraded]
```

### DEFERRED — Load at completion

```
  ../../shared/includes/run-logger.md        -- [READ at final step]
  ../../shared/includes/retrospective.md     -- [READ at final step]
```

---

## Argument Parsing

`$ARGUMENTS` controls both WHAT gets reviewed and WHAT to do with the findings.

### Scope (what code to examine)

| Input | Meaning | Git command |
|-------|---------|-------------|
| _(empty)_ | All uncommitted changes | `git diff --stat HEAD` |
| `staged` | Only staged changes | `git diff --stat --cached` |
| `new` | Commits since last review | Backlog/merge-base resolution |
| `HEAD~N` | Last N commits | `git diff --stat HEAD~N..HEAD` |
| `abc123..def456` | Specific commit range | `git diff --stat abc123..def456` |
| `src/services/` | Directory (uncommitted) | `git diff --stat HEAD -- src/services/` |

Tokens combine: `HEAD~3 src/api/` reviews the last 3 commits scoped to `src/api/`.

**`new` resolution order:**
1. `memory/backlog.md` unchecked entries -> oldest entry's parent hash as start point
2. Detect default branch: `DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||'); DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}`
3. Fallback: `git merge-base HEAD "$DEFAULT_BRANCH"`
4. Final fallback: `HEAD~5` with a warning

### Range Validation

After deriving `REVIEWED_FROM` and `REVIEWED_THROUGH` for any commit-based scope (`new`, `HEAD~N`, `abc123..def456`, batch entry), validate the range before tier selection, CodeSift pre-compute, or adversarial review:

```bash
git log --oneline "${REVIEWED_FROM}..${REVIEWED_THROUGH}" | head -5
```

If this returns no commits, STOP and print:
`[RANGE-ERROR] Empty commit range. Verify base/tip order before running review.`

Do NOT auto-swap the range.

Then print the validated diff stat:

```bash
git diff --shortstat "${REVIEWED_FROM}..${REVIEWED_THROUGH}"
```

### Mode (what to do after the audit)

| Token | Mode | Behavior |
|-------|------|----------|
| _(none)_ | REPORT | Audit and present findings. Wait for user decision. |
| `fix` | FIX-ALL | Apply every reported fix automatically, then verify. |
| `blocking` | FIX-BLOCKING | Apply only MUST-FIX findings, then verify. |
| `auto-fix` | AUTO-FIX | Dispatch `zuvo:build` to fix MUST-FIX issues (closed-loop). |
| `tag` | UTILITY | No audit. Remove reviewed commits from backlog. |
| `mark-reviewed` | UTILITY | No audit. Create `reviewed/` git tags on commits. |
| `status` | UTILITY | No audit. Show unreviewed commit count and list. |
| `batch <file>` | BATCH | Process a queue of commits: review, fix, tag per entry. |
| `--thorough` | FLAG | Activate multi-pass review with majority voting. |
| `--depth N` | FLAG | For `status` mode: how many commits to check (default 100). |

---

## Tier System

A quick `git diff --stat` determines how deep the review goes. Filter out noise files before counting (locks, dist, snapshots, generated code, binary assets).

### Edge Cases (check before tier selection)

| Condition | Action |
|-----------|--------|
| 0 files changed (empty diff) | Print "No changes to review." -> STOP |
| All files are binary | Print "Only binary files changed. Nothing to review." -> STOP |
| Binary files mixed with code | Tier based on code lines only. Note binaries in report. |
| All changed files are noise | Print "Only noise files changed (locks, snapshots, dist). Nothing to review." -> STOP |
| Merge commit detected | Interactive: warn + offer `--first-parent`. Non-interactive: auto-apply `--first-parent` with `[AUTO-DECISION]`. |

### Production Logic Line Count

Before tier selection, compute `PROD_LOGIC_LINES` from changed non-test production hunks after stripping diff headers, blank lines, and comment-only additions/deletions (`//`, `#`, `/*`, `*`, `*/`).

If `PROD_LOGIC_LINES = 0`:
- Force `TIER 1 -- LIGHT`
- Skip TIER 2+ escalation driven only by risk signals on comment-only diffs
- Skip heavy TIER 2-3 pre-compute and behavior-agent escalation
- Print `[AUTO-DECISION] No production logic lines changed -> TIER 1 override`

### Tier Selection

| Condition | Tier |
|-----------|------|
| `PROD_LOGIC_LINES = 0` | TIER 1 -- LIGHT |
| <15 lines, no risk signals | TIER 0 -- NANO |
| 15-100 lines, no risk signals | TIER 1 -- LIGHT |
| 100-500 lines OR 5-15 files OR 1 risk signal | TIER 2 -- STANDARD |
| >500 lines OR 15+ files OR 2+ risk signals | TIER 3 -- DEEP |

**Intent adjustments:**
- REFACTOR + <10 files + no DB/security/API/money signal: cap at TIER 2.
- INFRA-only (config, CI, Dockerfile -- no production code): cap at TIER 1 unless >300 lines.

### Tier Capabilities

| Capability | TIER 0 | TIER 1 | TIER 2 | TIER 3 |
|-----------|--------|--------|--------|--------|
| Inline diff scan | Yes | Yes | Yes | Yes |
| CQ patterns loaded | Skip | Core (500 tok) | Full (8.4K tok) | Full (8.4K tok) |
| CQ1-CQ29 evaluation | Skip | Yes (lead inline) | Yes (CQ Auditor agent) | Yes (CQ Auditor agent) |
| Q1-Q19 on test files | Skip | If present (lead) | Yes | Yes |
| Audit agents | None | None | Behavior + CQ (if new files) | All 3 (Behavior + Structure + CQ) |
| Adversarial (bash script) | Yes (all available) | Yes (all available) | Yes (all available) | Yes (all available) |
| CodeSift pre-compute | Optional | Yes (light ops) | Yes (core ops) | Yes (core ops) |
| Confidence scoring | Lead inline | Lead inline | Re-Scorer agent | Re-Scorer agent |
| Hotspot detection | Skip | Skip | Yes | Yes |
| Multi-pass (--thorough) | Refused | Optional | Optional | Auto if >500L |
| Stack-specific rules | Skip | Skip | Yes | Yes |
| Report persistence | Skip | Yes | Yes | Yes |

### Risk Signals

Check the diff for these markers. Each one counts toward tier escalation:

- DB migration or schema changes
- Security or authentication modifications
- API contract changes (routes, request/response shapes)
- Payment or money flow logic
- More than 500 lines changed
- New production files added (not test files)
- AI-generated code patterns (hallucinated imports, generic names, overly verbose)

### Deployment Risk Scoring

Every review MUST compute a deployment risk score.

| Factor | Points | How to detect |
|--------|--------|---------------|
| Auth/authz changes | +3 | Diff touches guards, middleware, JWT, session, role checks |
| Payment/money logic | +3 | Diff touches payment, pricing, billing, subscription |
| DB migration or schema | +2 | Migration files, schema changes, ALTER/CREATE TABLE |
| API contract changes | +2 | New/modified routes, request/response shape changes |
| File in churn hotspot (top 10) | +2 | Phase 0 hotspot detection. **Score 0 at TIER 0-1.** |
| >500 lines changed | +1 | From diff stat |
| New production files added | +1 | New .ts/.tsx/.py files (not tests) |
| Multi-service blast radius | +1 | Changes affect 3+ modules/services |
| Reverts or rollback-sensitive | +1 | State machine, data migration, irreversible ops |

| Points | Level | Deploy strategy |
|--------|-------|----------------|
| 0-1 | LOW | Direct merge -- standard CI |
| 2-4 | MEDIUM | Merge after review -- run full test suite |
| 5-7 | HIGH | Canary recommended -- deploy to subset first |
| 8+ | CRITICAL | Staged rollout -- extra reviewer, canary mandatory |

### FIX-ALL Blockers

For high-risk changes (DB migrations, security/auth, API contracts, payment/money), apply fixes one at a time and run tests after each fix. If a fix breaks tests, revert it and report as `[!]`.

---

## Phase 0: Pre-Audit Setup

### Knowledge Prime

Check if knowledge base exists BEFORE loading the protocol: `Glob("memory/knowledge*.md")` or `Glob(".zuvo/knowledge*.md")`. If no files found, skip — do NOT load `knowledge-prime.md` (saves ~140L / ~1.6K tokens). If files exist, then load and run:
```
WORK_TYPE = "review"
WORK_KEYWORDS = <keywords from diff file paths and commit messages>
WORK_FILES = <changed files from the diff>
```

### CodeSift Setup

**Use the deterministic preload helper FIRST.** Before issuing any ToolSearch, run:
```
~/.zuvo/compute-preload review "$PWD"
```
Copy the printed `[CodeSift matching trace]` block verbatim and issue the printed `ToolSearch(query="select:...")` line without modification. Math gate: `[CodeSift loaded] tools=N` must equal `[Expected after load] tools=N` from the helper. If they differ → `[PRELOAD MATH MISMATCH]` and abort before Phase 1.

### MANDATORY TOOL CALLS — Review Validity Gate

**This review is INVALID if any tool below is skipped when its trigger condition holds.** "DEFERRED", "N/A", "TIER 0 minimal scope" are NOT valid reasons unless explicitly documented as such.

| Tool | Trigger | Reason | Skip allowed? |
|------|---------|--------|---------------|
| `review_diff` | Always (any review with a diff) | KEY COMPOUND — 9 parallel checks (security, dead code, complexity, etc.) on the diff | **NO** |
| `changed_symbols` | Always (any commit-range or staged review) | Which symbols added/modified/deleted in range — required for CQ scoring | **NO** |
| `diff_outline` | Always | Structural diff per file (signatures only — no body churn noise) | **NO** |
| `impact_analysis` | Always | Blast radius + affected_tests for the changed surface | **NO** |
| `find_references` | Any finding cites a function/method | Regression risk verification | **NO** when condition holds |
| `scan_secrets` | Always (any review touching code or config) | CAP5 hardcoded-secret pre-scan on the diff | **NO** |
| `search_patterns` | Always | CQ8 empty-catch + CAP anti-patterns introduced in the diff | **NO** |
| Stack-specific tools (nest_audit/framework_audit/python_audit/etc.) | Framework/language detected AND diff touches framework code | Framework-aware gates the diff inherits | **NO** when conditions hold |

### Forbidden escape hatches

| Value | Forbidden when | Required value instead |
|-------|----------------|------------------------|
| `review_diff: skipped (TIER 0)` | EVER (TIER 0 still uses CodeSift pre-compute per Tier table) | `review_diff: <findings_per_check>` |
| `scan_secrets: not_run` | EVER | `scan_secrets: <count>` |
| `changed_symbols: N/A (test-only diff)` | EVER (test files have changed_symbols too) | `changed_symbols: <count>` |
| `codesift: unavailable` | `mcp__codesift__*` was in deferred-tools session-start banner | `codesift: deferred-not-preloaded (FAILURE: skill required preload)` |
| `RETRO: skipped (nothing interesting)` | EVER | One of: `RETRO: skipped (trivial session, <3 findings and no fix-loop)` OR full retro appended |

### Required POSTAMBLE — retrospective + verify-audit gates

After the review report is written, the review is **NOT complete** until:

1. `memory/reviews/<date>-<scope>.md` (TIER 1+) is on disk.
2. `~/.zuvo/append-runlog` is called with the Run line — this triggers BOTH:
   - **retro-gate**: requires a matching `RETRO:` entry in `~/.zuvo/retros.log` for `skill=review project=<this>`. If missing → exit 2, runs.log NOT appended.
   - **audit-content gate**: runs `~/.zuvo/verify-audit` on the report. Every MUST-FIX and RECOMMENDED finding must contain at least one `path/to/file.ext:LINE` citation that resolves in the current tree. NIT findings without citations get rejected. If rejected → fix the report, re-run `append-runlog`.
3. Print `RETRO_APPENDED: retros.log=YES retros.md=YES (verified)` and confirm exit 0 from `append-runlog`.

If you reach `REVIEW COMPLETE` and stop without calling `append-runlog`: the review is INVALID regardless of finding count. The Validity Gate `gate_status` flips to `FAIL — postamble incomplete` and the verdict overrides to `INCOMPLETE`.

### Mandatory acknowledgment (REQUIRED — print verbatim before Phase 0.5)

```
Mandatory-tools-acknowledgment: I will run review_diff + changed_symbols + diff_outline + impact_analysis + scan_secrets + search_patterns + find_references (on cited symbols) + stack-specific tools (nest_audit/framework_audit/python_audit/etc. when detected) for this review. Each MUST-FIX and RECOMMENDED finding will cite a `path/to/file.ext:LINE` resolving in the current tree.
```

### Standard CodeSift checks (run AFTER the helper)

Follow `codesift-setup.md`:
1. Check whether CodeSift tools are available (the helper above already verified this)
2. Repo auto-resolves from CWD — do NOT call `list_repos()` unless the review explicitly spans multiple repositories
3. If unsure whether the repo is indexed: `index_status()`
4. If not indexed: `index_folder(path=<project_root>)`

### Stack Detection (TIER 2+)

Detect tech stack and load matching rules:

| Stack indicator | Rules file |
|----------------|------------|
| tsconfig.json | `../../rules/typescript.md` |
| next.config.* or app/layout | `../../rules/react-nextjs.md` |
| nest-cli.json or @nestjs/* | `../../rules/nestjs.md` |
| requirements.txt / pyproject | `../../rules/python.md` |

Load at most 2 rules files. Pass to agents as STACK_RULES input.

### Hotspot Detection (TIER 2+)

**With CodeSift:** `analyze_hotspots(repo, since_days=90)` -- if any diff file is in the top 10 hotspots, add a risk signal.

**Without CodeSift:** `git log --format=format: --name-only --since="3 months ago" | sort | uniq -c | sort -rn | head -20`

### Blast Radius (TIER 2+)

**With CodeSift:** `impact_analysis(repo, since=<REVIEWED_FROM>, depth=2)`
**Without CodeSift:** `grep -r 'import.*[changed-module]'` to find direct importers.

### Dead Code Scan (optional, JS/TS only)

If the diff adds/removes exports and `knip` is available: `npx knip --reporter json 2>/dev/null`. Cross-reference flagged exports. If knip unavailable, skip silently.

---

## Phase 0.5: CodeSift Pre-Compute

Runs only when CodeSift is available. When unavailable, agents fall back to their degraded modes (Read/Grep).

**TIER 0 (optional):** Skip unless CodeSift is already initialized. Minimal value for <=15 line diffs.

If any pre-compute call fails, set `PRECOMPUTED_DATA=partial`, log the failed operation in SKIPPED STEPS, and continue. Do NOT guess `codebase_retrieval` sub-query shapes.

**TIER 1 (light ops):**

1. `search_patterns(pattern="empty-catch", file_pattern="<changed-file-substring>", max_results=20)`
2. `find_references(symbol_names=[<changed exports>], file_pattern="<active test glob>")`
3. `analyze_complexity(file_pattern="<changed-file-substring>", top_n=10)`

**TIER 2-3 (core ops):**

1. For each changed production file: `get_file_outline(file_path="<relative path>")`
2. `find_references(symbol_names=[<changed symbols>], file_pattern="<active test glob>")`
3. `trace_call_chain(symbol_name="<key changed symbol>", direction="callers", depth=2)`
4. `search_patterns(pattern="empty-catch", file_pattern="<changed-file-substring>", max_results=50)`
5. `analyze_complexity(file_pattern="<changed-file-substring>", top_n=20)`
6. `impact_analysis(since=<REVIEWED_FROM>, until=<REVIEWED_THROUGH>, depth=2)`

If the repo uses both `*.spec.*` and `*.test.*`, run the test-reference step for both globs and merge the results.

### Compatibility Notes

- Valid `codebase_retrieval` sub-query types: `symbols`, `text`, `file_tree`, `outline`, `references`, `call_chain`, `impact`, `context`, `knowledge_map`
- Do NOT use `patterns`, `complexity`, or `file_outlines` inside `codebase_retrieval`
- `outline` uses singular `file_path`
- For direct `find_references`, use `symbol_names` when checking multiple symbols
- For `search_patterns` and `analyze_complexity`, use the standalone tools — there is no equivalent valid `codebase_retrieval` sub-query type

Pass results as `PRECOMPUTED_DATA` to each agent:

| Agent | Gets | Helps with |
|-------|------|-----------|
| Behavior Auditor | Call chains, pattern matches, complexity | Focus on high-risk functions |
| Structure Auditor | File outlines, complexity, impact | SRP and limits pre-answered |
| CQ Auditor | Pattern matches, test refs, file outlines | ~40% of gates pre-evaluated |
| Confidence Re-Scorer | Reference counts, hotspot ranks, impact | Data-driven confidence |

---

## Phase 1: Audit

**Steps:** 1.1 Self-Review Disclosure -> 1.2 Review Header -> 1.3 Agent Dispatch / Inline Audit -> 1.4 CQ (TIER 1+) -> 1.5 Q1-Q19 (if tests) -> 1.6 Adversarial (ALL tiers) -> 1.7 Result Merging

**With --thorough:** steps 1.3-1.5 become 3 independent passes in parallel, merged via majority voting, then adversarial runs after merge.

### 1.1 Self-Review Disclosure

Check whether you wrote any of the code being reviewed in this session. If yes, add a `SELF-REVIEW` marker to the header. Self-review detected -> pass `--all-providers` to adversarial script (F5).

### 1.2 Review Header (merged banner -- single block replaces 4 separate blocks)

```
===============================================================
CODE REVIEW | TIER [0-3] ([NANO-DEEP])
SCOPE:  [N files, +X/-Y lines] | INTENT: [BUGFIX/REFACTOR/FEATURE/INFRA]
AUDIT:  [SOLO/TEAM (N)] | Adversarial: [providers] | RISK: [LOW-CRITICAL]
Risk signals: [x] API  [ ] DB  [ ] Auth  [ ] Money  [ ] 500+L
===============================================================
```

### 1.3 Agent Dispatch

Refer to `env-compat.md` for the correct dispatch pattern per environment.

**TIER 0-1:** No agents. Lead performs all analysis inline using CodeSift pre-computed data (Phase 0.5) if available.

**TIER 2:** Dispatch Behavior Auditor (`agents/behavior-auditor.md`) if new production files. Dispatch CQ Auditor (`agents/cq-auditor.md`) as background agent. Lead performs Structure analysis inline.

**TIER 3:** Dispatch all 3 audit agents in parallel:

```
Agent 1: Behavior Auditor
  model: "sonnet"
  type: "Explore"
  instructions: read agents/behavior-auditor.md
  input: diff, tech stack, change intent, PRECOMPUTED_DATA, PROJECT_CONTEXT

Agent 2: Structure Auditor
  model: "sonnet"
  type: "Explore"
  instructions: read agents/structure-auditor.md
  input: diff, tech stack, change intent, PRECOMPUTED_DATA, PROJECT_CONTEXT

Agent 3: CQ Auditor
  model: "sonnet"
  type: "Explore"
  instructions: read agents/cq-auditor.md
  input: diff, tech stack, change intent, PRECOMPUTED_DATA, PROJECT_CONTEXT
```

Each agent receives: diff, tech stack, change intent, PRECOMPUTED_DATA, PROJECT_CONTEXT (global error handlers, middleware, decorators).

### Result Merging (after agents complete)

1. Collect BEHAV-N, STRUCT-N, and CQ findings
2. Deduplicate -- same file:line + same issue = keep the one with more evidence
3. Renumber sequentially as R-1, R-2, R-3...

### 1.4 CQ Self-Evaluation (TIER 1+)

For each changed production file, run CQ1-CQ29. Print all 29 gates. Format: `CQ EVAL: file.ts (NL) | CQ1=1 CQ2=0 ... | Score: X/Y -> PASS/FAIL | Critical gates: CQ4=0(no orgId:87)`. CQ critical gate failures (CQ3, CQ4, CQ5, CQ6, CQ8, CQ14) always produce MUST-FIX.

### 1.5 Q1-Q19 Evaluation (if test files in diff)

For each test file, run Q1-Q19. Format: `Q EVAL: file.spec.ts | Q1=1 Q2=1 ... | Score: X/Y -> PASS | Critical: Q7=1 Q11=1 Q13=1 Q15=1 Q17=1 -> PASS`.

### Pre-Existing Issues

Issues NOT introduced by the current diff: always report critical CQ gate violations (CQ3/4/5/6/8/14); briefly note CQ2, CQ10, CQ22; skip naming/magic numbers (code-audit territory). Cap at RECOMMENDED severity.

### Working-Tree Staleness Check

When reviewing a commit range rather than the current working tree, verify that HEAD has not already changed a file after `REVIEWED_THROUGH` before reporting a finding against it:

```bash
git diff --quiet "{REVIEWED_THROUGH}..HEAD" -- <file>
```

If the file changed after the reviewed range:
- mark it `[ALREADY-PATCHED]`
- read the current file before reporting
- drop stale findings that no longer exist at HEAD

### 1.6 Adversarial (ALL tiers — sequential)

Cross-model adversarial review using external providers. Runs **sequentially** via `--rotate` — each pass uses a different random provider. Text mode (no `--json`).

If `adversarial-review` not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

**Self-review escalation:** If SELF-REVIEW marker set in 1.1, pass `--all-providers` flag.

#### REPORT mode — sequential finding (no fixes)

Each pass uses `--rotate` (script picks a random unused provider). Prepend prior findings summary so each provider targets NEW issues.

```bash
# Pass 1:
git diff {REVIEWED_FROM}..{REVIEWED_THROUGH} | adversarial-review --rotate --mode code
# → Read output, extract ADV-1, ADV-2

# Pass 2:
(echo "PRIOR FINDINGS: ADV-1 [desc], ADV-2 [desc] — find NEW issues only";
 git diff {REVIEWED_FROM}..{REVIEWED_THROUGH}) | adversarial-review --rotate --mode code
# → Read output, extract ADV-3

# Pass 3 (if provider available):
(echo "PRIOR FINDINGS: ADV-1..3 — final pass, find what everyone missed";
 git diff {REVIEWED_FROM}..{REVIEWED_THROUGH}) | adversarial-review --rotate --mode code
# → ADV-4 or clean → early exit
```

**Early exit:** 0 findings from a pass = stop (code is clean from that model's perspective).

#### FIX mode — sequential fix + validation

Same `--rotate` pattern but each pass sees the IMPROVED diff after prior fixes.

```bash
# Pass 1: review post-primary-fix code
git diff {REVIEWED_FROM}..HEAD | adversarial-review --rotate --mode code
# → ADV-1 → apply fix → commit

# Pass 2: validate fix + find new
git diff {REVIEWED_FROM}..HEAD | adversarial-review --rotate --mode code
# → validates ADV-1 fix + finds ADV-2 → apply → commit

# Pass 3: final validation
git diff {REVIEWED_FROM}..HEAD | adversarial-review --rotate --mode code
# → clean or ADV-3
```

Max 2 fix attempts per provider finding. Max 3 passes total.

#### Common rules

- **Use `--rotate`** — script picks a random provider each call. Do NOT use bare `--mode code` (that runs all providers in parallel, defeating sequential).
- Strip lockfiles, snapshots, dist output, and other known noise files from the diff before piping it to `adversarial-review`.
- When deterministic facts are already known (for example: lockfile present in diff, package ships bundled types, file already patched at HEAD), prepend a short `FACTS:` block before the diff so the adversarial provider does not rediscover settled facts.
- If `PROD_LOGIC_LINES = 0` and SELF-REVIEW is not set, skip adversarial and log: `[CROSS-REVIEW] Skipped — no production logic changed.`
- **Timeout:** 60s per provider. Skip on timeout/malformed, continue with next.
- **All unavailable:** `[CROSS-REVIEW] No external provider available.` in SKIPPED STEPS.
- **Severity:** CRITICAL -> MUST-FIX (bypasses confidence gate). WARNING -> RECOMMENDED. INFO -> NIT.
- **Tag:** each finding as `[CROSS:<provider>]`

### Multi-Pass (--thorough variant)

3 audit passes in parallel: Pass 1 alphabetical, Pass 2 reverse dependency (leaf-first), Pass 3 risk-score descending. **Majority voting:** 3/3 -> KEEP + confidence +15. 2/3 -> KEEP. 1/3 -> DOWNGRADE one tier. Sequential adversarial runs AFTER multi-pass merge. Adversarial findings are NOT subject to voting — they go through confidence gate (WARNING/INFO) or bypass it (CRITICAL).

---

## Phase 2: Confidence Gate

**TIER 0-1:** Lead scores each finding inline. `Confidence: [X]/100 -- [reason]`.

**TIER 2+:** Dispatch Confidence Re-Scorer agent:

```
Agent: Confidence Re-Scorer
  model: "sonnet"
  type: "Explore"
  instructions: read agents/confidence-rescorer.md
  input: full candidate list, PRECOMPUTED_DATA, adversarial findings
```

### Disposition

| Confidence | Action | Backlog Tag |
|-----------|--------|-------------|
| 0-25 | EXCLUDE from report | `[low-confidence]` |
| 26-50 | EXCLUDE from report | `[below-threshold]` |
| 51-100 | KEEP in report | -- |

**Adversarial CRITICAL bypass:** Findings from `adversarial-review.sh` tagged CRITICAL skip the confidence gate. Effective confidence = 100. No exceptions.

**Backlog write timing:** All backlog writes happen AFTER Phase 4 Execute (or after Phase 3 if no execute). This prevents stale entries -- fixed findings are not written to backlog.

---

## Phase 3: Report

> **Phase 3 runs end-to-end with no approval pauses.** Do not ask the user to confirm before persisting the report, tagging commits, writing to backlog, or running the retrospective. All subsections below (Backlog Persistence → Report Persistence → Tag Reviewed Commits → Knowledge Curation → Retrospective → Completion Gate → NEXT STEPS) execute in order before any `REVIEW COMPLETE` text is emitted. The only gate is the Completion Gate Check at the end.
>
> **Destructive-persistence preconditions** (verify silently before tagging or writing to shared logs):
> - The CWD is a git repo and matches the scope being reviewed (`git rev-parse --is-inside-work-tree` true; `REVIEWED_FROM..REVIEWED_THROUGH` resolved against this repo's history).
> - For commit-range scopes (`new`, `HEAD~N`, explicit hashes): `REVIEWED_FROM` and `REVIEWED_THROUGH` are both reachable from HEAD.
> - For `staged` / uncommitted scopes: skip `reviewed/<hash>` tagging entirely (already documented below).
> - If any precondition fails: skip the destructive step (tag / log append) and report `[skipped: precondition failed (<reason>)]` in the gate check rather than silently writing into the wrong repo or logging spurious entries.

### Severity Tiers

| Tier | Meaning | Merge impact |
|------|---------|-------------|
| **MUST-FIX** | Confirmed bug, security issue, data loss, critical CQ gate | Blocks merge |
| **RECOMMENDED** | Maintenance risk, degraded reliability | Merge discouraged |
| **NIT** | Style, readability, no functional impact | Merge OK as-is |

### Report Sections

**TIER 2-3 (full report, 14 sections):**
1. META  2. SCOPE FENCE  3. VERDICT  4. **QUESTIONS FOR AUTHOR** (in FIX modes: pause, re-evaluate findings per answers; in REPORT: informational)  5. DEPLOYMENT RISK  6. SEVERITY SUMMARY  7. CHANGE SUMMARY  8. SKIPPED STEPS  9. VERIFICATION PASSED  10. BACKLOG IN SCOPE  11. DROPPED ISSUES (with tags)  12. **FINDINGS** (MUST-FIX -> RECOMMENDED -> NIT collapsed)  13. **QUALITY WINS** (max 3)  14. TEST ANALYSIS

**TIER 0-1 (condensed report — merge sections to save ~1.5K output tokens):**
Combine META + SCOPE FENCE + VERDICT into the merged banner. Skip: DEPLOYMENT RISK (always LOW at TIER 0-1), SKIPPED STEPS (obvious), VERIFICATION PASSED (inline), BACKLOG IN SCOPE (check manually). Print only: banner, FINDINGS (if any), QUALITY WINS, NEXT STEPS. ~500 tok output vs ~3K for full report.

Each finding:
```
R-1 [MUST-FIX] Missing orgId filter in query -- returns all orgs' data
  File: src/order/order.service.ts:87
  Confidence: 92/100
  Evidence: findMany at :87 has no orgId in WHERE clause
  Fix: Add `organizationId: orgId` to the WHERE clause
```

**NIT visual subordination:**
```
NITs (3 items -- style/readability, no functional impact):
  R-12 unused import at auth.ts:3
  R-13 prefer ?? over || at config.ts:45
  R-14 collapsible if at user.service.ts:88
```

### Test Coverage Delta (TIER 2+)

For each changed production file: check pre-computed test references (Phase 0.5). Symbols with 0 test refs -> RECOMMENDED finding at TIER 2+, observation in TEST ANALYSIS at TIER 1.

### Backlog Persistence (after execute or after report if no execute)

Persist ALL findings to `memory/backlog.md`:
- Excluded findings (0-50 confidence): backlog with `[low-confidence]` or `[below-threshold]` tag
- Unfixed reported findings (51-100): backlog
- Pre-existing issues: backlog
- Deduplicate by fingerprint: `file|rule-id|signature`

### Report Persistence (TIER 1+)

Save the full report to `memory/reviews/YYYY-MM-DD-<scope>.md`.

### Tag Reviewed Commits (per-commit audit trail)

Naming convention: `reviewed/<short-hash>` tags the individual commits that were examined. This is distinct from the post-execute wrapper tag (`review-YYYY-MM-DD-<slug>`) that marks the fix commit produced by Phase 4.

```bash
for H in $(git log --format='%H' REVIEWED_FROM..REVIEWED_THROUGH); do
  h=$(git log --format='%h' -1 "$H")
  git tag -f "reviewed/$h" "$H"
done
```

Skip tagging when scope is `staged` or `uncommitted`.

### Knowledge Curation

Run `knowledge-curate.md` (if loaded): `WORK_TYPE="review"`, `CALLER="zuvo:review"`, `REFERENCE=<commit range or "staged">`.

### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check -> structured questions -> TSV emit -> markdown append.

If the gate check skips, you MUST print one of:
- `RETRO: skipped (trivial session, <3 findings and no fix-loop)`
- `RETRO: skipped (<reason>)` — reason must name a specific condition, not "nothing interesting"

Silently omitting the retro is a protocol violation. Track record shows ~90% of review runs skip this step without marking why, which produces no learning signal. If you are tempted to skip, print the reason explicitly so the pattern is visible in `~/.zuvo/retros.md`.

## Completion Gate Check (HARD GATE — blocks output)

Before printing `REVIEW COMPLETE` or the NEXT STEPS block, verify every item below. If any item is unchecked, execute the missing step now — do not emit the completion text with unfinished items.

```
COMPLETION GATE CHECK
[ ] Diff type classified and printed: [prod-only/test-only/mixed]
[ ] CQ self-eval printed for each changed production file
[ ] Q1-Q19 printed for each changed test file (if any)
[ ] Adversarial review ran — at least 2 sequential passes with findings printed
[ ] All findings confidence-scored
[ ] Backlog persistence ran (memory/backlog.md updated or explicitly N/A)
[ ] Report saved to memory/reviews/YYYY-MM-DD-<scope>.md (TIER 1+)
[ ] reviewed/<hash> tags created (skip for staged/uncommitted scope)
[ ] Knowledge curation ran (if knowledge-curate.md loaded)
[ ] Retrospective ran OR explicit "RETRO: skipped (<reason>)" printed
[ ] Run: TSV line printed and appended to ~/.zuvo/runs.log
```

Enforcement: print the gate check as a checklist with actual `[x]` / `[ ]` marks so the user can audit. If any `[ ]` remains, loop back and complete it before emitting the NEXT STEPS block.

### Validity Gate (REQUIRED — print BEFORE Run line, AFTER retro append + append-runlog)

```
VALIDITY GATE
  triggers_held:
    diff_lines: <count>
    diff_type: [prod-only|test-only|mixed]
    language: <typescript|python|...>
    framework: <nextjs|nestjs|astro|hono|react|django|...|none>
    tier: <0|1|2|3>
  required_tool_calls:
    review_diff: [<N> findings across 9 checks | NOT_CALLED — VIOLATES_TRIGGER]
    changed_symbols: [<N> symbols | NOT_CALLED — VIOLATES_TRIGGER]
    diff_outline: [<N> files outlined | NOT_CALLED — VIOLATES_TRIGGER]
    impact_analysis: [<N> affected_tests / <N> blast | NOT_CALLED — VIOLATES_TRIGGER]
    scan_secrets: [<N> hits | NOT_CALLED — VIOLATES_TRIGGER]
    search_patterns: [<N> CQ8/CAP hits | NOT_CALLED — VIOLATES_TRIGGER]
    find_references: [<N> chains | not_required (no symbol cited) | NOT_CALLED — VIOLATES_TRIGGER]
    stack_specific (nest_audit/framework_audit/python_audit/etc.): [<result> | not_required | NOT_CALLED — VIOLATES_TRIGGER]
  postamble:
    retros_log_appended: [yes(bytes_added=N) | NOT_APPENDED — VIOLATES_REQUIRED_POSTAMBLE]
    retros_md_appended: [yes(entry_count=N) | NOT_APPENDED — VIOLATES_REQUIRED_POSTAMBLE]
    verify_audit_pass: [yes(<verified>/<total> findings) | NOT_RUN | REJECTED]
  gate_status: [PASS | FAIL — <which gates missing>]
```

If `gate_status = FAIL`, override the VERDICT to `INCOMPLETE` regardless of finding count, append `[VALIDITY GATE FAIL]` to the Run line NOTES column, and add a backlog item `B-review-incomplete-<date>`.

Print this Validity Gate **AFTER** the retro append and `~/.zuvo/append-runlog` call (so postamble fields can be filled with `yes(verified)`).

### NEXT STEPS Block

```
REVIEW COMPLETE -- <VERDICT>, <N> issues found.
DEPLOYMENT RISK: <RISK LEVEL> -- <deploy strategy>
Run: <ISO-8601-Z>	review	<project>	<CQ>	<Q>	<VERDICT>	<TASKS>	<DURATION>	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>

NEXT STEPS: "fix" (all) | "blocking" (MUST-FIX only) | "auto-fix" (zuvo:build) | "skip"
```

Append the Run line via the retro-gated wrapper (NOT direct `>> runs.log`):

```bash
echo -e "$RUN_LINE" | ~/.zuvo/append-runlog
```

The wrapper:
- Verifies the matching `RETRO:` entry in `retros.log` (skill+project). Missing → exit 2.
- Runs `~/.zuvo/verify-audit` on the report at `memory/reviews/<date>-<scope>.md`. Findings without `file:line` citations → exit 2.
- On both pass: appends to `runs.log` and prints confirmation.

If the wrapper exits non-zero: do NOT manually append to runs.log. Fix the cause and re-run.

---

## Phase 4: Execute (FIX-ALL / FIX-BLOCKING / AUTO-FIX)

Read and follow the fix loop protocol from `../../shared/includes/fix-loop.md`.

```
Input:
  FINDINGS: [R-N findings to fix, per mode]
  SCOPE_FENCE: [allowed files from triage]
  MODE: FIX-ALL | FIX-BLOCKING | AUTO-FIX
```

- **FIX-ALL:** apply MUST-FIX + RECOMMENDED + NIT
- **FIX-BLOCKING:** apply MUST-FIX only
- **AUTO-FIX:** dispatch `zuvo:build` with MUST-FIX findings as context (closed-loop, max 1 cycle)

**Note:** When FIX/BLOCKING/AUTO-FIX mode is active, Phase 1.6 adversarial runs in FIX variant (sequential providers validate and fix between passes). The fix-loop.md below handles primary audit findings. Adversarial findings discovered and fixed during Phase 1.6 do NOT appear in the fix-loop — they are already resolved.

### Review-Specific Wrapper

After fix-loop.md completes:

1. **Git tag:** `git tag review-YYYY-MM-DD-<short-slug>` on the fix commit. This is distinct from the per-commit `reviewed/<hash>` tags created in Phase 3 — that set marks what was *audited*, this one marks what was *fixed*. Both can coexist on the same repo.
2. **Post-Execute block:**
```
===============================================================
EXECUTION COMPLETE
===============================================================
FILES MODIFIED: [list]
FIXED: [list of R-N items fixed]
TESTS WRITTEN: [list]
VERIFIED: Tests PASS, Types PASS
Commit: [hash] -- [message]
Tag: [tag name]
===============================================================
```
3. **Backlog persistence:** unfixed items from FIX-BLOCKING (RECOMMENDED + NIT) or partial fix

### Staged Scope Stash Management (B5 fix)

When scope is `staged`:

```
1. git stash --keep-index        # save unstaged changes
2. Run fix-loop.md               # applies fixes, tests, commits
3. git stash pop                 # ALWAYS runs, even if fix-loop fails
```

Treat `stash pop` as a finally block. If fix-loop aborts, pop the stash and report the failure.

### Closed-Loop Auto-Fix

When mode is AUTO-FIX:
1. Collect MUST-FIX findings into a fix list
2. Dispatch `zuvo:build` with scope = affected files, task = fix descriptions, mode = `--auto`
3. After build completes, auto-run `zuvo:review` on the fix diff (TIER 1 minimum)
4. If re-review finds new MUST-FIX: report (do NOT loop -- max 1 cycle)
5. If clean: `CLOSED-LOOP COMPLETE -- all MUST-FIX resolved`

---

## Batch Mode (batch <file>)

Process a queue of commits: review, fix, tag -- one at a time, zero interactive stops.

### Input Format

One commit hash per line, optionally with description:
```
ecbf4351c | perf: memoize productById Map
57a26ea14 | test: broaden cross-app coverage
```

Lines starting with `#` are comments. Lines with `- [x]` or `- [!]` are skipped (resume mode).

### Enrich Queue

Validate each hash (`git cat-file -t`). Rewrite file with `- [ ] <hash> | <msg> | +X/-Y | N files`.

### Per-Commit Loop

For each `[ ]` entry: read diff -> triage -> audit at full depth -> fix (FIX-ALL) -> tag (`reviewed/<hash>`) -> clean backlog -> update queue. **TIER 3 in batch:** run full review inline (sequential agents). Do NOT skip or redirect. If fix breaks tests, revert and mark `[!]`. Every `[x]` must include a code observation.

**Resume:** `[x]` skip, `[!]` skip, `[ ]` process. **Completion:** print totals and queue path.

---

## Utility Modes

### tag

No audit. Clean review backlog:
1. Read `memory/backlog.md`
2. For each unchecked hash: `git merge-base --is-ancestor <hash> HEAD`
3. If yes, remove the line
4. Print: "Review backlog cleaned. N removed, M remaining." -> STOP.

### mark-reviewed

No audit. Create `reviewed/` tags:
- `zuvo:review mark-reviewed` -> all commits on branch (merge-base..HEAD)
- `zuvo:review mark-reviewed HEAD~3` -> last 3 commits
- After tagging, clean `memory/backlog.md`. STOP.

### status

No audit. Show unreviewed commits:
1. Build set of reviewed hashes from `reviewed/*` tags
2. Walk last N commits (default 100, configurable with `--depth N`)
3. Print unreviewed: `Total: N | Reviewed: X | Unreviewed: Y` -> STOP.
