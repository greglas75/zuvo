#!/usr/bin/env bash
# Fast paths and small helpers of the per-tool-call hooks (b0e65d51 + review fixes 2026-09-29).
#
# These hooks run on every tool call, so each gained an early exit before its expensive part.
# An early exit is only correct if it is a SUPERSET of the full logic — it may skip work, never a
# decision. This suite pins the behaviour of the files whose other suites did not reach it:
# track-includes (no test before), run-hook.cmd's directory resolution, the pre-push PreToolUse
# fast path, and the session-id path guard in heartbeat/track-includes.
#
# Hermetic: temp dirs only, synthetic stdin, no suite is started — valid on the farm.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

T="$(mktemp -d)"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

# ── track-includes.sh ───────────────────────────────────────────────────────────────────────────
TI="$ROOT/hooks/track-includes.sh"
SID="fastpath-$$"
LOG="/tmp/zuvo-includes-${SID}.txt"
rm -f "$LOG"
mkdir -p "$T/shared/includes"; printf 'x%.0s' $(seq 1 42) > "$T/shared/includes/demo.md"

printf '{"session_id":"%s","tool_input":{"file_path":"%s"}}' "$SID" "$T/shared/includes/demo.md" | bash "$TI"
if [ -f "$LOG" ] && grep -qx 'demo:42' "$LOG"; then pass "track-includes: a shared/includes read is logged as name:bytes"
else bad "track-includes: tracked read not logged (log: $(cat "$LOG" 2>/dev/null))"; fi

rm -f "$LOG"
printf '{"session_id":"%s","tool_input":{"file_path":"%s/src/app.ts"}}' "$SID" "$T" | bash "$TI"
[ ! -e "$LOG" ] && pass "track-includes: an untracked path is skipped" || bad "track-includes: untracked path was logged"

# A JSON encoder that escapes '/' must still be tracked (the raw fast path defers to jq).
ESC_PATH=$(printf '%s' "$T/shared/includes/demo.md" | sed 's#/#\\/#g')
printf '{"session_id":"%s","tool_input":{"file_path":"%s"}}' "$SID" "$ESC_PATH" | bash "$TI"
[ -f "$LOG" ] && grep -qx 'demo:42' "$LOG" && pass "track-includes: an escaped-slash payload is still tracked" \
  || bad "track-includes: escaped-slash payload skipped by the fast path"
rm -f "$LOG"

# The session id names a /tmp file: it must not be able to leave /tmp.
printf '{"session_id":"../x-%s","tool_input":{"file_path":"%s"}}' "$SID" "$T/shared/includes/demo.md" | bash "$TI"
rc=$?
[ "$rc" -eq 0 ] && [ ! -e "/x-$SID.txt" ] && [ ! -e "/tmp/../x-$SID.txt" ] \
  && pass "track-includes: a session id with ../ is refused" || bad "track-includes: traversing session id accepted (rc=$rc)"

# A '/' alone (no '..') is refused too: it would point the append at a directory that does not
# exist, and under set -e that failed append would fail the hook.
printf '{"session_id":"nodir-%s/x","tool_input":{"file_path":"%s"}}' "$SID" "$T/shared/includes/demo.md" | bash "$TI"
rc=$?
[ "$rc" -eq 0 ] && pass "track-includes: a session id with / is refused cleanly" || bad "track-includes: '/' in session id failed the hook (rc=$rc)"

# No jq on PATH must not fail the hook under set -e.
mkdir -p "$T/nojq"; for b in bash cat sed; do ln -sf "$(command -v "$b")" "$T/nojq/$b"; done
printf '{"session_id":"%s","tool_input":{"file_path":"%s"}}' "$SID" "$T/shared/includes/demo.md" \
  | PATH="$T/nojq" "$T/nojq/bash" "$TI"; rc=$?
[ "$rc" -eq 0 ] && pass "track-includes: missing jq exits 0" || bad "track-includes: missing jq failed the hook (rc=$rc)"

# ── zuvo-heartbeat.sh — session id path guard ─────────────────────────────────────────────────
HB="$ROOT/hooks/zuvo-heartbeat.sh"
Z="$T/zh"; mkdir -p "$Z"
printf '{"session_id":"../escape","tool_input":{"command":"ls"}}' | ZUVO_HOME="$Z" bash "$HB"
[ ! -e "$Z/escape.beat" ] && pass "heartbeat: a session id with ../ writes nothing" || bad "heartbeat: ../ session id escaped heartbeats/"
printf '{"session_id":"abc.def:1","tool_input":{"command":"ls"}}' | ZUVO_HOME="$Z" bash "$HB"
[ -f "$Z/heartbeats/abc.def:1.beat" ] && pass "heartbeat: an id with . and : still beats" || bad "heartbeat: harmless id refused"

# ── run-hook.cmd — directory resolution ───────────────────────────────────────────────────────
H="$T/hooksdir"; mkdir -p "$H"
cp "$ROOT/hooks/run-hook.cmd" "$H/run-hook.cmd"
printf '#!/usr/bin/env bash\necho "ran:$1"\n' > "$H/probe.sh"
out=$(bash "$H/run-hook.cmd" probe.sh A 2>&1)
[ "$out" = "ran:A" ] && pass "run-hook.cmd: absolute \$0 dispatches with args" || bad "run-hook.cmd absolute: [$out]"
out=$(cd "$T" && bash hooksdir/run-hook.cmd probe.sh B 2>&1)
[ "$out" = "ran:B" ] && pass "run-hook.cmd: relative \$0 dispatches" || bad "run-hook.cmd relative: [$out]"
out=$(cd "$H" && bash run-hook.cmd probe.sh C 2>&1)
[ "$out" = "ran:C" ] && pass "run-hook.cmd: bare \$0 in its own dir dispatches" || bad "run-hook.cmd bare: [$out]"

# ── pre-push-gate.sh — PreToolUse fast path ───────────────────────────────────────────────────
# A non-push command must be decided WITHOUT sourcing the library: prove it by breaking the library.
G="$T/gate"; mkdir -p "$G/lib"
cp "$ROOT/hooks/pre-push-gate.sh" "$G/pre-push-gate.sh"
printf 'echo SOURCED >&2; exit 7\n' > "$G/lib/pipeline-gate-lib.sh"
out=$(printf '{"tool_input":{"command":"ls -la"}}' | ZUVO_AGENT=1 bash "$G/pre-push-gate.sh" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && pass "pre-push: a non-push PreToolUse call never sources the library" \
  || bad "pre-push: non-push call reached the library (rc=$rc out=[$out])"
out=$(printf '  \n{"tool_input":{"command":"ls -la"}}' | ZUVO_AGENT=1 bash "$G/pre-push-gate.sh" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && pass "pre-push: leading whitespace does not defeat the fast path" \
  || bad "pre-push: whitespace-led non-push call reached the library (rc=$rc out=[$out])"
out=$(printf '  \n{"tool_input":{"command":"git push origin x"}}' | ZUVO_AGENT=1 bash "$G/pre-push-gate.sh" 2>&1); rc=$?
case "$out" in *SOURCED*) pass "pre-push: a push (after leading whitespace) still takes the full path" ;;
  *) bad "pre-push: push command skipped the library (rc=$rc out=[$out])" ;; esac
out=$(printf '{"tool_input":{"command":"gh pr create -t x"}}' | ZUVO_AGENT=1 bash "$G/pre-push-gate.sh" 2>&1)
case "$out" in *SOURCED*) pass "pre-push: gh pr create takes the full path" ;; *) bad "pre-push: gh pr create skipped" ;; esac

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "SOME FAILED"; exit 1
