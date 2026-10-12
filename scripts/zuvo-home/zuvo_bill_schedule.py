"""`bill --install-schedule`: a tick every 10 minutes — launchd on macOS, a systemd user timer on Linux."""

from __future__ import annotations

import os
import subprocess
import sys
from xml.sax.saxutils import escape

import zuvo_bill_config as C

API = 1


def install_schedule() -> int:
    me = os.path.join(C.home(), "bill")
    bd = C.bill_data()
    path = os.environ.get("PATH", "/usr/bin:/bin")
    unit_path = path.replace("\\", "\\\\").replace('"', '\\"')   # systemd: quoted, so escape \ and "
    os.makedirs(bd, exist_ok=True)
    if sys.platform == "darwin":
        plist = os.path.expanduser("~/Library/LaunchAgents/com.zuvo.bill.plist")
        with open(plist, "w") as f:
            f.write(f"""<?xml version="1.0" encoding="UTF-8"?>
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
        subprocess.run(["launchctl", "unload", plist], capture_output=True)
        r = subprocess.run(["launchctl", "load", plist], capture_output=True, text=True)
        print(f"launchd com.zuvo.bill every 600 s ({plist}) rc={r.returncode} {r.stderr.strip()}")
    else:
        ud = os.path.expanduser("~/.config/systemd/user"); os.makedirs(ud, exist_ok=True)
        with open(os.path.join(ud, "zuvo-bill.service"), "w") as f:
            f.write(f"[Unit]\nDescription=zuvo Bill — judge adversarial findings\n\n[Service]\nType=oneshot\n"
                    f"Environment=\"PATH={unit_path}\"\nExecStart=\"{me}\"\n"
                    f"StandardOutput=append:{bd}/tick.log\nStandardError=append:{bd}/tick.log\n")
        with open(os.path.join(ud, "zuvo-bill.timer"), "w") as f:
            f.write("[Unit]\nDescription=zuvo Bill every 10 minutes\n\n[Timer]\nOnBootSec=5min\n"
                    "OnUnitInactiveSec=10min\n"
                    "Persistent=true\n\n[Install]\nWantedBy=timers.target\n")
        subprocess.run(["systemctl", "--user", "daemon-reload"])
        r = subprocess.run(["systemctl", "--user", "enable", "--now", "zuvo-bill.timer"],
                           capture_output=True, text=True)
        print(f"systemd user timer zuvo-bill.timer rc={r.returncode} {r.stderr.strip()}")
    return 0
