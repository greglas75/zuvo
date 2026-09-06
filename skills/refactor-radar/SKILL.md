---
name: refactor-radar
description: >
  Select refactor candidates with immutable git measurements, evidence-backed module
  families and temporary collision checks. Use for ranked refactor/test-debt triage,
  not implementation. DISCOVER saves reports without changing product code; REGISTER
  requires validated decisions. Worktree names are hints, test LOC is not coverage,
  and discovery scores are not execution priorities.
category: Core
codesift_tools:
  always:
    - analyze_project
    - index_status
    - plan_turn
    - search_symbols
    - find_references          # KEY — G1: is the candidate alive?
    - get_file_outline
    - analyze_complexity       # cross-check of the builtin engine on the top candidates
    - find_circular_deps       # G5: cycles through the family
    - fan_in_fan_out           # G5: hub detection (HUB-SPLIT class)
    - find_clones              # DEDUPE class: same shape across a family
    - search_text
  by_stack:
    typescript: [get_type_info]
    javascript: []
    python: [python_audit]
    php: [php_project_audit]
    kotlin: [analyze_sealed_hierarchy]
    nestjs: [nest_audit]
    nextjs: [nextjs_route_map]
    astro: [astro_route_map]
    hono: [detect_hono_modules]
    express: []
    fastify: []
    react: [trace_component_tree]
    django: []
    fastapi: []
    flask: []
    jest: []
    yii: []
    prisma: []
    drizzle: []
    sql: []
    postgres: []
---

# zuvo:refactor-radar

Decide WHAT is worth changing before `zuvo:refactor` decides HOW. Start with deterministic
discovery, validate the evidence, then propose bounded work. Never turn a ranked row into
an authorized refactor automatically.

## Modes and boundaries

- **DISCOVER (default):** read code, metadata and existing decisions; **save the raw results
  and the ranked report**, then link them in the answer. Saving these requested deliverables
  needs no extra approval and is not REGISTER. No product edits, queue, ledger, history,
  reservation, dependency install, commit or PR. An authorized farm run may stage a private,
  disposable `--prepare-farm` job; disclose its location. Explicit chat-only/no-file-write
  requests (`--no-save`) and `--dry-run` suppress report files; do not ask users to opt in.
- **REGISTER:** only when asked to save approved work; validate G1–G5, write a new queue
  and, if requested, append decisions/history. This does not reserve files or start work.
- **EXECUTE:** a separate request routed to `zuvo:refactor` or `zuvo:write-tests`.
  Recheck SHA, reservations and tests immediately before editing.

A worktree is disposable execution infrastructure, not a product, candidate or historical
identity. Use canonical repo ID + commit SHA + relative paths. Current worktree diffs can
warn about conflicts; a branch name alone is only a hint. Never retain a vanished directory
as a permanent exclusion, or infer FREE just because it vanished: check PRs/contracts.

## Argument Parsing

| Input | Meaning |
|-------|---------|
| `[path]` | Map to script `--scope <repo-relative path>`; keep complete families intersecting it |
| `--top N` | Requested final rows, default 50; fewer validated candidates is a valid result |
| `--validate N` | Agent-side investigation budget, default min(3 × top, 60); not a script flag |
| `--mode refactor\|tests` | Same discovery signals; tests mode suggests COVER, never infers coverage from LOC |
| `--ref <ref>`, `--cutoff <ISO timezone>` | Freeze code SHA and history window, including for HEAD |
| `--engine builtin\|codesift` | Stdlib estimate or verified CodeSift envelope; never compare their raw CC |
| `--prepare-farm <new directory>` | Export immutable inputs and worker code locally; NO measurement |
| `--snapshot <input.json>` | Replay a prepared DISCOVER job on the farm, without Git or credentials |
| `--timings`, `--timeout <seconds>` | Phase timings on stderr and a whole-process deadline |
| `--json <new file>` | Override the raw JSON destination; otherwise save in the run directory |
| `--no-save` | Agent-side chat-only opt-out; do not pass this flag to the CLI |
| `--queue <new file>` | Requires explicit REGISTER and a validated `--decisions` file |
| `--history <dir>` | Read compatible history; write only with `--record-snapshot` |
| `--no-remote` | Skip PR queries; availability UNKNOWN, not FREE |
| `--dry-run` | No artifacts, validation or queue creation |

Read [references/contract.md](references/contract.md) before passing advanced flags, creating
a profile, importing CodeSift data, using a farm, REGISTER, or interpreting schema/history.

## Environment Compatibility

This selector does not require agents. Follow the current session's execution policy and
project runner rules. Tools unavailable or outside authority → name the missing evidence
and degrade that gate, not the truth standard. No local fallback from a queued/failed farm.

## Mandatory File Loading

Before Phase 0 read the repository rules, this skill's [data contract](references/contract.md),
and `../../shared/includes/report-output-location.md` for the project-root destination.
Read [farm execution](references/farm.md) when offloading. Do not load generic execution,
test, mutation or multi-agent bootstraps for a read-only selector. At completion load
`../../shared/includes/run-logger.md` and `../../shared/includes/retrospective.md` for telemetry.
Keep work within the validation budget; never fabricate enough READY rows.

## Phase 0: Establish the input boundary

Read repo rules and the existing ledger/CONTRACTs, if present. Inspect canonical root, HEAD,
dirty paths, all live worktrees (including detached ones), and the authoritative remote.
Do not delete, prune, reset, fetch or install to make the census look clean.
Resolve explicit user exclusions to **exact paths**; ambiguous basenames require inspection.

Use an existing `.radar.json` / `zuvo/radar.json` profile or disclose defaults: K=3 for all
paths, application source roles. A tools/plugin repo needs `profile: tooling` because its
scripts ARE production. Seeds, dependencies, generated files, copies and docs are not
production candidates; tests remain evidence for verification.

Read old decisions as hypotheses with scope, reason and `returns_when`, not eternal bans.
A recent refactor can resolve one smell while leaving another. Inspect its family diff.
When continuing from a saved radar list, first reuse its candidate-specific evidence using
[handoff.md](references/handoff.md). Reformatting a report needs no rescan. A changed HEAD
alone does not invalidate unchanged scoped findings; refresh affected evidence and availability.
Prefer CodeSift when its scope/revision/completeness can be verified. `indexed=true` alone
does not prove freshness, and a timestamp alone does not attest a frozen SHA. A top-N MCP
result is not a complete census. Follow the contract's CodeSift decision procedure; use the
farm builtin estimate if the envelope cannot be obtained. Do not invent CLI/MCP arguments.

## Phase 1: Generate cheap discovery evidence

Resolve the real script first: the installed bundle at
`~/.zuvo/refactor-radar/current/refactor-radar.sh`, otherwise the verified Zuvo checkout's
`scripts/refactor-radar.sh`. Set RADAR to that absolute existing path; do not use `$0`
from an agent shell to locate a skill, or guess a cache version.

```bash
# >>> zuvo:refactor-radar-generate
# RADAR and REPO_ROOT are verified absolute paths; SCOPE is repo-relative.
# Map --dry-run/--no-save to RADAR_DRY_RUN/RADAR_NO_SAVE=1, --json to RADAR_JSON.
RADAR_ARGS=(--repo "$REPO_ROOT" --scope "${SCOPE:-.}" --top "${TOP:-50}" --mode "${MODE:-refactor}")
if [[ "${RADAR_DRY_RUN:-0}" == 1 ]]; then
  RADAR_ARGS+=(--dry-run)
elif [[ "${RADAR_NO_SAVE:-0}" != 1 ]]; then
  RADAR_OUTPUT_ROOT="${ZUVO_OUTPUT_DIR:-$REPO_ROOT/zuvo}"
  mkdir -p "$RADAR_OUTPUT_ROOT/reports"
  RADAR_RUN_DIR="$(mktemp -d "$RADAR_OUTPUT_ROOT/reports/refactor-radar-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
  RADAR_JSON="${RADAR_JSON:-$RADAR_RUN_DIR/discovery.json}"
  RADAR_ARGS+=(--json "$RADAR_JSON")
fi
# Only a small census where local execution is permitted. For repo/fleet scans use farm.md.
bash "$RADAR" "${RADAR_ARGS[@]}" --timings
# <<< zuvo:refactor-radar-generate
```

The default run directory is under `<project-root>/zuvo/reports/`, not the scoped source
directory or a disposable worktree selected for analysis. Use the invocation project's root
and retain SHA/repo identity in the report. Never overwrite another run or an approved queue.
Add requested flags with shell arrays; report persistence is already the default above.
Never pre-create a history/queue directory. For `--no-save` do not stage artifacts without
separate authority; use available read-only evidence or disclose the execution limitation.
For repo-wide/fleet scans use `--prepare-farm` and the documented `rt` workflow BEFORE
starting CPU work. Above 1,000 source+test files the CLI refuses local analysis; a narrow
`--scope` still needs the repo-wide graph. Do not bypass this with Python monkey-patches,
in-memory reimplementations, or `--execution farm` on the laptop. That flag checks the
worker context; it does not offload work. All snapshot workers go through `rt`.
Use stage timings to distinguish slow Git/provider I/O from parsing, graph construction
and ranking. A deadline aborts the report; do not silently omit files or call them clean.

Save the **complete scanner JSON before semantic validation**, not only the displayed top N.
On the farm retrieve it to the durable local run directory (farm.md); stdout, temporary job
files and a run-log entry are not a saved deliverable. Read the saved JSON back and check its
repo ID/SHA and row counts. Start `report.md` in that run directory with state IN_PROGRESS,
the raw JSON link and known limitations, then update it as validation progresses. If scanning
fails, save a FAILED diagnostic report with the actual error; do not invent a discovery JSON.

Copy the real stderr population/floor/exclusion summary. Zero exclusions is possible.
Keep schema, population, config hash and scanner diagnostics in the saved JSON; the human
list needs only repo/SHA, timestamp, counts and material limitations. `--dry-run` ends here.

The script ranks the **complexity lane only**:
ΣCC × sqrt(fix-commits + 1) × declared K, normalized within this run. It is a discovery
heuristic, not calibrated ROI or a cross-repo quality score. Conventional commit labels are
proxies. Report unknown churn; no novelty multiplier or blanket fresh-refactor exclusion.
Python uses stdlib AST; TS/JS/PHP/Kotlin use a bounded regex **estimate**, not an exact census.

## Phase 2: Cover blind spots within a budget

Do not make “top CC” masquerade as comprehensive selection. In addition to the complexity
shortlist, reserve up to one third of the investigation budget for independent lanes:
verified deletion hypotheses, clone mechanisms, runtime cycles/hubs, boundary type debt,
and confirmed runtime/defect hotspots. Report lane quotas and scanned/unavailable dimensions.

Use existing tools, only with observed schemas and project configuration:

| Dimension | Evidence to collect |
|-----------|---------------------|
| Complexity / size | Function CC, D=Σ(CC−1), N, ΣCC, max CC, independent max nesting, LOC |
| Duplication | CodeSift/jscpd/AST search; read matches and prove one shared mechanism, not just shape |
| Coupling / cycles | CodeSift plus configured dependency-cruiser/madge; distinguish runtime/type-only edges and resolver gaps |
| Dead code | Knip/framework roots, DI, route and package registrations, dynamic imports and intent |
| Type boundaries | Narrow source/AST checks for unchecked casts and suppressions, not raw grep count alone |
| Change pressure | Unique family fix/feature/refactor commits, rename caveats, co-change sample excluding bulk commits |
| Criticality | Owner profile, actual product entry/tenant/auth/write path; path names alone are not proof |
| Testability | Reachable behavioral assertions, measured branch coverage if available, characterization harness |
| Runtime / intent | Existing Sentry evidence mapped to this revision; E2E selectors and recent edits are clues only |

Do not assign invented runtime multipliers, call a clean/unscanned dimension debt-free, or
install all tools across all repos. Use internet research for an actual evidence/tool gap,
prefer primary sources, record versions and limitations. Suggestions belong in Follow-ups.
For an authorized Madge fallback, use `npx --yes madge --circular --extensions ts,tsx <dir>`
so a package-download prompt cannot hang a non-interactive run. Preserve project resolver
configuration and inspect type-only edges before calling a reported cycle a runtime defect.

## Phase 3: Validate G1–G5 and classify the decision

For every investigated family give gate status and concrete source/command evidence:

- **G1 Usage and intent:** trace product entry points and declared API consumers.
  Empty references, an “unused” report or absent sourcemap entry does NOT prove dead code.
  A sourcemap proves build participation, not user reachability. A test selector, comment or
  recent commit does NOT prove the feature is intended today. Unresolved intent → OBSERVE.
- **G2 Availability:** exact current PR/dirty/committed-diff scope and active CONTRACTs.
  Failed/skipped/partial/stale provider → UNKNOWN; exact overlap → BUSY. A name-only hint
  needs corroboration, not automatic exclusion. Do not repair authentication in DISCOVER.
- **G3 Cohesion and kept scope:** validate the proposed family edges and retained behavior.
  Matching names, the same feature label, or a common directory is insufficient to merge work.
  Respect sunset decisions and user exclusions, with revisit conditions.
- **G4 Verification:** name the assertions/harness that observe affected behavior. A test file
  existing, or a large test/source LOC ratio, is not adequate coverage. Missing safety net →
  TEST_FIRST with a concrete characterization plan, not “low value”.
- **G5 Bounded change:** inspect callers, alias/type-only resolution, fan-in and cycles. Specify
  a safe seam and realistic change scope; an arbitrary importer threshold does not pick a type.

Decision states: READY / TEST_FIRST / OBSERVE / BUSY / EXCLUDED / DELETE_CANDIDATE.
Only validated FREE rows can become READY; the script itself emits no READY decisions.
DELETE_CANDIDATE needs independent non-use + product-intent evidence; deletion still needs
a separately approved execution contract. This skill never deletes source.

## Phase 4: Group, sort and choose the intervention

Keep **analysis_scope** (family + relevant consumers), **write_scope** (owned files), and
**verification_scope** (tests/build/routes/contracts) distinct. Group overlapping edits or
one proven shared mechanism; separate disjoint responsibilities. Shared “pricing” vocabulary
does not justify a batch. Split broad work into dependency-ordered steps with explicit fences.

First separate execution lanes: READY, then TEST_FIRST/OBSERVE for evidence work; BUSY and
EXCLUDED outside execution. Within READY order by confirmed pain × product criticality ×
confidence, then lower blast radius/effort, then stable path tie-break. Record the reason and
effort/risk bands; do not disguise subjective estimates as precise numeric ROI.
Keep raw discovery order in JSON, separate from the final order. Never compare normalized scores
across repos/engines or allocate all fleet work to the largest repo.

Choose an intent, not a filename operation: SIMPLIFY, EXTRACT_METHODS, SPLIT_FILE, GOD_CLASS,
DEDUPE, BREAK_CIRCULAR, HUB_SPLIT, DELETE_DEAD; COVER only in tests mode. Check the actual
downstream skill's supported types before handoff. A cohesive plan may combine necessary
operations; “one type per PR” is not an evidence-based universal rule.

## Phase 5: Report; REGISTER only if requested

Write `report.md` as a **compact ranked handoff list**, using
[handoff.md](references/handoff.md), not a scan diary or a raw metrics table followed by essays.
Every recommended item must name an actual file/symbol, a bounded change, its specific
pitfalls and a test/evidence pointer. These are reusable findings, not just discovery scores.
Keep full metrics, raw rows and exclusions in `discovery.json`; do not duplicate them as a
top-N appendix in the human list unless the user explicitly asks for raw scanner output.
Keep all selected candidates in the saved list, not only the few summarized in chat.
Missing validation stays in a separate short pending section with the exact missing check;
do not dress up unreviewed family IDs as actionable refactor recommendations or pad to N.
Save partial/UNKNOWN results too, with requested/handed-off/pending counts in a short header.

For every intent: characterize behavior before edits, compare N/ΣCC/D/max/nesting including
new helpers with the SAME measurement engine; extraction adds baseline CC per function, so
ΣCC need not fall. No new runtime cycles. Targeted tests/type-check/build, full battery when
repo policy requires, UI verification for visible behavior. Module-count equality is not a
behavioral gate. Use targeted native mutation testing at EXECUTE where applicable, not on
every discovery file; invalid/timeouts/equivalent mutants are not automatically killed.

REGISTER requires the JSON decision contract in [references/contract.md](references/contract.md).
No default queue path, no overwriting an existing approved queue, no automatic ledger append.
Ledger rows must carry repo ID, SHA, family/smell, decision/evidence and a revisit condition.
A missing old worktree path never invalidates the ledger; current availability is recollected.

## REFACTOR-RADAR COMPLETE

Reopen the saved `report.md` and raw JSON: verify they are nonempty, parse the JSON, and
check source identity and counts against the report. Check that every handoff card actually
contains a concrete warning and verification pointer, not generic "preserve behavior" advice.
Link **both actual local files** in the
final answer. Missing/failed artifact writes prevent COMPLETE/PASS; report the save failure
and retained paths, not “done”. An analysis shortfall is PARTIAL even if persistence succeeded;
do not withhold partial results from disk. With explicit `--no-save`/`--dry-run`, state the
opt-out instead and do not create report directories or operational telemetry.
Report requested/returned/validated counts, limitations and next action. Saving a report is
not authorization to create an executable queue. UNKNOWN evidence stays visible.
Population zero may mean “no applicable production scope”; explain before calling it a failure.

Unless writes were explicitly suppressed, perform the retrospective and append the Run line
via the loaded protocols. Operational run
telemetry is separate from product queue/ledger/history; `--dry-run` itself writes none.
