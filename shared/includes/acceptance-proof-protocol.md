# Acceptance Proof Protocol

> Defines how the brainstorm → plan → execute pipeline verifies that **behavior matches Acceptance Criteria**, not merely that **code compiled and tests passed**.

## Why this exists

A task is not done because:
- code committed
- unit tests passed
- spec reviewer said "compliant"
- adversarial review said "no critical findings"

A task is done when **the behavior promised by the Acceptance Criteria can be demonstrated to actually work**, with evidence captured during execute. Tests are an *implementation detail* of the proof — not the proof itself. A passing unit test on a function whose AC was misunderstood proves nothing.

This protocol is the contract between brainstorm (writes ACs with proofs), plan (decomposes proofs into per-task assertions), and execute (runs proofs, captures evidence, gates completion).

## Definitions

- **Acceptance Criterion (AC)**: a specific user-observable or system-observable behavior the feature must exhibit. Written by brainstorm.
- **Acceptance Proof**: a deterministic procedure (command, interaction, or measurement) that, when executed, produces evidence the AC is satisfied. Written alongside the AC. Run by execute.
- **Per-task proof**: proof scoped to one task's slice of behavior (e.g., "function foo() returns the expected canonical token for input X").
- **Whole-feature smoke proof**: proof exercising the **end-to-end user flow** described in the spec's main use case. Run after all tasks complete, before execute declares COMPLETED. Catches structural bugs that span tasks (e.g., codec round-trip data loss).

## Surface taxonomy

Every task and every AC declares one **Surface**. Different surfaces accept different proof shapes.

| Surface | Examples | Proof shape | Deterministic? |
|---------|----------|-------------|----------------|
| `backend-logic` | Pure functions, classes, parsers, validators | Run function with spec inputs, assert outputs match spec | Yes |
| `api` | HTTP endpoints, RPC handlers, GraphQL resolvers | Real call (curl/fetch/SDK) against running service, assert status + body shape against spec schema | Yes |
| `db` | Migrations, schema changes, seed data | Run migration on test DB, run sample queries, assert schema + data invariants | Yes |
| `db-data` | Background jobs, ETL, data transforms | Run on sample dataset, assert before/after invariants (counts, sums, key properties) | Yes |
| `ui` | Components, pages, interactions | Open dev server, navigate, interact via Playwright/chrome-devtools MCP, assert DOM state + screenshot | Mostly yes; visual quality may need LLM judge |
| `integration` | Wiring across services, event handlers | Trigger upstream event, observe downstream effect end-to-end | Yes |
| `config` | Env vars, feature flags, build config | Load config, assert dependent code reads expected values | Yes |
| `docs` | Markdown, READMEs, runbooks | Linter (markdownlint), link checker, content validation against rubric | Yes |

**LLM-judge required only when** the AC includes a subjective dimension that no deterministic check can express (e.g., "chip renders with visual affordance for atomic edit"). For these, attach the screenshot/snapshot and dispatch a Sonnet judge with the AC text + artifact, requiring a binary `VERIFIED` or `BROKEN` token plus one-sentence justification. Default: deterministic.

## Proof structure

Every Acceptance Proof has these fields:

```yaml
ac_id: AC3                              # identifier matching the spec's AC#
surface: backend-logic                  # one of the surfaces above
preconditions: |                        # what must exist for proof to run
  - test DB seeded with fixtures/codec-sample.json
  - PLACEHOLDER_CODEC_ENABLED=true
proof: |                                # the actual proof — command, interaction, or measurement
  pnpm vitest run lib/services/placeholder-codec/codec.test.ts
  -- and additionally --
  node -e "const {validate} = require('./codec'); 
           const r = validate(['<em>x</em>','<em>y</em>'].join(''), '[[g1]][[/g1]][[g1]][[/g1]]');
           if (!r.unbalanced.length) process.exit(1);"
expected: |                             # what success looks like
  vitest exit 0 AND node script exit 0
  -- and validate must return unbalanced.length > 0 because both targets share id g1
artifact_path: |                        # where evidence is recorded for retro / audit
  .zuvo/proofs/<task-N>-AC3.txt
```

For UI surface, the `proof:` field becomes an **interaction script** (Playwright spec or chrome-devtools MCP commands), and `expected:` describes both DOM state and visual artifact:

```yaml
ac_id: AC1
surface: ui
preconditions: |
  - dev server on http://localhost:3000
  - canonical project seeded with one entry containing 2 source chips
proof: |
  navigate to /proofreading/<seeded-id>
  click first target chip
  press Backspace
  read DOM after interaction
expected: |
  - target column innerHTML loses exactly the clicked chip span
  - no [[gN]] token leaks into surrounding text
  - screenshot at .zuvo/proofs/<task-N>-AC1.png shows remaining chip intact
artifact_path: .zuvo/proofs/<task-N>-AC1.png + .zuvo/proofs/<task-N>-AC1-dom.txt
```

## Where proofs live

| Stage | What it owns |
|-------|--------------|
| brainstorm | Writes AC with inline `Proof:` sub-bullet per AC. Validation Methodology summarizes proofs at spec level. Whole-feature Smoke section enumerates main user flows + their proofs. |
| plan | Per-task `Acceptance:` field maps to spec AC# **and copies the spec's proof inline** (so execute does not need to re-resolve from spec). Adds `Surface:` field. Plan also has `## Whole-feature Smoke Proofs` section listing proofs that run after all tasks. |
| execute | At Step 7d (per task): runs the task's proof, captures artifact, gates commit on success. At Phase Final (after all tasks): runs Whole-feature Smoke Proofs, gates COMPLETED on success. |
| build | Inline equivalents — Phase 2 plan template includes Acceptance Proof per implementation step; Phase 4 verification runs proofs before committing. |

## Hard rules

1. **No proof = no completion.** A task without an Acceptance Proof field is rejected by plan-reviewer (cross-model validation). Execute cannot mark such a task COMPLETED.
2. **No aggregate scoring.** Telemetry must report per-file Q/CQ scores, never `q_gates: N/M aggregate`. Aggregate scores hide per-file zeros and were the proximate cause of the 2026-04-22 codec session failure (q_gates: 19/19 aggregate while review later found Q7=0 and Q11=0 in specific files).
3. **Independence.** The agent or runner that *executes* the proof must not be the same agent that *implemented* the code, when multi-agent dispatch is available. In single-agent mode, a `[CHECKPOINT: switching to acceptance-verifier role]` marker is required.
4. **Whole-feature smoke is mandatory** for any plan that has a "main user flow" AC. Per-task proofs alone cannot detect cross-task structural defects (e.g., codec round-trip data loss spanning encode + strip + decode in three different tasks).
5. **Proof failure = task BLOCKED, not WARN.** A proof that does not produce its expected outcome blocks the task. The implementer is re-dispatched with the failure evidence. After 3 cycles, surface to user.
6. **Deterministic preferred.** Use LLM judge only when no deterministic check expresses the AC. Prefer `assert response.target === '[[g1]]hello[[/g1]]'` over `LLM-judge: does this look right?`.
7. **Artifact retention.** Every proof writes its artifact to `.zuvo/proofs/<task-N>-<ac-id>.<ext>` so retros and post-hoc audits can verify the proof actually ran with real outputs.

## Proof writing recipe (for plan authors)

For each AC, ask:

1. **What is the user-observable behavior?** Write it as a single declarative sentence: "After import, target column displays interactive chips for every source-side tag."
2. **What's the smallest deterministic procedure that exhibits this behavior?** That is the proof body.
3. **What artifact would a skeptic accept?** That is the expected output.
4. **What surface is it on?** Pick from the taxonomy. If uncertain, default to the most concrete (favor `api` over `backend-logic` if the AC is reachable through HTTP).
5. **Is this a main user flow?** If yes, also list it under Whole-feature Smoke Proofs.

If you cannot answer (1) without using words like "should work" or "looks right", the AC is too vague — return to brainstorm to tighten it.

## Failure modes this protocol targets

| Past failure | How protocol prevents recurrence |
|--------------|----------------------------------|
| 2026-04-22 codec execute reported PASS while review found 2 prod bugs | Whole-feature smoke proof would have round-tripped sample HTML and detected data loss in stripRedundantVoidCloses |
| `q_gates: 19/19 aggregate` hid Q7=0 and Q11=0 | Per-file scoring rule #2 forbids aggregate reporting |
| canonical-codec-storage UI shipped 60% complete, marked PASS | UI-surface proof requires Playwright/chrome-devtools artifact; absent → cannot mark task COMPLETED |
| Spec ACs were vague ("import works"), so plan tasks couldn't decompose into proofs | Brainstorm now requires Proof: sub-bullet per AC at spec time, blocked at spec-reviewer if missing |
| Per-task adversarial review caught surface issues but missed structural bugs | Whole-feature smoke at Phase Final exercises end-to-end behavior, catching cross-task bugs |

## Backwards compatibility

Specs and plans created before this protocol's adoption (pre-2026-05-03) lack Proof fields. Behavior:

- `zuvo:plan` reading such a spec: print `[LEGACY-SPEC] no inline proofs — generating proofs at planning time from existing AC text. Skipping spec-side enforcement.` and produce proofs in the plan.
- `zuvo:execute` reading such a plan: same — proofs must exist in the plan even if absent from spec. If absent from both, abort with `BLOCKED_NO_ACCEPTANCE_PROOF`.

Going forward, all new specs and plans must include proofs.
