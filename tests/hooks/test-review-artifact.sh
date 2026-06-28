#!/usr/bin/env bash
# Task 2 — assert review/build/execute each INSTRUCT writing the content-keyed
# pipeline-entry review artifact (memory/reviews/<base7>..<head7>-<slug>.md) with
# the machine-readable range:/files: header, on SUCCESSFUL completion only.
#
# These skills are markdown; the "test" is that the instruction is present and
# correctly shaped in each SKILL.md (the lib in Task 3 reads the artifact the
# instruction produces). Pure grep assertions — no runtime side effects.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

# The canonical shared include must exist and define the schema.
INC="$ROOT/shared/includes/review-artifact.md"
if [ -f "$INC" ]; then
  grep -qE 'memory/reviews/<base7>\.\.<head7>-<slug>\.md' "$INC" \
    && grep -qE '^range:' "$INC" && grep -qE '^files:' "$INC" \
    && pass "shared include defines content-keyed path + range:/files: header" \
    || bad "shared include missing path or range:/files: header"
else
  bad "shared/includes/review-artifact.md missing"
fi

for sk in review build execute; do
  f="$ROOT/skills/$sk/SKILL.md"
  if [ ! -f "$f" ]; then bad "$sk SKILL.md missing"; continue; fi

  # (1) content-keyed path AND range header tokens both present on ONE line
  #     (matches the Task verify: grep -lE 'memory/reviews/.*range:')
  if grep -qE 'memory/reviews/.*range:' "$f"; then
    pass "$sk: 'memory/reviews/...range:' anchor line present"
  else
    bad "$sk: no single line with both memory/reviews/ and range:"
  fi

  # (2) content key <base7>..<head7> present
  if grep -qE '<base7>\.\.<head7>' "$f"; then
    pass "$sk: <base7>..<head7> content key present"
  else
    bad "$sk: missing <base7>..<head7> content key"
  fi

  # (3) both range: and files: header tokens referenced
  if grep -qE 'range:' "$f" && grep -qE 'files:' "$f"; then
    pass "$sk: range:/files: header tokens referenced"
  else
    bad "$sk: missing range:/files: header tokens"
  fi

  # (4) on-success-only discipline stated (crash-safe: failed run writes nothing)
  if grep -qiE 'on success|successful completion|on-success|success only|only on success' "$f"; then
    pass "$sk: on-success-only discipline stated"
  else
    bad "$sk: missing on-success-only discipline"
  fi

  # (5) references the canonical shared include (single source of schema)
  if grep -qE 'shared/includes/review-artifact\.md' "$f"; then
    pass "$sk: references shared/includes/review-artifact.md"
  else
    bad "$sk: does not reference the canonical include"
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "SOME FAILED"
  exit 1
fi
