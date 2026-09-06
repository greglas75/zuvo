# Execution policy — resolve once, share across nested skills

Session instructions and the user's authorization take precedence over skill defaults. Host
markers describe capabilities; they never grant permission. Do not use an include to override a
prohibition on delegation, local tests, indexing, committing or publishing.

At entry, record `zuvo/context/execution_policy.json` with these fields and the instruction/tool
that supports each decision. Resume the current policy; refresh changed capabilities or constraints.

| Field | Values / evidence |
|-------|-------------------|
| `schema` | `1` |
| `context_generation` | A new ID at entry and after compaction; never infer retained contents from disk |
| `host` | Actual harness; gate marker detection uses `hooks/lib/agent-env.sh` |
| `delegation` | `allowed`, `forbidden`, `unavailable`; include the governing instruction |
| `review_independence` | Actual reviewer model/provider; `degraded:same-model` if not independent |
| `runner` | Project's documented command and required wrapper; retain the exact command |
| `local_fallback` | Allowed only when project/session rules permit it; elapsed queue time is no consent |
| `index` | Exact repository identity and permission to index; a user prohibition wins over setup advice |
| `behavior_mode` | `preserve_behavior` (default refactor) or `refactor_and_fix` (explicit authorization) |
| `commit` / `push` | Authorization and required checks from the current session; no new permission ritual |

For the four consuming skills (refactor, mutation-test, test-audit, ship), this policy is the
single decision source for routing. Older examples in generic includes do not override it.
Within the resolved allowed scope, invoking a skill authorizes its required steps; do not ask for the same permission again.
A tool error is recorded as unavailable, not as a passed review or test. A missing mandatory
quality definition blocks that assessment; missing optional enrichment produces a named degraded
result. Load the missing definition only at the phase that needs it, not as an entry blocker.

If delegation is forbidden/unavailable, execute a required audit inline as a separate pass with
the actual sources and evidence. Mark it `degraded:same-model`; never claim independence. Use an
authorized external reviewer if available. If a gate demands independence and none ran, record
that requirement as unmet. No skill authorizes circumventing session tool restrictions.

Order: discover → characterize → transform → verify/review → audit affected tests → ready.
Commits are events within that sequence, not proof that it finished. A pure-move checkpoint may
precede an authorized bugfix commit; quality changes invalidate affected verification and reviews.
Completion, unresolved risks and permission/readiness to publish are separate report fields.
A repo-required full battery before push remains mandatory even if targeted evidence is reusable.

Keep reports, matrices and command receipts in artifacts. Human updates state new findings and
next actions; the final response states outcome, actual checks, limitations and file links.
Do not print every successful gate or narrate unchanged waits unless the host requires an update.
