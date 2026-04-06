---
name: docs
description: >
  Write and update technical documentation from actual codebase analysis.
  Generates README, API reference, runbook, onboarding guide, or changelog.
  Supports update mode that patches stale sections without rewriting from
  scratch. Modes: readme [path], api [path], runbook [topic], onboarding,
  update [file], changelog [range].
---

# zuvo:docs — Technical Documentation

Generate or update documentation by reading the actual codebase -- not from templates, not from memory, from real code.

**Iron rule:** Never write a claim in documentation without reading the source file it references first. Every section maps back to a source file via the Evidence Map.

**Scope:** README, API reference, runbooks, onboarding guides, changelogs.
**Out of scope:** Architecture diagrams (use `zuvo:architecture`), code comments (out of scope), user-facing product docs (out of scope).

## Argument Parsing

| Input | Action |
|-------|--------|
| _(empty)_ | Check if README.md exists. If yes: update it. If no: generate one. If user interaction is available, ask for preference. |
| `readme [path]` | Write or update README for the module at [path] |
| `api [path]` | Generate API reference from route/controller files at [path] |
| `runbook [topic]` | Write operational runbook for a specific process |
| `onboarding` | Write onboarding guide for new developers |
| `update [file]` | Read existing doc, verify claims against source, patch stale sections |
| `changelog` | Generate CHANGELOG.md from git history |
| `changelog [range]` | Generate changelog for a specific range (e.g., v1.2.0..v1.3.0) |

**Non-interactive environments (Codex, Cursor):**
- No arguments: default to `readme` for project root
- Target file exists: default to `update` mode (patch, not overwrite)

---

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for user interaction patterns.

## CodeSift Integration

Read `../../shared/includes/codesift-setup.md` for initialization.

**Key tools for this skill:**

| Doc type | Task | CodeSift tool | Fallback |
|----------|------|--------------|----------|
| README | Project structure | `get_file_tree(repo, path_prefix="src", compact=true)` | `ls -R src/` |
| README | Module overview | `detect_communities(repo, focus="src")` | Manual directory analysis |
| API | Endpoint discovery | `search_symbols(repo, kind="function", file_pattern="**/api/**")` | Grep for route decorators |
| API | Handler source + callers | `find_and_show(repo, query=<handler>, include_refs=true)` | Read each file |
| API | Schema discovery | `search_symbols(repo, query="Schema", kind="variable", include_source=true)` | Grep for Zod/validator |
| Update | Verify file paths | `get_file_tree(repo, path_prefix=<path>)` | ls / Glob |
| Update | Verify API shapes | `get_symbol(repo, symbol_id)` | Read the file |
| Any | Context assembly | `assemble_context(repo, query=<topic>, token_budget=4000)` | Multiple Read calls |

---

## Run Logging

Read `../../shared/includes/run-logger.md` for log format and file path resolution.

## Stack-Aware Commands (Required)

Before writing any doc with shell commands, detect the project's package manager and tooling. Never hardcode `npm` -- use what the project actually uses.

| Signal | Install | Dev | Test | Build |
|--------|---------|-----|------|-------|
| `pnpm-lock.yaml` | `pnpm install` | `pnpm dev` | `pnpm test` | `pnpm build` |
| `yarn.lock` | `yarn` | `yarn dev` | `yarn test` | `yarn build` |
| `bun.lockb` | `bun install` | `bun dev` | `bun test` | `bun run build` |
| `package-lock.json` | `npm install` | `npm run dev` | `npm test` | `npm run build` |
| `pyproject.toml` (poetry) | `poetry install` | `poetry run ...` | `poetry run pytest` | `poetry build` |
| `requirements.txt` | `pip install -r requirements.txt` | `python manage.py runserver` | `pytest` | -- |
| `go.mod` | `go mod download` | `go run .` | `go test ./...` | `go build` |
| `Cargo.toml` | `cargo build` | `cargo run` | `cargo test` | `cargo build --release` |
| `composer.json` | `composer install` | `php artisan serve` | `vendor/bin/phpunit` | -- |

If commands come from package.json scripts or Makefile targets, use the exact script name.

---

## Mandatory Source Reading

For every doc type, read the relevant source files before writing anything:

| Doc type | Read first |
|----------|-----------|
| README | package.json or pyproject.toml, main entry point, existing README if any |
| API docs | Route/controller files, DTO/schema files, auth guard files |
| Runbook | The service code being operated, existing runbooks in docs/ |
| Onboarding | package.json, docker-compose.yml, CI config, existing onboarding docs |
| Changelog | Git log for the target range |

---

## Mode: README

### Output Structure

```markdown
# [Service/Package Name]

> [One sentence -- what is this and why does it exist?]

## Quick Start

[Minimum steps to get running locally, using stack-aware commands]

## Configuration

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|

## Development

[Dev, test, lint, build commands -- from package.json/Makefile, verified]

## Project Structure

[Directory listing with one-line descriptions, from actual ls/tree]

## API

[Link to API docs or brief summary]

## Contributing

[Branch strategy, PR requirements]
```

Quality checklist: Quick start works in under 5 commands. All env vars documented. Commands match actual scripts. No template copy-paste.

---

## Mode: API Reference

### Output Structure

```markdown
# API Reference -- [Service Name]

**Base URL:** `/api/v1`
**Auth:** [from actual auth guard detection]

## [Resource Name]

### GET /[resource]

[Description from reading the handler code]

**Auth:** [from guard/middleware on this route]
**Query Parameters** [from DTO/schema]
**Response 200** [from actual return type/shape]
**Errors** [from error handling in the handler]
```

Quality checklist: Every endpoint has auth requirement noted. All request fields documented with types. All meaningful error codes listed. Response shapes come from code, not invention.

---

## Mode: Runbook

### Output Structure

```markdown
# Runbook: [Operation Name]

**When to use:** [Trigger condition]
**Time required:** ~[N] minutes
**Who can run this:** [Role]
**Risk level:** [Low | Medium | High]

## Prerequisites
## Steps (numbered, with commands and expected output)
## Verification (how to confirm success)
## Rollback (how to undo if something goes wrong)
## Escalation (who to contact)
```

---

## Mode: Onboarding Guide

### Output Structure

```markdown
# Developer Onboarding -- [Project Name]

**Time to first working local environment:** ~[N] minutes

## Environment Setup (prerequisites, clone, install, config)
## Key Systems (what does what, where it lives)
## Common Tasks (run tests, add endpoint, deploy)
## Who to Ask (topic -> person -> channel)
```

---

## Mode: Update (Staleness Check)

When `update [file]` is invoked, follow this procedure strictly. Never rewrite from scratch.

### Step 1: Extract Claims

Read the existing doc. Extract every factual claim as a checklist item: commands, file paths, env vars, API endpoints, architecture descriptions.

### Step 2: Verify Each Claim

For each claim, read the source file it references:

| Claim type | Where to verify |
|------------|----------------|
| Shell commands | package.json scripts, Makefile, pyproject.toml |
| File paths | ls / Glob -- does the path exist? |
| Env vars | .env.example, config loader |
| API endpoints | Route/controller files |
| Architecture | Import graph, docker-compose, infra config |

Mark each: verified (still true), stale (incorrect), unverifiable (source missing).

### Step 3: Patch

- Verified claims: leave unchanged
- Stale claims: update with correct information from source
- Unverifiable claims: add `<!-- TODO: verify -- source not found -->`
- Missing info: add new sections only if source reveals undocumented features

### Step 4: Summary

```
Update summary for [file]:
  [N] sections unchanged
  [N] sections updated: [list]
  [N] sections unverifiable: [list]
  [N] new sections added: [list]
```

If more than 50% of claims are stale, suggest full rewrite with `readme [path]` instead.

---

## Mode: Changelog

### Step 1: Check for git-cliff

```bash
npx git-cliff --version 2>/dev/null
```

### Step 2: Generate

If git-cliff available:

```bash
npx git-cliff --output CHANGELOG.md          # full
npx git-cliff v1.2.0..v1.3.0 --output CHANGELOG.md  # range
```

If not available, fall back to manual parsing:

```bash
git log --oneline --no-merges $(git describe --tags --abbrev=0 2>/dev/null || echo "HEAD~20")..HEAD
```

Classify by conventional commit prefix (feat/fix/refactor/docs/chore), format as Markdown.

### Step 3: Enrich

Read the generated changelog. For cryptic messages, read the actual diff and add one-line context. Group related commits. Highlight breaking changes.

---

## Evidence Map (Required)

Every generated doc must include a hidden Evidence Map tracing each section to its source:

```markdown
<!-- Evidence Map
| Section | Source file(s) |
|---------|---------------|
| Quick Start | package.json:scripts (line 5-12) |
| Configuration | .env.example (line 1-15) |
| API: GET /users | src/routes/users.controller.ts:24-45 |
-->
```

Rules:
- Every section with factual claims needs at least one source entry
- Commands must trace back to the script definition file
- If a section has no source: `<!-- TODO: needs source verification -->`

---

## Command Validation Gate (Before Output)

After writing any doc with shell commands:

1. Extract all bash code blocks from the generated doc
2. Check each command against its source (package.json scripts, Makefile targets, etc.)
3. Flag mismatches and fix them before output

```
Command validation:
  pnpm dev        -> matches package.json scripts.dev
  pnpm test       -> matches package.json scripts.test
  pnpm run lint   -> no "lint" in scripts (found "lint:check") -> FIXED
```

---

## Output Paths

| Doc type | Default path |
|----------|-------------|
| readme | `[target-path]/README.md` |
| api | `docs/api/[service-name].md` |
| runbook | `docs/runbooks/[topic].md` |
| onboarding | `docs/onboarding.md` |
| changelog | `./CHANGELOG.md` |

If target file exists, ask before overwriting (except in update mode). Non-interactive environments default to update mode.

---

## Completion

After completing any mode, print:

```
DOCS COMPLETE
-----
Mode:  [readme | api | runbook | onboarding | update | changelog]
Run: <ISO-8601-Z>	docs	<project>	-	-	<VERDICT>	-	<DURATION>	<NOTES>	<BRANCH>	<SHA7>
-----
```

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

`<DURATION>`: use the mode label (`readme`, `api`, `runbook`, `onboarding`, `changelog`, or `update`).

---

## Principles

1. Read the code, write the docs. Every claim must be verifiable in the source.
2. Write for the reader. README is for someone who just found the repo. Runbook is for someone at 2am.
3. Start with the most useful information. Quick Start before architecture details.
4. Stale docs are worse than no docs. Mark uncertainty with TODO rather than leaving wrong information.
