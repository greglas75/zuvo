"""The one rerank client the zuvo helpers share: OpenRouter POST /rerank, cached, budgeted, never fatal.

    scores = rerank("voyageai/rerank-2.5", query, docs, caller="knowledge-prime")
    # scores[i] is the relevance of docs[i], or None — and None always means "keep today's behaviour"

None covers every failure, and nothing raises to the caller: the body runs inside one guard that turns
any unexpected exception into None and the outcome `error`.

EGRESS AND ITS CONTROLS (all read at call time)
  ZUVO_RERANK=0             no request at all (outcome `disabled`)
  ZUVO_RERANK_BASE_URL      default https://openrouter.ai/api/v1. Deliberately NOT ZUVO_OPENROUTER_BASE_URL:
                            the BytePlus lane reuses that one, and following it would send this key elsewhere.
                            The key goes only to https://openrouter.ai or loopback (rio.url_problem).
  key                       see zuvo_rerank_io.key: env, then a mode-600/400 file, refused when unsafe.
  ZUVO_RERANK_MAX_CALLS     400 requests per process. Each request reserves its slot under a lock before it
                            is sent, so concurrent callers can never exceed it — this is the hard bound.
  ZUVO_RERANK_BUDGET_USD    0.25 per process, summed from usage.cost after each response. It is checked
                            before a request but not reserved, so calls already in flight can overshoot it
                            by their own cost; the call cap bounds that, and spend when cost is absent.

TELEMETRY  ${ZUVO_HOME:-$HOME/.zuvo}/rerank.log, one TSV line per call (zuvo_rerank_io.log):
  ts  caller  model  n_docs  latency_ms  cost  outcome
  outcome: ok | cached | disabled | no-key | bad-url | insecure-url | foreign-host | budget | timeout |
           http-NNN | bad-json | bad-shape | error
  The key never reaches the log, argv, a redirect target or an exception message.
"""

from __future__ import annotations

import contextlib
import json
import math
import os
import threading
import time
from typing import Any

import zuvo_rerank_cache as cache
import zuvo_rerank_http as rhttp
import zuvo_rerank_io as rio

DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"
DEFAULT_BUDGET_USD = 0.25
DEFAULT_MAX_CALLS = 400


class _Meter:
    """Per-process spend: dollars from usage.cost, and requests started."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.spent = 0.0
        self.calls = 0


_METER = _Meter()


def reset_budget() -> None:
    """Start a fresh per-process budget (what a new process gets); for tests and long-lived callers."""
    global _METER
    _METER = _Meter()


def available() -> str | None:
    """The refusal rerank() logs when nothing is cached: "disabled", "no-key", or None to go on.

    Budget, call-cap and URL refusals are per call and stay inside rerank(); None is not a promise to send.
    """
    if os.environ.get("ZUVO_RERANK") == "0":
        return "disabled"
    return "no-key" if rio.key() is None else None


def _reserve() -> bool:
    budget = rio.env_num("ZUVO_RERANK_BUDGET_USD", DEFAULT_BUDGET_USD)
    cap = rio.env_num("ZUVO_RERANK_MAX_CALLS", DEFAULT_MAX_CALLS)
    with _METER.lock:
        if _METER.spent >= budget or _METER.calls >= cap:
            return False
        _METER.calls += 1
        return True


def _finite(x: Any) -> float | None:
    """x as a float when it is a real, finite JSON number (bool, NaN, Infinity and 10**400 are not)."""
    if isinstance(x, bool) or not isinstance(x, (int, float)):
        return None
    try:
        return float(x) if math.isfinite(x) else None
    except OverflowError:
        return None


def _parse(raw: bytes, n: int) -> tuple[list[float] | None, float | None, str]:
    try:
        data: Any = json.loads(raw)
    except (ValueError, RecursionError):
        return None, None, "bad-json"
    usage = data.get("usage") if isinstance(data, dict) else None
    cost = _finite(usage.get("cost")) if isinstance(usage, dict) else None
    cost = cost if cost is not None and cost >= 0 else None  # read first: a malformed answer is still billed
    results = data.get("results") if isinstance(data, dict) else None
    if not isinstance(results, list) or len(results) != n:
        return None, cost, "bad-shape"
    scores: list[float | None] = [None] * n
    for r in results:
        i = r.get("index") if isinstance(r, dict) else None
        s = _finite(r.get("relevance_score")) if isinstance(r, dict) else None
        if not isinstance(i, int) or isinstance(i, bool) or not 0 <= i < n:
            return None, cost, "bad-shape"
        if scores[i] is not None or s is None:  # a duplicate index, or a NaN / missing score
            return None, cost, "bad-shape"
        scores[i] = s
    return [s or 0.0 for s in scores], cost, "ok"


def _rerank(model: str, query: str, docs: list[str], timeout: float, caller: str, t0: float
            ) -> list[float] | None:
    n = len(docs)
    if os.environ.get("ZUVO_RERANK") == "0":
        rio.log(caller, model, n, t0, None, "disabled")
        return None
    if not docs:
        return []
    base = (os.environ.get("ZUVO_RERANK_BASE_URL") or DEFAULT_BASE_URL).rstrip("/")
    k = cache.key(model, query, docs, base=base)
    hit = cache.get(k, n)
    if hit is not None:
        rio.log(caller, model, n, t0, 0.0, "cached")
        return hit
    api_key = rio.key()
    refused = "no-key" if api_key is None else rio.url_problem(base)
    if refused is None and not _reserve():
        refused = "budget"
    if refused is not None or api_key is None:
        rio.log(caller, model, n, t0, None, refused or "no-key")
        return None
    body = json.dumps({"model": model, "query": query, "documents": docs}).encode()
    raw, outcome = rhttp.post(f"{base}/rerank", api_key, body, timeout)
    scores, cost = None, None
    if raw is not None:
        scores, cost, outcome = _parse(raw, n)
    if cost is not None:
        with _METER.lock:
            _METER.spent += cost
    rio.log(caller, model, n, t0, cost, outcome)
    if scores is not None:
        cache.put(k, scores)
    return scores


def rerank(model: str, query: str, docs: list[str], *, timeout: float = 5.0,
           caller: str) -> list[float] | None:
    """Relevance of each doc to `query`, in input order, or None (today's behaviour) on any failure."""
    t0 = time.monotonic()
    try:
        return _rerank(model, query, docs, timeout, caller, t0)
    except Exception:  # the contract is "never fatal": an unforeseen failure is today's behaviour, logged
        with contextlib.suppress(Exception):  # the failure may have been the log itself
            rio.log(caller, model, len(docs) if isinstance(docs, list) else 0, t0, None, "error")
        return None
