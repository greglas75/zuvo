# Implementation Plan: Task Telemetry, Declared Failure Strategy, Category SSOT

**Spec:** inline — no spec
**spec_id:** none
**planning_mode:** inline
**source_of_truth:** inline brief (user-approved design, this session)
**plan_revision:** 4
**status:** Approved
**Created:** 2026-08-02
**Tasks:** 9
**Estimated complexity:** 4 standard / 5 complex

**Baseline (measured on base `50eeeaf`, before any task):**
- `bash scripts/validate-skills.sh` → 0 ERRORS, 0 WARNINGS, `count-consistency: OK (57)`
- `bash tests/run-all.sh` → PASS=61 FAIL=1 SKIP=1, and it **exits 1** whenever `FAIL>0`
- **Pre-existing failure, foreign to this plan. It MUST NOT be counted as a regression and MUST NOT
  be "fixed" here:** `tests/skill-suite/test-eval-corpus-schema.sh` fails on
  `evals/container-audit.evals.json` (`eval[0].assertions[2]` has no checkable verb). Committed by
  a parallel agent in `50eeeaf`. Any task adding an eval case must satisfy that suite's
  checkable-verb rule, or the new case will be blamed on this pre-existing red.
- Plan-lint sweep baseline: 46 in-repo plan files, 43 exit 0 and 3 exit 2 on `### Task 6b:`-style
  id suffixes (`verify-plan-dag:85-89`). **Task 6's G6 proof CAPTURES this to
  `zuvo/proofs/dag-before.txt` as its first command, before any edit** — `zuvo/` is gitignored, so
  the file cannot arrive from git and every later `diff` against it would exit 2.
- External sweep, measured over 3,136 files (`~/DEV/*/docs/specs/*.md`, `~/DEV/*/zuvo/plans/*.md`,
  `~/DEV/*/docs/**/*plan*.md`): **0 occurrences of the exact literal `**Failure:**`**; 46 near-miss
  `**Failure…` occurrences in 17 spellings. This zero is the expected sweep result for G8 — the
  proof compares against it rather than discovering it.

**`<task-base-sha>` is defined here, once.** Several Acceptance Proofs diff against
`<task-base-sha>..HEAD`. It means **the commit this task started from** — i.e. `HEAD` immediately
before the task's own first commit, captured by the executor as
`TASK_BASE=$(git rev-parse HEAD)` at task start. It is NOT the plan's base `50eeeaf` (a task may be
preceded by other tasks' commits) and NOT `HEAD~1` (a task may land more than one stacked commit).

**The validate-skills red window (Task 1 → Task 2).** Task 1 deliberately makes
`bash scripts/validate-skills.sh` exit 1 on the real repo (57 ERRORs for undeclared `category:`);
Task 2 turns it green. **Every task whose Verify runs the full validator must therefore depend on
Task 2** — otherwise, executed inside that window, its Verify can never pass no matter how correct
the work is. That is why Tasks 4 and 6, which are otherwise dependency-free, declare Task 2.
Tasks 5, 8 and 9 inherit it through their own chains; Tasks 3 and 7 do not run the validator in
their Verify.

**The same two edges also satisfy Rule 13 (same-file serialization).** Task 2's Files line is the
glob `skills/*/SKILL.md`, which includes `skills/execute/SKILL.md` (also edited by T4, T8, T9),
`skills/plan/SKILL.md` (T6) and `skills/retro/SKILL.md` (T5). Without the Task 2 edges, the ready
set after Task 1 is `{T2, T3, T4, T6}` and `zuvo:execute`'s parallel-dispatch rule (`execute:378`)
could batch them concurrently — Task 2 writing a frontmatter line into `skills/execute/SKILL.md`
while Task 4 inserts the `# >>> zuvo:task-telemetry` fence is the lost-edit hazard Rule 13 exists to
prevent.

**Destructive-command rule for this plan.** `./scripts/install.sh` writes unconditionally to
`$HOME/.claude/plugins/cache/…` (`:164`), `$HOME/.codex/` (`:632-668`), `$HOME/.cursor/`,
`$HOME/.gemini/antigravity/`, and `$HOME/.zuvo/` (`:366-403`, a loop over every
`scripts/zuvo-home/*`). **No task may run it against the real `$HOME`** — that would install a
half-finished branch over the user's live plugin on four platforms and overwrite
`~/.zuvo/verify-plan-dag` for every project on the machine, which is the exact blast radius Task 7
exists to control. Where a build must be proven, call the three `build-*-skills.sh` scripts
directly, or use the repo's own overridden-`HOME` idiom
(`tests/adversarial/test-install-verify-plan-dag.sh:11,87-89`): `HOME="$(mktemp -d)" bash scripts/install.sh`.

---

## Architecture Summary

Three independent changes to zuvo's own skill definitions and tooling. No application code; the
"components" are markdown prose contracts plus bash/python3 scripts. Per-file ownership is in each
task's **Files** line; the three that carry non-obvious risk:

- `skills/execute/SKILL.md` (1242 ln) — per-task orchestration; owns telemetry emission, state
  writes, BLOCKED handling and the final gate. Touched by **T2, T4, T8, T9**, which the dependency
  chain serializes. **T2 counts:** its Files line is the glob `skills/*/SKILL.md` (×57), which
  includes `execute/`, `plan/` and `retro/SKILL.md` — so it collides with T4/T8/T9, T6 and T5
  respectively. A glob hides that from a file-overlap check, which is exactly how the collision
  survived three revisions; T4 and T6 therefore declare Task 2 (T5, T7, T8 inherit it transitively,
  T9 declares it directly).
- `scripts/zuvo-home/verify-plan-dag` (295 ln, pure awk) — **installed to `~/.zuvo/` and used by
  every project on the machine**, so T7 is the only task whose blast radius leaves this repo.
- NEW `zuvo/context/task-telemetry.jsonl` — the first append-only file in `zuvo/context/`; every
  existing one is full-rewrite, which is why T4 must state its lifetime explicitly rather than
  inherit the neighbouring contract.

**Frontmatter blast radius (verified).** All three non-Claude builders whitelist frontmatter keys
and end their rule chain with `in_fm { next }` — `build-codex-skills.sh:298`,
`build-cursor-skills.sh:154`, `build-antigravity-skills.sh:177` — so `category:` is **dropped**
before shipping to Codex/Cursor/Antigravity. `install.sh` never parses frontmatter, so `category:`
**does** ship to Claude Code. It is therefore a **repo-side documentation-only key**; T1 states this
and T2 asserts it, so a later agent does not "fix" the drop in the wrong direction.

---

## Technical Decisions

Decisions whose rationale is **not** repeated inside the task that implements them. (Rationale that
is stated in a task — the exit-1-vs-2 enum rule, the loose-matcher measurement, the retro `3b`
phase id, the `quality-review` string shape — lives there only, to keep this document inside the
50,000-character cross-model review cap.)

| Decision | Chosen | Rejected | Rationale |
|---|---|---|---|
| Category SSOT | frontmatter `category:` | the two markdown tables | Exact mirror of `count_actual_skills` ↔ its 8 checked mirrors; makes both tables *checkable*, not merely summable (`sum_category_table:381-391` collapses to a scalar today, so `Design=8, Testing=0` still sums to 57 and passes) |
| Category check placement | new top-level `check_categories` | fold into `check_count_consistency` | `count-consistency: OK (N)` is grepped **literally** at `tests/skill-suite/test-validate-skills-contract.sh:561`; overloading makes `(N)` ambiguous |
| Count exposure to dev-push | `validate-skills.sh --print-count` | shared lib helper; dev-push recounting | `scripts/lib/portable.sh:2`'s charter is correctness hazards, not code sharing; recounting is a second definition of "what a skill is" — the exact drift C3 kills |
| Task order for C3 | validator FIRST, then the 57 edits | edits first | Reversed, both halves are verifiable: T1's Verify is the real repo going **red** with 57 ERRORs, T2's is it going green. Edits-first leaves the edit task with `git diff --stat` as its only evidence |
| JSONL write site | end of Step 9b (`execute:793-807`) | Step 9 (`:774-790`) | Step 9 is blocking-by-contract in four places (`:778`, `:1150`, `:1242`, and `no-pause-protocol.md` naming it the durable checkpoint); a must-never-block write there invites the harden-into-a-gate drift this design forbids |
| JSONL keys | telemetry names verbatim, hyphens kept | snake_case | A rename is a translation table that drifts from the printed block it mirrors |
| Subprocess call shape | argv-passed python3 heredoc | interpolated shell string | Values carry `"`, `=`, `@`, commas, em-dashes. This is CQ31 (argv array, never an interpolated string) and it is scored |
| Conflict B closure | **both**; execute-time gate blocks | plan-time only | Plan rule 7 (`plan:367`) is static and blind to execute-time outcomes; the hole exists today for the user skip (`execute:532`) and async auto-BLOCKED (`:537-545`) |
| Conflict A enforcement | verify-plan-dag **and** prose rule | prose only | In-degree needs zero new grammar — the adjacency (`adj[t,ac]`, `verify-plan-dag:165`) and the whole-DAG DFS are already built |

**Anchor-absent-skip is fail-open.** `check_categories` skips when the target root has no
`| Category | Count |` table (the `cc_assert:352-353` idiom), which keeps the `$TMP` fixture root
green with zero edits. That skip means deleting the table from `CLAUDE.md` would silently disable
all 57 assertions — so T1 also asserts the **real repo** prints `category-consistency: OK (…)` and
never `n/a`.

---

## Quality Strategy

**Applicable gate sets are small and named, per `quality-gates.md:84` (`applicable = 40 − out-of-scope − N/A`).
Do not fake-score 40 gates on a markdown diff.**

- **Bash/python3 tooling (T1, T3, T7):** CQ3, CQ8, CQ14 (critical); CQ12, CQ13, CQ25, CQ31; CQ11
  marginal. **CQ40 is an honest 0 and pre-existing** — 43 files carry inline `# shellcheck`
  directives but no CI runs shellcheck; a repo-wide gap, not a defect of these tasks. CQ35-CQ38 are
  out-of-scope by their own stack gate. ~9 applicable.
- **Prose contract edits (T2, T4 doc half, T5, T6, T8, T9):** CQ13, CQ14, CQ25 only. **3 applicable.**
  CQ14 is the live one — telemetry field names will exist in three places (`execute:310-324`, the
  JSON schema, `session-state.md`), the drift `gate-registry.md` exists to prevent.
- **Q1-Q25 are N/A throughout** — they grade test *files*; the new `tests/skill-suite/*.sh` are
  shell contract harnesses, graded by whether their negative fixtures actually go red.

**Verification honesty rule.** A Verify command must be able to FAIL on a sloppy or half-done edit.
Where a proof is a bare pipeline, it is wrapped in `test`/`grep -q` so a non-match is a non-zero
exit — a pipeline ending in `wc -l` exits 0 regardless
(`shared/includes/acceptance-proof-protocol.md` §7-8). One area cannot meet the bar with in-repo
tooling: the runtime behaviour of T8's carve-out and T9's gate is prose inside a SKILL.md, and
`tests/run-all.sh` has no harness that executes a SKILL.md. Its **only** instrument is
`zuvo:skill-eval` against `evals/execute.evals.json`, which T8 and T9 each run as a mandatory
proof — genuine unavailability is a `BLOCKED_*`, never a silent downgrade. The two eval cases are
split deliberately: T8's exercises the pre-existing BLOCKED path so the mitigation is provable
without the carve-out, T9's exercises `skip-and-continue`.

**Risk-ranked review attention (highest sneak-through first):** T9 (relaxes a safety rule; only the
verbatim clause and the anchored table are checkable) → T5 → T8 → T4 (doc/impl drift + the
missing-directory hole) → T2 → T6 → T3 → T1 → T7. T7 has the *lowest* sneak-through and the
*highest* regression risk — different axes, do not conflate.

---

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| G1 | Per-task telemetry is persisted, not lost to chat | requirement | Task 4 | |
| G2 | A failed telemetry append is a WARNING, never a `BLOCKED_*` state | constraint | Task 4 | Stated at the write site AND in session-state.md |
| G3 | The telemetry file survives resume without truncation | constraint | Task 4 | |
| G4 | retro can read per-task telemetry, degrading silently when absent | requirement | Task 5 | |
| G5 | A plan task can declare `halt \| skip-and-continue \| degraded:<desc>` | deliverable | Task 6 | |
| G6 | `halt` / absent is byte-identical to today's behaviour | constraint | Task 6, Task 7, Task 9 | Backward compatibility |
| G7 | `skip-and-continue` is rejected on a task with in-degree > 0 | constraint | Task 7 | Conflict A |
| G8 | Existing plans in this repo and in every other repo keep their current exit code | constraint | Task 7 | Blast radius: 3,136 external files, 0 exact-literal hits expected |
| G9 | `execute:528`'s "never silently skip" clause survives verbatim | constraint | Task 9 | Anti-regression |
| G10 | A plan-declared skip is auditable via a distinct reason code | requirement | Task 9 | `skipped-plan-declared` |
| G11 | An AC whose claiming tasks all ended non-COMPLETED is reported, not silently green | requirement | Task 8, Task 9 | **`[SCOPE-ADDITION]`** — see Review Trail. Closes a hole that exists TODAY; reframed as C2's required mitigation, because C2 replaces a human at a prompt with a pre-authorized skip |
| G12 | Every skill declares a category; both category tables are checked row-by-row against it | deliverable | Task 1, Task 2 | |
| G13 | `category:` is documentation-only and is dropped by the three non-Claude builders | constraint | Task 2 | Asserted so nobody "fixes" the drop |
| G14 | The fixture suites stay green | constraint | Task 1 | `$TMP2` needs 2 fixture edits; `$TMP` needs none |
| G15 | The category check cannot silently self-disable | constraint | Task 1 | Anchor-absent-skip is fail-open |
| G16 | A release can never publish a stale skill count in the marketplace repo | requirement | Task 3 | **Both** files: `marketplace.json` (51) and `README.md` (49) |
| G17 | The count invariant is CHECKED and REWRITTEN before any push; the resulting marketplace commit still rides Step 4 as today | constraint | Task 3 | Deliberate split: the check/rewrite moves to the pre-flight (`:42-44`) so a stale count can never reach a release, while the commit+push stays in Step 4 (`:153-162`, after `git push --tags` at `:107-112`) so no new push path is introduced |
| G18 | No alternative/branching task DAG is introduced — the enum changes a task's OUTCOME, never the graph | scope boundary | Task 6, Task 7, Task 9 | The authority's explicit OUT OF SCOPE |
| G19 | No new npm or python dependencies; python3-stdlib, awk and bash 3.2 only | constraint | Task 1, Task 3 | Narrowed to where a proof exists. Task 4's block is independently covered by its python3-absent case (G2) and Task 7 is pure awk |
| G20 | The documented telemetry schema and the written schema cannot drift | constraint | Task 4 | CQ14 |

---

## Review Trail

- Phase 1: full fan-out — Architect → Tech Lead → QA Engineer (3 sequential Opus sub-agents)
- QA refuted one Tech Lead claim (`$TMP2` DOES carry category tables,
  `test-validate-skills-contract.sh:514-537`) — folded into Task 1
- Plan reviewer: revision 1 → **ISSUES FOUND** (5 must-fix, 6 should-fix, 5 nits). All applied in
  revision 2: T1 split into T1/T2 (validator-first); the dev-push first-run deadlock (pre-flight now
  rewrites and self-heals, failing only if an occurrence survives); every `install.sh` proof replaced
  with direct build scripts or `HOME="$(mktemp -d)"`; key count settled at 19; T9's Verify made
  falsifiable and its `zuvo:skill-eval` run made mandatory; inverted/no-op proof polarity fixed
  (S1-S4); T6's new rules given a cross-file enum-consistency assertion (S5); `--json` violation array
  added to T7 (S6); G18/G19/G20 rows added; SMOKE1-3 given an owner; `/tmp` path moved into
  `zuvo/proofs/`; `count_actual_skills` typo and the `--print-count --root` edge case resolved.
- **`[SCOPE-ADDITION]` surfaced:** Task 9 (`[AC-UNPROVEN:]`) is a 4th deliverable inside a
  3-deliverable authority. Kept, reframed as C2's required mitigation: before C2 a skip required a
  human at a prompt; after C2 an approved plan pre-authorizes it, so C2 is what turns a latent hole
  into an automated one. If the user declines Task 9, Task 8 must instead FORBID `skip-and-continue`
  on any task claiming an AC no other task claims.
- Cross-model validation, pass 1 (whole file, `--mode plan`): **partial** — 3/5 providers returned
  (`codex-5.3`, `cursor-agent`, `claude`; `agy` and `kimi` returned empty), `timeout_count: 0`.
  **`input_truncated: true`, 50,155 of 57,492 chars** — the tail was NOT reviewed, exactly as
  predicted. Findings: **3 CRITICAL, 10 WARNING**, all dispositioned in revision 3:
  mitigation-scheduled-after-risk (→ Task 8/Task 9 swapped), the Task 6 enum assertion referencing a
  file Task 7 has not yet written (→ moved to Task 7 RED (h)), and the smoke-owning task missing
  dependencies on Tasks 1/2/5/7 (→ declared, with a per-edge concrete-read rationale). WARNINGs
  applied: Task 2 and Task 3 reclassified `standard`→`complex`; Task 9 given its Task 7 dependency;
  G19 narrowed to the tasks that carry a proof; the Task 1 ERROR count now asserted, not printed.
- Cross-model validation, pass 2 (tail extract): **did not run** — `adversarial-review` refused with
  "plan too short — 1 tasks, minimum 3". The tail extract carried only Task 9. The corrected extract
  starts at `### Task 8:` so it carries 3 tasks (the reviewer separately noted the ~960-char blind
  spot between pass 1's truncation point and a Task-9-only extract).
- Plan reviewer: revision 2 → **ISSUES FOUND** (3 must-fix, all NEW and introduced by the revision-1
  fixes; 3 should-fix; 6 nits). All applied in revision 3: `zuvo/proofs/dag-before.txt` had no
  creator and three sites diffed against it (→ Task 6's G6 proof now captures it first);
  `<carve-out-anchor-start>` was a placeholder no task ever created (→ real
  `<!-- zuvo:blocked-carveout-start -->` anchors, added by GREEN and keyed by the proof); `$TMP2` is
  a deliberate count-drift fixture asserting `DRIFT_RC -eq 1` so it can never exit 0 (→ Task 1
  RED (a) now asserts stdout facts instead); the rule-numbering awk is bounded to its own section;
  the dev-push pre-flight now pulls before rewriting so Step 4's `git pull --rebase` is not
  silently refused by a dirty tree; SMOKE1 now counts entries in the `FAILED children:` block.
- Cross-model validation, revision 3 — **two passes, both recorded**:
  - **Pass 1** (whole file): partial, 3/5 providers, `input_truncated: true` (49,912 of 65,938) — so
    it covered the Coverage Matrix through Task 6. **2 CRITICAL, 6 WARNING, 1 INFO.**
  - **Pass 2** (extract: Coverage Matrix + Tasks 7-9 + Smoke Proofs, 24,407 chars, provider rotated
    with `--exclude-last codex-5.3`): **NOT truncated** — full coverage of the tail pass 1 could not
    see. **2 CRITICAL, 8 WARNING.**
  - CRITICALs FIXED in revision 4: (i) the **validate-skills red window** — Tasks 4 and 6 ran the
    full validator in their Verify while declaring no dependency, so executed between Task 1 (which
    makes the repo exit 1) and Task 2 (which makes it green) their Verify could never pass; both now
    declare Task 2, and the window is documented in the preamble. (ii) **`<task-base-sha>` was used
    in four proofs and never defined** — now defined once in the preamble as the commit the task
    started from (not the plan base, not `HEAD~1`). (iii) **G17 conflated the pre-push check with
    the Step-4 commit** — the row now states the split explicitly.
  - CRITICAL dispositioned as a **false positive of the extract boundary**: "dag-before.txt has no
    provenance" was raised by pass 2, whose extract starts at Task 7 and therefore cannot see Task
    6's G6 capture. Verified present.
  - WARNINGs FIXED: the Task 1 G19 proof used a PCRE lookahead (`(?!json|sys|os|re)`) that neither
    BSD nor GNU `grep -E` supports — a tool error there reads identically to "no match"; split into
    two portable stages. `shared/includes/no-pause-protocol.md` is edited by Task 9 GREEN item 2 but
    was missing from its Files list, and the `degraded:` sentence had no stated home — both fixed,
    with a new cross-file assertion RED (e). Task 9's Verify claimed a 4-case corpus without
    asserting it. Task 7's G7 `Expected: as stated` replaced with explicit per-fixture expectations
    including the `--json` array asymmetry. G8's `~/DEV` sweep demoted to a machine-local supplement
    with the in-repo sweep as the binding proof.
  - WARNINGs ACCEPTED with rationale, not fixed: "move Task 7 earlier / Task 9 later" (ordering
    advisories — Task 7's before/after exit-code sweep already bounds its blast radius, and Task 9 is
    last **by design** because its mitigation, Task 8, must precede it); "split Task 9's smoke proofs
    into their own task" (it would re-open the ownership gap a prior round closed); "G18's grep
    cannot fail on a correct implementation" (already stated as an honest limitation in the proof
    itself); INFO "Task 4 GREEN over-prescribes the call shape" (per fix policy, INFO is not acted
    on; the prescription is the CQ31 argv-array requirement, which is deliberate).
- Plan reviewer, iteration 3 (final — the skill caps the loop here): **ISSUES FOUND, 1 must-fix.**
  Task 2's Files line is the glob `skills/*/SKILL.md`, which includes `execute/`, `plan/` and
  `retro/SKILL.md` — a Rule 13 collision with T4/T8/T9, T6 and T5 that a glob hides from a
  file-overlap check. **Already closed by revision 4**, which had added the same two dependency
  edges (T4←T2, T6←T2) for a different reason — the validate-skills red window. Both rationales are
  now recorded on those edges, and Task 2 was added to the Architecture Summary's toucher list (the
  omission that let this survive three revisions). Residual nits 1-5 and 7 applied; nit 6 (the
  documented Rule 8(a) smoke-runner deviation) stands as a surfaced deviation.
  Reviewer's process note, recorded because it is the reason this loop terminates:
  *"revision 3's fixes are all real and none of them introduced a new defect — the recurring
  'fixes create the next round's must-fixes' pattern broke this round."*
- **[POST-CAP: SPEC-AMENDED] Task 1 / G15** (execute, 2026-08-02): revision 4's G15 expected a
  stripped-table copy to print `category-consistency: n/a`. The Task-1 adversarial pass then
  NARROWED the skip — a file that exists without its table is now a loud ERROR, and `n/a` is
  reserved for roots where neither anchor file exists. The code is strictly stronger than the
  contract; the contract was amended to the two-branch form, not the code weakened.
- Status gate: **Approved.** Reviewer converged (iteration 3 must-fix already closed by revision 4),
  cross-model run over two passes with full document coverage and every CRITICAL fixed or
  dispositioned. Remaining WARNINGs are dispositioned above, not re-looped — per the plan skill's
  stop rule.

---

## Task Breakdown

### Task 1: Category validator (RED against the real repo)
**Files:** `scripts/validate-skills.sh`, `tests/skill-suite/test-validate-skills-contract.sh`
**Surface:** config
**Complexity:** complex
**Dependencies:** none
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED: Extend `tests/skill-suite/test-validate-skills-contract.sh` with cases that fail today:
      (a) `$TMP2`'s two skill fixtures (`:456-468`, `:470-490`) gain `category: Core` /
      `category: Utility` and the run emits **zero `category-` ERRORs** and prints
      `category-consistency: OK (2)` — the **positive** fixture the design otherwise lacks. Assert
      those two facts on stdout, NOT whole-run exit 0: `$TMP2` is a deliberate count-drift fixture
      (`:450-451`, `:492-496` drift `plugin.json` to `3`) and `:540-543` already asserts
      `DRIFT_RC -eq 1`, so it can never exit 0; (b) a `$TMP2` variant whose `docs/skills.md` category row count
      disagrees with the frontmatter tally exits 1 with an ERROR naming the label; (c) a `$TMP2`
      variant with one skill's `category:` removed exits 1 naming that skill; (d) `$TMP` (no
      category table) still exits 0 with zero category ERRORs; (e) the **real repo** must print
      `category-consistency: OK (` and must never print `category-consistency: n/a` — the fail-open
      guard; (f) `--print-count` prints exactly the integer, `--print-count --root <dir>` honours
      the root, and `--print-count --root <dir-without-skills/>` exits **2** (not `0`).
- [ ] GREEN:
      1. New top-level `check_categories` in `scripts/validate-skills.sh` (NOT folded into
         `check_count_consistency`). Two helpers: `category_tally` (per-skill `fm_value category` →
         `sort | uniq -c` → `count<TAB>label`) and `category_rows` (`awk -F'|'` walking from
         `| Category | Count |` to `**Total**`). **Reuse or refactor `sum_category_table:381-391`
         rather than adding a second table walker — CQ14.** Diff the tally against BOTH
         `docs/skills.md` and `CLAUDE.md`. Allowed set = column 2 of `category_rows`.
         Anchor-absent-skip: no table in this root → `pass "category-consistency: n/a (no category
         table in <root>)"`, return 0.
      2. `--print-count` flag: parse in the arg block (`:31-56`); act after the function
         definitions and **after** the `[ ! -d "$SKILLS_DIR" ]` guard (`:503-512`) so a root without
         `skills/` exits 2 rather than printing `0`; print exactly the integer + `\n` via
         `count_actual_skills` (`:335-341`) and `exit 0` before any check runs, so a lint ERROR
         elsewhere cannot poison a caller.
      3. Comment at the top of the category block: `category:` is repo-side documentation only and
         is intentionally dropped by `build-{codex,cursor,antigravity}-skills.sh` at their
         `in_fm { next }` lines.
      Bash 3.2 only — no `mapfile`, no associative arrays (`validate-skills.sh:27`). Labels contain
      spaces and a `/` (`Code/Test audits`): carry them as awk fields / shell variables and compare
      with `[ "$a" = "$b" ]`; never build a `sed` script, regex, or `case` glob from a label.
      python3-stdlib + awk only (G19).
- [ ] Verify: `bash tests/skill-suite/test-validate-skills-contract.sh && test "$(bash scripts/validate-skills.sh --print-count)" = "$(ls -d skills/*/ | wc -l | tr -d ' ')" && ! bash scripts/validate-skills.sh >/dev/null 2>&1`
  Expected: exit 0. The contract test passes; `--print-count` prints `57`; and the real repo run **fails** (exit 1) because no skill declares `category:` yet — the unfakeable RED that Task 2 turns green.
- [ ] Acceptance Proof:
  - G12 (validator half):
    - Surface: config
    - Proof: `bash scripts/validate-skills.sh > zuvo/proofs/task-1-report.md 2>&1; test $? -eq 1 && test "$(grep -c \"missing 'category:'\" zuvo/proofs/task-1-report.md)" -eq "$(ls -d skills/*/ | wc -l | tr -d ' ')"`
    - Expected: exit 0 — validate-skills exited 1 and the ERROR count equals the skill-directory count (57). The count is derived, never hardcoded.
    - Artifact: `zuvo/proofs/task-1-report.md`
  - G14:
    - Surface: config
    - Proof: `bash tests/skill-suite/test-validate-skills-contract.sh >> zuvo/proofs/task-1-report.md 2>&1`
    - Expected: exit 0 — the `$TMP` (no-table) and `$TMP2` (table + 2 categorized fixtures) roots both pass.
    - Artifact: `zuvo/proofs/task-1-report.md`
  - G15:
    - Surface: config
    - Proof: **two branches — the skip is narrower than revision 4 assumed.** (A) copy the repo to `mktemp -d`, strip the `| Category | Count |` table out of BOTH `docs/skills.md` and `CLAUDE.md` but LEAVE the files present, run `bash scripts/validate-skills.sh --root "$C"`. (B) a `mktemp -d` root that has `skills/` but NEITHER anchor file, same command.
    - Expected: (A) an explicit `ERROR: category-consistency: <file> exists but has no '| Category | Count |' table` for EACH file — **not** `n/a`; (B) exactly the `category-consistency: n/a (…; per-skill 'category:' presence/label checks were skipped too)` line. Plus: the REAL repo must never print `n/a` (asserted unconditionally by the contract test, not gated on Task 2 having landed).
    - Artifact: `zuvo/proofs/task-1-report.md`

  - G19:
    - Surface: config
    - Proof: `! git diff <task-base-sha>..HEAD -- scripts/validate-skills.sh | grep '^+' | grep -qE 'pip install|npm install|npm i |require\('` and, for python imports, `git diff <task-base-sha>..HEAD -- scripts/validate-skills.sh | grep '^+' | grep -oE '^\+[[:space:]]*import [a-z_]+' | grep -qvE 'import (json|sys|os|re)$' && exit 1 || exit 0`
    - Expected: exit 0 — no new dependency was introduced. Two portable grep stages, no PCRE lookahead: `grep -E` has no `(?!…)` on BSD or GNU, so the single-regex form would fail with a tool error that reads identically to "no match".
    - Artifact: `zuvo/proofs/task-1-report.md`
- [ ] Commit: `feat(validate): check per-category counts against SKILL.md frontmatter — the column was summed, never compared`

### Task 2: Declare `category:` in all 57 skills
**Files:** `skills/*/SKILL.md` (×57, one line each)
**Surface:** config
**Complexity:** complex
**Dependencies:** Task 1
**Failure:** halt
**Execution routing:** deep implementation tier

**Rule 2 (5-file boundary) — explicit justification.** This task edits 57 files. They are one
mechanical unit: an identical single-line frontmatter insert with zero logic, whose correctness is
established by one derived-count assertion plus the validator Task 1 already built. Splitting it
into batches would multiply review cycles over a change with no per-file decision content — the
micro-step anti-pattern Rule 1 forbids.

- [ ] RED: Already red from Task 1 — `bash scripts/validate-skills.sh` exits 1 with 57 ERRORs
      naming every skill that does not declare `category:`. Record that output as the RED evidence;
      do not author a new failing test for a mechanical edit whose checker already exists.
- [ ] GREEN: Add `category: <label>` to all 57 `skills/*/SKILL.md` frontmatters. Labels come
      verbatim from the 13-row table in `CLAUDE.md:229-242` / `docs/skills.md:137-152` — verified
      byte-identical row-for-row, 57 skills listed, 57 unique, 57 dirs on disk, zero drift either
      direction. Do not invent labels. Insert the key after `description:`, before any
      `codesift_tools:` block.
- [ ] Verify: `bash scripts/validate-skills.sh && test "$(grep -l '^category:' skills/*/SKILL.md | wc -l | tr -d ' ')" = "$(ls -d skills/*/ | wc -l | tr -d ' ')"`
  Expected: exit 0; validate-skills prints `count-consistency: OK (57)` **and** `category-consistency: OK (`; every skill dir has a `category:` line.
- [ ] Acceptance Proof:
  - G12 (frontmatter half):
    - Surface: config
    - Proof: `bash scripts/validate-skills.sh > zuvo/proofs/task-2-report.md 2>&1 && grep -q 'category-consistency: OK' zuvo/proofs/task-2-report.md`, then in a `mktemp -d` copy set one skill's `category:` to a bogus label and assert `bash scripts/validate-skills.sh --root "$C"` exits 1 naming that skill.
    - Expected: clean run exits 0 with the OK line; the perturbed copy exits 1 with an ERROR naming the skill and the bogus label.
    - Artifact: `zuvo/proofs/task-2-report.md`
  - G13:
    - Surface: config
    - Proof: `bash scripts/build-codex-skills.sh && bash scripts/build-cursor-skills.sh && bash scripts/build-antigravity-skills.sh && test "$(grep -rl '^category:' dist/codex dist/cursor dist/antigravity 2>/dev/null | wc -l | tr -d ' ')" = "0" && grep -q '^category:' skills/build/SKILL.md`
    - Expected: exit 0 — the three builds succeed, the key is dropped from all three build outputs (documentation-only, as designed), and it is still present in the source that Claude Code receives verbatim. **Does NOT run `install.sh`** (see the destructive-command rule).
    - Artifact: `zuvo/proofs/task-2-report.md`
- [ ] Commit: `feat(skills): declare category in every SKILL.md frontmatter — the count SSOT now covers the per-category breakdown`

### Task 3: Close the cross-repo count hole in dev-push
**Files:** `scripts/dev-push.sh`, `tests/skill-suite/test-dev-push-gate.sh`
**Surface:** config
**Complexity:** complex
**Dependencies:** Task 1
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED: Extend `tests/skill-suite/test-dev-push-gate.sh` (already the fence-extraction +
      hermetic-run + ordering harness, `:1-25`, `:41-44`, `:53-57`, `:106`) with: (a) a stub
      marketplace dir whose `marketplace.json` says `51 skills` and `README.md` says `49 skills`,
      with a stub `--print-count` returning `57` → after the block runs, **both files read
      `57 skills`** and the block exits 0 (it self-heals; it does not dead-end); (b) the fenced
      block's line number strictly precedes the first `git push origin main` line; (c)
      `26 specialized agents` in the same description string is byte-unchanged; (d) a marketplace
      file whose `<N> skills` occurrence **survives** the rewrite (e.g. read-only) makes the block
      exit non-zero with a `fail` message naming the file.
- [ ] GREEN: Add a fenced `# >>> zuvo:marketplace-count` block to `scripts/dev-push.sh` at the
      existing marketplace pre-flight (`:42-44`, which already `fail`s when
      `$MARKETPLACE_DIR/.claude-plugin` is absent), so it runs **before** Step 1 — Step 4
      (`:153-162`) executes after `git push origin main` + `git push --tags` (`:107-112`), and a
      `fail` there would leave an irrecoverable half-shipped release.
      **The block rewrites, then verifies — it does not merely assert.** A pre-flight that only
      fails on a mismatch would dead-end on today's real `51`/`49` (Step 4 never runs, nothing is
      ever rewritten, `dev-push.sh` is unusable until someone hand-edits the marketplace — exactly
      what "the fix must land via the mechanism, not a hand-edit" forbids). Sequence: **first**
      `git -C "$MARKETPLACE_DIR" pull --rebase --quiet 2>/dev/null || true`; then read `N` from
      `bash scripts/validate-skills.sh --print-count`; scan **every** file in `$MARKETPLACE_DIR` for
      `<digits> skills`; rewrite each occurrence that disagrees with `N`; re-scan; `fail` **only if
      an occurrence survives**. Step 4's existing `git add -A` + commit + push (`:159-161`, after
      `cd "$MARKETPLACE_DIR"` at `:156`) then carries the rewrite with no new commit path.
      **The pull must precede the rewrite.** Step 4's own `git pull --rebase --quiet 2>/dev/null || true`
      (`:157`) runs *before* its `git add -A` (`:159`); on a self-heal run the marketplace working
      tree is already dirty by then, so that rebase is deterministically refused — silently, via the
      `|| true`. `git push --quiet` (`:161`) is unprotected under `set -euo pipefail` (`:19`), so a
      moved remote would then hard-fail a release whose zuvo tag is already pushed. Pulling in the
      pre-flight makes Step 4's pull a harmless no-op; say so in the block's comment.
      Use **python3, not sed** (precedent: `dev-push.sh:177-193`, `validate-skills.sh:361-379`):
      `sed` exits 0 whether or not it substituted, so a renamed key silently no-ops. Wrap as
      `|| fail "…"` with remediation text, matching `:210`. Do NOT touch the unrelated plugin-level
      `"category": "development"` key, and do not let a loose numeric pattern hit
      `26 specialized agents`. Do NOT copy the `&& ok … || warn …` shape of `:177-193` — that step
      is deliberately best-effort because a missing `installed_plugins.json` must not fail a
      release; user-visible product metadata in a repo the script already treats as mandatory is not
      in that category.
- [ ] Verify: `bash tests/skill-suite/test-dev-push-gate.sh && bash -n scripts/dev-push.sh`
  Expected: exit 0; the stub-marketplace self-heal, ordering, near-miss and survivor cases all pass; `dev-push.sh` parses.
- [ ] Acceptance Proof:
  - G16:
    - Surface: config
    - Proof: run the extracted `# >>> zuvo:marketplace-count` fence against a `mktemp -d` stub marketplace containing both stale strings; then `grep -c '57 skills' "$STUB"/.claude-plugin/marketplace.json "$STUB"/README.md` and `grep -q '26 specialized agents' "$STUB"/.claude-plugin/marketplace.json`.
    - Expected: block exits 0; both files read `57 skills`; `26 specialized agents` is unchanged; a second run is a no-op that also exits 0.
    - Artifact: `zuvo/proofs/task-3-report.md`
  - G17:
    - Surface: config
    - Proof: `F=$(grep -Fn '# >>> zuvo:marketplace-count' scripts/dev-push.sh | head -1 | cut -d: -f1); P=$(grep -Fn 'git push origin main' scripts/dev-push.sh | head -1 | cut -d: -f1); test "$F" -lt "$P"`
    - Expected: exit 0 — the fence precedes the first push.
    - Artifact: `zuvo/proofs/task-3-report.md`
  - G19:
    - Surface: config
    - Proof: `! git diff <task-base-sha>..HEAD -- scripts/dev-push.sh | grep -qE '^\+.*(pip install|npm i )'`
    - Expected: exit 0.
    - Artifact: `zuvo/proofs/task-3-report.md`
- [ ] Commit: `fix(dev-push): rewrite and verify the marketplace skill count before pushing — both files were stale (51 and 49 vs 57)`

### Task 4: Persist per-task telemetry (write side)
**Files:** `shared/includes/session-state.md`, `skills/execute/SKILL.md`, `tests/skill-suite/test-task-telemetry-contract.sh`
**Surface:** integration
**Complexity:** complex
**Dependencies:** Task 2
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED: New `tests/skill-suite/test-task-telemetry-contract.sh`. Extract the
      `# >>> zuvo:task-telemetry` fence with the awk idiom at `test-dev-push-gate.sh:106` (precedent
      for a fence inside a SKILL.md bash block: `skills/execute/SKILL.md:783-787`), run it
      hermetically in `mktemp -d`, and assert:
      (a) the appended line is valid JSON with exactly the **19** documented keys — the count is
          derived from the `session-state.md` key list, never hardcoded in the test;
      (b) `acceptance-verified` is a JSON **array**;
      (c) adversarial values round-trip intact — a task name containing `"` and an em-dash, a
          `verify` value containing quotes/`=`/spaces, an `acceptance-verified` list containing `@`
          and commas;
      (d) two appends produce exactly two lines (append-only, no truncation);
      (e) **the target directory does NOT exist beforehand and the file still appears** — the
          highest-value assertion here: `open(...,"a")` raises `FileNotFoundError` on a missing
          dir, which would degrade this change to "always `[WARN]`, never persists" while every
          other assertion still passes;
      (f) with `python3` absent the block exits **0** and prints `[WARN]`. Use a shadow-PATH dir
          (symlink `sh bash git mkdir cat printf date` into `$TMP/bin`, deliberately omitting
          `python3`), **not** `PATH=/nonexistent` — the latter also removes `git`/`date` and tests
          something else. Additionally test a stub `python3` exiting 127: `command not found` and a
          non-zero child exercise different bytes;
      (g) exit status is 0 **and** `[WARN]` is on stdout **and** no other output appeared — a
          `|| echo` bound to the wrong command is the realistic way this silently changes shape.
- [ ] GREEN:
      1. `shared/includes/session-state.md`: new `### zuvo/context/task-telemetry.jsonl` section
         after the `active-plan.md` section (`:152`), so the three resume-critical files stay
         grouped first. Follow the existing entry shape (`### <path>` → fenced template → field
         contract → Lifetime → failure behaviour). It must state four things no existing entry does:
         **(i)** APPEND-ONLY, one line per task, explicitly contrasted with `:310` ("full rewrite —
         never append", which governs `execution-state.md` only); the READ protocol (`:172-251`)
         does not touch this file and must not start to — a resume appends, never rebuilds or
         truncates. **(ii)** Lifetime is `project-context.md`'s (`:115`) — survives across sessions,
         **never renamed, never truncated** — explicitly NOT `execution-state.md`'s, because the
         `.completed`/`.stale` rename (Cleanup Reference `:368-375`) would split one resumed run's
         records across two files. That table is Event × File, so this file is a new **column** (or a
         footnote), not a row — add it in whichever form keeps the table readable. **(iii)** Gitignored for
         free via `zuvo/` (`:298-302`). **(iv)** A failed append is a WARNING — not a failed test,
         not a `BLOCKED_*` state, never halts the task — and the unqualified "Treat a failed rewrite
         exactly like a failed test" at `:325` governs `execution-state.md` **only**.
      2. Document the **19** keys with types: `at`, `session-id`, `retro-session-id`, `task` (int),
         `task-name`, `surface`, `mode`, `fallback-path`, `writer-model`, `reviewer-route`,
         `implementer-status`, `spec-review`, `quality-review` (the full per-file string, NOT
         decomposed — `execute:326`; a schema a parser must reassemble is how the aggregate collapse
         returns), `adversarial`, `verify`, `acceptance-verified` (array), `codesift`,
         `backlog-adds` (int), `failure-strategy` (defaults to `halt`, never null — defined here,
         populated by Task 8).
      3. `skills/execute/SKILL.md`, END of Step 9b (`:793-807`), after the printed block: the fenced
         `# >>> zuvo:task-telemetry` block. Argv-passed python3 heredoc — every value a separate
         `argv` element so the shell quotes once and python never re-parses (**CQ31**).
         `os.makedirs(dirname, exist_ok=True)` — see RED (e). `ensure_ascii=False`,
         `encoding="utf-8"`, `open(...,"a")`, one `write()` per line. Tail:
         `|| echo "[WARN] task-telemetry append failed — continuing (diagnostic file, never a gate)"`;
         that tail **is** the non-blocking contract and also covers a missing interpreter, so no
         `zuvo_python` guard belongs here (`portable.sh:55-73` is for `scripts/`, which must not
         degrade; this block must). Restate the non-blocking rule in prose at the write site — it is
         stated twice on purpose.
      4. Document the accepted cost: Step 10 (`:809-817`) can downgrade `codesift` to `index-failed`
         after the line is written; append-only means it is not back-written. Do not "fix" this by
         moving the write to Step 10, which is explicitly best-effort maintenance.
- [ ] Verify: `bash tests/skill-suite/test-task-telemetry-contract.sh && bash scripts/validate-skills.sh`
  Expected: exit 0 for both; all seven assertion groups pass, including the missing-directory and python3-absent cases.
- [ ] Acceptance Proof:
  - G1:
    - Surface: integration
    - Proof: run the extracted fence twice in a `mktemp -d` with the documented argv values, then `python3 -c "import json,sys;ls=[json.loads(l) for l in open(sys.argv[1])];assert len(ls)==2 and all(len(r)==19 for r in ls) and isinstance(ls[0]['acceptance-verified'],list)" <file>`
    - Expected: exit 0 — 2 valid JSON lines, 19 keys each, `acceptance-verified` an array.
    - Artifact: `zuvo/proofs/task-4-report.md`
  - G2:
    - Surface: integration
    - Proof: run the fence under the shadow-PATH dir without `python3`, capture rc and stdout; repeat with a stub `python3` exiting 127; `test "$rc" -eq 0 && grep -q '\[WARN\] task-telemetry append failed' out && ! grep -q 'BLOCKED' out`
    - Expected: exit 0 in both cases; the `[WARN]` line present; no `BLOCKED` token anywhere.
    - Artifact: `zuvo/proofs/task-4-report.md`
  - G3:
    - Surface: integration
    - Proof: append 1 line; snapshot its bytes; run the fence again in the same dir simulating a resumed session (different `session-id`, same `retro-session-id`); `test "$(wc -l < f)" -eq 2` and assert line 1 is byte-identical and both records carry the same `retro-session-id`.
    - Expected: exit 0 — 2 lines, line 1 unchanged, one run identity.
    - Artifact: `zuvo/proofs/task-4-report.md`
  - G20:
    - Surface: docs
    - Proof: extract the key list from the `session-state.md` section and from the fence's python `k = [...]` list into two sorted files; `diff` them.
    - Expected: empty diff, exit 0 — the documented schema and the written schema are identical.
    - Artifact: `zuvo/proofs/task-4-report.md`
- [ ] Commit: `feat(execute): persist per-task telemetry to zuvo/context/task-telemetry.jsonl — the block was printed to chat and lost`

### Task 5: retro reads per-task telemetry
**Files:** `skills/retro/SKILL.md`, `tests/skill-suite/test-task-telemetry-contract.sh`
**Surface:** integration
**Complexity:** standard
**Dependencies:** Task 4
**Failure:** halt
**Execution routing:** default implementation tier

- [ ] RED: Extend `tests/skill-suite/test-task-telemetry-contract.sh` with reader cases against a
      new `# >>> zuvo:retro-telemetry` fence: (a) a fixture JSONL with 3 well-formed records yields
      a deterministic aggregate (gate-failure counts, reviewer-route distribution, blocked/skipped
      reason tally) — assert the exact expected numbers; (b) a fixture whose 2nd line is malformed
      JSON does **not** crash — the line is skipped, the other two are still aggregated, no
      traceback on stderr; (c) a **missing** file prints the "no per-task telemetry" note and exits
      0. A bare `grep '^## Phase 3b'` is explicitly NOT acceptable as this task's verification — a
      heading grep passes on anything.
- [ ] GREEN: Insert `## Phase 3b: Per-Task Telemetry (optional)` into `skills/retro/SKILL.md`
      between Phase 3 (`:151`) and Phase 4 (`:181`); do **not** renumber 4/5/6 — `3b` matches the
      repo's own `Step 9b` / `Phase Final-1b` / `Phase 3.0` vocabulary, and renumbering churns
      cross-references for zero signal. Give it a fenced `# >>> zuvo:retro-telemetry` block (this is
      what makes the phase testable at all) reading
      `${ZUVO_OUTPUT_DIR:-<git root>/zuvo}/context/task-telemetry.jsonl`, one `json.loads` per line
      with `continue` on a malformed line, printing the aggregate. Degradation copies the shape at
      `:155` — "If the file does not exist: note 'No per-task telemetry found.' Skip this section."
      **No project-name filter** (`:169`): unlike the HOME-global `runs.log`, this file is
      project-local by construction. The existing `runs.log` phase and its strict tab-field parse
      (`:159-164`) are untouched.
- [ ] Verify: `bash tests/skill-suite/test-task-telemetry-contract.sh && bash scripts/validate-skills.sh`
  Expected: exit 0; the three reader cases pass with their exact expected aggregates.
- [ ] Acceptance Proof:
  - G4:
    - Surface: integration
    - Proof: run the extracted `# >>> zuvo:retro-telemetry` fence against (i) a 3-record fixture, (ii) the same with line 2 corrupted, (iii) a non-existent path; assert each rc and the expected aggregate strings.
    - Expected: (i) rc 0, aggregate covers all 3; (ii) rc 0, aggregate covers 2, stderr has no traceback; (iii) rc 0 and the "No per-task telemetry found." note.
    - Artifact: `zuvo/proofs/task-5-report.md`
- [ ] Commit: `feat(retro): add optional per-task telemetry phase — runs.log is per-run, gate and retry hotspots need per-task`

### Task 6: Declared failure strategy — plan side
**Files:** `skills/plan/SKILL.md`, `tests/skill-suite/test-plan-authoring-rules.sh`
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 2
**Failure:** halt
**Execution routing:** default implementation tier

- [ ] RED: New `tests/skill-suite/test-plan-authoring-rules.sh` asserting: (a) the Task Authoring
      Rules list is a strict `1..N` with no repeats — **this fails today**, `skills/plan/SKILL.md:377`
      and `:390` are both `17.`. **Bound the awk scan between the `### Task Authoring Rules` heading
      (`:352`) and the next `^### ` heading:** a file-wide `^[0-9]+\.` scan also picks up the
      unrelated lists at `:441-443` and `:492-494`, both at indent 0, so it would see repeats even
      after a correct renumber and the task could never go green; (b) the task template carries a
      `**Failure:**` line, on its own line, never appended after a `·` bullet; (c) the Completion
      Gate Check contains the new literal item (a fixed-string assert is legitimate for a fixed
      literal list); (d) the new rule names **exactly** the three enum tokens `halt`,
      `skip-and-continue`, `degraded` and no fourth. This is a plan-side-only assertion by design —
      cross-file parity against the linter's classifier belongs to Task 7, because
      `scripts/zuvo-home/verify-plan-dag` contains none of those tokens until Task 7 writes them
      (verified: 0 occurrences in its 295 lines today), so asserting parity here would compare
      against a file that does not yet exist in that shape and would invert the T7←T6 edge.
- [ ] GREEN:
      1. Task template (`:311-329`): add
         `**Failure:** halt | skip-and-continue | degraded:<one-line description>` immediately after
         `**Dependencies:**` (`:315`). **It MUST be on its own line** — the `verify-plan-dag`
         Dependencies parser truncates at `(`/`>` and hard-exits 2 on a non-numeric token
         (`:122-125`, `:183-188`), so a `degraded:` description containing a comma placed after a
         `·` bullet on the Dependencies line would be tokenized as a dependency. State that
         constraint in the template comment, not just here.
      2. New Task Authoring Rule: `halt` is the default; a task with no `**Failure:**` line is
         `halt`, byte-identical to today. `skip-and-continue` is legal **only** on a task with
         in-degree zero — no other task may declare it as a dependency — because Rule 9 (`:369`)
         requires Dependencies to trace concrete reads, so "B depends on A but A is optional" means
         B fails mid-RED against a symbol never written, trading a clean `BLOCKED_BY_DEPENDENCY` for
         a worse failure. **State explicitly that the enum changes a task's OUTCOME and never the
         task graph — there is no alternative/fail branch (G18).**
      3. New Task Authoring Rule (the advisory, prose / plan-reviewer-enforced — **not** mechanical,
         because the Coverage Matrix "Primary task(s)" cell is free text at `:302`): a task may
         declare `skip-and-continue` only if every AC in its Acceptance Proof block is also claimed
         by at least one other task, or its Acceptance Proof is explicitly `none — <reason>`.
         Otherwise the plan authorizes a run reaching `## Execution Complete` with an unproven AC.
      4. Renumber the duplicate rule 17 at `:390` → 19; new rules take 20+. Rules 13 and 17 are
         cited by number elsewhere (`:359`, `execute:355`, `:378`) and keep their numbers; the
         trailing rule at `:390` is cited nowhere.
      5. Completion Gate Check (`:534-551`): add "every task declares a Failure strategy (or `halt`
         by omission)".
- [ ] Verify: `bash tests/skill-suite/test-plan-authoring-rules.sh && bash scripts/validate-skills.sh && bash scripts/zuvo-home/verify-plan-dag docs/specs/2026-08-02-telemetry-failure-count-ssot-plan.md`
  Expected: exit 0 for all three; the rule-numbering assertion now passes; this plan — which already carries `**Failure:**` lines on their own lines — still lints clean under the *unmodified* parser.
- [ ] Acceptance Proof:
  - G5:
    - Surface: docs
    - Proof: `bash tests/skill-suite/test-plan-authoring-rules.sh > zuvo/proofs/task-6-report.md 2>&1`
    - Expected: exit 0 — template field present on its own line, rules list strict 1..N within its own section, Completion Gate item present, exactly the three enum tokens named.
    - Artifact: `zuvo/proofs/task-6-report.md`
  - G6 (plan half):
    - Surface: docs
    - Proof: **capture the baseline first, before any edit in this task** — `mkdir -p zuvo/proofs; for f in docs/specs/*-plan.md; do bash scripts/zuvo-home/verify-plan-dag "$f" >/dev/null 2>&1; printf '%s %s\n' "$?" "$f"; done | sort > zuvo/proofs/dag-before.txt` (expect 43×`0`, 3×`2`). Then after the edit, re-run the same loop into `zuvo/proofs/dag-after-t6.txt` and `diff` the two.
    - Expected: empty diff, exit 0 — adding the field to the template changes nothing for existing plans under the unmodified parser. **This task owns the `dag-before.txt` capture**; Task 7 and SMOKE2 both `diff` against it, and `zuvo/` is gitignored so it cannot arrive any other way.
    - Artifact: `zuvo/proofs/task-6-report.md`
  - G18 (plan half):
    - Surface: docs
    - Proof: `test "$(grep -cE 'never the task graph|no alternative|no fail branch' skills/plan/SKILL.md)" -ge 1`
    - Expected: exit 0 — the scope boundary is written into the rule, not just into this plan. (None of the three phrases exists in the file today, so this is falsifiable.)
    - Artifact: `zuvo/proofs/task-6-report.md`
- [ ] Commit: `feat(plan): let a task declare its failure strategy — the retry machinery was global, the plan author never got a say`

### Task 7: Declared failure strategy — DAG enforcement
**Files:** `scripts/zuvo-home/verify-plan-dag`, `tests/skill-suite/test-plan-dag-failure-strategy.sh`
**Surface:** config
**Complexity:** complex
**Dependencies:** Task 6
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED: New `tests/skill-suite/test-plan-dag-failure-strategy.sh` (in `skill-suite`, not
      `tests/adversarial/` where the existing verify-plan-dag suite lives — `skill-suite` runs in
      the default `fast` scope and is auto-discovered; note this in the file header so nobody
      "consolidates" it back into the full-only suite). Fixture plans:
      (a) `skip-and-continue` on an in-degree-zero task → exit 0;
      (b) `skip-and-continue` on a task another task depends on → exit **1**, message naming the
          task and its dependents, **and** `--json` carries the reason in a populated array;
      (c) an unrecognised value (`**Failure:** maybe`) → exit **1**, NOT 2 — exit 2 is contractually
          "cannot parse the plan at all" (`verify-plan-dag:5-10`), and conflating them makes the
          linter read as crashing, which is how authors end up disabling it;
      (d) no `**Failure:**` line at all → exit 0 — the backward-compatibility guarantee, asserted
          rather than assumed;
      (e) `**Failure:** degraded: fix later, then re-run` → exit 0 — the free text contains a comma
          and must never be tokenized;
      (f) **near-miss negatives, one fixture per real-world spelling**: `**Failure paths:`,
          `**Failure handling (W1):`, `**Failure case (cross-model finding):`, `**Failure-path unit:`,
          `**Failure modes:`, `**Failure Mode row` → all exit 0, none classified as a declaration;
      (g) a `skip-and-continue` fixture adds **nothing** to the dependency graph — the reported task
          count and edge count are identical to the same fixture with the line removed (G18);
      (h) **cross-file enum parity** — the three tokens named in Task 6's new authoring rule,
          extracted from `skills/plan/SKILL.md`, `diff` clean against this parser's classifier
          tokens. This assertion lives HERE, not in Task 6, because the classifier does not exist
          until this task's GREEN writes it; placing it here is also what makes the Task 7 ← Task 6
          dependency a concrete read of `skills/plan/SKILL.md` rather than mere ordering.
- [ ] GREEN: `scripts/zuvo-home/verify-plan-dag`:
      1. New matcher for the **exact literal** `**Failure:**` (with the closing `**`), anchored at
         line start or after a `·` bullet, exactly like the Dependencies matcher at
         `:98`/`:102-112`. **A loose matcher is the defect this task exists to avoid:** measured
         across 3,136 files in `~/DEV`, there are **0** exact-literal occurrences but **46**
         near-miss `**Failure…` markers in 17 spellings, and `./scripts/install.sh` overwrites
         `~/.zuvo/verify-plan-dag` for every project on the machine.
      2. Classify by prefix into the closed set `halt | skip-and-continue | degraded`. Everything
         after `degraded` is **discarded unread** — never tokenized, never split on `,`. This keeps
         the exit-2 landmine at `:183-188` unreachable from this code path.
      3. Absent line = `halt` = no violation.
      4. In-degree from the already-built adjacency (`adj[t,ac]`, `:165`): a reverse count in the
         same `END` block. `skip-and-continue` with in-degree > 0 → violation via the
         existing machinery (`:246`, `:276-287`) → exit 1.
      5. **`--json` parity:** the emitter has `valid`, `cycles`, `forward_refs`, `missing_deps`
         (`:249-271`). Adding a class to `violations` (`:246`) without a matching array would flip
         `"valid": false` with the reason in **no** array — a consumer sees an invalid plan with
         zero causes. Add `"failure_strategy_violations":[{"task":N,"dependents":[…]}]` and the
         matching print loop in the text branch.
- [ ] Verify: `bash tests/skill-suite/test-plan-dag-failure-strategy.sh && for f in docs/specs/*-plan.md; do bash scripts/zuvo-home/verify-plan-dag "$f" >/dev/null 2>&1; printf '%s %s\n' "$?" "$f"; done | sort > zuvo/proofs/dag-after.txt; diff zuvo/proofs/dag-before.txt zuvo/proofs/dag-after.txt`
  Expected: exit 0; the diff is **empty**. The sweep asserts "no file changed its exit code", NOT "all exit 0" — 3 in-repo plans already exit 2 today on `### Task 6b:`-style id suffixes (`verify-plan-dag:85-89`), unrelated to this change. `zuvo/proofs/dag-before.txt` is captured BEFORE editing the parser.
- [ ] Acceptance Proof:
  - G7:
    - Surface: config
    - Proof: run fixtures (a) and (b); capture rc, stderr and `--json` for each.
    - Expected: (a) rc 0. (b) rc 1, the text message names the offending task number AND its dependent task numbers, and `--json` carries a populated `failure_strategy_violations` array whose entry has `task` and a non-empty `dependents` list. A non-empty `violations` count with an empty `failure_strategy_violations` array is a FAIL, not a pass — that asymmetry is the whole point of the `--json` parity work.
    - Artifact: `zuvo/proofs/task-7-report.md`
  - G8:
    - Surface: config
    - Proof: the in-repo sweep diff above, PLUS an external sweep captured to `zuvo/proofs/external-sweep-before.txt` **before** the parser edit and to `zuvo/proofs/external-sweep-after.txt` after, over `~/DEV/*/docs/specs/*.md`, `~/DEV/*/zuvo/plans/*.md`, `~/DEV/*/docs/**/*plan*.md` (3,136 files), plus `test "$(grep -rlF '**Failure:**' ~/DEV/*/docs ~/DEV/*/zuvo 2>/dev/null | wc -l | tr -d ' ')" -eq 0`.
    - Expected: both diffs empty and the exact-literal count is **0**, matching the recorded baseline. **The in-repo sweep is the BINDING proof** — it is reproducible by anyone with the repo. The `~/DEV` sweep is a machine-local supplement: it cannot run in CI or on another contributor's machine, so record its numbers as evidence but never gate on it alone.
    - Artifact: `zuvo/proofs/task-7-report.md`
  - G6 (parser half):
    - Surface: config
    - Proof: fixtures (c), (d), (e), (f) — assert rc for each.
    - Expected: (c) exit 1 not 2; (d) exit 0; (e) exit 0 with the comma-bearing description ignored; (f) all six near-miss spellings exit 0; (h) the enum-parity diff is empty.
    - Artifact: `zuvo/proofs/task-7-report.md`
  - G18 (parser half):
    - Surface: config
    - Proof: fixture (g) — compare `--json` task and edge counts with and without the `**Failure:**` line.
    - Expected: identical counts — the enum never touches the graph.
    - Artifact: `zuvo/proofs/task-7-report.md`
- [ ] Commit: `feat(verify-plan-dag): enforce skip-and-continue only on in-degree-zero tasks — rule 9 makes an optional depended-on task incoherent`

### Task 8: Close the unproven-AC hole (the mitigation, landing FIRST)
**Files:** `skills/execute/SKILL.md`, `evals/execute.evals.json`
**Surface:** docs
**Complexity:** complex
**Dependencies:** Task 4
**Failure:** halt
**Execution routing:** deep implementation tier

**Dependency rationale (Rule 13).** Task 4 is a same-file serialization on
`skills/execute/SKILL.md`: Task 4 inserts the Step 9b telemetry fence, this task edits the final
Completion Gate and the Final Summary. Task 2 is inherited transitively through Task 4.

**Why this precedes the carve-out.** This gate is the mitigation for Task 9's `skip-and-continue`,
and a mitigation scheduled *after* the risk it mitigates can land without it — Task 9 would be
committable while the hole is still open. It is orderable first because it does **not** depend on
the carve-out: the hole it closes exists TODAY, for the user-chosen skip (`execute:532`) and the
async auto-BLOCKED path (`:537-545`). So it is provable on today's behaviour alone.

- [ ] RED: Add case 3 to `evals/execute.evals.json` (currently 2 cases). Fixture: a small plan with
      **no** `**Failure:**` line anywhere — a plain BLOCKED task under today's rules — whose Coverage
      Matrix maps AC1 to that task **only**, and whose RED references a missing binary so the task
      blocks. Every assertion MUST use a checkable verb from
      `tests/skill-suite/test-eval-corpus-schema.sh`'s allowed list
      (`calls|commits|contains|creates|dispatches|edits|exits|matches|outputs|records|runs|shows|writes`)
      or the case will be blamed on the pre-existing red in that suite:
      (a) the final summary **contains** `### Unproven Acceptance Criteria` listing AC1;
      (b) the header **matches** `## Execution Complete (AC-UNPROVEN: 1)` and not a bare
          `## Execution Complete`.
      Using today's BLOCKED path rather than `skip-and-continue` is deliberate: it keeps this task
      independent of Tasks 6, 7 and 9, and it proves the gate closes the pre-existing hole.
      **Pin the fixture prompt to the async / no-user path** (`execute:537-545`): the skill-eval
      executor has no `AskUserQuestion` tool (`skills/skill-eval/agents/executor.md` frontmatter), so
      without that instruction whether the run reaches `## Execution Complete` after a BLOCKED task
      is left to chance.
- [ ] GREEN: `skills/execute/SKILL.md`:
      1. `COMPLETION GATE CHECK (final)` (`:1152-1166`), inserted directly after the Smoke Proofs
         item (`:1153`) — the same class of whole-feature assertion: every AC in the plan's Coverage
         Matrix must have at least ONE claiming task that ended COMPLETED with an
         `acceptance-verified=` artifact. For any AC whose claiming tasks ALL ended
         SKIPPED / SKIPPED_BY_DEPENDENCY / BLOCKED / BLOCKED_BY_DEPENDENCY, print
         `[AC-UNPROVEN: <AC-id> — claimed by task(s) N,M; final states <states>]`. Zero such lines =
         closed; one or more = the header reads `## Execution Complete (AC-UNPROVEN: <k>)`, never a
         bare `## Execution Complete` (`:1035`).
      2. New Final Summary section `### Unproven Acceptance Criteria`, immediately **before**
         `### Post-Cap Dispositions` (`:1069`) — the same "what the run decided for you" class, and
         the coverage hole should be read first. Empty case: `none — every Coverage Matrix AC has a
         COMPLETED claiming task`.
      No new state is required: AC→task comes from the plan's Coverage Matrix (`plan:297-302`),
      outcomes from `completed[]/skipped[]/blocked[]` (`session-state.md:29-32`) and per-task
      `acceptance-verified=` (`execute:322`).
      **State in the commit body that this closes a hole that exists TODAY** — it is not a guard
      invented for `skip-and-continue`.
- [ ] Verify: `bash tests/skill-suite/test-eval-corpus-schema.sh 2>&1 | grep -Fq 'PASS: evals/execute.evals.json' && python3 -c "import json;assert len(json.load(open('evals/execute.evals.json'))['evals'])==3" && bash scripts/validate-skills.sh`
  Expected: exit 0. The `-Fq 'PASS: …'` is deliberate — a `(PASS|FAIL)` alternation would match either and could never fail. The pre-existing `evals/container-audit.evals.json` FAIL is unchanged and is not this task's.
- [ ] Acceptance Proof:
  - G11:
    - Surface: docs
    - Proof: **MANDATORY** — `Skill(zuvo:skill-eval) execute` against the new case (its stated precondition, "the repo's `evals/` + `.git`", is satisfied here). Capture the per-assertion report path from `zuvo/reports/`. Genuine unavailability of the eval runner is a `BLOCKED_*`, **never** a downgrade to a deferred proof.
    - Expected: assertions (a) and (b) both pass, demonstrating the gate fires on today's BLOCKED path and the header is non-bare.
    - Artifact: `zuvo/proofs/task-8-report.md` (linking the `zuvo/reports/` eval report)
- [ ] Commit: `fix(execute): report ACs left unproven by skipped or blocked tasks — every gate reported green on them`

### Task 9: Declared failure strategy — execute side
**Files:** `skills/execute/SKILL.md`, `shared/includes/session-state.md`, `shared/includes/no-pause-protocol.md`, `tests/skill-suite/test-plan-authoring-rules.sh`, `evals/execute.evals.json`
**Surface:** docs
**Complexity:** complex
**Dependencies:** Task 1, Task 2, Task 4, Task 5, Task 6, Task 7, Task 8
**Failure:** halt
**Execution routing:** deep implementation tier

**Dependency rationale (Rule 9 — every edge is a concrete read).** Task 4: reads the
`# >>> zuvo:task-telemetry` fence key list to add `failure-strategy`, and shares
`skills/execute/SKILL.md` + `shared/includes/session-state.md`. Task 6: extends
`tests/skill-suite/test-plan-authoring-rules.sh`, which Task 6 creates, and honours the
`**Failure:**` field Task 6 defines. Task 7: SMOKE2 diffs `zuvo/proofs/external-sweep-before.txt`, which Task 7 captures — that is the
concrete read. (The ordering argument, that execute must not honour a declared strategy before the
linter can reject an incoherent one, is a second reason, not the Rule 9 justification.) Task 8: shares `skills/execute/SKILL.md` and `evals/execute.evals.json`, and its gate is
this task's required mitigation. Tasks 1, 2 and 5: this task owns SMOKE1-3, whose proofs read the
`category-consistency` output (T1, T2) and the `# >>> zuvo:retro-telemetry` fence (T5).

- [ ] RED: Extend `tests/skill-suite/test-plan-authoring-rules.sh` with cross-file assertions that
      can actually fail: (a) `grep -Fq 'Never silently skip or auto-resolve a BLOCKED task.'` in
      `skills/execute/SKILL.md` — **the anti-regression assertion this carve-out exists for**;
      (b) the carve-out table between the literal HTML-comment anchors
      `<!-- zuvo:blocked-carveout-start -->` and `<!-- zuvo:blocked-carveout-end -->` has exactly 4
      `|`-rows (header + separator + 2 data rows); (c) the reason code `skipped-plan-declared`
      appears in **both** `shared/includes/session-state.md` and `skills/execute/SKILL.md`;
      (d) `failure-strategy` appears in the Required Telemetry field list **and** in the
      `# >>> zuvo:task-telemetry` fence's key list; (e) the sentence stating that `degraded:` never
      produces a `BLOCKED_*` state appears in **both** `shared/includes/no-pause-protocol.md` and
      `skills/execute/SKILL.md` (cross-file, so a one-sided edit fails).
      Also add case 4 to `evals/execute.evals.json`: a plan whose Task 1 carries
      `**Failure:** skip-and-continue` and blocks; assertions (checkable verbs only) that the run
      **records** it SKIPPED with reason `skipped-plan-declared`, **outputs** `[AUTO-DECISION]`
      without presenting the three-option BLOCKED prompt, and **contains** the
      `### Unproven Acceptance Criteria` section Task 8 added.
- [ ] GREEN:
      1. `skills/execute/SKILL.md:528` carve-out. Preserve the sentence **verbatim** as the opening
         clause, then state that "silently" is the load-bearing word, then a **closed two-row
         table**. **Wrap that table in the literal HTML comments
         `<!-- zuvo:blocked-carveout-start -->` / `<!-- zuvo:blocked-carveout-end -->`** — the same
         idiom as `PLATFORM:CURSOR` at `:537`/`:545` — because RED (b) and the G6 proof key on those
         exact strings; without them the awk range matches nothing and the proof fails on a correct
         implementation. Rows: `halt` / absent → the existing three options, byte-unchanged
         (`:530-535` must not be touched); `skip-and-continue` → no prompt, mark SKIPPED with reason
         code `skipped-plan-declared`, print `[AUTO-DECISION]: Task N blocked; plan declares Failure:
         skip-and-continue → SKIPPED. Blocker: <one line>.` (reusing the `[AUTO-DECISION]:` marker
         already at `:544`), propagate `SKIPPED_BY_DEPENDENCY` per the existing Dependency State
         Contract, continue. Add: "An agent may NEVER infer, upgrade, or invent a Failure strategy
         at run time. It reads the one the approved plan declares, or it prompts." — an approved
         plan's `**Failure:**` line is human-attributable; an agent-chosen strategy would not be
         (`no-agent-typable-bypass`).
      2. Same file: `degraded:<desc>` is read at exactly ONE site — Post-Cap Autonomous Disposition
         (`no-pause-protocol.md:40-52`), where it pre-authorises case (c) with a named fallback and
         records through the existing `[POST-CAP: DEFERRED] … default=<X>` form into the existing
         `### Post-Cap Dispositions` section (`:1069-1073`). **Do not add a parallel section.** One
         explicit sentence must state `degraded:` never yields a `BLOCKED_*` state — put it in
         **`shared/includes/no-pause-protocol.md`, inside the Post-Cap Disposition section
         (`:40-52`)**, because `:30` of that same file lists `BLOCKED_*` as a legitimate stop and a
         literal-minded agent reading only that file would take "reduced outcome" for a gate
         failure. Add the mirror sentence in `skills/execute/SKILL.md` so the two files agree, and
         assert both in RED (e) below.
      3. Same file, Required Telemetry (`:310-324`): add `failure-strategy` with its three values,
         defaulting to `halt` when the plan line is absent.
      4. `shared/includes/session-state.md:66-76`: new reason-code row
         `| skipped-plan-declared | The task hit a hard blocker and its plan task declared **Failure:** skip-and-continue |`,
         distinct from `skipped-user` (decided live) and `skipped-dependency` (propagated).
      5. Dependency State Contract (`:821-840`): **no change** — `skip-and-continue` reuses
         `SKIPPED`/`SKIPPED_BY_DEPENDENCY` and `:836-837` already covers propagation. Say so in the
         commit body so a reviewer does not hunt for a missing edit.
- [ ] Verify: `bash tests/skill-suite/test-plan-authoring-rules.sh && bash scripts/validate-skills.sh && grep -Fq 'Never silently skip or auto-resolve a BLOCKED task.' skills/execute/SKILL.md && bash tests/skill-suite/test-eval-corpus-schema.sh 2>&1 | grep -Fq 'PASS: evals/execute.evals.json' && python3 -c "import json;assert len(json.load(open('evals/execute.evals.json'))['evals'])==4"`
  Expected: exit 0; the verbatim clause is present; the cross-file assertions pass; the corpus validates **and** actually holds 4 cases — the count is asserted, not claimed in prose (Task 8 asserts its own `==3` the same way).
- [ ] Acceptance Proof:
  - G9:
    - Surface: docs
    - Proof: `grep -Fq 'Never silently skip or auto-resolve a BLOCKED task.' skills/execute/SKILL.md && ! git diff <task-base-sha>..HEAD -- skills/execute/SKILL.md | grep '^-' | grep -qF 'Never silently skip'`
    - Expected: exit 0 — the clause is present, and no removal line carries it. (The leading `!` is required: a grep with no match exits 1, so the negation is what makes "absence" a pass.)
    - Artifact: `zuvo/proofs/task-9-report.md`
  - G10:
    - Surface: docs
    - Proof: `grep -qF 'skipped-plan-declared' shared/includes/session-state.md && grep -qF 'skipped-plan-declared' skills/execute/SKILL.md`
    - Expected: exit 0 — present in both files.
    - Artifact: `zuvo/proofs/task-9-report.md`
  - G6 (execute half):
    - Surface: docs
    - Proof: `test "$(awk '/<!-- zuvo:blocked-carveout-start -->/,/<!-- zuvo:blocked-carveout-end -->/' skills/execute/SKILL.md | grep -c '^ *|')" -eq 4 && ! git diff <task-base-sha>..HEAD -- skills/execute/SKILL.md | grep -q '^-.*Skip this task'`
    - Expected: exit 0 — exactly 2 data rows inside the anchored table, and the existing three-option block was not deleted.
    - Artifact: `zuvo/proofs/task-9-report.md`
  - G18 (execute half):
    - Surface: docs
    - Proof: `! grep -qiE 'fail branch|alternative task|branch to task' skills/execute/SKILL.md`
    - Expected: exit 0 — no branching-DAG concept was introduced. (Honest limitation: no match exists today either, so this guards against regression rather than proving new work.)
    - Artifact: `zuvo/proofs/task-9-report.md`
  - G11 (skip-and-continue half):
    - Surface: docs
    - Proof: **MANDATORY** — `Skill(zuvo:skill-eval) execute` against eval case 4.
    - Expected: the run records SKIPPED with `skipped-plan-declared`, emits `[AUTO-DECISION]` with no three-option prompt, and still prints the `### Unproven Acceptance Criteria` section.
    - Artifact: `zuvo/proofs/task-9-report.md`
  - SMOKE1:
    - Surface: integration
    - Proof: `A=zuvo/proofs/smoke-full-verify.md; bash scripts/validate-skills.sh > "$A" 2>&1; grep -q 'count-consistency: OK' "$A" && grep -q 'category-consistency: OK' "$A"; bash tests/run-all.sh >> "$A" 2>&1; test "$(sed -n '/FAILED children:/,$p' "$A" | grep -c '^  - ')" -eq 1 && sed -n '/FAILED children:/,$p' "$A" | grep -q 'container-audit' && bash scripts/build-codex-skills.sh && bash scripts/build-cursor-skills.sh && bash scripts/build-antigravity-skills.sh`
    - Expected: exit 0. Note the deliberate `;` after `run-all.sh` — it exits 1 whenever `FAIL>0`, and the expected `FAIL=1` is the pre-existing foreign failure, so an `&&` chain could never reach the build step. The assertion counts entries in the `FAILED children:` block so "the ONLY failure is container-audit" is actually established, not merely matched somewhere in the log.
    - Artifact: `zuvo/proofs/smoke-full-verify.md`
  - SMOKE2:
    - Surface: config
    - Proof: re-run the in-repo and external plan sweeps and diff against `zuvo/proofs/dag-before.txt` (captured by Task 6) and `zuvo/proofs/external-sweep-before.txt` (captured by Task 7).
    - Expected: both diffs empty.
    - Artifact: `zuvo/proofs/smoke-dag-compat.md`
  - SMOKE3:
    - Surface: integration
    - Proof: run the `# >>> zuvo:task-telemetry` fence 3 times into a fresh `mktemp -d` (directory NOT pre-created), then the `# >>> zuvo:retro-telemetry` fence against the result.
    - Expected: the file is created despite the missing directory; 3 lines; the reader aggregates all 3 and exits 0.
    - Artifact: `zuvo/proofs/smoke-telemetry-roundtrip.md`
- [ ] Commit: `feat(execute): honour a plan-declared skip-and-continue without weakening the never-silently-skip rule`

## Whole-feature Smoke Proofs

Owned by Task 9's Acceptance Proof block — it is the last task, and its Dependencies name every
task whose artifacts these proofs read (Rule 9), which is why its dependency list is long. No separate smoke-runner task is authored: each
proof is a shell sequence over existing artifacts, and the runner is the
`zuvo/proofs/smoke-*.md` capture itself.

- **SMOKE1 — the repo still validates and builds end to end.** `validate-skills.sh` exits 0 with
  both `count-consistency: OK (N)` and `category-consistency: OK (N)`; `tests/run-all.sh` shows
  **FAIL=1 and only the pre-existing `container-audit` failure** (PASS ≥ 61 plus the new suites);
  all three `build-*-skills.sh` scripts exit 0, proving the new frontmatter key breaks no build.
  Artifact: `zuvo/proofs/smoke-full-verify.md`
- **SMOKE2 — no plan anywhere changes its lint verdict.** In-repo and external sweeps diff empty
  against their recorded baselines. Artifact: `zuvo/proofs/smoke-dag-compat.md`
- **SMOKE3 — the telemetry round-trip works writer→reader**, including the missing-directory case.
  Artifact: `zuvo/proofs/smoke-telemetry-roundtrip.md`
