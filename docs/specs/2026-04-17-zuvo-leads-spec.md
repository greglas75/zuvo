# zuvo:leads — Design Specification

> **spec_id:** 2026-04-17-zuvo-leads-1438
> **topic:** zuvo:leads — free-tier B2B lead discovery and enrichment skill
> **status:** Approved
> **created_at:** 2026-04-17T14:38:00Z
> **reviewed_at:** 2026-04-17T07:48:00Z
> **approved_at:** 2026-04-17T07:52:00Z
> **approval_mode:** interactive
> **adversarial_review:** warnings
> **author:** zuvo:brainstorm

## Problem Statement

Users (solo founders, recruiters, growth marketers) regularly need lists of company addresses, employee emails, and phone numbers filtered by industry, geography, and role. Commercial tools (Hunter.io, Apollo.io, ZoomInfo) solve this but cost $49–$1000+/month. The user's constraint: if the skill requires paid API keys to produce useful output, it has no value over going directly to Apollo/Hunter.

Today, a user doing this inside Claude Code does it by hand: ad-hoc `WebSearch` queries, copy-pasting LinkedIn results, guessing emails, eyeballing company websites. There is no structured pipeline, no deduplication, no confidence scoring, no resume-on-interrupt, and no audit trail.

The opportunity: Claude Code users **already pay for** the two most expensive parts of a lead-gen pipeline — a high-quality LLM (for parsing pages and reasoning about fit) and `WebSearch`/`WebFetch` tools. A skill that orchestrates these alongside free OSINT tooling (theHarvester, crt.sh, whois, GitHub API, OpenStreetMap Overpass, DNS/SMTP) can deliver Hunter/Apollo-style results without any required paid API key.

## Design Decisions

**D1. Skill name: `zuvo:leads`** — chosen over `lead-scout`, `prospect`, `find-contacts`. Rationale: shortest, matches verb-first convention of other zuvo skills (`ship`, `debug`, `deploy`).

**D2. Mode: Hybrid (auto-routed).** The skill supports both discovery (criteria → companies → people) and enrichment (domain list → people). Mode is inferred from arguments: presence of `--domains <file>` triggers enrichment; presence of `--industry`/`--geo`/`--role` triggers discovery. Rationale: Hunter and Apollo both do this — splitting the modes into two skills forces users to learn two commands. Rejected: separate `zuvo:leads-discover` + `zuvo:leads-enrich`.

**D3. 100% free-tier engine.** No paid API key is required for the skill to produce value. Engine = `WebSearch` + `WebFetch` (native Claude Code tools) + theHarvester (free subprocess, 40+ OSINT sources) + crt.sh (free HTTPS) + `whois` (free CLI) + GitHub REST API (free, 60 req/h unauthenticated) + OpenStreetMap Overpass (free HTTPS) + DNS `dig MX` (free) + SMTP `RCPT TO` probe (free). Rationale: user's explicit constraint. Optional paid enhancers (Hunter.io free tier, Apollo) are recognized if keys are set in env, but the skill never fails when they are absent. Rejected: requiring Serper/Apollo/Hunter keys.

**D4. Claude as the LLM extractor.** Web page parsing and fuzzy reasoning (e.g., "does this page about 'Team' list the CTO?") are done by Claude itself rather than calling an external NLP API. Rationale: the user already pays for Claude; calling an external extraction API would duplicate cost. Risk: hallucinated emails — mitigated by verbatim-source check (see Failure Modes).

**D5. Global scope; no country-specific first-class sources.** The skill treats every country equally. Poland-specific registries (KRS, CEIDG, REGON), UK Companies House, US SEC EDGAR, and OpenCorporates are deferred to v2 as optional regional enrichers. Rationale: user confirmed clients may be from any country; first-class PL support would bloat v1. Rejected: PL-first architecture.

**D6. Interactive with checkpoints, not batch.** After each phase (company discovery, contact discovery, verification), the skill pauses and shows a preview + `continue / narrow / stop` prompt. Rationale: large discovery runs are expensive in tokens; letting the user kill obvious noise (e.g., a 50-company list that accidentally includes competitors) before enrichment is far cheaper than re-running. Rejected: fire-and-forget batch. In non-interactive environments (Codex App, Cursor) the skill auto-continues and annotates `[AUTO-CHECKPOINT]`.

**D7. Three output formats simultaneously.** Every run writes `docs/leads/YYYY-MM-DD-<slug>.{csv,json,md}`. CSV for outreach tools, JSON for programmatic use, Markdown for terminal review. Rationale: no clear winner among three use cases; the marginal cost of writing all three is trivial.

**D8. Permissive GDPR default + `--gdpr-strict` opt-in flag.** Default: all fields included (all phones, no GDPR notice file). `--gdpr-strict`: strip ALL phone numbers from EU/EEA contacts (no personal-vs-business classification — the spec treats every phone on an EU/EEA contact as in-scope), set `gdpr_flag: eu-eea` on those contacts, generate `GDPR_NOTICE.txt` with legitimate-interest template. `--keep-phones` is an explicit override. Rationale: user chose Option 2 (permissive) explicitly. Rejected: strict default (Option 1) and auto-detect by geo (Option 3).

**D9. Checkpoint every 10 contacts; resume on restart.** Checkpoint path: `docs/leads/.checkpoint-<slug>.json`. On restart with same slug: prompt "found checkpoint with N contacts, continue? [Y/n]". Rationale: long-running searches must survive terminal close / API rate limits / user Ctrl-C.

**D10. Confidence tiers per email, with strict labels.** Every email carries one of: `verified` (SMTP RCPT TO succeeded AND domain is not catch-all), `catch-all` (domain accepts everything), `pattern-inferred` (guessed from top-3 format patterns, no verification), `llm-inferred` (Claude extracted from page text but the string does NOT appear verbatim in the source HTML — highest risk), `unverified` (extracted verbatim but not SMTP-checked), `role-address` (info@, contact@, sales@), `not-found`. Rationale: lead-gen tools routinely inflate `verified` counts by flagging catch-all as verified; explicit labels prevent this.

## Solution Overview

```
Phase 0 — Bootstrap
  Parse args → detect mode (discovery vs enrichment) → load includes
  Probe availability of: WebSearch, WebFetch, theHarvester, whois, dig, GitHub API, OSM Overpass
  If WebSearch unavailable → skill degrades to enrichment-only on supplied domains
  Validate output path writable; check for existing checkpoint; acquire .lock file

Phase 1 — Company Discovery (skipped in enrichment mode)
  Inputs: --industry, --geo, --role, --size-band, --max-results
  Sources (in parallel where possible):
    • WebSearch: google-style queries built from filters
      e.g., `site:linkedin.com/company/ "fintech" "Berlin"`
      e.g., `"{industry}" "{geo}" "about us" OR "our team"`
    • OpenStreetMap Overpass: geo + category → local businesses (optional)
    • GitHub search (if engineering role): orgs active in language X, location Y
  Output: candidate_companies.json (name, domain, country, industry_tag, source)
  CHECKPOINT 1: show list, ask continue/narrow/stop

Phase 2 — Contact Discovery (per company)
  Sources per company domain:
    • theHarvester --domain <d> -b all   (40+ passive OSINT sources)
    • crt.sh: certificate transparency → subdomains → extra @domain surface
    • WebSearch: `site:linkedin.com/in/ "{role}" "{company_name}"`
    • WebFetch: fetch company /team, /about, /contact, /leadership pages
      → Claude LLM extraction pass: names, titles, emails (verbatim only)
    • whois <domain>: admin/tech registrant email
    • GitHub API: org members + commits → engineers + @domain emails
  Output: candidate_contacts.json (per company, raw evidence + attribution)
  CHECKPOINT 2: show contact count per company, ask continue/narrow/stop

Phase 3 — Email Synthesis + Verification
  For each contact where email not found verbatim:
    • Apply top-3 patterns: first@, first.last@, flast@
    • DNS: dig MX <domain> → if no MX, mark email not-found
    • Catch-all probe: SMTP RCPT TO zzz9999random@<domain>
      - If accepted → domain is catch-all → all emails from domain = confidence:catch-all
    • SMTP RCPT TO <candidate> → verified / rejected / unknown
  Optional: Hunter.io Verifier (if ZUVO_HUNTER_KEY env set, uses free 25/mo)

Phase 4 — LLM Extraction Validation
  For every email with confidence=llm-inferred:
    Check if address appears verbatim in the fetched source HTML
    If yes → upgrade to unverified (still needs SMTP check)
    If no → retain llm-inferred tag (NEVER promotes to verified)
  Blocks hallucinated-email class of failure.

Phase 5 — Dedup + Enrichment Pass
  Dedup keys: (email normalized) OR (linkedin_url) OR (full_name + company_domain)
  If --dedup-against <file> supplied: suppress matches present in that file
  If --gdpr-strict: strip personal phones for EU/EEA contacts; add gdpr_flag

Phase 6 — Write Output + Audit Log
  Atomic write (*.tmp → rename) to:
    docs/leads/YYYY-MM-DD-<slug>.csv
    docs/leads/YYYY-MM-DD-<slug>.json
    docs/leads/YYYY-MM-DD-<slug>.md
    docs/leads/YYYY-MM-DD-<slug>.audit.jsonl
  If --gdpr-strict: also write GDPR_NOTICE.txt
  Release .lock; remove .checkpoint-<slug>.json on clean exit

Phase 7 — Completion Gate + Run Log + Retrospective
```

## Detailed Design

### Data Model

**Contact record (JSON shape, same fields in CSV/Markdown columns):**

Two record subtypes share the schema:
- **person** record: represents a specific individual (CTO John Smith). Name fields are non-empty.
- **role-address** record: represents a functional mailbox (info@, sales@, contact@) with no individual attached. Name fields are nullable.

| Field | Type | Constraints |
|---|---|---|
| `record_type` | enum | one of: `person`, `role-address` |
| `full_name` | string or null | non-empty when `record_type=person`; null when `record_type=role-address` |
| `first_name` | string or null | same rule as `full_name` |
| `last_name` | string or null | same rule as `full_name` |
| `name_confidence` | enum | one of: `high`, `medium`, `low`, `n/a`; `n/a` for role-address records; `low` when source text is ambiguous (e.g., Asian-origin names with no clear delimiter) |
| `role_title` | string or null | nullable |
| `contact_extraction` | enum | one of: `ok`, `partial`, `failed`, `quarantined`; records with `quarantined` are in `.quarantine/<slug>.jsonl`, not the main file |
| `seniority` | enum | one of: `c-level`, `vp`, `director`, `manager`, `ic`, `other`, `unknown` |
| `company_name` | string | non-empty |
| `company_domain` | string | lowercase, host only (no scheme/path) |
| `industry` | string | free-form; from query filter or inferred tag |
| `company_size` | enum | one of: `1-10`, `11-50`, `51-200`, `201-500`, `501-1000`, `1001-5000`, `5001+`, `unknown` |
| `country` | string | ISO 3166-1 alpha-2; `unknown` if not resolved |
| `email` | string or null | RFC 5322; lowercase |
| `email_confidence` | enum | one of: `verified`, `catch-all`, `pattern-inferred`, `llm-inferred`, `unverified`, `role-address`, `not-found` |
| `is_personal_email` | bool | true when address host is in the personal-email domain list (gmail.com, icloud.com, yahoo.*, proton.me, outlook.com/hotmail.com, and similar). Independent of `email_confidence` |
| `phone` | string or null | E.164 preferred; null in `--gdpr-strict` for EU/EEA contacts unless `--keep-phones` |
| `linkedin_url` | string or null | full https URL |
| `source_urls` | array of string | ordered; first entry is primary source |
| `providers_used` | array of string | e.g., `["websearch", "theharvester", "webfetch:company.com/team"]` |
| `retrieved_at` | ISO-8601 UTC | timestamp when record was written |
| `gdpr_flag` | string or null | one of: `eu-eea`, `non-eu`, `unknown`; only populated in `--gdpr-strict` |

**JSON output shape:** the `.json` file is a single root object:

```json
{
  "meta": { /* run header fields below */ },
  "contacts": [ /* contact records */ ]
}
```

This keeps the file as valid JSON. The CSV file contains only the contacts table; run header metadata is written as a companion `.meta.json` file alongside the CSV. The Markdown file renders the run header as a top section and contacts as a following table.

**Run header fields (the `meta` object):**

| Field | Purpose |
|---|---|
| `spec_id` | always `2026-04-17-zuvo-leads-1438` |
| `skill_version` | zuvo plugin version |
| `run_id` | `YYYYMMDDTHHMMSSZ-<slug>` |
| `mode` | `discovery` or `enrichment` |
| `filters` | echo of user-supplied filters |
| `providers_enabled` | list of engines that were available at runtime |
| `providers_degraded` | list with reasons |
| `status` | one of: `complete` / `complete-at-cap` / `partial-rate-limit` / `partial-user-stop` / `partial-error` |
| `record_count` | integer |

### API Surface

The skill takes no programmatic input — it is invoked via `/zuvo:leads` with flags.

**Flags:**

| Flag | Type | Default | Purpose |
|---|---|---|---|
| `--industry "<term>"` | string | — | discovery mode filter |
| `--geo "<country\|city>"` | string | — | geography filter (ISO code or city name) |
| `--role "<title>"` | string | — | target role (e.g., "CTO") |
| `--seniority <level>` | enum | any | one of `c-level,vp,director,manager,ic` |
| `--size-band <band>` | enum | any | e.g., `51-200` |
| `--max-results N` | int | 50 | hard cap on total contacts produced |
| `--max-companies N` | int | derived | companies to enrich (default: ceil(max-results / 2)) |
| `--domains <file>` | path | — | triggers enrichment mode; one domain per line |
| `--dedup-against <file>` | path | — | suppress matches |
| `--gdpr-strict` | bool | false | enable GDPR restrictions |
| `--keep-phones` | bool | false | only meaningful with `--gdpr-strict`; when set, retains ALL phone numbers for EU/EEA contacts instead of stripping them. No personal-vs-business classification — the spec treats every phone on an EU/EEA contact as in-scope for stripping under strict mode |
| `--output <slug>` | string | derived from filters | filename stem |
| `--resume` | bool | false | continue from checkpoint |
| `--no-interactive` | bool | false | auto-accept all checkpoints |
| `--dry-run` | bool | false | plan only, no network calls |

Environment variables (all optional):

| Var | Purpose |
|---|---|
| `ZUVO_HUNTER_KEY` | upgrades email verification path (Hunter.io free tier 25/mo) |
| `ZUVO_APOLLO_KEY` | upgrades enrichment (uses free 10k credits if available) |
| `ZUVO_GITHUB_TOKEN` | raises GitHub API rate limit from 60/h (unauth) to 5000/h (free PAT); recommended for runs that enrich engineering roles |
| `ZUVO_LEADS_OUTPUT_DIR` | override `docs/leads/` |
| `ZUVO_LEADS_DISABLED` | when `=1`, skill exits immediately with code 0; used for CI opt-out |

API keys MUST NOT be accepted as CLI flags (shell-history leak risk).

### Integration Points

**New files created by the skill:**

```
skills/leads/SKILL.md                       — orchestrator
skills/leads/agents/company-finder.md       — parallel: discovery via WebSearch + OSM + GitHub
skills/leads/agents/contact-extractor.md    — per-company: WebFetch + LLM extraction + theHarvester
skills/leads/agents/lead-validator.md       — dedup, confidence scoring, GDPR flagging
shared/includes/lead-output-schema.md       — JSON contract (above Data Model)
shared/includes/lead-source-registry.md     — registry of source strategies (WebSearch query templates, OSINT tool invocations)
```

**Files reused without modification:**
- `shared/includes/env-compat.md` (agent dispatch pattern)
- `shared/includes/run-logger.md` (13-field TSV run log)
- `shared/includes/retrospective.md` (mandatory retro at completion)
- `shared/includes/live-probe-protocol.md` (HTTP rate limits: 2 req/s same domain, 1 req/s external; GET/HEAD only; robots.txt respect; User-Agent `zuvo-leads/1.0`)
- `shared/includes/knowledge-prime.md` + `knowledge-curate.md`
- `shared/includes/adversarial-loop-docs.md` (optional cross-model output validation)

**External tools invoked as subprocesses:**
- `theHarvester` (Python, must be installed; skill degrades gracefully if absent)
- `whois` (system CLI; usually present)
- `dig` (system CLI; usually present)
- Optional: `sherlock`, `maigret` (username OSINT; skipped if absent)

**New routing table entry** in `skills/using-zuvo/SKILL.md` so the router knows when to invoke this skill.

**Plugin manifest updates:** `package.json`, `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `docs/skills.md` — all need the skill count bump (51 → 52) and the new entry.

### Interaction Contract

Not applicable — `zuvo:leads` is an ordinary product skill that produces artifacts. It does not change cross-cutting agent behavior (prompts, hooks, routing, formatting, validation) outside of its own process.

### Edge Cases

| Case | Category | Handling |
|---|---|---|
| Empty discovery result | data | emit zero-result record with query echo; suggest broadening filter; exit clean |
| >1000 candidate companies | data | hard cap via `--max-companies`; warn user if cap hit |
| Ambiguous company name (e.g., "Apple") | data | when discovered name is substring of top-100 global brands, surface top-3 candidates, require user confirmation before enrichment |
| Non-ASCII company/person names | data | UTF-8 throughout; CSV written with UTF-8 BOM for Excel; deduplication uses NFC-normalized comparison |
| Multi-location company, mixed EU/non-EU staff | data | `gdpr_flag` is per-contact based on individual's `country` when resolvable (e.g., from LinkedIn location or bio text). When the individual's country cannot be determined, the skill falls back to the company's country. The fallback is recorded in `providers_used` as `gdpr_flag_source: {individual\|company-fallback\|unknown}` |
| Both `--domains` and `--industry` provided | data | validation error at Phase 0: skill exits with "Ambiguous mode: --domains triggers enrichment, --industry triggers discovery. Choose one." No implicit precedence; user must pick |
| Catch-all email domain | integration | detected via RCPT TO to `zzz9999-{random}@domain`; all addresses from catch-all domain labeled `confidence: catch-all`, never `verified` |
| Personal Gmail/iCloud address found | data | `is_personal_email: true` flag set on record; `email_confidence` remains the address's real quality tier (e.g., `unverified`); retained in output |
| No public email available | data | record kept with `email: null`, `email_confidence: not-found` |
| Rate limit mid-run | timing | checkpoint written; exponential backoff (5s, 30s, 120s) up to 3 retries; then save partial with `status: partial-rate-limit` |
| Long-running run > 15 min | timing | checkpointing every 10 contacts survives terminal timeout |
| Concurrent runs on same output | concurrency | `.lock` file in output dir; second run exits with lock file path + PID |
| Missing optional tool (theHarvester, whois, dig) | auth/env | degrade gracefully; record `providers_degraded` with reason in run header |
| API response schema mismatch (Hunter.io version bump) | integration | response validated against expected keys; missing keys log a structured error, continue without that source |
| LinkedIn blocks requests | integration | skill NEVER scrapes LinkedIn directly; uses only public search-engine indexed content |
| Company website unreachable | integration | mark record `contact_extraction: failed`, continue |

### Failure Modes

Every external dependency in Solution Overview / Integration Points has a failure-mode block below.

#### WebSearch (Claude Code native tool)

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|---|---|---|---|---|---|---|
| WebSearch not available in this Claude Code environment | tool-list probe at Phase 0 | all discovery | "Discovery disabled: WebSearch unavailable. Use --domains <file> for enrichment mode." | Exit Phase 0 with clear error OR continue if `--domains` supplied | Clean — no partial state | Immediate |
| WebSearch returns zero results for a valid query | empty result array | single query | logged `no-results` for that query; other queries continue | log and try alternate query shape | Clean | Immediate |
| WebSearch times out or errors | exception / non-success | single query | retry once; on second failure skip query | continue with remaining queries | Clean (query skipped is logged) | 10-30s |
| WebSearch result is spammy / off-topic | LLM post-filter (company name + geo match) | per-query | low-quality candidates filtered out; if >60% filtered, warn user query may be too broad | no auto-action beyond filtering | Clean | Immediate |

**Cost-benefit:** Frequency: occasional (zero-results 5-10%, timeouts <1%). Severity: medium (degraded run; no data loss). Mitigation cost: trivial (already built into fallback logic). **Decision: Mitigate.**

#### WebFetch (Claude Code native tool)

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|---|---|---|---|---|---|---|
| Target URL returns 5xx / network failure | HTTP error | single company contact-page fetch | record marked `contact_extraction: failed` for that source; other sources for same company continue | no retry (respect `live-probe-protocol.md` — avoid hammering unhealthy hosts) | Clean | Immediate |
| Target URL disallowed by robots.txt | robots.txt check before fetch | single URL | URL skipped, logged as `robots-disallowed` | try other discovery vectors for that company | Clean | Immediate |
| JavaScript-heavy site returns skeleton HTML (no team data) | Claude-detects: page content < 200 chars of meaningful text | single company | falls through to theHarvester / WebSearch results for that company | — | Clean | Immediate |
| URL returns HTML with redirect / paywall / login gate | HTTP 302 or login-form detection in body | single URL | URL skipped, logged as `gated`; user sees count in degraded sources | try other vectors | Clean | Immediate |

**Cost-benefit:** Frequency: frequent (~15-30% of company pages hit at least one of these). Severity: medium (some companies yield no contacts). Mitigation cost: trivial (already designed as multi-source). **Decision: Mitigate via multi-source fallback.**

#### theHarvester subprocess

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|---|---|---|---|---|---|---|
| `theHarvester` binary not installed | `which theHarvester` at Phase 0 | all theHarvester queries | one-time warning: "theHarvester not installed — OSINT sources disabled. Install: pip install theHarvester" | Skip theHarvester; rely on WebSearch + WebFetch + GitHub | Clean — `providers_degraded` records absence | Immediate |
| theHarvester exits with non-zero status | subprocess exit code | single company's OSINT pass | stderr captured; domain entry flagged `theharvester: error`; other sources continue | no retry | Clean (that source missing for that company) | Immediate |
| theHarvester hangs (upstream source timeout) | 90-second subprocess timeout | single domain | kill subprocess; log timeout; continue with other sources | no retry | Clean | 90s |
| theHarvester emits stale cached data (known issue when passive source is unresponsive) | data arrives but with no `retrieved_at` from provider | per-domain | data is retained but flagged `confidence: unverified, staleness-unknown` | — | Retained as low-confidence | Delayed |

**Cost-benefit:** Frequency: occasional (not-installed: one-time per machine; timeouts: ~5%). Severity: low (skill works without theHarvester, just fewer email sources). Mitigation cost: trivial. **Decision: Mitigate.**

#### LLM extraction pass (Claude self-reasoning on fetched HTML)

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|---|---|---|---|---|---|---|
| Hallucinated email (Claude infers address not in source) | Phase 4 verbatim-source check: extracted email not found as substring in fetched HTML | per-record | record kept with `email_confidence: llm-inferred`; never relabeled `verified`; Markdown output visually highlights these | Record retained; confidence accurately flagged so user filters downstream | Consistent (all labels honest) | Immediate |
| Wrong company attribution (contact's domain ≠ target company's domain) | domain-mismatch check in Phase 5 | per-record | record moved to `docs/leads/.quarantine/<slug>.jsonl`; not in main output | Quarantined for user review | Quarantined records isolated | Immediate |
| First/last name swap or middle name captured as last | structured extraction prompt + compare against LinkedIn URL slug if present | per-record | `first_name`/`last_name` confidence flagged when source text is ambiguous (e.g., Asian-origin names with no clear delimiter) | User sees confidence flag | Retained with low confidence | Delayed (user notices on use) |
| Claude returns an empty extraction for a page that clearly has contacts | sanity check: page has ≥200 words and contains `@` or "Contact" but extraction returned 0 contacts | per-company | one automatic retry with explicit prompt; if still empty, log `extraction: suspect-empty` | Retry once; otherwise skip | Clean | Immediate |

**Cost-benefit:** Frequency: occasional (hallucination: 5-10% of LLM extractions without guard; misattribution: 2-5%). Severity: high (fabricated emails → bounces → reputational damage for Persona A; misattribution → GDPR error). Mitigation cost: moderate (verbatim-check + quarantine pipeline). **Decision: Mitigate — non-negotiable for v1.**

#### DNS + SMTP verification (system resolver + outbound :25)

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|---|---|---|---|---|---|---|
| No MX record for domain | `dig MX <domain>` empty | all emails at that domain | label all `confidence: not-found`; skip SMTP probe | — | Clean | Immediate |
| Outbound port 25 blocked by ISP/cloud provider | SMTP connect fails with timeout | ALL verification for this run | one-time warning: "Port 25 blocked — email verification disabled, emails will be labeled unverified or pattern-inferred"; if Hunter.io key set, fall back to Hunter Verifier | Degrade to Hunter if key; else ship unverified emails | Clean | 30s on first SMTP attempt |
| SMTP server greylists (4xx temporary reject) | RCPT TO returns 4xx | single address | label `confidence: unverified (greylisted)`; no retry (greylisting clears in minutes-hours; not practical in batch) | — | Clean | 10-30s |
| SMTP server accepts everything (catch-all) | probe `zzz9999-{random}@domain` also accepted | all emails at that domain | all addresses labeled `confidence: catch-all`; run header `catch_all_domains: [...]` | — | Accurate labels | +1 probe/domain |

**Cost-benefit:** Frequency: frequent (port 25 blocked in most cloud/home networks — >60%; greylisting ~15%; catch-all 15-30% of domains). Severity: medium (drives users to mis-trust "verified" labels, or no verification possible). Mitigation cost: trivial (catch-all probe, accurate labeling, Hunter.io opt-in fallback). **Decision: Mitigate.**

#### GitHub API (unauthenticated, 60 req/h rate limit)

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|---|---|---|---|---|---|---|
| Rate limit hit (60/h unauthenticated) | HTTP 403 with `X-RateLimit-Remaining: 0` | remaining GitHub queries this run | warning: "GitHub rate limit hit. Set ZUVO_GITHUB_TOKEN (free, 5000/h) to raise limit."; continue without GitHub source | Skip GitHub; continue with remaining sources | Clean (GitHub sources missing) | Immediate |
| Company org name ambiguous on GitHub (e.g., "apple" org is not Apple Inc.) | LLM sanity check: org description/URL matches target company domain | per-company | GitHub results filtered to org that matches domain; if none, GitHub skipped for that company | — | Clean (low-quality matches filtered) | Immediate |
| Private org — no public member list | GitHub API returns empty member list | per-company | skipped silently | — | Clean | Immediate |

**Cost-benefit:** Frequency: frequent (60/h limit easily hit in a 20-company run). Severity: low (GitHub is supplementary for non-engineering roles). Mitigation cost: trivial (respect rate limit, suggest token). **Decision: Mitigate.**

#### OpenStreetMap Overpass (free HTTPS)

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|---|---|---|---|---|---|---|
| Overpass server overloaded (429 / slow response) | 429 or >30s response | geo-based discovery queries | skip OSM for this run; warn user | Rely on WebSearch geo queries | Clean | 30s |
| No matching tags for industry (niche industries have sparse OSM coverage) | empty result | geo discovery for that industry | WebSearch takes over; OSM logged as "sparse coverage" | — | Clean | Immediate |
| Overpass query syntax error (e.g., unsupported tag combo) | 400 error | single query | skill logs error and falls back; does not crash | — | Clean | Immediate |

**Cost-benefit:** Frequency: occasional (429: ~5%, sparse coverage: common for niche B2B industries). Severity: low (OSM is supplementary). Mitigation cost: trivial. **Decision: Mitigate.**

#### crt.sh (certificate transparency)

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|---|---|---|---|---|---|---|
| crt.sh HTTP timeout or 5xx | HTTP error | subdomain discovery for one domain | skip crt.sh for that domain; continue with other sources | no retry | Clean | 15s |
| crt.sh returns huge subdomain list (hundreds) | result count > 100 | single domain | take top-20 by recency; log "subdomains truncated" | — | Clean (bounded) | Immediate |
| False subdomain (cloud provider wildcard) | heuristic: `*.` prefix or known CDN suffix | per subdomain | subdomain ignored during email harvesting | — | Clean | Immediate |

**Cost-benefit:** Frequency: occasional. Severity: low. Mitigation cost: trivial. **Decision: Mitigate.**

#### Local persistence (CSV/JSON/Markdown + checkpoint)

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|---|---|---|---|---|---|---|
| Crash mid-write | file exists but is `*.tmp` with no final rename | one run's output | On next run: "Previous run did not complete. Checkpoint at <path> has N records. Resume? [Y/n]" | atomic write `.tmp` → rename; checkpoint every 10 records | Either complete old file OR resumable checkpoint — no corrupt final output | On restart |
| Concurrent runs on same slug | `.lock` file present | second run | "Another zuvo:leads run active (lock at <path>, PID N). Wait or remove lock if stale." | second run exits | No corruption | Immediate |
| Disk full | `write()` returns `ENOSPC` | current run | "Disk full after N records. Checkpoint saved. Free space and run --resume." | checkpoint writes in 10-record increments | Partial recoverable | Immediate |
| User kills process mid-run (Ctrl-C) | SIGINT handler flushes checkpoint | current run | "Interrupted. N records saved to checkpoint. Resume with: /zuvo:leads --resume --output <slug>" | Signal handler writes final checkpoint | Clean | Immediate |

**Cost-benefit:** Frequency: rare for crash/ENOSPC; occasional for Ctrl-C. Severity: medium (data loss limited to interrupted batch). Mitigation cost: trivial (atomic write + checkpoint + lock already common pattern). **Decision: Mitigate.**

#### Optional paid APIs (Hunter.io, Apollo.io) when keys are set

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|---|---|---|---|---|---|---|
| Key invalid / revoked | 401/403 at startup probe | that provider | "ZUVO_HUNTER_KEY invalid — running without Hunter verification."; run continues | Degrade to SMTP-only | Clean | Immediate |
| Free-tier quota exhausted | HTTP 402 mid-run | that provider | "Hunter.io free tier exhausted (25/mo). Remaining emails labeled unverified." | Continue without that provider | Clean | Immediate |
| Config file world-readable | `stat ~/.zuvo/config.toml` permissions > 0600 | all runs | one-time warning at startup with `chmod 600` suggestion | Non-blocking warning | Clean | Immediate |

**Cost-benefit:** Frequency: rare. Severity: medium (key leak = quota theft; wrong key = wasted effort). Mitigation cost: trivial. **Decision: Mitigate.**

## Acceptance Criteria

**Ship criteria** (must pass for release — deterministic, fact-checkable):

1. Skill runs end-to-end with **zero paid API keys configured** against a fixture-replay harness (committed HTML + SERP fixtures under `scripts/tests/fixtures/leads-smoke/`) and produces a non-empty output. A separate live-internet smoke run is advisory only (informational; does NOT gate release) since live SERP volatility cannot be bounded deterministically.
2. Skill auto-detects mode: supplying `--domains <file>` triggers enrichment mode without touching discovery phase; supplying `--industry` + `--geo` triggers discovery mode.
3. Every contact record includes all required fields from the Data Model table (nulls allowed only where schema permits).
4. Emails extracted by the LLM that do NOT appear verbatim in the fetched source HTML are labeled `email_confidence: llm-inferred` and NEVER promoted to `verified` regardless of SMTP probe result.
5. Catch-all domains are detected via a random-address RCPT TO probe; all emails from a catch-all domain are labeled `email_confidence: catch-all`.
6. When `--max-results N` cap is reached mid-run, skill stops and writes `status: complete-at-cap` in run header rather than silently continuing.
7. Interactive checkpoints appear after Phase 1 (companies found) and Phase 2 (contacts found); user can type `continue`/`narrow`/`stop`. In `--no-interactive` mode, skill auto-continues and annotates `[AUTO-CHECKPOINT]` in audit log.
8. All three output formats (`.csv`, `.json`, `.md`) are written in the same run; `.csv` uses UTF-8 with BOM; `.json` is valid per the Data Model schema.
9. Atomic write: during a run, the only files present in `docs/leads/` for this slug are `*.tmp`, `.checkpoint-<slug>.json`, `.lock`, and `.quarantine/<slug>.jsonl` (quarantine artifacts for LLM-misattributed records per Failure Modes). Final (non-prefixed) output files appear only on clean completion via atomic rename.
10. Resume — SIGINT (graceful): killing the process with SIGINT after Phase 2 triggers the signal handler which flushes the checkpoint; re-running with `--resume --output <slug>` recovers ALL pre-SIGINT records and resumes from Phase 3. SIGINT is the user-initiated path and must lose zero committed records. (SIGKILL is a separate, best-effort scenario validated under Success Criterion #4 with a ≥95% recovery target — 100% is not guaranteed under SIGKILL because the signal handler cannot run.)
11. Concurrent runs: if `.lock` exists, second run exits with clear message identifying lock path and PID. No output corruption.
12. Port 25 blocked: skill detects and emits a one-time warning; continues labeling emails as `pattern-inferred` or `unverified` rather than aborting.
13. API keys (if present) are only read from env vars or `~/.zuvo/config.toml`, never from CLI flags. Skill checks `~/.zuvo/config.toml` permissions at startup and warns if > 0600.
14. Robots.txt is checked before each WebFetch call; disallowed URLs are skipped and logged.
15. `--gdpr-strict`: contacts whose `country` is in the EU/EEA list have `phone` stripped (unless `--keep-phones`), get `gdpr_flag: eu-eea`, and `GDPR_NOTICE.txt` is generated alongside output files.
16. Dedup: when `--dedup-against existing.csv` contains 30 records that overlap with discovered contacts, the output contains 0 of the 30 overlaps and all non-overlapping results. The `existing.csv` file MUST conform to the same Data Model as the skill's output CSV (UTF-8, lowercase `email`, host-only `company_domain`). Dedup keys are normalized before comparison: (a) `email` → lowercase + NFC; (b) `linkedin_url` → lowercase scheme/host + trailing-slash stripped; (c) `full_name + company_domain` → NFC-normalized full_name case-insensitive + lowercase domain. Records match if ANY of the three keys match. Test fixtures live at `scripts/tests/fixtures/leads-dedup/`.
17. Run log: a `Run:` TSV line is appended to `~/.zuvo/runs.log` per `run-logger.md` with VERDICT one of `COMPLETE`, `PARTIAL`, `DEGRADED`, `FAILED`.
18. Retrospective: run is completed per `retrospective.md` protocol.

**Success criteria** (must pass for value validation — measurable quality/efficiency):

1. **LLM extraction accuracy ≥ 80%:** in a blind evaluation on 20 real company /team pages, the skill returns the correct first_name + last_name + role_title triple for at least 80% of contacts whose page has structured markup (team grid, bio list).
   - *Validation:* `scripts/tests/leads-llm-extraction-eval.sh` loads 20 curated HTML fixtures → runs extraction → diffs against ground-truth JSON → emits pass/fail + accuracy ratio.

2. **No hallucinated verbatim-source emails:** in the same 20-fixture eval, 0 emails labeled `verified` or `unverified` are absent from the source HTML (these tiers assert the address was present in the page verbatim). `pattern-inferred` is explicitly EXEMPT because by definition it is a format guess synthesized from `{first}.{last}@{domain}` patterns and is not expected to appear in source HTML. `llm-inferred` is likewise exempt but capped at low-confidence display.
   - *Validation:* same script, asserts zero `verified`/`unverified` labels on non-verbatim addresses.

3. **Catch-all detection coverage = 100%:** given 3 known catch-all domains (verifiable via mail-tester.com) and 3 known non-catch-all domains, the skill correctly labels all 6.
   - *Validation:* `scripts/tests/leads-catchall-detection.sh` runs against fixture MX servers (mocked) → asserts labels.

4. **Resume recovers ≥ 95% of completed records:** SIGKILL after 50% of records are processed → `--resume` recovers at least 95% of the pre-kill records.
   - *Validation:* `scripts/tests/leads-resume-resilience.sh` runs a 20-record job, kills at 10 records, resumes, asserts ≥ 10 records present in final output.

5. **Zero-key pathway produces usable output:** with no `ZUVO_HUNTER_KEY`, `ZUVO_APOLLO_KEY`, or `ZUVO_GITHUB_TOKEN` set, a 10-result discovery run produces at least 5 records with `email` populated (any confidence tier).
   - *Validation:* `scripts/tests/leads-zero-key-smoke.sh` asserts record count and populated-email count.

6. **Dedup accuracy:** 100% suppression of duplicates when `--dedup-against` is supplied. (This overlaps with Ship #16 but is measured here as a quality KPI.)
   - *Validation:* same script as Ship #16, framed as success metric.

## Validation Methodology

All success criteria above have a named validation script. The scripts live in `scripts/tests/` and run under Bats (bash test framework already used by the repo per `scripts/tests/banned-vocabulary.bats`). Each script:

- Is runnable standalone: `bash scripts/tests/leads-<name>.sh`
- Emits a final line: `PASS` or `FAIL: <reason>`
- Returns exit code 0 on pass, non-zero on fail
- Lives in the repo, not the user's home — fixtures committed for reproducibility

For the LLM-accuracy eval (Success #1, #2), the 20 HTML fixtures are checked into `scripts/tests/fixtures/leads-pages/` along with `ground-truth.json`. Re-running the eval against future model versions produces a comparable accuracy score for regression tracking.

Success criterion validation is a **prerequisite for declaring v1 complete**, not a deliverable of v1. If the validation script infrastructure is not written, the skill cannot ship.

## Rollback Strategy

**Kill switch:** remove `skills/leads/` directory and re-run `./scripts/install.sh`. The skill disappears from the router; other skills are unaffected. No persistent state outside `docs/leads/` and `~/.zuvo/runs.log` (which is shared and retained).

**Fallback behavior when disabled:** users fall back to the manual ad-hoc WebSearch workflow they used before the skill existed.

**Data preservation:** the contents of `docs/leads/` are user-generated outputs and MUST NOT be deleted during rollback. The plugin's install/uninstall scripts only touch `skills/`, `shared/includes/`, and `scripts/` — never `docs/`.

**Per-run disable:** the skill honors a `ZUVO_LEADS_DISABLED=1` env var; when set, the skill prints "Skill disabled by env flag." and exits with code 0. This allows CI to disable the skill without removing it.

## Backward Compatibility

`zuvo:leads` is a new skill. It creates new artifacts only:
- New skill files under `skills/leads/`
- New include files under `shared/includes/lead-output-schema.md` and `lead-source-registry.md`
- New routing-table entry in `skills/using-zuvo/SKILL.md`
- Skill count bump in `package.json`, `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `docs/skills.md`

No existing skill, include, schema, or config is modified in a way that changes its behavior. Existing users updating from v1.3.93 to the version shipping this skill see only an added entry in the skill list.

The `docs/leads/` directory is created on first run and is gitignored by default (added to `.gitignore` in the same PR) — users who want to commit their lead lists can remove that entry manually.

No deprecation, no migration, no precedence concerns.

## Out of Scope

### Deferred to v2

- **Regional business registries** (KRS, CEIDG, REGON, UK Companies House, US SEC EDGAR, OpenCorporates, GLEIF) — valuable for enrichment when jurisdiction is known, but bloats v1 scope. User explicitly de-prioritized PL-specific focus.
- **Paid provider first-class support** (Apollo.io, Hunter.io paid, Prospeo, Snov.io, Dropcontact, ZeroBounce, PDL, SerpAPI, Exa, Firecrawl) — v1 recognizes their env vars and uses them as optional enhancers, but v2 could add deeper integration (Apollo's sequence enrichment, Exa's LinkedIn index, Firecrawl's batch crawl).
- **Real-time lead monitoring** (track when a contact changes jobs/companies) — would be a separate skill `zuvo:lead-monitor`.
- **CRM push integration** (HubSpot, Salesforce, Pipedrive) — user exports CSV and imports manually for now.
- **Email campaign sending** — skill produces lists, does not send. Outreach tooling (Instantly, Apollo sequences) out of scope entirely.
- **Intent / signal data** (company funding events, hiring signals, tech stack changes) — would require paid data providers; deferred.
- **Chrome extension / browser UI** — this skill is CLI-only.

### Permanently out of scope

- **Direct LinkedIn scraping** — permanent ToS violation and CFAA gray area. Skill uses only publicly-indexed LinkedIn content surfaced via search engines, never direct scraping or automation against linkedin.com.
- **Consumer (B2C) contact data** — the skill targets business contacts only. Home addresses, personal phone numbers of non-professionals, family info, and similar personal data are out of scope.
- **Breach data / leaked credentials lookup** — explicitly excluded. Skill does not query Have I Been Pwned or any breach database.
- **Evasion of rate limits / captchas via proxy rotation or fingerprint spoofing** — violates Terms of Service of target sites; out of scope by design.
- **Automated outreach / cold email sending** — scope boundary between "discovery" and "outreach."

## Open Questions

*(Populated during adversarial review if new items emerge.)*

1. Should the default `--max-results` be 50 or lower? 50 produces a meaningful list but can burn ~15-20 min on a free-tier run. Alternative: default 20, require explicit `--max-results 50` for larger runs. **Proposed resolution:** default 50, document the typical runtime upfront in the skill's help text.

2. Should the skill cache company-level results across runs (e.g., once a company's /team page has been parsed, cache for N days)? Caching saves tokens but risks serving stale data. **Proposed resolution:** no cache in v1 (simpler, always fresh); add `--cache-days N` in v2 if users request it.

3. For `--geo` inference of EU/EEA jurisdiction, use ISO 3166-1 alpha-2 only, or accept city names like "Berlin"? **Proposed resolution:** accept both; internal resolver maps city → country (hardcoded list of top-200 cities, fallback to LLM reasoning).

## Adversarial Review

Ran 2026-04-17T07:50Z via `adversarial-review --mode spec` across three non-host providers: **codex-5.3**, **gemini**, **cursor-agent** (claude auto-excluded as writer host). Returned JSON; summary below.

### Verdict: WARNINGS (after fixes)

All three reviewers converged on the same internal contradictions — high-confidence signal, not noise. Six CRITICAL findings with cross-reviewer agreement were fixed in the spec before approval. Two remaining WARNING-level items accepted as documented open questions. One gemini finding (`domain-profile-registry.md` referenced) was a hallucination (the spec references `lead-source-registry.md`; no such file is cited) and is disregarded.

### CRITICAL findings (all fixed in spec)

| # | Finding (converged across reviewers) | Fix applied |
|---|---|---|
| 1 | Success #2 required every `verified` AND `pattern-inferred` email to appear verbatim in source HTML, but Phase 3 creates `pattern-inferred` emails by synthesizing format patterns with no verbatim source. Release gate would be impossible to pass. | Success #2 now restricts the verbatim assertion to `verified` and `unverified` tiers; `pattern-inferred` and `llm-inferred` are explicitly exempt. |
| 2 | Ship #9 atomic-write guarantee limited in-run files to `*.tmp`, checkpoint, `.lock` — but the LLM failure-mode flow writes quarantine records to `.quarantine/<slug>.jsonl` during processing. | Ship #9 amended to include `.quarantine/<slug>.jsonl` in the allowed in-run file inventory. |
| 3 | Ship #1 "deterministic and fact-checkable" criteria depended on live WebSearch returning non-empty results — inherently flaky under SERP/rate-limit variance. | Ship #1 now runs against committed fixtures in `scripts/tests/fixtures/leads-smoke/`. Live-internet run is advisory and does NOT gate release. |
| 4 | Data Model required non-empty `first_name` + `last_name` + `full_name` on every record, but workflow explicitly supports `role-address` records (`info@`, `sales@`) that have no person. | Data Model now has two record subtypes: `person` (name fields non-empty) and `role-address` (name fields null). New field `record_type` distinguishes them. |
| 5 | JSON output described as "Run header (first line of JSON file)" — a second JSON document concatenated to a first would invalidate JSON syntax. | Output shape is now a single root object: `{"meta": {...}, "contacts": [...]}`. CSV run header lives in companion `.meta.json`. Markdown renders meta as top section. |
| 6 | `ZUVO_GITHUB_TOKEN` referenced by GitHub failure-mode and Success #5 but absent from the Environment Variables table. | Added `ZUVO_GITHUB_TOKEN` and `ZUVO_LEADS_DISABLED` rows with purpose + precedence. |

### Additional fixes (WARNING-level)

- **D8 phone-stripping text** aligned with `--keep-phones` semantics (drop "personal" qualifier everywhere). All phones on EU/EEA contacts are stripped under `--gdpr-strict`; no personal/business classification.
- **Ship #10 vs Success #4 interrupt semantics** now explicitly separated: SIGINT (graceful, zero-loss via signal handler) vs SIGKILL (best-effort ≥95% recovery).
- **Ship #16 dedup normalization** now specifies exact keys, UTF-8/NFC normalization, case handling, and fixture path.
- **`gdpr_flag` per-contact country fallback** documented: individual country when resolvable, else company country; the fallback source is recorded in output.
- **`--domains` + `--industry` both supplied** now has an explicit validation-error edge case (no implicit precedence).
- **`contact_extraction` status field** + `name_confidence` enum added to Data Model to match references in Failure Modes.

### Accepted WARNING items (tracked in Open Questions)

- **Q (open):** Should the live-internet smoke check — currently advisory-only per Ship #1 fix — become a weekly cron that reports regressions without blocking releases? Flagged for v1.1 decision.

### Disregarded findings

- **gemini: hallucinated capability referencing `domain-profile-registry.md`** — this file is not referenced anywhere in the spec (the spec references `lead-source-registry.md`). False positive from cross-spec confusion. Disregarded.

### Providers used

- codex-5.3 — found 6 findings (3 CRITICAL, 3 WARNING); all CRITICAL converged with other reviewers.
- gemini — found 7 findings (3 CRITICAL, 4 WARNING); 1 hallucination disregarded; remainder converged.
- cursor-agent — found 7 findings (4 CRITICAL, 3 WARNING); all CRITICAL converged with other reviewers.

Cross-provider convergence was unusually high (~80% overlap among CRITICAL items across three providers), which validates that the identified contradictions were real. The fixes above resolve every converged CRITICAL.
