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
| `agy` | Google (Antigravity) | `Gemini 3.5 Flash (High)` | `ZUVO_AGY_MODEL` | `agy -p "<prompt>" --model <m> --dangerously-skip-permissions` (prompt = **arg**) |
| `codex-5.3` / `codex-5.4` | OpenAI | `gpt-5.5` / `gpt-5.4` | — | `codex` (spark/gpt lane) |
| `claude` | Anthropic | Opposite of author: `claude-sonnet-5` (Opus author) or `claude-opus-4-8` (Sonnet/Haiku author) | `ZUVO_CLAUDE_REVIEWER_MODEL` (Sonnet branch) | `claude --model <m> --print --output-format text` |
| `cursor-agent` | Cursor | `composer-2.5-fast` | `ZUVO_CURSOR_MODEL` | `… \| cursor-agent -p --model <m> --mode ask --trust --workspace /tmp` (prompt = **stdin**) |
| `gemini-api` | Google (API) | `gemini-3.1-pro-preview` | `ZUVO_GEMINI_API_MODEL` | `curl` to Gemini API (needs `GEMINI_API_KEY`) — fallback only |
| `gemini` (CLI) | Google (free/OAuth) | `gemini-3.1-pro-preview` | `ZUVO_GEMINI_MODEL` | **DEAD for individuals** — see below |
| `codestral` | Mistral | `codestral-latest` | `ZUVO_CODESTRAL_MODEL` | manual only (`--provider codestral`, needs `CODESTRAL_API_KEY`) |

The prompt is passed to `agy -p` as an **argument, not stdin** (stdin makes agy answer an empty
prompt). `--model` values for `agy`/`cursor-agent` are the **display / id strings** from
`agy models` / `cursor-agent models`.

## Current status (2026-07-11)

**Working headless 4-way cross-model:**

| Provider | Model | Status | Typical latency |
|----------|-------|--------|-----------------|
| `agy` | Gemini 3.5 Flash (High) | ✅ working | ~9s |
| `codex-5.3` | gpt-5.5 | ✅ working | ~10-30s |
| `claude` | Sonnet 5 (Opus author) | ✅ working | ~40s |
| `cursor-agent` | Composer 2.5 Fast | ✅ working (after `cursor-agent login`) | ~19s |
| `gemini` (free CLI) | — | ❌ dead: `IneligibleTierError: UNSUPPORTED_CLIENT` | — |

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
4. `claude` if installed

`codestral` is manual-only (`--provider codestral`, needs `CODESTRAL_API_KEY`).

Then the mode flag picks how many run:

| Flag | Behavior |
|------|----------|
| _(none)_ | all detected providers in parallel |
| `--multi` | REQUIRE ≥2 providers (else exit 3 `single_provider_only`) — cross-model consensus |
| `--rotate` | shuffle, pick ONE (sequential passes rotate a different provider each call) |
| `--single` | one provider |
| `--provider <name>` | force exactly that provider |
| `--exclude <name>` / `--exclude-last <name>` | drop a provider (rotation uses this) |

## Host self-exclusion (no self-review)

`detect_host_platform` detects which model is DRIVING the current session and auto-excludes it, so a
provider never reviews its own author:

| Host | Excluded / adjusted |
|------|---------------------|
| Codex (spark `codex-5.3`) | flip to `codex-5.4` (and vice versa) so a codex still reviews cross-model |
| Antigravity (`ANTIGRAVITY_SESSION_ID` / app path) | exclude the **entire Gemini family** (`agy`, `gemini-api`, `gemini`) — the host's model is Gemini, so no Gemini lane may review it |
| Cursor (app path) | exclude `cursor-agent` |
| Claude | **KEPT** — `run_claude` flips Opus↔Sonnet, so it is genuinely cross-model, not self-review |

**Why the asymmetry** (Gemini family fully excluded, but Claude/Codex kept-with-flip): the Claude and
Codex flips (Opus↔Sonnet, 5.3↔5.4) are a same-vendor cross-MODEL check that keeps a local reviewer
alive when no external vendor is installed. `agy` has no equivalent non-Gemini flip, and on an
Antigravity host excluding the whole Gemini family still leaves `codex` + `claude` + `cursor` (three
external vendors) — better coverage than a Gemini-flips-Gemini check. So the rule is: keep a
same-vendor flip only when it is the best remaining option, exclude the family when stronger
cross-vendor lanes remain.

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
