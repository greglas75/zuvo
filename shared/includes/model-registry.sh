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
ZUVO_MODEL_CLAUDE_OPUS="${ZUVO_MODEL_CLAUDE_OPUS:-claude-opus-4-8}"
ZUVO_MODEL_CLAUDE_SONNET="${ZUVO_MODEL_CLAUDE_SONNET:-claude-sonnet-5}"
ZUVO_MODEL_CLAUDE_HAIKU="${ZUVO_MODEL_CLAUDE_HAIKU:-claude-haiku-4-5-20251001}"

# ── OpenAI (Codex) ──────────────────────────────────────────────────
ZUVO_MODEL_CODEX_PRIMARY="${ZUVO_MODEL_CODEX_PRIMARY:-gpt-5.5}"   # codex-5.3 lane (spark)
ZUVO_MODEL_CODEX_ALT="${ZUVO_MODEL_CODEX_ALT:-gpt-5.4}"           # codex-5.4 lane (host-flip)

# ── Google (Gemini) ─────────────────────────────────────────────────
ZUVO_MODEL_AGY="${ZUVO_MODEL_AGY:-Gemini 3.5 Flash (High)}"          # agy default (fast, display name from `agy models`)
ZUVO_MODEL_AGY_DEEP="${ZUVO_MODEL_AGY_DEEP:-Gemini 3.1 Pro (High)}"  # agy max-depth alternative
ZUVO_MODEL_GEMINI_API="${ZUVO_MODEL_GEMINI_API:-gemini-3.1-pro-preview}"  # gemini-api curl fallback (needs GEMINI_API_KEY)

# ── Cursor ──────────────────────────────────────────────────────────
ZUVO_MODEL_CURSOR="${ZUVO_MODEL_CURSOR:-composer-2.5-fast}"          # "Composer 2.5 Fast (current)" from `cursor-agent models`
