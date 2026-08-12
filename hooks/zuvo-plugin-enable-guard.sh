#!/usr/bin/env bash
# SessionStart hook — re-assert that the zuvo plugin is enabled, ONCE per install.
#
# Why this exists. `dev-push.sh` runs `claude plugin enable` and it succeeds; the release
# log even prints "✓ Plugin enabled". But a Claude Code that was RUNNING through the
# release owns ~/.claude/settings.json and can persist its own older view afterwards,
# undoing the CLI's write. Measured 2026-08-12: a release reported success and the plugin
# was DISABLED in both scopes on the next start, with all 57 skills invisible. Nothing
# detected it — the user did, by noticing the skills were gone.
#
# Why it must be GLOBAL (~/.claude/hooks, registered directly in settings.json) and not a
# plugin hook: a plugin-scoped hook does not run while its own plugin is disabled, which is
# exactly the state it would need to fix. A guard that cannot run in the failure it guards
# against is decoration.
#
# Why it heals at most ONCE per install assertion: a hook that re-enables unconditionally
# would override `claude plugin disable` forever and there would be no way to turn zuvo off
# short of deleting this file. So: the installer stamps `asserted_at`; this heals that one
# stamp and records it. Disable it a second time and the disable STICKS — the guard reports
# and stands down. One clobber gets fixed; a decision gets respected.
#
# Never fails a session: every path exits 0.
set -u

KEY="zuvo@zuvo-marketplace"
SETTINGS="$HOME/.claude/settings.json"
STATE="$HOME/.zuvo/plugin-enable-state"
LOG="$HOME/.zuvo/plugin-enable-guard.log"
OPTOUT="$HOME/.zuvo/no-auto-enable"

# Hard opt-out, documented in the log line below — `touch ~/.zuvo/no-auto-enable`.
[ -f "$OPTOUT" ] && exit 0
[ -f "$SETTINGS" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

python3 - "$SETTINGS" "$STATE" "$LOG" "$KEY" <<'PY' 2>/dev/null || true
import json, os, sys, time

settings_path, state_path, log_path, key = sys.argv[1:5]

def log(msg):
    try:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        with open(log_path, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')}\t{msg}\n")
    except Exception:
        pass

# The plugin must actually be installed; nothing to assert otherwise.
inst = os.path.expanduser("~/.claude/plugins/installed_plugins.json")
try:
    with open(inst) as f:
        installed = json.load(f)
    if not any("zuvo" in n.lower() for n in installed.get("plugins", {})):
        sys.exit(0)
except Exception:
    sys.exit(0)

try:
    with open(settings_path) as f:
        s = json.load(f)
except Exception as e:
    log(f"skip\tsettings unreadable ({e})")
    sys.exit(0)

current = s.get("enabledPlugins", {}).get(key)
if current is True:
    sys.exit(0)                      # healthy, say nothing

# Read the installer's stamp and what we last healed.
st = {}
try:
    with open(state_path) as f:
        for line in f:
            k, _, v = line.strip().partition("=")
            if k:
                st[k] = v
except Exception:
    pass

asserted = st.get("asserted_at", "")
healed   = st.get("healed_for", "")

if not asserted:
    # No installer ever claimed this should be on — do not invent intent.
    log(f"stand-down\t{key}={current!r} but no install assertion on record")
    sys.exit(0)

if healed == asserted:
    # We already fixed this install's assertion once and it came back off.
    # That is a decision, not a clobber. Respect it.
    log(f"stand-down\t{key}={current!r} already healed once for assertion {asserted} — treating as intentional")
    sys.exit(0)

s.setdefault("enabledPlugins", {})[key] = True
tmp = settings_path + ".zuvo-tmp"
try:
    with open(tmp, "w") as f:
        json.dump(s, f, indent=2)
        f.write("\n")
    os.replace(tmp, settings_path)          # atomic; never a half-written settings.json
except Exception as e:
    try: os.unlink(tmp)
    except Exception: pass
    log(f"failed\tcould not write settings ({e})")
    sys.exit(0)

try:
    os.makedirs(os.path.dirname(state_path), exist_ok=True)
    with open(state_path, "w") as f:
        f.write(f"asserted_at={asserted}\nhealed_for={asserted}\n")
except Exception:
    pass

log(f"healed\t{key} was {current!r} -> True (assertion {asserted}); disable it again to make it stick, or touch ~/.zuvo/no-auto-enable")
print(f"[zuvo] plugin was disabled ({current!r}) — re-enabled. Restart Claude Code for skills to load. "
      f"To keep it off: run `claude plugin disable {key}` again (the second one sticks).")
PY

exit 0
