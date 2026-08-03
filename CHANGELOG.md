# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [1.6.54] — 2026-08-03

A hardening release. Most of it removes defects of one shape: **a mandated step
that could not actually run** — a section sealed inside a code fence, a gate
whose condition no real input satisfies, a grade band that leaves real scores
ungraded, a checklist that reports a file as read when nothing told the agent to
read it. Several were found by tooling added in this same release, and several
of the fixes turned out to contain the very defect they were fixing.

### Added

- **Per-task failure strategy and telemetry** (from #1). A plan task can now
  declare its own failure strategy instead of inheriting one global retry
  policy, and `verify-plan-dag` rejects `skip-and-continue` on a task something
  else depends on. `zuvo:execute` honours a declared skip without weakening the
  never-silently-skip rule, reports ACs left unproven by skipped or blocked
  tasks, and persists per-task telemetry to `zuvo/context/task-telemetry.jsonl`
  — `runs.log` is per-run, but the hotspots are per-task.
- **Category as a single source of truth** (from #1). Every `SKILL.md`
  frontmatter now declares `category:`, and `validate-skills.sh` checks the
  per-category counts against it. The category column in the docs used to be
  summed but never compared against reality; `dev-push.sh` now also syncs the
  marketplace skill count before pushing, which had gone stale in both
  published files.
- **`zuvo:container-audit`** — 57th skill. Docker/compose security audit across
  K1-K6 (base-image provenance, privilege/runtime hardening, secret and
  build-context hygiene, image size, CVEs, healthchecks), with reserved K7-K10
  behind `--k8s`. Static analysis only: no daemon access, and image pulls are
  consent-gated and default-denied in CI. Ships with a labelled fixture corpus
  and a behavioral eval suite.
- **`scripts/check-skill-structure.py`** — structural lint for the two defect
  classes that survive careful reading, wired into `validate-skills.sh` and
  covered by `tests/gates/test-skill-structure.sh`:
  - *mis-paired code fences*, tracked with real CommonMark rules. A parity count
    of ``` proves nothing — a fence closed in the wrong place still counts even.
  - *loading-list integrity* — sequential ordinals, and no file printed as READ
    that no prose entry told the agent to read.
  Replayed against the previous release it reports 33 findings across 19 files,
  including two nobody had found by hand.
- **`scripts/verify-review-claims.py`** — checks a review's Validity Gate claims
  against the harness transcript, closing the self-attestation gap.
- Dimension additions: `D11 Supply-Chain Integrity` (dependency-audit),
  `D12 OWASP API Security Top 10` (api-audit, `--security`),
  `S15.9 MCP & Tool-Invocation Security` (security-audit).

### Fixed

- **Proof-path traversal in `review-artifact-sync.sh`.** The containment rule
  lives in three places; a prior hardening updated two. `do_sync()` tested the
  ref without a leading slash, so `../x` matched neither traversal pattern and
  was copied outside both checkouts. `../../x` still matched, which is why a
  two-segment test case hid it. Now covered by an end-to-end regression test
  that drives the real script and was verified to fail against the prior code.
- **Retrospective and validity-gate instructions buried inside code fences** in
  8 skills. A completion block opened a fence, printed the `Run:` line and never
  closed it, so the retro protocol and the `append-runlog` mandate rendered as
  sample output — the steps the retro gate exists to enforce. Two report
  templates additionally nested same-length fences, inverting every fence to end
  of file.
- **Read-only mandates lost to unclosed fences** in `plan/agents/architect.md`
  (its whole `## Constraints` section, including "You are read-only") and
  `skill-eval/agents/grader.md`. The lint above did not scan agent files; it now
  covers 107 files instead of 57.
- **`no-pause-protocol.md` printed as READ but never listed to read** in
  content-fix, geo-fix, seo-fix and structure-audit — the HARD rule against
  mid-batch pauses, silently dropped by duplicate ordinals in 8 skills.
- **Score bands that leave real scores ungraded** — 15 across quality-gates,
  q-scoring-protocol, code-audit, test-audit, build, design-review,
  mutation-test, security-audit, api-audit, container-audit and
  ship/agents/coverage-check. Fixing the gaps first introduced a *dead* band
  (middle rows written in fractions between neighbours in percent, making
  CONDITIONAL PASS unreachable); both directions are now inequalities in one
  unit.
- **`rules/testing.md` scored against a frozen denominator** and counted N/A as
  a pass, while its own example three lines below used percent-of-applicable.
  Four skills load that file in full.
- **Critical gates that could never fire** across the infra-audit family and
  container-audit, where `Kn=0` / `Dn=0` conditions were unreachable because the
  dimension spreads several checks over its weight.
- **`verify-review-claims.py --strict` returned success when no transcript could
  be found** — delete the evidence, pass the verifier. Now exits 2
  ("could not check"), never 0, and still never accuses on absent data.
- `adversarial-review` invoked with a literal `[date]` placeholder in
  content-audit, code-audit and geo-audit, burning the whole cross-model pass.
- `install.sh` no longer copies `skills/tmp-*` test fixtures into the install
  cache.
- **"Shipped" meant "not shipped" on two of four platforms** (from #1) — push is
  part of shipping, and `zuvo:ship` did not treat it that way.
- The retro reader counted absent fields as failures (from #1).

### Changed

- `docs/runbook/testing.md` documents the structural lint, and adds a triage row
  for a finding worth knowing: this repo's hook tests fail on the i9 test farm
  and pass locally, because they assert on real git state, `~/.claude`, `~/.zuvo`
  and gitignored artifacts the farm's mirror does not carry. Environment
  mismatch, not a regression.
