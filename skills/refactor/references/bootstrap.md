## Mandatory File Loading

First resolve `../../../shared/includes/execution-policy.md` and
`../../../shared/includes/evidence-reuse.md`. Reuse the parent policy and verified evidence for
a nested stage. Load only the rules needed now, with the read-once receipt protocol.

### PHASE 0 — Bootstrap (always, before reading any input)

```
  1. ../../../shared/includes/codesift-setup.md      -- [READ | MISSING -> STOP]
  2. ../../../shared/includes/no-pause-protocol.md   -- [READ | MISSING -> WARN] (HARD: no mid-batch pauses)
  3. ../../../shared/includes/regression-fence.md    -- [READ at Phase 2] (proves MOVED_VERBATIM instead of asserting it)
  4. ../../../shared/includes/test-mutation-probes.md -- [READ at Phase 2] (proves the characterization lock has teeth — CHARACTERIZE_GAP step 2.5)
  5. ../../../shared/includes/test-quality-gate.md   -- [READ at Phase 3.6] (Phase 3.6; carries the dispatch-authorization rule)
  6. ../../../shared/includes/terminal-state.md      -- [READ | MISSING -> WARN] (no completion over a live runner or a pending check)
```

Load bootstrap requirements now; load each deferred protocol at its named phase.

### PHASE 0 — Commit-gate self-install (run this bash; ungated, fail-open)

Export the AI-run marker and ensure the external refactor commit-gate is active for this repo. The
gate is the bind that makes the Definition of Done real — an agent cannot skip a git hook. It no-ops
when the repo has no active refactor CONTRACT, fail-opens if anything is missing (never blocks setup).

```bash
# (No ZUVO_AI_RUN export — it would not survive into the agent's later, separate commit shell.
#  The gate detects an AI run from the ambient harness env: CLAUDECODE / CODEX_SANDBOX /
#  CURSOR_TRACE_ID / ANTIGRAVITY_SESSION_ID — always set at session level, so the gate fires
#  on real commits without any export. Verified end-to-end in a temp repo.)
# Probe EVERY host's install root, not just the Claude marketplace cache: on Codex/Cursor the
# plugin lives under ~/.codex or ~/.cursor, so a Claude-only probe printed "not found" on every
# run there — false installer-missing telemetry that hid a genuinely absent gate.
_GATE=$(ls ~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/hooks/refactor-safety-gate.sh \
           ~/.codex/scripts/refactor-safety-gate.sh ~/.cursor/scripts/refactor-safety-gate.sh \
           ~/.gemini/antigravity/hooks/refactor-safety-gate.sh \
           ~/.codex/.tmp/plugins/plugins/zuvo/hooks/refactor-safety-gate.sh 2>/dev/null | head -1)
_INST=$(ls ~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/install-refactor-gate.sh \
           ~/.codex/scripts/install-refactor-gate.sh ~/.cursor/scripts/install-refactor-gate.sh \
           ~/.gemini/antigravity/scripts/install-refactor-gate.sh 2>/dev/null | head -1)
# Is the gate even able to fire? It detects an AI run from the ambient harness env; if none of
# these is set the gate no-ops on the human's commits by design — say so instead of implying
# the repo is protected.
_HARNESS="unavailable (detector missing)"
_DETECTOR="$(dirname "$_GATE")/lib/agent-env.sh"
if [ -r "$_DETECTOR" ]; then
  . "$_DETECTOR"
  if zuvo_is_agent_env; then _HARNESS=active; else _HARNESS="human (gate bypass)"; fi
fi
if [ -n "$_GATE" ] && [ -n "$_INST" ]; then
  sh "$_INST" "$_GATE" "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  echo "[refactor-gate] gate=$_GATE"
  echo "[refactor-gate] ai-harness-detected:$_HARNESS"
else
  echo "[refactor-gate] NOT INSTALLED — gate='${_GATE:-missing}' installer='${_INST:-missing}';"
  echo "[refactor-gate] searched ~/.claude/plugins/cache, ~/.codex, ~/.cursor. Re-run scripts/install.sh."
  echo "[refactor-gate] in-skill self-check still applies, but the commit bind is ABSENT this run."
fi
```

### PHASE 0.5 — Classify (read target, determine refactor type)

After CodeSift setup, read the target file(s). Determine refactor type:
- **RENAME:** symbol rename, file move
- **EXTRACT:** extract function/class/module
- **SPLIT:** split large file into smaller modules
- **INLINE:** consolidate/inline scattered logic
- **RESTRUCTURE:** architectural change (module boundaries, dependency direction)

Print: `[CLASSIFIED] Refactor type: {RENAME|EXTRACT|SPLIT|INLINE|RESTRUCTURE}`

**First check the working tree — a prior interrupted attempt changes what "before" means.** If the
target already has staged or unstaged modifications (`git status --porcelain -- <target>`), this is
almost certainly a resumed/retried run, and reading the file as-is silently measures a
half-refactored state as the baseline: the CQ pre-audit scores partially-extracted code, the
"before" snapshot is wrong, and the run may re-extract what is already extracted.

```bash
git status --porcelain -- <target>          # empty → clean start, proceed normally
git diff HEAD -- <target> | head -60        # tracked changes ('??' in status = untracked, no diff)
```

**A dirty target is NOT automatically a resumable attempt** — it may be the user's unrelated
work-in-progress, and absorbing that into the baseline would quietly make their edits part of "the
code before my refactor" (and part of your commit). Decide by evidence, not assumption:

- A CONTRACT exists for this target with `stage != COMPLETE` → this IS a resumed run. Treat the
  current state as "before" for the CQ pre-audit, and reconcile with the CONTRACT and any CHANGELOG
  entry the earlier attempt wrote, so the run continues rather than duplicates or reverts it.
- No CONTRACT, or the changes do not look like the recorded plan → treat it as **foreign WIP**.
  Do not absorb it and do not stash it silently: say what is uncommitted and ask (or, when
  non-interactive, stop with `BLOCKED_DIRTY_TARGET`). Refactoring on top of someone's unfinished
  edit produces a diff neither of you can review.

Record which baseline was used either way — a "before" score measured against the wrong tree makes
the whole before/after comparison meaningless.

### PHASE 1 — Conditional Load (based on refactor type)

| Include | RENAME | EXTRACT/SPLIT | INLINE | RESTRUCTURE |
|---------|--------|---------------|--------|-------------|
| `../../../shared/includes/env-compat.md` | Full | Full | Full | Full |
| `../../../shared/includes/quality-gates.md` | **SKIP** | CQ section only | CQ section only | Full |
| `../../../rules/cq-patterns.md` | **SKIP** | **SKIP** | Full | Full |
| `../../../rules/cq-checklist.md` | **SKIP** | **SKIP** | **SKIP** | Full |
| `../../../rules/file-limits.md` | **SKIP** | Full | **SKIP** | Full |
| `../../../rules/testing.md` | If tests affected | If tests affected | If tests affected | Full |
| `../../../shared/includes/test-edge-cases.md` | **SKIP** | If tests affected | **SKIP** | If tests affected |
| `../../../rules/security.md` | **SKIP** | **SKIP** | **SKIP** | If security-sensitive |

Print loaded files:
```
PHASE 1 — LOADED:
  [list with READ/SKIP status per file]
```

### DEFERRED — Load at completion

```
  ../../../shared/includes/run-logger.md        -- [READ at final step]
  ../../../shared/includes/retrospective.md     -- [READ at final step]
  ../../../shared/includes/documentation-mandate.md -- [READ at final step]
  ../../../shared/includes/knowledge-prime.md   -- [READ at start if available | MISSING -> degraded]
  ../../../shared/includes/knowledge-curate.md  -- [READ at final step if available | MISSING -> degraded]
```

A missing required definition blocks its dependent phase. Optional enrichment marked WARN degrades only that enrichment.

---

## Argument Parsing

### Execution Modes (mutually exclusive)

```
$ARGUMENTS = empty         -> FULL mode (default)
$ARGUMENTS = "full"        -> FULL mode (explicit)
$ARGUMENTS = "batch <file>"-> BATCH mode (process queue file, zero stops)
$ARGUMENTS = other         -> task description, FULL mode
```

### Control Flags

```
"no-commit"                -> Skip auto-commits (show diff + proposed message instead)
"plan-only"                -> Stop after the approval gate (Phase 1). Do not enter Phase 2 or Phase 3.
"continue"                 -> RESUME: scan zuvo/contracts/refactor-*.json, resume active contract
"continue <path>"          -> RESUME: user passes readable file path (e.g., src/services/order.service.ts), skill computes hash internally to find zuvo/contracts/refactor-{hash}.json
```

**Flag priority rules:**
- `continue` has highest priority: it overrides flags (except `no-commit`). Mode is always `full` — if the contract was created with a legacy mode (`quick`/`standard`/`auto`), silently upgrade to `full` and log the migration.
- `no-commit` and `plan-only` combine freely: `zuvo:refactor no-commit` runs full mode without committing. Contract stage is set to `EXECUTION_COMPLETE` (not `COMPLETE`) so `continue` can resume from the uncommitted state.
- `plan-only` and `continue` are mutually exclusive (continue resumes past the plan phase).

---

## Phase 0: Stack Detection and CodeSift Setup

### Knowledge Prime

Run `knowledge-prime.md`: `WORK_TYPE = "implementation"`, `WORK_KEYWORDS = <target file/module names>`, `WORK_FILES = <files to refactor>`.

### Tech Stack

Detect the project's tech stack from config files:

| Signal | Stack | Rules to load |
|--------|-------|--------------|
| `tsconfig.json` | TypeScript | `../../../rules/typescript.md` |
| `package.json` with `next` | Next.js | `../../../rules/react-nextjs.md` |
| `package.json` with `@nestjs/core` | NestJS | `../../../rules/nestjs.md` |
| `pyproject.toml` or `.py` files | Python | `../../../rules/python.md` |
| `composer.json` | PHP | `../../../rules/php.md` |
| `composer.json` with `yiisoft/yii2` | Yii2 | `../../../rules/yii2.md` (with php.md) |
| `astro.config.*` | Astro | `../../../rules/astro.md` |
| `go.mod` | Go | `../../../rules/go.md` |
| `Cargo.toml` | Rust | `../../../rules/rust.md` |
| `*.csproj` / `*.sln` | .NET | `../../../rules/dotnet.md` |
| `Gemfile` | Ruby | `../../../rules/ruby.md` |
| `vitest.config.*` | Vitest test runner | |
| `jest.config.*` | Jest test runner | |

Print: `STACK: [language] | RUNNER: [test runner]`

### CodeSift Setup

Follow `codesift-setup.md`: check availability, then **resolve repo identity before the pre-scan** —
not after the commit. Every pre-scan call below is scoped to a repo, and in a linked worktree an
unresolved scope answers about the PARENT checkout's copy of the file.

```bash
TARGET_REPO=$(git -C "<scope>" rev-parse --show-toplevel)   # the tree this run refactors
```

If `index_status` reports a root other than `$TARGET_REPO` (or reports `indexed=true` with a file
count matching the parent), run `index_folder(path=$TARGET_REPO)` **once** — per `codesift-setup.md`
step 2 that is not a re-index, it is the first index of a tree that has none. Then `index_file` per
changed file. Do **NOT** call `list_repos()`: the repo auto-resolves from CWD, `codesift-setup.md:19`
says to skip it, and all three sub-agents are told the orchestrator already owns the identifier.

### Pre-Scan

Run 6 analysis calls to understand WHAT to refactor before planning HOW:

1. `analyze_complexity(repo, top_n=10, file_pattern=SCOPE)` -- Is the target among the most complex files? Which functions are worst?
2. `analyze_hotspots(repo, since_days=90)` -- Is the target a churn hotspot? Changed often + complex = high-value refactor.
3. `find_clones(repo, min_similarity=0.7, file_pattern=SCOPE)` -- Copy-paste blocks with other files? DRY extraction candidates.
4. `find_dead_code(repo, file_pattern=SCOPE)` -- Unused exports in scope. Delete BEFORE refactoring (less code to move).
5. `classify_roles(repo, file_pattern=SCOPE)` -- Symbol role classification: dead/leaf/core/entry
6. `find_circular_deps(repo, file_pattern=SCOPE)` -- Cycle detection for BREAK_CIRCULAR type

Print:

```
REFACTOR PRE-SCAN
------------------------------------
Complexity: target ranks #N/10 (cyclomatic X, function: Y)
Hotspot:    changed N times in 90 days (rank in repo)
Clones:     N blocks (X% similar) with [file:lines]
Dead code:  N unused exports ([names])
Roles:      N dead symbols (delete first), N leaf (safe to move), N core (careful)
Cycles:     [N cycles detected | no cycles]
------------------------------------
```

Feed pre-scan data into the extraction plan:
- Clone blocks -> extract to shared module. Dead exports -> delete before refactoring.
- Highest-complexity functions -> prioritize splitting these first. Hotspot confirmation -> validates high-value.
- `classify_roles`: dead = delete before refactoring, leaf = safe extraction, core = careful handling, entry = do not move without re-export.

When CodeSift unavailable: skip pre-scan. Log `[DEGRADED: classify_roles/find_circular_deps unavailable]`.

---
