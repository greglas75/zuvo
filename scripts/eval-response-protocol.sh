#!/bin/bash
# Snapshot-based eval for the compressed response protocol corpus.
# Counts use a deterministic token proxy so the eval stays local and dependency-light.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES_DIR="$ROOT/tests/fixtures/response-protocol"
MANIFEST="$FIXTURES_DIR/manifest.json"
SCENARIO="all"

usage() {
  cat <<'EOF'
Usage: bash scripts/eval-response-protocol.sh [--scenario <name>]

Scenarios:
  --scenario verbose-override   Evaluate only the explicit detailed-explanation sample
  --scenario readability-sheet  Print the two-rater markdown review sheet
  --scenario all                Evaluate the full fixed corpus (default)

This script compares fixed baseline/protocol snapshots. Counts are a local token proxy,
not provider-reported billing tokens.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --scenario)
      shift
      if [ "$#" -eq 0 ]; then
        echo "Missing value for --scenario" >&2
        exit 2
      fi
      SCENARIO="$1"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

python3 - "$MANIFEST" "$FIXTURES_DIR" "$SCENARIO" <<'PY'
import json
import os
import re
import statistics
import sys
from textwrap import shorten


manifest_path, fixtures_dir, scenario = sys.argv[1:4]


def read_text(rel_path: str) -> str:
    with open(os.path.join(fixtures_dir, rel_path), encoding="utf-8") as handle:
        return handle.read().strip()


def token_proxy(text: str) -> int:
    return len(re.findall(r"\w+|[^\w\s]", text, flags=re.UNICODE))


def classify_mode(text: str) -> str:
    if re.search(r"^## [A-Z0-9 :_-]+ COMPLETE$", text, flags=re.MULTILINE):
        return "STANDARD"
    if "Detailed explanation:" in text:
        return "STANDARD"
    if re.search(r"^(fact|cause|risk|next|conf):", text, flags=re.MULTILINE):
        return "STRUCTURED_TERSE"
    if token_proxy(text) >= 85 and text.count("\n\n") >= 1:
        return "STANDARD"
    return "TERSE"


with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)

samples = manifest.get("samples", [])
if scenario == "verbose-override":
    samples = [sample for sample in samples if sample.get("scenario") == "verbose-override"]
elif scenario == "all":
    pass
elif scenario == "readability-sheet":
    pass
else:
    raise SystemExit(f"Unknown scenario: {scenario}")

if not samples:
    raise SystemExit("No samples selected")

provider = manifest.get("provider", "unknown")
model = manifest.get("model", "unknown")

if scenario == "readability-sheet":
    print("# Response Protocol Readability Sheet")
    print("")
    print(f"- Provider: {provider}")
    print(f"- Model: {model}")
    print(f"- Samples: {len(samples)}")
    print("")
    print("Passing rubric: both raters mark `clearer` or `same`, and both mark `confidence-ok=yes` plus `literals-ok=yes`.")
    print("")
    for sample in samples:
        baseline = read_text(sample["baseline"])
        protocol = read_text(sample["protocol"])
        print(f"## {sample['id']}")
        print("")
        print(f"- expected_surface: {sample['expected_surface']}")
        print(f"- expected_mode: {sample['expected_mode']}")
        print(f"- protected_literals: {', '.join(sample.get('protected_literals', []))}")
        print("")
        print("Baseline excerpt:")
        print("```text")
        print(shorten(baseline.replace("\n", " "), width=320, placeholder=" [...]"))
        print("```")
        print("")
        print("Protocol excerpt:")
        print("```text")
        print(shorten(protocol.replace("\n", " "), width=320, placeholder=" [...]"))
        print("```")
        print("")
        print("- Rater 1: clearer [ ] | same [ ] | worse [ ] | confidence-ok yes/no | literals-ok yes/no | notes:")
        print("- Rater 2: clearer [ ] | same [ ] | worse [ ] | confidence-ok yes/no | literals-ok yes/no | notes:")
        print("")
    raise SystemExit(0)

rows = []
working_reductions = []
literals_pass = 0
mode_pass = 0

for sample in samples:
    baseline = read_text(sample["baseline"])
    protocol = read_text(sample["protocol"])
    baseline_runs = [token_proxy(baseline) for _ in range(3)]
    protocol_runs = [token_proxy(protocol) for _ in range(3)]
    baseline_tokens = int(statistics.median(baseline_runs))
    protocol_tokens = int(statistics.median(protocol_runs))
    observed_mode = classify_mode(protocol)
    mode_matches = observed_mode == sample["expected_mode"]
    missing_literals = [literal for literal in sample.get("protected_literals", []) if literal not in protocol]
    literals_ok = not missing_literals
    delta_pct = 0.0
    if baseline_tokens:
        delta_pct = ((baseline_tokens - protocol_tokens) / baseline_tokens) * 100.0

    if sample["expected_mode"] in {"TERSE", "STRUCTURED_TERSE"}:
        working_reductions.append(delta_pct)

    if literals_ok:
        literals_pass += 1
    if mode_matches:
        mode_pass += 1

    rows.append(
        {
            "id": sample["id"],
            "surface": sample["expected_surface"],
            "expected_mode": sample["expected_mode"],
            "observed_mode": observed_mode,
            "baseline_tokens": baseline_tokens,
            "protocol_tokens": protocol_tokens,
            "delta_pct": delta_pct,
            "literals_ok": literals_ok,
            "missing_literals": missing_literals,
            "mode_matches": mode_matches,
        }
    )

avg_working_reduction = None
if working_reductions:
    avg_working_reduction = sum(working_reductions) / len(working_reductions)
all_literals_ok = literals_pass == len(rows)
all_modes_ok = mode_pass == len(rows)
meets_reduction_gate = True if avg_working_reduction is None else avg_working_reduction >= 25.0

print("=== Response Protocol Eval ===")
print(f"Provider metadata: {provider} / {model}")
print("Corpus mode: fixed local snapshots; median over 3 identical passes")
print("")
print("| sample | surface | expected | observed | baseline_tokens | protocol_tokens | delta_pct | literals | mode |")
print("|--------|---------|----------|----------|-----------------|-----------------|-----------|----------|------|")
for row in rows:
    literals_cell = "pass" if row["literals_ok"] else "fail"
    mode_cell = "pass" if row["mode_matches"] else "fail"
    print(
        f"| {row['id']} | {row['surface']} | {row['expected_mode']} | {row['observed_mode']} | "
        f"{row['baseline_tokens']} | {row['protocol_tokens']} | {row['delta_pct']:.1f}% | "
        f"{literals_cell} | {mode_cell} |"
    )

print("")
print("Summary:")
if avg_working_reduction is None:
    print("- working_reduction_avg: n/a (no working samples selected)")
else:
    print(f"- working_reduction_avg: {avg_working_reduction:.1f}%")
print(f"- literal_preservation: {literals_pass}/{len(rows)}")
print(f"- mode_matches: {mode_pass}/{len(rows)}")

if scenario == "verbose-override":
    print("- scenario: verbose-override")

if not meets_reduction_gate:
    print("- gate: FAIL (working reduction below 25%)")
if not all_literals_ok:
    missing = []
    for row in rows:
        if not row["literals_ok"]:
            missing.append(f"{row['id']} -> {', '.join(row['missing_literals'])}")
    print("- missing_literals:")
    for item in missing:
        print(f"  - {item}")
if not all_modes_ok:
    mismatches = [row for row in rows if not row["mode_matches"]]
    print("- mode_mismatches:")
    for row in mismatches:
        print(f"  - {row['id']}: expected {row['expected_mode']}, observed {row['observed_mode']}")

if meets_reduction_gate and all_literals_ok and all_modes_ok:
    print("PASS: fixture corpus meets v1 thresholds")
    raise SystemExit(0)

print("FAIL: fixture corpus does not meet v1 thresholds")
raise SystemExit(1)
PY
