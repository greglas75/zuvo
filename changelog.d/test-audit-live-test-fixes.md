## test-audit: fixes from the live test on Sonnet and Codex (batch route, Q-gate scoring, report consistency)

- `model-run --access read` lets the Codex client re-exec through its symlinked path (`dirname` of the client is
  executable in the `zuvo_read` profile). Before, every read-only batch auditor on a symlinked install died with
  `rc=4` (`Operation not permitted`). `zuvo:review` and `zuvo:code-audit` run through the same code and get the fix.
- The router detects the innermost host first: a Codex child that inherited `CLAUDECODE=1` and `CLAUDE_MODEL` is
  `platform=codex`, so the own-vendor guard no longer sends a Codex session's review to Codex.
- The batch helper takes `setup --mode quick|standard|deep`, and the batch prompt carries `Audit mode:` so a
  `--quick` run no longer gets a full-depth report.
- Q20-Q25 have explicit triggers and are N/A (outside the denominator, never 0) when the repo has none: test levels,
  a mutation artifact, a property-test library, a shared contract artifact, configured randomized order, CI coverage.
- Q7 asks for error type AND message where an error is expected (one assertion, or separate tests of the same
  path); Q11 counts control flow, not members of a constant table; Q3 applies to state-changing mocks only.
- A file whose every test is REMOVE is a "REMOVE file": no A-D tier, its own row in the tier table, and the
  headline carries `<N> tests proposed for removal in <M> files, <K> REMOVE files`. This replaces "Tier C at best".
- One run-line format (13 TAB fields, `run-logger.md`), `--commit` defaults (`--quick` implies `off`), one Phase 5
  backlog step, and `append-runlog` verifies `test-quality-audit-<date>.md` instead of skipping it.
- evals: test-audit has 10 cases (added N/A conditional gates, Q7 split type/message with a constants list,
  a REMOVE-only file headline, and a pure-read mock under Q3).
