#!/usr/bin/env bash
# Real dispatch/plan contract; controlled provider executables consume no vendor quota.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 "$root/tests/adversarial/packing_plan_cases.py"
