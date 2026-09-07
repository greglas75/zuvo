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

### PHASE 0 — Commit-gate activation (record the actual exit status)

Ensure the refactor commit-gate is active for this checkout. The installer preserves existing
hooks. In a linked worktree with `extensions.worktreeConfig` already enabled and a recognized
Zuvo dispatcher, it selects private hooks using `git config --worktree core.hooksPath`. These
run the current guard and retain the original hook chain; shared hooks and configuration stay
unchanged. It does not enable the shared worktree-config extension automatically.
The installer reports nonzero when it cannot activate both hooks. Record that as unavailable, never
installed/PASS. Continue analysis and explicit verification, but do not claim automatic commit
enforcement; resolve activation before claiming the complete workflow. Do not modify a shared
or version-controlled hook merely to turn the status green.

Resolve the installed root for the **current harness** from the execution policy first
(Codex: `~/.codex`, Claude Code: its active plugin root). Do not choose another harness's cache
just because `ls | head` finds it first. Substitute the two actual paths below, and preserve the
command's exit status and diagnostic in the stage receipt.

```bash
(
set -e
_TARGET_PATH="<actual target file or directory>"
_INSTALL_ROOT="<installed root for the current harness>"
if [ -f "$_TARGET_PATH" ]; then _TARGET_PATH=$(dirname "$_TARGET_PATH"); fi
TARGET_REPO=$(git -C "$_TARGET_PATH" rev-parse --show-toplevel)
_GATE="$_INSTALL_ROOT/hooks/refactor-safety-gate.sh"
[ -f "$_GATE" ] || _GATE="$_INSTALL_ROOT/scripts/refactor-safety-gate.sh"
_INST="$_INSTALL_ROOT/scripts/install-refactor-gate.sh"
_HARNESS="unavailable (detector missing)"
_DETECTOR="$(dirname "$_GATE")/lib/agent-env.sh"
if [ -r "$_DETECTOR" ]; then
  . "$_DETECTOR"
  if zuvo_is_agent_env; then _HARNESS=active; else _HARNESS="human (gate bypass)"; fi
fi
_ACTIVATION_RC=2
if [ -f "$_GATE" ] && [ -f "$_INST" ]; then
  if sh "$_INST" "$_GATE" "$TARGET_REPO"; then
    _ACTIVATION_RC=0
    echo "[refactor-gate] activation=verified"
  else
    _ACTIVATION_RC=$?
    echo "[refactor-gate] activation=unavailable; preserve installer diagnostic"
  fi
else
  echo "[refactor-gate] activation=unavailable; missing gate or installer under $_INSTALL_ROOT"
fi
echo "[refactor-gate] exit=$_ACTIVATION_RC repo=$TARGET_REPO gate=$_GATE harness=$_HARNESS"
exit "$_ACTIVATION_RC"
)
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

Use the execution policy's exact repository identifier and indexing permission. A parent checkout
index is stale evidence for a linked worktree. If indexing this checkout is forbidden, use current
file reads and native analysis once and pass that decision to nested stages. Do not repeatedly
ask a known-stale index to audit the new code.

### Pre-Scan

Collect caller/re-export references, duplicate candidates and cycle risk for the requested scope.
Use current-index semantic tools when available and permitted; otherwise search the actual files.
For a user-selected identical-helper extraction, verify those bodies and their callers directly.
Do not run repository-wide hotspot rankings or dead-code inventories to rediscover an already
selected target. Broader restructures additionally need scoped complexity and role analysis;
cycle-breaking work needs the actual cycle graph. Out-of-scope dead code is a finding, not an
instruction to delete it before the requested refactor.

Print:

```
REFACTOR PRE-SCAN
------------------------------------
Complexity: [scoped metric + analyzer | skipped(reason) | unavailable]
Hotspot:    [scoped result | skipped(reason) | unavailable]
Clones:     [verified duplicate bodies + file:lines | none found | unavailable]
Dead code:  [scoped findings | skipped(reason) | unavailable]
Roles:      [scoped role findings | skipped(reason) | unavailable]
Cycles:     [scoped cycle evidence | unavailable]
------------------------------------
```

Use the results in the plan and record unavailable analyses honestly. Preserve the user's behavior
scope; unrelated clone, hotspot or dead-code findings do not expand the change.

---
