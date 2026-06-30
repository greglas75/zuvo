# Implementation Plan: zuvo:refactor full rebuild — bind the safety spine

**Spec:** inline — no spec
**spec_id:** none
**planning_mode:** inline
**source_of_truth:** inline brief (this conversation's root-cause analysis of skills/refactor/SKILL.md)
**plan_revision:** 2
**status:** Approved
**Created:** 2026-06-30
**Tasks:** 9 (+1 spike, +2 smoke)
**Estimated complexity:** complex (architectural restructure of a 958-line skill + a new cross-harness external enforcement layer)

## Problem (why this rebuild)

In one day, FIVE field refactors run via `zuvo:refactor` failed the same family of ways: ran the
code change + light verification + committed, then skipped or ignored the enforcement spine
(blind-audit, adversarial, remediation, CONTRACT, retro). The skill ALREADY screams MANDATORY in
24 places. Incremental prose/verifier patches (this session) did not bind and introduced
contradictions. Root causes (from the line-by-line analysis):

- RC1 — 958-line monolith, no front-loaded "definition of done"; spine scattered across Phase 3/3.5/4.
- RC2 — "Verification" (a 5-step list) reads as a false terminal; real verification (blind+adversarial) looks optional.
- RC3 — alarm fatigue: 24 MANDATORY/REQUIRED labels, no safety-vs-ceremony hierarchy.
- RC4 — commit (Phase 3.5, ~L651) PRECEDES the gate (~L719/746); the gate never gates.
- RC5 — enforcement is self-attested (the agent that decided to skip runs the verifier, last); no external bind; cross-harness = no Claude hooks fire.
- RC6 — "trivial session" off-ramp + LIGHT-tier mindset legitimize the shortcut.
- RC7 (self-inflicted) — recent verifier patches contradict the trivial-session path, read a GLOBAL `tail -1` retro (wrong-run across repos), and use a fragile `git log -3` fix-commit check.

## Architecture Summary

Two layers, separated by what they do:

1. **BIND (external, deterministic, agent-independent, cross-harness): a git commit-boundary gate.**
   A `pre-commit` (and/or `pre-push`) hook installed into the *target repo* that, when a refactor
   CONTRACT is active for the staged production files, BLOCKS the commit unless the CONTRACT records
   a completed Prove step (blind_audit ∉ {skipped,not_run}, adversarial ∉ {skipped,not_run}, and
   findings either fixed or dispositioned). Git hooks fire for every harness (Claude/Codex/Cursor/
   Antigravity) — this is the only mechanism an agent cannot narrate past. Models on the existing
   `hooks/pre-commit-adversarial-gate.sh` + `hooks/lib/pipeline-gate-lib.sh`.

2. **GUIDE (the skill prose): restructured for a short, ordered, binding-aware happy path.**
   Front-loaded Definition of Done; the canonical order becomes Classify → Plan → Characterize →
   Refactor → **Prove (blind-audit + adversarial + remediation)** → **Gate** → **Commit (LAST)**.
   Ceremony (CONTRACT-schema, retro, docs, curate, review-artifact) demoted to a clearly-labeled
   lower tier; batch/migration/dispatch detail moved to a reference section/include to shrink the core.

The CONTRACT JSON (already exists, `zuvo/contracts/refactor-*.json`) becomes the **artifact of record**
the external gate reads — it is the bridge between the (self-reported) agent run and the (deterministic)
hook. The CONTRACT gains `prove: {blind_audit, adversarial, findings_disposition}` fields the hook checks.

**Design corrections from rev-1 cross-model validation (5 findings, all valid — applied here):**
- **Pre-commit timing = STAGED, not a commit range.** Because Commit is LAST (G2), `HEAD` has not advanced
  when the gate runs; `REFACTOR_SHA..HEAD` is empty. The gate (and the in-skill verifier) check
  `git diff --cached --name-only` against the CONTRACT's `prove` fields — the CONTRACT is the proof, never
  a fix *commit* (remediation is staged, recorded in `prove.findings_disposition`, before the gated commit).
- **Hook resolves the ABSOLUTE zuvo path + fail-OPEN.** The self-installed hook in the target repo's
  `.git/hooks/` must source the gate lib by an absolute global-install path (resolved at install time),
  NOT a path relative to the target repo. If the lib is absent (e.g. zuvo uninstalled), the hook
  `exit 0`s with a one-line warning — it must NEVER fail-closed and brick a user's `git commit`.
- **Human-committer + stale-contract bypass.** The gate is for AI runs. A human committing files that
  intersect an abandoned `stage != COMPLETE` contract is NOT blocked: bypass when no AI-harness env marker
  is present, AND auto-expire contracts older than a TTL (e.g. 24h) or whose run-marker is gone. Prevents a
  crashed AI run from locking a human out of the repo.
- **Never mutate a TRACKED hooks dir.** If `core.hooksPath` points to a version-controlled dir (Husky's
  `.husky/`, etc.), do NOT auto-append (it would leak zuvo infra into the user's committed repo). Print a
  manual-install instruction instead and proceed without the self-install (the in-skill verifier still runs).

## Technical Decisions

- **Trigger:** the gate activates only when a `zuvo/contracts/refactor-*.json` with `stage != COMPLETE`
  exists whose `scope_fence` intersects the staged files. No active refactor contract ⇒ gate is a no-op
  (does not interfere with non-refactor commits). Decided over "scan every commit" to avoid false blocks.
- **Artifact of record = the CONTRACT, not the global retro.** Fixes RC7's global-`tail -1` bug: the gate
  reads the specific contract for the staged files, not the last line of a cross-project log.
- **pre-commit vs pre-push:** install BOTH, mirroring existing infra — pre-commit for immediate feedback,
  pre-push as the harder backstop (`pre-push-gate.sh` pattern). pre-commit is bypassable with `--no-verify`;
  `block-no-verify.sh` already defends that for Claude; pre-push is the cross-harness backstop.
- **Self-install:** the refactor skill installs the gate into the target repo at Phase 0 (idempotent,
  respects an existing `core.hooksPath`, appends rather than clobbers). Escape hatch `ZUVO_ALLOW_ADHOC=1`
  logged, matching the pipeline-gate convention.
- **Keep ALL existing safety prose substance** — restructure/relocate, do not delete the hard-won rules
  (DC3). The three-class model (safety/scope/telemetry) becomes the top-level frame.
- **Reuse, don't reinvent:** `hooks/lib/pipeline-gate-lib.sh` (content-keyed coverage, fail-open, range
  detection) is the model; add `refactor-gate-lib.sh` or extend it.

## Quality Strategy

- The hook + lib are plain shell ⇒ genuine TDD: RED = a test asserting a commit is blocked/allowed; GREEN = the hook.
- Skill-structure changes are checked by deterministic grep assertions (DoD near top; commit after gate; line-count down).
- Build integrity verified by `install.sh` exit 0 + grep of built Codex/Cursor copies (unicode survival).
- Risk areas: (a) hook false-blocking legit non-refactor commits — mitigated by contract-intersection trigger + fail-open; (b) cross-harness portability — covered by the `tests/hooks/test-git-shim.sh` pattern; (c) bypass via `--no-verify` — covered by pre-push backstop + block-no-verify.

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| G1 | Front-loaded Definition of Done at top | goal | Task 6 | |
| G2 | Gate BEFORE commit (commit is last) | goal | Task 6 | reorders Prove→Gate→Commit |
| G3 | Demote ceremony; safety/scope/telemetry tiers visible | goal | Task 6 | |
| G4 | Shrink 958 → short core + reference | goal | Task 7 | |
| G5 | External git-hook bind (agent-independent, cross-harness) | goal | Task 1, 3, 4, 5 | the real fix |
| G6 | Fix 3 self-inflicted contradictions | goal | Task 2 | independent quick win |
| DC1 | Cross-harness (Claude/Codex/Cursor/Antigravity) — bind must not be Claude-only | constraint | Task 1, 3, 4 | git hooks fire for all |
| DC2 | Do not break existing build/install | constraint | Task 8 | |
| DC3 | Preserve existing safety-prose substance (restructure, don't delete) | constraint | Task 6, 7 | |
| DC4 | Idempotent hook self-install; respect existing core.hooksPath; never clobber user hooks | constraint | Task 5 | |

## Review Trail
- Phase 1: direct (small/light scope — markdown+shell rebuild on a just-deep-analyzed indexed repo; Explore sub-agents lack CodeSift and would re-explore weaker). Architecture grounded in this session's line-by-line analysis of SKILL.md.
- Plan reviewer: rev 1 -> direct (Light); rev 2 -> structural fixes from cross-model applied
- Cross-model validation: rev 1 -> executed (multi-provider), **5 findings, ALL valid, ALL applied in rev 2**:
  - CRITICAL (Task 2/6) verifier checked a commit range but commit is LAST → now checks STAGED + CONTRACT. Fixed.
  - CRITICAL (Task 3/5) hook would resolve lib path relative to target repo → now absolute global path + fail-open. Fixed.
  - WARNING (Task 5) zuvo uninstall would brick `git commit` → hook fail-OPENs on missing lib. Fixed.
  - WARNING (Task 5) auto-append to tracked `.husky/` leaks infra → never mutate a tracked hooksPath. Fixed.
  - WARNING (arch) abandoned contract locks out humans → human-committer + stale-contract bypass. Fixed.
- Status gate: Approved (user, 2026-06-30). Executing.
- **[DECISION] (from Task 1 spike, locked):** `prove` schema = `{blind_audit, adversarial, findings_disposition}` on the CONTRACT JSON; gate blocks when `blind_audit ∈ {skipped,not_run,""}` or `adversarial ∈ {skipped,not_run,""}`. AI-harness marker = any of `ZUVO_AI_RUN | CLAUDECODE | CURSOR_TRACE_ID | CODEX_SANDBOX` set (the skill exports `ZUVO_AI_RUN=1`); none set ⇒ human ⇒ bypass. stale-TTL = `ZUVO_GATE_TTL_SEC` default 86400s. Hook fail-OPENs on missing lib. Gate reads STAGED (`git diff --cached`), never a commit range.
- **Task 1 (spike): DONE** — 6/6 cases pass (`zuvo/proofs/task-1-spike.txt`). Architecture + all 5 cross-model fixes validated end-to-end.

## Task Breakdown

### Task 1: Feasibility spike — deterministic cross-harness commit-gate POC
**Files:** scratchpad only (throwaway temp git repo)
**Surface:** integration
**Complexity:** complex
**Dependencies:** none
**Execution routing:** deep implementation tier

- [ ] RED: in a temp repo, a `pre-commit` shell hook + a fixture `zuvo/contracts/refactor-X.json` must drive SIX cases (all reading STAGED state, since commit hasn't happened): (1) `prove.blind_audit="skipped"` → `git commit` of the scope-fence file exits non-zero; (2) `prove.blind_audit="clean:strict"` + `prove.adversarial="clean"` + `prove.findings_disposition="none"` → exit 0; (3) unrelated file, no intersecting contract → exit 0 (NOOP); (4) **fail-open**: gate lib path missing → exit 0 + warning (never bricks commit); (5) **human bypass**: no AI-harness env marker set → exit 0 even with incomplete contract; (6) **stale contract**: contract older than TTL / run-marker gone → exit 0.
- [ ] GREEN: minimal `pre-commit` reading `git diff --cached --name-only`, globbing `zuvo/contracts/refactor-*.json`, intersecting `scope_fence`, checking `prove.*` with `grep`/jq-free portable parsing. Resolve the gate lib via an ABSOLUTE path baked at install time (not relative to the target repo). Decide: the exact CONTRACT `prove` schema; the AI-harness env marker(s) used to detect a human; the stale-contract TTL/run-marker rule.
- [ ] Verify: `bash <scratch>/spike/run.sh` driving the temp repo through all 6 cases
  Expected: `BLOCK | PASS | NOOP | FAIL-OPEN | HUMAN-BYPASS | STALE-BYPASS` all ok (6/6)
- [ ] Acceptance Proof:
  - AC-SPIKE: Surface integration · Proof: scripted temp-repo commit attempts (6 cases) · Expected: exit 1 / 0 / 0 / 0 / 0 / 0 respectively · Artifact: `zuvo/proofs/task-1-spike.txt`
- [ ] Commit: none (spike is throwaway; carry the proven `prove` schema + AI-env marker + TTL + fail-open/human-bypass skeleton into Task 3). Record `[DECISION: prove-schema=<fields>; ai-env-marker=<var>; stale-ttl=<dur>]` in the Review Trail.

### Task 2: Fix the 3 self-inflicted verifier contradictions (independent quick win)
**Files:** `skills/refactor/SKILL.md`
**Surface:** docs
**Complexity:** standard
**Dependencies:** none

- [ ] RED: a grep assertion script proves all three are wrong today: (a) `RETRO: skipped (trivial session)` coexists with verifier `UNPROVEN`-on-no-retro; (b) verifier uses global `tail -1 ~/.zuvo/retros.log`; (c) `git log -3` fix-commit check present.
- [ ] GREEN: reconcile trivial-session — a trivial refactor that legitimately skips retro reaches a defined terminal (`GATE: N/A (trivial — <2 tool calls, no production change)`), not `INCOMPLETE` forever; key the retro lookup to the CURRENT project+sha (match `\trefactor\t<project>\t` and branch/sha) instead of global `tail -1`; **drop the `git log -3` fix-commit check entirely** — it is wrong under commit-last timing (CRITICAL finding). The in-skill verifier checks STAGED state (`git diff --cached`) + the CONTRACT `prove.findings_disposition`, never a fix commit (which does not exist yet at gate time).
- [ ] Verify: `bash -n` on the extracted verifier + a logic test over fixture retro rows (trivial, clean, parked-via-contract, wrong-project)
  Expected: trivial→N/A, clean→PASS, parked(prove.findings_disposition unresolved)→BLOCKED, wrong-project-row→ignored (no false PASS)
- [ ] Acceptance Proof:
  - AC2: Surface docs · Proof: run the fixture-driven verifier test · Expected: 4/4 dispositions correct · Artifact: `zuvo/proofs/task-2-verifier.txt`
- [ ] Commit: `fix(refactor): reconcile trivial-session path + key verifier to current run, drop fragile git-log check`

### Task 3: Author the external refactor-safety gate (hook + lib)
**Files:** `hooks/refactor-safety-gate.sh`, `hooks/lib/refactor-gate-lib.sh` (or extend `pipeline-gate-lib.sh`)
**Surface:** integration
**Complexity:** complex
**Dependencies:** Task 1
**Execution routing:** deep implementation tier

- [ ] RED: `tests/hooks/test-refactor-safety-gate.sh` (authored here as the RED suite) asserts `refactor_gate_check <staged-files>` returns BLOCK/PASS/NOOP for fixture contracts (incomplete prove / complete prove / no intersecting contract), **fail-OPEN** on malformed contract AND on missing gate lib (the uninstall-safety case — exit 0, never 127), **human-bypass** (no AI-env marker → PASS), **stale-bypass** (contract past TTL → PASS), and logs an escape when `ZUVO_ALLOW_ADHOC=1`.
- [ ] GREEN: implement the lib (port the spike; reuse pipeline-gate-lib range/intersection helpers) + the `pre-commit` and `pre-push` entry scripts. The entry scripts source the lib by an ABSOLUTE install-time path and wrap it so a missing lib → `exit 0` + warning (fail-open). All checks read STAGED state, not commit ranges.
- [ ] Verify: `bash tests/hooks/test-refactor-safety-gate.sh`
  Expected: `ALL PASS` (block/pass/noop/fail-open/escape-logged)
- [ ] Acceptance Proof:
  - AC3: Surface integration · Proof: the test suite above · Expected: all cases green · Artifact: `zuvo/proofs/task-3-gate.txt`
- [ ] Commit: `feat(hooks): refactor-safety commit-gate — cross-harness, contract-keyed, fail-open`

### Task 4: Cross-harness + bypass hardening tests for the gate
**Files:** `tests/hooks/test-refactor-safety-gate.sh` (extend), reuse `tests/hooks/test-git-shim.sh`
**Surface:** integration
**Complexity:** standard
**Dependencies:** Task 3

- [ ] RED: add cases — gate fires under a simulated non-Claude env (git-shim), and `git commit --no-verify` is caught by the pre-push backstop (mirror `test-block-no-verify.sh` / `test-pre-push-gate.sh`).
- [ ] GREEN: any lib adjustments needed to pass (portable shell only; no bashisms that break under dash/zsh).
- [ ] Verify: `bash tests/hooks/test-refactor-safety-gate.sh && bash tests/hooks/test-pre-push-gate.sh`
  Expected: both suites green
- [ ] Acceptance Proof:
  - AC4 (DC1): Surface integration · Proof: cross-harness + no-verify suites · Expected: gate binds regardless of harness/bypass · Artifact: `zuvo/proofs/task-4-crossharness.txt`
- [ ] Commit: `test(hooks): refactor-gate cross-harness + --no-verify backstop coverage`

### Task 5: Refactor skill self-installs the gate into the target repo (Phase 0, idempotent)
**Files:** `skills/refactor/SKILL.md` (Phase 0 bootstrap), optional `scripts/install-refactor-gate.sh`
**Surface:** integration
**Complexity:** complex
**Dependencies:** Task 3

- [ ] RED: `tests/hooks/test-refactor-gate-install.sh` — install in a fresh temp repo creates the pre-commit + pre-push gate; re-run is idempotent (no duplicate); an UNTRACKED existing `core.hooksPath` is respected (gate chained, user hooks preserved); a **TRACKED hooksPath (e.g. `.husky/` under version control) is NOT mutated** — instead a manual-install instruction is printed and self-install is skipped (no staged change to the user's tracked files); the installed hook bakes an ABSOLUTE zuvo lib path and fail-opens if that path later disappears.
- [ ] GREEN: the install snippet (Phase 0) + helper; idempotency marker; `core.hooksPath` detection that distinguishes tracked vs untracked (`git ls-files --error-unmatch <hooksPath>`); absolute-path baking; fail-open wrapper.
- [ ] Verify: `bash tests/hooks/test-refactor-gate-install.sh`
  Expected: `installed | idempotent | untracked-hooksPath-chained | tracked-hooksPath-NOT-mutated | user-hook-preserved | absolute-path-baked` (6/6)
- [ ] Acceptance Proof:
  - AC5 (DC4): Surface integration · Proof: the install test · Expected: idempotent, non-clobbering, never mutates tracked hooks, absolute-path + fail-open · Artifact: `zuvo/proofs/task-5-install.txt`
- [ ] Commit: `feat(refactor): self-install commit-gate into target repo at Phase 0 (idempotent)`

### Task 6: Restructure SKILL.md core — front-load DoD, reorder Prove→Gate→Commit, tier the rules
**Files:** `skills/refactor/SKILL.md`
**Surface:** docs
**Complexity:** complex
**Dependencies:** Task 2, Task 5

- [ ] RED: grep-assertion script (RED) currently FAILS: no `## Definition of Done` in the first ~45 lines; the commit step appears BEFORE the gate; "Verification" used as a terminal label.
- [ ] GREEN: add a ≤14-line `## Definition of Done (non-negotiable)` block right after the H1 — the 4 safety gates + "a refactor is BLOCKED until proven; the external commit-gate enforces this." Reorder so the canonical path ends Prove (blind+adversarial+remediation) → Gate (verifier + the now-external hook) → **Commit LAST**. Rename/reframe the "Verification" 5-step as "self-check (mid-pipeline, NOT done)". Promote the safety/scope/telemetry three-tier frame to the top. Write the CONTRACT `prove` fields (from Task 1) at the Prove step so the hook has its artifact.
- [ ] Verify: the grep-assertion script now PASSES: `grep -n "## Definition of Done" within first 45 lines`; commit step line-number > gate line-number; no terminal "Verification = done" phrasing; `prove.blind_audit` written in the Prove section.
  Expected: `5/5 assertions pass`
- [ ] Acceptance Proof:
  - AC-G1/G2/G3 (DC3): Surface docs · Proof: structural grep-assertion script · Expected: DoD front-loaded + commit-after-gate + tiers visible + safety prose retained (grep the preserved rules still present) · Artifact: `zuvo/proofs/task-6-structure.txt`
- [ ] Commit: `refactor(refactor-skill): front-load Definition of Done, gate-before-commit, tier the rules`

### Task 7: Shrink — move reference detail out of the core path
**Files:** `skills/refactor/SKILL.md`, `shared/includes/refactor-reference.md` (new)
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 6

- [ ] RED: `wc -l skills/refactor/SKILL.md` > 700 today (after Task 6 additions); core happy-path not skimmable in one screen.
- [ ] GREEN: relocate CONTRACT JSON schema, v2→v3 migration, batch-mode sub-sections, and sub-agent dispatch boilerplate into `shared/includes/refactor-reference.md` (loaded on demand), leaving a short pointer in the core. Keep the binding spine inline.
- [ ] Verify: `wc -l skills/refactor/SKILL.md` (target ≤ ~600) AND `grep -c '../../shared/includes/refactor-reference.md' skills/refactor/SKILL.md` ≥ 1 AND the reference file resolves
  Expected: core ≤ ~600 lines, reference linked, no dangling include
- [ ] Acceptance Proof:
  - AC-G4: Surface docs · Proof: line-count + include-resolution check · Expected: shorter core, reference reachable · Artifact: `zuvo/proofs/task-7-shrink.txt`
- [ ] Commit: `refactor(refactor-skill): move CONTRACT/batch/dispatch detail to refactor-reference include`

### Task 8: Build + install integration (ship gate to all harnesses)
**Files:** `scripts/install.sh`, `scripts/build-codex-skills.sh` / `build-cursor-skills.sh` if needed
**Surface:** config
**Complexity:** standard
**Dependencies:** Task 3, Task 4, Task 7

- [ ] RED: `./scripts/install.sh` today does not ship `hooks/refactor-safety-gate.sh` / `refactor-gate-lib.sh` to Codex/Cursor/Antigravity caches (grep built copies — absent).
- [ ] GREEN: extend install/build to ship the new hook + lib + reference include to all four targets; ensure unicode in the verifier/DoD survives normalization.
- [ ] Verify: `./scripts/install.sh` exit 0 AND built copies contain the intact gate
  Expected: `install exit 0; gate present in ~/.codex + cache; awk/regex intact`
- [ ] Acceptance Proof:
  - AC-DC2: Surface config · Proof: install run + built-copy grep · Expected: exit 0, gate shipped intact, nothing else regressed · Artifact: `zuvo/proofs/task-8-install.txt`
- [ ] Commit: `build: ship refactor-safety gate + refactor-reference to all harnesses`

### Task 9: Docs + release decision (always-run gate task)
**Files:** `docs/pipeline.md`, `CLAUDE.md` (if the skill-conventions/enforcement section needs it)
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 6, Task 8

- [ ] RED: `grep -i 'refactor.*gate' docs/pipeline.md` — enforcement layer table does not yet mention the refactor commit-gate.
- [ ] GREEN: document the new refactor enforcement layer (mirror the pipeline-entry layer table); print an explicit decision marker for the version bump.
- [ ] Verify: `grep -i 'refactor.*commit-gate' docs/pipeline.md` matches AND a `[DECISION: version bump = minor|patch — <reason>] → COMPLETE` line is printed
  Expected: docs updated + decision recorded (gate task never silently no-ops)
- [ ] Acceptance Proof:
  - AC9: Surface docs · Proof: grep docs + decision marker · Expected: documented + version decision explicit · Artifact: `zuvo/proofs/task-9-docs.txt`
- [ ] Commit: `docs(pipeline): document refactor commit-gate enforcement layer`

## Whole-feature Smoke Proofs

- **SMOKE1 — end-to-end: the gate actually blocks a spine-skipping refactor**
  - Preconditions: temp git repo with the gate self-installed (Task 5) + a refactor CONTRACT whose `prove.blind_audit="skipped"`.
  - Proof: stage the scope-fence file, run `git commit`; then set `prove` to a completed state (blind_audit/adversarial recorded non-skipped, findings fixed/dispositioned) and `git commit` again.
  - Expected: first commit REJECTED by the gate (non-zero, clear message); second commit ALLOWED.
  - Artifact: `zuvo/proofs/smoke-gate-blocks-skip.txt`
- **SMOKE2 — cross-harness + bypass**
  - Preconditions: same repo, simulated non-Claude env (git-shim), `--no-verify` attempted.
  - Proof: attempt the spine-skipping commit with `--no-verify`; attempt a push.
  - Expected: pre-push backstop REJECTS the push even when pre-commit was bypassed; gate fires identically under the non-Claude shim.
  - Artifact: `zuvo/proofs/smoke-crossharness-bypass.txt`

## Execution Record (2026-06-30 — ALL TASKS DONE)

- Task 1 spike DONE (6/6) — architecture validated; design decisions locked.
- Tasks 3+4 DONE (7e50d7d) — gate lib + entry + tests (6 cases + --no-verify backstop), ALL PASS.
- Task 5 DONE (280fd72) — self-install (idempotent, fail-open, never clobbers, never mutates tracked hooksPath); targeting fixed for the zuvo global-dispatcher (installs to .git/hooks which the dispatcher bridges to).
- Task 6 (+ Task 2 subsumed) DONE (aa2332c) — DoD front-loaded, Prove→Gate→Commit, CONTRACT prove fields, verifier reads CONTRACT; 3 contradictions fixed; logic verified on 5 fixtures.
- Task 7 DONE (731ee3e) — SKILL.md 997→810 (CONTRACT schema + Batch Mode → refactor-reference include).
- Task 8 DONE (ddf89af) — install ships gate + self-installer; Phase 0 path transform fixed; install.sh exit 0, 4 providers.
- Task 9 DONE (25928d8) — docs/pipeline.md refactor commit-gate section; [DECISION: version bump = minor].
- SMOKE DONE — end-to-end with the REAL installed gate: ALL PASS (block / allow / --no-verify backstop / human-bypass).
