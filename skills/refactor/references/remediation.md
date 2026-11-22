## Phase 3.5: Bug Remediation + Commit (in-process — leave the file CORRECT, not just tidier)

Apply `behavior_mode` and `behavior_scope` from the contract; `SKILL.md` "Behavior mode" says when a
found bug may be fixed. Introduced regressions are always fixed; every other finding keeps its
severity and an explicit disposition (`change-assessment.md`). Verified baseline debt is reported,
not "fixed" to raise an audit score. For v6+, use `refactor-contract regression <id> red|green
'<command>'` (the green command string must equal the red one) and `fix_findings` for each applied
fix; the textual proof examples below describe legacy v3–v5 records only.

This phase OWNS all committing of the refactor and its fixes. Phase 4 records; the `wrote=` paths `backlog-add` printed go into the run's one closing commit, and only when the run commits (`backlog-protocol.md` "Filing from a skill", **Committing what backlog-add wrote**; `completion.md` "Telemetry vs commits").

**Disposition (the line is fix-SCOPE, not severity or size):**

| Finding | Disposition |
|---------|-------------|
| Introduced/worsened bug, or the defect `behavior_scope` names, one clearly-correct fix (any size) | **Fix now** (commit 2). A bug you merely moved is not in this row: pin it, report it, `backlog-add` it. |
| Real bug, fix needs files OUTSIDE the scope fence | Recorded in Phase 4 through `backlog-add` with `--source refactor` at its file and line (`backlog-protocol.md` "Filing from a skill", **Generic write**; the command is the `DEFERRED` line of `completion.md` "Backlog Persistence") — genuinely out of this contract's reach. |
| Behavior/product DECISION (partial vs hard error on failure; swallow vs surface a cost; etc.) | **Not a bug — a choice.** Interactive: ask the user (≤1 question), apply the chosen fix into commit 2. Batch/`--auto`/`no-pause`/headless: pick the safe, conservative default, log `[DECISION-DEFAULT: …]`, surface in the report. If the user later declines, Phase 4 records the decision through `backlog-add` with `--source refactor` (`backlog-protocol.md` "Filing from a skill", **Process item**). |

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
test is unsatisfiable by construction. Narrow carve-out, not a way around step 3c: it applies only when the path's zero-consumer status is PROVEN with the same evidence DELETE_DEAD
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

0. **Record the Prove step in the CONTRACT — BEFORE you commit (the external gate reads it).** After the blind audit + adversarial passes (Phase 3), write their outcomes into the contract's `prove`: `prove.blind_audit` = the blind-audit telemetry (`clean:strict` / `clean:degraded` / `clean:degraded:same-model` for an inline pass / `fix:N`, never `skipped`/`not_run`); `prove.adversarial` = `clean` / `Nfindings` / `Nfindings:preserved`. **Both record what the pass
FOUND, not how the run ended.** An audit that surfaced four bugs you then fixed stays `fix:4` — do
not rewrite it to `clean:strict` because the tree is clean now. The completion state lives in
`findings_disposition` and `cq_after`; overwriting the audit value erases the only record that the
gate caught anything, and makes a run that needed remediation indistinguishable from one that never
had a finding. The `refactor-safety-gate` hook reads these on `git commit` — if either is still `skipped`/`not_run`/empty and the staged files are in this refactor's scope fence, the commit is **rejected**. That is the bind: you literally cannot commit a refactor whose Prove step you skipped.
0b. **Comment pass (before commit 1).** Read `../../../shared/includes/comment-pass.md` and run its whole sequence — mechanical scope, `CHECK` lines, ledger check, exit valve — with `COMMENT_SCOPE` = the scope-fence files this run created or modified, plus every file a fix creates or edits, checked against `git status --porcelain --untracked-files=all` — a check on the record, never a source of paths (files other sessions changed stay out); and `COMMENT_BASE` = `HEAD`, still the pre-refactor commit because this phase owns all committing. Print `COMMENT_BASE=<sha>`, resolved by `git rev-parse -q --verify HEAD || git hash-object -t tree /dev/null`, and pass that literal; if it is missing (a resume): the same resolver (`git rev-parse -q --verify HEAD || git hash-object -t tree /dev/null`) only when this run has committed nothing, otherwise print `[GATE: comment-pass] BLOCKED rc=2 base unknown`. Moved comments are carried lines: the helper does not judge them and this pass never edits them. One run, each path quoted, from the repository root:
    ```bash
    COMMENT_BASE=<sha printed above>
    rc=0; ~/.zuvo/comment-audit --base "$COMMENT_BASE" --files "<fence-file-1>" "<fence-file-2>" --skill refactor || rc=$?
    ```
   - **rc 1** → fix every finding in-run and re-run until rc 0 — no cap, no backlog; history moves into the commit message. The one exception is the exit valve: findings that cannot be fixed without harming the code and exceed the justification cap → print `[GATE: comment-pass] BLOCKED rc=1 ids=<id,…> <reason>` and stop for a human.
   - **rc 0** → settle each `CHECK` claim once by TEST-OR-GO and list it as `CHECK settled: <file:line> test|removed|softened`. A settling edit (a test added, a number removed) means one more helper run, and the marker takes that last clean run's id. Confirm the ledger with the include's `awk` lookup: a row for every path in scope (no row → `[GATE: comment-pass] BLOCKED rc=0 no ledger row for run=<id>`; a scoped path without a row → re-run over the full scope), then print `[GATE: comment-pass] PASS run=<id> files=<n> justified=<k>[ ids=<id,…>][ env=<NAMES>]` or `N/A (run=<id> no audited source)`; `N/A (no files written)` is printed only when the scope is empty (include step 1), with no run. If the pass added a test or changed code, re-run the targeted suite for those files; the include's freshness section decides whether the Phase 3 blind audit runs again. A claim inside a frozen characterization file (characterization.md "Freeze the characterization package": commit 1 keeps those files unchanged) is settled by `removed|softened` or by a test in a NEW file, which joins the scope and is staged with the commit this pass precedes (commit 1 here, 3e when 3d runs this sequence) — it tests the code that commit holds; a comment-only edit to a frozen file must keep its recorded pass count — re-run it to confirm.
   - **any other rc** → fix the invocation; if it cannot be fixed, print `[GATE: comment-pass] BLOCKED rc=<n> <reason>` and do not commit.
   - **Recheck:** if any file in scope was changed or created after the last clean run (step 1's split of fix hunks included), re-run this step over the grown scope before `git add`; the marker carries the new run id.
1. **Commit the pure refactor (always).** Stage scope-fence files → `git commit -m "refactor([scope]): [what moved]"`. This is the behavior-preserving proof: the Phase-2 characterization/existing tests, UNCHANGED, still pass. Record `REFACTOR_SHA`. (no-commit mode: show the diff + message, don't commit.)
   If adversarial passes recorded findings destined for fix-now, set `findings_disposition = "stacked-correction-pending"` BEFORE this commit — a transition value the gate accepts (it is not empty/`pending`/`unresolved` and does not contain `fix`, so `regression_red` is not demanded yet); after the demonstrated red in step 3, replace it with `fixed:<N>`. If any fix was already applied to the working tree during Phase 3 passes ("CRITICAL — fix immediately"), separate it out (stage move-hunks only; never `git stash`) so THIS commit is the pure move; the fix hunks land in commit 2.
2. **Triage** the CQ-auditor + adversarial findings into the table above.
3. **If fix-now items exist:**
   a. Apply every fix-now fix.
   b. Behavior now CHANGES. The characterization files are frozen: put the regression test in a NEW file, **red on `REFACTOR_SHA`, green on the fix**, and record the superseded old pin in `evidence.fix_regressions`. Editing a frozen file makes `recheck` report DRIFT.
   c. **DEMONSTRATE the red — a logical implication is not proof.** Run the NEW assertions
      against the PRE-fix code with a real tool call and capture the failing output (`git show REFACTOR_SHA:<file>` into a scratch
      copy, or a runner importing the pre-fix module; never `git stash`), then run them against the fixed code and capture the
      pass. "The old test asserted +20 and passed, so -20 would have failed" is the exact
      inference two consecutive skill-eval runs (2026-07-10) showed agents substituting for
      the actual red run — and one of those runs even logged a self-contradictory 'RED'
      entry. Record the proof in the CONTRACT NOW:
      `prove.regression_red = "red@<REFACTOR_SHA7>:green@<fix-verify>:<test path>"` —
      the commit gate BLOCKS the fix commit when fix-now items were applied but
      `prove.regression_red` is missing/`not_run` (runs with NO fix-now items set nothing;
      the gate keys on the disposition containing a fix).
   d. **Comment pass on the fix diff first** — 0b's sequence with `COMMENT_SCOPE` = every file the fix touched, code and tests, and `COMMENT_BASE` = `REFACTOR_SHA` (missing: `git rev-parse HEAD` only when `git log -1 --format=%s HEAD` is this run's `refactor(` commit — nothing committed after it — otherwise `[GATE: comment-pass] BLOCKED rc=2 base unknown`). In no-commit mode step 1 committed nothing, so there is no `REFACTOR_SHA`: pass the `COMMENT_BASE=<sha>` line 0b printed (missing: 0b's resolver, since this run has committed nothing) — the refactor and the fix both stay uncommitted against it, and the pass audits their lines together. History moves into the 3e commit message. If any file in scope was changed or created after its last clean run (the fixes this step's adversarial pass asks for), re-run it before 3e's `git add`.
      Re-verify: type-check + **targeted suite** (touched package/files, compared against the session baseline — a test that was red before the correction or broken by the local env is `pre-existing-out-of-scope`, recorded, NOT a blocker; the FULL suite runs once at the end per the targeted-tests rule) + ONE adversarial pass over the fix diff (`~/.zuvo/adversarial-review --mode code`) — must converge (no new CRITICAL).
   e. **Commit separately:** `git commit -m "fix([scope]): [bug summary]"` (`feat`/`perf` if that fits better). NEVER fold the fix into the refactor commit — that erases the move-vs-change boundary that makes commit 1 trustworthy.
   Else: print `[REMEDIATION: none — no fixable bugs surfaced]`.
4. **Decisions:** resolve per the table (ask / safe-default+log). Out-of-scope-fence items are recorded in Phase 4 through `backlog-add` with `--source refactor` (`backlog-protocol.md` "Filing from a skill", **Generic write**).

**Why two commits and not one:** a single mixed commit can't be bisected — if prod breaks you can't tell "moved the code" from "changed the logic." Two commits in one run cost you nothing and keep that boundary. (If you genuinely want one commit, that is the only thing to override here.)

---

## Phase 3.6: Test Quality Gate (Step 0 coverage → Step 1 `zuvo:test-audit` → Step 2 `zuvo:mutation-test`)

The Phase 2/3 Q1-Q25 evals are self-scored, and field runs still shipped weak tests. After the
Phase 3.5 commits — behavior is now proven and locked, so improving tests can no longer break the
**Dispatch is already authorized — do not ask, and do not substitute.** Invoking this skill IS the
request for the gates it mandates. A session-level instruction like "do not use the Agent tool unless
the user asked" does NOT apply here: the user asked, by invoking this skill. Reading it as a
prohibition and recording a self-scored result is the substituted gate this step forbids — it
happened in the field, once invented as `WARN:substituted-inline`, a value no vocabulary defines. If the harness genuinely has no dispatch
capability (Cursor, Antigravity — NOT Codex, which dispatches mechanical workers), follow the ONE documented exception in
`test-quality-gate.md`; otherwise dispatch.

**Step 0 — Per-module coverage of what this refactor CREATED (run before the audit dispatch).**

The characterization lock proves the split changed nothing. It does **not** give the new modules
tests, and it structurally cannot: `Completion Gate Check` requires those tests to run green on the
**PRE-refactor** code, so they can only target the original surface. Every characterization test a
split writes therefore lands in the *facade's* spec. That is correct for safety and useless as
coverage of the modules you just created — and until this step existed, nothing in this skill ever
looked at them.

Every gate can be satisfied by a split that created modules with no spec of their own, because no
gate asked. This step asks.

For each path in `modules_created`:

1. Is the module's behaviour exercised? Search by import, not filename: a module covered from a
   differently-named spec is covered, and so is one the frozen characterization suite reaches
   through the public API (`covered-via-facade:<characterization test ids>`, the ids required).
   Tests attach to behaviour, never to files: one module, one behaviour area, one spec; no twin
   test file per new source file; table-driven edge cases. Test LOC above 1.5x the source it
   covers is a smell: say so in the report.
2. **A module with behaviour no test reaches gets tests IN THIS RUN**, written into the existing
   spec of its behaviour area, or one new spec named by behaviour. Dispatch
   `Skill(zuvo:write-tests <module> --invoked-by refactor)` (the flag makes it list its
   `Backlog writes:` for refactor's closing commit), commit as `test(<scope>):`. A parked gap is
   deferred onto the user.
3. Only these defer, and only **named**: a module whose test needs files outside the scope fence, or
   one the user explicitly declined. Size and lateness are not reasons. Record each module once with `~/.zuvo/backlog-add --repo "$R" --class TEST-GAP --conf <N> --source refactor --file "$F" --line 1 --title "$T" --evidence "$E"`
   (`backlog-protocol.md` "Filing from a skill", "The location rule", **whole-file**): `F` the module, `T` starting "Whole file: …", `E` the reason it defers, and no
   `--anchor`; assign `"$R"`, `"$F"`, `"$T"` and `"$E"` before the call, as "Free text goes through a variable" in that section says; an empty value is a bug, and `backlog-add` refuses a missing required field (`REFUSED missing-field:<f>`).
4. Record `prove.split_coverage = "<created>/<covered>:<disposition>"` where `<covered>` counts modules
   with a direct spec or a `covered-via-facade` disposition — e.g. `"7/7:fixed-in-run"`,
   `"7/5:2-backlogged-out-of-fence"`, `"4/4:covered-via-facade"`. Empty `modules_created` → `"N/A"`, and say why (no new files).
   `backlogged` in that value means recorded (backlog-add prints whether it went to the backlog or the
   ledger; a TEST-GAP like item 3's stays in the ledger), so the Post-Completion Summary names each F-id.

**Both this field and `prove.test_quality` are read by the git hook at `git push`, not at commit** —
they cannot exist earlier, since Phase 3.5 commits before this phase runs. Both are checked against
artifacts rather than trusted: the `test_quality` report path must EXIST on disk, and the created
count in `split_coverage` must equal the number of entries in `modules_created` recorded back in
Phase 3. `"N/A"` after a split that created modules is therefore a block, not an escape.

Gap remaining after the cap → `WARN`, each uncovered module recorded as item 3 prints it (`backlog-add`), never silence. The specs written
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
CONTRACT. Below-A after the cap → WARN, each below-A file recorded with `--source refactor` as the
gate's steps 2 and 5 print it (`backlog-protocol.md` "Filing from a skill": **Generic write** for a
Q-gate pinned to a line, "The location rule", **whole-file** for the file's tier), never silence. Skip only in
`plan-only` / VERIFY_COMPILATION runs (nothing test-shaped happened) — and say so.

---

## Phase 3.6 Step 2: Mutation-test the tests this refactor produced (`zuvo:mutation-test`)

**Run it last in 3.6 — after Step 0's new specs and after the test-quality fix loop.** Both steps
CHANGE tests, and mutating a suite you are about to rewrite measures a draft.

A green suite says the tests RAN, tier A says they LOOK right; neither says they would have
NOTICED. The Phase 2.5 probes answer that for the **pre-refactor** lock only, never for the specs
Step 0 just wrote for `modules_created`.

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
| `--no-install` | suppresses the 0.1c consent gate, so a project with no runner is never offered one. **Leave it off** when a human can answer: the gate prints the install AND uninstall command, and a decline degrades loudly to the LLM engine. Consent stays a human decision — no flag grants it. A run that cannot be asked records `not_run:no-consent` (below) instead of passing the flag |
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
parts (`score_triaged`, `engine`, path) read out of one artifact chosen by this rule; `scope` selects, it is not recorded.
Candidates: `$ZUVO_DIR/audits/mutation-test-*.json`, excluding `*.report.json` and zero-byte or
unparsable files, that cover every audited file: `scope` is `full`, or `scope` is a path and each
audited file lies under it, or each audited file is a `files[].path` entry.
Among candidates whose `commit` == HEAD (else among all), take the newest by mtime.
No candidate → the field cannot be filled: re-run Step 2 over the audited files. A missing artifact has no `N/A`.
Never from memory. `WARN` when gaps remain after the fix loop, each surviving mutant recorded with
`~/.zuvo/backlog-add --repo "$R" --class MUTATION --conf <N> --source refactor --file "$F" --line <n> --anchor "$A" --missing-assertion "$M" --title "$T"`
(`backlog-protocol.md` "Filing from a skill", **Generic write**): `F`, `<n>` and `A` the mutated
production line, `M` the assertion the tests lack. A survivor the artifact gives no line for is a
whole-file record (`backlog-protocol.md` "Filing from a skill", "The location rule", **whole-file**): `--line 1`, a title starting "Whole file: …"
that names the artifact's mutant id, and no `--anchor`, since MUTATION, like TEST-GAP, requires none.
Assign `"$R"`, `"$F"`, `"$M"` and `"$T"` before the call, and `"$A"` only when you pass
`--anchor`, as "Free text goes through a variable" in that section says; an empty value you pass is a bug, and `backlog-add` refuses a missing required field (`REFUSED missing-field:<f>`).
No artifact can exist in two cases, each a closed code (optional `:<detail>` after it): inapplicable,
`N/A:no-test-runner` (the project has no test runner) or `N/A:plan-only` (plan-only/VERIFY_COMPILATION,
the runs that skip Step 1); applicable but not run, `not_run:no-native-runner` (no native mutation
runner, none installed) or `not_run:no-consent` (the install needs a consent nobody can give). `check`
and the hook accept the `not_run:` pair as a WARN: list it under unresolved risks. Free text after
`N/A:`/`not_run:`, a bare `N/A` and a score with no digit are blocked (`WARN:substituted-inline` is a
value a field run once invented).

The field is enforced at `git push` and at the `PHASE-4` boundary, against the artifact on disk —
`refactor-gate-lib.sh` (contract `version >= 7`) and `REQUIRES` in `~/.zuvo/refactor-contract`.
Gate on the boundary AFTER the phase that fills it, never inside: `prove.mutation` cannot exist
until this step has run, which is why nothing before PHASE-4 asks for it.

---
