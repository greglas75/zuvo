# Zuvo Skill Web-Research Sweep — 2026-06-25

> Real **web** research for **all 54 skills** (workflow `zuvo-skill-web-research-throttled`). Per skill: one agent searched the web for comparable external tools/standards/best-practices and extracted findings **each requiring a real `source_url` + a verbatim quote** (anti-hallucination); then an independent verifier (**worker ≠ judge**) re-read our skill AND **re-fetched the source URL itself**, marking `confirmed` / `unreachable` / `contradicted`, and rejecting hallucinated / already-present / vague.

> Throttled (2 skills at a time, sequential web calls) after a first attempt hit a server rate-limit wall — burst of 54 parallel web agents → 0/54. The throttle is the root-cause fix; this run was 54/54 with zero web failures.

> **Honesty:** *verified ≠ implemented.* Each item is a sourced, reviewer-ready proposal. `[src:confirmed]` = the verifier re-fetched the page and it supports the claim; `[src:unreachable]` = could not re-fetch (kept, NOT refuted — needs human re-check); `[src:contradicted]` = page loaded but did NOT support it. Where the proposer over-claimed a number/detail, the verifier's **CAVEAT** is surfaced inline.


---


## At a glance

- **194 verified improvements** across 54 skills (~3.6/skill); 10 rejected by the verifier.
- **Leverage:** 90 high · 96 medium · 8 low
- **Effort:** 51 S · 126 M · 17 L
- **Source integrity (verifier re-fetched each URL):** **188 confirmed** · 5 unreachable · 1 contradicted
- **~22 findings' notes flag a verifier CAVEAT** (proposer over-claimed a number/detail the source didn't support); the 10 cleanly-parseable ones are surfaced inline as ⚠️ below — none silently kept.


## Source-integrity exceptions (human re-check these)

Everything else was independently confirmed. These are the only non-`confirmed` items:

- **[unreachable] `test-audit` — No dedicated flaky-test / non-determinism dimension despite it being the dominant test-quality failure mode** — https://www.sciencedirect.com/science/article/pii/S0164121223002327
- **[unreachable] `test-audit` — No suite-level order-dependency / shared-state-leak detection** — https://www.sciencedirect.com/science/article/pii/S0164121223002327
- **[unreachable] `refactor` — No explicit dry-run/preview-then-diff-review step before applying a mechanical transform** — https://www.sitepoint.com/getting-started-with-codemods/
- **[unreachable] `release-docs` — Compute a 0-100 staleness/drift score instead of a binary changed/unchanged decision** — https://mcpmarket.com/tools/skills/documentation-drift-detector
- **[contradicted] `review` — Report and trend a first-class false-positive rate as a review-quality metric** — https://www.devtoolsacademy.com/blog/state-of-ai-code-review-tools-2025/
- **[unreachable] `retro` — Action items lack owner / due date / priority / status structure** — https://itleadershiphub.com/best-practices/blameless-post-incident-review/

_Plus ~22 verifier notes flag an over-claimed detail; the 10 cleanly-parseable ones are surfaced inline as ⚠️ CAVEAT in the per-skill section below (every caveat is preserved in each finding's note field)._


## Quick wins — high leverage, small effort (17)

| Skill | External source | Improvement | Proposed change |
|---|---|---|---|
| `api-audit` | RFC 9457 (IETF) — Problem Details for H… | D4 (Error Standardization) does not check conformance to RFC 9457 pro… | Add an explicit D4 sub-check: 'RFC 9457 conformance — error responses use application/problem+json with type/title/status/detail/instance members.' S… |
| `backlog` | Lean/SAFe WSJF (Weighted Shortest Job F… | Replace the homegrown (Impact+Risk)x(6-Effort) score with an economic… | Offer a WSJF mode in prioritize: CostOfDelay = (business value + time-criticality + risk-reduction), divided by the new Effort(min) estimate. This ma… |
| `benchmark` | Academic LLM-as-a-judge bias-mitigation… | LLM judges suffer dominant style/verbosity bias the skill never contr… | Add an explicit anti-style-bias instruction to the judge prompt (lines 146-171): 'do not reward markdown formatting or response length; judge only co… |
| `brainstorm` | GitHub Spec Kit (/speckit.analyze detec… | Named vague-adjective ambiguity lint for requirements (fast, scalable… | Add a concrete ambiguity lint to spec-reviewer: a banned-vague-adjective list (fast/scalable/secure/intuitive/robust/performant/user-friendly) that m… |
| `canary` | Flagger (progressive delivery / canary … | Gate on request-success-rate + latency percentile, not just a flat 10… | Add two SLO-style gates to Phase 3 verdict: (a) success-rate = (count of 200 responses / total checks); BROKEN if below a configurable --min-success-… |
| `code-audit` | SARIF 2.1.0 / GitHub code scanning resu… | Map artifactLocation.uri to repo-root-relative paths and severity to … | As part of the SARIF emitter, normalize the file part of each existing file:line citation to a repo-root-relative artifactLocation.uri (git root alre… |
| `content-migration` | Screaming Frog SEO Spider — Compare Cra… | Word-count delta and page-level content-similarity change detection a… | Add a page-level metric to Phase 2: total content word count old vs new with a delta percentage, and raise a WARNING when new < ~80% of old (mirrors … |
| `design` | OpenAI Apps SDK UI Guidelines (accessib… | Make AA contrast and text-resize explicit, named requirements in the … | Add an 'A11y:' line to the Step 6 checkpoint template requiring: stated text/background token pair + measured AA ratio, alt-text strategy for any ima… |
| `design-review` | @lapidist/design-lint (open-source desi… | Emit SARIF (and JSON) so DX/DAP findings surface inline in PRs and CI… | Add a `--format sarif` option (or always emit a .sarif alongside the markdown report) that maps each DX/DAP finding's mandatory `path/to/file.ext:LIN… |
| `env-audit` | gitleaks (secret scanner, git log -p hi… | Concrete full git-history secret scan command for ENV4 (replace vague… | In ENV4 detection, replace the vague 'Git history — Past .env commits' note with a concrete command: run 'gitleaks detect' (full-history scan) or fal… |
| `incident` | Google SRE (Postmortem Culture chapter) | Postmortem is built around a single Root Cause + confidence tier; SRE… | Add a mandatory 'Contributing Factors' subsection to Phase 2 and the postmortem template (lines 483-501), alongside the suspect-commit RCA: enumerate… |
| `mutation-test` | StrykerJS thresholds.break / PIT mutati… | Configurable build-breaking mutation-score threshold (CI gate) | Add a `--break N` flag (and an env default e.g. ZUVO_MUTATION_BREAK). After Phase 4 score calc, if overall score < N, print 'BREAK: mutation score X%… |
| `refactor` | OpenRewrite / Moderne — Lossless Semant… | Symbol-level edits not mandated to be type-aware/LSP-based (Lossless … | At SKILL.md line 480, make type-aware transformation the REQUIRED path for RENAME_MOVE / MOVE / INTRODUCE_INTERFACE: use rename_symbol (or get_type_i… |
| `ship` | git (official git-tag documentation) | Ship creates a lightweight unsigned tag; release-grade tags should be… | Change Phase 4 Step 3 from `git tag v<version>` to an annotated tag `git tag -a v<version> -m "release: v<version>"`, embedding the CHANGELOG section… |
| `test-audit` | tsDetect / testsmells.org (canonical ac… | Canonical tsDetect catalog includes smells our AP list omits (Mystery… | Add the canonical smells our AP1-AP26 catalog omits, mapped to tsDetect names in rules/test-quality-rules.md: AP27 Mystery Guest (test reads real fil… |
| `worktree` | wtp (satococoa/wtp) — .wtp.yml post-cre… | Declarative copy hooks to seed gitignored config (.env) into fresh wo… | Add a CREATE step (after Step 4 dependency setup, before Step 5 baseline) that copies gitignored config files into the new worktree. Detect candidate… |
| `write-article` | GEO: Generative Engine Optimization (Ag… | Weight GEO tactics by measured per-domain effectiveness (Princeton GE… | Add a 'GEO tactic priority' field per niche in domain-profile-registry.md sourced from the paper's per-domain results (factual/law -> Cite Sources fi… |

## Recurring external tools/standards (cross-skill themes)

- **GitHub Spec Kit** → `brainstorm`, `build`, `plan`
- **Screaming Frog SEO Spider** → `content-migration`
- **SARIF 2.1.0** → `code-audit`, `security-audit`
- **Playwright Test Generator** → `write-e2e`
- **Flagger** → `canary`
- **Addy Osmani** → `execute`
- **Patronus AI** → `using-zuvo`
- **SonarQube** → `code-audit`
- **zizmor** → `ci-audit`
- **The Twelve-Factor App** → `env-audit`
- **jtesta** → `infra-audit`
- **OpenSCAP** → `infra-audit`
- **llmstxt.org official specification** → `geo-audit`, `geo-fix`
- **GenOptima GEO Best Practices 2026** → `geo-audit`
- **Vale** → `content-audit`, `write-article`
- **tsDetect** → `fix-tests`, `test-audit`
- **Playwright Best Practices** → `write-e2e`
- **UTRefactor** → `fix-tests`
- **W3C Design Tokens Community Group** → `design`, `design-review`
- **OpenAI Apps SDK UI Guidelines** → `design`
- **DevOps Training Institute** → `deploy`
- **Post-Mortem Best Practices That Actually Drive Change** → `incident`
- **Prospeo** → `leads`
- **CodeRabbit** → `review`
- **Google eng-practices** → `receive-review`
- **release-please** → `ship`
- **Catio** → `backlog`
- **Tokalator** → `context-audit`
- **Anthropic Engineering** → `context-audit`

## Full per-skill detail


### `a11y-audit`  (2 verified, 1 rejected)

- **[H/M · src:confirmed] Skill brands itself 'WCAG 2.2' but omits 6 of the 9 criteria new in WCAG 2.2**  
  _W3C WCAG 2.2 / wcag.com checklist_ — https://www.wcag.com/blog/wcag-2-2-aa-summary-and-checklist-for-website-owners/  
  Add a WCAG-2.2-delta check group across existing dimensions: A2 gets 2.4.11 Focus Not Obscured (detect position:sticky/fixed headers+footers and non-modal dialogs that can overlap a focused element) and 2.4.13 Focus Appearance (focus-ring area/contrast sizing); A2/A7 gets 2.5.7 Dragging Movements (…
- **[H/M · src:confirmed] No baseline / regression-diff mode to catch newly introduced a11y violations**  
  _IBM Equal Access Accessibility Checker (achecker)_ — https://github.com/IBMa/equal-access/blob/master/accessibility-checker/src/README.md  
  Add a baseline mode: persist findings to zuvo/audits/a11y-baseline.json keyed by stable identity (file + WCAG criterion + selector/component), add a --baseline / --since flag that diffs the current run against it and classifies findings as NEW / FIXED / KNOWN, and make the critical-gate FAIL apply …

  _rejected:_ Claims EAA coverage but has no EN 301 549 scan policy (hallucinated-source)

### `agent-benchmark`  (4 verified, 0 rejected)

- **[H/M · src:confirmed] Self-scoring by the benchmark subject is self-preference bias; use a cross-family/blind judge instead**  
  _LLM-as-a-Judge bias literature (Bias in the Loop: Auditing LLM-as-a-Judge for Software Engineering, arXiv 2604.16790)_ — https://arxiv.org/html/2604.16790v1  
  Replace or cross-check the Self-Scoring phase (lines 188-199) with a cross-family judge pass: feed R2/R4 artifacts to a different-family model via adversarial-review.sh in a blind/anonymized rubric-scoring mode, and store both self_score and external_score in agent-benchmark.json. Flag any delta > …
- **[H/M · src:confirmed] Single-run pass@1 is statistically unreliable for stochastic agents; run k samples and report variance/CIs**  
  _Beyond pass@1: A Reliability Science Framework for Long-Horizon LLM Agents (arXiv 2603.29231)_ — https://arxiv.org/pdf/2603.29231  
  Add a --runs N flag (default 1, recommend 3) that repeats Rounds 1-4, then report mean ± stddev (or 90% CI) for each score and timing in agent-benchmark.json and the completion table. Only treat a cross-model score gap as real when CIs do not overlap.
- **[M/S · src:confirmed] Report position/order controls and bias sensitivity alongside the score, not just the raw score**  
  _Self-Preference Bias in LLM Code Judges / SWE judging methodology (arXiv 2604.16790)_ — https://arxiv.org/html/2604.16790v1  
  When using an external judge (finding 1), run it twice with A/B order swapped and report the score delta as a 'bias_sensitivity' field in agent-benchmark.json; surface it in the completion block so a large swing flags an unreliable score rather than a quality signal.
- **[M/M · src:confirmed] Fixed public corpus risks training-data contamination/memorization; add held-out or freshly-generated tasks**  
  _SWE-bench Verified analysis (Groundy); LiveCodeBench contamination-resistant evaluation_ — https://groundy.com/articles/swe-bench-verified-explained-what-the-coding-agent-leaderboard-actually-measures-and-what-it-misses/  
  Add a contamination guard: (a) a --task <spec-file> flag pointing at a private/internal task the user supplies, or (b) a 'fresh' mode that parametrizes the corpus (rename entities, vary requirements) per run. Record a corpus_hash + provenance field ('static_public|private|parametrized') in agent-be…

### `api-audit`  (4 verified, 0 rejected)

- **[H/S · src:confirmed] D4 (Error Standardization) does not check conformance to RFC 9457 problem+json — the named IETF standard**  
  _RFC 9457 (IETF) — Problem Details for HTTP APIs_ — https://www.rfc-editor.org/rfc/rfc9457.html  
  Add an explicit D4 sub-check: 'RFC 9457 conformance — error responses use application/problem+json with type/title/status/detail/instance members.' Score full only when bodies match the canonical model; flag legacy ad-hoc error shapes and RFC 7807-only as partial. Cite the media-type header from pr…
- **[H/M · src:confirmed] No declarative, CI-runnable lint ruleset (Spectral) — D10 governance is prose-only**  
  _Spectral (Stoplight) — OpenAPI/AsyncAPI/Arazzo linter_ — https://github.com/stoplightio/spectral  
  Add a D10 sub-step: when an OpenAPI/AsyncAPI spec is present, run `spectral lint` against the spec (ship a default zuvo ruleset, detect an existing `.spectral.yaml`/`.spectral.json`). Fold violation counts into the D10 evidence ratio and emit the ruleset so the team can wire it into CI. Graceful de…
- **[M/S · src:confirmed] D3 (Pagination) does not encode the cursor-over-offset preference from established API guidelines**  
  _Zalando RESTful API Guidelines (Rule 160)_ — http://opensource.zalando.com/restful-api-guidelines/  
  Extend D3: detect offset/limit vs cursor/keyset patterns; when a list endpoint over a large table uses pure offset pagination, deduct and recommend cursor/keyset, citing Zalando Rule 160. Add a short 'Reference guidelines' note to D3 (Zalando / Google AIP) so scoring is anchored to a published stan…
- **[M/M · src:confirmed] D11 (Contract Stability) is spec-diff only (oasdiff) — no awareness of consumer-driven contract testing (Pact)**  
  _Pact — consumer-driven contract testing_ — https://docs.pact.io/consumer  
  Add a D11 sub-check for multi-consumer/microservice projects: detect Pact (or similar CDC) contract files / provider-verification in the repo. When a provider serves multiple consumers and no consumer contracts exist, flag as a contract-stability gap and recommend adding CDC tests for consumer-spec…

### `architecture`  (5 verified, 0 rejected)

- **[H/L · src:confirmed] Emit runnable architecture fitness functions, not just a point-in-time score**  
  _ArchUnit / Building Evolutionary Architectures (fitness functions)_ — https://www.infoq.com/articles/fitness-functions-architecture/  
  Add an optional output to review mode (e.g. --emit-fitness-functions) that, for each confirmed A1-A3 violation and cycle, generates a stack-appropriate executable rule: ArchUnit/.NET for JVM, dependency-cruiser/eslint-plugin-boundaries for JS/TS, import-linter for Python. The report's 'Recommendati…
- **[M/S · src:confirmed] A failed architecture rule must explain WHY it exists and HOW to fix it (and not over-enforce trivia)**  
  _ArchUnit.NET (.Because()) / Building Evolutionary Architectures 2e_ — https://developersvoice.com/blog/architecture/architectural-fitness-functions-automating-governance/  
  When emitting fitness functions, attach the finding's Risk + Fix text as the rule's rationale/Because clause, and gate emission to foundational boundaries only (A1-A3, cycles) — explicitly NOT cosmetic rules (class names, method length) — per the 'start with the principle, not the tool' guidance, t…
- **[M/M · src:confirmed] Align ADR template with the MADR 4.0 standard and add the Confirmation field**  
  _MADR 4.0 (adr.github.io/madr)_ — https://adr.github.io/madr/  
  Re-key the ADR output (Mode 2, lines 358-398) to MADR 4.0 section names so it interoperates with adr-tools/log4brains, add a 'Confirmation' section (e.g. 'enforced by fitness function X / reviewed at trigger Y' — natural tie-in to Finding 1), and extend front matter from just Deciders to deciders/c…
- **[M/M · src:confirmed] Adopt C4 model levels for the Architecture Map instead of ad-hoc ASCII**  
  _C4 model (c4model.com) / Structurizr_ — https://c4model.com/  
  Restructure the Architecture Map (review Output, line 290) and High-Level Design (design Step 2 / line 417 / output line 465) around C4 levels (at minimum Context + Container, optionally Component), and offer a Structurizr-DSL or Mermaid-C4 code block as the canonical diagram so output is tool-rend…
- **[M/M · src:confirmed] Emit a declarative dependency-cruiser forbidden-rules config as a review deliverable**  
  _dependency-cruiser (sverweij)_ — https://github.com/sverweij/dependency-cruiser/blob/main/doc/rules-reference.md  
  In review mode for JS/TS repos, generate a starter .dependency-cruiser.js with forbidden rules derived from the detected architecture style (e.g. domain not importing infra, no circular deps) plus a pre-commit snippet — turning the report's A2/A3 findings into runnable boundary enforcement.

### `backlog`  (4 verified, 0 rejected)

- **[H/S · src:confirmed] Replace the homegrown (Impact+Risk)x(6-Effort) score with an economic WSJF / Cost-of-Delay prioritization**  
  _Lean/SAFe WSJF (Weighted Shortest Job First)_ — https://www.zigpoll.com/content/how-do-you-prioritize-technical-debt-versus-feature-development-in-your-team's-roadmap  
  Offer a WSJF mode in prioritize: CostOfDelay = (business value + time-criticality + risk-reduction), divided by the new Effort(min) estimate. This makes our ranking defensible against the standard teams already use and lets debt be ranked against features on one axis. Keep the current heuristic as …
- **[H/M · src:confirmed] Estimate per-item remediation TIME, not just severity, and roll up to a single Technical Debt Ratio health grade (A-E)**  
  _SQALE / SonarQube_ — https://docs.sonarsource.com/sonarqube-server/2025.1/user-guide/code-metrics/metrics-definition  
  Add an optional 'Effort(min)' column to the backlog schema (audit skills already know per-rule fix estimates; default a coarse value per severity). In stats, compute a Technical Debt Ratio = sum(effort)/dev-cost and print an A-E grade using SonarQube's bands (A <=5%, B <10%, C <20%, D <50%, E >=50%…
- **[M/S · src:confirmed] Translate the backlog into a dollar/quarter cost to make tech debt visible to non-engineers**  
  _Catio (tech-debt measurement guide)_ — https://www.catio.tech/blog/how-to-measure-technical-debt  
  In stats, once Effort(min) exists, add an optional dollar line: total remediation cost = sum(effort_hours) x $ZUVO_HOURLY_RATE (env-configurable, default e.g. $100/hr). Print '$X to clear backlog' alongside the A-E grade. Cheap to add, high leverage for prioritization conversations.
- **[M/M · src:confirmed] Surface code-churn / hotspot signal in suggest and prioritize, not just static reference counts**  
  _Catio (tech-debt metrics) / SQALE hotspot practice_ — https://www.catio.tech/blog/how-to-measure-technical-debt  
  In prioritize, boost Impact for items whose file shows high churn via CodeSift analyze_hotspots(since_days=90) (fallback: git log --since). In suggest, add a 'Hotspot churn' line ranking the top backlog files by recent churn so batch-fix effort lands where it pays back fastest.

### `benchmark`  (3 verified, 0 rejected)

- **[H/S · src:confirmed] LLM judges suffer dominant style/verbosity bias the skill never controls for**  
  _Academic LLM-as-a-judge bias-mitigation research (arXiv 2604.23178)_ — https://arxiv.org/html/2604.23178  
  Add an explicit anti-style-bias instruction to the judge prompt (lines 146-171): 'do not reward markdown formatting or response length; judge only correctness and completeness'. Record response char-length + formatting-density per provider in the scorecard so reviewers can see whether a high score …
- **[H/L · src:confirmed] Subjective judge scoring overestimates agents vs objective test-execution ground truth**  
  _UTBoost / SWE-bench test-augmentation (arXiv 2506.09289)_ — https://arxiv.org/html/2506.09289  
  Ship a committed reference test suite with each corpus task (FAIL_TO_PASS + PASS_TO_PASS specs under shared/includes/benchmark-corpus/) and execute every provider's Round-1 code against it; report an objective resolution_rate alongside subjective quality. Make resolution the PRIMARY rank key in cor…
- **[M/M · src:confirmed] Single-pass judge with shuffled order is weaker than order-swapped dual scoring**  
  _Position-bias studies + bias-mitigation survey (arXiv 2604.23178)_ — https://arxiv.org/html/2604.23178  
  Add an optional --judge-swap mode (default in corpus mode) that runs the meta-judge twice with reversed provider ordering and averages per-dimension scores; surface a 'position_consistency' metric (how often a provider's rank survived the swap) in the JSON output, and downgrade to a 'low-confidence…
  ⚠️ _CAVEAT:_ same source reports position bias is small (<=0.04) and S1 HARMS adversarial benchmarks (-3 to -13 pp) — so order-swap is not a universal win and the finding overstates the payoff

### `brainstorm`  (4 verified, 0 rejected)

- **[H/S · src:confirmed] Named vague-adjective ambiguity lint for requirements (fast, scalable, secure, intuitive, robust)**  
  _GitHub Spec Kit (/speckit.analyze detection passes)_ — https://github.com/github/spec-kit/blob/main/templates/commands/analyze.md  
  Add a concrete ambiguity lint to spec-reviewer: a banned-vague-adjective list (fast/scalable/secure/intuitive/robust/performant/user-friendly) that must be replaced with a measurable threshold in a Success criterion, plus a near-duplicate-requirement pass. Tie to the existing severity vocabulary (v…
- **[H/M · src:confirmed] Persistent immutable project constitution validated against every spec (constitution conflicts auto-CRITICAL)**  
  _GitHub Spec Kit (/speckit.constitution + /speckit.analyze)_ — https://github.com/github/spec-kit/blob/main/templates/commands/analyze.md  
  Add an optional zuvo/constitution.md of immutable project principles. Phase-0 bootstrap loads it; add spec-reviewer C0 (Constitution Alignment) and a Phase-3b adversarial pre-check that auto-promotes any spec decision contradicting a MUST principle to CRITICAL — mirroring the existing auth/RBAC con…
- **[M/S · src:confirmed] EARS notation (WHEN/IF/WHILE/WHERE ... the system SHALL ...) for unambiguous, testable acceptance criteria**  
  _Amazon Kiro (EARS — Easy Approach to Requirements Syntax)_ — https://teachmeidea.com/kiro-ai-ide-spec-driven-development/  
  Offer EARS as the recommended phrasing for the AC headline sentence (keep the Surface/Proof/Expected/Artifact scaffolding underneath). Add a spec-reviewer C8 sub-check: each ship AC must be expressible as a single EARS clause (one trigger, one SHALL behavior); flag compound 'and'-joined criteria th…
- **[M/M · src:confirmed] Structured coverage-based clarification loop recorded in a Clarifications section**  
  _GitHub Spec Kit (/speckit.clarify)_ — https://github.github.com/spec-kit/quickstart.html  
  Add a fixed clarification coverage taxonomy to Phase 2 Step 2 (the axes the business-analyst already enumerates: data boundaries, timing/concurrency, auth/access, integration, non-functional thresholds) and require a `## Clarifications` section in the spec listing each question, the axis it covers,…
  ⚠️ _CAVEAT:_ the researcher's exact verbatim quote ('uses structured, sequential, coverage-based questioning that records answers in a Clarifications section') was NOT found word-for-word on this quickstart page …

### `build`  (3 verified, 0 rejected)

- **[H/M · src:confirmed] Persistent project Constitution re-asserted into every phase as a non-negotiable gate**  
  _GitHub Spec Kit (/speckit.constitution)_ — https://codestandup.com/posts/2025/github-spec-kit-tutorial-constitution-command/  
  Add an optional zuvo/constitution.md (or a CLAUDE.md '## Constitution' section). In Phase 0, load it and echo it into the plan's Scope Fence; add a 'CONSTITUTION: all principles satisfied (with violation list or none)' line to the 4.3 Execution Verification checklist and the Completion Gate, scored…
  ⚠️ _CAVEAT:_ source does NOT confirm the researcher's 're-read before every task' claim — it only confirms template injection + memory role
- **[H/M · src:confirmed] Structured ambiguity-resolution (Clarify) BEFORE planning, not after**  
  _GitHub Spec Kit (/speckit.clarify)_ — https://github.com/github/spec-kit  
  Insert a Phase 1.5 'Clarify' between Discovery (1a) and Plan (2): scan the feature description against a coverage checklist (inputs, error behavior, auth/ownership, edge cases, acceptance shape) and ask up to 4 questions BEFORE drafting the plan. Tier-aware (LIGHT: one-line 'no ambiguities' asserti…
- **[M/S · src:confirmed] Requirements-quality check validating the spec itself before coding (definition-of-done per workflow step)**  
  _GitHub Spec Kit (/speckit.checklist)_ — https://martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html  
  During Phase 2 plan authoring (STANDARD+), for each Acceptance Proof assert the underlying requirement is (a) testable, (b) unambiguous, (c) has a defined error/edge behavior. Any 'ambiguous/untestable' requirement bounces to the Phase 1.5 Clarify step. This adds a requirement-quality gate before o…

### `canary`  (4 verified, 0 rejected)

- **[H/S · src:confirmed] Gate on request-success-rate + latency percentile, not just a flat 10s cutoff**  
  _Flagger (progressive delivery / canary analysis)_ — https://docs.flagger.app/usage/deployment-strategies  
  Add two SLO-style gates to Phase 3 verdict: (a) success-rate = (count of 200 responses / total checks); BROKEN if below a configurable --min-success-rate (default 0.95). (b) Replace the flat >10s MEDIUM with a configurable --max-p95 latency threshold compared against the p95 already computed in Pha…
- **[H/M · src:confirmed] Use a consecutive/windowed failure limit, not a cumulative error count over the whole run**  
  _Argo Rollouts (AnalysisTemplate failureLimit)_ — https://www.infracloud.io/blogs/progressive-delivery-argo-rollouts-canary-analysis/  
  Track failures in a sliding window: add --failure-window N (default 3) and declare BROKEN only when N consecutive check cycles fail the gate, distinct from cumulative --max-errors. Keep cumulative count as a DEGRADED signal. This separates transient blips (DEGRADED) from sustained regressions (BROK…
- **[M/S · src:confirmed] Add a confirm/pre-promotion gate before declaring HEALTHY**  
  _Flagger (confirm-promotion webhooks)_ — https://docs.flagger.app/usage/webhooks  
  Add an optional --confirm-hook <url|command> step in Phase 3: before printing HEALTHY, invoke the hook (curl the URL or run the command) and require HTTP 200 / exit 0. If it fails, downgrade verdict to DEGRADED and do not certify HEALTHY. This lets canary integrate with CI acceptance gates.
- **[M/M · src:confirmed] Generate synthetic load during monitoring for low-traffic endpoints**  
  _Flagger (load testing webhook)_ — https://docs.flagger.app/usage/webhooks  
  Add an optional --load <rps>x<seconds> flag that, per check cycle, fires a short burst of concurrent requests (e.g. via a curl loop or 'hey'-style helper) before reading metrics, so success-rate and p95 reflect the page under realistic load rather than a single idle hit. Default off to stay safe in…

### `ci-audit`  (4 verified, 0 rejected)

- **[H/M · src:confirmed] Template/script injection from untrusted ${{ }} interpolation in run: steps is unchecked**  
  _GitHub official docs (Script injections) + zizmor template-injection audit_ — https://docs.github.com/en/actions/concepts/security/script-injections  
  Add a CI5 sub-check (or new CI11 'Untrusted input injection'): search_text/search_patterns for `${{ github.event.` (title, body, *.ref, head_ref, comment, *.name, label) appearing inside `run:` blocks. Flag CRITICAL; recommend hoisting to an `env:` intermediate variable referenced as "$VAR". Treat …
- **[H/M · src:confirmed] Dangerous triggers (pull_request_target, workflow_run) with code checkout are not flagged**  
  _zizmor (dangerous-triggers audit) + GitHub 'Securely using pull_request_target' docs_ — https://github.com/zizmorcore/zizmor  
  Extend CI5 (or add CI11): detect `on: pull_request_target` / `on: workflow_run` and check whether the job runs `actions/checkout` against `${{ github.event.pull_request.head.* }}` or fork ref while secrets/permissions are available. Flag HIGH/CRITICAL with the GitHub 'securely using pull_request_ta…
- **[M/M · src:confirmed] Cache poisoning and credential-persistence (artipacked) attack classes are not audited**  
  _zizmor (cache-poisoning + artipacked audits)_ — https://docs.zizmor.sh/audits/  
  Add to CI5: (1) flag cache restore (actions/cache, setup-* cache:) inside release/publish jobs as potential cache poisoning; (2) flag actions/checkout without `persist-credentials: false` when an artifact upload of the workspace follows. Cite zizmor cache-poisoning/artipacked as the rule basis.
- **[M/M · src:confirmed] Build provenance / SLSA artifact attestation is not assessed for release pipelines**  
  _GitHub Artifact Attestations (actions/attest-build-provenance) — SLSA v1.0_ — https://docs.github.com/en/actions/concepts/security/artifact-attestations  
  Add a CI4 (or CI6) sub-check: for workflows that publish artifacts/images/packages, detect presence of `actions/attest-build-provenance`/`actions/attest` and the required `permissions: id-token: write` + `attestations: write`. Score MEDIUM-HIGH absence as a supply-chain gap; recommend SLSA Build Le…

### `code-audit`  (4 verified, 0 rejected)

- **[H/S · src:confirmed] Map artifactLocation.uri to repo-root-relative paths and severity to SARIF's three levels for merge gating**  
  _SARIF 2.1.0 / GitHub code scanning result schema_ — https://dev.to/pavelespitia/sarif-the-format-that-connects-your-ai-auditor-to-github-code-scanning-311n  
  As part of the SARIF emitter, normalize the file part of each existing file:line citation to a repo-root-relative artifactLocation.uri (git root already resolved for ZUVO_DIR), set region.startLine from the line number, and translate the Validity-Gate verdict into result.level so a downstream githu…
- **[H/M · src:confirmed] Emit findings as OASIS SARIF 2.1.0 so the audit plugs into GitHub code scanning / PR annotations / branch protection**  
  _SARIF 2.1.0 (OASIS Standard) + GitHub code scanning_ — https://dev.to/pavelespitia/sarif-the-format-that-connects-your-ai-auditor-to-github-code-scanning-311n  
  Add a SARIF 2.1.0 emitter (zuvo/audits/code-quality-audit-<date>.sarif) alongside the existing .md + JSON. Map each CQ/CAP to a SARIF tool.driver.rules entry; each finding to a result with ruleId, level (critical-gate FAIL CQ3/4/5/6/8/14 + CAP5/6/7/8 -> error; HIGH -> warning; MEDIUM/NIT -> note), …
- **[M/S · src:confirmed] Define a reliability rating keyed to worst-bug severity, distinct from the maintainability tier**  
  _SonarQube (Reliability rating)_ — https://docs.sonarsource.com/sonarqube-server/10.8/user-guide/code-metrics/metrics-definition  
  Introduce a secondary Reliability rating per file/project derived from the worst-severity CAP/critical-gate finding using SonarQube's worst-bug-wins mapping (any blocker -> E, any critical -> D, major -> C, minor -> B, none -> A), reported alongside the existing maintainability tier so a single sev…
- **[M/M · src:confirmed] Add quantitative Cognitive Complexity + maintainability/technical-debt-ratio rating to complement line-count gates**  
  _SonarQube (Cognitive Complexity, Maintainability rating, Technical Debt Ratio)_ — https://docs.sonarsource.com/sonarqube-server/10.8/user-guide/code-metrics/metrics-definition  
  Add a per-function Cognitive Complexity metric (CodeSift analyze_complexity already exists and is in the skill tool list) as a CQ11 companion, and compute a project technical-debt-ratio mapped to SonarQube's exact A-E grid (A <=5%, B 5-10%, C 10-20%, D 20-50%, E >=50%). Surface it in the Phase 2 Su…

### `content-audit`  (3 verified, 0 rejected)

- **[H/M · src:confirmed] Adopt Vale's codifiable check-type taxonomy (consistency, occurrence, substitution, metric) instead of one fuzzy LLM-judged CC8**  
  _Vale (vale.sh)_ — https://vale.sh/docs/topics/styles  
  Add deterministic CC8 sub-checks runnable in --quick (grep-able, no agent): (1) term-consistency — flag when both spellings of a configurable term pair (e.g. 'email'/'e-mail', 'website'/'web site') appear in the same scope; (2) preferred-term-substitution — flag a wrong->right term map, loadable fr…
- **[M/M · src:confirmed] Add readability metrics (Flesch-Kincaid / Gunning Fog) as a scored CC7 completeness signal**  
  _Vale 'metric' rules (vale.sh); write-good / textlint for prose anchors_ — https://vale.sh/docs/topics/styles  
  Add a CC7 (or new CC sub-dimension) readability check computing Flesch-Kincaid grade and Gunning Fog per file, with profile-aware target bands (docs vs marketing vs blog, keyed off the existing --profile flag) and a deterministic flag when a file exceeds the band. Pair with a lightweight write-good…
- **[M/M · src:confirmed] Harden the --live-url link path with lychee-style caching and per-URL retry/backoff (throttling already present)**  
  _lychee (lycheeverse/lychee)_ — https://github.com/lycheeverse/lychee  
  In the live link path: (1) cache probe results keyed by URL with a configurable max-age so re-audits skip recently-verified links (currently every re-run re-probes everything — no cache exists in live-probe-protocol.md); (2) add bounded per-URL retry+backoff before declaring an external link dead, …

### `content-expand`  (1 verified, 1 rejected)

- **[H/M · src:confirmed] No Information Gain scoring — we expand for coverage but never measure NEW knowledge vs. existing ranking pages**  
  _Google Information Gain patent (US20200349181A1); Semrush_ — https://www.semrush.com/blog/information-gain/  
  Add an Information-Gain dimension to the Phase 0.4 / Phase 2.6 scoring rubric and a soft gate: for each added section, flag whether it carries at least one original-contribution signal (unique data point/stat, first-hand experience, named-expert commentary, original comparison/benchmark, or origina…

  _rejected:_ No competitive entity/term coverage-gap pass — our research is explicitly 'NOT competitor analysis' (hallucinated-source)

### `content-fix`  (4 verified, 0 rejected)

- **[H/M · src:confirmed] ftfy reconstructs the encode/decode chain and fixes multi-layer mojibake, beyond a static signature table**  
  _ftfy (python-ftfy, rspeer)_ — https://github.com/rspeer/python-ftfy  
  For `encoding-mojibake`, when ftfy is present on PATH/in the env (detected in env-compat, never installed — GATE 1 forbids installs), prefer `ftfy.fix_text()` / the CLI as the primary fixer and keep the static signature table as a no-dependency deterministic fallback. This catches multi-layer mojib…
- **[H/M · src:confirmed] Batch-apply multiple per-file fixes as reverse-order positional edits to guarantee deterministic, overlap-safe results**  
  _markdownlint --fix (DavidAnson) / applyFixes_ — https://deepwiki.com/DavidAnson/markdownlint/4.1-automatic-fixing  
  Replace the vague Phase 2.0 instruction 'batch all fixes into one edit' (line 191) with a concrete algorithm: represent each fix as a positional edit (line/column, delete-count, insert-text) and apply edits sorted in reverse document order (bottom-to-top, right-to-left) so no edit invalidates anoth…
- **[M/S · src:confirmed] Add markdownlint MD009/MD012/MD047 to the typography/markdown SAFE tier (trailing spaces, multiple blanks, EOF newline)**  
  _markdownlint Rules.md (MD009/MD012/MD047)_ — https://github.com/DavidAnson/markdownlint/blob/main/doc/Rules.md  
  Extend the `typography-fix`/`markdown-fix` SAFE contracts in content-fix-registry.md (and the SKILL Phase 2.1) to add: strip trailing spaces while preserving an intentional 2-space hard-break, collapse 3+ consecutive blank lines to one, and ensure a single trailing newline at EOF — reusing the exis…
- **[M/M · src:confirmed] ftfy.fix_and_explain emits a per-transformation plan for transparency and consistent re-application**  
  _ftfy fix_and_explain()_ — https://alexwlchan.net/notes/2025/ftfy-fix-and-explain/  
  Add an optional `transformation_plan` array (operation + encoding/fix tuples) to the content-fix action schema (fix-output-schema.md actions[]) populated from ftfy's explain output when ftfy is used, and surface it under each MODERATE encoding fix in the Phase 5 report. When multiple files share an…

### `content-migration`  (5 verified, 0 rejected)

- **[H/S · src:confirmed] Word-count delta and page-level content-similarity change detection as an explicit parity signal**  
  _Screaming Frog SEO Spider — Compare Crawls / Change Detection_ — https://www.screamingfrog.co.uk/seo-spider/tutorials/how-to-compare-crawls/  
  Add a page-level metric to Phase 2: total content word count old vs new with a delta percentage, and raise a WARNING when new < ~80% of old (mirrors Screaming Frog's word-count change report). Include old_words/new_words/delta in the JSON summary alongside matched/partial/missing.
- **[H/M · src:confirmed] Redirect resolution + chain/loop validation as part of parity (we exclude it)**  
  _Screaming Frog SEO Spider + migration checklists_ — https://www.screamingfrog.co.uk/seo-spider/tutorials/how-to-use-the-seo-spider-in-a-site-migration/  
  Add an optional --check-redirect step: when both --old and --new are given, HEAD/GET the old URL with redirect-following, record hop count, final URL, and whether final == --new. Flag CHAIN (>1 hop), LOOP, and TEMP-302-in-chain as findings (not silently consumed in 0.3). Surface in the report's SEO…
- **[H/L · src:confirmed] Bulk list-mode comparison of an entire old-URL set in one run (vs our one-page-per-invocation)**  
  _Screaming Frog SEO Spider (site migration tutorial)_ — https://www.screamingfrog.co.uk/seo-spider/tutorials/how-to-use-the-seo-spider-in-a-site-migration/  
  Add a --batch <urls-file|sitemap.xml> mode (or --old-list / --map <csv of old,new>) that iterates the parity pipeline over every pair, auto-populates migration-status.json, and emits a single roll-up report. Reuse the existing per-page logic; cap concurrency and honor the live-probe consent/rate-li…
- **[M/M · src:confirmed] Orphan-page / whole-page-loss detection: diff old sitemap vs new sitemap**  
  _Screaming Frog SEO Spider — orphan pages report_ — https://www.screamingfrog.co.uk/seo-spider/tutorials/how-to-use-the-seo-spider-in-a-site-migration/  
  In the proposed --batch mode, diff the old sitemap.xml URL set against the new sitemap.xml (or against the set of pages we found equivalents for) and report MISSING-PAGE findings for old URLs with no new counterpart. This catches whole-page loss, which the current element-level check structurally c…
- **[M/M · src:confirmed] Explicit old->new URL-mapping CSV input for cross-structure batch alignment**  
  _Screaming Frog SEO Spider — Crawl Comparison + URL Mapping_ — https://www.screamingfrog.co.uk/seo-spider/tutorials/how-to-compare-crawls/  
  Support an explicit URL-mapping CSV input (old_url,new_url) for batch runs so users can pre-declare the path translation when slug/path heuristics are unreliable, and classify each entry as MAPPED / REMOVED / MISSING in the roll-up. This removes the LOW-confidence guessing that currently forces NEE…

### `context-audit`  (5 verified, 0 rejected)

- **[H/M · src:confirmed] Measure context in real BPE tokens against the model's actual context window, not bytes**  
  _Tokalator (context engineering toolkit for AI coding assistants)_ — https://tokalator.wiki/  
  Add a token-estimation step: convert include byte sizes to estimated tokens (bytes/4 heuristic, or a real BPE tokenizer when available) and report cumulative tokens as a percentage of the active model's context window (e.g. '42K tokens = 21% of 200K'). Ship a per-model context-window table so a bud…
- **[M/S · src:confirmed] Add an MCP tool-count budget and deferred-loading recommendation, not just a per-server token check**  
  _Anthropic Engineering — Effective context engineering for AI agents_ — https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents  
  Add an MCP tool-budget check to Phase 2.1: count total always-loaded tool definitions across servers, flag high counts as an ambiguous-selection risk (not just token cost), and recommend deferred/on-demand tool loading (ToolSearch-style) for niche tools.
- **[M/S · src:confirmed] Ground scoring in the attention-budget / context-rot rationale and add a compaction recommendation**  
  _Anthropic Engineering — Effective context engineering for AI agents_ — https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents  
  Add an 'attention budget' framing to the report header and a recommendation rule: when avg tokens/run is high or a session nears the window, recommend (a) just-in-time include loading via lightweight references instead of pre-loading, and (b) compaction — citing the attention-budget rationale so th…
- **[M/M · src:confirmed] Report cost-per-turn and project total tokens after the next turn**  
  _Tokalator_ — https://tokalator.wiki/  
  Add a 'Projected next run' line: take the heaviest-tier include set for the skill the user is about to run, project tokens plus approximate cost (tokens x active-model input price), and warn if projected load would exceed a configurable fraction (e.g. 50%) of the window.
- **[M/M · src:confirmed] Recalibrate thresholds to empirical context-rot evidence and penalize distractor includes**  
  _Chroma Research — Context Rot (18-model study)_ — https://www.trychroma.com/research/context-rot  
  Recalibrate thresholds to the evidence: warn that degradation begins well before the window is full (don't only flag near-limit runs), and add a 'distractor' check that penalizes includes irrelevant to the current skill/tier — a single irrelevant include is a measurable cost — independent of total …

### `db-audit`  (5 verified, 0 rejected)

- **[H/M · src:confirmed] Backward-incompatible (breaking) change detection as a first-class rule, not just a manual DB13 row**  
  _Atlas (ariga) migration lint analyzers — BC101/BC102_ — https://atlasgo.io/lint/analyzers  
  Add a DB13 sub-check 'BC: breaking-change detection' that diffs old vs new schema (via diff_migrations / analyze_schema) to flag column/table renames and column-drops still referenced by code (trace_query). Emit a HIGH finding with expand-contract remediation (add new col -> dual-write -> backfill …
- **[H/M · src:confirmed] Live mode recommends MISSING indexes via hypothetical indexes, not just unused ones**  
  _Dexter (ankane) + HypoPG_ — https://github.com/ankane/dexter/blob/master/README.md  
  Add a Phase 3.x 'index advisor' step (PostgreSQL --live): if the hypopg extension is available, for each top slow query from pg_stat_statements, create hypothetical indexes and re-run EXPLAIN to find the index that lowers cost, then emit it as a DB2 recommendation. Gate on read-only (hypothetical i…
- **[M/S · src:confirmed] Data-dependent migrations: 'passes locally, fails in production on real data'**  
  _Atlas migration lint analyzers — MF101-MF104_ — https://atlasgo.io/lint/analyzers  
  Add a DB13 'data-dependent change' category: when diff_migrations/migration_lint sees ADD UNIQUE on an existing column or non-unique->unique index conversion, emit a finding requiring an explicit pre-check (SELECT col, count(*) ... GROUP BY HAVING count(*)>1) and a backfill/dedup plan before the mi…
- **[M/S · src:confirmed] Enumerate semantic query/schema anti-patterns our dimensions imply but don't name**  
  _sqlcheck (jarulraj)_ — https://github.com/jarulraj/sqlcheck  
  Add explicit rows: DB8 'ORDER BY RAND()/RANDOM() on growing table' (HIGH); DB3 'EAV / generic key-value table pattern' (MEDIUM); DB2 'over-indexing — table with >N indexes amplifies writes' as the inverse of unused-index (MEDIUM); DB2 'composite index attribute order does not match query predicate/…
- **[M/M · src:confirmed] CREATE INDEX CONCURRENTLY inside a transaction is a distinct, silent-failure check**  
  _Atlas v0.38 nestedtx / atlas:txmode none_ — https://atlasgo.io/blog/2025/10/28/v038-analyzers-pii-and-migration-hooks  
  Extend DB13 lock-duration check: when a migration contains CONCURRENTLY, verify it is NOT inside BEGIN/COMMIT and that the ORM/runner does not auto-wrap migrations in a transaction (Prisma, node-pg-migrate, Rails all auto-wrap by default). Flag as HIGH with the runner-specific opt-out (node-pg-migr…

### `debug`  (3 verified, 0 rejected)

- **[H/M · src:confirmed] Add a delta-debugging / minimal-repro reduction step (ddmin) before diagnosis**  
  _Delta Debugging (Andreas Zeller; GRIMM Cyber R&D writeup)_ — https://grimmcyber.com/delta-debugging/  
  Add a 'Phase 2.5: Minimize the Reproducer' step that applies a ddmin-style loop — partition the failing input/state/config into chunks, remove chunks while the failure still reproduces, converge on a 1-minimal repro — and feed THAT minimal case into Phase 3 diagnosis and the Phase 4.5 regression te…
- **[H/M · src:confirmed] Add an observability-data correlation phase (traces / spans / profiles / logs) to diagnosis**  
  _Sentry Seer (AI debugger) — trace-aware Autofix_ — https://blog.sentry.io/sentry-ai-debugger-autofix-superpower-traces/  
  Add a Phase 3 sub-step 'Runtime evidence' that, when observability is available (Sentry MCP, OTel, APM, or structured logs with a correlation/trace ID), correlates the error to its trace/spans/profile and connected errors to localize the failing service+operation, then maps that span back to source…
- **[M/S · src:confirmed] Enforce an explicit scientific-debugging logbook (hypothesis -> prediction -> experiment -> observation), iterated until refined**  
  _Scientific Debugging — Andreas Zeller, 'Why Programs Fail'_ — https://dev.to/hectorw_tt/why-programs-fail-a-guide-to-systematic-debugging-by-andreas-zeller-a-book-review-24h8  
  Extend the Phase 3 diagnosis table to a logbook with columns Hypothesis | Prediction (if true, then X observable) | Experiment run | Observation | Conclusion (confirmed/refuted/refine), and require iterating until the surviving hypothesis can no longer be refined before declaring root cause.

### `dependency-audit`  (3 verified, 0 rejected)

- **[H/M · src:confirmed] Exploitability-based prioritization (EPSS) instead of raw CVE severity**  
  _OWASP Dependency-Track_ — https://dependencytrack.org/  
  In D1 scoring, enrich each CVE with its EPSS score (FIRST.org EPSS API, gated behind --no-api) and rank the remediation roadmap by EPSS x reachability, not CVSS alone. Add a VEX-style 'not_affected (justification)' annotation in the report so a triaged non-reachable CVE can be suppressed in the nex…
  ⚠️ _CAVEAT:_ VEX is NOT present on this page per fetch — the VEX half of the proposal is unsupported by this URL and should cite a VEX-specific source (e.g
- **[H/L · src:confirmed] Behavioral malicious-package signals (install-script behavior, obfuscation, typosquatting, ownership churn) not just CVEs**  
  _Socket.dev_ — https://docs.socket.dev/docs/supply-chain-risk  
  Add a D1 sub-check 'Behavioral red flags' that, for newly-added/recently-published deps, scores: (a) install script that touches network/shell/env (grep the postinstall + lockfile), (b) typosquat distance to popular package names (Levenshtein vs a top-package list), (c) obfuscation/high-entropy bun…
- **[M/M · src:confirmed] Maintenance/health signals as named checks: Maintained (90-day), Pinned-Dependencies, Dependency-Update-Tool**  
  _OpenSSF Scorecard_ — https://github.com/ossf/scorecard  
  Extend D2 to (a) detect presence/absence of a dependency-update tool (.github/dependabot.yml or renovate.json) as its own check, (b) adopt the OpenSSF 90-day 'Maintained' definition explicitly, and (c) optionally pull the OpenSSF Scorecard score per top dependency (api.securityscorecards.dev) when …

### `deploy`  (5 verified, 0 rejected)

- **[H/M · src:confirmed] Metric-threshold verification gate (error rate / p95 latency), not just HTTP 200 + 10s**  
  _OneUptime / k6 post-deployment verification_ — https://oneuptime.com/blog/post/2026-02-26-argocd-post-deployment-verification/view  
  Add an optional metric-gate to Phase 6: accept --error-budget <pct> and --p95-ms <ms>; when the platform exposes metrics (or via --metrics-url), probe N times, compute observed error rate and p95, and FAIL the gate when either threshold is breached even if the homepage returns 200. Default threshol…
- **[H/M · src:confirmed] Multi-step synthetic smoke test of a critical user journey, reusable as scheduled monitor**  
  _New Relic synthetic monitors / smoke testing_ — https://newrelic.com/blog/how-to-relic/smoke-testing-with-synthetic-monitors  
  Add --smoke <file> that runs a project-supplied multi-step smoke script (or hands off to a zuvo:write-e2e/Playwright spec tagged @smoke) against production after deploy, asserting the critical journey works; on completion, suggest registering it as a scheduled synthetic monitor (tie into zuvo:canar…
- **[M/M · src:confirmed] Auto-rollback wired to error-rate/log threshold (opt-in, consent-gated)**  
  _DevOps Training Institute — CI/CD post-deployment validation_ — https://www.devopstraininginstitute.com/blog/12-post-deployment-validation-steps-in-cicd  
  Keep manual-default. Add opt-in --auto-rollback-on-fail that, when the Phase 6 metric gate (finding 1) breaches the configured error budget, executes the detected rollbackCmd after a single confirmation line (and in explicit non-interactive opt-in, executes + logs). Always surface the observed erro…
- **[M/M · src:confirmed] Post-deploy validation of DB migrations + env/config, separate from URL health**  
  _DevOps Training Institute — post-deployment validation steps_ — https://www.devopstraininginstitute.com/blog/12-post-deployment-validation-steps-in-cicd  
  Add a Phase 5.5 'release sanity' step: if the repo exposes a migration-status command (prisma migrate status, rails db:migrate:status, drizzle) run it and FAIL on pending/failed migrations; optionally probe a /readyz or app-defined readiness endpoint asserting DB connectivity. Gate the deploy verdi…
- **[L/L · src:confirmed] Progressive/canary traffic-shift with new-vs-stable comparison before full rollout**  
  _HashiCorp Well-Architected Framework — zero-downtime deployments_ — https://developer.hashicorp.com/well-architected-framework/define-and-automate-processes/deploy/zero-downtime-deployments  
  Where the detected platform natively supports it (Vercel staged rollouts/skew protection, Fly.io --strategy canary), add optional --strategy canary that promotes to a small slice, runs the metric gate (finding 1) on the canary, and promotes to 100% only on pass — else aborts/holds. Keep advisory/ma…

### `design`  (4 verified, 0 rejected)

- **[H/S · src:confirmed] Make AA contrast and text-resize explicit, named requirements in the per-component checkpoint**  
  _OpenAI Apps SDK UI Guidelines (accessibility section)_ — https://developers.openai.com/apps-sdk/concepts/ui-guidelines  
  Add an 'A11y:' line to the Step 6 checkpoint template requiring: stated text/background token pair + measured AA ratio, alt-text strategy for any imagery, and a text-resize/200%-zoom note. Makes accessibility a build-time decision rather than a post-hoc audit.
- **[H/M · src:confirmed] Emit design tokens in the stable W3C DTCG .tokens.json format, not a bespoke system.json**  
  _W3C Design Tokens Community Group (DTCG) Format Module 2025.10; Style Dictionary, Tokens Studio, Terrazzo, Figma, Penpot, Supernova_ — https://www.w3.org/community/design-tokens/2025/10/28/design-tokens-specification-reaches-first-stable-version/  
  Add a DTCG export: in Phase 6 (Step 8) also write .interface-design/tokens.tokens.json using DTCG syntax ($value/$type, color/dimension/fontFamily types). Keep system.json for design-review's internal use but make DTCG the interchange artifact. Document a --format dtcg flag and that the output roun…
  ⚠️ _CAVEAT:_ the page does NOT mention $value/$type, the .tokens.json extension, or application/design-tokens+json media type — those technical specifics in the researcher's gap/proposal are accurate to the DTCG …
- **[H/M · src:confirmed] Add a numeric contrast-verification gate over every foreground x background token pair (light + dark)**  
  _Design-system contrast-audit practice (we-promise/sure issue #1736; Figma 'Check Designs' AI linter, Oct 2025)_ — https://github.com/we-promise/sure/issues/1736  
  Add a 5th craft validation test ('Contrast Test') AND promote it into the --quick minimum gate: enumerate every text-token x background-surface-token pair from system.json, compute WCAG 2.1 relative-luminance ratio in light and dark, require >=4.5:1 (normal) / 3:1 (large/UI), and hard-fail the pers…
- **[M/M · src:confirmed] Add a host-theme-inheritance build mode for embedded/partner surfaces**  
  _OpenAI Apps SDK UI Guidelines_ — https://developers.openai.com/apps-sdk/concepts/ui-guidelines  
  Add an 'embedded' / --host mode to Step 0 that swaps Phase 3 direction-selection for host-token inheritance: use system colors for text/icons/dividers, inherit the platform font stack, apply brand accents sparingly without overriding backgrounds/text, and add a checkpoint line 'HostTokens: [which h…

### `design-review`  (4 verified, 0 rejected)

- **[H/S · src:confirmed] Emit SARIF (and JSON) so DX/DAP findings surface inline in PRs and CI dashboards**  
  _@lapidist/design-lint (open-source design-system linter, Aug 2025)_ — https://lapidist.net/articles/2025/introducing-lapidist-design-lint/  
  Add a `--format sarif` option (or always emit a .sarif alongside the markdown report) that maps each DX/DAP finding's mandatory `path/to/file.ext:LINE` evidence into SARIF result objects with ruleId=DX2/DX20/DAP3/etc. Cheap because line-level evidence is already required by the validity gate (line …
- **[H/M · src:confirmed] Adopt W3C DTCG token format ($value/$type, .tokens) as the canonical schema for DX2-DX4 token matching**  
  _W3C Design Tokens Community Group — Design Tokens Format Module (v2025.10, first stable)_ — https://www.designtokens.org/tr/drafts/format/  
  Add DTCG ingestion to Phase 1 Step 1: detect `*.tokens`/`*.tokens.json` and parse `$type`/`$value`. Add a DX/Craft check (extend the Token Test in Step 5.5) that validates each token value against its declared `$type` (flag a `color` token holding a non-color value as invalid, per the spec's 'token…
- **[M/M · src:confirmed] Add a baseline + pixel-diff visual regression mode, not just one-shot screenshots**  
  _Playwright (toHaveScreenshot / pixelmatch) + Chromatic_ — https://playwright.dev/docs/test-snapshots  
  Add a `--baseline` regression sub-mode to Phase 3: on first run, save golden screenshots under zuvo/audits/design-baselines/<route>-<bp>.png; on later runs, pixel-diff via pixelmatch with a configurable maxDiffPixels threshold, mask dynamic regions, and emit a DAP-style 'visual drift' finding when …
- **[M/M · src:confirmed] Compute a quantitative DOM-element-weighted shared-component adoption ratio**  
  _Mews design-system adoption metric (production-data methodology)_ — https://developers.mews.com/design-system-adoption-metric-building/  
  Strengthen Step 5 item 5 / DX20 with an element-weighted adoption metric: in code mode, ratio of JSX elements resolving to shared/design-system components vs total JSX elements per view (composites count their nested elements, naturally weighting complex components); in visual mode, optionally tag …

### `docs`  (0 verified, 0 rejected)


### `env-audit`  (4 verified, 0 rejected)

- **[H/S · src:confirmed] Concrete full git-history secret scan command for ENV4 (replace vague history note)**  
  _gitleaks (secret scanner, git log -p history scan)_ — https://github.com/gitleaks/gitleaks  
  In ENV4 detection, replace the vague 'Git history — Past .env commits' note with a concrete command: run 'gitleaks detect' (full-history scan) or fallback 'git log -p -- "*.env*" | grep -iE secret|key|password|token' to surface secrets in deleted/historical commits. Recommend a pre-commit secret-sc…
  ⚠️ _CAVEAT:_ for the researcher's proposal: the 'gitleaks protect --staged' command is DEPRECATED as of v8.19.0 (still works but hidden in --help); the verbatim '.env API keys' quote was NOT found on the current …
- **[H/M · src:confirmed] .env file syntactic hygiene checks (lowercase/duplicate/unordered keys, delimiter spacing, quote chars)**  
  _dotenv-linter (Rust, used in MegaLinter)_ — https://github.com/dotenv-linter/dotenv-linter  
  Add an ENV9 'File Hygiene' dimension (or a sub-section under ENV1) that scans each .env* file for syntactic defects: duplicate keys (later silently overrides), lowercase keys (some loaders skip), space-around-delimiter (KEY = val breaks POSIX sourcing), unquoted values containing spaces/special cha…
- **[M/M · src:confirmed] Named-environment config grouping is an anti-pattern (sharpens ENV5)**  
  _The Twelve-Factor App — Config (factor III)_ — https://12factor.net/config  
  Reframe ENV5: keep the 'same var set across envs' check, but ADD a check that flags proliferation of named per-environment config files (.env.staging, .env.qa, .env.joes-staging) as an architectural smell, recommending granular per-deploy env vars (injected by platform/secret manager) over committe…
- **[L/S · src:confirmed] Open-source litmus test as an ENV4 summary gate**  
  _The Twelve-Factor App — Config (factor III)_ — https://12factor.net/config  
  Add the 'open-source litmus test' as an explicit ENV4 summary line in the report: state whether the repo could be open-sourced today without exposing any credential, treating a 'no' as the ENV4 critical-gate trigger. Gives reviewers one crisp holistic question alongside the five enumerated checks.

### `execute`  (5 verified, 0 rejected)

- **[M/S · src:confirmed] Kill-and-reassign to a FRESH-context implementer when stuck on the same finding, instead of re-feeding the same agent**  
  _Addy Osmani — 'The Code Agent Orchestra' (multi-agent failure isolation)_ — https://addyosmani.com/blog/code-agent-orchestra/  
  In the spec/quality re-dispatch path (Step 5 ISSUES FOUND, Step 7 FAIL), after the 2nd failed iteration on the same finding fingerprint, dispatch a FRESH implementer (new context, given ONLY task spec + the failing finding + current file state) rather than re-feeding a conversation-laden agent. Rec…
- **[M/M · src:confirmed] Per-run token/dollar budget ceiling with hard cutoff and tiered alerts**  
  _Loop Engineering / agentic-loop cost-governance practice (explainx.ai)_ — https://explainx.ai/blog/loop-engineering-coding-agents-claude-code-guide-2026  
  Add a Pre-loop budget guard: read optional ZUVO_RUN_TOKEN_BUDGET / ZUVO_RUN_USD_CAP (or --budget) and accumulate spend in execution-state.md after each task's telemetry. Before dispatching task N+1, if cumulative spend >= cap -> stop with a new BLOCKED_BUDGET_EXCEEDED terminal state (write state, r…
- **[M/M · src:confirmed] Global no-progress / stuck detector spanning spec->quality->adversarial loops (not just per-loop iteration count)**  
  _Loop Engineering no-progress detection (explainx.ai)_ — https://explainx.ai/blog/loop-engineering-coding-agents-claude-code-guide-2026  
  Add a per-task no-progress fingerprint in Steps 5/7: hash (failing-test-ids + first-error-line + diff-stat). If a re-dispatch yields an identical fingerprint OR an empty diff vs the prior attempt, count a no-progress strike; 2 strikes -> short-circuit to BLOCKED_NO_PROGRESS, skipping the remaining …
- **[L/M · src:confirmed] Peer-to-peer contract handoff between parallel batch agents (no orchestrator bottleneck)**  
  _Addy Osmani — 'The Code Agent Orchestra' (peer-to-peer messaging)_ — https://addyosmani.com/blog/code-agent-orchestra/  
  When a parallel batch contains tasks that produce/consume a shared contract (detectable from the plan's code-contract.md 'Public surface' fields), have each producing task write its resolved contract to zuvo/contracts/<task-N>-<surface>.json on commit, and inject sibling batch contracts into consum…
- **[L/M · src:confirmed] Runtime advisory file-lock as defense-in-depth over static same-file serialization**  
  _Addy Osmani — 'The Code Agent Orchestra' (file locking)_ — https://addyosmani.com/blog/code-agent-orchestra/  
  Add a lightweight advisory lock for parallel batches: before a batch sub-agent's first write it claims zuvo/locks/<sha1(path)>.lock for every file in its declared set; a sibling finding a held lock for a file it also needs aborts back to serialization. Turns the static same-file guard into a runtim…

### `fix-tests`  (4 verified, 0 rejected)

- **[H/M · src:confirmed] Refactoring tools measure coverage delta to prove the fix didn't weaken the test; fix-tests only checks green**  
  _UTRefactor (Automated Unit Test Refactoring, arXiv:2409.16739)_ — https://arxiv.org/html/2409.16739v2  
  Add a coverage-preservation gate to Step 5: capture per-file line+branch coverage of each affected test BEFORE fixing (jest --coverage / pytest-cov / JaCoCo scoped to the touched files), re-measure AFTER, and FAIL the fix if coverage of the production counterpart drops. Surface a 'coverage delta' c…
- **[H/M · src:confirmed] LLM test-refactoring tools add an explicit pre/post functional-equivalence check; fix-tests has none**  
  _UTRefactor (arXiv:2409.16739)_ — https://arxiv.org/html/2409.16739v2  
  Add a lightweight functional-consistency step in Step 5b: for each rewritten assertion, diff old vs new and feed the old-vs-new pairs to the adversarial reviewer as an explicit 'did the subject-under-test or triggering action change?' question. Confirm the new assertion is a strict strengthening of…
- **[M/L · src:confirmed] Canonical test-smell taxonomy (tsDetect / testsmells.org) names smells fix-tests' catalog omits**  
  _tsDetect / testsmells.org (Peruma et al., FSE 2020 demo tool)_ — https://testsmells.org/pages/testsmells.html  
  Add detectors+fixers for the high-value missing smells, mapped to our IDs: Mystery Guest (real fs/db access in unit tests -> mock or move to integration), Resource Optimism (file-exists assumption -> add existence guard/fixture), Sensitive Equality (assert on .toString() -> assert structured fields…
- **[M/L · src:confirmed] Deterministic AST-based refactoring templates per smell (RAIDE) as a faster, safer alternative to free-form rewriting**  
  _RAIDE test-smell refactoring tool (via EmergentMind survey of test-smell detection tools)_ — https://www.emergentmind.com/topics/test-smell-detection-tools  
  For the mechanical patterns already in our table (AP10 delegation-only, AP21 raw mock.calls, Q3-CalledWith, and a new Duplicate-Assert pattern), define explicit AST/structured transform templates in Step 4 instead of free-form rewriting, reserving LLM judgment for the assertion VALUES only. This ma…

### `geo-audit`  (3 verified, 1 rejected)

- **[H/M · src:confirmed] No statistic/dateModified freshness-window check — G5 checks presence/variance but never the 90-day recency window or stale in-prose year tokens**  
  _GenOptima GEO Best Practices 2026_ — https://www.gen-optima.com/geo/generative-engine-optimization-best-practices-2026/  
  Add a deterministic sub-check spanning G5/G11: (1) when dateModified is parseable, flag PARTIAL for blog/marketing pages whose value is >90 days old (cross-referencing the source's 90-day time-sensitive-priority window); (2) regex-scan content body for year tokens and dated-stat patterns and flag p…
- **[M/S · src:confirmed] G2 schema-type coverage omits Speakable schema (and ItemList) which 2026 GEO guidance recommends for AI answer surfaces**  
  _GenOptima GEO Best Practices 2026_ — https://www.gen-optima.com/geo/generative-engine-optimization-best-practices-2026/  
  Extend G2.1 schema-type presence (geo-schema-render.md:88) to recognize Speakable as an advisory-positive type (presence boosts G2, absence never fails); extend the G2.3 attribute-richness table with Speakable (cssSelector or xpath). Add ItemList similarly as advisory-positive for blog/marketing pr…
- **[M/M · src:confirmed] G3 llms.txt check ignores the 'Optional' H2 section semantics and clean .md page mirrors that the spec assigns parsing meaning to**  
  _llmstxt.org official specification_ — https://llmstxt.org/  
  In G3.2 (geo-content-signals.md:121-141): (1) add a check that the 'Optional' H2 section, if present, is the LAST section (its skippable-context contract only holds if it is last); (2) add an advisory G3 sub-check for .md page mirrors — sample a few content routes and look for an <url>.md emitter i…

  _rejected:_ Only a site-weighted GEO score exists — no per-page GEO-adoption/compliance rate, so an A-tier average can mask many failing pages (hallucinated-source)

### `geo-fix`  (3 verified, 1 rejected)

- **[H/M · src:confirmed] A real structured-data validator (sdtt) exists for CI; geo-fix Phase 3.3 schema verification is grep-only and can mark malformed JSON-LD as VERIFIED**  
  _structured-data-testing-tool (sdtt) by iaincollins; schema.org Markup Validator_ — https://github.com/iaincollins/structured-data-testing-tool  
  Add an optional schema-validation step to Phase 3: if sdtt (or a bundled JSON-LD schema validator) is on PATH, run it against the modified file/built output and downgrade the action to FAILED on syntax or required-property errors. Degrade gracefully to the current grep check when the tool is absent…
- **[M/M · src:confirmed] llms.txt spec defines an expanded/full variant (llms-ctx-full) and a required skeleton (H1 + blockquote summary + H2 file-lists + Optional section) our generator never validates or emits**  
  _llmstxt.org official specification (Answer.AI / Jeremy Howard)_ — https://llmstxt.org/  
  Wire the existing (but dormant) `generate_full_companion` param in geo-fix-registry into an actual contract: (a) add an `llms-txt-generate` expanded contract that enforces the spec skeleton (required H1, blockquote summary, H2 file-list sections, an Optional H2), and (b) optionally emit a companion…
- **[M/M · src:confirmed] speakable / passage-level markup flags the citable passage — a publisher GEO citation signal geo-fix has no fix_type for**  
  _Geneo — Schema Markup Best Practices for AI Citations (2025)_ — https://geneo.app/blog/schema-markup-best-practices-ai-citations-2025/  
  Add an optional `speakable-add` fix_type to geo-fix-registry (MODERATE, publisher/news/article profile only) that injects a SpeakableSpecification referencing CSS selectors of the on-page summary/BLUF block, gated to article contexts to avoid misuse on app shells. Add a Phase 3.3 re-check asserting…

  _rejected:_ sameAs entity-resolution links are the highest-leverage Organization schema element and our schema-org-add omits them (already-present)

### `incident`  (4 verified, 0 rejected)

- **[H/S · src:confirmed] Postmortem is built around a single Root Cause + confidence tier; SRE/human-factors practice rejects single root cause for multiple contributing factors**  
  _Google SRE (Postmortem Culture chapter)_ — https://sre.google/sre-book/postmortem-culture/  
  Add a mandatory 'Contributing Factors' subsection to Phase 2 and the postmortem template (lines 483-501), alongside the suspect-commit RCA: enumerate 2-5 systemic factors framed blamelessly (missing test/canary, alerting gap, doc gap, review-process gap, tooling limitation). Keep the suspect-commit…
- **[H/M · src:confirmed] Action-item table uses Owner=TBD with no deadline binding, tracker export, or completion tracking**  
  _Post-Mortem Best Practices That Actually Drive Change (DEV / Samson Tanimawo)_ — https://dev.to/samson_tanimawo/post-mortem-best-practices-that-actually-drive-change-5dgd  
  After Phase 5, add an optional step to export P0/P1 action items into the project tracker by reusing the existing zuvo:backlog skill (confirmed present in the plugin) so each item becomes a tracked B-{N} with owner+due. Refuse to mark an item P0 without a concrete due date (currently template lines…
- **[M/S · src:confirmed] No 'how/contributing-conditions' analysis; skill's linear suspect-commit ranking is the single-cause chain Allspaw warns against**  
  _John Allspaw / Kitchen Soap ('Each necessary, but only jointly sufficient')_ — https://www.kitchensoap.com/2012/02/10/each-necessary-but-only-jointly-sufficient/  
  Add a 'How did this become possible?' prompt to Phase 2.3 asking for enabling conditions beyond the trigger commit (what guardrail/canary/test/alert was absent that let this reach prod). Add a short anti-hindsight note to Safety Rules (lines 88-98): analyze what people knew at the time, not what is…
- **[M/M · src:confirmed] No repeat-incident / recurring-root-cause detection as a tracked signal**  
  _Post-Mortem Best Practices That Actually Drive Change (DEV / Samson Tanimawo)_ — https://dev.to/samson_tanimawo/post-mortem-best-practices-that-actually-drive-change-5dgd  
  In Phase 0/2, grep docs/incidents/*.md for prior postmortems matching the same --service or risk area; if found, add a 'Repeat incident — recurrence of [incident-id]' flag to the metadata table (lines 464-473) and surface the prior postmortem's open/incomplete action items and Prevention checkboxes…

### `infra-audit`  (4 verified, 1 rejected)

- **[H/M · src:confirmed] Active SSH algorithm negotiation + named-attack detection (Terrapin/DHEat/user-enum) beyond static sshd_config reads**  
  _jtesta/ssh-audit_ — https://github.com/jtesta/ssh-audit  
  Add ssh-audit to the IS1 collector as a DD-3 consent-gated tool (or run from the --scan-via vantage, where it is a portable client probe). Feed `ssh-audit -j` JSON into the collector as an IS1 check source and add registry rows for terrapin-vulnerable / user-enum-vulnerable / kex-weak / cipher-weak…
- **[H/M · src:confirmed] Map findings to formal compliance profiles (STIG, PCI-DSS) — not only CIS**  
  _OpenSCAP / SCAP Security Guide_ — https://www.open-scap.org/security-policies/scap-security-guide/  
  Extend infra-check-registry rows with optional `stig_id` / `pci_dss_ref` columns alongside the existing `cis_ref`, and add a `--profile cis|stig|pci-dss` flag selecting which control-mapping column the per-host report and fleet-summary surface. Even partial mapping for high-frequency checks (SSH, a…
- **[M/M · src:confirmed] Declarative SSH policy scan — grade a host pass/fail against a named pinned baseline**  
  _jtesta/ssh-audit (policy scan mode)_ — https://github.com/jtesta/ssh-audit  
  Add a `--policy <name|path>` mode that ships one or two pinned baselines (e.g. openssh-hardened, cis-ssh) and accepts a user policy file. After registry scoring in Phase 3, diff each host's effective SSH settings against the named policy and emit a per-control PASS/FAIL conformance table in the per…
- **[L/L · src:confirmed] Emit a machine-readable compliance result datastream (XCCDF/ARF) for RMF/audit pipelines**  
  _OpenSCAP (oscap xccdf eval → ARF/XCCDF)_ — https://www.open-scap.org/security-policies/scap-security-guide/  
  Add an optional `--format arf|xccdf` Phase-3 sidecar export that serializes the deterministic per-host findings (already keyed on check_id with severity + CIS/STIG refs) into a minimal XCCDF result document or ARF datastream, making infra-audit output a drop-in artifact for existing compliance pipe…

  _rejected:_ Run Lynis and a compliance/STIG scanner in parallel rather than treating Lynis as the sole authority (hallucinated-source)

### `leads`  (4 verified, 1 rejected)

- **[H/M · src:confirmed] No disposable / temporary email detection in the verification pipeline**  
  _BillionVerify (Disposable Email Detection)_ — https://billionverify.com/disposable-email-detection  
  Add an is_disposable bool to the contact schema (lead-output-schema.md) and a disposable_domains list to the lead-validator rules object; ship a small bundled static list (public 'disposable-email-domains' GitHub list). In Phase 3 / validator labeling, match the email host against it and route matc…
- **[H/M · src:confirmed] GDPR handling is jurisdiction-blind: single eu-eea bloc ignores ePrivacy + member-state overrides**  
  _Prospeo (GDPR Cold Email Rules in 2026)_ — https://prospeo.io/s/gdpr-cold-email  
  Extend gdpr_flag (or add a gdpr_jurisdiction field in lead-output-schema.md) to carry the ISO country plus a derived legal_basis_note from a small bundled country-rules table (DE=consent-required, FR=b2b-permitted, ES=soft-opt-in, etc.). In --gdpr-strict, surface a per-country warning and tailor th…
- **[M/S · src:confirmed] Catch-all domains are a dead-end label, not a 'risky / send-low-volume' advisory**  
  _Allegrow (Catch-All Email Verification Guide for B2B)_ — https://www.allegrow.co/knowledge-base/catch-all-email-verification-guide-for-b2b  
  Keep the short-circuit but enrich output: for domains already tracked in meta.catch_all_domains, emit an advisory note in the Markdown report ('catch-all: deliverability unconfirmed — segment separately, send low-volume personalized, trust only on reply') and surface a per-record send_risk hint (lo…
- **[M/S · src:confirmed] GDPR_NOTICE template lacks retention cap and per-campaign LIA guidance**  
  _Prospeo / Sales Force Europe (Legitimate Interest Assessment guidance)_ — https://prospeo.io/s/gdpr-cold-email  
  Augment the Phase 6 GDPR_NOTICE template with (a) a computed retention-expiry line (retrieved_at + 3 years, framed as 'common practice, verify per jurisdiction') and (b) a short LIA stub (purpose/necessity/balancing prompts) for the user to fill per campaign. Purely a template addition in Phase 6 —…

  _rejected:_ No upfront syntax-validation layer before MX/SMTP probing (hallucinated-source)

### `mutation-test`  (4 verified, 0 rejected)

- **[H/S · src:confirmed] Configurable build-breaking mutation-score threshold (CI gate)**  
  _StrykerJS thresholds.break / PIT mutationThreshold_ — https://stryker-mutator.io/docs/stryker-js/configuration/  
  Add a `--break N` flag (and an env default e.g. ZUVO_MUTATION_BREAK). After Phase 4 score calc, if overall score < N, print 'BREAK: mutation score X% below threshold N%' and exit non-zero so CI fails. Document a recommended high=80/low=60 banding so the existing grade bands and the gate stay consis…
- **[H/M · src:confirmed] Extreme mutation / pseudo-tested-method operator (whole-method-body emptying)**  
  _Descartes / arcmutate (PIT extreme-mutation engine)_ — https://docs.arcmutate.com/docs/extreme.html  
  Add an EXTREME category (or `--extreme` mode): for each covered method generate one mutant that empties the body / returns a default (void: no-op; non-void: null/0/empty). Report survivors as PSEUDO-TESTED methods — a distinct high-priority finding. Run this pass first under tight budgets (--quick)…
- **[H/L · src:confirmed] Incremental/diff-scoped mutation runs for CI (only mutate changed code)**  
  _StrykerJS (stryker-mutator) --incremental mode_ — https://stryker-mutator.io/docs/stryker-js/incremental/  
  Add an `--incremental` flag plus a persisted report at zuvo/reports/mutation-incremental.json. On a subsequent run, diff current files against the stored report (or against `git diff <base>`), generate/execute mutations only for files changed since the last run, reuse stored KILLED/SURVIVED verdict…
- **[M/M · src:confirmed] Equivalent-mutant awareness (un-killable survivors are not test gaps)**  
  _PIT (pitest)_ — https://pitest.org/quickstart/basic_concepts/  
  Add an EQUIVALENT classification step before scoring: after a mutant SURVIVES, have the LLM reason about whether the mutation is behaviourally observable (a reachable input that distinguishes mutant from original). Mark suspected-equivalent mutants as EQUIVALENT, exclude them from the survived-need…

### `pentest`  (2 verified, 1 rejected)

- **[H/M · src:confirmed] Integrate Nuclei templated DAST (CVE + misconfig templates) into the black-box / --verify-live track instead of ad-hoc curl probes**  
  _ProjectDiscovery Nuclei_ — https://docs.projectdiscovery.io/opensource/nuclei/overview  
  Add nuclei to the Phase 0.5 tool-availability probe (lines 268-273 currently probe curl/semgrep/testssl/gitleaks only) and add an optional Phase-4 step: when nuclei is present and --url/--verify-live is set, run nuclei DAST + CVE/misconfig template tags against the authorized non-prod target (respe…
- **[M/M · src:confirmed] Align to OWASP APTS and formalize a non-destructive request/response chain-of-custody evidence contract with an explicit anti-self-confirmation MUST-GATE**  
  _OWASP APTS (Autonomous Penetration Testing Standard) / Astra Security_ — https://www.getastra.com/blog/penetration-testing/autonomous-ai-agents-for-penetration-testing/  
  Add an APTS-aligned evidence contract: every runtime_verified finding must persist a non-destructive, PII-scrubbed, timestamped request/response capture pair under evidence/<id>/ (current evidence spec at lines 734-738 is loose: trace.md/poc.sh/screenshot.png with capture only mandatory under --ver…

  _rejected:_ Map PT1-PT7 dimensions to the OWASP WSTG 12-category taxonomy to close coverage gaps (info-gathering, weak crypto, error handling) (hallucinated-source)

### `performance-audit`  (4 verified, 0 rejected)

- **[H/M · src:confirmed] Lighthouse CI budget.json / assertions as an exit-code-gated CI regression check**  
  _Lighthouse CI (GoogleChrome/lighthouse-ci)_ — https://github.com/GoogleChrome/lighthouse-ci/blob/main/docs/configuration.md  
  Add a 'Performance Budget' output to D2/D10: when Lighthouse/build output is present, emit a ready-to-commit budget.json (or lighthouserc assertions) seeded from the audit's measured values (LCP maxNumericValue, total-blocking-time, script byte budget) with warn/error levels, plus a Phase 6 routing…
- **[H/M · src:confirmed] Long Animation Frames (LoAF) API for script-level INP attribution**  
  _Long Animation Frames API (Chrome for Developers / web-vitals v4)_ — https://developer.chrome.com/docs/web-platform/long-animation-frames  
  Extend D10 with an INP attribution sub-check: when a live URL is provided, capture LoAF entries (via web-vitals v4 attribution build or a PerformanceObserver snippet) to name the slowest script and its source location, turning a vague 'INP poor' finding into an evidence-backed file:line finding wit…
- **[M/S · src:confirmed] Server-Timing header to surface backend timing into DevTools/Performance API**  
  _Server-Timing HTTP header (MDN Web Docs)_ — https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Server-Timing  
  Add to D4/D11 a recommendation (and a finding when absent on slow endpoints) to emit Server-Timing headers (e.g. 'Server-Timing: db;dur=53, cache;desc="Cache Read";dur=23'). This turns TTFB findings into measured backend-phase breakdowns visible in DevTools and consumable by RUM, while flagging the…
- **[M/M · src:confirmed] Field/RUM (CrUX) data as source of truth vs lab-only Web Vitals**  
  _Chrome UX Report (CrUX) / RUM — web.dev guidance_ — https://web.dev/articles/crux-and-rum-differences  
  Add a CrUX field-data probe to D10 (query the public CrUX API / PageSpeed Insights field section for the origin or URL when public) and reconcile against the lab score. When field and lab diverge, emit an explicit finding ('lab passes, field fails INP at 75th percentile') and raise confidence to HI…

### `plan`  (2 verified, 0 rejected)

- **[H/M · src:confirmed] Organize tasks by independently-shippable user story with per-story validation checkpoints (MVP-first), not only by architectural layer**  
  _GitHub Spec Kit (tasks-template.md)_ — https://raw.githubusercontent.com/github/spec-kit/main/templates/tasks-template.md  
  Add a task-grouping dimension to Phase 2 + team-lead.md Step 2: group tasks into ordered 'Slices' (foundational phase first, then one phase per user story / acceptance-cluster), where each slice ends in a CHECKPOINT task that runs that slice's smoke/acceptance proof and is independently demoable. O…
- **[M/M · src:confirmed] Add a post-design project-constitution re-check gate (engineering non-negotiables re-evaluated AFTER synthesis, not just artifact DCs before Phase 1)**  
  _GitHub Spec Kit (plan-template.md / commands/plan.md)_ — https://github.com/github/spec-kit/blob/main/templates/commands/plan.md?plain=1  
  Introduce an optional project-level constitution (read zuvo/constitution.md or a CLAUDE.md 'Non-negotiables' section) and add TWO gate points: (a) a pre-Phase-1 Constitution Check distinct from the artifact-scoped Provided-Design Check, and (b) a MANDATORY post-synthesis Constitution Re-check in te…

### `presentation`  (0 verified, 1 rejected)


  _rejected:_ t (vague)

### `receive-review`  (4 verified, 0 rejected)

- **[H/M · src:confirmed] Adopt Conventional Comments label taxonomy to parse and triage incoming comments deterministically**  
  _Conventional Comments (conventionalcomments.org)_ — https://conventionalcomments.org/  
  In Step 1/Step 2, classify each item using the Conventional Comments labels; when the reviewer already used a label or (blocking)/(non-blocking) decoration, honor it. Map non-blocking nitpicks to a lighter path (fix-or-explicitly-decline without full pushback ceremony) and let the blocking decorati…
- **[H/M · src:confirmed] Add an explicit acknowledge-and-resolve-the-thread step so every comment is closed on the platform**  
  _Tidyverse code-review guide (author/handling-comments)_ — https://code-review.tidyverse.org/author/handling-comments.html  
  Add a Step 5b: for PR-sourced feedback, post each formulated Step 5 response as a reply on its comment thread (gh CLI / gh pr review / GraphQL resolveReviewThread) and mark the conversation resolved after the fix is verified in Step 6. For pushbacks, post the technical reason but do NOT auto-resolv…
- **[M/S · src:confirmed] Define an escalation ladder for contested pushback instead of only 're-evaluate'**  
  _Google eng-practices (Handling pushback in code reviews)_ — https://google.github.io/eng-practices/review/reviewer/pushback.html  
  Add an escalation note to Step 5 (RESPOND): when author and reviewer cannot reach consensus after one re-evaluation, surface it to the user as a decision point — cite the relevant style guide / architecture decision as the tie-breaking authority and recommend a TL/maintainer or design-review discus…
- **[M/S · src:confirmed] Apply 'fix it now, not later' — stop backlogging WARNING-class adversarial findings on already-touched files**  
  _Google eng-practices (Handling pushback in code reviews)_ — https://google.github.io/eng-practices/review/reviewer/pushback.html  
  Tighten the Adversarial Review WARNING rule: if the finding is in a file already touched in this review pass, fix it now regardless of size (matching the cleanup-now principle and the no-silent-backlog-deferral memory), reserving backlog ONLY for findings in untouched files. State the principle exp…

### `refactor`  (4 verified, 0 rejected)

- **[H/S · src:confirmed] Symbol-level edits not mandated to be type-aware/LSP-based (Lossless Semantic Tree principle)**  
  _OpenRewrite / Moderne — Lossless Semantic Tree (LST)_ — https://www.moderne.ai/openrewrite  
  At SKILL.md line 480, make type-aware transformation the REQUIRED path for RENAME_MOVE / MOVE / INTRODUCE_INTERFACE: use rename_symbol (or get_type_info + find_references) and forbid grep-based text replacement for symbol-identity changes. If CodeSift/LSP is unavailable, do NOT silently treat 'Fall…
- **[H/M · src:confirmed] No hard gate enforcing a PURE-refactor diff (Fowler's 'two hats' / commit-in-isolation)**  
  _Martin Fowler, Refactoring (key-points summary, understandlegacycode.com)_ — https://understandlegacycode.com/blog/key-points-of-refactoring/  
  Add a 'Pure-Refactor Diff Gate' to the Completion Gate Check (lines 657-668): before commit, assert the staged diff introduces no NEW observable behavior — no new conditionals/return values, no changed error semantics, no new feature code. The characterization tests from the Phase 2 contract are th…
- **[M/M · src:unreachable] No explicit dry-run/preview-then-diff-review step before applying a mechanical transform**  
  _jscodeshift / codemods (SitePoint codemod guide)_ — https://www.sitepoint.com/getting-started-with-codemods/  
  For mechanical/repeated transforms (rename across N files, signature change with many call sites), add an optional 'preview' sub-step in Phase 3 (around line 470): edit ONE representative call site, run `git diff` on it, confirm the mechanical pattern is correct, then fan out to the rest. In batch/…
- **[M/M · src:confirmed] No mechanism to flag call sites the refactor could not safely transform**  
  _Martin Fowler — 'Refactoring with Codemods to Automate API Changes'_ — https://martinfowler.com/articles/codemods-api-refactoring.html  
  Add a 'partial-site marker' convention: when an individual call site cannot be safely auto-transformed (dynamic dispatch, reflection, string-keyed access, generated code), insert '// TODO(zuvo:refactor): manual update needed — <reason>' at that site, record it in the contract progress[] and backlog…

### `release-docs`  (3 verified, 0 rejected)

- **[H/M · src:confirmed] Produce user-facing release notes, not just a developer changelog, from the same change set**  
  _LaunchNotes (release-notes-vs-changelog guidance)_ — https://www.launchnotes.com/blog/release-notes-vs-changelog-understanding-the-key-differences-and-when-to-use-each  
  Add an optional --release-notes flag/Phase that reads the verified CHANGELOG entry for the range and emits zuvo/reports/release-notes-<range-suffix>.md: group changes by user impact, rewrite each Added/Fixed/Changed entry into benefit-oriented language, and drop internal-only entries. Keep human-re…
- **[M/M · src:confirmed] Label/category-driven grouping of release entries (configurable categories, exclude-internal)**  
  _GitHub automatically generated release notes_ — https://docs.github.com/en/repositories/releasing-projects-on-github/automatically-generated-release-notes  
  When deriving the range, also collect merged-PR labels (or conventional-commit types) via gh, and use a configurable category map (extend docs-map.yaml) to (a) group the optional release-notes output into sections and (b) exclude internal-only labels (chore, ci, refactor) from any user-facing surfa…
- **[M/L · src:unreachable] Compute a 0-100 staleness/drift score instead of a binary changed/unchanged decision**  
  _Documentation Drift Detector (Claude Code Skill, mcpmarket)_ — https://mcpmarket.com/tools/skills/documentation-drift-detector  
  In Phase 4, replace the binary documented/undocumented split with a 0-100 staleness score per doc (structural drift from signature changes via get_type_info/diff_outline, factual drift from behavior/claim changes, referential drift from broken refs/links). Emit the score in the COMPLETE block and a…

### `retro`  (3 verified, 0 rejected)

- **[H/M · src:confirmed] Retro reports only the throughput half of DORA, omitting the two stability metrics**  
  _DORA (DevOps Research and Assessment) — dora.dev official metrics guide_ — https://dora.dev/guides/dora-metrics/  
  Add a 'Stability' subsection to Phase 1: compute Change Fail Rate from revert/hotfix/rollback commits in the window (git log --grep='revert|hotfix|rollback' across release tags) plus incident postmortems in zuvo/reports/incident-*.md, and a Deployment Rework Rate from unplanned releases. Present ve…
- **[H/M · src:confirmed] No follow-through check: prior retro's action items are never re-examined**  
  _Retrospective facilitation practice — Age-of-Product ('Unfinished Action Items')_ — https://age-of-product.com/action-items-retrospectives/  
  Add a 'Carry-Over / Follow-Through' step to Phase 5: parse the prior retro's Actionable Items table, then verify each via cheap git evidence (write-tests item -> does the cited test file now exist; refactor item -> did the churn file change since). Mark each DONE / NOT DONE / STILL-OPEN, surface a …
- **[M/M · src:unreachable] Action items lack owner / due date / priority / status structure**  
  _Blameless retrospective & post-incident-review best practice (IT Leadership Hub)_ — https://itleadershiphub.com/best-practices/blameless-post-incident-review/  
  Convert Phase 4 and the report's Actionable Items into a table: # | Action (zuvo command) | Why (data-derived) | Priority (from severity) | Suggested Owner (default: last committer of the cited churn file via git log -1 --format='%an' -- <file>) | Target Date (+next retro window) | Status (OPEN). P…

### `review`  (3 verified, 0 rejected)

- **[H/M · src:confirmed] Persistent 'Learnings' loop: remember rejected findings and suppress that class on future reviews**  
  _CodeRabbit_ — https://www.coderabbit.ai/blog/how-coderabbit-delivers-accurate-ai-code-reviews-on-massive-codebases  
  Add a 'review-learnings' store (extend the existing shared/includes/knowledge-curate.md JSONL — it already has an 'anti-pattern' type, an 'affectedFiles' glob array, and a 'coderabbit' provenance source, so this is an extension not a new system) keyed by file-glob + rule-id + finding-signature. Whe…
- **[H/M · src:confirmed] Generate an executable proof-check (grep/ast-grep/CodeSift) to confirm a finding BEFORE reporting it**  
  _CodeRabbit_ — https://www.coderabbit.ai/blog/how-coderabbit-delivers-accurate-ai-code-reviews-on-massive-codebases  
  Add a Phase 1.5b 'Proof-Check' step: for every MUST-FIX and high-confidence RECOMMENDED, the lead/auditor runs one deterministic check (grep/ast-grep/CodeSift search_patterns or trace_call_chain) whose output substantiates the asserted DEFECT (not just the line's existence), recorded in the finding…
- **[M/M · src:contradicted] Report and trend a first-class false-positive rate as a review-quality metric**  
  _Greptile / CodeRabbit (AI code review benchmark category)_ — https://www.devtoolsacademy.com/blog/state-of-ai-code-review-tools-2025/  
  Add an FP-rate field to the Validity Gate + Run line: on a later 'tag'/'wontfix' cycle, compute dismissed_findings / reported_findings for the prior review and append 'fp_rate=X%' to ~/.zuvo/runs.log. Surface a rolling FP-rate in retrospective.md (which already has a 'false-positive-rule' friction …

### `security-audit`  (3 verified, 0 rejected)

- **[H/M · src:confirmed] Emit SARIF 2.1.0 alongside markdown/JSON so findings flow into CI code-scanning dashboards**  
  _SARIF 2.1.0 (OASIS standard) / GitHub code scanning, Sonar, Checkmarx One_ — https://docs.github.com/en/code-security/concepts/code-scanning/sarif-files  
  Add an optional SARIF 2.1.0 emitter in Phase 10.2 (--sarif or always-on artifact at zuvo/audits/artifacts/security/results.sarif): map each SEC-NNN finding to a SARIF result (ruleId=dimension+finding_type, level from severity, location from File:line, message from Impact, properties.cwe/owasp/secur…
- **[H/M · src:confirmed] Do function-level reachability on dependency CVEs (does the app CALL the vulnerable function), not grep 'directly imported?'**  
  _SCA reachability analysis (Black Duck, Endor Labs, Xygeni) — function/call-graph level_ — https://www.blackduck.com/blog/vulnerability-reachability-in-sca.html  
  Upgrade Phase 1.1: for each CRITICAL/HIGH CVE, extract the affected function/class from the advisory and run trace_call_chain/find_references from app code to that symbol. Tier each CVE: REACHABLE (keep full severity), PRESENT-NOT-REACHED (downgrade to Needs Verification), DYNAMIC/UNRESOLVED (cap M…
  ⚠️ _CAVEAT:_ the cited page does NOT contain the 70-95% / 71-88% false-positive figures the researcher quoted — those are unsupported by this source and should be dropped or re-sourced before citing
- **[M/L · src:confirmed] Map findings and target a coverage level against OWASP ASVS 5.0 (L1/L2/L3), not just OWASP Top 10 + CWE**  
  _OWASP Application Security Verification Standard (ASVS) 5.0.0 (May 2025)_ — https://owasp.org/www-project-application-security-verification-standard/  
  Add --asvs-level L1|L2|L3 (default L2). Carry an asvs_id (e.g. V5.1.3) on findings where a control maps, and add an 'ASVS Coverage' table reporting per ASVS chapter: verified / failed / not-applicable / not-assessed — producing a real verification statement, not just a vuln list. Anchor DEEP-tier s…
  ⚠️ _CAVEAT:_ this specific page does NOT enumerate the L1/L2/L3 levels — the tiering claim is real ASVS knowledge but not evidenced by the cited URL; the level table would need the ASVS doc itself as source

### `seo-audit`  (5 verified, 0 rejected)

- **[H/M · src:confirmed] CrUX field-data Core Web Vitals as the ranking signal, distinct from Lighthouse lab scores**  
  _PageSpeed Insights / CrUX dataset (NoGood + digitalapplied 2026 checklists)_ — https://nogood.io/blog/technical-seo-checklist/  
  Add a CrUX field-data step to D8: query the public CrUX API (or PageSpeed Insights API which returns loadingExperience field data) for the live URL, report field INP/LCP/CLS mobile p75 separately from lab values, and add a Source-vs-Field note. When field and lab disagree, prefer field for D8 scori…
- **[H/L · src:confirmed] Outcome-based GEO: live multi-engine citation rate, share-of-voice, and hallucination detection**  
  _GEO audit methodology (ailabsaudit) / Profound, Semrush AI, Conductor_ — https://ailabsaudit.com/blog/en/geo-audit-generative-ai-visibility  
  Add an optional outcome-mode (e.g. --ai-visibility "<brand>" "<competitor1,competitor2>") that runs a small prompt set via WebSearch/available LLM connectors, computes citation rate / mention rate / share-of-voice / sentiment, and flags hallucinated URLs by fetching every cited URL (404 => hallucin…
- **[M/M · src:confirmed] Reverse-DNS bot verification before trusting user-agent in the Bot Policy Matrix**  
  _Google documented two-step verification / digitalapplied + Screaming Frog Log Analyser_ — https://www.digitalapplied.com/blog/log-file-analysis-technical-seo-2026-crawl-budget-reference  
  When --log-file is used, add a per-bot 'verified|spoofed|unverifiable' column to the Bot Policy Matrix using reverse-DNS forward-confirm for Googlebot/Bingbot and the published IP-list JSON (claude.com/crawling/bots.json) for AI bots that lack reverse DNS. Record verification_mode='log-verified' in…
- **[M/M · src:confirmed] JS-rendered vs raw-HTML crawl diff at route scale (not just JSON-LD)**  
  _Screaming Frog JavaScript rendering mode (digitalapplied 50-point checklist)_ — https://www.digitalapplied.com/blog/technical-seo-audit-2026-50-point-checklist  
  Generalize the Source-vs-Render diff in Phase 3.2 beyond JSON-LD/meta: for each sampled route, diff visible text length, H1/H2 set, and internal-link count between raw fetch (no JS) and rendered DOM; flag routes with significant raw-vs-rendered divergence as a content-invisibility risk feeding D9/D…
- **[M/L · src:confirmed] Server log-file analysis for crawl budget and crawl-waste (new dimension)**  
  _Screaming Frog SEO Log File Analyser / digitalapplied 2026 crawl-budget reference_ — https://www.digitalapplied.com/blog/log-file-analysis-technical-seo-2026-crawl-budget-reference  
  Add an optional D14 'Crawl Efficiency (log-based)' dimension gated behind a new --log-file <path> / --access-log flag. When provided, group requests by URL template to compute crawl-waste %, list templates consuming disproportionate budget, flag sustained 503s, surface 410-vs-404 hygiene, and emit …

### `seo-fix`  (3 verified, 0 rejected)

- **[M/S · src:confirmed] llms.txt spec defines a special `## Optional` section that we never emit**  
  _llmstxt.org (official llms.txt specification)_ — https://llmstxt.org/  
  In the `llms-txt-add` generation block (SKILL.md ~lines 293-329), route low-value/secondary pages (changelogs, legal, low-priority reference — the same set already down-ranked for the 500KB cap) into a dedicated `## Optional` H2 section per the spec, instead of folding them all into `## Docs`. Add …
- **[M/M · src:confirmed] Post-fix JSON-LD re-check is a grep, not validation against schema.org required properties**  
  _TestSprite (AI structured-data testing) / Google Rich Results & Schema Markup Validator_ — https://www.testsprite.com/use-cases/en/the-best-schema-checker-tools  
  Add structural schema.org validation to the Phase 3.3 `json-ld-add`/`schema-cleanup` RE-CHECK (line 476): after injection, parse the JSON-LD, resolve @type, and assert schema.org-required properties for that type are present (e.g. Organization.name/url, Article.headline/author/datePublished). On a …
- **[M/M · src:confirmed] Live AI-bot UA probing trusts a spoofable User-Agent with no reverse-DNS / IP-range confirmation**  
  _AI User-Agent Landscape 2026 reference (No Hacks)_ — https://nohacks.co/blog/ai-user-agents-landscape-2026  
  Add a `verify_method` column/note to seo-bot-registry.md (reverse-DNS PTR pattern such as `*.googlebot.com` / `*.applebot.apple.com`, or vendor IP-range JSON) and have the `robots-fix` live-probe path (SKILL.md line 478) label any UA-string-only probe result as ESTIMATED rather than VERIFIED, recom…

### `ship`  (4 verified, 0 rejected)

- **[H/S · src:confirmed] Ship creates a lightweight unsigned tag; release-grade tags should be annotated/signed**  
  _git (official git-tag documentation)_ — https://git-scm.com/docs/git-tag/2.27.0  
  Change Phase 4 Step 3 from `git tag v<version>` to an annotated tag `git tag -a v<version> -m "release: v<version>"`, embedding the CHANGELOG section summary as the tag message. Add an optional `--sign-tag` flag (or auto-detect a configured user.signingkey) to emit `git tag -s`, and record `tagSign…
- **[M/M · src:confirmed] No build provenance / attestation linking the release commit+tag to a verifiable build**  
  _GitHub Actions Artifact Attestations (SLSA provenance)_ — https://docs.github.com/en/actions/concepts/security/artifact-attestations  
  Add a Phase 4 provenance step gated behind `--attest` (or CI auto-detection): under GitHub Actions, emit `actions/attest-build-provenance` for the release artifact; otherwise write a minimal in-toto-style provenance JSON (subject=releaseCommitSha, builder=zuvo:ship+env, materials=BASE_REF..RELEASE_…
- **[M/L · src:confirmed] PR flow opens a one-shot PR instead of maintaining a continuously-updated Release PR**  
  _release-please (googleapis/release-please)_ — https://github.com/googleapis/release-please  
  Add a `--release-pr` mode maintaining ONE idempotent Release PR per release line: detect an existing open 'release: vX' PR/branch and, if present, update its bump + regenerated CHANGELOG section in place reusing the same PR number instead of opening a new one. Defer tag+push to the merge of that PR…
- **[L/S · src:confirmed] Conventional-commit bump mapping is implemented but the triggering commits are never surfaced — bump decision is unauditable**  
  _release-please / Conventional Commits + SemVer_ — https://github.com/googleapis/release-please  
  In Phase 3, always compute and PRINT the bump rationale: the highest-impact prefix found and the exact commit subject(s)/SHAs that triggered the chosen bump (e.g. 'major triggered by: <sha> feat!: ...'). Keep the >=50%-conventional gate for AUTO-apply, but emit the mapping table + triggering commit…

### `structure-audit`  (4 verified, 0 rejected)

- **[H/M · src:confirmed] Add cognitive complexity alongside cyclomatic for SA9 maintainability scoring**  
  _SonarSource Cognitive Complexity_ — https://www.sonarsource.com/resources/cognitive-complexity/  
  Add a cognitive-complexity sub-metric to SA9: +1 for breaks in linear flow, +1 per nesting level, no increment for shorthand. Report cyclomatic AND cognitive per top-N function; flag/gate on cognitive (>15) for maintainability instead of cyclomatic alone. Use CodeSift if it exposes the metric; othe…
- **[H/L · src:confirmed] Emit codified, executable architecture fitness functions (ArchUnitTS / dependency-cruiser) instead of one-shot greps**  
  _ArchUnitTS_ — https://github.com/LukasNiessen/ArchUnitTS  
  When stack is JS/TS and SA6 finds a confirmed layer violation, optionally scaffold an ArchUnitTS spec (or a .dependency-cruiser.js rule) encoding the violated rule, converting the finding into an executable CI guardrail. Mirror the F1-F7 catalogue to ArchUnitTS predicates (noDependOnLayer, beFreeOf…
- **[M/M · src:confirmed] Fuse a single CodeHealth-style composite score per hotspot (complexity + cognitive load + maintainability)**  
  _CodeScene CodeHealth_ — https://codescene.com/product/behavioral-code-analysis  
  Compute a per-file composite (0-10) from cyclomatic + cognitive complexity + file-size/SA7 + duplication density, then rank the SA13 hotspot table by (low health x high churn). Flag low-health + top-decile-churn files as the primary Top 5 Action Items. Pick a threshold from our own calibration rath…
  ⚠️ _CAVEAT:_ the researcher's '<8' threshold is researcher-added — WebFetch confirms the page does NOT state any numeric threshold; do not cite '8' as sourced
- **[M/M · src:confirmed] Add module cohesion (LCOM) and distance-from-main-sequence metrics to SA6**  
  _ArchUnitTS code metrics_ — https://lukasniessen.github.io/ArchUnitTS/  
  Add an LCOM-style cohesion sub-check to SA6 for classes/modules (flag high LCOM, e.g. >0.3 for tight cohesion) plus a distance-from-main-sequence reading per module (via CodeSift instability/abstractness if available, else ArchUnitTS), surfacing 'incohesive but not oversized' modules that SA7 file-…

### `test-audit`  (4 verified, 0 rejected)

- **[H/S · src:confirmed] Canonical tsDetect catalog includes smells our AP list omits (Mystery Guest, Resource Optimism, Sensitive Equality, Constructor Initialization, Ignored Test)**  
  _tsDetect / testsmells.org (canonical academic test-smell catalog, 19 smells)_ — https://testsmells.org/pages/testsmells.html  
  Add the canonical smells our AP1-AP26 catalog omits, mapped to tsDetect names in rules/test-quality-rules.md: AP27 Mystery Guest (test reads real file/DB/network instead of mock/fixture), AP28 Resource Optimism (test assumes external resource exists without guard), AP29 Sensitive Equality (assertio…
- **[H/M · src:unreachable] No dedicated flaky-test / non-determinism dimension despite it being the dominant test-quality failure mode**  
  _Flaky-test empirical literature (Luo et al. taxonomy; multivocal review, Inf. & Softw. Tech.)_ — https://www.sciencedirect.com/science/article/pii/S0164121223002327  
  Add a FLAKE cluster covering: unseeded randomness (Math.random/Date.now/faker without fixed seed — distinct from AP26 which is only fake-timer absence), order-sensitive assertions on inherently unordered data (Set/Map/DB rows), exact float equality (toBe on floats vs toBeCloseTo), and real network/…
- **[H/M · src:unreachable] No suite-level order-dependency / shared-state-leak detection**  
  _Order-dependency flaky-test research (Python/JS empirical studies)_ — https://www.sciencedirect.com/science/article/pii/S0164121223002327  
  Add Q18 'No shared mutable state leaks across tests' — flag module-level mutable vars written inside tests, missing afterEach cleanup of temp files / global mocks, and in-place fixture mutation. In Phase 0, recommend one randomized-order run (jest --shuffle / pytest-randomly) as a cheap order-depen…
- **[M/S · src:confirmed] Red-flag pre-scan does not exploit empirical priors for LLM-generated tests (our primary use case)**  
  _'On the Diffusion of Test Smells in LLM-Generated Unit Tests' (arXiv 2410.10628)_ — https://arxiv.org/html/2410.10628  
  Tune the RED FLAG PRE-SCAN for LLM suites: add a 'Lazy Test' check (N tests all exercising the same single production method) which is genuinely absent today, and elevate Q7 (exception-path coverage) into the pre-scan since EH is only 7-23% in LLM output. Optionally add a --llm-generated flag apply…

### `tests-performance`  (4 verified, 0 rejected)

- **[H/M · src:confirmed] CI test sharding (--shard) is absent — TP4 only covers in-process workers, missing the biggest lever for large suites**  
  _Vitest official guide + Jest 28 --shard_ — https://vitest.dev/guide/improving-performance  
  Add a TP item (e.g. TP18 'CI sharding') that detects suite size + CI runner count and recommends jest/vitest --shard with merge-reports/blob reporter, including the exact split command and a note that splitting is by file (so one giant file caps a shard — cross-link to Phase 3 slow-file output to b…
- **[H/M · src:confirmed] Test impact analysis (run only affected tests) is absent — no --changed / --onlyChanged / --findRelatedTests guidance**  
  _Jest CLI (--onlyChanged/--findRelatedTests) + Vitest --changed/related_ — https://buildpulse.io/blog/how-to-speed-up-vitest  
  Add a TP item (e.g. TP19 'Affected-test selection') that checks whether dev/PR scripts use --changed/--onlyChanged (Vitest/Jest) or pytest-testmon, and recommends a watch/pre-commit/PR-CI script that runs only related tests while full runs stay on main/nightly. Distinguish from full-suite optimizat…
- **[M/S · src:confirmed] Built-in slow-test threshold flagging would make Phase 3 deterministic instead of manual**  
  _Vitest slowTestThreshold / verbose-reporter slow flagging_ — https://buildpulse.io/blog/how-to-speed-up-vitest  
  In Phase 2/3, add an item recommending a configured slow-test threshold (Vitest slowTestThreshold config / verbose reporter; for the CLI use the actual config key, not buildpulse's '--slow 500' shorthand) so regressions are flagged on every run, and feed that signal into Phase 3 classification auto…
- **[L/S · src:confirmed] Vitest experimental.fsModuleCache is a newer, more specific cache than generic TP9**  
  _Vitest experimental.fsModuleCache_ — https://vitest.dev/guide/improving-performance  
  Under TP9/TP12 for Vitest, explicitly check for and recommend experimental.fsModuleCache for large module graphs, with the caveat that it is experimental (verify with before/after measurement per Core Principle 5).

### `ui-design-team`  (3 verified, 0 rejected)

- **[H/M · src:confirmed] Run axe-core via Playwright as a deterministic WCAG gate, tagged by success criterion**  
  _Playwright + @axe-core/playwright_ — https://playwright.dev/docs/accessibility-testing  
  In Step 1/Step 2, when a live URL or rendered page is available (--screenshot path, chrome-devtools, or the mcp-accessibility-scanner present in this environment), Agent 4 should run an actual a11y engine (axe-core via Playwright, or accessibility-scanner scan_page/scan_page_matrix) and attach mach…
- **[M/M · src:confirmed] Use ARIA snapshots as a styling-resilient structural/accessibility regression check**  
  _Playwright ARIA snapshots / @playwright/mcp accessibility tree_ — https://playwright.dev/docs/accessibility-testing  
  On the rendered-page path, capture a Playwright/MCP ARIA snapshot (browser_snapshot accessibility tree) of the reviewed component and store it under zuvo/audits as the a11y baseline. On --fix verification (Step 5) and re-runs, diff the new ARIA snapshot against the baseline so the skill determinist…
- **[M/M · src:confirmed] Add a pixel-diff visual-regression baseline to verify --fix didn't break the layout**  
  _Chromatic / Percy (BrowserStack)_ — https://crosscheck.cloud/blogs/percy-vs-applitools-vs-chromatic-visual-regression-testing/  
  In Step 5, BEFORE applying --fix, capture before-screenshots at 375px/1024px as a baseline; AFTER fixing, run a pixel diff (chrome-devtools screenshots + an image-diff step, or git-aware baselines under zuvo/audits) and report changed regions. Adopt Percy's noise-reduction lesson: surface bounding …

### `using-zuvo`  (4 verified, 1 rejected)

- **[H/M · src:confirmed] Confidence-tiered routing with an explicit ambiguity band**  
  _TianPan.co — The Intent Classification Layer Most Agent Routers Skip_ — https://tianpan.co/blog/2026-04-16-intent-classification-agent-routers  
  Add a 'Routing Confidence' section: when ≥2 routing-table rows plausibly match OR the message mixes verbs from different tiers, treat the route as LOW confidence and emit a one-line disambiguation ('This matches zuvo:refactor and zuvo:security-audit — which?') instead of silently committing. Reserv…
- **[H/M · src:confirmed] Multi-intent decomposition for compound requests**  
  _Patronus AI — AI Agent Routing: Tutorial & Best Practices_ — https://www.patronus.ai/ai-agent-development/ai-agent-routing  
  Add a 'Compound Requests' rule to How Routing Works: first ask 'does this message contain more than one distinct intent?' If yes, enumerate each intent, route each to its skill, and sequence them (audit before fix, research before write) — surfacing the planned chain to the user before executing.
- **[M/S · src:confirmed] Explicit no-match fallback / default route**  
  _Patronus AI — AI Agent Routing: Tutorial & Best Practices_ — https://www.patronus.ai/ai-agent-development/ai-agent-routing  
  Define an explicit DEFAULT/fallback row (e.g. 'No skill matched AND task involves reading/writing code → confirm scope, then offer zuvo:build or direct handling per Boundary rules'). Make 'proceed normally' a deliberate, scoped fallback rather than an escape hatch, removing the contradiction with t…
- **[M/M · src:confirmed] Routing-decision observability / traces**  
  _Patronus AI — AI Agent Routing: Tutorial & Best Practices_ — https://www.patronus.ai/ai-agent-development/ai-agent-routing  
  Have using-zuvo append a one-line routing-decision trace to the run log on each non-trivial route: matched-intent, chosen skill, confidence tier, and runner-up. This feeds zuvo:retro / context-audit so router misclassification becomes a measurable, improvable signal distinct from skill quality.

  _rejected:_ Direct-handle vs delegate as an explicit cost criterion (hallucinated-source)

### `worktree`  (5 verified, 0 rejected)

- **[H/S · src:confirmed] Declarative copy hooks to seed gitignored config (.env) into fresh worktrees**  
  _wtp (satococoa/wtp) — .wtp.yml post-create hooks_ — https://github.com/satococoa/wtp  
  Add a CREATE step (after Step 4 dependency setup, before Step 5 baseline) that copies gitignored config files into the new worktree. Detect candidates via a `.worktreeinclude`-style list or by scanning .gitignore for .env*/local-config patterns, copy them from the main checkout, and report exactly …
- **[M/S · src:confirmed] Secrets boundary: copy local config but never copy .env secrets between worktrees**  
  _Abubakar Siddiq Ango — 'Git Worktrees for Parallel AI Coding'_ — https://abuango.me/blog/git-worktrees-for-ai-coding-tools/  
  Gate the config-copy step from finding 1: copy non-secret local config, but flag any file matching secret patterns (.env containing API keys, *.pem, credentials/*) and prefer a runtime secrets-manager note over physically duplicating secrets across worktree dirs. Add a one-line note in Safety Rules.
- **[M/S · src:confirmed] Prune/repair stale worktree metadata when a dir was deleted manually**  
  _gitworktree.org best practices (git worktree prune)_ — https://www.gitworktree.org/guides/best-practices  
  Add a self-heal step in FINISH (and a note in Safety Rules): when `git worktree remove` fails because the dir is already gone, run `git worktree prune` to clear dangling metadata. Optionally preview state first via `git worktree list`.
- **[M/M · src:confirmed] Symlink large dirs (node_modules) or rely on pnpm store instead of reinstalling per worktree**  
  _wtp symlink hooks + gitworktree.org (pnpm content-addressable store)_ — https://github.com/satococoa/wtp  
  In Step 4, before installing: if pnpm is in use, note its store already dedups so install is cheap. Otherwise offer a symlink option for node_modules/vendor to the main checkout for read-mostly cases, falling back to full install when the lockfile differs between branches. Report which path was tak…
- **[M/M · src:confirmed] PR-status-driven cleanup of merged/closed worktrees**  
  _git-worktree-runner (coderabbitai/gtr) — `git gtr clean`_ — https://github.com/coderabbitai/git-worktree-runner  
  Add a FINISH sub-mode (or `--sweep` flag) that lists all worktrees via `git worktree list`, queries `gh pr view <branch> --json state` per branch, and offers to remove worktrees whose PR is MERGED/CLOSED plus prune empties — with per-item confirmation, never auto-destroying unmerged work.

### `write-article`  (3 verified, 0 rejected)

- **[H/S · src:confirmed] Weight GEO tactics by measured per-domain effectiveness (Princeton GEO study), not uniformly**  
  _GEO: Generative Engine Optimization (Aggarwal et al., KDD 2024, arXiv:2311.09735)_ — https://arxiv.org/html/2311.09735v3  
  Add a 'GEO tactic priority' field per niche in domain-profile-registry.md sourced from the paper's per-domain results (factual/law -> Cite Sources first; history/explanation/people&society -> Quotation Addition first; law/opinion -> Statistics Addition). Phase 3 step 6 reads this to choose which ci…
- **[M/M · src:confirmed] Adopt a deterministic, syntax-aware prose linter (Vale) as a pre-LLM anti-slop gate**  
  _Vale (vale.sh) — open-source markup-aware prose linter_ — https://vale.sh/docs  
  Add an optional deterministic pre-pass in Phase 4: ship the hard/soft banned-vocabulary lists as a Vale style package, existence-check `vale` in PATH and graceful-skip if absent per env-compat pattern. Run Vale first to catch exact-match banned terms + sentence-length/readability deterministically,…
- **[M/M · src:confirmed] Add a reader-facing AI/automation provenance disclosure + Who/How/Why self-check gate**  
  _Google Search Central — Creating Helpful, Reliable, People-First Content_ — https://developers.google.com/search/docs/fundamentals/creating-helpful-content  
  Add a Phase 5 'provenance' step: optionally emit a reader-facing author/method note (or schema `author` + a short editorial-process line) and run a Who/How/Why self-check gate before ARTICLE COMPLETE — confirm first-hand/experience signals or clear source attribution, and flag YMYL pieces lacking a…

### `write-e2e`  (7 verified, 0 rejected)

- **[H/M · src:confirmed] Codegen generates assert visibility / assert text / assert value tied to real element state during recording**  
  _Playwright Test Generator (codegen) — official docs_ — https://playwright.dev/docs/codegen  
  In --record/--live mode, capture codegen-style assert-visibility/text/value triplets for a flow's terminal state and emit them as the spec's web-first assertions, upgrading E2E-Q4 (user-visible assertions) from 'flag only' to satisfiable with evidence-backed assertions.
- **[H/L · src:confirmed] Codegen records real user actions and emits verified locators + assertions the static generator cannot confirm**  
  _Playwright Test Generator (codegen) — official docs_ — https://playwright.dev/docs/codegen  
  Add a --record sub-mode to --live that drives Playwright codegen (or the Playwright MCP browser snapshot/accessibility tree) over a selected flow, captures the actual rendered locators and assertion steps, then rewrites them into the POM/quality-gate-compliant template. Converts the diagnose-only P…
- **[M/S · src:confirmed] Soft assertions (expect.soft) collect multiple failures per test instead of aborting on first**  
  _Playwright Best Practices — official docs_ — https://playwright.dev/docs/best-practices  
  Add a template + guidance to use expect.soft() for grouped post-action verification blocks (multi-field confirmation screens; API field validation in E2E-Q9), closed by a final hard assertion. Add an E2E-Q gate note recommending soft assertions when 2+ independent visible fields are checked.
- **[M/S · src:confirmed] 2026 best practice: prefer accessibility-tree (role/label) locators over testid/CSS because they change less**  
  _Playwright AI ecosystem 2026 / self-healing locators (TestDino)_ — https://testdino.com/blog/playwright-ai-ecosystem  
  Qualify the strict locator priority (line 313): when a stable accessible role+name exists, prefer getByRole over a data-testid that does NOT yet exist in production. Keep testid first only when it already exists in source. Document the rationale and reduce the volume of TestID Suggestions that ask …
- **[M/M · src:confirmed] Built-in visual regression via toHaveScreenshot baseline comparison**  
  _Playwright Visual Comparisons — official docs_ — https://playwright.dev/docs/test-snapshots  
  Add an optional --visual flag that, for high-traffic / low-mutation flows (static/marketing pages currently tiered SKIP at score 0-14), generates a toHaveScreenshot() spec with a configurable maxDiffPixels tolerance and notes baseline generation. Add E2E-Q11 (visual baseline present for visual spec…
  ⚠️ _CAVEAT:_ researcher's quote claimed 'maxDiffPixels / maxDiffPixelRatio' but the page documents only maxDiffPixels — maxDiffPixelRatio is NOT on this page; drop that param from the proposal
- **[M/M · src:confirmed] Codegen exposes device / dark-mode / locale / geolocation / timezone emulation flags**  
  _Playwright Test Generator (codegen) — official docs_ — https://playwright.dev/docs/codegen  
  Add an optional --matrix flag (or playwright.config project entries) that, for CRITICAL flows, emits parameterized projects for a mobile device, dark color-scheme, and a non-default locale, mirroring codegen's emulation flags. At minimum, suggest these projects in the proposed playwright.config dif…
- **[L/S · src:confirmed] Config-level sharding to distribute the suite across CI machines**  
  _Playwright Best Practices — official docs_ — https://playwright.dev/docs/best-practices  
  When proposing playwright.config.ts (Phase 2), include workers/fullyParallel defaults and a commented GitHub Actions matrix using --shard=${i}/${n}; emit a note in the completion report when generated spec count crosses a threshold (e.g. >15) recommending sharding.

### `write-tests`  (2 verified, 1 rejected)

- **[H/M · src:confirmed] No empirical coverage-delta gate: each generated test should be proven to increase measured coverage, not just judged 'good' by an LLM**  
  _Meta TestGen-LLM / Qodo Cover (qodo-cover)_ — https://www.qodo.ai/blog/we-created-the-first-open-source-implementation-of-metas-testgen-llm/  
  Add an optional empirical coverage-delta sub-step between Step 2 (Write) and Step 3 (Verify): run the stack's coverage runner (vitest --coverage / jest --coverage / pytest --cov / phpunit --coverage-text) once on the target before writing and once after; require new tests to increase covered lines/…
- **[M/L · src:confirmed] Mutation-kill delta, not just line coverage, as inline acceptance signal — write-tests enumerates MUTATION TARGETS but never verifies they are killed; defers entirely to the separate mutation-test skill**  
  _Atlassian (Automating Mutation Coverage with AI)_ — https://www.atlassian.com/blog/development/automating-mutation-coverage-with-ai  
  For COMPLEX-tier files (or behind a --mutation-gate flag), add a lightweight inline mutation check after Step 4: apply the MUTATION TARGETS already enumerated in the Step 2 test contract (boundary flip, condition inversion, null return, error-path removal) to the target file and assert the new test…

  _rejected:_ Self-document write-tests' existing defense against the 'observed-behavior-as-oracle' bug-reinforcement trap — it is a category differentiator worth making explicit (not-missing)
