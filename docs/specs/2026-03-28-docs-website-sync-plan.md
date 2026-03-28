# Implementation Plan: Documentation & Website Consistency

**Spec:** docs/specs/2026-03-28-docs-website-sync-spec.md
**Created:** 2026-03-28
**Revised:** 2026-03-28 (P1 fixes from Codex review)
**Tasks:** 10
**Estimated complexity:** 7 standard, 3 complex (cherry-pick + website content)

## Architecture Summary

Three documentation surfaces to sync: repo files (rules/ + docs/), GitHub README, and zuvo.dev website. Repo docs were updated earlier in this session. New patterns (from Semgrep/CodeSift/frequency analysis) need to be added to zuvo's rules files, which have their own framing and style.

Data flow: `zuvo-plugin/rules/` (authoritative) → `zuvo-plugin/docs/` → `README.md` → `zuvo.dev` → `zuvo-marketplace`

## Technical Decisions

- **Rules sync:** Zuvo rules/ is the source of truth. New patterns (identified during this session's Semgrep/CodeSift/frequency analysis) are added directly to the zuvo-adapted files. No upstream dependency.
- **Website:** Content changes only. All claims backed by existing repo artifacts. No synthetic examples. No invented numbers.
- **Agent count:** 11 dispatched agents + 1 main-agent synthesis role across 3 pipeline skills: brainstorm(4 dispatched: code-explorer, domain-researcher, business-analyst, spec-reviewer), plan(3 dispatched: architect, tech-lead, qa-engineer + 1 dispatched: plan-reviewer + team-lead as main-agent instructions), execute(3 dispatched: implementer, quality-reviewer, spec-reviewer).
- **Verification:** `grep` for pattern presence in zuvo files, content audit for docs, visual review for website.
- **Release timing:** Release covers repo changes only. Website is deployed separately — release does NOT claim website consistency.

## Quality Strategy

- No CQ gates active (no production code)
- Verification = content correctness: pattern counts match, AP ranges match, cross-references resolve
- Risk 1: website diverges from repo truth — mitigate by using ONLY existing artifacts (codex-compatibility-spec.md, codex-compatibility-plan.md)
- Risk 2: cherry-pick misses context — mitigate by diffing each file and reviewing zuvo framing before editing
- **Rule: no invented proof.** Every number, example, and screenshot on the website must trace to an existing file in the repo.

---

## Task Breakdown

### Task 1: Add new patterns to rules/cq-patterns.md

**Files:** `rules/cq-patterns.md`
**Complexity:** complex (must preserve zuvo framing)
**Dependencies:** none

- [ ] Add these NEW pattern sections at end of file, written in zuvo style ("Defensive Code Patterns" framing):
  - Semgrep-derived: Secrets, Path traversal, Non-literal RegExp, Prototype pollution, GCM authTag, SRI, Child process
  - CodeSift-derived: `as any` bypass, console.log in production, Throw consistency
  - Docker: Dockerfile USER, drop privileges
  - Strengthened: Error narrowing (add naming convention note), Config boundary (add scattered env example)
- [ ] Verify: `grep -c "### " rules/cq-patterns.md` — count should increase by ~14
- [ ] Verify: `head -3 rules/cq-patterns.md` — still says "Defensive Code Patterns"
- [ ] Commit: `docs: add 14 Semgrep/CodeSift/frequency-derived patterns to cq-patterns.md`

---

### Task 2: Add AP25/AP27/AP29 to rules/test-quality-rules.md

**Files:** `rules/test-quality-rules.md`
**Complexity:** standard
**Dependencies:** none

- [ ] Add 3 new auto-fail entries to the auto-fail patterns table (in zuvo "Test Quality Standards" style):
  - AP25: `expect(x.length).toBe(N)` instead of `.toHaveLength(N)` (Q4)
  - AP27: `expect(x.length).toBeGreaterThan(0)` when fixture count known (Q4, Q15)
  - AP29: Mock return value echoed in assertion (Q17)
- [ ] Verify: `grep -c "AP25\|AP27\|AP29" rules/test-quality-rules.md` — expected: 3+ matches
- [ ] Verify: `head -1 rules/test-quality-rules.md` — still says "Test Quality Standards"
- [ ] Commit: `docs: add AP25/AP27/AP29 auto-fail entries to test-quality-rules.md`

---

### Task 3: Add Semgrep patterns to stack-specific rules

**Files:** `rules/react-nextjs.md`, `rules/nestjs.md`, `rules/python.md`
**Complexity:** complex (3 files, each with its own framing)
**Dependencies:** none

For each file, add new pattern sections in zuvo style:
- [ ] `react-nextjs.md`: Add postMessage origin, innerHTML via DOM
- [ ] `nestjs.md`: Add Dynamic require, FS dynamic paths, HTTPS, TLS bypass
- [ ] `python.md`: Add Open redirect (Flask), defusedxml, credential logging
- [ ] Verify: `grep "Semgrep" rules/react-nextjs.md rules/nestjs.md rules/python.md` — each should have section header
- [ ] Verify: first heading of each file preserved (zuvo titles)
- [ ] Commit: `docs: add Semgrep-derived patterns to react/nestjs/python rules`

---

### Task 4: Add AP25-AP29 to rules/testing.md

**Files:** `rules/testing.md`
**Complexity:** standard
**Dependencies:** none

- [ ] Reference: the AP definitions (AP25, AP27, AP28, AP29) are documented in the spec and plan for this task
- [ ] Compare: check zuvo's `rules/testing.md` AP deductions table for existing entries
- [ ] Add missing entries: AP25, AP27, AP28, AP29 (adapted to zuvo style)
- [ ] Add Red Flags entries: mock-to-assertion ratio, CalledWith ratio, cross-file correlation, AP29 input echo
- [ ] Verify: `grep -c "AP25\|AP27\|AP28\|AP29" rules/testing.md` — expected: 4+ matches
- [ ] Commit: `docs: add AP25-AP29 to testing.md anti-pattern table + Red Flags`

---

### Task 5: README alignment

**Files:** `README.md`
**Complexity:** standard
**Dependencies:** Task 1-4 (rules must be synced first so counts are accurate)

- [ ] Fix agent count: "11 dispatched agents + 1 main-agent synthesis role across brainstorm, plan, and execute"
- [ ] Add platform status after "What's inside" section:
  ```markdown
  ## Platform support

  | Platform | Status |
  |----------|--------|
  | Claude Code | Stable |
  | Codex | Experimental |
  | Cursor | Limited (sequential fallback) |
  ```
- [ ] Add changelog link to Documentation section
- [ ] Verify: `grep "11 dispatched" README.md && grep "Changelog" README.md && grep "Experimental" README.md`
- [ ] Commit: `docs: README — fix agent count, add platform status, changelog link`

---

### Task 6: Website — "See real output" from EXISTING artifacts

**Files:** zuvo.dev content (external)
**Complexity:** standard
**Dependencies:** none

**Rule: every snippet must come from a real file in the repo. No synthetic examples.**

Extract from existing artifacts:

1. **Brainstorm spec snippet** — from `docs/specs/2026-03-27-codex-compatibility-spec.md`:
   - Show design decision D1 (verbatim, trimmed)
   - Show 2 acceptance criteria (verbatim)

2. **Plan task snippet** — from `docs/specs/2026-03-27-codex-compatibility-plan.md`:
   - Show 1 complete task (verbatim, trimmed)

3. **Quality gate definition** — from `rules/cq-checklist.md` or `docs/quality-gates.md`:
   - Show CQ4 (auth + query filter) gate definition with scoring
   - Show Q17 (input-echo) gate definition
   - These are RULE definitions, not synthetic review findings

4. **Backlog protocol** — from `shared/includes/backlog-protocol.md`:
   - Show the fingerprinting format (verbatim)
   - Show confidence routing table (verbatim)

- [ ] Verify: Every snippet has a `Source: <file>:<line>` attribution
- [ ] Note: No screenshots of "runs" that haven't happened. Show the RULES and ARTIFACTS, not invented outputs.

---

### Task 7: Website — "Start here" paths + product anatomy + honesty sections

**Files:** zuvo.dev content (external)
**Complexity:** standard
**Dependencies:** none

- [ ] Write 3 user paths (these describe skill routing, which IS in the repo):
  ```
  Building a feature?
    → zuvo:brainstorm → zuvo:plan → zuvo:execute
  Audit before release?
    → zuvo:code-audit + zuvo:security-audit + zuvo:test-audit
  Fixing test quality?
    → zuvo:test-audit → zuvo:fix-tests → zuvo:write-tests
  ```

- [ ] Write product anatomy one-liner:
  > Router → Skill → Agents → Artifact → Quality Gates → Backlog

- [ ] Write "When NOT to use Zuvo":
  - One-line fixes — just do it directly
  - Non-code tasks — your coding agent handles these natively
  - Projects under 5 files — overhead exceeds benefit
  - Go, Rust, Java — no bundled rules yet

- [ ] Write optional dependencies block:
  - CodeSift MCP — "better with, works without"
  - Chrome DevTools MCP — visual review, a11y
  - Sentry MCP — production error context

---

### Task 8: Website — Comparison by failure mode (real examples only)

**Files:** zuvo.dev content (external)
**Complexity:** standard
**Dependencies:** Task 6

**Replace "33 vs 14 skills" with failure-mode comparisons using verifiable claims:**

- [ ] CQ4 (tenant scoping): "CQ4 gate requires both auth guard AND query-level orgId filter. Guard alone = FAIL." — This is the CQ4 definition in `rules/cq-checklist.md`. Verifiable.
- [ ] Q17 (input echo): "Q17 detects when a test asserts the same value it set in the mock." — This is the Q17 definition in `rules/testing.md`. Verifiable.
- [ ] Backlog persistence: "Findings between 26-50% confidence go to backlog, not trash." — This is in `shared/includes/backlog-protocol.md`. Verifiable.
- [ ] **Do NOT claim "found in 8/45 repos" or "500+ instances" unless linking to the actual scan data.** If scan data isn't published, don't cite it.

- [ ] Write end-to-end structure showing the PIPELINE SHAPE (what each phase produces), not a synthetic run:
  ```
  brainstorm → spec document (design decisions, acceptance criteria)
  plan → task list (TDD steps with exact code, verification commands)
  execute → reviewed code (CQ/Q scores, evidence, commit per task)
  review → findings (tiered: MUST-FIX / RECOMMENDED / NIT, with file:line)
  ```

---

### Task 9: Website — Structural fixes

**Files:** zuvo.dev content (external)
**Complexity:** standard
**Dependencies:** Task 6, 7, 8

- [ ] Fix agent count everywhere: "11 dispatched agents + 1 main-agent synthesis role" with per-skill breakdown (brainstorm 4, plan 4 dispatched + team-lead instructions, execute 3)
- [ ] Clarify "commercial add-ons": if nothing is paid, state "100% open-source, MIT licensed." If there IS a commercial plan, describe it honestly.
- [ ] Replace "Read the docs" with deep links to specific pages
- [ ] Add working links: changelog (GitHub releases), privacy, community
- [ ] Platform status: Claude Code (stable), Codex (experimental), Cursor (limited)

---

### Task 10: Release repo changes (repo only, NOT website)

**Files:** `package.json`, `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`
**Complexity:** standard
**Dependencies:** Task 1-5 (all repo changes committed)

- [ ] Run: `./scripts/release.sh patch`
- [ ] Verify: `git tag --list | tail -1` shows new version tag
- [ ] Verify: marketplace repo has updated SHA
- [ ] **Note: This release covers repo changes only. Website (Tasks 6-9) is a separate deploy. Release does NOT claim website is updated.**

---

## Execution Order

```
Parallel group A (repo):     Tasks 1, 2, 3, 4 (independent rule cherry-picks)
Sequential after A:          Task 5 (README, needs accurate counts)
Sequential after 5:          Task 10 (release — repo only)

Parallel group B (website):  Tasks 6, 7 (independent content creation)
Sequential after B:          Task 8 (comparison, uses Task 6 artifacts)
Sequential after 8:          Task 9 (structural fixes, needs all content)
```

Groups A and B can run in parallel. Group B does NOT block release.

---

## Review Fixes Applied (from Codex P1/P2 feedback)

| Finding | Fix |
|---------|-----|
| P1: Wrong agent breakdown ("10 + 2 design-team") | R1: "12 pipeline agents" → R2: "11 dispatched + 1 main-agent role" (team-lead is instructions, not spawned) |
| P1: Synthetic examples and unverified numbers | Fixed: All snippets from existing repo files. No invented data. Scan numbers only if scan data is published. |
| P1: Blind `cp` destroys zuvo-adapted framing | R1: cherry-pick → R2: write directly into zuvo files (no upstream dependency) |
| P1: toolkit as upstream source of truth | Fixed R2: Zuvo rules/ is authoritative. No data flow from external repo. |
| P2: Wrong upstream path for test-patterns.md | Fixed: AP definitions taken from spec/plan, not external file. |
| P2: Release before website | Fixed: Release is repo-only. Website is separate deploy, explicitly decoupled. |
| P2: "Claude handles natively" (platform-specific) | Fixed: "your coding agent handles these natively" (platform-neutral) |
