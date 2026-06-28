#!/usr/bin/env bash
# Task 5 — CI gate. Runs scripts/zuvo-pipeline-entry-ci.sh headless on a fixture
# repo. CI is FAIL-CLOSED. Asserts exit codes + that the workflow YAML is valid.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI="$ROOT/scripts/zuvo-pipeline-entry-ci.sh"
YML="$ROOT/ci/zuvo-pipeline-entry.yml"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
(
  cd "$TMP" || exit 1
  git init -q -b main 2>/dev/null || { git init -q; git symbolic-ref HEAD refs/heads/main; }
  git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
  echo base > base.txt; git add -A; git commit -qm base
) || { bad "fixture init"; echo "SOME FAILED"; exit 1; }
cd "$TMP" || exit 1
MAIN=$(git rev-parse HEAD)

git checkout -q -b feature
mkdir -p src; echo a > src/a.sh; echo b > src/b.sh; echo c > src/c.sh
git add -A; git commit -qm feat
FHEAD=$(git rev-parse HEAD)
echo tiny > src/tiny.sh; git add -A; git commit -qm tiny
SMALL=$(git rev-parse HEAD)
mkdir -p docs; for i in $(seq 1 200); do echo "l$i" >> docs/big.md; done
git add -A; git commit -qm docs
DOCS=$(git rev-parse HEAD)

ci() { PG_REPO_ROOT="$TMP" bash "$CI"; }

# (a) PR range substantial + unreviewed + no label → exit 1 (FAIL CLOSED)
ZUVO_CI_RANGE="$MAIN..$FHEAD" ci >/dev/null 2>&1
[ "$?" -eq 1 ] && pass "(a) substantial unreviewed → CI FAIL (exit 1)" || bad "(a) should fail closed"

# (c) zuvo:adhoc-approved label env → 0
ZUVO_CI_RANGE="$MAIN..$FHEAD" ZUVO_CI_LABELS="other,zuvo:adhoc-approved" ci >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "(c) adhoc-approved label → pass (exit 0)" || bad "(c) label escape should pass"

# (d) small range → 0
ZUVO_CI_RANGE="$FHEAD..$SMALL" ci >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "(d1) small range → pass (exit 0)" || bad "(d1) small should pass"
# (d) docs-only → 0
ZUVO_CI_RANGE="$SMALL..$DOCS" ci >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "(d2) docs-only range → pass (exit 0)" || bad "(d2) docs-only should pass"

# (b) reviewed range → 0
mkdir -p memory/reviews
cat > memory/reviews/cov.md <<'ART'
<!-- zuvo-review -->
range: dead..beef
files: src/a.sh, src/b.sh, src/c.sh
verdict: PASS
-->
ART
ZUVO_CI_RANGE="$MAIN..$FHEAD" ci >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "(b) reviewed range → pass (exit 0)" || bad "(b) reviewed should pass"
rm -rf memory/reviews

# PR-event range resolution (no ZUVO_CI_RANGE): merge-base(main,HEAD)..HEAD
GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main PG_REPO_ROOT="$TMP" bash "$CI" >/dev/null 2>&1
[ "$?" -eq 1 ] && pass "(e1) PR-event resolves range, unreviewed → FAIL (exit 1)" || bad "(e1) PR-event range resolution"

# fail-closed when lib missing is covered by code; here assert label parse via GITHUB_EVENT_PATH
if command -v jq >/dev/null 2>&1; then
  cat > "$TMP/event.json" <<'EJ'
{ "pull_request": { "labels": [ { "name": "bug" }, { "name": "zuvo:adhoc-approved" } ] } }
EJ
  ZUVO_CI_RANGE="$MAIN..$FHEAD" GITHUB_EVENT_PATH="$TMP/event.json" PG_REPO_ROOT="$TMP" bash "$CI" >/dev/null 2>&1
  [ "$?" -eq 0 ] && pass "(e2) adhoc label via GITHUB_EVENT_PATH → pass" || bad "(e2) event-json label parse"
else
  pass "(e2) skipped (jq absent)"
fi

# (e) workflow YAML validity
if [ -f "$YML" ]; then
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 -c "import yaml,sys; yaml.safe_load(open('$YML'))" >/dev/null 2>&1 \
      && pass "(f) workflow YAML parses (pyyaml)" || bad "(f) workflow YAML invalid (pyyaml)"
  else
    # jq-free structural check: required keys, no leading tabs, script invoked
    if ! grep -qP '^\t' "$YML" 2>/dev/null && grep -qE '^name:' "$YML" \
        && grep -qE '^on:' "$YML" && grep -qE '^jobs:' "$YML" \
        && grep -qE 'runs-on:' "$YML" && grep -qE 'fetch-depth: 0' "$YML" \
        && grep -qE 'scripts/zuvo-pipeline-entry-ci\.sh' "$YML"; then
      pass "(f) workflow YAML structurally valid (no pyyaml; structural check)"
    else
      bad "(f) workflow YAML missing required structure"
    fi
  fi
else
  bad "(f) ci/zuvo-pipeline-entry.yml missing"
fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
