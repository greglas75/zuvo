# Benchmark Report — bm-2026-04-08-corpus-61fa

**Date:** 2026-04-08T03:25:39Z  
**Mode:** corpus | **Task:** corpus tasks (OrderService + useSearchProducts)  
**Options:** tests=true adversarial=true test-adversarial=true static=false  
**Judge:** claude-opus-4-6 (opposite-model rule)

---

## Benchmark Results — bm-2026-04-08-corpus-61fa

Task: corpus tasks (OrderService.ts + useSearchProducts.ts) | Mode: corpus

| Rank | Provider     | Quality | Code | Tests | Time  | Cost    | Adv.Δ | Test Adv.Δ | Status |
|------|-------------|---------|------|-------|-------|---------|-------|------------|--------|
|  1   | cursor-agent |    88   |  16  |  19   |  455s |   —     |   +2  |     +1     | scored |
|  2   | gemini       |    80   |  18  |  14   |  274s |  $0.00  |    0  |     +2     | scored |
|  3   | claude       |    78   |  15  |  16   |  360s |  $0.034 |    0  |      0     | scored |
|  4   | codex-fast   |    65   |  14  |  12   |  648s |  $0.054 |   +1  |     -2     | scored |

Quality = round((code + tests) × 2.5). Code/Tests = composite 0–20.  
Adv.Δ = score change after adversarial code fix (positive = improved). Test Adv.Δ = score change after adversarial test fix.

---

## Self-Eval Bias (positive = overconfident)

| Provider     | Self-Reported (0-20) | Judge Code Score | Bias |
|-------------|---------------------|-----------------|------|
| cursor-agent |         18          |       16        |  +2  |
| gemini       |         20          |       18        |  +2  |
| claude       |         18          |       15        |  +3  |
| codex-fast   |         18          |       14        |  +4  |

All providers overconfident; codex-fast most overconfident (+4).

---

## Detailed Scorecards

### cursor-agent — Quality 88 (Rank 1)

| Dimension          | Code | Tests |
|-------------------|------|-------|
| completeness       |  4   |   4   |
| accuracy           |  4   |   5   |
| actionability      |  4   |   5   |
| no_hallucinations  |  4   |   5   |
| **composite**      | **16** | **19** |

Strengths: Exceptional test quality — cursor-agent wrote the best tests (19/20), particularly strong on accuracy and hallucination avoidance. Adversarial review improved both code and tests. Code is solid but missed one completeness point.

---

### gemini — Quality 80 (Rank 2)

| Dimension          | Code | Tests |
|-------------------|------|-------|
| completeness       |  5   |   4   |
| accuracy           |  4   |   3   |
| actionability      |  4   |   4   |
| no_hallucinations  |  5   |   3   |
| **composite**      | **18** | **14** |

Strengths: Best code quality (18/20), perfect completeness and no hallucinations. Adversarial review improved tests significantly (+2). Weakness: test accuracy and no-hallucinations in tests scored lower.

---

### claude — Quality 78 (Rank 3)

| Dimension          | Code | Tests |
|-------------------|------|-------|
| completeness       |  4   |   5   |
| accuracy           |  3   |   4   |
| actionability      |  4   |   4   |
| no_hallucinations  |  4   |   3   |
| **composite**      | **15** | **16** |

Note: Adversarial reviewer found zero issues in both code (R2) and tests (R4) — claude responded "nothing to fix" both times. Strongest test completeness (5/5). Code accuracy was the weak point.

---

### codex-fast — Quality 65 (Rank 4)

| Dimension          | Code | Tests |
|-------------------|------|-------|
| completeness       |  3   |   4   |
| accuracy           |  4   |   3   |
| actionability      |  3   |   3   |
| no_hallucinations  |  4   |   2   |
| **composite**      | **14** | **12** |

Adversarial code fix improved code (+1) but test adversarial review hurt tests (-2). Highest self-eval bias (+4) — most overconfident. Slowest provider (648s total, 210s on R4 fixes alone). Test no_hallucinations notably weak (2/5).

---

## Timing Breakdown (seconds)

| Provider     | R1 Code | R2 Fix | R3 Tests | R4 Fix | Total |
|-------------|---------|--------|---------|--------|-------|
| cursor-agent |   120   |   29   |   223   |   83   |  455  |
| gemini       |    65   |   34   |    86   |   89   |  274  |
| claude       |    70   |   30   |   234   |   26   |  360  |
| codex-fast   |   134   |  138   |   166   |  210   |  648  |

Gemini fastest overall (274s). Claude fastest for R1 code (70s). Codex-fast significantly slowest.

---

## Key Observations

1. **cursor-agent wins on tests**: Despite average code quality, cursor-agent produced the best tests by a large margin (19/20), pulling it to first place.
2. **gemini leads on code**: Highest code composite (18/20) with perfect completeness and no hallucinations in code.
3. **claude consistent but underwhelming**: Adversarial reviewers (both code and test rounds) found zero issues — suggesting either very conservative code or reviewers missing things. Still ranked 3rd.
4. **codex-fast struggles with tests**: Test no_hallucinations score of 2/5 is notably low — invented test utilities or matchers likely. Most overconfident self-evaluation.
5. **Adversarial impact**: Code adversarial review helped cursor-agent (+2) and codex-fast (+1). Test adversarial improved gemini (+2) and cursor-agent (+1), but hurt codex-fast (-2).

---

## Run Log

Run: 2026-04-08T03:45:00Z	benchmark	zuvo-plugin	-	-	PASS	4-providers	corpus	full-4-round corpus with adversarial+test-adversarial	main	534c9eb
