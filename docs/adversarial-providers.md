# Adversarial Review — Provider & Model Matrix

> Which AI providers `adversarial-review` can use for cross-model code review, what model each runs,
> how to install/authenticate them, and what is working headless right now.

The single source of truth is [`scripts/adversarial-review.sh`](../scripts/adversarial-review.sh).
This doc is generated from it — if they disagree, the script wins.

## Why cross-model

The same model shares systematic blind spots: code written by Claude-Opus and reviewed by
Claude-Opus misses the same things. `adversarial-review` runs a hostile review with a **different
model** than the author — never author-reviews-author. The requirement is **cross-MODEL**, and the
strength tiers are:

1. **Different vendor** (best) — e.g. Opus author reviewed by `agy`/Gemini or `codex`/OpenAI. Use
   `--multi` to require ≥2 providers and get multi-vendor consensus.
2. **Different model, same vendor** (valid fallback) — `run_claude` flips Opus↔Sonnet and codex flips
   5.3↔5.4. This is a genuine independent check, NOT self-review, and it keeps a local reviewer alive
   when no external vendor is installed. It is weaker than cross-vendor (shared family priors), so it
   is a fallback, not the goal.

Self-review (same model reviews its own output) is the ONLY thing that is never allowed — the host
self-exclusion below enforces it.

## Provider matrix

| Provider | Vendor | Default model | Override env | Invocation (headless) |
|----------|--------|---------------|--------------|-----------------------|
| `agy` | Google (Antigravity) | `Gemini 3.1 Pro (High)` | `ZUVO_AGY_MODEL` | `agy -p "<prompt>" --model <m> --dangerously-skip-permissions` (prompt = **arg**) |
| `codex-5.3` / `codex-5.4` | OpenAI | `gpt-5.6-sol` / `gpt-5.4` | `ZUVO_MODEL_CODEX_PRIMARY` / `ZUVO_MODEL_CODEX_ALT` | `codex` (spark/gpt lane; 5.6 needs codex CLI ≥0.144) |
| `claude` | Anthropic | Opposite of author: `claude-sonnet-5` (Opus author) or `claude-opus-5` (Sonnet/Haiku author) | `ZUVO_CLAUDE_REVIEWER_MODEL` (Sonnet branch) | `claude --model <m> --print --output-format text` |
| `cursor-agent` | Cursor | `composer-2.5-fast` | `ZUVO_CURSOR_MODEL` | `… \| cursor-agent -p --model <m> --mode ask --trust --workspace /tmp` (prompt = **stdin**) |
| `gemini-api` | Google (API) | `gemini-3.1-pro-preview` | `ZUVO_GEMINI_API_MODEL` | `curl` to Gemini API (needs `GEMINI_API_KEY`) — fallback only |
| `gemini` (CLI) | Google (free/OAuth) | `gemini-3.1-pro-preview` | `ZUVO_GEMINI_MODEL` | **DEAD for individuals** — see below |
| `kimi` | Moonshot (Kimi) | CLI default (`kimi-code/k3`, OAuth) | `ZUVO_KIMI_CLI_MODEL` (`-m` alias; empty = CLI default) | `kimi -p "<prompt>" --output-format stream-json` (prompt = **arg**; assistant lines extracted via jq — plain text mode leaks reasoning bullets + resume footer). Runs from tmpdir, never `-y`. |
| `kimi-api` | Moonshot (Kimi) | `kimi-k2.6` | `ZUVO_KIMI_MODEL` (`kimi-k2.7-code` = coding variant) | `curl` to `api.moonshot.ai/v1/chat/completions` (OpenAI-compatible) — fallback when the CLI is absent and `MOONSHOT_API_KEY` is set; `ZUVO_KIMI_BASE_URL` for the `.cn` endpoint |
| `codestral` | Mistral | `codestral-latest` | `ZUVO_CODESTRAL_MODEL` | manual only (`--provider codestral`, needs `CODESTRAL_API_KEY`) |

The prompt is passed to `agy -p` as an **argument, not stdin** (stdin makes agy answer an empty
prompt). `--model` values for `agy`/`cursor-agent` are the **display / id strings** from
`agy models` / `cursor-agent models`.

## Current status (2026-07-11)

**Working headless 4-way cross-model:**

| Provider | Model | Status | Typical latency |
|----------|-------|--------|-----------------|
| `agy` | Gemini 3.1 Pro (High) | ✅ working | ~9s |
| `codex-5.3` | gpt-5.6-sol | ✅ working (benchmarked 2026-07-19: 18s, most complete findings of the 5.6 family; needs codex CLI ≥0.144) | ~10-30s |
| `claude` | Sonnet 5 (Opus author) | ✅ working | ~40s |
| `cursor-agent` | Composer 2.5 Fast | ✅ working (after `cursor-agent login`) | ~19s |
| `gemini` (free CLI) | — | ❌ dead: `IneligibleTierError: UNSUPPORTED_CLIENT` | — |
| `kimi` (CLI) | kimi-code/k3 (K3, OAuth) | ✅ working — verified E2E 2026-07-19: standalone caught a planted missing-`/100` discount bug; full pipeline returned structured findings | ~7-60s |
| `kimi-api` | kimi-k2.6 | ⏸ wired fallback, activates only when CLI absent + `MOONSHOT_API_KEY` set (smoke-tested: bad key → provider FAIL, not fake CLEAN) | ~2-5s expected |

> **The free `gemini` CLI is dead for individuals.** Google returns
> `IneligibleTierError … "migrate to the Antigravity suite of products"` and upgrading the CLI does
> **not** fix it (it is account-tier, not client-version). Use **`agy`** (the sanctioned Antigravity
> channel) or a billing-enabled `GEMINI_API_KEY` (`gemini-api`) instead. `detect_providers` already
> prefers `agy` over the dead CLI.

## Install & authenticate

```bash
# Google Gemini via agy (Antigravity CLI) — the working paid channel
curl -fsSL https://antigravity.google/cli/install.sh | bash    # -> ~/.local/bin/agy (SHA512-verified)
# then sign in via the Antigravity app; verify:
agy -p "reply OK" --dangerously-skip-permissions
agy models            # list available models (Gemini 3.5 Flash / 3.1 Pro, Claude 4.6, GPT-OSS)

# OpenAI via Codex CLI
npm install -g @openai/codex
codex                 # first run: login with ChatGPT

# Anthropic via Claude CLI — already installed if you use Claude Code

# Cursor Composer
curl https://cursor.com/install -fsS | bash
cursor-agent login    # or: export CURSOR_API_KEY=<key>
cursor-agent models   # composer-2.5-fast = "Composer 2.5 Fast (current)"

# Fallback: Gemini API (curl) — needs a billing-enabled key (free tier may hit IneligibleTier on 3.x-pro)
export GEMINI_API_KEY=<key from aistudio.google.com>
# export ZUVO_GEMINI_API_MODEL=gemini-2.0-flash   # if the pro-preview model is tier-blocked
```

## Detection & selection order

`detect_providers` builds the candidate list, in priority order, from installed CLIs:

1. `codex-5.3` (if `codex` present; adds `codex-5.4` when the host itself is spark `codex-5.3`)
2. Google Gemini — strict priority: **`agy`** → **`gemini-api`** (if `GEMINI_API_KEY` set) → the free
   `gemini` CLI (last resort, dead for individuals). So a working key is never shadowed by the dead CLI.
3. `cursor-agent` if installed
4. Moonshot Kimi — strict priority: **`kimi`** CLI (OAuth, K3) → **`kimi-api`** (if `MOONSHOT_API_KEY`
   set). Distinct vendor from every host we run under — never subject to self-review exclusion.
5. `claude` if installed

`codestral` is manual-only (`--provider codestral`, needs `CODESTRAL_API_KEY`).

## Doctor — verify providers actually WORK (not just exist)

`command -v <cli>` proves presence, not a working login. Field lesson 2026-07-19: fleet bots had
codex/gemini/claude on PATH with expired/revoked OAuth tokens — every review burned full provider
timeouts before discovering nothing could run. After provisioning a host or bot (and whenever
reviews start failing across the board), run:

```bash
adversarial-review --doctor        # probes each detected provider with a tiny prompt, 60s cap each
```

Output: `WORKING (Ns, model: …)` / `FAILED (exit N: first error line)` / `TIMEOUT` per provider +
a `usable providers: N/M` summary. Exit 0 when ≥1 works. Override per-probe cap with
`ZUVO_DOCTOR_TIMEOUT`. Verified 2026-07-19 on the Mac host: 5/5 WORKING (codex-5.3, agy,
cursor-agent, kimi, claude) in ~45s total.

### `provision-host.sh` — the doctor plus what to DO about it

`--doctor` answers "what works here". It cannot answer "what is missing and how do I add it",
because a CLI that was never installed is invisible to a probe over detected providers — which is
exactly the silent degradation this page opens with. `scripts/provision-host.sh` closes that half:

```bash
scripts/provision-host.sh                    # matrix + the exact install/login command per gap
scripts/provision-host.sh --install          # additionally offer to install MISSING CLIs (per-provider prompt)
scripts/provision-host.sh --remote h1 h2     # read-only probe over SSH, one block per host
scripts/provision-host.sh --quiet            # matrix only, for cron
```

Read-only by default; `--install` is local-only and prompts per provider, because remote installs
need per-host package managers and sudo. **Exit code is the fleet signal:** `0` = ≥2 usable
providers (real cross-model review possible), `1` = fewer (every review here will be
single-provider), `2` = the probe could not run at all. That makes it usable as a health check in
cron without parsing its output.

Its remediation commands mirror the "Install & authenticate" block above —
`tests/hooks/test-provision-host.sh` asserts they have not drifted apart.

Then the mode flag picks how many run:

| Flag | Behavior |
|------|----------|
| _(none)_ | all detected providers in parallel |
| `--multi` | REQUIRE ≥2 providers (else exit 3 `single_provider_only`) — cross-model consensus |
| `--rotate` | shuffle, pick ONE (sequential passes rotate a different provider each call) |
| `--single` | one provider |
| `--provider <name>` | force exactly that provider |
| `--exclude <name>` / `--exclude-last <name>` | drop a provider (rotation uses this) |

## When nothing comes back

"Every provider returned nothing" has three causes with three different correct responses. The
script separates them; a caller that collapses them into "provider infrastructure is blocked" is
guessing. This separation exists because of a concrete misdiagnosis: on 2026-07-30 a run that
started at 11:52 hit `Clamshell Sleep` at 11:53, woke at 13:32, and reported five dead providers.

| Exit | `status` | What actually happened | Response |
|------|----------|------------------------|----------|
| 124 | `timeout` | Providers were reachable and too slow, or the whole-run deadline fired | Do not retry inline; rotate or accept reduced coverage |
| 125 | `suspended` | The **host** slept mid-run (`suspended_seconds` says how long) | Retry once — nothing was actually attempted |
| 2 | `error` | Providers were reached and refused or errored | Read `evidence_dir` before naming a cause |

Suspension is measured, not guessed: the script samples a monotonic clock (which does not tick
while the machine is asleep) alongside the wall clock, and the gap between them is the sleep.

**Failure evidence.** When a run produces no review at all, every provider's stderr is copied to
`~/.zuvo/adversarial-failures/<run_id>/` with a `meta.txt` (mode, dispatch, providers, outcomes),
kept 7 days. Before this existed the tmpdir was deleted on exit, which is why the largest class of
failures — providers that reject in under 30 seconds, i.e. auth or quota or rate limit — could not
be told apart after the fact.

**Timeouts are hard.** Each provider runs under `timeout -k` (grace: `ZUVO_TIMEOUT_GRACE`, default
15s), so a CLI that ignores SIGTERM is still killed, and provider output is captured through files
rather than `$( )` so a surviving grandchild cannot hold the pipe open. A whole-run deadline
(`ZUVO_RUN_DEADLINE`) is the backstop. Before these, 94 of 5989 runs over 30 days exceeded their
240/360s budget, the worst at 34273s — 9.5 hours.

## Host self-exclusion (no self-review)

`detect_host_platform` detects which model is DRIVING the current session and auto-excludes it, so a
provider never reviews its own author:

| Host | Excluded / adjusted |
|------|---------------------|
| Codex (spark `codex-5.3`) | flip to `codex-5.4` (and vice versa) so a codex still reviews cross-model |
| Antigravity (`ANTIGRAVITY_SESSION_ID` / app path) | exclude **every Gemini lane the script can reach** — the host's model is Gemini, so no Gemini lane may review it. Which lanes those are differs per script, see below |
| Cursor (app path) | exclude `cursor-agent` |
| Claude | **KEPT** — `run_claude` flips Opus↔Sonnet, so it is genuinely cross-model, not self-review |

**Why the asymmetry** (Gemini family fully excluded, but Claude/Codex kept-with-flip): the Claude and
Codex flips (Opus↔Sonnet, 5.3↔5.4) are a same-vendor cross-MODEL check that keeps a local reviewer
alive when no external vendor is installed. `agy` has no equivalent non-Gemini flip, and on an
Antigravity host excluding the whole Gemini family still leaves `codex` + `claude` + `cursor` (three
external vendors) — better coverage than a Gemini-flips-Gemini check. So the rule is: keep a
same-vendor flip only when it is the best remaining option, exclude the family when stronger
cross-vendor lanes remain.

**A host is a SET of clients, and the set is per-script.** This table said "the entire Gemini family
(`agy`, `gemini-api`, `gemini`)" until 2026-08-12, when two of those three turned out not to exist:
`adversarial-review.sh`'s valid-provider list is `codex-5.3|codex-5.4|agy|cursor-agent|kimi|kimi-api|
codestral|claude` — no `gemini`, no `run_gemini`, and `gemini-api` was dropped with the free-tier
CLI on 2026-08-04. So there the Gemini family is `agy` alone, and `detect_host_platform` returning
`"agy gemini"` names one live lane plus one defensive placeholder (harmless: it is filtered against a
list that cannot contain it, and it keeps the hole shut if `gemini` is ever re-added).

`blind-audit-codex.sh` is the opposite case and the reason this matters: it DOES dispatch `gemini`
(`--provider codex|agy|gemini|claude`), so there `HOST_EXCLUDE="gemini agy"` excludes two REAL lanes.
Until 2026-08-11 it excluded only `gemini`, leaving `agy` — the same underlying model through a second
client — free to audit its own host's output, with the exclusion applied and announced. Check the
script's own valid-provider list before assuming a name in this table is live in it.

**Prompt delivery differs by CLI:** `agy` takes the prompt as a command **argument** (`agy -p "<prompt>"`);
`cursor-agent`, `claude`, and `codex` read it from **stdin** (`printf … | cursor-agent -p …`). This is
why `run_agy` passes `"$REVIEW_PROMPT"` inline while the others pipe it.

## Known limitations

- **Antigravity host running a non-Gemini model.** `agy models` also exposes Claude 4.6 and GPT-OSS.
  Host detection assumes the Antigravity *default* (Gemini) and excludes the Gemini family — it cannot
  see which model an Antigravity session actually selected. If you switch your Antigravity model to
  Claude, the `claude` provider is NOT auto-excluded (a potential Claude-reviews-Claude). Mitigation:
  export `CLAUDE_MODEL=<your Antigravity model>` (so `run_claude` flips to the opposite) or pass
  `--exclude claude` for that session.
- **No live provider health probe yet.** A dead-but-installed CLI (e.g. an unauthenticated
  `cursor-agent`) is still attempted and only skipped after it fails/times out. Keep providers logged
  in, or use `--provider`/`--exclude` to pin the working set.

## Timeouts

- Per-provider timeout: `ZUVO_REVIEW_TIMEOUT` seconds (default `240`, `360` for
  article/spec/plan/audit modes). A provider that exceeds it is skipped (`WARN … timed out`), not
  fatal.
- For a tiny diff (TIER 0), the `zuvo:review` skill scopes adversarial to ONE `--single` pass with a
  60s ceiling — see `skills/review/SKILL.md` §1.6 (proportionality).

<!-- Evidence Map
| Section | Source file(s) |
|---------|---------------|
| Provider matrix — models | scripts/adversarial-review.sh:999-1012 (provider_model) |
| agy invocation + default | scripts/adversarial-review.sh:830-856 (run_agy) |
| claude opposite-model | scripts/adversarial-review.sh:746-779 (run_claude) |
| cursor-agent invocation | scripts/adversarial-review.sh:781-799 (run_cursor_agent) |
| codex lane | scripts/adversarial-review.sh:707-745 (run_codex) |
| gemini-api fallback | scripts/adversarial-review.sh:898+ (run_gemini_api) |
| Detection order | scripts/adversarial-review.sh:581-628 (detect_providers) |
| gemini CLI dead / prefer agy | scripts/adversarial-review.sh:607-616 (detect_providers comment) |
| Host self-exclusion | scripts/adversarial-review.sh:514-569 (detect_host_platform + exclusion) |
| ENV vars | scripts/adversarial-review.sh:115-131 (help) |
| TIER-0 proportionality | skills/review/SKILL.md §1.6 |
-->
