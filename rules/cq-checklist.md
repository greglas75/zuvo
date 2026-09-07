# Code Quality Self-Evaluation

Run after writing production code, before writing tests. Companion patterns are in `cq-patterns.md`.

---

## 40 Evaluation Gates

Each gate is scored 1 (pass with evidence), 0 (fail or unproven), or N/A (feature precondition verified inactive, with evidence).

<!-- GATES:BEGIN kind=cq-table -->
| Gate | Domain | Check |
|------|--------|-------|
| CQ1 | Types | Unions, enums, or branded types used where plain `string`/`number` is too loose? No `==`/`!=` loose equality (JS/TS — in Python/Go `==` is the normal operator)? |
| CQ2 | Types | Explicit return types on all public functions? No implicit `any` anywhere? No `as unknown as X` casts? No `!` non-null assertions without justification? |
| CQ3 | Validation | **CRITICAL** — Input validated at every boundary? (a) required fields enforced, (b) format/range/allowlist applied, (c) runtime schema at entry point? |
| CQ4 | Security | **CRITICAL** — Auth guards paired with query-level tenant scoping? Guard alone is insufficient — `organizationId` must appear in service WHERE clauses. If any public method requires orgId, all must (or document exemptions). **For public/unauthenticated routes accepting opaque tokens, the security gate is server-side: (a) the SERVER MUST canonically validate token format and existence before any side effect, (b) the server MUST collapse "expired" / "invalid" / "not found" / "revoked" into a single opaque error (no enumeration leak), (c) rate-limit token-lookup endpoints. Optional UX: client may pre-validate format (UUID/ULID/regex) to skip a round-trip on obvious typos — this is NOT a security control and does not satisfy CQ4 on its own.** |
| CQ5 | Security | **CRITICAL** — Zero sensitive data in logs (ALL log outputs including structured logger), errors, response bodies (including stack traces gated by NODE_ENV), headers, or query params? No raw `dangerouslySetInnerHTML`? (Header like `x-modified-by: user@email.com` = violation; `stack: err.stack` in non-dev response = violation; `logger.info('User login', { email })` = violation.) |
| CQ6 | Resources | **CRITICAL** — No unbounded memory growth from external data? Pagination, streaming, or batching used? |
| CQ7 | Resources | All database queries bounded (LIMIT / cursor)? List responses return slim payloads (`select` fields)? |
| CQ8 | Errors | **CRITICAL** — Infrastructure failures handled? No empty `catch {}`. Timeouts on outbound calls. `response.ok` checked before `.json()`. `return await` inside try/catch. No infra details leaked. Frontend: `AbortSignal.timeout()` on every fetch. Node.js `execFile`/`exec` with callback: use `promisify(execFile)` or wrap in try/catch (sync throw before spawn = callback never fires = hang). |
| CQ9 | Data | Multi-table mutations wrapped in transactions? FK order respected during delete/create sequences? |
| CQ10 | Data | Nullable values guarded before access? No unsafe `.find()` without null check? No unvalidated `as Type` / `!` non-null assertion? |
| CQ11 | Structure | **File** within its type limit (service 300-450L, controller 300L, component 200L single-responsibility / 300L page-container, hook 250L, util 100L)? **Functions** within limits (public 50L, private 30L, handler 25L, $tx 60L, useEffect 20L)? No deeper than 4 nesting levels? 5 params max? **Inline sub-components or helper closures ≥50 LOC inside a parent component file = violation regardless of total file size — extract to sibling.** **Hard gate: file exceeding 2x the type limit = automatic CQ11 FAIL.** |
| CQ12 | Structure | No magic strings or numbers? No index-based mapping (`row[0]`)? Named constants in use? |
| CQ13 | Hygiene | No dead code (unreachable branches, unused exports)? No TODO without a ticket reference? No stale feature flags (>30 days since full rollout = stale)? No mixed `console.*` and structured logger in same file? **Note: commented-out old implementations and debug leftovers are dead code. Explanatory comments, API examples, and documented workarounds are NOT.** |
| CQ14 | Hygiene | **CRITICAL** — No duplicated logic? (a) block exceeding 10 lines repeated, OR (b) same structural pattern appearing 5+ times, OR (c) **block ≥3 lines repeated 4+ times across files when duplicates target the same module/action (high-fan-out: URL builders, mock factories, query-string helpers), OR (d) `vi.mock`/`jest.mock` for the same module duplicated 10+ times across the test suite — extract to `test-utils/`**? |
| CQ15 | Async | Every async call awaited or explicitly fire-and-forget with `.catch()`? `return await` used inside try/catch? No `await` inside `Promise.all()` argument list? |
| CQ16 | Data | **CONDITIONAL** — Monetary values use exact arithmetic (integer-cents, Decimal.js)? No `toFixed()` during computation? **Scope: actual currency amounts only.** Indices, ratios, scores = N/A. |
| CQ17 | Performance | No sequential `await` in loops where batch or `Promise.all` suffices? No N+1 queries? No `.find()` inside a loop? |
| CQ18 | Data | Multi-store/cross-system writes use a NAMED consistency mechanism — outbox, saga/compensation, two-phase commit, or a documented reconciliation job? The partial-failure path exists and is exercised by a test? A dual-write with no mechanism and no reconciliation = violation. |
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
| CQ30 | Security | **CONDITIONAL** — CSRF defence present on state-changing endpoints? `SameSite=Lax\|Strict` on the session cookie AND one of: an anti-CSRF token, framework server-side origin verification (`Origin`/`Sec-Fetch-Site` checks — Astro `checkOrigin`, SvelteKit/Next server-action origin checks), or a non-cookie bearer transport? A cookie-authenticated mutation with none of these = violation. |
| CQ31 | Security | **CONDITIONAL** — User input never reaches a dangerous sink unvalidated? (a) filesystem paths resolved + containment-checked (never `normalize`+`startsWith`), (b) subprocess arguments passed as an argv array, never an interpolated shell string, (c) no `pickle`/`yaml.load`/`unserialize` on non-first-party bytes, (d) outbound URLs allowlisted (SSRF, incl. IPv6 and redirect re-validation). Covers CWE-22/77/78/502/918 — none previously gated. |
| CQ32 | Security | **CONDITIONAL** — Supply chain controlled? Lockfile committed, no floating ranges or `latest` on a newly added dependency, and new dependencies checked against an advisory source. |
| CQ33 | Security | **CONDITIONAL** — Cryptographic material handled correctly? Tokens/IDs/nonces from a CSPRNG (`crypto.randomUUID`/`randomBytes`/`secrets`), never `Math.random()`/`Date.now()`; credential hashing via argon2id or bcrypt (cost >= 12), never a bare SHA-*; no bespoke crypto; secrets read from config, never literals in source or a client bundle. |
| CQ34 | Security | **CONDITIONAL** — Authorization complete at BOTH levels? (a) function-level: the handler asserts the caller's role/permission for THIS operation, not just that the caller is authenticated (BFLA); (b) field-level: write payloads are field-allowlisted, never a blanket spread into the ORM (mass assignment / BOPLA). CQ4 covers object/tenant scoping only. |
| CQ35 | Concurrency | **CONDITIONAL** — Cancellation propagated, not merely applied? The ambient cancellation handle (`AbortSignal` / `context.Context` / `CancellationToken` / `CoroutineScope`) is ACCEPTED as a parameter and forwarded to every downstream call — never re-created MID-CHAIN (`context.Background()` or a fresh `AbortController` deep inside a call that was handed one) and never stored in a struct/field. Creating one at an ENTRY POINT — `main`, a request handler, a CLI command, a top-level job — is correct and expected; the violation is a function that RECEIVES a handle and ignores it. Every derived handle is released (`defer cancel()`). A timeout no caller can cancel is not cancellation. |
| CQ36 | Concurrency | **CONDITIONAL** — Every spawned unit of work has a named owner that joins it, aborts it, or documents it as process-lifetime? No `go func()` / `tokio::spawn` / `Task.Run` / `GlobalScope.launch` / `asyncio.create_task` whose handle is dropped (Python: `TaskGroup`, or a module-level set + `add_done_callback`). Fan-out is bounded (`errgroup.SetLimit`, `JoinSet`, `Semaphore`), never an unbounded loop-spawn. (TS/JS: dropped async work is CQ15.) *(stack: go,rust,jvm,dotnet,python — `out-of-scope` on any other stack)* |
| CQ37 | Concurrency | **CONDITIONAL** — Shared mutable state race-free BY CONSTRUCTION (owned by one task, or behind a lock/atomic) AND proven by tooling — `go test -race`, TSan, `-ea` + `@GuardedBy`? Python: `x += 1` on a module global is NOT atomic and free-threaded 3.13+ removes the incidental GIL protection — guard with `threading.Lock`. No lock or guard copied by value (`go vet copylocks`), no `unsafe impl Send/Sync` without a written argument, no lock held across an `await`/`.await`/blocking call. A review opinion is not proof; the race detector is. *(stack: go,rust,jvm,dotnet,python — `out-of-scope` on any other stack)* |
| CQ38 | Resources | **CONDITIONAL** — Deterministic release on EVERY exit path — `defer x.Close()` placed after the error check, try-with-resources, `using`/`await using`, `with`/`async with`, or an RAII guard? HTTP bodies, rows, statements and files enumerated. No `defer` inside an unbounded loop. Cleanup only on the happy path = violation. (TS/JS listener + timer cleanup is CQ22.) *(stack: go,rust,jvm,dotnet,python — `out-of-scope` on any other stack)* |
| CQ39 | Resources | **CONDITIONAL** — Every queue, channel and fan-out bounded? An unbounded producer is CQ6 (unbounded memory) wearing a different hat: bounded channels, `SetLimit`, a semaphore, `BoundedChannelOptions`, or explicit backpressure (`writable.write()` return value honoured, `drain` awaited). Unbounded + a fast producer = OOM under load, not under test. |
| CQ40 | Hygiene | **CONDITIONAL** — The language's meta-linter is configured, pinned, and clean in CI — `golangci-lint` (errcheck/govet/staticcheck/gosec/bodyclose/contextcheck), `clippy -D warnings` + cargo-deny, typescript-eslint type-checked (or Biome/oxlint type-aware), ruff + mypy, ErrorProne + NullAway, `TreatWarningsAsErrors`. **No config present = 0** — that is the point of the gate, so its trigger is the LANGUAGE having a linter, not the project already having configured one (a trigger keyed on "has a config" would make the failure case unreachable). Scored on the config + the CI invocation; a local run with no CI may score on the config alone and note `ci: not-verified`. |
<!-- GATES:END kind=cq-table -->

---

## Scoring

**Critical gates:** CQ3, CQ4, CQ5, CQ6, CQ8, CQ14 — critical whenever their feature precondition is active; any active gate scored 0 triggers an immediate FAIL. Applicability is assessed before criticality. An inactive feature may be N/A only with the evidence below; criticality never excuses an active failure.

**Conditional critical gates** (active only when the code context applies):
- **CQ16** — critical when code manipulates prices, costs, discounts, invoices, payouts
- **CQ19** — critical when code crosses an API or module boundary. Exception: thin controllers that only return typed service data — CQ19=0 is a normal deduction (caps at B), not a critical failure.
- **CQ20** — critical when payload contains `*_id` + `*_name` pairs or number + string-with-currency for the same field
- **CQ21** — critical when concurrent mutations target the same resource. Not critical for read-only paths.
- **CQ22** — critical when code creates subscriptions, timers, or observers. Not critical for stateless handlers.
- **CQ23** — critical when code uses Redis, Memcached, or in-memory caching. Not critical for code without caching.
- **CQ24** — critical when code modifies existing API endpoint signatures (request/response shapes, route paths). Not critical for new endpoints.
- **CQ28** — critical when code defines timeouts at 2+ architectural layers (client, server, DB).
- **CQ30-CQ40** — each carries its own trigger; read them from the `Criticality` column of
  `../shared/includes/gate-registry.md` (the canonical source) rather than from a copy here.
  This list stopped at CQ28 while eleven further conditional-critical gates landed, so anything
  reading only this file treated CQ30-CQ40 failures as ordinary deductions. Re-derive, don't extend:
  `grep -E '^\| CQ(3[0-9]|40) ' shared/includes/gate-registry.md`.

**Non-critical gates:** CQ25, CQ26, CQ27, CQ29 — scored normally. Failure is a deduction, not an auto-FAIL.

When a conditional gate is active and scored 0: FAIL.

**Thresholds (single canonical formula — use this, not approximations elsewhere):**

```
denominator = (gates in scope) - count(N/A)            # N/A gates excluded from both numerator and denominator
pass_count  = count(score == 1)          # 1s only; N/A does NOT count as a pass

PASS              iff pass_count / denominator >= 0.86  AND  every active critical gate = 1
CONDITIONAL PASS  iff pass_count / denominator >= 0.79  AND  every active critical gate = 1
FAIL              iff any active critical gate = 0  OR  pass_count / denominator < 0.79
```

Reference table at zero N/A, zero out-of-scope (denominator = 40): PASS ≥ 35, CONDITIONAL PASS = 32-34, FAIL < 32.
On a pure-TS repo the three stack-scoped gates (CQ36-CQ38) are out-of-scope → denominator 37: PASS ≥ 32, CONDITIONAL 30-31, FAIL < 30.
At higher N/A counts the absolute pass count drops proportionally — always recompute against
the actual `denominator`. Active critical gates can never be N/A; they are either 1 or 0. A zero denominator is `INCOMPLETE` (no evaluated gates), never 100%.

**Three states, not two — `out-of-scope` is not `N/A`.**
A gate whose STACK does not match the project (a Go gate on a TypeScript repo) is `out-of-scope`:
excluded from the denominator AND from the applicability review count, because stack mismatch is mechanical
(`go.mod` is absent), not a judgement an auditor makes. `N/A` stays reserved for "this gate applies
to my stack, but its precondition does not hold in this file" — a judgement, and therefore
reviewed. Print `out-of-scope: N gates (stack=<detected>)` as one summary line; do not list them
individually. See `../shared/includes/gate-registry.md` for each gate's `Scope`.

```
in_scope    = 40 - count(out-of-scope)
denominator = in_scope - count(N/A)
```

**Evidence decides applicability; the count triggers review.**
Re-labelling failures as N/A can inflate a score without changing code. Prevent that by auditing
preconditions before calculating scores, with the following requirements:

1. **Every N/A records the gate's feature precondition, why it is inactive, and source evidence.**
   Cite inspected file:symbol:line locations, relevant imports/callers and a scoped negative search
   with command and result. A token search alone cannot establish absence of aliased or delegated
   I/O. Missing evidence, an unknown precondition, or an unperformed check is **0 (unproven)**,
   never N/A. If a mandatory review/check has not completed, the overall run is `INCOMPLETE`.
2. **`count(N/A) > floor(in_scope / 3)` requires documented independent applicability review.**
   The existing independent CQ auditor rechecks each inactive precondition against source and
   relevant callers, and records accepted/rejected gate IDs with evidence. Until that check
   completes, verdict is `INCOMPLETE`. Once verified, a high count alone does not prohibit PASS:
   a pure parser may legitimately have no DB, network, cache, auth, timers, or concurrency.
   The reviewer must be distinct from the original scoring author; record both agent/provider
   identities/models and the review artifact/run. Follow the resolved execution policy for
   independence; a fresh context with the same model is not independent. An auditor cannot
   certify its own N/A assignments.
   Reuse the already-required independent review to compare its source-derived applicability
   set with the original assessment. Newly proposed exclusions require distinct review too;
   without it they remain unverified and the high-N/A verdict stays INCOMPLETE.
   Use the existing reviewer, not a new provider loop solely because the count is high.
3. **Code type is a review focus, not proof that a feature exists.** A SERVICE with no cache can
   mark CQ23 N/A after verifying the absence; a PURE module that calls a DB must score CQ8.
   A missing required protection does not make its precondition inactive: user-scoped queries
   activate CQ4 even without auth code, and a supported language activates CQ40 without lint config.
   All active critical gates remain mandatory; a failed one cannot be relabelled N/A.
4. **Print `pass_count`, `count(N/A)`, `in_scope`, denominator, and applicability review status.**
   Exclude N/A from both numerator and denominator; keep 0/unproven in the denominator. The
   independent review records the final applicability set before the percentage is computed.
   Report any changed classification with the source evidence that changed the decision.

**Honest limit:** these are evidence requirements, not mechanical proof of source semantics.
Independent review must inspect the cited code; a fabricated or irrelevant citation does not
satisfy the requirement. A completed review can still leave a gate 0/unproven.

---

## Evidence Standards

### Allowed Score Values

| Score | Meaning | Use when |
|-------|---------|----------|
| **1** | Proven compliant | You can cite file:function:line proving it |
| **0** | Failed or unproven | Code violates the gate, OR evidence is insufficient |
| **N/A** | Feature precondition verified inactive | Record precondition, reason, source and negative-search evidence |

Note the distinction: `CQ4=0 (violation)` means a WHERE clause is missing orgId. `CQ4=0 (unproven)` means the model is complex and you cannot confirm all paths. Both score 0 for gating, but the fix action differs.

### Citing Evidence

```
PREFERRED:  file:function:line    → order.service.ts:updateStatus:112
ACCEPTABLE: file:line-range       → order.service.ts:108-125
```

For every CQ scored 1, provide:
```
CQ[N]=1
  Scope: [what was audited — e.g., "7 Prisma queries in order.service.ts"]
  Evidence: [file]:[function]:[line] — [what satisfies the gate]
  Exceptions: [deliberate exclusions with rationale, or "none"]
```

A claim without file:line evidence must be scored 0.

### Classifying Sensitive Data (CQ5)

- **Direct PII** (never in logs/errors/responses): email, phone, IP, name, address, DOB, government ID, payment card, password/token
- **Sensitive identifiers** (mask when possible): tenant slug, session token, API key, webhook secret, payment provider ID
- **Safe operational data** (acceptable in private backend logs): internal UUID (orgId, orderId), enum status, counts, timestamps, error codes

What is safe in backend logs may still be unsafe in HTTP responses, client-visible logs, or support exports. Audit each output channel: throws (appear in HTTP responses), logger calls (backend logs), return values (client payloads).

### Negative Evidence

Scoring 0 based on absence is valid when: (1) the project's logging API is identified first, (2) an exhaustive search is documented (`rg "try|catch|logger" file.ts → 0 matches`), (3) the correct baseline is used (if the project uses `this.logger.*`, absence of `console.log` is irrelevant).

### What Strong Evidence Looks Like

- **CQ3=1:** "schema: CreateOfferDto (dto:12), z.string().uuid() on id, z.enum() on status, ValidationPipe global"
- **CQ4=1:** "guard: tenantProcedure (trpc.init.ts:34) + WHERE { organizationId } on ALL 7 queries (listed)"
- **CQ5=1:** "enumerated: 4 throws (no PII), 3 logger calls (orgId=UUID safe), no dangerouslySetInnerHTML"
- **CQ6=1:** "all 5 findMany bounded: findAll take=200, export AsyncGenerator BATCH=1000, bulk cap=1000"
- **CQ8=1:** "try/catch on redis (fallback to DB), timeout 10s on payment, .catch on email, response.ok checked"
- **CQ14=1:** "compared all method pairs >20L (create vs batch: different), counted patterns <5 occurrences"
- **CQ9=1:** "IN tx: order.create + orderItem.createMany + audit. OUTSIDE: email .catch()"
- **CQ21=1:** "CAS: updateMany WHERE { id, status: current }, count===0 → ConflictException"

Vague claims like "no duplication" or "errors handled" score 0.

### Evidence Format Principles

1. **File:function:line** — every claim points to specific code
2. **What, not whether** — show `where: { id, organizationId }`, not "query is scoped"
3. **All paths, not one** — 7 queries means confirm all 7
4. **Inside AND outside** — for transactions, enumerate both
5. **Count your claims** — CQ4=1 with 7 queries means list each one
6. **Vague = 0** — no file:line means score is 0
7. **State audit method** — `rg "prisma\." file.ts → 7 matches`

### Before Submitting CQ=1

Can I point to file:function:line? Did I check ALL instances, not just one? Am I scoring what I actually wrote, or what I intended to write? Does every N/A have inactive-precondition evidence, and has the required independent applicability review completed when the count exceeds `floor(in_scope / 3)`?

---

## N/A Guidelines

N/A scores are excluded from both numerator and denominator (see canonical formula at the top of this file). Each N/A requires per-gate justification. Excessive N/A usage flags the audit as low-signal.

| CQ | N/A is valid when | N/A is NOT valid |
|----|-------------------|------------------|
| CQ3 | Pure internal helper with no external input | "It's simple" — if it accepts user input, it applies |
| CQ4 | Pure utility with zero auth. Internal services consumed only by authenticated callers IF: (a) JSDoc documents "Internal — caller must verify session ownership", (b) target entity lacks organizationId column (check schema). Without documentation → CQ4=0. | "Internal service" — if it touches user-scoped data, it applies |
| CQ5 | Pure computation, zero I/O, zero logging | "We don't log PII" — if it has logger/throws, it applies |
| CQ6 / CQ7 | CQ6: no externally sized collections or growing retained state (trace input provenance). CQ7: no database queries, including delegated queries | "Pure function" does not exempt external lists from CQ6; "small dataset" does not bound queries for CQ7 |
| CQ8 | Pure synchronous code, zero I/O | "Errors are rare" — any external call means it applies |
| CQ9 | Read-only or single-table mutations | "Don't use transactions" — multi-table writes need transactions |
| CQ15 | No async code present | "Simple async" — if async exists, it applies |
| CQ16 | No monetary calculations. Stats/ratios = N/A. | "Display field" — if the value enters arithmetic, it applies |
| CQ17 | No repeated queries, sequential async loops, or nested collection lookups | "Synchronous" — `.find()` inside a loop still applies |
| CQ18 | Single data store | "Cache is just cache" — if inconsistency breaks UX, it applies |
| CQ19 | Internal code, caller already validated | "Types are enough" — TS types vanish at runtime |
| CQ20 | No domain entities | "Legacy" — not a valid excuse |
| CQ21 | Read-only, single-user, no contested resources | "Low traffic" — races happen at any traffic level |
| CQ22 | Pure sync, stateless, no subscriptions | "One listener" — 1 listener x 1000 mounts = 1000 listeners |

**Conditional and security-wave gates** (same rules — split into a second table only to stay under
the gate-consistency test's hand-maintained-definition-table heuristic; this is guidance per gate,
not a definition table):

| CQ | N/A is valid when | N/A is NOT valid |
|----|-------------------|------------------|
| CQ23 | No caching in this code path | "Small data" — if cache exists, TTL applies |
| CQ24 | New endpoint only, no existing clients | "Internal API" — if any client calls it, backward compat applies |
| CQ25 | No comparable project structure or naming pattern after repository search | "It's better this way" — consistency > preference |
| CQ26 | Pure computation, zero I/O, zero logging | "We log elsewhere" — if file has logger calls, it applies |
| CQ27 | No log statements in changed code | "It's just a warning" — if logger.error exists, check its usage |
| CQ28 | Single-layer timeout, no hierarchy to check | "Defaults are fine" — if multiple layers define timeouts, check order |
| CQ29 | Workspace has no path alias configured in tsconfig/jsconfig/vite.config | "Alias is ugly" — if a configured alias exists, files with `../../../` violate |
| CQ1/CQ2 | Practically never — every file has types and equality; score them | "It's markdown/config" — that's out-of-scope handling, not N/A |
| CQ30 | Endpoint is not cookie/session-authenticated, or read-only | "We use SameSite" — SameSite alone without token/bearer still scores, as 0 or 1 |
| CQ31 | No user-controlled value reaches path/shell/deserializer/outbound URL (cite the negative search) | "Input is trusted" — provenance, not trust, decides |
| CQ32 | Diff adds no dependency AND repo has no manifest | "Dependabot handles it" — the lockfile/pinning state still scores |
| CQ33 | No token/ID generation, hashing, encryption, or secret reads | "It's just an ID" — IDs from Math.random() are the violation |
| CQ34 | Handler has no role model AND writes no persistence payload | "Auth middleware covers it" — that's authentication, not per-operation authorization |
| CQ35 | No cancellable I/O or long-running work | "It's fast" — duration is not the trigger, cancellability is |
| CQ36-CQ38 | (stack-scoped — mark `out-of-scope` on non-matching stacks, never N/A) | Using N/A for a stack mismatch burns the budget wrongly |
| CQ39 | No queue/channel/buffer sized by external input | "The producer is slow today" — bound it anyway |
| CQ40 | Practically never — the trigger is the LANGUAGE having a linter | "We lint locally" — score the config + CI invocation |

**Abuse check:** exceeding `floor(in_scope / 3)` triggers the independent applicability review above. An unreviewed high-N/A audit is `INCOMPLETE` and excluded from passing aggregate metrics. A verified high count may pass only under the normal percentage and active-critical-gate rules.

> **Reminder:** apply the canonical formula at the top of this file. Do not re-derive thresholds — `denominator = (gates in scope) - count(N/A)`, `PASS ≥ 86%`, `CONDITIONAL ≥ 79%`.

---

## Fix-First Protocol

When a gate scores 0, fix it immediately if the fix takes under 5 minutes. Do not record a 0 and continue.

```
CQ=0 found →
  Can I fix this in <5 min?
    YES → fix NOW, re-score as 1
    NO  → critical gate?
      YES → fix NOW regardless of time
      NO  → score as 0, note "FIX NEEDED: [description]"
```

**Principle:** If writing the backlog entry takes longer than the fix itself, you chose wrong.

"Out of scope" applies only to: public API signature changes, DB migrations, new dependencies, external API contract changes. Adding a WHERE clause, null guard, or type annotation is never out of scope.

### Output Format

```
Code quality self-eval: CQ1=1 CQ2=1 CQ3=1 CQ4=1 CQ5=1 CQ6=1 CQ7=1 CQ8=0 CQ9=1 CQ10=1 CQ11=1 CQ12=0 CQ13=1 CQ14=1 CQ15=1 CQ16=1 CQ17=1 CQ18=1 CQ19=1 CQ20=1 CQ21=1 CQ22=1 CQ23=N/A CQ24=N/A CQ25=1 CQ26=1 CQ27=1 CQ28=N/A CQ29=1
  Score: 24/26 applicable (3 N/A excluded) → 92.3% — but FAIL due to critical gate CQ8=0
  Evidence: CQ3=schema(dto:12) CQ4=guard+filter(service:45) CQ8=FAIL CQ14=compared(service:all) CQ25=follows existing pattern CQ26=structured logger with requestId
  Fix: CQ8 — add try/catch at service.ts:88
```

---

## Reference Patterns

Concrete code patterns to verify specific gates during evaluation.

**CQ6 — Cursor-based bounded iteration:**
```typescript
let cursor: string | undefined;
while (true) {
  const batch = await prisma.session.findMany({
    where: { surveyId }, take: 1000,
    ...(cursor ? { cursor: { id: cursor }, skip: 1 } : {}),
    select: { id: true },
  });
  if (batch.length === 0) break;
  await processBatch(batch.map(s => s.id));
  cursor = batch[batch.length - 1].id;
}
```

**CQ9 + CQ17 — Atomic batch replace inside transaction:**
```typescript
await prisma.$transaction(async (tx) => {
  await tx.model.deleteMany({ where: { scopeId } });
  await tx.model.createMany({ data: items, skipDuplicates: true });
});
```

**CQ14 — Duplication detection procedure:**
1. List all methods exceeding 20 lines plus declarative structures. Check for blocks sharing 10+ structurally identical lines. Extract these.
2. Count identical try/catch blocks, error handlers, reducers. Five or more repetitions = CQ14 FAIL regardless of individual block size.
3. Beware the rationalization trap: "Each block is only 3 lines" — total duplicated lines are what matter.

**CQ18 — Multi-store synchronization:** Match operations (soft delete both or neither). Establish single source of truth plus derived views. Use transactions for SQL stores and async cleanup queues for external stores.

**CQ12 vs CQ20 distinction:** If deleting one field loses information → CQ20 (dual source of truth). If both are just inconsistent coding style → CQ12 (magic values).

**CQ21 — CAS state machine transition:**
```typescript
const { count } = await prisma.order.updateMany({
  where: { id, status: 'pending' },
  data: { status: 'shipped' },
});
if (count === 0) throw new ConflictException('Order already transitioned');
```

**CQ8 — External service timeout:**
```typescript
// AbortSignal.timeout: no dangling timer to clear (a bare Promise.race +
// setTimeout leaks the timer when charge() resolves first — the exact CQ22/CQ8
// class this pattern exists to prevent).
const result = await paymentProvider.charge(amount, {
  signal: AbortSignal.timeout(5000),
});
// Provider does not accept a signal? Wrap with a cleared timer — NOTE this only bounds the
// wait; the underlying charge keeps running (race does not cancel it). Prefer signal support.
// try { return await Promise.race([charge, timeout]) } finally { clearTimeout(h) }
```

---

## High-Risk Gates by Code Type

| Code Type | Focus CQs | Common Failures |
|-----------|-----------|-----------------|
| **SERVICE** | CQ1,3,4,8,14,16,17,18,20,21,23,26,27 | Status as string, no validation, guard without filter, unhandled DB errors, duplication, float money, N+1, multi-store sync, dual fields, TOCTOU, stale cache, unstructured logs, wrong log level |
| **CONTROLLER** | CQ3,4,5,12,13,19,24,25 | Missing DTO, auth bypass, PII in error, magic codes, dead endpoints, no response schema, breaking API change, inconsistent pattern |
| **REACT** | CQ6,10,11,13,15,22,25 | Unbounded list, null crash, oversized file, dead code, dropped promise, listener leak, inconsistent component pattern |
| **ORM/DB** | CQ6,7,9,10,17,20,23 | Unbounded findMany, no LIMIT, wrong delete order, null column, N+1, dual fields, stale cache |
| **ORCHESTRATOR** | CQ6,8,9,14,15,17,18,21,28 | All IDs in memory, no error handling, no tx, duplication, dropped promises, N+1, sync, TOCTOU, inverted timeouts |
| **HOOK** | CQ6,8,10,11,15,22 | Unbounded spread, no AbortController, nullable fields, oversized body, dropped promise, no cleanup |
| **PURE** | CQ1,2,10,12,16 | Stringly-typed, no return type, null edge case, magic numbers, float money |

### Pure Computation Services

These still require auditing even though many gates are N/A.

| CQ | What to check | Typical miss |
|----|---------------|-------------|
| CQ2 | All public methods have explicit return types? | Complex object literal with no interface |
| CQ3 | Public methods callable from boundary have runtime validation? | Claiming N/A as "pure internal" but method is public |
| CQ10 | `as Type` casts followed by null guards? `.find()` results checked? | Claiming pass because "no DB" but casts on unknown have no guard |
| CQ11 | Methods within limits (30L private, 50L public)? | Claiming pass without counting |
| CQ16 | Financial arithmetic integer-safe? `toFixed()` only for display? | "Uses round()" — `round(float*float)` is still float |
