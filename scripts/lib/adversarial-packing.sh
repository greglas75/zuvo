# shellcheck shell=bash
# Shared canonical partitioner: dispatch and provider-free zuvo-packing/1 planning.
# _ck_count_units [<file>] — the chunk boundaries in <file> (stdin without one): file headers, or in a document
# mode headings outside code fences — by the split's own rule, so the dry-run plan counts what the split cuts.
_ck_count_units() {
  awk -v re="$_ck_boundary_re" -v fence="$_ck_fence" '
    fence && /^[[:space:]]*(```|~~~)/ { infence = !infence; next }
    !(fence && infence) && $0 ~ re    { n++ }
    END { print n + 0 }' "$@"
}

# _ck_count_hunks [<budget>] — the split points in the diff sections of stdin: one per hunk header, plus one for a
# hunk with two or more body lines that _ck_split_hunks cuts at its line boundaries — by the split's own rule:
# the file's header and `=== CONTEXT:` trailer plus the hunk over <budget> — so a new file that is ONE
# `@@ -0,0 +1,N @@` hunk over the cap counts as splittable. An `@@ ` line inside a --files section is that
# file's text, not a hunk.
_ck_count_hunks() {
  LC_ALL=C awk -v re="$FILE_HEADER_RE" -v budget="${1:-0}" -v hdr="$SUBHUNK_HEADER_BYTES" '
    # Splittable, as _ck_split_hunks rules it: over the budget with its file header and trailer, room for a
    # sub-hunk body (the budget less header, trailer, 200 and the section heading) of 1000 bytes or more, and
    # two or more lines a part can start at. A `\` marker never starts one; an empty line is not counted either
    # (the split may start a part at an empty line inside a hunk, so this can only under-count, never over-count).
    function close_sec(   k) {
      for (k = 1; k <= nh; k++)
        if (budget > 0 && fixed + hs[k] > budget && budget - fixed - hdr - hr[k] >= 1000 && hl[k] >= 2) n++
      nh = 0; fixed = 0; st = 0
    }
    $0 ~ re { close_sec(); indiff = ($0 ~ /^diff --git /); if (indiff) fixed = length($0) + 1; next }
    !indiff { next }
    st < 2 && /^=== CONTEXT: / { st = 2 }
    st != 2 && /^@@ /          { st = 1; nh++; n++; hs[nh] = length($0) + 1; hl[nh] = 0
                                 hr[nh] = match($0, /^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/) ? length($0) - RLENGTH : 1e9
                                 next }
    st == 1 { hs[nh] += length($0) + 1; if ($0 != "" && !/^\\/) hl[nh]++; next }
            { fixed += length($0) + 1 }
    END { close_sec(); print n + 0 }'
}

# _ck_split_hunks <section> <budget> — split one file's diff section at its hunks into <section>-pNNNN, each
# the file header + as many whole hunks as fit <budget> bytes + the section's `=== CONTEXT:` trailer. A hunk that
# alone overflows is cut at its LINE boundaries into sub-hunks that each fit, every one a valid hunk: a synthetic
# `@@ -a,b +c,d @@` header recomputed from the lines it holds (context counts on both sides, `-` old, `+` new, a
# `\ No newline` marker on neither and never separated from the line before it, empty lines closing the hunk on
# neither unless its header counts them), so a reviewer's file:line stays right. The section heading stays on
# the first sub-hunk only. Only a single LINE over the budget still overflows: its part is cut by the child's
# truncate path. A hunk is left whole when its header does not parse, or when the room for a sub-hunk body (the
# budget less the file header, the trailer, 200 bytes for the synthetic header and the section heading) is under
# 1000. Beside each part, <dir>/pnote-<name>-pNNNN names its hunks. Prints the number of parts written: 0 when
# the section has fewer than 2 units (whole hunks or hunk parts) — nothing is written.
_ck_split_hunks() {
  local sec="$1" budget="$2"
  # LC_ALL=C: length() counts bytes, the unit of the budget and of Pass 2's `wc -c`.
  LC_ALL=C awk -v budget="$budget" -v out="$sec" -v note="${sec%/*}/pnote-${sec##*/}" -v hdr="$SUBHUNK_HEADER_BYTES" '
    # rng(next, count) — one side of a hunk header: a side with no lines names the line BEFORE the gap (-0,0).
    function rng(start, cnt) { return (cnt == 0 ? start - 1 : start) "," cnt }
    function label(u) { return "hunk " uk[u] (upn[u] ? " part " upn[u] "/" kparts[uk[u]] : "") }
    function emit(a, b,   fn, i, u, whole) {
      np++
      fn = sprintf("%s-p%04d", out, np)
      for (i = 1; i < us[1]; i++) print L[i] > fn
      for (u = a; u <= b; u++) {
        if (uh[u] != "") print uh[u] > fn
        for (i = ub[u]; i <= ue2[u]; i++) print L[i] > fn
      }
      if (ts) for (i = ts; i <= NR; i++) print L[i] > fn
      close(fn)
      fn = sprintf("%s-p%04d", note, np)
      whole = 1
      for (u = a; u <= b; u++) if (upn[u]) whole = 0
      if (whole) printf "hunks %d-%d of %d of %s", uk[a], uk[b], nu, path > fn
      else if (a == b) printf "%s of %d of %s", label(a), nu, path > fn
      else printf "%s to %s of %d of %s", label(a), label(b), nu, path > fn
      close(fn)
    }
    # addunit(k, hdr, from, to, size, partno) — one packing unit of hunk k: lines <from>..<to>, preceded by the
    # synthetic header <hdr> ("" = a whole hunk, whose own header is line <from>); partno 0 = the whole hunk.
    function addunit(k, hdr, from, to, size, pn) {
      nunit++; uk[nunit] = k; uh[nunit] = hdr; ub[nunit] = from; ue2[nunit] = to; usz2[nunit] = size; upn[nunit] = pn
    }
    # cut(k, avail) — hunk k as sub-hunks of at most <avail> body bytes each (a longer single line stays one part);
    # 0, adding nothing, when its header does not parse or it yields one part.
    function cut(k, avail,   h, rest, ab, o, nw, no, nn, i, c, sz, from, cur, po, pn, pc, m, last, j, to, tn, sz2) {
      h = L[us[k]]
      if (!match(h, /^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/)) return 0
      rest = substr(h, RLENGTH + 1)
      avail -= length(rest)   # room for the section heading, which the first sub-hunk keeps
      if (avail < 1000) return 0
      split(substr(h, 4, RLENGTH - 6), ab, " ")
      if (split(substr(ab[1], 2), o, ",") < 2) o[2] = 1
      if (split(substr(ab[2], 2), nw, ",") < 2) nw[2] = 1
      # The next old / new line number: a side with no lines names the line before the gap.
      no = (o[2] + 0 == 0) ? o[1] + 1 : o[1] + 0
      nn = (nw[2] + 0 == 0) ? nw[1] + 1 : nw[1] + 0
      # Empty lines closing the hunk (a separator before the next file) are not context: they count on neither
      # side — unless the header of the hunk counts them, as blank context lines whose space was stripped.
      for (last = ue[k]; last > us[k] && L[last] == ""; last--) ;
      if (last < ue[k]) {
        to = 0; tn = 0
        for (j = us[k] + 1; j <= last; j++) {
          c = substr(L[j], 1, 1)
          if (c == "-") to++; else if (c == "+") tn++; else if (c != "\\") { to++; tn++ }
        }
        # As many as the header still counts on BOTH sides are stripped blank context; any beyond are separators.
        j = o[2] - to
        if (j > 0 && j == nw[2] - tn) last += (j < ue[k] - last ? j : ue[k] - last)
      }
      from = us[k] + 1; cur = 0; po = 0; pn = 0; m = 0
      for (i = from; i <= ue[k] + 1; i++) {
        sz = (i <= ue[k]) ? length(L[i]) + 1 : 0
        # A `\` marker goes with the line before it, so that line is measured with it.
        if (i < ue[k] && substr(L[i + 1], 1, 1) == "\\") sz2 = sz + length(L[i + 1]) + 1; else sz2 = sz
        if (i > ue[k] || (cur > 0 && i <= last && cur + sz2 > avail && substr(L[i], 1, 1) != "\\")) {
          m++
          # The heading names the function the HUNK starts in: true of the first part only.
          phdr[m] = sprintf("@@ -%s +%s @@%s", rng(no, po), rng(nn, pn), m == 1 ? rest : "")
          pfrom[m] = from; pto[m] = i - 1; psz[m] = cur
          no += po; nn += pn
          from = i; cur = 0; po = 0; pn = 0
          if (i > ue[k]) break
        }
        c = substr(L[i], 1, 1)
        if (i > last) c = "\\"
        if (c == "-") po++
        else if (c == "+") pn++
        else if (c != "\\") { po++; pn++ }
        cur += sz
      }
      if (m < 2) return 0
      kparts[k] = m
      for (pc = 1; pc <= m; pc++) addunit(k, phdr[pc], pfrom[pc], pto[pc], psz[pc] + length(phdr[pc]) + 1, pc)
      return 1
    }
    { L[NR] = $0; sz = length($0) + 1 }
    st < 2 && /^=== CONTEXT: / { st = 2; ts = NR }
    st == 0 && /^@@ /          { st = 1 }
    st == 0 { hsz += sz
              if (/^\+\+\+ b\//) path = substr($0, 7)
              else if (path == "" && /^--- a\//) path = substr($0, 7)
              next }
    st == 1 { if (/^@@ /) us[++nu] = NR; usz[nu] += sz; next }
            { tsz += sz }
    END {
      if (nu < 1) { print 0; exit }
      for (k = 1; k < nu; k++) ue[k] = us[k + 1] - 1
      ue[nu] = ts ? ts - 1 : NR
      if (path == "") path = substr(L[1], 12)
      if (length(path) > 80) path = "..." substr(path, length(path) - 76)
      fixed = hsz + tsz
      # Room for one sub-hunk body: the budget less the repeated file header and trailer, less its own header.
      avail = budget - fixed - hdr
      for (k = 1; k <= nu; k++) {
        if (fixed + usz[k] > budget && avail >= 1000 && cut(k, avail)) continue
        addunit(k, "", us[k], ue[k], usz[k], 0)
      }
      if (nunit < 2) { print 0; exit }
      first = 1; cur = usz2[1]
      for (u = 2; u <= nunit; u++) {
        if (fixed + cur + usz2[u] > budget) { emit(first, u - 1); first = u; cur = 0 }
        cur += usz2[u]
      }
      emit(first, nunit)
      print np
    }' "$sec"
}

# _ck_split_oversized_sections <dir> <budget> — Pass 1.5: a diff section over <budget> is split at its hunks
# (_ck_split_hunks), so one big file is reviewed whole across parts instead of being cut. The parts sort right
# after the section they replace, which is emptied; a split that fails leaves the section whole and its partial
# parts empty. Prints the number of sections split.
_ck_split_oversized_sections() {
  local dir="$1" budget="$2" sec first parts p nsplit=0
  for sec in "$dir"/sec-*; do
    [[ -s "$sec" && $(wc -c < "$sec" | tr -d ' ') -gt $budget ]] || continue
    first=""; IFS= read -r first < "$sec" || true
    [[ "$first" == "diff --git "* ]] || continue
    if parts=$(_ck_split_hunks "$sec" "$budget") && [[ "${parts:-0}" -ge 2 ]]; then
      : > "$sec"
      nsplit=$((nsplit + 1))
    else
      for p in "$sec"-p*; do if [[ -e "$p" ]]; then : > "$p"; fi; done
    fi
  done
  printf '%s\n' "$nsplit"
}

# _ck_merge_part_note <dir> <section> <chunk> — a part's hunk note (pnote-*) goes into its chunk's note (cnote-*).
_ck_merge_part_note() {
  local dir="$1" sec="$2" chunk="$3" pnote cnote
  pnote="$dir/pnote-${sec##*/}"
  [[ -s "$pnote" ]] || return 0
  cnote="$dir/cnote-${chunk##*/chunk-}"
  if [[ -s "$cnote" ]]; then printf '; ' >> "$cnote"; fi
  cat "$pnote" >> "$cnote"
}

# _ck_build_chunk_note <fence> <i> <n> <cnote> — the context note for part <i> of <n>. A diff part names the
# hunks its chunk note <cnote> lists, capped so the whole note stays inside CHUNK_NOTE_HEADROOM_CHARS.
_ck_build_chunk_note() {
  local fence="$1" i="$2" n="$3" cnote="$4" note ell="..."
  # The cap holds the closing bracket; a fifth of the headroom stays spare.
  local note_max=$(( CHUNK_NOTE_HEADROOM_CHARS * 4 / 5 ))
  # The note must match what was actually split. Telling a plan reviewer that
  # "sibling FILES are reviewed in other chunks" invites it to report the
  # document as truncated or to flag cross-references it cannot see; say
  # plainly that this is one document cut into parts.
  if [[ "$fence" -eq 1 ]]; then
    printf '%s' "[part ${i}/${n} of ONE document split at section headings — the other sections are reviewed in sibling parts; do NOT report the document as incomplete/truncated, and do NOT report a section or cross-reference you cannot see here as missing]"
    return 0
  fi
  note="[chunk ${i}/${n} of a larger range — sibling files, hunks of the same file or parts of a split hunk are reviewed in other chunks; do NOT report them as missing"
  if [[ -s "$cnote" ]]; then
    note="$note; this chunk holds $(cat "$cnote")"
    [[ ${#note} -lt $note_max ]] || note="${note:0:$(( note_max - ${#ell} - 1 ))}$ell"
  fi
  printf '%s]' "$note"
}


_ck_should_chunk() {
# One budget for the gate below and the split it predicts (Pass 1.5, Pass 2): MAX_CHARS less the note headroom.
_ck_budget=$((MAX_CHARS - CHUNK_NOTE_HEADROOM_CHARS))
if [[ ${#INPUT} -gt $MAX_CHARS && ! "$REVIEW_MODE" =~ $AR_UNCHUNKED_DOC_MODES ]]; then
  _chunk_headers=$(printf '%s\n' "$INPUT" | _ck_count_units)
  if [[ "$_ck_fence" -eq 0 ]]; then
    _chunk_hunks=$(printf '%s\n' "$INPUT" | _ck_count_hunks "$_ck_budget")
  fi
fi
if [[ ${#INPUT} -gt $MAX_CHARS && -z "${ZUVO_ADV_CHUNK:-}" && "$NO_CHUNK" != "true" \
      && "${ZUVO_ADV_NO_CHUNK:-0}" != "1" \
      && ( "${_chunk_headers:-0}" -ge 2 || ( "$_ck_fence" -eq 0 && "${_chunk_hunks:-0}" -ge 2 ) ) ]]; then
  return 0
fi
return 1
}

_ck_pack_input() {
  # Pass 1: split into sections (sec-0000 = any preamble before the first header).
  # Fence tracking is enabled ONLY for document modes. A diff of a markdown file
  # legitimately contains ``` lines; letting those toggle in-fence state there
  # would suppress a real `diff --git` boundary and silently merge two files into
  # one chunk — so the toggle is gated on $_ck_fence, not applied universally.
  printf '%s\n' "$INPUT" | awk -v dir="$_ck_dir" -v re="$_ck_boundary_re" -v fence="$_ck_fence" '
    BEGIN { n = 0; infence = 0; fn = sprintf("%s/sec-%04d", dir, n) }
    fence && /^[[:space:]]*(```|~~~)/ { infence = !infence; print >> fn; next }
    !(fence && infence) && $0 ~ re { close(fn); n++; fn = sprintf("%s/sec-%04d", dir, n) }
    { print >> fn }
  '
  # Pass 1.5: a diff section over the budget is split at its hunks.
  _ck_nsplit=0
  if [[ "$_ck_fence" -eq 0 ]]; then
    _ck_nsplit=$(_ck_split_oversized_sections "$_ck_dir" "$_ck_budget")
  fi
  # Pass 2: pack sections and parts greedily into chunks of at most the budget (MAX_CHARS less the headroom
  # for the per-chunk context note). One still over it — a --files section, a single line over the cap, a
  # file header or trailer that leaves no room to cut a hunk — becomes its own chunk, which the child truncates with the loud WARN; every other file and
  # hunk keeps a full-fidelity review. A part's hunk note (pnote-*) goes into its chunk's note (cnote-*).
  _ck_n=0; _ck_size=0; _ck_file=""
  for _sec in "$_ck_dir"/sec-*; do
    [[ -s "$_sec" ]] || continue
    _sec_size=$(wc -c < "$_sec" | tr -d ' ')
    if [[ -z "$_ck_file" || $((_ck_size + _sec_size)) -gt $_ck_budget && $_ck_size -gt 0 ]]; then
      _ck_n=$((_ck_n + 1)); _ck_file=$(printf '%s/chunk-%03d' "$_ck_dir" "$_ck_n"); _ck_size=0
    fi
    cat "$_sec" >> "$_ck_file"
    _ck_size=$((_ck_size + _sec_size))
    _ck_merge_part_note "$_ck_dir" "$_sec" "$_ck_file"
  done

}

# Planning is an observation, not a review: no providers, quotas or review artifacts.
ar_emit_chunk_plan() {
  [[ "$CHUNK_PLAN" == true ]] || return 0
  if [[ "$DOCTOR" == true || "$LIST_PROVIDERS" == true || "$DRY_RUN" == true \
      || "$EFFECTIVENESS" == true || -n "$RECORD_ROWS" || "$REVIEW_MODE" == blind-audit ]]; then
    echo "ERROR: --chunk-plan requires ordinary review input and mode" >&2; exit 2
  fi
  ar_validate_mode
  ar_guard_file_list
  ar_collect_input
  ar_set_input_cap
  ar_set_chunk_boundary
  ar_check_material
  local chunked=false reserve=0 ck input_chars=${#INPUT} i=0 is_doc=false
  [[ ! "$REVIEW_MODE" =~ $AR_DOC_MODES ]] || is_doc=true
  _ck_dir=$(mktemp -d "${TMPDIR:-/tmp}/zuvo-adv-plan.XXXXXX")
  trap 'rm -rf "$_ck_dir"' EXIT
  printf '%s' "$INPUT" > "$_ck_dir/normalized-input"
  printf '%s' "$CONTEXT_HINT" > "$_ck_dir/context"
  ar_omit_oversized_content
  if _ck_should_chunk; then
    chunked=true; reserve=$CHUNK_NOTE_HEADROOM_CHARS
    _ck_pack_input
  else
    printf '%s' "$INPUT" > "$_ck_dir/chunk-001"
  fi
  for ck in "$_ck_dir"/chunk-*; do
    i=$((i + 1))
    # Child collection strips trailing newlines just as the parent collector does.
    INPUT="$(cat "$ck")"
    # Observe the same collection/material guards as a child before truncation. The
    # subshell keeps the guard's exit and child marker out of this provider-free phase.
    if (
      [[ -n "$INPUT" && "$INPUT" =~ [^[:space:]] ]] || exit 2
      [[ "$chunked" != true ]] || ZUVO_ADV_CHUNK="$i/$_ck_n"
      ar_check_material
    ) >/dev/null 2>&1; then
      printf true > "$_ck_dir/reviewable-$i"
    else
      printf false > "$_ck_dir/reviewable-$i"
    fi
    ar_truncate_input
    printf '%s' "$INPUT" > "$_ck_dir/review-$i"
    printf '%s' "$INPUT_TRUNCATED" > "$_ck_dir/truncated-$i"
  done
  python3 - "$_ck_dir" "$REVIEW_MODE" "$MAX_CHARS" "$reserve" "$chunked" "$input_chars" "$INPUT_OMITTED" "$INPUT_UNSPLITTABLE" "$INPUT_MODE" "$is_doc" <<'PACKING_JSON'
import hashlib, json, os, pathlib, sys
root = pathlib.Path(sys.argv[1]); mode = sys.argv[2]
cap, reserve, chunked, chars = int(sys.argv[3]), int(sys.argv[4]), sys.argv[5] == 'true', int(sys.argv[6])
digest = lambda value: hashlib.sha256(value).hexdigest()
normalized = (root / 'normalized-input').read_bytes()
chunks = []
for index, path in enumerate(sorted(root.glob('chunk-*')), 1):
    payload = path.read_bytes(); reviewed = (root / f'review-{index}').read_bytes()
    text = payload.decode('utf-8', errors='replace'); file = None; hunks = []
    for line in (text.split('\n') if sys.argv[9] != 'files' and sys.argv[10] != 'true' else []):
        if line.startswith('diff --git '): file = line
        elif line.startswith(('=== FILE: ', '=== CONTEXT: ')): file = None
        elif file is not None and line.startswith('@@ '): hunks.append({'file_header': file, 'header': line})
    reviewable = (root / f'reviewable-{index}').read_text() == 'true'
    chunks.append({'index': index, 'payload_bytes': len(payload), 'payload_sha256': digest(payload),
                   'review_input_bytes': len(reviewed), 'review_input_sha256': digest(reviewed),
                   'hunks': hunks, 'truncated': (root / f'truncated-{index}').read_text() == 'true',
                   'reviewable': reviewable})
print(json.dumps({'schema_version': 1, 'contract_version': 'zuvo-packing/1', 'mode': mode,
                  'cap': cap, 'activation_unit': 'bash_characters', 'packing_unit': 'utf8_bytes',
                  'locale': {key: os.environ.get(key) for key in ('LC_ALL', 'LC_CTYPE', 'LANG')},
                  'byte_reserve': reserve, 'payload_byte_budget': cap - reserve,
                  'normalized_input': {'sha256': digest(normalized), 'bytes': len(normalized), 'characters': chars},
                  'context_sha256': digest((root / 'context').read_bytes()),
                  'chunked': chunked, 'planned_chunk_count': len(chunks), 'chunks': chunks,
                  'input_omitted': bool(sys.argv[7]), 'input_unsplittable': bool(sys.argv[8]),
                  'omission_notes': sys.argv[7].split('\n') if sys.argv[7] else [],
                  'unsplittable_notes': sys.argv[8].split('\n') if sys.argv[8] else [],
                  'complete': not sys.argv[7] and not sys.argv[8] and all(c['reviewable'] and not c['truncated'] for c in chunks),
                  'unreviewable': any(not c['reviewable'] for c in chunks)}))
PACKING_JSON
  exit 0
}
