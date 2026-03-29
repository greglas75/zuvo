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

1. **NEVER** use `git add -A` or `git add .`. Stage ONLY these files by explicit name: the version file(s), `CHANGELOG.md`, and `memory/last-ship.json`.
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
   COMMIT_COUNT=$(git log $(git describe --tags --abbrev=0 2>/dev/null || echo HEAD~10)..HEAD --oneline | wc -l | tr -d ' ')
   git diff --stat HEAD~${COMMIT_COUNT} | tail -1
   ```
   Extract the total insertions + deletions number as `DIFF_LOC`.

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

## Phase 4: Stage, Tag, Push

1. **Stage files by explicit name:**
   ```bash
   git add <version-file> CHANGELOG.md memory/last-ship.json
   ```
   **NEVER** use `git add -A` or `git add .`. Only stage the version file(s), `CHANGELOG.md`, and `memory/last-ship.json`.

2. **Commit:**
   ```bash
   git commit -m "release: v<version>"
   ```

3. **Tag** (unless `--no-tag` was passed):
   ```bash
   git tag v<version>
   ```

4. **Push** (branch-aware):

   - **Direct flow (on main/master/trunk/develop):**
     ```bash
     git push origin <branch>
     git push --tags
     ```
     Requires explicit user confirmation before each push command. In non-interactive environments: push the commit but skip `git push --tags`. Write `tagPushed: false` in the artifact.

   - **PR flow (on feature branch):**
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

   - **Non-interactive environments (E15):** Push the commit. Skip `git push --tags`. Write `tagPushed: false` in the artifact.

---

## Phase 5: Artifact + Output

### 1. Write `memory/last-ship.json`

```json
{
  "version": "<new-version>",
  "previousVersion": "<old-version>",
  "tag": "v<new-version>",
  "range": "v<old-version>..v<new-version>",
  "branch": "<current-branch>",
  "targetBranch": "<target-branch-or-null>",
  "flow": "direct" or "pr",
  "pr": <number-or-null>,
  "sha": "<commit-sha>",
  "date": "<ISO-8601>",
  "tests": "pass",
  "reviewDepth": "<none|light|full|full+coverage>",
  "diffLOC": <number>,
  "tagPushed": true or false
}
```

Field notes:
- `targetBranch`: set to the PR base branch in PR flow, `null` in direct flow.
- `pr`: the PR number returned by `gh pr create`, `null` if direct flow or `gh` unavailable.
- `tagPushed`: `false` when tag push was skipped (non-interactive env or `--no-tag`), `true` otherwise.

### 2. Print SHIP COMPLETE block

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

### 3. Run logger

Append a run log entry per `../../shared/includes/run-logger.md`:

```
<ISO-8601>\tship\t<project>\t-\t-\t<PASS|WARN|ABORTED>\t-\t5-phase\tv<old>→v<new> <flow> <reviewDepth>
```
