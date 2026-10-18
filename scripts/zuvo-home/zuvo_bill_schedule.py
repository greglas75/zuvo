"""Bill's scheduled units: `bill --install-schedule` (a tick every 10 minutes) and any other job of Bill's —
launchd on macOS, a systemd user timer on Linux — through one writer, install_unit, and its uninstall_unit.

Exit 0 only when the scheduler accepted the job: a refused load (its exit code, or "failed" in what
launchctl prints — it can say "Load failed" and exit 0), a failed daemon-reload or enable, or a unit file
that could not be written exits 1 with the reason on stderr, so nobody believes Bill is scheduled while
nothing will ever run it. A refused install takes back the files it wrote: a new one is removed (launchd
would load a left-over plist at the next login), one it overwrote gets its old text back.
"""

from __future__ import annotations

import contextlib
import os
import re
import subprocess
import sys
from typing import NamedTuple
from xml.sax.saxutils import escape

import zuvo_bill_config as C

API = 3
_DAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
LABEL = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
MIN_INTERVAL_S = 60
Written = list[tuple[str, "str | None"]]   # (unit file, its text before this install; None: it was new)


class Calendar(NamedTuple):
    """Once a week at local time: ISO weekday 1 (Monday) … 7 (Sunday), hour 0–23, minute 0–59. launchd's
    Weekday gets the number as is (its 7, like its 0, is Sunday); systemd's OnCalendar gets Mon … Sun."""
    weekday: int
    hour: int
    minute: int


def _run(argv: list[str]) -> subprocess.CompletedProcess[str]:
    """The command's result; a scheduler binary that is missing reads as exit 127, never a traceback."""
    try:
        return subprocess.run(argv, capture_output=True, encoding="utf-8", errors="replace", timeout=60)
    except (OSError, subprocess.TimeoutExpired) as ex:
        return subprocess.CompletedProcess(argv, 127, "", f"{type(ex).__name__}: {ex}")


def _write(path: str, text: str, written: Written) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        with open(path, encoding="utf-8") as f:
            before: str | None = f.read()
    except FileNotFoundError:
        before = None
    written.append((path, before))
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def install_schedule() -> int:
    try:
        return install_unit("bill", [os.path.join(C.home(), "bill")], interval_s=60,
                            description="zuvo Bill — judge adversarial findings",
                            timer_description="zuvo Bill, a minute after each tick")
    except ValueError as ex:
        print(f"bill: schedule not installed — {ex}", file=sys.stderr)
        return 1


def install_unit(label: str, argv: list[str], *, interval_s: int | None = None,
                 calendar: Calendar | None = None, description: str, timer_description: str | None = None,
                 log: str | None = None) -> int:
    """Schedule `argv` as launchd job com.zuvo.<label> / systemd units zuvo-<label>.{service,timer}, run
    every `interval_s` (≥ 60) seconds or at `calendar` — exactly one. Output goes to `log`
    (bill-data/tick.log). Raises ValueError, before writing anything, on a bad label or time: the caller
    reports it and exits 1."""
    _validate(label, interval_s, calendar)
    log = log or os.path.join(C.bill_data(), "tick.log")
    path = os.environ.get("PATH", "/usr/bin:/bin")
    written: Written = []
    stops: list[list[str]] = []    # how to stop the job once it was handed to the scheduler
    try:
        os.makedirs(os.path.dirname(log), exist_ok=True)
        if sys.platform == "darwin":
            rc = _launchd(label, argv, interval_s, calendar, path, log, written, stops)
        else:
            rc = _systemd(label, argv, interval_s, calendar, path, log, description,
                          timer_description or description, written, stops)
    except OSError as ex:
        print(f"bill: schedule not installed — {type(ex).__name__}: {ex}", file=sys.stderr)
        rc = 1
    if rc != 0:
        _take_back(written, stops)
    return rc


def _validate(label: str, interval_s: int | None, calendar: Calendar | None) -> None:
    if not LABEL.fullmatch(label):
        raise ValueError(f"install_unit: label {label!r} is not [A-Za-z0-9][A-Za-z0-9._-]*")
    if (interval_s is None) == (calendar is None):
        raise ValueError("install_unit: give exactly one of interval_s, calendar")
    if calendar is not None:
        parts = (calendar.weekday, calendar.hour, calendar.minute)
        if not (all(type(v) is int for v in parts) and 1 <= calendar.weekday <= 7
                and 0 <= calendar.hour <= 23 and 0 <= calendar.minute <= 59):
            raise ValueError(f"install_unit: {calendar} is not weekday 1-7, hour 0-23, minute 0-59")
    elif type(interval_s) is not int or interval_s < MIN_INTERVAL_S:
        raise ValueError(f"install_unit: interval_s {interval_s!r} is not an int >= {MIN_INTERVAL_S}")


def _take_back(written: Written, stops: list[list[str]]) -> None:
    """Undo a refused install: stop the job if it was handed over (a load or an enable can act before it
    reports failure), restore the files, and hand a unit file it overwrote back to the scheduler."""
    for argv in stops:
        _run(argv)
    for path, before in reversed(written):
        with contextlib.suppress(OSError):
            if before is None:
                _remove(path)
            else:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(before)
    if sys.platform == "darwin":
        for path, before in written:
            if before is not None:
                _run(["launchctl", "load", path])
    elif written:
        _run(["systemctl", "--user", "daemon-reload"])
        timers = [p for p, before in written if p.endswith(".timer") and before is not None]
        for p in timers:
            _run(["systemctl", "--user", "enable", "--now", os.path.basename(p)])


def uninstall_unit(label: str) -> int:
    """Stop and remove what install_unit(label, …) wrote; nothing installed is not an error. Exit 1 when the
    scheduler refused to stop a job that was there (its files are kept, so a retry can stop it) or a unit
    file could not be removed. Raises ValueError on a label install_unit would refuse."""
    if not LABEL.fullmatch(label):
        raise ValueError(f"uninstall_unit: label {label!r} is not [A-Za-z0-9][A-Za-z0-9._-]*")
    try:
        if sys.platform == "darwin":
            plist = _plist(label)
            if not os.path.exists(plist):
                return 0
            r = _run(["launchctl", "unload", plist])
            if r.returncode != 0 or "failed" in (r.stdout + r.stderr).lower():
                return _refused(r, "removed")
            _remove(plist)
            return 0
        files = [os.path.join(_unit_dir(), f"zuvo-{label}.{kind}") for kind in ("timer", "service")]
        if not any(os.path.exists(p) for p in files):
            return 0
        stop = _run(["systemctl", "--user", "disable", "--now", f"zuvo-{label}.timer"])
        if stop.returncode != 0:
            return _refused(stop, "removed")
        for p in files:
            _remove(p)
        reload = _run(["systemctl", "--user", "daemon-reload"])
    except OSError as ex:
        print(f"bill: schedule not removed — {type(ex).__name__}: {ex}", file=sys.stderr)
        return 1
    return _refused(reload, "removed") if reload.returncode != 0 else 0


def _remove(path: str) -> None:
    with contextlib.suppress(FileNotFoundError):
        os.remove(path)


def _plist(label: str) -> str:
    return os.path.expanduser(f"~/Library/LaunchAgents/com.zuvo.{label}.plist")


def _unit_dir() -> str:
    return os.path.expanduser("~/.config/systemd/user")


def _launchd(label: str, argv: list[str], interval_s: int | None, calendar: Calendar | None, path: str,
             log: str, written: Written, stops: list[list[str]]) -> int:
    plist = _plist(label)
    if calendar is None:
        when, said = f"<key>StartInterval</key><integer>{interval_s}</integer>", f"every {interval_s} s"
    else:
        when = ("<key>StartCalendarInterval</key><dict>"
                + "".join(f"<key>{k}</key><integer>{v}</integer>"
                          for k, v in (("Weekday", calendar.weekday), ("Hour", calendar.hour),
                                       ("Minute", calendar.minute)))
                + "</dict>")
        said = f"at {_on_calendar(calendar)}"
    args = "".join(f"<string>{escape(a)}</string>" for a in argv)
    _write(plist, f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.zuvo.{escape(label)}</string>
  <key>ProgramArguments</key><array>{args}</array>
  {when}
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>{escape(path)}</string></dict>
  <key>StandardOutPath</key><string>{escape(log)}</string>
  <key>StandardErrorPath</key><string>{escape(log)}</string>
</dict></plist>
""", written)
    _run(["launchctl", "unload", plist])          # not loaded yet is fine
    stops.append(["launchctl", "unload", plist])
    r = _run(["launchctl", "load", plist])
    print(f"launchd com.zuvo.{label} {said} ({plist}) rc={r.returncode} {r.stderr.strip()}")
    if r.returncode != 0 or "failed" in (r.stdout + r.stderr).lower():
        return _refused(r)
    return 0


def _systemd(label: str, argv: list[str], interval_s: int | None, calendar: Calendar | None, path: str,
             log: str, description: str, timer_description: str, written: Written,
             stops: list[list[str]]) -> int:
    ud, unit = _unit_dir(), f"zuvo-{label}"
    if calendar is None:
        secs = interval_s or 0                     # _validate let exactly one of the two through
        span = f"{secs // 60}min" if secs % 60 == 0 else f"{secs}s"
        when = f"OnBootSec=5min\nOnUnitInactiveSec={span}\n"
    else:
        when = f"OnCalendar={_on_calendar(calendar)}\n"
    # % starts a systemd specifier in every value written here; quoted values also escape \ and ", and
    # ExecStart expands $. append:<path> takes the rest of the line, spaces included.
    exec_start = " ".join(f'"{_quoted(a).replace("$", "$$")}"' for a in argv)
    _write(os.path.join(ud, f"{unit}.service"),
           f"[Unit]\nDescription={_pct(description)}\n\n[Service]\nType=oneshot\n"
           f"Environment=\"PATH={_quoted(path)}\"\nExecStart={exec_start}\n"
           f"StandardOutput=append:{_pct(log)}\nStandardError=append:{_pct(log)}\n", written)
    _write(os.path.join(ud, f"{unit}.timer"),
           f"[Unit]\nDescription={_pct(timer_description)}\n\n[Timer]\n{when}"
           "Persistent=true\n\n[Install]\nWantedBy=timers.target\n", written)
    reload = _run(["systemctl", "--user", "daemon-reload"])
    if reload.returncode != 0:   # enabling would start the units systemd has not re-read
        return _refused(reload)
    stops.append(["systemctl", "--user", "disable", "--now", f"{unit}.timer"])
    r = _run(["systemctl", "--user", "enable", "--now", f"{unit}.timer"])
    print(f"systemd user timer {unit}.timer rc={r.returncode} {r.stderr.strip()}")
    return _refused(r) if r.returncode != 0 else 0


def _pct(value: str) -> str:
    return value.replace("%", "%%")


def _quoted(value: str) -> str:
    return _pct(value.replace("\\", "\\\\").replace('"', '\\"'))


def _on_calendar(c: Calendar) -> str:
    return f"{_DAYS[c.weekday - 1]} *-*-* {c.hour:02d}:{c.minute:02d}:00"


def _refused(p: subprocess.CompletedProcess[str], what: str = "installed") -> int:
    said = (p.stderr or p.stdout).strip()
    print(f"bill: schedule not {what} — `{' '.join(p.args)}` rc={p.returncode} {said}", file=sys.stderr)
    return 1
