## ship never merges a PR; worktree prune can no longer delete a git-ignored `.env`

A live test of `zuvo:ship` and `zuvo:worktree` on Claude Sonnet, Codex Sol and Gemini found these defects.

**worktree**
- PRUNE now lists git-ignored files (`git status --porcelain --ignored`) before it removes anything. Anything besides install/build output (`node_modules`, `dist`, `.turbo` and the like) makes the worktree SKIPPED, because `git worktree remove` deletes ignored files without a prompt. The text that claimed git refuses is gone.
- "Merged into base" no longer reclaims a worktree created minutes ago: a branch with no commits of its own is an ancestor of base by definition. RECLAIMABLE now needs the branch to have moved (reflog) or the worktree to be older than `ZUVO_WORKTREE_IDLE_DAYS`.
- FINISH checks that the main checkout is clean before `checkout`/`pull`, and stops with `FINISH BLOCKED` otherwise. It reads the base from `branch.<b>.zuvo-base` (set at CREATE) instead of `git log --merges`.
- A branch `feat/x` gets the directory `feat-x`, so donor and PRUNE globs see it. Every "ask" has a non-interactive default (`[WORKTREE] BLOCKED`). Layout migration no longer edits `.gitignore`.

**ship**
- Ship never merges a PR. PR flow ends at an open PR (`PR: #N open`); the merge belongs to the repo's merge path or `zuvo:deploy`. Zero configured checks is reported, never a reason to merge. A moved base is merged into the branch only when no PR exists and no merge queue is named, and the merge is announced.
- A feature branch never bumps the version, even when the user asks for it: a `changelog.d` note and an explanation instead.
- `--dry-run` is read-only from the first command (a `git ls-remote` replaces the fetch; no tag, no push, no file).
- A frontend file in the diff dispatches `zuvo:design-review` whatever the size band; the band table says so.
- `--no-bump` has a defined result: an `## [Unreleased]` entry committed as `docs(changelog)`, no tag.
- The push-gate preflight resolves the hooks directory with `git rev-parse --git-path hooks`; the test step no longer hardcodes `npm test > log`; the secret-scan fallback is named; a repo without tags gets the `v` prefix.
- `env-compat.md`: the `rt` rule and the 30-second threshold now agree (`rt` when the run is expected to exceed 30 s).
