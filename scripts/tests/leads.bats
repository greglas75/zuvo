#!/usr/bin/env bats
# leads.bats — wraps all zuvo:leads validation scripts.
# Per plan rev3 Task 13: slow tests gated behind LEADS_SLOW=1.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT
}

@test "schema structure: lead-output-schema.md declares all 23 fields" {
  run bash "$BATS_TEST_DIRNAME/leads-schema-structure.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "source registry structure: all 9 sections present with timeouts co-located" {
  run bash "$BATS_TEST_DIRNAME/leads-source-registry-structure.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "company-finder agent structure: frontmatter + role_context passthrough" {
  run bash "$BATS_TEST_DIRNAME/leads-agent-company-finder-structure.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "contact-extractor agent structure: verbatim-source + theHarvester tmp lifecycle" {
  run bash "$BATS_TEST_DIRNAME/leads-agent-contact-extractor-structure.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "lead-validator agent structure: blind + labels-not-dedups + no Bash tool" {
  run bash "$BATS_TEST_DIRNAME/leads-agent-lead-validator-structure.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "SKILL.md orchestrator structure: all 22 structural elements (a..v)" {
  run bash "$BATS_TEST_DIRNAME/leads-skill-structure.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "zero-key smoke: fixtures present, meta-json contract, UTF-8 diacritics preserved" {
  run bash "$BATS_TEST_DIRNAME/leads-zero-key-smoke.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "catch-all detection: mock SMTP correctly classifies 3 catch-all + 3 strict domains" {
  run bash "$BATS_TEST_DIRNAME/leads-catchall-detection.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "resume resilience: SIGINT 100% + SIGKILL ≥95% + concurrent lock" {
  run bash "$BATS_TEST_DIRNAME/leads-resume-resilience.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "dedup normalization: 30 suppressed / 20 kept across 3 key types + Unicode" {
  run bash "$BATS_TEST_DIRNAME/leads-dedup-normalization.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "LLM extraction eval: verbatim gate (SU2 blocking) — zero hallucinated ground-truth emails" {
  run bash "$BATS_TEST_DIRNAME/leads-llm-extraction-eval.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VERBATIM-GATE: PASS"* ]]
}

# @slow: full LLM dispatch against 20 fixtures — gated behind LEADS_SLOW=1
@test "LLM extraction accuracy (SU1 advisory @slow)" {
  if [ "${LEADS_SLOW:-0}" != "1" ]; then
    skip "slow test — set LEADS_SLOW=1 to run full LLM accuracy eval"
  fi
  # In the @slow mode this test would dispatch the Claude contact-extractor
  # against each fixture and compute accuracy. For v1 this is covered by the
  # verbatim-gate test above; a future iteration wires the LLM dispatch here.
  run bash "$BATS_TEST_DIRNAME/leads-llm-extraction-eval.sh"
  [ "$status" -eq 0 ]
}
