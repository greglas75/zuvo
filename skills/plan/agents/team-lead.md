# Team Lead — Synthesis Procedure

> This is NOT a dispatched agent. These are instructions for the MAIN AGENT acting as Team Lead.

You have received three reports from the Architect, Tech Lead, and QA Engineer agents. You also have the original spec. Your job is to synthesize all of this into a concrete, ordered list of TDD tasks that an implementer can execute without ambiguity.

---

## Synthesis Process

### Step 1: Identify the Deliverables

From the spec, list every concrete deliverable: each new file, each modified file, each new API endpoint, each new component, each new test file. Cross-reference with:
- The Architect's component list and blast radius
- The Tech Lead's file structure table
- The QA Engineer's test strategy table

If any deliverable appears in the spec but not in the agent reports, investigate. Either the agents missed it or the spec includes something that does not require code changes (documentation, config, etc.).

Build the plan's `## Coverage Matrix` before writing tasks:
- **Spec-driven mode:** one row per spec acceptance item, deliverable, or explicit constraint
- **Inline mode:** one row per goal, scope boundary, and user-stated constraint
- If an unapproved spec exists in inline mode, treat it as context only. Do not promote its IDs into the matrix as authority items.

### Step 2: Determine Task Order

Tasks must be ordered so that:
1. Foundation comes first: types, interfaces, schemas, configuration
2. Core logic comes second: services, handlers, business rules
3. Integration comes third: controllers, routes, UI components that consume the core
4. Wiring comes last: imports, barrel exports, module registration

Within each layer, independent tasks should have no dependencies on each other. Dependent tasks must explicitly list their prerequisites.

### Step 3: Size Each Task

Each task should take 2-5 minutes to implement. Use these guidelines:

| Size indicator | Action |
|----------------|--------|
| Task creates 1 file + 1 test file | Good size. Keep as one task. |
| Task creates 2-3 files + test files | Acceptable if the files are small and tightly coupled. |
| Task creates 4+ files | Too large. Split by responsibility: one task per logical unit. |
| Task modifies an existing file with complexity rank in top 10 | Mark as `complex`. The QA Engineer's risk assessment applies. |
| Task involves only type definitions or interfaces | Mark as `standard`. These are low-risk. |
| Task involves cross-cutting concerns (auth, validation, error handling) | Mark as `complex`. These affect multiple code paths. |

If a task would touch more than 5 files, more than two system boundaries, or two independent deliverables, split it instead of merely marking it `complex`.

### Step 4: Write the Task Contract

For each task, write the minimum contract the implementer needs to succeed without guessing.

**RED step (failing test):**
- Name the test file path.
- State the behavior that must fail first (missing symbol, wrong value, broken path, failing assertion).
- State the key assertions and edge/error cases that prove the task is complete.
- Use the test conventions identified by the QA Engineer (framework, naming, directory).
- Do not inline full test bodies unless a scaffold of 20 LOC or less is necessary to clarify a non-obvious pattern.

**GREEN step (implementation intent):**
- Name the symbols, files, interfaces, and invariants to add or change.
- Follow the patterns selected by the Tech Lead.
- Reuse the existing code identified by the Tech Lead (do not reimplement what already exists).
- If a scaffold is necessary, keep it at or below 20 LOC and use it only to show structure.
- Do NOT write the full implementation. The plan defines WHAT must exist and WHY, not every line the implementer will type.

**Verify step:**
- Write the exact shell command to run the tests. Example: `npx vitest run src/services/order.service.test.ts`
- Write the expected output. Example: `Tests: 3 passed, 3 total`
- If the expected result mentions a concrete value or behavior, the command must assert it through exit status rather than merely print it.
- If the verification involves more than just tests (e.g., type checking, linting), include those commands too.

**Commit step:**
- Write a commit message that describes the behavior added, not the files changed.
- Example: "add order validation that rejects negative quantities and empty item lists"

### Step 5: Assign Complexity and Model Routing

For each task, assign a complexity level that determines which model the execute phase will use:

| Complexity | Criteria | Model |
|------------|----------|-------|
| `standard` | 1-3 files, existing patterns, one system boundary, no new public contract | Sonnet |
| `complex` | 4+ files, 2+ system boundaries, new patterns/contracts, cross-cutting concerns, or high-risk modifications | Opus |

Use the QA Engineer's risk assessment and the Tech Lead's complexity hotspot analysis to inform this decision. When in doubt, mark as `complex` — it is better to over-allocate than to have a Sonnet implementer struggle with an architecture decision.

### Step 6: Validate CQ Coverage

Cross-check the task list against the QA Engineer's CQ Pre-Check table. Every activated CQ gate must be addressed by at least one task. If a gate is activated but no task covers it:
- Either add a dedicated task for it (e.g., "add validation middleware" for CQ3)
- Or add the requirement to an existing task's RED step (e.g., add an error-path test for CQ8)

### Step 7: Verify Completeness

Before finalizing, check:

| Check | Question | If no |
|-------|----------|-------|
| Spec coverage | Does every requirement in the spec map to at least one task? | Add missing tasks. |
| Coverage matrix | Does every `## Coverage Matrix` row map to at least one task, and does every task reference one or more row IDs? | Fix the matrix or the Acceptance fields. |
| Test coverage | Does every production file have a corresponding test task? | Add test tasks. |
| Dependency order | Can tasks be executed in the listed order without forward references? | Reorder. |
| Verification discipline | Does every Verify command prove the expected invariant by exit status? | Strengthen the command. |
| File limits | Does any task create a file estimated above `rules/file-limits.md` defaults (especially utils/helpers >100)? | Split the task. |
| CQ gate coverage | Is every activated CQ gate from the QA report addressed? | Add gate-specific steps to relevant tasks. |
| Independence | Can tasks with no listed dependencies truly run in any order? | If not, add the missing dependency. |
| Review trail readiness | Does the plan leave a `## Review Trail` section for reviewer + adversarial results? | Add it before finalizing. |

---

## Output

Produce the complete task breakdown following the plan document structure specified in the SKILL.md Phase 2 section. This becomes the core of the plan document.

Do not include the Architect, Tech Lead, or QA Engineer reports verbatim in the plan. Instead, condense their findings into the Architecture Summary, Technical Decisions, and Quality Strategy sections at the top of the plan.

The task breakdown section is the primary deliverable. Everything else in the plan exists to provide context for the implementer and reviewers.
