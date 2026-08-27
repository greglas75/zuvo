# zuvo sleep guard — enforcement that does not depend on a Codex hook running.
#
# Codex executes every command as `/bin/zsh -lc '<command>'`, and a login zsh reads ~/.zshenv.
# So the shell itself can apply the rule the hook was meant to apply — and unlike the hook, this
# has been observed to fire (docs/runbook/operating.md §11: no Codex hook has ever been seen to
# execute on this machine).
#
# NARROW BY DESIGN. It acts only when ALL of these hold:
#   - the shell is non-interactive with a -c string (so an interactive `sleep 5` is untouched)
#   - the PARENT process is codex (so scripts, CI, make, and other agents are untouched)
#   - the sleep is >= 5s and NOT inside a do…done loop (a loop is the shape being asked for)
#   - ~/.zuvo/no-sleep-guard does not exist (one-line, permanent off switch)
#
# It does not kill the command: it declines the delay, explains, and returns 1. Anything after a
# `;` still runs, so nothing is destroyed — the agent simply gets the guidance and no free wait.

zuvo_sleep_guard() {
  emulate -L zsh
  [[ -o interactive ]] && return 1
  [[ -n "$ZSH_EXECUTION_STRING" ]] || return 1
  [[ -e "$HOME/.zuvo/no-sleep-guard" ]] && return 1
  # Walk UP the process tree, not just one level: `comm` on a script shows the interpreter, and
  # Codex may put an intermediate process between itself and the shell. Four levels is enough to
  # reach it and cheap enough to run per sleep.
  local pid=$PPID depth=0 args="" found=0
  while (( depth < 4 )) && [[ -n "$pid" && "$pid" != 0 && "$pid" != 1 ]]; do
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if [[ "$args" == *codex* || "$args" == *Codex* || "$args" == *ChatGPT.app* ]]; then
      found=1; break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    (( depth++ ))
  done
  (( found )) || return 1
  local n=$1
  [[ "$n" == <-> || "$n" == <->.<-> ]] || return 1
  (( ${n%%.*} >= ${ZUVO_SLEEP_MIN:-5} )) || return 1
  # A sleep inside any loop body is exactly what the guidance asks for. Same test as the hook:
  # some `do` opens before it and some `done` closes after it — never keyword adjacency, which
  # breaks on a body that merely mentions `done`.
  local s=$ZSH_EXECUTION_STRING
  [[ $s == *do* && $s == *done* ]] && return 1
  return 0
}

sleep() {
  if zuvo_sleep_guard "$@"; then
    print -u2 -- "zuvo: declining \`sleep $1\` outside a loop — it costs one whole turn per interval."
    print -u2 -- "      Block in the shell instead and pay one round-trip however long it takes:"
    print -u2 -- "          until <condition>; do sleep $1; done && <read the result>"
    print -u2 -- "      Say nothing between checks. Off switch: touch ~/.zuvo/no-sleep-guard"
    return 1
  fi
  command sleep "$@"
}
