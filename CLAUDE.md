# Zuvo Plugin — Project Guide

## What this repo is

A Claude Code / Codex plugin. All skills are markdown files (SKILL.md). No TypeScript, no Python, no npm dependencies. `package.json` is metadata only (version field) — never run `npm install`.

## Tech stack

Markdown. Shell scripts in `scripts/`. That's it.

## How to update after making changes

### For yourself (dev testing, no marketplace push)

```bash
./scripts/install.sh          # copies to Claude Code cache + Codex
```

Then restart Claude Code / Codex.

**BUT** — `install.sh` alone is NOT enough for Claude Code in all cases. Claude Code validates the plugin SHA from `installed_plugins.json` against the cache. If they don't match, skills may not load. To fully sync:

```bash
# Full local update (guaranteed to work):
./scripts/install.sh
claude plugin marketplace update zuvo-marketplace
claude plugin update zuvo@zuvo-marketplace
# Then restart Claude Code
```

### For end users (marketplace release)

```bash
./scripts/release.sh patch "description"
```

This does everything: version bump, commit, push, tag, marketplace SHA update. Users get it via `claude plugin update zuvo`.

### Quick reference

| What you want | Command |
|---------------|---------|
| Test changes locally (dev) | `./scripts/install.sh` then restart Claude/Codex |
| Release to users | `./scripts/release.sh patch "msg"` |
| Verify release works | `claude plugin uninstall zuvo@zuvo-marketplace && claude plugin install zuvo` then new session |
| User first install | `claude plugin marketplace add greglas75/zuvo-marketplace && claude plugin install zuvo` |
| User updates | `claude plugin marketplace update zuvo-marketplace && claude plugin update zuvo@zuvo-marketplace` |

### Known gotcha: stale SHA after update

`claude plugin update` sometimes keeps a stale SHA in `installed_plugins.json`, causing skills to not load. If skills don't appear after update, do a clean reinstall:
```bash
claude plugin uninstall zuvo@zuvo-marketplace
claude plugin install zuvo
```
This is a Claude Code plugin cache bug, not a zuvo bug. It creates multiple cache directories (by version AND by SHA) and can get confused about which one to load.

### What install.sh does

| Platform | Action |
|----------|--------|
| Claude Code | Copies source → ALL directories under `~/.claude/plugins/cache/zuvo-marketplace/zuvo/` (see below) |
| Codex | Runs `build-codex-skills.sh` (path replacement, unicode normalization, TOML agent generation) → copies to `~/.codex/skills/` + `~/.codex/agents/` + `~/.codex/shared/` |

**Claude Code cache gotcha:** Claude Code creates TWO cache directories — one named by version (`1.0.0/`) and one named by git SHA (`564a269.../`). It may load from EITHER. `install.sh` syncs to ALL directories. Never copy manually to just one.

Codex requires a BUILD step because it uses different paths (`~/.codex/` not `../../shared/`) and needs TOML agent registration files.

## How to release (for end users via marketplace)

```bash
./scripts/release.sh patch "description"
./scripts/release.sh minor "description"
```

This does: version bump → commit → push → tag → update marketplace SHA → push marketplace. Users get it via `claude plugin update zuvo`.

## File structure

```
skills/<name>/SKILL.md          — skill definitions (39 total)
skills/<name>/agents/<name>.md  — sub-agent instructions
shared/includes/*.md            — shared procedural includes (codesift-setup, env-compat, etc.)
rules/*.md                      — code quality rules (cq-patterns, testing, security)
scripts/install.sh              — local install to Claude + Codex
scripts/release.sh              — release to marketplace
scripts/build-codex-skills.sh   — build Codex distribution (called by install.sh)
docs/                           — documentation (skills.md, pipeline.md, etc.)
.claude-plugin/plugin.json      — Claude Code plugin manifest
.codex-plugin/plugin.json       — Codex plugin manifest
package.json                    — version metadata only (no npm)
```

## Skill conventions

Every SKILL.md follows this structure:
1. YAML frontmatter: `name` (kebab-case), `description` (one paragraph)
2. H1 heading: `# zuvo:<name>`
3. Argument Parsing table
4. Mandatory File Loading checklist (shared includes via `../../shared/includes/`)
5. Numbered phases (Phase 0, 1, 2...)
6. Named output block (e.g., `SHIP COMPLETE`)
7. Run log append via `../../shared/includes/run-logger.md`

Reference: `skills/build/SKILL.md` is the canonical template.

## Skill categories (39 total)

| Category | Count | Skills |
|----------|-------|--------|
| Pipeline | 5 | brainstorm, plan, execute, worktree, receive-review |
| Core | 4 | build, review, refactor, debug |
| Code/Test audits | 5 | code-audit, test-audit, api-audit, security-audit, pentest |
| Infra audits | 5 | performance-audit, db-audit, dependency-audit, ci-audit, env-audit |
| Structure/SEO/Arch | 4 | structure-audit, seo-audit, seo-fix, architecture |
| Design | 3 | design, design-review, ui-design-team |
| Testing | 4 | write-tests, fix-tests, write-e2e, tests-performance |
| Release | 5 | ship, deploy, canary, release-docs, retro |
| Utility | 4 | docs, presentation, backlog, using-zuvo |

## Common tasks

| Task | Command |
|------|---------|
| Add a new skill | Create `skills/<name>/SKILL.md`, add to `skills/using-zuvo/SKILL.md` routing table, update counts in plugin.json files + package.json + docs/skills.md, then `./scripts/install.sh` |
| Edit a skill | Edit the SKILL.md, then `./scripts/install.sh` |
| Test changes locally | `./scripts/install.sh` then restart Claude/Codex |
| Release to users | `./scripts/release.sh patch "description"` |
| Add a shared include | Create in `shared/includes/`, reference via `../../shared/includes/` from skills |
