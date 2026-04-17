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

## 2026-04-17 zuvo:leads Task 1 (schema include)

- [ ] B-leads-T1-test-scope: `scripts/tests/leads-schema-structure.sh` greps are unscoped (not anchored to Data Model table range). If an enum value is removed from a field definition but still appears in prose elsewhere, the test passes false-green. Fix: use awk range `/^## Contact Record Fields/,/^## /` to extract the table, then grep within it. Source: adversarial task-1 round 2 WARNING.
- [ ] B-leads-T1-jsonl-ext: `.checkpoint-<slug>.json` stores JSONL but uses `.json` extension. Tooling that `JSON.parse`s the whole file will fail. Fix: rename convention to `.checkpoint-<slug>.jsonl` in `lead-output-schema.md` before v1 ships. Source: adversarial task-1 round 2 WARNING.
- [ ] B-leads-T1-casefold-perf: Casefold normalization via `python3 -c` subprocess spawn is correct but slow at scale (~10-50ms per record × 500 records = 5-25s). Fix: batch normalization in a single Python invocation (read records on stdin, emit keyed output). Source: adversarial task-1 round 2 WARNING.
