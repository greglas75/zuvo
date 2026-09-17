#!/usr/bin/env bash
#
# test-retro-no-count-cap.sh — no file in this repo may carry a count-based cap on
# ~/.zuvo/retros.log or retros.md.
#
# Why this exists. `append-retro` stopped truncating retros.log to the last 100 rows
# long ago, and `shared/includes/retrospective.md` says "Do not reintroduce a count
# cap". Neither helped: the RECIPE survived in
# docs/specs/2026-04-09-retrospective-feedback-loop-spec.md as a runnable bash block
# ("100 entries max, oldest pruned on write" + head -1 / tail -n 100 / mv), and that
# spec ships inside the plugin cache on all five platforms. Between 2026-08-17 and
# 2026-09-17 retros.log was cut to ~101 rows six times (422->101, 464->101, 519->101,
# 1525->101, 2678->101, 3789->101, 3929->99), twice taking retros.md with it; 323 rows
# were lost for good on 2026-08-17 before the snapshot interval was tightened to 1h.
#
# Retention is age-based archival via `rotate-retros` — entries MOVE into
# retros-archive-YYYY-QN.*, they are never destroyed. A count cap is always a bug here:
# at 36 retros/day a 100-row cap holds ~2.8 days while retro-mine.py asks for --days 7,
# so the miner cannot see its own window.
#
# Prose ABOUT the removed cap is allowed (this file, and the explanatory comments in
# append-retro / retrospective.md / the spec, are all history that must stay readable).
# What is banned is a line an agent can copy and run: a tail/head/awk truncation whose
# target is a retro file.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILS=$((FAILS + 1)); }

# Files to scan: everything tracked, minus this test itself. Untracked scratch files
# are irrelevant — only what ships can be copied by an agent.
FILES="$(git ls-files 2>/dev/null | grep -v '^tests/hooks/test-retro-no-count-cap\.sh$')"
if [ -z "$FILES" ]; then
  printf 'SKIP: not a git checkout (nothing to scan)\n'
  exit 0
fi

# ── 1. no runnable truncation whose target is a retro file ───────────────────
# A hit needs BOTH halves on one line: a window operator (tail/head/awk) reading a retro
# file, AND a write-back to that retro file (`> "$RETRO_LOG.tmp"`, `mv ... retros.log`).
# Requiring the write-back is what separates the cap recipe from legitimate reads —
# `head -1 "$RETRO_LOG" | grep '^#'` in append-retro's recovery path preserves the
# header and destroys nothing, and flagging it would have made this guard noise.
#
# EXCLUDED files: the two shrink-guard suites truncate a FIXTURE retros.log on purpose —
# simulating the incident is how they prove the guard fires. Excluding them by name (not
# by pattern) keeps that narrow: a cap appearing in any other test still fails here.
SIMULATORS='^tests/hooks/test-retro-shrink-(guard|forensics)\.sh$'

HITS="$(printf '%s\n' "$FILES" | grep -vE "$SIMULATORS" | while IFS= read -r f; do
  [ -f "$f" ] || continue
  grep -nE '(tail -n [0-9]+|head -n? ?[0-9]+|awk [^|]*(c>=|NR>))[^|]*(RETRO_LOG|RETRO_MD|retros\.log|retros\.md)' "$f" 2>/dev/null \
    | grep -E '(>>?[[:space:]]*"?\$?[^[:space:]]*(RETRO_LOG|RETRO_MD|retros\.(log|md))|mv [^|]*(RETRO_LOG|RETRO_MD|retros\.(log|md)))' \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | sed "s|^|$f:|"
done)"

if [ -n "$HITS" ]; then
  fail "runnable count-cap truncation of a retro file found:"
  printf '%s\n' "$HITS" >&2
  printf '  Retention is age-based: ~/.zuvo/rotate-retros --apply --target <file>\n' >&2
else
  pass "no runnable count-cap truncation targets retros.log / retros.md"
fi

# ── 2. no spec/doc still DECLARES a cap as the retention policy ──────────────
# The quoted phrases are what the spec table said. They are allowed only inside an
# explicit SUPERSEDED note, which this check approximates by ignoring blockquote lines.
DECL="$(printf '%s\n' "$FILES" | while IFS= read -r f; do
  [ -f "$f" ] || continue
  grep -nE '[0-9]+ entries max|oldest pruned on write' "$f" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*(>|#)' \
    | sed "s|^|$f:|"
done)"

if [ -n "$DECL" ]; then
  fail "a doc still declares a count cap as retro retention policy:"
  printf '%s\n' "$DECL" >&2
else
  pass "no doc declares 'N entries max / oldest pruned on write' for retros"
fi

# ── 3. the shipped append path stays append-only ─────────────────────────────
AR="scripts/zuvo-home/append-retro"
if [ ! -f "$AR" ]; then
  fail "$AR is missing (the append path is the thing under test)"
elif grep -nE '^[^#]*(tail -n [0-9]+|head -n? ?[0-9]+)[^|]*\$RETRO_LOG[^|]*(>>?[[:space:]]*"?\$RETRO_LOG|mv [^|]*\$RETRO_LOG)' "$AR" >/dev/null 2>&1; then
  fail "$AR truncates \$RETRO_LOG on write — it must be append-only"
else
  pass "append-retro writes append-only (no truncation of \$RETRO_LOG)"
fi

if [ "$FAILS" -gt 0 ]; then
  printf '\n%s: %d check(s) failed\n' "$(basename "$0")" "$FAILS" >&2
  exit 1
fi
printf '\n%s: all checks passed\n' "$(basename "$0")"
exit 0
