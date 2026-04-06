# Adversarial Loop

> Referenced by: /build, /write-tests, /execute, /refactor, /write-e2e, /debug, /fix-tests, /receive-review, /seo-fix, /code-audit, /test-audit, /security-audit.
> For document artifacts (specs, plans, audit reports): see `adversarial-loop-docs.md`.

## Purpose

After a skill writes code, consult a DIFFERENT AI model to catch blind spots before presenting results to the user. This is a **smart adversarial second opinion** — not a QA gate, not proof of correctness.

**MANDATORY.** This loop is not optional. The agent does NOT decide whether to run it. If the skill references this include, the adversarial review runs. Period. Self-review bias (the agent skipping review of its own output) is the primary failure mode this protocol prevents.

## What Counts as Code Changes

Adversarial review runs when the skill produces any of these:
- New or modified source code files (.ts, .tsx, .js, .py, .go, .php, .rs, etc.)
- New or modified test files (.test.*, .spec.*, *_test.*)
- New or modified shell scripts with logic
- Modified database migrations, schema files

**Skip ONLY when ALL of these are true:**
- Config-only changes (package.json version bump, tsconfig, .env, CI config) with zero logic changes
- OR mechanical-only changes (symbol rename without logic change, formatting by tool, import reordering only)
- OR no provider available (note in output, proceed normally)

When skipped, state the reason. "Skipped" is NOT a clean pass — make this clear in output.

## Execution

### Step 1: Risk override

The calling skill sets the default mode. Check if high-risk signals require an override:

```
HIGH_RISK = diff content contains: auth, guard, token, session, payment, billing,
            charge, migration, schema, encrypt, decrypt, hash, secret, password, pii
         OR file paths match: */migrations/*, schema.prisma, *.sql, */auth/*,
            */payment/*, */billing/*, */crypto/*

IF HIGH_RISK AND mode is "code":
  Override to --mode security

IF HIGH_RISK AND file paths match */migrations/*, schema.prisma, *.sql:
  Override to --mode migrate
```

### Mode table

| Skill | Default mode | Risk override |
|-------|-------------|---------------|
| /build | `code` | `security` or `migrate` on high-risk signals |
| /execute | `code` | same |
| /write-tests | `test` | N/A |
| /write-e2e | `test` | N/A |
| /refactor | `code` | `security` on high-risk signals |
| /debug | `code` | `security` on high-risk signals |
| /fix-tests | `test` | N/A |
| /receive-review | `code` | `security` on high-risk signals |
| /seo-fix | `code` | N/A |

### Step 2: Run adversarial review

Run the script as a **single foreground Bash call**. The script auto-detects available providers and returns results. Do NOT manage providers yourself.

```bash
git add -u
git diff --staged | adversarial-review --json --single --mode {MODE}
```

Use `--single` (first available provider, fastest). Multi-provider mode is reserved for `/review` and dedicated review flows.

**If staged diff doesn't reflect the skill's changes** (e.g., skill worked on explicit files, not staged): use `--files` instead:
```bash
adversarial-review --json --single --mode {MODE} --files "path/to/changed/file.ts"
```

**IMPORTANT:** Run as foreground Bash call. Wait for complete output before proceeding. Do NOT use background execution.

**If `adversarial-review` is not in PATH:** try `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`.

**If the script exits non-zero with empty output:** note `adversarial review: skipped (no provider available)` and proceed.

**If output is not valid JSON:** treat as raw text findings. Do NOT try to parse severity programmatically from prose. Present raw text in the adversarial section. Do NOT auto-fix based on unstructured output.

### Step 3: Meta-review check

```
IF findings == 0 AND diff_lines > 150:
  Add to output: "⚠ Adversarial returned clean on 150+ line diff — possible false negative. Consider running zuvo:review for thorough multi-provider check."
```

### Step 4: Apply fix policy

```
For each finding:

  CRITICAL  ->  Fix immediately. No exceptions.

  WARNING   ->  Is the fix < 10 lines AND localized (same file, no cross-file impact)?
                  YES  ->  Fix immediately
                  NO   ->  Do NOT fix. Add to "known concerns."

  INFO      ->  Do NOT fix. Add to "known concerns."
```

**Known concerns limit:** Max 3 items, one line each, highest severity first. If more than 3, keep top 3 and note "(N more omitted)".

### Step 5: Validation re-run (max 1)

If Step 4 fixed any CRITICAL or WARNING:

1. Stage fixes: `git add -u`
2. Re-run: `git diff --staged | adversarial-review --json --single --mode {MODE}`
3. **This is a validation run, NOT a new repair cycle.** If new issues found:
   - New CRITICAL → add to known concerns, STOP. Do NOT attempt another fix.
   - New WARNING caused by previous fix → add to known concerns, STOP.
   - Only INFO → add to known concerns, proceed.

**Hard limit: 2 total adversarial calls per task.** No third run.

### Step 6: Present to user

| State | Presentation | Wording |
|-------|-------------|---------|
| No findings | Normal delivery | "complete" |
| Clean on large diff (150+ lines) | Normal with note | "complete" + false-negative warning |
| Only INFO | Normal delivery | "complete" + known concerns |
| Unresolved WARNING | Deliver with disclosure | "complete" + explicit WARNING list |
| Unresolved CRITICAL | **DO NOT say "complete"** | "implementation done, but adversarial review found unresolved critical issue(s)" |
| Skipped | Normal with note | "complete" + `adversarial review: skipped ([reason])` |

**Output format:**

```
[task description] complete
Adversarial review ([provider]): [N] issues found, [N] fixed
  Fixed:
  - [CRITICAL] [description] ([file]:[line])
  Known concerns (not fixed):
  - [WARNING] [description] — non-local fix
  - [INFO] [description]
```

When clean:
```
[task description] complete
Adversarial review ([provider]): clean pass
```

When skipped:
```
[task description] complete
Adversarial review: skipped ([reason])
```

Valid skip reasons: `config-only changes`, `mechanical-only changes`, `no provider available`, `script not found`

---

## Integration Points

Each skill adds the adversarial loop at a specific phase. The loop is **MANDATORY** at these points — the agent does not decide whether to run it.

### /build — Phase 4.4 (after implementation + tests passing)
### /write-tests — Phase 4.5 (after all tests written and passing)
### /execute — Step 7b (after quality review passes, every task)
### /refactor — Phase 4 (after CQ Post-Audit)
### /debug — Phase 4.6 (after CQ self-eval)
### /fix-tests — Step 5 (after all tests pass)
### /receive-review — after all fixes implemented
### /write-e2e — Phase 3 (after quality gates pass)
### /seo-fix — Phase 3 (after verify/build passes)

---

## What This Is NOT

- **Not a replacement for zuvo:review** — this uses `--single` (one provider). zuvo:review uses multi-provider with confidence scoring.
- **Not a quality gate** — does not block completion (except: unresolved CRITICAL changes wording).
- **Not recursive** — max 2 calls. Third opinion is zuvo:review's job.
- **Not proof of correctness** — "clean pass" means one model found nothing. Different model = potentially different findings.
- **Not optional** — if referenced by a skill, it runs. The agent does not skip it.
