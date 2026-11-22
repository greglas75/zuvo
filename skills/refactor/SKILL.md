---
name: refactor
description: >
  Refactor existing code by extracting helpers, splitting files, removing
  duplication, or untangling dependencies. Supports resumable and batch runs.
  Use for structural changes that preserve behavior; use zuvo:build for new features.
category: Core
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    - search_symbols
    - get_symbol
    - get_symbols
    - get_file_outline
    - find_references          # KEY — impact analysis before changing signatures
    - trace_call_chain         # downstream effect of refactor
    - rename_symbol            # KEY — cross-file rename without manual Edit
    - find_dead_code           # remove what becomes unused after refactor
    - find_unused_imports      # post-refactor cleanup
    - find_clones              # extract-method opportunities
    - find_circular_deps       # break cycles is a common refactor goal
    - search_text
  by_stack:
    typescript: [get_type_info, resolve_constant_value]
    javascript: []
    python: [python_audit, analyze_async_correctness, resolve_constant_value]
    php: [php_project_audit, php_security_scan, resolve_php_namespace]
    kotlin: [analyze_sealed_hierarchy, find_extension_functions, trace_flow_chain, trace_suspend_chain, trace_compose_tree, analyze_compose_recomposition, trace_hilt_graph, trace_room_schema, analyze_kmp_declarations, extract_kotlin_serialization_contract]
    nestjs: [nest_audit]
    nextjs: [framework_audit, nextjs_route_map]
    astro: [astro_audit, astro_actions_audit, astro_hydration_audit, astro_middleware, astro_svg_components]
    hono: [analyze_hono_app, audit_hono_security]
    express: []
    fastify: []
    react: [react_quickstart, analyze_hooks, analyze_renders, analyze_context_graph, trace_component_tree]
    django: [analyze_django_settings, effective_django_view_security, taint_trace]
    fastapi: [trace_fastapi_depends, get_pydantic_models]
    flask: [find_framework_wiring]
    jest: []
    yii: [resolve_php_service, trace_php_event, find_php_views]
    prisma: [analyze_prisma_schema]
    drizzle: []
    sql: [sql_audit]
    postgres: [migration_lint]
---

# zuvo:refactor

Refactor the requested symbols while preserving their observed behavior. Resolve
`../../shared/includes/execution-policy.md` and `../../shared/includes/evidence-reuse.md` once.
Follow the user's current authorization, project verification rules and behavior scope.

## Argument Parsing

| Argument | Action |
|----------|--------|
| `<file(s)>` | Analyze and refactor this scope |
| `continue` | Resume the selected contract at its recorded phase |
| `batch <file>` | Load batch handling in `references/completion.md` and `../../shared/includes/refactor-reference.md` |
| `no-commit` | Finish verification; retain uncommitted work and report its location |
| Other documented flags | Resolve the full argument table in `references/bootstrap.md` |

## Mandatory File Loading

Load only the current phase reference below. Read its required includes when that phase needs
them; use the realpath/hash/context-generation receipt protocol in `evidence-reuse.md`. After
compaction reload current requirements; a persistent file ledger is not retained context.
Do not concatenate every phase at entry. Missing optional enrichment is a named degradation;
missing mandatory safety definitions blocks the dependent assessment.

## Phase routing

| Phase / contract boundary | Read on entry | Required outcome |
|---------------------------|---------------|------------------|
| 0: discovery | `references/bootstrap.md` | Current worktree, capabilities, gate install, scope and refactor type |
| 1: plan | `references/planning.md` | Callers, duplication, CQ baseline, behavior/symbol scope and contract |
| 2: characterize | `references/characterization.md` | Every moved unit exercised on pre-change code; use `../../shared/includes/regression-fence.md` |
| 3: transform | `references/transformation.md` | Planned move, targeted verification, independent CQ audit under policy |
| 3: review | `references/review.md` | Actual adversarial review of formatted final inputs; finding dispositions |
| 3.5–3.6: fix/audit | `references/remediation.md` | Authorized fixes with linked red/green runs; test-quality substage with parent evidence; mutation substage over the tests this run produced |
| 4: completion | `references/completion.md` | Shared verifier, content-keyed proof, required telemetry and concise result |

## Definition of Done

For preserve-behavior CQ and finding disposition, read `references/change-assessment.md`.

Characterization, CQ audit, adversarial review and remediation remain mandatory. Keep
provider requirements unchanged; size alone does not waive a safety gate. An audit that ran
inline is labeled with its actual independence. Under `preserve_behavior`, fix introduced
regressions and report unrelated existing risks with their original severity. Authorized existing
bugfixes require demonstrated red/green tests; green characterization rechecks are different proof.

Create v7 contracts with `~/.zuvo/refactor-contract init --file <src> --type <T>` (flags in
`../../shared/includes/refactor-reference.md`), never by hand; preserve v3–v6 records on resume.
Format before the final snapshot and review. Reuse completed test, mutation and review evidence
only for verified matching inputs and scope; never treat pending runs as PASS.
Stage explicit touched paths, not `git add -u`. Commits follow session policy and do not replace
quality completion. Full repository checks required before push remain required.

## Behavior mode

Default `preserve_behavior`. A bug in code you move moves verbatim: pin it with a test as current
behavior, name it in the first lines of the result, file it with `backlog-add`. Fix it in-run only
when the request itself says to fix, repair or correct a named defect or symbol ("fix it", "also fix
the X bug"); describing a bug, its severity or its size is not that request. Then `init
--behavior-mode refactor_and_fix --behavior-scope <symbol>`: that defect, and only it, is fixed as
a second commit with red/green proof; every other pre-existing finding stays baseline debt.

## Runs that cannot ask or write

Decide once, record it, finish; never ask, never forge a stage.

- No native mutation runner, or an install needing consent nobody can give: `prove.mutation =
  not_run:no-native-runner` or `not_run:no-consent` (a `check` WARN). No free-text `N/A`.
- `.git` not writable: `no-commit` with `commit_execution` set (`references/bootstrap.md` probe); an
  accepted end state.

## Result

```bash
~/.zuvo/refactor-contract --contract <this-run-contract.json> check
```

The exit status is the hook predicates; do not recreate them. The result opens with:

```
REFACTOR <COMPLETE|UNCOMMITTED|PARTIAL|BLOCKED>
Gate: refactor-contract check exit=<n>
```

- `n=0`, committed: `COMPLETE`. `n=0`, `no-commit` (flag or `commit_execution`): `UNCOMMITTED`, contract
  `stage EXECUTION_COMPLETE` (the CLI records it as PHASE-3.5), with the exact worktree and diff path.
- `n≠0`: never COMPLETE or UNCOMMITTED: `PARTIAL` (work finished, name each unmet gate) or `BLOCKED`.
  The CLI refuses `stage COMPLETE` then, and `set stage` always.

Then: checks run, unresolved risks, publish readiness, commit and file links. Receipt, CQ matrix
and finding ledger go in artifacts; `../../shared/includes/run-logger.md` and
`../../shared/includes/retrospective.md` run once.
