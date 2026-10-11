# Drive-by Findings — record what you noticed outside the task

Canonical "Drive-by findings" step, shared by every skill that reads code to do its job (build,
execute, review, refactor, debug, write-tests, fix-tests, plan, brainstorm). The CALLER
substitutes its own skill name for `<skill>` below.

**Why.** A run reads far more code than it changes. Until this step existed, a security hole, a
1,400-line service or a copy-pasted function the agent read on its way to the task was seen once
and lost: the skill's rules covered only its own fence, and the audits that would catch it run
rarely. The backlog is the place those observations go, so the next person who opens that file
starts with them.

## What is in scope

- **Files this run already read or edited — nothing else.** No repo-wide scanning: that is what
  `zuvo:security-audit`, `zuvo:code-audit` and `zuvo:structure-audit` are for, and a drive-by step
  that scans is an unrequested audit billed to someone else's task. A scoped CodeSift call to
  CONFIRM something you saw (`find_clones`, `analyze_complexity`, `find_references` on those
  files) is fine.
- **Only problems OUTSIDE the task's fence.** Inside the fence the skill's own gates apply and the
  problem is fixed in-run. Outside it you **record, never fix** — a fix there widens the diff past
  what was planned and reviewed.

## Categories and their bars

A finding goes in only when it clears its bar. "This looks messy" clears none of them.

| Tag | Records | Bar (all of it) |
|-----|---------|-----------------|
| `SEC` | Missing auth or tenant scoping (CQ4), secrets/PII in logs, errors or responses (CQ5), injection, XSS, SSRF, path traversal, unsafe deserialization, weak crypto or randomness (`rules/security.md`), a hardcoded credential | A named missing control or source→sink path at `file:line`. "Might be insecure" is not a finding. |
| `BUG` | Wrong behaviour you can state | Input or state → wrong result, at `file:line` |
| `SIZE` | Oversized file or function | File over **2×** its type limit (the CQ11 hard gate, `rules/file-limits.md` or the project's own limits); a type the rules do not list: over 1,000 executable lines. A function over 2× its function limit, or nesting deeper than 4 |
| `DUP` | Duplicated logic | The CQ14 thresholds, with **both** locations cited and confirmed by `find_clones` or by reading both sites side by side |
| `CPLX` | Hard-to-follow function | `analyze_complexity` cyclomatic ≥ 15 (or a manual branch count when CodeSift is absent) |
| `PERF` | Avoidable cost | CQ17: an N+1 query, a query or `await` inside a loop where a batch would do, an unbounded fetch, sync I/O on a request path |
| `DEAD` | Dead code | CQ13: an unreachable branch, or an export `find_references` shows with zero users |
| `READ` | Readability **with a nameable defect** | A name or comment that contradicts what the code does, or a magic value carrying business meaning (CQ12). Style preference never qualifies |

**Confidence.** At least 51% for every tag. `SEC` alone is also recorded at 26-50%, marked
`(low confidence — verify manually)`: a missed vulnerability costs more than a wrong lead.

**Below the bar is dropped on purpose.** `backlog-protocol.md`'s "Zero Silent Discards" governs the
findings a skill was asked to produce. Drive-by observations are a different class: the bars above
ARE the filter, and an observation that clears none of them is not recorded.

**Cap.** At most **5** entries per run across `SIZE`, `DUP`, `CPLX`, `PERF`, `DEAD` and `READ`,
highest severity first. `SEC` and `BUG` are uncapped: they are defects, the rest is debt.

## How to record

1. **Dedup first.** Run `backlog-archive.py lookup` per `backlog-protocol.md`: `OPEN` → bump that entry
   (`Seen`, date, add the source); `ARCHIVED` → re-open it as a REGRESSION; `ABSENT` → append.
   Never a second entry for a known problem.
2. **Append to `memory/backlog.md` resolved per `backlog-protocol.md` "Where the Backlog Lives"**
   (a tracked backlog is the current checkout's copy; an untracked one is the MAIN checkout's),
   one line each:

   ```
   - [ ] B-<file-stem>-<tag>-<short-slug> <path>:<line> — [<TAG>] <the defect, one sentence> | evidence: <what proves it> | severity: <critical|high|medium|low> | source: drive-by:<skill> | conf: NN | <YYYY-MM-DD>
   ```

3. **Never copy a secret into the backlog or the summary.** For a hardcoded credential or PII in a
   log, cite `file:line` and the KIND (`AWS secret key`, `customer e-mail`) — never the value.
   The backlog is tracked in some repos and the summary lands in a transcript.
4. **Sub-agents do not write the backlog.** A dispatched agent that notices one puts it in its
   report's `BACKLOG ITEMS` section with the `[<TAG>]` prefix (`agent-preamble.md`). The
   orchestrator dedups, applies the cap once per run and persists.

## Surface it, then leave a receipt

- **The skill's final summary gets one line:** `Drive-by: N recorded (SEC:a BUG:b SIZE:c DUP:d
  CPLX:e PERF:f DEAD:g READ:h)`, or `Drive-by: 0 recorded`.
- **Every `SEC` finding is also listed by name** under that line: `⚠ SECURITY (drive-by)
  <path>:<line> — <defect> [<severity>]`. A critical or high one goes at the TOP of the final
  summary, not only in the backlog. Two or more `SEC` findings in one module → add
  `Next: zuvo:security-audit <module path>` to the summary.
- **Then, whether or not anything was recorded, the receipt is the one non-optional part:**

  ```bash
  ~/.zuvo/log-drive-by --skill <skill> --sec <a> --bug <b> --size <c> --dup <d> --cplx <e> --perf <f> --dead <g> --read <h>
  ```

  Omitted counts are 0. All zeros is a normal, honest outcome — do not hunt for findings to make it
  non-zero. The receipt lands in `~/.zuvo/drive-by.log`, so a run that skipped the step can be
  told apart from a run that looked and found nothing. The counts are the ones you recorded in
  the backlog, sub-agents' tagged `BACKLOG ITEMS` included — the receipt proves the step was
  reached; the backlog rows are the evidence of what it found.
- **If the helper prints `receipt NOT written` or is missing** (an install older than this step),
  say so in the final summary and carry on — the receipt never blocks a run.

## What this step is not

- Not an audit: no scoring, no repo scan, no verdict change. Neither a finding nor a failed
  receipt fails or blocks the calling skill; skipping the step is what a completion check flags.
- Not a licence to fix outside the fence.
- Not a substitute for `zuvo:security-audit`: it catches what a run happened to read, never the
  code nobody opened.
