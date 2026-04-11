# Implementation Plan: Zuvo Compressed Response Protocol

**Spec:** docs/specs/2026-04-11-compressed-response-protocol-spec.md
**spec_id:** 2026-04-11-compressed-response-protocol-1447
**plan_revision:** 1
**status:** Approved
**Created:** 2026-04-11
**Tasks:** 4
**Estimated complexity:** 3 standard + 1 complex

---

## Architecture Summary

- **`shared/includes/compressed-response-protocol.md`** -- canonical v1 response contract. Defines `STANDARD`, `TERSE`, `STRUCTURED_TERSE`, protected literals, override order, and the `[...truncated...]` escape hatch.
- **`hooks/session-start`** -- injects router + optional protocol + optional project profile into hook-enabled main assistant sessions. Honors `ZUVO_RESPONSE_PROTOCOL=off`.
- **`skills/using-zuvo/SKILL.md`** -- top-level response surface policy so the router makes protected vs working surfaces explicit.
- **Docs + shell validation** -- operator docs explain scope and kill switch; shell scripts verify wiring and fixture-based eval behavior without requiring live provider calls.

## Technical Decisions

- v1 scope stays **hook-enabled main assistant responses only**. No global agent-preamble rollout.
- Final output blocks, repo-written artifacts under `docs/`, `memory/`, `.interface-design/`, and explicit user requests for depth stay `STANDARD`.
- Working chatter defaults to `TERSE`; findings/checklists default to `STRUCTURED_TERSE`.
- Behavioral evaluation uses a **fixed local corpus** with baseline/protocol snapshots. This keeps the repo testable without network or model credentials.

## Quality Strategy

- Verify the kill switch by running `hooks/session-start` with and without `ZUVO_RESPONSE_PROTOCOL=off`.
- Keep the injected protocol short; avoid swelling startup payload size.
- Preserve all technical literals exactly in fixtures: paths, commands, env vars, dates, versions, and quoted errors.
- Use fixture metadata to assert expected surface/mode labels instead of pretending shell code can infer every live turn correctly.

## Task Breakdown

### Task 1: Approve spec and wire protocol into session-start
**Files:** spec metadata, new shared include, `hooks/session-start`
**Complexity:** standard

- [ ] Update spec status to `Approved` and stamp `approved_at`
- [ ] Create `shared/includes/compressed-response-protocol.md`
- [ ] Inject the protocol from `hooks/session-start`
- [ ] Honor `ZUVO_RESPONSE_PROTOCOL=off`
- [ ] Verify:
  - `CODEX_PLUGIN_ROOT=1 ./hooks/session-start | grep "Compressed Response Protocol"`
  - `ZUVO_RESPONSE_PROTOCOL=off CODEX_PLUGIN_ROOT=1 ./hooks/session-start | grep -q "Compressed Response Protocol" && exit 1 || true`

### Task 2: Add router and docs guidance
**Files:** `skills/using-zuvo/SKILL.md`, `docs/configuration.md`, `docs/getting-started.md`
**Complexity:** standard

- [ ] Add a short response-surface policy to the router
- [ ] Document hook-enabled scope, protected surfaces, and degraded mode
- [ ] Document the `ZUVO_RESPONSE_PROTOCOL=off` kill switch
- [ ] Verify:
  - `rg -n "Response Surface Policy|ZUVO_RESPONSE_PROTOCOL|degraded mode" skills/using-zuvo/SKILL.md docs/configuration.md docs/getting-started.md`

### Task 3: Add fixture corpus and validation scripts
**Files:** `scripts/validate-response-protocol.sh`, `scripts/eval-response-protocol.sh`, `tests/fixtures/response-protocol/**`
**Complexity:** complex

- [ ] Create static validator for file presence, grep contracts, and kill-switch behavior
- [ ] Create local eval runner for baseline vs protocol snapshots
- [ ] Add a manifest with representative working and protected surfaces
- [ ] Support `--scenario verbose-override` and `--scenario readability-sheet`
- [ ] Verify:
  - `bash scripts/validate-response-protocol.sh`
  - `bash scripts/eval-response-protocol.sh`
  - `bash scripts/eval-response-protocol.sh --scenario verbose-override`
  - `bash scripts/eval-response-protocol.sh --scenario readability-sheet`

### Task 4: Run verification and summarize residual risk
**Files:** none
**Complexity:** standard

- [ ] Run static validation and fixture eval
- [ ] Smoke-check `hooks/session-start` JSON output
- [ ] Note residual limitation: hookless/direct-skill sessions remain degraded in v1
