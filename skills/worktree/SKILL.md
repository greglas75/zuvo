---
name: worktree
description: >
  Isolate work in a git worktree. Activates when the user needs branch isolation
  before executing a plan, wants a clean environment for a feature, or is ready
  to finish work in an existing worktree.
---

# zuvo:worktree

Git worktree isolation with structured completion options.

Two modes: **CREATE** (set up a new worktree) and **FINISH** (wrap up work in the current worktree).

Detect mode automatically:
- If the current directory IS inside a worktree (check `git worktree list`), default to FINISH.
- If the current directory is the main checkout, default to CREATE.
- If the user explicitly says "create" or "finish", honor that regardless.

---

## CREATE Mode

### Step 1: Determine Worktree Directory

Check these sources in order. Use the first match:

1. **Existing convention** -- Run `ls -d .worktrees 2>/dev/null`. If `.worktrees/` exists at repo root, use it.
2. **Project instructions preference** -- Search project `AGENTS.md` or `CLAUDE.md` for a `worktree` or `worktrees` section that declares a preferred directory path.
3. **Ask the user** -- Present two options:
   - `.worktrees/` (recommended, keeps repo root clean)
   - Custom path

Store the chosen directory as `WTDIR`.

### Step 2: Verify .gitignore Coverage

Check whether `WTDIR` is covered by `.gitignore`:

```bash
git check-ignore -q "$WTDIR" 2>/dev/null
```

If exit code is non-zero (not ignored):
1. Append `WTDIR` pattern to `.gitignore` (e.g., `.worktrees/`).
2. Stage and commit: `git add .gitignore && git commit -m "chore: add worktree directory to .gitignore"`.
3. Report what was done.

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
4. Switch to main checkout: `cd` to the main worktree path (from `git worktree list`).
5. Pull latest base: `git checkout <base> && git pull`.
6. Merge: `git merge <feature-branch>`.
7. If merge conflict occurs: report conflicts and STOP. Do not auto-resolve. Tell the user which files conflict and wait for instructions.
8. If merge succeeds: run tests again on the merged result. Report pass/fail.
9. Cleanup worktree: `git worktree remove "$WTDIR/<branch-name>"`.
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
7. Cleanup worktree: `git worktree remove "$WTDIR/<branch-name>"`.
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
   - `cd` to main worktree path.
   - Remove worktree: `git worktree remove --force "$WTDIR/<branch-name>"`.
   - Delete branch: `git branch -D <feature-branch>`.
4. If the branch was pushed to remote, warn: "Branch exists on remote. Delete remote branch too?" If yes: `git push origin --delete <feature-branch>`.

Report: "Worktree and branch <name> discarded."

---

## Safety Rules

These apply across both modes:

1. **Never force-push.** If a push is rejected, report the conflict and ask for instructions.
2. **Never rebase without consent.** If the user asks for rebase, confirm they understand it rewrites history.
3. **Never delete `main` or `master`.** If a deletion command would target these branches, refuse and explain why.
4. **Always verify tests before merge.** Options 1 and 2 run tests before the destructive step. If tests fail, the user must explicitly choose to proceed.
5. **Always confirm before discard.** Option 4 requires typed confirmation. No shortcuts.
6. **Uncommitted changes block FINISH.** All four finish options require a clean working tree. Prompt the user to commit or stash first.
7. **Report, do not assume.** When detecting base branches, test runners, or setup commands, report what was detected and what will run before running it.

---

## Auto-Docs

After completing the skill output, update per `{plugin_root}/shared/includes/auto-docs.md`:

- **project-journal.md**: Log the worktree operation scope, key findings, and verdict.

---

## Session Memory

After Auto-Docs, update `memory/project-state.md` per `{plugin_root}/shared/includes/session-memory.md`:

- **Recent Activity**: Prepend entry with worktree operation summary and verdict.

---

## Run Log

Log this run to `memory/zuvo-runs.log` per `shared/includes/run-logger.md`:
- SKILL: `worktree`
- CQ_SCORE: `-`
- Q_SCORE: `-`
- VERDICT: PASS if worktree operation completed, ABORTED if user cancelled
- TASKS: `-`
- DURATION: mode label (`start` or `finish-N`)
- NOTES: branch name + operation (e.g., `feature/export — merged to main`)
