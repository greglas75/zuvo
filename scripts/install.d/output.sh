#!/usr/bin/env bash
# scripts/install.d/output.sh — part of scripts/install.sh, which sources it; not runnable alone.
# Colors, the ok/warn/fail reporters, the copy-verification counters, dist_root and cp_warn —
# sourced first, because every other module reports through these.

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }

# --- copy verification (B-install-sh-copy-verification) -----------------------------------------
# Every named-script copy in this installer is `cp … 2>/dev/null || true`. The `|| true` is
# deliberate — a partial install must not abort the rest — but paired with an unconditional
# `ok "Scripts installed"` it means a copy that FAILED is reported as a success, and the first
# symptom is a skill failing at runtime with a missing helper. (This is the same class as the
# stale-installPath and plugin-disabled gotchas in CLAUDE.md: the install said ✓ and the thing was
# not there.)
#
# So the `|| true` stays and the CLAIM gets checked instead. The rule is deliberately narrow:
# assert the destination only when the SOURCE exists. A file absent from the repo was never
# supposed to be copied, so it cannot produce a false alarm; a file present in the repo and absent
# at the destination is a real copy failure and nothing else.
# Set here, read by install.d/copy.sh (verify_copied and friends) and by install.sh's summary.
# shellcheck disable=SC2034
INSTALL_VERIFY_MISSING=0
# shellcheck disable=SC2034
INSTALL_VERIFY_DETAIL=""

# cp_warn <label> <cp-args…> — copy, and SAY SO when it fails (B-INSTALL-COPY-IDIOM).
#
# install_claude()'s cache loop repeated `cp … 2>/dev/null || true` eight times. The duplication is
# the small half. The swallow is the big half: it is the mechanism that let the Claude plugin
# manifest go stale for ~40 releases with no signal — install.sh printed OK whether or not any
# given copy happened. One of the eight was fixed to WARN when that was found; the other seven kept
# the convention, which is a fix to an instance of a shape that keeps producing the same bug.
#
# The `|| true` semantics are PRESERVED on purpose — a failed copy must not abort the remaining
# cache dirs or the other four hosts. What changes is that it stops being invisible.
#
# A glob that matched nothing is NOT a failure: `cp src/*.py dst/` with no .py files passes the
# literal pattern to cp, which fails. Same rule as verify_copied — assert only what was actually
# attempted, because a check that cries wolf is one that gets ignored.
# The counter only accumulates when cp_warn runs in the CURRENT shell. `x=$(cp_warn …)` puts it in
# a subshell and the increment dies there — the WARN still prints, but the final summary reports 0.
# Keep every call site a plain statement.
# dist_root — ONE place that answers "where did the build write?" (review R-4).
#
# The four build scripts were changed to `DIST="${ZUVO_DIST_ROOT:-$PLUGIN_DIR/dist}/<platform>"` so a
# test run can get its own tree. install.sh, which INVOKES them, kept computing
# `DIST="$ZUVO_DIR/dist/<platform>"` in four separate places and ignored the override — so with the
# variable set the builder writes one path and the installer checks another, and
# `if [[ ! -d "$DIST/skills" ]]; then fail "Build failed"` fires on a build that succeeded (or
# worse, finds a stale tree from an earlier default-path build and installs it). Reproduced.
#
# Latent while the variable is unset, which is exactly how it would have survived: the fix landed in
# the source and not in every place that recomputes the same answer.
dist_root() { printf '%s' "${ZUVO_DIST_ROOT:-$ZUVO_DIR/dist}"; }

INSTALL_COPY_WARNINGS=0
cp_warn() {
  local _label="$1"; shift
  [ "$#" -ge 2 ] || return 0
  # First non-flag argument is the source; if it does not exist the glob did not match.
  local _first=""
  local _a
  for _a in "$@"; do
    case "$_a" in -*) continue ;; esac
    _first="$_a"; break
  done
  [ -n "$_first" ] && [ ! -e "$_first" ] && return 0
  if cp "$@" 2>/dev/null; then
    return 0
  fi
  INSTALL_COPY_WARNINGS=$((INSTALL_COPY_WARNINGS + 1))
  echo "  WARN: $_label — copy FAILED; this install is incomplete in that respect" >&2
  return 0
}
