#!/usr/bin/env bats

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/hooks/pre-commit-adversarial-gate.sh"

setup() {
  TMPDIR_TEST=$(mktemp -d)
  REPO="$TMPDIR_TEST/repo"
  mkdir -p "$REPO/.zuvo/context"

  (
    cd "$REPO"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "base" > tracked.ts
    git add tracked.ts
    git commit -qm "base"
  )

  cat > "$REPO/.zuvo/context/execution-state.md" <<'EOF'
# Execution State
<!-- status: in-progress -->
plan: docs/specs/example-plan.md
spec_id: example-spec
branch: main
total-tasks: 3

## Progress
completed: [1,2]
skipped: []
blocked: []
next-task: 3
EOF

  echo "changed" > "$REPO/tracked.ts"
  (
    cd "$REPO"
    git add tracked.ts
  )
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

run_hook() {
  run bash -lc "cd '$REPO' && printf '%s' '{\"command\":\"git commit -m test\"}' | '$SCRIPT'"
}

@test "allows non-execute commits when no execution-state exists" {
  rm -f "$REPO/.zuvo/context/execution-state.md"

  run_hook
  [ "$status" -eq 0 ]
}

@test "blocks commit when execute task has no adversarial artifact" {
  run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing adversarial artifact"* ]]
  [[ "$output" == *"adversarial-task-3.txt"* ]]
}

@test "allows commit when execute task has a fresh adversarial artifact" {
  cat > "$REPO/.zuvo/context/adversarial-task-3.txt" <<'EOF'
artifact_kind=adversarial-review
created_at=2026-04-12T10:00:00Z
mode=code
output_format=text
providers_used=gemini
provider_count=1
input_chars=10
total_findings=0
critical=0
warning=0
info=0
---
NO ISSUES FOUND
EOF

  run_hook
  [ "$status" -eq 0 ]
}

@test "blocks commit when adversarial artifact is older than staged edits" {
  cat > "$REPO/.zuvo/context/adversarial-task-3.txt" <<'EOF'
artifact_kind=adversarial-review
created_at=2026-04-12T10:00:00Z
mode=code
output_format=text
providers_used=gemini
provider_count=1
input_chars=10
total_findings=0
critical=0
warning=0
info=0
---
NO ISSUES FOUND
EOF

  sleep 1
  echo "changed again" > "$REPO/tracked.ts"
  (
    cd "$REPO"
    git add tracked.ts
  )

  run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"artifact for task 3 is stale"* ]]
}
