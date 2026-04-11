---
name: receive-review
description: >
  Process code review feedback with technical rigor. Activates when the user
  shares review comments, PR feedback, or asks to address reviewer suggestions.
---

# zuvo:receive-review

Protocol for responding to code review feedback. Every review comment gets the same structured treatment: understand it, verify it against the actual code, decide whether to fix or push back, then implement precisely.

## Mandatory File Reading

Before starting work, read each file below. Print the checklist with status.

```
CORE FILES LOADED:
  1. ../../shared/includes/run-logger.md       -- READ/MISSING
  2. ../../shared/includes/retrospective.md       -- READ/MISSING
  2. ../../shared/includes/knowledge-prime.md  -- READ/MISSING
  3. ../../shared/includes/knowledge-curate.md -- READ/MISSING
```

---

### Knowledge Prime

Run the knowledge prime protocol from `knowledge-prime.md`:
```
WORK_TYPE = "implementation"
WORK_KEYWORDS = <keywords from user request>
WORK_FILES = <files being touched>
```

---

## The 6-Step Protocol

Process each review item through all six steps before moving to the next item.

### Step 1: READ

Read the complete feedback without reacting. Do not start fixing anything.

- If the feedback is a PR comment thread, read every comment in the thread (not just the latest).
- If the feedback is a list, read the entire list before acting on any item.
- Identify each distinct action item. Number them for tracking.

Output:
```
Review items identified: N
1. [file:line] <one-line summary>
2. [file:line] <one-line summary>
...
```

### Step 2: UNDERSTAND

For each item, restate what the reviewer is asking for in your own words. This is not parroting -- it is demonstrating that the requirement is understood.

Ask yourself:
- What behavior does the reviewer want changed?
- What is the reviewer's underlying concern (correctness, performance, readability, security)?
- Is this a request for a specific change, or a question that needs answering?

If the intent is unclear after reading, ask the user for clarification BEFORE proceeding. Do not guess.

### Step 3: VERIFY

Read the actual code that the review comment refers to. Do not rely on memory or the reviewer's description of the code.

For each item:
1. Read the file at the referenced line.
2. Read surrounding context (the full function, the imports, the callers if relevant).
3. Determine the current behavior -- what does this code actually do right now?

This step exists because reviewers sometimes reference stale code, wrong line numbers, or misread the logic. Verify the premise before accepting the conclusion.

### Step 4: EVALUATE

For each item, make a technical judgment: fix or push back.

**Fix when:**
- The reviewer identified a real bug or correctness issue.
- The suggestion improves clarity without adding unnecessary complexity.
- The change aligns with the codebase's established patterns.
- The reviewer points out a missing edge case or error path.

**Push back when:**
- The suggestion breaks existing functionality (verify by tracing callers).
- The change violates YAGNI -- it adds abstraction for a scenario that does not exist.
- The reviewer's claim is technically incorrect for this language, framework, or version.
- The reviewer lacks full context about why the code is structured this way (e.g., a deliberate trade-off documented elsewhere).
- The suggestion conflicts with an architecture decision already made in this codebase.
- The suggestion duplicates logic that already exists elsewhere.

Pushing back is not disagreement for its own sake. It is protecting the codebase from well-intentioned changes that would make it worse. Every pushback must include a specific technical reason.

### Step 5: RESPOND

Formulate a response for each item. Two formats only.

**If fixing:**
```
Fixed. <What changed and why.>
```

Example: "Fixed. Added null check before accessing `user.profile` -- the query can return null when the user has been soft-deleted."

**If pushing back:**
```
Pushing back: <Technical reason with evidence.>
```

Example: "Pushing back: This endpoint intentionally returns 200 with an empty array instead of 404 because the frontend grid component treats 404 as a fatal error (see `DataGrid.tsx:47`). Changing to 404 would break the dashboard view."

#### Forbidden Responses

Do NOT use any of the following:
- "You're absolutely right!"
- "Great point!"
- "Good catch!"
- "Thanks for the feedback!"
- "Totally agree!"
- Any form of gratitude or performative agreement before the fix.

These phrases signal compliance, not comprehension. The response must demonstrate that the code was read, the concern was understood, and the fix was verified -- not that the reviewer's ego was stroked.

Conversely, do NOT be combative. "Pushing back" is a neutral technical statement, not an argument. If the user or reviewer disagrees with the pushback, re-evaluate with the new information they provide.

### Step 6: IMPLEMENT

Execute fixes one item at a time. After each fix:

1. Make the change.
2. Run affected tests. If no specific tests exist for the changed code, run the full test suite.
3. Verify the fix addresses the reviewer's concern -- re-read the comment and confirm the new code satisfies it.
4. If the fix introduces a test gap (new branch, new error path), write a test for it.
5. Move to the next item.

Do NOT batch all fixes into one large change. Sequential, verified fixes prevent cascading errors where fix #3 breaks what fix #1 corrected.

### Adversarial Review (MANDATORY — do NOT skip)

After all items are implemented:

```bash
git add -u && git diff --staged | adversarial-review --mode code
```

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Wait for complete output. Handle findings by severity:
- **CRITICAL** — fix immediately, regardless of confidence. If confidence is low, verify first (check the code), then fix if confirmed.
- **WARNING** — fix if localized (< 10 lines). If fix is larger, add to backlog with specific file:line.
- **INFO** — known concerns (max 3, one line each).

Do NOT discard findings based on confidence alone. Confidence measures how sure the reviewer is, not how important the issue is. A CRITICAL with low confidence means "verify this — if true, it's serious."

"Pre-existing" is NOT a reason to skip a finding. If the issue is in a file you are already editing, fix it now. If not, add it to backlog with file:line. The adversarial review found a real problem — don't dismiss it just because it existed before your changes.

---

## Source-Specific Handling

The source of the feedback affects trust calibration but not the protocol. All items still go through all six steps.

### From the User (Direct Feedback)

Trust level: **high**. The user knows their codebase and their intent.

- Implement after understanding. Do not second-guess unless something is technically impossible.
- If the request is unclear, ask. Do not interpret ambiguity as permission to improvise.
- If the user asks for something that would break tests, say so and propose an alternative, but defer to the user's decision.

### From External Reviewers (PR Comments, Team Members)

Trust level: **standard**. The reviewer may not have full context.

- Verify every factual claim against the actual code.
- Check whether the suggested change breaks any callers or dependents.
- Consider whether the reviewer is seeing a different version of the code (stale diff).
- If the suggestion is valid but incomplete (e.g., "add validation here" without specifying what validation), fill in the details based on codebase patterns and report what was added.

### From Automated Tools (Linters, SAST, AI Reviewers)

Trust level: **skeptical**. Automated tools produce false positives.

- Verify every finding against the actual code. Automated tools flag patterns, not bugs -- the pattern may be intentional.
- Check if the flagged code is covered by tests that prove correctness.
- For security findings: take seriously, but verify the attack vector is reachable in this specific application (not just theoretically possible).
- For style findings: only fix if the project has adopted the rule. Do not enforce rules the team has not agreed to.
- For AI reviewer suggestions: treat as hypotheses, not instructions. AI reviewers hallucinate context, misread control flow, and suggest fixes that break invariants. Verify everything.

---

## Ordering

When the review contains multiple items, process them in this order:

1. **Correctness bugs** -- anything that produces wrong results.
2. **Security issues** -- anything that exposes data or enables unauthorized access.
3. **Error handling gaps** -- missing catches, swallowed errors, unhandled edge cases.
4. **API contract issues** -- wrong status codes, missing fields, broken pagination.
5. **Performance concerns** -- N+1 queries, unbounded fetches, missing indexes.
6. **Code clarity** -- naming, structure, documentation.

This ordering ensures that if the review is partially addressed (e.g., user says "enough for now"), the most critical items were handled first.

---

## Knowledge Curation

After work is complete, run the knowledge curation protocol from `knowledge-curate.md`:
```
WORK_TYPE = "implementation"
CALLER = "zuvo:receive-review"
REFERENCE = <git SHA or relevant identifier>
```

---

## Completion

After all items are processed, produce a summary:

```
Review complete. N items processed.

Fixed:
  1. [file:line] <what changed>
  2. [file:line] <what changed>

Pushed back:
  3. [file:line] <reason>

Tests: N passing, 0 failing.
Run: <ISO-8601-Z>	receive-review	<project>	-	-	<VERDICT>	-	<DURATION>	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
```


### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

`<DURATION>`: use `N-comments` (number of review items processed).

If any fix introduced new tests, list them separately:

```
New tests added:
  - <test file>: <test name>
```
