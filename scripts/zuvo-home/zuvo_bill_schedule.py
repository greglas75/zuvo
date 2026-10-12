"""`bill --install-schedule`: a tick every 10 minutes — launchd on macOS, a systemd user timer on Linux.

Exit 0 only when the scheduler accepted the job: a refused load (its exit code, or "failed" in what
launchctl prints — it can say "Load failed" and exit 0), a failed daemon-reload or enable, or a unit file
that could not be written exits 1 with the reason on stderr, so nobody believes Bill is scheduled while
nothing will ever run it.
"""

from __future__ import annotations

import os
import subprocess
import sys
from xml.sax.saxutils import escape

import zuvo_bill_config as C

API = 2


def _run(argv: list[str]) -> subprocess.CompletedProcess[str]:
    """The command's result; a scheduler binary that is missing reads as exit 127, never a traceback."""
    try:
        return subprocess.run(argv, capture_output=True, encoding="utf-8", errors="replace", timeout=60)
    except (OSError, subprocess.TimeoutExpired) as ex:
        return subprocess.CompletedProcess(argv, 127, "", f"{type(ex).__name__}: {ex}")


def _write(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def install_schedule() -> int:
    me = os.path.join(C.home(), "bill")
    bd = C.bill_data()
    path = os.environ.get("PATH", "/usr/bin:/bin")
    unit_path = path.replace("\\", "\\\\").replace('"', '\\"')   # systemd: quoted, so escape \ and "
    try:
        os.makedirs(bd, exist_ok=True)
        return _launchd(me, bd, path) if sys.platform == "darwin" else _systemd(me, bd, unit_path)
    except OSError as ex:
        print(f"bill: schedule not installed — {type(ex).__name__}: {ex}", file=sys.stderr)
        return 1


def _launchd(me: str, bd: str, path: str) -> int:
    plist = os.path.expanduser("~/Library/LaunchAgents/com.zuvo.bill.plist")
    _write(plist, f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.zuvo.bill</string>
  <key>ProgramArguments</key><array><string>{escape(me)}</string></array>
  <key>StartInterval</key><integer>600</integer>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>{escape(path)}</string></dict>
  <key>StandardOutPath</key><string>{escape(bd)}/tick.log</string>
  <key>StandardErrorPath</key><string>{escape(bd)}/tick.log</string>
</dict></plist>
""")
    _run(["launchctl", "unload", plist])          # not loaded yet is fine
    r = _run(["launchctl", "load", plist])
    print(f"launchd com.zuvo.bill every 600 s ({plist}) rc={r.returncode} {r.stderr.strip()}")
    if r.returncode != 0 or "failed" in (r.stdout + r.stderr).lower():
        return _refused(r)
    return 0


def _systemd(me: str, bd: str, unit_path: str) -> int:
    ud = os.path.expanduser("~/.config/systemd/user")
    _write(os.path.join(ud, "zuvo-bill.service"),
           f"[Unit]\nDescription=zuvo Bill — judge adversarial findings\n\n[Service]\nType=oneshot\n"
           f"Environment=\"PATH={unit_path}\"\nExecStart=\"{me}\"\n"
           f"StandardOutput=append:{bd}/tick.log\nStandardError=append:{bd}/tick.log\n")
    _write(os.path.join(ud, "zuvo-bill.timer"),
           "[Unit]\nDescription=zuvo Bill every 10 minutes\n\n[Timer]\nOnBootSec=5min\n"
           "OnUnitInactiveSec=10min\n"
           "Persistent=true\n\n[Install]\nWantedBy=timers.target\n")
    reload = _run(["systemctl", "--user", "daemon-reload"])
    if reload.returncode != 0:   # enabling would start the units systemd has not re-read
        return _refused(reload)
    r = _run(["systemctl", "--user", "enable", "--now", "zuvo-bill.timer"])
    print(f"systemd user timer zuvo-bill.timer rc={r.returncode} {r.stderr.strip()}")
    return _refused(r) if r.returncode != 0 else 0


def _refused(p: subprocess.CompletedProcess[str]) -> int:
    said = (p.stderr or p.stdout).strip()
    print(f"bill: schedule not installed — `{' '.join(p.args)}` rc={p.returncode} {said}", file=sys.stderr)
    return 1
