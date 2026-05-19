# Implementation Plan: Retro Checkpoint Capture (stop losing ~50% of pipeline runs)

**Spec:** inline — no spec
**spec_id:** none
**planning_mode:** inline
**source_of_truth:** inline brief (prior art: `docs/specs/2026-04-09-retrospective-feedback-loop-spec.md` is context only — its D5/Edge-280/AC1 terminal-gate decision is what this plan supersedes)
**plan_revision:** 3
**status:** Approved
**approved_at:** 2026-05-18 (user: interactive "go")
**Created:** 2026-05-18
**Tasks:** 9
**Estimated complexity:** complex-heavy (4 complex, 5 standard) — shell + markdown infra, no TS/Python/npm

## Architecture Summary

The retro/run-logging data path: a skill works → fills `retrospective.md` protocol → appends a `RETRO:` line to `~/.zuvo/retros.log` + a block to `~/.zuvo/retros.md` → calls the `~/.zuvo/append-runlog` gate → gate verifies a matching retro exists → appends the `Run:` line to `~/.zuvo/runs.log`. Source of the `~/.zuvo/*` scripts is `scripts/zuvo-home/{append-runlog,verify-audit,compute-preload}`, deployed by an inline block in `scripts/install.sh` (L221–256, `# ZUVO HOME ($HOME/.zuvo)`).

**Three structural loss paths:** (1) brainstorm/plan load `retrospective.md` "deferred (completion)" but never reach a completion step — they hand off; no retro, no run line. (2) execute mid-run abandon/pause/context-out skips Phase Final → no stub. (3) `session-state.md` carries `next-task` across resume but not retro state → resumed runs cannot finalize the prior session's retro. **Plus a stale-match defect:** `append-runlog` awk `($2==skill || $1 ~ "RETRO: " skill) && index($0,project)` is skill+project, **any timestamp** → a weeks-old retro satisfies every later same-skill run.

**Architectural truth (QA):** an abandoned run cannot self-report from inside itself, and brainstorm/plan have no in-skill abort hook. So checkpoint capture must be **passive at the next boundary**: a skill writes a *run-marker* at start and clears it on clean completion; the next zuvo skill start sweeps for an orphaned marker with no matching retro and emits a degraded stub for it (Windsurf passive-capture / Reflexion "capture incomplete runs at a strong external boundary").

## Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Stub mechanism | New script `scripts/zuvo-home/retro-stub` | Matches the `zuvo-home` helper convention; zero token bloat on shared includes; independently testable |
| Capture trigger | **Run-marker (skill-side, minimal) + `retro-stub --sweep` at next boundary** | QA proved skills can't self-report abandonment; passive next-boundary sweep is the only mechanism that captures genuinely abandoned runs. Marker *write/clear* is skill-side instrumentation (Task 7); `--sweep` is a defensive scanner (Task 5) |
| Testability | `ZUVO_HOME` env override (default `$HOME/.zuvo`) in `append-runlog` AND `retro-stub`, consistent with the existing `CODEX_WORKSPACE→memory/` branch in `retrospective.md` | **Blocking prerequisite** (Task 1) — hermetic harness isolation |
| **Canonical "full retro" predicate** (single source of truth) | A line is a **full retro** iff it starts `RETRO:` AND field 5 (FRICTION_CATEGORY) ∉ `{abandoned, context-out, partial-recovery}`. A **stub** is a `RETRO:` line whose field 5 ∈ that set. Defined once in `retrospective.md` (Task 2); referenced verbatim by `retro-stub` idempotency (Task 3), the `append-runlog` match (Task 4), and `--sweep` (Task 5). | Resolves the reviewer's "three incompatible supersession contracts" — one predicate, three consumers |
| Strong-signal match | `append-runlog` gates only on a **full retro** (predicate above) with `skill` + `project` + (`SHA7==HEAD` OR retro-ts ≥ run-start). A stub NEVER satisfies the gate. **Strict default**, `ZUVO_MATCH_LOOSE=1` documented relax | A completed run always writes a full retro; gating on full-only means a stale stub OR stale full can't satisfy a fresh run (SC2). Incomplete runs never call `append-runlog`, so excluding stubs from the gate loses nothing |
| Supersession | Stub is informational telemetry only. `retro-stub` is a no-op if a **full retro** for the same `skill+project+SHA7` already exists; a later full retro for a session simply coexists and is preferred by downstream dedup (`date+skill+project`, full wins) | Coherent: stub never blocks/satisfies a gate; no double-count |
| Escape-hatch visibility | `ZUVO_SKIP_RETRO_GATE=1` appends a rotated `SKIP:` line to `$ZUVO_HOME/skip-retro-gate.log` (header + last 100). SC4b: a `zuvo:context-audit`-parseable contract (documented format) so the next audit surfaces bypasses | Durable + bounded (CQ6) + actually discoverable |
| Concurrency | `flock -x` around every append in `append-runlog` and `retro-stub`; fallback to `mkdir`-atomic lockfile if `flock` absent (macOS has it; guard anyway) | `zuvo:execute` parallelism + multi-provider review append concurrently (QA risk #2) |
| Session-state carry | Add `retro-session-id` / `last-retro-status` / `last-retro-friction` to `.zuvo/context/execution-state.md`; resume rule = one execution-state session → exactly one eventual retro | Coherent multi-session retro (SC3) |
| append-runlog edit locality | **All `append-runlog` edits land in exactly two tasks: Task 1 (ZUVO_HOME) then Task 4 (everything else: match + flock + skip-log + marker-clear), strictly linear.** Tasks 5–8 never touch `append-runlog`. | Removes the reviewer's shared-file edit-contention risk entirely |
| Distribution | Append `retro-stub` cp/chmod block to `scripts/install.sh`; verify `build-codex-skills.sh`/`build-cursor-skills.sh` copy `scripts/` wholesale (Task 8 asserts this, not assumes it) | Proven pattern, verified not assumed |

## Quality Strategy

- **Harness:** `tests/adversarial/` (`run.sh` discovers `test-*.sh`; `assert.sh` = `start_test/pass/fail/assert_eq`; `ADV_TEST_HOME="$HERE/.tmp"`). Every new test sets `ZUVO_HOME="$ADV_TEST_HOME/zuvo-$$"` — hermetic, never touches real `~/.zuvo` (Task 1 is the blocking foundation).
- **CQ gates active & owned:** CQ8 file-write/flock error handling → Tasks 3,4 (asserted, not just mentioned); CQ6 skip-log rotation → Task 4; CQ14 `retro-stub` reuses (does not re-derive) the `retrospective.md` field shape and the canonical predicate → Task 3 references Task 2's definition; CQ22 PID+`%s%N` temp files → Tasks 3,4.
- **Regression guard:** SMOKE1 is the canonical completed-run flow run hermetically (full retro → `append-runlog` → `runs.log`) against the modified scripts — proves SC5 without polluting real `~/.zuvo` (reviewer's "clear real ~/.zuvo SMOKE4" is rejected: it would corrupt the user's live telemetry and violate the local-only constraint; the hermetic equivalent is strictly safer and equivalent in coverage).
- **Local-only:** all changes are local file I/O; no network.

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| SC1 | Abandoned/paused/context-out run produces a retro stub with friction reason | requirement | Task 3, Task 5, Task 7 | stub emit + sweep + skill run-markers |
| SC2 | Fresh completed run on a project with an old same-skill retro MUST write its own | requirement | Task 4 | strong-signal, full-retro-only match |
| SC3 | Resumed multi-session runs finalize ONE coherent retro | requirement | Task 6, Task 7 | session-state carry + execute resume wiring |
| SC4 | Escape-hatch usage is always visible (log exists, readable) | requirement | Task 4 | rotated skip-retro-gate.log |
| SC4b | Escape-hatch bypasses are surfaced by the next `zuvo:context-audit` | requirement | Task 9 | context-audit actually parses+reports `SKIP:` (Task 4 only produces the contract) |
| SC5 | No regression to the existing happy-path | constraint | Task 1, Task 4, SMOKE1 | hermetic regression assertions |
| G-TEST | Hermetically testable (no `~/.zuvo` pollution) | constraint | Task 1 | `ZUVO_HOME` override — blocking prerequisite |
| G-CONC | Concurrent appends never corrupt logs | constraint | Task 3, Task 4 | flock folded into appenders |
| G-SUPER | One canonical "full retro" predicate; stub never gates/double-counts | constraint | Task 2 (def), Task 3/4/5 (consumers) | reviewer issue #8 resolved |
| G-DIST | Fix lands on user machines + Codex/Cursor builds (verified) | deliverable | Task 8 | install.sh block + build-script invariant; depends on Task 5 so the installed retro-stub is sweep-capable |

## Review Trail
- Plan reviewer: revision 1 -> ISSUES FOUND (8: append-runlog edit contention; run-marker scope; non-executable proofs; brief completeness/escape-hatch loudness; dependency ordering; file-limit assertions; missing real-path regression; incoherent supersession)
- Plan reviewer: revision 2 -> APPROVED (all 8 rev-1 issues verified resolved; no new FAILs; predicate single-sourced)
- Cross-model validation: revision 2 -> executed (2 providers). Findings dispositioned in revision 3:
  - **Task 8 → Task 5 dependency** (CRITICAL, both providers): installing after Task 3 only would ship a sweep-less `retro-stub`. FIXED — Task 8 now depends on Task 3 **and** Task 5.
  - **Task 7 verification theater** (CRITICAL): grep-only proof. FIXED — Task 7 acceptance proof is now a hermetic on-disk runtime check (marker created + swept) plus a failure-mode test (gate-refusal/SKIP/sweep-no-op stderr+exit).
  - **SC4b unowned** (WARNING, both): no task made `context-audit` consume the skip log. FIXED — new **Task 9** wires `skills/context-audit/SKILL.md` + test.
  - **flock without timeout** (WARNING): deadlock on stale lock. FIXED — Tasks 3/4 specify `flock -w` + stale-lock cleanup (mkdir-lock fallback also time-bounded).
  - **Risk concentration / integration last** (CRITICAL, both): dispositioned, NOT a missing-file/nonexistent-dependency CRITICAL per the fix policy's CRITICAL definition — it is a sequencing concern. Mitigated by fix B (Task 7 is now empirically verified, not grep-only) + the SMOKE2 gate that must pass before any install/commit; a true vertical-slice spike cannot precede Task 3 (the script it would exercise). Release-Gate disposition recorded in Notes. (This matches the documented adversarial CRITICAL-overload pattern: sequencing/risk-concentration findings resolved via Release-Gate + documented residual, not unbounded re-loop.)
  - **Task 1 no-deps but precedes Task 4 on same file** (WARNING): FIXED — Task 1 annotated "blocks Task 4"; Notes forbids parallel execution of append-runlog tasks; Task 3 retro-stub marked incremental-shim-until-Task-5.
  - INFO (Task 4/7 at 4-file boundary; Task 8 commit wording): Task 8 commit reworded to behavior-focused; 4-file tasks accepted (≤5 limit; splitting Task 4 would reintroduce the rev-1 edit-contention CRITICAL — contention-avoidance is the governing constraint, documented in Notes).
- Plan reviewer: revision 3 -> APPROVED (all 8 checks PASS; every cross-model finding verified genuinely resolved in task text; Task 9 dep correct = Task 4 only; Task 7 fencing coherent + stated in GREEN; marker-write-ungated / marker-clear-gated consistent by design; 9-task graph acyclic; no orphan rows/tasks; SMOKE2 covers operator failure modes)
- Cross-model validation: revision 2 executed (2 providers); all CRITICAL/WARNING findings fixed in rev3 and re-verified by plan-reviewer rev3. No further loop required.
- Status gate: Approved (reviewer converged rev3 + cross-model recorded + user approved interactive "go" 2026-05-18)

## Task Breakdown

### Task 1: ZUVO_HOME env override in append-runlog (testability foundation)
**Files:** `scripts/zuvo-home/append-runlog`, `tests/adversarial/test-retro-home-override.sh`
**Surface:** config · **Complexity:** complex · **Dependencies:** none · **Blocks:** Task 4 (sole subsequent `append-runlog` editor — strict linear, no parallel execution) · **Execution routing:** deep

- [ ] RED: `test-retro-home-override.sh` — `ZUVO_HOME="$ADV_TEST_HOME/zuvo-$$"`, pipe an exempt-skill 13-field run line, assert `$ZUVO_HOME/runs.log` gets it and real `$HOME/.zuvo/runs.log` mtime is unchanged. Fails today (paths hardcoded at `append-runlog:51-52`).
- [ ] GREEN: `ZUVO_HOME="${ZUVO_HOME:-$HOME/.zuvo}"` resolved once near top; replace every literal `$HOME/.zuvo` (RUNS_LOG, RETROS_LOG, verify-audit path, override branch) with `$ZUVO_HOME`. Preserve `CODEX_WORKSPACE→memory/` semantics when `ZUVO_HOME` unset. No behavior change when unset.
- [ ] Verify: `bash tests/adversarial/run.sh test-retro-home-override`
  Expected: test `PASS`; run.sh summary `0 failed`.
- [ ] Acceptance Proof:
  - G-TEST:
    - Surface: config
    - Proof:
      ```bash
      Z=$(mktemp -d); ZUVO_HOME="$Z" bash -c 'printf "%b\n" "2026-05-18T00:00:00Z\tbacklog\tdemo\t-\t-\tPASS\t-\t-\tx\tmain\tabc1234\t-\t-" | scripts/zuvo-home/append-runlog'; test -s "$Z/runs.log" && [ "$(grep -c . "$Z/runs.log")" -ge 1 ]
      ```
      (13 tab-separated fields; `backlog` is gate-exempt so no retro needed)
    - Expected: exit 0; `$Z/runs.log` non-empty; real `~/.zuvo` untouched
    - Artifact: `.zuvo/proofs/task-1-G-TEST.txt`
- [ ] Commit: `add ZUVO_HOME override to append-runlog so the retro gate is hermetically testable`

### Task 2: Canonical full-retro predicate + friction enum + stub schema
**Files:** `shared/includes/retrospective.md`, `tests/adversarial/test-retro-enum-contract.sh`
**Surface:** docs · **Complexity:** standard · **Dependencies:** none · **Execution routing:** default

- [ ] RED: `test-retro-enum-contract.sh` — assert `retrospective.md` (a) FRICTION_CATEGORY enum contains `abandoned`, `context-out`, `partial-recovery`; (b) has a "Canonical Full-Retro Predicate" subsection stating *full retro = `^RETRO:` AND field 5 ∉ {abandoned,context-out,partial-recovery}*; (c) has a "Checkpoint Stub Schema" subsection (17-field shape, `status`→friction map, `BLIND_AUDIT/ADVERSARIAL/CODESIFT=skipped`, `ROUTING_STATUS=N/A`, others `-`); (d) added line count ≤ 25 (`test $(($(wc -l < shared/includes/retrospective.md) - 259)) -le 25`). Fails today.
- [ ] GREEN: add the three enum values; add the two subsections, terse. The predicate text is the single source of truth Tasks 3/4/5 cite verbatim.
- [ ] Verify: `bash tests/adversarial/run.sh test-retro-enum-contract`
  Expected: all 4 sub-assertions `PASS`; `0 failed`.
- [ ] Acceptance Proof:
  - G-SUPER (definition):
    - Surface: docs
    - Proof:
      ```bash
      grep -q 'Canonical Full-Retro Predicate' shared/includes/retrospective.md && grep -q 'partial-recovery' shared/includes/retrospective.md && grep -q 'Checkpoint Stub Schema' shared/includes/retrospective.md && [ $(( $(wc -l < shared/includes/retrospective.md) - 259 )) -le 25 ]
      ```
    - Expected: exit 0
    - Artifact: `.zuvo/proofs/task-2-G-SUPER.txt`
- [ ] Commit: `define canonical full-retro predicate + checkpoint stub schema + extend friction enum`

### Task 3: retro-stub script — degraded emit, idempotent (full-retro predicate), flock
**Files:** `scripts/zuvo-home/retro-stub`, `tests/adversarial/test-retro-stub.sh`
**Surface:** backend-logic · **Complexity:** complex · **Dependencies:** Task 1, Task 2 · **Execution routing:** deep

- [ ] RED: `test-retro-stub.sh` (`ZUVO_HOME` set) — (a) `retro-stub --status=ABANDONED --friction=abandoned --skill=brainstorm --project=demo` appends exactly one 17-field `RETRO:` line (field 5 = `abandoned`) to `$ZUVO_HOME/retros.log` + a `<!-- RETRO -->` block to `$ZUVO_HOME/retros.md`; (b) `--status=BOGUS` exits non-zero, writes nothing; (c) idempotency: with a seeded **full** retro for `plan/demo` at HEAD SHA present, `retro-stub … --skill=plan --project=demo` is a no-op (line count unchanged); (d) concurrency: 10 parallel calls → 10 well-formed lines, `awk -F'\t' 'NF!=17'` count = 0.
- [ ] RED (add): (e) lock safety — a held lock on the retros.log lockfile does NOT hang `retro-stub` forever: with a stale lock held, the call returns non-zero within the bounded wait and writes nothing (assert wall-time < 2×timeout).
- [ ] GREEN: implement `scripts/zuvo-home/retro-stub`. Args `--status`(ABANDONED|PARTIAL|CONTEXT_OUT, `case`-validated), `--friction`, `--skill`, `--project`, `--sweep`(parse only; logic in Task 5). Resolve `ZUVO_HOME`, `SHA7`, ISO date. Emit 17-field TSV per Task 2 schema; append under **`flock -w 5 -x`** with a documented timeout; if `flock` is unavailable use a `mkdir`-atomic lockfile with the SAME bounded retry (≤5s) + stale-lock reclaim (lock dir mtime > 60s ⇒ steal). On lock-acquire failure: exit non-zero, write nothing, emit a one-line stderr `retro-stub: lock busy, skipped` (never block the pipeline). Mirror `retros.md` block + reuse `retrospective.md` rotation (header-preserving, PID+`%s%N` temp). Idempotency check uses **Task 2's canonical full-retro predicate** (`$1 ~ /^RETRO:/ && $2==skill && index(project) && $13==sha && $5 !~ /^(abandoned|context-out|partial-recovery)$/`) → if a full retro exists, exit 0 silently.
- [ ] Verify: `bash tests/adversarial/run.sh test-retro-stub`
  Expected: 4 sub-assertions `PASS`; `0 failed`.
- [ ] Acceptance Proof:
  - SC1:
    - Surface: backend-logic
    - Proof:
      ```bash
      Z=$(mktemp -d); ZUVO_HOME="$Z" scripts/zuvo-home/retro-stub --status=ABANDONED --friction=abandoned --skill=brainstorm --project=demo; awk -F'\t' 'END{exit !(NF==17)}' "$Z/retros.log" && grep -q 'abandoned' "$Z/retros.log"
      ```
    - Expected: exit 0; one valid 17-field stub
    - Artifact: `.zuvo/proofs/task-3-SC1.txt`
  - G-CONC:
    - Surface: backend-logic
    - Proof:
      ```bash
      Z=$(mktemp -d); for i in $(seq 1 10); do ZUVO_HOME="$Z" scripts/zuvo-home/retro-stub --status=ABANDONED --friction=abandoned --skill=s$i --project=p & done; wait; [ "$(awk -F'\t' 'NF!=17' "$Z/retros.log" | wc -l)" -eq 0 ] && [ "$(grep -c '^RETRO:' "$Z/retros.log")" -eq 10 ]
      ```
    - Expected: exit 0; 10 well-formed, 0 malformed
    - Artifact: `.zuvo/proofs/task-3-GCONC.txt`
  - G-SUPER (stub no-op when full exists):
    - Surface: backend-logic
    - Proof:
      ```bash
      Z=$(mktemp -d); S=$(git rev-parse --short HEAD); printf "%b\n" "RETRO: 2026-05-18T00:00:00Z\tplan\tdemo\tMIXED\tpipeline-heavy\t-\tnone\t0\t10\t2\t1\tmain\t$S\tclean:strict\tclean\tindexed\tok" >> "$Z/retros.log"; n0=$(grep -c '^RETRO:' "$Z/retros.log"); ZUVO_HOME="$Z" scripts/zuvo-home/retro-stub --status=ABANDONED --friction=abandoned --skill=plan --project=demo; [ "$(grep -c '^RETRO:' "$Z/retros.log")" -eq "$n0" ]
      ```
    - Expected: exit 0; no new line (idempotent against a full retro)
    - Artifact: `.zuvo/proofs/task-3-GSUPER.txt`
- [ ] Commit: `add retro-stub: flock-safe, idempotent (full-retro-predicate) degraded-retro emitter`

### Task 4: append-runlog — strong-signal match + flock + skip-log + marker-clear (ALL append-runlog edits, atomic)
**Files:** `scripts/zuvo-home/append-runlog`, `shared/includes/run-logger.md`, `tests/adversarial/test-strong-signal-match.sh`, `tests/adversarial/test-skip-gate-log.sh`
**Surface:** backend-logic · **Complexity:** complex · **Dependencies:** Task 1, Task 3 · **Execution routing:** deep
> This is the ONLY task besides Task 1 that edits `append-runlog`; all four append-runlog concerns land here in one atomic change to eliminate edit-contention.

- [ ] RED:
  - `test-strong-signal-match.sh` (`ZUVO_HOME` set): (a) **stale full reject** — retros.log has a `plan/demo` full retro at SHA `0ldldld` dated 30d ago; fresh `plan/demo` run at HEAD refused (exit 2, `RETRO_REQUIRED`); (b) **fresh full accept** — add a `plan/demo` full retro at HEAD SHA → same run line appends (exit 0); (c) **stub never satisfies** — only a `plan/demo` ABANDONED **stub** at HEAD SHA present → fresh completed `plan/demo` run still refused (exit 2) [enforces SC2 + G-SUPER]; (d) **loose override** — `ZUVO_MATCH_LOOSE=1` makes the stale full satisfy (exit 0); (e) **happy-path regression** — full retro + run line, same SHA → exit 0, `runs.log` gains line.
  - `test-skip-gate-log.sh`: with `ZUVO_SKIP_RETRO_GATE=1`, run line for `plan/demo` → (f) `$ZUVO_HOME/skip-retro-gate.log` has one `SKIP:`-prefixed TSV line `SKIP:\t<ISO>\t<skill>\t<project>\t<note>`; (g) WARN still prints and references `zuvo:context-audit`; (h) 105 skip writes → file = header + 100 (rotation, CQ6); (i) the documented `SKIP:` format is grep-parseable: `grep -c '^SKIP:' == 100`.
- [ ] RED (add): (j) lock-timeout — `append-runlog` with a stale lock held returns within the bounded wait (no indefinite block); the run line is NOT silently dropped (exit non-zero + stderr `append-runlog: lock busy`), so the caller can retry rather than lose the run.
- [ ] GREEN: in `append-runlog`: (1) rewrite match awk → consider only `$1 ~ /^RETRO:/`; require `$2==skill && index($0,project)` AND **full-retro predicate** `$5 !~ /^(abandoned|context-out|partial-recovery)$/` AND, unless `ZUVO_MATCH_LOOSE=1`, (`$13==HEAD_SHA7` OR field-1 ts `>= RUN_START` where RUN_START = incoming run line's DATE); resolve `HEAD_SHA7` once; keep exempt-skill + `ZUVO_SKIP_RETRO_GATE` branches ahead of the match. (2) wrap `runs.log` append in **`flock -w 5 -x`** (same `mkdir`-lock + 60s stale-reclaim fallback as Task 3); on lock-acquire failure exit non-zero with stderr `append-runlog: lock busy` (do NOT drop the run silently). (3) in the skip branch, after WARN (updated to cite `zuvo:context-audit`), append a `SKIP:` TSV line to `$ZUVO_HOME/skip-retro-gate.log` under the bounded lock with a `# v1 SKIP DATE SKILL PROJECT NOTE` header on first write + header-preserving last-100 rotation. (4) on a successful gated append, `rm -f` the matching `$ZUVO_HOME/run-markers/<skill>-<project>-*.marker` (clean completion ⇒ no orphan). Update `run-logger.md` §"Append via retro-gate wrapper" (≤12 lines): strict default, `ZUVO_MATCH_LOOSE`, stub-never-gates, `SKIP:` contract, lock-busy non-zero semantics.
- [ ] Verify: `bash tests/adversarial/run.sh test-strong-signal-match test-skip-gate-log`
  Expected: all 9 sub-assertions (a–i) `PASS`, including regression (e); `0 failed`.
- [ ] Acceptance Proof:
  - SC2 + G-SUPER:
    - Surface: backend-logic
    - Proof:
      ```bash
      Z=$(mktemp -d); RL="$Z/retros.log"; H=$(git rev-parse --short HEAD)
      printf "%b\n" "RETRO: 2026-04-18T00:00:00Z\tplan\tdemo\tMIXED\tabandoned\t-\tnone\t0\t1\t0\t0\tmain\t0ldldld\tskipped\tskipped\tskipped\tN/A" >> "$RL"
      RUN='2026-05-18T12:00:00Z\tplan\tdemo\t-\t-\tPASS\t3\t3-phase\tx\tmain\t'"$H"'\t-\tdefault'
      ZUVO_HOME="$Z" bash -c 'printf "%b\n" "'"$RUN"'" | scripts/zuvo-home/append-runlog'; rc=$?; [ "$rc" -eq 2 ]   # stale + stub-only ⇒ refused
      printf "%b\n" "RETRO: 2026-05-18T11:59:00Z\tplan\tdemo\tMIXED\tpipeline-heavy\t-\tnone\t0\t9\t2\t1\tmain\t$H\tclean:strict\tclean\tindexed\tok" >> "$RL"
      ZUVO_HOME="$Z" bash -c 'printf "%b\n" "'"$RUN"'" | scripts/zuvo-home/append-runlog'; [ $? -eq 0 ] && grep -q . "$Z/runs.log"
      ```
    - Expected: first call exit 2 (stale full + no fresh full); after a HEAD-SHA full retro added, exit 0 and `runs.log` written
    - Artifact: `.zuvo/proofs/task-4-SC2.txt`
  - SC4 + SC4b:
    - Surface: backend-logic
    - Proof:
      ```bash
      Z=$(mktemp -d); RUN='2026-05-18T12:00:00Z\tplan\tdemo\t-\t-\tPASS\t3\t3-phase\tx\tmain\tabc1234\t-\tdefault'
      ZUVO_HOME="$Z" ZUVO_SKIP_RETRO_GATE=1 bash -c 'printf "%b\n" "'"$RUN"'" | scripts/zuvo-home/append-runlog' >/dev/null
      grep -q '^SKIP:' "$Z/skip-retro-gate.log" && awk -F'\t' '/^SKIP:/{exit !(NF>=4)}' "$Z/skip-retro-gate.log"
      ```
    - Expected: exit 0; parseable `SKIP:` line with ≥4 fields (the contract `zuvo:context-audit` consumes)
    - Artifact: `.zuvo/proofs/task-4-SC4.txt`
  - SC5 (regression):
    - Surface: backend-logic
    - Proof: `test-strong-signal-match.sh` case (e) — full retro + run line at same SHA ⇒ `append-runlog` exit 0 and `$ZUVO_HOME/runs.log` gains the line
    - Expected: exit 0; line present
    - Artifact: `.zuvo/proofs/task-4-SC5.txt`
- [ ] Commit: `tighten append-runlog: full-retro-only strong-signal match, flock, visible skip-log, marker-clear`

### Task 5: retro-stub --sweep (passive next-boundary orphan capture)
**Files:** `scripts/zuvo-home/retro-stub`, `tests/adversarial/test-orphan-sweep.sh`
**Surface:** backend-logic · **Complexity:** complex · **Dependencies:** Task 3, Task 4 · **Execution routing:** deep
> In-scope justification: solution direction A = "checkpoint/passive retro stub on abandon"; QA proved skills can't self-report, so a defensive sweep is the *required* mechanism, not creep. Marker *write* is skill-side (Task 7); this task only *consumes* markers.

- [ ] RED: `test-orphan-sweep.sh` (`ZUVO_HOME` set) — (a) orphan: a `$ZUVO_HOME/run-markers/brainstorm-demo-<sha>.marker` (started 1h ago) with NO matching full retro → `retro-stub --sweep` emits exactly one `abandoned` stub for brainstorm/demo and removes the marker; (b) a marker WITH a matching fresh **full** retro (Task 2 predicate) → swept WITHOUT a stub (marker just cleared); (c) `--sweep` idempotent (second run no-op, no marker-dir → exit 0); (d) a marker older than 7 days with unparseable content is removed defensively, no stub.
- [ ] GREEN: implement `--sweep`. Marker contract: file `$ZUVO_HOME/run-markers/<skill>-<project>-<sha7>.marker` with `start_ts/skill/project/sha7/session_id`. For each marker: apply Task 2's full-retro predicate against `retros.log`; if no full retro → emit `--status=ABANDONED --friction=abandoned` stub (note `orphan-sweep:<skill>` in MISSING_TEMPLATE field, not friction — keeps friction enum-valid); always `rm` the marker under flock; defensively remove unparseable/>7d markers without emitting.
- [ ] Verify: `bash tests/adversarial/run.sh test-orphan-sweep`
  Expected: 4 sub-assertions `PASS`; `0 failed`.
- [ ] Acceptance Proof:
  - SC1 (abandoned path):
    - Surface: backend-logic
    - Proof:
      ```bash
      Z=$(mktemp -d); mkdir -p "$Z/run-markers"; printf 'start_ts=2026-05-18T10:00:00Z\nskill=brainstorm\nproject=demo\nsha7=abc1234\nsession_id=S1\n' > "$Z/run-markers/brainstorm-demo-abc1234.marker"; ZUVO_HOME="$Z" scripts/zuvo-home/retro-stub --sweep; grep -q 'abandoned' "$Z/retros.log" && [ -z "$(ls -A "$Z/run-markers")" ]
      ```
    - Expected: exit 0; one `abandoned` stub; marker dir empty
    - Artifact: `.zuvo/proofs/task-5-SC1.txt`
- [ ] Commit: `add retro-stub --sweep: capture orphaned/abandoned runs at the next boundary`

### Task 6: Session-state retro carry (one session → one retro)
**Files:** `shared/includes/session-state.md`, `tests/adversarial/test-session-retro-carry.sh`
**Surface:** docs · **Complexity:** standard · **Dependencies:** Task 3 · **Execution routing:** default

- [ ] RED: `test-session-retro-carry.sh` — assert `session-state.md` defines a `## Retro State` block for `.zuvo/context/execution-state.md` with `retro-session-id`, `last-retro-status`, `last-retro-friction`, and a READ-protocol resume rule: if resuming and `retro-session-id` matches the current session, finalize/upgrade the existing retro instead of writing a second (one execution-state session ⇒ exactly one eventual retro, stub OR full, never both). Assert added lines ≤ 20 (`test $(($(wc -l < shared/includes/session-state.md) - 323)) -le 20`). Assert a sim: stub for session S then full retro same `retro-session-id` ⇒ downstream dedup yields one (reuse Task 3 idempotency).
- [ ] GREEN: add the terse `## Retro State` block + resume rule to `session-state.md` WRITE and READ protocols; define `session_id` derivation (reuse execute's session id; else `sha7+start_ts`).
- [ ] Verify: `bash tests/adversarial/run.sh test-session-retro-carry`
  Expected: contract assertions `PASS`; `0 failed`.
- [ ] Acceptance Proof:
  - SC3:
    - Surface: docs
    - Proof:
      ```bash
      grep -q 'Retro State' shared/includes/session-state.md && grep -q 'retro-session-id' shared/includes/session-state.md && grep -qiE 'exactly one .*retro|one .*session.*one .*retro' shared/includes/session-state.md && [ $(( $(wc -l < shared/includes/session-state.md) - 323 )) -le 20 ]
      ```
    - Expected: exit 0
    - Artifact: `.zuvo/proofs/task-6-SC3.txt`
- [ ] Commit: `define session-state retro-carry so resumed multi-session runs finalize one coherent retro`

### Task 7: Wire run-marker + retro hooks into brainstorm/plan/execute
**Files:** `skills/brainstorm/SKILL.md`, `skills/plan/SKILL.md`, `skills/execute/SKILL.md`, `tests/adversarial/test-skill-retro-wiring.sh`
**Surface:** integration · **Complexity:** complex · **Dependencies:** Task 5, Task 6 · **Execution routing:** deep
> Hard deps justified: Task 5 defines the marker contract this task writes; Task 6 defines the Retro State block execute references. (Reviewer's "T7/T8 false dep" addressed: this is Task 7↔Task 5/6 which IS real; Task 8 below depends only on Task 3.)

- [ ] RED: `test-skill-retro-wiring.sh` — two layers, NOT grep-only (resolves cross-model "verification theater"):
  - **Structure (grep):** (a) each SKILL.md has a Phase 0 step writing the run-marker AND invoking `retro-stub --sweep` at start (standard `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/zuvo-home/retro-stub` fallback, matching the existing `adversarial-review` fallback idiom); (b) brainstorm has an explicit terminal retro step at spec `Approved`; plan at `Reviewed`/`Approved`; (c) execute's abandon/context-out path emits `--status=CONTEXT_OUT|PARTIAL` and resume references `session-state.md` Retro State; (d) zero `{plugin_root}`; include refs relative `../../`.
  - **Runtime (executes the injected snippet on disk):** (e) extract the exact Phase-0 marker-write+sweep bash block from each SKILL.md (delimited by a stable `# >>> zuvo:retro-marker` / `# <<< zuvo:retro-marker` fence the GREEN step adds), run it under `bash -n` (syntax) AND execute it with `ZUVO_HOME=$ADV_TEST_HOME/zuvo-$$` and a stubbed PROJECT/SKILL; assert a real `$ZUVO_HOME/run-markers/*.marker` file is created, then a follow-up `retro-stub --sweep` clears it and (no prior retro) leaves exactly one `abandoned` stub. A syntactically-broken or wrong-path snippet FAILS this. (f) failure-mode: with `append-runlog` forced to refuse (no full retro) the extracted block still exits cleanly (marker write must not be gated by the run gate), and a `--sweep` no-op on an empty marker dir exits 0 with no output.
- [ ] GREEN: edit the 3 SKILL.md minimally within each skill's existing phase vocabulary. The Phase-0 marker-write + `--sweep` block MUST be wrapped in the stable fence `# >>> zuvo:retro-marker` … `# <<< zuvo:retro-marker` so the test can extract+execute it. Add/relocate the terminal retro step for brainstorm (after `Approved`) and plan (after `Reviewed`); add abandon/context-out + resume hooks in execute referencing Retro State. The marker-write must be ungated (independent of `append-runlog`). Do not restructure unrelated phases.
- [ ] Verify: `bash tests/adversarial/run.sh test-skill-retro-wiring`
  Expected: structure (a–d) AND runtime (e–f) assertions `PASS`; `0 failed`.
- [ ] Acceptance Proof:
  - SC1 + SC3 (wiring, empirically verified on disk):
    - Surface: integration
    - Proof:
      ```bash
      Z=$(mktemp -d); fail=0
      for s in brainstorm plan execute; do
        grep -q 'retro-stub' skills/$s/SKILL.md || fail=1
        blk=$(awk '/# >>> zuvo:retro-marker/{f=1;next}/# <<< zuvo:retro-marker/{f=0}f' skills/$s/SKILL.md)
        [ -n "$blk" ] || { fail=1; continue; }
        bash -n <(printf '%s' "$blk") || fail=1
        ZUVO_HOME="$Z/$s" SKILL="$s" PROJECT="demo" bash -c "$blk" || fail=1
        ls "$Z/$s"/run-markers/*.marker >/dev/null 2>&1 || fail=1
      done
      grep -lq '{plugin_root}' skills/brainstorm/SKILL.md skills/plan/SKILL.md skills/execute/SKILL.md && fail=1
      exit $fail
      ```
    - Expected: exit 0 — every skill's fenced block is syntactically valid, runs, and creates a real marker on disk; no `{plugin_root}`
    - Artifact: `.zuvo/proofs/task-7-SC1.txt`
- [ ] Commit: `wire run-marker, --sweep, and terminal/abandon retro hooks into brainstorm/plan/execute`

### Task 8: Install + distribution wiring for retro-stub (verified, not assumed)
**Files:** `scripts/install.sh`, `tests/adversarial/test-install-retro-stub.sh`
**Surface:** config · **Complexity:** standard · **Dependencies:** Task 3, Task 5 · **Execution routing:** default
> Depends on Task 5 (not just Task 3): installing/distributing before `--sweep` lands would ship a sweep-incapable `retro-stub`, silently breaking SC1 in the field while G-DIST claims "verified" (cross-model CRITICAL, both providers).

- [ ] RED: `test-install-retro-stub.sh` — (a) `scripts/install.sh` ZUVO HOME block has a `retro-stub` cp+`chmod +x`+`ok`/`warn` clause mirroring the `append-runlog` clause (L234–240 pattern); (b) `scripts/zuvo-home/retro-stub` exists and is executable; (c) **build invariant** — assert `scripts/build-codex-skills.sh` and `scripts/build-cursor-skills.sh` copy `scripts/` (grep for the scripts-copy line) so `retro-stub` propagates to Codex/Cursor without a separate change (resolves reviewer's "verify don't assume"); (d) dry-run the ZUVO HOME block with `ZUVO_HOME=$(mktemp -d)` style and assert `retro-stub` lands executable.
- [ ] GREEN: add the `retro-stub` install clause after the `verify-audit` clause (~L256) using the identical guarded `if [[ -f "$ZUVO_DIR/scripts/zuvo-home/retro-stub" ]]` pattern; `chmod +x scripts/zuvo-home/retro-stub` in-repo; add a one-line comment in install.sh asserting the build-script copy invariant so future readers don't duplicate.
- [ ] Verify: `bash tests/adversarial/run.sh test-install-retro-stub`
  Expected: 4 sub-assertions `PASS`; `0 failed`.
- [ ] Acceptance Proof:
  - G-DIST:
    - Surface: config
    - Proof:
      ```bash
      grep -q 'zuvo-home/retro-stub' scripts/install.sh && test -x scripts/zuvo-home/retro-stub && grep -qE 'cp .*scripts|scripts/.*dist|rsync .*scripts' scripts/build-codex-skills.sh scripts/build-cursor-skills.sh
      ```
    - Expected: exit 0
    - Artifact: `.zuvo/proofs/task-8-GDIST.txt`
- [ ] Commit: `distribute a sweep-capable retro-stub: install.sh ZUVO HOME wiring + enforced build-copy invariant`

### Task 9: context-audit consumes the skip-retro-gate log (owns SC4b)
**Files:** `skills/context-audit/SKILL.md`, `tests/adversarial/test-context-audit-skip.sh`
**Surface:** integration · **Complexity:** standard · **Dependencies:** Task 4 · **Execution routing:** default
> Cross-model (both providers): SC4b was an unowned authority row — Task 4 only produces the parseable `SKIP:` contract; nothing made the audit consume it. This task makes the bypass actually surface.

- [ ] RED: `test-context-audit-skip.sh` — assert `skills/context-audit/SKILL.md` has a phase/step that reads `$ZUVO_HOME/skip-retro-gate.log` (honoring the same `ZUVO_HOME` default) and reports a count + last-N `SKIP:` entries (skill/project/date) in its output contract; assert it documents the `# v1 SKIP DATE SKILL PROJECT NOTE` schema it parses. Runtime: extract the audit's skip-parsing snippet (fenced `# >>> zuvo:skip-audit` … `# <<<`), feed a fixture skip-log with 3 `SKIP:` lines, assert the snippet emits a report line containing `3` and each project. Empty/missing log ⇒ "0 bypasses" not an error.
- [ ] GREEN: add a terse "Retro-gate bypass check" step to `skills/context-audit/SKILL.md` within its existing audit-phase vocabulary, fenced for extraction; parse the rotated `SKIP:` TSV; surface count + recent entries; degrade cleanly when the file is absent. Token-lean (≤18 added lines — context-audit SKILL.md is widely relevant).
- [ ] Verify: `bash tests/adversarial/run.sh test-context-audit-skip`
  Expected: structure + runtime assertions `PASS`; `0 failed`.
- [ ] Acceptance Proof:
  - SC4b:
    - Surface: integration
    - Proof:
      ```bash
      Z=$(mktemp -d); printf '# v1 SKIP DATE SKILL PROJECT NOTE\nSKIP:\t2026-05-18T01:00:00Z\tplan\tdemo\truns.log\nSKIP:\t2026-05-18T02:00:00Z\texecute\tacme\truns.log\nSKIP:\t2026-05-18T03:00:00Z\tbrainstorm\tacme\truns.log\n' > "$Z/skip-retro-gate.log"
      blk=$(awk '/# >>> zuvo:skip-audit/{f=1;next}/# <<< zuvo:skip-audit/{f=0}f' skills/context-audit/SKILL.md)
      [ -n "$blk" ] && out=$(ZUVO_HOME="$Z" bash -c "$blk") && echo "$out" | grep -q '3' && echo "$out" | grep -q 'acme'
      ```
    - Expected: exit 0; the audit snippet reports 3 bypasses and names the projects
    - Artifact: `.zuvo/proofs/task-9-SC4b.txt`
- [ ] Commit: `surface retro-gate bypasses in zuvo:context-audit by parsing skip-retro-gate.log`

## Whole-feature Smoke Proofs

Run by `zuvo:execute` at Phase Final after all per-task proofs, hermetic `ZUVO_HOME`.

- **SMOKE1 — canonical completed-run regression guard (SC5 + G-TEST)**
  - Preconditions: `ZUVO_HOME=$(mktemp -d)`; git repo at known HEAD; modified `scripts/zuvo-home/*`.
  - Proof: drive the *real* happy path against the modified scripts — write a full retro line (Task-2 schema, friction `pipeline-heavy`, SHA=HEAD) to `$ZUVO_HOME/retros.log`; pipe a matching 13-field `Run:` line to `append-runlog`; assert exit 0 and `$ZUVO_HOME/runs.log` gained it. Then repeat with a stale-only retro and assert exit 2.
  - Invariants: the canonical completed flow still gates and writes; a stale/stub-only state still refuses. (This is the hermetic equivalent of the reviewer's proposed real-`~/.zuvo` test — same coverage, zero pollution of live telemetry.)
  - Artifact: `.zuvo/proofs/smoke-regression.txt`
- **SMOKE2 — abandoned → swept → fresh round trip (SC1 + SC2 + G-CONC)**
  - Proof: write a brainstorm run-marker, no retro (simulated abandon); run `retro-stub --sweep` → exactly one `abandoned` stub; seed a 30-day-old stale `plan` full retro; attempt `append-runlog` for a fresh `plan` run → refused (exit 2); add a HEAD-SHA full `plan` retro → accepted (exit 0); 10 parallel `retro-stub` calls → 0 malformed lines.
  - Also assert operator-visible failure modes: gate-refusal exits 2 with `RETRO_REQUIRED` on stderr; `ZUVO_SKIP_RETRO_GATE=1` exits 0 with WARN + a `SKIP:` line; `--sweep` on an empty marker dir exits 0 silently; a lock held past the bounded wait yields non-zero `lock busy` (never an indefinite hang).
  - Invariants: every incomplete run leaves a trace; no stale/stub state satisfies a fresh run; concurrent writes never corrupt; degraded paths fail loud+bounded, never silently or forever.
  - Artifact: `.zuvo/proofs/smoke-roundtrip.txt`
- **SMOKE3 — full harness (G-TEST + no regression)**
  - Proof: `bash tests/adversarial/run.sh` (entire suite, old + new).
  - Expected: `0 failed`; pre-existing adversarial tests stay green.
  - Artifact: `.zuvo/proofs/smoke-full-suite.txt`

## Notes
- Pure markdown + shell; **never `npm install`**. Bash macOS+Linux portable; `flock -w 5` guarded with a `mkdir`-atomic lockfile fallback that is equally time-bounded (≤5s) with 60s stale-lock reclaim — locking never blocks the pipeline indefinitely.
- Standing rules: relative include paths only (`../../`), no `{plugin_root}`, commit messages end with the Co-Authored-By line, commit/push only on explicit user request.
- **Execution-ordering contract (cross-model rev-2 fix):** `append-runlog` is edited by **only** Task 1 then Task 4 (strict linear). Task 1 `Blocks: Task 4`. Tasks 5–9 never touch `append-runlog`. `scripts/zuvo-home/retro-stub` is created in Task 3 as an accepted **incremental shim** (`--sweep` parses but no-ops) and completed in Task 5; **Tasks 3 and 5 must not run in parallel and Task 8 (install/distribute) must not run before Task 5** or a sweep-incapable binary ships. Execute these in listed order; do not reorder/parallelize the `retro-stub`/`append-runlog` chains.
- **Cross-model risk-concentration disposition (Release Gate):** the "integration last / risk concentration" CRITICAL is a sequencing concern, not a missing-file/nonexistent-dependency CRITICAL. A true vertical-slice spike cannot precede Task 3 (the script it would exercise). Residual risk is gated, not ignored: Task 7's acceptance proof is now an empirical on-disk runtime check (not grep), and **SMOKE2 must pass before Task 8 (install/distribute) and before any commit/push** — so a fundamental marker/sweep/skill-phase mismatch is caught at the integration boundary, not in the field. This disposition follows the documented adversarial CRITICAL-overload pattern: sequencing findings resolved via Release-Gate + documented residual rather than unbounded re-loop.
- Execution never mutates real `~/.zuvo`: all tests/smokes use `ZUVO_HOME` temp dirs.
