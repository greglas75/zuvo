# Playwright generation patterns

How `zuvo:write-e2e` decides what to assert, what to click it with, and what it is allowed
to call an end-to-end test. Gate IDs cited here are defined once, in `quality-gates.md`.
General test-quality rules that are not E2E-specific live in `../../../rules/testing.md`.

## Causality contract

Fill this in for every scenario BEFORE generating a single line of spec code. A scenario
that cannot be filled in is not ready to be generated -- that is a finding, not a blocker to
work around.

| Field | What goes here |
|-------|----------------|
| trigger | The user action that starts the scenario: click, submit, keypress, navigation |
| decisive event | The one thing that must actually happen for the feature to be working -- the mutation, the state transition, the request the app makes |
| pre-state | What is observably true BEFORE the trigger, asserted so a false pass is impossible |
| post-state | What is observably different AFTER the decisive event |
| visible oracle | The specific user-visible signal that proves the post-state -- the assertion the test lives or dies on |
| cleanup | What this scenario created or changed, and how it is undone |

Worked example, "create project":

```
trigger:        click "New project" then submit the form
decisive event: POST /api/projects creates a record
pre-state:      project list does not contain the run-unique project name
post-state:     project list contains it, and it survives a reload
visible oracle: expect(page.getByRole('listitem', { name: uniqueName })).toBeVisible()
cleanup:        delete the created project in afterEach, even on failure
```

Two rules make this contract worth filling in:

1. **The oracle must come after the decisive event, not after the trigger.** Asserting that
   a spinner appeared, or that the URL changed, proves the click was handled -- it does not
   prove the project exists. This is E2E-Q3.
2. **The pre-state assertion is not optional.** Without it, a test that asserts "the list
   contains Alpha" passes forever once any Alpha exists, including one left behind by a
   previous run.

## Oracle selection

A visible oracle is state a user could see and that only the decisive event could produce.

Counts as an oracle:

- The created, updated or deleted entity appearing or disappearing in the UI.
- A value rendered from server state that changes as a result of the mutation.
- An error message, empty state or disabled control that the app renders for the branch
  under test.
- A user-visible consequence that survives a reload, when the feature claims persistence.

Does NOT count as an oracle:

- URL alone, unless the route change IS the feature.
- Toasts and spinners on their own: they are fired by the client and stay green when the
  server call fails silently.
- A screenshot comparison used as the primary assertion (see Anti-patterns).
- The mocked response the test itself supplied. Asserting your own fixture back tests the
  mock, not the app.

**When there is no visible oracle, report a testability gap instead of writing a test.**
The report names the scenario, the decisive event, and what the app would need to render for
the behavior to be observable -- for example an error state that currently only appears in
the console. A weakened assertion that "at least tests something" is worse than no test: it
enters the suite as coverage and never fails when the feature breaks.

## Locator hierarchy

Strict preference order. Use the first one that identifies the element unambiguously:

1. `getByRole(role, { name })` -- accessible role plus accessible name. Default choice: it
   breaks when the element stops being reachable the way a user reaches it, which is
   exactly when the test should break.
2. `getByLabel(...)` -- form controls with an associated label.
3. `getByPlaceholder(...)` -- inputs with no label, as a stopgap; note the missing label as
   an accessibility finding.
4. Stable visible text -- `getByText`, `getByRole('button', { name })` on copy that is part
   of the product, not incidental wording.
5. `getByTestId(...)` -- ONLY when no semantic selector identifies the element, or when
   translated copy makes text and accessible names vary by locale. The spec records which
   of those two reasons applies.
6. CSS or XPath -- last resort, single element, never a descendant chain. Record why nothing
   above worked.

If a semantic locator would work but the element lacks the markup for it, the correct output
is a suggested markup improvement in the report, not a silent drop to a CSS selector. Never
modify production code to make a locator work without saying so.

### Confidence scoring is decoupled from testid presence

Flow confidence is HIGH when the route, the decisive event and the oracle are all confirmed
in the codebase. **HIGH confidence MUST NOT require a `data-testid` to be present**, and the
absence of testids MUST NOT downgrade a flow whose semantics are clear. The V1 scoring made
testids a confidence input, which quietly taught the generator that testid-first selectors
were the safe choice and inverted the hierarchy above.

| Confidence | Criteria |
|------------|----------|
| HIGH | Route confirmed, decisive event identified in code, a visible oracle exists |
| MEDIUM | Route and component confirmed, but the decisive event or the oracle is inferred |
| LOW | Surface exists with no observable user-facing outcome -- usually a testability gap |
| CONDITIONAL | Reachable only behind a feature flag, role or entitlement the run cannot set |

Testid availability affects only which locator is emitted and how the spec justifies it.

## Gray-box labeling

A spec is GRAYBOX when it does anything a user cannot: imports the app's store or reducers,
seeds state through an internal module, calls a private or admin-only route to arrange the
scenario, or asserts on internal state instead of rendered output.

Gray-box specs are allowed and often valuable. What they may never do is claim to be
end-to-end coverage. Labeling per E2E-Q9:

```typescript
// Generated by zuvo:write-e2e -- <date>
// GRAYBOX: seeds cart state via src/stores/cart directly (no UI path to a 50-item cart)
test('GRAYBOX: checkout totals for a 50-item cart', async ({ page }) => {
```

The registry row for such a flow is recorded as CHARACTERIZATION or GRAYBOX, so the coverage
report never counts it as a proven user journey.

## Cleanup and isolation

**E2E-Q6 -- cleanup for destructive operations -- is CRITICAL.** Any scenario that creates,
mutates or deletes state declares its cleanup in the causality contract and implements it in
a hook that runs even when the test body throws.

- Undo in `afterEach` (or a fixture teardown), never at the end of the test body: a failing
  assertion skips everything after it and leaves the residue behind.
- Prefer isolation over cleanup where the app allows it -- a fresh account, tenant or
  workspace per test needs no teardown and cannot collide across workers.
- Every created record carries a run-unique key, so a leaked record from a crashed run can
  be identified and never satisfies a later assertion (E2E-Q2).
- **Cleanup is best-effort and must never mask the original failure.** Teardown runs after a
  test that may already have failed, often against state the failure left half-built, so a
  throwing teardown converts one real failure into a cascade of teardown noise that buries
  the cause. Wrap each teardown step so one failure does not abort the rest, and report what
  could not be cleaned as a warning rather than re-throwing over the assertion that actually
  failed.
- Reporting is the point: a teardown wrapped in an empty catch turns a leak into silence.
  Best-effort means "keep going and say what broke", not "ignore it".

```typescript
test.afterEach(async () => {
  for (const undo of teardown.reverse()) {
    try {
      await undo();
    } catch (error) {
      // Warn, never throw: the original assertion failure is the one worth reading.
      console.warn(`cleanup step failed, possible leak: ${String(error)}`);
    }
  }
});
```

- Authentication state is set up once via `storageState` and reused; logging in inside every
  test is both slow and a shared-state hazard. This does not conflict with E2E-Q2 as long as
  the reused state stays a **read-only input**: the file is written once in a setup project
  and never mutated by a test. The moment tests mutate account-level state -- profile
  settings, entitlements, a shared cart -- the account itself is shared mutable state, and
  the fixture must become **per-worker**: one account and one `storageState` file per worker
  index, so parallel workers cannot observe each other's writes.

## Anti-patterns

| Anti-pattern | Why it is banned | Instead |
|--------------|------------------|---------|
| `page.waitForTimeout(n)` | A bet on machine speed: green locally, flaky on a loaded runner (E2E-Q1) | Web-first assertion on the post-state, or wait for the specific response |
| `waitForLoadState('networkidle')` | Never settles with polling, sockets or analytics; settles too early on a fast app (E2E-Q1) | Wait for the element or the response the action actually produces |
| CSS descendant chains such as `div > div:nth-child(3) span` | Breaks on any layout edit and communicates nothing about intent | A role or label locator, or a justified testid |
| Screenshot diff as the primary oracle | Fails on font rendering and passes on a broken mutation; it is a rendering check, not a causal one | Assert the post-state, keep screenshots as supplementary evidence |
| Asserting the mocked response back | Tests the fixture, not the app | Assert rendered state, and validate the request the app sent |
| Chained tests that depend on run order | One shard boundary or retry and the suite collapses (E2E-Q2) | Independent tests with their own setup and unique data |
| Giant single spec files | Decisive event and oracle drift hundreds of lines apart (E2E-Q10) | Split by journey and extract named step helpers |
