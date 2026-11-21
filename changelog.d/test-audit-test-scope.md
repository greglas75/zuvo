## test-audit: audits tests by the defect they catch, not by method or file

- Removed the expected-test-count table and the "untested public methods" inventory. The report now lists
  Untested Behaviours (each names the defect a test would catch) and Removal Proposals (REMOVE: render-only,
  snapshot, mock-echo, tautological or wiring tests). Presentational views, wiring and constants are
  NO-TEST-NEEDED: never a gap, outside Q7/Q11, never downgraded in `coverage.md`.
- The post-audit fix workflow only strengthens tests, adds a test for a listed behaviour, and deletes a REMOVE
  item after the user confirms the list; no `--commit` value deletes tests on its own. The Test Quality Gate
  does not apply REMOVE proposals.
- One AUTO TIER-D table (AP13, AP16, AP31). The pre-scan no longer treats AP14 as a red flag, and the SHORT
  template placeholder is `Red flags: [AUTO TIER-D AP ids]` (`test-audit-batch` rejects that echo).
- A critical-gate failure is always Tier C (never B or D) and always a critical-gate failure for the verdict;
  Phase 5 and the routing table now say so.
- `--quick` still cites `path:line` for every Q=0, AP, removal and untested behaviour.
- evals: test-audit has 6 cases (added a view-only render test, a tautological assertion, an untested
  business rule, constants under `--quick`); eval 1's fixtures no longer carry the expected answer in comments.
