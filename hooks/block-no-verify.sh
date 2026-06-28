#!/usr/bin/env bash
# block-no-verify — reject git invocations that skip hooks.
#
# Blocks (exit 2):
#   - --no-verify on  commit | push | merge | cherry-pick | rebase | am
#   - -n (or a short bundle containing n, e.g. -nm) on COMMIT only
#     (-n is --dry-run for push/add, so those pass)
# Robust to global options BEFORE the subcommand: git -c k=v, git -C dir,
#   --git-dir=, --work-tree=, --namespace=, --exec-path, -p/-P/--paginate, …
# Handles chained commands (&&, ||, ;, |) and JSON tool-input (.command).
#
# Exit: 2 = block; 0 = allow / non-git / malformed (FAIL-OPEN).

set -uo pipefail

RAW=$(cat 2>/dev/null || true)

# Extract the command string from JSON tool-input if present; else use raw.
CMD="$RAW"
if command -v jq >/dev/null 2>&1; then
  _c=$(printf '%s' "$RAW" | jq -r '.tool_input.command // .command // empty' 2>/dev/null || true)
  [ -n "${_c:-}" ] && CMD="$_c"
fi
[ -n "$CMD" ] || exit 0

# Does a short-option CLUSTER (e.g. -nm, -an) contain -n as a FLAG? `n` counts
# only if it appears before any argument-taking short option (m/c/C/F/u/S/t/G/O),
# because everything after such a flag is its value. Fixes the false-positive
# where `-uno` (= -u no) was wrongly read as containing -n.
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

# Is a value mutating core.hooksPath (= hook bypass)? Matches the `key=value`
# form AND the boolean form (`git -c core.hooksPath` → git sets it to "true").
is_hookspath_kv() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    core.hookspath|core.hookspath=*|*core.hookspath=*) return 0 ;;
  esac
  return 1
}

violates_segment() {
  [ "$#" -gt 0 ] || return 1
  local toks=("$@") n=$# i=0 gitidx=-1 t sub hookspath=0 config_hookspath=0
  while [ "$i" -lt "$n" ]; do
    case "${toks[$i]}" in
      git|*/git) gitidx=$i; break ;;
    esac
    i=$((i+1))
  done
  [ "$gitidx" -lt 0 ] && return 1
  i=$((gitidx+1))

  # skip global options to reach the subcommand
  while [ "$i" -lt "$n" ]; do
    t="${toks[$i]}"
    case "$t" in
      -c|--config-env)
        is_hookspath_kv "${toks[$((i+1))]:-}" && hookspath=1
        i=$((i+2)); continue ;;
      -c*) is_hookspath_kv "${t#-c}" && hookspath=1; i=$((i+1)); continue ;;  # attached: -ccore.hooksPath=...
      -C|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix)
        i=$((i+2)); continue ;;
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*)
        i=$((i+1)); continue ;;
      -p|-P|--paginate|--no-pager|--bare|--no-replace-objects|\
      --literal-pathspecs|--icase-pathspecs|--noglob-pathspecs|--glob-pathspecs)
        i=$((i+1)); continue ;;
      --*=*) is_hookspath_kv "$t" && hookspath=1; i=$((i+1)); continue ;;
      -*)    i=$((i+1)); continue ;;
      *)     break ;;
    esac
  done
  [ "$i" -ge "$n" ] && return 1
  sub="${toks[$i]}"
  i=$((i+1))

  local has_noverify=0 has_commit_n=0
  while [ "$i" -lt "$n" ]; do
    t="${toks[$i]}"
    case "$t" in
      --) break ;;                                   # end of options
      --no-verify|--no-v|--no-ve|--no-ver|--no-veri|--no-verif) has_noverify=1 ;;  # incl. git's unambiguous abbreviations
      -n) [ "$sub" = "commit" ] && has_commit_n=1 ;;
      --*) ;;
      -[!-]*) [ "$sub" = "commit" ] && short_has_n "$t" && has_commit_n=1 ;;
    esac
    # `git config core.hooksPath <x>` persistently disables hooks
    [ "$sub" = "config" ] && is_hookspath_kv "$t" && config_hookspath=1
    i=$((i+1))
  done

  case "$sub" in
    commit|push|merge|cherry-pick|rebase|am)
      [ "$has_noverify" -eq 1 ] && return 0
      [ "$hookspath" -eq 1 ] && return 0 ;;   # core.hooksPath override = hook bypass
    config)
      [ "$config_hookspath" -eq 1 ] && return 0 ;;   # config writing core.hooksPath
  esac
  [ "$sub" = "commit" ] && [ "$has_commit_n" -eq 1 ] && return 0
  return 1
}

# Strip QUOTED substrings before segmenting so shell metacharacters inside a
# commit message (e.g. -m "fix UI & tests") cannot split a real --no-verify off
# the git segment, and a --no-verify mentioned INSIDE a message does not cause a
# false block. Real (unquoted) flags survive.
SCAN=$(printf '%s' "$CMD" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")

# split on connectors, tokenize each segment, check
segments=$(printf '%s' "$SCAN" | sed -E 's/(\&\&|\|\||;|\||&)/\
/g')

block=0
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  # shellcheck disable=SC2206
  read -ra toks <<< "$seg"
  if [ "${#toks[@]}" -gt 0 ] && violates_segment "${toks[@]}"; then
    block=1; break
  fi
done <<EOF
$segments
EOF

if [ "$block" -eq 1 ]; then
  {
    echo "BLOCKED: git --no-verify / commit -n skips hooks — not allowed for agents."
    echo "  Hooks (incl. the pipeline-entry gates) must run. Remove --no-verify / -n."
    echo "  If a hook is genuinely wrong, fix the hook — don't bypass it."
    echo "  Human override: run via /usr/bin/git, or set ZUVO_ALLOW_ADHOC=1 with a reason."
  } >&2
  exit 2
fi
exit 0
