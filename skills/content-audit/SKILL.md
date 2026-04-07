---
name: content-audit
description: >
  Content file quality audit across 8 dimensions (CC1-CC8): encoding artifacts
  (NBSP, mojibake, zero-width), markdown syntax (broken italic, orphan backslash),
  CMS migration artifacts (Joomla/WordPress/PHP), frontmatter quality, image
  integrity, link integrity with anchor validation, content completeness, and
  spelling/typography. Language-agnostic with multi-encoding mojibake detection.
  Companion fix skill: content-fix. Flags: [path], --live-url <url>, --quick,
  --content-path <dir>, --lang <code>, --check-external, --profile <type>,
  --persist-backlog.
---

# zuvo:content-audit — Content File Quality Audit

Scan content files for encoding artifacts, broken formatting, CMS migration debris, broken links/images, and editorial quality issues. Produces a graded report (A/B/C/D) with auto-fixable findings tagged for `zuvo:content-fix`.

**Scope:** Editorial hygiene, encoding quality, CMS migration cleanup, link/image integrity, frontmatter validation.
**Out of scope:** SEO signals (`zuvo:seo-audit`), code quality (`zuvo:code-audit`), content writing, CMS API content, PDF/Word documents.

## Mandatory File Loading

Read these files before any work begins:

1. `../../shared/includes/codesift-setup.md` -- CodeSift discovery and tool selection
2. `../../shared/includes/env-compat.md` -- Agent dispatch and environment adaptation
3. `../../shared/includes/backlog-protocol.md` -- Backlog fingerprint dedup and update
4. `../../shared/includes/content-check-registry.md` -- Canonical check slugs (49 checks, CC1-CC8)
5. `../../shared/includes/audit-output-schema.md` -- JSON output contract (v1.1)
6. `../../shared/includes/content-fix-registry.md` -- fix_type and safety for tagging fixable findings
7. `../../shared/includes/live-probe-protocol.md` -- Live URL safety rules
8. `../../shared/includes/run-logger.md` -- Run logging contract
9. `../../shared/includes/verification-protocol.md` -- Fresh-evidence rules

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
  9. verification-protocol.md   -- [READ | MISSING -> STOP]
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
- `audit-results/` for the report file (`.md` and `.json`)
- `memory/backlog.md` only when `--persist-backlog` is explicitly enabled

**FORBIDDEN:**
- Modifying any content files
- Creating, deleting, or renaming files outside `audit-results/`

---

## Arguments

| Argument | Behavior |
|----------|----------|
| `[path]` | Scope to specific file or directory |
| `--content-path <dir>` | Override auto-detected content directory |
| `--live-url <url>` | Enable live link/image checks (CC5 img-404-live, CC6 link-external-dead, CC6 link-external-redirect) |
| `--quick` | Source-only grep checks, no agent dispatch. Runs CC1-CC3 grep patterns + CC5/CC6 path resolution. Skips CC4/CC7/CC8 entirely. Checks requiring agents or live access return `INSUFFICIENT DATA`. |
| `--lang <code>` | Force language for spell/typography checks (ISO 639-1: `pl`, `en`, `de`, `tr`, etc.) |
| `--check-external` | Enable external link checking (requires network access) |
| `--persist-backlog` | Append findings to memory/backlog.md |
| `--profile <type>` | Content profile: `blog`, `docs`, `ecommerce`, `marketing`. Adjusts thresholds for CC7 content completeness checks. |

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

Record detected language(s). Pass to agents for CC8 checks.

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

For each file, check encoding via `file -i` (available on Unix/macOS). Flag
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

Do NOT dispatch agents. Run source-only grep checks directly:

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
- `img-404-live` → `INSUFFICIENT DATA` (needs `--live-url`, not grep)

Proceed to Phase 2.

### Full mode (default)

Dispatch three agents in **parallel** per `env-compat.md`:

```
Agent A: Content Encoding
  model: sonnet
  type: Explore (read-only)
  instructions: [read agents/content-encoding.md]
  input: file manifest, detected stack, content-check-registry.md
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
   (`PASS`, `FAIL`, `PARTIAL`, `N/A`, `INSUFFICIENT DATA`). Every check from
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
dimension_score = checks_passed / checks_applicable * 100
overall_score = sum(dimension_scores) / dimensions_with_applicable_checks
```

Grade mapping:

| Grade | Score range | Meaning |
|-------|-----------|---------|
| **A** | 90-100% | Clean content, minor advisory items |
| **B** | 75-89% | Some issues, no blocking findings |
| **C** | 50-74% | Significant issues affecting quality |
| **D** | 0-49% | Critical issues, CMS migration incomplete |

**Blocking gate cap:** If ANY blocking finding exists (`mojibake-detected`,
`php-tag`, `fm-yaml-malformed`, `img-404-live`), the grade is capped at **D**
regardless of numeric score.

### 2.4 Tag fixable findings

For each finding with a non-null `fix_type` in the registry, tag it with the
fix_type and safety classification from `content-fix-registry.md`.

---

## Phase 3: Report

### 4.1 Markdown report

Write to `audit-results/content-audit-YYYY-MM-DD.md`. Auto-increment
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

Run: <ISO-8601-Z>	content-audit	<project>	-	-	<VERDICT>	-	8-dim	<NOTES>	<BRANCH>	<SHA7>

NEXT STEPS:
  1. Run zuvo:content-fix to apply [N] auto-fixable findings
  2. Review MODERATE fixes before applying with --auto
  3. Address MANUAL findings listed above
```

After printing this block, append the `Run:` line value (without the `Run:`
prefix) to the log file path resolved per `run-logger.md`.

### 4.2 JSON report

Write to `audit-results/content-audit-YYYY-MM-DD.json` conforming to
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
    "tier": "B",
    "sub_scores": {
      "CC1": 85, "CC2": 71, "CC3": 100, "CC4": 83,
      "CC5": 67, "CC6": 50, "CC7": 80, "CC8": 60
    }
  },
  "critical_gates": [
    { "id": "CC1-mojibake-detected", "name": "Mojibake detection", "status": "FAIL", "evidence": "12 corrupted sequences in 4 files" },
    { "id": "CC3-php-tag", "name": "PHP tag presence", "status": "PASS", "evidence": "No PHP tags found" },
    { "id": "CC4-fm-yaml-malformed", "name": "Frontmatter YAML validity", "status": "PASS", "evidence": "All 150 files parse" },
    { "id": "CC5-img-404-live", "name": "Image live check", "status": "INSUFFICIENT DATA", "evidence": "--live-url not provided" }
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

Use `result: "PROVISIONAL"` when any blocking gate returns `INSUFFICIENT DATA`
(e.g., `img-404-live` without `--live-url`, or `fm-yaml-malformed` in `--quick`
mode).

---

## Phase 4: Adversarial Review (MANDATORY — do NOT skip)

Run AFTER report files are generated (Phase 3).

```bash
adversarial-review --json --mode audit --files "audit-results/content-audit-[date].md"
```

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Wait for complete output. Fix CRITICAL immediately (update report files).
WARNING → fix if localized. INFO → ignore.

---

## Phase 5: Backlog (optional)

When `--persist-backlog` is enabled, persist findings per
`shared/includes/backlog-protocol.md`:

| Finding status | Backlog action |
|----------------|---------------|
| FAIL (blocking) | Add as OPEN with category `content-blocking` |
| FAIL (scored) | Add as OPEN with category `content-quality` |
| ADVISORY | Add as OPEN with category `content-advisory` |

**Fingerprint format:** `{file}|{dimension}|{check}`

---

## Edge Case Handling

| Edge case | Handling |
|-----------|---------|
| **Mixed encoding in file** | `file -i` per file. Non-UTF-8 → `encoding-mismatch` (advisory), Unicode checks → `INSUFFICIENT DATA` |
| **Large files (100KB+)** | Read in 500-line chunks. Flag: "large file — chunked read" |
| **Binary files in content dir** | Skip by extension whitelist. Log in "Skipped files" section |
| **Template syntax** | Strip `{...}`, `{{ }}`, `<% %>` before CC2/CC8 checks on `.astro`/`.tsx`/`.jsx`/`.mdx` |
| **CMS-backed content** | Detect CMS config. Emit `CONTENT INACCESSIBLE`. Recommend `--live-url` |
| **Framework-relative images** | `@/`, `~/`, `../assets/` → `img-path-relative-risk` (advisory), not hard FAIL |
| **Anchor links** | Source: extract headings → normalize → compare. Live: DOM inspection |
| **Multilingual dirs** | Detect language per file/directory. Apply CC8 only for matching language |
| **Standalone `\`** | Stack-aware: flag for Hugo/Goldmark, skip for GFM targets |
| **Duplicate detection** | Cap at top 50 longest files. Declare sampling in report |
| **Frontmatter templates** | Strip `{{...}}` and `{...}` from YAML strings before text checks |
