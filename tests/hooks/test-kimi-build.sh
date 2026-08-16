#!/bin/bash
# Kimi Code build target — contract tests.
#
# The build script validates its own output and fails closed, so this suite does NOT
# re-assert what the build already gates. It covers the opposite risk: that someone
# maintaining five build targets copies a Cursor/Antigravity transform into the Kimi
# one and silently DEGRADES it. Kimi is the only non-Claude target with real parallel
# sub-agents, plan mode and AskUserQuestion; a degradation there is invisible — skills
# keep running, just single-agent and worse, while every build still reports success.
#
# Run: bash tests/hooks/test-kimi-build.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST="$ROOT/dist/kimi"

pass_count=0; fail_count=0
pass() { echo "  PASS: $1"; pass_count=$((pass_count + 1)); }
bad()  { echo "  FAIL: $1"; fail_count=$((fail_count + 1)); }

echo "=== kimi build target ==="

# (1) The build must succeed and be self-validating.
# tests/lib/dist-build.sh replays the build's exact log and exit code from a per-run
# cache when one exists, so this assertion still tests "the kimi build exits 0" — it
# just does not pay for a second full 57-skill build when a sibling already ran one.
if build_log=$(bash "$ROOT/tests/lib/dist-build.sh" kimi 2>&1); then
  pass "(1) build-kimi-skills.sh exits 0"
else
  bad "(1) build failed (tail: $(printf '%s' "$build_log" | tail -3))"
  echo "  -> remaining assertions would be vacuous; stopping"
  exit 1
fi

# (2) Sub-agent dispatch survives. Cursor and Antigravity rewrite spawn blocks into
#     "Execute inline: ..." because they lack sub-agents; Kimi has the Agent tool, so
#     that rewrite must NOT be present here.
if grep -rq 'Execute inline: read instructions from' "$DIST/skills" 2>/dev/null; then
  bad "(2) dist contains the inline-sequential rewrite — Kimi's sub-agents were degraded away"
else
  pass "(2) no inline-sequential rewrite (sub-agent dispatch preserved)"
fi

# (3) Agent profiles are actually shipped and flat. Kimi resolves profiles byName from a
#     single directory, so a subdirectory layout would load nothing.
agent_files=$(ls "$DIST"/agents/*.md 2>/dev/null | wc -l | tr -d ' ')
if [ "${agent_files:-0}" -ge 40 ]; then
  pass "(3) flat agent namespace populated ($agent_files profiles)"
else
  bad "(3) expected >=40 flat agent profiles, found ${agent_files:-0}"
fi
if [ -d "$DIST/skills/review/agents" ]; then
  bad "(3b) agents left in a skill subdirectory — Kimi would not discover them"
else
  pass "(3b) no per-skill agents/ subdirectories in dist"
fi

# (4) Kimi HAS these tools; the Cursor/Antigravity builds must strip them, this one must
#     not. Presence is asserted, NOT a source-vs-dist count: platform-block stripping
#     legitimately removes mentions that live inside other harnesses' sections, so a
#     count comparison fails for a correct build (it did, on the first version of this
#     test). The substitution check below is what actually catches a degradation.
#     Only tools the source uses are checked — ExitPlanMode appears zero times today,
#     and asserting it would be vacuous.
for tool in AskUserQuestion EnterPlanMode; do
  src_n=$( { grep -rho "$tool" "$ROOT"/skills/*/SKILL.md "$ROOT"/skills/*/agents/*.md "$ROOT"/shared/includes/*.md 2>/dev/null || true; } | wc -l | tr -d ' ')
  dst_n=$( { grep -rho "$tool" "$DIST"/skills "$DIST"/agents "$DIST"/shared 2>/dev/null || true; } | wc -l | tr -d ' ')
  if [ "${src_n:-0}" -eq 0 ]; then
    echo "  SKIP: (4) $tool absent from source — nothing to preserve"
  elif [ "${dst_n:-0}" -ge 1 ]; then
    pass "(4) $tool survives in dist ($dst_n mentions; Kimi supports it)"
  else
    bad "(4) $tool stripped from dist entirely ($src_n in source) — Kimi supports it"
  fi
done

# (4a) The Cursor/Antigravity builds replace AskUserQuestion with a canned
#      "[AUTO-DECISION: proceed with safest default]". Kimi can ask the user, so that
#      substitution appearing here means a run will silently guess instead of asking.
if grep -rqF '[AUTO-DECISION: proceed with safest default]' "$DIST" 2>/dev/null; then
  bad "(4a) dist contains the [AUTO-DECISION] substitution — Kimi can ask the user"
else
  pass "(4a) no [AUTO-DECISION] substitution (interactive prompts preserved)"
fi

# (4b) The dist must carry Kimi's platform guidance and NOT another harness's. Shipping
#      Codex's single-agent section to Kimi is the subtlest degradation available: nothing
#      breaks, runs just quietly stop dispatching because the prose told them to.
ENVC="$DIST/shared/includes/env-compat.md"
if [ -f "$ENVC" ]; then
  if grep -q '### Kimi Code' "$ENVC" && ! grep -q '### Codex' "$ENVC"; then
    pass "(4b) env-compat carries the Kimi section and not Codex's single-agent block"
  else
    bad "(4b) env-compat platform sections wrong (kimi=$(grep -c '### Kimi Code' "$ENVC"), codex=$(grep -c '### Codex' "$ENVC"))"
  fi
else
  bad "(4b) dist is missing shared/includes/env-compat.md"
fi

# (5) Tools Kimi does NOT have must be gone.
if grep -rq '\bTodoWrite\b\|\bMultiEdit\b' "$DIST/skills" "$DIST/agents" 2>/dev/null; then
  bad "(5) dist references TodoWrite/MultiEdit — neither exists in Kimi"
else
  pass "(5) no TodoWrite/MultiEdit references"
fi

# (6) model_preference is a closed enum in Kimi's loader ("primary" | "secondary");
#     anything else is a hard parse error that disables the agent.
bad_pref=$(grep -rh '^model_preference:' "$DIST"/agents/*.md 2>/dev/null \
  | grep -vcE '^model_preference: *"?(primary|secondary)"? *$' || true)
if [ "${bad_pref:-0}" -eq 0 ]; then
  pass "(6) every model_preference is primary|secondary"
else
  bad "(6) $bad_pref agent(s) carry an invalid model_preference"
fi

# (7) Hook template must use Kimi's flat [[hooks]] TOML shape, not the nested JSON one.
if [ -f "$DIST/hooks.kimi.toml" ]; then
  if grep -q '^\[\[hooks\]\]' "$DIST/hooks.kimi.toml"; then
    pass "(7) hooks template uses [[hooks]] array-of-tables"
  else
    bad "(7) hooks template has no [[hooks]] tables"
  fi
  # StopFailure is the rewake path. Kimi supports the event, so unlike Cursor/Antigravity
  # this target has no excuse to drop it.
  if grep -q 'StopFailure' "$DIST/hooks.kimi.toml"; then
    pass "(7b) StopFailure rewake hook is wired (Kimi supports the event)"
  else
    bad "(7b) StopFailure hook missing — the API-error rewake path is silently absent"
  fi
else
  bad "(7) dist/kimi/hooks.kimi.toml missing"
fi

# (8) install.sh must actually wire the target, in the case dispatch AND in `all`.
INSTALL="$ROOT/scripts/install.sh"
if grep -q 'install_kimi()' "$INSTALL" && grep -qE '^\s*kimi\)\s*install_kimi' "$INSTALL"; then
  pass "(8) install.sh defines and dispatches install_kimi"
else
  bad "(8) install.sh does not define/dispatch install_kimi"
fi
if grep -qE 'both\|all\).*install_kimi' "$INSTALL"; then
  pass '(8b) install_kimi runs as part of the "all" target'
else
  bad "(8b) install_kimi is missing from the 'all' target — a normal install would skip Kimi"
fi

# (9) Provenance: the shared user roots must never be blanket-deleted. ~/.kimi-code/skills
#     and /agents hold the user's own work too (this is the bug class that hit the
#     Antigravity target in 2026-08-11).
if grep -qE 'rm -rf "\$KIMI_SKILLS"|rm -rf "\$KIMI_AGENTS"' "$INSTALL"; then
  bad "(9) install.sh blanket-deletes a shared Kimi root — third-party data loss"
else
  pass "(9) no blanket delete of the shared Kimi skills/agents roots"
fi
if grep -q 'KIMI_AGENT_MANIFEST' "$INSTALL"; then
  pass "(9b) flat agent installs are manifest-tracked (prune + no-clobber)"
else
  bad "(9b) no agent manifest — stale agents cannot be pruned and user agents can be clobbered"
fi

echo ""
echo "  $pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ] || exit 1
