# Implementation Plan: zuvo:leads

**Spec:** docs/specs/2026-04-17-zuvo-leads-spec.md
**spec_id:** 2026-04-17-zuvo-leads-1438
**planning_mode:** spec-driven
**source_of_truth:** approved spec
**plan_revision:** 3
**status:** Approved
**Created:** 2026-04-17
**Tasks:** 17
**Estimated complexity:** 10 standard / 7 complex (Task 15 reclassified from standard → complex per adversarial review)

## Architecture Summary

`zuvo:leads` is a new skill in the zuvo-plugin (markdown-only Claude Code / Codex / Cursor plugin). The orchestrator — `skills/leads/SKILL.md` — runs a 7-phase pipeline: Phase 0 bootstrap + tool-probe, Phase 1 discovery (optional), Phase 2 contact extraction, Phases 3-4 email synthesis + LLM verbatim validation (inline), Phase 5 dedup + GDPR flagging, Phase 6 atomic write, Phase 7 run log + retro. Three sub-agents handle isolatable work: `company-finder`, `contact-extractor`, `lead-validator`. Two new shared includes (`lead-output-schema.md`, `lead-source-registry.md`) codify the output contract and source strategies. No new runtime code dependencies; external tools (`dig`, `theHarvester`, `whois`, SMTP) are probed at startup with graceful degradation. Reference patterns: `write-article` (phase-gated orchestrator + tool probing + graceful degradation + mode split) and `pentest` (3-parallel-agent cap + candidate dedup + subprocess probing). Blast radius: 6 existing files modified — routing, three manifests, docs/skills.md, .gitignore.

## Technical Decisions

**Patterns:**
- Phase-gated orchestrator with numbered output blocks (write-article)
- Tool-probe + graceful degradation with `providers_degraded[]` run-header field (pentest Phase 0.5)
- Parallel agent dispatch capped at 3 globally (pentest, write-article)
- Blind validator agent (receives output + rules only; write-article anti-slop-reviewer)
- Canonical-key dedup at orchestrator level; agents never dedup among themselves (pentest Phase 2)
- Mode fork via argument probe: `--domains` → enrichment; `--industry`/`--geo` → discovery
- JSONL checkpoint (append-only, truncate-last-line-on-resume — survives partial writes)
- Atomic `.tmp` → rename written in the same directory as the final file (same-filesystem requirement)

**Libraries / dependencies:** No new code dependencies — markdown-only. External CLI tools probed at Phase 0: `dig` (required for MX), `theHarvester` (optional OSINT), `whois` (optional registrant lookup), SMTP port-25 reachability (probed once at Phase 0, not lazily on first use). Claude Code native `WebSearch` and `WebFetch` required for discovery mode.

**File structure:** 6 new files, 6 modified. Orchestrator SKILL.md estimated 400-500 lines (within precedent: `pentest` SKILL.md ~688 lines, `write-article` SKILL.md ~290 core + ~750 total). Highest-risk files: orchestrator (density) and `contact-extractor` agent (most external I/O). Mitigation: externalize all data definitions to `lead-output-schema.md` and all query/subprocess templates to `lead-source-registry.md`.

**Skill-count resolution** (pre-existing discrepancy confirmed by Architect): `package.json` says "51 skills" (content-only count); `.claude-plugin/plugin.json` + `.codex-plugin/plugin.json` say "52 skills" (directory count including `using-zuvo` router). After this PR: `package.json` → "52", `plugin.json` × 2 → "53", `docs/skills.md` → "52", `using-zuvo/SKILL.md` banner → "53 skills".

## Quality Strategy

**Test framework:** Bats (`bats-core`) for test harness, standalone `bash` validation scripts for heavy lifting. Convention established by `scripts/tests/banned-vocabulary.bats` + `scripts/validate-banned-vocabulary*.sh`: validation scripts emit `PASS` / `FAIL: <reason>` + exit codes; Bats wraps them in `mktemp -d` sandboxes with PATH-substitution mocks. Fixtures committed to `scripts/tests/fixtures/leads-*/`.

**Active CQ gates:** CQ3 (boundary validation — 12 flags + 5 env vars + file inputs), CQ5 (PII — skill collects contact data; run log must NOT echo values), CQ6 (unbounded data — `--max-results` cap must be strict), CQ8 (external calls — every network call needs explicit timeout + degradation), CQ19 (API contract — `lead-output-schema.md` is the single source of truth; no inline schema restatements), CQ21 (concurrency — agents emit results to orchestrator; orchestrator merges serially; lock file atomic), CQ22 (cleanup — `.lock` + `.checkpoint` released on every exit path including SIGINT).

**Top risks (QA Engineer ranked):**
1. **SMTP mock seam** — inline SMTP probe has no clean injection point; must be wrapped in a named helper overridable via `ZUVO_SMTP_PROBE_CMD` env var (mirrors `ZUVO_REVIEW_PROVIDER` pattern)
2. **LLM-variable extraction eval** — `leads-llm-extraction-eval.sh` uses Claude as the extractor; advisory-only CI gate; assertions on field presence (non-null), not exact strings
3. **Checkpoint race under parallel agents** — agents MUST NOT write checkpoint files directly; orchestrator merges
4. **`--domains` path traversal** — Phase 0 must reject paths outside `docs/`, `scripts/`, or CWD
5. **Routing regression** — after adding routing entry, assert new keyword does not shadow existing skills
6. **Atomic-rename cross-mount** — `.tmp` file must be written in same directory as final target (same FS)

**Test strategy per component:** See Coverage Matrix + individual task RED steps.

## Coverage Matrix

Every spec acceptance item maps to at least one task below. Ship criteria (SC1-SC18) and Success criteria (SU1-SU6) from the spec.

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| SC1 | Zero-key run produces non-empty output against fixtures | requirement | Task 7, Task 8 | fixture smoke |
| SC2 | Auto-detects mode (`--domains` vs `--industry`) | requirement | Task 6 | orchestrator Phase 0 |
| SC3 | Every contact record includes all required Data Model fields | requirement | Task 1, Task 6 | schema foundation + writer |
| SC4 | LLM-extracted emails not in source HTML → `llm-inferred`, never promoted | requirement | Task 4, Task 6 | contact-extractor validation pass |
| SC5 | Catch-all detection labels all emails from catch-all domain | requirement | Task 10 | catch-all test + orchestrator probe |
| SC6 | `--max-results` cap stops cleanly; `status: complete-at-cap` written | requirement | Task 6, Task 8 | orchestrator + smoke assert |
| SC7 | Interactive checkpoints + `--no-interactive` auto-continues with `[AUTO-CHECKPOINT]` audit entry | requirement | Task 6 | orchestrator |
| SC8 | All 3 output formats written (CSV + JSON + Markdown), UTF-8 BOM on CSV, valid JSON | requirement | Task 1, Task 6, Task 8 | schema + writer + smoke |
| SC9 | Atomic write: only `.tmp`, `.checkpoint`, `.lock`, `.quarantine` during run | requirement | Task 6, Task 8 | orchestrator + smoke assert no `.tmp` after clean exit |
| SC10 | SIGINT → checkpoint flush → `--resume` recovers all pre-SIGINT records | requirement | Task 6, Task 11 | orchestrator + resume test |
| SC11 | Concurrent runs blocked by `.lock` with clear message | requirement | Task 6, Task 11 | orchestrator + resume test validates lock |
| SC12 | Port 25 blocked detected at startup with one-time warning | requirement | Task 6 | orchestrator Phase 0 |
| SC13 | API keys only from env/config; config file perm check | requirement | Task 6 | orchestrator Phase 0 |
| SC14 | robots.txt check before every WebFetch | requirement | Task 4, Task 6 | contact-extractor + live-probe-protocol reuse |
| SC15 | `--gdpr-strict` → strip phones for EU/EEA, generate GDPR_NOTICE.txt | requirement | Task 5, Task 6 | lead-validator flagging + orchestrator stripping |
| SC16 | Dedup against existing CSV: 100% suppression, normalized keys | requirement | Task 12 | dedup fixtures + test |
| SC17 | `Run:` TSV appended to `~/.zuvo/runs.log` with correct VERDICT | requirement | Task 6 | orchestrator Phase 7 |
| SC18 | Retrospective completed per `retrospective.md` | requirement | Task 6 | orchestrator Phase 7 |
| SU1 | LLM extraction accuracy ≥80% on 20-fixture eval | advisory (was success) | Task 9 | LLM model variance makes strict CI gating unreliable; demoted to tracked KPI per cursor-1 adversarial finding. Tracked in retrospectives; regression triggers manual review, not release block |
| SU2 | No hallucinated verbatim-source emails (verified/unverified) | success (BLOCKING) | Task 9 | The verbatim-source check is deterministic (substring match on fetched HTML) — this CAN and MUST gate CI. Task 9 script asserts zero false-positive `verified`/`unverified` labels on non-verbatim emails; failing this fails the release gate |
| SU3 | Catch-all detection coverage 100% on known fixtures | success | Task 10 | catch-all test |
| SU4 | Resume recovers ≥95% after SIGKILL mid-run | success | Task 11 | resume-resilience test |
| SU5 | Zero-key pathway ≥5 populated emails in 10-result fixture run | success | Task 8 | zero-key smoke |
| SU6 | Dedup accuracy 100% when --dedup-against supplied | success | Task 12 | dedup test |
| G1 | New skill `zuvo:leads` discoverable via router | deliverable | Task 14 | routing entry in using-zuvo |
| G2 | Skill count manifests updated | deliverable | Task 15 | package.json, plugin.json × 2, docs/skills.md |
| G3 | `docs/leads/` gitignored | constraint | Task 16 | .gitignore |
| G4 | All validation scripts bundled in Bats wrapper | deliverable | Task 13 | leads.bats |
| G5 | Schema source of truth (CQ19) | constraint | Task 1 | lead-output-schema.md |
| G6 | Source strategy registry (externalized templates) | constraint | Task 2 | lead-source-registry.md |

## Review Trail

- Plan reviewer: revision 1 → APPROVED (all 8 checks pass; 2 non-blocking observations on fixture task sizes)
- Cross-model validation: revision 1 → warnings + fixes. Providers: codex-5.3, gemini, cursor-agent (claude auto-excluded as writer host). 4 CRITICAL findings, 11 WARNING — all CRITICALs and high-confidence WARNINGs fixed in revision 2.
  - CRITICAL fixes applied:
    - **codex-1:** Task 17 Verify now runs `LEADS_SLOW=1 bats`, dry-run assertions, and gitignore check via new `scripts/verify-leads-release.sh`
    - **gemini-1:** Task 6 RED item (k) now specifies `mkdir .lock` atomic acquisition (not `echo $$ > .lock`) + (k2) stale-lock PID liveness detection for SIGKILL orphan recovery
    - **gemini-2:** Task 3 GREEN now requires `role_context` field passed through `candidate_companies.json` so contact-extractor can conditionally trigger GitHub enrichment
    - **cursor-1:** Task 16 Verify now uses repo-relative `.gitignore` path with `cd` prefix (portable)
  - WARNING fixes applied:
    - **gemini-4:** Task 5 GREEN clarifies validator LABELS records with dedup keys but does NOT dedup; orchestrator does dedup in Phase 5 (also asserted by Task 6 structure test item (v))
    - **gemini-5:** Task 6 structure test item (u) asserts config-file permission check (SC13 orphan fix)
    - **codex-4 / cursor-2:** Task 15 reclassified `standard` → `complex` (5 files across 3 distribution boundaries); dependency added to Task 14 (codex-5 ordering hazard)
    - **cursor-3:** Task 13 commit message updated to reflect twelve validation suites (not six)
  - WARNINGs accepted (tracked, not fixed):
    - **codex-3 (verification theater):** Task 6 structure-only tests are intentional — behavioral tests live in Tasks 8, 10, 11, 12. This split is idiomatic for markdown skills.
    - **codex-2 / cursor-4-5 (spike tasks):** No spike tasks added. Mitigation: the spec's field-presence assertions (not exact strings) in Task 9 bound LLM variability; the SMTP seam via `ZUVO_SMTP_PROBE_CMD` env var makes Task 10 mockable. Late-validation risk is accepted.
    - **gemini-6 (split Task 6):** Not split. Splitting Phase 0 vs Phases 1-7 would create two half-files that cannot be tested until both exist, inflating total task count without reducing risk.
    - **gemini INFO (OSM Overpass spike):** deferred — OSM source is supplementary; failure path is graceful skip per spec.
- Status gate: Reviewed (pending user approval)
- **Plan revision 3** (execute-phase startup adversarial on combined spec+plan diff — 2 new CRITICAL + 6 new WARNING). Writer: claude; providers: codex, gemini, cursor-agent. Combined diff uncovered issues that per-artifact reviews missed:
  - **CRITICAL (gemini-1): TOCTOU race in stale-lock reclamation.** If process A does `mkdir .lock` but hasn't yet written `.lock/pid`, process B reads empty pid and steals lock. FIX applied: Task 6 (k3) requires sleep+retry on empty pid.
  - **CRITICAL (cursor-1): SU1 strict threshold is unenforceable under LLM variance.** Demoted SU1 (80% accuracy) from blocking success → advisory KPI; retained SU2 (verbatim-source violation — deterministic) as blocking.
  - **WARNING (gemini-2): Signal trap only catches SIGINT, orphans .lock on SIGTERM.** FIX: trap `INT TERM HUP EXIT`.
  - **WARNING (gemini-3): Truncate-last-line-on-resume deletes valid record when Ctrl+C writes cleanly.** FIX: validate last line with `jq -e` before truncation.
  - **WARNING (gemini-4): Path safety prefix check vulnerable to `../` traversal.** FIX: use `realpath -s` before prefix comparison.
  - **WARNING (gemini-5): `nc` cross-platform flag divergence.** FIX: use bash built-in `/dev/tcp/$host/25` with `read -t`.
  - **WARNING (cursor-2): SC14 robots.txt not enforced on discovery-phase WebFetch.** FIX: Task 3 agent must cite `live-probe-protocol.md` for any WebFetch it performs.
  - **WARNING (cursor-3): `ZUVO_SMTP_PROBE_CMD` unconstrained → command injection.** FIX: sanitize to absolute path inside `scripts/` or `$FIXTURE_DIR`; reject shell metacharacters; argv-only invocation.
  - **WARNING (cursor-4): `kill -0` PID reuse.** FIX: store `pid:host:start_ts` in `.lock/pid`; reclaim only when host matches AND start time differs.
  - **WARNING (cursor-5): Dedup key normalization drift.** FIX: Phase 5 uses validator-emitted keys verbatim; single canonicalization function defined in `lead-output-schema.md`.
  - **WARNING (codex): Config perm check fail-open.** FIX: Task 6 (u) now fails closed on mode>0600 unless `ZUVO_LEADS_ALLOW_INSECURE_CONFIG=1`.
  - INFO findings (nc edge cases, --dry-run=false parser ambiguity, JSONL length-prefix alternative) tracked in retro, not blocking.

---

## Task Breakdown

### Task 1: Create `shared/includes/lead-output-schema.md` (foundation)
**Files:** `shared/includes/lead-output-schema.md` (new), `scripts/tests/leads-schema-structure.sh` (new)
**Complexity:** standard
**Dependencies:** none
**Execution routing:** default implementation tier

- [ ] RED: create `scripts/tests/leads-schema-structure.sh` that asserts the include exists and contains every required field from the spec's Data Model table. Use grep to verify 23 field names: `record_type`, `full_name`, `first_name`, `last_name`, `name_confidence`, `role_title`, `contact_extraction`, `seniority`, `company_name`, `company_domain`, `industry`, `company_size`, `country`, `email`, `email_confidence`, `is_personal_email`, `phone`, `linkedin_url`, `source_urls`, `providers_used`, `retrieved_at`, `gdpr_flag`, plus meta fields. Also assert the include declares the JSON root shape `{"meta":{}, "contacts":[]}` and the `email_confidence` enum values (`verified`, `catch-all`, `pattern-inferred`, `llm-inferred`, `unverified`, `role-address`, `not-found`). Script prints `PASS` or `FAIL: <missing field>`.
- [ ] GREEN: write `shared/includes/lead-output-schema.md` per spec Data Model section — two record subtypes (person, role-address), all 23 fields with type + constraints, JSON root shape definition, CSV UTF-8 BOM note, companion `.meta.json` format, quarantine format `.quarantine/<slug>.jsonl`, Markdown rendering convention. Reference this file as the single source of truth — no other file restates field definitions inline (CQ19, CQ14).
- [ ] Verify: `bash scripts/tests/leads-schema-structure.sh && echo OK`
  Expected: output ends in `PASS` followed by `OK`; exit code 0
- [ ] Acceptance: SC3, SC8, G5
- [ ] Commit: `add lead-output-schema shared include as single source of truth for contact record shape`

---

### Task 2: Create `shared/includes/lead-source-registry.md` (foundation)
**Files:** `shared/includes/lead-source-registry.md` (new), `scripts/tests/leads-source-registry-structure.sh` (new)
**Complexity:** standard
**Dependencies:** none
**Execution routing:** default implementation tier

- [ ] RED: create `scripts/tests/leads-source-registry-structure.sh` that greps the include for required sections: `WebSearch Templates`, `theHarvester Invocation`, `crt.sh Endpoint`, `GitHub REST API`, `OSM Overpass Query Shape`, `SMTP Probe Sequence`, `Catch-All Detection`. Script asserts each named template/command exists; prints `PASS` / `FAIL: <missing section>`.
- [ ] GREEN: write the include. Each section codifies a concrete pattern: WebSearch query templates (e.g., `site:linkedin.com/in/ "{role}" "{company_name}"`), theHarvester command (`theHarvester -d <domain> -b all -l 200` with 90s timeout), crt.sh endpoint (`https://crt.sh/?q={domain}&output=json`), GitHub API endpoints (`/orgs/{org}/members`, `/search/users`), Overpass query shape (tag filter + bbox), SMTP probe script (`nc`-based RCPT TO with 30s timeout), catch-all detection (probe `zzz9999-{random}@{domain}` — if accepted, domain is catch-all).
- [ ] Verify: `bash scripts/tests/leads-source-registry-structure.sh`
  Expected: `PASS` in stdout; exit 0
- [ ] Acceptance: G6, SC14
- [ ] Commit: `add lead-source-registry shared include with WebSearch/theHarvester/crt.sh/GitHub/OSM/SMTP templates`

---

### Task 3: Create `skills/leads/agents/company-finder.md` (core)
**Files:** `skills/leads/agents/company-finder.md` (new), `scripts/tests/leads-agent-company-finder-structure.sh` (new)
**Complexity:** standard
**Dependencies:** Task 2
**Execution routing:** default implementation tier

- [ ] RED: create structure test that asserts the agent file has YAML frontmatter (`name: company-finder`, `model: sonnet`, `tools:` list), a Mission section, a read of `shared/includes/agent-preamble.md`, references to `shared/includes/lead-source-registry.md` (WebSearch templates), references to `shared/includes/live-probe-protocol.md` covering ANY WebFetch this agent performs in discovery mode (robots.txt check + rate limits apply to discovery-phase fetches too — fix for cursor-2 SC14 gap), output contract section emitting `candidate_companies.json` with fields `company_name`, `domain`, `country`, `industry_tag`, `role_context`, `source_url`. Script prints `PASS` / `FAIL: <missing>`.
- [ ] GREEN: write agent per Architect + Tech Lead specs. Agent reads criteria (industry, geo, role, size-band), composes queries from the source registry, runs WebSearch in parallel with OSM Overpass and (for engineering roles) GitHub search. Agent emits structured candidate list back to orchestrator — it does NOT write files directly (CQ21). Every candidate record MUST include a `role_context` field that passes through the `--role` flag value, so downstream `contact-extractor` can decide whether to trigger GitHub enrichment without re-reading CLI flags (fix for gemini adversarial finding: missing role data for GitHub enrichment). Size target 150-200 lines.
- [ ] Verify: `bash scripts/tests/leads-agent-company-finder-structure.sh`
  Expected: `PASS`; exit 0
- [ ] Acceptance: SC2 (discovery mode), spec Phase 1
- [ ] Commit: `add company-finder agent for discovery-mode WebSearch+OSM+GitHub candidate collection`

---

### Task 4: Create `skills/leads/agents/contact-extractor.md` (core)
**Files:** `skills/leads/agents/contact-extractor.md` (new), `scripts/tests/leads-agent-contact-extractor-structure.sh` (new)
**Complexity:** complex
**Dependencies:** Task 1, Task 2
**Execution routing:** deep implementation tier

- [ ] RED: create structure test asserting the agent file: (a) has proper frontmatter; (b) references `live-probe-protocol.md` (robots.txt, rate limits); (c) references `lead-source-registry.md` (theHarvester + crt.sh + whois + GitHub); (d) references `lead-output-schema.md` (output record shape); (e) has a VERBATIM-SOURCE VALIDATION section describing the rule that LLM-extracted emails not appearing in source HTML must be labeled `llm-inferred`, never `verified`; (f) emits candidates with `source_url` + `provider` per-datapoint attribution; (g) overrides User-Agent to `zuvo-leads/1.0`. Script prints `PASS` / `FAIL: <missing>`.
- [ ] GREEN: write agent. Per-company pipeline: WebFetch Contact/About/Team pages (robots.txt gated) → LLM verbatim extraction (names + titles + emails that appear in source HTML) → theHarvester subprocess (90s timeout) → crt.sh subdomain expansion → whois registrant email → GitHub org member enrichment (when engineering role). Every extraction emits source attribution. Agent does NOT write files — returns results as structured text to orchestrator. Size target 250-300 lines.
- [ ] Verify: `bash scripts/tests/leads-agent-contact-extractor-structure.sh`
  Expected: `PASS`; exit 0
- [ ] Acceptance: SC4, SC14, spec Phase 2
- [ ] Commit: `add contact-extractor agent with robots.txt-gated fetch and verbatim-source validation`

---

### Task 5: Create `skills/leads/agents/lead-validator.md` (core)
**Files:** `skills/leads/agents/lead-validator.md` (new), `scripts/tests/leads-agent-lead-validator-structure.sh` (new)
**Complexity:** standard
**Dependencies:** Task 1
**Execution routing:** default implementation tier

- [ ] RED: structure test asserts the agent file: (a) proper frontmatter; (b) is blind (receives only candidate records + rules — no orchestrator state); (c) references `lead-output-schema.md` for field definitions; (d) defines 3 dedup keys (normalized email, LinkedIn URL, full_name+domain NFC-normalized); (e) domain-mismatch quarantine logic (contact's domain ≠ company's → quarantine record); (f) `gdpr_flag` assignment rule (individual country when resolvable, else company country fallback recorded as `gdpr_flag_source`); (g) confidence tier assignment (role-address detection for info@/sales@/contact@). Prints `PASS` / `FAIL: <missing>`.
- [ ] GREEN: write blind validator agent per write-article anti-slop pattern. Input: candidate records + validation rules. Output: LABELED records (each carrying computed `dedup_key_email`, `dedup_key_linkedin`, `dedup_key_name_domain`, `quarantine_reason`, `confidence`, `gdpr_flag`, `gdpr_flag_source`). The agent DOES NOT DEDUPLICATE — the orchestrator performs the actual dedup in Phase 5 using the labels this agent produces (fix for gemini adversarial finding: agents never dedup across outputs). The agent does NOT strip phones either — that is orchestrator Phase 5 responsibility. Size target 150-200 lines.
- [ ] Verify: `bash scripts/tests/leads-agent-lead-validator-structure.sh`
  Expected: `PASS`; exit 0
- [ ] Acceptance: SC15 (gdpr_flag labeling), SC16 (dedup keys), spec Phase 5
- [ ] Commit: `add lead-validator blind agent for dedup and confidence/gdpr labeling`

---

### Task 6: Create `skills/leads/SKILL.md` (orchestrator — integration hotspot)
**Files:** `skills/leads/SKILL.md` (new), `scripts/tests/leads-skill-structure.sh` (new)
**Complexity:** complex
**Dependencies:** Task 1, Task 2, Task 3, Task 4, Task 5
**Execution routing:** deep implementation tier

- [ ] RED: create `scripts/tests/leads-skill-structure.sh` asserting SKILL.md contains: (a) YAML frontmatter (`name: leads`, description); (b) H1 `# zuvo:leads`; (c) Argument Parsing section; (d) Mandatory File Loading checklist citing all 7 reused includes + the 2 new includes; (e) Phase 0 through Phase 7 headers; (f) Tool-probe block for `dig`, `theHarvester`, `whois`, SMTP port 25, WebSearch, WebFetch; (g) Mode-detection block (`--domains` → enrichment; `--industry`/`--geo` → discovery; both supplied → error); (h) `--domains` path safety check using `realpath -s` + prefix comparison against allowed roots (`docs/`, `scripts/`, `$CWD`) to defeat `../`-style directory traversal — NOT a naive string prefix match (fix for gemini-4 path traversal); (i) Interactive checkpoint block + `--no-interactive` `[AUTO-CHECKPOINT]` path; (j) SMTP probe wrapped in overridable env var `ZUVO_SMTP_PROBE_CMD`, with sanitization: the env var must resolve to an absolute path inside `scripts/` or `$FIXTURE_DIR`; reject values containing shell metacharacters (` `, `;`, `|`, `&`, `$`, `` ` ``, `(`, `)`, newline); use argv-only invocation (no `eval`, no `$()`) — prevents command injection (fix for cursor-3); (j2) SMTP probe implementation uses bash built-in `/dev/tcp/$host/25` + `read -t 30` for timeout rather than `nc`/`netcat`/`ncat` (macOS/Linux `nc` flag divergence makes it unreliable) (fix for gemini-5 cross-platform); (k) Lock file atomic acquisition via `mkdir .lock` with `set -C` noclobber + write `.lock/pid` immediately after successful mkdir inside the SAME shell statement (i.e., `mkdir .lock && echo "$$:$(hostname):$(date +%s)" > .lock/pid`); (k2) Stale lock detection: on acquisition failure, read `.lock/pid` and parse `pid:host:start_ts`; reclaim ONLY when (a) host matches, AND (b) `kill -0 <pid>` fails OR process exists but its start time (`ps -o lstart= -p <pid>`) differs from stored ts (handles PID reuse) (fix for cursor-4 PID reuse + gemini-1 TOCTOU); (k3) If `.lock/pid` is empty or unreadable after a failed mkdir, sleep 200ms and retry acquisition up to 3× (TOCTOU: writer process A hasn't yet written pid file when B fails mkdir) (fix for gemini-1); (l) Signal trap covers INT, TERM, HUP, and EXIT (idempotent handler releases `.lock`, flushes checkpoint, marks run `status: partial-user-stop`) — not only INT (fix for gemini-2); (m) Atomic write `.tmp` → rename in same directory as final target; (m2) Resume protocol: on `--resume`, validate the LAST JSONL checkpoint line with `jq -e` — only truncate if parse fails, otherwise retain (fix for gemini-3 clean-ctrl-c record loss); (n) Dedup-against file schema validation; (n2) Dedup canonicalization: single canonical function is specified in `lead-output-schema.md` as `canonicalize_dedup_key(record) → {email_key, linkedin_key, name_domain_key}` with Unicode casefold + NFC + trim/collapse whitespace + strip punctuation from names; Phase 5 uses validator-emitted keys verbatim without re-computing (fix for cursor-5 normalization drift); (o) `--gdpr-strict` phone stripping + GDPR_NOTICE.txt generation; (p) Run log `Run:` TSV appended to `~/.zuvo/runs.log`; (q) COMPLETION GATE CHECK block; (r) Retrospective call-out; (s) prose rule that agents return results to orchestrator — do not write checkpoint files (CQ21); (t) rule that `Run:` TSV does not interpolate contact field values (CQ5 PII); (u) Config file permission check: on Phase 0, `stat` `~/.zuvo/config.toml` (if present) — FAIL CLOSED if mode > 0600 unless `ZUVO_LEADS_ALLOW_INSECURE_CONFIG=1` is set for local dev (fix for codex-WARNING fail-open credential exposure); (v) prose rule that the `lead-validator` agent LABELS records with dedup keys + quarantine flags but does NOT deduplicate across agent outputs — the orchestrator performs the actual dedup in Phase 5 using validator-emitted keys verbatim. Prints `PASS` / `FAIL: <missing element>` with line.
- [ ] GREEN: write the orchestrator. Follow `pentest/SKILL.md` phase-numbering style; reuse patterns from `write-article` for tool probing and graceful degradation. Each phase block ≤60 lines. Externalize data definitions to the two new includes — reference, don't inline. Size target 400-500 lines (within precedent). Must explicitly instruct the LLM to NOT echo contact values in the run log line (CQ5), enforce `--max-results` cap throughout Phase 2 (not just final write; CQ6), apply explicit timeouts on every external call (CQ8), treat `lead-output-schema.md` as authoritative (CQ19), release `.lock` on every exit path including SIGINT and Phase 0 errors (CQ22), merge agent results serially (CQ21).
- [ ] Verify: `bash scripts/tests/leads-skill-structure.sh`
  Expected: `PASS`; exit 0
- [ ] Acceptance: SC2, SC6, SC7, SC8, SC9, SC10, SC11, SC12, SC13, SC15, SC17, SC18
- [ ] Commit: `add zuvo:leads orchestrator with 7-phase pipeline and CQ3/5/6/8/19/21/22 compliance`

---

### Task 7: Build zero-key smoke fixture set
**Files:** `scripts/tests/fixtures/leads-smoke/*.html` (new, ~5 company pages), `scripts/tests/fixtures/leads-smoke/serp-fixtures.json` (new), `scripts/tests/fixtures/leads-smoke/expected-output.json` (new)
**Complexity:** standard
**Dependencies:** Task 1 (schema to conform to)
**Execution routing:** default implementation tier

- [ ] RED: the fixture set is data, not code. The RED phase is writing the `expected-output.json` first — it defines what a passing run must produce. Assert fixture directory exists and contains at least 5 HTML team/about pages, 1 SERP-fixtures JSON, and 1 expected-output.json that validates against `lead-output-schema.md` (valid JSON with `meta` + `contacts` keys, ≥5 contacts, each with `email` non-null and `email_confidence` ∈ enum).
- [ ] GREEN: assemble fixtures. HTML pages: 5 synthetic company team pages with 2-4 named contacts each, varied formats (some with `@` emails visible in HTML, some with role-addresses only, one with Asian-origin names, one catch-all domain candidate). SERP fixtures: mock search results linking to these HTML pages. `expected-output.json`: the target output against which the smoke test diffs.
- [ ] Verify: `jq -e '.meta and .contacts | length >= 5' scripts/tests/fixtures/leads-smoke/expected-output.json`
  Expected: exit 0 (jq asserts both keys present and contacts ≥ 5)
- [ ] Acceptance: SC1, SU5
- [ ] Commit: `add zero-key smoke fixture set (5 HTML pages, SERP stub, expected output)`

---

### Task 8: Create `scripts/tests/leads-zero-key-smoke.sh`
**Files:** `scripts/tests/leads-zero-key-smoke.sh` (new)
**Complexity:** complex
**Dependencies:** Task 6, Task 7
**Execution routing:** deep implementation tier

- [ ] RED: first write the assertion block of the script (the FAIL conditions): script must assert that after the run (a) 3 output files exist in the fixture output dir (`*.csv`, `*.json`, `*.md`), (b) the `.json` file validates against the schema (jq checks for `meta` + `contacts` keys, contacts count ≥ 5 of which ≥5 have non-null `email`), (c) no `.tmp` files remain (SC9), (d) no `.lock` file remains, (e) exit code of the run was 0 (or specifically `status: complete-at-cap` if cap reached — SC6).
- [ ] GREEN: implement the harness: `mktemp -d` sandbox, copy fixtures, invoke the skill with `--no-interactive --max-results 10 --industry saas --geo US --role CTO --output smoke-fixture-run --dry-run=false` against fixture-replay harness (PATH-substituted `dig`, `theHarvester` mocks + SERP fixture pre-load). Compare the result to `expected-output.json`. Print `PASS` on match, `FAIL: <diff>` otherwise. Exit code matches.
- [ ] Verify: `bash scripts/tests/leads-zero-key-smoke.sh`
  Expected: stdout ends `PASS`; exit 0
- [ ] Acceptance: SC1, SC6, SC8, SC9, SU5
- [ ] Commit: `add zero-key smoke test that runs leads against fixtures with no paid API keys`

---

### Task 9: Build LLM extraction fixtures + eval script
**Files:** `scripts/tests/fixtures/leads-pages/*.html` (new, 20 pages), `scripts/tests/fixtures/leads-pages/ground-truth.json` (new), `scripts/tests/leads-llm-extraction-eval.sh` (new)
**Complexity:** complex
**Dependencies:** Task 4
**Execution routing:** deep implementation tier

- [ ] RED: the ground-truth.json is written first — it defines correct extraction for each of 20 fixture pages. Assertion script block: for each page, run the extraction pass (invoke the contact-extractor agent in isolation against the HTML), diff extracted records to ground-truth. Metric: ≥80% accuracy on name+title triples (SU1) AND zero `verified`/`unverified` labels on emails not appearing verbatim in source HTML (SU2). Accuracy = (correct first_name + correct last_name + correct role_title) / total expected contacts. Output: `PASS` / `FAIL: accuracy=<pct>%, verbatim-violations=<n>`.
- [ ] GREEN: (a) assemble 20 fixture HTML pages — varied structured-team, unstructured-bio, role-address, Asian-origin-names, empty-contacts-page cases; (b) write ground-truth.json mapping each page to its expected contact records with field-presence assertions (non-null name + non-null title; don't assert exact strings — avoids flakiness from whitespace); (c) write the eval harness calling the extractor agent in blind-review mode on each fixture, aggregating results, computing both: (i) accuracy metric (≥80% name+title triples — ADVISORY; fails produce a warning log but exit 0) and (ii) verbatim-source violation count (≥1 invented `verified`/`unverified` emails → FAIL exit 1 — BLOCKING). Mark script as `@slow` per speed reasons but the verbatim gate runs always (it is deterministic, not LLM-variable — see SU2 Coverage Matrix note). Per cursor-1 adversarial fix: enforcement tiers match Coverage Matrix tiers.
- [ ] Verify: `bash scripts/tests/leads-llm-extraction-eval.sh`
  Expected: stdout contains `VERBATIM-GATE: PASS verbatim-violations=0` (blocking); may emit `ACCURACY: warning=<pct<80>%` advisory note; final exit 0 iff verbatim-gate passes
- [ ] Acceptance: SU1 (advisory tracked), SU2 (blocking)
- [ ] Commit: `add LLM extraction accuracy eval with 20 fixture pages and ground-truth diff`

---

### Task 10: Create catch-all detection test with SMTP mock
**Files:** `scripts/tests/fixtures/leads-catchall/mock-smtp.sh` (new mock binary), `scripts/tests/leads-catchall-detection.sh` (new)
**Complexity:** complex
**Dependencies:** Task 6 (needs `ZUVO_SMTP_PROBE_CMD` override seam)
**Execution routing:** deep implementation tier

- [ ] RED: write the assertions first: test feeds the skill 3 domains known to be catch-all (`acme-catchall.test`, `wide-open.test`, `accepts-all.test`) and 3 domains known NOT to be catch-all (`strict.test`, `proper.test`, `exact.test`). After the run, script asserts: (a) every email from the 3 catch-all domains is labeled `email_confidence: catch-all`; (b) no email from the 3 non-catch-all domains is labeled catch-all. Print `PASS` on 100% match, `FAIL: <misclassified>` otherwise.
- [ ] GREEN: (a) write `mock-smtp.sh` that inspects the domain argument and exits with 2xx for catch-all domains or 5xx for strict domains (when the random-local-part probe is supplied); (b) set `ZUVO_SMTP_PROBE_CMD=$FIXTURE_DIR/mock-smtp.sh` in the test environment; (c) invoke the skill with a pre-seeded contact list covering all 6 domains; (d) compare output labels to the known-truth map.
- [ ] Verify: `bash scripts/tests/leads-catchall-detection.sh`
  Expected: stdout ends `PASS`; exit 0
- [ ] Acceptance: SC5, SU3
- [ ] Commit: `add catch-all detection test with SMTP mock via ZUVO_SMTP_PROBE_CMD seam`

---

### Task 11: Create resume resilience test
**Files:** `scripts/tests/leads-resume-resilience.sh` (new)
**Complexity:** complex
**Dependencies:** Task 6, Task 8
**Execution routing:** deep implementation tier

- [ ] RED: write assertions first: (a) run skill with `--max-results 20` against fixture set; (b) kill the process with SIGKILL after ~10 records are written to checkpoint; (c) invoke again with `--resume --output <slug>` in the same dir; (d) assert final output contains ≥ 10 of the pre-kill records (≥95% of completed ones — SU4); (e) separately, test SIGINT handling: same setup but send SIGINT, assert that ALL pre-SIGINT committed records are in final output (SC10); (f) assert `.lock` is cleaned up in both cases.
- [ ] GREEN: implement the harness. Use bash `&` to background the skill, sleep for a checkpoint cycle, send `kill -9` or `kill -INT`. Track PIDs; ensure `teardown()` in the Bats wrapper kills orphaned subprocesses. Read the JSONL checkpoint after kill to verify record count, then run resume and read final output to confirm recovery.
- [ ] Verify: `bash scripts/tests/leads-resume-resilience.sh`
  Expected: stdout shows both `PASS: SIGKILL recovery=<pct ≥ 95>%` and `PASS: SIGINT recovery=100%`; exit 0
- [ ] Acceptance: SC10, SC11, SU4
- [ ] Commit: `add resume resilience test validating SIGINT (100%) and SIGKILL (≥95%) recovery`

---

### Task 12: Create dedup fixtures + test
**Files:** `scripts/tests/fixtures/leads-dedup/existing.csv` (new, 30 records), `scripts/tests/fixtures/leads-dedup/candidates.json` (new, 50 records with 30 overlapping), `scripts/tests/leads-dedup-normalization.sh` (new)
**Complexity:** standard
**Dependencies:** Task 5, Task 6
**Execution routing:** default implementation tier

- [ ] RED: write assertions: after feeding `candidates.json` to the skill with `--dedup-against existing.csv`, (a) output contains exactly 20 records (50 - 30 overlaps); (b) none of the 30 overlap records appear; (c) dedup handles edge cases: case-insensitive email match (`John@Acme.com` vs `john@acme.com`), linkedin_url with/without trailing slash, NFC normalization of full_name+domain key (test with Polish diacritics `Łukasz` vs `Łukasz` in different encodings). Print `PASS` / `FAIL: <found N unexpected duplicates>`.
- [ ] GREEN: (a) write `existing.csv` with 30 contacts covering all 3 dedup keys + 3 normalization edge cases; (b) write `candidates.json` with 50 records of which 30 overlap (some via email, some via linkedin, some via name+domain, with noise variations); (c) write the test harness that invokes skill with the flags and diffs output against expected-kept list (20 records).
- [ ] Verify: `bash scripts/tests/leads-dedup-normalization.sh`
  Expected: stdout ends `PASS`; exit 0
- [ ] Acceptance: SC16, SU6
- [ ] Commit: `add dedup normalization test with email/linkedin/name+domain key fixtures`

---

### Task 13: Create `scripts/tests/leads.bats` wrapper
**Files:** `scripts/tests/leads.bats` (new)
**Complexity:** standard
**Dependencies:** Task 8, Task 9, Task 10, Task 11, Task 12, Task 1, Task 2, Task 3, Task 4, Task 5, Task 6
**Execution routing:** default implementation tier

- [ ] RED: Bats tests themselves are the test here (Bats is a contract: each `@test` asserts one script returns PASS with exit 0). Before implementing, write the full list of `@test` blocks: one per validation script (schema-structure, source-registry-structure, 3 agent structure checks, skill-structure, zero-key-smoke, llm-extraction-eval (`@slow`), catchall-detection, resume-resilience, dedup-normalization). Each `@test` invokes the script in a `mktemp -d` sandbox with PATH-mocks and asserts `[[ "$output" == *"PASS"* ]]` and `[ "$status" -eq 0 ]`.
- [ ] GREEN: write `leads.bats` following the `banned-vocabulary.bats` convention: `setup()` creates temp dir and copies scripts+fixtures in; `teardown()` cleans up. Mark the LLM eval block `@slow` per QA Engineer recommendation — skipped in the default bats run unless `LEADS_SLOW=1`. Every non-slow `@test` is ≤20 lines (Bats convention).
- [ ] Verify: `bats scripts/tests/leads.bats`
  Expected: all non-slow tests pass; stdout shows `ok N - ...` for each; exit 0
- [ ] Acceptance: G4 (Bats wrapper for all validation scripts)
- [ ] Commit: `add leads.bats wrapper covering all twelve validation suites (schema, registry, 3 agents, skill, smoke, catchall, resume, dedup, routing, manifests; slow LLM eval gated behind LEADS_SLOW=1)`

---

### Task 14: Add routing entry to `skills/using-zuvo/SKILL.md`
**Files:** `skills/using-zuvo/SKILL.md` (modified), `scripts/tests/leads-routing-smoke.sh` (new)
**Complexity:** standard
**Dependencies:** Task 6
**Execution routing:** default implementation tier

- [ ] RED: `scripts/tests/leads-routing-smoke.sh` greps `skills/using-zuvo/SKILL.md` for a routing row mentioning `zuvo:leads` AND trigger keywords (at minimum: `lead`, `email finder`, `prospect`, `contact discovery`, `enrich domain`). Assert routing entry exists and keyword list does not collide with `seo-fix`'s "lead time" phrasing or other shadowed entries (grep existing routing rows for competing `lead` / `prospect` patterns). Print `PASS` / `FAIL: <missing keyword> or <shadow conflict>`.
- [ ] GREEN: Read `skills/using-zuvo/SKILL.md`, find the appropriate Priority 2 (Task) section, append a row: `"Find leads, discover companies, enrich contacts, prospect B2B emails, build cold-outreach list"` → `zuvo:leads`. Bump the version banner's skill count per the Tech Lead's resolution (52 → 53 in using-zuvo).
- [ ] Verify: `bash scripts/tests/leads-routing-smoke.sh`
  Expected: `PASS`; exit 0
- [ ] Acceptance: G1
- [ ] Commit: `add zuvo:leads routing entry and bump using-zuvo skill count`

---

### Task 15: Bump skill counts across manifests
**Files:** `package.json` (modified), `.claude-plugin/plugin.json` (modified), `.codex-plugin/plugin.json` (modified), `docs/skills.md` (modified), `scripts/tests/leads-manifest-counts.sh` (new)
**Complexity:** complex (reclassified from `standard` per codex/cursor adversarial — touches 4 production manifest boundaries across 3 distribution targets)
**Dependencies:** Task 6, Task 14 (explicit dependency on routing task so skill-count semantics stay coordinated — fix for codex adversarial: hidden ordering hazard)
**Execution routing:** deep implementation tier

- [ ] RED: `scripts/tests/leads-manifest-counts.sh` asserts: `package.json` description contains `"52 skills"`; both `plugin.json` files contain `"53 skills"`; `docs/skills.md` first line contains `"52 skills"` and contains a row mentioning `leads` in the Utility or a new Lead Generation table. Print `PASS` / `FAIL: <file> count=<N>, expected <N'>`.
- [ ] GREEN: update each file's count string. In `docs/skills.md`, add a row in the skill categories table: either extend Utility (`Utility | 8 | ... leads`) or add a new `Lead Generation | 1 | leads` row. Mention in the overall count at top. Per Tech Lead resolution: package.json = 52, plugin.json ×2 = 53, docs/skills.md = 52.
- [ ] Verify: `bash scripts/tests/leads-manifest-counts.sh`
  Expected: `PASS`; exit 0
- [ ] Acceptance: G2
- [ ] Commit: `bump skill counts across manifests (52/53 per file convention) and add leads to docs/skills.md`

---

### Task 16: Add `docs/leads/` to `.gitignore`
**Files:** `.gitignore` (modified)
**Complexity:** standard
**Dependencies:** none
**Execution routing:** default implementation tier

- [ ] RED: config-only change — no production code. Assertion: `grep -Fx 'docs/leads/' .gitignore` returns exit 0 after the change.
- [ ] GREEN: append `docs/leads/` (with a comment `# zuvo:leads output (per-user lead lists; not committed)`) to `.gitignore`. Idempotent: check existence before appending.
- [ ] Verify: `cd /Users/greglas/DEV/zuvo-plugin && grep -Fx 'docs/leads/' .gitignore`
  Expected: prints `docs/leads/`; exit 0. (Repo-relative path for portability per cursor-agent adversarial finding; the `cd` is the documented cwd assumption.)
- [ ] Acceptance: G3
- [ ] Commit: `gitignore docs/leads/ per zuvo:leads spec backward-compat section`

---

### Task 17: End-to-end smoke validation and final review
**Files:** `scripts/verify-leads-release.sh` (new; chains every required check)
**Complexity:** standard
**Dependencies:** Task 13, Task 14, Task 15, Task 16
**Execution routing:** default implementation tier

- [ ] RED: write `scripts/verify-leads-release.sh` that chains EVERY required validation in a single executable with `set -e`. It must run, in order: (1) `bats scripts/tests/leads.bats` (non-slow); (2) `LEADS_SLOW=1 bats scripts/tests/leads.bats` (runs the LLM extraction eval — fixes codex adversarial #1); (3) `bash scripts/tests/leads-routing-smoke.sh`; (4) `bash scripts/tests/leads-manifest-counts.sh`; (5) `cd $REPO_ROOT && grep -Fx 'docs/leads/' .gitignore` (fixes cursor adversarial — gitignore check absent from final gate); (6) `./scripts/install.sh --dry-run` to validate the plugin structurally builds for all 4 targets (Claude Code, Codex, Cursor, Antigravity); (7) invoke `zuvo:leads --dry-run --industry saas --geo US --role CTO --max-results 5 --no-interactive` and assert stdout contains `Phase 0 tool probe` and `Mode: discovery` without any network call (assert exit code 0). Each step prints `STEP N: PASS` or `FAIL: <step-name> <reason>`. Final line: `RELEASE GATE: PASS`.
- [ ] GREEN: implement the chain script per above. Each step failure causes `set -e` to abort the script; trap `ERR` prints which step failed.
- [ ] Verify: `bash scripts/verify-leads-release.sh`
  Expected: stdout ends `RELEASE GATE: PASS`; exit 0
- [ ] Acceptance: SC1-SC18, SU1-SU6, G1-G6 (final gate across all Coverage Matrix rows)
- [ ] Commit: `add release-gate script chaining bats (slow+fast), manifests, routing, gitignore, dry-run smoke`
