#!/usr/bin/env python3
"""audit-registry-integrity.py — mechanical referential checks across zuvo's registries.

Catches the class of defect the test suite structurally cannot see: an ID that one registry
references and another never defines. Every finding here was a REAL defect at some point:

  * 11 probe_template_ids referenced by the pentest finding map with no definition (2026-08-01)
  * `header_injection` / `token_compare_bypass` used by 8 safe-pattern rows, never defined
  * 4 geo fix types with full templates that no check could ever emit (~140 dead lines)

Usage:
    python3 scripts/audit-registry-integrity.py            # human output
    python3 scripts/audit-registry-integrity.py --strict   # exit 1 on any finding (CI/runbook)

Exit: 0 clean (or findings without --strict) | 1 findings in --strict | 2 a registry is missing.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INC = ROOT / "shared" / "includes"

# fix types that are deliberately manual-escalation only (no check emits them, by design).
# Keep this list SHORT and justified — it is an allowlist against a real check.
KNOWN_MANUAL_FIX_TYPES = {
    "seo": {"noindex-change", "redirect-add"},
}


def read(path: Path) -> str:
    if not path.is_file():
        print(f"ERROR: missing registry: {path.relative_to(ROOT)}", file=sys.stderr)
        raise SystemExit(2)
    return path.read_text(encoding="utf-8")


def check_pentest() -> list[str]:
    """Probe templates, finding types and safe patterns must all resolve against each other."""
    reg = read(INC / "pentest-finding-registry.md")
    sp = read(INC / "pentest-safe-pattern-registry.md")

    referenced = set(re.findall(r"\| `(probe-[a-z0-9-]+)` \|", reg))
    defined = set(re.findall(r"^### `(probe-[a-z0-9-]+)`", reg, re.M))
    finding_types = set(re.findall(r"^\| `([a-z_]+)` \| `PT", reg, re.M))

    used_types: set[str] = set()
    for row in re.findall(r"^\| `SP-[^|]+\|[^|]*\|[^|]*\|([^|]*)\|", sp, re.M):
        used_types |= {t.strip(" `") for t in row.split(",") if t.strip()}

    findings = []
    for label, missing in (
        ("probe templates referenced but never defined", referenced - defined),
        ("probe templates defined but never referenced", defined - referenced),
        ("finding_types used by safe patterns but not in the finding registry", used_types - finding_types),
    ):
        if missing:
            findings.append(f"pentest: {label}: {sorted(missing)}")
    return findings


def check_check_fix_pairs() -> list[str]:
    """Every fix type must be emittable by at least one check row (or be a known manual escalation)."""
    findings = []
    for family in ("seo", "geo", "content"):
        chk = read(INC / f"{family}-check-registry.md")
        fix = read(INC / f"{family}-fix-registry.md")

        # a check row's fix_type lives in its LAST cell; a cell may offer several variants
        # ("`a` (site) / `b` (article)") — count every token in it as emittable.
        emitted: set[str] = set()
        for line in chk.splitlines():
            if not line.startswith("|"):
                continue
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) < 3:
                continue
            emitted |= set(re.findall(r"`([a-z][a-z0-9-]*)`", cells[-1]))

        declared = set(re.findall(r"^\|\s*`([a-z][a-z0-9-]*)`\s*\|", fix, re.M))
        unreachable = declared - emitted - KNOWN_MANUAL_FIX_TYPES.get(family, set())
        if unreachable:
            findings.append(
                f"{family}: fix types no check can emit (dead remediation logic): {sorted(unreachable)}"
            )
    return findings


def check_severity_rows() -> list[str]:
    """Skills that cite severity-vocabulary must have a row in it."""
    vocab = read(INC / "severity-vocabulary.md")
    findings = []
    for skill in ("pentest", "geo-audit", "content-audit", "write-e2e"):
        if f"`/{skill}`" not in vocab:
            findings.append(f"severity-vocabulary: no mapping row for /{skill} (cited elsewhere)")
    return findings


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--strict", action="store_true", help="exit 1 when any finding is reported")
    args = ap.parse_args()

    findings = check_pentest() + check_check_fix_pairs() + check_severity_rows()

    if not findings:
        print("registry-integrity: OK (probes, finding types, safe patterns, check/fix pairs, severity rows)")
        return 0

    print(f"registry-integrity: {len(findings)} finding(s)")
    for f in findings:
        print(f"  - {f}")
    return 1 if args.strict else 0


if __name__ == "__main__":
    raise SystemExit(main())
