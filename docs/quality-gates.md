# Quality Gates

Zuvo enforces two quality gate systems: **CQ1-CQ29** for production code and **Q1-Q19** for test code. Every skill that writes or reviews code runs these evaluations with evidence requirements. Scores determine whether work can proceed.

---

## CQ1-CQ29: Code Quality Gates

Each gate is scored **1** (pass with evidence), **0** (fail or unproven), or **N/A** (precondition not active, requires justification).

<!-- GATES:BEGIN kind=cq-table -->
| Gate | Domain | Check |
|------|--------|-------|
| CQ1 | Types | Unions, enums, or branded types used where plain `string`/`number` is too loose? No `==`/`!=` loose equality? |
| CQ2 | Types | Explicit return types on all public functions? No implicit `any` anywhere? No `as unknown as X` casts? No `!` non-null assertions without justification? |
| CQ3 | Validation | **CRITICAL** — Input validated at every boundary? (a) required fields enforced, (b) format/range/allowlist applied, (c) runtime schema at entry point? |
| CQ4 | Security | **CRITICAL** — Auth guards paired with query-level tenant scoping? Guard alone is insufficient — `organizationId` must appear in service WHERE clauses. If any public method requires orgId, all must (or document exemptions). **For public/unauthenticated routes accepting opaque tokens, the security gate is server-side: (a) the SERVER MUST canonically validate token format and existence before any side effect, (b) the server MUST collapse "expired" / "invalid" / "not found" / "revoked" into a single opaque error (no enumeration leak), (c) rate-limit token-lookup endpoints. Optional UX: client may pre-validate format (UUID/ULID/regex) to skip a round-trip on obvious typos — this is NOT a security control and does not satisfy CQ4 on its own.** |
| CQ5 | Security | **CRITICAL** — Zero sensitive data in logs (ALL log outputs including structured logger), errors, response bodies (including stack traces gated by NODE_ENV), headers, or query params? No raw `dangerouslySetInnerHTML`? (Header like `x-modified-by: user@email.com` = violation; `stack: err.stack` in non-dev response = violation; `logger.info('User login', { email })` = violation.) |
| CQ6 | Resources | **CRITICAL** — No unbounded memory growth from external data? Pagination, streaming, or batching used? |
| CQ7 | Resources | All database queries bounded (LIMIT / cursor)? List responses return slim payloads (`select` fields)? |
| CQ8 | Errors | **CRITICAL** — Infrastructure failures handled? No empty `catch {}`. Timeouts on outbound calls. `response.ok` checked before `.json()`. `return await` inside try/catch. No infra details leaked. Frontend: `AbortSignal.timeout()` on every fetch. Node.js `execFile`/`exec` with callback: use `promisify(execFile)` or wrap in try/catch (sync throw before spawn = callback never fires = hang). |
| CQ9 | Data | Multi-table mutations wrapped in transactions? FK order respected during delete/create sequences? |
| CQ10 | Data | Nullable values guarded before access? No unsafe `.find()` without null check? No unvalidated `as Type` / `!` non-null assertion? |
| CQ11 | Structure | **File** within its type limit (service 300-450L, component 200-300L, hook 250L, util 100L)? **Functions** within limits (public 50L, private 30L, handler 25L, $tx 60L, useEffect 20L)? No deeper than 4 nesting levels? 5 params max? **Inline sub-components or helper closures ≥50 LOC inside a parent component file = violation regardless of total file size — extract to sibling.** **Hard gate: file exceeding 2x the type limit = automatic CQ11 FAIL.** |
| CQ12 | Structure | No magic strings or numbers? No index-based mapping (`row[0]`)? Named constants in use? |
| CQ13 | Hygiene | No dead code (unreachable branches, unused exports)? No TODO without a ticket reference? No stale feature flags (>30 days since full rollout = stale)? No mixed `console.*` and structured logger in same file? **Note: commented-out old implementations and debug leftovers are dead code. Explanatory comments, API examples, and documented workarounds are NOT.** |
| CQ14 | Hygiene | **CRITICAL** — No duplicated logic? (a) block exceeding 10 lines repeated, OR (b) same structural pattern appearing 5+ times, OR (c) **block ≥3 lines repeated 4+ times across files when duplicates target the same module/action (high-fan-out: URL builders, mock factories, query-string helpers), OR (d) `vi.mock`/`jest.mock` for the same module duplicated 10+ times across the test suite — extract to `test-utils/`**? |
| CQ15 | Async | Every async call awaited or explicitly fire-and-forget with `.catch()`? `return await` used inside try/catch? No `await` inside `Promise.all()` argument list? |
| CQ16 | Data | **CONDITIONAL** — Monetary values use exact arithmetic (integer-cents, Decimal.js)? No `toFixed()` during computation? **Scope: actual currency amounts only.** Indices, ratios, scores = N/A. |
| CQ17 | Performance | No sequential `await` in loops where batch or `Promise.all` suffices? No N+1 queries? No `.find()` inside a loop? |
| CQ18 | Data | Cross-system consistency maintained? Multi-store operations handle partial failures? |
| CQ19 | Contract | **CONDITIONAL** — API request AND response shapes validated by runtime schema? No hope-based typing? **Identity validators (`(v: unknown) => v`, bare `as T` after `await res.json()`, untyped `assertRecord`) do NOT satisfy CQ19 — they pass nothing through. Acceptable: Zod / Yup / Valibot parse, hand-written `assertObjectShape({...})` with at least one field check, typed tRPC client (note `// validated by tRPC schema` once per file).** |
| CQ20 | Contract | **CONDITIONAL** — Single canonical source per data point? No dual fields stored independently for the same concept? |
| CQ21 | Concurrency | **CONDITIONAL** — No time-of-check-to-time-of-use races? Mutations idempotent or CAS-protected? Mutating API endpoints safe to retry (idempotency key or CAS guard)? No shared mutable state? |
| CQ22 | Resources | **CONDITIONAL** — All listeners, timers, and observers cleaned up on unmount/destroy? No stale closures in callbacks? |
| CQ23 | Resources | **CONDITIONAL** — Cache entries have TTL or explicit invalidation? No stale-forever entries? Redis `SET` without `EX`/`PX` = violation. In-memory cache without eviction policy = violation. |
| CQ24 | Contract | **CONDITIONAL** — API changes are additive only (new optional fields, new endpoints)? Removing or renaming fields has a deprecation path with migration guide? Breaking changes without versioning or deprecation = violation. |
| CQ25 | Structure | New endpoint/component/service follows existing project patterns? Same naming convention, same file structure, same error handling approach as existing code? "Special snowflake" = violation. |
| CQ26 | Observability | Log statements use structured logger with context (requestId, userId, traceId), not plain `console.log` strings? Every service/controller uses the project's standard logger. |
| CQ27 | Observability | Log levels used correctly? `logger.error` reserved for unrecoverable failures and infrastructure errors, not validation failures or expected business conditions. `logger.warn` for recoverable but unexpected situations. Validation failure logged as `error` = violation. Stack trace logged as `info` = violation. |
| CQ28 | Resilience | **CONDITIONAL** — DB timeout < server timeout < client timeout (deadline shrinks with depth, not inverted)? If code defines timeouts at multiple layers, verify the hierarchy is correct. Inverted timeout hierarchy = violation. |
| CQ29 | Structure | Workspace path alias used for imports ≥3 hops deep when the alias is configured? Aliases must come from the project's actual `tsconfig.compilerOptions.paths` / `jsconfig` / `vite.config.alias` — common patterns are `@/`, `#/`, `~/` but only count those declared in the workspace config. Files mixing `../../../` with a configured alias = violation. No alias configured = N/A. |
<!-- GATES:END kind=cq-table -->

### Critical gates -- static (always block)

**CQ3, CQ4, CQ5, CQ6, CQ8, CQ14**

Any of these scored 0 is an immediate FAIL, regardless of the total score.

### Critical gates -- conditional (block when context activates)

| Gate | Becomes critical when |
|------|----------------------|
| CQ16 | Code touches prices, costs, discounts, invoices, payouts |
| CQ19 | Code crosses an API or module boundary |
| CQ20 | Payload contains `*_id` + `*_name` pairs or number + currency-string |
| CQ21 | Concurrent mutations on the same resource |
| CQ22 | Code creates subscriptions, timers, or observers |
| CQ23 | Code uses Redis, Memcached, or in-memory caching |
| CQ24 | Code modifies existing API endpoint signatures |
| CQ28 | Code defines timeouts at 2+ architectural layers |

### CQ scoring thresholds

| Result | Criteria |
|--------|---------|
| **PASS** | Score >= 25/29 AND all active critical gates = 1 |
| **CONDITIONAL PASS** | Score 23-24/29 AND all active critical gates = 1 |
| **FAIL** | Any active critical gate = 0, OR total score < 23 |

---

## Q1-Q19: Test Quality Gates

<!-- GATES:BEGIN kind=q-table -->
| Gate | Check |
|------|-------|
| Q1 | Every test name describes expected behavior (not "should work")? |
| Q2 | Tests grouped in logical describe blocks? |
| Q3 | Every mock has `CalledWith` (positive) AND `not.toHaveBeenCalled` (negative)? |
| Q4 | Known-data assertions use exact values (`toEqual`/`toBe`, not `toBeTruthy`)? |
| Q5 | Mocks are typed (not `as any`/`as never`)? Note: `as unknown as ServiceType` is acceptable when no mock factory exists — it avoids `as any` while preserving the target type. Score Q5=1 for `as unknown as X`, Q5=0 only for `as any` or `as never`. |
| Q6 | Mock state is fresh per test (proper `beforeEach`, no shared mutable)? |
| Q7 | **CRITICAL** — Every error-throwing path tested with specific error type AND message? (not just "at least one") |
| Q8 | Null/undefined/empty inputs tested where applicable? |
| Q9 | Repeated setup (3+ tests) extracted to helper/factory? |
| Q10 | No magic values — test data is self-documenting? |
| Q11 | **CRITICAL** — All code branches exercised (if/else, switch, early return)? |
| Q12 | Symmetric: every "does X when Y" has "does NOT do X when not-Y"? **For each repeated pattern (auth guard, validation, error), verify every method has it.** |
| Q13 | **CRITICAL** — Tests import the actual production function (not a local copy)? |
| Q14 | Assertions verify behavior, not just that a mock was called? |
| Q15 | **CRITICAL** — Assertions verify content/values, not just counts or shape? |
| Q16 | Cross-cutting isolation: change to A verified not to affect B? |
| Q17 | **CRITICAL** — Assertions verify computed output, not input echo? Expected values from spec/manual calc, not copied from implementation (P-70). |
| Q18 | No flaky test signals? No `Date.now()` without fake timers, no `setTimeout` for timing, no `Math.random()` without seed, no reliance on execution order, no real network calls? |
| Q19 | Tests fully isolated? No shared mutable state between tests (global variables, module-level `let`, database rows without cleanup)? Each test can run independently in any order? |
<!-- GATES:END kind=q-table -->

### Critical gates (always block)

**Q7, Q11, Q13, Q15, Q17**

### Q scoring thresholds

| Result | Criteria |
|--------|---------|
| **PASS** | Score >= 16/19, all critical gates = 1 |
| **FIX** | Score 10-15/19, or any critical gate = 0 -- fix worst gaps, re-score |
| **REWRITE** | Score < 10 -- tests need fundamental rework |

---

## Evidence format

Every gate scored as 1 requires evidence. No evidence means the score is 0.

### CQ evidence

```
CQ[N]=1
  Scope: [what was checked -- e.g., "7 Prisma queries in order.service.ts"]
  Evidence: file:function:line -- [what satisfies the gate]
  Exceptions: [deliberate exclusions with rationale, or "none"]
```

Vague claims like "errors handled" are not evidence. Specific file paths, function names, and line numbers are required.

### Q evidence

```
Self-eval: Q1=1 Q2=1 Q3=0 Q4=1 Q5=1 Q6=1 Q7=1 Q8=0 Q9=1 Q10=1 Q11=1 Q12=0 Q13=1 Q14=1 Q15=1 Q16=1 Q17=1 Q18=1 Q19=1
  Score: 16/19 -> PASS | Critical gate: Q7=1 Q11=1 Q13=1 Q15=1 Q17=1 -> PASS
```

---

## N/A abuse prevention

If more than 9 of the 29 CQ gates (or 10+ of 19 Q gates) are scored N/A, the evaluation is flagged as **low-signal audit**. Every N/A requires a one-sentence justification explaining why the precondition is inactive. N/A counts as 1 for scoring but must be defensible.

This prevents agents from marking everything N/A to avoid doing the evaluation work.

---

## Fix-first rule

When a gate violation is found during evaluation:

1. **Can you fix it in under 5 minutes?** Fix it now, re-score as 1.
2. **Is it a critical gate?** Fix it now regardless of time.
3. **Otherwise:** Score as 0, note what needs fixing, persist to backlog if not fixed this session.

Adding a WHERE clause, null guard, try/catch, or type annotation is never "out of scope."

---

## Test anti-patterns (AP1-AP29)

Test audits check for 29 anti-patterns in addition to the Q1-Q19 gates. These are common structural problems that reduce test value:

| Range | Coverage |
|-------|----------|
| AP1-AP18 | Core anti-patterns: skip in new tests, mock-as-implementation, tautological tests, leaking state, .toBeDefined-only, etc. |
| AP25 | `expect(x.length).toBe(N)` instead of `.toHaveLength(N)` — worse error messages, masks missing property (Q4) |
| AP26 | Real timers in time-dependent tests without `useFakeTimers` — causes flaky tests |
| AP27 | `expect(x.length).toBeGreaterThan(0)` when exact fixture count is known — masks off-by-one and duplicates (Q4/Q15) |
| AP28 | Persistent `it.skip`/`describe.skip` without backlog tracking — dead code and coverage gaps |
| AP29 | Mock return value echoed in assertion — proves mock setup, not production logic (Q17). Most common audit failure. |

Full AP definitions with detection heuristics and fix guidance are in `rules/testing.md`.

---

## Where to find the full definitions

- **CQ details, scoring rules, evidence examples:** `rules/cq-checklist.md`
- **CQ code patterns (NEVER/ALWAYS pairs):** `rules/cq-patterns.md`
- **Q details, test patterns, scoring:** `rules/testing.md`
- **Test quality enforcement rules:** `rules/test-quality-rules.md`
- **Quick reference for agents:** `shared/includes/quality-gates.md`
