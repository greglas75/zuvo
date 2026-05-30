# No-Pause Protocol

**Purpose:** Eliminate emergent mid-loop pauses. When a skill iterates over N items (tasks, files, findings, articles), it must process ALL of them in one run unless a hard blocker fires.

**Scope:** Any skill with a "for each X in list" loop — execute, build, refactor, ship, code-audit, security-audit, pentest, test-audit, write-article, content-expand, write-tests, fix-tests, content-fix, seo-fix, geo-fix.

---

## Hard Continuation Rule

After completing item N in a loop, the orchestrator MUST immediately start item N+1. The orchestrator MUST NOT:

- Estimate remaining wall-clock time ("21 × 15min = ~5h")
- Extrapolate session capacity ("this won't fit in one session")
- Present `(A) continue, (B) stop, (C) different scope` menus
- Ask "do you want me to continue?" / "should I proceed with the rest?"
- Pause "to be safe" because there are many items remaining
- Offer to "split into multiple sessions"
- Stop after the first item to "validate the approach" unless explicitly told to
- Wait for confirmation between items in the same approved batch

**Why:** The plan / scope / file list was already approved at the entry gate. That approval covers ALL items. Asking again is approval-gate fatigue and burns the user's time and tokens.

---

## Legitimate Stop Conditions (the ONLY ones)

Stop only when one of these fires:

1. **Hard gate failure** — `BLOCKED_*` state from the skill's own gate protocol (BLOCKED_PLAN_NOT_APPROVED, BLOCKED_TDD_PROTOCOL, BLOCKED_BRANCH_MISMATCH, BLOCKED_MISSING_GATE, BLOCKED_ADVERSARIAL_LOOP, etc.)
2. **All items processed** — terminal state reached (COMPLETED / SKIPPED / BLOCKED for every item)
3. **Explicit user interrupt** — user typed "stop", "pause", "wait", "halt", "wystarczy", "starczy", or pressed Ctrl+C in the current turn
4. **Runtime context pressure** — `/context` reports >85% usage, OR a context-compaction warning fired in this session. In that case: write session state, print resume instructions, exit. Do NOT ask the user — the runtime is the signal.
5. **Per-item retry exhausted** — same item hit its retry cap (e.g. 3 review iterations) with residual findings. Do **NOT** pause to ask the user `fix / accept / abort`. Apply the **Post-Cap Autonomous Disposition** below, record it loudly, and continue. The ONLY thing that halts the whole pipeline here is a genuinely *irreversible* action only the user can authorize (see (c)) — and even then you mark that ONE item BLOCKED and continue the rest, you do not stop and wait.

If none of these fired: keep going.

---

## Post-Cap Autonomous Disposition (replaces "surface to user, wait for decision")

When a per-item review loop (spec / quality / adversarial / acceptance) exhausts its cap and the reviewer still blocks, the orchestrator **decides and continues — it does not wake the user.** The plan was approved at the entry gate; resolving *how* the contract conforms is the agent's job, not a question for a sleeping user. This is one BOUNDED final action per item (apply / amend / defer), NOT a re-entry into the loop. Classify the residual and act:

**(a) Reviewer is objectively right and the fix is determinate** — the finding maps to an explicit plan/AC requirement (e.g. "AC9 requires per-question `source` provenance"; "spec types `meta: string`, code has object") and the corrective change is unambiguous. → Apply it as ONE final implementer pass, re-run tests/tsc/build, and on green **continue**. No further review loop — the fix was already agreed, re-litigating it is the waste. Record `[POST-CAP: FIXED] <task> <finding> → <change>`.

**(b) The spec/plan itself is wrong, impossible, or contradicts the codebase** — the reviewer is enforcing a contract that reality won't support (a column that isn't NOT NULL, an API that doesn't exist, a type the framework forbids). → **Amend the plan task's contract** to the correct shape, then continue. Record `[POST-CAP: SPEC-AMENDED] <task> <old → new> (reason)` in the artifact, `execution-state.md`, AND the Final Summary. The agent is explicitly authorized to fix the spec — that is what "let it fix the contract or the spec itself" means.

**(c) A genuine product / irreversible decision only a human can make** — choosing between two valid behaviors with real user-visible consequences, or an action that destroys data / breaks a published contract. → Pick the **safest reversible default**, persist the decision to the backlog with both options, record `[POST-CAP: DEFERRED] <task> <decision> default=<X> alt=<Y>`, and continue. HARD-stop the single item as `BLOCKED_*` ONLY if every path is destructive AND irreversible — then continue the REST of the plan; never halt the pipeline waiting on the user.

**Morning-review contract:** every `[POST-CAP: ...]` line MUST appear in the Final Summary so the user reviews all autonomous dispositions in one place when they return. Continue + document beats pause + wait — the user runs these overnight expecting to review, not to be paged. (This honors the standing `no-approval-gates` preference: skills execute and report; they do not gate on approval.)

A `fix / accept / abort` menu mid-run is now an ANTI-PATTERN for retry-exhaustion. The agent already knows the fix when it recommends one — applying it (a) or amending the spec (b) is the action, not the question.

---

## Sub-agent file-write integrity (check after a dispatched agent writes a file)

A dispatched sub-agent that writes/edits a file can occasionally emit a corrupt result — a NUL-byte / binary blob, a truncated half-write, or an empty file — instead of the intended text. Continuing the loop over a corrupted file silently propagates garbage. After a sub-agent reports a file write/edit, before treating that item as done, verify the file is well-formed text: it is non-empty, contains no NUL bytes (`grep -qP '\x00' <file>` must be FALSE / `file <file>` says text, not "data"), and parses for its language (tsc/py-compile/`node --check`/markdown headings intact). If corrupt: re-dispatch that ONE item once with an explicit "your previous write produced a binary/empty file, rewrite as plain UTF-8 text" note; if it corrupts again, mark that item BLOCKED with `BLOCKED_CORRUPT_WRITE` and continue the rest of the loop. Never commit or build on an unverified sub-agent write.

---

## What "going to the end" means

- 21 tasks → process all 21 (or until BLOCKED / context pressure)
- 47 audit findings → write all 47 fixes (subject to safety tier)
- 12 articles in batch → write all 12
- 8 files to refactor → refactor all 8

If you genuinely cannot finish (real BLOCKED, real context pressure), exit with:

```
[CONTINUATION HALTED]
reason: <BLOCKED_* | context-pressure | user-interrupt>
processed: <N of M>
remaining: <list of item IDs>
resume-with: <exact command to continue>
state-file: <path>
```

Do NOT halt with "I think this is enough for one session". That is not a valid reason.

---

## Anti-pattern Examples (DO NOT DO THIS)

```
❌ "Task 1 done. Extrapolating: 21 × 15min = ~5h. Want me to (A) continue, (B) stop here, (C) different scope?"
❌ "I've completed 3 of 12 articles. Should I continue with the rest?"
❌ "Let me pause here so you can review the first task before I proceed."
❌ "This is going to take a while. Want me to focus on just the critical ones?"
❌ "Stopping after Task 1 to validate the approach before continuing."
```

```
✅ "Task 1/21 COMPLETED. Starting Task 2/21."
✅ "Article 3/12 done. Article 4/12: <title>..."
✅ "Finding 7/47 fixed. Finding 8/47: <description>..."
```

---

## Loading

This protocol is loaded once at skill entry, before the iteration loop begins. Skills that include this file MUST honor it for the lifetime of the run. The loop continuation behavior is non-negotiable — it is the contract with the user.
