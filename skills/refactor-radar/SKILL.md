---
name: refactor-radar
description: >
  Pick WHAT to refactor before zuvo:refactor decides HOW. Deterministic ranking of
  refactor candidates for any git repo (scripts/refactor-radar.sh: ΣCC × fix-churn ×
  criticality × persistence per module family, busy/fresh exclusions), then agent-side
  validation (G1-G5: alive, free, kept, testable, cheap to touch), refactor-type
  classification, and complete orders with a measured baseline. Writes a zuvo:refactor
  batch queue and a per-repo ledger so no candidate is evaluated twice. Flags: [path],
  --top N, --mode refactor|tests, --queue <file>, --history <dir>, --engine builtin|codesift,
  --no-remote, --dry-run.
category: Core
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
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

Choose the refactor targets that are worth an agent's session, with evidence, and hand them
to `zuvo:refactor` as a queue. The ranking is computed by a script and is reproducible; the
agent's job starts after the script: validate the top of the list against the code, classify
the refactor type, write orders that carry their own baseline, and record every decision
(including the negative ones) in the repo's ledger.

**Scope:** candidate selection, validation, classification, order writing, queue + ledger.
**Out of scope:** performing the refactor (`zuvo:refactor`, `zuvo:refactor batch <queue>`),
auditing structure for its own sake (`zuvo:structure-audit`), writing tests (`zuvo:write-tests`
— but `--mode tests` produces its queue).

## Why this exists (read once)

Measured on one repo taking 30-50 PRs a day (2026-08 → 2026-09):

- The same "which files should we refactor" analysis was hand-derived **six times in one
  session**, each time from scratch and each time with a different mistake.
- **Raw churn ranked facades.** 7 530 commits in 90 days, ~1 000 of them `refactor:` and
  ~1 100 `test:`. The top of the churn list was `designer-page.tsx` — 120 commits, ΣCC 3 —
  a facade every fix passes through after a split. The signal is **fix-churn per module
  family**, not commits per file.
- **max-CC is flat.** P80 of max-CC per file was 14. A file of 74 small functions (ΣCC 159,
  max 12) was invisible to a max-CC ranking and was the third-largest debt in the repo.
- **Half the "done" refactors moved complexity instead of reducing it.** 5 of 10 merged
  splits relocated the worst function whole: file LOC −96 %, max CC unchanged. The
  Definition of Done therefore measures the **family** (facade + satellites), never the file.
- **A worktree with zero commits is still someone's job.** 18 of 40 `codex-refactor-*`
  worktrees sat on the base branch with an empty diff; a diff-based busy set proposed their
  targets to a second agent. Busy is diff **and** name.
- Research agrees on the shape (see `refactor-reference.md` → "Selection evidence" if
  present, else the citations in the retrospective of the first run): hotspot = complexity ×
  change frequency (CodeScene); practitioners discard tests, isolated files, temporary bursts
  and code under active cleanup from any automatic ranking (Technical Debt Friction, 2026);
  agents succeed on **atomic** refactors (~83 %) and fail on compound ones (~39 %)
  (SWE-Refactor, 2026); LLM refactors tend to move complexity and over-split (CodeTaste, 2026).

## Argument Parsing

| Input | Action |
|-------|--------|
| _(empty)_ | Whole repo, `--top 50`, mode `refactor` |
| `<path>` | Restrict candidates to families under this directory |
| `--top N` | Number of ranked rows / queue entries (default 50) |
| `--mode refactor\|tests` | `tests` ranks by MISSING coverage (ΣCC × √fix × K × (1 − cov)) and writes a `zuvo:write-tests` queue |
| `--queue <file>` | Where to write the batch queue (default `zuvo/refactor-queue.md`) |
| `--history <dir>` | Snapshot directory for persistence R (default `zuvo/radar-history/`) |
| `--engine builtin\|codesift` | CC engine; `codesift` needs the CLI and an index of THIS tree |
| `--no-remote` | Skip open-PR lookup (gh / Bitbucket) |
| `--dry-run` | Run the script and print the table; no validation, no orders, no ledger write |
| `--validate N` | How many top rows get G1-G5 validation (default `min(3 × --top, 60)`) |

---

## Environment Compatibility

**Dispatch is already authorized — do not ask, do not downgrade.** Invoking this skill IS the
request for every agent and gate it mandates. Only a harness with NO dispatch capability takes
the documented single-agent fallback, and it still runs every gate inline — see
`../../shared/includes/env-compat.md`.

Read `../../shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and
progress tracking across all supported platforms.

## Mandatory File Loading

Read these before Phase 0:

1. `../../shared/includes/env-compat.md` — dispatch and path resolution
2. `../../shared/includes/run-logger.md` — the Run line at completion
3. `../../shared/includes/codesift-setup.md` — availability, worktree scope, degraded mode
4. `../../shared/includes/no-pause-protocol.md` — HARD: validate every row in the batch, no mid-list stops
5. `../../shared/includes/retrospective.md` — required before the Run line

Print the checklist:

```
CORE FILES LOADED:
  1. env-compat.md          -- [READ | MISSING -> WARN]
  2. run-logger.md          -- [READ | MISSING -> WARN]
  3. codesift-setup.md      -- [READ | MISSING -> DEGRADED (builtin engine + grep for G1/G5)]
  4. no-pause-protocol.md   -- [READ | MISSING -> WARN]
  5. retrospective.md       -- [READ | MISSING -> WARN]
```

---

## Phase 0: Hygiene — what is already known and what is already in flight

The ranking is only as good as its exclusions. Before computing anything:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
git -C "$REPO_ROOT" rev-parse --short HEAD
git -C "$REPO_ROOT" status --porcelain --untracked-files=no | wc -l      # dirty files → prefer --ref <base-branch>
git -C "$REPO_ROOT" worktree list | grep -ic 'refactor\|split\|extract'  # jobs in flight by NAME
git -C "$REPO_ROOT" branch -r --format='%(refname:short)' | grep -c refactor
```

Resolve the CodeSift scope ONCE with `scripts/codesift-worktree-scope.sh` (a linked worktree
resolves to its PARENT until indexed — see `codesift-setup.md`). Print its `action=` line.

**Read the ledger.** `zuvo/refactor-ledger.md` (or the path the repo's rules name — some repos
keep it under `memory/refactor-queue/`). Sections "Selected", "Watching", "Rejected",
"Excluded". Nothing in "Selected"/"Excluded" is proposed again; a "Rejected" row with a
`returns when …` clause is re-proposed only when that clause is TRUE — check it, do not assume.
If no ledger exists, create it from the template in Phase 5 on first write.

**Manifest.** `<repo>/.radar.json` (or `zuvo/radar.json`) declares noise regexes, criticality
(`critical: [{pattern, k}]` with K = 5 / 3 / 1), source extensions and the PR remote. If it
does not exist, run with the defaults AND say so in the report — the default K=5 regex
(`submission|validation|auth|guard|persistence|tenant|export|session|…`) is a guess, not the
owner's declaration. Propose a manifest in the report's "Follow-ups" when the defaults
mis-rank something (e.g. a QA bot controller getting K=5 because its path contains `session`).

---

## Phase 1: Generate the ranking (script, never by hand)

```bash
# >>> zuvo:refactor-radar-generate
RADAR="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/cache/zuvo}/scripts/refactor-radar.sh"
[ -f "$RADAR" ] || RADAR="$(dirname "$0")/../../scripts/refactor-radar.sh"   # repo checkout
mkdir -p "$REPO_ROOT/zuvo/radar-history"
bash "$RADAR" --repo "$REPO_ROOT" --top "${TOP:-50}" --mode "${MODE:-refactor}" \
  --json "$REPO_ROOT/zuvo/radar-latest.json" \
  --queue "${QUEUE:-$REPO_ROOT/zuvo/refactor-queue.md}" \
  --history "${HISTORY:-$REPO_ROOT/zuvo/radar-history}" ${ENGINE:+--engine "$ENGINE"} ${NO_REMOTE:+--no-remote}
echo "RADAR_EXIT=$?"
```

Read the stderr summary and copy it into the report verbatim — it carries the population,
the self-calibrated floor (`ΣCC≥P80`), the fix-churn P90, and the exclusion counts
(`busy:diff`, `busy:name`, `fresh-refactor`, `below-floor`). **A run that excluded nothing is
suspicious, not clean**: on any repo with agents working, `busy:*` > 0.

What the script does NOT compute, and what you must add on the validated rows only
(Phase 3): cycles, clone families, Sentry/runtime signal, e2e intent. Do not try to add them
for all 4 000 families — the script's ranking decides WHICH rows deserve the expensive checks.

`--dry-run` stops here: print the table, the summary, and exit with no ledger write.

**Engine note.** `builtin` is a regex estimator (documented in the script header); its ΣCC is
comparable across snapshots of the same repo, not with CodeSift's numbers. Use
`--engine codesift` when the repo is indexed and the ledger's calibration used CodeSift —
never mix engines inside one history directory (the script warns; the R signal survives, the
ΣCC comparison does not).

---

## Phase 2: Signals the script cannot see (validated rows only)

Run on the top `--validate` rows (default `min(3 × top, 60)`), in one pass, no pauses:

| Signal | How | Effect |
|--------|-----|--------|
| **Cycles through the family** | `find_circular_deps(file_pattern=<family dir>)`; fallback `npx madge --circular --extensions ts,tsx <dir>`. Discard type-only cycles (`import type`). | Real cycle → class `BREAK_CIRCULAR`; note count for the DoD ("cycles do not increase") |
| **Clone family** | `find_clones(file_pattern=<family dir>, min_similarity=0.7)`; if ≥ 3 files share a shape (same algorithm, renamed fields), read two of them to confirm — hash similarity alone is not evidence | Class `DEDUPE` (one mechanism, N call sites); the order lists every member |
| **Runtime errors** | Sentry MCP `search_issues` for the last 30 days, map stack frames to paths | ×1.5 on score; the report says "runtime-backed" |
| **Intent** | `grep -rl 'data-testid' e2e/ tests/e2e/` for ids the family renders; `git log -1 --format=%cs -- <file>`; comments like "unrouted", "extracted from" | An unreachable component that e2e asks for is a PRODUCT backlog item, not dead code — never class `DELETE_DEAD` |
| **Regrowth** | ledger says the family was split on date D → `git show <sha-at-D>:<file> \| wc -l` vs now | Grew back ≥ 30 % → the previous split relocated complexity; say so in the order |

---

## Phase 3: Validation G1-G5 — a row that fails a gate is not a candidate

For every validated row, print one line `G1 ✅/❌ G2 ✅/❌ G3 … | <evidence>`:

- **G1 ALIVE** — `find_references(<exported symbol>) ≠ []`, or the file is reachable from an
  entry point (`main.tsx`, `AppModule`, a router). For Vite apps the proof is the bundle:
  `vite build --sourcemap` → `sources` in `dist/assets/*.map`. NestJS decorators
  (`@Injectable`, `@Controller`) have zero "calls" — that is DI, not dead code. Dead-code
  tools produce false positives here; confirm before you classify anything `DELETE_DEAD`.
- **G2 FREE** — 0 worktrees (diff **and** name), 0 open PRs, absent from the ledger's
  "Selected", not `fresh-refactor`. One-word stems (`page`, `survey`, `question`) match too
  many branch names — the script skips names under 6 characters; check those by hand and
  say which branch you compared against.
- **G3 KEPT** — not on a deletion list, not an ADR-documented sunset, not a prototype the repo
  rules call out.
- **G4 TESTABLE** — a spec exists (`tests` column > 0), or a characterization test can be
  written without a database. DB-bound controllers without a fake are testability 2 (the
  script already halves their score); say what the harness would be.
- **G5 CHEAP TO TOUCH** — `fan_in` from the JSON (importers OUTSIDE the family). > 30 →
  class `HUB_SPLIT` (barrel/hub: importers must not change). Cycles from Phase 2.

Rows failing G1 go to the ledger's "Delete?" list with the evidence (never deleted here).
Rows failing G2/G3 go to "Excluded" with the blocker. G4/G5 do not exclude; they shape the
order and lower the score (record the adjusted score next to the script's).

Do not stop after the first N pass. The no-pause protocol applies: every validated row gets
its line, then the ranking is re-sorted once.

---

## Phase 4: Classify — one type per order, one order per PR

The script proposes a type from metrics; you confirm or override after reading the file:

| Type (zuvo:refactor vocabulary) | Signal | Order shape |
|---------------------------------|--------|-------------|
| `EXTRACT_METHODS` | one function holds ≥ 40 % of the family's ΣCC (`concentration`), or `nest ≥ 6` | Decompose THAT function: table-drive the cascade, extract pure predicates, flatten. Atomic — highest agent success rate. |
| `SPLIT_FILE` | ΣCC spread over ≥ 10 functions, max < 15 | Thematic split with a re-exporting facade; importers unchanged; use a TS-API tool, not hand edits |
| `GOD_CLASS` | LOC > 600 and ≥ 10 functions (script) AND ≥ 5 responsibilities (you) | Iterative: one responsibility per commit; residual-core gate applies |
| `SIMPLIFY` | deep nesting with modest ΣCC | Within-function strategies only |
| `DEDUPE` (→ `EXTRACT_METHODS` on the shared mechanism) | Phase 2 clone family ≥ 3 | One mechanism + N call sites; list every member; ONE PR for the mechanism, one per member migration if > 5 |
| `BREAK_CIRCULAR` | real cycle | Invert the dependency / extract the contract |
| `HUB_SPLIT` (→ `SPLIT_FILE`) | fan_in > 30 | Split the barrel; zero importer changes; measure fan-in after |
| `DELETE_DEAD` | G1 ❌ with intent check ❌ | Deletion order with the three proofs (tsc, build module count, bundle sources) |

**An order without a type is not an order.** A family that needs two types gets two orders,
sequenced (extract the monster first, then split the remainder), each with its own baseline.
Compound orders are what agents fail at; sequencing atomic ones is what they succeed at.

---

## Phase 5: Output — table, orders, queue, ledger

### 5.1 Ranked table (report: `zuvo/reports/refactor-radar-<date>.md`)

Columns: `# | score (script → adjusted) | type | family (n files) | ΣCC | max (fn) | nest |
fix/feat/ref | K | R | fan_in | cycles | tests | runtime | why NOW (one sentence) | PRs`.
Below the table: the script's stderr summary verbatim, the manifest status (declared /
defaults), the engine, and the previous snapshot compared against.

### 5.2 Orders for the top 10 (copy-paste blocks)

Every order is complete on its own — an agent that receives only the block has everything:

```markdown
## ORDER <n> — <family> (<n files>, ΣCC <sum>, type <TYPE>)

### Preparation
git -C <repo> fetch <remote> <base>
git -C <repo> worktree add -b refactor/<stem> <worktrees-dir>/refactor-<stem> <remote>/<base>
<repo's pinned install command>          # never bare npm ci if the repo says so
Then invoke `zuvo:refactor <target>` — it has its own mandatory flow (ETAP, CONTRACT, safety
gates, commit hook). Follow it.

### Files (ΣCC / LOC / fix-churn / tests)
<one line per member, satellite with the worst function first>

### Baseline (what "after" is measured against)
| function | CC | lines | nest |
|---|---|---|---|
<every function ≥ 5 CC in the family>
Family: max CC <m> (<fn>), ΣCC <s>, nest <n>, cycles <c>, fan_in <f>, bundle modules <b> (Vite apps)

### What to do
<the type's order shape, made concrete for this family — which function, which cascade,
which responsibility first; what the previous split (if any) relocated and must now be undone>

### Delivery — <N> PR(s)
PR 1: … (type, expected max CC after)
PR 2: …

### Definition of Done (the pre-push gate reads the CONTRACT; these are the numbers it needs)
1. max CC of the FAMILY (file + every child file) < 15; nest ≤ 3
2. ΣCC of the family drops ≥ 40 % — moved complexity does not count; table "function | CC
   before | CC after | where it landed" in the PR description
3. cycles through the family: not more than <c>
4. zero behaviour change: characterization/golden test BEFORE the first edit; diff function by function
5. Vite apps: "N modules transformed" identical before and after
6. type-check + targeted tests, then the full suite (on the farm where the repo says so) + build green
7. every new source file has its test pair (repo pre-commit gate) — inventory BEFORE the split
```

### 5.3 Queue

The script already wrote `zuvo/refactor-queue.md` in `zuvo:refactor` batch format
(`- [ ] path | TYPE | Score: 0.NN` + a `#` evidence line). After validation, rewrite it to
the validated order: drop rows that failed G1-G3, apply type overrides, keep the evidence
lines. Hand-off: `zuvo:refactor batch zuvo/refactor-queue.md`. In `--mode tests` the queue
is for `zuvo:write-tests` (same line format; type column = `COVER`).

### 5.4 Ledger (append-only; one row per decision, including "no")

```markdown
## <date> — radar run <sha7> (engine <e>, floor ΣCC≥<p80>, prev snapshot <file|none>)
### Selected
- <family> | rank #<n> script <s> → adjusted <s'> | <ΣCC/max/nest/fix/K/R/fan_in> | G1-G5 ✅ | type | plan (one line)
### Watching
- <family> | why not now | returns when <condition>
### Rejected
- <family> | reason (busy:<branch> / fresh <date> / K=1 / G4 DB-bound / …) | returns when <condition>
### Delete?
- <family> | G1 ❌ evidence | intent signals checked: e2e testid <y/n>, last commit <date>, comment <quote|none>
```

The ledger is what makes the next run cheaper than this one. A run that writes nothing to it
has produced an opinion, not a decision.

---

## REFACTOR-RADAR COMPLETE

```
REFACTOR-RADAR COMPLETE
  Repo:        <root> @ <sha7>  (engine <builtin|codesift>, floor ΣCC≥<n>, window <d>d)
  Population:  <families> families | excluded busy:diff <n> busy:name <n> fresh <n> below-floor <n>
  Validated:   <n> rows → <n> pass G1-G5 | <n> Delete? | <n> Rejected | <n> Watching
  Orders:      <n> written (types: EXTRACT_METHODS <n>, SPLIT_FILE <n>, GOD_CLASS <n>, DEDUPE <n>, BREAK_CIRCULAR <n>, HUB_SPLIT <n>, DELETE_DEAD <n>)
  Queue:       zuvo/refactor-queue.md (<n> entries) → next: zuvo:refactor batch zuvo/refactor-queue.md
  Ledger:      <path> (+<n> rows)
  Report:      zuvo/reports/refactor-radar-<date>.md
  Manifest:    <declared .radar.json | DEFAULTS — proposal in report>

  Run: <ISO-8601-Z>	refactor-radar	<project>	-	-	<VERDICT>	<orders>	<validated>-validated	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
```

VERDICT: PASS (queue + ledger written, ≥ 1 order), WARN (queue written, 0 rows passed
validation — say why: everything busy/fresh is a legitimate outcome), FAIL (script exit ≠ 0
or population 0), DRY-RUN (`--dry-run`).

### Retrospective (REQUIRED — load + fill BEFORE the Run line append)

Load `../../shared/includes/retrospective.md` if not already loaded. Follow the retrospective
protocol: gate check → structured questions → TSV emit → markdown append to `~/.zuvo/retros.md`
AND `~/.zuvo/retros.log`. Friction worth recording here: a script exclusion that was wrong
(a name match that hit an unrelated branch), a manifest default that mis-ranked a path, a
G1 false positive from a dead-code tool, a type the script proposed that reading overturned.

Then append the Run line via the retro-gated wrapper:

```bash
printf '%b\n' "$RUN_LINE" | ~/.zuvo/append-runlog
```

Expected stdout: `OK: appended to runs.log (retro verified for refactor-radar on <project>)`.
If the wrapper exits 2 with `RETRO_REQUIRED`, execute the retro bash first; never bypass with
`ZUVO_SKIP_RETRO_GATE=1`, never `>>` directly to `runs.log`.
