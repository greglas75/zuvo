# Prose Quality Registry — PQ1-PQ18

> Canonical check definitions for content quality scoring. Consumed by `content-optimize` and `write-article` review phases.

## Check Registry

| ID | Dimension | Check | Severity |
|----|-----------|-------|----------|
| PQ1 | Readability | FK grade level appropriate for target audience (LLM-estimated) | MEDIUM |
| PQ2 | Readability | Sentence length variety — burstiness per `banned-vocabulary.md` rules | MEDIUM |
| PQ3 | Engagement | Hook present in first 2 sentences of article | HIGH |
| PQ4 | Engagement | Specificity ratio — concrete examples/numbers vs abstract claims | HIGH |
| PQ5 | Engagement | Tension/release pattern per section (poses question, builds, resolves) | LOW |
| PQ6 | SEO | Primary keyword present in title + H1 + first 100 words | HIGH |
| PQ7 | SEO | Meta description 150-160 characters, includes primary keyword naturally | MEDIUM |
| PQ8 | SEO | BlogPosting or Article JSON-LD schema present in frontmatter/output | MEDIUM |
| PQ9 | SEO | Internal links: 2-5 contextual links per 1000 words (validated if site-dir) | LOW |
| PQ10 | Structure | Heading hierarchy — no skipped levels (H1→H3 without H2) | HIGH |
| PQ11 | Structure | Section balance — no section more than 2x the average section length | MEDIUM |
| PQ12 | Structure | Intro paragraph + conclusion/CTA present | HIGH |
| PQ13 | Authority | E-E-A-T signals: first-hand experience markers, expertise demonstration | MEDIUM |
| PQ14 | Authority | Cited sources or concrete data points (not vague "studies show") | HIGH |
| PQ15 | Anti-slop | Hard-banned vocabulary count — zero tolerance per `banned-vocabulary.md` | CRITICAL |
| PQ16 | Anti-slop | Soft-banned vocabulary — tone-dependent per `banned-vocabulary.md` matrix | MEDIUM |
| PQ17 | Anti-slop | AI-pattern sentence openers (repetitive transitions, uniform structure) | MEDIUM |
| PQ18 | Freshness | References or statistics dated >2 years flagged for review | LOW |

## Scoring

Each check scores 0 (fail) or 1 (pass). Dimension scores are the percentage of passed checks within the dimension.

**Composite score:** Weighted average of dimension scores:
- Readability: 15%
- Engagement: 20%
- SEO: 15%
- Structure: 15%
- Authority: 20%
- Anti-slop: 15%

**Tier mapping:**
- A: 90-100
- B: 75-89
- C: 50-74
- D: 0-49

**Critical gate:** PQ15 (hard-banned vocabulary) = 0 → caps tier at D regardless of composite score.

## Dimension Grouping

| Dimension | Checks | Weight |
|-----------|--------|--------|
| Readability | PQ1, PQ2 | 15% |
| Engagement | PQ3, PQ4, PQ5 | 20% |
| SEO | PQ6, PQ7, PQ8, PQ9 | 15% |
| Structure | PQ10, PQ11, PQ12 | 15% |
| Authority | PQ13, PQ14 | 20% |
| Anti-slop | PQ15, PQ16, PQ17 | 15% |
| Freshness | PQ18 | (modifier only — not in composite) |

**Note:** PQ18 (Freshness) does not affect the composite score. It is reported as a standalone modifier: `Freshness: OK` or `Freshness: N stale references flagged`.
