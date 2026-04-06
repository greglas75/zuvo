#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

run_test() {
  local script="$1"
  bash "$ROOT_DIR/$script"
}

run_test tests/seo-suite/test-bot-registry.sh
run_test tests/seo-suite/test-page-profiles.sh
run_test tests/seo-suite/test-check-registry.sh
run_test tests/seo-suite/test-fix-registry.sh
run_test tests/seo-suite/test-json-schemas.sh
run_test tests/seo-suite/test-audit-technical-contract.sh
run_test tests/seo-suite/test-audit-content-contract.sh
run_test tests/seo-suite/test-audit-assets-contract.sh
run_test tests/seo-suite/test-seo-audit-skill-contract.sh
run_test tests/seo-suite/test-seo-fix-skill-contract.sh
run_test tests/seo-suite/test-validator-script.sh
run_test tests/seo-suite/test-website-seo-audit.sh
run_test tests/seo-suite/test-website-seo-fix.sh
bash "$ROOT_DIR/scripts/validate-seo-skill-contracts.sh"

echo "PASS: seo skill suite end-to-end"
