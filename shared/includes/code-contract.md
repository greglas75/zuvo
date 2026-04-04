# Pre-Write Code Contract

> Fill this contract BEFORE writing production code. Do not skip sections. This prevents the most common quality failures: missing error handling, unguarded nulls, forgotten edge cases, and CQ gate violations.

## Purpose

Production code written without upfront analysis tends to fail CQ3 (validation), CQ8 (error handling), CQ10 (null guards), and CQ11 (structure). This contract forces the agent to think through error paths, edge cases, and defensive patterns BEFORE writing code — not as an afterthought during review.

## When to Use

- `zuvo:build` — Phase 3, before writing each production file (STANDARD and DEEP tiers)
- `zuvo:execute` — before the GREEN phase of each TDD task (complex tasks)
- Any workflow that produces new production files with business logic

**Skip for:** Config changes, simple type definitions, re-exports, files under 20 LOC.

## The Contract

Fill this template for each production file being written or significantly modified:

```
CODE CONTRACT: [file-path]
═══════════════════════════════════════

1. INPUTS AND VALIDATION (CQ3)
   List every input to this code (function params, request body, query params, config values).

   Input 1: [name: type] — REQUIRED/OPTIONAL
     Valid range: [constraints]
     Invalid examples: [null, empty, negative, too long, wrong type]
     Validation strategy: [runtime schema / guard clause / type system]

   Input 2: [name: type] — REQUIRED/OPTIONAL
     ...

   Unvalidated inputs = CQ3 violation. Every input must have a validation strategy.

2. ERROR PATHS (CQ8)
   List every way this code can fail, and the handling strategy.

   Error 1: [dependency] times out → STRATEGY: [timeout + retry / fallback / rethrow]
   Error 2: [dependency] returns unexpected shape → STRATEGY: [validate + throw / default]
   Error 3: [input] fails validation → STRATEGY: [400 response / throw ValidationError]
   Error 4: [database] constraint violation → STRATEGY: [catch + domain error]
   ...

   For each error, classify business impact:
   - CRITICAL (payment, auth, data integrity): catch → rethrow with context
   - NON-CRITICAL (metrics, cache, logging): catch → warn + continue
   - USER-FACING (dashboard, API response): catch → fallback data or friendly error

   Empty catch blocks = CQ8 violation. "Log and rethrow" without context = CQ8 violation.

3. NULL AND OPTIONAL HANDLING (CQ10)
   List every nullable value this code touches.

   Nullable 1: [source.field] — can be null when [condition]
     Guard: [?. / ?? default / explicit null check / throw]
   Nullable 2: [array.find()] result — can be undefined when [condition]
     Guard: [explicit undefined check before use]
   ...

   .find() without null check = CQ10 violation. Optional chaining without fallback on critical path = CQ10 violation.

4. RESOURCE MANAGEMENT (CQ6, CQ22)
   List every resource this code creates or consumes.

   Resource 1: [type: DB connection / timer / listener / stream]
     Cleanup: [.close() in finally / clearTimeout / removeListener / .destroy()]
     Bounded: [YES — LIMIT N / pagination / streaming] or [NO — FIX NEEDED]

   Unbounded memory from external data = CQ6 violation. Listeners without cleanup = CQ22 violation.

5. SECURITY CHECKLIST (CQ4, CQ5)
   Answer each question. N/A with justification is acceptable.

   [ ] Auth: Does this code require authentication? If yes, where is the guard?
   [ ] AuthZ: Does this code check authorization? If yes, is it query-level (not just route-level)?
   [ ] PII: Does this code log, return, or store user data? If yes, is PII filtered from logs/errors?
   [ ] Injection: Does this code build queries/commands from user input? If yes, is it parameterized?

6. PATTERN COMPLIANCE (CQ25)
   Before writing, identify existing patterns in the project for:

   - Error handling: [how does existing code handle errors in similar files?]
   - Naming: [what naming convention do similar files use?]
   - Structure: [what file structure do similar files follow?]
   - Logging: [what logger and format does the project use?]

   Deviating from project patterns = CQ25 violation. Document any intentional deviation with rationale.

7. FUNCTION SIGNATURES (draft)
   List the public API of this file before implementing:

   function/method 1: [name](params) → ReturnType
     Purpose: [one sentence]
     Throws: [ErrorTypes] when [conditions]

   function/method 2: ...

   This becomes the specification that tests are written against.
```

## Verification

After filling the contract, verify:

- [ ] Every input has a validation strategy (section 1)
- [ ] Every error path has a handling strategy with impact classification (section 2)
- [ ] Every nullable value has an explicit guard (section 3)
- [ ] Every resource has cleanup and bounding documented (section 4)
- [ ] Security checklist answered for all applicable items (section 5)
- [ ] Existing project patterns identified and will be followed (section 6)
- [ ] Function signatures drafted with error conditions (section 7)

If any check fails, complete the section before writing code.

## CQ Gates This Contract Prevents Failing

| Gate | Contract Section | What it catches early |
|------|-----------------|----------------------|
| CQ3 (Validation) | Section 1 | Missing input validation |
| CQ5 (PII) | Section 5 | PII leaking into logs/errors |
| CQ6 (Resources) | Section 4 | Unbounded memory from external data |
| CQ8 (Errors) | Section 2 | Missing error handling, empty catch blocks |
| CQ10 (Nulls) | Section 3 | Unguarded .find(), optional access on critical path |
| CQ11 (Structure) | Section 7 | Functions growing too large (caught by upfront design) |
| CQ22 (Cleanup) | Section 4 | Listeners/timers without cleanup |
| CQ25 (Patterns) | Section 6 | Deviating from project conventions |
