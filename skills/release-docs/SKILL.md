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

## Phase 0: Determine Range and Suffix

1. If an explicit `<range>` argument was provided: use it. Skip remaining steps in this phase.
2. Else if `memory/last-ship.json` exists: read the `range` field (SHA-based, e.g., `"abc1234..def5678"`) and use it directly for `git diff`. Also read `previousTag` and `newTag` for display in the output block. If the artifact uses a legacy version-based range (e.g., `"v1.1.0..v1.2.0"`), fall back to it but log: "Warning: legacy version-based range — consider re-running zuvo:ship for SHA-based artifact."
3. Else: derive from git tags.
   - Run `git describe --tags --abbrev=0` to get the latest tag.
   - Run `git describe --tags --abbrev=0 <latest-tag>^` to get the previous tag.
   - Construct range as `<previous-tag>..<latest-tag>`.
4. If no range can be derived after the above steps:
   - Interactive environments: ask the user to provide a range explicitly.
   - Non-interactive environments (Codex App, Cursor): print `[AUTO-DECISION]: no range derivable. Skipping documentation sync.` and exit with PASS verdict.

5. **Compute `RANGE_SUFFIX`** for use in evidence and output paths:
   - If `previousTag` and `newTag` are available: `RANGE_SUFFIX = "<previousTag>_<newTag>"` (e.g., `v1.1.0_v1.2.0`)
   - Else if range contains tags: extract them (e.g., `v1.1.0..v1.2.0` → `v1.1.0_v1.2.0`)
   - Else: use short SHAs from the range (e.g., `abc1234_def5678`)

   All downstream references to `<range-suffix>` use this computed value.

---

## Phase 1: Diff Analysis

1. Run `git diff --name-only <range>` to get all files changed in the range.
2. Classify each changed file:
   - **Source files:** `.ts`, `.tsx`, `.js`, `.jsx`, `.py`, `.php`, `.go`, `.rs`, `.java`, `.rb`, `.swift`, `.kt`
   - **Doc files:** `.md`, `.mdx`, `.rst`, `.txt`
   - **Config files:** `.json`, `.yaml`, `.toml`, `.yml`
   - **Other:** images, binaries, lock files, etc.
3. Determine "docs-adjacent" source files using this priority order:
   - **Priority 1: Explicit mapping.** If `docs/docs-map.yaml` exists, use it:
     ```yaml
     # docs-map.yaml — maps source paths to documentation files
     src/auth/: docs/authentication.md
     src/orders/: [docs/orders.md, docs/api/orders-api.md]
     ```
     Source files matching a key are docs-adjacent to the mapped doc files.
   - **Priority 2: Frontmatter.** If doc files have `sources:` in their YAML frontmatter (e.g., `sources: [src/auth/*]`), use those globs to match changed source files.
   - **Priority 3: Name heuristic** (fallback). `src/auth/` is docs-adjacent if `docs/auth.md` or any `*auth*` file in `docs/` exists, or if any `.md` file mentions the module name.
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
3. **Iron rule:** Every documentation claim added or modified must reference a source file (file path, function name, or line reference). If `zuvo:docs` produces a claim without traceable evidence, flag it and request a correction before accepting the update.

   Write the evidence trail to:
   `audit-results/release-docs-sources-<range-suffix>.md`

   Use one line per claim in this format:
   - `<doc-file>` → `<claim summary>` → `<source-file:line>` or `<source-file:function>`

If multiple doc files need updating, invoke `zuvo:docs update` for each in sequence.

---

## Phase 4: Debt Detection

1. Reuse the **same mapping priority order** from Phase 1:
   - `docs/docs-map.yaml`
   - `sources:` YAML frontmatter
   - name heuristic (fallback only)
2. A changed source file is **documented** if it resolves to at least one documentation file through Priority 1 or Priority 2.
3. If only the fallback heuristic matches, mark the result as **low-confidence** and report it separately.
4. A source file is **undocumented** only when no explicit mapping or frontmatter source rule matches it.
5. Documentation debt is informational unless explicitly flagged by the user.

---

## Phase 5: Output

Print the RELEASE-DOCS COMPLETE block:

```
RELEASE-DOCS COMPLETE
  Range:        <range>
  Changelog:    CHANGELOG.md updated (Added: N, Fixed: N, Changed: N)
  Docs updated: <list of doc files updated, or "none">
  Docs skipped: <list of known doc files (from docs-map/frontmatter) with no source changes, or "—" if no mapping exists>
  Debt found:   N file(s) (<list of undocumented files>) / none
  Evidence:     audit-results/release-docs-sources-<range-suffix>.md
  Verdict:      PASS
```

If `--dry-run` was set and execution reached this phase (only on early exits), annotate the block with `[DRY RUN — no files written]`.

Append run log entry per `../../shared/includes/run-logger.md`. Use the environment-aware log path from run-logger.md (do NOT hardcode `~/.zuvo/runs.log`):

```
<ISO-timestamp>\trelease-docs\t<project-basename>\t-\t-\tPASS\t-\t5-phase\tdocs synced for <range>
```
