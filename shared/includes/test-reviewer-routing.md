# Reviewer Routing & Preflight (write-tests)

> Single source of truth for how `zuvo:write-tests` resolves reviewer
> infrastructure: Phase-0 preflight, Step 3.5 blind-audit routing, Step 4
> adversarial routing. The SKILL references this file instead of restating it.

## Resolving `$ZUVO_BASE` (always first)

Bash resolves `../../` against the CWD — the user's PROJECT during a run — so
relative script paths do not exist when a skill shells out. Set `$ZUVO_BASE`
once with the canonical resolver, then call every script by absolute path:

```bash
ZUVO_BASE="$(~/.zuvo/zuvo-base)"   # empty + exit 3 if nothing resolves; add --why to see the rule
[ -n "$ZUVO_BASE" ] || { echo "ZUVO_BASE is empty — run '~/.zuvo/zuvo-base --why' to see which rule failed" >&2; exit 1; }
```

An empty `$ZUVO_BASE` carried forward silently builds a broken path (every later
`"$ZUVO_BASE/scripts/..."` call resolves to `/scripts/...`), so the guard above
stops the run right here instead of letting that failure surface three steps
later as a confusing "file not found".

`~/.zuvo/zuvo-base` is the one command every harness resolves the install root
with — see `env-compat.md` for what it checks, in order (a `$ZUVO_BASE` that
already contains `scripts/`, `installPath` from `installed_plugins.json`, the
semver-filtered cache dir, the Codex/Cursor/Antigravity/Kimi build roots, the
source checkout). `env-compat.md` also documents the pre-1.6.72 fallback recipe
for a host where the helper itself is not installed.

## Phase-0 preflight (BEFORE any test is written)

```bash
bash "$ZUVO_BASE/scripts/reviewer-preflight.sh"   # add --no-canary to skip the model round-trip
```

| `preflight_status` | Exit | Run consequence |
|--------------------|------|-----------------|
| `ok` | 0 | proceed normally |
| `degraded-routing` | 0 | proceed — `reviewer-model-route.sh` could not resolve a distinct Step-4 reviewer, so Step 4's fallback-local degrades accordingly. **Blind-audit strictness (Step 3.5) is independent of this status**: it comes from the panel's own `Audit panel: strict|degraded` line, never from routing — say so up front only for Step 4 |
| `no-provider` / `canary-failed` | 1 | **First run the out-of-band check below.** If it finds nothing, print `review infrastructure unavailable` IMMEDIATELY; the run is `DRAFT/BLOCKED_INFRA` from the start. Tests MAY still be written (they have standalone value) but no file may be reported `PASS`, and the completion block must carry the BLOCKED_INFRA list. Never burn a full pipeline pretending review will appear later. |

### `canary-failed` is NOT proof that cross-model review is unavailable

How the preflight picks and checks candidates:

- **Candidates** come from the blind-audit panel driver's own listing
  (`adversarial-review(.sh) --list-providers --mode blind-audit`; missing driver
  fails preflight CLOSED to `no-provider` — never a private fallback list), one
  client per vendor (`codex-5.3` / `codex-5.4` collapse to one `codex` canary).
  The driver has already applied vendor host exclusion (`claude` dropped under
  Claude Code; `codex-5.3`/`codex-5.4` on a Codex host — any ONE of
  `CODEX_SANDBOX`, `CODEX_SHELL=1`, `__CFBundleIdentifier=com.openai.codex`,
  `CODEX_INTERNAL_ORIGINATOR_OVERRIDE="Codex Desktop"`; `agy` under Antigravity;
  `cursor-agent` under Cursor) and the isolation allowlist that decides which
  lanes a blind audit may EVER run — a lane not on that allowlist (`cursor-agent`,
  `gemini`, `muse`) is never a candidate here, whatever the host is. Kept only
  when the shared runner can start it (`zms_client_available`: `ZUVO_CODEX_BIN` /
  `ZUVO_CLAUDE_BIN` when set, and a set value is final; then PATH; then the
  Codex.app fallback).
- **Every candidate is canaried, in that order, until one passes** — not just the first.
  `provider=` names the client that passed, or the first candidate when none did.
- **The canary asks for a computed answer:** `Reply with the product of 6 and 7, digits only.`
  It passes only when the client **exits 0** AND a line of its **stdout** reads `42`
  (blanks, markdown emphasis/backticks and a trailing period around it are trimmed;
  `142` or `The answer is 42` do not count). The prompt never contains the answer, so a
  client that echoes its input fails.
- **Isolated:** codex/claude run through the shared runner with no tools, no MCP servers
  and a neutral cwd; agy / cursor-agent / kimi / gemini run from an empty temp dir
  (never the repository) with stdin from `/dev/null` (gemini: the prompt), under GNU
  timeout. Without `timeout`/`gtimeout` on PATH no canary runs at all.

`canary-failed` therefore means every detected candidate failed THIS run, and stderr
carries one line per client saying why (timed out, exit N, not run: no model id / no GNU
timeout, auth error). A timeout or a missing model id is not an account-level verdict.
Treating that exit as "no reviewer exists" can downgrade a whole run to same-model for
no reason.

**On `canary-failed` / `no-provider`, re-check by hand before declaring
BLOCKED_INFRA** — a client the stderr shows as timed out or not run, or one installed
where the driver does not look. Canary it exactly as the preflight does:

```bash
# agy = Antigravity CLI; the same for cursor-agent / kimi. From an EMPTY temp dir, never
# the repository; stdin closed; bounded (GNU timeout — `gtimeout` if that is its name here).
d="$(mktemp -d)"
( cd "$d" && timeout -k 5 60 agy -p "Reply with the product of 6 and 7, digits only." \
    < /dev/null > "$d/out" 2> "$d/err" ); rc=$?
# Pass = exit 0 AND a stdout line reading 42 — never "the reply contains 42".
if [ "$rc" -eq 0 ] && tr -d '\r' < "$d/out" | sed -E 's/^[[:space:]*_`]+//; s/[[:space:]*_`.]+$//' | grep -qx '42'; then
  echo "agy answers"
else
  echo "agy canary failed (exit $rc)"
fi
rm -rf "$d"
```

Never use an echo-marker prompt ("respond with exactly this token: …"): the marker is in
the prompt, so a client that merely repeats its input passes.

If a candidate answers, run it directly as the Step 3.5 panel of one:

```bash
"$ZUVO_BASE/scripts/adversarial-review.sh" --mode blind-audit --provider <candidate> \
  --production "<absolute-path-to-production-file>" --test "<absolute-path-to-test-file>"
```

A single-lane run is recorded exactly like any exit 3: `panel=degraded`,
`clean:degraded` at best (never `clean:strict` — strict needs ≥ 2 valid answers).
It is still genuinely cross-vendor: the driver itself excludes the host's own
vendor from the candidate list, so a same-vendor `<candidate>` would have failed
with exit 1 here, not answered.

**Re-verify client health, never assume it** — the account-level status of any
client (works / dead / quota-exhausted) changes without notice. One canary per
client is enough: if the error names the account, tier, or client support, stop
and move to the next client rather than cycling through models on the same one.

## Blind-audit invocation (Step 3.5)

The audit runs through the panel, not through the writer/reviewer resolver below —
strictness comes from the merged output's own `Audit panel:` line, never from
`routing_status`.

```bash
"$ZUVO_BASE/scripts/adversarial-review.sh" --mode blind-audit \
  --production "<absolute-path-to-production-file>" \
  --test "<absolute-path-to-test-file>"
# installed alternative, same argv: ~/.zuvo/adversarial-review --mode blind-audit ...
```

Dispatches an isolated 3-provider panel (`agy` pinned + 2 random, cross-vendor
excluded) over the WHOLE production/test file pair — no chunking, no truncation.
On exit 0/3 print the merged block's second line (`Audit panel: strict|degraded
valid=<k>/<m> providers=<a,b,c> verdicts=...`) immediately after the run AND
again in the final Step 3.5 block. On exit 2 stdout is EMPTY — there is no line
to print. On any other exit, print the exit code and its outcome from the table
below instead.

| Exit | Outcome | `coverage.md` value |
|------|---------|----------------------|
| `0` | strict — ≥ 2 valid panel answers | `Audit panel: strict` + verdict → `clean:strict` / `fix:<n>` / `rewrite` |
| `3` | degraded — exactly 1 valid panel answer | `Audit panel: degraded` + verdict → `clean:degraded` / `fix:<n>` / `rewrite` |
| `2` | no valid panel answer | fall back below; `clean:degraded` at best |
| `1` | no provider lane after exclusion | fall back below; `clean:degraded` at best |
| `124` | all providers timed out, or the whole-run deadline fired — no panel answer at all | fall back below, same as exit 1/2; `clean:degraded` at best — a timeout says nothing about the input, and the fallback's own `degraded` label already records the lost isolation |
| `125` | the HOST slept mid-run (lid close/sleep); providers never had a chance | re-run the panel once — the RE-RUN's exit is then handled by this same table (a second `125` → fall back below, same as exit 1/2/124) |
| `5` | empty or unauditable production/test file | fix the input — not a reviewer failure |
| `6` | input over the byte cap | fix the input (split/shrink) — not a reviewer failure |

**Fallback (driver exit 1, 2, or 124 — or a second consecutive 125):** fall back
to the in-harness `blind-coverage-auditor` agent, routed by the CURRENT router
lanes below (`review-primary` / `same-model-fallback` / `unknown-writer-model` →
`blind-coverage-auditor`; `review-alt` → `blind-coverage-auditor-alt`;
`routing-failed` → no agent, mark `BLOCKED_INFRA` instead — the ONLY case here
that maps to `BLOCKED_INFRA`). Record the verdict with the normal values
(`clean:degraded` at best — never `clean:strict` — / `fix:<n>` / `rewrite`) and
the retrospective panel field as `panel=fallback:same-vendor`: a same-environment
fallback cannot prove the cross-vendor isolation the panel does.

The panel (and this fallback) receive ONLY: `blind-coverage-audit.md`, the
production file, the test file, an optional repo identifier. No CodeSift in
strict mode.

### Retro `blind_audit:` fields

`panel=<strict|degraded|fallback:same-vendor|none>` says HOW the verdict was reached: `strict`/`degraded` are the panel's own exit 0/3; `fallback:same-vendor` is the in-harness `blind-coverage-auditor` agent above (driver exit 1/2/124, or a second `125`); `none` is for `skipped`/`blocked_infra` with no audit output at all (`valid=0/0 providers=-`).

`rows=` is N from the audit output's own `INVENTORY COMPLETE: <N> rows` line — the merged panel block on `strict`/`degraded`, or the fallback auditor's block on `fallback:same-vendor` (same protocol, same line format, so the same rule reads it); `-` only for `panel=none`.

`exit=` is the driver exit that decided the outcome: after a `125` re-run it is the RE-RUN's exit, never the original suspended run's; for a fallback it is the driver exit that TRIGGERED it (`1`, `2`, `124`, or a second `125`).

## Reviewer-model resolution (Step 3.5 fallback + Step 4)

Writer-hint env precedence: `CLAUDE_MODEL` → `ZUVO_CODEX_MODEL` →
`CURSOR_AGENT_MODEL` → `CURSOR_MODEL` → `GEMINI_MODEL` → `ANTIGRAVITY_MODEL` →
`ZUVO_KIMI_CLI_MODEL` → `ZUVO_KIMI_MODEL` → `unknown`.

**Kimi Code has no writer-hint variable of its own.** It is the one host that exports
nothing identifying into its tool subprocess, so the resolver falls back to a PATH probe
for `~/.kimi-code/bin` — checked *after* every other host, because a PATH component is a
signal `env -u` cannot strip and an earlier check would make the answer depend on whether
the machine happens to have Kimi installed. Two consequences worth knowing here: a Kimi
session resolves to `platform=kimi writer_model=kimi-code` with no env set at all, and its
reviewer is the opposite in-family lane (`kimi-k2.6`) only when `MOONSHOT_API_KEY` makes
that lane reachable — otherwise the resolver falls through to a cross-host client exactly
as Cursor does, and reports `same-model-fallback` when none is installed rather than
naming a reviewer that cannot run.

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

The lane names above are exactly the fallback mapping used by the "Fallback"
paragraph under Blind-audit invocation (Step 3.5): this resolver decides which
fallback AGENT runs, never the panel's own strict/degraded verdict.

## Adversarial routing (Step 4)

Priority:

1. **Primary:** external cross-provider `~/.zuvo/adversarial-review --rotate`
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
