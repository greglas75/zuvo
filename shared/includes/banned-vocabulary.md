# Banned Vocabulary — Anti-Slop Enforcement

> Shared include consumed by `write-article` and `content-optimize`. Defines hard-banned and soft-banned AI vocabulary per language, plus burstiness heuristics.

## Hard Ban (all tones, all languages — ALWAYS block)

These words/phrases are statistically anomalous in AI output and virtually never appear in natural human writing. Any occurrence is a CRITICAL finding.

### English

- delve
- tapestry
- it's worth noting
- in the realm of
- game-changer
- as an AI
- certainly!
- I'd be happy to
- multifaceted
- embark

### Polish

- z pewnością warto zauważyć
- w dzisiejszym świecie
- nie da się ukryć, że
- jak powszechnie wiadomo
- w kontekście powyższego

## Soft Ban (tone-dependent)

Soft-banned words are flagged differently based on `--tone`. Check the tone matrix below.

### English

Furthermore, Moreover, comprehensive, robust, leverage, utilize, seamless, cutting-edge, unlock, empower, streamline, foster, nuanced, landscape, In conclusion, In today's world, It is important to note, plays a crucial role, are not limited to, at the end of the day, needless to say

### Polish

Ponadto, Co więcej, Podsumowując, Warto podkreślić, Nie ulega wątpliwości, Kluczowym aspektem jest, W dzisiejszych czasach, Nie sposób nie zauważyć

## Tone Matrix

| Tone | Hard ban | Soft ban behavior |
|------|----------|-------------------|
| `casual` | CRITICAL (block) | CRITICAL (block) — strictest |
| `marketing` | CRITICAL (block) | CRITICAL (block) — strictest |
| `technical` | CRITICAL (block) | WARNING — "Furthermore", "Moreover", "In conclusion" allowed; rest flagged |
| `formal` | CRITICAL (block) | WARNING only — all soft bans are advisories, not blockers |

## Burstiness Rules (qualitative — LLM-assessed, not exact counting)

AI writing defaults to uniform ~18-word sentences with subject-verb-object structure. Human writing varies dramatically. The reviewer checks for:

- **Sentence length monotony:** Flag 3+ consecutive sentences of similar length (all medium, all short, or all long). Mix is required.
- **Sentence opener repetition:** Flag 2+ consecutive sentences starting with the same word or phrase pattern.
- **Transition abuse:** Flag sections where every sentence begins with a transition word (However, Additionally, Moreover, Furthermore).
- **Missing variety:** Flag sections with zero short sentences (<8 words) or zero long sentences (>25 words). Good prose mixes both.

These are heuristic assessments by the reviewer agent, not deterministic word counts. The reviewer should read the text naturally and flag sections that "feel" monotonous or robotic.

## G12 Anti-Patterns (from geo-check-registry)

### Throat-Clearing Openers (after H2/H3 headings)
In today's rapidly evolving, When it comes to, It goes without saying, As we all know, In the world of, It is widely recognized that, One cannot overstate, In an era where, As technology continues to

**Rule:** First sentence after any H2/H3 must NOT match these patterns. Start with the answer, not the windup.

### Generic Superlatives
best, leading, top, premier, #1, world-class, cutting-edge, state-of-the-art, industry-leading, unparalleled, unmatched, best-in-class

**Rule:** Flag unless backed by a verifiable source ("rated #1 by G2 in Q3 2025" is OK; "#1 solution" alone is not).

### Keyword Density
Same exact phrase appearing more than 3 times per 500 words = keyword stuffing. Flag as WARNING.

## How to Apply

### In write-article (Phase 4 — Review)

1. The Anti-Slop Reviewer agent reads this file and the draft
2. Checks every sentence against the hard ban list
3. Checks every sentence against the soft ban list using the active `--tone`
4. Assesses burstiness qualitatively
5. Reports findings with line references

### In content-optimize (Phase 1 — Analyze)

1. The Prose Quality Scorer agent reads this file and the input article
2. PQ15 = hard-banned vocabulary count (CRITICAL if >0)
3. PQ16 = soft-banned vocabulary count (severity per tone matrix)
4. PQ17 = AI-pattern sentence openers (MEDIUM)

### In research summaries (write-article Phase 1 → Phase 3)

Before research summaries are injected into the draft phase, the orchestrator strips any hard-banned or soft-banned vocabulary from the summaries. The ban applies to the OUTPUT regardless of where vocabulary originated.
