# Flow discovery, scoring and confidence

Phase 0 and Phase 1 of `zuvo:write-e2e`: find the testable surfaces, turn them into candidate
user journeys, rank them, and label how sure the run is about each one. Nothing here writes a
file -- the output is a ranked list plus the reasons behind it.

Discovery uses the code index when it is available; set it up per
`../../../shared/includes/codesift-setup.md` and fall back to repository search when it is not.
How a flow is turned into a spec -- the causality contract, oracle selection and the locator
hierarchy -- lives in `playwright-patterns.md` and is NOT restated here.

## Discovery targets

Scan the scope for two layers: raw artifacts (what exists) and candidate flows (what a user
could do with them).

| Target | What to find |
|--------|--------------|
| Routes | Every navigable path under `app/`, `pages/`, `src/routes/`, or the framework's router config |
| Interactive components | Page-level forms, modals, dialogs, multi-step wizards |
| API endpoints | Route handlers, especially POST/PUT/PATCH/DELETE mutations |
| Auth system | Login route, guard patterns, session and storage mechanism |
| Existing E2E | Inventory of journeys already covered by spec files, so coverage is not duplicated |

Run route discovery and coverage analysis in parallel; both must finish before scoring, because
"already covered" is a scoring input, not an afterthought.

A candidate flow is a route plus a decisive event plus an outcome a user could observe. A route
with no decisive event is a page, not a flow -- it scores as navigation at best.

## Scoring: five weighted signals

Each candidate flow is scored 0-100 on five signals. The weights encode one judgment: a broken
mutation costs more than a broken page.

| Signal | Weight | Detection |
|--------|--------|-----------|
| Mutation type | 30 | POST/PUT/PATCH/DELETE handler, form `onSubmit`, mutation hook, server action |
| Auth requirement | 20 | Route guard, auth middleware, session check, role or entitlement gate |
| Data sensitivity | 20 | Payment, billing, credentials, personal data, deletion, admin surfaces |
| User traffic proxy | 15 | Primary navigation links, route depth, how many places link to it |
| Existing coverage | 15 | Already has an E2E spec? yes = 0, no = 15 |

Scores are reported with their inputs. "auth/login 92" is unreviewable; "auth/login 92
(mutation 30, auth 20, sensitivity 20, traffic 15, uncovered 15)" can be argued with.

## Score tiers

| Range | Tier | Behavior |
|-------|------|----------|
| 70-100 | CRITICAL | Generate first |
| 40-69 | IMPORTANT | Generate when within the flow budget |
| 15-39 | NICE-TO-HAVE | Generate only on explicit selection |
| 0-14 | SKIP | Static pages, dev-only routes, redirects with no user-visible outcome |

## Flow budget

Volume is a safety property: twenty unreviewed specs are worse than one that is trusted.

| Invocation | Flows generated |
|------------|-----------------|
| A named flow or a scoped request | 1 |
| Bare `--auto` | 3, highest score first |
| `--flows` or an explicit `--max-flows N` | up to N (this is the only path to a large batch) |

Print the ranked list with score, confidence and the one-line reason before generating, so the
selection can be corrected before any file is written.

## Confidence assignment

Confidence describes how well the run understands the flow. It is independent of the score: a
CRITICAL flow can be MEDIUM confidence, and that combination is exactly the one worth telling
the user about.

| Level | Criteria |
|-------|----------|
| HIGH | Route confirmed, decisive event identified in the code, a user-visible oracle exists |
| MEDIUM | Route and component confirmed, but the decisive event or the oracle is inferred |
| LOW | Surface exists with no observable user-facing outcome -- usually a testability gap |
| CONDITIONAL | Reachable only behind a feature flag, role or entitlement this run cannot set |

**Confidence must not require a `data-testid`, and the absence of test IDs must not downgrade
a flow whose semantics are clear.** V1 made HIGH conditional on test IDs being present, which
taught the generator that test-ID selectors were the safe default and quietly inverted the
locator hierarchy in `playwright-patterns.md`. Markup affects which locator is emitted and how
the spec justifies it -- never how well the flow is understood.

## Failure handling

| Condition | Response |
|-----------|----------|
| No routes found | `ABORT: no routes detected -- is this a web application?` |
| Routes but no interactive flows | Report the count and offer navigation-only coverage explicitly |
| Auth detected but not automatable | Warn: no programmatic login path found; generated specs will be unauthenticated |
| Monorepo without a scope | List the detected apps and ask for a scope instead of picking one |
| Nothing selected | Stop. An empty selection is a valid answer, not a reason to fall back to `--auto` |

## Exit points

- `--flows`: print the scored, confidence-labeled list and STOP. Nothing is written.
- `--dry-run`: continue through the scaffold plan (see `scaffold.md`) and STOP before writing
  any file.
