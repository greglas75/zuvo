---
name: content-optimize
description: >
  Evaluate and optimize existing articles across 6 dimensions (readability,
  engagement, SEO, structure, authority, anti-slop) using PQ1-PQ18 checks.
  Always produces a diagnostic report with before/after scoring and voice delta
  metric. Optional --apply rewrites content while preserving author voice,
  protected regions (code blocks, MDX components, complex frontmatter), and
  rollback guarantees. Companion to content-audit for editorial hygiene.
  Flags: [file], --apply, --lang, --tone, --force-rewrite, --dry-run,
  --competitors, --skip-benchmark.
---

# zuvo:content-optimize — Article Evaluation & Optimization

Score an existing article across 6 quality dimensions, diagnose weaknesses, and optionally rewrite to improve — without destroying author voice.

**Scope:** Prose quality scoring, structural diagnosis, SEO gap analysis, competitor benchmarking, voice-preserving optimization.
**Out of scope:** Encoding artifacts (`zuvo:content-audit`), code quality (`zuvo:code-audit`), writing from scratch (`zuvo:write-article`), CMS API content, PDF/Word documents.

## Mandatory File Loading

Read these files before any work begins:

1. `../../shared/includes/env-compat.md` -- Agent dispatch and environment adaptation
2. `../../shared/includes/run-logger.md` -- Run logging contract
3. `../../shared/includes/banned-vocabulary.md` -- Hard/soft banned words per language + burstiness rules
4. `../../shared/includes/prose-quality-registry.md` -- PQ1-PQ18 check definitions
5. `../../shared/includes/content-optimize-output-schema.md` -- JSON output contract
6. `../../shared/includes/adversarial-loop-docs.md` -- Cross-model adversarial review
7. `../../shared/includes/audit-output-schema.md` -- Report format reference
8. `../../shared/includes/backlog-protocol.md` -- Backlog fingerprint dedup and update
9. `../../shared/includes/knowledge-prime.md` -- Project knowledge priming
10. `../../shared/includes/knowledge-curate.md` -- Learning extraction after work
11. `../../shared/includes/verification-protocol.md` -- Build verification after apply
12. `../../shared/includes/seo-page-profile-registry.md` -- Profile-aware SEO scoring
13. `../../shared/includes/domain-profile-registry.md` -- Niche-aware schema merge rules

Print `CORE FILES LOADED:` checklist with `[READ | MISSING -> STOP]` for each. If any file is missing, STOP.

## Safety Gates (NON-NEGOTIABLE)

### GATE 1 -- File Type Validation (EC-CO-01)

**Primary:** `.md`, `.mdx` -- full support.
**Tolerated:** `.html` -- strip tags, extract body text only, emit WARNING: "HTML input — tag-stripped, body text only."
**Blocked:** Binary formats, PDF, Word, images -- STOP with error.

### GATE 2 -- Dirty File Check (EC-CO-11)

Before any work:
1. `git status --porcelain -- <file>` -- check for staged and unstaged changes.
2. With `--apply`: if file has uncommitted changes -> **STOP**. Require commit or stash.
3. Without `--apply` (report-only): **proceed with WARNING** banner: "File has uncommitted changes. Report reflects current disk state."

### GATE 3 -- Write Scope

**Allowed write targets with `--apply`:**
- The input file (optimized content)
- `<file>.content-optimize-backup` (temporary backup, deleted on success)
- `audit-results/` for report files (`.md` and `.json`)

**FORBIDDEN:** All other files. No config changes, no dependency installs, no deletions.

---

## Arguments

| Argument | Behavior |
|----------|----------|
| `[file]` | Required. Path to content file. Primary: `.md`, `.mdx`. Tolerated: `.html` (tag-stripped, WARNING). Blocked: binary formats |
| `--apply` | Apply optimizations to the file (default: report only). See Backup Strategy |
| `--lang <code>` | Language override (default: auto-detect from content) |
| `--tone <value>` | `casual` / `technical` / `formal` / `marketing` — adjusts anti-slop soft ban thresholds |
| `--force-rewrite` | Allow structural rewrites on high-scoring (>=80) articles |
| `--dry-run` | Alias for default behavior (report only, no changes) |
| `--competitors <urls>` | Manual competitor URLs (skips web search discovery) |
| `--skip-benchmark` | Skip competitor benchmarking entirely |

---

## Phase 0 -- Setup

### 0.1 File type validation (EC-CO-01)

Check the input file extension against GATE 1. Binary -> STOP. HTML -> strip tags, WARNING.

### 0.2 Dirty file check (EC-CO-11)

Run GATE 2. With `--apply` on dirty file -> STOP. Report-only on dirty file -> WARNING banner, proceed.

### 0.3 Language detection (EC-CO-04)

Multi-signal cascade (first definitive signal wins):

1. `--lang` flag (explicit override)
2. Frontmatter `lang`, `language`, or `locale` field
3. Content analysis (dominant language detection by LLM)
4. **Fallback:** structural-only analysis. Skip language-dependent checks (PQ15-PQ17 anti-slop). Emit: "Language undetected — structural analysis only."

### 0.4 Protected region extraction (EC-CO-03, EC-CO-08)

Extract and tag regions that must NEVER be modified:

- **Fenced code blocks** (``` and ~~~) — preserve verbatim
- **MDX components** (`<Component ...>`, `<Component />`) — never rewrite tags or props
- **Complex YAML frontmatter** (EC-CO-02) — only `title`, `description`, `keywords`, `author` are optimizable. All other fields preserved byte-for-byte

Store protected regions with position markers for re-insertion after optimization.

### 0.5 YAML frontmatter preservation (EC-CO-02)

Parse frontmatter. Mutable: `title`, `description`, `keywords`, `author`. All other fields immutable.

### 0.6 Detect web search availability

Check if web search available. If unavailable: note for Phase 2 skip (EC-CO-05).

Print setup summary: File, Language, Tone, Protected regions count, Web search status, Mode.

---

## Phase 1 -- Analyze

Dispatch 2 agents in **parallel** per `env-compat.md`:

```
Agent A: Prose Quality Scorer
  model: sonnet
  type: Explore (read-only)
  instructions: [read agents/prose-quality-scorer.md]
  input: file content (protected regions masked), detected language, tone, banned-vocabulary.md, prose-quality-registry.md
  dimensions: Readability (PQ1-PQ2), Engagement (PQ3-PQ5), Anti-slop (PQ15-PQ17), Freshness (PQ18)

Agent B: Structure Analyst
  model: sonnet
  type: Explore (read-only)
  instructions: [read agents/structure-analyst.md]
  input: file content, frontmatter, seo-page-profile-registry.md, prose-quality-registry.md
  dimensions: SEO (PQ6-PQ9), Structure (PQ10-PQ12), Authority (PQ13-PQ14)
```

**Cursor fallback:** Execute each agent's analysis sequentially yourself.

Scoring per `prose-quality-registry.md`: 6 dimensions (PQ1-PQ17), composite = weighted mean, tier A/B/C/D per registry thresholds. PQ15 (hard-banned vocabulary) = critical gate: score 0 caps tier at D.

### Enhancement-only gate (EC-CO-06)

If composite >= 80 and `--force-rewrite` NOT set: default to **enhancement-only** mode. Only meta/SEO updates and minor polish allowed — no structural rewrites. Print: "Score >= 80 — enhancement-only mode. Use --force-rewrite for structural changes."

---

## Phase 2 -- Benchmark (optional)

**Skip conditions:** `--skip-benchmark` set, OR web search unavailable (EC-CO-05). On skip: "Benchmark skipped — [reason]. Proceeding with internal analysis only."

### 2.1 Extract topic and keywords

From the article content and frontmatter, identify the primary topic and 3-5 target keywords.

### 2.2 Competitor search

If `--competitors <urls>` provided: use those URLs directly.
Otherwise: web search for top-ranking content on the primary topic. Analyze 3-5 competitor articles.

### 2.3 Gap analysis

Compare against competitors:

- **Topics covered** that this article misses
- **Depth** — word count, section count, example density
- **Structure** — heading patterns, FAQ sections, data tables
- **Freshness** — date references, version numbers

Output: structured gap list for Phase 3.

---

## Phase 3 -- Diagnose

Synthesize agent reports and benchmark results into a prioritized diagnosis:

1. **Weak sections** — thin content, vague claims, missing examples, low specificity ratio
2. **Missing topics** — gaps from competitor analysis (Phase 2)
3. **Structural issues** — poor heading hierarchy, weak intro/CTA, section imbalance (PQ10-PQ12)
4. **SEO gaps** — missing meta, keyword placement, schema gaps (PQ6-PQ9)
5. **Freshness issues** — outdated stats, deprecated references (PQ18)
6. **Voice profile extraction** — sentence length distribution, person (1st/2nd/3rd), punctuation patterns, transition style. This baseline drives the voice delta check in Phase 4.

For report-only mode: this diagnosis IS the deliverable (presented in Phase 5).

---

## Phase 4 -- Optimize (`--apply` only)

Skip entirely without `--apply`. Proceed directly to Phase 5.

### Backup Strategy (NON-NEGOTIABLE)

1. **Pre-condition:** GATE 2 already confirmed file is committed. `git checkout -- <file>` is always a viable rollback.
2. **Backup copy:** Copy original to `<file>.content-optimize-backup`.
3. **Atomic operation:** Compute ALL optimizations on a temp copy. Original replaced ONLY when full pipeline succeeds.
4. **On success:** Delete `.content-optimize-backup`. Original is now the optimized version.
5. **On failure (crash, regression, abort):** `.content-optimize-backup` remains. Report: "ROLLBACK: Backup preserved at <path>. Original file unchanged."
6. **Per-dimension rollback (EC-CO-10):** If a section rewrite causes ANY dimension to regress, revert that single rewrite in the temp copy. Final file contains only non-regressive changes.

### 4.1 Schema Merge Rule

When updating schema in frontmatter or JSON-LD: detect existing `@type` values. If the present schema is more specific than BlogPosting (e.g., Recipe, HowTo, Event, SoftwareApplication), **PRESERVE it** — merge new fields into the existing schema, do not replace `@type`. Only downgrade to plain BlogPosting if user explicitly requests schema regeneration. Reference `../../shared/includes/domain-profile-registry.md` for valid niche-schema mappings.

### 4.2 Rewrite

For each diagnosed issue (Phase 3), apply targeted rewrites on the temp copy:

- Rewrite weak sections while preserving voice profile
- Add content for gap-fill sections
- Improve headings, strengthen intro/conclusion
- SEO pass: update mutable frontmatter fields, suggest internal links
- For files >5000 words (EC-CO-07): section-by-section optimization with full outline as context anchor

### 4.2 Protected region re-insertion

Re-insert all protected regions (code blocks, MDX components, immutable frontmatter) at their original positions. Verify byte-for-byte match.

### 4.3 Internal link validation (EC-CO-12)

For internal link suggestions: validate via Glob against content files in the same directory tree. Unverified links flagged `[UNVERIFIED LINK]`, NOT auto-inserted. Note: "Link targets validated by file path, not by generated URL — verify routing matches your framework."

### 4.4 Re-score

Run the same 6-dimension scoring (Phase 1 logic) on the optimized temp copy. Compare each dimension to the original.

**Per-dimension rollback (EC-CO-10):** If ANY dimension score decreased, revert the changes that caused that regression. Re-score until no dimension regresses. Never deliver a lower composite score.

### 4.5 Voice delta check (EC-CO-09)

Compare optimized text against the original voice profile (Phase 3 step 6):

| Delta | Meaning | Action |
|-------|---------|--------|
| **LOW** | Minimal voice shift | Proceed |
| **MED** | Noticeable but acceptable | Proceed, note in report |
| **HIGH** | Significant voice change | Interactive: ask user confirmation. Async: apply with `[AUTO-DECISION: voice-delta-high]` + `REVIEW NEEDED` flag in report |

### 4.6 Adversarial review

```bash
adversarial-review --mode article --files "<optimized-file>"
```

If `--mode article` not available: fall back to `--mode audit` with WARNING: "Adversarial review used --mode audit (article mode not yet available). Prose-specific checks (burstiness, voice, slop) not covered by this mode."

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Handle findings: CRITICAL -> fix immediately. WARNING -> fix if localized. INFO -> note in report.

### 4.7 Build verification

If in a site directory with a detectable build command: run build verification per `verification-protocol.md`. Build failure -> preserve backup, report ROLLBACK.

### 4.8 Replace original

All checks passed. Replace original file with optimized temp copy. Delete `.content-optimize-backup`.

---

## Phase 5 -- Report

Write report to `audit-results/content-optimize-YYYY-MM-DD.md` (auto-increment for same-day). Contents: file, mode, language, before/after dimension scores, diagnosis, changes (applied or proposed, with rollback notes), benchmark gaps, voice delta, protected regions count.

Write JSON to `audit-results/content-optimize-YYYY-MM-DD.json` per `content-optimize-output-schema.md`.

**VERDICT mapping:** `PASS` (applied, no regressions), `WARN` (report-only with issues, or voice delta MED+), `FAIL` (rollback or CRITICAL), `BLOCKED` (dirty file with --apply, binary input).
**NOTES:** `[report|applied] [file basename] [before]->[after] [tier]` (max 80 chars).

Run knowledge curation per `knowledge-curate.md` (WORK_TYPE="analysis", CALLER="zuvo:content-optimize"). Persist findings per `backlog-protocol.md` — fingerprint: `{file}|{dimension}|{check_id}`, CRITICAL→content-critical, HIGH→content-quality, MEDIUM/LOW→content-advisory.

---

## CONTENT-OPTIMIZE COMPLETE

```
----------------------------------------------------
CONTENT-OPTIMIZE COMPLETE
File: [input file path]
Mode: [report-only | applied]
Composite: [before] → [after] ([tier] → [tier])
Voice delta: [LOW | MED | HIGH | n/a]
Benchmark: [N competitors | skipped]
Protected: [N] code blocks, [N] MDX components preserved
Changes: [N] applied | [N] proposed

Run: <ISO-8601-Z>	content-optimize	<project>	-	-	<VERDICT>	<TASKS>	6-dim	<NOTES>	<BRANCH>	<SHA7>
----------------------------------------------------
```

After printing, append the `Run:` line value (without `Run: ` prefix) to the log file per `run-logger.md`.

Next steps: `zuvo:review [file]` | `zuvo:content-audit [file]` | `zuvo:ship`
