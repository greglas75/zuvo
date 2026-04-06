# Implementation Plan: World-Class SEO Skill Suite

**Spec:** /Users/greglas/DEV/zuvo-plugin/docs/specs/2026-04-05-seo-skill-suite-spec.md
**spec_id:** 2026-04-05-seo-skill-suite-1442
**plan_revision:** 2
**status:** Approved
**Created:** 2026-04-05
**Tasks:** 10
**Estimated complexity:** 6 standard, 4 complex

## Architecture Summary

- The suite is a contract-driven subsystem with five layers: shared registries, shared schemas, audit agent prompts, audit/fix orchestrators, and website marketing YAML.
- `/Users/greglas/DEV/zuvo-plugin/shared/includes` is the trust boundary. `seo-check-registry.md`, `seo-fix-registry.md`, `audit-output-schema.md`, `fix-output-schema.md`, `seo-bot-registry.md`, and `seo-page-profile-registry.md` must agree before the public skills can be trusted.
- `/Users/greglas/DEV/zuvo-plugin/skills/seo-audit/agents/seo-technical.md`, `/Users/greglas/DEV/zuvo-plugin/skills/seo-audit/agents/seo-content.md`, and `/Users/greglas/DEV/zuvo-plugin/skills/seo-audit/agents/seo-assets.md` are the execution surface for the registries. They already contain partial redesign work and need contract tests plus normalization, not a greenfield rewrite.
- `/Users/greglas/DEV/zuvo-plugin/skills/seo-audit/SKILL.md` and `/Users/greglas/DEV/zuvo-plugin/skills/seo-fix/SKILL.md` are the public orchestration layer. The remaining work is dispatch correctness, verdict semantics, and output/report alignment.
- `/Users/greglas/DEV/zuvo-plugin/website/skills/seo-audit.yaml` and `/Users/greglas/DEV/zuvo-plugin/website/skills/seo-fix.yaml` are validated downstream consumers, not sources of truth.

## Technical Decisions

- Keep `seo-audit` and `seo-fix` as separate public skills. The redesign happens through stronger shared contracts and stricter validation, not through merging them.
- Use shell-based contract tests under `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/`. The repo has no existing application test runner for this subsystem, so executable shell contracts are the safest practical fit.
- Treat existing dirty changes in shared includes and audit agents as the working baseline. Execution should finish and normalize them, not discard them.
- Preserve JSON compatibility through schema `v1.1` optional fields only. No required field reset.
- Add a dedicated validator script for contract drift and run it from an end-to-end shell suite at the end.

## Quality Strategy

- Existing automated coverage is absent. Verification will rely on shell contract tests, grep-based assertions, and the validator script.
- Activated CQ gates:
  - `CQ3`: validator/test scripts must handle missing files and unsupported states explicitly.
  - `CQ8`: validation failures must exit non-zero with actionable errors.
  - `CQ14`: duplicated bot lists, llms semantics, and website counts must be removed or subordinated to shared registries.
  - `CQ19`: audit and fix schema docs, prompts, and consuming skills must stay aligned.
- Highest-risk files are `/Users/greglas/DEV/zuvo-plugin/skills/seo-audit/SKILL.md`, `/Users/greglas/DEV/zuvo-plugin/skills/seo-fix/SKILL.md`, and the three audit agent prompt files because they are large and cross-coupled.

## Task Breakdown

### Task 1: Add shell test helpers and the shared-contract smoke test
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/assert.sh, /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-shared-contracts.sh
**Complexity:** standard
**Dependencies:** none
**Execution routing:** default implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-shared-contracts.sh` so it currently fails by checking for the validator script and for missing shared invariants such as website alignment and runtime wiring.
- [ ] GREEN: Add `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/assert.sh` with reusable shell assertions and keep `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-shared-contracts.sh` as the baseline smoke test for later tasks.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-shared-contracts.sh`
  Expected: non-zero exit before Task 2, with a specific missing-contract message
- [ ] Acceptance: AC1, AC5, AC15
- [ ] Commit: `add SEO suite shell test helpers and baseline smoke test`

### Task 2: Normalize the shared audit registries
**Files:** /Users/greglas/DEV/zuvo-plugin/shared/includes/seo-bot-registry.md, /Users/greglas/DEV/zuvo-plugin/shared/includes/seo-page-profile-registry.md, /Users/greglas/DEV/zuvo-plugin/shared/includes/seo-check-registry.md
**Complexity:** standard
**Dependencies:** Task 1
**Execution routing:** default implementation tier

- [ ] RED: Make `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-shared-contracts.sh` fail on shared audit contract gaps: canonical bot inventory, page profiles, check ownership, enforcement classes, and llms split semantics.
- [ ] GREEN: Normalize the three shared audit registries so the bot matrix, page profiles, and check registry are consistent with the approved spec and with each other.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-shared-contracts.sh`
  Expected: shared-registry assertions pass; validator-related assertions still fail
- [ ] Acceptance: AC2, AC3, AC4, AC5
- [ ] Commit: `normalize shared SEO audit registries`

### Task 3: Normalize the shared fix and schema contracts
**Files:** /Users/greglas/DEV/zuvo-plugin/shared/includes/seo-fix-registry.md, /Users/greglas/DEV/zuvo-plugin/shared/includes/audit-output-schema.md, /Users/greglas/DEV/zuvo-plugin/shared/includes/fix-output-schema.md
**Complexity:** standard
**Dependencies:** Task 1
**Execution routing:** default implementation tier

- [ ] RED: Extend `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-shared-contracts.sh` so it fails on missing `schema-cleanup`, `manual_checks`, `network_override_risk`, `eta_minutes`, and optional `v1.1` fields.
- [ ] GREEN: Normalize the fix registry and both schema docs so they advertise the full deterministic remediation contract and backward-compatible JSON `v1.1` fields.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-shared-contracts.sh`
  Expected: shared-contract smoke test reports PASS for registries and schemas; validator/website/runtime checks may still fail
- [ ] Acceptance: AC7, AC8, AC9, AC10, AC11, AC12, AC13, AC16
- [ ] Commit: `normalize shared SEO fix and schema contracts`

### Task 4: Add audit-agent contract tests and finish the technical agent
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-audit-technical-contract.sh, /Users/greglas/DEV/zuvo-plugin/skills/seo-audit/agents/seo-technical.md
**Complexity:** complex
**Dependencies:** Task 2, Task 3
**Execution routing:** deep implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-audit-technical-contract.sh` to fail until the technical agent loads the bot registry, emits a bot matrix, checks deep robots risks, and handles Cloudflare/network override uncertainty.
- [ ] GREEN: Finish `/Users/greglas/DEV/zuvo-plugin/skills/seo-audit/agents/seo-technical.md` so D5/D11 are fully wired to the shared contracts and emit canonical evidence fields.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-audit-technical-contract.sh`
  Expected: `PASS: seo-audit technical contract`
- [ ] Acceptance: AC2, AC5, AC6
- [ ] Commit: `finish technical SEO audit agent contract wiring`

### Task 5: Add audit-agent contract tests and finish the content and assets agents
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-audit-content-assets-contract.sh, /Users/greglas/DEV/zuvo-plugin/skills/seo-audit/agents/seo-content.md, /Users/greglas/DEV/zuvo-plugin/skills/seo-audit/agents/seo-assets.md
**Complexity:** complex
**Dependencies:** Task 2, Task 3
**Execution routing:** deep implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-audit-content-assets-contract.sh` to fail until the content agent uses page profiles and llms best-practice semantics, and the assets agent emits source-vs-render evidence, schema cleanup routing, and page-class-aware `og:type` rules.
- [ ] GREEN: Finish `/Users/greglas/DEV/zuvo-plugin/skills/seo-audit/agents/seo-content.md` and `/Users/greglas/DEV/zuvo-plugin/skills/seo-audit/agents/seo-assets.md` so they match the shared contracts and approved spec semantics.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-audit-content-assets-contract.sh`
  Expected: `PASS: seo-audit content/assets contract`
- [ ] Acceptance: AC4, AC10, AC11, AC14
- [ ] Commit: `finish content and assets SEO audit agent contract wiring`

### Task 6: Repair seo-audit orchestration and report semantics
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-seo-audit-skill-contract.sh, /Users/greglas/DEV/zuvo-plugin/skills/seo-audit/SKILL.md
**Complexity:** complex
**Dependencies:** Task 4, Task 5
**Execution routing:** deep implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-seo-audit-skill-contract.sh` to fail until `--quick` and `--geo` dispatch correctly, only blocking checks control `FAIL`/`PROVISIONAL`, and the new report sections/flags are documented.
- [ ] GREEN: Finish `/Users/greglas/DEV/zuvo-plugin/skills/seo-audit/SKILL.md` so orchestration, flags, report sections, and JSON output semantics align with the registries and spec.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-seo-audit-skill-contract.sh`
  Expected: `PASS: seo-audit skill contract`
- [ ] Acceptance: AC1, AC3, AC6
- [ ] Commit: `repair seo-audit orchestration and report contract`

### Task 7: Repair seo-fix remediation semantics and report vocabulary
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-seo-fix-skill-contract.sh, /Users/greglas/DEV/zuvo-plugin/skills/seo-fix/SKILL.md
**Complexity:** complex
**Dependencies:** Task 3
**Execution routing:** deep implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-seo-fix-skill-contract.sh` to fail until `seo-fix` supports `schema-cleanup`, network-override-aware `NEEDS_REVIEW`, manual checks, ETA fields, and advisory content scaffolds.
- [ ] GREEN: Finish `/Users/greglas/DEV/zuvo-plugin/skills/seo-fix/SKILL.md` so it consumes the richer fix registry and emits the expanded report semantics.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-seo-fix-skill-contract.sh`
  Expected: `PASS: seo-fix skill contract`
- [ ] Acceptance: AC7, AC8, AC9, AC10, AC11, AC12, AC13, AC14
- [ ] Commit: `repair seo-fix remediation semantics and report vocabulary`

### Task 8: Add the dedicated SEO suite validator
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-validator-script.sh, /Users/greglas/DEV/zuvo-plugin/scripts/validate-seo-skill-contracts.sh
**Complexity:** standard
**Dependencies:** Task 2, Task 3, Task 6, Task 7
**Execution routing:** default implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-validator-script.sh` to fail until a suite validator exists and checks registry presence, schema fields, website claim drift, and shared vocabulary consistency.
- [ ] GREEN: Add `/Users/greglas/DEV/zuvo-plugin/scripts/validate-seo-skill-contracts.sh` in the same style as `scripts/validate-skill-pages.sh`, and make the validator test prove both syntax and behavior.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-validator-script.sh`
  Expected: `PASS: seo suite validator script`
- [ ] Acceptance: AC15, AC16
- [ ] Commit: `add SEO suite contract validator`

### Task 9: Align the seo-audit and seo-fix website pages
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-website-seo-contracts.sh, /Users/greglas/DEV/zuvo-plugin/website/skills/seo-audit.yaml, /Users/greglas/DEV/zuvo-plugin/website/skills/seo-fix.yaml
**Complexity:** standard
**Dependencies:** Task 6, Task 7, Task 8
**Execution routing:** default implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-website-seo-contracts.sh` to fail until both website pages stop overclaiming, use aligned verdicts/counts, and advertise the new report/fix semantics accurately.
- [ ] GREEN: Update `/Users/greglas/DEV/zuvo-plugin/website/skills/seo-audit.yaml` and `/Users/greglas/DEV/zuvo-plugin/website/skills/seo-fix.yaml` to match the real suite contract.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-website-seo-contracts.sh`
  Expected: `PASS: website SEO skill contracts`
- [ ] Acceptance: AC15
- [ ] Commit: `align SEO skill website pages with validated contract`

### Task 10: Run final suite validation end to end
**Files:** /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-suite-e2e.sh
**Complexity:** standard
**Dependencies:** Task 4, Task 5, Task 6, Task 7, Task 8, Task 9
**Execution routing:** default implementation tier

- [ ] RED: Create `/Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-suite-e2e.sh` to fail until every contract test plus `scripts/validate-seo-skill-contracts.sh` passes in one run.
- [ ] GREEN: Wire the end-to-end script to run each `tests/seo-suite/test-*.sh` file and then the validator. Do not change production files in this task.
- [ ] Verify: `bash /Users/greglas/DEV/zuvo-plugin/tests/seo-suite/test-suite-e2e.sh`
  Expected: final line `PASS: seo skill suite end to end`
- [ ] Acceptance: AC1, AC2, AC3, AC4, AC5, AC6, AC7, AC8, AC9, AC10, AC11, AC12, AC13, AC14, AC15, AC16
- [ ] Commit: `validate SEO skill suite end to end`
