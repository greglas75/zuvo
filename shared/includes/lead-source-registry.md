# Lead Source Registry

> Canonical registry of source strategies for `zuvo:leads`. Every agent and the orchestrator
> references this file — they MUST NOT duplicate query templates, subprocess commands, or
> API endpoints inline (CQ19 / CQ14 / G6).
>
> **Safety baseline:** every HTTP fetch in this registry respects
> `shared/includes/live-probe-protocol.md` rate limits (2 req/s same-domain, 1 req/s
> external), robots.txt-first check, and User-Agent `zuvo-leads/1.0`. The GET/HEAD-only
> clause from `live-probe-protocol.md` applies to content-scraping fetches (company
> websites, Team/About/Contact pages). Read-only API calls that require a POST body
> because the API itself is POST-shaped (OpenStreetMap Overpass — a query-only API that
> uses POST to carry a large QL body) are exempt from the GET-only clause but must still
> honor rate limits, timeouts, and retry/backoff rules. No API in this registry performs
> state mutation.

## Direct-Scrape Prohibitions

- **Do NOT scrape LinkedIn directly.** LinkedIn ToS Section 8.2 prohibits automation.
  The registry surfaces LinkedIn only via public search-engine indexing
  (`site:linkedin.com/in/` queries through `WebSearch`). Never fetch `linkedin.com/*`
  URLs directly with `WebFetch` or any other client.
- Never use proxy rotation, captcha solvers, or fingerprint spoofing to evade rate limits.
- Never query breach databases (Have I Been Pwned etc.) — out of scope.

## WebSearch Templates

The orchestrator composes these queries from user-supplied filters (industry, geo, role,
company-size) and runs them via Claude Code's native `WebSearch` tool.

### Discovery-mode queries (Phase 1)

| Purpose | Template | Example |
|---|---|---|
| Find people on LinkedIn by role + geo | `site:linkedin.com/in/ "{role}" "{geo}"` | `site:linkedin.com/in/ "CTO" "Berlin"` |
| Find people on LinkedIn by role + company | `site:linkedin.com/in/ "{role}" "{company_name}"` | `site:linkedin.com/in/ "Head of Marketing" "Acme"` |
| Find companies by industry + geo | `"{industry}" company "{geo}" "about us"` | `"fintech" company "London" "about us"` |
| Find team pages | `site:{company_domain} /team OR /about OR /leadership` | `site:acme.com /team OR /about` |
| Find company listings in directories | `"{industry}" companies "{geo}" site:clutch.co OR site:crunchbase.com` | — |

### Enrichment-mode queries (Phase 2)

| Purpose | Template |
|---|---|
| Find contacts at a specific domain | `site:{domain} "@{domain}"` |
| Surface public email mentions | `"@{domain}" "{role}"` |
| Discover team-page path | `site:{domain} inurl:team OR inurl:about OR inurl:people` |

**Query budget:** max 5 WebSearch calls per company in enrichment mode; max 20 per run in
discovery mode. Count is recorded in `providers_used`.

## theHarvester Invocation

`theHarvester` is an optional OSINT subprocess (absent on systems without
`pip install theHarvester` — skill degrades gracefully).

| Phase | Command |
|---|---|
| 0 (probe) | `command -v theHarvester` — record presence in `providers_enabled` / `providers_degraded` |
| 2 (contact harvest) | `theHarvester -d <domain> -b all -l 200 -f <tmp>/<domain>.json` (theHarvester timeout: 90 seconds per invocation) |

**Timeout: 90 seconds.** If the subprocess exceeds 90s, send SIGTERM then SIGKILL,
record `theharvester: timeout` in `providers_degraded`, and continue with other sources.

Parse output JSON for `.emails` and `.hosts` arrays; feed each email as a candidate with
`providers_used: ["theharvester:b-all"]`.

## crt.sh Endpoint

Certificate Transparency lookup — free HTTPS, no auth, no rate limit (be polite anyway).

- **URL:** `https://crt.sh/?q={domain}&output=json`
- **Method:** `GET`
- **crt.sh timeout: 15 seconds.** On timeout or 5xx, skip crt.sh for this domain; log `crt.sh: <error>` in audit.
- **Response:** JSON array of certificate entries. Extract `.[].name_value` — each is a
  subdomain (may be wildcard-prefixed `*.`). Skip wildcard entries for email harvesting.
- **Cap:** take the top-20 most-recent unique subdomains (sort by `.entry_timestamp` desc).
- **Use case:** subdomains found here (e.g., `careers.acme.com`, `support.acme.com`) are
  fed to theHarvester and WebFetch as additional surfaces for `@{primary-domain}` emails.

## GitHub REST API

Unauthenticated GitHub API has **60 req/h** rate limit. Setting `ZUVO_GITHUB_TOKEN`
(any fine-grained PAT with `public_repo` read) raises it to **5000/h**.

| Endpoint | Purpose | Rate cost |
|---|---|---|
| `https://api.github.com/search/users?q=<company_name>+in:login+in:name` | Find candidate GitHub orgs matching a company name | 30/min search limit |
| `https://api.github.com/orgs/{org}/members?per_page=100` | List public org members | 1 core req |
| `https://api.github.com/users/{user}/events/public` | Recent events (commit emails may appear) | 1 core req |
| `https://api.github.com/search/commits?q=author:{user}+author-email:%40{domain}` | Surface commits with matching author email | 30/min search limit |

**Auth header (when `$ZUVO_GITHUB_TOKEN` is set):**
`Authorization: Bearer $ZUVO_GITHUB_TOKEN`

**Trigger condition:** GitHub enrichment is invoked only when the candidate company's
`role_context` (passed through from `company-finder`) matches an engineering role
(CTO, VP Engineering, Director of Engineering, Head of Engineering, Principal Engineer,
Staff Engineer, Software Engineer). For non-engineering roles, skip GitHub.

**On 403 `X-RateLimit-Remaining: 0`:** record `github: rate-limit (60/h — set ZUVO_GITHUB_TOKEN for 5000/h)` in audit, skip remaining GitHub queries this run.

## OSM Overpass Query Shape

OpenStreetMap Overpass API — free, no auth — for local-business discovery by category +
location.

- **URL:** `https://overpass-api.de/api/interpreter`
- **Method:** `POST` with Overpass QL body
- **OSM Overpass timeout: 30 seconds.** On 429 or 5xx, skip OSM for this run; continue with WebSearch.

### Query template

```overpassql
[out:json][timeout:25];
(
  node["office"="{industry_tag}"](area:{area_id});
  way["office"="{industry_tag}"](area:{area_id});
  node["amenity"="{amenity_tag}"](area:{area_id});
);
out tags center 50;
```

- `{industry_tag}` is mapped from user's `--industry` via a small lookup table
  (e.g., `fintech` → `office=financial`; `saas` → `office=it`; `marketing agency`
  → `office=advertising_agency`). Unknown tags fall back to `office=company`.
- `{area_id}` is resolved from `--geo` via a preliminary Nominatim query:
  `https://nominatim.openstreetmap.org/search?city={geo}&format=json&limit=1` → take
  `.[].osm_id + 3600000000` per Overpass area convention.
- `out ... 50` caps results at 50 per query.

Extract `name`, `website`, `addr:*` tags, `phone`, `email` (rare but present on some
nodes). Feed `name`+`website` to the contact-extractor.

## SMTP Probe Sequence

Bash-native SMTP probe using built-in `/dev/tcp` (no `nc` / `netcat` / `ncat` — their
flags differ between macOS BSD, GNU coreutils, and Nmap's `ncat`).

**SMTP timeout: 30 seconds per address.** On timeout, label `email_confidence: unverified (smtp-timeout)`.

### Canonical probe function (bash)

SMTP replies can be multi-line. Continuation lines start with `<code>-` (hyphen); the
terminal line starts with `<code> ` (space). A correct probe MUST drain all continuation
lines per stage before sending the next command, otherwise reads desynchronize and later
commands bind to earlier replies (false verify/unverify).

```bash
smtp_probe() {
  # usage: smtp_probe <domain> <email_local@domain> → exits 0 on accept, 1 on reject/timeout
  local host="$1" addr="$2" fd line code
  exec {fd}<>"/dev/tcp/${host}/25" 2>/dev/null || return 1

  # _drain_reply reads lines until the terminal line ("XYZ " with space, not hyphen).
  # Sets $code to the final 3-digit status code. Returns 0 on success, 1 on timeout/close.
  _drain_reply() {
    while read -t 30 -r -u "$fd" line; do
      # Normalize CRLF → LF
      line="${line%$'\r'}"
      # Extract 3-digit code and the continuation/terminal separator
      if [[ "$line" =~ ^([0-9]{3})([\ -])(.*)$ ]]; then
        code="${BASH_REMATCH[1]}"
        [[ "${BASH_REMATCH[2]}" == " " ]] && return 0   # terminal line
      else
        return 1  # malformed
      fi
    done
    return 1  # read timeout or EOF before terminal line
  }

  _drain_reply || { exec {fd}>&-; return 1; }
  [[ "$code" == "220" ]] || { exec {fd}>&-; return 1; }

  printf 'EHLO zuvo-leads.test\r\n' >&"$fd"
  _drain_reply || { exec {fd}>&-; return 1; }
  [[ "$code" =~ ^2 ]] || { exec {fd}>&-; return 1; }

  printf 'MAIL FROM:<probe@zuvo-leads.test>\r\n' >&"$fd"
  _drain_reply || { exec {fd}>&-; return 1; }
  [[ "$code" =~ ^2 ]] || { exec {fd}>&-; return 1; }

  printf 'RCPT TO:<%s>\r\n' "$addr" >&"$fd"
  _drain_reply || { exec {fd}>&-; return 1; }
  local rcpt_code="$code"

  printf 'QUIT\r\n' >&"$fd"
  _drain_reply   # best-effort; result not inspected
  exec {fd}>&-

  # Caller examines $rcpt_code via a wrapper; this boolean form is for catch-all probe:
  [[ "$rcpt_code" == "250" ]]
}
```

Notes:
- Multi-line reply handling is mandatory (gmail, outlook, and most enterprise MTAs emit
  multi-line `250-` sequences after `EHLO`).
- `read -t 30` applies per line, not per stage — a slow server emitting many continuation
  lines can still time out. That is acceptable; `_drain_reply` returning 1 is treated as
  `email_confidence: unverified (smtp-timeout)`.
- Callers that need to distinguish 4xx vs 5xx vs 250 wrap this function and inspect
  `$rcpt_code` directly (via a variant `smtp_probe_code` that echoes the code rather
  than returning a boolean).

**Override seam:** if `$ZUVO_SMTP_PROBE_CMD` is set, orchestrator invokes that instead.
The env var value MUST:
- resolve to an absolute path inside `$REPO_ROOT/scripts/` or `$FIXTURE_DIR`
- NOT contain shell metacharacters: ` `, `;`, `|`, `&`, `$`, `` ` ``, `(`, `)`, newline
- be invoked via argv only (no `eval`, no `$()`)

Values failing validation cause Phase 0 to reject startup with exit code 2.

### 4xx vs 5xx distinction

- `250` → accepted → `email_confidence: verified` (subject to catch-all check)
- `550`, `551`, `553` (hard reject) → `email_confidence: unverified` (address doesn't exist)
- `4xx` (greylisting, temporary rejection) → `email_confidence: unverified (greylisted)`
  — NEVER interpret a 4xx as a hard reject (catch-all probe must treat 4xx specially too)

## Catch-All Detection

A domain is catch-all if it accepts random local parts. Detection:

1. Generate a random local part: `zzz9999-$(openssl rand -hex 4)` — known-invalid
2. Probe via SMTP: `smtp_probe "$domain" "zzz9999-xxxxxxxx@$domain"`
3. If the probe returns `250` (accept): the domain is catch-all
4. If it returns `5xx` (hard reject): the domain enforces per-address validation
5. If it returns `4xx` (temporary): label the domain `catch-all-unknown` — do NOT classify
   all emails as catch-all based on a transient failure

Probe is run ONCE per domain, cached in the run's `catch_all_domains` list in `meta`.
Subsequent emails from the same domain short-circuit to the cached result.

## WHOIS Lookup

System `whois` CLI — optional subprocess, probed at Phase 0.

- **Command:** `whois <domain>` with 15s timeout via `timeout 15 whois <domain>`
- **Use:** extract `Registrant Email`, `Tech Email`, `Admin Email` fields if present.
  These are often redacted (`REDACTED FOR PRIVACY`) under GDPR; treat redactions as no data.
- **Caution:** WHOIS output format is registrar-dependent; treat as best-effort, not schema.

## DNS MX Lookup

System `dig` CLI — required tool; probed at Phase 0. If missing, all emails at any domain
are labeled `email_confidence: not-found` and the skill emits a warning.

- **Command:** `dig +short +time=5 MX <domain>`
- **Interpretation:** empty output → no MX record → domain does not accept email → label all
  candidate emails for that domain as `email_confidence: not-found`.
- **Timeout: 5 seconds.**

## Rate Limit Escalation

From `live-probe-protocol.md`:
- 3× consecutive 429 from the same host → pause 30s, then resume
- 3× consecutive 5xx from the same host → halt that source for the rest of the run
- honor any `Retry-After` header verbatim

## Audit Trail

Every source invocation writes one line to `<slug>.audit.jsonl`:

```json
{"ts":"2026-04-17T08:52:00Z","event":"source-called","source":"theharvester","domain":"acme.com","duration_ms":18200,"result":"ok","candidate_count":14}
```

Raw contact values are NOT logged (CQ5). Counts and timings only.
