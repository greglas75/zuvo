---
name: backlog
description: Known improvements and ideas deferred from active work
type: project
---

## benchmark skill

### Round 4: adversarial review on tests

**What:** After Round 3 (providers write tests), add adversarial cross-review on the test files — each provider critiques other providers' tests. Author can fix. Meta-judge re-scores after adversarial. Adds `test_adversarial_delta` field to scorecards.

**Why:** User requested (2026-04-07). Mirrors Round 1 adversarial on code. Answers: does adversarial review improve test quality as much as it improves code quality? Are tests easier or harder to improve via cross-review?

**Scope:** New `--with-test-adversarial` flag (separate from `--with-adversarial` which applies to code only), or extend `--with-adversarial` to cover both rounds. Add `test_adversarial_delta` to benchmark-output-schema.md, leaderboard, and scorecards. New Round 4 phase in SKILL.md corpus mode extension.

### Token counting — actual vs estimated

**What:** Most providers return estimated token counts (`wc -w × 1.3`, flagged `~estimated`). Only Gemini API returns actual token counts via `usageMetadata`. If/when other CLIs expose token usage, wire it in.

**Why:** Cost calculations are approximate for CLI-based providers (Codex, Gemini CLI, Cursor, Claude CLI).
