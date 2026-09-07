## Phase 4: Completion

### Commits (recorded — committing happened in Phase 3.5)

Phase 3.5 has already committed: the pure refactor (`REFACTOR_SHA`), and — when fix-now bugs existed — a separate `fix(…)` commit. Record BOTH SHAs in the contract and the Post-Completion Summary. If no bugs surfaced, there is just the one refactor commit.

In no-commit mode: Phase 3.5 showed both diffs + proposed messages instead of committing; nothing to record here beyond the proposed messages.

**Telemetry vs commits:** everything Phase 4 writes (CONTRACT, review artifact, backlog, retro, doc notes) is LOCAL telemetry — never stage it into the refactor/fix commits. If the repo tracks these paths, ONE trailing `chore(refactor): telemetry` commit MAY carry them; the `commits` array still lists only the production refactor/fix commits. Expected final `git status`: clean, or dirty only with untracked/ignored telemetry paths — that is the intended end state, not an unfinished run.

### Update Contract State

Mark contract: `"stage": "COMPLETE"`, `"cq_after": { "score": "18/18", "critical_failures": [] }`, `"commits": ["abc1234"]`.

**Record applicability separately from compliance.** N/A is excluded from both numerator and
denominator; never count an unevaluated gate as passing:

```json
"cq_after": { "status": "PASS", "score": "17/17", "in_scope": 29, "na": 12,
  "critical_failures": [], "applicability_review": { "status": "PASS",
  "scorer": "<original scorer identity and model>",
  "reviewer": "<independent reviewer identity and model>", "artifact": "<existing review path>" } }
```

Every N/A needs precondition/source/search evidence. When its count exceeds `floor(in_scope / 3)`,
record the independent applicability review's actual identity, result and artifact before PASS.
Unknown evidence remains 0/unproven. Use the normal percentage and active-critical-gate rules in
`../../../shared/includes/gate-registry.md`; completed WARN differs from INCOMPLETE.

### CodeSift Index Update

After committing: `index_file(path=<changed-file>)` for every changed file.

**A linked worktree gets indexed — it is not an exception.** This section used to say the opposite
("do not index a secondary worktree"), and that instruction is retracted: auto-indexing *refuses*
linked worktrees and silently defers to the parent checkout, so an unindexed worktree does not mean
"no index" — it means every later query answers about the PARENT's copy of your files. Measured
2026-08-10 on a run that fell back to `grep`/`cat` because of this: **21.8M tokens, 13.2% of the
whole run**. A refactor in `rewards-api` got a CQ14 clone reported at `paypal-webhook.ts:564` in a
facade that is 212 lines long — the wrong tree's answer reached the gate's output.
`../../../shared/includes/codesift-setup.md` is the source of truth here; if this file and step 2 of
that include ever disagree again, **step 2 wins**.

Procedure, in order:

1. **Blob-identity short-circuit — check this first.** If every file in scope is blob-identical to
   the indexed HEAD (`git rev-parse "HEAD:$f"` matches what the index was built from), the existing
   index is already correct for your content. Skip `index_folder`, use `index_file` per changed file,
   and say so. Indexing on top of an already-correct index is pure cost.
2. Otherwise resolve identity and index the tree once:
   `TARGET_REPO=$(git -C <scope> rev-parse --show-toplevel)` → if the index root differs,
   `index_folder(path=$TARGET_REPO)` **once**, then `index_file(path=<changed-file>)` per changed file.
3. **Cost escape.** `index_folder` on a large worktree is not free: measured 125 s on one run (both
   mandated tools then hit their 90 s timeout, so ~5 minutes bought nothing) and a 300 s MCP wedge
   that killed 4 follow-up calls on another. If it is slow, wedged, or times out, stop and record
   `degraded:<the exact restriction>` — that string must cover **slow/wedged/timed-out**, not only
   "index_folder failed".
4. **The narrow, real exception stays.** If the TARGET REPO's own instruction files forbid indexing
   worktrees, honour that and record `degraded:<the exact restriction>`. What is retracted is the
   false claim that *our* files forbid it.

When you skip indexing for any of these reasons, the run still has real evidence — local complexity,
cycle checks, and the test suite — so say which of those carried the verification.

### Backlog Persistence (FULL mode)

Read `../../../shared/includes/backlog-protocol.md`. Persist ONLY the items Phase 3.5 deferred — fixes needing files outside the scope fence, and behavior decisions the user declined. **Mechanical bugs were already fixed in Phase 3.5; they do NOT belong in the backlog.** Persist to `memory/backlog.md`. Fingerprint: `file|rule-id|signature`. Source: `zuvo:refactor` or `zuvo:refactor/cq-auditor`. Deduplicate per `backlog-protocol.md`.

**Transactional / concurrency residuals need an atomicity boundary line.** A deferred item like
"read-modify-write race in `applyCredit`" is unactionable months later — the next person re-derives
the whole analysis. When the deferral is an out-of-fence data race, add ONE line naming: (a) the
operations that must share a transaction, (b) the current race window (what interleaving loses or
duplicates data), and (c) the migration/constraint/RPC that would close it (unique index, `SELECT
… FOR UPDATE`, atomic RPC). That keeps the fix cheap to pick up without dragging schema work into
a behavior-preserving refactor.

### Content-keyed review artifact (on success only)

A refactor that completed its in-skill review layer (CQ post-audit + blind audit + adversarial)
has ALREADY reviewed the production files it changed. Record that so the pipeline-entry gates
do not demand a redundant standalone review: write `memory/reviews/<base7>..<head7>-<slug>.md`
with the `range:`/`files:` header per `../../../shared/includes/review-artifact.md`, listing the
production files this refactor touched (range head = the refactor/fix commit). Coverage is
content-keyed (by blob), so this only vouches for the exact reviewed content. Skip in no-commit
mode (nothing committed to vouch for).

### Aggregate Review Hand-off (single FULL mode)

A single refactor is fully reviewed by its in-skill layer (CQ post-audit + independent blind audit + adversarial). That layer is scoped to ONE contract's scope fence. When several refactors run back-to-back as separate invocations (a refactor sweep — the common real-world case), nothing reviews their **combined** blast radius: a symbol renamed in refactor A and consumed by refactor B's new module, two extractions that now duplicate each other, a re-export chain broken across several commits.

Do NOT auto-run `zuvo:review` after every single refactor — that is redundant ceremony the in-skill layer already covers. Instead, **detect a series and hand off once.** At completion:

1. Determine the session merge-base from the worktree's own repo: `repo_root=$(git rev-parse --show-toplevel); MERGE_BASE=$(git -C "$repo_root" merge-base HEAD <main-branch>)`. The `<MERGE_BASE>..HEAD` range is content-SHA-portable across worktrees, so the surfaced command diffs correctly from any checkout — a worktree/CWD reset is never a reason to drop the hand-off.
2. Scan `zuvo/contracts/refactor-*.json` for sibling contracts with `stage == "COMPLETE"` whose commits are ahead of `MERGE_BASE` on the current branch (i.e., landed this session, not yet reviewed together).
3. If 2 or more sibling refactor commits exist (including this one), surface:

```
AGGREGATE REVIEW RECOMMENDED
  N refactor commits this session not yet reviewed together: <sha7 list>
  Run: zuvo:review <MERGE_BASE>..HEAD   (cross-refactor integration check)
```

Print this in the Post-Completion Summary. If this refactor was invoked under an orchestrator running a known sweep, the orchestrator SHOULD run that single `zuvo:review` once after the LAST refactor — not after each one. (In `batch <file>` mode the series is known, so this becomes the MANDATORY aggregate review in Batch Completion, not a recommendation.)

### Knowledge Curation

Run `knowledge-curate.md`: `WORK_TYPE = "implementation"`, `CALLER = "zuvo:refactor"`, `REFERENCE = <commit SHA>`.

### Documentation (REQUIRED — no silent skip)

Follow `documentation-mandate.md`. A pure internal refactor with no behavior/API/contract
change is the COMMON case here — but it must still be DECLARED, not silently skipped:
`[DOC: N/A — internal-only refactor, no behavior/API/contract change]`. If the refactor
DID change public surface (moved a module, renamed an exported symbol, split a package,
changed an import path others use) → update the architecture/onboarding note + CHANGELOG.
Record the doc paths (or the N/A line) for the Post-Completion Summary.

### Follow-up ideas (optional — ZERO ceremony, leaves a receipt)

Follow `../../../shared/includes/followup-ideas.md` with `<skill> = refactor`: append genuine new
ideas to `memory/ideas.md` at the MAIN checkout root if any surfaced, then ALWAYS record the
receipt `~/.zuvo/log-ideas --skill refactor --count <N>` (N=0 is the normal, honest outcome — do
not invent ideas to inflate it). The receipt makes the un-gated step's silence auditable in
`~/.zuvo/ideas.log` without forcing ideation.

### Verification and quality status

Keep actual command success separate from assessment completeness. Persist current CQ and
per-file statuses in `cq_after`; do not hide INCOMPLETE behind a descriptive `clean` string.
Use `refactor-contract check` and its real exit code. Completed WARN assessments retain their
warnings; an unmet mandatory assessment blocks COMPLETE even if all tests and build passed.

### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check -> structured questions -> TSV emit -> markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed to output.

## Completion Gate Check

**A refactor is BLOCKED until proven COMPLETE — and proof is an ARTIFACT, not a self-assessment.** Each gate below leaves evidence: a file, a telemetry row, a log line. "I did it" / "dependency impact = 0, so I skipped the scanner" / "I went with the condensed flow" without the artifact = it did NOT happen = verdict is `BLOCKED`. This gate runs AFTER the code change, so **if you already committed the code, that commit is provisional** — the run is not finished, and you may not present it as done, until every item below has its artifact. Skipping a HARD GATE because the change "looks small/safe" is exactly the failure this gate exists to catch: triviality is an output of the gates, not an excuse to skip them.

```
COMPLETION GATE CHECK
[ ] Refactor type classified and printed: [RENAME/EXTRACT/SPLIT/INLINE/RESTRUCTURE]
[ ] CQ pre-audit printed on target file (all gates before changes)
[ ] Coverage gate: `units_total`/`units_covered` printed; if gap > 0, characterization tests were written for EVERY uncovered moved unit and ran green on the PRE-refactor code (build/type-check/static-resolution do NOT satisfy this item)
[ ] Characterization LOCK recorded: `prove.characterization` written into the CONTRACT the moment the suite went green on the PRE-refactor code — BEFORE the first move edit, in every test mode (WRITE_NEW/CHARACTERIZE_GAP/RUN_EXISTING), never backfilled at commit time (the refactor-safety-gate hook blocks on a missing value)
[ ] Baseline test suite ran green before first change
[ ] After each change: tests ran and green (not just at the end)
[ ] CQ post-audit printed — score must not regress
[ ] Independent CQ Auditor (blind audit) RAN — telemetry is clean:strict or clean:degraded, NOT skipped/not_run (HARD GATE; if it could not be dispatched the verdict is BLOCKED, never PASS/WARN — CodeSift being unavailable does NOT excuse skipping it)
[ ] Adversarial review ran on final diff
[ ] Bug remediation (Phase 3.5): every fix-now bug fixed + tested IN THIS RUN as a separate fix commit; nothing parked by size; only out-of-scope-fence items or user-declined decisions deferred. If bugs were fixed, the run has 2 commits (refactor, then fix)
[ ] Regression red DEMONSTRATED (only when fix-now items were applied): the new regression assertions were actually RUN against the pre-fix code with the failing output captured — not inferred from the old assertion's flip — and `prove.regression_red` recorded in the CONTRACT (the gate blocks the fix commit without it)
[ ] Effectiveness (v5, SPLIT_FILE/GOD_CLASS/SIMPLIFY only): `prove.complexity_before` recorded in
    Phase 1 (before any edit) and `prove.complexity_reduced` recorded in Phase 3.7 with the
    matching baseline number — verdict `reduced` (maxfn ≥10% smaller), `already-small` (baseline
    ≤50), or `essential:reason=<shape>` with the completion block saying the file REMAINS complex.
    A halved file with an intact worst function is a relocation, not a refactor
[ ] Per-module coverage (Phase 3.6 Step 0): every path in `modules_created` either has a test that imports it DIRECTLY, or was tested in-run via `zuvo:write-tests`, or is a NAMED backlog entry with an out-of-fence/user-declined reason; `prove.split_coverage = "<created>/<with_own_spec>:<disposition>"` recorded (`"N/A"` only when the refactor created no files). The characterization lock does NOT satisfy this item — it targets the pre-refactor surface by construction, so it can never cover a module that did not exist yet
[ ] Test Quality Gate (Phase 3.6) ran: `[GATE: test-quality] PASS|WARN|N/A` printed with a REAL `zuvo/audits/` test-audit report path (inline Q-rescoring is a substituted gate = INVALID); below-A files fixed in-run as a `test:` commit or WARN + per-file backlog; `prove.test_quality` recorded
[ ] Aggregate review hand-off evaluated: if 2+ sibling refactor commits this session, the `zuvo:review <range>` line is surfaced (per Aggregate Review Hand-off)
[ ] Documentation updated if public surface changed, else explicit [DOC: N/A — internal-only] (per documentation-mandate.md)
[ ] Terminal state A (terminal-state.md): processes launched = N, still alive = 0   (PIDs + how each ended)
[ ] Terminal state B: external checks triggered = N, unconcluded = 0   (run IDs + conclusions)
[ ] Terminal state C: artifacts created = N, not landed = 0   (PR/branch/tag + its state)
[ ] Run: line printed and appended to log
```

**Do not conflate three different things** — the verifier separates them, and so must you:
- **SAFETY gates** — blind-audit (Independent CQ Auditor), adversarial review, characterization coverage. These prove the refactor did not break behavior. **Never skippable, never reducible by user scope, never "looks small so I skipped it."** Skipping one = the code is *unsafe* = `BLOCKED`. **Running a gate and then parking its findings is the same failure** — an adversarial pass that surfaces 8 bugs and backlogs them (instead of fixing introduced regressions and authorized existing bugs in Phase 3.5) is `BLOCKED(unsafe)`, not done. The gate's value is the remediation, not the ceremony of having run it.
- **BUILD SCOPE** — targeted package type-check/tests vs full `turbo build/test --force`. The user *may* legitimately narrow this ("just type-check + targeted tests"), but only if you **declare it**: `[SCOPE: user-reduced — targeted type-check+tests; full build skipped per user]`. Silent narrowing is not allowed; declared narrowing is fine.
- **TELEMETRY** — retro, run-log, CONTRACT, review artifact. These don't make the code safer, but they are the durable PROOF the gates ran and the history the skill improves from (losing them is exactly how months of retros vanished). Cheap; always do them. Missing telemetry ⇒ the run is *unrecorded* (`INCOMPLETE`), not necessarily unsafe — but it is **not done** either.

Run the shared verifier against THIS run's explicit contract path:

```bash
~/.zuvo/refactor-contract --contract <this-run-contract.json> check
```

Record its actual exit status and output. Missing/unreadable evidence is not PASS. Fix unmet
requirements before COMPLETE; record unresolved risks and publish readiness separately.

### Post-Completion Summary

```
REFACTORING COMPLETE
------------------------------------
Type: [TYPE] | Target: [filename]
Files modified: [N] | Files created: [N]
CQ: [before] -> [after] | Tests: [status] | Commits: refactor [sha7][ + fix [sha7] (N bugs fixed in-run)]
Complexity: maxfn [before]→[after] ([-N%| ESSENTIAL — file remains complex: <reason>]) | file LOC [before]→[after]   (SPLIT/GOD_CLASS/SIMPLIFY only)

Run: <ISO-8601-Z>\trefactor\t<project>\t<CQ>\t<Q>\t<VERDICT>\t<TASKS>\t<DURATION>\t<NOTES>\t<BRANCH>\t<SHA7>\t<INCLUDES>\t<TIER>
------------------------------------
```

**Append via wrapper (REQUIRED).** Never `>>` directly to `~/.zuvo/runs.log` — the wrapper is the gate that verifies a retro entry exists for this run. Order: retro bash executed → wrapper invoked → completion claimed.

```bash
printf '%b\n' "$RUN_LINE" | ~/.zuvo/append-runlog
```

Expected stdout: `OK: appended to runs.log (retro verified for <skill> on <project>)`. If exit 2 with `RETRO_REQUIRED` — go execute the retro bash from `retrospective.md` first; never bypass with `ZUVO_SKIP_RETRO_GATE=1`. After the wrapper succeeds, print a `Logs:` evidence line (`tail -1 ~/.zuvo/retros.log`, `grep -c "^<!-- RETRO -->" ~/.zuvo/retros.md`, `tail -1 ~/.zuvo/runs.log`) before claiming completion. Printing the markdown retro section without executing the bash leaves all three log files empty.

Field hints — VERDICT: PASS/WARN/FAIL/BLOCKED/ABORTED. CQ: post-audit score. Q: test score or `-`. TASKS: files modified+created. DURATION: phase reached (e.g., `phase-3`). NOTES: type + target (max 80 chars).

---

## Batch Mode (batch <file>)

The full batch-mode protocol — queue parse/triage + PriorityScore ordering, the per-file
pipeline, zero-stop overrides, the anti-rationalization gate, the mandatory aggregate review,
and batch completion — lives in `../../../shared/includes/refactor-reference.md` -> "Batch Mode".
Load it when `$ARGUMENTS` begins with `batch`. The same Definition of Done + external commit-gate
apply to every file; per-file Prove is recorded in each file's CONTRACT before its commit.

## GOD_CLASS Protocol

When GOD_CLASS is detected (>600L, 5+ responsibilities):

1. **Identify:** List public methods grouped by responsibility. Map internal dependencies. Extract the group with the FEWEST internal dependencies first.
2. **Decompose iteratively:** For each responsibility: create new module, delegate from original, update imports, run tests, verify equivalence, commit. Repeat until original is under size limit with single responsibility.
3. **Size gate:** After each extraction check original file, new module, and all modules (CQ self-eval via Split-File Audit Rule). Continue if any exceeds limit.
4. **Residual-core gate:** when every responsibility is extracted and the survivor's worst function
   is still ≥90% of the Phase 1 baseline, the extraction removed the easy parts and left the reason
   the file was a GOD_CLASS. Decompose that function itself (within-function strategies in
   `refactor-reference.md` → "ADDITIVE vs ESSENTIAL") before recording `prove.complexity_reduced` —
   or record `essential:...:reason=` and say the file remains complex. Measured: this exact
   file-halved-core-intact outcome shipped 13 times in 14 days with every safety gate green.

---
