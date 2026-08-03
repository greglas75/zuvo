---
name: worktree
description: >
  Isolate work in a git worktree. Activates when the user needs branch isolation
  before executing a plan, wants a clean environment for a feature, is ready
  to finish work in an existing worktree, or wants to reclaim worktrees that
  accumulated and are now polluting filesystem-level measurement.
codesift_tools:
  always:
    - analyze_project
    - index_status
    - plan_turn
    - get_file_tree
  by_stack: {}                  # git ops only, no code analysis
---

# zuvo:worktree

Git worktree isolation with structured completion options.

Three modes: **CREATE** (set up a new worktree), **FINISH** (wrap up work in the current worktree), and **PRUNE** (reclaim finished worktrees and fix a nested layout).

Detect mode automatically:
- If the user explicitly says "create", "finish", or "prune"/"cleanup", honor that regardless.
- If the current directory IS inside a worktree (check `git worktree list`), default to FINISH.
- If the current directory is the main checkout, default to CREATE.

---

## CREATE Mode

### Step 0: Accumulation Precheck

Run PRUNE steps 1-2 (bookkeeping reconcile + classification) in report-only form. Removing nothing, print one line:

```
Worktrees in this repo: <n> live (<n> reclaimable, <n> idle >30d). Layout: <sibling | NESTED>.
```

If reclaimable or nested worktrees exist, point at `zuvo:worktree prune` and continue with CREATE. Never block CREATE on cleanup.

### Step 1: Determine Worktree Directory

Compute the default first -- it is a **sibling of the repo, never a child**:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_NAME=$(basename "$REPO_ROOT")
DEFAULT_WTDIR="$(dirname "$REPO_ROOT")/${REPO_NAME}-worktrees"
```

Resolution order. Use the first match, do NOT ask the user:

1. **`$ZUVO_WORKTREE_DIR`** if set -- absolute path, or relative to `$REPO_ROOT`.
2. **Project instructions preference** -- a `worktree`/`worktrees` section in the project `AGENTS.md` or `CLAUDE.md` that declares a directory. If the declared path is inside `$REPO_ROOT`, honor it but emit the nested-layout warning below.
3. **Existing sibling** -- `$DEFAULT_WTDIR` already exists.
4. **Existing nested directory (LEGACY)** -- `.worktrees/`, `worktrees/`, or `.claude/worktrees/` inside `$REPO_ROOT`. Use it so worktrees for one repo do not end up split across two locations, but you MUST emit the nested-layout warning and offer the PRUNE-mode migration in the same turn.
5. **Default** -- `$DEFAULT_WTDIR`. Create it with `mkdir -p`.

Store the chosen directory as `WTDIR`.

**Why the default is a sibling, not `.worktrees/` inside the repo.** A nested worktree is a second full checkout of the same files living inside the tree. `.gitignore` hides it from git and from nothing else -- every filesystem-level consumer still walks it: code indexers, `find`/`rg`, cloc, test globs, bundler entry scans, Docker build context. Worse, an indexer that resolves a repo from a path resolves a nested worktree to its **path ancestor**, i.e. the parent repo, so edits made inside the worktree land in the parent's index (this is CodeSift hint `H19`). Measured on one repo 2026-08-02: 94 of 916 files in the index were duplicate copies from `.worktrees/`, which corrupted clone detection, boundary checks and role classification. A sibling directory has no ancestor relationship with the repo root, so none of it happens -- and no `.gitignore` entry is needed at all.

**Nested-layout warning** (emit verbatim when `WTDIR` resolves inside `$REPO_ROOT`):

```
NESTED WORKTREE LAYOUT -- measurement is unreliable in this repo.
  <WTDIR> is inside the repo, so filesystem-level tools count every file N+1 times
  (indexers, cloc, duplication scans, glob-based test discovery).
  Fix: zuvo:worktree prune  -- migrates existing worktrees to <DEFAULT_WTDIR>.
```

### Step 2: Verify .gitignore Coverage

Only applies when `WTDIR` is inside `$REPO_ROOT` (legacy layouts). A sibling `WTDIR` is outside the repo and needs no ignore rule -- skip this step entirely and say so.

For a nested `WTDIR`, check coverage:

```bash
git check-ignore -q "$WTDIR" 2>/dev/null
```

If exit code is non-zero (not ignored):
1. Append the `WTDIR` pattern to `.gitignore`.
2. Stage and commit: `git add .gitignore && git commit -m "chore: add worktree directory to .gitignore"`.
3. Report what was done -- and repeat that ignoring it does not remove the measurement problem, only the git noise.

### Step 3: Create Worktree

Determine branch name:
- If the user provided a name, use it.
- If a spec or plan document exists (from pipeline), derive from the topic slug (e.g., `feat/add-user-auth`).
- Otherwise ask the user for a branch name.

Safety check -- NEVER create a worktree on `main` or `master` without explicit user consent. If the user requests it, confirm: "You are about to branch from and work directly on the main branch. Confirm by typing the branch name."

Run:
```bash
git worktree add "$WTDIR/<branch-name>" -b "<branch-name>"
```

If the branch already exists (exit code non-zero), report and ask user whether to:
- Use the existing branch: `git worktree add "$WTDIR/<branch-name>" "<branch-name>"`
- Pick a different name

After creation, `cd` into the new worktree directory.

### Step 4: Project Setup

Auto-detect the project's dependency system and run setup:

| File detected | Command |
|---------------|---------|
| `package-lock.json` | `npm ci` |
| `package.json` (no lockfile) | `npm install` |
| `yarn.lock` | `yarn install --frozen-lockfile` |
| `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` |
| `bun.lockb` | `bun install` |
| `requirements.txt` | `pip install -r requirements.txt` |
| `pyproject.toml` | `pip install -e .` or `poetry install` (check for `[tool.poetry]`) |
| `Cargo.toml` | `cargo build` |
| `go.mod` | `go mod download` |
| `Gemfile` | `bundle install` |
| `composer.json` | `composer install` |

If multiple apply (e.g., monorepo), run all relevant commands.

If no recognized file is found, skip setup and note: "No dependency file detected. Skipping setup."

### Step 5: Verify Baseline

Run the project's test command to establish a green baseline:

1. Detect test runner from config files (`vitest.config.*`, `jest.config.*`, `pytest.ini`, `phpunit.xml`, `Cargo.toml`, etc.) or `package.json` scripts.
2. Run the test command.
3. Report result:
   - **All pass** -- "Baseline green. N tests passed. Ready to work."
   - **Failures detected** -- "Baseline has N failing tests. These failures exist on the base branch, not caused by this worktree." Then ask: "Proceed anyway, or investigate first?"
   - **No test command found** -- "No test runner detected. Skipping baseline verification."

### CREATE Output

Report:
```
Worktree created.
  Path:   <absolute path>
  Branch: <branch-name>
  Base:   <base-branch> @ <short-hash>
  Setup:  <what was installed>
  Tests:  <pass count> / <total count> passing
```

---

## FINISH Mode

### Step 0: Resolve paths (FINISH is a standalone entry point)

FINISH is reached by standing INSIDE a worktree in a fresh invocation, so it inherits nothing from
CREATE — `WTDIR` does not exist here. Resolve the two paths every option below needs, from git:

```bash
WT_PATH=$(git rev-parse --show-toplevel)                              # the worktree being finished
MAIN_ROOT=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')   # the main checkout
```

Use `$WT_PATH` for removal — never `$WTDIR/<branch>`. Until 2026-08-02 all three options removed
`"$WTDIR/<branch-name>"` with `WTDIR` unset, so the path collapsed to `/<branch-name>`:
`git worktree remove` failed, the worktree survived, and the skill still reported "Worktree
removed." A silent no-op on the cleanup step, and Option 4 ran it with `--force`.

You cannot remove the worktree you are standing in — `cd "$MAIN_ROOT"` first in every option that
removes.

Present four completion options. The user picks one.

Before presenting options, summarize the current state:
- Branch name and base branch
- Number of commits ahead of base
- Uncommitted changes (if any -- warn that these must be committed or stashed first)

If uncommitted changes exist, do NOT proceed until they are resolved. Ask the user to commit or stash.

### Option 1: Merge Locally

Merge the feature branch into its base branch on this machine.

Steps:
1. Ensure working tree is clean (`git status --porcelain` produces no output).
2. Run tests in the worktree. If failures exist, report and ask whether to proceed.
3. Determine base branch: `git log --oneline --merges --first-parent -1` or parse from worktree creation context. If unclear, ask.
4. Switch to the main checkout: `cd "$MAIN_ROOT"`.
5. Pull latest base: `git checkout <base> && git pull`.
6. Merge: `git merge <feature-branch>`.
7. If merge conflict occurs: report conflicts and STOP. Do not auto-resolve. Tell the user which files conflict and wait for instructions.
8. If merge succeeds: run tests again on the merged result. Report pass/fail.
9. Cleanup worktree: `git worktree remove "$WT_PATH"`.
10. Delete feature branch: `git branch -d <feature-branch>`.

Report: "Merged <branch> into <base>. Tests: N passing. Worktree removed."

### Option 2: Push + Pull Request

Push the branch and open a PR via GitHub CLI.

Steps:
1. Ensure working tree is clean.
2. Run tests. If failures, report and ask whether to proceed.
3. Push: `git push -u origin <feature-branch>`.
4. Collect PR information:
   - Title: derive from branch name or ask user.
   - Body: summarize commits on the branch (`git log <base>..<feature-branch> --oneline`).
   - Ask user if they want to edit title/body before creation.
5. Create PR:
   ```bash
   gh pr create --title "<title>" --body "<body>" --base "<base-branch>"
   ```
6. Report the PR URL.
7. Leave the worktree first, then remove it: `cd "$MAIN_ROOT" && git worktree remove "$WT_PATH"`.
8. Do NOT delete the branch (it is now tracked by the PR).

Report: "PR created: <url>. Worktree removed. Branch preserved on remote."

### Option 3: Keep As-Is

Preserve everything for later.

Steps:
1. Report current state:
   ```
   Worktree preserved.
     Path:   <absolute path>
     Branch: <branch-name>
     Commits ahead: N
     Status: <clean / N uncommitted changes>
   ```
2. No cleanup. No branch deletion. No worktree removal.

Report: "Worktree kept at <path>. Resume anytime by opening that directory."

### Option 4: Discard

Destroy the worktree and all uncommitted work. This is irreversible.

Steps:
1. Require explicit confirmation. Ask the user to type the word `discard` (case-insensitive).
2. If the user types anything else, abort and return to option selection.
3. After confirmation:
   - `cd "$MAIN_ROOT"`.
   - Remove worktree: `git worktree remove --force "$WT_PATH"`.
   - Delete branch: `git branch -D <feature-branch>`.
4. If the branch was pushed to remote, warn: "Branch exists on remote. Delete remote branch too?" If yes: `git push origin --delete <feature-branch>`.

Report: "Worktree and branch <name> discarded."

---

## PRUNE Mode

Worktrees accumulate. CREATE makes them, FINISH removes only the one you are standing in, and nothing ever revisits the rest -- so a repo silently grows dozens of stale checkouts that keep inflating every filesystem-level measurement. PRUNE is the sweep that closes that loop.

Run it when the user asks to clean up worktrees, and as a report-only precheck at the start of CREATE (steps 1-2 only; never remove anything during CREATE).

PRUNE never uses `--force`, never touches a worktree with uncommitted or unmerged work, and never runs `git fetch`. It removes only what is provably reclaimable.

### Step 0: Resolve paths (PRUNE is a standalone entry point)

PRUNE is normally invoked on its own, so it cannot inherit anything from CREATE. Re-derive the two
paths its later steps use, exactly as CREATE Step 1 does:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
DEFAULT_WTDIR="${ZUVO_WORKTREE_DIR:-$(dirname "$REPO_ROOT")/$(basename "$REPO_ROOT")-worktrees}"
```

### Step 1: Reconcile bookkeeping

```bash
git worktree prune -v
```

This drops admin records for worktree directories that no longer exist. It deletes no files and touches no branches. Report how many records were cleared.

### Step 2: Classify every live worktree

Determine the default branch once:

```bash
BASE=$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's|^origin/||')
BASE=${BASE:-$(git rev-parse --verify -q main >/dev/null && echo main || echo master)}
```

For each entry in `git worktree list --porcelain`, excluding the main checkout and the worktree the current directory is in:

| Signal | Command | Meaning |
|--------|---------|---------|
| Dirty | `git -C <wt> status --porcelain` non-empty | uncommitted work |
| Merged | `git -C <wt> merge-base --is-ancestor HEAD "$BASE"` exit 0, **or** the same against `origin/$BASE` | every commit already in base |
| Age | `git -C <wt> log -1 --format=%cr` | how long since last commit |

Classify:

- **RECLAIMABLE** -- clean AND merged. Zero data at risk: the commits exist in the base branch and nothing is uncommitted.
- **IDLE** -- clean, not merged, last commit older than `$ZUVO_WORKTREE_IDLE_DAYS` (default 30). Report only. Never removed automatically -- unmerged commits are work.
- **ACTIVE** -- everything else. Not listed as a candidate.

Checking against both the local and the remote-tracking base means a stale local `main` produces false ACTIVE/IDLE, never a false RECLAIMABLE.

### Step 3: Remove RECLAIMABLE only

For each RECLAIMABLE worktree:

```bash
git worktree remove "<path>"        # NEVER --force
git branch -d "<branch>"            # safe delete; refuses if unmerged
```

Both commands are safe by construction. `git worktree remove` without `--force` refuses when untracked files are present (a local `.env`, a build artifact, an uncommitted scratch file) -- that refusal is the intended backstop, not an error. Collect those as SKIPPED with the reason and move on.

### Step 4: Layout check -- the part that prevents recurrence

If any remaining worktree path is under `$REPO_ROOT`, migrate it out:

```bash
git worktree move "<repo>/.worktrees/<name>" "$DEFAULT_WTDIR/<name>"
```

`git worktree move` relocates the checkout and rewrites its gitdir pointers, so no work is lost and no branch changes. It fails on a locked worktree, one containing submodules, or one with a dirty index -- report those individually and leave them in place rather than forcing.

Once the nested directory is empty, remove it and drop its now-dead `.gitignore` entry.

### Step 5: Index hygiene

Removing a directory does not remove what it already put in a code index -- stale worktree paths and their duplicate symbols persist until the repo is re-indexed. After any removal or migration, tell the user to re-index (CodeSift: `index_folder(path=<repo root>)`), otherwise clone, boundary and centrality metrics stay corrupted by files that no longer exist.

### PRUNE Output

```
WORKTREE PRUNE COMPLETE
  Records cleared:  <n> (directories already gone)
  Reclaimed:        <n>  <branch list>
  Skipped:          <n>  <path -- reason>
  Idle (>30d):      <n>  <branch -- last commit age>
  Active:           <n>
  Layout:           <sibling, clean | migrated <n> out of <nested dir> | NESTED, <n> not migrated>
  Re-index:         <required | not needed>
```

---

## Run Log (REQUIRED)

This skill removes worktrees, deletes branches, and can delete a remote branch — the only three
destructive-git skills in the set, and until 2026-08-02 the only one of the 57 that recorded
nothing. Load `../../shared/includes/run-logger.md` and append one line per invocation:

```
Run: <ISO-8601-Z>	worktree	<project>	-	-	<VERDICT>	-	<MODE>	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
```

`<MODE>`: `create` | `finish-<option>` | `prune`. `<VERDICT>`: `PASS` when the mode completed,
`WARN` when something was skipped (dirty worktree, refused removal), `FAIL` on an aborted merge or
a removal that errored. `<NOTES>`: what was actually destroyed — `removed <n> wt, deleted <n>
branch` — capped at 80 chars. `<TIER>`: `-`.

Append via the wrapper, never `>>` directly:

```bash
printf '%b\n' "$RUN_LINE" | ~/.zuvo/append-runlog
```

On exit 2 with `RETRO_REQUIRED`, run the retrospective from
`../../shared/includes/retrospective.md` first; never bypass with `ZUVO_SKIP_RETRO_GATE=1`.

---

## Safety Rules

These apply across all three modes:

1. **Never force-push.** If a push is rejected, report the conflict and ask for instructions.
2. **Never rebase without consent.** If the user asks for rebase, confirm they understand it rewrites history.
3. **Never delete `main` or `master`.** If a deletion command would target these branches, refuse and explain why.
4. **Always verify tests before merge.** Options 1 and 2 run tests before the destructive step. If tests fail, the user must explicitly choose to proceed.
5. **Always confirm before discard.** Option 4 requires typed confirmation. No shortcuts.
6. **Uncommitted changes block FINISH.** All four finish options require a clean working tree. Prompt the user to commit or stash first.
7. **Report, do not assume.** When detecting base branches, test runners, or setup commands, report what was detected and what will run before running it.
8. **Never default a worktree inside the repo.** New worktrees go to `../<repo>-worktrees/`. A nested directory is honored only when it already exists or a project instruction declares it, and only alongside the nested-layout warning.
9. **PRUNE removes only provably reclaimable worktrees.** Clean AND merged into base, verified against both the local and remote-tracking base. No `--force` in any prune command, ever. Dirty, unmerged, locked, or current-directory worktrees are reported, never touched.
