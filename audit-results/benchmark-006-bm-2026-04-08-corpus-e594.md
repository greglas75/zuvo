# Benchmark Report — bm-2026-04-08-corpus-e594

**Mode:** corpus | **Task:** OrderService + useSearchProducts (fixed corpus)
**Date:** 2026-04-07T18:40:13Z | **Project:** zuvo-plugin
**Options:** tests=true, adversarial=true, static=false

## Results

| Rank | Provider      | Quality | Code | Tests | Time  | Cost   | Adv Delta | Bias | Status |
|------|--------------|---------|------|-------|-------|--------|-----------|------|--------|
| 1    | gemini        | 88      | 17   | 18    | 58s   | $0.000 | -2        | +3   | scored |
| 2    | claude        | 88      | 18   | 17    | 70s   | $0.034 | -2        | 0    | scored |
| 3    | codex-fast    | 85      | 19   | 15    | 158s  | $0.054 | -1        | -1   | scored |
| 4    | cursor-agent  | 65      | 15   | 11    | 184s  | $0.000 | -1        | +2   | scored |

### Self-eval bias (positive = overconfident)

gemini +3, cursor-agent +2, claude 0, codex-fast -1

## Code Scorecards (Round 1)

| Provider      | Complete | Accuracy | Action | No Halluc | Composite |
|--------------|----------|----------|--------|-----------|-----------|
| codex-fast    | 5        | 5        | 5      | 4         | 19        |
| claude        | 5        | 4        | 5      | 4         | 18        |
| gemini        | 5        | 4        | 4      | 4         | 17        |
| cursor-agent  | 4        | 4        | 4      | 3         | 15        |

## Test Scorecards (Round 3)

| Provider      | Complete | Accuracy | Action | No Halluc | Composite |
|--------------|----------|----------|--------|-----------|-----------|
| gemini        | 4        | 4        | 5      | 5         | 18        |
| claude        | 5        | 4        | 4      | 4         | 17        |
| codex-fast    | 4        | 4        | 4      | 3         | 15        |
| cursor-agent  | 4        | 3        | 2      | 2         | 11        |

## Adversarial Cross-Review Summary

| Provider      | CRITICALs | WARNINGs | Delta |
|--------------|-----------|----------|-------|
| claude        | 10        | 21       | -2    |
| gemini        | 10        | 21       | -2    |
| codex-fast    | 7         | 21       | -1    |
| cursor-agent  | 7         | 22       | -1    |

Key adversarial findings (shared across providers):
- Race condition in updateStatus: concurrent requests can force invalid state paths
- Numeric validation gaps: NaN/Infinity accepted in quantity and unitPrice
- Cache key injection: JSON.stringify(filters) without sanitization
- Unbounded Redis KEYS pattern scan in cache invalidation

## Key Observations

- **gemini** leads on speed (58s) and test quality (18/20) despite weaker code accuracy. Zero cost (free tier). Overconfident self-eval (+3 bias).
- **claude** matches gemini's overall quality (88) with stronger code (18 vs 17) but slightly weaker tests (17 vs 18). Best-calibrated self-eval (0 bias).
- **codex-fast** produces the highest raw code quality (19/20) but tests lag at 15/20 due to hallucinated Redis method names. Slowest of the trio at 158s.
- **cursor-agent** trails significantly due to test quality issues (hallucinated service imports, invented method names). 184s is the slowest provider.

## Meta

- **Judge model:** claude-sonnet-4-6 (opposite-model rule: skill runs on opus)
- **Presentation order:** gemini, codex-fast, cursor-agent, claude (randomized)
- **Judge input truncated:** yes (codex-fast response exceeded 20K char limit)
- **Quality formula:** round((code_composite + test_composite) * 2.5)
