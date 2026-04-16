#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--root" ]]; then
  ROOT="${2:?Usage: $0 [--root <path>]}"
else
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi

REGISTRY="$ROOT/shared/includes/banned-vocabulary/registry.tsv"
LANG_DIR="$ROOT/shared/includes/banned-vocabulary/languages"
MATCHES="$ROOT/shared/includes/banned-vocabulary/fixtures.match.tsv"
MISSES="$ROOT/shared/includes/banned-vocabulary/fixtures.miss.tsv"
NORMALIZE="$ROOT/shared/includes/banned-vocabulary/fixtures.normalize.tsv"

python3 - "$REGISTRY" "$LANG_DIR" "$MATCHES" "$MISSES" "$NORMALIZE" <<'PY'
import sys
from pathlib import Path

registry_path = Path(sys.argv[1])
lang_dir = Path(sys.argv[2])
matches_path = Path(sys.argv[3])
misses_path = Path(sys.argv[4])
normalize_path = Path(sys.argv[5])

errors = []

for path in (registry_path, lang_dir, matches_path, misses_path, normalize_path):
    if not path.exists():
        errors.append(f"missing required path: {path}")

if errors:
    print("INVALID: banned-vocabulary fixtures", file=sys.stderr)
    for error in errors:
        print(f"- {error}", file=sys.stderr)
    sys.exit(1)

def normalize_locale(raw: str) -> str:
    token = raw.strip().replace("_", "-")
    if not token:
        return token
    base = token.split("-", 1)[0].lower()
    return base

def read_tsv(path: Path):
    rows = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        rows.append(line.split("\t"))
    return rows

registry_codes = set()
for row in read_tsv(registry_path):
    if len(row) != 5:
        errors.append(f"registry row must have 5 columns: {row}")
        continue
    registry_codes.add(row[0])

def parse_language_file(path: Path):
    hard = set()
    soft = set()
    section = None
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line == "## Hard Ban":
            section = "hard"
            continue
        if line == "## Soft Ban":
            section = "soft"
            continue
        if line.startswith("## "):
            section = None
            continue
        if line.startswith("- "):
            item = line[2:].strip()
            if section == "hard":
                hard.add(item.casefold())
            elif section == "soft":
                soft.add(item.casefold())
    return {"hard": hard, "soft": soft}

lang_data = {}
for code in registry_codes:
    lang_path = lang_dir / f"{code}.md"
    if not lang_path.exists():
        errors.append(f"language file missing for registry code: {code}")
        continue
    lang_data[code] = parse_language_file(lang_path)

coverage = {code: {"hard": 0, "soft": 0} for code in registry_codes}

for row in read_tsv(matches_path):
    if len(row) != 3:
        errors.append(f"match fixture must have 3 columns: {row}")
        continue
    raw_code, section, phrase = row
    code = normalize_locale(raw_code)
    if code not in registry_codes:
        errors.append(f"match fixture uses unsupported code: {raw_code}")
        continue
    if section not in ("hard", "soft"):
        errors.append(f"match fixture invalid section '{section}' for {raw_code}")
        continue
    if phrase.casefold() not in lang_data[code][section]:
        errors.append(f"{code}:{section} missing expected fixture phrase: {phrase}")
    else:
        coverage[code][section] += 1

for row in read_tsv(misses_path):
    if len(row) != 2:
        errors.append(f"miss fixture must have 2 columns: {row}")
        continue
    raw_code, phrase = row
    code = normalize_locale(raw_code)
    if code not in registry_codes:
        errors.append(f"miss fixture uses unsupported code: {raw_code}")
        continue
    folded = phrase.casefold()
    if folded in lang_data[code]["hard"] or folded in lang_data[code]["soft"]:
        errors.append(f"{code} unexpectedly contains negative fixture phrase: {phrase}")

for row in read_tsv(normalize_path):
    if len(row) != 2:
        errors.append(f"normalize fixture must have 2 columns: {row}")
        continue
    raw_code, expected = row
    actual = normalize_locale(raw_code)
    if actual != expected:
        errors.append(f"normalize fixture mismatch: {raw_code} -> {actual}, expected {expected}")

for code, counts in sorted(coverage.items()):
    if counts["hard"] < 1:
        errors.append(f"{code} missing hard-ban positive fixture coverage")
    if counts["soft"] < 1:
        errors.append(f"{code} missing soft-ban positive fixture coverage")

if errors:
    print("INVALID: banned-vocabulary fixtures", file=sys.stderr)
    for error in errors:
        print(f"- {error}", file=sys.stderr)
    sys.exit(1)

print(
    f"PASS: banned-vocabulary fixtures ({len(registry_codes)} languages, "
    f"{sum(1 for _ in read_tsv(matches_path))} positive fixtures, "
    f"{sum(1 for _ in read_tsv(misses_path))} negative fixtures, "
    f"{sum(1 for _ in read_tsv(normalize_path))} normalization fixtures)"
)
PY
