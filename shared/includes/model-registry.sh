#!/usr/bin/env bash
# shared/includes/model-registry.sh — SINGLE SOURCE OF TRUTH for the concrete AI model IDs the zuvo
# shell scripts pass to each provider CLI. Bump a model HERE when a new generation ships, instead of
# hunting hardcoded ids across scripts — that scatter is exactly how claude-sonnet-4-6 went a full
# generation stale (2026-07). Every value is env-overridable: an already-set ZUVO_MODEL_* wins.
#
# NOT for skill dispatch. skills/*.md use ABSTRACT tier labels (`model: sonnet|opus|haiku`) that the
# harness resolves to the current model at runtime — those need no registry and MUST stay abstract.
# This file is only for scripts that must name a concrete model id/string to a CLI (agy/codex/claude/
# cursor/gemini-api).
#
# Sourced by: adversarial-review.sh, benchmark.sh, reviewer-model-route.sh, blind-audit-codex.sh.
# Consumers ALSO keep an inline `:-<id>` fallback, so a missing/unsourced registry never breaks a run.
#
# Path: siblings `scripts/` and `shared/includes/` are copied together into every target (Claude
# cache, ~/.codex, ~/.cursor, ~/.gemini/antigravity), so a consumer resolves this as
# `"$(dirname "$0")/../shared/includes/model-registry.sh"` in all of them.

# ── Anthropic (Claude) ──────────────────────────────────────────────
ZUVO_MODEL_CLAUDE_OPUS="${ZUVO_MODEL_CLAUDE_OPUS:-claude-opus-5}"
ZUVO_MODEL_CLAUDE_SONNET="${ZUVO_MODEL_CLAUDE_SONNET:-claude-sonnet-5}"
ZUVO_MODEL_CLAUDE_HAIKU="${ZUVO_MODEL_CLAUDE_HAIKU:-claude-haiku-4-5-20251001}"

# ── OpenAI (Codex) ──────────────────────────────────────────────────
# gpt-5.6 family (GA 2026-07-09): Sol=flagship, Terra=mid, Luna=fast. Benchmarked 2026-07-19
# on identical planted-bug review @ medium: sol 18s/5 findings (most complete), terra 15s/4,
# luna 13s/3 — all caught the bug. Requires codex CLI ≥0.144 (0.142 rejects 5.6 ids).
ZUVO_MODEL_CODEX_PRIMARY="${ZUVO_MODEL_CODEX_PRIMARY:-gpt-5.6-sol}"  # codex-5.3 lane (spark)
ZUVO_MODEL_CODEX_ALT="${ZUVO_MODEL_CODEX_ALT:-gpt-5.4}"              # codex-5.4 lane (host-flip)
# The reviewer this file did not name. reviewer-model-route.sh both DEFAULTS the Codex
# writer to gpt-5.5 (`${ZUVO_CODEX_MODEL:-gpt-5.5}`) and routes writer=gpt-5.4 to it as
# the ALTERNATE review lane — so it is dispatched in normal operation, yet appeared nowhere
# in the "single source of model ids". Registered 2026-08-11 after a build<->registry
# assertion caught it: this is the third instance of the same drift in one range (the
# first was gpt-5.6-sol missing from the ROUTER, which made the registry's own primary
# self-review). Registering it does NOT unify the tables — reviewer-model-route.sh and
# build-codex-skills.sh still hardcode their own literals; that is B-MODEL-ID-FANOUT.
# NB: spell the lane as prose, never as the literal token the Codex build greps for — the
# build rewrites those tokens to concrete ids elsewhere and then asserts none survive in
# dist/, and this file is copied WITHOUT that rewrite, so the token here fails the build.
ZUVO_MODEL_CODEX_REVIEW_ALT="${ZUVO_MODEL_CODEX_REVIEW_ALT:-gpt-5.5}" # alternate review lane + default writer

# ── Google (Gemini) ─────────────────────────────────────────────────
# Flash, not Pro — reversed 2026-09-01 on measurement, and the reasoning that put Pro
# here is preserved below because it was CORRECT WHEN WRITTEN and only a newer model
# retired it.
#
# The old pin cited a 2026-08-07 result (8 uncovered defensive paths a same-model audit
# called CLEAN) run on Pro (High), and noted that `agy models` "tops out at 3.1 for the
# Pro tier — 3.5/3.6 exist only as Flash". Both statements were true. 3.7 Flash shipped
# after that measurement, so the comparison it rested on no longer describes the choice.
#
# Measured 2026-09-01, same 20 real review diffs through the same prompt, both lanes:
#   3.7 Flash (High)  20/20 answered, 64s avg, 69 REAL findings, 82% precision
#   3.1 Pro   (High)   7/20 answered, 225s avg (12 timeouts + 1 empty) — and that is
#                      WITH DEFAULT_TIMEOUT already raised to 400s (cb913be)
# A size ladder (one diff cut to 5/12/20/28 kB, 2 reps each) shows why: Pro's wall clock
# scales 4.6x with input size (52s -> 239s) and crosses the timeout at ~20 kB, while Flash
# stays flat at 60-90s. The fleet log agrees — in the 15-30 kB band, 54% of all runs, the
# Pro lane failed to answer 52% of the time.
# An Opus judge also caught Pro reviewing the production file named in a diff HEADER
# instead of the artifacts actually in the diff — a correctness fault, not just latency.
#
# A reviewer that does not answer has precision 0, whatever it scores when it does.
# Display name, exactly as `agy models` prints it: a wrong string fails silently.
#
# 3.8 Flash (High) since 2026-09-05, on measurement: the same 20 review diffs through both,
# every finding judged REAL/FALSE_POSITIVE by an independent Opus judge against the diff,
# with a shared defect vocabulary so neither model scores twice for one defect.
# The decisive number is MARGINAL coverage over the other six providers, not the head-to-head:
#   others alone 215 defects · +3.7 Flash 232 (17 unique) · +3.8 Flash 247 (32 unique)
# 3.8 nearly doubles what this lane contributes that nobody else finds. It is bought with
# three real regressions, all measured, none disqualifying for an ADVERSARIAL reviewer where
# a false positive dies in triage and a missed defect ships:
#   precision 82% -> 73%   (30 false positives vs 15)
#   median 66s -> 172s, p90 273s, max 308s against the 400s PROVIDER_TIMEOUT
#   1/20 empty answer, plus 2/20 returning zero findings — one of them a diff in which the
#   other providers found 37 real defects and 3.7 found 6. 3.8 is streakier, not just slower.
# Running BOTH was measured and rejected: +9 defects over 3.8 alone for two of the five
# provider slots spent on one vendor, and cross-VENDOR spread is where the coverage comes from.
ZUVO_MODEL_AGY="${ZUVO_MODEL_AGY:-Gemini 3.8 Flash (High)}"
# Same value as the default. This is the deepest lane that reliably answers; pointing it at
# 3.1 Pro would reintroduce the 65% non-answer rate exactly where a caller asked for MORE
# depth, which is the worst place to put it.
ZUVO_MODEL_AGY_DEEP="${ZUVO_MODEL_AGY_DEEP:-Gemini 3.8 Flash (High)}"
ZUVO_MODEL_GEMINI_API="${ZUVO_MODEL_GEMINI_API:-gemini-3.1-pro-preview}"  # gemini-api curl fallback (needs GEMINI_API_KEY)

# ── OpenRouter (paid, opt-in) ───────────────────────────────────────
# Two models, chosen by measurement, not by benchmark rank. 20 real review diffs, every
# finding judged REAL / FALSE_POSITIVE / UNVERIFIABLE by an independent Opus judge against
# the diff, with a shared defect-id vocabulary so overlapping findings collapse:
#   z-ai/glm-5.3        85 REAL /  1 FP (99%) — adds 32 defects nothing free covers, 363s, $2.92/20
#   qwen/qwen3.8-flash  80 REAL /  2 FP (98%) — adds 22, 336s, $0.26/20
# Both fit under DEFAULT_TIMEOUT=400.
#
# What the same measurement REJECTED, so nobody re-adds them on price or speed:
#   qwen/qwen3-coder-next  25% precision, 66 false positives — the cheapest ($0.04/20) and
#                          fastest (16s) model in the whole field, and almost pure fabrication.
#                          Zero reasoning tokens; it does not analyse, it pattern-matches.
#   poolside/laguna-s-2.1  35%, 46 FP — same shape, same trap.
#   minimax/minimax-m3     62% under an Opus judge vs 84% under a Sonnet one. Weak-judge
#                          artifact; it reads convincingly and is wrong.
# The lesson those three encode: findings COUNT is a gadfly metric. A model that emits five
# plausible paragraphs per diff outranks a careful one until somebody checks the claims.
ZUVO_MODEL_OPENROUTER="${ZUVO_MODEL_OPENROUTER:-z-ai/glm-5.3}"
ZUVO_MODEL_OPENROUTER_ALT="${ZUVO_MODEL_OPENROUTER_ALT:-qwen/qwen3.8-flash}"

# ── Cursor ──────────────────────────────────────────────────────────
ZUVO_MODEL_CURSOR="${ZUVO_MODEL_CURSOR:-composer-2.5-fast}"          # "Composer 2.5 Fast (current)" from `cursor-agent models`

# ── Moonshot (Kimi) ─────────────────────────────────────────────────
ZUVO_MODEL_KIMI_CLI="${ZUVO_MODEL_KIMI_CLI:-}"                       # kimi CLI -m alias; EMPTY = use the CLI's own default (kimi-code/k3, OAuth) — verified E2E 2026-07-19
ZUVO_MODEL_KIMI="${ZUVO_MODEL_KIMI:-kimi-k2.6}"                      # kimi-api curl fallback (needs MOONSHOT_API_KEY); k2.7-code = coding variant, same price
