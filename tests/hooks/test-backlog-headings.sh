#!/usr/bin/env bash
# The '## B-id' heading-block dialect: an entry in its own right.
#
# The defect this guards (measured on this repo's own backlog): memory/backlog.md records whole
# entries as a HEADING plus prose — '## B-driftguard-bounded-age — DONE' — and `iter_entries`
# `continue`d on every heading line, so those entries had NO representation in either parser mode.
# `backlog-archive.py lookup` answered ABSENT for an id that is sitting in the file, and every audit
# skill's mandatory dedup check therefore re-filed the finding as new: the exact loop the backlog
# protocol exists to prevent. 64 of the id-shaped headings here carry no sub-bullet at all, so they
# were invisible in BOTH modes, not merely mis-keyed.
#
# The discriminator is deliberately ID-ANCHORED: a heading at any level `#`..`######` is an entry iff
# `BODY_ID_RE` matches the text after the hashes. It can therefore only ever UNDER-cover — 20 of the
# 102 headings here are entry-shaped without an id and are correctly not entries — which is the right
# direction to be wrong in for a parser whose callers rewrite tracked files under a lock.
#
# Counts are DERIVED from the file, never hardcoded. memory/backlog.md is tracked and grows several
# times a day (1885 → 1911 → 1932 → 1957 lines inside one day), so the plan's literal "306 / 43 / 81"
# was already stale (328 / 65 / 82) before this suite was written. An absolute-count assertion here
# would be a false red by tomorrow; the invariants below hold at any size.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
MODULE="$ROOT/scripts/zuvo-home/zuvo_backlog_parse.py"
REAL="$ROOT/memory/backlog.md"

PASS=0; FAIL=0
ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

FIX="$(mktemp -d "${TMPDIR:-/tmp}/stqa-backlog-head.XXXXXX")"
# Canonicalise once: on macOS $TMPDIR is /var/folders/... and /var is a symlink to /private/var, so
# the helpers (which resolve real paths, correctly) answer /private/var/... while every comparison
# here would hold the unresolved form. Linux has no such symlink, which is why the farm never sees it.
FIX="$(cd "$FIX" && pwd -P)"
trap 'rm -rf "$FIX"' EXIT

# A misspelled helper prints "command not found", returns 127 and moves no counter — a whole file of
# broken assertions then summarises as FAIL=0 (that happened in test-profile-session-tokens.sh).
#
# THE HANDLER CANNOT INCREMENT A COUNTER, on any bash. MEASURED on bash 5.3.15: the handler FIRES and
# prints its line, but bash runs it in a SUBSHELL, so `FAIL=$((FAIL+1))` is discarded when that
# subshell exits — `definitely_not_a_command` left FAIL=0 and the script still exited 0. Inside a
# `$(...)` it is worse: the printed line is captured into the variable instead of the log. So the
# previous "mandatory typo protection" incremented nothing on EVERY bash version, not just 3.2; it
# only looked live because the bash-4 assertion below passes. A misspelled helper in an `if`
# condition still took the `else` branch (a real `no()`), but a bare call counted absolutely nothing.
#
# The evidence therefore has to cross the subshell boundary, and a FILE is the only thing that does.
# `finish` turns a non-empty marker into a real FAIL, so a typo now makes the suite exit non-zero.
CNFH_MARK="$FIX/.cnfh"
command_not_found_handle(){
  echo "  FAIL harness: unknown command '$1'"
  printf '%s\n' "$1" >> "$CNFH_MARK"
  return 127
}

# The ONLY exit path. Every early return in H0 goes through it, so the marker is always consulted and
# the RESULT line is always printed — run-all.sh parses that line and a bare `exit 1` would hand it
# a run with no verdict.
finish(){
  if [ -s "$CNFH_MARK" ]; then
    no "(H0) unknown command(s) ran: $(sort -u "$CNFH_MARK" | tr '\n' ' ')— a misspelled helper prints and returns 127 in a subshell, so every assertion that used it checked nothing"
  fi
  echo "RESULT: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

echo "== backlog heading entries =="

# --- H0 the harness guarantee itself: `command_not_found_handle` is bash 4+ ONLY -----------------
# Measured on the machine this was written on: /bin/bash 3.2.57 runs `definitely_not_a_command`,
# returns 127 and NEVER calls the handler; bash 5.3.15 calls it. The shebang is `#!/usr/bin/env bash`
# and run-all.sh invokes children as `bash <file>`, so the handler does fire under a modern PATH bash
# — but this repo otherwise targets bash 3.2 (no mapfile, no associative arrays), and under /bin/bash
# the typo protection above is silently inert: a misspelled helper would move no counter and the file
# would summarise FAIL=0 having checked nothing. The bash-4 dependency is therefore ASSERTED, not
# assumed. It is a FAIL and never a `SKIP:` — run-all.sh classifies exit 0 plus a leading `SKIP:` as
# SKIP, and a SKIP never fails the run, which is precisely the false green at issue. Only the HANDLER
# needs bash 4; every other bash-3.2 compatibility rule in this file still holds.
if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
  ok "(H0) bash ${BASH_VERSION%%(*} is 4+ — command_not_found_handle fires, typo protection is live"
else
  # EXIT, do not carry on. This assertion gates a guarantee the rest of the file RELIES on: without
  # the handler a misspelled helper writes no marker, so `finish` sees nothing and the FAIL count
  # below means nothing. Recording the failure and then running 50 more assertions produced a report
  # whose body read as evidence while its premise was already false.
  no "(H0) bash ${BASH_VERSION%%(*} predates command_not_found_handle (bash 4+): a misspelled helper returns 127 and writes no marker, so this file's FAIL count proves nothing — re-run under bash >= 4"
  finish
fi

# --- H0 next: no-substitution. A missing module or backlog is a FAILURE, never a SKIP — python3 and
# memory/backlog.md are both stated prerequisites of this repo, so there is no legitimate path on
# which the rest of this file does not run.
if [ -f "$MODULE" ]; then ok "(H0) parser module present"; else
  no "(H0) $MODULE missing — nothing below can be checked"; finish; fi
if [ -f "$REAL" ]; then ok "(H0) memory/backlog.md present"; else
  no "(H0) $REAL missing — the real-file invariants cannot be checked"; finish; fi

py(){ python3 -c "
import sys, re, warnings
sys.path.insert(0, '$ROOT/scripts/zuvo-home')
import zuvo_backlog_parse as zb
REAL = '$REAL'
$1"; }

if py "sys.exit(0 if hasattr(zb, 'iter_entries') else 1)"; then
  ok "(H0) module imports and exposes iter_entries"; else
  no "(H0) module does not import — the rest cannot be checked"; finish; fi

# --- fixtures -----------------------------------------------------------------------------------
# One file carrying the positive shapes AND all eight negative shapes, so a negative assertion can
# never pass vacuously: the same parse has to produce the four expected heading entries.
# Two of the eight are MALFORMED HASH PREFIXES rather than prose: seven hashes, and no whitespace
# after the hashes. Both fall outside HEADING_RE (^#{1,6}\s+), so _heading_entry leaves on its
# `h is None` branch — the one branch of the new code the real file cannot exercise, because
# memory/backlog.md holds zero lines of either shape (^####### matched 0, ^#{1,6}[^# \t] matched 0).
# Without these two lines that branch is live, correct and completely untested.
cat > "$FIX/heads.md" <<'EOF'
# Tech Debt Backlog

## Open

### B-alpha-one the heading IS the entry
- [ ] B-alpha-sub a sub-bullet under the heading entry

#### B-beta-two — DONE b9767b6a
###### B-deep-six deepest level is still an entry
# B-top-one level one is an entry too
## [obs] run-all.sh scope requires healthy Docker infra fixtures (2026-07-02)
## (closed) B-paren-not-a-definition
## Archived from backlog.md on 2026-09-20 (1 completed items moved out)
  ## B-IND indented heading
  > ## B-Q quoted heading
####### B-seven seven hashes is past the level range
##B-nospace no whitespace after the hashes
## B-tpl-head fingerprint | source-task
| B-tbl-1 | a table row | RESOLVED |
- [x] B-chk-done a ticked checkbox
- plain bullet carrying no id
EOF

# Every heading level, one id each: the level range is part of the contract.
: > "$FIX/levels.md"
for n in 1 2 3 4 5 6; do
  h="$(printf '#%.0s' $(seq 1 "$n"))"
  printf '%s B-lvl-%s level %s entry\n\n' "$h" "$n" "$n" >> "$FIX/levels.md"
done

# SIBLING heading entries under one section — the shape memory/backlog.md is actually written in
# (measured: 83 of its 84 id-shaped headings sit at level 2 under a level-1 heading, so every one of
# them has same-level siblings). `section` used to be "the previous heading, whatever it was", with no
# level awareness at all, so siblings CHAINED: B-sib-beta reported B-sib-alpha as its section and a
# flat list of independent entries described a nesting the document does not contain. `parent_key` was
# already level-aware and correct, which is exactly why this survived — the two fields disagreed.
cat > "$FIX/siblings.md" <<'EOF'
## Open

### B-sib-alpha first sibling
### B-sib-beta second sibling
#### B-sib-gamma nested under beta
# B-sib-top a top-level entry
EOF

# --- H1 the kind vocabulary ---------------------------------------------------------------------
if py "sys.exit(0 if (zb.KIND_CHECKBOX, zb.KIND_BULLET, zb.KIND_TABLE, zb.KIND_HEADING)
        == ('checkbox', 'bullet', 'table', 'heading') else 1)"; then
  ok "(H1) KIND_* constants carry the documented string values"; else
  no "(H1) KIND_CHECKBOX/BULLET/TABLE/HEADING missing or renamed"; fi

if py "sys.exit(0 if zb.DEFAULT_KINDS == (zb.KIND_CHECKBOX, zb.KIND_BULLET, zb.KIND_TABLE) else 1)"; then
  ok "(H1) DEFAULT_KINDS is exactly today's tolerant set (heading NOT in it)"; else
  no "(H1) DEFAULT_KINDS is not (checkbox, bullet, table) — the default mode changed meaning"; fi

# `Entry.kind` must name the kind that ADMITTED the line, not the line's most specific dialect: a
# checkbox satisfies BOTH checkbox and bullet, so `kinds=(KIND_BULLET,)` used to yield rows stamped
# kind="checkbox" — a caller filtering on a kind it never asked for. The overlap itself is deliberate
# and documented in `_body_kinds`: `- [ ] x` IS a markdown bullet, so requesting bullets DOES select
# it (asserted below), and the row then reports "bullet". Under DEFAULT_KINDS both are wanted and the
# most specific one still wins, which is what keeps the H10 invariance and H3's alias exact.
if [ "$(py "
cb = '- [ ] B-x thing'
print('%s %s %s %d' % (
    list(zb.iter_entries(cb, kinds=(zb.KIND_BULLET,)))[0].kind,
    list(zb.iter_entries(cb, kinds=(zb.KIND_CHECKBOX,)))[0].kind,
    list(zb.iter_entries(cb))[0].kind,
    len(list(zb.iter_entries(cb, kinds=(zb.KIND_BULLET,))))))")" = "bullet checkbox checkbox 1" ]; then
  ok "(H1) kind is the kind that ADMITTED the line (bullet/checkbox/default), overlap documented"; else
  no "(H1) kind does not follow the request — a row carries a dialect the caller did not ask for"; fi

# The same line under a TABLE-only request must not be admitted at all — the overlap is checkbox and
# bullet only, so "admitted kind" cannot degrade into "any kind at all".
if py "sys.exit(0 if list(zb.iter_entries('- [ ] B-x thing', kinds=(zb.KIND_TABLE,))) == [] else 1)"; then
  ok "(H1) a checkbox bullet is NOT admitted as a table — the overlap is bounded"; else
  no "(H1) a checkbox bullet was admitted under kinds=(KIND_TABLE,)"; fi

# --- H2 the kinds= selectors are validated EAGERLY -----------------------------------------------
# WHERE the ValueError surfaces is the assertion, not merely whether one exists. `iter_entries` used
# to be a generator FUNCTION: `def` + `yield` means the body, `_requested_kinds` included, does not
# run until the first `next()`. MEASURED pre-fix — `iter_entries('## B-x y', kinds=())` returned a
# generator object with no error at all, and so did the other two bad calls. A caller that builds the
# iterator and passes it on therefore got the error in a different function from the bad argument, or
# never got it. `list(...)` around the probe — what these three assertions used to do — iterates
# immediately and so cannot tell eager validation from deferred: it passed either way.
#
# NO list(), NO next(): construction ALONE must raise. That is the whole probe. It fails if
# `iter_entries` is ever turned back into a generator function (the validation would move to first
# iteration and the call would return cleanly), and it fails if a selector check is dropped.
bad_call(){ py "
try:
    zb.iter_entries('## B-x y', $1)
except ValueError:
    sys.exit(0)
sys.exit(1)"; }

if bad_call "checkbox_only=True, kinds=('heading',)"; then
  ok "(H2) kinds= together with checkbox_only= raises ValueError AT CALL TIME"; else
  no "(H2) kinds= plus checkbox_only= did not raise on construction — the two selectors can disagree silently until someone iterates"; fi

# An unknown kind must raise, not yield nothing: a typo ('headings') would otherwise read as
# "this file has no heading entries", which is the false-green this whole suite exists to prevent.
if bad_call "kinds=('headings',)"; then
  ok "(H2) an unknown kind raises ValueError AT CALL TIME, not on first iteration"; else
  no "(H2) a misspelled kind did not raise on construction — the typo reads as 'no entries' until iteration, and elsewhere"; fi

# An EMPTY kinds=() has the SAME failure mode as a misspelled one and must raise for the same reason:
# a caller whose kind list filtered down to nothing (or that lost a constant) would read the empty
# iterator as "this file holds no entries of the kinds I asked for". "Yields nothing" is not a
# meaningful contract to pin — it is the false green, one step earlier than the typo.
if bad_call "kinds=()"; then
  ok "(H2) kinds=() raises ValueError AT CALL TIME — an empty selection cannot read as 'no such entries'"; else
  no "(H2) kinds=() did not raise on construction — same false negative as a misspelled kind"; fi

# The counter-control: a GOOD call must still construct without touching the text. Without this the
# three probes above would also pass if `iter_entries` raised ValueError unconditionally.
if py "
it = zb.iter_entries('## B-x y', kinds=(zb.KIND_HEADING,))
sys.exit(0 if list(it)[0].ident == 'B-x' else 1)"; then
  ok "(H2) control: a VALID kinds= still constructs and then yields"; else
  no "(H2) a valid kinds= no longer works — the eager validation rejects good input too"; fi

# `kinds=` MUST BE MATERIALIZED ONCE. It used to be read twice — the unknown-kind scan, then
# `tuple(kinds)` — so a ONE-SHOT iterable was exhausted by the first pass and the second returned ().
# MEASURED pre-fix: `kinds=iter(('heading',))` yielded 0 entries with NO error at all, which is the
# exact false negative ("this file has no heading entries") that the raises above exist to prevent,
# arriving through the argument's TYPE instead of its value. The assertion is EQUALITY with the tuple
# call, not "> 0": a parser that dropped rows for both would otherwise pass.
if py "
t = '## B-x first\n## B-y second\n'
a = [e.ident for e in zb.iter_entries(t, kinds=(zb.KIND_HEADING,))]
b = [e.ident for e in zb.iter_entries(t, kinds=iter((zb.KIND_HEADING,)))]
c = [e.ident for e in zb.iter_entries(t, kinds=(k for k in zb._ALL_KINDS if k == 'heading'))]
sys.exit(0 if a == b == c and len(a) == 2 else 1)"; then
  ok "(H2) a one-shot kinds= iterable yields the same as the tuple — materialized once"; else
  no "(H2) kinds= is consumed twice — a generator or iterator silently selects NOTHING"; fi

# A bare string is a Sequence[str] to the type checker and iterates into CHARACTERS, so it used to
# fail as "unknown kind(s): 'h', 'e', 'a'…" — an error describing the symptom and hiding the mistake.
# It must raise (it is not a valid selection) with a message naming the string itself.
if py "
try:
    zb.iter_entries('## B-x y', kinds='heading')
except ValueError as exc:
    sys.exit(0 if 'heading' in str(exc) and \"'h'\" not in str(exc) else 1)
sys.exit(1)"; then
  ok "(H2) kinds='heading' (a bare str) raises AT CALL TIME, naming the string not its characters"; else
  no "(H2) a bare kinds= string was accepted, or still reports per-character unknown kinds"; fi

# --- H3 checkbox_only stays a permanent, silent alias --------------------------------------------
# It is published parser API documented as a permanent alias, NOT a deprecation. Until Task 2 spelled
# the pin out, all 7 of backlog-archive.py's write/gate sites were written this way; they now say
# `kinds=(zb.KIND_CHECKBOX,)` (H14), which is a readability change and must not be read as retiring
# the alias. Two reasons it has to keep working silently: the INSTALLED `~/.zuvo/` copy of these
# helpers lags the repo between `install.sh` runs, so an older `backlog-archive.py` calls a newer
# parser routinely; and every one of those callers is a write/gate path reached through
# `append-runlog`, where a DeprecationWarning on stderr is indistinguishable from a failure.
if py "
t = open(REAL).read()
a = [e.key for e in zb.iter_entries(t, checkbox_only=True)]
b = [e.key for e in zb.iter_entries(t, kinds=(zb.KIND_CHECKBOX,))]
sys.exit(0 if a == b and a else 1)"; then
  ok "(H3) checkbox_only=True == kinds=(KIND_CHECKBOX,) on the real file"; else
  no "(H3) the checkbox_only alias no longer matches kinds=(KIND_CHECKBOX,)"; fi

# The fixture is read and CLOSED before the window opens: an unclosed file object of the probe's own
# making raises a ResourceWarning inside it, which would read as the parser warning (it did, once).
if py "
with open(REAL) as fh:
    t = fh.read()
with warnings.catch_warnings(record=True) as w:
    warnings.simplefilter('always')
    list(zb.iter_entries(t, checkbox_only=True))
sys.exit(0 if not w else 1)"; then
  ok "(H3) checkbox_only emits no warning (stderr noise = failure on write paths)"; else
  no "(H3) checkbox_only now warns — append-runlog paths read stderr as a failure"; fi

# --- H4 Entry stays positionally constructible at the OLD arity ----------------------------------
# A NamedTuple's field order IS its tuple order, so the three new fields must be appended with
# defaults. This positional construction is the only real probe of that rule.
if py "
e = zb.Entry(7, '- [ ] B-x y', 'B-x y', 'open', 'B-x', 'id:b-x', 'Open')
sys.exit(0 if (e.lineno == 7 and e.section == 'Open' and e.kind == zb.KIND_CHECKBOX
               and e.end_lineno == 0 and e.parent_key is None) else 1)"; then
  ok "(H4) old-arity positional Entry(...) still works, new fields default"; else
  no "(H4) positional Entry(...) at the old arity broke — a field was inserted, not appended"; fi

if py "sys.exit(0 if zb.Entry._fields[:7] == ('lineno', 'raw', 'body', 'status', 'ident', 'key', 'section')
        and zb.Entry._fields[7:] == ('kind', 'end_lineno', 'parent_key') else 1)"; then
  ok "(H4) the three new fields are appended LAST, in order"; else
  no "(H4) Entry field order changed — every positional caller and tuple unpack is affected"; fi

# --- H5 every heading level is an entry ----------------------------------------------------------
if [ "$(py "
es = list(zb.iter_entries(open('$FIX/levels.md').read(), kinds=(zb.KIND_HEADING,)))
print('%d %s' % (len(es), ' '.join(sorted(e.ident for e in es))))")" \
   = "6 B-lvl-1 B-lvl-2 B-lvl-3 B-lvl-4 B-lvl-5 B-lvl-6" ]; then
  ok "(H5) all six heading levels (#..######) yield one entry each, ident set"; else
  no "(H5) the level range is wrong — see levels.md fixture"; fi

if py "
es = list(zb.iter_entries(open('$FIX/levels.md').read(), kinds=(zb.KIND_HEADING,)))
sys.exit(0 if es and all(e.kind == zb.KIND_HEADING for e in es) else 1)"; then
  ok "(H5) heading entries carry kind=heading"; else
  no "(H5) a heading entry did not carry kind=heading"; fi

# The heading body is the post-hash text, computed WITHOUT body_of()/CHECKBOX_RE. Relying on a
# regex that happens to be a no-op today is how the next change to CHECKBOX_RE breaks this.
if [ "$(py "
e = list(zb.iter_entries('### B-alpha-one the heading IS the entry', kinds=(zb.KIND_HEADING,)))[0]
print(e.body)")" = "B-alpha-one the heading IS the entry" ]; then
  ok "(H5) heading body is the post-hash text, hashes and spacing stripped"; else
  no "(H5) heading body is not the post-hash text"; fi

if py "
e = list(zb.iter_entries('## B-driftguard-bounded-age — DONE', kinds=(zb.KIND_HEADING,)))[0]
sys.exit(0 if e.key == 'id:b-driftguard-bounded-age' else 1)"; then
  ok "(H5) a heading entry keys off its id (what lookup needs)"; else
  no "(H5) a heading entry does not key off its id — every archive lookup still misses"; fi

# --- H6 the eight negative shapes ----------------------------------------------------------------
# Vacuity guard first: the same parse must produce the four expected heading entries.
if [ "$(py "
es = list(zb.iter_entries(open('$FIX/heads.md').read(), kinds=(zb.KIND_HEADING,)))
print(' '.join(e.ident for e in es))")" = "B-alpha-one B-beta-two B-deep-six B-top-one" ]; then
  ok "(H6) vacuity guard: the fixture's four id-shaped headings ARE entries"; else
  no "(H6) the fixture's positive controls are not entries — negatives below prove nothing"; fi

# Second vacuity guard, this one for the NEGATIVES. neg_line() addresses heads.md by LINE NUMBER,
# so a line inserted into the fixture above a negative silently re-points that check at a different
# (or blank) line, where "not an entry" is trivially true — a green assertion checking nothing.
# Every spec therefore carries the text its line must still contain. Drift FAILS here AND drops the
# loop count below 8, so the count assertion is a real second gate rather than a tautology.
anchor(){ py "
line = open('$FIX/heads.md').read().splitlines()[$1 - 1]
sys.exit(0 if '''$2''' in line else 1)"; }

# Every kind requested, so a negative shape cannot sneak in as a bullet or a table either.
neg_line(){ py "
kinds = zb.DEFAULT_KINDS + (zb.KIND_HEADING,)
lines = {e.lineno for e in zb.iter_entries(open('$FIX/heads.md').read(), kinds=kinds)}
sys.exit(0 if $1 not in lines else 1)"; }
i=0
# <lineno>:<text that line must still contain>:<what the shape is>
for spec in "1:# Tech Debt Backlog:# Tech Debt Backlog (no id)" \
            "11:[obs]:## [obs] prose heading" \
            "12:(closed) B-paren:## (closed) B-x — parenthesised, not a definition" \
            "13:Archived from backlog.md:## Archived from backlog.md on <date>" \
            "14:## B-IND:  ## B-IND indented heading" \
            "15:## B-Q:  > ## B-Q quoted heading" \
            "16:####### B-seven:####### B-seven — seven hashes, past HEADING_RE's 1..6 range" \
            "17:##B-nospace:##B-nospace — no whitespace after the hashes" \
            "18:## B-tpl-head:## B-tpl-head fingerprint | source-task — a TEMPLATE heading"; do
  ln="${spec%%:*}"; rest="${spec#*:}"; needle="${rest%%:*}"; what="${rest#*:}"
  if anchor "$ln" "$needle"; then
    if neg_line "$ln"; then ok "(H6) not an entry: $what"; else no "(H6) became an entry: $what"; fi
    i=$((i+1))
  else
    no "(H6) fixture drift: heads.md line $ln no longer holds '$needle' — shape NOT checked"
  fi
done
[ "$i" -eq 9 ] && ok "(H6) all nine negative shapes were checked" \
  || no "(H6) only $i of 9 negative shapes ran"

# The ninth shape needs its own explanation, because unlike the other eight it is not about HASHES.
# `TEMPLATE_RE` catches a line that DOCUMENTS the entry format instead of recording an item, and its
# only call site was the NON-heading branch of `_iter_entries` — which `_heading_entry` never reaches.
# MEASURED pre-fix: '## B-tpl-head fingerprint | source-task' matches BOTH TEMPLATE_RE and
# BODY_ID_RE, and was yielded as a real heading entry. The write path this feeds is the archiver, so
# the format documentation itself would have been moved into the archive. Id-anchoring exists so the
# rule can only UNDER-cover; admitting a template over-covers, which is the direction that loses data.
# Three more TEMPLATE_RE shapes, so the assertion cannot pass on one lucky alternative of that regex.
if [ "$(py "
out = []
for h in ('## B-tplA severity: [critical|high|medium]',
          '## B-tplB <field> | <value>',
          '## B-tplC CRITICAL / HIGH'):
    out.append(str(len(list(zb.iter_entries(h, kinds=(zb.KIND_HEADING,))))))
print(' '.join(out))")" = "0 0 0" ]; then
  ok "(H6) every TEMPLATE_RE shape is refused as a heading entry, not just the fixture's"; else
  no "(H6) a TEMPLATE_RE heading shape was admitted as an entry — the format doc would be archived"; fi

# The other half of the contract, exactly as for the indented headings: skipping the ENTRY must not
# skip the BOOKKEEPING. A template heading is still a REAL heading for scope, so at the SAME level it
# closes the enclosing entry's scope and DEEPER it closes nothing. Fails if `return None` were placed
# before the stack pop (the child would be handed to B-parent) or if the template heading still
# PUSHED (the child would be handed to the template).
if [ "$(py "
def child_parent(mid):
    t = '## B-parent the parent entry\n' + mid + '\n- [ ] B-child a child\n'
    return str([e.parent_key for e in zb.iter_entries(t) if e.ident == 'B-child'][0])
print('%s|%s' % (child_parent('## B-tpl fingerprint | source-task'),
                 child_parent('### B-tpl fingerprint | source-task')))")" = "None|id:b-parent" ]; then
  ok "(H6) a skipped template heading still tracks scope (same level closes, deeper does not)"; else
  no "(H6) the template heading's stack bookkeeping is wrong — parent_key below it is mis-attributed"; fi

# --- H7 a heading entry's section is its ENCLOSING heading, never a sibling ----------------------
if [ "$(py "
es = {e.ident: e for e in zb.iter_entries(open('$FIX/heads.md').read(), kinds=(zb.KIND_HEADING,))}
print(es['B-alpha-one'].section)")" = "Open" ]; then
  ok "(H7) a heading entry's section is its enclosing heading"; else
  no "(H7) a heading entry's section is not its enclosing heading"; fi

# ALL FOUR sections pinned, not just the first. Pinning only the FIRST entry is how the sibling bug
# survived review: the first entry's section is the same under both the broken and the correct rule
# (its predecessor IS its enclosing heading), so the assertion was green while every entry after it
# was wrong. MEASURED pre-fix on this fixture: B-sib-beta='B-sib-alpha first sibling' (should be
# 'Open') and B-sib-top='B-sib-gamma nested under beta' (should be empty).
#
# What makes each field fail:
#   B-sib-alpha  'Open'   — the control; fails only if enclosing lookup breaks entirely.
#   B-sib-beta   'Open'   — FAILS on the sibling-chaining bug (its predecessor is a same-level entry).
#   B-sib-gamma  parent   — FAILS if the level stack pops too eagerly, and if heading ENTRIES stopped
#                           counting as sections at all (it would read 'Open' and lose the nesting
#                           that parent_key reports).
#   B-sib-top    ''       — FAILS if a DEEPER preceding heading is allowed to be an enclosing one.
if [ "$(py "
es = {e.ident: e for e in zb.iter_entries(open('$FIX/siblings.md').read(), kinds=(zb.KIND_HEADING,))}
print('|'.join(es[i].section for i in
               ('B-sib-alpha', 'B-sib-beta', 'B-sib-gamma', 'B-sib-top')))")" \
   = "Open|Open|B-sib-beta second sibling|" ]; then
  ok "(H7) sibling heading entries share their enclosing section; nesting and top level pinned"; else
  no "(H7) sibling heading entries chain through section, or the nesting/top-level case moved"; fi

# parent_key must AGREE with section on the same fixture: gamma is inside beta, the two level-3
# siblings are inside nothing. The two fields disagreeing is what the sibling bug looked like.
if [ "$(py "
es = {e.ident: e for e in zb.iter_entries(open('$FIX/siblings.md').read(), kinds=(zb.KIND_HEADING,))}
print('%s %s %s' % (es['B-sib-alpha'].parent_key, es['B-sib-beta'].parent_key,
                    es['B-sib-gamma'].parent_key))")" = "None None id:b-sib-beta" ]; then
  ok "(H7) parent_key agrees with section on the sibling fixture"; else
  no "(H7) parent_key and section disagree about the sibling fixture's nesting"; fi

# A same-level `## Open` is a SIBLING of `## B-x`, not an enclosing heading, so the entry has NO
# section. Pinned deliberately rather than left to chance: the tolerant reading ("the nearest
# preceding heading, whatever its level") is exactly the rule that made siblings chain. The real file
# never uses this shape — its entries nest under a lower-level heading — but the semantics are stated
# here so a future change to the flat case is a visible decision, not a silent one.
if [ "$(py "
es = list(zb.iter_entries('## Open\n## B-flat-a first\n## B-flat-b second\n',
                          kinds=(zb.KIND_HEADING,)))
print('|'.join(repr(e.section) for e in es))")" = "''|''" ]; then
  ok "(H7) a SAME-LEVEL heading is a sibling, not a section (both entries: empty)"; else
  no "(H7) a same-level heading was taken as an enclosing section — the chaining rule is back"; fi

# The structural invariant, replacing `all(e.section != e.body)` — which was VACUOUS: while siblings
# chained, each entry's section was the PREVIOUS entry's body and never its own, so the check passed
# on precisely the corpus that was broken. The real rule: an entry's `section` is empty, or it is the
# text of a heading at a STRICTLY LOWER level than the entry's own. A sibling fails it; itself fails
# it; a deeper heading fails it. It is checked on the real file too, where it FAILED pre-fix for 83
# of the 84 id-shaped headings.
sec_is_enclosing(){ py "
t = open('$1').read()
lv = {}
for l in t.splitlines():
    s = l.strip()
    if not l.lstrip().startswith('#'):
        continue
    h = zb.HEADING_RE.match(s)
    if h:
        lv.setdefault(h.group(1).strip(), set()).add(len(s) - len(s.lstrip('#')))
es = list(zb.iter_entries(t, kinds=(zb.KIND_HEADING,)))
bad = []
for e in es:
    if e.section == '':
        continue
    s = e.raw.strip()
    own = len(s) - len(s.lstrip('#'))
    if not any(x < own for x in lv.get(e.section, ())):
        bad.append((e.ident, own, e.section[:40]))
if not es:
    print('no heading entries parsed — the invariant would hold vacuously')
    sys.exit(1)
if bad:
    print('%d of %d: %r' % (len(bad), len(es), bad[:3]))
    sys.exit(1)
sys.exit(0)"; }
for f in siblings.md heads.md; do
  if sec_is_enclosing "$FIX/$f"; then
    ok "(H7) every heading entry's section is a strictly-lower-level heading ($f)"; else
    no "(H7) a heading entry's section is a sibling, itself, or a deeper heading ($f)"; fi
done
if sec_is_enclosing "$REAL"; then
  ok "(H7) …and on the real file, where the sibling bug hit 83 of 84 entries"; else
  no "(H7) the real file has heading entries whose section is not an enclosing heading"; fi

# Children of a heading entry keep today's section semantics: the heading text, verbatim.
if [ "$(py "
es = [e for e in zb.iter_entries(open('$FIX/heads.md').read()) if e.ident == 'B-alpha-sub']
print(es[0].section)")" = "B-alpha-one the heading IS the entry" ]; then
  ok "(H7) a sub-bullet still names its heading as section (unchanged)"; else
  no "(H7) the sub-bullet's section changed — the branch was inserted in the wrong place"; fi

# --- H8 heading status comes from has_resolution_marker ------------------------------------------
# DONE_SECTION is prefix-anchored, which is the original defect: the marker sits at the END of
# these lines. is_resolved_inline anchors at the head and scores 0 on the real file.
if py "sys.exit(0 if not zb.DONE_SECTION.match('## B-x — DONE') else 1)"; then
  ok "(H8) control: DONE_SECTION does NOT match '## B-x — DONE' (the original defect)"; else
  no "(H8) DONE_SECTION now matches a trailing marker — this suite's premise moved"; fi
if py "sys.exit(0 if not zb.is_resolved_inline('B-x — DONE') else 1)"; then
  ok "(H8) control: is_resolved_inline does NOT see a trailing marker"; else
  no "(H8) is_resolved_inline changed shape"; fi

if [ "$(py "
es = {e.ident: e.status for e in zb.iter_entries(open('$FIX/heads.md').read(), kinds=(zb.KIND_HEADING,))}
print('%s %s' % (es['B-beta-two'], es['B-alpha-one']))")" = "done open" ]; then
  ok "(H8) trailing-marker heading is done, unmarked heading is open"; else
  no "(H8) heading status is not driven by has_resolution_marker"; fi

# A RE-OPEN MARKER OUTRANKS THE RESOLUTION MARKER — the one place `has_resolution_marker` cannot be
# used raw. It is pre-existing and was only ever an archive-honesty GUARD stacked on top of a checkbox
# ("ticked AND says why", backlog-archive.py), and `_WRAPPED_MARKER_RE` counts "[REGRESSION …]" as a
# resolution CLAUSE on purpose, because for that guard's question a regression note IS a recorded
# resolution. Making it the SOLE status source for headings imported that blindness into status:
# "## B-x — DONE [REGRESSION …]" read as done, i.e. ARCHIVABLE, although backlog-protocol.md documents
# that exact form as a re-open and REOPEN_RE exists for it.
#
# The control below is the evidence that this is a HEADING-path defect and not a pre-existing one: on
# the IDENTICAL body the bullet path answers open, because its status comes from the checkbox and
# `is_resolved_inline` is head-anchored. The two paths must not disagree about the same text.
# These fail if REOPEN_RE stops being consulted, and the third fails if it is consulted too eagerly.
regr_status(){ py "
es = list(zb.iter_entries('''$1''', kinds=(zb.KIND_HEADING,)))
print(es[0].status if es else 'NO-ENTRY')"; }
[ "$(regr_status '## B-x — DONE [REGRESSION 2026-09-27: broke again]')" = "open" ] \
  && ok "(H8) a REGRESSION re-open marker keeps a marked heading OPEN (not archivable)" \
  || no "(H8) a re-opened heading entry still reads as done — the archiver would file live work"
[ "$(regr_status '## B-x — DONE — nawrót po #830')" = "open" ] \
  && ok "(H8) the recorded Polish re-open form ('nawrót') is honoured too" \
  || no "(H8) 'nawrót' did not re-open the entry, though REOPEN_RE matches it"
[ "$(regr_status '## B-x — DONE b9767b6a')" = "done" ] \
  && ok "(H8) control: WITHOUT a re-open marker a marked heading is still done" \
  || no "(H8) REOPEN_RE is being applied too eagerly — an ordinary closed heading reads as open"
if [ "$(py "
b = 'B-x — DONE [REGRESSION 2026-09-27: broke again]'
print('%s %s %s' % ([e.status for e in zb.iter_entries('- [ ] ' + b)][0],
                    zb.has_resolution_marker(b), zb.is_resolved_inline(b)))")" \
   = "open True False" ]; then
  ok "(H8) control: the BULLET path already answers open on the same body — the paths agree now"; else
  no "(H8) the bullet path's answer on the re-open body moved; re-derive which path owns the defect"; fi

# THE LAST MARKER WINS: the outranking is POSITIONAL, not an existence test. `REOPEN_RE.search(body)`
# has no sense of order, so a heading that was closed, re-opened and then GENUINELY re-resolved was
# forced open for ever and could never be archived again — the mirror of the defect above, equally
# silent, and measured on the third row below. The resolution side already reads positionally (the
# marker sits at the END of these lines), so the re-open side must too.
#
# ALL FOUR ORDERINGS, because each one fails for a different reason and any three of them pass under
# some wrong rule:
#   DONE only                — the control; fails if the positional compare rejects a plain closure.
#   DONE + REGRESSION        — fails if the re-open marker stops outranking an EARLIER closure.
#   DONE + REGRESSION + DONE — FAILS PRE-FIX: order-insensitive `search()` forces open for ever.
#   REGRESSION only          — fails if "later of the two" degrades into "a marker exists":
#                              `_WRAPPED_MARKER_RE` counts '[REGRESSION …]' as a resolution CLAUSE on
#                              purpose, and it matches from the opening bracket, so the word inside
#                              always starts LATER — which is the only reason this row reads open.
ord_status(){ py "
es = list(zb.iter_entries('''$1''', kinds=(zb.KIND_HEADING,)))
print(es[0].status if es else 'NO-ENTRY')"; }
if [ "$(printf '%s|%s|%s|%s' \
      "$(ord_status '## B-ord — DONE 2026-09-28')" \
      "$(ord_status '## B-ord — DONE [REGRESSION 2026-09-28: broke]')" \
      "$(ord_status '## B-ord — DONE [REGRESSION 2026-09-28: broke] — DONE again 2026-09-28')" \
      "$(ord_status '## B-ord — [REGRESSION 2026-09-28: broke]')")" \
   = "done|open|done|open" ]; then
  ok "(H8) the LAST marker decides: done / re-opened / re-resolved / re-opened-only all correct"; else
  no "(H8) the re-open guard is order-INSENSITIVE — a re-resolved heading can never be archived again"; fi

# The positional primitive is exported and its contract stated, so a future reader does not restore
# the existence test by "simplifying". -1 means no marker; `has_resolution_marker` is defined in terms
# of it, so the two can never recognise different marker sets. The EQUIVALENCE is checked over one
# body per marker GROUP, not over a single one: with only a bare-marker body ('… DONE …') the two
# agree even when the predicate has been re-narrowed to `_BARE_MARKER_RE` alone (measured — the
# assertion passed on exactly that regression), so a wrapped-caps body and a wrapped-phrase body,
# which no bare test can see, are what make the equivalence real.
if py "
b = 'B-x — DONE [REGRESSION 2026-09-28: broke] — DONE again'
bodies = ['B-x nothing here at all', b, 'B-x — DONE b9767b6a',
          'B-x [STALE — zweryfikowane w kodzie]', 'B-x (not a bug)', 'B-x OBALONE 2026-09-20']
same = all(zb.has_resolution_marker(x) is (zb.resolution_marker_pos(x) >= 0) for x in bodies)
sys.exit(0 if (zb.resolution_marker_pos('B-x nothing here at all') == -1
               and zb.resolution_marker_pos(b) > b.index('REGRESSION')
               and zb.has_resolution_marker('B-x [STALE — zweryfikowane w kodzie]')
               and same) else 1)"; then
  ok "(H8) resolution_marker_pos is positional, -1 when absent, and backs has_resolution_marker"; else
  no "(H8) resolution_marker_pos and has_resolution_marker disagree, or the position is wrong"; fi

# TWO STATUS SOURCES, ONE GUARD — recorded so it is a decision and not an oversight. A ticked checkbox
# carrying a regression marker stays DONE: its status source is the TICK, an explicit human act, which
# later prose does not undo. A heading has no tick, so its status is DERIVED from the marker text and
# therefore needs the re-open guard. This asserts the asymmetry ON PURPOSE; changing the ticked-bullet
# answer here would change `classify()` and archiving across every checkout and is tracked separately.
if [ "$(py "
b = 'B-x — DONE [REGRESSION 2026-09-28: broke]'
print('%s|%s|%s' % ([e.status for e in zb.iter_entries('- [x] ' + b)][0],
                    [e.status for e in zb.iter_entries('- [ ] ' + b)][0],
                    [e.status for e in zb.iter_entries('## ' + b, kinds=(zb.KIND_HEADING,))][0]))")" \
   = "done|open|open" ]; then
  ok "(H8) recorded: tick-derived status ignores REOPEN, marker-derived status honours it"; else
  no "(H8) the two status sources were 'harmonised' — check which path moved before accepting it"; fi

# --- H9 the real file: STRUCTURAL invariants only ------------------------------------------------
# WHAT BELONGS HERE AND WHAT DOES NOT. memory/backlog.md is a live, tracked file that grows several
# times a day (1812 -> 1958 -> 1989 lines during one session). So an assertion on it may only pin
# properties of the PARSER, never properties of today's data.
#
# Two assertions were removed for failing that test: `0 < n_marked < n_id` and `n_inline == 0`. Both
# are facts about the current corpus's content, not about the discriminator. A day on which every
# id-shaped heading happens to be open (n_marked == 0) or every one closed (n_marked == n_id) would
# turn this suite red for a reason that has nothing to do with the parser — and the corpus reaching
# either state is ordinary backlog work, not a defect. Same for n_inline: it is 0 because nobody has
# yet written a head-anchored marker on a heading, which anyone may do tomorrow without breaking
# anything. The marker-vs-inline DISCRIMINATION is a real claim and it is now asserted where it
# belongs — on the frozen fixture below, which holds both an open and a DONE heading entry and cannot
# grow behind the suite's back.
#
# What survives here is structural: every id-shaped heading yields exactly one entry (the
# discriminator is `BODY_ID_RE` on the post-hash text, so this holds at any size and any open/closed
# mix), and the corpus is non-empty so the invariant is not vacuous.
marker_report="$(py "
t = open('$FIX/heads.md').read()
ids = [zb.HEADING_RE.match(l.strip()).group(1).strip()
       for l in t.splitlines()
       if l.startswith('#') and zb.HEADING_RE.match(l.strip())
       and zb.BODY_ID_RE.match(zb.HEADING_RE.match(l.strip()).group(1).strip())]
print('%d %d %d' % (len(ids),
                    sum(1 for b in ids if zb.has_resolution_marker(b)),
                    sum(1 for b in ids if zb.is_resolved_inline(b))))")"
set -- $marker_report
if [ "$#" -eq 3 ]; then
  ok "(H9) the fixture marker probe produced all three counts"
  f_id="$1"; f_marked="$2"; f_inline="$3"
  echo "  ... fixture: id-shaped headings=$f_id marker=$f_marked inline=$f_inline"
  # The fixture holds exactly one closed heading entry ('#### B-beta-two — DONE b9767b6a') and three
  # open ones, so BOTH bounds are real and neither can drift with the backlog's content.
  { [ "$f_marked" -gt 0 ] && [ "$f_marked" -lt "$f_id" ]; } \
    && ok "(H9) has_resolution_marker DISCRIMINATES on the fixture ($f_marked of $f_id closed)" \
    || no "(H9) has_resolution_marker scores $f_marked of $f_id on the fixture — it marks all or none"
  [ "$f_inline" -eq 0 ] \
    && ok "(H9) is_resolved_inline scores 0 on the fixture — why it is NOT the status test" \
    || no "(H9) is_resolved_inline now matches a trailing marker; re-derive the status decision"
else
  no "(H9) the fixture marker probe produced $# field(s), not 3 — it crashed"
fi

heads_report="$(py "
t = open(REAL).read()
ids = [zb.HEADING_RE.match(l.strip()).group(1).strip()
       for l in t.splitlines()
       if l.startswith('#') and zb.HEADING_RE.match(l.strip())
       and zb.BODY_ID_RE.match(zb.HEADING_RE.match(l.strip()).group(1).strip())]
es = list(zb.iter_entries(t, kinds=(zb.KIND_HEADING,)))
print('%d %d' % (len(ids), len(es)))")"
# The probe's OUTPUT is gated first, on the word count. Defaulting the fields to "0" turned a crash
# inside the python above into n_entry==n_id==0, which PASSES "entries == id-shaped headings" — a
# false green in the one suite whose job is to prevent them. A crash is now a FAIL, and the derived
# assertions do not run at all on no output.
set -- $heads_report
if [ "$#" -eq 2 ]; then
  ok "(H9) the real-file probe produced both counts"
  n_id="$1"; n_entry="$2"
  echo "  ... real file: id-shaped headings=$n_id heading entries=$n_entry"
  [ "$n_id" -gt 0 ] && ok "(H9) the real file has id-shaped headings to parse ($n_id)" \
    || no "(H9) no id-shaped heading found in $REAL — the defect's own corpus vanished"
  [ "$n_entry" = "$n_id" ] && ok "(H9) every id-shaped heading yields exactly one entry ($n_entry)" \
    || no "(H9) $n_id id-shaped headings but $n_entry entries — the discriminator drifted"
else
  no "(H9) probe produced $# field(s), not 2 — it crashed; every count below it would read as 0 and PASS"
fi

# --- H10 the invariance that keeps the fleet index stable ----------------------------------------
# `fingerprint` is sha1(body[:200])[:12] and ~/.zuvo/backlog reads it, so DEFAULT_KINDS must select
# the same entries with byte-identical bodies as the pre-change parser did.
#
# WHAT THE ORACLE IS, precisely: `iter_entries` ITSELF out of a FROZEN SNAPSHOT of the pre-change
# module (tests/fixtures/zuvo-backlog-parse-frozen.pysnap, the file as commit e565df29bf75 records
# it), loaded by path under its own module name, and with it the whole chain it delegates to —
# body_of, entry_key, is_resolved_inline, definition_id, TEMPLATE_RE, HEADING_RE, ID_RE,
# DONE_SECTION/OPEN_SECTION. It is frozen, NOT independent: it is the same code at a revision the
# working tree cannot move. The frozen side is the snapshot; the moving side is the working tree.
#
# Two earlier shapes of this oracle were both weaker than they read. First it imported those HELPERS
# from the module UNDER TEST, which made its own claim ("a change inside iter_entries cannot move both
# sides at once") false for every one of them: a helper edit moved both sides together and the
# assertion stayed green. Then it kept the snapshot but RE-IMPLEMENTED the pre-change iteration loop
# inline, calling only the frozen helpers — so `iter_entries`, the one function this change rewrites,
# was never executed on the frozen side at all, and the hand-copied loop could drift from the code it
# claimed to freeze. Both are closed: the frozen side is now `old_zb.iter_entries(text)`.
#
# `git show HEAD:…` into a temp file was the first shape tried and it does not survive where this
# suite actually runs: the farm receives a file mirror with NO .git (measured on ryzen-tf, `fatal:
# not a git repository`), so every farm run would have lost the frozen side. The snapshot is frozen
# on every host, and its sha256 is pinned here so "frozen" is enforced rather than asserted in prose.
HEAD_MOD="$ROOT/tests/fixtures/zuvo-backlog-parse-frozen.pysnap"
FROZEN_SHA256="22491dc34f1bd0e0bd2c3d495283b478b7e2cc01ec0c67141cd766afd15430be"
if [ -f "$HEAD_MOD" ]; then
  ok "(H10) the oracle's frozen side is present ($(grep -c '' "$HEAD_MOD" | tr -d ' ') lines)"; else
  # TERMINATE. Without the snapshot there is no frozen side at all, and continuing produced a
  # misleading second failure: the sha256 probe below reads a file that is not there, prints nothing,
  # and reports "the frozen snapshot MOVED" — which sends the reader after a corrupted artifact when
  # the actual fault is a missing one. The oracle itself would then fail to load, four more times.
  no "(H10) $HEAD_MOD missing — the oracle has no frozen side and H10 would compare the module to itself"
  finish; fi
if [ "$(py "
import hashlib
print(hashlib.sha256(open('$HEAD_MOD', 'rb').read()).hexdigest())" 2>/dev/null)" = "$FROZEN_SHA256" ]; then
  ok "(H10) the frozen snapshot still hashes to its pinned sha256 — it has not been 'refreshed'"; else
  no "(H10) the frozen snapshot MOVED (sha256 mismatch) — a frozen oracle that tracks the module proves nothing"; fi

cat > "$FIX/oracle.py" <<'PYEOF'
import hashlib
import importlib.util
import re
import sys
from importlib.machinery import SourceFileLoader

sys.path.insert(0, sys.argv[1])
import zuvo_backlog_parse as zb  # noqa: E402  the module UNDER TEST (working tree)


def _load_frozen(path):
    """The frozen pre-change snapshot, imported by PATH under its own module name.

    Not `sys.path` + `import`: the snapshot declares the same module as the file under test, so a
    plain import would hand back the already-imported working-tree module from sys.modules and the
    oracle would silently be the module under test again — the very defect this loader closes.

    The explicit SourceFileLoader is required, not decoration: the snapshot is deliberately not
    named `*.py` (the lint corpus is `git ls-files '*.py'` and a frozen artifact must not absorb
    lint fixes), and `spec_from_file_location` returns None for an extension it has no loader for.
    """
    name = "zuvo_backlog_parse_frozen"
    spec = importlib.util.spec_from_file_location(name, path, loader=SourceFileLoader(name, path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


old_zb = _load_frozen(sys.argv[4])


def old_dialect(entry):
    """`(is_check, is_table)` for a frozen row, read off its raw line.

    The ONE thing the frozen module cannot answer: `kind` is the field this change ADDS, so no
    snapshot of the pre-change module has it. This is a two-line classification of a line's shape,
    not a re-implementation of the selection/status chain — that chain is `old_zb.iter_entries`
    itself, called below.
    """
    s = entry.raw.strip()
    return (bool(re.match(r"^[-*]\s*\[[ xX]\]", s)),
            s.startswith("|") and bool(old_zb.ID_RE.search(s)))


def nonempty(n, what):
    """Any mode that COMPARES must refuse an empty selection.

    With both sides at zero the `rows` branch printed `OK 0` and PASSED, so a parser that selected
    nothing whatsoever satisfied every H10 assertion. "The two sides agree" is only evidence when
    there is something for them to agree about.
    """
    if n == 0:
        print("EMPTY: %s selected 0 rows — the comparison would hold vacuously" % what)
        sys.exit(1)


text = open(sys.argv[2]).read()
# THE FROZEN MODULE'S OWN `iter_entries`, not a copy of it. This oracle used to re-implement the
# pre-change iteration loop inline and import only HELPERS from the snapshot — so the frozen
# `iter_entries`, the single function this change actually rewrites, was never executed. The
# duplicated loop was free to drift from the code it claimed to freeze (and a transcription slip in
# it would read as a parser defect, or hide one). The frozen side is now the frozen function.
old = list(old_zb.iter_entries(text))
new = list(zb.iter_entries(text))
what = sys.argv[3]
if what == "rows":
    a = [(e.lineno, e.raw, e.body, e.status, e.ident, e.key, e.section) for e in old]
    b = [(e.lineno, e.raw, e.body, e.status, e.ident, e.key, e.section) for e in new]
    nonempty(len(a), "rows (frozen side)")
    nonempty(len(b), "rows (working tree)")
    if a != b:
        diff = [(x, y) for x, y in zip(a, b) if x != y][:2]
        print("MISMATCH len %d/%d %r" % (len(a), len(b), diff))
        sys.exit(1)
    print("OK %d" % len(a))
elif what == "fingerprints":
    a = [hashlib.sha1(e.body[:200].encode()).hexdigest()[:12] for e in old]
    b = [x["fingerprint"] for x in zb.parse_backlog(sys.argv[2], text)]
    nonempty(len(a), "fingerprints")
    if a != b:
        print("MISMATCH %d/%d differing=%d" % (len(a), len(b), sum(1 for x, y in zip(a, b) if x != y)))
        sys.exit(1)
    print("OK %d" % len(a))
elif what == "kinds":
    # LENGTH FIRST, before zip. `zip` truncates to the shorter side, so a parser that dropped rows
    # entirely produced an empty `bad` list and printed OK — the dropped rows were never compared.
    # The `rows` branch already guarded this; this branch did not.
    if len(old) != len(new):
        print("MISMATCH len %d/%d — zip would truncate and hide the dropped rows" % (len(old), len(new)))
        sys.exit(1)
    nonempty(len(new), "kinds")
    want = {(True, False): zb.KIND_CHECKBOX, (True, True): zb.KIND_CHECKBOX,
            (False, True): zb.KIND_TABLE, (False, False): zb.KIND_BULLET}
    bad = [(e.lineno, e.kind) for r, e in zip(old, new)
           if e.kind != want[old_dialect(r)]]
    if bad:
        print("MISMATCH %r" % bad[:3])
        sys.exit(1)
    print("OK %d" % len(new))
elif what == "additive":
    heads = list(zb.iter_entries(text, kinds=(zb.KIND_HEADING,)))
    both = list(zb.iter_entries(text, kinds=zb.DEFAULT_KINDS + (zb.KIND_HEADING,)))
    nonempty(len(heads), "additive (heading entries)")
    nonempty(len(both), "additive (combined)")
    if len(both) != len(new) + len(heads):
        print("MISMATCH %d != %d + %d" % (len(both), len(new), len(heads)))
        sys.exit(1)
    if [e.lineno for e in both] != sorted(e.lineno for e in both):
        print("MISMATCH out of document order")
        sys.exit(1)
    print("OK %d" % len(both))
PYEOF
O(){ python3 "$FIX/oracle.py" "$ROOT/scripts/zuvo-home" "$REAL" "$1" "$HEAD_MOD"; }
out="$(O rows)" && ok "(H10) default-mode rows identical to the pre-change parser — $out" \
  || no "(H10) default-mode selection or fields MOVED: $out"
out="$(O fingerprints)" && ok "(H10) every parse_backlog fingerprint unchanged — $out" \
  || no "(H10) fingerprint drift — the fleet backlog index would re-key: $out"
out="$(O kinds)" && ok "(H10) each default-mode entry carries its dialect's kind — $out" \
  || no "(H10) a default-mode entry carries the wrong kind: $out"
out="$(O additive)" && ok "(H10) heading entries ADD to the default set, in document order — $out" \
  || no "(H10) requesting headings changed the non-heading result: $out"

# --- H11 the one deliberate corner, pinned so it cannot drift silently ---------------------------
# `-[x] foo` (no space after the dash) satisfied the old checkbox_only predicate but not the old
# tolerant one, so it was an entry in one mode and not the other. With KIND_CHECKBOX in
# DEFAULT_KINDS it is now an entry in both. Zero such lines exist in either backlog file here, so
# this is inert in practice — but it IS a semantics change, and it is pinned rather than discovered.
if py "
es = list(zb.iter_entries('-[x] B-nospace ticked without a space'))
sys.exit(0 if len(es) == 1 and es[0].kind == zb.KIND_CHECKBOX else 1)"; then
  ok "(H11) '-[x]' (no space) is a checkbox entry in default mode too — pinned"; else
  no "(H11) the '-[x]' corner moved; re-derive DEFAULT_KINDS against the old predicates"; fi
if py "
t = open(REAL).read()
bad = [i for i, l in enumerate(t.splitlines(), 1)
       if re.match(r'^[-*]\s*\[[ xX]\]', l.strip())
       and not (l.strip().startswith('- ') or l.strip().startswith('* '))]
sys.exit(0 if not bad else 1)"; then
  ok "(H11) the real file contains no such line — the corner is inert here"; else
  no "(H11) the real file now HAS space-less checkboxes; the H10 invariance needs re-measuring"; fi

# --- H12 parent_key: the enclosing heading-entry chain -------------------------------------------
if py "
t = open('$FIX/heads.md').read()
h = {e.ident: e for e in zb.iter_entries(t, kinds=(zb.KIND_HEADING,))}
b = {e.ident: e for e in zb.iter_entries(t)}
ok = (b['B-alpha-sub'].parent_key == h['B-alpha-one'].key
      and h['B-beta-two'].parent_key == h['B-alpha-one'].key
      and h['B-deep-six'].parent_key == h['B-beta-two'].key
      and h['B-top-one'].parent_key is None
      and h['B-alpha-one'].parent_key is None)
sys.exit(0 if ok else 1)"; then
  ok "(H12) parent_key names the nearest enclosing heading entry, None at the top"; else
  no "(H12) parent_key does not follow the heading-entry chain"; fi

# --- H12 which headings may MOVE the stack -------------------------------------------------------
# Three probes over one shape, '## B-parent' / <middle line> / '- [ ] B-child', because the answer to
# "whose child is it" is different for each middle line and the earlier code got one of them wrong:
#   '## Plain title'   a real sibling heading — CLOSES B-parent's scope, so parent_key is None.
#                      (Popping only for id-shaped headings would under-pop and claim the child.)
#   '### Plain sub'    a real DEEPER heading — pops nothing, the child stays inside B-parent.
#   '##B-nospace'      NOT a heading at all (CommonMark needs the space); it closes nothing, but the
#   '####### B-seven'  pre-fix code popped on it because the level was computed before HEADING_RE ran.
mid_parent(){ py "
t = '## B-parent the parent entry\n' + '''$1''' + '\n- [ ] B-child a child\n'
e = [x for x in zb.iter_entries(t) if x.ident == 'B-child'][0]
print(e.parent_key)"; }
[ "$(mid_parent '## Plain title')" = "None" ] \
  && ok "(H12) a same-level plain heading CLOSES the parent entry's scope (child parent_key=None)" \
  || no "(H12) a plain sibling heading did not close the parent scope — the child was mis-attributed"
[ "$(mid_parent '### Plain sub')" = "id:b-parent" ] \
  && ok "(H12) a DEEPER plain heading keeps the child inside the enclosing heading entry" \
  || no "(H12) a deeper plain heading closed the parent scope — over-popping"
[ "$(mid_parent '##B-nospace no space after the hashes')" = "id:b-parent" ] \
  && ok "(H12) '##x' is not a heading and does not move the stack" \
  || no "(H12) '##x' (no space — a paragraph) popped the heading stack: parent_key is wrong below it"
[ "$(mid_parent '####### B-seven seven hashes')" = "id:b-parent" ] \
  && ok "(H12) '#######' is past the level range and does not move the stack" \
  || no "(H12) '#######' (a paragraph) popped the heading stack"

# ONE NORMALIZATION for `section` and for the stack. These two used different ones: the caller matched
# HEADING_RE against `line.strip()` when updating `section`, while the entry path gated on
# `line.startswith('#')`. So an INDENTED heading — a real heading under CommonMark, which allows up to
# three leading spaces — moved `section` out of the enclosing heading entry's scope and left that entry
# on the stack. MEASURED pre-fix: with '  ## Plain title' in the middle the child reported
# section='Plain title' AND parent_key='id:b-parent', two fields of one row disagreeing about where
# the row lives. Both now say the scope is closed.
[ "$(mid_parent '  ## Plain title')" = "None" ] \
  && ok "(H12) an INDENTED plain heading closes the parent scope, like the unindented one" \
  || no "(H12) an indented heading moved section but not the stack — stale parent_key below it"
[ "$(mid_parent '  ## B-IND indented id-shaped heading')" = "None" ] \
  && ok "(H12) an indented ID-shaped heading pops the stack without BECOMING an entry" \
  || no "(H12) the indented id-shaped heading left a stale parent_key (or became an entry)"
# The other half of that contract, which the H6 negatives also pin: popping must not promote it.
if py "
t = '## B-parent the parent entry\n  ## B-IND indented id-shaped heading\n'
sys.exit(0 if [e.ident for e in zb.iter_entries(t, kinds=(zb.KIND_HEADING,))] == ['B-parent'] else 1)"; then
  ok "(H12) …and it is still NOT an entry — prose about an entry, not its definition"; else
  no "(H12) an indented id-shaped heading became an entry — the H6 negative would break too"; fi
# `section` for the row after it must agree: the indented heading IS the nearest preceding heading.
if [ "$(py "
t = '## B-parent the parent entry\n  ## Plain title\n- [ ] B-child a child\n'
print([e.section for e in zb.iter_entries(t) if e.ident == 'B-child'][0])")" = "Plain title" ]; then
  ok "(H12) section still names the indented heading — the two fields agree on the same rule"; else
  no "(H12) section and the stack disagree about whether an indented heading is a heading"; fi

# --- H12 the indentation TIERS: CommonMark allows 0-3 spaces, FOUR is a code block ---------------
# The tolerance above had no upper bound, so an ATX-LOOKING LINE INSIDE AN INDENTED CODE BLOCK was
# treated as a real heading — and a backlog documents its own format in code samples, so this shape is
# ordinary content, not a corner case. MEASURED pre-fix on the shape below: B-child reported
# section='B-fake inside a code block' AND parent_key=None — the fake line moved `section` and popped
# BOTH stacks, so a code sample re-parented every entry after it.
#
# Three tiers, and each assertion below fails for a different reason:
#   0 spaces   heading, may be an ENTRY            — fails if the bound is applied to column 0.
#   1-3 spaces heading for SCOPE only, never an entry — the pre-existing rule, pinned above and in H6;
#              re-checked here because a bound placed one space too tight would silently demote it.
#   4+ / tab   NOT a heading at all, touches nothing — the fix.
ind_shape(){ py "
t = '## B-parent real\n\n' + '''$1''' + '\n\n- [ ] B-child after\n'
e = [x for x in zb.iter_entries(t) if x.ident == 'B-child'][0]
print('%s %s' % (e.parent_key, e.section))"; }
[ "$(ind_shape '    ## B-fake inside a code block')" = "id:b-parent B-parent real" ] \
  && ok "(H12) a 4-space-indented ATX line is a CODE BLOCK: section and parent_key both untouched" \
  || no "(H12) a 4-space-indented '#' line still moved section and popped the stack"
[ "$(ind_shape "$(printf '\t## B-fake tabbed')")" = "id:b-parent B-parent real" ] \
  && ok "(H12) a TAB-indented ATX line is a code block too (a tab is four columns)" \
  || no "(H12) a tab-indented '#' line was treated as a heading"
[ "$(ind_shape '  ## B-IND three-space-or-less stays a heading')" = "None B-IND three-space-or-less stays a heading" ] \
  && ok "(H12) …while 1-3 spaces is STILL a heading for scope (pops, moves section, not an entry)" \
  || no "(H12) the 4-space bound was applied too tightly — a legal indented heading stopped counting"

# `section_done` is the third thing an indented '#' line must not touch, and it is the one with teeth:
# it flips the status of every unticked bullet below it. A '    ## Resolved' inside a code sample made
# an open bullet read as DONE — archivable. Neither `section` nor `parent_key` would have shown this.
if [ "$(py "
t = '## Open\n\n    ## Resolved\n\n- B-bullet no checkbox here\n'
e = [x for x in zb.iter_entries(t) if 'B-bullet' in x.body][0]
print('%s %s' % (e.status, e.section))")" = "open Open" ]; then
  ok "(H12) a code-block '## Resolved' does not flip section_done — the bullet below stays open"; else
  no "(H12) an indented '## Resolved' still flipped section_done: live work reads as archivable"; fi

# THE single normalization answers the tiers directly, so the rule is pinned at its source and not
# only through `iter_entries`. `indented` can now only ever mean 1-3 spaces.
if py "
sys.exit(0 if (zb._heading_parts('## Plain') == (2, 'Plain', False)
               and zb._heading_parts('   ## Plain') == (2, 'Plain', True)
               and zb._heading_parts('    ## Plain') is None
               and zb._heading_parts('\t## Plain') is None) else 1)"; then
  ok "(H12) _heading_parts: 0=heading, 1-3=indented heading, 4+/tab=not a heading"; else
  no "(H12) _heading_parts does not implement the 0-3 / 4+ CommonMark boundary"; fi

# end_lineno is the entry's own line until Task 3's level-aware block delimiter lands in
# backlog-archive.py — stated, not silently zero, so a caller cannot mistake 0 for "line 0".
if py "
es = list(zb.iter_entries(open('$FIX/heads.md').read(), kinds=zb.DEFAULT_KINDS + (zb.KIND_HEADING,)))
sys.exit(0 if es and all(e.end_lineno == e.lineno for e in es) else 1)"; then
  ok "(H12) end_lineno is populated (== lineno; block extent is the archiver's job)"; else
  no "(H12) end_lineno left at 0 or wrong — a caller would read 0 as a real line number"; fi

# --- H13 the write paths are still checkbox-only by default -------------------------------------
# Task 2 pins them explicitly; this asserts the DEFAULT cannot hand a heading entry to a write path.
if py "
t = open('$FIX/heads.md').read()
sys.exit(0 if not [e for e in zb.iter_entries(t, checkbox_only=True) if e.kind == zb.KIND_HEADING]
         and not [e for e in zb.iter_entries(t) if e.kind == zb.KIND_HEADING] else 1)"; then
  ok "(H13) no heading entry reaches checkbox_only or default mode unasked"; else
  no "(H13) a heading entry leaked into a default/checkbox_only walk — write paths would move it"; fi

# --- H14 THE MECHANICAL PIN GUARD: what the SOURCE of backlog-archive.py says --------------------
# Why a SOURCE assertion and not only the behavioural one below: the behavioural guard can only see
# the paths it thinks to call. A future edit that adds an `iter_entries` call to a NEW write path —
# or drops `kinds=` from an existing one because the default "looks tolerant enough" — passes every
# behavioural probe that does not happen to exercise that path. The source assertion sees it the
# moment it is written, which is the point at which it is cheap.
#
# THE PIN MUST BE SPELLED OUT AT THE CALL SITE. `checkbox_only=True` is a permanent, documented
# alias (H3) and means exactly the same thing to the parser — but `kinds=(zb.KIND_CHECKBOX,)` is
# what makes Task 4's opt-in a ONE-LINE reviewable diff at a site whose current selection is
# visible, instead of a reader having to know the alias table to tell a pinned site from a
# defaulted one. So the alias counts as UNPINNED here, deliberately, and the count of
# `checkbox_only` uses in this file is asserted to be zero.
ARCHIVE_PY="$ROOT/scripts/zuvo-home/backlog-archive.py"
PROTOCOL="$ROOT/shared/includes/backlog-protocol.md"
if [ -f "$ARCHIVE_PY" ]; then ok "(H14) backlog-archive.py present"; else
  no "(H14) $ARCHIVE_PY missing — the pin guard and every CLI probe below would check nothing"
  finish; fi
if [ -f "$PROTOCOL" ]; then ok "(H14) backlog-protocol.md present"; else
  no "(H14) $PROTOCOL missing — the amendment assertions below would check nothing"; finish; fi

# A FILE, not an inline heredoc, so the identical logic can be re-run against a mutated copy of the
# module when this assertion's own sensitivity has to be demonstrated.
cat > "$FIX/pinguard.py" <<'PYEOF'
"""Classify every `iter_entries(...)` call site in ONE module by how it selects kinds.

Prints: <n_pinned> <n_unpinned> <comma-separated owners of the unpinned ones> <n_checkbox_only>
Owners are the enclosing `def`, so "which function" is part of the verdict rather than a line
number that moves with every edit above it.

WHAT THIS GUARD COVERS, stated so its blind spots are not mistaken for coverage. MEASURED, by
re-running this file against mutated copies of the module (see the assertions below it):

  COVERED — every call whose callee resolves through an `import` statement in this same file:
  `import zuvo_backlog_parse as zb` → `zb.iter_entries(...)`, the same under ANY alias (the local
  name is READ OFF the import, not hardcoded), and `from zuvo_backlog_parse import iter_entries`
  → a bare `iter_entries(...)`. In all four dimensions at once: a new call anywhere in the file
  moves `n_pinned` or `n_unpinned`; an unpinned one in a new function changes the OWNER list even
  when the totals happen to balance; and `checkbox_only=` is counted separately, so swapping a
  pin for the alias is not a silent no-op. A wrapper `def` in this module is caught too, under
  its own name. Injecting a third unpinned call inside `find()` moved `7 2 cmd_index,find 0` to
  `7 3 cmd_index,find,find 0`; the same injection into `cmd_verify` gave `7 3
  cmd_index,cmd_verify,find 0` while `verify`'s own output stayed byte-identical — which is the
  case the behavioural half (H15) cannot see and this half is here for.

  NOT COVERED — resolution this AST matcher cannot perform, by construction:
    * `getattr(zb, "iter_entries")(...)`, or any callee assembled at runtime. A string is not a
      name; no AST matcher closes this, so it is documented rather than chased.
    * a call in ANY OTHER FILE. This scans the one path it is given. `backlog-collect.py` and the
      `~/.zuvo/` helpers each need their own assertion if they grow write paths.
    * a `kinds=` argument that is a NAME rather than the literal tuple (`kinds=CHECKBOX_ONLY`) —
      deliberately counted as UNPINNED, see `is_pinned`; not a blind spot but a choice.
  When the callee resolves through none of the import forms above, this exits non-zero rather than
  reporting "0 calls, all clean": a guard that cannot find its subject must fail, not pass.
"""
import ast
import sys

PARSER_MODULE = "zuvo_backlog_parse"
READERS = ("find", "cmd_index")


def parser_names(tree: ast.AST) -> tuple:
    """(module aliases, bare function names) the parser is reachable under IN THIS FILE.

    Read off the `import` statements instead of hardcoding `zb`, so renaming the alias — or
    importing the parser a second time under another name — cannot hide a call site from the scan.
    """
    mods, funcs = set(), set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            mods |= {a.asname or a.name for a in node.names if a.name == PARSER_MODULE}
        elif isinstance(node, ast.ImportFrom) and node.module == PARSER_MODULE:
            funcs |= {a.asname or a.name for a in node.names if a.name == "iter_entries"}
    return mods, funcs


def is_call(node: ast.AST, mods: set, funcs: set) -> bool:
    if not isinstance(node, ast.Call):
        return False
    f = node.func
    if isinstance(f, ast.Attribute) and f.attr == "iter_entries":
        return isinstance(f.value, ast.Name) and f.value.id in mods
    return isinstance(f, ast.Name) and f.id in funcs


def is_pinned(node: ast.Call) -> bool:
    """True iff the call spells `kinds=(zb.KIND_CHECKBOX,)` LITERALLY, here, at this site.

    Not "resolves to checkbox-only": a name bound elsewhere (`kinds=CHECKBOX_ONLY`) would satisfy
    the parser and defeat the whole purpose, which is that the selection is readable AT the write
    path. `checkbox_only=True` therefore does not count either — see the suite's comment.
    """
    for kw in node.keywords:
        if kw.arg != "kinds":
            continue
        v = kw.value
        return (isinstance(v, ast.Tuple) and len(v.elts) == 1
                and isinstance(v.elts[0], ast.Attribute) and v.elts[0].attr == "KIND_CHECKBOX")
    return False


def scan(node: ast.AST, owner: str, out: list, mods: set, funcs: set) -> None:
    """Attribute each call to its NEAREST enclosing def.

    `ast.walk` per FunctionDef would attribute a call inside a nested def to BOTH defs, and which
    one won would depend on walk order — a guard whose verdict depends on traversal order is not a
    guard. This descends explicitly instead.
    """
    for child in ast.iter_child_nodes(node):
        nxt = child.name if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)) else owner
        if is_call(child, mods, funcs):
            out.append((owner, child.lineno, is_pinned(child)))
        scan(child, nxt, out, mods, funcs)


src = open(sys.argv[1], encoding="utf-8").read()
tree = ast.parse(src)
p_mods, p_funcs = parser_names(tree)
if not p_mods and not p_funcs:
    sys.stderr.write("pinguard: %s imports %s under no name this scan can follow — every call site "
                     "would read as absent and the counts below would pass vacuously.\n"
                     % (sys.argv[1], PARSER_MODULE))
    sys.exit(2)
calls: list = []
scan(tree, "<module>", calls, p_mods, p_funcs)
pinned = [c for c in calls if c[2]]
loose = [c for c in calls if not c[2]]
print("%d %d %s %d" % (len(pinned), len(loose),
                       ",".join(sorted(o for o, _, _ in loose)) or "-",
                       src.count("checkbox_only")))
PYEOF

pin_report="$(python3 "$FIX/pinguard.py" "$ARCHIVE_PY")"
set -- $pin_report
if [ "$#" -eq 4 ]; then
  ok "(H14) the pin-guard scan produced all four fields"
  p_pin="$1"; p_loose="$2"; p_owners="$3"; p_alias="$4"
  echo "  ... pinned=$p_pin unpinned=$p_loose unpinned-in=$p_owners checkbox_only-uses=$p_alias"
  [ "$p_pin" -eq 7 ] \
    && ok "(H14) exactly 7 iter_entries calls are pinned kinds=(zb.KIND_CHECKBOX,) at the call site" \
    || no "(H14) $p_pin sites are pinned, not 7 — a write/gate path lost its explicit selection (or one was added)"
  [ "$p_owners" = "cmd_index,find" ] \
    && ok "(H14) the only unpinned calls are find() and cmd_index() — the two READ paths" \
    || no "(H14) unpinned iter_entries calls live in: $p_owners — a path outside find/cmd_index can see a heading entry"
  [ "$p_loose" -eq 2 ] \
    && ok "(H14) there are exactly 2 unpinned calls, so neither reader grew a second one" \
    || no "(H14) $p_loose unpinned calls, not 2"
  [ "$p_alias" -eq 0 ] \
    && ok "(H14) no checkbox_only= alias left in the module — every pin is spelled out" \
    || no "(H14) $p_alias checkbox_only= use(s) remain: a pinned and a defaulted site read alike, and Task 4's opt-in stops being a one-line diff"
else
  no "(H14) the pin-guard scan produced $# field(s), not 4 — it crashed, and every count below it would read as empty and PASS"
fi

# --- H14b MUTANTS: the read-dialect CONTRACT, and this guard's own sensitivity -------------------
# Everything above measures the module as it is. These measure what happens when it is WRONG, which
# is the only way to know the assertions are load-bearing rather than incidentally true.
#
# Two subjects, one mutant factory:
#   * `LOOKUP_KINDS`' import-time contract in backlog-archive.py. It used to read
#     `zb.DEFAULT_KINDS + (zb.KIND_HEADING,)` — a SECOND source of truth for the read dialect: the
#     day `DEFAULT_KINDS` gained `KIND_HEADING` it would list that kind TWICE (nothing in
#     `iter_entries` rejects a repeat), and any parser-side change to "today's tolerant set" moved
#     what `lookup`/`index` resolve without a diff at the read paths. The `derived` mutant below
#     re-applies that expression and MEASURES the duplicate, so the explicit form plus contract is
#     justified by a failing case and not by an argument.
#   * pinguard.py itself. Its docstring states what it covers and what it cannot (aliased imports
#     are now resolved from the `import` statement; `getattr` indirection and other files are not).
#     The last two assertions hold that statement to the code.
MKMUT="$FIX/mkmut.py"
cat > "$MKMUT" <<'PYEOF'
"""Write a named mutation of backlog-archive.py + the parser it imports into their own directory.

Usage: mkmut.py <archive.py> <parser.py> <kind> <outdir>

    none        byte-identical copies — the control, so a mutant that fails proves the MUTATION
                failed and not the copy mechanics (the parser must sit beside the archiver: the
                archiver puts its own directory on sys.path and imports the module from there)
    dup         LOOKUP_KINDS lists KIND_HEADING twice — the duplicate the derived form could mint
    drift       the PARSER's DEFAULT_KINDS gains a NEW dialect; the archiver is untouched
    headdefault the PARSER's DEFAULT_KINDS gains KIND_HEADING; the archiver is untouched
    derived     headdefault PLUS the archiver's old `zb.DEFAULT_KINDS + (zb.KIND_HEADING,)`
    alias       the parser is imported `as zb2` and every `zb.` renamed (pinguard subject)
    runtime     the import is assembled at runtime: `zb = __import__(...)` (pinguard subject)

Every substitution is counted and a miss is a hard error: a mutation that silently failed to apply
would make the assertion reading it pass for the wrong reason, which is the defect class this whole
block exists to rule out.
"""
import os
import re
import sys

EXPLICIT = ("LOOKUP_KINDS: Tuple[str, ...] = "
            "(zb.KIND_CHECKBOX, zb.KIND_BULLET, zb.KIND_TABLE, zb.KIND_HEADING)")
DERIVED = "LOOKUP_KINDS: Tuple[str, ...] = zb.DEFAULT_KINDS + (zb.KIND_HEADING,)"
IMPORT = "import zuvo_backlog_parse as zb"
DEFAULTS = "DEFAULT_KINDS = (KIND_CHECKBOX, KIND_BULLET, KIND_TABLE)"


def sub(src, old, new, what):
    if src.count(old) != 1:
        sys.exit("mkmut: %s occurs %dx, expected once — the mutation would not apply: %r"
                 % (what, src.count(old), old))
    return src.replace(old, new)


arch_path, parser_path, kind, outdir = sys.argv[1:5]
arch = open(arch_path, encoding="utf-8").read()
parser = open(parser_path, encoding="utf-8").read()

if kind == "dup":
    arch = sub(arch, EXPLICIT, EXPLICIT[:-1] + ", zb.KIND_HEADING)", "the explicit LOOKUP_KINDS")
elif kind == "drift":
    parser = sub(parser, DEFAULTS, DEFAULTS[:-1] + ', "numbered")', "DEFAULT_KINDS")
elif kind in ("headdefault", "derived"):
    parser = sub(parser, DEFAULTS, DEFAULTS[:-1] + ", KIND_HEADING)", "DEFAULT_KINDS")
    if kind == "derived":
        arch = sub(arch, EXPLICIT, DERIVED, "the explicit LOOKUP_KINDS")
elif kind == "alias":
    arch = sub(arch, IMPORT + " ", IMPORT + "2 ", "the parser import")
    arch, n = re.subn(r"(?<![A-Za-z0-9_.])zb\.", "zb2.", arch)
    if n < 5:
        sys.exit("mkmut: renamed only %d `zb.` references — the alias mutant is not a rename" % n)
elif kind == "runtime":
    arch = sub(arch, IMPORT + " ", 'zb = __import__("zuvo_backlog_parse") ', "the parser import")
elif kind != "none":
    sys.exit("mkmut: unknown mutation %r" % kind)

os.makedirs(outdir, exist_ok=True)
with open(os.path.join(outdir, "backlog-archive.py"), "w", encoding="utf-8") as fh:
    fh.write(arch)
with open(os.path.join(outdir, os.path.basename(parser_path)), "w", encoding="utf-8") as fh:
    fh.write(parser)
PYEOF

CONTRACT="$FIX/contract.py"
cat > "$CONTRACT" <<'PYEOF'
"""Import a (possibly mutated) backlog-archive.py, then USE its read dialect, and report both.

Two steps, reported separately, because WHERE the contract fires is itself the thing under test: an
import-time abort exits 1, which `append-runlog` reads as `verify`'s namespace-violation exit and
turns into a blocked run in every repo. The contract must therefore fire on the READ path only.

Prints ONE line, always exit 0 — the shell decides what is a failure:
    IMPORT_RAISE <ExcType> <msg>                        importing the module failed (the regression)
    IMPORT_OK USE_RAISE <ExcType> <msg>                 clean import, contract fired at first USE
    IMPORT_OK USE_OK <n_kinds> <n_distinct> <relation:0|1> <kinds>
`relation` is set(LOOKUP_KINDS) == set(DEFAULT_KINDS) | {KIND_HEADING}, read off the parser the
module actually imported rather than off the repo copy.
"""
import importlib.util
import os
import sys

path = sys.argv[1]
sys.path.insert(0, os.path.dirname(os.path.realpath(path)))
spec = importlib.util.spec_from_file_location("ba_probe", path)
mod = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(mod)
except Exception as exc:                                    # noqa: BLE001 — reporting, not handling
    print("IMPORT_RAISE %s %s" % (type(exc).__name__, " ".join(str(exc).split())))
    raise SystemExit(0)
try:
    kinds = tuple(mod._lookup_kinds())
except Exception as exc:                                    # noqa: BLE001 — reporting, not handling
    print("IMPORT_OK USE_RAISE %s %s" % (type(exc).__name__, " ".join(str(exc).split())))
    raise SystemExit(0)
zb = getattr(mod, "zb", None) or getattr(mod, "zb2")
rel = set(kinds) == set(zb.DEFAULT_KINDS) | {zb.KIND_HEADING}
print("IMPORT_OK USE_OK %d %d %d %s"
      % (len(kinds), len(set(kinds)), 1 if rel else 0, ",".join(kinds)))
PYEOF

mkmut(){ python3 "$MKMUT" "$ARCHIVE_PY" "$MODULE" "$1" "$FIX/mut-$1"; }
contract(){ python3 "$CONTRACT" "$FIX/mut-$1/backlog-archive.py" 2>&1; }

# The control FIRST. If a byte-identical copy does not import and satisfy the contract, every RAISE
# below could be the copy's fault and this block would be measuring the harness.
if mkmut none; then
  c_none="$(contract none)"
  echo "  ... control: $c_none"
  case "$c_none" in
    "IMPORT_OK USE_OK 4 4 1 checkbox,bullet,table,heading")
      ok "(H14b) control: the module imports, and on first USE LOOKUP_KINDS is duplicate-free and exactly DEFAULT_KINDS + heading" ;;
    *)
      no "(H14b) control: an UNMUTATED copy reported '$c_none' — the mutants below prove nothing" ;;
  esac
else
  no "(H14b) the mutant factory could not even write the control copy — every assertion below is vacuous"
fi

# The requested duplicate, reintroduced by hand: the contract must refuse to import.
mkmut dup >/dev/null 2>&1
c_dup="$(contract dup)"
case "$c_dup" in
  "IMPORT_OK USE_RAISE RuntimeError LOOKUP_KINDS lists a kind twice"*)
    ok "(H14b) a reintroduced duplicate kind fails ON USE, with the import left clean — $c_dup" ;;
  "IMPORT_RAISE"*)
    no "(H14b) the duplicate mutant failed AT IMPORT ($c_dup) — that exit is what append-runlog misreads as BACKLOG_NAMESPACE_VIOLATION; the check belongs on the read path" ;;
  "IMPORT_OK USE_OK"*)
    no "(H14b) LOOKUP_KINDS with KIND_HEADING listed twice passed the contract ($c_dup) — the duplicate reaches _requested_kinds unchecked" ;;
  *)
    no "(H14b) the duplicate mutant reported '$c_dup' — not the contract's own error" ;;
esac

# A parser-side change to "today's tolerant set" must not move the read paths silently.
mkmut drift >/dev/null 2>&1
c_drift="$(contract drift)"
case "$c_drift" in
  "IMPORT_OK USE_RAISE RuntimeError the read dialect and the parser have diverged"*)
    ok "(H14b) a new dialect in DEFAULT_KINDS stops the READ paths instead of silently bypassing them" ;;
  "IMPORT_RAISE"*)
    no "(H14b) the drift mutant failed AT IMPORT ($c_drift) — verify/archive would die too, and append-runlog would blame a namespace violation" ;;
  "IMPORT_OK USE_OK"*)
    no "(H14b) DEFAULT_KINDS gained a dialect and the read dialect accepted it silently ($c_drift) — lookup/index would never see it and nothing would say so" ;;
  *)
    no "(H14b) the drift mutant reported '$c_drift' — not the contract's own error" ;;
esac

# THE ORIGINAL DEFECT, both halves, on the same mutated parser: explicit is benign where derived
# duplicates. Neither assertion means much without the other.
mkmut headdefault >/dev/null 2>&1
c_head="$(contract headdefault)"
case "$c_head" in
  "IMPORT_OK USE_OK 4 4 1 "*)
    ok "(H14b) DEFAULT_KINDS gaining KIND_HEADING leaves the EXPLICIT LOOKUP_KINDS duplicate-free and still contract-clean" ;;
  *)
    no "(H14b) the explicit LOOKUP_KINDS reported '$c_head' when KIND_HEADING joined DEFAULT_KINDS — expected IMPORT_OK USE_OK 4 4 1" ;;
esac
mkmut derived >/dev/null 2>&1
c_der="$(contract derived)"
case "$c_der" in
  "IMPORT_OK USE_RAISE RuntimeError LOOKUP_KINDS lists a kind twice"*)
    ok "(H14b) the OLD derived expression DOES duplicate on that same parser — measured, so the explicit form is a fix and not a preference" ;;
  "IMPORT_OK USE_OK 5 4 "*)
    no "(H14b) the derived expression duplicated the kind and the contract passed it ($c_der) — the contract is not enforcing" ;;
  *)
    no "(H14b) the derived mutant reported '$c_der' — expected the duplicate to be caught on use" ;;
esac

# pinguard.py's own two claims about what it can resolve.
mkmut alias >/dev/null 2>&1
a_report="$(python3 "$FIX/pinguard.py" "$FIX/mut-alias/backlog-archive.py" 2>&1)"
[ -n "$pin_report" ] && [ "$a_report" = "$pin_report" ] \
  && ok "(H14b) the pin guard follows the parser's LOCAL ALIAS: under 'as zb2' the verdict is unchanged ($a_report)" \
  || no "(H14b) under 'as zb2' the pin guard reported '$a_report' instead of '$pin_report' — renaming the import would hide every call site"
mkmut runtime >/dev/null 2>&1
r_report="$(python3 "$FIX/pinguard.py" "$FIX/mut-runtime/backlog-archive.py" 2>/dev/null)"
r_rc=$?
[ "$r_rc" -ne 0 ] && [ -z "$r_report" ] \
  && ok "(H14b) a runtime-assembled import makes the pin guard EXIT $r_rc, not report '0 calls, all clean' — the documented blind spot fails loudly" \
  || no "(H14b) with the import assembled at runtime the pin guard exited $r_rc printing '$r_report' — an unresolvable callee must fail, not pass vacuously"

# --- H14c THE BLAST RADIUS: a broken READ dialect must not take the GATE paths down ---------------
# MEASURED, and the reason the contract above is checked on use instead of at import. `append-runlog`
# runs the installed archiver as a BLOCKING gate:
#
#     if ! _bl_out=$("$ZUVO_BIN/backlog-archive.py" verify --repo "$PWD" 2>&1); then
#       echo "BACKLOG_NAMESPACE_VIOLATION: the same entry is defined in backlog.md AND ..." >&2
#       exit 2        # runs.log NOT appended
#
# A module-level `raise` exits 1, which is byte-for-byte indistinguishable from `verify`'s real
# "the same key is in both files" exit — so a broken read dialect would block every skill run in
# every repo on the machine and name the wrong cause. It would also be out of all proportion: the
# write and gate paths pin `kinds=(zb.KIND_CHECKBOX,)` at each call site (H14) and provably never
# consult LOOKUP_KINDS, so a read-dialect divergence cannot affect their answers. The rule this
# encodes: a contract fires where its value is USED, not at the widest point that can reach it.
#
# So, on the SAME mutant binary: the read path must fail loudly, and verify/archive/status must not.
mkdir -p "$FIX/wc/memory"
{ printf '# Tech Debt Backlog\n\n## Open\n\n'
  printf '## B-wc-head the heading entry the read paths must resolve\nprose under it\n\n'
  printf -- '- [x] B-wc-done [FIXED deadbee] src/one.ts a resolved checkbox for archive/status\n'
  printf -- '- [ ] B-wc-open src/two.ts a genuinely open checkbox\n'; } > "$FIX/wc/memory/backlog.md"

# Vacuity guard: the UNMUTATED copy must resolve that heading entry, or "the read path failed" below
# could be any other error and the gate-path assertions would be comparing two broken binaries.
wc_ctl="$(python3 "$FIX/mut-none/backlog-archive.py" lookup --repo "$FIX/wc" B-wc-head 2>&1)"
wc_ctl_rc=$?
[ "$wc_ctl_rc" -eq 10 ] \
  && ok "(H14c) vacuity guard: the unmutated copy answers OPEN on the fixture's heading entry (rc=10) — $wc_ctl" \
  || no "(H14c) the unmutated copy answered '$wc_ctl' rc=$wc_ctl_rc on the fixture — the probes below would measure the fixture, not the contract"

# One probe, used for both mutants: argv is passed as separate words (no `$cmd` word-splitting) so
# `archive --dry-run` is one subject rather than two hopeful ones.
gate_probe(){
  gp_m="$1"; gp_label="$2"; shift 2
  gp_out="$(python3 "$FIX/mut-$gp_m/backlog-archive.py" "$@" --repo "$FIX/wc" 2>&1)"; gp_rc=$?
  case "$gp_out" in
    *LOOKUP_KINDS*|*Traceback*)
      no "(H14c) \`$gp_label\` died under the $gp_m mutant (rc=$gp_rc): $(printf '%s' "$gp_out" | tail -1) — append-runlog would print BACKLOG_NAMESPACE_VIOLATION and refuse to append runs.log, in every repo" ;;
    *)
      ok "(H14c) \`$gp_label\` still runs under the $gp_m mutant (rc=$gp_rc) — the read-dialect contract's blast radius stops at the read paths" ;;
  esac
}
for m in dup drift; do
  rp_out="$(python3 "$FIX/mut-$m/backlog-archive.py" lookup --repo "$FIX/wc" B-wc-head 2>&1)"
  rp_rc=$?
  case "$rp_out" in
    *LOOKUP_KINDS*)
      [ "$rp_rc" -ne 0 ] \
        && ok "(H14c) the READ path DOES fail on the $m mutant (rc=$rp_rc) and names LOOKUP_KINDS — loud where it matters" \
        || no "(H14c) lookup exited 0 under the $m mutant while printing the contract error — a caller would read that as a verdict" ;;
    *)
      no "(H14c) lookup under the $m mutant answered '$(printf '%s' "$rp_out" | tail -1)' rc=$rp_rc without naming LOOKUP_KINDS — the contract is not reached on the read path" ;;
  esac
  gate_probe "$m" "verify" verify
  gate_probe "$m" "archive --dry-run" archive --dry-run
  gate_probe "$m" "status" status
done

# --- H15 the BEHAVIOURAL half: no write/gate path moves, counts or settles a heading entry -------
# The source guard above and this one catch different things and neither subsumes the other: a call
# site can be pinned and the surrounding code still hand a heading entry to a write path (a second
# selection layer, a merged list), and a path can be behaviourally clean today and grow an unpinned
# call tomorrow.
cat > "$FIX/ba.py" <<'PYEOF'
"""Load backlog-archive.py by PATH — its filename has dashes, so `import` cannot reach it."""
import importlib.util
import sys
from importlib.machinery import SourceFileLoader


def load(path):
    name = "backlog_archive_under_test"
    spec = importlib.util.spec_from_file_location(name, path, loader=SourceFileLoader(name, path))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod
PYEOF

pyb(){ python3 -c "
import sys
sys.path.insert(0, '$FIX')
sys.path.insert(0, '$ROOT/scripts/zuvo-home')
import zuvo_backlog_parse as zb
from ba import load
BA = load('$ARCHIVE_PY')
$1"; }

if pyb "sys.exit(0 if callable(BA.classify) and callable(BA.find) else 1)"; then
  ok "(H15) backlog-archive.py loads by path and exposes classify()/find()"; else
  no "(H15) backlog-archive.py does not load — none of the write-path probes below mean anything"
  finish; fi

# Two fixture repos that differ ONLY by four heading lines and their prose. w1 carries a RESOLVED
# heading entry ('— DONE <sha>', the archivable shape: 24 of the real file's 84 id-shaped headings
# are written exactly like this) and an OPEN one; w2 has neither. Every count a write path reports
# must be identical between them.
mkrepo(){ mkdir -p "$1/memory"; }
mkrepo "$FIX/w1"; mkrepo "$FIX/w2"
{ printf '# Tech Debt Backlog\n\n## Open\n\n'
  printf '## B-head-done — DONE b9767b6a\nprose recording the fix under the resolved heading entry\n\n'
  printf '## B-head-open the heading entry nobody has closed\nprose under the open heading entry\n\n'
  printf -- '- [x] B-cb-done [FIXED deadbee] src/one.ts the checkbox that SHOULD move\n'
  printf -- '- [ ] B-cb-open src/two.ts a genuinely open checkbox\n'
  printf '## (closed) B-paren-head not a definition\n'; } > "$FIX/w1/memory/backlog.md"
{ printf '# Tech Debt Backlog\n\n## Open\n\n'
  printf -- '- [x] B-cb-done [FIXED deadbee] src/one.ts the checkbox that SHOULD move\n'
  printf -- '- [ ] B-cb-open src/two.ts a genuinely open checkbox\n'; } > "$FIX/w2/memory/backlog.md"

# VACUITY GUARD, first and hardest. Every assertion in H15 is of the form "the write path did NOT
# see a heading entry", and all of them hold trivially on a fixture that has none — or on a parser
# that stopped recognising the shape. So the same fixture must first be shown to CONTAIN a heading
# entry that a heading-admitting write path would archive: id-shaped, status done, marker-carrying,
# no live sub-item.
if [ "$(pyb "
t = open('$FIX/w1/memory/backlog.md').read()
hs = {e.ident: e for e in zb.iter_entries(t, kinds=(zb.KIND_HEADING,))}
d = hs.get('B-head-done')
print('%d %s %s %s' % (len(hs), d.status if d else '-',
                       zb.has_resolution_marker(d.body) if d else '-',
                       '[ ]' not in d.body if d else '-'))")" = "2 done True True" ]; then
  ok "(H15) vacuity guard: w1 holds a DONE, marker-carrying heading entry a write path would move"; else
  no "(H15) w1 has no archivable heading entry — every 'no heading reached the write path' below is trivially true"; fi

# classify() feeds cmd_status AND cmd_archive; it is the single gate both sit behind.
if [ "$(pyb "
t = open('$FIX/w1/memory/backlog.md').read()
marked, unmarked, nested = BA.classify(t)
heads = [e.ident for _, e in marked + unmarked if e.kind == zb.KIND_HEADING]
print('%s|%s|%d|%s' % (','.join(e.ident for _, e in marked) or '-',
                       ','.join(e.ident for _, e in unmarked) or '-',
                       len(nested), ','.join(heads) or '-'))")" = "B-cb-done|-|0|-" ]; then
  ok "(H15) classify() returns the checkbox only — no KIND_HEADING entry in either group"; else
  no "(H15) classify() admitted a heading entry (or lost the checkbox) — cmd_archive would move it"; fi

# cmd_status's numbers, compared BETWEEN the two fixtures rather than against a literal: the open
# count is a property of the file, and pinning it as a constant would be a fact about this fixture
# instead of a claim about the code.
st_counts(){ python3 "$ARCHIVE_PY" status --repo "$1" 2>&1 | sed -n '1s/.*: \([0-9]*\) resolved.*(\([0-9]*\) with.*, \([0-9]*\) ticked.*; \([0-9]*\) genuinely open).*/\1 \2 \3 \4/p'; }
w1_st="$(st_counts "$FIX/w1")"; w2_st="$(st_counts "$FIX/w2")"
echo "  ... status w1='$w1_st' w2='$w2_st'"
if [ -n "$w1_st" ] && [ "$w1_st" = "$w2_st" ]; then
  ok "(H15) cmd_status reports identical counts with and without the heading entries ($w1_st)"; else
  no "(H15) cmd_status counts differ between w1='$w1_st' and w2='$w2_st' (or did not parse) — headings are reaching the gate"; fi

# The one that actually writes. --dry-run so nothing moves, and the file's own hash is checked after
# it: a dry run that mutated the backlog would otherwise be invisible here.
w1_sha_before="$(pyb "
import hashlib
print(hashlib.sha256(open('$FIX/w1/memory/backlog.md','rb').read()).hexdigest())")"
dry="$(python3 "$ARCHIVE_PY" archive --repo "$FIX/w1" --dry-run 2>&1)"
case "$dry" in
  *"would move 1 resolved entries"*) ok "(H15) cmd_archive --dry-run would move exactly the 1 checkbox entry" ;;
  *) no "(H15) cmd_archive --dry-run: $(printf '%s' "$dry" | head -1)" ;;
esac
case "$dry" in
  *B-head*) no "(H15) cmd_archive --dry-run named a heading entry among what it would move" ;;
  *) ok "(H15) cmd_archive --dry-run names no heading entry at all" ;;
esac
[ "$(pyb "
import hashlib
print(hashlib.sha256(open('$FIX/w1/memory/backlog.md','rb').read()).hexdigest())")" = "$w1_sha_before" ] \
  && ok "(H15) …and the backlog is byte-identical after the dry run" \
  || no "(H15) cmd_archive --dry-run MODIFIED the backlog"

# verify and drop-stale are the other two pinned paths, and both are gates with teeth: `verify`'s
# exit 1 makes `append-runlog` refuse to log a run. A heading entry present in BOTH files must
# therefore be invisible to them while the write paths stay checkbox-only — otherwise installing
# this helper turns every repo whose archive holds a moved heading into a blocked run.
mkrepo "$FIX/w3"
printf '## B-both-head — DONE b9767b6a\n' > "$FIX/w3/memory/backlog.md"
printf -- '- [ ] B-w3-open src/x.ts an open checkbox so the file is not heading-only\n' \
  >> "$FIX/w3/memory/backlog.md"
printf '## Archived from backlog.md on 2026-09-28 (1 completed items moved out)\n' \
  > "$FIX/w3/memory/backlog-done.md"
printf '## B-both-head — DONE b9767b6a\n' >> "$FIX/w3/memory/backlog-done.md"
if [ "$(pyb "
print(len([e for e in zb.iter_entries(open('$FIX/w3/memory/backlog.md').read(),
                                     kinds=(zb.KIND_HEADING,)) if e.ident == 'B-both-head']))")" = "1" ]; then
  ok "(H15) vacuity guard: w3's id-shaped heading IS a heading entry in both files"; else
  no "(H15) w3's heading is not parsed as an entry — the verify probe below is vacuous"; fi
out="$(python3 "$ARCHIVE_PY" verify --repo "$FIX/w3" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "${out##OK disjoint*}" ]; then
  ok "(H15) verify ignores a heading entry defined in BOTH files (exit 0) — no run is blocked"; else
  no "(H15) verify saw the heading pair: rc=$rc $out"; fi
out="$(python3 "$ARCHIVE_PY" drop-stale --repo "$FIX/w3" --id B-both-head --dry-run 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ -n "${out##*would remove*}" ]; then
  ok "(H15) drop-stale refuses a heading id — it is not defined in the checkbox namespace"; else
  no "(H15) drop-stale acted on a heading entry (rc=$rc): $out"; fi

# --- H16 the two READ paths DO resolve a heading entry — the user-facing defect ------------------
# `lookup` answered ABSENT for an id sitting in the file, so every audit skill's mandatory dedup
# check re-filed the finding as new: the exact loop backlog-protocol.md exists to prevent.
lk(){ out="$(python3 "$ARCHIVE_PY" lookup --repo "$1" "$2" 2>&1)"; printf '%s rc=%d' "$out" "$?"; }
case "$(lk "$FIX/w1" B-head-done)" in
  "OPEN id:b-head-done B-head-done backlog.md:"*"rc=10") ok "(H16) lookup resolves a RESOLVED heading entry: OPEN, exit 10" ;;
  *) no "(H16) lookup on a heading id: $(lk "$FIX/w1" B-head-done)" ;;
esac
case "$(lk "$FIX/w1" B-head-open)" in
  "OPEN id:b-head-open B-head-open backlog.md:"*"rc=10") ok "(H16) lookup resolves an OPEN heading entry too" ;;
  *) no "(H16) lookup on the open heading id: $(lk "$FIX/w1" B-head-open)" ;;
esac
# Two controls, so "resolves a heading id" cannot degrade into "answers OPEN for anything". The
# second is the id ANCHOR surviving all the way through the CLI: a parenthesised id in a heading is
# a mention, not a definition (H6 pins it at the parser; this pins it at the user-facing command).
case "$(lk "$FIX/w1" B-never-seen-anywhere)" in
  "ABSENT id:b-never-seen-anywhere rc=0") ok "(H16) control: an unknown id is still ABSENT, exit 0" ;;
  *) no "(H16) control failed — lookup answers OPEN for an id that is not there: $(lk "$FIX/w1" B-never-seen-anywhere)" ;;
esac
case "$(lk "$FIX/w1" B-paren-head)" in
  "ABSENT id:b-paren-head rc=0") ok "(H16) control: '## (closed) B-paren-head' is a mention, still ABSENT" ;;
  *) no "(H16) a parenthesised heading id became a definition at the CLI: $(lk "$FIX/w1" B-paren-head)" ;;
esac

# `index` is the other read path and it is what the fleet's dedup grep reads instead of the file.
python3 "$ARCHIVE_PY" index --repo "$FIX/w1" >/dev/null 2>&1
IDX="$FIX/w1/memory/.backlog-index.tsv"
if [ -f "$IDX" ]; then
  ok "(H16) index wrote $(basename "$IDX")"
  if [ "$(awk -F'\t' '$5=="B-head-done" {print $1"/"$2"/"$3}' "$IDX")" = "id:b-head-done/done/backlog.md" ]; then
    ok "(H16) the index carries the heading entry with its key, status and file"; else
    no "(H16) the heading entry is missing from the index, or its row is wrong: $(awk -F'\t' '$5 ~ /^B-head/' "$IDX" | tr '\t' '/')"; fi
  [ -n "$(awk -F'\t' '$5=="B-head-open"' "$IDX")" ] \
    && ok "(H16) …the open heading entry too" \
    || no "(H16) the OPEN heading entry is missing from the index"
  [ -z "$(awk -F'\t' '$5=="B-paren-head"' "$IDX")" ] \
    && ok "(H16) control: the parenthesised heading mention is NOT indexed" \
    || no "(H16) the index admitted a heading mention as an entry"
else
  no "(H16) index wrote no file — every row assertion above would read as empty"; fi

# AC1 on the REAL file, DERIVED. The plan's proof names one id (B-driftguard-bounded-age) and the
# acceptance artifact runs exactly that command — but memory/backlog.md is live and tracked, and
# that entry will be archived one day, so a literal here would be a false red with no defect behind
# it. The id is therefore taken FROM the file: the first id-shaped level-2 heading in it. The claim
# is the same one ("an entry written as a heading is findable by lookup") and it cannot go stale.
real_head_id="$(py "
for e in zb.iter_entries(open(REAL).read(), kinds=(zb.KIND_HEADING,)):
    print(e.ident)
    break")"
if [ -n "$real_head_id" ]; then
  ok "(H16) the real file offers a heading entry to look up ($real_head_id)"
  out="$(python3 "$ARCHIVE_PY" lookup --repo "$ROOT" "$real_head_id" 2>&1)"; rc=$?
  [ "$rc" -eq 10 ] && [ -z "${out##OPEN id:*}" ] \
    && ok "(H16) AC1: lookup resolves it on the real file — $out (exit 10)" \
    || no "(H16) AC1: lookup on $real_head_id answered '$out' rc=$rc — the reported defect is back"
else
  no "(H16) no heading entry in $REAL — AC1 cannot be checked on the real corpus"; fi

# --- H17 backlog-protocol.md states the dialect and the read/write boundary ----------------------
# THE A26 LESSON. A `grep -qi` on this document passes against text that was already there: it
# discusses `##` headings (the archive's section headings), `lookup`, `archive`, `verify`,
# `drop-stale`, `append-runlog` and `REGRESSION` in sections that predate this change. So every
# assertion below is scoped to the NEW section, and each one is paired with a control that COUNTS
# the same needle OUTSIDE that section. A non-zero outside count is the proof that the whole-file
# matcher — the one a reviewer would reach for first — was already true before the amendment and
# therefore proves nothing.
PROT_SECTION="The '## B-id' heading dialect"
# `##`-delimited slice of the doc, by heading TEXT. Printing the two halves separately is what makes
# the inside/outside controls possible at all.
prot(){ python3 -c "
import re, sys
want = '''$PROT_SECTION'''
inside, outside, cur = [], [], None
for ln in open('$PROTOCOL', encoding='utf-8').read().splitlines():
    m = re.match(r'^## +(.*?)\s*\$', ln)
    if m:
        cur = m.group(1)
    (inside if cur == want else outside).append(ln)
sys.stdout.write('\n'.join(inside if '$1' == 'in' else outside))"; }

prot_in="$(prot in)"
if [ -n "$prot_in" ]; then
  ok "(H17) backlog-protocol.md has a '## $PROT_SECTION' section ($(printf '%s\n' "$prot_in" | grep -c '') lines)"
else
  no "(H17) backlog-protocol.md has no '## $PROT_SECTION' section — the dialect is undocumented"; fi
prot_out="$(prot out)"
# The control that makes the section slice itself non-vacuous: the REST of the document must still
# be there. A `prot in` that accidentally captured everything (or a `prot out` that captured
# nothing) would make every outside count zero and turn the controls below into free passes.
[ "$(printf '%s\n' "$prot_out" | grep -c '')" -gt 200 ] \
  && ok "(H17) the slice is a slice: the rest of the document is outside it" \
  || no "(H17) the section slice swallowed the document — the controls below cannot discriminate"

# <needle>|<what it pins>
prot_needle(){ printf '%s\n' "$prot_in" | grep -qiF -- "$1"; }
prot_outside_count(){ printf '%s\n' "$prot_out" | grep -ciF -- "$1"; }
for spec in "id-shaped|the id anchor that decides what is an entry" \
            "lookup|the read path that must resolve a heading entry" \
            "index|the other read path" \
            "checkbox|the dialect the write paths stay pinned to" \
            "archive|the write path named in the boundary rule" \
            "drop-stale|the settle path named in the boundary rule" \
            "append-runlog|WHY the boundary exists: it runs in every repo, every run" \
            "REGRESSION|the re-open marker that outranks the resolution marker"; do
  needle="${spec%%|*}"; what="${spec#*|}"
  outside="$(prot_outside_count "$needle")"
  if prot_needle "$needle"; then
    if [ "$outside" -gt 0 ]; then
      ok "(H17) '$needle' is IN the new section — $what (and $outside line(s) outside it, so a whole-file grep was already true)"
    else
      ok "(H17) '$needle' is in the new section — $what (new to the document)"
    fi
  else
    no "(H17) the new section does not state '$needle' ($what); a whole-file grep would still match $outside pre-existing line(s) and read as documented"
  fi
done

# The three needles whose whole-file match was ALREADY true are named explicitly, so the control is
# a measurement and not a by-product of the loop above. If one of these ever reads 0 outside, the
# A26 argument for section-scoping has changed and this file should say so.
for n in "lookup" "archive" "REGRESSION"; do
  [ "$(prot_outside_count "$n")" -gt 0 ] \
    && ok "(H17) control: '$n' occurs $(prot_outside_count "$n")x OUTSIDE the new section — the naive matcher is vacuous" \
    || no "(H17) control: '$n' no longer occurs outside the new section; re-derive whether section scoping is still needed"
done

# The key rule itself has to admit the dialect, not only the new section: item 1 of "The key" lists
# the prefixes an id may HEAD with, and a `##` heading was not among them. A whole-file grep for a
# hash matches hundreds of lines here, which is exactly why this reads the one bullet.
if python3 -c "
import re, sys
t = open('$PROTOCOL', encoding='utf-8').read()
m = re.search(r'^   1\. \`id:<slug>\`.*?(?=^   2\.)', t, re.S | re.M)
sys.exit(0 if m and '##' in m.group(0) else 1)"; then
  ok "(H17) 'The key' item 1 admits the '##' heading position among the definition prefixes"; else
  no "(H17) 'The key' item 1 still lists only bullet/bold/bracket prefixes — a heading id reads as a mention"; fi

finish
