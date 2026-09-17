#!/usr/bin/env bash
# zuvo:survey-translation-qa — one entry point for the skill's deterministic checks and builders.
#
#   stqa.sh integrity <export.xlsx> --script el
#   stqa.sh diff <old.xlsx> <new.xlsx>
#   stqa.sh verify <old.xlsx> <new.xlsx> --workbook QA.xlsx --script el
#   stqa.sh simulate <export.xlsx> --workbook QA.xlsx --out patched.xlsx --script el
#   stqa.sh reconcile --export E --primary QA.xlsx --adversarial ADV.xlsx --decisions d.json --out QA.xlsx --script el
#   stqa.sh adversary --project ACME --lang EL --script el --round 2 --export new.xlsx \
#                     --workbook ACME_EL_QA_Corrections_R2.xlsx --verdict verdict.txt [--client codex|agy|kimi] [--model ID]
#   stqa.sh fonts --list | stqa.sh fonts el "<text>"
#   stqa.sh selfcheck
#   stqa.sh py -c 'from stqa_workbook import QABook; …'      # the builders, from python
#
# Every subcommand adds --json / --strict where stqa_checks.py offers them.
#
# openpyxl is not a zuvo dependency, so the first run bootstraps a private venv in
# ~/.zuvo/stqa-venv (needs network once); later runs are offline, which is what lets a sandboxed
# adversary run the same checks. Override the location with ZUVO_STQA_VENV.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
VENV="${ZUVO_STQA_VENV:-$HOME/.zuvo/stqa-venv}"
PY="$VENV/bin/python"

ensure_py() {
  if [ ! -x "$PY" ] && python3 -c 'import openpyxl' 2>/dev/null; then
    PY="$(command -v python3)"          # hosted sandboxes ship openpyxl and have no network for a venv
    return
  fi
  if [ ! -x "$PY" ] || ! "$PY" -c 'import openpyxl' 2>/dev/null; then
    echo "survey-translation-qa: bootstrapping $VENV (openpyxl)…" >&2
    mkdir -p "$(dirname "$VENV")"
    if command -v uv >/dev/null 2>&1; then
      uv venv --quiet "$VENV" && uv pip install --quiet --python "$VENV/bin/python" openpyxl
    else
      python3 -m venv "$VENV" && "$VENV/bin/python" -m pip install --quiet openpyxl
    fi
  fi
}

run() { PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}" PYTHONDONTWRITEBYTECODE=1 exec "$PY" "$@"; }

# ── Phase 4b from a terminal: hand the round to a model of the OTHER family ────────────────────
# The adversary gets the export(s), the workbook and the chat verdict — never the primary's
# reasoning. It works in a scratch copy (the inputs are not modified) and must leave
#   {project}_{LANG}_QA_Adversarial_R{n}_<model>.xlsx   next to the workbook.
# Client = an agentic CLI of a different family than the primary. Primary Claude/Fable → codex
# (GPT); primary GPT → run the adversary in Claude instead (this path is not needed then).
# Exit: 0 file produced · 3 no cross-family client on PATH · 4 client ran but produced no file.
adversary() {
  local PROJECT='' LANG_='' SCRIPT=latin ROUND=1 EXPORT='' PREVIOUS=''
  local WORKBOOK='' VERDICT='' CLIENT='' MODEL=''
  local PRIMARY="Claude (Fable)"
  while [ $# -gt 0 ]; do case "$1" in
    --project) PROJECT="$2"; shift 2;; --lang) LANG_="$2"; shift 2;; --script) SCRIPT="$2"; shift 2;;
    --round) ROUND="$2"; shift 2;; --export) EXPORT="$2"; shift 2;; --previous) PREVIOUS="$2"; shift 2;;
    --workbook) WORKBOOK="$2"; shift 2;; --verdict) VERDICT="$2"; shift 2;; --client) CLIENT="$2"; shift 2;;
    --model) MODEL="$2"; shift 2;; --primary) PRIMARY="$2"; shift 2;;
    *) echo "adversary: unknown argument $1" >&2; return 2;; esac; done
  local v f
  for v in PROJECT LANG_ EXPORT WORKBOOK VERDICT; do
    [ -n "${!v}" ] || { echo "adversary: missing --$(echo "${v%_}" | tr '[:upper:]' '[:lower:]')" >&2; return 2; }
  done
  for f in "$EXPORT" "$WORKBOOK" "$VERDICT" ${PREVIOUS:+"$PREVIOUS"}; do
    [ -f "$f" ] || { echo "adversary: no such file: $f" >&2; return 2; }
  done

  if [ -z "$CLIENT" ]; then
    for f in codex agy kimi; do command -v "$f" >/dev/null 2>&1 && { CLIENT="$f"; break; }; done
  fi
  [ -n "$CLIENT" ] && command -v "$CLIENT" >/dev/null 2>&1 || {
    echo "no cross-family client on PATH (looked for codex, agy, kimi) — the round stays UNREVIEWED:" \
         "say so in the verdict; CRITICAL/HIGH workbooks do not ship as GO" >&2; return 3; }

  ensure_py
  PYTHONPATH="$HERE" "$PY" -c 'import openpyxl' >/dev/null   # the venv must exist BEFORE the sandboxed client runs
  local SKILL_DIR OUTDIR WORK NAME_PREFIX
  SKILL_DIR="$(cd "$HERE/../skills/survey-translation-qa" 2>/dev/null && pwd || echo "")"
  OUTDIR="$(cd "$(dirname "$WORKBOOK")" && pwd)"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/stqa-adv.XXXXXX")"
  cp "$EXPORT" "$WORK/export.xlsx"; cp "$WORKBOOK" "$WORK/primary_workbook.xlsx"
  cp "$VERDICT" "$WORK/primary_verdict.txt"
  [ -n "$PREVIOUS" ] && cp "$PREVIOUS" "$WORK/previous_export.xlsx"
  NAME_PREFIX="${PROJECT}_${LANG_}_QA_Adversarial_R${ROUND}_"

  cat > "$WORK/PROMPT.md" <<EOF
You are the adversarial reviewer for a survey translation QA round. Your job is to break the
attached corrections workbook, not to redo the review. Read the skill at
  ${SKILL_DIR:-<skill directory unavailable — ask the operator>}/SKILL.md
and follow references/adversarial-review.md in that directory exactly (also read
references/workbook-contract.md).

Inputs (this directory): export.xlsx$( [ -n "$PREVIOUS" ] && echo ", previous_export.xlsx (the round before)" ), primary_workbook.xlsx, primary_verdict.txt.
Language: $LANG_ (script key: $SCRIPT). Round: R$ROUND. Primary model: $PRIMARY. You are a
different model family — state your exact model name.

Run every check through this entry point (openpyxl is already installed; you have no network):
  bash $HERE/stqa.sh integrity export.xlsx --script $SCRIPT
  bash $HERE/stqa.sh simulate export.xlsx --workbook primary_workbook.xlsx --out patched.xlsx --script $SCRIPT$( [ -n "$PREVIOUS" ] && printf '\n  bash %s/stqa.sh verify previous_export.xlsx export.xlsx --workbook primary_workbook.xlsx --script %s' "$HERE" "$SCRIPT" )
  bash $HERE/stqa.sh selfcheck        # optional: proves the builders before you use them

Steps: reproduce the numbers; simulate the apply; attack every proposal as text; read the whole
export for misses; dispute severities both ways; attack each claim in the verdict; audit the contract.

Deliver, in this directory:
  ${NAME_PREFIX}<your-model>.xlsx   — build it with stqa_adversarial.AdvBook via
                                       \`bash $HERE/stqa.sh py <your script>\`. It refuses to save a
                                       file where a primary row has no verdict, a value cell holds
                                       prose, an Argument hedges, or a cell is in a font that cannot
                                       draw the target script.
  ADVERSARY_SUMMARY.md              — ≤200 words: counts per verdict → the three most consequential
                                       findings → whether the primary's GO/NO-GO survives.
Exact values only in "Adversary Proposed"; evidence first in "Argument". Do not soften findings; do
not invent findings to look busy — an all-CONFIRM file with reproduced numbers is a valid result.
EOF

  echo "adversary: $CLIENT${MODEL:+ ($MODEL)} · workdir $WORK" >&2
  case "$CLIENT" in
    codex) codex exec --skip-git-repo-check -C "$WORK" -s workspace-write ${MODEL:+-m "$MODEL"} \
             -o "$WORK/last-message.txt" "$(cat "$WORK/PROMPT.md")" 2>&1 | tee "$WORK/client.log" >&2 ;;
    agy)   ( cd "$WORK" && agy ${MODEL:+--model "$MODEL"} -p "$(cat PROMPT.md)" \
             --dangerously-skip-permissions > last-message.txt ) ;;
    kimi)  ( cd "$WORK" && kimi -p "$(cat PROMPT.md)" > last-message.txt ) ;;
    *) echo "adversary: unsupported client: $CLIENT" >&2; return 2 ;;
  esac

  local OUT MODEL_ID FINAL
  OUT="$(ls "$WORK"/"${NAME_PREFIX}"*.xlsx 2>/dev/null | head -1 || true)"
  [ -n "$OUT" ] || { echo "client finished without the adversarial file — see $WORK/last-message.txt;" \
                          "the round stays UNREVIEWED" >&2; return 4; }
  # The file is named after the model the CLIENT reports, not after what the model calls itself
  # (first end-to-end run: the log said `model: gpt-6-astra`, the model signed its file "GPT-6").
  MODEL_ID="$MODEL"
  [ -z "$MODEL_ID" ] && [ -f "$WORK/client.log" ] && MODEL_ID="$(sed -n 's/^model:[[:space:]]*//p' "$WORK/client.log" | head -1)"
  [ -z "$MODEL_ID" ] && MODEL_ID="$(basename "${OUT%.xlsx}")" && MODEL_ID="${MODEL_ID#"$NAME_PREFIX"}"
  MODEL_ID="$(printf '%s' "$MODEL_ID" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-*$//')"
  FINAL="$OUTDIR/${NAME_PREFIX}${MODEL_ID}.xlsx"
  cp "$OUT" "$FINAL"
  [ -f "$WORK/ADVERSARY_SUMMARY.md" ] && cp "$WORK/ADVERSARY_SUMMARY.md" "${FINAL%.xlsx}.summary.md"
  echo "adversary model (as reported by $CLIENT): $MODEL_ID" >&2
  echo "$FINAL"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  integrity|diff|verify|simulate) ensure_py; run "$HERE/stqa_checks.py" "$cmd" "$@" ;;
  reconcile)                      ensure_py; run "$HERE/stqa_reconcile.py" "$@" ;;
  fonts)                          ensure_py; run "$HERE/stqa_fonts.py" "$@" ;;
  selfcheck)                      ensure_py; run "$HERE/stqa_selfcheck.py" "$@" ;;
  py)                             ensure_py; run "$@" ;;
  adversary)                      adversary "$@" ;;
  ""|-h|--help)                   sed -n '2,19p' "$0" ;;
  *) echo "unknown command: $cmd — try: integrity diff verify simulate reconcile adversary fonts selfcheck py" >&2
     exit 2 ;;
esac
