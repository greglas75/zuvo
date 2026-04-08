# Benchmark Report — bm-corpus-full

**Mode:** corpus | **Timestamp:** 2026-04-08T01:46:43Z | **Project:** zuvo-plugin

---

## Task

**Source:** Corpus (fixed benchmark tasks)

Write two production TypeScript files:
1. **OrderService.ts** — NestJS service with 8 methods (findAll, findById, create, deleteOrder, updateStatus, calculateMonthlyRevenue, bulkUpdateStatus, getOrdersForExport)
2. **useSearchProducts.ts** — React hook with debouncing, AbortController, pagination, validation, retry logic

**Requirements:**
- All queries scoped by `organizationId`
- Redis caching + invalidation on mutations
- Audit logging on all mutations
- Email notifications on shipped status with error handling
- State machine for order transitions
- Debounced search (300ms), separate loading states, exponential backoff (max 3 attempts)

**Hash:** c02d40e7 (deterministic, same corpus every run)

---

## Results Summary

| Rank | Provider     | Quality | Code Score | Time  | Cost    | Self-Eval Bias |
|------|-------------|---------|------------|-------|---------|---|
| 🥇 1 | **gemini**   | **100** |   **20**   | 58s   | $0.000  | 0.0 |
| 🥈 2 | **codex-fast** |  **85**  |    17     | 133s  | $0.008  | +2.0 |
| 🥉 3 | **claude**   |  **85**  |    17     |  67s  | $0.031  | +1.0 |
| 4 | **cursor-agent** |  80   |    16     |  89s  |   —     | +2.0 |

---

## Quality Breakdown

### Gemini — 🥇 WINNER (100/100)

**Code Composite:** 20/20  
Dimensions: Completeness **5/5** | Accuracy **5/5** | Actionability **5/5** | No Hallucinations **5/5**

**Strengths:**
- All 8 OrderService methods fully implemented and production-ready
- Efficient cache invalidation using Redis pattern matching  
- Comprehensive state machine for order transitions
- Robust validation in create() and updateStatus()
- useSearchProducts hook implements all required features: debouncing, AbortController, pagination append logic, retry with exponential backoff
- No invented APIs or mock implementations

**Profile:**
- Fastest execution (58s) among high-quality providers
- Zero cost (leverages free tier)
- Perfect self-eval calibration (20 claimed, 20 scored)

---

### Codex-fast — 🥈 TIER 2 (85/100)

**Code Composite:** 17/20  
Dimensions: Completeness **5/5** | Accuracy **4/5** | Actionability **4/5** | No Hallucinations **4/5**

**Strengths:**
- All methods implemented, careful type definitions
- Good separation of concerns (helper methods for validation, cache management)
- Solid state machine logic

**Trade-offs:**
- More verbose with extra interfaces (PrismaOrderDelegate, PrismaOrderLineItemDelegate)
- Cache invalidation slightly less optimal
- useSearchProducts callback structure less idiomatic React
- Overconfident self-eval (+2 bias: claimed 19, scored 17)

**Profile:**
- Slowest execution (133s) due to verbose approach
- Low cost ($0.008)

---

### Claude — 🥈 TIER 2 (85/100)

**Code Composite:** 17/20  
Dimensions: Completeness **5/5** | Accuracy **4/5** | Actionability **4/5** | No Hallucinations **4/5**

**Strengths:**
- Complete implementation of all requirements
- Clean Logger integration
- VALID_TRANSITIONS as data structure (idiomatic)
- Good error handling in email notifications

**Trade-offs:**
- Slightly less optimized cache key generation
- useSearchProducts code organization slightly less refined than gemini
- Modest self-eval bias (+1: claimed 18, scored 17)

**Profile:**
- Mid-range execution (67s)
- Highest cost among leaders ($0.031)
- Most stable self-eval calibration

---

### Cursor-agent — 4th PLACE (80/100)

**Code Composite:** 16/20  
Dimensions: Completeness **4/5** | Accuracy **4/5** | Actionability **4/5** | No Hallucinations **4/5**

**Gaps:**
- OrderService methods complete but custom Redis interface (deleteByPattern) not in spec
- useSearchProducts requires custom fetchPage callback (non-standard)
- Less conventional approach to pagination offset tracking
- Self-eval overconfidence (+2: claimed 18, scored 16)

**Profile:**
- Mid-range execution (89s)
- Cost unavailable

---

## Self-Evaluation Bias Analysis

**Bias = Self-Eval Raw − Judge Score**

| Provider | Self-Eval | Judge Score | Bias |
|----------|-----------|-----------|------|
| Gemini | 20 | 20 | **0.0** ✓ |
| Claude | 18 | 17 | +1.0 (slight overconfidence) |
| Codex-fast | 19 | 17 | +2.0 (overconfident) |
| Cursor-agent | 18 | 16 | +2.0 (overconfident) |

**Interpretation:**
- **Gemini** showed perfect calibration; knows its strengths/limits
- **Codex-fast & Cursor-agent** overestimated their code quality by 2 points
- **Claude** slightly optimistic but closer to reality

---

## Corpus Mode Notes

This benchmark runs in **corpus mode** with:
- ✅ **Round 1 (Code)** — Completed
- ⏸️ **Round 5 (Adversarial review)** — Skipped (phase not activated in this skill run)
- ⏸️ **Round 3 (Tests)** — Skipped (test round would follow Round 1 + adversarial)
- ⏸️ **Round 7 (Test adversarial)** — Skipped (no test round)

This run focuses on **code quality only**. Multi-round execution (adversarial, tests) would require invoking skills in sequence with intermediate rounds stored in `/tmp/zuvo-rounds/`.

---

## Recommendations

1. **Adopt Gemini's approach** for production code:
   - Pattern-based cache invalidation
   - Cleaner state transition logic
   - Idiomatic React patterns in hooks

2. **Monitor Claude's cost trajectory** — highest cost but solid quality

3. **Address overconfidence in Codex & Cursor** — recalibrate self-evaluation heuristics

4. **Repeat in 1 week** — corpus is deterministic, so trends across runs reveal model improvements

---

**Run completed:** 2026-04-08 01:46 UTC | Total execution: 347s | Top provider: gemini (100/100)
