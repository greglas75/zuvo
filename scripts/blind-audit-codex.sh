#!/usr/bin/env bash

set -euo pipefail

PROTOCOL_FILE=""
PRODUCTION_FILE=""
TEST_FILE=""
MODEL="${ZUVO_CODEX_MODEL:-}"

usage() {
  cat <<'EOF'
Usage: blind-audit-codex.sh --protocol <blind-coverage-audit.md> --production <file> --test <file> [--model <model>]

Runs a strict blind coverage audit in an ephemeral Codex subprocess.
Success requires a non-empty final message containing:
  - Audit mode: strict
  - Coverage verdict:
  - INVENTORY COMPLETE:
  - the required inventory table header
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --protocol)
      PROTOCOL_FILE="${2:-}"
      shift 2
      ;;
    --production)
      PRODUCTION_FILE="${2:-}"
      shift 2
      ;;
    --test)
      TEST_FILE="${2:-}"
      shift 2
      ;;
    --model)
      MODEL="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for required in "$PROTOCOL_FILE" "$PRODUCTION_FILE" "$TEST_FILE"; do
  if [[ -z "$required" ]]; then
    echo "Missing required arguments." >&2
    usage >&2
    exit 2
  fi
done

for path in "$PROTOCOL_FILE" "$PRODUCTION_FILE" "$TEST_FILE"; do
  if [[ ! -f "$path" ]]; then
    echo "Missing file: $path" >&2
    exit 2
  fi
done

if ! command -v codex >/dev/null 2>&1; then
  echo "codex command not found" >&2
  exit 2
fi

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/zuvo-blind-audit.XXXXXX")"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

cp "$PROTOCOL_FILE" "$tmpdir/blind-coverage-audit.md"
cp "$PRODUCTION_FILE" "$tmpdir/$(basename "$PRODUCTION_FILE")"
cp "$TEST_FILE" "$tmpdir/$(basename "$TEST_FILE")"

cat > "$tmpdir/prompt.txt" <<EOF
Read only these files:
- blind-coverage-audit.md
- $(basename "$PRODUCTION_FILE")
- $(basename "$TEST_FILE")

Follow blind-coverage-audit.md exactly.
Do not use repo tools, CodeSift, or any prior conversation context.
Return only the required strict output block.
EOF

codex_args=(
  exec
  --ephemeral
  --color never
  -s read-only
  --skip-git-repo-check
  -C "$tmpdir"
  -o "$tmpdir/out.txt"
  -
)

if [[ -n "$MODEL" ]]; then
  codex_args+=( -m "$MODEL" )
fi

if ! codex "${codex_args[@]}" < "$tmpdir/prompt.txt" > "$tmpdir/stdout.txt" 2> "$tmpdir/stderr.txt"; then
  cat "$tmpdir/stderr.txt" >&2
  exit 1
fi

if [[ ! -s "$tmpdir/out.txt" ]]; then
  echo "blind-audit-codex: missing out.txt or empty final message" >&2
  cat "$tmpdir/stdout.txt" >&2 || true
  exit 1
fi

if ! grep -q 'Audit mode: strict' "$tmpdir/out.txt"; then
  echo "blind-audit-codex: strict audit marker missing" >&2
  cat "$tmpdir/out.txt" >&2
  exit 1
fi

if ! grep -q 'Coverage verdict:' "$tmpdir/out.txt"; then
  echo "blind-audit-codex: coverage verdict missing" >&2
  cat "$tmpdir/out.txt" >&2
  exit 1
fi

if ! grep -q 'INVENTORY COMPLETE:' "$tmpdir/out.txt"; then
  echo "blind-audit-codex: inventory summary missing" >&2
  cat "$tmpdir/out.txt" >&2
  exit 1
fi

if ! grep -q '| id | kind | production lines | owned_or_delegated | coverage | test evidence | notes |' "$tmpdir/out.txt"; then
  echo "blind-audit-codex: required inventory table header missing" >&2
  cat "$tmpdir/out.txt" >&2
  exit 1
fi

cat "$tmpdir/out.txt"
