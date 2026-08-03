# Quality Gates

Zuvo enforces two quality gate systems: **CQ1-CQ40** for production code and **Q1-Q25** for test code, plus two anti-pattern catalogues (**CAP1-CAP29** for code, **AP1-AP32** for tests). Every skill that writes or reviews code runs these evaluations with evidence requirements. Scores determine whether work can proceed.

> **Where gates are defined, and how to change one.** Every gate on this page is GENERATED from
> [`../shared/includes/gate-registry.md`](../shared/includes/gate-registry.md) — the single source
> of truth for all 124 gates. Editing a table here is overwritten on the next build and caught by
> `tests/gates/test-gate-consistency.sh`.
>
> To add or change a gate: **(1)** edit the row in the registry, **(2)** run
> `python3 scripts/gen-gate-copies.py --write`, **(3)** commit both. The definitions previously
> lived in 4-6 hand-maintained copies each and drifted — CQ14 lost three of its four clauses in the
> audit prompt, CQ28's timeout hierarchy was inverted in seven places, and adding one gate meant
> ~30 edits across 27 files (which is why CQ29 shipped with six places still saying "28").

### Three outcomes, not two

A gate can be `1`/`0` (evaluated), **`N/A`** (applies to this stack, but its precondition does not
hold in this file — a judgement, so it needs the same negative-evidence citation as a `0` and is
capped at one third of the in-scope gates), or **`out-of-scope`** (the gate's stack does not match
the project at all — mechanical, so it costs nothing). Only `out-of-scope` is free; that is what
lets stack-specific gates be added without taxing every other project.

All verdict thresholds are **percentages of applicable**, never raw counts over a fixed
denominator — a fixed count silently changes meaning every time the gate set grows.

---

## CQ1-CQ40: Code Quality Gates

Each gate is scored **1** (pass with evidence), **0** (fail or unproven), or **N/A** (precondition not active, requires justification).

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
| CQ30-CQ40 | Each carries its own trigger — see the `Criticality` column in `shared/includes/gate-registry.md` (the canonical source). Do NOT re-enumerate them here: this table sat frozen at CQ28 while eleven more conditional-critical gates landed, which is how a "critical" gate becomes invisible to anything reading this page. |

### CQ scoring thresholds

| Result | Criteria |
|--------|---------|
| **PASS** | Score >= 86% of applicable AND all active critical gates = 1 |
| **CONDITIONAL PASS** | Score >= 79% and < 86% of applicable AND all active critical gates = 1 |
| **FAIL** | Any active critical gate = 0, OR score < 79% of applicable |

`applicable = 40 - count(out-of-scope) - count(N/A)` — a PERCENTAGE, never a fixed denominator.
These read `>= 25/29` until 2026-08-02; the set has been 40 gates since CQ30-CQ40 landed, so the
threshold silently decayed to 62% of the real set and passed files that should have failed.
Canonical: `shared/includes/quality-gates.md` → CQ Scoring.

---

## Q1-Q25: Test Quality Gates

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
| Q20 | **CONDITIONAL** — Test level declared and respected? The file states whether it is a small (in-process, no I/O, no sleep), medium, or large test, and stays in that level — no file mixes in-process units with real network, DB, filesystem, or `sleep`. A "unit" test that opens a socket is the flake nobody can reproduce. |
| Q21 | **CONDITIONAL** — Changed production files reach a mutation score >= 70%, or every surviving mutant is triaged as equivalent/arid with a written reason? This is the only gate that measures test STRENGTH rather than test STYLE — coverage says a line ran, a surviving mutant says nothing checked what it did. (Stryker / mutmut / PIT / go-mutesting / cargo-mutants.) |
| Q22 | **CONDITIONAL** — Every pure/validator unit has at least one property or invariant test over generated inputs, with the seed recorded (fast-check / Hypothesis / proptest / jqwik)? |
| Q23 | **CONDITIONAL** — The request/response contract is verified against a SHARED artifact — a Pact file, or an OpenAPI/JSON-Schema validated on BOTH consumer and provider — rather than a hand-written mock that only proves the mock matches itself? The test-side twin of CQ19. |
| Q24 | **CONDITIONAL** — The suite passes under RANDOMIZED order with the seed logged (`--sequence.shuffle`, `-p randomly`, `go test -shuffle=on`, `MethodOrderer.Random`)? Q18 greps for hazard tokens; this gate proves determinism by construction — it fails the suite Q18 passes when the dependency hides in a shared module-level fixture. |
| Q25 | **CONDITIONAL** — Changed lines reach >= 90% patch coverage with zero new uncovered branches, enforced server-side? Patch coverage gates the diff; project-level coverage lets a large green codebase hide an untested change. |
<!-- GATES:END kind=q-table -->

### Critical gates (always block)

**Q7, Q11, Q13, Q15, Q17**

### Q scoring thresholds

| Result | Criteria |
|--------|---------|
| **PASS** | Score >= 82% of applicable, all critical gates = 1 |
| **FIX** | Score >= 53% and < 82% of applicable, all critical gates = 1 -- fix worst gaps, re-score |
| **REWRITE** | Score < 53% of applicable, OR any critical gate = 0 -- tests need fundamental rework |

Same rule as CQ: a percentage of applicable gates, never a fixed denominator. This table mixed two
frozen denominators (`/25` and `/19`) until 2026-08-02. Canonical:
`shared/includes/quality-gates.md` → Q Scoring.

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
Self-eval: Q1=1 Q2=1 Q3=0 Q4=1 Q5=1 Q6=1 Q7=1 Q8=0 Q9=1 Q10=1 Q11=1 Q12=0 Q13=1 Q14=1 Q15=1
           Q16=1 Q17=1 Q18=1 Q19=1 Q20=1 Q21=N/A Q22=1 Q23=N/A Q24=1 Q25=1
  Score: 20/23 applicable (87%) -> PASS | Critical gate: Q7=1 Q11=1 Q13=1 Q15=1 Q17=1 -> PASS
```

---

## N/A abuse prevention

`count(N/A)` may not exceed **one third of the in-scope gates** — the proportional cap in
`rules/cq-checklist.md`, which is the canonical rule. Over that, the evaluation is a **low-signal
audit**. Every N/A requires a one-sentence justification, held to the same evidence rigour as a 0
(an exhaustive negative assertion, not "probably not applicable").

**N/A does NOT count as a pass.** It leaves both the numerator and the denominator:

```
in_scope    = 40 - count(out-of-scope)
denominator = in_scope - count(N/A)
pass_count  = count(score == 1)        # 1s only
```

The ratio alone is **not** an anti-gaming guard — read plainly it rewards abuse, because dropping
a `0` out of the denominator raises the percentage — three passes against two failures scores 60%,
and re-marking both failures N/A scores 100% on identical code. What actually closes that path is
the four HARD rules in `rules/cq-checklist.md`
→ "N/A cannot raise the score": an N/A needs the SAME exhaustive negative evidence as a 0, the
one-third cap above, gates listed for the file's code type can never be N/A, and `pass_count` /
`count(N/A)` / denominator are printed next to every percentage. Quote the formula only together
with those rules.

This page said "N/A counts as 1 for scoring" with a 60% cap until 2026-08-02 — both errors pushed
the same way, and they compounded: counting N/A as a pass *while* shrinking the denominator made
re-labelling a failure a double upgrade, and a 60% cap left room to do it to most of the set.

This prevents agents from marking everything N/A to avoid doing the evaluation work.

---

## Fix-first rule

When a gate violation is found during evaluation:

1. **Can you fix it in under 5 minutes?** Fix it now, re-score as 1.
2. **Is it a critical gate?** Fix it now regardless of time.
3. **Otherwise:** Score as 0, note what needs fixing, persist to backlog if not fixed this session.

Adding a WHERE clause, null guard, try/catch, or type annotation is never "out of scope."

---

## Test anti-patterns (AP1-AP32)

Test audits check for 32 anti-patterns in addition to the Q1-Q25 gates. These are common structural problems that reduce test value:

The full catalogue, generated from `../shared/includes/gate-registry.md` — this used to be a
hand-written summary that glossed the first eighteen entries with descriptions matching none
of them, and skipped six more entirely.

<!-- GATES:BEGIN kind=ap-list -->
AP1: try/catch in test swallowing errors
AP2: Conditional assertions (if/else in test)
AP3: Re-implementing production logic in test
AP4: Snapshot as only test for component
AP5: `as any` -> `as never` bypassing types
AP6: Testing CSS classes instead of behavior
AP7: .catch(() => {}) swallowing errors
AP8: document.querySelector bypassing Testing Library
AP9: Always-true assertion (expect(true).toBe(true))
AP10: Tautological mock (call mock -> verify mock called, no production code)
AP11: vi.mocked(vi.fn()) -- mock targeting fresh fn
AP12: waitForTimeout(N) hardcoded delays
AP13: Test with zero expect() calls -- AUTO TIER-D
AP14: toBeTruthy()/toBeDefined() as sole assertion on complex object
AP15: Testing private methods directly
AP16: Fixture:assertion ratio > 20:1 -- AUTO TIER-D
AP17: Unused test data declared but never used
AP18: Duplicate test names (copy-paste indicator)
AP19: expect.anything() hiding callback contract
AP20: Mock returns same data for ALL methods
AP21: .calls[N] magic index (fragile)
AP22: CSS selector in test
AP23: Inline mockRestore() with afterEach present (redundant)
AP24: consoleSpy typed as `any`
AP25: `expect(x.length).toBe(N)` instead of `.toHaveLength(N)` — worse failure output, masks a missing property (Q4). JS-only: pytest/Go/Rust have no equivalent, mark N/A there
AP26: Real timers in time-dependent tests (Date.now/setTimeout without useFakeTimers)
AP27: `expect(x.length).toBeGreaterThan(0)` when the fixture's exact count is known — masks off-by-one and duplicates (Q4/Q15)
AP28: Persistent `it.skip`/`describe.skip`/`@Ignore`/`#[ignore]`/`@pytest.mark.skip` with no ticket or expiry — dead code plus a silent coverage gap
AP29: Mock return value echoed in the assertion — proves the mock setup, not production logic (Q17). The most common audit failure
AP30: Mocking own code that could run with a real implementation (was AP25 until the numbering fork was resolved; overlaps `fix-tests` P-68 and Q13)
AP31: Committed focus marker — `it.only`/`describe.only`/`test.only`/`fit`/`fdescribe`/`@pytest.mark.only`-style filter left in a committed test file. Silently disables the REST of the suite while CI reports green — a whole-suite coverage collapse, worse than a skip. Deterministic detector: grep / Biome `noFocusedTests`. **AUTO TIER-D**
AP32: Flake-masking retries — per-test/per-suite `retries:`/`@Retry`/`flaky=True` annotation with no ticket or expiry (same contract as AP28's skip rule). Retry hides the nondeterminism Q18/Q24 exist to surface
<!-- GATES:END kind=ap-list -->

Full AP definitions with detection heuristics and fix guidance are in `rules/testing.md`.

---

## Where to find the full definitions

- **CQ details, scoring rules, evidence examples:** `rules/cq-checklist.md`
- **CQ code patterns (NEVER/ALWAYS pairs):** `rules/cq-patterns.md`
- **Q details, test patterns, scoring:** `rules/testing.md`
- **Test quality enforcement rules:** `rules/testing.md` (incl. Assertion Strength Classifier + Self-Eval Evidence, absorbed from the retired test-quality-rules.md 2026-08-01)
- **Quick reference for agents:** `shared/includes/quality-gates.md`
