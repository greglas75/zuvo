---
name: write-article
description: >
  Write high-quality articles from scratch using a 6-phase pipeline: deep
  STORM-inspired research with parallel agents, multi-perspective outline
  generation, section-by-section drafting with research grounding, adaptive
  anti-slop enforcement (hard/soft banned vocabulary per tone), cross-model
  adversarial review, and SEO optimization with BlogPosting schema. Supports
  site-aware output with frontmatter auto-detection, batch mode for multi-article
  sessions, and graceful degradation when web search is unavailable. Flags:
  --lang, --tone, --length, --site-dir, --format, --keyword, --audience,
  --batch-mode.
---

# zuvo:write-article — Research-Grounded Article Writer

Write articles backed by real research, not model memory. Every claim traces to a fact sheet. Every draft passes anti-slop review before output.

**Scope:** Long-form articles, blog posts, technical guides, marketing content.
**Out of scope:** Translation, image generation, CMS publishing, video/audio content, plagiarism detection.

## Mandatory File Loading

Read these files before any work begins:

1. `../../shared/includes/env-compat.md` -- Agent dispatch and environment adaptation
2. `../../shared/includes/run-logger.md` -- Run logging contract
3. `../../shared/includes/banned-vocabulary/core.md` -- Shared anti-slop rules, tone matrix, G12, fallback behavior
4. `../../shared/includes/banned-vocabulary/languages/<resolved-lang>.md` -- Active hard/soft list after `--lang` normalization; fallback `en`
5. `../../shared/includes/prose-quality-registry.md` -- PQ1-PQ18 check definitions
6. `../../shared/includes/article-output-schema.md` -- JSON output contract
7. `../../shared/includes/adversarial-loop-docs.md` -- Cross-model review protocol
8. `../../shared/includes/seo-page-profile-registry.md` -- Word count thresholds and SEO profiles
9. `../../shared/includes/domain-profile-registry.md` -- 17 niche profiles: schema, E-E-A-T, detection signals
10. `../../shared/includes/humanization-rules.md` -- Anti-detection writing constraints + voice matching
11. `../../shared/includes/retrospective.md` -- RETRO PROTOCOL

Print `CORE FILES LOADED:` checklist with `[READ | MISSING -> STOP]` for each. For item 4 print the resolved language file and whether English fallback was used.

## Safety Gates

**Allowed write targets:**
- `output/articles/` for generated article files
- `--site-dir <path>` when explicitly provided by the user
- `memory/write-article-cache-*.json` for batch mode cache

**FORBIDDEN:**
- Modifying existing files (this skill creates new files only)
- Installing packages or running build commands
- Writing outside the allowed targets

## Arguments

| Argument | Behavior |
|----------|----------|
| `<topic>` | Required. The article topic or title |
| `--lang <code>` | Language (default: `en`). Affects banned vocabulary, SEO, register |
| `--tone <value>` | `casual` / `technical` / `formal` / `marketing` (default: `casual`) |
| `--length <N>` | Approximate word count (default: `1500`). <800 = COMPACT mode (EC-WA-11) |
| `--site-dir <path>` | Write to site content dir; auto-detect frontmatter schema from existing articles |
| `--format <fmt>` | `md` (default) / `astro-mdx` / `hugo` / `nextjs-mdx`. Unsupported value: fall back to `md` with note (EC-WA-09) |
| `--keyword <term>` | Primary SEO keyword (auto-detected from topic if omitted) |
| `--audience <desc>` | Target audience description (feeds persona generation) |
| `--domain <niche>` | Override auto-detection. One of 17 niche IDs from `domain-profile-registry.md` (e.g., `travel`, `recipe-food`, `technical`, `saas-product`) |
| `--batch-mode` | Cache competitor/domain research per session. Key: `{site-dir-basename}:{keyword}`. Storage: `memory/write-article-cache-{date}.json`. TTL: session or 24h (EC-WA-12) |

---

## Phase 0 -- Setup

1. Read `../../shared/includes/env-compat.md`. Detect environment (Claude Code / Codex / Cursor / Antigravity).
2. Parse and validate arguments. If `<topic>` is missing: STOP.
3. Resolve the active language file from `../../shared/includes/banned-vocabulary/languages/` using the normalized base code from `--lang` (for example `pt-BR -> pt`, `zh-CN -> zh`). If missing: load `en.md` and emit `WARNING: banned-vocabulary fallback -> en`.
4. **Vague topic gate (EC-WA-02):** If topic lacks specificity (no audience, keyword, or length signal), ask for clarification: audience, keyword, length, tone. Async: apply defaults with `[AUTO-DECISION: defaults-applied]`.
5. **Web search probe:** Test `WebSearch` availability. If unavailable, set `research_limited = true` and emit: `WARNING: Web search unavailable. Article will use context-only research. Frontmatter tagged research_limited: true.` (EC-WA-01)
6. **Site-dir schema detection:** If `--site-dir` provided, inspect the local content schema/config first and then read 2-3 existing articles to confirm actual frontmatter shape. Treat the schema/config as the source of truth for allowed fields. Text fields (title, description, tags): populate. Enums, relational IDs, custom types: use placeholder values with `# TODO` comments. If `og*` or modification-date fields are not clearly supported by the schema, do not invent them.
7. **Domain detection:** Cascade: `--domain` override → scan 3-5 articles in `--site-dir` for frontmatter/content signals per `domain-profile-registry.md` → fallback `general`. If top two niches within 20%: `domain=mixed`, use `general` schema. YMYL niches (`health`, `finance-legal`): emit credentials WARNING per registry.
8. **Voice matching:** If `--site-dir` has 3+ articles in the same content directory (blog posts only, not about/landing pages), extract voice profile per `humanization-rules.md` (sentence rhythm, person, formality, patterns). Inconclusive → fall back to default rules with note.
9. **COMPACT mode (EC-WA-11):** If `--length < 800`, activate COMPACT: collapse research + outline into single phase, skip competitor analysis, FAQ generation, voice matching, lighter review.

Print SETUP block: Topic, Language, Tone, Length, Format, Site-dir, Domain (niche/mixed/unknown), Voice (profile/inconclusive/skipped), Web search, Mode, Batch.

---

## Phase 1 -- Research

**COMPACT mode:** Orchestrator performs a single focused web search + brief fact gathering. Skip agents and competitor analysis. Proceed to Phase 2.

**STANDARD mode:** Orchestrator performs all web searches first (agents do NOT search), then dispatches 3 parallel agents per `env-compat.md`:

| Agent | Instructions | Input | Output |
|-------|-------------|-------|--------|
| Topic Researcher | `agents/topic-researcher.md` | topic, web results, --lang | Fact sheet with citations |
| Persona Generator | `agents/persona-generator.md` | topic, --audience, web results | 3-5 personas + questions |
| Competitor Analyst | `agents/competitor-analyst.md` | topic, --keyword, web results, site inventory | Gaps + angle recommendations |

All agents: model sonnet, type Explore (read-only). Cursor/Antigravity: execute sequentially yourself.

**Web search unavailable (EC-WA-01):** Degrade to user-context only. Agents work with available project context and general knowledge. Tag all output: `research_limited: true`.

**Conflicting sources (EC-WA-03):** Tag conflicts as `[CONFLICT]` in fact sheet. Phase 4 must resolve or exclude.

Wait for all agents. Merge into:
- Structured fact sheet (cited sources, `[CONFLICT]` tags)
- Persona questions (3-5 perspectives)
- Competitor gap analysis

---

## Phase 2 -- Outline

Generate outline using STORM pattern: derive sections from persona questions, not generic templates.

1. Map each persona question to a potential section or subsection
2. Assign research facts to outline sections
3. Self-critique: check for logical flow, missing perspectives, redundancy
4. **Approval gate (EC-WA-08):**
   - Interactive: present outline for approval. Max 3 revision rounds. After 3 rejections: prompt for manual outline or abandon.
   - Async: auto-approve after 1 self-revision with `[AUTO-DECISION: outline-approved]`.

5. **Snippet targeting:** Classify each H2 by query type: "What is X" → paragraph snippet (40-60 word answer block), "How to X" → ordered list snippet, "X vs Y" → table snippet. Use niche defaults from `domain-profile-registry.md` as starting point; override per H2.
6. **H2 question words (G10):** Prefer What/How/Why question-word headings for informational topics.
7. **FAQ candidates:** Collect answerable questions from persona output + competitor gaps. If 3+ questions + informational intent + >800 words: plan FAQ section at article end. Skip FAQ for `marketing`/`ecommerce`/`personal-brand` niches unless explicitly requested.

Output: numbered outline with mapped fact references, snippet classification per H2, and FAQ candidate list.

---

## Phase 3 -- Draft

**This phase runs INLINE (no sub-agent).** The orchestrator drafts section-by-section in the main context.

For each section:
1. Feed: section outline + mapped facts + summary of previous sections
2. **Strip banned vocabulary from research (EC-WA-10):** Before injecting fact summaries, remove any hard-banned words from the research text.
3. Draft the section using research facts (not model memory)
4. **Continuity check (EC-WA-04):** For articles >3000 words, verify terminology consistency and cross-references between sections after each segment.

**Technical articles (EC-WA-05):** If topic references the current project, dispatch a Code Explorer sub-agent (read `../../skills/brainstorm/agents/code-explorer.md` instructions) to extract real API surface. Inject verified code context into the fact sheet before drafting.

**Language awareness (EC-WA-06):** For non-English output, apply language-specific register, morphological variants in SEO, and locale-appropriate banned vocabulary from the resolved `banned-vocabulary/languages/<lang>.md` file.

5. **Humanization rules:** Apply ALL constraints from `humanization-rules.md` during drafting: sentence variation (fragments + long sentences, max 3 consecutive medium), contractions, parenthetical asides, rhetorical questions, first-person references, hedging transitions, entity grounding, structural asymmetry. If voice profile available: match person, formality, rhythm.
6. **GEO constraints:** BLUF per H2 section — first sentence ≤30 words, answer-first, no throat-clearing (G9). Section cap 300 words between headings (G6). Snippet format per H2 classification from Phase 2. Stats and volatile practical facts must remain traceable to the fact sheet (G11).
   - Attribution should support the prose, not dominate it.
   - Do not start consecutive paragraphs with `Według X (2025)` / `According to X`.
   - Use a hard source-name budget: the same full institution/source name should appear no more than once per section and no more than 3 times in the whole article body, excluding a compact `## Źródła` section.
   - Use access-date markers such as `(odczyt: kwiecień 2026)` only for volatile operational facts: pricing, opening hours, transport, access rules, ticketing, or policy.
   - Stable historical or descriptive facts should usually stay sourced in the fact sheet / JSON output, not with repeated inline lead-ins.
   - The fact sheet is internal. Do not serialize it into the public article as a narrated research appendix.
   - Do not append a wide `Źródła wykorzystane...` block or any process-heavy bibliography.
   - End public articles with a compact `## Źródła` section unless the host project explicitly forbids visible sources.
   - In `## Źródła`, keep 3-6 grouped bullets max. Use source title + link only. Group repeated institutions into one bullet, e.g. `- **APSARA National Authority:** [Beng Mealea](...), [Restoration update](...)`.
   - Do not leave repeated institutions as separate one-line bullets if they can be grouped cleanly.
   - Prefer practical information-carrying sections over polished narrative scene-setting. If the article needs more depth, add concrete subtopics, lists, comparisons, route notes, or FAQ answers before adding a glossy intro paragraph.
7. **TL;DR block:** For practical/service-intent articles (visa, prices, tickets, transport, rules, logistics, how-to, checklists), add a short `## W skrócie` block immediately after the italic lead and before the first image or H2. Keep 3-5 bullets max. Skip it for essay-like, cultural, or historical narratives where it adds no speed value.
8. **FAQ section:** If FAQ candidates from Phase 2 passed quality gate (3+ research-backed questions, >800 words, informational intent): draft FAQ section at article end. Each answer traces to fact sheet. Skip if `research_limited` and no PAA data.
9. **Ending discipline:** Do not add a generic `Na koniec` / `Podsumowanie` section unless it contributes new synthesis in 1-2 short paragraphs. If it only repeats the article, omit it.

Use these exact output shapes when applicable:

```md
## W skrócie
- [Najważniejsza decyzja / odpowiedź]
- [Najważniejszy wymóg / koszt / limit]
- [Najważniejsza opcja / wyjątek]
- [Najważniejszy warunek praktyczny]
```

```md
## Źródła
- **[Instytucja / grupa źródeł]:** [Tytuł 1](...), [Tytuł 2](...)
- **[Instytucja / grupa źródeł]:** [Tytuł 3](...)
- **[Instytucja / grupa źródeł]:** [Tytuł 4](...)
```

Never output `## Źródła` as an ungrouped flat list when multiple bullets share the same institution.

After all sections + FAQ are drafted, assemble the complete article.

---

## Phase 4 -- Review

### 4.1 Anti-Slop Review

Dispatch the anti-slop-reviewer agent per `env-compat.md`:

```
Agent: Anti-Slop Reviewer
  model: sonnet
  type: Explore (read-only)
  instructions: [read agents/anti-slop-reviewer.md]
  input: complete draft, banned-vocabulary/core.md, banned-vocabulary/languages/<resolved-lang>.md, --tone value
  output: hard violations (CRITICAL), soft violations (tone-dependent), burstiness report
```

This agent has NO memory of the drafting process. It sees only the output text plus the shared rules and active language list.

Anti-slop review applies to human-facing prose only. Do not treat frontmatter keys, file paths, URLs, image names, JSON-LD/schema, code, or raw source lists as banned-vocabulary violations unless the task explicitly asks to review those zones as prose.

Fix all hard-ban violations. Fix soft-ban violations per tone rules. Burstiness warnings: fix if 3+ consecutive same-range sentences.

### 4.2 Domain Sensitivity (EC-WA-07)

If topic is medical, legal, or financial AND `--tone` is `casual` or `marketing`: emit `WARNING: Casual tone on [domain] topic. Consider --tone technical or --tone formal. Proceeding as requested.` Surface risk, do not override user.

### 4.3 Cross-Model Adversarial Review

Run: `adversarial-review --json --mode article --files "[draft path]"` (fallback: `--json --mode audit` with WARNING). If not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`. CRITICAL → fix. WARNING → fix if localized. INFO → ignore. If the script returns `status: "timeout"` or exit `124`, record `Adversarial review: skipped (timeout)` and continue without blocking publication.

---

## Phase 5 -- SEO + Output

### 5.1 SEO Pass

1. **Keyword placement (PQ6):** Ensure primary keyword appears in title, H1, first 100 words, and at least 2 H2s
2. **Meta tags (PQ7):** Generate `title` (50-60 chars) and `description` (150-160 chars) with primary keyword
3. **Schema (PQ8):** Domain-aware JSON-LD per `domain-profile-registry.md`. Use `@type` array when multiple types apply (e.g., `["BlogPosting", "Recipe"]` for recipe-food). Include `@id`, `isPartOf` (Organization), `datePublished`, and a modification date only when the local schema clearly supports such a field. YMYL niches: add author credentials schema. Framework injection: `astro-mdx` → component placeholder, `hugo` → shortcode hint, `nextjs-mdx` → inline JSON-LD.
4. **FAQ Schema:** If FAQ section present, auto-append FAQPage JSON-LD with all Q&A pairs.
5. **OG Tags:** Generate `og:title`, `og:description`, `og:type: article`, `og:image` in frontmatter only if the local schema clearly supports those fields. Otherwise inherit layout-level OG behavior and note `OG: inherited-from-layout` in the output/report.
6. **Internal links (PQ9):** Suggest 2-5 per 1000 words. If `--site-dir`: validate via Glob. Unverified: tag `[UNVERIFIED LINK]`
7. **Language-aware SEO (EC-WA-06):** For non-English, use morphological keyword variants and locale-appropriate schema

### 5.2 Frontmatter

- If `--site-dir`: use the schema/config detected in Phase 0 as the hard gate. Populate only fields that are clearly allowed. If OG or modification-date fields are layout-managed or unsupported, do not add them to frontmatter; record that they are inherited or unchanged.
- Else: standard YAML frontmatter (title, description, date, author, tags, keywords).
- If `research_limited`: add `research_limited: true` to frontmatter.

### 5.3 Format Output

| Format | Action |
|--------|--------|
| `md` | Plain markdown with YAML frontmatter |
| `astro-mdx` | MDX with Astro component imports, `.mdx` extension |
| `hugo` | Hugo frontmatter (TOML or YAML per site convention), shortcode hints |
| `nextjs-mdx` | MDX with Next.js metadata exports |

Unsupported format (EC-WA-09): fall back to `md` with note in output.

### 5.4 Save File

- `--site-dir`: write to `{site-dir}/YYYY-MM-DD-{slug}.{ext}`
- Default: write to `output/articles/YYYY-MM-DD-{slug}.{ext}`
- `--batch-mode (EC-WA-12)`: cache competitor/domain data to `memory/write-article-cache-{date}.json`. NOTES field includes `batch:{N}` (sequence number).

### 5.5 JSON Output

Write `article-output-schema.md`-conformant JSON alongside the article:
- `output/articles/YYYY-MM-DD-{slug}.json` (or `{site-dir}/...`)
- Includes research stats, quality scores, SEO data

---

### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check -> structured questions -> TSV emit -> markdown append.
This step is MANDATORY — do not skip it. Write the retro BEFORE the terminal report below.

## ARTICLE COMPLETE

```
ARTICLE COMPLETE
-----
Topic: [topic]
Words: [N] | Language: [lang] | Tone: [tone]
Format: [format] | Output: [file path]
Research: [N] sources, [N] facts used / [N] available [| research_limited]
Quality: hard violations [N], soft violations [N], burstiness [score]
Adversarial: [PASS | WARN | FAIL]
Domain: [niche] | Schema: [type(s)] | FAQ: [N items | none]
SEO: keyword "[kw]", meta OK, OG OK [| internal links: N verified / N suggested]
Humanization: [voice matched | rules only | skipped]

Run: <ISO-8601-Z>	write-article	<project>	-	-	<VERDICT>	-	<DURATION>	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
-----
```

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

**VERDICT:** `PASS` (article delivered), `WARN` (delivered with research_limited or unresolved warnings), `FAIL` (adversarial review blockers unresolved), `BLOCKED` (missing required files), `ABORTED` (user cancelled or topic abandoned after EC-WA-08 cap).

**DURATION:** `standard` or `compact` (mode label).

**NOTES:** `[MODE] topic summary` (max 80 chars). Batch mode: append `batch:N`.

Next steps: `zuvo:content-expand [file]` | `zuvo:seo-audit` | `zuvo:ship`
