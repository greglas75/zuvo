# zuvo:review Full Revision — Design Specification

> **spec_id:** 2026-04-09-review-revision-1445
> **topic:** Review skill restructure, bug fixes, token optimization, and new features
> **status:** Approved
> **created_at:** 2026-04-09T14:45:00Z
> **approved_at:** 2026-04-09T15:10:00Z
> **approval_mode:** interactive
> **author:** zuvo:brainstorm

## Problem Statement

`zuvo:review` is the most-connected skill in zuvo (17 cross-references, auto-invoked by `ship` and `pentest`). It has accumulated structural debt:

1. **Token bloat** — 920-line monolith loads ~30K tokens mandatory, up to ~42K at TIER 3, before any diff enters the window. TIER 0 (15-line diffs) pays the same 30K as TIER 3.
2. **Inline agents** — 5 agent personas defined inline (no reuse, no frontmatter, weak prompts compared to agents in `execute` and `brainstorm`).
3. **Logical bugs** — adversarial CRITICALs can be discarded by confidence gate, CQ8 false positives on NestJS, staged+fix creates ambiguous commits, empty diffs fall through tier logic.
4. **Phase misordering** — adversarial section sits physically after Phase 4 Execute despite running between Phase 1 and Phase 2.
5. **Adversarial only at TIER 2+** — TIER 0-1 (solo Claude review) has the highest blind spot risk but gets no cross-model validation. The bash script costs 0 Claude tokens and should run at every tier.
6. **Missing features** — no `auto-fix` argument, no report persistence, no stack-specific rules, no test coverage delta, no edge case handling (empty diff, binary, merge commits).
7. **Underutilized CodeSift** — Phase 0 uses hotspots/blast-radius but Phase 1 agents receive no pre-computed data, wasting tokens on discovery work CodeSift can do in milliseconds.

If we do nothing: every review run wastes ~15K tokens on TIER 0, agents produce CQ8 false positives on NestJS projects, and adversarial coverage has a gap at the tiers that need it most.

## Design Decisions

### D1: Phase restructure — match physical order to execution flow

Move adversarial into Phase 1 as the final audit step. Move multi-pass from a top-level section into a dispatch variant within Phase 1. Remove the separate 100-line adversarial section.

**Why:** The current file reads Phase 0 → 1 → 2 → 3 → 4 → Multi-Pass → Adversarial. Execution order is Phase 0 → 1 → Adversarial → Multi-Pass merge → 2 → 3 → 4. Models reading top-to-bottom can misread the execution sequence.

### D2: Extract 4 agents to `skills/review/agents/*.md`

Extract Behavior Auditor, Structure Auditor, CQ Auditor, and Confidence Re-Scorer to standalone agent files with full frontmatter, tool discovery, structured output, and "What You Must NOT Do" sections. Kill the internal Adversarial Auditor agent (replaced by D3).

**Why:** Inline agents lack the quality of agents in `execute` and `brainstorm` (no frontmatter, no CodeSift guidance, no output templates, no calibration examples). Extraction enables reuse and on-demand loading (TIER 0-1 loads 0 agent files).

### D3: Adversarial = bash script only, at ALL tiers

Replace the internal Adversarial Auditor agent + cross-provider section (~100 lines) with a single call to `adversarial-review.sh` at every tier. The script sends the diff to all available external providers (Gemini, Codex, opposite-Claude-model) in parallel.

**Why:** The internal agent is Claude reviewing Claude — same blind spots. The bash script costs 0 Claude context tokens and provides true cross-model diversity. For TIER 0 (15-line diff), the script call takes 5-10 seconds. There is no tier where skipping adversarial is justified.

**Provider count:** The script auto-detects and runs ALL available providers at every tier. There is no "single provider" mode — if Gemini, Codex, and Claude-opposite are all available, they all run in parallel regardless of tier. The cost is external (provider API calls), not Claude tokens. Simplicity over per-tier provider gating.

### D4: Tiered cq-patterns loading

- TIER 0: skip both `cq-patterns.md` and `cq-patterns-core.md`
- TIER 1: load `cq-patterns-core.md` (58L, ~500 tokens)
- TIER 2+: load full `cq-patterns.md` (700L, ~8.4K tokens)

`cq-patterns-core.md` already exists at `rules/cq-patterns-core.md`.

**Why:** TIER 0 is a 15-line diff — 700 lines of patterns is pure waste. TIER 1 needs patterns but the core subset (universal error handling, security, data integrity, async) covers 90% of what a 15-100 line diff will trigger.

### D5: CodeSift pre-compute before agent dispatch

Add a "Phase 0.5: CodeSift Pre-Compute" step that runs a batch `codebase_retrieval` query before dispatching agents. Results are passed as structured input to each agent, replacing their discovery work.

**Why:** Agents currently waste tokens scanning diffs for patterns that CodeSift can find in milliseconds. Pre-computed data (file outlines, pattern matches, test references, complexity scores, callee chains) lets agents focus on judgment, not search.

### D6: All findings go to backlog

Replace the current disposition table (0-25 = discard forever) with: all findings persist to `memory/backlog.md`. Low-confidence items get tagged `[low-confidence]`.

**Why:** "Zero silent discards" is currently a lie (line 494 says it, but 0-25 items vanish). If the confidence scorer misjudges a real bug as hallucination, it is lost forever. Backlog persistence with tags lets users verify and escalate later.

### D7: Adversarial CRITICAL bypass confidence gate

Adversarial findings tagged CRITICAL always enter the report at MUST-FIX. They skip the confidence gate entirely (minimum effective confidence = 100).

**Why:** Current design lets adversarial CRITICALs be scored 0-25 and discarded. This contradicts `adversarial-loop.md` line 113: "CRITICAL → Fix immediately. No exceptions."

### D8: Reports saved to disk

Save review reports to `memory/reviews/YYYY-MM-DD-<scope>.md` at TIER 1+.

**Why:** Current reports exist only in conversation. No trending, no cross-review diffs, no persistent artifact. `memory/reviews/` is consistent with `memory/backlog.md` and stays in `.gitignore`.

### D9: Merged banner — 4 banners → 1

Replace the 4 separate output blocks (file loading checklist, triage result, step header, review header) with a single combined header.

**Why:** ~30 lines of output before any finding appears. Wastes output tokens and user attention.

### D10: `auto-fix` as first-class argument

Add `auto-fix` to the argument parsing table as a parseable mode token.

**Why:** Currently only works as a follow-up message after report. Users seeing the argument table don't know it exists.

---

## Feature Summary

| ID | Feature | Tier Gate | Design Decision |
|----|---------|-----------|-----------------|
| F1 | `auto-fix` as first-class argument | All | D10 |
| F2 | Report persistence to `memory/reviews/` | TIER 1+ | D8 |
| F3 | Stack-specific rule loading | TIER 2+ | Detailed Design |
| F4 | Test coverage delta detection | TIER 2+ | Detailed Design |
| F5 | Self-review → auto-escalate adversarial to all providers | All | Detailed Design |
| F6 | Empty/binary/merge edge case handling | All | B6+B7+B9 |
| F7 | `status --depth N` configurable commit depth | Utility | B11 |
| F8 | Merged banner (4 → 1) | All | D9 |
| F9 | QUESTIONS FOR AUTHOR moved to position 4 (before FINDINGS) | All | Detailed Design |
| F10 | QUALITY WINS specification (criteria, max count) | All | Detailed Design |

---

## Solution Overview

### New SKILL.md Structure (~550 lines, down from 920)

```
Frontmatter + intro                              ~10L
Mandatory File Loading (tiered)                   ~40L  (split CORE vs OPTIONAL)
Argument Parsing (+ auto-fix mode)                ~45L
Tier System (+ empty/binary/merge handling)       ~90L
Phase 0: Setup (+ stack detect, default branch)   ~45L
Phase 0.5: CodeSift Pre-Compute                   ~30L  (NEW)
Phase 1: Audit                                    ~80L  (agents external, adversarial = script)
  - Agent dispatch (refs agents/*.md)
  - Inline audit (TIER 0-1)
  - CQ/Q evaluation
  - Adversarial (bash script, all tiers)
  - Multi-pass variant (--thorough)
Phase 2: Confidence Gate                          ~25L  (+ adversarial CRITICAL bypass)
Phase 3: Report                                   ~80L  (+ persistence, merged banner, questions before findings)
Phase 4: Execute                                  ~30L  (refs shared/includes/fix-loop.md)
Batch Mode                                        ~60L  (TIER 3 inline, not recursive dead-end)
Utility Modes (+ status --depth N)                ~35L
```

### New Files

| File | Lines (est.) | Purpose |
|------|-------------|---------|
| `skills/review/agents/behavior-auditor.md` | ~70L | Logic correctness, error handling, async safety, CQ3-CQ10 |
| `skills/review/agents/structure-auditor.md` | ~55L | Naming, imports, circular deps, file limits, SRP, coupling |
| `skills/review/agents/cq-auditor.md` | ~65L | Independent CQ1-CQ28 evaluation with PROJECT_CONTEXT |
| `skills/review/agents/confidence-rescorer.md` | ~50L | Confidence scoring with calibration examples |
| `shared/includes/fix-loop.md` | ~50L | Reusable fix loop (shared with `build`) |

### Modified Files

| File | Change |
|------|--------|
| `skills/review/SKILL.md` | Full rewrite (920L → ~550L) |
| `shared/includes/severity-vocabulary.md` | Clarify that the existing "adversarial loop" row (CRITICAL/WARNING/INFO → S1/S2/S4) covers bash script adversarial findings within review. Add a footnote: "The adversarial loop row applies to all adversarial-review.sh output regardless of which skill invokes it. Within `/review`, CRITICAL findings bypass the confidence gate (D7)." No new row needed — the existing mapping is correct. |
| `docs/review-queue.md` | Move to post-implementation documentation follow-up (not blocking for spec) |

---

## Detailed Design

### Mandatory File Loading (tiered)

Split the checklist into CORE (STOP on missing) and OPTIONAL (degraded on missing):

```
CORE FILES (STOP if missing):
  1. codesift-setup.md     -- [READ | MISSING -> STOP]
  2. env-compat.md         -- [READ | MISSING -> STOP]
  3. quality-gates.md      -- [READ | MISSING -> STOP]
  4. run-logger.md         -- [READ | MISSING -> STOP]

OPTIONAL FILES (degraded if missing):
  5. knowledge-prime.md    -- [READ | MISSING -> degraded]
  6. knowledge-curate.md   -- [READ | MISSING -> degraded]

CONDITIONAL FILES (loaded after triage):
  cq-patterns-core.md     -- TIER 1 only
  cq-patterns.md          -- TIER 2+
  cq-checklist.md         -- TIER 1+
  testing.md              -- if test files in diff
  security.md             -- if security signals or TIER 3
  cross-provider-review.md -- always (adversarial runs at all tiers)
```

Key change: `cq-patterns.md` moves from mandatory to conditional. `cross-provider-review.md` explicitly listed (was missing).

### Token Budget by Tier

| Component | TIER 0 | TIER 1 | TIER 2 | TIER 3 |
|-----------|--------|--------|--------|--------|
| SKILL.md (~550L) | 6.5K | 6.5K | 6.5K | 6.5K |
| codesift-setup.md | 1.8K | 1.8K | 1.8K | 1.8K |
| env-compat.md | 2.1K | 2.1K | 2.1K | 2.1K |
| quality-gates.md | 1.7K | 1.7K | 1.7K | 1.7K |
| run-logger.md | 1.6K | 1.6K | 1.6K | 1.6K |
| cq-patterns-core.md | — | 0.5K | — | — |
| cq-patterns.md | — | — | 8.4K | 8.4K |
| cq-checklist.md | — | 3.3K | 3.3K | 3.3K |
| Agent files (on-demand) | — | — | ~1.5K | ~3K |
| cross-provider-review.md | 1.4K | 1.4K | 1.4K | 1.4K |
| testing.md (if tests) | — | — | 5.6K | 5.6K |
| security.md (if signals) | — | — | — | 1.9K |
| **TOTAL (mandatory)** | **~15K** | **~19K** | **~28K** | **~33K** |
| **Current baseline** | ~30K | ~30K | ~35K | ~42K |
| **Saving** | **-50%** | **-37%** | **-20%** | **-21%** |

Note: TIER 2-3 totals include cross-provider-review.md (1.4K) which is always loaded since adversarial runs at all tiers. Agent files at TIER 2 are conditional on new production files; worst case shown.

### Argument Parsing (updated)

New mode table:

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

### Tier System (edge cases added)

**Updated Tier Capabilities table (replaces current SKILL.md table):**

| Capability | TIER 0 | TIER 1 | TIER 2 | TIER 3 |
|-----------|--------|--------|--------|--------|
| Inline diff scan | Yes | Yes | Yes | Yes |
| CQ patterns loaded | Skip | Core (500 tok) | Full (8.4K tok) | Full (8.4K tok) |
| CQ1-CQ28 evaluation | Skip | Yes (lead inline) | Yes (CQ Auditor agent) | Yes (CQ Auditor agent) |
| Q1-Q19 on test files | Skip | If present (lead) | Yes | Yes |
| Audit agents | None | None | Behavior + CQ (if new files) | All 3 (Behavior + Structure + CQ) |
| Adversarial (bash script) | Yes (all available) | Yes (all available) | Yes (all available) | Yes (all available) |
| CodeSift pre-compute | Optional (minimal) | Yes (3 queries) | Yes (5 queries) | Yes (5 queries) |
| Confidence scoring | Lead inline | Lead inline | Re-Scorer agent | Re-Scorer agent |
| Hotspot detection | Skip | Skip | Yes | Yes |
| Multi-pass (--thorough) | Refused | Optional | Optional | Auto if >500L |
| Security deep dive | Skip | Skip | Skip | Yes |
| Stack-specific rules | Skip | Skip | Yes | Yes |
| Report persistence | Skip | Yes | Yes | Yes |

New rows in tier selection:

| Condition | Tier | Action |
|-----------|------|--------|
| 0 files changed (empty diff) | — | Print "No changes to review." → STOP |
| All files are binary | — | Print "Only binary files changed. Nothing to review." → STOP |
| Binary files mixed with code | Tier based on code lines only | Note binary files in report, exclude from line count |
| Merge commit detected | — | Interactive: warn + offer `--first-parent`. Non-interactive (Codex App, Cursor): auto-apply `--first-parent` with `[AUTO-DECISION]` annotation |

**Deployment risk hotspot factor at TIER 0-1 (B12 fix):** The "File in churn hotspot (top 10)" scoring factor requires Phase 0 hotspot detection, which is skipped at TIER 0-1. For TIER 0-1, this factor is explicitly scored as 0 points in the deployment risk calculation. Add a note in the scoring table: "File in churn hotspot (top 10) | +2 | From Phase 0 hotspot detection (TIER 2+). **Score 0 at TIER 0-1.**"

Default branch detection for `new` scope:

```bash
# Replace hardcoded "main" with:
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
git merge-base HEAD "$DEFAULT_BRANCH"
```

### Phase 0.5: CodeSift Pre-Compute (NEW)

After Phase 0 setup and before Phase 1 audit dispatch. Runs only when CodeSift is available. When unavailable, agents fall back to their own analysis (degraded mode documented in each agent file).

**TIER 0 (optional — may be skipped without impacting audit):** Pre-compute is optional for ≤15 line diffs. If CodeSift is available, the pattern scan adds marginal value; if latency is a concern, skip entirely. Lead performs inline analysis from the diff alone.

**TIER 1 (no agents — pre-compute feeds inline analysis):**

```
codebase_retrieval(repo, queries=[
  {"type": "patterns", "pattern": "empty-catch", "file_pattern": "<changed files>"},
  {"type": "references", "symbol_names": [<changed exports>], "file_pattern": "*.test.*"},
  {"type": "complexity", "file_pattern": "<changed files>"}
], token_budget=2000)
```

Results used directly by the lead for inline CQ evaluation and test coverage delta detection.

**TIER 2-3 (agents — pre-compute feeds agent input):**

```
codebase_retrieval(repo, queries=[
  {"type": "file_outlines", "paths": [<changed files>]},
  {"type": "references", "symbol_names": [<changed symbols>], "file_pattern": "*.test.*"},
  {"type": "call_chain", "symbol_name": "<key changed symbol>", "direction": "callees"},
  {"type": "patterns", "pattern": "empty-catch", "file_pattern": "<changed files>"},
  {"type": "complexity", "file_pattern": "<changed files>"}
], token_budget=5000)
```

Results passed as structured `PRECOMPUTED_DATA` section in each agent's input. Agents use this data as a starting point — they can run additional CodeSift queries if needed but should not repeat pre-computed work.

**What each agent receives from pre-compute:**

| Agent | Pre-computed data | How it helps |
|-------|------------------|-------------|
| Behavior Auditor | Callee chains, pattern matches, complexity | Knows immediately where to focus (high-complexity functions, empty catches) |
| Structure Auditor | File outlines, complexity scores | SRP violations and file limit checks pre-answered |
| CQ Auditor | Pattern matches, test references | ~40% of CQ gates pre-evaluated (CQ6, CQ8, CQ13, CQ23) |
| Confidence Re-Scorer | Reference counts, hotspot ranks | Confidence based on data (47 callers = high impact) not intuition |

### Phase 1: Audit (restructured)

New sub-phase ordering within Phase 1:

```
Standard flow (no --thorough):
  1.1  Self-Review Disclosure
  1.2  Review Header (merged banner — single block)
  1.3  Agent Dispatch (TIER 2+) or Inline Audit (TIER 0-1)
  1.4  CQ Self-Evaluation (TIER 1+)
  1.5  Q1-Q19 Evaluation (if test files)
  1.6  Adversarial (bash script — ALL tiers)
  1.7  Result Merging + deduplication

With --thorough:
  1.1  Self-Review Disclosure
  1.2  Review Header (merged banner — single block)
  1.3  Multi-Pass: 3 independent audit passes in parallel (each includes CQ + Q eval)
  1.4  Multi-Pass merge with majority voting (3/3, 2/3, 1/3 thresholds)
  1.5  Adversarial (bash script — runs AFTER multi-pass merge, on the merged diff)
  1.6  Result Merging: multi-pass findings + adversarial findings, deduplication
```

**1.2 Merged Banner** — replaces 4 separate blocks:

```
===============================================================
CODE REVIEW
===============================================================
SCOPE:  [N files, +X/-Y lines] | TIER [0-3] ([NANO-DEEP])
INTENT: [BUGFIX / REFACTOR / FEATURE / INFRA]
AUDIT:  [SOLO / TEAM (N auditors)] | Adversarial: [providers]
RISK:   [LOW-CRITICAL] — [1-2 sentence rationale]
FILES:  [loaded includes list]

Risk signals: [x] API contract  [ ] DB/migration  ...
===============================================================
```

One block. ~12 lines. Replaces ~30 lines of 4 separate banners.

**1.3 Agent Dispatch** — agents loaded from external files:

```
TIER 0-1: No agents dispatched. Lead performs inline analysis using
          CodeSift pre-computed data (Phase 0.5).

TIER 2:   Dispatch Behavior Auditor (if new production files).
          CQ Auditor dispatched as background agent.
          Lead performs Structure analysis inline.

TIER 3:   Dispatch all 3 audit agents in parallel:
            Agent 1: [read agents/behavior-auditor.md]
            Agent 2: [read agents/structure-auditor.md]
            Agent 3: [read agents/cq-auditor.md]
          Each agent receives: diff, tech stack, change intent,
          PRECOMPUTED_DATA from Phase 0.5, PROJECT_CONTEXT.
```

**1.6 Adversarial (all tiers):**

```bash
git diff {REVIEWED_FROM}..{REVIEWED_THROUGH} | adversarial-review --json --mode code
```

If `adversarial-review` not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Script auto-detects providers and runs all available in parallel (Gemini, Codex, opposite-Claude-model).

**Failure modes:**
- Provider timeout (>60s): skip that provider, use results from others
- Malformed JSON from a provider: skip that provider with warning
- All providers unavailable: print `[CROSS-REVIEW] No external provider available. Proceeding without adversarial.` — continue review, add to SKIPPED STEPS in report
- Partial success (1 of 3 providers): use available results, note which providers were skipped

Parse JSON output:
- CRITICAL → MUST-FIX (bypass confidence gate per D7)
- WARNING → RECOMMENDED
- INFO → NIT
- Tag each finding as `[CROSS:<provider>]`
- Deduplicate against primary audit findings (same file:line + same issue = drop)

**Self-review escalation (F5):** When self-review detected in 1.1, pass `--all-providers` flag to the script to force multi-provider mode regardless of tier.

**Multi-pass + adversarial interaction:** With `--thorough`, multi-pass uses **3-pass majority voting** (Pass 1: alphabetical, Pass 2: reverse dependency, Pass 3: risk score descending). The old Pass 4 (adversarial persona) is eliminated — the internal Adversarial Auditor agent no longer exists. The bash script adversarial (step 1.5 in --thorough flow) runs **after multi-pass merge** (step 1.4), not as a voting pass. Adversarial findings are NOT subject to majority voting — adversarial WARNING/INFO go through the confidence gate individually; adversarial CRITICAL bypasses the gate per D7. Majority voting thresholds: 3/3, 2/3, 1/3.

### Phase 2: Confidence Gate (updated)

**Dispatch logic:**
- TIER 0-1: Lead scores each finding inline using the scoring factors below. For each issue, state `Confidence: [X]/100 — [reason]`.
- TIER 2+: Dispatch Confidence Re-Scorer agent (`agents/confidence-rescorer.md`). Agent receives full candidate list, pre-computed data, and adversarial findings.

New disposition table:

| Confidence | Action | Backlog tag |
|-----------|--------|-------------|
| 0-25 | EXCLUDE from report | `[low-confidence]` |
| 26-50 | EXCLUDE from report | `[below-threshold]` |
| 51-100 | KEEP in report | — |

**Backlog write timing:** All backlog writes happen AFTER Phase 4 Execute (or after Phase 3 Report if no execute). This prevents stale entries: if Phase 4 fixes a finding, it is NOT written to backlog. Only unfixed findings and excluded findings are persisted. The Confidence Re-Scorer tags dispositions but does NOT write to backlog directly — it returns tags to the orchestrator, which writes after execute.

**Adversarial CRITICAL bypass:** Findings from `adversarial-review.sh` tagged CRITICAL skip the confidence gate entirely. They enter the report as MUST-FIX with effective confidence 100.

**Adversarial WARNING/INFO:** Proceed through normal confidence gate.

### Phase 3: Report (updated)

New report section order (QUESTIONS moved to position 4):

```
1.  META — date, intent, tier, audit mode, agents, confidence method, CodeSift status
2.  SCOPE FENCE — files examined, files excluded
3.  VERDICT — PASS / WARN / BLOCKED with score
4.  QUESTIONS FOR AUTHOR — genuine uncertainties (moved from position 11). **Questions Gate integrated into report flow.** Questions are now visible at position 4, before findings. In interactive mode with FIX-ALL/FIX-BLOCKING/AUTO-FIX: the skill prints positions 1-4 (META through QUESTIONS), pauses for user answers, **re-evaluates affected findings based on answers** (user says "intentional" → downgrade to NIT or drop), then prints positions 5+ with updated findings. In REPORT mode (default): no pause, questions are informational alongside findings.
5.  DEPLOYMENT RISK — LOW-CRITICAL with deploy strategy
6.  SEVERITY SUMMARY — MUST-FIX: N | RECOMMENDED: N | NIT: N
7.  CHANGE SUMMARY — what the diff does in plain language
8.  SKIPPED STEPS — which audit steps were skipped and why
9.  VERIFICATION PASSED — what checks passed cleanly (with confidence indicator)
10. BACKLOG ITEMS IN SCOPE — open backlog items in touched files
11. DROPPED ISSUES — findings filtered by confidence gate (with tag)
12. FINDINGS — grouped: MUST-FIX first, then RECOMMENDED, then NIT (collapsed)
13. QUALITY WINS — things done well (max 3, criteria: novel pattern, good error handling, clean refactor)
14. TEST ANALYSIS — test validity, coverage delta, existing test status
```

**NIT visual subordination:** NITs are listed as a collapsed/summary block, not individual findings:

```
NITs (3 items — style/readability, no functional impact):
  R-12 unused import at auth.ts:3
  R-13 prefer ?? over || at config.ts:45
  R-14 collapsible if at user.service.ts:88
```

**Report persistence (TIER 1+):**

After generating the report, save to `memory/reviews/YYYY-MM-DD-<scope>.md`. Content = the full report as printed. The file is the persistent artifact for trending and cross-review diffs.

**QUALITY WINS specification:**

Max 3 items. Criteria for inclusion:
- Novel pattern not seen elsewhere in the codebase
- Particularly clean error handling or edge case coverage
- Good refactoring that reduces complexity
- Effective test that catches a real edge case

Format: `[WIN] description — file:line`

### Phase 4: Execute (refs fix-loop.md)

Replace the inline fix loop (~90 lines) with a reference to `shared/includes/fix-loop.md`:

```
Read and follow the fix loop protocol from `../../shared/includes/fix-loop.md`.

Input:
  FINDINGS: [list of R-N findings to fix, per mode]
  SCOPE_FENCE: [allowed files from triage]
  MODE: FIX-ALL | FIX-BLOCKING | AUTO-FIX

FIX-ALL:      apply MUST-FIX + RECOMMENDED + NIT
FIX-BLOCKING: apply MUST-FIX only
AUTO-FIX:     dispatch zuvo:build for MUST-FIX (closed-loop, max 1 cycle)
```

**Review-specific wrapper around fix-loop.md:**

After fix-loop.md completes (commit done), SKILL.md adds:

1. Review-specific git tag: `git tag review-YYYY-MM-DD-[short-slug]`
2. Post-Execute output block:
```
===============================================================
EXECUTION COMPLETE
===============================================================
FILES MODIFIED: [list]
FIXED: [list of R-N items fixed]
TESTS WRITTEN: [list]
VERIFIED: Tests PASS, Types PASS
Commit: [hash] — [message]
Tag: [tag name]
===============================================================
```
3. Persist unfixed issues to backlog (FIX-BLOCKING: RECOMMENDED + NIT; partial fix: any unfixed items)

These are NOT in fix-loop.md (which is generic). They wrap the fix-loop call in SKILL.md's Phase 4 section.

**Staged + fix bug fix (B5):** When scope is `staged`, the fix-loop.md handles the commit internally. The SKILL.md wrapper adds stash management around the fix-loop call:

```
1. git stash --keep-index        # save unstaged changes
2. Run fix-loop.md (it applies fixes, runs tests, and commits)
3. git stash pop                 # restore unstaged changes — ALWAYS runs, even if fix-loop fails
```

**Failure recovery:** If fix-loop aborts (tests fail, fix breaks), `git stash pop` MUST still execute. The SKILL.md wrapper treats stash pop as a `finally` block — it runs regardless of fix-loop outcome. If fix-loop fails, the wrapper pops the stash and reports the failure.

This separates the user's staged changes from review fixes. The wrapper does NOT issue its own `git commit` — fix-loop.md handles that.

**Batch mode TIER 3 fix (B10):** Replace "needs dedicated zuvo:review" with:

```
TIER 3 in batch: run full review inline (sequential agent execution per env-compat.md).
Do NOT skip. Do NOT redirect to a separate invocation.
```

### Stack-Specific Rule Loading (F3, TIER 2+)

In Phase 0, after stack detection:

```
Detected stack → load matching rules file:

| Stack indicator              | Rules file              |
|------------------------------|-------------------------|
| tsconfig.json                | rules/typescript.md     |
| next.config.* or app/layout  | rules/react-nextjs.md   |
| nest-cli.json or @nestjs/*   | rules/nestjs.md         |
| requirements.txt / pyproject | rules/python.md         |
| go.mod                       | rules/go.md (if exists) |

Load at most 2 rules files. Pass to agents as STACK_RULES input.
```

### Test Coverage Delta (F4, TIER 2+)

In Phase 1, after CodeSift pre-compute:

```
For each changed production file:
  1. Get changed symbols from diff
  2. Check pre-computed test references (from Phase 0.5)
  3. Symbols with 0 test references → RECOMMENDED finding:
     "R-N [RECOMMENDED] No test coverage for [symbol] — changed without corresponding test update"
```

At TIER 0: skip entirely. At TIER 1: the pre-compute includes test references — if a changed symbol has 0 test refs, note it as an observation in the report (not a formal RECOMMENDED finding, just a note in TEST ANALYSIS section). At TIER 2+: formal RECOMMENDED findings with evidence.

---

## Agent Prompt Design

Each agent file follows this structure (matching quality-reviewer.md and implementer.md standard):

```markdown
---
name: <agent-name>
description: "<one-line role>"
model: sonnet
reasoning: false
tools:
  - Read
  - Grep
  - Glob
---

# <Agent Name>

<One paragraph: who you are, who dispatches you, what you do.>

Read and follow the agent preamble at `../../../shared/includes/agent-preamble.md`.

## What You Receive

<Explicit numbered list of inputs from orchestrator.>

## Tool Discovery

<CodeSift setup + degraded fallback. Standard block from codesift-setup.md.>

## Workflow

<Numbered step-by-step procedure. Not "focus areas" — concrete actions.>

## Output Format

<Full template with every required field.>

## Calibration Examples

<2-3 examples with concrete confidence scores and rationale.>

## What You Must NOT Do

<4-6 explicit prohibitions.>
```

### Agent 1: Behavior Auditor

**What You Receive:**
1. Production code diff (excluding test files, config, locks)
2. Detected tech stack and change intent
3. `PRECOMPUTED_DATA` — callee chains, pattern matches, complexity scores from Phase 0.5
4. `PROJECT_CONTEXT` — global error handlers, middleware, decorators (if detected)
5. CODESIFT_AVAILABLE flag and repo identifier
6. Tier and risk signals

**Workflow:**
1. Read PRECOMPUTED_DATA — identify high-complexity functions and pre-detected patterns
2. For each changed production file, check: error handling paths, null safety, async correctness, race conditions, state management
3. For FEATURE intent: verify feature completeness (loading/error/empty states)
4. For REFACTOR intent: verify behavioral equivalence (before matches after)
5. Apply CQ3-CQ10 checks on each file. Use PRECOMPUTED_DATA pattern matches as starting point — do not re-scan for patterns already detected
6. For each finding: assign confidence, provide file:line evidence, describe production failure scenario

**Specific checks (not categories):**
- CQ3: atomicity — check-then-act patterns, TOCTOU in concurrent paths
- CQ5: timing-safe comparison — `===` on secrets
- CQ6: unbounded queries — findMany without take/limit
- CQ8: error handling — empty catch, missing catch, swallowed errors (but respect PROJECT_CONTEXT: if global exception filter exists, per-service catch is optional for non-critical paths)
- CQ9: async — missing await, async forEach, Promise without catch
- CQ10: resource cleanup — listeners without removeEventListener, intervals without clear

**Output format:**
```
## Behavior Auditor Report

### Findings

BEHAV-1 [severity] [description]
  File: [path:line]
  Confidence: [0-100]
  Evidence: [specific code reference]
  Production impact: [how this breaks in production]

BEHAV-2 ...

### Summary

[What was checked, what was found, overall assessment.]

### Quality Wins

[Things done well — max 2 per agent. Criteria: novel pattern, clean error handling, effective edge case coverage.]
- [WIN] description — file:line
(or "None observed")

### BACKLOG ITEMS

[Issues outside scope, or "None"]
```

**Calibration examples:**
- `Confidence: 92` — `findMany` at order.service.ts:87 has no `take` parameter, called in a GET endpoint with user-supplied filter. Bounded query is missing. Clear CQ6 violation with production OOM risk.
- `Confidence: 35` — `catch (err) { logger.warn(err) }` at cache.service.ts:45. Looks like swallowed error but this is a cache warm path — warn + continue is the correct strategy per CQ8 context-aware rules. Low confidence because PROJECT_CONTEXT shows this service is non-critical.

**Degraded mode (CodeSift unavailable):** Fall back to Read for full file content, Grep for pattern matching (`grep -n "catch.*{" <file>` for empty catches, `grep "findMany" <file>` for unbounded queries). Skip callee chain analysis. Note "CodeSift unavailable — callee chain not analyzed" in report.

**What You Must NOT Do:**
- Do not flag CQ8 on services when PROJECT_CONTEXT shows a global exception filter handles errors
- Do not report style/naming issues — that is the Structure Auditor's scope
- Do not score CQ gates — that is the CQ Auditor's scope. Report behavioral findings only
- Do not read files that are not in the diff — stay within scope
- Do not report findings without file:line evidence

### Agent 2: Structure Auditor

**What You Receive:**
1. Production code diff
2. Detected tech stack and change intent
3. `PRECOMPUTED_DATA` — file outlines, complexity scores from Phase 0.5
4. Blast radius data from Phase 0
5. CODESIFT_AVAILABLE flag and repo identifier
6. Content of `rules/file-limits.md` (provided by orchestrator)

**Workflow:**
1. Read PRECOMPUTED_DATA file outlines — check function count, export count per file
2. Apply file-limits.md thresholds: production file ≤300L, test ≤400L, function ≤50L, params ≤5
3. Check naming conventions against project patterns (read 2-3 existing files for calibration)
4. Check import correctness: circular deps (use CodeSift `find_circular_deps` if available), barrel export patterns
5. Check SRP: file outline shows >8 public methods = flag for review
6. Check coupling: blast radius data shows >5 direct importers of a changed module = flag

**Output format:**
```
## Structure Auditor Report

### Findings

STRUCT-1 [severity] [description]
  File: [path:line]
  Confidence: [0-100]
  Evidence: [measurement or reference]
  Threshold: [limit vs actual]

STRUCT-2 ...

### File Metrics

| File | Lines | Functions | Exports | Complexity | Status |
|------|-------|-----------|---------|------------|--------|
| ... | ... | ... | ... | ... | OK / OVER LIMIT |

### Quality Wins

[Max 2. Criteria: clean module boundaries, good refactoring, well-organized file structure.]
- [WIN] description — file:line
(or "None observed")

### Summary

[What was checked, what was found.]

### BACKLOG ITEMS

[Or "None"]
```

**Calibration examples:**
- `Confidence: 88` — STRUCT-1: order.service.ts is 412 lines (limit 300). 9 public methods. File outline shows clear SRP violation — service handles both order CRUD and payment orchestration. High confidence: objective measurement exceeds hard limit.
- `Confidence: 32` — STRUCT-3: function `processWebhook` is 52 lines (limit 50). Only 2 lines over limit, single responsibility, clean early returns. Low confidence: marginal violation, not worth refactoring.
- `Confidence: 15` — STRUCT-5: `getUserName` uses camelCase but project has 3 files with snake_case helpers. After reading 5 existing files, camelCase is the dominant convention (>80%). The snake_case files are legacy. Low confidence: flagging would be wrong.

**Degraded mode (CodeSift unavailable):** Fall back to Read for file content, count lines with `wc -l`, count functions with Grep (`grep -c "function\|=>.*{" <file>`). Skip circular dependency detection and complexity scoring. Note "CodeSift unavailable — complexity and circular dep analysis skipped" in report.

**What You Must NOT Do:**
- Do not check logic correctness — that is the Behavior Auditor's scope
- Do not evaluate CQ gates — that is the CQ Auditor's scope
- Do not flag naming that matches existing project conventions (read existing files first)
- Do not report findings without measurement data (line count, function count, import count)

### Agent 3: CQ Auditor

**What You Receive:**
1. Full source of each changed production file (not just diff — needs complete context)
2. CQ checklist reference (`rules/cq-checklist.md`)
3. CQ patterns reference (`rules/cq-patterns.md` or `cq-patterns-core.md` per tier)
4. `PRECOMPUTED_DATA` — pattern matches, test references from Phase 0.5
5. `PROJECT_CONTEXT` — global error handlers, middleware, decorators, DI container details
6. Detected tech stack
7. CODESIFT_AVAILABLE flag and repo identifier

**Workflow:**
1. Read PROJECT_CONTEXT first — understand what the framework handles globally before scoring individual files
2. For each changed production file:
   a. Read the full source (not just the diff)
   b. Score all 28 CQ gates as 1/0/N/A with file:line evidence
   c. Use PRECOMPUTED_DATA pattern matches as pre-validated evidence (e.g., empty-catch match at line 45 = CQ8 pre-confirmed)
   d. Count N/A scores — if >60% (17+), flag as "low-signal audit" and justify each N/A
3. Check for CQ8 context: if PROJECT_CONTEXT has a global exception filter AND the service is non-critical-path, CQ8 per-method catch is N/A (not 0)

**Output format:**
```
## CQ Auditor Report

### Per-File Evaluation

CQ AUDIT: [filename] ([N]L)
CQ1=1 CQ2=0 CQ3=N/A ... CQ28=N/A
Score: X/Y applicable -> [PASS / CONDITIONAL PASS / FAIL]
Critical gates: CQ3=1(validated:42) CQ5=0(PII in log:54)
Evidence: [file:function:line for each gate scored 1 or 0]
N/A justification: [for each N/A, ≤10 words]
PROJECT_CONTEXT applied: [which gates were affected by global handlers]

### Cross-File Patterns

[Patterns that span multiple files — e.g., inconsistent error handling across 3 services]

### Summary

[Overall CQ health, critical failures, N/A ratio.]

### BACKLOG ITEMS

[Or "None"]
```

**Calibration examples:**
- `CQ8=N/A` (correct) — user.service.ts in NestJS project with global AllExceptionsFilter registered in main.ts. Non-critical service. Global handler catches and logs. Per-method catch is optional.
- `CQ8=0` (correct) — payment.service.ts in same project. Critical path (money). Global filter is insufficient — payment errors need specific handling with retry/rollback logic. Evidence: processPayment:67 has bare `throw` without cause chain.
- `CQ8=0` (WRONG — should be N/A) — cache.service.ts warm-cache method. `catch { logger.warn(...) }` is the CORRECT pattern for non-critical cache warming per cq-patterns.md "error strategy by impact."

**Degraded mode (CodeSift unavailable):** Fall back to Read for full file source. Use Grep for pattern searches (`grep -n "catch" <file>`, `grep -n "findMany" <file>`). All 28 gates must still be evaluated — degraded mode affects speed, not coverage.

**What You Must NOT Do:**
- Do not trust the lead's CQ scores — evaluate from scratch
- Do not score a gate as 1 without file:line evidence
- Do not score CQ8 as 0 on non-critical services when PROJECT_CONTEXT shows global error handling
- Do not score >60% N/A without per-gate justification
- Do not skip any of the 28 gates

### Agent 4: Confidence Re-Scorer

**What You Receive:**
1. Full list of candidate findings (ID, severity, file, code quote, problem description)
2. Change intent and tier
3. Pre-existing data (blame results)
4. `PRECOMPUTED_DATA` — reference counts, hotspot ranks from Phase 0.5
5. Path to backlog file (`memory/backlog.md`)
6. List of adversarial findings and their source providers

**Workflow:**
1. For each finding, compute confidence score 0-100 based on scoring factors
2. Check adversarial findings: if source is CRITICAL from adversarial script → assign confidence 100 (bypass)
3. Use PRECOMPUTED_DATA reference counts: high reference count = high blast radius = confidence boost
4. Use hotspot rank: file in top-10 hotspots = confidence boost (+10)
5. Apply disposition rules per confidence score
6. Write all dispositions (including 0-25 items) to backlog with tags

**Scoring factors:**

| Factor | Effect |
|--------|--------|
| Matches a CQ/Q critical gate | +25 |
| Concrete reproduction scenario | +20 |
| User-visible or money/auth/data impact | +15 |
| High reference count (>10 callers) | +10 |
| File in churn hotspot (top 10) | +10 |
| Theoretical only (no reproduction path) | -20 |
| Covered by existing tests | -15 |
| Rarely-executed code path | -10 |
| Intentional author choice (comment/commit msg) | -15 |
| Adversarial CRITICAL source | = 100 (override) |

**Output format:**
```
## Confidence Re-Scorer Report

### Dispositions

| ID | Original Severity | Confidence | Disposition | Rationale |
|----|------------------|------------|-------------|-----------|
| R-1 | MUST-FIX | 92 | KEEP | CQ6 violation + 47 callers |
| R-2 | RECOMMENDED | 28 | BACKLOG [below-threshold] | Theoretical, covered by tests |
| ADV-1 | MUST-FIX [CROSS:gemini] | 100 | KEEP (CRITICAL bypass) | Adversarial CRITICAL |
| R-5 | NIT | 18 | BACKLOG [low-confidence] | Style preference, no impact |

### Summary

Kept: N | Backlogged: M | Total: N+M
```

**Calibration examples:**
- `Confidence: 92` — R-1 MUST-FIX: findMany without limit. CQ6 critical gate (+25), 47 callers in codebase (+10), GET endpoint accessible to all users (+15), hotspot file (+10). Clear production OOM risk.
- `Confidence: 28` — R-4 RECOMMENDED: sequential await in loop. Theoretical perf concern (-20), loop is over a fixed 3-element config array (-10), not user-facing (-0). Below threshold → backlog.
- `Confidence: 100` — ADV-1 CRITICAL from Gemini: race condition in auth token refresh. Adversarial CRITICAL override. Bypasses scoring entirely.

**Degraded mode (CodeSift unavailable):** Skip reference count and hotspot rank factors (score them as 0 impact). All other scoring factors work from the finding data alone (no CodeSift dependency). Note "CodeSift unavailable — reference count and hotspot factors not applied" in report.

**What You Must NOT Do:**
- Do not discard any finding — all go to either report or backlog
- Do not override adversarial CRITICAL bypass (confidence = 100 is mandatory)
- Do not assign confidence without stating the contributing factors
- Do not use the scoring factors as a strict formula — they are guidelines, not arithmetic

---

## Shared Include: fix-loop.md

New file at `shared/includes/fix-loop.md`. Extracted from review Phase 4 + build Phase 4, deduplicated.

```markdown
# Fix Loop Protocol

> Shared include — apply code fixes from review/audit findings with verification.

## Input

The calling skill provides:
- FINDINGS: list of findings to fix (ID, severity, file, description, suggested fix)
- SCOPE_FENCE: allowed files (from triage or plan)
- MODE: determines which findings to apply

## Execution Strategy

| Condition | Strategy |
|-----------|----------|
| <3 fixes OR fixes share files | Sequential (severity order) |
| 3+ fixes on independent files | Parallel (up to 3 agents per env-compat.md) |

Before choosing parallel: verify target files do not import each other.

## Fix Loop

1. Apply each fix within the scope fence
2. Write any required tests (complete, runnable — not stubs)
3. Run verification: detect project test runner, execute full suite
4. If tests fail: check for flaky tests, then fix and repeat
5. If tests pass: run Execute Verification Checklist

## Execute Verification Checklist

[Y/N]  SCOPE: No files modified outside scope fence
[Y/N]  SCOPE: No new features beyond what the fix requires
[Y/N]  TESTS: Full test suite green
[Y/N]  LIMITS: All files within size limits (production ≤300L, test ≤400L)
[Y/N]  CQ: Self-eval on each modified production file
[Y/N]  Q: Self-eval on each modified/created test file
[Y/N]  NO SCOPE CREEP: Only report fixes applied, nothing extra

Any failure must be addressed before committing.

## Commit

git add [specific files]
git commit -m "<skill>-fix: [brief description]"

If interactive environment: confirm before committing.
If non-interactive (Codex App, Cursor): commit automatically, do NOT push.

## High-Risk Fix Policy

For fixes touching DB migrations, security/auth, API contracts, or payment/money:
apply one at a time, run tests after each. If a fix breaks tests, revert and report as [!].
```

---

## Bug Fixes Summary

| ID | Bug | Fix in spec |
|----|-----|-------------|
| B1 | knowledge-prime/curate: STOP covers all but items 6-7 are degraded-ok | Split checklist into CORE (STOP) and OPTIONAL (degraded) sections |
| B2 | cross-provider-review.md missing from file loading | Added to conditional files (always loaded — adversarial runs at all tiers) |
| B3 | CQ Auditor missing PROJECT_CONTEXT → CQ8 false positives | Added to CQ Auditor "What You Receive" as item 5 |
| B4 | Adversarial CRITICAL passable through confidence gate | CRITICAL bypass: confidence = 100, never gated |
| B5 | staged + fix creates ambiguous commit | Stash-based separation: stash unstaged → fix → commit fix → unstash |
| B6 | Empty diff (0 files) falls through tier logic | New row: 0 files → print message → STOP |
| B7 | Binary files not handled in tier calculation | Exclude from line count, note in report |
| B8 | `new` scope assumes `main` branch | Detect default branch via `git symbolic-ref refs/remotes/origin/HEAD` |
| B9 | Merge commit → huge diff | Detect with `git rev-list --merges`, warn + offer `--first-parent` |
| B10 | Batch TIER 3 "needs dedicated zuvo:review" recursive dead-end | Run full review inline (sequential agents) |
| B11 | `status` 100-commit hard limit undocumented | Add `--depth N` parameter, default 100 |
| B12 | Hotspot factor unusable for TIER 1 | Explicitly score 0 for TIER 0-1 |

---

## Acceptance Criteria

1. SKILL.md is ≤600 lines and loads ≤16K tokens at TIER 0
2. 4 agent files exist in `skills/review/agents/` with frontmatter, tool discovery, output templates, calibration examples, and "What You Must NOT Do"
3. No internal Adversarial Auditor agent — adversarial is bash script only
4. `adversarial-review.sh` runs at all tiers (TIER 0 through TIER 3) with all available providers
5. `cq-patterns.md` is conditional (TIER 2+), `cq-patterns-core.md` loads at TIER 1
6. When CodeSift is available: pre-compute runs in Phase 0.5 (mandatory TIER 1+, optional TIER 0), results passed to agents as PRECOMPUTED_DATA. When CodeSift unavailable: agents use degraded mode (Read/Grep fallback)
7. CQ Auditor receives PROJECT_CONTEXT as input item 5. When PROJECT_CONTEXT includes a global exception filter (e.g., `AllExceptionsFilter` in NestJS `main.ts`), CQ8 on non-critical services is scored N/A with justification referencing the global handler — not scored 0
8. Adversarial CRITICAL findings bypass confidence gate (effective confidence = 100)
9. All findings (including 0-25 confidence) persist to `memory/backlog.md` with appropriate tags
10. Empty diff, binary-only diff, and merge commits are handled with explicit messages
11. `auto-fix` is a parseable argument in the mode table
12. Reports saved to `memory/reviews/` at TIER 1+
13. QUESTIONS FOR AUTHOR appears at position 4 in report (before FINDINGS)
14. `new` scope detects default branch instead of hardcoding `main`
15. `shared/includes/fix-loop.md` exists and is referenced by review Phase 4
16. `staged` + `fix` uses stash-based separation to avoid ambiguous commits
17. Batch mode TIER 3 runs full review inline instead of recursive redirect
18. `status --depth N` is supported with configurable commit count
19. NIT findings are visually subordinate (collapsed summary block)
20. QUALITY WINS has specification (max 3, criteria defined)
21. Merged banner: single combined header replaces 4 separate blocks
22. Stack-specific rules loaded at TIER 2+ based on detected stack
23. Test coverage delta detection at TIER 2+ using CodeSift pre-computed test references
24. Self-review detected → adversarial escalates to `--all-providers`
25. `severity-vocabulary.md` has footnote clarifying that existing "adversarial loop" row covers bash script findings within review, with D7 bypass note
26. All 4 agent prompts pass quality bar: workflow steps (not categories), CodeSift guidance, degraded mode, evidence requirements

## Out of Scope

- Changes to `adversarial-review.sh` script behavior or provider logic (the script already supports `--json`, `--mode code`, `--files`, auto-provider-detection, and multi-provider parallel execution — verified in current v1.3.33+). The `--all-providers` flag for self-review escalation (F5) is the ONE exception: if not already supported, add it as a minimal script change (pass-through, no logic change — the script already runs all available providers by default)
- Changes to `ship` or `pentest` skill output parsing (backward-compatible — review output format unchanged for MUST-FIX/RECOMMENDED/NIT)
- Changes to `build` skill to use `fix-loop.md` (separate task — `build` continues with its inline loop until explicitly migrated)
- Creating new stack-specific rules files (uses existing `rules/*.md`)
- Backlog skill changes (backlog format unchanged — just more entries)
- Run logger changes (format unchanged)

## Open Questions

None — all questions resolved during Phase 2 dialogue.
