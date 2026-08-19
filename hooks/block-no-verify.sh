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

# DOCUMENTED ESCAPE (was promised in the block message but never implemented — fixed 2026-07-02):
# a command that carries an explicit `ZUVO_ALLOW_ADHOC=1` is a deliberate, visible-in-transcript
# override (same logged-escape semantics as the pipeline/work gates honor). Allow it LOUDLY.
# Legit use: removing a stale repo-local core.hooksPath override to RESTORE the global gate layer.
# Word-boundary match (not bare substring): the token must stand alone, so an incidental
# occurrence glued inside another word does not trip it. Residue: a QUOTED argument containing
# the standalone token still matches — acceptable for a BEST-EFFORT layer (see header): writing
# the escape marker anywhere is a deliberate, transcript-visible act, and the robust layers
# (git PATH-shim, CI gate) are unaffected by this hook's decisions.
if printf '%s' "$CMD" | grep -qE '(^|[[:space:]])ZUVO_ALLOW_ADHOC=1([[:space:]]|$)'; then
  echo "block-no-verify: ZUVO_ALLOW_ADHOC=1 escape honored (logged) — command allowed despite hook-skip pattern" >&2
  exit 0
fi

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

# --- ALIAS USAGE (B-noverify-hardening #1) --------------------------------------------------
# Alias CREATION was already blocked (`git config alias.x "commit --no-verify"`). Alias USAGE was
# not: an alias defined earlier — by a human, in ~/.gitconfig, or before this hook existed — turns
# `git yolo -m x` into `git commit --no-verify -m x` with nothing on the command line for a string
# parser to see. Measured before the fix: rc=0.
#
# Resolution asks git itself rather than parsing config files, so it sees the same precedence git
# will use (repo over global over system) and needs no knowledge of includes.
#
# Two guards make it safe to recurse: a depth limit, and a seen-set, because aliases legitimately
# chain (`alias.a = b`, `alias.b = commit --no-verify`) and can be defined circularly (`a = b`,
# `b = a`), which would otherwise hang the hook — a hang being worse than the bypass, since every
# Bash tool call goes through here.
#
# `!shell` aliases cannot be parsed as git argv at all, so their TEXT is scanned instead. That is
# weaker and deliberately so: this is the best-effort layer, the PATH-shim sees real argv and CI is
# server-side. Anything that errors resolves to "not an alias" — fail-open, matching the rest of
# this hook, EXCEPT that a failure here cannot re-open a bypass the direct-flag scan already caught.
_ZBNV_ALIAS_SEEN=""
alias_is_bad() {
  local name="${1:-}" depth="${2:-0}" exp first
  [ -n "$name" ] || return 1
  [ "$depth" -lt 5 ] || return 1
  case "$name" in -*) return 1 ;; esac
  case " $_ZBNV_ALIAS_SEEN " in *" $name "*) return 1 ;; esac
  _ZBNV_ALIAS_SEEN="$_ZBNV_ALIAS_SEEN $name"

  # Aliases cannot shadow builtins (git refuses to run them), so a builtin name is never worth a
  # config read. This is a latency guard on the hot path, not a security decision.
  case "$name" in
    add|status|log|diff|show|fetch|pull|checkout|switch|restore|branch|tag|stash|    rev-parse|ls-files|for-each-ref|cat-file|describe|blame|worktree|remote|clone|init|    reset|revert|clean|apply|bisect|grep|mv|rm|shortlog|reflog|gc|fsck|notes|submodule) return 1 ;;
  esac

  exp="$(git config --get "alias.$name" 2>/dev/null)" || return 1
  [ -n "$exp" ] || return 1

  case "$exp" in
    '!'*)
      # Pad with spaces so a flag at either end of the string still has a delimiter on both
      # sides — the abbreviation patterns below need one and would otherwise miss a trailing
      # `--no-verif`.
      _zbnv_low=" $(printf '%s' "$exp" | tr '[:upper:]' '[:lower:]') "
      case "$_zbnv_low" in
        *--no-verify*|*core.hookspath*) return 0 ;;
      esac
      # git accepts any UNAMBIGUOUS abbreviation, so `--no-verif` is `--no-verify`. The direct-flag
      # scan (violates_segment) and the config-creation scan both already carry the full set; this
      # branch carried only the full word, which made `!git commit --no-verif` a live hook-skip
      # bypass through the one layer that reads a shell string instead of argv. Verified by
      # execution, not by reading: the alias returned rc=0 (allow) where the same flag typed
      # directly returns rc=2.
      #
      # The delimiter class is what keeps this from over-blocking: matching a bare `*--no-v*`
      # would also swallow `--no-verbose`, a real and harmless git flag. Requiring the token to
      # END means `--no-ve` in `--no-verbose` is followed by `r` and does not match, while
      # `--no-ve ` (a genuine abbreviation) does.
      case "$_zbnv_low" in
        *--no-v[\ \;\&\|\'\"\`]*|*--no-ve[\ \;\&\|\'\"\`]*|*--no-ver[\ \;\&\|\'\"\`]*|\
        *--no-veri[\ \;\&\|\'\"\`]*|*--no-verif[\ \;\&\|\'\"\`]*) return 0 ;;
      esac
      return 1 ;;
  esac

  local etoks=() _t
  while IFS= read -r _t; do etoks+=("$_t"); done < <(printf 'git %s' "$exp" | xargs -n1 printf '%s\n' 2>/dev/null)
  if [ "${#etoks[@]}" -gt 0 ]; then
    violates_segment "${etoks[@]}" && return 0
  fi
  first="${exp%% *}"
  [ "$first" = "$name" ] && return 1
  alias_is_bad "$first" $((depth + 1))
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
    # A non-gated subcommand may be an ALIAS for a gated one — resolve and re-scan.
    case "$sub" in
      commit|push|merge|cherry-pick|rebase|am|config) ;;
      *) alias_is_bad "$sub" && return 0 ;;
    esac
    # NOTE: hooksPath on a NON-gated subcommand (log/status/…) is harmless (no
    # hooks run) and is intentionally NOT blocked — avoids over-blocking.
  done
  return 1
}

# --- strip HEREDOC BODIES before tokenizing (B-gate-9) -----------------------
# A heredoc body is DATA on stdin, never argv. `git commit -F - <<EOF … EOF` with a message
# mentioning `tail -n 100` used to flatten, via xargs below, into a standalone `-n` token sitting
# after `git commit` — and got BLOCKED as `commit -n`. A legitimate commit, refused, twice in one
# day. (Quoted `-m "… -n …"` messages were never affected: xargs keeps those as one token. Only
# the heredoc path was broken, which is why the original report over-attributed it.)
#
# Conservative by construction: a body is dropped ONLY when its closing delimiter is actually
# found. An unterminated heredoc is left completely untouched, so this can never make the hook
# blinder than before — the failure mode of a bad guess here would be fail-OPEN, and that is the
# one direction a bypass-defense hook must not move in.
_strip_heredocs() {
  awk '
    # Is the first `<<` on this line inside a quoted string? Walks the prefix once, tracking
    # single/double quote state and honouring backslash escapes. Deliberately conservative: on
    # ANY doubt the caller treats the line as NOT an opener, which means nothing is stripped and
    # the tokenizer sees the raw command — the safe direction for a bypass-defense hook.
    function quotes_open_before(line,   p, i, c, sq, dq, prev) {
      p = index(line, "<<")
      if (p == 0) return 0
      sq = 0; dq = 0; prev = ""
      for (i = 1; i < p; i++) {
        c = substr(line, i, 1)
        if (prev == "\\") { prev = ""; continue }
        if (c == "\\") { prev = "\\"; continue }
        if (c == "\x27" && dq == 0) sq = 1 - sq
        else if (c == "\x22" && sq == 0) dq = 1 - dq
        prev = ""
      }
      return (sq || dq)
    }
    function delim_of(line,   m) {
      # <<EOF | <<-EOF | <<"EOF" | <<\x27EOF\x27  (skip << that is really a <<< herestring)
      # A COMMENT is not a heredoc opener. `# <<EOF` followed by `git push --no-verify` and a
      # lone `EOF` made this filter suppress the bypass before tokenization — rc=0, gate silent.
      # Reproduced 2026-08-17 by adversarial review of this very commit. The quoted variant it
      # also alleged (`echo "<<EOF"; git push --no-verify; echo EOF`) does NOT bypass: verified
      # rc=2. Only the comment form was real, so only the comment form is fixed here.
      if (line ~ /^[[:space:]]*#/) return ""
      if (line !~ /<<-?[[:space:]]*("[^"]+"|\x27[^\x27]+\x27|[A-Za-z_][A-Za-z0-9_]*)/) return ""
      if (line ~ /<<</) return ""
      # A `<<` INSIDE a quoted string is not an opener either, and this one is a live BYPASS,
      # not a false positive: `echo "hi <<X"` / `git push --no-verify` / `X` made the stripper
      # swallow the bypass line and the gate returned 0. Found by the adversarial pass over the
      # commit that added this stripper. An earlier fix checked the sibling case
      # `echo "<<EOF"` + `echo EOF` and correctly found it safe — but only because `echo EOF`
      # never CLOSES the heredoc, so nothing was stripped. With a bare terminator line it does.
      # Test: is the quote count before the `<<` odd? Then we are inside a string.
      if (quotes_open_before(line)) return ""
      m = line
      sub(/^.*<<-?[[:space:]]*/, "", m)
      sub(/[[:space:]].*$/, "", m)
      gsub(/^["\x27]|["\x27]$/, "", m)
      return m
    }
    BEGIN { pend = "" }
    {
      lines[NR] = $0
      if (pend == "") { d = delim_of($0); if (d != "") { pend = d; start[NR] = d } }
      else {
        t = $0; sub(/^\t+/, "", t)
        if (t == pend || $0 == pend) { close_at[NR] = pend; pend = "" }
      }
    }
    END {
      # Only suppress bodies whose delimiter was CLOSED. Walk once, tracking state.
      cur = ""
      for (i = 1; i <= NR; i++) {
        if (cur == "") {
          print lines[i]
          if (i in start) {
            # look ahead for a matching close; only then enter suppression
            for (j = i + 1; j <= NR; j++) if ((j in close_at) && close_at[j] == start[i]) { cur = start[i]; break }
          }
        } else {
          if ((i in close_at) && close_at[i] == cur) cur = ""
          # body and terminator both suppressed
        }
      }
    }
  '
}

# QUOTE-AWARE tokenization via xargs (respects quotes; newlines → whitespace).
# Connectors space-padded first so glued `a&&git …` and `a ; git …` both expose
# the git tokens; violates_segment then scans EVERY git in the flat list.
TOKS=()
while IFS= read -r _tk; do TOKS+=("$_tk"); done < <(
  printf '%s' "$CMD" | _strip_heredocs | sed -E 's/[&|;]/ & /g' | xargs -n1 printf '%s\n' 2>/dev/null
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
