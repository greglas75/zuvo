---
name: worktree
description: >
  Isolate work in a git worktree. Activates when the user needs branch isolation
  before executing a plan, wants a clean environment for a feature, is ready
  to finish work in an existing worktree, or wants to reclaim worktrees that
  accumulated and are now polluting filesystem-level measurement.
category: Pipeline
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

## Non-interactive runs

When no user can answer (headless `-p` / `exec` runs, batch pipelines), every "ask" below resolves
to STOP, never to a choice made for the user: end with `[WORKTREE] BLOCKED: <the question and its
options>` and change nothing further. This table takes precedence over the prose of each step: a
decision point it lists gets the default shown (some are "proceed"), and an "ask" it does not list
stops.

| Decision point | Non-interactive default |
|---|---|
| branch name not given, no spec/plan topic | stop |
| branch already exists | stop; never reuse it |
| baseline has failing tests | proceed; report `baseline red (<n> failing)` |
| PR title/body (Option 2) | derive from the commits; no edit prompt |
| FINISH without a chosen option | stop; print the four options |
| tests fail before a merge or push (Options 1-2) | stop |
| base branch not determinable (Option 1) | stop |
| `discard` confirmation (Option 4), a worktree on `main`/`master` | refuse: both need typed words from a user |
| delete the remote branch (Option 4) | do not delete; report that it exists |

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

**Pin the base explicitly.** `git worktree add -b <name> <path>` with no start-point branches from
whatever the main checkout's HEAD happens to be at that moment, so a batch of worktrees created a
few minutes apart silently lands on different bases whenever the parent moves — a commit, a pull, a
branch switch between two creations is enough. Measured on one repo: **34 worktrees split across 4
different bases** (26 on `91d2c64`, 6 on `f8de6d9`, and two singletons), which is four separate
green baselines to establish instead of one, and four different sets of code to reason about when
comparing their results.

Resolve the base once, name it in the command, and report it:

```bash
# The base a batch should share. Default: the current HEAD, resolved to a SHA so it cannot move
# under a later worktree in the same batch. Override with $ZUVO_WORKTREE_BASE to pin a whole batch
# to one commit deliberately (e.g. `origin/main` fetched once at the start).
BASE_REF="${ZUVO_WORKTREE_BASE:-HEAD}"
BASE_SHA=$(git rev-parse "$BASE_REF") || { echo "cannot resolve base '$BASE_REF'"; exit 1; }

# Directory name = the branch with `/` replaced by `-` (`feat/x` -> `feat-x`): a slash would nest
# the worktree one level deeper, where Step 4's donor scan and PRUNE's listing never look.
WT_NAME=$(printf '%s' "<branch-name>" | tr '/' '-')
# The branch FINISH Option 1 merges back into: a LOCAL branch only. A SHA, a tag or `upstream/x`
# is a starting point, not a destination, so nothing is recorded for it.
BASE_BRANCH="${ZUVO_WORKTREE_BASE:-$(git branch --show-current)}"; BASE_BRANCH="${BASE_BRANCH#origin/}"
git show-ref --verify --quiet "refs/heads/$BASE_BRANCH" || BASE_BRANCH=""
if git worktree add "$WTDIR/$WT_NAME" -b "<branch-name>" "$BASE_SHA"; then
  [ -z "$BASE_BRANCH" ] || git config "branch.<branch-name>.zuvo-base" "$BASE_BRANCH"
  echo "worktree <branch-name> based on $(git rev-parse --short=7 "$BASE_SHA") ($BASE_REF)"
else
  echo "worktree add failed (branch or path already exists?)"; exit 1   # never `cd` into another worktree
fi
```

Report the base in the CREATE output. Two worktrees on the same base share a baseline (Step 5) and
their results are comparable; two on different bases share neither, and saying which is which costs
one line.

If the branch already exists (exit code non-zero), report and ask user whether to:
- Use the existing branch: `git worktree add "$WTDIR/$WT_NAME" "<branch-name>"` (if that path is taken, `feat/x` and `feat-x` map to the same directory: report the collision and stop)
- Pick a different name

After creation, `cd` into the new worktree directory.

### Step 4: Project Setup

**FIRST: reuse an identical dependency tree instead of installing one.** Skip this and every
worktree pays a full install it did not need.

Measured 2026-09-02 on `tgm-survey-platform`: worktrees were deliberately branched from ONE base
so their dependencies would be identical, and this step made each of them run `npm ci` anyway —
**three concurrent installs, 22 minutes each and still going**, on a laptop, for a tree a sibling
worktree already had on disk. On APFS (macOS) and on any filesystem with reflinks, copying that
tree is a copy-on-write clone: near-instant and costing no extra disk.

So, in order, before consulting the table below:

1. **Find a donor.** A sibling worktree — or the main checkout — whose lockfile is byte-identical
   to this one:

   ```bash
   want=$(shasum -a256 package-lock.json | cut -d' ' -f1)
   for cand in "$MAIN_ROOT" "$WTDIR"/*/; do
     [ -d "$cand/node_modules" ] || continue
     [ "$(shasum -a256 "$cand/package-lock.json" 2>/dev/null | cut -d' ' -f1)" = "$want" ] || continue
     DONOR="$cand"; break
   done
   ```

   Identical lockfile is the whole condition, and it is the same fact Step 4.5 verifies. A donor
   with a different lockfile is not a donor — that is the cross-branch contamination Step 4.5
   exists to catch.

2. **Clone it, do not copy it.**

   ```bash
   cp -Rc "$DONOR/node_modules" node_modules 2>/dev/null   # macOS/APFS: reflink
   cp -R --reflink=auto "$DONOR/node_modules" node_modules # GNU coreutils
   ```

   If neither reflink form is available, fall through to the install rather than a plain `cp -R`:
   a real byte copy of ~1 GB per worktree buys little over the install and costs the disk.

   **Never symlink `node_modules` to another worktree.** Measured the same week: a symlinked tree
   pointed at a worktree that was later removed, and a 730-mutant Stryker run died ten minutes in
   on vanished dependencies — a crash that reads as a test failure. A clone is independent; a
   symlink is a shared fate.

3. **Record which path ran** in the completion block: `deps: cloned from <donor>` or
   `deps: installed (no donor with a matching lockfile)`.

4. **Then run Step 4.5 exactly as written** — the clone is *not* exempt. It is the case that
   "looks fine", which is precisely when that check earns its keep.

**Only if no donor matched**, auto-detect and install:

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

### Step 4.5: Prove the installed tree matches THIS branch's lockfile

Step 4 is an instruction, and an instruction that is skipped leaves no trace. The failure it lets
through is specific and it has already happened: a worktree ran its tests against dependency
versions from a **different branch** (TanStack v9 installed, v8 in the lockfile), so the suite
reported failures that did not exist in the code. Hours went into debugging the code instead of the
tree. Note where it did NOT happen: on the test farm, which does its own `npm ci` from the branch's
lockfile on every run. This is a local-only failure, which is exactly why nothing upstream caught it.

Two ways in, and the second is the one that bites: Step 4 never ran, or it ran while a
`node_modules` from another branch was already sitting there. **So run this check ALWAYS — most of
all when `node_modules` already exists**, because that is the case that looks fine.

```bash
# Print a verdict. A worktree with the wrong deps must not reach Step 5.
# The loop is ORDERED and `ls` is deliberately not used: `ls a b c` sorts its output, it does not
# preserve argument order, so `ls package-lock.json Gemfile | head -1` returns Gemfile. A JS repo
# with a Gemfile for its docs would have run `bundle check` and declared the JS tree verified —
# the exact miss this section exists to prevent.
LOCK=""
for f in package-lock.json pnpm-lock.yaml requirements.txt Gemfile yarn.lock; do
  [ -f "$f" ] && { LOCK="$f"; break; }
done
case "$LOCK" in
  package-lock.json) npm ls --depth=0 >/dev/null 2>&1 && echo "[WORKTREE] deps: OK (npm ls clean)" \
                       || echo "[WORKTREE] deps: MISMATCH — $(npm ls --depth=0 2>&1 | grep -ciE 'invalid|missing|extraneous') problem(s)" ;;
  pnpm-lock.yaml)    pnpm install --frozen-lockfile --lockfile-only >/dev/null 2>&1 && echo "[WORKTREE] deps: OK (frozen lockfile satisfied)" \
                       || echo "[WORKTREE] deps: MISMATCH — frozen lockfile not satisfied" ;;
  requirements.txt)  pip check >/dev/null 2>&1 && echo "[WORKTREE] deps: OK (pip check clean)" \
                       || echo "[WORKTREE] deps: MISMATCH — $(pip check 2>&1 | head -1)" ;;
  Gemfile)           bundle check >/dev/null 2>&1 && echo "[WORKTREE] deps: OK (bundle satisfied)" \
                       || echo "[WORKTREE] deps: MISMATCH — bundle check failed" ;;
  yarn.lock)         echo "[WORKTREE] deps: UNVERIFIED (yarn — no portable check across v1 and berry)" ;;
  *)                 echo "[WORKTREE] deps: UNVERIFIED (no checkable lockfile — say so, do not imply OK)" ;;
esac
```

**A monorepo can carry several of these.** The loop takes the first by the order above, which is a
heuristic, not a truth — so when more than one lockfile exists, run the check for EACH ecosystem
you actually installed in Step 4 and print a verdict line per ecosystem. One `OK` does not clear
the others.

Every branch is a READ. `pnpm` uses `--lockfile-only` rather than a plain `--frozen-lockfile`
install: a step whose job is to prove the tree matches must not modify the tree while proving it,
and an interrupted install would leave the worktree in a worse state than Step 4 produced while
having printed a verdict about a tree that no longer exists. `yarn` has no portable equivalent
across v1 and berry, so it is `UNVERIFIED` rather than a check that quietly passes on one major
version and errors on the other.

**On MISMATCH: re-run Step 4's install for this ecosystem, then re-run this check.** If it still
mismatches, STOP and report it — do not run the baseline. A red baseline caused by the wrong
dependency tree is the most expensive kind of wrong, because it looks exactly like a real
regression and sends the next hour into the code.

Carry the verdict into the CREATE output (`Deps:` line below). `UNVERIFIED` is an honest value;
printing `OK` for an ecosystem you did not check is not.

### Step 5: Verify Baseline

A green baseline is a property of the **commit**, not of the directory it was checked out into. Two
worktrees at the same SHA with the same installed dependencies cannot disagree about whether that
code's tests pass — so the suite is run once per (repo, commit, dependency set) and every worktree
sharing those three reuses the result. Measured across one 12-hour window of real runs: **12
worktrees branched from `55d2b46`, 7 from `f8de6d9`, 4 from `2d99475`**, each re-running the same
full suite over byte-identical code.

**1. Ask the cache first.**

```bash
ROOT=$(git rev-parse --show-toplevel)
if RESULT=$(~/.zuvo/baseline-cache check "$ROOT"); then
  echo "Baseline green (reused): $RESULT"
else
  # Capture the key BEFORE the suite runs. If HEAD moves, a lockfile changes, or an install
  # finishes while the tests are running, the result describes the OLD tree — recording it under
  # the new key would be a false green, so `record --key` refuses instead.
  KEY=$(~/.zuvo/baseline-cache key "$ROOT")

  # Detect the runner and RUN it — see the detection list below. Let it BLOCK.
  # Then record what happened, with an EXPLICIT verdict:
  ~/.zuvo/baseline-cache record "$ROOT" --key "$KEY" --result "$RESULT_TEXT" --green   # or --red
fi
```

`--green` / `--red` is mandatory and neither is the default: a missing flag used to record GREEN,
which is the one outcome that must never happen by omission. `record` exits non-zero if the flag is
absent, if both are given, or if the tree changed since `--key` was captured — in every case the
next worktree runs the suite rather than trusting an entry nobody can vouch for.

`check` exits non-zero — meaning *run the suite* — whenever anything differs or is unknown: a
different commit, a changed lockfile, a different repository, an entry older than 24 h, or a base
recorded RED. It fails **open**, so a cache problem costs a test run and never a false green. Only a
GREEN entry is ever reused; a RED one is kept so the next worktree can say "this base was already
failing" instead of rediscovering it, but it does not satisfy the check.

The dependency fingerprint is deliberate, not caution: identical source with a different
`node_modules` is a different baseline, which is the same fact Step 4.5 exists to prove. Keying on
every lockfile in the tree means a cache hit cannot smuggle a mismatched install past that gate.

**2. Run it, when the cache says to.**

1. Detect test runner from config files (`vitest.config.*`, `jest.config.*`, `pytest.ini`, `phpunit.xml`, `Cargo.toml`, etc.) or `package.json` scripts.
2. Run the test command. Let it BLOCK (`rt`, `rt --wait`) rather than polling it — see G5 and
   `../../shared/includes/env-compat.md`.
3. Record the outcome with `baseline-cache record ... --green` or `--red`, so the next worktree off
   this commit does not repeat it. Passing `--key` (captured before the run) is what makes the
   record trustworthy: without it, a tree that moved mid-suite is silently misfiled as verified.

**3. Report result:**
   - **All pass** -- "Baseline green. N tests passed. Ready to work." (say *(reused)* when it was)
   - **Failures detected** -- "Baseline has N failing tests. These failures exist on the base branch, not caused by this worktree." Then ask: "Proceed anyway, or investigate first?"
   - **No test command found** -- "No test runner detected. Skipping baseline verification."

`~/.zuvo/baseline-cache list` shows what is cached; `purge --older-than-hours N` clears it.

### CREATE Output

Report:
```
Worktree created.
  Path:   <absolute path>
  Branch: <branch-name>
  Base:   <base-branch> @ <short-hash>
  Setup:  <what was installed>
  Deps:   <OK (<check that proved it>) | UNVERIFIED (<why)>   # Step 4.5 — never blank
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

If uncommitted changes exist, Options 1-3 do NOT proceed until they are resolved: ask the user to
commit or stash. (Option 4 exists to discard them and lists them in its confirmation.)

### Option 1: Merge Locally

Merge the feature branch into its base branch on this machine.

Steps:
1. Ensure working tree is clean (`git status --porcelain` produces no output).
2. Run tests in the worktree. If failures exist, report and ask whether to proceed.
3. Determine the base branch: `git config branch.<feature-branch>.zuvo-base` (CREATE recorded it), else `git symbolic-ref --short refs/remotes/origin/HEAD` minus the `origin/` prefix. If neither answers, ask — never guess `main`.
4. **Check the main checkout BEFORE touching it:** `MAIN_STATUS=$(git -C "$MAIN_ROOT" status --porcelain) || stop` (a failed status is "cannot tell", never "clean"). Anything printed is the user's uncommitted work, and the checkout and pull below would carry it onto the base branch or merge into it. Stop: `FINISH BLOCKED: main checkout has uncommitted changes (<files>)`, ask the user to commit or stash them, and never stash or commit them yourself.
5. Switch to the main checkout and pull the base: `cd "$MAIN_ROOT" && git checkout <base>` (stop if it fails), then `git pull --ff-only` only when `git rev-parse --abbrev-ref "<base>@{upstream}"` succeeds (a base with no upstream skips the pull); a pull that cannot fast-forward stops the run.
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
1. List what will be lost (`git -C "$WT_PATH" status --short --ignored` plus the commits on no other branch), then require explicit confirmation: the user types the word `discard` (case-insensitive).
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

PRUNE never uses `--force`, never touches a worktree with uncommitted or unmerged work, never deletes a git-ignored local file, never commits, and never runs `git fetch`. It removes only what is provably reclaimable.

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
| Dirty | `git -C <wt> status --porcelain` non-empty | uncommitted or untracked work |
| Local files | `git -C <wt> status --porcelain --ignored` prints a `!! <path>` line that is not install/build output (`node_modules`, `dist`, `build`, `.turbo`, `.next`, `coverage`, `__pycache__`, `.pytest_cache`, `target`, `.venv`), **or** `git -C <wt> ls-files -o -i --exclude-standard` lists a secret-looking file (`.env*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `id_rsa`, `id_ed25519`, `credentials*`) even inside one of those directories (git collapses an ignored directory to `!! build/`, hiding a `build/.env`). A command that fails is "cannot inspect", never "no local files" | git-ignored files that exist only on this disk: `.env*`, local databases, keys, notes |
| Merged | `git -C <wt> merge-base --is-ancestor HEAD "$BASE"` exit 0, **or** the same against `origin/$BASE` | every commit already in base |
| Own commits | `git -C <wt> reflog show HEAD` has an entry whose message starts `commit`, `merge`, `rebase`, `pull`, `cherry-pick` or `am` (the worktree's own HEAD log: a fresh worktree holds only its creation entries, even when it checked out an old branch with a long history) | work was done in this worktree |
| Created | `find "<wt>/.git" -maxdepth 0 -mtime +<N>` prints the path (`<N>` = `$ZUVO_WORKTREE_IDLE_DAYS`, default 30) | the worktree is older than N days |
| Age | `git -C <wt> log -1 --format=%cr` | how long since last commit |

Classify:

- **RECLAIMABLE** -- clean AND no Local files AND merged AND (Own commits OR Created more than N days ago). Zero data at risk: the work exists in the base branch, nothing is uncommitted, nothing exists only on this disk. A branch with no commits of its own is an ancestor of base by definition, so "merged" alone cannot tell landed work from work not started: a zero-commit worktree is someone's freshly prepared workspace and is RECLAIMABLE only once older than N days.
- **SKIPPED** -- would be RECLAIMABLE but has Local files. Report `ignored local files: <list>`; never remove it, never delete `.env*`.
- **IDLE** -- clean, not merged, last commit older than N days. Report only. Never removed automatically -- unmerged commits are work.
- **ACTIVE** -- everything else (including a zero-commit worktree younger than N days). Not listed as a candidate.

Checking against both the local and the remote-tracking base means a stale local `main` produces false ACTIVE/IDLE, never a false RECLAIMABLE.

### Step 3: Remove RECLAIMABLE only

`git worktree remove` does NOT protect ignored files: a clean worktree holding an ignored `.env` is removed with exit 0 and the file is gone (live test 2026-11-22: two of three executors lost a `.env` this way). Re-run the Local files check immediately before each removal, since the tree may have changed since Step 2:

```bash
# inside the per-worktree loop; a failed inspection skips the worktree, it never counts as "nothing found"
OUT=$(git -C "<path>" status --porcelain --ignored) && FILES=$(git -C "<path>" ls-files -o -i --exclude-standard) \
  || { echo "SKIPPED <path>: could not inspect (git failed)"; continue; }
LOCAL=$( { printf '%s\n' "$OUT" | sed -n 's/^!! //p' \
             | awk '$0 !~ /(^|\/)(node_modules|dist|build|\.turbo|\.next|coverage|__pycache__|\.pytest_cache|target|\.venv)\/$/'
           printf '%s\n' "$FILES" \
             | awk '/(^|\/)\.env[^\/]*$|\.(pem|key|p12|pfx)$|(^|\/)(id_rsa|id_ed25519|credentials[^\/]*)$/ && !/(^|\/)node_modules\//'; } )
if [ -n "$LOCAL" ]; then echo "SKIPPED <path>: ignored local files: $LOCAL"
elif git worktree remove "<path>"; then   # NEVER --force
  git branch -d "<branch>" || echo "KEPT branch <branch>: not fully merged"   # safe delete
else
  echo "SKIPPED <path>: worktree remove refused (locked or changed)"
fi
```

A refusal from either command (a locked worktree, an unmerged branch) is not an error: collect it as SKIPPED with the reason and move on. The branch is deleted only after the worktree removal succeeded.

### Step 4: Layout check -- the part that prevents recurrence

If any remaining worktree path is under `$REPO_ROOT`, migrate it out:

```bash
git worktree move "<repo>/.worktrees/<name>" "$DEFAULT_WTDIR/<name>"
```

`git worktree move` relocates the checkout and rewrites its gitdir pointers, so no work is lost and no branch changes. It fails on a locked worktree, one containing submodules, or one with a dirty index -- report those individually and leave them in place rather than forcing.

Once the nested directory is empty, remove it. Do not edit or commit `.gitignore`: PRUNE never writes tracked files. If a dead entry remains, report it for the user.

### Step 5: Index hygiene

Removing a directory does not remove what it already put in a code index -- stale worktree paths and their duplicate symbols persist until the repo is re-indexed. After any removal or migration, tell the user to re-index (CodeSift: `index_folder(path=<repo root>)`), otherwise clone, boundary and centrality metrics stay corrupted by files that no longer exist.

### PRUNE Output

```
WORKTREE PRUNE COMPLETE
  Records cleared:  <n> (directories already gone)
  Reclaimed:        <n>  <branch list>
  Skipped:          <n>  <path -- reason, e.g. ignored local files: .env>
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
6. **Uncommitted changes block FINISH Options 1-3.** They require a clean working tree and the main checkout must be clean too. Report it and stop; never stash or commit for the user. Option 4 lists what it will lose before the typed `discard`.
7. **Report, do not assume.** When detecting base branches, test runners, or setup commands, report what was detected and what will run before running it.
8. **Never default a worktree inside the repo.** New worktrees go to `../<repo>-worktrees/`. A nested directory is honored only when it already exists or a project instruction declares it, and only alongside the nested-layout warning.
9. **PRUNE removes only provably reclaimable worktrees.** Clean, no git-ignored local files besides install/build output (`git worktree remove` deletes them silently), merged into base (verified against both the local and remote-tracking base), and not freshly created. No `--force` in any prune command, ever. Dirty, unmerged, locked, current-directory or ignored-file worktrees are reported, never touched.
