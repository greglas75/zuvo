---
name: leads
description: >
  B2B lead discovery and enrichment skill. Finds company addresses, employee emails, and
  phone numbers filtered by industry, geography, role, and company size. 100% free-tier:
  orchestrates Claude Code's native WebSearch and WebFetch plus free OSINT subprocesses
  (theHarvester, crt.sh, whois, GitHub API, OSM Overpass, DNS MX, bash SMTP probe). No
  paid API keys required — optional env vars (ZUVO_HUNTER_KEY, ZUVO_APOLLO_KEY,
  ZUVO_GITHUB_TOKEN) are recognized as enhancers but never required. Hybrid mode:
  supplying --domains triggers enrichment; --industry + --geo triggers discovery.
  Interactive checkpoints after Phase 1 and Phase 2. Output: CSV + JSON + Markdown in
  docs/leads/. Optional --gdpr-strict for EU/EEA compliance.
---

# zuvo:leads

Free-tier B2B contact discovery orchestrator. Runs a 7-phase pipeline with interactive
checkpoints, parallel-agent dispatch, graceful degradation when tools are missing, and
atomic output writes.

## Argument Parsing

| Flag | Type | Default | Purpose |
|---|---|---|---|
| `--industry "<term>"` | string | — | discovery-mode filter |
| `--geo "<country\|city>"` | string | — | ISO 3166-1 code or city name |
| `--role "<title>"` | string | — | target role |
| `--seniority <level>` | enum | any | `c-level,vp,director,manager,ic` |
| `--size-band <band>` | enum | any | `1-10`/`11-50`/.../`5001+` |
| `--max-results N` | int | 50 | hard cap on contacts |
| `--max-companies N` | int | derived | default: ceil(max-results/2) |
| `--domains <file>` | path | — | triggers enrichment mode |
| `--dedup-against <file>` | path | — | suppress matching records |
| `--gdpr-strict` | bool | false | enable GDPR restrictions |
| `--keep-phones` | bool | false | only with `--gdpr-strict`; retain all phones |
| `--output <slug>` | string | derived | filename stem |
| `--resume` | bool | false | continue from checkpoint |
| `--no-interactive` | bool | false | auto-accept checkpoints, emit `[AUTO-CHECKPOINT]` |
| `--dry-run` | bool | false | plan only, no network calls |

Env vars (all optional): `ZUVO_HUNTER_KEY`, `ZUVO_APOLLO_KEY`, `ZUVO_GITHUB_TOKEN`,
`ZUVO_LEADS_OUTPUT_DIR`, `ZUVO_LEADS_DISABLED`, `ZUVO_SMTP_PROBE_CMD`,
`ZUVO_LEADS_ALLOW_INSECURE_CONFIG`. API keys MUST come from env/config only — NEVER
from CLI flags.

## Mandatory File Loading

```
CORE FILES LOADED:
  1. ../../shared/includes/env-compat.md            -- READ/MISSING
  2. ../../shared/includes/live-probe-protocol.md   -- READ/MISSING
  3. ../../shared/includes/lead-output-schema.md    -- READ/MISSING
  4. ../../shared/includes/lead-source-registry.md  -- READ/MISSING
  5. ../../shared/includes/knowledge-prime.md       -- READ/MISSING
  6. ../../shared/includes/knowledge-curate.md      -- DEFERRED (completion)
  7. ../../shared/includes/run-logger.md            -- DEFERRED (completion)
  8. ../../shared/includes/retrospective.md         -- DEFERRED (completion)
  9. ../../shared/includes/adversarial-loop-docs.md -- OPTIONAL
```

If any READ-marked file is missing: STOP.

## Authoritative References — Don't Inline

- Output record shape → `../../shared/includes/lead-output-schema.md`
- Source strategies (queries, subprocess commands, API endpoints) → `../../shared/includes/lead-source-registry.md`
- HTTP safety (rate limits, robots.txt, User-Agent) → `../../shared/includes/live-probe-protocol.md`
- Agent dispatch → `../../shared/includes/env-compat.md`

This file orchestrates. Data definitions and source templates live in the includes.

---

## Phase 0 — Bootstrap

### Step 0.1 — Kill-switch check

If `ZUVO_LEADS_DISABLED=1`: print `Skill disabled by env flag.` and exit 0.

### Step 0.2 — Parse args + mode detection

- If both `--domains` AND (`--industry` or `--geo`) are supplied: exit 2 (via `echo ... >&2; exit 2` — NOT `exit 2 "msg"`; bash `exit` does not accept a message argument) with
  `Ambiguous mode: --domains triggers enrichment, --industry triggers discovery. Choose one.`
- If `--domains <file>` supplied: `mode=enrichment`
- If `--industry` or `--geo` or `--role` supplied: `mode=discovery`
- Otherwise: exit 2 (via `echo ... >&2; exit 2` — NOT `exit 2 "msg"`; bash `exit` does not accept a message argument) with usage help

### Step 0.3 — Path safety check (`--domains`, `--dedup-against`)

For any file-path flag, resolve with `realpath` (WITHOUT `-s` — symlinks MUST be
followed so a symlink under an allowed root cannot be used to escape it) BEFORE
prefix comparison against
allowed roots (`$REPO_ROOT/docs/`, `$REPO_ROOT/scripts/`, `$CWD`). This defeats
`../`-style directory traversal (a naive string prefix match would accept
`docs/../../etc/shadow`). Reject with exit 2 if the resolved path is outside allowed
roots.

### Step 0.4 — Config file permission check

If `~/.zuvo/config.toml` exists: `stat` its mode. If mode > 0600 AND
`$ZUVO_LEADS_ALLOW_INSECURE_CONFIG` is NOT `1`: **fail closed** with exit 2 and a
clear message (`chmod 600 ~/.zuvo/config.toml` or set the override env var for local
dev). Rationale: world-readable config files containing API keys are a silent
credential-exposure risk on shared systems.

### Step 0.5 — Tool probes

Record each into `providers_enabled[]` or `providers_degraded[]`:

| Check | Command | Required? |
|---|---|---|
| WebSearch | inspect tool list | required for discovery |
| WebFetch | inspect tool list | required |
| dig | `command -v dig` | required (DNS MX) |
| theHarvester | `command -v theHarvester` | optional |
| whois | `command -v whois` | optional |
| port 25 | bash `/dev/tcp/gmail-smtp-in.l.google.com/25` connect with 5s timeout | optional (SMTP) |
| GitHub API | `curl -sS -o /dev/null -w '%{http_code}' https://api.github.com/rate_limit` | optional |
| OSM Overpass | `curl -sS -o /dev/null -w '%{http_code}' https://overpass-api.de/api/status` | optional |

When port 25 is blocked: record `smtp_available: false` once; Phase 3 will degrade
emails to `pattern-inferred`/`unverified` without aborting.

### Step 0.6 — SMTP override validation (if set)

If `$ZUVO_SMTP_PROBE_CMD` is set, validate:
- resolves (via `realpath`, symlinks followed) to an absolute path inside `$REPO_ROOT/scripts/` or `$FIXTURE_DIR`
- does NOT contain any shell metacharacter: space, `;`, `|`, `&`, `$`, backtick, `(`, `)`, newline, quote
- is executable (`-x` test)

If validation fails: exit 2. Invocation is argv-only — no `eval`, no `$(...)` expansion.

### Step 0.7 — Acquire lock

Output dir defaults to `docs/leads/` (or `$ZUVO_LEADS_OUTPUT_DIR`). Slug from
`--output` or derived from filters.

Atomic lock acquisition:

```bash
if mkdir "$OUTDIR/.lock" 2>/dev/null; then
  # Store PID, host, AND the process's own start time (lstart) so PID reuse can be
  # detected later. `ps -o lstart= -p $$` captures when THIS process started.
  OWN_START=$(ps -o lstart= -p $$ | tr -s ' ' | sed 's/^ //; s/ $//')
  printf '%s\t%s\t%s\n' "$$" "$(hostname)" "$OWN_START" > "$OUTDIR/.lock/pid"
  # lock acquired
else
  # race or stale — run the stale-PID check below
  :
fi
```

**Stale-lock detection (fixes gemini-1 TOCTOU + cursor-4 PID reuse):**

```bash
PIDLINE=$(cat "$OUTDIR/.lock/pid" 2>/dev/null)
if [ -z "$PIDLINE" ]; then
  # TOCTOU: other process just ran mkdir but hasn't written pid yet.
  # Sleep + retry acquisition up to 3×, 200ms each.
  sleep 0.2; retry_acquisition
fi
IFS=$'\t' read -r PID HOST STORED_START <<<"$PIDLINE"
if [ "$HOST" != "$(hostname)" ]; then
  echo "lock held by another host: $HOST" >&2; exit 2
fi
if ! kill -0 "$PID" 2>/dev/null; then
  # process dead → reclaim
  rm -rf "$OUTDIR/.lock" && retry_acquisition
fi
# verify same process (PID reuse defense): compare current lstart to stored lstart.
# STORED_START was captured from `ps -o lstart=` at lock-creation time, not from
# `date +%s`, so a legitimate holder's start-time matches exactly across checks.
CURRENT_START=$(ps -o lstart= -p "$PID" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//')
if [ -n "$CURRENT_START" ] && [ "$CURRENT_START" != "$STORED_START" ]; then
  # PID was reused by an unrelated process → reclaim
  rm -rf "$OUTDIR/.lock" && retry_acquisition
fi
echo "lock held by active PID $PID ($STORED_START) on this host" >&2; exit 2
```

### Step 0.8 — Signal trap (fixes gemini-2 SIGTERM orphan)

Install trap on `INT TERM HUP EXIT`. The handler is idempotent: on first invocation it
(1) flushes the in-memory checkpoint buffer to JSONL, (2) marks the run
`status: partial-user-stop` in the companion `.meta.json` tmp file, (3) removes
`$OUTDIR/.lock/`. Subsequent signals see the handler already ran and no-op.

### Step 0.9 — Resume check

If `--resume`: read `$OUTDIR/.checkpoint-<slug>.jsonl`. Validate the LAST line with
`jq -e '.' <<< "$LASTLINE"`. If parse succeeds → retain the record, resume from the
record after it. If parse fails → truncate the malformed last line, resume from the
record before it. Do NOT blindly truncate (fixes gemini-3 — would lose a cleanly
written final record on SIGINT).

If `--resume` without a checkpoint: exit 2 (via `echo ... >&2; exit 2` — NOT `exit 2 "msg"`; bash `exit` does not accept a message argument) with clear message.

---

## Phase 1 — Company Discovery (enrichment mode skips)

Dispatch `company-finder` agent per `env-compat.md`. Input: filters + providers_enabled.
Agent returns candidate_companies records. Orchestrator serializes the result into
`$OUTDIR/.checkpoint-<slug>.jsonl` using one line per company.

**CHECKPOINT 1:** print a summary table (company_name, domain, country, industry_tag)
with counts. In interactive mode, prompt `continue / narrow / stop`. In
`--no-interactive`: log `[AUTO-CHECKPOINT] Phase 1 → continue with N companies` and
proceed. User chooses `narrow` → re-prompt for revised filter and re-dispatch.

---

## Phase 2 — Contact Discovery (per company, max 3 parallel)

Dispatch `contact-extractor` once per candidate company. Batch of 3 at a time; wait
for the batch to return before dispatching the next 3 (parallel-agent cap from
pentest pattern).

**Agents return results via agent reply (no file writes).** The orchestrator merges
all contact-extractor outputs serially into the in-memory candidate list and writes
checkpoint lines. Agents NEVER write the checkpoint, output, or any file (CQ21).

Every 10 records, flush to `.checkpoint-<slug>.jsonl` (append, atomic via
`>>` wrapped in a per-run exclusive lock on the checkpoint itself — one writer at
a time because serialization is orchestrator-only).

**CHECKPOINT 2:** per-company contact counts summary + option `continue / narrow / stop`.

If `--max-results` cap is reached mid-Phase-2: stop dispatch, set
`status: complete-at-cap` in meta, proceed to Phase 3.

---

## Phase 3 — Email Synthesis + Verification (inline, orchestrator-owned)

For each contact with `email: null` but `full_name` and `company_domain` present:
1. Generate top-3 pattern candidates: `first@`, `first.last@`, `flast@` (NFC-normalized,
   lowercase, stripped of diacritics for ASCII fallback).
2. `dig MX <domain>` (5s timeout). If no MX: label all candidates `not-found`.
3. If MX present AND `smtp_available: true`: run catch-all probe first:
   `smtp_probe "$domain" "zzz9999-$(openssl rand -hex 4)@$domain"` (see
   `lead-source-registry.md` for the canonical probe function). If accepted → domain
   is catch-all → label all emails from domain `catch-all`.
4. Otherwise probe each pattern candidate; first accepted → label `verified` (unless
   catch-all from step 3); else `unverified` or `pattern-inferred`.
5. For contacts with existing `email_confidence: llm-inferred`: NEVER promote to
   `verified` or `unverified` regardless of SMTP result — it stays `llm-inferred` per
   spec SC4.

**SMTP invocation override:** if `$ZUVO_SMTP_PROBE_CMD` is set (validated in Step 0.6),
invoke it via argv only instead of the inline bash probe. No `eval`, no `$()`. The
override uses bash's built-in `/dev/tcp/host/25` rather than the `nc` binary because
macOS BSD `nc` and GNU/Nmap `ncat` have incompatible flags.

---

## Phase 4 — LLM Extraction Validation (inline)

For every record with `email_confidence: llm-inferred`: verify the email string does
NOT appear verbatim in the source HTML. If it DOES appear verbatim → upgrade to
`unverified` (promotion is safe — the address really was in the page, just not
initially confirmed). If not → retain `llm-inferred`. Never promote `llm-inferred`
directly to `verified`.

---

## Phase 5 — Dedup + GDPR Flagging

Dispatch `lead-validator` agent (blind, no Bash) with the merged candidate list plus
the rules object (EU/EEA country list, personal email domains, role-address locals).

Receive back labeled records with `raw_key_email`, `raw_key_linkedin`,
`raw_key_name_domain`, quarantine flags, gdpr_flag, confidence tiers.

**Apply canonicalize_dedup_key() ONCE in the orchestrator** (single source of truth
for normalization — CQ19). Python subprocess:

```bash
python3 <<'PY' < raw_keys.tsv > canonical_keys.tsv
import sys, unicodedata, re
for line in sys.stdin:
    key = line.rstrip("\n")
    if not key: print(""); continue
    n = unicodedata.normalize("NFC", key).casefold()
    n = re.sub(r"\s+", " ", n).strip()
    n = re.sub(r"[.,\-_'\"/\\]", "", n)
    print(n)
PY
```

Deduplicate records: two records match iff ANY of the three canonical keys matches
(null-vs-null = no match). The validator LABELS, the orchestrator DEDUPS — validator
never performs cross-record dedup.

If `--dedup-against <file>` is supplied: load it, validate it conforms to
`lead-output-schema.md` (required fields present, enum values valid), compute canonical
keys for its records, and suppress any discovered records matching those keys.

**GDPR phone stripping** (orchestrator-owned, not agent-owned): for every record with
`gdpr_flag: eu-eea`, if `--gdpr-strict` is active AND `--keep-phones` is NOT active:
set `phone: null`.

Quarantined records (`quarantine_reason` non-null) are routed to
`$OUTDIR/.quarantine/<slug>.jsonl` — NOT the main output.

---

## Phase 6 — Write Output (atomic)

Build 4 artifacts in the SAME directory as the final targets (cross-filesystem rename
is not atomic on POSIX):

1. `$OUTDIR/<slug>.json.tmp` — `{"meta":{...}, "contacts":[...]}` root shape
2. `$OUTDIR/<slug>.csv.tmp` — UTF-8 BOM, contact columns in schema order
3. `$OUTDIR/<slug>.meta.json.tmp` — run header (companion for CSV consumers)
4. `$OUTDIR/<slug>.md.tmp` — Markdown: `## Run Metadata` + `## Contacts` table
5. `$OUTDIR/<slug>.audit.jsonl.tmp` — append-only event log built during run

Then atomically `mv *.tmp → *` (same directory guarantees atomic rename). Only AFTER
successful rename release the lock: `rm -rf "$OUTDIR/.lock/"` and delete
`.checkpoint-<slug>.jsonl`.

If `--gdpr-strict`: also write `$OUTDIR/<slug>.GDPR_NOTICE.txt` with a legitimate-
interest template (B2B outreach basis, opt-out contact, data retrieval date).

**CQ5 — No PII in run log:** the `Run:` TSV line appended in Phase 7 contains counts,
verdicts, and provider names only. It does NOT interpolate any contact field values
(no names, no emails, no phones). The event log in `*.audit.jsonl` references contact
records by their deterministic record-id, never by name/email/phone.

---

## Phase 7 — Run Log + Retrospective

Append to `~/.zuvo/runs.log` per `run-logger.md` (13-field TSV, VERDICT one of
`COMPLETE`, `PARTIAL`, `DEGRADED`, `FAILED`).

Run retrospective per `retrospective.md` protocol.

Optional: if `adversarial-loop-docs.md` is present and user wants output validation,
run cross-model review on the emitted `.json` artifact.

Knowledge curation per `knowledge-curate.md`.

---

## COMPLETION GATE CHECK

Before emitting the final block, verify:

```
[ ] Phase 0 tool probes recorded in meta.providers_enabled/providers_degraded
[ ] Lock acquired and released cleanly (no .lock/ remains)
[ ] Checkpoint .jsonl deleted on clean completion
[ ] All three output formats (CSV + JSON + Markdown) present, no .tmp remnants
[ ] Records labeled with email_confidence from enum; no llm-inferred promoted to verified
[ ] If --gdpr-strict: GDPR_NOTICE.txt written and eu-eea phones stripped (unless --keep-phones)
[ ] Run: TSV appended to ~/.zuvo/runs.log (no PII)
[ ] Retrospective appended
```

```
Run: <ISO-8601-Z>\tleads\t<project>\t<mode>\t<records>\t<VERDICT>\t<providers>\t<slug>\t<notes>\t<BRANCH>\t<SHA7>\t<INCLUDES>\t<TIER>
```

## Final Output

`docs/leads/YYYY-MM-DD-<slug>.{csv,json,md,meta.json,audit.jsonl}` + optional
`GDPR_NOTICE.txt`. User imports to CRM / outreach tool of choice.

## Parallel-Agent Safety Invariants

1. **Agents return results via agent reply text only — they never write files.** The
   orchestrator is the sole writer. Two concurrent contact-extractor dispatches never
   collide on disk because neither touches the disk.
2. **Validator LABELS, orchestrator DEDUPS.** The validator agent emits raw key inputs;
   the orchestrator computes canonical keys and performs dedup serially. No cross-agent
   dedup race.
3. **Lock files are atomic.** `mkdir .lock` is atomic on POSIX. The `.lock/pid` file is
   written immediately after successful mkdir. TOCTOU between mkdir success and pid
   write is handled by sleep+retry on empty pid.
4. **No file writes outside the output directory.** Agents are restricted to Read
   (validator) or denylisted Bash (finder/extractor). theHarvester's `/tmp/zuvo-leads-*`
   scratch files are the only non-output-directory writes allowed, and they are
   created+read+deleted within a single agent invocation.
