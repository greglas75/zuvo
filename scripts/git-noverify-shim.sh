#!/usr/bin/env bash
# git-noverify-shim — opt-in PATH wrapper for `git`.
#
# Install it as ~/bin/git (earlier on PATH than the real git) to block
# hook-skipping git invocations UNIVERSALLY — at the git level, so it catches
# every harness AND any shell, not just tool-call hooks.
#
#   - AGENT invocations of commit --no-verify / commit -n (or short bundle -nm),
#     and --no-verify on push/merge/cherry-pick/rebase/am → BLOCKED (exit 1).
#   - HUMAN invocations (no agent env var) → transparent PASS-THROUGH (G8): a
#     human can always --no-verify. Dry-runs (push -n / add -n) always pass.
#
# Escapes: run /usr/bin/git directly, or set ZUVO_UNINSTALL_GIT_SHIM=1 to remove
# the shim (rm ~/bin/git). Install/uninstall wiring lives in scripts/install.sh.
#
# FAIL-OPEN: if the real git can't be found, print a clear error (never silently
# swallow a git command).

set -uo pipefail

# --- uninstall path ---------------------------------------------------------
if [ "${ZUVO_UNINSTALL_GIT_SHIM:-0}" = "1" ]; then
  target="${ZUVO_SHIM_PATH:-$HOME/bin/git}"
  if [ -e "$target" ]; then
    rm -f "$target" && echo "zuvo: removed git shim at $target"
  else
    echo "zuvo: no git shim at $target (nothing to remove)"
  fi
  exit 0
fi

# --- locate the real git (skip self + any other copy of this shim) ----------
# Pure-bash path resolution (no dirname/basename) so the shim works even in a
# minimal env where coreutils are not on PATH.
_self_dir="${0%/*}"; [ "$_self_dir" = "$0" ] && _self_dir="."
SELF="$(cd "$_self_dir" 2>/dev/null && pwd)/${0##*/}"
REAL_GIT=""
_OLDIFS="${IFS:-}"
IFS=:
for d in $PATH; do
  [ -n "$d" ] || continue
  cand="$d/git"
  [ -x "$cand" ] || continue
  _cand_dir="${cand%/*}"
  rc="$(cd "$_cand_dir" 2>/dev/null && pwd)/${cand##*/}"
  [ "$rc" = "$SELF" ] && continue
  grep -q 'git-noverify-shim' "$cand" 2>/dev/null && continue   # another shim copy
  REAL_GIT="$cand"; break
done
IFS="$_OLDIFS"

if [ -z "$REAL_GIT" ]; then
  echo "zuvo git-shim: real 'git' not found on PATH (after skipping the shim)." >&2
  echo "  Fix your PATH, or remove the shim: ZUVO_UNINSTALL_GIT_SHIM=1 git" >&2
  exit 127
fi

# --- agent detection --------------------------------------------------------
is_agent() {
  [ "${ZUVO_AGENT:-0}" = "1" ] && return 0
  local v
  for v in CLAUDECODE CLAUDE_PLUGIN_ROOT CLAUDE_CODE_ENTRYPOINT CODEX_WORKSPACE \
           CODEX_SANDBOX CURSOR_AGENT CURSOR_TRACE_ID GEMINI_CLI ANTIGRAVITY; do
    [ -n "${!v:-}" ] && return 0
  done
  return 1
}

# Short cluster contains -n as a flag (before any arg-taking short option)?
short_has_n() {
  local cluster="${1#-}" j c
  for (( j=0; j<${#cluster}; j++ )); do
    c="${cluster:$j:1}"
    case "$c" in
      n) return 0 ;;
      m|c|C|F|u|S|t|G|O) return 1 ;;
    esac
  done
  return 1
}

is_hookspath_kv() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    core.hookspath|core.hookspath=*|*core.hookspath=*) return 0 ;;
  esac
  return 1
}

# core.hooksPath injected via GIT_CONFIG_* environment (GIT_CONFIG_KEY_N=core.hooksPath)?
env_hookspath() {
  env | grep -iqE '^GIT_CONFIG_KEY_[0-9]+=core\.hookspath$'
}

# --- ALIAS USAGE (B-noverify-hardening #1) ------------------------------------
# The shim sees real argv, so quoting and metacharacters cannot hide a flag from
# it — but an ALIAS hides the flag from argv entirely. With
# `git config alias.yolo "commit --no-verify"` already in ~/.gitconfig, argv is
# literally `git yolo -m x`: there is no `--no-verify` anywhere to find, and the
# subcommand is not in the gated set. Measured before this fix: passed through.
#
# Resolution asks the REAL git, so precedence (repo > global > system) and config
# includes are git's problem, not a parser's. Recursion is guarded twice: a depth
# limit and a seen-set, because aliases chain legitimately and can be defined
# circularly — and a hang in the shim would wedge every git call on the machine,
# which is worse than the bypass it is closing.
#
# `!shell` aliases are not git argv and are scanned as TEXT. Weaker on purpose:
# the CI gate is the server-side guarantee (see docs/pipeline.md).
_ZSHIM_ALIAS_SEEN=""
alias_is_bad() {
  local name="${1:-}" depth="${2:-0}" exp first
  [ -n "$name" ] || return 1
  # Depth exceeded means UNRESOLVED, and unresolved must not read as safe: at depth 5 this used to
  # return "not bad" WITHOUT expanding, so a six-hop alias chain ending in `push --no-verify`
  # bypassed the shim entirely. Fail-open in a bypass defense; now it blocks.
  if [ "$depth" -ge 5 ]; then
    return 0
  fi
  case "$name" in -*) return 1 ;; esac
  case " $_ZSHIM_ALIAS_SEEN " in *" $name "*) return 1 ;; esac
  _ZSHIM_ALIAS_SEEN="$_ZSHIM_ALIAS_SEEN $name"

  # git refuses to let an alias shadow a builtin, so a builtin name can never be
  # one. Skipping them keeps `git status` from paying for a config read on every
  # invocation — a latency guard, not a security decision.
  case "$name" in
    add|status|log|diff|show|fetch|pull|checkout|switch|restore|branch|tag|stash|\
    rev-parse|ls-files|for-each-ref|cat-file|describe|blame|worktree|remote|clone|init|\
    reset|revert|clean|apply|bisect|grep|mv|rm|shortlog|reflog|gc|fsck|notes|submodule) return 1 ;;
  esac

  exp="$("$REAL_GIT" config --get "alias.$name" 2>/dev/null)" || return 1
  [ -n "$exp" ] || return 1

  case "$exp" in
    '!'*)
      # Padded so a flag at either end of the string still has a delimiter on both sides.
      _zgns_low=" $(printf '%s' "$exp" | tr '[:upper:]' '[:lower:]') "
      case "$_zgns_low" in
        *--no-verify*|*core.hookspath*) return 0 ;;
      esac
      # Same gap, same fix as hooks/block-no-verify.sh: git accepts any unambiguous abbreviation,
      # so `!git commit --no-verif` skipped every hook through this layer while line 179's direct
      # scan already knew the full set. The two implementations are deliberately independent
      # (string vs argv) — which is exactly why a pattern fixed in one must be fixed in both, and
      # why tests/hooks/test-noverify-alias.sh runs every case against BOTH.
      # The delimiter class prevents over-blocking `--no-verbose`.
      case "$_zgns_low" in
        *--no-v[\ \;\&\|\'\"\`]*|*--no-ve[\ \;\&\|\'\"\`]*|*--no-ver[\ \;\&\|\'\"\`]*|\
        *--no-veri[\ \;\&\|\'\"\`]*|*--no-verif[\ \;\&\|\'\"\`]*) return 0 ;;
      esac
      return 1 ;;
  esac

  # Re-evaluate the expansion as if it had been typed. Word-splitting is correct
  # here: a git-argv alias is exactly a whitespace-separated argument list.
  local etoks
  # shellcheck disable=SC2206
  etoks=($exp)
  if [ "${#etoks[@]}" -gt 0 ]; then
    violates_args "${etoks[@]}" && return 0
  fi
  first="${exp%% *}"
  [ "$first" = "$name" ] && return 1
  alias_is_bad "$first" $((depth + 1))
}

# --- does this git invocation skip hooks? -----------------------------------
# (args come from the real shell argv, so they are already quote-resolved — no
#  metacharacter-split bypass here; only the -c hooksPath and short-cluster
#  cases need the same hardening as block-no-verify.sh.)
violates_args() {
  local args=("$@") n=$# i=0 t sub has_nv=0 has_cn=0 hookspath=0 config_hookspath=0
  [ "$n" -ge 1 ] || return 1
  env_hookspath && hookspath=1                      # GIT_CONFIG_* env injection
  while [ "$i" -lt "$n" ]; do
    t="${args[$i]}"
    case "$t" in
      -c|--config-env) is_hookspath_kv "${args[$((i+1))]:-}" && hookspath=1; i=$((i+2)); continue ;;
      -c*) is_hookspath_kv "${t#-c}" && hookspath=1; i=$((i+1)); continue ;;   # attached -ccore.hooksPath=
      -C|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix) i=$((i+2)); continue ;;
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*) i=$((i+1)); continue ;;
      -p|-P|--paginate|--no-pager|--bare|--no-replace-objects|\
      --literal-pathspecs|--icase-pathspecs|--noglob-pathspecs|--glob-pathspecs) i=$((i+1)); continue ;;
      --*=*) is_hookspath_kv "$t" && hookspath=1; i=$((i+1)); continue ;;
      -*) i=$((i+1)); continue ;;
      *) break ;;
    esac
  done
  [ "$i" -ge "$n" ] && { [ "$hookspath" -eq 1 ] && return 0; return 1; }
  sub="${args[$i]}"; i=$((i+1))
  while [ "$i" -lt "$n" ]; do
    t="${args[$i]}"
    case "$t" in
      --) break ;;
      --no-verify|--no-v|--no-ve|--no-ver|--no-veri|--no-verif) has_nv=1 ;;
      -n) [ "$sub" = "commit" ] && has_cn=1 ;;
      --*) ;;
      -[!-]*) [ "$sub" = "commit" ] && short_has_n "$t" && has_cn=1 ;;
    esac
    [ "$sub" = "config" ] && is_hookspath_kv "$t" && config_hookspath=1
    i=$((i+1))
  done
  case "$sub" in
    commit|push|merge|cherry-pick|rebase|am)
      [ "$has_nv" -eq 1 ] && return 0
      [ "$hookspath" -eq 1 ] && return 0 ;;   # hooksPath override on a hook-running cmd
    config)
      [ "$config_hookspath" -eq 1 ] && return 0 ;;
  esac
  [ "$sub" = "commit" ] && [ "$has_cn" -eq 1 ] && return 0
  # A non-gated subcommand may be an ALIAS for a gated one — resolve and re-scan.
  case "$sub" in
    commit|push|merge|cherry-pick|rebase|am|config) ;;
    *) alias_is_bad "$sub" && return 0 ;;
  esac
  # hooksPath on a non-gated subcommand (log/status) is harmless → not blocked.
  return 1
}

if is_agent && violates_args "$@"; then
  {
    echo "BLOCKED: git --no-verify / commit -n skips hooks — not allowed for agents."
    echo "  The pipeline-entry + adversarial hooks must run. Remove --no-verify / -n."
    echo "  Human override: $REAL_GIT $*"
    echo "  Remove the shim entirely: ZUVO_UNINSTALL_GIT_SHIM=1 git"
  } >&2
  exit 1
fi

exec "$REAL_GIT" "$@"
