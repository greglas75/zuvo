---
name: api-audit
description: "API and endpoint integrity audit across 10 dimensions (D1-D10) plus optional contract stability (D11). Covers validation, payloads, pagination, errors, caching, HTTP semantics, waterfalls, rate limiting, auth, and documentation. Supports NestJS, Cloudflare Workers, FastAPI, and frontend call patterns. Optional GET probing on non-production targets. Flags: zuvo:api-audit full | [path] | --static"
---

# zuvo:api-audit — API and Endpoint Integrity Audit

Standalone audit of how the application exposes, consumes, and validates data across API boundaries. Evaluates endpoints through 10 weighted dimensions, builds an auth matrix, and runs cross-cutting analysis on contract consistency, money field representation, and payload efficiency.

**When to use:** Periodic health check of the API layer, before major releases, after adding new endpoints, when investigating overfetching or waterfall issues.
**Out of scope:** Single-file code review (use `zuvo:review`), refactoring (use `zuvo:refactor`), security posture analysis (use `zuvo:security-audit`), feature development (use `zuvo:build`).

## Argument Parsing

| Argument | Effect |
|----------|--------|
| `full` | Audit all endpoints in the project |
| `[path]` | Audit endpoints in a specific directory or module |
| `--static` | Static analysis only -- skip Phase 2 (GET probing). Use when no running server is available. |

## Mandatory File Loading

Read these files from disk before starting. Print the checklist. Do not proceed from memory.

```
CORE FILES LOADED:
  1. {plugin_root}/rules/cq-checklist.md            -- READ/MISSING
  2. {plugin_root}/rules/security.md                -- READ/MISSING
  3. {plugin_root}/shared/includes/env-compat.md    -- READ/MISSING
  4. {plugin_root}/shared/includes/codesift-setup.md -- READ/MISSING
```

Where `{plugin_root}` resolves per `env-compat.md`.

**If any file is missing:** Stop. The audit requires the full rule set to score correctly.

## Environment Compatibility

Read `{plugin_root}/shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking.

## CodeSift Integration

Read `{plugin_root}/shared/includes/codesift-setup.md` for the full initialization sequence.

**Summary:** Run the CodeSift setup from `codesift-setup.md` at skill start. Use CodeSift tools for endpoint discovery and handler inspection when available. If unavailable, fall back to grep/find scripts.

### CodeSift Optimizations

| Task | CodeSift | Fallback |
|------|----------|----------|
| Endpoint discovery | `get_file_tree(repo, name_pattern="route.ts")` + `get_file_outline` | grep/find scripts |
| Route handler inspection | `get_file_outline(repo, file_path)` on route files | `Read` each route file |
| Batch handler reads | `get_symbols(repo, symbol_ids=[...])` | Multiple `Read` calls |
| Auth call chain verification | `trace_call_chain(repo, symbol_name, direction="callees", depth=2)` | Manual grep |
| Validation coverage | `search_symbols(repo, query="withValidation", include_source=true)` | `Grep` for validation patterns |
| Auth pattern scanning | `search_text(repo, query="withAuth\|withWorkspace", regex=true)` | `Grep` for auth decorators |
| Error handling consistency | `find_references(repo, "AppError")` | `Grep` for error class usage |
| Response type analysis | `search_symbols(repo, kind="type", query="Response", include_source=true)` | `Grep` for type definitions |

### Degraded Mode (CodeSift unavailable)

All endpoint discovery falls back to grep/find scripts (Phase 0.3). Handler analysis requires full file reads. Auth chain verification loses transitive analysis (only direct callers visible).

---

## Safety Gates (NON-NEGOTIABLE)

### GATE 1 -- HTTP Request Policy

| Environment | Detection | GET / OPTIONS | POST / PUT / DELETE |
|-------------|-----------|--------------|---------------------|
| Production | Known prod domains, CI env vars | REFUSE -- ask for sandbox URL | REFUSE |
| Staging | User confirms "staging" | Present plan, get batch approval, execute | Present plan, get batch approval, execute |
| Localhost / sandbox | `localhost`, `127.0.0.1`, user confirms | Proceed freely | REFUSE unless user explicitly approves per-endpoint |

Default (no environment confirmed): treat as production. REFUSE all requests until user clarifies.

### GATE 2 -- PII and Credential Censorship

When logging API responses, headers, or payloads:
- Replace Bearer tokens: `Bearer ***`
- Replace API keys: `x-api-key: ***`
- Replace emails: `***@***.***`
- Replace passwords: `***`
- Strip AWS signatures, session tokens, cookies

All output files and reports must be scrubbed before writing.

### GATE 3 -- Script Execution

Discovery scripts >20 lines MUST be saved to file first, then `chmod +x`, then executed. No pasting long scripts into the terminal.

---

## CQ Integration

This audit extends (not duplicates) the CQ checklist:

| CQ | API Audit Dimension | Depth |
|----|---------------------|-------|
| CQ3 | D1 (Validation) -- schema completeness across ALL endpoints | Extended |
| CQ5 | D9 (Auth) -- secret exposure in headers/responses | Extended |
| CQ7 | D3 (Pagination) -- query bounds and payload size | Extended |
| CQ16 | D2 (Payload) -- money field representation across endpoints | Extended |
| CQ19 | D1+D2 -- runtime schema on both request AND response | Extended |
| CQ20 | D2 (Payload) -- dual fields in response payloads | Extended |

If `zuvo:review` already scored these CQs, focus on what CQ self-eval misses: cross-endpoint consistency, client-side waterfall patterns, caching strategy, and system-wide contract drift.

---

## Phase 0: Detection and Scope

### 0.1 Stack Detection

Save as script, `chmod +x`, execute:

```bash
#!/bin/bash
set -euo pipefail
SRC="${1:-.}"
echo "=== API STACK DETECTION ==="
NEST_CTRL=$(find "$SRC" -name "*.controller.ts" 2>/dev/null | wc -l)
[ "$NEST_CTRL" -gt 0 ] && echo "NestJS: $NEST_CTRL controllers"
WRANGLER=$(find "$SRC" -name "wrangler.toml" 2>/dev/null | wc -l)
[ "$WRANGLER" -gt 0 ] && echo "Cloudflare Workers: $WRANGLER configs"
FASTAPI=$(grep -rl "APIRouter\|FastAPI()" "$SRC" --include="*.py" 2>/dev/null | wc -l || true)
[ "$FASTAPI" -gt 0 ] && echo "FastAPI: $FASTAPI routers"
REACT_QUERY=$(grep -rl "useQuery\|useMutation" "$SRC" --include="*.ts" --include="*.tsx" 2>/dev/null | wc -l || true)
[ "$REACT_QUERY" -gt 0 ] && echo "React Query: $REACT_QUERY files"
RAW_FETCH=$(grep -rl "fetch(\|axios\." "$SRC" --include="*.ts" --include="*.tsx" 2>/dev/null | wc -l || true)
[ "$RAW_FETCH" -gt 0 ] && echo "Raw fetch/axios: $RAW_FETCH files"
ZOD=$(grep -rl "z\.object\|z\.string" "$SRC" --include="*.ts" 2>/dev/null | wc -l || true)
CLASS_VAL=$(grep -rl "@IsString\|@IsNotEmpty\|ValidationPipe" "$SRC" --include="*.ts" 2>/dev/null | wc -l || true)
echo "Validation: Zod=$ZOD, ClassValidator=$CLASS_VAL"
echo "=== DETECTION COMPLETE ==="
```

### 0.2 Tier Selection

| Tier | When | Dimensions | Probing |
|------|------|-----------|---------|
| LIGHT | Single module, <10 endpoints | D1, D2, D3, D4, D9 | Static only |
| STANDARD | Full service, 10-50 endpoints | D1-D9 (+D11 if spec exists) | Static + GET probing |
| DEEP | Cross-service, >50 endpoints, pre-release | D1-D11 (all + documentation + contract stability) | Static + GET + response analysis |

**Risk signals that force DEEP tier:**
- Payment/money endpoints
- Auth/permission endpoints
- Multi-tenant data isolation
- External API integrations
- File upload/download endpoints

### 0.3 Endpoint Inventory

Build a complete endpoint list before auditing.

When CodeSift is available: `get_file_tree(repo, name_pattern="route.ts")` + `get_file_outline` per route file. Use `search_text(repo, query="@Get|@Post|@Put|@Delete", regex=true)` for NestJS.

When unavailable, per stack:

**NestJS:** `grep -rn "@Get\|@Post\|@Put\|@Patch\|@Delete" --include="*.controller.ts"`
**Workers:** `grep -rn "request.method\|router\.\(get\|post\)" --include="*.ts"`
**FastAPI:** `grep -rn "@router\.\(get\|post\|put\|patch\|delete\)" --include="*.py"`
**Frontend:** `grep -rn "useQuery\|useMutation\|fetch(\|axios\." --include="*.ts" --include="*.tsx"`

Discovery must return ALL results. No truncation via `head -N`. If output exceeds 200 lines, save to `audits/artifacts/endpoints-raw.txt`.

**OpenAPI layer:** If an OpenAPI/Swagger spec exists, use it as primary inventory. Grep-based discovery becomes the fallback. Endpoints found by grep but missing from spec = undocumented (flag for D10).

**Completeness check:** Cross-check grep results against module imports/exports, Swagger spec if present, and test files hitting unlisted endpoints.

Output:
```
ENDPOINT INVENTORY
Stack: [detected]
Tier: [LIGHT/STANDARD/DEEP]
Total endpoints: [N]
Risk signals: [list or "none"]
Completeness: [high/medium]
```

---

## Phase 1: Dimension Analysis (D1-D11)

For EACH dimension, evaluate all endpoints in scope and assign a score.

| # | Dimension | Weight | Max | Critical Gate |
|---|-----------|--------|-----|---------------|
| D1 | Input Validation and Type Safety | 15% | 15 | D1=0 -> auto-fail |
| D2 | Payload Efficiency and Data Contracts | 15% | 15 | -- |
| D3 | Pagination and Unbounded Queries | 12% | 12 | D3<3 AND >10K rows -> auto-fail |
| D4 | Error Handling and Standardization | 12% | 12 | -- |
| D5 | Caching and HTTP Headers | 8% | 8 | -- |
| D6 | HTTP Semantics Correctness | 8% | 8 | -- |
| D7 | N+1 API Waterfall (Client-Side) | 5% | 5 | -- |
| D8 | Rate Limiting and Throttling | 5% | 5 | -- |
| D9 | Authentication and Authorization | 15% | 15 | D9<8 -> auto-fail |
| D10 | Documentation and Contracts (DEEP only) | 5% | 5 | -- |
| D11 | Contract Stability via oasdiff (conditional) | 5% | 5 | D11=0 -> auto-fail |

**D11 activation:** Only if OpenAPI spec exists. If no spec -> D11=N/A.

**N/A-aware scoring:** Dimensions not applicable to the tier or codebase context are excluded from both score sum and max denominator.

```
max = sum of weights for all non-N/A dimensions
score = sum of dimension scores
percentage = score / max x 100
```

**Evidence ratio scoring:** For each dimension, compute `violating_endpoints / eligible_endpoints`:

| Ratio | Interpretation | Score impact |
|-------|---------------|-------------|
| 0% | No violations | Full score |
| 1-20% | Isolated gaps | -1 to -3 |
| 21-50% | Systemic issue | -4 to -8 |
| 51-80% | Pervasive failure | -8 to -12 |
| >80% | Absent practice | Score 0-2 |

Always report ratio alongside score: `D1: 11/15 (3/18 endpoints lack validation = 17%)`.

**Health grades:**
- >= 80%: HEALTHY
- 60-79%: NEEDS ATTENTION
- 40-59%: AT RISK
- < 40%: CRITICAL

**Critical gate:** D9<8 (auth gaps on mutations), D1=0 (no validation), D3<3 with >10K records, D11=0 (critical breaking change) -> auto-fail regardless of total.

### Execution

Split endpoints into batches by controller/module. Each batch covers one controller and all its endpoints.

**Parallel** (Claude Code with Task tool): spawn one agent per batch, max 6 concurrent.
**Sequential** (Cursor, Codex, no Task tool): evaluate one batch at a time inline.

---

## Phase 2: GET-Only Probing (STANDARD+ tier)

**Skip if:** `--static` flag set, or LIGHT tier, or no running server.

### Prerequisites (HARD GATE)

All variables must be confirmed before any HTTP request:

| Variable | Source | Required |
|----------|--------|----------|
| `BASE_URL` | User confirms environment | YES -- no default |
| `TOKEN` | User provides auth token | YES -- never auto-extract from code |
| `TIMEOUT` | curl `--max-time` | NO (default 15) |
| `MAX_RPS` | Rate limit for probing | NO (default 2) |

**Environment gate:**
1. User confirms target (localhost/staging/sandbox)
2. Production domains -> REFUSE
3. Auth token from user (never auto-extract from code)

### Probing Protocol

For each list endpoint:

```bash
CURL_OPTS="--connect-timeout 5 --max-time 15 --retry 2 --retry-delay 1 --fail-with-body"

curl -s -w "\n%{size_download} %{http_code} %{time_total}" $CURL_OPTS \
  -H "Authorization: Bearer $TOKEN" "$BASE_URL$ENDPOINT?limit=10"

curl -s -I $CURL_OPTS -H "Authorization: Bearer $TOKEN" "$BASE_URL$ENDPOINT" | \
  grep -i "cache-control\|etag\|vary\|x-ratelimit\|content-type"
```

**Rate limiting:** Max 5 req/s. 3 consecutive 429s -> pause 30s, resume at 2 RPS. 3 consecutive 5xx -> STOP, report "target unhealthy".

Scrub ALL responses before recording (Gate 2).

---

## Phase 3: Cross-Cutting Analysis (STANDARD+ tier)

### 3.1 Contract Consistency
- Same entity from different endpoints -- identical shape?
- Frontend expects field X, backend returns field Y?
- Pagination format consistent across list endpoints?
- Error shape consistent across stacks?

### 3.2 Money Field Audit
- List ALL fields with money values across all endpoints
- Same representation everywhere (number OR integer-cents, never both)?
- Currency always travels with amount (never implicit)?

### 3.3 Auth Matrix

Build endpoint x role matrix:

```
| Endpoint | Public | User | Admin | Manager | Evidence |
```

### 3.4 Payload Size Analysis (if probing done)
- Flag endpoints returning >100KB for list views
- Flag nested relations >3 levels deep
- Flag dual fields in responses (`*_id` + `*_name` for same entity)

---

## Phase 4: Report

Save to: `audits/api-audit-[date].md`

```markdown
# API and Endpoint Integrity Audit

## Metadata
| Field | Value |
|-------|-------|
| Project | {name} |
| Date | {date} |
| Tier | {LIGHT/STANDARD/DEEP} |
| Stacks | {detected} |
| Total Endpoints | {N} |
| Probing | {Static only / Static + GET on {env}} |

## Score Summary

| Dimension | Score | Max |
|-----------|-------|-----|
| D1. Input Validation | {X} | 15 |
| D2. Payload Efficiency | {X} | 15 |
| D3. Pagination | {X} | 12 |
| D4. Error Standardization | {X} | 12 |
| D5. Caching | {X} | 8 |
| D6. HTTP Semantics | {X} | 8 |
| D7. API Waterfall | {X} | 5 |
| D8. Rate Limiting | {X} | 5 |
| D9. Auth | {X} | 15 |
| D10. Documentation | {X} | 5 |
| D11. Contract Stability | {X or N/A} | 5 |
| **TOTAL** | **{X}** | **{max}** | **{grade} ({%})** |

## Critical Findings
## All Findings (by dimension)
## Cross-Cutting Analysis
## Recommendations (top 5 by effort + impact)
## CQ Overlap
```

### Issue Format

```
### API-{N}: {Title}
Dimension: D{X} -- {name}
Severity: CRITICAL / HIGH / MEDIUM / LOW
Confidence: {X}/100
Endpoint: {METHOD} {path}
Stack: {NestJS/Worker/FastAPI/Frontend}
File: {path} -> {handler}()
Evidence: {code quote or response excerpt, max 15 lines, SCRUBBED}
Problem: {specific}
Impact: {user/security/performance}
Fix: {complete code for MEDIUM+}
CQ Overlap: {CQ IDs or "none -- cross-endpoint only"}
```

## Phase 5: Backlog Persistence

**Default: off.** Activate with `--persist-backlog` flag or explicit user request.

When active, persist findings (confidence 26+) to `memory/backlog.md`:

1. Read `memory/backlog.md`. If missing, create with template.
2. Fingerprint: `file|dimension|endpoint-signature`. Dedup: existing = increment `Seen`.
3. Delete resolved items. Confidence 0-25 = DISCARD.

Full protocol: `{plugin_root}/shared/includes/backlog-protocol.md`.

## Phase 6: Next-Action Routing

| Condition | Suggested Action |
|-----------|-----------------|
| D1=0 (no validation) | `zuvo:code-audit [controllers]` -- audit CQ3/CQ19 |
| D9<8 (auth gaps) | `zuvo:code-audit [controllers]` -- audit CQ4/CQ5 |
| D3<3 AND >10K rows | `zuvo:refactor [services]` -- add pagination |
| D10<3 (undocumented) | `zuvo:docs api [path]` -- generate API reference |
| D1+D9 both critical | Fix D9 first -- security before correctness |
| D11=0 (breaking change) | Fix breaking changes before release |
| All dimensions >= 8 | No action needed. Schedule next audit in 30 days. |

---

## Execution Notes

- Use **Sonnet** for LIGHT/STANDARD tiers
- Use **Opus** for DEEP tier
- Process controllers sequentially. Claude Code may parallelize with up to 6 Task agents.
- Read the project's AGENTS.md or CLAUDE.md first for stack-specific conventions
- Estimated durations: LIGHT ~3-5 min, STANDARD ~8-10 min, DEEP ~15-20 min
