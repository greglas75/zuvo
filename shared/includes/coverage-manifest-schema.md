# Coverage Manifest Schema (`zuvo-coverage-manifest/v1`)

> The on-disk contract between the write-tests inventory, the test evidence
> mapping, and the executable gate `scripts/test-coverage-gate.py`. The agent
> WRITES this file; only the validator APPROVES it. Never claim a gate result
> the validator did not print.

## Location

```
$ZUVO_DIR/contracts/<production-basename>.coverage.json
```

`$ZUVO_DIR` per `report-output-location.md` (git root `zuvo/`, overridable via
`$ZUVO_OUTPUT_DIR`). One manifest per production file — sibling test files
(split specs) all aggregate into this single manifest. A sibling
`<basename>.contract.md` (written at Step 2, contract-fill sub-step) carries the full test contract +
classification + runner facts; manifest + contract together are the resumable
checkpoint (`--resume`). The gate validates the manifest only.

## Schema

```json
{
  "schema": "zuvo-coverage-manifest/v1",
  "production_file": "src/respondent/respondent.controller.ts",
  "production_sha256": "<sha256 of the production file at freeze time>",
  "stack": "ts|js|python|php",
  "test_files": ["src/respondent/__tests__/respondent.controller.spec.ts"],
  "quality_gates": {"Q7": 1, "Q11": 1},
  "status": "inventory|final",
  "families": ["SIDE-EFFECT-BOUNDARY"],          // optional — matched cross-cutting families (core table)
  "unmatched_shape": "<one-line structural description>",  // REQUIRED when classification fell through ELSE → STANDARD
  "symbols": [
    {
      "symbol": "RespondentController.findOne",
      "kind": "method|function|route|callback|accessor",
      "visibility": "public",
      "production_lines": "18-26",
      "ownership": "owned|delegated",
      "rows": [
        {
          "id": "E1",
          "type": "entry|branch|error_path|side_effect|delegation_contract|async_state",
          "description": "throws Error('Respondent not found') when service returns null",
          "coverage": "FULL|PARTIAL|NONE|STRUCTURAL_ONLY|N/A|PARTIAL-by-constraint|UNREACHABLE",
          "evidence": "spec.ts::throws not-found when service returns null  (PREFERRED — test-name form, formatter-proof)  OR  spec.ts:42 (line form)",
          "note": "required when coverage is N/A / PARTIAL-by-constraint / UNREACHABLE"
        }
      ]
    }
  ]
}
```

Rules the validator enforces (do not restate them from memory — run it):

- every public entry point found by independent AST extraction has a symbol row
- production hash still matches (production edits invalidate the manifest)
- at inventory phase no row may claim `FULL` (nothing is written yet)
- at final phase every owned row is `FULL` or excused with a `note`;
  every owned symbol has ≥1 `FULL` row; `evidence` is either the durable
  `test-file::exact test name` form (PREFERRED — resolved against the real
  test declarations, must match exactly one; survives formatters) or an
  existing `test-file:line` that lands inside a real test; no duplicate and
  no empty evidence; `Q7`/`Q11` are `1`; declared test files exist

## Validator invocation

```bash
# Step 1.7 — after freezing the inventory, before writing any test:
python3 "$ZUVO_BASE/scripts/test-coverage-gate.py" validate \
  --manifest "$ZUVO_DIR/contracts/<basename>.coverage.json" \
  --phase inventory --repo-root "$(git rev-parse --show-toplevel)"

# Step 2.5 — after tests are written and evidence is mapped.
# DO NOT call this directly: `~/.zuvo/verify-tests --manifest <m>` runs the final-phase
# validate as one of its checks and prints its block verbatim, alongside the suite, scoped
# coverage, a scoped typecheck and the mutation run. Calling it here as well is how a run
# ends up issuing the same verification command eight times -- measured on the rig, that is
# the strongest single predictor of a run's turn count. The command below is the FALLBACK,
# for a harness where the helper is genuinely not executable.
python3 "$ZUVO_BASE/scripts/test-coverage-gate.py" validate \
  --manifest "$ZUVO_DIR/contracts/<basename>.coverage.json" \
  --phase final --repo-root "$(git rev-parse --show-toplevel)"

# One-time durability upgrade — rewrite line evidence to test-name form
# (do this right after the final gate first passes; formatters stop
# invalidating the manifest from then on):
python3 "$ZUVO_BASE/scripts/test-coverage-gate.py" refresh \
  --manifest "$ZUVO_DIR/contracts/<basename>.coverage.json" \
  --repo-root "$(git rev-parse --show-toplevel)"

# Semantic freshness hash of a test file (blind-audit freshness guard):
# unchanged output ⇒ the edit was provably non-semantic (comments/whitespace/
# line-wrap/trailing-comma) ⇒ a prior blind-audit CLEAN survives it.
python3 "$ZUVO_BASE/scripts/test-coverage-gate.py" normhash --file <test-file>
```

## Exit codes (act on them, never reinterpret)

| Exit | Meaning | Caller action |
|------|---------|---------------|
| 0 | PASS — AST-grade extraction, all checks green | proceed |
| 1 | FAIL — violations printed line by line | fix every printed row, rerun; NEVER proceed past a FAIL |
| 2 | usage/input error | fix the invocation or manifest path |
| 3 | DEGRADED_PASS — checks green but extraction was textual | record `BLOCKED_DEGRADED` evidence quality; the file may continue ONLY with the blind audit strict; never report a full clean gate |

For TS repos where exit is 3: the repo has TypeScript 7 (Go compiler, no
classic JS API) and no `@babel/parser`. Point `ZUVO_TSC_PATH` at any TS ≤5
`lib/typescript.js` on the machine to restore AST-grade extraction.

## Non-negotiables

- The inventory is generated by the writer but approved ONLY by the validator —
  the same stage never both generates and certifies the symbol list.
- A validator FAIL is not a prompt to edit the manifest into passing. Missing
  symbol → add tests (or an excused row with a defensible note), never delete
  the symbol from extraction's reach.
- Paste the validator's own output block into the run log. Summaries in prose
  are not gate evidence.
