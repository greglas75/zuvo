# Assess the refactor against its baseline

Use this policy for `preserve_behavior` runs. It governs CQ, review disposition and completion
within this skill; it does not change standalone code-audit scores, release rules or project gates.

## Compare before deciding what blocks

Keep the full post-audit and its original scores/severities. Independently classify every failure:

- **Introduced or worsened:** the diff creates the defect, expands its exposure, or worsens the
  measured violation. It remains a current failure and must be addressed within authorization.
- **Baseline debt:** the same defect is proven at the pinned pre-refactor SHA, is outside the
  requested remediation targets, and the change neither worsens it nor expands its exposure.
  This may include code moved verbatim. Retain the finding, severity and follow-up location.
- **Unproven:** comparison, caller evidence or required review is missing. Record INCOMPLETE;
  neither green tests nor the phrase "pre-existing" establishes baseline debt.

For baseline debt, record the baseline SHA, before/after file and symbol or measurement,
caller/boundary comparison, and the independent reviewer's artifact and actual runtime model.
A move's identical body alone is insufficient: check changed callers, trust boundaries, call
frequency, resource lifetime, error propagation and exports. A file newly added by extraction
can carry an old defect; a byte-identical function can acquire a new defect through new callers.
For structural limits, measure both versions: reducing a file while it remains above the limit
retains a failing absolute score but is not a new violation. Increasing it is not baseline debt.

The existing independent CQ/review pass validates this classification; include this reference
and baseline evidence in that pass, without adding a separate provider loop. Runtime model
metadata determines reviewer identity; an LLM's self-description is not model telemetry.
A severity increase requires re-review at that severity; an earlier low-severity classification
cannot automatically settle the new concern. New contradictory evidence reopens the finding.

## Record two distinct outcomes

The full code-quality report may still say FAIL. Do not edit it to PASS, rescore failures as N/A,
or inflate its denominator. `cq_after` records the assessed **refactor delta**, with links to the
unchanged full report, baseline debt ledger and independent delta review. For example:

```json
"cq_after": {
  "status": "WARN",
  "scope": {"assessment": "refactor delta", "base_sha": "<pinned SHA>"},
  "critical_failures": [],
  "artifacts": {
    "full_post_audit": "<existing raw CQ report>",
    "baseline_debt": "<existing ledger with before/after evidence>",
    "delta_review": "<existing independent review artifact>"
  }
}
```

Use WARN when verified baseline debt remains; PASS only when no such debt or current failure
remains. Put introduced/worsened failures in the current CQ fields; unresolved critical failures
still block even with `--force`. Unproven classification or incomplete mandatory audits remain
INCOMPLETE. Do not copy a full-report FAIL into the delta and then silently delete its findings:
preserve the raw report and reconcile every failing ID in the ledger first.

The CLI validates declared current assessments. It cannot infer semantic scope or prove a
reviewer's classification from arbitrary prose. That comparison is independently reviewed,
not mechanically guaranteed; report this limitation. The example is not a bypass flag.

## Completion and remediation

In the review ledger, `baseline-debt` is a separate, reviewed disposition at the original severity,
not `fixed`, `false-positive` or N/A. It can settle a finding for this preserve-behavior refactor
only while the evidence above holds. Report **refactor complete with existing debt**, not code
quality PASS, when all current requirements and project gates pass. This does not authorize push,
merge or deployment and never overrides an explicitly required remediation target.

Do not add caps, truncation, fallback behavior or API changes merely to remove an old finding.
Authorized fixes use the usual separate red/green proof. New regressions, changed exposure,
unresolved product decisions inside the requested work, and missing evidence remain blockers.
Finish edits, mutant triage and review before the final full suite; reuse matching completed
checks for assessment-only corrections. Do not rerun an unchanged repository to repair report prose.
