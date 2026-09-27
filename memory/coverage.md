# Test coverage ledger

| File | Status | Metrics | Q Score | Coverage Gate | Blind Audit | Adversarial | Date |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `scripts/zuvo-home/verify-tests` | `BLOCKED_INCOMPLETE` | methods 0/53 verified, rows 0/348 verified, mutation probes 22/22 killed | 0/2 critical gates (Q7=0, Q11=0; Q13/Q15/Q17 not scored) | `fail:403` (farm run `1790529153-35032-2512`) | skipped: executable inventory gate failed | blocked: executable inventory gate failed | 2026-09-28 |

The four new Python test modules and existing shell tests pass, but the independent inventory has 348 owned rows without behavioral evidence. The `write-tests` process cannot mark this file complete. The skill's split threshold is 60 rows; splitting the 2,300-line helper before continuing this ledger is tracked in the backlog.
