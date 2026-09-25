# Implementation Plan: Blind coverage audit as a 3-provider panel in adversarial-review.sh (Plan B of 3)

**Spec:** inline — no spec (planning input: `zuvo/context/plan-input-cross-vendor-review.md`)
**spec_id:** none
**planning_mode:** inline
**source_of_truth:** inline brief (user decision 2026-09-25: "3. ok" — blind audit through the adversarial driver, agy pinned + 2 random, effort per mode) + Phase 1 reports `zuvo/context/plan-{architect,techlead}-report.md`
**plan_revision:** 5
**status:** Approved
**Created:** 2026-09-25
**Tasks:** 10
**Estimated complexity:** 4 complex, 6 standard
**Series:** Plan A `2026-09-25-reviewer-subprocess-foundation-plan.md` (PREREQUISITE — must be merged to `main` first; this plan uses `scripts/lib/model-subprocess.sh` access mode `none`, `zms_client_available`, the `ZUVO_CODEX_BIN`/`ZUVO_CLAUDE_BIN` seams in detection (a set `ZUVO_CODEX_BIN` is final), Plan A's install of `~/.zuvo/model-subprocess.sh`, and `ZUVO_CODEX_EFFORT_AUDIT`) → Plan B (this) → Plan C `2026-09-25-cross-vendor-reviewer-routing-plan.md`.

**Concurrency warning:** another session commits to `main`; `scripts/adversarial-review.sh` is the hottest file in the repo (55 commits / 30 days). Re-read the exact region before every edit; never edit or install `~/.zuvo/adversarial-review` while a review run is using it. **Known live defect (from `7907fe70`):** the driver crashed with `claude_reviewer_model: command not found` (called at `:1774`, defined at `:2144`) whenever the `claude` lane is in the provider list AND the health bench runs (bench enabled, non-empty ledger) — i.e. every adversarial run from a Claude Code host on this machine. Plan A Task 1 fixes and installs it with a regression test; Task 4 below only re-runs that test.

## Architecture Summary

Today `scripts/blind-audit-codex.sh` runs ONE reviewer: `candidates[0]` of codex → agy → gemini → claude (`:128-150`), no failover (`exit 1`), stale inline defaults (`gpt-5.5`, `Gemini 3.1 Pro (High)`, `:161-171`), a dead `gemini` lane (`:256-272`), and a global-`CODEX_HOME` codex call (`:221-254`) that died on 2026-09-25 when the `codesift` MCP daemon hung. Its validator greps the four strict markers UNANCHORED (`:379-382`, `:396-416`) — and `blind-coverage-audit.md:123-127` contains all four verbatim, so a client that ECHOES the prompt passes (reproduced by QA).

The driver already has 11 lanes, host self-exclusion, a failed-provider cache, a health ledger and random sampling with `agy` pinned (`adversarial-review.sh:~1889-1957`). Plan B adds `--mode blind-audit`; the panel logic lives in a new sourced library so the 4247-line driver only gains wiring. Both libraries are installed next to `~/.zuvo/adversarial-review`, the path write-tests actually calls.

```mermaid
graph TD
  WT[skills/write-tests Step 3.5] -->|~/.zuvo/adversarial-review --mode blind-audit --production P --test T| DRV
  WRAP[scripts/blind-audit-codex.sh<br/>thin back-compat wrapper] --> DRV
  DRV[adversarial-review.sh --mode blind-audit] --> BAP[scripts/lib/blind-audit-panel.sh<br/>prompt · byte gates · anchored validation · merge · exit map]
  DRV --> LIB[scripts/lib/model-subprocess.sh access=none]
  DRV --> L1[agy pinned] & L2[random lane] & L3[random lane]
  DRV -->|mode=blind-audit rows| LOG[~/.zuvo/adversarial.log]
  LOG -. skipped .-> HOOK[hooks/post-skill-adversarial-check.sh]
  PROOF[--artifact proof] -. refused .-> PG[pipeline-gate-lib pg_artifact_proven]
  INS[install.sh → ~/.zuvo/{blind-audit-panel.sh, blind-coverage-audit.md}] --> DRV
```

## Technical Decisions

- **Input:** new flags `--production`, `--test` (required for a panel run), `--protocol` (optional) — valid ONLY in this mode (elsewhere exit 2). Stdin, `--diff`, `--files`, `--artifact`, `--append-artifact` rejected in this mode (exit 2). Empty production/test → exit 5. **`--list-providers --mode blind-audit` is exempt** from the `--production`/`--test` requirement (prints the post-exclusion panel candidates, exit 0); `--list-providers` WITHOUT the mode keeps today's output exactly.
- **`--provider <lane>` in this mode** runs exactly that one lane (a panel of 1 → at best `degraded`, exit 3 on a valid answer); this is how the back-compat wrapper selects a provider.
- **Protocol lookup** (`bap_find_protocol <driver_dir> [--protocol value]` — `$dir` is the DRIVER's directory, passed in by the driver, never the library's own): `--protocol` → `<driver_dir>/../shared/includes/blind-coverage-audit.md` only if `<driver_dir>/../skills` exists → `~/.zuvo/blind-coverage-audit.md` (installed in Task 7) → exit 2. Must contain a line `Audit mode: strict`.
- **Library lookup** (same order as `model-subprocess.sh`): `$dir/lib/blind-audit-panel.sh` → `$dir/blind-audit-panel.sh` → `$HOME/.zuvo/blind-audit-panel.sh`; missing → the mode exits 2 with a message naming the file (other modes unaffected).
- **Prompt:** protocol + `=== PRODUCTION FILE: <basename> ===` + file + `=== TEST FILE: <basename> ===` + file + "Return only the required strict output block". Basenames only. No FOCUS, no language line, no SEVERITY instructions. Character caps (`:651-660`), chunking (`:776`) and truncation (`:944-980`) SKIPPED in this mode.
- **Byte gates (`wc -c`, never `${#var}`):** > `ZUVO_BLIND_AUDIT_ARGV_MAX` (120000) → drop argv lanes `agy`, `kimi` with a loud stderr line; > `ZUVO_BLIND_AUDIT_MAX_BYTES` (400000) → **exit 6** before any dispatch. Nothing is ever shortened.
- **Panel:** `ZUVO_BLIND_AUDIT_PANEL` — DEFAULT 3, overridable (tests set 5 to see every spy); global `ZUVO_REVIEW_MAX_PROVIDERS` ignored here; existing pin (`ZUVO_REVIEW_PIN_PROVIDERS`, default `agy`) + random fill; ≤ panel available → all run. The `--multi` < 2 refusal (`:3033-3053`) is skipped; always parallel. `ZUVO_REVIEW_PROVIDER_PICK=ranked` ignores pins — the pin is only testable in the default random mode. No replacement/top-up round when a lane returns invalid output (deferred: Plan C backlog item).
- **Host exclusion by VENDOR in this mode** (cross-vendor; matches the old wrapper): Claude → `claude`; Codex → `codex-5.3`,`codex-5.4`; Antigravity → `agy`,`gemini`; Cursor → `cursor-agent`; Kimi → `kimi`,`kimi-api`; Qwen → `qwen`. `--list-providers --mode blind-audit` applies it (today `--list-providers` exits at `:~1661`, BEFORE exclusion at `:~1697` — moved for THIS mode only).
- **Isolation allowlist** `ZUVO_BLIND_AUDIT_ALLOWLIST` (default = the lanes that passed Task 1's spike; a lane not on it is excluded in this mode): codex, claude → library access `none`; agy → neutral cwd (+ `--mode plan`/`--sandbox` if the spike showed they are needed); cursor-agent → neutral cwd + `--workspace <neutral>` only if P8 passed; muse → empty workspace only if P9 passed; kimi, qwen → already isolated (no tools / `--max-tool-calls 0`); openrouter, byteplus, kimi-api, codestral → HTTP. A spike that fails EXCLUDES the lane (`[DECISION: <lane>-isolation] → excluded`). If agy is excluded that contradicts the settled "agy pinned" → `[DEVIATION]` in this plan's Review Trail, surfaced to the user BEFORE any code is written (Task 1 halts).
- **Effort:** codex lanes use `ZUVO_CODEX_EFFORT_AUDIT` (high); `ZUVO_BLIND_AUDIT_EFFORT` honoured as override.
- **Validation (anti-echo):** anchored `^Audit mode: strict$`, `^Coverage verdict: (CLEAN|FIX|REWRITE)$`, `^INVENTORY COMPLETE: [0-9]+ rows`, the exact table header; text taken from the first `Audit mode:` line (handles agy's fallback banner); REJECT if the block contains the protocol template row `| B1 | branch | 18-24 | owned | FULL | file.test.ts:42-58 | verifies empty guard |` or the literal `Coverage verdict: CLEAN|FIX|REWRITE`. Failure → outcome `invalid`, kept by `preserve_failure_evidence`.
- **Merge:** worst verdict (REWRITE > FIX > CLEAN); table = union of rows whose coverage is not `FULL`/`N/A` from all valid answers, id prefixed with provider (`agy:B3`), note suffixed `[agy]`, no duplicate guessing; `INVENTORY COMPLETE:` = max reported; "Prioritized findings" / "Highest-value missing test" kept per provider; second line `Audit panel: strict|degraded valid=k/m providers=… verdicts=a:FIX,b:CLEAN failed=c:timeout`.
- **Exit codes in this mode:** 0 strict (≥ 2 valid, block printed); 3 degraded (exactly 1 valid, block printed); 2 no valid answer (stdout empty); 1 no provider after exclusions; 5 empty input; 6 input too large; 124/125/130/143 as today. Exit 4 cannot occur.
- **Output:** text stdout = merged block only; diagnostics stderr. `--json` → `{status, mode, verdict, valid_providers[], provider_outcomes, prompt_bytes, excluded_argv_lanes[], merged_block, results{}}`.
- **Timeouts:** per-provider `ZUVO_BLIND_AUDIT_TIMEOUT=480` (`ZUVO_REVIEW_TIMEOUT` ignored in this mode); whole-run deadline = timeout + grace + 60 ≈ 555 s; values > 510 clamped with a warning. In Claude Code a Bash call over its timeout is moved to the background — the skill passes `timeout: 600000` and treats "moved to background" as wait-and-read, never as `BLOCKED_INFRA`.
- **Gate integrity (Task 2, before the mode exists):** `post-skill-adversarial-check.sh` ignores `adversarial.log` rows whose col 3 is `blind-audit`; `pg_artifact_proven` returns 1 for a proof containing `mode=blind-audit`. **Health ledger in this mode:** outcomes caused by the INPUT or the prompt (`timeout`, `empty`, `invalid`) are NOT recorded; `ok`, `auth`, `quota` ARE recorded, because they describe the lane's account, not this input — a lane whose login expired is benched for both modes, which is correct.
- **Wrapper:** `blind-audit-codex.sh` stays (installed/checked in six places) as a thin wrapper: same argv and env; the driver has NO `--model`/`--effort`/`--timeout` flags, so the wrapper maps them to env (`--timeout`→`ZUVO_BLIND_AUDIT_TIMEOUT`, `--effort`→`ZUVO_BLIND_AUDIT_EFFORT`, `--model` with `--provider codex`→`ZUVO_MODEL_CODEX_PRIMARY`, with `--provider claude`→ BOTH `ZUVO_CLAUDE_REVIEWER_MODEL` and `ZUVO_MODEL_CLAUDE_REVIEWER_OPUS`, with `--provider agy`→`ZUVO_AGY_MODEL`; `--model` without `--provider` → warning, ignored); no 600 s forwarding; `codex`→`codex-5.3`, `gemini` → exit 2 ("lane removed 2026-08-04"); without `--provider` the wrapper runs the full panel; driver exit 0|3 → 0, 5|6 → 2, else 1; stdout = merged block. No own `codex exec`, no own marker grep (CQ14).
- **Write-tests Step 3.5 contract (Task 9):** the lane→agent table (`test-reviewer-routing.md:101-106`) is REPLACED by a panel-outcome table: `Audit panel: strict` + CLEAN → `clean:strict`; `Audit panel: degraded` + CLEAN → `clean:degraded`; FIX/REWRITE unchanged; driver exit 1/2 → fallback to the in-harness `blind-coverage-auditor` agent routed by the CURRENT router lanes (Plan C re-points this sentence to `--fallback`), recorded `clean:degraded` at best with `degraded:same-vendor`; exit 5/6 → fix the input. No routing condition in the strict row. The `blind-audit-codex.sh` "canonical fresh-subprocess fallback" section is removed.
- **Size budget (CQ11):** panel logic lives in `blind-audit-panel.sh` (≤ 400 executable lines; the 100-line utility default does not fit a merge/validation library). The driver grows by at most ~150 lines of MECHANICAL wiring (flag parsing, mode branches, hook calls) — every decision (validation, merge, exit mapping, byte gates, exclusion table) lives in the library.

## Quality Strategy

- **How to run (IMPORTANT):** the local hook `~/.claude/hooks/farm-no-local-tests.sh` blocks `bash`/`/bin/bash` on paths under `tests/` unless the command starts with `TF_ALLOW_LOCAL=1 ` and contains no `;`, `&`, `|`, `$(`; testing.md §5 forbids `rt` for hook tests. Every Verify line is a LIST of separate commands, each must exit 0; test scripts run as `TF_ALLOW_LOCAL=1 bash tests/…`. Files under `tests/adversarial/` run only in `ZUVO_TEST_SCOPE=full`, so the Verify lists them explicitly. Acceptance Proofs are bare commands whose own exit code is the verdict.
- **Hermeticity** as in Plan A: `HOME=tmp`, fixture `CODEX_HOME` with dummy `auth.json`, own `ZUVO_HOME`, explicit `PATH` (never `~/.kimi-code/bin`) whose FIRST entry is a shim dir holding symlinks to the real `timeout`/`gtimeout`/`jq` (resolved with `command -v` before narrowing PATH — macOS `/usr/bin:/bin` has no `timeout` and the driver exits 1 at `:~3368` without it), every host signal cleared before setting the one under test, `ZUVO_CODEX_BIN=/nonexistent ZUVO_CODEX_APP_BIN=/nonexistent` unless the case needs a codex spy. Harness env for mock panels: `ZUVO_ADVERSARIAL_TEST_HARNESS=1`, `ZUVO_REVIEW_TEST_PROVIDERS=…`, `ZUVO_PROVIDER_BENCH=0` (except ledger cases). Existing mocks used: `mock-success`, `mock-fail`, `mock-timeout` (`tests/adversarial/mocks/`); new ones are listed in Task 4.
- **Two layers of tests:** mocks prove panel size, merge and exit logic ONLY; SPIES named after real lanes, dispatched through the REAL runners, prove per-lane isolation (QA Q3). Every spy case first asserts its `.rec` exists.
- New tests in `tests/hooks/test-*.sh` (default suite); edited bats in place; smoke runner `tests/hooks/smoke-blind-audit.sh` (not globbed by run-all).
- **Full-suite rule (final task):** `RESULT: PASS=n FAIL=0`; the ONLY exception is a child listed in the Plan A baseline file that fails identically when re-run alone in a throwaway worktree of the pre-plan commit (testing.md §6b), both outputs recorded.
- **CQ gates:** CQ3, CQ5 (no provider stderr secrets in `adversarial.log`), CQ6 (byte caps before dispatch; multi-byte RED), CQ8, CQ11 (see Size budget), CQ14 (one validator, one exclusion implementation — preflight's own block at `:104-121` deleted), CQ19 (merged-block contract, JSON shape, exit table incl. the double meaning of 3), CQ21/22. Shellcheck ratchet 0; bash 3.2.

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| G4 | Blind audit runs through `adversarial-review.sh` as a panel of 3: `agy` pinned + 2 random | requirement | Task 1, Task 4, Task 5, Task 10 | spike proves feasibility; pin tested in random mode |
| K1 | Every blind-audit lane isolated: neutral cwd, no repo access, no MCP; unprovable lanes excluded | constraint | Task 1, Task 4 | spike P4/P8/P9 + allowlist + spies |
| K2 | Codex effort `high` in blind audit (not the adversarial `none`) | constraint | Task 4 | `ZUVO_CODEX_EFFORT_AUDIT` |
| K5 | Whole production + test file; no truncation/chunking; oversize fails loudly; argv limit measured in bytes | constraint | Task 3, Task 4 | exits 6 / argv-lane drop |
| K6 | Per-provider strict-block validation; invalid output counts as that provider failing | requirement | Task 1, Task 3, Task 5 | anchored + anti-echo; spike runs the real prompt |
| K7 | Merge: worst verdict, union of uncovered rows with attribution, strict PASS needs ≥ 2 valid, else degraded | requirement | Task 3, Task 5 | |
| K8 | `blind-audit-codex.sh` becomes a thin back-compat wrapper; dead `gemini` lane + stale defaults gone | requirement | Task 6 | |
| K9 | `test-reviewer-routing.md` stale client-health table + hand-rolled agy block removed; write-tests Step 3.5 uses the panel with no routing condition | requirement | Task 9 | |
| K12 | New behaviour tested in the default suite | constraint | Tasks 2-9 | per-task `tests/hooks/test-*.sh` + bats; the smoke runner only chains them |
| X1 | Blind-audit rows/proofs never count as an adversarial review; input-caused blind-audit failures do not bench lanes | requirement (derived, architect defect 7) | Task 2, Task 5 | lands before the mode exists |
| X2 | Preflight candidate list = the driver's blind-audit panel candidates (no duplicate exclusion logic) | requirement (derived, defect 8) | Task 8 | |
| X6 | The mode works from the INSTALLED `~/.zuvo/adversarial-review` (panel lib + protocol installed) | requirement (derived, reviewer CRITICAL) | Task 7 | |

## Review Trail
- Phase 1: full fan-out (shared with Plan A; reports in `zuvo/context/`)
- Plan reviewer: revision 1 → ISSUES FOUND (1 critical: panel library never installed next to `~/.zuvo/adversarial-review`; warnings: pin untested under `ranked`, ledger asserted in the wrong file, wrapper bats reaching real Codex, driver lacks `--model/--effort/--timeout`, five-spy case unrealisable, file lists, unproven cursor/muse isolation, Step 3.5 still tied to routing, `--list-providers` contradiction, nondeterministic live smoke) — applied in revision 2
- Plan reviewer: revision 2 → ISSUES FOUND (0 critical: `timeout` missing from hermetic PATH; pin test named non-existent mocks; benched pinned lane; wrapper `--model` mappings; unprefixed gate command) — applied in revision 3
- Plan reviewer: revision 3 → only finding resolved by Plan A option (a) → APPROVED
- Cross-model validation: executed on revision 3 → 5 providers (agy, codex-5.3, byteplus, byteplus-3, kimi; `claude` excluded — installed driver crashes on it, see Concurrency warning) → fixed in revision 4: isolation probes moved into an up-front spike Task 1 that also runs the REAL blind-audit prompt per lane (agy CRITICAL, byteplus-3, kimi); Task 6 split into install (Task 7) and preflight (Task 8) (agy, byteplus, byteplus-3, kimi); five-spy case vs panel cap → `ZUVO_BLIND_AUDIT_PANEL` is a default, overridable (codex CRITICAL, kimi); live smoke host-aware (agy CRITICAL); `--provider` semantics in this mode defined (agy); allowlist made a variable with a real negative RED case (byteplus); `--list-providers` non-blind-audit output pinned (kimi); X1 vs auth/quota wording (byteplus); CQ11 re-baselined to mechanical wiring (byteplus); protocol lookup base dir defined (byteplus); installed-driver test also asserts `model-subprocess.sh` present (codex); "by hand:" prefix removed (agy). Rejected with reasons: undeclared `mock-fail`/`mock-timeout` (kimi, byteplus — both exist in `tests/adversarial/mocks/`); protocol installed before Task 9 edits it (agy — the test `cmp`s against the repo copy at test time; the real install happens at release); retry/monitoring tasks (byteplus-3, codex — top-up round is an explicit Plan C backlog item); Task 9 file count (agy — docs-only, 5 files, within rule 2).
- Plan reviewer (post-adversarial re-review of revision 4): ISSUES FOUND (warnings: Task 4's crash RED could not fail with the bench disabled; Task 1's DECISION grep already matched the plan's own prose; crash-condition wording) — applied in revision 5: the crash fix moved to Plan A Task 1 (Task 4 only checks its regression test), DECISION grep anchored to the Review Trail entry format with a `-eq 0` pre-state, wording now names the bench condition. Per the stop rule (one post-adversarial re-review), no further reviewer pass — handed to the user for approval.
- Status gate: Approved 2026-09-25T03:41:32Z — the user approved the three items in-session ("1. … 2. ok 3. ok"); per the user's standing rule (no separate approval gate; zuvo:plan is always followed by zuvo:execute) the reviewed plans were approved without an extra prompt. Execution order A → B → C, each merged before the next.

## Task Breakdown

### Task 1: Spike — lane isolation and real-prompt feasibility (agy, cursor-agent, muse)
**Files:** `docs/specs/2026-09-25-blind-audit-panel-plan.md` (Review Trail + allowlist decision lines only)
**Surface:** integration
**Complexity:** standard
**Dependencies:** none
**Failure:** halt
**Execution routing:** default implementation tier

- [ ] RED: spike — no production code. Pre-state: `test "$(grep -cE '^- \[DECISION: (agy|cursor-agent|muse)-isolation\] → (allowed|excluded)' docs/specs/2026-09-25-blind-audit-panel-plan.md)" -eq 0` (the plan's own prose mentions the marker, so only the Review Trail ENTRY format is counted).
- [ ] GREEN (live probes, recorded like Plan A's; transcripts `zuvo/proofs/probe-{4,8,9}-*-2026-09-25.txt`, one commit-message line each): for **P4** agy (print mode, neutral cwd, with and without `--mode plan`/`--sandbox`), **P8** cursor-agent (`--mode ask --workspace <neutral>`, neutral cwd), **P9** muse (empty `--workspace`):
  1. isolation: the planted-file token (absolute path given in the prompt) is ABSENT from stdout+stderr;
  2. answer: "product of 6 and 7" → `42`;
  3. real prompt: send the REAL `blind-coverage-audit.md` protocol + a tiny inline production/test pair (written to a tmp dir, one deliberately untested branch) and check the raw reply against the anchored markers (`^Audit mode: strict$`, `^Coverage verdict: (CLEAN|FIX|REWRITE)$`, `^INVENTORY COMPLETE: [0-9]+ rows`, the exact table header) — record pass/fail and any banner/fence the validator will have to strip.
  Write one Review Trail line per lane, EXACTLY in the form `- [DECISION: <lane>-isolation] → allowed (flags: …; transcript: …)` or `- [DECISION: <lane>-isolation] → excluded (reason; transcript: …)`, and set the default `ZUVO_BLIND_AUDIT_ALLOWLIST` value in Technical Decisions accordingly. If agy is excluded: add `[DEVIATION: agy pin → excluded, reason]` and HALT the run for the user's decision (the settled "agy pinned" cannot silently change).
- [ ] Verify (each separately, exit 0):
  - `test -s zuvo/proofs/probe-4-agy-2026-09-25.txt`
  - `test -s zuvo/proofs/probe-8-cursor-agent-2026-09-25.txt`
  - `test -s zuvo/proofs/probe-9-muse-2026-09-25.txt`
  - `test "$(grep -cE '^- \[DECISION: (agy|cursor-agent|muse)-isolation\] → (allowed|excluded)' docs/specs/2026-09-25-blind-audit-panel-plan.md)" -ge 3`
- [ ] Acceptance Proof:
  - G4 / K1 / K6
    - Surface: integration
    - Proof: `test "$(grep -cE '^- \[DECISION: (agy|cursor-agent|muse)-isolation\] → (allowed|excluded)' docs/specs/2026-09-25-blind-audit-panel-plan.md)" -ge 3`
    - Expected: exit 0; each DECISION line cites its transcript; agy `→ allowed` (else the run has halted on the DEVIATION)
    - Artifact: `zuvo/proofs/plan-b-task-1-report.md`, `zuvo/proofs/probe-{4,8,9}-*-2026-09-25.txt`
- [ ] Commit: `docs(blind-audit): which lanes can be isolated and still answer the real audit prompt — measured before building the panel` (body: probe lines)

### Task 2: Gate integrity — a blind audit is never counted as an adversarial review
**Files:** `hooks/post-skill-adversarial-check.sh`, `hooks/lib/pipeline-gate-lib.sh`, `tests/hooks/test-post-skill-adversarial-check.sh`, `tests/hooks/test-pipeline-gate-lib.sh`
**Surface:** backend-logic
**Complexity:** standard
**Dependencies:** none
**Failure:** halt
**Execution routing:** default implementation tier

- [ ] RED:
  - `test-post-skill-adversarial-check.sh`: fixture `adversarial.log` (in `HOME=tmp`) whose ONLY recent row has col 3 = `blind-audit` → the hook still prints its "no adversarial review" reminder (FOUND stays false); a `code` row in the same window → FOUND true (existing behaviour preserved).
  - `test-pipeline-gate-lib.sh`: a proof file with two `REVIEW BY:` lines and a `mode=blind-audit` line → `pg_artifact_proven` returns 1; the same proof with `mode=code` → 0.
- [ ] GREEN: in the awk at `post-skill-adversarial-check.sh:~64-68` add `$3 == "blind-audit" { next }`; in `pg_artifact_proven` (`pipeline-gate-lib.sh:~380-392`) return 1 when the proof has the exact `mode=` line format `write_artifact` emits with value `blind-audit` (read `write_artifact` first).
- [ ] Verify (each separately, exit 0):
  - `TF_ALLOW_LOCAL=1 bash tests/hooks/test-post-skill-adversarial-check.sh`
  - `TF_ALLOW_LOCAL=1 bash tests/hooks/test-pipeline-gate-lib.sh`
  - `shellcheck -x -S warning hooks/post-skill-adversarial-check.sh hooks/lib/pipeline-gate-lib.sh`
- [ ] Acceptance Proof:
  - X1
    - Surface: backend-logic
    - Proof: `TF_ALLOW_LOCAL=1 bash tests/hooks/test-pipeline-gate-lib.sh` and `TF_ALLOW_LOCAL=1 bash tests/hooks/test-post-skill-adversarial-check.sh`
    - Expected: both exit 0
    - Artifact: `zuvo/proofs/plan-b-task-2-report.md`
- [ ] Commit: `fix(gates): a blind coverage audit must not stand in for an adversarial review`

### Task 3: Panel library — prompt assembly, byte gates, anchored validation, merge, exit mapping
**Files:** `scripts/lib/blind-audit-panel.sh` (new), `tests/hooks/test-blind-audit-panel.sh` (new), `tests/hooks/fixtures/blind-audit/{clean,fix,rewrite,banner-prefixed,echo-of-protocol,template-row}.txt` (new fixtures)
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** Task 1
**Failure:** halt
**Execution routing:** deep implementation tier

(Depends on Task 1 for the banner/fence shapes the spike recorded — the validator must strip exactly those.)

- [ ] RED: `tests/hooks/test-blind-audit-panel.sh` sources the library (also under `/bin/bash`):
  - `bap_build_prompt <protocol> <prod> <test>`: output starts with the protocol, contains `=== PRODUCTION FILE: <basename> ===` and `=== TEST FILE: <basename> ===` in that order, contains NO absolute path of either file, no `SEVERITY`, no FOCUS text, ends with the "Return only the required strict output block" line;
  - `bap_find_protocol <driver_dir>`: `--protocol` wins; `<driver_dir>/../shared/includes/…` only when `<driver_dir>/../skills` exists (called with the repo's `scripts/` dir it finds the repo protocol; called with the LIBRARY's dir `scripts/lib` it must NOT be used — the test passes the driver dir explicitly); `$HOME/.zuvo/blind-coverage-audit.md` next; none → non-zero; a protocol without an `Audit mode: strict` line → non-zero;
  - `bap_bytes`: a multi-byte file whose CHARACTER count is below 120000 but BYTE count above → classified "over argv limit" (run under `LC_ALL=C.UTF-8` if available);
  - `bap_validate`: fixtures `clean`, `fix`, `rewrite` valid; `banner-prefixed` (using the banner shape Task 1 recorded) valid and returned WITHOUT the banner; `echo-of-protocol` INVALID; `template-row` INVALID; literal `Coverage verdict: CLEAN|FIX|REWRITE` INVALID; missing table header INVALID;
  - `bap_merge` over (clean from p1, fix from p2, rewrite from p3): line 1 `Audit mode: strict`, line 2 `Audit panel: strict valid=3/3 providers=p1,p2,p3 verdicts=p1:CLEAN,p2:FIX,p3:REWRITE`, `Coverage verdict: REWRITE`, `INVENTORY COMPLETE:` = max of the three, every non-FULL/N/A row once per provider with id `pN:<id>` and note suffix `[pN]`, FULL rows absent, output byte-identical across two calls;
  - `bap_merge` with one valid → `Audit panel: degraded valid=1/…`; `bap_exit_code` k ≥ 2 → 0, k = 1 → 3, k = 0 → 2;
  - `bap_vendor_excluded <host>` returns the vendor-exclusion list of Technical Decisions for each host.
- [ ] GREEN: `scripts/lib/blind-audit-panel.sh` (prefix `bap_`, bash 3.2, awk for table parsing, ≤ 400 executable lines) per Technical Decisions.
- [ ] Verify (each separately, exit 0):
  - `TF_ALLOW_LOCAL=1 bash tests/hooks/test-blind-audit-panel.sh`
  - `TF_ALLOW_LOCAL=1 /bin/bash tests/hooks/test-blind-audit-panel.sh`
  - `shellcheck -x -S warning scripts/lib/blind-audit-panel.sh`
- [ ] Acceptance Proof:
  - K5 / K6 / K7
    - Surface: backend-logic
    - Proof: `TF_ALLOW_LOCAL=1 bash tests/hooks/test-blind-audit-panel.sh`
    - Expected: exit 0; the output lists the executed `echo-of-protocol` case
    - Artifact: `zuvo/proofs/plan-b-task-3-report.md`
- [ ] Commit: `feat(blind-audit): panel library — whole-file prompt, byte limits, anti-echo validation, worst-verdict merge`

### Task 4: Driver `--mode blind-audit` — input, isolation, panel dispatch
**Files:** `scripts/adversarial-review.sh`, `scripts/lib/blind-audit-panel.sh`, `tests/hooks/test-adversarial-blind-audit.sh` (new), `tests/adversarial/test-provider-fanout-cap.sh`, `tests/adversarial/mocks/{mock-strict-clean,mock-strict-fix,mock-strict-rewrite,mock-invalid-block,mock-echo-prompt}` (new fixtures)
**Surface:** integration
**Complexity:** complex
**Dependencies:** Task 1, Task 2, Task 3
**Failure:** halt
**Execution routing:** deep implementation tier

(The edge to Task 2 is ordering only: gate integrity must land before the mode exists.)

- [ ] Precondition check: `TF_ALLOW_LOCAL=1 bash tests/hooks/test-adversarial-claude-lane-bench.sh` (Plan A Task 1) exits 0; if not, STOP — Plan A is not fully merged.
- [ ] RED: `tests/hooks/test-adversarial-blind-audit.sh` (dispatch half; hermetic env):
  - flags: `--mode blind-audit` without `--production`/`--test` → exit 2; `--production` outside the mode → exit 2; `--files`, `--diff`, stdin, `--artifact`, `--append-artifact` in the mode → exit 2; `--list-providers --mode blind-audit` WITHOUT `--production`/`--test` → exit 0 and prints candidates; `--list-providers` WITHOUT the mode prints byte-identically to HEAD's output for the same env (captured before GREEN); empty production file → exit 5; production file of 400001 bytes → exit 6 and NO spy `.rec`/mock invocation;
  - `--provider mock-strict-clean` in the mode → exactly that one lane runs, exit 3, `Audit panel: degraded valid=1/1`;
  - a 60000-char production file (above the 30k code cap) reaches the provider whole: `mock-echo-prompt`/spy stdin sha == `bap_build_prompt` sha; no "truncated"/chunk lines on stderr;
  - argv lanes: prompt > 120000 bytes → `agy` and `kimi` dropped with a stderr line naming them; stdin lanes still dispatched;
  - panel size: 5 test providers with `ZUVO_REVIEW_PROVIDER_PICK=ranked` → exactly 3 run and `ZUVO_REVIEW_MAX_PROVIDERS=5` is ignored; `ZUVO_BLIND_AUDIT_PANEL=5` → 5 run;
  - **pin (default random mode):** `ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix mock-strict-rewrite mock-invalid-block agy"` with an `agy` spy printing a valid strict block, pick mode NOT set, 10 runs → `agy` in all 10 panels of 3;
  - vendor exclusion, each as its own case with all other signals cleared: `CLAUDECODE=1` → `claude` excluded; each Codex signal → `codex-5.3` and `codex-5.4` excluded; kimi host → `kimi`,`kimi-api` excluded; `--list-providers --mode blind-audit` prints the post-exclusion list;
  - isolation via SPIES through the real runners, ALL host signals cleared, explicit PATH, `ZUVO_BLIND_AUDIT_PANEL=5`, `ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 claude agy cursor-agent kimi"`: codex `.rec` shows neutral pwd/OLDPWD, isolated `CODEX_HOME`, `model_reasoning_effort = "high"`, `sandbox_mode = "read-only"`; claude `.rec` shows access-`none` flags; agy pwd neutral (+ spike flags); cursor-agent `--workspace <neutral>` and neutral pwd (or no `.rec` if the spike excluded it); kimi pwd == run tmpdir;
  - allowlist negative case: the same five spies with `ZUVO_BLIND_AUDIT_ALLOWLIST="codex-5.3 claude kimi"` → `agy` and `cursor-agent` have NO `.rec` and stderr names them as excluded;
  - `--mode code` behaviour unchanged: Plan A's `test-adversarial-lane-golden.sh` still passes;
  - update `test-provider-fanout-cap.sh` MODE.1 (error text lists `blind-audit`) and MODE.3 (does not loop `--files` through `blind-audit`).
- [ ] GREEN: wire the mode: help (`:~325`), mode check (`:~460`), new flags + rejections + the `--list-providers` exemption, `--provider` = single-lane panel, skip caps/chunking/truncation, prompt → `bap_build_prompt`, byte gates → `bap_bytes`, vendor exclusion via `bap_vendor_excluded` (moved before the `--list-providers` exit for this mode only), allowlist `ZUVO_BLIND_AUDIT_ALLOWLIST`, codex/claude via `zms_run_* --access none`, agy/cursor neutral cwd, effort `ZUVO_CODEX_EFFORT_AUDIT`, panel size `ZUVO_BLIND_AUDIT_PANEL` (default 3) with the pin applied, skip the `--multi` refusal, timeout defaults/clamp, library lookup per Technical Decisions.
- [ ] Verify (each separately, exit 0):
  - `TF_ALLOW_LOCAL=1 bash tests/hooks/test-adversarial-blind-audit.sh`
  - `TF_ALLOW_LOCAL=1 bash tests/hooks/test-adversarial-lane-golden.sh`
  - `bats scripts/tests/adversarial-review.bats`
  - `shellcheck -x -S warning scripts/adversarial-review.sh scripts/lib/blind-audit-panel.sh`
  - `TF_ALLOW_LOCAL=1 bash tests/adversarial/test-provider-fanout-cap.sh` (full-scope file — not in run-all, so run here)
- [ ] Acceptance Proof:
  - G4 / K1 / K2 / K5
    - Surface: integration
    - Proof: `TF_ALLOW_LOCAL=1 bash tests/hooks/test-adversarial-blind-audit.sh`
    - Expected: exit 0
    - Artifact: `zuvo/proofs/plan-b-task-4-report.md`
- [ ] Commit: `feat(adversarial): --mode blind-audit dispatches a 3-provider isolated panel over the whole file pair`

### Task 5: Driver `--mode blind-audit` — collection, merge, output, ledger and log
**Files:** `scripts/adversarial-review.sh`, `scripts/lib/blind-audit-panel.sh`, `tests/hooks/test-adversarial-blind-audit.sh`, `docs/adversarial-providers.md`
**Surface:** integration
**Complexity:** complex
**Dependencies:** Task 3, Task 4
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED (collection half of `test-adversarial-blind-audit.sh`):
  - `mock-strict-clean mock-strict-fix mock-strict-rewrite` → exit 0; stdout line 1 `Audit mode: strict`; `Audit panel: strict valid=3/3`; `Coverage verdict: REWRITE`; rows carry `mock-strict-fix:` / `mock-strict-rewrite:` prefixes;
  - swap one for `mock-echo-prompt` → exit 0, `valid=2/3`, the echo provider reported `invalid` on stderr and in `--json` `provider_outcomes`;
  - one valid (others `mock-invalid-block`, `mock-fail`) → exit 3, `Audit panel: degraded valid=1/3`;
  - none valid → exit 2 and stdout EMPTY (assert the exit code first, then emptiness);
  - `--json` has keys `status mode verdict valid_providers provider_outcomes prompt_bytes excluded_argv_lanes merged_block results`;
  - no "partial"/SEVERITY-count WARN on stderr in this mode;
  - health ledger — this case sets `ZUVO_PROVIDER_BENCH=1 ZUVO_PROVIDER_HEALTH_FILE=$T/health.tsv`: after a run with `mock-strict-clean`, `mock-invalid-block`, `mock-timeout`, `$T/health.tsv` has an `ok` row for the clean mock and NO rows for the other two; a mock that prints an auth stub IS recorded `auth`;
  - `adversarial.log` (`$ZUVO_HOME`): one row per provider with col 3 `blind-audit` and the findings column = number of uncovered rows;
  - `ZUVO_BLIND_AUDIT_TIMEOUT=900` → warning + clamp to 510; help text and the exit-code table list `3` (blind-audit: degraded) and `6`.
- [ ] GREEN: in the collect loop (`:~3706`) validate each result with `bap_validate` (outcome `invalid`, `preserve_failure_evidence` kept), merge with `bap_merge`, print text/JSON, map exit with `bap_exit_code`, skip `count_findings` for the mode, filter outcomes passed to `record_provider_health` (`:~3849`) per Technical Decisions, log rows with `mode=blind-audit`. Document the mode, flags, env vars and exit codes in `docs/adversarial-providers.md`.
- [ ] Verify (each separately, exit 0):
  - `TF_ALLOW_LOCAL=1 bash tests/hooks/test-adversarial-blind-audit.sh`
  - `TF_ALLOW_LOCAL=1 bash tests/hooks/test-adversarial-lane-golden.sh`
  - `bats scripts/tests/adversarial-review.bats`
  - `TF_ALLOW_LOCAL=1 bash tests/hooks/test-post-skill-adversarial-check.sh`
  - `shellcheck -x -S warning scripts/adversarial-review.sh scripts/lib/blind-audit-panel.sh`
- [ ] Acceptance Proof:
  - K6 / K7 / X1
    - Surface: integration
    - Proof: `TF_ALLOW_LOCAL=1 bash tests/hooks/test-adversarial-blind-audit.sh` (its collection half is SMOKE-B1's per-task RED copy)
    - Expected: exit 0
    - Artifact: `zuvo/proofs/plan-b-task-5-report.md`
- [ ] Commit: `feat(adversarial): blind-audit panel merges to the worst verdict and keeps input-caused failures out of the lane-health ledger`

### Task 6: `blind-audit-codex.sh` becomes a thin back-compat wrapper over the driver
**Files:** `scripts/blind-audit-codex.sh`, `scripts/tests/blind-audit-codex.bats`
**Surface:** integration
**Complexity:** standard
**Dependencies:** Task 5
**Failure:** halt
**Execution routing:** default implementation tier

- [ ] RED: `blind-audit-codex.bats` — `setup` adds `HOME=$(mktemp -d)`, a fixture `CODEX_HOME`, and exports `ZUVO_CODEX_BIN=/nonexistent ZUVO_CODEX_APP_BIN=/nonexistent` (the codex case points `ZUVO_CODEX_BIN` at the mock instead; a set `ZUVO_CODEX_BIN` is final per Plan A); keeps the isolated PATH (`/bin/bash` 3.2, `timeout`/`jq` symlinked in):
  - `--provider codex` with a codex mock that answers `--version` and writes the strict block to STDOUT → wrapper exit 0, stdout line 1 `Audit mode: strict`, a line `Audit panel: degraded valid=1/1`;
  - `--provider gemini` → exit 2, stderr contains `removed`;
  - `CLAUDECODE=1` → stderr has the "Host detected … auto-excluding" message, claude not invoked;
  - driver exit 6 (oversize fixture) → wrapper exit 2;
  - one case per mapped flag: `--timeout 300` → the driver sees `ZUVO_BLIND_AUDIT_TIMEOUT=300` (mock echoes its env to a file); `--effort medium` → `ZUVO_BLIND_AUDIT_EFFORT=medium`; `--provider codex --model gpt-test-x` → codex spy's `config.toml` model `gpt-test-x`; `--provider claude --model claude-test-y` → the claude spy's argv carries `--model claude-test-y` both with `CLAUDECODE=1` unset and via the Sonnet branch; `--provider agy --model agy-test-z` with an exported `ZUVO_MODEL_AGY=other` → the agy spy receives `agy-test-z`; no flags → `ZUVO_BLIND_AUDIT_TIMEOUT` NOT set by the wrapper (no clamp warning);
  - source lint: the wrapper contains no `codex exec` and no `INVENTORY COMPLETE` grep.
- [ ] GREEN: rewrite `blind-audit-codex.sh` (~418 → ~120 lines) per Technical Decisions; header comment: "back-compat only — call `adversarial-review --mode blind-audit` directly".
- [ ] Verify (each separately, exit 0):
  - `bats scripts/tests/blind-audit-codex.bats`
  - `shellcheck -x -S warning scripts/blind-audit-codex.sh`
- [ ] Acceptance Proof:
  - K8
    - Surface: integration
    - Proof: `bats scripts/tests/blind-audit-codex.bats`
    - Expected: exit 0
    - Artifact: `zuvo/proofs/plan-b-task-6-report.md`
- [ ] Commit: `refactor(blind-audit): the old single-provider wrapper now delegates to the panel`

### Task 7: Install the panel library and protocol next to `~/.zuvo/adversarial-review`
**Files:** `scripts/install.sh`, `tests/hooks/test-install-wiring.sh`
**Surface:** config
**Complexity:** standard
**Dependencies:** Task 4, Task 5
**Failure:** halt
**Execution routing:** default implementation tier

- [ ] RED: `test-install-wiring.sh` — after `install_zuvo_home` with `HOME=tmp`: `$HOME/.zuvo/blind-audit-panel.sh`, `$HOME/.zuvo/blind-coverage-audit.md` AND `$HOME/.zuvo/model-subprocess.sh` (from Plan A) exist and `cmp`-equal their repo sources; then the LONE installed driver `$HOME/.zuvo/adversarial-review --mode blind-audit --production P --test T` (no `--protocol`, harness mocks `mock-strict-clean mock-strict-fix`, PATH = timeout/jq shim dir + mocks + `/usr/bin:/bin`) exits 0 and prints `Audit panel: strict valid=2/2` — proving it found both the library and the protocol from `~/.zuvo` (FAILS today: neither is installed there).
- [ ] GREEN: add `scripts/lib/blind-audit-panel.sh` and `shared/includes/blind-coverage-audit.md` to the `install_zuvo_home` loop (`install.sh:~656-660`) with `cmp` verification.
- [ ] Verify (each separately, exit 0):
  - `TF_ALLOW_LOCAL=1 bash tests/hooks/test-install-wiring.sh`
  - `shellcheck -x -S warning scripts/install.sh`
- [ ] Acceptance Proof:
  - X6
    - Surface: config
    - Proof: `TF_ALLOW_LOCAL=1 bash tests/hooks/test-install-wiring.sh`
    - Expected: exit 0
    - Artifact: `zuvo/proofs/plan-b-task-7-report.md`
- [ ] Commit: `fix(install): the installed driver can run a blind-audit panel on its own`

### Task 8: Preflight probes exactly the panel's candidates
**Files:** `scripts/reviewer-preflight.sh`, `tests/hooks/test-reviewer-preflight-isolation.sh`
**Surface:** backend-logic
**Complexity:** standard
**Dependencies:** Task 4
**Failure:** halt
**Execution routing:** default implementation tier

- [ ] RED: `test-reviewer-preflight-isolation.sh` (Plan A's hermetic harness env): preflight's candidate list equals `adversarial-review --list-providers --mode blind-audit` under the same env; under `CLAUDECODE=1` `claude` is not a candidate; source lint: preflight no longer contains its own host-exclusion block (`:104-121`).
- [ ] GREEN: preflight takes candidates from the driver and deletes its exclusion block.
- [ ] Verify (each separately, exit 0):
  - `TF_ALLOW_LOCAL=1 bash tests/hooks/test-reviewer-preflight-isolation.sh`
  - `shellcheck -x -S warning scripts/reviewer-preflight.sh`
- [ ] Acceptance Proof:
  - X2
    - Surface: backend-logic
    - Proof: `TF_ALLOW_LOCAL=1 bash tests/hooks/test-reviewer-preflight-isolation.sh`
    - Expected: exit 0
    - Artifact: `zuvo/proofs/plan-b-task-8-report.md`
- [ ] Commit: `fix(preflight): probe exactly the reviewers the blind-audit panel would use`

### Task 9: Skill and include docs — Step 3.5 runs the panel, no routing condition
**Files:** `shared/includes/test-reviewer-routing.md`, `skills/write-tests/SKILL.md`, `shared/includes/blind-coverage-audit.md`, `shared/includes/retrospective.md`, `tests/skill-suite/test-write-tests-coverage-gate.sh`
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 5, Task 6, Task 7, Task 8
**Failure:** halt
**Execution routing:** default implementation tier

- [ ] RED (docs contract, extend `test-write-tests-coverage-gate.sh`):
  - `test-reviewer-routing.md` Step 3.5 names `adversarial-review --mode blind-audit --production` and `--test`; lists exits 0/3/2/1/5/6/124 with outcomes; the old lane→agent table (`reviewer_lane=review-primary` → `blind-coverage-auditor` rows) is GONE and replaced by the panel-outcome table + the "driver exit 1/2 → in-harness `blind-coverage-auditor`, `degraded:same-vendor`, `clean:degraded` at best" fallback; the "Canonical fresh-subprocess fallback" (`blind-audit-codex.sh`) section is gone; no `Known client health`, no `Gemini 3.1 Pro (High)`, no hand-rolled `agy -p "$(cat /tmp/blind-in.txt)"` block; `$ZUVO_BASE` via `~/.zuvo/zuvo-base`;
  - `skills/write-tests/SKILL.md` Step 3.5 outcome table: strict row `Audit panel: strict` + `CLEAN` → `clean:strict`, degraded row `Audit panel: degraded` + `CLEAN` → `clean:degraded`, NO "routing ok" / "degraded routing" wording (FAILS today, `:732-733`); the Bash call carries `timeout: 600000`; "moved to background" = wait and read the output file, not `BLOCKED_INFRA`;
  - `blind-coverage-audit.md` documents the merged block's `Audit panel:` second line (its own template markers stay — the anti-echo rule recognises them);
  - `retrospective.md`'s `blind_audit:` line becomes `blind_audit: <clean:strict|clean:degraded|fix:N|rewrite|skipped|blocked_infra> | panel=<strict|degraded> valid=<k>/<m> providers=<a,b,c> | exit=<code> | rows=<INVENTORY N> | uncovered=<n>`.
- [ ] GREEN: edit the four markdown files accordingly.
- [ ] Verify (each separately, exit 0):
  - `TF_ALLOW_LOCAL=1 bash tests/skill-suite/test-write-tests-coverage-gate.sh`
  - `bash scripts/validate-skills.sh`
  - `python3 scripts/gen-gate-copies.py`
  - `TF_ALLOW_LOCAL=1 bash tests/gates/test-gate-consistency.sh`
- [ ] Acceptance Proof:
  - K9 / G4
    - Surface: docs
    - Proof: `TF_ALLOW_LOCAL=1 bash tests/skill-suite/test-write-tests-coverage-gate.sh`
    - Expected: exit 0
    - Artifact: `zuvo/proofs/plan-b-task-9-report.md`
- [ ] Commit: `docs(write-tests): Step 3.5 audits through the 3-provider panel; strictness comes from the panel, not from routing`

### Task 10: Plan B smoke runner (mock panel always; live panel on demand) + full verification
**Files:** `tests/hooks/smoke-blind-audit.sh` (new), `tests/hooks/fixtures/blind-audit-live/{sum.sh,sum.test.sh}` (new fixtures — a tiny production function with one deliberately untested branch)
**Surface:** integration
**Complexity:** standard
**Dependencies:** Task 5, Task 6, Task 7, Task 8, Task 9
**Failure:** halt
**Execution routing:** default implementation tier

- [ ] RED: author `tests/hooks/smoke-blind-audit.sh` (named `smoke-*`, not globbed by run-all). Always runs SMOKE-B1. Runs SMOKE-B2 only with `ZUVO_LIVE_SMOKE=1`, otherwise prints `SKIP live`. Exit contract: `0` = all executed parts passed; `75` (EX_TEMPFAIL) = the live panel got < 2 valid answers AND every failed provider's outcome is `timeout`/`auth`/`quota`/`unavailable`; `1` = anything else. Executed-check count must be > 0.
- [ ] GREEN: no production change expected; a smoke failure is fixed in the owning file with its own RED case.
- [ ] Verify (each separately, exit 0):
  - `TF_ALLOW_LOCAL=1 bash tests/hooks/smoke-blind-audit.sh`
  - `bash scripts/validate-skills.sh`
  - `python3 scripts/gen-gate-copies.py`
  - `TF_ALLOW_LOCAL=1 bash tests/gates/test-gate-consistency.sh`
  - `python3 scripts/audit-registry-integrity.py --strict`
  - `TF_ALLOW_LOCAL=1 bash tests/run-all.sh`
  Expected: `RESULT: PASS=n FAIL=0` (full-suite rule in Quality Strategy).
- [ ] Acceptance Proof:
  - G4 / K6 / K7 / X1 / K12
    - Surface: integration
    - Proof: `TF_ALLOW_LOCAL=1 ZUVO_LIVE_SMOKE=1 bash tests/hooks/smoke-blind-audit.sh`
    - Expected: exit 0 per SMOKE-B2. Exit 75 → reported `BLOCKED_INFRA` (provider outage) to the user, not retried as a code failure; exit 1 → task BLOCKED, fix and re-run.
    - Artifact: `zuvo/proofs/plan-b-task-10-report.md` (+ `zuvo/proofs/smoke-plan-b.txt`)
- [ ] Commit: `test(blind-audit): smoke — mock panel always, live 3-provider panel on demand`

## Whole-feature Smoke Proofs

- **SMOKE-B1 — mock panel end to end, gates unaffected**
  - Preconditions: `T=$(mktemp -d)`; hermetic env; `HOME=$T ZUVO_HOME=$T/.zuvo ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_PROVIDER_BENCH=0 ZUVO_CODEX_BIN=/nonexistent ZUVO_CODEX_APP_BIN=/nonexistent`; `$SHIM` = a dir with symlinks to the real `timeout`/`gtimeout`/`jq`; two small fixture files P and T2
  - Proof (inside the smoke runner):
    ```bash
    rc=0; out=$(env -u CLAUDECODE ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix mock-strict-rewrite" \
      PATH="$SHIM:tests/adversarial/mocks:/usr/bin:/bin" bash scripts/adversarial-review.sh --mode blind-audit --production P --test T2) || rc=$?
    [ "$rc" -eq 0 ] && printf '%s\n' "$out" | sed -n 1p | grep -qx 'Audit mode: strict' \
     && printf '%s\n' "$out" | grep -qx 'Coverage verdict: REWRITE' \
     && printf '%s\n' "$out" | grep -q '^Audit panel: strict valid=3/3' \
     && printf '%s\n' "$out" | grep -q 'mock-strict-fix:' \
     && awk -F'\t' '$1!="SUMMARY" && $3=="blind-audit"{n++} END{exit !(n==3)}' "$ZUVO_HOME/adversarial.log"
    ```
    then: the post-skill hook run with `HOME=$T` still prints its reminder; echo provider → `valid=2/3` exit 0; one valid → exit 3; none valid → exit 2 + empty stdout; 400001-byte input → exit 6 with no provider invoked.
  - Expected: every step exits as stated
  - Artifact: `zuvo/proofs/smoke-plan-b.txt`
  - RED allocation: Task 4, Task 5
- **SMOKE-B2 — live panel (`ZUVO_LIVE_SMOKE=1`; needs ≥ 2 working lanes)**
  - Preconditions: REAL `HOME` (lanes need their own logins); the REPO copy of the driver (its sibling libraries resolve; the installed layout is proven hermetically in Task 7); `ZUVO_PROVIDER_BENCH=0` (a lane benched by the real ledger, which runs before the pin, must not silently drop out); `ZUVO_REVIEW_PIN_PROVIDERS="agy codex-5.3"`
  - Proof: `ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_PIN_PROVIDERS="agy codex-5.3" bash scripts/adversarial-review.sh --mode blind-audit --production tests/hooks/fixtures/blind-audit-live/sum.sh --test tests/hooks/fixtures/blind-audit-live/sum.test.sh`
  - Expected (HOST-AWARE: the smoke runner computes `expected_pins` = `agy codex-5.3` minus the lanes `bap_vendor_excluded <detected host>` removes): exit 0; `Audit panel: strict valid=k/m` with k ≥ 2; every lane in `expected_pins` among the providers; no host-vendor lane among the providers; the untested branch of `sum.sh` as a non-FULL row; codex effort high on stderr when codex ran. Infrastructure outage → runner exit 75 → `BLOCKED_INFRA`.
  - Artifact: `zuvo/proofs/smoke-plan-b.txt`
  - RED allocation: Task 10
