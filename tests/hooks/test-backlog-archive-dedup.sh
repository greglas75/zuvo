#!/usr/bin/env bash
# Backlog archive + both-file dedup contract.
#
# The rule this guards: the backlog namespace is TWO files (memory/backlog.md open,
# memory/backlog-done.md closed), an entry is defined in exactly ONE of them, and a candidate found
# in the archive is a REGRESSION — never a fresh entry under a fresh id. Without a probe, that rule
# is prose in an include, and the failure it prevents is silent: a closed 300-item archive turns
# itself back into an open backlog, one re-discovered finding at a time.
#
# Measured on the canonical backlog while this was written (and the reason A3 exists): five ids are
# currently defined in BOTH files. On those five pairs the id key matches 5/5 and the CONTENT key
# matches 0/5, because closing an entry rewrites its text into a description of the fix. So the id
# is the only thing that bridges open→archived, which is why `archive` mints one for any entry that
# lacks it, and why A3 asserts key stability rather than assuming it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
HELPER="$ROOT/scripts/zuvo-home/backlog-archive.py"
INCLUDE="$ROOT/shared/includes/backlog-protocol.md"
SKILL="$ROOT/skills/backlog/SKILL.md"

PASS=0; FAIL=0
# A misspelled helper prints "command not found", returns 127 and moves no counter — a whole file of
# broken assertions then summarises as FAIL=0 (that happened in test-profile-session-tokens.sh).
command_not_found_handle(){ echo "  FAIL harness: unknown command '$1'"; FAIL=$((FAIL+1)); return 127; }
ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

echo "== backlog archive + both-file dedup =="

# --- A8 first: no-substitution. A missing helper is a FAILURE, not a SKIP: python3 is a stated
# prerequisite of this repo, so there is no legitimate path on which this check does not run.
if [ -x "$HELPER" ]; then ok "(A8) helper present and executable"; else
  no "(A8) $HELPER missing or not executable — the rest cannot be checked"; echo "RESULT: PASS=$PASS FAIL=$FAIL"; exit 1
fi
H(){ "$HELPER" "$@"; }

# --- A1 contract, in BOTH copies (the include AND the skill that carries its own paraphrase) ------
for token in "backlog-done.md" "ARCHIVED" "ABSENT" "REGRESSION"; do
  grep -q -- "$token" "$INCLUDE" && ok "(A1) include names $token" || no "(A1) include never names $token"
done
grep -q "delete the row entirely" "$INCLUDE" \
  && no "(A1) include still says 'delete the row entirely' — the rule archiving replaces" \
  || ok "(A1) 'delete the row entirely' is gone from the include"
grep -q "delete the row entirely" "$SKILL" \
  && no "(A1) skills/backlog/SKILL.md still says 'delete the row entirely'" \
  || ok "(A1) 'delete the row entirely' is gone from skills/backlog/SKILL.md"
grep -q "Fingerprint column" "$INCLUDE" \
  && no "(A1) include still tells agents to search a 'Fingerprint column' that no backlog has" \
  || ok "(A1) the unexecutable 'Fingerprint column' instruction is gone"

FIX="$(mktemp -d "${TMPDIR:-/tmp}/stqa-backlog.XXXXXX")"
# Canonicalise once. On macOS $TMPDIR is /var/folders/... and /var is a symlink to /private/var,
# so the helper (which resolves real paths, correctly) answers /private/var/... while every
# comparison here would hold the unresolved form — A5 failed on the prefix alone, and only on
# macOS. Linux has no such symlink, which is why the farm never saw it.
FIX="$(cd "$FIX" && pwd -P)"
trap 'rm -rf "$FIX"' EXIT

mkfixture(){ # mkfixture <dir> — one open entry, one archived entry, one prose cross-reference
  mkdir -p "$1/memory"
  cat > "$1/memory/backlog.md" <<'EOF'
# Tech Debt Backlog

- [ ] B-FIXTURE-OPEN src/open.ts misses the orgId filter on the list query | conf: 70
- [ ] B-FIXTURE-PROSE src/other.ts see B-FIXTURE-ARCHIVED for the same class of bug | conf: 40
EOF
  cat > "$1/memory/backlog-done.md" <<'EOF'
## Archived from backlog.md on 2026-09-01 (1 completed item moved out)
- [x] B-FIXTURE-ARCHIVED [FIXED abc1234] src/foo.ts drops the orgId filter | conf: 70
EOF
}

# --- A2 THE PROBE: an id that exists only in the archive must not read as new -------------------
mkfixture "$FIX/a2"
out="$(H lookup --repo "$FIX/a2" B-FIXTURE-ARCHIVED)"; rc=$?
case "$out" in ARCHIVED*) ok "(A2) archived id reports ARCHIVED" ;; *) no "(A2) archived id reported: $out" ;; esac
[ "$rc" -eq 11 ] && ok "(A2) archived id exits 11" || no "(A2) archived id exit was $rc, want 11"
case "$out" in *ABSENT*) no "(A2) verdict contains ABSENT" ;; *) ok "(A2) verdict does not say ABSENT" ;; esac
case "$out" in *backlog-done.md:*) ok "(A2) verdict names the archive and line" ;; *) no "(A2) no archive:line in verdict" ;; esac
case "$out" in *"Archived from backlog.md on 2026-09-01"*) ok "(A2) verdict quotes the section heading" ;;
  *) no "(A2) section heading missing from verdict: $out" ;; esac

out="$(H lookup --repo "$FIX/a2" B-NEVER-SEEN-ANYWHERE)"; rc=$?
case "$out$rc" in ABSENT*0) ok "(A2) unknown id reports ABSENT, exit 0" ;; *) no "(A2) unknown id: $out rc=$rc" ;; esac
out="$(H lookup --repo "$FIX/a2" B-FIXTURE-OPEN)"; rc=$?
case "$out$rc" in OPEN*10) ok "(A2) open id reports OPEN, exit 10" ;; *) no "(A2) open id: $out rc=$rc" ;; esac

# --- A3 key stability across resolution ---------------------------------------------------------
# The same entry, open and closed. If the key moves, every archive lookup misses and the whole
# feature is a no-op that reads as working.
py(){ python3 -c "
import sys
sys.path.insert(0, '$ROOT/scripts/zuvo-home')
import zuvo_backlog_parse as z
$1"; }
if py "
o = z.entry_key('B-X src/foo.ts drops the orgId filter | conf: 70')
c = z.entry_key('B-X [done] — DONE — PR #834 squash 9178842d51 src/foo.ts drops the orgId filter')
sys.exit(0 if o == c else 1)"; then ok "(A3) id key is stable across resolution"; else no "(A3) id key CHANGED when the entry was closed"; fi
if py "
o = z.entry_key('src/foo.ts drops the orgId filter on the list query | conf: 70')
c = z.entry_key('[FIXED abc1234] src/foo.ts drops the orgId filter on the list query')
sys.exit(0 if o == c else 1)"; then ok "(A3) content key survives a marker-only closure"; else no "(A3) content key CHANGED on a marker-only closure"; fi
if py "
sys.exit(0 if z.entry_key('B-Y a.ts x').startswith('id:') and z.entry_key('a.ts x').startswith('fp:') else 1)"
then ok "(A3) key is id-preferred, content-fallback"; else no "(A3) key selection is wrong"; fi

# --- A4 disjointness, plus the false-positive control -------------------------------------------
mkfixture "$FIX/a4"
printf -- '- [x] B-FIXTURE-OPEN [FIXED deadbee] src/open.ts misses the orgId filter\n' >> "$FIX/a4/memory/backlog-done.md"
out="$(H verify --repo "$FIX/a4")"; rc=$?
{ [ "$rc" -eq 1 ] && case "$out" in *b-fixture-open*) true ;; *) false ;; esac; } \
  && ok "(A4) a key defined in both files is a VIOLATION, exit 1, named" \
  || no "(A4) duplicate not reported (rc=$rc): $out"
mkfixture "$FIX/a4b"
out="$(H verify --repo "$FIX/a4b")"; rc=$?
{ [ "$rc" -eq 0 ] && case "$out" in OK*) true ;; *) false ;; esac; } \
  && ok "(A4) a prose 'see B-X' reference is NOT a definition (no false positive)" \
  || no "(A4) prose cross-reference flagged as a duplicate (rc=$rc): $out"

# --- A12 a DECLARED regression shares an id legitimately -----------------------------------------
# The protocol's re-open path puts the same id in both files on purpose. A gate that called that a
# violation would punish the behaviour it mandates — and on the real backlog it flagged two genuine
# regressions, which is how a guard gets muted.
mkfixture "$FIX/a12"
printf -- '- [ ] B-FIXTURE-ARCHIVED [REGRESSION 2026-09-18 — closed FIXED abc1234] src/foo.ts drops the orgId filter\n' \
  >> "$FIX/a12/memory/backlog.md"
out="$(H verify --repo "$FIX/a12")"; rc=$?
{ [ "$rc" -eq 0 ] && case "$out" in *"declared regression"*) true ;; *) false ;; esac; } \
  && ok "(A12) a declared REGRESSION sharing an id is not a violation" \
  || no "(A12) declared regression flagged as a violation (rc=$rc): $out"
mkfixture "$FIX/a12b"
printf -- '- [ ] B-FIXTURE-ARCHIVED src/foo.ts drops the orgId filter again\n' >> "$FIX/a12b/memory/backlog.md"
out="$(H verify --repo "$FIX/a12b")"; rc=$?
[ "$rc" -eq 1 ] && ok "(A12) the same pair WITHOUT the marker is still a violation" \
  || no "(A12) an undeclared duplicate passed (rc=$rc): $out"

# --- A5 symlink safety: the archive belongs beside the REAL file, and the link survives ----------
mkdir -p "$FIX/a5/real" "$FIX/a5/alias/memory"
mkfixture "$FIX/a5/realrepo"
mv "$FIX/a5/realrepo/memory/backlog.md" "$FIX/a5/real/backlog.md"
mv "$FIX/a5/realrepo/memory/backlog-done.md" "$FIX/a5/real/backlog-done.md"
ln -s ../../real/backlog.md "$FIX/a5/alias/memory/backlog.md"
out="$(H path --repo "$FIX/a5/alias")"
case "$out" in *"$FIX/a5/real/backlog-done.md"*) ok "(A5) archive resolves beside the real file" ;;
  *) no "(A5) archive resolved to the wrong directory: $out" ;; esac
printf -- '- [x] B-A5-DONE [FIXED cafe123] src/five.ts leaks the tenant id\n' >> "$FIX/a5/real/backlog.md"
H archive --repo "$FIX/a5/alias" >/dev/null 2>&1
[ -L "$FIX/a5/alias/memory/backlog.md" ] && ok "(A5) the symlink is still a symlink after archiving" \
  || no "(A5) archiving REPLACED the symlink with a regular file — the 6-way fork"
[ -f "$FIX/a5/real/backlog-done.md" ] && ok "(A5) the real directory got the archive" \
  || no "(A5) no archive beside the real file"
[ -e "$FIX/a5/alias/memory/backlog-done.md" ] \
  && no "(A5) a second archive appeared beside the symlink" \
  || ok "(A5) no archive was created beside the symlink"

# --- A6 byte conservation -----------------------------------------------------------------------
mkfixture "$FIX/a6"
printf -- '- [x] B-A6-ONE [FIXED 1111111] src/one.ts double counts refunds\n' >> "$FIX/a6/memory/backlog.md"
printf -- '- [x] B-A6-TWO [WONTFIX — by design] src/two.ts logs the raw payload\n' >> "$FIX/a6/memory/backlog.md"
before_open=$(wc -l < "$FIX/a6/memory/backlog.md"); before_arch=$(wc -l < "$FIX/a6/memory/backlog-done.md")
H archive --repo "$FIX/a6" >/dev/null
after_open=$(wc -l < "$FIX/a6/memory/backlog.md"); after_arch=$(wc -l < "$FIX/a6/memory/backlog-done.md")
[ "$((before_open - after_open))" -eq 2 ] && ok "(A6) exactly the resolved lines left the open file" \
  || no "(A6) open file lost $((before_open - after_open)) lines, want 2"
[ "$((after_arch - before_arch))" -ge 2 ] && ok "(A6) the archive grew by the moved lines" \
  || no "(A6) archive grew by $((after_arch - before_arch))"
for id in B-A6-ONE B-A6-TWO; do
  grep -q "$id" "$FIX/a6/memory/backlog-done.md" && grep -qv "$id" "$FIX/a6/memory/backlog.md" \
    && ok "(A6) $id is in the archive and gone from the open file" \
    || no "(A6) $id was not moved cleanly"
done

# --- A7 an entry with a live sub-item is refused -------------------------------------------------
mkfixture "$FIX/a7"
printf -- '- [x] B-A7-PARENT [FIXED 2222222] src/p.ts fixed the parser | [ ] OPEN follow-up: add a test\n' \
  >> "$FIX/a7/memory/backlog.md"
H archive --repo "$FIX/a7" >/dev/null 2>&1
grep -q "B-A7-PARENT" "$FIX/a7/memory/backlog.md" \
  && ok "(A7) an entry carrying a live [ ] sub-item stays in the open file" \
  || no "(A7) archiving dragged a live sub-item out of sight"

# --- A11 an id behind emphasis/tag markup is still a DEFINITION ----------------------------------
# Measured prefixes in the canonical backlog: "**" (385 lines), "**[S] " (249), "**[M] " (165),
# "**[S]** **" (99). Reading those as "no id" made the archiver mint a SECOND id for an entry that
# already had one, and pushed its key onto the content fallback so a lookup by the real id missed.
# Caught by a --dry-run against the real file, which is why this assertion exists.
mkfixture "$FIX/a11"
printf -- '- [x] **[S] B-A11-TAGGED [P3][tests]** — [FIXED 5555555] src/eleven.ts covers nothing\n' \
  >> "$FIX/a11/memory/backlog.md"
out="$(H archive --repo "$FIX/a11" --dry-run)"
case "$out" in *"would mint an id for 0"*) ok "(A11) a tag-prefixed id is recognised, nothing minted" ;;
  *) no "(A11) would mint an id for an entry that has one: $out" ;; esac
H archive --repo "$FIX/a11" >/dev/null
out="$(H lookup --repo "$FIX/a11" B-A11-TAGGED)"; rc=$?
{ [ "$rc" -eq 11 ] && case "$out" in ARCHIVED*) true ;; *) false ;; esac; } \
  && ok "(A11) the archived tag-prefixed entry is findable by its real id" \
  || no "(A11) archived tag-prefixed entry not findable (rc=$rc): $out"

# --- A9 the threshold is not an excuse to invent a file -----------------------------------------
mkdir -p "$FIX/a9/memory"
printf -- '- [ ] B-A9-OPEN src/nine.ts drops the retry budget\n' > "$FIX/a9/memory/backlog.md"
out="$(H lookup --repo "$FIX/a9" B-A9-NOPE)"; rc=$?
case "$out$rc" in ABSENT*0) ok "(A9) missing archive answers ABSENT, exit 0" ;; *) no "(A9) $out rc=$rc" ;; esac
[ -e "$FIX/a9/memory/backlog-done.md" ] \
  && no "(A9) the lookup CREATED an archive so it would have something to check" \
  || ok "(A9) no archive was created by a lookup"

# --- A10 mode + ignore inheritance ---------------------------------------------------------------
mkfixture "$FIX/a10"
chmod 600 "$FIX/a10/memory/backlog.md"; rm -f "$FIX/a10/memory/backlog-done.md"
printf -- '- [x] B-A10-DONE [FIXED 3333333] src/ten.ts trusts the client clock\n' >> "$FIX/a10/memory/backlog.md"
H archive --repo "$FIX/a10" >/dev/null
mode=$(ls -l "$FIX/a10/memory/backlog-done.md" | cut -c1-10)
[ "$mode" = "-rw-------" ] && ok "(A10) a new archive inherits the source file mode" \
  || no "(A10) archive mode is $mode, source was 0600"

mkfixture "$FIX/a10b"
( cd "$FIX/a10b" && git init -q . && printf '/memory/backlog.md\n' > .gitignore ) >/dev/null 2>&1
rm -f "$FIX/a10b/memory/backlog-done.md"
printf -- '- [x] B-A10B [FIXED 4444444] src/eleven.ts swallows the error\n' >> "$FIX/a10b/memory/backlog.md"
out="$(H archive --repo "$FIX/a10b" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && case "$out" in *gitignore*) true ;; *) false ;; esac; } \
  && ok "(A10) refuses to publish a tracked archive beside an ignored backlog" \
  || no "(A10) archived into git beside an ignored backlog (rc=$rc): $out"
[ -e "$FIX/a10b/memory/backlog-done.md" ] \
  && no "(A10) the refused run still created the archive" \
  || ok "(A10) the refused run wrote nothing"


# --- A13 status: finished work in the open backlog is a finding at COUNT 1, not at a size ---------
# The threshold this replaced ("archive at >= 50 resolved or >100 KB") is why the feature went
# unused for its first two days: it asked someone to notice a size. One resolved entry must be
# enough to say OVERDUE, and the exit code is what lets a hook act without parsing prose.
mkdir -p "$FIX/a13/memory"
printf -- '- [ ] B-A13-OPEN src/thirteen.ts retries forever\n' > "$FIX/a13/memory/backlog.md"
out="$(H status --repo "$FIX/a13")"; rc=$?
{ [ "$rc" -eq 0 ] && case "$out" in OK*) true ;; *) false ;; esac; } \
  && ok "(A13) a backlog with nothing resolved is OK, exit 0" \
  || no "(A13) clean backlog reported as $out (rc=$rc)"

printf -- '- [x] B-A13-DONE [FIXED 1313131] src/thirteen.ts double-counts the budget\n' >> "$FIX/a13/memory/backlog.md"
out="$(H status --repo "$FIX/a13")"; rc=$?
{ [ "$rc" -eq 12 ] && case "$out" in OVERDUE*) true ;; *) false ;; esac; } \
  && ok "(A13) ONE resolved entry is already OVERDUE, exit 12" \
  || no "(A13) one resolved entry reported as $out (rc=$rc)"
case "$out" in *VERBATIM*|*verbatim*) ok "(A13) status says the entry moves verbatim, not deleted" ;;
  *) no "(A13) status never says the history is kept: $out" ;; esac

H archive --repo "$FIX/a13" >/dev/null 2>&1
out="$(H status --repo "$FIX/a13")"; rc=$?
{ [ "$rc" -eq 0 ] && case "$out" in OK*) true ;; *) false ;; esac; } \
  && ok "(A13) status is clean once the entry has been archived" \
  || no "(A13) still $out (rc=$rc) after archiving"

# A ticked entry with NO resolution marker also leaves the open backlog, but into its own section.
# Policy changed deliberately (2026-09-21): holding them back protected an unwritten "why" and kept
# 538 finished entries across 17 files in the list of what is LEFT, indefinitely, waiting for notes
# nobody was going to write. The safeguard is the HEADING, which must say the evidence is only a tick.
printf -- '- [x] B-A13-SILENT src/thirteen.ts sorts the wrong column\n' >> "$FIX/a13/memory/backlog.md"
out="$(H status --repo "$FIX/a13")"; rc=$?
{ [ "$rc" -eq 12 ] && case "$out" in *"ticked without one"*) true ;; *) false ;; esac; } \
  && ok "(A13) an unmarked tick is OVERDUE and counted separately" \
  || no "(A13) silent tick not reported as its own group: $out (rc=$rc)"
H archive --repo "$FIX/a13" >/dev/null 2>&1
grep -q -- "B-A13-SILENT" "$FIX/a13/memory/backlog.md" \
  && no "(A13) the unmarked entry is still in the open backlog" \
  || ok "(A13) the unmarked entry left the open backlog"
grep -q "ticked WITHOUT a recorded resolution" "$FIX/a13/memory/backlog-done.md" \
  && ok "(A13) it landed under a heading that states the reason is missing" \
  || no "(A13) archived without an honest heading — indistinguishable from a documented closure"
# and it must NOT be filed under the heading meant for documented closures
awk '/^## Archived/{h=$0} /B-A13-SILENT/{print h}' "$FIX/a13/memory/backlog-done.md" \
  | grep -q "WITHOUT a recorded resolution" \
  && ok "(A13) the two groups are in different sections" \
  || no "(A13) the unmarked entry sits under the documented-closure heading"

# --- A14 it happens by itself: the run-logger archives, and cannot block a run over housekeeping --
# Two days of zero uptake is the measurement behind this assertion. Prose in an include is not a
# trigger; append-runlog is the one path every skill takes.
RUNLOG="$ROOT/scripts/zuvo-home/append-runlog"
grep -q "backlog-archive.py\" archive --repo" "$RUNLOG" \
  && ok "(A14) append-runlog runs archive, not just verify" \
  || no "(A14) append-runlog never archives — the rule is prose again"
grep -q "ZUVO_NO_AUTO_ARCHIVE" "$RUNLOG" \
  && ok "(A14) the auto-archive has a named opt-out" \
  || no "(A14) no opt-out for the automatic write"
# The namespace gate above it exits 2 on violation; the archive block must not. Anything that can
# refuse to record a completed run over tidiness gets disabled, and then so does the tidiness.
sed -n '/backlog order: finished work/,/^# Skills exempted from retro gate/p' "$RUNLOG" | grep -q "exit " \
  && no "(A14) the auto-archive block can abort the run log" \
  || ok "(A14) auto-archive never blocks the run log"

# --- A15 the contract no longer sells a size threshold -------------------------------------------
for bad in ">= 50 resolved" "100 KB of resolved text"; do
  grep -q -- "$bad" "$INCLUDE" \
    && no "(A15) include still gates archiving on size: $bad" \
    || ok "(A15) include no longer gates archiving on \"$bad\""
done
grep -q "verbatim" "$INCLUDE" \
  && ok "(A15) include states the entry moves verbatim (history kept)" \
  || no "(A15) include never says the archived entry is kept verbatim"


# --- A16 archiving into an inconsistent namespace makes it WORSE, so it is refused ----------------
# verify compares the two files; it cannot see the archive holding the same id twice. So a stale open
# copy of an already-archived entry must not be allowed to move: afterwards both copies sit in the
# archive, verify reports OK, and the duplicate is invisible. This is the ordering rule that keeps
# the 23 real pairs in the canonical backlog a human decision instead of a silent merge.
mkfixture "$FIX/a16"
printf -- '- [x] B-A16-OPEN [FIXED 1616161] src/sixteen.ts loses the header\n' >> "$FIX/a16/memory/backlog.md"
printf -- '- [x] B-A16-OPEN [FIXED 0000000] src/sixteen.ts loses the header\n' >> "$FIX/a16/memory/backlog-done.md"
out="$(H archive --repo "$FIX/a16" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && case "$out" in *"BOTH files"*) true ;; *) false ;; esac; } \
  && ok "(A16) archive refuses while an id is defined in both files" \
  || no "(A16) archived on top of a violation (rc=$rc): $out"
grep -c -- "B-A16-OPEN" "$FIX/a16/memory/backlog-done.md" | grep -qx 1 \
  && ok "(A16) the archive did not gain a second copy" \
  || no "(A16) the archive now holds the id twice"
# the rehearsal must say the same thing as the real run
H archive --repo "$FIX/a16" --dry-run >/dev/null 2>&1 \
  && no "(A16) --dry-run promises a move the real run refuses" \
  || ok "(A16) --dry-run reports the same blocker"


# --- A17 an ordinal id is a POSITION, not an identity --------------------------------------------
# Measured on the first real fleet-wide archive run: B-1..B-9 (codesift-mcp) and B-70..B-79
# (QuotasMobi) each label two different entries, because a plain counter is reused for every fresh
# batch. Keying identity off them reported 14 violations that were not violations. A descriptive id
# must still be an identity, or the guard stops catching the stale copies it exists for.
mkdir -p "$FIX/a17/memory"
printf -- '- [ ] B-70 [robustness] chart-utils.ts pixelToDataIndex returns NaN for a non-finite clientX\n' \
  > "$FIX/a17/memory/backlog.md"
printf -- '- [x] B-70 [FIXED 7070707] src/lib/benchmark/semantic.ts ivfflat probe rejection leak\n' \
  > "$FIX/a17/memory/backlog-done.md"
out="$(H verify --repo "$FIX/a17" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && case "$out" in OK*) true ;; *) false ;; esac; } \
  && ok "(A17) the same ordinal on two different entries is NOT a violation" \
  || no "(A17) ordinal reuse still reads as a namespace violation: $out"

printf -- '- [ ] B-rev-sigterm-leak server-probe SIGTERM stops only the worker\n' >> "$FIX/a17/memory/backlog.md"
printf -- '- [x] B-rev-sigterm-leak (fixed ab753a3) scheduler stopped on SIGTERM via onDrain\n' >> "$FIX/a17/memory/backlog-done.md"
out="$(H verify --repo "$FIX/a17" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && case "$out" in *b-rev-sigterm-leak*) true ;; *) false ;; esac; } \
  && ok "(A17) a DESCRIPTIVE id in both files is still caught" \
  || no "(A17) descriptive id no longer caught (rc=$rc): $out"


# --- A18 drop-stale: the action verify asks for, with the open text kept ---------------------------
# verify says "stale open copy (remove it)" and, before this, offered no safe way to do it — which is
# how 31 real pairs accumulated. The risk it has to defuse: closing an entry REWRITES it into a
# description of the fix, so the open copy is often the only statement of the problem. Deleting it
# outright loses that; re-adding it as a bullet would create a duplicate definition the two-file
# verify cannot see. It is kept as an indented quote instead.
mkdir -p "$FIX/a18/memory"
printf -- '- [ ] B-A18-STALE checks/ssh.ts maps a null exit code to 0 so a killed command reads as success\n' \
  > "$FIX/a18/memory/backlog.md"
printf -- '- [ ] B-A18-LIVE untouched open entry\n' >> "$FIX/a18/memory/backlog.md"
printf -- '- [x] B-A18-STALE (fixed abc1234) null exit code now maps to exit_signal failure\n' \
  > "$FIX/a18/memory/backlog-done.md"
H drop-stale --repo "$FIX/a18" --id B-A18-STALE >/dev/null 2>&1
grep -q -- "B-A18-STALE" "$FIX/a18/memory/backlog.md" \
  && no "(A18) the stale open copy is still in backlog.md" \
  || ok "(A18) the stale open copy left backlog.md"
grep -q -- "B-A18-LIVE" "$FIX/a18/memory/backlog.md" \
  && ok "(A18) the unrelated open entry was not touched" \
  || no "(A18) removed more than the named id"
grep -q "killed command reads as success" "$FIX/a18/memory/backlog-done.md" \
  && ok "(A18) the open copy's problem text is kept in the archive" \
  || no "(A18) the problem statement was destroyed"
[ "$(grep -c -- '^- \[x\] B-A18-STALE' "$FIX/a18/memory/backlog-done.md")" = "1" ] \
  && ok "(A18) the archive did not gain a second definition of the id" \
  || no "(A18) the quoted copy was re-defined as a bullet"
H verify --repo "$FIX/a18" >/dev/null 2>&1 \
  && ok "(A18) the namespace is disjoint afterwards" \
  || no "(A18) verify still reports a violation after drop-stale"

# it must refuse the two shapes where "stale" is not established
printf -- '- [ ] B-A18-NOARCH src/x.ts open only\n' >> "$FIX/a18/memory/backlog.md"
H drop-stale --repo "$FIX/a18" --id B-A18-NOARCH >/dev/null 2>&1 \
  && no "(A18) removed an id the archive never recorded" \
  || ok "(A18) refuses an id that is not in the archive"
printf -- '- [ ] B-A18-SILENT src/y.ts open copy\n' >> "$FIX/a18/memory/backlog.md"
printf -- '- [x] B-A18-SILENT src/y.ts ticked with no resolution marker\n' >> "$FIX/a18/memory/backlog-done.md"
H drop-stale --repo "$FIX/a18" --id B-A18-SILENT >/dev/null 2>&1 \
  && no "(A18) removed an open copy on the word of an unmarked archive entry" \
  || ok "(A18) refuses when the archived copy states no resolution"


# --- A19 RUN the hook, do not grep it -------------------------------------------------------------
# A14 asserts the wiring exists; that was not enough. Executing the installed hook showed the block
# never ran for `backlog`, `deploy`, `canary`, `worktree`, `using-zuvo`, `benchmark` or
# `agent-benchmark`: the retro-gate exemption calls runs_append and exits 0 before reaching it. The
# same hole had silently disabled the namespace gate for those seven skills since it shipped — and
# `backlog` is the skill that writes the file. So this drives append-runlog for real, with ZUVO_HOME
# pointed at a throwaway state dir so the fleet's runs.log is not polluted.
RUNLOG_BIN="$ROOT/scripts/zuvo-home/append-runlog"
mkdir -p "$FIX/a19/memory" "$FIX/a19home"
( cd "$FIX/a19" && git init -q . ) 2>/dev/null
printf -- '- [ ] B-A19-OPEN src/nineteen.ts still broken\n' > "$FIX/a19/memory/backlog.md"
printf -- '- [x] B-A19-DONE [FIXED abc1234] src/nineteen.ts off-by-one — fixed\n' >> "$FIX/a19/memory/backlog.md"
row="$(printf '%s\tbacklog\ta19\t1/1 PASS\t1 files\tOK\t1\t1m\thook end-to-end\t-\t-\t-\t-' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")"
( cd "$FIX/a19" && ZUVO_HOME="$FIX/a19home" ZUVO_BIN="$ROOT/scripts/zuvo-home" \
    sh "$RUNLOG_BIN" "$row" ) >/dev/null 2>&1
[ -s "$FIX/a19home/runs.log" ] \
  && ok "(A19) the hook logged the run to the throwaway state dir" \
  || no "(A19) the hook did not log at all — the fixture is wrong, not the gate"
grep -q -- "B-A19-DONE" "$FIX/a19/memory/backlog-done.md" 2>/dev/null \
  && ok "(A19) a retro-EXEMPT skill still archives (the early exit no longer skips it)" \
  || no "(A19) the resolved entry never moved — the gate sits after an early exit again"
grep -q -- "B-A19-OPEN" "$FIX/a19/memory/backlog.md" \
  && ok "(A19) the open entry stayed open" \
  || no "(A19) the hook moved an entry that is not resolved"
[ "$(awk -F"\t" "\$3==\"a19\"" "$HOME/.zuvo/runs.log" 2>/dev/null | wc -l | tr -d " ")" = "0" ] \
  && ok "(A19) the real runs.log was not touched by the test" \
  || no "(A19) the test polluted the fleet runs.log"


# --- A20 an archived entry that reappears in the open file is SEEN -------------------------------
# Measured an hour after auto-archive went live: tgm-pulse's archive held the same three entries
# TWICE, in two identical sections. A skill rewrote memory/backlog.md from a copy it had read earlier,
# the resolved entries came back, and the next run archived them again. Neither the both-files guard
# nor `verify` noticed, and the reason is subtle: archiving MINTS an id for an entry that lacks one,
# so the archived copy keys as `id:b-a2026…` while the returning open copy keys as `fp:<hash>` — two
# keys that had stopped describing the same thing. Identity now includes the pre-mint content key.
# Note what did NOT catch this: a conservation check that only looks for LOST lines passes happily
# while data is being duplicated.
mkfixture "$FIX/a20"
printf -- '- [x] src/twenty.ts rounds half-up where the spec says half-even — FIXED 2020202\n' \
  >> "$FIX/a20/memory/backlog.md"
H archive --repo "$FIX/a20" >/dev/null 2>&1
grep -q "B-A[0-9]\{8\}-" "$FIX/a20/memory/backlog-done.md" \
  && ok "(A20) the id-less entry got a minted id on the way in" \
  || no "(A20) fixture wrong: nothing was minted, so this asserts nothing"
# the skill puts it back, exactly as it was — without the minted id
printf -- '- [x] src/twenty.ts rounds half-up where the spec says half-even — FIXED 2020202\n' \
  >> "$FIX/a20/memory/backlog.md"
H verify --repo "$FIX/a20" >/dev/null 2>&1 \
  && no "(A20) the returning copy is invisible to verify — identity did not survive minting" \
  || ok "(A20) verify sees the returning copy as a both-files pair"
out="$(H archive --repo "$FIX/a20" 2>&1)"
case "$out" in *"BOTH files"*) ok "(A20) the second pass refuses instead of duplicating" ;;
  *) no "(A20) second pass did not refuse: $out" ;; esac
[ "$(grep -c "rounds half-up" "$FIX/a20/memory/backlog-done.md")" = "1" ] \
  && ok "(A20) the archive still holds exactly one copy" \
  || no "(A20) the archive holds $(grep -c 'rounds half-up' "$FIX/a20/memory/backlog-done.md") copies"

# --- A21 the resolution vocabulary matches what the fleet actually writes --------------------------
# 508 archived entries carried none of the original six markers. The tags on them showed why:
# "WYSLANE fala 5 — PR #83" (191 hits) means the finding went upstream, "[not a bug]" is a verdict,
# and so are ZROBIONE / ROZSTRZYGNIETE / OBALONE. The gap was not cosmetic — `drop-stale` refused a
# 20-id batch over "[not a bug]", and the archiver filed entries under "no recorded resolution" that
# recorded one. The false-positive direction is guarded too: "stale" is an ordinary English word, so
# it counts only inside brackets.
py_marker(){ python3 -c "
import sys; sys.path.insert(0, '$ROOT/scripts/zuvo-home')
import zuvo_backlog_parse as zb
print('YES' if zb.has_resolution_marker(sys.argv[1]) else 'NO')" "$1"; }
for form in "B-X ZROBIONE 2026-09-20 — komentarze poprawione" \
            "B-X [WYSLANE fala 5 — PR #83] moved upstream" \
            "B-X ROZSTRZYGNIETE Z KODU (2026-07-04): appka tworzy lite tylko przy ingest" \
            "B-X [not a bug] checked on develop, the helper does not spread defaults" \
            "B-X OBALONE 2026-09-20, wpis byl NIEPRAWDZIWY"; do
  [ "$(py_marker "$form")" = "YES" ] \
    && ok "(A21) recognised: ${form:0:34}" \
    || no "(A21) NOT recognised as a resolution: $form"
done
[ "$(py_marker "B-X the loader serves a stale cache entry after invalidation")" = "NO" ] \
  && ok "(A21) bare 'stale' in prose is not a resolution" \
  || no "(A21) prose containing 'stale' reads as resolved — unresolved work would be archived as done"
# The measured false positive that forced the wrapped verdicts to OPEN their clause. This exact entry
# was mislabelled by the first version of the widened vocabulary: \bstale\b matches inside
# "stale-index", and the clause was parenthesised, so prose about a bug read as a verdict.
[ "$(py_marker "B-R12 RankingHandler wired to use dragRanking (also fixes inline stale-index bug)")" = "NO" ] \
  && ok "(A21) a parenthesised mention of a stale-index BUG is not a verdict" \
  || no "(A21) prose in brackets reads as a resolution — this archived live work as done"
[ "$(py_marker "B-X [STALE — zweryfikowane w kodzie, fala 2] teza nie potwierdzona")" = "YES" ] \
  && ok "(A21) a clause that OPENS with the verdict still counts" \
  || no "(A21) the narrowing broke the real verdict form"


# --- A22 the archiver must not CREATE a both-files pair -------------------------------------------
# Measured on the canonical backlog, by the archive run itself: one id labelled TWO entries in the
# open file, one ticked and one still open (B-20260905-STAGE1-SMOKE-DRAINING). Moving the ticked one
# put that id in both files, so the very next run was blocked by a violation the archiver produced a
# second earlier. Refusing quietly is not enough either — the report has to say the id is doing two
# jobs, because that is the actual defect in the data.
mkdir -p "$FIX/a22/memory"
printf -- '- [x] B-A22-DUP [FIXED 2222222] src/a.ts first meaning, finished\n' > "$FIX/a22/memory/backlog.md"
printf -- '- [ ] B-A22-DUP src/b.ts second, unrelated meaning, still open\n' >> "$FIX/a22/memory/backlog.md"
printf -- '- [x] B-A22-OK [FIXED 3333333] src/c.ts unrelated finished entry\n' >> "$FIX/a22/memory/backlog.md"
out="$(H archive --repo "$FIX/a22" 2>&1)"
grep -q -- "B-A22-DUP" "$FIX/a22/memory/backlog.md" \
  && ok "(A22) the double-duty id stayed in the open backlog" \
  || no "(A22) archived an id that another open entry still uses"
grep -q -- "B-A22-OK" "$FIX/a22/memory/backlog-done.md" \
  && ok "(A22) the unrelated resolved entry was still archived" \
  || no "(A22) one bad id blocked the whole run"
case "$out" in *"double duty"*) ok "(A22) the report names the id doing two jobs" ;;
  *) no "(A22) skipped it silently: $out" ;; esac
H verify --repo "$FIX/a22" >/dev/null 2>&1 \
  && ok "(A22) the namespace is still disjoint after archiving" \
  || no "(A22) the archive run created the violation it is supposed to prevent"

echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
