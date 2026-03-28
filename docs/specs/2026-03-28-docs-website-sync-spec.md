# Documentation & Website Consistency — Design Specification

**Status:** DRAFT
**Created:** 2026-03-28
**Scope:** Repo docs, GitHub README, zuvo.dev website, marketplace listing

---

## Problem Statement

Three documentation surfaces are out of sync:

1. **Repo docs** (`docs/`) — just updated with AP25-AP29, 40+ CQ patterns, new CodeSift tools, quality gates section
2. **Rules files** (`rules/`) — stale copies from toolkit, missing Semgrep/CodeSift/frequency-derived patterns added 2026-03-28
3. **Website** (zuvo.dev) — lacks concrete evidence, real examples, and the specificity that the product itself delivers

Additionally, Codex review identified structural gaps in the website that reduce credibility with technical users.

---

## D1: Rules Sync Strategy

**Decision:** Copy updated rules from `claude-code-toolkit/rules/` to `zuvo-plugin/rules/` on each release.

**Stale files (toolkit has newer versions):**

| File | Toolkit changes (2026-03-28) | Zuvo status |
|------|------------------------------|-------------|
| `cq-patterns.md` | +9 Semgrep patterns, +2 CodeSift patterns, +1 frequency pattern, +2 Docker patterns, strengthened Error narrowing + Config boundary | Stale (Mar 27) |
| `test-quality-rules.md` | +3 auto-fail entries (AP25, AP27, AP29) | Stale (Mar 27) |
| `react-nextjs.md` | +2 Semgrep patterns (postMessage, innerHTML) | Stale (Mar 27) |
| `nestjs.md` | +4 Semgrep patterns (dynamic require, FS paths, HTTPS, TLS) | Stale (Mar 27) |
| `python.md` | +3 Semgrep patterns (open redirect, defusedxml, credential logging) | Stale (Mar 27) |

**Not in zuvo-plugin but exists in toolkit:**
- `php-yii2.md` (+8 Semgrep patterns) — conditional rule, loaded by stack detection. Not bundled in zuvo currently.

**Testing.md** (test-patterns.md in toolkit = testing.md in zuvo): AP25, AP27-AP29 were added to toolkit's `test-patterns.md`. Need to check if zuvo's `testing.md` has the same AP table.

---

## D2: Website Restructure (from Codex Review)

### New sections to add

1. **"See real output"** — 4 screenshots or code snippets showing actual artifacts:
   - Brainstorm spec output (design dialogue + spec sections)
   - Plan task list (TDD tasks with exact code)
   - Execute review (quality reviewer CQ/Q scoring with evidence)
   - Backlog persistence (fingerprinted tech debt entry)

2. **"Start here"** — 3 user paths:
   - "I'm building a feature" → brainstorm/build
   - "I want an audit before release" → code-audit/security-audit/test-audit
   - "I want to fix test quality" → test-audit → fix-tests → write-tests

3. **Product anatomy** — one sentence:
   > Router → Skill → Agents → Artifact → Quality Gates → Backlog

4. **Platform status** — clear badges:
   - Claude Code: stable
   - Codex: experimental
   - Cursor: limited fallback (sequential only)

5. **"What is open-source vs paid"** — transparency section

6. **Real subpages or working links:**
   - Docs (→ GitHub docs/)
   - Changelog (→ GitHub releases)
   - Privacy policy
   - Discord/community

7. **"When NOT to use Zuvo"** — credibility builder:
   - One-line fixes (change a port, fix a typo)
   - Non-code tasks (writing emails, general questions)
   - Projects with <5 files (overhead > benefit)
   - Languages without rule support (Go, Rust — no bundled rules yet)

8. **Optional dependencies** block:
   - CodeSift MCP — deep code analysis (semantic search, call chains, complexity)
   - Chrome DevTools MCP — visual design review, accessibility audit
   - Sentry MCP — production error context for debug skill

### Fixes for existing content

1. **Agent count consistency** — standardize on "12 specialized agents: 10 pipeline + 2 quality reviewers" or break down by skill
2. **Footer commercial add-ons** — clarify or remove
3. **"Read the docs"** → actual deep links to specific doc pages
4. **Replace testimonials with concrete evidence:**
   - "Catches tenant scoping issues" (CQ4 defense-in-depth gate)
   - "Rejects fake passing tests" (Q17 input-echo detection, AP29)
   - "Persists medium-confidence findings" (backlog protocol, 26-50% confidence → tracked)
5. **Replace "33 vs 14 skills" comparison** with capability comparisons

### End-to-end example

Add one complete walkthrough showing:
```
User: "Add CSV export for survey results"
→ brainstorm (3 agents explore, design dialogue, spec output)
→ plan (architect + tech lead + QA, 6 TDD tasks)
→ execute (task 1: RED test, GREEN code, CQ eval, commit)
→ review catches: CQ6=0 (unbounded query), AP27 (vague assertion)
→ backlog: 2 items persisted for follow-up
```

---

## D3: README Alignment

README.md should be a concise entry point that matches the website. Current README is good but needs:

1. Agent count clarification (match website)
2. Link to changelog
3. Platform status badges or table

---

## D4: Marketplace Listing

After all changes, `release.sh` updates marketplace SHA automatically. No manual marketplace edits needed.

---

## Affected Files

### Repo (zuvo-plugin)
- `rules/cq-patterns.md` — sync from toolkit
- `rules/test-quality-rules.md` — sync from toolkit
- `rules/react-nextjs.md` — sync from toolkit
- `rules/nestjs.md` — sync from toolkit
- `rules/python.md` — sync from toolkit
- `README.md` — agent count, platform status, changelog link
- `docs/` — already updated (this session)

### External
- zuvo.dev website — restructure per D2
- zuvo-marketplace — auto-updated via release script

---

## Acceptance Criteria

1. All `rules/` files in zuvo-plugin match toolkit versions (byte-identical or zuvo-adapted)
2. `docs/` references (pattern counts, AP ranges, tool lists) match actual rules content
3. README agent count matches website and docs
4. Website has: real output section, start-here paths, product anatomy, platform status, when-not-to-use, optional deps, end-to-end example
5. All cross-references between docs resolve (no broken links)
6. `release.sh patch` succeeds and marketplace updates

---

## Out of Scope

- Adding new skills
- Changing skill behavior or quality gate thresholds
- PHP/Yii2 rules bundling (deferred — not enough PHP projects using zuvo yet)
- Cursor full support (separate effort)
