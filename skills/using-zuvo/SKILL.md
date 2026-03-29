---
name: using-zuvo
description: "ALWAYS LOADED — Zuvo skill router. Injected at session start. Determines which zuvo skill to invoke for the current task."
---

# Zuvo Skill Router

You have access to the Zuvo skill ecosystem. Before acting on any user request, check the routing table below. If a skill matches, invoke it using the Skill tool. Do not implement the task yourself when a skill exists for it.

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
| Continue from approved spec | `zuvo:plan` | Requires spec artifact in `docs/specs/*-spec.md` |
| Continue from approved plan | `zuvo:execute` | Requires plan artifact in `docs/specs/*-plan.md` |

**Pipeline order is mandatory.** `brainstorm` produces a spec. `plan` requires a spec. `execute` requires a plan. Do not skip phases. If the user says "build this feature" and no spec exists, start with `brainstorm`, not `execute`.

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
| Audit codebase structure and organization | `zuvo:structure-audit` |
| Review architecture, create ADR | `zuvo:architecture` |
| Review UI/UX consistency and accessibility | `zuvo:design-review` |
| Design new UI (components, layouts, systems) | `zuvo:design` |
| UI design with multi-agent team | `zuvo:ui-design-team` |
| Optimize test suite speed | `zuvo:tests-performance` |

### Priority 4 — Utility

| User intent | Skill |
|-------------|-------|
| View or manage tech debt backlog | `zuvo:backlog` |
| Write documentation | `zuvo:docs` |
| Create a presentation | `zuvo:presentation` |
| Respond to code review feedback | `zuvo:receive-review` |
| Isolate work in a git worktree | `zuvo:worktree` |

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
- `zuvo:plan` requires a spec. If none exists, redirect to `zuvo:brainstorm`.
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
