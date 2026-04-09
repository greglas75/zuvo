# Implementation Plan: Write-Article SEO/GEO Enhancement

**Spec:** docs/specs/2026-04-09-write-article-seo-enhancement-spec.md
**spec_id:** 2026-04-09-write-article-seo-enhancement-2130
**planning_mode:** spec-driven
**plan_revision:** 2
**status:** Approved
**Created:** 2026-04-09
**Tasks:** 9
**Estimated complexity:** 6 standard, 3 complex

## Architecture Summary

Enhancement to existing `write-article` skill. One new shared include (`domain-profile-registry.md`), one new shared include (`humanization-rules.md` — extracted to save SKILL.md line budget), updates to 5 existing files. Critical: `write-article/SKILL.md` at 287/300 lines requires condensation FIRST (Task 1) before any additions.

## Technical Decisions

- **Task 1 = condensation spike** — prove line budget before anything else (adversarial feedback)
- **Humanization rules extracted** to `shared/includes/humanization-rules.md` — saves ~15 lines in SKILL.md, also reusable by content-optimize
- **Task 5 split** into 3 tasks: Phase 0+2 additions (T5), Phase 3 additions (T6), Phase 5 additions (T7)
- **AC coverage explicit** per task — no blanket "AC #1-#28"

## Quality Strategy

- Verify line count after EVERY task that touches SKILL.md
- Integration gate after Task 7 (install.sh)
- No TDD (markdown-only)

---

## Task Breakdown

### Task 1: Condensation spike — make room in write-article/SKILL.md
**Files:** `skills/write-article/SKILL.md` (modified)
**Complexity:** complex
**Dependencies:** none

**Goal:** Free 30+ lines in SKILL.md without changing behavior. Verify exact headroom.

- [ ] Condense Phase 1 agent dispatch: 3 separate agent blocks → single table (est. ~10 lines saved)
- [ ] Condense Phase 4 adversarial review: remove fallback path explanation, keep one-liner (est. ~5 lines saved)
- [ ] Condense Phase 5 existing SEO: merge redundant keyword/meta descriptions (est. ~5 lines saved)
- [ ] Condense Phase 0 setup summary: tighten print block (est. ~3 lines saved)
- [ ] Condense ARTICLE COMPLETE block: remove verbose next-steps (est. ~5 lines saved)
- [ ] Verify: `wc -l < skills/write-article/SKILL.md` shows ≤260 (target: 30+ lines of headroom)
- [ ] Verify: no behavioral change — all phases, edge cases, and output block still present
- [ ] Acceptance: Prerequisite for all subsequent tasks. No spec AC directly — this is structural.
- [ ] Commit: `refactor: condense write-article SKILL.md — free 30 lines for SEO/GEO enhancement`

### Task 2: Create `shared/includes/domain-profile-registry.md`
**Files:** `shared/includes/domain-profile-registry.md` (new)
**Complexity:** standard
**Dependencies:** none (parallel with Task 1)

- [ ] 17-niche profile table: ID, primary schema, secondary schema, E-E-A-T tier, content rules
- [ ] Detection signals table: frontmatter + content signals per niche
- [ ] Per-niche FAQ rules: which niches generate FAQ, which skip
- [ ] Per-niche snippet format defaults: paragraph/list/table
- [ ] Verify: `grep -c "^|" shared/includes/domain-profile-registry.md` → 17+ data rows
- [ ] Acceptance: Spec AC #1-#3 (domain detection infra)
- [ ] Commit: `feat: add domain-profile-registry — 17 niche profiles with schema, E-E-A-T, detection signals`

### Task 3: Create `shared/includes/humanization-rules.md` + update `banned-vocabulary.md`
**Files:** `shared/includes/humanization-rules.md` (new), `shared/includes/banned-vocabulary.md` (modified)
**Complexity:** standard
**Dependencies:** none (parallel with Tasks 1-2)

- [ ] **humanization-rules.md:** Extract all prompt-based humanization rules from spec DD2:
  - Sentence variation (fragments <8 words + long >30 words, max 3 consecutive medium)
  - Contractions (don't, can't, it's)
  - Parenthetical asides (1+ per 500 words)
  - Rhetorical questions (1+ per 1000 words)
  - First-person references (1+ per article)
  - Hedging transitions ("but", "although", "that said")
  - Entity grounding (specific versions, dates, named tools per section)
  - Structural asymmetry (vary section lengths)
  - Voice matching section (when profile available: match rhythm, person, formality)
- [ ] **banned-vocabulary.md:** Add G12 anti-patterns section:
  - Throat-clearing openers
  - Generic superlatives
  - Keyword density rule (max 3x/500 words)
- [ ] Verify: `test -f shared/includes/humanization-rules.md && grep -c "G12" shared/includes/banned-vocabulary.md`
- [ ] Acceptance: Spec AC #20-#25 (humanization prompt rules), AC #14 (G12 throat-clearing)
- [ ] Commit: `feat: add humanization-rules + G12 anti-patterns — sentence variation, voice matching, entity grounding`

### Task 4: Update `shared/includes/article-output-schema.md` + `anti-slop-reviewer.md`
**Files:** `shared/includes/article-output-schema.md` (modified), `skills/write-article/agents/anti-slop-reviewer.md` (modified)
**Complexity:** standard
**Dependencies:** Task 3 (G12 in banned-vocabulary.md)

- [ ] **article-output-schema.md:** Add fields: `seo.domain`, `seo.schema_type` as array, `seo.snippet_targets`, `seo.faq_count`, `seo.og_tags`, `humanization.voice_matched`, `humanization.voice_profile_source`
- [ ] **anti-slop-reviewer.md:** Add 4 new review sections: G12 anti-patterns, G9 BLUF compliance, G6 chunkability (>300 words), G11 citation compliance
- [ ] Verify: `grep -c "snippet_targets\|domain\|faq_count" shared/includes/article-output-schema.md` → 3+
- [ ] Verify: `grep -c "G12\|G9\|G6\|G11" skills/write-article/agents/anti-slop-reviewer.md` → 4+
- [ ] Acceptance: Spec AC #4b (domain in output), #10-#13 (GEO in review)
- [ ] Commit: `feat: expand output schema + add GEO checks to anti-slop-reviewer — G9/G6/G11/G12`

### Task 5: Update write-article Phase 0 + Phase 2 — domain detection, voice matching, snippet targeting
**Files:** `skills/write-article/SKILL.md` (modified)
**Complexity:** complex
**Dependencies:** Tasks 1 (headroom), 2 (registry), 3 (humanization-rules)

- [ ] **Mandatory File Loading:** add `domain-profile-registry.md` and `humanization-rules.md` to checklist
- [ ] **New arg:** `--domain <niche>` in argument table
- [ ] **Phase 0 — Domain Detection:** detection cascade (`--domain` → site scan → `general`), print in SETUP, edge cases EC-SE-01/02/03/04
- [ ] **Phase 0 — Voice Matching:** read 3-5 articles from `--site-dir` content dir (blog only), extract profile, print in SETUP, EC-SE-09
- [ ] **Phase 2 — Snippet Targeting:** classify H2s (paragraph/list/table), H2 question-word preference (G10), FAQ candidate collection
- [ ] Verify: `wc -l < skills/write-article/SKILL.md` shows ≤285
- [ ] Verify: `grep -c "domain-profile-registry\|voice.*match\|snippet.*target" skills/write-article/SKILL.md` → 3+
- [ ] Acceptance: Spec AC #1-#4a (domain detection), #18-#19 (snippet targeting), #26-#28 (voice matching)
- [ ] Commit: `feat: write-article Phase 0+2 — domain detection, voice matching, snippet targeting`

### Task 6: Update write-article Phase 3 — humanization + GEO constraints
**Files:** `skills/write-article/SKILL.md` (modified)
**Complexity:** standard
**Dependencies:** Task 5 (Phase 0+2 must exist first)

- [ ] **Phase 3 — Humanization:** add reference to `humanization-rules.md` (one-line include, rules live in shared file)
- [ ] **Phase 3 — GEO Constraints:** BLUF ≤30 words first sentence (G9), section cap 300 words (G6), snippet format per H2 classification, stats with attribution (G11)
- [ ] **Phase 3 — FAQ Section:** if FAQ candidates from Phase 2 passed quality gate (3+ questions, >800 words, informational intent), append FAQ section. EC-SE-05, EC-SE-11
- [ ] Verify: `wc -l < skills/write-article/SKILL.md` shows ≤295
- [ ] Verify: `grep -c "humanization-rules\|BLUF\|FAQ.*section" skills/write-article/SKILL.md` → 3+
- [ ] Acceptance: Spec AC #10-#13 (GEO generation), #15-#17 (FAQ), #20-#25 (humanization)
- [ ] Commit: `feat: write-article Phase 3 — humanization rules, BLUF enforcement, chunkability, FAQ generation`

### Task 7: Update write-article Phase 5 — multi-schema, FAQ schema, OG tags
**Files:** `skills/write-article/SKILL.md` (modified)
**Complexity:** complex
**Dependencies:** Task 6

- [ ] **Phase 5 — Multi-Schema:** replace BlogPosting-only with domain-aware schema from registry. `@type` array, `@id` + `isPartOf`, `datePublished`/`dateModified`. EC-SE-06/07/08
- [ ] **Phase 5 — FAQ Schema:** FAQPage JSON-LD auto-appended when FAQ section present. EC-SE-12
- [ ] **Phase 5 — OG Tags:** `og:title`, `og:description`, `og:type: article`, `og:image` placeholder
- [ ] **Phase 5 — Output JSON:** populate new fields (domain, snippet_targets, faq_count, og_tags, voice_matched)
- [ ] Verify: `wc -l < skills/write-article/SKILL.md` shows ≤300
- [ ] Verify: `grep -c "FAQPage\|og:title\|@type.*array\|domain-profile-registry" skills/write-article/SKILL.md` → 3+
- [ ] Acceptance: Spec AC #5-#9 (schema), #15+#17 (FAQ schema), #9 (OG tags)
- [ ] Commit: `feat: write-article Phase 5 — domain-aware multi-schema, FAQ JSON-LD, OG metadata`

### Task 8: Update content-optimize — schema merge behavior
**Files:** `skills/content-optimize/SKILL.md` (modified)
**Complexity:** standard
**Dependencies:** Task 2 (domain-profile-registry)

- [ ] Phase 4 (Optimize): add schema merge rule — detect `@type` arrays, preserve specific types, merge not replace
- [ ] Add `domain-profile-registry.md` to Mandatory File Loading
- [ ] Verify: `wc -l < skills/content-optimize/SKILL.md` shows ≤300
- [ ] Verify: `grep -c "merge\|domain-profile-registry" skills/content-optimize/SKILL.md` → 2+
- [ ] Acceptance: Spec AC #29
- [ ] Commit: `feat: content-optimize schema merge — preserve Recipe/HowTo/Event types on re-optimization`

### Task 9: Integration verification
**Files:** none (verification only)
**Complexity:** standard
**Dependencies:** Tasks 1-8

- [ ] `./scripts/install.sh` — exit 0, 51 skills
- [ ] All SKILL.md files ≤300 lines
- [ ] `domain-profile-registry.md` has 17 niche entries
- [ ] `humanization-rules.md` exists with voice matching section
- [ ] `write-article/SKILL.md` references both new includes
- [ ] `content-optimize/SKILL.md` has schema merge rule
- [ ] Acceptance: Full integration
- [ ] Commit: none
