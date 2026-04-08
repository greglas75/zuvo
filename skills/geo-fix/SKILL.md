---
name: geo-fix
description: "Apply fixes from geo-audit findings. Reads geo-audit JSON, classifies by safety tier (SAFE/MODERATE/DANGEROUS), applies framework-aware code patches for schema, robots.txt, canonical, sitemap, llms.txt, and freshness fixes. Emits content scaffolds for advisory findings. Deduplicates against seo-fix to prevent double-application."
tools:
  - Read
  - Edit
  - Write
  - Grep
  - Glob
  - Bash
  - Agent
---

# zuvo:geo-fix -- Apply GEO Audit Fixes

Read geo-audit JSON findings. Plan patches per finding. Validate each patch. Apply by safety tier. Verify build. Report.

**Scope:** Post-audit fix application for GEO findings (schema, robots AI policy, canonical, sitemap, llms.txt, freshness signals, content scaffolds).
**Out of scope:** Content writing, BLUF restructuring, heading rewriting, statistics addition, anti-pattern removal, WordPress plugin config, React SPA fixes. Out-of-scope content findings emit advisory scaffolds only (structural markers, never body content).

## Mandatory File Loading

Read these files before any work begins:

1. `../../shared/includes/codesift-setup.md` -- CodeSift discovery and tool selection
2. `../../shared/includes/env-compat.md` -- Agent dispatch and environment adaptation
3. `../../shared/includes/backlog-protocol.md` -- Backlog fingerprint dedup and update
4. `../../shared/includes/geo-fix-registry.md` -- Canonical fix_type, safety, eta, and manual verification rules
5. `../../shared/includes/fix-output-schema.md` -- JSON report contract
6. `../../shared/includes/seo-bot-registry.md` -- Canonical AI/search bot policy taxonomy for robots fixes
7. `../../shared/includes/run-logger.md` -- Run logging contract
8. `../../shared/includes/verification-protocol.md` -- Fresh-evidence rules for build and endpoint verification
9. `../../shared/includes/knowledge-prime.md` -- Project knowledge priming
10. `../../shared/includes/knowledge-curate.md` -- Learning extraction after work

Print the checklist:

```
CORE FILES LOADED:
  1. codesift-setup.md          -- [READ | MISSING -> STOP]
  2. env-compat.md              -- [READ | MISSING -> STOP]
  3. backlog-protocol.md        -- [READ | MISSING -> STOP]
  4. geo-fix-registry.md        -- [READ | MISSING -> STOP]
  5. fix-output-schema.md       -- [READ | MISSING -> STOP]
  6. seo-bot-registry.md        -- [READ | MISSING -> STOP]
  7. run-logger.md              -- [READ | MISSING -> STOP]
  8. verification-protocol.md   -- [READ | MISSING -> STOP]
  9. ../../shared/includes/knowledge-prime.md  -- READ/MISSING
  10. ../../shared/includes/knowledge-curate.md -- READ/MISSING
```

If any file is missing, STOP.

If native agent dispatch is unavailable, execute the workflow sequentially
yourself, preserve the same validation checkpoints, and note the fallback mode
in the final fix report.

## Safety Gates (NON-NEGOTIABLE)

### GATE 1 -- Write Scope

**Allowed write targets:**
- Files listed in geo-fix-registry.md target paths (source/config files)
- `audit-results/` for the fix report (`.md` and `.json`)
- `memory/backlog.md` for backlog updates

**FORBIDDEN:**
- Installing packages without explicit user confirmation. If a fix requires dependency installation, escalate to NEEDS_REVIEW with install instructions.
- Writing to files not referenced by template registry or finding evidence
- Deleting files

### GATE 2 -- DANGEROUS Fix Confirmation

DANGEROUS fixes (`robots-ai-policy-change`, `schema-restructure`, and safety-upgraded findings) are NEVER auto-applied. Procedure:
1. Show the exact diff that would be applied
2. Explain the risk and expected GEO impact
3. List target files
4. Wait for explicit positive confirmation from user
5. Without confirmation: mark as `MANUAL` and move to next finding

### GATE 3 -- Stale Audit Protection

If audit JSON `timestamp` is >24h old:
- `--dry-run` mode: proceed with warning
- Default mode (SAFE only): proceed with warning
- `--auto` or `--all` mode: **require user confirmation** before mutating. Without confirmation, fall back to `--dry-run`.

### GATE 4 -- Build Verification

After applying fixes, run build verification. Detect build command from project:
1. `package.json` scripts: `build`, `astro build`, `next build`
2. Hugo: `hugo` binary
3. If no build command found: skip build verification, note in report

Build verification claims follow `verification-protocol.md`:
- Capture stdout/stderr **and the process exit code**
- Treat `exit code != 0` as a build failure even if logs contain optimistic lines
  such as `Completed`, `Built`, or similar
- Only report `build_result: PASS` when the detected build exits with code `0`

Build failure -> rollback (see Phase 3 rollback model).

### GATE 5 -- Dirty File Check

Before modifying any file, check for uncommitted changes in that file (`git diff --name-only`). If the file has uncommitted changes, mark finding as `NEEDS_REVIEW` instead of modifying.

---

## Arguments

| Argument | Behavior |
|----------|----------|
| (no args) | Read latest geo-audit JSON, apply SAFE fixes, recommend MODERATE + DANGEROUS |
| `--dry-run` | Show planned fixes without applying |
| `--auto` | Apply SAFE + MODERATE fixes automatically (skip DANGEROUS) |
| `--all` | Include DANGEROUS fixes (requires confirmation per fix) |
| `--skip-adversarial` | Skip cross-provider adversarial review |
| `--finding G5-schema-org,G3-robots-ai` | Fix specific findings by stable ID |
| `--fix-type schema-org-add,robots-ai-allow` | Fix specific fix_type categories |
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
2. Otherwise: glob `audit-results/geo-audit-*.json`, parse `timestamp` from each, select most recent by timestamp (not filename)
3. If no JSON found: "No audit JSON found. Run `zuvo:seo-audit` first (GEO dimensions are included)." STOP.

### 0.2 Validate schema and version

**Version handshake:** Check `version` field. Supported versions: `"1.1"` (minor bumps are backward compatible). If major version differs (e.g., `"2.0"`): STOP with "Unsupported audit schema version [X]. Update zuvo:geo-fix."

**Required fields.** If any missing, STOP with "Invalid audit JSON: missing field [X]":

```
Required: version, skill, timestamp, result, score.overall
Required array: findings[]
Required per finding: id, dimension, check, status, fix_type, fix_safety, fix_params
```

**Skill validation:** `"skill"` field must be `"geo-audit"`. If it is `"seo-audit"`, STOP with "This is an seo-audit JSON. Run geo-fix on geo-audit output only."

### 0.3 Check result and freshness

**PROVISIONAL audit handling:** If `result` = `"PROVISIONAL"`:
- Default mode and `--dry-run`: proceed normally, SAFE fixes are still safe regardless of incomplete gates
- `--auto` mode: restrict to SAFE fixes only (do not auto-apply MODERATE). Warn: "Audit is PROVISIONAL -- restricting to SAFE fixes. Re-run seo-audit with --live-url for full GEO coverage."
- `--all` mode: require confirmation per fix (same as DANGEROUS gate)

**Freshness check:**
Read `timestamp` field. Calculate age.
- If <=24h: proceed
- If >24h: apply GATE 3 (stale audit protection)

### 0.4 Filter findings

Filter findings into two categories:
- **(a) Fixable:** status is `FAIL` or `PARTIAL` with `fix_type` != null
- **(b) Scaffolds:** status is any with `fix_safety` = `"OUT_OF_SCOPE"` (for scaffold emission)

Exclude findings where `fix_type` is not in `geo-fix-registry.md` fixable inventory (Fixable? = yes). Record these as `NO_TEMPLATE`.

### 0.5 Print summary

```
 AUDIT: geo-audit 2026-04-07 (1h ago) | Score: 41/100 (D) | 18 findings
  SAFE:              4 findings (auto-fixable)
  MODERATE:          7 findings (fixable with validation)
  DANGEROUS:         2 findings (manual only)
  OUT_OF_SCOPE:      3 findings (scaffold only -- no content generation)
  NO_TEMPLATE:       1 finding (fix_type not in registry)
  INSUFFICIENT DATA: 1 finding (require live audit for verification)
```

---

## Phase 0.5: Dedup vs seo-fix

### 0.5.1 Read seo-fix output

Glob `audit-results/seo-fix-*.json`. For each file, parse `actions[]`.

### 0.5.2 Check for overlapping fixes

For each seo-fix action with `status: "FIXED"`:
- Check if a matching `fix_type` + `file` pair exists in the current geo-audit findings
- Specifically check `llms-txt-add` (seo-fix) against `llms-txt-generate` / `llms-txt-update` (geo-fix) -- these are equivalent operations on the same file

### 0.5.3 Apply dedup

If match found:
- Skip the geo-fix finding with status `ALREADY_APPLIED_BY_SEO_FIX`
- Record `dedup_source: "seo-fix"` in the action result

If seo-fix applied the fix but with `NEEDS_REVIEW` or `FAILED`:
- Proceed with geo-fix attempt independently

If no seo-fix JSON is present:
- Proceed normally

### 0.5.4 Print dedup summary

```
 DEDUP: N findings already fixed by seo-fix, skipping
```

---

## Phase 1: Plan & Classify

### 1.1 Stack detection (self-contained)

Detect framework directly -- do NOT depend on geo-audit at runtime:

```bash
# Inline stack detection
ASTRO=$(find . -maxdepth 3 -name "astro.config.*" 2>/dev/null | wc -l)
NEXT=$(find . -maxdepth 3 -name "next.config.*" 2>/dev/null | wc -l)
HUGO=$(find . -maxdepth 2 \( -name "hugo.toml" -o -name "hugo.yaml" \) 2>/dev/null | wc -l)
```

Cross-check with `stack` field in audit JSON. If mismatch: warn "Stack changed since audit. Consider re-running geo-audit."

Detect output directory for static files:
- Astro/Next.js/React: `public/`
- Hugo: `static/`
- Unknown: search for `public/` or `static/`, default to `public/`

### 1.2 Sort by safety tier

Order findings: SAFE first, then MODERATE, then DANGEROUS.

### 1.3 Context-aware safety upgrade

Per `geo-fix-registry.md` `upgrade_eligible` rules:

| fix_type | Upgrade condition | From -> To |
|----------|-------------------|------------|
| `schema-org-add` | Target file contains existing JSON-LD | MODERATE -> DANGEROUS |
| `schema-article-add` | Target file contains existing JSON-LD | MODERATE -> DANGEROUS |
| `schema-faq-add` | Target file contains existing JSON-LD | MODERATE -> DANGEROUS |
| `schema-id-link` | Target file contains existing `@id` references | MODERATE -> DANGEROUS |
| `robots-ai-allow` | `robots.txt` has existing bot rules | SAFE -> MODERATE |
| `canonical-add` | Layout file has an existing canonical tag | SAFE -> MODERATE |

When a safety upgrade fires:
1. Record `upgraded: true` and `upgrade_reason` in the fix result JSON
2. Downgrade to `NEEDS_REVIEW` if running in non-interactive mode without `--force`
3. Emit a warning block naming the conflict before applying

### 1.4 Resolve target files

For each fix: resolve framework-specific target file from registry templates.

**Target file priority (key fix types):**

| fix_type | astro | nextjs | hugo |
|----------|-------|--------|------|
| `schema-org-add` | Root layout `<head>` | `app/layout.tsx` | `layouts/partials/head.html` |
| `schema-article-add` | Blog layout `<head>` | Post `page.tsx` | `layouts/_default/single.html` |
| `robots-ai-allow` | `public/robots.txt` | `public/robots.txt` | `static/robots.txt` |
| `canonical-add` | Base layout `<head>` | `app/layout.tsx` | `layouts/partials/head.html` |
| `llms-txt-generate` | `public/llms.txt` | `public/llms.txt` | `static/llms.txt` |

Other fix_types: target file is deterministic from framework (single obvious location per registry).

### 1.5 Print fix plan table

Print table with columns: finding ID, fix_type, safety tier, target file. SAFE first, MODERATE next, DANGEROUS last.

---

## Phase 2: Apply Fixes

For each finding, execute three stages: **plan the patch**, **validate the patch**, **apply the patch**. Group multiple fixes targeting the same file into a single batch edit.

### 2.0 Pre-flight per file

Before modifying any file:
1. Save a snapshot of the original content (in memory, for rollback)
2. Check GATE 5 (dirty file check)
3. If multiple findings target the same file: parse existing structure first, then batch all patches into one coherent edit

### 2.1 SAFE fixes (auto-applied)

For each SAFE finding:
1. **Plan:** Determine target file and insertion point per template registry priority
2. **Validate:**
   - File parse: target file is readable and has expected structure
   - Dedup: the fix content does not already exist in the file
   - For `robots-ai-allow`: check for existing bot rules (upgrade to MODERATE if found)
   - For `canonical-add`: check for existing canonical tag (upgrade to MODERATE if found)
3. **Apply:** Edit the file. One edit per file (batch if multiple findings target same file).
4. Record: `{ finding_id, action, file, status: "FIXED", eta_minutes, manual_checks, risk_notes }`

### 2.2 MODERATE fixes (applied with 3-layer validation)

For each MODERATE finding:
1. **Plan:** Determine target file per priority list. Read target + surrounding context.
2. **Validate (3 layers):**
   - **File parse:** target file is syntactically valid (JSON, JSX, TOML, HTML)
   - **Framework convention:** fix follows framework idiom (e.g., Next.js uses Metadata API, Astro uses `set:html`)
   - **Finding-specific check:** per geo-fix-registry.md post-conditions (e.g., schema-org: no duplicate Organization blocks; schema-article: valid ISO 8601 dates, unique `@id`; schema-faq: >= 2 Q/A entries; schema-id-link: no circular `@id` refs; frontmatter-date: valid YAML; sitemap-lastmod: deterministic strategy, not uniform stale dates)
3. **Apply:** If all 3 layers pass, apply patch. If any layer fails: revert, mark `NEEDS_REVIEW`.
4. Record: `{ finding_id, action, file, status: "FIXED" | "NEEDS_REVIEW", validation_result, eta_minutes, manual_checks, risk_notes }`

### 2.3 OUT_OF_SCOPE findings (scaffold emission)

For findings with `fix_safety: "OUT_OF_SCOPE"`:
- Emit structural scaffolds ONLY (HTML comment placeholders)
- **NEVER** write body content text, descriptions, summaries, or factual content
- **NEVER** populate author bios, About pages, or mission statements

**Scaffold format:** `<!-- TODO: [description] GEO signal: [rationale] -->`

Example: `<!-- TODO: Add a 150-300 word organization description. Include: founding year, core mission, primary audience. GEO signal: used by AI retrieval to answer "what is {org_name}?" -->`

Each scaffold MUST include a GEO rationale so the content author understands why it matters for AI retrieval.

Record: `{ finding_id, action, file, status: "SCAFFOLDED", scaffold_content }`

Scaffolds do NOT count toward the fix success count.

### 2.4 DANGEROUS fixes (gated by GATE 2)

For each DANGEROUS finding:
1. **Plan:** Generate the exact diff that would be applied
2. **Present to user:**
   - Show diff
   - Explain specific risk (e.g., "Opening training bots in robots.txt may allow model scraping. Schema restructure on existing JSON-LD may break Google Rich Results.")
   - List all target files
   - Show expected GEO impact if fix is correct
3. **Wait for confirmation:** positive response -> apply with 3-layer validation. No response or negative -> mark `MANUAL`, move to next finding.
4. Record: `{ finding_id, action, file, status: "FIXED" | "MANUAL", diff, risk }`

### 2.5 INSUFFICIENT DATA findings

Split into two categories:
- **Cannot confirm bug** (e.g., live crawl data inconclusive in code-only):
  `INSUFFICIENT_DATA`. Cannot fix what is not confirmed broken.
- **Cannot determine params** (e.g., site_url unknown but fix is otherwise safe):
  offer `--dry-run` suggestion with placeholder params. Mark as
  `NEEDS_PARAMS` with explicit manual checks.

---

## Phase 3: Verify

### 3.1 Build verification

Detect project build command:
1. Check `package.json` scripts for `build`, or framework-specific: `astro build`, `next build`
2. Hugo: check for `hugo` binary
3. If no build command detected: skip, note "No build verification available" in report

Run the detected build command. Record exact command and exit code.

Hard rules:
- `build_result: PASS` requires `exit code = 0`
- `build_result: FAIL` for any non-zero exit code, regardless of log content
- For public artifacts (`llms.txt`, `robots.txt`, `sitemap.xml`): post-build existence check required. Missing/empty/404 = cannot stay `VERIFIED`

### 3.2 Rollback model

**Per-finding rollback** (not just "last fix"):
- Before each file modification, snapshot is saved (Phase 2.0)
- If build fails: identify which file(s) caused the failure
- Rollback that file to snapshot, re-run build
- If build passes but a required artifact/endpoint check fails (for example
  `/llms.txt` returns `404` or the built file is absent), rollback the
  related fix or downgrade it to `NEEDS_REVIEW` with `verification="FAILED"`
- If still failing: rollback all files from current batch, mark remaining findings as `NEEDS_REVIEW`
- If build passes after selective rollback: keep successful fixes, report rolled-back ones

### 3.3 Gate re-check

For each fix_type applied, run a targeted mini-check (not full cross-file audit):

| fix_type | Re-check |
|----------|----------|
| `robots-ai-allow` | Parse robots.txt, retrieval bot allow rules present, Googlebot not blocked |
| `schema-org-add` | Grep `application/ld+json` + `Organization` in target |
| `schema-article-add` | Grep `application/ld+json` + `Article` in target, `dateModified` present |
| `schema-faq-add` | Grep `application/ld+json` + `FAQPage` in target |
| `schema-id-link` | `@id` references consistent between linked blocks |
| `canonical-add` | Grep `rel="canonical"` in target layout |
| `sitemap-robots-ref` | `Sitemap:` directive in robots.txt |
| `llms-txt-generate` | `llms.txt` exists, valid markdown, `X-Robots-Tag: noindex` configured |
| `frontmatter-date-add` | `dateModified` field in frontmatter |
| Others | Grep for injected content in target file |

Verification semantics:
- `VERIFIED`: build exited `0` (when a build exists) and the targeted re-check
  passed, including artifact/endpoint checks for generated public files
- `ESTIMATED`: source-level mutation looks correct, but no deterministic
  artifact/endpoint check was possible after a successful build
- `FAILED`: the re-check or artifact/endpoint check failed; do not leave the
  action reported as a clean success

### 3.4 Adversarial Review (MANDATORY -- do NOT skip)

```bash
git add -u && git diff --staged | adversarial-review --json --mode code
```

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Wait for complete output. Handle findings by severity:
- **CRITICAL** -- fix immediately, regardless of confidence. If confidence is low, verify first (check the code), then fix if confirmed.
- **WARNING** -- fix if localized (< 10 lines). If fix is larger, add to backlog with specific file:line.
- **INFO** -- known concerns (max 3, one line each).

**OUT_OF_SCOPE scaffold enforcement (MANDATORY):** Adversarial reviewer MUST verify that OUT_OF_SCOPE scaffolds contain only structural markers (HTML comments, placeholder text like `<!-- TODO: ... -->`) and NO generated prose body content. Any generated body text = adversarial review FAIL. If this check fails, revert the scaffold and mark as FAILED.

Do NOT discard findings based on confidence alone. Confidence measures how sure the reviewer is, not how important the issue is. A CRITICAL with low confidence means "verify this -- if true, it's serious."

"Pre-existing" is NOT a reason to skip a finding. If the issue is in a file you are already editing, fix it now. If not, add it to backlog with file:line. The adversarial review found a real problem -- don't dismiss it just because it existed before your changes.

Skip adversarial review ONLY if `--skip-adversarial` flag is passed. Note the skip in the report.

---

## Phase 4: Report

### 4.1 Estimated score calculation

`estimated_after_score` is calculated by:
1. Take all findings from audit JSON
2. For findings confirmed FIXED: change status from FAIL to PASS
3. For findings with `NEEDS_REVIEW`, `MANUAL`, `OUT_OF_SCOPE`,
   `NO_TEMPLATE`, or `INSUFFICIENT_DATA`: keep original status
4. For `SCAFFOLDED` findings: keep original status (scaffolds are not fixes)
5. Recalculate dimension scores and overall using same weights as geo-audit
6. Do NOT simulate benefits of unverified fixes

### 4.2 Report template

Estimated effort rubric: `EASY = <30min`, `MEDIUM = 1-4h`, `HARD = 1+ day`.

```
GEO FIX REPORT -- [project name]
----
Findings: 18 total | 5 fixed | 3 needs review | 2 manual | 3 scaffolded | 1 deduped | ...
Score:    41 -> 58 (estimated from confirmed fixes only)
Build:    [PASS | FAIL (rolled back N fixes) | NOT VERIFIED]
Dedup:    N findings already applied by seo-fix
----

FIXED (auto-applied):
  G3: Added AI retrieval bot allow rules          public/robots.txt           [VERIFIED] ~5 min
  ...

FIXED (validated):
  G5: Added Organization JSON-LD                  src/layouts/Layout.astro    [VERIFIED] ~15 min
  ...

NEEDS REVIEW:
  G8: frontmatter dateModified                    Reason: [specific reason]

MANUAL (DANGEROUS -- user action required):
  G4: robots.txt AI policy change                 Risk: [risk + suggested diff]

SCAFFOLDED (content markers -- no body content written):
  G14: Organization description                   Scaffold: <!-- TODO: ... -->

ALREADY APPLIED BY SEO-FIX:
  G11b: llms.txt generation                       Source: seo-fix JSON ref

[Also: OUT OF SCOPE, NO TEMPLATE, INSUFFICIENT DATA sections as applicable]
```

### 4.3 Save report

1. Save markdown report to `audit-results/geo-fix-YYYY-MM-DD.md`
   Auto-increment: `-2.md`, `-3.md` if same-day file exists.

2. Save fix JSON to `audit-results/geo-fix-YYYY-MM-DD.json` (schema: `../../shared/includes/fix-output-schema.md`):

```json
{
  "version": "1.2",
  "skill": "geo-fix",
  "source_skill": "geo-audit",
  "timestamp": "[ISO 8601]",
  "project": "[cwd]",
  "args": "[arguments]",
  "source_audit": "audit-results/geo-audit-YYYY-MM-DD.json",
  "result": "PARTIAL | COMPLETE | SAFE_ONLY",
  "score": { "before": 41, "estimated_after": 58, "method": "confirmed-fixes-only" },
  "summary": {
    "total": 18, "fixed": 5, "needs_review": 3, "manual": 2,
    "scaffolded": 3, "out_of_scope": 2, "no_template": 1,
    "insufficient_data": 1, "already_applied_by_seo_fix": 1
  },
  "actions": [
    { "finding_id": "G3-robots-ai", "fix_type": "robots-ai-allow", "status": "FIXED",
      "file": "public/robots.txt", "verification": "VERIFIED", "eta_minutes": 5,
      "estimated_time": "<30 minutes", "manual_checks": null,
      "policy_notes": [...], "advisory_scaffolds": null, "risk_notes": [],
      "network_override_risk": false, "upgraded": false },
    { "finding_id": "G14-org-description", "fix_type": null, "status": "SCAFFOLDED",
      "file": "src/pages/about.astro", "scaffold_content": "<!-- TODO: ... -->" },
    { "finding_id": "G11b-llms-txt", "fix_type": "llms-txt-generate",
      "status": "ALREADY_APPLIED_BY_SEO_FIX",
      "dedup_source": "seo-fix", "dedup_ref": "seo-fix-YYYY-MM-DD.json" }
  ],
  "manual_checks": [...],
  "estimated_time": { "easy": 3, "medium": 2, "hard": 0 },
  "policy_notes": [...],
  "advisory_scaffolds": [...],
  "files_modified": [...],
  "build_result": "PASS"
}
```

After printing the report block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

`<DURATION>`: use `N-fixes` (number of findings fixed).

---

## Phase 5: Update Backlog

### 5.1 Backlog operations

Per `shared/includes/backlog-protocol.md`:

| Finding status | Backlog action |
|----------------|---------------|
| FIXED | Remove row by fingerprint |
| NEEDS_REVIEW | If exists: increment `Seen`. If new: add as OPEN |
| MANUAL | Add as OPEN if not present |
| SCAFFOLDED | Persist with scaffold content reference |
| OUT_OF_SCOPE | Add as OPEN with category `geo-manual` |
| NO_TEMPLATE | Add as OPEN with category `geo-manual` |
| ALREADY_APPLIED_BY_SEO_FIX | No backlog action (handled by seo-fix backlog) |
| INSUFFICIENT_DATA | Do not add (unconfirmed issue) |

**Fingerprint format:** `{file}|{dimension}|{check}`

Same format as geo-audit backlog persistence. Uses the stable check ID from the finding (e.g., `robots-ai`, `schema-org`), NOT the fix_type. Example: `public/robots.txt|G3|robots-ai`.

---

### Knowledge Curation

After work is complete, run the knowledge curation protocol from `knowledge-curate.md`:
```
WORK_TYPE = "implementation"
CALLER = "zuvo:geo-fix"
REFERENCE = <git SHA or relevant identifier>
```

---

## GEO-FIX COMPLETE

```
Run: <ISO-8601-Z>	geo-fix	<project>	-	-	<VERDICT>	<TASKS>	<N>-fixes	<NOTES>	<BRANCH>	<SHA7>
```

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.
