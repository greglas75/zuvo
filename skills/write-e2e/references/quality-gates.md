# E2E Quality Gates -- E2E-Q1 through E2E-Q10 (V2)

**This file is the authoritative definition of the E2E-Q gate set.** Nothing else in the
repo re-states these rows: `../../../shared/includes/gate-registry.md` carries a pointer to
this file, and `zuvo:write-e2e` loads this file when it scores a generated spec. If a gate
needs to change, it changes here and nowhere else.

Severity words used below follow `../../../shared/includes/severity-vocabulary.md`.
Generation guidance that is *not* a gate -- locator policy, oracle selection, gray-box
labeling mechanics, cleanup helpers -- lives in `playwright-patterns.md` and
`network-mocking.md`. Those files cite gate IDs; they never redefine them.

## How to read the table

- **Critical** -- every gate in the V2 set is critical. A failing critical gate means the
  spec is NOT shippable: fix it in-run, or emit the spec in a blocked state with the
  failure recorded. "Flag it and move on" is not an outcome for any row here.
- **Auto-fixable** -- `Yes` means the fix is mechanical and the skill applies it without
  asking. `Partial` means the skill can rewrite the obvious shape but a human decision may
  remain. `No` means the gate can only be satisfied by changing what the test asserts, so
  the skill reports and stops rather than guessing.
- **Evidence format** -- what must appear in the run's gate report for the row to count as
  checked. A gate with no evidence line is treated as NOT RUN, which fails the same way a
  violation does.

## The gates

| Gate | What it checks | Critical | Auto-fixable | Evidence format |
|------|----------------|----------|--------------|-----------------|
| E2E-Q1 | No arbitrary waits -- no `waitForTimeout`, no `waitForLoadState('networkidle')`, no polling sleeps; every wait is a web-first assertion or a response wait tied to the action | Yes | Yes | `E2E-Q1 FAIL spec:line -- waitForTimeout(2000) -- replaced with expect(locator).toBeVisible()` |
| E2E-Q2 | Test independence and unique data -- no shared mutable module state, no ordering dependency between tests, and every record the test creates carries a run-unique key | Yes | Partial | `E2E-Q2 PASS spec:line -- data factory seeds email with a per-run unique suffix` |
| E2E-Q3 | Causal oracle -- the decisive assertion runs AFTER the decisive event and observes state that only the event under test could have produced | Yes | No | `E2E-Q3 FAIL spec:line -- asserts URL only; decisive event is order creation, no post-state observed` |
| E2E-Q4 | Fail-closed network policy -- unrouted requests are denied, the allow-list is explicit, and no broad directory glob is used as a route pattern | Yes | Partial | `E2E-Q4 FAIL spec:line -- route pattern is a directory glob; unrouted hosts reachable` |
| E2E-Q5 | Mutation contract validation -- every intercepted mutation asserts on the request body, query and the headers the server actually depends on, not just on the URL | Yes | No | `E2E-Q5 PASS spec:line -- POST body asserted for 3 required fields plus idempotency header` |
| E2E-Q6 | Cleanup for destructive operations -- anything created, mutated or deleted is undone or isolated, in a hook that runs even when the test body throws | Yes | Partial | `E2E-Q6 FAIL spec:line -- creates a project, no afterEach teardown` |
| E2E-Q7 | Runner and browser version compatibility -- the generated spec only uses APIs present in the project's pinned Playwright version, and browsers are the ones the pinned runner installs | Yes | Yes | `E2E-Q7 PASS -- @playwright/test 1.49.1 pinned; no API newer than 1.49 used` |
| E2E-Q8 | No external mutation flows without explicit consent -- a spec that mutates state against a non-local origin exists only with a recorded consent decision naming that origin | Yes | No | `E2E-Q8 FAIL -- origin classified EXTERNAL_UNKNOWN and spec performs a POST; no consent recorded` |
| E2E-Q9 | Gray-box explicitly labeled -- a spec that reaches into internal stores, app state or private routes is labeled CHARACTERIZATION or GRAYBOX in its title and header, never presented as pure end-to-end | Yes | Yes | `E2E-Q9 PASS spec:line -- title prefixed GRAYBOX; header records the internal import` |
| E2E-Q10 | Spec size limit and helper extraction -- a spec file stays under the size limit and repeated multi-step sequences are extracted into named helpers instead of copy-pasted | Yes | Partial | `E2E-Q10 FAIL spec -- 412 lines over the 300-line limit; login sequence repeated 4 times` |

## Per-gate notes

### E2E-Q1 -- no arbitrary waits

A fixed sleep is a bet on machine speed. It fails on a loaded CI runner and passes locally,
which is the single most common source of "flaky" E2E suites. `networkidle` is banned for
the same reason plus a worse one: on an app with polling, websockets or analytics beacons it
never settles, and on a fast app it settles before the interesting request even starts.
Replacement is always one of: a web-first assertion on the post-state, `waitForResponse`
scoped to the request the action triggers, or `waitFor` on the specific element state.

### E2E-Q2 -- independence and unique data

Two failures hide here. Ordering dependency: test B only passes because test A ran first,
so a shard boundary or `--repeat-each` breaks it. Data collision: two workers, or two runs
of the same suite, create the same `test@example.com` and the second one fails on a
uniqueness constraint. Unique data means a per-run suffix generated inside the test, not a
constant the author promises to remember to change.

### E2E-Q3 -- causal oracle

See `playwright-patterns.md` -> Causality contract for the field list the author fills in
before generation. The gate itself is narrow: find the decisive event, find the assertion
that proves it happened, and check that the second observes something the first uniquely
causes. An assertion that would pass with the feature deleted is not an oracle. If the app
exposes no such visible state, the correct output is a testability gap report, not a weaker
assertion.

### E2E-Q4 / E2E-Q5 -- network policy and mutation contracts

Both are defined in detail in `network-mocking.md`. Q4 is about what the test is allowed to
talk to; Q5 is about what the test proves when it intercepts a mutation. A spec that routes
everything through a permissive handler and asserts only on the response it invented tests
the mock, not the app.

### E2E-Q6 -- cleanup

Cleanup wording lives in `playwright-patterns.md` -> Cleanup and isolation. The gate fails on
an uncleaned destructive operation even when the test passes, because the cost lands on the
next run, not this one.

### E2E-Q7 -- runner and browser compatibility

Generated specs frequently use an API that only exists in a newer Playwright than the
project pins, which surfaces as a confusing type error or a runtime "not a function". The
gate reads the pinned version from the project's lockfile or `package.json` and rejects
newer APIs. It also rejects an implicit browser download: the runner that is installed is
the runner that is used.

### E2E-Q8 -- external mutation consent

Origin classification is LOCAL, STAGING or EXTERNAL_UNKNOWN. Read-only specs are allowed
against any origin. A mutating spec against anything other than LOCAL requires a consent
decision that names the origin. The gate fails closed: an unclassified origin is treated as
EXTERNAL_UNKNOWN, never as staging.

### E2E-Q9 -- gray-box labeling

A test that imports the app's store, seeds internal state or calls a private route can be a
legitimate and valuable test. What it cannot be is silently counted as end-to-end coverage,
because it no longer proves the user-visible path works. Labeling is mechanical, so this
gate is auto-fixable: the spec title gets the prefix and the generated header records which
internal surface it touched.

### E2E-Q10 -- spec size and helper extraction

Oversized specs are where causality gets lost: the decisive event ends up 200 lines from the
assertion that is supposed to prove it. The limit follows the project's own file limits
where one exists, otherwise the default in `../../../rules/file-limits.md`. Extraction target
is a named helper that reads as a step in the journey, not a grab-bag utility.

## Reporting

Every run emits one evidence line per gate per spec, in the format in the table. The summary
counts gates, not specs:

```
E2E QUALITY GATES -- <spec path>
  checked: 10/10   passed: N   failed: M   auto-fixed: K
  <one evidence line per gate>
```

A missing evidence line is a NOT RUN and is reported as a failure, so a truncated or skipped
gate pass can never be read as a clean bill.
