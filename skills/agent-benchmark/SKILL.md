---
name: agent-benchmark
description: "Self-benchmark: YOU write the code, adversarial reviews it (multi-provider), you fix, you write tests, adversarial reviews tests, you fix. Measures YOUR quality as an agent. Run in different models (Opus, Sonnet, Haiku) and compare results."
---

# zuvo:agent-benchmark — Self-Benchmark

You are the subject of this benchmark. YOU write the code and tests. Adversarial review (multi-provider) critiques your work between rounds. You fix based on findings.

Run this skill in different models (Opus, Sonnet, Haiku) to compare agent quality.

## Argument Parsing

| Flag | Effect |
|------|--------|
| `--quick` | Skip adversarial rounds (R1 code + R3 tests only, no fixes) |
| `--no-tests` | Skip test rounds (R1 + R2 only) |
| `--dry-run` | Print what would happen, don't execute |
| _(no flags)_ | Full 4-round benchmark with adversarial |

## Mandatory File Loading

Read these files before starting:

```
CORE FILES LOADED:
  1. ../../shared/includes/benchmark-corpus/task-code.md    -- READ/MISSING
  2. ../../shared/includes/benchmark-corpus/task-tests.md   -- READ/MISSING
  3. ../../shared/includes/run-logger.md                    -- READ/MISSING
```

If any file is missing, stop.

---

## Setup

1. Detect current model: check `$CLAUDE_MODEL` or infer from context. Record as `agent_model`.

2. Create output directory:
   ```bash
   RUN_ID="agent-bm-$(date -u +%Y%m%dT%H%M%SZ)"
   OUT_DIR="audit-results/${RUN_ID}"
   mkdir -p "$OUT_DIR"
   ```

3. Find adversarial-review.sh:
   - `scripts/adversarial-review.sh` (if in zuvo-plugin repo)
   - `~/.codex/scripts/adversarial-review.sh` (Codex install)
   - `~/.cursor/scripts/adversarial-review.sh` (Cursor install)
   - `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh` (Claude Code)

4. Record start time.

---

## Round 1 — Write Code

Read `../../shared/includes/benchmark-corpus/task-code.md`. This is your task.

**Write the two files yourself.** Do NOT dispatch to external providers. YOU are the agent being tested.

Write each file using the Write tool:
- `$OUT_DIR/r1-OrderService.ts`
- `$OUT_DIR/r1-useSearchProducts.ts`

Follow the spec exactly. Do your best work — this is measuring YOUR quality.

Record R1 time: `r1_time_s = end - start`.

Print:
```
── Round 1: Code ──
  r1-OrderService.ts — written (N lines)
  r1-useSearchProducts.ts — written (N lines)
  Time: Xs
```

---

## Round 2 — Adversarial Review + Fix

Run adversarial-review.sh on your R1 files. **Use all available providers** (default multi-provider mode):

```bash
adversarial-review.sh --files "$OUT_DIR/r1-OrderService.ts $OUT_DIR/r1-useSearchProducts.ts" --json
```

Read the findings. Print summary:
```
── Round 2: Adversarial Review ──
  Providers: [list of adversarial reviewers]
  Findings: N critical, M warning, K info
```

Now **fix your code** based on the adversarial findings. **Do NOT edit R1 files — they are the baseline.** Write corrected code as NEW files:
- `$OUT_DIR/r2-OrderService.ts` (new file — corrected version of r1)
- `$OUT_DIR/r2-useSearchProducts.ts` (new file — corrected version of r1)

Save adversarial findings:
- `$OUT_DIR/r2-adversarial-findings.txt`

If adversarial found zero issues, copy R1 files as R2:
```bash
cp $OUT_DIR/r1-OrderService.ts $OUT_DIR/r2-OrderService.ts
cp $OUT_DIR/r1-useSearchProducts.ts $OUT_DIR/r2-useSearchProducts.ts
```

Record R2 time (review + fix).

Print:
```
  Fix applied: [brief description of what you changed]
  Time: Xs
```

---

## Round 3 — Write Tests

Read `../../shared/includes/benchmark-corpus/task-tests.md`.

Replace `{{ROUND_1_CODE}}` with the contents of your R2 files (the fixed versions).

**Write tests yourself** for both files:
- `$OUT_DIR/r3-OrderService.test.ts`
- `$OUT_DIR/r3-useSearchProducts.test.ts`

Record R3 time.

Print:
```
── Round 3: Tests ──
  r3-OrderService.test.ts — written (N lines, M test cases)
  r3-useSearchProducts.test.ts — written (N lines, M test cases)
  Time: Xs
```

---

## Round 4 — Adversarial Review on Tests + Fix

Run adversarial-review.sh on your test files. **Multi-provider mode**:

```bash
adversarial-review.sh --files "$OUT_DIR/r3-OrderService.test.ts $OUT_DIR/r3-useSearchProducts.test.ts" --json --mode test
```

Read findings. **Do NOT edit R3 files — they are the baseline.** Read R3, apply fixes, and write corrected tests as NEW files:
- `$OUT_DIR/r4-OrderService.test.ts` (new file — corrected version of r3)
- `$OUT_DIR/r4-useSearchProducts.test.ts` (new file — corrected version of r3)

**Critical: R3 and R4 must be different files showing before/after.** If you edit R3 directly, the benchmark loses the ability to compare pre/post adversarial quality.

Save findings:
- `$OUT_DIR/r4-adversarial-findings.txt`

Record R4 time.

Print:
```
── Round 4: Adversarial on Tests ──
  Findings: N critical, M warning, K info
  Fix applied: [brief description]
  Time: Xs
```

---

## Output — Summary + Artifacts

### File Inventory

Print:
```
── Artifacts: $OUT_DIR/ ──
  r1-OrderService.ts              (N lines) — original code
  r1-useSearchProducts.ts         (N lines) — original code
  r2-OrderService.ts              (N lines) — after adversarial fix
  r2-useSearchProducts.ts         (N lines) — after adversarial fix
  r2-adversarial-findings.txt     — adversarial review output
  r3-OrderService.test.ts         (N lines, M tests) — original tests
  r3-useSearchProducts.test.ts    (N lines, M tests) — original tests
  r4-OrderService.test.ts         (N lines, M tests) — after adversarial fix
  r4-useSearchProducts.test.ts    (N lines, M tests) — after adversarial fix
  r4-adversarial-findings.txt     — adversarial review output
  agent-benchmark.json            — machine-readable results
```

### JSON Report

Write `$OUT_DIR/agent-benchmark.json`:

```json
{
  "version": "1.0",
  "skill": "agent-benchmark",
  "run_id": "<run_id>",
  "timestamp": "<ISO-8601>",
  "agent_model": "<model name>",
  "project": "<project path>",
  "r1_time_s": 0,
  "r2_time_s": 0,
  "r3_time_s": 0,
  "r4_time_s": 0,
  "total_time_s": 0,
  "r2_adversarial": {
    "providers": ["gemini", "codex-fast"],
    "critical": 0,
    "warning": 0,
    "info": 0
  },
  "r4_adversarial": {
    "providers": ["gemini", "codex-fast"],
    "critical": 0,
    "warning": 0,
    "info": 0
  },
  "files": {
    "r1_code_lines": 0,
    "r2_code_lines": 0,
    "r3_test_lines": 0,
    "r3_test_count": 0,
    "r4_test_lines": 0,
    "r4_test_count": 0
  }
}
```

### Completion Block

```
AGENT BENCHMARK COMPLETE
Model:      [agent_model]
Run ID:     [run_id]
Artifacts:  [OUT_DIR]/

Timing:
  R1 Code:           Xs
  R2 Adversarial+Fix: Xs
  R3 Tests:          Xs
  R4 Adversarial+Fix: Xs
  Total:             Xs

Adversarial Impact:
  Code:  N findings → [what changed]
  Tests: N findings → [what changed]

Files: 8 artifacts + 2 findings + 1 JSON = 11 files
```

### Run Log

```
Run: <ISO-8601-Z>	agent-benchmark	<project>	-	-	PASS	<agent_model>	4-round	<notes>	<BRANCH>	<SHA7>
```

After printing, append to the log file path resolved per `../../shared/includes/run-logger.md`.
