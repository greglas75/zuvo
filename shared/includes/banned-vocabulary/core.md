# Banned Vocabulary Core

> Shared anti-slop rules loaded for every language before the active language file.

## Coverage

Dedicated language files currently cover 32 languages:

- European: `bg`, `cs`, `da`, `de`, `el`, `en`, `es`, `et`, `fi`, `fr`, `hr`, `hu`, `it`, `lt`, `lv`, `nl`, `no`, `pl`, `pt`, `ro`, `sk`, `sl`, `sr`, `sv`, `uk`
- Additional: `ar`, `id`, `ja`, `ko`, `th`, `vi`, `zh`

## Coverage Model

- `en` and `pl` remain the most mature lists.
- All languages added beyond `en` and `pl` use conservative seed lists built around the same high-signal AI cliches already enforced in English and Polish: "as an AI", "it's worth noting", "in today's world", "in the realm/domain of", and generic transition-heavy scaffolding like "furthermore" / "in conclusion".
- Extend local lists when corpus evidence shows recurring language-specific slop patterns.
- Hard bans are precision-first and intentionally shorter. Soft bans carry most multilingual coverage and are expected to be larger.
- The cross-language contract lives in `./banned-vocabulary/registry.tsv` and is enforced by `scripts/validate-banned-vocabulary.sh`.

## Matching Guidance

- Match case-insensitively.
- Treat sentence-initial capitalization as the same phrase.
- For inflected languages, flag close morphological variants and common punctuation variants, not just exact string matches.
- For Arabic, Chinese, Japanese, Korean, Thai, and Vietnamese, also flag visually obvious close variants even when spacing or punctuation changes.
- If the active language is unsupported, fall back to English hard-ban + soft-ban logic and still apply G12 heuristics.

## Language Resolution

- Normalize incoming language tags to lowercase base code before file lookup.
- Region tags fall back to the base file: `pt-BR -> pt`, `es-MX -> es`, `zh-CN -> zh`.
- Script tags also fall back to the base file unless a dedicated file is added later: `sr-Latn -> sr`, `zh-Hans -> zh`, `zh-Hant -> zh`.
- If the requested file is unavailable, load `languages/en.md` and emit `WARNING: banned-vocabulary fallback -> en`.

## Tone Matrix

| Tone | Hard ban | Soft ban behavior |
|------|----------|-------------------|
| `casual` | CRITICAL (block) | CRITICAL (block) — strictest |
| `marketing` | CRITICAL (block) | CRITICAL (block) — strictest |
| `technical` | CRITICAL (block) | WARNING — sparse connector-style equivalents of "furthermore / moreover / in conclusion" may pass; the rest remain flagged |
| `formal` | CRITICAL (block) | WARNING only — all soft bans are advisories, not blockers |

## Burstiness Rules (qualitative — LLM-assessed, not exact counting)

AI writing defaults to uniform ~18-word sentences with subject-verb-object structure. Human writing varies dramatically. The reviewer checks for:

- **Sentence length monotony:** Flag 3+ consecutive sentences of similar length (all medium, all short, or all long). Mix is required.
- **Sentence opener repetition:** Flag 2+ consecutive sentences starting with the same word or phrase pattern.
- **Transition abuse:** Flag sections where every sentence begins with a transition word.
- **Missing variety:** Flag sections with zero short sentences (<8 words) or zero long sentences (>25 words). Good prose mixes both.

These are heuristic assessments by the reviewer agent, not deterministic word counts. The reviewer should read the text naturally and flag sections that "feel" monotonous or robotic.

## G12 Anti-Patterns (from geo-check-registry)

### Throat-Clearing Openers (after H2/H3 headings)

In today's rapidly evolving, When it comes to, It goes without saying, As we all know, In the world of, It is widely recognized that, One cannot overstate, In an era where, As technology continues to

**Rule:** First sentence after any H2/H3 must NOT match these patterns. Start with the answer, not the windup.

**Cross-language guidance:** For supported non-English languages, treat direct equivalents of "nowadays / in today's world / when it comes to / it goes without saying" as the same anti-pattern even if the exact English phrase is absent.

### Generic Superlatives

best, leading, top, premier, #1, world-class, cutting-edge, state-of-the-art, industry-leading, unparalleled, unmatched, best-in-class

**Rule:** Flag unless backed by a verifiable source ("rated #1 by G2 in Q3 2025" is OK; "#1 solution" alone is not).

### Keyword Density

Same exact phrase appearing more than 3 times per 500 words = keyword stuffing. Flag as WARNING.

## How to Apply

### In write-article (Phase 4 — Review)

1. Read `core.md`
2. Read the active language file
3. Check every sentence against hard bans
4. Check every sentence against soft bans using the active `--tone`
5. Assess burstiness qualitatively
6. Report findings with line references

### In content-expand (Phase 0 / Phase 2.5)

1. Read `core.md`
2. Read the active language file
3. PQ15 = hard-banned vocabulary count (CRITICAL if >0)
4. PQ16 = soft-banned vocabulary count (severity per tone matrix)
5. PQ17 = AI-pattern sentence openers (MEDIUM)

### In research summaries (write-article Phase 1 -> Phase 3)

Before research summaries are injected into the draft phase, the orchestrator strips any hard-banned or soft-banned vocabulary from the summaries. The ban applies to the output regardless of where vocabulary originated.
