# Humanization Rules

> Shared include consumed by `write-article` Phase 3 (drafting) and optionally `content-optimize` Phase 4 (rewriting). Makes AI-generated prose harder to detect as machine-written by increasing perplexity and burstiness.

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
