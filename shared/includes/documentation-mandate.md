# Documentation Mandate

**Purpose:** Every run that LANDS production code — `execute`, `build`, `refactor`, `ship` — MUST create or update documentation reflecting what changed. A 20-task feature merging with zero docs is a defect, not a default. This closes the recurring failure where the pipeline finishes, the retro/curate steps run, but no human-readable doc ever appears.

**Why a mandate and not prose:** the doc step was always *implied* (knowledge-curate, release-docs exist) but never *enforced*, so under time pressure it is silently skipped — the same drift pattern as the telemetry/review/no-pause gaps. This include makes documentation a **completion-gate item + a Final Summary section**: skipping it is a visible, deliberate, gated decision, never a silent omission.

---

## What to document (decide by change shape)

Pick the target(s) that match what actually changed — proportional to the change, never zero:

| Change shape | Documentation target |
|--------------|----------------------|
| New user-facing feature / capability | `README` section or a `docs/<feature>.md` page (what it does + how to use it) **+ CHANGELOG entry** |
| New / changed API endpoint or public contract | API reference (`docs/api*`, OpenAPI, or inline contract doc) **+ CHANGELOG entry** |
| New module / subsystem | Architecture note or onboarding/README update (where it lives, what it owns) |
| Behavior / ops change (feature flag, env var, migration, config) | Runbook + `.env.example` / migration notes; CHANGELOG entry |
| Bugfix only | CHANGELOG entry (+ an inline comment if the fix is non-obvious) |

**Minimum floor:** even the smallest change updates the project's CHANGELOG (or its equivalent — release notes, a "Recent changes" doc section). There is no run that lands code and touches zero docs.

---

## How to produce it (proportional to size)

- **Substantial change (multi-file feature, new API, new subsystem):** dispatch `zuvo:docs update <target>` (README/API/runbook/onboarding) or `zuvo:release-docs` (diff-driven sync). Do NOT hand-wave — the docs skill reads the actual diff.
- **Small change (1–5 files, bugfix):** edit the relevant doc section inline + add the CHANGELOG line. A dispatch is overkill here.
- Write from the ACTUAL change (the diff / the landed tasks), not from intent. Doc that contradicts the code is worse than no doc.

---

## The only valid "no docs" path

If the change genuinely needs no documentation — a pure internal refactor with **no** behavior, API, contract, config, or public-surface change — that is allowed, but it MUST be **declared**, never silently skipped:

```
[DOC: N/A — internal-only, no behavior/API/contract/config change]
```

A bare skip with no `[DOC: ...]` line is the defect. "I'll document it later" is not a valid N/A.

---

## Enforcement (wire into the calling skill)

1. **Completion Gate Check** — add the item:
   `[ ] Documentation created/updated for the landed change (or explicit [DOC: N/A — <reason>])`
   An unchecked box with no declared N/A means the run is INCOMPLETE — loop back and write the doc before emitting the completion block.

2. **Final Summary** — add a `### Documentation` section listing every doc file created/updated (path + one-line what), or the `[DOC: N/A — <reason>]` line. The user reads ONE place to see what was documented.

3. **Proportionality rule:** scale the doc to the change. A 20-task feature → real feature doc + API ref + CHANGELOG. A one-line bugfix → CHANGELOG line. Neither bloat the trivial nor skip the substantial.
