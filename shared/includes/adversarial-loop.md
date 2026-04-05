# Adversarial Loop

> Referenced by: /build, /write-tests (Phase 1). Later: /execute, /write-e2e, /refactor.
> NOT referenced by: /review (already IS review), /debug (speed > thoroughness), /audit-* (audits, not code).

## Purpose

After a skill writes code, consult a DIFFERENT AI model to catch blind spots before presenting results to the user. This is a **smart adversarial second opinion** — not a QA gate, not proof of correctness. "Adversarial clean" means no issues found by this pass, not that code is bug-free.

## When to Run

Run adversarial loop when **ANY** of these are true:

| Condition | Rationale |
|-----------|-----------|
| Diff > 30 lines (production + test combined) | Enough context for meaningful review |
| Diff touches auth, authorization, or session logic | High-risk even at 5 lines |
| Diff touches billing, payment, or money flow | Financial impact |
| Diff touches migrations or schema changes | Data integrity |
| Diff touches cryptographic operations or secrets | Security-critical |
| Diff touches PII or sensitive data handling | Compliance risk |

**Skip when ALL of:**
- Diff <= 30 lines AND none of the high-risk triggers above
- Config-only changes (package.json, tsconfig, .env, CI config)
- No provider available (note in output, proceed normally)
- Script timeout > 120s (note in output, proceed normally)

## Mode Selection

The calling skill determines the mode:

| Skill | Default mode | Override to `--mode security` when |
|-------|-------------|-----------------------------------|
| /build | `--mode code` | Auth, payment, crypto, PII signals in diff |
| /execute | `--mode code` | Same |
| /write-tests | `--mode test` | N/A (test mode handles security test patterns) |
| /write-e2e | `--mode test` | N/A |
| /refactor | `--mode code` | Same |

## Execution

### Step 1: Check threshold

Count changed lines. Check for high-risk file patterns.

```
CHANGED_LINES = count insertions + deletions from git diff --staged --stat
HIGH_RISK = diff content contains: auth, guard, token, session, payment, billing,
            charge, migration, schema, encrypt, decrypt, hash, secret, password, pii
         OR file paths match: */migrations/*, schema.prisma, *.sql, */auth/*,
            */payment/*, */billing/*, */crypto/*

IF CHANGED_LINES < 30 AND NOT HIGH_RISK:
  Skip adversarial. Set ADVERSARIAL_RESULT = "skipped (diff < 30 lines, no high-risk signals)"
  Go to Step 5.
```

### Step 2: Run adversarial review

```bash
SCRIPT_PATH="{plugin_root}/scripts/adversarial-review.sh"
```

If script not found or not executable: skip, note in output, proceed normally.

```bash
git add -A
```

Detect available providers, then randomly select 2 for dispatch. This ensures different model combinations across runs, maximizing blind-spot coverage over time.

```
Available providers (check in order): gemini, codex-app, cursor
Select 2 at random from those available.
If only 1 available: use that one.
If 0 available: skip adversarial, note in output.
```

Dispatch selected providers in parallel as background Agent tasks — merge results:

```
Agent 1: git diff --staged | "$SCRIPT_PATH" --provider {RANDOM_PROVIDER_1} --json --mode {MODE}
Agent 2: git diff --staged | "$SCRIPT_PATH" --provider {RANDOM_PROVIDER_2} --json --mode {MODE}
```

Both run with `run_in_background: true`. Merge findings from both before applying fix policy. If one provider fails or times out, continue with the other.

**Flags per agent:**
- `--provider X` — one specific provider per agent (parallel, not sequential)
- `--json` — machine-readable for parsing
- `--mode` — set by calling skill

**Soft fail on bad JSON:** If the provider returns invalid JSON (markdown fences, trailing text, malformed output), do NOT fail the loop. Instead:
- Strip markdown fences (```json ... ```)
- Attempt to extract findings from raw text (look for SEVERITY: / FILE: / ISSUE: patterns)
- If still unparseable: treat entire output as `unstructured_output`, present raw text to user in the adversarial summary section, tag as `[RAW — provider returned non-standard output]`

### Step 3: Apply fix policy

```
For each finding:

  CRITICAL  ->  Fix immediately. No exceptions.
  
  WARNING   ->  Estimate fix size:
                  < 10 lines changed  ->  Fix immediately
                  >= 10 lines changed ->  Do NOT fix. Add to "known concerns" in output.
  
  INFO      ->  Do NOT fix. Add to "known concerns" in output.
```

### Step 4: Re-run after fixes (max 1 re-run)

If Step 3 fixed any CRITICAL or WARNING findings:

1. Stage fixes: `git add -A`
2. Re-run: dispatch 2 agents again (same as Step 2), merge results
3. If new CRITICAL: fix and STOP (no third iteration)
4. If only WARNING/INFO: add to known concerns, do not fix

**Hard limit: 2 total adversarial calls per task.** No third run. Prevents infinite loop.

### Step 5: Present to user

**Presentation policy — this determines what the user sees:**

| Unresolved findings | Presentation | Wording |
|---------------------|-------------|---------|
| No findings | Normal delivery | "complete" |
| Only INFO | Normal delivery | "complete" + known concerns section |
| Unresolved WARNING | Deliver with disclosure | "complete" + explicit WARNING list |
| Unresolved CRITICAL | **DO NOT present as "gotowe/complete"** | "implementation done, but adversarial review found unresolved critical issue(s)" |

**Output format:**

When findings were found and fixed:
```
[task description] complete
Adversarial review ([provider]): [N] issues found, [N] fixed
  Fixed:
  - [CRITICAL] [description] ([file]:[line])
  - [WARNING] [description] ([file]:[line])
  Known concerns (not fixed):
  - [WARNING] [description] -- requires architecture change
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

Valid skip reasons: `diff < 30 lines, no high-risk signals`, `config-only changes`, `no provider available`, `script timeout`

When provider returned bad output:
```
[task description] complete
Adversarial review ([provider]): [RAW -- provider returned non-standard output]
[raw text from provider]
```

---

## Integration Points

Each calling skill adds the adversarial loop at a specific phase.

### /build — after Phase 4 (implementation + tests passing)

```
Phase 4: Implementation complete, tests pass
  -> [ADVERSARIAL LOOP]
  -> Present results to user
```

Add to SKILL.md:
```markdown
### Adversarial Loop

Read and execute `{plugin_root}/shared/includes/adversarial-loop.md`.
Set ADVERSARIAL_MODE to "code" (or "security" if auth/payment/crypto signals detected in diff).
```

### /write-tests — after all tests written and passing

```
Tests written and passing
  -> [ADVERSARIAL LOOP --mode test]
  -> Present results to user
```

Add to SKILL.md:
```markdown
### Adversarial Loop

Read and execute `{plugin_root}/shared/includes/adversarial-loop.md`.
Set ADVERSARIAL_MODE to "test".
```

### /execute — after Step 7 (Phase 2 — not yet integrated)

```
Step 7: Quality review passes
  -> [ADVERSARIAL LOOP]
  -> Confidence gate
  -> Present results
```

### /write-e2e (Phase 2 — not yet integrated)

Same as /write-tests, ADVERSARIAL_MODE = "test".

### /refactor (Phase 2 — not yet integrated)

```
ETAP-2: Refactoring applied, tests pass
  -> [ADVERSARIAL LOOP]
  -> CQ audit agent
  -> Present results
```

---

## What This Is NOT

- **Not a replacement for zuvo:review** — this is a quick, single-provider check during writing. zuvo:review is a full multi-pass audit with confidence scoring, CQ evaluation, and multi-provider adversarial.
- **Not a quality gate** — adversarial loop does not block the skill from completing (except: unresolved CRITICAL changes the presentation wording). It finds and fixes what it can, notes the rest, and moves on.
- **Not recursive** — max 2 adversarial calls per task. The third opinion is zuvo:review's job.
- **Not proof of correctness** — "adversarial clean" means this specific model, at this moment, with this context window, found nothing. Different run, different model, different context = potentially different findings.
