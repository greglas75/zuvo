# Cross-Provider Adversarial Review

Run an adversarial code review using a DIFFERENT AI provider to catch blind spots shared between the code author (Claude) and the internal reviewer (also Claude).

## Why

The same model family shares systematic blind spots. Code written by Claude and reviewed by Claude misses the same classes of bugs. A different model (Gemini, GPT, Qwen) catches 30-40% more issues because it has different training biases.

## How It Works

The script `scripts/adversarial-review.sh` auto-detects the best available provider and runs a hostile review:

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
SCRIPT_PATH="${PLUGIN_ROOT}/scripts/adversarial-review.sh"
CROSS_REVIEW_AVAILABLE=false
if [[ -x "$SCRIPT_PATH" ]]; then
  CROSS_REVIEW_AVAILABLE=true
fi
```

### Step 2: Run the review

```bash
# Option A: Pipe a diff
git diff HEAD~1 | "$SCRIPT_PATH" > /tmp/cross-review.md

# Option B: Specify diff ref
"$SCRIPT_PATH" --diff HEAD~3 > /tmp/cross-review.md

# Option C: Specify files
"$SCRIPT_PATH" --files "src/auth.ts src/user.ts" > /tmp/cross-review.md

# Option D: Force a provider
"$SCRIPT_PATH" --provider gemini --diff HEAD~1 > /tmp/cross-review.md
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

## Installation (for users)

```bash
# Recommended: Gemini CLI (free)
npm install -g @google/gemini-cli
gemini   # first run: login with Google account

# Alternative: Codex CLI
npm install -g @openai/codex
codex    # first run: login with ChatGPT

# Alternative: Ollama (local, free, needs GPU)
curl -fsSL https://ollama.com/install.sh | sh
ollama pull qwen2.5-coder:32b
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ZUVO_REVIEW_PROVIDER` | (auto-detect) | Force a specific provider: `gemini`, `codex`, `ollama` |
| `ZUVO_OLLAMA_MODEL` | `qwen2.5-coder:32b` | Ollama model for local review |
| `ZUVO_CODEX_MODEL` | (default) | Codex model override |
| `ZUVO_GEMINI_MODEL` | (default) | Gemini model override |
