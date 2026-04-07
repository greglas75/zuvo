# Benchmark Corpus Task — Write Tests

You are participating in a benchmark. Write Jest tests for the two production files below. Do NOT reference any external rules or style guides — implement from the spec below only.

## Round 1 Output (the code you must test)

{{ROUND_1_CODE}}

---

## Requirements

**Test framework:** Jest + ts-jest. For React hooks, use `@testing-library/react` with `renderHook` and `act`. Do NOT use `react-hooks-testing-library` (deprecated).

Mock all external dependencies:
- NestJS: `PrismaService`, `RedisService`, `EmailService`, `PaymentGateway` — use `jest.fn()` mocks
- React hook: mock `fetch` or `axios` globally with `jest.spyOn(global, 'fetch')`

For **OrderService.ts**, write tests covering:
- Happy path for each of the 8 public methods
- Error paths: NotFoundException, invalid state transition, transaction rollback
- Edge cases: cache hit vs miss, bulkUpdateStatus with mixed valid/invalid transitions, getOrdersForExport at maxRows boundary
- Email notification error handling on `shipped` status

For **useSearchProducts.ts**, write tests covering:
- Debounce: verify fetch not called until 300ms elapsed (use `jest.useFakeTimers()`)
- AbortController: verify abort called on query change and unmount
- Pagination: loadMore appends results, does not replace
- Retry: 3 attempts with exponential backoff on failure
- isLoading vs isLoadingMore states are mutually exclusive
- Cleanup on unmount: timers cleared, no state updates after unmount

**Quality standards:**
- Test names describe expected behavior: `it('throws NotFoundException when order not found in org')`
- Each error path asserts specific error type AND message
- Mocks verified with `toHaveBeenCalledWith` assertions
- No magic values — test data declared as named constants
- Mock state reset in `beforeEach` using `jest.clearAllMocks()`

---

## Required Response Format

Your response MUST follow this structure exactly:

1. A fenced TypeScript block for OrderService tests:
   ````
   ```typescript
   // FILE: OrderService.test.ts
   <full test suite>
   ```
   ````

2. A fenced TypeScript block for useSearchProducts tests:
   ````
   ```typescript
   // FILE: useSearchProducts.test.ts
   <full test suite>
   ```
   ````

3. The TEST_EVAL_SUMMARY block at the very end (no prose after it):

```
TEST_EVAL_SUMMARY
File count: <number of test files written>
Test count: <total number of it() blocks>
Edge cases covered: <list the 3 most important edge cases you explicitly tested>
```
