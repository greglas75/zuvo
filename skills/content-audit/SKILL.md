---
name: content-audit
description: >
  Content file quality audit across 8 dimensions (CC1-CC8): encoding artifacts
  (NBSP, mojibake, zero-width), markdown syntax (broken italic, orphan backslash),
  CMS migration artifacts (Joomla/WordPress/PHP), frontmatter quality, image
  integrity, link integrity with anchor validation, content completeness, and
  spelling/typography. Language-agnostic with multi-encoding mojibake detection.
  Companion fix skill: content-fix. Flags: [path], --live-url <url>, --quick,
  --content-path <dir>, --lang <code>, --check-external, --profile <type>, --persist-backlog.
category: Content
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    - get_file_tree            # locate content/*.md
    - search_text              # encoding artifacts, mojibake patterns
    - search_patterns          # broken markdown, orphan backslash, etc.
  by_stack: {}                 # markdown-focused — no framework tools needed
---

# zuvo:content-audit — Content File Quality Audit

Scan content files for encoding artifacts, broken formatting, CMS migration debris, broken links/images, and editorial quality issues. Produces a graded report (A/B/C/D) with auto-fixable findings tagged for `zuvo:content-fix`.

**Scope:** Editorial hygiene, encoding quality, CMS migration cleanup, link/image integrity, frontmatter validation.
**Out of scope:** SEO signals (`zuvo:seo-audit`), code quality (`zuvo:code-audit`), content writing, CMS API content, PDF/Word documents.

## Mandatory File Loading

Read these files before any work begins:

1. `../../shared/includes/codesift-setup.md` -- CodeSift discovery and tool selection
2. `../../shared/includes/env-compat.md` -- Agent dispatch and environment adaptation
3. `../../shared/includes/backlog-protocol.md` -- Filing findings through `backlog-add`
4. `../../shared/includes/content-check-registry.md` -- Canonical check slugs (49 checks, CC1-CC8)
5. `../../shared/includes/audit-output-schema.md` -- JSON output contract (v1.1)
6. `../../shared/includes/content-fix-registry.md` -- fix_type and safety for tagging fixable findings
7. `../../shared/includes/live-probe-protocol.md` -- Live URL safety rules
8. `../../shared/includes/run-logger.md` -- Run logging contract
9. `../../shared/includes/retrospective.md` -- Retrospective protocol
10. `../../shared/includes/verification-protocol.md` -- Fresh-evidence rules
11. `../../shared/includes/audit-postamble.md` -- Verdict rule and closing order

Print the checklist:

```
CORE FILES LOADED:
  1. codesift-setup.md          -- [READ | MISSING -> STOP]
  2. env-compat.md              -- [READ | MISSING -> STOP]
  3. backlog-protocol.md        -- [READ | MISSING -> STOP]
  4. content-check-registry.md  -- [READ | MISSING -> STOP]
  5. audit-output-schema.md     -- [READ | MISSING -> STOP]
  6. content-fix-registry.md    -- [READ | MISSING -> STOP]
  7. live-probe-protocol.md     -- [READ | MISSING -> STOP]
  8. run-logger.md              -- [READ | MISSING -> STOP]
  9. retrospective.md           -- [READ | MISSING -> STOP]
 10. verification-protocol.md   -- [READ | MISSING -> STOP]
 11. audit-postamble.md         -- [READ | MISSING -> STOP]
```

If any file is missing, STOP.

## Safety Gates (NON-NEGOTIABLE)

### GATE 1 -- Live Audit Consent

Read `../../shared/includes/live-probe-protocol.md` for the full consent gate,
rate limiting rules, error escalation thresholds, and HTTP method restrictions.
All live probing in this skill follows that shared protocol.

### GATE 2 -- Read-Only Audit

This audit is read-only against source files.

**Allowed write targets:**
- `zuvo/audits/` for the report file (`.md` and `.json`)
- `memory/backlog.md` and `memory/findings/` (written by `backlog-add`) only when `--persist-backlog` is explicitly enabled

**FORBIDDEN:**
- Modifying any content files
- Creating, deleting, or renaming files outside `zuvo/audits/`

---

## Arguments

| Argument | Behavior |
|----------|----------|
| `[path]` | Scope to specific file or directory |
| `--content-path <dir>` | Override auto-detected content directory |
| `--live-url <url>` | Enable live link/image checks (CC5 img-404-live, CC6 link-external-dead, CC6 link-external-redirect) |
| `--quick` | Source-only grep checks, no agent dispatch. Runs CC1-CC3 grep patterns + CC5/CC6 path resolution. Skips CC4/CC7/CC8 entirely. Checks requiring agents return `INSUFFICIENT DATA`; live-only checks return `N/A`. |
| `--lang <code>` | Force language for spell/typography checks (ISO 639-1: `pl`, `en`, `de`, `tr`, etc.) |
| `--check-external` | Enable external link checking (requires network access) |
| `--persist-backlog` | Record findings through `backlog-add` (Phase 5) |
| `--profile <type>` | Content profile: `blog`, `docs`, `ecommerce`, `marketing`. Adjusts thresholds for CC7 content completeness checks. |

---

## MANDATORY TOOL CALLS — Content Audit Validity Gate

**INVALID if any tool below is skipped.** "DEFERRED", "N/A" NOT valid reasons.

| Tool | Trigger | Skip allowed? |
|------|---------|---------------|
| `get_file_tree` | Always | **NO** — locate content/*.md |
| `search_text` | Always | **NO** — encoding artifacts, mojibake patterns |
| `search_patterns` | Always | **NO** — broken markdown, orphan backslash |

Forbidden: skipped/N/A — REJECTED. POSTAMBLE: closing order: `../../shared/includes/audit-postamble.md` §2. Every CC finding needs `path/to/file.ext:LINE` (verify-audit gate).

```
Mandatory-tools-acknowledgment: I will run get_file_tree + search_text + search_patterns for this content audit. Every CC finding will cite a `path/to/file.ext:LINE` resolving in the current tree.
```

**Use the deterministic preload helper FIRST.** Run `~/.zuvo/compute-preload content-audit "$PWD"`. Math gate enforced.

---

## Phase 0: Discovery

### 0.1 Framework detection

Detect the SSG/framework from config files:

```bash
ASTRO=$(find . -maxdepth 3 -name "astro.config.*" 2>/dev/null | wc -l)
NEXT=$(find . -maxdepth 3 -name "next.config.*" 2>/dev/null | wc -l)
HUGO=$(find . -maxdepth 2 \( -name "hugo.toml" -o -name "hugo.yaml" \) 2>/dev/null | wc -l)
GATSBY=$(find . -maxdepth 3 -name "gatsby-config.*" 2>/dev/null | wc -l)
```

### 0.2 Content path auto-detection

Detection cascade (first match wins):

| Framework | Auto-detected paths |
|-----------|-------------------|
| Hugo | `content/` |
| Astro | `src/content/`, `src/pages/` (`.md`/`.mdx` only) |
| Next.js | `content/`, `posts/`, `pages/` (`.md`/`.mdx` only) |
| Gatsby | `content/`, `src/pages/` |
| Generic | `content/`, `posts/`, `articles/`, `docs/`, `blog/` |

Override with `--content-path <dir>`.

If no content directory found: check for CMS config files (`CONTENTFUL_SPACE_ID`
in `.env*`, `sanity.config.*`, `strapi` in `package.json`). If CMS detected,
emit `CONTENT INACCESSIBLE` warning and recommend `--live-url`. Do NOT report
all-PASS for a CMS-backed site with no local files.

### 0.3 Language detection

Multi-signal cascade (first definitive signal wins):

1. **Frontmatter per file:** `lang`, `language`, or `locale` field
2. **Directory convention:** `content/pl/`, `content/en/`, `i18n/de/`
3. **Site config:** Hugo `defaultContentLanguage`, Astro `i18n.defaultLocale`, Next.js `i18n.defaultLocale`
4. **HTML lang attribute:** `<html lang="...">` in layout templates
5. **Fallback:** `unknown` — spell/typo checks (CC8) emit `INSUFFICIENT DATA`

Record detected language(s). Pass to agents A and C: CC8 and the CC1 NBSP, zero-width and mojibake rules depend on it.

### 0.4 File manifest

Build the list of files to scan.

**Include:** `.md`, `.mdx`, `.html` (in content dirs only), `.txt` (content-like)

**Template files:** `.astro`, `.tsx`, `.jsx` — scan only text content between
tags. Strip template interpolation (`{...}`, `{{ }}`, `<% %>`) before text
checks.

**Exclude always:**
- Build output: `dist/`, `.next/`, `_site/`, `public/` (unless it IS the content dir)
- Dependencies: `node_modules/`, `.git/`
- Binary files by extension: `.jpg`, `.png`, `.gif`, `.webp`, `.avif`, `.svg`,
  `.pdf`, `.woff`, `.woff2`, `.ttf`, `.mp4`, `.mp3`, `.zip`, `.tar`, `.gz`,
  `.DS_Store`

For each file, check encoding via `file -b --mime-encoding -- <file>` (`file -i` prints `regular file` on macOS). Flag
non-UTF-8 files with check `encoding-mismatch` (advisory).

### 0.5 Print discovery summary

```
DISCOVERY:
  Framework: [astro | hugo | nextjs | gatsby | generic]
  Content path: [path] (auto-detected | override)
  Language: [code | unknown]
  Files found: [N] content files ([M] skipped binary)
  Live mode: [enabled (url) | disabled]
  Quick mode: [yes | no]
  Profile: [blog | docs | ecommerce | marketing | default]
```

---

## Phase 1: Agent Dispatch

### Quick mode (--quick)

Dispatch follows `../../shared/includes/execution-policy.md` through env-compat. Reuse existing
authorization within that policy; session restrictions take precedence. Run each required gate
and report its actual independence or an unmet requirement.

Do NOT dispatch agents. Run source-only grep checks directly, under the Scope and Language Rules of
`agents/content-encoding.md` (no matches in code; NBSP, zero-width and mojibake by language):

1. CC1 blocking: `mojibake-detected` (grep for mojibake signatures)
2. CC3 blocking: `php-tag` (grep for `<?php`, `<?=`)
3. CC1 scored: `nbsp-present`, `zero-width-present`
4. CC2 scored: `broken-italic`
5. CC3 scored: `joomla-path`, `wp-shortcode`
6. CC5 scored: `img-path-broken` (resolve paths via Glob)
7. CC6 scored: `link-internal-broken` (resolve paths via Glob)

**Skipped in --quick (require agents or live access):**
- CC4 entirely (frontmatter parsing requires agent)
- CC7 entirely (content analysis requires agent)
- CC8 entirely (language detection + LLM judgment)
- `fm-yaml-malformed` → `INSUFFICIENT DATA` (needs YAML parser, not grep)
- `img-404-live` → `N/A` (needs `--live-url`; "CANNOT DETERMINE", not a failure)

Proceed to Phase 2.

### Full mode (default)

Dispatch three agents in **parallel** per `env-compat.md`:

```
Agent A: Content Encoding
  model: sonnet
  type: Explore (read-only; tools Read, Grep, Glob, Bash for read-only commands)
  instructions: [read agents/content-encoding.md]
  input: file manifest, detected stack, detected language, content-check-registry.md
  dimensions: CC1, CC2, CC3

Agent B: Content Links
  model: sonnet
  type: Explore (read-only)
  instructions: [read agents/content-links.md]
  input: file manifest, detected stack, live-probe-protocol.md, --live-url if set, --check-external if set
  dimensions: CC5, CC6

Agent C: Content Prose
  model: sonnet
  type: Explore (read-only)
  instructions: [read agents/content-prose.md]
  input: file manifest, detected language, content-check-registry.md
  dimensions: CC4, CC7, CC8
```

**Cursor fallback:** Execute each agent's analysis sequentially yourself.

Wait for all three agents to complete before proceeding to Phase 2.

---

## Phase 2: Merge & Score

### 2.1 Collect check results

Each agent MUST return **two** structures:
1. **`check_results[]`** — complete matrix of ALL owned checks with status
   (`PASS`, `FAIL`, `PARTIAL`, `N/A`, `INSUFFICIENT DATA`). A live-only check without live access
   (`img-404-live`, `link-external-dead`, `link-external-redirect`) is `N/A`. Every check from
   the registry that the agent owns appears here, even if it passed.
2. **`findings[]`** — details for FAIL and PARTIAL checks only (evidence,
   file:line, fix_type).

Merge `check_results[]` from all agents into a single matrix. Build
`findings[]` from the FAIL/PARTIAL entries.

### 2.2 Deduplicate

If two agents flag the same `file:line` with different checks, keep both.
If two agents flag the same `file:line` with the SAME check (shouldn't happen
with proper dimension assignment), keep the one with higher confidence.

### 2.3 Score

Calculate per-dimension and overall scores:

```
# N/A and INSUFFICIENT DATA checks are not applicable: out of both counts
dimension_score = checks_passed / checks_applicable * 100
overall_score = sum(dimension_scores) / dimensions_with_applicable_checks
# a dimension with no applicable check shows `n/a`, not a percentage; no applicable check at all: unscored
```

Grade mapping:

Both formulas produce fractional scores, so the bands are stated as inequalities —
a hyphenated `75-89` would leave 74.5 ungraded.

| Grade | Score range | Meaning |
|-------|-----------|---------|
| **A** | `>= 90` | Clean content, minor advisory items |
| **B** | `>= 75 and < 90` | Some issues, no blocking findings |
| **C** | `>= 50 and < 75` | Significant issues affecting quality |
| **D** | `< 50` | Critical issues, CMS migration incomplete |

**Blocking gate cap:** If ANY blocking finding exists (`mojibake-detected`,
`php-tag`, `fm-yaml-malformed`, `img-404-live`), the grade is capped at **D**
regardless of numeric score. Only a confirmed `FAIL` counts: `img-404-live` is a live check and
without `--live-url` it is `N/A`, never a blocking failure.

### 2.4 Tag fixable findings

For each finding whose agent-assigned `fix_type` is non-null, add the safety classification from
`content-fix-registry.md`. Never fill in a `fix_type` the agent left `null`: the registry column is the type for
certain corruption only, and a null marks the finding MANUAL.

---

## Phase 3: Report

### 3.1 Markdown report

Write to `zuvo/audits/content-audit-YYYY-MM-DD.md`. Auto-increment
`-2.md`, `-3.md` for same-day runs.

```
CONTENT AUDIT REPORT -- [project name]
----
Grade: [A|B|C|D] ([score]%)
Files scanned: [N] | Findings: [N] total
  BLOCKING: [N]  SCORED: [N]  ADVISORY: [N]
  Auto-fixable: [N] (run zuvo:content-fix)
----

CC1 — Encoding Quality:    [PASS|PARTIAL|FAIL] ([score]%)
CC2 — Markdown Syntax:     [PASS|PARTIAL|FAIL] ([score]%)
CC3 — Migration Artifacts: [PASS|PARTIAL|FAIL] ([score]%)
CC4 — Frontmatter Quality: [PASS|PARTIAL|FAIL] ([score]%)
CC5 — Image Integrity:     [PASS|PARTIAL|FAIL] ([score]%)
CC6 — Link Integrity:      [PASS|PARTIAL|FAIL] ([score]%)
CC7 — Content Completeness:[PASS|PARTIAL|FAIL] ([score]%)
CC8 — Spelling/Typography: [PASS|PARTIAL|FAIL] ([score]%)

FINDINGS:
  F1: [CC1-mojibake-detected] content/post-1.md:42
      Evidence: "Ä…" should be "ą" (ISO-8859-2 → UTF-8 corruption)
      Fix: encoding-mojibake (MODERATE)
  F2: ...

SKIPPED FILES:
  [list of binary files skipped]

NEXT STEPS:
  1. Run zuvo:content-fix to apply [N] auto-fixable findings
  2. Review MODERATE fixes before applying with --auto
  3. Address MANUAL findings listed above
```

### 3.2 JSON report

Write to `zuvo/audits/content-audit-YYYY-MM-DD.json` conforming to
`audit-output-schema.md` v1.1.

```json
{
  "version": "1.1",
  "skill": "content-audit",
  "timestamp": "[ISO 8601]",
  "project": "[working directory]",
  "args": "[arguments]",
  "stack": "[detected framework]",
  "language": "[detected language or unknown]",
  "result": "PASS | FAIL | PROVISIONAL",
  "score": {
    "overall": 75,
    "tier": "D",
    "sub_scores": {
      "CC1": 85, "CC2": 71, "CC3": 100, "CC4": 83,
      "CC5": 67, "CC6": 50, "CC7": 80, "CC8": 60
    }
  },
  "critical_gates": [
    { "id": "CC1-mojibake-detected", "name": "Mojibake detection", "status": "FAIL", "evidence": "12 corrupted sequences in 4 files" },
    { "id": "CC3-php-tag", "name": "PHP tag presence", "status": "PASS", "evidence": "No PHP tags found" },
    { "id": "CC4-fm-yaml-malformed", "name": "Frontmatter YAML validity", "status": "PASS", "evidence": "All 150 files parse" },
    { "id": "CC5-img-404-live", "name": "Image live check", "status": "N/A", "evidence": "CANNOT DETERMINE: --live-url not provided" }
  ],
  "findings": [
    {
      "id": "CC1-mojibake-detected",
      "dimension": "CC1",
      "check": "mojibake-detected",
      "status": "FAIL",
      "enforcement": "blocking",
      "severity": "HIGH",
      "confidence": "HIGH",
      "evidence": "\"Ä…\" should be \"ą\" (ISO-8859-2 corruption)",
      "file": "content/post-1.md",
      "line": 42,
      "fix_type": "encoding-mojibake",
      "fix_safety": "MODERATE",
      "fix_params": {}
    }
  ],
  "summary": {
    "files_scanned": 150,
    "files_skipped": 12,
    "findings_count": 25,
    "fixable": 18
  }
}
```

Use `result: "PROVISIONAL"` when a blocking gate that applies to this run returns
`INSUFFICIENT DATA` (e.g., `fm-yaml-malformed` in `--quick` mode) and no gate is a confirmed FAIL. A confirmed
blocking FAIL always gives tier D and `FAIL`; list the unresolved gate in the report. `img-404-live` without
`--live-url` is `N/A`, not PROVISIONAL.

---

## Phase 4: Adversarial Review (MANDATORY — do NOT skip)

Run AFTER report files are generated (Phase 3). Point `--files` at the report you
just wrote — a literal `[date]` placeholder matches nothing and burns the pass.

```bash
# Phase 3 auto-increments (-2.md, -3.md) on same-day reruns, so take the newest
# match rather than assuming the base name.
REPORT=$(ls -t zuvo/audits/content-audit-$(date +%F)*.md 2>/dev/null | head -1)
[ -n "$REPORT" ] && ~/.zuvo/adversarial-review --mode audit --files "$REPORT" \
  || echo "adversarial: report not found — write it first"
```

**Record the verdicts** after triage: every finding is fixed, rejected (a false positive) or deferred — record each by its `ID:` in ONE call, `~/.zuvo/adversarial-review --record-disposition ID-1 fixed --record-disposition ID-2 rejected …`, per `../../shared/includes/adversarial-loop.md` Step 4.9 (the review lists its IDs on stderr).

If `adversarial-review` is not in PATH: `~/.zuvo/adversarial-review` (stable; the versioned cache path breaks after any release)

Wait for complete output. Fix CRITICAL immediately (update report files).
WARNING → fix if localized. INFO → ignore.

---

## Phase 5: Backlog (optional)

When `--persist-backlog` is enabled, record each finding through `backlog-add`, one call per finding (`shared/includes/backlog-protocol.md` "Filing from a skill"; the bars, the dedupe and the confidence routing are the protocol's and are not restated here):

| Finding status | Backlog action |
|----------------|---------------|
| FAIL (blocking) | Record (`backlog-add`), `E` starting `content-blocking:` |
| FAIL (scored) | Record (`backlog-add`), `E` starting `content-quality:` |
| ADVISORY | Record (`backlog-add`), `E` starting `content-advisory:` |

A **Generic write** per finding: `~/.zuvo/backlog-add --repo "$R" --class <C> --conf <N> --source content-audit --file "$F" --line <n> [--anchor "$A"] --evidence "$E" --title "$T"` when a content or template file causes it. A finding on a live page with no repository file causing it (`--live-url`) takes `--target "$U" --evidence "$E"` in place of `--file`, `--line` and `--anchor`, whatever the class: `~/.zuvo/backlog-add --repo "$R" --class <C> --conf <N> --source content-audit --target "$U" --evidence "$E" --title "$T"`, `U` the page URL. A live defect that a repository file causes is filed by that file (the file form), with the URL in `--evidence "$E"`; the target form is only for a finding with no repository file causing it. `<N>` is your confidence that the finding is real. This audit files `CQ` or `BUG` only: `<C>` is `CQ` for a failed check and `BUG` only when the finding names the input and the wrong output; BUG takes `--anchor "$A"`, copied from the line that shows the defect ("The location rule"). `T` starts with the finding's `check` ID, `<check-id>: <title>` (e.g. `mojibake-detected`), so a later run can find the entry. A check that fails for the whole file is a whole-file finding: `--line 1`, a "Whole file: ..." title (after the check ID), and no `--anchor`; a whole-file BUG is filed at the line that shows the defect instead, with `--anchor "$A"` copied from it, never at line 1. Assign "$R", "$E" and "$T" before each call, "$F" only for a file finding, "$U" only for a target finding, "$A" only when you pass `--anchor`, as "Free text goes through a variable" in that section says; an empty value you pass is a bug, and backlog-add refuses a missing required field (`REFUSED missing-field:<f>`). Report the B- or F-id each call prints and `Recorded: N (backlog: a, ledger: b)` ("The report line" in `backlog-protocol.md`), plus each `NOT PERSISTED (<reason>)` by name; on a non-zero exit act on the protocol's exit table, and never append by hand.

An open entry is closed, never removed (**Closing, not removing**), when this run re-read its cited code and found it fixed. Close each open entry with the same file (or target) and the same title check ID whose cited code this run re-read and found fixed (for a file entry, its line and anchor); leave every other entry with that file and check ID open. A target (live-page) entry is closed only by a later live audit that re-reads the page, never by a source-file patch alone. A legacy entry written in the old `{file}|{dimension}|{check}` fingerprint format is matched by that fingerprint's file and check segments.

Recording findings through `backlog-add` commits and stages nothing. This audit lists the `wrote=` paths backlog-add printed as `Backlog writes: <path>, ...` (`Backlog writes: none` when there are none), in its report for the user when it runs standalone, and in its report for the calling skill's closing commit to carry when another skill runs it (`backlog-protocol.md` "Filing from a skill", **Committing what backlog-add wrote**).

---

## Phase 6: Close

Order per `../../shared/includes/audit-postamble.md` §2: the reports (Phase 3) and the adversarial pass (Phase 4) are done, so retro,
Validity Gate, Run line follow. VERDICT per §1: the critical gates are the four blocking checks
(`mojibake-detected`, `php-tag`, `fm-yaml-malformed`, `img-404-live`), and a `FAIL` on any of them is
`FAIL`; `img-404-live` can only trip under `--live-url`. A `PROVISIONAL` result is noted in NOTES and does not by itself change the VERDICT.

### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

### Validity Gate (REQUIRED — print after the retrospective, before the Run line)

```
VALIDITY GATE
  required_tool_calls:
    get_file_tree: [<N> | NOT_CALLED]
    search_text: [<N> | NOT_CALLED]
    search_patterns: [<N> | NOT_CALLED]
  postamble:
    retros_log_appended: [yes(bytes_added=N) | NOT_APPENDED]
    retros_md_appended: [yes(entry_count=N) | NOT_APPENDED]
    verify_audit_pass: [yes(<verified>/<total>) | NOT_RUN | REJECTED]
  gate_status: [PASS | FAIL]
```

`gate_status = FAIL` → `../../shared/includes/audit-postamble.md` §1 (a `FAIL` already reached stays `FAIL`, otherwise row 3 `INCOMPLETE`); append `[VALIDITY GATE FAIL]` to NOTES and, if the VERDICT changed, rewrite it in the report header and JSON.

### Run line

Append via the retro-gated wrapper, never `>> runs.log`:

```bash
printf '%b\n' "$RUN_LINE" | ~/.zuvo/append-runlog
```

Run: <ISO-8601-Z>	content-audit	<project>	-	-	<VERDICT>	-	8-dim	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>

---

## Edge Case Handling

| Edge case | Handling |
|-----------|---------|
| **Mixed encoding in file** | `file -b --mime-encoding -- <file>` per file. Non-UTF-8 → `encoding-mismatch` (advisory), Unicode checks → `INSUFFICIENT DATA` |
| **Large files (100KB+)** | Read in 500-line chunks. Flag: "large file — chunked read" |
| **Binary files in content dir** | Skip by extension whitelist. Log in "Skipped files" section |
| **CMS-backed content** | Detect CMS config. Emit `CONTENT INACCESSIBLE`. Recommend `--live-url` |
| **Framework-relative images** | `@/`, `~/`, `../assets/` → `img-path-relative-risk` (advisory), not hard FAIL |
| **Anchor links** | Source: extract headings → normalize → compare. Live: DOM inspection |
| **Multilingual dirs** | Detect language per file/directory. Apply CC8 only for matching language |
