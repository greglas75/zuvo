#!/usr/bin/env bash
# A release can report "✓ Plugin enabled" and leave the plugin DISABLED. `claude plugin
# enable` writes ~/.claude/settings.json; a Claude Code running through the release owns
# that file and can persist its own older view afterwards. Measured 2026-08-12: release
# said success, next start had zuvo disabled in BOTH scopes, all 57 skills invisible, and
# nothing detected it — the user did, by noticing the skills were gone.
#
# The guard is a GLOBAL SessionStart hook (a plugin-scoped hook cannot run while its own
# plugin is off — the state it exists to fix). It heals ONE install assertion, once, so a
# clobber is repaired but a deliberate `claude plugin disable` still sticks on the retry.
# These cases pin both halves; the second half is the one that keeps this from becoming a
# hook that nobody can turn off.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/hooks/zuvo-plugin-enable-guard.sh"
KEY="zuvo@zuvo-marketplace"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

[ -f "$GUARD" ] || { bad "hooks/zuvo-plugin-enable-guard.sh missing"; echo "SOME FAILED"; exit 1; }
command -v python3 >/dev/null 2>&1 || { pass "python3 unavailable — guard is a no-op here (skipped)"; echo "=== RESULT ==="; echo "ALL PASS"; exit 0; }

H="$(mktemp -d)"; trap 'rm -rf "$H"' EXIT
mkdir -p "$H/.claude/plugins" "$H/.zuvo"

set_state() {   # $1 = enabledPlugins value literal (True/False/absent)
  if [ "$1" = "absent" ]; then
    python3 -c "import json;json.dump({'enabledPlugins':{}},open('$H/.claude/settings.json','w'))"
  else
    python3 -c "import json;json.dump({'enabledPlugins':{'$KEY':$1}},open('$H/.claude/settings.json','w'))"
  fi
  python3 -c "import json;json.dump({'plugins':{'$KEY':[{'installPath':'/x','version':'1'}]}},open('$H/.claude/plugins/installed_plugins.json','w'))"
}
stamp() { printf 'asserted_at=%s\nhealed_for=%s\n' "$1" "${2:-}" > "$H/.zuvo/plugin-enable-state"; }
val()   { python3 -c "import json;print(json.load(open('$H/.claude/settings.json')).get('enabledPlugins',{}).get('$KEY'))"; }
run()   { HOME="$H" bash "$GUARD" >/dev/null 2>&1; }

# 1. The clobber: key removed entirely, install asserted -> heal.
set_state absent; stamp 111; run
[ "$(val)" = "True" ] && pass "a missing key after an install assertion is healed" \
                      || bad  "did not heal a missing key (got $(val)) — the clobber case is unfixed"

# 2. The clobber, other shape: explicit False, install asserted -> heal once.
set_state False; stamp 222; run
[ "$(val)" = "True" ] && pass "an unexpected False after an install assertion is healed once" \
                      || bad  "did not heal False (got $(val))"

# 3. THE SAFETY HALF: the user disables again -> it must STICK.
set_state False; run
[ "$(val)" = "False" ] && pass "a second disable sticks — the guard stands down, it does not fight" \
                       || bad  "re-enabled after a deliberate second disable (got $(val)) — zuvo cannot be turned off"

# 4. Hard opt-out.
: > "$H/.zuvo/no-auto-enable"; set_state False; stamp 333; run
[ "$(val)" = "False" ] && pass "~/.zuvo/no-auto-enable disables the guard entirely" \
                       || bad  "opt-out ignored (got $(val))"
rm -f "$H/.zuvo/no-auto-enable"

# 5. No install ever asserted -> do not invent intent.
set_state False; rm -f "$H/.zuvo/plugin-enable-state"; run
[ "$(val)" = "False" ] && pass "with no install assertion on record it leaves the value alone" \
                       || bad  "enabled a plugin no install asked for (got $(val))"

# 6. Healthy: silent, and settings.json must not be rewritten at all.
set_state True; stamp 444
before="$(python3 -c "import hashlib;print(hashlib.md5(open('$H/.claude/settings.json','rb').read()).hexdigest())")"
out="$(HOME="$H" bash "$GUARD" 2>/dev/null)"
after="$(python3 -c "import hashlib;print(hashlib.md5(open('$H/.claude/settings.json','rb').read()).hexdigest())")"
[ -z "$out" ] && [ "$before" = "$after" ] \
  && pass "healthy state: no output, settings.json byte-identical" \
  || bad  "touched settings.json or printed on a healthy state (out='$out')"

# 7. Not installed at all -> no-op (never resurrect a plugin the user removed).
set_state False; stamp 555
python3 -c "import json;json.dump({'plugins':{}},open('$H/.claude/plugins/installed_plugins.json','w'))"
run
[ "$(val)" = "False" ] && pass "does nothing when zuvo is not installed" \
                       || bad  "enabled a plugin that is not installed (got $(val))"

# 8. A malformed settings.json must not break the session or be overwritten.
printf 'not json{' > "$H/.claude/settings.json"
HOME="$H" bash "$GUARD" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "exits 0 on malformed settings.json (a hook must never break a session)" \
                || bad  "exited $rc on malformed settings.json"
grep -q 'not json{' "$H/.claude/settings.json" \
  && pass "malformed settings.json left untouched, not clobbered" \
  || bad  "overwrote a malformed settings.json"

# 9. Source guard: registration must stay SessionStart and GLOBAL.
if grep -q "SessionStart" "$ROOT/scripts/install.sh" && grep -q "zuvo-plugin-enable-guard" "$ROOT/scripts/install.sh"; then
  pass "install.sh registers the guard on SessionStart"
else
  bad "install.sh no longer installs/registers the enable-guard — nothing re-asserts after a release"
fi

echo "=== RESULT ==="
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
