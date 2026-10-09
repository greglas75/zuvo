# Adversarial Review — Provider & Model Matrix

> How a model or effort gets CHOSEN for a lane (benchmark, pitfalls, noise): `docs/runbook/model-benchmark.md`.
>
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
| `agy` | Google (Antigravity) | `Gemini 3.8 Flash (Medium)`; no quota fallback by default (Opus 4.6 retired by Antigravity) | `ZUVO_AGY_MODEL` / `ZUVO_AGY_FALLBACK_MODEL` | `agy -p "<prompt>" --model <m> --dangerously-skip-permissions` (prompt = **arg**) |
| `codex-5.3` | OpenAI | `gpt-6-sol` @ effort `none` | `ZUVO_MODEL_CODEX_PRIMARY` / `ZUVO_CODEX_EFFORT_PRIMARY` (`ZUVO_CODEX_EFFORT` sets both codex lanes' effort when the per-lane one is unset) | `codex` (gpt-6 ids need codex CLI ≥0.156; `codex_cli_guard` downgrades automatically on older) |
| `codex-5.4` | OpenAI | `gpt-6-luna` @ effort `medium` | `ZUVO_MODEL_CODEX_ALT` / `ZUVO_CODEX_EFFORT_ALT` | **not auto-selected** — reachable only by `--provider codex-5.4` (see roster note below) |
| `claude` | Anthropic | Opposite of author: `claude-sonnet-5-5` (Opus author; `ZUVO_MODEL_CLAUDE_REVIEWER_SONNET`) or `claude-opus-5-5` @ effort `high` (Sonnet/Haiku author or a Codex host; `ZUVO_MODEL_CLAUDE_REVIEWER_OPUS`) | `ZUVO_CLAUDE_REVIEWER_MODEL` (Sonnet branch, wins over the registry) / `ZUVO_MODEL_CLAUDE_REVIEWER_SONNET` / `ZUVO_MODEL_CLAUDE_REVIEWER_OPUS` | `claude --model <m> --print --output-format text` |
| `cursor-agent` | Cursor | `composer-2.5-fast` | `ZUVO_CURSOR_MODEL` | `… \| cursor-agent -p --model <m> --mode ask --trust --workspace /tmp` (prompt = **stdin**) |
| `gemini-api` | Google (API) | `gemini-3.1-pro-preview` | `ZUVO_GEMINI_API_MODEL` | `curl` to Gemini API (needs `GEMINI_API_KEY`) — fallback only |
| `gemini` (CLI) | Google (free/OAuth) | `gemini-3.1-pro-preview` | `ZUVO_GEMINI_MODEL` | **DEAD for individuals** — see below |
| `kimi` | Moonshot (Kimi) | `kimi-code/k3-256k` at effort `high` (OAuth) | `ZUVO_KIMI_CLI_MODEL` (`-m` alias), `ZUVO_KIMI_EFFORT` (`low\|high\|max`, passed per call as `KIMI_MODEL_THINKING_EFFORT`) | `kimi -p "<prompt>" --output-format stream-json -m <model> --agent-file <tool-less profile>` (prompt = **arg**; assistant lines extracted via jq — plain text mode leaks reasoning bullets + resume footer). The profile declares `tools: []`: the default agent ran shell commands mid-review. Runs from tmpdir, never `-y`. A 403 plan limit is outcome `quota`, not `empty`. |
| `kimi-api` | Moonshot (Kimi) | `kimi-k2.6` | `ZUVO_KIMI_MODEL` (`kimi-k2.7-code` = coding variant) | `curl` to `api.moonshot.ai/v1/chat/completions` (OpenAI-compatible) — fallback when the CLI is absent and `MOONSHOT_API_KEY` is set; `ZUVO_KIMI_BASE_URL` for the `.cn` endpoint |
| `codestral` | Mistral | `codestral-latest` | `ZUVO_CODESTRAL_MODEL` | manual only (`--provider codestral`, needs `CODESTRAL_API_KEY`) |

**Effort in the run log.** `~/.zuvo/adversarial.log` column 18 (`effort`, since 2026-10-09) is the
effort each lane actually ran at: the codex effort (the audit effort in `--mode blind-audit`), the
claude reviewer's `--effort` (empty for Sonnet, which runs at its default), kimi's
`KIMI_MODEL_THINKING_EFFORT` (empty when `kimi-api` answered for a failed CLI), and for agy the
`(Low|Medium|High)` level in the name of the model it ran. Empty means the lane sets no effort or did
not run — read it with the `outcome` column. Values are lowercased; one that then does not match
`[a-z][a-z0-9_-]{0,15}` is logged as `?`. Columns 1-17 are unchanged.

The prompt is passed to `agy -p` as an **argument, not stdin** (stdin makes agy answer an empty
prompt). `--model` values for `agy`/`cursor-agent` are the **display / id strings** from
`agy models` / `cursor-agent models`.

## Current status (2026-07-11)

**Working headless 4-way cross-model:**

| Provider | Model | Status | Typical latency |
|----------|-------|--------|-----------------|
| `agy` | Gemini 3.8 Flash (Medium) | ✅ working (benchmarked 2026-09-23, effort sweep: +25 defects nobody else finds, 75% precision, 0 timeouts — see `docs/runbook/model-benchmark.md`) | ~90-150s |
| `codex-5.3` | gpt-6-sol @`none` | ✅ working (benchmarked 2026-09-23 on 20 diffs: 93% precision, 38 REAL, 5 defects nobody else finds, 33s; needs codex CLI ≥0.156) | ~20-35s |
| `claude` | Sonnet 5 (Opus author) | ✅ working (benchmarked 2026-09-23: +21 defects nobody else finds, 83% precision) | ~40s |
| `cursor-agent` | Composer 2.5 Fast | ✅ working (after `cursor-agent login`) | ~19s |
| `gemini` (free CLI) | — | ❌ dead: `IneligibleTierError: UNSUPPORTED_CLIENT` | — |
| `kimi` (CLI) | kimi-code/k3-256k (K3-256k, OAuth, effort high) | ✅ working — bench 2026-09-24: 20/20 diffs, 86 real defects, 83% precision (best of 8 kimi variants; table in `shared/includes/model-registry.sh`) | ~84s |
| `kimi-api` | kimi-k2.6 | ⏸ wired fallback, activates only when CLI absent + `MOONSHOT_API_KEY` set (smoke-tested: bad key → provider FAIL, not fake CLEAN) | ~2-5s expected |

> **The free `gemini` CLI is dead for individuals.** Google returns
> `IneligibleTierError … "migrate to the Antigravity suite of products"` and upgrading the CLI does
> **not** fix it (it is account-tier, not client-version). Use **`agy`** (the sanctioned Antigravity
> channel) or a billing-enabled `GEMINI_API_KEY` (`gemini-api`) instead. `detect_providers` already
> prefers `agy` over the dead CLI.

## Usage & billing — `~/.zuvo/adversarial-stats`

A lane name is an **account slot, not a model**: `byteplus-3` is "the third BytePlus slot", and its
model comes from an env variable (`ZUVO_MODEL_BYTEPLUS_3`, …). One vendor can run three unrelated
models (2026-09-30: `byteplus` = glm-5.3-flash, `byteplus-3` = dola-seed-2.0-code, `byteplus-alt`
= deepseek-v4-flash). So never report usage per lane alone:

**The BytePlus lanes stream (`"stream": true`, since 2026-10-05).** The Coding Plan endpoint closes a
non-streaming request after ~60 s without a byte (curl exit 16 over HTTP/2, 52 over HTTP/1.1), and a
reasoning model on a real diff thinks for minutes — so before streaming, every such review ended
"empty" at ~62 s (11 of 43 production calls answered, 2026-10-04/05). `openrouter_assemble_stream`
folds the SSE body back into the non-streaming shape; OpenRouter lanes are unchanged. A stream that is
not whole — a torn or non-object event, no `[DONE]` and no `finish_reason`, an assembly failure — is
never a review: it fails with a named reason and is retried like a dropped connection (as are curl
18/92). An error event the provider sent on purpose is not retried. Still open: glm-5.3-flash needs
3-10 min per review (bench rerun 2026-10-06: 171-576 s), so the slowest diffs exceed the 500 s lane
timeout — backlog `B-20261006-BYTEPLUS-GLM-TIMEOUT-VS-500S`.

```bash
~/.zuvo/adversarial-stats                 # last 7 days: LANE, MODEL, PAYS, RUNS, OK%, P50/P90, FIND, CRIT, FAILURES
~/.zuvo/adversarial-stats --days 30 --project zuvo-plugin
~/.zuvo/adversarial-stats --markdown      # for a chat or a doc
```

**Rule: every usage summary table ends with the billing links** of the vendors in it — the tool
prints them; a hand-made table must too. `CRIT` is what a model *reported*, not what was right.

| Vendor | Lanes | Where the usage / bill is |
|---|---|---|
| BytePlus ModelArk (Coding Plan) | `byteplus`, `byteplus-alt`, `byteplus-3` | https://console.byteplus.com/ark/region:ap-southeast-1/subscription/coding-plan |
| OpenRouter (per token) | `openrouter`, `openrouter-alt`, `openrouter-3`, `openrouter-4` | https://openrouter.ai/activity |
| Alibaba Model Studio (Token Plan Intl) | `qwen` | https://modelstudio.console.alibabacloud.com/ap-southeast-1/subscription/token-plan/personal |
| OpenAI (ChatGPT plan) | `codex-5.3`, `codex-5.4` | https://chatgpt.com/codex/settings/usage |
| Anthropic (Claude plan) | `claude` | https://claude.ai/settings/usage |
| Cursor | `cursor-agent` | https://cursor.com/dashboard?tab=usage |
| Mistral | `codestral` | https://console.mistral.ai/usage |
| Google Antigravity | `agy` | no usage page recorded |
| Moonshot Kimi Code | `kimi` | no usage page recorded |
| Moonshot API (per token) | `kimi-api` | no usage page recorded |
| Google Gemini API | `gemini`, `gemini-api` | no usage page recorded |
| Muse | `muse` | no usage page recorded |

Qwen models reach the panel through TWO bills: the `qwen` lane (Alibaba Token Plan, gated by
`ZUVO_ADV_QWEN=1`) and the `openrouter` lane (`qwen/qwen3.8-flash`, gated by
`ZUVO_ADV_OPENROUTER=1`). Alibaba's usage page shows nothing while `ZUVO_ADV_QWEN` is off.
New lane → add its vendor to `BILLING` in `scripts/zuvo-home/adversarial-stats` AND a row here;
`tests/hooks/test-adversarial-stats.sh` fails when this table is missing a `BILLING` vendor or URL.

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

`detect_providers` builds the candidate list from installed CLIs, in **measured** priority order:

1. `cursor-agent` if installed
2. `agy` (Antigravity) — the only Gemini lane; `gemini`/`gemini-api` were removed 2026-08-04
3. `codex-5.3` (if `codex` present). `codex-5.4` is **never** added automatically, not even on a codex host: self-review exclusion removes the host's own lane, and adding a second OpenAI model back would make the panel *less* cross-model than the ten remaining lanes already are.
4. `claude` if installed
5. Moonshot Kimi — strict priority: **`kimi`** CLI (OAuth, K3) → **`kimi-api`** (if `MOONSHOT_API_KEY`
   set). Distinct vendor from every host we run under — never subject to self-review exclusion.

`codestral` is manual-only (`--provider codestral`, needs `CODESTRAL_API_KEY`).

The order is not a preference — it is the ranking measured over ~43,000 provider invocations in
`~/.zuvo/adversarial.log` (30 days to 2026-08-19; mock and test-fixture rows excluded, and
`not-attempted` rows excluded from the denominator so each provider is judged only on calls it
actually received):

| provider | attempted | ok% | timeout% | empty% | find/ok | crit/ok | **crit per attempt** | p50 | p90 |
|---|---|---|---|---|---|---|---|---|---|
| `cursor-agent` | 5,648 | 87% | 2% | 11% | 6.85 | 1.02 | **0.89** | 53s | 93s |
| `agy` | 5,489 | 53% | 9% | 38% | 4.89 | 1.42 | **0.75** | 69s | 200s |
| `claude` | 5,286 | 97% | 3% | 0% | 2.05 | 0.39 | 0.38 | 145s | 240s |
| `kimi` | 5,299 | 48% | 11% | 41% | 5.12 | 0.65 | 0.31 | 133s | 208s |
| `codex-5.3` | 5,946 | 87% | 1% | 12% | 2.44 | 0.33 | 0.29 | 38s | 61s |

`codex-5.3` holds the third slot over the nominally higher-yield `claude` because subset coverage,
not per-provider yield, is what a 3-provider fan-out buys: over the same window `agy+codex+cursor`
covers **91.9%** of runs that produced any CRITICAL and **90.6%** of runs that produced any finding,
versus 91.4% / 83.1% for `agy+claude+cursor`. `claude` is also the wall-clock setter in 30-36% of
runs, and `kimi` returns nothing 41% of the time.

**Caveat on what this measures.** The log records finding COUNTS, not whether a finding was
accepted. So this ranks reviewers on yield, reliability and latency — a volume proxy, not precision.
Per-finding dispositions (which would make it a precision ranking) are the subject of the unmerged
`feat/adversarial-effectiveness` branch.

## Fan-out cap (`ZUVO_REVIEW_MAX_PROVIDERS`, default 3)

Every detected provider used to run. With five installed, one review meant five CLI calls — measured
over 30 days: 9,613 adversarial invocations → **43,228 provider calls**, 890M characters shipped to
external providers, **387 hours** of summed wall-clock, against 891 skill runs in the last week alone
(~2.5 adversarial passes per skill run).

The cap keeps the top N of the list above and drops the rest, announcing both sets on stderr:

```
  Fan-out cap: keeping top 3 by measured yield (cursor-agent agy codex-5.3); not running: claude kimi
```

At the default 3 that is **39% fewer provider calls and 35% less wall-clock** for ~92% of the
CRITICAL coverage. It is applied **last** — after host self-exclusion, `--exclude`, `--exclude-last`
and the auth-failure cache — so it always keeps the best N *still standing*, not three chosen before
the host reviewer was removed. `--provider <name>` bypasses it. Raise it with
`ZUVO_REVIEW_MAX_PROVIDERS=5`; a non-numeric or zero value warns and falls back to 3 rather than
filtering the list to nothing.

**The cap freezes the data that justifies it.** Capped-out providers stop appearing in
`~/.zuvo/adversarial.log` entirely, so the ranking above cannot refresh itself and a provider that
improves (or one that quietly rots) will never show it. Before re-ranking, run a sampling window
with `ZUVO_REVIEW_MAX_PROVIDERS=5` for a day or two, then recompute from the log — do not compare a
capped period against an uncapped one, since the capped period has no rows for the dropped
providers at all.

**Volume is not value — the findings ledger.** `find/ok` and `crit/ok` above count what a lane
SAID, not what was true: a lane that emits seven speculative issues outranks one that finds two real
bugs. `~/.zuvo/adversarial-findings.log` closes that gap. Every review appends one row per distinct
finding that carries a fingerprint — the `ID:` line of the text format, the `id` of `--json` (provider,
model, fingerprint, severity, project = the main checkout's path),
and the triaging agent appends a verdict per `id` (`adversarial-loop.md` Step 4.9):

```bash
~/.zuvo/adversarial-review --record-disposition "<id>" fixed --record-disposition "<id>" rejected
~/.zuvo/adversarial-review --effectiveness   # per model: raised, CRIT, fixed/deferred/rejected, open, precision
```

precision = (fixed + deferred) / judged; `rejected` is the false-positive column and unjudged
findings are excluded, not counted against the lane. A verdict judges the raises logged before it; a
later raise of the same `id` is a new, open occurrence. A finding without an ID is not recorded (no
verdict could join it); `--mode blind-audit` runs are not recorded, and `mock-*` lanes never write the
real ledger. Rank lanes on
precision × coverage from here, not on the table above.

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
rather than `$( )` so a surviving grandchild cannot hold the pipe open. A whole-run deadline is the
backstop: timeout + grace + 70 s in every mode — 585 s by default, inside the 600 s wrappers the
skills call it from, so a wedged lane ends with this run's exit 124 and its evidence rather than the
caller's kill — overridable with `ZUVO_RUN_DEADLINE`. `--single`/`--rotate` walk their lanes inside
that one budget: a lane after the first gets what is left (and is not started below the floor a lane's
own fallback uses), so a lane that timed out leaves nothing for the next — set `ZUVO_RUN_DEADLINE` to
allow a longer walk. A chunked run takes `ZUVO_RUN_DEADLINE`, when set, as the bound for ALL its parts:
each part gets what is left, and a part that would start with too little is not started (exit 4, a
`not_started` entry in `--json`). A negative or digit-less override falls back to that computed
deadline (a negative one — a `-` or a Unicode minus such as U+2212 before the first digit — with a
WARN naming it) rather than arming no watchdog at all; `0` still
disables the watchdog. Before these, 94 of 5989 runs over 30 days exceeded their 240/360s budget, the
worst at 34273s — 9.5 hours.

## Host self-exclusion (no self-review)

`detect_host_platform` detects which model is DRIVING the current session and auto-excludes it, so a
provider never reviews its own author:

| Host | Excluded / adjusted |
|------|---------------------|
| Codex (`codex-5.3`) | no flip — the lane is excluded and the panel is drawn from the other ten (non-OpenAI) lanes. The old flip dated from a driver with few providers, where losing one risked `single_provider_only`; with eleven lanes it only bought a weaker panel. |
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

## Blind coverage audit (`--mode blind-audit`)

One production file + its test file, audited against `shared/includes/blind-coverage-audit.md` by a
cross-vendor PANEL of lanes that cannot read anything but the prompt. It is a coverage audit, never a
review proof: `--artifact` is refused, and `post-skill-adversarial-check.sh` / `pg_artifact_proven`
ignore its rows. Every decision lives in `scripts/lib/blind-audit-panel.sh`; the driver only wires it.
Plan: `docs/specs/2026-09-25-blind-audit-panel-plan.md`.

```bash
adversarial-review.sh --mode blind-audit --production src/sum.sh --test tests/sum.test.sh [--protocol F] [--provider P] [--json]
```

| Flag | Meaning |
|------|---------|
| `--production F`, `--test F` | required; an empty file → exit 5, a missing one or a NUL byte → exit 2 |
| `--protocol F` | the protocol (must hold `Audit mode: strict`); default: the repo copy, then `~/.zuvo/` |
| `--provider P` | a panel of ONE lane — at best `degraded`, exit 3 |
| `--json` | the document below instead of the block |

Stdin, `--diff`, `--files`/`--file`, `--artifact`/`--append-artifact` are refused (exit 2); the three
flags above are refused in every other mode. Stdin counts as given when it is a pipe or a file (never a
tty or `/dev/null`) and a first byte arrives within 1 s — any byte, a NUL or a newline included. The
probe is bash's own bounded `read`, so it needs no `timeout` on PATH.

**The panel.** `ZUVO_BLIND_AUDIT_PANEL` lanes (default 3; `agy` pinned, the rest random) from the lanes
whose isolation is proven — `ZUVO_BLIND_AUDIT_ALLOWLIST` can only narrow that list, never add
`cursor-agent` or `muse`. An override that names only unproven lanes admits NOTHING: one stderr line
names the refused names, every candidate is dropped (one `Blind audit: excluding …` line names them),
and the run ends at the no-lane ERROR, exit 1. The host's whole vendor is excluded (a Claude host
drops `claude`). Both files go whole: above `ZUVO_BLIND_AUDIT_ARGV_MAX` bytes (120000) the argv lanes
`agy`/`kimi` are left out, above `ZUVO_BLIND_AUDIT_MAX_BYTES` (400000) nothing runs (exit 6). Nothing
is ever shortened.

**The answer.** Each reply must be a strict block (anchored markers, the protocol's exact table header,
no echo of the protocol's template). One that is not is outcome `invalid`. Valid answers merge into
ONE block: the worst verdict (REWRITE > FIX > CLEAN), every non-FULL row prefixed with its lane, and
a second line `Audit panel: strict|degraded valid=k/m providers=… verdicts=… failed=…`. The
`Prioritized findings` and `Highest-value missing test` sections of each answer are carried over too. A
line opens one of them when, after optional `#`s, a list marker or number and markup, it starts with
the title, and the title is followed only by optional closing markup, at most one `(…)` (a count or
qualifier, dropped) and markup again, then nothing or a colon plus inline text (kept as the section's
first line). Any other continuation, such as a word, a comma, a dash or `(…)` followed by more words,
is prose that happens to start with those words, not a section header.

| Exit | Meaning | stdout (text) |
|------|---------|---------------|
| 0 | strict — ≥ 2 valid answers | the merged block |
| 3 | degraded — exactly 1 valid answer (in the other modes 3 means `single_provider_only`) | the merged block |
| 2 | no valid answer — and, before any lane runs, a usage error (bad flag, missing file, NUL byte); and, after the lanes ran, an internal merge/JSON failure: the stderr ERROR names the step (`bap_merge`/`bap_json`), its rc, and the panel outcome it withheld (status, valid count, the exit it would have had) | EMPTY |
| 1 | no lane left after the exclusions — the ERROR block names each exclusion | empty |
| 5 | an empty production or test file | empty |
| 6 | the prompt is over `ZUVO_BLIND_AUDIT_MAX_BYTES` | empty |
| 124 / 125 | every lane timed out / the host slept, and nothing answered | empty |

`--json` prints one document in every one of those outcomes that reaches the lanes:
`{status, mode, verdict, valid_providers[], provider_outcomes, prompt_bytes, excluded_argv_lanes[],
merged_block, results{}}` — `status` is `strict|degraded|none|timeout|suspended`, `verdict` is null
without a valid answer, `provider_outcomes` is the same `lane:outcome,…` string as the other modes,
`excluded_argv_lanes` the argv lanes this prompt size rules out, `results` the raw reply of every lane
that answered, valid or not.

**Timeouts.** Per lane `ZUVO_BLIND_AUDIT_TIMEOUT` (default 480 s; `ZUVO_REVIEW_TIMEOUT` does not apply);
above 510 it is clamped with a WARN, and garbage or 0 falls back to 480 with a WARN (0 would mean *no*
timeout to GNU `timeout`). The whole-run deadline is timeout + `ZUVO_TIMEOUT_GRACE` + 60 and **never
passes 585 s**, so the run ends inside the 600 s Bash call its skill runs it in: 555 s by default, 585 s
at the 510 s clamp. `ZUVO_RUN_DEADLINE` does not apply either — a larger value would break that 585 s
invariant, a smaller one would SIGTERM the panel before a lane can answer, so it is ignored here with a
NOTE naming the (sanitized) value. The kill grace is part of that budget — a longer grace SHORTENS the
per-lane timeout instead of moving the deadline (grace 60 → 465 s per lane; one WARN names the effective
per-lane timeout and deadline). The floor is 1 s per lane (reached at 524 s of grace: 1 + 524 + 60 =
585); a grace too long even for that (≥ 525 s) is cut by the deadline itself: `bap_deadline` still
computes timeout + grace + 60, but then clamps that sum to the 585 s ceiling, so whatever a requested
grace of 525 s or more adds past 524 s is simply discarded — the whole run still ends at 585 s, not
later. Codex lanes run at `ZUVO_BLIND_AUDIT_EFFORT` (default `ZUVO_CODEX_EFFORT_AUDIT`, high).
`--single` and `--rotate` are ignored with a NOTE: the panel always runs in parallel.

**Health ledger.** Only outcomes that describe a lane's ACCOUNT are recorded: `ok`, `auth`, `quota`. A
`timeout`, an `empty` or an `invalid` answer (and any other outcome) describes this input or prompt — a
large file pair or a protocol a model misreads must not bench a lane that reviews code fine — and is
not recorded. `empty` is the driver's catch-all for a lane that produced no answer and was not
classified as a timeout, an auth stub, a quota limit or a missing runner — a CLI that rejected the
arguments it was given looks exactly the same — so it is not evidence of an outage either: the live
smoke (`tests/hooks/smoke-blind-audit.sh`, SMOKE-B2) excuses a failed panel as an infra outage (exit
75) only when every failed lane is `timeout`, `auth` or `quota` — never `empty`, `invalid` or any other
outcome, because `--json` carries nothing that tells those apart from a code or content regression.

**Logs and evidence.** `adversarial.log` gets one row per lane with column 3 `blind-audit`; its
`findings` column is the number of uncovered rows that lane contributed to the merged block (0 for an
invalid or failed lane), the severity columns stay 0, and there is no `SUMMARY` row. A run without a
valid answer keeps every lane's stderr AND each invalid reply under
`~/.zuvo/adversarial-failures/<run_id>/`, as the other modes do for a run without a review.

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

## Timeouts and ceilings

- Per-provider timeout: `ZUVO_REVIEW_TIMEOUT` seconds (default `500`, every mode; at least 1 — `0`
  would be `timeout 0`, no limit, and is refused with a WARN). A provider that exceeds it is skipped
  (`WARN … timed out`), not fatal. A lane's fallback (agy's second model, kimi's API lane) gets what
  is left of it, never a second full window.
- Input ceiling: `ZUVO_ADV_MAX_INPUT_BYTES` (default 8 MiB). The input is held whole and sent to
  several lanes; past the ceiling the run refuses (exit 2, nothing sent) — review it in parts.
- One lane's answer is kept up to 2 MiB (a review is a few KB); a longer one is cut, said in a WARN.
- A lane that fails says why: the driver's `failed or returned empty` line ends with the lane's own
  last WARN (a refused key, a billing endpoint, a malformed model id, its client's error), cleaned of
  terminal escapes.
- `ZUVO_SHARED_HOST=1`: agy and the kimi CLI are left out — their clients take the review prompt, the
  diff, as an argument, which every user of a shared host can read through `ps`. kimi-api, which sends a
  payload file, still reaches the same vendor.
- For a tiny diff (TIER 0), the `zuvo:review` skill scopes adversarial to ONE `--single` pass with a
  60s ceiling — see `skills/review/SKILL.md` §1.6 (proportionality).

<!-- Evidence Map
| Section | Source file(s) |
|---------|---------------|
| Provider matrix — models | scripts/lib/adversarial-providers.sh (provider_model) |
| agy invocation + default | scripts/lib/adversarial-lanes.sh (run_agy, _agy_attempt) |
| claude opposite-model | scripts/lib/adversarial-lanes.sh (run_claude), scripts/lib/adversarial-providers.sh (claude_reviewer_model) |
| cursor-agent invocation | scripts/lib/adversarial-lanes.sh (run_cursor_agent) |
| codex lane | scripts/lib/adversarial-lanes.sh (run_codex, run_codex_53, run_codex_54) |
| gemini-api fallback | removed 2026-08-04 — see the detect_providers comment in scripts/lib/adversarial-providers.sh |
| Detection order | scripts/lib/adversarial-providers.sh (detect_providers) |
| gemini CLI dead / prefer agy | scripts/lib/adversarial-providers.sh (detect_providers comment) |
| Host self-exclusion | scripts/lib/adversarial-providers.sh (detect_host_platform, ar_exclude_host_lanes) |
| ENV vars | scripts/lib/adversarial-cli.sh (ar_parse_args, the --help text) |
| TIER-0 proportionality | skills/review/SKILL.md §1.6 |
| Blind coverage audit | scripts/lib/adversarial-blind-audit.sh (the wiring), scripts/lib/blind-audit-panel.sh (the decisions), tests/hooks/test-adversarial-blind-audit.sh |
-->
