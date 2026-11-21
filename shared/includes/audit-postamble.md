# Audit Postamble — verdict rule and closing order (all `*-audit` skills + pentest)

One rule for how an audit decides its VERDICT and one order for how it closes. Every audit skill
loads this file and points at it instead of restating either. Written 2026-11-21 after a
three-model audit of the audit skills found that 9 skills computed VERDICT from the critical
FINDING count alone (a tripped critical gate with 0 critical findings logged PASS while the report
said FAIL), 16 skills wrote `INCOMPLETE`, a value `run-logger.md` did not allow, and 12+ skills
listed the retro / run-line / validity-gate steps in contradicting orders.

## 1. VERDICT — first match wins

| # | Condition | VERDICT |
|---|-----------|---------|
| 1 | Any **critical gate tripped** (the skill's gate table: fires on the FINDING, never on a dimension score of 0) | `FAIL` |
| 2 | **≥4 critical findings** | `FAIL` |
| 3 | Validity Gate `gate_status = FAIL`, or a skill-defined coverage gate FAIL (pentest 2.4, security-audit DEGRADED, db-audit unreachable tool, zero applicable checks) | `INCOMPLETE` |
| 4 | 1-3 critical findings | `WARN` |
| 5 | 0 critical findings | `PASS` |

- A `FAIL` reached by rows 1-2 stays `FAIL` when the Validity Gate also failed: the run proved a
  failure, it only failed to prove coverage. Append `[VALIDITY GATE FAIL]` to NOTES so the
  incomplete coverage is still visible.
- `INCOMPLETE` means "this run cannot certify PASS or WARN". It never upgrades anything.
- "Critical" is the `severity-vocabulary.md` CRITICAL level. A skill whose report uses a different
  word maps it there — it does not invent its own band.
- The report header, the JSON `verdict` field and the Run line carry the SAME value. Compute it
  once, after the Validity Gate, and copy it; never recompute it in a second place.

A skill may be STRICTER than rows 4-5 (pentest: any confirmed CRITICAL finding is `FAIL`; a11y and
security grade bands under rows 1 and 3), never looser: no skill turns a row 1-3 outcome into
`WARN` or `PASS`.

A skill states only WHICH gates are critical and what trips each one (its gate table). It does not
restate rows 1-5. A line like `VERDICT: PASS (0 critical findings), WARN (1-3 critical), FAIL (4+
critical)` is the bug this file replaces — it omits row 1.

## 2. Closing order

1. **Provisional VERDICT** — from the finished findings by §1 rows 1, 2, 4, 5.
2. **Report on disk** — `zuvo/audits/<skill>-<YYYY-MM-DD>.md` (+ `.json` where the skill emits one),
   per `report-output-location.md`, carrying the provisional VERDICT. From here on use the real date
   and the real saved path — never a literal `[date]` placeholder.
3. **Cross-model review** (skills that run one) — on the SAVED path from step 2. Findings it
   confirms or adds go into the report, and step 1 is recomputed.
4. **Retrospective** — `retrospective.md`: `RETRO:` line to `~/.zuvo/retros.log`, long form to
   `~/.zuvo/retros.md`. `append-runlog` refuses a run line without it (`RETRO_REQUIRED`, exit 2).
5. **Validity Gate block** — printed, with `gate_status`. Its `postamble` fields check steps 2-4
   (they have happened by now). If it FAILs, apply §1 row 3 and rewrite the VERDICT in the report
   header and JSON in place, so all three carriers agree.
6. **Run line** — `printf '%b\n' "$RUN_LINE" | ~/.zuvo/append-runlog` (never `>> runs.log`), with
   the final VERDICT.

The wrapper's exit code is about the APPEND, not the audit: a `FAIL` audit appends its line and the
wrapper returns 0. A non-zero exit means the run is not logged: say so to the user with the
wrapper's message — never report the audit as complete. An audit re-entered after stopping early
resumes at the first missing step.

A pre-scan abort (consent declined, nothing to audit) exits before step 2 and writes no run line;
that is `ABORTED`/`BLOCKED` reported to the user, not a logged audit.
