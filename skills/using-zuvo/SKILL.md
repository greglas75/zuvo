---
name: using-zuvo
description: "ALWAYS LOADED — Zuvo skill router. Injected at session start. Determines which zuvo skill to invoke for the current task."
---

> **Zuvo v1.3.38** | 51 skills | 4 adversarial providers | CQ1-CQ28 + Q1-Q19

# Zuvo Skill Router

You have access to the Zuvo skill ecosystem. Before acting on any user request, check the routing table below. If a skill matches, invoke it using the Skill tool. Do not implement the task yourself when a skill exists for it.

**If the user asks "zuvo version", "what version", or "which zuvo"** — print the version banner above and stop. Do not invoke any skill.

## How Routing Works

1. Read the user's message
2. Match intent against the routing table
3. If a skill matches, invoke it: `Skill(skill="zuvo:<name>")`
4. If no skill matches, proceed normally

Do this on every message. Not just the first one.

---

## Routing Table

### Priority 1 — Pipeline (multi-file features)

| User intent | Skill | Notes |
|-------------|-------|-------|
| Build a feature, add major functionality, implement a design | `zuvo:brainstorm` | Start here for anything touching 5+ files or requiring design decisions |
| Plan implementation tasks | `zuvo:plan` | Uses spec from `docs/specs/*-spec.md` if available, otherwise plans from user description |
| Continue from approved plan | `zuvo:execute` | Requires plan artifact in `docs/specs/*-plan.md` |

**Pipeline order is recommended but not mandatory.** `brainstorm` produces a spec. `plan` works best with a spec but also accepts a direct description. `execute` requires a plan. If the user says "plan this" without a spec, `plan` runs in inline mode. If they say "build this feature" and it's large (5+ files), suggest `brainstorm` first but don't block.

### Priority 2 — Task (scoped work)

| User intent | Skill |
|-------------|-------|
| Build a small feature (1-5 files, clear scope) | `zuvo:build` |
| Fix a bug, investigate an error, diagnose a problem | `zuvo:debug` |
| Refactor, extract, split, move, rename, simplify | `zuvo:refactor` |
| Review code, check changes, audit a PR | `zuvo:review` |
| Write unit/integration tests for existing code | `zuvo:write-tests` |
| Write end-to-end tests (Playwright) | `zuvo:write-e2e` |
| Fix systematic test anti-patterns across files | `zuvo:fix-tests` |
| Fix SEO audit findings, apply SEO fixes | `zuvo:seo-fix` |
| Fix GEO issues — fix schema, fix llms.txt, apply GEO fixes | `zuvo:geo-fix` |
| Fix content audit findings (encoding, markdown, artifacts) | `zuvo:content-fix` |
| Write an article, blog post, generate content from scratch | `zuvo:write-article` |
| Audit accessibility, WCAG compliance, keyboard navigation, screen reader, ADA, contrast | `zuvo:a11y-audit` |

### Priority 3 — Audit (analysis and reporting)

| User intent | Skill |
|-------------|-------|
| Audit code quality | `zuvo:code-audit` |
| Audit test quality | `zuvo:test-audit` |
| Audit API endpoints | `zuvo:api-audit` |
| Audit security (OWASP, auth, secrets) | `zuvo:security-audit` |
| Run penetration test | `zuvo:pentest` |
| Audit performance | `zuvo:performance-audit` |
| Audit database (queries, schema, indexes) | `zuvo:db-audit` |
| Audit dependencies (outdated, vulnerable, unused) | `zuvo:dependency-audit` |
| Audit CI/CD pipelines | `zuvo:ci-audit` |
| Audit environment config and secrets | `zuvo:env-audit` |
| Audit SEO and structured data | `zuvo:seo-audit` |
| GEO readiness audit — AI citation optimization, llms.txt, schema graph, generative engine visibility | `zuvo:geo-audit` |
| Audit content quality (encoding, links, formatting, CMS artifacts) | `zuvo:content-audit` |
| Optimize existing article, improve content quality, score content | `zuvo:content-optimize` |
| Compare old CMS page with new SSG page, fix parity gaps | `zuvo:content-migration` |
| Audit codebase structure and organization | `zuvo:structure-audit` |
| Review architecture, create ADR | `zuvo:architecture` |
| Review UI/UX consistency, visual design quality, component patterns | `zuvo:design-review` |
| Design new UI (components, layouts, systems) | `zuvo:design` |
| UI design with multi-agent team | `zuvo:ui-design-team` |
| Optimize test suite speed | `zuvo:tests-performance` |
| Run mutation testing (verify tests actually catch bugs) | `zuvo:mutation-test` |
| _(see Priority 2)_ | `zuvo:a11y-audit` |
| Benchmark providers, compare models, measure quality/speed/cost | `zuvo:benchmark` |
| Self-benchmark: YOU write code+tests, adversarial reviews, you fix — measures YOUR quality | `zuvo:agent-benchmark` |

### Priority 4 — Utility

| User intent | Skill |
|-------------|-------|
| View or manage tech debt backlog | `zuvo:backlog` |
| Write documentation | `zuvo:docs` |
| Create a presentation | `zuvo:presentation` |
| Respond to code review feedback | `zuvo:receive-review` |
| Isolate work in a git worktree | `zuvo:worktree` |
| Incident response, postmortem, root cause analysis | `zuvo:incident` |

### Priority 5 — Release (post-code lifecycle)

| User intent | Skill |
|-------------|-------|
| Ship a release, push code, create PR, bump version | `zuvo:ship` |
| Deploy to production, merge PR, verify health | `zuvo:deploy` |
| Monitor production after deploy, check for regressions | `zuvo:canary` |
| Sync documentation with a release | `zuvo:release-docs` |
| Engineering retrospective, shipping velocity | `zuvo:retro` |

---

## Pipeline Enforcement

```
zuvo:brainstorm  -->  spec document   -->  zuvo:plan
zuvo:plan        -->  plan document   -->  zuvo:execute
```

- `zuvo:brainstorm` produces `docs/specs/YYYY-MM-DD-<topic>-spec.md`
- `zuvo:plan` uses a spec if available, otherwise plans from user description (inline mode).
- `zuvo:execute` requires a plan. If none exists, redirect to `zuvo:plan`.
- Each downstream skill checks for its prerequisite artifact automatically.
- The user can pass an artifact path explicitly: `zuvo:plan docs/specs/my-spec.md`

### When to use pipeline vs task skills

- **Pipeline** (`brainstorm` -> `plan` -> `execute`): The work requires design decisions, touches many files, or the scope is unclear. The user says things like "build a feature", "implement this design", "add a new module".
- **Task** (`build`, `debug`, `refactor`, etc.): The scope is clear and bounded. The user says things like "add a utility function", "fix this bug", "refactor this service".

If uncertain, ask the user: "This could be handled as a scoped task with `zuvo:build` or through the full pipeline starting with `zuvo:brainstorm`. The pipeline adds design exploration and multi-agent review. Which approach fits?"

---

## Priority Resolution

When a message could match multiple skills, use priority order:

1. **Pipeline** — If the user is mid-pipeline (spec or plan exists and they say "continue" or "next"), resume the pipeline.
2. **Task** — If the intent matches a specific task skill, use it.
3. **Audit** — If the user asks for analysis or a report, use the matching audit skill.
4. **Utility** — Backlog, docs, presentations, worktree management.
5. **Release** — Ship, deploy, monitor, document, reflect.

Within the same priority level, pick the most specific match. "Review my API endpoints" matches `zuvo:api-audit` (more specific) over `zuvo:review` (general code review).

---

## Boundary: When NOT to Invoke a Skill

Do not route to a skill when:

- **Simple questions** — "What does this function do?", "Explain this error" -> answer directly.
- **One-line fixes** — "Change the port to 3001", "Fix the typo on line 42" -> fix directly.
- **Git operations** — "Commit this", "Push to origin", "Create a branch" -> do directly.
- **File reading** — "Show me the config", "Read package.json" -> read directly.
- **Conversation** — "What skills are available?", "How does zuvo work?" -> answer directly.

The threshold: if the task requires reading code to understand it, writing more than a trivial change, or producing a structured output, use a skill. If you can do it in one tool call without analysis, do it directly.

---

## Rationalization Red Flags

You will be tempted to skip skills. Watch for these thoughts and override them:

| What you might think | Why it is wrong | What to do instead |
|----------------------|-----------------|-------------------|
| "This is simple enough to do without a skill" | Skills enforce quality gates you will skip on your own. A "simple" refactor without `zuvo:refactor` skips CONTRACT verification. | Invoke the skill. |
| "I already know how to do this" | Knowing how is not the problem. The skill ensures you verify, test, and document. | Invoke the skill. |
| "The user just wants it done fast" | Fast without quality gates produces bugs. The skill IS the fast path because it catches issues before they ship. | Invoke the skill. |
| "I'll just do the quality checks manually" | You will forget at least one. Skills encode the full checklist. | Invoke the skill. |
| "This is just a small change" | Small changes without `zuvo:review` are the #1 source of regressions. | If it touches production code, invoke the skill. |
| "The user didn't ask for a skill" | Auto-activation means you route to skills by intent, not by explicit command. The user hired zuvo to enforce standards. | Match intent, invoke the skill. |

The only valid reason to skip a skill is when the task falls within the boundary rules above (simple questions, one-line fixes, git ops, file reading, conversation).

---

## Quality Gates (applies to ALL coding — with or without a skill)

Before writing ANY code, verify:

| # | Gate | Trigger | Action |
|---|------|---------|--------|
| G1 | **New code → tests** | Any new `.ts`/`.tsx`/`.py`/`.php` file | Write tests BEFORE or WITH the code. Zero exceptions. |
| G2 | **3+ files → /build** | Feature touches 3+ files | Use `zuvo:build`, NOT direct coding. |
| G3 | **CQ self-eval** | Any production code written | Read `../../rules/cq-checklist.md`. Run CQ1-CQ28. Print score. |
| G4 | **Test self-eval** | Any test code written | Read `../../rules/testing.md`. Run Q1-Q19. Print score. |

Tests are part of implementation, not a follow-up. NEVER ask "should I write tests?" — the answer is always yes. NEVER say "implementation complete" when test files = 0.

**Additional rules:**
- **No direct EnterPlanMode** for features touching 3+ files — use `zuvo:build` instead (includes planning WITH analysis sub-agents).
- **CQ self-eval for direct coding** (1-2 files, no skill): still run CQ1-CQ28 on each production file before writing tests.
- **/review before push**: after any non-trivial implementation, run `zuvo:review` before pushing.

## Skill File Loading

When executing ANY skill that specifies a file loading checklist: **Read each listed file from disk using the Read tool** — "I already know the content" is NOT valid. Print the checklist with status before proceeding. If any REQUIRED file is missing, STOP.

## Stack Detection

Detect the project's tech stack to know which rules to Read when writing code directly (without a skill):

| Signal | Rule to Read |
|--------|-------------|
| `tsconfig.json` or `.ts`/`.tsx` files | `../../rules/typescript.md` |
| `package.json` with `react` or `next` | `../../rules/react-nextjs.md` |
| `package.json` with `@nestjs/core` | `../../rules/nestjs.md` |
| `pyproject.toml`, `.py` files | `../../rules/python.md` |
| `composer.json` with PHP framework | `../../rules/php.md` |

When writing security-sensitive code (auth, input, API): Read `../../rules/security.md`.

## Session Startup

### 1. Project Setup Check (BLOCKING — first session action)

Check if `CLAUDE.md` exists in the project root. If it does NOT exist:

**Tell the user:**

> This project doesn't have a CLAUDE.md yet. Zuvo needs it to enforce quality gates (tests, code review, skill routing). Without it, I might skip skills and write code without tests.
>
> Want me to create one? It'll take 10 seconds.

If the user agrees, create `CLAUDE.md` with this content (adapt stack detection from package.json/tsconfig/pyproject.toml):

```markdown
# [Project Name]

## Development Rules

- ALWAYS use zuvo skills for code changes. Never write production code directly.
  - 1-5 files: `zuvo:build`
  - 5+ files or unclear scope: `zuvo:brainstorm` → `zuvo:plan` → `zuvo:execute`
  - Bug fixes: `zuvo:debug`
  - Refactoring: `zuvo:refactor`
- Tests are mandatory. No production file without a corresponding test file.
- Run `zuvo:review` before pushing any changes.

## Tech Stack

[auto-detected from project files]

## How to run

- Dev: [detected from package.json scripts]
- Test: [detected from package.json scripts]
- Build: [detected from package.json scripts]
```

If the user declines, proceed but warn: "Without CLAUDE.md, quality gates are suggestions, not rules. Tests may be skipped."

Do NOT skip this check. Do NOT silently proceed without CLAUDE.md. A project without CLAUDE.md is the #1 reason agents skip tests and quality gates.

### 2. Knowledge Prime (session-level)

Check if the project has a knowledge base:
```
Glob("knowledge/*.jsonl")
```

If found: read `../../shared/includes/knowledge-prime.md` and run a **lightweight session prime** — no specific WORK_FILES or WORK_KEYWORDS (session start doesn't know the task yet). Use:
```
WORK_TYPE = "research"
WORK_KEYWORDS = <project name>
WORK_FILES = <empty>
```

This surfaces the top project-level gotchas and anti-patterns at session start, before the user even asks for a task. Individual skills will run a focused prime with task-specific keywords later.

If no knowledge base found: skip silently. No log needed at session level.

### 3. Load Patterns

Read `../../rules/cq-patterns-core.md` — defensive coding patterns (error handling, security, data integrity, resource safety). This is a lightweight summary; skills load the full version when needed.

---

## Invocation Format

Use the Skill tool with the `zuvo:` namespace prefix:

```
Skill(skill="zuvo:brainstorm")
Skill(skill="zuvo:build")
Skill(skill="zuvo:review")
Skill(skill="zuvo:code-audit")
```

If the user explicitly names a skill (e.g., "run zuvo:security-audit"), invoke it directly without further routing analysis.

If the user uses a slash command (e.g., "/review", "/build"), map it to the corresponding zuvo skill and invoke it.
