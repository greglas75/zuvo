#!/usr/bin/env bash
# test-spec-includes.sh — Task 7+8: spec includes document new contract.

CODE_DOC="$ROOT/shared/includes/adversarial-loop.md"
DOCS_DOC="$ROOT/shared/includes/adversarial-loop-docs.md"

check_doc() {
  local label="$1" file="$2"
  start_test "$label — required terms present"
  for term in 'status: "partial"' 'single_provider_only' 'exclude-last' 'exit code 3' 'exit code 124'; do
    # Use -- to prevent grep from interpreting "--exclude-last" as a flag
    if grep -qF -- "$term" "$file"; then
      pass "$label contains: $term"
    else
      fail "$label" "missing: $term"
    fi
  done
}

check_doc "T7 adversarial-loop.md (code mode)" "$CODE_DOC"
check_doc "T8 adversarial-loop-docs.md (docs mode)" "$DOCS_DOC"
