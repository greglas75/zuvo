# shellcheck shell=bash
# adversarial-agreement.sh — a run's findings grouped by location: lanes agreeing on the same lines predict a real defect.
# Private helpers called from adversarial-report.sh, so not in AR_REQUIRED_FNS (the modules test pins it to Main + router).

# _ar_agreement_findings <lane> <result file> — one JSON object per finding of the lane's answer, one per line:
# {lane, file, severity, id}. The JSON the answer carries is read as the counter and the ledger read it
# (result_json_text). Only an answer holding NO JSON review is read as the text format (findings_text_rows,
# which sees findings with a recordable ID only): an empty JSON review is a clean review, not a text one.
_ar_agreement_findings() {
  local lane="$1" rf="$2" rows=""
  [[ -s "$rf" ]] || return 0
  rows=$(result_json_text "$rf" | jq -cs --arg l "$lane" '
    [ .[] | objects | select((.findings | type) == "array") ] as $r
    | if ($r | length) == 0 then "no-json-review" else
        ($r[].findings[] | objects
         | {lane: $l, file: ((.file // "") | tostring), severity: ((.severity // "") | tostring),
            id: (if (.id | type) == "string" then .id else null end)})
      end' 2>/dev/null) || rows='"no-json-review"'
  if [[ "$rows" == '"no-json-review"' ]]; then
    # Ledger row columns: 6 id, 7 severity, 9 file.
    rows=$(findings_text_rows "$lane" "" "$rf" | jq -cR --arg l "$lane" \
      'split("\t") | {lane: $l, file: (.[8] // ""), severity: (.[6] // ""), id: .[5]}' 2>/dev/null) || rows=""
  fi
  [[ -z "$rows" ]] || printf '%s\n' "$rows"
  return 0
}

# _ar_agreement_group <window> — reads the finding objects on stdin, prints the agreement array: one
# {file, line_lo, line_hi, n_lanes, lanes, ids, max_severity} per group, most lanes first, then highest severity.
# The file loses any leading `./`, then only its LAST `:<line>[-<line>]` (the ledger's split_file). A file's
# findings are CHAINED: each within <window> lines of its neighbour (single linkage), so a group can span more
# than the window; a lane counts once per group. A placeholder path, no line, or a row jq cannot read is a group
# of its own — a missing location is no evidence two lanes saw the same thing. jq only: python3 may be absent.
_ar_agreement_group() {
  jq -cs --argjson w "$1" '
    def str: if . == null then "" else tostring end;
    def rank: (if type == "string" then ascii_upcase else "" end) as $s
      | {"CRITICAL": 3, "WARNING": 2, "INFO": 1}[$s] // 0;
    def placeholder: ascii_downcase | . == "" or . == "unknown" or . == "?" or . == "n/a" or . == "none";
    def where: (.file | str | sub("^\\s+"; "") | sub("\\s+$"; "") | sub("^(\\./)+"; "")) as $f
      | ($f | capture("^(?<path>.*):(?<line>[0-9]+)(?:[-\u2010-\u2015\u2212][0-9]+)?$") // {path: $f, line: null})
      | if (.path | sub("^\\s+"; "") | sub("\\s+$"; "") | placeholder) or .line == null
        then {path: .path, line: null} else {path: .path, line: (.line | tonumber)} end;
    [ .[] | objects | {lane: (.lane | str), severity: (.severity | str), id: .id}
        + (try where catch {path: "", line: null}) ] as $all
    | ([ $all[] | select(.line != null) ] | group_by(.path)
        | map(sort_by(.line)
            | reduce .[] as $x ([]; if length > 0 and ($x.line - .[-1][-1].line) <= $w
                                    then .[-1] += [$x] else . + [[$x]] end))
        | add // []) as $near
    | [ ($near + [ $all[] | select(.line == null) | [.] ])[]
        | (max_by(.severity | rank) | .severity) as $top
        | { file: .[0].path, line_lo: (map(.line) | min), line_hi: (map(.line) | max),
            n_lanes: (map(.lane) | unique | length), lanes: (map(.lane) | unique),
            ids: ([ .[].id | strings ] | unique),
            max_severity: (if ($top | rank) > 0 then ($top | ascii_upcase) else null end) } ]
    | sort_by(-.n_lanes, -((.max_severity // "") | rank), .file, (.line_lo // -1))'
}

# _ar_agreement_json <lanes left out> <out file> — the agreement array of every lane that answered (lane_ok)
# and is not among <lanes left out> (the --json document drops a lane jq could not add), written to <out file>.
# Never fails the review: a step that fails writes `null` there and says so on stderr.
_ar_agreement_json() {
  local skip="$1" out="$2" p lanes="" window
  window="$(ar_env_int ZUVO_ADV_AGREE_WINDOW 5)"
  for p in $PROVIDERS; do
    lane_ok "$p" || continue
    case " $skip " in *" $p "*) continue ;; esac
    lanes="$lanes $p"
  done
  if { for p in $lanes; do _ar_agreement_findings "$p" "$JSON_TMPDIR/result_${p}.txt"; done; } \
       | _ar_agreement_group "$window" > "$out.next" 2>/dev/null && [[ -s "$out.next" ]] \
     && mv -f "$out.next" "$out"; then
    return 0
  fi
  rm -f "$out.next"
  echo "  WARN: lane agreement could not be computed — the findings are not grouped by location this run" >&2
  printf 'null' > "$out" || true
  return 0
}

# _ar_print_agreement <agreement file> — on STDERR, after the review: the locations more than one lane raised,
# capped, most lanes first, control characters stripped (file names come from the lanes' answers). STDERR, so a
# text review's stdout and its artifact stay byte-identical. Nothing when no two lanes agree or no array.
_ar_print_agreement() {
  local lines
  lines=$(jq -r '
    if type == "array" then [ .[] | select(.n_lanes >= 2) ] else [] end
    | if length == 0 then empty else
        "AGREEMENT: \(length) location(s) raised by more than one lane — triage these first:",
        (.[:10][] | "  \(.n_lanes) lanes  \(.max_severity // "?")  \(.file):\(.line_lo)"
          + (if .line_hi != .line_lo then "-\(.line_hi)" else "" end) + "  \(.lanes | join(", "))"
          | gsub("[[:cntrl:]]"; "")),
        (if length > 10 then "  (\(length - 10) more: --json .agreement)" else empty end)
      end' "$1" 2>/dev/null) || lines=""
  [[ -z "$lines" ]] || printf '%s\n' "$lines" >&2
  return 0
}
