# Cross-Provider Adversarial Review

Run an adversarial code review using a DIFFERENT AI provider to catch blind spots shared between the code author (Claude) and the internal reviewer (also Claude).

## Why

The same model family shares systematic blind spots. Code written by Claude and reviewed by Claude misses the same classes of bugs. A different model (Gemini, GPT, Qwen) catches 30-40% more issues because it has different training biases.

## How It Works

The script `adversarial-review` auto-detects the best available provider and runs a hostile review:

1. **Gemini CLI** (free, recommended) — different model family, zero cost
2. **Codex CLI** (OpenAI) — GPT-based, needs ChatGPT subscription or API key
3. **Ollama** (local) — runs Qwen2.5-Coder locally, zero cost, needs GPU

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
# adversarial-review resolves automatically — the skill's fallback line handles path lookup.
# Just call: adversarial-review --json --mode {MODE} ...
# If not in PATH, use the fallback from the calling skill's adversarial section.
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

# Alternative: Gemini CLI (free)
npm install -g @google/gemini-cli
gemini   # first run: login with Google account

# Alternative: Claude CLI (comes with Claude Code)
# Already installed if you use Claude Code.

# Alternative: Gemini API (free tier, 250 req/day)
export GEMINI_API_KEY=<key from aistudio.google.com>
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
