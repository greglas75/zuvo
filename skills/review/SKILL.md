---
name: review
description: >
  Structured code review with parallel audit agents, confidence-scored triage,
  and optional auto-fix. Examines uncommitted changes, staged diffs, commit
  ranges, or specific paths. Produces a tiered report (MUST-FIX / RECOMMENDED /
  NIT) backed by evidence, then optionally applies fixes with verification.
---

# zuvo:review

Triage the diff, audit it through independent lenses, confidence-score every finding, and deliver a verdict. No separate "go" step required -- the review runs end to end.

## Mandatory File Loading

Read these files before doing anything else:

1. `../../shared/includes/codesift-setup.md` -- CodeSift discovery and tool selection
2. `../../shared/includes/env-compat.md` -- Agent dispatch and environment adaptation
3. `../../shared/includes/quality-gates.md` -- CQ1-CQ28 and Q1-Q19 condensed reference
4. `../../rules/cq-patterns.md` -- NEVER/ALWAYS code pairs for pattern recognition
5. `../../shared/includes/run-logger.md` -- Log-in-Output run logging

Print the checklist:

```
CORE FILES LOADED:
  1. codesift-setup.md   -- [READ | MISSING -> STOP]
  2. env-compat.md       -- [READ | MISSING -> STOP]
  3. quality-gates.md    -- [READ | MISSING -> STOP]
  4. cq-patterns.md      -- [READ | MISSING -> STOP]
  5. run-logger.md       -- [READ | MISSING -> STOP]
```

If any file is missing, STOP. Do not proceed from memory.

### Conditional Files (loaded after triage determines tier)

| File | Load when | Skip when |
|------|-----------|-----------|
| `../../rules/cq-checklist.md` | TIER 1+ (full CQ detail needed) | TIER 0 |
| `../../rules/testing.md` | Diff contains test files (`*.test.*`, `*.spec.*`) | No test files in diff |
| `../../rules/security.md` | Triage flags security signals, or TIER 3 | TIER 0-2 with no security signals |

Print loaded conditional files after triage completes:

```
FILES LOADED: codesift-setup.md, env-compat.md, quality-gates.md, cq-patterns.md [Phase 1]
              + cq-checklist.md, testing.md [Phase 2 -- TIER 2]
              (skipped: security.md -- no security signals)
```

---

## Argument Parsing

`$ARGUMENTS` controls both WHAT gets reviewed and WHAT to do with the findings.

### Scope (what code to examine)

| Input | Meaning | Git command |
|-------|---------|-------------|
| _(empty)_ | All uncommitted changes | `git diff --stat HEAD` |
| `staged` | Only staged changes | `git diff --stat --cached` |
| `new` | Commits since last review | Backlog resolution (see below) |
| `HEAD~1` | Last commit | `git diff --stat HEAD~1..HEAD` |
| `HEAD~N` | Last N commits | `git diff --stat HEAD~N..HEAD` |
| `abc123..def456` | Specific commit range | `git diff --stat abc123..def456` |
| `src/services/` | Directory (uncommitted) | `git diff --stat HEAD -- src/services/` |
| `auth.service.ts` | File pattern (uncommitted) | `git diff --stat HEAD -- '**/auth.service.ts'` |

Tokens combine: `HEAD~3 src/api/` reviews the last 3 commits scoped to `src/api/`.

**`new` resolution order:**
1. If `memory/backlog.md` has unchecked entries, use the oldest entry's parent hash as the start point.
2. Fallback: `git merge-base HEAD main` (diverge point from main branch).
3. Final fallback: `HEAD~5` with a warning.

### Mode (what to do after the audit)

| Token | Mode | Behavior |
|-------|------|----------|
| _(none)_ | REPORT | Audit and present findings. Wait for user decision. |
| `fix` | FIX-ALL | Apply every reported fix automatically, then verify. |
| `blocking` | FIX-BLOCKING | Apply only MUST-FIX findings, then verify. |
| `tag` | UTILITY | No audit. Remove reviewed commits from backlog. |
| `mark-reviewed` | UTILITY | No audit. Create `reviewed/` git tags on commits. |
| `status` | UTILITY | No audit. Show unreviewed commit count and list. |
| `batch <file>` | BATCH | Process a queue of commits: review, fix, tag per entry. |
| `--thorough` | FLAG | Activate multi-pass review with majority voting. |

Examples: `zuvo:review`, `zuvo:review fix`, `zuvo:review HEAD~3 blocking`, `zuvo:review new src/api/ fix`, `zuvo:review --thorough`, `zuvo:review batch commits.md`

---

## Tier System

A quick `git diff --stat` determines how deep the review goes. Filter out noise files before counting (locks, dist, snapshots, generated code, binary assets).

If ALL changed files are noise, print "Only noise files changed (locks, snapshots, dist). Nothing to review." and STOP.

### Tier Selection

| Condition | Tier |
|-----------|------|
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
| CQ1-CQ28 evaluation | Skip | Yes | Yes | Yes |
| Q1-Q19 on test files | Skip | If present | Yes | Yes |
| Audit agents | None | None | Behavior (if new files) | All 3 |
| Adversarial review | Skip | If risk signal | Yes (single) | Yes (multi) |
| Confidence re-scoring | Inline | Inline | Agent | Agent |
| Hotspot detection | Skip | Skip | Yes | Yes |
| Multi-pass (--thorough) | Refused | Optional | Optional | Automatic if >500L |
| Security deep dive | Skip | Skip | Skip | Yes |

### Risk Signals

Check the diff for these markers. Each one counts toward tier escalation:

- DB migration or schema changes
- Security or authentication modifications
- API contract changes (routes, request/response shapes)
- Payment or money flow logic
- More than 500 lines changed
- New production files added (not test files)
- AI-generated code patterns (hallucinated imports, generic names, overly verbose)

Print the triage result:

```
TRIAGE RESULT
------------------------------------
Files changed:    N
Lines changed:    +X/-Y
Change intent:    [BUGFIX / REFACTOR / FEATURE / INFRA]

Risk signals:
  [x] API contract changes
  [ ] DB/migration changes
  ...

Tier:       TIER 2 (STANDARD)
Mode 2 OK:  YES
------------------------------------
```

### FIX-ALL Blockers

FIX-ALL mode applies to all tiers. For high-risk changes (DB migrations, security/auth, API contracts, payment/money), apply fixes one at a time and run tests after each fix. If a fix breaks tests, revert it and report as `[!]`.

---

## Phase 0: Pre-Audit Setup

### CodeSift Setup

Follow `codesift-setup.md`:

1. Check whether CodeSift tools are available in the current environment
2. `list_repos()` once to cache the repo identifier
3. If not indexed: `index_folder(path=<project_root>)`

### Hotspot Detection (TIER 2+)

**With CodeSift:** `analyze_hotspots(repo, since_days=90)` -- returns ranked risk scores. If any file in the current diff appears in the top 10 hotspots, add a risk signal and note it for extra scrutiny during the audit.

**Without CodeSift:** Fall back to a git log frequency analysis:

```bash
git log --format=format: --name-only --since="3 months ago" -- '*.ts' '*.tsx' '*.py' '*.go' '*.rs' '*.java' | \
  sort | uniq -c | sort -rn | head -20
```

Cross-reference results against files in the current diff.

### Blast Radius (TIER 2+)

**With CodeSift:** `impact_analysis(repo, since=<REVIEWED_FROM>, depth=2, include_source=true)` -- detects changed symbols, traces callers two levels deep, and scores each change. This single call replaces the need for a separate blast radius agent.

**Without CodeSift:** `grep -r 'import.*[changed-module]'` to find direct importers of changed files.

### Dead Code Scan (optional, JS/TS only)

If the diff adds or removes exports and `knip` is available: `npx knip --reporter json 2>/dev/null`. Cross-reference flagged exports against the diff. Dead exports being added become CQ13 findings with high confidence.

If knip is not available, skip silently. This is an enhancement, not a gate.

---

## Phase 1: Audit

Print a step header before each audit stage:

```
STEP: Triage [DONE]
STEP: Scope Fence
STEP: Audit (Behavior + Structure + CQ agents)
STEP: CQ1-CQ28
STEP: Q1-Q19 per test file
STEP: Adversarial Review (TIER 2+ only)
STEP: Confidence Gate
STEP: Report
```

### Self-Review Disclosure

Before starting the audit, check whether you wrote any of the code being reviewed in this conversation session. If yes, add a `SELF-REVIEW` marker to the report header. Self-review has inherent bias -- recommend external review in the final verdict for any file where you changed CQ gate scores during implementation.

### Review Header

```
===============================================================
CODE REVIEW
===============================================================
REVIEWING: [1-2 sentence summary]
FILES: [N files, +X/-Y lines]
TIER: [0/1/2/3] -- [NANO/LIGHT/STANDARD/DEEP]
AUDIT: [SOLO / TEAM (N auditors)]
CHANGE INTENT: [BUGFIX / REFACTOR / FEATURE / INFRA]
===============================================================
```

### Agent Dispatch (tier-gated)

Refer to `env-compat.md` for the correct dispatch pattern per environment.

**TIER 0-1:** No agents. Lead performs all analysis inline.

**TIER 2:** Lead performs the audit sequentially. If the diff introduces new production files, dispatch the Behavior Auditor as a single background agent to scrutinize those files for logic correctness.

**TIER 3:** Dispatch all three audit agents in parallel.

#### Agent 1: Behavior Auditor

**Execution profile:** default analysis tier for TIER 2 new files or normal TIER 3 runs. Escalate to the deep tier when TIER 3 also includes 15+ files or security/money risk signals.

**Type:** Explore (read-only)

**Focus:** Logic correctness, error handling paths, edge cases, async safety, race conditions, state management, feature completeness (if FEATURE intent). Applies CQ3-CQ10 checks on each changed production file. Reports findings as `BEHAV-N` items.

**Input:**
- Production code diff only (exclude test files, config, locks)
- Detected tech stack
- Change intent from triage
- Pre-existing data (blame results for distinguishing new vs old code)
- Tier and conditional section flags

**Scope rules by tier and intent:**
- TIER 2 REFACTOR: Verify behavioral equivalence (before matches after). Run only affected tests.
- TIER 2 FEATURE: Full logic audit including feature completeness (loading/error/empty states).
- TIER 3: Include security analysis and i18n checks.

#### Agent 2: Structure Auditor

**Execution profile:** default analysis tier

**Type:** Explore (read-only)

**Focus:** Naming conventions, import correctness, circular dependencies, file and function size limits, SRP violations, coupling, barrel exports. Reports findings as `STRUCT-N` items.

**Input:**
- Production code diff only
- Detected tech stack
- Change intent and tier
- Blast radius data (from Phase 0)

**Scope rules by tier and intent:**
- TIER 2 REFACTOR: Focus on import correctness and file limits. Skip deep performance analysis.
- TIER 2 FEATURE: Full structural review.
- TIER 3: Include rollback plan assessment and documentation checks.

#### Agent 3: CQ Auditor

**Execution profile:** default analysis tier

**Type:** Explore (read-only)

**Focus:** Independent CQ1-CQ28 evaluation. Does NOT trust the lead's CQ scores -- performs its own assessment from scratch. Catches N/A abuse (>60% N/A triggers a flag and demands justification for each). Reports findings with file:line evidence.

**Input:**
- Full source of each changed production file (not just the diff -- the auditor needs complete context)
- CQ checklist reference
- CQ patterns reference
- Detected tech stack

**Output format:**
```
CQ AUDIT: [filename] ([N]L)
CQ1=1 CQ2=0 CQ3=N/A ... CQ22=N/A
Score: X/Y applicable -> [PASS / CONDITIONAL PASS / FAIL]
Critical gates: CQ3=1(validated:42) CQ5=0(PII in log:54)
Evidence: [file:function:line for each gate scored 1]
N/A justification: [for each N/A, 5 words or less]
```

#### Result Merging

After all agents complete:

1. Collect BEHAV-N, STRUCT-N, and CQ findings
2. Deduplicate -- if two agents flagged the same issue, keep the one with more specific evidence
3. Renumber sequentially as R-1, R-2, R-3...
4. Proceed to the Confidence Gate

### Inline Audit (TIER 0-1)

When no agents are dispatched, the lead performs all analysis directly:

- **Blast radius:** Use the `impact_analysis` result from Phase 0 if CodeSift is available. Otherwise run a single `grep` to find importers.
- **Pre-existing check:** `git blame -L <start>,<end> <file>` on changed hunks to distinguish new code from old.
- **Confidence scoring:** With a small number of issues (typically 2-4 for TIER 0-1), the lead assigns confidence scores directly using the scoring rules.

### CQ Self-Evaluation (TIER 1+)

For each changed production file, run CQ1-CQ28. Print ALL 28 gates -- not just failures. The user needs to verify that gates scored as 1 are genuinely satisfied, not rubber-stamped.

```
CQ EVAL: order.service.ts (185L)
CQ1=1 CQ2=1 CQ3=1 CQ4=0 CQ5=1 CQ6=1 CQ7=1 CQ8=0 CQ9=N/A CQ10=1
CQ11=1 CQ12=0 CQ13=1 CQ14=1 CQ15=1 CQ16=N/A CQ17=1 CQ18=N/A CQ19=1
CQ20=N/A CQ21=1 CQ22=N/A CQ23=N/A CQ24=N/A CQ25=1 CQ26=N/A CQ27=N/A CQ28=N/A
Score: 15/17 applicable -> CONDITIONAL PASS
Critical gates: CQ4=0(no orgId filter:87) CQ8=0(empty catch:102)
```

CQ critical gate failures (CQ3, CQ4, CQ5, CQ6, CQ8, CQ14) always produce MUST-FIX findings.

### Q1-Q19 Evaluation (when test files in diff)

For each test file in the diff, run Q1-Q19 and print:

```
Q EVAL: order.service.spec.ts
Q1=1 Q2=1 Q3=0 Q4=1 Q5=1 Q6=1 Q7=1 Q8=0 Q9=1 Q10=1 Q11=1 Q12=0 Q13=1 Q14=1 Q15=1 Q16=1 Q17=1
Score: 14/17 -> PASS | Critical: Q7=1 Q11=1 Q13=1 Q15=1 Q17=1 -> PASS
```

### Pre-Existing Issue Reporting

During the audit, if you notice issues that were NOT introduced by the current diff:

- **Always report:** Critical CQ gate violations (CQ3/4/5/6/8/14), resource issues (unbounded memory, missing stream cleanup).
- **Briefly note:** CQ2 (missing return types), CQ10 (unsafe casts), CQ22 (missing cleanup).
- **Skip:** Naming conventions, magic numbers, dead code -- these are code-audit territory.

Pre-existing issues are capped at RECOMMENDED severity (they were not introduced by this change) and noted as pre-existing in the report.

---

## Phase 2: Confidence Gate

After the audit produces a list of candidate findings, score each one before including it in the report.

### Scoring (TIER 0-1: inline, TIER 2+: agent)

**TIER 0-1:** The lead scores each finding directly. For each issue, state `Confidence: [X]/100 -- [reason]`.

**TIER 2+:** Dispatch a Confidence Re-Scorer agent:

**Execution profile:** lightweight analysis tier

**Type:** Explore (read-only)

**Input:** The full list of candidate issues (ID, severity, file, code quote, problem description), the change intent, pre-existing data, and path to the backlog file.

**Task:** For each finding, assign a confidence score 0-100 based on: matches a project rule (+), concrete reproduction scenario (+), user-visible impact (+), money/auth/data involved (+), theoretical only (-), covered by tests (-), rarely-executed code (-), intentional author choice (-).

### Disposition

| Confidence | Action |
|-----------|--------|
| 0-25 | DISCARD (hallucination or false positive) |
| 26-50 | DROP from report, persist to backlog for tracking |
| 51-100 | KEEP in report |

After filtering, adjust severity if the re-scorer disagrees with the original assessment. Write dropped issues (26-50) to `memory/backlog.md` BEFORE showing the report.

---

## Phase 3: Report

### Severity Tiers

Every finding uses one of three tiers:

| Tier | Meaning | Merge impact |
|------|---------|-------------|
| **MUST-FIX** | Confirmed bug, security issue, data loss, critical CQ gate failure | Blocks merge |
| **RECOMMENDED** | Risk of maintenance problem or degraded reliability | Merge discouraged |
| **NIT** | Style, readability, no functional impact | Merge OK as-is |

**Classification rules:**
- "Would this cause a production bug?" -> MUST-FIX
- "Would this cause a maintenance problem in 3 months?" -> RECOMMENDED
- "Is this style/preference?" -> NIT
- CQ critical gate failures -> always MUST-FIX
- Security findings -> always MUST-FIX (unless purely informational)
- Pre-existing issues -> cap at RECOMMENDED
- When in doubt, downgrade

### Report Format

The report contains these sections in order:

1. **META** -- date, intent, tier, audit mode (SOLO/TEAM), agents used, confidence method
2. **SCOPE FENCE** -- files that were examined, files that were excluded
3. **VERDICT** -- PASS / WARN / BLOCKED with score
4. **SEVERITY SUMMARY** -- `MUST-FIX: N | RECOMMENDED: N | NIT: N` (MUST-FIX > 0 means verdict is BLOCKED)
5. **CHANGE SUMMARY** -- what the diff does in plain language
6. **SKIPPED STEPS** -- which audit steps were skipped and why (tier-based or conditional)
7. **VERIFICATION PASSED** -- what checks passed cleanly
8. **BACKLOG ITEMS IN SCOPE** -- any open backlog items in files touched by this diff
9. **DROPPED ISSUES** -- brief list of findings filtered by the confidence gate
10. **FINDINGS** -- grouped by tier: MUST-FIX first, then RECOMMENDED, then NIT

Each finding:
```
R-1 [MUST-FIX] Missing orgId filter in query -- returns all orgs' data
  File: src/order/order.service.ts:87
  Confidence: 92/100
  Evidence: findMany at :87 has no orgId in WHERE clause, guard at :12 only checks role
  Fix: Add `organizationId: orgId` to the WHERE clause
```

11. **QUESTIONS FOR AUTHOR** -- genuine uncertainties where the author's input changes severity
12. **QUALITY WINS** -- things done well (encourages good patterns)
13. **TEST ANALYSIS** -- test validity, missing coverage, existing test status

### Backlog Persistence (after report)

Persist unfixed issues to `memory/backlog.md`:

- Dropped issues (confidence 26-50): backlog with confidence score and "(dropped from report)" note
- Pre-existing issues: backlog
- REPORT mode: all reported issues go to backlog (not yet fixed)
- Deduplicate by fingerprint: `file|rule-id|signature`
- Confidence 0-25: discard entirely (do not persist)
- Zero silent discards -- every finding is either in the report, in the backlog, or explicitly discarded

### Tag Reviewed Commits (after backlog update)

Every reviewed commit MUST receive a `reviewed/` git tag. This is the mechanism that enables `zuvo:review status` to work. No tag means the review did not happen.

```bash
for H in $(git log --format='%H' REVIEWED_FROM..REVIEWED_THROUGH); do
  h=$(git log --format='%h' -1 "$H")
  git tag -f "reviewed/$h" "$H"
done
```

Skip tagging when scope is `staged` (no committed code to tag).

### NEXT STEPS Block

After the report, ALWAYS print actionable options so the user knows what to do:

**If PASS with 0 issues:**
```
------------------------------------
REVIEW COMPLETE -- PASS, no issues found.
Run: <ISO-8601-Z>	review	<project>	<CQ>	<Q>	PASS	<TASKS>	<DURATION>	<NOTES>	<BRANCH>	<SHA7>
------------------------------------

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.
```

**If issues found:**
```
------------------------------------
REVIEW COMPLETE -- <VERDICT>, <N> issues found.
Run: <ISO-8601-Z>	review	<project>	<CQ>	<Q>	<VERDICT>	<TASKS>	<DURATION>	<NOTES>	<BRANCH>	<SHA7>

NEXT STEPS -- say one of these:
  "fix"         -> apply ALL fixes from this report
  "blocking"    -> apply MUST-FIX only
  "skip"        -> keep report, don't fix
------------------------------------

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.
```

### Questions Gate (after report, before execute)

If the report has QUESTIONS FOR AUTHOR, pause before executing fixes:

1. Surface each question to the user (max 4 at a time if interactive; otherwise print them inline and proceed with the safest default).
2. Incorporate answers -- update severity if answers change the picture.
3. Then proceed to execute if requested.

If no questions, skip this gate.

---

## Phase 4: Execute (FIX-ALL or FIX-BLOCKING mode)

Runs when the user says "fix" or "blocking", or when the skill was invoked in FIX-ALL or FIX-BLOCKING mode from the start.

### Scope Fence

```
===============================================================
EXECUTING FIXES
===============================================================
SCOPE FENCE:
  ALLOWED: [file list from triage]
  FORBIDDEN: files outside scope, new APIs, "while we're here" fixes
FIXES TO APPLY:
  [ ] R-1 [MUST-FIX] Missing orgId filter
  [ ] R-3 [RECOMMENDED] Sequential await in loop
===============================================================
```

FIX-ALL: apply MUST-FIX + RECOMMENDED + NIT. FIX-BLOCKING: MUST-FIX only.

### Execution Strategy

| Condition | Strategy |
|-----------|----------|
| <3 fixes OR fixes share files | Sequential (severity order) |
| 3+ fixes on independent files | Parallel (up to 3 agents per `env-compat.md`) |

Before choosing parallel, verify target files do not import each other. Any dependency between targets forces sequential.

### Fix Loop

1. Apply each fix within the scope fence
2. Write any required tests (complete, runnable -- not stubs)
3. Run verification: detect the project's test runner and execute the full suite
4. If tests fail: check for flaky tests, then fix and repeat
5. If tests pass: run the Execute Verification Checklist

### Execute Verification Checklist

After applying fixes, before committing:

```
EXECUTE VERIFICATION
------------------------------------
[Y/N]  SCOPE: No files modified outside scope fence
[Y/N]  SCOPE: No new features beyond what the fix requires
[Y/N]  TESTS: Full test suite green
[Y/N]  LIMITS: All files within size limits (production <=300L, test <=400L)
[Y/N]  CQ: Self-eval on each modified production file
[Y/N]  Q: Self-eval on each modified/created test file
[Y/N]  NO SCOPE CREEP: Only report fixes applied, nothing extra
------------------------------------
```

Any failure must be addressed before committing.

### Commit and Tag

Commit the fixes with a descriptive message:

```bash
git add [specific files]
git commit -m "review-fix: [brief description]"
git tag review-YYYY-MM-DD-[short-slug]
```

If the environment supports confirmation, confirm before committing. If not (for example Codex App async or Cursor), commit automatically but do NOT push.

### Post-Execute

Show completion:

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

Persist unfixed issues to backlog:
- FIX-BLOCKING mode: RECOMMENDED + NIT issues go to backlog
- Partial fix: any unfixed items go to backlog

---

## Multi-Pass Review (--thorough flag)

Activated by `--thorough` flag, or automatically when the diff exceeds 500 lines. For TIER 0, refuse with a note that multi-pass is unnecessary for diffs under 15 lines.

### How It Works

Run 3 independent review passes. Each pass receives the same diff but examines files in a different order:

| Pass | File order | Rationale |
|------|-----------|-----------|
| Pass 1 | Alphabetical | Baseline reading order |
| Pass 2 | Reverse dependency (leaf files first) | Forces bottom-up reasoning about data flow |
| Pass 3 | Risk score descending (hotspots first) | Focuses attention on highest-risk code while fresh |

**Claude Code:** Dispatch 3 agents in parallel via the Task tool. Each agent performs a full audit pass independently.

**Codex / Cursor:** Execute 3 passes sequentially, maintaining separate finding lists per pass.

### Majority Voting

After all passes complete:

| Agreement | Action |
|----------|--------|
| 3/3 passes found it | KEEP at original tier + boost confidence by 15 |
| 2/3 passes found it | KEEP at original tier |
| 1/3 passes found it | DOWNGRADE one tier (MUST-FIX -> RECOMMENDED, RECOMMENDED -> NIT, NIT -> DROP) |

Merge the most detailed description across passes. Renumber findings as R-1, R-2, R-3... and add synthesis metadata to the report:

```
REVIEW MODE: Multi-pass (3 passes, majority voting)
PASS AGREEMENT: [X] unanimous, [Y] majority, [Z] single-pass (downgraded)
```

Proceed to the Confidence Gate with the synthesized findings.

---

## Adversarial Review Pass (TIER 1+)

After the standard audit completes (Phase 1) and before the Confidence Gate (Phase 2), run an adversarial review pass. This uses a DIFFERENT AI model to catch blind spots that the primary reviewer shares with the code author. **This is NOT optional when conditions are met — run it automatically.**

### When It Runs

| Condition | Adversarial pass |
|-----------|-----------------|
| TIER 0 | Skip |
| TIER 1 + risk signal (auth, payment, crypto, migration, PII) | **Run** (single provider) |
| TIER 1, no risk signals | Skip |
| TIER 2 | **Run** (single provider) |
| TIER 3 | **Run** (multi provider) |
| `--thorough` | **Run** (integrated into multi-pass as Pass 4) |

### How It Works

Dispatch an **Adversarial Auditor** agent with a deliberately different analytical frame:

**Execution profile:** default analysis tier

**Type:** Explore (read-only)

**Persona instructions (included in agent prompt):**
> You are a hostile code reviewer. Assume the author (an AI) has systematic blind spots.
> Your job is to find ways this code could break in production.
> Focus on what other reviewers are likely to MISS, not what they already found.
> Specifically hunt for:
> 1. Edge cases the author didn't consider (timezone, unicode, concurrent access, empty collections)
> 2. Assumptions that are true in tests but false in production (network latency, partial failures, clock skew)
> 3. Security paths that bypass the happy path (auth token expired mid-request, race between check and use)
> 4. Silent failures (catch blocks that swallow errors, promises without rejection handlers)
> 5. Data integrity issues (partial writes without rollback, cache inconsistency with DB)
> Do NOT repeat findings from the primary audit. Only report NEW issues.

**Input:**
- Production code diff (same as primary audit)
- The primary audit's finding IDs (so the adversarial agent avoids duplicates)
- Detected tech stack
- Change intent

**Output format:**
```
ADVERSARIAL FINDINGS:
ADV-1 [severity] [description]
  File: [path:line]
  Attack vector: [how this breaks in production]
  Confidence: [0-100]
ADV-2 ...
```

### Cross-Provider Review (after adversarial agent)

After the internal adversarial agent completes, **run** a cross-provider review using a different AI model. This is NOT optional — execute automatically. Read `../../shared/includes/cross-provider-review.md` for full protocol.

**Execution:**

Run `../../scripts/adversarial-review.sh` on the reviewed diff. Use default multi mode (all available providers in parallel):

```
git diff {REVIEWED_FROM}..{REVIEWED_THROUGH} | adversarial-review.sh --json --mode code
```

The script auto-detects all available providers and runs them in parallel. If a provider fails or times out, results from the others are still used.

**If the script is available and succeeds:**
1. Parse the output for CRITICAL / WARNING / INFO findings
2. Tag findings as `[CROSS:<provider>]` (e.g., `[CROSS:gemini]`)
3. Merge with internal adversarial findings — deduplicate by file:line
4. CRITICAL cross-provider findings become MUST-FIX
5. WARNING become RECOMMENDED
6. INFO become NIT

**If the script is not available or fails:**
Print: `[CROSS-REVIEW] No external provider available. Using internal adversarial pass only.`
Continue with internal adversarial findings only. Do NOT block the pipeline.

### Result Merging

After both the internal adversarial pass and cross-provider review complete:

1. Deduplicate against primary audit findings (same file:line + same issue = drop)
2. Findings that survive dedup are added to the candidate list with an `[ADV]` or `[CROSS]` tag
3. All ADV and CROSS findings proceed through the standard Confidence Gate in Phase 2
4. In the final report, findings are marked: `R-N [MUST-FIX] [ADV] Description...` or `R-N [MUST-FIX] [CROSS:gemini] Description...`

### Multi-Pass Integration

When `--thorough` is active, the adversarial pass becomes **Pass 4** in the multi-pass pipeline:

| Pass | File order | Rationale |
|------|-----------|-----------|
| Pass 1 | Alphabetical | Baseline reading order |
| Pass 2 | Reverse dependency | Bottom-up data flow reasoning |
| Pass 3 | Risk score descending | Hotspots while fresh |
| **Pass 4** | **Risk score descending** | **Adversarial persona — what breaks in production?** |

Majority voting applies across all 4 passes:
- 4/4 or 3/4: KEEP at original tier + boost confidence by 15
- 2/4: KEEP at original tier
- 1/4: DOWNGRADE one tier

---

## Batch Mode (batch <file>)

Process a queue of commits through review, fix, and tag -- one commit at a time, zero interactive stops.

### Input Format

One commit hash per line, optionally with a pipe-separated description:

```
ecbf4351c | perf: memoize productById Map
57a26ea14 | test: broaden cross-app coverage
```

Lines starting with `#` are comments. Lines with `- [x]` or `- [!]` are skipped (resume mode).

### Phase 0: Enrich Queue

Validate each hash with `git cat-file -t <hash>`. Rewrite the file with enriched metadata:

```markdown
# Review Batch -- YYYY-MM-DDTHH:MM:SS
# Total: N | Completed: 0 | Failed: 0 | Pending: N

- [ ] ecbf435 | perf: memoize productById Map | +45/-12 | 3 files
- [ ] 57a26ea | test: broaden cross-app coverage | +320/-40 | 8 files
```

### Per-Commit Loop

For each `[ ]` entry:

1. **Read the diff** -- `git diff <hash>~1..<hash>`. Actually read the code. Classifying by commit message alone is not a review.
2. **Triage** -- Determine tier and risk signals. If TIER 3, mark `[!] TIER 3: needs dedicated zuvo:review` and skip.
3. **Audit at full depth per tier** -- TIER 0 gets a diff scan with 1+ CQ observation. TIER 1 gets CQ self-eval on production files. TIER 2 gets the complete step sequence including CQ1-CQ28 and Q1-Q19.
4. **Fix** -- Apply all fixes (FIX-ALL mode active). If fixes break tests, revert and mark `[!]`.
5. **Tag** -- `git tag -f reviewed/<short-hash> <full-hash>`. Non-negotiable.
6. **Clean backlog** -- Remove the hash from `memory/backlog.md`.
7. **Update queue file** -- Mark completed or failed with evidence.

**Evidence requirement:** Every `[x]` line must include at least one specific code observation. "PASS (0 issues)" without evidence is forbidden.

```
- [x] ecbf435 | perf: memoize | PASS -- CQ17 ok: Map lookup replaces find() at :45
- [x] 57a26ea | test: coverage | FIXED: R-1 Q7 missing error path | fix: abc1234
- [!] dafd1cf | refactor: split | TIER 3: needs dedicated zuvo:review
```

### Resume

Running the batch command on a file with existing progress:
- `[x]` -> skip (completed)
- `[!]` -> skip (needs human decision)
- `[ ]` -> process

### Completion

```
REVIEW BATCH COMPLETE
Total: N | Completed: X | Fixed: Y | Clean: Z | Failed: W
Queue: [path to queue file]

------------------------------------
NEXT STEPS -- say one of these:
  "push"          -> push all fix commits
  "squash fixes"  -> squash fix commits into one
  "done"          -> keep as-is
------------------------------------
```

---

## Utility Modes

### tag

No audit. Cleans the review backlog by removing commits that are ancestors of HEAD:

1. Read `memory/backlog.md`
2. For each unchecked hash, test `git merge-base --is-ancestor <hash> HEAD`
3. If yes, remove the line
4. Print: "Review backlog cleaned. N commits removed, M remaining."
5. STOP.

### mark-reviewed

No audit. Creates lightweight `reviewed/` tags on commits in the specified range.

| Command | Range tagged |
|---------|-------------|
| `zuvo:review mark-reviewed` | All commits on branch (merge-base..HEAD) |
| `zuvo:review mark-reviewed HEAD~3` | Last 3 commits |
| `zuvo:review mark-reviewed abc123..HEAD` | Specific range |

After tagging, clean `memory/backlog.md` by removing tagged commit lines. STOP after output.

### status

No audit. Show unreviewed commits:

1. Build the set of all reviewed commit hashes from `reviewed/*` tags
2. Walk the last N commits (default 100), check each against the set
3. Print the unreviewed commits and a summary: `Total: N | Reviewed: X | Unreviewed: Y`
4. STOP.
