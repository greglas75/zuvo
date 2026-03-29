---
name: release-docs
description: >
  Diff-driven documentation sync after a release. Determines what source files
  changed, delegates changelog to zuvo:docs, updates only docs whose source changed.
  Flags: --dry-run, explicit range argument.
---

# zuvo:release-docs

Sync documentation with a release. Only updates docs whose source files actually changed.

## Mandatory File Loading

Read these files before proceeding:

```
CORE FILES LOADED:
  1. ../../shared/includes/env-compat.md    — READ
  2. ../../shared/includes/run-logger.md    — READ
```

## Argument Parsing

| Input | Effect |
|-------|--------|
| _(no flags)_ | Auto-detect range from `memory/last-ship.json` or git tags |
| `<range>` | Explicit git range (e.g., `v1.1.0..v1.2.0`) |
| `--dry-run` | Show proposed changes without writing |

---

## Phase 0: Determine Range

1. If an explicit `<range>` argument was provided: use it. Skip remaining steps in this phase.
2. Else if `memory/last-ship.json` exists: read the `range` field (e.g., `"v1.1.0..v1.2.0"`). Use it.
3. Else: derive from git tags.
   - Run `git describe --tags --abbrev=0` to get the latest tag.
   - Run `git describe --tags --abbrev=0 <latest-tag>^` to get the previous tag.
   - Construct range as `<previous-tag>..<latest-tag>`.
4. If no range can be derived after the above steps:
   - Interactive environments: ask the user to provide a range explicitly.
   - Non-interactive environments (Codex App, Cursor): print `[AUTO-DECISION]: no range derivable. Skipping documentation sync.` and exit with PASS verdict.

---

## Phase 1: Diff Analysis

1. Run `git diff --name-only <range>` to get all files changed in the range.
2. Classify each changed file:
   - **Source files:** `.ts`, `.tsx`, `.js`, `.jsx`, `.py`, `.php`, `.go`, `.rs`, `.java`, `.rb`, `.swift`, `.kt`
   - **Doc files:** `.md`, `.mdx`, `.rst`, `.txt`
   - **Config files:** `.json`, `.yaml`, `.toml`, `.yml`
   - **Other:** images, binaries, lock files, etc.
3. Determine "docs-adjacent" source files: source files in directories that have corresponding documentation. Detection heuristic:
   - `src/auth/` has a doc-adjacent match if `docs/auth.md` or any `*auth*` file in `docs/` exists.
   - A changed source file at `src/<module>/` is docs-adjacent if any `.md` file in the repo mentions the module name (search for the basename).
   - If in doubt, include the file — false positives cause minor extra work; false negatives miss documentation updates.
4. If no docs-adjacent source files changed: print "No documentation updates required for this release." Exit with PASS verdict.
5. If `--dry-run` is set: print the list of source files that would trigger doc updates and the doc files that would be updated, then exit without writing anything.

---

## Phase 2: Changelog

Invoke the docs skill to generate the changelog for the release range:

```
Skill(skill="zuvo:docs", args="changelog <range>")
```

This delegates all changelog logic to `zuvo:docs`, which handles:
- git-cliff detection and usage
- Conventional commit classification (Added / Changed / Fixed / Removed)
- Keep-a-Changelog format
- Fallback to raw git log when git-cliff is unavailable

Record the outcome (changelog updated, entries count by type) for the output block.

---

## Phase 3: Doc Updates

For each documentation file whose corresponding source files changed:

1. Invoke:
   ```
   Skill(skill="zuvo:docs", args="update <doc-file>")
   ```
2. `zuvo:docs update` handles staleness detection and targeted section updates.
3. **Iron rule:** Every documentation claim added or modified must reference a source file (file path, function name, or line reference). If `zuvo:docs` produces a claim without a traceable source reference, flag it and request a correction before accepting the update.

If multiple doc files need updating, invoke `zuvo:docs update` for each in sequence.

---

## Phase 4: Debt Detection

1. For each source file that changed in the diff, check whether any documentation file in the project references that source file's module, directory, or exported symbols.
2. A source file is **undocumented** if no `.md` or `.mdx` file in the project mentions its module or directory name.
3. For each undocumented changed file: log it as documentation debt.
4. Documentation debt is informational — it does not change the PASS/FAIL verdict unless explicitly flagged.

---

## Phase 5: Output

Print the RELEASE-DOCS COMPLETE block:

```
RELEASE-DOCS COMPLETE
  Range:        <range>
  Changelog:    CHANGELOG.md updated (Added: N, Fixed: N, Changed: N)
  Docs updated: <list of doc files updated, or "none">
  Docs skipped: <list of doc files with no source changes>
  Debt found:   N file(s) (<list of undocumented files>) / none
  Verdict:      PASS
```

If `--dry-run` was set and execution reached this phase (only on early exits), annotate the block with `[DRY RUN — no files written]`.

Append run log entry per `../../shared/includes/run-logger.md`:

```bash
mkdir -p ~/.zuvo
echo "<ISO-timestamp>\trelease-docs\t<project-basename>\t-\t-\tPASS\t-\t5-phase\tdocs synced for <range>" >> ~/.zuvo/runs.log
```
