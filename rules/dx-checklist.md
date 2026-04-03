# Developer Experience Quality Gates (DX1-DX8)

Meta-quality: how easy is this codebase for the next developer? Run during code review, onboarding assessment, or architecture review.

---

## 8 Developer Experience Gates

| # | Domain | Gate |
|---|--------|------|
| DX1 | Onboarding | **Setup time** — README → running dev server in <5 minutes. Prerequisites listed. Setup script exists or steps are <10 commands. No undocumented manual steps (secret keys, database seeds, etc.). |
| DX2 | Error Messages | **Actionable errors** — developer-facing error messages include: what went wrong, why, and how to fix it. Not just error codes or cryptic messages. Config errors suggest the correct setting. Missing env vars name the variable and show an example value. |
| DX3 | Type Safety | **IDE autocomplete works** — no `any`, no `as unknown as X`, no `!` non-null assertions without documented reason. Generics used where appropriate. Return types explicit on public API. IDE can navigate to definitions (no dynamic imports breaking resolution). |
| DX4 | Debuggability | **Stack traces are useful** — errors point to the actual problem, not to a framework wrapper 5 levels deep. Error wrapping preserves original cause (`cause` property or equivalent). Source maps configured for transpiled code. |
| DX5 | Config Docs | **Environment variables documented** — `.env.example` exists and is complete. Each variable has: name, description, type, default value, example. Required vs optional marked. Groups organized by service (DB, Auth, Email, etc.). |
| DX6 | Consistency | **Patterns are consistent** — new endpoint/component/service looks like existing ones. No "special snowflakes." Same error handling pattern across all services. Same request validation approach across all endpoints. Same test structure across all test files. |
| DX7 | Test Readability | **Test names describe behavior** — `it("should reject expired authentication token")` not `it("calls validate()")`. Test body follows Arrange-Act-Assert clearly. Test data is meaningful, not `foo/bar/baz`. Helpers/fixtures are named for their purpose. |
| DX8 | Migration Path | **Breaking changes are documented** — version upgrades have migration guide with before/after code examples. Deprecation warnings reference the replacement. Database migrations are reversible. Config changes are backward-compatible or documented. |

---

## Scoring

Each gate: **1** (pass with evidence), **0** (fail or unproven), **N/A** (precondition not active).

**Always-on gates:** DX1, DX5, DX6 — fundamental for any project with >1 contributor.

**Conditional gates:**
- DX2 — critical for frameworks/libraries (consumers see errors) and backend services (operators debug errors)
- DX3 — critical for TypeScript/Java/C#/Go projects. N/A for Python/Ruby without type annotations.
- DX4 — critical for production services. N/A for scripts or CLI tools.
- DX7 — critical when project has >50 tests
- DX8 — critical for libraries, APIs, or packages consumed by others

**Thresholds:**
- **PASS:** 6+ out of 8 AND all active gates = 1
- **WARN:** 4-5 AND no critical gate = 0
- **FAIL:** any always-on gate = 0, OR total below 4

---

## Evidence Standards

```
DX1=1
  Scope: README.md setup section
  Evidence: README.md:15-30 — 6-step setup (clone, install, copy .env, seed, migrate, start)
            scripts/setup.sh exists — automates all steps
  Exceptions: Docker setup requires Docker Desktop (documented as prerequisite)

DX5=1
  Scope: .env.example (23 variables)
  Evidence: .env.example — all 23 vars present with comments
            Grouped: Database (4), Auth (3), Email (2), Storage (2), App (12)
            Required marked with # REQUIRED, optional with # Optional (default: value)
  Exceptions: none

DX6=1
  Scope: 8 service files, 12 controller files
  Evidence: All services follow constructor(private readonly repo: Repository) pattern
            All controllers follow @UseGuards + @ApiTags + method pattern
            Error handling: all use AppException.from() wrapper
  Exceptions: WebSocket gateway uses different pattern (documented in architecture.md)
```

---

## When to Use

- `zuvo:code-audit` — include DX gates alongside CQ gates
- `zuvo:review` — check DX6 (consistency) in PR reviews
- `zuvo:docs` — verify DX1 (onboarding), DX5 (config docs) when generating documentation
- `zuvo:architecture` — check DX6 (consistency), DX8 (migration path) in architecture reviews
- `zuvo:design-review` — check DX2 (error messages) for user-facing error states
