#!/bin/bash
# Install zuvo to Claude Code, Codex, and/or Cursor from source.
# Usage:
#   ./scripts/install.sh          # install to all
#   ./scripts/install.sh claude   # Claude Code only
#   ./scripts/install.sh codex    # Codex only
#   ./scripts/install.sh cursor   # Cursor only
#
# What it does:
#   Claude Code: copies source files to plugin cache
#   Codex:       runs build-codex-skills.sh, then copies dist to ~/.codex/
#   Cursor:      runs build-cursor-skills.sh, then copies dist to ~/.cursor/

# NOTE: `set -euo pipefail` is deliberately NOT global — it is enabled inside the
# main run guard at the bottom. This file is source-able (tests source it to call
# install_hook_tree / install_pipeline_artifacts / install_git_shim) and a global
# `set -e` would leak into and abort the sourcing shell.

ZUVO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# Portable primitives (sed_i, zuvo_python) — Windows/Git-Bash is a supported target and
# the BSD-only `sed -i ''` it replaces breaks there. See scripts/lib/portable.sh.
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib/portable.sh"
# The reviewer-lane grammar (the strict rewriter and the lenient validators), shared with the builds —
# see materialize_claude_reviewer_lanes. Found beside this file, like portable.sh above.
#
# Checked, not assumed: the library `return`s 1 when its own model-subprocess.sh does not load, and a
# truncated or empty copy sources "successfully" while defining nothing. Either way the installer used to
# run on and die with a 127 at the first zrl_ call, steps later. Every zrl_ function this file calls is
# named here, so a half-loaded library stops the run by name before anything is installed.
_zi_lanes_lib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib/reviewer-lanes.sh"
# Unset first: in a shell that sourced an earlier copy (a test, a re-source), what THAT copy defined
# would otherwise pass for this one. ALL of it — zrl_require_fns checks the library's whole list (ZRL_FUNCS,
# the internal _zrl_ ones included), not only the six functions this file calls.
# shellcheck disable=SC2046  # function names: one word each, no glob characters
unset -f $(compgen -A function zrl_) $(compgen -A function _zrl_)
# shellcheck source=lib/reviewer-lanes.sh
if ! . "$_zi_lanes_lib" || ! declare -F zrl_require_fns >/dev/null 2>&1 \
   || ! zrl_require_fns "$_zi_lanes_lib" zrl_links_inside zrl_rewrite_lanes_file zrl_scan_md zrl_show_refs \
          zrl_count_refs; then
  echo "install: $_zi_lanes_lib did not load (missing, incomplete, or its model-subprocess.sh failed) — nothing was installed" >&2
  unset _zi_lanes_lib
  return 1 2>/dev/null || exit 1
fi
unset _zi_lanes_lib

# Python writes ✓ and other non-ASCII text. On Windows its default encoding follows the locale
# (cp1250 under Polish settings), and printing U+2713 there dies with UnicodeEncodeError. UTF-8 mode
# for every Python this install starts — the builds too — unless the caller chose otherwise.
export PYTHONUTF8="${PYTHONUTF8:-1}" PYTHONIOENCODING="${PYTHONIOENCODING:-utf-8}"

# ─── Downgrade guard ────────────────────────────────────────────────────────────
# An install from a checkout that is BEHIND the installed state silently reverts every live
# helper in ~/.zuvo — and reports success while doing it. This is not hypothetical: on
# 2026-09-02 a parallel session ran install.sh from a feature branch forked before three
# merged commits, overwrote ~/.zuvo/adversarial-review with the older file, and the fleet kept
# running the previous model and timeout for hours. Nothing detected it; the install printed
# its usual ✓ lines. The only reason it surfaced was somebody asking why nothing had changed.
#
# So: record what was installed, and refuse to go backwards. A source commit that is a strict
# ANCESTOR of the recorded one is a downgrade — that is exactly the shape of "installing from a
# stale branch". Anything else (newer, unrelated, or no git at all) proceeds untouched, because
# this must never block ordinary work.
_zuvo_install_stamp="$HOME/.zuvo/.installed-from"
# --verify -q: in a repo with no commit yet, a bare `rev-parse HEAD` prints the word "HEAD" to stdout
# (and fails) — `|| true` then kept it as the sha.
_zuvo_src_sha="$(git -C "$ZUVO_DIR" rev-parse --verify -q HEAD 2>/dev/null || true)"
if [ -n "$_zuvo_src_sha" ] && [ -f "$_zuvo_install_stamp" ] && [ "${ZUVO_INSTALL_FORCE:-0}" != "1" ]; then
  _zuvo_prev_sha="$(head -1 "$_zuvo_install_stamp" 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$_zuvo_prev_sha" ] && [ "$_zuvo_prev_sha" != "$_zuvo_src_sha" ]; then
    if ! git -C "$ZUVO_DIR" cat-file -e "${_zuvo_prev_sha}^{commit}" 2>/dev/null; then
      # FAIL CLOSED. The first version treated an unresolvable recorded sha as "carry on", so a
      # shallow clone, a separate clone, or a pruned repo disabled the guard exactly where it was
      # needed most — the checkouts least likely to contain the installed work.
      echo "REFUSING: the installed commit ${_zuvo_prev_sha:0:7} is not in this repository." >&2
      echo "  Cannot prove this checkout is not a downgrade. Fetch it, or override:" >&2
      echo "  ZUVO_INSTALL_FORCE=1 $0" >&2
      return 1 2>/dev/null || exit 1   # sourced: return; a bare exit killed the SOURCING shell
    fi
    # Proceed ONLY when the source CONTAINS the installed commit. The first version merely
    # rejected strict ancestors, which let a DIVERGENT branch through — forked before the
    # installed revision but carrying one unrelated commit, so not an ancestor, and still
    # reverting everything unique to what is live. Containment is the property that actually
    # matters: if the source does not have the installed commit in its history, installing it
    # removes work from ~/.zuvo.
    if ! git -C "$ZUVO_DIR" merge-base --is-ancestor "$_zuvo_prev_sha" "$_zuvo_src_sha" 2>/dev/null; then
      echo "REFUSING: this checkout ($(git -C "$ZUVO_DIR" rev-parse --short HEAD), branch $(git -C "$ZUVO_DIR" rev-parse --abbrev-ref HEAD)) does NOT contain the installed commit ($(git -C "$ZUVO_DIR" rev-parse --short "$_zuvo_prev_sha"))." >&2
      echo "  Installing would silently revert live helpers in ~/.zuvo/ and still report success." >&2
      echo "  Fix: merge or rebase onto the installed commit, or install from a checkout that has it." >&2
      echo "  Override (you are certain the older code should go live): ZUVO_INSTALL_FORCE=1 $0" >&2
      return 1 2>/dev/null || exit 1
    fi
  fi
fi


TARGET="${1:-all}"

# _zi_source <module>… — load scripts/install.d/<module>.sh, in the order given. A module that cannot
# be read or loaded stops the install HERE, by name, before anything is installed: sourcing a missing
# file only prints a warning and carries on, and the first symptom would be a "command not found"
# partway through some host's install, after the hosts before it were already done. (install_claude
# ships install.d/ into every Claude cache dir beside the install.sh it copies there, so that copy
# loads too.) tests/lib/installer-sources.sh reads the module list from the `_zi_source` calls below,
# so keep each call on one line.
_zi_source() {
  local _zi_m _zi_f
  for _zi_m in "$@"; do
    _zi_f="$ZUVO_DIR/scripts/install.d/$_zi_m.sh"
    if [ ! -f "$_zi_f" ] || [ ! -r "$_zi_f" ]; then
      echo "REFUSING: cannot read $_zi_f — run install.sh from a complete zuvo checkout." >&2
      return 1
    fi
    . "$_zi_f" || { echo "REFUSING: $_zi_f failed to load." >&2; return 1; }
  done
}

# Colors, ok/warn/fail, the copy-verification counters, dist_root and cp_warn.
_zi_source output || { return 1 2>/dev/null || exit 1; }


# --- refuse to carry test debris out of the repo (B-REFGUARD) -----------------------------------
# `tests/skill-suite/test-references-guards.sh` used to create its fixture inside the real skills/
# tree. install.sh copies skills/* into FIVE destinations, so an install that overlapped a running
# guard test — or followed a killed one — carried the fixture out and left it there permanently:
# `tmp-refguard-56836-test` and `tmp-refguard-82399-test` were found in the Claude Code plugin
# cache under both zuvo/1.6.52/skills/ and zuvo/1.6.53/skills/, inflating the installed skill count
# to 59 against 57 in source.
#
# That test is sandboxed now, so the source is gone. This is the backstop, and it is deliberately
# ONE check before any build rather than a filter in each of the five copy loops — a guard repeated
# five times is five places for the sixth copy path to be forgotten. No real skill is named `tmp-*`,
# so it cannot false-positive; failing loudly beats installing debris quietly.
# `return 1 2>/dev/null || exit 1`: return when SOURCED, exit when RUN. This block sits above the
# main-run guard (it must, so no build path can start before it), and a bare `exit 1` therefore killed
# the SOURCING shell —
# verified: `source scripts/install.sh` with debris present terminated the caller, and
# tests/hooks/test-install-copy-verification.sh is itself a sourcing caller, so the guard would
# have taken down the very suite that checks it. The file's own header promises it is source-able.
if compgen -G "$ZUVO_DIR/skills/tmp-*" >/dev/null 2>&1; then
  fail "refusing to install: test debris in skills/"
  for _d in "$ZUVO_DIR"/skills/tmp-*; do echo "      $_d"; done
  echo "  A test fixture is sitting in the source tree. Installing would copy it into every"
  echo "  target and leave it there. Remove it, then re-run:"
  echo "      rm -rf $ZUVO_DIR/skills/tmp-*"
  return 1 2>/dev/null || exit 1
fi

# verify_copied, install_file_atomic, install_runner_lib and the lib name-collision guards.
_zi_source copy || { return 1 2>/dev/null || exit 1; }

# The installer itself, one module per target: hooks (pipeline-entry hook helpers every target
# reuses), claude (plugin cache), zuvo-home (~/.zuvo helpers), claude-home (~/.claude: git dispatchers,
# settings.json hooks, the retired review queue's cleanup), then one per host. These hold function
# definitions only — sourcing them runs nothing — so their order is free. The two above are not: output.sh
# comes before the debris guard, which reports through it; copy.sh after it, where its functions were always
# defined.
_zi_source hooks claude zuvo-home claude-home codex cursor antigravity kimi || { return 1 2>/dev/null || exit 1; }


# =======================================
# MAIN
# =======================================
# VERSION is computed unconditionally (functions reference it; harmless when sourced).
VERSION=$(grep '"version"' "$ZUVO_DIR/package.json" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')

# _zi_record_install_stamp <clean|modified> — record what was installed, for the downgrade guard at the
# top of the next run. Called only after the INSTALL INCOMPLETE exit — a stamp from a half-finished
# install would let the next one refuse for the wrong reason (it used to be written before that check)
# — and before DONE, so a failed install prints neither. Only from a git checkout: the guard compares
# COMMITS, and from a tree without history (a tarball, the plugin cache) the stamp's first line used to
# be the date, which the next install from git then read as an unknown commit and refused on. "A git
# checkout" means ZUVO_DIR is the top of its own work tree: `rev-parse` alone walks up, and a copy
# unpacked inside some other repository would record THAT repository's commit. Written whole or not at
# all: a plain `> file` truncates first, and an empty stamp left by a failed write disarms the guard
# silently. A stamp that cannot be written is said out loud.
# Lines: the commit, the branch, the time, and `worktree: clean|modified` — line 1 names a commit, but
# what was copied is the work tree, and a modified checkout installs something no commit holds.
_zi_record_install_stamp() {
  local sha="" body tmp err
  if [ "$(git -C "$ZUVO_DIR" rev-parse --show-toplevel 2>/dev/null || true)" = "$(cd "$ZUVO_DIR" && pwd -P)" ]; then
    sha="$(git -C "$ZUVO_DIR" rev-parse --verify -q HEAD 2>/dev/null || true)"   # --verify: see _zuvo_src_sha
  fi
  [ -n "$sha" ] || return 0
  # The whole body first, then ONE write whose status is checked: a `{ …; } > file` group reports
  # only its last command's status, and a stamp missing its commit line must never be installed.
  body="$(printf '%s\n%s\n%s\nworktree: %s' "$sha" \
    "$(git -C "$ZUVO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1")"
  tmp="$(mktemp "$HOME/.zuvo/.installed-from.new.XXXXXX" 2>/dev/null || true)"
  err="could not create a temp file in ~/.zuvo"
  if [ -n "$tmp" ]; then
    err="could not write the temp file $tmp"
    if printf '%s\n' "$body" > "$tmp" 2>/dev/null; then
      err="$(install_file_atomic "$tmp" "$HOME/.zuvo/.installed-from")" && err=""
    fi
    rm -f "$tmp"
  fi
  [ -z "$err" ] \
    || warn "could not write ~/.zuvo/.installed-from ($err) — the next install's downgrade guard will have nothing to compare against"
}

# Only RUN the installer when executed directly — not when sourced (tests source
# this file to call install_hook_tree / install_pipeline_artifacts / install_git_shim).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
set -euo pipefail

echo "Installing zuvo v${VERSION} from $ZUVO_DIR"
# The work tree as the install STARTS is what gets copied: line 4 of the stamp (_zi_record_install_stamp).
_zuvo_src_worktree=clean
[ -z "$(git --no-optional-locks -C "$ZUVO_DIR" status --porcelain 2>/dev/null | head -1 || true)" ] || _zuvo_src_worktree=modified

echo "Validating banned-vocabulary contracts..."
"$ZUVO_DIR/scripts/validate-banned-vocabulary.sh"
echo "Validating banned-vocabulary fixtures..."
"$ZUVO_DIR/scripts/validate-banned-vocabulary-fixtures.sh"

case "$TARGET" in
  # install_zuvo_home on EVERY branch, not just both|all (B-9, open since v1.3.109).
  # ~/.zuvo/ holds append-runlog, append-retro, adversarial-review, compute-preload,
  # build-review-patch and review-artifact-sync.sh — helpers that EVERY skill calls by absolute
  # path, on every platform. A platform-only invocation used to install a full skill set that
  # then failed at its first mandatory gate with "command not found", and the failure surfaces
  # inside a skill run rather than at install time, which is where the four days of confusion
  # came from. The function is standalone (no DIST/SKILL_COUNT/CACHE_DIR from a sibling
  # installer) and idempotent, so calling it per-branch is a no-op when it already ran.
  claude) install_claude; install_zuvo_home; install_claude_home ;;
  codex)  install_codex; install_zuvo_home ;;
  cursor) install_cursor; install_zuvo_home ;;
  antigravity) install_antigravity; install_zuvo_home ;;
  kimi)   install_kimi; install_zuvo_home ;;
  both|all) install_claude; install_codex; install_cursor; install_antigravity; install_kimi; install_zuvo_home; install_claude_home ;;
  *)      echo "Usage: $0 [claude|codex|cursor|antigravity|kimi|all]"; exit 1 ;;
esac

# Opt-in git PATH-shim (ZUVO_INSTALL_GIT_SHIM / ZUVO_UNINSTALL_GIT_SHIM); no-op otherwise.
install_git_shim

# =======================================
# POST-INSTALL: Cross-provider check
# =======================================
# Adversarial review needs a DIFFERENT provider than the host IDE.
# Warn if no cross-providers are available.

check_cross_providers() {
  # Mirror adversarial-review.sh detect_providers (the source of truth): the real
  # auto-detected set is codex → agy → cursor-agent → kimi → claude. The free
  # `gemini` CLI is DEAD for individuals (agy is the live Google channel), and
  # kimi (Moonshot, OAuth CLI) was added in v1.6.18 — an install check that still
  # probes `gemini` and omits `kimi` is exactly the stale list that misleads.
  local has_codex="" has_agy="" has_gemini="" has_cursor="" has_kimi="" has_claude=""
  command -v codex &>/dev/null && has_codex=1
  [[ -x "/Applications/Codex.app/Contents/Resources/codex" ]] && has_codex=1
  command -v agy &>/dev/null && has_agy=1
  command -v gemini &>/dev/null && has_gemini=1   # legacy/dead CLI — only counts if agy absent
  command -v cursor-agent &>/dev/null && has_cursor=1
  { command -v kimi &>/dev/null || [[ -n "${MOONSHOT_API_KEY:-}" ]]; } && has_kimi=1
  command -v claude &>/dev/null && has_claude=1

  # Google is ONE vendor: count agy OR gemini once (agy preferred).
  local has_google=""
  [[ -n "$has_agy" || -n "$has_gemini" ]] && has_google=1

  local count=0
  [[ -n "$has_codex" ]] && count=$((count + 1))
  [[ -n "$has_google" ]] && count=$((count + 1))
  [[ -n "$has_cursor" ]] && count=$((count + 1))
  [[ -n "$has_kimi" ]] && count=$((count + 1))
  [[ -n "$has_claude" ]] && count=$((count + 1))

  print_providers() {
    [[ -n "$has_codex" ]] && echo "    ✓ codex (OpenAI)"
    [[ -n "$has_agy" ]] && echo "    ✓ agy (Google/Antigravity)" || { [[ -n "$has_gemini" ]] && echo "    ✓ gemini (Google — legacy CLI, dead for individuals; prefer agy)"; }
    [[ -n "$has_cursor" ]] && echo "    ✓ cursor-agent (Cursor)"
    [[ -n "$has_kimi" ]] && echo "    ✓ kimi (Moonshot — OAuth CLI, no API key needed)"
    [[ -n "$has_claude" ]] && echo "    ✓ claude (Anthropic)"
    # Explicit: the last `[[ … ]] && echo` returns 1 when claude is absent, and this runs under the
    # main run's `set -euo pipefail` as a plain statement — without this line a codex/agy-only host
    # aborted here, BEFORE the copy-verification summary, the install stamp and DONE.
    return 0
  }

  if [[ $count -eq 0 ]]; then
    echo "  ⚠ WARNING: No adversarial review providers found!"
    echo ""
    echo "  Zuvo uses cross-model review — a DIFFERENT AI reviews code"
    echo "  written by your primary AI. Install at least one (different vendor from your host):"
    echo ""
    echo "    npm install -g @openai/codex              # Codex CLI (OpenAI)"
    echo "    curl -fsSL https://antigravity.google/cli/install.sh | bash   # agy (Google/Gemini)"
    echo "    # kimi (Moonshot) — install the kimi CLI, then: kimi login"
    echo "    # claude CLI — already included with Claude Code"
    echo ""
    echo "  Without a cross-provider, adversarial review will be skipped."
    echo "  Verify what actually works: adversarial-review --doctor"
    echo ""
  elif [[ $count -eq 1 ]]; then
    echo "  Cross-provider check: 1 vendor found."
    echo "  Adversarial review needs a provider DIFFERENT from your host IDE."
    print_providers
    echo ""
    echo "  For full coverage, install one more provider from a different vendor."
    echo "  Verify: adversarial-review --doctor"
    echo ""
  else
    echo "  Cross-provider check: $count vendors found ✓"
    print_providers
    echo ""
  fi
}

check_cross_providers

# --- copy-verification summary (B-install-sh-copy-verification) ---------------------------------
# Runs LAST so the whole install still happens — a failed copy in one host must not stop the other
# four. But the exit code changes, because "install.sh printed ✓ and exited 0" is precisely how a
# missing helper stays invisible until a skill fails hours later in another repo.
if [ "${INSTALL_COPY_WARNINGS:-0}" -gt 0 ]; then
  echo ""
  warn "$INSTALL_COPY_WARNINGS copy operation(s) failed during this install (WARN lines above)."
  echo "  Non-fatal by design — a failure in one cache dir must not abort the others — but the"
  echo "  install is incomplete in those respects. This used to be entirely silent, which is how"
  echo "  the Claude plugin manifest went stale for ~40 releases with nothing reporting it."
fi

if [ "${INSTALL_VERIFY_MISSING:-0}" -gt 0 ]; then
  echo ""
  fail "INSTALL INCOMPLETE — $INSTALL_VERIFY_MISSING file(s) present in the repo did not reach their destination:"
  echo "$INSTALL_VERIFY_DETAIL"
  echo ""
  echo "  These are named scripts the skills resolve at runtime; a skill will fail with a missing"
  echo "  helper rather than degrade. Usual causes: destination not writable, disk full, or a stale"
  echo "  root-owned file at the destination. Fix the cause and re-run — do not ignore this."
  echo ""
  exit 1
fi

_zi_record_install_stamp "$_zuvo_src_worktree"
echo ""
echo "======================================"
echo "  DONE"
echo "======================================"
echo ""
echo "  Restart Claude Code / Codex / Cursor / Antigravity / Kimi Code to pick up changes."
echo ""

# --- shell-level sleep guard -------------------------------------------------------------
# Inside the main-run guard, and after the INSTALL INCOMPLETE exit, which is exactly when it ran
# before — except that it used to sit below the guard and so also ran when install.sh was merely
# SOURCED (tests source it), copying into ~/.zuvo and appending to ~/.zshenv.
# Enforcement that does not depend on a Codex hook running — and no Codex hook has ever been
# observed to run here (docs/runbook/operating.md §11). Codex shells out through `/bin/zsh -lc`,
# and a zsh ALWAYS reads ~/.zshenv, so the rule can live in the shell instead.
#
# ~/.zshenv is read by every zsh on this machine, so the block written into it is a guarded
# one-liner: if the guard file is ever deleted, nothing breaks and no shell errors.
# Every step says what happened. The copy used to end in `2>/dev/null || true`, so a file that could not
# be refreshed — and, with no zsh to parse it, one that was not even a file — still got ~/.zshenv wired
# to it under a "wired" line; and a ~/.zshenv that could not be appended to failed under this run's
# `set -e`, ending the install after its DONE banner with a non-zero status.
if [ -d "$HOME/.zuvo" ] || mkdir -p "$HOME/.zuvo" 2>/dev/null; then
  _zsg="$HOME/.zuvo/zuvo-sleep-guard.zsh"
  _zsg_state="file refreshed"
  if ! _zsg_err="$(install_file_atomic "$ZUVO_DIR/hooks/zuvo-sleep-guard.zsh" "$_zsg")"; then
    warn "sleep guard NOT refreshed: $_zsg ($_zsg_err)"
    _zsg_state="the older copy kept"
  fi
  ZSHENV="$HOME/.zshenv"
  if [ ! -f "$_zsg" ]; then
    warn "sleep guard NOT wired: $_zsg is not a file"
  elif command -v zsh >/dev/null 2>&1 && ! zsh -n "$_zsg" 2>/dev/null; then
    warn "sleep guard NOT wired: $_zsg does not parse"
  elif [ -e "$ZSHENV" ] && [ ! -f "$ZSHENV" ]; then
    warn "sleep guard NOT wired: $ZSHENV exists and is not a regular file"
  elif grep -q 'zuvo sleep guard' "$ZSHENV" 2>/dev/null; then
    ok "sleep guard already wired in ~/.zshenv ($_zsg_state)"
  else
    if [ -f "$ZSHENV" ] && ! cp -f "$ZSHENV" "$ZSHENV.zuvo-bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null; then
      warn "could not back up ~/.zshenv before appending the sleep guard to it"
    fi
    if {
      printf '\n# >>> zuvo sleep guard >>>\n'
      printf '[ -f "$HOME/.zuvo/zuvo-sleep-guard.zsh" ] && source "$HOME/.zuvo/zuvo-sleep-guard.zsh"\n'
      printf '# <<< zuvo sleep guard <<<\n'
    } >> "$ZSHENV" 2>/dev/null; then
      ok "sleep guard wired into ~/.zshenv (inert unless the parent process is codex; off: touch ~/.zuvo/no-sleep-guard)"
    else
      warn "sleep guard NOT wired: could not append to $ZSHENV"
    fi
  fi
fi

fi  # end main run guard (skipped when sourced)
