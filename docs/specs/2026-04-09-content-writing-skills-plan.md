# Implementation Plan: Content Writing Skills

**Spec:** docs/specs/2026-04-09-content-writing-skills-spec.md
**spec_id:** 2026-04-09-content-writing-skills-1845
**planning_mode:** spec-driven
**plan_revision:** 1
**status:** Approved
**Created:** 2026-04-09
**Tasks:** 13
**Estimated complexity:** 11 standard, 2 complex

## Architecture Summary

Two independent skills (`write-article`, `content-optimize`) sharing 4 new shared includes. Build order: shared includes → agent files → SKILL.md orchestrators → registry/routing updates. Total: 11 new files, 5 modified files.

Key constraint: this is a markdown-only plugin. No code, no npm. Skills are prompt files. "Verification" means: file exists, frontmatter valid, install.sh clean, skill dispatches correctly.

## Technical Decisions

- **write-article** template: `docs/SKILL.md` structure shell, custom 6-phase pipeline
- **content-optimize** template: `content-audit/SKILL.md` adapted for hybrid audit+fix
- **All agents:** model: sonnet, reasoning: false. Web searches done by orchestrator, NOT agents
- **adversarial-loop-docs.md:** append `--mode article` rubric section + table row
- **Draft phase (write-article Phase 3):** runs in orchestrator context, not a sub-agent

## Quality Strategy

- No TDD (markdown-only project — TDD protocol exemption for documentation changes)
- Verify: file exists → frontmatter valid → includes referenced exist → install.sh exits 0 → skill loads
- Risk areas: write-article line count (250-290 est.), --apply backup sequence, --mode article dispatch
- Integration: verify existing skills still route correctly after using-zuvo modification

---

## Task Breakdown

### Task 1: Create `shared/includes/banned-vocabulary.md`
**Files:** `shared/includes/banned-vocabulary.md` (new)
**Complexity:** standard
**Dependencies:** none

- [ ] Write the banned vocabulary shared include with hard ban (EN + PL), soft ban (EN + PL), and burstiness rules per spec DD4
- [ ] Hard ban EN: delve, tapestry, it's worth noting, in the realm of, game-changer, as an AI, certainly!, I'd be happy to, multifaceted, embark
- [ ] Hard ban PL: z pewnością warto zauważyć, w dzisiejszym świecie, nie da się ukryć że, jak powszechnie wiadomo, w kontekście powyższego
- [ ] Soft ban tone-dependent table: casual/marketing (strictest) → technical (partial) → formal (WARNINGs only)
- [ ] Burstiness rules as qualitative heuristics (not deterministic counting)
- [ ] Verify: `test -f shared/includes/banned-vocabulary.md && echo OK`
  Expected: `OK`
- [ ] Acceptance: Spec DD4 (adaptive anti-slop enforcement)
- [ ] Commit: `feat: add banned-vocabulary shared include — hard/soft ban lists for EN/PL with tone-dependent thresholds`

### Task 2: Create `shared/includes/prose-quality-registry.md`
**Files:** `shared/includes/prose-quality-registry.md` (new)
**Complexity:** standard
**Dependencies:** none

- [ ] Write PQ1-PQ18 check registry table per spec Detailed Design section
- [ ] Each check: ID, Dimension, Check description, Severity (CRITICAL/HIGH/MEDIUM/LOW)
- [ ] Dimensions: Readability (PQ1-2), Engagement (PQ3-5), SEO (PQ6-9), Structure (PQ10-12), Authority (PQ13-14), Anti-slop (PQ15-17), Freshness (PQ18)
- [ ] Verify: `grep -c "^| PQ" shared/includes/prose-quality-registry.md` → Expected: `18`
- [ ] Acceptance: Spec section "prose-quality-registry.md"
- [ ] Commit: `feat: add prose-quality-registry — PQ1-PQ18 check definitions for content quality scoring`

### Task 3: Create `shared/includes/article-output-schema.md`
**Files:** `shared/includes/article-output-schema.md` (new)
**Complexity:** standard
**Dependencies:** none

- [ ] Copy JSON schema from spec section "article-output-schema.md"
- [ ] Add field descriptions and required/optional markers
- [ ] Verify: `test -f shared/includes/article-output-schema.md && echo OK`
- [ ] Acceptance: Spec JSON contract for write-article
- [ ] Commit: `feat: add article-output-schema — JSON output contract for write-article skill`

### Task 4: Create `shared/includes/content-optimize-output-schema.md`
**Files:** `shared/includes/content-optimize-output-schema.md` (new)
**Complexity:** standard
**Dependencies:** none

- [ ] Copy JSON schema from spec section "content-optimize-output-schema.md"
- [ ] Add field descriptions: scores.before/after, changes[], findings[], protected_regions, voice_delta
- [ ] Verify: `test -f shared/includes/content-optimize-output-schema.md && echo OK`
- [ ] Acceptance: Spec JSON contract for content-optimize
- [ ] Commit: `feat: add content-optimize-output-schema — JSON output contract for content-optimize skill`

### Task 5: Update `shared/includes/adversarial-loop-docs.md` — add `--mode article`
**Files:** `shared/includes/adversarial-loop-docs.md` (modified)
**Complexity:** standard
**Dependencies:** none

- [ ] Add `### article mode` section after `### tests mode` (before `## Limits`)
- [ ] CRITICAL: factual claim without source, internal contradiction, hard-banned vocabulary
- [ ] WARNING: weak E-E-A-T, buried answer, soft-banned vocabulary, burstiness violation, voice inconsistency
- [ ] INFO: style preference, transition quality, paragraph length
- [ ] Add row to "When to Run" table: `| Article (write-article, content-optimize) | After internal review converges | --mode article |`
- [ ] Verify: `grep -c "article mode" shared/includes/adversarial-loop-docs.md` → Expected: `1`
- [ ] Verify: existing modes unchanged — `grep -c "### spec mode\|### plan mode\|### audit mode\|### tests mode" shared/includes/adversarial-loop-docs.md` → Expected: `4`
- [ ] Acceptance: Spec section "Adversarial Article Mode"
- [ ] Commit: `feat: add --mode article to adversarial-loop-docs — prose quality rubric for content skills`

### Task 6: Create `skills/write-article/agents/` — all 4 agent files
**Files:** `skills/write-article/agents/topic-researcher.md`, `skills/write-article/agents/persona-generator.md`, `skills/write-article/agents/competitor-analyst.md`, `skills/write-article/agents/anti-slop-reviewer.md` (all new)
**Complexity:** standard
**Dependencies:** Task 1 (banned-vocabulary.md), Task 2 (prose-quality-registry.md)

- [ ] **topic-researcher.md**: frontmatter (name, description, model: sonnet, tools: [Read, Glob]). Mission: receive pre-fetched web content from orchestrator, extract facts with citations, produce structured fact sheet. Output format: `## Fact Sheet` with numbered facts and source URLs. **Note: spec Agent Architecture table lists WebSearch as a tool — this is intentionally removed per Tech Lead decision: all web searches done by orchestrator, agents receive pre-fetched content. No existing zuvo agent uses WebSearch directly.**
- [ ] **persona-generator.md**: frontmatter (model: sonnet, tools: [Read]). Mission: generate 3-5 reader personas from topic + audience, produce questions from each perspective. Output: `## Personas` with name, background, 3-5 questions each
- [ ] **competitor-analyst.md**: frontmatter (model: sonnet, tools: [Read, Glob]). Mission: analyze pre-fetched competitor content, identify gaps, keyword landscape. Output: `## Competitor Analysis` with gaps and opportunities
- [ ] **anti-slop-reviewer.md**: frontmatter (model: sonnet, tools: [Read]). Mission: review draft against banned-vocabulary.md (hard + soft per tone), check burstiness, verify facts against fact sheet. Two-model pattern: NO memory of drafting. Output: PASS/FAIL with line-level findings
- [ ] Verify: `ls skills/write-article/agents/*.md | wc -l` → Expected: `4`
- [ ] Acceptance: Spec Agent Architecture table
- [ ] Commit: `feat: add write-article agents — topic-researcher, persona-generator, competitor-analyst, anti-slop-reviewer`

### Task 7: Create `skills/content-optimize/agents/` — both agent files
**Files:** `skills/content-optimize/agents/prose-quality-scorer.md`, `skills/content-optimize/agents/structure-analyst.md` (both new)
**Complexity:** standard
**Dependencies:** Task 2 (prose-quality-registry.md)

- [ ] **prose-quality-scorer.md**: frontmatter (model: sonnet, tools: [Read, Glob]). Mission: score article against PQ1-PQ18 registry, extract voice profile (sentence length, person, punctuation, transitions). Output: dimension scores + voice profile JSON
- [ ] **structure-analyst.md**: frontmatter (model: sonnet, tools: [Read, Glob]). Mission: analyze heading hierarchy, section balance, internal link targets (Glob for file validation), code block / MDX component detection for protected regions. Output: structure score + protected regions list + internal link validation
- [ ] Verify: `ls skills/content-optimize/agents/*.md | wc -l` → Expected: `2`
- [ ] Acceptance: Spec Agent Architecture table
- [ ] Commit: `feat: add content-optimize agents — prose-quality-scorer, structure-analyst`

### Task 8: Create `skills/write-article/SKILL.md`
**Files:** `skills/write-article/SKILL.md` (new)
**Complexity:** complex
**Dependencies:** Tasks 1-6 (all shared includes + write-article agents)
**Execution routing:** deep implementation tier

- [ ] **Frontmatter:** name: write-article, description from spec
- [ ] **Mandatory File Loading:** env-compat.md, run-logger.md, banned-vocabulary.md, prose-quality-registry.md, article-output-schema.md, adversarial-loop-docs.md, seo-page-profile-registry.md. Print checklist with READ/MISSING
- [ ] **Safety Gates:** Allowed write targets: `output/articles/` or `--site-dir` path. FORBIDDEN: modifying existing files, installing packages
- [ ] **Argument Parsing table:** all 9 args from spec (topic, --lang, --tone, --length, --site-dir, --format, --keyword, --audience, --batch-mode)
- [ ] **Phase 0 — Setup:** env-compat detection, arg validation, web search availability probe, site-dir frontmatter schema detection (text fields only, enums get TODO). COMPACT mode trigger for --length <800 (EC-WA-11: collapse research+outline, skip competitor analysis, lighter review). Async defaults with [AUTO-DECISION]. Verify `codesift-setup.md` exists (pre-existing include, needed for EC-WA-05 technical articles)
- [ ] **Phase 1 — Research:** Orchestrator does web search via WebSearch tool, passes content to 3 parallel agents (topic-researcher, persona-generator, competitor-analyst). EC-WA-01 degradation if no web search. Output: structured fact sheet + personas + gaps
- [ ] **Phase 2 — Outline:** STORM pattern — derive outline from persona questions. Map research facts to sections. Internal self-critique. Interactive: present for approval (max 3 revisions, EC-WA-08). Async: auto-approve after 1 revision
- [ ] **Phase 3 — Draft (inline, no agent):** Section-by-section generation. Each section receives: outline, mapped facts, previous sections summary. EC-WA-04 continuity checks for >3000 words. Strip banned vocabulary from research before injection (EC-WA-10). EC-WA-05: technical article code explorer dispatch
- [ ] **Phase 4 — Review:** Dispatch anti-slop-reviewer agent. Then adversarial-loop-docs --mode article (fallback: --mode audit + WARNING). EC-WA-07 domain sensitivity check
- [ ] **Phase 5 — SEO + Output:** Keyword placement, meta tags, BlogPosting schema, internal links (validated if --site-dir). Format per --format flag. Save file. EC-WA-12: batch-mode cache contract (cache key: `{site-dir-basename}:{keyword}`, storage: `memory/write-article-cache-{date}.json`, TTL: session, run_id isolation in NOTES field as `batch:{N}`). Run-logger line
- [ ] **Output block:** `ARTICLE COMPLETE` with Run: line template
- [ ] Verify: `head -5 skills/write-article/SKILL.md` shows valid frontmatter; `wc -l < skills/write-article/SKILL.md` shows under 300
- [ ] Acceptance: Spec AC write-article #1-#10 (must have), #11-#17 (should have)
- [ ] Commit: `feat: add write-article skill — 6-phase pipeline with STORM research, anti-slop review, multi-format output`

### Task 9: Create `skills/content-optimize/SKILL.md`
**Files:** `skills/content-optimize/SKILL.md` (new)
**Complexity:** complex
**Dependencies:** Tasks 1-5, Task 7 (all shared includes + content-optimize agents)
**Execution routing:** deep implementation tier

- [ ] **Frontmatter:** name: content-optimize, description from spec
- [ ] **Mandatory File Loading:** env-compat.md, run-logger.md, banned-vocabulary.md, prose-quality-registry.md, content-optimize-output-schema.md, adversarial-loop-docs.md, audit-output-schema.md, backlog-protocol.md, knowledge-prime.md, knowledge-curate.md, verification-protocol.md, seo-page-profile-registry.md. Print checklist
- [ ] **Safety Gates:** Read-only by default. With --apply: allowed write targets = input file + audit-results/. Dirty file check scoped to --apply only (report-only proceeds with WARNING on dirty files, EC-CO-11)
- [ ] **Argument Parsing table:** all 8 args from spec (file, --apply, --lang, --tone, --force-rewrite, --dry-run, --competitors, --skip-benchmark)
- [ ] **Phase 0 — Setup:** File type validation (EC-CO-01). Dirty file check (--apply only). Language detection. Protected region extraction: code blocks + MDX components (EC-CO-03, EC-CO-08). Complex YAML frontmatter preservation (EC-CO-02)
- [ ] **Phase 1+3 — Analyze + Diagnose:** Dispatch 2 parallel agents (prose-quality-scorer, structure-analyst). Score 6 dimensions: readability, engagement, SEO, structure, authority, anti-slop. Composite score with A/B/C/D tier. If >=80: enhancement-only mode default (EC-CO-06)
- [ ] **Phase 2 — Benchmark (optional):** Web search for competitor content. Gap analysis. Skip if --skip-benchmark or no web search (EC-CO-05)
- [ ] **Phase 4 — Optimize (--apply only):** Backup strategy per spec (backup copy → temp file → per-dimension rollback → cleanup). Rewrite weak sections preserving voice profile. Re-score after optimize; rollback regressions (EC-CO-10). Voice delta check: HIGH in async = [AUTO-DECISION] + REVIEW NEEDED (EC-CO-09). Protected regions re-inserted. Internal links validated (EC-CO-12). Adversarial-loop-docs --mode article
- [ ] **Phase 5 — Report:** Before/after scores, changes, voice delta, competitor gaps, protected regions count. Save .md + .json to audit-results/. Run-logger line
- [ ] **Output block:** `CONTENT-OPTIMIZE COMPLETE` with Run: line template
- [ ] Verify: `head -5 skills/content-optimize/SKILL.md` shows valid frontmatter; `wc -l < skills/content-optimize/SKILL.md` shows under 300
- [ ] Acceptance: Spec AC content-optimize #1-#10 (must have), #11-#16 (should have)
- [ ] Commit: `feat: add content-optimize skill — hybrid audit+fix with voice preservation, regression rollback, multi-format support`

### Task 10: Update `skills/using-zuvo/SKILL.md` + early integration gate
**Files:** `skills/using-zuvo/SKILL.md` (modified)
**Complexity:** standard
**Dependencies:** Tasks 8, 9 (skills must exist before routing)

- [ ] Update version banner: `49 skills` → `51 skills`
- [ ] Add to Priority 2 (Task) section: `| Write an article, blog post, generate content | \`zuvo:write-article\` |`
- [ ] Add to Priority 3 (Audit) section: `| Optimize existing article, improve content quality, score content | \`zuvo:content-optimize\` |`
- [ ] Verify routing entries: `grep -c "write-article\|content-optimize" skills/using-zuvo/SKILL.md` → Expected: `2`
- [ ] Verify count: `grep "51 skills" skills/using-zuvo/SKILL.md` confirms count updated
- [ ] **INTEGRATION GATE:** Run `./scripts/install.sh` now — confirm exit 0 and 51 skills reported. This catches file structure issues BEFORE docs/version tasks
- [ ] Verify existing routing intact: `grep "zuvo:review" skills/using-zuvo/SKILL.md` → still present
- [ ] Acceptance: Spec "Existing files modified" table
- [ ] Commit: `feat: add write-article and content-optimize to skill router — 49→51 skills`

### Task 11: Update `docs/skills.md` — document both new skills
**Files:** `docs/skills.md` (modified)
**Complexity:** standard
**Dependencies:** Tasks 8, 9

- [ ] Add both skills to Content category (or create "Content Creation" subcategory)
- [ ] Update total skill count from 49 to 51
- [ ] Update Content category count
- [ ] Verify: `grep -c "write-article\|content-optimize" docs/skills.md` → Expected: `2`
- [ ] Acceptance: Spec "Existing files modified" table
- [ ] Commit: `docs: add write-article and content-optimize to skills reference — 49→51 skills`

### Task 12: Update plugin manifests — version bump and skill count
**Files:** `package.json` (modified), `.claude-plugin/plugin.json` (modified), `.codex-plugin/plugin.json` (modified)
**Complexity:** standard
**Dependencies:** Tasks 8, 9

- [ ] Bump version in all three files (minor bump to 1.4.0 or patch to next version — match convention from recent commits)
- [ ] Update description: `49 skills` → `51 skills` in all three
- [ ] Verify: all three version strings match — `grep '"version"' package.json .claude-plugin/plugin.json .codex-plugin/plugin.json`
- [ ] Verify: all three contain `51 skills`
- [ ] Acceptance: Spec "Existing files modified" table
- [ ] Commit: `chore: bump version and skill count to 51 in plugin manifests`

### Task 13: Run `install.sh` and verify end-to-end
**Files:** none (verification only)
**Complexity:** standard
**Dependencies:** Tasks 1-12 (all tasks)

- [ ] Run `./scripts/install.sh` — confirm exit 0
- [ ] Verify skill count in output shows 51
- [ ] Start new Claude Code session
- [ ] Test routing: send "write an article about zuvo" → confirm `zuvo:write-article` dispatched
- [ ] Test routing: send "optimize this article" → confirm `zuvo:content-optimize` dispatched
- [ ] Test existing skill: send "review my code" → confirm `zuvo:review` still routes correctly
- [ ] Acceptance: Full integration verification
- [ ] Commit: none (verification only)
