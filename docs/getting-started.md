# Getting Started

## Prerequisites

- **Claude Code** installed and working (`claude` command available in your terminal)
- **Node.js** 18+ (for package.json resolution and hook execution)
- **GNU coreutils** — required for adversarial review (`brew install coreutils` on macOS)
- **Bash** available (macOS/Linux native; Windows requires Git Bash or WSL)
- **Optional:** [codesift-mcp](https://github.com/nicobailey/codesift-mcp) for deep code exploration (semantic search, call chain tracing, complexity analysis). Zuvo works without it but runs in degraded mode.

## Install

> **Requires Claude Code 1.0.33+.** Check with `claude --version`, update with `claude update` or `npm update -g @anthropic-ai/claude-code`.

```bash
# Prerequisite (macOS)
brew install coreutils

# Add the Zuvo marketplace (one-time)
claude plugin marketplace add greglas75/zuvo-marketplace

# Install the plugin
claude plugin install zuvo
```

Restart Claude Code.

## Update

```bash
claude plugin marketplace update zuvo-marketplace
claude plugin update zuvo@zuvo-marketplace
```

Restart Claude Code. Then verify the update applied:

```bash
echo "test" | ~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh --help 2>&1 | grep "mode spec"
```

If you see `--mode spec` — update successful.

If you don't, or skills behave oddly after update — do a clean reinstall:

```bash
claude plugin uninstall zuvo@zuvo-marketplace
claude plugin install zuvo
```

Restart Claude Code. This is a known Claude Code cache bug (stale SHA in `installed_plugins.json`), not a zuvo issue.

## Check version

```bash
claude plugin list | grep zuvo
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Skills don't load after update | Clean reinstall: `claude plugin uninstall zuvo@zuvo-marketplace && claude plugin install zuvo` |
| Skills load but skip adversarial review | Stale cache — clean reinstall |
| `timeout: command not found` in adversarial review | `brew install coreutils` |
| `/using-zuvo` shows "unknown command" | Plugin not loaded — restart Claude Code |

## Enable auto-updates

After installing, enable automatic updates so new skills and fixes arrive automatically:

```
/plugin
→ Select zuvo-marketplace
→ Enable auto-update
```

## Codex

Zuvo runs on OpenAI Codex. The SKILL.md format is natively compatible (agentskills.io open standard).

```bash
git clone https://github.com/greglas75/zuvo.git ~/zuvo-plugin
cd ~/zuvo-plugin && ./scripts/install.sh codex
```

Update: `cd ~/zuvo-plugin && git pull && ./scripts/install.sh codex`

Optional: bundle CodeSift MCP for deep code analysis:

```toml
# Add to ~/.codex/config.toml
[mcp_servers.codesift]
command = "npx"
args = ["-y", "codesift-mcp"]
```

Skills are invoked with `$skill-name` (Codex convention) instead of `/skill-name`. The skill router auto-discovers skills via description matching.

On Codex App (async mode), interactive skills like brainstorm run autonomously with `[AUTO-DECISION]` annotations. Review the generated spec before proceeding to plan.

## Cursor / Antigravity

```bash
git clone https://github.com/greglas75/zuvo.git ~/zuvo-plugin
cd ~/zuvo-plugin && ./scripts/install.sh cursor
```

Update: `cd ~/zuvo-plugin && git pull && ./scripts/install.sh cursor`

## Local development

```bash
git clone https://github.com/greglas75/zuvo.git
claude --plugin-dir ./zuvo
```

This loads the plugin for the current session only. Useful for testing changes before publishing.

## What happens at session start

When you start a Claude Code session with Zuvo installed:

1. The `SessionStart` hook fires (defined in `hooks/hooks.json`)
2. The hook script (`hooks/session-start`) reads the skill router from `skills/using-zuvo/SKILL.md`
3. The router content is injected as session context via `hookSpecificOutput`
4. Claude now knows about all 39 skills and will auto-route your requests to the right skill

You do not need to type skill names. The router matches your intent to skills automatically. Saying "review my changes" activates `zuvo:review`. Saying "add a notification feature" activates `zuvo:brainstorm` or `zuvo:build` depending on scope.

## Quick test

Start a session in any project and try:

```
Add a utility function that formats currency values as integer-cents
```

Zuvo should activate `zuvo:build` (scoped feature, 1-5 files). You will see:

1. **File loading checklist** -- the skill confirms it read its reference files
2. **Analysis agents** -- blast radius mapper and existing code scanner run in parallel
3. **Implementation plan** -- presented for your approval before any code is written
4. **TDD cycle** -- failing test first, then implementation, then quality gates
5. **CQ self-evaluation** -- CQ1-CQ28 scored with evidence before completion

If you ask for something larger ("build a user management module with roles, permissions, and audit logging"), the router will direct to `zuvo:brainstorm` instead, starting the full pipeline.

## Explicit invocation

You can always invoke a skill directly:

```
zuvo:review
zuvo:code-audit src/services/
zuvo:security-audit --live-url http://localhost:3000
zuvo:brainstorm
```

Slash commands also work: `/review`, `/build`, `/refactor` map to their `zuvo:` equivalents.

## Uninstalling

### Marketplace install

```bash
claude plugin uninstall zuvo
```

### Local install

Stop the session. The plugin is only active while `--plugin-dir` is specified.

To remove the marketplace source entirely:

```bash
claude plugin marketplace remove greglas75/zuvo-marketplace
```

Zuvo does not modify your project files during installation. All runtime artifacts (specs, plans, backlog) are written to `docs/specs/` and `memory/` within your project, which you can delete if unwanted.
