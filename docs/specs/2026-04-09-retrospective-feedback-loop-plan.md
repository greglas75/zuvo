# Implementation Plan: Retrospective Feedback Loop

**Spec:** docs/specs/2026-04-09-retrospective-feedback-loop-spec.md
**spec_id:** 2026-04-09-retrospective-feedback-loop-1345
**planning_mode:** spec-driven
**plan_revision:** 2
**status:** Approved
**Created:** 2026-04-09
**Tasks:** 5
**Estimated complexity:** all standard (markdown-only, no code)

## Architecture Summary

- 1 new shared include: `shared/includes/retrospective.md` (~130 lines)
- 8 skill modifications: add include ref + retrospective step before terminal block
- Runtime output: `~/.zuvo/retros.log` (13-field TSV) + `~/.zuvo/retros.md` (markdown sections)
- Pattern follows `run-logger.md` exactly: loaded at Phase 0, executed before terminal block, append via Bash

## Technical Decisions

- **Structure model:** `run-logger.md` — concise, imperative, bash blocks + tables. No narrative in the include.
- **Target length:** 120-150 lines (fits ~800-1000 tokens in context)
- **Shell pattern:** Reuse run-logger.md's path detection verbatim. TSV rotation preserves header line. Markdown rotation uses `<!-- RETRO -->` delimiter with shell-interpolated awk variable.
- **Skill edit pattern:** 3-line delegation: "Follow the retrospective protocol from `retrospective.md`." No protocol duplication in skills (CQ14).
- **Heading convention:** Match each skill's existing convention (Phase N.N for build, Step N for write-tests, etc.)

## Quality Strategy

- **No automated tests** — markdown-only project. Verification is manual: install plugin, invoke skill, check output.
- **Highest risk:** awk rotation command for markdown. Mitigated by using shell variable interpolation (`'"$ENTRY_COUNT"'`).
- **CQ25 (pattern consistency):** Include line format matches `N. ../../shared/includes/X.md -- LABEL` pattern exactly.
- **CQ14 (no duplication):** Each skill's retro step is ≤3 lines delegating to the include.
- **Acceptance tests:** 6 manual tests defined (load test, skip gate, full retro, AC12 grep, rotation, join key).

## Task Breakdown

### Task 1: Create `shared/includes/retrospective.md`

**Files:** `shared/includes/retrospective.md` (new, ~130 lines)
**Complexity:** standard
**Dependencies:** none
**Execution routing:** default

- [ ] RED: N/A (markdown-only, no test framework)
- [ ] GREEN: Create the shared include file with these sections in order:
  1. Header blockquote: `> Shared include — retrospective protocol for execution skills.`
  2. Gate Check: pseudocode block — subjective triviality check (~5 tool calls / ~1 min), degraded-context flag (>200 tool calls), "do not summarize" prohibition
  3. Structured Questions: 7-row table (fields 1-7 with prompts and grounding requirements), enforcement rules (min 1 of fields 1-4 grounded, field 6 required, field 7 required), structural grounding check (file path / phase number / numeric count)
  4. TSV Format: `RETRO:` prefix line, 13-field table with types and enum values, field resolution bash block (reuse run-logger.md git commands for PROJECT, BRANCH, SHA7)
  5. Markdown Format: exact template with `<!-- RETRO -->` delimiter, all 7 section headings, `[DEGRADED-CONTEXT]` prefix rule
  6. Append Commands: path detection bash block (Codex fallback), TSV first-write guard (create header if file missing), TSV append + rotation (preserve header, `> 101` threshold), markdown append + rotation (`> 100` entries, awk with shell-interpolated ENTRY_COUNT)
  7. Enforcement Rules: 4-bullet compact list — no narrative
- [ ] Verify: `cat shared/includes/retrospective.md | wc -l` — expect 120-150 lines
  `grep -c 'RETRO' shared/includes/retrospective.md` — expect 5+ occurrences
  Visually confirm: file opens with blockquote, contains bash blocks, ends with enforcement rules
- [ ] Acceptance: AC1-AC12 (the include IS the protocol — all ACs depend on it being correct)
- [ ] Commit: `feat: add retrospective shared include — structured agent reflection protocol`

### Task 2: Modify `build` and `write-tests` skills

**Files:** `skills/build/SKILL.md`, `skills/write-tests/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 1
**Execution routing:** default

- [ ] RED: N/A
- [ ] GREEN: For each skill:
  1. Add `../../shared/includes/retrospective.md -- RETRO PROTOCOL` to the Mandatory File Loading checklist (as the next numbered item)
  2. Add a retrospective step section before the terminal block:
     - **build:** Note: the build skill has two sections both numbered `4.6` (`4.6 Stage and Commit` and `4.6 Knowledge Curation`). Insert `### 4.7 Retrospective (REQUIRED)` after the SECOND `4.6` (Knowledge Curation), immediately before the existing `### 4.7 Output` section. Renumber `4.7 Output` to `4.8 Output`. 3 lines: follow protocol, gate check summary, skip instruction.
     - **write-tests:** Insert new numbered item `3. **Retrospective** per retrospective.md` in the Step 5 list, between knowledge curation and the report. Renumber subsequent items.
- [ ] Verify: `grep -c 'retrospective.md' skills/build/SKILL.md` — expect 2 (one in file loading, one in step)
  `grep -c 'retrospective.md' skills/write-tests/SKILL.md` — expect 2
  Visually confirm: step numbering is sequential with no gaps or duplicates
- [ ] Acceptance: AC7 (skills that load the include produce retros; skills that don't, don't)
- [ ] Commit: `feat: add retrospective step to build and write-tests skills`

### Task 3: Modify `review` and `refactor` skills

**Files:** `skills/review/SKILL.md`, `skills/refactor/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 1
**Execution routing:** default

- [ ] RED: N/A
- [ ] GREEN: For each skill:
  1. Add `../../shared/includes/retrospective.md -- RETRO PROTOCOL` to Mandatory File Loading
  2. Add retrospective step:
     - **review:** Insert `### Retrospective (REQUIRED)` between Knowledge Curation and NEXT STEPS. 3-line delegation.
     - **refactor:** Insert `### Retrospective (REQUIRED)` before the `REFACTORING COMPLETE` block (single-file mode) AND before the `BATCH COMPLETE` block (batch mode). Both code paths need it. 3-line delegation each.
- [ ] Verify: `grep -c 'retrospective.md' skills/review/SKILL.md` — expect 2
  `grep -c 'retrospective.md' skills/refactor/SKILL.md` — expect 3 (1 in file loading + 2 in FULL and BATCH paths)
  Visually confirm: refactor has retro step in BOTH code paths
- [ ] Acceptance: AC7
- [ ] Commit: `feat: add retrospective step to review and refactor skills`

### Task 4: Modify `debug`, `execute`, `fix-tests`, `write-e2e` skills

**Files:** `skills/debug/SKILL.md`, `skills/execute/SKILL.md`, `skills/fix-tests/SKILL.md`, `skills/write-e2e/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 1
**Execution routing:** default

- [ ] RED: N/A
- [ ] GREEN: For each skill:
  1. Add `../../shared/includes/retrospective.md -- RETRO PROTOCOL` to Mandatory File Loading
  2. Add retrospective step before terminal block:
     - **debug:** Insert `## Retrospective (REQUIRED)` between Knowledge Curation and Completion. 3-line delegation.
     - **execute:** Insert `### Retrospective (REQUIRED)` between Worktree Suggestion and the terminal Run: block. 3-line delegation.
     - **fix-tests:** Insert `### Retrospective (REQUIRED)` before the `FIX-TESTS SESSION COMPLETE` terminal block (at session end), NOT inside the per-pattern loop. The per-pattern loop has its own Knowledge Curation and Multi-Pattern Continuation steps — the retrospective goes AFTER the loop exits, before the session summary. 3-line delegation.
     - **write-e2e:** Insert `## Retrospective (REQUIRED)` between Knowledge Curation and Completion Report. 3-line delegation.
  Note: heading level (## vs ###) must match each skill's existing convention at that nesting depth.
- [ ] Verify: For each of the 4 skills: `grep -c 'retrospective.md' skills/<name>/SKILL.md` — expect 2
  Visually confirm: heading level matches surrounding sections
- [ ] Acceptance: AC7
- [ ] Commit: `feat: add retrospective step to debug, execute, fix-tests, write-e2e skills`

### Task 5: Integration verification + install

**Files:** none (verification only)
**Complexity:** standard
**Dependencies:** Tasks 1-4
**Execution routing:** default

- [ ] RED: N/A
- [ ] GREEN: N/A (no new files)
- [ ] Verify: Run the full acceptance test sequence:
  1. `./scripts/install.sh` — installs to Claude Code cache + Codex + Cursor
  2. Count check: `grep -rl 'retrospective.md' skills/*/SKILL.md | wc -l` — expect 8
  3. Include exists: `test -f shared/includes/retrospective.md && echo OK` — expect OK
  4. Line count: `wc -l < shared/includes/retrospective.md` — expect 120-150
  5. TSV field count: `grep 'RETRO:' shared/includes/retrospective.md | head -1 | awk -F'\\\\t' '{print NF}'` — expect 13
  6. No orphan references: `grep -r 'retrospective.md' skills/ | grep -v RETRO` — expect only Mandatory File Loading lines
- [ ] Acceptance: All ACs verified structurally. Runtime verification (AC1-AC6, AC9-AC12) requires invoking a skill in a new session.
- [ ] Commit: N/A (verification only, no file changes)
