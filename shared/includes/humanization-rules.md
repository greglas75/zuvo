# Humanization Rules

> Shared include consumed by `write-article` Phase 3 (drafting) and optionally `content-expand` Phase 4 (rewriting). Makes AI-generated prose harder to detect as machine-written by increasing perplexity and burstiness.

## Why This Exists

AI detectors measure two signals: **perplexity** (how predictable each token is — AI text is too predictable) and **burstiness** (variance in sentence length — AI text is too uniform). These rules target both signals.

## Always-Active Rules (no `--site-dir` required)

Apply ALL of these during drafting. They are constraints, not suggestions.

### Sentence Variation
- Include fragment sentences (<8 words). "Wrong." / "Exactly." / "Not quite." as standalone sentences are good.
- Include long flowing sentences (>30 words) that build and release tension.
- **Max 3 consecutive medium-length sentences** (15-25 words). After 3, force a short or long one.
- Never start 2+ consecutive sentences with the same word.

### Contractions
- Use contractions throughout: don't, can't, it's, won't, they'll, we've, that's.
- AI defaults to "do not", "cannot", "it is" — this is a strong detection signal.
- Exception: `--tone formal` reduces contraction density (every 3rd sentence can be uncontracted).

### Structural Disruption
- **Parenthetical asides:** 1+ per 500 words. "(which, honestly, nobody does)" / "(at least in our experience)"
- **Rhetorical questions:** 1+ per 1000 words. Mid-paragraph, not just as section headers.
- **First-person references:** 1+ per article. "we found", "in our testing", "I'd argue".
- **Hedging transitions:** Use "but", "although", "that said", "to be fair" — NOT "Furthermore", "Moreover", "Additionally".

### Entity Grounding
- Every section should reference at least one specific: version number, date, tool name, person, or organization.
- "axe-core 4.10" not "accessibility tools". "Chrome 126" not "modern browsers". "WebAIM's 2025 study" not "research shows".
- Specific entities are low-probability tokens that spike perplexity in the right direction.

### Structural Asymmetry
- Vary section lengths. One 2-paragraph section followed by a 6-paragraph section is more human than three 4-paragraph sections.
- Vary paragraph lengths within sections. One-sentence paragraphs are fine. So are 5-sentence paragraphs.
- No uniform pattern: 3 bullets, then prose, then 1 bullet, then a long paragraph.

### Citation Cadence
- Do not open consecutive paragraphs with source-led formulas such as "According to X", "Według X", or "UNESCO states".
- In body prose, explicit source lead-ins should usually appear no more than once per section unless the section is directly comparing sources.
- Treat source naming as a budget, not a flourish: the same full institution/source name should usually appear no more than once per section and no more than 3 times in the whole article body, excluding a compact `## Źródła` section.
- Access-date markers such as "(odczyt: kwiecień 2026)" are for volatile facts only: hours, pricing, routes, tickets, access rules, policy, or other frequently changing operational details.
- Stable historical, descriptive, or interpretive facts usually do not need inline access dates in the body. Keep the source in the fact sheet or JSON/report output instead.
- After the first full mention in a section, prefer a shorter functional reference (`oficjalny opis`, `operator biletów`, `muzeum`, `lokalne dane`) or no inline source mention at all if the fact is stable and already grounded in the fact sheet.
- The fact sheet is an internal research artifact. Do not "show your work" in the article by repeatedly naming sources just to prove research happened.
- By default, do not add a visible research appendix such as `## Źródła wykorzystane przy aktualizacji`, `## Źródła i daty faktów`, or similar process-heavy headings.
- Public-facing articles should normally end with a compact visible `## Źródła` section unless the host project explicitly forbids visible sources.
- Keep `## Źródła` compact: 3-6 bullets/groups max, title + link only, no sentence-long explanations of what each source was used for.
- Visible sources should be grouped whenever the same institution or source family appears more than once. Preferred format: `- **APSARA National Authority:** [Beng Mealea](...), [Restoration update](...)`.
- Do not output bare process lists such as `APSARA National Authority: historia, architektura, godziny...`; if the source is public, link it. If no reliable public link is available, keep the label short and do not narrate the research process.

### TL;DR Placement
- For practical, service-intent, regulatory, ticketing, pricing, transport, visa, or other "answer in 10 seconds" articles, add a short `## W skrócie` block immediately after the italic lead.
- Place `## W skrócie` before the first image/caption and before the first thematic H2.
- Keep it to 3-5 bullets max. One bullet = one decision or fact.
- Use `## W skrócie` to answer the user's likely first questions fast; do not turn it into a second introduction.
- Skip `## W skrócie` for purely narrative, historical, cultural, or essay-like articles where the block would feel artificial.

Preferred markdown skeleton:

```md
## W skrócie
- [Najważniejsza odpowiedź]
- [Najważniejszy wymóg / koszt]
- [Najważniejsza opcja / wyjątek]
- [Najważniejszy warunek praktyczny]
```

```md
## Źródła
- **[Instytucja / grupa źródeł]:** [Tytuł 1](...), [Tytuł 2](...)
- **[Instytucja / grupa źródeł]:** [Tytuł 3](...)
```

### Ending Discipline
- Do not append a generic epilogue like `## Na koniec` unless it adds genuinely new synthesis or a useful final distinction.
- Avoid "soft landing" conclusions that simply restate the whole article in slightly different words.
- On legacy/travel/editorial articles, it is usually better to end on the last strong section or FAQ than to add a manufactured closing block.

### Expansion Bias
- When extending an existing article, prefer practical expansion blocks over glossy narrative re-intros.
- Safer additions: concise practical H2s, specific lists, local comparisons, route/context notes, update blocks, and FAQ placed at the end.
- Higher-risk additions: polished magazine-style intros, generic lifestyle framing, "if you are looking for..." paragraphs, and prose whose main job is to sound smooth rather than add information.
- Do not replace a solid existing lead just to make the article feel more modern. Add coverage after it unless the lead is objectively wrong, stale, unsafe, or broken.

### Anti-Parallel
- AI defaults to three-clause parallel structures: "It reads X, traces Y, and evaluates Z."
- Break these up: "It reads X. From there it traces Y — and evaluates Z if both branches apply."
- Repetition of the same word is MORE human than synonymizing: "The tool catches it. The tool catches it because..." beats "The tool catches it. The instrument detects it because..."

## Voice Matching (requires `--site-dir`)

When `--site-dir` is available and contains 3+ articles in the same content directory:

### Extraction (Phase 0)
Read 3-5 recent articles. Extract:

```json
{
  "avg_sentence_length": "short|medium|long",
  "sentence_length_variance": "low|medium|high",
  "person": "first|second|third|mixed",
  "contraction_density": "none|sparse|frequent",
  "punctuation_style": "minimal|standard|expressive",
  "formality": "casual|neutral|formal",
  "distinctive_patterns": ["list of notable stylistic traits"]
}
```

### Application (Phase 3)
- Match the extracted `person` preference (if existing articles use "you" heavily, new article should too)
- Match `formality` level (if existing articles are casual with slang, don't write formally)
- Match `contraction_density` (if existing articles avoid contractions, reduce them)
- Apply `distinctive_patterns` where natural (if author uses lots of parenthetical asides, include more)

### Inconclusive Profile
If articles vary too much (different authors, different styles), print: "Voice profile: inconclusive (articles too varied). Using default humanization rules only."
