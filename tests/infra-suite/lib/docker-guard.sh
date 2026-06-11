#!/usr/bin/env bash
# Sourceable SKIP guard for the infra-audit Docker fixture suite.
# Exits 0 (clean SKIP) when Docker or compose v2 is unavailable, so CI on hosts
# without Docker does not turn red. Source this near the top of every infra test.
command -v docker >/dev/null 2>&1 || { echo "SKIP: docker not available"; exit 0; }
docker compose version >/dev/null 2>&1 || { echo "SKIP: docker compose v2 required"; exit 0; }
