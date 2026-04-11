# Configuration

## Plugin structure

```
zuvo-plugin/
  .claude-plugin/
    plugin.json          # Plugin metadata (name, version, description)
  hooks/
    hooks.json           # Hook definitions (SessionStart triggers router injection)
    run-hook.cmd         # Cross-platform hook launcher (bash + cmd polyglot)
    session-start        # Reads the skill router and injects it as session context
  rules/                 # Bundled rule files loaded by skills on demand
  shared/
    includes/            # Reusable protocol files included by multiple skills
  skills/
    <skill-name>/
      SKILL.md           # Skill definition (frontmatter + instructions)
      agents/            # Agent instruction files (pipeline skills only)
  .codex-plugin/
    plugin.json          # Codex plugin manifest (name, version, skills path)
  .mcp.json              # Optional CodeSift MCP config for Codex
  dist/
    codex/               # Build output (gitignored) — Codex-adapted skills + TOMLs
  package.json
  README.md
```

## Hooks

Zuvo uses a single `SessionStart` hook. It fires when you start a Claude Code session (or clear/compact the context).

**What it does:** Reads the `using-zuvo` skill router and injects it as session context so Claude knows about all 33 skills from the first message. The same hook also injects the compressed response protocol for hook-enabled main assistant replies, plus the optional `.zuvo/project-profile.json` summary when present. The router handles auto-activation -- matching your intent to the right skill without explicit commands.

**Platform detection:** The hook detects whether it is running in Claude Code (`CLAUDE_PLUGIN_ROOT`), Cursor (`CURSOR_PLUGIN_ROOT`), or an unknown environment, and emits the correct JSON format for each.

**Kill switch:** Set `ZUVO_RESPONSE_PROTOCOL=off` before starting a session to disable protocol injection while keeping router injection enabled.

## Shared includes

Located in `shared/includes/`. These are protocol files loaded by skills at runtime via the Read tool. They are not auto-loaded -- each skill specifies which includes it needs in its Mandatory File Loading section.

| File | Purpose |
|------|---------|
| `env-compat.md` | Environment compatibility: how skills adapt to Claude Code, Codex, and Cursor. Covers agent dispatch patterns, path resolution, progress tracking, and user interaction per platform. |
| `codesift-setup.md` | CodeSift discovery, initialization, and tool selection guide. Includes the full tool mapping table and degraded mode fallbacks. See [codesift-integration.md](codesift-integration.md). |
| `compressed-response-protocol.md` | Global v1 response-style contract for hook-enabled main assistant turns. Defines `STANDARD`, `TERSE`, `STRUCTURED_TERSE`, protected literals, override order, and the `[...truncated...]` escape hatch. |
| `quality-gates.md` | Quick reference for CQ1-CQ28 and Q1-Q19 gates. Condensed version for agent use. Full details in the rules directory. See [quality-gates.md](quality-gates.md). |
| `tdd-protocol.md` | TDD cycle enforcement: RED (failing test), GREEN (minimal code), REFACTOR. Red flag table for common violations. Used by pipeline execute and build skills. |
| `verification-protocol.md` | 5-step verification protocol: IDENTIFY, RUN, READ, VERIFY, CLAIM. Ensures no completion claims without fresh evidence from the actual system. |
| `agent-preamble.md` | Standard rules for read-only audit agents: never modify files, every finding requires evidence (file:line), confidence levels (0-25% discard, 26-50% backlog, 51-100% report), structured output format. |
| `backlog-protocol.md` | How skills persist findings to `memory/backlog.md`: fingerprint-based deduplication, confidence routing, severity tracking, resolution cleanup. |
| `run-logger.md` | Centralized skill usage log protocol: append-only writes to `~/.zuvo/runs.log`, Codex path fallback (`~/.codex/zuvo/runs.log`), structured fields (timestamp, skill, env, project). |
| `codex-agent-registry.md` | TOML generation manifest: agent naming, model mapping, thread/depth limits. Used by `scripts/build-codex-skills.sh`. |

## Bundled rules

Located in `rules/`. These are reference files that skills load when performing evaluations.

| File | Scope |
|------|-------|
| `cq-checklist.md` | Full CQ1-CQ28 gate definitions, scoring thresholds, evidence standards, N/A rules |
| `cq-patterns.md` | NEVER/ALWAYS code pairs for 40+ patterns (atomicity, idempotency, errors, money, lookups, cleanup, secrets, path traversal, prototype pollution, Docker, etc.) |
| `testing.md` | Q1-Q19 gate definitions, test quality scoring, pattern selection |
| `test-quality-rules.md` | Edge case checklists, mock safety rules, auto-fail patterns, assertion strength |
| `security.md` | XSS, SSRF, injection, auth patterns for security-sensitive code |
| `file-limits.md` | File and function size limits by type (service, component, hook, util, handler) |
| `typescript.md` | TypeScript rules: zero-any policy, Zod type-first, strict typing, error handling types |
| `react-nextjs.md` | React and Next.js patterns and conventions |
| `nestjs.md` | NestJS-specific patterns and conventions |
| `python.md` | Python-specific patterns and conventions |
| `php.md` | PHP patterns: type juggling, SQL injection, SSRF, file uploads, multi-tenant isolation, CSRF, Semgrep-derived (unserialize, exec, eval, mcrypt, unlink, FTP, open redirect) |

## Stack detection

Skills that need stack-specific rules detect the project's tech stack from config files:

| Signal | Stack | Rules loaded |
|--------|-------|-------------|
| `tsconfig.json` or `.ts`/`.tsx` files | TypeScript | `typescript.md` |
| `package.json` with `react` in deps | React | `react-nextjs.md` |
| `package.json` with `next` in deps | Next.js | `react-nextjs.md` |
| `package.json` with `@nestjs/core` in deps | NestJS | `nestjs.md` |
| `pyproject.toml` or `.py` files | Python | `python.md` |
| `composer.json` or `.php` files | PHP | `php.md` |
| `vitest.config.*` or `vitest` in devDeps | Vitest | Test runner detection |
| `jest.config.*` or `jest` in devDeps | Jest | Test runner detection |
| `prisma/schema.prisma` | Prisma ORM | ORM detection for DB audit |

Detection is automatic. Skills read the relevant rule files when they detect a matching stack.

## Customization

### Project-specific rules

Zuvo reads your project's `CLAUDE.md` and `.claude/rules/` directory. Project conventions override Zuvo's bundled rules when they conflict. Agent preamble (`shared/includes/agent-preamble.md`) instructs all agents to check for project conventions before starting analysis.

### Backlog location

Tech debt backlog is written to `memory/backlog.md` in your project root. If `memory/` does not exist, Zuvo creates it. The backlog format is a markdown table with fingerprint-based deduplication.

### Artifact locations

Pipeline specs and plans are written to `docs/specs/` in your project root. Design system files go to `.interface-design/`. These paths are hardcoded in the skill definitions.

### Disabling auto-routing

If you want to use Zuvo skills explicitly without auto-routing, you can:

1. Invoke skills directly by name: `zuvo:review`, `zuvo:code-audit`, etc.
2. For tasks that do not need a skill, state your intent clearly: "just change the port to 3001" -- the router recognizes one-line fixes and does not activate a skill.

### Disabling response compression

If you want the router but not the compressed response protocol for a session, start the session with:

```bash
ZUVO_RESPONSE_PROTOCOL=off claude
```

That disables only the protocol injection. Explicit skill invocation still works. In environments where session hooks do not run, Zuvo falls back to degraded mode: skills still work, but global response compression defaults are not guaranteed.

### Environment support

Zuvo adapts to three environments:

| Environment | Agent dispatch | Concurrency | User interaction |
|-------------|---------------|-------------|-----------------|
| **Claude Code** | Task tool (parallel, model-routed) | Unrestricted | AskUserQuestion |
| **Codex** | TOML agents (parallel, sandboxed) | Capped at 6 threads | Not available (safest default) |
| **Cursor** | Sequential (no spawning) | Sequential only | Not available (safest default) |

All skills produce identical output regardless of environment. The execution strategy adapts, but quality gates and evidence requirements remain the same.
