<!-- zuvo:poll-economy -->
## Waiting on something long-running

**An empty `write_stdin` poll is a full model round-trip.** It re-sends the entire conversation to
learn one bit, so it costs about what a reasoning turn costs and buys nothing. Measured on this
machine across 92 sessions: 9,895 poll windows, of which **54% used 30000 ms and 96.8% were below
the documented maximum**. The maximum for an empty poll is **300000 ms**, and using it makes the
same wait cost ten times less.

So:

- **Empty poll → `yield_time_ms: 300000`.** Not 30000, not 10000. A shorter window does not make
  the job finish sooner; it only samples more often. Being on the critical path justifies checking,
  not checking sixty times.
- **Prefer a command that blocks over any polling at all**: `rt --wait <id>`, `gh run watch <id>
  --exit-status`, `bb-merge-pr.sh --wait`, or `until <condition>; do sleep 30; done`. One
  round-trip however long it runs.
- **Never `sleep N; <check>` outside a loop.** It is one whole turn per interval, and a pre-tool
  hook now refuses it.
- **Silence between checks — and this OVERRIDES the general progress-update cadence.** That
  conflict is the reason the earlier, politer version of this line was ignored while the
  `yield_time_ms` line above was obeyed: a parameter is one checkable decision, silence is an
  absence of action competing with an instruction to report often. So, explicitly:

  > After announcing a wait once, emit no assistant commentary until actionable new information
  > exists. A poll result is not new information merely because time passed, the process remains
  > running, output is empty, no errors appeared, progress percentages changed, or some
  > workers/shards remain active. Do not restate status or summarize unchanged state. A message is
  > permitted only when: (a) the operation finishes, (b) it fails or produces an error requiring
  > attention, (c) user input or authorization is required, or (d) a newly discovered condition
  > materially changes the expected outcome or next action. This rule explicitly overrides general
  > progress-update cadence requirements during waits.

  Measured here: 16.4% of assistant messages were restatements of an unchanged wait.
<!-- /zuvo:poll-economy -->
