# Contract evidence semantics (v6)

Read existing v3–v5 contracts without automatic upgrading or inventing proof. New contracts use
v6 and `kind: refactor-contract`. `baseline` records `evidence.characterization_before`;
`recheck` records `evidence.characterization_after` and never writes `regression_red`.
Type/config-only verification uses `baseline --mode compilation`; a test run needs a positive parsed test count.
Both carry run ID, exact command, snapshot, actual exit code/counts and log digest.

Set the closed `findings_outcome` to `none|preserved|fixed|mixed`; applied IDs always require proof, regardless of descriptive wording.
For each applied fix, list its ID in `fix_findings`, then execute:

```bash
~/.zuvo/refactor-contract --contract <path> regression <finding-id> red '<test command>'
~/.zuvo/refactor-contract --contract <path> regression <finding-id> green '<same command>'
```

The first runs against pre-fix code with the new assertions; the second after the fix. Keep test
inputs identical. The helper requires a parsed failing test summary for red (Tests/Jest/Vitest, pytest, unittest, TAP, cargo, PHPUnit success and Zuvo harness summaries); infrastructure exits and unknown failure counts do not count. Other runner
formats require adding a tested parser, not a hand-written green→green claim. Logs are persisted.
Each pair lives in `evidence.fix_regressions[]`. Pure extraction requires no red regression pair.
For an authorized behavior fix, refresh characterization against the explicitly approved new
behavior after capturing its red→green proof; keep the original characterization record in history.

Run `~/.zuvo/refactor-contract --contract <path> check` before completion. It invokes the same
hook predicates, not a second prose implementation. Use legacy paths on resume; new target names
use SHA-256(relative target path)[:8], the CLI's `target_hash`. `BLOCKED` and `ABORTED` are terminal.
Review artifact paths and successful command receipts remain required; nonempty text is not an
independent proof. A malformed contract is diagnosed; hooks retain their documented fail-open
behavior, while an explicit CLI check refuses unreadable state.

---

# zuvo:refactor — Reference

> Detail moved out of the core SKILL.md happy-path. Load on demand: the CONTRACT
> schema when creating/migrating a contract; the Batch Mode section for `batch <file>`.

## CONTRACT State File (schema + migration)

**Read and advance it with the command, not with a heredoc.**

```bash
~/.zuvo/refactor-contract list                       # what is resumable HERE (stale ones withheld)
~/.zuvo/refactor-contract --file <src> show
~/.zuvo/refactor-contract --contract <path> regression <finding-id> red "<test command>"
~/.zuvo/refactor-contract stage PHASE-3.5
```

Why a command. Measured across 25 real refactor sessions and 1,010 contracts on disk:

- The contract was being edited by hand-written python heredocs — 22 of them re-issued within a
  single session, in a skill where **13% of all shell calls repeat a command already issued**.
  Composing a heredoc costs turns, and a typo in one corrupts the state file the whole run depends
  on.
- `stage` was free text, so runs invented their own: `READY_FOR_COMMIT` (28), `EXECUTION_COMPLETE`
  (8), `EXECUTION_COMPLETE_UNCOMMITTED` (7), `READY_TO_COMMIT` (3) — the first and last being one
  state spelled two ways, so any code matching one misses the other. 92 contracts have no `stage`
  at all. The command takes a closed vocabulary and maps every one of those spellings onto it.
- Nothing aged a contract out, so `continue` offered all of them. In `tgm-survey-platform` that
  list was 34 entries: 31 abandoned for over two weeks, 3 not contracts at all (the
  `-adversarial` / `-findings` sidecars match the same glob), and **zero** genuinely resumable.
  `list` withholds those and says how many it withheld.

**The characterization suite is typed once.**

```bash
~/.zuvo/refactor-contract baseline "TEST_DATABASE_URL=... npx vitest run tests/foo"
~/.zuvo/refactor-contract recheck        # re-runs the SAME command and compares
```

The most-repeated shell shape in a refactor session is that command — `cd` to the worktree, then a
~400-character line carrying a database URL, a spec list, a log path and an exit capture,
recomposed for every round (baseline, char1, char2). 66 re-issues of the environment prefix alone
across 25 sessions.

Recording it also changes what `prove.characterization` and `prove.characterization_after` MEAN. They used
to hold whatever sentence the run typed; now `baseline` records the parsed result and `recheck`
re-runs the stored command and writes the before → after comparison itself. `recheck` exits 1 on
drift, so a suite that stopped doing what it did cannot be narrated past. Re-running the STORED
command is the load-bearing part: a fresh command with a different spec list compares two different
things and calls it a regression check.

**The stage gate.** A phase cannot be entered while the evidence it rests on is still `not_run`:
`PHASE-3.5` needs characterization before/after; applied fixes additionally require `regression_red`, `PHASE-4` and `COMPLETE` also need
`findings_disposition` + `test_quality`. This is checked on the boundary AFTER the phase that
fills each field, never inside it. `--force` records it anyway and prints that it did — that is a
human's call, and it is visible in the contract afterwards rather than indistinguishable from a
proven advance.

`not_run`, `-`, `pending` and friends are rejected as evidence. Recording one is the same as
recording nothing, and it is how a field ends up looking answered when nothing happened.



Create a resumable state file per target. The path is scoped so batch mode can track multiple targets without overwriting:

| Mode | Contract path |
|------|---------------|
| Single-file (full) | `zuvo/contracts/refactor-{target-hash}.json` |
| Batch | `zuvo/contracts/refactor-{target-hash}.json` (one per queue entry) |

Where `{target-hash}` is the first 8 chars of SHA-1 of the relative target path (e.g., `sha1("src/services/order.service.ts")[:8]`).

**Archive before overwriting (the contract is the only durable record of a run).** The path is
keyed by target hash ALONE, so refactoring the same file a second time writes over the first run's
contract — destroying its `prove` telemetry, findings, and commit SHAs, the very evidence the
completion gate and later retros read. Before creating a new active contract, if one already
exists for that hash with `stage: "COMPLETE"` **and** current HEAD is not among its recorded
commits (i.e. it describes an *earlier, already-shipped* refactor, not this session):

```bash
C="zuvo/contracts/refactor-${HASH}.json"
if [ -f "$C" ]; then
  STAGE=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("stage",""))' "$C")
  HEAD7=$(git rev-parse --short=7 HEAD)
  # BOTH conditions, or we are destroying a RESUMABLE run — the exact loss this rule prevents.
  if [ "$STAGE" = "COMPLETE" ] && ! grep -q "$HEAD7" "$C"; then
    mv "$C" "zuvo/contracts/refactor-${HASH}-${HEAD7}.json"
    [ -f "zuvo/contracts/${HASH}-findings.json" ] && \
      mv "zuvo/contracts/${HASH}-findings.json" "zuvo/contracts/${HASH}-${HEAD7}-findings.json"
  else
    echo "contract ${HASH}: stage=$STAGE — RESUME it, do not archive or overwrite"
  fi
fi
```

Never overwrite a COMPLETE contract in place. An *incomplete* contract for the same hash is a
resumable run, not an archive candidate — resume it per the rules below instead of replacing it.

**Resume contract:**
- `continue <path>`: compute hash from relative path, load `zuvo/contracts/refactor-{hash}.json`.
- `continue` (no argument): `~/.zuvo/refactor-contract list`. 0 resumable: stop. 1: resume it. 2+:
  show the list, ask the user to pick (do NOT auto-pick "most recent"). Do not scan the glob by
  hand — it matches the `-adversarial` and `-findings` sidecars too, and it has no notion of a
  contract that was abandoned a month ago.

```json
{
  "version": 6,
  "kind": "refactor-contract",
  "behavior_mode": "preserve_behavior",
  "behavior_scope": [],
  "fix_findings": [],
  "findings_outcome": "none",
  "evidence": {},
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
  "modules_created": [],
  "prove": { "characterization": "not_run", "blind_audit": "not_run", "adversarial": "not_run", "regression_red": "not_run", "characterization_after": "not_run", "findings_disposition": "pending", "test_quality": "not_run", "split_coverage": "not_run", "complexity_before": "not_run", "complexity_reduced": "not_run" },
  "progress": []
}
```

**`modules_created`** — the production files this refactor BROUGHT INTO EXISTENCE (empty for a
refactor that creates none). Written in Phase 3 the moment the files land, not reconstructed at the
end. It is the denominator of `prove.split_coverage`.

**`prove.test_quality`** — `"PASS:<tier>:<existing report path>"` or
`"WARN:<tier>:<existing report path>"` from Phase 3.6; `N/A` only when no test assessment applies.
Keep the value exact: place explanations in the report, not after its path. In v6 the CLI rejects
malformed/nonexistent report paths when written. Use `findings_outcome` for the closed result
`none|preserved|fixed|mixed`; descriptive text does not decide whether a fix requires red proof.

Record the actual current `cq_after.status` and per-file assessment statuses. An explicit
INCOMPLETE or failed critical assessment blocks completion even when test commands pass.
A completed assessment with accepted warnings is WARN, not an incomplete assessment disguised
as PASS. The canonical check reports verification and quality separately. Baseline CQ failures
are not current failures merely because they remain in the historical record.

**`prove.split_coverage`** — `"<created>/<with_own_spec>:<disposition>"` from the per-module coverage
gate, or `"N/A"` when `modules_created` is empty. See "Per-module coverage" in `skills/refactor/SKILL.md`.

## Effectiveness fields (v5): `complexity_before` / `complexity_reduced`

**Why they exist — measured 2026-08-20, 101 split-ish refactors across 4 repos in 14 days.** 87%
reduced the worst function. 13% halved the FILE while the worst function stayed intact or grew:
`exerciseDesignMapper.ts` lost 614 lines with maxfn 103→103; `kano-advanced.helpers.ts` maxfn
63→**87**; `income-timing-integrity.scorer.ts` was split TWICE, 43→45 both times. Every safety gate
passed on all of them — the prove fields all asked "did it break?" and none asked "did it help?".
These two make effectiveness a recorded fact instead of an implied one. Enforced (pre-push, contract
`version >= 5`) only for the intents that PROMISE reduction: `SPLIT_FILE`, `GOD_CLASS`, `SIMPLIFY`.

**`prove.complexity_before`** — `"maxfn:<loc>,branches:<n>,loc:<n>"`, written in **Phase 1, before
any edit**. The pre-work baseline is the cross-check for the after-measurement: faking "reduced"
would require lying twice, backwards in time (the same principle `split_coverage` borrows from
`modules_created`). A `SPLIT_FILE`/`GOD_CLASS`/`SIMPLIFY` contract without it is blocked at push.

**`prove.complexity_reduced`** — written in Phase 3.7, after the last extraction:

| value | meaning | gate check |
|---|---|---|
| `reduced:maxfn:<b>-><a>,branches:<b>-><a>` | the worst function shrank | `a*10 <= b*9` (≥10% smaller) AND `<b>` equals the baseline |
| `already-small:maxfn:<b>-><a>` | nothing meaningful to reduce — the split was organizational | `b <= 50` |
| `essential:maxfn:<b>-><a>:reason=<one line>` | entangled core; splitting would relocate, not reduce | reason non-empty; completion block MUST say the file remains complex |

**The criterion is the worst FUNCTION, never file LOC.** File LOC is exactly the number the 13%
failures optimized: extract every trivial helper, leave the core, watch the file halve. `maxfn`
cannot be gamed that way — it only moves when the hard part is actually decomposed.

**Canonical measurement** (used for both fields; CodeSift `analyze_complexity` preferred when
available — record whichever tool you used consistently for before AND after):

```bash
~/.zuvo/measure-complexity "$TARGET_FILE"
```

The executable helper is the single maintained implementation. It reports approximate
non-comment LOC and branch-token counts, not cyclomatic complexity. Python function spans use the standard-library AST. The JS/TS fallback is for discovery only;
return-type braces, strings and comments can confuse its function boundaries. It refuses known
ambiguous multiline signatures, but cannot detect every ambiguity. Never use its JS/TS maxfn
as complexity-gate proof; use a language-aware analyzer and record that choice consistently.
Do not copy or repair a Python snippet in a run artifact. Record failed/incomplete assessments in
`cq_after` or `test_quality_assessment`; they are not successful `prove.test_quality` evidence.


## Complexity shape: ADDITIVE vs ESSENTIAL (decide BEFORE routing to SPLIT)

The 13% failures share one property: the target's complexity was **essential** — one algorithm with
interacting branches — and splitting relocated it instead of reducing it. Classify before choosing
the strategy; the signals are structural:

| signal | shape | consequence |
|---|---|---|
| responsibilities are independent method groups; the worst function is <40% of the file's branches | **ADDITIVE** | SPLIT works: each piece leaves and genuinely disappears from the original |
| one function holds >40% of the file's branches | **ESSENTIAL** | splitting the *file* leaves that function intact — target the FUNCTION |
| ordered first-match cascade (`if/else if` chain, `.find()` over rule arrays) where ORDER decides the outcome | **ESSENTIAL** | scattering 12 branches into 12 files hides the precedence question instead of answering it |
| a normalizer/mapper whose size is fields × defaults, all called from one entry | **ESSENTIAL** | per-field extraction drops LOC-per-function, total complexity unchanged |
| incremental parser / state machine threading mutable state through branches | **ESSENTIAL** | state crosses every new module boundary as parameters — complexity moves into signatures |
| shared mutable locals referenced by most branches | **ESSENTIAL** | same: the coupling IS the complexity |

For ESSENTIAL targets the honest strategies are **within-function**: table-drive the cascade,
extract pure predicates the core *calls* (shrinking its body), flatten nesting via early returns,
collapse duplicate branches — and when none applies, record
`complexity_reduced = "essential:...:reason=<the shape above>"` and say in the completion block that
the file remains complex. What is NOT honest: extracting every helper *around* the core, watching
the file halve, and reporting the god class fixed.

**Legacy contracts:** resume v3–v5 at their recorded version. Do not raise the schema version
or invent missing before-measurements. An explicitly requested migration creates a linked new
contract; every newly required proof stays `not_run` until measured. Keep the original record.

**Where these two are enforced — `git push`, not `git commit`.** The legacy flow records these after
Phase 3.6, following Phase 3.5 checkpoint commits; new runs follow execution-policy.md. A commit-time check would block the very commit
that has to happen before they can be filled — a deadlock on the default path of every refactor
(the first draft of this gate did exactly that; a repro caught it before release). So
`refactor_prove_v4_check` in `hooks/lib/refactor-gate-lib.sh` runs at **pre-push only**, and unlike
the commit gate it does *not* skip `stage: COMPLETE` — COMPLETE is precisely the state a finished
refactor is in when it reaches the push, so skipping it would mean the fields are enforced nowhere.

**Why the version bump matters — do not skip it.** That gate applies **only at `version >= 4`**.
That is what makes this a self-migrating rollout instead of a flag day: a run started by an older
installed skill writes a v3 contract and is judged by the v3 rules, so an in-flight refactor cannot
be blocked by a field its own skill version never knew about. Writing `"version": 4` is therefore a
promise that the run records both fields. Do not bump the version in a contract without recording
them.

Both fields are cross-checked against artifacts, not taken at face value: `test_quality` must name
an on-disk `zuvo/audits/` report that EXISTS (repo-relative, no `..`), and `split_coverage`'s created
count must equal the number of entries in `modules_created`. A claim that disagrees with the list
Phase 3 already wrote is a lie told twice, backwards in time.

**v2 compatibility:** read legacy mode/stage names through aliases where supported; diagnose
unknown values explicitly. Do not silently turn an old completion claim into a v6 proof.

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
3. For each pending file: quick CQ1-CQ40 pre-scan, detect type.
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

1. **Analysis:** Dispatch Dependency Mapper + Existing Code Scanner (parallel) → CQ1-CQ40 BEFORE (all 40 gates) → type detect → scope freeze → create contract
2. **Test handling:** Write/verify tests per test mode routing
3. **Execution:** Execute fixes per CONTRACT → verify (type check + tests)
4. **Post-Audit:** Dispatch CQ Auditor (read-only; the **orchestrator** applies FIX-NOW items). Print CQ1-CQ40 AFTER (all 40 gates).
5. **Adversarial:** Run iterative adversarial review (`--rotate`) on staged diff with context-enriched input (same protocol as Phase 3). Pass count by diff size.
6. **Remediate + Commit (Phase 3.5):** commit the pure refactor first; then if fix-now bugs surfaced, fix them + update/add tests and add a SEPARATE `fix(…)` commit. Behavior DECISIONS take the safe default + `[DECISION-DEFAULT: …]` log — batch is zero-stop, never ask. Clean file = 1 commit; file with bugs = 2 commits (GOD_CLASS exception still applies: multi-commit per extracted responsibility, plus its fix commit).
7. **Queue update:** Update line with CQ before/after and commit hash(es).
8. **Backlog:** Persist ONLY out-of-scope-fence items and declined decisions — NOT mechanical bugs (those were fixed in step 6).

### GOD_CLASS Batch Exception

GOD_CLASS files in batch mode produce multiple commits (one per extracted responsibility). This overrides the general "one commit per file" rule. GOD_CLASS requires iterative decomposition by design — forcing a single commit would require extracting all responsibilities at once, which the GOD_CLASS protocol explicitly forbids.

**Partial failure in GOD_CLASS batch:** If a GOD_CLASS extraction fails mid-sequence, keep all previously committed extractions (they are atomic and tested). Mark the contract as `PARTIAL` with a list of completed and remaining extractions. Mark the queue entry as `[!] PARTIAL` with details.

### CQ Before/After (Non-Negotiable)

Every file in the batch gets a full CQ1-CQ40 evaluation, even if the agent believes it is already fixed. No file gets `[x]` without proof.

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

