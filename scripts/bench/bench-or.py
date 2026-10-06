#!/usr/bin/env python3
"""bench-or.py --models SPEC [SPEC ...] [--workers N] [--timeout S] [--plan]

Runs OpenRouter models on the benchmark corpus with the SAME prompt the adversarial-review driver
builds, so the answers are comparable with the CLI lanes. Every answer is appended to
$BENCH_HOME/or/results.tsv and written to or/raw/<SAFE>-<group>-<packet>.txt the moment it
returns — a run that dies keeps everything it paid for. Re-running skips packets already done.

SPEC   model-id                       label = the id
       label=model-id                 e.g. xiaomi/mimo-v2.6-flash~r2=xiaomi/mimo-v2.6-flash
       label=model-id@effort          adds {"reasoning": {"effort": effort}}

Env:   BENCH_HOME   data dir (default ~/.zuvo/bench): sel.json, judge2/, or/, shim/
       ADV          REQUIRED — a FROZEN copy of adversarial-review.sh (runbook pitfall 1: a parallel
                    agent editing the live driver corrupts a running bash script). The live repo
                    driver and ~/.zuvo/adversarial-review are refused.
       OPENROUTER_API_KEY or ~/.zuvo/openrouter.key

--plan prints what would run (label, model, effort, packets to do) and makes no network call.
"""
import contextlib
import argparse
import collections
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

BENCH = os.path.expanduser(os.environ.get("BENCH_HOME", "~/.zuvo/bench"))
OUT = os.path.join(BENCH, "or", "results.tsv")
SUM = os.path.join(BENCH, "or", "summary.tsv")
RAW = os.path.join(BENCH, "or", "raw")
LIVE_DRIVERS = (
    os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "adversarial-review.sh")),
    os.path.realpath(os.path.expanduser("~/.zuvo/adversarial-review")),
)
SPEC = re.compile(r"^(?:(?P<label>[^=\s]+)=)?(?P<model>[A-Za-z0-9._/:-]+?)(?:@(?P<effort>[a-z]+))?$")


def parse_spec(text):
    m = SPEC.match(text.strip())
    if not m or "/" not in m.group("model"):
        raise ValueError(f"bad model spec {text!r} (want [label=]vendor/model[@effort])")
    model = m.group("model")
    effort = m.group("effort")
    label = m.group("label") or (model + (f"@{effort}" if effort else ""))
    # the label names files in or/raw/ — no path, no separators
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._@~+/-]*", label) or ".." in label or label.endswith("/"):
        raise ValueError(f"bad label {label!r}")
    extra = {"reasoning": {"effort": effort}} if effort else {}
    return label, model, extra


FINDING_LINE = re.compile(r"SEVERITY[*\s]*:|^[\s>*#_-]*\[?(?:CRITICAL|WARNING|INFO)\]?(?:[*\s:-]|$)", re.I)


def finding_count(text):
    """Lines that carry a finding — the same rule as judge.sh and evaluate-model.py."""
    return sum(1 for line in text.splitlines() if FINDING_LINE.search(line))


def frozen_driver():
    adv = os.environ.get("ADV", "").strip()
    if not adv:
        raise SystemExit("bench-or.py: set ADV to a FROZEN copy of adversarial-review.sh, with its lib/ "
                         "beside it (docs/runbook/model-benchmark.md, \"Running it\")")
    real = os.path.realpath(os.path.expanduser(adv))
    if real in LIVE_DRIVERS:
        raise SystemExit(f"bench-or.py: ADV={adv} is the LIVE driver — freeze a copy first "
                         f"(runbook pitfall 1)")
    if not os.path.isfile(real):
        raise SystemExit(f"bench-or.py: ADV={adv} does not exist")
    # The driver loads its modules from <its dir>/lib/ or <its dir>/ (scripts/lib/adversarial-*.sh): a copy
    # frozen without them exits 2 before it builds a prompt. --help exits 0 only after every module loaded.
    res = subprocess.run(["bash", real, "--help"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.PIPE, check=False)
    if res.returncode != 0:
        tail = res.stderr.decode(errors="ignore").strip().splitlines()[-3:]
        raise SystemExit(f"bench-or.py: ADV={adv} cannot run — freeze it together with its lib/ "
                         f"(docs/runbook/model-benchmark.md, \"Running it\"):\n  " + "\n  ".join(tail))
    shim = os.path.join(BENCH, "shim", "agy")
    if not os.access(shim, os.X_OK):
        raise SystemExit(f"bench-or.py: {shim} missing or not executable — it captures the driver's prompt")
    return real


def inputs():
    """(group, packet id, diff path) for every corpus packet in sel.json order."""
    with open(os.path.join(BENCH, "sel.json")) as fh:
        sel = json.load(fh)
    out = []
    for grp in ("ok", "fail"):
        for r in sel.get(grp, []):
            path = os.path.expanduser(r["diff"])
            base = os.path.basename(path)
            # sel.json may name the rotated input (<id>.diff) or the corpus file (judge2/<id>/CODE.diff)
            pid = (os.path.basename(os.path.dirname(path)) if base == "CODE.diff"
                   else re.sub(r"\.diff$", "", base))
            diff = path if os.path.exists(path) else os.path.join(BENCH, "judge2", pid, "CODE.diff")
            if not os.path.exists(diff):
                raise SystemExit(f"bench-or.py: packet {pid}: neither {path} "
                                 f"nor judge2/{pid}/CODE.diff exists")
            out.append((grp, pid, diff))
    return out


def done_keys():
    """(label, group, packet) already answered. A timeout is a result too; an error is not."""
    done = set()
    if not os.path.exists(OUT):
        return done
    with open(OUT, errors="ignore") as fh:
        for line in fh:
            f = line.rstrip("\n").split("\t")
            if len(f) < 8:
                continue
            try:
                timed_out = f[4].startswith("err") and float(f[7] or 0) >= TIMEOUT - 5
            except ValueError:
                timed_out = False
            if f[4] == "ok" or timed_out:          # a malformed or failed row is NOT done
                done.add((f[0], f[1], f[2]))
    return done


def prompt_for(diff, adv):
    sink = os.path.join(BENCH, "or", f".prompt-{os.getpid()}-{threading.get_ident()}.txt")
    env = dict(os.environ, AGY_PROMPT_SINK=sink,
               PATH=os.path.join(BENCH, "shim") + os.pathsep + os.environ["PATH"])
    with open(diff, "rb") as fh:
        res = subprocess.run(["bash", adv, "--provider", "agy", "--mode", "code"], stdin=fh,
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env, check=False)
    try:
        with open(sink, encoding="utf-8", errors="ignore") as fh:
            text = fh.read()
    finally:
        if os.path.exists(sink):
            os.remove(sink)
    if not text.strip():
        tail = res.stderr.decode(errors="ignore").strip().splitlines()[-5:]
        raise SystemExit(f"bench-or.py: the driver produced no prompt for {diff} (exit {res.returncode}):\n  "
                         + "\n  ".join(tail))
    return text


def api_key():
    k = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if k.startswith("sk-or-"):
        return k
    path = os.path.expanduser("~/.zuvo/openrouter.key")
    if os.path.exists(path):
        with open(path) as fh:
            k = fh.read().strip()
        if k.startswith("sk-or-"):
            return k
    raise SystemExit("bench-or.py: no OpenRouter key (OPENROUTER_API_KEY or ~/.zuvo/openrouter.key)")


def once(key, model, prompt, extra):
    body = {"model": model, "messages": [{"role": "user", "content": prompt}]}
    body.update(extra)
    req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions",
                                 data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {key}",
                                          "Content-Type": "application/json",
                                          "X-Title": "zuvo-adversarial-bench"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            d = json.loads(r.read(), strict=False)
        txt = (d.get("choices") or [{}])[0].get("message", {}).get("content") or ""
        u = d.get("usage") or {}
        rt = (u.get("completion_tokens_details") or {}).get("reasoning_tokens") or 0
        return ("ok", txt, time.time() - t0, u.get("prompt_tokens", 0) or 0,
                u.get("completion_tokens", 0) or 0, rt)
    except Exception as e:  # noqa: BLE001 — every failure is recorded as a row, never raised
        detail = str(e)
        if isinstance(e, urllib.error.HTTPError):
            with contextlib.suppress(Exception):   # a body that cannot be read keeps str(e)
                detail = f"HTTP {e.code}: {e.read()[:300].decode(errors='ignore')}"
        return f"err:{type(e).__name__}", detail[:300], time.time() - t0, 0, 0, 0


def call(key, model, prompt, extra):
    """One answer. Retried: 429/5xx, connection drops, and an EMPTY answer with ZERO usage — the
    provider never ran it (2026-10-04: mercury and fugu-max). NOT retried: a timeout, which is the
    model's own result; retrying it cost ~1 h per call for nex-n2.5-pro."""
    last = None
    for attempt in range(4):
        r = once(key, model, prompt, extra)
        st, txt, dt, pt, ct, _ = r
        if st == "ok" and not txt.strip() and pt == 0 and ct == 0:
            last = ("err:empty-zero-usage", "provider returned an empty answer with no token usage",
                    dt, 0, 0, 0)
        elif st == "ok":
            return r
        else:
            if dt >= TIMEOUT - 5:
                return (st, txt, dt, 0, 0, 0)
            transient = ("429" in txt or re.search(r"HTTP 5\d\d", txt) or "Connection" in st or "Reset" in st
                         or "Incomplete" in st or "RemoteDisconnected" in st or "URLError" in st)
            if not transient:
                return r
            last = r
        time.sleep(min(45, 5 * 2 ** attempt))
    return last


def findings(text):
    if not text.strip():
        return 0, "empty"
    n = finding_count(text)
    if n == 0 and re.search(r"^\s*NO ISSUES FOUND", text, re.I | re.M):
        return 0, "clean"
    return n, ("parsed" if n else "unparsed")


def rewrite_summary():
    latest = {}                         # a retried packet counts once: its LAST row
    with open(OUT, errors="ignore") as fh:
        for line in fh:
            f = line.rstrip("\n").split("\t")
            if len(f) >= 11:
                latest[(f[0], f[1], f[2])] = f
    per = collections.defaultdict(list)
    for (label, _, _), f in latest.items():
        per[label].append(f)
    rows = []
    for label, v in per.items():
        ok = [x for x in v if x[4] == "ok"]
        if not ok:
            rows.append((0.0, label, len(v), 0, 0, 0, 0.0, 0.0))
            continue
        fnd = sum(int(x[6]) for x in ok)
        rows.append((fnd / len(ok), label, len(v), len(ok), sum(1 for x in ok if x[5] == "clean"), fnd,
                     sum(float(x[7]) for x in v) / len(v), sum(int(x[10] or 0) for x in ok) / len(ok)))
    tmp = f"{SUM}.{os.getpid()}.tmp"
    with open(tmp, "w") as w:
        w.write("model\ttrials\tok\tclean\tfindings\tfind_per_ok\tavg_sec\tavg_reasoning_tok\n")
        for r in sorted(rows, reverse=True):
            w.write(f"{r[1]}\t{r[2]}\t{r[3]}\t{r[4]}\t{r[5]}\t{r[0]:.2f}\t{r[6]:.0f}\t{r[7]:.0f}\n")
    os.replace(tmp, SUM)


def main(argv):
    global TIMEOUT
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--models", nargs="+", required=True)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--plan", action="store_true")
    a = ap.parse_args(argv)
    if a.workers < 1 or a.timeout < 60:
        ap.error("--workers >= 1 and --timeout >= 60")
    TIMEOUT = a.timeout
    try:
        specs = [parse_spec(s) for s in a.models]
    except ValueError as e:
        ap.error(str(e))
    labels = [s[0] for s in specs]
    if len(set(labels)) != len(labels):
        ap.error("duplicate labels — give each run its own label (label=model)")
    adv = frozen_driver()
    todo_inputs = inputs()
    done = done_keys()
    jobs = [((label, model, extra), grp, pid, diff) for (grp, pid, diff) in todo_inputs
            for (label, model, extra) in specs if (label, grp, pid) not in done]
    if a.plan:
        for label, model, extra in specs:
            n = sum(1 for j in jobs if j[0][0] == label)
            eff = extra.get("reasoning", {}).get("effort", "-")
            print(f"{label}\t{model}\teffort={eff}\tto-do={n}/{len(todo_inputs)}")
        print(f"driver: {adv}")
        return 0
    key = api_key()
    os.makedirs(RAW, exist_ok=True)
    prompts = {pid: prompt_for(diff, adv) for (_, _, pid, diff) in {(None, None, j[2], j[3]) for j in jobs}}
    print(f"do zrobienia: {len(jobs)} (z {len(specs) * len(todo_inputs)})", flush=True)
    lock = threading.Lock()
    answered = collections.Counter()      # ok answers written by THIS run, per label

    def work(job):
        (label, model, extra), grp, pid, _ = job
        st, txt, dt, pt, ct, rt = call(key, model, prompts[pid], extra)
        n, shape = findings(txt) if st == "ok" else (0, "unparsed")
        with lock:
            # the answer first, then the row that marks the packet done
            raw_path = os.path.join(RAW, f"{label.replace('/', '_')}-{grp}-{pid}.txt")
            with open(raw_path, "w", encoding="utf-8") as w:
                w.write(txt)
                w.flush()
                os.fsync(w.fileno())
            if st == "ok":
                answered[label] += 1
            with open(OUT, "a") as w:
                w.write(f"{label}\t{grp}\t{pid}\t{len(prompts[pid])}\t{st}\t{shape}\t{n}\t{dt:.0f}\t{pt}\t{ct}\t{rt}\n")
                w.flush()
                os.fsync(w.fileno())
            rewrite_summary()
            print(f"{label:34}{grp:5}{pid:20}{st:22}{shape:9}f={n:<3}{dt:5.0f}s", flush=True)

    with concurrent.futures.ThreadPoolExecutor(max_workers=a.workers) as ex:
        list(ex.map(work, jobs))
    rewrite_summary()
    print("ALL DONE", flush=True)
    # a model that answered nothing in THIS run is not a finished benchmark (earlier rows do not count)
    dead = [label for (label, _, _) in specs if any(j[0][0] == label for j in jobs) and answered[label] == 0]
    if dead:
        print(f"bench-or.py: no answer at all from: {', '.join(dead)}", file=sys.stderr)
        return 4
    return 0


TIMEOUT = 900

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
