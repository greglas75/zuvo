#!/usr/bin/env bash
# judge.sh <label> --source or|cli [--judge-model <id>]
#
# Scores ONE reviewer's findings on every corpus packet: each finding becomes REAL or
# FALSE_POSITIVE plus a defect slug from the packet's shared vocabulary. Appends to
# $BENCH_HOME/judge2/verdicts-<label>.tsv and skips packets that already have verdicts, so a
# re-run only judges what is missing.
#
#   --source or   findings in or/raw/<SAFE>-{ok,fail}-<id>.txt   (bench-or.py)
#   --source cli  findings in subs/<label>-<id>.out              (run-lane.sh, driver-wrapped)
#   --judge-model judge CLI model (default claude-opus-5). Every judge answer is cached under
#                 judge2/raw/<judge-model>/ BEFORE it is parsed, and a cached answer with at least
#                 one valid row is reused instead of a new (paid) call.
#
# Env: BENCH_HOME (default ~/.zuvo/bench), BENCH_JUDGE_CLI (default `claude`; tests stub it).
#
# Each rule below was a corrupted measurement first:
#  - The findings file is matched EXACTLY. `$SAFE-*-$id` + `head -1` picked a neighbouring label
#    (aion-3.5 → aion-3.5-mini-ok-…, mercury-2.5 → mercury-2.5-preview-…), alphabetically first.
#  - "Clean" means no finding at all. An answer that lists findings and then ends with
#    "NO ISSUES FOUND." was skipped whole — 9 packets in 6 labels were never judged (2026-10-05).
#    A finding is a `SEVERITY:` line OR a line that LEADS with CRITICAL/WARNING (`**CRITICAL …`,
#    `[WARNING]`, `- CRITICAL:` — nemotron writes no SEVERITY header at all).
#  - A judge call that exits non-zero, or answers without one valid row, never overwrites the cache
#    and never becomes a verdict; a valid row has verdict REAL|FALSE_POSITIVE and, when REAL, a slug.
#  - The vocabulary is cut to the packet; the whole file lets the judge pin a slug from another diff.
#  - Rows are filtered with awk, never `grep -P` (BSD grep in a script passes zero rows silently).
#  - Every scripted `claude -p` runs with an empty, strict MCP config: without it each call starts
#    the owner's MCP servers and orphans them (~30 GB on 2026-09-23).
set -uo pipefail

usage() { echo "usage: judge.sh <label> --source or|cli [--judge-model <id>]" >&2; exit 2; }
LABEL="${1:-}"; [ -n "$LABEL" ] || usage; shift
SOURCE=""; JUDGE_MODEL="claude-opus-5"
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage                      # a flag without its value (shift 2 would not move)
  case "$1" in
    --source) SOURCE="$2"; shift 2 ;;
    --judge-model) JUDGE_MODEL="$2"; shift 2 ;;
    *) usage ;;
  esac
done
case "$SOURCE" in or|cli) ;; *) usage ;; esac
# the judge model names a cache directory — plain id characters only, no path
case "$JUDGE_MODEL" in ''|*[!A-Za-z0-9._-]*|.*) echo "judge.sh: bad --judge-model '$JUDGE_MODEL'" >&2; exit 2 ;; esac

D="${BENCH_HOME:-$HOME/.zuvo/bench}"; PKG="$D/judge2"
JUDGE_CLI="${BENCH_JUDGE_CLI:-claude}"
[ -d "$PKG" ] || { echo "judge.sh: no corpus at $PKG (set BENCH_HOME)" >&2; exit 2; }
[ -f "$PKG/DEFECT_VOCAB.md" ] || { echo "judge.sh: missing $PKG/DEFECT_VOCAB.md" >&2; exit 2; }
command -v "$JUDGE_CLI" >/dev/null 2>&1 || { echo "judge.sh: judge CLI '$JUDGE_CLI' not on PATH" >&2; exit 2; }

# A label may carry a vendor slash (meta/muse-spark-1.3); every file path goes through SAFE,
# otherwise "err-meta/..." is a missing DIRECTORY and bash skips the command without an error.
SAFE=$(printf '%s' "$LABEL" | tr '/' '_')
OUT="$PKG/verdicts-$SAFE.tsv"
RAW="$PKG/raw/$JUDGE_MODEL"; mkdir -p "$RAW/rejected"
[ -f "$OUT" ] || printf 'input\tmodel\tseverity\tverdict\tdefect_id\tnew_slug\treason\n' > "$OUT"

# one judge per label at a time: two runs would both see a packet as missing and append it twice
# The lock holds the owner's PID, so a run killed with -9 does not block the label forever.
LOCK="$PKG/.lock-$SAFE"
if ! mkdir "$LOCK" 2>/dev/null; then
  owner=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
    echo "judge.sh: reclaiming stale lock of dead PID $owner" >&2
    rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null \
      || { echo "judge.sh: lock $LOCK busy" >&2; exit 3; }
  else
    echo "judge.sh: another judge.sh (PID ${owner:-?}) is running for $LABEL" >&2; exit 3
  fi
fi
echo $$ > "$LOCK/pid"
trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null' EXIT

findings_file() {  # $1 = packet id → path of this label's answer, or nothing
  case "$SOURCE" in
    or)  local g; for g in ok fail; do
           [ -f "$D/or/raw/$SAFE-$g-$1.txt" ] && { echo "$D/or/raw/$SAFE-$g-$1.txt"; return; }
         done ;;
    cli) [ -f "$D/subs/$LABEL-$1.out" ] && echo "$D/subs/$LABEL-$1.out" ;;
  esac
}

FINDING_RE='SEVERITY[*[:space:]]*:|^[[:space:]>*#_-]*\[?(CRITICAL|WARNING)\]?([*[:space:]:-]|$)'
has_findings() { grep -qiE "$FINDING_RE" "$1"; }

# clean = no finding at all AND (an explicit "no issues" answer, or too short to hold a finding)
is_clean() {
  local f="$1" bytes
  has_findings "$f" && return 1
  bytes=$(wc -c < "$f" | tr -d ' ')
  [ "$bytes" -lt 120 ] && return 0
  grep -qiE '^[[:space:]]*NO ISSUES FOUND' "$f"
}

# a valid verdict row: severity, REAL|FALSE_POSITIVE, a slug when REAL, new_slug, reason
parse() { awk -F'\t' 'NF>=5 && $1 !~ /^[[:space:]]*(severity|===)/ && ($2=="FALSE_POSITIVE" || ($2=="REAL" && $3!="" && $3!="-"))' "$1"; }
invalid_rows() { awk -F'\t' 'NF>=5 && $1 !~ /^[[:space:]]*(severity|===)/ && !($2=="FALSE_POSITIVE" || ($2=="REAL" && $3!="" && $3!="-"))' "$1" | wc -l | tr -d ' '; }

judged=0; skipped=0; missing=0
for dir in "$PKG"/*/; do
  id=$(basename "$dir")
  case "$id" in [0-9]*-[0-9]*) ;; *) continue ;; esac
  [ -f "$dir/CODE.diff" ] || continue
  if awk -F'\t' -v id="$id" '$1==id {found=1; exit} END {exit !found}' "$OUT"; then continue; fi
  f=$(findings_file "$id")
  if [ -z "$f" ] || [ ! -s "$f" ]; then echo "[brak] $id"; missing=$((missing+1)); continue; fi
  if is_clean "$f"; then echo "[czysty/pusty] $id ($(wc -c < "$f" | tr -d ' ')B)"; skipped=$((skipped+1)); continue; fi

  vocab=$(awk -v id="$id" '$0 ~ "^## "id" " {p=1;next} p&&/^## /{exit} p&&/^[[:space:]]*- /{print}' "$PKG/DEFECT_VOCAB.md")
  prompt="Jesteś niezależnym sędzią. Oceniasz findings jednego recenzenta wobec DIFFA.

Dla KAŻDEGO findingu wypisz DOKŁADNIE jeden wiersz TSV:
severity<TAB>verdict<TAB>defect_id<TAB>new_slug<TAB>powód (jedno zdanie)

verdict: REAL albo FALSE_POSITIVE.
REAL = defekt istnieje w tym diffie i twierdzenie o nim jest prawdziwe.
FALSE_POSITIVE = nie istnieje, dotyczy kodu spoza diffa, albo twierdzenie jest fałszywe.

defect_id: jeśli defekt JEST na liście poniżej, użyj TEGO slugu i wpisz new_slug=reused.
Jeśli defektu NIE MA na liście, wymyśl nowy kebab-case slug i wpisz new_slug=new.
Dla FALSE_POSITIVE wpisz defect_id=- oraz new_slug=-.

Istniejące slugi dla tego pakietu:
$vocab

Bez preambuły, bez podsumowania, bez bloków kodu. Tylko wiersze TSV.

=== DIFF ===
$(cat "$dir/CODE.diff")

=== FINDINGS DO OCENY ===
$(cat "$f")"

  rawf="$RAW/$SAFE-$id.txt"
  if [ -s "$rawf" ] && [ -n "$(parse "$rawf")" ]; then
    echo "[z dysku] $id"
  else
    echo "[sędzia] $id"
    jrc=0
    "$JUDGE_CLI" --model "$JUDGE_MODEL" --strict-mcp-config --mcp-config '{"mcpServers":{}}' -p "$prompt" \
      > "$rawf.tmp" 2>"$PKG/err-$SAFE-$id.log" || jrc=$?
    if [ "$jrc" -ne 0 ] || [ -z "$(parse "$rawf.tmp")" ]; then
      rej="$RAW/rejected/$SAFE-$id.$(date +%s).txt"; mv "$rawf.tmp" "$rej"
      echo "  !! judge returned no TSV row for $id (exit $jrc) — kept in $rej, stderr in $PKG/err-$SAFE-$id.log: $(head -c 160 "$rej" | tr '\n' ' ')" >&2
      continue
    fi
    mv "$rawf.tmp" "$rawf"
  fi
  bad=$(invalid_rows "$rawf")
  [ "$bad" = "0" ] || echo "  !! $id: $bad judge row(s) dropped — verdict not REAL|FALSE_POSITIVE or REAL without a slug" >&2
  # one append per packet: the resume check treats any row of a packet as "judged"
  rows=$(parse "$rawf" | awk -F'\t' -v id="$id" -v m="$LABEL" '{ print id "\t" m "\t" $0 }')
  printf '%s\n' "$rows" >> "$OUT"
  judged=$((judged+1))
done
n_rows=$(( $(wc -l < "$OUT") - 1 ))
n_packets=$(awk -F'\t' 'NR>1{print $1}' "$OUT" | sort -u | wc -l | tr -d ' ')
echo "GOTOWE $LABEL: $n_rows werdyktów, $n_packets wsadów (ten przebieg: ocenione $judged, czyste $skipped, brak odpowiedzi $missing)"
