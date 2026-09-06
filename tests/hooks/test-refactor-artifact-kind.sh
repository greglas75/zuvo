#!/usr/bin/env bash
# Exercise all contract consumers and both harness detectors without inherited agent markers.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/hooks/lib/refactor-gate-lib.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/contracts"
fails=0
check_rc() {
  local expected="$1" label="$2" rc=0; shift 2
  "$@" >"$TMP/output" 2>&1 || rc=$?
  if [ "$rc" -eq "$expected" ]; then
    echo "PASS: $label"
  else
    echo "FAIL: $label (expected $expected, got $rc)"
    cat "$TMP/output"
    fails=$((fails+1))
  fi
}
for marker in CODEX_THREAD_ID CODEX_SESSION_ID; do
  for spec in 'sh refactor-gate-lib.sh _is_agent_env' 'bash pipeline-gate-lib.sh pg_is_agent_env'; do
    read -r shell lib detector <<< "$spec"
    check_rc 0 "$lib recognizes $marker alone" env -i PATH="$PATH" "$marker=probe" \
      "$shell" -c '. "$1"; "$2"' _ "$ROOT/hooks/lib/$lib" "$detector"
    check_rc 1 "$lib keeps human detection" env -i PATH="$PATH" \
      "$shell" -c '. "$1"; "$2"' _ "$ROOT/hooks/lib/$lib" "$detector"
  done
done
cat > "$TMP/contract" <<'JSON'
{"version":4,"file":"src/a.ts","stage":"PHASE-3","scope_fence":["src/a.ts"],"prove":{"blind_audit":"not_run","adversarial":"not_run","test_quality":"not_run","split_coverage":"not_run"}}
JSON
for spec in 'refactor_gate_check src/a.ts' 'refactor_prove_v4_check src/a.ts' 'refactor_scope_gate_check src/elsewhere.ts'; do
  read -r gate file <<< "$spec"
  for suffix in findings adversarial; do
    sidecar="$TMP/contracts/refactor-aaaaaaaa-$suffix.json"
    # Even object-shaped metadata is not a contract, including nested contract copies.
    cp "$TMP/contract" "$sidecar"
    check_rc 0 "$gate ignores $suffix sidecar" env -i PATH="$PATH" ZUVO_AI_RUN=1 \
      ZUVO_GATE_MODE=pre-push ZUVO_CONTRACTS_DIR="$TMP/contracts" sh -c '. "$1"; "$2" "$3"' _ "$LIB" "$gate" "$file"
    rm "$sidecar"
  done
  printf '[%s]\n' "$(cat "$TMP/contract")" > "$TMP/contracts/refactor-aaaaaaaa.json"
  check_rc 0 "$gate ignores an array ledger" env -i PATH="$PATH" ZUVO_AI_RUN=1 \
    ZUVO_GATE_MODE=pre-push ZUVO_CONTRACTS_DIR="$TMP/contracts" sh -c '. "$1"; "$2" "$3"' _ "$LIB" "$gate" "$file"
  printf "\357\273\277[%s]\n" "$(cat "$TMP/contract")" > "$TMP/contracts/refactor-aaaaaaaa.json"
  check_rc 0 "$gate ignores a BOM-prefixed array ledger" env -i PATH="$PATH" ZUVO_AI_RUN=1 \
    ZUVO_GATE_MODE=pre-push ZUVO_CONTRACTS_DIR="$TMP/contracts" \
    sh -c '. "$1"; "$2" "$3"' _ "$LIB" "$gate" "$file"
  for marker in CODEX_THREAD_ID CODEX_SESSION_ID; do
    cp "$TMP/contract" "$TMP/contracts/refactor-aaaaaaaa.json"
    check_rc 1 "$gate still blocks a real incomplete contract under $marker" \
      env -i PATH="$PATH" "$marker=probe" ZUVO_GATE_MODE=pre-push ZUVO_CONTRACTS_DIR="$TMP/contracts" \
      sh -c '. "$1"; "$2" "$3"' _ "$LIB" "$gate" "$file"
  done
  rm "$TMP/contracts/refactor-aaaaaaaa.json"
  printf "\357\273\277%s\n" "$(cat "$TMP/contract")" > "$TMP/contracts/refactor-legacy.json"
  check_rc 1 "$gate preserves legacy ids and BOM-prefixed contracts" env -i PATH="$PATH" ZUVO_AI_RUN=1 \
    ZUVO_GATE_MODE=pre-push ZUVO_CONTRACTS_DIR="$TMP/contracts" \
    sh -c '. "$1"; "$2" "$3"' _ "$LIB" "$gate" "$file"
  rm "$TMP/contracts/refactor-legacy.json"
done
[ "$fails" -eq 0 ] || { echo "SOME FAILED: $fails"; exit 1; }
echo 'ALL PASS'
