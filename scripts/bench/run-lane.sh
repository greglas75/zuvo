#!/usr/bin/env bash
# run-lane.sh <label> <provider> [ENV=value ...]
#
# Runs one driver lane (cursor-agent, codex-5.3, kimi, qwen, byteplus, claude, agy, muse, …) on the
# benchmark corpus through a FROZEN copy of adversarial-review.sh, one packet at a time, and records
# per packet: subs/<label>-<id>.{out,err,art} and a row in subs/results-<label>.tsv
# (provider group input status findings sec). Packets with a non-empty .out are skipped, so an
# interrupted run resumes where it stopped.
#
# The label names the CONFIGURATION, not the lane: effort is a separate dial from the model id, so
# "luna high" and "luna max" under one label overwrite each other and one measurement poses as two.
#
#   run-lane.sh cursor-grok-4.7-high cursor-agent ZUVO_CURSOR_MODEL=grok-4.7-high
#   run-lane.sh sol-light codex-5.3 ZUVO_MODEL_CODEX_PRIMARY=gpt-6-sol ZUVO_CODEX_EFFORT_PRIMARY=none
#   run-lane.sh tp-qwen3.8-max qwen ZUVO_ADV_QWEN=1 ZUVO_QWEN_MODEL=qwen3.8-max
#   run-lane.sh glm-5.3-flash-byteplus byteplus
#
# Env: BENCH_HOME (default ~/.zuvo/bench); ADV = REQUIRED frozen driver copy (runbook pitfall 1 —
# the live repo driver and ~/.zuvo/adversarial-review are refused); BENCH_TIMEOUT (default 900 s,
# the same for every lane so a timeout means the same thing everywhere).
set -uo pipefail

LAB="${1:-}"; PROV="${2:-}"
if [ -z "$LAB" ] || [ -z "$PROV" ]; then
  echo "usage: run-lane.sh <label> <provider> [ENV=value ...]" >&2; exit 2
fi
shift 2
case "$LAB" in */*|*" "*|*"	"*) echo "run-lane.sh: label must not contain '/', spaces or tabs: $LAB" >&2; exit 2 ;; esac
for kv in "$@"; do
  case "$kv" in [A-Z_]*=*) ;; *) echo "run-lane.sh: extra arguments must be ENV=value, got: $kv" >&2; exit 2 ;; esac
done

D="${BENCH_HOME:-$HOME/.zuvo/bench}"
[ -f "$D/sel.json" ] || { echo "run-lane.sh: no corpus selection at $D/sel.json (set BENCH_HOME)" >&2; exit 2; }
ADV="${ADV:-}"
[ -n "$ADV" ] || { echo "run-lane.sh: set ADV to a FROZEN copy of adversarial-review.sh" >&2; exit 2; }
[ -f "$ADV" ] || { echo "run-lane.sh: ADV=$ADV does not exist" >&2; exit 2; }
_real() { python3 -c 'import os,sys;print(os.path.realpath(os.path.expanduser(sys.argv[1])))' "$1"; }
_here=$(cd "$(dirname "$0")/.." && pwd)
for live in "$_here/adversarial-review.sh" "$HOME/.zuvo/adversarial-review"; do
  if [ -e "$live" ] && [ "$(_real "$ADV")" = "$(_real "$live")" ]; then
    echo "run-lane.sh: ADV is the LIVE driver ($live) — freeze a copy first" >&2; exit 2
  fi
done
# The driver loads its modules from <its dir>/lib/ or <its dir>/ (scripts/lib/adversarial-*.sh): a copy frozen
# without them exits 2 before it reviews anything, and every packet would be recorded as `none` and re-run on the
# next call. --help exits 0 only after every module loaded, so it proves this copy is not missing them.
if ! _pf=$(bash "$ADV" --help 2>&1 >/dev/null </dev/null); then
  echo "run-lane.sh: ADV=$ADV cannot run — freeze it together with its lib/ (docs/runbook/model-benchmark.md, \"Running it\"):" >&2
  printf '%s\n' "$_pf" | tail -3 >&2
  exit 2
fi
TIMEOUT="${BENCH_TIMEOUT:-900}"
case "$TIMEOUT" in ''|*[!0-9]*) echo "run-lane.sh: BENCH_TIMEOUT must be seconds" >&2; exit 2 ;; esac

S="$D/subs"; mkdir -p "$S"
OUT="$S/results-$LAB.tsv"
# one runner per label: two would both see a packet as unfinished and run it twice. The lock holds
# the owner's PID so a run killed with -9 does not block the label forever.
LOCK="$S/.lock-$LAB"
if ! mkdir "$LOCK" 2>/dev/null; then
  owner=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
    stale="$LOCK.stale.$$"     # atomic reclaim, as in judge.sh
    if mv "$LOCK" "$stale" 2>/dev/null && [ "$(cat "$stale/pid" 2>/dev/null || true)" = "$owner" ]; then
      rm -f "$stale/pid"; rmdir "$stale" 2>/dev/null
      mkdir "$LOCK" 2>/dev/null || { echo "run-lane.sh: lock $LOCK busy" >&2; exit 3; }
    else
      [ -d "$stale" ] && mv "$stale" "$LOCK" 2>/dev/null
      echo "run-lane.sh: lock $LOCK taken by another run" >&2; exit 3
    fi
  else
    echo "run-lane.sh: another run-lane.sh (PID ${owner:-?}) is running $LAB" >&2; exit 3
  fi
fi
echo $$ > "$LOCK/pid"
trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null' EXIT
[ -f "$OUT" ] || printf 'provider\tgroup\tinput\tstatus\tfindings\tsec\n' > "$OUT"

python3 - "$D/sel.json" <<'PY' | while IFS=$'\t' read -r grp diff; do
import json, sys
sel = json.load(open(sys.argv[1]))
for g in ("ok", "fail"):
    for r in sel.get(g, []):
        print(g + "\t" + r["diff"])
PY
  # sel.json may name the rotated input (<id>.diff) or the corpus file (judge2/<id>/CODE.diff)
  if [ "$(basename "$diff")" = "CODE.diff" ]; then iid=$(basename "$(dirname "$diff")"); else iid=$(basename "$diff" .diff); fi
  [ -f "$diff" ] || diff="$D/judge2/$iid/CODE.diff"
  [ -f "$diff" ] || { echo "run-lane.sh: packet $iid has no diff (sel.json path nor judge2/$iid/CODE.diff)" >&2; exit 3; }
  # Resume on the RECORDED status, not on a non-empty .out: the driver writes its report header
  # even when the provider never answered, and that packet was never retried. `none` = no provider
  # outcome at all (infrastructure) → run again; ok / timeout / empty / failed are results → keep.
  last=$(awk -F'\t' -v id="$iid" 'NR>1 && $3==id {s=$4} END {print s}' "$OUT")
  if [ -n "$last" ] && [ "$last" != "none" ] && [ -s "$S/$LAB-$iid.out" ]; then continue; fi
  rm -f "$S/$LAB-$iid.art"       # a re-run must not read the previous attempt's outcome
  t0=$(date +%s)
  env "$@" ZUVO_ADVERSARIAL_LOG_FILE="$S/adv-$LAB.log" ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT="$TIMEOUT" \
    bash "$ADV" --provider "$PROV" --mode code --artifact "$S/$LAB-$iid.art" \
    < "$diff" > "$S/$LAB-$iid.out" 2>"$S/$LAB-$iid.err"
  t1=$(date +%s)
  st=$(awk -F= -v p="$PROV" '/^provider_outcomes=/{n=split($2,a,","); for(i=1;i<=n;i++){split(a[i],b,":"); if(b[1]==p){print b[2]; exit}}}' "$S/$LAB-$iid.art" 2>/dev/null)
  fnd=$(awk -F= '/^total_findings=/{print $2; exit}' "$S/$LAB-$iid.art" 2>/dev/null)
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$LAB" "$grp" "$iid" "${st:-none}" "${fnd:-0}" "$((t1-t0))" >> "$OUT"
  echo "$LAB $iid ${st:-none} findings=${fnd:-0} $((t1-t0))s"
done
rc=$?
[ "$rc" -eq 0 ] || { echo "run-lane.sh: aborted (rc=$rc)" >&2; exit "$rc"; }
echo "LANE_DONE $LAB"
