# Zuvo Plugin — Project Guide

## What this repo is

A Claude Code / Codex / Cursor / Antigravity / Kimi Code plugin. All skills are markdown files (SKILL.md). No TypeScript, no Python, no npm dependencies. `package.json` is metadata only (version field) — never run `npm install`.

## Tech stack

Markdown. Shell scripts in `scripts/`. That's it.

## How to update after making changes

### For yourself (dev testing, no marketplace push)

```bash
./scripts/install.sh          # copies to Claude Code cache + Codex + Cursor + Antigravity + Kimi Code
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
| Test changes locally (dev) | `./scripts/install.sh` then restart Claude/Codex/Cursor/Kimi |
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

### Codex gotcha: the app indexes skills at LAUNCH — restart AFTER install finishes (found 2026-07-18)

The Codex app snapshots `~/.codex/skills/` into memory when it starts (its marker:
`~/.codex/skills/.system/.codex-system-skills.marker` — the mtime is the LAST index time). Running
`install.sh` while the app is open changes the files on disk but NOT what running/new sessions read.
The 2026-07-17 failure: the app indexed at 20:58, the v1.6.10 install finished 21:09 — every session
that evening (64 of them, 575 thread-spawns) ran on the pre-fix snapshot even though the user had
"restarted Codex" (before the install completed). Rule: **finish install.sh first, THEN restart the
Codex app**; verify uptake by checking the marker mtime is newer than the install, and that a fresh
zuvo run prints `[MODE] single-agent (codex hard rule)`. Note: zuvo is NOT a codex `[plugins.*]`
entry — Codex loads it via `~/.codex/skills/` (the legacy path install.sh writes).

### Claude Code gotcha: a release can leave the plugin DISABLED and still report success (2026-08-12)

Same class as the Codex one above, different file. `dev-push.sh` Step 7 runs `claude plugin enable`
and prints `✓ Plugin enabled` — but a Claude Code that was **running through the release** owns
`~/.claude/settings.json` and can persist its own older view afterwards, undoing the CLI's write.
Observed three times in one day: releases reported success, `claude plugin list` showed
`Status: ✘ disabled` in BOTH scopes, and all 57 skills were invisible. Nothing detected it — the
user did, by noticing the skills were gone.

**First check on "skills are not visible" is `claude plugin list`, not the SHA/installPath dance
above.** The two look identical from the outside and have opposite fixes:

```bash
claude plugin list | grep -A3 zuvo          # Status: ✘ disabled  → enable it
claude plugin enable zuvo@zuvo-marketplace
```

A SessionStart hook now self-heals this: `hooks/zuvo-plugin-enable-guard.sh` (installed GLOBALLY to
`~/.claude/hooks/`, **not** plugin-scoped — a plugin hook does not run while its own plugin is off,
which is the state it must fix). `install.sh` stamps `~/.zuvo/plugin-enable-state`; the guard heals
that one stamp **once**, so a clobber is repaired but a deliberate `claude plugin disable` sticks on
the second try. Hard opt-out: `touch ~/.zuvo/no-auto-enable`. Decisions are logged with reasons to
`~/.zuvo/plugin-enable-guard.log`.

Two consequences worth knowing: the guard runs at session START, so it cannot undo a clobber inside
an already-running session — it fixes it at the next start and asks for a restart. And a release
whose push is BLOCKED by the pipeline-entry gate **dies before tagging and before `install.sh`**, so
neither the tag nor the guard lands; the run still prints its earlier `✓` lines. Verify a release by
its tag and `claude plugin list`, never by the absence of an error.

### What install.sh does

| Platform | Action |
|----------|--------|
| Claude Code | Copies source → ALL directories under `~/.claude/plugins/cache/zuvo-marketplace/zuvo/` (see below) |
| Codex | Runs `build-codex-skills.sh` (path replacement, unicode normalization, TOML agent generation) → copies to `~/.codex/skills/` + `~/.codex/agents/` + `~/.codex/shared/` |
| Cursor | Runs `build-cursor-skills.sh` (Cursor v3 agent frontmatter, flat agents with skill prefixes, max 4 parallel) → copies to `~/.cursor/skills/` + `~/.cursor/agents/` + `~/.cursor/shared/` |
| Antigravity | Runs `build-antigravity-skills.sh` → copies to `~/.gemini/antigravity/skills/` + `~/.gemini/antigravity/shared/` |
| Kimi Code | Runs `build-kimi-skills.sh` (flat agents, `model_preference` lanes, hooks in TOML) → copies to `~/.kimi-code/skills/` + `~/.kimi-code/agents/` + `~/.kimi-code/shared/`, and merges `[[hooks]]` into `~/.kimi-code/config.toml` |

**Claude Code cache gotcha:** Claude Code creates TWO cache directories — one named by version (`1.0.0/`) and one named by git SHA (`564a269.../`). It may load from EITHER. `install.sh` syncs to ALL directories. Never copy manually to just one.

Codex requires a BUILD step because it uses different paths (`~/.codex/` not `../../shared/`) and needs TOML agent registration files.

### Kimi Code: the one non-Claude target that is NOT degraded

Kimi Code (verified against v0.34.0) is effectively a Claude Code superset for zuvo's purposes,
so `build-kimi-skills.sh` deliberately does **not** apply the degradations the Cursor and
Antigravity builds must:

- **Sub-agents survive.** Kimi's `Agent` tool takes `prompt`/`description`/`subagent_type`/
  `run_in_background`; builtin types are `agent`, `coder`, `explore`, `plan`. zuvo's 48 agents
  install as custom profiles. Cursor/Antigravity rewrite spawn blocks to "Execute inline: …";
  doing that here would silently turn every multi-agent audit into a single-agent one while
  still reporting success — `tests/hooks/test-kimi-build.sh` (2) exists to catch exactly that.
- **`AskUserQuestion` and plan mode survive** — Kimi has both.
- **Agents are FLAT** in `~/.kimi-code/agents/`: Kimi resolves profiles by a `byName` map, so
  subdirectories load nothing and the two duplicate-name pairs (`cq-auditor`, `spec-reviewer`)
  would silently collide. Names are skill-prefixed, as in the Cursor build.
- **`model:` becomes `model_preference:`**, a closed enum — exactly `primary` or `secondary`,
  anything else is a hard parse error. opus/sonnet → primary, haiku → secondary.
- **Hooks are TOML**, a flat `[[hooks]]` array of `event`/`matcher`/`command`/`timeout` in
  `config.toml` — not the nested JSON shape. Kimi has every event zuvo uses **including
  `StopFailure`**, so the API-error rewake path works here (Cursor/Antigravity must drop it).
  `install.sh` rewrites a marker-delimited block and refuses to write a `config.toml` that
  would not parse — a corrupt one would break the CLI itself.
- **`AGENTS.md`**, not `CLAUDE.md`, is the project instruction file.
- Kimi's native plugin registry (`$KIMI_CODE_HOME/plugins/installed.json`) is deliberately
  **not** used — it is the same central-registry staleness trap as the `installed_plugins.json`
  gotcha above. Auto-discovery dirs have no registry to go stale.

Both `~/.kimi-code/skills/` and `~/.kimi-code/agents/` are SHARED user roots, so installs are
provenance-keyed: skill dirs carry a `.zuvo-owned` marker and flat agents are tracked in a
`.zuvo-agents` manifest. zuvo never deletes or overwrites what it did not install.

Cursor requires a BUILD step because it uses flat agent files in `~/.cursor/agents/` with Cursor v3 frontmatter (`model: inherit`, `readonly: true/false`) instead of Claude Code's `tools:` list.

## How to release (for end users via marketplace)

```bash
./scripts/release.sh patch "description"
./scripts/release.sh minor "description"
```

This does: version bump → commit → push → tag → update marketplace SHA → push marketplace. Users get it via `claude plugin update zuvo`.

## File structure

```
skills/<name>/SKILL.md          — skill definitions (57 total)
skills/<name>/agents/<name>.md  — sub-agent instructions (50 agent files, 48 unique names:
                                    cq-auditor and spec-reviewer each exist TWICE with DIFFERENT
                                    content — refactor/ vs review/, brainstorm/ vs execute/.
                                    Same name ≠ same file; never "sync" one onto the other)
shared/includes/*.md            — shared procedural includes (83 files):
                                    gate-registry.md (SSOT for all 124 CQ/Q/CAP/AP gates; E2E-Q by reference)
                                      E2E-Q is registered there, not defined: the authoritative table
                                      is skills/write-e2e/references/quality-gates.md, and the
                                      generator does not parse those rows
                                    knowledge-prime.md, knowledge-curate.md (knowledge store)
                                    session-state.md (session recovery)
                                    report-output-location.md (canonical zuvo/ output dir)
                                    severity-vocabulary.md (unified severity mapping)
                                    terminal-state.md (no completion over a live process / pending check)
                                    adversarial-loop.md, adversarial-loop-docs.md (evidence enforcement)
                                    quality-gates.md, env-compat.md, codesift-setup.md, run-logger.md
                                    + registries, schemas, protocols
rules/*.md                      — code quality rules (20 files: cq-patterns, testing, security, file-limits, etc.)
scripts/install.sh              — local install to Claude + Codex + Cursor + Antigravity + Kimi
scripts/release.sh              — release to marketplace
scripts/build-codex-skills.sh   — build Codex distribution (called by install.sh)
scripts/build-cursor-skills.sh  — build Cursor v3 distribution (called by install.sh)
scripts/build-antigravity-skills.sh — build Antigravity distribution (called by install.sh)
scripts/build-kimi-skills.sh    — build Kimi Code distribution (called by install.sh)
hooks/*.sh                      — hooks install.sh copies into ~/.claude/hooks/ and registers in
                                  ~/.claude/settings.json. These are GLOBAL, not plugin-scoped —
                                  they keep running when the plugin is disabled, which is what makes
                                  zuvo-plugin-enable-guard.sh (SessionStart) able to fix exactly that
                                  state. Also: pipeline-entry gates, skill-usage-logger, retro sweep.
docs/                           — documentation (skills.md, pipeline.md, competitive-analysis.md, etc.)
docs/runbook/testing.md         — HOW TO VERIFY THIS REPO: the 5 commands, per-change checklist,
                                  the quarterly deep-audit procedure, failure triage
docs/runbook/operating.md       — commands that look right and are not. Read BEFORE typing a
                                  pkill/pgrep, a heredoc through ssh, or a `grep -c` guard; also
                                  why `install.sh` can leave the plugin disabled for the NEXT
                                  session and why editing a running driver corrupts it
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

## The retro learning loop (how zuvo improves itself)

Runs write retros → weekly mining turns them into digests → digests carry change proposals →
proposals get surfaced, implemented, and **marked done**. Full runbook, including every dead end
this loop already produced and how each was closed: **`docs/retro-learning-loop.md`**. Read it
before touching anything under `scripts/zuvo-home/` or `~/.zuvo/`.

The two rules worth repeating here:

- **After implementing a proposal, disposition it in the same session** —
  `~/.zuvo/digest-proposals --mark applied --file <F> --section <S> --ref <version>`. Skip this and
  the item re-surfaces forever; that exact gap left 57 finished proposals looking open.
- **Never edit `~/.zuvo/<helper>` directly** — `./scripts/install.sh` overwrites it from
  `scripts/zuvo-home/<helper>` on the next run. Edit the repo copy, then install.

`~/.zuvo/` data (retros, digests, the disposition ledger) is HOME-local and NOT in git. Before a
machine migration: `tar czf ~/zuvo-state-$(date +%F).tgz -C "$HOME" .zuvo`.

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

## Skill categories (57 total)

| Category | Count | Skills |
|----------|-------|--------|
| Pipeline | 5 | brainstorm, plan, execute, worktree, receive-review |
| Core | 4 | build, review, refactor, debug |
| Code/Test audits | 5 | code-audit, test-audit, api-audit, security-audit, pentest |
| Infra audits | 7 | performance-audit, db-audit, dependency-audit, ci-audit, env-audit, infra-audit, container-audit |
| Structure/SEO/GEO | 6 | structure-audit, seo-audit, seo-fix, geo-audit, geo-fix, architecture |
| Content | 5 | content-audit, content-fix, content-migration, write-article, content-expand |
| Design | 3 | design, design-review, ui-design-team |
| Testing | 5 | write-tests, fix-tests, write-e2e, tests-performance, mutation-test |
| Accessibility | 1 | a11y-audit |
| Release | 5 | ship, deploy, canary, release-docs, retro |
| Utility | 10 | docs, presentation, backlog, incident, benchmark, agent-benchmark, using-zuvo, context-audit, skill-eval, profile-session |
| Lead Generation | 1 | leads |

## Common tasks

| Task | Command |
|------|---------|
| Add a new skill | See the checklist below — the count lives in **eight** places, and missing one fails a test, not the build |
| Edit a skill | Edit the SKILL.md, then `./scripts/install.sh` |
| Test changes locally | `./scripts/install.sh` then restart Claude/Codex |
| Verify the repo (any change) | `docs/runbook/testing.md` §1 — validate-skills → gen-gate-copies → gate-consistency → registry-integrity → run-all |
| Periodic deep audit | `docs/runbook/testing.md` §4 — the 5 questions per file; question 3 ("does the example implement its own prose?") is the highest-yield |
| Release to users | `./scripts/release.sh patch "description"` |
| Add a shared include | Create in `shared/includes/`, reference via `../../shared/includes/` from skills |

### Adding a skill — the full checklist

`validate-skills.sh` catches most of this, but two test suites carry the count independently and
only fail at release time. Every one of these bit on the 56th skill:

1. `skills/<name>/SKILL.md` — frontmatter, `# zuvo:<name>`, Argument Parsing, Mandatory File
   Loading, phases, named completion block, run-log append (template: `skills/build/SKILL.md`).
2. `skills/using-zuvo/SKILL.md` — a routing row **and** the `| N skills |` banner.
3. `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json` (two strings), `package.json` —
   the "N skills and M agents" description.
4. `docs/skills.md` — the per-skill table row, the category-count table, and the `**Total**` row.
5. `CLAUDE.md` — "skill definitions (N total)", "## Skill categories (N total)", category table.
6. `README.md` — the "N skills, …" intro line (sat stale at 55 until 2026-08-01; now covered by
   `count-consistency`).
7. `./scripts/install.sh` — builds all four targets; the Codex build **fails** on Claude-Code tool
   names (`run_in_background`, `Task`, …) that `validate-skills.sh` does not check.
8. `bash scripts/validate-skills.sh` → `count-consistency: OK (N)`, then
   `bash tests/run-all.sh` — the release script runs it and will block on a stale count.

Counts in tests are now derived from `skills/` rather than hardcoded, so (7) should stay green on
its own; keep it that way if you touch those assertions.
