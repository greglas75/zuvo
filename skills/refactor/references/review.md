### Adversarial Review (MANDATORY — do NOT skip)

**Risk-sensitive mode selection:**
- Default: `--mode code`
- If diff touches auth, payment, crypto, PII, or migration files: `--mode security`

**Staging:** Stage ONLY files within the scope fence — not `git add -u` (which misses new files and may include unrelated changes):
```bash
git add [specific files from scope fence]
```

**Iterative review with `--multi`:** Run adversarial passes sequentially, every available provider per pass. Each pass sees the FIXED code from previous passes — so fixes themselves get reviewed. A pass that returns 0 new findings ends the loop **only when the ledger completion scan (below) is also clean** — an empty pass alone never ends it if an open CRITICAL identity remains.

Artifact counters describe recognized records. If `count_status=partial`, inspect the full provider output and reconcile the ledger before deciding that a pass has no new findings.

**Finding-disposition ledger (`zuvo/reports/refactor/<id>-findings.json`) — carry dispositions across passes.** Create the parent directory before writing. Choose the existing legacy `zuvo/contracts/<id>-findings.json` ledger if present; otherwise use the reports path. Use that one selected path for every read, write and completion scan. Feed resolved dispositions into later reviews so preserved-verbatim, out-of-fence and decision-deferred items do not consume another review pass.

**The orchestrator owns this ledger — providers never write it.** A provider only reports findings in its own words; the orchestrator normalizes each into one ledger row. That single rule dissolves the identity/duplicate problems: providers never mint fingerprints, so there is exactly ONE identity per finding. The file is a JSON **array** of rows like the one below; an *identity* is all rows sharing a `fingerprint`, and its state is that group's latest row.

```json
{ "fingerprint": "file|rule-id|signature", "provider": "codex-5.3", "severity": "CRITICAL|WARNING|INFO",
  "evidence": "one line",
  "disposition": "reported|fixed|false-positive|preserved-verbatim|out-of-fence|decision-deferred|reopened|reaffirmed",
  "reaffirms": "<the terminal disposition this row re-asserts; only for disposition=reaffirmed, else dash>",
  "fix_commit": "<sha7-or-dash>", "regression_test": "<path; REQUIRED when disposition=fixed, else dash>" }
```

- **Identity (assigned at ingest, by the orchestrator).** For each finding a provider reports, match it to an existing identity by `file|rule-id|signature`, else by `file|rule-id` + evidence. `signature` = a short normalized excerpt of the issue site (the offending symbol name or expression, whitespace-collapsed and lowercased) — it drifts when the code changes, so it is a matching hint, and `file|rule-id` + the orchestrator's evidence judgment is the fallback key. (This is guidance for an LLM orchestrator, not a byte-exact hash; the fallback path is expected to carry most matches.) Matched → append a row under that identity's **original fingerprint**. Unmatched → a new identity keyed by this fingerprint. A finding keeps ONE fingerprint for its whole life; there is never a second fingerprint to reconcile and no `supersedes` chain to walk.
- **Severity belongs to the IDENTITY, not the row — monotonic MAX, ratchets UP only.** An identity's severity is the highest severity any pass has assigned it: a later pass rating it higher ratchets it UP; **rating it lower NEVER lowers it** (re-rating a CRITICAL identity down to WARNING/INFO on a later row is forbidden). At ingest the orchestrator must preserve the provider's stated severity — it may not record a provider's CRITICAL as a lower severity on the first row. The gate (below) reads the *identity's* severity, never just the latest row's — so no downgraded row can flip a CRITICAL out of the blocking rule. When a severity ratchet lifts a WARNING/INFO identity UP to CRITICAL, any prior non-`fixed` terminal it held (a scope disposition `preserved-verbatim`/`out-of-fence`/`decision-deferred`, OR `false-positive`, which was judged at the lower severity) is no longer legal for it: the identity reverts to open (`reopened`) and must reach `fixed`/`false-positive` — re-judged at CRITICAL severity — before completion.
- **State = the latest row for an identity.** Passes run sequentially (one provider per pass), so append order is a total order and "latest" is unambiguous. `disposition` alone encodes the state: the OPEN states are `reported` (seen, not yet dispositioned) and `reopened` (was resolved, a later pass produced new evidence it persists); every other value is RESOLVED.
- **Resolving reuses the identity's original fingerprint** with `disposition: fixed` (or `false-positive` / a WARNING-only scope disposition) — it is never re-signed from the now-fixed code.
- **Regression vs. spurious re-report — both are LOGGED, never dropped.** When a later pass reports a finding whose identity is already resolved, the orchestrator appends a row (it never silently drops): if the evidence shows the issue STILL PRESENT (the fix did not hold), the row is `reopened` → it becomes the latest → for a CRITICAL it blocks. If there is no new evidence (the provider simply had not been told it was already resolved), the row is `reaffirmed` — it RE-ASSERTS the identity's prior terminal disposition (named in `reaffirms`, whatever it was: `fixed`/`false-positive`, or a WARNING/INFO scope disposition) and inherits that terminal status, with the evidence comparison that justified the call recorded in the row's `evidence` field. So the state stays settled *and* the re-report is auditable. A CRITICAL identity's prior terminal can only ever be `fixed`/`false-positive` (scope dispositions are forbidden for CRITICAL), so a `reaffirmed` CRITICAL necessarily inherits `fixed`/`false-positive` and does NOT block the gate. `reaffirmed` re-asserts a prior resolution; it is valid only on an already-resolved identity and never as a first row.
- **CRITICAL has only two terminal dispositions: `fixed` or `false-positive`.** A CRITICAL may NEVER be `preserved-verbatim` / `out-of-fence` / `decision-deferred` (those are WARNING/INFO-only scope decisions). **Any identity of CRITICAL severity whose latest disposition is other than `fixed`/`false-positive` blocks completion — regardless of pass count or an early 0-findings exit** (a `reaffirmed` latest row counts as the `fixed`/`false-positive` state it inherits, so it does not block). The severity checked is the identity's (its monotonic max, per the rule above), not the latest row's, so a downgraded later row cannot dodge it. `reported` and `reopened` are open states, so an un-remediated or regressed CRITICAL always blocks. This is what keeps the early exit safe: the carry-forward suppresses *re-reporting*, never remediation.
- **The completion scan (run at EVERY terminal path — 0-findings early exit, cap exhaustion, and final verdict).** The loop ends, and the run may claim done, ONLY IF a scan of the ledger shows no CRITICAL-severity identity whose *effective* terminal is outside `{fixed, false-positive}` (for a `reaffirmed` latest row, the effective terminal is the `fixed`/`false-positive` row it inherits). An identity failing that check BLOCKS the run (unsafe) — an empty pass never launders an open CRITICAL, and this scan runs at every terminal path, not just the early-exit one. The `fixed` rows' correctness is NOT re-litigated here: it rides on the machinery the skill already has — Phase 3.5's demonstrated `regression_red` (red→green) proof and the tests-still-pass gate — so the ledger references that proof rather than re-inventing a grade. Whether the run is `strict` or `degraded` is the existing PROVE telemetry's job (below), not a second grading rule in this scan.
- **Over-rated CRITICAL — resolved, never silently downgraded.** If a later assessment judges a CRITICAL was over-rated, it is still resolved the same two ways: `fixed`, or `false-positive` (with the rationale) when the CRITICAL claim itself was unfounded. There is deliberately NO severity-downgrade disposition — a silent downgrade is exactly the laundering vector this gate blocks, so a disputed CRITICAL is dispositioned, not re-rated away.
- **Open WARNING/INFO do NOT block after the pass cap** — they take the normal Phase 4 disposition (fixed within authorized behavior scope, with unrelated debt reported separately). This is why the post-cap verification pass may leave fresh WARNINGs unresolved without spinning a new loop.
- **Trust boundary (what the ledger does NOT do).** The ledger is orchestrator-owned bookkeeping; it cannot police the orchestrator's own honesty or blind spots. Its integrity rests on the mechanisms already in this skill, not on self-report: (1) the **Independent CQ Auditor** and the **cross-model multi-provider review** are the check on disposition calls — a mis-judged "spurious" or a fix-introduced defect the orchestrator failed to log is caught when the NEXT independent, different-model pass re-raises it; the ledger feeds those passes, it does not replace them. (2) **The orchestrator MUST NOT silently drop a re-report** — every re-report becomes a row (`reopened` for a regression, `reaffirmed` for a spurious one), per the rule above, so the decision is auditable, never invisible. (3) **A `fixed` disposition REQUIRES a `regression_test`** (mandatory for `fixed`, per the schema; `-` is allowed only for non-`fixed` rows): "fixed" is then backed by a test that goes red on regression at the tests-still-pass gate — mechanical proof independent of the ledger, not the orchestrator's say-so. Where none of these can run (no independent pass, no test possible), the run's PROVE telemetry records the weaker `blind_audit`/`adversarial` `degraded` value and the run cannot claim `strict` — the ledger `disposition` enum is unchanged.
- **The dispositions must ADD UP to the reported count.** `prove.adversarial` records a number
  (`6findings`); the ledger's dispositioned rows for this run must sum to exactly that. If they do
  not, either a finding was dropped without a disposition or the count was copied from a different
  pass — both are silent, and both look identical to a clean run. Count by REPORTED OCCURRENCE (a
  finding raised in two passes counts twice, matching what `prove.adversarial` saw); when duplicates
  recur, additionally report the unique root-cause total, because "6 findings, 2 root causes" and
  "6 independent findings" are very different runs and the single number cannot distinguish them.
- This is a companion to the run CONTRACT (`zuvo/contracts/<id>.json`), same directory and lifecycle — not a new state location.
- **Enforcement model & known limits (disclosed, not hidden).** These per-row rules are **agent-followed guidance**, not hook-validated: the deterministic `refactor-safety-gate` hook enforces only the COARSE contract (`prove.blind_audit`, `prove.adversarial`, `findings_disposition`) — it does not parse this ledger row-by-row. So the ledger's integrity has exactly three backstops, and no more: (1) the **independent cross-model multi-provider review + CQ auditor** re-derive findings without trusting the ledger — a mis-judged `false-positive`, a spurious→`reaffirmed` that was really a regression, or two distinct bugs fuzzy-matched into one identity are caught when a different-model pass raises the surviving defect on the actual code (the ledger feeds these passes but is not their source of truth); (2) a `fixed` row's **`regression_test`** goes red at the tests-still-pass gate if the fix regresses — mechanical, ledger-independent; (3) `ACCEPTED_FINDINGS` suppresses *re-listing* a settled item but a provider may always raise it **with new evidence**, so suppression narrows re-litigation without blinding the next pass to a real defect. What this does NOT give: byte-exact identity matching (it is LLM judgment with a `file|rule-id`+evidence fallback), write-time schema validation, cognitive independence for the single-agent-lock *inline* auditor (same context — hence `degraded:same-model`; the cross-model multi-provider review, not the inline pass, is the real independence check), or any guarantee against an orchestrator that is both dishonest AND faces a same-model-only provider pool — that residual is the reason the blind audit and cross-model multi-provider review exist and are themselves HARD GATES. The `degraded` marker is keyed to which providers ACTUALLY ran (not merely the pool's composition): if no cross-family pass in fact executed, the run records `degraded:same-family` and cannot claim `strict`. Record `degraded` telemetry (never `strict`) whenever a backstop cannot run. **When BOTH independence backstops degrade at once — a same-model inline CQ auditor AND a same-family-only adversarial pass — zero independent verification actually occurred; the run records `degraded:no-independent-verification` (never `strict`), and its report must state plainly that no independent eyes reviewed it.** This is disclosure within the existing `strict`/`degraded` telemetry model, not a new verdict enum. ("HARD GATE" for the blind audit and cross-model multi-provider review means the pass must RUN — *absent* is BLOCKED; running *degraded* satisfies the gate but caps the grade at `degraded`, and whether a fully-degraded run is shippable is then the coarse gate's / reviewer's policy call, not something the ledger invents.) **Regression-proof enforcement is run-level, not per-identity:** the mechanically-enforced floor is Phase 3.5's `prove.regression_red` + the tests-still-pass gate, which the coarse hook reads; the ledger's per-row `regression_test` is a finer-grained *record*, not an independently-enforced check, so a multi-CRITICAL fix relies on that run-level proof covering all of its fixes — a bounded, pre-existing limit of the skill's regression machinery, not a hole this ledger introduces. And the residual the cross-model multi-provider review exists to catch is not only re-report misjudgements but a **first-pass omission** — a real defect the orchestrator never logged at all; that is why the independent, different-model pass reads the actual code rather than trusting the ledger's row set.

**Proof limits:** v3–v5 textual characterization/regression fields are legacy claims. v6 links
measured runs, commands, snapshots and log digests per `refactor-reference.md`; green rechecks
cannot satisfy red proof. Records are author-controlled, not cryptographically attested runner
results. An independent reviewer still checks that commands/assertions test the claimed behavior.

**ACCEPTED_FINDINGS carry-forward.** Before each pass after the first, prepend the latest RESOLVED row of each identity to the adversarial input as an `ACCEPTED_FINDINGS` block (fingerprint + disposition + the one-line reason) and instruct the provider: **a settled disposition is not a finding — do not re-report it.** If the provider believes a listed item is wrong, it must say so **with new evidence** — and a **higher-severity assessment counts as new evidence** (a later pass arguing a settled WARNING is really CRITICAL reopens it for re-rating; this is the only way the severity ratchet fires on an already-dispositioned identity, so ACCEPTED_FINDINGS suppression can never freeze a mis-rated CRITICAL as a settled WARNING). The orchestrator treats such a re-report as the regression path above and appends a `reopened` row for that one identity, at the escalated severity. This makes the 0-findings early exit reachable and ends the unbounded clean-check loop **without weakening remediation** — a real, un-dispositioned bug is still a finding, a regressed CRITICAL re-opens and blocks, and every CRITICAL must still reach `fixed`/`false-positive`.

**Context-enriched input:** Prepend refactoring context + full source files so the provider can verify behavioral equivalence, not just diff syntax:

```bash
(echo "CONTEXT: refactor [TYPE] [TARGET] scope:[N files]";
 echo "CQ-PRE: [pre-audit score]. CQ-POST: [post-audit score]. Critical: [gates]";
 echo "SCOPE-FENCE: [file list]";
 echo "MOVED_VERBATIM: [files PROVEN byte-identical to PRE_REFACTOR_SHA — see regression-fence.md; assert the list only after the check passes]. Focus on new/changed logic. Verbatim-moved code is out of scope unless the move itself creates an issue.";
 echo "---NEW/MODIFIED FILES---";
 cat [each new or modified PRODUCTION file in scope fence];   # NOT the test files — see below
 echo "---TESTS: [N] characterization tests green on <pre-refactor sha7>, [M] existing suites pass---";
 echo "---FACADE + COLLABORATORS (SPLIT/EXTRACT only)---";
 cat [the composing facade]; sed -n '1,80p' [each direct collaborator];
 echo "---ORIGINAL SOURCE (excerpt-capped)---";
 head -c 40000 [target file before refactoring];
 echo "---DIFF---";
 git diff --staged) | ~/.zuvo/adversarial-review --multi --mode [code|security]
```

**Measure the payload BEFORE dispatch, do not discover the cap by being truncated.** Pipe the
assembled input through `wc -c` first. The wrapper caps at 30K (code/test) and truncates silently
enough that a pass which never saw the highest-risk file is indistinguishable from a clean one:

```bash
SIZE=$(…assembly… | wc -c)
[ "$SIZE" -gt 28000 ] && echo "SPLIT REQUIRED: ${SIZE}c"
```

Over the cap, split **by extracted responsibility** — one pass per extracted module, each carrying
only the ORIGINAL segment that module came from — rather than letting the tail fall off. Aggregate
the findings across passes; a file that received no pass is not reviewed, and saying so is
mandatory (`../../../shared/includes/cross-provider-review.md`).

**Tests are summarized, not pasted.** `cat`-ing a large characterization suite displaces the
production files the review exists to look at — the promised context gets evicted by the very
tests that prove it works. Send the one-line green summary above instead. Same for lockfiles and
generated output.

**SPLIT/EXTRACT must carry the facade.** When behaviour is assembled across files, a module-only
prompt makes reviewers report that fields, guards or gates "disappeared" — they were reattached
one layer up, in the composing facade the prompt omitted. Include the facade in full and the first
~80 lines (signatures) of each direct collaborator. This is the single largest source of
false-positive findings in split refactors.

The provider receives: (1) every new/modified in-fence file in full — placed FIRST so provider truncation can never drop the files under review, (2) the original file (excerpt-capped) — can check nothing was lost in extraction, (3) diff — sees exact changes. This prevents false positives on moved-verbatim code while catching real issues like dropped branches, changed signatures, or broken re-exports.

**DELETE_DEAD reviews:** prepend the verified production caller count and the zero-consumer evidence to the CONTEXT line, plus `UNTOUCHED_NOT_REPLACEMENT: <symbol> (<reason>)` for any name-similar unit the plan deliberately leaves alone. Reviewers flag only behavior removed from a LIVE path. Proposals to port or implement never-wired behavior are feature gaps (backlog), and documented-but-unmounted behavior is documentation drift (backlog) — neither is a refactor regression nor an in-fence blocker unless the staged deletion changes current runtime behavior.

If `adversarial-review` is not in PATH: `~/.zuvo/adversarial-review` (stable; the versioned cache path breaks after any release)

**Preflight the providers ONCE, before the first dispatch.** Run discovery a single time
(`~/.zuvo/adversarial-review --doctor`, or the first pass's provider list). If NO provider is reachable,
record `adversarial: blocked:no-provider` and go straight to the independent local CQ/security
pass — do **not** retry the dispatch per pass. Repeated zero-output attempts against an unreachable
provider are the most common way a refactor burns its budget without producing a single finding,
and the outcome is identical after the first attempt. `blocked:no-provider` is an honest degraded
state that must appear in the report; it is NOT `clean`.

**Fallback order when a provider is down** — follow it in order, stop at the first that works, and
record which step produced the pass. Guessing at this per-run is where the trial-and-error goes:

| # | Try | Record as |
|---|-----|-----------|
| 1 | Another provider in the pool, different model family | `clean`/`Nfindings` (full strength) |
| 2 | Another provider, SAME family as the orchestrator | `…:degraded:same-family` |
| 3 | The orchestrator itself, inline, as a blind second pass on the diff alone | `…:degraded:same-model` |
| 4 | Nothing reachable | `blocked:no-provider` + the local CQ/security pass |

Steps 2-4 are progressively weaker independence, and each has its own marker precisely so the
report cannot present them as the same thing. Never skip to step 4 because step 1 failed once —
`--doctor` tells you which providers are actually reachable, so the choice is a lookup, not a
search. An auth failure is cached for the run (`adversarial-review.sh` remembers it), so trying the
next provider costs one dispatch, not another full timeout.

**Pass count by diff size:**

| Diff size | Max passes | Rationale |
|-----------|-----------|-----------|
| < 50 lines | 2 | Small extraction — quick sanity check |
| 50-200 lines | 3 | Standard refactor — most issues found in 2-3 passes |
| > 200 lines or GOD_CLASS | 4 | Large split — fixes on fixes need full depth |

**Remediation review passes `--multi` (changed 2026-09-02).** It used to pass `--rotate` — one
random provider per pass — on the reasoning that diversity accumulates ACROSS the capped passes
and the ledger carries dispositions between them. That reasoning is coherent and it is why the
flag stood for so long. It was overruled by measurement.

Measured on 20 real review diffs, every finding judged REAL / FALSE_POSITIVE by an independent
Opus judge against the diff, with a shared defect-id vocabulary so overlapping findings collapse:
**57% of each model's true findings are unique to that model, and no single model sees more than
28% of the 347 distinct defects.** Diversity-over-time only works if a later pass re-examines the
SAME code — but each pass here reviews the FIX diff, not the original, so a defect that provider A
missed in pass 1 is never shown to provider B at all. Rotation across passes diversifies the
reviewer, not the coverage of any given change.

The cost is real and is the price of that coverage: 4 passes now fan out to every configured
provider instead of one, so provider calls per refactor rise roughly 5x. Bound the spend with the
PASS CAP (the table above) and `--exclude`, not by narrowing each pass to a single opinion.

**Convergence at the pass cap (the last pass is never the finish line for a CRITICAL).** The cap bounds *review* effort, not *remediation*. If the LAST permitted pass surfaces a CRITICAL, apply the fix and run ONE verification-only pass beyond the cap. That pass may ONLY confirm the CRITICAL is gone and (via the ledger) that the fix introduced nothing new — it may **not** open a new remediation loop for fresh WARNINGs. **Non-CRITICAL findings on the last pass do NOT earn an extra pass.** When the final permitted pass
returns only WARNING/INFO: apply mechanical fixes within the authorized behavior scope, run the focused tests, record each
disposition in the ledger, and stop. Spending another full rotated pass to re-confirm a set of
one-line fixes is the loop this cap exists to end — the ledger already records what was done, and
the tests already prove it. The extra pass is reserved for the CRITICAL case below, where the
question is whether a *safety* claim still holds.

If a CRITICAL is still unresolved after that verification pass, **or the verification pass surfaces a NEW CRITICAL** (introduced by the fix or otherwise), that CRITICAL counts as unresolved and the run is **BLOCKED (unsafe), not "shipped at cap"** — do not spin another fix loop past the cap. An unfixed CRITICAL blocks completion no matter how many passes were spent.

**Per-pass fix policy (disposition by fix-SCOPE, never by line count):**

| Finding | Action |
|---------|--------|
| **CRITICAL** | Fix immediately. Re-run tests. |
| **WARNING — real bug, one clearly-correct fix** | Fix it in Phase 3.5 (the fix commit). **Size is irrelevant** — a 40-line mechanical bug is still fix-now. Never park a bug just because the fix is large. |
| **WARNING — needs a behavior/product DECISION** (e.g. on total failure: partial result vs hard error) | Not a bug, a choice. Interactive → ask the user (Phase 3.5 decision gate, ≤1 question). Batch/`--auto`/`no-pause` → pick the safe default, log `[DECISION-DEFAULT: …]`, surface in report. |
| **WARNING — fix needs files OUTSIDE the scope fence** | Backlog with file:line — genuinely out of this contract's reach. |
| **INFO** | Known concerns (max 3, one line each). |
| **0 findings** | Early exit — stop passes, code is clean. |

The old "WARNING > 10 lines → backlog" rule is gone: line count is not a proxy for scope. A big mechanical fix is still a fix; a one-line product decision is still a decision.

**Meta-review:** If pass 1 returns 0 findings AND diff_lines > 150: add false-negative warning — large diffs with zero findings suggest insufficient review depth. Run pass 2 regardless. (`diff_lines` = the sum from `git diff --staged --numstat`, computed BEFORE prompt enrichment — never derived from reviewer input or prompt line count.)

Do NOT discard findings based on confidence alone. "Pre-existing" is NOT a reason to skip — if the issue is in a file you are editing, fix it now.

**Boundary/security findings: trace one layer OUT and one layer IN before classifying.** A provider
reviewing a service file in isolation cannot see the guards around it, so it reliably reports
"missing rate limiting", "unbounded input", "no auth check", "missing uniqueness" on code where the
router already validates and the schema already constrains. Before dispositioning such a finding:

- **One layer outward** — the router/middleware: is the input already validated, authenticated,
  size-capped, or rate-limited before it reaches this function?
- **One layer inward** — persistence: does a NOT NULL / UNIQUE / CHECK constraint or transaction
  already enforce the invariant the finding says is missing?

Dismiss ONLY when a layer enforces **the specific invariant the finding names**, on **every** path
that reaches this code — a guard that validates a different field, or that sits on one of three
routes (plus a queue consumer and a CLI entry point) mounting the same service, is not enforcement.
`grep` the call sites before concluding "the router handles it". When that holds, the finding is a
false positive — record it as such **with the citation** (`router.ts:42 validates`, `schema.sql:17
UNIQUE`), not as a bare dismissal. Partial enforcement is a REAL finding, narrowed to the unguarded
paths. If neither layer enforces it, it is real and in scope. This check is what separates "the reviewer lacked context" from "the
guard is genuinely absent" — and citing the enforcing line is what stops the next pass re-raising it.

---
