# Implementation Plan: GEO Audit & Fix Skills

**Spec:** `docs/specs/2026-04-07-geo-audit-geo-fix-spec.md`
**spec_id:** 2026-04-07-geo-audit-geo-fix-1415
**plan_revision:** 1
**status:** Approved
**Created:** 2026-04-07
**Tasks:** 12
**Estimated complexity:** 8 standard, 4 complex

## Architecture Summary

7 new markdown files + 1 modification + ~8 metadata updates. Build order:
1. Shared registries (`geo-check-registry.md`, `geo-fix-registry.md`)
2. Schema bump (`fix-output-schema.md` v1.1→v1.2) + test fixes
3. Three geo-audit agents (parallel — no inter-dependencies)
4. `geo-audit/SKILL.md` (depends on registries + agents)
5. `geo-fix/SKILL.md` (depends on registries + geo-audit)
6. Metadata (routing table, skill counts, docs, website YAML)

Dependency constraint: geo-audit MAY read seo-audit output. seo-audit MUST NOT read geo-audit output.

## Technical Decisions

- All files are markdown (no code). "Testing" = contract assertions (string pattern checks in `.sh` scripts) + manual skill execution.
- geo-audit reuses: `seo-bot-registry.md`, `seo-page-profile-registry.md`, `audit-output-schema.md` (v1.1), `env-compat.md`, `backlog-protocol.md`.
- geo-fix reuses: `fix-output-schema.md` (v1.2), `verification-protocol.md`, `backlog-protocol.md`.
- Copy-verbatim from seo-audit: Phase 0.2 stack detection, Phase 4 scoring math, Phase 5 validation, Phase 6 finding format, Phase 7 backlog fingerprint.
- Copy-verbatim from seo-fix: all 5 safety gates, Phase 0.2 version handshake, Phase 2 pre-flight, Phase 3.2 rollback model, Phase 3.4 adversarial review.
- New: Phase 0 seo-audit import protocol, schema graph `@id` analysis, content heuristics (BLUF, chunkability, anti-patterns), WAF detection scoring cap.

## Quality Strategy

- 4 definite regressions to fix immediately: fix-output-schema v1.2 bump breaks `test-shared-contracts.sh` and `validate-seo-skill-contracts.sh` (version string assertions).
- Contract tests for each new file: `tests/geo-suite/` directory mirroring `tests/seo-suite/`.
- Risk areas: version handshake between geo-audit/geo-fix, dedup logic with seo-fix, dimension-to-agent ownership consistency, geo-content-signals agent scope (6 dimensions).
- Routing: `using-zuvo/SKILL.md` must add geo-audit and geo-fix entries.

## Task Breakdown

### Task 1: Create geo-check-registry.md
**Files:** `shared/includes/geo-check-registry.md`
**Complexity:** complex
**Dependencies:** none
**Execution routing:** deep implementation tier

- [ ] RED: Verify file doesn't exist: `test ! -f shared/includes/geo-check-registry.md && echo "READY"`
- [ ] GREEN: Create `shared/includes/geo-check-registry.md` modeled on `seo-check-registry.md`. Must contain:
  - Header with canonical column definitions (owner_agent, layer, enforcement, evidence_mode, fix_type, last_reviewed)
  - Semantic Notes section: import rules for G1/G7/G8 overlapping with seo-audit D3/D5
  - 12 dimension sections (G1 through G12) with check slug tables
  - Each check: slug, description, owner_agent (geo-crawl-access / geo-schema-render / geo-content-signals), layer, enforcement (blocking/scored/advisory), evidence_mode, GCG gate flag, fix_type mapping
  - GCG1-GCG4 checks marked as `blocking`
  - Summary table with per-dimension check counts and total
  - All check slugs use `{dimension}-{check_slug}` format (e.g., `G1-retrieval-bots-access`, `G2-schema-id-connected`)
  - Agent ownership: geo-crawl-access owns G1/G7/G8, geo-schema-render owns G2/G4/G5, geo-content-signals owns G3/G6/G9-G12
  - G9-G12 all advisory enforcement, never blocking
  - Profile override column for G9-G12 (app-shell = N/A, CMS = INSUFFICIENT DATA)
- [ ] Verify: `grep "## G" shared/includes/geo-check-registry.md | wc -l && grep "blocking" shared/includes/geo-check-registry.md | grep -c "GCG" && grep -c "geo-crawl-access\|geo-schema-render\|geo-content-signals" shared/includes/geo-check-registry.md`
  Expected: 12 dimension sections, 4 GCG blocking gates, all 3 agent names present in owner_agent column
- [ ] Acceptance: Spec AC — dimension coverage for all G1-G12, GCG1-GCG4 blocking gates defined
- [ ] Commit: `add geo-check-registry with G1-G12 canonical check slugs and GCG1-GCG4 gates`

---

### Task 2: Create geo-fix-registry.md
**Files:** `shared/includes/geo-fix-registry.md`
**Complexity:** complex
**Dependencies:** none
**Execution routing:** deep implementation tier

- [ ] RED: Verify file doesn't exist: `test ! -f shared/includes/geo-fix-registry.md && echo "READY"`
- [ ] GREEN: Create `shared/includes/geo-fix-registry.md` modeled on `seo-fix-registry.md`. Must contain:
  - Fix Inventory table: all fix_types from spec (robots-ai-allow, robots-ai-policy-change, schema-org-add, schema-article-add, schema-faq-add, schema-id-link, schema-restructure, canonical-add, trailing-slash-config, sitemap-robots-ref, sitemap-lastmod-fix, frontmatter-date-add, schema-date-add, freshness-ui-add, llms-txt-generate, llms-txt-update)
  - Each fix_type: description, fixable? (yes/no/manual), base safety (SAFE/MODERATE/DANGEROUS), eta_minutes, target platforms
  - Safety Classification table per framework (Astro, Next.js, Hugo)
  - Fix Parameters Schema table per fix_type
  - Context-aware safety upgrade rules with `upgrade_eligible: true/false` per the spec's enumeration
  - Estimated Time Bands (copy from seo-fix-registry)
  - Expanded Fix Contracts section for complex fixes (schema-org-add, schema-article-add, schema-faq-add, schema-id-link)
  - OUT_OF_SCOPE handling: G9-G12 findings have fix_type: null, fix_safety: OUT_OF_SCOPE, scaffold field
  - Dedup boundary note: geo-fix includes `llms-txt-generate` and `llms-txt-update` as SAFE fix types (per spec Decision 5). If seo-fix already has an equivalent `llms-txt-add` fix applied (checked via dedup protocol at runtime), geo-fix skips with ALREADY_APPLIED_BY_SEO_FIX. The registry includes both types — dedup happens at fix-time, not registry-time.
- [ ] Verify: `grep -c "fix_type\|SAFE\|MODERATE\|DANGEROUS" shared/includes/geo-fix-registry.md`
  Expected: 30+ matches covering all fix types and safety tiers
- [ ] Acceptance: Spec Decision 5 — safety tier model with upgrade rules
- [ ] Commit: `add geo-fix-registry with 16 fix types, safety tiers, and framework templates`

---

### Task 3: Bump fix-output-schema.md v1.1→v1.2 + fix tests
**Files:** `shared/includes/fix-output-schema.md`, `tests/seo-suite/test-shared-contracts.sh`, `scripts/validate-seo-skill-contracts.sh`
**Complexity:** standard
**Dependencies:** none
**Execution routing:** default implementation tier

- [ ] RED: Run existing tests to confirm they pass on v1.1: `bash tests/seo-suite/test-shared-contracts.sh 2>&1 | tail -5`
  Expected: PASS (baseline before bump)
- [ ] GREEN: In `fix-output-schema.md`:
  - Update title: `# Fix Output Schema (v1.2)`
  - Add `"OUT_OF_SCOPE"` to the `fix_safety` enum in the field definitions
  - Add optional `scaffold` field to actions array (string or null, absent from non-OUT_OF_SCOPE findings)
  - Add optional `source_skill` field to top-level optional fields (string: "geo-audit", "seo-audit", etc.)
  - Update JSON example: `"version": "1.2"`, add `"source_skill": "seo-fix"` to example
  - Add Version 1.2 Changes section with migration notes
  - In `test-shared-contracts.sh`: update `v1.1` assertion to `v1.2`
  - In `validate-seo-skill-contracts.sh`: update `v1.1` assertion to `v1.2`
  - **seo-fix backward compat:** seo-fix/SKILL.md continues to emit `"version": "1.1"` in its output — do NOT update seo-fix. The schema file documents all valid versions (1.1 and 1.2). seo-fix is not in scope of this plan. The version handshake in seo-fix accepts minor bumps (1.x), so it will not break.
- [ ] Verify: `bash tests/seo-suite/test-shared-contracts.sh 2>&1 | tail -5`
  Expected: PASS (tests pass with new version)
- [ ] Acceptance: Spec — fix_safety enum extension, v1.2 migration notes
- [ ] Commit: `bump fix-output-schema to v1.2: add OUT_OF_SCOPE enum, scaffold field, source_skill field`

---

### Task 4: Create geo-crawl-access agent (G1, G7, G8)
**Files:** `skills/geo-audit/agents/geo-crawl-access.md`
**Complexity:** complex
**Dependencies:** Task 1 (geo-check-registry)
**Execution routing:** deep implementation tier

- [ ] RED: Verify directory structure: `test ! -d skills/geo-audit/agents && echo "READY"`
- [ ] GREEN: Create `skills/geo-audit/agents/geo-crawl-access.md` modeled on `seo-audit/agents/seo-technical.md`. Must contain:
  - Frontmatter: name, description, model: sonnet, tools: [Read, Grep, Glob]
  - Mandatory File Loading: codesift-setup.md, geo-check-registry.md, seo-bot-registry.md
  - Input contract: detected_stack, detected_profile, cms_detected, imported_findings, file_paths, codesift_repo
  - **G1: AI Crawler Access** — robots.txt training vs retrieval bot matrix per seo-bot-registry.md, Cloudflare/WAF detection (_headers, wrangler.toml, vercel.json), WAF scoring cap rule (PARTIAL when WAF detected without --live-url), bot identity rule (use canonical names from registry), content negotiation (--live-url only)
  - **G7: Canonicalization & URL Hygiene** — canonical tag presence in layouts, trailing slash config per framework, www/non-www redirect, URL parameter handling
  - **G8: Sitemap & Discovery** — sitemap.xml presence, robots.txt Sitemap directive, lastmod accuracy (flag uniform build-time stamps), content page coverage
  - seo-audit Import Handling section: if imported_findings contains D5 checks, use directly for overlapping G1/G7/G8 checks
  - Critical Gates: GCG1 (retrieval bots not blocked), GCG4 (canonical present)
  - Finding Output Format: raw PASS/PARTIAL/FAIL/INSUFFICIENT DATA per check (copy from seo-technical.md)
  - Constraint: "Do NOT calculate dimension scores — return raw statuses only"
- [ ] Verify: `grep -c "PASS\|PARTIAL\|FAIL\|INSUFFICIENT DATA" skills/geo-audit/agents/geo-crawl-access.md`
  Expected: 10+ occurrences across check descriptions
- [ ] Acceptance: Spec G1, G7, G8 dimension descriptions; AC 2 (file-level evidence), AC 13 (training vs retrieval distinction)
- [ ] Commit: `add geo-crawl-access agent: G1 AI crawler access, G7 canonicalization, G8 sitemap`

---

### Task 5: Create geo-schema-render agent (G2, G4, G5)
**Files:** `skills/geo-audit/agents/geo-schema-render.md`
**Complexity:** complex
**Dependencies:** Task 1 (geo-check-registry)
**Execution routing:** deep implementation tier

- [ ] RED: Verify agent doesn't exist: `test ! -f skills/geo-audit/agents/geo-schema-render.md && echo "READY"`
- [ ] GREEN: Create `skills/geo-audit/agents/geo-schema-render.md` modeled on `seo-audit/agents/seo-assets.md`. Must contain:
  - Frontmatter: name, description, model: sonnet, tools: [Read, Grep, Glob]
  - Mandatory File Loading: codesift-setup.md, geo-check-registry.md
  - **G2: Schema Graph** — JSON-LD presence (Organization, Article, FAQPage, WebSite, Person), `@id` connectivity checks (Org→Article→Person publisher/author/worksFor), attribute richness per type (required + recommended fields), `@graph` pattern preference, Wikidata/Wikipedia sameAs links. Key rule: "generic minimally-populated schema underperforms no schema" — penalize empty schema MORE than absent schema.
  - **G4: SSR & Rendering** — JSON-LD in SSR output vs client-side injection. FAIL patterns: useEffect + JSON-LD (Next.js), client:load island with schema (Astro), document.head.appendChild. PASS patterns: inline script type=application/ld+json in layout/page. Framework-specific checks for Astro islands, Next.js 'use client' components.
  - **G5: Freshness Signals** — dateModified in Article schema (present + not hardcoded), datePublished present, frontmatter freshness fields (date, updated, lastmod, modified), build-time injection detection (uniform dateModified = flag), sitemap lastmod (present + varying), visible "Last updated" pattern in templates.
  - Critical Gates: GCG2 (≥1 schema with @id), GCG3 (JSON-LD is SSR)
  - Import handling: if imported D3 findings available, use as starting point for G2; if CG5 status available, use for G4
  - Constraint: "Do NOT calculate dimension scores"
- [ ] Verify: `grep -c "@id\|JSON-LD\|dateModified\|SSR" skills/geo-audit/agents/geo-schema-render.md`
  Expected: 15+ occurrences
- [ ] Acceptance: Spec G2, G4, G5 dimensions; AC 14 (schema richness distinction)
- [ ] Commit: `add geo-schema-render agent: G2 schema graph, G4 SSR rendering, G5 freshness`

---

### Task 6: Create geo-content-signals agent (G3, G6, G9-G12)
**Files:** `skills/geo-audit/agents/geo-content-signals.md`
**Complexity:** complex
**Dependencies:** Task 1 (geo-check-registry)
**Execution routing:** deep implementation tier

- [ ] RED: Verify agent doesn't exist: `test ! -f skills/geo-audit/agents/geo-content-signals.md && echo "READY"`
- [ ] GREEN: Create `skills/geo-audit/agents/geo-content-signals.md` modeled on `seo-audit/agents/seo-content.md`. Must contain:
  - Frontmatter: name, description, model: sonnet, tools: [Read, Grep, Glob]
  - Mandatory File Loading: codesift-setup.md, geo-check-registry.md, seo-page-profile-registry.md
  - **G3: llms.txt & AI Discovery** — llms.txt present in public/static root, structure per llmstxt.org spec (H1 site name, blockquote, H2 sections, markdown links), llms-full.txt companion, link coverage ratio, robots.txt reference. Scoring note about Otterly removing llms.txt from scoring.
  - **G6: Structured HTML & Chunkability** — tables, lists, definition lists in content pages. Section length 130-160 words (cite Kopp Online Marketing research). Flagged as advisory when >300 words without sub-headings. Semantic HTML elements (article, section, nav, aside) vs div-soup.
  - **G9: BLUF & Answer Blocks (advisory)** — First sentence after H2/H3: ≤30 words, no throat-clearing regex, contains number/proper noun/technical term. Profile-aware (marketing = product clarity). CMS = INSUFFICIENT DATA.
  - **G10: Heading Structure (advisory)** — Single H1, H2 question words (What/How/Why/When/Which...), H2/H3 hierarchy, max 300 words between headings, heading makes sense out of context.
  - **G11: Citation Signals (advisory)** — Statistics with attribution regex, dated facts, source linking. docs/ecommerce profiles = N/A. CMS = INSUFFICIENT DATA.
  - **G12: Anti-patterns (advisory)** — Throat-clearing openers regex (first 200 chars after H2/H3), keyword stuffing (>3× per 500 words), generic superlatives regex, filler phrases. English default + --lang pl patterns. CMS = INSUFFICIENT DATA.
  - All G9-G12: enforcement = advisory, never blocking. fix_type = null, fix_safety = OUT_OF_SCOPE. Emit content scaffold suggestions.
  - Constraint: "Do NOT calculate dimension scores"
- [ ] Verify: `grep -c "advisory\|INSUFFICIENT DATA\|scaffold\|BLUF\|throat-clearing" skills/geo-audit/agents/geo-content-signals.md`
  Expected: 15+ occurrences
- [ ] Acceptance: Spec G3, G6, G9-G12 dimensions; AC 9 (advisory only), AC 10 (CMS INSUFFICIENT DATA), AC 12 (multilingual)
- [ ] Commit: `add geo-content-signals agent: G3 llms.txt, G6 chunkability, G9-G12 content quality`

---

### Task 7: Create geo-audit SKILL.md
**Files:** `skills/geo-audit/SKILL.md`
**Complexity:** complex
**Dependencies:** Tasks 1, 2, 4, 5, 6
**Execution routing:** deep implementation tier

- [ ] RED: Verify skill doesn't exist: `test ! -f skills/geo-audit/SKILL.md && echo "READY"`
- [ ] GREEN: Create `skills/geo-audit/SKILL.md` modeled on `seo-audit/SKILL.md`. Structure:
  - YAML frontmatter: name: geo-audit, description (one paragraph about GEO audit)
  - `# zuvo:geo-audit`
  - Argument Parsing table: [path], --profile, --cms/--no-cms, --live-url, --lang, --persist-backlog
  - Mandatory File Loading checklist (9 files: codesift-setup, env-compat, seo-bot-registry, seo-page-profile-registry, geo-check-registry, geo-fix-registry, audit-output-schema, backlog-protocol, run-logger)
  - **Phase 0:** Parse arguments, stack detection (copy seo-audit Phase 0.2 bash), profile auto-detection (blog/docs/ecommerce/marketing/app-shell heuristics), CMS auto-detection (WordPress/Contentful/Sanity/Strapi/Prismic + narrowed GraphQL heuristic)
  - **Phase 0.5: seo-audit Import Protocol** — scan audit-results/ for seo-audit-*.json, select lexicographically greatest, extract layer:geo findings from D3/D5/D9/D10, extract critical_gates.CG5, map to G dimensions, tag [IMPORTED:seo-audit], 48h staleness warning, dependency direction constraint
  - **Phase 1: Agent Dispatch** — 3 parallel agents (geo-crawl-access, geo-schema-render, geo-content-signals). Pass: detected_stack, detected_profile, cms_detected, imported_findings, file_paths, codesift_repo. Claude Code: Task tool, sonnet, Explore. Codex: TOML agents. Cursor: sequential.
  - **Phase 2: Merge** — concatenate findings, assign stable IDs {dimension}-{check_slug}, assign display IDs F1..FN, conflict resolution (geo-audit > imported)
  - **Phase 3: Scoring** — check-to-value mapping (PASS=1.0, PARTIAL=0.5, FAIL=0.0, excluded), dimension scores, weighted overall (G1:15%, G2:18%, G3:8%, G4:12%, G5:10%, G6:7%, G7:10%, G8:5%, G9:5%, G10:4%, G11:3%, G12:3%), critical gates GCG1-GCG4 (any FAIL = overall FAIL, INSUFFICIENT DATA = PROVISIONAL), tier A≥85/B≥70/C≥50/D<50, 3D priority formula
  - **Phase 4: Validation** — 8-item checklist (count consistency, score math, gate completeness, evidence completeness) — copy from seo-audit Phase 5
  - **Phase 5: Report** — executive summary with overall score/tier/gates, scope notices (CMS, WAF advisories), dimension score table, per-finding details with evidence, fix coverage summary, JSON output to audit-results/geo-audit-YYYY-MM-DD.json with "skill": "geo-audit". **Extension fields note:** `profile`, `cms_detected`, `seo_audit_imported`, `scope_notices`, `advisories` are geo-audit-specific extension fields tolerated under audit-output-schema v1.1 unknown-key rules. Do NOT bump audit-output-schema — only fix-output-schema bumps to v1.2.
  - **Phase 6: Backlog** — optional --persist-backlog, fingerprint format {file}|{dimension}|{check}
  - GEO-AUDIT COMPLETE block with Run: line per run-logger.md
- [ ] Verify: `grep -c "Phase\|GCG\|geo-check-registry\|geo-fix-registry\|\"skill\": \"geo-audit\"" skills/geo-audit/SKILL.md`
  Expected: 20+ occurrences covering all phases and references
- [ ] Acceptance: Spec AC 1-6, 9-11, 13-16
- [ ] Commit: `add geo-audit skill: 12 dimensions, 4 critical gates, 3-agent parallel dispatch, seo-audit import`

---

### Task 8: Create geo-fix SKILL.md
**Files:** `skills/geo-fix/SKILL.md`
**Complexity:** complex
**Dependencies:** Tasks 2, 3, 7
**Execution routing:** deep implementation tier

- [ ] RED: Verify skill doesn't exist: `test ! -f skills/geo-fix/SKILL.md && echo "READY"`
- [ ] GREEN: Create `skills/geo-fix/SKILL.md` modeled on `seo-fix/SKILL.md`. Structure:
  - YAML frontmatter: name: geo-fix, description
  - `# zuvo:geo-fix`
  - Argument Parsing: (no args)=latest audit, --dry-run, --auto, --all, --skip-adversarial
  - Mandatory File Loading (8 files: codesift-setup, env-compat, backlog-protocol, geo-fix-registry, fix-output-schema, seo-bot-registry, run-logger, verification-protocol)
  - **Safety Gates (NON-NEGOTIABLE)** — copy all 5 from seo-fix. Gate 2: DANGEROUS fixes require explicit user confirmation with diff preview.
  - **Phase 0: Load Findings** — read audit-results/geo-audit-YYYY-MM-DD.json (latest), validate "skill": "geo-audit", version handshake (supported: "1.1"), filter findings: (a) FAIL/PARTIAL with fix_type != null, (b) OUT_OF_SCOPE with fix_safety: "OUT_OF_SCOPE" for scaffold emission
  - **Phase 0.5: Dedup vs seo-fix** — read all audit-results/seo-fix-*.json, check actions[] for matching fix_type + file pairs with status "FIXED", skip with ALREADY_APPLIED_BY_SEO_FIX
  - **Phase 1: Plan & Classify** — sort by safety tier (SAFE→MODERATE→DANGEROUS), context-aware safety upgrade per geo-fix-registry.md upgrade_eligible rules, framework-specific target resolution per fix_type
  - **Phase 2: Apply** — per-finding: snapshot, apply fix template, verify file parse, batch edits for same file. OUT_OF_SCOPE: emit scaffold only (HTML comments, placeholder markers, NO prose body content)
  - **Phase 3: Verify** — build verification (detect-and-run), rollback model (per-finding snapshots), gate re-check table per fix_type, adversarial review (MANDATORY — enforcement rule: verify OUT_OF_SCOPE scaffolds contain no generated prose)
  - **Phase 4: Report** — summary with score before/estimated after, actions list per finding, JSON output to audit-results/geo-fix-YYYY-MM-DD.json with "skill": "geo-fix", "version": "1.2", "source_skill": "geo-audit"
  - **Phase 5: Backlog** — update backlog: FIXED→remove, NEEDS_REVIEW→increment
  - GEO-FIX COMPLETE block with Run: line
- [ ] Verify: `grep -c "SAFE\|MODERATE\|DANGEROUS\|OUT_OF_SCOPE\|adversarial\|rollback\|scaffold" skills/geo-fix/SKILL.md`
  Expected: 20+ occurrences
- [ ] Acceptance: Spec AC 7, 8; Spec Decision 5 (safety tiers)
- [ ] Commit: `add geo-fix skill: safety-tiered fixes, seo-fix dedup, scaffold-only for content`

---

### Task 9: Update using-zuvo routing table
**Files:** `skills/using-zuvo/SKILL.md`
**Complexity:** standard
**Dependencies:** Tasks 7, 8
**Execution routing:** default implementation tier

- [ ] RED: Verify current routing table doesn't contain geo-audit: `grep -c "geo-audit" skills/using-zuvo/SKILL.md`
  Expected: 0 (not present yet)
- [ ] GREEN: In `skills/using-zuvo/SKILL.md`:
  - Update skill count in version banner (increment by 2)
  - Add geo-audit row to the audit priority table: `| GEO readiness audit, AI citation optimization, schema graph, llms.txt | zuvo:geo-audit |`
  - Add geo-fix row to the task/fix priority table: `| Fix GEO audit findings, apply schema/robots.txt/canonical fixes | zuvo:geo-fix |`
  - Ensure routing triggers include: "geo", "GEO", "generative engine", "AI citation", "llms.txt audit", "schema graph"
- [ ] Verify: `grep -c "geo-audit\|geo-fix" skills/using-zuvo/SKILL.md`
  Expected: 2+ (both skills routed)
- [ ] Acceptance: QA report item 4.1 — routing miss without this
- [ ] Commit: `add geo-audit and geo-fix to using-zuvo routing table`

---

### Task 10: Update skill counts and metadata
**Files:** `package.json`, `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `docs/skills.md`
**Complexity:** standard
**Dependencies:** Tasks 7, 8
**Execution routing:** default implementation tier

- [ ] RED: Check current counts: `grep -c "skills" package.json .claude-plugin/plugin.json .codex-plugin/plugin.json`
- [ ] GREEN:
  - `package.json`: update skill count in description
  - `.claude-plugin/plugin.json`: update skill count in description, add geo-audit and geo-fix to skills array if applicable
  - `.codex-plugin/plugin.json`: update skill count in description
  - `docs/skills.md`: add geo-audit and geo-fix to the appropriate category table (Audits or new GEO category), update total count, update header
- [ ] Verify: `grep "skills" package.json .claude-plugin/plugin.json .codex-plugin/plugin.json | grep -o "[0-9]*" | sort -u`
  Expected: single consistent count across all files
- [ ] Acceptance: QA report items 4.2-4.5
- [ ] Commit: `update skill counts and metadata for geo-audit and geo-fix`

---

### Task 11: Create contract tests for geo suite
**Files:** `tests/geo-suite/test-geo-check-registry.sh`, `tests/geo-suite/test-geo-fix-registry.sh`, `tests/geo-suite/test-geo-audit-contract.sh`, `tests/geo-suite/test-geo-fix-contract.sh`, `tests/geo-suite/test-suite-e2e.sh`
**Complexity:** standard
**Dependencies:** Tasks 1-8
**Execution routing:** default implementation tier

- [ ] RED: Verify test directory doesn't exist: `test ! -d tests/geo-suite && echo "READY"`
- [ ] GREEN: Create `tests/geo-suite/` with 5 test scripts:
  - `test-geo-check-registry.sh`: assert all G1-G12 sections, blocking enforcement for GCG checks, owner_agent assignments match agents, total check count
  - `test-geo-fix-registry.sh`: assert all fix_types present, safety tiers, fix params schema
  - `test-geo-audit-contract.sh`: assert SKILL.md contains: geo-check-registry ref, geo-fix-registry ref, GCG1-GCG4, 3 agent names, "skill": "geo-audit", Run: line, all mandatory files in checklist
  - `test-geo-fix-contract.sh`: assert SKILL.md contains: geo-fix-registry ref, SAFE/MODERATE/DANGEROUS/OUT_OF_SCOPE, adversarial, rollback, scaffold, "skill": "geo-fix", Run: line
  - `test-suite-e2e.sh`: runs all 4 test scripts, reports pass/fail count
- [ ] Verify: `bash tests/geo-suite/test-suite-e2e.sh 2>&1 | tail -3`
  Expected: all tests PASS
- [ ] Acceptance: QA report — contract test coverage for all new files
- [ ] Commit: `add geo contract test suite with registry, audit, and fix contract tests`

---

### Task 12: Create website skill YAML files
**Files:** `website/skills/geo-audit.yaml`, `website/skills/geo-fix.yaml`
**Complexity:** standard
**Dependencies:** Tasks 7, 8
**Execution routing:** default implementation tier

- [ ] RED: Verify directory exists and files don't: `test -d website/skills && test ! -f website/skills/geo-audit.yaml && echo "READY"`. **Note:** If `website/skills/` does not exist in zuvo-plugin (website source may be in ~/DEV/zuvo-landing), skip this task entirely — the YAML files belong in the website repo, not the plugin repo. Check with `ls website/skills/*.yaml 2>/dev/null | head -3`.
- [ ] GREEN: Create YAML files modeled on `website/skills/seo-audit.yaml` and `website/skills/seo-fix.yaml`:
  - `geo-audit.yaml`: name, slug, category, description, dimensions (G1-G12 with names), critical_gates (GCG1-GCG4), flags, output_format, related_skills
  - `geo-fix.yaml`: name, slug, category, description, safety_tiers, fix_types list, flags, output_format, related_skills
- [ ] Verify: `ls website/skills/geo-*.yaml | wc -l`
  Expected: 2
- [ ] Acceptance: QA report item 4.9
- [ ] Commit: `add website YAML files for geo-audit and geo-fix skill pages`
