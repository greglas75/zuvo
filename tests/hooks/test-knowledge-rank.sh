#!/usr/bin/env bash
# Keep the spec of scripts/zuvo-home/knowledge-rank (knowledge-prime Steps 3 and 4) in the shell test
# battery — run-all globs test-*.sh only. Every case runs against the local stub in
# tests/lib/rerank_stub.py; none reaches the paid API. Exit status is unittest's.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SPEC=tests/hooks/test_knowledge_rank.py
[ -f "$SPEC" ] || { echo "FAIL: knowledge-rank spec missing: $SPEC" >&2; exit 1; }
python3 -m unittest -v "$SPEC"
