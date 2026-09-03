---
name: review
description: >
  Structured code review with parallel audit agents, confidence-scored triage,
  and optional auto-fix. Examines uncommitted changes, staged diffs, commit
  ranges, or specific paths. Produces a tiered report (MUST-FIX / RECOMMENDED /
  NIT) backed by evidence, then optionally applies fixes with verification.
category: Core
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
      - resolve_php_namespace
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
      - analyze_context_graph
      - audit_compiler_readiness
      - trace_component_tree
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
      - trace_php_event
      - find_php_views
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
| `../../shared/includes/quality-gates.md` | CQ1-CQ40 section only* | Q1-Q25 section only** | Full |
| `../../shared/includes/cross-provider-review.md` | Full | Full | Full |
| `../../rules/cq-patterns.md` or `cq-patterns-core.md` | Per code type*** | **SKIP** | Per code type*** |
| `../../rules/cq-checklist.md` | TIER 1+ | **SKIP** | TIER 1+ |
| `../../rules/testing.md` | **SKIP** | Full | Full |
| `../../rules/security.md` | If security signals | **SKIP** | If security signals |

\* **CQ section only:** Read from start of file to the `## Q1-Q25` heading. Skip Q section.
\*\* **Q section only:** Read from `## Q1-Q25: Test Quality Gates` heading to end of file. Skip CQ section.
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
| `commits A,B,C` | Specific non-consecutive commit hashes | Union-diff via `git show` per hash, concatenated. **Range-derived steps use the SPAN**: `REVIEWED_FROM=<oldest-hash>^`, `REVIEWED_THROUGH=<newest-hash>`, and the artifact's `files:` lists ONLY the files from the named commits (never `*`) — the span may contain commits you did not review |
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
| _(none)_ | **FIX-AUTO (default)** | Audit, then **automatically apply** MUST-FIX + localized/high-confidence RECOMMENDED, verify, and run the post-fix adversarial gate — NO menu wait. NIT + structural-refactor RECOMMENDED → backlog (not force-applied). |
| `--report-only` | REPORT | Audit and present findings only. Do NOT touch code; print the menu and stop. Use when you want to read before acting. |
| `fix` | FIX-ALL | Apply EVERY reported fix incl. NIT, then verify + gate. |
| `blocking` | FIX-BLOCKING | Apply only MUST-FIX findings, then verify + gate. |
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
| CQ1-CQ40 evaluation | Skip | Yes (lead inline) | Yes (CQ Auditor agent) | Yes (CQ Auditor agent) |
| Q1-Q25 on test files | Skip | If present (lead) | Yes | Yes |
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

Check if knowledge base exists BEFORE loading the protocol — **worktree-aware**: resolve `MAIN_ROOT=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')` (fallback `--show-toplevel`) and check `Glob("$MAIN_ROOT/knowledge/*.jsonl")` (knowledge lives at the MAIN checkout per `backlog-protocol.md`; a CWD-relative glob in a linked worktree finds nothing and silently skips priming — same bug class as the old `memory/knowledge*.md` pre-check that pointed at a path NO skill writes). If no files found, skip — do NOT load `knowledge-prime.md` (saves ~140L / ~1.6K tokens). If files exist, then load and run:
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

**Absent-in-build substitution (per-tool, NOT whole-server).** If a required tool above is genuinely absent from THIS build's tool surface (verified absent, not merely deferred — see `codesift-setup.md` absent-in-build detection), run the documented equivalent and record `<tool>: absent-in-build (<equivalent>: <result>)`, which SATISFIES the gate. This is distinct from whole-server absence (`codesift-setup.md` handles that). Substitution map:

| Absent tool | Equivalent | Recorded as |
|-------------|-----------|-------------|
| `review_diff` | `audit_scan` (compound 5-gate) | `review_diff: absent-in-build (audit_scan: <findings>)` |
| `changed_symbols` + `diff_outline` | `impact_analysis` + `get_file_outline` | `changed_symbols: absent-in-build (impact_analysis+get_file_outline: <result>)` |
| `scan_secrets` | `grep` secret-scan (high-entropy/key patterns on diff) | `scan_secrets: absent-in-build (grep secret-scan: <count>)` |

**Fence the substitute's output to the reviewed file set.** `audit_scan` (and the other compound substitutes) scan the **repository**, not your diff — a scoped review that scores their raw output drowns in repo-wide pre-existing findings that this change never touched, and the CQ score stops describing the diff. After each substitute call, discard findings whose file is outside the reviewed file set (`git diff --name-only "${REVIEWED_FROM}..${REVIEWED_THROUGH}"`) BEFORE CQ scoring, and record whether the tool honored the requested fence: `audit_scan: fence-honored` or `audit_scan: fence-ignored (filtered <N>→<M>)`. Two exceptions to the fence, both about causality rather than file membership: a finding in an **unchanged** file that this diff *caused* — a caller broken by a changed signature, a consumer of a removed export, a now-unreachable branch — is IN scope and must be triaged normally, because the diff is what made it true. And findings outside the fence that the diff did not cause are not silently dropped knowledge: they are pre-existing debt, so backlog them separately rather than scoring them against this diff.

### Forbidden escape hatches

| Value | Forbidden when | Required value instead |
|-------|----------------|------------------------|
| `review_diff: skipped (TIER 0)` | EVER (TIER 0 still uses CodeSift pre-compute per Tier table) | `review_diff: <findings_per_check>` |
| `scan_secrets: not_run` | EVER | `scan_secrets: <count>` |
| `changed_symbols: N/A (test-only diff)` | EVER (test files have changed_symbols too) | `changed_symbols: <count>` |
| `codesift: unavailable` | `mcp__codesift__*` was in deferred-tools session-start banner | `codesift: deferred-not-preloaded (FAILURE: skill required preload)` |
| `RETRO: skipped (nothing interesting)` | EVER | One of: `RETRO: skipped (trivial session, <3 findings and no fix-loop)` OR full retro appended |
| `Adversarial: skipped (context budget)` / `(tight context)` | EVER | Chunk the diff (see section 1.6 CONTEXT BUDGET) and run adversarial per chunk, OR exit with `BLOCKED_CONTEXT_BUDGET` and ask the user to narrow scope. Skipping is never an option. |
| `Adversarial: skipped (already mechanically detected)` / `(scanners covered it)` | EVER | This inverts the rationale. Adversarial's purpose is to find what mechanical scanners MISSED (CodeSift/audit_scan find patterns; adversarial finds semantics). Skipping because scanners ran is a category error. Run it. |
| `Adversarial: skipped (self-review, low value)` / `(I wrote this code so adversarial adds little)` | EVER | Self-review REQUIRES MORE adversarial coverage, not less. Section 1.1 + 1.6 mandate `--multi` on SELF-REVIEW. Anchoring bias is exactly why adversarial exists here. |
| `Adversarial: skipped (small diff)` / `(<N lines so not worth)` | EVER (Tier table line 284 mandates adversarial at TIER 0) | Run it. Even <15 line diffs get the pass per the Tier table — a single-line semantic bug (e.g. inverted comparison, off-by-one, swapped args) is exactly the class adversarial catches that scanners cannot. |
| `Adversarial: skipped (documented honestly)` / `(noting the skip transparently)` | EVER | Honesty about a violation is still a violation. The Validity Gate evaluates whether the gate ran, not whether the skip was politely worded. Run it or exit BLOCKED. |
| Any `Adversarial: skipped (<reason>)` where `<reason>` is not on the whitelist | EVER | Whitelist (from section 1.6): `single_provider_only` (exit 3), `timeout` (exit 124), `BLOCKED_CONTEXT_BUDGET` (after chunking attempt failed). Nothing else. |
| `ok` / any | **4** | **Review COMPLETED but the input was TRUNCATED** — part of the change reached no provider (`input_truncated=true` in the artifact, which also lists the omitted files) | **Do NOT report the review complete.** Findings returned are real; the ABSENCE of findings says nothing about the omitted files. Re-run over the omitted set or split the input, then merge verdicts |

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

### Cross-checkout / worktree scope

When the REVIEWED scope path resolves to a repo or worktree that is NOT the CWD, do NOT degrade CodeSift — re-point it at the target instead:

1. **Resolve `TARGET_REPO`.** `git -C <scope-path> rev-parse --show-toplevel`. If it differs from CWD's toplevel, set `TARGET_REPO=<that path>`.
2. **Pass `repo=`/`path=` explicitly** to `review_diff`, `changed_symbols`, `scan_secrets`, `find_references` (and `index_folder`) so they target `TARGET_REPO`, not CWD.
3. **Fresh worktree staleness — index the worktree ONCE, then proceed.** Run
   `index_status(path=TARGET_REPO)`. If the branch's commits are not indexed, the semantic tools
   would silently answer from the stale main checkout, so they are not usable for this scope
   *yet*. The resolution is `index_folder(path=TARGET_REPO)` — auto-indexing refuses linked
   worktrees and defers to the parent, so a worktree typically has no index of its own and this
   is its FIRST index, not a re-index. Degrade to the authoritative local source — git-diff-scoped
   `grep` over `git diff "${REVIEWED_FROM}..${REVIEWED_THROUGH}"`, plus bounded `Read` on the changed
   files, recorded as `codesift: degraded (worktree not indexed)` — only if that `index_folder`
   call itself fails.
   This is the same rule as `../../shared/includes/codesift-setup.md` → "Worktree path rejected by
   `index_file`"; **that include is the single source of truth — if this section and the include
   ever disagree, the include wins.** It also covers the sibling-worktree case (a fresh index that
   is simply WIDER than your scope). Neither branch permits redirecting the check at the main
   checkout: that reports on code you are not reviewing, which is the stale-analysis trap this
   section exists to prevent.
   *(This paragraph carried the pre-2026-08-11 text — "do NOT index the worktree" — for one commit
   after the include was corrected, which is exactly the drift the "include wins" clause above now
   makes cheap to resolve. The include's own measurement: 21.8M tokens, 13.2% of one run, spent on
   a grep fallback that an `index_folder` call would have made unnecessary.)*
4. **Keep `TARGET_REPO` consistent** with the Phase 3 destructive-persistence precondition (the repo `REVIEWED_FROM..REVIEWED_THROUGH` is resolved against MUST be the same `TARGET_REPO` analysis and tagging both reference).

### Read-only audit checkout (TIER 2+, commit-range scopes)

The auditors read; the lead writes. Until that was a boundary in the filesystem it was only a
convention, and two things went wrong because of it. A review of a commit range runs while the tree
keeps moving — this skill already carries a "Working-Tree Staleness Check" for exactly that, i.e. it
knows findings can be reported against a file HEAD has since changed. And in FIX modes the lead
starts editing while auditors may still be reading, so a finding can be produced from a tree that
no longer matches the range it claims to describe.

Give the audit agents a **frozen, unwritable checkout of `REVIEWED_THROUGH`** and keep the live tree
for the fix loop:

```bash
REVIEW_TREE=$(mktemp -d)/audit-$(git rev-parse --short=7 "$REVIEWED_THROUGH")
if git worktree add --detach -q "$REVIEW_TREE" "$REVIEWED_THROUGH" 2>/dev/null; then
  chmod -R a-w "$REVIEW_TREE" 2>/dev/null          # enforcement, not etiquette
  echo "[REVIEW] audit tree: $REVIEW_TREE (read-only @ $(git rev-parse --short=7 "$REVIEWED_THROUGH"))"
else
  REVIEW_TREE="$(git rev-parse --show-toplevel)"
  echo "[REVIEW] audit tree: live checkout (read-only worktree unavailable) — findings may race the fix loop"
fi
```

Pass `REVIEW_TREE` to every dispatched agent as the root they analyze. The lead keeps using the live
checkout: CodeSift pre-compute, the fix loop, the artifact and the retro all belong there.

**Teardown is mandatory and must survive a failed run** — `chmod -R a-w` makes the directory
undeletable by the normal path, so a review that dies mid-flight leaves an unwritable worktree and a
registered entry that `git worktree list` will keep showing:

```bash
# The guard is not defensive padding. On the fallback path $REVIEW_TREE IS the live checkout, and
# an unguarded teardown would then `chmod -R u+w` the entire working repository — stripping the
# read-only bits off .git/objects, mounted secrets and locked configs — and try to `worktree
# remove` the main tree. A failed worktree creation must not damage the repo it failed to copy.
if [ -n "${REVIEW_TREE:-}" ] && [ "$REVIEW_TREE" != "$(git rev-parse --show-toplevel)" ]; then
  chmod -R u+w "$REVIEW_TREE" 2>/dev/null
  git worktree remove --force "$REVIEW_TREE" 2>/dev/null
fi
```

Run it at the end of Phase 3 and on every abort path. Record the outcome in the Validity Gate as
`audit_tree: readonly(<sha7>) | live(<reason>)`. `live` is honest and allowed; silently claiming
`readonly` when the worktree was never created is not.

**Do NOT use this for the fix loop.** Phase 4 edits real files, runs the real suite and commits — it
belongs in the live checkout, and pointing it at a frozen detached tree would produce commits on no
branch. The split is the point: frozen tree for the eyes, live tree for the hands.

### Stack Detection (TIER 2+)

Detect tech stack and load matching rules:

| Stack indicator | Rules file |
|----------------|------------|
| tsconfig.json | `../../rules/typescript.md` |
| next.config.* or app/layout | `../../rules/react-nextjs.md` |
| nest-cli.json or @nestjs/* | `../../rules/nestjs.md` |
| requirements.txt / pyproject | `../../rules/python.md` |
| composer.json | `../../rules/php.md` |
| composer.json with yiisoft/yii2 | `../../rules/yii2.md` (with php.md — counts as ONE slot) |
| package.json with express (no Next/Nest) | `../../rules/express.md` |
| astro.config.* | `../../rules/astro.md` |
| go.mod | `../../rules/go.md` |
| Cargo.toml | `../../rules/rust.md` |
| *.csproj / *.sln | `../../rules/dotnet.md` |
| Gemfile | `../../rules/ruby.md` |

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

**Dispatch is already authorized — do not ask, do not downgrade.** Invoking this skill IS the
request for every agent and gate it mandates, so a session rule about unprompted Agent use does not
apply here. Only a harness with NO dispatch capability takes the documented single-agent fallback,
and it still runs every gate inline — see `../../shared/includes/env-compat.md`. Skipping a mandated
agent and self-scoring the result is a substituted gate, not a degraded run.

## Phase 1: Audit

**Steps:** 1.1 Self-Review Disclosure -> 1.2 Review Header -> 1.3 Agent Dispatch / Inline Audit -> 1.4 CQ (TIER 1+) -> 1.5 Q1-Q25 (if tests) -> 1.6 Adversarial (ALL tiers) -> 1.7 Result Merging

**With --thorough:** steps 1.3-1.5 become 3 independent passes in parallel, merged via majority voting, then adversarial runs after merge.

### 1.1 Self-Review Disclosure

Check whether you wrote any of the code being reviewed in this session. If yes, add a `SELF-REVIEW` marker to the header. Self-review detected -> pass `--multi` to the adversarial script (forces ALL available providers, not a rotating single). **The flag is `--multi` — do NOT pass `--all-providers`** (a phantom flag): the DISPATCH-SHAPE flags are limited to `--multi/--single/--rotate/--exclude/--exclude-last` (other flags such as `--mode`, `--artifact`, `--append-artifact`, `--json` are separate and valid); an unknown flag exits 2 and silently drops you to weaker coverage. Probe once if unsure: `~/.zuvo/adversarial-review --help | grep -- --multi`. `--multi` exits 3 (`single_provider_only`) when <2 providers exist — only then fall back to `--rotate`/`--single`.

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
  type: "general-purpose"   # NOT Explore — Explore lacks mcp__codesift__* and CodeSift precheck hooks reject the dispatch
  instructions: read agents/behavior-auditor.md
  input: diff, tech stack, change intent, PRECOMPUTED_DATA, PROJECT_CONTEXT

Agent 2: Structure Auditor
  model: "sonnet"
  type: "general-purpose"
  instructions: read agents/structure-auditor.md
  input: diff, tech stack, change intent, PRECOMPUTED_DATA, PROJECT_CONTEXT

Agent 3: CQ Auditor
  model: "sonnet"
  type: "general-purpose"
  instructions: read agents/cq-auditor.md
  input: diff, tech stack, change intent, PRECOMPUTED_DATA, PROJECT_CONTEXT
```

Each agent receives: diff, tech stack, change intent, PRECOMPUTED_DATA, PROJECT_CONTEXT (global error handlers, middleware, decorators).

### Result Merging (after agents complete)

1. Collect BEHAV-N, STRUCT-N, and CQ findings
2. Deduplicate -- same file:line + same issue = keep the one with more evidence
3. Renumber sequentially as R-1, R-2, R-3...

### 1.4 CQ Self-Evaluation (TIER 1+)

For each changed production file, run CQ1-CQ40. Format: `CQ EVAL: file.ts (NL) | CQ1=1 CQ2=0 ... | Score: X/Y -> PASS/FAIL | Critical gates: CQ4=0(no orgId:87)`. CQ critical gate failures (CQ3, CQ4, CQ5, CQ6, CQ8, CQ14) always produce MUST-FIX.

**Where the 40 gates go (TIER 3, many files).** Every gate must be EVALUATED for every file — that
is not negotiable and no summary form relaxes it. What changes is where the evidence is printed:
40 gates × 15 files buries the findings the report exists to deliver. So:

- **The full per-file gate line always goes into the review artifact** (`memory/reviews/…`), for
  every file. That is the auditable record, and it must be complete.
- **In the chat report**, print the full line for any file with a `0`, an `N/A`, or a critical-gate
  failure; for a fully clean file print one line: `CQ EVAL: file.ts (NL) | 40/40 clean`.
- **Never aggregate across files** (`cq=38/40 overall`). Per-file scores are what caught Q7=0 and
  Q11=0 hiding under an aggregate; the compact form above is per-file, just shorter.

A clean-file summary line is only honest if the gates really ran. If some were not evaluated, that
file is not `clean` — print the full line with the unevaluated gates marked, per
`../../shared/includes/gate-registry.md`.

### 1.5 Q1-Q25 Evaluation (if test files in diff)

For each test file, run Q1-Q25. Format: `Q EVAL: file.spec.ts | Q1=1 Q2=1 ... | Score: X/Y -> PASS | Critical: Q7=1 Q11=1 Q13=1 Q15=1 Q17=1 -> PASS`.

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

Cross-model adversarial review using external providers. Runs **sequentially** via `--multi` — each pass fans out to every available provider, and different random provider. Text mode (no `--json`).

**PROPORTIONALITY (HARD — a tiny diff gets a FAST pass, not a 20-minute grind).** Adversarial still runs at every tier (a 3-line change CAN hide an inverted comparison), but the COST must match the diff. The 2026-07-10 pathology: a 3-line icon swap ran the full multi-pass rotate with each hung provider eating the 240s `PROVIDER_TIMEOUT` × several passes ≈ **20 minutes**. That is a defect, not diligence. Scale the pass by tier:

| Tier | Diff | Adversarial shape |
|------|------|-------------------|
| **TIER 0 (NANO)** | <15 prod-logic lines, 1 file, no risk signal | **ONE `--single` pass, `ZUVO_REVIEW_TIMEOUT=60`.** No rotate, no second pass. `git diff … \| ZUVO_REVIEW_TIMEOUT=60 ~/.zuvo/adversarial-review --single --mode code`. ~60s ceiling. |
| **TIER 1 (LIGHT)** | 15–100 lines | Up to **2** `--multi` passes, default timeout; stop early on a clean pass. |
| **TIER 2–3** | larger / risk signals | Full sequential `--multi` (2–3 passes) as below. |

- **Self-review overrides tier-down for correctness, but keep the timeout tight on tiny diffs:** SELF-REVIEW still forces `--multi` (section 1.1) — but on a TIER 0 diff run it as ONE `--multi` pass with `ZUVO_REVIEW_TIMEOUT=60`, not multi-pass. One cross-model look, bounded to ~60s.
- **A hung/timed-out provider is NEVER retried in a manual loop on a tiny diff.** If a provider times out at TIER 0/1, record `Adversarial: partial (<provider> only, others timed out)` and finalize — do NOT hand-retry the remaining providers (that hand-retry loop is exactly what turned 3 lines into 20 minutes). Chunking/retry is a TIER 2–3 concern for genuinely large diffs.
- **Always run in the background or with a long Bash `timeout`** per `adversarial-loop.md` — never let the 120s Bash-tool default kill the pass mid-flight.

If `adversarial-review` not in PATH: `~/.zuvo/adversarial-review` (stable; the versioned cache path breaks after any release)

**BASE PREFLIGHT (run BEFORE piping any commit-range diff — a stale base wastes the whole pass).** A two-dot `<base>..<tip>` diff computed against a base that is no longer an ancestor of the tip shows **reverse hunks of other sessions' pushes** — code being "deleted" that was actually added elsewhere. Every provider then reports a confident CRITICAL about a revert that does not exist (observed: one full multi-provider pass burned, 5/5 providers false-CRITICAL). Before the pipe:

```bash
git fetch -q origin                                    # the base may have moved since you resolved it
git merge-base --is-ancestor "$REVIEWED_FROM" "$REVIEWED_THROUGH" || echo "STALE BASE"
```

If it is NOT an ancestor: either merge/rebase first, or review `$(git merge-base "$REVIEWED_FROM" "$REVIEWED_THROUGH")..$REVIEWED_THROUGH` instead. Never send a known-stale range to the providers "to see what they say" — the findings are unfalsifiable noise you then have to disprove one by one.

**TRUNCATED INPUT INVALIDATES THE PASS FOR THE OMITTED FILES.** The staircase above is proactive; this is the reactive backstop for when it was not applied. If the wrapper prints `input truncated` (or the piped diff exceeds the provider cap), the pass did NOT review the files that fell off the end — and the highest-risk file is as likely to be dropped as any other. Do not accept that pass as coverage: re-run per production file (staircase step 1) for the omitted files before triage, and never let a nominal "pass 1 clean" stand for a file the provider never received.

**Self-review escalation:** If SELF-REVIEW marker set in 1.1, pass `--multi` flag.

**Status handling (D2+D3+D4, 2026-05-17):** When the script exits non-zero or returns non-`ok` JSON status, branch:

- **exit 3 / `single_provider_only`** — `--multi` was requested but post-host-exclusion only 1 provider remains. Two options: re-invoke with `--single` (accept reduced consensus and note it in the review header) OR skip this pass and note `Adversarial: skipped (single_provider_only — install second provider for diversity)` in the review output.
- **exit 124 / `status: "timeout"`** — ALL providers timed out. Record `Adversarial: skipped (timeout)` and continue to next pass (or finalize if last pass).
- **exit 125 / `status: "suspended"`** — the HOST slept mid-run (`suspended_seconds` says how long); the providers were never given a chance. This is not reduced coverage and not a provider fault, so it is NOT a skip reason: **re-invoke the same pass once.** If the retry also returns 125, record it as `timeout` (same practical effect — no review — and the whitelist stays closed). Never report a suspended run as blocked provider infrastructure.
- **`status: "partial"` with exit 0** — some providers returned, others did not. Surface `timeout_count` in the review header (e.g. `Adversarial pass 1: cursor-agent (1 of 2 providers; gemini timed out)`) so the user sees coverage was reduced.

**Provider accounting — a block is only "used" if it actually reviewed.** Count a provider toward `providers_used` only when its block contains at least one verdict or finding. A block that holds nothing but an execution error, a usage/auth message, or an empty result is `provider_failed`, NOT a used provider. Otherwise the aggregate header claims cross-provider coverage that never happened — the same fake-coverage failure the Validity Gate exists to catch. If that drops the count below the tier's minimum, treat it as reduced coverage (`Adversarial: partial (…)`), never as a satisfied gate.

**Unhealthy-provider short-circuit.** Within one review run, after a provider returns two empty/error-only blocks, mark it unhealthy and stop dispatching to it for the remaining passes (including fix-delta passes) — repeated 5–8 minute waits buy nothing. Keep dispatching to the rest, and preserve the floor of **two** independent providers; if dropping the unhealthy one would take you below two, the run is reduced-coverage and must say so rather than silently continuing.

**Cross-pass provider tracking:** `--multi` already runs every available provider on each pass, so
there is nothing left to rotate and `--exclude-last` is no longer threaded between calls — it
existed to force variety when each pass got exactly one provider. Still capture
`providers_used_list` (array field) from each pass's JSON: it is the record of who actually
answered, which is what tells a later reader whether a pass was genuinely cross-model or quietly
degraded to one provider because the others timed out. (The string field `providers_used` cannot
be indexed in jq; use the array.)

**CONTEXT BUDGET handling (the constructive escape valve — read this before invoking the "tight budget" rationalization):**

Adversarial CLI providers have ~150K char input limits (varies: codex ~200K, gemini ~100K, cursor-agent ~150K). If `git diff "${REVIEWED_FROM}..${REVIEWED_THROUGH}" | wc -c` exceeds the smallest provider's limit OR the current session is genuinely close to its own ceiling, do NOT skip adversarial. Take the staircase in order:

1. **Per-file chunking.** Split the diff per file (`git diff --name-only "${REVIEWED_FROM}..${REVIEWED_THROUGH}"`) and run adversarial separately on each file's diff. Aggregate findings, dedupe by fingerprint. Per-file passes still satisfy the gate.
2. **Hunk-level chunking** (if a single file's diff is still too large): split on `@@` hunk boundaries with surrounding context. Run per-hunk, aggregate.
3. **Drop --rotate to --single fastest provider.** Reduces parallelism but keeps adversarial coverage. Note in header: `Adversarial: degraded (--single <provider>, context-budget chunked N files)`.
4. **Last resort — exit BLOCKED:** if even single-provider per-hunk does not fit, exit with status `BLOCKED_CONTEXT_BUDGET` and surface to the user: "Diff is N chars across M files; adversarial cannot complete. Narrow the scope (e.g. `/zuvo:review path/to/subdir/` or `HEAD~3`) and re-invoke." This blocks the review verdict — does NOT silently produce PASS/APPROVED.

What "context budget tight" is NOT a license to do: skip the pass, mark `Adversarial: skipped (context budget)`, and proceed to a verdict. That value is on the forbidden escape hatches list (line 376+) and the Validity Gate will override the verdict to `INCOMPLETE` with suffix `[ESCAPE-HATCH-VIOLATION:adversarial]`.

#### REPORT mode — sequential finding (no fixes)

Each pass uses `--multi` (every available provider runs in parallel). Prepend prior findings summary so each provider targets NEW issues.

```bash
# Proof file FIRST — the artifact you write in Phase 3 must cite it, and
# pipeline-gate-lib.sh::pg_artifact_proven REJECTS an artifact whose adversarial:
# path does not resolve or holds <2 "REVIEW BY:" lines. A review that skips this
# writes an artifact the push gate silently ignores.
# The filename must be unique per REVIEWED RANGE, not a fixed word. With a literal `review`
# default, two concurrent reviews (parallel agents on the same repo — routine here) both
# --append-artifact into ONE file, and pg_artifact_proven's ">=2 REVIEW BY: lines" check is then
# satisfied by lines belonging to the OTHER review. That defeats the proof gate with no error
# anywhere: the mechanical backstop passes on evidence about a different range.
RANGE_KEY=$(printf '%s' "${REVIEWED_FROM}..${REVIEWED_THROUGH}" | shasum | cut -c1-10)
ADV_PROOF="zuvo/proofs/${SLUG:+${SLUG}-}${RANGE_KEY}-adversarial.txt"   # range hash ALWAYS present

# The proof path is carried by --artifact on EVERY pass. --append-artifact is a boolean
# modifier that says "add to that file instead of overwriting it" — it is NOT where the path
# goes. Between 2026-08-07 and 2026-08-09 this block documented `--append-artifact "$ADV_PROOF"`;
# the parser took no value there, so the path fell through to `Unknown argument` and every
# copied pass exited 2 having written nothing. Six ship retros reported it before it was fixed.
# The one-arg form is accepted now as an alias, but write the canonical pair.

# Pass 1 (creates the proof — no --append-artifact, so an earlier run's file is replaced):
git diff "${REVIEWED_FROM}..${REVIEWED_THROUGH}" | ~/.zuvo/adversarial-review --multi --mode code --artifact "$ADV_PROOF"
# → Read output, extract ADV-1, ADV-2

# Pass 2:
(echo "PRIOR FINDINGS: ADV-1 [desc], ADV-2 [desc] — find NEW issues only";
 git diff "${REVIEWED_FROM}..${REVIEWED_THROUGH}") | ~/.zuvo/adversarial-review --multi --mode code --artifact "$ADV_PROOF" --append-artifact
# → Read output, extract ADV-3

# Pass 3 (if provider available):
(echo "PRIOR FINDINGS: ADV-1..3 — final pass, find what everyone missed";
 git diff "${REVIEWED_FROM}..${REVIEWED_THROUGH}") | ~/.zuvo/adversarial-review --multi --mode code --artifact "$ADV_PROOF" --append-artifact
# → ADV-4 or clean → early exit
```

**Check the exit code of every pass.** `0` = reviewed, `3` = single_provider_only (honest degraded),
`1`/`2` = nothing was reviewed. A pass that exits non-zero writes no `REVIEW BY:` line, so an
artifact citing this proof will fail `pg_artifact_proven` at push time — with the failure surfacing
one phase later, in a place that says nothing about the pass that actually died.

**Early exit:** 0 findings from a pass = stop (code is clean from that model's perspective).

#### FIX mode — sequential fix + validation

Same `--multi` pattern but each pass sees the IMPROVED diff after prior fixes.

```bash
# Pass 1: review post-primary-fix code (creates the proof — no --append-artifact)
git diff "${REVIEWED_FROM}..HEAD" | ~/.zuvo/adversarial-review --multi --mode code --artifact "$ADV_PROOF"
# → ADV-1 → apply fix → commit

# Pass 2: validate fix + find new
git diff "${REVIEWED_FROM}..HEAD" | ~/.zuvo/adversarial-review --multi --mode code --artifact "$ADV_PROOF" --append-artifact
# → validates ADV-1 fix + finds ADV-2 → apply → commit

# Pass 3: final validation
git diff "${REVIEWED_FROM}..HEAD" | ~/.zuvo/adversarial-review --multi --mode code --artifact "$ADV_PROOF" --append-artifact
# → clean or ADV-3
```

In FIX mode the fixes land BETWEEN passes, so the last pass reviews content no earlier pass saw.
The artifact you write in Phase 3 covers the FINAL blob of each file (the gate is content-keyed) —
if you fix anything after the last adversarial pass, that pass no longer covers what you are
pushing, and the honest move is one more append, not a re-labelled old one.

Max 2 fix attempts per provider finding. Max 3 passes total.

#### Common rules

- **Use `--multi`** — every available provider reviews the same diff in parallel. This used to say the
  opposite (`--rotate`, one random provider, explicitly warning off the all-provider run) as a cost
  measure. Measured 2026-09-02 on 20 real diffs with Opus-judged findings: 57% of each model's TRUE
  findings are unique to it and no model sees more than 28% of the 347 distinct defects — so one
  provider per review loses roughly two thirds of what was there. For the skill whose entire job is
  finding defects, that is not a cost saving, it is the product.
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

**Structural-refactor findings → defer with a recipe, don't block.** A RECOMMENDED finding whose fix is a structural refactor (extract a module, split a god-file, invert a dependency, restructure a layer) is real but does NOT belong in this review's fix loop — it is multi-file work that `zuvo:refactor` owns. Do not leave it as a vague "consider refactoring": persist it to backlog with a concrete **resolution recipe** (what to extract/split, the target shape, the 2-3 ordered steps, the rule it satisfies) so it is actionable later, and keep it OUT of the MUST-FIX set so it cannot block the merge. A structural refactor surfaced as MUST-FIX on an unrelated diff is scope creep.

**TIER 0-1:** Lead scores each finding inline. `Confidence: [X]/100 -- [reason]`.

**TIER 2+:** Dispatch Confidence Re-Scorer agent:

```
Agent: Confidence Re-Scorer
  model: "sonnet"
  type: "general-purpose"
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

**CQ/Q critical-gate bypass (same rule, added 2026-08-02):** a finding sourced from a CRITICAL gate failure — CQ3, CQ4, CQ5, CQ6, CQ8, CQ14, or Q7, Q11, Q13, Q15, Q17 — also skips the confidence gate at effective confidence 100. Without this the skill contradicted itself: "critical gate failures ALWAYS produce MUST-FIX" and "MUST-FIX blocks merge", yet a CQ4 tenant-isolation finding scored 40 by the re-scorer landed in the backlog as `[below-threshold]` and never blocked anything.

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

**ORDERING (persistence artifacts are SHA-keyed — a later commit invalidates them).** Both gates
here key on the head SHA: `verify-audit` rejects a report whose `Verified-against:` stamp is not
the **current** SHA, and the content-keyed artifact below encodes `<base7>..<head7>` in its own
filename. So finish ALL commits first — including any late CQ/complexity cleanup — and only then
write the report, the artifact, the tags, and the retro. If a commit does land after persistence,
the stamp and the `<head7>` are stale: re-stamp and rewrite the artifact for the new head rather
than shipping a report the verifier will reject. Do the final complexity/structure checks
*before* this section, not after it.

**Content-keyed pipeline-entry artifact (REQUIRED — on successful completion only).**
In addition (or as the same file's first lines), write the content-keyed review artifact
`memory/reviews/<base7>..<head7>-<slug>.md` carrying the machine-readable
`range:` / `files:` header per `../../shared/includes/review-artifact.md`. This is the
signal the pipeline-entry gates read (`pg_range_reviewed`) — the path encodes the reviewed
`<base7>..<head7>` range and the `files:` line records the reviewed production files (or `*`).
Write it **only on success** — a crashed/aborted review must leave no artifact, so a failed
run never grants pipeline coverage. Skip for `staged`/`uncommitted` scope (no committed range).

### Tag Reviewed Commits (per-commit audit trail)

Naming convention: `reviewed/<short-hash>` tags the individual commits that were examined. This is distinct from the post-execute wrapper tag (`review-YYYY-MM-DD-<slug>`) that marks the fix commit produced by Phase 4.

```bash
# Namespace-collision guard: git refs are FILES, so a flat tag named `reviewed`
# and the directory `reviewed/<hash>` cannot coexist. NEVER delete the flat tag
# to make room — it is someone else's ref and deleting it is unrecoverable here.
if git rev-parse -q --verify refs/tags/reviewed >/dev/null; then
  echo "per-commit tags: skipped: namespace-collision(refs/tags/reviewed)"
else
  for H in $(git log --format='%H' "${REVIEWED_FROM}..${REVIEWED_THROUGH}"); do
    h=$(git log --format='%h' -1 "$H")
    git tag -f "reviewed/$h" "$H"
  done
fi
```

If the collision is hit, record `per-commit tags: skipped: namespace-collision(<target>)` in the report and still create the non-conflicting `review-YYYY-MM-DD-<slug>` wrapper tag — the audit trail degrades to the wrapper, it does not become a licence to rewrite existing tags. (`git tag -f` above only ever force-updates the *same* `reviewed/<hash>` name, which is the intended re-review behavior.)

Skip tagging when scope is `staged` or `uncommitted`.

### Knowledge Curation

Run `knowledge-curate.md` (if loaded): `WORK_TYPE="review"`, `CALLER="zuvo:review"`, `REFERENCE=<commit range or "staged">`.

### Follow-up ideas (optional — ZERO ceremony, leaves a receipt)

Follow `../../shared/includes/followup-ideas.md` with `<skill> = review`: append genuine new
ideas to `memory/ideas.md` at the MAIN checkout root if any surfaced, then ALWAYS record the
receipt `~/.zuvo/log-ideas --skill review --count <N>` (N=0 is the normal, honest outcome — do
not invent ideas to inflate it). The receipt makes the un-gated step's silence auditable in
`~/.zuvo/ideas.log` without forcing ideation.

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
[ ] Q1-Q25 printed for each changed test file (if any)
[ ] TIER 2-3: Behavior Auditor (if new prod files) + CQ Auditor + Confidence Re-Scorer DISPATCHED; TIER 3 additionally Structure Auditor as sub-agents — NOT done inline as "lead" (or explicit [DEGRADED: ...] line, forbidden on self-review)
[ ] Every dispatched sub-agent RETURNED and its findings were read — count RETURNS, not dispatches. One still running bought no coverage: record `NO_RETURN(<elapsed>)`, which violates the tier exactly as `NOT_DISPATCHED` does. (2026-08-11: a TIER 3 self-review shipped a release on 2-of-3 auditors because nothing checked this; the third returned 12h later with a real finding.)
[ ] TIER 2-3 Next.js: framework_audit called (nextjs_route_map alone does NOT satisfy it)
[ ] Adversarial review ran — at least 2 sequential passes with findings printed; SELF-REVIEW used --multi (not --rotate)
[ ] All findings confidence-scored
[ ] Backlog persistence ran (memory/backlog.md updated or explicitly N/A)
[ ] No localized RECOMMENDED silently backlogged — every backlogged RECOMMENDED carries a defer-reason of [NIT] or [structural-refactor (multi-file)]; any single-file fix in backlog = drift, route it to Phase 4 instead
[ ] Report saved to memory/reviews/YYYY-MM-DD-<scope>.md (TIER 1+)
[ ] Content-keyed artifact memory/reviews/<base7>..<head7>-<slug>.md written with range:/files:/adversarial: header — the adversarial: field points at the saved `--artifact` output (≥2 providers); an artifact without a real proof no longer grants coverage (on success; skip staged/uncommitted)
[ ] reviewed/<hash> tags created (skip for staged/uncommitted scope)
[ ] Knowledge curation ran (if knowledge-curate.md loaded)
[ ] Retrospective ran OR explicit "RETRO: skipped (<reason>)" printed
[ ] Run: TSV line printed and appended to ~/.zuvo/runs.log
```

Enforcement: print the gate check as a checklist with actual `[x]` / `[ ]` marks so the user can audit. If any `[ ]` remains, loop back and complete it before emitting the NEXT STEPS block.

### Validity Gate (REQUIRED — print BEFORE Run line, AFTER retro append + append-runlog)

> **What is machine-checked, and what is not.** Three of these fields now have independent
> evidence behind them; the rest are self-attested and you should treat them that way.
>
> **RUN THIS after printing the gate** (it is cheap and it is the point):
> ```bash
> printf '%s' "$VALIDITY_GATE_BLOCK" | python3 scripts/verify-review-claims.py \
>   --claims - --anchor "<the reviewed range or artifact slug>" --strict
> ```
> `verify-review-claims.py` reads the HARNESS-written session transcript
> (`~/.claude/projects/<munged-cwd>/*.jsonl`) and compares `tier2_subagents.*: DISPATCHED(...)`,
> `adversarial.passes_run` and `self_review_flag: yes — used --multi` against the `Agent`/`Task`
> and `adversarial-review` tool calls that ACTUALLY executed. A `DISPATCHED(<marker>)` typed
> without a dispatch is now a reported disagreement, not an invisible one.
>
> Plus the two pre-existing mechanical backstops: the content-keyed artifact (`pg_range_reviewed`)
> and its adversarial proof file carrying >=2 `REVIEW BY:` lines (`pg_artifact_proven`).
>
> Still self-attested (no verifier exists): the per-gate CQ/Q scores, the confidence numbers, the
> finding severities, and every `not_required`/`N/A` justification. Adding more forbidden phrasings
> does not change that — cite the transcript check and the artifact pair as evidence, never "the
> Validity Gate passed" on its own.

```
VALIDITY GATE
  triggers_held:
    diff_lines: <count>
    diff_type: [prod-only|test-only|mixed]
    language: <typescript|python|...>
    framework: <nextjs|nestjs|astro|hono|react|django|...|none>
    tier: <0|1|2|3>
  required_tool_calls:
    # VIOLATES_TRIGGER fires ONLY when the tool IS present in this build's surface
    # but was not called. `absent-in-build (<equivalent>: <result>)` = PASS (see
    # MANDATORY TOOL CALLS substitution map). NOT_CALLED on a present tool = violation.
    # A tool CALLED but erroring in-provider (`Transport closed`, provider crash) is
    # neither NOT_CALLED nor an infinite retry: per codesift-setup.md's transport
    # protocol, record `<tool>: call-failed(<error>) (<substitution-map fallback>:
    # <result>)` = PASS, and list the failure under SKIPPED STEPS.
    review_diff: [<N> findings across 9 checks | absent-in-build (audit_scan: <findings>) | NOT_CALLED — VIOLATES_TRIGGER]
    changed_symbols: [<N> symbols | absent-in-build (impact_analysis+get_file_outline: <result>) | NOT_CALLED — VIOLATES_TRIGGER]
    diff_outline: [<N> files outlined | absent-in-build (get_file_outline: <result>) | NOT_CALLED — VIOLATES_TRIGGER]
    impact_analysis: [<N> affected_tests / <N> blast | NOT_CALLED — VIOLATES_TRIGGER]
    scan_secrets: [<N> hits | absent-in-build (grep secret-scan: <count>) | NOT_CALLED — VIOLATES_TRIGGER]
    search_patterns: [<N> CQ8/CAP hits | NOT_CALLED — VIOLATES_TRIGGER]
    find_references: [<N> chains | not_required (no symbol cited) | NOT_CALLED — VIOLATES_TRIGGER]
    stack_specific (nest_audit/framework_audit/python_audit/etc.): [<result> | not_required | NOT_CALLED — VIOLATES_TRIGGER]
    framework_audit (Next.js ONLY): [<result> | not_nextjs | NOT_CALLED — VIOLATES_TRIGGER]
      # For a Next.js diff, framework_audit is the single-call-first requirement.
      # nextjs_route_map is a SUBSET (routes only) and does NOT satisfy it —
      # framework_audit also covers client-boundary, data-flow, and server-actions.
  audit_tree: [readonly(<sha7>) | live(<why the read-only worktree could not be created>)]
    # The auditors' root. `live` is an honest degraded value — the findings then race the fix loop
    # and the Working-Tree Staleness Check carries the weight alone. Claiming `readonly` without
    # having created the worktree is the same class as claiming a dispatch that never happened.
  tier2_subagents:   # TIER 2-3 only; for TIER 0-1 print "not_required (tier<2)"
    # Single-agent environments (Codex/Cursor/Antigravity — env-compat.md forbids
    # pipeline-stage thread dispatch there): SEQUENTIAL_CHECKPOINT(<role>, <evidence>)
    # is a PASS value for every role below and satisfies the Completion Gate
    # "DISPATCHED as sub-agents" item — the env-mandated checkpoint pass IS the
    # required result, not VIOLATES_TIER2. Adversarial coverage still required as usual.
    behavior_auditor: [DISPATCHED(<agent-return-marker>) | INLINE-SINGLE-AGENT-LOCK(<marker>) | not_required (no new prod files / tier<2) | NO_RETURN(<elapsed>) — VIOLATES_TIER2 | NOT_DISPATCHED — VIOLATES_TIER2]
    structure_auditor: [DISPATCHED(<agent-return-marker>) | INLINE-SINGLE-AGENT-LOCK(<marker>) | not_required (tier<3) | NO_RETURN(<elapsed>) — VIOLATES_TIER3 | NOT_DISPATCHED — VIOLATES_TIER3]
    cq_auditor: [DISPATCHED(<agent-return-marker>) | INLINE-SINGLE-AGENT-LOCK(<marker>) | NO_RETURN(<elapsed>) — VIOLATES_TIER2 | NOT_DISPATCHED — VIOLATES_TIER2]
    confidence_rescorer: [DISPATCHED(<agent-return-marker>) | INLINE-SINGLE-AGENT-LOCK(<marker>) | NO_RETURN(<elapsed>) — VIOLATES_TIER2 | NOT_DISPATCHED — VIOLATES_TIER2]
    # `DISPATCHED(<marker>)` requires a RETURNED result you actually used. A dispatch that
    # never came back is `NO_RETURN(<elapsed>)` and counts EXACTLY as NOT_DISPATCHED for every
    # rule below — it contributed no findings, so it bought no coverage, and the reason it is
    # missing does not change what the verdict may claim. This state existed in reality before
    # it existed in this table: on 2026-08-11 a TIER 3 SELF-REVIEW shipped a release with the
    # behavior auditor still running (it returned 12h later, with a real finding). Nothing
    # flagged it — the gate only recognised "not dispatched", so a dispatched-and-silent agent
    # fell through and the verdict read as full coverage. Before writing ANY value here, verify
    # each agent actually returned; "I sent three" is not "three reported".
    # DEGRADED is allowed ONLY when self_review_flag=no AND you print a one-line
    # [DEGRADED: <agent> skipped because <concrete reason>] — a DELIBERATE,
    # logged decision, never a silent omission. On SELF-REVIEW the sub-agents are
    # NON-NEGOTIABLE (author=reviewer bias is exactly what they mitigate): a
    # skipped sub-agent on self-review is NOT_DISPATCHED — VIOLATES_TIER2, no
    # degraded path. "adversarial covers it" is FALSE — sub-agents read the plan
    # + spec independently; adversarial sees only the diff.
  adversarial:
    passes_run: [<N> | 0 — VIOLATES_MANDATE]
    providers_used: [<provider1,provider2,...> | none]
    skip_reason: [n/a | single_provider_only | timeout | BLOCKED_CONTEXT_BUDGET | <other> — VIOLATES_MANDATE]
    # rate_limit is NOT a skip reason — per stall-recovery.md ("Rate-limit
    # is a RETRY condition, NEVER a quality lever"), a rate-limited adversarial pass
    # is RE-RUN across watchdog resumes until it completes, never recorded as a skip
    # or a degraded verdict. The only genuine no-retry unavailability reasons are
    # single_provider_only (only one model exists) and BLOCKED_CONTEXT_BUDGET (window
    # full) — those keep the degraded-coverage handling below; rate_limit does not.
    coverage_source: [fresh-this-run | same-session-same-commit(<artifact-paths>) | NONE — degraded]
    self_review_flag: [no | yes — used --multi | yes — DID_NOT_USE_--multi — VIOLATES_1.1]
  backlog_deferral:
    recommended_applied: <count of localized RECOMMENDED fixed in Phase 4>
    recommended_deferred: [<count> all tagged NIT/structural-refactor(multi-file) | <B-id> NO_VALID_DEFER_REASON — LOCALIZED-DEFER-DRIFT]
  postamble:
    retros_log_appended: [yes(bytes_added=N) | NOT_APPENDED — VIOLATES_REQUIRED_POSTAMBLE]
    retros_md_appended: [yes(entry_count=N) | NOT_APPENDED — VIOLATES_REQUIRED_POSTAMBLE]
    verify_audit_pass: [yes(<verified>/<total> findings) | NOT_RUN | REJECTED]
  gate_status: [PASS | FAIL — <which gates missing>]
```

If `gate_status = FAIL`, override the VERDICT to `INCOMPLETE` regardless of finding count, append `[VALIDITY GATE FAIL]` to the Run line NOTES column, and add a backlog item `B-review-incomplete-<date>`.

**Adversarial-skip violation handling (NEW — closes the 2026-05-28 escape-hatch loophole):** If `adversarial.skip_reason` is set to anything OUTSIDE the whitelist `{n/a, single_provider_only, timeout, BLOCKED_CONTEXT_BUDGET}` — including but not limited to "context budget", "already mechanically detected", "self-review low value", "small diff", "documented honestly" — then:
1. Set `gate_status = FAIL — adversarial skip outside whitelist (<reason>)`.
2. Override VERDICT to `INCOMPLETE` regardless of finding count.
3. Append `[ESCAPE-HATCH-VIOLATION:adversarial:<reason>]` to the Run line NOTES column.
4. Add backlog item `B-review-escape-hatch-<date>` with the verbatim quote of the skip rationale (so the pattern is auditable).

Same handling if `self_review_flag = yes — DID_NOT_USE_--multi` (section 1.1 mandates `--multi` on self-review).

**Rate-limit is NOT a degraded path — it is a RETRY (per stall-recovery.md).** If a mandatory gate (fresh adversarial `--multi`, or any TIER-2 sub-agent fan-out) cannot complete this turn because of a rate-limit / API-error, do NOT record a skip, do NOT downgrade to CONDITIONAL, do NOT cite coverage. **End the turn; the watchdog resumes; RE-RUN the exact gate.** Repeat until it actually runs. A rate-limited review is *still-running*, not *done-degraded*. The verdict is computed only once every mandatory gate has truly run (or is proven by a same-commit artifact, below). There is no `rate_limit` skip-reason and no rate-limit CONDITIONAL — that path is removed precisely because it became the universal excuse.

**Genuine capability-limit handling (NOT rate-limit — these do not clear by retrying).** The only honest non-retry unavailability reasons are `single_provider_only` (only one model is configured, so cross-model `--multi` truly cannot run) and `BLOCKED_CONTEXT_BUDGET` (the context window is full). For these, check `coverage_source`:
- `same-session-same-commit(<artifacts>)` — the dimension WAS covered by a real pass on the EXACT commits under review (e.g. adversarial artifacts in `zuvo/context/adversarial-task-*.txt` returning 0 open MUST-FIX). Verify the artifacts exist on disk AND reference these commit SHAs. If so, that dimension is legitimately covered → it does NOT degrade the verdict. (The ONE honest reuse — real coverage on the same code, not a lighter substitute.)
- `NONE` — no fresh run and no same-commit artifact, and the limit genuinely cannot be retried away. Then: verdict downgrades to **`CONDITIONAL`**; print `[DEGRADED-COVERAGE: <gate> not run — <single_provider_only|BLOCKED_CONTEXT_BUDGET>; re-validate before merge]` + append `[DEGRADED-COVERAGE:<gate>:<reason>]` to the Run line NOTES; record a re-validation obligation (`B-review-revalidate-<date>` + the NEXT STEPS "run `/zuvo:review <range>` to clear the CONDITIONAL"); `gate_status` stays `PASS` with `degraded=<gate>` noted.

The point: a clean `APPROVE` requires every mandatory gate to be either freshly run, proven by a same-commit artifact, or (only for a true capability limit) honestly degraded to CONDITIONAL. `timeout` (exit 124, ALL providers timed out) IS a legitimate recorded skip — it is a provider-side dead end, not a retryable rate-limit. Rate-limit is none of these — it is retried until the gate runs. `n/a` (no production logic to review) is the only no-coverage-needed path.

**TIER 2 sub-agent skip handling (NEW — closes the silent-degradation / context-fatigue drift gap):** This is the dominant real-world failure: on a long session the lead does CQ/behavior/confidence scoring *inline as "lead"* instead of dispatching the sub-agents, then rationalizes it after the fact ("adversarial covers it", "scoped check instead"). That is **drift, not a decision**. If any `tier2_subagents.*` reads `NOT_DISPATCHED — VIOLATES_TIER2` **or `NO_RETURN(<elapsed>)`**:
1. Set `gate_status = FAIL — tier2 sub-agent(s) not dispatched (<which>)`.
2. Override VERDICT to `INCOMPLETE` (the inline "lead" scoring does NOT substitute — sub-agents read plan+spec independently and are the second pair of eyes; on self-review they are the ONLY independent eyes).
3. Append `[TIER2-SUBAGENT-SKIP:<which>]` to the Run line NOTES.
4. Add backlog item `B-review-tier2-skip-<date>` with the verbatim rationalization quote.
A DEGRADED line (`[DEGRADED: <agent> skipped because <reason>]`) is acceptable ONLY for non-self-review AND only as a printed, deliberate choice — never the default. On self-review there is NO degraded path.

**`NO_RETURN` is the same failure wearing an innocent face, and it is the one that actually
shipped.** The drift above is a lead who *chose* not to dispatch; `NO_RETURN` is a lead who
dispatched correctly, never noticed the agent did not come back, and wrote the verdict from
whoever happened to reply. Same outcome — a tier claiming coverage it does not have — but no
rationalization to catch it by, because nothing was rationalized. Use `NO_RETURN(<elapsed>)`
and route it through steps 1-4 above (note `[TIER2-SUBAGENT-NO-RETURN:<which>:<elapsed>]`
instead, and backlog the elapsed time rather than a quote). Two practical rules:

- **Before writing the Validity Gate, count RETURNS against dispatches.** If you dispatched 3
  and can name findings from 2, the third is `NO_RETURN` — not "presumably fine".
- **Do not wait indefinitely for it.** Ask the outstanding agent for whatever it has, then
  finalize with the honest value. A 12-hour agent that returns one real finding after the
  release is worth reading; it is not worth blocking on, and it is never worth assuming.
  (Measured 2026-08-11: exactly that, and the release went out on the overstated version.)

**Harness single-agent lock is NOT a skip — run the roles INLINE.** The rule above targets *drift*:
a lead that COULD dispatch and chose not to, then rationalized it. It does not target a harness
that forbids dispatch outright (Cursor, Antigravity — see `env-compat.md`; Codex is NOT one of them,
it runs review roles inline because they are same-model, and dispatches mechanical workers). Treating those as
the same thing made TIER 2+ unpassable on that harness: the skill mandated the one action the
environment prohibits, so every run was `INCOMPLETE` no matter how well it was done. Three retros
this week reported exactly that conflict.

Where dispatch is impossible, run each role's prompt INLINE as a distinct pass — read
`agents/<role>.md`, execute it against the diff WITHOUT consulting your own earlier scoring, and
record it as such:

```
behavior_auditor: INLINE-SINGLE-AGENT-LOCK(<marker>)
cq_auditor:       INLINE-SINGLE-AGENT-LOCK(<marker>)
```

`INLINE-SINGLE-AGENT-LOCK` satisfies the gate but caps the verdict at `degraded:same-model` — it is
the same model doing both passes, so it is weaker than dispatch and must never be reported as
`strict`. Cross-model independence still comes from the adversarial rotation, which is unaffected
by the lock. **This carve-out applies ONLY when the harness genuinely forbids dispatch.** If
dispatch is available and you scored inline anyway, that is the drift above and stays
`NOT_DISPATCHED — VIOLATES_TIER2`.

**Localized-deferral drift handling (NEW — closes the "RECOMMENDED → backlog" reflex that grows the backlog with things that should have been fixed in-loop):** The recurring failure is the lead reflexively routing a localized, single-file RECOMMENDED fix (add `try/catch`, add a guard, add a missing affordance) to backlog *because* it is "only RECOMMENDED" — conflating merge-severity with fix-scope. The backlog then accretes one-line fixes that the AUTO-FIX default already mandates applying. If any backlogged RECOMMENDED item carries a `defer-reason` OUTSIDE the whitelist `{NIT, structural-refactor (multi-file)}` — or carries none — then:
1. Set `gate_status = FAIL — localized RECOMMENDED deferred to backlog (<B-id>)`.
2. Override VERDICT to `INCOMPLETE` and route the mis-deferred item(s) into Phase 4 NOW (do not emit REVIEW COMPLETE with them still in backlog).
3. Append `[LOCALIZED-DEFER-DRIFT:<B-id>]` to the Run line NOTES.
A multi-file structural refactor stays in backlog with its recipe — that is correct, not drift. The test is fix-scope (one file/symbol → fix; cross-cutting restructure → backlog), never severity tier.

Print this Validity Gate **AFTER** the retro append and `~/.zuvo/append-runlog` call (so postamble fields can be filled with `yes(verified)`).

### NEXT STEPS Block

```
REVIEW COMPLETE -- <VERDICT>, <N> issues found.
DEPLOYMENT RISK: <RISK LEVEL> -- <deploy strategy>
Run: <ISO-8601-Z>	review	<project>	<CQ>	<Q>	<VERDICT>	<TASKS>	<DURATION>	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
```

**Default (FIX-AUTO) — do NOT stop here; auto-proceed to Phase 4.** Unless `--report-only` (or an explicit `fix`/`blocking`/`auto-fix`/`tag`/`status`) was passed, the review does not present a menu and wait — it announces what it will apply and goes straight into the fix:

```
AUTO-FIX: applying <M> MUST-FIX + <R> RECOMMENDED (localized/high-confidence) → Phase 4.
DEFERRED to backlog: <K> NIT + <S> structural-refactor RECOMMENDED.
  <for each deferred item> B-<id> — defer-reason: [NIT | structural-refactor (multi-file)]
```

**Backlog-deferral whitelist (HARD — closes the silent-deferral drift gap).** The DEFAULT for a RECOMMENDED finding is **fix it now in Phase 4**, not backlog. A RECOMMENDED finding may be deferred to backlog ONLY if it matches one of exactly two categories, and you MUST print its `defer-reason` tag in the AUTO-FIX block above:
- **NIT** — style/readability, zero functional impact (already its own tier; would only apply under explicit `fix`/FIX-ALL).
- **structural-refactor (multi-file)** — extract a module, split a god-file, invert a dependency, restructure a layer. This is `zuvo:refactor` territory and gets a resolution recipe per Phase 2.

Everything else is **localized and gets fixed in-loop, full stop.** A single-file, single-symbol reliability/correctness/affordance fix — add a missing `try/catch` around a transaction, add a null guard, tighten a WHERE clause, add a missing scope indicator on a button, reject invalid input — is **localized + high-confidence by construction** and is NEVER deferrable. "It's only RECOMMENDED so I'll backlog it" is the exact drift this gate forbids: severity tier (MUST-FIX vs RECOMMENDED) decides *merge-blocking*, it does NOT decide *fix-now vs defer*. The defer decision is made on the **scope of the fix** (localized → fix; multi-file refactor → backlog), not on severity. If you cannot name the deferred item's category as `NIT` or `structural-refactor (multi-file)`, it is NOT deferrable — route it to Phase 4.

Then continue to Phase 4 immediately (no user turn). If there are ZERO MUST-FIX and ZERO applicable RECOMMENDED, print `AUTO-FIX: nothing to apply (only NIT/structural — backlogged)` and finish. Only when `--report-only` was passed do you instead print the menu and stop:

```
NEXT STEPS: "fix" (all) | "blocking" (MUST-FIX only) | "auto-fix" (zuvo:build) | "skip"
```

Append the Run line via the retro-gated wrapper (NOT direct `>> runs.log`):

```bash
printf '%b\n' "$RUN_LINE" | ~/.zuvo/append-runlog
```

The wrapper:
- Verifies the matching `RETRO:` entry in `retros.log` (skill+project). Missing → exit 2.
- Runs `~/.zuvo/verify-audit` on the report at `memory/reviews/<date>-<scope>.md`. Findings without `file:line` citations → exit 2.
- On both pass: appends to `runs.log` and prints confirmation.

If the wrapper exits non-zero: do NOT manually append to runs.log. Fix the cause and re-run.

---

## Phase 4: Execute (FIX-AUTO / FIX-ALL / FIX-BLOCKING / AUTO-FIX)

Read and follow the fix loop protocol from `../../shared/includes/fix-loop.md`.

```
Input:
  FINDINGS: [R-N findings to fix, per mode]
  SCOPE_FENCE: [allowed files from triage]
  MODE: FIX-AUTO | FIX-ALL | FIX-BLOCKING | AUTO-FIX
```

- **FIX-AUTO (default):** apply MUST-FIX + RECOMMENDED that are localized + high-confidence (confidence ≥ ~60 from Phase 2). Do NOT apply NIT or structural-refactor RECOMMENDED — those go to backlog (the structural-refactor defer rule in Phase 2 already routes them there). This is the "I always click fix anyway" default — minus the low-value churn and the multi-file refactors that belong to `zuvo:refactor`.
- **FIX-ALL:** apply MUST-FIX + RECOMMENDED + NIT (explicit `fix` — you want everything incl. nits).
- **FIX-BLOCKING:** apply MUST-FIX only.
- **AUTO-FIX:** dispatch `zuvo:build` with MUST-FIX findings as context (closed-loop, max 1 cycle).

### Post-fix gate (MANDATORY — auto-applied fixes can over-correct)

Applying fixes without re-checking is how a "fix" silently becomes a regression (2026-05-30: an auto-applied resize fix removed the width floor → the dock could collapse to 0px and `aria-valuemin > valuemax`; caught only by the next adversarial pass). After applying ANY fixes, before declaring done:

1. **Verify** — run the project's test/typecheck/build. A fix that leaves the suite red is reverted, not shipped.
   - **Pre-existing failure in an UNTOUCHED workspace is not your regression** (and reverting a good fix over it is the actual harm). If the full suite fails only outside the reviewed file set: re-run that workspace once to confirm it reproduces, then compare the failing files against the reviewed diff. A **reproducible** failure in files this review never touched does NOT invalidate a green targeted suite + typecheck — but the verdict MUST disclose it: `verification debt: <workspace> <N> failing (pre-existing, out-of-scope)`, with the exact files/counts. Silence here is the escape hatch: an undisclosed "the suite was already broken" is indistinguishable from a fix that broke it. If the failure touches ANY reviewed file, it is yours — revert or fix, no debt option.
2. **Adversarial re-validation** — run one cross-provider adversarial pass on the FIX diff (`~/.zuvo/adversarial-review --mode code` on the applied changes). It must **converge** (no new CRITICAL): a new CRITICAL introduced by a fix is itself fixed (cap 3 passes per `adversarial-loop.md`), residual non-CRITICAL → backlog. Do NOT print the FIX-COMPLETE block while a fix-introduced CRITICAL is open.
3. **Commit** only after 1+2 pass. Record applied vs deferred (backlog IDs) in the FIX summary.

This gate is what makes auto-fix safe to default: the user never has to eyeball each change, because the verify + adversarial pass catch an over-correction the way a human glance would.

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
