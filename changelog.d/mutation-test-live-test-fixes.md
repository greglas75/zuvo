## mutation-test: fixes from the cross-model live test

- Off-farm path: `mutation-survivor-reprobe.sh --plan <plan.json> --out <results.json>` runs the LLM
  engine's whole apply, test, restore loop in one process (baseline once per test command, restore
  hash-verified, changed-lines scope enforced, exit 3 when any mutant has no verdict). The skill
  uses it only when `tf-ablate`/`rt` is unavailable and the execution policy permits local runs.
- `report.json` is the as-found result (survivors stay `Survived`); the post-fix state is a
  separate field, and the headline score is the as-found one with the post-fix delta beside it.
- `NoCoverage` counts against the score; ERROR is `RuntimeError`, outside the score.
- `--dry-run` writes nothing (no policy file, retro, run line or report); native dry-run uses
  `stryker-scoped-config.sh --no-write`.
- LLM engine skips static and constant-initializer mutants (as `ignoreStatic`).
- Test fixes land as ONE test-only commit `test: close mutation survivors in <scope>`.
- Whole-file scope only with the literal `--whole-files` flag; prose requests keep changed lines
  and print both sizes.
- The scoped Stryker config no longer carries the unknown `_generatedBy` key.
