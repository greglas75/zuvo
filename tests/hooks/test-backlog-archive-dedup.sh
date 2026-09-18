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

echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
