# Benchmark Corpus Task — Write Tests

You are participating in a benchmark. Write tests for the two production files from Round 1 of this benchmark session.

The files to test are:
- `OrderService.ts` — NestJS service with CRUD, state machine, caching, multi-tenancy
- `useSearchProducts.ts` — React hook with debounce, pagination, retry

## Round 1 Output (the code you must test)

{{ROUND_1_CODE}}

## Requirements

Use Jest + ts-jest. Mock all external dependencies (PrismaService, RedisService, EmailService, PaymentGateway, fetch/axios).

For each file, write tests covering:
- Happy path for each public method
- Error paths (service unavailable, invalid input, not found)
- Edge cases (empty results, state machine invalid transitions, concurrent requests)
- Boundary conditions (max pagination, cache hit vs miss)

Follow these quality standards:
- Test names describe expected behavior (not "should work")
- Each error path asserts specific error type AND message
- Mocks verified with `toHaveBeenCalledWith` assertions
- No magic values — test data is self-documenting
- Mock state reset between tests (`beforeEach`)

---

## After writing tests

At the end of your response, print this block EXACTLY (fill in your values):

```
TEST_EVAL_SUMMARY
File count: <number of test files written>
Test count: <total number of it() blocks>
Edge cases covered: <list the 3 most important edge cases you explicitly tested>
```
