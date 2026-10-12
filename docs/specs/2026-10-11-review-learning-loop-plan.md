# Implementation Plan: Review-effectiveness learning loop

**Spec:** inline — no spec (brief: owner request 2026-10-11 "tak aż do końca" after the Bill analysis)
**spec_id:** none
**planning_mode:** inline
**source_of_truth:** inline brief
**plan_revision:** 4
**status:** Approved
**Created:** 2026-10-11
**Tasks:** 12 (Task 0 is a gate)
**Estimated complexity:** 8 complex, 3 standard, 1 gate

## Goal

Measure what code review catches (precision — Bill, exists) AND what it misses (escapes — new), turn both into
a small set of rules for the agents that write and review code, and measure each rule's effect so rules that do
not reduce their defect class are retired.

## Architecture Summary

- Helpers stay extensionless sh/python polyglots in `scripts/zuvo-home/`; logic moves into flat sibling modules
  (`zuvo_review_*` shared, `zuvo_bill_*`, `zuvo_escapes_*`), imported via `sys.path.insert(0, dirname(realpath(__file__)))`
  like `comment-audit:33`. `install_zuvo_home` (`scripts/install.d/zuvo-home.sh:320`) copies every flat file — no
  installer change.
- Data is per host (`~/.zuvo/`); ryzen-dev holds ~98% of reviews. Escapes + curation run on ONE curator host
  (where `bill --install-schedule --curate` is installed — ryzen-dev); readers also walk `~/.zuvo/remote/**`.
- New stores (HOME-local, never in a repo): `~/.zuvo/review-escapes-data/<project>.jsonl`,
  `~/.zuvo/knowledge/<project>/{anti-patterns,gotchas,codebase-facts}.jsonl` + `metrics.jsonl`,
  `~/.zuvo/knowledge-surfaced.log`.
- Driver: new module `scripts/lib/adversarial-agreement.sh`, additive top-level JSON key `agreement`, text-mode block
  on stderr. Ledger schema untouched.
- zuvo:review writes a findings sidecar `memory/reviews/<base7>..<head7>-<slug>.findings.json` (archived with the
  artifact); Bill judges it into `bill-data/` only (never through `--record-disposition`).
- Priming: deterministic helper `~/.zuvo/knowledge-overlay` merges repo + overlay entries; `knowledge-prime.md`
  calls it. Repo `knowledge/` is written only by a human-run `bill --promote` (never commits).

## Technical Decisions

1. `bill --curate` (not a separate helper): shares LLM hygiene, data dir, PAUSE, schedule; own lock `bill-data/.curate.lock`.
2. Closed defect-class vocabulary in `zuvo_review_classes.py`: race-condition, null-handling, numeric, boundary,
   contract-drift, validation, error-handling, auth, tenant-scope, data-loss, resource-leak, perf, test-gap, logic,
   style, other. Old free text normalized on read via an alias table; history is not re-judged.
3. Rate denominator = production lines merged per ISO week (`git log --first-parent -m --numstat <ref>`, prodpath
   filter); defects attributed to the review's ts, escapes to the fix merge's week; last 2 weeks recomputed each run.
4. Escape coverage: `reviewed` (artifact `files:` lists the path or `*` and intro commit ∈ range by ancestry; content
   fallback when rebased; `range_unresolved` otherwise) × `flagged` (ledger finding, project by basename, path-suffix
   match, ±10 lines of blame orig-line or final line, time window [intro−72h, fix)) with latest-verdict-wins then Bill
   verdict → accepted/dismissed/unjudged/none. Pure-addition fixes are `unattributed` (SZZ limit, reported).
5. Sidecar verdicts → `bill-data/` only, `source: review-sidecar`, `lanes: [agent]`; queue filtered by `host == host_tag()`.
6. Agreement helpers are PRIVATE (`_ar_agreement_json`, `_ar_print_agreement`), called from `ar_build_output` /
   `ar_emit_output`, NOT in `AR_REQUIRED_FNS` (test-adversarial-driver-modules.sh pins that list to Main's calls).
   `AR_MODULES` edited by hand. Never in the blind-audit document.
7. Overlay `timesSurfaced`: prime appends to `~/.zuvo/knowledge-surfaced.log`; only the curator rewrites overlay files.
8. Rule lifecycle: active → (4 weeks, class rate drop <15%) demoted → (4 more weeks) retired; <5 baseline events → hold.
   Writer rules measured on (real+escapes)/kloc of their class, reviewer rules on fp_rate. Unclassified escapes make
   escape rates `null`, never 0. Max 10 active rules per project; retired ids never reused.
9. Curate writes the overlay only with `--apply`; `bill --install-schedule --curate` generates the weekly unit
   WITHOUT `--apply` unless `--apply` is passed too (Task 8). Task 11 passes it only after the ccsync exclusion lands.
10. One reader: bill's own `read_ledger`, `jsonl()` and claude call are REPLACED by Task 2's `zuvo_review_ledger` /
    `run_claude` in Task 3 (CQ14) — not kept alongside.
11. Module budgets (rules/file-limits.md): logic modules ≤300 lines, helpers/launchers ≤100. Each multi-file task
    below is "flat modules of one helper, one public surface" — the file count is the split, not scope creep.
12. bill function → module map (Task 3):
    `bill` launcher (usage, argv dispatch, API/ImportError guard) · `zuvo_bill_config.py` (paths resolved at call
    time, env ints, now, locks, PAUSE, `API = 1`) · `zuvo_bill_judge.py` (prompt, findings block, `valid_verdicts`,
    `LIMIT_RE`) · `zuvo_bill_tick.py` (`pending`, `settle`, attempts, `record`, thread-pool tick) ·
    `zuvo_bill_schedule.py` (`install_schedule` → `install_unit`) · `zuvo_bill_status.py` (`status`).

## Quality Strategy

- Tests: stdlib unittest via `tests/hooks/test-*.sh` wrappers (`test-backlog-unit.sh` shape); harness
  `tests/hooks/bill_testlib.py` resolves paths at call time, purges `zuvo_bill_*`/`zuvo_review_*` from `sys.modules`
  per test, sets HOME + ZUVO_HOME to a temp dir, stubs `launchctl`/`systemctl`. Escape tests use real temp git repos
  with `GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1` and fixed `GIT_*_DATE`; injected `now`.
- Every test names the bug it catches (owner rule test-scope.md); no wiring tests. ruff 0 + mypy 0 on every new file
  (`tests/hooks/test-python-lint.sh`, local); new functions annotated so mypy checks them.
- CQ gates: CQ3 (validate every LLM answer + sidecar schema; argparse types), CQ5 (no author-mail / diff text
  persisted), CQ6 (windows, ancestry cache, `--classify-max`, curate input cap), CQ8 (timeouts on every subprocess,
  unresolvable → evidence not crash), CQ14 (one Python ledger reader; parity with bash header/prodpath rules), CQ19
  (additive contracts; pinned stdout/artifact/blind-audit keys byte-identical), CQ21 (mkdir locks, tmp+os.replace,
  API/ImportError guard, single writer per file), CQ22 (lock released in finally, process-group kill on timeout,
  uninstall path for units).
- Pinned suites that `run-all` does not run by default and must be run explicitly when the driver changes:
  `tests/adversarial/test-findings-ledger.sh`, `test-claude-reviewer-model.sh`, `test-backward-compat.sh`,
  `tests/hooks/test-adversarial-blind-audit.sh`, `npx bats@1.11.0 scripts/tests/adversarial-review.bats`.

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| G1 | Measure what review misses (escapes) per repo/window | deliverable | Task 5, Task 6 | tgm-survey-platform first |
| G2 | Coverage class per escape incl. flagged-but-dismissed | deliverable | Task 6 | |
| G3 | Weekly curation → ≤10 rules into HOME overlay, stable ids | deliverable | Task 8 | |
| G4 | Per-class rates + rule retirement (measured effect) | deliverable | Task 8 | |
| G5 | `--promote` to repo knowledge/, never commits | deliverable | Task 8 | |
| G6 | Agents read the overlay (writer + reviewer) | deliverable | Task 9 | incl. review sub-agents |
| G7 | zuvo:review findings sidecar judged by Bill | deliverable | Task 10 | |
| G8 | Lane-agreement annotation in the driver | deliverable | Task 7 | |
| G9 | Bill uses a closed class vocabulary | deliverable | Task 2, Task 4 | needed by G4 |
| C1 | Never write a team repo's tracked files automatically | constraint | Task 8, Task 9 | tested |
| C2 | Headless claude: strict empty MCP, no tools, cwd /tmp | constraint | Task 2 | `run_claude()` |
| C3 | Live bill job on two hosts keeps working through the change | constraint | Task 0, Task 3 | |
| C4 | Overlay never clobbered by ccsync | constraint | Task 1 | other repo; probe proof |
| C5 | Pinned driver contracts unchanged | constraint | Task 7 | |
| C6 | No adversarial lane prompt change without a benchmark | constraint | Task 7 | `git diff --exit-code` on adversarial-prompt.sh |

## Review Trail
- Phase 1: full fan-out (Architect → Tech Lead → QA, Opus, read-only)
- [DEVIATION] brief asked for the weekly curation "on both hosts"; the plan runs escapes + curation on ONE curator
  host (ryzen-dev) and mirrors the overlay to the Mac. Reason: git history is identical on both hosts, so two
  curators double-count every escape and grow two diverging rule sets. Bill's 10-minute judging stays on both hosts.
- Plan reviewer: revision 1 → ISSUES FOUND (14: ccsync has no dry-run, lint blind to untracked files + SKIP exits 0,
  wrappers list files by name, rule-9 deps, `--apply` unbuilt, sidecar lacks project path, promote unproven, smoke
  not wired, non-exit-status expectations, oversized Task 3, no module budgets, unmarked deviation + missing C6,
  scratchpad reference, CLAUDE.md module count) → all fixed in revision 2
- Plan reviewer: revision 2 → ISSUES FOUND (8: status string, stale-row tick proofs, scp glob, review/SKILL.md WIP gate,
  rule-9 deps of Tasks 8/9, curate output format + G4 check, ambiguous promote proof, Task 7 base sha) → fixed in revision 3
- Plan reviewer: revision 3 → 3 proof-mechanics issues (zsh unmatched glob in RSYNC-HELPERS, $B lost between tool
  calls, tee/SIGPIPE truncating the curate artifact) → applied inline; iteration cap (3) reached, no blocking issue left
- Cross-model validation (rev 3): partial (cursor-agent, byteplus-3, claude, kimi). 3 CRITICAL (same theme: riskiest
  cross-repo + live pieces scheduled last) → fixed in revision 4: ccsync exclusion moved to Task 1 (no deps) with a
  probe proof that a Mac-side file never reaches the host; escapes live proof now requires escapes>0 as the early
  feasibility check of blame attribution (STOP + re-plan if 0); final task only turns curation on. WARNINGs fixed:
  live-bill rollback (backup before RSYNC, restore + halt on failure), Task 4 → complex, G9 proof checks classes,
  sidecar schema-parity test, overlay `.prev` snapshot, Task 3 I/O-swap note, ccsync RED runnable. Rejected: Task 4
  `--by-agreement` needs the driver key (FP — it uses Bill's len(lanes)); "verification theater" (Verify runs named
  test suites whose cases are listed in RED); "happy-path only" (RED tables carry the error cases); stale `$B`
  finding (fixed in rev 3). Accepted as notes: Task 8 bundles curate+metrics+promote (one helper surface, budgets
  set); live proofs depend on real data (they are the point of a live proof).
- [POST-CAP: SPEC-AMENDED] execute Task 1 spec review: `~/.zuvo/review-escapes` was both the helper file and the
  store directory (the bill/bill-data collision class) → store renamed `~/.zuvo/review-escapes-data/`; ccsync excludes that name.
- [POST-CAP: SPEC-AMENDED] execute Task 5 live proof: the default `--ref origin/develop` read a stale mirror on the
  curator host (tgm-survey-platform's live remote is `bitbucket`, `origin` a frozen GitHub copy) → the default ref
  is develop's configured upstream, falling back to origin/develop.
- [POST-CAP: SPEC-AMENDED] execute Task 6: classification is per fix/intro pair and copied onto every row of the
  pair, so the G2 proof counts classified PAIRS (≤ --classify-max), not rows.
- [POST-CAP: SPEC-AMENDED] execute Task 6 review round: modules added to stay within budget (discover, hunks,
  gitbatch, cli) and a separate classify spec file; Task 5 and Task 6 land as one commit (the Task 5 snapshot was lost).
- [POST-CAP: SPEC-AMENDED] execute Task 4: the driver's --record-disposition accepted only finding rows keyed by
  the absolute checkout path, so bare-basename rows (92 of ~13k on the Mac) could never be recorded by anyone. Fixed
  at the root in scripts/lib/adversarial-ledger.sh: a row under the checkout's basename is accepted when no other
  absolute project in the ledger shares that basename (same guard for --effectiveness). Bill resolves a bare name to
  ~/DEV/<name> or a mirrored ledger's absolute path; a project that is not a git checkout here is never paid for —
  counted `unrecordable` and re-checked every tick until it leaves the 48 h window (nothing is marked done for it).
- Status gate: Approved — owner 2026-10-11 "tak aż do końca" (carry the whole loop through, no pauses)
- Cross-model validation: pending


## Task Breakdown

Common lint step (referred to as LINT below): `git add -N <new files> && set -o pipefail && bash tests/hooks/test-python-lint.sh 2>&1 | tee /dev/stderr | { ! grep -q SKIP; }` — `git add -N` makes the
new files visible to the `git ls-files`-based linter; the grep makes a missing ruff/mypy a failure instead of SKIP.
Remote install for proofs on ryzen-dev (referred to as RSYNC-HELPERS): `scp $(find scripts/zuvo-home -maxdepth 1 -type f \( -name bill -o -name review-escapes -o -name knowledge-overlay -o -name 'zuvo_review_*.py' -o -name 'zuvo_bill_*.py' -o -name 'zuvo_escapes_*.py' \)) ryzen-dev:.zuvo/`
(only this plan's files that exist at that task). BEFORE it, back up: `ssh ryzen-dev 'mkdir -p ~/.zuvo/bill-rollback/$(date +%s) && cp ~/.zuvo/bill ~/.zuvo/zuvo_*.py ~/.zuvo/bill-rollback/$(ls -t ~/.zuvo/bill-rollback | head -1)/ 2>/dev/null; true'`. If a live proof fails: copy the newest `~/.zuvo/bill-rollback/<ts>/*` back to `~/.zuvo/` and stop the task (halt) — the live 10-minute job must not stay broken. until ryzen-dev's checkout pulls the commits.

### Task 0: Gate — bill baseline owned by another session
**Files:** none (coordination)
**Surface:** config
**Complexity:** standard
**Dependencies:** none
**Failure:** halt
**Execution routing:** default implementation tier

- [ ] RED: n/a — gate task. `scripts/zuvo-home/bill` carries an uncommitted ~+198/−76 rewrite and an untracked
  `tests/hooks/test-bill.sh` from session zuvo-plugin-40 (asked 2026-10-11 18:55; owner confirmed, commit + push
  promised within ~1 h). `skills/review/SKILL.md` also carries that session's WIP (drive-by gate line). None of these
  files is edited until that work is committed by its owner.
- [ ] GREEN: wait for / confirm the owner's commit; record its sha. If the owner hands the WIP over, commit it as its
  own commit for that work (never folded into the split).
- [ ] Verify: `git diff --quiet HEAD -- scripts/zuvo-home/bill skills/review/SKILL.md && git ls-files --error-unmatch tests/hooks/test-bill.sh && bash tests/hooks/test-bill.sh`
  Expected: exit 0
- [ ] Acceptance Proof:
  - C3 (precondition) — Surface: config — Proof: the Verify command — Expected: exit 0 — Artifact: `zuvo/proofs/task-0-baseline.txt`
- [ ] Commit: none of ours; prints `[DECISION: bill baseline <sha>] → COMPLETE`

### Task 1: ccsync — never push or mirror-over the new HOME stores (moved early: riskiest cross-repo change)
**Files:** ~/DEV/cc-remote/bin/ccsync (other repo)
**Surface:** config
**Complexity:** standard
**Dependencies:** none
**Failure:** halt
**Execution routing:** default implementation tier

- [ ] RED: `Z=$(sed -n "s/^ZSTATE='\(.*\)'$/\1/p" ~/DEV/cc-remote/bin/ccsync); printf 'knowledge\n' | grep -qE "$Z"` exits 1 today (knowledge and review-escapes-data would be pushed Mac→host as helpers).
- [ ] GREEN: `ZSTATE` += `knowledge|review-escapes-data`; `ZLOGS` mirrors `adversarial-findings.log`, `knowledge-surfaced.log`, `bill-data/defects.jsonl`, `bill-data/lessons.jsonl` into `remote/…`; a one-way pull host `~/.zuvo/knowledge/` → Mac (no `--delete`). Commit in cc-remote (launchd runs ccsync from the repo, so it is live on commit).
- [ ] Verify: `Z=$(sed -n "s/^ZSTATE='\(.*\)'$/\1/p" ~/DEV/cc-remote/bin/ccsync); for n in knowledge review-escapes-data; do printf '%s\n' "$n" | grep -qE "$Z" || exit 1; done; bash -n ~/DEV/cc-remote/bin/ccsync`
  Expected: exit 0
- [ ] Acceptance Proof:
  - C4 — Surface: integration — Proof: `mkdir -p ~/.zuvo/knowledge/zz-probe && echo mac > ~/.zuvo/knowledge/zz-probe/probe.jsonl && ~/DEV/cc-remote/bin/ccsync; ssh ryzen-dev 'test ! -e ~/.zuvo/knowledge/zz-probe/probe.jsonl'; r=$?; rm -r ~/.zuvo/knowledge/zz-probe; test $r = 0` (a Mac-side file never reaches the curator host)
  - Expected: exit 0
  - Artifact: `zuvo/proofs/task-1-ccsync.txt`
- [ ] Commit: (cc-remote) `ccsync: the curator host owns ~/.zuvo/knowledge and review-escapes-data — never push them`

### Task 2: Shared review modules — ledger reader, class vocabulary, LLM call, production filter
**Files:** scripts/zuvo-home/zuvo_review_ledger.py, zuvo_review_classes.py, zuvo_review_llm.py, zuvo_review_prodpath.py; tests/hooks/review_testlib.py, tests/hooks/test_review_shared.py, tests/hooks/test-review-shared-unit.sh, tests/hooks/test-prodpath-parity.sh
(4 flat modules of one shared surface + their tests; budgets ≤150 each)
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** none
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED (`tests/hooks/test_review_shared.py`, tables):
  - classes: `race`, `Race Condition `, `undefined`, `security`, unknown, None → canonical or `other` (bug: free text splits a class in metrics)
  - ledger: latest verdict row wins per (project, fingerprint); project key = basename for abs-path AND basename rows, `/Users/…` and `/home/…` (bug: basename rows never matched); `file:line` split incl. `unknown` and bare path
  - llm: `run_claude()` argv has `--strict-mcp-config`, an empty server list, `--tools ""`, `--no-session-persistence`; cwd /tmp; a fake `claude` that sleeps past the timeout leaves no child process (bug: orphaned MCP servers)
  - `test-prodpath-parity.sh`: for each path in a table, bash `pg_is_production` false ⇒ python false; explicit table of the extra generated/lock patterns (bug: filters drift)
- [ ] GREEN: annotated functions; `remote_roots(name)` walks `~/.zuvo/remote/**` depth ≤2; `run_claude` → (rc, parsed_json|None, usage); paths resolved at call time.
- [ ] Verify: `bash tests/hooks/test-review-shared-unit.sh && bash tests/hooks/test-prodpath-parity.sh && LINT`
  Expected: exit 0
- [ ] Acceptance Proof:
  - G9, C2 — Surface: backend-logic — Proof: Verify command — Expected: exit 0 — Artifact: `zuvo/proofs/task-2-shared.txt`
- [ ] Commit: `feat(zuvo-home): shared review modules — one ledger reader, a closed defect-class vocabulary, one hygienic claude call`

### Task 3: Split bill into modules behind an install guard — behaviour unchanged
**Files:** scripts/zuvo-home/bill, zuvo_bill_config.py, zuvo_bill_judge.py, zuvo_bill_tick.py, zuvo_bill_schedule.py, zuvo_bill_status.py; tests/hooks/bill_testlib.py, tests/hooks/test_bill_unit.py, tests/hooks/test-bill-unit.sh
(flat modules of one helper per Decision 12; launcher ≤100, modules ≤300)
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** Task 0, Task 2
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED:
  - `tests/hooks/test-bill.sh` (Task 0 characterization) passes before AND after — only its loader path may change
  - launcher: a missing module or `API` mismatch → exit 0 with `bill: install in progress`; a persistent mismatch is shown by `--status` (bug: traceback loop during install / silent broken install)
  - `bill_testlib.py`: purges `zuvo_bill_*`/`zuvo_review_*` from `sys.modules`, sets HOME + ZUVO_HOME to a temp dir per test (bug: second test writes the real ~/.zuvo)
- [ ] GREEN: move code per Decision 12; replace bill's own ledger reader / jsonl / claude call with Task 2's (Decision 10); every WIP behaviour (settle, attempts, MIN_AGE, MAX_TRIES, LIMIT_RE, valid_verdicts) preserved.
- [ ] Verify: `bash tests/hooks/test-bill.sh && bash tests/hooks/test-bill-unit.sh && LINT && ZUVO_HOME=$(mktemp -d) python3 scripts/zuvo-home/bill --status | grep -q '^attempts: 0 total'` (string re-checked against the Task 0 commit)
  Expected: exit 0
- [ ] Acceptance Proof:
  - C3 — Surface: integration — Proof: `./scripts/install.sh && ~/.zuvo/bill --dry-run && RSYNC-HELPERS && n=$(ssh ryzen-dev 'wc -l < ~/.zuvo/bill-data/bill.log') && ssh ryzen-dev '~/.zuvo/bill --dry-run; ~/.zuvo/bill'`; then poll up to 12 min (the live timer may hold the lock) until `ssh ryzen-dev 'wc -l < ~/.zuvo/bill-data/bill.log'` > n, and assert the new rows have no `error`: `ssh ryzen-dev "tail -n +$((n+1)) ~/.zuvo/bill-data/bill.log" | python3 -c 'import json,sys; R=[json.loads(l) for l in sys.stdin if l.strip()]; assert R and all("error" not in r for r in R), R'`
  - Expected: exit 0 (rows written by the NEW code, none with an error)
  - Artifact: `zuvo/proofs/task-3-live-tick.txt`
- [ ] Note: swapping bill's ledger reader / claude call for Task 2's is an I/O change with NO intended behaviour change; the characterization suite is what proves it.
- [ ] Commit: `refactor(bill): modules beside the launcher, one ledger reader, install guard — no behaviour change`

### Task 4: bill behaviour — closed classes in the prompt, reviewed-line counts, unit installer, precision tables
**Files:** scripts/zuvo-home/zuvo_bill_judge.py, zuvo_bill_tick.py, zuvo_bill_schedule.py, zuvo_bill_status.py, bill; tests/hooks/test_bill_unit.py
(same helper's modules; one surface)
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** Task 3, Task 2
**Failure:** halt
**Execution routing:** default implementation tier

- [ ] RED:
  - judge prompt enumerates the closed vocabulary; an answer with an unknown class is normalized, not dropped
  - `bill.log` rows carry `diff_added`/`diff_removed` counted from the diff (bug: no reviewed-lines denominator)
  - `install_unit`: the 600 s plist / systemd unit is byte-identical to today's; launchctl/systemctl stubbed, HOME sandboxed (bug: live job rescheduled)
  - `--status --by-lane` and `--by-agreement` (precision by `len(lanes)`) from a fixture defects.jsonl
  - a ledger row whose project column is a bare basename resolves to the main checkout (`~/DEV/<basename>` or a `remote_roots` match) for `--record-disposition`; unresolvable → counted `unrecordable` in `--status`, never silently judged-but-unrecorded (bug: Bill judged basename rows and dropped the verdict — architect item 3)
- [ ] GREEN: `install_unit(label, argv, interval_s | calendar)` + uninstall; status tables.
- [ ] Verify: `python3 -m unittest -v tests/hooks/test_bill_unit.py && bash tests/hooks/test-bill.sh && LINT`
  Expected: exit 0
- [ ] Acceptance Proof:
  - G9 — Surface: integration — Proof: `./scripts/install.sh && RSYNC-HELPERS && n=$(ssh ryzen-dev 'wc -l < ~/.zuvo/bill-data/bill.log') && ssh ryzen-dev '~/.zuvo/bill'`; poll up to 12 min until the line count > n; then `ssh ryzen-dev "tail -n +$((n+1)) ~/.zuvo/bill-data/bill.log" | python3 -c 'import json,sys; R=[json.loads(l) for l in sys.stdin if l.strip()]; assert R and all("diff_added" in r for r in R if "error" not in r), R'` and the new defects rows use the closed vocabulary: `ssh ryzen-dev 'tail -n 50 ~/.zuvo/bill-data/defects.jsonl' | python3 -c 'import json,sys; sys.path.insert(0,"scripts/zuvo-home"); from zuvo_review_classes import CLASSES; R=[json.loads(l) for l in sys.stdin if l.strip()]; assert all(r["class"] in CLASSES for r in R[-10:]), R[-10:]'`
  - Expected: exit 0
  - Artifact: `zuvo/proofs/task-4-tick.txt`
- [ ] Commit: `feat(bill): closed defect classes, reviewed-line counts, precision by lane and by agreement`

### Task 5: review-escapes — fix discovery, blame to the introducing commit, idempotent store
**Files:** scripts/zuvo-home/review-escapes, zuvo_escapes_fixwalk.py, zuvo_escapes_blame.py, zuvo_escapes_store.py; tests/hooks/escapes_testlib.py, tests/hooks/test_escapes_blame.py, tests/hooks/test-review-escapes-unit.sh
(one helper's flat modules; launcher ≤100, modules ≤300)
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** Task 2
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED (real temp git repos: `GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1`, fixed `GIT_*_DATE`, injected now):
  - blame of a fix's deleted line lands on the introducing commit; intro → the first-parent merge that brought it in
  - `Merged in fix/…`, `Merged in hotfix/…`, `fix(x): …` found; `fixture: …`, `feat:` not
  - pure-addition fix → `unattributed`, no escape row
  - test/lock/generated/docs paths skipped; commit touching ≥`--mass-files` files skipped; `.git-blame-ignore-revs` honoured, absence harmless; merges and commits older than `--max-age` skipped
  - rerun → byte-identical file; classify fields kept unless `--reclassify`; key fix_sha:file:line_at_parent
  - no author email or diff text in records (CQ5)
- [ ] GREEN: `review-escapes --repo P [--since 30d] [--ref R (default: develop's upstream, e.g. bitbucket/develop; else origin/develop)] [--fetch] [--max-age 180d] [--mass-files 200] [--json]`; blame `-w --porcelain`; ancestry cache; atomic upsert; summary {fixes, escapes, unattributed, skipped{reason:n}}.
- [ ] Verify: `bash tests/hooks/test-review-escapes-unit.sh && LINT`
  Expected: exit 0
- [ ] Acceptance Proof:
  - G1 — Surface: db-data — Proof: `RSYNC-HELPERS && ssh ryzen-dev 'python3 ~/.zuvo/review-escapes --repo ~/DEV/tgm-survey-platform --since 30d --fetch --json' | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["fixes"]>0 and d["escapes"]>0, d'`
  - Expected: exit 0 — at least one real fix attributed to an introducing commit (the feasibility check of blame-based attribution on real history; if it is 0, STOP and re-plan escapes before Tasks 6–8)
  - Artifact: `zuvo/proofs/task-5-escapes-smoke.txt`
- [ ] Commit: `feat(review-escapes): trace each fix back to the commit that introduced the bug`

### Task 6: review-escapes — review coverage of each escape, optional classification
**Files:** scripts/zuvo-home/zuvo_escapes_artifacts.py, zuvo_escapes_discover.py, zuvo_escapes_ledgerjoin.py, zuvo_escapes_coverage.py, zuvo_escapes_classify.py, zuvo_escapes_hunks.py, zuvo_escapes_gitbatch.py, zuvo_escapes_cli.py, review-escapes; tests/hooks/test_escapes_coverage.py, tests/hooks/test_escapes_classify.py, tests/hooks/test-review-escapes-unit.sh
(coverage, discovery, prompt hunks, batched git reads and the locked run each in their own module per budget ≤300; launcher ≤100)
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** Task 5, Task 2
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED (tables):
  - intro in range → reviewed; intro before base → not; rebased-away SHAs with head object present → content fallback; head missing → `range_unresolved`, not reviewed
  - headerless dated `.md` ignored; `files: *`; comma list with spaces; PROVISIONAL → `provisional=true`; checkout copy beats archive copy of the same name; worktree roots scanned
  - ledger join: abs vs basename project; suffix match both directions; non-unique basename → no match; ±10 via blame orig-line when the final line moved; finding before intro−72h excluded; finding from the fix's own review excluded; later `rejected` beats earlier Bill `real`
  - label precedence flagged-* > reviewed > unreviewed
  - `--classify` validates the answer (class in vocabulary, bool catchable), stops at `--classify-max`
- [ ] GREEN: artifact sources = MAIN_ROOT + worktree `memory/reviews/` + `~/.zuvo/review-archive/<repo>/reviews/` + remote copies (dedup by filename); Bill verdicts from local + remote `bill-data/defects.jsonl`; `reviewed/<hash>` tags evidence only.
- [ ] Verify: `python3 -m unittest -v tests/hooks/test_escapes_coverage.py && bash tests/hooks/test-review-escapes-unit.sh && LINT`
  Expected: exit 0
- [ ] Acceptance Proof:
  - G2 — Surface: db-data — Proof: `RSYNC-HELPERS && ssh ryzen-dev 'python3 ~/.zuvo/review-escapes --repo ~/DEV/tgm-survey-platform --since 30d --classify --classify-max 5 >/dev/null && cat ~/.zuvo/review-escapes-data/tgm-survey-platform.jsonl' | python3 -c 'import json,sys; R=[json.loads(l) for l in sys.stdin if l.strip()]; L={"flagged-accepted","flagged-dismissed","flagged-unjudged","reviewed","unreviewed"}  # range_unresolved / provisional are evidence fields, not labels; assert R and all(r["coverage"] in L for r in R); assert len({(r["fix_sha"], r["intro_sha"]) for r in R if r.get("class")})<=5'`
  - Expected: exit 0
  - Artifact: `zuvo/proofs/task-6-coverage.txt`
- [ ] Commit: `feat(review-escapes): say for each escaped bug whether a review saw it, flagged it, or let it through`

### Task 7: Driver — lane agreement in the JSON document and on stderr
**Files:** scripts/lib/adversarial-agreement.sh, scripts/adversarial-review.sh (AR_MODULES), scripts/lib/adversarial-report.sh, shared/includes/adversarial-loop.md, CLAUDE.md (module count line); tests/hooks/test-adversarial-agreement.sh
(one driver surface; CLAUDE.md is the one-line module count)
**Surface:** integration
**Complexity:** complex
**Dependencies:** none
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED (`tests/hooks/test-adversarial-agreement.sh`, driver mock lanes, hermetic PATH):
  - 3 lanes within ±5 lines of one file → one group n_lanes 3; one lane with two findings there counts once
  - beyond the window / other file → separate; `./a.py` == `a.py`; `unknown`/no-line never merges
  - sorted by n_lanes then severity; text stdout byte-identical; block on stderr; blind-audit document keys unchanged; works with python3 off PATH
- [ ] GREEN: at task start `git rev-parse HEAD > zuvo/proofs/task-7-base.sha` (Verify and the proof read it with `B=$(cat zuvo/proofs/task-7-base.sha)` — shell variables do not survive between tool calls). Private `_ar_agreement_json` (jq) and `_ar_print_agreement` (NOT in AR_REQUIRED_FNS); `AR_MODULES` edited; additive top-level `agreement` key in the non-blind document only; `ZUVO_ADV_AGREE_WINDOW` (5); adversarial-loop.md: triage in `.agreement` order; CLAUDE.md "eleven" → "twelve".
- [ ] Verify: `B=$(cat zuvo/proofs/task-7-base.sha) && bash -n scripts/lib/adversarial-agreement.sh && bash tests/hooks/test-adversarial-driver-modules.sh && bash tests/hooks/test-adversarial-agreement.sh && bash tests/adversarial/test-findings-ledger.sh && bash tests/adversarial/test-claude-reviewer-model.sh && bash tests/adversarial/test-backward-compat.sh && bash tests/hooks/test-adversarial-blind-audit.sh && npx --yes bats@1.11.0 scripts/tests/adversarial-review.bats && bash tests/hooks/test-shellcheck.sh && git diff --exit-code $B -- scripts/lib/adversarial-prompt.sh`
  Expected: exit 0
- [ ] Acceptance Proof:
  - G8, C5, C6 — Surface: integration — Proof: `B=$(cat zuvo/proofs/task-7-base.sha) && ./scripts/install.sh && git diff $B -- scripts/lib/adversarial-report.sh | ~/.zuvo/adversarial-review --multi --mode code --json 2>/dev/null | jq -e 'has("agreement")'` and the Verify suite's byte-identical stdout check
  - Expected: exit 0
  - Artifact: `zuvo/proofs/task-7-agreement.json`
- [ ] Commit: `feat(adversarial): group findings several lanes raised on the same lines — agreement predicts a real defect`

### Task 8: bill --curate — rules from defects and escapes, weekly rates, retirement, promote
**Files:** scripts/zuvo-home/zuvo_bill_curate.py, zuvo_bill_overlay.py, zuvo_bill_metrics.py, zuvo_bill_schedule.py, bill; tests/hooks/test_bill_curate.py, tests/hooks/test-bill-unit.sh
(one helper's modules; budgets ≤300)
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** Task 2, Task 4, Task 5, Task 6
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED (fake `run_claude`, temp repo, fixed dates):
  - known id updated; unknown id rejected; null → minted `bill-<class>-<n>` never reusing a retired id; cap 10 active; unmentioned rules untouched
  - nothing written under `$MAIN_ROOT` by curate (C1); `--promote` writes the repo file once, rerun adds nothing, `git rev-list --count HEAD` unchanged
  - numstat denominator: branch merged once counted once; tests excluded; direct commit counted; 0-line week → rate null
  - ISO week across year end (2026-12-31 / 2027-01-01 → 2026-W53); defects attributed to the review ts
  - retirement table: drop ≥15% active; <15% at 4 w demoted; still <15% at 8 w retired; <5 events hold; unclassified escapes → escape rate null
  - surfaced counts: the same line in the local and a remote log counted once
  - dry-run prints `rule …` and `metric …` lines in the stated format;
  - without `--apply` nothing is written; `bill --install-schedule --curate` unit lacks `--apply`, with `--apply` it has it (launchctl/systemctl stubbed)
- [ ] GREEN: dry-run output format: one `rule <id> <class> <audience> <status>` line per rule, one `metric <week> <class> real=<n> escapes=<n> changed_lines=<n>` line per metrics row. `bill --curate [--project P] [--apply]`, `bill --promote ID… --project P --repo PATH`; escapes refreshed via subprocess (failure logged, not fatal); one Opus call per project, capped input; metrics upsert per (week, class), last 2 weeks recomputed; before every `--apply` rewrite the previous overlay file is kept as `<file>.prev` (one-step rollback); weekly unit (Mon 06:00).
- [ ] Verify: `python3 -m unittest -v tests/hooks/test_bill_curate.py && bash tests/hooks/test-bill-unit.sh && LINT`
  Expected: exit 0
- [ ] Acceptance Proof:
  - G3, G4, C1 — Surface: backend-logic — Proof: `RSYNC-HELPERS && ssh ryzen-dev '~/.zuvo/bill --curate --project tgm-survey-platform' > zuvo/proofs/task-8-curate-dry.txt && grep -q '^rule ' zuvo/proofs/task-8-curate-dry.txt && grep -q '^metric ' zuvo/proofs/task-8-curate-dry.txt && ssh ryzen-dev 'test -z "$(git -C ~/DEV/tgm-survey-platform status --porcelain knowledge)"'`
  - G5 — Surface: backend-logic — Proof: `python3 -m unittest -v tests/hooks/test_bill_curate.py -k test_promote_once_never_commits 2>&1 | tee zuvo/proofs/task-8-promote.txt | grep -qE '^Ran [1-9]'` (the case builds a temp clone, asserts rev-list count unchanged, knowledge/ dirty after the first promote, line count unchanged after the second) — Artifact: `zuvo/proofs/task-8-promote.txt`
  - Expected: exit 0
  - Artifact: `zuvo/proofs/task-8-curate-dry.txt`
- [ ] Commit: `feat(bill): weekly curation — rules from real defects and escapes, measured per class, retired when they do nothing`

### Task 9: Agents read the overlay — knowledge-overlay helper, includes, review + using-zuvo pre-checks
**Files:** scripts/zuvo-home/knowledge-overlay, shared/includes/knowledge-prime.md, shared/includes/knowledge-curate.md, skills/review/SKILL.md, skills/using-zuvo/SKILL.md; tests/hooks/test_knowledge_overlay.py, tests/hooks/test-bill-unit.sh
(one helper + the prose that calls it)
**Surface:** integration
**Complexity:** complex
**Dependencies:** Task 3, Task 5, Task 6, Task 8
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED:
  - helper table: repo copy wins on equal id; retired skipped; `audience: reviewer` only for work-type review; writer rules shown to reviewers; empty repo + non-empty overlay still returns entries (bug: pre-check skipped priming); one `knowledge-surfaced.log` line per surfaced overlay entry; overlay files never rewritten; repo `knowledge/` untouched (C1)
  - end-to-end with fakes (`test_loop_end_to_end`): temp repo with an introduced bug and a `fix/` merge → `review-escapes` → `bill --curate --apply` with a fake `run_claude` returning a rule → `knowledge-overlay --work-type implementation` prints that rule
- [ ] GREEN: `knowledge-overlay --project P --work-type T` prints merged JSONL; knowledge-prime Steps 1/2/6 call it; review SKILL.md:341 and using-zuvo:296 check repo OR overlay (MAIN_ROOT-anchored); review dispatch inputs (~:607) gain `KNOWLEDGE_CONTEXT`; knowledge-curate: `bill` in the source enum, never writes overlay entries into the repo.
- [ ] Verify: `python3 -m unittest -v tests/hooks/test_knowledge_overlay.py && bash tests/hooks/test-bill-unit.sh && bash scripts/validate-skills.sh && bash scripts/build-codex-skills.sh "$PWD" >/dev/null && LINT`
  Expected: exit 0
- [ ] Acceptance Proof:
  - G6, C1 — Surface: integration — Proof: `python3 -m unittest -v tests/hooks/test_knowledge_overlay.py` (fixtures built by its setUp under a temp ZUVO_HOME; cases `test_reviewer_rule_only_for_review`, `test_repo_untouched`, `test_loop_end_to_end`)
  - Expected: exit 0
  - Artifact: `zuvo/proofs/task-9-overlay.txt`
- [ ] Commit: `feat(knowledge): agents read Bill's measured rules from a HOME overlay; the team repo stays untouched`

### Task 10: zuvo:review findings sidecar, archived, judged by Bill
**Files:** skills/review/SKILL.md, shared/includes/review-artifact.md, scripts/review-artifact-sync.sh, scripts/zuvo-home/zuvo_bill_sidecar.py, zuvo_bill_tick.py; tests/hooks/test_bill_sidecar.py, tests/hooks/test-bill-unit.sh, tests/hooks/test-review-artifact-archive.sh
(one feature across the writer prose, the archiver and the reader)
**Surface:** integration
**Complexity:** complex
**Dependencies:** Task 3 (bill modules), Task 4 (zuvo_bill_tick.py as Task 4 leaves it), Task 9 (serializes the second edit of skills/review/SKILL.md — rule 13)
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED:
  - sidecar → defects.jsonl rows with `lanes=[agent]`, `source: review-sidecar`; the driver stub is never called
  - another host's sidecar skipped; `project` path missing on this host → resolved by `repo` basename under ~/DEV, else skipped with a reason; unbuildable diff given up after MAX_TRIES; malformed sidecar rejected by the schema validator
  - archive: a sidecar beside the `.md` is copied when the hook fires on the `.md`; absent sidecar is no error
  - schema parity: the JSON example in skills/review/SKILL.md's sidecar block passes the reader's validator (bug: the prose instructs a shape the reader rejects)
- [ ] GREEN: schema `{range, artifact, project (abs MAIN_ROOT), repo (basename), host, findings[{id, severity, file, line, title, detail, agent}]}`; SKILL.md Report Persistence writes `<stem>.findings.json` on success only, BEFORE the `.md`, same SHA/frozen-range rules; review-artifact.md documents it; `do_archive` copies it; tick merges the sidecar queue (`judged-sidecars.txt`).
- [ ] Verify: `python3 -m unittest -v tests/hooks/test_bill_sidecar.py && bash tests/hooks/test-bill-unit.sh && bash tests/hooks/test-review-artifact-archive.sh && bash scripts/validate-skills.sh && bash scripts/build-codex-skills.sh "$PWD" >/dev/null && LINT`
  Expected: exit 0
- [ ] Acceptance Proof:
  - G7 — Surface: integration — Proof: `python3 -m unittest -v tests/hooks/test_bill_sidecar.py` (case `test_sidecar_judged_without_driver`: fixture sidecar in a temp project + temp ZUVO_HOME, one tick with fake claude)
  - Expected: exit 0
  - Artifact: `zuvo/proofs/task-10-sidecar.txt`
- [ ] Commit: `feat(review): persist zuvo:review findings as JSON so Bill can judge the review agents too`

### Task 11: Turn curation on — weekly unit with --apply on the curator host, live smoke
**Files:** none in this repo (ryzen-dev schedule)
**Surface:** config
**Complexity:** standard
**Dependencies:** Task 1 (ccsync exclusion), Task 8 (`--apply`, curate unit), Task 9 (overlay layout the Mac reads), Task 10 (sidecar queue live)
**Failure:** halt
**Execution routing:** default implementation tier

- [ ] RED: `ssh ryzen-dev 'systemctl --user list-timers --all | grep -q zuvo-bill-curate'` exits 1 before.
- [ ] GREEN: RSYNC-HELPERS; on ryzen-dev `~/.zuvo/bill --install-schedule --curate --apply`; run one `~/.zuvo/bill --curate --apply`; one ccsync cycle.
- [ ] Verify: `ssh ryzen-dev 'systemctl --user list-timers --all | grep -q zuvo-bill-curate && systemctl --user cat zuvo-bill-curate.service | grep -q -- --apply'`
  Expected: exit 0
- [ ] Acceptance Proof:
  - SMOKE1 (below) — Surface: integration — writes `zuvo/proofs/smoke-review-learning-loop.txt`
  - Expected: exit 0
  - Artifact: `zuvo/proofs/task-11-enable.txt`
- [ ] Commit: none (host state); record the unit text in the artifact

## Whole-feature Smoke Proofs

- **SMOKE1 — escapes → rules → agents (live)**
  - Preconditions: Tasks 0–11 done; helpers on both hosts; one `bill --curate --apply` on ryzen-dev; one ccsync cycle.
  - Proof:
    `ssh ryzen-dev '~/.zuvo/review-escapes --repo ~/DEV/tgm-survey-platform --since 30d --json' | python3 -c 'import json,sys; assert json.load(sys.stdin)["fixes"]>0'`
    `&& ssh ryzen-dev '~/.zuvo/knowledge-overlay --project tgm-survey-platform --work-type implementation' | grep -q '"source": *"bill"'`
    `&& ~/.zuvo/knowledge-overlay --project tgm-survey-platform --work-type implementation | grep -q '"source": *"bill"'`
    `&& ssh ryzen-dev 'test -z "$(git -C ~/DEV/tgm-survey-platform status --porcelain knowledge)"'`
  - Expected: exit 0. Observation only (not a pass condition): `bill --status --by-agreement` precision per lane count.
  - Artifact: `zuvo/proofs/smoke-review-learning-loop.txt`
  - RED counterpart: Task 9 `test_loop_end_to_end` exercises the same chain with fakes.
