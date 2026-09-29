# Implementation Plan (1 of 2): heading blocks become real backlog entries

**Spec:** inline — no spec
**spec_id:** none
**planning_mode:** inline
**source_of_truth:** inline brief (user decisions of 2026-09-25/27)
**plan_revision:** 7
**status:** Approved
**Created:** 2026-09-27
**Tasks:** 6
**Sequence:** this is PR 1 of 2. It is a self-contained **bug fix** and must land on `main` and be
observed in the wild before PR 2 (`2026-09-27-backlog-grooming-plan.md`, the grooming feature) starts.
Split per the plan skill's rule 17: one long-lived branch carrying both would put a fleet-wide write
hazard behind six more tasks.
**Estimated complexity:** 4 complex / 2 standard. `zuvo_backlog_parse.py` roots the import graph;
`backlog-archive.py` is the only sanctioned write path to a tracked backlog in 88 checkouts and runs
on every skill run via `append-runlog:288`.
**Degraded inputs:** CodeSift index 12 files stale, `index_folder` timed out; every measurement below
is a direct read or an executed probe, re-verified independently by the plan reviewer.

---

## The defect

```
memory/backlog.md:220  is  '## B-driftguard-bounded-age — DONE'
$ python3 scripts/zuvo-home/backlog-archive.py lookup --repo . B-driftguard-bounded-age
ABSENT id:b-driftguard-bounded-age          rc=0
$ python3 scripts/zuvo-home/backlog-archive.py status --repo .
OK …/memory/backlog.md: 43 open, nothing resolved left in backlog.md
```

`iter_entries` `continue`s on every heading line (`zuvo_backlog_parse.py:294-304`), so the `## B-id`
heading-block dialect has **no entry representation in either parser mode**. Every audit skill's
*mandatory* dedup check (`backlog-protocol.md:88-101`) therefore reads ABSENT for these entries and
re-files them as new findings — the loop the protocol exists to prevent.

Chain, each link verified: `DONE_SECTION = ^#+\s*(resolved|done|closed|completed)`
(`zuvo_backlog_parse.py:23`) is prefix-anchored, so `## B-x — DONE` misses → `:325` marks the block's
bullets `open` → `classify()` (`backlog-archive.py:302-308`) walks `checkbox_only=True` and needs
`status == "done"`, so the block is never archivable → `cmd_status` (`:331-335`) prints "nothing
resolved left" → `find()` (`:180`) walks tolerant mode, so `lookup` can only match a sub-bullet key,
never the heading's own id.

### Measured

> **These are point-in-time values and `memory/backlog.md` is a LIVE, git-tracked file.** It grew
> 1812 → 1958 lines during this session alone (backlog appends from this run and from a concurrent
> one), moving tolerant 306 → 328, `checkbox_only` 43 → 65, headings 100 → 102, id-shaped 81 → 82.
> **Every task therefore DERIVES its counts and asserts invariants** (id-shaped count == heading-entry
> count; `is_resolved_inline` == 0; `0 < marker < total`) and pins absolutes in a pre-change golden
> taken from the committed module. A task that hardcodes 306 / 43 / 81 will be red on arrival.
> Values below are as first measured (2026-09-27, 1812-line file); the parenthesised value is the
> same measurement re-taken at Task 1 (1958-line file).


| measurement | value |
|---|---|
| `memory/backlog.md` | 1812 lines / 220,145 bytes; entry raw lines only 69,754 of that |
| heading lines / id-shaped (`zb.BODY_ID_RE` on the post-`#` text) | 100 / **81** (re-taken: 102 / **82**) |
| id-shaped headings with `has_resolution_marker` / `is_resolved_inline` | **24 / 0** |
| `iter_entries` tolerant / `checkbox_only=True` | 306 / 43 (re-taken: 328 / 65) — neither is the entry count |
| id-shaped headings with **zero** sub-bullets | 64 of 81 (pure prose, invisible in both modes) |
| definition ids / content-keyed (`fp:`) entries | 43 / 240 |
| duplicate `entry_key` in the open file | 6 |
| fleet id-shaped heading entries | **1004–1227** across 14–20 of 69–88 backlogs, ~739 `##` + ~488 `###` (two censuses, different roots) |
| fleet **open** heading entries carrying a resolution marker | **170–216** |
| heading entries in any `backlog-done.md` fleet-wide | **0** |
| `backlog-archive.py` size | 648 raw lines / 395 `ast.stmt` nodes; `cmd_archive` 137 lines (382-518), `cmd_drop_stale` 99 (520-618) |

~40% of the fleet population sits at `###`, which is why the discriminator cannot be `^## B-`.

### Two further defects found while planning, both reproduced

- **D1 — `entry_block` cannot delimit a heading block.** It breaks at `^[-*]\s` or `^#{1,6}\s`
  (`backlog-archive.py:374`). On line 220 it returns a **1-line** block while line 221
  (`- **Closed:** 2026-08-18. …`) is plainly its content. Distribution over the 81 id-shaped headings:
  `{1:6, 3:2, 4:3, 6:2, 7:20, 8:12, … 46:1}` — it looks right on ~75 only because their continuation
  happens to be *indented* prose. Data-dependent truncation, green on the majority.
- **D2 — the mint is anchored on the checkbox prefix and no-ops silently on a heading.**
  `cmd_archive:481-484` is `m_cb = re.match(r"^(\s*[-*]\s*\[[ xX]\]\s*)", block[0])` then `if m_cb:`.
  On `## B-x` nothing matches, nothing is inserted, **nothing is reported**. The heading mint is a new
  untested code path, not a reuse of a tested one.

### The boundary trap that a naive fix walks into (found by plan review, then reproduced)

"Terminate on the next heading of level ≤ mine" is wrong on the flagship entry. After the block at
line 220, lines **240-243 are four independent, OPEN `- [ ]` entries** (`B-refactor-gate-nul`,
`B-plan-gate-fileformat`, `B-plan-gate-format-variance`, `B-adversarial-single-cli-host`); the next
`#{1,2}` heading is not until line 246. A level-only terminator sweeps those four into
`backlog-done.md` via `drop.update(range(idx, end))` (`:487`), and the `staying` guard at `:410`
cannot stop it because it keys on the *archived* entry's key, not the siblings'. **A line-level
conservation check passes** — every line lands exactly once. The defect is mis-attribution, not loss,
which is precisely the class `cmd_archive`'s own checks (`:501-507`) cannot express.

Correct rule, executed: terminate on the next heading of level ≤ own **or** the next flush-left line
that is itself a checkbox entry (a sibling, never continuation), then trim trailing blanks.
`- **Closed:**` is flush-left but not a checkbox, so D1's real case stays covered. That yields **lines
220-238 (19 lines)** and leaves line 240 open. Flush-left checkbox entries following a heading are
**siblings, not `parent_key` children** — only indented checkboxes are children. That is a *measured*
rule, not an absolute one: across the fleet, 95 heading blocks terminate on a flush-left checkbox and
**89 of those terminators are a genuine `B-`-id sibling while 6 are a non-id checkbox that is really
the heading's own child** (`tgm-survey-platform/memory/backlog.md:2269`, `:2889`, `:3547`;
`QuotasMobi/memory/backlog.md:393`, `:403`; `data-lab-wt-exportpoll/memory/backlog.md:1540`). On this
repo all 5 checkbox terminators are genuine siblings. For those 6 the block truncates to a stub and
`child_open` reports 0, so the children are invisible to both halves — an **accepted residual** in the
under-cover direction decision 1 chooses, with a live hazard of 0 today (the one marker-carrying case,
`:2889`, is a genuinely parked unrelated finding). Task 3's spike prints this classification so the
residual stays measured rather than assumed.

---

## Technical Decisions

| # | Decision | Rationale |
|---|---|---|
| 1 | A heading at **any** level `#`..`######` is an entry iff `zb.BODY_ID_RE` matches the text after the `#`s | id-anchored, so it can only under-cover, never over-cover — the right direction to be wrong in for a helper that writes a tracked file under a lock. 19 of 100 headings here are entry-shaped without an id (`:246`, `:529`, `:1084`); they surface as `NOT-VERIFIABLE — heading-shaped entry with no id` in PR 2, never silently dropped |
| 2 | `iter_entries(text, *, checkbox_only=False, kinds=None)`; `DEFAULT_KINDS = (CHECKBOX, BULLET, TABLE)` = today's tolerant set exactly; both args → `ValueError` | `checkbox_only` conflated "is this an entry?" with "which dialect?", which is why one helper family sees 43 and the other 306 |
| 3 | `checkbox_only=True` stays a **permanent documented alias**, not a deprecation | 7 of 9 call sites use it and all are write/gate paths reached through `append-runlog`, where a `DeprecationWarning` on stderr is indistinguishable from a failure |
| 4 | `Entry` gains `kind` / `end_lineno` / `parent_key` **appended last with defaults** | a NamedTuple's field order is its tuple order; old-arity positional construction must keep working and is asserted (the only real probe of the rule) |
| 4b | A heading entry's `section` is the nearest **enclosing** heading of a *strictly lower* level, or empty at top level — never a sibling. A heading entry's status is `has_resolution_marker(body) and not REOPEN_RE.search(body)` | Both were settled during execution against a contradictory instruction and are recorded here so the code and the plan agree. The orchestrator's own worked example (`## Open` / `## B-alpha` → `'Open'`) contradicted the rule it accompanied, because `## Open` is the SAME level there, so the rule yields `''`. The rule won, decided by the corpus: 83 of 84 id-shaped headings sit at level 2 under a level-1 heading, so the rule gives the enclosing section in the real file, while the variant that rescues the flat example makes 43 entries point at unrelated prose headings hundreds of lines back. The flat same-level case is pinned to `''` in `siblings.md` as a visible decision. Separately, `has_resolution_marker` alone treats a `[REGRESSION …]` re-open marker as closed (measured: heading path `done`, bullet path `open` on identical text) — pre-existing usage always stacked it on a checkbox `status != "done"` guard, and promoting it to the SOLE status source for headings imported that blindness, so `REOPEN_RE` is now checked too |
| 5 | Heading status = `has_resolution_marker(heading_text)`, never `DONE_SECTION`, never `is_resolved_inline` | measured 24/81 vs 0/81; the marker sits at the **end** of these lines, which is exactly what the prefix-anchored regex misses |
| 6 | The heading archive path is **opt-in behind `ZUVO_BACKLOG_HEADING_ARCHIVE=1`**, defaulting off | separate *commits* give zero protection: `install.sh:826` globs `scripts/zuvo-home/*` into `~/.zuvo/`, which is machine-global across all 88 checkouts, and `append-runlog:288` runs `backlog-archive.py archive --repo "$PWD"` on **every skill run in every repo**. So the moment the helper is installed, 170-216 marker-carrying headings would be archived — under `Lock`, into tracked files. An env gate is the only thing that survives another agent running `install.sh` mid-plan |
| 7 | Every Acceptance Proof invokes `python3 scripts/zuvo-home/…`, never `~/.zuvo/…` | the repo copy and the installed copy are byte-identical today, so a `~/.zuvo` proof would silently test the *old* helper until `install.sh` runs |
| 8 | CQ11 stated honestly, not claimed fixed | `backlog-archive.py` is 648 raw / 395 AST statements — already over the 400 default (`rules/file-limits.md:253-260`; 800 = automatic FAIL). Task 5 brings `cmd_archive` and `cmd_drop_stale` under the 50-line public-function limit, taking the module to ~450 raw. **It still does not clear 400**; the residual is filed as a backlog entry carrying these numbers |

---

## Quality Strategy

`run-all.sh:build_child_list` globs `tests/hooks/test-*.sh`, so registration is automatic.
`set -uo pipefail` — **never `-e`**, a FAIL must count rather than abort the file. `PASS`/`FAIL`
counters, `RESULT: PASS=n FAIL=n`, `[ "$FAIL" -eq 0 ] || exit 1`. **Mandatory**
`command_not_found_handle` converting a misspelled helper into a FAIL — without it a whole file of
typos summarises `FAIL=0`, which has happened here. `FIX="$(cd "$(mktemp -d)" && pwd -P)"`: the
`pwd -P` is load-bearing because macOS `$TMPDIR` resolves `/var` → `/private/var` and the helper
resolves realpaths. bash 3.2 — no `mapfile`, no associative arrays.

**`rt` is deliberately NOT used for these suites.** `docs/runbook/testing.md` §5 records
`rt bash tests/run-all.sh` producing 13 failures in 108 s that all pass standalone, because the hook
suites assert on real git state, `~/.claude`, `~/.zuvo` and gitignored `memory/reviews/`. Python
lint/mypy still goes through `rt --light`.

**Four false-green vectors, all live here.** (1) `run_one()` treats exit 0 + a first line matching
`^SKIP:` as SKIP and SKIPs never fail the run — these suites have no optional tool, so they must
contain no `SKIP:` path at all (A8: *"A missing helper is a FAILURE, not a SKIP"*).
(2) `tests/hooks/test-python-lint.sh` reads `git ls-files`, so an **untracked** `.py` is invisible to
ruff and the hard-zero mypy gate — every new `.py` is `git add`ed in the commit that creates it.
(3) Vacuous greps: A26's history is a `grep -qi "by hand"` that passed against unrelated prose, so
every assertion on `backlog-protocol.md` text carries a negative control showing old and new matchers
disagree on the text that made the old one vacuous. (4) Conservation checks that only look for loss —
`cmd_archive`'s own is `if ln not in new_archive`, presence not multiplicity — so every new
conservation assertion counts **occurrences**, and additionally asserts **attribution** (which entry
each line was moved under), because the boundary trap above passes an occurrence check.

**Exit codes in this family:** `0` OK · `1` verify violation · `2` `append-runlog` namespace violation
· `10` OPEN · `11` ARCHIVED · `12` OVERDUE (non-blocking). Every Verify command gates on `$?`, never
on `echo rc=$?` (which always exits 0) and never on a bare `grep` of a status line (which matches
`FAIL` as happily as `OK`).

**CQ gates at risk.** CQ8: three documented fail-opens sit in this code — `is_ignored()` returns
`None` outside a repo, `cmd_verify` catches `SystemExit` from `Lock` and falls back to an *unlocked*
read, `read()` swallows `FileNotFoundError` → `""`. Nothing in this PR may widen them, and Task 5's
extraction must preserve each one's exact semantics. CQ21: the `lines[idx].rstrip("\r\n") != e.raw`
identity check stays — A31 records that `rstrip("\n")` made every entry fail forever with a message
blaming concurrency. CQ19: `Entry` positional old-arity construction is asserted.

---

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) | Notes |
|---|---|---|---|---|
| AC1 | `lookup` resolves an entry defined as a `## B-id` heading | requirement | Task 2 | regression test for the reproduced proof |
| AC2 | The dialect is recognised at any heading level, id-anchored | requirement | Task 1 | ~40% of the population is `###` |
| AC3 | All 306 existing `fingerprint` values byte-identical; `test-backlog-archive-dedup.sh` passes **unedited** | constraint | Task 1, Task 2 | any edited assertion is the finding |
| AC4 | No write path sees a heading: 7 sites explicitly pinned, guard test present, heading archive env-gated off | constraint | Task 2 | prevents 170-216 fleet auto-archives |
| AC4′ | The pin guard is revised in the same commit that adds the eighth, env-gated site | constraint | Task 4 | a guard a later task invalidates is worse than none |
| AC5 | `entry_block` on a heading covers its children and nested lower headings, stops at the next heading of level ≤ own **or** the next flush-left checkbox sibling | requirement | Task 3 | fixture generated **from the real file** |
| AC6a | Attribution is asserted read-only over `entry_block` spans | constraint | Task 3 | archiving a heading does not exist until Task 4 |
| AC6b | Archive conservation counts occurrences **and** asserts attribution | constraint | Task 4 | occurrence-only passes the boundary trap |
| AC7 | Minting into a heading works and preserves identity; a `B-G…` prefix FAILS | requirement | Task 4 | D2 |
| AC8 | A resolved heading archives with its block whole and its open siblings untouched; a heading with open **children** is HELD | requirement | Task 4 | |
| AC9 | `zuvo_backlog_io.py` importable; both oversized functions ≤50 lines; residual module size reported, not claimed away | constraint | Task 5 | |
| SMOKE1 | The dedup loop is closed for all 81 heading ids, read-only | deliverable | Task 6 | |
| SMOKE2 | The boundary rule holds at fleet scale on a generated fixture | deliverable | Task 6 | live-file scan is an observation, never a gate |
| G1 | No new skill; `validate-skills.sh` fully green | constraint | Task 2, Task 5 | |

---

## Task Breakdown

### Task 1: Heading entries in the parser
**Files:** `scripts/zuvo-home/zuvo_backlog_parse.py`, `tests/hooks/test-backlog-headings.sh` (new)
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** none
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED: new suite. Baseline golden first — record 306/43 and all 306 `fingerprint` values. Then:
  id-shaped headings at `#`…`######` are entries and carry `kind=heading`; `## [obs] …`,
  `## (closed) B-x`, `# Tech Debt Backlog`, `## Archived from backlog.md on …`, `  ## B-IND` (indented —
  `iter_entries` uses `line.lstrip()`, so it reads as a heading today) and `  > ## B-Q` are **not**
  entries; `Entry` constructed **positionally at the old arity** still works; `kinds=` plus
  `checkbox_only=` raises `ValueError`; `DEFAULT_KINDS` equals today's tolerant set; a heading entry's
  `section` is its **parent** heading, never itself; `has_resolution_marker` scores 24/81 and
  `is_resolved_inline` 0/81 on the real file; every one of the 306 recorded fingerprints is unchanged.
- [ ] GREEN: add `KIND_CHECKBOX/BULLET/TABLE/HEADING`, `DEFAULT_KINDS`, the `kinds=` parameter, and the
  heading branch — inserted inside the existing `if line.lstrip().startswith("#")` block at
  `:294-304`, **after** the `section`/`section_done` update and **before** the `continue`, so children's
  `section` semantics are untouched. Heading body is `HEADING_RE.match(...).group(1).strip()`; it never
  calls `body_of()`/`CHECKBOX_RE` (relying on a no-op is how the next change breaks it). Status via
  `has_resolution_marker`. `Entry` gains `kind`, `end_lineno`, `parent_key` appended last with defaults.
- [ ] Verify: `bash tests/hooks/test-backlog-headings.sh && bash tests/hooks/test-backlog-archive-dedup.sh && git diff --quiet tests/hooks/test-backlog-archive-dedup.sh`
  Expected: both suites `RESULT: … FAIL=0`; the `git diff --quiet` exits 0, proving the 32-group suite was not edited.
- [ ] Acceptance Proof:
  - AC2: Surface backend-logic · Proof `python3 -c` probe asserting the id-shaped-heading count is 81, that a synthetic `###### B-deep` parses with `kind=heading`, and that all six negative shapes are non-entries · Expected `81`, `kind=heading`, six non-entries · section `## <ac-id>` of `zuvo/proofs/task-1-report.md`
  - AC3: Surface backend-logic · Proof diff the 306 recorded fingerprints against a fresh `parse_backlog`; run the 32-group suite and `git diff --quiet` on it · Expected zero fingerprint differences, `FAIL=0`, `git diff --quiet` rc=0 · section `## <ac-id>` of `zuvo/proofs/task-1-report.md`
- [ ] Commit: `feat(backlog): parse '## B-id' heading blocks as entries in their own right`

### Task 2: Read paths on, write paths pinned shut, protocol amended
**Files:** `scripts/zuvo-home/backlog-archive.py`, `shared/includes/backlog-protocol.md`, `tests/hooks/test-backlog-headings.sh`
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** Task 1
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED: the **mechanical pin guard**, both halves — (i) the source of `backlog-archive.py` contains
  exactly 7 `iter_entries` calls pinned `kinds=(KIND_CHECKBOX,)` and zero unpinned ones outside
  `find()`/`cmd_index`; (ii) behaviourally `classify()` returns no `KIND_HEADING` entry, `cmd_status`'s
  open count is unchanged on a heading fixture, and `cmd_archive --dry-run` moves 0 heading entries
  **with `ZUVO_BACKLOG_HEADING_ARCHIVE` unset**. Both, because the source assertion catches a future
  call site the behavioural one would miss. Then: `lookup B-driftguard-bounded-age` resolves (AC1);
  `cmd_index` includes heading entries; the `backlog-protocol.md` amendment assertions, each with a
  negative control per the A26 lesson.
- [ ] GREEN: switch `find()` (`:180`) and `cmd_index` (`:214`) to include headings — these two are what
  fix the user-facing bug and neither writes. Pin `:236`, `:241`, `:302`, `:331`, `:410`, `:545`, `:546`
  explicitly to `kinds=(KIND_CHECKBOX,)` — spelled out, not defaulted, so the opt-in is a reviewable
  one-line diff. Amend `backlog-protocol.md`: document the heading dialect and its boundary rule.
- [ ] Verify: `python3 scripts/zuvo-home/backlog-archive.py lookup --repo . B-driftguard-bounded-age; test $? -eq 10 && bash tests/hooks/test-backlog-headings.sh && bash tests/hooks/test-backlog-archive-dedup.sh && bash scripts/validate-skills.sh`
  Expected: `lookup` exits **10** (OPEN) printing `OPEN id:b-driftguard-bounded-age`, never `ABSENT`; both suites `FAIL=0`; `validate-skills.sh` fully green including `count-consistency: OK (58)`.
- [ ] Acceptance Proof:
  - AC1: Surface backend-logic · Proof `python3 scripts/zuvo-home/backlog-archive.py lookup --repo . B-driftguard-bounded-age; test $? -eq 10` · Expected rc=10 and `OPEN id:…`; the command's own exit status is the gate · section `## <ac-id>` of `zuvo/proofs/task-2-report.md`
  - AC4: Surface backend-logic · Proof the pin guard's two halves plus `cmd_archive --dry-run` on a heading fixture with the env var unset · Expected exactly 7 pinned calls, 0 unpinned outside the two readers, 0 heading entries moved · section `## <ac-id>` of `zuvo/proofs/task-2-report.md`
  - G1: Surface config · Proof `bash scripts/validate-skills.sh | grep -q 'count-consistency: OK (58)'` · Expected rc=0 from the `grep -q` on the exact success string · section `## <ac-id>` of `zuvo/proofs/task-2-report.md`
- [ ] Commit: `fix(backlog): lookup and index find heading entries; write paths stay checkbox-only`

### Task 3: Level-and-sibling-aware heading-block boundaries (D1)
**Files:** `scripts/zuvo-home/backlog-archive.py`, `scripts/zuvo-home/zuvo_backlog_block.py` (new — added during execution, authorised by the orchestrator: the level-and-sibling rule pushed the archiver to 803 raw lines, one over the 800 automatic CQ11 FAIL at `rules/file-limits.md:258`, so the four boundary functions were extracted whole. Orthogonal to Task 5's `zuvo_backlog_io.py`, so the DAG is unaffected; SCOPE-FREEZE permits a blocker's minimal unblocking change), `tests/hooks/test-backlog-headings.sh`
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** Task 2
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED: **boundary-rule spike first, before touching `entry_block`.** Run the proposed rule as a
  standalone read-only script over this repo's backlog *and* over the largest heading-dialect file in
  the fleet, and print the resulting spans **plus, for every block that terminates on a
  flush-left checkbox, whether that terminator carries a `B-` id (a sibling) or does not (a probable
  child)** — the 89/6 split above is what that classification is for. A rule that is wrong is then
  cheap to reshape; the
  revision-1 plan asserted an expected boundary of "14 lines" that matched neither the old behaviour
  (1) nor the new rule (19) precisely because this measurement was skipped.
  Then the suite proper. The load-bearing fixture is **generated by script from the real file** — extract lines
  starting at `memory/backlog.md:220` (the heading; 219 is the previous entry's bullet) into the temp
  repo. A hand-written fixture with indented children passes while the real shape fails, which is how
  this survived 32 assertion groups. Assert: the block **ends at line 238**; lines 240-243 (four OPEN
  `- [ ]` siblings) fall **outside** the block's span and are attributed to themselves, not to the
  heading (nothing moves at this task, so there is no destination to check — the archive-shaped form of
  this assertion lives in Task 4's AC6b); the block covers its flush-left
  `- **Closed:** …` continuation bullets and a nested `### B-…-SUB`; a fenced code block containing a
  flush-left `#` does not terminate it; trailing blank lines are trimmed; the following `## B-NEXT`
  block is byte-unchanged. Record the current distribution and assert the 6 one-line truncations are
  gone. Conservation here is **span attribution**: every line of the fixture maps to exactly one
  entry at its own nesting level, and no line is attributed to an entry it does not belong to.
  Occurrence-only conservation passes the boundary trap, which is why attribution is the assertion.
- [ ] GREEN: rewrite `entry_block` (`:349-379`) to terminate on the next heading of level ≤ the start
  entry's, **or** the next flush-left line that is itself a checkbox entry, then trim trailing blanks;
  never terminate inside a fenced block; for a bullet-shaped start entry keep today's behaviour exactly.
  Populate `end_lineno` for both dialects from this one function so every later consumer measures the
  same span.
- [ ] Verify: `bash tests/hooks/test-backlog-headings.sh && bash tests/hooks/test-backlog-archive-dedup.sh`
  Expected: both `FAIL=0`; the real-file probe reports the block at line 220 spanning **19 lines (220-238)**, down from the current 1, and no id-shaped heading with continuation content measuring 1 line.
- [ ] Acceptance Proof:
  - AC5: Surface backend-logic · Proof run `entry_block` over all 81 id-shaped headings, print the distribution, and print the boundary for line 220 · Expected 19 lines for 220; no entry of length 1 that has continuation content · section `## <ac-id>` of `zuvo/proofs/task-3-report.md`
  - AC6a: Surface backend-logic · **Read-only** attribution proof — for the generated fixture, map every line to the entry whose `entry_block` span contains it, without invoking `cmd_archive` (heading archiving does not exist until Task 4, so an archive proof here could not pass) · Expected every line attributed to exactly one entry at its own nesting level; the four sibling checkboxes attributed to themselves, never to the heading · section `## <ac-id>` of `zuvo/proofs/task-3-report.md`
- [ ] Commit: `fix(backlog): a heading entry ends at the next sibling, not at the next bullet`

### Task 4: Heading-aware mint and the gated archive remedy (D2)
**Files:** `scripts/zuvo-home/backlog-archive.py`, `tests/hooks/test-backlog-headings.sh`
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** Task 3
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED: **first, revise the pin guard Task 2 locked.** Task 2 asserts "exactly 7 pinned calls, zero
  unpinned outside `find()`/`cmd_index`"; this task adds an eighth site, so the guard is updated in the
  same commit to assert exactly 7 unconditionally-pinned calls **plus exactly one env-gated site**, and
  to assert that with `ZUVO_BACKLOG_HEADING_ARCHIVE` unset the behaviour is byte-identical to AC4's.
  A guard that a later task quietly invalidates is worse than no guard.
  Then: minting into `## B-x` inserts `B-A<YYYYMMDD>-<6hex> ` immediately after the `#`s and
  whitespace, matching `MINTED_ID_RE = ^B-A\d{8}-[0-9a-f]{6}\s+` (`:260`); `keys_for(after) ⊇
  {entry_key(before)}`; a `B-G…` or any other prefix **FAILS** (it silently breaks the `keys_for`
  bridge and no existing test catches it); the checkbox mint path is byte-unchanged — the negative
  control for D2's silent no-op. With `ZUVO_BACKLOG_HEADING_ARCHIVE=1`: a heading marked resolved with
  no open children archives, its block whole, siblings untouched; a heading with 12 children of which
  3 are open is **HELD** with `child_open == 3` (A7's live-sub-item rule one level up — it does not
  transfer today because `classify()` tests `"[ ]" in e.body` and a heading's body holds no child
  text). With the env var unset, all of the above archive **nothing**.
- [ ] GREEN: replace the checkbox-anchored mint at `:481-484` with a dialect-aware anchor (checkbox
  prefix, or heading marker + whitespace), keeping the explicit-slicing form that avoids the ruff B023
  closure. Add `KIND_HEADING` to the archive write path's `kinds=` **only when
  `ZUVO_BACKLOG_HEADING_ARCHIVE=1`**; default remains checkbox-only. Extend the hold rule to
  `child_open > 0`, counting only *indented* checkbox children.
- [ ] Verify: `bash tests/hooks/test-backlog-headings.sh && bash tests/hooks/test-backlog-archive-dedup.sh && bash tests/run-all.sh`
  Expected: all `FAIL=0`; `run-all.sh` shows no new failures against the pre-task baseline.
- [ ] Acceptance Proof:
  - AC7: Surface backend-logic · Proof mint into a heading in a temp repo; print the before/after line and the `keys_for`/`entry_key` sets; run the `B-G…` negative · Expected id matches `MINTED_ID_RE` at body position 0, the pre-mint content key still in `keys_for`, the `B-G…` case FAILS · section `## <ac-id>` of `zuvo/proofs/task-4-report.md`
  - AC8: Surface backend-logic · Proof `cmd_archive` on a fixture holding one resolved heading with no children, one resolved heading with 3 open children, one resolved checkbox, and four open sibling checkboxes — run once with the env var set and once unset · Expected set: heading 1 and the checkbox move whole, heading 2 HELD, four siblings untouched; unset: nothing moves · section `## <ac-id>` of `zuvo/proofs/task-4-report.md`
  - AC6b: Surface backend-logic · Proof the archive half of AC6 that Task 3 could not run — archive the generated fixture with the env var set, then count occurrences of every source line across source+destination **and** assert each moved line's attributed entry id · Expected every line exactly once, every line attributed to the entry it belongs to, the four siblings still open · section `## <ac-id>` of `zuvo/proofs/task-4-report.md`
  - AC4′: Surface backend-logic · Proof the revised pin guard · Expected 7 unconditionally-pinned calls plus exactly one env-gated site, and default-off behaviour byte-identical to Task 2's AC4 · section `## <ac-id>` of `zuvo/proofs/task-4-report.md`
- [ ] Commit: `feat(backlog): archive a resolved heading entry behind an explicit env gate`

### Task 5: Importable io layer and the two oversized functions
**Files:** `scripts/zuvo-home/zuvo_backlog_io.py` (new), `scripts/zuvo-home/backlog-archive.py`, `tests/hooks/test-backlog-headings.sh`

> **Amendment (2026-09-28, revision 5 — written before Task 5 was dispatched).** This task's spec was
> drafted when `zuvo_backlog_parse.py` was the family's only derived sibling. Tasks 3 and 4 added
> **three**: `zuvo_backlog_block.py` (206 raw), `zuvo_backlog_heading.py` (180) and
> `zuvo_backlog_mint.py` (81). `zuvo_backlog_io.py` is therefore the *fourth* sibling, not the second,
> and three consequences follow that the original text does not carry:
> 1. The suite's **pin guard** already walks the family; it must be extended to the new module in the
>    same commit, or it silently stops covering the file it is there to cover.
> 2. The numbers below were measured at drafting time and have moved. Live at dispatch:
>    `backlog-archive.py` **763 raw / 401 `ast.stmt`**, `cmd_archive` **145 raw / 95 body**,
>    `cmd_drop_stale` **99 raw / 62 body**. Derive, never quote.
> 3. `rules/file-limits.md:252-260` gates a Python **module** on RAW lines only (400 default,
>    800 automatic CQ11 FAIL) and a **function** on BODY lines (public ≤50, private ≤30 —
>    signature, docstring, comments and blanks excluded). Both metrics must be reported; only those
>    two thresholds have force.
> 4. AC9's backlog entry is for **`backlog-archive.py`'s own** overage. It does not exist yet —
>    `B-20260927-PARSE-CQ11-470` covers `zuvo_backlog_parse.py` only.
**Surface:** backend-logic
**Complexity:** standard
**Dependencies:** Task 4
**Failure:** halt
**Execution routing:** default implementation tier

- [ ] RED: `import zuvo_backlog_io` works both from the repo checkout and from a flattened
  `~/.zuvo/`-style layout (hyphenated scripts are not importable — that is why `zuvo_backlog_parse.py`
  carries an underscore, per its docstring `:1-6`); `backlog-archive.py`'s CLI behaviour is unchanged,
  with the 32-group suite as the assertion; the three documented fail-opens keep their exact semantics
  (`is_ignored()` → `None` outside a repo, `read()` → `""` on a missing file, `cmd_verify`'s unlocked
  fallback); a measurement assertion prints `cmd_archive` and `cmd_drop_stale` lengths and fails above
  50; another prints the module's raw line count and fails only above 800, **recording the actual
  number** so the residual stays visible.
- [ ] GREEN: move `resolve` (`:53-58`), `read` (`:61-66`), `is_ignored` (`:69-76`), `Lock` (`:83-157`)
  and `atomic_write` (`:160-168`) verbatim into `zuvo_backlog_io.py`; re-import under the same
  module-level names so zero call sites change. Extract the section-building loop out of `cmd_archive`
  (137 lines) and the settle loop out of `cmd_drop_stale` (99) into private helpers ≤30 lines each.
  `git add` the new file in this commit — `test-python-lint.sh` reads `git ls-files`, so an untracked
  `.py` is invisible to ruff and the hard-zero mypy gate. Full annotations from the first commit.
- [ ] Verify: `bash tests/hooks/test-backlog-archive-dedup.sh && bash tests/hooks/test-backlog-headings.sh && rt --light bash tests/hooks/test-python-lint.sh && bash tests/run-all.sh`
  Expected: all `FAIL=0`; mypy zero errors; ruff count not above the existing ratchet.
- [ ] Acceptance Proof:
  - AC9: Surface backend-logic · Proof print measured raw lines and `ast.stmt` count for `backlog-archive.py` plus both function lengths, before and after · Expected both functions ≤50; module reduced from 648 raw and **explicitly reported as still above the 400 default**, with the residual filed as a backlog entry carrying these numbers · section `## <ac-id>` of `zuvo/proofs/task-5-report.md`
- [ ] Commit: `refactor(backlog): extract the shared io layer and split two oversized commands`

---

## Whole-feature Smoke Proofs

- **SMOKE1 — the dedup loop is actually closed on this repo, read-only**
  - Preconditions: clean tree; Tasks 1-5 committed; `install.sh` **not** run (decision 7);
    `ZUVO_BACKLOG_HEADING_ARCHIVE` unset.
  - Proof: `tests/hooks/test-backlog-smoke.sh` (authored by Task 6) runs
    `python3 scripts/zuvo-home/backlog-archive.py lookup` over **all 81** id-shaped heading ids and
    over 10 sampled checkbox ids, then `status`, then `verify`.
  - Expected: zero `ABSENT` results for the 81 heading ids; every one returns rc=10 or rc=11; `verify`
    prints `OK disjoint`; `status`'s open count is **unchanged** from the pre-change baseline (the
    write path is still checkbox-only, so nothing was archived); `memory/backlog.md` sha256 unchanged.
  - Artifact: `zuvo/proofs/smoke-heading-lookup.txt`
- **SMOKE2 — the boundary holds at fleet scale**
  - Preconditions: a **generated** fixture at fleet scale, built deterministically from a seed by the
    runner itself — ~400 id-shaped headings mixing `##` and `###`, heading blocks with indented
    continuation, heading blocks followed by flush-left checkbox siblings, nested `###` children under
    `##` parents, fenced code blocks containing a flush-left `#`, and trailing-blank runs. Generated
    rather than vendored for two reasons: the real heaviest file
    (`~/DEV/tgm-survey-platform/memory/backlog.md` — quoted here as ~397 `## B-` headings / ~815 KB at
    planning time; **re-measured 2026-09-28: 499 id-shaped headings, 1,057,828 bytes, 4604 lines**, so
    the quoted figures were already 25%/30% low, which is the point — mtime moves daily) cannot
    reproduce a fixed count, and copying another project's backlog into this repo would
    import that project's content.
  - Proof: run `entry_block` over every id-shaped heading in the fixture and assert (i) no block
    contains a flush-left **checkbox** line belonging to a different entry, and (ii) **sibling** blocks
    never overlap — parent/child nesting *is* expected and legitimate, since AC5 requires a `##` block
    to contain its nested `### B-…-SUB`, so a flat no-overlap assertion would contradict AC5.
  - Expected: zero sibling-block overlaps; zero foreign siblings inside any block; every line of the
    fixture attributed to exactly one entry *at each nesting level*.
  - Additionally, and reported separately without affecting the verdict: the same scan over the live
    fleet file when it is present, printing its sha256 and any anomaly found. This is an observation,
    never a gate — it must not be able to turn red from someone else's edit, and it must not be able
    to hide a failure of the generated-fixture gate either.
  - **Measured 2026-09-28, and it settles the generated-vs-vendored question for good:** the real fleet
    file contains **zero** parent/child nesting (`nested_pairs=0`). Vendoring it would therefore have
    left AC5 — a `##` block containing its nested `### B-…-SUB` — completely untested at scale. The
    generated fixture carries 80 such pairs and asserts that count is ≥ 40, because zero crossings over
    a fixture with no nesting proves nothing.
  - Artifact: `zuvo/proofs/smoke-fleet-scale-boundary.txt`

### Task 6: The smoke runner
**Files:** `tests/hooks/test-backlog-smoke.sh` (new)
**Surface:** integration

> **Amendment (2026-09-28, revision 6 — written before Task 6 was dispatched).** Three details in this
> task and in the two smoke proofs above went stale while Tasks 1-5 ran, and each would send the
> implementer at the wrong target:
> 1. **"all 81 id-shaped heading ids" is now 91.** The count has moved four times during this plan
>    (81 → 82 → 83 → 84 → 91), largely because the plan's own tasks filed nine findings as `## B-`
>    heading entries. SMOKE1 must DERIVE the count from the file and pin it in its own output; it may
>    not assert a literal. Same for the sha256 — the baseline is whatever HEAD's file hashes to at run
>    time, and the assertion is that the run does not CHANGE it.
> 2. **"fails against `HEAD~5` (pre-Task-1)" is wrong.** There are now 10 commits on the branch, so
>    `HEAD~5` sits mid-plan. The pre-Task-1 reference is the branch base **`e565df29`** and nothing
>    else; use the SHA, not an offset that moves with every commit.
> 3. **"carries the mandatory `command_not_found_handle`"** — the naive form of that handler has NEVER
>    incremented `FAIL` in any suite on any bash (the assignment is discarded in the subshell; filed as
>    `B-20260927-CNFH-NEVER-COUNTED`). Use the marker-file pattern the headings suite already uses, or
>    the typo protection is decoration.
>
> The two smoke artifacts stay two files: `acceptance-proof-protocol.md` hard rule 7 is about one
> report per TASK for per-AC evidence, and these are whole-feature proofs the plan names separately.
**Complexity:** standard
**Dependencies:** Task 5
**Failure:** halt
**Execution routing:** default implementation tier

- [x] RED: the runner itself is the test; its RED is that it fails against the branch base
  **`e565df29`** (pre-Task-1) and passes at `HEAD`. **Corrected at the source, 2026-09-28** — the
  revision-6 amendment above replaced `HEAD~5` in prose and left it standing here, two paragraphs
  down, which is the exact trap that amendment was written to close. Demonstrated three ways: the
  base tree with this suite copied in exits 1 (`PASS=7 FAIL=1`, missing `zuvo_backlog_block.py`);
  `(S1h)` runs the base's own CLI on the same canonical file and gets `ABSENT rc=0` where HEAD gets
  `OPEN rc=10`; and `(S1g)` reproduces the pre-Task-1 read dialect from the CURRENT parser, so no
  coverage depends on that object surviving in a clone — it is absent from the farm's delta mirror. It contains no `SKIP:` path and carries the mandatory `command_not_found_handle`.
- [ ] GREEN: author both smoke proofs above as one suite, auto-registered by the
  `tests/hooks/test-*.sh` glob.
- [ ] Verify: `bash tests/hooks/test-backlog-smoke.sh && bash tests/run-all.sh`
  Expected: `FAIL=0` in both; the runner prints the pinned sha256 of the fleet fixture it used.
- [ ] Acceptance Proof:
  - SMOKE1: Surface integration · Proof as above · Expected as above · Artifact `zuvo/proofs/smoke-heading-lookup.txt`
  - SMOKE2: Surface integration · Proof as above · Expected as above · Artifact `zuvo/proofs/smoke-fleet-scale-boundary.txt`
- [ ] Commit: `test(backlog): end-to-end smoke for heading-entry lookup and block boundaries`

---

## Review Trail

- Phase 1: full fan-out (Architect → Tech Lead → QA Engineer, sequential, Opus, read-only). Each stage
  corrected its predecessor: the Architect corrected the brief's `checkbox_only` premise; the Tech Lead
  corrected the heading status predicate, the fleet index path and the census; QA corrected the CQ11
  arithmetic, the mint anchor (D2) and `entry_block` (D1). The orchestrator re-verified D1, D2 and the
  `lookup ABSENT` proof by execution rather than accepting them on report.
- Plan reviewer, revision 1 → **ISSUES FOUND** (10, one CRITICAL). It re-ran every probe and all
  reproduced. Revision 2 changes, each traceable to a finding: the heading-block terminator now stops
  at a flush-left checkbox sibling as well as a heading (CRITICAL — a level-only rule swept four OPEN
  entries at lines 240-243 into the archive while a line-level conservation check stayed green; the
  corrected boundary, 220-238, was then executed); the heading archive path is env-gated because
  separate *commits* do not protect a machine-global `~/.zuvo/` install (decision 6); every proof now
  gates on `$?` instead of `echo rc=$?` or a bare `grep`; proofs invoke the repo copy, not `~/.zuvo`;
  the fixture line is 220, not 219; the expected boundary is 19 lines, not the un-executed 14; SMOKE2
  pins a sha256 instead of a count that cannot reproduce against a live file; conservation now asserts
  **attribution** as well as occurrence; a smoke-runner task was added (rule 8a); the original Task 1
  was split; and the whole plan was split into two sequential PRs (rule 17), this being PR 1.
- Cross-model validation, revision 2 → 5 providers (cursor-agent, codex-5.3, byteplus-3, claude, muse),
  0 timeouts, input NOT truncated (30,916 of 50,000 chars, so the whole document was reviewed).
  Six CRITICAL raised; three were real defects and are fixed in revision 3:
  (i) **converging finding from two providers** — Task 3's AC6 proof invoked `cmd_archive` on a heading
  fixture, but heading archiving does not exist until Task 4, so the proof could not pass. Split into
  read-only AC6a (Task 3) and archive AC6b (Task 4);
  (ii) Task 4 adds an eighth, env-gated `iter_entries` site, which would have made Task 2's
  "exactly 7 pinned, zero unpinned" guard fail — Task 4 RED now revises the guard in the same commit
  (AC4′), because a guard a later task quietly invalidates is worse than no guard;
  (iii) SMOKE2 demanded that blocks partition the file without overlap while AC5 requires a `##` block
  to contain its nested `### B-…-SUB` — a flat contradiction. Overlap is now rejected only between
  **sibling** blocks.
  Two further findings accepted as improvements rather than defects: SMOKE2 now gates on a generated
  fleet-scale fixture instead of a live file outside the repo (it cannot reproduce a fixed count, and
  vendoring it would import another project's content), with the live scan kept as a non-gating
  observation; and Task 3 RED opens with a read-only boundary-rule spike over real data, which is the
  measurement whose absence produced revision 1's wrong expected boundary.
  Remaining WARNINGs are dispositioned in-place above; none changed task ordering or coverage.
- **Decision taken 2026-09-27, by the agent, on the user's explicit instruction** ("nie wiem podejmij
  sam decyzje"): **PR 1 lands first**, alone, and is observed before PR 2 starts — it is a
  self-contained bug fix whose blast radius is 20 repositories, and it has no reason to wait behind
  seven feature tasks. Revision 4's own fixes have not been through a further whole-plan review round
  (the reviewer loop's 3-iteration cap is reached); that residual is accepted deliberately, because
  `zuvo:execute`'s per-task review gates catch it closer to the code than another full round would.
- Status gate: **Approved** 2026-09-27T13:52:27Z — active plan.
