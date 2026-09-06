#!/usr/bin/env bash
# Guard the permission/independence boundary, including policy-forbidden dispatch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
policy=(root/'shared/includes/execution-policy.md').read_text()
gate=(root/'shared/includes/test-quality-gate.md').read_text()
assert 'Session instructions and the user' in policy and 'take precedence' in policy
assert 'forbidden/unavailable' in policy
assert 'degraded:same-model' in gate and 'never strict PASS' in gate
assert 'actual test and production source' in gate
assert 'requirement as unmet' in policy
assert 'do not ask for the same permission again' in policy
assert 'execution-policy.md' in gate
assert 'substituted gate' in gate
assert 'does NOT block this' not in gate
print('PASS: policy restrictions, retained authorization, real-source audit, degraded verdict and unmet independence')
PY
