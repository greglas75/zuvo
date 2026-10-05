# Test coverage ledger

| File | Status | Metrics | Q Score | Coverage Gate | Blind Audit | Adversarial | Date |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `scripts/zuvo-home/verify-tests` | `BLOCKED_INCOMPLETE` | methods 0/53 verified, rows 0/348 verified, mutation probes 14/14 killed | 0/2 critical gates (Q7=0, Q11=0; Q13/Q15/Q17 not scored) | `fail:403` (farm run `1790529153-35032-2512`) | skipped: executable inventory gate failed | blocked: executable inventory gate failed | 2026-09-28 |

The four new Python test modules and existing shell tests pass, but the independent inventory has 348 owned rows without behavioral evidence. The `write-tests` process cannot mark this file complete. The skill's split threshold is 60 rows; splitting the 2,300-line helper before continuing this ledger is tracked in the backlog.

| `scripts/zuvo-home/backlog` | `FAILED` | methods 11/11 FULL, rows 152/152 FULL, probes 13/13 killed; coverage.py branch 99% | 5/5 critical gates (Q7=1,Q11=1,Q13=1,Q15=1,Q17=1) | `pass` (verify-tests GREEN, receipt 5622b315) | `fix:6` (panel strict 3/3; 5 passes, last FIX closed by tests not re-audited) | `3 passes: findings fixed (15 production defects), rest rejected with evidence` | 2026-10-06 |

`FAILED` is the write-tests table's state for a blind audit still `FIX` after its budget, not a red suite: 237 tests pass, verify-tests is GREEN and every inventory row has its own test. The panel found finer edge rows on each of 5 passes; the last 6 were covered by tests (a5be53c2) that no panel has re-audited (B-20261006-BLIND-AUDIT-NEVER-CONVERGES).
