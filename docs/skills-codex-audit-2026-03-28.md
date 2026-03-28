# Skills Codex Audit (2026-03-28)

## Scope

Review of all 33 Zuvo skills, skill by skill, with focus on:

- usefulness and operator clarity
- document quality and maintainability
- source-level compatibility with Codex

## Cross-Cutting Findings

1. The biggest compatibility risk was not in one skill, but in shared conventions: `CLAUDE.md`, `.claude/`, `AskUserQuestion`, and explicit `ToolSearch(...)` instructions leaked into source skills that Codex reads directly.
2. A second recurring issue is model-name coupling (`Sonnet`, `Haiku`, `Opus`) in operational instructions. This is tolerable in Claude-only flows, but weakens cross-platform clarity.
3. Long skills are still the main maintainability risk. Six source skills exceed 500 lines and are the first candidates for progressive-disclosure refactors.

## Status Legend

- `OK`: no immediate Codex-compat blocker found
- `Needs cleanup`: usable, but has clarity or compatibility debt
- `High priority`: repeated compatibility debt or high maintenance cost

## Skill-by-Skill Review

| Skill | Status | Main findings | Action |
|---|---|---|---|
| `api-audit` | Needs cleanup | Had explicit CodeSift discovery wording and legacy project-instruction reference. | Summary and instruction-file reference updated. |
| `architecture` | Needs cleanup | Mixed modern and legacy interaction guidance; still somewhat verbose. | `AGENTS.md`/`CLAUDE.md` handling improved. |
| `backlog` | OK | Clear scope and low Codex coupling. | No change needed now. |
| `brainstorm` | Needs cleanup | Direct CodeSift discovery wording still visible in source before cleanup. | CodeSift wording generalized. |
| `build` | Needs cleanup | Useful workflow, but still carries legacy project-instruction language and model-specific tables. | Project-instruction wording fixed; model cleanup still partial. |
| `ci-audit` | OK | Reasonably self-contained and already low in platform coupling. | No change needed now. |
| `code-audit` | Needs cleanup | Strong workflow, but legacy CodeSift summary and project-instruction wording reduced Codex clarity. | Summary and instruction-file reference updated. |
| `db-audit` | Needs cleanup | Main issue is size: 538 lines. | Leave behavior as-is; split into references later. |
| `debug` | Needs cleanup | Main issue is size: 508 lines. | Leave behavior as-is; split into references later. |
| `dependency-audit` | OK | No immediate Codex-specific blocker detected. | No change needed now. |
| `design` | Needs cleanup | Interactive-question wording assumed platform-specific prompting. | Rephrased to interactive vs non-interactive behavior. |
| `design-review` | Needs cleanup | Still mentions `ToolSearch` conceptually for optional tooling. | Follow-up: make tool checks environment-neutral. |
| `docs` | OK | Low coupling and acceptable length. | No change needed now. |
| `env-audit` | OK | No immediate blocker detected. | No change needed now. |
| `execute` | Needs cleanup | Source still had explicit CodeSift discovery wording and legacy project-instruction reference. | CodeSift wording and project instructions improved. |
| `fix-tests` | OK | Focused and low-coupling. | No change needed now. |
| `pentest` | Needs cleanup | Direct CodeSift/Playwright discovery wording in source. | Environment-neutral checks added. |
| `performance-audit` | Needs cleanup | Main issue is size: 542 lines. | Leave behavior as-is; split into references later. |
| `plan` | Needs cleanup | Model-routing language was Claude-centric and leaked into Codex output. | Routing wording generalized; agent headings cleaned up. |
| `presentation` | OK | Low platform coupling. | No change needed now. |
| `receive-review` | OK | Reasonably portable. | No change needed now. |
| `refactor` | High priority | 653 lines, explicit model naming, approval wording, and direct CodeSift discovery text. | Approval and CodeSift wording improved; still a strong candidate for splitting. |
| `review` | High priority | 741 lines, multiple model-specific execution blocks, approval wording, and direct CodeSift discovery text. | Approval/CodeSift wording improved; still the top refactor candidate. |
| `security-audit` | High priority | 505 lines plus legacy project-instruction and CodeSift wording. | Compatibility wording improved; size remains the main debt. |
| `seo-audit` | Needs cleanup | Direct CodeSift discovery wording in source. | Summary generalized. |
| `structure-audit` | Needs cleanup | Direct CodeSift discovery wording in source. | Summary generalized. |
| `test-audit` | Needs cleanup | Direct CodeSift discovery wording plus model-specific notes remain. | Summary generalized; model cleanup deferred. |
| `tests-performance` | Needs cleanup | Stored artifacts under `.claude/`, which is wrong for Codex and generally brittle. | Moved instructions to `memory/` artifacts. |
| `ui-design-team` | Needs cleanup | Legacy project-instruction wording. | `AGENTS.md`/`CLAUDE.md` handling improved. |
| `using-zuvo` | OK | Router is concise and already Codex-aware enough. | No change needed now. |
| `worktree` | Needs cleanup | Looked only at `CLAUDE.md` for project preference. | Generalized to `AGENTS.md` or `CLAUDE.md`. |
| `write-e2e` | Needs cleanup | Direct CodeSift and Playwright discovery wording plus model-specific agent table. | Tool-check wording generalized; model cleanup deferred. |
| `write-tests` | Needs cleanup | Still references `CLAUDE.md`, `.claude`, and model-specific subagent wording. | Left untouched in this pass because the file already has local uncommitted edits. |

## Shared Includes Review

| File | Status | Main findings | Action |
|---|---|---|---|
| `shared/includes/agent-preamble.md` | Fixed | Assumed `CLAUDE.md` and `.claude/rules/` only. | Generalized to `AGENTS.md`, `CLAUDE.md`, `rules/`, `.claude/rules/`. |
| `shared/includes/env-compat.md` | Fixed | Overstated that Codex cannot ask questions and hard-coded Claude-oriented interaction semantics. | Updated to distinguish Codex CLI vs async/non-interactive execution. |
| `shared/includes/codesift-setup.md` | Fixed | Described `ToolSearch(...)` as the only discovery path. | Rewritten to support both discovery-based and direct MCP-based environments. |

## Recommended Next Pass

1. Split `review`, `refactor`, `security-audit`, `performance-audit`, `db-audit`, and `debug` into lean `SKILL.md` plus reference files.
2. Replace remaining model-specific execution prose with capability tiers instead of Claude model names.
3. Finish source cleanup for `write-tests` after reconciling the already-present local edits.
