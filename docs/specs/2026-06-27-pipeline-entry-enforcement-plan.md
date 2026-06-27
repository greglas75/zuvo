# Implementation Plan: Pipeline-Entry Enforcement (stop agents shipping features past the gates)

**Spec:** inline — no spec
**spec_id:** none
**planning_mode:** inline
**source_of_truth:** inline brief + 3-reviewer adversarial loop (rev1→rev3)
**plan_revision:** 3
**status:** Approved
**Created:** 2026-06-27
**Approved:** 2026-06-27 (user: "lec z planem")
**Tasks:** 14
**Estimated complexity:** mixed; 5 complex (lib, pre-push gate, CI gate, install, smoke)

## Problem (root cause, established this session)

Prompts/router don't enforce. An agent built a whole `custom-tables` feature (3 commits on a worktree, **not pushed**) with **no `zuvo:execute` run** — confirmed via `~/.zuvo/runs.log` (no Run: line, no run-marker). No review, no smoke, no gate fired; the user only got review by asking. The existing `pre-commit-adversarial-gate.sh` engages only when execute is *already active*, so freelance bypasses it.

## The pivot (why rev3 looks different from rev1/2)

Two adversarial review rounds (plan-reviewer + gemini + cursor-agent) proved the rev1/2 **primitives were wrong**, not just mis-worded:
- **session-base cumulative diff** breaks 4 ways — worktree (the incident's own env), post-`compact`, and `git pull`/branch-switch (false-locks every commit for the session).
- **"build emits a marker" = a session-wide whitelist** — one small build run unlocks unlimited freelance; crash-unsafe (marker written before build succeeds).
- **commit-gate staged-diff detection is gameable** — `git commit <paths>`, `git -c x commit`, `-am`.
- **Stop exit-2 efficacy is unproven** and the gate doesn't even ship to Codex/Antigravity — blind exactly where the incident happened.

**Resolution (research-backed: "CI cannot be bypassed by agents"; deterministic > prompt):** move the *guarantee* to where the range is canonical and the layer is unbypassable, and keep local hooks as best-effort nudges.

| Layer | Role | Why robust |
|-------|------|-----------|
| **CI gate** (server-side, GH Actions template + check script) | **the guarantee** | runs on the PR/push range server-side; cannot be `--no-verify`'d or skipped by any agent/harness |
| **pre-push gate** (local, extends existing `pre-push-gate.sh`) | **primary local enforcement** | git hands the hook the EXACT pushed ref ranges on stdin — immune to pull/checkout/worktree/compaction; git-level so harness-agnostic |
| **review-artifact keyed-to-content** (`memory/reviews/<base>..<head>.md`) | **the signal** | written by review/build/execute on SUCCESS, recording the reviewed range+files; gates ask "is THIS range reviewed?" not "did a pipeline run recently?" — kills the whitelist |
| commit-gate + Stop-gate | **best-effort nudges** | explicitly NOT the guarantee; surface early so the agent self-corrects (the user's immediate pain). Their fragility/bypassability is acceptable-by-design and documented. |
| block-no-verify + PATH-shim (opt-in) | `--no-verify` defense | hook + universal git-level shim |
| using-zuvo router | soft top layer | sets intent; the gates enforce |

The fragile **session-base SHA and the build-marker-whitelist are removed entirely.** Local best-effort gates use **`merge-base` with the default branch** (stable, not session/time-based). The CI + pre-push gates use the **canonical push/PR range**.

## Architecture Summary

```
                review-artifact (memory/reviews/<base>..<head>.md)  ← Task 2 (review/build/execute write on success)
                        ▲ pg_range_reviewed(range)  — content-keyed coverage
 hooks/lib/pipeline-gate-lib.sh (Task 3): classify · is_substantial(range, add+del) · range_reviewed · allow_adhoc · fail-open   (range is ALWAYS an arg — never session state)
   ▲ pushed ranges (git stdin)     ▲ PR/push range (CI)        ▲ merge-base..HEAD (best-effort)
 pre-push-gate.sh (Task 4)       CI check script (Task 5)     commit-gate (Task 6) + Stop-gate (Task 7)
  PRIMARY local — blocks push     THE GUARANTEE — fails check   NUDGES — warn early, not the guarantee
 block-no-verify (Task 8, robust parse)   PATH-shim (Task 9, opt-in, human pass-through)   router (Task 12)
```

**Layer → harness/coverage (honest):**

| Layer | Claude | Codex | Cursor | Antigravity | Human | Bypassable? |
|-------|:--:|:--:|:--:|:--:|:--:|:--|
| CI gate | ✅ | ✅ | ✅ | ✅ | ✅ | **No** (server-side) — the guarantee |
| pre-push gate | ✅ | ✅ | ✅ | ✅ | ⚠️¹ | only via `--no-verify` (→ Task 8/9) |
| commit/Stop nudge | ✅ | ✅² | ✅² | ✅² | ❌ | yes (by design — best-effort) |
| block-no-verify | ✅ | ✅ | ✅ | ✅ | ❌ | — |
| PATH-shim (opt-in) | ✅ | ✅ | ✅ | ✅ | pass-through | — |

¹ pre-push is a git hook → fires for the human too; the gate exempts human (non-agent-env) pushes. ² commit/Stop nudges are best-effort; where a harness can't run them, the pre-push + CI gates still cover.

## Technical Decisions

- **Range is always an argument, never inferred from session state.** Every lib function takes an explicit `<base>..<head>`. Callers supply it from the canonical source: pre-push → git stdin; CI → PR/push range; commit/Stop nudges → `git merge-base HEAD <default-branch>..HEAD`. This eliminates every session-base failure mode at once.
- **The signal is review coverage of content, not pipeline recency.** `pg_range_reviewed` checks whether a `memory/reviews/*` artifact records a reviewed range/file-set that COVERS the change under inspection. A build of files X never whitelists unrelated files Y; a crashed build writes nothing (artifact is on-success only). No markers, no whitelist, no 6h window.
- **Guarantee at push/CI; nudge at commit/stop.** The user's pain ("agent finished without review") is addressed by the nudges (surface early). The real risk (unreviewed code entering shared history) is addressed by pre-push + CI, where the range is canonical and CI is unbypassable. Because the nudges are explicitly NOT the guarantee, their known bypasses (staging tricks, Stop exit-2 uncertainty, harness gaps) are acceptable and documented, not load-bearing.
- **Substantial = total changed lines (add+del) OR prod-file count**, env-overridable (`ZUVO_GATE_MIN_FILES` 3, `ZUVO_GATE_MIN_LINES` 150). Classifier excludes `tests/`,`**/__tests__/`,`*.test.*`,`*.spec.*`,`docs/`,`*.md`, config globs.
- **Fail-open everywhere.** Malformed input / missing repo / git failure / missing lib → exit 0. A benign error never opaque-blocks. (The CI gate is the backstop if a local fail-open lets something slip.)
- **Escape valve, logged:** `ZUVO_ALLOW_ADHOC=1` (with reason) for local gates; CI uses a PR label `zuvo:adhoc-approved` (human-applied) so the agent can't self-exempt the unbypassable layer.
- **Robust git parsing** (block-no-verify, gate commands): account for global flags (`git -c k=v`, `--work-tree`, `-C dir`) before the subcommand; `-n` is `--no-verify` only for `commit` (dry-run for push/add).
- **Hard human checkpoint after the spike.** Task 1 is a decision gate; in interactive execute it stops for confirmation before Tasks 4–11 build on its verdicts (so an agent can't auto-pivot on a hallucinated spike result).
- **install.sh testable**: source-able (`BASH_SOURCE` guard), overridable HOME; ships `hooks/lib/` + new hooks to ALL targets incl. the `build-codex-skills.sh`/`build-antigravity-skills.sh` allowlists; CI template installed/documented.

## Quality Strategy

Pure-shell stdin→exit-code hooks → unit-testable by piping synthetic payloads (`tests/hooks/`, assert `$?`). `shellcheck` exit 0 unconditional. Every gate has explicit fail-open RED cases. The CI check script is testable headless on a fixture repo. Smoke (Task 14) uses an overridable `$HOME` so it never touches real `~/.claude`/`~/.codex`. Risks: false-positive nudges (mitigated — nudges, not blocks, + merge-base range + classifier + escape), CI provider coverage (GH Actions primary; others documented/detected), review-artifact discipline (skills must write it on success — tested).

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| G1 | Unreviewed substantial change cannot be **pushed** (local) | requirement | Task 4, Task 14 | canonical push range |
| G2 | Unreviewed substantial change cannot **merge** (CI, unbypassable) | requirement | Task 5, Task 14 | the guarantee |
| G3 | Agent that finishes with unreviewed committed work is **nudged** to review | requirement | Task 6, Task 7, Task 14 | best-effort; addresses the user's pain |
| G4 | Signal is content-keyed review coverage (no whitelist, crash-safe) | requirement | Task 2, Task 3, Task 14 | replaces marker-whitelist |
| G5 | `--no-verify`/commit-`-n` rejected; `push -n`/`add -n` pass; robust to global flags | requirement | Task 8, Task 9 | |
| G6 | Escape valves work + are logged (local env; CI = human PR label) | requirement | Task 3, Task 5, Task 6 | agent can't self-exempt CI |
| G7 | Small/test/docs/config changes NOT blocked | constraint | Task 3, Task 14 | classifier + thresholds |
| G8 | Human terminal pushes/commits not blocked | constraint | Task 4, Task 9 | agent-env exemption + shim pass-through |
| G9 | Shared detection logic single-source (range-arg, fail-open) | deliverable | Task 3 | every gate sources it |
| G10 | Local hooks + lib shipped to Claude/Codex/Cursor/Antigravity; CI template installable | deliverable | Task 10, Task 11 | correct per-harness shape + build allowlists |
| G11 | Router defaults production-code work to the pipeline; threshold = contract | deliverable | Task 12 | soft layer |
| G12 | Gates fail OPEN on malformed input/missing repo/git failure | constraint | Task 4, Task 6, Task 7, Task 8 | CI is the backstop |
| C1 | Honest limits documented (nudges bypassable; CI is the guarantee) | constraint | Task 1, Task 13 | |
| C2 | Cross-harness/CI-provider/parse unknowns resolved before building; human checkpoint | constraint | Task 1 | hard decision gate |

## Review Trail
- Phase 1: direct (full in-session context on hook wiring + web research)
- rev1 review: plan-reviewer + gemini + cursor-agent → 10+13 findings (build self-block, no session base, stale window, lib not shipped, antigravity shape, double-reg, -am, -n, deletions, shim-human, install testability, fail-open, router threshold, smoke coverage). ALL folded into rev2.
- rev2 review: plan-reviewer + gemini + cursor-agent → confirmed rev1 fixes landed; surfaced ARCHITECTURAL defects (session-base fragile on worktree/compact/pull; build-marker = whitelist; staged-diff bypass via explicit paths/global flags; Stop efficacy unproven + not shipped to Codex/Antigravity). → **rev3 pivot**: push+CI guarantee, content-keyed review artifact, merge-base for best-effort, nudges decoupled from the guarantee.
- rev3 review: presented to user at iteration cap; user approved the pivot ("lec z planem")
- Status gate: Approved (2026-06-27, user)

## Task Breakdown

### Task 1: Spike + contract + human checkpoint (resolve every unknown BEFORE building)
**Files:** `docs/specs/2026-06-27-pipeline-entry-enforcement-notes.md` (new)
**Surface:** docs
**Complexity:** complex
**Dependencies:** none
**Execution routing:** deep implementation tier

- [ ] RED: docs/decision task — VERDICT line per question below.
- [ ] GREEN: pin: (a) production classifier globs; (b) substantial = add+del (`git diff --shortstat <range>`) ≥150 lines OR ≥3 prod files, env-overridable; (c) **review-artifact schema** — path `memory/reviews/<base>7..<head>7-<slug>.md` + a machine-readable header recording reviewed `range` and `files[]`; define `pg_range_reviewed` coverage rule (change files ⊆ union of reviewed files, OR change range ⊆ a reviewed range); (d) **pre-push stdin contract** (`<localref> <localsha> <remoteref> <remotesha>` lines) and how to derive the pushed range incl. new-branch (`<remotesha>` all-zeros → use `merge-base`); (e) **CI provider** — GH Actions primary (workflow + check script), detect/doc GitLab/others; the `zuvo:adhoc-approved` PR-label escape; (f) commit/Stop nudge range = `merge-base HEAD <default-branch>..HEAD` (NOT session-base); confirm nudges are best-effort (non-load-bearing) so Stop exit-2 efficacy is NOT required; (g) robust git-command parse rule (skip `-c k=v`,`-C dir`,`--work-tree=` etc. before subcommand); (h) agent-env detection set for human-exemption (`CLAUDE_*`,`CODEX_*`,`CURSOR_*`,`GEMINI_*`/antigravity).
- [ ] **Human checkpoint:** in interactive execute, STOP after this task and present the verdicts for confirmation before Tasks 4–11 build on them (batch/--auto: proceed with recorded verdicts).
- [ ] Verify: `test -s docs/specs/2026-06-27-pipeline-entry-enforcement-notes.md && grep -qE 'ZUVO_ALLOW_ADHOC|adhoc-approved|merge-base|range_reviewed|--shortstat' docs/specs/2026-06-27-pipeline-entry-enforcement-notes.md`
  Expected: exit 0
- [ ] Acceptance Proof:
  - AC C2: unknowns resolved + checkpoint
    - Surface: docs
    - Proof: `grep -ciE 'VERDICT' docs/specs/2026-06-27-pipeline-entry-enforcement-notes.md`
    - Expected: ≥8 VERDICT lines (a–h), each with fallback where the answer is "no/unsupported"
    - Artifact: `zuvo/proofs/task-1-c2.txt`
- [ ] Commit: `docs(plan): pin push/CI range + review-artifact contract + spike verdicts`

### Task 2: Content-keyed review artifact — review/build/execute write it on success
**Files:** `skills/review/SKILL.md` (edit), `skills/build/SKILL.md` (edit), `skills/execute/SKILL.md` (edit), `tests/hooks/test-review-artifact.sh` (new)
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 1
**Execution routing:** default implementation tier

- [ ] RED: test asserts each of the 3 SKILLs instructs writing `memory/reviews/<base>7..<head>7-<slug>.md` **on successful completion only**, with the machine-readable `range:`/`files:` header from Task 1(c). (review already writes a report — standardize its header; build/execute add it to their completion.)
- [ ] GREEN: add/standardize the artifact-write step in review (completion), build (Phase 4 on success), execute (Phase Final-2 on success). Crash/early-exit → no artifact (so a failed run never grants coverage).
- [ ] Verify: `grep -lE 'memory/reviews/.*range:' skills/review/SKILL.md skills/build/SKILL.md skills/execute/SKILL.md | wc -l | grep -q 3 && bash tests/hooks/test-review-artifact.sh`
  Expected: 3 files match; `ALL PASS`
- [ ] Acceptance Proof:
  - AC G4: content-keyed signal, on-success only
    - Surface: docs
    - Proof: `bash tests/hooks/test-review-artifact.sh`
    - Expected: `ALL PASS` — all 3 skills write a range/files-headed artifact on success
    - Artifact: `zuvo/proofs/task-2-g4.txt`
- [ ] Commit: `feat(skills): review/build/execute emit content-keyed review artifact on success`

### Task 3: Shared detection library (range-arg, content-keyed, fail-open)
**Files:** `hooks/lib/pipeline-gate-lib.sh` (new), `tests/hooks/test-pipeline-gate-lib.sh` (new)
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** Task 1, Task 2
**Execution routing:** deep implementation tier

- [ ] RED: source lib, assert with fixtures: `pg_classify_files` drops test/docs/config; `pg_is_substantial <range>` true at ≥3 prod files OR ≥150 add+del, false below; `pg_range_reviewed <range>` true when a fixture `memory/reviews/*` covers the changed files/range, **false when it covers only unrelated files** (no-whitelist case); `pg_allow_adhoc` honors env; **fail-open**: bad range / no repo / unreadable artifact dir → safe default (not substantial / reviewed=unknown→non-block), never a non-zero abort.
- [ ] GREEN: implement pure functions taking an explicit `<range>`; env-overridable thresholds; `git -C "$repo_root"`; guard every git call. No session/marker/time logic at all.
- [ ] Verify: `bash tests/hooks/test-pipeline-gate-lib.sh && shellcheck hooks/lib/pipeline-gate-lib.sh`
  Expected: `ALL PASS`; shellcheck 0
- [ ] Acceptance Proof:
  - AC G4/G7/G9/G12: classifier + no-whitelist coverage + single-source + fail-open
    - Surface: backend-logic
    - Proof: `bash tests/hooks/test-pipeline-gate-lib.sh`
    - Expected: `ALL PASS` — incl. unrelated-review ≠ coverage, add+del threshold, fail-open
    - Artifact: `zuvo/proofs/task-3-g4.txt`
- [ ] Commit: `feat(hooks): range-keyed, content-reviewed detection library (fail-open) + tests`

### Task 4: pre-push gate (PRIMARY local enforcement, canonical range)
**Files:** `hooks/pre-push-gate.sh` (edit), `tests/hooks/test-pre-push-gate.sh` (new)
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** Task 3
**Execution routing:** deep implementation tier

- [ ] RED: feed synthetic pre-push stdin lines. Cases: (a) pushed range substantial + unreviewed → **exit 1** (block push) naming the remedy + `ZUVO_ALLOW_ADHOC`; (b) range reviewed (fixture artifact covers it) → 0; (c) small range → 0; (d) docs-only → 0; (e) `ZUVO_ALLOW_ADHOC=1` → 0; (f) new-branch (remote all-zeros) → uses merge-base, still evaluates; (g) **human push (no agent env)** → 0 (G8); (h) fail-open: malformed stdin / no repo → 0. Preserve any existing pre-push behavior.
- [ ] GREEN: parse stdin ranges; for each, if agent-env AND `pg_is_substantial` AND NOT `pg_range_reviewed` AND NOT `pg_allow_adhoc` → block (exit 1). Human pushes exempt. Fail-open on error.
- [ ] Verify: `bash tests/hooks/test-pre-push-gate.sh && shellcheck hooks/pre-push-gate.sh`
  Expected: `ALL PASS`; shellcheck 0
- [ ] Acceptance Proof:
  - AC G1/G6/G8/G12: unreviewed push blocked; escape; human-exempt; fail-open
    - Surface: backend-logic
    - Proof: `bash tests/hooks/test-pre-push-gate.sh`
    - Expected: `ALL PASS` — (a) exit 1; (b)(c)(d)(e)(f-evaluates)(g)(h) per spec
    - Artifact: `zuvo/proofs/task-4-g1.txt`
- [ ] Commit: `feat(hooks): pre-push gate blocks unreviewed substantial pushes (canonical range)`

### Task 5: CI gate (THE GUARANTEE — unbypassable server-side check)
**Files:** `ci/zuvo-pipeline-entry.yml` (new GH Actions template), `scripts/zuvo-pipeline-entry-ci.sh` (new), `tests/hooks/test-ci-gate.sh` (new)
**Surface:** integration
**Complexity:** complex
**Dependencies:** Task 3
**Execution routing:** deep implementation tier

- [ ] RED: run the CI check script headless on a fixture repo. Cases: (a) PR range substantial + unreviewed + no `zuvo:adhoc-approved` label → **exit 1** (fail check); (b) reviewed range → 0; (c) `zuvo:adhoc-approved` label env present → 0; (d) small/docs → 0; (e) the workflow YAML is valid (yamllint/`jq`-free parse) and computes the PR/push range correctly.
- [ ] GREEN: implement `scripts/zuvo-pipeline-entry-ci.sh` (sources the lib; range from CI env — `GITHUB_BASE_REF`/SHA or push before/after; label via `GITHUB_*`/input); author the GH Actions template invoking it. Document the human-only `zuvo:adhoc-approved` label as the CI escape (agents can't self-apply).
- [ ] Verify: `bash tests/hooks/test-ci-gate.sh && shellcheck scripts/zuvo-pipeline-entry-ci.sh`
  Expected: `ALL PASS`; shellcheck 0
- [ ] Acceptance Proof:
  - AC G2/G6: unreviewed change fails CI; human-label escape only
    - Surface: integration
    - Proof: `bash tests/hooks/test-ci-gate.sh`
    - Expected: `ALL PASS` — (a) exit 1; (b)(c)(d) exit 0; YAML valid
    - Artifact: `zuvo/proofs/task-5-g2.txt`
- [ ] Commit: `feat(ci): unbypassable pipeline-entry CI gate (GH Actions template + check script)`

### Task 6: commit-gate nudge (best-effort, merge-base range)
**Files:** `hooks/pre-commit-adversarial-gate.sh` (edit), `tests/hooks/test-commit-gate-nudge.sh` (new)
**Surface:** backend-logic
**Complexity:** standard
**Dependencies:** Task 3
**Execution routing:** default implementation tier

- [ ] RED: synthetic `git commit` payloads. Cases: (a) merge-base..HEAD+staged substantial + unreviewed → **loud stderr nudge, exit 0** (NUDGE not block — the push/CI gate is the guarantee); (b) reviewed → silent 0; (c) `ZUVO_ALLOW_ADHOC=1` → 0; (d) existing active-execute path → unchanged; (e) fail-open. (Best-effort: staging tricks are acknowledged; not the guarantee.)
- [ ] GREEN: extend with a nudge branch using the lib over the merge-base range; print a clear "you're committing substantial unreviewed work — run zuvo:build/review; the push/CI gate will block it otherwise" message; **exit 0** (do not block at commit). Preserve existing adversarial-artifact path + `*"git commit"*` guard. Fail-open.
- [ ] Verify: `bash tests/hooks/test-commit-gate-nudge.sh && shellcheck hooks/pre-commit-adversarial-gate.sh`
  Expected: `ALL PASS`; shellcheck 0
- [ ] Acceptance Proof:
  - AC G3/G12: early nudge on unreviewed commit; never opaque-blocks; fail-open
    - Surface: backend-logic
    - Proof: `bash tests/hooks/test-commit-gate-nudge.sh`
    - Expected: `ALL PASS` — nudge prints, exit 0 in all cases (never blocks)
    - Artifact: `zuvo/proofs/task-6-g3.txt`
- [ ] Commit: `feat(hooks): commit-gate best-effort nudge for unreviewed work (non-blocking)`

### Task 7: Stop-gate nudge (best-effort, addresses the user's pain)
**Files:** `hooks/zuvo-stop-pipeline-gate.sh` (new), `tests/hooks/test-stop-pipeline-gate.sh` (new)
**Surface:** backend-logic
**Complexity:** standard
**Dependencies:** Task 3
**Execution routing:** default implementation tier

- [ ] RED: Stop payloads. Cases: (a) `stop_hook_active:false` + merge-base..HEAD substantial (committed, clean tree) + unreviewed → **loud stderr nudge "run zuvo:review before finishing"** + exit 2 ONLY if Task 1(f) confirmed Stop exit-2 blocks, else exit 0 with the nudge (best-effort); (b) `stop_hook_active:true` → 0 (loop guard); (c) reviewed → 0; (d) `ZUVO_ALLOW_ADHOC=1` → 0; (e) docs/test-only → 0; (f) fail-open (no repo/bad JSON) → 0.
- [ ] GREEN: parse `stop_hook_active`; compute merge-base..HEAD via lib; nudge per Task 1(f) verdict (block or warn). Mirror `zuvo-stop-retro-sweep.sh` robustness. Single registration site (Task 10/11 own it). Fail-open.
- [ ] Verify: `bash tests/hooks/test-stop-pipeline-gate.sh && shellcheck hooks/zuvo-stop-pipeline-gate.sh`
  Expected: `ALL PASS`; shellcheck 0
- [ ] Acceptance Proof:
  - AC G3/G12: "done with unreviewed work" surfaced; loop-guard + fail-open
    - Surface: backend-logic
    - Proof: `bash tests/hooks/test-stop-pipeline-gate.sh`
    - Expected: `ALL PASS` — (a) nudge (block-or-warn per verdict); (b–f) per spec
    - Artifact: `zuvo/proofs/task-7-g3.txt`
- [ ] Commit: `feat(hooks): Stop-gate best-effort nudge to review before finishing`

### Task 8: block-no-verify (robust parse, commit-scoped -n)
**Files:** `hooks/block-no-verify.sh` (new), `tests/hooks/test-block-no-verify.sh` (new)
**Surface:** backend-logic
**Complexity:** standard
**Dependencies:** Task 1
**Execution routing:** default implementation tier

- [ ] RED: `git commit -m x --no-verify`→2; `git commit -n`→2; `git -c core.editor=x commit -n`→2 (global flag before subcommand); `git -C /r commit --no-verify`→2; `git push --no-verify`→2; `git push -n`→0; `git add -n`→0; `git commit -m ok`→0; non-git→0; malformed→0 (fail-open).
- [ ] GREEN: skip global args (`-c k=v`,`-C dir`,`--work-tree=…`,`--git-dir=…`,`-c`,`--namespace`) to find the real subcommand; reject `--no-verify` on commit/push/merge/cherry-pick/rebase/am; reject `-n` only for `commit`. Fail-open.
- [ ] Verify: `bash tests/hooks/test-block-no-verify.sh && shellcheck hooks/block-no-verify.sh`
  Expected: `ALL PASS`; shellcheck 0
- [ ] Acceptance Proof:
  - AC G5: --no-verify rejected even behind global flags; dry-runs pass; fail-open
    - Surface: backend-logic
    - Proof: `bash tests/hooks/test-block-no-verify.sh`
    - Expected: `ALL PASS`
    - Artifact: `zuvo/proofs/task-8-g5.txt`
- [ ] Commit: `feat(hooks): block-no-verify with global-flag-robust parsing`

### Task 9: PATH-shim git wrapper (opt-in, human pass-through, uninstall)
**Files:** `scripts/git-noverify-shim.sh` (new), `tests/hooks/test-git-shim.sh` (new)
**Surface:** backend-logic
**Complexity:** standard
**Dependencies:** Task 1
**Execution routing:** default implementation tier

- [ ] RED: stubbed `REAL_GIT`: agent-env `commit --no-verify`→1, `commit -n`→1; **human-env (no agent vars) `commit --no-verify`→pass-through (G8)**; `push -n`→pass-through; `status`→pass-through; real-git-not-found→clear error; `ZUVO_UNINSTALL_GIT_SHIM=1`→removes `~/bin/git`.
- [ ] GREEN: locate real git skipping `$SELF`; pass through transparently when no agent env var set; block commit `--no-verify`/`-n` for agent invocations. Header documents `/usr/bin/git` escape. (Opt-in install + uninstall appended in Task 11, serialized.)
- [ ] Verify: `bash tests/hooks/test-git-shim.sh && shellcheck scripts/git-noverify-shim.sh`
  Expected: `ALL PASS`; shellcheck 0
- [ ] Acceptance Proof:
  - AC G5/G8: agent --no-verify blocked; human + dry-runs pass; uninstall works
    - Surface: backend-logic
    - Proof: `bash tests/hooks/test-git-shim.sh`
    - Expected: `ALL PASS`
    - Artifact: `zuvo/proofs/task-9-g5g8.txt`
- [ ] Commit: `feat(scripts): opt-in PATH-shim — agent-only --no-verify block, human pass-through`

### Task 10: Wire local hooks into all harness configs (correct shapes, single Stop site)
**Files:** `hooks/hooks.json` (edit), `hooks/hooks.codex.json` (edit), `hooks/hooks.antigravity.json` (edit), `tests/hooks/test-hooks-wiring.sh` (new)
**Surface:** config
**Complexity:** standard
**Dependencies:** Task 4, Task 6, Task 7, Task 8
**Execution routing:** default implementation tier

- [ ] RED: `jq` test asserts: `block-no-verify` in Claude+Codex PreToolUse `Bash` and Antigravity `BeforeTool`/`run_shell_command`; pre-push gate present (already is) and commit-gate still present; Stop nudge registered at exactly ONE site (per Task 1 — assert not double); all three files valid JSON; no existing hook dropped.
- [ ] GREEN: add `block-no-verify` per each harness's real shape; add the Stop nudge to the single chosen site (hooks.json Stop OR defer to settings.json in Task 11 — not both); record `[STOP-UNSUPPORTED:<harness>]` where applicable.
- [ ] Verify: `jq -e . hooks/hooks.json hooks/hooks.codex.json hooks/hooks.antigravity.json && bash tests/hooks/test-hooks-wiring.sh`
  Expected: valid JSON; `ALL PASS`
- [ ] Acceptance Proof:
  - AC G10: wired with correct per-harness shape, single Stop site
    - Surface: config
    - Proof: `bash tests/hooks/test-hooks-wiring.sh`
    - Expected: `ALL PASS`
    - Artifact: `zuvo/proofs/task-10-g10.txt`
- [ ] Commit: `feat(hooks): wire block-no-verify + single-site stop nudge across harness configs`

### Task 11: install.sh + build scripts — ship lib/hooks/CI to all targets (testable)
**Files:** `scripts/install.sh` (edit), `scripts/build-codex-skills.sh` (edit), `scripts/build-antigravity-skills.sh` (edit), `scripts/build-cursor-skills.sh` (edit), `tests/hooks/test-install-wiring.sh` (new)
**Surface:** integration
**Complexity:** complex
**Dependencies:** Task 4, Task 6, Task 7, Task 8, Task 9, Task 10
**Execution routing:** deep implementation tier

- [ ] RED: source `install.sh` against an overridable temp HOME; assert `block-no-verify.sh`, `zuvo-stop-pipeline-gate.sh`, `lib/pipeline-gate-lib.sh`, `git-noverify-shim.sh`, the CI template + `scripts/zuvo-pipeline-entry-ci.sh` land in: Claude cache + `~/.claude/hooks/` (recursive — incl. `lib/`), and the Codex/Antigravity/Cursor build outputs (add new hooks to each build's hardcoded allowlist; copy `hooks/lib/` recursively through `replace_paths`); Stop registered at the SINGLE site, idempotent (no dup on re-run); `ZUVO_INSTALL_GIT_SHIM`/`ZUVO_UNINSTALL_GIT_SHIM` paths present; `shellcheck` exit 0 on all four scripts.
- [ ] GREEN: refactor `install.sh` source-able (`[[ "${BASH_SOURCE[0]}" == "$0" ]]` guard wrapping the top-level run incl. version/banner lines) + overridable HOME; make the hook copies recursive (incl. `lib/`); extend the codex/antigravity/cursor build allowlists with the new hooks + `hooks/lib/`; single idempotent Stop registration; opt-in shim install/uninstall.
- [ ] Verify: `bash tests/hooks/test-install-wiring.sh && shellcheck scripts/install.sh scripts/build-codex-skills.sh scripts/build-antigravity-skills.sh scripts/build-cursor-skills.sh`
  Expected: `ALL PASS`; shellcheck 0
- [ ] Acceptance Proof:
  - AC G10: lib+hooks+CI shipped to ALL harnesses; single idempotent registration
    - Surface: integration
    - Proof: `bash tests/hooks/test-install-wiring.sh`
    - Expected: `ALL PASS` — files in all targets incl codex/antigravity/cursor; one Stop entry after two installs
    - Artifact: `zuvo/proofs/task-11-g10.txt`
- [ ] Commit: `feat(install): ship entry hooks + lib + CI template to all targets (testable, idempotent)`

### Task 12: Router rule (threshold = contract)
**Files:** `skills/using-zuvo/SKILL.md` (edit), `tests/hooks/test-router-rule.sh` (new)
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 3
**Execution routing:** default implementation tier

- [ ] RED: grep test asserts the router routes production-code changes at the SAME threshold the lib enforces (≥3 prod files OR ≥150 changed lines → `zuvo:build`/`zuvo:execute`), forbids ad-hoc multi-file implementation, and states the push/CI gates enforce it.
- [ ] GREEN: add the rule near the routing table, citing the exact threshold + that pre-push/CI are the enforcement (and commit/Stop are early nudges).
- [ ] Verify: `grep -qiE 'zuvo:build|enter the pipeline' skills/using-zuvo/SKILL.md && grep -qE 'ZUVO_GATE_MIN_FILES|3 .*files|150' skills/using-zuvo/SKILL.md && bash tests/hooks/test-router-rule.sh`
  Expected: exit 0; `ALL PASS`
- [ ] Acceptance Proof:
  - AC G11: router rule present, threshold matches contract
    - Surface: docs
    - Proof: `bash tests/hooks/test-router-rule.sh`
    - Expected: `ALL PASS`
    - Artifact: `zuvo/proofs/task-12-g11.txt`
- [ ] Commit: `docs(using-zuvo): route production-code changes through the pipeline (threshold-aligned)`

### Task 13: Docs + honest limits + CI enablement guide
**Files:** `CLAUDE.md` (edit), `docs/pipeline.md` (edit), `tests/hooks/test-docs-present.sh` (new)
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 4, Task 5, Task 10, Task 11, Task 12
**Execution routing:** default implementation tier

- [ ] RED: grep test asserts docs cover: the layer table (CI=guarantee, pre-push=primary local, commit/Stop=nudges), how to enable the CI workflow, `ZUVO_ALLOW_ADHOC` + `zuvo:adhoc-approved` escapes, thresholds + env overrides, and an explicit limits paragraph (nudges are bypassable by design; CI is the only unbypassable layer; fail-open philosophy).
- [ ] GREEN: write the section from this plan's architecture + coverage + limits + a "enable CI" how-to.
- [ ] Verify: `grep -qiE 'ZUVO_ALLOW_ADHOC|adhoc-approved' CLAUDE.md docs/pipeline.md && grep -qiE 'fail.open|nudge|unbypassable|CI is the' docs/pipeline.md && bash tests/hooks/test-docs-present.sh`
  Expected: exit 0; `ALL PASS`
- [ ] Acceptance Proof:
  - AC C1: honest limits + CI enablement documented
    - Surface: docs
    - Proof: `bash tests/hooks/test-docs-present.sh`
    - Expected: `ALL PASS`
    - Artifact: `zuvo/proofs/task-13-c1.txt`
- [ ] Commit: `docs: pipeline-entry enforcement — layers, escapes, CI enablement, honest limits`

### Task 14: Whole-feature smoke (end-to-end, overridable HOME)
**Files:** `tests/hooks/smoke-pipeline-entry.sh` (new)
**Surface:** integration
**Complexity:** complex
**Dependencies:** Task 4, Task 5, Task 6, Task 7, Task 8, Task 11
**Execution routing:** deep implementation tier

- [ ] RED: the smoke IS the test. It sets an overridable `$HOME` (never touches real `~/.claude`/`~/.codex`), builds a throwaway repo, and drives the REAL gates end-to-end.
- [ ] GREEN: reproduce the incident + invariants — (1) substantial unreviewed range → **pre-push gate exit 1** AND **CI script exit 1**; (2) commit + Stop produce the nudge; (3) write a covering review artifact → pre-push + CI both exit 0 (content-keyed coverage); (4) an UNRELATED review artifact does NOT grant coverage (no whitelist); (5) `ZUVO_ALLOW_ADHOC=1` / `zuvo:adhoc-approved` → pass; (6) docs-only → pass; (7) `block-no-verify`: `commit -n`→2, `push -n`→0; (8) shim: agent `--no-verify`→block, human→pass; (9) malformed payloads → fail-open. Print `SMOKE PASS`/`SMOKE FAIL`.
- [ ] Verify: `bash tests/hooks/smoke-pipeline-entry.sh`
  Expected: `SMOKE PASS`
- [ ] Acceptance Proof:
  - AC G1/G2/G3/G4/G5/G6/G7/G8/G12: full incident caught at push+CI; nudges fire; no-whitelist; escapes; --no-verify; human pass-through; fail-open
    - Surface: integration
    - Proof: `bash tests/hooks/smoke-pipeline-entry.sh`
    - Expected: `SMOKE PASS`
    - Artifact: `zuvo/proofs/smoke-pipeline-entry.txt`
- [ ] Commit: `test(hooks): end-to-end smoke — push+CI guarantee, nudges, no-whitelist, escapes`

## Whole-feature Smoke Proofs

- **SMOKE1 — Unreviewed substantial change is stopped at the guarantee layers; nudges fire; no whitelist**
  - Preconditions: overridable `$HOME`; throwaway repo on a feature branch; substantial unreviewed range vs `merge-base`; no covering `memory/reviews/*`.
  - Proof: `bash tests/hooks/smoke-pipeline-entry.sh` (drives the real `pre-push-gate.sh`, `scripts/zuvo-pipeline-entry-ci.sh`, commit/Stop nudges, `block-no-verify.sh`, and the shim via synthetic payloads).
  - Expected: pre-push exit 1 AND CI script exit 1; commit/Stop print the nudge; a covering review artifact flips both to 0; an unrelated artifact does NOT (no whitelist); `ZUVO_ALLOW_ADHOC`/`zuvo:adhoc-approved` pass; docs-only pass; `commit -n`→2 / `push -n`→0; agent `--no-verify` blocked / human pass-through; malformed→fail-open. Prints `SMOKE PASS`.
  - Artifact: `zuvo/proofs/smoke-pipeline-entry.txt`
