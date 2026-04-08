---
name: content-fix
description: >
  Apply fixes from content-audit findings. Reads audit JSON, classifies fixes
  by safety tier (SAFE/MODERATE), applies templates per fix type. Handles
  encoding artifacts (NBSP, mojibake), broken markdown, CMS migration debris,
  and typography issues. Modes: default (SAFE only), --auto (SAFE+MODERATE),
  --dry-run, --finding CC1-nbsp-present, --fix-type encoding-strip.
---

# zuvo:content-fix — Apply Content Audit Fixes

Read content-audit JSON findings. Classify by safety tier. Apply mechanical fixes. Verify build. Report.

**Scope:** Post-audit fix application for content file quality findings.
**Out of scope:** SEO fixes (`zuvo:seo-fix`), content writing, spelling corrections, link target changes.

## Mandatory File Loading

Read these files before any work begins:

1. `../../shared/includes/env-compat.md` -- Agent dispatch and environment adaptation
2. `../../shared/includes/content-fix-registry.md` -- Canonical fix_type, safety, contracts
3. `../../shared/includes/fix-output-schema.md` -- JSON report contract
4. `../../shared/includes/content-check-registry.md` -- Check slugs reference
5. `../../shared/includes/backlog-protocol.md` -- Backlog fingerprint dedup
6. `../../shared/includes/verification-protocol.md` -- Build verification rules
7. `../../shared/includes/run-logger.md` -- Run logging contract
8. `../../shared/includes/knowledge-prime.md` -- Project knowledge priming
9. `../../shared/includes/knowledge-curate.md` -- Learning extraction after work

Print the checklist:

```
CORE FILES LOADED:
  1. env-compat.md              -- [READ | MISSING -> STOP]
  2. content-fix-registry.md    -- [READ | MISSING -> STOP]
  3. fix-output-schema.md       -- [READ | MISSING -> STOP]
  4. content-check-registry.md  -- [READ | MISSING -> STOP]
  5. backlog-protocol.md        -- [READ | MISSING -> STOP]
  6. verification-protocol.md   -- [READ | MISSING -> STOP]
  7. run-logger.md              -- [READ | MISSING -> STOP]
  8. ../../shared/includes/knowledge-prime.md  -- READ/MISSING
  9. ../../shared/includes/knowledge-curate.md -- READ/MISSING
```

If any file is missing, STOP.

## Safety Gates (NON-NEGOTIABLE)

### GATE 1 — Write Scope

**Allowed write targets:**
- Content files from the audit manifest (files listed in audit JSON findings)
- `audit-results/` for the fix report (`.md` and `.json`)
- `memory/backlog.md` for backlog updates

**FORBIDDEN:**
- Installing packages or dependencies
- Writing to files not referenced by audit findings
- Modifying config files, build scripts, or non-content files
- Deleting files

### GATE 2 — Dirty File Check

Before modifying any file:
1. `git status --porcelain -- <file>` — check for BOTH staged and unstaged changes
2. If the file has ANY uncommitted changes (staged or unstaged): mark finding
   as `NEEDS_REVIEW`
3. Do not modify dirty files

### GATE 3 — Stale Audit Protection

If audit JSON `timestamp` is >24h old:
- Default mode (SAFE only): proceed with warning
- `--auto` mode: **require user confirmation** before mutating
- `--dry-run` mode: proceed with warning

### GATE 4 — PROVISIONAL Audit Handling

If audit JSON `result` is `"PROVISIONAL"` (has `INSUFFICIENT DATA` blocking
gates):
- Default mode (SAFE only): proceed normally — SAFE fixes are safe regardless
  of incomplete gates
- `--auto` mode: restrict to SAFE fixes only (do not apply MODERATE). Warn:
  "Audit is PROVISIONAL — restricting to SAFE fixes. Re-run content-audit
  with --live-url for full coverage."

---

## Arguments

| Argument | Behavior |
|----------|----------|
| (default) | Apply SAFE fixes only (`encoding-strip`, `markdown-fix`, `typography-fix`) |
| `--auto` | Apply SAFE + MODERATE fixes (`encoding-mojibake`, `artifact-remove`) |
| `--dry-run` | Show what would be fixed, change nothing |
| `--finding CC1-nbsp-present,CC2-broken-italic` | Fix specific findings by stable ID |
| `--fix-type encoding-strip,markdown-fix` | Fix specific fix_type categories |
| `[json-path]` | Use specific JSON file instead of latest |

---

### Knowledge Prime

Run the knowledge prime protocol from `knowledge-prime.md`:
```
WORK_TYPE = "implementation"
WORK_KEYWORDS = <keywords from user request>
WORK_FILES = <files being touched>
```

---

## Phase 0: Load Findings

### 0.1 Locate audit JSON

1. If `[json-path]` provided: use that file
2. Otherwise: glob `audit-results/content-audit-*.json`, select most recent by timestamp
3. If no JSON found: "No audit JSON found. Run `zuvo:content-audit` first." STOP.

### 0.2 Validate schema

Check `version` field. Supported: `"1.0"`, `"1.1"`.

Required fields:
```
version, skill, timestamp, result, score.overall, findings[]
Required per finding: id, dimension, check, status, fix_type, fix_params
```

### 0.3 Check freshness

Read `timestamp`. Apply GATE 3 if >24h old.

### 0.4 Print summary

```
 AUDIT: content-audit [date] ([age]) | Grade: [A-D] ([score]%) | [N] findings
  SAFE:     [N] findings (auto-fixable)
  MODERATE: [N] findings (fixable with --auto)
  MANUAL:   [N] findings (advisory only)
```

---

## Phase 1: Detect Framework & Classify

### 1.1 Stack detection

Same inline detection as content-audit Phase 0.1.

### 1.2 Classify findings

For each finding with a non-null `fix_type`:

| fix_type | Safety | Default mode | --auto mode |
|----------|--------|-------------|-------------|
| `encoding-strip` | SAFE | Apply | Apply |
| `markdown-fix` | SAFE | Apply | Apply |
| `typography-fix` | SAFE | Apply | Apply |
| `encoding-mojibake` | MODERATE | Skip | Apply |
| `artifact-remove` | MODERATE | Skip | Apply |

Findings with `fix_type: null` are MANUAL — never auto-applied.

---

## Phase 2: Apply Fixes

### 2.0 Pre-flight per file

Before modifying any file:
1. Save a snapshot of the original content (in memory, for rollback)
2. Check GATE 2 (dirty file check)
3. If multiple findings target the same file: batch all fixes into one edit

### 2.1 SAFE fixes (auto-applied)

For each SAFE finding:

**`encoding-strip`:**
- Replace NBSP (U+00A0) with regular space (U+0020)
- Remove zero-width characters (U+200B, U+200C, U+200D, U+FEFF)
- Remove BOM marker from file start
- Remove soft hyphens (U+00AD)
- Remove replacement characters (U+FFFD) — flag for manual review
- Scope: body content AND frontmatter string fields
- Skip content inside fenced code blocks

**`markdown-fix`:**
- Close unclosed `*` or `_` at paragraph end (append matching marker)
- Fix split italic: `* *text*` → `*text*`
- Remove orphan `\` lines (stack-aware: only for Hugo/Goldmark)

**`typography-fix`:**
- Collapse 2+ spaces to 1 (outside code blocks, tables, indentation)
- Fix `..` → `.` (preserve `...` ellipsis)
- Fix `,,` → `,`

### 2.2 MODERATE fixes (with --auto only)

**`encoding-mojibake`:**
- Replace garbled sequences using the mojibake signature table from
  `content-fix-registry.md`
- Skip matches inside fenced code blocks (may be intentional examples)
- Verify each replacement produces valid UTF-8

**`artifact-remove`:**
- Remove WordPress shortcodes: extract inner content where possible
- Remove PHP tags: `<?php ... ?>` blocks entirely
- Remove `<font>` tags: keep inner text
- Remove excessive inline styles (>50 chars)
- **Joomla paths (`/images/stories/`, `index.php?option=com_`):** do NOT
  auto-replace — target path is unknown. Mark as `NEEDS_REVIEW` with evidence
  and suggested manual action. These are always flagged for human review even
  in `--auto` mode.

### 2.3 MANUAL findings

Never auto-applied. Appear in report as advisory with suggested changes:
- Spelling corrections
- Content duplication resolution
- Frontmatter rewrites
- Link target changes

---

## Phase 3: Build Verification

Detect project build command:
1. `package.json` scripts: `build`, `astro build`, `next build`
2. Hugo: `hugo` binary
3. If no build command: skip, note in report

Build verification follows `verification-protocol.md`:
- `build_result: PASS` requires exit code 0
- `build_result: FAIL` for any non-zero exit code

Build failure → rollback per-file snapshots from Phase 2.0.

---

## Phase 4: Adversarial Review (MANDATORY — do NOT skip)

```bash
git add -u && git diff --staged | adversarial-review --json --mode code
```

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Wait for complete output. Fix CRITICAL immediately. WARNING (localized) → fix.

---

## Phase 5: Report

### 5.1 Report template

```
CONTENT FIX REPORT -- [project name]
----
Findings: [N] total | [N] fixed | [N] needs review | [N] manual
Grade:    [before] -> [estimated after] (confirmed fixes only)
Build:    [PASS | FAIL (rolled back N) | NOT VERIFIED]
----

FIXED (SAFE — auto-applied):
  F1: Stripped 42 NBSP characters              content/post-1.md    [VERIFIED]
  F2: Closed unclosed italic                   content/post-3.md:18 [VERIFIED]

FIXED (MODERATE — applied with --auto):
  F3: Fixed mojibake: Ä… → ą (12 occurrences)  content/post-5.md    [VERIFIED]

NEEDS REVIEW:
  F4: encoding-strip on dirty file             content/draft.md
      Reason: File has uncommitted changes

MANUAL (advisory):
  F5: Spelling correction needed               content/about.md:7
      Suggestion: "forumują" → "formują"

Run: <ISO-8601-Z>	content-fix	<project>	-	-	<VERDICT>	<N-fixes>	fix	<NOTES>	<BRANCH>	<SHA7>

NEXT STEPS:
  1. Review NEEDS_REVIEW items
  2. Apply MANUAL fixes manually
  3. Re-audit: zuvo:content-audit
```

After printing this block, append the `Run:` line value (without the `Run:`
prefix) to the log file path resolved per `run-logger.md`.

### 5.2 Save JSON report

Write to `audit-results/content-fix-YYYY-MM-DD.json` conforming to
`fix-output-schema.md` v1.1. Auto-increment `-2.json` for same-day runs.

### Knowledge Curation

After work is complete, run the knowledge curation protocol from `knowledge-curate.md`:
```
WORK_TYPE = "implementation"
CALLER = "zuvo:content-fix"
REFERENCE = <git SHA or relevant identifier>
```

### 5.3 Update backlog

Per `shared/includes/backlog-protocol.md`:

| Finding status | Backlog action |
|----------------|---------------|
| FIXED | Remove row by fingerprint |
| NEEDS_REVIEW | If exists: increment `Seen`. If new: add as OPEN |
| MANUAL | Add as OPEN with category `content-manual` |

**Fingerprint format:** `{file}|{dimension}|{check}`
