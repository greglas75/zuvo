# Zuvo Plugin — Project Guide

## What this repo is

A Claude Code / Codex plugin. All skills are markdown files (SKILL.md). No TypeScript, no Python, no npm dependencies. `package.json` is metadata only (version field) — never run `npm install`.

## Tech stack

Markdown. Shell scripts in `scripts/`. That's it.

## How to update after making changes

### For yourself (dev testing, no marketplace push)

```bash
./scripts/install.sh          # copies to Claude Code cache + Codex + Cursor
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

### One-command dev workflow (RECOMMENDED)

```bash
./scripts/dev-push.sh "description"
```

This does EVERYTHING in one command:
1. `git add -A` + commit with your message
2. `git push origin main`
3. Update marketplace SHA → push marketplace
4. Update `installed_plugins.json` SHA (fixes the stale SHA problem)
5. Copy files to Claude Code cache (all directories)
6. Build + install to Codex

After running: **just restart Claude Code**. No uninstall/install needed.

### For end users (marketplace release)

```bash
./scripts/release.sh patch "description"
```

This does everything: version bump, commit, push, tag, marketplace SHA update. Users get it via `claude plugin update zuvo`.

### Quick reference

| What you want | Command |
|---------------|---------|
| Push + sync everything (dev) | `./scripts/dev-push.sh "description"` then restart Claude/Codex |
| Test changes locally (dev) | `./scripts/install.sh` then restart Claude/Codex/Cursor |
| Release to users | `./scripts/release.sh patch "msg"` |
| Verify release works | `claude plugin uninstall zuvo@zuvo-marketplace && claude plugin install zuvo` then new session |
| User first install | `claude plugin marketplace add greglas75/zuvo-marketplace && claude plugin install zuvo` |
| User updates | `claude plugin marketplace update zuvo-marketplace && claude plugin update zuvo@zuvo-marketplace` |

### Known gotcha: stale `installPath` after update (ROOT CAUSE — fixed 2026-05-31)

**Claude Code loads hooks + skills from the `installPath` field in `installed_plugins.json`, NOT from `gitCommitSha`.** The original `dev-push.sh` step 5 updated only `gitCommitSha` and left `installPath`/`version` frozen — so every "release" copied files into a new `cache/.../zuvo/<new-version>/` dir while Claude Code kept loading the OLD `<installPath>` dir. Symptom: new hooks/skills never take effect no matter how many restarts (the 2026-05-31 watchdog saga — three releases, zero hook firings, because `installPath` was stuck at 1.3.107 while `gitCommitSha` advanced to 1.3.111's commit).

`dev-push.sh` now updates `installPath` + `version` + `gitCommitSha` together, so future releases are fixed. To check if it ever recurs:
```bash
python3 -c "import json; d=json.load(open('$HOME/.claude/plugins/installed_plugins.json')); [print(x['installPath'], x['version']) for n,e in d['plugins'].items() if 'zuvo' in n.lower() for x in e]"
```
`installPath`/`version` must match the latest `cache/.../zuvo/<version>/` dir that holds your changes. If stale, re-run `dev-push.sh` or clean reinstall:
```bash
claude plugin uninstall zuvo@zuvo-marketplace && claude plugin install zuvo
```
Claude Code also creates multiple cache dirs (by version AND by SHA); `install.sh` syncs all of them, but `installPath` is the one that actually loads.

### What install.sh does

| Platform | Action |
|----------|--------|
| Claude Code | Copies source → ALL directories under `~/.claude/plugins/cache/zuvo-marketplace/zuvo/` (see below) |
| Codex | Runs `build-codex-skills.sh` (path replacement, unicode normalization, TOML agent generation) → copies to `~/.codex/skills/` + `~/.codex/agents/` + `~/.codex/shared/` |
| Cursor | Runs `build-cursor-skills.sh` (Cursor v3 agent frontmatter, flat agents with skill prefixes, max 4 parallel) → copies to `~/.cursor/skills/` + `~/.cursor/agents/` + `~/.cursor/shared/` |

**Claude Code cache gotcha:** Claude Code creates TWO cache directories — one named by version (`1.0.0/`) and one named by git SHA (`564a269.../`). It may load from EITHER. `install.sh` syncs to ALL directories. Never copy manually to just one.

Codex requires a BUILD step because it uses different paths (`~/.codex/` not `../../shared/`) and needs TOML agent registration files.

Cursor requires a BUILD step because it uses flat agent files in `~/.cursor/agents/` with Cursor v3 frontmatter (`model: inherit`, `readonly: true/false`) instead of Claude Code's `tools:` list.

## How to release (for end users via marketplace)

```bash
./scripts/release.sh patch "description"
./scripts/release.sh minor "description"
```

This does: version bump → commit → push → tag → update marketplace SHA → push marketplace. Users get it via `claude plugin update zuvo`.

## File structure

```
skills/<name>/SKILL.md          — skill definitions (54 total)
skills/<name>/agents/<name>.md  — sub-agent instructions (28 agents)
shared/includes/*.md            — shared procedural includes (38 files):
                                    knowledge-prime.md, knowledge-curate.md (knowledge store)
                                    session-state.md (session recovery)
                                    report-output-location.md (canonical zuvo/ output dir)
                                    severity-vocabulary.md (unified severity mapping)
                                    adversarial-loop.md, adversarial-loop-docs.md (evidence enforcement)
                                    quality-gates.md, env-compat.md, codesift-setup.md, run-logger.md
                                    + 22 registries, schemas, protocols
rules/*.md                      — code quality rules (12 files: cq-patterns, testing, security, file-limits, etc.)
scripts/install.sh              — local install to Claude + Codex + Cursor
scripts/release.sh              — release to marketplace
scripts/build-codex-skills.sh   — build Codex distribution (called by install.sh)
scripts/build-cursor-skills.sh  — build Cursor v3 distribution (called by install.sh)
docs/                           — documentation (skills.md, pipeline.md, competitive-analysis.md, etc.)
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

## Output location convention (where reports/state are written)

**Single source of truth: `shared/includes/report-output-location.md`.** All project-local
zuvo output goes into ONE visible folder at the **project root**, never scattered into a
scoped subfolder:

```
ZUVO_DIR="${ZUVO_OUTPUT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/zuvo}"
```

- `zuvo/audits/` — all `*-audit` reports (`.md` + `.json`), incl. seo/geo/content/a11y/design-review/architecture-review
- `zuvo/reports/` — non-audit outputs: canary, content-migration, benchmark, agent-benchmark, retro, release-docs
- `zuvo/plans/`, `zuvo/contracts/`, `zuvo/context/` — pipeline state (plan/build/execute/refactor/review)
- `zuvo/project-profile.json` — project profile (read by `hooks/session-start`)

Anchored to git root (not `$PWD`/scope), **visible** (not hidden `.zuvo/`, which is invisible
in macOS Finder), overridable via `$ZUVO_OUTPUT_DIR`. Readers (`~/.zuvo/append-runlog`,
`hooks/pre-commit-adversarial-gate.sh`, fix skills) check `zuvo/` first, then fall back to the
legacy `audits/`, `audit-results/`, and `.zuvo/` locations for projects mid-migration.

Distinct and unaffected: `~/.zuvo/` (HOME — global `runs.log`, `retros.*`, helper binaries)
and `docs/` (human-authored README/ADR/runbook/spec docs). When adding a report-writing skill,
load `report-output-location.md` and write under `$ZUVO_DIR/{audits,reports}/`.

## Pipeline-entry enforcement (stop agents shipping past the gates)

Production-code work must go through `zuvo:build`/`zuvo:execute` so it gets reviewed. The
enforcement is deterministic (see `docs/pipeline.md` → "Pipeline-entry enforcement" for the
full layer table + honest limits):

- **CI gate** (`ci/zuvo-pipeline-entry.yml` + `scripts/zuvo-pipeline-entry-ci.sh`) — THE
  GUARANTEE, fail-closed, unbypassable server-side. Enable: `cp ci/zuvo-pipeline-entry.yml .github/workflows/`.
- **pre-push gate** — primary local block (canonical pushed range).
- **global git-dispatch layer** (`hooks/git-dispatch/` → `~/.claude/hooks`, global
  `core.hooksPath`) — runs the repo-local hook (no exec) then ALWAYS chains the pipeline-entry +
  work gates in EVERY repo, so freestyle-agent pushes are gated even where no local hook exists.
  Limits: repo-local `core.hooksPath` overrides (Husky) bypass it; uninstall:
  `git config --global --unset core.hooksPath`.
- **commit-gate + Stop-gate nudges** — best-effort early warnings (bypassable by design).
- **`hooks/lib/pipeline-gate-lib.sh`** — single-source detection (range-arg, content-keyed
  review coverage via `memory/reviews/<base7>..<head7>-<slug>.md`, fail-open).
- **Threshold = the contract:** ≥3 production files OR ≥150 changed lines, override with
  `ZUVO_GATE_MIN_FILES` / `ZUVO_GATE_MIN_LINES`.
- **Escapes (logged):** `ZUVO_ALLOW_ADHOC=1` locally; the human-applied `zuvo:adhoc-approved`
  PR label in CI (an agent cannot self-apply it). Hooks/tests live in `hooks/` + `tests/hooks/`.

## Skill categories (54 total)

| Category | Count | Skills |
|----------|-------|--------|
| Pipeline | 5 | brainstorm, plan, execute, worktree, receive-review |
| Core | 4 | build, review, refactor, debug |
| Code/Test audits | 5 | code-audit, test-audit, api-audit, security-audit, pentest |
| Infra audits | 6 | performance-audit, db-audit, dependency-audit, ci-audit, env-audit, infra-audit |
| Structure/SEO/GEO | 6 | structure-audit, seo-audit, seo-fix, geo-audit, geo-fix, architecture |
| Content | 5 | content-audit, content-fix, content-migration, write-article, content-expand |
| Design | 3 | design, design-review, ui-design-team |
| Testing | 5 | write-tests, fix-tests, write-e2e, tests-performance, mutation-test |
| Accessibility | 1 | a11y-audit |
| Release | 5 | ship, deploy, canary, release-docs, retro |
| Utility | 8 | docs, presentation, backlog, incident, benchmark, agent-benchmark, using-zuvo, context-audit |
| Lead Generation | 1 | leads |

## Common tasks

| Task | Command |
|------|---------|
| Add a new skill | Create `skills/<name>/SKILL.md`, add to `skills/using-zuvo/SKILL.md` routing table, update counts in plugin.json files + package.json + docs/skills.md, then `./scripts/install.sh` |
| Edit a skill | Edit the SKILL.md, then `./scripts/install.sh` |
| Test changes locally | `./scripts/install.sh` then restart Claude/Codex |
| Release to users | `./scripts/release.sh patch "description"` |
| Add a shared include | Create in `shared/includes/`, reference via `../../shared/includes/` from skills |
