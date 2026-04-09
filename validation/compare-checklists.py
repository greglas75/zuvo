#!/usr/bin/env python3
"""Compare a generated test checklist against REQUIRED_INVARIANTS.

Usage:
    python compare-checklists.py <checklist_file>

Output:
    JSON to stdout with score, matched/unmatched invariants.
    Exit code 0 if score >= 0.80, exit code 1 otherwise.
"""

import json
import re
import sys
from pathlib import Path

INVARIANTS_PATH = Path(__file__).parent / "invariants" / "tgmcontest_orchestrator.json"
PASS_THRESHOLD = 0.80


def load_invariants(path: Path) -> list[dict]:
    with open(path) as f:
        return json.load(f)


def score_checklist(checklist_content: str, invariants: list[dict]) -> dict:
    matched = []
    unmatched = []

    for inv in invariants:
        if re.search(inv["pattern"], checklist_content, re.IGNORECASE | re.DOTALL):
            matched.append(inv["id"])
        else:
            unmatched.append(inv["id"])

    total = len(invariants)
    score = len(matched) / total if total > 0 else 0.0

    return {
        "total_required": total,
        "matched": len(matched),
        "unmatched": unmatched,
        "score": round(score, 4),
        "pass": score >= PASS_THRESHOLD,
    }


def main() -> int:
    if len(sys.argv) != 2:
        print(json.dumps({"error": "Usage: compare-checklists.py <checklist_file>"}))
        return 1

    checklist_path = Path(sys.argv[1])
    if not checklist_path.exists():
        print(json.dumps({"error": f"File not found: {checklist_path}"}))
        return 1

    checklist_content = checklist_path.read_text()
    invariants = load_invariants(INVARIANTS_PATH)
    result = score_checklist(checklist_content, invariants)

    print(json.dumps(result, indent=2))
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
