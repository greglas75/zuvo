# Fix Loop Protocol

> Shared include — apply code fixes from review/audit findings with verification.

## Input

The calling skill provides:
- **FINDINGS**: list of findings to fix (ID, severity, file, description, suggested fix)
- **SCOPE_FENCE**: allowed files (from triage or plan)
- **MODE**: determines which findings to apply

## Execution Strategy

| Condition | Strategy |
|-----------|----------|
| <3 fixes OR fixes share files | Sequential (severity order) |
| 3+ fixes on independent files | Parallel (up to 3 agents per env-compat.md) |

Before choosing parallel: verify target files do not import each other. Any dependency between targets forces sequential.

## Fix Loop

For each fix in the list:

1. Apply the fix within the scope fence — modify only files in SCOPE_FENCE
2. Write any required tests (complete, runnable — not stubs)
3. Run verification: detect the project's test runner and execute the full suite
4. If tests fail: check for flaky tests (re-run once), then fix the regression
5. If tests pass: proceed to Execute Verification Checklist

## Execute Verification Checklist

After all fixes applied, before committing:

```
[Y/N]  SCOPE: No files modified outside scope fence
[Y/N]  SCOPE: No new features beyond what the fix requires
[Y/N]  TESTS: Full test suite green
[Y/N]  LIMITS: All files within size limits (production <=300L, test <=400L)
[Y/N]  CQ: Self-eval on each modified production file
[Y/N]  Q: Self-eval on each modified/created test file
[Y/N]  NO SCOPE CREEP: Only report fixes applied, nothing extra
```

Any failure must be addressed before committing.

## Commit

```bash
git add [specific files — never git add -A]
git commit -m "<skill>-fix: [brief description of what was fixed]"
```

- Interactive environment: confirm before committing
- Non-interactive (Codex App, Cursor): commit automatically, do NOT push

## High-Risk Fix Policy

For fixes touching DB migrations, security/auth, API contracts, or payment/money:
apply one at a time and run tests after each. If a fix breaks tests, revert it immediately and report as `[!]`.
