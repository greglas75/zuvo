# Severity Vocabulary

> Canonical mapping between skill-specific severity vocabularies. Load this file when interpreting findings across skills or when a finding from one skill feeds into another.

## Canonical Scale

Four severity levels, ordered by impact:

| Level | Meaning | Action |
|-------|---------|--------|
| **S1 — Blocking** | Production bug, security hole, data loss, critical gate failure | Must fix before merge/ship. No exceptions. |
| **S2 — Significant** | Maintenance risk, reliability concern, non-critical gate failure | Should fix before merge. Merge discouraged without fix. |
| **S3 — Minor** | Style, readability, non-functional improvement | Merge OK as-is. Fix if convenient. |
| **S4 — Informational** | Observation, alternative approach, no action required | Note only. No fix expected. |

## Skill-to-Canonical Mapping

| Skill | Skill vocabulary | S1 Blocking | S2 Significant | S3 Minor | S4 Info |
|-------|-----------------|-------------|----------------|----------|---------|
| `/review` | MUST-FIX / RECOMMENDED / NIT | MUST-FIX | RECOMMENDED | NIT | — |
| `/code-audit` | Tier A / B / C / D | Tier D | Tier C | Tier B | Tier A |
| `/security-audit` | CRITICAL / HIGH / MEDIUM / LOW | CRITICAL | HIGH | MEDIUM | LOW |
| `/ship` review-light | BLOCKER / WARNING | BLOCKER | WARNING | — | — |
| adversarial loop | CRITICAL / WARNING / INFO | CRITICAL | WARNING | — | INFO |
| `/architecture` | 0-3 score | 0 (Critical) | 1 (Needs work) | 2 (Minor gaps) | 3 (Good) |
| `/a11y-audit` | Critical gate FAIL / grade | Gate FAIL | Grade C/FAIL | Grade B | Grade A |
| `/seo-audit` | Critical gate / grade | CG FAIL | Grade C/FAIL | Grade B | Grade A |
| CQ/Q gates | FAIL / PASS | Critical gate = 0 | Score < threshold | Score >= threshold | N/A |

## When to Use This Mapping

**Cross-skill finding inheritance:** When one skill consumes findings from another (e.g., `/ship` runs `/review` then reads its findings), use this table to normalize severity before applying fix policy.

**Backlog persistence:** When writing findings to `memory/backlog.md`, always record the canonical level (S1-S4) alongside the skill-specific label. This enables cross-skill queries like "show all S1 findings regardless of source skill."

**User-facing reports:** When presenting findings from multiple skills in one session, prefer the canonical vocabulary to avoid confusing the user with MUST-FIX + CRITICAL + BLOCKER + Tier D for the same severity concept.

## Rules

1. **Mapping is fixed.** Skills do not redefine which of their labels maps to which canonical level. The table above is the source of truth.
2. **Higher severity wins.** If the same finding is reported by two skills at different severities, use the higher canonical level.
3. **Canonical labels are optional in skill output.** Skills continue using their own vocabulary. The canonical mapping is for cross-skill interpretation, not for replacing skill-specific output.
4. **New skills** that introduce severity labels must add a row to this table before release.
