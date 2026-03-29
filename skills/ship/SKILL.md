---
name: ship
description: >
  Pre-merge release pipeline: run tests, auto-scaled code review, version bump,
  changelog generation, git tag, push or PR. Auto-detects branch context (direct
  push on main, PR on feature branch). Scales review depth by diff size.
  Flags: --fast, --full, --no-bump, --no-tag, --dry-run, patch/minor/major.
---

# zuvo:ship

Prepare and push a release. Tests, version bump, changelog, tag, and push — auto-scaled by diff size.

## Argument Parsing

Parse `$ARGUMENTS` for these flags:

| Argument | Effect |
|----------|--------|
| _(no flags)_ | Auto-scaled pipeline based on diff size |
| `--fast` | Force fast path: tests + bump + push only (skip all review) |
| `--full` | Force full pipeline: tests + review + design-review + coverage + bump + push |
| `--no-bump` | Skip version bumping (hotfixes, chores) |
| `--no-tag` | Skip git tag creation |
| `--dry-run` | Show what would happen without executing |
| `patch` / `minor` / `major` | Explicit bump type (overrides auto-detection) |

Flags can be combined: `zuvo:ship --fast --no-tag`, `zuvo:ship minor --no-tag`

## Mandatory File Loading

Read each file below using the Read tool. Print the checklist with status before proceeding. Do not proceed from memory.

```
CORE FILES LOADED:
  1. ../../shared/includes/env-compat.md     — READ/MISSING
  2. ../../shared/includes/codesift-setup.md — READ/MISSING
  3. ../../shared/includes/run-logger.md     — READ/MISSING
```

If any file is missing: proceed in degraded mode. Note which files are unavailable in the Phase 5 output.

---

## SAFETY RULES

**Read these before executing any phase. Violations are non-recoverable.**

1. **NEVER** use `git add -A` or `git add .`. Stage ONLY files that were actually generated or modified: `memory/last-ship.json` (always), the version file (only if bump was performed), and `CHANGELOG.md` (only if created/updated).
2. **NEVER** push to a remote repository without explicit user confirmation. In non-interactive environments (Codex, Cursor): skip the push step entirely.
3. **NEVER** push tags without interactive confirmation. In non-interactive environments (Codex, Cursor): skip `git push --tags`, write `tagPushed: false` in `memory/last-ship.json`.
4. **Default to `patch`** bump with `[AUTO-DECISION]` annotation in non-interactive environments when the user cannot be asked for bump type.

---

## Phase 0: Pre-flight

1. **Detect current branch:**
   ```bash
   git branch --show-current
   ```
   - If on `main`, `master`, `trunk`, or `develop`: **direct flow** (tag + push to current branch).
   - If on any other branch: **PR flow** (push branch + create PR targeting the default branch).

2. **Check GitHub CLI availability:**
   ```bash
   gh auth status
   ```
   - If the command fails or `gh` is not installed: set `GH_AVAILABLE=false`. Continue — PR creation will be skipped at Phase 4 (see E3 handling).

3. **Check for changes since last tag:**
   ```bash
   git log $(git describe --tags --abbrev=0 2>/dev/null || echo HEAD~10)..HEAD --oneline
   ```
   - If no commits in range: print "Nothing to ship. No commits since the last tag." and exit cleanly.

4. **Dry-run gate:** If `--dry-run` was passed, walk through each subsequent phase printing what would happen at each step (branch, flow, diff LOC, review depth, bump type, files staged, tag name, push target). Then exit without executing anything.

---

## Phase 1: Tests

1. **Detect test command.** Check in order:
   - `package.json` → `scripts.test` (run with `npm test` / `yarn test` / `pnpm test`)
   - `Makefile` → `test` target (run with `make test`)
   - `pyproject.toml` → `[tool.pytest]` or `[tool.pytest.ini_options]` (run with `pytest`)
   - `Cargo.toml` → `cargo test`
   - `composer.json` → `scripts.test` (run with `composer test`)
   - If no test command found: print "No test runner detected. Skipping tests." and continue.

2. **Run the test suite.** Capture exit code, pass count, and fail count.

3. **If tests fail:** Stop. Print the failure summary. Ask the user to fix the failures or explicitly confirm override to continue shipping with failing tests. In non-interactive environments: stop and print `SHIP ABORTED: test failures` — never auto-override test failures.

---

## Phase 2: Review Scaling

1. **Compute diff LOC.** Count insertions + deletions since the last tag:
   ```bash
   BASE_REF=$(git describe --tags --abbrev=0 2>/dev/null || echo HEAD~10)
   git diff --stat ${BASE_REF}..HEAD | tail -1
   ```
   Extract the total insertions + deletions number as `DIFF_LOC`. Uses the tag ref directly — `HEAD~N` is fragile with merge commits and non-linear history.

2. **Apply review threshold** (per DD4), unless overridden by `--fast` or `--full`:

   | Diff LOC | Review actions |
   |----------|----------------|
   | < 20 | **Fast path** — skip review entirely |
   | 20 - 100 | Dispatch `review-light` agent (read `skills/ship/agents/review-light.md`) |
   | 100+ | Dispatch `review-light` + invoke `zuvo:review` as inline agent + invoke `zuvo:design-review` if frontend files changed (`.tsx`, `.jsx`, `.css`, `.scss`, `.html`) |
   | 300+ | All of the above + dispatch `coverage-check` agent (read `skills/ship/agents/coverage-check.md`) |

   **Flag overrides:**
   - `--fast`: always use fast path regardless of diff size.
   - `--full`: always use 300+ path (all reviews + coverage check) regardless of diff size.

3. **Agent dispatch — review-light:**
   - Read `skills/ship/agents/review-light.md` for the agent's instructions.
   - Provide the git diff as input.
   - If the agent returns verdict `BLOCK`: pause. Show the blocker list. Ask the user to fix the issues or explicitly override. In non-interactive environments: stop and print `SHIP PAUSED: review blockers found`.

4. **Agent dispatch — coverage-check** (300+ LOC or `--full` only):
   - Read `skills/ship/agents/coverage-check.md` for the agent's instructions.
   - Provide the list of changed production files (exclude test files).
   - The coverage-check verdict is **informational only** — it never blocks ship.

5. **Record review depth** for the artifact:
   - `"none"` — fast path, no review performed
   - `"light"` — review-light agent only
   - `"full"` — review-light + zuvo:review (+ design-review if applicable)
   - `"full+coverage"` — full + coverage-check agent

---

## Phase 3: Version Bump

1. **Detect version file.** Check project root in this order:

   | File | Ecosystem | Version field |
   |------|-----------|---------------|
   | `package.json` | Node.js | `.version` |
   | `pyproject.toml` | Python | `[project].version` or `[tool.poetry].version` |
   | `Cargo.toml` | Rust | `[package].version` |
   | `go.mod` | Go | git tags only (no file bump) |
   | `composer.json` | PHP | `.version` |
   | `VERSION` | Generic | entire file content |
   | None found | — | Offer to create a `VERSION` file, or skip versioning with user consent (E5) |

2. **Skip gate:** If `--no-bump` was passed, skip this entire phase. Proceed to Phase 4 with the current version unchanged.

3. **Detect conventional commits.** Scan all commits in the release range for prefixes:
   - `BREAKING CHANGE:` or `!:` suffix → major
   - `feat:` → minor
   - `fix:` → patch

   Decision logic:
   - If the user provided an explicit `patch`, `minor`, or `major` argument: use that. Skip detection.
   - If >= 50% of commits follow conventional commit format: auto-compute bump type from the highest-impact prefix (BREAKING > feat > fix).
   - If < 50% follow convention (E4): list the raw commit messages. Ask the user for bump type (`patch`, `minor`, or `major`). In non-interactive environments (Codex, Cursor): default to `patch` with `[AUTO-DECISION]` annotation.

4. **Apply the bump** to the detected version file. Read the current version, increment the appropriate segment, write back.

5. **Generate or update CHANGELOG.md:**
   - If `CHANGELOG.md` exists: prepend a new section at the top (below the header).
   - If `CHANGELOG.md` does not exist (E6): create it from scratch with the Keep-a-Changelog header:
     ```markdown
     # Changelog

     All notable changes to this project will be documented in this file.

     The format is based on [Keep a Changelog](https://keepachangelog.com/).
     ```
   - New section format:
     ```markdown
     ## [<version>] — YYYY-MM-DD

     ### Added
     - ...

     ### Changed
     - ...

     ### Fixed
     - ...
     ```
   - Group commit messages under the appropriate heading (Added for `feat:`, Fixed for `fix:`, Changed for everything else). If commits are not conventional, list all under Changed.

---

## Phase 4: Artifact, Stage, Commit, Tag, Push

### Step 1: Write `memory/last-ship.json`

Compute values before writing:
- `BASE_REF`: the tag or ref used as the diff base (from Phase 2).
- `baseSha`: `git rev-parse ${BASE_REF}`

Write the artifact (headSha will be updated after commit in step 3):

```json
{
  "version": "<new-version>",
  "previousVersion": "<old-version>",
  "newTag": "v<new-version>",
  "previousTag": "<BASE_REF>",
  "baseSha": "<sha-of-BASE_REF>",
  "headSha": "<placeholder-until-commit>",
  "range": "<baseSha>..<headSha>",
  "branch": "<current-branch>",
  "targetBranch": "<target-branch-or-null>",
  "flow": "direct" or "pr",
  "pr": <number-or-null>,
  "date": "<ISO-8601>",
  "tests": "pass",
  "reviewDepth": "<none|light|full|full+coverage>",
  "diffLOC": <number>,
  "tagPushed": false,
  "pushed": false
}
```

Field notes:
- `previousTag`: the actual git tag or ref used as diff base, not a version-derived string.
- `baseSha` / `headSha`: exact SHAs so downstream skills (release-docs, retro) can use `git diff <baseSha>..<headSha>` reliably.
- `range`: SHA-based, not version-based. Downstream skills must not rely on `v<old>..v<new>`.
- `targetBranch`: the PR base branch in PR flow, `null` in direct flow.
- `pr`: the PR number returned by `gh pr create`, `null` if direct flow or `gh` unavailable.
- `tagPushed`: `false` when tag push was skipped (non-interactive env or `--no-tag`).
- `pushed`: `false` when ALL remote pushes were skipped (non-interactive env).

### Step 2: Stage files

Stage **only** files that were actually generated or modified:

```bash
git add memory/last-ship.json

# Only if bump was performed (--no-bump was NOT set):
git add <version-file>

# Only if CHANGELOG.md was created or updated in Phase 3:
git add CHANGELOG.md
```

**NEVER** use `git add -A` or `git add .`. If `--no-bump` was set, do not stage a version file.

### Step 3: Commit

```bash
git commit -m "release: v<version>"
```

After commit, update `headSha` and `range` in `memory/last-ship.json` with the actual commit SHA:
```bash
HEAD_SHA=$(git rev-parse HEAD)
```
Then restage and amend: `git add memory/last-ship.json && git commit --amend --no-edit`

### Step 4: Tag (unless `--no-tag`)

```bash
git tag v<version>
```

### Step 5: Push

**Non-interactive environments (Codex App, Cursor):** Skip ALL remote pushes. Set `pushed: false` and `tagPushed: false` in the artifact. Print the exact manual commands:
```
[NON-INTERACTIVE] Remote push skipped. Run manually:
  git push origin <branch>
  git push origin v<version>
```

**Interactive environments (Claude Code, Codex CLI):**

- **Direct flow (on main/master/trunk/develop):**
  Requires explicit user confirmation before each push command:
  ```bash
  git push origin <branch>
  git push origin v<version>   # only if tag was created
  ```
  Update artifact: `pushed: true`, `tagPushed: true` (or `false` if `--no-tag`).

- **PR flow (on feature branch):**
  Requires explicit user confirmation:
  ```bash
  git push -u origin <branch>
  ```
  Then, if `GH_AVAILABLE=true`:
  ```bash
  gh pr create --title "Release v<version>" --body "<changelog excerpt>"
  ```
  If `GH_AVAILABLE=false` (E3): skip PR creation. Print manual instructions:
  ```
  gh unavailable — create PR manually:
    gh pr create --title "Release v<version>"
  ```
  Update artifact: `pushed: true`, `pr: <number-or-null>`.

---

## Phase 5: Output

### 1. Print SHIP COMPLETE block

```
SHIP COMPLETE
  Branch:      <branch>
  Flow:        direct (solo) / pr (#<number>)
  Version:     <old-version> → <new-version>
  Tag:         v<new-version>
  Diff:        <N> LOC (<review-depth> path)
  Tests:       PASS (<N> passed, <N> failed)
  Review:      <depth> (<details>)
  Changelog:   CHANGELOG.md updated
  Push:        origin/<branch> ✓
  PR:          #<N> / — (direct flow) / skipped (gh unavailable)
  Artifact:    memory/last-ship.json written

  Next: zuvo:deploy (when ready)
```

### 2. Run logger

Append a run log entry per `../../shared/includes/run-logger.md`:

```
<ISO-8601>\tship\t<project>\t-\t-\t<PASS|WARN|ABORTED>\t-\t5-phase\tv<old>→v<new> <flow> <reviewDepth>
```
