## audits: one VERDICT rule and one closing order for every audit

- New `shared/includes/audit-postamble.md` is the single source for how an audit decides its VERDICT
  (a tripped critical gate is `FAIL` even with 0 critical findings; a failed Validity or coverage gate
  is `INCOMPLETE`) and for the closing order (report, cross-model review, retro, Validity Gate, run line).
- The 17 `*-audit` skills and `pentest` load it and drop their own VERDICT bands and postamble order
  prose; gate tables, Validity Gate blocks and Run-line templates stay.
- `append-runlog`'s `RETRO_REQUIRED` hint lists the same order.
- seo-audit and geo-audit no longer multiply the overall score by 100 twice; structure-audit, env-audit
  and a11y-audit divide by the dimensions actually in scope; test-audit reviews the real saved report
  path; code-audit files CQ30-34 and CAP5/7/8/25/26 findings as `SEC`.
- The v2-class warning-only grace in security-audit and pentest (due to end in 1.5.0) is removed;
  `--strict-v2` stays as a no-op.
- env-audit eval 3: a tripped ENV1 gate must log `FAIL`.
