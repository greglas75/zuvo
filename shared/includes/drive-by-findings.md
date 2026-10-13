# Drive-by Findings — record what you noticed outside the task

Canonical "Drive-by findings" step, shared by every skill that reads code to do its job (build,
execute, review, refactor, debug, write-tests, fix-tests, plan, brainstorm). The CALLER
substitutes its own skill name for `<skill>` below.

**Why.** A run reads far more code than it changes. Until this step existed, a security hole, a
1,400-line service or a copy-pasted function the agent read on its way to the task was seen once
and lost: the skill's rules covered only its own fence, and the audits that would catch it run
rarely. `backlog-add` keeps those observations: a defect reaches the backlog, debt reaches the
findings ledger, so the next person who opens that file, or the next report built from the ledger,
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

## Categories and what qualifies

An observation is a drive-by finding only when it meets its tag's condition. "This looks messy" meets
none of them. These conditions say what to report; `backlog-add` does not check them, it applies its
own admission bars afterwards.

| Tag | Records | Qualifies when (all of it) |
|-----|---------|-----------------|
| `SEC` | Missing auth or tenant scoping (CQ4), secrets/PII in logs, errors or responses (CQ5), injection, XSS, SSRF, path traversal, unsafe deserialization, weak crypto or randomness (`rules/security.md`), a hardcoded credential | A named missing control or source→sink path at `file:line`. "Might be insecure" is not a finding. |
| `BUG` | Wrong behaviour you can state | Input or state → wrong result, at `file:line` |
| `SIZE` | Oversized file or function | File over **2×** its type limit (the CQ11 hard gate, `rules/file-limits.md` or the project's own limits); a type the rules do not list: over 1,000 executable lines. A function over 2× its function limit, or nesting deeper than 4 |
| `DUP` | Duplicated logic | The CQ14 thresholds, with **both** locations cited and confirmed by `find_clones` or by reading both sites side by side |
| `CPLX` | Hard-to-follow function | `analyze_complexity` cyclomatic ≥ 15 (or a manual branch count when CodeSift is absent) |
| `PERF` | Avoidable cost | CQ17: an N+1 query, a query or `await` inside a loop where a batch would do, an unbounded fetch, sync I/O on a request path |
| `DEAD` | Dead code | CQ13: an unreachable branch, or an export `find_references` shows with zero users |
| `READ` | Readability **with a nameable defect** | A name or comment that contradicts what the code does, or a magic value carrying business meaning (CQ12). Style preference never qualifies |

**Confidence.** Record a finding from 26%, whatever the tag. Where it lands is
`backlog-add`'s decision, by `backlog-protocol.md`'s bar table: `SEC` reaches the backlog from 26%
(below 51% its title is prefixed `(low confidence — verify manually)`, because a missed vulnerability
costs more than a wrong lead), `BUG` from 80% with its anchor, and every other tag stays in the
findings ledger.

**An observation that qualifies for no tag is not a finding.** The conditions above define what a
drive-by finding IS; they are not a filter on findings. An observation that meets none of them is not
recorded at any confidence. Every drive-by finding at 26% or more goes to `backlog-add`, which keeps
it in the findings ledger or files it in the backlog; only a finding below 26% is dropped. So
`backlog-protocol.md`'s "Zero Silent Discards" holds for drive-by findings like any other.

**Cap.** The summary LISTS by name at most **5** findings per run across `SIZE`, `DUP`, `CPLX`,
`PERF`, `DEAD` and `READ`, highest severity first. That is the cap's only effect: every finding still
goes through `backlog-add`, the ledger keeps all of them, and the summary's counts and the receipt
count all of them too. `SEC` and `BUG` are uncapped: they are defects, the rest is debt.

## How to record

1. **The skill running this step makes one `backlog-add` call per finding** (the orchestrator, when
   it dispatched agents), as `backlog-protocol.md` "Persisting a finding: backlog-add" describes. The
   tag is `--class`. For `SEC` and `BUG`, `--anchor` is text copied from
   the cited line. The helper dedupes against both backlog files and the ledger, decides the route and
   writes. Never append to `memory/backlog.md` by hand, and never call twice "to make sure": the
   second call only counts a second sighting.

   ```bash
   ~/.zuvo/backlog-add --repo "$PWD" --class DUP --conf 85 --source drive-by:<skill> \
     --file src/orders/totals.ts --line 40 --also src/cart/sum.ts:12 \
     --title '<the defect, one sentence>' --evidence '<what proves it>' --severity medium
   ```

2. **`--source drive-by:<skill>`, exactly.** The source is the only way to tell a drive-by finding
   from the task's own follow-ups, and the helper refuses any other shape (`bad-source`), so a ticket
   or run id goes in `--evidence`, never in the source. The token has to be exact because a near
   miss is not countable: on 2026-10-12, 80 counted drive-by findings left only ~17 entries anyone
   could find, because the rest were filed under sources like `build RD-2981 / final review`. When an
   existing entry in `backlog-add`'s own format is bumped, the source is added to that entry's list;
   a hand-written (legacy) entry is linked in the ledger and its text, sources included, is never
   edited.
3. **Never copy a secret into a finding or the summary.** For a hardcoded credential or PII in a
   log, cite `file:line` and the KIND (`AWS secret key`, `customer e-mail`) — never the value. The
   backlog and the ledger are tracked in some repos and the summary lands in a transcript.
   `backlog-add` refuses credential shapes (`secret-like-value`) but does not scan for PII.
4. **Sub-agents do not call `backlog-add`.** A dispatched agent that notices one puts it in its
   report's `BACKLOG ITEMS` section in the form `agent-preamble.md` gives (class, conf, site or
   target, anchor, evidence), every item and uncapped. The orchestrator makes one call per item and
   only then applies the report cap, once per run, so the cap never keeps an item out of the ledger.
5. **A non-zero exit is handled as the protocol says:** exit 3 on an input mistake, correct it and
   resubmit once; exit 1, retry once after 2 s. A finding still not persisted goes in the summary
   under `NOT PERSISTED (…)`. Some refusals are not input mistakes: `anchor-not-at-line` or
   `file-not-in-worktree` confirmed by a re-read means the code changed and nothing is filed, and
   `tracked-findings-beside-ignored-backlog` is reported once with its `.gitignore` recipe for the
   user to apply, never fixed by the skill.

## Surface it, then leave a receipt

- **The skill's final summary gets one line:** `Drive-by: N recorded (SEC:a BUG:b SIZE:c DUP:d
  CPLX:e PERF:f DEAD:g READ:h)`, or `Drive-by: 0 recorded`. The counts cover every finding kept,
  including debt findings beyond the 5 the cap lets the summary list by name.
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
  told apart from a run that looked and found nothing. The counts are the same as the summary line's:
  every finding `backlog-add` kept (any verdict but `REFUSED` and `DISCARDED`), uncapped, sub-agents'
  tagged `BACKLOG ITEMS` included —
  the receipt proves the step was reached; the backlog entries and ledger records are the evidence
  of what it found.
- **If the helper prints `receipt NOT written` or is missing** (an install older than this step),
  say so in the final summary and carry on — the receipt never blocks a run.

## What this step is not

- Not an audit: no scoring, no repo scan, no verdict change. Neither a finding nor a failed
  receipt fails or blocks the calling skill; skipping the step is what the skill's own completion
  checklist flags. Nothing reads `~/.zuvo/drive-by.log` automatically yet — it is the record later
  mining compares against runs.log, not a gate.
- Not a licence to fix outside the fence.
- Not a substitute for `zuvo:security-audit`: it catches what a run happened to read, never the
  code nobody opened.
