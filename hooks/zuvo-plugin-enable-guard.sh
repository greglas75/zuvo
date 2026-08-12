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

# `set -u` + an unset $HOME made line 1 of the real work an "unbound variable" abort — exit 1
# from the one script whose header promises every path exits 0. A SessionStart hook runs in
# whatever environment the harness hands it (sandboxes, containers, service invocations), and
# $HOME is not guaranteed there. Caught by the behaviour auditor with a repro, an hour after
# this file was written, on the single line its own contract was about.
[ -n "${HOME:-}" ] || exit 0

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

# Write THROUGH a symlink, never over it. Dotfile managers (chezmoi, stow, dotbot) commonly
# make settings.json a link into their own tree; a bare os.replace() swaps the link for a
# plain file, leaving the managed target stale. The next `chezmoi apply` re-links and the old
# disabled state comes back — the fix looks like it "didn't stick" and nothing points at the
# cause. Resolve first, and keep the temp file beside the REAL file so os.replace stays atomic
# (same filesystem).
real_path = os.path.realpath(settings_path)

# Record the heal BEFORE performing it, and refuse to heal if that record cannot be written.
# Ordered the other way (settings first, state "best effort" in a bare `except: pass`), an
# unwritable ~/.zuvo means healed_for never lands, every SessionStart sees healed != asserted,
# and a deliberate `claude plugin disable` gets undone on every restart forever — the "one
# heal, then respect the decision" contract silently inverts into a hook you cannot turn off.
# Failing closed here costs at most one un-healed clobber, which `install.sh` re-stamps.
try:
    os.makedirs(os.path.dirname(state_path), exist_ok=True)
    state_tmp = f"{state_path}.tmp.{os.getpid()}"
    with open(state_tmp, "w") as f:
        f.write(f"asserted_at={asserted}\nhealed_for={asserted}\n")
    os.replace(state_tmp, state_path)
except Exception as e:
    log(f"stand-down\tcould not record the heal ({e}) — refusing to heal rather than heal forever")
    sys.exit(0)

# PID-unique temp: two sessions starting at once would otherwise open, truncate and write the
# SAME path before either renames. 600 concurrent invocations did not actually corrupt
# settings.json (identical small payload, one flush, the loser gets a caught FileNotFoundError)
# — but that is luck about buffer sizes, not a guarantee, and uniqueness is free.
tmp = f"{real_path}.zuvo-tmp.{os.getpid()}"
try:
    with open(tmp, "w") as f:
        json.dump(s, f, indent=2)
        f.write("\n")
    os.replace(tmp, real_path)              # atomic; never a half-written settings.json
except Exception as e:
    try: os.unlink(tmp)
    except Exception: pass
    log(f"failed\tcould not write settings ({e})")
    sys.exit(0)

log(f"healed\t{key} was {current!r} -> True (assertion {asserted}); disable it again to make it stick, or touch ~/.zuvo/no-auto-enable")
print(f"[zuvo] plugin was disabled ({current!r}) — re-enabled. Restart Claude Code for skills to load. "
      f"To keep it off: run `claude plugin disable {key}` again (the second one sticks).")
PY

exit 0
