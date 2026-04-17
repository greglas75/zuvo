# Lead Output Schema

> Canonical output contract for `zuvo:leads`. This file is the single source of truth for
> contact record shape, run-header shape, and dedup canonicalization. Skills, agents, and
> validation scripts reference this file — they MUST NOT restate field definitions inline
> (CQ19 / CQ14 / G5).

## Record Subtypes

Two record subtypes share the same schema. The `record_type` field discriminates.

| `record_type` value | Represents | Name fields |
|---|---|---|
| `person` | A specific individual (e.g., CTO Jane Smith) | non-empty |
| `role-address` | A functional mailbox (e.g., `info@`, `sales@`, `contact@`) with no individual attached | null |

## Contact Record Fields

| Field | Type | Constraints |
|---|---|---|
| `record_type` | enum | one of: `person`, `role-address` |
| `full_name` | string or null | non-empty when `record_type=person`; null when `record_type=role-address` |
| `first_name` | string or null | same rule as `full_name` |
| `last_name` | string or null | same rule as `full_name` |
| `name_confidence` | enum | one of: `high`, `medium`, `low`, `n/a`. Use `n/a` for role-address. Use `low` when source text is ambiguous (e.g., Asian-origin names with no clear delimiter, or name resolved from heuristics) |
| `role_title` | string or null | free-form; nullable |
| `contact_extraction` | enum | one of: `ok`, `partial`, `failed`, `quarantined`. Records with `quarantined` live in `.quarantine/<slug>.jsonl`, never in the main output |
| `seniority` | enum | one of: `c-level`, `vp`, `director`, `manager`, `ic`, `other`, `unknown` |
| `company_name` | string | non-empty |
| `company_domain` | string | lowercase; host only (no scheme, no path) |
| `industry` | string | free-form; populated from the query filter or inferred tag |
| `company_size` | enum | one of: `1-10`, `11-50`, `51-200`, `201-500`, `501-1000`, `1001-5000`, `5001+`, `unknown` |
| `country` | string | ISO 3166-1 alpha-2; `unknown` if not resolved |
| `email` | string or null | RFC 5322; lowercase |
| `email_confidence` | enum | one of: `verified`, `catch-all`, `pattern-inferred`, `llm-inferred`, `unverified`, `role-address`, `not-found`. See Tier Definitions below |
| `is_personal_email` | bool | `true` when the address host is in the personal-domain list: `gmail.com`, `googlemail.com`, `icloud.com`, `me.com`, `yahoo.*`, `outlook.com`, `hotmail.com`, `live.com`, `proton.me`, `protonmail.com`, `aol.com`, `gmx.*`, `mail.ru`, `yandex.*`. Independent of `email_confidence` |
| `phone` | string or null | E.164 preferred when possible; null in `--gdpr-strict` for EU/EEA contacts unless `--keep-phones` is set |
| `linkedin_url` | string or null | full `https://` URL; lowercase host; no trailing slash |
| `source_urls` | array of string | ordered; the first entry is the primary source |
| `providers_used` | array of string | e.g., `["websearch", "theharvester", "webfetch:example.com/team"]` |
| `retrieved_at` | string | ISO-8601 UTC timestamp when the record was written |
| `gdpr_flag` | string or null | one of: `eu-eea`, `non-eu`, `unknown`. Populated only in `--gdpr-strict` mode |
| `gdpr_flag_source` | string or null | one of: `individual`, `company-fallback`, `unknown`. Indicates whether the country used for the GDPR flag came from the individual's resolved country or from the company's country as a fallback |

### Email Confidence Tier Definitions

| Tier | Meaning | Verbatim-source required? |
|---|---|---|
| `verified` | SMTP RCPT TO accepted AND domain is not catch-all. Address must appear verbatim in fetched source HTML | YES — see SU2 blocking gate |
| `catch-all` | Domain accepts any local part (detected via random-local-part probe). All emails from the domain are labeled catch-all regardless of SMTP result | N/A — catch-all short-circuits verification |
| `pattern-inferred` | Address synthesized from top-3 format patterns (`first@`, `first.last@`, `flast@`) against a known MX domain. NOT expected to appear in source HTML (format guess, not extraction) | NO |
| `llm-inferred` | LLM extracted an address not appearing verbatim in source HTML. Capped at low display confidence. NEVER promoted to `verified` or `unverified` regardless of later SMTP result | NO |
| `unverified` | Address appears verbatim in source HTML but SMTP check was skipped, blocked (port 25), or returned `unknown` | YES |
| `role-address` | Local part matches functional patterns: `info@`, `sales@`, `contact@`, `hello@`, `admin@`, `support@`, `careers@`, `press@`, `legal@` | NO |
| `not-found` | No email could be synthesized or extracted for this contact | N/A |

## JSON Output Shape (root object)

The `.json` output file is a single JSON object:

```json
{
  "meta": { /* run header fields, see below */ },
  "contacts": [ /* contact records */ ]
}
```

This is valid JSON and parseable with a single `jq '.'` call. Run header MUST NOT be written as a separate line-oriented prefix; that would invalidate the document.

## CSV Output

The `.csv` file contains only the contacts table (one row per contact, columns match field names).

- Encoding: **UTF-8 BOM** at start of file (so Microsoft Excel opens non-ASCII names correctly)
- Field order matches the Data Model table above (`record_type` first, `gdpr_flag_source` last)
- Array fields (`source_urls`, `providers_used`) are serialized as `;`-joined strings
- Null values are written as empty cells (not the literal string `null`)

Run header metadata for the CSV lives in a companion `.meta.json` file alongside the CSV. Example file layout for a completed run:

```
docs/leads/2026-04-17-saas-us-cto.csv
docs/leads/2026-04-17-saas-us-cto.meta.json
docs/leads/2026-04-17-saas-us-cto.json
docs/leads/2026-04-17-saas-us-cto.md
docs/leads/2026-04-17-saas-us-cto.audit.jsonl
```

## Markdown Output

The `.md` file renders the run header as a top section (`## Run Metadata`) followed by a contact table (`## Contacts`). Intended for quick terminal review, not programmatic use.

## Run Header (the `meta` object)

| Field | Purpose |
|---|---|
| `spec_id` | always `2026-04-17-zuvo-leads-1438` (v1) |
| `skill_version` | zuvo plugin version (from `package.json`) |
| `run_id` | `YYYYMMDDTHHMMSSZ-<slug>` |
| `mode` | `discovery` or `enrichment` |
| `filters` | echo of user-supplied flags (industry, geo, role, size-band, max-results) |
| `providers_enabled` | list of engines available at runtime (`websearch`, `webfetch`, `theharvester`, `whois`, `dig`, `github`, `osm`, `hunter`, `apollo`) |
| `providers_degraded` | list of `{ "provider": "<name>", "reason": "<text>" }` entries for missing or failing tools |
| `status` | one of: `complete`, `complete-at-cap`, `partial-rate-limit`, `partial-user-stop`, `partial-error` |
| `record_count` | integer — count of records in `contacts[]` |
| `catch_all_domains` | array of domains detected as catch-all during this run |
| `smtp_available` | bool — whether port 25 was reachable at startup probe |
| `gdpr_mode` | one of: `off`, `strict` |
| `started_at` | ISO-8601 UTC |
| `ended_at` | ISO-8601 UTC |

## Quarantine Format

Records whose extracted domain does not match the target company's domain (LLM misattribution) are routed to `docs/leads/.quarantine/<slug>.jsonl`:

- One JSON record per line (JSONL)
- Same field shape as the main contact record
- Additional fields: `quarantine_reason` (enum: `domain-mismatch`, `contact_extraction-failed`, `schema-violation`), `orchestrator_run_id`

Quarantine records NEVER appear in the main `.json` / `.csv` / `.md` output.

## Checkpoint Format

`.checkpoint-<slug>.json` (written during Phase 2 every 10 records) is JSONL-style despite the `.json` extension — one record per line, append-safe.

- On resume (`--resume`): orchestrator reads the checkpoint line-by-line
- Validate the **last** line with `jq -e '.' <<< "$last_line"`:
  - If parse succeeds → retain the record, resume from the next record position
  - If parse fails → truncate the malformed last line, resume from the record before it
- Do not blindly truncate the last line (this would lose a cleanly-written final record when the run was interrupted by SIGINT after a clean flush)

## Canonical Dedup Keys

All dedup comparisons (Phase 5 orchestrator dedup AND `--dedup-against` suppression) use
the single function below. The `lead-validator` agent emits these keys per record; the
orchestrator uses them verbatim — no re-computation, no divergent normalization.

```
canonicalize_dedup_key(record) → {
  "email_key":       <email lowercase + NFC + whitespace-strip, or null if email is null>,
  "linkedin_key":    <linkedin_url lowercase-scheme-and-host + trailing-slash-stripped + query-stripped, or null>,
  "name_domain_key": <NFC + Unicode casefold + whitespace-collapse(" ") + punctuation-strip on full_name,
                      PLUS lowercase company_domain, joined by "|". Null when full_name is null>
}
```

Normalization primitives:

- **Unicode casefold** — **normatively defined as Python 3 `str.casefold()`**. This is mandatory for cross-runtime consistency. JavaScript's `String.prototype.toLowerCase()` is NOT casefold-equivalent (e.g., Turkish dotless-i and German sharp-s `ß` → `ss` differ) and MUST NOT be substituted. The orchestrator and `lead-validator` both invoke Python via `python3 -c "import sys,unicodedata; ... sys.stdout.write(s.casefold())"` as a subprocess when computing keys. Canonical conformance test vectors:
  - `"Ş"` → `"ş"`
  - `"İ"` → `"i̇"` (i + U+0307 combining dot above)
  - `"ß"` → `"ss"`
  - `"ΰ"` → `"ύ"` (casefolded form)
  These vectors are committed as `scripts/tests/fixtures/leads-dedup/casefold-vectors.tsv` and checked by Task 12.
- **NFC** — Unicode Normalization Form C (canonical composition). Applied via `unicodedata.normalize("NFC", s)`.
- **Whitespace collapse** — multiple whitespace chars → single space; trim leading/trailing.
- **Punctuation strip** — remove `.`, `,`, `-`, `'`, `"`, `\`, `/`, `_` from names (preserves diacritics).

Two records are duplicates if ANY of their three keys match (with null-vs-null counted as no-match).

## Audit Log Format

`<slug>.audit.jsonl` is written alongside outputs:

- One JSON record per line
- Records significant events: `run-started`, `provider-degraded`, `robots-disallowed`,
  `rate-limit-hit`, `catch-all-detected`, `quarantine-written`, `checkpoint-flushed`,
  `lock-acquired`, `lock-released`, `gdpr-strip-applied`, `run-ended`
- Each event has `ts`, `event`, and event-specific payload
- NEVER contains raw contact field values (CQ5) — event payloads reference contact records
  by index or deterministic id, not by name/email/phone
