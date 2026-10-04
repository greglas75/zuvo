# Implementation Plan (2 of 2): `zuvo:backlog verify / groom / doc`

**Spec:** inline — no spec
**spec_id:** none
**planning_mode:** inline
**source_of_truth:** inline brief (user decisions of 2026-09-25/27, recorded verbatim below)
**plan_revision:** 7
**status:** Approved
**Created:** 2026-09-27
**Tasks:** 7
**Sequence:** PR 2 of 2. **Hard precondition:** `2026-09-27-backlog-heading-entries-plan.md` (PR 1)
landed on `main` and observed in the wild. PR 1 delivers the entry model, the boundary rule, the mint
anchor and the env-gated archive remedy that every task here consumes. Split per rule 17.
**Estimated complexity:** 4 complex / 3 standard.
**Degraded inputs:** CodeSift index 12 files stale, `index_folder` timed out; every measurement is a
direct read or an executed probe.

---

## Amendment (2026-09-29, revision 5 — written after Task 1, before Task 2 was dispatched)

Task 1 executed and found four things in this plan that would have misled the tasks after it. Fixed
here rather than in each task's head, because three of them are cited more than once.

1. **`backlog-protocol.md:445-450` does not exist, and it is the wrong file.** That include is **384
   lines** long (363 before Task 1). The refusal the plan meant is the archiver's:
   `scripts/zuvo-home/backlog-archive.py:416-426` (`_refuse_tracked_archive`, called from `:560`),
   whose `.gitignore` recipe names exactly the three paths the plan described. The visibility prose in
   the include is at `:240-242`. Other citations that have also drifted: `src_mode` `:509` → **`:501`**;
   banned dated snapshots `:164-168` → **`:235-239`**; the ordinal-id rule `:205-207` → **`:297`**.
   **Derive every line number before using it.**

2. **`DUPLICATE-OF <key>` CANNOT be the `verdict` field, and Task 2 must not emit it that way.**
   Decision 1 closes the vocabulary at five tokens and the ledger validates against that closed set, so
   a field carrying a variable payload is unvalidatable by construction. Task 2's line about
   `DUPLICATE-OF <key>` is a *report* format, not the record: `verdict` is exactly `DUPLICATE-OF`, and
   the other entry's `id:`/`fp:` key rides in `evidence`, enforced mechanically and documented in
   `shared/includes/backlog-grooming.md`. **Task 2's deterministic duplicate class emits that shape.**

3. **AC1 named eight properties for seven rows.** Resolved: rows 2 and 3 carry the stale-sha and
   orphan-key properties, row 6 is the second writer. 7 rows, 9 shapes, censused from the bytes.

4. **"Fail closed on `is_ignored() is None`" does not apply to PLACEMENT.** The archiver deliberately
   fails *open* there, because the canonical backlog lives outside any repository, and the ledger now
   matches it. The `is None` refusal is still owed by Task 2's `plan`/`apply` **write** path — that is
   where a wrong answer costs something.

**Residual carried into Task 6** (wiring), because it is outside Task 1's declared file set and sits in
a file whose behaviour is byte-pinned by `test-backlog-archive-dedup.sh`: `_refuse_tracked_archive`'s
recipe still lists three paths, so a user who follows *that* message still ends up with a tracked
ledger. One line, in a file Task 1 does not own — not smuggled in here.

---

## Amendment (2026-09-29, revisions 6-7 — Task 2's mint premise is unreachable, the deadlock it feared does not exist, and revision 6's stated cost was wrong)

Task 2 executed the pre-pass and measured that **the plan's central mint premise cannot be satisfied**.
Both halves were re-measured independently before this amendment was written.

**What is impossible.** The mint set — entries `iter_entries` yields with no `ident` — is **263 entries,
and all 263 are the BULLET dialect. `zuvo_backlog_mint.mint_into` refuses every one of them: 0 of 263
are mintable.** That refusal is deliberate PR 1 behaviour ("THE REFUSAL IS THE POINT" —
`zuvo_backlog_mint.py:61`, because returning the line unchanged was a measured data-loss path) and it is
pinned verbatim by `tests/hooks/test-backlog-headings.sh` H20/AC7. So "mint an id for every entry
`iter_entries` yields without one" is not a task that can be completed; it is a task that must be
redefined. Related: some of the 263 are not even id-less — `- B-4 [TRIAGE …]` shows an id but reports
`ident == ""`, because `DEF_ID_RE` requires a checkbox while `BODY_ID_RE` does not.

**The stated reason for minting first is also false.** Task 2 argued that minting must precede verify
because "a content-keyed entry cannot carry a stable verdict until it has an id", and that deferring it
would deadlock `groom`. Measured against what Task 1 actually shipped, it cannot deadlock:
`keys_for` gives such an entry a first-class `fp:<12hex>` key, `zuvo_backlog_ledger._KEY_RE` accepts
`fp:` keys as first-class, and `plan_reuse` keys staleness on **(key, text_sha)** — on content, never on
an id. A bullet with no ident can therefore carry, reuse and re-verify a verdict today.

**THE DECISION.** Verification proceeds on `fp:` keys for the 263. The mint is **not** attempted on the
bullet dialect and no id is written into a tracked file to satisfy a premise that measurement refuted.
The user's binding decision 3 is untouched: every entry is still verified first, none is sampled, and
nothing is closed, ranked, grouped or rendered without a verdict backed by an evidence line — the key's
*shape* changes, its coverage does not.

**The real cost — CORRECTED at revision 7, because revision 6 overstated it and was wrong about the one
case it named.** Revision 6 said an `fp:` key "rotates when the entry's text changes, so a verdict is
orphaned by the very normalisation `groom` performs". Measured, that is false in exactly the case that
mattered. `entry_key` hashes `normalize_signature` = **the first path token's basename plus the 8 words
that FOLLOW it**, and the docstring (`zuvo_backlog_parse.py:303-311`) says the window is anchored after
the path *precisely so the signature survives resolution*. Measured on fixtures:

| edit | key | `text_sha` | outcome |
|---|---|---|---|
| **a leading `[DONE 2026-09-29 abc1234]` marker prepended** — what normalisation does | kept | **kept** | **REUSED — the closure is free** |
| prose appended outside the 8-word window | kept | moved | RE-VERIFY, row stays reachable |
| the path changed | rotated | moved | rotate + **named orphan** |
| one of the 8 words after the path changed | rotated | moved | rotate + **named orphan** |
| the 9th word changed (outside the window) | kept | moved | RE-VERIFY |

Revision 6 was therefore wrong twice: `groom`'s resolution marker does not orphan a verdict, and it does
not even force a re-verify — the row is **reused**, at zero dispatch. `text_sha` strips resolution
markers before hashing (`zuvo_backlog_ledger.text_sha:125-133`) *precisely* so "a verdict must not be
invalidated by the very edit that proves it". And the sha is **not** redundant with the key: measured, it
moves on prose the key ignores, which is what separates re-verify from reuse. Three distinct buckets,
and all three are pinned separately.

Two consequences for the tasks after this one, narrower again than the first correction claimed:
`groom` re-verifies only what it actually rotates (path or signature-window edits) and pays **nothing**
for its own closures; and `doc`'s honest line is that a content-keyed verdict survives resolution
entirely, survives later prose at the cost of one re-verify, and is lost only when the entry's subject
changes. **Both halves must be asserted** — the broad claim overstates the
cost, and the narrow one alone would hide it.

**Routed out, not smuggled in:** teaching `mint_into` the BULLET dialect is a genuine improvement and
would make these verdicts durable. It is also a behaviour change to PR-1 code whose refusal is
deliberately pinned by a passing assertion, so it gets its own task and its own review — filed as a
backlog entry, not appended to Task 2.

**Also stale:** the task's "387" is now **330** entries (measured 2026-09-29). The 263 still holds by
coincidence. Derive both.

---

## Binding user decisions

1. **Form** — new modes in `skills/backlog/SKILL.md`'s Argument Parsing table. **Not** a 59th skill.
   Heavy logic → `shared/includes/` + helpers in `scripts/zuvo-home/`, never skill prose.
2. **Scope** — per-repo by default; opt-in `--fleet`.
3. **Autonomy** — verbatim: *"wszystkie ma najpierw zweryfikować."* Verification is mandatory over the
   **whole** set, never sampled. Nothing is **closed, ranked, grouped or rendered** until it carries a
   verdict backed by an evidence line. Deterministic classes still carry evidence; they skip only the
   LLM judgement.

Decision 3's "ranked, grouped or rendered" is why `doc` is gated too, not just `groom` — see decision 11.

## What PR 1 leaves on the table, and what this PR adds

PR 1 makes the 81 heading entries findable and the 24 resolved ones archivable. It does **not** decide
whether an entry is still *true*. That is this PR: a verdict with evidence for every entry, then
dispositions that follow from verdicts, then a working document.

Measured starting point (per-repo): 387 entries after PR 1's parser change (306 today + 81 heading
entries), of which 24 carry a resolution marker, 6 share a duplicate `entry_key`, 240 key on content
rather than an id, and 19 headings are entry-shaped with no id at all. Fleet: 1004-1227 heading entries
across 14-20 of 69-88 backlogs; `~/.zuvo/backlog-index.jsonl` is **0 bytes** while the real snapshot is
`backlog-local.jsonl` (7.3 MB, `backlog-collect.py:51`), so the fleet READ model is empty today.

---

## Technical Decisions

| # | Decision | Rationale |
|---|---|---|
| 1 | Verdict vocabulary closed at 5: `STILL-REAL` · `STALE-FIXED` · `STALE-OBSOLETE` · `DUPLICATE-OF` · `NOT-VERIFIABLE`. **Not** folded into `severity-vocabulary.md` | that file maps *impact*; this maps *existence*. An entry has both. `audit-registry-integrity.py` validates severity-vocabulary rows, so folding them in would fail there |
| 2 | Ledger = `memory/backlog-verdicts.jsonl`, beside the real backlog, inheriting its git-ignore status **and** file mode | undated and not `.md`, so structurally unable to be read as one of the banned dated snapshots at `backlog-protocol.md:164-168` — where `backlog-verified-stale-<date>.md` is *literally* listed. `$ZUVO_DIR/context/` is wrong: `zuvo/` is gitignored (`.gitignore:37`) while `memory/backlog.md` here is tracked, so a ledger there is lost on clone and 387 judgements get re-spent per machine |
| 3 | Ledger fields: `id` · `keys` (`sorted(zb.keys_for(body, ident))` at verification time) · `text_sha` (`sha1` of `zb.strip_resolution_markers(body)` as verified) · `verdict` · `evidence` · `verified_at` · `verified_by` (`deterministic:<class>` \| `agent:<lane>`) · `disposition` (`pending\|archived\|dropped\|kept\|no-remedy`, written by `groom`) | `text_sha` is the invalidation key, so there is no time-based TTL: a verdict does not expire with the clock, it expires with the text |
| 4 | Incrementality: key resolves **and** `text_sha` matches → reuse free; key resolves, sha differs → re-verify; **no** key resolves → report as a defect, never silently drop | the last case means an entry was normalized without minting, which is the bug the ledger exists to detect |
| 5 | Mint **before** any normalization, always, same locked write; exactly `MINTED_ID_RE` | 240/387 entries key on content. `strip_resolution_markers` does **not** strip severity words or category tags and `SEV_RE` matches `critical\|high\|medium\|low\|CRITICAL\|WARNING\|INFO`, so inserting `[high]` lands in the 8-word window at `normalize_signature:224-226` and rotates the key silently. Once an entry carries a descriptive id, `entry_key` prefers `id:` and stops reading the text. A `B-G…` prefix breaks the `keys_for` bridge and **no existing test catches it** (PR 1 Task 4 adds that assertion) |
| 6 | Never mint an ordinal; never order by id | `B-1`/`B-70` are positions in a numbered batch and get reused (`backlog-protocol.md:205-207`) |
| 7 | **Option B**: `groom`'s only write to `memory/backlog.md` is inserting a minted id at body position 0 for entries with no id. Ordering, grouping and backfilled metadata live in the ledger and the rendered doc | option A (full re-emission) has no oracle: the per-entry `text_sha` this PR creates **is** the entry-level conservation check that line-level ones cannot express (`cmd_archive:501-507`; A25's own comment records that both stay green through a boundary error, and PR 1's boundary trap proved it). Option A is costed below |
| 8 | Closures are delegated to `backlog-archive.py archive` / `drop-stale` — `groom` never writes `backlog-done.md` | `backlog-protocol.md:173-185` records a hand-written archive that copied the helper's heading format, counted LINES as items ("106 completed items" for three entries) and destroyed quoted open copies |
| 9 | `verify` **never** becomes a blocking gate. The existing non-blocking `status` check (exit 12) additionally prints `N of M entries carry no verdict` | `append-runlog:285-303` documents that housekeeping able to refuse a completed run gets switched off within a week. But prose is not a trigger either (A14: the archiver shipped and no repo used it for two days), so one **count** gets wired — a count cannot be wrong in a way that costs anyone a run |
| 10 | "All of them first" is enforced at the destructive action: `groom` **refuses** unless `verified == entry_count`, naming the shortfall by id, exiting with a code outside `{0,1,2,10,11,12}` | a refusal at the write, not a gate on unrelated runs |
| 11 | `doc` is gated the same way. Rendering unverified entries requires an explicit `--partial`, which stamps the coverage ratio into the document header and omits the ranking | decision 3 forbids *ranking, grouping and rendering* before verification, not just closing. Revision 1 let `doc` run "clearly labelled"; that was a silent deviation from the brief and is corrected here |
| 12 | The rendered doc carries the source `memory/backlog.md` sha256, the ledger coverage count and the generating version in its header | it lives in `$ZUVO_DIR/reports/`, which is gitignored (`.gitignore:37`) — defensible for a regenerable report, but decision 2 rejected that tree for the *ledger* on durability grounds, so the difference must be deliberate and visible. A reader must be able to tell whether the document still describes the file |
| 13 | `groom --fleet` **does not exist**; `verify --fleet` is read-only, reads `~/.zuvo/backlog-local.jsonl` (not the 0-byte `backlog-index.jsonl`) and writes `~/.zuvo/backlog-verdicts/<host>-<repo>.jsonl` | grooming needs each repo's `Lock`, realpath, ignore status and own `backlog-done.md`; across 88 checkouts that is the 2026-07-19 fork-the-backlog incident (`backlog-protocol.md:14-29`) with 88× blast radius. Fleet verdicts carry `source=index` because the snapshot truncates at `text[:400]` (`parse_backlog:354`), and a disposition **refuses** on such a row |
| 14 | Fan-out chunks by **block** bytes via PR 1's `end_lineno`, cap ~25 KB/agent, 4-8 concurrent | measured: 8 of 9 sub-agents jammed on 90-180 kB chunks. 220 KB over ~387 entries averages 0.6 KB, but one section holds 117 entries / 15.8 KB, so a count-based split produces a 40 KB agent |

No new dependencies: Python stdlib only.

---

## Quality Strategy

Harness conventions, the `rt` override and the four false-green vectors are as stated in PR 1's plan
and apply unchanged (`tests/hooks/test-*.sh` auto-glob; `set -uo pipefail` never `-e`; mandatory
`command_not_found_handle`; `pwd -P` on the temp dir; no `SKIP:` path; `git add` every new `.py` so
`test-python-lint.sh`'s `git ls-files` sees it; negative controls on every prose assertion;
conservation counts occurrences **and** attribution). Every Verify command gates on `$?`, never on
`echo rc=$?` and never on a bare `grep` of a status line.

**CQ8 is the central risk, and it now applies to `plan` as well as `apply`**, because the mint write moved into the pre-pass. Both must fail **closed** on lock failure, on a missing or
unparseable ledger, and on `is_ignored() is None` — a corrupt ledger line reading as "verified" is
catastrophic, reading as "unverified" is a refusal. `Lock`'s `sys.exit` moves into an importable
library in PR 1 Task 5; `cmd_verify` deliberately swallows it for a read-only fallback, and a **write**
path inheriting that is a data-loss hazard, so it is asserted separately. CQ6: the fleet snapshot is
7.3 MB and is streamed; the 25 KB block cap **is** the CQ6 control and carries its own assertion.
CQ14: the ledger's mode/ignore logic reuses `is_ignored` and the `src_mode` pattern at `:509`, and the
refusal message at `:445-450` is extended to name the ledger — a user following it today still ends up
with a tracked ledger beside an ignored backlog.

**What cannot be tested deterministically: the truth of the verdicts.** Five compensating controls, all
in the orchestrator, never in the agent prompt. (a) shape — verdict in the closed 5, one evidence line,
`STILL-REAL` without a `file:line` is INVALID. (b) resolvability — the cited path exists at the verified
commit and has at least that many lines. (c) keyword overlap, **scoped to the verdicts that cite a production path** (`STILL-REAL`,
`STALE-FIXED`) — re-read the cited line **±5** (a fabricated number is usually close; an exact-line
assert would reject correct evidence) and require the cited basename to equal `normalize_signature`'s
basename plus ≥2 of its 8 content words case-folded in the window. `STALE-OBSOLETE` cites a *backlog*
line by construction (fix (iii)), so its basename is `backlog.md` and can never equal the missing
path's — applying (c) to it would reject every such row. It gets its own control instead: the cited
backlog line must name the path, and the path must be absent at the verified commit. (d) **seeded known-answers** — K=4 per chunk from this repo's git history, 2 provably fixed
and 2 provably still real, chunk re-dispatched on a miss in either direction, ~8% of fan-out cost.
(e) asymmetric cross-model spot check on ~10% of `STALE-FIXED` rows only — the one verdict leading to a
destructive disposition — through `adversarial-review.sh --multi`, disagreement demoting the row to
`NOT-VERIFIABLE`.

(c)'s limit goes in the shipped include verbatim: **it catches fabrication, not misjudgement** — citing
the very line the entry names satisfies it while the verdict is still wrong. Only (d) measures
judgement, and neither may be reported as verdict validation. The idempotence test is written about the
**reuse path** (an unchanged entry is not re-dispatched; a one-character edit rotates `text_sha` and
*is* re-dispatched), never about byte-identity of LLM output, which would be flaky by construction.

---

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) | Notes |
|---|---|---|---|---|
| AC1 | Ledger validates, detects staleness via `text_sha`, reuses unchanged verdicts free, inherits ignore status + mode, survives concurrent writers, fails **closed** on a corrupt line | requirement | Task 1 | |
| AC2 | Verdict vocabulary stays out of `severity-vocabulary.md` | constraint | Task 1 | folding it in would fail registry integrity |
| AC3 | Every deterministic class emits a verdict **and** a resolvable evidence line | requirement | Task 2 | |
| AC4 | Chunker caps by **block** bytes; the 117-entry/15.8 KB section splits; a 12 KB entry never splits mid-entry | constraint | Task 2 | |
| AC5 | The census is a committed script with an explicit root set and per-heading-level counts | requirement | Task 2 | makes the 1004-vs-1227 hazard number auditable |
| AC6 | Agent contract: one record per row, no row omitted or merged; `STILL-REAL` without `file:line` INVALID; controls (a)(b)(c) run; (d) gates the chunk | requirement | Task 3 | |
| AC7 | `groom` refuses unless `verified == entry_count`, naming the shortfall by id | requirement | Task 4 | the mechanical form of decision 3 |
| AC8 | `apply` writes **nothing** to `memory/backlog.md` (the mint happened in the pre-pass); ordering never touches it; closures delegated; `no-remedy` reported rather than a false `archived` | constraint | Task 4 | stated so it can fail — an empty-diff assertion on a write that moved would be `0 == 0` |
| AC8′ | The pre-pass mint carries the full write discipline: `Lock`, `atomic_write`, the `lines[idx].rstrip("\r\n") != e.raw` identity check, byte delta equal to the sum of inserted ids, line count unchanged, mode/symlink/ignore/CRLF preserved, idempotent on a second run, and fail-closed on `is_ignored() is None` | constraint | Task 2 | the write is in `plan`, so its assertions live there |
| AC9 | `doc` refuses without full verification unless `--partial`, which stamps coverage and omits the ranking | requirement | Task 5 | decision 11 |
| AC10 | The rendered doc carries source sha256, coverage count and generating version | requirement | Task 5 | decision 12 |
| AC11 | `verify --fleet` writes zero bytes into any other checkout; every row carries `source=index`; a disposition refuses on such a row; `groom --fleet` is rejected naming the per-repo command | constraint | Task 5 | |
| AC12 | The three modes are reachable from `SKILL.md`; include integrity passes; `status` prints the non-blocking coverage count and contains no `exit` | deliverable | Task 6 | |
| G1 | No 59th skill; `validate-skills.sh` fully green including the `docs/skills.md` and `CLAUDE.md` category sums | constraint | Task 6 | |
| SMOKE1 | Dogfood `verify → groom → doc` on this repo with entry-level conservation | deliverable | Task 7 | |
| SMOKE2 | Partial-verification refusal and resume on a second pass | deliverable | Task 7 | |

---

## Task Breakdown

### Task 1: The verdict ledger
**Files:** `scripts/zuvo-home/zuvo_backlog_ledger.py` (new), `shared/includes/backlog-grooming.md` (new), `shared/includes/backlog-protocol.md`, `tests/hooks/test-backlog-grooming.sh` (new)
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** none
**Consumes from PR 1:** the shipped `zuvo_backlog_io.py` and the extended `Entry` model — a precondition of this whole plan, not a task in it.
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED: new suite. Schema — `verdict` in the closed 5, `evidence` non-empty, `STILL-REAL` requires a
  `path:line`, `text_sha` 40 hex, `keys` non-empty; a failing row is a **defect**, never a skip.
  Staleness — key + sha match → reused with zero dispatch; key matches, sha differs → re-verify; no key
  resolves → reported as a named defect. Placement — tracked source yields a tracked ledger; ignored
  source **refuses**, and the refusal message names the ledger (today `:445-450` names only
  `backlog-done.md`, the lock dir and the index); file mode inherited. Concurrency — two writers, dedup
  on `(key, text_sha)` keeping the later `verified_at`. Fail-closed — a truncated final line makes the
  ledger read **unverified**, never verified; a held lock makes a write exit non-zero having written
  nothing. Plus: the five verdict tokens are absent from `severity-vocabulary.md`.
- [ ] GREEN: `zuvo_backlog_ledger.py` with read/append/validate/reuse-decision over
  `zuvo_backlog_io`'s `Lock`, `atomic_write`, `is_ignored` and the `src_mode` pattern. Write
  `backlog-grooming.md`: the 5-verdict vocabulary, the four evidence shapes, the ledger schema, the
  agent contract, the chunking rule, and control (c)'s honest limit. Extend `backlog-protocol.md`'s
  refusal wording to name the ledger.
- [ ] Verify: `bash tests/hooks/test-backlog-grooming.sh && bash scripts/validate-skills.sh && python3 scripts/audit-registry-integrity.py && ! grep -qE 'STILL-REAL|STALE-FIXED|NOT-VERIFIABLE' shared/includes/severity-vocabulary.md`
  Expected: `FAIL=0`; include integrity and registry integrity green; the final `!`-negated grep exits 0, proving the vocabularies stayed separate.
- [ ] Acceptance Proof:
  - AC1: Surface backend-logic · Proof drive a 7-row fixture ledger (one per verdict, one stale sha, one orphan key, one truncated line) through validate + reuse + a two-writer append + a held-lock write · Expected reuse without dispatch on the matching row, re-verify on the stale one, a **named** defect on the orphan, refusal on the truncated one, non-zero exit and zero bytes on the held lock, no duplicate rows · Artifact `zuvo/proofs/task-1-ac1.txt`
  - AC2: Surface backend-logic · Proof the negated grep above · Expected rc=0 · Artifact `zuvo/proofs/task-1-ac2.txt`
- [ ] Commit: `feat(backlog): verdict ledger with content-keyed staleness and fail-closed reads`

### Task 2: Deterministic pre-pass, work queue, byte chunker, committed census
**Files:** `scripts/zuvo-home/backlog-groom.py` (new), `scripts/zuvo-home/backlog-census.py` (new), `tests/hooks/test-backlog-grooming.sh`
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** Task 1
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED: every deterministic class emits a verdict **and** an evidence line — resolution marker
  present (`STALE-FIXED`, `backlog.md:<line> "<marker clause>"`); key also in the archive
  (`STALE-FIXED`, `backlog-done.md:<line> section="…"`); key collides in the open file
  (`DUPLICATE-OF <key>`, both line numbers — a *report*, never a licence to merge); every cited path absent on disk (`STALE-OBSOLETE`, evidence
  `backlog.md:<line> "<path>" does not exist` — the citation resolves to the **backlog line that names
  the path**, with the absence stated in the text, because a citation of the missing path itself could
  not satisfy the resolvability check); `TEMPLATE_RE` match → not an entry; a heading that `iter_entries` does **not**
  yield as an entry (entry-shaped but with no id) → **reported, never minted**, exactly as PR 1
  decision 1 states.
  **The mint set is the entries `iter_entries` yields with no `ident` — measured 263 of 387 here.**
  Those are minted in the pre-pass, before verdicts, because minting is verification *preparation*, not
  a disposition: leaving it to `groom` deadlocks, since `groom` refuses until every entry is verified
  while a content-keyed entry cannot carry a stable verdict until it has an id (decision 5 already
  requires mint-before-normalize; this makes it mint-before-*verify*). Minting is none of decision 3's
  four forbidden verbs — closed, ranked, grouped, rendered — so it is the one write that legitimately
  precedes the gate. It is **count-neutral**: every minted entry was already one of the 387, so
  `entry_count` cannot move mid-run. The 19 id-less headings measured here are NOT among the 387
  (81 id-shaped + 19 id-less = 100 headings; 306 + 81 = 387), and nine of them are plain section
  headers such as `## benchmark skill` (:7) and `## 2026-04-17 zuvo:leads Task 1 (schema include)`
  (:23) — minting into those would write ids into the structure of a tracked file. Every emitted evidence line is
  asserted **resolvable** (the path exists and has that many lines), not merely non-empty. Chunker — the
  117-entry / 15.8 KB section **splits**; a single 12 KB entry is **never** split mid-entry; measurement
  is by block bytes via `end_lineno`, so a 1-line block cannot under-measure. Census — runs, prints its
  root set, reports counts per heading level.
- [ ] GREEN: `backlog-groom.py plan` mints an id for every entry `iter_entries` yields without one — under `zuvo_backlog_io`'s `Lock`, through `atomic_write`, re-reading under the lock and aborting on the `lines[idx].rstrip("\r\n") != e.raw` identity check, failing **closed** on `is_ignored() is None` — and writes the queue to
  `$ZUVO_DIR/context/backlog-verify-queue.jsonl` (`$ZUVO_DIR` per `report-output-location.md`) and the
  deterministic verdicts to the ledger. `backlog-census.py` takes `--roots` as literal directory paths
  (expanding `~` itself, since Python's `glob` does not), defaults to the documented set, and prints
  per-level counts.
- [ ] Verify: `bash tests/hooks/test-backlog-grooming.sh && python3 scripts/zuvo-home/backlog-census.py --roots "$FIXTURE_ROOTS" --min-repos 1 && python3 scripts/zuvo-home/backlog-groom.py plan --repo . --dry-run`
  Expected: `FAIL=0`; the census exits 0 over a **fixture root the suite creates** (two synthetic backlogs with known per-level counts) and prints those counts exactly — the author's `$HOME/DEV` is never the pass/fail oracle, only an optional manual smoke; it exits non-zero on an empty root set, so an unexpanded glob cannot pass silently; `plan --dry-run` emits 387 queue rows for this repo with ≥30 deterministic verdicts and writes nothing.
- [ ] Acceptance Proof:
  - AC3: Surface backend-logic · Proof `plan --dry-run` on this repo, then assert every deterministic row's `evidence` resolves to an existing path and line · Expected 100% resolvable evidence on deterministic rows · Artifact `zuvo/proofs/task-2-ac3.txt`
  - AC4: Surface backend-logic · Proof chunk the real 220 KB file; print per-chunk byte sizes and entry spans · Expected no chunk above 25 KB, no entry split across chunks, the 117-entry section split into ≥2 · Artifact `zuvo/proofs/task-2-ac4.txt`
  - AC8′: Surface backend-logic · Proof mint on a temp copy under a held lock, then without; assert byte delta equals the sum of inserted ids, line count unchanged, mode/symlink/ignore/CRLF preserved, a second run is a byte-identical no-op, and a mutated `e.raw` aborts on the identity check · Expected the held-lock run exits non-zero writing nothing; the clean run's delta matches exactly; the identity-check case aborts · Artifact `zuvo/proofs/task-2-ac8prime.txt`
  - AC5: Surface backend-logic · Proof run the census on the suite's fixture root (known counts), then on an empty temp root · Expected the fixture root reproduces its known per-level counts exactly and exits 0; the empty root exits non-zero; `$HOME/DEV` is reported separately and gates nothing · Artifact `zuvo/proofs/task-2-ac5.txt`
- [ ] Commit: `feat(backlog): deterministic verification pre-pass with a byte-capped work queue`

### Task 3: The verifier lane and the evidence controls
**Files:** `skills/backlog/agents/backlog-verifier.md` (new), `scripts/zuvo-home/backlog-groom.py`, `shared/includes/backlog-grooming.md`, `tests/hooks/test-backlog-grooming.sh`
**Surface:** integration
**Complexity:** complex
**Dependencies:** Task 2
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED: conservation against the dispatched queue — count equality, key-set equality, **and**
  `len(set(keys_returned)) == len(rows_dispatched)` so a merged pair cannot pass a count check; a
  missing row is an agent FAILURE, not an implicit verdict. Controls (a) shape, (b) resolvability,
  (c) keyword overlap with basename equality and ≥2 of 8 content words within ±5 lines, (d) seeded
  known-answers gating the chunk. Fixtures include a well-formed but **fabricated** evidence line that
  (b) or (c) must reject, an omitted row, and a merged pair.
- [ ] GREEN: write `backlog-verifier.md` copying the frontmatter shape of
  `skills/infra-audit/agents/*.md`, read-only by instruction (Read/Grep/Glob/CodeSift; no
  Edit/Write/commit). Input rows `{id, keys, text_sha, raw_text, section, cited_paths}`; output exactly
  one record per row with one verdict and one evidence line. `NOT-VERIFIABLE` is cheap and legitimate,
  so an agent has no incentive to guess `STILL-REAL` to look thorough. Implement (a)-(d) in the
  orchestrator; document (c)'s fabrication-not-misjudgement limit in the include.
- [ ] Verify: `bash tests/hooks/test-backlog-grooming.sh`
  Expected: `FAIL=0`, including the three rejection cases; nothing is appended to the ledger on any of them.
- [ ] Acceptance Proof:
  - AC6: Surface integration · Proof feed a synthetic agent response that omits one row, merges two, and carries one fabricated `file:line` · Expected three distinct rejections naming the offending ids; zero ledger rows written · Artifact `zuvo/proofs/task-3-ac6.txt`
- [ ] Commit: `feat(backlog): verifier lane with mechanical evidence checks and seeded known-answers`

### Task 4: `groom` — the refusal gate and the dispositions
**Files:** `scripts/zuvo-home/backlog-groom.py`, `tests/hooks/test-backlog-grooming.sh`
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** Task 3
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED: `groom` refuses unless `verified == entry_count`, naming the shortfall by id and exiting with
  a code outside `{0,1,2,10,11,12}`. Write discipline — the diff touches exactly N lines; each gains
  exactly the minted id at body position 0; nothing else on any line changes; byte delta equals the sum
  of inserted ids; line count unchanged; mode, symlink-ness, ignore status and CRLF preserved; a second
  run is byte-identical; `memory/backlog.md` is byte-identical apart from the mints **even when the
  ledger says to reorder**. Closures are delegated — `groom` never writes `backlog-done.md` itself, and
  a verdict with no performable action is reported `no-remedy` with a reason rather than a false
  `archived`. A **mocked pipeline** case (`plan → fixture ledger → apply`) runs end to end here — it stops at
  `apply`, because `render` does not exist until Task 5; the `apply → render` half is asserted in Task
  5's RED, where both pieces exist.
- [ ] GREEN: implement `apply`, delegating to `backlog-archive.py archive` / `drop-stale` (with
  `ZUVO_BACKLOG_HEADING_ARCHIVE=1` for heading rows, per PR 1 decision 6) and writing `disposition`
  back to the ledger. Fail closed on lock failure, unparseable ledger, and `is_ignored() is None`.
- [ ] Verify: `bash tests/hooks/test-backlog-grooming.sh && ! python3 scripts/zuvo-home/backlog-groom.py apply --repo . --dry-run`
  Expected: `FAIL=0`; the `!`-negated `apply` exits 0 overall because `apply` itself **refuses** on this repo's incomplete ledger — the refusal is the assertion, and the suite separately pins the exact exit code and the named shortfall.
- [ ] Acceptance Proof:
  - AC7: Surface backend-logic · Proof run `apply` against a ledger covering 386 of 387 entries; capture the exit code · Expected refusal naming the one missing id, exit code outside `{0,1,2,10,11,12}`, zero bytes written · Artifact `zuvo/proofs/task-4-ac7.txt`
  - AC8: Surface backend-logic · Proof `apply` on a temp copy with a complete ledger, then `git diff` on `memory/backlog.md` and a sha256 before/after · Expected `memory/backlog.md` **byte-identical** — `apply` mints nothing, because the pre-pass already did — while `backlog-done.md` changes and is written only by the helper. A non-empty diff on the open file FAILS · Artifact `zuvo/proofs/task-4-ac8.txt`
- [ ] Commit: `feat(backlog): groom applies verified dispositions and refuses on partial verification`

### Task 5: `doc` mode and `--fleet`
**Files:** `scripts/zuvo-home/backlog-groom.py`, `tests/hooks/test-backlog-grooming.sh`
**Surface:** backend-logic
**Complexity:** standard
**Dependencies:** Task 4
**Failure:** halt
**Execution routing:** default implementation tier

- [ ] RED: `render` **refuses** when `verified < entry_count` unless `--partial` is passed; with
  `--partial` the header carries the coverage ratio and the ranking section is **omitted** (decision 11).
  Golden-file compare against a fixture ledger — clustered by theme/module, ranked by the existing
  `prioritize` scoring now that severity exists, per-cluster suggested batch commands, and an explicit
  **not-verifiable** section rather than silent omission. Header carries the source `memory/backlog.md`
  sha256, the coverage count and the generating version (decision 12), and a changed source sha is
  detectable from the document alone. `--fleet`: snapshot every other checkout's `memory/` mtimes and
  assert zero writes; every row carries `source=index`; a disposition on a `source=index` row
  **refuses**; `groom --fleet` is rejected with a message naming the per-repo command.
- [ ] GREEN: implement `render` writing `$ZUVO_DIR/reports/backlog-groomed-<date>.md`, and
  `verify --fleet` reading `~/.zuvo/backlog-local.jsonl` and writing
  `~/.zuvo/backlog-verdicts/<host>-<repo>.jsonl`.
- [ ] Verify: `bash tests/hooks/test-backlog-grooming.sh && ! python3 scripts/zuvo-home/backlog-groom.py render --repo . && python3 scripts/zuvo-home/backlog-groom.py render --repo . --partial && grep -q 'source_sha256:' zuvo/reports/backlog-groomed-$(date +%F).md`
  Expected: `FAIL=0`; the un-flagged `render` refuses on this repo's incomplete ledger (so the negation exits 0); `--partial` succeeds; the `grep -q` finds the provenance header.
- [ ] Acceptance Proof:
  - AC9: Surface docs · Proof `render` without and with `--partial` on a 90%-covered ledger · Expected refusal without the flag; with it, a coverage ratio in the header and **no** ranking section · Artifact `zuvo/proofs/task-5-ac9.txt`
  - AC10: Surface docs · Proof render, mutate one byte of `memory/backlog.md`, compare the header sha against the file · Expected the mismatch is detectable from the document alone · Artifact `zuvo/proofs/task-5-ac10.txt`
  - AC11: Surface integration · Proof `verify --fleet --dry-run` with mtimes snapshotted before and after; then a disposition attempt on a `source=index` row; then `groom --fleet` · Expected zero mtime changes outside `~/.zuvo/`, every row `source=index`, the disposition refuses, `groom --fleet` is rejected naming the per-repo command · Artifact `zuvo/proofs/task-5-ac11.txt`
- [ ] Commit: `feat(backlog): render the groomed working document and read-only fleet verification`

### Task 6: Wire the three modes into the skill
**Files:** `skills/backlog/SKILL.md`, `scripts/zuvo-home/append-runlog`, `docs/skills.md`, `tests/hooks/test-backlog-grooming.sh`
**Surface:** config
**Complexity:** standard
**Dependencies:** Task 5
**Failure:** halt
**Execution routing:** default implementation tier

- [ ] RED: the three rows exist in the Argument Parsing table and each names its phase section;
  `backlog-grooming.md` is in the Phase 0 loading list at the canonical `../../shared/includes/` depth
  (`validate-skills.sh`'s `check_include_integrity`); the `status` nudge is asserted **twice** per the
  A14/A19 lesson — once by grepping `append-runlog`, once by *running* it with
  `ZUVO_HOME=<throwaway> ZUVO_BIN="$ROOT/scripts/zuvo-home"` and asserting the real `~/.zuvo/runs.log`
  was not polluted — plus A29's stderr pair (the nudge surfaces; a fully verified repo prints nothing).
  The nudge block contains **no** `exit`. `docs/skills.md`'s existing `backlog` row is **extended**, not
  duplicated, so the per-skill table stays consistent with the category sums and the `**Total**` row
  that `validate-skills.sh:561,564` and `:601` assert (these are checked in addition to `N skills`).
- [ ] GREEN: add the rows and phase sections to `SKILL.md`, the include to Phase 0, extend the existing
  `docs/skills.md` row, and extend `append-runlog`'s non-blocking `status` check to print
  `N of M entries carry no verdict — run zuvo:backlog verify`.
- [ ] Verify: `bash scripts/validate-skills.sh && python3 scripts/gen-gate-copies.py --check && bash scripts/test-gate-consistency.sh && python3 scripts/audit-registry-integrity.py && bash tests/run-all.sh && bash scripts/validate-skills.sh | grep -q 'count-consistency: OK (58)'`
  Expected: all five of the runbook's commands green; `run-all.sh` `FAIL=0`; the `grep -q` matches the exact success string, so a `FAIL (57)` cannot pass.
- [ ] Acceptance Proof:
  - AC12: Surface config · Proof grep the three rows; run include integrity; run `append-runlog` in a throwaway `ZUVO_HOME` against a repo with an incomplete ledger, then against a fully verified one · Expected three rows present, integrity OK, the nudge on stderr with the exit code unchanged from the pre-change value, and silence on the verified repo · Artifact `zuvo/proofs/task-6-ac12.txt`
  - G1: Surface config · Proof `bash scripts/validate-skills.sh | grep -q 'count-consistency: OK (58)'` plus the full `validate-skills.sh` exit status · Expected both rc=0 · Artifact `zuvo/proofs/task-6-g1.txt`
- [ ] Commit: `feat(backlog): expose verify, groom and doc modes on zuvo:backlog`

---

## Whole-feature Smoke Proofs

- **SMOKE1 — dogfood the whole pipeline on this repo's own backlog**
  - Preconditions: clean tree; PR 1 landed; `memory/backlog.md` sha256, the 387-entry inventory and
    every entry's `text_sha` recorded first.
  - Proof: `zuvo:backlog verify` → `zuvo:backlog groom` → `zuvo:backlog doc` on this repo, then assert:
    all 387 entries carry a verdict with a resolvable evidence line; the 24 marker-carrying entries are
    archived with their blocks whole and their open siblings untouched; the 6 duplicate content keys are
    **disambiguated by minting distinct ids, never merged** — `backlog-protocol.md:205-207` is explicit
    that two entries sharing a key are two entries, and the option-A deferral below records that a
    key-deduping rewriter destroys 6 real entries here; `backlog-archive.py verify` reports `OK disjoint`; `status` no longer
    prints the false "nothing resolved left"; `lookup` resolves a sample of 10 heading ids; the working
    document exists with a not-verifiable section and a matching `source_sha256`.
  - Expected invariants: **entry-level** conservation keyed on `text_sha` —
    `open_before + archived_before == open_after + archived_after` — no entry text lost, and
    `memory/backlog.md` differing from its original only by minted ids.
  - Artifact: `zuvo/proofs/smoke-dogfood-zuvo-plugin.txt`
- **SMOKE2 — the refusal actually holds, and a second pass resumes for free**
  - Preconditions: a temp copy of this repo's backlog with one entry's verdict deleted from the ledger.
  - Proof: `groom` must refuse naming that id; `doc` must refuse without `--partial`; restore the
    verdict, re-run `verify` and assert **zero** agent dispatches (the `text_sha` reuse path); then
    `groom` succeeds.
  - Expected: two refusals with the id named, zero dispatches on the second `verify`, then success.
  - Artifact: `zuvo/proofs/smoke-refusal-and-resume.txt`

### Task 7: The smoke runner
**Files:** `tests/hooks/test-backlog-grooming-smoke.sh` (new)
**Surface:** integration
**Complexity:** standard
**Dependencies:** Task 6
**Failure:** halt
**Execution routing:** default implementation tier

- [ ] RED: the runner is the test; its RED is that the refusal half fails before Task 4 and passes
  after. No `SKIP:` path; mandatory `command_not_found_handle`. The dogfood half runs against a **temp
  copy**, never the live `memory/backlog.md`, so the suite is re-runnable.
- [ ] GREEN: author both smoke proofs above as one suite, auto-registered by the `tests/hooks/test-*.sh`
  glob. Where a step needs real agent dispatch, the suite asserts the orchestrator's queue and
  conservation logic against a recorded response fixture rather than calling a model, so it stays
  deterministic in CI.
- [ ] Verify: `bash tests/hooks/test-backlog-grooming-smoke.sh && bash tests/run-all.sh`
  Expected: `FAIL=0` in both.
- [ ] Acceptance Proof:
  - SMOKE1: Surface integration · Proof as above · Expected as above · Artifact `zuvo/proofs/smoke-dogfood-zuvo-plugin.txt`
  - SMOKE2: Surface integration · Proof as above · Expected as above · Artifact `zuvo/proofs/smoke-refusal-and-resume.txt`
- [ ] Commit: `test(backlog): end-to-end smoke for the grooming pipeline and its refusals`

---

## Deferred: option A (in-place re-emission) — and what the user gives up by not taking it

**Stated plainly, because two of the user's own words ride on it:** option B verifies, refreshes and
*closes*. It does **not sort or group the tracked file** — `memory/backlog.md` ends up with its resolved
entries archived and its unidentified entries minted, but in its original order, and the ordering and
grouping the user asked for ("sortował, grupował") live only in the rendered document. Option A is what
buys ordering inside `memory/backlog.md`. B was recommended by the Tech Lead, QA and the plan reviewer
on one shared ground: A's correctness is unprovable today, and what makes it provable is the ledger B
creates. If chosen, A lands as a third plan carrying all of B's work plus:

- a per-entry conservation oracle over the whole file — every pre-rewrite `text_sha` present exactly
  once after re-emission;
- **non-entry text conservation**: entry raw lines are 69,754 of 220,145 bytes, so **~150 KB is
  continuation prose, preamble, section headings and layout blank lines**, and no existing check covers
  any of it;
- ordering determinism (stable sort, same input → same output) and never ordering by id;
- `parse(render(parse(x))) == parse(x)`;
- the 6 duplicate `entry_key`s must survive re-emission **without being collapsed** — a re-emitter that
  dedups by key destroys 6 real entries and nothing currently notices;
- fenced-block safety in the write direction (the A30 class);
- a real-file golden: re-emit `memory/backlog.md` and require `git diff` to show only the intended
  normalizations — the only check that covers the ~150 KB;
- crash safety across a whole-file rewrite, where B's mint is line-local.

---

## Review Trail

- Phase 1: full fan-out (Architect → Tech Lead → QA Engineer, sequential, Opus, read-only), each stage
  correcting its predecessor; the orchestrator re-verified the load-bearing probes by execution.
- Plan reviewer, revision 1 → **ISSUES FOUND** (10, one CRITICAL). Every probe it re-ran reproduced.
  Revision 2 changes traceable to findings: the plan was **split into two sequential PRs** (rule 17),
  with the entry model, boundary rule, mint anchor and env-gated archive moving to PR 1; `doc` is now
  **gated on full verification** with an explicit `--partial` that omits the ranking (the brief forbids
  ranking and rendering before verification, and revision 1 had silently deviated); the rendered
  document carries source sha256 + coverage + version, and decision 12 records why the ledger's
  durability argument does not transfer to a regenerable report; Task 5's `Dependencies` now chain
  through Task 4 so `zuvo:execute` cannot dispatch it concurrently onto `backlog-groom.py`; a
  smoke-runner task was added (rule 8a) and a mocked full-pipeline case moved into Task 4's RED
  (rule 8b); every Verify and proof now gates on `$?` rather than `echo rc=$?` or a bare `grep`; the
  census takes literal roots and exits non-zero on an empty root set, so an unexpanded glob cannot pass
  silently; `docs/skills.md`'s existing row is extended rather than duplicated, and decision 1's claim
  about `cc_*` was corrected (it also asserts the category sums and the `**Total**` row); the option-A
  deferral now states outright that ordering and grouping of the tracked file are what B gives up.
- Cross-model validation, revision 2 → 4 providers (codex-5.3, byteplus-3, claude, muse;
  `--exclude-last cursor-agent` so the revised plan met a different model), 0 timeouts, input NOT
  truncated (35,951 of 50,000 chars). **Five CRITICAL, all five real** — three were internal
  contradictions, fixed in revision 3:
  (i) SMOKE1 demanded the 6 duplicate content keys be "collapsed onto one entry each" while also
  demanding entry-level conservation with nothing lost. `backlog-protocol.md:205-207` settles it: two
  entries sharing a key are two entries. Duplicates are now **disambiguated by minting distinct ids,
  never merged** — the same defect this plan's own option-A deferral warns a key-deduping rewriter
  would cause;
  (ii) a deadlock — `groom` refuses until every entry is verified, but id-less headings were given
  `NOT-VERIFIABLE — mint one`, so they could never reach a mint that only `groom` performed. Minting
  id-less entries moved into the deterministic pre-pass as verification *preparation*, making
  decision 5 mint-before-**verify**, not merely mint-before-normalize;
  (iii) AC3 required every deterministic evidence line to be resolvable while `STALE-OBSOLETE` cited
  `"<path> does not exist"` — unresolvable by construction. Evidence now cites the backlog line that
  names the path and states the absence in text;
  (iv) Task 2's Verify used `$HOME/DEV` as its pass/fail oracle. It now gates on a fixture root the
  suite creates with known per-level counts; the real tree is reported and gates nothing;
  (v) Task 4's mocked pipeline included `render`, which Task 5 implements. It now stops at `apply`, and
  the `apply → render` half is asserted in Task 5's RED — the same ordering class as PR 1's finding (i).
  Remaining WARNINGs are dispositioned in place; none changed task ordering or coverage.
- Plan reviewer, revision 3 → **ISSUES FOUND** (2 CRITICAL, 2 MAJOR, 2 MINOR). It re-verified every
  load-bearing number by execution and confirmed PR 1's fixes, AC4′'s no-red-window, the AC6a/AC6b
  split, rule 20 and cross-PR consumption. Both CRITICALs were in **revision 3's own fix (ii)**, and the
  orchestrator reproduced the arithmetic before accepting them. Revision 4:
  (i) the pre-pass mint had no defined input set. It would have written ids into the **19 id-less
  headings**, nine of which are plain section headers (`## benchmark skill`,
  `## 2026-04-17 zuvo:leads Task 1 (schema include)`) in a git-tracked file — and those 19 sit
  **outside** the 387 (81 id-shaped + 19 id-less = 100 headings; 306 + 81 = 387), so revision 3's
  "387 … of which 19 have no id" was arithmetically impossible and would have moved `entry_count`
  mid-run against a gate that compares to it. The mint set is now **the entries `iter_entries` yields
  without an `ident` — 263 of 387, count-neutral**; id-less headings are reported, never minted, as
  PR 1 decision 1 already said;
  (ii) the write moved to `plan` but every write-discipline and fail-closed assertion stayed on Task 4,
  where `apply`'s diff is now empty — so AC8 had become `0 == 0`, a proof that cannot fail. AC8 is
  restated as "`apply` writes **nothing** to `memory/backlog.md`", and a new **AC8′** on Task 2 carries
  the `Lock`, `atomic_write`, identity-check, byte-delta, permission-preservation, idempotence and
  `is_ignored() is None` fail-closed assertions to where the write actually is. CQ8's scope in the
  Quality Strategy now names `plan` as well as `apply`;
  (iii) control (c)'s basename equality made `STALE-OBSOLETE` structurally unable to pass, since fix
  (iii) has it cite a *backlog* line whose basename is never the missing path's. (c) is now scoped to
  the verdicts that cite a production path, and `STALE-OBSOLETE` gets its own control.
  PR 1 took the two MAJOR/MINOR items: the sibling rule is recorded as a **measured** 89/6 residual with
  the six counter-examples named and the Task 3 spike classifying terminators, and Task 3's RED prose no
  longer describes an archive destination that does not exist at that task.
  **Revision 4's own fixes have not been through a further review round** — the reviewer loop's
  3-iteration cap is reached, so residual risk is stated rather than looped on.
- **Decision taken 2026-09-27, by the agent, on the user's explicit instruction** ("nie wiem podejmij
  sam decyzje"): **option B**, with option A committed to as a third plan immediately after, not
  dropped. Reason: A's correctness has no oracle today — the per-entry `text_sha` a lossless rewrite
  needs is exactly what B's ledger creates, so writing A first means building the riskiest writer in
  the change with nothing to diff it against. The two verbs the user used that B defers ("sortował,
  grupował") are deferred, not abandoned; the costing is in the option-A section above.
  Revision 4's fixes are unreviewed (reviewer cap reached) — accepted, with execute's per-task gates
  as the compensating control.
- Status gate: **Approved** 2026-09-27T13:52:27Z — BLOCKED until PR 1 has landed on `main`.
