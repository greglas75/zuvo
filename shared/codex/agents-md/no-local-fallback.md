<!-- zuvo:no-local-fallback -->
## When the farm is busy, WAIT. Never run the suite locally, never abandon the work.

Measured 2026-08-29: 26 sessions hit `rt`'s queue timeout and fell back to running vitest/stryker in
their own worktree. With 53 worktrees open, 11 node processes across 6 of them drove this Mac to a
load average of **42.9** and macOS put it to sleep with `Dark Wake Thermal Emergency` — 3h22m of it.
Everything then took longer, including the `rt` clients that were still waiting, which produced more
queue timeouts and more of the same. Running the suite here is what turns a busy farm into an
11-hour refactor.

- **A full farm is a WAIT, not an answer.** `rt` does not hand back "no". When no host can seat a
  run it re-places it up to `TF_REPLACE_MAX` (3) times and then QUEUES it: `rt: the fleet is full —
  QUEUING this run instead of failing it.` A queued run holds its place and starts when a slot
  frees. Let it. `rt --attach <runid>` reconnects to one you lost; `rt --queue` shows the line.
- **There is NO cap on attempts.** An earlier version of this rule said "re-queue once, or report
  `BLOCKED_FARM_BUSY` with the run id and stop". It was written against a client that could still
  return a bare refusal, and it cost a real run on 2026-09-03: an agent read it as a two-attempt
  budget, filed `BLOCKED_FARM_BUSY`, and abandoned a finished branch — no push, no PR, no merge —
  over a farm that would have queued it. `BLOCKED_FARM_BUSY` is not a status this fleet emits, and
  no host reporting `busy/allowed` at capacity is a refusal. Do not invent either one.
- **A busy farm never justifies discarding work.** Commit, push, PR and merge are gated on a test
  RESULT, not on how long the queue was. If the tests genuinely have not run, keep the branch and
  the commits, say plainly that the run is still queued, and pick it up when it lands — never
  unwind finished work because a machine was busy.
- **`rt` failing is a REASON TO WAIT, never a reason to run the suite here.** A local suite run
  competes with every other worktree on one laptop.
- **A queue timeout is not a test result.** Do not record it as pass, fail, or "tests inconclusive,
  proceeding" — the tests did not run.
- **Never `--cold`** unless you are deliberately provisioning a host. It disables a cache that hits
  78% of the time and turns a 4-minute run into a full install.
- **Discovery counts too.** `vitest list`, a type-check, a `turbo build` — if it would take more
  than a few seconds, it goes through `rt` like everything else.
<!-- /zuvo:no-local-fallback -->
