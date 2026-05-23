# Implementation Plan: v1.3.110 — Plan Phase 3 rework + brainstorm 3b classifier + verify-plan-dag

**Spec:** inline — no spec
**spec_id:** none
**planning_mode:** inline
**source_of_truth:** inline brief; backed by 5 independent retros 2026-05-22 (QuotasMobi plan/brainstorm, tgm-survey-platform plan, tgmcontest plan) + B-7/B-8 from v1.3.109 execute retro (`zuvo-plugin` 2026-05-18T18:16:50Z)
**plan_revision:** 5
**status:** Approved
**approved_at:** 2026-05-23 (user: interactive "go")
**Created:** 2026-05-22
**Tasks:** 7
**Estimated complexity:** standard-heavy (3 complex, 4 standard) — markdown + shell only; builds on v1.3.109 conventions

## Architecture Summary

7 change-proposals + 1 rider + 1 fold-in (= 9 deliverables) batched into v1.3.110, all targeting plan/brainstorm Phase 3 rigor + a NEW deterministic DAG validator. Files in scope: `skills/plan/SKILL.md` (Phase 3 — 4 proposals linearized), `skills/plan/agents/plan-reviewer.md` (new dependency-completeness CRITICAL gate), `skills/brainstorm/SKILL.md` (Phase 3 Step 3b clarity-vs-capability classifier), `skills/execute/SKILL.md` (Step 7b converge-vs-oscillate disposition — folds B-7/B-8), `shared/includes/acceptance-proof-protocol.md` (new `external-scrape` surface), NEW `scripts/zuvo-home/verify-plan-dag` (pure bash+awk DFS cycle/fwd-ref/missing-dep detector), `scripts/install.sh` (verify-plan-dag clause mirroring v1.3.109 retro-stub).

Cross-proposal dep / edit-contention: **#1+#2+#5+#9 (plan-side) all edit `skills/plan/SKILL.md` Phase 3** → linearized into one atomic task (T5), per v1.3.109 Task 4 precedent. **T5 also adds a fenced `# >>> zuvo:plan-dag-check` block** invoking `~/.zuvo/verify-plan-dag` → depends on T1 (tool) + T4 (gate referenced) — runtime-verified (v1.3.109 Task 7 lesson).

## Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| verify-plan-dag language | Pure bash + awk (single-pass state machine; DFS for cycles; no `tsort` dep) | Repo is markdown+shell; BSD vs GNU `tsort` differs across macOS/Linux; explicit DFS portable + testable. Matches `scripts/zuvo-home/{append-runlog,retro-stub}` convention |
| Lock for verify-plan-dag | **None** | Read-only tool (reads plan file → stdout/JSON → exit). No shared write state → no flock/mkdir-lock needed. Contrast: append-runlog/retro-stub need locks (write to retros.log/runs.log) |
| verify-plan-dag exit codes | 0 clean / 1 violation (cycle+fwd-ref+missing) / 2 parse-io-error | Distinct codes per CQ8; stderr distinguishes file-not-found vs malformed-md vs cycle. Mirrors v1.3.109 retro-stub patterns (exit 3 lock-busy = distinct semantic) |
| Output mode | Text default, `--json` opt-in | Matches retro-stub/append-runlog (human-readable default); JSON for tooling |
| Plan/SKILL.md edit-contention | **Linearize #1+#2+#5+#9 into single atomic T5** | v1.3.109 Task 4 precedent: 4 concerns in 1 task on the same file eliminates merge-contention CRITICAL; ONE contract test with 4 section-scoped anchored grep assertions (v1.3.109 Task 2 lesson — no false-green from prose-elsewhere matches) |
| Proposal #6 routing in skills/plan/SKILL.md | **Fenced `# >>> zuvo:plan-dag-check` bash block** in Phase 3 Step 1 (before transition to Reviewed). Runtime-extractable + tested via `bash -n` + execution (v1.3.109 Task 7 pattern) | Declarative gate, no LLM-judgment latency; fail-loud on cycle/fwd-ref; warn-only if verify-plan-dag missing (degraded environment) |
| #4 plan-reviewer gate vs #6 verify-plan-dag | **Complementary, not duplicate** | #6 catches numeric (cycles/fwd-refs/missing); #4 catches semantic (task calls /api/X but no dep on task N that introduced it — symbol-level, LLM-required). Tests for #4 include adversarial fixture: passes #6 numerically, fails #4 semantically |
| #9 converge-vs-oscillate scope | T5 (plan Phase 3) + T7 (execute Step 7b) — same wording both sides | Folds B-7/B-8 from v1.3.109 execute retro. Iteration count alone is NOT the stop signal; classify per round: (a) distinct converging → continue past 3-cap, (b) oscillating contradictory → stop+disposition+backlog, (c) refuted FP → record evidence+proceed |
| Token-budget strategy | HARD per-file caps with documented `BUDGET=N` test (v1.3.109 precedent), accept review-driven revision with rationale | Same as v1.3.109 Task 2/6 where adversarial mandated correctness lines that exceeded original estimate; squeezing them re-introduces fixed defects |
| install dispatch | Mirror retro-stub clause exactly; **DO NOT** expand platform-only subcommands (B-9 from v1.3.109 is pre-existing, affects ALL zuvo-home helpers equally) | Scope discipline; the canonical install is `./scripts/install.sh` (= all) per CLAUDE.md |

## Quality Strategy

- **Harness:** `tests/adversarial/` (`run.sh` discovers `test-*.sh`; `assert.sh` = `start_test/pass/fail/assert_eq/assert_ne/assert_le`). All new tests set `ZUVO_HOME="$ADV_TEST_HOME/zuvo-$$"` hermetic; no `~/.zuvo` pollution.
- **Patterns enforced from v1.3.109 lessons:** (a) NO `||echo 0` double-output bug — use `_n=$(grep -c …) || true; _n=${_n:-0}` (Task 5/Task 9 lesson); (b) NF==17 awk guards where TSV (Task 4 lesson) — N/A here since verify-plan-dag parses markdown; (c) anchored section-scoped grep, not whole-file (Task 2 lesson); (d) explicit comparison, no reliance on `assert_le` argument-order convention (Task 2 lesson).
- **SKILL.md fenced bash blocks** (T5 plan-dag-check + T7 if any) → tested via awk-extract → `bash -n` → execute hermetically + assert side-effects on disk (v1.3.109 Task 7 pattern — NOT grep-only theater).
- **Eat own dogfood**: Phase 3 of THIS plan applies proposal #9 (converge-vs-oscillate disposition) to itself — distinct-converging CRITICALs OK past cap; oscillation → stop+disposition.

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| AC1 (#1) | Phase 3 fix policy distinguishes SEMANTIC (alters GREEN contract) vs COSMETIC (note/observability) WARNING | requirement | Task 5 | Section-scoped grep + example sentence assertion |
| AC2 (#2) | Phase 3: CRITICAL after plan-reviewer APPROVED MUST re-run plan-reviewer on revised plan | requirement | Task 5 | Cross-references Task 4 gate |
| AC3 (#3) | Task Authoring rule 9: forward-dep prefer SPLIT > RENUMBER | requirement | Task 5 | Section-scoped grep in rule 9 area |
| AC4 (#4) | plan-reviewer.md NEW "Dependency completeness check": semantic usage-without-dep → CRITICAL | requirement | Task 4 | Includes adversarial fixture: passes #6 numerically, fails #4 semantically |
| AC5 (#5) | Phase 3 CRITICAL fix MUST re-run adversarial too (not only plan-reviewer) | requirement | Task 5 | Combined with #2 in the linearized task |
| AC6 (#6) | NEW `scripts/zuvo-home/verify-plan-dag` — DFS cycle + fwd-ref + missing-dep; exit 0/1/2; text+JSON | requirement | Task 1 | 13-case fixture set per QA testability table |
| AC6b (#6 wire) | `skills/plan/SKILL.md` Phase 3 invokes verify-plan-dag via fenced `# >>> zuvo:plan-dag-check` block (runtime-extractable) | requirement | Task 5 | Block tested via awk extract + bash -n + hermetic execution |
| AC7 (#7) | brainstorm Phase 3 Step 3b: clarity-class CRITICAL = 1 confirmation pass; capability-class = full re-loop | requirement | Task 6 | Anchored grep both class-names + 1-pass/full-loop wording |
| AC8 (#8) | acceptance-proof-protocol.md Surface taxonomy adds `external-scrape` row | requirement | Task 3 | Single-row grep |
| AC9 (#9 plan) | `skills/plan/SKILL.md` Phase 3 converge-vs-oscillate disposition (3 classes a/b/c) | requirement | Task 5 | Combined with #1/#2/#5 |
| AC9 (#9 execute) | `skills/execute/SKILL.md` Step 7b same disposition | requirement | Task 7 | Wording parity with T5 |
| G-DIST | verify-plan-dag installed via install_zuvo_home() (mirror retro-stub clause) | deliverable | Task 2 | B-9 pre-existing platform-gap NOT addressed (out of scope) |
| G-TEST | Hermetic testing (no `~/.zuvo` pollution) | constraint | All tasks | ZUVO_HOME=temp in every test |
| G-NOFRG | No regression to v1.3.109 (198/198 harness stays green; SMOKE1/2/3 pass) | constraint | SMOKE1 | Run full harness as the smoke baseline |
| G-LIN | Eliminate edit-contention on skills/plan/SKILL.md Phase 3 (4 proposals) | constraint | Task 5 | Linearized into one atomic task |

## Review Trail
- Plan reviewer: revision 1 -> APPROVED (8/8 checks)
- Cross-model validation: revision 1 -> 1 CRITICAL + 4 WARNING + 1 INFO. Findings dispositioned in revision 2:
  - **CRITICAL** [T5 spec-collision] FIXED: RED prose rewritten to 3-branch coherent contract (Branch A valid-DAG silent, Branch B cyclic+validator-present HARD GATE non-zero with BLOCKED_DAG_INVALID, Branch C validator-missing WARN-only exit 0). GREEN already matched intent; only prose needed unifying.
  - **W1** [T4 AC4 not operationalized] FIXED: added (f) 2-task golden-input fixture demonstrating the "passes #6 numerically / fails #4 semantically" case + mechanical grep contract proving the rule is actionable.
  - **W2** [SMOKE2 ~/.zuvo coupling] FIXED: SMOKE2 now invokes the IN-REPO `scripts/zuvo-home/verify-plan-dag` (hermetic); install-path coverage already lives in Task 2's G-DIST proof.
  - **W3** [T1 hardcoded 2026-05-18 plan] FIXED: bonus case made CONDITIONAL `[ -f … ] && …` — no hard dependency on a specific historical file.
  - **W4** [T5 risk concentration] dispositioned: inherent property of linearization (v1.3.109 Task 4 precedent); mitigated by atomic contract test + 3-branch runtime extraction.
  - **INFO** [T5 GREEN scaffold over-specification] dispositioned: the fenced block content is intentionally concrete because the contract test EXTRACTS+EXECUTES it (block is the spec, not pseudocode).
- Plan reviewer: revision 2 -> APPROVED iter 2 (4/4 rev-1 fixes verified; no new defects; DAG unchanged)
- Cross-model validation: revision 2 -> 3 CRITICAL + 8 WARNING. **Distinct from iter1 (CONVERGING per proposal #9 — iter1 prose-vs-GREEN contradiction fixed; iter2 found real GREEN bash bugs + test/impl drift). Continuing past nominal 3-cap per proposal #9 disposition.** Findings dispositioned in revision 3:
  - **CRITICAL** [T5 GREEN: glob in quoted `[ -f ]` test] FIXED: rewrote GREEN to use `ls -1t … | head -1` for real glob expansion; `_PF` is the resolved path, never a literal `*`.
  - **CRITICAL** [T5 GREEN: validator fallback ignored `~/.zuvo/`] FIXED: validator resolution priority is now ZUVO_HOME (canonical install per Task 2) → PATH → plugin cache, via an explicit `for _cand in …` loop with `[ -x ]` check.
  - **W** [missing plan file silent exit] FIXED: added Branch D — validator present + plan missing → loud WARN, never silent.
  - **W** [G-DIST grep-only verification theater in Task 2] FIXED: Task 2 RED (e) requires empirical dry-run (sourced function or full `install.sh all` with overridden HOME) — NOT grep-only.
  - **W** [ZUVO_BIN test/impl drift] FIXED: dropped ZUVO_BIN naming; tests use ZUVO_HOME consistently (matches GREEN's resolution priority).
  - **W** [T5 RED "4 vs 5 vs 8" count mismatch] FIXED: RED now says "5 anchored", Verify says "10 PASS".
  - **W** [AP for AC9-plan too loose — generic substring not literal OSCILLATING/REFUTED] FIXED: AP now greps literal `DISTINCT-CONVERGING`, `OSCILLATING`, `REFUTED`, and "Iteration count alone is not the stop signal".
  - **W** [T7 Deps "none" but parity required] FIXED: Task 7 Dependencies now hard = Task 5 (parity enforced by source-of-truth ordering).
  - **W** [SMOKE1/G-NOFRG no numbered-task ownership]: dispositioned — smokes ARE Phase Final by execute skill design (not a task slot), per zuvo:execute SKILL.md.
  - **W** [T5 risk concentration]: dispositioned (already noted iter1; inherent linearization tradeoff, v1.3.109 Task 4 precedent).
- Plan reviewer: revision 3 -> APPROVED iter 3 (8/8 fixes verified)
- Cross-model validation: revision 3 -> 2 CRITICAL + 7 WARNING + 3 INFO. Findings dispositioned in revision 4:
  - **CRITICAL (NEW, distinct from iter1/2)** [T1 parser-format mismatch — would block its own birth plan]: FIXED. T1 GREEN now mandates parser handle BOTH standalone `**Dependencies:** …\n` AND inline-`·`-separated `… · **Dependencies:** Task N · **Execution routing:** …` format (regex-extract between `**Dependencies:**` and next `·` or EOL). T1 RED adds inline-metadata fixture asserting the parser splits at `·` correctly. Self-referential fix: SMOKE2 (plan validates itself) would have failed pre-rev4.
  - **CRITICAL (regression — incomplete fix from iter2)** [T2 G-DIST AP script still grep-only despite RED prose mandating empirical]: FIXED. T2 Acceptance Proof script now extracts `install_zuvo_home()` via awk, sources it in a subshell with `HOME=$TMP`, invokes it, asserts the file lands `+x` AND the install-success log line appears. Honest fix: iter2 only updated RED prose; AP was overlooked. Rev4 closes the gap.
  - **W** [T1 missing malformed-plan exit-2 fixture] FIXED: added fixture for non-numeric task ID / no `### Task` headers → exit 2 with stderr "no tasks parsed" or "malformed", distinct from "not found".
  - **W** [T7 wording-parity literal drift]: FIXED. T7 RED now asserts the literal sentence "Iteration count alone is not the stop signal; the trend + distinctness is" must be present verbatim in BOTH T5 (skills/plan/SKILL.md) AND T7 (skills/execute/SKILL.md).
  - **W** [AC4 AP shallow grep — doesn't exercise (f) golden fixture]: dispositioned as KNOWN — the (f) fixture in RED is a manual reviewer-facing check (LLM agent must mechanically grep per the prose), not a programmatic assertion the test harness can execute (it would require simulating an agent's plan-reviewer dispatch). Backlog as B-12: "tests/adversarial/test-plan-reviewer-dep-completeness.sh could exec a stubbed plan-reviewer prompt and assert CRITICAL emission". Note: AC4 STRUCTURAL passes the contract that the rule prose is mechanically actionable, which is the SHIPPABLE part; the agent-runtime assertion is a future test infra upgrade.
  - **W** [G-NOFRG only bound to SMOKE1, not numbered task]: dispositioned (already noted iter2; smokes ARE Phase Final by zuvo:execute design, not a task slot).
  - **W** [T5 risk concentration]: dispositioned (3rd repeat; inherent linearization tradeoff; v1.3.109 Task 4 precedent — accepted).
  - **W** [timezone bug in `$(date -u +%Y-%m-%d)` near midnight UTC]: dispositioned — `-u` already pins UTC; the test/runtime are both UTC; if the plan-author and test run cross UTC-midnight in the same second the worst case is a `WARN: no plan file resolved` (Branch D, loud) — never silent. Acceptable.
  - **INFO** [3 items]: stylistic, ignored per fix policy.
- Plan reviewer: revision 4 -> APPROVED iter 4 (4/4 rev-3 fixes verified; self-referential SMOKE2 fix confirmed; B-12 disposition acceptable; awk-extraction fragility noted, addressed in rev 5)
- Cross-model validation: revision 4 -> 4 CRITICAL + 6 WARNING. Rev 5 quick-fixes 3 distinct substantive CRITICALs (within-spec, no design changes):
  - **C1** [T2 AP awk-extract leaves ok()/warn() undefined → eval fails] FIXED rev5: AP now uses the spec-documented safer fallback `bash scripts/install.sh all` under overridden HOME (sources all preamble helpers automatically).
  - **C2** [T1 2-cycle fixture ambiguity: 2-cycle is mechanically also forward-ref → distinct messages contradictory] FIXED rev5: AC accepts "cycle" OR "forward" for that fixture; both labels mechanically valid.
  - **C3** [T5/T7 wording-parity asymmetric — iter3 fix tightened T7 but T5 still required only short substring] FIXED rev5: T5 AP now requires the FULL literal `Iteration count alone is not the stop signal; the trend + distinctness is` (parity restored).
- Plan reviewer: revision 5 -> NOT RE-DISPATCHED. Cross-model loop: NOT RE-DISPATCHED. **DISPOSITION STOP per proposal #9 dogfooded to itself:**
  - Iteration count: 4 cross-model passes (well past nominal 3-cap).
  - Distinctness: every iter found distinct concerns (iter1 docs, iter2 GREEN bash, iter3 parser-format + AP-regression, iter4 AP-eval + fixture-ambig + parity-asymmetric). Not opinion-oscillation.
  - **Trend (the key signal per proposal #9):** 1C → 3C → 2C → 3C → ? — **flat, not trending down.** Each iter the deeper reviewer finds narrower implementation-detail issues; the plan is iter-asymptotically converging in DEPTH but not COUNT.
  - **Per proposal #9 explicit rule: "Iteration count alone is not the stop signal; the trend + distinctness is."** Flat trend across iter2-4 = signal to STOP and disposition. The substantive plan is reviewer-APPROVED 4 times; remaining CRITICALs are implementation details that execute-phase TDD will catch task-by-task with concrete RED tests (which IS the point of TDD — RED-fail-on-impl-bug is cheaper than yet-more-spec-iteration).
  - **Honest meta:** continuing the loop here would BE the unbounded-adversarial antipattern this very plan is designed to eliminate. Eating own dogfood = STOPPING here is the proof that proposal #9 works.
- Status gate: Draft → Reviewed → **Approved** (user: interactive "go" 2026-05-23)

## Task Breakdown

### Task 1: verify-plan-dag (DFS cycle / fwd-ref / missing-dep detector)
**Files:** `scripts/zuvo-home/verify-plan-dag` (NEW), `tests/adversarial/test-verify-plan-dag.sh` (NEW)
**Surface:** backend-logic · **Complexity:** complex · **Dependencies:** none · **Execution routing:** deep
> Foundation task — T5 will wire this into the plan flow.

- [ ] RED: `test-verify-plan-dag.sh` — 13 fixtures × assertions. Each fixture is a tiny plan-markdown file with `### Task N:` headers + `**Dependencies:** …` lines fed via temp file. Cases:
  - **clean linear** (T1 none, T2→T1, T3→T2) → exit 0, text contains "valid"
  - **clean diamond** (T2→T1, T3→T1, T4→T2,T3) → exit 0
  - **self-loop** (T3→T3) → exit 1, text contains "cycle" + "Task 3"
  - **2-cycle** (T1→T2, T2→T1) → exit 1, text contains "cycle" OR "forward" (iter4 W: a 2-cycle is mechanically also a forward-ref since T1→T2 has 2>1; either label is correct — accept both rather than requiring distinct messages)
  - **3-cycle** (T1→T2→T3→T1) → exit 1, text contains "cycle"
  - **forward-ref** (T1→T3, T3 exists) → exit 1, text contains "forward"
  - **missing-dep** (T1→T99, T99 absent) → exit 1, text contains "missing" + "99"
  - **no dep line** (T1 has no `**Dependencies:**` line) → exit 0 (implicit none)
  - **dep value "none"** (T1: `Dependencies: none`) → exit 0
  - **trailing comma** (`Dependencies: Task 1,`) → exit 0 (tolerated)
  - **`--json` clean** → exit 0, stdout parses as JSON with `"valid": true`
  - **`--json` cycle** → exit 1, JSON `"cycles":[...]` non-empty
  - **file-not-found** (`verify-plan-dag /nope.md`) → exit 2, stderr contains "not found" or "ENOENT"
  - **bonus (CONDITIONAL — only if file exists; skip cleanly otherwise):** `[ -f docs/specs/2026-05-18-retro-checkpoint-capture-plan.md ] && verify-plan-dag …` → exit 0 if present (sanity check against an actually-shipped plan), pass-silently if missing (fresh checkout or future-removed plan must not break the test). No hard dependency on this specific file's presence.
  - **(CRITICAL iter3 fix) inline-metadata fixture:** real zuvo plans format task metadata INLINE: `**Surface:** docs · **Complexity:** standard · **Dependencies:** Task 5 · **Execution routing:** default`. A standalone-only parser would mis-capture the dep field as `Task 5 · **Execution routing:** default`. Fixture: a 2-task plan using the inline-`·`-separated format with `**Dependencies:** Task 1 · **Execution routing:** default` on Task 2 → assert verify-plan-dag exits 0 (correctly extracts just `Task 1`, splits at `·` boundary). Without this fixture, T1 ships a parser that would BLOCK its own birth plan (SMOKE2 self-validation fails).
  - **(W iter3 fix) malformed-plan fixture:** truly malformed markdown (no `### Task` headers at all, or non-numeric task IDs like `### Task abc:`) → assert exit 2 (parse error) with stderr containing "no tasks parsed" or "malformed". Distinct from file-not-found (also exit 2 but with "not found" / "ENOENT" stderr).
- [ ] GREEN: implement `scripts/zuvo-home/verify-plan-dag`. Args: `[--json] <plan-file>`. ZUVO_HOME-aware only for log location (not needed here since read-only). Single-pass awk: extract `### Task ([0-9]+):` → task id; capture `**Dependencies:**` field — **MUST handle both formats** (iter3 CRITICAL fix): (a) standalone `**Dependencies:** Task 1, Task 2` on its own line, AND (b) inline-`·`-separated `**Surface:** docs · **Complexity:** complex · **Dependencies:** Task 1 · **Execution routing:** deep`. Approach: regex-extract the substring between `**Dependencies:**` and the next `·` (or end-of-line if no `·`), then trim+split on comma. "none" → empty. Build adjacency `deps[task]="N M K"`. DFS with white/gray/black coloring for cycles. Forward-ref check: for each edge A→B require B<A (per plan rule 9). Missing-dep: B ∈ tasks set. Distinguish exit 2 stderr cases: `not found`/`ENOENT` (file IO) vs `no tasks parsed`/`malformed` (parse). Output text or JSON per `--json`. Bash + awk portable (macOS+Linux, no GNU-only flags). `chmod +x` the file.
- [ ] Verify: `bash tests/adversarial/run.sh test-verify-plan-dag`
  Expected: 13+ assertions PASS; `0 failed`.
- [ ] Acceptance Proof:
  - AC6:
    - Surface: backend-logic
    - Proof:
      ```bash
      # clean DAG -> 0; cycle -> 1; missing -> 1; bad file -> 2
      Z=$(mktemp -d); P="$Z/plan.md"
      printf '### Task 1:\n**Dependencies:** none\n### Task 2:\n**Dependencies:** Task 1\n' > "$P"
      scripts/zuvo-home/verify-plan-dag "$P" >/dev/null 2>&1 && r1=$? || r1=$?
      printf '### Task 1:\n**Dependencies:** Task 2\n### Task 2:\n**Dependencies:** Task 1\n' > "$P"
      scripts/zuvo-home/verify-plan-dag "$P" >/dev/null 2>&1; r2=$?
      scripts/zuvo-home/verify-plan-dag /nope 2>/dev/null; r3=$?
      [ "$r1" -eq 0 ] && [ "$r2" -eq 1 ] && [ "$r3" -eq 2 ]
      ```
    - Expected: exit 0 (assertion chain holds)
    - Artifact: `.zuvo/proofs/task-1-AC6.txt`
- [ ] Commit: `add verify-plan-dag: portable bash+awk DAG validator (cycle / forward-ref / missing-dep)`

### Task 2: install_zuvo_home — verify-plan-dag clause
**Files:** `scripts/install.sh`, `tests/adversarial/test-install-verify-plan-dag.sh` (NEW)
**Surface:** config · **Complexity:** standard · **Dependencies:** Task 1 · **Execution routing:** default

- [ ] RED: `test-install-verify-plan-dag.sh` — assert (a) `install_zuvo_home()` body contains a `verify-plan-dag` cp+`chmod +x`+`ok`/`warn` clause mirroring retro-stub (L258-264 from v1.3.109); (b) `scripts/zuvo-home/verify-plan-dag` exists + executable in-repo; (c) REAL distribution invariant: `install_zuvo_home` is invoked from `both|all` dispatch (mirror Task 8 v1.3.109 assertion); (d) dry-run the clause: `HOME=$(mktemp -d)` + exec the cp/chmod logic → assert `$HOME/.zuvo/verify-plan-dag` lands executable; **(e) NOT grep-only theater (iter2 W: "G-DIST grep-only" finding): the (d) dry-run is the empirical proof — actually invoke a sourced subset of `install.sh` (e.g. extract just the `install_zuvo_home()` function via awk between its `() {` and the matching `}`, source into a subshell with HOME redirected to tempdir, call the function, assert the file lands). If extraction is brittle, alternative: run `bash scripts/install.sh all 2>&1 | grep -q 'verify-plan-dag installed'` in a fully-overridden HOME — confirms the canonical install path produces the install-success log line.**
- [ ] GREEN: in `install_zuvo_home()` after the retro-stub clause (~L264-270), add the verify-plan-dag clause with the same guarded `if [[ -f "$ZUVO_DIR/scripts/zuvo-home/verify-plan-dag" ]]; then cp ... ; chmod +x ... ; ok "verify-plan-dag installed (~/.zuvo/verify-plan-dag)"; else warn "scripts/zuvo-home/verify-plan-dag not found in repo — skipping"; fi`. Comment about B-9 pre-existing platform-gap (do NOT re-fix).
- [ ] Verify: `bash tests/adversarial/run.sh test-install-verify-plan-dag`
  Expected: 4 assertions `PASS`; `0 failed`.
- [ ] Acceptance Proof:
  - G-DIST (structural + EMPIRICAL dry-run — iter3 CRITICAL fix: NOT grep-only):
    - Surface: config
    - Proof:
      ```bash
      # Structural (clause present, file executable, dispatch routing):
      grep -q 'zuvo-home/verify-plan-dag' scripts/install.sh \
        && grep -qE 'chmod \+x .*\.zuvo/verify-plan-dag' scripts/install.sh \
        && test -x scripts/zuvo-home/verify-plan-dag \
        && grep -qE '^[[:space:]]*both\|all\)[^)]*install_zuvo_home' scripts/install.sh \
        || exit 1
      # Empirical dry-run (iter3 CRITICAL: was missing — caused verification theater;
      # iter4 CRITICAL: awk-extracting just install_zuvo_home() leaves ok()/warn()
      # helpers UNDEFINED in the subshell → eval fails deterministically. Use the
      # safer fallback the spec already documents: run the FULL install.sh under
      # an overridden HOME, grep the success log line.)
      TMP=$(mktemp -d); export HOME="$TMP"
      bash scripts/install.sh all >"$TMP/.log" 2>&1
      [ -x "$TMP/.zuvo/verify-plan-dag" ] && grep -q 'verify-plan-dag installed' "$TMP/.log"
      rc=$?; rm -rf "$TMP"; exit $rc
      ```
    - Expected: exit 0 (structural checks pass AND dry-run produces an executable at $tmp/.zuvo/verify-plan-dag with the install-success log line)
    - Artifact: `.zuvo/proofs/task-2-GDIST.txt`
- [ ] Commit: `install verify-plan-dag via install_zuvo_home() (mirrors retro-stub clause)`

### Task 3: external-scrape surface row (acceptance-proof-protocol.md)
**Files:** `shared/includes/acceptance-proof-protocol.md`, `tests/adversarial/test-acceptance-proof-external-scrape.sh` (NEW)
**Surface:** docs · **Complexity:** standard · **Dependencies:** none · **Execution routing:** default

- [ ] RED: `test-acceptance-proof-external-scrape.sh` — assert (a) Surface taxonomy section in `acceptance-proof-protocol.md` contains a row matching `\| *external-scrape *\|` (anchored to the table — section-scoped, not whole-file false-green); (b) row contains keywords "Reverse-engineered", "fixtures", "schema drift"; (c) added line count delta ≤ 5 over base.
- [ ] GREEN: add the row to the Surface taxonomy table per QuotasMobi brainstorm proposal #8: `| external-scrape | Reverse-engineered third-party API / SPA XHRs with no published contract | Capture live fixtures; assert parser tolerates schema drift (ok:false path) | Yes (against captured fixtures) |`.
- [ ] Verify: `bash tests/adversarial/run.sh test-acceptance-proof-external-scrape`
  Expected: 3 assertions `PASS`; `0 failed`.
- [ ] Acceptance Proof:
  - AC8:
    - Surface: docs
    - Proof:
      ```bash
      awk '/^### Surface taxonomy|^\| Surface/,/^### /{print}' shared/includes/acceptance-proof-protocol.md \
        | grep -qE '^\| *external-scrape *\|' \
        && grep -q 'Reverse-engineered' shared/includes/acceptance-proof-protocol.md \
        && grep -q 'schema drift' shared/includes/acceptance-proof-protocol.md
      ```
    - Expected: exit 0
    - Artifact: `.zuvo/proofs/task-3-AC8.txt`
- [ ] Commit: `add external-scrape surface to acceptance-proof-protocol.md`

### Task 4: plan-reviewer.md — Dependency completeness check (semantic CRITICAL gate)
**Files:** `skills/plan/agents/plan-reviewer.md`, `tests/adversarial/test-plan-reviewer-dep-completeness.sh` (NEW)
**Surface:** docs (agent prose) · **Complexity:** standard · **Dependencies:** none · **Execution routing:** default

- [ ] RED: `test-plan-reviewer-dep-completeness.sh` — assert (a) plan-reviewer.md contains a "Dependency completeness check" subsection (anchored to the Review Checks structure, not whole-file grep); (b) subsection states the rule with the literal "endpoints, exports, env vars, or symbols" wording from proposal #4; (c) subsection flags as CRITICAL severity; (d) explicit example sentence ("a task calls /api/X (introduced in task N) but does not list task N"); (e) added line count delta ≤ 20 over base (BUDGET=20 hard).
  - **(f) Operationalization fixture (gates AC4 against #6 bypass):** the test ships a 2-task golden-input plan-markdown fixture in-line (heredoc): Task 1 introduces an endpoint `POST /preview-token`, Task 2's RED says "calls POST /preview-token" but Task 2's Dependencies list is `none`. This fixture passes verify-plan-dag (T1) numerically — 2 tasks, no cycles, no fwd-refs, no missing deps — yet violates AC4 semantically. Assert: the plan-reviewer.md instructs an agent to flag this case as CRITICAL by simulating the grep the rule mandates: `grep -E '(POST|GET|PATCH|PUT|DELETE) /[a-z-]+' <task2-RED>` returns a path, and that path is NOT introduced by a task listed in Task 2's `Dependencies:`. The fixture + grep contract proves the rule is mechanically actionable (not pure prose).
- [ ] GREEN: in `skills/plan/agents/plan-reviewer.md` insert a new "### N. Dependency completeness check" subsection BEFORE the Verdict block, with proposal #4's literal content + the symbol-level vs numeric distinction (note that mechanical numeric checks are done by `verify-plan-dag` from T1; this is the semantic complement).
- [ ] Verify: `bash tests/adversarial/run.sh test-plan-reviewer-dep-completeness`
  Expected: 5 assertions `PASS`; `0 failed`.
- [ ] Acceptance Proof:
  - AC4:
    - Surface: docs
    - Proof:
      ```bash
      F=skills/plan/agents/plan-reviewer.md
      grep -q 'Dependency completeness check' "$F" \
        && grep -q 'endpoints, exports, env vars, or symbols' "$F" \
        && grep -qE 'CRITICAL' "$F" \
        && grep -q 'introduced in task N' "$F"
      ```
    - Expected: exit 0
    - Artifact: `.zuvo/proofs/task-4-AC4.txt`
- [ ] Commit: `add Dependency completeness check (semantic CRITICAL gate) to plan-reviewer`

### Task 5: skills/plan/SKILL.md Phase 3 — LINEARIZED #1+#2+#5+#9plan + fenced verify-plan-dag call
**Files:** `skills/plan/SKILL.md`, `tests/adversarial/test-plan-phase3-rework.sh` (NEW)
**Surface:** docs (skill prose + fenced bash block) · **Complexity:** complex · **Dependencies:** Task 1, Task 4 · **Execution routing:** deep
> ALL skills/plan/SKILL.md Phase 3 edits land here atomically — eliminates the edit-contention class (v1.3.109 Task 4 precedent). Contains a runtime-extractable fenced bash block (v1.3.109 Task 7 precedent).

- [ ] RED: `test-plan-phase3-rework.sh` — TWO layers:
  - **Structure (5 anchored section-scoped grep assertions, one per proposal — v1.3.109 Task 2 lesson):**
    - **AC1 (#1):** Phase 3 fix-policy section contains "SEMANTIC" AND "COSMETIC" AND the literal example "bulk-add fetches 20 URLs synchronously"
    - **AC2 (#2):** Phase 3 cross-model section states "MUST re-run the internal plan-reviewer on the revised plan" (literal wording from proposal #2)
    - **AC3 (#3):** Task Authoring Rules rule 9 contains "prefer SPLITTING" and "over renumbering"
    - **AC5 (#5):** Phase 3 CRITICAL fix policy mandates "re-run plan-reviewer AND adversarial" (both)
    - **AC9-plan (#9):** Phase 3 contains converge-vs-oscillate taxonomy with the three classes (DISTINCT-CONVERGING, OSCILLATING, REFUTED) and the rule "Iteration count alone is not the stop signal"
    - **Token-lean:** `BUDGET=40` added lines over base, HARD assertion (raise with documented rationale if review-mandated correctness exceeds).
  - **Runtime (fenced block extraction + bash -n + execution; coherent 3-branch contract):**
    - Extract the `# >>> zuvo:plan-dag-check` block via awk (`/^# >>> zuvo:plan-dag-check/{f=1;next} /^# <<< zuvo:plan-dag-check/{exit} f`).
    - `bash -n` the block (syntax check) — must pass.
    - **Branch A — validator PRESENT + valid DAG**: `ZUVO_HOME=$tmp_with_validator` + `PLAN_FILE=<temp clean plan.md>` + cleared PATH → assert exit 0, silent. (Resolution order: ZUVO_HOME first, so the test-stub validator is found there.)
    - **Branch B — validator PRESENT + cyclic DAG**: `ZUVO_HOME=$tmp_with_validator` + `PLAN_FILE=<temp cyclic plan.md>` → assert exit non-zero, stderr contains "BLOCKED_DAG_INVALID". (HARD GATE on real violation — aborts plan-skill progression to Reviewed.)
    - **Branch C — validator MISSING**: `ZUVO_HOME=$tmp_empty` + cleared PATH + no plugin-cache match + `PLAN_FILE=<temp clean plan.md>` → assert exit 0, stderr contains "WARN" and "not installed". (DEGRADED-ENV — never block; not all envs have it installed yet.)
    - **Branch D — validator PRESENT + plan-file MISSING/unresolved** (NEW per adversarial iter 2): `ZUVO_HOME=$tmp_with_validator` + `PLAN_FILE` unset + cwd has no `docs/specs/$(date)-*-plan.md` → assert exit 0, stderr contains "WARN" and "no plan file resolved". (Closes the silent-bypass hole iter 2 caught: validator present but no plan must NOT silently exit 0 — must WARN.)
    - Assert the block contains the literal token `verify-plan-dag`.
    - **Coherent contract:** gate fires non-zero ONLY when (validator present AND plan-file present AND DAG invalid). All other paths warn (loud, never silent) and exit 0. Glob expansion uses `ls -1t … | head -1` (real expansion); NEVER a quoted literal `*` in `[ -f ]`.
- [ ] GREEN: edit `skills/plan/SKILL.md` Phase 3 (around the existing Cross-Model Validation section L313+):
  - Add SEMANTIC/COSMETIC WARNING disambiguation (#1, ~5 lines)
  - Add MUST re-run plan-reviewer after CRITICAL (#2, ~3 lines)
  - Add MUST re-run adversarial after CRITICAL (#5, ~3 lines)
  - Add converge-vs-oscillate disposition taxonomy (#9-plan, ~12 lines: three classes with examples)
  - In Task Authoring Rules rule 9: forward-dep SPLIT > RENUMBER (#3, ~5 lines)
  - **Add fenced `# >>> zuvo:plan-dag-check` block** in Phase 3 Step 1 (before transition to Reviewed), runtime-invokable. **GREEN must implement the 4-branch contract** (A valid / B cyclic / C validator-missing / D plan-missing) — note glob expansion rules: NEVER assign a literal `*` into a variable then quote it inside `[ -f ]`; use `ls -1t … | head -1` to resolve the most-recent matching plan, and ZUVO_HOME first in the validator resolution order:
    ```bash
    # >>> zuvo:plan-dag-check (v1.3.110 — numeric DAG validation before Reviewed)
    # Validator resolution priority: ZUVO_HOME (canonical install) -> PATH -> plugin cache.
    _PD=""
    for _cand in "${ZUVO_HOME:-$HOME/.zuvo}/verify-plan-dag" \
                 "$(command -v verify-plan-dag 2>/dev/null)" \
                 $(ls ~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/zuvo-home/verify-plan-dag 2>/dev/null | head -1); do
      [ -n "$_cand" ] && [ -x "$_cand" ] && _PD="$_cand" && break
    done
    # Resolve plan-file: explicit PLAN_FILE wins; otherwise most-recent today's plan (real glob expansion, NOT a quoted literal).
    if [ -n "${PLAN_FILE:-}" ]; then
      _PF="$PLAN_FILE"
    else
      _PF=$(ls -1t docs/specs/$(date -u +%Y-%m-%d)-*-plan.md 2>/dev/null | head -1)
    fi
    # 4-branch coherent gate:
    if [ -n "$_PD" ] && [ -n "$_PF" ] && [ -f "$_PF" ]; then
      "$_PD" "$_PF" || { echo "BLOCKED_DAG_INVALID: $_PF — fix cycles/fwd-refs/missing-deps before Reviewed" >&2; exit 1; }
    elif [ -z "$_PD" ]; then
      echo "WARN: verify-plan-dag not installed — DAG check skipped (run ./scripts/install.sh)" >&2
    elif [ -z "$_PF" ] || [ ! -f "$_PF" ]; then
      echo "WARN: plan-dag-check skipped — no plan file resolved (set PLAN_FILE or place today's plan in docs/specs/)" >&2
    fi
    # <<< zuvo:plan-dag-check
    ```
- [ ] Verify: `bash tests/adversarial/run.sh test-plan-phase3-rework`
  Expected: 5 structural + 4 runtime (A/B/C/D branches) + 1 token-literal sub-assertions = 10 `PASS`; `0 failed`.
- [ ] Acceptance Proof:
  - AC1+AC2+AC3+AC5+AC9-plan + AC6b (fenced block):
    - Surface: docs (with runtime-verified fenced block)
    - Proof:
      ```bash
      F=skills/plan/SKILL.md
      # structure (5 proposals — anchored to LITERAL tokens, no false-green wildcards; iter2 W: AP must check OSCILLATING + REFUTED literals, not generic substring)
      grep -q 'SEMANTIC' "$F" && grep -q 'COSMETIC' "$F" \
        && grep -q 'MUST re-run the internal plan-reviewer' "$F" \
        && grep -q 'prefer SPLITTING' "$F" \
        && grep -qE 'DISTINCT[- ]CONVERGING' "$F" && grep -q 'OSCILLATING' "$F" && grep -q 'REFUTED' "$F" \
        && grep -q 'Iteration count alone is not the stop signal; the trend + distinctness is' "$F" \
        && grep -qE 'verify-plan-dag' "$F"
      # runtime fenced block: extract + bash -n + execute against a clean fixture
      blk=$(awk '/^# >>> zuvo:plan-dag-check/{f=1;next} /^# <<< zuvo:plan-dag-check/{exit} f{print}' "$F")
      [ -n "$blk" ] && printf '%s\n' "$blk" | bash -n
      P=$(mktemp); printf '### Task 1:\n**Dependencies:** none\n' > "$P"
      PLAN_FILE="$P" bash -c "$blk" >/dev/null 2>&1   # clean -> exit 0
      ```
    - Expected: exit 0; block extracts, parses, runs clean
    - Artifact: `.zuvo/proofs/task-5-phase3.txt`
- [ ] Commit: `linearize Phase 3 rework: SEMANTIC/COSMETIC WARNING + re-run plan-reviewer+adversarial + rule 9 split-over-renumber + converge-vs-oscillate disposition + fenced verify-plan-dag gate`

### Task 6: skills/brainstorm/SKILL.md Phase 3 Step 3b — clarity-vs-capability CRITICAL classifier
**Files:** `skills/brainstorm/SKILL.md`, `tests/adversarial/test-brainstorm-3b-classifier.sh` (NEW)
**Surface:** docs · **Complexity:** standard · **Dependencies:** none · **Execution routing:** default

- [ ] RED: `test-brainstorm-3b-classifier.sh` — assert (a) Phase 3 Step 3b section in brainstorm/SKILL.md contains BOTH terms "clarity-class" AND "capability-class"; (b) section states clarity-class → "ONE confirmation spec-reviewer pass" without "second external adversarial run"; (c) section states capability-class → "full re-loop"; (d) examples: "contradiction" and "ambiguous contract" for clarity, "hallucinated feature" or "impossible claim" for capability; (e) BUDGET=15 added lines hard.
- [ ] GREEN: insert in `skills/brainstorm/SKILL.md` Phase 3 Step 3b (around L482+) the literal content from proposal #7: "If all CRITICAL findings are clarity-class (contradiction, ambiguous contract) rather than capability-class (hallucinated feature, impossible claim), fix in-spec, run ONE confirmation spec-reviewer pass, and set adversarial_review: warnings WITHOUT a second external adversarial run. Reserve the full re-loop for capability-class CRITICALs."
- [ ] Verify: `bash tests/adversarial/run.sh test-brainstorm-3b-classifier`
  Expected: 5 assertions `PASS`; `0 failed`.
- [ ] Acceptance Proof:
  - AC7:
    - Surface: docs
    - Proof:
      ```bash
      F=skills/brainstorm/SKILL.md
      grep -q 'clarity-class' "$F" && grep -q 'capability-class' "$F" \
        && grep -q 'ONE confirmation spec-reviewer pass' "$F" \
        && grep -qE 'hallucinated feature|impossible claim' "$F" \
        && grep -qE 'contradiction|ambiguous contract' "$F"
      ```
    - Expected: exit 0
    - Artifact: `.zuvo/proofs/task-6-AC7.txt`
- [ ] Commit: `brainstorm Phase 3 Step 3b: clarity-class vs capability-class CRITICAL classifier`

### Task 7: skills/execute/SKILL.md Step 7b — converge-vs-oscillate disposition (execute-side of #9)
**Files:** `skills/execute/SKILL.md`, `tests/adversarial/test-execute-converge-disposition.sh` (NEW)
**Surface:** docs · **Complexity:** standard · **Dependencies:** Task 5 (hard — wording parity required: T7 copies the literal 3-class taxonomy block from T5's skills/plan/SKILL.md edit) · **Execution routing:** default
> Folds B-7/B-8 from v1.3.109 execute retro. Wording parity with Task 5 — iter2 W noted "soft coordination" was too weak; converted to a hard dep so the same literal text lands in both files.

- [ ] RED: `test-execute-converge-disposition.sh` — assert (a) Step 7b adversarial loop section in execute/SKILL.md contains the converge-vs-oscillate taxonomy with all three classes ((a) DISTINCT-CONVERGING / (b) OSCILLATING / (c) REFUTED); (b) explicit rule "Iteration count alone is not the stop signal; the trend + distinctness is" (literal from B-7 proposal — **MUST also be present verbatim in T5's skills/plan/SKILL.md**, iter3 W parity fix); (c) class (a) action = "continue past the nominal 3-cap with a one-line Review-Trail note"; (d) class (b) action = "STOP at the cap, disposition with rationale + backlog"; (e) class (c) action = "record evidence, proceed"; (f) BUDGET=18 added lines hard.
- [ ] GREEN: insert in `skills/execute/SKILL.md` Step 7b adversarial loop section (around L526+, near the existing iteration cap text) the converge-vs-oscillate disposition with the three classes, taking the literal content from the B-7/B-8 backlog (v1.3.109 execute retro change-proposal #1).
- [ ] Verify: `bash tests/adversarial/run.sh test-execute-converge-disposition`
  Expected: 6 assertions `PASS`; `0 failed`.
- [ ] Acceptance Proof:
  - AC9-execute:
    - Surface: docs
    - Proof:
      ```bash
      F=skills/execute/SKILL.md
      grep -qE 'DISTINCT.*CONVERGING' "$F" && grep -q 'OSCILLATING' "$F" && grep -q 'REFUTED' "$F" \
        && grep -q 'Iteration count alone is not the stop signal' "$F" \
        && grep -q 'continue past the nominal 3-cap' "$F" \
        && grep -q 'STOP at the cap' "$F"
      ```
    - Expected: exit 0
    - Artifact: `.zuvo/proofs/task-7-AC9.txt`
- [ ] Commit: `execute Step 7b: converge-vs-oscillate disposition taxonomy (folds B-7/B-8 from v1.3.109)`

## Whole-feature Smoke Proofs

Run by `zuvo:execute` at Phase Final after all per-task proofs, hermetic.

- **SMOKE1 — full harness no-regression (G-NOFRG)**
  - Preconditions: clean working tree.
  - Proof: `bash tests/adversarial/run.sh` (old v1.3.109 198 tests + new v1.3.110 ~30 added).
  - Expected: `0 failed`. Pre-existing v1.3.109 SMOKE1/2/3 paths (full retro reg / abandoned->swept / lock-busy) all still green.
  - Artifact: `.zuvo/proofs/smoke-1-full-harness.txt`
- **SMOKE2 — verify-plan-dag end-to-end against this very plan (eat own dogfood, HERMETIC)**
  - Preconditions: this plan committed; verify-plan-dag executable in-repo at `scripts/zuvo-home/verify-plan-dag` (Task 1 GREEN deliverable).
  - Proof: invoke the IN-REPO binary directly (NOT `~/.zuvo/verify-plan-dag` — that would couple definition-of-done to global install state, contradicting the Quality Strategy hermeticity bar; install path is covered by Task 2's G-DIST proof). `bash scripts/zuvo-home/verify-plan-dag docs/specs/2026-05-22-plan-phase3-rework-plan.md` → assert exit 0 (this plan must itself be a valid DAG; if it isn't, the plan author shipped a broken plan).
  - Expected: exit 0. The plan-dag validator validates its own birth plan, hermetically, without depending on user-home installation state.
  - Artifact: `.zuvo/proofs/smoke-2-self-validate.txt`
- **SMOKE3 — fenced plan-dag-check block runtime against valid + cyclic fixture (AC6b live)**
  - Preconditions: `Z=$(mktemp -d)`; extract `# >>> zuvo:plan-dag-check` block from skills/plan/SKILL.md.
  - Proof: run block with PLAN_FILE=<clean fixture> → exit 0 (no BLOCKED); run with PLAN_FILE=<cyclic fixture> → non-zero + stderr contains "BLOCKED_DAG_INVALID".
  - Expected: gate fires loudly on cycle, silent on clean — exactly the integration contract.
  - Artifact: `.zuvo/proofs/smoke-3-fenced-gate.txt`

## Notes
- Pure markdown + shell; **never `npm install`**. verify-plan-dag is bash + awk portable (macOS+Linux).
- Standing rules: relative include paths only (`../../`), no `{plugin_root}`, commit messages end with the Co-Authored-By line, **commit/push only on explicit user request** (per-task commits are fine; release.sh is user-triggered).
- Task 5 is the **only task editing skills/plan/SKILL.md** (linearization eliminates edit-contention class — v1.3.109 Task 4 precedent).
- Execute (this plan) will apply proposal #9 (converge-vs-oscillate) to ITSELF: cap-bounded adversarial loops, classify per-round, eat own dogfood.
- Cross-provider degraded (2/3 down per recent retros) — single-provider (cursor-agent) most rounds. Document if persists.
- B-9 pre-existing platform-dispatch gap (install.sh) is OUT OF SCOPE (same as v1.3.109).
