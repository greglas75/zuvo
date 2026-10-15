# Backlog

## Open

- [ ] B-leads-T1-jsonl-ext: `.checkpoint-<slug>.json` stores JSONL but uses `.json` extension. Tooling that `JSON.parse`s the whole file will fail. Fix: rename convention to `.checkpoint-<slug>.jsonl` in `lead-output-schema.md` before v1 ships. Source: adversarial task-1 round 2 WARNING.
- [ ] B-20261005-CP-R-A3 A3 (12) zuvo_comment_scan.py:536: the python tokenize fallback has no f-string model. This is the documented degraded mode; consider adding one.
- [ ] B-20261005-CP-BSD-SED [no BSD host in the session]: the builders' new `sed -E` rules (b68bb3b1) were proven only with GNU sed on Linux. Run test-build-path-depth.sh against macOS `/usr/bin/sed` once.
- [ ] B-20261008-TQ-INSTALL-FILE-ATOMIC [P4][test-quality] tests/hooks/test-install-file-atomic.sh — tier C (Q2, Q3, Q7 = 0): assert the complete reasons for symlink refusals and the destination-directory race; check the stand-ins' arguments and non-calls; isolate the linked-destination and mode cases.
- [ ] B-20260928-RT-SKIPS-LINT-GATES make a missing linter FAIL rather than SKIP, and fix the routing
