# Cross-Provider Adversarial Review

Run an adversarial code review using a DIFFERENT AI provider to catch blind spots shared between the code author (Claude) and the internal reviewer (also Claude).

## Why

The same model family shares systematic blind spots. Code written by Claude and reviewed by Claude misses the same classes of bugs. A different model (Gemini, GPT, Qwen) catches 30-40% more issues because it has different training biases.

## How It Works

The script `adversarial-review` auto-detects the best available provider and runs a hostile review:

1. **codex-5.3** (OpenAI) — GPT-based (default `gpt-5.6-sol`), needs ChatGPT subscription or API key
2. **agy** (Antigravity CLI) — Google's Gemini 3.x via the paid Antigravity subscription. This is the
   sanctioned Gemini channel; the free `gemini` CLI is DEAD for individuals (Google returns
   `IneligibleTierError: UNSUPPORTED_CLIENT` → "migrate to Antigravity"). Install:
   `curl -fsSL https://antigravity.google/cli/install.sh | bash`, then sign in via the Antigravity app.
3. **cursor-agent** (Cursor) — needs `cursor-agent login` or `CURSOR_API_KEY`
4. **kimi** (Moonshot) — Kimi K3 via the `kimi` CLI (OAuth subscription; **no API key needed** — sign in
   with `kimi login`). Distinct vendor from every host we run under, so it is NEVER excluded by the
   self-review guard. Fallback `kimi-api` (curl, needs `MOONSHOT_API_KEY`) only when the CLI is absent.
5. **claude** (Anthropic) — kept as a cross-model reviewer (flips Opus↔Sonnet on a Claude host)
6. **gemini-api** (curl) — only with a billing-enabled `GEMINI_API_KEY` (fallback where agy is absent)

A genuine cross-model pass needs ≥2 DIFFERENT vendors. Working headless set as of 2026-07-19:
**codex-5.3 (OpenAI) + agy (Google) + cursor-agent (Cursor) + kimi (Moonshot) + claude (Anthropic)** — 5 vendors,
all verified WORKING via `adversarial-review --doctor`. Kimi's default model is `kimi-code/k3`.

The script outputs structured findings with severity, file:line, and suggested fixes.

## When to Run

| Skill | Condition | How |
|-------|-----------|-----|
| `zuvo:review` | TIER 2+ with 3+ production files | Automatic after internal adversarial pass |
| `zuvo:execute` | Complex tasks (4+ files) | After quality reviewer passes |
| `zuvo:ship` | 100+ LOC diff | After zuvo:review completes |
| `zuvo:code-audit` | `--deep` mode | After batch CQ evaluation |
| `zuvo:test-audit` | `--deep` mode | After batch Q evaluation |
| `zuvo:security-audit` | Always (security is high-stakes) | After Phase 7 (before report) |

## Integration Pattern (for skill authors)

### Step 1: Check availability

```bash
# Resolve $AR_CMD once (canonical resolver: shared/includes/env-compat.md). On Claude Code
# `adversarial-review` is NOT on PATH, so resolve the absolute wrapper instead of calling bare.
if command -v adversarial-review >/dev/null 2>&1; then
  AR_CMD=adversarial-review
else
  ZUVO_BASE="${ZUVO_BASE:-$(sed -n 's/.*"installPath"[[:space:]]*:[[:space:]]*"\([^"]*zuvo[^"]*\)".*/\1/p' \
    "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null | head -1)}"
  [ -d "$ZUVO_BASE/scripts" ] || ZUVO_BASE=$(ls -d "$HOME/.claude/plugins/cache/zuvo-marketplace/zuvo"/*/ \
    2>/dev/null | grep -E '/[0-9]+\.[0-9]+\.[0-9]+/$' | sort -V | tail -1 | sed 's:/$::')
  AR_CMD="$ZUVO_BASE/scripts/adversarial-review.sh"   # Codex/Cursor/Antigravity: built absolute
fi
# Then call: "$AR_CMD" --json --mode {MODE} ...
```

### Step 2: Run the review

```bash
# Option A: Pipe a diff
git diff HEAD~1 | "$AR_CMD" > /tmp/cross-review.md

# Option B: Specify diff ref
"$AR_CMD" --diff HEAD~3 > /tmp/cross-review.md

# Option C: Specify files
"$AR_CMD" --files "src/auth.ts src/user.ts" > /tmp/cross-review.md

# Option D: Force a provider
"$AR_CMD" --provider gemini --diff HEAD~1 > /tmp/cross-review.md
```

### Step 3: Parse results

Read the output file. Extract findings between the header/footer markers. Each finding has:
- `SEVERITY:` CRITICAL | WARNING | INFO
- `FILE:` path:line
- `ISSUE:` description
- `ATTACK VECTOR:` production failure scenario
- `SUGGESTED FIX:` brief fix

### Step 4: Merge with internal findings

- CRITICAL findings from cross-provider review are added as `[CROSS]` tagged items at MUST-FIX severity
- WARNING findings are added at RECOMMENDED severity
- INFO findings are added at NIT severity
- Deduplicate against internal findings (same file:line + same issue = drop)
- **Secret false-positive suppression.** Before promoting any "hardcoded secret" / `scan_secrets` finding, Read the cited `file:line`: if the match is on a COMMENT line (`//`, `#`, `/* */`, `--`, docstring), a `.env.example` placeholder, a test fixture, or an obvious placeholder token (`xxx`, `your-key-here`, `<REDACTED>`, `changeme`), DROP it — it is not a live secret. Only an assignment to a real config/runtime value on a non-comment line is a true finding. (A flood of comment-line secret false positives buries the one real leak.)

### Step 5: Report

In the final report, cross-provider findings are clearly marked:

```
R-N [MUST-FIX] [CROSS:gemini] Missing rate limiting on password reset endpoint
  File: src/auth/auth.controller.ts:45
  Confidence: 85/100
  Provider: Gemini 2.5
  Evidence: No rate limiter decorator on resetPassword handler
  Fix: Add @Throttle(5, 60) decorator
```

## Graceful Degradation

If no cross-provider tool is available:
1. Print a one-line notice: `[CROSS-REVIEW] No external provider available. Using internal adversarial pass only.`
2. Fall back to the internal adversarial agent (same model, different persona)
3. Do NOT block the review pipeline — cross-provider review is an enhancement, not a gate

## Large diffs

`--all-providers`/`--multi` combined with `--artifact` on a >5000-line (~600KB+) aggregate diff can exit 0 yet write NO artifact file — a silent no-artifact failure. Guard against it:

1. **Chunk or rotate above ~3000 lines.** For diffs over ~3000 lines, use `--rotate` (one provider per pass) instead of `--all-providers`, and/or pre-chunk the diff by file group and run a pass per group.
2. **Always verify the artifact exists and is non-empty** before treating a pass as complete: `[ -s "$ARTIFACT" ] || { echo "[CROSS-REVIEW] empty artifact — diff too large; rotate/chunk and retry"; }`. Exit 0 alone does NOT prove the pass produced findings.

## Installation (for users)

```bash
# Recommended: Codex CLI (fastest, needs ChatGPT sub)
npm install -g @openai/codex
codex    # first run: login with ChatGPT

# Google Gemini: agy (Antigravity CLI) — the paid, WORKING channel.
# The free @google/gemini-cli is dead for individuals (IneligibleTierError: UNSUPPORTED_CLIENT),
# so do NOT rely on it — Google forces the Antigravity suite.
curl -fsSL https://antigravity.google/cli/install.sh | bash   # installs ~/.local/bin/agy
# then sign in via the Antigravity app; verify: agy -p "reply OK" --dangerously-skip-permissions

# Claude CLI (comes with Claude Code) — already installed if you use Claude Code.

# Cursor: cursor-agent (login required)
curl https://cursor.com/install -fsS | bash
cursor-agent login          # or: export CURSOR_API_KEY=<key>

# Fallback: Gemini API (curl) — needs a billing-enabled key (free tier may hit IneligibleTier on 3.x-pro)
export GEMINI_API_KEY=<key from aistudio.google.com>
# export ZUVO_GEMINI_API_MODEL=gemini-2.0-flash   # if the pro-preview model is tier-blocked
```

## JSON Status Enum (2026-05-17 — adversarial-robustness A1+A2)

The script's `--json` output includes a `status` field. Skills should branch on it:

| `status` | Exit | Meaning |
|----------|------|---------|
| `ok` | 0 | All requested providers succeeded |
| `partial` | 0 | Some providers succeeded, others timed out or failed (`provider_count < attempted_count`) — proceed but surface `timeout_count` to user |
| `timeout` | 124 | ALL providers timed out (`provider_count == 0`) — no inline retry; caller chooses next action |
| `single_provider_only` | 3 | `--multi` or `--rotate` requested but only 1 provider available after host self-exclusion — caller must use `--single` or install another provider |
| `error` | 2 | All providers failed (non-timeout) |
| (n/a) | 130 | Interrupted (SIGINT — user pressed Ctrl-C) |
| (n/a) | 143 | Terminated (SIGTERM — orchestrator killed the process) |

Always-present count fields: `attempted_count`, `provider_count`, `timeout_count`.

For cross-call rotation (extracting last-used provider for `--exclude-last`), use the **array** field `providers_used_list[0]` — the string field `providers_used` cannot be indexed with `[0]` in jq.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ZUVO_REVIEW_PROVIDER` | (auto-detect) | Force: `codex-fast`, `gemini`, `claude`, `gemini-api`, `codex-mcp` |
| `ZUVO_CODEX_MODEL` | (default) | Codex model override |
| `ZUVO_GEMINI_MODEL` | `gemini-3.1-pro-preview` | Gemini CLI model |
| `ZUVO_GEMINI_API_MODEL` | `gemini-3.1-pro-preview` | Gemini API model |
| `GEMINI_API_KEY` | — | Required for gemini-api provider |
| `CLAUDE_MODEL` | — | Used for opposite-model detection |
