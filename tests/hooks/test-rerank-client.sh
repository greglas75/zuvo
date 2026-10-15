#!/usr/bin/env bash
# Keep the stdlib spec of the shared rerank client (scripts/zuvo-home/zuvo_rerank.py, its cache and
# zuvo_bm25.py) in the shell test battery — run-all globs test-*.sh only. Every case runs against the
# local stub in tests/lib/rerank_stub.py; none reaches the paid API. Exit status is unittest's.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SPEC=tests/hooks/test_rerank_client.py
[ -f "$SPEC" ] || { echo "FAIL: rerank client spec missing: $SPEC" >&2; exit 1; }
python3 -m unittest -v "$SPEC"
