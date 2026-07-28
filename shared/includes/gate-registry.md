# Gate Registry — the single source of truth for CQ / Q / CAP / AP

> **This file defines every quality gate.** Other files do not re-state them — they carry
> GENERATED regions produced from this registry by `scripts/gen-gate-copies.py`.
> `tests/gates/test-gate-consistency.sh` fails the build when a region is stale.
>
> **To change a gate:** edit the row here, run `python3 scripts/gen-gate-copies.py --write`,
> commit both. Editing a generated region directly is overwritten on the next run and caught
> by the test.
>
> Why this exists: the definitions previously lived in 4-6 copies each and drifted — CQ14 lost
> three of its four clauses in the audit prompt, CQ28 was inverted in 7 places, `q-scoring-protocol`
> carried four gates' labels under the wrong IDs, and test-audit shipped Q1-Q17 while claiming
> Q1-Q19. Adding one gate meant ~30 edits across 27 files, which is why CQ29 shipped with six
> places still saying 28.
>
> **Self-containment is preserved:** the generator INLINES the text into each consuming skill, so
> a sub-agent still reads one file. This is a build-time source, not a runtime indirection.

## Scope vocabulary — the third scoring state

A gate has three possible outcomes, not two:

| State | Meaning | In denominator? | Counts toward the N/A cap? |
|-------|---------|-----------------|----------------------------|
| `1` / `0` | evaluated, with evidence | yes | — |
| `N/A` | the gate applies to this stack, but its precondition does not hold in this file (a judgement call) | no | **yes** |
| `out-of-scope` | the gate's STACK does not match the project at all (mechanical, not a judgement) | no | **no** |

Why the third state exists: adding stack-specific gates to a flat list breaks every existing
score. 25/29 is a PASS at 86%; the same file against 43 gates is 58%, a FAIL, with nothing about
the code changed. And forcing a TypeScript project to N/A ten Go gates would blow the N/A cap and
turn a clean audit into `INCOMPLETE`. Stack mismatch is not a judgement an auditor makes — it is
`go.mod` being absent — so it must not be spent from the N/A budget.

**Scope column values:** `universal` (any stack) or `stack:<a>,<b>` (only when that stack is
detected by the skill's stack-detection step). An `out-of-scope` gate is not printed in the score
line; print one summary line instead: `out-of-scope: N gates (stack=<detected>)`.

## Criticality vocabulary

- `critical` — always active; scored 0 ⇒ immediate FAIL, no tier absorbs it.
- `conditional:<trigger>` — critical **only** when the trigger holds; otherwise a normal gate.
  When the trigger holds and the gate scores 0 ⇒ FAIL.
- `—` — normal gate; contributes to the score, never blocks on its own.

## CQ1-CQ40 — Code Quality

| ID | Domain | Criticality | Scope | Gate (canonical) | Prompt short form |
|----|--------|-------------|-------|------------------|-------------------|
| CQ1 | Types | — | universal | Unions, enums, or branded types used where plain `string`/`number` is too loose? No `==`/`!=` loose equality? | No string/number where union/enum/branded type appropriate? |
| CQ2 | Types | — | universal | Explicit return types on all public functions? No implicit `any` anywhere? No `as unknown as X` casts? No `!` non-null assertions without justification? | All public function return types explicit? No implicit any? |
| CQ3 | Validation | critical | universal | Input validated at every boundary? (a) required fields enforced, (b) format/range/allowlist applied, (c) runtime schema at entry point? | Boundary validation complete? Required fields, format/range, runtime schema? |
| CQ4 | Security | critical | universal | Auth guards paired with query-level tenant scoping? Guard alone is insufficient — `organizationId` must appear in service WHERE clauses. If any public method requires orgId, all must (or document exemptions). **For public/unauthenticated routes accepting opaque tokens, the security gate is server-side: (a) the SERVER MUST canonically validate token format and existence before any side effect, (b) the server MUST collapse "expired" / "invalid" / "not found" / "revoked" into a single opaque error (no enumeration leak), (c) rate-limit token-lookup endpoints. Optional UX: client may pre-validate format (UUID/ULID/regex) to skip a round-trip on obvious typos — this is NOT a security control and does not satisfy CQ4 on its own.** | Guards reinforced by query-level filtering? Guard NOT sole defense? |
| CQ5 | Security | critical | universal | Zero sensitive data in logs (ALL log outputs including structured logger), errors, response bodies (including stack traces gated by NODE_ENV), headers, or query params? No raw `dangerouslySetInnerHTML`? (Header like `x-modified-by: user@email.com` = violation; `stack: err.stack` in non-dev response = violation; `logger.info('User login', { email })` = violation.) | No sensitive data in logs/errors/responses? |
| CQ6 | Resources | critical | universal | No unbounded memory growth from external data? Pagination, streaming, or batching used? | No unbounded memory from external data? Pagination/streaming? |
| CQ7 | Resources | — | universal | All database queries bounded (LIMIT / cursor)? List responses return slim payloads (`select` fields)? | DB queries bounded? LIMIT/cursor present? Slim payloads? |
| CQ8 | Errors | critical | universal | Infrastructure failures handled? No empty `catch {}`. Timeouts on outbound calls. `response.ok` checked before `.json()`. `return await` inside try/catch. No infra details leaked. Frontend: `AbortSignal.timeout()` on every fetch. Node.js `execFile`/`exec` with callback: use `promisify(execFile)` or wrap in try/catch (sync throw before spawn = callback never fires = hang). | Infra failures handled? Timeouts on outbound? No empty catch? |
| CQ9 | Data | — | universal | Multi-table mutations wrapped in transactions? FK order respected during delete/create sequences? | Multi-table mutations in transactions? FK order correct? |
| CQ10 | Data | — | universal | Nullable values guarded before access? No unsafe `.find()` without null check? No unvalidated `as Type` / `!` non-null assertion? | Nullable values handled? No silent null propagation? No unsafe array[0]/.find()? |
| CQ11 | Structure | — | universal | **File** within its type limit (service 300-450L, component 200-300L, hook 250L, util 100L)? **Functions** within limits (public 50L, private 30L, handler 25L, $tx 60L, useEffect 20L)? No deeper than 4 nesting levels? 5 params max? **Inline sub-components or helper closures ≥50 LOC inside a parent component file = violation regardless of total file size — extract to sibling.** **Hard gate: file exceeding 2x the type limit = automatic CQ11 FAIL.** | File within its type limit? Functions within limits (public 50L, private 30L)? Nesting <=4? Params <=5? (2x any limit = automatic FAIL) |
| CQ12 | Structure | — | universal | No magic strings or numbers? No index-based mapping (`row[0]`)? Named constants in use? | No magic strings/numbers? No index-based mapping (row[0])? Named constants in use? |
| CQ13 | Hygiene | — | universal | No dead code (unreachable branches, unused exports)? No TODO without a ticket reference? No stale feature flags (>30 days since full rollout = stale)? No mixed `console.*` and structured logger in same file? **Note: commented-out old implementations and debug leftovers are dead code. Explanatory comments, API examples, and documented workarounds are NOT.** | No dead code (unreachable branches, unused exports)? No TODO without a ticket? No mixed logging? |
| CQ14 | Hygiene | critical | universal | No duplicated logic? (a) block exceeding 10 lines repeated, OR (b) same structural pattern appearing 5+ times, OR (c) **block ≥3 lines repeated 4+ times across files when duplicates target the same module/action (high-fan-out: URL builders, mock factories, query-string helpers), OR (d) `vi.mock`/`jest.mock` for the same module duplicated 10+ times across the test suite — extract to `test-utils/`**? | No duplicated logic? (a) >10-line block repeated, (b) same pattern 5+ times, (c) >=3-line block 4+ times cross-file, (d) same mock 10+ times |
| CQ15 | Async | — | universal | Every async call awaited or explicitly fire-and-forget with `.catch()`? `return await` used inside try/catch? No `await` inside `Promise.all()` argument list? | Every async awaited or fire-and-forget with .catch()? No dropped promises? |
| CQ16 | Data | conditional: code manipulates prices, costs, discounts, invoices, payouts | universal | Monetary values use exact arithmetic (integer-cents, Decimal.js)? No `toFixed()` during computation? **Scope: actual currency amounts only.** Indices, ratios, scores = N/A. | Money uses exact arithmetic (Decimal/integer-cents)? No float for money? |
| CQ17 | Performance | — | universal | No sequential `await` in loops where batch or `Promise.all` suffices? No N+1 queries? No `.find()` inside a loop? | No sequential await in loops where batch/parallel works? |
| CQ18 | Data | — | universal | Cross-system consistency maintained? Multi-store operations handle partial failures? | Cross-system data consistency? Multi-store writes handle partial failures? |
| CQ19 | Contract | conditional: code crosses an API or module boundary (exception: thin controllers returning typed service data) | universal | API request AND response shapes validated by runtime schema? No hope-based typing? **Identity validators (`(v: unknown) => v`, bare `as T` after `await res.json()`, untyped `assertRecord`) do NOT satisfy CQ19 — they pass nothing through. Acceptable: Zod / Yup / Valibot parse, hand-written `assertObjectShape({...})` with at least one field check, typed tRPC client (note `// validated by tRPC schema` once per file).** | API request AND response validated by runtime schema? |
| CQ20 | Contract | conditional: payload contains `*_id` + `*_name` pairs, or number + currency-string for the same field | universal | Single canonical source per data point? No dual fields stored independently for the same concept? | Each data point ONE canonical source? No dual fields? |
| CQ21 | Concurrency | conditional: concurrent mutations target the same resource (not for read-only paths) | universal | No time-of-check-to-time-of-use races? Mutations idempotent or CAS-protected? Mutating API endpoints safe to retry (idempotency key or CAS guard)? No shared mutable state? | No TOCTOU? State machine transitions use CAS? Mutations idempotent? |
| CQ22 | Resources | conditional: code creates subscriptions, timers, or observers (not for stateless handlers) | universal | All listeners, timers, and observers cleaned up on unmount/destroy? No stale closures in callbacks? | All listeners/timers/subscriptions cleaned up on unmount? |
| CQ23 | Resources | conditional: code uses Redis, Memcached, or in-memory caching | universal | Cache entries have TTL or explicit invalidation? No stale-forever entries? Redis `SET` without `EX`/`PX` = violation. In-memory cache without eviction policy = violation. | Cache has TTL or explicit invalidation? No stale-forever entries? |
| CQ24 | Contract | conditional: code modifies existing API endpoint signatures | universal | API changes are additive only (new optional fields, new endpoints)? Removing or renaming fields has a deprecation path with migration guide? Breaking changes without versioning or deprecation = violation. | API changes additive only? Breaking changes have deprecation path? |
| CQ25 | Structure | — | universal | New endpoint/component/service follows existing project patterns? Same naming convention, same file structure, same error handling approach as existing code? "Special snowflake" = violation. | New code follows existing project patterns? No special snowflakes? |
| CQ26 | Observability | — | universal | Log statements use structured logger with context (requestId, userId, traceId), not plain `console.log` strings? Every service/controller uses the project's standard logger. | Structured logger with context (requestId, userId), not plain console.log? |
| CQ27 | Observability | — | universal | Log levels used correctly? `logger.error` reserved for unrecoverable failures and infrastructure errors, not validation failures or expected business conditions. `logger.warn` for recoverable but unexpected situations. Validation failure logged as `error` = violation. Stack trace logged as `info` = violation. | Log levels correct? `error` for infra failures only, not validation? |
| CQ28 | Resilience | conditional: code defines timeouts at 2+ architectural layers | universal | DB timeout < server timeout < client timeout (deadline shrinks with depth, not inverted)? If code defines timeouts at multiple layers, verify the hierarchy is correct. Inverted timeout hierarchy = violation. | Timeout hierarchy correct? DB < server < client (innermost shortest)? |
| CQ29 | Structure | — | universal | Workspace path alias used for imports ≥3 hops deep when the alias is configured? Aliases must come from the project's actual `tsconfig.compilerOptions.paths` / `jsconfig` / `vite.config.alias` — common patterns are `@/`, `#/`, `~/` but only count those declared in the workspace config. Files mixing `../../../` with a configured alias = violation. No alias configured = N/A. | Workspace path alias (@/, ~/, #/) used for imports >=3 hops deep when alias is configured? N/A if no alias in workspace. |
| CQ30 | Security | conditional: the endpoint mutates state AND authenticates via a cookie/session (not a bearer token the browser cannot auto-attach) | universal | CSRF defence present on state-changing endpoints? `SameSite=Lax\|Strict` on the session cookie AND an anti-CSRF token (or a non-cookie bearer transport)? A cookie-authenticated mutation with neither = violation. CWE-352 is rank 3 of the CWE Top 25 and had no gate. | CSRF defence on cookie-authed mutations? SameSite + token, or bearer transport? |
| CQ31 | Security | conditional: any user-controlled value reaches a filesystem path, a shell argv, a deserializer, or an outbound URL | universal | User input never reaches a dangerous sink unvalidated? (a) filesystem paths resolved + containment-checked (never `normalize`+`startsWith`), (b) subprocess arguments passed as an argv array, never an interpolated shell string, (c) no `pickle`/`yaml.load`/`unserialize` on non-first-party bytes, (d) outbound URLs allowlisted (SSRF, incl. IPv6 and redirect re-validation). Covers CWE-22/77/78/502/918 — none previously gated. | User input reaching path/shell/deserializer/outbound URL — allowlisted and validated? |
| CQ32 | Security | conditional: the change adds or updates a dependency, or the repo has a dependency manifest | universal | Supply chain controlled? Lockfile committed, no floating ranges or `latest` on a newly added dependency, and new dependencies checked against an advisory source. OWASP A03:2025 (Software Supply Chain Failures) is rank 3 and had no gate anywhere in CQ/CAP. | Lockfile committed, new deps pinned and CVE-checked? |
| CQ33 | Security | conditional: code generates a token/ID/nonce, hashes or encrypts, or reads a secret | universal | Cryptographic material handled correctly? Tokens/IDs/nonces from a CSPRNG (`crypto.randomUUID`/`randomBytes`/`secrets`), never `Math.random()`/`Date.now()`; credential hashing via argon2id or bcrypt (cost >= 12), never a bare SHA-*; no bespoke crypto; secrets read from config, never literals in source or a client bundle. | CSPRNG for tokens? Credential hashing argon2/bcrypt, not SHA? No bespoke crypto? |
| CQ34 | Security | conditional: the code is an endpoint/handler with roles, or writes a payload into a persistence layer | universal | Authorization complete at BOTH levels? (a) function-level: the handler asserts the caller's role/permission for THIS operation, not just that the caller is authenticated (BFLA); (b) field-level: write payloads are field-allowlisted, never a blanket spread into the ORM (mass assignment / BOPLA). CQ4 covers object/tenant scoping only — these two levels had no gate. | Role checked for THIS operation (not just authenticated)? Write payload field-allowlisted? |
| CQ35 | Concurrency | conditional: the code performs cancellable I/O or long-running work | universal | Cancellation propagated, not merely applied? The ambient cancellation handle (`AbortSignal` / `context.Context` / `CancellationToken` / `CoroutineScope`) is ACCEPTED as a parameter and forwarded to every downstream call — never re-created mid-request (`context.Background()`, a fresh `AbortController`) and never stored in a struct/field. Every derived handle is released (`defer cancel()`). A timeout no caller can cancel is not cancellation. | Cancellation handle accepted + forwarded downstream, not re-created? Derived handles released? |
| CQ36 | Concurrency | conditional: the code spawns background work | stack:go,rust,jvm,dotnet | Every spawned unit of work has a named owner that joins it, aborts it, or documents it as process-lifetime? No `go func()` / `tokio::spawn` / `Task.Run` / `GlobalScope.launch` whose handle is dropped. Fan-out is bounded (`errgroup.SetLimit`, `JoinSet`, `Semaphore`), never an unbounded loop-spawn. (TS/JS: dropped async work is CQ15.) | Every spawn has an owner that joins/aborts it? Fan-out bounded? |
| CQ37 | Concurrency | conditional: two or more threads/tasks touch the same state | stack:go,rust,jvm,dotnet | Shared mutable state race-free BY CONSTRUCTION (owned by one task, or behind a lock/atomic) AND proven by tooling — `go test -race`, TSan, `-ea` + `@GuardedBy`? No lock or guard copied by value (`go vet copylocks`), no `unsafe impl Send/Sync` without a written argument, no lock held across an `await`/`.await`/blocking call. A review opinion is not proof; the race detector is. | Race-free by construction AND proven by -race/TSan? No lock held across await? |
| CQ38 | Resources | conditional: the code acquires a handle, connection, lock, or file | stack:go,rust,jvm,dotnet | Deterministic release on EVERY exit path — `defer x.Close()` placed after the error check, try-with-resources, `using`/`await using`, or an RAII guard? HTTP bodies, rows, statements and files enumerated. No `defer` inside an unbounded loop. Cleanup only on the happy path = violation. (TS/JS listener + timer cleanup is CQ22.) | Deterministic release on every exit path? No defer inside an unbounded loop? |
| CQ39 | Resources | conditional: the code has a queue, channel, buffer, or fan-out whose size depends on external input | universal | Every queue, channel and fan-out bounded? An unbounded producer is CQ6 (unbounded memory) wearing a different hat: bounded channels, `SetLimit`, a semaphore, `BoundedChannelOptions`, or explicit backpressure (`writable.write()` return value honoured, `drain` awaited). Unbounded + a fast producer = OOM under load, not under test. | Queues/channels/fan-out bounded? Backpressure honoured on streams? |
| CQ40 | Hygiene | conditional: the project has a linter config, or the language has a standard one | universal | The language's meta-linter is configured, pinned, and clean in CI — `golangci-lint` (errcheck/govet/staticcheck/gosec/bodyclose/contextcheck), `clippy -D warnings` + cargo-deny, typescript-eslint type-checked (or Biome/oxlint type-aware), ruff + mypy, ErrorProne + NullAway, `TreatWarningsAsErrors`. **No config present = 0.** Roughly a third of the CQ set is mechanically checkable; a configured linter enforces those deterministically instead of an LLM re-deriving them per file. | Language meta-linter configured, pinned and clean in CI? No config = 0 |

## Q1-Q19 — Test Quality

| ID | Criticality | Gate (canonical) | Prompt short form |
|----|-------------|------------------|-------------------|
| Q1 | — | Every test name describes expected behavior (not "should work")? | Every test name describes expected behavior? |
| Q2 | — | Tests grouped in logical describe blocks? | Tests grouped in logical describe blocks? |
| Q3 | — | Every mock has `CalledWith` (positive) AND `not.toHaveBeenCalled` (negative)? | Every mock has CalledWith + not.toHaveBeenCalled? |
| Q4 | — | Known-data assertions use exact values (`toEqual`/`toBe`, not `toBeTruthy`)? | Assertions use exact matchers (toEqual/toBe, not toBeTruthy)? |
| Q5 | — | Mocks are typed (not `as any`/`as never`)? Note: `as unknown as ServiceType` is acceptable when no mock factory exists — it avoids `as any` while preserving the target type. Score Q5=1 for `as unknown as X`, Q5=0 only for `as any` or `as never`. | Mocks are typed (no `as any`)? |
| Q6 | — | Mock state is fresh per test (proper `beforeEach`, no shared mutable)? | Mock state fresh per test (beforeEach, no shared mutable)? |
| Q7 | critical | Every error-throwing path tested with specific error type AND message? (not just "at least one") | Every error-throwing path tested with specific type+message? |
| Q8 | — | Null/undefined/empty inputs tested where applicable? | Null/empty/edge inputs tested? |
| Q9 | — | Repeated setup (3+ tests) extracted to helper/factory? | Repeated setup (3+ tests) extracted to helper/factory? |
| Q10 | — | No magic values — test data is self-documenting? | No magic values -- test data is self-documenting? |
| Q11 | critical | All code branches exercised (if/else, switch, early return)? | All code branches exercised? |
| Q12 | — | Symmetric: every "does X when Y" has "does NOT do X when not-Y"? **For each repeated pattern (auth guard, validation, error), verify every method has it.** | Symmetric: "does X when Y" has "does NOT do X when not-Y"? |
| Q13 | critical | Tests import the actual production function (not a local copy)? | Tests import actual production function? |
| Q14 | — | Assertions verify behavior, not just that a mock was called? | Behavioral assertions (not just mock-was-called)? |
| Q15 | critical | Assertions verify content/values, not just counts or shape? | Content/values assertions, not just counts/shape? |
| Q16 | — | Cross-cutting isolation: change to A verified not to affect B? | Cross-cutting isolation: change to A verified not to affect B? |
| Q17 | critical | Assertions verify computed output, not input echo? Expected values from spec/manual calc, not copied from implementation (P-70). | Assertions verify COMPUTED output, not input echo? |
| Q18 | — | No flaky test signals? No `Date.now()` without fake timers, no `setTimeout` for timing, no `Math.random()` without seed, no reliance on execution order, no real network calls? | No flaky signals? No Date.now() without fake timers, no setTimeout for timing, no Math.random(), no real network? |
| Q19 | — | Tests fully isolated? No shared mutable state between tests (global variables, module-level `let`, database rows without cleanup)? Each test can run independently in any order? | Tests fully isolated? No shared mutable state between tests; each runs independently in any order? |

## CAP1-CAP29 — Code Anti-Patterns

| ID | Finding | Severity | Scope |
|----|---------|----------|-------|
| CAP1 | Empty catch block | HIGH | universal |
| CAP2 | Plain `console.log` in production. `console.warn`/`console.error` allowed ONLY when paired with Sentry.captureMessage/captureException on the same code path; otherwise MEDIUM. | MEDIUM | universal |
| CAP3 | `as any` / `as unknown as X` without validation (x5+ = HIGH). `as unknown as <DomainType>` after Prisma/ORM queries = HIGH (silent contract bypass). | MEDIUM | universal |
| CAP4 | @ts-ignore without justification | MEDIUM | universal |
| CAP5 | Hardcoded secret | AUTO TIER-D | universal |
| CAP6 | Unsanitized HTML reaching DOM or persistence. Covers `dangerouslySetInnerHTML` without DOMPurify, `editor.commands.setContent(rawHtml)`/raw-HTML mode without pre-save sanitization, paste-as-HTML, programmatic raw HTML writes. Display-time sanitization alone is INSUFFICIENT if persistence path is unsanitized. | AUTO TIER-D | universal |
| CAP7 | eval() / new Function() with dynamic input | AUTO TIER-D | universal |
| CAP8 | SQL string concatenation OR `$queryRaw`/`$executeRawUnsafe` against tenant tables without organizationId in WHERE | AUTO TIER-D | universal |
| CAP9 | File exceeds type limit (service <=450, controller <=300, hook <=250, component <=200, helper <=100) OR inline sub-component >=50 LOC nested in a parent component file (2x file limit = AUTO TIER-D) | HIGH | universal |
| CAP10 | Function > 100 lines (2x the 50L limit) | HIGH | universal |
| CAP11 | parseFloat/Number() on money field | HIGH | universal |
| CAP12 | await inside for/while without batch alternative | MEDIUM | universal |
| CAP13 | 7+ useState in one component, OR >=3 mutually-exclusive dialog/modal boolean flags (collapse to discriminated union `dialog: { kind: '...' } | null`), OR state mirroring URL params managed via local useState (use router query API) | MEDIUM | universal |
| CAP14 | Business logic >10 lines in component body that has no DOM dependency | MEDIUM | universal |
| CAP15 | API URL built without `encodeURIComponent` on dynamic path segments, OR hardcoded base URL string-concat (`` `${BASE}/api/foo/${id}` ``), OR unencoded user-controlled token in URL path/query. MUST use a single `buildApiUrl(path, pathParams)` helper and validate enum-typed segments against an allowlist before interpolation. | HIGH | universal |
| CAP16 | Client auth-token plumbing race (deferred-promise wait for provider, token injected mid-flight, no readiness gate before first request), OR missing 401-> refresh-> retry-once on REST clients while tRPC has it (or vice versa), OR unsigned/dev-only tokens accepted as auth credentials in any environment | HIGH | universal |
| CAP17 | `error.message` rendered directly to UI/DOM without a curated `userMessageFor(error)` mapping. Leaks server stack/PII; map known error types to safe messages and fall back to a generic "Something went wrong". | HIGH | universal |
| CAP18 | `throw new Error(...)` from a service/injectable/handler. Use a typed exception class instead (BadRequestException, NotFoundException, custom DomainError); bare Error loses HTTP status mapping and can leak the original message into 5xx response bodies. | MEDIUM | universal |
| CAP19 | Mutating endpoint, AI/expensive operation (LLM call, export, generation), webhook receiver, or tRPC procedure without a rate limiter (ThrottlerGuard, custom limiter, queue with concurrency cap). tRPC bypassing the project-wide ThrottlerGuard = always violation. | HIGH | universal |
| CAP20 | Mutable object as a default argument or dataclass field default (`def f(x=[])`, `field: list = []`) | HIGH | stack:python |
| CAP21 | `except Exception: pass`, bare `except:`, or catch-and-return-None with no log and no re-raise | HIGH | stack:python |
| CAP22 | `assert` used as a runtime precondition in production code — stripped under `python -O`, silently deleting the check (CWE-703) | HIGH | stack:python |
| CAP23 | `asyncio.create_task`/`ensure_future` whose result is not retained — the loop keeps only a weak reference, so the task can vanish mid-flight | HIGH | stack:python |
| CAP24 | Blocking call inside `async def` — `requests`, `time.sleep`, bare `open`, a sync DB driver, `boto3` | HIGH | stack:python |
| CAP25 | `pickle`/`marshal`/`dill` load, or `yaml.load` without `SafeLoader`, on non-first-party bytes | AUTO TIER-D | stack:python |
| CAP26 | `subprocess`/`os.system` with `shell=True` or a non-literal command string (CWE-78) | AUTO TIER-D | stack:python |
| CAP27 | Naive `datetime.now()`/`utcnow()` stored, compared, or serialized (`utcnow` is deprecated in 3.12) | MEDIUM | stack:python |
| CAP28 | Module-import-time side effect — DB engine, HTTP client, network call, or `os.environ[k]` at import | MEDIUM | stack:python |
| CAP29 | `__del__` used for resource release, or `.close()` without `with`/`try-finally` — GC timing is unguaranteed and `__del__` exceptions are swallowed | MEDIUM | stack:python |

## AP1-AP30 — Test Anti-Patterns

> Deduction: -1 per unique AP, capped at -5. AP13 and AP16 are AUTO TIER-D triggers.

| ID | Smell |
|----|-------|
| AP1 | try/catch in test swallowing errors |
| AP2 | Conditional assertions (if/else in test) |
| AP3 | Re-implementing production logic in test |
| AP4 | Snapshot as only test for component |
| AP5 | `as any` -> `as never` bypassing types |
| AP6 | Testing CSS classes instead of behavior |
| AP7 | .catch(() => {}) swallowing errors |
| AP8 | document.querySelector bypassing Testing Library |
| AP9 | Always-true assertion (expect(true).toBe(true)) |
| AP10 | Tautological mock (call mock -> verify mock called, no production code) |
| AP11 | vi.mocked(vi.fn()) -- mock targeting fresh fn |
| AP12 | waitForTimeout(N) hardcoded delays |
| AP13 | Test with zero expect() calls -- AUTO TIER-D |
| AP14 | toBeTruthy()/toBeDefined() as sole assertion on complex object |
| AP15 | Testing private methods directly |
| AP16 | Fixture:assertion ratio > 20:1 -- AUTO TIER-D |
| AP17 | Unused test data declared but never used |
| AP18 | Duplicate test names (copy-paste indicator) |
| AP19 | expect.anything() hiding callback contract |
| AP20 | Mock returns same data for ALL methods |
| AP21 | .calls[N] magic index (fragile) |
| AP22 | CSS selector in test |
| AP23 | Inline mockRestore() with afterEach present (redundant) |
| AP24 | consoleSpy typed as `any` |
| AP25 | `expect(x.length).toBe(N)` instead of `.toHaveLength(N)` — worse failure output, masks a missing property (Q4). JS-only: pytest/Go/Rust have no equivalent, mark N/A there |
| AP26 | Real timers in time-dependent tests (Date.now/setTimeout without useFakeTimers) |
| AP27 | `expect(x.length).toBeGreaterThan(0)` when the fixture's exact count is known — masks off-by-one and duplicates (Q4/Q15) |
| AP28 | Persistent `it.skip`/`describe.skip`/`@Ignore`/`#[ignore]`/`@pytest.mark.skip` with no ticket or expiry — dead code plus a silent coverage gap |
| AP29 | Mock return value echoed in the assertion — proves the mock setup, not production logic (Q17). The most common audit failure |
| AP30 | Mocking own code that could run with a real implementation (was AP25 until the numbering fork was resolved; overlaps `fix-tests` P-68 and Q13) |

## Cost of changing a gate

Before: ~30 edit sites across 27 files (the CQ table alone lived in 4 copies, scoring in 5, the AP
catalogue in 4 namespaces). Evidence it did not work: CQ29 shipped and six places still said 28.

Now: **3 steps.**

1. edit the row here
2. `python3 scripts/gen-gate-copies.py --write`
3. commit both — `tests/gates/test-gate-consistency.sh` (also wired into `scripts/validate-skills.sh`)
   fails the build if you skip step 2, if someone edits a generated region by hand, or if a new
   hand-maintained copy of the table appears anywhere in the repo.

Generated regions currently live in: `rules/cq-checklist.md`, `rules/testing.md`,
`shared/includes/quality-gates.md`, `docs/quality-gates.md`, `skills/code-audit/SKILL.md`,
`skills/test-audit/SKILL.md`. Run `python3 scripts/gen-gate-copies.py --list` for the live list.

## Detector evidence (Python CAPs)

CAP20-CAP27 are not opinions — each has a deterministic detector, verified by running `ruff`
0.15.20 against a file containing all of them (9/9 fired):

| CAP | Rule |
|-----|------|
| CAP20 mutable default | `B006` |
| CAP21 blind except / except-pass | `BLE001` + `S110` |
| CAP22 assert in production | `S101` (bandit B101 → CWE-703) |
| CAP23 dangling create_task | `RUF006` |
| CAP24 blocking call in async | `ASYNC210` (also 212/230/240/251) |
| CAP25 pickle / unsafe yaml | `S301` / `S506` |
| CAP26 shell=True | `S602` (also 604/605) |
| CAP27 naive datetime | `DTZ003` / `DTZ005` |

Where a deterministic detector exists, prefer running it (see **CQ40**) over having an LLM
re-derive the finding per file. The CAP entry exists so the audit REPORTS it consistently and
attaches a severity, not so an agent hunts for it by hand.

## Known gaps (stated, not hidden)

- **AP numbering fork — RESOLVED 2026-07-28.** `AP25` meant two different smells depending on which
  file you opened: `.length`-instead-of-`.toHaveLength` in `rules/testing.md` + `docs/quality-gates.md`,
  and "mocking own code" in the executable `test-audit` checklist. Resolved in favour of the PUBLISHED
  prose meaning (it had already shipped to the website and to two rule files), with the executable
  meaning re-homed to **AP30**. `AP27`-`AP29` were defined in prose and never executable; they are now
  in the registry, so `AP1-AP30` is a truthful claim for the first time.
  The tie-break rule for any future collision: **the meaning that already shipped to users wins**;
  the newer one takes a fresh ID. Renumbering a published ID silently re-labels every historical
  report that cites it.
- **Q18/Q19 prompt forms** are authored here rather than lifted from `test-audit`, which shipped
  Q1-Q17 only. Their canonical text comes from `rules/testing.md`.
