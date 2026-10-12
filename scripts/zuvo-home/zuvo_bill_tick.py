"""One tick: find the reviews nobody judged, judge them in parallel, record the verdicts, settle retries.
What each file holds: zuvo_bill_state.py.
"""

from __future__ import annotations

import concurrent.futures as cf
import json
import os
import subprocess
import time
from collections.abc import Iterator
from datetime import timedelta
from typing import Any

import zuvo_bill_config as C
import zuvo_bill_state as S
from zuvo_bill_judge import Item, Row, judge
from zuvo_review_ledger import LedgerRow, latest_verdicts, project_key, read_rows

API = 2
VERDICT_TO_DISPOSITION = {"real": "deferred", "false_positive": "rejected"}
Runs = dict[str, dict[str, Any]]


class Judged:
    """The findings that carry a verdict, asked as (project, fingerprint) with `project` in any form the
    ledger writes it (/Users/…/repo, /home/…/repo, repo): the shared reader keys on the basename. A row
    without a project has no key and is judged nowhere."""

    def __init__(self, verdicts: dict[tuple[str, str], str]) -> None:
        self._keys = frozenset(verdicts)

    def __contains__(self, item: object) -> bool:
        if not isinstance(item, tuple) or len(item) != 2 or not isinstance(item[0], str):
            return False
        key = project_key(item[0])
        return key is not None and (key, item[1]) in self._keys


def read_ledger() -> tuple[Runs, Judged]:
    """(runs: run_id -> {project, ts, rows[]}, judged). Only `new` code-review rows of real lanes inside
    the age window are kept (the ledger is never rotated, and holding every row of every review ever run
    grew without bound); `judged` holds every verdict, which an all-time view needs. One streamed pass.
    Raises OSError when the ledger exists but cannot be read — never reads that as "no findings"."""
    runs: Runs = {}
    oldest = C.stamp(C.now() - timedelta(hours=C.max_age_h()))

    def verdict_rows() -> Iterator[LedgerRow]:
        for r in read_rows(C.ledger()):
            if r.is_verdict:
                yield r
            elif r.disposition == "new" and r.provider:
                if r.mode != "code" or r.provider.startswith("mock-") or r.ts < oldest:
                    continue
                run = runs.setdefault(r.run_id, {"project": r.project, "ts": r.ts, "rows": []})
                run["rows"].append({"id": r.fingerprint, "lane": r.provider, "model": r.model,
                                    "severity": r.severity, "confidence": r.confidence, "file": r.file})

    judged = Judged(latest_verdicts(verdict_rows()))
    return runs, judged


def pending(runs: Runs, judged: Judged, done: set[str]) -> list[Item]:
    oldest = C.stamp(C.now() - timedelta(hours=C.max_age_h()))
    youngest = C.stamp(C.now() - timedelta(minutes=C.min_age_m()))
    out: list[Item] = []
    for run, r in runs.items():
        if (run in done or not C.RUN_ID.fullmatch(run) or not oldest <= r["ts"] <= youngest
                or not os.path.exists(os.path.join(C.inputs_dir(), run + ".diff"))):
            continue
        open_rows = [x for x in r["rows"] if (r["project"], x["id"]) not in judged]
        if open_rows:
            out.append((r["ts"], run, r["project"], open_rows))
    out.sort(reverse=True)                  # newest first: fresh lessons, and a backlog never starves today
    return out


def record(rec: dict[str, Any], rows: list[Row]) -> dict[str, Any]:
    """Write the verdict rows through the driver (it validates the ids against this project's ledger), and
    the defects/lessons only once the ledger accepted them — a retried run must not duplicate them.
    Sets rec["recorded"]: True, False (driver refused: retry), or "project-missing" (cannot ever land)."""
    # Re-read just before writing: the agent may have recorded its own verdict during Bill's long call,
    # and Bill's row, written later, would win (latest row wins). This narrows that window to the
    # driver call; it does not close it.
    _, judged_now = read_ledger()
    lanes = {x["id"]: x["lane"] for x in rows if (rec["project"], x["id"]) not in judged_now}
    rec["agent_judged_meanwhile"] = len(rows) - len(lanes)
    args: list[str] = []
    ts, defects, covered = C.stamp(C.now()), [], set()
    for d in rec["verdicts"]["defects"]:
        ids = [i for i in d["finding_ids"] if i in lanes]
        covered.update(ids)
        defects.append({"ts": ts, "run": rec["run"], "project": rec["project"],
                        "defect_key": d.get("defect_key"),
                        "class": d.get("class"), "verdict": d.get("verdict"), "severity": d.get("severity"),
                        "reason": d.get("reason"), "lanes": sorted({lanes[i] for i in ids}),
                        "finding_ids": ids})
        disp = VERDICT_TO_DISPOSITION.get(d.get("verdict"))
        if disp:
            for i in ids:
                args += ["--record-disposition", i, disp]
    # Ids the model left out stay unjudged; re-asking would re-pay the whole review, so they are counted.
    rec["omitted"] = len(set(lanes) - covered)
    if not args:
        rec["recorded"] = True
    elif not os.path.isdir(rec["project"]):
        rec["recorded"] = "project-missing"
    else:
        env = dict(os.environ, ZUVO_RUN_ID="bill")
        r = subprocess.run([os.path.join(C.home(), "adversarial-review"), *args], cwd=rec["project"], env=env,
                           capture_output=True, text=True, timeout=120)
        rec["recorded"] = r.returncode == 0
        if r.returncode != 0:
            rec["error"] = f"record-disposition rc={r.returncode}: {r.stderr.strip()[-200:]}"
    if rec["recorded"] is not False:
        bd = C.bill_data()
        for x in defects:
            C.append(os.path.join(bd, "defects.jsonl"), json.dumps(x, ensure_ascii=False))
        for lesson in rec["verdicts"]["lessons"]:
            C.append(os.path.join(bd, "lessons.jsonl"), json.dumps(
                {"ts": ts, "run": rec["run"], "project": rec["project"], "lesson": lesson},
                ensure_ascii=False))
    return rec


def settle(rec: dict[str, Any], rows: list[Row], attempts: dict[str, int], done_f: str) -> dict[str, Any]:
    """One finished attempt: record it, decide done / retry / give up, log it. Never raises: a state file
    it cannot write is reported on stderr."""
    if rec.get("verdicts"):
        try:
            record(rec, rows)
        except Exception as ex:  # noqa: BLE001 — a driver timeout, a missing driver, an unreadable ledger: retried
            rec["recorded"], rec["error"] = False, f"record: {type(ex).__name__}: {str(ex)[:200]}"
    finished = rec.get("verdicts") and rec.get("recorded") is not False
    # A rate-limited call is the account's state, not the review's: it does not use up the run's tries.
    if not finished and not rec.get("limited"):
        attempts[rec["run"]] = attempts.get(rec["run"], 0) + 1
        if attempts[rec["run"]] >= C.max_tries():
            rec["gave_up"] = True
    # An all-"uncertain" answer is finished too: re-asking re-pays. The tries are forgotten only once
    # judged-runs.txt holds the run; while it cannot, a finished run counts as an attempt as well, so
    # the try cap still stops a run being paid for on every tick.
    if finished or rec.get("gave_up"):
        if S.persist("judged-runs.txt", lambda: C.append(done_f, rec["run"])):
            attempts.pop(rec["run"], None)
        elif finished:
            attempts[rec["run"]] = attempts.get(rec["run"], 0) + 1
    v = rec.pop("verdicts", None) or {}
    rec["defects"] = len(v.get("defects", []))
    rec["ts"] = C.stamp(C.now())
    line = json.dumps(rec, ensure_ascii=False)
    S.persist("bill.log", lambda: C.append(os.path.join(C.bill_data(), "bill.log"), line))
    print(f"bill: {rec['run']} {rec.get('secs')}s findings={rec['findings']} defects={rec['defects']} "
          f"usd={rec.get('usd')} recorded={rec.get('recorded')}{' GAVE-UP' if rec.get('gave_up') else ''} "
          f"{rec.get('error', '')}", flush=True)
    return rec


def tick(dry: bool) -> int:
    bd = C.bill_data()
    os.makedirs(bd, exist_ok=True)
    if C.paused():
        print("bill: paused (~/.zuvo/bill-data/PAUSE)"); return 0
    refused = C.acquire_lock()
    if refused:
        print(f"bill: {refused.reason}"); return 1 if refused.error else 0
    try:
        done_f = os.path.join(bd, "judged-runs.txt")
        done = S.read_done(done_f)
        try:
            runs, judged = read_ledger()
        except OSError as ex:   # one line per tick, lock released: never a traceback every 10 minutes
            print(f"bill: cannot read the ledger {C.ledger()} ({type(ex).__name__}: {ex}) — tick skipped",
                  flush=True)
            return 1
        bad = sum(not C.RUN_ID.fullmatch(r) for r in runs)
        if bad:
            print(f"bill: {bad} review(s) skipped: bad-run-id (not [A-Za-z0-9._-]+)")
        queue = pending(runs, judged, done)
        print(f"bill: {len(queue)} review(s) with unjudged findings between {C.min_age_m()} min "
              f"and {C.max_age_h()} h old")
        if dry:
            for ts, run, proj, rows in queue[:30]:
                print(f"  {ts} {run} {os.path.basename(proj)} {len(rows)} finding(s)")
            return 0
        blocked = S.unwritable()
        if blocked:
            print(f"bill: cannot write Bill's state ({blocked}) — tick skipped before any paid call",
                  flush=True)
            return 1
        _judge_queue(queue, S.load_attempts(set(runs)), done_f)
        return 0
    finally:
        C.release_lock()


def _judge_queue(queue: list[Item], attempts: dict[str, int], done_f: str) -> None:
    """Up to `workers` calls in flight until the time budget runs out (calls in flight finish); a rate or
    usage limit stops new calls for the rest of the tick."""
    workers = C.workers()
    queue = [q for q in queue if attempts.get(q[1], 0) < C.max_tries()]   # given up, not yet in judged-runs
    deadline, i = time.time() + C.budget(), 0
    futs: dict[cf.Future[tuple[dict[str, Any], list[Row]]], Item] = {}
    with cf.ThreadPoolExecutor(workers) as ex:
        while futs or i < len(queue):
            while i < len(queue) and len(futs) < workers and time.time() < deadline:
                futs[ex.submit(judge, queue[i])] = queue[i]; i += 1
            if not futs:
                break
            fin, _ = cf.wait(futs, return_when=cf.FIRST_COMPLETED)
            for f in fin:
                item = futs.pop(f)
                try:
                    rec, rows = f.result()
                except Exception as e:  # noqa: BLE001 — judge() catches the call's own errors; this is the diff read
                    rec, rows = {"run": item[1], "project": item[2], "findings": len(item[3]),
                                 "error": f"judge: {type(e).__name__}: {str(e)[:200]}"}, item[3]
                settle(rec, rows, attempts, done_f)
                S.save_attempts(attempts)
                if rec.get("limited"):
                    print("bill: rate/usage limit — stopping this tick"); deadline = 0
