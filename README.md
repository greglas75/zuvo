# Zuvo

Auto-activating, multi-agent skill ecosystem for Claude Code.

33 skills, 12 specialized agents, quality gates, and structured workflows — all in one plugin.

## Install

### Via marketplace (recommended)

```bash
# Add the Zuvo marketplace (one-time)
claude plugin marketplace add greglas75/zuvo-marketplace

# Install the plugin
claude plugin install zuvo
```

### Local development

```bash
# Clone and load for a single session
git clone https://github.com/greglas75/zuvo.git
claude --plugin-dir ./zuvo
```

## What's inside

- **Pipeline skills** — `zuvo:brainstorm` → `zuvo:plan` → `zuvo:execute` with multi-agent code exploration, quality gates, and evidence-based review
- **27 task skills** — build, review, refactor, debug, 19 audits, design, docs, and more
- **Auto-activation** — SessionStart hook injects a routing engine that matches your intent to the right skill automatically
- **CodeSift integration** — deep code understanding via semantic search, community detection, call chain tracing, and complexity analysis
- **Quality gates** — CQ1-CQ22 (code quality) and Q1-Q17 (test quality) with evidence requirements and N/A abuse prevention

## Pipeline

```
User: "Add user export with CSV download"

→ zuvo:brainstorm
  ├── Code Explorer (what exists in the codebase?)
  ├── Domain Researcher (what libraries/patterns exist?)
  └── Business Analyst (edge cases, acceptance criteria)
  → Design → Spec → User approval

→ zuvo:plan
  ├── Architect (boundaries, data flow)
  ├── Tech Lead (patterns, libraries, trade-offs)
  ├── QA Engineer (testability, CQ pre-check)
  └── Team Lead (bite-sized TDD tasks)
  → Plan → User approval

→ zuvo:execute
  For each task:
  ├── Implementer (RED test → GREEN code → commit)
  ├── Spec Reviewer (does code match plan?)
  └── Quality Reviewer (CQ1-CQ22, Q1-Q17, file limits)
```

## Skills

| Category | Skills |
|----------|--------|
| Pipeline | brainstorm, plan, execute, worktree, receive-review |
| Core | build, review, refactor, debug |
| Code audits | code-audit, test-audit, api-audit, security-audit, pentest |
| Infra audits | performance-audit, db-audit, dependency-audit, ci-audit, env-audit |
| Structure | structure-audit, seo-audit, architecture |
| Design | design, design-review, ui-design-team |
| Testing | write-tests, fix-tests, write-e2e, tests-performance |
| Utility | docs, presentation, backlog |

## License

MIT
