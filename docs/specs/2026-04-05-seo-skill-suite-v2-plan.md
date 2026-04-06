# Implementation Plan: SEO Skill Suite v2

**Spec:** /Users/greglas/DEV/zuvo-plugin/docs/specs/2026-04-05-seo-skill-suite-v2-spec.md
**spec_id:** 2026-04-05-seo-skill-suite-v2-1442
**plan_revision:** 1
**status:** Approved
**Created:** 2026-04-05
**Approved:** 2026-04-05
**Tasks:** 14
**Estimated complexity:** 9 standard, 5 complex

## Architecture Summary

- The SEO suite is a contract-driven subsystem spanning four layers: shared contracts under `/Users/greglas/DEV/zuvo-plugin/shared/includes`, audit prompt orchestration under `/Users/greglas/DEV/zuvo-plugin/skills/seo-audit`, fix orchestration under `/Users/greglas/DEV/zuvo-plugin/skills/seo-fix`, and website consumers under `/Users/greglas/DEV/zuvo-plugin/website/skills`.
- `/Users/greglas/DEV/zuvo-plugin/skills/seo-audit/SKILL.md` owns stack detection, mode dispatch, live verification, scoring, and output shape. Its behavior is delegated to three prompt files: `/Users/greglas/DEV/zuvo-plugin/skills/seo-audit/agents/seo-technical.md`, `/Users/greglas/DEV/zuvo-plugin/skills/seo-audit/agents/seo-content.md`, and `/Users/greglas/DEV/zuvo-plugin/skills/seo-audit/agents/seo-assets.md`.
- `/Users/greglas/DEV/zuvo-plugin/skills/seo-fix/SKILL.md` consumes audit JSON and `/Users/greglas/DEV/zuvo-plugin/shared/includes/seo-fix-registry.md` to produce fix reports and mutate files safely.
- `/Users/greglas/DEV/zuvo-plugin/shared/includes/seo-check-registry.md`, `/Users/greglas/DEV/zuvo-plugin/shared/includes/seo-fix-registry.md`, `/Users/greglas/DEV/zuvo-plugin/shared/includes/audit-output-schema.md`, and `/Users/greglas/DEV/zuvo-plugin/shared/includes/fix-output-schema.md` form the canonical machine-readable contract layer.
- `/Users/greglas/DEV/zuvo-plugin/website/skills/seo-audit.yaml` and `/Users/greglas/DEV/zuvo-plugin/website/skills/seo-fix.yaml` are downstream marketing consumers. They currently drift from the prompt and registry reality, so the redesign introduces explicit validation rather than trusting manual sync.
- Existing validator precedent exists in `/Users/greglas/DEV/zuvo-plugin/scripts/validate-skill-pages.sh`. No normal test framework exists in the repo, so this plan uses shell-based contract tests under `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/`.

## Technical Decisions

- Keep `seo-audit` and `seo-fix` as separate public skills. The redesign happens through stronger shared contracts, not through merging workflows.
- Introduce foundational shared registries first: bot registry and page-profile registry. All later prompt and schema changes read from them.
- Preserve JSON compatibility via optional schema `v1.1` fields only. No required-field reset in this iteration.
- Use shell-based contract tests because the repo has no existing `*.test.*` or `*.spec.*` suite and no package scripts in `/Users/greglas/DEV/zuvo-plugin/package.json`.
- Reuse the style of `/Users/greglas/DEV/zuvo-plugin/scripts/validate-skill-pages.sh` for deterministic validators and executable tests. Avoid adding a new dependency or test runner.
- Treat website YAML as validated narrative copy, not generated output. The validator enforces counts, enums, framework support, and verdict vocabulary.
- Split the large prompt files by ownership and risk: technical, content, assets, audit orchestrator, and fix orchestrator each get separate tasks.

## Quality Strategy

- Test approach: shell contract tests plus executable validators. Every production artifact in this plan gets a matching shell test file under `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/`.
- Activated CQ gates:
  - `CQ3`: validator/test scripts must handle missing files and unsupported states explicitly.
  - `CQ8`: shell checks must fail loudly with actionable errors, not silent false passes.
  - `CQ14`: remove duplicated bot lists, llms rules, verdict names, and website counts from prompt text by centralizing them in registries.
  - `CQ19`: audit and fix JSON schemas must remain aligned with their producing/consuming prompts.
- Highest-risk files are `/Users/greglas/DEV/zuvo-plugin/skills/seo-audit/SKILL.md`, `/Users/greglas/DEV/zuvo-plugin/skills/seo-fix/SKILL.md`, and the three audit agent prompt files because they are large and currently mix implementation contract with product copy.
- Because no CodeSift or churn tooling is available, risk mitigation is structural: small tasks, one subsystem concern per task, and a final validator pass across all touched contracts.

## Task Breakdown

### Task 1: Add shell test helpers and the canonical AI bot registry
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/assert.sh, /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-bot-registry.sh, /Users/greglas/DEV/zuvo-plugin/shared/includes/seo-bot-registry.md
**Complexity:** standard
**Dependencies:** none
**Execution routing:** default implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-bot-registry.sh` to fail while `/Users/greglas/DEV/zuvo-plugin/shared/includes/seo-bot-registry.md` is missing and to assert:
  - exactly 15 bot rows exist
  - each row declares tier and default recommendation
  - training, retrieval/search, and user-proxy classes all appear
- [ ] GREEN: Add `/Users/greglas/DEV/zuvo-plugin/shared/includes/seo-bot-registry.md` plus `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/assert.sh` helper functions used by this and later shell tests.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-bot-registry.sh`
  Expected: `PASS: seo-bot-registry`
- [ ] Acceptance: 5
- [ ] Commit: `add canonical AI bot registry and shell test helpers`

### Task 2: Add the page-profile registry and its contract test
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-page-profiles.sh, /Users/greglas/DEV/zuvo-plugin/shared/includes/seo-page-profile-registry.md
**Complexity:** standard
**Dependencies:** Task 1
**Execution routing:** default implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-page-profiles.sh` to fail until the profile registry exists and to assert:
  - profiles `marketing`, `docs`, `blog`, `ecommerce`, and `app-shell` are present
  - each profile defines thin-content handling, answer-first handling, E-E-A-T handling, and advisory/scored behavior
- [ ] GREEN: Add `/Users/greglas/DEV/zuvo-plugin/shared/includes/seo-page-profile-registry.md` with per-profile heuristic rules used by D9/D10.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-page-profiles.sh`
  Expected: `PASS: seo-page-profile-registry`
- [ ] Acceptance: 7
- [ ] Commit: `add SEO page profile registry and coverage checks`

### Task 3: Normalize the audit check registry into the real execution contract
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-check-registry.sh, /Users/greglas/DEV/zuvo-plugin/shared/includes/seo-check-registry.md
**Complexity:** standard
**Dependencies:** Task 1, Task 2
**Execution routing:** default implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-check-registry.sh` to fail until `/Users/greglas/DEV/zuvo-plugin/shared/includes/seo-check-registry.md` declares:
  - `owner_agent`, `layer`, `enforcement`, and `evidence_mode` metadata
  - separate llms checks for proposal compliance vs best practice
  - new checks for render diff, bot matrix, Cloudflare override risk, robots sub-risks, stale sitemap quality, schema duplication, and OG type consistency
- [ ] GREEN: Refactor `/Users/greglas/DEV/zuvo-plugin/shared/includes/seo-check-registry.md` so every emitted audit check is canonical and owned by exactly one agent.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-check-registry.sh`
  Expected: `PASS: seo-check-registry`
- [ ] Acceptance: 1, 2, 3, 4
- [ ] Commit: `normalize SEO check registry into the audit execution contract`

### Task 4: Expand the fix registry into a deterministic remediation contract
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-fix-registry.sh, /Users/greglas/DEV/zuvo-plugin/shared/includes/seo-fix-registry.md
**Complexity:** complex
**Dependencies:** Task 1
**Execution routing:** deep implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-fix-registry.sh` to fail until the fix registry defines:
  - `schema-cleanup`
  - explicit metadata for `robots-fix`, `headers-add`, `json-ld-add`, `meta-og-add`, and `sitemap-add`
  - estimated time/effort bands
  - manual verification hooks and network override caveats
- [ ] GREEN: Refactor `/Users/greglas/DEV/zuvo-plugin/shared/includes/seo-fix-registry.md` so fix entries define richer params, validation, risk notes, Cloudflare/network caveats, and `schema-cleanup`.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-fix-registry.sh`
  Expected: `PASS: seo-fix-registry`
- [ ] Acceptance: 9, 10, 11, 12, 13
- [ ] Commit: `expand SEO fix registry into a deterministic remediation contract`

### Task 5: Upgrade audit and fix schema docs to v1.1 with contract tests
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-json-schemas.sh, /Users/greglas/DEV/zuvo-plugin/shared/includes/audit-output-schema.md, /Users/greglas/DEV/zuvo-plugin/shared/includes/fix-output-schema.md
**Complexity:** standard
**Dependencies:** Task 1, Task 4
**Execution routing:** default implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-json-schemas.sh` to fail until both schema docs advertise optional `v1.1` fields for:
  - bot matrix and render diff
  - estimated time and manual checks
  - policy notes / risk notes
  - backward-compatible optional additions only
- [ ] GREEN: Update the audit and fix schema docs to `v1.1` and document the new optional fields with examples.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-json-schemas.sh`
  Expected: `PASS: seo schema docs v1.1`
- [ ] Acceptance: 15
- [ ] Commit: `document SEO audit and fix schema v1.1 optional fields`

### Task 6: Refactor the technical audit agent around the bot contract
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-audit-technical-contract.sh, /Users/greglas/DEV/zuvo-plugin/skills/seo-audit/agents/seo-technical.md
**Complexity:** complex
**Dependencies:** Task 1, Task 3, Task 5
**Execution routing:** deep implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-audit-technical-contract.sh` to fail until the technical agent:
  - loads the bot registry
  - evaluates the full bot matrix
  - checks deep robots risks for `/*.js*`, `/*.pdf$`, and `/*.feed*`
  - warns about Cloudflare/network overrides
- [ ] GREEN: Update `/Users/greglas/DEV/zuvo-plugin/skills/seo-audit/agents/seo-technical.md` to read the shared contracts and emit canonical D5 evidence for both static and live modes.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-audit-technical-contract.sh`
  Expected: `PASS: seo-audit technical contract`
- [ ] Acceptance: 2, 5
- [ ] Commit: `refactor technical SEO audit agent around canonical bot policy rules`

### Task 7: Refactor the content audit agent around page profiles
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-audit-content-contract.sh, /Users/greglas/DEV/zuvo-plugin/skills/seo-audit/agents/seo-content.md
**Complexity:** complex
**Dependencies:** Task 2, Task 3
**Execution routing:** deep implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-audit-content-contract.sh` to fail until the content agent:
  - loads the page-profile registry
  - separates llms proposal compliance from llms best-practice quality
  - can downgrade D9/D10 checks to advisory or `N/A`
  - documents advisory scaffolds for out-of-scope content fixes
- [ ] GREEN: Update `/Users/greglas/DEV/zuvo-plugin/skills/seo-audit/agents/seo-content.md` so D9/D10 become site-profile-aware and less brittle.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-audit-content-contract.sh`
  Expected: `PASS: seo-audit content contract`
- [ ] Acceptance: 4, 7, 8
- [ ] Commit: `refactor content SEO audit agent around page profiles`

### Task 8: Refactor the assets audit agent for render-aware schema and OG checks
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-audit-assets-contract.sh, /Users/greglas/DEV/zuvo-plugin/skills/seo-audit/agents/seo-assets.md
**Complexity:** complex
**Dependencies:** Task 3, Task 4, Task 5
**Execution routing:** deep implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-audit-assets-contract.sh` to fail until the assets agent:
  - formalizes source-vs-render evidence
  - routes schema clutter toward `schema-cleanup`
  - validates `og:type` by page class
- [ ] GREEN: Update `/Users/greglas/DEV/zuvo-plugin/skills/seo-audit/agents/seo-assets.md` to cover structured-data duplication/spam and render-aware evidence.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-audit-assets-contract.sh`
  Expected: `PASS: seo-audit assets contract`
- [ ] Acceptance: 6, 11, 12
- [ ] Commit: `refactor assets SEO audit agent for render-aware schema checks`

### Task 9: Repair seo-audit orchestration, flags, and report contract
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-seo-audit-skill-contract.sh, /Users/greglas/DEV/zuvo-plugin/skills/seo-audit/SKILL.md
**Complexity:** complex
**Dependencies:** Task 1, Task 2, Task 3, Task 5, Task 6, Task 7, Task 8
**Execution routing:** deep implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-seo-audit-skill-contract.sh` to fail until `/Users/greglas/DEV/zuvo-plugin/skills/seo-audit/SKILL.md`:
  - dispatches owners correctly for `--quick` and `--geo`
  - documents `--profile`
  - exposes `Strengths`, `Bot Policy Matrix`, `Source vs Render Diff`, `Content Table`, and `Fix Coverage Summary`
  - documents sequential fallback when agent dispatch is unavailable
- [ ] GREEN: Refactor `/Users/greglas/DEV/zuvo-plugin/skills/seo-audit/SKILL.md` to align the orchestration with the updated registries and output contract.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-seo-audit-skill-contract.sh`
  Expected: `PASS: seo-audit skill contract`
- [ ] Acceptance: 1, 2, 5, 6, 7, 8, 17
- [ ] Commit: `repair seo-audit orchestration and report semantics`

### Task 10: Deepen seo-fix remediation semantics and verdict vocabulary
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-seo-fix-skill-contract.sh, /Users/greglas/DEV/zuvo-plugin/skills/seo-fix/SKILL.md
**Complexity:** complex
**Dependencies:** Task 1, Task 4, Task 5
**Execution routing:** deep implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-seo-fix-skill-contract.sh` to fail until `/Users/greglas/DEV/zuvo-plugin/skills/seo-fix/SKILL.md`:
  - supports `schema-cleanup`
  - documents Cloudflare/network override `NEEDS_REVIEW`
  - includes estimated time, manual checks, and policy notes in report semantics
  - documents sequential fallback when agent dispatch is unavailable
- [ ] GREEN: Refactor `/Users/greglas/DEV/zuvo-plugin/skills/seo-fix/SKILL.md` to consume the richer fix registry and emit the expanded report semantics.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-seo-fix-skill-contract.sh`
  Expected: `PASS: seo-fix skill contract`
- [ ] Acceptance: 9, 10, 11, 12, 13, 17
- [ ] Commit: `deepen seo-fix remediation semantics and verdict vocabulary`

### Task 11: Add the dedicated SEO suite validator
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-validator-script.sh, /Users/greglas/DEV/zuvo-plugin/scripts/validate-seo-skill-contracts.sh
**Complexity:** standard
**Dependencies:** Task 1, Task 2, Task 3, Task 4, Task 5
**Execution routing:** default implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-validator-script.sh` to fail until the validator script exists and checks:
  - registry presence
  - website claim drift
  - schema field presence
  - shared enum vocabulary consistency
- [ ] GREEN: Add `/Users/greglas/DEV/zuvo-plugin/scripts/validate-seo-skill-contracts.sh` reusing the shell style of `/Users/greglas/DEV/zuvo-plugin/scripts/validate-skill-pages.sh`.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-validator-script.sh`
  Expected: `PASS: seo suite validator script`
- [ ] Acceptance: 16
- [ ] Commit: `add validator for SEO suite contract drift`

### Task 12: Align the seo-audit website page with the new contract
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-website-seo-audit.sh, /Users/greglas/DEV/zuvo-plugin/website/skills/seo-audit.yaml
**Complexity:** standard
**Dependencies:** Task 1, Task 2, Task 3, Task 5, Task 9, Task 11
**Execution routing:** default implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-website-seo-audit.sh` to fail until the page:
  - matches the actual flags and output sections
  - uses aligned terminology for D8/D13
  - advertises the new bot/render/content coverage honestly
- [ ] GREEN: Update `/Users/greglas/DEV/zuvo-plugin/website/skills/seo-audit.yaml` to match the redesigned audit contract and output surface.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-website-seo-audit.sh`
  Expected: `PASS: website seo-audit contract`
- [ ] Acceptance: 14, 16
- [ ] Commit: `align seo-audit website copy with redesigned contract`

### Task 13: Align the seo-fix website page with the new contract
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-website-seo-fix.sh, /Users/greglas/DEV/zuvo-plugin/website/skills/seo-fix.yaml
**Complexity:** standard
**Dependencies:** Task 4, Task 5, Task 10, Task 11
**Execution routing:** default implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-website-seo-fix.sh` to fail until the page:
  - stops overclaiming fix counts
  - reflects the richer verdict vocabulary
  - mentions `schema-cleanup`, manual checks, and estimated time
- [ ] GREEN: Update `/Users/greglas/DEV/zuvo-plugin/website/skills/seo-fix.yaml` to match the redesigned fix contract.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-website-seo-fix.sh`
  Expected: `PASS: website seo-fix contract`
- [ ] Acceptance: 13, 14, 16
- [ ] Commit: `align seo-fix website copy with redesigned contract`

### Task 14: Run final end-to-end suite validation
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-suite-e2e.sh
**Complexity:** standard
**Dependencies:** Task 1, Task 2, Task 3, Task 4, Task 5, Task 6, Task 7, Task 8, Task 9, Task 10, Task 11, Task 12, Task 13
**Execution routing:** default implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-suite-e2e.sh` to fail until all previous contract tests and the validator pass in one run.
- [ ] GREEN: Wire the end-to-end script to call each `tests/seo-suite/test-*.sh` script and finally run `/Users/greglas/DEV/zuvo-plugin/scripts/validate-seo-skill-contracts.sh`. Do not change production files in this task; this task only proves the suite is internally consistent after Tasks 1-13.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-suite-e2e.sh`
  Expected: final line `PASS: seo skill suite end-to-end`
- [ ] Acceptance: 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17
- [ ] Commit: `validate SEO skill suite end to end`
