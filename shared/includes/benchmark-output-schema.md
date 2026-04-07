# Benchmark Output Schema

This document defines the JSON schema for the **final benchmark report** written by the `zuvo:benchmark` skill to `audit-results/benchmark-NNN-<run_id>.json`.

> **Note:** `scripts/benchmark.sh` produces an intermediate raw JSON (`providers_raw` array) that does NOT conform to this schema. The skill orchestrator (SKILL.md) reads the raw output and assembles the final schema-conformant document including leaderboard, scorecards, and meta-judge fields.

---

## Top-Level Fields

| Field | Type | Description |
|-------|------|-------------|
| `version` | `"2.0"` | Schema version. Always `"2.0"` for this format. |
| `skill` | `string` | Skill name that produced this run (e.g. `"benchmark"`). |
| `run_id` | `string` | Unique run identifier (UUID v4 or timestamp slug). |
| `timestamp` | `string` | ISO 8601 datetime of run start. |
| `project` | `string` | Project root path or name. |
| `mode` | `"default" \| "corpus"` | Run mode. `"default"` uses a user-provided task; `"corpus"` uses the fixed benchmark corpus tasks. |

---

## Task Fields

| Field | Type | Description |
|-------|------|-------------|
| `task_source` | `"corpus" \| "user" \| "diff" \| "files"` | Source of the task. `"corpus"` = built-in corpus tasks, `"user"` = `--prompt` text, `"diff"` = git diff, `"files"` = `--files` input. |
| `task_hash` | `string` | Full 64-char SHA-256 hex of the task prompt. First 8 chars are used as display label only. (Examples in this document show truncated 8-char forms for readability.) |
| `task_snapshot` | `string` | First 30,000 characters of the task prompt. Truncated if longer (`task_snapshot_truncated: true`). **Warning:** If the task contains secrets or PII, those will be stored here. Use `--no-snapshot` flag to suppress storage. |

---

## Options

```json
"options": {
  "with_tests": true,
  "with_adversarial": true,
  "with_test_adversarial": false,
  "with_static_checks": false
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `with_tests` | `boolean` | `false` | Whether a Round 3 (write tests) task was run after Round 1. |
| `with_adversarial` | `boolean` | `false` | Whether adversarial cross-review was run on Round 1 code. |
| `with_test_adversarial` | `boolean` | `false` | Whether adversarial cross-review was run on Round 3 tests. |
| `with_static_checks` | `boolean` | `false` | Whether TypeScript compile + jest was run on provider output. |

---

## Provider Summary Fields

| Field | Type | Description |
|-------|------|-------------|
| `providers_attempted` | `string[]` | List of all provider IDs attempted (e.g. `["claude", "codex-fast", "gemini"]`). |
| `providers_succeeded` | `string[]` | Subset that returned valid output within timeout. |
| `scored` | `string[]` | Subset that were scored by the judge (may exclude providers that failed or timed out). |

---

## Leaderboard

Array of ranked provider results. Sorted by `quality` (descending), then `time_s` (ascending), then `provider` (alphabetical) for full ties.

**Quality formula:**
- Both rounds: `quality = round((code_composite + test_composite) * 2.5)` → range 0–100
- Code only: `quality = round(code_composite * 5)` → range 0–100
- Neither scored: `quality = null`

```json
"leaderboard": [
  {
    "rank": 1,
    "provider": "claude",
    "quality": 87,
    "code_score": 18,
    "test_score": 15,
    "time_s": 42.1,
    "cost_usd": 0.031,
    "compile_ok": true,
    "tests_pass": true,
    "self_eval_bias": 1.2,
    "adversarial_delta": -3,
    "status": "scored"
  }
]
```

| Field | Type | Description |
|-------|------|-------------|
| `rank` | `integer` | 1-based rank position. |
| `provider` | `string` | Provider identifier. |
| `quality` | `number` | Overall quality score (0–100). Composite of code and test scores. |
| `code_score` | `number` | Code quality score (0–20). Sum of CQ dimension scores. |
| `test_score` | `number \| null` | Test quality score (0–20). `null` if `with_tests` is false. |
| `time_s` | `number` | Wall-clock seconds from task dispatch to response received. |
| `cost_usd` | `number \| null` | Estimated cost in USD. `null` if not reported by provider. |
| `compile_ok` | `boolean \| null` | Whether TypeScript compiled without errors. `null` if `with_static_checks` is false. |
| `tests_pass` | `boolean \| null` | Whether written tests passed. `null` if not applicable. |
| `self_eval_bias` | `number \| null` | Difference between provider's self-reported score and judge score. Positive = overconfident. `null` if provider did not emit a parseable `SELF_EVAL_SUMMARY` block. |
| `adversarial_delta` | `number \| null` | Score change after adversarial cross-review. Negative = score reduced by challenge. `null` if `with_adversarial` is false. |
| `status` | `string` | One of: `"scored"`, `"timeout"`, `"error"`, `"skipped"`. |

---

## Scorecards

Detailed per-dimension scores for each provider. Keys are provider identifiers.

```json
"scorecards": {
  "claude": {
    "code_completeness": 5,
    "code_accuracy": 4,
    "code_actionability": 5,
    "code_no_hallucinations": 4,
    "code_composite": 18,
    "test_completeness": 4,
    "test_accuracy": 4,
    "test_actionability": 4,
    "test_no_hallucinations": 3,
    "test_composite": 15,
    "adversarial_delta": -3,
    "self_eval_bias": 1.2,
    "response_excerpt": "OrderService.ts\n\n@Injectable()\nexport class OrderService {\n  constructor(\n    private readonly prisma: PrismaService,\n..."
  }
}
```

### Code Scorecard Dimensions

| Field | Type | Range | Description |
|-------|------|-------|-------------|
| `code_completeness` | `number` | 0–5 | All required methods, fields, and behaviors implemented. |
| `code_accuracy` | `number` | 0–5 | Logic is correct, state machines valid, edge cases handled. |
| `code_actionability` | `number` | 0–5 | Code is production-ready; no stubs, TODOs, or placeholder logic. |
| `code_no_hallucinations` | `number` | 0–5 | No invented APIs, non-existent methods, or fabricated behavior. |
| `code_composite` | `number` | 0–20 | Sum of the four code dimensions. |

### Test Scorecard Dimensions

| Field | Type | Range | Description |
|-------|------|-------|-------------|
| `test_completeness` | `number \| null` | 0–5 | Coverage of happy paths, error paths, edge cases. |
| `test_accuracy` | `number \| null` | 0–5 | Assertions are meaningful; mocks are correctly set up. |
| `test_actionability` | `number \| null` | 0–5 | Tests are runnable and follow project conventions. |
| `test_no_hallucinations` | `number \| null` | 0–5 | No invented test utilities, non-existent matchers, or fake APIs. |
| `test_composite` | `number \| null` | 0–20 | Sum of the four test dimensions. `null` if `with_tests` is false. |

### Adversarial and Bias Fields

| Field | Type | Description |
|-------|------|-------------|
| `adversarial_delta` | `number \| null` | Score change on code from adversarial review (Round 1 → Round 1 fixed). Negative = weaknesses exposed. `null` if `with_adversarial` is false. |
| `test_adversarial_delta` | `number \| null` | Score change on tests from adversarial review (Round 3 → Round 3 fixed). Negative = weaknesses exposed. `null` if `with_test_adversarial` is false. |
| `self_eval_bias` | `number \| null` | Provider self-score minus judge score. `null` if no parseable `SELF_EVAL_SUMMARY` block found. |
| `response_excerpt` | `string` | First 500 characters of provider's code response for audit purposes. |

---

## Meta Fields

| Field | Type | Description |
|-------|------|-------------|
| `meta_judge_model` | `string` | Model used as judge (e.g. `"claude-opus-4-6"`). |
| `judge_presentation_order` | `string[]` | Order in which provider responses were shown to the judge (randomized to reduce positional bias). |
| `judge_input_truncated` | `boolean` | Whether any provider response was truncated before being sent to the judge. |

---

## Example: Default Mode

```json
{
  "version": "2.0",
  "skill": "benchmark",
  "run_id": "bm-2026-04-07-a3f1",
  "timestamp": "2026-04-07T14:32:00Z",
  "project": "/Users/dev/my-app",
  "mode": "default",
  "task_source": "user",
  "task_hash": "c4f9a2b1",
  "task_snapshot": "Write a NestJS controller for user authentication...",
  "options": {
    "with_tests": false,
    "with_adversarial": false,
    "with_static_checks": false
  },
  "providers_attempted": ["claude", "codex-fast"],
  "providers_succeeded": ["claude", "codex-fast"],
  "scored": ["claude", "codex-fast"],
  "leaderboard": [
    {
      "rank": 1,
      "provider": "claude",
      "quality": 82,
      "code_score": 17,
      "test_score": null,
      "time_s": 38.4,
      "cost_usd": 0.024,
      "compile_ok": null,
      "tests_pass": null,
      "self_eval_bias": 0.5,
      "adversarial_delta": null,
      "status": "scored"
    },
    {
      "rank": 2,
      "provider": "codex-fast",
      "quality": 71,
      "code_score": 14,
      "test_score": null,
      "time_s": 22.1,
      "cost_usd": 0.008,
      "compile_ok": null,
      "tests_pass": null,
      "self_eval_bias": 2.1,
      "adversarial_delta": null,
      "status": "scored"
    }
  ],
  "scorecards": {
    "claude": {
      "code_completeness": 5,
      "code_accuracy": 4,
      "code_actionability": 4,
      "code_no_hallucinations": 4,
      "code_composite": 17,
      "test_completeness": null,
      "test_accuracy": null,
      "test_actionability": null,
      "test_no_hallucinations": null,
      "test_composite": null,
      "adversarial_delta": null,
      "self_eval_bias": 0.5,
      "response_excerpt": "@Controller('auth')\nexport class AuthController {\n  constructor(private readonly authService: AuthService) {}\n..."
    },
    "codex-fast": {
      "code_completeness": 4,
      "code_accuracy": 3,
      "code_actionability": 4,
      "code_no_hallucinations": 3,
      "code_composite": 14,
      "test_completeness": null,
      "test_accuracy": null,
      "test_actionability": null,
      "test_no_hallucinations": null,
      "test_composite": null,
      "adversarial_delta": null,
      "self_eval_bias": 2.1,
      "response_excerpt": "// AuthController\nimport { Controller, Post, Body } from '@nestjs/common';\n..."
    }
  },
  "meta_judge_model": "claude-opus-4-6",
  "judge_presentation_order": ["codex-fast", "claude"],
  "judge_input_truncated": false
}
```

---

## Example: Corpus Mode

```json
{
  "version": "2.0",
  "skill": "benchmark",
  "run_id": "bm-2026-04-07-corpus-9d2e",
  "timestamp": "2026-04-07T16:00:00Z",
  "project": "/Users/dev/my-app",
  "mode": "corpus",
  "task_source": "corpus",
  "task_hash": "a1b2c3d4",
  "task_snapshot": "# Benchmark Corpus Task — Write Production Code\n\nYou are participating in a benchmark...",
  "options": {
    "with_tests": true,
    "with_adversarial": true,
    "with_static_checks": true
  },
  "providers_attempted": ["claude", "codex-fast", "gemini", "cursor-agent"],
  "providers_succeeded": ["claude", "codex-fast", "gemini", "cursor-agent"],
  "scored": ["claude", "codex-fast", "gemini", "cursor-agent"],
  "leaderboard": [
    {
      "rank": 1,
      "provider": "claude",
      "quality": 87,
      "code_score": 18,
      "test_score": 15,
      "time_s": 91.2,
      "cost_usd": 0.071,
      "compile_ok": true,
      "tests_pass": true,
      "self_eval_bias": 1.2,
      "adversarial_delta": -3,
      "status": "scored"
    },
    {
      "rank": 2,
      "provider": "gemini",
      "quality": 79,
      "code_score": 16,
      "test_score": 13,
      "time_s": 64.8,
      "cost_usd": 0.019,
      "compile_ok": true,
      "tests_pass": false,
      "self_eval_bias": 3.0,
      "adversarial_delta": -5,
      "status": "scored"
    },
    {
      "rank": 3,
      "provider": "codex-fast",
      "quality": 68,
      "code_score": 14,
      "test_score": 11,
      "time_s": 31.5,
      "cost_usd": 0.012,
      "compile_ok": false,
      "tests_pass": false,
      "self_eval_bias": 4.5,
      "adversarial_delta": -6,
      "status": "scored"
    },
    {
      "rank": 4,
      "provider": "cursor-agent",
      "quality": 61,
      "code_score": 12,
      "test_score": 10,
      "time_s": 55.3,
      "cost_usd": null,
      "compile_ok": true,
      "tests_pass": false,
      "self_eval_bias": 2.8,
      "adversarial_delta": -2,
      "status": "scored"
    }
  ],
  "scorecards": {
    "claude": {
      "code_completeness": 5,
      "code_accuracy": 5,
      "code_actionability": 4,
      "code_no_hallucinations": 4,
      "code_composite": 18,
      "test_completeness": 4,
      "test_accuracy": 4,
      "test_actionability": 4,
      "test_no_hallucinations": 3,
      "test_composite": 15,
      "adversarial_delta": -3,
      "self_eval_bias": 1.2,
      "response_excerpt": "@Injectable()\nexport class OrderService {\n  constructor(\n    private readonly prisma: PrismaService,\n    private readonly redis: RedisService,\n..."
    },
    "gemini": {
      "code_completeness": 4,
      "code_accuracy": 4,
      "code_actionability": 4,
      "code_no_hallucinations": 4,
      "code_composite": 16,
      "test_completeness": 4,
      "test_accuracy": 3,
      "test_actionability": 3,
      "test_no_hallucinations": 3,
      "test_composite": 13,
      "adversarial_delta": -5,
      "self_eval_bias": 3.0,
      "response_excerpt": "// OrderService.ts\nimport { Injectable, NotFoundException } from '@nestjs/common';\n..."
    },
    "codex-fast": {
      "code_completeness": 4,
      "code_accuracy": 3,
      "code_actionability": 4,
      "code_no_hallucinations": 3,
      "code_composite": 14,
      "test_completeness": 3,
      "test_accuracy": 3,
      "test_actionability": 3,
      "test_no_hallucinations": 2,
      "test_composite": 11,
      "adversarial_delta": -6,
      "self_eval_bias": 4.5,
      "response_excerpt": "import { Injectable } from '@nestjs/common';\n// OrderService implementation\n..."
    },
    "cursor-agent": {
      "code_completeness": 3,
      "code_accuracy": 3,
      "code_actionability": 3,
      "code_no_hallucinations": 3,
      "code_composite": 12,
      "test_completeness": 3,
      "test_accuracy": 3,
      "test_actionability": 2,
      "test_no_hallucinations": 2,
      "test_composite": 10,
      "adversarial_delta": -2,
      "self_eval_bias": 2.8,
      "response_excerpt": "@Injectable()\nclass OrderService {\n  // CRUD operations for orders\n..."
    }
  },
  "meta_judge_model": "claude-opus-4-6",
  "judge_presentation_order": ["gemini", "cursor-agent", "codex-fast", "claude"],
  "judge_input_truncated": false
}
```
