"""A local stand-in for OpenRouter's POST /rerank, so no test suite ever calls the paid API.

    with RerankStub(scores={"cache": 0.9}) as stub:
        os.environ["ZUVO_RERANK_BASE_URL"] = stub.base_url
        ...
        stub.requests, stub.bodies, stub.auth

A real ThreadingHTTPServer on 127.0.0.1:0 in a daemon thread — not mock.patch — because the CLI suites
run the helpers as subprocesses. Scores come from the first `scores` substring found in a document (0.0
otherwise) and results are returned sorted by score, as the live API does, so a client that reads them in
input order fails. Modes that replace the answer:
  status/body   a well-formed HTTP response with this status and body
  raw           these exact bytes on the socket, then close (bad status lines, short bodies)
  trickle       the body one byte per `trickle` seconds (a total-deadline test)
  trickle_headers  the WHOLE response, status line and headers too, one byte per this many seconds
  redirect      302 to this URL
`delays` holds a sleep per query substring (`delay` for every query); `hold_until` holds the answer to a
query containing a key until its threading.Event is set (60 s at most); `cost=None` drops `usage.cost`.
Any GET (a followed redirect) is recorded too. Tests clear HTTP(S)_PROXY and set NO_PROXY.
"""

from __future__ import annotations

import contextlib
import http.server
import json
import threading
import time
from typing import Any


class RerankStub:
    def __init__(self, scores: dict[str, float] | None = None, *, status: int = 200,
                 body: bytes | None = None, raw: bytes | None = None, trickle: float = 0.0,
                 trickle_headers: float = 0.0, redirect: str | None = None, delay: float = 0.0,
                 delays: dict[str, float] | None = None,
                 hold_until: dict[str, threading.Event] | None = None,
                 cost: float | None = 0.001) -> None:
        self.scores = dict(scores or {})
        self.status, self.body, self.cost = status, body, cost
        self.raw, self.trickle, self.redirect = raw, trickle, redirect
        self.trickle_headers = trickle_headers
        self.delay, self.delays = delay, dict(delays or {})
        self.hold_until = dict(hold_until or {})
        self.bodies: list[dict[str, Any]] = []
        self.auth: list[str] = []
        self._lock = threading.Lock()
        self._server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self._server.daemon_threads = True
        self._thread = threading.Thread(target=self._server.serve_forever, kwargs={"poll_interval": 0.05},
                                        daemon=True)

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self._server.server_address[1]}/api/v1"

    @property
    def requests(self) -> int:
        with self._lock:
            return len(self.bodies)

    def start(self) -> RerankStub:
        self._thread.start()
        return self

    def stop(self) -> None:
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=5)

    def __enter__(self) -> RerankStub:
        return self.start()

    def __exit__(self, *exc: object) -> None:
        self.stop()

    def _answer(self, req: dict[str, Any]) -> tuple[int, bytes]:
        if self.body is not None:
            return self.status, self.body
        docs = req.get("documents") or []
        scored = [{"index": i, "relevance_score": next((s for k, s in self.scores.items() if k in d), 0.0)}
                  for i, d in enumerate(docs)]
        scored.sort(key=lambda r: -r["relevance_score"])
        out: dict[str, Any] = {"results": scored}
        if self.cost is not None:
            out["usage"] = {"cost": self.cost}
        return self.status, json.dumps(out).encode()

    def _handler(self) -> type[http.server.BaseHTTPRequestHandler]:
        stub = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def _record(self, req: dict[str, Any]) -> None:
                with stub._lock:
                    stub.bodies.append(req)
                    stub.auth.append(self.headers.get("Authorization", ""))

            def do_GET(self) -> None:
                self._record({})
                self.send_error(405)

            def do_POST(self) -> None:
                raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                try:
                    req = json.loads(raw)
                except ValueError:
                    req = {}
                self._record(req)
                query = str(req.get("query", ""))
                time.sleep(next((d for k, d in stub.delays.items() if k in query), stub.delay))
                for k, event in stub.hold_until.items():
                    if k in query:
                        event.wait(60)
                with contextlib.suppress(OSError):  # the client already gave up (a timeout test)
                    self._send(req)

            def _send(self, req: dict[str, Any]) -> None:
                self.close_connection = True
                code, body = stub._answer(req)
                out = stub.raw if stub.raw is not None else (
                    f"HTTP/1.1 302 Found\r\nLocation: {stub.redirect}\r\nContent-Length: 0\r\n\r\n".encode()
                    if stub.redirect is not None else
                    f"HTTP/1.1 {code} X\r\nContent-Length: {len(body)}\r\n\r\n".encode() + body)
                pace = stub.trickle_headers or stub.trickle
                split = 0 if stub.trickle_headers else (out.find(b"\r\n\r\n") + 4 if pace else len(out))
                self.wfile.write(out[:split])
                for i in range(split, len(out)):  # paced bytes; empty unless a trickle mode is set
                    self.wfile.write(out[i:i + 1])
                    self.wfile.flush()
                    time.sleep(pace)

            def log_message(self, *args: Any) -> None:
                pass

        return Handler
