#!/usr/bin/env bash
# test-verdict-recording-wiring.sh — every skill that runs adversarial-review on work it then triages tells the
# agent to record a verdict per finding (shared/includes/adversarial-loop.md Step 4.9).
#
# Without that line the agent fixes or dismisses the findings and records nothing: the findings ledger keeps
# every raise open, and precision per model has nothing to be computed from.
#
# A skill "runs the driver" when a line invokes it with a flag (the command token before `--`), as
# test-adversarial-flag-contract.sh reads invocations; the pointer must come AFTER the first invocation.
# EXEMPT skills run the driver on output they do not triage as their own work — their verdicts would skew the
# ledger with benchmark artifacts — and must still exist and still run it, or the exemption is stale.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXEMPT="benchmark agent-benchmark profile-session"
npass=0; nfail=0
check() { if [ "$2" -eq 0 ]; then echo "  PASS $1"; npass=$((npass + 1)); else echo "  FAIL $1${3:+ — $3}"; nfail=$((nfail + 1)); fi; }

# missing_pointer <skills-dir> — the skills that invoke the driver and carry no pointer after it, one per line.
missing_pointer() {
  local f d
  for f in "$1"/*/SKILL.md; do
    d="$(basename "$(dirname "$f")")"
    case " $EXEMPT " in *" $d "*) continue ;; esac
    awk '
      !inv && /(adversarial-review(\.sh)?|"\$AR") +--/ && $0 !~ /^[[:space:]]*#/ { inv = NR }
      inv && NR > inv && /Step 4\.9/ && /--record-disposition/ { ok = 1 }
      END { exit (inv && !ok) ? 0 : 1 }' "$f" && echo "$d"
  done
  return 0
}

echo "== every triaging skill points at Step 4.9 after its first adversarial-review call =="
miss="$(missing_pointer "$ROOT/skills")"
check "no skill runs the driver without the verdict-recording pointer" "$([ -z "$miss" ] && echo 0 || echo 1)" "$(echo $miss)"
n=$(grep -l 'Step 4\.9' "$ROOT"/skills/*/SKILL.md | xargs grep -l -- '--record-disposition' | wc -l | tr -d ' ')
check "premise: the pointer is present in at least 20 skills (found $n)" "$([ "$n" -ge 20 ] && echo 0 || echo 1)"

echo "== the exemptions are real =="
for d in $EXEMPT; do
  rc=1; [ -f "$ROOT/skills/$d/SKILL.md" ] && grep -q 'adversarial-review' "$ROOT/skills/$d/SKILL.md" && rc=0
  check "exempt skill '$d' exists and still mentions adversarial-review" "$rc"
done

echo "== negative control: a skill with its pointer removed is reported =="
T="$(mktemp -d "${TMPDIR:-/tmp}/verdict-wiring.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/skills/build"
grep -v 'Step 4\.9' "$ROOT/skills/build/SKILL.md" > "$T/skills/build/SKILL.md"
check "build without the pointer → reported as missing" "$([ "$(missing_pointer "$T/skills")" = build ] && echo 0 || echo 1)"
cp "$ROOT/skills/build/SKILL.md" "$T/skills/build/SKILL.md"
check "build with the pointer → not reported" "$([ -z "$(missing_pointer "$T/skills")" ] && echo 0 || echo 1)"

printf 'RESULT: PASS=%d FAIL=%d\n' "$npass" "$nfail"
[ "$nfail" -eq 0 ]
