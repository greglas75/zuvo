#!/usr/bin/env bash
# bench-model.sh — the WHOLE evaluation of one reviewer candidate: run → judge → evaluate.
# Every stage resumes: an interruption loses nothing that already returned.
#
#   bench-model.sh or  <spec>                         spec = [label=]vendor/model[@effort]
#   bench-model.sh cli <label> <provider> [ENV=value ...]
#   bench-model.sh or  meta/muse-spark-1.3 --skip-run   (judge + evaluate only)
#
#   ADV=<frozen driver copy>  REQUIRED for the run stage (see docs/runbook/model-benchmark.md)
#   BENCH_HOME                data dir, default ~/.zuvo/bench
#   JUDGE_MODEL               judge model for judge.sh (default claude-opus-5)
#   REF                       reference label for evaluate-model.py (optional)
#
# Why a script and not a list of steps: assembling these stages by hand for Muse Spark 1.3 gave
# four errors in a row — the wrong output path, the wrong vocabulary, `grep -P` that does not work
# inside a script, and a process match that caught its own monitor.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LANE="${1:-}"; shift || true
SKIP_RUN=0
args=()
for a in "$@"; do [ "$a" = "--skip-run" ] && SKIP_RUN=1 || args+=("$a"); done
set -- ${args[@]+"${args[@]}"}

case "$LANE" in
  or)
    SPEC="${1:?usage: bench-model.sh or [label=]vendor/model[@effort] [--skip-run]}"
    LABEL="${SPEC%%=*}"; [ "$LABEL" = "$SPEC" ] && LABEL="$SPEC"
    SOURCE=or ;;
  cli)
    LABEL="${1:?usage: bench-model.sh cli <label> <provider> [ENV=value ...] [--skip-run]}"
    PROVIDER="${2:-}"; [ "$SKIP_RUN" = 1 ] || [ -n "$PROVIDER" ] || { echo "bench-model.sh: cli needs <provider>" >&2; exit 2; }
    shift 2 2>/dev/null || shift $#
    SOURCE=cli ;;
  *) echo "usage: bench-model.sh or|cli … (see header)" >&2; exit 2 ;;
esac

echo "═══ 1/3 run: $LABEL ($LANE) ═══"
if [ "$SKIP_RUN" = 1 ]; then
  echo "  skipped (--skip-run)"
elif [ "$LANE" = or ]; then
  python3 "$HERE/bench-or.py" --models "$SPEC" || exit $?
else
  bash "$HERE/run-lane.sh" "$LABEL" "$PROVIDER" "$@" || exit $?
fi

echo "═══ 2/3 judge ═══"
bash "$HERE/judge.sh" "$LABEL" --source "$SOURCE" --judge-model "${JUDGE_MODEL:-claude-opus-5}" || exit $?

echo "═══ 3/3 evaluate ═══"
python3 "$HERE/evaluate-model.py" "$LABEL" ${REF:+"$REF"} || exit $?
