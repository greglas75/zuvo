# Implementation Plan: backlog noise bar — follow-ups

**Spec:** inline — no spec
**spec_id:** none
**planning_mode:** inline
**source_of_truth:** inline brief (owner decisions 2026-10-17, from the open questions of
`memory/reviews/2026-10-16-backlog-noise-bar-part2.md`)
**plan_revision:** 1
**status:** Approved
**Created:** 2026-10-17
**Tasks:** 2
**Estimated complexity:** 1 standard, 1 standard

## Decisions

| Open question | Decision |
|---|---|
| 1. Where build keeps its snapshot and `backlog-writes:` | A sidecar, `zuvo/context/build-backlog.md`, written beside the plan block, so a compacted run still commits what it wrote |
| 2. A pending-close marker for fixed, uncommitted entries | None. The fix skills already list `Close after commit: B-…`, and the commit that carries the fix closes them (the `Fixes #N` convention). No format change |
| 3. An `image:` target kind | Yes: `image:<reference>`. `redis:7` is no longer read as host `redis`, port 7, and two images never share a hand-made slug |
| 4. `ZUVO_BACKLOG_ADMIT` for humans only | Not changed. The backlog skill's `add` mode is an agent acting on the user's own request, and nothing in a shell can tell who typed it. It stays env-only and visible (`forced: true` on every record it forces) |

Phase 1: direct (small/light scope).

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) |
|---|---|---|---|
| D3 | `image:` target kind | requirement | Task 1 |
| D1 | build's durable backlog-writes | requirement | Task 2 |

## Task Breakdown

### Task 1: `image:` target kind in backlog-add
**Files:** scripts/zuvo-home/zuvo_backlog_admit.py, tests/hooks/test_backlog_admit.py,
shared/includes/backlog-protocol.md, skills/container-audit/SKILL.md
**Surface:** backend-logic
**Complexity:** standard
**Dependencies:** none
**Failure:** halt

- [ ] RED: `target_kind("image:redis:7") == "image"`; `redis:7` without the prefix stays `host`;
  malformed references (uppercase repository, empty tag, bad digest, spaces) give None; a fingerprint
  keeps tag case (`v1` ≠ `V1`), treats `docker.io/library/nginx` as `nginx`, and separates
  `org/app:1` from `org-app:1`; the B-id stems on the last repository component; an image target
  without `--evidence` is refused `missing-field:evidence`.
- [ ] GREEN: `_IMAGE_RE` (OCI reference: optional registry host[:port], lowercase path components,
  optional tag, optional digest), kind `image` in `target_kind`, `_TARGET_CLASSES`, `_target_key`
  (no lowercasing; Docker Hub default prefixes removed) and `_stem`.
- [ ] Protocol: the `--target` row, the `bad-target` and `bad-combination` rows, the identity
  sentence, the live-target filing row and the location rule name `image:`.
- [ ] container-audit: a finding on an image with no repository file naming it takes
  `--target "image:$I"`, replacing the `subject:container-image-<slug>` fallback; the CQ
  "reported only" exception goes away.
- [ ] Verify: `rt --light` on `tests/hooks/test_backlog_admit.py`, `test_backlog_add.py`, the prose
  guard and the prose-commands test. Expected: all pass, pins unchanged or re-pinned with reason.
- [ ] Acceptance Proof: AC-image — `backlog-add --target image:redis:7 --class SEC --evidence …` in a
  scratch repo prints ACCEPTED with a B-id stemmed `redis`; `--target redis:7` still files a host.
  Artifact: `zuvo/proofs/task-1-report.md`.
- [ ] Commit: `backlog-add: an image: target kind, so redis:7 is no longer read as a host`

### Task 2: build keeps its backlog writes in a sidecar
**Files:** skills/build/SKILL.md, tests/hooks/test-backlog-prose-commands.sh (only if a pin moves)
**Surface:** docs
**Complexity:** standard
**Dependencies:** none
**Failure:** halt

- [ ] Change: Phase 0 step 4 also writes the snapshot to `zuvo/context/build-backlog.md`
  (`branch:`, `base:` and the fenced snapshot), overwritten only at a run's original start; every
  `wrote=` path is appended there as it is printed. The closing commit reads the plan block, or this
  file when the plan block is no longer in context.
- [ ] Verify: the prose guard and the prose-commands test pass.
- [ ] Acceptance Proof: AC-build — the build text names the sidecar at the snapshot, the write and
  the closing commit; the prose tests pass. Artifact: `zuvo/proofs/task-2-report.md`.
- [ ] Commit: `build: keep the backlog snapshot and writes in a sidecar that survives a compaction`

## Whole-feature Smoke Proofs

Not applicable: two independent changes; Task 1's acceptance proof is its end-to-end run.
