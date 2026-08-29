# Lightweight Mutation Probes (write-tests Step 3.3)

> A cheap, planned substitute for full mutation testing: 3–5 hand-picked
> mutations that the new test suite MUST kill. A suite that survives an
> inverted main condition or a deleted error fallback is asserting shape, not
> behavior — no Q-score catches that; a probe does.

## First: is a real mutation runner already configured here?

If the project already ships one, USE IT for the file just written — a reproducible score
beats five hand-picked probes, and re-deriving what the project can already measure was a
gap this file used to have. Detection is read-only; the table of signals and scoped commands
is `skills/mutation-test/SKILL.md` § 0.1b.

| Runner | Scoped to ONE file |
|--------|--------------------|
| StrykerJS | `npx stryker run --mutate <file>` |
| Infection | `vendor/bin/infection -- <file>` (positional; `--filter` is deprecated since 0.34) |
| mutmut | **no per-file path** — `--paths-to-mutate` was removed in mutmut 3.x and scoping is config-only; Python falls back to the probes below |
| cargo-mutants | `cargo mutants -f <file>` |
| PIT | `./gradlew pitest -Dpitest.targetClasses=<class>` / the maven equivalent |

Three limits, and they are what keep this from becoming a second mutation-test:

1. **NO consumer of this include ever installs anything** — not write-tests, not refactor, not
   any future loader. No consent prompt, no dev dependency, no config generation, no build-file
   edit. Detect-and-use only. The authority to add tooling to someone's project lives in exactly
   one place, `zuvo:mutation-test` § 0.1c, behind a human consent gate; a per-file writing or
   refactoring loop is the wrong place to ask and the wrong place to decide. Runner absent → the
   probe path below, unchanged. (Written as a universal rule because scoping it to one consumer
   by name left the include's other loaders with no statement at all.)
2. **The probes remain the floor, not an alternative.** A native score does NOT license
   skipping them: syntactic mutators do not generate probe classes 2-4 (deleted error
   catch, skipped side effect, changed delegation argument), which are precisely the
   classes a freshly-written suite fails. Run both; record both.
3. **The `rt` ban below applies doubly.** A native runner is a long multi-process job that
   re-runs the suite per mutant — wrapping it multiplies the per-invocation charge across
   every mutant, not once.

Record `native: <score>% (<runner>)` alongside the probe table, or `native: none` when no
runner is configured. A run that had a runner available and did not use it must say why.

## When

- STANDARD tier: 3 probes. COMPONENT tier: 3 probes (5 when complexity == COMPLEX). HEAVY/COMPLEX: 5 probes, at least one per major
  behavior group (session/profile/export/... as split by the inventory).
- LIGHT tier: skip (branch surface too small to justify the runs) unless the
  file has an error fallback — then run probe class 2 only.
- Skip entirely in `--dry-run`.

## Probe classes (pick from the MUTATION TARGETS of the test contract. **Relationship to M1-M5** (`rules/testing.md`): these five probe classes are an EXECUTABLE SUPERSET, not a renaming — class 1 ≈ M1 (invert condition) and class 5 ≈ M4 (change return); M2 (null-guard removal), M3 (operator swap) and M5 (error-message change) remain valid contract targets and are probed via classes 1/5 with the corresponding edit; classes 2-4 (delete error catch, skip side effect, change delegation argument) have no M-equivalent and exist only here)

1. invert the main condition (`if (x)` → `if (!x)`, `>=` → `<`)
2. delete an error catch/fallback (rethrow raw / return undefined)
3. skip a side effect (comment out the dispatch/persist/log call)
4. change a delegation argument (drop or reorder a forwarded param)
5. change a response value (wrong field, off-by-one, empty list)

## Protocol (byte-restore, no git commands)

**Send the WHOLE probe loop to the farm as ONE invocation. Never run it on the workstation,
and never wrap each probe individually.** Both halves matter, and an earlier version of this
line got the first one wrong.

The measurement behind the earlier version of this rule is real: 2026-08-10, one test file, `npx vitest
run <file>` = **1.4 s** against `rt npx vitest run <file>` = **103.4 s**, ~50-75x. But that is
the cost of wrapping EACH probe — a fixed mirror/queue charge paid N times. The conclusion
drawn from it was wrong: the fix is to pay it ONCE.

    rt --light bash -c 'for f in <probes>; do <apply>; npx vitest run "$f"; <restore>; done'

Ten probes then cost one charge, not ten. What running them locally costs was measured on
2026-08-29: 109 local test processes at 421% CPU, load 34, macOS suspending the machine with
`Dark Wake Thermal Emergency`, and a mutation run that died ten minutes in because a
concurrent worktree pulled shared `node_modules` out from under it. The farm was idle at the
same moment.

If the farm is genuinely unreachable, `rt` exits 21 and says so — then skip probing and report
it. Do not fall back to the workstation, and never report a wrapper timeout as a coverage
result.

For each probe:

1. Save the production file's exact current content and sha256.
2. Apply ONE mutation with a targeted `Edit`.
3. Run the target test file(s) only (scoped, not the whole suite), locally per above.
4. Expected: **at least one test fails** (mutant killed).
5. Restore the saved content with `Write` (full original bytes) and verify the
   sha256 matches the pre-mutation hash. Never leave a probe applied; never
   restore via `git checkout`/`git reset` (may sweep unrelated hunks).
6. Rerun the target test file once after the final restore to prove green.

## Recording

```
MUTATION PROBES: [N]/[N] killed | native: [<score>% (<runner>) | none]
| # | class | production line | mutation | killed by |
| 1 | invert-condition | 148 | `if (!r)` → `if (r)` | respondent.controller.spec.ts:142 |
```

- A native survivor is closed the same way a probe survivor is: add the missing behavioral
  assertion, rerun, re-probe. It is not a report to hand onward.

- A probe that SURVIVES is a coverage gap: add the missing behavioral assertion,
  re-run, and re-probe. Do not close the file with a surviving probe.
- A probe whose scoped run errors for infrastructure reasons is recorded
  `probe-error`, not `killed`. 2+ probe-errors → treat mutation probing as
  degraded and say so in the completion block.
- Probes run AFTER the executable coverage gate passes (Step 2.5) and BEFORE
  the blind audit — the audit must see the final, restored production file.
  The post-restore sha256 must equal the manifest's `production_sha256`.
