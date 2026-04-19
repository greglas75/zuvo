#!/usr/bin/env bash
# leads-skill-structure.sh
# Asserts skills/leads/SKILL.md has all 22 structural elements (a..v) from plan rev3 Task 6.
set -u
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SK="$REPO_ROOT/skills/leads/SKILL.md"
fail() { echo "FAIL: $1"; exit 1; }
[ -f "$SK" ] || fail "missing file $SK"

# (a) frontmatter
grep -Fq 'name: leads' "$SK" || fail "(a) frontmatter 'name: leads' missing"
grep -Fq 'description:' "$SK" || fail "(a) frontmatter 'description:' missing"

# (b) H1
grep -Fxq '# zuvo:leads' "$SK" || fail "(b) H1 '# zuvo:leads' missing"

# (c) Argument Parsing
grep -Eiq '## Argument Parsing|## Arguments' "$SK" || fail "(c) Argument Parsing section missing"

# (d) Mandatory File Loading — all 9 includes (7 reused + 2 new)
for inc in env-compat.md run-logger.md retrospective.md live-probe-protocol.md \
           knowledge-prime.md knowledge-curate.md adversarial-loop-docs.md \
           lead-output-schema.md lead-source-registry.md; do
  grep -Fq "$inc" "$SK" || fail "(d) include '$inc' not referenced in mandatory file loading"
done

# (e) Phase 0..7 headers
for ph in "Phase 0" "Phase 1" "Phase 2" "Phase 3" "Phase 4" "Phase 5" "Phase 6" "Phase 7"; do
  grep -Fq "$ph" "$SK" || fail "(e) '$ph' header missing"
done

# (f) Tool-probe block for required externals
for tool in dig theHarvester whois 'port 25' WebSearch WebFetch; do
  grep -Fq "$tool" "$SK" || fail "(f) tool probe for '$tool' missing"
done

# (g) Mode detection + both-flags error
grep -Eq '\-\-domains' "$SK" || fail "(g) --domains flag reference missing"
grep -Eq '\-\-industry' "$SK" || fail "(g) --industry flag reference missing"
grep -Eiq 'both.*(flags|supplied|provided)' "$SK" || fail "(g) both-flags-supplied error handling missing"

# (h) Path safety with realpath (fix for gemini-4 traversal)
grep -Eq 'realpath' "$SK" || fail "(h) realpath path safety missing"

# (i) Interactive checkpoints + AUTO-CHECKPOINT
grep -Fq 'AUTO-CHECKPOINT' "$SK" || fail "(i) AUTO-CHECKPOINT non-interactive path missing"
grep -Fq -- '--no-interactive' "$SK" || fail "(i) --no-interactive flag missing"

# (j) SMTP probe env-var override with sanitization
grep -Fq 'ZUVO_SMTP_PROBE_CMD' "$SK" || fail "(j) ZUVO_SMTP_PROBE_CMD override missing"
grep -Eiq 'absolute path.*(scripts|FIXTURE)|metacharacter' "$SK" \
  || fail "(j) SMTP override sanitization rule missing"

# (j2) bash /dev/tcp (not nc)
grep -Fq '/dev/tcp' "$SK" || fail "(j2) bash /dev/tcp SMTP method missing"

# (k) atomic lock via mkdir
grep -Fq 'mkdir .lock' "$SK" || fail "(k) atomic 'mkdir .lock' missing"

# (k2) stale lock detection with PID+host+start_ts
grep -Fq 'kill -0' "$SK" || fail "(k2) 'kill -0' stale PID check missing"

# (k3) TOCTOU retry on empty pid
grep -Eiq 'retry.*acquisition|empty.*pid.*sleep' "$SK" \
  || fail "(k3) TOCTOU sleep+retry on empty pid missing"

# (l) trap INT TERM HUP EXIT
grep -Eiq 'trap.*(INT.*TERM|INT TERM HUP|HUP EXIT)' "$SK" \
  || fail "(l) trap INT TERM HUP EXIT missing (gemini-2 fix)"

# (m) atomic write .tmp → rename same directory
grep -Eq '\.tmp.*rename|tmp.*same directory' "$SK" \
  || fail "(m) atomic .tmp→rename (same directory) missing"

# (m2) resume: jq -e validate last JSONL line
grep -Fq 'jq -e' "$SK" || fail "(m2) jq -e last-line validation on resume missing"

# (n) dedup-against schema validation
grep -Fq -- '--dedup-against' "$SK" || fail "(n) --dedup-against flag missing"

# (o) gdpr-strict phone stripping + notice
grep -Fq -- '--gdpr-strict' "$SK" || fail "(o) --gdpr-strict flag missing"
grep -Fq 'GDPR_NOTICE.txt' "$SK" || fail "(o) GDPR_NOTICE.txt generation missing"

# (p) Run: TSV log
grep -Fq '~/.zuvo/runs.log' "$SK" || fail "(p) run log path missing"

# (q) COMPLETION GATE CHECK
grep -Fq 'COMPLETION GATE CHECK' "$SK" || fail "(q) COMPLETION GATE CHECK block missing"

# (r) retrospective
grep -Fq 'retrospective.md' "$SK" || fail "(r) retrospective.md reference missing"

# (s) agents return results — do not write checkpoints (CQ21)
grep -Eiq 'agents.*(return|reply).*(not write|never write)' "$SK" \
  || fail "(s) CQ21 agents-don't-write rule missing"

# (t) run log does NOT interpolate contact values (CQ5)
grep -Eiq "(does not|NOT|never).*interpolate.*contact" "$SK" \
  || fail "(t) CQ5 no-PII-in-run-log rule missing"

# (u) config perm check — fail closed
grep -Fq 'ZUVO_LEADS_ALLOW_INSECURE_CONFIG' "$SK" \
  || fail "(u) config perm check with fail-closed override env var missing"

# (v) validator LABELS — orchestrator dedups
grep -Eiq 'validator.*labels|orchestrator.*dedup' "$SK" \
  || fail "(v) validator-labels-orchestrator-dedups rule missing"

echo "PASS"
exit 0
