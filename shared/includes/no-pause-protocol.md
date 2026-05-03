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
5. **Per-item retry exhausted** — same item failed N times (per the skill's own retry limit, e.g. 3 adversarial iterations). Surface to user with the standard 3 options (context / skip / abort), then continue with next item if user says skip.

If none of these fired: keep going.

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
