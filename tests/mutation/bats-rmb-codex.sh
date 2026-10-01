#!/usr/bin/env bash
# Mutation spec: the "^Codex build" tests of scripts/tests/reviewer-model-builds.bats only (run_shell_plan.py
# runs `bash <spec>` with no arguments, so the filter lives here). The farm has no system bats.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
cd "$ROOT" || exit 2
BATS=(bats); command -v bats >/dev/null 2>&1 || BATS=(npx --yes bats@1.11.0)
exec "${BATS[@]}" -f '^Codex build' scripts/tests/reviewer-model-builds.bats
