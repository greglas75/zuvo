## refactor: defects found by a live three-model test

- One default for a bug found in moved code: `preserve_behavior` pins it, reports it and files it; it is
  fixed in-run only when the request asks for the fix (`SKILL.md` "Behavior mode"). Corpus eval 2 now
  expects that, and eval 3 covers the explicit-fix request.
- Runs that cannot ask or write end in a defined state: `prove.mutation` takes the closed codes
  `N/A:no-test-runner`, `N/A:plan-only`, `not_run:no-native-runner`, `not_run:no-consent` (free text is
  blocked, the `not_run:` pair is a WARN), and a read-only `.git` is probed once and ends at
  `EXECUTION_COMPLETE` through `commit_execution`.
- `refactor-contract`: new `init`, full usage block, `prove characterization_probes`; `set stage` is
  refused and `stage COMPLETE` is refused unless `check` exits 0. The result opens with
  `Gate: refactor-contract check exit=<n>`.
- Phase 3.6 Step 0 no longer forces a twin test file per new module (`covered-via-facade`, 1.5x test-LOC
  smell); characterization adds an override-seam probe; remediation no longer edits frozen
  characterization files or uses `git stash`; review builds its input with `build-review-patch`.
- The contract hash rule is SHA-256 everywhere; the test-audit report template carries a `Status:` row.
