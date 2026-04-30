# Implementation Plan: CodeSift bootstrap preflight (residual gaps after c65d399)

**Spec:** inline — no spec
**spec_id:** none
**planning_mode:** inline
**source_of_truth:** inline brief — 2026-04-30 audit batch (tgm-survey-platform) surfaced 5 CodeSift failure patterns. Pattern C (`NOT INDEXED` due to wrong repo resolution) is fixed at the source by `c65d399c4` in `~/DEV/codesift-mcp` (resolver: walk registry by ancestor root). Patterns A, B, D, E remain.
**plan_revision:** 2
**status:** Approved
**Created:** 2026-04-30
**Tasks:** 5 (3 in zuvo-plugin, 2 in codesift-mcp)
**Estimated complexity:** 4 standard, 1 complex (Task 4 — diagnose-first)
**Cross-repo:** YES — touches both `zuvo-plugin` (skill markdown) and `codesift-mcp` (TypeScript)

## Sample disclosure (drives the scope of this plan)

The "2026-04-30 audit batch" referenced throughout = 10 audit reports run by the user against `tgm-survey-platform` on branch `fix/tenant-cls-e2e-db-safety` @ `2a589b57f` between 04:47Z and 11:52Z on 2026-04-30. Reports inspected:
- `audits/api-audit-2026-04-30.md`, `audits/db-audit-2026-04-30.md`, `audits/dependency-audit-2026-04-30.md`, `audits/performance-audit-2026-04-30.md`, `audits/performance-audit-designer-2026-04-30.md`, `audits/performance-audit-runner-2026-04-30.md`
- `audit-results/a11y-audit-2026-04-30.md`, `audit-results/architecture-review-2026-04-30.md`, `audit-results/architecture-review-2026-04-30-api.md`, `audit-results/architecture-review-2026-04-30-designer.md`, `audit-results/structure-audit-2026-04-30.md`

Selection rule for in-scope skills: a skill is in scope iff at least one of its 2026-04-30 reports surfaces Pattern A, B, D, or E (verified by grep against the report files). Single-batch sample is acknowledged as the exposure source — the applicability rule below replaces "didn't appear in batch" with a checkable criterion for excluded skills.

## Baseline (pre-fix snapshot — frozen for this plan)

Before-state captured from the 11 reports listed above:

| Pattern | Skill / report | Evidence | Count in 2026-04-30 batch |
|---------|----------------|----------|---------------------------|
| A | performance-audit-designer | "available (deferred) — not invoked, used Grep/Read" | 1 explicit + N silent (unmeasurable from reports alone) |
| B | db-audit, architecture-review-api | "transport closed mid-run" / "transport closed mid-session — degraded mode" | 2 explicit |
| D | a11y-audit, performance-audit-runner | No Tool Availability table at all | 2 (vs 4 audits with full table) |
| E | structure-audit | "`analyze_hotspots` empty (tool anomaly). Git fallback identifies clear hotspots" | 1 explicit on 2,376-commit repo |
| C (already fixed by c65d399) | performance-audit, architecture-review (runner) | "NOT INDEXED" | 2 — out of scope, source-fixed |

Baseline preservation: copy these 11 reports verbatim into `docs/specs/2026-04-30-baseline/` (read-only) before merging Task 1. The post-merge gate diffs against THESE files, not against future regenerated reports.

## Applicability rule (replaces "didn't appear in batch")

A skill is excluded from this plan ONLY IF all of:

1. The skill's `SKILL.md` does not invoke any `mcp__codesift__*` tool, OR delegates fully to `codesift-setup.md` without adding skill-specific CodeSift logic, AND
2. The skill has zero "degraded mode" / "fallback" / "TRANSPORT-CLOSED" / "NOT INDEXED" / "deferred — not invoked" string occurrences across its last 5 runs in `~/.zuvo/runs.log` retros, AND
3. The skill is not listed in `~/.claude/rules/codesift.md` ALWAYS/PREFER table.

Excluded skills must be re-checked every 30 days; if the rule fails for any of them, add to scope in a follow-up plan revision.

---

## Architecture Summary

Two artifact zones, one shared problem:

**Zone 1 — `zuvo-plugin` (Patterns A, D):** SKILL.md instructions tell the harness LLM how to bootstrap CodeSift. The shared include `shared/includes/codesift-setup.md` is the single source of truth. Already covers `index_status`/`index_folder`/transport-close/text-stub. Missing: deferred-tool preload via `ToolSearch` (the MCP-host pattern surfaced this session) and a Tool Availability template that audit reports MUST emit.

**Zone 2 — `codesift-mcp` (Patterns B, E):** TypeScript MCP server. `src/server.ts` (106 LOC) holds the StdioServerTransport. `src/tools/hotspot-tools.ts` (165 LOC) implements `analyze_hotspots`. Pattern B is a transport stability problem during long sessions. Pattern E is a tool-anomaly bug — empty result on a 2,376-commit repo.

The two zones do NOT share dependencies; they're addressable in parallel. The cross-repo coupling is only at runtime: zuvo skills call the MCP server, so a fix on either side is independently shippable.

**Important constraint:** the codesift-mcp working tree has UNSTAGED changes (`.gitignore`, `src/utils/import-graph.ts`, 4 wiki specs in `docs/specs/`). These are user's in-progress work — DO NOT touch. All work for Tasks 4-5 happens on new files or the specific files I name, never via `git add -A`.

## Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Where to detect "deferred MCP tools" | Inline in Phase 0 of each audit skill (delegated to `codesift-setup.md` Step 2.5) | Skills already load codesift-setup.md; one fix benefits all consumers |
| ToolSearch preload set | Core 6 tools: `search_text`, `get_file_tree`, `search_symbols`, `get_symbol`, `index_status`, `plan_turn` | Matches `~/.claude/rules/codesift.md` recommended preload; covers ~80% of audit queries |
| Tool Availability template format | Markdown table with 3 columns (Tool, Status, Notes) — emitted as a copy-paste block in `codesift-setup.md` | Easier to standardize than a structured schema; audit skills already use markdown |
| Audit skills in scope | **7 skills** with confirmed gaps: `api-audit`, `db-audit`, `dependency-audit`, `performance-audit`, `structure-audit`, `a11y-audit`, `architecture` | Other audit skills excluded per the Applicability Rule above; recheck cadence: 30 days |
| Pattern B (transport closed) | Investigate-first, then fix (not blind reconnect logic) | Two retros — db-audit + arch-review-api — but root cause unknown. Adding silent reconnect could mask real bugs |
| Pattern E (analyze_hotspots empty) | Diagnostic logging + repro on tgm-survey-platform → targeted fix | Code reads correctly on inspection: `Math.max(symCount, 1)` does NOT skip 0-symbol files. Empty result must come from `getGitChurn` returning empty Map, or from a path-resolution mismatch between git output and `index.files[].path`. Need real repro |

## Quality Strategy

- **Zone 1 (zuvo-plugin):** docs-only edits, grep assertions + smoke test (run `zuvo:structure-audit` against tgm-survey-platform after deploy, inspect Tool Availability table emission).
- **Zone 2 (codesift-mcp):** real test code. Vitest unit tests + one integration test against tgm-survey-platform's actual git history.
- **Cross-repo verification:** after both zones deploy, re-run the 6 audits from 2026-04-30 batch on the SAME branch state of tgm-survey-platform (`fix/tenant-cls-e2e-db-safety` @ `2a589b57f`) and diff the new "CodeSift" line in each report against the original. Acceptance: zero "available (deferred) — not invoked", zero "transport closed" within 5min runs, `analyze_hotspots` returns ≥10 hotspots on tgm-survey-platform.

Risk areas:
- ToolSearch preload (Task 1) might bloat context for skills that don't actually need CodeSift. Mitigation: only preload when at least one `mcp__codesift__*` appears in deferred list — non-CodeSift sessions skip the preload entirely.
- Pattern B fix risks masking errors if reconnect is too aggressive. Mitigation: log every reconnect attempt + cap at 1 retry per skill run (matching the existing query-fail recovery rule in codesift-setup.md).

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| A | "available (deferred) — not invoked" — agents fall back to Grep/Read silently | constraint | Task 1, Task 3 | preload + per-skill enforcement |
| D | Inconsistent Tool Availability reporting across audit reports | constraint | Task 2, Task 3 | template + 7-skill rollout |
| B | Transport closed mid-session (db-audit, architecture-review-api) | constraint | Task 4 | diagnose first; fix gated on root cause |
| E | `analyze_hotspots` empty on 2,376-commit repo | constraint | Task 5 | diagnostic + targeted fix |
| G1 | Single shared include for all CodeSift bootstrap concerns | goal | Task 1, Task 2 | preserves the existing single-source-of-truth pattern in `codesift-setup.md` |
| G2 | No regression on Pattern C (already fixed by c65d399) | goal | Task 4 (negative) | Task 4 must NOT touch `server-helpers.ts` resolver code |

## Review Trail

- Cross-model validation rev 1 (codex-5.3 + gemini + cursor-agent, mode=audit): 3 CRITICAL + 5 actionable WARNING findings
  - Cursor + Gemini CRIT: `dependency-audit` listed in Task 3 in-scope AND in "Out of scope" enumeration → FIXED rev 2 (removed from out-of-scope)
  - Cursor CRIT: Technical Decisions table said "6 skills" then named 7 then "(7 total)" → FIXED rev 2 (consistent "7 skills")
  - Gemini CRIT: Task 4 Phase A (instrument) → Phase B (fix) workflow contradicts Post-merge gate "zero TRANSPORT-CLOSED single-batch" → FIXED rev 2 (split post-merge into Phase A telemetry pass + Phase B fix verification with explicit gates per phase)
  - Codex WARN: scope exclusions need applicability rule → FIXED rev 2 (Applicability Rule section added)
  - Codex + Cursor WARN: no baseline snapshot recorded → FIXED rev 2 (Baseline section with 11 report inventory + freeze copy directive)
  - Cursor WARN: `architecture` in Task 3 (7 skills) but post-merge runs 6 → FIXED rev 2 (architecture added to verification batch)
  - Gemini WARN: 10-hotspot threshold has no empirical basis → FIXED rev 2 (replaced with "≥ 80% of git-fallback churn count, computed at gate time")
  - Cursor WARN: "original" baseline reports not pinned → FIXED rev 2 (pinned to 11 specific files at branch+SHA in Baseline section)
  - Codex INFO: Task 3 grep verifies presence not placement → FIXED rev 2 (verification extended)
  - Cursor INFO: Task 2 template example concatenates statuses with `|` inside one cell → FIXED rev 2 (one status per row)
- Cross-model validation rev 2: deferred until execute time
- Status gate: Reviewed (cross-model + revision applied; awaiting user approval)

---

## Task Breakdown

### Task 1: Add `Step 2.5: Deferred Tool Preload` to codesift-setup.md

**Files:**
- `zuvo-plugin/shared/includes/codesift-setup.md` (insert new section between current Step 2 and Step 3)

**Complexity:** standard
**Dependencies:** none
**Execution routing:** default implementation tier
**Repo:** zuvo-plugin

- [ ] RED: docs-only edit. Acceptance is grep + smoke run.
- [ ] GREEN:
  Insert after current "Step 2: Initialize" (which already covers `index_status` / `index_folder`):
  ```
  ## Step 2.5: Deferred Tool Preload (MCP-host environments)

  Some MCP hosts (Claude Code, Codex Plugins) defer tool schemas to keep
  the system prompt small. When `mcp__codesift__*` tools appear under
  "deferred tools" in the system reminder rather than directly in the tool
  list, calling them produces `InputValidationError`.

  Detect: if the session start banner mentions `mcp__codesift__*` in a
  deferred list, run preload BEFORE Step 3:

      ToolSearch(query="select:mcp__codesift__search_text,mcp__codesift__get_file_tree,mcp__codesift__search_symbols,mcp__codesift__get_symbol,mcp__codesift__index_status,mcp__codesift__plan_turn")

  This loads the 6 most-used tools' schemas. After preload, the tools work
  normally — proceed with Step 3.

  If `ToolSearch` itself is unavailable: skip preload and treat CodeSift
  as unavailable (degraded mode).

  Run preload at most ONCE per session. Repeating it is wasted tokens.
  ```
  Cross-link from the `Step 1: Discover Availability` section to mention deferred-tool detection as part of the discovery check.
- [ ] Verify:
  ```bash
  grep -nE "Deferred Tool Preload|ToolSearch\(query=\"select:mcp__codesift|deferred tools" /Users/greglas/DEV/zuvo-plugin/shared/includes/codesift-setup.md
  ```
  Expected: at least 3 hits, including the literal `ToolSearch(query="select:mcp__codesift...` line.
- [ ] Acceptance: A, G1
- [ ] Commit: `codesift-setup: add Step 2.5 deferred-tool preload — fixes "available (deferred) — not invoked" pattern from 2026-04-30 perf-audit-designer`

### Task 2: Add `Tool Availability Block (REQUIRED)` template

**Files:**
- `zuvo-plugin/shared/includes/codesift-setup.md` (append new section at end)

**Complexity:** standard
**Dependencies:** Task 1 (status values must reference deferred-tool state)
**Execution routing:** default implementation tier
**Repo:** zuvo-plugin

- [ ] RED: docs-only edit.
- [ ] GREEN:
  Append a new top-level section to `codesift-setup.md`:
  ```
  ## Tool Availability Block (REQUIRED in audit reports)

  Audit skills MUST emit this block at the top of their report (after the
  audit title, before findings). Copy the template; replace status values.
  This is what makes degraded runs auditable after the fact.

  | Tool / Index       | Status                            | Used For   |
  |--------------------|-----------------------------------|------------|
  | CodeSift index     | OK (N files / N symbols)          | <dim list> |
  | analyze_complexity | OK                                | <dim list> |
  | analyze_hotspots   | OK                                | <dim list> |
  | scan_secrets       | OK                                | <dim list> |

  Use exactly ONE status string per row. Do not concatenate values with
  `|` inside a cell — that breaks downstream grep parsing of acceptance
  gates. If a tool was unavailable for one dimension and OK for another,
  emit two separate rows scoped by dimension (e.g.,
  `analyze_hotspots (SA13) | EMPTY-RESULT (git fallback used)`).

  Status vocabulary (use exactly these strings):
  - `OK` — tool ran, returned non-empty result
  - `OK (N files / N symbols)` — index status with counts
  - `DEFERRED-PRELOADED` — was deferred at session start, preloaded via ToolSearch (Step 2.5)
  - `NOT INDEXED` — index missing at session start; ran `index_folder` to recover
  - `TRANSPORT-CLOSED` — MCP transport died mid-run; switched to native fallback
  - `EMPTY-RESULT (<fallback>)` — tool returned empty on a non-empty repo (anomaly); used <fallback>
  - `UNAVAILABLE` — CodeSift MCP not present in tool list at all
  ```
  Add a one-line reference at the top of `codesift-setup.md`: "Skills consuming this include must also emit the Tool Availability Block — see end of file."
- [ ] Verify:
  ```bash
  grep -nE "Tool Availability Block|DEFERRED-PRELOADED|EMPTY-RESULT|TRANSPORT-CLOSED" /Users/greglas/DEV/zuvo-plugin/shared/includes/codesift-setup.md
  ```
  Expected: at least 4 hits.
- [ ] Acceptance: D, G1
- [ ] Commit: `codesift-setup: add Tool Availability Block template — standardizes degraded-mode reporting across audit skills`

### Task 3: Roll out Tool Availability Block reference to 7 audit SKILL.md

**Files:**
- `zuvo-plugin/skills/api-audit/SKILL.md`
- `zuvo-plugin/skills/db-audit/SKILL.md`
- `zuvo-plugin/skills/dependency-audit/SKILL.md`
- `zuvo-plugin/skills/performance-audit/SKILL.md`
- `zuvo-plugin/skills/structure-audit/SKILL.md`
- `zuvo-plugin/skills/a11y-audit/SKILL.md`
- `zuvo-plugin/skills/architecture/SKILL.md`

**Complexity:** standard
**Dependencies:** Task 2 (template must exist before skills can reference it)
**Execution routing:** default implementation tier
**Repo:** zuvo-plugin

- [ ] RED: docs-only edit per file.
- [ ] GREEN:
  In each of the 7 SKILL.md, find the report-output section (varies per skill: `### 5.1 Report`, `### Output`, etc.) and add a single line at the start: "Emit the Tool Availability Block (template in `../../shared/includes/codesift-setup.md`) before findings. This is REQUIRED — auditing degraded runs depends on it."
  Do NOT inline the template into each SKILL.md — keep the single-source-of-truth pattern. Reference only.
  For skills that already mention CodeSift status ad-hoc (`structure-audit`, `architecture`), replace the ad-hoc text with the same standard reference line.
- [ ] Verify:
  ```bash
  for f in api-audit db-audit dependency-audit performance-audit structure-audit a11y-audit architecture; do
    grep -lE "Tool Availability Block" "/Users/greglas/DEV/zuvo-plugin/skills/$f/SKILL.md" >/dev/null \
      || echo "MISSING reference: $f"
  done
  # Structural placement check: the reference must appear within the report-output
  # phase block (not buried in arguments or appendix). Heuristic: reference line
  # number must be > 60% of file length (report sections are always near the end).
  # 6 audit-mode-only skills require placement in last 40% of file
  for f in api-audit db-audit dependency-audit performance-audit structure-audit a11y-audit; do
    p="/Users/greglas/DEV/zuvo-plugin/skills/$f/SKILL.md"
    total=$(wc -l < "$p")
    line=$(grep -n "Tool Availability Block" "$p" | head -1 | cut -d: -f1)
    [ -n "$line" ] && [ "$line" -gt $((total * 60 / 100)) ] || echo "MISPLACED: $f (line $line of $total)"
  done
  # architecture is multi-mode (review/ADR/design); reference goes to REVIEW mode output,
  # which is the audit-style mode. Verify it's inside the "Output -- Architecture Review Report" section
  # (between that header and the next "### Step" or "### Output" header).
  awk '/^### Output -- Architecture Review Report/{in_block=1; next} /^### Step|^### Output/{in_block=0} in_block && /Tool Availability Block/{print "OK: architecture review-mode output"; found=1} END{if(!found) print "MISPLACED: architecture (not in review-mode output section)"}' /Users/greglas/DEV/zuvo-plugin/skills/architecture/SKILL.md
  ```
  Expected: zero MISSING and zero MISPLACED.
- [ ] Acceptance: D
- [ ] Commit: `7 audit skills: require Tool Availability Block emission — references shared template`

### Task 4: Diagnose + fix Pattern B (transport closed mid-session)

**Files:**
- `codesift-mcp/src/server.ts` (instrument + reconnect logic)
- `codesift-mcp/tests/server/transport-stability.test.ts` (NEW)

**Complexity:** **complex** (diagnose-first)
**Dependencies:** none (independent of zuvo-plugin tasks)
**Execution routing:** deep implementation tier
**Repo:** codesift-mcp

- [ ] RED:
  Write `tests/server/transport-stability.test.ts` with:
  1. A unit test that simulates an idle StdioServerTransport for 60s, then sends a request — must succeed without "Transport closed".
  2. A test that intentionally kills and respawns the transport mid-request — server must detect close and surface a clear error code rather than hang.
  Both tests should FAIL on current `main` (proving the bug exists).
- [ ] GREEN:
  Phase A — INSTRUMENT (commit separately, ship to user, run on tgm-survey-platform once):
  In `src/server.ts` around the `transport.connect()` call, register `transport.onclose` handler that logs to stderr with timestamp, last-tool-call, uptime-ms. Add `console.error` lines around request boundaries showing `req-id` and `tool-name`. Do NOT change behavior in this phase.
  Phase B — FIX (only after instrumentation surfaces actual failure mode in a real audit run):
  Based on the captured log, implement targeted fix. Three likely root causes ranked by probability:
  1. **No keep-alive on stdin/stdout** (most likely on macOS pipe — child process flushes get buffered indefinitely) → add explicit `process.stdout.write('')` heartbeat every 30s.
  2. **Long-running tool blocks event loop**, MCP client times out and closes its end → identify which tool, refactor to be cancellable.
  3. **Parent process (Claude Code/Cursor) closes stdin during context compaction** → add graceful re-handshake on stdin EOF.
  Apply ONE fix matching the captured evidence. If the log shows a 4th cause, document it and apply the matching fix.
  Make the tests from RED pass after the fix.
- [ ] Verify:
  ```bash
  cd /Users/greglas/DEV/codesift-mcp && pnpm test tests/server/transport-stability.test.ts 2>&1 | tail -20
  ```
  Expected: all tests pass (`✓` for each `it()` block).
  Integration verify: re-run `zuvo:db-audit` against tgm-survey-platform with the new build installed — the resulting Tool Availability Block must show `CodeSift index | OK (...)` instead of `TRANSPORT-CLOSED`.
- [ ] Acceptance: B, G2 (must not regress c65d399 — Task 4 must NOT touch `src/server-helpers.ts`)
- [ ] Commit (Phase A): `server: instrument transport-close with stderr telemetry — diagnostic only, no behavior change`
  Commit (Phase B): `server: <targeted-fix-per-evidence> — closes pattern B from 2026-04-30 audit batch`

### Task 5: Diagnose + fix Pattern E (analyze_hotspots empty on active repo)

**Files:**
- `codesift-mcp/src/tools/hotspot-tools.ts` (instrument + targeted fix)
- `codesift-mcp/tests/tools/hotspot-tools.test.ts` (extend with regression test)

**Complexity:** standard
**Dependencies:** none
**Execution routing:** default implementation tier
**Repo:** codesift-mcp

- [ ] RED:
  Add a regression test in `tests/tools/hotspot-tools.test.ts`: against a fixture repo with ≥10 commits in the last 90 days where every commit modifies indexed files, `analyzeHotspots(repo, { since_days: 90 })` MUST return `hotspots.length >= 5`. The fixture can be a minimal in-temp git repo built in `beforeAll` (faster than depending on a real repo). Test must FAIL on current `main`.
- [ ] GREEN:
  Three plausible root causes (inspecting `src/tools/hotspot-tools.ts:108-165`):
  1. **`getGitChurn` returns empty** — `since_days` default is too small, or `git log --numstat --format=%H --since=...` returns nothing for repos using merge-commits-only style. Verify by adding `console.error('[hotspot] churn entries=', churn.size)` after line 125.
  2. **Path mismatch** — `git log --numstat` emits paths relative to repo root, but `index.files[].path` may store absolute paths or paths relative to a different anchor. The `symbolCounts.get(file)` lookup at line 139 returns 0 (handled), and the file IS still pushed (line 146). But if `churn` is empty due to (1), no files reach the push.
  3. **`since_days` semantics** — DEFAULT_SINCE_DAYS unknown without reading file. If it's e.g. 30 and the repo had a 31-day quiet period before the audit, churn is empty.
  After Phase A instrumentation, pick the matching fix. Most likely: lower default to 90, OR check stderr to see if `git log` itself errored.
  Add path-mismatch defensive code regardless: after `getGitChurn`, if `churn.size === 0`, retry with `--all` flag (handles odd refs) and log a warning. If still empty, attach the warning to the result so the audit skill can mark `EMPTY-RESULT` properly.
- [ ] Verify:
  ```bash
  cd /Users/greglas/DEV/codesift-mcp && pnpm test tests/tools/hotspot-tools.test.ts 2>&1 | tail -15
  ```
  Expected: regression test passes.
  Integration verify: rebuild + reinstall codesift-mcp, re-run `zuvo:structure-audit` against tgm-survey-platform. The structure-audit report SA13 row must show `analyze_hotspots: OK` with at least 10 hotspots, NOT `EMPTY-RESULT`.
- [ ] Acceptance: E
- [ ] Commit: `analyze_hotspots: <targeted-fix> + regression test — fixes empty-result anomaly on 2,376-commit repo`

---

## Out of scope (explicitly deferred)

- **Do NOT touch** `~/DEV/codesift-mcp/.gitignore`, `~/DEV/codesift-mcp/src/utils/import-graph.ts`, or the 4 unstaged spec files (`docs/specs/2026-04-20-wiki-v2-rich-content-{plan,spec}.md`, `2026-04-21-wiki-journal-{plan,spec}.md`). User has these as in-progress work.
- **Do NOT modify** `~/DEV/codesift-mcp/src/server-helpers.ts` — this is where c65d399 fixed Pattern C. Re-touching the resolver risks regressing Pattern C in the same plan that's supposed to leave it stable (acceptance criterion G2).
- Pattern C remediation in zuvo (workaround code) — not needed; source fix is correct.
- Other audit skills NOT in the 7-skill scope (`code-audit`, `test-audit`, `security-audit`, `seo-audit`, `geo-audit`, `env-audit`, `ci-audit`, `content-audit`, `context-audit`) — gated by the Applicability Rule above; recheck in 30 days.
- Auto-recovery from `transport-closed` to a fresh MCP subprocess restart — too invasive; reconnect within the existing transport (Task 4 Phase B) is enough.

## Post-merge verification (two-phase, mandatory)

The Phase A → Phase B split in Task 4 means the post-merge gate cannot be a single atomic batch run — telemetry capture in Phase A is EXPECTED to surface `TRANSPORT-CLOSED` (that is the diagnostic signal), so a "zero TRANSPORT-CLOSED" gate at that point would fail by design. Two-phase gate:

### Phase A gate (after Tasks 1, 2, 3, 5 ship + Task 4 Phase A instrumentation ships)

Re-run all **7 audits** against tgm-survey-platform `fix/tenant-cls-e2e-db-safety` @ `2a589b57f`:

```bash
cd /Users/greglas/DEV/tgm-survey-platform
zuvo:api-audit && zuvo:db-audit && zuvo:dependency-audit \
  && zuvo:performance-audit && zuvo:structure-audit && zuvo:a11y-audit \
  && zuvo:architecture
```

Phase A acceptance:

| Pattern | Phase A expectation |
|---------|---------------------|
| A | Zero `available (deferred) — not invoked` across all 7 reports; if deferred at session start, shows `DEFERRED-PRELOADED` |
| B | If `TRANSPORT-CLOSED` appears: STDERR log from Task 4 instrumentation must show timestamps + last-tool-call + uptime-ms — these feed Phase B fix selection. If it does NOT appear: Pattern B is dormant on this run; capture remains pending. Either outcome is acceptable in Phase A. |
| D | All 7 reports include the standard Tool Availability table near the top of the report (placement check from Task 3 Verify) |
| E | `structure-audit` SA13 row shows `analyze_hotspots: OK` with hotspot count ≥ 80% of git-fallback churn count, computed at gate time:<br>```GIT_HOT_COUNT=$(git -C /Users/greglas/DEV/tgm-survey-platform log --since="90 days ago" --name-only --pretty=format: 2>/dev/null \| sort -u \| grep -E '\.(ts\|tsx\|js\|jsx)$' \| wc -l); MIN=$(( GIT_HOT_COUNT * 80 / 100 )); echo "Need >= $MIN hotspots"```<br>If `analyze_hotspots` returns < MIN, Task 5 fix is incomplete. |

### Phase B gate (after Task 4 Phase B fix ships)

Re-run the same 7 audits. Phase B acceptance:

| Pattern | Phase B expectation |
|---------|---------------------|
| A | (unchanged from Phase A) |
| B | Zero `TRANSPORT-CLOSED` across all 7 reports during normal-duration runs (≤ 5 min per audit). If a single audit legitimately exceeds 5 min, document and exclude from this gate. |
| D | (unchanged) |
| E | (unchanged) |

Pass = Phase A acceptance fully met AND Phase B acceptance fully met. Fail on Phase A = block Phase B and iterate Task 4 Phase A instrumentation. Fail on Phase B only = open v1.4.x revision targeting the residual transport-close evidence.

### Baseline reference

Phase A and Phase B reports must diff against the frozen `docs/specs/2026-04-30-baseline/` snapshot (created in baseline section above) — NOT against ad-hoc memory of the 2026-04-30 run. The frozen copy is the canonical reference.
