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

violates_segment() {
  [ "$#" -gt 0 ] || return 1
  local toks=("$@") n=$# i=0 gitidx=-1 t sub
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
      -c|-C|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix)
        i=$((i+2)); continue ;;
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*)
        i=$((i+1)); continue ;;
      -p|-P|--paginate|--no-pager|--bare|--no-replace-objects|\
      --literal-pathspecs|--icase-pathspecs|--noglob-pathspecs|--glob-pathspecs)
        i=$((i+1)); continue ;;
      --*=*) i=$((i+1)); continue ;;
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
      --no-verify) has_noverify=1 ;;
      -n) [ "$sub" = "commit" ] && has_commit_n=1 ;;
      --*) ;;
      -*) case "$sub" in commit) case "$t" in *n*) has_commit_n=1 ;; esac ;; esac ;;
    esac
    i=$((i+1))
  done

  case "$sub" in
    commit|push|merge|cherry-pick|rebase|am)
      [ "$has_noverify" -eq 1 ] && return 0 ;;
  esac
  [ "$sub" = "commit" ] && [ "$has_commit_n" -eq 1 ] && return 0
  return 1
}

# split on connectors, tokenize each segment, check
segments=$(printf '%s' "$CMD" | sed -E 's/(\&\&|\|\||;|\||&)/\
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
