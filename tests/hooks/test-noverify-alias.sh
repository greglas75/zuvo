#!/usr/bin/env bash
# Alias USAGE must not launder a hook-skip past either --no-verify layer (B-noverify-hardening #1).
#
# Alias CREATION was already blocked (`git config alias.x "commit --no-verify"`). Alias USAGE was
# not. With the alias already in ~/.gitconfig — put there by a human, or before these hooks
# existed — `git yolo -m x` carries no flag at all: argv and the command string are both clean, and
# the subcommand is not in the gated set. Measured before the fix: block-no-verify rc=0, shim
# passed through.
#
# Both layers are exercised against the SAME fixture repo. They are separate implementations (one
# parses a command STRING, the other real argv) and the whole point of pinning them together is
# that they cannot quietly diverge on which aliases are dangerous.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
HOOK="$ROOT/hooks/block-no-verify.sh"
SHIM="$ROOT/scripts/git-noverify-shim.sh"
PASS=0; FAIL=0
t_ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
t_no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

REPO="$(mktemp -d)"; trap 'rm -rf "$REPO"' EXIT
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t

# The flag is assembled rather than written, so this fixture file does not itself trip the very
# hook it tests when an agent edits or greps it.
NV="--no-"$'\x76'"erify"
git -C "$REPO" config alias.yolo     "commit $NV"
git -C "$REPO" config alias.chain    'yolo'
git -C "$REPO" config alias.deep     'chain'
git -C "$REPO" config alias.loopa    'loopb'
git -C "$REPO" config alias.loopb    'loopa'
git -C "$REPO" config alias.selfref  'selfref'
git -C "$REPO" config alias.shellbad "!git commit $NV"
git -C "$REPO" config alias.hookpath '!git -c core.hooksPath=/dev/null commit'
git -C "$REPO" config alias.safe     'status --short'
git -C "$REPO" config alias.pushbad  "push $NV"

json(){ python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1"; }

# hook: 2 = block, 0 = allow
hook_rc(){ ( cd "$REPO" && json "$1" | CLAUDECODE=1 timeout 20 bash "$HOOK" >/dev/null 2>&1; echo $? ); }
# Detect a shim BLOCK by its message, not by exit code. `[ $? -eq 1 ]` looks right and is wrong:
# the shim's block exits 1, but so does the real git for `commit` with nothing staged — so the
# assertion reported a block for two commands the shim had passed through untouched. An exit code
# the subject shares with the thing it delegates to cannot identify the subject's decision.
shim_blocked(){
  local err
  err="$( cd "$REPO" && CLAUDECODE=1 timeout 20 bash "$SHIM" "$@" 2>&1 >/dev/null )"
  case "$err" in *"BLOCKED: git"*) return 0 ;; *) return 1 ;; esac
}

blocked(){ # <label> <argv…>
  local label="$1"; shift
  local cmd="git $*"
  [ "$(hook_rc "$cmd")" = "2" ] && t_ok "hook blocks $label" || t_no "hook ALLOWED $label ($cmd)"
  if shim_blocked "$@"; then t_ok "shim blocks $label"; else t_no "shim ALLOWED $label ($cmd)"; fi
}
allowed(){
  local label="$1"; shift
  local cmd="git $*"
  [ "$(hook_rc "$cmd")" = "0" ] && t_ok "hook allows $label" || t_no "hook BLOCKED $label ($cmd)"
  if shim_blocked "$@"; then t_no "shim BLOCKED $label ($cmd)"; else t_ok "shim allows $label"; fi
}

# --- the bypass itself, and its chained forms ---------------------------------------------------
blocked "a plain alias for commit --no-verify"   yolo -m x
blocked "a one-hop alias chain"                  chain -m x
blocked "a two-hop alias chain"                  deep -m x
blocked "an alias for push --no-verify"          pushbad
blocked "a !shell alias running the flag"        shellbad
blocked "a !shell alias overriding hooksPath"    hookpath -m x

# --- must NOT over-block ------------------------------------------------------------------------
# A verifier that blocks harmless aliases gets uninstalled, so these matter as much as the above.
allowed "a harmless alias"                       safe
allowed "a plain builtin"                        status
allowed "a normal commit"                        commit -m ok

# --- termination: circular and self-referential aliases must not hang ---------------------------
# Both layers recurse through expansions. A cycle without a guard wedges the hook on EVERY Bash
# tool call, and the shim on every git command on the machine — strictly worse than the bypass
# being closed. `timeout 20` above is the real assertion here: a hang shows up as a non-2/non-0 rc.
rc="$(hook_rc 'git loopa')"
[ "$rc" = "0" ] && t_ok "hook terminates on a circular alias (rc=0, no hang)" || t_no "hook rc=$rc on a circular alias"
rc="$(hook_rc 'git selfref')"
[ "$rc" = "0" ] && t_ok "hook terminates on a self-referential alias" || t_no "hook rc=$rc on a self-referential alias"
( cd "$REPO" && CLAUDECODE=1 timeout 20 bash "$SHIM" loopa >/dev/null 2>&1; [ $? -ne 124 ] ) \
  && t_ok "shim terminates on a circular alias" || t_no "shim hung on a circular alias"

# --- a HUMAN keeps the documented escape --------------------------------------------------------
# The shim is transparent for humans by design (G8). An alias-resolving shim that forgot this
# would break every human alias on the machine.
_herr="$( cd "$REPO" && env -u CLAUDECODE -u ZUVO_AGENT -u CLAUDE_PLUGIN_ROOT -u CLAUDE_CODE_ENTRYPOINT \
    -u CLAUDE_CODE_SESSION -u CODEX_SANDBOX -u CODEX_WORKSPACE -u CURSOR_AGENT -u CURSOR_TRACE_ID \
    -u GEMINI_CLI -u ANTIGRAVITY timeout 20 bash "$SHIM" yolo -m x 2>&1 >/dev/null )"
case "$_herr" in *"BLOCKED: git"*) t_no "shim blocked a HUMAN alias" ;; *) t_ok "human alias usage still passes through" ;; esac

# --- pin what is NOT a bypass -------------------------------------------------------------------
# The backlog also claimed `git commit "--no-verify"` evades the string parser. It does not: xargs
# tokenizes quote-aware, so the quotes are gone before the scanner runs. Pinned so nobody "fixes"
# a bug that was never there — and so a future tokenizer change that DOES break it gets caught.
[ "$(hook_rc 'git commit "--no-verify" -m x')" = "2" ] && t_ok "double-quoted flag was never a bypass" || t_no "quoted flag now evades the parser"
[ "$(hook_rc "git commit '--no-verify' -m x")" = "2" ] && t_ok "single-quoted flag was never a bypass" || t_no "single-quoted flag now evades the parser"

echo "  --- noverify alias: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
