# TDD Protocol

> Iron law: no production code without a failing test first.

## The Rule

Every piece of production code must be preceded by a test that fails without it and passes with it. This is the RED-GREEN-REFACTOR cycle. It is not optional, not skippable for "simple" changes, and not deferrable to "after implementation."

## The Cycle

### RED: Write a Failing Test

1. Write a test that describes the behavior you are about to implement
2. Run the test suite
3. Confirm the new test fails (and fails for the right reason — missing function, wrong return value, etc.)
4. If the test passes immediately, something is wrong. Either the behavior already exists (you do not need to write code) or the test is not testing what you think it is. Investigate before proceeding.

### GREEN: Write the Minimum Code to Pass

1. Write only enough production code to make the failing test pass
2. Run the test suite
3. Confirm the new test passes AND all existing tests still pass
4. Do not add functionality beyond what the test requires. If you need more behavior, go back to RED and write another test first.

### REFACTOR: Improve Without Changing Behavior

1. Look for duplication, unclear naming, or structural improvements in both production and test code
2. Make the improvement
3. Run the test suite
4. Confirm all tests still pass — the refactoring must not change any behavior

Then repeat: RED for the next behavior, GREEN to implement it, REFACTOR to clean up.

## When This Protocol Applies

- Every task in a `zuvo:execute` plan that creates new functionality
- Every feature in `zuvo:build`
- Every bug fix (RED = test that reproduces the bug, GREEN = fix that makes it pass)
- Every `zuvo:refactor` that adds new behavior (pure restructuring with existing tests is an exception)

## When This Protocol Does NOT Apply

- Pure refactoring where existing tests already cover the behavior and remain green
- Configuration changes (CI, linting, build config)
- Documentation changes
- Deleting dead code (existing tests should still pass after deletion)

## Red Flags — Immediate Stop

If any of these occur, stop and correct course before continuing:

| Red flag | What went wrong | Correction |
|----------|----------------|------------|
| Writing production code before any test exists | Skipped RED phase | Stop. Write the test first. Then write the code. |
| Test passes on first run (no RED phase) | Test is not testing new behavior | Investigate: does the behavior already exist? Is the test asserting the right thing? |
| "I'll write the tests after" | Deferred testing disguised as pragmatism | Tests come first. No exceptions. Write the test now. |
| "Just this one function, it's too simple to test" | Complexity assessment is irrelevant to the rule | Simple functions get simple tests. The test still comes first. |
| "The existing tests cover this" | May be true — verify it | Run existing tests with the new code removed. If they pass, the behavior is NOT covered. Write a test. |
| Multiple production files written with zero test files | Batch skipping of RED phase | Stop. Go back to the first production file. Write tests for each one. |
| Test exists but never ran red | GREEN without RED — test may be vacuous | Delete the production code temporarily, confirm the test fails, then restore. |
| Refactoring changes behavior (test fails after refactor) | REFACTOR phase violated its constraint | Undo the refactor. Either fix it to be behavior-preserving, or go back to RED and write a test for the new behavior first. |

## Integration with Execute Phase

In `zuvo:execute`, the plan document specifies TDD tasks in this format:

```
- [ ] RED: Write failing test [test description]
- [ ] GREEN: Implement [production code description]
- [ ] Verify: [command + expected output]
- [ ] Commit: [commit message]
```

The implementer agent follows this order strictly. The verify step invokes the verification protocol (see `verification-protocol.md`). No task is marked complete without a green test suite as fresh evidence.

## Commit Rhythm

Commit after each GREEN-REFACTOR cycle, not after the entire feature. Small, frequent commits with passing tests at every commit point. Each commit message should describe the behavior added, not the files changed.
