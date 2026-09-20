## Phase 3.5: Bug Remediation + Commit (in-process — leave the file CORRECT, not just tidier)

Apply `behavior_mode` and `behavior_scope` from the contract. For preserve_behavior, introduced
regressions are fixed; unrelated existing findings keep their severity and explicit disposition.
For v6+, use `refactor-contract regression <id> red|green '<command>'` and `fix_findings` for each
applied fix. The older textual proof examples below describe legacy v3–v5 records only.


Classify findings with `change-assessment.md` before selecting fixes. In preserve-behavior mode,
fix regressions and authorized remediation targets. Verified baseline debt is reported rather
than changing established behavior to satisfy an absolute audit score.

This phase OWNS all committing (Phase 4 no longer commits — it records).

**Disposition (the line is fix-SCOPE, not severity or size):**

| Finding | Disposition |
|---------|-------------|
| Introduced/worsened bug or authorized remediation target, one clearly-correct fix (any size) | **Fix now** (commit 2). Mechanical correctness has one answer — don't park it. |
| Real bug, fix needs files OUTSIDE the scope fence | Backlog with file:line — genuinely out of this contract's reach. |
| Behavior/product DECISION (partial vs hard error on failure; swallow vs surface a cost; etc.) | **Not a bug — a choice.** Interactive: ask the user (≤1 question), apply the chosen fix into commit 2. Batch/`--auto`/`no-pause`: pick the safe, conservative default, log `[DECISION-DEFAULT: …]`, surface in the report; backlog only if the user later declines. |

**Before applying the FIRST fix, size its blast radius.** When a finding changes the *error*,
*validation*, or *authorization* behaviour of an **exported** symbol, the fix is a contract change,
not a local repair: every production caller and every HTTP/RPC boundary that reaches it inherits
the new behaviour. Enumerate them (`find_references` + a route/handler trace, or grep for the
symbol and its route path) BEFORE editing, and then either add those files to the scope fence or
disposition each one explicitly in the ledger. Doing this after the fix means the next adversarial
pass raises the callers you did not look at, and the run spends a whole extra pass on it. Fixes
that stay inside the symbol — a wrong constant, a missing null-guard, a swapped argument — do not
need this.

**Draft-only / unwired parity repairs.** A repair that only brings a path with **no live consumers**
up to parity with the wired path has no live behaviour to regress, so a red-on-pre-fix regression
test is unsatisfiable by construction. This is a narrow carve-out, not a way around step 3c: it
applies only when the path's zero-consumer status is PROVEN with the same evidence DELETE_DEAD
requires (symbol references + repo-wide import/re-export/dynamic/string-literal search), and it is
recorded, not skipped — `prove.regression_red = "n/a-unreachable:<evidence>"`. The gate accepts that
value (it is not empty/`skipped`/`not_run`) and it stays visible in telemetry. If ANY consumer
exists, or you cannot prove none does, the demonstrated red is required as normal.

**Procedure:**

0a. **Phase 3.7 — Effectiveness re-measure (SPLIT_FILE / GOD_CLASS / SIMPLIFY only, after the
   LAST extraction).** Re-run the same measurement used for the baseline and write
   `prove.complexity_reduced` per the vocabulary in `refactor-reference.md` →
   "Effectiveness fields (v5)": `reduced:` needs maxfn ≥10% smaller; `already-small:` needs the
   baseline ≤50; `essential:` needs a `reason=` naming the entangled shape. **If the number says
   not-reduced and the Phase 1 classification was ADDITIVE, the job is not done — go back and
   decompose the worst function itself** (that residual core is what the user asked about), then
   re-measure. Recording `essential:` after an ADDITIVE classification is a contradiction the
   review will catch: you claimed the split would work, then claimed it could not.

0. **Record the Prove step in the CONTRACT — BEFORE you commit (the external gate reads it).** After the blind audit + adversarial passes (Phase 3), write their outcomes into the contract's `prove`: `prove.blind_audit` = the blind-audit telemetry (`clean:strict` / `clean:degraded` / `fix:N`, never `skipped`/`not_run`); `prove.adversarial` = `clean` / `Nfindings` / `Nfindings:preserved`. **Both record what the pass
FOUND, not how the run ended.** An audit that surfaced four bugs you then fixed stays `fix:4` — do
not rewrite it to `clean:strict` because the tree is clean now. The completion state lives in
`findings_disposition` and `cq_after`; overwriting the audit value erases the only record that the
gate caught anything, and makes a run that needed remediation indistinguishable from one that never
had a finding. The `refactor-safety-gate` hook reads these on `git commit` — if either is still `skipped`/`not_run`/empty and the staged files are in this refactor's scope fence, the commit is **rejected**. That is the bind: you literally cannot commit a refactor whose Prove step you skipped.
1. **Commit the pure refactor (always).** Stage scope-fence files → `git commit -m "refactor([scope]): [what moved]"`. This is the behavior-preserving proof: the Phase-2 characterization/existing tests, UNCHANGED, still pass. Record `REFACTOR_SHA`. (no-commit mode: show the diff + message, don't commit.)
   If adversarial passes recorded findings destined for fix-now, set `findings_disposition = "stacked-correction-pending"` BEFORE this commit — a transition value the gate accepts (it is not empty/`pending`/`unresolved` and does not contain `fix`, so `regression_red` is not demanded yet); after the demonstrated red in step 3, replace it with `fixed:<N>`. If any fix was already applied to the working tree during Phase 3 passes ("CRITICAL — fix immediately"), separate it out (stash, or stage move-hunks only) so THIS commit is the pure move; the fix hunks land in commit 2.
2. **Triage** the CQ-auditor + adversarial findings into the table above.
3. **If fix-now items exist:**
   a. Apply every fix-now fix.
   b. Behavior now CHANGES, so update the characterization test that pinned the OLD (buggy) behavior to assert the NEW correct behavior, and add a regression test that is **red on `REFACTOR_SHA`, green on the fix**.
   c. **DEMONSTRATE the red — a logical implication is not proof.** Run the NEW assertions
      against the PRE-fix code with a real tool call and capture the failing output (e.g.
      `git stash`/`git show REFACTOR_SHA:<file>` into a scratch copy, or a `/tmp` runner
      importing the pre-fix module), then run them against the fixed code and capture the
      pass. "The old test asserted +20 and passed, so -20 would have failed" is the exact
      inference two consecutive skill-eval runs (2026-07-10) showed agents substituting for
      the actual red run — and one of those runs even logged a self-contradictory 'RED'
      entry. Record the proof in the CONTRACT NOW:
      `prove.regression_red = "red@<REFACTOR_SHA7>:green@<fix-verify>:<test path>"` —
      the commit gate BLOCKS the fix commit when fix-now items were applied but
      `prove.regression_red` is missing/`not_run` (runs with NO fix-now items set nothing;
      the gate keys on the disposition containing a fix).
   d. Re-verify: type-check + **targeted suite** (touched package/files, compared against the session baseline — a test that was red before the correction or broken by the local env is `pre-existing-out-of-scope`, recorded, NOT a blocker; the FULL suite runs once at the end per the targeted-tests rule) + ONE adversarial pass over the fix diff (`~/.zuvo/adversarial-review --mode code`) — must converge (no new CRITICAL).
   e. **Commit separately:** `git commit -m "fix([scope]): [bug summary]"` (`feat`/`perf` if that fits better). NEVER fold the fix into the refactor commit — that erases the move-vs-change boundary that makes commit 1 trustworthy.
   Else: print `[REMEDIATION: none — no fixable bugs surfaced]`.
4. **Decisions:** resolve per the table (ask / safe-default+log). Out-of-scope-fence items → backlog (Phase 4).

**Why two commits and not one:** a single mixed commit can't be bisected — if prod breaks you can't tell "moved the code" from "changed the logic." Two commits in one run cost you nothing and keep that boundary. (If you genuinely want one commit, that's the only thing to override here — the in-run fixing stays either way.)

---

## Phase 3.6: Test Quality Gate (Step 0 coverage → Step 1 `zuvo:test-audit` → Step 2 `zuvo:mutation-test`)

The Phase 2/3 Q1-Q25 evals are self-scored, and field runs still shipped weak tests. After the
Phase 3.5 commits — behavior is now proven and locked, so improving tests can no longer break the
**Dispatch is already authorized — do not ask, and do not substitute.** Invoking this skill IS the
request for the gates it mandates. A session-level instruction like "do not use the Agent tool unless
the user asked" does NOT apply here: the user asked, by invoking this skill. Reading it as a
prohibition and recording a self-scored result is the substituted gate this step forbids — it
happened twice in the field (2026-08-07, 2026-08-08), the second time invented as
`WARN:substituted-inline`, a value no vocabulary defines. If the harness genuinely has no dispatch
capability (Cursor, Antigravity — NOT Codex, which dispatches mechanical workers), follow the ONE documented exception in
`test-quality-gate.md`; otherwise dispatch.

**Step 0 — Per-module coverage of what this refactor CREATED (run before the audit dispatch).**

The characterization lock proves the split changed nothing. It does **not** give the new modules
tests, and it structurally cannot: `Completion Gate Check` requires those tests to run green on the
**PRE-refactor** code, so they can only target the original surface. Every characterization test a
split writes therefore lands in the *facade's* spec. That is correct for safety and useless as
coverage of the modules you just created — and until this step existed, nothing in this skill ever
looked at them.

The failure is on record. `rs_be` PR #291 (`refactor(result): split result export responsibilities`)
created 7 `.operations.ts` modules holding 2 586 lines of moved logic, added 215 lines of
characterization tests to `result-export.service.spec.ts`, and shipped with **zero** spec files for
the 7 modules — no spec in the repo imports any of them to this day. Blind audit, adversarial,
mutation-test Grade A, review APPROVE, ship PASS. Every gate was satisfied because no gate asked.

For each path in `modules_created`:

1. Does a test file exercise it **directly** (imports the module, not only the facade)? Search by
   import, not by filename convention — a module covered from a differently-named spec is covered.
2. **Uncovered modules get tests IN THIS RUN.** Dispatch `Skill(zuvo:write-tests <module>)` per
   uncovered module, commit as `test(<scope>):`. This is the same in-run fix rule Phase 3.5 applies
   to bugs: a gap you surfaced and parked is not dispositioned, it is deferred onto the user, who
   finds it two weeks later on a "files without tests" list.
3. Only these defer, and only **named** in the backlog: a module whose test needs files outside the
   scope fence, or one the user explicitly declined. Size, lateness and "the facade covers it" are
   not reasons.
4. Record `prove.split_coverage = "<created>/<with_own_spec>:<disposition>"` — e.g. `"7/7:fixed-in-run"`,
   `"7/5:2-backlogged-out-of-fence"`. Empty `modules_created` → `"N/A"`, and say why (no new files).

**Both this field and `prove.test_quality` are read by the git hook at `git push`, not at commit** —
they cannot exist earlier, since Phase 3.5 commits before this phase runs. Both are checked against
artifacts rather than trusted: the `test_quality` report path must EXIST on disk, and the created
count in `split_coverage` must equal the number of entries in `modules_created` recorded back in
Phase 3. `"N/A"` after a split that created modules is therefore a block, not an escape.

Gap remaining after the cap → `WARN` + per-module backlog entry, never silence. The specs written
here are part of `TEST_SCOPE` below, so they get audited in the same run rather than next quarter.

**Step 1 — the characterization proof.** Run the gate from `../../../shared/includes/test-quality-gate.md` with:

- `TEST_SCOPE` = every test file this refactor **created or modified** (characterization/pin-down
  suites, updated specs) PLUS every **pre-existing** test file covering an in-fence production
  file (Phase 1 Test Discovery already found these — reuse `test_audit_before.test_file`).
- `FIX_COMMIT_PREFIX` = `test(<scope>):`

The include dispatches the REAL `Skill(zuvo:test-audit …)` on that scope, fixes every file below
tier A in-run (separate `test:` commit, suites re-run green), re-audits (max 2 iterations), and
prints `[GATE: test-quality] PASS|WARN|N/A` with the on-disk `zuvo/audits/` report path as proof
of dispatch. Record `prove.test_quality = "<PASS|WARN|N/A>:<worst tier>:<report path>"` in the
CONTRACT. Below-A after the cap → WARN + per-file backlog, never silence. Skip only in
`plan-only` / VERIFY_COMPILATION runs (nothing test-shaped happened) — and say so.

---

## Phase 3.6 Step 2: Mutation-test the tests this refactor produced (`zuvo:mutation-test`)

**Run it last in 3.6 — after Step 0's new specs and after the test-quality fix loop.** Both steps
CHANGE tests, and mutating a suite you are about to rewrite measures a draft.

A green suite says the tests RAN. Tier A says they LOOK right. Neither says they would have
NOTICED. Nothing earlier in this skill asks that question about the code this run produced: the
Phase 2.5 probes answer it for the **pre-refactor** lock, and by construction cannot touch the
specs Step 0 just wrote for `modules_created`. That is the gap `rs_be` PR #291 shipped through —
it carried a mutation-test **Grade A** scoped to the facade's spec while 7 created modules had no
spec at all.

**Scope — derive it, do not guess, and never pass a bare directory.** An unscoped invocation
re-mutates everything the last twenty commits touched; `zuvo:mutation-test` names that a bug in
the calling skill, and its own default (changed files) is not this run's fence.

```
MUTATION_SCOPE = TEST_SCOPE                                  # created + modified + pre-existing covering specs
               ∪ tests written in Step 0 for modules_created # they are the newest and least proven
```

A production file inside the fence with no covering test is **not** a scope entry — it is Step 0's
finding, and Step 0 already had to fix or name it. Reaching this step with one outstanding means
Step 0 was not finished.

```
Skill(skill="zuvo:mutation-test", args="<space-separated files from MUTATION_SCOPE> --runner auto")
```

**The flags this call must NOT carry, and why each one would hollow the gate out:**

| Flag | Why it is forbidden here |
|---|---|
| `--report-only` | skips the 4.2b fix loop — the survivors would be reported and left, which is the backlog-instead-of-fix drift this whole phase exists to prevent |
| `--no-install` | suppresses the 0.1c consent gate, so a project that has no runner silently never gets offered one. **Leave it off**: the gate asks the human, prints the install AND uninstall command, and a decline degrades loudly to the LLM engine. Consent stays a human decision — there is deliberately no flag that grants it |
| `--dry-run` | executes nothing |

**Close what it finds — in this run.** `zuvo:mutation-test` already fixes the tests whose gaps let
a mutation survive; that behaviour is the reason for chaining it here rather than printing a
suggestion. Two obligations this skill adds:

- A survivor that reveals a **production** bug rather than a test gap is a Phase 3.5 finding
  arriving late: fix it, demonstrate red/green, stack it as its own commit, and update
  `findings_outcome` / `fix_findings` accordingly.
- A survivor that is a genuine **equivalent mutant** is triaged as such in the artifact, not
  silently dropped.

**Read the verdict honestly.** A grade over a tiny denominator is a statement about a budget, not
about the tests: if the reported total equals the plan and the plan is a round number, the honest
word is `sampled(<N>)`, not `clean`. `--runner auto` prefers the native runner precisely because
its total is not a budget.

**Record `prove.mutation = "<PASS|WARN>:<score_triaged>%(<engine>):<artifact path>"`** — all three
parts read out of `$ZUVO_DIR/audits/mutation-test-<date>.json` (`score_triaged`, `engine`), never
from memory. `WARN` when gaps remain after the fix loop, with a per-file backlog entry naming each.
The only `N/A` values are `N/A:<why>` with a nameable condition — no test runner in the project, or
`plan-only`/VERIFY_COMPILATION (the same runs that skip Step 1). **A bare `N/A` is blocked**, as is
a score with no digit in it: `WARN:substituted-inline` is a real value a field run once invented
for `test_quality`, and it passed a shape-only check.

The field is enforced at `git push` and at the `PHASE-4` boundary, against the artifact on disk —
`refactor-gate-lib.sh` (contract `version >= 7`) and `REQUIRES` in `~/.zuvo/refactor-contract`.
Gate on the boundary AFTER the phase that fills it, never inside: `prove.mutation` cannot exist
until this step has run, which is why nothing before PHASE-4 asks for it.

---
