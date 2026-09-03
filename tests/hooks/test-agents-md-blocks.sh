#!/usr/bin/env bash
# The rules Codex reads from AGENTS.md must come from this repo, and must not carry an attempt cap.
#
# Both blocks were hand-injected into ~/.codex/AGENTS.md with no source here. That is how a
# drafting error survived unreviewed: the no-local-fallback block said "Re-queue once, or report
# BLOCKED_FARM_BUSY with the run id and stop". On 2026-09-03 an agent read that as a two-attempt
# budget, hit a farm at capacity, and abandoned a finished branch — no push, no PR, no merge —
# for a run the client would have QUEUED. `rt` re-places up to TF_REPLACE_MAX times and then
# queues; it never hands back a bare refusal, and no part of the fleet emits BLOCKED_FARM_BUSY.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/shared/codex/agents-md"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

for b in poll-economy no-local-fallback; do
  if [ -s "$SRC/$b.md" ]; then
    pass "$b.md has a source in the repo"
  else
    bad "$b.md has no source — it exists only in the user's home and cannot be reviewed or restored"
  fi
done

# The retired wording, in the file that would reinstall it.
if grep -q 'Re-queue once' "$SRC/no-local-fallback.md" 2>/dev/null; then
  bad "the attempt cap is back — 'Re-queue once' is what produced the two-attempt reading"
else
  pass "no attempt cap in the farm-busy rule"
fi

# BLOCKED_FARM_BUSY may only appear as the thing being WARNED ABOUT, never as an instruction. The
# block quotes the retired sentence verbatim (that history is the reason the rule reads as it
# does), so a line-wise grep flags the correction itself — and the quote WRAPS, which is the other
# way a marker check silently reports the wrong answer. Read the whole file, collapse the
# whitespace, and let a phrase that is introduced as history be history.
if python3 - "$SRC/no-local-fallback.md" <<'PYEOF'
import re, sys
t = " ".join(open(sys.argv[1], errors="replace").read().split())
bad = []
for m in re.finditer(r"(report[^.]{0,40}BLOCKED_FARM_BUSY|BLOCKED_FARM_BUSY[^.]{0,40}and stop)", t, re.I):
    lead = t[max(0, m.start() - 140):m.start()]
    if not re.search(r"(earlier version|used to say|retired|do not invent|is not a status)", lead, re.I):
        bad.append(m.group(0))
sys.exit(1 if bad else 0)
PYEOF
then
  pass "BLOCKED_FARM_BUSY appears only as history, never as an outcome to report"
else
  bad "the rule still tells agents to report BLOCKED_FARM_BUSY and stop"
fi

# The positive half: waiting has to be named, or removing the cap just leaves a vacuum.
if grep -q 'QUEU' "$SRC/no-local-fallback.md" 2>/dev/null; then
  pass "the rule says the fleet queues instead of refusing"
else
  bad "nothing tells the agent what a full fleet actually does — it will invent an outcome again"
fi

if grep -q 'install-agents-md-blocks.sh' "$ROOT/scripts/install.sh"; then
  pass "install.sh installs the blocks"
else
  bad "install.sh does not install the blocks — the repo source would be decorative"
fi

# Behaviour: a deleted block comes back, the user's own text survives, and a second run is a no-op.
tmp=$(mktemp -d)
{
  printf '# My own notes\n\nSomething I wrote.\n\n'
  cat "$SRC/poll-economy.md"
  printf '\n\n## More of my notes\n\nKeep me.\n'
} > "$tmp/AGENTS.md"
bash "$ROOT/scripts/install-agents-md-blocks.sh" "$SRC" "$tmp/AGENTS.md" >/dev/null 2>&1
h1=$(shasum -a256 "$tmp/AGENTS.md" | cut -d' ' -f1)
bash "$ROOT/scripts/install-agents-md-blocks.sh" "$SRC" "$tmp/AGENTS.md" >/dev/null 2>&1
h2=$(shasum -a256 "$tmp/AGENTS.md" | cut -d' ' -f1)

grep -q 'zuvo:no-local-fallback' "$tmp/AGENTS.md" \
  && pass "a missing block is appended" || bad "a missing block was not restored"
grep -q 'Something I wrote.' "$tmp/AGENTS.md" && grep -q 'Keep me.' "$tmp/AGENTS.md" \
  && pass "the user's own text on both sides survives" || bad "the installer ate the user's text"
[ "$h1" = "$h2" ] \
  && pass "a second run changes nothing" || bad "the installer is not idempotent"
rm -rf "$tmp"

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
