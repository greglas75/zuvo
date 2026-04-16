#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--root" ]]; then
  ROOT="${2:?Usage: $0 [--root <path>]}"
else
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi

LOADER="$ROOT/shared/includes/banned-vocabulary.md"
CORE="$ROOT/shared/includes/banned-vocabulary/core.md"
REGISTRY="$ROOT/shared/includes/banned-vocabulary/registry.tsv"
LANG_DIR="$ROOT/shared/includes/banned-vocabulary/languages"

python3 - "$LOADER" "$CORE" "$REGISTRY" "$LANG_DIR" <<'PY'
import re
import sys
from pathlib import Path

loader_path = Path(sys.argv[1])
core_path = Path(sys.argv[2])
registry_path = Path(sys.argv[3])
lang_dir = Path(sys.argv[4])

errors = []

for path in (loader_path, core_path, registry_path, lang_dir):
    if not path.exists():
        errors.append(f"missing required path: {path}")

if errors:
    print("INVALID: banned-vocabulary contract", file=sys.stderr)
    for error in errors:
        print(f"- {error}", file=sys.stderr)
    sys.exit(1)

registry = {}
for raw_line in registry_path.read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split("\t")
    if len(parts) != 5:
        errors.append(f"registry row must have 5 columns: {raw_line}")
        continue
    code, name, tier, min_hard, min_soft = parts
    if code in registry:
        errors.append(f"duplicate registry code: {code}")
        continue
    registry[code] = {
        "name": name,
        "tier": tier,
        "min_hard": int(min_hard),
        "min_soft": int(min_soft),
    }

loader_text = loader_path.read_text(encoding="utf-8")
core_text = core_path.read_text(encoding="utf-8")

loader_codes = set(re.findall(r"`([a-z]{2})`", loader_text.split("## Supported Language Files", 1)[-1]))
registry_codes = set(registry)
dir_codes = {p.stem for p in lang_dir.glob("*.md")}

if loader_codes != registry_codes:
    errors.append(
        f"loader supported-code set mismatch: loader={sorted(loader_codes)} registry={sorted(registry_codes)}"
    )

if dir_codes != registry_codes:
    errors.append(
        f"language-dir code set mismatch: dir={sorted(dir_codes)} registry={sorted(registry_codes)}"
    )

coverage_match = re.search(r"currently cover (\d+) languages", core_text)
if not coverage_match:
    errors.append("core.md missing language coverage count")
else:
    declared = int(coverage_match.group(1))
    if declared != len(registry):
        errors.append(f"core.md declares {declared} languages, registry has {len(registry)}")

def parse_language_file(path: Path):
    lines = path.read_text(encoding="utf-8").splitlines()
    title_ok = bool(lines and lines[0].startswith("# Banned Vocabulary"))
    hard = []
    soft = []
    mode = None
    for line in lines:
        if line.strip() == "## Hard Ban":
            mode = "hard"
            continue
        if line.strip() == "## Soft Ban":
            mode = "soft"
            continue
        if line.startswith("## "):
            mode = None
            continue
        if line.startswith("- "):
            item = line[2:].strip()
            if mode == "hard":
                hard.append(item)
            elif mode == "soft":
                soft.append(item)
    return title_ok, hard, soft

for code, meta in sorted(registry.items()):
    path = lang_dir / f"{code}.md"
    title_ok, hard_items, soft_items = parse_language_file(path)
    if not title_ok:
        errors.append(f"{code}: missing or malformed title")
    if not hard_items:
        errors.append(f"{code}: missing hard-ban items")
    if not soft_items:
        errors.append(f"{code}: missing soft-ban items")
    if len(hard_items) < meta["min_hard"]:
        errors.append(
            f"{code}: hard-ban count {len(hard_items)} < required {meta['min_hard']} ({meta['tier']})"
        )
    if len(soft_items) < meta["min_soft"]:
        errors.append(
            f"{code}: soft-ban count {len(soft_items)} < required {meta['min_soft']} ({meta['tier']})"
        )

    norm_hard = {}
    for item in hard_items:
        key = item.casefold().strip()
        norm_hard.setdefault(key, []).append(item)
    dup_hard = [vals[0] for vals in norm_hard.values() if len(vals) > 1]
    if dup_hard:
        errors.append(f"{code}: duplicate hard-ban items: {dup_hard}")

    norm_soft = {}
    for item in soft_items:
        key = item.casefold().strip()
        norm_soft.setdefault(key, []).append(item)
    dup_soft = [vals[0] for vals in norm_soft.values() if len(vals) > 1]
    if dup_soft:
        errors.append(f"{code}: duplicate soft-ban items: {dup_soft}")

    overlap = sorted(set(norm_hard).intersection(norm_soft))
    if overlap:
        errors.append(f"{code}: items present in both hard and soft bans: {overlap}")

if errors:
    print("INVALID: banned-vocabulary contract", file=sys.stderr)
    for error in errors:
        print(f"- {error}", file=sys.stderr)
    sys.exit(1)

primary = sum(1 for meta in registry.values() if meta["tier"] == "primary")
priority = sum(1 for meta in registry.values() if meta["tier"] == "priority")
seed = sum(1 for meta in registry.values() if meta["tier"] == "seed")
print(
    f"PASS: banned-vocabulary contract ({len(registry)} languages: {primary} primary, {priority} priority, {seed} seed)"
)
PY
