# Comparing complete task costs

`token-cohort.py` combines explicit profiler exports and receipts. It retains failed attempts,
retries, unknown runtime and ambiguous costs. It never discovers sessions or contacts a provider.
A successful process means a valid report, including `INCONCLUSIVE`, not a successful experiment.

```bash
python3 scripts/zuvo-home/profile-session.py transcript.jsonl \
  2026-01-02T00:00:00Z 2026-01-03T00:00:00Z --usage-jsonl usage.jsonl
python3 scripts/zuvo-home/token-cohort.py --manifest manifest.json --out comparison.json
```

All paths in a manifest, including paths inside its receipts and envelopes, resolve relative to
**the manifest directory**. Files must be regular files (input symlinks may resolve to regular
files). Output is an atomic replacement of an independent regular file; aliases, hardlinks to
inputs, symlinks, directories and special nodes are refused. Exit 2 means invalid input or an I/O
failure. The old report is preserved on validation failure. No transcript content enters a report.
Reports contain local source paths, identifiers, counters and receipts' experiment metadata.

## Schema v1

This document owns the format used by subsequent runtime, protocol and monitoring operations.
JSON forbids duplicate keys, NaN and Infinity. Numbers are finite and nonnegative; counters are
integers in [0, 2^63-1], never booleans. Aggregate counters remain Python integers. All timestamps
include a timezone. Unknown optional measurements are
`null` or absent, never zero. Every receipt and observation has `schema_version: 1`.

A minimal manifest (the receipt paths can be null while evidence is unavailable):

```json
{
  "schema_version": 1,
  "experiment": "protocol",
  "window_start": "2026-01-02T00:00:00Z",
  "window_end": "2026-01-03T00:00:00Z",
  "policy": {
    "schema_version": 1,
    "frozen_at": "2026-01-01T00:00:00Z",
    "assignment_seed": "pilot-2026-11",
    "min_completed": 10,
    "min_savings_fraction": 0.15,
    "max_p90_regression": 0.10,
    "require_leave_one_out": true
  },
  "attempts": [{
    "task_id": "task-001",
    "attempt_id": "task-001-first",
    "root_thread_id": "parent-thread-id",
    "provider": "codex",
    "model": "exact-model-name",
    "reasoning": "high",
    "workload_class": "implementation",
    "cohort": "unknown",
    "assignment_order": 0,
    "accepted_at": "2026-01-01T01:00:00Z",
    "protocol_ref": "baseline-sha:brief-control",
    "brief_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
    "runtime_receipt": null,
    "result_receipt": null,
    "transcript_paths": ["transcript.jsonl"],
    "missing_transcript_paths": [],
    "usage_paths": ["usage.jsonl"]
  }],
  "observation_paths": []
}
```

`experiment` is `protocol` (default, stage A) or `compaction` (stage B). `attempts` is nonempty.
Identity, model, reasoning, workload, cohort, protocol reference and brief digest are required.
Assignment order and acceptance timestamp are required for control/candidate trial assignments. `provider` is `codex|claude`; `cohort` is
`control|candidate|unknown`. Transcript/usage lists may be absent or empty, producing unknown
coverage. `missing_transcript_paths` records known gaps even when some transcript files exist.
An explicitly listed absent usage/transcript is a coverage gap. Missing receipt files are unknown;
present malformed receipt files are errors. Observation files explicitly listed must exist.

Attempt IDs are globally unique. Attempts appear in chronological retry order. Task metadata,
including cohort, stays identical across retries. For control/candidate tasks, `assignment_order`
is unique per task and follows unique `accepted_at` timestamps;
`policy.frozen_at <= accepted_at <= started_at` is checked. Within each workload class, rank
these prospectively assigned tasks by assignment order. The first arm index is
`int(SHA256(UTF8(assignment_seed + ":" + workload_class)), 16) % 2` in `[control, candidate]`;
subsequent tasks alternate. `unknown` is allowed and cannot enter the comparable arms. Unknown
descriptive tasks are excluded from that assignment sequence; their `assignment_order` and
`accepted_at` may be null or absent. They need no invented historical preregistration and may
use a policy recorded after the observation window. Report `assignment_evidence:unassigned`
explicitly distinguishes them. Their costs remain visible and the comparison is INCONCLUSIVE.
Known acceptance timestamps still cannot follow known attempt starts. Orders need not be contiguous. Accepted order is declared evidence, not a cryptographic proof of prior
registration: retain the original manifest and its commit/hash before accepting work. Do not
change policy, assignment, brief or conditions after inspecting outcomes.

The policy has exactly the seven keys shown above; unsupported keys are rejected, so prompt text
or unrelated extras cannot be echoed into the report. The canonical versioned policy is copied
into every report. Actual pilots require minimum **10 completed
per arm**, at least **15%** fresh reduction, at most **10%** P90 elapsed-time regression and
leave-one-task-out sensitivity. Smaller thresholds are solely for synthetic fixtures.

### Runtime receipt

```json
{
  "schema_version": 1,
  "status": "unknown",
  "declared": {"compaction_threshold": 300000},
  "confirmed": {
    "parent": {"context_window": 828400, "compaction_threshold": null},
    "child": {"context_window": 828400, "compaction_threshold": null}
  },
  "evidence_kind": "bounded-runtime-probe",
  "evidence_paths": ["runtime-observation.json"]
}
```

`status` is `confirmed|unknown`; `declared` and `confirmed` are objects, and `confirmed.parent`
and `.child` are objects or null. `evidence_kind` is nonempty text; `evidence_paths` is a list.
Effective confirmation requires status `confirmed`, existing evidence, and equal nonnull
`provider`, `model`, `reasoning`, `context_window`, `compaction_threshold` in parent and child.
The first three must match the attempt. Window/threshold are positive integers and threshold
cannot exceed window. Partial observations remain unknown even if status claims confirmation.
The declaration never supplies a missing confirmed value. The tool validates receipt consistency;
it cannot independently authenticate the external runtime observation.

The actual bounded probe observed parent and child windows of **828400** but did not expose the
compaction threshold. Its effective status is **unknown**, and stage B is **INELIGIBLE**. There
are no live A/B samples or measured savings to report. A synthetic `KEEP` is only a test result.

### Result receipt

```json
{
  "schema_version": 1,
  "outcome": "completed",
  "reviewer_verdict": "pass",
  "review_corrections": 0,
  "ci_corrections": 0,
  "critical_regressions": 0,
  "started_at": "2026-01-02T00:00:00Z",
  "green_at": "2026-01-02T00:10:00Z",
  "queue_duration_seconds": 60
}
```

`outcome` is `completed|failed|incomplete`; `reviewer_verdict` is `pass|fail|unknown`.
All measurement/outcome fields may be null or absent, yielding unknown evidence.
Correction/regression counts are nonnegative integers. Durations are finite nonnegative numbers.
Green cannot precede start; a known queue duration cannot exceed a known attempt duration.
Explicit success plus passing review is required for a completed task. The last attempt governs
its final outcome; **all attempts** contribute cost, correction counts and queue time. Task time
is earliest attempt start to final successful green, including retry gaps and queue time.
Failed/abandoned tasks remain in the arm's cost numerator with no completion in its denominator.

### Monitoring observation JSONL

Each line contains `schema_version`, `task_id`, `subject_id`, `timestamp`, `state_hash`, `event`,
`nonempty` and `source`. IDs, hash and source are nonempty strings; nonempty is boolean or null.
The closed event set is `pending`, `empty_poll`, `changed_result`, `error`, `stdin_write`,
`probe_interrupt`, `human_interrupt`, `heartbeat`. An observation must refer to a manifest task.

```json
{"schema_version":1,"task_id":"task-001","subject_id":"farm-run-1","timestamp":"2026-01-02T00:01:00Z","state_hash":"pending-state-hash","event":"pending","nonempty":false,"source":"process-monitor"}
```

`heartbeat` is passive telemetry: it remains in event counts but never counts as a genuine poll
or empty repeat, and does not reset the preceding genuine read. Passive monitoring logs must use
this label. `empty_poll` measures confirmed unchanged reads in the supplied model-facing
observations, **not billable model roundtrips or measured token savings**.

An empty repeat is confirmed only when two successive genuine observations for the same task/subject
have the same hash, both are pending/empty_poll, and both say `nonempty:false`. The first,
changed state, terminal result/error, input and interruption never count. A terminal/input/interrupt
ends the pending sequence; a new explicit `pending` is required to restart it. Identical observations
across copied files are deduplicated; conflicting observations at the same instant are invalid.
The nearest preceding genuine observation before window_start establishes context for the first
in-window repeat; only events within [start,end) contribute counts. Absent observations (including
empty files or no observations in the window) yield null counts.
`polling_proxy` remains a distinct T1 tool-label metric. A blocking `rt --wait` can match that
proxy without proving any empty poll. These counts alone do not establish a waiting-time rate
or demonstrate that results/errors were delivered; retain process-monitor evidence for that.

### Optional compaction provenance

T1 usage rows contain no compaction count, so the default report has `compactions:null`.
To supply it, an attempt may list `profiler_summary_paths`. Each file is a schema-v1 envelope:

```json
{
  "schema_version": 1, "accounting_version": 2,
  "window_start": "2026-01-02T00:00:00Z", "window_end": "2026-01-03T00:00:00Z",
  "transcript_path": "transcript.jsonl", "thread_id": "parent-thread-id", "compactions": 2
}
```

Copy the count from that transcript's profiler summary, retaining the exact requested window.
Windows must match; transcript_path must be in the attempt; every supplied transcript must be
covered to produce a total. Equal counts for the same provider/thread are counted once;
conflicting counts fail rather than guessing which export is authoritative. Partial summary
coverage remains null. This envelope is an explicit producer attestation, not inferred metadata.

## Accounting and interpretation

Usage rows must have `accounting_version:2` and the fields emitted by the current profiler:
timestamp, provider, response_id/thread_id/parent_id (nullable), input, cached_input, output,
reasoning_output, fresh, gross, source, polling_proxy and missing_response_id. Canonical sources
are Codex `token_usage_record|info.last_token_usage` and Claude `message.usage`; invented or
provider-incompatible sources fail validation. The tool checks
`fresh=input-cached_input+output`, `gross=input+output`, and subset bounds, then sums the exported
fields. It never reinterprets Claude/Codex cache semantics or adds reasoning to output again.

Known response IDs are global per provider. Across exports, the latest timestamp is the final
usage authority, applied before [start,end) filtering. Equal-time conflicting amounts fail.
Within one transcript T1 already resolves final records in file order. A matching original root thread takes precedence over a parent relationship;
conflicting observed original threads remain ambiguous. A matching root thread or parent thread
proves task ownership; otherwise IDs copied across different tasks are counted
once in `unattributed_cost`, never assigned by filename. Unknown IDs stay ambiguous observations,
and `info.last_token_usage` remains an incomplete UI source. Neither can support complete costs.

`observed_cost` preserves the sum actually observed even when incomplete. A task's `cost` is null
when its accounting is incomplete, start precedes the window, or green is at/after its exclusive end,
while its observed_cost remains available. The report includes
coverage counts, task and attempt outcomes, source paths, arm summaries and quality totals. Unknown
runtime costs are visible in the unknown comparison bucket and excluded from comparable arms.
Unknown runtime never changes the original assignment: `declared_cohort` preserves the manifest's
control/candidate arm, while derived `cohort:unknown` records ineligibility. Descriptive rows
explicitly declared unknown remain unassigned.
Zero completions or incomplete cost produces `fresh_per_completed:null`. Distributions use linear
interpolation at ranks `(n-1)*p`; missing values are omitted and coverage stays explicit. Fresh
distributions include every task with known cost, including failed tasks; elapsed distributions
include completed tasks with known start/green. Queue is reported separately, not subtracted.

A live experiment manifest must hold provider, model and reasoning constant. Comparisons are
stratified by those fields and workload class; descriptive unknown rows are unassigned, not trial
participants. Each stratum needs both arms, complete quality/cost/runtime, the minimum completed
count and equal total task counts per arm. Unequal arm sizes produce `INCONCLUSIVE` with
`unequal_arm_sizes` before comparing raw failure/correction totals; identical per-task rates
must not look worse merely because one arm contains another task. Stage A needs identical
confirmed runtime across arms and one immutable `protocol_ref` per arm, without mixing protocol
revisions. Stage B requires Codex, equal window, the same immutable `protocol_ref` across both
arms, and confirmed control 500000 versus candidate 300000. Task-specific brief SHA256 values
remain provenance: distinct task IDs and acceptance criteria need not produce identical bytes. Different stratum proportions prevent KEEP.
Do not pool providers or change the workload mix and attribute the difference to the protocol.

`KEEP` additionally requires the savings/time policy, no increase in failed tasks or attempts,
review/CI corrections, zero candidate critical regressions, and positive savings after removing any single
task with all its attempts. No outlier is removed from the principal report. Clear adverse
quality/time harm yields `ROLLBACK` once sample size, completeness and comparability are satisfied,
even when positive savings are unstable. Cost harm yields `ROLLBACK` when it remains negative
after every single-task removal. Smaller positive savings below policy are `INCONCLUSIVE`, not
harm. The two sensitivity signs are calculated independently using integer cost/count subtraction
in O(n); positive stability gates KEEP. Incomplete evidence, insufficient samples, a sensitivity
reversal or mixed stratum verdicts yield `INCONCLUSIVE`. Mixed results explicitly report
`mixed_stratum_verdicts`; any adverse stratum also reports `stratum_rollback`, so an inconclusive
aggregate does not hide the adverse evidence. Decision thresholds are practical
criteria, not confidence intervals or a significance test. The report never authorizes rollout.

## Verification

`rt --light bash tests/hooks/test-token-cohort.sh` exercises the public CLI with synthetic data.
Its integration case invokes the real profiler on the committed raw fixtures: parent, child,
copied identity, repeated Claude usage, failed attempt plus retry and both window boundaries.
The hand-calculated combined expected result is fresh 290, gross 590 and four unique responses.
The surrounding unknown/cohort cases are intentionally unsuitable for a live savings claim.
