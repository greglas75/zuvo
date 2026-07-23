#!/usr/bin/env bash
# Tests the plan-review round budget in scripts/adversarial-review.sh.
# zuvo:plan splits a large scope into 3 sequential plan docs, each running its own review loop;
# the prose caps ("max 3 iterations") don't compose, so a run did ~10 adversarial --mode plan
# passes (185-225s each) across r1..r4 for a 6-hour run. This is the deterministic composing
# bound: --mode plan is refused past a per-repo/window budget, so the loop cannot continue.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AR="$ROOT/scripts/adversarial-review.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }
export ZUVO_HOME="$TMP/zh"; mkdir -p "$ZUVO_HOME"
repo(){ rm -rf "$TMP/r"; mkdir -p "$TMP/r"; cd "$TMP/r"; git init -q; }
# run one --mode plan pass; --single keeps it cheap; empty stdin returns fast; echo exit code
pass(){ echo "plan" | ZUVO_PLAN_ROUND_BUDGET="${1:-8}" ZUVO_PLAN_BUDGET_WINDOW="${2:-1800}" \
        timeout 8 bash "$AR" --mode plan --single >/dev/null 2>&1; echo $?; }

echo "=== budget exhausts after N passes, refuses N+1 ==="
repo
[ "$(pass 3)" -ne 7 ] && ok "pass 1 proceeds" || bad "pass 1 refused"
[ "$(pass 3)" -ne 7 ] && ok "pass 2 proceeds" || bad "pass 2 refused"
[ "$(pass 3)" -ne 7 ] && ok "pass 3 proceeds" || bad "pass 3 refused"
[ "$(pass 3)" -eq 7 ] && ok "pass 4 REFUSED (exit 7) — budget 3 exhausted" || bad "pass 4 not refused"
[ "$(pass 3)" -eq 7 ] && ok "stays refused after exhaustion" || bad "budget leaked back"

echo "=== a gap longer than the window is a new run: counter resets ==="
repo
pass 2 >/dev/null; pass 2 >/dev/null                 # count=2 (at budget)
[ "$(pass 2)" -eq 7 ] && ok "3rd pass refused at budget 2" || bad "not refused at 2"
# backdate the state file beyond the window -> next pass sees a fresh run.
# Key off the SAME path the script uses: git rev-parse resolves symlinks (/var -> /private/var
# on macOS), so hashing $TMP/r directly would target a different file.
realroot="$(git -C "$TMP/r" rev-parse --show-toplevel)"
key="$(printf '%s' "$realroot" | (shasum 2>/dev/null || sha1sum) | cut -c1-16)"
printf '2 100\n' > "$ZUVO_HOME/plan-budget/$key"        # last=epoch 100 (long ago)
[ "$(pass 2 1800)" -ne 7 ] && ok "pass after a >window gap resets the counter (new run)" || bad "stale counter blocked a new run"

echo "=== per-repo isolation ==="
repo; pass 1 >/dev/null                                # repo A: at budget 1
A="$TMP/r"
rm -rf "$TMP/r2"; mkdir -p "$TMP/r2"; cd "$TMP/r2"; git init -q
[ "$(pass 1)" -ne 7 ] && ok "a different repo has its own budget" || bad "budget bled across repos"
cd "$A"; [ "$(pass 1)" -eq 7 ] && ok "original repo still at its budget" || bad "repo A budget lost"

echo "=== escape + scope ==="
repo; pass 1 >/dev/null
[ "$(ZUVO_PLAN_BUDGET_OFF=1 pass 1)" -ne 7 ] && ok "ZUVO_PLAN_BUDGET_OFF=1 disables the breaker" || bad "OFF did not disable"
repo
r=$(echo x | ZUVO_PLAN_ROUND_BUDGET=1 timeout 8 bash "$AR" --mode code --single >/dev/null 2>&1; echo $?)
[ "$r" -ne 7 ] && ok "--mode code is NOT subject to the plan budget" || bad "code hit the plan budget"
r=$(echo x | ZUVO_PLAN_ROUND_BUDGET=1 timeout 8 bash "$AR" --mode security --single >/dev/null 2>&1; echo $?)
[ "$r" -ne 7 ] && ok "--mode security is NOT subject to the plan budget" || bad "security hit the plan budget"

echo "=== race safety: parallel passes never UNDER-count (the CRITICAL) ==="
# The motivating run reviewed the 3 split documents in PARALLEL. A read-modify-write counter
# races and loses increments (under-enforcement). Append-then-count cannot: the invariant is
# proceeded <= budget always. (A burst larger than the budget may refuse ALL — over-enforcement,
# the safe direction for a circuit-breaker.)
repo
rc="$TMP/race-rc"; : > "$rc"
for i in 1 2 3 4 5 6 7 8; do
  ( r="$(pass 4)"; echo "$r" >> "$rc" ) &
done
wait
proceeded="$(grep -vc '^7$' "$rc")"
[ "$proceeded" -le 4 ] && ok "8 parallel passes, budget 4: proceeded=$proceeded <= 4 (no lost increments)" || bad "under-enforced: $proceeded > 4"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
