# Zuvo

Auto-activating, multi-agent skill ecosystem for Claude Code and Codex.

39 skills, 20 specialized agents, quality gates, and structured workflows — all in one plugin.

## Install

### Claude Code (recommended)

> Requires Claude Code 1.0.33+. Check with `claude --version`, update with `claude update`.

```bash
# Add the Zuvo marketplace (one-time)
claude plugin marketplace add greglas75/zuvo-marketplace

# Install
claude plugin install zuvo
```

### Codex

```bash
git clone https://github.com/greglas75/zuvo.git
cd zuvo
./scripts/install.sh codex
```

### Both (for plugin developers)

```bash
./scripts/install.sh
```

## Update

### Claude Code

```bash
claude plugin marketplace update zuvo-marketplace
claude plugin update zuvo@zuvo-marketplace
```

Or enable auto-updates:
```
/plugin → Select zuvo-marketplace → Enable auto-update
```

**If skills don't appear after update** (known Claude Code cache issue):
```bash
claude plugin uninstall zuvo@zuvo-marketplace
claude plugin install zuvo
```
Then start a new session.

### Codex

```bash
cd /path/to/zuvo
git pull
./scripts/install.sh codex
```

### Both

```bash
cd /path/to/zuvo
git pull
./scripts/install.sh
```

## What `install.sh` does

One script, two platforms:

| Platform | What it does |
|----------|-------------|
| Claude Code | Copies source files to plugin cache (`~/.claude/plugins/cache/...`) |
| Codex | Builds adapted distribution (path replacement, unicode normalization, TOML agent generation) then copies to `~/.codex/skills/` + `~/.codex/agents/` |

```bash
./scripts/install.sh          # both platforms
./scripts/install.sh claude   # Claude Code only
./scripts/install.sh codex    # Codex only
```

## Local development

For testing changes without committing:

```bash
# Edit files in zuvo-plugin/, then:
./scripts/install.sh

# Restart Claude Code / Codex to pick up changes
```

Optional: add CodeSift MCP for deep code analysis:

```toml
# ~/.codex/config.toml
[mcp_servers.codesift]
command = "npx"
args = ["-y", "codesift-mcp"]
```

## What's inside

- **Pipeline skills** — `zuvo:brainstorm` → `zuvo:plan` → `zuvo:execute` with multi-agent exploration, quality gates, and evidence-based review
- **34 task skills** — build, review, refactor, debug, 19 audits, design, docs, ship, deploy, canary, retro, and more
- **Release pipeline** — `zuvo:ship` → `zuvo:deploy` → `zuvo:canary` for the full post-code lifecycle
- **Auto-activation** — routing engine matches your intent to the right skill automatically
- **CodeSift integration** — semantic search, community detection, call chain tracing, complexity analysis
- **Quality gates** — CQ1-CQ22 (code quality) and Q1-Q17 (test quality)

## Platform support

| Platform | Status | Install |
|----------|--------|---------|
| Claude Code | Stable | `claude plugin install zuvo` |
| Codex | Experimental | `./scripts/install.sh codex` |
| Cursor | Limited (sequential fallback) | `claude --plugin-dir ./zuvo` |

## Skills

| Category | Skills |
|----------|--------|
| Pipeline | brainstorm, plan, execute, worktree, receive-review |
| Core | build, review, refactor, debug |
| Code audits | code-audit, test-audit, api-audit, security-audit, pentest |
| Infra audits | performance-audit, db-audit, dependency-audit, ci-audit, env-audit |
| Structure | structure-audit, seo-audit, seo-fix, architecture |
| Design | design, design-review, ui-design-team |
| Testing | write-tests, fix-tests, write-e2e, tests-performance |
| Release | ship, deploy, canary, release-docs, retro |
| Utility | docs, presentation, backlog, using-zuvo |

## Documentation

- [All 39 Skills](docs/skills.md)
- [Pipeline](docs/pipeline.md) — brainstorm → plan → execute
- [Quality Gates](docs/quality-gates.md) — CQ1-CQ22 + Q1-Q17
- [CodeSift Integration](docs/codesift-integration.md)
- [Configuration](docs/configuration.md)
- [Changelog](https://github.com/greglas75/zuvo/releases)

## For maintainers

### Release to marketplace (for end users)

```bash
./scripts/release.sh patch "fix: description"
./scripts/release.sh minor "feat: description"
```

This bumps version, commits, pushes, tags, updates marketplace SHA.

### Install locally (for development)

```bash
./scripts/install.sh
```

This syncs source to Claude Code cache + Codex. No git push, no marketplace update.

### What `package.json` is for

Metadata only (name, version, description). There are no npm dependencies. No `npm install` needed. The version field is read by `release.sh` and `install.sh`.

## License

MIT
