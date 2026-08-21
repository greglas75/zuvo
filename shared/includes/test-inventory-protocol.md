# Production Surface Inventory Protocol (inventory-before-writing)

> Used by `zuvo:write-tests` Steps 1.6–1.7 and 2.5. The full public-surface
> inventory is built and FROZEN before the first test is written. Writing tests
> first and inventorying later invites rationalizing the existing result — the
> "42 green tests, 13 untouched methods" failure. Manifest format:
> `coverage-manifest-schema.md`.

## Step 1.6 — Build and freeze the inventory (BEFORE the test contract)

1. Run the independent extractor first:

   ```bash
   python3 "$ZUVO_BASE/scripts/test-coverage-gate.py" extract \
     --production "<absolute-path-to-production-file>"
   ```

   Its symbol list is the floor, not the ceiling: add rows for public surface
   the extractor cannot see (dynamic dispatch, route tables, indirectly-called
   public methods) — never remove one it found.

1b. Run the boundary extractor in the same breath — it reads the SOURCE, not the
   classification:

   ```bash
   python3 "$ZUVO_BASE/scripts/test-coverage-gate.py" boundaries \
     --production "<absolute-path-to-production-file>"
   ```

   Every relational operator, boolean operator, `throw`/`raise`, optional chain
   (`a?.b`), arithmetic operator and literal index it prints is an inventory row,
   and its evidence must be a test that sits ON the boundary — not one that
   merely executes the line.

   This is mechanical rather than a judgement call for a measured reason. Across
   **39 suites written for one file**, the mutants separating an 88% suite from a
   91% one were all boundaries the tests never sat exactly on: a `throw` deleted
   outright survived **34 of 39** suites, `value < 0` changed to `<=` survived 27,
   a literal `0` bumped to `1` survived 27, `normalized[0]` shifted to `[1]`
   survived 15. On the React cases the top survivors are removed optional chains
   and swapped booleans instead — same shape, different operator mix.

   `test-edge-cases.md` already asks for "exact threshold N, N-1, N+1", but from a
   row keyed on code TYPE, so a bare comparison inside a pure function never
   triggers it: classification decides whether the rule applies, and
   classification happens before the comparisons are known. Reading the source
   removes that ordering problem.

   Exit 3 means no parser for this language — record `BLOCKED_DEGRADED` for
   boundary evidence. That is not the same as "this file has no boundaries".

2. For EVERY symbol add inventory rows: one `entry` row, plus one row per owned
   conditional branch, per explicit error path (`throw`, rejected dependency,
   catch/fallback), per owned side effect, **plus every boundary obligation from
   1b**. Mark `ownership` honestly — `delegated` is for thin forwarding only, not
   for "hard to test".

3. Write the manifest to `$ZUVO_DIR/contracts/<basename>.coverage.json` with
   `status: "inventory"`, the current production `sha256`, and NO coverage
   claims (nothing is written yet).

4. Print the inventory summary — these are the progress metrics for the rest of
   the file. For COMPLEX files, test COUNT is never presented as progress:

   ```
   INVENTORY FROZEN: <basename>.coverage.json
   public entry points: N
   owned branch rows:   N
   owned error paths:   N
   projected metrics:   methods 0/N, owned rows 0/N, error paths 0/N
   ```

## Step 1.7 — Validate the freeze

```bash
python3 "$ZUVO_BASE/scripts/test-coverage-gate.py" validate \
  --manifest "$ZUVO_DIR/contracts/<basename>.coverage.json" \
  --phase inventory --repo-root "$(git rev-parse --show-toplevel)"
```

- exit 0 → inventory is frozen; proceed to the test contract.
- exit 1 → the extractor found public symbols the inventory missed. Add them
  and rerun. Do NOT start writing tests with a failing freeze.
- exit 3 → degraded extraction (see schema doc); record it, continue, and
  carry `BLOCKED_DEGRADED` evidence quality to the end of the file.

**Step 2.5 is NOT this command.** The inventory-phase validate above is a direct call because
it runs before any test exists, so there is nothing else to verify alongside it. The FINAL-phase
validate belongs to `~/.zuvo/verify-tests`, which runs it together with the suite, scoped
coverage, a scoped typecheck and the mutation run, and prints one verdict. Issuing it separately
at Step 2.5 duplicates a check the helper already ran.

**Freeze semantics:** after Step 1.7 passes, the symbol list is immutable for
this run. Editing the production file (including Step 4.5 bug fixes) changes
its hash and invalidates the manifest — rebuild rows for the changed lines,
re-freeze, and re-run the final validation before closing the file.

## Split rule for large files (mandatory, not advisory)

If ANY of these holds:

```
> 15 public entry points
> 40 owned rows
> 800 production LOC
> 800 projected test LOC
```

split the test surface by responsibility into sibling specs BEFORE writing:

```
respondent.controller.session.spec.ts
respondent.controller.profile.spec.ts
respondent.controller.serialization.spec.ts
respondent.controller.export.spec.ts
```

- Assign every inventory symbol to exactly one sibling spec (record the
  assignment in the manifest row's `evidence` file once written).
- ONE manifest aggregates all siblings — `test_files` lists every spec.
- Write and green each sibling spec fully before starting the next; the final
  validation (Step 2.5) runs once, over the aggregate.
- Never let a sibling boundary become an excuse for dropping symbols: the
  validator sees the union, not the per-file slices.

## Step 2.5 — Map tests to the FROZEN inventory

After writing (per sibling spec order), fill each row's `coverage` + `evidence`
in the manifest — prefer the durable `test-file::exact test name` evidence form
(or convert once with `test-coverage-gate.py refresh` after the gate first
passes; formatters then stop invalidating the manifest) — set
`status: "final"`, record `quality_gates.Q7/Q11` from the Step 3 self-eval,
then run the final validation (see schema doc). The printed
`Uncovered owned rows: 0` from the VALIDATOR — not from the agent — is the only

> **Freeze taxonomy ⊂ blind-audit taxonomy (deliberate).** The manifest tracks entry, branch,
> error path and side effect. `blind-coverage-audit.md` judges nine owned-behavior kinds —
> it additionally owns fallback, callback_forwarding, prop_forwarding, a11y_output,
> async_state and delegation_contract. A file can therefore freeze at `Uncovered owned rows: 0`
> and still fail the later blind audit on a category the freeze never tracked. That is the
> design: the freeze is a mechanical pre-write floor, the blind audit is the semantic
> ceiling — do NOT read a clean freeze as a predicted clean audit.
passing condition. Evidence rules (existing file, line inside a test, no
duplicates, no empties) are enforced by the program; a FAIL is closed by adding
or strengthening tests, never by editing rows into excused states without a
defensible note.
