# Zuvo Competitive Analysis — April 2026

> Comprehensive review of the AI coding tools ecosystem. 70+ competitors analyzed across Claude Code plugins, Cursor extensions, Codex/Windsurf/Copilot ecosystems, and DevOps trends.
> Last updated: 2026-04-08

---

## Executive Summary

Zuvo's 48-skill depth across audits, testing, security, deployment, design, pipeline management, knowledge accumulation, and session recovery is **unmatched per-skill** in the plugin ecosystem. No competitor offers this depth with structured multi-agent workflows, adversarial review (4 providers), quality gates (CQ1-CQ28, Q1-Q19), evidence enforcement, knowledge store, and cross-platform support (Claude Code + Codex + Cursor).

**Where Zuvo leads:**
- Full SDLC pipeline (brainstorm > plan > execute > ship > deploy > canary > retro)
- 10+ audit dimensions with evidence-based scoring and tiered output
- Adversarial multi-provider review (4 providers) — unique in the ecosystem
- Knowledge Store v3 (JSONL, timesSurfaced/confidence separation, recency ranking, merge rules)
- Session Recovery with validation, precedence, stale detection
- Evidence enforcement (auto-downgrade findings without file:line)
- Unified severity vocabulary across all 48 skills
- Cross-platform build system from single source

**Where Zuvo trails:**
- Visibility/distribution: 1 star vs 128K (everything-claude-code), 42K (superpowers)
- Not on Skills.sh (87K+ skills indexed, 17 platforms) or Anthropic official marketplace
- No viral proof point (metaswarm: "127 PRs in a weekend", Claw Code: 50K stars in 2h)
- Event-driven automations (Cursor 3 Agents Window)
- Closed-loop review-to-fix pipelines (Copilot, BugBot)
- Issue-to-PR zero-friction workflows (Copilot Cloud Agent, Jules, Devin 2.0)

---

## Part 1: Direct Competitors

### Tier 1 — Major Skill Libraries

| Competitor | Stars | Skills | Strengths | Zuvo advantage |
|-----------|-------|--------|-----------|----------------|
| **alirezarezvani/claude-skills** | 9,803 | 248 | Breadth (marketing, product, compliance, C-level), 332 Python CLI tools, personas, orchestration protocol | Deeper per-skill workflows, adversarial review, quality gates, pipeline enforcement |
| **trailofbits/skills** | 4,341 | 35+ | Gold standard security (Semgrep, CodeQL, smart contracts, 6 blockchains), Trophy Case of real bugs found | Broader coverage beyond security, full SDLC pipeline |
| **EveryInc/compound-engineering** | 13,415 | ~10 | Viral brand ("compound engineering"), structured engineering workflow | More skills, audit depth, adversarial review |
| **jeremylongshore/plugins-plus-skills** | 1,859 | 1,367 | Quantity, own package manager (CCPI) | Quality > quantity, structured workflows |
| **wondelai/skills** | 445 | 40 | Book-as-skill methodology (Clean Code, DDD, etc.) | Actionable audits vs theoretical frameworks |
| **Anthropic-Cybersecurity-Skills** | 4,077 | 754 | 26 security domains, 5 framework mappings (MITRE, NIST, ATLAS) | Broader than security, integrated pipeline |

### Tier 1b — Major New Competitors (discovered 2026-04-08)

| Competitor | Stars | Skills/Agents | Strengths | Zuvo advantage |
|-----------|-------|---------------|-----------|----------------|
| **affaan-m/everything-claude-code** | 128,000 | 136 skills, 30 agents | Massive stars, breadth | Depth unknown — needs audit. Zuvo's per-skill depth (CQ/Q gates, evidence) likely unmatched |
| **obra/superpowers** | 42,000 | TDD, debug, brainstorm, review | In official Anthropic marketplace (Jan 15, 2026), 6+ platforms | Zuvo has 48 skills vs ~10, adversarial review, knowledge store |
| **ruvnet/ruflo** (ex Claude Flow) | 25,000 | 60+ agents, 314 MCP tools | MCP-native, self-learning, v3.5 (Apr 7) | Zuvo's structured CQ/Q gates vs generic quality checks |
| **dsifry/metaswarm** | ~500 | 18 agents, 13 skills | BEADS task tracking, 9 formal rubrics, "127 PRs in a weekend" proof point | Zuvo has 48 vs 13 skills, knowledge store v3, evidence enforcement |
| **levnikolaevich/claude-code-skills** | ~1,000 | 6 plugins + MCP servers | Bundled MCP: hex-line (hash editing), hex-graph (code knowledge graph), hex-ssh (remote) | Zuvo has deeper skills, more audit dimensions |

### Tier 2 — Workflow/Orchestration Competitors

| Competitor | Stars | Focus | Zuvo advantage |
|-----------|-------|-------|----------------|
| **claude-mem** | 45,887 | Session memory persistence | Zuvo solves a different problem (quality engineering) |
| **nyldn/claude-octopus** | 2,423 | Multi-model review (up to 8 models) | Zuvo's adversarial review is deeper (modes, meta-review, confidence scoring) |
| **rohitg00/pro-workflow** | 1,554 | Self-correcting memory, 17 skills | Zuvo has 2x+ skills with deeper workflows |
| **revfactory/harness** | 2,024 | Meta-skill: designs agent teams | Zuvo already HAS the teams built |
| **agent-sh/agentsys** | 699 | 40 skills, cross-platform | Zuvo's skills are deeper and more specialized |
| **oh-my-codex (OMX)** | ~500 | 40+ Codex workflow skills, autopilot, TDD | Orchestration primitives vs deep domain skills |
| **Yeachan-Heo/oh-my-claudecode (OMC)** | ~1,000 | 19 agents, 36 skills, tmux workers | Zero-config multi-model team, trending #1 | Zuvo's structured pipeline and knowledge store |
| **ComposioHQ/agent-orchestrator** | 4,700 | Parallel agents, worktrees, CI fix | Just-in-Time context, `ao start` onboarding | Zuvo has 48 skills vs orchestration primitives |
| **jayminwest/overstory** | ~500 | 11 runtime adapters, SQLite mail | Pluggable AgentRuntime, FIFO merge queue | Infrastructure layer, not skill content |

### Tier 3 — Broader AI Tool Competitors

| Tool | Key feature Zuvo lacks | Assessment |
|------|----------------------|------------|
| **Cursor Automations** | Event-driven agents (PR, Slack, cron triggers) | Biggest paradigm gap — Zuvo is invoke-only |
| **Cursor BugBot** | Closed-loop: review > spawn fix agent > PR | Zuvo review suggests but doesn't auto-dispatch fixes |
| **Copilot Cloud Agent** | Assign GitHub issue > get PR back | Zero-friction entry point |
| **Windsurf Cascade** | Auto-generated memories from behavior | Passive learning without user effort |
| **CodeRabbit** | Learnings system that improves reviews over time | Self-improving from feedback |
| **Aider** | Auto-lint/auto-test after every edit + watch mode | Tighter feedback loop during implementation |
| **Roo Code** | Tool permission scoping per mode | Safety guarantee (read-only review) |
| **Qodo 2.0** | Parallel specialized review agents (60.1% F1) | Similar to Zuvo's adversarial, but with benchmarks |
| **Amazon Q** | Cross-repo migration (1000 apps Java 8>17) | Large-scale transformation beyond file-level |
| **Devin** | Auto-generated documentation wiki | Always-current docs from codebase analysis |
| **Devin 2.0** | Interactive Planning, Devin Wiki (auto-indexes repos), $20/month Core plan | Lower cost, auto-planning. But SaaS vs local plugin |
| **Cursor 3** | Agent-first workspace: parallel agents, Design Mode, worktrees, 30+ partner plugins | Paradigm shift — multi-repo, multi-agent. Plugin model cannot replicate Agents Window |
| **Claw Code** | Clean-room Claude Code rewrite, 172K stars in days | Harness not skills — could become a platform for skills like Zuvo |
| **Anthropic Code Review** | Native multi-agent PR review, $15-25/review, 54% substantive review rate | Zuvo has adversarial multi-provider (4 models), not just Anthropic's single-model agents |
| **Qodo 2.0** | 60.1% F1 (highest benchmarked), $70M Series B, learns org's code quality definition | Review-only. Zuvo covers full SDLC, not just review |
| **Macroscope v3** | 98% precision, dual-model (o4-mini + Opus 4) consensus | Review-only. Strong precision but narrow scope |
| **CodeRabbit Issue Planner** | Auto-generates Coding Plans from Jira/Linear/GitHub Issues, scans full codebase | Competes with zuvo:brainstorm + zuvo:plan pipeline |
| **Skills.sh (Vercel)** | 87K+ skills indexed across 17 platforms, npm-like discovery | Distribution platform. Zuvo should publish here |
| **GitHub Copilot Cloud Agent** | Issue-to-PR, self-review, agent firewall, custom agents with MCP | Zero-friction from GitHub Issues. Zuvo's quality gates are deeper |

---

## Part 2: Feature Gap Analysis

### GAP A — New Skill Candidates (HIGH priority)

#### A1. `zuvo:migrate` — Framework/Library Migration
**Why:** No current coverage. Huge demand. Amazon Q proved AI-driven migration cuts 2-year projects to 4 months. Salesforce reported 68-79% code health improvement.
**What:** Detect current framework version, map upgrade path, identify breaking changes, generate codemod transformations, run in phases with verification. Covers: React version upgrades, Next.js pages>app router, Express>Hono, Jest>Vitest, CJS>ESM, Node version bumps.
**Competitors doing this:** Amazon Q (large-scale), Devin (legacy COBOL/Fortran), Moderne (enterprise).
**Differentiator:** Phased migration with rollback points and adversarial verification at each step.

#### A2. `zuvo:ai-security-audit` — AI/LLM-Specific Security
**Why:** Prompt injection is #1 vulnerability (73% of AI deployments). MCP tool poisoning, RAG poisoning, agent memory attacks are new attack surfaces. OWASP LLM Top 10 exists but no plugin audits against it.
**What:** Audit prompt injection vectors, RAG poisoning risks, MCP tool security, agent memory safety, AI supply chain (models, SDKs, MCP servers), output filtering, AI-BOM generation.
**Competitors doing this:** Anthropic-Cybersecurity-Skills (framework mapping), cursor-security-rules (basic guardrails). None do white-box AI security auditing.
**Differentiator:** First plugin to audit AI integrations with the depth of zuvo:security-audit.

#### A3. `zuvo:risk-score` — Deployment Risk Scoring
**Why:** Novel capability few tools offer standalone. The glue between review and deploy. Greptile and Qodo do this implicitly in reviews, but not as a discrete assessment.
**What:** Analyze diff against ownership history, churn hotspots, past incident correlation, complexity, blast radius. Output: LOW/MEDIUM/HIGH/CRITICAL with recommended deployment strategy (direct merge, canary, staged rollout, extra review).
**Competitors doing this:** Partially embedded in Cursor BugBot, Greptile. No standalone skill.
**Differentiator:** Explicit risk assessment that feeds into ship/deploy decision.

#### A4. `zuvo:mutation-test` — Mutation Testing
**Why:** Validates test quality beyond coverage metrics. Meta proved LLM-powered mutation testing works at scale (FSE 2025). 73% acceptance rate from privacy engineers.
**What:** Inject mutations into production code (boundary changes, logic inversions, null returns), run test suite, report mutation score per module, identify undertested critical paths.
**Competitors doing this:** None as a plugin skill. Trail of Bits has mutation testing concepts.
**Differentiator:** LLM-guided intelligent mutations (not random), integrated with zuvo:test-audit scoring.

#### A5. `zuvo:incident` — Incident Response & Postmortem
**Why:** AI-generated postmortems save 10-20 hours/week per on-call rotation. Tools like Rootly and incident.io do this as SaaS, but no plugin does it from code/git context.
**What:** Triage severity, correlate recent changes (git log + deploy history), generate runbook steps, draft comms templates, produce postmortem with timeline and action items.
**Competitors doing this:** Rootly, incident.io, PagerDuty (SaaS only). No plugin.
**Differentiator:** Code-aware postmortem (which commits likely caused it, blast radius analysis).

#### A6. `zuvo:contract-test` — API Contract Testing
**Why:** Schema drift between API spec and implementation is a growing pain. TestSprite boosts contract test pass rates from 42% to 93%.
**What:** Scan endpoints for schema drift between OpenAPI spec and implementation, generate consumer-driven contract tests, detect breaking changes before deployment.
**Competitors doing this:** Partially in API testing tools (Pact, TestSprite). No plugin skill.

### GAP B — New Skill Candidates (MEDIUM priority)

#### ~~B1. `zuvo:a11y-audit` — Dedicated Accessibility Audit~~ ✅ DONE
Added in v1.3.x. 10 dimensions (A1-A10), WCAG 2.2 AA/AAA, 2 critical gates (keyboard A2, contrast A4), legal compliance (ADA/EAA/Section 508), `--fix` mode.

#### B2. `zuvo:boundaries` — Module Boundary Enforcement
**Why:** Architecture fitness functions becoming standard. Nx and Feature-Sliced Design proving value.
**What:** Define import rules between modules, public API surface validation, dependency direction enforcement, detect violations in diffs.

#### B3. `zuvo:migration-audit` — Database Migration Safety
**Why:** Gap in db-audit. Destructive migrations are a top cause of production incidents.
**What:** Analyze migration files for destructive ops, lock duration estimation, missing rollbacks, data loss risk, backward compatibility with current app code.

#### B4. `zuvo:flaky-test` — Flaky Test Detection & Quarantine
**Why:** 11-27% test flakiness rates. 5-16% noise-induced build failures.
**What:** Analyze test history for intermittent failures, classify root causes (timing, state leakage, environment dependency), quarantine recommendations.

### GAP C — New Skill Candidates (LOWER priority)

| Skill | Rationale |
|-------|-----------|
| `zuvo:sbom` | Software/AI Bill of Materials generation (CycloneDX/SPDX). ML-BOM adoption lagging. |
| `zuvo:visual-test` | Structural UI comparison via Playwright screenshots. Requires infrastructure. |
| `zuvo:test-impact` | Analyze diff to determine affected tests only. Hard without runtime data. |
| `zuvo:perf-budget` | Define/enforce performance budgets. Could be performance-audit enhancement. |
| `zuvo:observability-audit` | OTel coverage, alert quality, dashboard coverage. Niche. |
| `zuvo:license-audit` | Flag GPL contamination in AI-generated code (Tabnine does this). |

---

## Part 3: Enhancement Opportunities for Existing Skills

### HIGH impact enhancements

| Skill | Enhancement | Inspiration |
|-------|-------------|-------------|
| **review** | Add deployment risk scoring to review output. Review produces LOW/MED/HIGH/CRIT risk + recommended deploy strategy. | Greptile, Qodo, BugBot |
| **review** | Closed-loop: when review finds MUST-FIX issues, offer to auto-dispatch `zuvo:build` to fix them. | Copilot agentic review, BugBot autofix |
| **review** | Add learnings system: remember past review feedback patterns per-project, apply them in future reviews. | CodeRabbit Learnings |
| **security-audit** | Add AI/LLM security dimension (S15): prompt injection vectors, MCP tool security, RAG poisoning, AI supply chain. | OWASP LLM Top 10, RSAC 2026 trends |
| **build** | Add auto-lint/auto-test tight loop: after each file edit, immediately run linter + relevant tests, auto-fix before moving on. | Aider auto-lint/auto-test |
| **retro** | Add AI attribution metrics: % of AI-assisted code, quality comparison AI vs human PRs, review burden analysis. | 2025 DORA report |
| **ship** | Integration with risk-score: auto-determine ship strategy (fast-track vs full review vs staged) based on diff risk. | Probabilistic CI/CD trend |

### MEDIUM impact enhancements

| Skill | Enhancement | Inspiration |
|-------|-------------|-------------|
| **ci-audit** | Add probabilistic pipeline analysis, test impact scoring, flaky test detection dimension. | SAPAL framework, AI-powered CI/CD |
| **db-audit** | Add migration safety dimension (DB13): destructive ops, lock duration, rollback verification. | DataGrip, Bytebase |
| **test-audit** | Add mutation score checking dimension, contract test coverage assessment. | Meta mutation testing |
| **write-e2e** | Add visual regression step: capture screenshots, compare structurally (not pixel-diff). | Applitools, Percy Visual Review |
| **performance-audit** | Add performance budget definition/enforcement, Chrome DevTools MCP integration. | Industry trend |
| **code-audit** | Add license compliance dimension: detect AI-generated code matching restrictively-licensed repos. | Tabnine license detection |
| **architecture** | Add module boundary enforcement (fitness functions) and drift detection. | Nx, Feature-Sliced Design |
| **dependency-audit** | Add AI supply chain dimension: audit MCP servers, LLM dependencies, AI SDKs. | AI-BOM concept |
| **docs** | Add living architecture docs mode: auto-update architecture diagrams when code changes. | Kinde approach |

---

## Part 4: Ecosystem & Distribution Gaps

### Visibility problem
- Zuvo: 1 star. Top competitor (claude-mem): 45,887 stars.
- The awesome lists (awesome-claude-code at 37K stars, awesome-agent-skills at 14K stars) are the primary discovery channels.
- Single-skill viral hits (humanizer 12K, caveman 4K) outperform comprehensive toolkits on stars.

### Distribution channels to consider

| Channel | What it is | Action |
|---------|-----------|--------|
| **anthropics/claude-plugins-official** (16K stars) | Official Anthropic curated directory | Submit Zuvo for inclusion |
| **VoltAgent/awesome-agent-skills** (14K stars) | 1,060+ skills directory | Submit Zuvo skills |
| **hesreallyhim/awesome-claude-code** (37K stars) | THE canonical awesome list | Submit Zuvo |
| **PRPM** (101 stars) | Universal prompt package manager (7,500+ packages) | Publish skills as PRPM packages for cross-platform reach |
| **agentskills.io** | Open standard for agent skills format | Ensure Zuvo SKILL.md format is compatible |
| **cursor/plugins** (205 stars) | Official Cursor plugin directory | Submit Cursor build |
| **davepoon/buildwithclaude** (2,707 stars) | Claude skills hub | Submit for listing |

### Competitive moats to build

1. **Adversarial review is unique** — No competitor does multi-provider adversarial verification at Zuvo's depth. Double down.
2. **Full pipeline is unique** — brainstorm > plan > execute > review > ship > deploy > canary > retro. No competitor covers end-to-end.
3. **Audit breadth is unique** — 10+ audit dimensions with structured scoring. Closest is Trail of Bits (security only).
4. **Quality gates are unique** — CQ1-CQ28 + Q1-Q19 + AP1-AP29 + CAP1-CAP14. No competitor has this systematic approach.

---

## Part 5: Innovation Patterns Worth Stealing

### From Cursor
- **Automations** — event-driven skills triggered by external events (PR, Slack, cron, webhook). Not just invoke-on-demand.
- **BugBot autofix** — closed-loop review > fix > PR with 35% merge rate.
- **Background agents** — up to 8 parallel agents in cloud VMs on separate branches.

### From Windsurf
- **Auto-generated memories** — passive learning from developer behavior without explicit save actions.
- **Shared timeline** — track everything (files edited, terminal, clipboard, conversation) to infer intent.

### From Aider
- **Auto-lint/auto-test loop** — after every edit, automatically verify and fix. Not just at the end.
- **Watch mode / AI comments** — `// AI! refactor this` in any editor triggers action.
- **Architect mode** — separate reasoning model from editing model.

### From CodeRabbit
- **Learnings system** — reviews improve over time from team feedback. Scoped: local (repo), global (org), auto.
- **Natural language config** — plain English review instructions in YAML.

### From Roo Code
- **Tool permission scoping** — read-only review mode that literally cannot write files.
- **Community Mode Gallery** — one-click install of pre-tested agent configurations (140+ specialist agents).

### From Trail of Bits
- **Trophy Case** — documented list of real bugs found by skills. Social proof.
- **Framework compliance mapping** — every skill mapped to MITRE ATT&CK, NIST, CWE, etc.
- **Mutation testing skill** — added same week as zuvo:mutation-test (convergent evolution).

### From Cursor 3 (NEW — April 2026)
- **Agents Window** — parallel agents across repos and environments (local, worktrees, cloud, SSH).
- **Design Mode** — annotate and target UI elements in-browser for agent feedback.
- **MCP Apps** — structured content in tool outputs (not flat text).
- **30+ partner plugins** — Atlassian, Datadog, GitLab, PlanetScale ecosystem.

### From Devin 2.0 (NEW)
- **Interactive Planning** — auto-analyzes codebase, proposes plans before user asks.
- **Devin Wiki** — auto-indexes repos every few hours, generates architecture docs.
- **$20/month entry** — makes autonomous agent accessible to individuals.

### From Skills.sh (Vercel) (NEW)
- **87K+ skills indexed** across 17 platforms — the npm of agent skills.
- **Cross-platform discovery** — one listing reaches Claude Code + Codex + Cursor + Gemini + 13 others.

### From Metaswarm (deep-dived 2026-04-08)
- **Knowledge Store** (JSONL fact store) — patterns, gotchas, decisions persist across sessions. ✅ ADOPTED by zuvo.
- **Session Recovery** (.beads/context/) — state persistence across context compaction. ✅ ADOPTED by zuvo.
- **BEADS CLI** — git-native task tracking. Zuvo uses session-state.md instead (lighter, no npm dependency).
- **9 formal rubrics** — evaluated, decided against (3 targeted fixes instead — severity vocabulary, quality-reviewer dedup, threshold alignment). ✅ ADDRESSED differently.

---

## Part 6: Prioritized Action Plan

### TIER 1 — Do Now (high impact, achievable)

| # | Action | Type | Effort | Status |
|---|--------|------|--------|--------|
| 1 | ~~Add `zuvo:migrate` skill~~ | ~~New skill~~ | ~~L~~ | SKIPPED — not needed by user |
| 2 | Add AI/LLM security dimension (S15) to security-audit | Enhancement | M | ✅ DONE (v1.3.x) |
| 3 | Add deployment risk scoring to review output | Enhancement | M | OPEN |
| 4 | Add closed-loop review > auto-fix dispatch | Enhancement | M | OPEN |
| 5 | Submit to awesome-claude-code, awesome-agent-skills, claude-plugins-official | Distribution | S | OPEN |
| 6 | Create Trophy Case in docs (real bugs found by Zuvo audits) | Marketing | S | ✅ DONE (docs/trophy-case.md, 550+ findings) |
| 5b | **Publish to Skills.sh** (87K skills, 17 platforms) | Distribution | S | **NEW — HIGH PRIORITY** |
| 5c | **Submit to Anthropic official marketplace** | Distribution | M | **NEW — superpowers got in Jan 15** |

### TIER 2 — Do Next (high impact, more effort)

| # | Action | Type | Effort | Status |
|---|--------|------|--------|--------|
| 7 | Add `zuvo:ai-security-audit` skill | New skill | L | ✅ COVERED (S15 in security-audit) |
| 8 | Add `zuvo:risk-score` skill | New skill | M | OPEN |
| 9 | Add `zuvo:mutation-test` skill | New skill | L | ✅ DONE |
| 10 | Add learnings system to review (remember patterns per-project) | Enhancement | L | ✅ DONE (Knowledge Store v3 — 2026-04-08) |
| 11 | Add auto-lint/auto-test loop to build skill | Enhancement | M | OPEN |
| 12 | Map audit dimensions to OWASP/CWE/NIST frameworks | Enhancement | M | PARTIAL (security-audit has CWE) |
| 10b | **Knowledge Store v3** — JSONL fact store, prime/curate, session-level auto-prime | Enhancement | L | ✅ DONE (2026-04-08) |
| 10c | **Session Recovery** — execution-state.md, project-context.md, active-plan.md | Enhancement | M | ✅ DONE (2026-04-08) |
| 10d | **Evidence enforcement** — auto-downgrade findings without file:line | Enhancement | S | ✅ DONE (2026-04-08) |
| 10e | **Severity vocabulary** — unified mapping across all 48 skills | Enhancement | S | ✅ DONE (2026-04-08) |
| 10f | **Quality-reviewer dedup** — removed 140 lines of duplicated CQ/Q gates | Fix | S | ✅ DONE (2026-04-08) |
| 10g | **CQ23-28 gap** — 6 missing gates added to code-audit | Fix | S | ✅ DONE (2026-04-08) |

### TIER 3 — Do Later (medium impact)

| # | Action | Type | Effort | Status |
|---|--------|------|--------|--------|
| 13 | Add `zuvo:a11y-audit` skill | New skill | M | ✅ DONE |
| 14 | Add `zuvo:incident` skill | New skill | M | ✅ DONE (fixed 2026-04-08) |
| 15 | Add `zuvo:contract-test` skill | New skill | M | OPEN |
| 16 | Add `zuvo:boundaries` skill | New skill | M | OPEN |
| 17 | Add migration safety to db-audit | Enhancement | S | OPEN |
| 18 | Add visual regression to write-e2e | Enhancement | M | OPEN |
| 19 | Add AI attribution metrics to retro | Enhancement | S | OPEN |
| 20 | Add performance budgets to performance-audit | Enhancement | S | OPEN |
| 14b | **Investigate everything-claude-code** — 128K stars, 136 skills, depth unknown | Research | S | **NEW** |

### TIER 4 — Consider (nice to have)

| # | Action | Type | Status |
|---|--------|------|--------|
| 21 | `zuvo:sbom` — Software/AI Bill of Materials |  New skill | OPEN |
| 22 | `zuvo:license-audit` — GPL contamination detection | New skill | OPEN |
| 23 | Tool permission scoping (read-only audit modes) | Architecture | OPEN |
| 24 | PRPM package publishing | Distribution | OPEN |
| 25 | Watch mode / AI comments integration | Architecture | OPEN |

---

## Appendix: Competitor Star Counts (top 40)

| Rank | Competitor | Stars | Category | Change |
|------|-----------|-------|----------|--------|
| 1 | **Claw Code** (clean-room Claude Code rewrite) | 172,000 | Harness | NEW — 50K in 2 hours |
| 2 | **affaan-m/everything-claude-code** | 128,000 | Skill library | NEW |
| 3 | claude-mem | 46,100 | Memory | +200 |
| 4 | **obra/superpowers** | 42,000 | Workflow | NEW — Anthropic marketplace |
| 5 | awesome-claude-code | 37,339 | Awesome list | +338 |
| 6 | wshobson/agents | 33,091 | Orchestration | — |
| 7 | **ruvnet/ruflo** (ex Claude Flow) | 25,000 | Agent framework | NEW |
| 8 | OthmanAdi/planning-with-files | 18,178 | Planning | — |
| 9 | jarrodwatts/claude-hud | 17,303 | Observability | — |
| 10 | anthropics/claude-plugins-official | 16,298 | Registry | +123 |
| 11 | VoltAgent/awesome-agent-skills | 14,686 | Directory | +208 |
| 12 | EveryInc/compound-engineering-plugin | 13,605 | Workflow | +190, v2.63.1 |
| 13 | wasp-lang/open-saas | 13,930 | SaaS bundle | — |
| 14 | mattpocock/skills | 12,637 | Personal skills | — |
| 15 | blader/humanizer | 12,618 | Single skill | — |
| 16 | anthropics/knowledge-work-plugins | 10,960 | Knowledge work | — |
| 17 | alirezarezvani/claude-skills | 9,975 | Skill library | +172, v2.0.0 |
| 18 | numman-ali/openskills | 9,456 | Skills loader | — |
| 19 | Understand-Anything | 7,913 | Knowledge graph | — |
| 20 | ykdojo/claude-code-tips | 7,190 | Tips/education | — |
| 21 | slavingia/skills | 7,066 | Business skills | — |
| 22 | devin.cursorrules | 5,963 | Self-evolving agent | — |
| 23 | **ComposioHQ/agent-orchestrator** | 4,700 | Orchestration | NEW |
| 24 | vibe-tools | 4,752 | Tool integrations | — |
| 25 | JuliusBrussee/caveman | 4,373 | Token reduction | — |
| 26 | trailofbits/skills | 4,364 | Security skills | +23 |
| 27 | Anthropic-Cybersecurity-Skills | 4,077 | Cybersecurity | — |
| 28 | sanjeed5/awesome-cursor-rules-mdc | 3,433 | Rules generator | — |
| 29 | agenticnotetaking/arscontexta | 3,054 | Knowledge system | — |
| 30 | ralphy | 2,723 | Autonomous loop | — |
| 31 | davepoon/buildwithclaude | 2,707 | Hub | — |
| 32 | ZeframLou/call-me | 2,553 | Notification | — |
| 33 | nyldn/claude-octopus | 2,449 | Multi-model review | +26, v9.20.0 |
| 34 | revfactory/harness | 2,024 | Meta-skill | — |
| 35 | jeremylongshore/claude-code-plugins-plus-skills | 1,871 | Mega collection | +12, v4.24.0 |
| 36 | rohitg00/pro-workflow | 1,739 | Self-correcting | +185, v3.2.0 |
| 37 | **levnikolaevich/claude-code-skills** | ~1,000 | SDLC + MCP servers | NEW |
| 38 | **Yeachan-Heo/oh-my-claudecode** | ~1,000 | Multi-model team | NEW |
| 39 | dsifry/metaswarm | ~500 | Multi-agent orchestration | v0.11.0 |
| 40 | wondelai/skills | 473 | Book-as-skill | +28 |

## Appendix B: Major Platform Events (March-April 2026)

| Date | Event | Impact on zuvo |
|------|-------|----------------|
| 2026-03-31 | **Claude Code source leak** via npm sourcemap (512K lines, 1,906 files) | Ecosystem shift — open-source harnesses proliferate |
| 2026-04-01 | **Claw Code** clean-room rewrite hits 172K stars | Could become a platform for skills like zuvo |
| 2026-04-02 | **Cursor 3** launches — agent-first workspace, parallel agents, Design Mode | Plugin model cannot replicate Agents Window |
| 2026-04-01 | **Copilot Cloud Agent** renamed, self-review + security scanning | Zero-friction from Issues remains Copilot's moat |
| 2026-03-30 | **Qodo 2.0** — $70M Series B, 60.1% F1 highest | Review benchmarks as marketing weapon |
| 2026-02-24 | **Anthropic Private Plugin Marketplaces** — 101 plugins official | Enterprise distribution opportunity for zuvo |
| 2026-02-05 | **Anthropic Agent Teams** — full Claude Code instances as teammates | Enabler for zuvo multi-agent dispatch |
| 2026-01-20 | **Skills.sh** (Vercel) — 87K+ skills, 17 platforms | npm for agent skills. Zuvo not listed |
| 2026-01-15 | **Superpowers** accepted to Anthropic marketplace | Distribution advantage zuvo doesn't have |

## Appendix C: Ecosystem Metrics (April 2026)

| Metric | Count |
|--------|-------|
| Claude Code GitHub stars | 82K+ |
| Indexed Claude Code plugin repos | 10,913 |
| Official marketplace plugins | 101 (33 Anthropic + 68 partner) |
| Community marketplaces | 43 (834 total plugins) |
| Skills.sh indexed skills | 87,000+ |
| AI agent skills packages (all platforms) | 350,000+ |

---

*Updated 2026-04-08. Based on research across GitHub, web search, AI tool documentation, and daily competitive scans.*
