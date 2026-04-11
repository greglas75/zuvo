---
name: security-audit
description: "Application security audit covering OWASP Top 10, injection, XSS, SSRF, auth/authz, multi-tenant isolation, secrets, headers, dependencies, business logic, and infrastructure. Uses Sentry 3-tier confidence model. Supports Next.js, NestJS, Express, FastAPI, Django, Flask. Dual scoring: static posture + runtime exploitability. Flags: zuvo:security-audit [path] | full | --live-url <url> | --static | --quick | --persist-backlog"
---

# zuvo:security-audit — Application Security Audit

Comprehensive security assessment across 15 dimensions (S1-S15) covering OWASP Top 10 2021, OWASP LLM Top 10, application security, AI/LLM integration security, and infrastructure hardening. Every finding is filtered through a Sentry-inspired 3-tier confidence model: HIGH confidence findings in the main report, MEDIUM in a "Needs Verification" section, LOW excluded entirely.

**When to use:** Before releases, after adding auth or payment flows, after security incidents, periodic quarterly health check, when onboarding a new codebase.
**Out of scope:** Single-file code review (use `zuvo:review`), API contract audit (use `zuvo:api-audit`), performance issues (use `zuvo:performance-audit`), penetration testing with exploit verification (use `zuvo:pentest`).

## Argument Parsing

| Argument | Effect |
|----------|--------|
| `[path]` | Audit a specific directory or module |
| `full` | Audit the entire project |
| `--live-url <url>` | Enable Phase 8 (live probing) against the specified URL |
| `--static` | Static analysis only -- skip Phase 8 even if `--live-url` present |
| `--quick` | Quick mode: secrets + auth coverage + critical gates only |
| `--persist-backlog` | Emit backlog entries for CRITICAL/HIGH findings |

| Mode | Scope | Phases | Live Probes |
|------|-------|--------|-------------|
| `[path]` | Directory | 1-7, 9-10 | No |
| `full` | Entire project | All | No |
| `--live-url` | Project + URL | All incl. Phase 8 | Yes |
| `--quick` | Project | 3 critical gates | No |
| `--static` | Project | 1-7, 9-10 | No |

## Mandatory File Loading

Read in two stages to reduce upfront cost.

**Stage 1 -- Before Phase 0 (STOP if any missing):**

```
CORE FILES LOADED:
  1. ../../rules/cq-checklist.md            -- READ/MISSING
  2. ../../rules/security.md                -- READ/MISSING
  3. ../../shared/includes/env-compat.md    -- READ/MISSING
  4. ../../shared/includes/codesift-setup.md -- READ/MISSING
```

**Stage 2 -- Before Phase 10 (report writing):**
```
  5. ../../shared/includes/backlog-protocol.md -- READ/MISSING
  6. ../../shared/includes/run-logger.md       -- READ/MISSING
  7. ../../shared/includes/retrospective.md       -- READ/MISSING
```

Stage 2 deferred to save ~300 lines of upfront context.

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for agent dispatch, path resolution, and progress tracking.

## CodeSift Integration

Read `../../shared/includes/codesift-setup.md` for the full initialization sequence.

**Summary:** Run the CodeSift setup from `codesift-setup.md` at skill start. Use CodeSift for all code analysis when available. If unavailable, fall back to grep/find.

### CodeSift Optimizations

| Task | CodeSift | Fallback |
|------|----------|----------|
| Auth coverage scan | `search_symbols(repo, "UseGuards\|requireAuth\|withAuth", include_source=true)` | `Grep` for auth decorators |
| Injection sink discovery | `search_text(repo, "queryRawUnsafe\|eval\\(\|exec\\(", regex=true)` | `Grep` for dangerous sinks |
| Handler deep inspection | `find_and_show(repo, query, include_refs=true)` | Sequential Read + Grep |
| Defense in depth | `trace_call_chain(repo, symbol_name, direction="callers", depth=2)` | Single-level grep |
| Blast radius for auth gaps | `impact_analysis(repo, since="HEAD~10")` | `Grep` for imports |

### Degraded Mode (CodeSift unavailable)

| CodeSift tool | Fallback | Lost capability |
|---------------|----------|-----------------|
| `search_symbols` (auth) | `Grep` for decorator patterns | Less precise matches |
| `search_text` (sinks) | `Grep` with regex | Same coverage, more tokens |
| `trace_call_chain` | `Grep` for imports | No transitive caller analysis |
| `impact_analysis` | `Grep` for import paths | No automatic affected test detection |
| `find_and_show` | Sequential `Read` + `Grep` | 3x more calls |

---

## Safety Gates (NON-NEGOTIABLE)

### GATE 1 -- No Production Scanning

| Environment | Static Analysis | Live Tests (--live-url) |
|-------------|----------------|------------------------|
| Production | Proceed (code read only) | REFUSE -- ask for staging/localhost |
| Staging | Proceed | Present plan, get approval, proceed |
| Localhost | Proceed | Proceed freely (read-only GET probing) |

Default: static analysis proceeds, live tests REFUSE until user clarifies.

Mutation requests (POST/PUT/DELETE) in live tests: REFUSE unless user explicitly approves per-endpoint. Security audits observe, they do not modify state.

### GATE 2 -- PII and Credential Censorship

All output scrubbed: Bearer tokens, API keys, emails, passwords, AWS signatures, session tokens, cookies, connection strings replaced with `***`.

### GATE 3 -- Script Execution

Discovery scripts >20 lines: save to file, `chmod +x`, execute. No long inline scripts.

### GATE 4 -- Tool Scope

This audit is read-only against production code. Sole write target: `audits/`. Forbidden: modifying source files, sending requests to production, installing packages, running DB mutations.

---

## CQ Integration

| CQ | Security Dimension | Depth |
|----|-------------------|-------|
| CQ3 | S9 (Input Validation) -- schema completeness at all entry points | Extended |
| CQ4 | S5 (Authorization) -- defense in depth: guard + query filter | Extended |
| CQ5 | S7+S12 (Secrets + Logging) -- no secrets in logs/responses | Extended |

If `zuvo:review` or `zuvo:code-audit` already scored these CQs, focus on what they miss: cross-endpoint auth gaps, multi-tenant isolation, infrastructure, and attack paths.

---

## Phase 0: Detection and Scope

### 0.1 Stack Detection

Run a detection script covering backend frameworks (NestJS, Express, Next.js, FastAPI, Django, Flask), auth patterns (JWT, sessions), infrastructure (Docker, CI/CD, K8s, Terraform), existing security tooling (Helmet, rate limiters, validation), and multi-tenant signals.

### 0.2 Load Stack-Specific Rules

Based on detection, load the applicable conditional rules from `../../rules/`:

| Stack | Load |
|-------|------|
| Next.js | `../../rules/react-nextjs.md` |
| NestJS | `../../rules/nestjs.md` |
| Python (FastAPI/Django/Flask) | `../../rules/python.md` |

Load ALL that match. Most projects have 2-3 applicable stacks.

### 0.3 Tool Detection

```bash
which semgrep 2>/dev/null && echo "SEMGREP: available" || echo "SEMGREP: not installed"
which gitleaks 2>/dev/null && echo "GITLEAKS: available" || echo "GITLEAKS: not installed"
npm --version 2>/dev/null && echo "NPM: available"
which pip-audit 2>/dev/null && echo "PIP-AUDIT: available"
```

Semgrep available: run in Phase 2. Not available: grep-based analysis sufficient. Note in report as `Status: STANDARD (grep-based)`. No score penalty.

### 0.4 Client-Side Scope Adjustment

If scope is limited to client-side files only:

| Dimension | Applies? | Reason |
|-----------|---------|--------|
| S1 (Injection) | Limited | Only raw string concat in URLs or innerHTML |
| S2 (XSS) | Yes | Check dangerouslySetInnerHTML, document.write, eval |
| S3 (SSRF) | No | Client fetch goes through browser |
| S4-S6 (Auth/AuthZ/Tenant) | No | Server responsibility |
| S7 (Secrets) | Check | Hardcoded API keys in client bundle |
| S8 (Headers) | No | Server-side |
| S9 (Validation) | Yes | API response validation |
| S10-S14 | No | Server-side concerns |

All client-side: cap tier at LIGHT, skip server-focused phases.

### 0.5 Tier Selection

| Tier | When | Phases |
|------|------|--------|
| QUICK | `--quick` flag | 0, 1, critical gates only |
| LIGHT | Single module, <5 endpoints | 0-4, 9-10 |
| STANDARD | Full service, 5-30 endpoints | 0-7, 9-10 |
| DEEP | Pre-release, >30 endpoints, payments/auth | All 0-10 |

**Risk signals forcing DEEP:** payment/financial endpoints, auth/identity service, multi-tenant isolation, file uploads, external API integrations.

### 0.6 Endpoint Inventory

Build complete endpoint list per stack using grep discovery patterns. Cross-check with OpenAPI spec if present.

---

## Phase 1: Dependency and Secrets Scan

### 1.1 Dependency Vulnerabilities (S11)

```bash
npm audit --json 2>/dev/null || pnpm audit --json 2>/dev/null
pip-audit --format json 2>/dev/null
```

For each CRITICAL/HIGH CVE: check reachability (directly imported?), check exploit path (usage matches vulnerability?), assign confidence.

### 1.1b Supply Chain Analysis (S11 enhancement)

Check for behavioral supply chain risks: install scripts, native addons, recently published packages, no lockfile.

### 1.2 Secret Scanning (S7)

If gitleaks available:
```bash
gitleaks detect --source . --report-format json --no-git 2>/dev/null
```

If unavailable, grep-based:
```bash
rg "(api[_-]?key|secret[_-]?key|password|token)\s*[:=]\s*['\"][^'\"{}\$]" --type ts --type py -n -i
```

Filter false positives: exclude test files, `.env.example`, type definitions, comments.

### 1.3 Client-Side Secret Exposure (S7)

```bash
rg "NEXT_PUBLIC_.*KEY|NEXT_PUBLIC_.*SECRET|VITE_.*KEY|VITE_.*SECRET" --type ts -n
```

---

## Phase 2: Static Analysis and Server Controls (S8, S10, S12)

### 2.1 Semgrep (if available)

```bash
semgrep --config auto --json --output audits/artifacts/security/semgrep.json . 2>/dev/null
```

Parse results, cross-reference with confidence model, deduplicate against grep findings.

### 2.2 Headers and Transport (S8)

Check framework header config: Helmet, CSP, X-Frame-Options, HSTS. Score from code/config if no live URL. Phase 8 upgrades with runtime confirmation.

### 2.3 File Upload and Path Traversal (S10)

Check for multer/formidable/busboy usage, filename validation, path traversal defenses. No upload handling detected: S10=N/A.

### 2.4 Logging and Monitoring (S12)

Check for secrets in logs, error disclosure to clients, auth failure logging.

---

## Phase 3: Code Pattern Audit (S1, S2, S3, S9)

Run discovery patterns for Injection (S1), XSS (S2), SSRF (S3), and Input Validation (S9).

**Parallel** (Claude Code with Task tool): one agent per dimension, max 4 concurrent.
**Sequential** (Cursor, Codex): one dimension at a time inline.

### Per-Dimension Agent Instructions

Each agent must:
1. Check the exclusion list before reporting any finding
2. Check framework mitigations (Prisma parameterizes, React auto-escapes, etc.)
3. Verify input is attacker-controlled (not server-controlled)
4. Evaluate rationalizations to reject -- do not dismiss valid findings
5. Assign confidence: HIGH/MEDIUM/LOW using the 3-tier model
6. Only HIGH in main findings. MEDIUM in "Needs Verification". LOW excluded entirely.

For each grep match:
1. Read the full function containing the match
2. Trace input source -- attacker-controlled?
3. Check for framework mitigation
4. Check for explicit validation/sanitization
5. Assign confidence
6. HIGH/MEDIUM -> create finding. LOW -> skip silently.

Fix completeness: for findings involving data flow, the fix must cover BOTH source side (validation) and sink side (escaping/parameterization).

---

## Phase 4: Authentication and Authorization Audit (S4, S5)

Always manual (not parallelized) -- requires cross-endpoint reasoning.

### 4.1 Auth Architecture Assessment

Determine: auth type (JWT/session/API key/OAuth), where authN is enforced, where authZ is enforced, defense in depth (CQ4), session storage location.

### 4.2 Auth Coverage Matrix

Every endpoint must be classified:

```
| Endpoint | Method | Public? | Auth? | How? | Tenant? | Notes |
```

For each endpoint: check auth decorator, verify it checks the right thing (not just "logged in" but "can access THIS resource"), check query-level filter (CQ4 defense in depth).

Missing auth on mutation (POST/PUT/DELETE) -> CRITICAL finding (S4).
Guard exists but query does not filter by tenant/user -> HIGH finding (S5).

---

## Phase 5: Multi-Tenant Isolation (S6)

**Skip if:** No multi-tenant signals detected.

Check:
1. Tenant ID source: from auth token (SAFE) vs from request params (DANGEROUS)
2. Query-level isolation: every write operation includes tenant filter from session
3. Cross-tenant vectors: cache keys, queue messages, file storage, background jobs

---

## Phase 6: Business Logic (S13)

**Skip if:** LIGHT tier.

Check:
1. Race conditions: check-then-act patterns without atomicity
2. Price/amount server authority: client-submitted price used without re-fetch from DB
3. State machine bypass: can user skip steps by calling later-stage endpoint?

---

## Phase 7: Infrastructure (S14)

**Skip if:** No Docker/CI/K8s/Terraform detected.

- Docker: USER directive, secrets in layers, base image pinning, .dockerignore
- CI/CD: script injection, action pinning, permissions, secret handling
- K8s: pod security, network policies, secrets management
- Terraform: state file, provider credentials, insecure defaults

---

## Phase 7b: AI/LLM Integration Security (S15)

**Skip if:** No AI/LLM integration detected (no OpenAI, Anthropic, Google AI, Hugging Face, LangChain, LlamaIndex, MCP imports or API calls).

**Detection:**
```bash
rg "openai|anthropic|@google/generative|langchain|llamaindex|ai/sdk|@ai-sdk|mcp|claude|gpt|gemini" --type ts --type py --type js -l
```

If matches found, audit these 8 check areas:

### S15.1 Prompt Injection (OWASP LLM01)

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| User input in prompts | Parameterized templates, input sanitized before inclusion | Raw user input concatenated into system/user prompts | CRITICAL |
| System prompt protection | System prompt separated from user content, instruction hierarchy enforced | System prompt injectable via user content | CRITICAL |
| Indirect injection via RAG | Retrieved content sanitized, marked as untrusted data | RAG results inserted directly into prompt without sanitization | HIGH |
| MCP tool input validation | Tool parameters validated with schema before execution | Tool parameters passed directly from LLM output without validation | CRITICAL |

### S15.2 Sensitive Data Exposure (OWASP LLM06)

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| PII in prompts | PII stripped/masked before sending to LLM API | User PII (email, name, SSN, credentials) sent to external LLM | HIGH |
| Secrets in context | API keys, tokens, connection strings excluded from LLM context | Secrets appear in prompt context, system prompts, or tool outputs | CRITICAL |
| Response filtering | LLM output checked for sensitive data before returning to user | Raw LLM response returned without output validation | HIGH |
| Logging of prompts | Prompts redacted in logs, no PII in telemetry | Full prompts with user data logged to external observability | HIGH |

### S15.3 AI Supply Chain (OWASP LLM05)

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Model pinning | Model version pinned (e.g., `gpt-4o-2024-08-06`, `claude-sonnet-4-20250514`) | Using `latest` or unpinned model identifiers | MEDIUM |
| MCP server trust | MCP servers from known sources, tool descriptions reviewed | Third-party MCP servers with unreviewed tool descriptions | HIGH |
| AI SDK versions | AI SDKs pinned and audited like any other dependency | AI SDKs unpinned or using pre-release versions in production | MEDIUM |
| Embedding/vector store integrity | Vector DB content sourced from trusted origins | Embeddings from user-uploaded or scraped content without provenance | HIGH |

### S15.4 Output Handling (OWASP LLM02)

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Rendered LLM output | LLM text sanitized before HTML rendering (DOMPurify, escape) | LLM output rendered via dangerouslySetInnerHTML or similar | HIGH |
| Code execution from LLM | LLM-generated code sandboxed, reviewed before execution | `eval()` or `exec()` on raw LLM output | CRITICAL |
| Structured output validation | LLM JSON/structured output validated with Zod/JSON Schema | LLM output parsed with `JSON.parse` and used directly without schema | MEDIUM |
| Tool call validation | LLM tool calls validated against allowed tool set | LLM can invoke any tool without allowlist filtering | HIGH |

### S15.5 Rate Limiting and Cost Control (OWASP LLM04)

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Per-user rate limiting | AI endpoints rate-limited per user/org/IP | No rate limit on AI endpoints — single user can exhaust budget | HIGH |
| Cost budget enforcement | Hard budget cap with circuit breaker (Redis counter, middleware) | Budget tracked but not enforced, or no budget at all | HIGH |
| Token/request limits | Max input tokens and max output tokens configured per request | No token limits — user can send 100K token prompts | MEDIUM |
| Concurrent request limiting | Max concurrent AI requests per user | Unbounded concurrent AI requests possible | MEDIUM |

### S15.6 Agent and Memory Security

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Agent action scope | Agent actions bounded by allowlist, destructive ops require confirmation | Agent can perform any action including writes, deletes, network calls | HIGH |
| Memory/context poisoning | Agent memory validated, untrusted content marked | Conversation history or memory injectable by third-party content | HIGH |
| Multi-step chain safety | Chain-of-thought actions validated at each step | Multi-step agent chains with no intermediate validation | MEDIUM |
| Credential delegation | Agent uses scoped tokens with minimal permissions | Agent inherits full user session/admin credentials | CRITICAL |

### S15.7 Data Poisoning and RAG Safety

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| RAG source validation | Document sources verified, metadata preserved | Any user can upload documents to the RAG index | HIGH |
| Embedding integrity | Embedding pipeline isolated, re-indexing requires admin | Users can trigger re-indexing or inject documents | HIGH |
| Retrieval filtering | Retrieved chunks filtered by user permissions/tenant | RAG returns cross-tenant or unauthorized content | CRITICAL |
| Content freshness | Stale/outdated content flagged or excluded from retrieval | No staleness check on retrieved content | MEDIUM |

### S15.8 AI-Specific Infrastructure

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| API key management | AI API keys in secrets manager, rotated, scoped per environment | AI API keys hardcoded or in .env committed to git | CRITICAL |
| Fallback handling | Graceful degradation when AI service is unavailable | App crashes or hangs on AI provider timeout/error | HIGH |
| AI proxy isolation | AI calls routed through a dedicated proxy/gateway service | Direct AI API calls from frontend/client code | HIGH |
| Audit trail | AI interactions logged (input hash, model, tokens, cost, latency) | No audit trail for AI API calls | MEDIUM |

### S15 Scoring

```
S15=[0-10]
```

**Weight: 10** (same as S4/S5 — AI integrations are a primary attack surface in 2025+)

**Critical gate:** S15<3 when AI integration is present -> auto-escalate to AT RISK.

**S15 N/A:** If no AI/LLM integration detected, S15=N/A (excluded from score).

---

## Phase 8: Live Tests (OPTIONAL -- requires --live-url)

**Prerequisites (HARD GATE):**
1. `--live-url` provided
2. URL is NOT production (Gate 1)
3. User confirms environment

### 8.1 Security Headers (S8)

```bash
curl -sI "$LIVE_URL" | grep -iE "content-security|strict-transport|x-frame|x-content-type|permissions-policy"
```

### 8.2 Auth Endpoint Probing

```bash
curl -s -o /dev/null -w "%{http_code}" "$LIVE_URL/api/protected"
# Expected 401. If 200 -> CRITICAL auth bypass
curl -sI -H "Origin: https://evil.com" "$LIVE_URL/api/endpoint" | grep -i "access-control"
```

### 8.3 Error Information Disclosure

Trigger errors, check if stack traces or internal paths leak to clients.

Rate limiting: max 2 req/s. 3 consecutive 429s -> pause 30s. 3 consecutive 5xx -> STOP.
Scrub all responses (Gate 2).

---

## Phase 9: Cross-Cutting Analysis and Attack Paths

### 9.1 Reconciliation (MANDATORY before report)

1. Review ALL findings from Phases 1-8
2. Re-check each against: exclusion list, framework mitigations, attacker-controlled verification, rationalizations to reject
3. Check for contradictions between findings
4. Remove invalidated findings completely (not just marked)
5. Record what was removed and why (1 line per removal)

This prevents self-contradicting report sections.

### 9.2 Cross-References

After reconciliation, link related findings (same module, same root cause, same trust boundary gap). Add `Related: SEC-NNN` annotations.

### 9.3 Attack Path Construction

Construct top 3 attack paths combining findings:
1. **Entry point:** where attacker enters
2. **Steps:** exploitation sequence (2-5 steps)
3. **Impact:** what attacker achieves
4. **Mitigations present:** what partially blocks
5. **Mitigations missing:** what would prevent

Natural language descriptions, NOT proof-of-concept exploit code.

### 9.4 Defense Gap Analysis

Build summary table: input validation coverage, auth coverage, authZ depth (CQ4), tenant isolation, rate limiting, security headers, dependency scanning, secret scanning.

---

## Phase 9b: Adversarial Security Review (MANDATORY — do NOT skip)

Security audits benefit the most from cross-model review. Runs on ALL security audits.

```bash
adversarial-review --mode security --files "[auth files, middleware, controllers, env config]"
```

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Wait for complete output. Then:
- **CRITICAL** (auth bypass, injection, SSRF) → add to attack path analysis, fix in report before delivery
- **WARNING** → append to findings with `[CROSS]` tag
- **INFO** → ignore

---

## Phase 10: Report and Backlog

### 10.1 Score Calculation

Per dimension using standard rubrics:

```
S1=[0-10]  S2=[0-8]   S3=[0-8]   S4=[0-10]
S5=[0-10]  S6=[0-8]   S7=[0-8]   S8=[0-5]
S9=[0-8]   S10=[0-5]  S11=[0-5]  S12=[0-5]
S13=[0-5]  S14=[0-5]  S15=[0-10]
```

**N/A handling:** S6=N/A if not multi-tenant. S10=N/A if no file upload. S13=N/A if LIGHT. S14=N/A if no infra. S15=N/A if no AI/LLM integration. N/A excluded from both score and max.

**Score = sum of dimension scores / sum of max for non-N/A dimensions x 100**

**Score caps:**
- Any CRITICAL finding (confirmed, HIGH confidence) -> cap at 40
- Any HIGH finding (confirmed) -> cap at 60
- >5 MEDIUM findings -> cap at 70

**Critical gates:** S1=0 OR S4<3 OR S5<3 OR S7=0 OR (S15<3 AND S15!=N/A) -> auto-fail to CRITICAL.

**Health grades:** >=80% HEALTHY, 60-79% NEEDS ATTENTION, 40-59% AT RISK, <40% CRITICAL.

### Dual Score Computation

- **Static Posture Score:** S1-S14 from code analysis (Phases 1-7, 9). Weighted: CRITICAL=-15, HIGH=-8, MEDIUM=-3. Base=100.
- **Runtime Exploitability Score:** Verified exploits from Phase 8. VERIFIED=-20, PLAUSIBLE=-10, BLOCKED=0. Base=100. If no `--live-url`, print "NOT ASSESSED."

Always show both scores in Executive Summary.

### 10.2 Write Report

Save to: `audits/security-audit-[date].md`
Artifacts to: `audits/artifacts/security/`

Report includes: metadata, threat model, executive summary, dimension scores (S1-S14), auth matrix, top 3 attack paths, all findings (grouped CRITICAL -> HIGH -> MEDIUM -> Needs Verification), dependency vulnerabilities, infrastructure findings, defense gap analysis, remediation roadmap (immediate / short-term / medium-term / long-term).

### Finding Format

```
### SEC-{NNN}: {Title}
Dimension: S{N} -- {name}
Severity: CRITICAL / HIGH / MEDIUM
Confidence: HIGH / MEDIUM
CWE: CWE-{NNN}
OWASP: A{N}:2021
File: {path}:{line}
Evidence: {code snippet, scrubbed, max 15 lines}
Impact: {what an attacker can achieve}
Fix: {remediation with code example}
Related: {SEC-NNN if same root cause}
```

### 10.3 Report Validation (MANDATORY)

Before finishing, re-read the report and verify:

1. **Text integrity:** No truncated sentences, broken markdown, missing sections
2. **Count consistency:** Executive summary counts match actual findings per section
3. **Score math:** Dimension scores sum to total. Max = sum of non-N/A maxes. Percentage correct.
4. **Sequential numbering:** SEC-001, SEC-002, SEC-003 with no gaps

Fix any issues in-place before proceeding.

### 10.4 Backlog Persistence

**Default: off.** Activate with `--persist-backlog` or explicit user request.

When active, persist CRITICAL and HIGH findings to `memory/backlog.md`:

Fingerprint: `file|dimension|endpoint`. Prevents duplicate entries across audits.

Full protocol: `../../shared/includes/backlog-protocol.md`.

### 10.5 Next-Action Routing

| Condition | Suggested Action |
|-----------|-----------------|
| CRITICAL injection (S1) | `zuvo:pentest --dimensions PT1` -- verify exploitability |
| Auth gaps on mutations (S4<3) | `zuvo:code-audit [controllers]` -- audit CQ4/CQ5 across endpoints |
| Secrets found (S7=0) | Rotate secrets immediately, add pre-commit gitleaks hook |
| Multi-tenant gaps (S6<5) | `zuvo:code-audit [services]` -- audit query-level isolation |
| Header/transport gaps (S8) | Quick config fix -- add Helmet/CSP/HSTS |
| AI integration gaps (S15<5) | `zuvo:ai-security-audit` -- deep dive on prompt injection, RAG poisoning, MCP security |
| All dimensions >= 8 | No urgent action. Schedule next audit in 90 days. |

## SECURITY AUDIT COMPLETE

Run: <ISO-8601-Z>\tsecurity-audit\t<project>\t-\t-\t<VERDICT>\t-\t<N>-dimensions\t<NOTES>\t<BRANCH>\t<SHA7>\t<INCLUDES>\t<TIER>


### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

VERDICT mapping: HEALTHY -> PASS, NEEDS ATTENTION -> WARN, AT RISK or CRITICAL -> FAIL.

---

## Execution Notes

- Use **Sonnet** for QUICK/LIGHT/STANDARD tiers
- Use **Opus** for DEEP tier
- Phase 3 dimensions (S1/S2/S3/S9) can parallelize with up to 4 Task agents in Claude Code
- Read the project's AGENTS.md or CLAUDE.md first for stack-specific conventions
- QUICK mode skips full mandatory reads (inline output only)
- Estimated durations: QUICK ~3 min, LIGHT ~10 min, STANDARD ~20 min, DEEP ~30 min
