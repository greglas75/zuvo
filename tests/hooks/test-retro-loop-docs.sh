#!/usr/bin/env bash
# Guards docs/retro-learning-loop.md — the operating manual for retro -> mine -> digest ->
# proposals -> disposition. This loop produced three separate dead ends (output nobody read),
# and each time the reason it ran undetected for months was that nothing documented the
# contract. These assertions keep the manual honest: the commands must exist, the dead-end
# table must stay, and the engine it describes must actually be versioned.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOC="$ROOT/docs/retro-learning-loop.md"
CLAUDE="$ROOT/CLAUDE.md"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

[ -f "$DOC" ] || { bad "missing docs/retro-learning-loop.md"; echo "SOME FAILED"; exit 1; }
pass "doc exists"

# --- the loop's stages must all be named (a missing stage is how a dead end hides) ---
for s in retros.log retros.md retro-mine digest-proposals proposals-ledger.tsv; do
  grep -q -- "$s" "$DOC" && pass "documents stage artifact: $s" || bad "doc never mentions $s"
done

# --- the disposition step: the whole point. Command + every disposition value ---
grep -q -- '--mark applied' "$DOC" && pass "documents --mark applied" || bad "no --mark applied example"
for d in applied rejected covered not-ours deferred; do
  grep -q -- "\`$d\`" "$DOC" && pass "documents disposition: $d" || bad "disposition $d undocumented"
done
# the values in the doc must match the ones the tool actually accepts
DISP=$(grep -o 'DISPOSITIONS = (.*)' "$ROOT/scripts/zuvo-home/digest-proposals" || true)
for d in applied rejected covered not-ours deferred; do
  case "$DISP" in *"\"$d\""*) : ;; *) bad "doc lists '$d' but digest-proposals does not accept it" ;; esac
done
pass "documented dispositions match the tool's DISPOSITIONS tuple"

# --- the two traps that actually bit us must stay called out ---
grep -qi 'HOME-local\|not backed up by git\|NOT in git' "$DOC" \
  && pass "warns ~/.zuvo state is not versioned" || bad "missing the HOME-local data warning"
grep -qi 'install.sh overwrites\|overwrites it from the repo' "$DOC" \
  && pass "warns editing ~/.zuvo helpers is overwritten by install.sh" || bad "missing the edit-the-repo-copy warning"
grep -qi 'dead end' "$DOC" && pass "keeps the dead-ends table" || bad "dead-ends table removed"

# --- CLAUDE.md must point at it, or agents never find it ---
grep -q 'retro-learning-loop.md' "$CLAUDE" && pass "CLAUDE.md links the runbook" || bad "CLAUDE.md does not link the runbook"

# --- the engine the doc describes must be versioned (it was HOME-only until 2026-07-27) ---
for f in retro-mine.py retro-mine-weekly.sh rotate-retros-cron.sh; do
  [ -f "$ROOT/scripts/zuvo-home/$f" ] && pass "engine versioned in repo: $f" || bad "$f missing from scripts/zuvo-home"
  grep -q "$f" "$ROOT/scripts/install.sh" && pass "install.sh installs $f" || bad "install.sh does not install $f"
done

# --- scheduled jobs named in the doc must be the real LaunchAgent labels ---
grep -q 'com.greglas.zuvo-retro-mine' "$DOC" && pass "names the retro-mine LaunchAgent" || bad "schedule table lost the mine job"

# --- host-specific glue must STAY unversioned: it hardcodes an SSH host + fetches a collector
# token, so shipping it would point every installing machine at one private collector. ---
[ -f "$ROOT/scripts/zuvo-home/runlog-sync.sh" ] \
  && bad "runlog-sync.sh is host-specific (SSH host + token) and must not be versioned" \
  || pass "host-specific runlog-sync.sh stays out of the repo"
for f in "$ROOT"/scripts/zuvo-home/*; do
  grep -qE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "$f" 2>/dev/null \
    && bad "hardcoded IP in $(basename "$f")" || :
done
pass "no hardcoded IPs in versioned zuvo-home scripts"
grep -qi 'untrusted' "$DOC" && pass "documents the untrusted-digest / prompt-injection surface" \
  || bad "doc does not warn the digest is untrusted input"

echo "=== RESULT ==="; [ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
