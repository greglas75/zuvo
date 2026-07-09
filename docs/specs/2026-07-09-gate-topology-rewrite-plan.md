# Implementation Plan: Topology-Complete Pipeline-Gate Range Computation

**Spec:** inline — no spec
**spec_id:** none
**planning_mode:** inline
**source_of_truth:** inline brief (user: "topology-complete rewrite so the gate stops mis-scoping merge/develop/multi-merge branches")
**plan_revision:** 2
**status:** Approved
**Created:** 2026-07-09
**Tasks:** 5 (Task 1 is the feasibility spike; Task 5 authors the smoke runner)
**Estimated complexity:** standard mix (all changes localized to hooks/lib/pipeline-gate-lib.sh + tests); 1 complex (the semantics spike)

## Problem (why this rewrite)

The pipeline-gate decides "which production files does this push introduce, and are they reviewed?"
by computing a RANGE `base..HEAD` and running `git diff base..HEAD`. Finding the right `base` is
git-topology-dependent, and every history shape needs it computed differently:

| Shape | Correct base | History of breakage |
|-------|--------------|---------------------|
| linear branch | fork-point | ok |
| branch off far-ahead `develop` | remote tip | v1.6.1 fix (`--not --remotes`) |
| deleted files | n/a | v1.6.1 fix (`rev-parse --verify`) |
| branch that MERGED main in | newest remote ancestor | v1.6.3 fix (this week) |
| MULTI-merge (two remote branches) | no single base exists | still over-scopes → backlog B-gate-multimerge |

This is whack-a-mole: each shape is a new base-computation edge case (3 shipped fixes + 1 open).
The current `pg_unpushed_range` also loops `git merge-base` over up to 100 remote refs (O(N) push latency).

## The fix (topology-agnostic, base-free)

Ask git directly for the files the UN-PUSHED commits introduce — one command, no base:

```
git log --format= --name-only -c <tip> --not --remotes
```

- `--not --remotes` — exclude everything already on ANY remote (already pushed ⇒ already gated). This
  automatically drops develop-ahead deltas, merged-in main, and every other merged remote branch —
  for ALL topologies, without a base.
- `--name-only` — list changed paths (includes deletions).
- `-c` — for a merge commit, show ONLY files that differ from ALL parents (the conflict resolutions),
  never the merged-in content. Clean merges contribute nothing.

This closes linear / develop-ahead / single-merge / MULTI-merge / octopus in one mechanism, captures
conflict-resolution changes, and removes the O(N) merge-base loop entirely.

## Architecture Summary

Integration via a **sentinel range**, so callers and the two consuming functions stay untouched:

- `pg_unpushed_range` returns `@unpushed..<tip>` (was `<newest-remote-ancestor>..<tip>`). The `..<tip>`
  suffix keeps `head=${range##*..}` working everywhere; the `@unpushed` base is the marker.
- `pg_changed_production` / `pg_changed_lines`: when `base == @unpushed`, compute from
  `git log --format= --name-only -c "$tip" --not --remotes` (and `--numstat` for lines) instead of
  `git diff`. Any other base → unchanged `git diff` path (the native `rsha..lsha` range is untouched).
- `pg_range_reviewed`, `pg_is_substantial`, and all four callers (gate_native new-branch, gate_legacy,
  stop-hook, adversarial-gate) are **unchanged** — they pass the sentinel through exactly like a range.
- The `pg_mergebase_range` fallback (remote-less repos, exit 1) stays: `--not --remotes` on a repo with
  NO remotes would select the whole history, so remote-less repos keep the merge-base diff.

Dependency direction: `pg_unpushed_range` (producer) → sentinel string → `pg_changed_*` (consumers).
The `best`/merge-base loop and its comment block are DELETED (net negative LOC in the producer).

## Technical Decisions

- **Sentinel `@unpushed`** over new parallel functions: minimal churn (3 functions, 0 callers changed),
  and `@unpushed..<tip>` reuses the existing `A..B` head-parsing. `@` prefix cannot collide with a real
  git ref (refs cannot start with `@` as a full name here; and a real base is always a hex sha).
- **`git log --format= --name-only -c … --not --remotes`** is the single primitive. `-c` (combined) is
  what excludes merged-in content while keeping conflict resolutions — verified in Task 1 before use.
- **`--not --remotes` guard:** only emit the sentinel when `for-each-ref refs/remotes` is non-empty AND
  `rev-list <tip> --not --remotes` is non-empty; else exit 1 (no remotes → merge-base fallback) / exit 3
  (nothing un-pushed → nothing to gate). Same exit contract as today, so callers are unaffected.
- **Lines (`pg_changed_lines`) for the sentinel:** `git log --format= --numstat -c "$tip" --not --remotes`
  summed over production paths — mirrors the file computation so the substantiality line-threshold matches.
- **No behavior change to the native pre-push path** (`rsha..lsha` from git stdin): that is already the
  exact pushed range; it keeps `git diff`.

## Quality Strategy

- **Spike first (Task 1):** the whole rewrite rests on `git log -c --not --remotes` semantics. Prove it
  across every topology (linear, develop-ahead, single-merge, multi-merge, octopus, deletions,
  conflict-resolution, no-remotes) in a throwaway-repo harness BEFORE editing the lib. A failed spike
  reshapes the plan cheaply.
- **Hermetic fixtures:** every test repo exports `GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  GIT_CONFIG_NOSYSTEM=1` — a fixture `git push` is otherwise intercepted by THIS machine's real global
  zuvo pre-push gate and blocked, corrupting the fixture (learned 2026-07-07).
- **Regression parity:** the existing R-DEL / R-UNPUSHED / R-MERGE assertions in
  `tests/hooks/test-pipeline-gate-lib.sh` must stay green under the new mechanism (proves no regression),
  plus NEW R-MULTIMERGE / R-CONFLICT assertions (proves the class is closed). pre-push / stop / adversarial
  gate suites must stay green (proves callers unaffected).
- **CQ watch:** shell (POSIX sh); fail-OPEN contract preserved (any git failure → allow, never brick a
  push); no regex/glob injection on paths; `--format=` (empty) to avoid commit-subject noise in output.

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| G1 | Merge-based branch scopes to feature-only (the reported bug) | goal | Task 3, Task 4 | R-MERGE stays green |
| G2 | Multi-merge / octopus no longer over-scopes (closes B-gate-multimerge) | goal | Task 3, Task 4 | R-MULTIMERGE new |
| G3 | Conflict-resolution changes ARE flagged (no under-scope hole) | constraint | Task 1, Task 4 | R-CONFLICT new |
| G4 | Develop-ahead + linear + deletions unchanged (no regression) | constraint | Task 4 | R-UNPUSHED/R-DEL green |
| G5 | O(N) remote-ref loop removed (push-latency) | goal | Task 3 | no merge-base loop in producer |
| G6 | Remote-less repos keep merge-base fallback (no whole-history flag) | constraint | Task 3, Task 4 | exit-1 path |
| G7 | Native `rsha..lsha` pre-push path unchanged | constraint | Task 2 | git diff retained |
| G8 | Fail-OPEN preserved (git failure → allow) | constraint | Task 2, Task 3 | 2>/dev/null + guards |

## Review Trail
- Phase 1: direct (small/light scope — inline, ≤5 tasks, no new public contract, orchestrator holds deep
  session context on this exact lib; CodeSift MCP disconnected so an Explore fan-out would be strictly
  degraded Read/Grep and API-unstable). plan-reviewer + cross-model still run.
- Plan reviewer: revision 1 → self-review (Explore fan-out blocked: CodeSift MCP disconnected → a
  degraded Read/Grep review; protocol fallback = orchestrator self-review). Traced the `@unpushed`
  sentinel through pg_range_reviewed (head=${range##*..}=HEAD ✓; per-file blob uses head ✓; artifact
  staleness check keys on the ARTIFACT range, not the sentinel ✓) and pg_is_substantial (delegates to
  pg_changed_*, both sentinel-aware ✓). Under-scope check: `--not --remotes` excludes only commits already
  on a remote (= already gated); `-c` retains conflict resolutions → no missed-review hole. Residual risks
  routed to the Task 1 spike: `-c` clean-vs-conflict behavior, shallow-clone `--not --remotes`, and any raw
  `git diff "$range"` on the sentinel (none found in read; spike/tests confirm).
- Cross-model validation: adversarial --mode plan (codex-5.3; gemini/cursor excluded/absent this run) →
  0 CRITICAL, 3 WARNING, ALL FIXED in rev 2: (1) smoke proofs now authored+run by Task 5 [rule 8];
  (2) Task 5 relabeled integration and scoped to smoke+docs+verify; (3) B-gate-multimerge closure moved to
  Task 5 AFTER end-to-end smoke, out of Task 4.
- Status gate: Approved (user: "rob" = option A)

## Task Breakdown

### Task 1: Feasibility spike — prove `git log -c --not --remotes` semantics across topologies
**Files:** `zuvo/proofs/task-1-loglog-spike.sh` (throwaway harness), `zuvo/proofs/task-1-loglog-spike.txt` (captured output)
**Surface:** integration
**Complexity:** complex
**Dependencies:** none
**Execution routing:** deep implementation tier

- [ ] RED: author `task-1-loglog-spike.sh` that builds throwaway hermetic repos (GIT_CONFIG isolated,
  bare remote) for EACH topology and asserts the exact production-file set from
  `git log --format= --name-only -c "$tip" --not --remotes | sort -u`:
  (a) linear branch → only the local commits' files;
  (b) branch off far-ahead develop → only feature files (develop-ahead excluded);
  (c) single-merge (merged origin/main in) → feature files only, NO merged main files;
  (d) MULTI-merge (merged origin/main AND origin/other) → feature files only, NEITHER merged branch;
  (e) octopus merge → same;
  (f) deletion of a tracked file in an un-pushed commit → the deleted path IS listed;
  (g) merge WITH a hand-resolved conflict → the conflict-resolved file IS listed (`-c` keeps it);
  (h) clean merge (no conflict) → contributes nothing;
  (i) remote-less repo → document that `--not --remotes` lists the whole history (why the exit-1
      merge-base fallback is retained).
- [ ] GREEN: the spike is the test; "GREEN" = every asserted case matches. If any case (esp. g/h — the
  `-c` conflict/clean behavior) deviates, STOP and record the deviation as a `[SPIKE-DEVIATION]` that
  reshapes Task 3/4 before any lib edit.
- [ ] Verify: `bash zuvo/proofs/task-1-loglog-spike.sh; echo "exit=$?"`
  Expected: `ALL SPIKE PASS` and `exit=0`.
- [ ] Acceptance Proof:
  - G3:
    - Surface: integration
    - Proof: `bash zuvo/proofs/task-1-loglog-spike.sh 2>&1 | grep -E 'conflict-resolved file IS listed'`
    - Expected: the conflict case prints PASS (exit 0)
    - Artifact: `zuvo/proofs/task-1-loglog-spike.txt`
- [ ] Commit: `test(gate): spike proving git log -c --not --remotes scopes every topology (pre-rewrite)`

### Task 2: `pg_changed_production` + `pg_changed_lines` recognise the `@unpushed` sentinel
**Files:** `hooks/lib/pipeline-gate-lib.sh`, `tests/hooks/test-pipeline-gate-lib.sh`
**Surface:** backend-logic
**Complexity:** standard
**Dependencies:** Task 1 (consumes the spike-proven `git log -c --not --remotes` invocation)
**Execution routing:** default implementation tier

- [ ] RED: in `test-pipeline-gate-lib.sh` add assertions that `pg_changed_production "@unpushed..HEAD"`
  and `pg_changed_lines "@unpushed..HEAD"` compute from the un-pushed commit set (build a merge fixture:
  their output = feature files / feature line-count, NOT merged-in main files/lines), while a normal
  `A..B` range still uses `git diff` (existing behavior unchanged — assert a linear range gives the same
  files as before). Fixtures hermetic (GIT_CONFIG isolated).
- [ ] GREEN: in both functions, parse `base=${range%%..*}`; when `base = @unpushed`, set `tip=${range##*..}`
  and compute via `git -C "$root" log --format= --name-only -c "$tip" --not --remotes` (production-filter
  through `pg_is_production`) / `--numstat -c` (sum add+del over production paths). Else keep the current
  `git diff` path verbatim. Preserve fail-OPEN (`2>/dev/null`, empty on error) and the NUL/space-safe
  path handling already present.
- [ ] Verify: `bash tests/hooks/test-pipeline-gate-lib.sh 2>&1 | grep -E 'SENTINEL|R-DEL|ALL PASS'`
  Expected: new `SENTINEL:` assertions PASS and existing `R-DEL` assertions unchanged; `ALL PASS`.
- [ ] Acceptance Proof:
  - G7:
    - Surface: backend-logic
    - Proof: assert a non-sentinel range still diffs: the R-DEL/linear cases (which pass a normal `A..B`)
      remain green after the edit
    - Expected: `ALL PASS` (git-diff path untouched for non-sentinel ranges)
    - Artifact: `zuvo/proofs/task-2-sentinel.txt`
  - G8:
    - Surface: backend-logic
    - Proof: `pg_changed_production "@unpushed..HEAD"` in a non-repo / on a bad tip returns empty (fail-open)
    - Expected: empty output, exit non-fatal (no abort)
    - Artifact: `zuvo/proofs/task-2-failopen.txt`
- [ ] Commit: `feat(gate): pg_changed_* compute un-pushed files via git log -c --not --remotes on @unpushed sentinel`

### Task 3: `pg_unpushed_range` returns the sentinel — delete the merge-base loop
**Files:** `hooks/lib/pipeline-gate-lib.sh`, `tests/hooks/test-pipeline-gate-lib.sh`
**Surface:** backend-logic
**Complexity:** standard
**Dependencies:** Task 2 (the sentinel it emits is only meaningful once the consumers understand it)
**Execution routing:** default implementation tier

- [ ] RED: assert `pg_unpushed_range` returns `@unpushed..<HEAD-sha-or-HEAD>` when remotes exist AND there
  is un-pushed work; exit 3 when everything is pushed; exit 1 when there are NO remote refs (remote-less →
  caller falls back to merge-base). Assert NO `git merge-base` loop remains (grep the function body for
  `merge-base` returns 0 hits inside `pg_unpushed_range`).
- [ ] GREEN: replace the body: keep the `for-each-ref --count=1 refs/remotes` guard (empty → return 1) and
  the `rev-list "$tip" --not --remotes | head -1` emptiness guard (empty → return 3); then
  `printf '@unpushed..%s\n' "$tip"`. Delete the `best`/merge-base candidate loop, the `--sort=-committerdate`
  scan, and the multi-merge LIMIT comment (obsolete). Keep the tip arg (`${1:-HEAD}`) for gate_native.
- [ ] Verify: `bash tests/hooks/test-pipeline-gate-lib.sh 2>&1 | grep -E 'R-UNPUSHED|R-MERGE|no merge-base loop|ALL PASS'`
  Expected: R-UNPUSHED + R-MERGE PASS, "no merge-base loop" assertion PASS, `ALL PASS`.
- [ ] Acceptance Proof:
  - G5:
    - Surface: backend-logic
    - Proof: `awk '/^pg_unpushed_range\(\)/{f=1} f&&/merge-base/{print} f&&/^}/{exit}' hooks/lib/pipeline-gate-lib.sh | wc -l`
    - Expected: `0` (no merge-base call inside the function — O(N) loop gone)
    - Artifact: `zuvo/proofs/task-3-noloop.txt`
  - G6:
    - Surface: backend-logic
    - Proof: a remote-less fixture → `pg_unpushed_range` exits 1 (caller uses merge-base fallback, not the sentinel)
    - Expected: exit code 1
    - Artifact: `zuvo/proofs/task-3-noremotes.txt`
- [ ] Commit: `refactor(gate): pg_unpushed_range emits @unpushed sentinel — delete the O(N) merge-base loop`

### Task 4: Topology regression suite — close the whole class + prove no regression
**Files:** `tests/hooks/test-pipeline-gate-lib.sh`, `memory/backlog.md`
**Surface:** integration
**Complexity:** standard
**Dependencies:** Task 2, Task 3 (exercises the assembled mechanism end-to-end via pg_range_reviewed/pg_is_substantial)
**Execution routing:** default implementation tier

- [ ] RED: add end-to-end assertions driving `pg_changed_production`/`pg_is_substantial`/`pg_range_reviewed`
  on the sentinel for: R-MULTIMERGE (merged two divergent remote branches → feature-only, neither branch
  dragged in); R-CONFLICT (merge with a hand-resolved conflict → the resolved file IS in scope, no
  under-scope hole); confirm R-DEL, R-UNPUSHED, R-MERGE still assert feature-only. All fixtures hermetic.
- [ ] GREEN: no production change expected — this task is the coverage net. If a case fails, the fix lands
  in Task 2/3 (loop back). (Backlog closure of `B-gate-multimerge` is deferred to Task 5, AFTER the
  end-to-end installed-gate smoke confirms the class is closed — not on unit assertions alone.)
- [ ] Verify: `bash tests/hooks/test-pipeline-gate-lib.sh 2>&1 | tail -1`
  Expected: `ALL PASS` (incl. R-MULTIMERGE, R-CONFLICT, and all prior R-* assertions).
- [ ] Acceptance Proof:
  - G1:
    - Surface: integration
    - Proof: `bash tests/hooks/test-pipeline-gate-lib.sh 2>&1 | grep 'R-MERGE'`
    - Expected: R-MERGE PASS (merged-in main excluded — the reported bug)
    - Artifact: `zuvo/proofs/task-4-topology.txt`
  - G2:
    - Surface: integration
    - Proof: `bash tests/hooks/test-pipeline-gate-lib.sh 2>&1 | grep 'R-MULTIMERGE'`
    - Expected: R-MULTIMERGE PASS (two merged remote branches, neither dragged in)
    - Artifact: `zuvo/proofs/task-4-topology.txt`
  - G3:
    - Surface: integration
    - Proof: `bash tests/hooks/test-pipeline-gate-lib.sh 2>&1 | grep 'R-CONFLICT'`
    - Expected: R-CONFLICT PASS (conflict-resolved file IS flagged — no under-scope)
    - Artifact: `zuvo/proofs/task-4-topology.txt`
  - G4:
    - Surface: integration
    - Proof: `bash tests/hooks/test-pipeline-gate-lib.sh 2>&1 | grep -E 'R-UNPUSHED|R-DEL'`
    - Expected: R-UNPUSHED + R-DEL PASS (no regression on prior-fixed shapes)
    - Artifact: `zuvo/proofs/task-4-topology.txt`
- [ ] Commit: `test(gate): topology regression suite (multi-merge + conflict) — close B-gate-multimerge`

### Task 5: Whole-feature smoke runner + cross-gate integration + close backlog + docs + version
**Files:** `zuvo/proofs/smoke-gate-topology.sh` (the smoke runner — authored here, per rule 8), `hooks/lib/pipeline-gate-lib.sh` (header comment), `docs/pipeline.md`, `memory/backlog.md`
**Surface:** integration
**Complexity:** standard
**Dependencies:** Task 3, Task 4
**Execution routing:** default implementation tier

- [ ] RED: author `zuvo/proofs/smoke-gate-topology.sh` — the runnable end-to-end smoke that BOTH
  SMOKE1 and SMOKE2 execute against the INSTALLED gate (self-install into a hermetic throwaway repo +
  bare remote, exactly as a real project wires it). It asserts: (SMOKE1) a merge-based branch push is
  BLOCKED naming ONLY the feature file then ALLOWED after a covering artifact; (SMOKE2) a multi-merge
  branch push is ALLOWED with only the feature file covered. Also assert (verify-only, no code change)
  the four consumer suites are green under the new mechanism: `test-pre-push-gate.sh` (gate_native
  new-branch + gate_legacy route through the sentinel), `test-stop-pipeline-gate.sh`, `test-ci-gate.sh`.
  If any suite or smoke case fails, the fix lands in Task 2/3 (loop back).
- [ ] GREEN: the smoke runner is the deliverable; the lib header comment + `docs/pipeline.md` are edited to
  describe the base-free `@unpushed` / `git log -c --not --remotes` mechanism (replacing the
  base-per-topology narrative). ONLY AFTER `smoke-gate-topology.sh` passes AND the topology suite (Task 4)
  is green, remove `B-gate-multimerge` from `memory/backlog.md` and delete its obsolete code-comment
  reference — the class is closed end-to-end, not on unit assertions alone.
- [ ] Verify: `bash zuvo/proofs/smoke-gate-topology.sh && for t in test-pre-push-gate test-stop-pipeline-gate test-ci-gate; do bash tests/hooks/$t.sh >/dev/null 2>&1 && echo "$t PASS" || echo "$t FAIL"; done`
  Expected: `ALL SMOKE PASS` then all three suites print PASS.
- [ ] Acceptance Proof:
  - G1:
    - Surface: integration
    - Proof: `bash zuvo/proofs/smoke-gate-topology.sh 2>&1 | grep -i 'SMOKE1'`
    - Expected: SMOKE1 PASS — merge-branch push blocked on ONLY the feature file, allowed after coverage
    - Artifact: `zuvo/proofs/smoke-merge-scope.txt`
  - G2:
    - Surface: integration
    - Proof: `bash zuvo/proofs/smoke-gate-topology.sh 2>&1 | grep -i 'SMOKE2'`
    - Expected: SMOKE2 PASS — multi-merge push allowed with only the feature file covered (was over-scoped)
    - Artifact: `zuvo/proofs/smoke-multimerge-scope.txt`
  - G7:
    - Surface: integration
    - Proof: the pre-push native-path assertions in `test-pre-push-gate.sh` (rsha..lsha ranges) stay green
    - Expected: `test-pre-push-gate PASS` (native git-diff path unchanged)
    - Artifact: `zuvo/proofs/task-5-integration.txt`
  - [DECISION: version bump] print `[DECISION: patch|minor]` — patch (internal gate correctness, no new
    behavior surface for users) unless the removed-loop / new-scoping is deemed a behavior change → minor.
- [ ] Commit: `feat(gate): topology-complete @unpushed mechanism — smoke + integration verified, close B-gate-multimerge`

## Whole-feature Smoke Proofs

- **SMOKE1 — end-to-end merge-branch push scoped feature-only via the INSTALLED gate**
  - Preconditions: hermetic throwaway repo + bare remote; the repo self-installs the built gate
    (`install-refactor-gate.sh` / global dispatcher path) exactly as a real project does; ZUVO_ALLOW_ADHOC unset.
  - Proof: build a branch that merges origin/main in, add an un-reviewed feature file, attempt `git push`;
    then write a covering `memory/reviews/` artifact for ONLY the feature file and push again.
  - Expected: first push BLOCKED naming ONLY the feature file (never merged-in main files); second push ALLOWED.
  - Artifact: `zuvo/proofs/smoke-merge-scope.txt`
- **SMOKE2 — multi-merge branch is not over-scoped end-to-end**
  - Preconditions: same harness; branch merges TWO remote branches in.
  - Proof: push with only the feature file covered.
  - Expected: push ALLOWED (neither merged branch dragged in) — the case that previously over-scoped.
  - Artifact: `zuvo/proofs/smoke-multimerge-scope.txt`
