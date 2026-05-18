#!/usr/bin/env bash
# test-retro-home-override.sh — Plan Task 1 (G-TEST).
# append-runlog MUST honor $ZUVO_HOME (default $HOME/.zuvo) so the retro/run
# gate is hermetically testable without polluting the real ~/.zuvo.

ADV="$ROOT/scripts/zuvo-home/append-runlog"
_t1_tmps=""
_t1_cleanup() { for d in $_t1_tmps; do rm -rf "$d" 2>/dev/null; done; }
trap _t1_cleanup EXIT INT TERM

start_test "T1.1 append-runlog writes to \$ZUVO_HOME, not real ~/.zuvo"
SAFE_HOME=$(mktemp -d)          # redirect HOME too: even a buggy script can't touch real ~/.zuvo
ZH=$(mktemp -d)/zuvo            # ZUVO_HOME deliberately != $SAFE_HOME/.zuvo
# 13-field run line for an exempt skill (backlog) — exempt path needs no retro.
RUN='2026-05-18T00:00:00Z\tbacklog\tdemo\t-\t-\tPASS\t-\t-\thome-override\tmain\tabc1234\t-\t-'
out=$(HOME="$SAFE_HOME" ZUVO_HOME="$ZH" bash -c 'printf "%b\n" "'"$RUN"'" | "'"$ADV"'"' 2>&1)
rc=$?

assert_exit_code 0 "$rc" "exempt skill exits 0"
if [[ -s "$ZH/runs.log" ]]; then
  pass "runs.log written under \$ZUVO_HOME"
else
  fail "T1.1" "expected \$ZUVO_HOME/runs.log non-empty (got: out=<$out>)"
fi
if [[ ! -e "$SAFE_HOME/.zuvo/runs.log" ]]; then
  pass "did NOT fall back to \$HOME/.zuvo when \$ZUVO_HOME set"
else
  fail "T1.1" "leaked to \$HOME/.zuvo/runs.log despite ZUVO_HOME being set"
fi

start_test "T1.2 default (ZUVO_HOME unset) still resolves to \$HOME/.zuvo"
SAFE_HOME2=$(mktemp -d)
RUN2='2026-05-18T00:00:01Z\tbacklog\tdemo\t-\t-\tPASS\t-\t-\tdefault-path\tmain\tabc1234\t-\t-'
HOME="$SAFE_HOME2" bash -c 'unset ZUVO_HOME; printf "%b\n" "'"$RUN2"'" | "'"$ADV"'"' >/dev/null 2>&1
if [[ -s "$SAFE_HOME2/.zuvo/runs.log" ]]; then
  pass "unset ZUVO_HOME falls back to \$HOME/.zuvo (no behavior change)"
else
  fail "T1.2" "default path regressed — \$HOME/.zuvo/runs.log not written"
fi

start_test "T1.3 verify-audit executable is resolved via ZUVO_BIN, not ZUVO_HOME"
# Regression guard for the adversarial CRITICAL: a hermetic/Codex ZUVO_HOME
# (no verify-audit binary there) must NOT silently disable the audit gate.
if grep -q 'ZUVO_BIN' "$ADV" && grep -q '"\$ZUVO_BIN/verify-audit"' "$ADV" \
   && ! grep -q '"\$ZUVO_HOME/verify-audit"' "$ADV"; then
  pass "verify-audit decoupled from state dir (ZUVO_BIN, default \$HOME/.zuvo)"
else
  fail "T1.3" "verify-audit still resolved via ZUVO_HOME — hermetic override would bypass the audit gate"
fi

start_test "T1.4 mis-set ZUVO_HOME fails fast with a clear error (no silent continue)"
# Portable "uncreatable": a path UNDER a regular file — mkdir -p fails on any POSIX OS.
_blocker=$(mktemp); _t1_tmps="$_t1_tmps $_blocker"
out=$(ZUVO_HOME="$_blocker/nope" bash -c 'printf "%b\n" "2026-05-18T00:00:02Z\tbacklog\tdemo\t-\t-\tPASS\t-\t-\tx\tmain\tabc1234\t-\t-" | "'"$ADV"'"' 2>&1)
rc=$?
assert_ne 0 "$rc" "non-zero exit when ZUVO_HOME uncreatable"
assert_contains "$out" "ZUVO_HOME" "error names ZUVO_HOME"

_t1_tmps="$_t1_tmps $SAFE_HOME $SAFE_HOME2 ${ZH%/zuvo}"
