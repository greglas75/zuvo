#!/usr/bin/env bash
# block-no-verify — reject git invocations that skip hooks (BEST-EFFORT layer).
#
# Blocks (exit 2):
#   - --no-verify (incl. unambiguous abbreviations) on commit|push|merge|
#     cherry-pick|rebase|am
#   - -n / short cluster containing -n (e.g. -nm) on COMMIT only (-n is --dry-run
#     for push/add, so those pass; -uno = -u no is NOT -n)
#   - core.hooksPath override via -c key=val (kv / attached / boolean / --config),
#     `git config core.hooksPath ...`, include.path, or GIT_CONFIG_* env assignment
#   - `git config alias.X "...--no-verify..."` (alias CREATION of a hook-skip)
#
# Robust to: global options before the subcommand, chained/newline-joined commands
# (scans EVERY git invocation in the token list), and quoting (xargs tokenizes
# quote-aware, so a commit message stays one token).
#
# This is a BEST-EFFORT defense. A determined adversary can still evade a command-
# STRING parser (alias USAGE, exotic quoting). The ROBUST layers are the git
# PATH-shim (real argv) and the CI gate (server-side). See docs/pipeline.md.
#
# Exit: 2 = block; 0 = allow / non-git / malformed (fail-open, except a non-empty
# git-ish command that fails to tokenize → fail CLOSED).

set -uo pipefail

RAW=$(cat 2>/dev/null || true)

# --- command extraction (jq, with an escaped-quote-aware jq-less fallback) ----
CMD="$RAW"
if command -v jq >/dev/null 2>&1; then
  _c=$(printf '%s' "$RAW" | jq -r '.tool_input.command // .command // empty' 2>/dev/null || true)
  [ -n "${_c:-}" ] && CMD="$_c"
else
  case "$RAW" in
    *'"command"'*)
      # skip escaped quotes (\") inside the JSON string value
      _c=$(printf '%s' "$RAW" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(\([^"\\]\|\\.\)*\)".*/\1/p' | head -1)
      [ -n "${_c:-}" ] && CMD="$_c" ;;
  esac
fi
[ -n "$CMD" ] || exit 0

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

# value mutating core.hooksPath (= direct hook bypass)? include.path is NOT
# blocked here — it is a legitimate, common config-include feature and its value
# does not reveal hooksPath without reading the file; over-blocking it would break
# real workflows. (include.path → documented residue; the shim + CI are robust.)
is_hookspath_kv() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    core.hookspath|core.hookspath=*|*core.hookspath=*) return 0 ;;
  esac
  return 1
}

# Scan the WHOLE token list — every git invocation (handles chained/newline-joined
# commands that xargs flattens into one list) + pre-git env injections.
violates_segment() {
  [ "$#" -gt 0 ] || return 1
  local toks=("$@") n=$# i=0 t env_hookspath=0
  # env-assignment hooksPath injection (GIT_CONFIG_KEY_*=core.hooksPath or a bare
  # core.hooksPath=... assignment token before git)
  for t in "${toks[@]}"; do
    case "$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')" in
      *=core.hookspath) case "$t" in *=*) env_hookspath=1 ;; esac ;;
    esac
  done

  while [ "$i" -lt "$n" ]; do
    # advance to the next git token
    while [ "$i" -lt "$n" ]; do case "${toks[$i]}" in git|*/git) break ;; esac; i=$((i+1)); done
    [ "$i" -ge "$n" ] && return 1
    i=$((i+1))   # past 'git'

    local sub="" hookspath="$env_hookspath"
    # global options before the subcommand
    while [ "$i" -lt "$n" ]; do
      t="${toks[$i]}"
      case "$t" in
        -c|--config-env) is_hookspath_kv "${toks[$((i+1))]:-}" && hookspath=1; i=$((i+2)); continue ;;
        -c*) is_hookspath_kv "${t#-c}" && hookspath=1; i=$((i+1)); continue ;;
        -C|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix) i=$((i+2)); continue ;;
        --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*) i=$((i+1)); continue ;;
        -p|-P|--paginate|--no-pager|--bare|--no-replace-objects|\
        --literal-pathspecs|--icase-pathspecs|--noglob-pathspecs|--glob-pathspecs) i=$((i+1)); continue ;;
        --*=*) is_hookspath_kv "$t" && hookspath=1; i=$((i+1)); continue ;;
        git|*/git) break ;;            # no subcommand for this invocation
        -*) i=$((i+1)); continue ;;
        *) sub="$t"; i=$((i+1)); break ;;
      esac
    done

    # No subcommand for this invocation → nothing to enforce (git errors anyway).
    [ -z "$sub" ] && continue

    # subcommand flags, until the next git invocation or end
    local has_noverify=0 has_commit_n=0 config_hookspath=0 alias_bad=0 ddash=0 saw_alias=0
    while [ "$i" -lt "$n" ]; do
      t="${toks[$i]}"
      case "$t" in
        git|*/git) break ;;
        --) ddash=1; i=$((i+1)); continue ;;
      esac
      if [ "$ddash" -eq 0 ]; then
        case "$t" in
          --no-verify|--no-v|--no-ve|--no-ver|--no-veri|--no-verif) has_noverify=1 ;;
          -n) [ "$sub" = "commit" ] && has_commit_n=1 ;;
          --*) ;;
          -[!-]*) [ "$sub" = "commit" ] && short_has_n "$t" && has_commit_n=1 ;;
        esac
      fi
      if [ "$sub" = "config" ]; then
        is_hookspath_kv "$t" && config_hookspath=1
        case "$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')" in alias.*) saw_alias=1 ;; esac
        if [ "$saw_alias" -eq 1 ]; then
          case "$t" in *--no-verify*|*--no-v*) alias_bad=1 ;; esac
          case "$t" in *' -n'*|*'-n ') alias_bad=1 ;; esac
        fi
      fi
      i=$((i+1))
    done

    case "$sub" in
      commit|push|merge|cherry-pick|rebase|am)
        [ "$has_noverify" -eq 1 ] && return 0
        [ "$hookspath" -eq 1 ] && return 0 ;;   # core.hooksPath override on a hook-running cmd
      config)
        { [ "$config_hookspath" -eq 1 ] || [ "$alias_bad" -eq 1 ]; } && return 0 ;;
    esac
    [ "$sub" = "commit" ] && [ "$has_commit_n" -eq 1 ] && return 0
    # NOTE: hooksPath on a NON-gated subcommand (log/status/…) is harmless (no
    # hooks run) and is intentionally NOT blocked — avoids over-blocking.
  done
  return 1
}

# QUOTE-AWARE tokenization via xargs (respects quotes; newlines → whitespace).
# Connectors space-padded first so glued `a&&git …` and `a ; git …` both expose
# the git tokens; violates_segment then scans EVERY git in the flat list.
TOKS=()
while IFS= read -r _tk; do TOKS+=("$_tk"); done < <(
  printf '%s' "$CMD" | sed -E 's/[&|;]/ & /g' | xargs -n1 printf '%s\n' 2>/dev/null
)

block=0
if [ "${#TOKS[@]}" -gt 0 ]; then
  violates_segment "${TOKS[@]}" && block=1
else
  # Non-empty command that FAILED to tokenize (e.g. unmatched quote) and looks
  # like a git hook-skip → fail CLOSED (safe direction for a bypass-defense hook).
  case "$CMD" in
    *git*)
      case "$CMD" in
        *--no-verify*|*--no-v*|*core.hooksPath*|*core.hookspath*) block=1 ;;
      esac ;;
  esac
fi

if [ "$block" -eq 1 ]; then
  {
    echo "BLOCKED: git --no-verify / commit -n / hook-path override skips hooks — not allowed for agents."
    echo "  Hooks (incl. the pipeline-entry gates) must run. Remove --no-verify / -n / core.hooksPath."
    echo "  If a hook is genuinely wrong, fix the hook — don't bypass it."
    echo "  Human override: run via /usr/bin/git, or set ZUVO_ALLOW_ADHOC=1 with a reason."
  } >&2
  exit 2
fi
exit 0
