# zuvo:refactor — Reference

> Detail moved out of the core SKILL.md happy-path. Load on demand: the CONTRACT
> schema when creating/migrating a contract; the Batch Mode section for `batch <file>`.

## CONTRACT State File (schema + migration)


Create a resumable state file per target. The path is scoped so batch mode can track multiple targets without overwriting:

| Mode | Contract path |
|------|---------------|
| Single-file (full) | `zuvo/contracts/refactor-{target-hash}.json` |
| Batch | `zuvo/contracts/refactor-{target-hash}.json` (one per queue entry) |

Where `{target-hash}` is the first 8 chars of SHA-1 of the relative target path (e.g., `sha1("src/services/order.service.ts")[:8]`).

**Resume contract:**
- `continue <path>`: compute hash from relative path, load `zuvo/contracts/refactor-{hash}.json`.
- `continue` (no argument): scan `zuvo/contracts/refactor-*.json` for `stage != "COMPLETE"`. 0 active: stop. 1 active: resume. 2+: list candidates, ask user to pick (do NOT auto-pick "most recent").

```json
{
  "version": 3,
  "file": "src/services/order.service.ts",
  "type": "EXTRACT_METHODS",
  "mode": "full",
  "stage": "PHASE-1",
  "queue_file": null,
  "queue_entry": null,
  "cq_before": { "score": "11/18", "critical_failures": ["CQ4", "CQ5"] },
  "scope_fence": ["src/services/order.service.ts", "src/services/order-helpers.ts"],
  "backup_branch": "backup/refactor-order-service-2026-03-27",
  "plan": {},
  "test_mode": "",
  "test_audit_before": { "test_file": null, "q7": 0, "q11": 0, "q13": 0, "units_total": 0, "units_covered": 0, "uncovered_units": [] },
  "prove": { "characterization": "not_run", "blind_audit": "not_run", "adversarial": "not_run", "findings_disposition": "pending" },
  "progress": []
}
```

**Contract migration (v2 → v3):** When `continue` loads a legacy contract:
- Mode migration: `quick`/`standard`/`auto` → `full` (silently, with log)
- Stage migration: `ETAP-1A` → `PHASE-1`, `ETAP-1B` → `PHASE-2`, `ETAP-2` → `PHASE-3`, `COMPLETE` → `COMPLETE`
- Version: bump to 3

In batch mode, `queue_file` and `queue_entry` are set so resume can map back to the queue:

```json
{
  "queue_file": "refactor-queue.md",
  "queue_entry": 3
}
```

Update this file after each phase completes. If the session is interrupted, `zuvo:refactor continue` picks up from the last recorded stage.


## Batch Mode (batch <file>)

Process a queue of files through the full pipeline autonomously. Zero interactive stops, one commit per file (exception: GOD_CLASS), failure logging in the queue file.

### Phase 0: Parse Queue and Triage

0. **Record `repo_root=$(git rev-parse --show-toplevel)` and `PRE_BATCH_SHA=$(git -C "$repo_root" rev-parse HEAD)` before any triage or change.** Bind git to `repo_root` (not CWD) so a worktree/CWD reset cannot target the wrong tree. The mandatory aggregate review at Batch Completion diffs the whole batch against this SHA.
1. Read the queue file. Parse lines:
   - Blank lines and lines starting with `#`: skip (comments)
   - `- [x]`: skip (completed, resume mode)
   - `- [!]`: skip (failed, needs human decision)
   - `- [ ]`: process (pending)
   - Bare file paths: process (first run)
2. Validate each file exists. Non-existent files: mark `[!] FILE NOT FOUND`, skip.
3. For each pending file: quick CQ1-CQ29 pre-scan, detect type.
4. Compute **PriorityScore** for ordering (range 0.00-1.00):

   ```
   PriorityScore = 0.4 * complexity_rank + 0.3 * hotspot_rank + 0.3 * cq_gap
   ```

   Where:
   - `complexity_rank` = file's rank in `analyze_complexity` top-10, normalized to 0-1 (rank 1 = 1.0, not in top 10 = 0.0)
   - `hotspot_rank` = file's rank in `analyze_hotspots`, normalized to 0-1
   - `cq_gap` = `1 - (cq_score / cq_applicable)` (e.g., 11/18 = gap 0.39)

   If CodeSift pre-scan is unavailable: `PriorityScore = cq_gap` (fallback). The queue is still sorted by PriorityScore descending even when using the fallback formula.

5. Rewrite the queue file with enriched format, sorted by PriorityScore descending:

```markdown
# Refactor Batch -- YYYY-MM-DDTHH:MM:SS
# Total: N | Completed: 0 | Failed: 0 | Pending: N
# PriorityScore = 0.4*complexity + 0.3*hotspot + 0.3*cq_gap

- [ ] path/to/file.ts | EXTRACT_METHODS | CQ: 11/18 | Score: 0.61
```

6. Proceed immediately (no approval stop).

### Per-File Pipeline

For each `[ ]` entry, run the full pipeline -- not a shortcut:

**Pipeline enforcement:** "Full pipeline" means running Phase 1 planning → Phase 2 test handling → Phase 3 execution → Phase 3.5 remediation → Phase 4 completion as defined in this skill. "Read file, fix obvious things, commit" is a shortcut that violates batch mode. Every file gets: its own contract state file (`zuvo/contracts/refactor-{target-hash}.json`), CQ BEFORE eval, fixes, CQ AFTER eval, and Phase 3.5 remediation+commit (the refactor commit, plus a separate `fix(…)` commit when fix-now bugs surfaced — files come out CORRECT, not just tidier).

**Steps (ALL mandatory, in order):**

1. **Analysis:** Dispatch Dependency Mapper + Existing Code Scanner (parallel) → CQ1-CQ29 BEFORE (all 29 gates) → type detect → scope freeze → create contract
2. **Test handling:** Write/verify tests per test mode routing
3. **Execution:** Execute fixes per CONTRACT → verify (type check + tests)
4. **Post-Audit:** Dispatch CQ Auditor (read-only; the **orchestrator** applies FIX-NOW items). Print CQ1-CQ29 AFTER (all 29 gates).
5. **Adversarial:** Run iterative adversarial review (`--rotate`) on staged diff with context-enriched input (same protocol as Phase 3). Pass count by diff size.
6. **Remediate + Commit (Phase 3.5):** commit the pure refactor first; then if fix-now bugs surfaced, fix them + update/add tests and add a SEPARATE `fix(…)` commit. Behavior DECISIONS take the safe default + `[DECISION-DEFAULT: …]` log — batch is zero-stop, never ask. Clean file = 1 commit; file with bugs = 2 commits (GOD_CLASS exception still applies: multi-commit per extracted responsibility, plus its fix commit).
7. **Queue update:** Update line with CQ before/after and commit hash(es).
8. **Backlog:** Persist ONLY out-of-scope-fence items and declined decisions — NOT mechanical bugs (those were fixed in step 6).

### GOD_CLASS Batch Exception

GOD_CLASS files in batch mode produce multiple commits (one per extracted responsibility). This overrides the general "one commit per file" rule. GOD_CLASS requires iterative decomposition by design — forcing a single commit would require extracting all responsibilities at once, which the GOD_CLASS protocol explicitly forbids.

**Partial failure in GOD_CLASS batch:** If a GOD_CLASS extraction fails mid-sequence, keep all previously committed extractions (they are atomic and tested). Mark the contract as `PARTIAL` with a list of completed and remaining extractions. Mark the queue entry as `[!] PARTIAL` with details.

### CQ Before/After (Non-Negotiable)

Every file in the batch gets a full CQ1-CQ29 evaluation, even if the agent believes it is already fixed. No file gets `[x]` without proof.

```
- [x] path | TYPE | CQ: 12/18->17/18 | CQ3,CQ21 fixed | commit: abc1234
- [x] path | VERIFY | CQ: 18/18 PASS | no changes needed
- [!] path | PARTIAL | CQ: 10/18->14/18 | CQ8 fixed, CQ19=0 CQ21=0 remain (cross-file)
```

### Anti-Rationalization Gate

The agent MUST NOT use these escape patterns:

| Escape | Rule |
|--------|------|
| "Already fixed" | Forbidden without CQ BEFORE eval proving all gates pass. Print the scores. |
| "Audit misclassification" | Forbidden without specific counter-evidence (file:line proving the audit was wrong). |
| "Out of scope" for the target file | Forbidden. The file IS the refactoring target. "Out of scope" is valid only for fixes requiring files not in the queue. |
| Partial fix (fix easy CQ, ignore rest) | If CQ AFTER still has fixable CQ=0 gates, mark `[!] PARTIAL`, not `[x]`. |
| "N/A" without justification | Each N/A needs a one-sentence explanation. >60% N/A triggers a low-signal flag. |

`[x]` means ALL in-scope CQ gates pass. If any fixable CQ=0 remains, use `[!] PARTIAL`.

### Zero-Stop Override

Batch mode overrides ALL interactive stops:

| Standard stop | Batch behavior |
|---------------|----------------|
| Phase 1 plan approval | Skipped -- agent proceeds autonomously |
| Phase 2 test approval | Skipped |
| Questions Gate | Skipped -- agent makes best judgment, logs uncertainty |
| Post-completion prompt | Skipped -- proceed to next queue entry |
| GOD_CLASS confirmation | Skipped -- auto-proceed with iterative decomposition |

### Failure Policy

- **Never stop.** Log failure in queue file, revert current file's uncommitted changes, move to next entry.
- **Actionable descriptions:** WHY + partial progress (e.g., "BLOCKED: test fail pricing.spec.ts -- expects old return shape | CQ16 fixed, CQ17 open").
- **Revert scope:** Only current file. Previous commits preserved. Note which commits landed if partial.

### Resume

Running `zuvo:refactor batch queue.md` on a file with existing progress: `[x]` skip (completed), `[!]` skip (needs human), `[ ]` process, bare path: process (triage enriches). Session-crash safe: uncommitted files stay `[ ]`.

### Aggregate Review (batch mode — MANDATORY, runs once)

Per-file review (CQ auditor + adversarial) sees each file in isolation against its own scope fence. It **cannot** catch integration issues that emerge ACROSS refactors in the same batch: a symbol renamed in file A and consumed by file B's new module, two extractions that now duplicate each other, a re-export chain broken across several commits. After the LAST queue entry is processed and committed, run ONE aggregate review over the whole batch:

```
HEAD_SHA=$(git -C "$repo_root" rev-parse HEAD)   # worktree-safe; SHAs are object-store-global
Skill(skill="zuvo:review", args="${PRE_BATCH_SHA}..${HEAD_SHA}")
```

- Runs **once per batch**, not once per file — this is the cross-file safety net, distinct from per-file review. Do not skip it because each file "already passed."
- Honors `no-pause-protocol`: invoke `zuvo:review` non-interactively. MUST-FIX findings are applied in-loop by review's own auto-fix; RECOMMENDED/NIT go to the backlog. Do NOT stop for approval.
- Record the outcome as `aggregate_review: <APPROVE|CHANGES|BLOCKED>` for the completion block.
- **Worktree isolation / CWD reset is NOT a dispatch failure.** The `${PRE_BATCH_SHA}..${HEAD_SHA}` content SHAs resolve to the same diff from any checkout of the repo (shared object store), so review diffs correctly regardless of where its CWD lands — "review would diff the wrong branch in a worktree" is a solved problem (explicit SHA range computed via `git -C "$repo_root"`), never a reason to punt the gate.
- If `zuvo:review` is GENUINELY un-dispatchable (skill missing / dispatch mechanism errors — not worktree), record `aggregate_review: BLOCKED`, downgrade the batch VERDICT to WARN at best, and say so loudly — never report a clean batch with the aggregate review absent. (Same HARD-GATE discipline as the per-file blind audit: a real review or an honest BLOCKED, never a silent skip.)

### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check -> structured questions -> TSV emit -> markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed to output.

### Batch Completion

```
BATCH COMPLETE
Total: N | Completed: X | Failed: Y | Skipped: Z
Aggregate review: [APPROVE | CHANGES (M MUST-FIX applied) | BLOCKED] over PRE_BATCH_SHA..HEAD
Queue: [path to queue file]
Run: <ISO-8601-Z>\trefactor\t<project>\t<CQ>\t-\t<VERDICT>\t<TASKS>\t<DURATION>\t<NOTES>\t<BRANCH>\t<SHA7>\t<INCLUDES>\t<TIER>
```

**Append via wrapper (REQUIRED).** Never `>>` directly to `~/.zuvo/runs.log` — the wrapper is the gate that verifies a retro entry exists for this run. Order: retro bash executed → wrapper invoked → completion claimed.

```bash
printf '%b\n' "$RUN_LINE" | ~/.zuvo/append-runlog
```

Expected stdout: `OK: appended to runs.log (retro verified for <skill> on <project>)`. If exit 2 with `RETRO_REQUIRED` — go execute the retro bash from `retrospective.md` first; never bypass with `ZUVO_SKIP_RETRO_GATE=1`. After the wrapper succeeds, print a `Logs:` evidence line (`tail -1 ~/.zuvo/retros.log`, `grep -c "^<!-- RETRO -->" ~/.zuvo/retros.md`, `tail -1 ~/.zuvo/runs.log`) before claiming completion. Printing the markdown retro section without executing the bash leaves all three log files empty.

Field hints (batch mode) — CQ: aggregate (e.g., `avg 16/18`) or `-`. TASKS: files completed. DURATION: `batch-N`. NOTES: `batch X/N completed Y failed` (max 80 chars).

---

