#!/usr/bin/env bash
# test-orphan-sweep-backfill.sh — M6 fix: the Stop-hook sweep is no longer a
# telemetry dead-end. A progress-bearing orphan (commits on its repo since
# start_ts) is auto-logged to runs.log as DEGRADED; a zero-progress orphan
# stays ABANDONED with NO runs.log row. The DEGRADED friction is NOT producible
# by an ordinary append-retro call (sweep-reserved).

STUB="$ROOT/scripts/zuvo-home/retro-stub"
ARUN="$ROOT/scripts/zuvo-home/append-runlog"
ARET="$ROOT/scripts/zuvo-home/append-retro"
_o=""; _oc(){ for d in $_o; do rm -rf "$d" 2>/dev/null; done; }; trap _oc EXIT INT TERM
_z(){ local d; d=$(mktemp -d); _o="$_o $d"; mkdir -p "$d/run-markers"; cp "$ARUN" "$d/append-runlog"; chmod +x "$d/append-runlog"; printf '%s' "$d"; }
_repo(){ local r; r=$(mktemp -d); _o="$_o $r"; git -C "$r" init -q; git -C "$r" config user.email t@t; git -C "$r" config user.name t; printf '%s' "$r"; }
OLD="2026-05-28T00:00:00Z"   # >6h ago, past grace

start_test "PROGRESSED orphan -> DEGRADED retro + real runs.log row"
Z=$(_z); R=$(_repo)
echo x > "$R/a.txt"; git -C "$R" add -A; git -C "$R" commit -qm "work since start_ts"
RB=$(basename "$(git -C "$R" rev-parse --show-toplevel)")
RSHA=$(git -C "$R" rev-parse --short HEAD)
printf 'start_ts=%s\nskill=execute\nproject=PlanSlug\nsha7=%s\nbranch=main\nsession_id=s1\nrepo_root=%s\n' "$OLD" "$RSHA" "$R" \
  > "$Z/run-markers/execute-PlanSlug-$RSHA-1-1.marker"
PATH="$Z:$PATH" ZUVO_HOME="$Z" "$STUB" --sweep >/dev/null 2>&1
assert_exit_code 0 "$?" "sweep exits 0"
fr=$(grep '^RETRO:' "$Z/retros.log" | head -1 | sed 's/^RETRO: //' | awk -F'\t' '{print $5}')
assert_eq "degraded-autolog" "$fr" "progressed orphan -> degraded-autolog retro"
rows=$(grep -c . "$Z/runs.log" 2>/dev/null || echo 0)
assert_eq 1 "$rows" "a runs.log row was backfilled"
rp=$(awk -F'\t' '{print $3}' "$Z/runs.log")
assert_eq "$RB" "$rp" "runs.log PROJECT = repo basename (NOT the plan-slug)"
rv=$(awk -F'\t' '{print $6}' "$Z/runs.log")
assert_eq "WARN" "$rv" "degraded row verdict = WARN"
rt=$(awk -F'\t' '{print $1}' "$Z/runs.log")
assert_eq "$OLD" "$rt" "runs.log field1 = real run start_ts (honest time series)"

start_test "ZERO-progress orphan -> ABANDONED stub + NO runs.log row"
Z=$(_z); R=$(_repo)   # fresh repo, NO commits since start_ts
printf 'start_ts=%s\nskill=plan\nproject=Empty\nsha7=-\nbranch=main\nsession_id=s2\nrepo_root=%s\n' "$OLD" "$R" \
  > "$Z/run-markers/plan-Empty---2-2.marker"
PATH="$Z:$PATH" ZUVO_HOME="$Z" "$STUB" --sweep >/dev/null 2>&1
fr=$(grep '^RETRO:' "$Z/retros.log" | head -1 | sed 's/^RETRO: //' | awk -F'\t' '{print $5}')
assert_eq "abandoned" "$fr" "no-progress orphan -> abandoned stub"
assert_eq 0 "$(grep -c . "$Z/runs.log" 2>/dev/null || echo 0)" "NO runs.log row (nothing to credit)"

start_test "missing repo_root (old marker / phantom branch) -> ABANDONED, no row"
Z=$(_z)
printf 'start_ts=%s\nskill=execute\nproject=Phantom\nsha7=-\nbranch=codex/x\nsession_id=s3\n' "$OLD" \
  > "$Z/run-markers/execute-Phantom---3-3.marker"
PATH="$Z:$PATH" ZUVO_HOME="$Z" "$STUB" --sweep >/dev/null 2>&1
fr=$(grep '^RETRO:' "$Z/retros.log" | head -1 | sed 's/^RETRO: //' | awk -F'\t' '{print $5}')
assert_eq "abandoned" "$fr" "no repo_root -> falls back to ABANDONED (never fabricates)"
assert_eq 0 "$(grep -c . "$Z/runs.log" 2>/dev/null || echo 0)" "no runs.log row without provable progress"

start_test "degraded-autolog is sweep-RESERVED (agent cannot self-emit it)"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --skill=execute --project=P --friction=degraded-autolog >/dev/null 2>&1
assert_exit_code 2 "$?" "append-retro refuses friction=degraded-autolog"
