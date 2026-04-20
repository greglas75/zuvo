#!/usr/bin/env bats

CONTRACT_SCRIPT="$BATS_TEST_DIRNAME/../validate-banned-vocabulary.sh"
FIXTURE_SCRIPT="$BATS_TEST_DIRNAME/../validate-banned-vocabulary-fixtures.sh"

setup() {
  TMPDIR_TEST=$(mktemp -d)
  FIXTURE_ROOT="$TMPDIR_TEST/repo"
  mkdir -p "$FIXTURE_ROOT/shared/includes" "$FIXTURE_ROOT/scripts"

  cp "$CONTRACT_SCRIPT" "$FIXTURE_ROOT/scripts/validate-banned-vocabulary.sh"
  cp "$FIXTURE_SCRIPT" "$FIXTURE_ROOT/scripts/validate-banned-vocabulary-fixtures.sh"
  chmod +x \
    "$FIXTURE_ROOT/scripts/validate-banned-vocabulary.sh" \
    "$FIXTURE_ROOT/scripts/validate-banned-vocabulary-fixtures.sh"

  cp -R "$BATS_TEST_DIRNAME/../../shared/includes/banned-vocabulary" \
    "$FIXTURE_ROOT/shared/includes/banned-vocabulary"
  cp "$BATS_TEST_DIRNAME/../../shared/includes/banned-vocabulary.md" \
    "$FIXTURE_ROOT/shared/includes/banned-vocabulary.md"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

@test "banned-vocabulary contract validator passes on repository fixtures" {
  run "$FIXTURE_ROOT/scripts/validate-banned-vocabulary.sh" --root "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: banned-vocabulary contract"* ]]

  run "$FIXTURE_ROOT/scripts/validate-banned-vocabulary-fixtures.sh" --root "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: banned-vocabulary fixtures"* ]]
}

@test "banned-vocabulary validators fail when a required phrase is removed" {
  python3 - <<'PY' "$FIXTURE_ROOT/shared/includes/banned-vocabulary/languages/en.md"
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace("- as an AI\n", "")
text = text.replace("- certainly!\n", "")
path.write_text(text, encoding="utf-8")
PY

  run "$FIXTURE_ROOT/scripts/validate-banned-vocabulary.sh" --root "$FIXTURE_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"en: hard-ban count"* ]]

  run "$FIXTURE_ROOT/scripts/validate-banned-vocabulary-fixtures.sh" --root "$FIXTURE_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"en:hard missing expected fixture phrase"* ]]
}
