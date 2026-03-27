# Verification Protocol

> Iron law: no completion claims without fresh evidence from the actual system.

## The Rule

Never state that something works, passes, is fixed, or is complete unless you have run a verification command in this session and read its output. Prior knowledge, memory of previous runs, and logical deduction are not substitutes for fresh evidence.

This applies to every claim: "tests pass," "build succeeds," "the bug is fixed," "the feature works," "no errors." If you did not just run the command and read the output, you cannot make the claim.

## The 5-Step Protocol

### 1. IDENTIFY

Determine which command or check would prove your claim true. Be specific.

| Claim | Verification command |
|-------|---------------------|
| "Tests pass" | `npm test` / `pytest` / `vitest run` (the project's actual test command) |
| "Build succeeds" | `npm run build` / `tsc --noEmit` |
| "The bug is fixed" | Run the exact reproduction steps from the bug report |
| "No type errors" | `tsc --noEmit` (not just "no red squiggles") |
| "Lint clean" | `npm run lint` / `eslint .` |
| "Feature works" | Manual verification or test that exercises the feature |
| "File is valid" | Read the file, confirm syntax and structure |

### 2. RUN

Execute the command. Run it fresh — do not rely on cached results from earlier in the conversation. If the command was run before a code change, it must be run again after.

### 3. READ

Read the complete output. Check the exit code. Do not skim. Look specifically for:
- Non-zero exit codes
- Failed test counts (even if some pass)
- Warning messages that indicate problems
- Error output that may appear after apparent success lines

### 4. VERIFY

Confirm that the output actually supports the claim. Common traps:
- "3 passed, 1 failed" does NOT support "tests pass"
- "Compiled with warnings" does NOT support "build succeeds" if warnings are errors in CI
- A test passing does not mean the bug is fixed if the test does not reproduce the bug

### 5. CLAIM

Only after steps 1-4 are complete, make the claim. Include the evidence:

```
Tests pass: `npm test` exited 0, 47 passed, 0 failed.
Build succeeds: `tsc --noEmit` exited 0, no errors.
Bug fixed: reproduction steps from issue #42 now produce expected output (verified via test).
```

## Red Flags — Stop Immediately

If you catch yourself doing any of these, stop and run the verification protocol:

| Red flag | What is actually happening |
|----------|---------------------------|
| "Tests should pass" | You have not run them |
| "This should fix the issue" | You have not verified it does |
| "The build will succeed" | You have not run it |
| "I believe this is correct" | You have not checked |
| "Based on my earlier run..." | That run was before your latest changes |
| "No errors expected" | Expectation is not evidence |
| "The implementation is complete" | Complete = verified, not just written |
| Skipping verification because "it's a small change" | Small changes break things too |
| Running tests on only one file when you changed three | Partial verification is not verification |

## Scope

This protocol applies to:
- Every task completion claim in `zuvo:execute`
- Every "implementation done" statement in `zuvo:build`
- Every "refactoring complete" statement in `zuvo:refactor`
- Every quality gate evaluation that references test results
- Any statement in any skill that asserts the system is in a specific state

It does not apply to analysis-only outputs (audit reports, design documents, plans) where the claim is about findings, not system state.
