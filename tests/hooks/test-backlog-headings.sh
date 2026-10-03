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

# THE ENV GATE IS OFF for every assertion that is not explicitly about it. Task 4 puts the heading
# ARCHIVE remedy behind ZUVO_BACKLOG_HEADING_ARCHIVE=1, so an exported variable in the caller's shell
# would turn H15's "no write path moves a heading entry" group — which IS the default-off contract —
# into a report of a product defect that does not exist. Unset once, here, and asserted below; the
# gated probes set it per COMMAND with `env VAR=1`, never for the whole file.
unset ZUVO_BACKLOG_HEADING_ARCHIVE
HEAD_ARCH_ENV=ZUVO_BACKLOG_HEADING_ARCHIVE

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

if [ -z "${ZUVO_BACKLOG_HEADING_ARCHIVE:-}" ]; then
  ok "(H0) $HEAD_ARCH_ENV is unset — the default-off assertions measure the default"; else
  no "(H0) $HEAD_ARCH_ENV='${ZUVO_BACKLOG_HEADING_ARCHIVE:-}' survived the unset, so the write-path group below would measure the GATED behaviour and read its result as a defect"
  finish; fi

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

# --- H8b THE GUARD IS NOT THE PREDICATE: a heading has no tick, so tolerance becomes false "resolved"
# Added by the aggregate review, which found TWO live defects here that every one of the 289 assertions
# above walked straight past — the suite scored 289/0 both before and against the fix, so the coverage
# gap was the real finding and this block is it.
#
# `resolution_marker_pos`/`has_resolution_marker` are a deliberately LOOSE guard, and correctly so: the
# checkbox path archives an entry that is TICKED **and** says why, so the tick is the decision and the
# marker only corroborates. `_heading_entry` has no tick to lean on, so promoting that guard to the sole
# status source turned every tolerance into a false "resolved" — in the ARCHIVABLE direction, i.e. open
# work moved into backlog-done.md and answered ARCHIVED by lookup, the exact inverse of the defect this
# whole plan exists to fix. `heading_resolution_pos` is the stricter predicate; the guard is unchanged.
#
# Every string below was MEASURED as read-resolved under the old rule (fleet: 499 of 3561 heading
# entries read resolved, 449 under the new one, all 50 differences false positives, 0 flips the other
# way). Three of them come from this repo's own memory/backlog.md.
h8b_open="$(py "
for t in ['## B-1 — socket is closed too early on reconnect',
          '## B-2 — the fixed-width column header overflows on mobile',
          '## B-3 — investigate why the modal cannot be closed with Esc',
          '## B-RPT-FB-EXPORT-STALE — the export still shows yesterday rows',
          '## B-20260925-ADVLOG-LINE1-STALE — the ledger first line advertises the old schema',
          '## B-20260928-ARCHIVE-CQ11-722 — the two oversized functions are fixed, the module is not']:
    e = list(zb.iter_entries(t, kinds=(zb.KIND_HEADING,)))[0]
    print(e.status)" | sort -u | tr '\n' ' ')"
[ "$h8b_open" = "open " ] \
  && ok "(H8b) six MEASURED false-resolved headings all read open — lowercase prose ('is closed', 'fixed-width', 'are fixed') and a STALE inside the entry's own id no longer count as verdicts" \
  || no "(H8b) at least one lowercase-prose or id-derived heading still reads done (statuses: $h8b_open) — an OPEN entry that reads done is archivable, which is the direction that loses work"

# The other half, and the half that makes the first one safe: a stricter predicate must not start
# reporting CLOSED entries as open, which would un-archive real work and re-open settled findings.
# Both the leading `[FIXED sha] B-id` form and the trailing `— DONE sha` form are live corpus shapes.
h8b_done="$(py "
for t in ['## B-driftguard-bounded-age — DONE',
          '## B-x — FIXED abc1234',
          '## [FIXED 35e7f18b] B-SQLITE-TRACKED-DB — checked-in database at the sqlite default path',
          '## B-y [STALE — zweryfikowane w kodzie]',
          '## B-z OBALONE 2026-09-20, wpis byl NIEPRAWDZIWY',
          '## B-w — RESOLVED in PR #881',
          '## B-v [not a bug]',
          '## B-t — DONE b9767b6a [REGRESSION] — DONE again']:
    e = list(zb.iter_entries(t, kinds=(zb.KIND_HEADING,)))[0]
    print(e.status)" | sort -u | tr '\n' ' ')"
[ "$h8b_done" = "done " ] \
  && ok "(H8b) all eight genuine verdict forms still read done — caps bare, bracketed, Polish caps, and a LEADING [FIXED sha] before the id" \
  || no "(H8b) a genuine resolved heading now reads open (statuses: $h8b_done) — the stricter predicate over-corrected and would re-open settled findings"

# THE ID-STRIP IS SPAN-EXACT, not prefix-cut. `_ID_PREFIX` admits up to four bracketed tags BEFORE the
# id, so cutting at `BODY_ID_RE.match(...).end()` discards a LEADING verdict. Measured: doing it that
# lazy way flipped 5 genuinely-FIXED fleet entries to open. This pins the distinction directly, because
# the assertion above would still pass if only ONE of its eight forms regressed into the majority.
if py "sys.exit(0 if zb.strip_ident('[FIXED 35e7f18b] B-SQL-X — text') == '[FIXED 35e7f18b]  — text'
        and zb.strip_ident('B-plain — text') == ' — text' else 1)"; then
  ok "(H8b) strip_ident removes ONLY the id token's own span — a leading [FIXED sha] survives it"; else
  no "(H8b) strip_ident is cutting the whole BODY_ID_RE prefix — a leading verdict is being discarded and closed entries will read open"; fi

# MUTANT: the guard reinstated as the predicate. This is the one-line regression that reintroduces both
# defects at once, and it must be shown to break the assertions above rather than assumed to.
h8b_mut="$(py "
import re
pos = zb.resolution_marker_pos            # the LOOSE guard, i.e. the pre-fix behaviour
n = 0
for t in ['B-1 — socket is closed too early on reconnect',
          'B-RPT-FB-EXPORT-STALE — the export still shows yesterday rows']:
    if pos(t) >= 0:
        n += 1
print(n)")"
[ "$h8b_mut" = "2" ] \
  && ok "(H8b) MUTANT: reverting to the loose guard makes both probes read resolved again ($h8b_mut of 2) — the assertions above are load-bearing, not decorative" \
  || no "(H8b) the loose guard no longer reads those two as resolved ($h8b_mut of 2) — either the guard changed (it must not: the ticked path depends on its tolerance) or these probes stopped discriminating"

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
# The boundary rule lives in its OWN module: backlog-archive.py crossed rules/file-limits.md's
# automatic CQ11 FAIL (2x the 400-line Python default) when the level-and-sibling rule landed. Both
# mutant factories below must copy it beside the archiver, or every "the module imports" assertion
# would fail on a ModuleNotFoundError that has nothing to do with the mutation under test.
BLOCK_MOD="$ROOT/scripts/zuvo-home/zuvo_backlog_block.py"
# The heading-archive POLICY is its own module for the same reason: backlog-archive.py measured 850 raw
# lines with it inlined, past the automatic CQ11 FAIL at 800. It holds the family's ONE env-gated
# iter_entries call, so both mutant factories must copy it beside the archiver AND the guard has to
# scan it (H19c's family is derived, so it already does).
HEADPOL_MOD="$ROOT/scripts/zuvo-home/zuvo_backlog_heading.py"
# …and the MINT is the third module the 800-line ceiling pushed out of backlog-archive.py (it measured
# 818 with the mint's refusal invariants inlined). Same treatment: copied into every mutant dir, and
# scanned by the family guard because it imports the parser.
MINT_MOD="$ROOT/scripts/zuvo-home/zuvo_backlog_mint.py"
# …and the FILESYSTEM LAYER is the fourth: path resolution, `read`, the `Lock` and `atomic_write` left
# backlog-archive.py when it measured 763 raw lines against the 400-line default in
# rules/file-limits.md. It is the module the archiver cannot even IMPORT without (`Lock` and
# `atomic_write` are named in its import list), so both mutant factories must copy it into every
# mutant dir; H19c's derived family scans it because it imports the parser, and H24 below asserts that
# derivation explicitly rather than trusting the glob.
IO_MOD="$ROOT/scripts/zuvo-home/zuvo_backlog_io.py"
if [ -f "$ARCHIVE_PY" ]; then ok "(H14) backlog-archive.py present"; else
  no "(H14) $ARCHIVE_PY missing — the pin guard and every CLI probe below would check nothing"
  finish; fi
if [ -f "$PROTOCOL" ]; then ok "(H14) backlog-protocol.md present"; else
  no "(H14) $PROTOCOL missing — the amendment assertions below would check nothing"; finish; fi
if [ -f "$BLOCK_MOD" ]; then ok "(H14) zuvo_backlog_block.py present (the boundary rule's own module)"; else
  no "(H14) $BLOCK_MOD missing — backlog-archive.py imports entry_block/with_span from it, so nothing below loads"
  finish; fi
if [ -f "$HEADPOL_MOD" ]; then ok "(H14) zuvo_backlog_heading.py present (the heading-archive policy's own module)"; else
  no "(H14) $HEADPOL_MOD missing — backlog-archive.py imports heading_candidates from it, so nothing below loads"
  finish; fi
if [ -f "$MINT_MOD" ]; then ok "(H14) zuvo_backlog_mint.py present (the minted id's shape and position)"; else
  no "(H14) $MINT_MOD missing — backlog-archive.py imports mint_id/mint_into from it, so nothing below loads"
  finish; fi
if [ -f "$IO_MOD" ]; then ok "(H14) zuvo_backlog_io.py present (paths, read, the Lock, atomic_write)"; else
  no "(H14) $IO_MOD missing — backlog-archive.py imports Lock/atomic_write/read/resolve/is_ignored from it by name, so the module does not even IMPORT and every probe below would fail on a ModuleNotFoundError that says nothing about what it was testing"
  finish; fi

# A FILE, not an inline heredoc, so the identical logic can be re-run against a mutated copy of the
# module when this assertion's own sensitivity has to be demonstrated.
cat > "$FIX/pinguard.py" <<'PYEOF'
"""Classify every `iter_entries(...)` call site in ONE module by how it selects kinds.

Prints: <n_pinned> <n_unpinned> <owners of the unpinned> <n_checkbox_only> <n_env_gated>
        <owners of the env-gated>
Owners are the enclosing `def`, so "which function" is part of the verdict rather than a line
number that moves with every edit above it.

THE THIRD CATEGORY, added with Task 4's archive remedy: a call may ask for KIND_HEADING when, and
only when, the function it sits in RETURNS first unless `ZUVO_BACKLOG_HEADING_ARCHIVE` says
otherwise. Both halves are required and neither is sufficient — a heading request with no gate is
the fleet-wide write hazard (`install.sh` globs this directory into `~/.zuvo/` and `append-runlog`
runs `archive` in every repo), and a gate in front of a checkbox-only call selects nothing new and
must keep reading as an ordinary pinned site. The gate is verified by NAME RESOLUTION, not by the
presence of an `if`: the test has to mention the env-var constant, the literal, or a module-level
function that mentions one of them, so `if not lines: return` cannot pose as a gate.

WHAT THIS GUARD COVERS, stated so its blind spots are not mistaken for coverage. MEASURED, by
re-running this file against mutated copies of the module (see the assertions below it):

  COVERED — every call whose callee resolves through an `import` statement in this same file:
  `import zuvo_backlog_parse as zb` → `zb.iter_entries(...)`, the same under ANY alias (the local
  name is READ OFF the import, not hardcoded), and `from zuvo_backlog_parse import iter_entries`
  → a bare `iter_entries(...)`. In all four dimensions at once: a new call anywhere in the file
  moves `n_pinned` or `n_unpinned`; an unpinned one in a new function changes the OWNER list even
  when the totals happen to balance; and `checkbox_only=` is counted separately, so swapping a
  pin for the alias is not a silent no-op. A wrapper `def` in this module is caught too, under
  its own name. Injecting a third unpinned call inside `find()` moved backlog-archive.py's
  `7 2 cmd_index,find 0 0 -` to `7 3 cmd_index,find,find 0 0 -`; the same injection into
  `cmd_verify` gave `7 3 cmd_index,cmd_verify,find 0 0 -` while `verify`'s own output stayed
  byte-identical — which is the case the behavioural half (H15) cannot see and this half is here
  for. On the POLICY module, deleting the gate's early return moves its one gated site into the
  UNPINNED bucket (`0 1 heading_candidates 0 0 -` instead of `0 0 - 0 1 heading_candidates`), which
  is what stops an UNGATED heading request from reading as the gated one (H14d measures both).

  NOT COVERED — resolution this AST matcher cannot perform, by construction:
    * `getattr(zb, "iter_entries")(...)`, or any callee assembled at runtime. A string is not a
      name; no AST matcher closes this, so it is documented rather than chased.
    * a call in ANY OTHER FILE. This scans the one path it is given. `backlog-collect.py` and the
      `~/.zuvo/` helpers each need their own assertion if they grow write paths.
    * a `kinds=` argument that is a NAME rather than the literal tuple (`kinds=CHECKBOX_ONLY`) —
      deliberately counted as UNPINNED, see `is_pinned`; not a blind spot but a choice.
    * WHERE the gate's early return leaves the function. This checks that an `if` mentioning the
      gate, with a `return` in its body, sits ABOVE the call — not that no path reaches the call
      with the gate off. A `while` loop or a second entry point could still do so, which is why
      the behavioural half asserts the default-off output as bytes.
  When the callee resolves through none of the import forms above, this exits non-zero rather than
  reporting "0 calls, all clean": a guard that cannot find its subject must fail, not pass.
"""
import ast
import sys

PARSER_MODULE = "zuvo_backlog_parse"
READERS = ("find", "cmd_index")
GATE_ENV = "ZUVO_BACKLOG_HEADING_ARCHIVE"


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


def kinds_arg(node: ast.Call) -> "ast.expr | None":
    """The `kinds=` keyword's value, or None when the call passes none."""
    for kw in node.keywords:
        if kw.arg == "kinds":
            return kw.value
    return None


def is_pinned(node: ast.Call) -> bool:
    """True iff the call spells `kinds=(zb.KIND_CHECKBOX,)` LITERALLY, here, at this site.

    Not "resolves to checkbox-only": a name bound elsewhere (`kinds=CHECKBOX_ONLY`) would satisfy
    the parser and defeat the whole purpose, which is that the selection is readable AT the write
    path. `checkbox_only=True` therefore does not count either — see the suite's comment.
    """
    v = kinds_arg(node)
    return (isinstance(v, ast.Tuple) and len(v.elts) == 1
            and isinstance(v.elts[0], ast.Attribute) and v.elts[0].attr == "KIND_CHECKBOX")


def mentions(node: ast.AST, names: set) -> bool:
    """Does this subtree read one of `names`, as a Name or as a string literal?"""
    for n in ast.walk(node):
        if isinstance(n, ast.Name) and n.id in names:
            return True
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and n.value in names:
            return True
    return False


def gate_names(tree: ast.AST) -> set:
    """Every module-level name that carries the env gate: the literal itself, the constant bound to
    it, and any function whose body reads either. Read off the source for the same reason the
    parser's alias is — a hardcoded `heading_archive_enabled` would hide a renamed gate."""
    names = {GATE_ENV}
    for node in tree.body:
        if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant) \
                and node.value.value == GATE_ENV:
            names |= {t.id for t in node.targets if isinstance(t, ast.Name)}
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and mentions(node, names):
            names.add(node.name)
    return names


def is_gated(node: ast.Call, fn: "ast.FunctionDef | None", gates: set) -> bool:
    """True iff this call asks for KIND_HEADING and its function returns first when the gate is off."""
    v = kinds_arg(node)
    if not (isinstance(v, ast.Tuple) and any(isinstance(el, ast.Attribute)
                                             and el.attr == "KIND_HEADING" for el in v.elts)):
        return False
    if fn is None:
        return False
    return any(isinstance(n, ast.If) and n.lineno < node.lineno and mentions(n.test, gates)
               and any(isinstance(s, ast.Return) for s in n.body)
               for n in ast.walk(fn))


def scan(node: ast.AST, owner: str, fn: object, out: list, mods: set, funcs: set,
         gates: set) -> None:
    """Attribute each call to its NEAREST enclosing def.

    `ast.walk` per FunctionDef would attribute a call inside a nested def to BOTH defs, and which
    one won would depend on walk order — a guard whose verdict depends on traversal order is not a
    guard. This descends explicitly instead. The def NODE travels beside its name because the
    env-gate check has to look at that one function's body and nothing above it.
    """
    for child in ast.iter_child_nodes(node):
        deeper = isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef))
        nxt, nxt_fn = (child.name, child) if deeper else (owner, fn)
        if is_call(child, mods, funcs):
            out.append((owner, child.lineno, is_pinned(child), is_gated(child, fn, gates)))
        scan(child, nxt, nxt_fn, out, mods, funcs, gates)


src = open(sys.argv[1], encoding="utf-8").read()
tree = ast.parse(src)
p_mods, p_funcs = parser_names(tree)
if not p_mods and not p_funcs:
    sys.stderr.write("pinguard: %s imports %s under no name this scan can follow — every call site "
                     "would read as absent and the counts below would pass vacuously.\n"
                     % (sys.argv[1], PARSER_MODULE))
    sys.exit(2)
calls: list = []
scan(tree, "<module>", None, calls, p_mods, p_funcs, gate_names(tree))
# Order matters: a GATED call is by construction not pinned (it asks for a heading), and a pinned one
# can never be gated (`is_gated` requires KIND_HEADING in the tuple), so the three buckets partition
# the call sites and their three counts always sum to the total.
pinned = [c for c in calls if c[2]]
gated = [c for c in calls if c[3] and not c[2]]
loose = [c for c in calls if not c[2] and not c[3]]
print("%d %d %s %d %d %s" % (len(pinned), len(loose),
                             ",".join(sorted(o for o, _, _, _ in loose)) or "-",
                             src.count("checkbox_only"), len(gated),
                             ",".join(sorted(o for o, _, _, _ in gated)) or "-"))
PYEOF

PIN_GATE_OWNER=heading_candidates
pin_report="$(python3 "$FIX/pinguard.py" "$ARCHIVE_PY")"
set -- $pin_report
if [ "$#" -eq 6 ]; then
  ok "(H14) the pin-guard scan produced all six fields"
  p_pin="$1"; p_loose="$2"; p_owners="$3"; p_alias="$4"; p_gated="$5"; p_gowners="$6"
  echo "  ... pinned=$p_pin unpinned=$p_loose unpinned-in=$p_owners checkbox_only-uses=$p_alias" \
       "env-gated=$p_gated env-gated-in=$p_gowners"
# SEVEN in this file, EIGHT across the family. The aggregate review added the over-cover refusal that
# the two conservation checks structurally cannot make, and it then moved into
# `zuvo_backlog_conserve.py` when this file reached 791 raw lines — nine short of the 800 automatic
# CQ11 FAIL. So the per-file count here is unchanged at 7 while the FAMILY total below is 8, which is
# the whole reason that total is asserted separately: a call site that moves between modules must not
# be able to change the invariant. The guard failing on that call first (as a THIRD unpinned call,
# before it was pinned) is exactly what it is for.
  [ "$p_pin" -eq 7 ] \
    && ok "(H14) exactly 7 iter_entries calls in THIS FILE are pinned kinds=(zb.KIND_CHECKBOX,) at the call site" \
    || no "(H14) $p_pin sites are pinned in backlog-archive.py, not 7 — a write/gate path lost its explicit selection (or one was added)"
  [ "$p_owners" = "cmd_index,find" ] \
    && ok "(H14) the only unpinned calls are find() and cmd_index() — the two READ paths" \
    || no "(H14) unpinned iter_entries calls live in: $p_owners — a path outside find/cmd_index can see a heading entry"
  [ "$p_loose" -eq 2 ] \
    && ok "(H14) there are exactly 2 unpinned calls, so neither reader grew a second one" \
    || no "(H14) $p_loose unpinned calls, not 2"
  [ "$p_alias" -eq 0 ] \
    && ok "(H14) no checkbox_only= alias left in the module — every pin is spelled out" \
    || no "(H14) $p_alias checkbox_only= use(s) remain: a pinned and a defaulted site read alike, and the opt-in stops being a one-line diff"
  # AC4′, first half: backlog-archive.py itself must ask for KIND_HEADING NOWHERE. Task 2 asserted
  # "7 pinned, zero unpinned outside the two readers"; Task 4 adds the archive remedy, so the guard has
  # to state the new shape or it would be satisfied by an UNGATED heading request in a write path —
  # the one outcome the whole split exists to prevent.
  [ "$p_gated" -eq 0 ] && [ "$p_gowners" = "-" ] \
    && ok "(H14/AC4′) backlog-archive.py asks for KIND_HEADING at NO call site of its own — the gated one lives in the policy module" \
    || no "(H14/AC4′) backlog-archive.py has $p_gated env-gated call(s) in $p_gowners — the heading request must sit in zuvo_backlog_heading.py, behind the gate the guard can read, or the seven pins stop being the whole story of this file"
else
  no "(H14) the pin-guard scan produced $# field(s), not 6 — it crashed, and every count below it would read as empty and PASS"
fi

# AC4′, second half: the POLICY module carries exactly one call, it is env-gated, and it is the only
# one in the family that may ask for a heading. "Exactly one", not "at least one" — a second gated site
# is a second place the fleet-wide default can be changed from, and moving that number must be a
# deliberate edit. H19c re-runs the same scan over the derived family, so a third module cannot quietly
# grow one either.
pol_report="$(python3 "$FIX/pinguard.py" "$HEADPOL_MOD")"
echo "  ... policy module: $pol_report"
[ "$pol_report" = "0 0 - 0 1 $PIN_GATE_OWNER" ] \
  && ok "(H14/AC4′) zuvo_backlog_heading.py: exactly ONE iter_entries call, env-gated behind $HEAD_ARCH_ENV, in $PIN_GATE_OWNER() — and no unpinned or aliased one beside it" \
  || no "(H14/AC4′) zuvo_backlog_heading.py reported '$pol_report', expected '0 0 - 0 1 $PIN_GATE_OWNER' — either the gate is not recognisable as one (an ungated heading request), or a second call joined it"

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
r"""Write a named mutation of backlog-archive.py + the parser it imports into their own directory.

RAW docstring, and not a preference: the mutation table below quotes regexes, and under Python 3.12+ a
`\s` in a non-raw string is a SyntaxWarning on STDERR — which every caller here reads as "the mutant
did not build", because that is exactly how a build failure looks.

Usage: mkmut.py <archive.py> <parser.py> <block.py> <heading.py> <mint.py> <io.py> <kind> <outdir>

    none        byte-identical copies — the control, so a mutant that fails proves the MUTATION
                failed and not the copy mechanics (the parser, the boundary module, the heading
                policy, the mint and the io layer must ALL sit beside the archiver: it puts its own
                directory on sys.path and imports every one of them by name)
    dup         LOOKUP_KINDS lists KIND_HEADING twice — the duplicate the derived form could mint
    drift       the PARSER's DEFAULT_KINDS gains a NEW dialect; the archiver is untouched
    headdefault the PARSER's DEFAULT_KINDS gains KIND_HEADING; the archiver is untouched
    derived     headdefault PLUS the archiver's old `zb.DEFAULT_KINDS + (zb.KIND_HEADING,)`
    alias       the parser is imported `as zb2` and every `zb.` renamed (pinguard subject)
    runtime     the import is assembled at runtime: `zb = __import__(...)` (pinguard subject)

  Task 4's archive remedy — the gate, the mint and the hold, each reverted ON ITS OWN:
    ungated     the gate's early return is deleted: the heading request stays, the gate does not
    fakegate    the gate's test no longer mentions the env var, so an `if`+`return` alone must not
                satisfy the guard
    secondgate  a SECOND env-gated call, so "exactly one" is shown to be load-bearing
    unconditional  KIND_HEADING added to classify()'s PINNED checkbox call — the shape the pin count
                catches and the gated-site count does not
    nohold      the open-child hold is switched off: a resolved parent archives over live follow-ups
    mintcb      the mint anchor goes back to checkbox-only — D2's no-op on a heading line
    mintprefix  minted ids become `B-G…`, which `MINTED_ID_RE` does not strip, so `keys_for` stops
                bridging the pre-mint content key

  And the adversarial round's, each reverting ONE fix (the file each applies to is part of the
  mutation: three of them are in the heading policy, two in the mint, two in the archiver):
    mintvspace  the anchor's `\s*` is restored: the id lands on a NEW line (file corruption)
    mintmiss    the anchor never matches, which is the only way to reach the mint's refusal branch
    boxnarrow   the open box must be exactly one whitespace char again: `- [  ]` stops counting
    boxhead     the open box is only looked for at the child's HEAD, not in its tail
    nofencechild  open_children stops stepping over fences, so a code sample holds the heading
    nostayheads   the plan reports no staying heading keys, so an open heading id is unprotected
    nototalheads  the plan reports 0 heading entries, so cmd_status's still_open under-counts
    orderswap   `'[ ]' in body` is tested before the `inside` filter again (the false "held")
    noinside    the inside exclusion is deleted: a ticked child is counted twice

  And Task 5's io split — the two-layout import and the three documented fail-opens, each reverted
  ON ITS OWN (H24 reads these):
    iodash      the io module is written HYPHENATED (`zuvo-backlog-io.py`), which is exactly what the
                underscore in every sibling's name is load-bearing against: the archiver's
                `import zuvo_backlog_io` then resolves to nothing
    ioreporoot  io stops relying on being a flat sibling and points sys.path at the REPO layout
                instead, which resolves in the checkout and NOT on the flattened ~/.zuvo/ one — the
                asymmetric failure a single-layout assertion cannot see
    ignoretight `is_ignored()` stops returning None outside a git repo and exits instead
    readtight   `read()` re-raises FileNotFoundError instead of returning ""
    nofallback  `cmd_verify` catches OSError instead of SystemExit, so a held lock takes the GATE
                down — the exit `append-runlog` reads as BACKLOG_NAMESPACE_VIOLATION

Every substitution is counted and a miss is a hard error: a mutation that silently failed to apply
would make the assertion reading it pass for the wrong reason, which is the defect class this whole
block exists to rule out.
"""
import glob
import os
import re
import sys

EXPLICIT = ("LOOKUP_KINDS: Tuple[str, ...] = "
            "(zb.KIND_CHECKBOX, zb.KIND_BULLET, zb.KIND_TABLE, zb.KIND_HEADING)")
DERIVED = "LOOKUP_KINDS: Tuple[str, ...] = zb.DEFAULT_KINDS + (zb.KIND_HEADING,)"
IMPORT = "import zuvo_backlog_parse as zb"
DEFAULTS = "DEFAULT_KINDS = (KIND_CHECKBOX, KIND_BULLET, KIND_TABLE)"
# Task 4's four subjects, quoted from the module so a rename there is a hard error here rather than a
# mutation that silently does not apply (`sub` counts every substitution).
GATE_IF = "    if not heading_archive_enabled():"
GATE_RET = GATE_IF + "\n        return HeadingPlan(moving, held, spans, 0, frozenset())\n"
GATED_CALL = "    ents = list(zb.iter_entries(text, kinds=(zb.KIND_HEADING,)))"
CLS_CALL = "    for e in zb.iter_entries(text, kinds=(zb.KIND_CHECKBOX,)):"
HOLD_IF = "        if n_open or inner:"
MINT_ANCHOR = ('_MINT_ANCHOR_RE = re.compile('
               'r"^([ \\t]*[-*][ \\t]*\\[[ xX]\\][ \\t]*|#{1,6}[ \\t]+)")')
# the pre-fix anchor, VERBATIM: `\s*` matches a newline, which is the corruption F1 pins
MINT_VSPACE = '_MINT_ANCHOR_RE = re.compile(r"^(\\s*[-*]\\s*\\[[ xX]\\]\\s*|#{1,6}[ \\t]+)")'
MINT_CB_ONLY = '_MINT_ANCHOR_RE = re.compile(r"^([ \\t]*[-*][ \\t]*\\[[ xX]\\][ \\t]*)")'
MINT_NEVER = '_MINT_ANCHOR_RE = re.compile(r"^(?!x)x")'
MINT_PREFIX = '    return "B-A" + time.strftime'
BOX_RE = '_OPEN_BOX_RE = re.compile(r"\\[[ \\t]*\\]")'
BOX_NARROW = '_OPEN_BOX_RE = re.compile(r"\\[\\s\\]")'
CHILD_OPEN = "    return bool(_CHILD_RE.match(line) and _OPEN_BOX_RE.search(line))"
CHILD_HEAD = ("    return bool(_CHILD_RE.match(line) and "
              "_OPEN_BOX_RE.match(line.lstrip(' \\t-*')))")
FENCE_STEP = "        close = fences.get(i)"
STAYING = ("    staying = frozenset(e.key for e in ents\n"
           "                        if not any(s <= e.lineno <= en for s, en in "
           "moving_spans))")
HEAD_TOTAL = "total=len(ents)"
INSIDE_SKIP = "        if e.lineno in inside:\n            continue\n"
ORDERED = ("        if e.lineno in inside:\n            continue\n"
           "        if \"[ ]\" in e.body:\n            nested.append(e.ident or e.key)\n"
           "            continue\n")
SWAPPED = ("        if \"[ ]\" in e.body:\n            nested.append(e.ident or e.key)\n"
           "            continue\n        if e.lineno in inside:\n            continue\n")


def sub(src, old, new, what):
    if src.count(old) != 1:
        sys.exit("mkmut: %s occurs %dx, expected once — the mutation would not apply: %r"
                 % (what, src.count(old), old))
    return src.replace(old, new)


# Task 5's io subjects, quoted from zuvo_backlog_io.py so a rename there is a hard error here rather
# than a mutation that silently does not apply.
IO_IMPORT = "import zuvo_backlog_parse as zb"
# The parser reachable ONLY through the repo tree: the module's own directory (and the cwd entry a
# `-c` run adds) are dropped, and `../../scripts/zuvo-home` put in their place. That path resolves back
# to itself inside a scripts/zuvo-home/ checkout and to nothing at all on the flattened ~/.zuvo/ one.
# The stdlib entries are LEFT ALONE on purpose: wiping sys.path wholesale fails on `import hashlib`,
# which is a broken mutant rather than the asymmetry under test.
IO_REPOROOT = ('_HERE = os.path.dirname(os.path.realpath(__file__))\n'
               'sys.path[:] = [p for p in sys.path if p not in ("", ".", _HERE)]\n'
               'sys.path.insert(0, os.path.join(_HERE, "..", "..", "scripts", "zuvo-home"))\n'
               "import zuvo_backlog_parse as zb")
IGN_NONE = "    if sh([\"git\", \"rev-parse\", \"--is-inside-work-tree\"], cwd=d) != \"true\":\n" \
           "        return None"
IGN_EXIT = "    if sh([\"git\", \"rev-parse\", \"--is-inside-work-tree\"], cwd=d) != \"true\":\n" \
           "        sys.exit(\"not inside a git work tree: %s\" % path)"
READ_OPEN = "    except FileNotFoundError:\n        return \"\""
READ_RAISE = "    except FileNotFoundError:\n        raise"
VERIFY_FALLBACK = "    except SystemExit:"
VERIFY_NARROW = "    except OSError:"

arch_path, parser_path, block_path, head_path, mint_path, io_path, kind, outdir = sys.argv[1:9]
arch = open(arch_path, encoding="utf-8").read()
parser = open(parser_path, encoding="utf-8").read()
block = open(block_path, encoding="utf-8").read()
head = open(head_path, encoding="utf-8").read()
mint = open(mint_path, encoding="utf-8").read()
io_src = open(io_path, encoding="utf-8").read()
io_name = os.path.basename(io_path)

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
elif kind == "ungated":
    head = sub(head, GATE_RET, "", "the env gate's early return")
elif kind == "fakegate":
    head = sub(head, GATE_IF, "    if not lines:", "the env gate's test")
elif kind == "secondgate":
    head = sub(head, GATED_CALL, GATED_CALL + " \\\n        + list(zb.iter_entries(text, "
               "kinds=(zb.KIND_HEADING,)))", "the gated iter_entries call")
elif kind == "unconditional":
    arch = sub(arch, CLS_CALL, CLS_CALL.replace("(zb.KIND_CHECKBOX,)",
                                                "(zb.KIND_CHECKBOX, zb.KIND_HEADING)"),
               "classify()'s pinned checkbox call")
elif kind == "nohold":
    head = sub(head, HOLD_IF, "        if False:", "the open-child hold")
elif kind == "mintcb":
    mint = sub(mint, MINT_ANCHOR, MINT_CB_ONLY, "the mint anchor")
elif kind == "mintprefix":
    mint = sub(mint, MINT_PREFIX, '    return "B-G" + time.strftime', "the minted-id prefix")
elif kind == "mintvspace":
    mint = sub(mint, MINT_ANCHOR, MINT_VSPACE, "the mint anchor's whitespace classes")
elif kind == "mintmiss":
    mint = sub(mint, MINT_ANCHOR, MINT_NEVER, "the mint anchor")
elif kind == "boxnarrow":
    head = sub(head, BOX_RE, BOX_NARROW, "the open-box class")
elif kind == "boxhead":
    head = sub(head, CHILD_OPEN, CHILD_HEAD, "the open-box search over the child line")
elif kind == "nofencechild":
    head = sub(head, FENCE_STEP, "        close = None", "the fence step in open_children")
elif kind == "nostayheads":
    head = sub(head, STAYING, "    staying = frozenset()", "the staying-heading keys")
elif kind == "nototalheads":
    head = sub(head, HEAD_TOTAL, "total=0", "the heading total")
elif kind == "orderswap":
    arch = sub(arch, ORDERED, SWAPPED, "the inside/[ ] order in classify")
elif kind == "noinside":
    arch = sub(arch, INSIDE_SKIP, "", "the inside exclusion in classify")
elif kind == "iodash":
    io_name = "zuvo-backlog-io.py"          # the archiver's import cannot resolve a hyphen
elif kind == "ioreporoot":
    io_src = sub(io_src, IO_IMPORT, IO_REPOROOT, "the io module's parser import")
elif kind == "ignoretight":
    io_src = sub(io_src, IGN_NONE, IGN_EXIT, "is_ignored's outside-a-repo fail-open")
elif kind == "readtight":
    io_src = sub(io_src, READ_OPEN, READ_RAISE, "read's missing-file fail-open")
elif kind == "nofallback":
    arch = sub(arch, VERIFY_FALLBACK, VERIFY_NARROW, "cmd_verify's unlocked fallback")
elif kind != "none":
    sys.exit("mkmut: unknown mutation %r" % kind)

os.makedirs(outdir, exist_ok=True)
with open(os.path.join(outdir, "backlog-archive.py"), "w", encoding="utf-8") as fh:
    fh.write(arch)
# `io_name` rather than basename(io_path): the `iodash` mutation IS the filename, so the io module is
# the one file whose destination name the mutation may change.
written = set()
for name, text in ((os.path.basename(parser_path), parser), (os.path.basename(block_path), block),
                   (os.path.basename(head_path), head), (os.path.basename(mint_path), mint),
                   (io_name, io_src)):
    with open(os.path.join(outdir, name), "w", encoding="utf-8") as fh:
        fh.write(text)
    written.add(name)
# The io module's ORIGINAL basename is reserved too, even when the mutation renamed it: `iodash`
# IS a rename, so without this the sweep below helpfully restores the real `zuvo_backlog_io.py`
# beside the hyphenated one and the mutant imports fine — the mutation silently undone by the
# convenience meant to protect it. Measured: iodash reported LOADED instead of ModuleNotFoundError.
written.add(os.path.basename(io_path))
# EVERY OTHER SIBLING BY GLOB, so a new one joins the mutant dirs by existing rather than by being
# listed here. This list was manual and it cost the identical failure twice — Task 5's io module, then
# zuvo_backlog_conserve.py — each landing with the factories still naming five files, after which every
# mutant died with ModuleNotFoundError: an import error wearing a mutation's clothes, inside the
# assertions that exist to prove the mutation fires. The mutated modules above stay explicit, because a
# mutation has to name its target; the rest are copied verbatim.
for extra in sorted(glob.glob(os.path.join(os.path.dirname(os.path.realpath(parser_path)),
                                           "zuvo_backlog_*.py"))):
    if os.path.basename(extra) in written:
        continue
    with open(extra, encoding="utf-8") as fh:
        extra_text = fh.read()
    with open(os.path.join(outdir, os.path.basename(extra)), "w", encoding="utf-8") as fh:
        fh.write(extra_text)
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

mkmut(){ python3 "$MKMUT" "$ARCHIVE_PY" "$MODULE" "$BLOCK_MOD" "$HEADPOL_MOD" "$MINT_MOD" \
                 "$IO_MOD" "$1" "$FIX/mut-$1"; }
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
# THE FACTORY'S EXIT CODE IS CHECKED, and this is the one assertion in the file where omitting that
# check was not harmless. Found by the aggregate review's CQ audit and reproduced: if `sub()` hard-errors
# (the anchored string no longer occurs exactly once), `mkmut` exits BEFORE `os.makedirs(outdir)`, so
# `$FIX/mut-runtime/` never exists — and `pinguard.py` on a missing path exits 1 with empty stdout,
# which is byte-for-byte what `[ "$r_rc" -ne 0 ] && [ -z "$r_report" ]` was accepting as success. The
# assertion that exists to prove an unresolvable callee FAILS LOUDLY was itself passing on a mutant that
# was never built. Every other mkmut site demands a POSITIVE observation and so cannot be fooled this
# way; this one asked only for absence.
#
# Three changes, each closing one step of that path: the factory's exit code is a hard failure, the
# mutant directory must exist before the guard is pointed at it, and stderr is CAPTURED and required to
# name the unresolvable callee — so "exited non-zero saying nothing" can no longer stand in for
# "diagnosed the blind spot".
if ! mkmut runtime >/dev/null 2>&1; then
  no "(H14b) mkmut could not build the 'runtime' mutant — its substitution no longer applies, so the assertion below would pass on a mutant that does not exist"
elif [ ! -f "$FIX/mut-runtime/backlog-archive.py" ]; then
  no "(H14b) mkmut reported success but $FIX/mut-runtime/backlog-archive.py is absent — pinguard.py would 'fail' for the wrong reason"
else
  r_report="$(python3 "$FIX/pinguard.py" "$FIX/mut-runtime/backlog-archive.py" 2>"$FIX/runtime.err")"
  r_rc=$?
  r_err="$(head -1 "$FIX/runtime.err" 2>/dev/null)"
  if [ "$r_rc" -ne 0 ] && [ -z "$r_report" ] && case "$r_err" in *"under no name this scan can follow"*) true ;; *) false ;; esac; then
    ok "(H14b) a runtime-assembled import makes the pin guard EXIT $r_rc with nothing on stdout AND a stderr line naming the unresolvable callee — the documented blind spot fails loudly, diagnosed rather than merely non-zero"
  else
    no "(H14b) with the import assembled at runtime the pin guard exited $r_rc, stdout '$r_report', stderr '$r_err' — an unresolvable callee must fail loudly AND say why"
  fi
fi

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

pybg(){ ( export ZUVO_BACKLOG_HEADING_ARCHIVE=1; pyb "$1" ); }

# CONTROL: `load()` must EXECUTE the module, top-level imports included. Every H24b mutant depends on
# this and NONE of them states it — `iodash` for instance asserts that a hyphenated io module makes the
# archiver's `import zuvo_backlog_io` raise ModuleNotFoundError, which can only happen if imports run.
# An adversarial provider filed that dependency as a CRITICAL ("if load() only parsed the AST, all of
# H24b would be meaningless"). It does execute — `spec.loader.exec_module()` above — but a reader has
# to know that, so the property is now ASSERTED against a module whose only content is an import that
# cannot resolve. If loading ever becomes lazy or AST-only, this goes red first, next to the mutants it
# would otherwise silently hollow out.
printf 'import definitely_no_such_module_e45f92\n' > "$FIX/exec-control.py"
ctl_out="$(pyb "
try:
    load('$FIX/exec-control.py')
    print('NO-RAISE')
except ModuleNotFoundError as e:
    print('RAISED %s' % e.name)
except Exception as e:
    print('OTHER %s' % type(e).__name__)" 2>&1)"
[ "$ctl_out" = "RAISED definitely_no_such_module_e45f92" ] \
  && ok "(H15) CONTROL: load() executes top-level imports — a module whose only line is an unresolvable import raises ModuleNotFoundError, so every H24b import mutant below can actually fire" \
  || no "(H15) CONTROL: load() answered '$ctl_out', expected 'RAISED definitely_no_such_module_e45f92' — if top-level imports are not executed, every H24b mutant passes vacuously"

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
marked, unmarked, nested, plan = BA.classify(t)
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

# --- H18 the BLOCK BOUNDARY of a heading entry: level, sibling, fence, trim ----------------------
# The defect: `entry_block` terminated at the next flush-left BULLET, and a heading entry's own
# continuation is written as flush-left `- **Closed:** …` bullets. Measured on this repo's backlog
# before the fix: SIX id-shaped headings (107, 119, 141, 161, 185, 220) reported a ONE-LINE block
# while the next line was plainly their content, and 432 of tgm-survey-platform's 487 did. Moving a
# 1-line "block" would leave the entry split across two files, and the per-entry conservation check
# passes throughout, because every line still exists SOMEWHERE.
#
# The trap this group exists for, and the reason the assertion is ATTRIBUTION and not occurrence: a
# LEVEL-ONLY terminator ("the next heading of level <= mine") sweeps the four independent `- [ ]`
# entries that follow the anchor into its block — the next `##` is 8 lines further down — and every
# line still lands exactly once. The defect is mis-attribution, so what is asserted is that each
# line belongs to the entry the DOCUMENT puts it in.
#
# THE FIXTURE IS GENERATED FROM THE REAL FILE, never hand-written: a hand-written fixture indents its
# children, which is exactly the shape that already passed while the real one failed. `mkspan.py`
# extracts the anchor entry's real slice and hard-errors rather than degrade, so a fixture that lost
# its shape cannot make the assertions below pass vacuously.
MKSPAN="$FIX/mkspan.py"
cat > "$MKSPAN" <<'PYEOF'
"""Generate the span fixture FROM the real backlog, with byte-exact, INDEPENDENT expectations.

Usage: mkspan.py <real-backlog> <anchor-id> <parser-dir> <outdir>

The anchor's expected block is extracted by a rule that is deliberately NOT the implementation's:
"from the heading, stop at the first flush-left checkbox, then drop trailing blanks". It knows
nothing about heading levels, fences or `_heading_parts`, so an agreement between it and
`entry_block` is a measurement and not a restatement. The fence / nested-heading / trailing-blank
cases the real slice cannot exercise are APPENDED after it, so they cannot move the anchor boundary.

Every precondition is a hard error, never a degrade: the whole H18 group is of the form "the block
covers X and stops before Y", and all of it passes trivially on a fixture where X and Y are absent.
"""
import os
import re
import sys

CHECK = re.compile(r"^[-*]\s*\[[ xX]\]")
L2 = re.compile(r"^#{1,2}\s")

real, anchor, parser_dir, outdir = sys.argv[1:5]
sys.path.insert(0, parser_dir)
import zuvo_backlog_parse as zb  # noqa: E402

text = open(real, encoding="utf-8").read()
lines = text.splitlines(keepends=True)
hits = [e for e in zb.iter_entries(text, kinds=(zb.KIND_HEADING,)) if e.ident == anchor]
if len(hits) != 1:
    sys.exit("mkspan: %r matches %d heading entries in %s, expected exactly 1 — the fixture would "
             "not carry the measured shape" % (anchor, len(hits), real))
start = hits[0].lineno - 1

nxt = next((i for i in range(start + 1, len(lines)) if L2.match(lines[i])), -1)
if nxt < 0:
    sys.exit("mkspan: no following '##' heading after %s:%d — the slice would run to EOF and the "
             "'siblings stay outside' case would not be bounded" % (real, start + 1))
sliced = lines[start:nxt]

term = next((i for i, ln in enumerate(sliced) if CHECK.match(ln)), -1)
if term < 0:
    sys.exit("mkspan: no flush-left checkbox in %s:%d-%d — the sibling terminator this task is "
             "about is not present in the slice" % (real, start + 1, nxt))
head = sliced[:term]
while head and not head[-1].strip():
    head.pop()
sibs = [i for i, ln in enumerate(sliced) if CHECK.match(ln)]
if len(head) < 5:
    sys.exit("mkspan: the anchor's independently-extracted block is %d line(s) — too short to tell a "
             "level-aware boundary from a bullet-terminated one" % len(head))
if len(sibs) < 2:
    sys.exit("mkspan: only %d flush-left checkbox(es) after the anchor — one sibling cannot show the "
             "difference between 'outside the span' and 'swept in'" % len(sibs))
if not any(ln.startswith("- **") for ln in head[1:]):
    sys.exit("mkspan: the anchor's block carries no flush-left '- **' continuation bullet — the very "
             "shape the old rule truncated on is missing")

# The three FENCE cases, and why each is shaped the way it is. They are APPENDED after the real slice
# and after B-FENCED, so they cannot move the anchor's boundary or B-FENCED's.
#   TILDE     a `~~~` line inside a ``` fence. The heading between them must stay INSIDE the block: a
#             detector that toggles on either marker closes the fence at the `~~~` and the heading cuts it.
#   INDENTF   a PAIR of 4-space-indented ``` lines around a flush-left checkbox. The pair matters: with
#             a single marker the unclosed-fence rule would give the same answer either way, so only a
#             closed pair isolates the indentation tier from the unclosed case.
#   UNCLOSED  a stray ``` with NO matching marker anywhere after it, which is why this group sits LAST
#             in the fixture. A later ``` would genuinely close it — that is what a markdown renderer
#             does — and the case under test is the one the coordinator measured: nothing closes it, and
#             the inherited detector then disabled every structural terminator to EOF (span 7 of 7,
#             swallowing both the `## B-LATER` heading and the `- [ ] B-STRAY-SIB` entry after it).
NEXT = ["## B-NEXT — DONE deadbee\n",
        "- **Closed:** synthetic: byte-compared, so a boundary change shows up as a diff here.\n",
        "- **Note:** two flush-left bullets, so a bullet terminator truncates this to one line.\n"]
FENCED = ["## B-FENCED — DONE deadbee\n",
          "- **Closed:** synthetic: the fence, the nested sub-entry and the trailing blanks all\n",
          "  belong to this entry.\n",
          "```\n",
          "# a flush-left hash INSIDE a fence is a comment, not structure\n",
          "systemctl restart workers\n",
          "```\n",
          "### B-FENCED-SUB a deeper heading stays INSIDE its parent\n",
          "- **Detail:** a flush-left bullet under the sub-entry.\n",
          "  - [ ] an INDENTED checkbox child of the sub-entry\n"]
SUB_AT = 7                                   # index of '### B-FENCED-SUB' within FENCED
TILDE = ["## B-TILDE — DONE deadbee\n",
         "- **Closed:** synthetic: a ~~~ line must not close a ``` fence.\n",
         "```\n",
         "~~~\n",
         "## INSIDE-A-FENCE is a code sample, not a heading (and carries no id on purpose)\n",
         "```\n",
         "- **After:** the bullet after the fence still belongs to B-TILDE.\n"]
INDENTF = ["## B-INDENTFENCE — DONE deadbee\n",
           "- **Closed:** synthetic: a 4-space-indented ``` is an indented code line, not a fence.\n",
           "    ```\n"]
INDENTSIB = ["- [ ] B-INDENT-SIB the checkbox a bogus fence would have hidden\n",
             "    ```\n"]
UNCLOSED = ["## B-UNCLOSED — DONE deadbee\n",
            "- **Closed:** synthetic: an unclosed fence must not swallow what follows it.\n",
            "```\n",
            "an unclosed fence starts here, and nothing after it closes it\n"]
LATER = ["## B-LATER — DONE deadbee\n"]
STRAY = ["- [ ] B-STRAY-SIB a sibling entry that must stay outside B-UNCLOSED\n"]

body = (sliced + ["\n"] + NEXT + ["\n", "\n"] + FENCED + ["\n", "\n"]
        + TILDE + ["\n", "\n"] + INDENTF + INDENTSIB + ["\n", "\n"]
        + UNCLOSED + LATER + STRAY + ["\n", "\n", "\n"])
os.makedirs(os.path.join(outdir, "memory"), exist_ok=True)
os.makedirs(os.path.join(outdir, "expected"), exist_ok=True)
with open(os.path.join(outdir, "memory", "backlog.md"), "w", encoding="utf-8") as fh:
    fh.write("".join(body))
for name, block in (("head", head), ("next", NEXT), ("fenced", FENCED), ("sub", FENCED[SUB_AT:]),
                    ("tilde", TILDE), ("indentf", INDENTF), ("unclosed", UNCLOSED)):
    with open(os.path.join(outdir, "expected", name + ".txt"), "w", encoding="utf-8") as fh:
        fh.write("".join(block))
# SIBS_FIX counts the flush-left checkboxes in the WHOLE fixture, not just the real slice: the fence
# cases add two, and an assertion pinned to the slice's four would read as a failure the day a case is
# added rather than as the measurement it is.
fix_sibs = sum(1 for ln in body if CHECK.match(ln))
print("HEAD_LEN %d SIBS %d NEXT_LEN %d FENCED_LEN %d SUB_LEN %d REAL_START %d REAL_END %d SIBS_FIX %d"
      % (len(head), len(sibs), len(NEXT), len(FENCED), len(FENCED) - SUB_AT,
         start + 1, start + len(head), fix_sibs))
PYEOF

# The PROBE: one script, used for the real module and for every mutant, so a mutant's number and the
# control's number are produced by identical code.
SPANPROBE="$FIX/spanprobe.py"
cat > "$SPANPROBE" <<'PYEOF'
"""Measure `entry_block` spans of a (possibly mutated) backlog-archive.py. Prints ONE line.

Usage: spanprobe.py <archive.py> <mode> <backlog.md> [anchor-id]

    head <id>   HEAD <start> <end> <len>                        the anchor entry's block
    text <id>   the block's BYTES, verbatim (for a byte-exact compare)
    attrib      ATTRIB owned=<n> orphan_nonblank=<n> cross=<n> selfown=<n> sibs=<n> inspan=<n>
    dist        DIST <len:count,...> TRUNC <n> <ids>

`attrib` is the conservation check: OWNER(line) is the entry with the greatest `lineno` whose span
contains it — the innermost, i.e. its own nesting level. `cross` counts entry pairs whose spans
PARTIALLY overlap (neither disjoint nor nested), which is a boundary that cut through another
entry's body. `inspan` counts flush-left checkbox lines that fell INSIDE the anchor's span: the
level-only trap, and the one number that distinguishes mis-attribution from loss.
`dist` TRUNC counts id-shaped headings whose block is ONE line while the next non-blank line is
continuation content — content, i.e. not itself a terminator (a heading of level <= the start's, or
a flush-left checkbox). Derived, so it needs no count frozen from the file.
"""
import importlib.util
import os
import re
import sys
from importlib.machinery import SourceFileLoader

CHECK = re.compile(r"^[-*]\s*\[[ xX]\]")

apath, mode, backlog = sys.argv[1], sys.argv[2], sys.argv[3]
anchor = sys.argv[4] if len(sys.argv) > 4 else ""
here = os.path.dirname(os.path.realpath(apath))
sys.path.insert(0, here)
spec = importlib.util.spec_from_file_location("ba_span", apath,
                                              loader=SourceFileLoader("ba_span", apath))
BA = importlib.util.module_from_spec(spec)
sys.modules["ba_span"] = BA
spec.loader.exec_module(BA)
zb = getattr(BA, "zb")

text = open(backlog, encoding="utf-8").read()
lines = text.splitlines(keepends=True)
ents = list(zb.iter_entries(text, kinds=BA.LOOKUP_KINDS))


def span(e):
    """(first, last) 1-based inclusive — `entry_block` returns one PAST the end, 0-based."""
    return e.lineno, BA.entry_block(lines, e.lineno - 1)


def anchor_entry():
    hits = [e for e in ents if e.ident == anchor]
    if len(hits) != 1:
        sys.exit("spanprobe: %r matches %d entries" % (anchor, len(hits)))
    return hits[0]


if mode in ("head", "text"):
    a = anchor_entry()
    s, en = span(a)
    if mode == "text":
        sys.stdout.write("".join(lines[s - 1:en]))
    else:
        print("HEAD %d %d %d" % (s, en, en - s + 1))
elif mode == "attrib":
    spans = [(e.lineno, span(e)[1], e) for e in ents]
    cross = 0
    for i in range(len(spans)):
        for j in range(i + 1, len(spans)):
            a1, b1, _ = spans[i]
            a2, b2, _ = spans[j]
            if a2 > b1 or a1 > b2:
                continue                                   # disjoint
            if not ((a1 <= a2 and b2 <= b1) or (a2 <= a1 and b1 <= b2)):
                cross += 1
    a = anchor_entry()
    a_s, a_e = span(a)
    owned = orphan = 0
    for n in range(1, len(lines) + 1):
        holders = [s for s in spans if s[0] <= n <= s[1]]
        if holders:
            owned += 1
        elif lines[n - 1].strip():
            orphan += 1
    sib_lines = [i + 1 for i, ln in enumerate(lines) if CHECK.match(ln)]
    inspan = sum(1 for n in sib_lines if a_s <= n <= a_e)
    selfown = 0
    for n in sib_lines:
        if a_s <= n <= a_e:
            continue
        holders = [s for s in spans if s[0] <= n <= s[1]]
        if holders and max(holders, key=lambda s: s[0])[2].lineno == n:
            selfown += 1
    print("ATTRIB owned=%d orphan_nonblank=%d cross=%d selfown=%d sibs=%d inspan=%d"
          % (owned, orphan, cross, selfown, len(sib_lines), inspan))
elif mode == "dist":
    dist, trunc = {}, []
    for e in ents:
        if e.kind != zb.KIND_HEADING:
            continue
        s, en = span(e)
        n = en - s + 1
        dist[n] = dist.get(n, 0) + 1
        if n != 1:
            continue
        nxt = next((ln for ln in lines[s:] if ln.strip()), "")
        parts = zb._heading_parts(nxt.rstrip("\r\n"))
        own = zb._heading_parts(lines[s - 1].rstrip("\r\n"))
        terminator = (parts is not None and own is not None and parts[0] <= own[0]) \
            or bool(CHECK.match(nxt))
        if nxt and not terminator:
            trunc.append(e.ident)
    print("DIST %s TRUNC %d %s"
          % (",".join("%d:%d" % kv for kv in sorted(dist.items())), len(trunc),
             ",".join(trunc[:8]) or "-"))
else:
    sys.exit("spanprobe: unknown mode %r" % mode)
PYEOF

# THE MUTANT FACTORY for the boundary rule. Same contract as H14b's: every substitution is counted
# and a miss is a HARD ERROR, because a mutation that silently failed to apply would make the
# assertion reading it pass for the wrong reason.
MKBLOCK="$FIX/mkblock.py"
cat > "$MKBLOCK" <<'PYEOF'
"""Write a named mutation of the BOUNDARY RULE into its own directory.

Usage: mkblock.py <archive.py> <parser.py> <block.py> <heading.py> <mint.py> <io.py> <kind> <outdir>

The SUBJECT is zuvo_backlog_block.py, not the archiver: `entry_block` and its two helpers moved there
when backlog-archive.py crossed the automatic CQ11 FAIL at 800 raw lines. All six files are written
out — the archiver imports all four siblings from its own directory, so a mutant dir missing one
would fail to IMPORT and the assertion reading it would blame the mutation for a packaging error.

    none        byte-identical copies — the control (the parser, the boundary module, the heading
                policy, the mint and the io layer must all sit beside the archiver, which puts its
                own dir on sys.path)
    legacy      the heading path is switched OFF: every start entry takes the pre-Task-3 branch,
                which is the exact behaviour that truncated six entries to one line
    levelonly   the sibling terminator is removed — "next heading of level <= mine" ONLY: the
                boundary trap, which a line-level conservation check cannot see
    anylevel    any heading terminates, level ignored: a nested '### B-x-SUB' ends its parent
    nofence     the fence guard never matches: a flush-left '#' inside a code sample terminates
    notrim      trailing blank lines are not trimmed back
    indentterm  an INDENTED checkbox terminates too: a parent block then ends inside its own
                sub-entry's body, which is a CROSSING span rather than a nested one
"""
import glob
import os
import sys

LEVEL = "    level = _heading_start_level(lines[start])"
SIB = "    return bool(zb.CHECK_LINE_RE.match(ln))"
LVLCMP = "    if lvl is not None and lvl <= level:"
FENCE = '_FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})")'
FCLOSE = "    return spans"
FMATCH = "        elif marker == open_marker:"
TRIM = "    while i - 1 > start and not lines[i - 1].strip():"
SPAN = "        e = with_span(lines, e)"

# (target, old, new, what) — `target` is which FILE the substitution applies to. The boundary rule
# lives in the block module; the end_lineno ROUTING lives in the archiver, and a mutant that reverts
# one must not be able to silently apply to the other.
MUT = {
    "legacy": ("block", LEVEL, "    level = None", "the heading-level lookup in entry_block"),
    "levelonly": ("block", SIB, "    return False", "the sibling-checkbox terminator"),
    "anylevel": ("block", LVLCMP, "    if lvl is not None:", "the level comparison"),
    "nofence": ("block", FENCE, '_FENCE_RE = re.compile(r"^(?!x)x")', "the fence regex"),
    "notrim": ("block", TRIM, "    while False:", "the trailing-blank trim"),
    "indentterm": ("block", SIB, '    return bool(re.match(r"^\\s*[-*]\\s*\\[[ xX]\\]", ln))',
                   "the sibling-checkbox terminator"),
    # the three PRE-EXISTING fence flaws, each reverted on its own
    # RE-POINTED at closed_fence_spans (the aggregate review replaced the per-opener _fence_close scan
    # with one left-to-right pass over the document, and these two anchored on the code it deleted —
    # mkblock hard-errored and said so, which is the factory contract working).
    "fenceeof": ("block", FCLOSE,
                 "    if open_at is not None:\n        spans[open_at] = len(lines) - 1\n"
                 "    return spans", "the unclosed-fence recovery"),
    "fenceany": ("block", FMATCH, "        elif True:", "the fence-character match"),
    "fenceindent": ("block", FENCE, '_FENCE_RE = re.compile(r"^\\s*(`{3,}|~{3,})")',
                    "the fence indentation bound"),
    # and the end_lineno routing: classify() hands its entries on WITHOUT a measured span
    "nospan": ("arch", SPAN, "        e = e", "with_span in classify()"),
}

arch_path, parser_path, block_path, head_path, mint_path, io_path, kind, outdir = sys.argv[1:9]
arch = open(arch_path, encoding="utf-8").read()
parser = open(parser_path, encoding="utf-8").read()
block = open(block_path, encoding="utf-8").read()
head = open(head_path, encoding="utf-8").read()
mint = open(mint_path, encoding="utf-8").read()
io_src = open(io_path, encoding="utf-8").read()

if kind != "none":
    if kind not in MUT:
        sys.exit("mkblock: unknown mutation %r" % kind)
    target, old, new, what = MUT[kind]
    subject_path = block_path if target == "block" else arch_path
    subject = block if target == "block" else arch
    if subject.count(old) != 1:
        sys.exit("mkblock: %s occurs %dx in %s, expected once — the %r mutation would NOT apply and "
                 "the assertion reading it would pass for the wrong reason: %r"
                 % (what, subject.count(old), os.path.basename(subject_path), kind, old))
    subject = subject.replace(old, new)
    if target == "block":
        block = subject
    else:
        arch = subject

os.makedirs(outdir, exist_ok=True)
with open(os.path.join(outdir, "backlog-archive.py"), "w", encoding="utf-8") as fh:
    fh.write(arch)
written = set()
for src_path, text in ((parser_path, parser), (block_path, block), (head_path, head),
                       (mint_path, mint), (io_path, io_src)):
    with open(os.path.join(outdir, os.path.basename(src_path)), "w", encoding="utf-8") as fh:
        fh.write(text)
    written.add(os.path.basename(src_path))
# Every other sibling by GLOB — same reasoning as in mkmut: this list was manual and cost the identical
# ModuleNotFoundError twice, once per new module, inside the assertions meant to prove a mutation fires.
for extra in sorted(glob.glob(os.path.join(os.path.dirname(os.path.realpath(parser_path)),
                                           "zuvo_backlog_*.py"))):
    if os.path.basename(extra) in written:
        continue
    with open(extra, encoding="utf-8") as fh:
        text = fh.read()
    with open(os.path.join(outdir, os.path.basename(extra)), "w", encoding="utf-8") as fh:
        fh.write(text)
PYEOF

SPANFIX="$FIX/span"
meta="$(python3 "$MKSPAN" "$REAL" B-driftguard-bounded-age "$ROOT/scripts/zuvo-home" "$SPANFIX" 2>&1)"
case "$meta" in
  "HEAD_LEN "*)
    echo "  ... fixture: $meta"
    ok "(H18) the span fixture was generated FROM memory/backlog.md — the real shape, not a hand-written one" ;;
  *)
    no "(H18) the fixture generator refused: $meta — every boundary assertion below would measure nothing"
    finish ;;
esac
set -- $meta
H_LEN="$2"; H_SIBS="$4"; H_REAL_START="${12}"; H_REAL_END="${14}"; H_SIBS_FIX="${16}"
FIXBL="$SPANFIX/memory/backlog.md"

# `${4:-}`, not `$4`: `set -u` is on, and the three-argument modes (attrib, dist) would abort the
# FUNCTION with an unbound-variable error whose text goes to the subshell's stderr and NOT into the
# `$(...)` capture — the caller then compares against an EMPTY string and reports a failure whose
# message names no number. Measured on the first RED run of this group: four assertions failed with
# a blank verdict while the probe had never run.
probe(){ python3 "$SPANPROBE" "$1" "$2" "$3" "${4:-}" 2>&1; }
mkblk(){ python3 "$MKBLOCK" "$ARCHIVE_PY" "$MODULE" "$BLOCK_MOD" "$HEADPOL_MOD" "$MINT_MOD" \
                  "$IO_MOD" "$1" "$FIX/blk-$1" 2>&1; }
blk(){ echo "$FIX/blk-$1/backlog-archive.py"; }

# The CONTROL first: a byte-identical copy must reproduce the real module's numbers, or every mutant
# below could be measuring the copy mechanics instead of the mutation.
c_out="$(mkblk none)"
if [ -z "$c_out" ]; then ok "(H18) the mutant factory wrote the control copy"; else
  no "(H18) the factory could not write the control: $c_out — the mutants below prove nothing"; fi
h_real="$(probe "$ARCHIVE_PY" head "$FIXBL" B-driftguard-bounded-age)"
h_ctl="$(probe "$(blk none)" head "$FIXBL" B-driftguard-bounded-age)"
if [ -n "$h_real" ] && [ "$h_real" = "$h_ctl" ]; then
  ok "(H18) control: the unmutated copy measures the same block as the module itself ($h_real)"; else
  no "(H18) control disagrees with the module: '$h_real' vs '$h_ctl' — the mutants measure the copy, not the rule"; fi

# A1 THE BOUNDARY, byte-exact against the generator's INDEPENDENT extraction.
if [ "$h_real" = "HEAD 1 $H_LEN $H_LEN" ]; then
  ok "(H18/A1) the anchor's block is lines 1-$H_LEN ($H_LEN lines) — the real entry's whole body, not its heading line"; else
  no "(H18/A1) the anchor's block measured '$h_real', expected 'HEAD 1 $H_LEN $H_LEN'"; fi
if probe "$ARCHIVE_PY" text "$FIXBL" B-driftguard-bounded-age | diff -q - "$SPANFIX/expected/head.txt" >/dev/null; then
  ok "(H18/A1) and it is BYTE-IDENTICAL to the independently extracted block (fence/level rules not consulted)"; else
  no "(H18/A1) the block's bytes differ from the independent extraction — diff: $(probe "$ARCHIVE_PY" text "$FIXBL" B-driftguard-bounded-age | diff - "$SPANFIX/expected/head.txt" | head -4 | tr '\n' ' ')"; fi

# A2 + A9 ATTRIBUTION: the four siblings are OUTSIDE the span and own themselves; no span crosses
# another; every non-blank line has an owner at its own nesting level.
at_real="$(probe "$ARCHIVE_PY" attrib "$FIXBL" B-driftguard-bounded-age)"
echo "  ... attribution: $at_real"
case "$at_real" in
  *" inspan=0")
    ok "(H18/A2) no flush-left checkbox fell inside the anchor's span — the $H_SIBS siblings stay their own entries" ;;
  *) no "(H18/A2) a flush-left checkbox was attributed to the anchor heading: $at_real" ;;
esac
case "$at_real" in
  *"selfown=$H_SIBS_FIX "*) ok "(H18/A2) all $H_SIBS_FIX flush-left checkboxes in the fixture ($H_SIBS of them from the real slice) are attributed to THEMSELVES" ;;
  *) no "(H18/A2) the siblings are not attributed to themselves: $at_real (expected selfown=$H_SIBS_FIX)" ;;
esac
case "$at_real" in
  *"orphan_nonblank=0 "*) ok "(H18/A9) every non-blank fixture line has an owning entry (blanks stay file layout)" ;;
  *) no "(H18/A9) some non-blank line belongs to no entry: $at_real" ;;
esac
case "$at_real" in
  *"cross=0 "*) ok "(H18/A9) no two spans partially overlap — the spans nest, so 'own nesting level' is well defined" ;;
  *) no "(H18/A9) a span cuts through another entry's body: $at_real" ;;
esac

# A4/A5/A6 the three cases the real slice cannot carry: fence, nested sub-entry, trailing blanks,
# and the following block left byte-unchanged.
for spec in "B-FENCED|fenced|the fence's flush-left '#' and the nested '### B-FENCED-SUB' stay INSIDE the block, and the trailing blanks are trimmed" \
            "B-FENCED-SUB|sub|the deeper sub-entry's own block runs to the end of its body" \
            "B-NEXT|next|the FOLLOWING heading block is byte-unchanged"; do
  id="${spec%%|*}"; rest="${spec#*|}"; exp="${rest%%|*}"; what="${rest#*|}"
  if probe "$ARCHIVE_PY" text "$FIXBL" "$id" | diff -q - "$SPANFIX/expected/$exp.txt" >/dev/null; then
    ok "(H18/A4-6) $id: $what"; else
    no "(H18/A4-6) $id's block does not match expected/$exp.txt — $what; diff: $(probe "$ARCHIVE_PY" text "$FIXBL" "$id" | diff - "$SPANFIX/expected/$exp.txt" | head -4 | tr '\n' ' ')"; fi
done

# A10 THE FENCE CONTRACT. Three PRE-EXISTING flaws of the detector `entry_block` inherited (the
# `re.match(r"^\s*(```|~~~)", ln)` toggle committed at 16b5df07), fixed here because this function was
# being rewritten anyway. The over-cover one is the reason this group is not a nicety: one stray fence
# marker disabled every structural terminator to EOF, so a heading block absorbed later `## B-…` and
# `- [ ] B-…` entries that `iter_entries` still yields separately — and a future archive move would
# carry those unrelated OPEN entries out of the file with it.
for spec in "B-TILDE|tilde|a ~~~ line does not close a backtick fence, so the heading inside it stays INSIDE the block" \
            "B-INDENTFENCE|indentf|a 4-space-indented fence marker is an indented code line, so the flush-left checkbox after it still terminates" \
            "B-UNCLOSED|unclosed|an UNCLOSED fence does not extend the span past the next structural boundary"; do
  id="${spec%%|*}"; rest="${spec#*|}"; exp="${rest%%|*}"; what="${rest#*|}"
  if probe "$ARCHIVE_PY" text "$FIXBL" "$id" | diff -q - "$SPANFIX/expected/$exp.txt" >/dev/null; then
    ok "(H18/A10) $id: $what"; else
    no "(H18/A10) $id's block does not match expected/$exp.txt — $what; diff: $(probe "$ARCHIVE_PY" text "$FIXBL" "$id" | diff - "$SPANFIX/expected/$exp.txt" | head -4 | tr '\n' ' ')"; fi
done
# The over-cover case, stated as what it is rather than only as a byte compare: the two entries that
# follow the stray marker must not be inside B-UNCLOSED's span at all.
u_span="$(probe "$ARCHIVE_PY" head "$FIXBL" B-UNCLOSED)"
u_later="$(probe "$ARCHIVE_PY" head "$FIXBL" B-LATER)"
echo "  ... unclosed fence: B-UNCLOSED $u_span | B-LATER $u_later"
set -- $u_span
u_end="$3"
set -- $u_later
if [ -n "$u_end" ] && [ "$2" -gt "$u_end" ]; then
  ok "(H18/A10) B-LATER starts at line $2, AFTER B-UNCLOSED's span ends at $u_end — no over-cover past the boundary"; else
  no "(H18/A10) B-LATER (at $2) is inside B-UNCLOSED's span (ends $u_end) — the stray fence swallowed a later entry"; fi

# An out-of-range start is a RAISE, not a silently empty span: every consumer slices or DELETES the
# range this returns, so a span for a line that does not exist is a wrong answer, not a harmless one.
if [ "$(pyb "
import zuvo_backlog_block as zbb
try:
    zbb.entry_block(['only one line\n'], 5)
    print('NO-RAISE')
except IndexError as exc:
    print('IndexError' if 'outside 0..0' in str(exc) and '5' in str(exc) else 'BAD-MESSAGE')")" = "IndexError" ]; then
  ok "(H18/A10) entry_block raises IndexError naming the index and the length on an out-of-range start"; else
  no "(H18/A10) an out-of-range start does not raise an actionable IndexError — a caller would read a span for a line that does not exist"; fi

# A7/A8 THE REAL FILE. Structural, derived: absolutes here would be a false red by tomorrow
# (memory/backlog.md grew 1812 -> 2069 lines during the session this was written in).
d_real="$(probe "$ARCHIVE_PY" dist "$REAL")"
echo "  ... real-file distribution: $d_real"
case "$d_real" in
  *"TRUNC 0 -") ok "(H18/A7) no id-shaped heading measures ONE line while its next non-blank line is continuation content" ;;
  *) no "(H18/A7) id-shaped headings still truncate to a single line with content below them: $d_real" ;;
esac
r_head="$(probe "$ARCHIVE_PY" head "$REAL" B-driftguard-bounded-age)"
if [ "$r_head" = "HEAD $H_REAL_START $H_REAL_END $H_LEN" ]; then
  ok "(H18/A8) on the REAL file the anchor spans $H_REAL_START-$H_REAL_END ($H_LEN lines), matching the independent extraction"; else
  no "(H18/A8) the real-file span is '$r_head', the independent extraction says 'HEAD $H_REAL_START $H_REAL_END $H_LEN'"; fi

# --- H18b MUTANTS: every assertion above, shown catching the behaviour it claims to pin -----------
# Six mutations, each reverting ONE behaviour. A mutation whose substitution does not apply is a
# hard error from the factory, so "the mutant passed" can never mean "the mutant was not built".
mut_head(){ probe "$(blk "$1")" head "$FIXBL" B-driftguard-bounded-age; }
for spec in "legacy|HEAD 1 1 1|the pre-Task-3 rule truncates the anchor to its heading line" \
            "levelonly|inspan|dropping the sibling terminator sweeps the siblings in" ; do
  m="${spec%%|*}"; rest="${spec#*|}"; want="${rest%%|*}"; why="${rest#*|}"
  out="$(mkblk "$m")"
  if [ -n "$out" ]; then no "(H18b) the $m mutant did not build: $out"; continue; fi
  if [ "$m" = "legacy" ]; then
    got="$(mut_head "$m")"
    [ "$got" = "$want" ] \
      && ok "(H18b) $m: the anchor measures '$got' — $why, and A1 fails on it" \
      || no "(H18b) $m measured '$got', not '$want' — A1 would not have caught the old rule"
  else
    got="$(probe "$(blk "$m")" attrib "$FIXBL" B-driftguard-bounded-age)"
    case "$got" in
      *" inspan=0") no "(H18b) $m still reports inspan=0 — A2 does not catch $why: $got" ;;
      *) ok "(H18b) $m: $got — $why, and A2 fails on it" ;;
    esac
  fi
done

# The three structural mutants, each checked against the byte-exact expectation it should break.
for spec in "anylevel|fenced|a nested '### B-FENCED-SUB' must not end its parent" \
            "nofence|fenced|a flush-left '#' inside a fence must not end the block" \
            "notrim|next|trailing blank lines must be trimmed back out of the block"; do
  m="${spec%%|*}"; rest="${spec#*|}"; exp="${rest%%|*}"; why="${rest#*|}"
  id="B-FENCED"; [ "$exp" = "next" ] && id="B-NEXT"
  out="$(mkblk "$m")"
  if [ -n "$out" ]; then no "(H18b) the $m mutant did not build: $out"; continue; fi
  if probe "$(blk "$m")" text "$FIXBL" "$id" | diff -q - "$SPANFIX/expected/$exp.txt" >/dev/null; then
    no "(H18b) $m produced the SAME block as the real module — the A4-6 compare on expected/$exp.txt does not pin: $why"
  else
    ok "(H18b) $m changes $id's block, so the byte compare pins it — $why"
  fi
done

# The three FENCE mutants, each reverting one inherited flaw, against the case built for it.
for spec in "fenceeof|B-UNCLOSED|unclosed|an unclosed fence running to EOF swallows the entries after it" \
            "fenceany|B-TILDE|tilde|a ~~~ closing a backtick fence lets the heading inside it cut the block" \
            "fenceindent|B-INDENTFENCE|indentf|a 4-space fence pair hides the flush-left checkbox between them"; do
  m="${spec%%|*}"; rest="${spec#*|}"; id="${rest%%|*}"; rest="${rest#*|}"; exp="${rest%%|*}"; why="${rest#*|}"
  out="$(mkblk "$m")"
  if [ -n "$out" ]; then no "(H18b) the $m mutant did not build: $out"; continue; fi
  got="$(probe "$(blk "$m")" head "$FIXBL" "$id")"
  if probe "$(blk "$m")" text "$FIXBL" "$id" | diff -q - "$SPANFIX/expected/$exp.txt" >/dev/null; then
    no "(H18b) $m produced the SAME block for $id as the real module ($got) — the A10 compare on expected/$exp.txt pins nothing: $why"
  else
    ok "(H18b) $m changes $id's block to $got — $why, and A10 fails on it"
  fi
done

# The crossing mutant: a boundary that ends a parent INSIDE its own sub-entry's body. This is the one
# case `cross` exists for, and the one no other mutant here produces.
out="$(mkblk indentterm)"
if [ -n "$out" ]; then no "(H18b) the indentterm mutant did not build: $out"; else
  got="$(probe "$(blk indentterm)" attrib "$FIXBL" B-driftguard-bounded-age)"
  case "$got" in
    *"cross=0 "*) no "(H18b) indentterm still reports cross=0 — the no-crossing assertion pins nothing: $got" ;;
    *) ok "(H18b) indentterm: $got — a parent ending inside its sub-entry is caught as a CROSSING span" ;;
  esac
fi

# And the mutant that reproduces the ORIGINAL finding on the real file: six one-line blocks with
# content below them. The count is printed, never asserted as a literal — the file keeps growing.
d_leg="$(probe "$(blk legacy)" dist "$REAL")"
echo "  ... legacy on the real file: $d_leg"
case "$d_leg" in
  "DIST "*"TRUNC 0 -") no "(H18b) even the legacy rule reports no truncation on $REAL — A7 is vacuous here" ;;
  "DIST "*) ok "(H18b) the legacy rule still truncates real entries (${d_leg#*TRUNC }) — A7 measures a live defect" ;;
  *) no "(H18b) the legacy probe failed on the real file: $d_leg" ;;
esac

# --- H19 ONE producer for end_lineno, and the pin guard over the whole MODULE FAMILY -------------
# The parser sets `end_lineno` to the entry's OWN line, deliberately (a block's extent is
# level-and-sibling aware and belongs to the rewriting side). So two values could answer "where does
# this entry end", which is the `LOOKUP_KINDS` defect shape: `with_span` is the single producer, and
# every function in backlog-archive.py whose entries LEAVE it must route them through it.
#
# First the vacuity guard, and it is the load-bearing one: the parser's raw value must be shown to
# DISAGREE on this fixture. If it happened to agree, every assertion below would hold with the routing
# deleted, which is exactly the state that shipped before this round.
raw_vs_span="$(pyb "
import zuvo_backlog_block as zbb
t = open('$FIXBL').read(); lines = t.splitlines(keepends=True)
heads = [e for e in zb.iter_entries(t, kinds=(zb.KIND_HEADING,)) if e.ident == 'B-driftguard-bounded-age']
h = heads[0]
print('%d %d' % (h.end_lineno, zbb.entry_block(lines, h.lineno - 1)))")"
set -- $raw_vs_span
if [ "$#" -eq 2 ] && [ "$1" -ne "$2" ]; then
  ok "(H19) vacuity guard: the parser's raw end_lineno ($1) DISAGREES with the measured span ($2), so the routing below is load-bearing"; else
  no "(H19) the parser's raw end_lineno and the measured span read '$raw_vs_span' — if they agree, every assertion below passes with the routing removed"; fi

# Behavioural: every entry that LEAVES a producer carries the measured span. classify() is the one the
# write paths read, and its entries are checkbox-shaped — the dialect whose continuation lines the
# heading rule did not change, so this is not a restatement of A1.
# A fixture of its own, because the REAL backlog currently holds nothing resolved-and-unarchived, so
# classify() returns zero entries there and the assertion would pass having measured nothing. The
# entry is CHECKBOX-shaped with continuation lines — the dialect the heading rule did not touch, so
# this is a claim about the routing and not a restatement of A1.
mkrepo "$FIX/span-cls"
{ printf '# Tech Debt Backlog\n\n## Open\n\n'
  printf -- '- [x] B-multi [FIXED deadbee] src/one.ts the ticked entry whose body runs on\n'
  printf '  continuation line one, indented, part of the entry\n'
  printf '  continuation line two\n'
  printf -- '- [ ] B-still-open src/two.ts a genuinely open checkbox\n'; } > "$FIX/span-cls/memory/backlog.md"
span_agree="$(pyb "
import zuvo_backlog_block as zbb
t = open('$FIX/span-cls/memory/backlog.md').read(); lines = t.splitlines(keepends=True)
marked, unmarked, _, _plan = BA.classify(t)
ents = [e for _, e in marked + unmarked]
bad = [e.ident or e.key for e in ents if e.end_lineno != zbb.entry_block(lines, e.lineno - 1)]
multi = [e for e in ents if e.end_lineno > e.lineno]
print('%d %d %d %s' % (len(ents), len(multi), len(bad), ','.join(bad[:3]) or '-'))")"
echo "  ... classify(): $span_agree  (entries, multi-line, disagreeing, ids)"
set -- $span_agree
if [ "$1" -gt 0 ] && [ "$3" -eq 0 ]; then
  ok "(H19) classify() returns $1 entries and every one's end_lineno equals its measured block end"; else
  no "(H19) classify() entries disagree with the measured span: $span_agree"; fi

# find()'s heading entry, the read path — the case where the parser's default is most wrong.
if [ "$(pyb "
import zuvo_backlog_block as zbb
e = BA.find('$REAL', 'id:b-driftguard-bounded-age')
lines = open('$REAL').read().splitlines(keepends=True)
print('%s' % (e is not None and e.end_lineno == zbb.entry_block(lines, e.lineno - 1) and e.end_lineno > e.lineno))")" = "True" ]; then
  ok "(H19) find() returns the heading entry with a MEASURED multi-line span, not the parser's own line"; else
  no "(H19) find()'s entry carries the parser's default end_lineno — the two-producer mismatch is back"; fi

# MECHANICAL, because the behavioural half only sees the producers it thinks to call: the archiver must
# read `end_lineno` NOWHERE (every span comes from the block module), and the block module must set it
# exactly once. A new producer anywhere else changes one of these two numbers the moment it is written.
# The POLICY module is scanned for SETS too, not for reads: it legitimately READS the span it just had
# measured (that is what `with_span` is for), but if it ever SET `end_lineno` itself there would be two
# producers again — the exact shape this group exists to pin, one module further out.
prod="$(python3 -c "
import ast, sys
arch = open('$ARCHIVE_PY', encoding='utf-8').read()
blk = open('$BLOCK_MOD', encoding='utf-8').read()
pol = open('$HEADPOL_MOD', encoding='utf-8').read()
reads = sum(1 for n in ast.walk(ast.parse(arch))
            if isinstance(n, ast.Attribute) and n.attr == 'end_lineno')
def sets(src):
    return sum(1 for n in ast.walk(ast.parse(src)) if isinstance(n, ast.Call)
               for kw in n.keywords if kw.arg == 'end_lineno')
print('%d %d %d %d' % (reads, sets(arch), sets(blk), sets(pol)))")"
echo "  ... end_lineno: archiver reads/sets, block sets, policy sets = $prod"
[ "$prod" = "0 0 1 0" ] \
  && ok "(H19) the archiver neither reads nor sets end_lineno, the block module sets it exactly ONCE and the policy module never sets it — one producer, mechanically" \
  || no "(H19) end_lineno producers/readers read '$prod', expected '0 0 1 0' (archiver reads, archiver sets, block sets, policy sets) — a second source of truth"

# Which functions route: the owner list, so a new producer that keeps the totals balanced still shows.
owners="$(python3 -c "
import ast
src = open('$ARCHIVE_PY', encoding='utf-8').read()
out = []
def walk(n, owner):
    for c in ast.iter_child_nodes(n):
        nxt = c.name if isinstance(c, ast.FunctionDef) else owner
        if isinstance(c, ast.Call) and isinstance(c.func, ast.Name) and c.func.id == 'with_span':
            out.append(owner)
        walk(c, nxt)
walk(ast.parse(src), '<module>')
print(','.join(sorted(set(out))) or '-')")"
[ "$owners" = "classify,find,undeclared_pairs" ] \
  && ok "(H19) with_span is called in exactly the three functions whose entries LEAVE them: $owners" \
  || no "(H19) with_span callers are '$owners', not 'classify,find,undeclared_pairs' — a producer was added or one stopped spanning"

# cmd_index is the ONE deliberate exception, and the reason has to live in the code rather than only in
# a report: a bare absence reads as an oversight to the next editor.
if python3 -c "
import ast, sys
src = open('$ARCHIVE_PY', encoding='utf-8').read()
fn = [n for n in ast.parse(src).body if isinstance(n, ast.FunctionDef) and n.name == 'cmd_index'][0]
body = '\n'.join(src.splitlines()[fn.lineno - 1:fn.end_lineno])
sys.exit(0 if 'with_span' in body and 'span column' in body else 1)"; then
  ok "(H19) cmd_index names its exclusion from with_span IN CODE, with the reason (no span column in the TSV)"; else
  no "(H19) cmd_index's exclusion is undocumented in the source — the next reader cannot tell a decision from an omission"; fi

# The mutant: classify() hands its entries on unspanned. This is the state that shipped before this
# round, and the behavioural assertion above must fail on it.
out="$(mkblk nospan)"
if [ -n "$out" ]; then no "(H19b) the nospan mutant did not build: $out"; else
  got="$(python3 -c "
import importlib.util, sys
from importlib.machinery import SourceFileLoader
sys.path.insert(0, '$FIX/blk-nospan')
p = '$FIX/blk-nospan/backlog-archive.py'
spec = importlib.util.spec_from_file_location('ba_ns', p, loader=SourceFileLoader('ba_ns', p))
M = importlib.util.module_from_spec(spec); sys.modules['ba_ns'] = M; spec.loader.exec_module(M)
import zuvo_backlog_block as zbb
t = open('$FIX/span-cls/memory/backlog.md').read(); lines = t.splitlines(keepends=True)
marked, unmarked, _, _plan = M.classify(t)
ents = [e for _, e in marked + unmarked]
print(sum(1 for e in ents if e.end_lineno != zbb.entry_block(lines, e.lineno - 1)))" 2>&1)"
  if [ "$got" -gt 0 ] 2>/dev/null; then
    ok "(H19b) nospan: $got of classify()'s entries then disagree with the measured span — the routing assertion is load-bearing"; else
    no "(H19b) nospan produced no disagreement ($got) — classify()'s routing assertion pins nothing"; fi
fi

# --- H19c the pin guard over the whole module FAMILY, not one file -------------------------------
# It only ever scanned backlog-archive.py, which was right while that was the only production module
# here. It is not any more: an `iter_entries` call added to zuvo_backlog_block.py would be invisible in
# all four of the guard's dimensions. The family is DERIVED (the archiver plus every zuvo_backlog_*.py
# that imports the parser), so a third module joins the scan by existing rather than by being listed —
# and the parser itself is excluded because it DEFINES iter_entries, which makes the guard exit 2.
# NEWLINE-DELIMITED, not space-joined. A space-joined list is word-split at every use site, so a repo
# path containing a space silently splits one module into two nonexistent ones — the derivation then
# scans neither, and the guard reports a family it never examined. That is the failure mode this whole
# assertion exists to prevent, reachable through the list that carries it. `$ROOT` is a mktemp path or
# a checkout path, so today it has no space; "today it has no space" is exactly the reasoning that
# makes such a break expensive to find later. Newlines also make `grep -qxF` below the natural match
# rather than a hedge against the separator.
FAMILY="$ARCHIVE_PY"
for f in "$ROOT"/scripts/zuvo-home/zuvo_backlog_*.py; do
  [ "$f" = "$MODULE" ] && continue
  grep -q "^import zuvo_backlog_parse" "$f" && FAMILY="$FAMILY
$f"
done
fam_n="$(printf '%s\n' "$FAMILY" | grep -c .)"
[ "$fam_n" -ge 2 ] \
  && ok "(H19c) the pin-guard family resolved to $fam_n modules — the scan covers the family, not one file" \
  || no "(H19c) the family resolved to $fam_n module(s); a sibling module would go unscanned"
# THE DERIVATION, asserted for the newest sibling by NAME. Task 5's io layer reaches `main_root`
# through the parser, which is what puts it inside the derived family above — but "the glob found it"
# and "it imports the parser" are two different facts, and only the second one is what the derivation
# keys on. A future io that got `main_root` some other way would drop silently OUT of the scan and an
# `iter_entries` call added there would be invisible in all four of the guard's dimensions: a coverage
# hole created by a refactor, which is worse than the duplication avoiding it would have cost.
# Matched on WHOLE LINES (`grep -qxF`), which is what the newline-delimited list above is for. The
# history is worth keeping: the original `case " $FAMILY " in *" $IO_MOD "*)` was correct against a
# space-joined list, and two independent adversarial providers still filed it as a CRITICAL false-RED
# after misreading `printf '%s\n' $FAMILY | grep -c .` as proof the list was newline-joined. They were
# wrong about the code and right about the fragility, and the structure audit then found the actual
# bug their instinct was circling: the space-joined list itself breaks on a path containing a space.
# Both readings are now moot — the list is newline-delimited and matched exactly.
if printf '%s\n' "$FAMILY" | grep -qxF "$IO_MOD"; then
  ok "(H19c) zuvo_backlog_io.py is IN the derived family — it imports the parser, so the guard scans it by existing"
else
  no "(H19c) zuvo_backlog_io.py is NOT in the derived family ($FAMILY) — it no longer matches '^import zuvo_backlog_parse', so an iter_entries call added to the io layer would go unscanned in all four dimensions; either restore the import or widen the derivation AND add an explicit per-file expectation below"
fi
fam_pin=0; fam_loose=0; fam_gated=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  v="$(python3 "$FIX/pinguard.py" "$f" 2>&1)"
  base="$(basename "$f")"
  case "$base" in
    backlog-archive.py) want="7 2 cmd_index,find 0 0 -"
      why="the seven pins and the two readers — and no heading request of its own" ;;
    zuvo_backlog_heading.py) want="0 0 - 0 1 $PIN_GATE_OWNER"
      why="the family's ONE env-gated call, and nothing else" ;;
    zuvo_backlog_conserve.py) want="1 0 - 0 0 -"
      why="the over-cover refusal: one PINNED read of the document, on a write path, under the lock" ;;
    *) want="0 0 - 0 0 -"
      why="no iter_entries call at all, so neither an unpinned selection nor a second gate can hide there" ;;
  esac
  [ "$v" = "$want" ] && ok "(H19c) $base: $v — $why" \
    || no "(H19c) $base: '$v', expected '$want' — $why"
  # FAIL-CLOSED. `pinguard.py` exits 2 on its own vacuity guard (it could not resolve the parser under
  # any name in that file), and then `$v` is a prose error rather than six fields. The old
  # `[ "$#" -eq 6 ] && { … }` silently skipped the accumulation, so the 7/2/1 total below came out
  # UNDERSTATED rather than red — a guard reporting a smaller number than reality is the one shape a
  # count assertion cannot survive, because "fewer unpinned sites than expected" reads like good news.
  # The per-file `no` above does catch it, but the aggregate must not be quietly wrong either.
  set -- $v
  if [ "$#" -eq 6 ]; then
    fam_pin=$((fam_pin + $1)); fam_loose=$((fam_loose + $2)); fam_gated=$((fam_gated + $5))
  else
    no "(H19c) pinguard.py did not return six fields for $base — it answered '$v'. The family totals below would be understated, not red, so this is failed here instead."
  fi
done <<FAMEOF
$FAMILY
FAMEOF
# AC4′ as ONE number over the whole family, which is the scope the claim is actually made at: a call
# site that moved from one module to another keeps the totals honest even if a per-file expectation
# above were relaxed by a future edit.
echo "  ... family totals: pinned=$fam_pin unpinned=$fam_loose env-gated=$fam_gated"
[ "$fam_pin" -eq 8 ] && [ "$fam_loose" -eq 2 ] && [ "$fam_gated" -eq 1 ] \
  && ok "(H19c/AC4′) across the $fam_n-module family: exactly 8 unconditionally-pinned calls, 2 unpinned (both readers) and exactly 1 env-gated site" \
  || no "(H19c/AC4′) family totals are pinned=$fam_pin unpinned=$fam_loose env-gated=$fam_gated, expected 7/2/1"

# --- H14d MUTANTS of the GATE: what AC4′'s revised pin guard actually catches ---------------------
# Task 2's guard said "7 pinned, zero unpinned outside the two readers". This task adds an eighth,
# env-gated site, so the guard had to be revised IN THE SAME COMMIT — and a revised guard is worth
# exactly what its sensitivity is. Four mutations, each reverting one half of the new claim, with the
# verdict asserted as a WHOLE STRING: a mutation that moved a different field than the one under test
# would otherwise read as a pass.
# The FILE to scan travels with the mutant, because three of these four mutate the policy module and
# the fourth mutates the archiver — scanning the wrong one would report the unmutated verdict and pass.
gate_guard(){
  gg_m="$1"; gg_file="$2"; gg_want="$3"; gg_why="$4"
  gg_out="$(mkmut "$gg_m" 2>&1)"
  if [ -n "$gg_out" ]; then no "(H14d) the $gg_m mutant did not build: $gg_out"; return; fi
  gg_v="$(python3 "$FIX/pinguard.py" "$FIX/mut-$gg_m/$gg_file" 2>&1)"
  if [ "$gg_v" = "$gg_want" ]; then
    ok "(H14d) $gg_m ($gg_file) -> '$gg_v' — $gg_why"; else
    no "(H14d) $gg_m ($gg_file) reported '$gg_v', expected '$gg_want' — $gg_why"; fi
}
gate_guard ungated zuvo_backlog_heading.py "0 1 $PIN_GATE_OWNER 0 0 -" \
  "deleting the gate's early return moves the heading request into the UNPINNED bucket, so AC4′'s 'exactly one env-gated site' FAILS on an ungated heading request in a write path"
gate_guard fakegate zuvo_backlog_heading.py "0 1 $PIN_GATE_OWNER 0 0 -" \
  "an if/return that does not name the env var is not a gate: the guard resolves the gate by NAME, so a coincidental early return cannot pose as one"
gate_guard secondgate zuvo_backlog_heading.py "0 0 - 0 2 $PIN_GATE_OWNER,$PIN_GATE_OWNER" \
  "a SECOND gated call is counted, so 'exactly one' is load-bearing and not a restatement of 'at least one'"
gate_guard unconditional backlog-archive.py "6 3 classify,cmd_index,find 0 0 -" \
  "KIND_HEADING added to classify()'s PINNED call drops the pin count to 6 and leaves it UNGATED — the shape the gated-site count alone would miss"

# --- H20 THE MINT ANCHOR (AC7): a heading line mints at its BODY position ------------------------
# D2, measured: cmd_archive's mint was anchored on `^(\s*[-*]\s*\[[ xX]\]\s*)` and wrapped in
# `if m_cb:`, so on a `## B-x` line it inserted nothing AND reported nothing. The insert POSITION is
# not cosmetic: `MINTED_ID_RE` is `^B-A\d{8}-[0-9a-f]{6}\s+` against `Entry.body`, and `keys_for`
# strips exactly that prefix to recover the content key an entry had BEFORE the archiver minted one.
# An id anywhere else, or under any other prefix, leaves the archived entry findable ONLY under its
# new id — which is the silent half of the 2026-07 tgm-pulse incident (the archive took the same
# three entries twice and neither guard saw it, because the two keys had stopped describing the same
# entry).
if pyb "sys.exit(0 if callable(getattr(BA, 'mint_into', None)) else 1)"; then
  ok "(H20) backlog-archive.py exposes mint_into() — the dialect-aware anchor"; else
  no "(H20) no mint_into() in backlog-archive.py: the mint is still anchored at its call site, so every assertion below would measure nothing"; fi

# The minted id's own SHAPE first: every assertion below rests on it matching MINTED_ID_RE, and
# mint_id() is the only producer.
if [ "$(pyb "
import re
print(bool(re.fullmatch(r'B-A\d{8}-[0-9a-f]{6}', BA.mint_id('some entry text'))))")" = "True" ]; then
  ok "(H20/AC7) mint_id() produces B-A<YYYYMMDD>-<6hex> — the shape MINTED_ID_RE strips"; else
  no "(H20/AC7) mint_id() produced $(pyb "print(BA.mint_id('some entry text'))") — keys_for cannot strip that, so archiving would lose the pre-mint content key"; fi

# THE HEADING CASE, end to end through the parser: mint into the line, re-parse the result, and check
# the minted id at body position 0 AND the keys_for bridge. Re-parsing is the point — an assertion on
# the raw line would pass with the id inserted before the hashes, where `body` never sees it.
mint_head="$(pyb "
line = '## B-mint-head — DONE b9767b6a\n'
before = list(zb.iter_entries(line, kinds=(zb.KIND_HEADING,)))[0]
after_line = BA.mint_into(line, BA.mint_id(before.body))
after = list(zb.iter_entries(after_line, kinds=(zb.KIND_HEADING,)))[0]
m = zb.MINTED_ID_RE.match(after.body)
print('%s %s %s %s' % (after_line.startswith('## B-A'), bool(m), m.start() if m else -1,
                       zb.keys_for(after.body, after.ident) >= {zb.entry_key(before.body, before.ident)}))")"
echo "  ... mint into a heading: $mint_head  (after-line, MINTED_ID_RE, position, keys_for bridge)"
case "$mint_head" in
  "True True 0 True")
    ok "(H20/AC7) minting into '## B-x' inserts the id after the hashes: MINTED_ID_RE matches body position 0 and keys_for(after) still carries entry_key(before)" ;;
  *) no "(H20/AC7) the heading mint produced '$mint_head', expected 'True True 0 True' — the id is not at the body's start, or the keys_for bridge is broken" ;;
esac
# And the whole point of the bridge, spelled out: the PRE-MINT key must still be one of the keys the
# archived entry answers to, or a lookup by the id the entry always had misses it.
if [ "$(pyb "
line = '## B-mint-head — DONE b9767b6a\n'
before = list(zb.iter_entries(line, kinds=(zb.KIND_HEADING,)))[0]
after = list(zb.iter_entries(BA.mint_into(line, BA.mint_id(before.body)), kinds=(zb.KIND_HEADING,)))[0]
print(sorted(zb.keys_for(after.body, after.ident))[-1] == zb.entry_key(before.body, before.ident))")" = "True" ]; then
  ok "(H20/AC7) the pre-mint key is literally in keys_for(after) — not merely a superset by accident"; else
  no "(H20/AC7) keys_for(after) does not contain the pre-mint key"; fi

# THE CHECKBOX PATH IS BYTE-UNCHANGED — the negative control for D2's silent no-op. The expectation
# is computed here by the OLD expression, so this is a comparison against the pre-change behaviour
# rather than against a hand-written string that could encode the same mistake twice.
cb_parity="$(pyb "
import re
LEG = re.compile(r'^(\s*[-*]\s*\[[ xX]\]\s*)')
def legacy(line, minted):
    g = LEG.match(line)
    return line if g is None else line[:g.end()] + minted + ' ' + line[g.end():]
# Shapes with a BODY: the legacy expression's \s* and the new [ \t]* stop at the same character, so
# these must be byte-identical. The body-less and trailing-space shapes are deliberately NOT here —
# that is where legacy wrote the id onto the next line, and H23/F1 asserts the new behaviour.
SHAPES = ['- [x] src/one.ts no id here\n', '- [ ] src/two.ts open, also unminted\n',
          '  - [x] indented child without an id\n', '* [X] a star bullet, capital X\n',
          '-[x] no space after the dash\n', '- [x]   extra spaces after the box\n']
# Lines the anchor cannot match: legacy returned them UNCHANGED (the silent no-op that let an id-less
# entry reach the archive), the new one REFUSES.
UNANCHORED = ['| B-tbl | a table row | RESOLVED |\n', '  ## B-ind an indented heading is prose\n',
              'plain prose that is not an entry at all\n']
bad = [s for s in SHAPES if BA.mint_into(s, 'B-A20260101-abcdef') != legacy(s, 'B-A20260101-abcdef')]
kept = [s for s in UNANCHORED if BA.mint_into(s, 'B-A20260101-abcdef') is not None]
print('%d %s %d %s' % (len(SHAPES), ','.join(repr(b) for b in bad) or '-',
                       len(UNANCHORED), ','.join(repr(k) for k in kept) or '-'))")"
echo "  ... parity with the legacy expression / refusals: $cb_parity"
case "$cb_parity" in
  "6 - 3 -") ok "(H20/AC7) all 6 shapes WITH A BODY mint byte-identically to the pre-change expression, and all 3 lines it cannot anchor are REFUSED rather than returned unchanged" ;;
  *) no "(H20/AC7) the checkbox mint path changed, or an unanchored line was accepted: $cb_parity" ;;
esac
# The lines that are NOT entry definitions must be refused, one by one — the parity check above groups
# them, and a group can hide one member that slipped through.
if [ "$(pyb "
S = ['| B-tbl | a table row | RESOLVED |\n', '  ## B-ind an indented heading is prose\n',
     '> ## B-quote a quoted heading\n', '####### B-seven past the level range\n',
     '##B-nospace no whitespace after the hashes\n', '- plain bullet, no checkbox\n']
print(','.join(s for s in S if BA.mint_into(s, 'B-A20260101-abcdef') is not None) or '-')")" = "-" ]; then
  ok "(H20/AC7) a table row, a quoted/indented heading, 7 hashes, '##x' and a plain bullet are all REFUSED — the anchor admits only the two entry dialects, and a miss is never silent"; else
  no "(H20/AC7) mint_into wrote into a line that is not an entry definition: $(pyb "
S = ['| B-tbl | a table row | RESOLVED |\n', '  ## B-ind an indented heading is prose\n',
     '> ## B-quote a quoted heading\n', '####### B-seven past the level range\n',
     '##B-nospace no whitespace after the hashes\n', '- plain bullet, no checkbox\n']
print([(s, BA.mint_into(s, 'X')) for s in S if BA.mint_into(s, 'X') is not None])")"; fi

# --- H20b the mint mutants ------------------------------------------------------------------------
# Prints WHY the mutant's mint failed, not merely that it did: NO-ANCHOR (the anchor does not match
# the dialect at all) and REFUSED-BAD-ID (it matches, but the id it would write is not one
# `MINTED_ID_RE` can strip) are different defects, and one assertion must not cover for the other.
mintprobe(){ python3 -c "
import sys
sys.path.insert(0, '$FIX'); sys.path.insert(0, '$FIX/mut-$1')
import zuvo_backlog_parse as zb
import zuvo_backlog_mint as zm
from ba import load
BA = load('$FIX/mut-$1/backlog-archive.py')
line = '## B-mint-head — DONE b9767b6a\n'
before = list(zb.iter_entries(line, kinds=(zb.KIND_HEADING,)))[0]
after_line = BA.mint_into(line, BA.mint_id(before.body))
if after_line is None:
    print('NO-ANCHOR' if zm._MINT_ANCHOR_RE.match(line) is None else 'REFUSED-BAD-ID')
    raise SystemExit(0)
after = list(zb.iter_entries(after_line, kinds=(zb.KIND_HEADING,)))[0]
print('WROTE %s %s' % (bool(zb.MINTED_ID_RE.match(after.body)),
                       zb.keys_for(after.body, after.ident) >= {zb.entry_key(before.body, before.ident)}))" 2>&1; }
out="$(mkmut mintcb 2>&1)"
if [ -n "$out" ]; then no "(H20b) the mintcb mutant did not build: $out"; else
  got="$(mintprobe mintcb)"
  case "$got" in
    NO-ANCHOR) ok "(H20b) mintcb: the checkbox-only anchor does not match a heading line at all, so the mint refuses ($got) — D2's shape, now loud instead of silent, and AC7 fails on it" ;;
    *) no "(H20b) mintcb still minted into the heading ($got) — AC7's assertion pins nothing" ;;
  esac
fi
out="$(mkmut mintprefix 2>&1)"
if [ -n "$out" ]; then no "(H20b) the mintprefix mutant did not build: $out"; else
  got="$(mintprobe mintprefix)"
  case "$got" in
    REFUSED-BAD-ID) ok "(H20b) mintprefix: the anchor matches but a 'B-G…' id is not one MINTED_ID_RE can strip, so the mint refuses rather than breaking the keys_for bridge ($got) — the prefix assertion is load-bearing" ;;
    "WROTE False"*) no "(H20b) a B-G id was WRITTEN and the keys_for bridge broke ($got) — the mint's own MINTED_ID_RE check is not enforcing" ;;
    *) no "(H20b) with a B-G prefix the probe reported '$got', expected REFUSED-BAD-ID" ;;
  esac
fi

# --- H20c THE OVER-COVER REFUSAL: the one check that does not trust the boundary rule -------------
# From the aggregate review's behaviour audit, which reproduced this end-to-end on the DEFAULT gate-off
# archive path: a stray ``` inside one entry's prose pairs with a LATER entry's code-sample opener, the
# span between them is stepped over as content, and `- [ ] B-two still OPEN work` is carried into
# backlog-done.md — after which `lookup` answers ARCHIVED for live work. Both existing conservation
# checks pass while it happens, and their own comment says why: the presence check finds every moved
# line present, and the line-accounting check balances, because the swallowed lines really did move
# exactly once. So `_refuse_foreign_entries` is the only signal, and this group is what proves it fires.
mkdir -p "$FIX/oc/memory"
{ printf -- '- [x] B-one — FIXED abc1234\n'
  printf -- '  repro used ``` in prose\n'
  printf '```\n'
  printf -- '  leftover\n'
  printf -- '- [ ] B-two still OPEN work\n'
  printf -- '  detail for two\n'
  printf -- '  sample:\n'
  printf '```\n'
  printf -- 'x\n'
  printf '```\n'
  printf -- '- [ ] B-three OPEN\n'; } > "$FIX/oc/memory/backlog.md"
( cd "$FIX/oc" && git init -q . && printf 'zuvo/\n' > .gitignore ) >/dev/null 2>&1
# VACUITY GUARD: the boundary really must over-cover on this fixture, or the refusal below proves
# nothing. entry_block for B-one has to reach past B-two's line (index 4).
oc_span="$(py "
import zuvo_backlog_block as _zbb
lines = open('$FIX/oc/memory/backlog.md').read().splitlines(keepends=True)
print(_zbb.entry_block(lines, 0))" 2>/dev/null)"
[ "${oc_span:-0}" -gt 4 ] \
  && ok "(H20c) the fixture DOES over-cover: entry_block(B-one) reaches index $oc_span, past B-two at index 4 — so the refusal below has something to catch" \
  || no "(H20c) entry_block(B-one) stops at index ${oc_span:-?}, so this fixture no longer reproduces the over-cover and the refusal assertion would pass vacuously"

oc_before="$(shasum -a 256 < "$FIX/oc/memory/backlog.md" | cut -d' ' -f1)"
oc_out="$(python3 "$ARCHIVE_PY" archive --repo "$FIX/oc" 2>&1)"; oc_rc=$?
oc_after="$(shasum -a 256 < "$FIX/oc/memory/backlog.md" | cut -d' ' -f1)"
if [ "$oc_rc" -ne 0 ] && case "$oc_out" in *"was not selected for archiving"*) true ;; *) false ;; esac; then
  ok "(H20c) archive REFUSES rather than over-covering: rc=$oc_rc — '$(printf '%s' "$oc_out" | head -1 | cut -c1-96)'"
else
  no "(H20c) archive answered rc=$oc_rc '$(printf '%s' "$oc_out" | head -1)' — an over-covering block was accepted, which is how an OPEN entry reaches backlog-done.md"
fi
[ "$oc_before" = "$oc_after" ] \
  && ok "(H20c) FAIL-CLOSED: backlog.md is byte-unchanged after the refusal ($oc_before)" \
  || no "(H20c) backlog.md changed despite the refusal — the check must run BEFORE either rename"
[ ! -f "$FIX/oc/memory/backlog-done.md" ] \
  && ok "(H20c) no archive file was created by the refused run" \
  || no "(H20c) backlog-done.md exists after a refused run — something was written"

# THE CONTROL, and it is the assertion that stops the refusal being a blanket 'never archive near a
# fence': a GENUINE fenced recipe inside one entry must still travel whole with that entry. An earlier
# attempt at this fix inside `entry_block` traded the over-cover for exactly this under-cover, splitting
# the recipe at its own flush-left `#` comment — the control caught it, which is why it is here.
mkdir -p "$FIX/ocok/memory"
{ printf -- '- [x] B-solo — FIXED abc1234\n'
  printf -- '  recipe:\n'
  printf '```\n'
  printf -- '# restart cleanly before profiling\n'
  printf -- 'systemctl restart workers\n'
  printf '```\n'
  printf -- '  and that is all\n'
  printf -- '- [ ] B-next OPEN\n'; } > "$FIX/ocok/memory/backlog.md"
( cd "$FIX/ocok" && git init -q . && printf 'zuvo/\n' > .gitignore ) >/dev/null 2>&1
ocok_out="$(python3 "$ARCHIVE_PY" archive --repo "$FIX/ocok" 2>&1)"; ocok_rc=$?
ocok_left="$(tr -d ' \n' < "$FIX/ocok/memory/backlog.md")"
if [ "$ocok_rc" -eq 0 ] && [ "$ocok_left" = "-[]B-nextOPEN" ]; then
  ok "(H20c) CONTROL: a genuine fenced recipe still travels whole with its entry — only B-next remains, so the refusal is not a blanket ban near fences"
else
  no "(H20c) CONTROL: rc=$ocok_rc and backlog.md left '$ocok_left' (expected '-[]B-nextOPEN'); archive said '$(printf '%s' "$ocok_out" | head -1)' — the refusal is now rejecting a legitimate fenced block, which is the under-cover direction"
fi

# --- H21 THE GATED ARCHIVE (AC8): D3's remedy, and its default ------------------------------------
# D3, measured: `cmd_archive` reaches the file through `classify()`, which walks checkbox entries
# only, so NO command could archive a `## B-id` heading entry at all — a heading verified resolved had
# a disposition nothing could perform, for the 24 marker-carrying headings in this repo and 170-216
# fleet-wide. The remedy is env-gated because `install.sh` globs scripts/zuvo-home/* into the
# machine-global ~/.zuvo/ and `append-runlog:288` runs `archive --repo "$PWD"` at the end of EVERY
# skill run in EVERY repo: an ungated version would rewrite tracked files under `Lock` in 88 checkouts
# the moment it was installed.
#
# The fixture carries all four shapes the AC asks for: a resolved heading with no children, a resolved
# heading with 12 children of which 3 are open, a resolved flush-left checkbox, and four open sibling
# checkboxes that must not move whatever happens.
# ONE generator, parametrised by how many of the parent's children are already ticked, because of a
# PRE-EXISTING defect this fixture walked straight into and which is NOT this task's to fix: for a
# bullet-shaped start entry `entry_block` terminates at the next FLUSH-LEFT bullet (`_BULLET_START_RE`
# is anchored at column 0), so an INDENTED ticked child's block swallows every indented child after it.
# Two such children therefore produce overlapping move ranges, and `cmd_archive`'s line-accounting
# check then refuses the whole run — measured, reported as a finding, and asserted below as the SAFE
# property it is (nothing written). g1 (nine ticked children) is the AC8 shape; g2 (one) is the shape
# the default-off and env-value assertions need, because those have to compare a run that DID write.
mkg(){
  rm -rf "$1"; mkdir -p "$1/memory"
  { printf '# Tech Debt Backlog\n\n## Open\n\n'
    printf '## B-g-clean — DONE b9767b6a\n'
    printf -- '- **Closed:** the resolved heading with no children at all\n'
    printf -- '- **Note:** a second flush-left continuation bullet, part of the same entry\n\n'
    printf '## B-g-kids — DONE deadbee\n'
    printf -- '- **Closed:** the resolved parent whose follow-ups are not resolved\n'
    for n in 01 02 03; do printf '  - [ ] B-g-k%s open follow-up %s\n' "$n" "$n"; done
    for n in $(seq 4 $((3 + $2))); do
      printf '  - [x] B-g-k%02d [FIXED cafe0%02d] finished child %d\n' "$n" "$n" "$n"; done
    printf -- '- [x] B-g-cb [FIXED cafe123] src/one.ts the flush-left checkbox that moves either way\n'
    for n in 1 2 3 4; do printf -- '- [ ] B-g-s%s src/s%s.ts open sibling %s\n' "$n" "$n" "$n"; done
  } > "$1/memory/backlog.md"
}
mkg1(){ mkg "$1" 9; }      # 12 children, 3 open — AC8's fixture
mkg2(){ mkg "$1" 1; }      #  4 children, 3 open — one ticked child, so no overlapping ranges

# VACUITY GUARD: the fixture must really carry the four shapes, or every assertion below holds
# trivially. Counts are read out of the fixture, not asserted as prose.
mkg1 "$FIX/g1"
g1_shape="$(pyb "
t = open('$FIX/g1/memory/backlog.md').read()
lines = t.splitlines(keepends=True)
hs = {e.ident: e for e in zb.iter_entries(t, kinds=(zb.KIND_HEADING,))}
kids = hs['B-g-kids']
import re
IND = re.compile(r'^\s+[-*]\s*\[')
end = __import__('zuvo_backlog_block').entry_block(lines, kids.lineno - 1)
children = [ln for ln in lines[kids.lineno:end] if IND.match(ln)]
sibs = [e for e in zb.iter_entries(t, kinds=(zb.KIND_CHECKBOX,))
        if e.status == 'open' and not e.raw.startswith(' ')]
print('%d %s %s %d %d %d' % (len(hs), hs['B-g-clean'].status, kids.status, len(children),
                             sum(1 for ln in children if '[ ]' in ln), len(sibs)))")"
echo "  ... g1: $g1_shape  (headings, clean.status, kids.status, children, open children, flush-left open)"
case "$g1_shape" in
  "2 done done 12 3 4") ok "(H21) vacuity guard: g1 holds 2 resolved heading entries, 12 children of which 3 open, and 4 flush-left open siblings" ;;
  *) no "(H21) g1 is not the shape AC8 describes: '$g1_shape', expected '2 done done 12 3 4' — every assertion below would measure a different fixture" ;;
esac

# No `arch()` wrapper that returns the rc in a variable: the call site would be `$(arch ...)`, a
# SUBSHELL, so the assignment would be discarded and `set -u` would then abort the whole file on the
# unbound read — the same subshell boundary that makes command_not_found_handle unable to count.
# Each run is therefore inline, with `$?` read on the very next command.
has(){ grep -q -- "$2" "$1"; }

# THE GATE OFF, first, because it is the fleet default and the thing that must not change: not one
# heading line may leave the file.
mkg2 "$FIX/g-off"
off_out="$(python3 "$ARCHIVE_PY" archive --repo "$FIX/g-off" 2>&1)"; off_rc=$?
echo "  ... gate OFF: rc=$off_rc $(printf '%s' "$off_out" | head -1)"
case "$off_out" in
  *"moved 2 entries"*) ok "(H21/AC8) gate OFF: the 2 CHECKBOX entries move (the flush-left one and the ticked child) — the pre-existing behaviour, unchanged" ;;
  *) no "(H21/AC8) gate OFF moved a different set: $(printf '%s' "$off_out" | head -1)" ;;
esac
has "$FIX/g-off/memory/backlog.md" '## B-g-clean' && has "$FIX/g-off/memory/backlog.md" '## B-g-kids' \
  && ok "(H21/AC8) gate OFF: BOTH resolved heading entries are still in backlog.md — the gated half archived nothing" \
  || no "(H21/AC8) gate OFF: a heading entry left backlog.md without the env var being set — the fleet-wide default is not off"
if [ -f "$FIX/g-off/memory/backlog-done.md" ] && ! grep -q '^## B-g-' "$FIX/g-off/memory/backlog-done.md"; then
  ok "(H21/AC8) gate OFF: no heading line reached backlog-done.md either"; else
  no "(H21/AC8) gate OFF: backlog-done.md carries a heading line: $(grep -m1 '^## B-g-' "$FIX/g-off/memory/backlog-done.md" 2>&1)"; fi
case "$off_out" in
  *HELD*) no "(H21/AC8) gate OFF printed a HELD line about a heading entry: $(printf '%s' "$off_out" | grep HELD)" ;;
  *) ok "(H21/AC8) gate OFF says nothing about heading entries at all — no report, no write" ;;
esac

# THE PRE-EXISTING OVERLAP, asserted as the safe property and not as the defect: on g1 the nine ticked
# children produce overlapping block ranges (see `mkg`), and the archiver must then write NOTHING and
# exit non-zero rather than corrupt the file. It is reported as a finding for its own fix; what this
# pins is that the failure stays FAIL-CLOSED, which is what makes leaving it to that fix safe.
mkg1 "$FIX/g-ovl"
ovl_before="$(python3 -c "
import hashlib
print(hashlib.sha256(open('$FIX/g-ovl/memory/backlog.md','rb').read()).hexdigest())")"
ovl_out="$(python3 "$ARCHIVE_PY" archive --repo "$FIX/g-ovl" 2>&1)"; ovl_rc=$?
ovl_after="$(python3 -c "
import hashlib
print(hashlib.sha256(open('$FIX/g-ovl/memory/backlog.md','rb').read()).hexdigest())")"
echo "  ... overlapping indented children, gate OFF: rc=$ovl_rc $(printf '%s' "$ovl_out" | head -1)"
if [ "$ovl_rc" -ne 0 ] && [ "$ovl_before" = "$ovl_after" ] && [ ! -f "$FIX/g-ovl/memory/backlog-done.md" ]; then
  ok "(H21/PRE-EXISTING) two indented ticked children overlap, and the archiver refuses fail-closed: rc=$ovl_rc, backlog.md byte-identical, no archive created"; else
  no "(H21/PRE-EXISTING) the overlapping-range case is no longer fail-closed (rc=$ovl_rc, hash changed: $([ "$ovl_before" != "$ovl_after" ] && echo yes || echo no)) — if the block rule was fixed, drop this assertion and the mkg note with it"; fi

# THE GATE ON: heading 1 and the checkbox move, heading 2 is HELD with child_open == 3, the four
# siblings stay open, and heading 2's block keeps all twelve children.
mkg1 "$FIX/g-on"
on_out="$(env ZUVO_BACKLOG_HEADING_ARCHIVE=1 python3 "$ARCHIVE_PY" archive --repo "$FIX/g-on" 2>&1)"; on_rc=$?
echo "  ... gate ON: rc=$on_rc"
printf '%s\n' "$on_out" | sed 's/^/      /'
case "$on_out" in
  *"moved 2 entries"*) ok "(H21/AC8) gate ON: exactly 2 entries move — the childless resolved heading and the flush-left checkbox" ;;
  *) no "(H21/AC8) gate ON moved: $(printf '%s' "$on_out" | head -1)" ;;
esac
case "$on_out" in
  *"B-g-kids (child_open=3"*) ok "(H21/AC8) gate ON: B-g-kids is HELD and the report names child_open=3 — A7's live-sub-item rule, one level up" ;;
  *) no "(H21/AC8) gate ON: no 'B-g-kids (child_open=3' in the HELD report: $(printf '%s' "$on_out" | grep -i held)" ;;
esac
[ "$on_rc" -eq 0 ] && ok "(H21/AC8) gate ON exits 0" || no "(H21/AC8) gate ON exited $on_rc"
has "$FIX/g-on/memory/backlog.md" '## B-g-kids' \
  && ok "(H21/AC8) gate ON: the HELD heading is still in backlog.md" \
  || no "(H21/AC8) gate ON: the HELD heading was archived anyway"
grep -q '^## B-g-clean' "$FIX/g-on/memory/backlog.md" \
  && no "(H21/AC8) gate ON: the resolved childless heading did NOT leave backlog.md" \
  || ok "(H21/AC8) gate ON: the resolved childless heading left backlog.md"
# its BLOCK, not its heading line: the two continuation bullets must travel with it, and neither may
# stay behind (the split-entry failure a line-count conservation check cannot see).
g1_left="$(grep -c 'the resolved heading with no children\|a second flush-left continuation bullet' "$FIX/g-on/memory/backlog.md" || true)"
g1_gone="$(grep -c 'the resolved heading with no children\|a second flush-left continuation bullet' "$FIX/g-on/memory/backlog-done.md" || true)"
[ "$g1_left" = "0" ] && [ "$g1_gone" = "2" ] \
  && ok "(H21/AC8) gate ON: both of its continuation bullets moved WITH it (0 left behind, 2 in the archive)" \
  || no "(H21/AC8) gate ON: the block was split — $g1_left continuation line(s) left in backlog.md, $g1_gone in the archive"
kids_left="$(grep -c '^  - \[' "$FIX/g-on/memory/backlog.md" || true)"
[ "$kids_left" = "12" ] \
  && ok "(H21/AC8) gate ON: all 12 of the HELD parent's children are still under it — a held parent is not dismantled" \
  || no "(H21/AC8) gate ON: the HELD parent kept only $kids_left of its 12 children"
sibs_left="$(grep -c '^- \[ \] B-g-s' "$FIX/g-on/memory/backlog.md" || true)"
[ "$sibs_left" = "4" ] \
  && ok "(H21/AC8) gate ON: the four open sibling checkboxes are untouched" \
  || no "(H21/AC8) gate ON: only $sibs_left of the 4 open siblings are left — the heading's block swept siblings out"

# AC4′ BEHAVIOURAL: exactly "1" switches it on. An inherited "0", "2", "true" or an empty value must
# be byte-identical to unset — a write path that runs in every repo is not the place for a tolerant
# truthiness parse, and "0 means on" is the shape in which a gate silently stops being one.
sha2(){ python3 -c "
import hashlib, sys
h = hashlib.sha256()
for p in sys.argv[1:]:
    try:
        h.update(open(p, 'rb').read())
    except FileNotFoundError:
        h.update(b'<absent>')
print(h.hexdigest())" "$1/memory/backlog.md" "$1/memory/backlog-done.md"; }
mkg2 "$FIX/g2-on"
env ZUVO_BACKLOG_HEADING_ARCHIVE=1 python3 "$ARCHIVE_PY" archive --repo "$FIX/g2-on" >/dev/null 2>&1
base_sha="$(sha2 "$FIX/g-off")"
on_sha="$(sha2 "$FIX/g2-on")"
[ "$base_sha" != "$on_sha" ] \
  && ok "(H21/AC4′) vacuity guard: on the SAME fixture the gated and ungated runs produce different bytes" \
  || no "(H21/AC4′) gated and ungated produced IDENTICAL bytes on g2 — every env-value assertion below is vacuous"
for v in "" 0 2 true 11 " 1"; do
  d="$FIX/g-v$(printf '%s' "$v" | tr -d ' ' | sed 's/^$/empty/')"
  mkg2 "$d"
  v_out="$(env ZUVO_BACKLOG_HEADING_ARCHIVE="$v" python3 "$ARCHIVE_PY" archive --repo "$d" 2>&1)"
  if [ "$(sha2 "$d")" = "$base_sha" ]; then
    ok "(H21/AC4′) $HEAD_ARCH_ENV='$v' is byte-identical to unset"; else
    no "(H21/AC4′) $HEAD_ARCH_ENV='$v' changed the archive: $(printf '%s' "$v_out" | head -1)"; fi
done

# --- H21b the HOLD mutant -------------------------------------------------------------------------
out="$(mkmut nohold 2>&1)"
if [ -n "$out" ]; then no "(H21b) the nohold mutant did not build: $out"; else
  mkg1 "$FIX/g-nohold"
  nh="$(env ZUVO_BACKLOG_HEADING_ARCHIVE=1 python3 "$FIX/mut-nohold/backlog-archive.py" \
        archive --repo "$FIX/g-nohold" 2>&1)"
  if grep -q '^  - \[ \] B-g-k01' "$FIX/g-nohold/memory/backlog.md"; then
    no "(H21b) nohold left the open children in backlog.md ($(printf '%s' "$nh" | head -1)) — the hold assertion pins nothing"; else
    ok "(H21b) nohold: the resolved parent archives over its 3 live follow-ups ($(printf '%s' "$nh" | head -1)) — AC8's HELD assertion is load-bearing"; fi
fi

# --- H21c the GATE mutant, behaviourally: ungated means the fleet default writes ------------------
out="$(mkmut ungated 2>&1)"
if [ -n "$out" ]; then no "(H21c) the ungated mutant did not build: $out"; else
  mkg1 "$FIX/g-ungated"
  ug="$(python3 "$FIX/mut-ungated/backlog-archive.py" archive --repo "$FIX/g-ungated" 2>&1)"
  if grep -q '^## B-g-clean' "$FIX/g-ungated/memory/backlog.md"; then
    no "(H21c) ungated still left the heading in place ($(printf '%s' "$ug" | head -1)) — the default-off assertions pin nothing"; else
    ok "(H21c) ungated: with $HEAD_ARCH_ENV UNSET the heading is archived anyway ($(printf '%s' "$ug" | head -1)) — which is what AC4′/AC8's default-off assertions catch, and what an install would have done in 88 checkouts" ; fi
fi

# --- H22 AC6b: the ARCHIVE half of the attribution proof, on the GENERATED fixture ----------------
# Task 3 could only measure attribution READ-ONLY, and the measurement it produced is exactly why this
# group asserts attribution and not occurrence: a LEVEL-ONLY boundary left `cross` at 0 while `owned`
# rose 36 -> 38 — every line still landed exactly once, in the wrong entry. `cmd_archive`'s own
# conservation check is `if ln not in new_archive`: PRESENCE, not multiplicity, and not attribution.
# So this archives the fixture that was GENERATED FROM the real backlog (H18's, so the shape is the
# measured one and not a hand-written one that indents its children), and then asserts per ENTRY that
# the bytes of each moved entry's block are the bytes the SAME id owns in the archive, with line
# multiplicity compared as a Counter over both files.
ATPROBE="$FIX/attribprobe.py"
cat > "$ATPROBE" <<'PYEOF'
"""Conservation AND ATTRIBUTION across one archive move. Prints ONE line, always exit 0.

Usage: attribprobe.py <archive.py> <before.md> <after-backlog.md> <after-done.md>

    MOVED <n> STAYED <n> BLOCKS <ok|bad:…> MULT <ok|bad:…> EXTRA <ok|bad:…> OPENSIBS <n>/<n>
    IDS moved=<…> held=<…>

BLOCKS is the attribution assertion: for every entry the move took OUT of backlog.md, the bytes of its
block in the source must equal the bytes of the block the SAME id owns in backlog-done.md — and for
every entry that stayed, the bytes it owns in the open file must be unchanged. A line that exists
somewhere in the archive but under another entry's heading fails here and passes an occurrence check.
The block is measured on BOTH sides by the module under test, so a mutant's own boundary rule is used
for both — which is deliberate: this number is about where lines LANDED, and the sibling count below
is what catches a boundary that swept unrelated entries along.

MULT compares line MULTIPLICITY (a Counter, never a set) of every non-blank line between source and
source+destination: a block appended twice fails although every line is still "present". Blank lines
are excluded because the archiver inserts its own separators. EXTRA is what the move ADDED: only its
own section headings may appear. OPENSIBS counts flush-left, still-open checkbox lines before / after.
"""
import collections
import importlib.util
import os
import re
import sys
from importlib.machinery import SourceFileLoader

apath, before_p, open_p, done_p = sys.argv[1:5]
sys.path.insert(0, os.path.dirname(os.path.realpath(apath)))
spec = importlib.util.spec_from_file_location("ba_at", apath, loader=SourceFileLoader("ba_at", apath))
BA = importlib.util.module_from_spec(spec)
sys.modules["ba_at"] = BA
spec.loader.exec_module(BA)
zb = BA.zb
SIB = re.compile(r"^[-*]\s*\[\s\]")


def read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except FileNotFoundError:
        return ""


def blocks(text):
    """{id: [block bytes, …]} for every entry in `text`. A LIST per id, so an entry that landed twice
    is visible instead of overwriting itself."""
    lines = text.splitlines(keepends=True)
    out = {}
    for e in zb.iter_entries(text, kinds=BA.LOOKUP_KINDS):
        end = BA.entry_block(lines, e.lineno - 1)
        out.setdefault(e.ident or e.key, []).append("".join(lines[e.lineno - 1:end]))
    return out


before, after_open, after_done = read(before_p), read(open_p), read(done_p)
b_blk, o_blk, d_blk = blocks(before), blocks(after_open), blocks(after_done)
moved = sorted(k for k in b_blk if k not in o_blk)
stayed = sorted(k for k in b_blk if k in o_blk)
bad = [k for k in moved if d_blk.get(k) != b_blk[k]]
bad += [k + "(stayed)" for k in stayed if o_blk.get(k) != b_blk[k]]
cb = collections.Counter(ln for ln in before.splitlines(keepends=True) if ln.strip())
ca = collections.Counter(ln for ln in (after_open + after_done).splitlines(keepends=True) if ln.strip())
mult = [ln for ln, n in cb.items() if ca.get(ln, 0) != n]
extra = [ln for ln, n in ca.items()
         if n > cb.get(ln, 0) and not ln.startswith("## Archived from backlog.md on")]
print("MOVED %d STAYED %d BLOCKS %s MULT %s EXTRA %s OPENSIBS %d/%d"
      % (len(moved), len(stayed),
         "ok" if not bad else "bad:" + ",".join(bad[:4]),
         "ok" if not mult else "bad:" + repr(mult[0])[:70].replace(" ", "\u00b7"),
         "ok" if not extra else "bad:" + repr(extra[0])[:70].replace(" ", "\u00b7"),
         sum(1 for ln in before.splitlines() if SIB.match(ln)),
         sum(1 for ln in after_open.splitlines() if SIB.match(ln))))
print("IDS moved=%s held=%s" % (",".join(moved) or "-", ",".join(stayed) or "-"))
PYEOF

mkac6b(){ rm -rf "$1"; mkdir -p "$1/memory"; cp "$FIXBL" "$1/memory/backlog.md"; }
mkac6b "$FIX/ac6b"
cp "$FIXBL" "$FIX/ac6b-before.md"
ac_out="$(env ZUVO_BACKLOG_HEADING_ARCHIVE=1 python3 "$ARCHIVE_PY" archive --repo "$FIX/ac6b" 2>&1)"
ac_rc=$?
echo "  ... AC6b archive (rc=$ac_rc): $(printf '%s' "$ac_out" | head -2 | tr '\n' ' ')"
ac_probe="$(python3 "$ATPROBE" "$ARCHIVE_PY" "$FIX/ac6b-before.md" \
            "$FIX/ac6b/memory/backlog.md" "$FIX/ac6b/memory/backlog-done.md" 2>&1)"
printf '%s\n' "$ac_probe" | sed 's/^/      /'
set -- $ac_probe
ac_moved="$2"; ac_blocks="$6"; ac_mult="$8"; ac_extra="${10}"; ac_sibs="${12}"
[ "$ac_rc" -eq 0 ] && ok "(H22/AC6b) the gated archive of the generated fixture exits 0" \
  || no "(H22/AC6b) the gated archive exited $ac_rc: $ac_out"
[ "${ac_moved:-0}" -ge 1 ] 2>/dev/null \
  && ok "(H22/AC6b) vacuity guard: $ac_moved entries actually moved, so the assertions below have a subject" \
  || no "(H22/AC6b) nothing moved out of the generated fixture ('$ac_probe') — every assertion below would hold trivially"
[ "$ac_blocks" = "ok" ] \
  && ok "(H22/AC6b) every moved entry's block is byte-identical to the block the SAME id owns in backlog-done.md, and every entry that stayed is unchanged — ATTRIBUTION, not occurrence" \
  || no "(H22/AC6b) a moved entry's block is not what its id owns in the archive: BLOCKS=$ac_blocks"
[ "$ac_mult" = "ok" ] \
  && ok "(H22/AC6b) every non-blank source line occurs EXACTLY once across backlog.md + backlog-done.md (Counter, not set — a duplicated block fails)" \
  || no "(H22/AC6b) line multiplicity changed: MULT=$ac_mult"
[ "$ac_extra" = "ok" ] \
  && ok "(H22/AC6b) the only lines the move ADDED are the archiver's own section headings" \
  || no "(H22/AC6b) the move invented a line: EXTRA=$ac_extra"
[ "$ac_sibs" = "6/6" ] \
  && ok "(H22/AC6b) all 6 flush-left open checkboxes are still open in backlog.md ($ac_sibs) — the four from the real slice and the two fence-case siblings" \
  || no "(H22/AC6b) open flush-left checkboxes before/after: $ac_sibs — the heading blocks carried siblings out of the file"
# The held case is part of the expected SET, not an accident of the fixture: B-FENCED carries an
# indented open checkbox inside its own sub-entry, so it must stay — and so must the sub-entry, which
# sits inside a resolved heading's block and therefore travels with it or waits with it.
case "$ac_probe" in
  *"held="*B-FENCED*) ok "(H22/AC6b) B-FENCED (an indented open child inside its sub-entry) is among the entries that STAYED" ;;
  *) no "(H22/AC6b) B-FENCED did not stay: $(printf '%s' "$ac_probe" | tail -1)" ;;
esac
case "$ac_probe" in
  *"moved="*B-LATER*) ok "(H22/AC6b) B-LATER (resolved, one line, no children) did move — the fixture exercises both outcomes" ;;
  *) no "(H22/AC6b) B-LATER did not move: $(printf '%s' "$ac_probe" | tail -1)" ;;
esac

# THE MUTATION PROOF for AC6b, and it is the one Task 3 identified: a LEVEL-ONLY boundary keeps every
# line exactly once and still mis-attributes. Reusing H18's `levelonly` block mutant, whose archiver
# is byte-identical apart from the sibling terminator, the four independent open entries between the
# anchor and the next `##` are swept into the anchor's block and archived WITH it — while MULT stays
# ok, which is precisely why the sibling count is asserted separately.
out="$(mkblk levelonly)"
if [ -n "$out" ]; then no "(H22b) the levelonly mutant did not build: $out"; else
  mkac6b "$FIX/ac6b-lo"
  lo_run="$(env ZUVO_BACKLOG_HEADING_ARCHIVE=1 python3 "$(blk levelonly)" \
            archive --repo "$FIX/ac6b-lo" 2>&1)"
  lo_probe="$(python3 "$ATPROBE" "$(blk levelonly)" "$FIX/ac6b-before.md" \
              "$FIX/ac6b-lo/memory/backlog.md" "$FIX/ac6b-lo/memory/backlog-done.md" 2>&1)"
  echo "  ... levelonly: $(printf '%s' "$lo_run" | head -1)"
  echo "  ...            $(printf '%s' "$lo_probe" | head -1)"
  case "$lo_probe" in
    *"OPENSIBS 6/6"*) no "(H22b) levelonly still leaves all 6 open siblings in place — AC6b's sibling assertion pins nothing: $lo_probe" ;;
    *"OPENSIBS 6/"*) ok "(H22b) levelonly archives open sibling entries with the heading ($(printf '%s' "$lo_probe" | sed -n 's/.*OPENSIBS /OPENSIBS /p')) — and AC6b catches it where a line-level conservation check cannot" ;;
    *) no "(H22b) the levelonly probe did not report a sibling count: $lo_probe" ;;
  esac
fi

# --- H23 THE ADVERSARIAL ROUND'S FIXES: the mint's line endings, a refused mint, the open-child
# --- notion, fences, the order in classify(), and the two gate-conditional counts ------------------
# Every one of these was MEASURED on this code before it was changed, and each assertion below failed
# on the pre-fix module — the RED output is quoted in zuvo/proofs/task-4-report.md.

# F1 THE ANCHOR MUST NOT EAT A LINE ENDING. `\s*` matches `\n`, so a body-less or trailing-space
# ticked entry had its minted id written onto a NEW LINE: `- [x]` left with no id and an orphaned line
# holding the id. That is corruption on the archive write path, and it is PRE-EXISTING — the legacy
# expression this replaced (`^(\s*[-*]\s*\[[ xX]\]\s*)`) matches the newline identically (measured),
# so the extraction into `mint_into` is what made it visible, not what caused it.
# WHAT WOULD MAKE THIS FAIL: any whitespace class in the anchor that admits \r or \n — the `mintvspace`
# mutant restores exactly that and is asserted below.
f1="$(pyb "
import zuvo_backlog_mint as zm
M = 'B-A20260928-abcdef'
SHAPES = ['- [x]\n', '- [x]   \n', '  - [x]\r\n', '- [x] B-x body\n', '## B-h — DONE\n',
          '  - [x]\t\n', '* [X]\n']
bad, ate = [], []
for s in SHAPES:
    out = BA.mint_into(s, M)
    if out is None or M not in out.splitlines()[0] or out.count('\n') != s.count('\n'):
        bad.append(s)
    m = zm._MINT_ANCHOR_RE.match(s)
    if m is not None and ('\n' in m.group(0) or '\r' in m.group(0)):
        ate.append(s)
print('%d %s %s' % (len(SHAPES), ','.join(repr(b) for b in bad) or '-',
                    ','.join(repr(a) for a in ate) or '-'))")"
echo "  ... F1 mint vs line endings: $f1  (shapes, id-not-on-first-line, anchor-ate-a-terminator)"
case "$f1" in
  "7 - -") ok "(H23/F1) all 7 shapes mint on the SAME line, and the anchor consumes no \\r or \\n — a body-less or trailing-space '- [x]' is no longer split into two lines" ;;
  *) no "(H23/F1) the mint wrote an id onto a new line, or the anchor ate a terminator: $f1" ;;
esac

# F2 A MINT THAT DOES NOT HAPPEN MUST NOT LET THE ENTRY MOVE. `mint_into` returning the line unchanged
# is D2 arriving through another door: the entry is archived with NO id, permanently unfindable by
# `lookup` — the exact failure this whole PR exists to end.
if [ "$(pyb "print(BA.mint_into('no anchor here at all\n', 'B-A20260928-abcdef') is None)")" = "True" ]; then
  ok "(H23/F2) mint_into REFUSES (returns None) on a line with no anchor, instead of returning it unchanged"; else
  no "(H23/F2) mint_into returned $(pyb "print(repr(BA.mint_into('no anchor here at all\n', 'B-A20260928-abcdef')))") for an unanchored line — a silent no-op the archiver would move anyway"; fi
# …and the write path must act on that refusal. The only way to reach the branch is a mint that cannot
# match, which is what the `mintmiss` mutant makes of the anchor — so the mutant IS the behavioural
# proof, not merely a sensitivity check.
out="$(mkmut mintmiss 2>&1)"
if [ -n "$out" ]; then no "(H23/F2) the mintmiss mutant did not build: $out"; else
  mkdir -p "$FIX/f2/memory"
  { printf '# Tech Debt Backlog\n\n## Open\n\n'
    printf -- '- [x] [FIXED deadbee] src/one.ts a resolved entry that carries NO id\n'
    printf -- '- [ ] B-f2-open src/two.ts an open entry so the file is not single-entry\n'
  } > "$FIX/f2/memory/backlog.md"
  f2_sha="$(python3 -c "
import hashlib
print(hashlib.sha256(open('$FIX/f2/memory/backlog.md','rb').read()).hexdigest())")"
  f2_out="$(python3 "$FIX/mut-mintmiss/backlog-archive.py" archive --repo "$FIX/f2" 2>&1)"; f2_rc=$?
  f2_after="$(python3 -c "
import hashlib
print(hashlib.sha256(open('$FIX/f2/memory/backlog.md','rb').read()).hexdigest())")"
  echo "  ... F2 mintmiss: rc=$f2_rc $(printf '%s' "$f2_out" | head -1)"
  if [ "$f2_rc" -ne 0 ] && [ "$f2_sha" = "$f2_after" ] && [ ! -f "$FIX/f2/memory/backlog-done.md" ]; then
    ok "(H23/F2) with the mint unable to match, the archiver REFUSES fail-closed (rc=$f2_rc, backlog.md byte-identical, no archive written) — an id-less entry can no longer reach the append"; else
    no "(H23/F2) the archiver moved an entry whose mint failed (rc=$f2_rc, file changed: $([ "$f2_sha" != "$f2_after" ] && echo yes || echo no), archive created: $([ -f "$FIX/f2/memory/backlog-done.md" ] && echo yes || echo no)) — it would be unfindable by lookup for ever"; fi
  # control on the SAME fixture with the real module: the id-less entry DOES move, and with an id.
  mkdir -p "$FIX/f2ok/memory"; cp "$FIX/f2/memory/backlog.md" "$FIX/f2ok/memory/backlog.md"
  python3 "$ARCHIVE_PY" archive --repo "$FIX/f2ok" >/dev/null 2>&1
  if grep -q '^- \[x\] B-A[0-9]\{8\}-' "$FIX/f2ok/memory/backlog-done.md" 2>/dev/null; then
    ok "(H23/F2) control: the unmutated module mints an id for that same entry and archives it — the refusal above is the mutant's, not the fixture's"; else
    no "(H23/F2) control: the unmutated module did not mint+archive the id-less entry: $(head -3 "$FIX/f2ok/memory/backlog-done.md" 2>&1 | tr '\n' ' ')"; fi
fi

# F3 + F5 WHAT COUNTS AS AN OPEN FOLLOW-UP. `\[\s\]` requires EXACTLY one whitespace character, so
# `- [  ]` and `- []` read as "no open child" and the hold rule fails OPEN — the dangerous direction:
# a resolved parent archives over live follow-ups. And an indented TICKED child carrying `[ ]` later in
# its line (`- [x] fixed | [ ] OPEN follow-up`, the shape the dedup suite's A7 fixture uses) was not
# counted either, although the CHECKBOX hold path holds exactly that text on its `'[ ]' in body` test.
# WHAT WOULD MAKE THIS FAIL: narrowing the box class back to a single whitespace character, or matching
# the open box only at the head of the child line (the `boxnarrow` / `boxhead` mutants below).
f3="$(pyb "
import zuvo_backlog_heading as zh
CHILDREN = ['  - [ ] one space', '  - [  ] two spaces', '  - [\t] a tab', '  * [ ] star bullet',
            '  - []  empty box', '  -[ ] no space after the dash',
            '  - [x] B-c [FIXED a1] fixed the parser | [ ] OPEN follow-up: add a test']
NOT = ['  - [x] B-d [FIXED a2] a finished child', '  - **Closed:** prose, not a child',
       '  a plain indented line', '- [ ] B-flush a FLUSH-LEFT sibling, not a child']
rows = []
for kids in ([c] for c in CHILDREN):
    t = '## B-h — DONE aaa\n' + '\n'.join(kids) + '\n'
    L = t.splitlines(keepends=True)
    e = list(zb.iter_entries(t, kinds=(zb.KIND_HEADING,)))[0]
    rows.append(zh.open_children(L, e))
neg = []
for c in NOT:
    t = '## B-h — DONE aaa\n' + c + '\n'
    L = t.splitlines(keepends=True)
    e = list(zb.iter_entries(t, kinds=(zb.KIND_HEADING,)))[0]
    if zh.open_children(L, e):
        neg.append(c)
print('%d/%d %s' % (sum(1 for r in rows if r == 1), len(CHILDREN),
                    ','.join(repr(n) for n in neg) or '-'))")"
echo "  ... F3 open-child dialects: $f3  (counted/total, false positives)"
case "$f3" in
  "7/7 -") ok "(H23/F3) every spelling of an open box counts as an open follow-up — one space, two, a tab, '[]', a star bullet, no space after the dash, and an open marker in a TICKED child's tail — while a finished child, prose and a flush-left sibling do not" ;;
  *) no "(H23/F3) the open-child notion misses a real open follow-up, or invents one: $f3" ;;
esac
# The DIALECT SPLIT the reviewers named: the checkbox hold path tests the literal substring '[ ]' in
# the entry's body. The heading path must be a SUPERSET of it — never stricter — or the same child gets
# different verdicts depending on which dialect found it. Asserted as the relation, because the
# checkbox test itself cannot change: it is the fleet-wide default path (AC4′).
if [ "$(pyb "
import zuvo_backlog_heading as zh
TEXTS = ['- [x] a [ ] b', '- [ ] c', '- [x] done [ ]', '- [x] plain done', '- [x] [  ] wide box']
bad = [t for t in TEXTS if ('[ ]' in t) and not zh.is_open_child('  ' + t)]
print(','.join(repr(b) for b in bad) or '-')")" = "-" ]; then
  ok "(H23/F3) the heading path's open-child test is a SUPERSET of the checkbox path's '[ ]' substring test — it can never hold less"; else
  no "(H23/F3) the heading path misses a child the checkbox path would hold: $(pyb "
import zuvo_backlog_heading as zh
TEXTS = ['- [x] a [ ] b', '- [ ] c', '- [x] done [ ]', '- [x] plain done', '- [x] [  ] wide box']
print([t for t in TEXTS if ('[ ]' in t) and not zh.is_open_child('  ' + t)])")"; fi

# …and the COUNT is a count, not a boolean: a heading with exactly two open children must be held
# with child_open=2, through the CLI as well as through the function (the HELD line is what an operator
# reads, and it is the only place the number is stated).
mkdir -p "$FIX/f3b/memory"
{ printf '# Tech Debt Backlog\n\n## Open\n\n'
  printf '## B-f3b-two — DONE b9767b6a\n'
  printf -- '- **Closed:** the parent with exactly two live follow-ups\n'
  printf '  - [ ] B-f3b-k1 the first open child\n'
  printf '  - [  ] B-f3b-k2 the second, written with a WIDE box\n'
  printf -- '- [x] B-f3b-cb [FIXED cafe005] src/one.ts an unrelated finished entry\n'
} > "$FIX/f3b/memory/backlog.md"
f3b="$(env ZUVO_BACKLOG_HEADING_ARCHIVE=1 python3 "$ARCHIVE_PY" archive --repo "$FIX/f3b" 2>&1)"
case "$f3b" in
  *"B-f3b-two (child_open=2"*) ok "(H23/F3) a heading with two open children is HELD and the CLI states child_open=2 — one of them written with a wide box, so the count and the dialect are asserted together" ;;
  *) no "(H23/F3) the HELD line does not state child_open=2: $(printf '%s' "$f3b" | grep -i held)" ;;
esac
grep -q '^## B-f3b-two' "$FIX/f3b/memory/backlog.md" \
  && ok "(H23/F3) …and it stayed in backlog.md" \
  || no "(H23/F3) the parent with two open children was archived anyway"

# F4 FENCE AWARENESS, and it is a CONSISTENCY requirement rather than a preference: `entry_block` was
# made fence-aware in Task 3 and this reads the same document, so a checkbox in a documentation sample
# must not be a live child for one and content for the other. Fail-closed if wrong (a heading held for
# ever), which is why it is a WARNING and not a corruption — but two notions of "code block" in one
# module family is the `LOOKUP_KINDS` defect shape.
f4="$(pyb "
import zuvo_backlog_heading as zh
def oc(body):
    t = '## B-h — DONE aaa\n' + body
    L = t.splitlines(keepends=True)
    e = list(zb.iter_entries(t, kinds=(zb.KIND_HEADING,)))[0]
    return zh.open_children(L, e)
print('%d %d %d %d' % (
    oc('\`\`\`\n  - [ ] sample in a code block\n\`\`\`\n'),
    oc('  - [ ] a REAL open child\n'),
    oc('\`\`\`\n  - [ ] fenced\n\`\`\`\n  - [ ] real\n'),
    oc('\`\`\`\n  - [ ] an UNCLOSED fence does not hide it\n')))")"
echo "  ... F4 fence awareness: $f4  (fenced=0, real=1, fenced+real=1, unclosed=1)"
case "$f4" in
  "0 1 1 1") ok "(H23/F4) a checkbox inside a CLOSED fence is content and does not hold the heading, a real child still does, and an UNCLOSED fence hides nothing — the same convention entry_block uses" ;;
  *) no "(H23/F4) open_children and entry_block disagree about what a code block is: $f4" ;;
esac

# F5 THE ORDER IN classify(). `'[ ]' in e.body` was tested BEFORE the `inside` filter, so a ticked
# child carrying an open follow-up inside a resolved heading's block was appended to the HELD list
# while its parent moved and carried it into the archive. A FALSE held is worse than either outcome
# alone: the operator reads it as safe. WHAT WOULD MAKE THIS FAIL: swapping the two checks back, which
# the `orderswap` mutant does.
f5="$(pybg "
t = ('## B-f5-parent — DONE b9767b6a\n'
     '- **Closed:** the parent says it is done\n'
     '  - [x] B-f5-child [FIXED a1] fixed the parser | [ ] OPEN follow-up: add a test\n'
     '- [ ] B-f5-sib src/s.ts an open sibling\n')
marked, unmarked, nested, plan = BA.classify(t)
print('%s|%s|%s' % (','.join(e.ident or e.key for _, e in marked + unmarked) or '-',
                    ';'.join(nested) or '-', plan.total))")"
echo "  ... F5 classify(): $f5  (moving|held|heading entries seen)"
case "$f5" in
  "-|B-f5-parent (child_open=1, open heading(s) inside=0)|1")
    ok "(H23/F5) the parent is HELD for its ticked child's open follow-up, NOTHING moves, and the child is not reported held on its own — no false 'held' over an entry that was being archived" ;;
  *) no "(H23/F5) classify() reported '$f5' — expected the parent HELD with child_open=1, nothing moving, and no separate child label" ;;
esac

# F6 AN OPEN HEADING ID MUST BE PROTECTED. `staying` is built from CHECKBOX entries only, so with the
# gate on the same id could end up in BOTH files with nothing in the checkbox namespace to notice.
# Measured correction to the reported mechanism: `cmd_verify` does NOT catch it and `append-runlog`
# does NOT exit 2, because verify is pinned checkbox-only on both sides — so the consequence is a
# silently inconsistent namespace (lookup answers OPEN … ALSO ARCHIVED), which is the 2026-07
# "archive took the same entry twice" class rather than a blocked run. Both directions are asserted:
# a moving HEADING whose id also names an open heading, and a moving CHECKBOX whose id does.
mkdir -p "$FIX/f6/memory"
{ printf '# Tech Debt Backlog\n\n## Open\n\n'
  printf '## B-f6-dup — DONE b9767b6a\n- **Closed:** the resolved copy\n\n'
  printf '## B-f6-dup an open restatement of the same id\nprose under the open one\n\n'
  printf '## B-f6-two an OPEN heading whose id a ticked checkbox also carries\n\n'
  printf -- '- [x] B-f6-two [FIXED cafe001] src/two.ts the ticked checkbox sharing that id\n'
  printf -- '- [x] B-f6-ok [FIXED cafe002] src/ok.ts an unrelated finished entry\n'
} > "$FIX/f6/memory/backlog.md"
f6_out="$(env ZUVO_BACKLOG_HEADING_ARCHIVE=1 python3 "$ARCHIVE_PY" archive --repo "$FIX/f6" 2>&1)"; f6_rc=$?
echo "  ... F6 gate ON: rc=$f6_rc"
printf '%s\n' "$f6_out" | sed 's/^/      /'
case "$f6_out" in
  *"id does double duty"*) ok "(H23/F6) the archiver reports the shared id instead of moving it" ;;
  *) no "(H23/F6) no double-duty report: $(printf '%s' "$f6_out" | head -1)" ;;
esac
grep -q '^## B-f6-dup — DONE' "$FIX/f6/memory/backlog.md" \
  && ok "(H23/F6) the resolved heading STAYED because an open heading carries its id — no id in both files" \
  || no "(H23/F6) the resolved heading moved while an open heading kept its id: both files now define B-f6-dup"
grep -q '^- \[x\] B-f6-two' "$FIX/f6/memory/backlog.md" \
  && ok "(H23/F6) …and the same protection covers a moving CHECKBOX whose id names an open HEADING" \
  || no "(H23/F6) the ticked checkbox moved while the open heading B-f6-two kept its id"
grep -q 'B-f6-ok' "$FIX/f6/memory/backlog-done.md" 2>/dev/null \
  && ok "(H23/F6) …while the unrelated finished entry still moves — one bad id does not hold back the rest" \
  || no "(H23/F6) the unrelated entry did not move: one shared id blocked the whole run"

# F7 cmd_status's ARITHMETIC. `total` counts checkbox entries only, so once headings are classified
# `still_open = total - marked - unmarked - nested` under-counts and can go negative.
mkdir -p "$FIX/f7/memory"
{ printf '# Tech Debt Backlog\n\n## Open\n\n'
  printf '## B-f7-done — DONE b9767b6a\n- **Closed:** a resolved heading with no children\n\n'
  printf '## B-f7-open a heading that is still waiting\nprose under it\n\n'
  printf -- '- [x] B-f7-cb [FIXED cafe003] src/one.ts a resolved checkbox\n'
  printf -- '- [ ] B-f7-cbo src/two.ts a genuinely open checkbox\n'
} > "$FIX/f7/memory/backlog.md"
st7(){ printf '%s' "$1" | sed -n '1s/.*: \([0-9]*\) resolved.*(\([0-9]*\) with.*, \([0-9]*\) ticked.*; \([0-9]*\) genuinely open).*/\1 \2 \3 \4/p'; }
f7_on="$(st7 "$(env ZUVO_BACKLOG_HEADING_ARCHIVE=1 python3 "$ARCHIVE_PY" status --repo "$FIX/f7" 2>&1)")"
f7_off="$(st7 "$(python3 "$ARCHIVE_PY" status --repo "$FIX/f7" 2>&1)")"
echo "  ... F7 status gate ON='$f7_on' OFF='$f7_off'  (movable, marked, unmarked, genuinely open)"
[ "$f7_on" = "2 2 0 2" ] \
  && ok "(H23/F7) gate ON: 2 movable (the resolved heading and the resolved checkbox) and 2 genuinely open (the open heading and the open checkbox) — the heading entries are in the total" \
  || no "(H23/F7) gate ON status reported '$f7_on', expected '2 2 0 2' — still_open is computed against a checkbox-only total"
[ "$f7_off" = "1 1 0 1" ] \
  && ok "(H23/F7) gate OFF: 1 movable, 1 genuinely open — the heading entries are invisible, exactly as before" \
  || no "(H23/F7) gate OFF status reported '$f7_off', expected '1 1 0 1' — the default path changed"

# F8 THE INSIDE-EXCLUSION ON A **MOVING** PARENT, which H21/AC8 only covered for a HELD one
# (`kids_left=12`). What the exclusion is for, stated the way the spec review measured it: it is
# necessary for the FEATURE to work on real content, NOT for safety. Strip the line and nothing is
# corrupted — the pre-existing `len(kept) != len(lines) - len(moved)` check sees the duplication and
# aborts `internal: line accounting mismatch — nothing written` — so the failure mode is "a resolved
# heading with any ticked child can never be archived", not "the archive is silently wrong".
mkdir -p "$FIX/f8/memory"
mkf8(){
  rm -rf "$1"; mkdir -p "$1/memory"
  { printf '# Tech Debt Backlog\n\n## Open\n\n'
    printf '## B-f8-parent — DONE b9767b6a\n'
    printf -- '- **Closed:** a resolved heading with NO open children but one finished child\n'
    printf '  - [x] B-f8-child [FIXED cafe004] the indented TICKED child that travels with it\n'
    printf -- '- [ ] B-f8-sib src/s.ts a flush-left open sibling that must not move\n'
  } > "$1/memory/backlog.md"
}
mkf8 "$FIX/f8"
f8_out="$(env ZUVO_BACKLOG_HEADING_ARCHIVE=1 python3 "$ARCHIVE_PY" archive --repo "$FIX/f8" 2>&1)"; f8_rc=$?
echo "  ... F8 moving parent with a ticked child: rc=$f8_rc $(printf '%s' "$f8_out" | head -1)"
case "$f8_out" in
  *"moved 1 entries"*) ok "(H23/F8) the parent moves as ONE entry — its ticked child is not a second mover" ;;
  *) no "(H23/F8) gate ON moved: $(printf '%s' "$f8_out" | head -1)" ;;
esac
f8_done="$(grep -c 'B-f8-child' "$FIX/f8/memory/backlog-done.md" 2>/dev/null || true)"
f8_left="$(grep -c 'B-f8-child' "$FIX/f8/memory/backlog.md" 2>/dev/null || true)"
[ "$f8_done" = "1" ] && [ "$f8_left" = "0" ] \
  && ok "(H23/F8) the ticked child's line is in the archive EXACTLY once and gone from backlog.md — no duplicate append inside its parent's block" \
  || no "(H23/F8) the child's line occurs $f8_done time(s) in the archive and $f8_left time(s) in backlog.md — expected 1 and 0"
grep -q 'B-f8-sib' "$FIX/f8/memory/backlog.md" \
  && ok "(H23/F8) …and the flush-left open sibling stayed" \
  || no "(H23/F8) the flush-left open sibling was carried out with the parent"
out="$(mkmut noinside 2>&1)"
if [ -n "$out" ]; then no "(H23b) the noinside mutant did not build: $out"; else
  mkf8 "$FIX/f8-noinside"
  f8m_sha="$(python3 -c "
import hashlib
print(hashlib.sha256(open('$FIX/f8-noinside/memory/backlog.md','rb').read()).hexdigest())")"
  f8m="$(env ZUVO_BACKLOG_HEADING_ARCHIVE=1 python3 "$FIX/mut-noinside/backlog-archive.py" \
         archive --repo "$FIX/f8-noinside" 2>&1)"; f8m_rc=$?
  f8m_after="$(python3 -c "
import hashlib
print(hashlib.sha256(open('$FIX/f8-noinside/memory/backlog.md','rb').read()).hexdigest())")"
  echo "  ... F8 noinside: rc=$f8m_rc $(printf '%s' "$f8m" | head -1)"
  if [ "$f8m_rc" -ne 0 ] && [ "$f8m_sha" = "$f8m_after" ]; then
    ok "(H23b) noinside: without the exclusion the ticked child is counted twice and the run ABORTS fail-closed (rc=$f8m_rc, file byte-identical) — the exclusion is what makes the feature usable on real content, and F8's assertions are load-bearing" ; else
    no "(H23b) noinside produced rc=$f8m_rc with the file $([ "$f8m_sha" = "$f8m_after" ] && echo unchanged || echo CHANGED) — if it wrote, the duplication is NOT caught by the line accounting and this is worse than reported"; fi
fi

# --- H23b the mutants for each of the five fixes above -------------------------------------------
# `mintmiss` is asserted in F2 itself (it is the only way to reach the refusal branch).
mut_probe(){ mp_m="$1"; shift; mp_out="$(mkmut "$mp_m" 2>&1)"
  if [ -n "$mp_out" ]; then printf 'BUILD-FAILED %s' "$mp_out"; return; fi
  # GATED, in a subshell: three of these mutants are in the policy module and its walk returns an
  # empty plan with the gate off, which would make every one of them look like a PASS.
  ( export ZUVO_BACKLOG_HEADING_ARCHIVE=1
    python3 -c "
import sys
sys.path.insert(0, '$FIX'); sys.path.insert(0, '$FIX/mut-$mp_m')
import zuvo_backlog_parse as zb
import zuvo_backlog_heading as zh
from ba import load
BA = load('$FIX/mut-$mp_m/backlog-archive.py')
$1" 2>&1 ); }

# TWO INDEPENDENT LAYERS, which is why this mutant's outcome is REFUSED and not SPLIT: reverting the
# anchor's whitespace classes puts `\n` back inside the match, and `mint_into`'s own invariant ("the
# anchor consumed no \r or \n") then refuses instead of writing the id onto a new line. So the
# corruption needs BOTH to be reverted, and F1's assertion fails on this mutant either way — asserted
# here by re-running F1's own verdict against the mutant, not by arguing it.
got="$(mut_probe mintvspace "
M = 'B-A20260928-abcdef'
SHAPES = ['- [x]\n', '- [x]   \n', '  - [x]\r\n', '- [x] B-x body\n', '## B-h — DONE\n',
          '  - [x]\t\n', '* [X]\n']
def verdict(s):
    o = BA.mint_into(s, M)
    return o is None or M not in o.splitlines()[0] or o.count('\n') != s.count('\n')
bad = [s for s in SHAPES if verdict(s)]
out = BA.mint_into('- [x]\n', M)
state = 'REFUSED' if out is None else ('SPLIT' if M not in out.splitlines()[0] else 'SAME-LINE')
print('%s %d/%d' % (state, len(bad), len(SHAPES)))")"
case "$got" in
  "REFUSED 5/7") ok "(H23b) mintvspace: with \\s* back in the anchor, 5 of the 7 shapes can no longer be minted at all ($got) — the invariant catches what the regex used to let through, and F1's verdict fails on it" ;;
  "SPLIT"*) no "(H23b) mintvspace SPLIT the line ($got) — the terminator invariant is not enforcing, so only the regex stands between this and corruption" ;;
  *) no "(H23b) mintvspace reported '$got', expected 'REFUSED 5/7' — F1 pins nothing" ;;
esac
got="$(mut_probe boxnarrow "
CH = ['  - [  ] two spaces', '  - []  empty box']
t = '## B-h — DONE aaa\n' + '\n'.join(CH) + '\n'
L = t.splitlines(keepends=True)
e = list(zb.iter_entries(t, kinds=(zb.KIND_HEADING,)))[0]
print(zh.open_children(L, e))")"
[ "$got" = "0" ] \
  && ok "(H23b) boxnarrow: a single-whitespace box class counts 0 of the 2 wide-box children — F3's assertion is load-bearing" \
  || no "(H23b) boxnarrow reported '$got', expected 0 — F3 pins nothing"
got="$(mut_probe boxhead "
t = ('## B-h — DONE aaa\n'
     '  - [x] B-c [FIXED a1] fixed | [ ] OPEN follow-up\n')
L = t.splitlines(keepends=True)
e = list(zb.iter_entries(t, kinds=(zb.KIND_HEADING,)))[0]
print(zh.open_children(L, e))")"
[ "$got" = "0" ] \
  && ok "(H23b) boxhead: matching the open box only at the child's HEAD misses an open marker in its tail — F3/F5's assertion is load-bearing" \
  || no "(H23b) boxhead reported '$got', expected 0"
got="$(mut_probe nofencechild "
t = '## B-h — DONE aaa\n\`\`\`\n  - [ ] sample in a code block\n\`\`\`\n'
L = t.splitlines(keepends=True)
e = list(zb.iter_entries(t, kinds=(zb.KIND_HEADING,)))[0]
print(zh.open_children(L, e))")"
[ "$got" = "1" ] \
  && ok "(H23b) nofencechild: without the fence step a documentation sample holds the heading for ever — F4's assertion is load-bearing" \
  || no "(H23b) nofencechild reported '$got', expected 1"
got="$(mut_probe orderswap "
t = ('## B-f5-parent — DONE b9767b6a\n'
     '- **Closed:** the parent says it is done\n'
     '  - [x] B-f5-child [FIXED a1] fixed | [ ] OPEN follow-up\n')
marked, unmarked, nested, plan = BA.classify(t)
print('%s|%s' % (','.join(e.ident or e.key for _, e in marked + unmarked) or '-', ';'.join(nested) or '-'))")"
case "$got" in
  *"B-f5-child"*) ok "(H23b) orderswap: testing '[ ]' before the inside filter reports the child HELD ($got) while its parent carries it into the archive — F5's false-held assertion is load-bearing" ;;
  *) no "(H23b) orderswap reported '$got' — F5 pins nothing" ;;
esac
got="$(mut_probe nostayheads "
t = ('## B-f6-dup — DONE b9767b6a\n- **Closed:** resolved copy\n\n'
     '## B-f6-dup an open restatement\nprose\n')
marked, unmarked, nested, plan = BA.classify(t)
print(len(plan.staying))")"
[ "$got" = "0" ] \
  && ok "(H23b) nostayheads: with the heading keys dropped from the plan, nothing protects an open heading id — F6's assertion is load-bearing" \
  || no "(H23b) nostayheads reported '$got', expected 0"
got="$(mut_probe nototalheads "
t = ('## B-f7-open a heading nobody closed\n\n'
     '- [ ] B-cb src/a.ts open\n')
marked, unmarked, nested, plan = BA.classify(t)
print(plan.total)")"
[ "$got" = "0" ] \
  && ok "(H23b) nototalheads: with the heading total zeroed, cmd_status's still_open under-counts again — F7's assertion is load-bearing" \
  || no "(H23b) nototalheads reported '$got', expected 0"

# --- H23c THE REJECTED CLAIM, measured here so the rejection is reproducible ---------------------
# Reported as CRITICAL twice: that `open_children` and `cmd_archive` use different block conventions
# (an off-by-one in the `lineno`/index conversion). It does NOT reproduce: on a resolved heading with
# an indented open child and a flush-left sibling, both spellings return the same boundary. Asserted
# rather than argued, so the day a shape DOES diverge this test says so instead of a report.
rej="$(pyb "
import zuvo_backlog_block as zbb
import zuvo_backlog_heading as zh
t = '## B-h — DONE aaa\n  - [ ] child\n- [ ] B-sib flush-left sibling\n'
L = t.splitlines(keepends=True)
e = list(zb.iter_entries(t, kinds=(zb.KIND_HEADING,)))[0]
print('%d %d %d' % (zbb.entry_block(L, e.lineno - 1), zbb.entry_block(L, e.lineno),
                    zh.open_children(L, e)))")"
echo "  ... H23c rejected claim: $rej  (entry_block(lineno-1), entry_block(lineno), open_children)"
case "$rej" in
  "2 2 1") ok "(H23c) the reported off-by-one does not reproduce: both block spellings return 2 and open_children still counts the 1 real child" ;;
  *) no "(H23c) the block conventions now DO diverge ($rej) — that is a real finding, not the rejected one" ;;
esac

# --- H24 THE IO LAYER (Task 5): two layouts, three fail-opens, and the two size gates -------------
# `zuvo_backlog_io.py` holds `resolve`/`read`/`is_ignored`/`Lock`/`atomic_write`, moved out of
# backlog-archive.py VERBATIM when that file measured 763 raw lines against the 400-line default in
# rules/file-limits.md. The move is pure motion — `tests/hooks/test-backlog-archive-dedup.sh` (138
# assertions, unedited by this task) is the behavioural proof — so what this group pins is what the
# MOVE could break and the CLI could not tell you about:
#   * the two LAYOUTS. `install_zuvo_home` (scripts/install.d/zuvo-home.sh) globs scripts/zuvo-home/* into the machine-global
#     ~/.zuvo/, so every module ends up a FLAT sibling with no package. A single-layout assertion
#     would pass on an io that resolved the parser through the repo tree and broke on every installed
#     copy, which nothing in this repo's tests would have run.
#   * the three documented FAIL-OPENS. None of them has a CLI symptom on the happy path, and each one
#     is load-bearing at fleet scale, so each gets its own assertion and its own mutant.
#   * the SIZE gates the move exists to serve, measured rather than asserted from the plan: a function
#     on BODY lines (public <= 50, private <= 30) and the module on RAW lines (400 default, 800 the
#     automatic CQ11 FAIL). `ast.stmt` is printed as an observation — rules/file-limits.md never
#     mentions it, so it is NOT a gate here and must not read as one.

io_pin="$(python3 "$FIX/pinguard.py" "$IO_MOD" 2>&1)"
echo "  ... io module pin guard: $io_pin"
[ "$io_pin" = "0 0 - 0 0 -" ] \
  && ok "(H24) zuvo_backlog_io.py: $io_pin — no iter_entries call at all, so the io layer can hide neither an unpinned selection nor a second gate" \
  || no "(H24) zuvo_backlog_io.py reported '$io_pin', expected '0 0 - 0 0 -' — the io layer has grown a parser walk of its own"

# LAYOUT 1, the repo checkout, through the importer's own pattern (backlog-archive.py puts its own
# directory on sys.path, then imports the sibling by name). Asserted on the NAMES that arrived, not on
# "the import returned": an io module that imported cleanly and exported nothing would satisfy a bare
# import probe while every call site in the archiver was already broken.
io_repo="$(python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/zuvo-home')
import zuvo_backlog_io as m
print('%s %s %s %s %s' % (m.ARCHIVE_NAME, m.LOCK_NAME, callable(m.resolve) and callable(m.read),
                          callable(m.is_ignored) and callable(m.atomic_write),
                          callable(getattr(m.Lock, '__enter__', None))
                          and callable(getattr(m.Lock, '__exit__', None))))" 2>&1)"
# `Lock` is checked by its CONTEXT-MANAGER PROTOCOL, not by `__name__`. The archiver's only use of it
# is `with Lock(...)`, so `__enter__`/`__exit__` are the property every call site depends on;
# `__name__ == 'Lock'` is an implementation detail that would go RED on a harmless
# `import LockManager as Lock` while still going GREEN for a Lock that cannot be entered at all.
[ "$io_repo" = "backlog-done.md .backlog-archive.lock.d True True True" ] \
  && ok "(H24) repo checkout: \`import zuvo_backlog_io\` resolves and carries all five moved names plus both constants, Lock with its context-manager protocol" \
  || no "(H24) repo checkout: the io import reported '$io_repo', expected 'backlog-done.md .backlog-archive.lock.d True True True'"

# LAYOUT 2, the FLATTENED ~/.zuvo/ one install.sh produces: every helper a sibling in one directory,
# no package, no subdirectories. Built here rather than by running install.sh, which has
# machine-global side effects.
FLAT="$FIX/flat"
mkdir -p "$FLAT"
# The archiver plus EVERY sibling, by glob rather than by name — `install.sh` globs
# `scripts/zuvo-home/*` into ~/.zuvo/, so naming them here would make this fixture describe a narrower
# install than the real one, and a seventh module would silently be missing from the layout under test.
cp "$ARCHIVE_PY" "$ROOT"/scripts/zuvo-home/zuvo_backlog_*.py "$FLAT/"
# THE PREMISE FIRST. If this directory were not flat — a stray subdirectory, an __init__.py, a missing
# module — the import below could succeed for a reason that has nothing to do with the layout under
# test, and the assertion would pass while proving nothing.
flat_files="$(ls -1 "$FLAT" | wc -l | tr -d ' ')"
flat_dirs="$(find "$FLAT" -mindepth 1 -type d | wc -l | tr -d ' ')"
# DERIVED, not the literal 6 it used to be: the count is "the archiver plus every zuvo_backlog_* sibling"
# and it has moved twice already (5 -> 6 with the io layer, 6 -> 7 with the conservation module). A
# literal here turns each new module into a red test that says "the fixture is not flat", which is not
# what went wrong. The SHAPE assertions — no subdirectory, no __init__.py — are the real content.
flat_want="$(( 1 + $(ls -1 "$ROOT"/scripts/zuvo-home/zuvo_backlog_*.py | wc -l | tr -d ' ') ))"
{ [ "$flat_files" -eq "$flat_want" ] && [ "$flat_dirs" -eq 0 ] && [ ! -f "$FLAT/__init__.py" ]; } \
  && ok "(H24) the flat fixture is flat: $flat_files sibling files (archiver + $((flat_want - 1)) modules), 0 subdirectories, no __init__.py — the shape install.sh writes into ~/.zuvo/" \
  || no "(H24) the flat fixture has $flat_files file(s) (expected $flat_want) and $flat_dirs subdirectory/ies — it is not the flattened layout, so the import below would measure something else"
io_flat="$(cd "$FLAT" && python3 -c "
import zuvo_backlog_io as m
print('%s %s %s' % (m.ARCHIVE_NAME, callable(m.atomic_write), m.main_root is not None))" 2>&1)"
[ "$io_flat" = "backlog-done.md True True" ] \
  && ok "(H24) flattened layout: \`import zuvo_backlog_io\` resolves with no package and no sys.path help, and reaches main_root through the flat parser" \
  || no "(H24) flattened layout: the io import reported '$io_flat', expected 'backlog-done.md True True' — an installed ~/.zuvo/ copy would not load"
# …and the whole CLI from that layout, from an unrelated cwd, which is how `append-runlog` calls it.
# STDERR IS NOT MERGED IN, and the reason is the same one stated at H3: a warning on stderr (a future
# Python's DeprecationWarning, a SyntaxWarning about a `\s` in a regex) is indistinguishable from a
# failure once it is interleaved into stdout. With `2>&1 | head -1` a warning line becomes "the first
# line", falls to the `*)` branch, and this assertion reports "every installed ~/.zuvo/ copy is
# broken" about a working install — a spurious RED with a maximally alarming message. The claim here
# is about STDOUT content, so stderr is captured separately and reported, never asserted on.
flat_err="$FIX/flat-cli.err"
flat_cli="$(cd / && python3 "$FLAT/backlog-archive.py" path --repo "$FIX/w1" 2>"$flat_err" | head -1)"
case "$flat_cli" in
  declared*) ok "(H24) the flattened archiver RUNS from an unrelated cwd: $flat_cli" ;;
  *) no "(H24) the flattened archiver answered '$flat_cli' — every installed ~/.zuvo/ copy is broken$(
       [ -s "$flat_err" ] && printf ' (stderr: %s)' "$(head -1 "$flat_err")")" ;;
esac

# FAIL-OPEN 1: `is_ignored()` returns None, not False, when the parent is not a git repository. The
# canonical backlog lives outside any repo and `git check-ignore` there answers a question nobody
# asked; cmd_archive's refusal reads `is_ignored(archive) is False` precisely so "unknown" cannot
# masquerade as "tracked". ALL THREE answers are asserted in one line — None outside a repo, False for
# a tracked path, True for an ignored one — because an is_ignored that returned None unconditionally
# would satisfy the first alone.
#
# A FRESH `git init` fixture, not this checkout: the farm runs this suite from a delta MIRROR with no
# .git at all, so `is_ignored($ROOT/memory/backlog.md)` answers None there and False locally. That is
# the environment differing, not the product, and an assertion that flips between the two machines
# measures the machine.
case "$(cd "$FIX" && git rev-parse --is-inside-work-tree 2>&1)" in
  true) no "(H24) \$FIX is inside a git work tree, so the outside-a-repo assertion below would be measuring a repo — the None fail-open cannot be tested from here" ;;
  *) ok "(H24) \$FIX is outside any git work tree — the premise the None fail-open is about" ;;
esac
mkdir -p "$FIX/ignrepo/memory"
( cd "$FIX/ignrepo" && git init -q . ) >/dev/null 2>&1
printf 'x\n' > "$FIX/ignrepo/memory/backlog.md"
printf '/memory/backlog-done.md\n' > "$FIX/ignrepo/.gitignore"
case "$(cd "$FIX/ignrepo" && git rev-parse --is-inside-work-tree 2>&1)" in
  true) ok "(H24) the git fixture initialised — is_ignored() can be asked the question it exists for" ;;
  *) no "(H24) \`git init\` in \$FIX/ignrepo did not produce a work tree, so the False/True halves below would both read as the outside-a-repo None and pass for the wrong reason" ;;
esac
ign_out="$(pyb "print('%s %s %s' % (BA.is_ignored('$FIX/no-such-backlog.md'),
                                    BA.is_ignored('$FIX/ignrepo/memory/backlog.md'),
                                    BA.is_ignored('$FIX/ignrepo/memory/backlog-done.md')))")"
[ "$ign_out" = "None False True" ] \
  && ok "(H24) is_ignored() fail-open: None outside a repo, False for a tracked path, True for an ignored one — 'unknown' stays distinguishable from both" \
  || no "(H24) is_ignored() reported '$ign_out', expected 'None False True' — cmd_archive's \`is_ignored(archive) is False\` refusal now reads a degraded answer as a verdict"

# FAIL-OPEN 2: `read()` returns "" for a file that does not exist. `append-runlog` runs `status` and
# `verify` at the end of every skill run in every repo on the machine, most of which have no backlog
# at all, and a traceback there is a blocked run. Asserted at the function AND through the CLI.
rd_out="$(pyb "print('%r %s' % (BA.read('$FIX/no-such-file-at-all.md'), len(BA.read('$REAL')) > 0))")"
[ "$rd_out" = "'' True" ] \
  && ok "(H24) read() fail-open: '' for an absent file, and the real backlog still reads non-empty" \
  || no "(H24) read() reported '$rd_out', expected \"'' True\""
mkdir -p "$FIX/nobacklog"
nb_out="$(python3 "$ARCHIVE_PY" status --repo "$FIX/nobacklog" 2>&1)"; nb_rc=$?
{ [ "$nb_rc" -eq 0 ] && case "$nb_out" in "OK no backlog"*) true ;; *) false ;; esac; } \
  && ok "(H24) …and \`status\` on a repo with no backlog exits 0 with '$nb_out'" \
  || no "(H24) status on a backlog-less repo answered rc=$nb_rc '$(printf '%s' "$nb_out" | head -1)' — every repo without a backlog would block its runs"

# FAIL-OPEN 3: cmd_verify reads under `Lock` but falls back to an UNLOCKED read when the lock cannot be
# taken. A gate that cannot answer is worse than one that occasionally reads a transient state, because
# `append-runlog` turns a non-zero `verify` into BACKLOG_NAMESPACE_VIOLATION, exits 2 and appends
# nothing. THE CONTENTION IS PROVED, not assumed: `drop-stale`, which has no fallback, must die on the
# same held lock in the same breath — otherwise verify's rc=0 could simply mean the lock was free.
mkdir -p "$FIX/vlock/memory"
printf '# Tech Debt Backlog\n\n## Open\n\n- [ ] B-vlock src/a.ts an open entry\n' \
  > "$FIX/vlock/memory/backlog.md"
mkdir -p "$FIX/vlock/memory/.backlog-archive.lock.d"
printf '%s' "$$" > "$FIX/vlock/memory/.backlog-archive.lock.d/pid"   # this suite's own pid: alive
ds_out="$(env ZUVO_LOCK_WAIT=0 python3 "$ARCHIVE_PY" drop-stale --repo "$FIX/vlock" \
            --id B-vlock --dry-run 2>&1)"; ds_rc=$?
{ [ "$ds_rc" -ne 0 ] && case "$ds_out" in *"lock held"*) true ;; *) false ;; esac; } \
  && ok "(H24) the lock IS contended: drop-stale (no fallback) exits $ds_rc — '$(printf '%s' "$ds_out" | head -1)'" \
  || no "(H24) drop-stale on the held lock answered rc=$ds_rc '$(printf '%s' "$ds_out" | head -1)' — the lock is not actually held, so verify's verdict below would prove nothing"
vf_out="$(env ZUVO_LOCK_WAIT=0 python3 "$ARCHIVE_PY" verify --repo "$FIX/vlock" 2>&1)"; vf_rc=$?
{ [ "$vf_rc" -eq 0 ] && case "$vf_out" in "OK disjoint"*) true ;; *) false ;; esac; } \
  && ok "(H24) cmd_verify's unlocked fallback: on that same held lock it still answers rc=0 '$(printf '%s' "$vf_out" | head -1)'" \
  || no "(H24) verify on the held lock answered rc=$vf_rc '$(printf '%s' "$vf_out" | head -1)' — append-runlog would print BACKLOG_NAMESPACE_VIOLATION and block the run in every repo"

# --- H24b THE MUTANTS: each of the six claims above, reverted on its own -------------------------
# A PASS nobody has seen fail is not evidence. Every mutation below reverts exactly ONE of the
# properties asserted above and nothing else, and `mkmut` hard-errors when a substitution does not
# apply, so "the mutant passed" can never quietly mean "the mutation was never made".
io_mut(){ im_m="$1"; shift; im_out="$(mkmut "$im_m" 2>&1)"
  if [ -n "$im_out" ]; then printf 'BUILD-FAILED %s' "$im_out"; return; fi
  # NOT gated, unlike mut_probe: none of these mutations is about the heading env gate, and exporting
  # it here would change what the archiver does for a reason unrelated to the subject.
  #
  # PYTHONPATH IS CLEARED and the probe runs from a NEUTRAL cwd, because two of the mutations below
  # are about where a module can be resolved FROM, and `python3 -c` puts the cwd on sys.path itself.
  # `iodash` asserts that a hyphenated io module is not importable — but if the runner's cwd (or an
  # inherited PYTHONPATH) happened to be scripts/zuvo-home, the REAL zuvo_backlog_io.py would resolve
  # from there, the mutant would import fine, and the assertion would go RED against a working
  # mutation. `ioreporoot` is the same story mirrored: a PYTHONPATH pointing at the repo tree makes
  # the flattened layout succeed where it must fail. Both would then be measuring the runner's
  # environment instead of the mutant — which is exactly the sys.path hygiene the IO_REPOROOT
  # mutation itself is about.
  # `env -u`, not `PYTHONPATH=`: an EMPTY PYTHONPATH puts '' (the cwd) back on sys.path in some CPython
  # versions, which is the very entry this is removing. Unset it instead of blanking it.
  ( cd / && env -u PYTHONPATH python3 -c "
import sys
sys.path.insert(0, '$FIX'); sys.path.insert(0, '$FIX/mut-$im_m')
from ba import load
BA = load('$FIX/mut-$im_m/backlog-archive.py')
$1" 2>&1 ); }

# iodash — the module written HYPHENATED. This is what the underscore in every sibling's name is
# load-bearing against, and it breaks BOTH layouts at once, which is why it is asserted on the
# archiver's own import rather than on one layout's probe.
dash_out="$(io_mut iodash "print('LOADED')")"
case "$dash_out" in
  *"No module named 'zuvo_backlog_io'"*) ok "(H24b) iodash: a hyphenated io module is not importable at all — 'import zuvo_backlog_io' finds nothing, so the underscore is load-bearing and not a convention" ;;
  *) no "(H24b) iodash reported '$(printf '%s' "$dash_out" | tail -1)' — expected a ModuleNotFoundError for zuvo_backlog_io" ;;
esac

# ioreporoot — io stops being a flat sibling and points sys.path at the REPO tree. It resolves in the
# checkout and NOT on the flattened layout, which is exactly the asymmetry a single-layout assertion
# cannot see: the repo probe stays green while every installed ~/.zuvo/ copy is dead.
mkmut ioreporoot >/dev/null 2>&1
# TWO TREES from the one mutant, because the whole point is that they disagree: a `scripts/zuvo-home/`
# one, where `../../scripts/zuvo-home` resolves back to itself exactly as it does in this checkout, and
# a flat one, where it resolves to a directory that does not exist.
mkdir -p "$FIX/repolike/scripts/zuvo-home" "$FIX/flat-rr"
cp "$FIX/mut-ioreporoot"/*.py "$FIX/repolike/scripts/zuvo-home/"
cp "$FIX/mut-ioreporoot"/*.py "$FIX/flat-rr/"
rr_repo="$(cd "$FIX/repolike/scripts/zuvo-home" && python3 -c "
import zuvo_backlog_io as m
print(m.ARCHIVE_NAME)" 2>&1 | tail -1)"
rr_flat="$(cd "$FIX/flat-rr" && python3 -c "
import zuvo_backlog_io as m
print(m.ARCHIVE_NAME)" 2>&1 | tail -1)"
echo "  ... ioreporoot: repo layout -> '$rr_repo'; flat layout -> '$rr_flat'"
{ [ "$rr_repo" = "backlog-done.md" ] && [ "$rr_flat" != "backlog-done.md" ]; } \
  && ok "(H24b) ioreporoot: an io that resolves the parser through the REPO tree still imports in the checkout and FAILS on the flattened layout — the two-layout assertion is load-bearing, not a restatement of the first" \
  || no "(H24b) ioreporoot gave repo='$rr_repo' flat='$rr_flat' — expected the repo layout to work and the flat one to fail; the flattened-layout assertion above is then not shown to catch anything"

# ignoretight — the None fail-open becomes an exit.
it_out="$(io_mut ignoretight "print(BA.is_ignored('$FIX/no-such-backlog.md'))")"
case "$it_out" in
  None) no "(H24b) ignoretight still printed None — the mutation did not reach is_ignored, so the fail-open assertion is not shown to catch anything" ;;
  *) ok "(H24b) ignoretight: tightening the outside-a-repo answer changes it to '$(printf '%s' "$it_out" | tail -1)' — the None is measured, not incidental" ;;
esac

# readtight — the missing-file fail-open re-raises. Asserted through the CLI too, because that is where
# it costs: `status` in a repo with no backlog.
rt_out="$(io_mut readtight "print(repr(BA.read('$FIX/no-such-file-at-all.md')))")"
case "$rt_out" in
  "''") no "(H24b) readtight still returned '' — the mutation did not reach read(), so the fail-open assertion proves nothing" ;;
  *FileNotFoundError*) ok "(H24b) readtight: read() then raises FileNotFoundError instead of returning '' — the fail-open is measured" ;;
  *) no "(H24b) readtight reported '$(printf '%s' "$rt_out" | tail -1)' — expected a FileNotFoundError" ;;
esac
rt_cli="$(python3 "$FIX/mut-readtight/backlog-archive.py" status --repo "$FIX/nobacklog" 2>&1)"
rt_rc=$?
{ [ "$rt_rc" -ne 0 ] && case "$rt_cli" in *FileNotFoundError*) true ;; *) false ;; esac; } \
  && ok "(H24b) …and \`status\` in a backlog-less repo then exits $rt_rc with a traceback — which append-runlog turns into a blocked run" \
  || no "(H24b) readtight's status answered rc=$rt_rc '$(printf '%s' "$rt_cli" | tail -1)' — expected a non-zero exit naming FileNotFoundError"

# nofallback — cmd_verify catches OSError instead of SystemExit, so the held lock takes the GATE down.
mkmut nofallback >/dev/null 2>&1
nf_out="$(env ZUVO_LOCK_WAIT=0 python3 "$FIX/mut-nofallback/backlog-archive.py" verify \
            --repo "$FIX/vlock" 2>&1)"; nf_rc=$?
{ [ "$nf_rc" -ne 0 ] && case "$nf_out" in *"lock held"*) true ;; *) false ;; esac; } \
  && ok "(H24b) nofallback: without the SystemExit catch, verify exits $nf_rc on the held lock — '$(printf '%s' "$nf_out" | head -1)' — the exit append-runlog reads as BACKLOG_NAMESPACE_VIOLATION" \
  || no "(H24b) nofallback's verify answered rc=$nf_rc '$(printf '%s' "$nf_out" | head -1)' — the unlocked-fallback assertion is not shown to catch anything"

# --- H24c THE SIZE GATES, MEASURED: function BODY lines and module RAW lines ----------------------
# A FILE, not an inline heredoc, so the identical measurement can be re-run against the PRE-refactor
# module and against a deliberately oversized one — which is the only way to know these two
# assertions can go red at all.
cat > "$FIX/pysize.py" <<'PYEOF'
"""Measure ONE python file the way rules/file-limits.md gates it.

Prints  MODULE <raw_lines> <ast_stmt_count>
then    FN <qualname> <public|private> <raw> <body> <limit> <OK|OVER>  per function and method.

BODY is `rules/file-limits.md:42` — "function body only, excluding signature line, JSDoc, and closing
brace" — read for Python as the lines from the first non-docstring statement to the last line of the
def, minus blank lines and comment-only lines. The docstring is excluded because it sits above that
first statement. The thresholds are that file's: public <= 50, private/helper <= 30.

`ast.stmt` is printed as an OBSERVATION. rules/file-limits.md never mentions it, and it is NOT a gate
here — an earlier revision of this task's spec treated it as one, which it never was.
"""
import ast
import sys

PUBLIC, PRIVATE = 50, 30


def body_lines(fn, lines):
    stmts = list(fn.body)
    if stmts and isinstance(stmts[0], ast.Expr) and isinstance(stmts[0].value, ast.Constant) \
            and isinstance(stmts[0].value.value, str):
        stmts = stmts[1:]
    if not stmts:
        return 0
    n = 0
    for ln in lines[stmts[0].lineno - 1:fn.end_lineno]:
        s = ln.strip()
        if s and not s.startswith("#"):
            n += 1
    return n


def walk(node, prefix, lines, out):
    for child in ast.iter_child_nodes(node):
        if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
            name = prefix + child.name
            private = child.name.startswith("_")
            out.append((name, "private" if private else "public",
                        child.end_lineno - child.lineno + 1, body_lines(child, lines),
                        PRIVATE if private else PUBLIC))
            walk(child, name + ".", lines, out)
        elif isinstance(child, ast.ClassDef):
            walk(child, prefix + child.name + ".", lines, out)
        else:
            walk(child, prefix, lines, out)


src = open(sys.argv[1], encoding="utf-8").read()
lines = src.splitlines()
tree = ast.parse(src)
print("MODULE %d %d" % (len(lines), sum(1 for n in ast.walk(tree) if isinstance(n, ast.stmt))))
rows = []
walk(tree, "", lines, rows)
for name, vis, raw, body, limit in rows:
    print("FN %s %s %d %d %d %s" % (name, vis, raw, body, limit, "OK" if body <= limit else "OVER"))
PYEOF

# Named explicitly, because these two are the whole reason Task 5 exists and a "no function is over"
# assertion alone would not record their numbers anywhere a reader can see them.
size_line(){ python3 "$FIX/pysize.py" "$1" | awk -v f="$2" '$1=="FN" && $2==f {print $4, $5, $6, $7}'; }
ca_size="$(size_line "$ARCHIVE_PY" cmd_archive)"
ds_size="$(size_line "$ARCHIVE_PY" cmd_drop_stale)"
echo "  ... cmd_archive raw/body/limit/verdict: $ca_size"
echo "  ... cmd_drop_stale raw/body/limit/verdict: $ds_size"
case "$ca_size" in *" OK") ok "(H24c) cmd_archive is within the 50-line public-function limit ($ca_size)" ;;
  *) no "(H24c) cmd_archive is $ca_size — over the 50 body lines rules/file-limits.md allows a public function" ;; esac
case "$ds_size" in *" OK") ok "(H24c) cmd_drop_stale is within the 50-line public-function limit ($ds_size)" ;;
  *) no "(H24c) cmd_drop_stale is $ds_size — over the 50 body lines rules/file-limits.md allows a public function" ;; esac
# …and no OTHER function may cross its limit as a side effect of the split, in either module.
for f in "$ARCHIVE_PY" "$IO_MOD"; do
  over="$(python3 "$FIX/pysize.py" "$f" | awk '$1=="FN" && $7=="OVER" {printf "%s(%s/%s) ", $2, $5, $6}')"
  [ -z "$over" ] \
    && ok "(H24c) every function in $(basename "$f") is within its limit (public 50, private 30)" \
    || no "(H24c) $(basename "$f") has function(s) over the limit: $over"
done
# THE MODULE, on RAW lines. 800 is rules/file-limits.md's automatic CQ11 FAIL for a Python module and
# is the only module threshold with teeth here; the 400 default is over-run and REPORTED, with the
# residual filed as a backlog entry rather than silently tolerated. The actual number is printed on
# every run so the residual cannot go quiet.
for f in "$ARCHIVE_PY" "$IO_MOD"; do
  mod="$(python3 "$FIX/pysize.py" "$f" | awk '$1=="MODULE" {print $2, $3}')"
  set -- $mod; m_raw="$1"; m_stmt="$2"
  echo "  ... $(basename "$f"): $m_raw raw lines, $m_stmt ast.stmt (observation — ast.stmt is NOT a gate)"
  [ "$m_raw" -le 800 ] \
    && ok "(H24c) $(basename "$f") is $m_raw raw lines — under the 800-line automatic CQ11 FAIL$([ "$m_raw" -gt 400 ] && printf ', and OVER the 400-line default (filed as a backlog entry)')" \
    || no "(H24c) $(basename "$f") is $m_raw raw lines — past the 800-line automatic CQ11 FAIL in rules/file-limits.md; split it, do not raise the number"
done
# NOT VACUOUS: the same measurement, on a generated file that breaks both thresholds on purpose. A
# measurement assertion nobody has seen go red is a comment.
python3 -c "
lines = ['\"\"\"generated oversize probe — 53 body lines in one public function, 801 raw.\"\"\"', '',
         'def wide_function() -> int:', '    n = 0']
lines += ['    n += %d' % i for i in range(51)]
lines.append('    return n')
while len(lines) < 801:
    lines.append('# pad')
open('$FIX/oversize.py', 'w', encoding='utf-8').write('\n'.join(lines) + '\n')"
ov="$(python3 "$FIX/pysize.py" "$FIX/oversize.py")"
ov_mod="$(printf '%s\n' "$ov" | awk '$1=="MODULE" {print $2}')"
ov_fn="$(printf '%s\n' "$ov" | awk '$1=="FN" && $2=="wide_function" {print $5, $7}')"
echo "  ... oversize probe: module $ov_mod raw, wide_function body/verdict $ov_fn"
{ [ "$ov_mod" -gt 800 ] && [ "$ov_fn" = "53 OVER" ]; } \
  && ok "(H24c) the measurement reports OVER on a padded copy (801 raw, a 53-body-line public function) — both size assertions can go red" \
  || no "(H24c) the oversize probe measured module=$ov_mod fn='$ov_fn', expected >800 and '53 OVER' — the two size assertions above may be vacuous"

finish
