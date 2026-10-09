#!/usr/bin/env bash
# test-backlog-declared-partial.sh — an id in BOTH backlog files is legitimate when the open copy declares a
# PARTIAL closure (the marker near its start AND a `Remaining:` clause) or a REGRESSION, and `drop-stale` must
# never remove such a copy: it is the live definition, the archived [x] the stale one.
#
# The defects these cases catch:
#   - the namespace gate rejecting what backlog-protocol.md tells agents to do (16 declared partial closures in
#     one repo blocked every `append-runlog` there);
#   - drop-stale filing a code-verified re-open back as done (two "(re-added by verification) … PARTIAL …
#     Remaining:" entries) — the open copy is quoted into the archive and the work reads as closed again;
#   - the exemption widening to any entry that says "partial" somewhere, which would hide genuine stale copies.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
ARCHIVE_PY="$ROOT/scripts/zuvo-home/backlog-archive.py"
PASS=0; FAIL=0
ok() { echo "  PASS $1"; PASS=$((PASS + 1)); }
no() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
FIX="$(mktemp -d "${TMPDIR:-/tmp}/backlog-partial.XXXXXX")" && FIX="$(cd "$FIX" && pwd -P)" \
  && [ -n "$FIX" ] || { echo "FATAL: no fixture directory" >&2; exit 1; }
trap 'rm -rf "$FIX"' EXIT

ARCHIVED='- [x] B-PAIR-1 [FIXED deadbee] src/a.ts the archived copy closes the part that shipped'
# repo <name> <open-entry-lines…> — a repo whose archive closes B-PAIR-1 and whose open file holds the given lines.
repo() {
  local d="$FIX/$1"; shift; mkdir -p "$d/memory"
  { printf '# Tech Debt Backlog\n\n## Open\n\n'; printf '%s\n' "$@"
    printf -- '- [ ] B-OTHER src/b.ts an unrelated open entry\n'; } > "$d/memory/backlog.md"
  printf '## Archived from backlog.md on 2026-10-01 (1 completed items moved out)\n%s\n' "$ARCHIVED" \
    > "$d/memory/backlog-done.md"
}
verify() { out="$(python3 "$ARCHIVE_PY" verify --repo "$FIX/$1" 2>&1)"; rc=$?; }
sha() { python3 -c "import hashlib,sys; print(hashlib.sha1(open(sys.argv[1],'rb').read()).hexdigest())" "$1"; }
pair_sha() { echo "$(sha "$FIX/$1/memory/backlog.md")$(sha "$FIX/$1/memory/backlog-done.md")"; }

echo "== verify: which pairs are declared =="
repo partial '- [ ] **B-PAIR-1** — (re-added by verification) **2026-10-09 PARTIAL — PR #9:** the API part shipped.' \
             '  The UI half is still on an unmerged branch.' '  Remaining: the on-screen display and its test'
verify partial
{ [ "$rc" -eq 0 ] && [ "$out" = "OK disjoint: 2 open, 1 archived, 1 declared partial closure(s)" ]; } \
  && ok "a PARTIAL marker + a Remaining: clause on a continuation line → exempt, counted: '$out'" \
  || no "declared partial: rc=$rc '$out'"

repo noremain '- [ ] **B-PAIR-1** — (re-added by verification) **2026-10-09 PARTIAL — PR #9:** the API part shipped.'
verify noremain
{ [ "$rc" -eq 1 ] && case "$out" in *"VIOLATION 1 key(s)"*"id:b-pair-1"*) true ;; *) false ;; esac; } \
  && ok "PARTIAL without Remaining: → still a violation" || no "PARTIAL without Remaining: rc=$rc '$out'"

pad="$(printf 'x%.0s' $(seq 1 300))"
repo late "- [ ] **B-PAIR-1** — $pad PARTIAL" '  Remaining: the rest'
verify late
[ "$rc" -eq 1 ] && ok "PARTIAL past the first 300 characters → violation (the marker belongs at the start)" \
  || no "late PARTIAL: rc=$rc '$out'"

# "- [ ] **B-PAIR-1** — " is 21 characters, so this marker starts at 297 and ends past the window.
repo straddle "- [ ] **B-PAIR-1** — $(printf 'x%.0s' $(seq 1 275)) PARTIAL" '  Remaining: the rest'
verify straddle
[ "$rc" -eq 0 ] && ok "a marker that STARTS inside the window counts, though it ends past it" \
  || no "straddling PARTIAL: rc=$rc '$out'"

# Each of these looks like a declaration and is not one: the pair stays a violation.
expect_violation() {
  local name="$1" why="$2"; shift 2
  repo "$name" "$@"; verify "$name"
  [ "$rc" -eq 1 ] && ok "$why → violation" || no "$why: rc=$rc '$out'"
}
expect_violation lower "lower-case 'partial' in prose + Remaining:" \
  '- [ ] **B-PAIR-1** — a partial fix went in' '  Remaining: the rest'
expect_violation inid "PARTIAL only inside other ids (B-…-PARTIAL-…, …_PARTIAL) + Remaining:" \
  '- [ ] **B-PAIR-1** — see B-20261002-TURF-FU-COVERAGE-PARTIAL and QUALIFICATION_PARTIAL' '  Remaining: the rest'
expect_violation emptyrem "PARTIAL + a Remaining: that names nothing" \
  '- [ ] **B-PAIR-1** — **PARTIAL — PR #9:** the API part shipped. Remaining:'
expect_violation boldrem "PARTIAL + a bold **Remaining:** that names nothing" \
  '- [ ] **B-PAIR-1** — **PARTIAL — PR #9:** the API part shipped.' '  **Remaining:** —'
expect_violation nextrem "PARTIAL + a Remaining: that belongs to the NEXT entry" \
  '- [ ] **B-PAIR-1** — **PARTIAL — PR #9:** the API part shipped.' '- [ ] B-NEXT src/c.ts Remaining: its own rest'

repo plain '- [ ] **B-PAIR-1** — the same defect, never re-opened'
verify plain
{ [ "$rc" -eq 1 ] && case "$out" in *"mark the"*"PARTIAL"*"Remaining:"*) true ;; *) false ;; esac; } \
  && ok "an undeclared pair → violation, and the advice names the PARTIAL + Remaining: form" \
  || no "undeclared pair: rc=$rc '$out'"

repo regr '- [ ] **B-PAIR-1** — REGRESSION after deadbee: it broke again'
verify regr
{ [ "$rc" -eq 0 ] && [ "$out" = "OK disjoint: 2 open, 1 archived, 1 declared regression(s)" ]; } \
  && ok "a REGRESSION pair is still exempt: '$out'" || no "regression pair: rc=$rc '$out'"

echo "== drop-stale: a declared re-open is the live definition =="
for case_ in partial:PARTIAL regr:REGRESSION; do
  r="${case_%%:*}"; want="${case_#*:}"; before="$(pair_sha "$r")"
  out="$(python3 "$ARCHIVE_PY" drop-stale --id B-PAIR-1 --repo "$FIX/$r" 2>&1)"; rc=$?
  { [ "$rc" -ne 0 ] && case "$out" in *"declares a $want"*"live definition"*"archived [x] (backlog-done.md:2) is the stale one"*"tick the open copy"*) true ;; *) false ;; esac; } \
    && ok "drop-stale refuses the $want open copy and names the archived [x] as stale" \
    || no "drop-stale on $want: rc=$rc '$out'"
  [ "$(pair_sha "$r")" = "$before" ] && ok "…and both files are byte-identical ($want)" || no "drop-stale on $want changed a file"
done

# The protocol declares a regression on the bullet line; verify and drop-stale must read it the same way.
repo contreg '- [ ] **B-PAIR-1** — the same defect' '  an old note: this was a REGRESSION once'
verify contreg
[ "$rc" -eq 1 ] && ok "REGRESSION only on a continuation line → verify reports the pair" || no "contreg verify: rc=$rc '$out'"
out="$(python3 "$ARCHIVE_PY" drop-stale --id B-PAIR-1 --repo "$FIX/contreg" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "…and drop-stale agrees that it is a stale copy and removes it" || no "contreg drop-stale: rc=$rc '$out'"

repo stale '- [ ] **B-PAIR-1** — the same defect, a stale copy left behind'
out="$(python3 "$ARCHIVE_PY" drop-stale --id B-PAIR-1 --repo "$FIX/stale" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "drop-stale still removes a genuine stale copy" || no "stale copy: rc=$rc '$out'"
verify stale
[ "$rc" -eq 0 ] && ok "…after which verify is clean: '$out'" || no "verify after drop-stale: rc=$rc '$out'"
grep -q '> - \[ \] \*\*B-PAIR-1\*\* — the same defect, a stale copy left behind' "$FIX/stale/memory/backlog-done.md" \
  && ok "…and the removed text is quoted in the archive" || no "removed text not quoted in the archive"

echo "== drop-stale stays all-or-nothing =="
mkdir -p "$FIX/batch/memory"
{ printf '# Tech Debt Backlog\n\n## Open\n\n'
  printf -- '- [ ] **B-PAIR-1** — the same defect, a stale copy\n'
  printf -- '- [ ] **B-PAIR-2** — (re-added by verification) **PARTIAL — PR #3:** half shipped\n  Remaining: the other half\n'; } \
  > "$FIX/batch/memory/backlog.md"
printf '## Archived\n%s\n- [x] B-PAIR-2 [FIXED cafe123] src/c.ts first half\n' "$ARCHIVED" > "$FIX/batch/memory/backlog-done.md"
before="$(pair_sha batch)"
out="$(python3 "$ARCHIVE_PY" drop-stale --id B-PAIR-1 --id B-PAIR-2 --repo "$FIX/batch" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && [ "$(pair_sha batch)" = "$before" ]; } \
  && ok "a batch holding one declared partial is refused whole — the stale copy beside it is not removed either" \
  || no "batch: rc=$rc, files changed: $([ "$(pair_sha batch)" = "$before" ] && echo no || echo yes) '$out'"

echo "== groom apply: a declared re-open never reaches the drop-stale batch =="
# One refused key refuses the whole drop-stale batch, so a declared re-open with a stale verdict must be
# withheld at the decision — otherwise one such entry blocks every disposition in the repo.
got="$(python3 - "$ROOT/scripts/zuvo-home" <<'PY'
import sys; sys.path.insert(0, sys.argv[1])
import zuvo_backlog_apply as zap, zuvo_backlog_ledger as zl, zuvo_backlog_parse as zb
text = ("# Tech Debt Backlog\n\n## Open\n\n"
        "- [ ] **B-STALE** — the same defect, a stale copy\n"
        "- [ ] **B-OPEN** — (re-added by verification) **PARTIAL — PR #3:** half shipped\n  Remaining: the rest\n"
        "- [x] **B-TICKED** — **PARTIAL — PR #4:** half shipped\n  Remaining: done now [FIXED cafe123]\n")
arch = "".join(f"- [x] {i} [FIXED deadbee] src/a.ts first half\n" for i in ("B-STALE", "B-OPEN", "B-TICKED"))
entries = list(zb.iter_entries(text, kinds=(zb.KIND_CHECKBOX,)))
rows = [{"keys": [e.key], "text_sha": zl.text_sha(e.body), "verdict": zl.VERDICT_STALE_FIXED} for e in entries]
acts = zap.dispositions(entries, rows, list(zb.iter_entries(arch, kinds=(zb.KIND_CHECKBOX,))),
                        text.splitlines(keepends=True))
print(" ".join(f"{a.entry.ident}={a.disposition}:{a.verb or '-'}" for a in acts))
print([a.reason for a in acts if a.entry.ident == "B-OPEN"][0])
PY
)"; rc=$?
first="$(printf '%s\n' "$got" | head -1)"; why="$(printf '%s\n' "$got" | tail -1)"
[ "$rc" -eq 0 ] && [ "$first" = "B-STALE=dropped:drop-stale B-OPEN=no-remedy:- B-TICKED=archived:archive" ] \
  && ok "stale copy → dropped, declared partial → no-remedy, ticked declared partial → archived" \
  || no "dispositions: rc=$rc '$got'"
case "$why" in *"declares a PARTIAL closure"*"drop-stale"*"refuses"*) ok "…and the no-remedy reason says why" ;;
  *) no "no-remedy reason: '$why'" ;; esac

printf 'RESULT: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
