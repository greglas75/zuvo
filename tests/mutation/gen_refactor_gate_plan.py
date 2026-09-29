#!/usr/bin/env python3
"""Freeze a content-anchored mutation plan for the refactor gate's test surface."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LIB = "hooks/lib/refactor-gate-lib.sh"
STATE = "hooks/lib/refactor-state.py"
ENV = "hooks/lib/agent-env.sh"
ENTRY = "hooks/refactor-safety-gate.sh"
CONTRACT = "scripts/zuvo-home/refactor-contract"
HUMAN_ENV = "tests/lib/human-env.sh"
T = "tests/hooks/"

# (source, exact original, replacement, category, mapped shell suite names)
MUTATIONS = [
    (LIB, '  set +f\n  staged=$1', '  :\n  staged=$1', 'SECURITY', ['test-refactor-gate-lib-edge-cases.sh']),
    (LIB, '  [ -n "$ttl" ] || ttl=86400', '  [ -n "$ttl" ] || ttl=0', 'BOUNDARY', ['test-refactor-gate-lib-edge-cases.sh']),
    (LIB, '    _scope_intersects "$c" "$staged" || continue', '    _scope_intersects "$c" "$staged" && continue', 'SECURITY', ['test-refactor-gate-lib-edge-cases.sh']),
    (LIB, '    if [ $((now - mt)) -gt "$ttl" ]; then', '    if [ $((now - mt)) -lt "$ttl" ]; then', 'BOUNDARY', ['test-refactor-safety-gate.sh']),
    (LIB, '    case "$ba" in skipped|not_run|"")', '    case "$ba" in skipped|"")', 'SECURITY', ['test-refactor-gate-lib-edge-cases.sh']),
    (LIB, '    case "$av" in skipped|not_run|"")', '    case "$av" in skipped|"")', 'SECURITY', ['test-refactor-gate-lib-edge-cases.sh']),
    (LIB, '    case "$ch" in skipped|not_run|"")', '    case "$ch" in skipped|"")', 'SECURITY', ['test-refactor-safety-gate.sh']),
    (LIB, '    if [ "$_needs_red" -eq 1 ]; then', '    if [ "$_needs_red" -eq 0 ]; then', 'LOGIC', ['test-refactor-safety-gate.sh']),
    (LIB, "  set +f  # expand contract paths without changing the caller's noglob setting", '  :  # leave noglob active', 'SECURITY', ['test-refactor-gate-lib-edge-cases.sh']),
    (LIB, '    if [ "$rpv_cv" -ge 7 ] 2>/dev/null; then', '    if [ "$rpv_cv" -ge 8 ] 2>/dev/null; then', 'BOUNDARY', ['test-refactor-v4-prove-gate.sh']),
    (LIB, '        N/A:?*) ;;', '        N/A*) ;;', 'LOGIC', ['test-refactor-v4-prove-gate.sh']),
    (LIB, '    elif [ "$rpv_num" -ne "$rpv_mods" ] 2>/dev/null; then', '    elif [ "$rpv_num" -eq "$rpv_mods" ] 2>/dev/null; then', 'LOGIC', ['test-refactor-v4-prove-gate.sh']),
    (LIB, '    if [ "$rpv_b1" -ne "$rpv_b0" ] 2>/dev/null; then', '    if [ "$rpv_b1" -eq "$rpv_b0" ] 2>/dev/null; then', 'LOGIC', ['test-refactor-complexity-gate.sh']),
    (LIB, '        if [ $((rpv_a1 * 10)) -gt $((rpv_b1 * 9)) ] 2>/dev/null; then', '        if [ $((rpv_a1 * 10)) -ge $((rpv_b1 * 9)) ] 2>/dev/null; then', 'BOUNDARY', ['test-refactor-complexity-gate.sh']),
    (LIB, "  set +f  # expand contract paths; the subshell preserves the caller's options", '  :  # leave noglob active', 'SECURITY', ['test-refactor-gate-lib-edge-cases.sh']),
    (LIB, '    [ "$rsg_hit" = 0 ] && rsg_off="$rsg_off $rsg_f"', '    [ "$rsg_hit" = 1 ] && rsg_off="$rsg_off $rsg_f"', 'SECURITY', ['test-refactor-scope-gate.sh']),
    (LIB, '  [ -n "$_app" ] || _app=$(_ap_field "$1" plan_file)', '  [ -n "$_app" ] || _app=""', 'LOGIC', ['test-plan-execute-gate.sh']),
    (LIB, '  case "$sag_st" in draft|reviewed) ;; *) return 0 ;; esac', '  case "$sag_st" in draft) ;; *) return 0 ;; esac', 'SECURITY', ['test-spec-approval-gate.sh']),
    (LIB, '  set +f\n  _erl_root=$1', '  :\n  _erl_root=$1', 'SECURITY', ['test-refactor-gate-lib-edge-cases.sh']),
    (LIB, '    pending) ;;', '    notpending) ;;', 'SECURITY', ['test-plan-execute-gate.sh']),
    (LIB, '    [ "$_erl_age" -ge 0 ] && [ "$_erl_age" -le "$_erl_grace" ] && return 0', '    [ "$_erl_age" -le 0 ] && [ "$_erl_age" -le "$_erl_grace" ] && return 0', 'BOUNDARY', ['test-plan-execute-gate.sh']),
    (LIB, '    [ -n "$_erl_mr" ] && [ "$(_realpath "$_erl_mr")" = "$_erl_rootp" ] || continue', '    [ -n "$_erl_mr" ] && [ "$(_realpath "$_erl_mr")" != "$_erl_rootp" ] || continue', 'SECURITY', ['test-plan-execute-gate.sh']),
    (STATE, 'TERMINAL = {"COMPLETE", "BLOCKED", "ABORTED"}', 'TERMINAL = {"COMPLETE", "ABORTED"}', 'LOGIC', ['test-refactor-state-reader-behavior.sh']),
    (STATE, '        return int(contract.get("version") or 0)', '        return 0', 'LOGIC', ['test-refactor-v4-prove-gate.sh']),
    (STATE, '    return contract.get("findings_outcome") in ("fixed", "mixed") or bool(contract.get("fix_findings"))', '    return contract.get("findings_outcome") in ("fixed", "mixed") and bool(contract.get("fix_findings"))', 'LOGIC', ['test-refactor-state-reader-behavior.sh']),
    (STATE, '    if len(parts) != 3 or parts[0] not in ("PASS", "WARN") or not re.search(r"\\d", parts[1]):', '    if len(parts) != 3 or parts[0] not in ("PASS", "WARN"):', 'SECURITY', ['test-refactor-v4-prove-gate.sh']),
    (STATE, '    if args.action == "valid":\n        return 0', '    if args.action == "valid":\n        return 1', 'LOGIC', ['test-refactor-safety-gate.sh']),
    (STATE, '        return 0 if set(value).intersection(sys.stdin.read().splitlines()) else 1', '        return 1 if set(value).intersection(sys.stdin.read().splitlines()) else 0', 'SECURITY', ['test-refactor-gate-lib-edge-cases.sh']),
    (STATE, '        return 0 if args.value in value else 1', '        return 0 if args.value not in value else 1', 'LOGIC', ['test-refactor-state-reader-behavior.sh']),
    (ENV, '  [ "${ZUVO_AGENT:-0}" = "1" ] && return 0', '  [ "${ZUVO_AGENT:-0}" = "1" ] && return 1', 'SECURITY', ['test-refactor-agent-env-markers.sh']),
    (ENV, '  [ -n "${ZUVO_AI_RUN:-}" ] && return 0', '  [ -n "${ZUVO_AI_RUN:-}" ] && return 1', 'SECURITY', ['test-refactor-safety-gate.sh']),
    (ENV, '  [ -n "${CURSOR_TRACE_ID:-}${CURSOR_AGENT:-}" ] && return 0', '  [ -n "${CURSOR_TRACE_ID:-}" ] && return 0', 'SECURITY', ['test-refactor-agent-env-markers.sh']),
    (ENV, '  [ -n "${GEMINI_CLI:-}${ANTIGRAVITY:-}${GEMINI_ANTIGRAVITY:-}${ANTIGRAVITY_SESSION_ID:-}" ] && return 0', '  [ -n "${GEMINI_CLI:-}${ANTIGRAVITY:-}${GEMINI_ANTIGRAVITY:-}" ] && return 0', 'SECURITY', ['test-refactor-agent-env-markers.sh']),
    (ENV, '  return 1\n}', '  return 0\n}', 'SECURITY', ['test-refactor-agent-env-markers.sh']),
    (ENTRY, 'MODE=${1:-pre-commit}', 'MODE=${1:-pre-push}', 'LOGIC', ['test-refactor-gate-entry-defaults.sh']),
    (ENTRY, 'files=$(git -c core.quotePath=false diff --cached --name-only --no-renames 2>/dev/null) || exit 0', 'files=$(git -c core.quotePath=false diff --name-only --no-renames 2>/dev/null) || exit 0', 'LOGIC', ['test-refactor-safety-gate.sh']),
    (ENTRY, '      if [ "$rsha" = "$ZERO" ]; then', '      if [ "$rsha" != "$ZERO" ]; then', 'LOGIC', ['test-refactor-gate-entry-defaults.sh']),
    (ENTRY, 'refactor_gate_check "$files" || blk=1', 'refactor_gate_check "$files" || :', 'SECURITY', ['test-refactor-safety-gate.sh']),
    (ENTRY, 'refactor_scope_gate_check "$files" || blk=1', 'refactor_scope_gate_check "$files" || :', 'SECURITY', ['test-refactor-scope-gate.sh']),
    (ENTRY, 'plan_execute_gate_check "$files" || blk=1', 'plan_execute_gate_check "$files" || :', 'SECURITY', ['test-plan-execute-gate.sh']),
    (ENTRY, 'spec_approval_gate_check "$files" || blk=1', 'spec_approval_gate_check "$files" || :', 'SECURITY', ['test-spec-approval-gate.sh']),
    (CONTRACT, '    if up in ALIASES:', '    if False:', 'LOGIC', ['test-refactor-contract.sh']),
    (CONTRACT, '    live = [r for r in rows if r[1] not in _STATE["TERMINAL"]]', '    live = [r for r in rows if r[1] in _STATE["TERMINAL"]]', 'LOGIC', ['test-refactor-state-reader-behavior.sh']),
    (CONTRACT, '    stale = [r for r in live if r[3] > a.stale_days]', '    stale = [r for r in live if r[3] <= a.stale_days]', 'BOUNDARY', ['test-refactor-contract.sh']),
    (CONTRACT, '    if a.json:', '    if False:', 'LOGIC', ['test-refactor-state-reader-behavior.sh']),
    (CONTRACT, '    if missing and (not a.force or quality_errors):', '    if False:', 'SECURITY', ['test-refactor-contract.sh']),
    (CONTRACT, '    if ev.lower() in UNPROVEN or len(ev) < 3:', '    if False:', 'ERROR', ['test-refactor-contract.sh']),
    (CONTRACT, '    if a.cmd == "list":', '    if False:', 'LOGIC', ['test-refactor-contract.sh']),
    (CONTRACT, '        if not is_contract(c) or canonical_stage(c.get("stage"))[0] in _STATE["TERMINAL"]:', '        if not is_contract(c) or canonical_stage(c.get("stage"))[0] not in _STATE["TERMINAL"]:', 'LOGIC', ['test-refactor-contract.sh']),
    (HUMAN_ENV, "_HE_NEVER_UNSET='PATH|HOME|USER|SHELL|TMPDIR|TMP|TEMP|LANG|LC_ALL|PWD|OLDPWD|TERM|SHLVL|IFS'", "_HE_NEVER_UNSET='HOME|USER|SHELL|TMPDIR|TMP|TEMP|LANG|LC_ALL|PWD|OLDPWD|TERM|SHLVL|IFS'", 'SECURITY', ['test-human-env-helper.sh']),
    (HUMAN_ENV, "sed -n '/^zuvo_is_agent_env()/,/^}/p'", "sed -n '/^missing_agent_detector()/,/^}/p'", 'LOGIC', ['test-human-env-helper.sh']),
    (HUMAN_ENV, '  HUMAN+=(-u "$_he_v")', '  HUMAN+=(-u ZUVO_AGENT)', 'LOGIC', ['test-human-env-helper.sh']),
    (HUMAN_ENV, 'if [ "$_he_count" -lt 10 ]; then', 'if [ "$_he_count" -lt 0 ]; then', 'BOUNDARY', ['test-human-env-helper.sh']),
]


def main() -> None:
    rows = []
    for path, original, replacement, category, specs in MUTATIONS:
        source = (ROOT / path).read_bytes()
        old = original.encode()
        count = source.count(old)
        if count != 1:
            raise ValueError(f"{path}: anchor occurs {count} times: {original[:80]!r}")
        offset = source.index(old)
        line = source.count(b"\n", 0, offset) + 1
        column = offset - source.rfind(b"\n", 0, offset) - 1
        rows.append({
            "id": f"MUT-{len(rows) + 1:03d}", "file": path, "line": line,
            "col": column, "length": len(old), "category": category,
            "original": original, "replacement": replacement,
            "original_norm": " ".join(original.split()), "occurrence": 1,
            "file_sha": hashlib.sha256(source).hexdigest(),
            "specs": [T + name for name in specs],
        })
    out = Path(__file__).with_name("refactor-gate-lib.plan.json")
    out.write_text(json.dumps(rows, indent=2) + "\n")
    print(f"PLAN: {len(rows)} content-anchored mutations across {len(set(r['file'] for r in rows))} files: {out}")


if __name__ == "__main__":
    main()
