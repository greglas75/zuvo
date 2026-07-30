# Reviewer Routing & Preflight (write-tests)

> Single source of truth for how `zuvo:write-tests` resolves reviewer
> infrastructure: Phase-0 preflight, Step 3.5 blind-audit routing, Step 4
> adversarial routing. The SKILL references this file instead of restating it.

## Resolving `$ZUVO_BASE` (always first)

Bash resolves `../../` against the CWD — the user's PROJECT during a run — so
relative script paths do not exist when a skill shells out. Set `$ZUVO_BASE`
once (canonical recipe in `env-compat.md`), then call every script by absolute
path:

```bash
ZUVO_BASE="${ZUVO_BASE:-$(sed -n 's/.*"installPath"[[:space:]]*:[[:space:]]*"\([^"]*zuvo[^"]*\)".*/\1/p' \
  "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null | head -1)}"
[ -d "$ZUVO_BASE/scripts" ] || ZUVO_BASE=$(ls -d "$HOME/.claude/plugins/cache/zuvo-marketplace/zuvo"/*/ \
  2>/dev/null | grep -E '/[0-9]+\.[0-9]+\.[0-9]+/$' | sort -V | tail -1 | sed 's:/$::')
```

## Phase-0 preflight (BEFORE any test is written)

```bash
bash "$ZUVO_BASE/scripts/reviewer-preflight.sh"   # add --no-canary to skip the model round-trip
```

| `preflight_status` | Exit | Run consequence |
|--------------------|------|-----------------|
| `ok` | 0 | proceed normally |
| `degraded-routing` | 0 | proceed; blind audit will be `clean:degraded` at best — say so up front |
| `no-provider` / `canary-failed` | 1 | print `review infrastructure unavailable` IMMEDIATELY; the run is `DRAFT/BLOCKED_INFRA` from the start. Tests MAY still be written (they have standalone value) but no file may be reported `PASS`, and the completion block must carry the BLOCKED_INFRA list. Never burn a full pipeline pretending review will appear later. |

## Reviewer resolution (Step 3.5)

Writer-hint env precedence: `CLAUDE_MODEL` → `ZUVO_CODEX_MODEL` →
`CURSOR_AGENT_MODEL` → `CURSOR_MODEL` → `GEMINI_MODEL` → `ANTIGRAVITY_MODEL` →
`unknown`.

Run `$ZUVO_BASE/scripts/reviewer-model-route.sh` with **no override flags** and
a **5s timeout**. Never `eval` resolver output. Output is valid only when
stdout is exactly one single-line `KEY=VALUE` per key: `platform`,
`writer_model`, `writer_lane`, `reviewer_lane`, `reviewer_model`,
`routing_status`. Any missing/duplicate/unknown key, multi-line value, timeout,
missing script, or non-zero exit = `routing-failed`.

Print immediately after resolution AND again in the final Step 3.5 block:

```text
Reviewer routing: writer=<model>, reviewer=<model>, lane=<review-primary|review-alt|same-model-fallback>, status=<ok|same-model-fallback|unknown-writer-model|routing-failed>
```

Routing → agent artifact:

| Resolver result | Blind-audit agent |
|-----------------|-------------------|
| `reviewer_lane=review-primary`, `routing_status=ok` | `blind-coverage-auditor` |
| `reviewer_lane=review-alt`, `routing_status=ok` | `blind-coverage-auditor-alt` |
| `same-model-fallback` / `unknown-writer-model` | `blind-coverage-auditor`, record degraded routing, never describe as cross-model |
| `routing-failed` | no agent from lane data — only the fresh-subprocess wrapper may continue |

Strict isolated execution receives ONLY: `blind-coverage-audit.md`, the
production file, the test file, an optional repo identifier. No CodeSift in
strict mode.

## Canonical fresh-subprocess fallback

When agent-based strict isolation is unavailable or routing is
`routing-failed`:

```bash
"$ZUVO_BASE/scripts/blind-audit-codex.sh" \
  --protocol "$ZUVO_BASE/shared/includes/blind-coverage-audit.md" \
  --production "<absolute-path-to-production-file>" \
  --test "<absolute-path-to-test-file>"
```

The wrapper must exit `0` and emit a validated strict block (`Audit mode:
strict`, `Coverage verdict:`, `INVENTORY COMPLETE:`, the required table
header). If it is missing, exits non-zero, times out, or fails validation: do
NOT substitute an inline same-run audit. Mark the file `BLOCKED_INFRA`, persist
`Blind Audit=skipped`, set `Adversarial=blocked`, stop after backlog
persistence.

## Adversarial routing (Step 4)

Priority:

1. **Primary:** external cross-provider `adversarial-review --rotate`
   (fallback location: `$ZUVO_BASE/scripts/adversarial-review.sh`)
2. **Fallback-local:** same environment, different-from-writer read-only agent
   via the same resolver + 5s timeout + parser rules as above. Route
   `review-primary` → `adversarial-test-reviewer`, `review-alt` →
   `adversarial-test-reviewer-alt`. Requires `routing_status=ok`; on
   `same-model-fallback` / `unknown-writer-model` / `routing-failed` do NOT run
   local fallback — mark `SKIPPED_REVIEW`.
3. **Final degraded state:** `SKIPPED_REVIEW`.

Fallback-local is a degraded second opinion, valid only when the fallback
reviewer model differs from the writer model. Never label it cross-provider.
Persist as `clean:fallback-local` or `<n> findings:fallback-local`.
