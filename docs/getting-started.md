# Getting Started

## Prerequisites

- **Claude Code** installed and working (`claude` command available in your terminal)
- **Node.js** 18+ (for package.json resolution and hook execution)
- **GNU coreutils** — required for adversarial review (`brew install coreutils` on macOS)
- **Bash** available (macOS/Linux native; Windows requires Git Bash or WSL)
- **Optional:** [codesift-mcp](https://github.com/nicobailey/codesift-mcp) for deep code exploration (semantic search, call chain tracing, complexity analysis). Zuvo works without it but runs in degraded mode.

## Adversarial review providers (optional but recommended)

Zuvo uses cross-model adversarial review — a different AI reviews code written by your primary AI. Install one or more providers for best results. More providers = more diverse blind-spot coverage.

### Codex CLI (fastest — 5-23s)

```bash
npm install -g @openai/codex
codex auth login          # login with your ChatGPT account
```

Requires a ChatGPT Plus/Pro/Team subscription.

### Gemini CLI (free — 11s)

```bash
npm install -g @google/gemini-cli
gemini                    # first run: opens browser, login with Google account
```

Free tier — no credit card required.

### Cursor Agent CLI (11s)

```bash
# Comes with Cursor IDE — install from https://cursor.com
# Verify:
cursor-agent --version
```

No separate login needed if Cursor is already authenticated.

### Claude CLI

Already installed if you use Claude Code. No extra setup.

```bash
claude --version          # verify it works
```

### Gemini API (alternative — 15-60s, no CLI needed)

```bash
# Get a free API key from https://aistudio.google.com
export GEMINI_API_KEY=your_key_here
# Add to ~/.zshrc or ~/.bashrc to persist
```

Free tier: 250 requests/day, 10 RPM.

### What Zuvo auto-detects

Zuvo automatically detects which providers are available and uses them in priority order:

| Priority | Provider | Detection |
|----------|----------|-----------|
| 1 | codex-fast | `codex` binary in PATH or Codex.app installed |
| 2 | cursor-agent | `cursor-agent` binary in PATH |
| 3 | gemini | `gemini` binary in PATH (or available via npx) |
| 4 | claude | `claude` binary in PATH |
| 5 | gemini-api | `GEMINI_API_KEY` environment variable set |

You don't need all of them. Even one provider gives you cross-model review. Two or more providers run in parallel for diverse coverage.

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

The compressed response protocol is injected only in hook-enabled sessions. If you invoke skills in a degraded path without session hooks, skills still work, but terse working-mode defaults are not guaranteed.

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
3. The hook also reads `shared/includes/compressed-response-protocol.md` unless `ZUVO_RESPONSE_PROTOCOL=off`
4. Router and protocol content are injected as session context via `hookSpecificOutput`
5. Claude now knows about all 39 skills and will auto-route your requests to the right skill

You do not need to type skill names. The router matches your intent to skills automatically. Saying "review my changes" activates `zuvo:review`. Saying "add a notification feature" activates `zuvo:brainstorm` or `zuvo:build` depending on scope.

If the hook is unavailable or disabled, Zuvo still runs in degraded mode: explicit skill invocation works, but the global compression contract for working chatter is not guaranteed.

To disable the response protocol while keeping the router, start the session with:

```bash
ZUVO_RESPONSE_PROTOCOL=off claude
```

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
