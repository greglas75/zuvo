# shellcheck shell=bash
# blind-audit-panel.sh — every DECISION of the adversarial driver's `--mode blind-audit`: the prompt,
# the protocol lookup, the byte gates, the per-lane timeout, the anti-echo validation of one answer, the
# merge of the panel's answers, the exit mapping, what the health ledger may learn, the --json document,
# the per-host vendor exclusion and the isolation allowlist.
# Sourced, never executed; every public function is prefixed `bap_`.
#
# Why it exists: the blind coverage audit (shared/includes/blind-coverage-audit.md) was ONE Codex
# subprocess behind blind-audit-codex.sh, with its own marker grep. It becomes a cross-vendor panel
# run by the driver (docs/specs/2026-09-25-blind-audit-panel-plan.md). The driver keeps the mechanical
# wiring (flags, dispatch, hooks); what counts as an answer and how answers combine lives HERE, in one
# place tests/hooks/test-blind-audit-panel.sh pins.
#
# Contract for everything below:
#   * bash 3.2 (macOS /bin/bash): no `declare -A`, `mapfile`, `${x,,}`. awk is POSIX (BSD + GNU) and
#     runs under LC_ALL=C, so a reply is read as bytes whatever the caller's locale.
#   * NOTHING external runs at source time — sourcing works with PATH=/nonexistent.
#   * Safe under the caller's `set -euo pipefail`: a non-zero status is the ANSWER (invalid / none /
#     too large), never a crash. Never changes the caller's shell options or traps; the only globals
#     are the _BAP_* constants below. Output goes to stdout; diagnostics to stderr, prefixed
#     `blind-audit-panel: <function>:`; bap_merge and bap_json use a private mktemp dir, which they remove.
#   * Status convention: 0 = yes / found / valid, 1 = no / none / invalid, 2 = usage error.
#
# Knobs (the first two are the byte gates — see bap_size_class):
#   ZUVO_BLIND_AUDIT_ARGV_MAX    prompt bytes above which the argv lanes (bap_argv_lanes) are left
#                                out: argv has a hard size limit, stdin does not (default 120000)
#   ZUVO_BLIND_AUDIT_MAX_BYTES   prompt bytes above which the mode refuses to dispatch (default 400000)
#   Both: digits only, leading zeros are decimal (not octal); empty = the default; zero or anything
#   else = the default with a WARN; 10+ digits are capped at 999999999 BEFORE any arithmetic, so no
#   value can wrap around to a negative limit.
#   ZUVO_BLIND_AUDIT_TIMEOUT     per-lane seconds (bap_timeout; default 480, same rules, at most 510 and
#                                at most 525 - the kill grace, so the deadline stays <= 585 s)
#   ZUVO_BLIND_AUDIT_ALLOWLIST   the lanes a run may use (bap_allowlist) — it narrows the isolated
#                                default, it can never widen it
#
# Consumers find this file sibling-first, like model-subprocess.sh: <dir>/lib/blind-audit-panel.sh
# → <dir>/blind-audit-panel.sh → $HOME/.zuvo/blind-audit-panel.sh (where install.sh ships it).

# The protocol's own strings (its "Required Output" block). The test compares all three with
# shared/includes/blind-coverage-audit.md, so an edit there that is not mirrored here fails loudly.
_BAP_HEADER='| id | kind | production lines | owned_or_delegated | coverage | test evidence | notes |'
_BAP_SEPARATOR='|----|------|------------------|--------------------|----------|---------------|-------|'
_BAP_TEMPLATE_ROW='| B1 | branch | 18-24 | owned | FULL | file.test.ts:42-58 | verifies empty guard |'
_BAP_PROMPT_TAIL='Return only the required strict output block'
_BAP_PROTOCOL_NAME='blind-coverage-audit.md'

_bap_err() { echo "blind-audit-panel: $1: $2" >&2; }

# _bap_name_ok <word> — a provider or outcome name that is safe inside the `Audit panel:` line:
# non-empty; letters, digits, `.`, `_`, `-` only (never a space, comma, colon, `=` or `|`).
_bap_name_ok() {
  local LC_ALL=C; case "${1:-}" in ''|*[![:alnum:]._-]*) return 1 ;; esac
}

# _bap_has_line <file> <line> — true when some line of <file> is exactly <line> (a trailing CR ignored).
_bap_has_line() {
  LC_ALL=C awk -v want="$2" '{ sub(/\r$/, "") } $0 == want { found = 1; exit } END { exit !found }' "$1"
}

# _bap_has_nul <file> — true when <file> holds a NUL byte, or cannot be measured (fail closed). Counted
# byte-safely — `wc -c` of the file against `wc -c` after `LC_ALL=C tr -d '\000'` — never by a shell read,
# which is exactly what cannot see a NUL.
_bap_has_nul() {
  local all kept
  all="$(wc -c < "$1")" || return 0
  kept="$(LC_ALL=C tr -d '\000' < "$1" | wc -c)" || return 0
  [ "${all//[[:space:]]/}" != "${kept//[[:space:]]/}" ]
}

# ── Protocol and prompt ───────────────────────────────────────────────────────

# bap_find_protocol <driver_dir> [--protocol <path>] — print the protocol file the panel must use:
#   1. --protocol <path>                         explicit: final, never falls through
#   2. <driver_dir>/../shared/includes/blind-coverage-audit.md — ONLY when <driver_dir>/../skills
#      exists (a real repo or plugin-cache tree). <driver_dir> is the DRIVER's directory, passed in by
#      the driver, never this library's own: scripts/lib has no ../skills, so it never qualifies.
#      Installed flat in ~/.zuvo, a bare `..` would leave the install root (zms_source_registry has
#      the same guard).
#   3. $HOME/.zuvo/blind-coverage-audit.md       shipped by install.sh
# The FIRST candidate that exists is final: it must be a readable file holding a line that is exactly
# `Audit mode: strict`, or the status is 1 — a broken repo copy is not papered over by an older
# installed one. Status 1 also when nothing exists (the reason lists where it looked); 2 = usage.
bap_find_protocol() {
  local fn=bap_find_protocol dir="${1:-}" cand="" explicit=0 root="" looked=""
  if [ -z "$dir" ]; then _bap_err "$fn" "usage: $fn <driver_dir> [--protocol <path>]"; return 2; fi
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --protocol)
        if [ $# -lt 2 ] || [ -z "$2" ]; then _bap_err "$fn" "--protocol needs a path"; return 2; fi
        cand="$2"; explicit=1; shift 2 ;;
      *) _bap_err "$fn" "unknown argument: $1"; return 2 ;;
    esac
  done
  if [ "$explicit" = 0 ]; then
    root="$(CDPATH='' cd -P -- "$dir/.." 2>/dev/null && pwd -P)" || root=""
    looked="${root:-$dir/..}/shared/includes/$_BAP_PROTOCOL_NAME (only with ${root:-$dir/..}/skills)"
    if [ -n "$root" ] && [ -d "$root/skills" ] && [ -e "$root/shared/includes/$_BAP_PROTOCOL_NAME" ]; then
      cand="$root/shared/includes/$_BAP_PROTOCOL_NAME"
    elif [ -n "${HOME:-}" ] && [ -e "$HOME/.zuvo/$_BAP_PROTOCOL_NAME" ]; then
      cand="$HOME/.zuvo/$_BAP_PROTOCOL_NAME"
    else
      if [ -n "${HOME:-}" ]; then looked="$looked, $HOME/.zuvo/$_BAP_PROTOCOL_NAME"
      else looked="$looked, ~/.zuvo (HOME is unset)"; fi
      _bap_err "$fn" "no protocol found (looked at: $looked)"
      return 1
    fi
  fi
  if [ ! -f "$cand" ] || [ ! -r "$cand" ]; then
    _bap_err "$fn" "the protocol is not a readable file: $cand"; return 1
  fi
  if ! _bap_has_line "$cand" 'Audit mode: strict'; then
    _bap_err "$fn" "the protocol has no line 'Audit mode: strict': $cand"; return 1
  fi
  printf '%s\n' "$cand"
}

# bap_build_prompt <protocol> <production> <test> — print the ONE prompt every panel lane receives:
# the protocol, then `=== PRODUCTION FILE: <basename> ===` + the file, `=== TEST FILE: <basename> ===`
# + the file, and last the line `Return only the required strict output block` — each header and the
# last line preceded by a newline, the shape Task 1's spike sent. Files go in WHOLE: no character cap,
# chunking or truncation; the byte gates decide instead, and nothing is ever shortened. Basenames only
# (no path reaches a model); no FOCUS, language or SEVERITY text. agy's no-tool-use prefix is NOT
# added here — the driver adds it for that lane alone, so every other lane's stdin is this output.
# Status 1 when a file is unreadable (stdout may then hold a partial prompt — discard it) or when the
# production or test file holds a NUL byte ("binary input", refused before anything is printed: the
# driver keeps the prompt in a bash variable, which silently drops everything from a NUL on); 2 for a
# wrong argument count or a basename holding a control character (a newline there forges a header).
bap_build_prompt() {
  local fn=bap_build_prompt f pb tb
  if [ $# -ne 3 ]; then _bap_err "$fn" "usage: $fn <protocol> <production> <test>"; return 2; fi
  for f in "$1" "$2" "$3"; do
    if [ -z "$f" ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then _bap_err "$fn" "not a readable file: '$f'"; return 1; fi
  done
  for f in "$1" "$2" "$3"; do
    if _bap_has_nul "$f"; then
      _bap_err "$fn" "binary input (a NUL byte) in '$f' — refused: a prompt cannot carry it whole"; return 1
    fi
  done
  pb="${2##*/}"; tb="${3##*/}"
  case "$pb$tb" in
    *[[:cntrl:]]*) _bap_err "$fn" "a file name holds a control character — refused"; return 2 ;;
  esac
  cat -- "$1" || return 1
  printf '\n=== PRODUCTION FILE: %s ===\n' "$pb"
  cat -- "$2" || return 1
  printf '\n=== TEST FILE: %s ===\n' "$tb"
  cat -- "$3" || return 1
  printf '\n%s\n' "$_BAP_PROMPT_TAIL"
}

# ── Byte gates ────────────────────────────────────────────────────────────────

# bap_bytes [file] — print the byte size of <file>, or of stdin without an argument. Always `wc -c`,
# never ${#var}: under a UTF-8 locale ${#var} counts CHARACTERS, so a Polish or CJK file below 120000
# characters can be far above 120000 bytes — the very argv overflow the gate exists to prevent.
# Status 1, nothing printed, when the file is unreadable.
bap_bytes() {
  local n
  if [ $# -gt 0 ]; then
    if [ ! -f "$1" ] || [ ! -r "$1" ]; then _bap_err bap_bytes "not a readable file: '$1'"; return 1; fi
    n="$(wc -c < "$1")" || return 1
  else
    n="$(wc -c)" || return 1
  fi
  n="${n//[[:space:]]/}"   # BSD wc pads the number with blanks
  case "$n" in ''|*[!0-9]*) _bap_err bap_bytes "wc -c printed no byte count: '$n'"; return 1 ;; esac
  printf '%s\n' "$n"
}

# _bap_knob <name> <value> <default> [unit] — the effective value of a numeric knob (rules in the
# header; unit defaults to bytes). Zero is refused as well: a limit of 0 bytes would reject every
# prompt, and a timeout of 0 means NO timeout to GNU timeout — both silently.
_bap_knob() {
  local name="$1" v="$2" def="$3" unit="${4:-bytes}"
  if [ -z "$v" ]; then printf '%s\n' "$def"; return 0; fi
  case "$v" in
    *[!0-9]*) _bap_err "$name" "WARN: not a whole number of $unit ('$v') — using $def"; printf '%s\n' "$def"; return 0 ;;
  esac
  v="${v#"${v%%[!0]*}"}"
  if [ -z "$v" ]; then _bap_err "$name" "WARN: 0 $unit is not a usable limit — using $def"; printf '%s\n' "$def"; return 0; fi
  case "$v" in ??????????*) v=999999999 ;; esac
  printf '%s\n' "$v"
}

# bap_argv_max / bap_max_bytes — print the effective ZUVO_BLIND_AUDIT_ARGV_MAX / _MAX_BYTES.
bap_argv_max()  { _bap_knob ZUVO_BLIND_AUDIT_ARGV_MAX "${ZUVO_BLIND_AUDIT_ARGV_MAX:-}" 120000; }
bap_max_bytes() { _bap_knob ZUVO_BLIND_AUDIT_MAX_BYTES "${ZUVO_BLIND_AUDIT_MAX_BYTES:-}" 400000; }

# _bap_secs <value> — <value> as plain decimal digits (leading zeros dropped, "" → 0), 10+ digits
# capped at 999999999 before any arithmetic; status 2 and nothing printed for anything but digits.
_bap_secs() {
  local v="${1:-}"
  case "$v" in ''|*[!0-9]*) return 2 ;; esac
  v="${v#"${v%%[!0]*}"}"
  case "$v" in '') v=0 ;; ??????????*) v=999999999 ;; esac
  printf '%s\n' "$v"
}

# The whole-run ceiling of a panel run: the skill runs the driver inside a 600 s Bash call, and the
# driver needs a few seconds after its deadline to report. bap_deadline never prints more.
_BAP_RUN_CEILING=585

# bap_run_ceiling — public accessor for _BAP_RUN_CEILING, so callers never read the private var directly.
bap_run_ceiling() { printf '%s\n' "$_BAP_RUN_CEILING"; }

# bap_timeout [grace] — print the per-lane timeout of a panel run in seconds: ZUVO_BLIND_AUDIT_TIMEOUT
# (default 480; the knob rules above; ZUVO_REVIEW_TIMEOUT never applies here), at most 510, and at most
# what keeps timeout + <grace> + 60 (bap_deadline) within the 585 s ceiling: a longer kill grace
# (ZUVO_TIMEOUT_GRACE, default 15 — the driver passes its own) buys a SHORTER per-lane timeout, never a
# later deadline. At 15 s of grace both limits are 510. Never below 1 s. When either limit lowers the
# value, ONE WARN names the effective timeout and deadline. Status 0; 2 for a non-digit grace (usage).
bap_timeout() {
  local v g cap
  if ! g="$(_bap_secs "${1:-15}")"; then _bap_err bap_timeout "usage: bap_timeout [grace-seconds], got '${1:-}'"; return 2; fi
  v="$(_bap_knob ZUVO_BLIND_AUDIT_TIMEOUT "${ZUVO_BLIND_AUDIT_TIMEOUT:-}" 480 seconds)"
  cap=$(( _BAP_RUN_CEILING - 60 - g ))   # g has at most 9 digits (_bap_secs): no overflow
  [ "$cap" -le 510 ] || cap=510
  [ "$cap" -ge 1 ] || cap=1
  if [ "$v" -gt "$cap" ]; then
    _bap_err ZUVO_BLIND_AUDIT_TIMEOUT "WARN: $v s per lane with a $g s kill grace (ZUVO_TIMEOUT_GRACE) would run past the $_BAP_RUN_CEILING s ceiling (at most 510 s per lane; the caller waits 600 s) — using $cap s per lane, whole-run deadline $(bap_deadline "$cap" "$g") s"
    v=$cap
  fi
  printf '%s\n' "$v"
}

# bap_deadline <timeout> <grace> — print the whole-run deadline of a panel run: timeout + grace + 60,
# never more than 585 (a grace so long that bap_timeout's 1 s floor cannot absorb it is cut here — the
# run then ends on the deadline, not past the caller's wait). Status 2 unless both are digits.
bap_deadline() {
  local t g d
  if [ $# -ne 2 ] || ! t="$(_bap_secs "$1")" || ! g="$(_bap_secs "$2")"; then
    _bap_err bap_deadline "usage: bap_deadline <timeout-seconds> <grace-seconds>"; return 2
  fi
  d=$(( t + g + 60 ))   # each at most 9 digits (_bap_secs): no overflow
  [ "$d" -le "$_BAP_RUN_CEILING" ] || d=$_BAP_RUN_CEILING
  printf '%s\n' "$d"
}

# bap_argv_lanes — the lanes that take the prompt as an ARGUMENT. Every other lane reads stdin or
# HTTP. Over bap_argv_max bytes the driver leaves exactly these out, with a loud stderr line.
bap_argv_lanes() { printf '%s\n' "agy kimi"; }

# bap_size_class <bytes> — classify a prompt size (from bap_bytes) against the two limits; prints:
#   ok         at most bap_argv_max bytes — every lane can take it
#   over-argv  above bap_argv_max — drop bap_argv_lanes, dispatch the rest
#   too-large  above bap_max_bytes — dispatch nothing (the driver exits 6)
# Both limits are inclusive (exactly the limit is still under it). Status 2 unless <bytes> is digits;
# leading zeros are decimal; 10+ digits are over any possible limit without arithmetic.
bap_size_class() {
  local b="${1:-}" max argv
  case "$b" in ''|*[!0-9]*) _bap_err bap_size_class "usage: bap_size_class <bytes> (digits), got '$b'"; return 2 ;; esac
  b="${b#"${b%%[!0]*}"}"
  case "$b" in
    '') b=0 ;;
    ??????????*) printf 'too-large\n'; return 0 ;;
  esac
  max="$(bap_max_bytes)"; argv="$(bap_argv_max)"
  if [ "$b" -gt "$max" ]; then printf 'too-large\n'
  elif [ "$b" -gt "$argv" ]; then printf 'over-argv\n'
  else printf 'ok\n'; fi
}

# ── One answer ────────────────────────────────────────────────────────────────

# bap_validate <reply-file> — decide whether one lane's reply is a strict audit block; print the
# cleaned block and return 0 when it is, print nothing and return 1 (the reason on stderr) when not;
# status 2 for a missing or unreadable file.
# Cleaning: the block starts at the FIRST line that is exactly `Audit mode: strict` — a banner before
# it (agy's `[agy] fallback model: …`) is dropped; fence lines (``` or ```<word>, cursor-agent's
# ```text wrapper) are dropped; trailing blanks, CRs and trailing empty lines are removed. Cleaning a
# cleaned block changes nothing, so bap_merge can validate again.
# Valid needs, anchored per line: `Coverage verdict: (CLEAN|FIX|REWRITE)` (repeats must agree),
# `INVENTORY COMPLETE: <digits> rows`, and the protocol's exact table header. An ECHO is refused
# even when it would otherwise pass: the protocol's literal `Coverage verdict: CLEAN|FIX|REWRITE`,
# its example row (compared cell by cell, so re-spacing does not hide it) and the prompt's own
# `=== PRODUCTION FILE:` / `=== TEST FILE:` headers are never part of an answer.
bap_validate() {
  local fn=bap_validate
  if [ $# -ne 1 ] || [ -z "$1" ]; then _bap_err "$fn" "usage: $fn <reply-file>"; return 2; fi
  if [ ! -f "$1" ] || [ ! -r "$1" ]; then _bap_err "$fn" "not a readable file: '$1'"; return 2; fi
  LC_ALL=C awk -v hdr="$_BAP_HEADER" -v tpl="$_BAP_TEMPLATE_ROW" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function cells(s, c) { sub(/^\|/, "", s); sub(/\|$/, "", s); return split(s, c, "|") }
    function is_template(s,   c, i) {
      if (s !~ /^\|/ || cells(s, c) != 7) return 0
      for (i = 1; i <= 7; i++) if (trim(c[i]) != tp[i]) return 0
      return 1
    }
    function reject(why) { if (bad == "") bad = why }
    BEGIN { cells(tpl, tp); for (i = 1; i <= 7; i++) tp[i] = trim(tp[i]) }
    { sub(/[ \t\r]+$/, "") }
    !started { if ($0 != "Audit mode: strict") next; started = 1 }
    /^```[A-Za-z0-9_+-]*$/ { next }
    {
      line[++n] = $0
      if ($0 == "Coverage verdict: CLEAN|FIX|REWRITE") reject("it echoes the verdict template of the protocol")
      else if ($0 ~ /^Coverage verdict: (CLEAN|FIX|REWRITE)$/) {
        if (verdict == "") verdict = $0
        else if ($0 != verdict) reject("conflicting verdict lines")
      }
      if ($0 ~ /^INVENTORY COMPLETE: [0-9]+ rows$/) inventory = 1
      if ($0 == hdr) header = 1
      if (is_template($0)) reject("it contains the example row of the protocol")
      if ($0 ~ /^=== (PRODUCTION|TEST) FILE: /) reject("it echoes the file headers of the prompt")
    }
    END {
      if (!started) reject("no line is exactly \"Audit mode: strict\"")
      else if (verdict == "") reject("no line matches ^Coverage verdict: (CLEAN|FIX|REWRITE)$")
      else if (!inventory) reject("no line matches ^INVENTORY COMPLETE: [0-9]+ rows")
      else if (!header) reject("the exact table header is missing")
      if (bad != "") { print "blind-audit-panel: bap_validate: invalid reply: " bad > "/dev/stderr"; exit 1 }
      while (n > 0 && line[n] == "") n--
      for (i = 1; i <= n; i++) print line[i]
    }' "$1"
}

# ── The panel ─────────────────────────────────────────────────────────────────

# bap_merge [--failed <provider>:<outcome>]... <provider>=<reply-file>... — print the panel's ONE
# strict block:
#   Audit mode: strict
#   Audit panel: strict|degraded valid=<k>/<m> providers=<a,b> verdicts=<a:FIX,b:CLEAN>[ failed=<c:timeout,…>]
#   Coverage verdict: <the worst valid verdict: REWRITE > FIX > CLEAN>
#   INVENTORY COMPLETE: <the largest count reported> rows
#   <blank>, the exact table header and separator, then every row whose coverage is not FULL / N/A
#   (bold, code and case ignored) from every valid answer: id prefixed `<provider>:`, notes suffixed
#   `[<provider>]` — rows are never guessed to be "the same" across providers
#   <blank>, `Prioritized findings`, then `[<provider>]` + that provider's own text for each valid one
#   <blank>, `Highest-value missing test`, the same way; a provider without the section → `(none)`
# How providers are passed: a lane that ANSWERED is `<provider>=<reply-file>` — the file is validated
# here again (bap_validate), and one that fails counts as `<provider>:invalid`; a lane that did NOT
# answer is `--failed <provider>:<outcome>` (timeout, auth, empty, …). m = every provider named,
# k = the valid ones; `strict` needs k >= 2, k = 1 is `degraded`. Every list keeps ARGUMENT order, so
# the same arguments print the same bytes. Names: letters, digits, `.`, `_`, `-`, each at most once.
# The table runs from the header to the first NON-blank line not starting with `|`: a blank line
# or a repeated header+separator inside it does not cut it short. A row with fewer than 7 cells is
# padded with empty cells; a cell holding `|` shifts the ones after it — extra cells rejoin the notes.
# Status 0 printed; 1 no valid answer (stdout EMPTY); 2 usage or no temp dir (nothing printed).
# A subshell function: its temp dir and traps never touch the caller's.
bap_merge() (
  fn=bap_merge; seen=" "; want=""
  if [ $# -eq 0 ]; then _bap_err "$fn" "usage: $fn [--failed <provider>:<outcome>]... <provider>=<file>..."; exit 2; fi
  for a in "$@"; do   # pass 1, syntax only: a usage error prints nothing and validates nothing
    if [ "$want" = failed ]; then
      n="${a%%:*}"; want=""
      if [ "$n" = "$a" ] || ! _bap_name_ok "$n" || ! _bap_name_ok "${a#*:}"; then
        _bap_err "$fn" "--failed wants <provider>:<outcome>, got '$a'"; exit 2
      fi
    else
      case "$a" in
        --failed) want=failed; continue ;;
        *=*) n="${a%%=*}"
             if ! _bap_name_ok "$n" || [ -z "${a#*=}" ]; then _bap_err "$fn" "want <provider>=<file>, got '$a'"; exit 2; fi ;;
        *) _bap_err "$fn" "want <provider>=<file> or --failed <provider>:<outcome>, got '$a'"; exit 2 ;;
      esac
    fi
    case "$seen" in *" $n "*) _bap_err "$fn" "provider named twice: $n"; exit 2 ;; esac
    seen="$seen$n "
  done
  if [ -n "$want" ]; then _bap_err "$fn" "--failed needs <provider>:<outcome>"; exit 2; fi

  base="${TMPDIR:-/tmp}"
  if ! tmp="$(mktemp -d "${base%/}/bap.XXXXXX")"; then _bap_err "$fn" "cannot create a temp dir under $base"; exit 2; fi
  trap 'rm -rf "$tmp"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  names=""; failed=""; m=0; k=0; want=""
  for a in "$@"; do   # pass 2, in argument order
    if [ "$want" = failed ]; then failed="${failed:+$failed,}$a"; m=$((m + 1)); want=""; continue; fi
    if [ "$a" = --failed ]; then want=failed; continue; fi
    m=$((m + 1))
    if bap_validate "${a#*=}" > "$tmp/$((k + 1))"; then
      k=$((k + 1)); names="${names:+$names }${a%%=*}"
    else
      failed="${failed:+$failed,}${a%%=*}:invalid"
    fi
  done
  [ "$k" -gt 0 ] || exit 1
  set --
  i=1
  while [ "$i" -le "$k" ]; do set -- "$@" "$tmp/$i"; i=$((i + 1)); done
  LC_ALL=C awk -v names="$names" -v m="$m" -v failed="$failed" \
      -v hdr="$_BAP_HEADER" -v sep="$_BAP_SEPARATOR" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    # The section a line opens ("pf" / "hv") or "". Tolerates "## ", "- ", "1. ", bold, code and a
    # colon; text after the title on the SAME line is kept (sets the global `rest`).
    function section(s,   t, low, r, key) {
      t = s
      sub(/^[ \t]*(#+[ \t]*)?([-+][ \t]+)?([0-9]+[.)][ \t]*)?[*_`]*[ \t]*/, "", t)
      low = tolower(t)
      if (index(low, "prioritized findings") == 1) { r = substr(t, 21); key = "pf" }
      else if (index(low, "highest-value missing test") == 1) { r = substr(t, 27); key = "hv" }
      else return ""
      if (r != "" && r ~ /^[ \t]*[A-Za-z0-9]/) return ""
      sub(/^[*_`]*[ \t]*:?[ \t]*[*_]*[ \t]*/, "", r)
      rest = r
      return key
    }
    function append(f, key, s) { sec[f, key] = ((f, key) in sec) ? sec[f, key] "\n" s : s }
    function add_row(s, p,   c, k, i, cov, notes) {
      sub(/^\|/, "", s); sub(/\|$/, "", s)
      k = split(s, c, "|")   # a short row: the missing cells read as "" — padded, not shifted
      notes = c[7]
      for (i = 8; i <= k; i++) notes = notes "|" c[i]
      for (i = 1; i <= 6; i++) c[i] = trim(c[i])
      notes = trim(notes)
      cov = toupper(c[5]); gsub(/[*`]/, "", cov); cov = trim(cov)
      if (cov == "FULL" || cov == "N/A") return
      if (notes != "") notes = notes " "
      rows[++nrows] = "| " p ":" c[1] " | " c[2] " | " c[3] " | " c[4] " | " c[5] " | " c[6] " | " notes "[" p "] |"
    }
    function take_inventory(s) {   # compared as digit strings: no float rounding, no overflow
      sub(/^INVENTORY COMPLETE: /, "", s); sub(/[^0-9].*$/, "", s); sub(/^0+/, "", s)
      if (s == "") s = "0"
      if (length(s) > length(maxinv) || (length(s) == length(maxinv) && (s "") > (maxinv ""))) maxinv = s
    }
    function print_section(title, key,   f, x) {
      print title
      for (f = 1; f <= np; f++) {
        print "[" name[f] "]"
        x = ((f, key) in sec) ? sec[f, key] : ""
        sub(/^\n+/, "", x); sub(/\n+$/, "", x)
        if (x == "") x = "(none)"
        print x
      }
    }
    BEGIN { np = split(names, name, " "); maxinv = "0" }
    FNR == 1 { f++; intab = 0; tabdone = 0; cur = "" }
    {
      if (verdict[f] == "" && $0 ~ /^Coverage verdict: (CLEAN|FIX|REWRITE)$/) { verdict[f] = substr($0, 19); next }
      if ($0 ~ /^INVENTORY COMPLETE: [0-9]+ rows$/) { take_inventory($0); next }
      if (intab) {   # blank lines inside the table do not end it; the first other non-pipe line does
        if ($0 ~ /^\|/) { if ($0 != hdr && $0 !~ /^\|[-:| \t]+$/) add_row($0, name[f]); next }
        if ($0 == "") next
        intab = 0; tabdone = 1
      }
      if (!tabdone && $0 == hdr) { intab = 1; next }
      sk = section($0)
      if (sk != "") { cur = sk; if (rest != "") append(f, cur, rest); next }
      if (cur != "") append(f, cur, $0)
    }
    END {
      worst = 1
      for (j = 1; j <= np; j++) {
        r = (verdict[j] == "REWRITE") ? 3 : ((verdict[j] == "FIX") ? 2 : 1)
        if (r > worst) worst = r
        plist = plist (j > 1 ? "," : "") name[j]
        vlist = vlist (j > 1 ? "," : "") name[j] ":" verdict[j]
      }
      status = "Audit panel: " (np >= 2 ? "strict" : "degraded") " valid=" np "/" m " providers=" plist " verdicts=" vlist
      if (failed != "") status = status " failed=" failed
      print "Audit mode: strict"
      print status
      print "Coverage verdict: " ((worst == 3) ? "REWRITE" : ((worst == 2) ? "FIX" : "CLEAN"))
      print "INVENTORY COMPLETE: " maxinv " rows"
      print ""
      print hdr
      print sep
      for (j = 1; j <= nrows; j++) print rows[j]
      print ""
      print_section("Prioritized findings", "pf")
      print ""
      print_section("Highest-value missing test", "hv")
    }' "$@"
)

# bap_exit_code <valid_count> — print the driver's exit status for a panel with <valid_count> valid
# answers: >= 2 → 0 (strict), 1 → 3 (degraded), 0 → 2 (no valid answer). Printed, not returned, so
# `exit "$(bap_exit_code "$k")"` stays safe under `set -e`. Digits only (leading zeros decimal),
# else status 2 and nothing printed.
bap_exit_code() {
  local k="${1:-}"
  case "$k" in ''|*[!0-9]*) _bap_err bap_exit_code "usage: bap_exit_code <valid_count> (digits), got '$k'"; return 2 ;; esac
  k="${k#"${k%%[!0]*}"}"
  case "$k" in
    '') printf '2\n' ;;
    1)  printf '3\n' ;;
    *)  printf '0\n' ;;
  esac
}

# bap_ledger_outcomes <outcomes> — the part of the driver's outcome list (`a:ok,b:invalid,c:auth`) the
# persistent provider-health ledger may learn from a panel run: `ok`, `auth` and `quota` describe the
# lane's ACCOUNT and hold for every mode; `timeout`, `empty` and `invalid` (and anything else) describe
# THIS input or prompt — a huge file pair or a protocol a model misreads must not bench a lane that
# reviews code fine. Prints the kept entries comma-joined in their order (nothing when none). Status 0.
bap_ledger_outcomes() {
  printf '%s' "${1:-}" | LC_ALL=C awk 'BEGIN { RS = ","; ORS = "" } { sub(/\n$/, ""); sub(/\r$/, "") }
    /^[A-Za-z0-9._-]+:(ok|auth|quota)$/ { printf "%s%s", (n++ ? "," : ""), $0 } END { if (n) printf "\n" }'
}

# bap_uncovered_rows <merged-block> <provider> — print how many table rows of a bap_merge block that
# provider contributed (rows whose id is `<provider>:…`): the number of gaps it found, which the driver
# logs as the lane's findings (a lane with no valid answer contributed none: 0). Status 2 for a missing
# file or a bad provider name.
bap_uncovered_rows() {
  if [ $# -ne 2 ] || ! _bap_name_ok "$2"; then _bap_err bap_uncovered_rows "usage: bap_uncovered_rows <merged-block> <provider>"; return 2; fi
  if [ ! -f "$1" ] || [ ! -r "$1" ]; then _bap_err bap_uncovered_rows "not a readable file: '$1'"; return 2; fi
  LC_ALL=C awk -v hdr="$_BAP_HEADER" -v pre="| $2:" '
    $0 == hdr { t = 1; next } t && $0 == "" { exit } t && index($0, pre) == 1 { n++ } END { print n + 0 }' "$1"
}

# bap_json <status> <valid> <outcomes> <prompt-bytes> <argv-lanes> [<merged-block> [<provider>=<reply>]...]
# — print the driver's --json document for a panel run:
#   {status, mode: "blind-audit", verdict, valid_providers[], provider_outcomes, prompt_bytes,
#    excluded_argv_lanes[], merged_block, results{}}
# <status> exactly one of strict|degraded|none|timeout|suspended; <valid> and <argv-lanes> space-separated
# lane lists (may be empty); <outcomes> the driver's `a:ok,b:invalid` string, kept as a string like the
# other modes'; <merged-block> the bap_merge output file — "" or left out when nothing merged (then
# verdict null, merged_block ""); each <provider>=<reply> a lane that ANSWERED, valid or not, named at
# most once — its raw reply lands in results. Every file travels through jq's stdin or --rawfile, never
# argv: a reply can echo a 400 kB prompt, far past Linux's 128 kB per-argument limit. Every argument is
# checked BEFORE jq is needed, so a usage error is status 2 on any machine; without jq, status 2 too
# ("jq is required" — the driver itself exits 1 without it). Status 2 also when no temp dir.
bap_json() (
  fn=bap_json; seen=" "
  if [ $# -lt 5 ]; then _bap_err "$fn" "usage: $fn <status> <valid> <outcomes> <prompt-bytes> <argv-lanes> [<merged-block> [<provider>=<reply>]...]"; exit 2; fi
  case "$1" in strict|degraded|none|timeout|suspended) ;;
    *) _bap_err "$fn" "status must be strict|degraded|none|timeout|suspended, got '$1'"; exit 2 ;; esac
  case "$4" in ''|*[!0-9]*) _bap_err "$fn" "prompt bytes must be digits, got '$4'"; exit 2 ;; esac
  merged="${6:-/dev/null}"
  if [ ! -r "$merged" ]; then _bap_err "$fn" "not a readable block: '$merged'"; exit 2; fi
  st="$1" valid="$2" outcomes="$3" bytes="${4#"${4%%[!0]*}"}" argv="$5"; shift 5; [ $# -eq 0 ] || shift
  for a in "$@"; do   # names are [alnum._-] (checked), so they need no JSON escaping
    n="${a%%=*}"
    if [ "$n" = "$a" ] || ! _bap_name_ok "$n" || [ ! -r "${a#*=}" ]; then _bap_err "$fn" "want <provider>=<readable reply>, got '$a'"; exit 2; fi
    case "$seen" in *" $n "*) _bap_err "$fn" "provider named twice: $n"; exit 2 ;; esac
    seen="$seen$n "
  done
  command -v jq >/dev/null 2>&1 || { _bap_err "$fn" "jq is required (the driver itself exits 1 without it)"; exit 2; }
  verdict="$(LC_ALL=C awk '{ sub(/\r$/, "") } /^Coverage verdict: (CLEAN|FIX|REWRITE)$/ { print substr($0, 19); exit }' "$merged")"
  base="${TMPDIR:-/tmp}"
  if ! tmp="$(mktemp -d "${base%/}/bap.XXXXXX")"; then _bap_err "$fn" "cannot create a temp dir under $base"; exit 2; fi
  trap 'rm -rf "$tmp"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  { printf '{'; sep=""
    for a in "$@"; do printf '%s"%s":' "$sep" "${a%%=*}"; jq -Rs . < "${a#*=}" || exit 2; sep=","; done
    printf '}\n'; } > "$tmp/results.json" || exit 2
  jq -n --arg status "$st" --arg verdict "$verdict" --arg valid "$valid" --arg outcomes "$outcomes" \
      --argjson bytes "${bytes:-0}" --arg argv "$argv" --rawfile merged "$merged" --slurpfile results "$tmp/results.json" '
    def words: split(" ") | map(select(. != ""));
    {status: $status, mode: "blind-audit", verdict: (if $verdict == "" then null else $verdict end),
     valid_providers: ($valid | words), provider_outcomes: $outcomes, prompt_bytes: $bytes,
     excluded_argv_lanes: ($argv | words), merged_block: $merged, results: $results[0]}'
)

# bap_vendor_excluded <host> — the lanes a panel run on <host> leaves out: the host's whole VENDOR,
# not only its model, because a blind audit is cross-vendor (the old wrapper's rule). Hosts: claude,
# codex, antigravity, cursor, kimi, qwen, codestral, openrouter, byteplus (the last three are
# forward-compatibility arms: detect_host_platform cannot emit them today, kept in sync with
# _BAP_ISOLATED below so a future same-vendor detection signal is not silently un-excluded); anything
# else, or nothing, prints nothing (status 0).
bap_vendor_excluded() {
  case "${1:-}" in
    claude)      printf '%s\n' "claude" ;;
    codex)       printf '%s\n' "codex-5.3 codex-5.4" ;;
    antigravity) printf '%s\n' "agy gemini" ;;
    cursor)      printf '%s\n' "cursor-agent" ;;
    kimi)        printf '%s\n' "kimi kimi-api" ;;
    qwen)        printf '%s\n' "qwen" ;;
    codestral)   printf '%s\n' "codestral" ;;
    openrouter)  printf '%s\n' "openrouter openrouter-alt openrouter-3 openrouter-4" ;;
    byteplus)    printf '%s\n' "byteplus byteplus-alt byteplus-3" ;;
    *)           ;;
  esac
}

# ── Isolation ─────────────────────────────────────────────────────────────────

# The lanes a blind audit may run AT ALL — each one is isolated by construction or by a recorded probe:
# codex-5.3/5.4 and claude through model-subprocess.sh access `none`; kimi and qwen with no tools; the
# HTTP API lanes, which have no tool or file access; agy, proven by the 2026-09-25 spike when run
# WITHOUT --dangerously-skip-permissions (plan, Review Trail). cursor-agent and muse are NOT here: every
# tested flag set let their read tool reach a path outside the workspace. A lane joins only with a proof.
_BAP_ISOLATED='codex-5.3 codex-5.4 claude agy kimi kimi-api qwen codestral openrouter openrouter-alt openrouter-3 openrouter-4 byteplus byteplus-alt byteplus-3'

# bap_allowlist — print the lanes this run may use, space-separated on one line (nothing at all when
# none is left): ZUVO_BLIND_AUDIT_ALLOWLIST (space-separated; unset, empty or blank = the whole isolated
# list) NARROWED to the isolated list, in the override's order, each once. An override can only narrow:
# a lane it names that is not isolated (cursor-agent, muse, a typo) is refused — ONE stderr line names
# every refused lane — and never printed. Words are never glob-expanded (a subshell function with
# set -f). Status 0.
bap_allowlist() (
  set -f
  out=" "; refused=""; want="${ZUVO_BLIND_AUDIT_ALLOWLIST:-}"
  case "$want" in *[![:space:]]*) ;; *) want="$_BAP_ISOLATED" ;; esac
  for l in $want; do
    case " $_BAP_ISOLATED " in
      *" $l "*) case "$out" in *" $l "*) ;; *) out="$out$l " ;; esac ;;
      *) refused="${refused:+$refused }$l" ;;
    esac
  done
  if [ -n "$refused" ]; then
    _bap_err bap_allowlist "ZUVO_BLIND_AUDIT_ALLOWLIST can only narrow the isolated default — refused (isolation never proven): $refused"
  fi
  out="${out# }"; out="${out% }"
  if [ -z "$out" ]; then [ -n "$refused" ] && return 1; return 0; fi
  printf '%s\n' "$out"
)

# bap_agy_tools_open <settings.json> — status 0 when agy's OWN settings could re-open the tool access
# the blind-audit invocation keeps closed: a non-empty `permissions.allow` (the escape hatch agy's
# headless denial message names), or a file that exists but cannot be read as JSON (fail closed: a rule
# nobody can read may still be there; also without jq). Status 1 when the file is absent or empty, or
# holds no allow-rule — the spike's state, only `trustedWorkspaces`. Status 2: usage.
bap_agy_tools_open() {
  local f="${1:-}" rc=0
  if [ -z "$f" ]; then _bap_err bap_agy_tools_open "usage: bap_agy_tools_open <settings.json>"; return 2; fi
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then return 1; fi
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then return 0; fi
  [ -s "$f" ] || return 1
  command -v jq >/dev/null 2>&1 || return 0
  # jq -e: 0 = a truthy answer (a rule, or an allow that is not a list), 1 = false; anything else is a
  # parse or type error — unverifiable, so open.
  jq -e '(.permissions.allow // []) | (type != "array") or (length > 0)' "$f" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 1 ]
}
