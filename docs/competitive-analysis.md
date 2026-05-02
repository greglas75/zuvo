# Zuvo Competitive Analysis — May 2026

> Comprehensive review of the AI coding tools ecosystem. 90+ competitors analyzed across Claude Code plugins, Cursor extensions, Codex/Windsurf/Copilot ecosystems, and DevOps trends.
> Last updated: 2026-05-01 (prior: 2026-04-08)

---

## Executive Summary

Zuvo's 51-skill depth across audits, testing, security, deployment, design, pipeline management, knowledge accumulation, and session recovery is **mid-pack on count** but unique on quality-gate depth. No competitor matches: structured multi-agent workflows, adversarial review (4 providers), quality gates (CQ1-CQ29 + Q1-Q19 + AP1-AP29 + CAP1-CAP14), evidence enforcement, knowledge store, and tri-platform build (Claude Code + Codex + Cursor; Antigravity build target evaluated).

**Critical context shift since 2026-04-08:**
- **Skill count is no longer a differentiator.** compound-engineering 36 skills + 51 agents (v3.0.3); claude-octopus 52 skills; alirezarezvani 235; jeremylongshore 2,849.
- **Distribution war intensified.** superpowers grew 42K → ~150K stars (3.5x in 3 months) after Anthropic Verified badge.
- **Cursor Marketplace launched 2026-02-17** (Cursor 2.5), not April. Window narrower than thought.
- **Native first-party overlap shipped:** Anthropic `/security-review`, `/review`, Claude Design (Apr 2026); GitHub Copilot agentic review GA (2026-03-05).
- **CodeRabbit Agent (2026-04-22)** = single agent across 7 SDLC phases — direct hit on brainstorm > plan > execute > review pipeline.

**Where Zuvo leads:**
- Full SDLC pipeline (brainstorm > plan > execute > ship > deploy > canary > retro)
- 10+ audit dimensions with evidence-based scoring and tiered output
- Adversarial multi-provider review (4 providers) — unique in the ecosystem
- Knowledge Store v3 (JSONL, timesSurfaced/confidence separation, recency ranking, merge rules)
- Session Recovery with validation, precedence, stale detection
- Evidence enforcement (auto-downgrade findings without file:line)
- Unified severity vocabulary across all 51 skills
- Cross-platform build system from single source (Claude Code + Codex + Cursor)

**Where Zuvo trails:**
- Visibility/distribution: 1 star vs 158K (everything-claude-code), ~150K (superpowers, was 42K in Feb)
- Not on agentskill.sh (107-110K skills indexed) or Anthropic Verified marketplace
- No viral proof point (metaswarm: "127 PRs in a weekend", Claw Code: 50K stars in 2h)
- Event-driven automations (Cursor Automations, Cursor 3 Agents Window)
- Closed-loop review-to-fix pipelines (Copilot agentic GA Mar 5, BugBot)
- Issue-to-PR zero-friction workflows (Copilot Cloud Agent, Jules, Devin 2.2)
- Native CLI agent product (CodeRabbit Agent CLI `--agent` mode with JSON output, Apr 22)
- 21/51 skills have zero recorded user invocations (per ~/.zuvo/runs.log, 33-day window) — distribution vs adoption gap

---

## Part 1: Direct Competitors

### Tier 1 — Major Skill Libraries (refreshed 2026-05-01)

| Competitor | Stars | Skills | Strengths | Zuvo advantage |
|-----------|-------|--------|-----------|----------------|
| **alirezarezvani/claude-skills** | unclear: 5,200–9,975 (web research diverges) | 235–248 | Breadth (marketing, product, compliance, C-level), 314 Python CLI tools, personas, multi-platform (Claude/Codex/Gemini/Cursor + 8 more) | Deeper per-skill workflows, adversarial review, quality gates, pipeline enforcement |
| **trailofbits/skills** | 4,364 | 35+ | Gold standard security (Semgrep, CodeQL, smart contracts, 6 blockchains), Trophy Case, separate `skills-curated` third-party marketplace | Broader coverage beyond security, full SDLC pipeline |
| **EveryInc/compound-engineering-plugin** | 13,605 | **36 skills + 51 agents** (v3.0.3, was ~10 in April) | Reviewer personas, autopilot orchestration, sandboxing. Multi-platform. Closest in size to zuvo | Knowledge Store v3, evidence enforcement, deeper audit dimensions |
| **jeremylongshore/plugins-plus-skills** | 1,871 | 423 plugins, **2,849 skills**, 177 agents (v4.24.0+) | Scale-as-marketplace, own CLI `ccpi`, daily GH Actions update, tonsofskills.com | Quality > quantity, structured workflows |
| **wondelai/skills** | 473 | 40 | Book-as-skill methodology, non-eng focus (PM, marketing, sales, UX) | Actionable audits vs theoretical frameworks |
| **Anthropic-Cybersecurity-Skills** | 4,077 | 754 | 26 security domains, 5 framework mappings (MITRE, NIST, ATLAS) | Broader than security, integrated pipeline |

### Tier 1b — Major New Competitors (refreshed 2026-05-01)

| Competitor | Stars | Skills/Agents | Strengths | Zuvo advantage |
|-----------|-------|---------------|-----------|----------------|
| **affaan-m/everything-claude-code** | **158,000** (was 128K, Global Rank #40) | 136 skills, 30 agents | "Agent harness performance optimization system" — skills, instincts, memory, security, research-first dev. Multi-platform: Claude/Codex/Opencode/Cursor | Depth unverified — zuvo's CQ/Q evidence enforcement likely unmatched |
| **obra/superpowers** | **~150,000** (was 42K — 3.5x in 3 months) | TDD, debug, brainstorm, review pipeline | Anthropic Verified marketplace since 2026-01-15, separate `superpowers-marketplace` and `superpowers-skills` repos (community-editable) | Zuvo has 51 skills vs ~10, adversarial review, knowledge store, audit breadth |
| **ruvnet/ruflo** (ex Claude Flow) | 25,000 | 19 plugins, 64 skills, 314 MCP tools as discoverable skills | MCP-native, self-learning, v3.5+ | Zuvo's structured CQ/Q gates vs generic quality checks |
| **dsifry/metaswarm** | ~500 | 18 agents, 13 skills, 15 commands | TDD enforcement, quality gates, spec-driven dev, 100% test coverage mandate, integrations with CodeRabbit + Greptile, "127 PRs in a weekend" | Zuvo has 51 vs 13 skills, knowledge store v3, evidence enforcement |
| **levnikolaevich/claude-code-skills** | ~1,000 | 6 plugins + 3 own MCP servers | Bundled MCP: **hex-line** (hash-verified editing), **hex-graph** (code knowledge graph), **hex-ssh**. Full Agile lifecycle, multi-model review. Last update 2026-03-26 | Zuvo has deeper skills, more audit dimensions; gap = bundled MCP UX |
| **nyldn/claude-octopus** | 2,449 | 32 personas, 48 commands, **52 skills** (= zuvo) | Discover→Define→Develop→Deliver gates. Architect/strategist/security default to Opus 4.7. Integrates with claude-mem | Zuvo's adversarial multi-provider review, knowledge store v3 |
| **Yeachan-Heo/oh-my-claudecode (OMC)** | **~31,300** (was ~1K, large jump) | 32 specialized agents | Teams-first multi-agent, real-time HUD, smart model routing | Zuvo's structured pipeline + audit gates |

### Tier 1c — Newly Discovered (NEW since 2026-04-08)

| Competitor | Stars | Skills/Agents | Why it matters |
|-----------|-------|---------------|----------------|
| **rohitg00/awesome-claude-code-toolkit** | trending #1 GitHub Feb 2026 | 135 agents + 35 skills + ~400K via SkillKit + 176 plugins + 14 MCP configs | Aggregator with massive surface; one-stop competitor to discoverability |
| **MadeByTokens/claude-brainstorm** | unverified | 1 (single-purpose) | Whole repo around `brainstorm` only — proves market for **specialist plugins**. Direct overlap with `zuvo:brainstorm` |
| **shanraisshan/claude-code-best-practice** | trending Mar 2026 | curated guides | Positions "vibe coding to agentic engineering" — captures terminology mindshare |
| **aaron-he-zhu/seo-geo-claude-skills** | unverified | 20 skills (CORE-EEAT + CITE) | Direct overlap with `zuvo:seo-audit` + `zuvo:geo-audit`. Specialist beats generalist on domain |
| **AgriciDaniel/claude-seo** | unverified | 19 sub-skills + DataForSEO + Firecrawl integrations | Direct SEO overlap with paid data sources zuvo lacks |
| **Dicklesworthstone/claude_code_agent_farm** | unverified | 20+ parallel agents + tmux monitoring | Agent-farm pattern: parallel execution UX zuvo doesn't have |
| **wshobson/agents** | 33,091 (top 10) | multi-agent orchestration | High-star orchestration — reference architecture for parallelism |

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
| **ComposioHQ/agent-orchestrator** | 4,700 | Parallel agents, worktrees, CI fix | Just-in-Time context, `ao start` onboarding | Zuvo has 51 skills vs orchestration primitives |
| **jayminwest/overstory** | ~500 | 11 runtime adapters, SQLite mail | Pluggable AgentRuntime, FIFO merge queue | Infrastructure layer, not skill content |

### Tier 3 — Broader AI Tool Competitors (refreshed 2026-05-01)

| Tool | Key feature Zuvo lacks | Assessment |
|------|----------------------|------------|
| **Cursor Automations** | Event-driven agents (PR, Slack, cron triggers) | Biggest paradigm gap — Zuvo is invoke-only |
| **Cursor BugBot** | Closed-loop: review > spawn fix agent > PR | Zuvo review suggests but doesn't auto-dispatch fixes |
| **Copilot Cloud Agent** | Assign GitHub issue > get PR back | Zero-friction entry point |
| **Windsurf Cascade + SWE-1.5** | Auto-memories + persistent codebase memory + 13× faster than Sonnet 4.5 (claimed) | Passive learning; speed advantage |
| **CodeRabbit** | Learnings system that improves reviews over time | Self-improving from feedback |
| **CodeRabbit Agent (NEW 2026-04-22)** | **Single agent across 7 SDLC phases**, CLI `--agent` JSON output (Mar 31), Issue Planner beta | **HIGH threat** — direct overlap with brainstorm > plan > execute > review pipeline |
| **Aider** | Auto-lint/auto-test after every edit + watch mode | Tighter feedback loop during implementation |
| **Roo Code** | Tool permission scoping per mode | **DEAD — shutdown 2026-04-20, gone 2026-05-15.** Pivots to Roomote cloud. **Capture window for refugees** |
| **Cline v3.78+ (NEW)** | Spend-limit UI, open-source agent leader. Free users now pay-per-token on Anthropic Max/Pro (2026-04-04 pricing change) | Pricing pressure makes zuvo's "Claude-Code-native" positioning more valuable |
| **Qodo 2.0** | **#1 in Martian benchmark Feb 2026 (60.1% F1, 17 tools tested)**, $70M Series B, learns org code quality | Review-only. Zuvo covers full SDLC. Use Martian methodology in `zuvo:agent-benchmark` |
| **Qodo Cover** | Autonomous regression tests via GitHub Action, MCP-aware (Postgres etc.) | Direct overlap with `zuvo:write-tests` |
| **Amazon Q** | Cross-repo migration (1000 apps Java 8>17) | Large-scale transformation beyond file-level |
| **Devin 2.2 + Devin Cloud (NEW)** | Self-verifying via computer use, parallel cloud sandboxes, in Windsurf 2.0. Cognition raising at $25B | Hybrid SaaS/IDE; zuvo stays plugin-native |
| **Cursor 3 (Apr 2026)** | Agents Window (parallel agents across local/worktrees/cloud/SSH), Design Mode, interactive canvases, multi-folder workspaces, real-time RL retraining of Composer ~5h | Plugin model cannot replicate Agents Window. **Cursor Marketplace launched 2026-02-17** with ~30 partner plugins (Atlassian, Datadog, GitLab, Glean, HuggingFace, monday.com, PlanetScale, Amplitude, AWS, Figma, Linear, Stripe). Hard ceiling: ~40 active MCP tools across all servers |
| **Cursor Plugin Spec (NEW 2026-02)** | Formalized: SKILL.md, hooks, MCP, subagents, rules, commands. AGENTS.md / .cursorrules governance | **OPPORTUNITY** — zuvo's existing Cursor v3 build can publish; near 1:1 SKILL.md compat |
| **Claw Code** | Clean-room Claude Code rewrite, 172K stars in days | Harness not skills — could become a platform for skills like Zuvo |
| **Anthropic `/security-review` + `/review` (native built-ins)** | Both invocable via Skill tool; `/security-review` shipped as preview with **500+ vulns found**, customizable via `.claude/commands/`, GitHub Action `anthropics/claude-code-security-review` | **HIGH threat** to `zuvo:security-audit` + `zuvo:review`. Differentiator must be 14-dim breadth + evidence enforcement |
| **Anthropic Claude Code Security (preview 2026)** | Native security agent, OWASP-style coverage | Reframe `zuvo:pentest` + `security-audit` against this baseline |
| **Anthropic Claude Design (NEW Apr 2026)** | Collaborative UI design product | **Direct hit** on `zuvo:design` + `zuvo:design-review` + `zuvo:ui-design-team` (which have 0 user invocations in 33-day window) — recommend deprecate or specialist pivot |
| **Anthropic Agent Teams (v2.1.32, Feb 5)** | Multi-session coordination, env-gated `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | Direct competitor for `ui-design-team`, parallel `code-audit` orchestration |
| **Claude Code marketplace + plugin spec (matured)** | Dependency auto-resolve, `blockedMarketplaces` host/path patterns, type-to-filter `/skills` UI | Zuvo plugin already conforms; needs **Anthropic Verified** badge |
| **Codex Agent Skills (shipped 2026-12-19, agentskills.io)** | Standardized: `~/.codex/skills`, `.codex/skills`, `$skill-name`, built-ins `$skill-creator`/`$skill-installer`/`$create-plan` | Zuvo's Codex build target = first-class. Custom prompts deprecated 2026-01-22 |
| **Codex Plugin System (2026-03-25)** | `.codex-plugin/plugin.json` bundles skills + MCP + integrations, built-in `@plugin-creator` | Zuvo already builds for this |
| **Codex App + computer-use (Feb-Apr 2026)** | macOS Feb 2, Windows Mar 4, in-app browser Apr 16, GPT-5.4 native computer-use, 1M context experimental | Browser/desktop control surface zuvo lacks |
| **Macroscope v3** | **98% precision, nitpicks down 64-80%, $0.95/review pay-per-use** | Stronger precision but narrow scope (review-only) |
| **Greptile v3 (NEW)** | Claude Agent SDK + repo graph + multi-hop investigation, $30/dev | Direct overlap with `code-audit` + `architecture` |
| **GitHub Copilot agentic code review (GA 2026-03-05)** | Tool-calling for cross-file context, **60M reviews to date**, autopipes fixes to coding agent | **HIGH threat — distribution moat (every dev already pays)** |
| **GitHub Copilot inline agent mode JetBrains (preview 2026-04-24)** | Inline edits in JetBrains IDEs | Cross-IDE pressure |
| **Frase MCP (NEW Feb 2026)** | **First SEO platform with read-write MCP** — agent reads SERP/brief/score and writes drafts back | Different lane than `zuvo:seo-fix` (technical SEO code patches). Real overlap = `zuvo:write-article` content grounding |
| **Google Antigravity (preview 2026-11-18)** | Gemini 3 Pro (1M context), Editor + Manager Surface, browser subagent, Walkthroughs artifact, AGENTS.md global at `~/.gemini/`. **No formal plugin spec yet** | **Window of opportunity** — 4th build target before Google formalizes |
| **Google Jules / Project Jitro (V2 waitlist, May I/O 2026)** | KPI-driven goal-setting agent ("raise coverage" not "write tests") | Different paradigm; watch HIGH post-I/O 2026-05-19 |
| **OpenAI Codex desktop revamp (2026-04-16)** | Desktop-control, opens any app with cursor | Computer-use shift; orthogonal but expanding |
| **agentskill.sh** | **107-110K skills** indexed, 20+ AI tools, two-layer security scanning, /learn installer. Dev/Eng: 124K skills, PM: 39K | Replaces "Skills.sh 87K" reference. Auto-lists agentskills.io-compliant SKILL.md |
| **Zed + JetBrains ACP (Agent Client Protocol, Jan 2026)** | Editor-agnostic agent protocol, supports Claude Code/Codex/Gemini/OpenCode | Potential **5th build target** — cross-IDE portability |
| **Anthropic per-token pricing for third-party CLI tools (2026-04-04)** | Max/Pro users pay per-token on Cline/etc., not on official Claude Code | Pushes users to **Claude-Code-native skills like zuvo** |

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
| **PRPM** (101 stars) | Universal prompt package manager + lock file for Claude/Cursor/Continue/Windsurf/OpenCode/Droid (7,500+ packages) | Publish skills as PRPM packages for cross-platform reach |
| **microsoft/apm** | Microsoft Agent Package Manager (competitor to PRPM) | Watch — Microsoft endorsement could win on enterprise |
| **agentskill.sh** | 107-110K skills, 20+ AI tools | Auto-listed if SKILL.md is agentskills.io-compliant |
| **agentskills.io** | Open standard for agent skills format | Ensure Zuvo SKILL.md format is compatible |
| **cursor/plugins** (205 stars) | Official Cursor plugin directory | Submit Cursor build |
| **davepoon/buildwithclaude** (2,707 stars) | Claude skills hub | Submit for listing |

### Competitive moats to build

1. **Adversarial review is unique** — No competitor does multi-provider adversarial verification at Zuvo's depth. Double down.
2. **Full pipeline is unique** — brainstorm > plan > execute > review > ship > deploy > canary > retro. No competitor covers end-to-end.
3. **Audit breadth is unique** — 10+ audit dimensions with structured scoring. Closest is Trail of Bits (security only).
4. **Quality gates are unique** — CQ1-CQ29 + Q1-Q19 + AP1-AP29 + CAP1-CAP14. No competitor has this systematic approach.

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

### From agentskill.sh / agentskills.io (refreshed 2026-05-01)
- **107-110K+ skills indexed** across 20+ platforms (was 87K) — the npm of agent skills.
- **agentskills.io** is the open standard adopted by 26+ platforms — SKILL.md compliance auto-lists you across the network.
- **Two-layer security scanning** + `/learn` installer in agentskill.sh.

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
| 5b | **Publish to agentskill.sh / agentskills.io** (107-110K skills, 20+ tools) | Distribution | S | **HIGH — auto-listed if SKILL.md compliant** |
| 5c | **Apply for Anthropic Verified marketplace badge** | Distribution | M | **CRITICAL — superpowers grew 42K→150K (3.5x) after badge** |
| 5d | **Publish to Cursor Marketplace** (launched 2026-02-17, ~30 partner plugins, narrow window) | Distribution | S | **HIGH — Cursor v3 build already exists** |
| 5e | **Publish to Codex plugin system** (`.codex-plugin/plugin.json`, shipped 2026-03-25) | Distribution | S | **HIGH — Codex build already exists** |
| 5f | **Roo Code refugee migration content** ("Switching from Roo to Claude-Code-native zuvo") | Marketing | S | **HIGH — Roo gone 2026-05-15, 2-week window** |
| 5g | **Fix `write-article` + `content-expand` friction** (96-100% friction rate over 174 invocations per ~/.zuvo/runs.log; primary causes: unclear-instruction 39%, unknown-writer-model routing degradation, infra timeouts) | Quality | M | **CRITICAL — flagship skills with worst friction** |
| 5h | **Decide: deprecate vs specialist-pivot for `design`/`design-review`/`ui-design-team`** (0 invocations in 33 days; Anthropic Claude Design shipped Apr 2026 = direct overlap) | Strategy | S | **Decision needed** |
| 5i | **Deprecate or split 21 unused skills** (worktree, debug, api-audit, ci-audit, env-audit, geo-audit/fix, content-migration, fix-tests, write-e2e, deploy, canary, release-docs, retro, presentation, backlog, incident — all 0 invocations). Options: delete, hide behind `--experimental`, or split to `zuvo-extras` plugin | Strategy | M | **Decision needed** |
| 5j | **Anti-CodeRabbit Agent positioning** (CodeRabbit Agent shipped 2026-04-22, 7 SDLC phases, single-agent. Zuvo moat: 14-dim audit breadth incl. perf/db/seo/geo/a11y/env they lack + adversarial multi-provider evidence). Update `zuvo:review` README + landing page messaging | Marketing | S | **HIGH** |

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
| 10e | **Severity vocabulary** — unified mapping across all 51 skills | Enhancement | S | ✅ DONE (2026-04-08) |
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
| 26 | **Antigravity build target** (4th platform; AGENTS.md at `~/.gemini/`, Workflows. No formal plugin spec yet = window) | Distribution | OPEN |
| 27 | **ACP adapter** (Zed + JetBrains via Agent Client Protocol, Jan 2026) | Distribution | OPEN |
| 28 | **`zuvo:context-budget` skill** (Claude rate-limit crisis Mar-Apr 2026; uses new Claude Code `updatedToolOutput` hook for all tools + `duration_ms` from PostToolUse to trim/summarize tool outputs in-flight) | New skill | OPEN |
| 29 | **Lean MCP mode** (Cursor 40-tool ceiling silently drops over the cap — CodeSift alone has 51+95 tools) | Architecture | OPEN |
| 30 | **`--frase` mode in `write-article`/`content-expand`** (optional Frase MCP brief grounding for SERP-aware content; user supplies their own Frase key) | Enhancement | OPEN |
| 31 | **Adopt Martian benchmark methodology in `zuvo:agent-benchmark`** (Feb 2026 first independent test of 17 AI review tools across 300k PRs) | Enhancement | OPEN |

---

## Appendix: Competitor Star Counts (top 40, refreshed 2026-05-01)

| Rank | Competitor | Stars | Category | Change since 2026-04-08 |
|------|-----------|-------|----------|--------|
| 1 | **affaan-m/everything-claude-code** | **158,000** | Skill library | **+30K (Global Rank #40)** |
| 2 | **obra/superpowers** | **~150,000** | Workflow pipeline | **+108K (3.5x in 3 months)** |
| 3 | Claw Code (clean-room Claude Code rewrite) | 172,000 | Harness | unchanged |
| 4 | claude-mem | 46,100 | Memory | unchanged |
| 5 | awesome-claude-code | 37,339 | Awesome list | unchanged |
| 6 | wshobson/agents | 33,091 | Orchestration | unchanged |
| 7 | **Yeachan-Heo/oh-my-claudecode** | **~31,300** | Multi-model team | **+30K (was ~1K, large jump)** |
| 8 | ruvnet/ruflo (ex Claude Flow) | 25,000 | Agent framework | unchanged |
| 9 | OthmanAdi/planning-with-files | 18,178 | Planning | unchanged |
| 10 | jarrodwatts/claude-hud | 17,303 | Observability | unchanged |
| 11 | anthropics/claude-plugins-official | 16,298+ | Registry | growing |
| 12 | VoltAgent/awesome-agent-skills | **~14,686** (now indexes 1000+ skills) | Directory | unchanged |
| 13 | quemsah/awesome-claude-plugins | unverified | Aggregator | NEW — indexes **14,634 repos** via n8n, last update 2026-04-28 |
| 14 | wasp-lang/open-saas | 13,930 | SaaS bundle | unchanged |
| 15 | EveryInc/compound-engineering-plugin | 13,605 | Workflow | **v3.0.3 — now 36 skills + 51 agents** (was ~10 skills) |
| 16 | mattpocock/skills | 12,637 | Personal skills | unchanged |
| 17 | blader/humanizer | 12,618 | Single skill | unchanged |
| 18 | anthropics/knowledge-work-plugins | 10,960 | Knowledge work | unchanged |
| 19 | alirezarezvani/claude-skills | unclear: 5,200–9,975 (sources diverge) | Skill library | flagged as unverifiable |
| 20 | numman-ali/openskills | 9,456 | Skills loader | unchanged |
| 21 | Understand-Anything | 7,913 | Knowledge graph | unchanged |
| 22 | ykdojo/claude-code-tips | 7,190 | Tips/education | unchanged |
| 23 | slavingia/skills | 7,066 | Business skills | unchanged |
| 24 | devin.cursorrules | 5,963 | Self-evolving agent | unchanged |
| 25 | vibe-tools | 4,752 | Tool integrations | unchanged |
| 26 | ComposioHQ/agent-orchestrator | 4,700 | Orchestration | unchanged |
| 27 | JuliusBrussee/caveman | 4,373 | Token reduction | unchanged |
| 28 | trailofbits/skills | 4,364 | Security skills | unchanged |
| 29 | Anthropic-Cybersecurity-Skills | 4,077 | Cybersecurity | unchanged |
| 30 | sanjeed5/awesome-cursor-rules-mdc | 3,433 | Rules generator | unchanged |
| 31 | agenticnotetaking/arscontexta | 3,054 | Knowledge system | unchanged |
| 32 | ralphy | 2,723 | Autonomous loop | unchanged |
| 33 | davepoon/buildwithclaude | 2,707 | Hub | unchanged |
| 34 | ZeframLou/call-me | 2,553 | Notification | unchanged |
| 35 | nyldn/claude-octopus | 2,449 | Multi-model review | unchanged (52 skills) |
| 36 | revfactory/harness | 2,024 | Meta-skill | unchanged |
| 37 | jeremylongshore/claude-code-plugins-plus-skills | 1,871 | Mega collection | **now 423 plugins / 2,849 skills / 177 agents** (v4.24.0+) |
| 38 | rohitg00/pro-workflow | 1,739 | Self-correcting | unchanged |
| 39 | rohitg00/awesome-claude-code-toolkit | trending #1 GitHub Feb 2026 | Aggregator | NEW — 135 agents, 35 skills, +400K via SkillKit, 176 plugins, 14 MCP |
| 40 | levnikolaevich/claude-code-skills | ~1,000 | SDLC + 3 own MCP servers | unchanged |
| 41 | dsifry/metaswarm | ~500 | Multi-agent orchestration | unchanged |
| 42 | wondelai/skills | 473 | Book-as-skill | unchanged |

## Appendix B: Major Platform Events (refreshed through 2026-05-01)

| Date | Event | Impact on zuvo |
|------|-------|----------------|
| 2026-04-30 | **OpenAI GPT-5.5** ships, default for Codex CLI | Codex skills get faster default model |
| 2026-04-24 | **GitHub Copilot inline agent mode (preview)** for JetBrains IDEs | Cross-IDE agentic pressure |
| 2026-04-22 | **CodeRabbit Agent** — single agent across 7 SDLC phases, CLI `--agent` JSON output, Issue Planner beta | **HIGH threat — direct overlap with brainstorm > plan > execute > review pipeline** |
| 2026-04-20 | **Roo Code shutdown announced** (gone 2026-05-15), pivots to Roomote cloud | **Refugee capture window 2-3 weeks** |
| 2026-04-16 | **Claude Opus 4.7** ships (requires Claude Code v2.1.111+) | Default model for zuvo flagship audits |
| 2026-04-16 | **Codex App in-app browser** (visual bug repro) | Browser-control surface |
| 2026-04 (date unclear) | **Anthropic Claude Design** product launches | Direct hit on zuvo design skills (which have 0 invocations) |
| 2026-04-04 | **Anthropic per-token pricing** for third-party CLI tools (Cline/etc. on Max/Pro) | Pushes users to Claude-Code-native skills like zuvo |
| 2026-04-02 | **Cursor 3** launches — Agents Window, Design Mode, multi-folder workspaces, RL retraining ~5h | Paradigm shift; plugin model cannot replicate Agents Window |
| 2026-04-01 | **Copilot Cloud Agent** renamed, self-review + security scanning | Zero-friction from Issues remains Copilot's moat |
| 2026-03-31 | **Claude Code rate-limit / quota crisis** widely reported (MacRumors, Register, Axios) — Max users burn 5h windows in 1-2h | Token-frugal design (lazy includes) is now table-stakes; opportunity for `zuvo:context-budget` |
| 2026-03-31 | **Claude Code source leak** via npm sourcemap (512K lines, 1,906 files) | Ecosystem shift — open-source harnesses proliferate |
| 2026-03-25 | **Codex Plugin System** launches — `.codex-plugin/plugin.json`, built-in `@plugin-creator` | Zuvo's Codex build target = first-class |
| 2026-03-17 | **GPT-5.4-mini** (30% cost, 2× faster) | Cheaper Codex skill execution |
| 2026-03-11 | **Cursor Marketplace +30 partner plugins** (Atlassian, Datadog, GitLab, PlanetScale, etc.) | Marketplace filling fast |
| 2026-03-05 | **GitHub Copilot agentic code review GA** — 60M reviews to date, autopipes to coding agent | **HIGH threat — distribution moat** |
| 2026-03-05 | **GPT-5.4** with 1M context (experimental) + native computer-use | Codex closes context gap with Sonnet |
| 2026-02-24 | Anthropic Private Plugin Marketplaces — 101 plugins official | Enterprise distribution opportunity |
| 2026-02-17 | **Cursor Marketplace launches** (Cursor 2.5) — formal plugin spec with SKILL.md, hooks, MCP | (correction: was reported as April; actually February) |
| 2026-02 | **Qodo 2.0** ranks #1 in Martian benchmark (60.1% F1, 17 review tools tested) | Use Martian methodology in `zuvo:agent-benchmark` |
| 2026-02 | **Frase MCP** — first SEO platform with read-write MCP | Optional `--frase` integration for content skills |
| 2026-02-12 | GPT-5.3-Codex-Spark preview (1000+ tok/s) | Fast Codex skill iteration |
| 2026-02-05 | **Claude Sonnet 4.6** + **Anthropic Agent Teams** (v2.1.32, env-gated) | Enabler/competitor for zuvo multi-agent dispatch |
| 2026-02-05 | **GPT-5.3-Codex** (+25% faster) | Codex baseline bump |
| 2026-02 | **Anthropic `/security-review` and `/review`** as native Claude Code built-ins; `/security-review` has GitHub Action | **HIGH threat to `zuvo:security-audit` + `zuvo:review`** |
| 2026-01-22 | Codex deprecates custom prompts in favor of skills | Validates zuvo's Codex build |
| 2026-01-XX | **Zed + JetBrains ACP (Agent Client Protocol)** | Potential 5th build target |
| 2026-01-15 | Superpowers accepted to Anthropic Verified marketplace → 3.5× star growth | **CRITICAL distribution proof point** |
| 2025-12-19 | **Codex Agent Skills standard** (agentskills.io) | Zuvo Codex build = first-class |
| 2025-12-18 | GPT-5.2-Codex | — |
| 2025-11-18 | **Google Antigravity** public preview (Gemini 3 Pro, AGENTS.md, no formal plugin spec) | **Window of opportunity for 4th build target** |

## Appendix C: Ecosystem Metrics (refreshed 2026-05-01)

| Metric | Count | Source |
|--------|-------|--------|
| Claude Code GitHub stars | 82K+ | github.com/anthropics/claude-code |
| Indexed Claude Code plugin repos | 10,913 → growing | quemsah/awesome-claude-plugins indexes 14,634 repos (2026-04-28) |
| Official marketplace plugins | 101+ (33 Anthropic + 68 partner, 2026-02-24 baseline) | anthropics/claude-plugins-official |
| Community marketplaces | 43+ (834+ total plugins) | aggregate |
| **agentskill.sh indexed skills** | **107,000–110,000** (was 87K) | agentskill.sh — Dev/Eng: 124K, PM: 39K |
| AI agent skills packages (all platforms) | 350,000+ | aggregate |
| **agentskills.io standard** | adopted by 26+ platforms | agentskills.io |
| **Cursor Marketplace plugins** | ~30 partner (launch baseline Feb 2026) + community | cursor.com/marketplace |
| **Zuvo skills** | **51** (was 48 on 2026-04-08) | CLAUDE.md |
| **Zuvo daily-active skills** | 30 of 51 (~59%); 21 zero-use over 33 days | ~/.zuvo/runs.log |

---

## Update Summary (2026-05-01)

- 14 sections updated with refreshed star counts, skill counts, dates
- 2 new sections added: Tier 1c (newly discovered competitors), Tier 3 expansion (15 new entries)
- 9 new platform events added to Appendix B
- 11 new TIER 1 / TIER 4 actions added to action plan
- 2 corrections: Cursor Marketplace launched 2026-02-17 (was reported as April 2); Skills.sh 87K → agentskill.sh 107-110K
- 3 unverifiable items flagged (alirezarezvani star count, several MadeByTokens/aaron-he-zhu/AgriciDaniel star counts)

<!-- Evidence Map
| Section | Source |
|---------|--------|
| Header skill count (51) | /Users/greglas/DEV/zuvo-plugin/CLAUDE.md, skills/using-zuvo/SKILL.md banner |
| CQ/Q/CAP gate counts | skills/using-zuvo/SKILL.md banner: "CQ1-CQ29 + Q1-Q19" |
| zuvo daily-active 30/51 | /Users/greglas/.zuvo/runs.log (33-day window 2026-03-28→2026-04-29, 485 entries) |
| write-article 96-100% friction | /Users/greglas/.zuvo/retros.log (105 structured entries 2026-04-12→2026-04-29) |
| Superpowers 42K→150K | web research 2026-04-30 (general-purpose agent) |
| everything-claude-code 158K | web research 2026-04-30 |
| Cursor Marketplace 2026-02-17 launch | cursor.com/blog/marketplace |
| CodeRabbit Agent 2026-04-22 | docs.coderabbit.ai/changelog |
| Roo Code shutdown 2026-04-20 | bodegaone.ai/blog/roo-code-shutdown-alternatives |
| Anthropic Claude Code Security 500+ vulns | anthropic.com/news/claude-code-security |
| Copilot agentic GA 2026-03-05 | github.blog/changelog/2026-03-05-... |
| Frase MCP read-write Feb 2026 | frase.io/blog/ai-agents-for-seo |
| Antigravity preview 2025-11-18 + Gemini 3 Pro | developers.googleblog.com, antigravity.google/docs |
| ACP (Zed/JetBrains) | reported via web research 2026-04-30 |
| GPT-5.5 default 2026-04-23 | developers.openai.com/codex/changelog |
| Opus 4.7 2026-04-16 | code.claude.com/docs/en/changelog |
| agentskill.sh 107-110K | web research 2026-04-30 |
| Anthropic per-token third-party 2026-04-04 | relayplane.com/blog/anthropic-extra-usage-third-party-tools |
-->

*Updated 2026-05-01. Based on research across GitHub, web search, AI tool documentation, and the live ~/.zuvo/runs.log + retros.log usage data.*
