# Adversarial Loop — Document Artifacts

> Referenced by: /brainstorm, /plan, /code-audit, /test-audit, /security-audit, /api-audit, /architecture, /seo-audit, /docs, /ship, and all audit skills that produce scored reports.
> Companion to: `adversarial-loop.md` (code diffs). Load both when a skill produces code AND documents.
> **MANDATORY** — if referenced by a skill, this loop runs. The agent does not decide whether to skip it.

## Purpose

After a skill produces a document artifact (design spec, implementation plan, audit report), consult a DIFFERENT AI model to catch blind spots before presenting to the user. Same concept as code adversarial review, adapted for prose documents.

## When to Run

| Artifact type | Trigger | Mode flag |
|---------------|---------|-----------|
| Design spec (brainstorm) | **Always** | `--mode spec` |
| Implementation plan (plan) | **Always** | `--mode plan` |
| Audit report (code-audit, test-audit, security-audit, etc.) | Score < 75% OR any FAIL gate | `--mode audit` |
| Test audit report (test-audit Q1-Q19 output) | **Always** | `--mode tests` |
| Changelog (ship, release-docs) | **Always** | `--mode spec` (reuse spec mode) |

**Skip when:**
- Artifact below minimum size (200 words for spec, 3 tasks for plan, 500 words for audit/tests)
- No provider available (note in output, proceed normally)
- Config-only or documentation-only changes with no new artifact

## Sequencing Rule

Cross-model validation is the **final gate before user presentation**. Internal agent reviewers must converge first:

```
Skill produces artifact
  -> Internal reviewer (spec-reviewer, plan-reviewer, etc.) iterates until converged
  -> Cross-model validation (this protocol) — final skeptic
  -> Present to user
```

Do NOT run cross-model in parallel with internal reviewers. The internal reviewer's corrections must be in the artifact before cross-model sees it.

## Execution

### Step 1: Check minimum size

```
IF mode == spec AND word_count < 200: skip
IF mode == plan AND task_count < 3: skip
IF mode == audit|tests AND word_count < 500: skip
```

The script (`adversarial-review.sh`) handles this internally — the calling skill does not need to count.

### Step 2: Dispatch

Run the script in a **single foreground Bash call**. The script auto-detects all available providers, runs them in parallel, and returns merged results. Do NOT manage providers yourself.

```bash
adversarial-review --json --mode {MODE} --files "{ARTIFACT_PATH}"
```

**IMPORTANT:** Run as a foreground Bash call. Wait for the complete output before proceeding to Step 3. Do NOT read results early or use background execution.

**If `adversarial-review` is not in PATH:** try `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh` as fallback.

**If the script exits non-zero with empty output:** no provider was available. Note `adversarial review: skipped (no provider available)` and proceed normally.

### Step 3: Apply fix policy

Fix policy depends on artifact type:

| Artifact | CRITICAL finding | WARNING finding | INFO finding |
|----------|-----------------|-----------------|--------------|
| **Spec** | Re-enter skill iteration loop (max 3 total). Fix before user approval. | Append to Open Questions section in spec. | Note in output, no action. |
| **Plan** | Re-enter skill iteration loop (max 3 total). Fix before user approval. | Append as note to affected task. | Note in output, no action. |
| **Audit report** | Block delivery. Re-run the failed dimension of the audit. | Append to Known Gaps section in report. | Note in output, no action. |

### Step 4: Present to user

Same presentation rules as code adversarial loop:

- Unresolved CRITICAL → do NOT say "complete". Say "done, but adversarial review found unresolved critical issue(s)."
- Unresolved WARNING → note as known concern in delivery.
- All clear → proceed normally.

## Severity Rubric Per Mode

Each mode has its own definition of CRITICAL/WARNING/INFO. The adversarial-review.sh script embeds these in the provider prompt via the FOCUS block.

### spec mode
- **CRITICAL:** Hallucinated capability, internal contradiction that changes behavior
- **WARNING:** Missing edge case, vague acceptance criteria
- **INFO:** Style preference, alternative wording

### plan mode
- **CRITICAL:** Missing dependency that will fail execution, task requires nonexistent file
- **WARNING:** Task too large, questionable ordering
- **INFO:** Alternative decomposition preference

### audit mode
- **CRITICAL:** FAIL gate not reflected in verdict, finding severity mismatch
- **WARNING:** Skipped check rationalized as N/A
- **INFO:** Remediation could be more specific

### tests mode
- **CRITICAL:** Passing Q-score contradicted by evidence
- **WARNING:** Coverage theater not flagged
- **INFO:** Flakiness signal missed

## Limits

- **Max 2 cross-model runs per skill invocation** (matching code adversarial loop). Second run only triggered by CRITICAL findings in first run.
- **Provider dispatch:** 2 random providers per run (matching code adversarial loop).
- **Soft fail on bad JSON:** Same as code loop — strip fences, attempt text extraction, fall back to `[RAW]` tag.

## Graceful Degradation

If no provider is available: output `Adversarial review: skipped (no provider available)` and proceed. Do NOT block skill completion.

If provider returns empty: output `Adversarial review: skipped (provider returned empty)` and proceed with other provider's results.
