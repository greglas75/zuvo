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

### Step 4: Write the RED-GREEN Steps

For each task, write the exact code that the implementer will produce.

**RED step (failing test):**
- Write the complete test. Include imports, describe block, test name, setup, action, and assertion.
- The test must fail before the production code exists (missing import, missing function, wrong return value).
- Use the test conventions identified by the QA Engineer (framework, naming, directory).
- Include the edge cases and error paths identified by the QA Engineer for this component.

**GREEN step (production code):**
- Write the minimum code that makes the RED test pass.
- Follow the patterns selected by the Tech Lead.
- Reuse the existing code identified by the Tech Lead (do not reimplement what already exists).
- Respect file size limits: services at most 300 lines, components at most 200 lines.

**Verify step:**
- Write the exact shell command to run the tests. Example: `npx vitest run src/services/order.service.test.ts`
- Write the expected output. Example: `Tests: 3 passed, 3 total`
- If the verification involves more than just tests (e.g., type checking, linting), include those commands too.

**Commit step:**
- Write a commit message that describes the behavior added, not the files changed.
- Example: "add order validation that rejects negative quantities and empty item lists"

### Step 5: Assign Complexity and Model Routing

For each task, assign a complexity level that determines which model the execute phase will use:

| Complexity | Criteria | Model |
|------------|----------|-------|
| `standard` | 1-3 files, clear spec, follows existing patterns, no architecture decisions | Sonnet |
| `complex` | 4+ files, new patterns, cross-cutting concerns, high-risk modifications, design decisions | Opus |

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
| Test coverage | Does every production file have a corresponding test task? | Add test tasks. |
| Dependency order | Can tasks be executed in the listed order without forward references? | Reorder. |
| File limits | Does any task create a file estimated at >300 lines (service) or >200 lines (component)? | Split the task. |
| CQ gate coverage | Is every activated CQ gate from the QA report addressed? | Add gate-specific steps to relevant tasks. |
| Independence | Can tasks with no listed dependencies truly run in any order? | If not, add the missing dependency. |

---

## Output

Produce the complete task breakdown following the plan document structure specified in the SKILL.md Phase 2 section. This becomes the core of the plan document.

Do not include the Architect, Tech Lead, or QA Engineer reports verbatim in the plan. Instead, condense their findings into the Architecture Summary, Technical Decisions, and Quality Strategy sections at the top of the plan.

The task breakdown section is the primary deliverable. Everything else in the plan exists to provide context for the implementer and reviewers.
