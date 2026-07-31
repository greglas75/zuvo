---
name: write-e2e
description: >
  Generate Playwright E2E tests from codebase analysis. Discovers routes,
  scores user flows by criticality, writes .spec.ts files that assert
  causality, and reports what was actually proven: GENERATED,
  STATIC_CHECKED, VERIFIED_LOCAL or VALIDATED_LIVE. Modes: --scope <path>,
  --flow <name>, --output <dir>, --base-url <url>, --max-flows N, --live,
  --auto, --flows, --dry-run.
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    - trace_route              # KEY — route discovery (any framework)
    - get_file_tree            # find pages/components/routes/
    - search_text
    - search_symbols
    - get_file_outline
    - search_patterns          # form / link / button conventions to seed flows
  by_stack:
    typescript: [get_type_info]
    javascript: []
    python: [python_audit, analyze_async_correctness]
    php: [php_project_audit, php_security_scan, resolve_php_namespace]
    kotlin: [analyze_sealed_hierarchy, find_extension_functions, trace_flow_chain, trace_suspend_chain, trace_compose_tree, analyze_compose_recomposition, trace_hilt_graph, trace_room_schema, analyze_kmp_declarations, extract_kotlin_serialization_contract]
    nestjs: [nest_audit]
    nextjs: [framework_audit, nextjs_route_map]
    astro: [astro_audit, astro_actions_audit, astro_hydration_audit]
    hono: [analyze_hono_app, audit_hono_security, visualize_hono_routes]
    express: []
    fastify: []
    react: [react_quickstart, analyze_hooks, analyze_renders, trace_component_tree]
    django: [analyze_django_settings, effective_django_view_security, taint_trace]
    fastapi: [trace_fastapi_depends, get_pydantic_models]
    flask: [find_framework_wiring]
    jest: []
    yii: [resolve_php_service, find_php_views]
    prisma: [analyze_prisma_schema]
    drizzle: []
    sql: [sql_audit]
    postgres: [migration_lint]
---

# zuvo:write-e2e — E2E Test Generation

Discover routes and user flows, rank them by criticality, generate Playwright specs that assert causality, and — when
the project can actually run Playwright — execute them and report exactly what was proven; a spec is a draft until a
state on the verification ladder says otherwise. **Scope:** web apps with routes, forms, interactions. **Out of
scope:** unit tests (`zuvo:write-tests`), a suite audit (`zuvo:test-audit`), flaky specs (`zuvo:fix-tests`).

## Argument Parsing

Parse `$ARGUMENTS` as: `[--scope <path>] [--flow <name>] [--output <dir>] [--base-url <url>] [--max-flows N] [--live] [--auto] [--flows] [--dry-run]`

| Argument | Mode | Flows | Description |
|----------|------|-------|-------------|
| `--scope <path>` | SCOPED | 1 | Restrict discovery to one app root, directory or route file |
| `[path]` | SCOPED | 1 | Deprecated positional alias for `--scope` — accepted, but prefer `--scope <path>` |
| `--flow <name>` | NAMED | 1 | Generate exactly the named flow |
| `--output <dir>` / `--base-url <url>` | OUTPUT / TARGET | — | Write specs under `<dir>` instead of the detected E2E root / name the origin the specs target, classified in Phase 0.5 before any request |
| `--max-flows N` | LIMIT | N | Explicit flow budget — the only way to ask for a large batch, 20 included |
| `--live` | LIVE | — | Permit live DOM/locator inspection against a permitted origin |
| `--auto` | AUTO | 3 | Skip the selection prompt; take the highest-scored flows |
| `--flows` / `--dry-run` | DISCOVER / PREVIEW | 0 | Print the scored list and stop / plan through scaffold and write nothing |

Volume is a safety property: scoped or named requests generate 1 flow, bare `--auto` generates 3, and a large batch
happens only when a human asks by name (`--max-flows 20`) — 20 is never assumed. Codex and Cursor always behave as
`--auto`, so a 20-flow default let a non-interactive host emit twenty unreviewed specs with nobody deciding to.

## Mandatory File Loading

Load at start, MISSING -> STOP: `../../rules/testing.md`, `../../rules/file-limits.md`,
`../../shared/includes/run-logger.md`, `../../shared/includes/env-compat.md`,
`../../shared/includes/codesift-setup.md`, `../../shared/includes/knowledge-prime.md` (`WORK_TYPE =
"implementation"`), `../../shared/includes/knowledge-curate.md`, `../../shared/includes/retrospective.md`. The six
references are LAZY — load each when its phase begins, never all at start:

- Phase 0, Phase 0.5, Phase 4 — `references/live-validation.md`: preflight states, origin classes, consents, validation states, triage, registry
- Phase 1 — `references/discovery-and-scoring.md`: discovery targets, five weighted signals, tiers, flow budget, confidence
- Phase 2 — `references/scaffold.md`: write policy, output structure, page-object threshold, auth fixture, ID suggestions
- Phase 3, per scenario — `references/playwright-patterns.md`: causality contract, oracles, locator hierarchy, gray-box labels, cleanup
- Phase 3, when a spec touches the network — `references/network-mocking.md`: fail-closed policy, match key, allowed-host list, mutation contracts
- Phase 3, after each spec is written — `references/quality-gates.md`: E2E-Q1..E2E-Q10, all critical, with evidence formats

## Agent Routing

| Agent | Purpose | Model | Type | Phase |
|-------|---------|-------|------|-------|
| Route Discoverer | Routes, components, API endpoints, auth patterns | Sonnet | Explore | 1 (parallel) |
| Coverage Analyzer | Existing specs, already-covered flows | Haiku | Explore | 1 (parallel) |
| Test Writer | Generate specs for a flow batch | Sonnet | Code | 2-3 |

## Phase 0: Preflight — can Playwright run here

Load `references/live-validation.md` and ask the helper, never guess: when `$HOME/.zuvo/e2e-preflight` is executable,
`~/.zuvo/e2e-preflight probe <scope>` prints exactly one of READY, GENERATE_ONLY or BOOTSTRAP_REQUIRED on stdout,
reasons on stderr.

Helper absent (a Codex-only or Cursor-only install never ran `install_zuvo_home`) — reproduce the SAME three states, READY / GENERATE_ONLY / BOOTSTRAP_REQUIRED, from the four signals in that reference: config, dependency, runnable local binary, browser cache. Never invent a fourth outcome, never read a missing helper as READY, and never probe through unpinned `npx playwright`, which installs the thing it claims to detect.

- **READY** — generate AND execute locally; `VERIFIED_LOCAL` is reachable.
- **GENERATE_ONLY** — generate and static-check only; the ceiling is `STATIC_CHECKED`, and the report says so.
- **BOOTSTRAP_REQUIRED** — generate, then PRINT the exact install command for the user to run. Installing is a conscious human decision; this run never installs anything.

Also detect the CodeSift index (else repository search), Playwright MCP (which gates live DOM inspection ONLY — a
local `playwright test` run needs no MCP), the framework and the auth provider, then print `PREFLIGHT: <state>
| CODESIFT: <..> | MCP: <..> | STACK: <..> | AUTH: <..>`.

## Phase 0.5: Origin gate — every run that executes anything

Load `references/live-validation.md` and resolve the EFFECTIVE base URL before a single request: `--base-url` when
given, otherwise the project's own `playwright.config.*` (`use.baseURL`, and the `webServer.url` a run would start). A
default, flagless run executes against whatever that config points at — staging or production included — so it is
classified exactly like a `--live` run: `Origin: LOCAL | STAGING | EXTERNAL_UNKNOWN`:

- **LOCAL** — matches the local shape AND resolves to a permitted local destination; a name is never evidence about where traffic lands.
- **STAGING** — explicit only: `--allow-external-origin`, or an exact `ZUVO_E2E_STAGING_HOSTS` match. No hostname heuristics; adding one is a defect.
- **EXTERNAL_UNKNOWN** — everything else, including hosts that merely look internal: read-only specs, and every mutating step is BLOCKED rather than warned about.

Two consents, never one: `--allow-external-origin` permits reaching a non-local origin read-only, `--allow-destructive
<ops>` authorizes the named mutating operations. A resolved baseURL classified STAGING or EXTERNAL_UNKNOWN takes that
same path whether or not `--live` was passed — read-only under the first consent, mutations only under the second,
otherwise the run BLOCKS before executing anything. Classification is continuous — redo it on every navigation and
redirect hop, and fail loudly on a transition into EXTERNAL_UNKNOWN instead of degrading into a quiet read-only run.

## Phase 1: Discover and score

Load `references/discovery-and-scoring.md`. Run route discovery and coverage analysis in parallel — both finish before
scoring, because "already covered" is a scoring input. Score each candidate on the five weighted signals (mutation 30,
auth 20, sensitivity 20, traffic 15, uncovered 15) and label its confidence, which measures how well the flow is
understood and never how the markup is written. Print the ranked list with score, confidence and a one-line reason,
apply the flow budget, then take the selection. `--flows` stops here; `--dry-run` continues to the Phase 2 plan and
stops before writing.

## Phase 2: Scaffold

Load `references/scaffold.md`. New specs, fixtures and page objects are written directly; `playwright.config.*`
changes are proposed, never auto-written; existing test files are never modified; production source is never edited to
make a test pass, so suggested test IDs stay suggestions. `--output <dir>` overrides the detected E2E root, and an E2E
layout the project already has wins over the default tree.

## Phase 3: Generate

For each selected flow, in this order:

1. **Causality contract first** — `references/playwright-patterns.md`: trigger, decisive event, pre-state,
   post-state, visible oracle, cleanup, filled in BEFORE any spec code. A scenario that cannot be filled in is a
   testability-gap finding, not something to improvise around, and specs reaching into internals are labeled
   CHARACTERIZATION/GRAYBOX.
2. **Network policy** — `references/network-mocking.md` whenever the spec touches the network: fail-closed
   default, hostname+method+pathname match key, an explicit allowed-host list, mutation body/query/header
   validation, and no broad directory globs.
3. **Gate check** — `references/quality-gates.md`: score each spec against E2E-Q1..E2E-Q10. All ten are
   critical — fix in-run, or emit the spec BLOCKED with the failure recorded. Every gate needs an evidence
   line; a gate with no evidence counts as NOT RUN.

### Phase 3.5: Adversarial Review (MANDATORY — do NOT skip)

```bash
# Scoped review patch on stdout — the git index is NEVER touched (no staging).
# PATH args = the E2E specs and fixtures this run wrote.
# Quote each SEPARATELY — never one space-joined string or a bare $FILES: zsh does
# not word-split an unquoted expansion, so the helper gets the whole list as ONE
# path, matches nothing and exits 2. Use "${FILES[@]}" for an array.
# With NO PATH args the helper reviews the WHOLE dirty tree, untracked files
# included, and that content is sent to the external providers — always scope it.
# `|| _prc=$?` (never `; _prc=$?`): under `set -e` the plain form aborts the shell
# at the assignment, so exit 3 and the BLOCKED branch would never be reached.
# The BLOCKED branch ends in `false`, so the block's own exit status is non-zero:
# printing alone lets a `set -e` / `if ! …` caller sail past a review that never
# ran. `false`, not `exit`, so an inlining caller's shell is not killed.
if [ -x "$HOME/.zuvo/build-review-patch" ]; then
  _prc=0; _patch=$("$HOME/.zuvo/build-review-patch" "<spec-file-1>" "<fixture-file>") || _prc=$?
  if [ "$_prc" -eq 3 ]; then echo "adversarial review: skipped (no changes)"
  elif [ "$_prc" -ne 0 ]; then echo "BLOCKED: build-review-patch failed (rc=$_prc). Adversarial review did NOT run; do NOT proceed to commit and do NOT report this skill complete" >&2; false
  else printf '%s\n' "$_patch" | adversarial-review --mode test; fi
else
  adversarial-review --mode test --files "<changed files>"
fi
```

Not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`. Wait for complete
output, then act on findings: **CRITICAL** — fix immediately regardless of confidence, verifying against the code
first when confidence is low; **WARNING** — fix if localized (< 10 lines), else backlog with file:line; **INFO** —
record, max 3. Confidence measures how sure the reviewer is, not how important the issue is, and "pre-existing" is no
reason to skip a finding in a file this run is already editing.

## Phase 4: Verification ladder

Load `references/live-validation.md`. A flow carries exactly ONE state, earned by evidence:

| State | Earned by | Requires |
|-------|-----------|----------|
| GENERATED | the spec was written; nothing executed or parsed | — |
| STATIC_CHECKED | it parses/typechecks/lints clean and passes the E2E-Q gates | always attempted |
| VERIFIED_LOCAL | executed green with `playwright test` | preflight READY AND the Phase 0.5 classification of the resolved baseURL is LOCAL — no MCP |
| VALIDATED_LIVE | executed green with live DOM/locator inspection confirming the oracles | `--live` + Playwright MCP + an origin Phase 0.5 permits |
| BLOCKED | an origin, consent or preflight gate refused the work | a stop, never a pass |
| FAILED | executed and went red | triage, never hide |

When evidence is missing, record the LOWER state — a spec nobody ran is GENERATED however confident this run feels,
and there is no "skipped" state. Triage red runs by category (locatorMiss / timing / data / auth / backend), which
this skill diagnoses and does not auto-fix.

## Artifact Contract

State lands in `memory/e2e-coverage.md`, which carries a `State` column. Row shape, exactly what the helper writes:
`| Flow ID | Name | Score | Confidence | Status | Spec File | Last Updated | State |`. Write it with
`"$HOME/.zuvo/e2e-preflight" coverage-upsert --file memory/e2e-coverage.md --flow <id> --state <STATE> --spec <path>
--score <N> --confidence <LEVEL>`; when that helper is absent (the same Codex-only or Cursor-only install as Phase 0)
append the row by hand in that exact format, so the table stays machine-readable and the completion gate stays
satisfiable — the helper is never a prerequisite. A legacy row with no `State` cell reads as GENERATED, never back-filled.

## Knowledge Curation and Retrospective (REQUIRED)

Run the curation protocol from `knowledge-curate.md` (`WORK_TYPE = "implementation"`, `CALLER = "zuvo:write-e2e"`,
`REFERENCE = <git SHA>`), then the retrospective protocol from `retrospective.md` (gate check
-> questions -> TSV emit -> markdown append); if it skips, print `RETRO: skipped (trivial session)` and proceed.

## Completion Gate Check and Report

```
COMPLETION GATE CHECK
[ ] Preflight state printed; effective baseURL resolved and its origin classified before anything executed
[ ] Scored flow list printed with confidence and reasons; E2E-Q1..E2E-Q10 evidenced on every spec
[ ] Adversarial review ran (--mode test); every flow carries exactly one verification state
[ ] memory/e2e-coverage.md upserted via the helper, or hand-written in the row shape when it is absent
[ ] Run: line printed and appended to log

WRITE-E2E COMPLETE
Preflight: [READY | GENERATE_ONLY | BOOTSTRAP_REQUIRED]   Origin: [LOCAL | STAGING | EXTERNAL_UNKNOWN | n/a]
Flows:     [N] generated ([M] high, [K] medium) | [X] spec + [Y] fixture files | gates [N]/[N] evidenced
States:    [a] STATIC_CHECKED, [b] VERIFIED_LOCAL, [c] VALIDATED_LIVE, [d] BLOCKED, [e] FAILED
Run: <ISO-8601-Z>	write-e2e	<project>	-	<Q>	<VERDICT>	<TASKS>	<DURATION>	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
```

**Append via wrapper (REQUIRED).** Never `>>` directly to `~/.zuvo/runs.log` — the wrapper is the gate that verifies a
retro entry exists for this run. Order: retro bash executed → wrapper invoked → completion claimed, via `printf '%b\n'
"$RUN_LINE" | ~/.zuvo/append-runlog`, which must print `OK: appended to runs.log (retro verified for <skill> on
<project>)`. On exit 2 with `RETRO_REQUIRED`, execute the retro bash from `retrospective.md` first; never bypass with
`ZUVO_SKIP_RETRO_GATE=1`. After it succeeds, print a `Logs:` evidence line (`tail -1 ~/.zuvo/retros.log`, `grep -c
"^<!-- RETRO -->" ~/.zuvo/retros.md`, `tail -1 ~/.zuvo/runs.log`). `<DURATION>`: `N-flows`; `<Q>`: gate score or `-`;
`<TASKS>`: spec files written.
