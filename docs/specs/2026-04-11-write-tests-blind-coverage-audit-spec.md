# write-tests Blind Coverage Audit -- Design Specification

> **spec_id:** 2026-04-11-write-tests-blind-coverage-audit-1735
> **topic:** add a production-first blind coverage audit to write-tests
> **status:** Approved
> **created_at:** 2026-04-11T10:35:00Z
> **approved_at:** 2026-04-11T14:17:56Z
> **approval_mode:** async
> **author:** zuvo:brainstorm

## Problem Statement

`zuvo:write-tests` already has three quality mechanisms:

1. writer self-checks (`anti-tautology` + `Q1-Q19 self-eval`) in [skills/write-tests/SKILL.md](/Users/greglas/DEV/zuvo-plugin/skills/write-tests/SKILL.md:287)
2. an optional independent Q-scoring reviewer in [skills/write-tests/agents/test-quality-reviewer.md](/Users/greglas/DEV/zuvo-plugin/skills/write-tests/agents/test-quality-reviewer.md:1)
3. cross-model adversarial review in [skills/write-tests/SKILL.md](/Users/greglas/DEV/zuvo-plugin/skills/write-tests/SKILL.md:300)

These are useful, but they leave a specific gap:

- Q-scoring evaluates test quality gates, not exhaustive production behavior coverage
- the reviewer currently receives the test contract, which anchors it to the writer's plan instead of forcing an independent coverage inventory
- adversarial review is strong but stochastic and relatively expensive; it is not optimized for deterministic branch-by-branch mapping

The failure mode is not "tests are obviously bad". The failure mode is:

- tests pass
- Q score looks acceptable
- adversarial may or may not catch the issue
- a real regression survives because no one performed a production-first, contract-blind coverage map

Typical misses:

- unmatched `default` / fallback branches
- weak delegation tests without `CalledWith`
- unverified callback/prop forwarding
- untested a11y fallback elements
- structural assertions that do not prove runtime behavior

## Scope

This spec adds one new review step to `zuvo:write-tests`.

It does **not** redesign the entire skill and does **not** replace adversarial review.

## Current State

### What exists

- `write-tests` uses a single-file loop with `Analyze -> Write -> Verify -> Adversarial -> Log`
- Step 3 verifies anti-tautology and Q-gates
- Step 4 runs cross-model adversarial review using both production and test files
- a dedicated `test-quality-reviewer` agent exists for Q1-Q19 scoring

### What is missing

- no mandatory review step that enumerates production behavior **before** judging the test
- no output artifact that shows `production behavior -> test mapping -> gap verdict`
- no gate that prevents moving to adversarial when an owned branch or fallback has `NONE` coverage

## Goals

1. Add a deterministic review pass that catches coverage theater before adversarial.
2. Make the pass orthogonal to Q-scoring.
3. Force production-first reasoning.
4. Keep the step reusable for future `test-audit` / `fix-tests` adoption.

## Non-Goals

1. Rewriting `adversarial-review.sh`
2. Changing Q1-Q19 definitions
3. Broad refactor of all testing skills in the same change
4. Requiring CodeSift for correctness

## [AUTO-DECISION] Scope Choice

This spec covers only `write-tests`, not `test-audit` or `fix-tests`.

Rationale: `write-tests` is the writer path where confirmation bias is strongest. If the protocol works there, it can be extracted later for auditing skills without blocking this design.

## Design Decisions

### D1: Add `Blind Coverage Audit` as Step 3.5

Insert a new step between `Verify` and `Adversarial`:

```text
Step 1: Analyze
Step 2: Write
Step 3: Verify (anti-tautology + Q-score)
Step 3.5: Blind Coverage Audit
Step 4: Adversarial Review
Step 5: Log
```

This step is mandatory for all files processed by `write-tests`.

### D2: The audit must be production-first and contract-blind

The auditor may read:

- production file
- test file

The auditor may **not** read before scoring:

- the writer's test contract
- the writer's self-eval block
- prior adversarial findings

Reason: the second review must not inherit the same plan assumptions that produced the test.

### D3: The audit is not another Q-score

Q1-Q19 remains useful, but it answers different questions.

Blind Coverage Audit answers:

1. What behaviors does the production file actually own?
2. Which of those behaviors are fully tested?
3. Which are only partially tested or structurally asserted?
4. What single missing test would improve confidence the most?

### D4: Use a behavior inventory, not prose impressions

The audit output is a strict table.

Each production behavior must be represented as one row with:

- `id`
- `kind`
- `production lines`
- `owned_or_delegated`
- `coverage` = `FULL | PARTIAL | NONE | STRUCTURAL_ONLY | N/A`
- `test evidence`
- `notes`

`kind` values:

- `branch`
- `error_path`
- `fallback`
- `side_effect`
- `callback_forwarding`
- `prop_forwarding`
- `a11y_output`
- `async_state`
- `delegation_contract`

### D5: Owned-vs-delegated classification is mandatory

False positives will cluster around wrappers, barrels, orchestrators, and thin delegators unless the auditor explicitly tags behavior ownership.

Rules:

- if the module owns the branch/fallback/side effect, it must be audited
- if the module only forwards to another module, audit the forwarding contract, not the downstream implementation
- barrels remain out of scope for behavior tests

### D6: Gate on uncovered critical behaviors

Blind Coverage Audit has its own verdict:

```text
CLEAN
FIX
REWRITE
```

Rules:

- any owned `branch`, `error_path`, `fallback`, `a11y_output`, `side_effect`, `callback_forwarding`, or `prop_forwarding` with `coverage=NONE` -> `FIX`
- any critical item with `coverage=STRUCTURAL_ONLY` -> `FIX`
- 3 or more `PARTIAL` rows -> `FIX`
- if the test shape is fundamentally wrong for the file's owned behaviors -> `REWRITE`

The skill must not proceed to Step 4 until `Blind Coverage Audit` is `CLEAN`, unless the file is explicitly marked `FAILED`.

### D7: One rerun only

To avoid another infinite review loop:

- run Blind Coverage Audit
- fix findings
- rerun once

Max 2 total audit passes per file.

If critical blind-audit findings persist after pass 2:

- mark the file `FAILED`
- backlog the unresolved findings
- do not claim clean coverage

### D8: Default execution is sequential; agent is an optimization

[AUTO-DECISION]

The protocol must work without sub-agent dispatch.

Execution model:

- Codex / Cursor / degraded env: role-switch checkpoint inside the same run
- Claude Code / Codex agent-capable env: optional dedicated agent `blind-coverage-auditor`

Reason: the protocol should improve reliability everywhere, not only where sub-agents are available.

### D9: Do not depend on regex branch extraction for correctness

[AUTO-DECISION]

The auditor must read the production file fully and enumerate behaviors manually from source. CodeSift may assist with outlines and symbol boundaries, but exhaustive behavior inventory cannot rely on regex-only extraction.

Reason: `switch`, ternaries, JSX fallback fragments, framework conventions, and delegated rendering logic are too varied across JS/TS, PHP, and Python to trust a single pattern pass.

### D10: Persist the result in `coverage.md`

Update the schema from:

```text
| File | Status | Tests | Q Score | Adversarial | Date |
```

to:

```text
| File | Status | Tests | Q Score | Blind Audit | Adversarial | Date |
```

Valid `Blind Audit` values:

- `clean`
- `fix:<n>`
- `rewrite`
- `skipped`

## Proposed Protocol

### Step A: Inventory production behavior

Read the production file first and enumerate:

1. explicit branches (`if`, `else`, `switch`, ternary)
2. early returns and guard clauses
3. throws/rejects/catches/fallback renders
4. side effects and emitted callbacks
5. prop/arg forwarding contracts
6. a11y-visible outputs (`role`, fallback text, status nodes)
7. async loading/error/empty states

Output:

```text
INVENTORY COMPLETE: N rows
```

### Step B: Map tests to inventory

Read the test file second and map each inventory row to test evidence.

Allowed coverage states:

- `FULL`
- `PARTIAL`
- `NONE`
- `STRUCTURAL_ONLY`
- `N/A`

`STRUCTURAL_ONLY` means the test touches the area but does not prove runtime behavior.

Examples:

- render exists, but no assertion on callback args
- fallback node exists, but no accessible role/text assertion
- function called, but no `toHaveBeenCalledWith`

### Step C: Oracle stress

For every `FULL` or `PARTIAL` mapping, ask:

1. does the assertion prove behavior or just presence?
2. could the implementation break and the test still pass?
3. is the mock verified strongly enough?
4. is there an implementation-derived oracle?

This step is where weak delegation tests and shallow component assertions are downgraded.

### Step D: Emit prioritized findings

Findings are grouped:

1. `Missing coverage`
2. `Weak oracle`
3. `Mock fidelity gap`
4. `Scope mismatch`

The audit must always emit:

- one highest-priority finding
- one highest-value missing test

If the audit is clean, it must explicitly say:

```text
BLIND COVERAGE AUDIT: CLEAN
```

## Output Format

```text
BLIND COVERAGE AUDIT
Coverage verdict: [CLEAN | FIX | REWRITE]

Inventory:
| ID | Kind | Prod lines | Owned? | Coverage | Test evidence | Notes |

Top findings:
1. ...
2. ...

Highest-value missing test:
- name:
- production behavior covered:
- why current suite misses it:
- minimum assertions required:
```

## File Changes

### New

1. `shared/includes/blind-coverage-audit.md`
2. `skills/write-tests/agents/blind-coverage-auditor.md`

### Modified

1. `skills/write-tests/SKILL.md`

## Implementation Notes

### `shared/includes/blind-coverage-audit.md`

Should contain:

- the behavior inventory protocol
- owned-vs-delegated classification rules
- coverage state definitions
- verdict thresholds
- output schema
- false-positive guardrails for delegators / barrels / orchestrators

### `skills/write-tests/agents/blind-coverage-auditor.md`

Read-only agent with one job:

- read production file first
- build inventory
- read test file second
- emit table + verdict

It must explicitly forbid reading the test contract before verdicting.

### `skills/write-tests/SKILL.md`

Update Step 3 / Step 4 area to:

1. run Q-score
2. run Blind Coverage Audit
3. fix blind-audit findings
4. rerun blind audit once if fixes were made
5. only then run adversarial review

## Trade-Offs

### Benefits

- catches deterministic coverage gaps earlier than adversarial
- reduces false confidence from a high Q-score
- gives a concrete artifact the user can inspect
- surfaces missing forwarding/a11y/fallback tests reliably

### Costs

- extra tokens and time per file
- one more checkpoint can feel heavy on THIN files

Mitigation:

- keep the protocol compact
- allow a reduced inventory for true THIN delegators
- do not introduce another narrative report; require a table

## Acceptance Criteria

1. `write-tests` cannot mark a file `PASS` when an owned critical behavior has `coverage=NONE`.
2. The blind auditor reads the production file before the test file.
3. The blind auditor does not read the test contract before emitting verdict.
4. The output always includes a behavior inventory table with line references.
5. Weak delegation tests without `CalledWith` are downgraded from `FULL`.
6. Missing a11y fallback assertions are surfaced as `a11y_output` gaps.
7. `coverage.md` records blind-audit status for every processed file.
8. The protocol works without sub-agents.

## Out of Scope

1. Changing `adversarial-review.sh`
2. Replacing Q1-Q19 with a new rubric
3. Rolling the same protocol into `test-audit` in the same implementation
4. Automatic AST-based branch extraction across all supported languages

## Recommendation

Implement this as a small orchestration change plus one extracted include.

Do **not** add another free-form reviewer prompt. The value comes from:

- production-first sequencing
- contract blindness
- table output
- hard gating on `NONE` / `STRUCTURAL_ONLY`

That gives you a real second review instead of another reflective paragraph that sounds smart but proves little.
