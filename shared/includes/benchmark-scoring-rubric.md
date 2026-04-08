# Benchmark Scoring Rubric v1.0

Standard evaluation applied to every agent-benchmark run. Same criteria, same weights, every time.

---

## How to Use

After a benchmark run completes, read R2 (fixed code) and R4 (fixed tests). Score each dimension 0-5. Record in `agent-benchmark.json` under `scores` key.

---

## Code Quality (R2 files) — 7 dimensions, max 35

### C1: Completeness (0-5)
- 5: All 8 OrderService methods + hook with all return values. No stubs/TODOs.
- 4: All methods present, minor missing return field or helper.
- 3: 1 method incomplete or stubbed.
- 2: 2+ methods incomplete.
- 0: Major methods missing.

### C2: Input Validation (0-5)
- 5: Validates all inputs: customerId, currency, lineItems array, quantity (>0, integer, finite), unitPrice (>=0, finite), take/skip bounds, orgId.
- 4: Validates most inputs, misses 1-2 edge cases (e.g. NaN, negative).
- 3: Basic validation (empty checks) but no numeric bounds.
- 2: Minimal validation.
- 0: No validation.

### C3: Error Handling (0-5)
- 5: Specific exception types (NotFoundException, BadRequestException, ConflictException). Email .catch(). Redis .catch() fallback. No empty catch blocks.
- 4: Specific exceptions, email handled, 1 missing catch.
- 3: Generic Error() instead of specific types, or missing email/Redis error handling.
- 2: try/catch present but swallows errors or uses generic Error.
- 0: No error handling.

### C4: State Machine (0-5)
- 5: Correct transitions map. TOCTOU protection via CAS (updateMany + status WHERE + count check). Cancellation from any non-delivered. Inside transaction.
- 4: Correct transitions + TOCTOU protection but not inside transaction.
- 3: Correct transitions but no TOCTOU protection (plain update).
- 2: Transitions present but incorrect (e.g. missing cancellation paths).
- 0: No state machine enforcement.

### C5: Redis/Cache (0-5)
- 5: Version-based invalidation (no KEYS/SCAN). TTL set. Date deserialization from JSON. Malformed cache fallback. findAll + findById cached.
- 4: SCAN-based invalidation. TTL + Date deserialization. One of findAll/findById cached.
- 3: Pattern deletion (may use KEYS). TTL present. No Date deserialization.
- 2: Basic cache set/get but no invalidation strategy.
- 0: No caching.

### C6: Hook Quality (0-5)
- 5: Debounce 300ms. AbortController per-request (aborts previous). Pagination appends. Retry only 5xx/429 (not 4xx). mountedRef guard. Cleanup on unmount.
- 4: All above but retries ALL errors (no 4xx/5xx distinction).
- 3: Debounce + abort + pagination but missing retry discrimination or mountedRef.
- 2: Basic implementation, missing abort or cleanup.
- 0: Incomplete hook.

### C7: Code Structure (0-5)
- 5: Under file-limits.md thresholds. Helpers extracted. Clear separation of concerns. Proper TypeScript types.
- 4: Slightly over limits but well-structured.
- 3: Over limits, some long methods but readable.
- 2: Monolithic methods, poor structure.
- 0: Unreadable.

---

## Test Quality (R4 files) — 5 dimensions, max 25

### T1: Assertion Specificity (0-5)
- 5: Every error assertion checks type AND message (double assert). CalledWith on every mock. No toBeDefined/toBeTruthy alone.
- 4: Most assertions specific, 1-2 weak (toBeDefined without follow-up).
- 3: Mix of specific and generic assertions.
- 2: Mostly toBeDefined/toBeTruthy.
- 0: No meaningful assertions.

### T2: Edge Case Coverage (0-5)
- 5: TOCTOU race, cache hit/miss/malformed, boundary values (0, negative, MAX), empty arrays, concurrent requests, stale responses, Date serialization round-trip.
- 4: Most edge cases, missing 1-2.
- 3: Happy path + basic error + 2-3 edge cases.
- 2: Happy path + 1 error path only.
- 0: Happy path only.

### T3: Mock Quality (0-5)
- 5: Factory functions for mocks. $transaction passthrough. beforeEach cleanup. Unexpected call detection. Realistic mock data with named constants.
- 4: Proper mocks with cleanup, missing factory or unexpected-call guard.
- 3: Basic jest.fn() mocks, beforeEach present.
- 2: Inline mocks, no cleanup.
- 0: No mocks or broken mock setup.

### T4: Error Path Coverage (0-5)
- 5: Every throw/reject in production code has a corresponding test. Validation errors, not-found, conflict, email failure, Redis failure, network error. 4xx vs 5xx retry distinction tested.
- 4: Most error paths tested, 1-2 missing.
- 3: Major error paths tested but validation paths untested.
- 2: 1-2 error paths tested.
- 0: No error tests.

### T5: Anti-Tautology (0-5)
- 5: Zero tautological assertions. No expect(true).toBe(true), no toBeDefined-only, no mirrored implementation logic in expected values. expect.assertions() used where appropriate.
- 4: 1 weak assertion.
- 3: 2-3 weak assertions.
- 2: Multiple tautologies.
- 0: Tests prove nothing.

---

## Adversarial Response (2 dimensions, max 10)

### A1: Code Fix Quality (0-5)
- 5: All CRITICAL findings addressed. Most WARNING addressed. Fix is correct (not just cosmetic). Both files modified.
- 4: All CRITICAL addressed, some WARNING skipped. Both files modified.
- 3: Most CRITICAL addressed but 1 missed or incorrectly fixed. Or only 1 of 2 files fixed.
- 2: Some fixes attempted but CRITICAL issues remain.
- 0: Findings ignored or R2 = R1.

### A2: Test Fix Quality (0-5)
- 5: All CRITICAL findings addressed. Assertions strengthened. New edge case tests added. Both test files modified.
- 4: CRITICAL addressed, minor findings skipped. Both files modified.
- 3: Some fixes but weak assertions remain. Or only 1 file fixed.
- 2: Minimal fixes.
- 0: Findings ignored or R4 = R3.

---

## Total Score

| Category | Max |
|----------|-----|
| Code Quality (C1-C7) | 35 |
| Test Quality (T1-T5) | 25 |
| Adversarial Response (A1-A2) | 10 |
| **Total** | **70** |

---

## JSON Format

Add to `agent-benchmark.json`:

```json
"scores": {
  "C1_completeness": 0,
  "C2_validation": 0,
  "C3_error_handling": 0,
  "C4_state_machine": 0,
  "C5_redis": 0,
  "C6_hook": 0,
  "C7_structure": 0,
  "code_total": 0,
  "T1_assertion_specificity": 0,
  "T2_edge_cases": 0,
  "T3_mock_quality": 0,
  "T4_error_paths": 0,
  "T5_anti_tautology": 0,
  "test_total": 0,
  "A1_code_fix": 0,
  "A2_test_fix": 0,
  "adversarial_total": 0,
  "grand_total": 0
}
```

---

## Scoring Rules

1. Read R2 code files. Score C1-C7. Write down file:line evidence for each score.
2. Read R4 test files. Score T1-T5. Write down evidence.
3. Compare R1 vs R2 diff + adversarial findings. Score A1.
4. Compare R3 vs R4 diff + adversarial findings. Score A2.
5. Sum totals. Record in JSON.
6. **Never score from memory.** Always read the actual files.
