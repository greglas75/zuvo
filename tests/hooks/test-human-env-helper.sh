#!/usr/bin/env bash
# tests/lib/human-env.sh builds the `env -u …` prefix that makes a test look like a HUMAN committer
# to the gates. It derives the variable list from the two detector functions themselves
# (pipeline-gate-lib.sh::pg_is_agent_env and refactor-gate-lib.sh::_is_agent_env) instead of keeping
# an allowlist — that is deliberate, and it is what stops the list drifting when a new harness is
# added.
#
# Derivation has a sharp edge, flagged CRITICAL by adversarial review: ANY uppercase token inside
# those functions becomes an `env -u`. A comment like `# must not modify PATH`, or a `$HOME`
# reference added later, would unset PATH or HOME for every subsequent test — a catastrophic and
# cryptic failure, arbitrarily far from its cause. Verified LATENT at the time (the detectors yielded
# 15 clean vendor names and nothing else), so this pins the guard before it can go live.
#
# The fix is a DENYLIST of names whose absence breaks the shell, not an allowlist of vendors: an
# allowlist would have to be edited for every new harness, which is exactly the drift the derivation
# exists to prevent.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HE="$ROOT/tests/lib/human-env.sh"
RGL="$ROOT/hooks/lib/refactor-gate-lib.sh"
TMP="$(mktemp -d)"; trap 'cp -f "$TMP/rgl.bak" "$RGL" 2>/dev/null; rm -rf "$TMP"' EXIT
fails=0
ok(){ echo "  ✓ $1"; }
bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

[ -f "$HE" ] || { bad "tests/lib/human-env.sh missing"; echo "FAILED: 1"; exit 1; }
bash -n "$HE" 2>/dev/null && ok "helper parses" || bad "helper does not parse"
cp "$RGL" "$TMP/rgl.bak"

names(){ bash -c 'source "$1" 2>/dev/null; printf "%s\n" "${HUMAN[@]}"' _ "$HE"; }
count(){ names | grep -c '^-u$'; }

BASE=$(count)
[ "$BASE" -ge 8 ] && ok "derives a real list from the detectors ($BASE variables)" \
  || bad "only $BASE variables derived — the derivation is broken, not just narrow"

# Every derived name must look like a harness variable, not an arbitrary word.
STRAY=$(names | grep -vx '\-u' | grep -vx 'env' | grep -cvE '^(ZUVO|CLAUDE|CLAUDECODE|CODEX|CURSOR|GEMINI|ANTIGRAVITY)')
[ "$STRAY" = "0" ] && ok "no derived name is outside the known harness families" \
  || bad "$STRAY derived name(s) are not harness variables"

# THE REGRESSION: a hostile-but-realistic comment inside a detector must not poison the list.
python3 - "$RGL" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old = '_is_agent_env() {'
assert old in s, 'anchor missing — re-anchor this test'
open(p, 'w', encoding='utf-8').write(
    s.replace(old, old + '\n  # must not modify PATH or HOME or TMPDIR or SHELL here', 1))
PY
LEAK=$(names | grep -cxE 'PATH|HOME|TMPDIR|SHELL|USER|LANG|PWD|IFS')
[ "$LEAK" = "0" ] && ok "a comment naming PATH/HOME/TMPDIR/SHELL does not reach \`env -u\`" \
  || bad "$LEAK shell-critical name(s) leaked into env -u — the test environment would be destroyed"
[ "$(count)" = "$BASE" ] && ok "and the harness list is unchanged ($BASE)" \
  || bad "the list changed from $BASE to $(count) — the denylist is over- or under-matching"
cp -f "$TMP/rgl.bak" "$RGL"

# The denylist must be a denylist, not a vendor allowlist: adding a NEW harness variable to a
# detector has to appear automatically, or the derivation has been defeated by its own guard.
python3 - "$RGL" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old = '_is_agent_env() {'
open(p, 'w', encoding='utf-8').write(s.replace(old, old + '\n  [ -n "${NEWHARNESS_SESSION:-}" ] && return 0', 1))
PY
names | grep -qx 'NEWHARNESS_SESSION' \
  && ok "a NEW harness variable is picked up automatically (still a denylist, not an allowlist)" \
  || bad "a new harness variable was not derived — the guard turned into an allowlist"
cp -f "$TMP/rgl.bak" "$RGL"

[ "$(count)" = "$BASE" ] && ok "restored cleanly ($BASE)" || bad "helper left in a modified state"

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $fails"; exit 1; fi
