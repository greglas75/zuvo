#!/usr/bin/env bash
# Task 10 — assert block-no-verify + single-site Stop nudge wired across all
# harness configs, correct shapes, no existing hook dropped, valid JSON.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLAUDE="$ROOT/hooks/hooks.json"
CODEX="$ROOT/hooks/hooks.codex.json"
ANTIG="$ROOT/hooks/hooks.antigravity.json"
# Kimi's config is a FLAT [[hooks]] TOML array, not the nested JSON shape, so it needs
# its own reader. It was absent from this file entirely — which meant the one test whose
# stated job is "no existing hook dropped, across all harness configs" was blind to the
# config carrying the MOST hooks (11, versus Antigravity's 4).
KIMI="$ROOT/hooks/hooks.kimi.toml"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required for this test"; exit 1; }

# all valid JSON
for f in "$CLAUDE" "$CODEX" "$ANTIG"; do
  jq -e . "$f" >/dev/null 2>&1 && pass "valid JSON: ${f##*/}" || bad "invalid JSON: ${f##*/}"
done

cmds() { jq -r '.. | .command? // empty' "$1" 2>/dev/null; }
has()  { cmds "$1" | grep -q "$2"; }
countall() { cat "$CLAUDE" "$CODEX" "$ANTIG" | jq -rs '.[] | .. | .command? // empty' 2>/dev/null | grep -c "$1"; }

# block-no-verify present in all three
has "$CLAUDE" 'block-no-verify.sh' && pass "Claude: block-no-verify wired" || bad "Claude: block-no-verify missing"
has "$CODEX"  'block-no-verify.sh' && pass "Codex: block-no-verify wired"  || bad "Codex: block-no-verify missing"
has "$ANTIG"  'block-no-verify.sh' && pass "Antigravity: block-no-verify wired" || bad "Antigravity: block-no-verify missing"

# correct shape: Claude PreToolUse Bash, Codex PreToolUse Bash, Antigravity BeforeTool run_shell_command
jq -e '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[] | select(.command|test("block-no-verify"))' "$CLAUDE" >/dev/null 2>&1 \
  && pass "Claude: block-no-verify under PreToolUse/Bash" || bad "Claude: block-no-verify wrong matcher"
jq -e '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[] | select(.command|test("block-no-verify"))' "$CODEX" >/dev/null 2>&1 \
  && pass "Codex: block-no-verify under PreToolUse/Bash" || bad "Codex: block-no-verify wrong matcher"
jq -e '.hooks.BeforeTool[] | select(.matcher=="run_shell_command") | .hooks[] | select(.command|test("block-no-verify"))' "$ANTIG" >/dev/null 2>&1 \
  && pass "Antigravity: block-no-verify under BeforeTool/run_shell_command" || bad "Antigravity: block-no-verify wrong matcher"

# existing gates still present (not dropped)
for f in "$CLAUDE" "$CODEX" "$ANTIG"; do
  has "$f" 'pre-push-gate.sh' && pass "${f##*/}: pre-push-gate preserved" || bad "${f##*/}: pre-push-gate dropped"
  has "$f" 'pre-commit-adversarial-gate.sh' && pass "${f##*/}: commit-gate preserved" || bad "${f##*/}: commit-gate dropped"
done
# Claude session-start + rewake hooks not dropped
has "$CLAUDE" 'run-hook.cmd' && pass "Claude: session-start preserved" || bad "Claude: session-start dropped"
has "$CLAUDE" 'zuvo-rewake-reset.sh' && pass "Claude: rewake-reset preserved" || bad "Claude: rewake-reset dropped"
has "$CLAUDE" 'zuvo-rewake-on-failure.sh' && pass "Claude: rewake-on-failure preserved" || bad "Claude: rewake-on-failure dropped"

# Stop nudge: present in Claude Stop, absent in Codex/Antigravity, EXACTLY one site total
jq -e '.hooks.Stop[] | .hooks[] | select(.command|test("zuvo-stop-pipeline-gate"))' "$CLAUDE" >/dev/null 2>&1 \
  && pass "Claude: Stop nudge in Stop array" || bad "Claude: Stop nudge missing from Stop"
# Claude Stop nudge must be async:false so exit 2 is honored
jq -e '.hooks.Stop[] | .hooks[] | select(.command|test("zuvo-stop-pipeline-gate")) | select(.async==false)' "$CLAUDE" >/dev/null 2>&1 \
  && pass "Claude: Stop nudge async:false (exit 2 honored)" || bad "Claude: Stop nudge not async:false"
has "$CODEX" 'zuvo-stop-pipeline-gate' && bad "Codex: Stop nudge should be ABSENT (no Stop support)" || pass "Codex: Stop nudge correctly absent [STOP-UNSUPPORTED:codex]"
has "$ANTIG" 'zuvo-stop-pipeline-gate' && bad "Antigravity: Stop nudge should be ABSENT (no Stop support)" || pass "Antigravity: Stop nudge correctly absent [STOP-UNSUPPORTED:antigravity]"

# ── the Stop-nudge count is PER CONFIG, not a global total ────────────────────
# The old assertion summed the nudge across CLAUDE+CODEX+ANTIG and demanded exactly 1.
# That worked only while Claude was the sole harness with a Stop event, and it is the
# wrong shape twice over: it would have passed with Claude at 0 and Codex at 1, and it
# goes stale the moment a second Stop-capable harness registers the nudge legitimately —
# which Kimi does (hooks.kimi.toml:76). The real invariant is what the nudge needs to
# behave: at most one registration inside any single session, i.e. exactly one per
# Stop-capable config and zero elsewhere.
n=$(cmds "$CLAUDE" | grep -c 'zuvo-stop-pipeline-gate')
[ "$n" -eq 1 ] && pass "Claude: Stop nudge registered exactly once" || bad "Claude: Stop nudge registered $n times (must be exactly 1)"
for f in "$CODEX" "$ANTIG"; do
  n=$(cmds "$f" | grep -c 'zuvo-stop-pipeline-gate')
  [ "$n" -eq 0 ] && pass "${f##*/}: Stop nudge absent (count=0)" || bad "${f##*/}: Stop nudge registered $n times on a harness without Stop"
done

# ── Windows: EVERY Claude Code hook must go through run-hook.cmd ──────────────
# `bash "${CLAUDE_PLUGIN_ROOT}/hooks/x.sh"` requires bash on the system PATH. Git for Windows
# does not always put it there — its "Git Bash only" install option deliberately does not. Only
# run-hook.cmd carries the fallback that probes C:\Program Files\Git\bin\bash.exe, so a hook
# wired directly to bash is silently dead on exactly the machines that need the fallback.
# Before this test, 10 of 11 hooks were wired directly and only SessionStart used the shim.
direct=$(jq -r '[.hooks[][] | .hooks[] | .command | select(startswith("bash "))] | length' "$CLAUDE" 2>/dev/null || echo -1)
[ "$direct" = "0" ] \
  && pass "Claude: no hook bypasses run-hook.cmd (bash-on-PATH not assumed)" \
  || bad "Claude: $direct hook(s) call bash directly — no bash-discovery fallback on Windows"
shimmed=$(jq -r '[.hooks[][] | .hooks[] | .command | select(contains("run-hook.cmd"))] | length' "$CLAUDE" 2>/dev/null || echo 0)
total=$(jq -r '[.hooks[][] | .hooks[]] | length' "$CLAUDE" 2>/dev/null || echo 0)
[ "$shimmed" = "$total" ] && [ "$total" != "0" ] \
  && pass "Claude: all $total hooks routed through the shim" \
  || bad "Claude: only $shimmed of $total hooks routed through run-hook.cmd"
# The shim itself must keep its bash-discovery fallback — that is the whole point of routing here.
grep -q 'Program Files\\Git\\bin\\bash.exe' "$ROOT/hooks/run-hook.cmd" \
  && pass "run-hook.cmd retains the Git-for-Windows bash fallback" \
  || bad "run-hook.cmd lost its bash-discovery fallback"

# ── Kimi Code (hooks.kimi.toml) ───────────────────────────────────────────────
# Kimi is the one non-Claude target zuvo does NOT degrade: it has every event zuvo
# uses, including StopFailure, so the API-error rewake path survives there where the
# Cursor and Antigravity builds must drop it. That makes its hook config the one most
# likely to drift silently — it is the only non-Claude config expected to stay at full
# parity, and nothing here was checking it.
if [ ! -f "$KIMI" ]; then
  bad "hooks.kimi.toml missing — the Kimi target ships no hook config"
else
  # Reader for the flat TOML array. Prefer tomllib (same parser install.sh validates the
  # merged config with, scripts/install.sh:1511) so a file that parses here is a file
  # that will merge there; fall back to a line scan if the interpreter is too old, which
  # loses parse-validity but keeps every content assertion below alive.
  KIMI_PARSED=0
  if python3 -c 'import tomllib' >/dev/null 2>&1; then
    KIMI_PARSED=1
    if python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' "$KIMI" >/dev/null 2>&1; then
      pass "valid TOML: hooks.kimi.toml (tomllib — same parser install.sh gates the merge on)"
    else
      bad "invalid TOML: hooks.kimi.toml — install.sh would refuse the merge and Kimi would get NO zuvo hooks"
    fi
  else
    pass "hooks.kimi.toml TOML-parse check skipped (python3 tomllib unavailable); content checks still run"
  fi

  kimi_cmds() {
    if [ "$KIMI_PARSED" -eq 1 ]; then
      python3 -c 'import tomllib,sys
d=tomllib.load(open(sys.argv[1],"rb"))
for h in d.get("hooks",[]): print(h.get("event",""),"\t",h.get("matcher",""),"\t",h.get("command",""))' "$KIMI"
    else
      awk '/^event *=/{e=$0} /^matcher *=/{m=$0} /^command *=/{print e"\t"m"\t"$0}' "$KIMI"
    fi
  }
  khas() { kimi_cmds | grep -q "$1"; }

  khas 'block-no-verify.sh' && pass "Kimi: block-no-verify wired" || bad "Kimi: block-no-verify missing"
  kimi_cmds | grep 'block-no-verify' | grep -q 'PreToolUse' \
    && pass "Kimi: block-no-verify under PreToolUse" || bad "Kimi: block-no-verify wrong event"
  khas 'pre-push-gate.sh' && pass "Kimi: pre-push-gate preserved" || bad "Kimi: pre-push-gate dropped"
  khas 'pre-commit-adversarial-gate.sh' && pass "Kimi: commit-gate preserved" || bad "Kimi: commit-gate dropped"

  # Kimi HAS Stop, so unlike Codex/Antigravity the nudge belongs here — exactly once.
  n=$(kimi_cmds | grep -c 'zuvo-stop-pipeline-gate')
  [ "$n" -eq 1 ] && pass "Kimi: Stop nudge registered exactly once" || bad "Kimi: Stop nudge registered $n times (Kimi supports Stop; must be exactly 1)"

  # StopFailure is the single capability that separates Kimi from the degraded targets.
  # If it ever vanishes the build still succeeds and every test still passes, while an
  # API-error-killed run on Kimi silently stops resuming — the exact failure the rewake
  # layer exists to prevent.
  kimi_cmds | grep -q 'StopFailure' \
    && pass "Kimi: StopFailure rewake wired (the capability Cursor/Antigravity must drop)" \
    || bad "Kimi: StopFailure hook gone — API-error rewake dead on the one target that supports it"

  # ── 1:1 parity with the Claude manifest ──────────────────────────────────────
  # hooks.kimi.toml's own header claims "Event coverage vs the Claude Code manifest:
  # 1:1". Left as prose, that claim rots the first time a hook is added to hooks.json
  # alone — and the addition would look complete, because every other assertion here is
  # about hooks that already exist. Compared as SETS so a drop and an addition are both
  # named, in both directions.
  if [ "$KIMI_PARSED" -eq 1 ]; then
    parity="$(python3 - "$CLAUDE" "$KIMI" <<'PY'
import json, re, sys, tomllib
def scripts(cmds):
    out = set()
    for c in cmds:
        for m in re.findall(r'[\w.-]+\.(?:sh|cmd)|session-start', c):
            if m != "run-hook.cmd":   # the Windows shim wraps the real script, it is not one
                out.add(m)
    return out
def walk(o):
    if isinstance(o, dict):
        if isinstance(o.get("command"), str): yield o["command"]
        for v in o.values(): yield from walk(v)
    elif isinstance(o, list):
        for v in o: yield from walk(v)
claude = scripts(walk(json.load(open(sys.argv[1]))))
kimi   = scripts(h.get("command","") for h in tomllib.load(open(sys.argv[2],"rb")).get("hooks", []))
missing, extra = sorted(claude - kimi), sorted(kimi - claude)
print("OK" if not missing and not extra else
      "DRIFT missing_in_kimi=[%s] not_in_claude=[%s]" % (",".join(missing), ",".join(extra)))
PY
)"
    case "$parity" in
      OK) pass "Kimi: hook coverage is 1:1 with hooks.json (both $(kimi_cmds | wc -l | tr -d ' ') entries)" ;;
      *)  bad "Kimi: hook coverage drifted from hooks.json — $parity" ;;
    esac
  fi
fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
