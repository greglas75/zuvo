# Adversarial Loop

> **Protocol spec** for the adversarial review contract. Skills implement this protocol inline via `adversarial-review` bash calls — they do NOT load this file at runtime. This file documents the contract for reference and maintenance.
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
git diff --staged | adversarial-review --json --artifact /tmp/adv-pass1.json --mode {MODE}
```

Default is multi-provider (all available run in parallel). The script handles provider detection and dispatch.

**Capture full output before triage — NEVER pipe through `tail`/`head`.** Multi-provider output exceeds one screen; `tail`/`head` silently truncates the first providers (codex, gemini) and drops their CRITICAL findings (two documented loss-of-finding incidents). Use the `--artifact <path>` flag (or redirect `... > /tmp/adv-passN.txt 2>&1`) and triage from the full file/variable. Prefer `--artifact` — it is a real script flag that also records metadata for downstream gates.

**If staged diff doesn't reflect the skill's changes** (e.g., skill worked on explicit files, not staged): use `--files` instead:
```bash
adversarial-review --json --mode {MODE} --files "path/to/changed/file.ts"
```

**IMPORTANT:** Run as foreground Bash call. Wait for complete output before proceeding. Do NOT use background execution.

**If `adversarial-review` is not in PATH**, use the platform-specific fallback:

| Platform | Fallback path |
|----------|---------------|
| Claude Code | `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh` |
| Codex | `~/.codex/scripts/adversarial-review.sh` |
| Antigravity | `~/.gemini/antigravity/scripts/adversarial-review.sh` |
| Cursor | `~/.cursor/scripts/adversarial-review.sh` |

**Host auto-exclusion:** The script auto-detects which IDE/CLI is the host (via `CLAUDECODE`, `CODEX_SANDBOX`, `VSCODE_GIT_ASKPASS_MAIN`) and excludes the host's provider from review. This prevents self-review (e.g., Gemini reviewing Gemini's work inside Antigravity). Override with explicit `--exclude` or `--provider`.

**If the script exits non-zero with empty output:** note `adversarial review: skipped (no provider available)` and proceed.

**If output is not valid JSON:** treat as raw text findings. Do NOT try to parse severity programmatically from prose. Present raw text in the adversarial section. Do NOT auto-fix based on unstructured output.

### Step 3: Meta-review check

```
IF findings == 0 AND diff_lines > 150:
  Add to output: "⚠ Adversarial returned clean on 150+ line diff — possible false negative. Consider running zuvo:review for thorough multi-provider check."
```

### Step 3b: Partial / single-provider handling (D2 + D3)

The script may return a non-clean `status` when not all requested providers ran. Branch on it explicitly. Notable: `status: "partial"` with exit 0 means *some* providers succeeded and *some* timed out or failed — surface the `timeout_count` field to the user. `single_provider_only` produces exit code 3 (distinct from exit code 124 = all-timeout, exit 2 = all-failed, exit 1 = no provider available).

| JSON `status` | Exit code | Meaning | Caller action |
|---------------|-----------|---------|---------------|
| `ok` | 0 | All requested providers succeeded | normal delivery |
| `partial` | 0 | Some succeeded, some timed out or failed (`timeout_count > 0` or `provider_count < attempted_count`) | continue, but surface `timeout_count` + `provider_count` in user-visible output so they know coverage was reduced |
| `timeout` | 124 | ALL providers timed out (`provider_count == 0`, `timeout_count == attempted_count`) — exit code 124 distinguishes total timeout from partial | record `Adversarial review: skipped (timeout)` and continue — do NOT retry inline |
| `single_provider_only` | 3 | `--multi` or `--rotate` requested but post-exclusion provider count < 2 — exit code 3 is unique to this case | install a second provider, retry with `--single`, or pass `--provider <name>` explicitly |
| `error` | 2 | All providers failed (non-timeout) | record `Adversarial review: skipped (provider error)` and continue |

**Cross-call rotation pattern** (D4 — for skills that invoke `adversarial-review` multiple times in the same flow):

```bash
# Pass 1 — capture to a per-pass artifact; never pipe through tail/head
out1=$(adversarial-review --rotate --json --artifact /tmp/adv-pass1.json --files "$ARTIFACT")
last_provider=$(jq -r '.providers_used_list[0] // .providers_used' <<<"$out1")

# Pass 2 — exclude last to force a different provider, distinct artifact
out2=$(adversarial-review --rotate --exclude-last "$last_provider" --json --artifact /tmp/adv-pass2.json --files "$ARTIFACT")
```

If only 1 provider remains after the exclusion, pass 2 will exit 3 (`single_provider_only`) — caller chooses whether to fall back to `--single` or accept single-perspective results.

### Step 4: Evidence validation

#### Step 4.0: Known false-positive classes (verify-then-dismiss, do NOT churn the diff)

These FP classes recur from CLI/provider artifacts and cost a turn each if treated as real. For each,
do the ONE-LINE verification and dismiss if confirmed FP — do not apply a fix, do not loop:

| FP class | Symptom | One-line verification → dismiss |
|----------|---------|--------------------------------|
| **CLI-token mangling** | A provider (notably `gemini`) reports a "hallucinated/invalid file path" CRITICAL where the "path" is actually an email, `user@host`, URL, or `@`-decorator token in the diff | Check the cited token in the diff: if it's an `@`-token / email / host, not a real path → `FP: CLI @-token mangling`. |
| **Markdown-regex balance** | "Unbalanced parens / stray lookaround / broken regex" on a regex inside a **markdown table cell** (`\\(`, `\|` double-escaped for the table) | Extract the real regex (unescape `\|`→`|`, `\\(`→`\(`) and `python3 -c 'import re; re.compile(r"…")'`. Compiles → `FP: markdown double-escape miscount`. |
| **Type-system-disproven** | "May be null/falsy/0/undefined" on a value a declared type forbids (e.g. a string-union can't be `0`; a non-optional field can't be `undefined`) | Confirm the declared type; if it excludes the claimed value → `FP: type-disproven`. |
| **Already-a-fact** | Re-raises a settled fact (lockfile present, bundled types, file already patched at HEAD) | Confirm against the `FACTS:` block / current tree → `FP: settled-fact`. |

Record each dismissal as a one-line `FP: <class> — <token/evidence>` in the output; these do NOT
count toward the known-concerns limit and do NOT block the verdict. **Verify before dismissing** —
an unverified "probably FP" is not a dismissal, it's a skipped finding.

Before applying any fix policy, validate each remaining finding for mandatory evidence.

**Every CRITICAL or WARNING finding MUST include:**
- `file:line` — exact file path and line number where the issue occurs
- A description that references the specific code or behavior (not just "this looks wrong")

```
IF finding.severity in [CRITICAL, WARNING]:
  IF finding has no file:line reference:
    Downgrade to INFO
    Annotate: "(downgraded: no file:line evidence — cannot action)"
```

**Rationale:** Vague findings without evidence cannot be verified, fixed, or explained to the user. A finding that says "authentication looks insecure" with no location is unfixable. A finding that says "auth/token.ts:47 — JWT secret is hardcoded as a string literal, violates no-hardcoded-secrets" is actionable.

After validation, apply fix policy:

```
For each finding:

  CRITICAL  ->  Fix immediately. No exceptions.
               Output: [CRITICAL] <description> (<file>:<line>)

  WARNING   ->  Is the fix < 10 lines AND localized (same file, no cross-file impact)?
                  YES  ->  Fix immediately
                  NO   ->  Do NOT fix. Add to "known concerns."
               Output: [WARNING] <description> (<file>:<line>) — <fix-or-not reason>

  INFO      ->  Do NOT fix. Add to "known concerns."
               Output: [INFO] <description> (<file>:<line> or "general")
```

**Known concerns limit:** Max 3 items, one line each, highest severity first. If more than 3, keep top 3 and note "(N more omitted)".

### Step 5: Validation re-run (max 1)

If Step 4 fixed any CRITICAL or WARNING:

1. Stage fixes: `git add -u`
2. Re-run: `git diff --staged | adversarial-review --json --mode {MODE}`
3. **This is a validation run, NOT a new repair cycle.** If new issues found:
   - **False-re-raise check FIRST.** If a re-flagged CRITICAL is the SAME issue you just fixed
     (same `file:line` + same root cause) and you can prove the fix holds (the regression test for
     it passes / the changed code is present at HEAD), it is a **false-re-raise, NOT non-convergence**:
     dispose `[POST-CAP: FIXED] false-re-raise — <file:line>, verified by <test/evidence>` and STOP
     cleanly. Do NOT count it toward the retry cap, do NOT re-fix, do NOT flip the verdict to BLOCKED.
     A provider re-stating an already-fixed finding is noise; the test is ground truth.
   - New CRITICAL (genuinely distinct from what you fixed) → add to known concerns, STOP. Do NOT attempt another fix.
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
Adversarial review ([provider]): [N] issues found, [N] fixed ([N] downgraded for missing evidence)
  Fixed:
  - [CRITICAL] <description> (<file>:<line>)
  - [WARNING]  <description> (<file>:<line>) — fixed (< 10 lines, localized)
  Known concerns (not fixed):
  - [WARNING]  <description> (<file>:<line>) — non-local fix
  - [INFO]     <description> (<file>:<line> or "general")
  Downgraded (no evidence):
  - [INFO↓]    <original description> — no file:line provided
```

Every finding in Fixed and Known concerns **must** include `(<file>:<line>)`. No exceptions. If the provider returns a finding without a location, it is downgraded and listed in the Downgraded section — it does NOT block or trigger fixes.

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

- **Not a replacement for zuvo:review** — this is a quick multi-provider check during writing. zuvo:review is a full multi-pass audit with confidence scoring.
- **Not a quality gate** — does not block completion (except: unresolved CRITICAL changes wording).
- **Not recursive** — max 2 calls. Third opinion is zuvo:review's job.
- **Not proof of correctness** — "clean pass" means one model found nothing. Different model = potentially different findings.
- **Not optional** — if referenced by a skill, it runs. The agent does not skip it.
