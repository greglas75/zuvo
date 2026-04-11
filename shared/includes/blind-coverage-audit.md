# Blind Coverage Audit

> Shared protocol for deterministic, production-first coverage mapping. Used by `write-tests` as a mandatory checkpoint between Q-score verification and adversarial review.

## Purpose

Blind Coverage Audit is not another Q-score. It answers a different set of questions:

1. What behaviors does the production file actually own?
2. Which of those behaviors are fully tested?
3. Which are only partially tested or structurally asserted?
4. What single missing test would improve confidence the most?

This protocol exists to catch coverage theater before adversarial review.

## Contract-Blind Rules

The audit is **production-first**.

Strict **contract-blind** execution requires an isolated context such as a read-only agent or a fresh subprocess that receives this protocol plus only the production file and test file.

The auditor may read:
- production file
- test file

The auditor must NOT read before issuing a verdict:
- the writer's test contract
- the writer's self-eval block
- prior adversarial findings

Do not inherit the writer's plan. Build the coverage inventory from source.

If strict isolation is unavailable, do not claim a passing blind audit. Defer the audit or fail the file explicitly.

## Audit Procedure

### Step A: Inventory production behavior

Read the production file fully before reading the test file. Enumerate every owned behavior row-by-row.

Required inventory kinds:

| Kind | What counts |
|------|-------------|
| `branch` | `if`, `else`, `switch`, ternary, early-return guard |
| `error_path` | `throw`, reject, catch fallback, explicit error branch |
| `fallback` | default branch, unmatched case, empty/loading/error render |
| `side_effect` | logging, mutation, dispatch, storage, navigation, metrics |
| `callback_forwarding` | emitted handler or callback invocation owned by the module |
| `prop_forwarding` | forwarded props or args that define the module contract |
| `a11y_output` | `role`, status text, fallback nodes, labels, accessible names |
| `async_state` | loading, success, empty, retry, error transitions |
| `delegation_contract` | exact forwarding contract for thin delegators and wrappers |

Output:

```text
INVENTORY COMPLETE: <N> rows
```

### Step B: Classify ownership

Apply Owned-vs-delegated rules before judging coverage:

- **Owned behavior**: branch, fallback, side effect, callback wiring, prop forwarding, or a11y output created by this module. Must be audited.
- **Thin delegator**: if the module only forwards to another module, audit the forwarding contract, not the downstream implementation.
- **Wrapper/orchestrator**: audit what it selects, forwards, or emits. Do not demand tests for downstream internals.
- **Barrel/re-export file**: no owned runtime behavior. Mark rows `N/A` or skip the file.
- **Accessibility fallback**: if the module renders a fallback node such as `role="status"` or loading/error text, that is owned behavior even when the main content is delegated.

### Step C: Map tests to inventory

Read the test file second. For every inventory row, map the strongest matching test evidence.

Use this coverage scale only:

| Coverage | Meaning |
|----------|---------|
| `FULL` | behavioral assertion proves the owned behavior |
| `PARTIAL` | some evidence exists, but key branch data or contract detail is missing |
| `NONE` | no test proves the behavior |
| `STRUCTURAL_ONLY` | test checks presence, markup, or mock shape without proving runtime behavior |
| `N/A` | behavior is not owned by the file or genuinely does not apply |

Evidence must reference concrete test locations or assertions, not impressions.

### Step D: Issue verdict and missing test

Coverage verdicts: `CLEAN | FIX | REWRITE`

Rules:

- any owned `branch`, `error_path`, `fallback`, `side_effect`, `callback_forwarding`, `prop_forwarding`, `a11y_output`, `async_state`, or `delegation_contract` with coverage `NONE` => `FIX`
- any owned `error_path`, `fallback`, `side_effect`, `callback_forwarding`, `prop_forwarding`, `a11y_output`, `async_state`, or `delegation_contract` with coverage `STRUCTURAL_ONLY` => `FIX`
- 3 or more `PARTIAL` rows => `FIX`
- if the overall test shape is wrong for the module's owned behaviors => `REWRITE`
- otherwise => `CLEAN`

This protocol allows at most 2 audit passes per file:

1. initial blind audit
2. one rerun after fixes

If critical blind-audit findings persist after pass 2, the caller must mark the file failed instead of pretending the coverage is clean.

## False-Positive Guardrails

- Do not fail a thin delegator for not testing downstream business logic. Fail it only when forwarding is unproven.
- For THIN delegation, `FULL` is allowed when the test proves the pass-through result and verifies forwarded args with `CalledWith`.
- Do not call a row `FULL` if the test only asserts a mock return value and never verifies forwarded args with `CalledWith`.
- Do not downgrade owned accessibility fallbacks just because they look "small". If the screen reader-visible fallback can regress, it must be audited.
- Do not confuse "rendered something" with "proved the fallback path". That is `STRUCTURAL_ONLY`, not `FULL`.

## Required Output

The audit output is a strict table, not prose impressions.

```text
Audit mode: strict
Coverage verdict: CLEAN|FIX|REWRITE
INVENTORY COMPLETE: <N> rows

| id | kind | production lines | owned_or_delegated | coverage | test evidence | notes |
|----|------|------------------|--------------------|----------|---------------|-------|
| B1 | branch | 18-24 | owned | FULL | file.test.ts:42-58 | verifies empty guard |
```

After the table, emit:

1. `Prioritized findings`
2. `Highest-value missing test`

`Highest-value missing test` must name the single test that closes the most important uncovered or structural-only gap.
