#!/usr/bin/env bash
# The verdict ledger, and the deterministic pre-pass that fills it: content-keyed staleness, named
# defects, reads that fail CLOSED, a mint write that fails closed the OTHER way, a byte-capped work
# queue and a committed census.
#
# WHAT THIS GUARDS. `memory/backlog.md` records what someone once believed; nothing recorded whether
# it is still true, so every pass re-spent the judgement the last pass made (387 entries here). The
# ledger makes a verdict survive between runs — and the moment a verdict survives, a WRONG one
# survives too. The direction of failure is therefore not symmetric: a corrupt line read as
# "verified" closes an entry nobody examined, while the same line read as "unverified" produces a
# refusal someone looks at. Every fail-closed assertion below is about keeping that asymmetry.
#
# FOUR HARNESS RULES, each paid for by a false green in this repo:
#   * `set -uo pipefail`, never `set -e` — a 0 -> 1 counter step exits under `-e` and aborted a suite
#     before it could report its own failure.
#   * `command_not_found_handle` CANNOT increment a counter: bash runs it in a SUBSHELL, so
#     `FAIL=$((FAIL+1))` is discarded. The evidence has to cross the subshell boundary, and a FILE is
#     the only thing that does — hence CNFH_MARK and `finish`.
#   * NO `SKIP:` PATH. python3 and the three modules are stated prerequisites of this repo. A missing
#     precondition is a `no` then `finish`; `tests/run-all.sh` classifies exit 0 plus a leading
#     `SKIP:` as SKIP, and a SKIP never fails the run.
#   * EVERY assertion below has a MUTANT that reverts only its behaviour (group M), and the mutant
#     factory HARD-ERRORS when a substitution does not apply exactly once — otherwise "the mutant
#     passed" silently means "the mutation was never made".
#
# NO VACUOUS ASSERTIONS. Each negative group is preceded by a positive control on the SAME fixture:
# the base row is shown to validate before a field is broken, the terminated ledger is shown to read
# as N rows before the terminator is removed, the two-writer rows are shown to share a key and a sha
# before dedup is asserted. A probe that tested for the literal characters `\`+`n` instead of a
# newline once printed `ok` over a live corruption; that is the class this rule exists for.
#
# THE FIXTURE TREE IS NOT REMOVED. It lives under $TMPDIR (OS-reaped) and holds git repos, lock dirs
# and a deliberately corrupt ledger; a recursive delete is the one command in this file that must
# never be misaimed, and its only benefit is a few kilobytes. The path is printed at the end so a
# failing run can be inspected instead of re-created.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
LEDGER_MOD="$ROOT/scripts/zuvo-home/zuvo_backlog_ledger.py"
PARSE_MOD="$ROOT/scripts/zuvo-home/zuvo_backlog_parse.py"
IO_MOD="$ROOT/scripts/zuvo-home/zuvo_backlog_io.py"
INCLUDE="$ROOT/shared/includes/backlog-grooming.md"
PROTOCOL="$ROOT/shared/includes/backlog-protocol.md"
SEVERITY="$ROOT/shared/includes/severity-vocabulary.md"

# The lock wait is the only thing this shortens: the held-lock assertions below would otherwise sit
# out the 5 s default twice. It changes no behaviour under test — nothing here contends for real.
export ZUVO_LOCK_WAIT=0.5

PASS=0; FAIL=0
ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

FIX="$(mktemp -d "${TMPDIR:-/tmp}/zuvo-backlog-groom.XXXXXX")"
# Canonicalise once: on macOS $TMPDIR is /var/folders/... and /var is a symlink to /private/var, so
# the helpers (which resolve real paths, correctly) answer /private/var/... while every comparison
# here would hold the unresolved form. Linux has no such symlink, which is why the farm never sees it.
FIX="$(cd "$FIX" && pwd -P)"

CNFH_MARK="$FIX/.cnfh"
command_not_found_handle(){
  echo "  FAIL harness: unknown command '$1'"
  printf '%s\n' "$1" >> "$CNFH_MARK"
  return 127
}

finish(){
  if [ -s "$CNFH_MARK" ]; then
    no "(G0) unknown command(s) ran: $(sort -u "$CNFH_MARK" | tr '\n' ' ')— a misspelled helper prints and returns 127 in a SUBSHELL, so every assertion that used it checked nothing"
  fi
  echo "fixtures: $FIX"
  echo "RESULT: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

echo "== backlog verdict ledger =="

# --- G0 preconditions: the harness guarantee, then the modules. No SKIP on any of them. -----------
if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
  ok "(G0) bash ${BASH_VERSION%%(*} is 4+ — command_not_found_handle fires, typo protection is live"
else
  no "(G0) bash ${BASH_VERSION%%(*} predates command_not_found_handle (bash 4+): a misspelled helper returns 127 and writes no marker, so this file's FAIL count proves nothing — re-run under bash >= 4"
  finish
fi

for f in "$LEDGER_MOD" "$PARSE_MOD" "$IO_MOD" "$INCLUDE" "$PROTOCOL" "$SEVERITY"; do
  [ -f "$f" ] && ok "(G0) present: ${f#"$ROOT"/}" || { no "(G0) missing: ${f#"$ROOT"/} — nothing below can be checked"; finish; }
done

CTL="$FIX/ctl"
mkdir -p "$CTL"
cp "$LEDGER_MOD" "$PARSE_MOD" "$IO_MOD" "$CTL/"

# ================================================================================================
# The probe. ONE script, run against the control copy or a mutant copy, printing KEY=value lines.
# It takes the module directory as argv[1] so a mutant is reached by POINTING at it, never by
# editing the repo file: editing a module the suite has already imported corrupts the run it is in.
# ================================================================================================
PROBE="$FIX/probe.py"
cat > "$PROBE" <<'PYEOF'
r"""Machine-readable probe over zuvo_backlog_ledger. RAW docstring: the modes below quote regex-ish
text, and a `\s` in a plain docstring is a SyntaxWarning on stderr — which every caller here would
read as "the mutant did not build", because that is exactly how a build failure looks.

Usage: probe.py <moddir> <mode> [args...]
"""
import json
import os
import sys

sys.path.insert(0, sys.argv[1])
import zuvo_backlog_ledger as L      # noqa: E402
import zuvo_backlog_parse as zb      # noqa: E402


def out(key, value):
    print("%s=%s" % (key, value))


def base_row():
    """The row every schema case starts from. Its own shape is ASSERTED by the caller before any
    field is broken, so a rejection below cannot be a rejection of the base."""
    return {
        "id": "B-A20260929-abc123",
        "keys": ["fp:0123456789ab", "id:b-a20260929-abc123"],
        "text_sha": "a" * 40,
        "verdict": "STILL-REAL",
        "evidence": "scripts/zuvo-home/zuvo_backlog_io.py:123 atomic_write follows a planted symlink",
        "verified_at": "2026-09-29T10:00:00+00:00",
        "verified_by": "deterministic:marker",
        "disposition": "pending",
    }


def schema_cases():
    cases = []

    def add(name, **changes):
        row = base_row()
        for k, v in changes.items():
            if v is None and k != "_none":
                row.pop(k, None)
            else:
                row[k] = v
        cases.append((name, row))

    add("valid")
    add("noid", id=None)
    add("emptyid", id="   ")
    add("nokeys", keys=[])
    add("badkey", keys=["B-alpha"])
    add("sha39", text_sha="a" * 39)
    add("shaupper", text_sha="A" * 40)
    add("badverdict", verdict="STALE")
    add("stillnoloc", evidence="the symlink hole is still open in the io layer")
    add("stillloc", evidence="still open: zuvo_backlog_io.py:123")
    add("dupnokey", verdict="DUPLICATE-OF", evidence="the same thing as the other one, lines 44/912")
    add("dupkey", verdict="DUPLICATE-OF",
        evidence="fp:0123456789ab — backlog.md:44 and backlog.md:912 describe one defect")
    add("noevidence", evidence="   ")
    add("badby", verified_by="bob")
    add("baddisp", disposition="closed")
    add("nodisp", disposition=None)
    add("obsolete", verdict="STALE-OBSOLETE",
        evidence='backlog.md:44 "apps/legacy/old.ts" does not exist')
    add("notverifiable", verdict="NOT-VERIFIABLE", evidence="the repo does not say either way")
    return cases


def entries_of(path):
    with open(path, encoding="utf-8") as fh:
        return list(zb.iter_entries(fh.read()))


def write_ac1_fixture(backlog, dest):
    """The AC1 fixture: SEVEN rows carrying nine shapes, every sha DERIVED from the backlog.

    Row 7 is truncated mid-JSON and carries no terminating newline, so the file ends the way a
    killed writer ends it. Nothing here is hardcoded from a plan document; the census the caller
    verifies against the bytes is printed below.
    """
    ents = {(e.ident or e.key): e for e in entries_of(backlog)}
    idless = [k for k in ents if k.startswith("fp:")]
    alpha, beta, delta = ents["B-alpha-reuse"], ents["B-beta-drift"], ents["B-delta-notver"]
    dup = ents[idless[0]]
    stale_sha = "b" * 40

    def row(ident, keys, sha, verdict, evidence, at, by="agent:opus"):
        return {"id": ident, "keys": sorted(keys), "text_sha": sha, "verdict": verdict,
                "evidence": evidence, "verified_at": at, "verified_by": by,
                "disposition": "pending"}

    rows = [
        row("B-alpha-reuse", zb.keys_for(alpha.body, alpha.ident), L.text_sha(alpha.body),
            "STILL-REAL", "scripts/zuvo-home/zuvo_backlog_io.py:123 the temp name is predictable",
            "2026-09-28T08:00:00+00:00"),
        row("B-beta-drift", zb.keys_for(beta.body, beta.ident), stale_sha,
            "STALE-FIXED", "shared/includes/backlog-protocol.md:243 the ledger is now named",
            "2026-09-28T08:01:00+00:00"),
        row("B-deleted-long-ago", ["id:b-deleted-long-ago"], "c" * 40,
            "STALE-OBSOLETE", 'backlog.md:9 "apps/legacy/gone.ts" does not exist',
            "2026-09-28T08:02:00+00:00"),
        row(dup.key, zb.keys_for(dup.body, dup.ident), L.text_sha(dup.body),
            "DUPLICATE-OF", "fp:0123456789ab — backlog.md:8 and backlog.md:44 are one defect",
            "2026-09-28T08:03:00+00:00"),
        row("B-delta-notver", zb.keys_for(delta.body, delta.ident), L.text_sha(delta.body),
            "NOT-VERIFIABLE", "the repo does not answer: the provider is external",
            "2026-09-28T08:04:00+00:00"),
        row("B-alpha-reuse", zb.keys_for(alpha.body, alpha.ident), L.text_sha(alpha.body),
            "STILL-REAL", "scripts/zuvo-home/zuvo_backlog_io.py:123 second writer, same text",
            "2026-09-28T09:00:00+00:00", by="agent:sonnet"),
    ]
    body = "".join(json.dumps(r, sort_keys=True) + "\n" for r in rows)
    truncated = json.dumps(rows[4], sort_keys=True)[:60]
    with open(dest, "w", encoding="utf-8") as fh:
        fh.write(body + truncated)

    out("NROWS_WRITTEN", len(rows) + 1)
    out("BETA_CURRENT_SHA", L.text_sha(beta.body))
    out("BETA_LEDGER_SHA", stale_sha)
    out("DUP_KEY", dup.key)
    for i, r in enumerate(rows, start=1):
        print("CENSUS=row%d verdict=%s keys=%s sha=%s" % (i, r["verdict"], "+".join(r["keys"]),
                                                          r["text_sha"][:8]))
    print("CENSUS=row7 verdict=<truncated> keys=<none> sha=<none>")
    shapes = ["verdict:" + v for v in L.VERDICTS]
    shapes += ["stale-sha:row2", "orphan-key:row3", "two-writer-duplicate:row1+row6",
               "truncated-line:row7"]
    out("SHAPES", ",".join(shapes))
    out("NSHAPES", len(shapes))


def main():
    mode = sys.argv[2]
    rest = sys.argv[3:]
    if mode == "vocab":
        out("VERDICTS", "|".join(L.VERDICTS))
        out("NVERDICTS", len(L.VERDICTS))
        out("DISPOSITIONS", "|".join(L.DISPOSITIONS))
        out("FIELDS", "|".join(L.FIELDS))
        out("LEDGER_NAME", L.LEDGER_NAME)
    elif mode == "schema":
        for name, row in schema_cases():
            probs = L.validate_row(row, "case:" + name)
            print("CASE=%s n=%d first=%s" % (name, len(probs), probs[0] if probs else "-"))
    elif mode == "read":
        r = L.read_ledger(rest[0])
        out("LINES", r.lines)
        out("ROWS", len(r.rows))
        out("NDEFECTS", len(r.defects))
        for d in r.defects:
            print("DEFECT=" + d)
        for row in r.rows:
            print("ROWID=%s|%s|%s" % (row.get("id"), row.get("verdict"), row.get("verified_by")))
    elif mode == "plan":
        ents = entries_of(rest[0])
        r = L.read_ledger(rest[1])
        p = L.plan_reuse(ents, r.rows)
        out("NENTRIES", len(ents))
        out("REUSE", ",".join(e.ident or e.key for e, _ in p.reuse))
        out("REVERIFY", ",".join(e.ident or e.key for e, _ in p.reverify))
        out("FRESH", ",".join(e.ident or e.key for e in p.fresh))
        out("NORPHANS", len(p.orphans))
        for o in p.orphans:
            print("ORPHAN=" + o)
        verified, total, short = L.coverage(ents, r.rows)
        out("COVERAGE", "%d/%d" % (verified, total))
        out("SHORT", ",".join(short))
    elif mode == "append":
        with open(rest[1], encoding="utf-8") as fh:
            rows = json.load(fh)
        n, defects = L.append_rows(rest[0], rows)
        out("APPENDED", n)
        out("PREEXISTING_DEFECTS", len(defects))
    elif mode == "paths":
        real, ledger = L.ledger_paths(rest[0])
        out("REAL", real)
        out("LEDGER", ledger)
        out("LEDGER_EXISTS", os.path.exists(ledger))
    elif mode == "sha":
        ents = entries_of(rest[0])
        for e in ents:
            print("ENTRY=%s|%s" % (e.ident or e.key, L.text_sha(e.body)))
    elif mode == "fixture":
        write_ac1_fixture(rest[0], rest[1])
    else:
        sys.exit("probe: unknown mode %r" % mode)


main()
PYEOF

# ================================================================================================
# The mutant factory. Every substitution is COUNTED and a miss is a hard error: a mutation that
# silently failed to apply would make the assertion reading it pass for the wrong reason, which is
# the defect class this whole block exists to rule out.
# ================================================================================================
MKMUT="$FIX/mkmut.py"
cat > "$MKMUT" <<'PYEOF'
r"""Write a named mutation of zuvo_backlog_ledger.py, beside untouched copies of the two modules it
imports, into its own directory.

RAW docstring for the same reason as the probe's: a `\s` in a plain one is a SyntaxWarning on
stderr, and every caller here reads stderr as "the mutant did not build".

Usage: mkmut.py <ledger.py> <parse.py> <io.py> <kind> <outdir>

The ledger and its two siblings must ALL sit in the output directory: the module imports them by
name and nothing puts the importer's directory on sys.path for it, so a missing sibling fails at
IMPORT — an import error wearing a mutation's clothes.

  none            byte-identical copies: the CONTROL, so a failing mutant proves the MUTATION failed
                  and not the copy mechanics
  vocab6          a sixth verdict token, against "the vocabulary is closed at five"
  nostillloc      the `STILL-REAL` needs a `path:line` check is disabled
  shalax          `text_sha` accepts any hex length, not exactly 40
  nokeys          the `keys` shape check is disabled
  nodup           the `DUPLICATE-OF` must name a key check is disabled
  trunctolerant   the missing-terminator test is disabled: a truncated tail reads as a verdict
  silentdrop      unparseable JSON is skipped WITHOUT a defect — the silent drop
  schemasilent    a schema-invalid row is skipped WITHOUT a defect
  noorphan        `plan_reuse` reports no orphans: a verdict whose entry vanished disappears quietly
  shablind        reuse ignores `text_sha`, so a key match alone is "verified" — the TTL-less
                  invalidation removed
  dedupfirst      `_dedup` keeps the EARLIER `verified_at`
  dedupsha        `_dedup` identity drops the sha, so a re-verification overwrites its predecessor
  noplacement     the tracked-ledger-beside-ignored-backlog refusal is deleted
  nonamed         the refusal no longer names the LEDGER file, only the archive
  nomode          the ledger stops inheriting the source's file mode
  nolock          the write no longer takes the backlog's lock
  prevalidate     an invalid incoming row is no longer refused before the lock
  fponly          `_KEY_RE` admits only `id:` keys, so a content-keyed entry could carry no verdict
  shaonraw        `text_sha` hashes the RAW body, so closing an entry invalidates its own verdict
"""
import os
import shutil
import sys

LEDGER, PARSE, IO, KIND, OUT = sys.argv[1:6]

VERDICT_TUPLE = ("VERDICTS: Tuple[str, ...] = (VERDICT_STILL_REAL, VERDICT_STALE_FIXED, "
                 "VERDICT_STALE_OBSOLETE,\n                             VERDICT_DUPLICATE_OF, "
                 "VERDICT_NOT_VERIFIABLE)")
STILL_LOC = "    if verdict == VERDICT_STILL_REAL and not evidence_locations(evidence):"
SHA_RE = '_SHA_RE = re.compile(r"^[0-9a-f]{40}$")'
TEXT_SHA = ('    return hashlib.sha1(zb.strip_resolution_markers(body)'
            '.encode("utf-8")).hexdigest()')
KEY_RE = '_KEY_RE = re.compile(r"^(?:id:[\\w.-]+|fp:[0-9a-f]{12})$")'
KEYS_CHECK = ("    if (not isinstance(keys, list) or not keys\n"
              "            or not all(isinstance(k, str) and _KEY_RE.match(k) for k in keys)):")
DUP_CHECK = "    if verdict == VERDICT_DUPLICATE_OF and not _KEY_IN_TEXT_RE.search(evidence):"
TERMINATOR = "        if not terminated and i == len(lines):"
JSON_EXCEPT = ('        except ValueError as exc:\n'
               '            defects.append(f"{where}: unparseable JSON ({exc}) — reads UNVERIFIED")\n'
               '            continue')
SCHEMA_DEFECT = ("        problems = validate_row(obj, where)\n"
                 "        if problems:\n"
                 "            defects.extend(problems)\n"
                 "            continue")
ORPHANS = "    orphans = [_orphan_defect(rows[i]) for i in range(len(rows)) if i not in matched]"
EXACT = '        exact = next((i for i in idx if rows[i].get("text_sha") == sha), None)'
DEDUP_CMP = '        if str(row.get("verified_at", "")) >= str(chosen[hit].get("verified_at", "")):'
DEDUP_IDS = '        ids = [(str(k), sha) for k in row.get("keys", [])]'
PLACEMENT = "    if zio.is_ignored(real) and zio.is_ignored(ledger) is False:"
NAMED = '                 f"    /memory/{LEDGER_NAME}\\n"'
MODE_LINE = ("            mode = os.stat(real).st_mode & 0o7777     "
             "# inherit the source's visibility AND its mode")
LOCK_LINE = "    with zio.Lock(os.path.dirname(real)):"
PREVALIDATE = ('    if bad:\n'
               '        sys.exit("refusing to append an invalid verdict row:\\n  " '
               '+ "\\n  ".join(bad))')

MUTATIONS = {
    "vocab6": (VERDICT_TUPLE, VERDICT_TUPLE[:-1] + ', "MAYBE-REAL")'),
    "nostillloc": (STILL_LOC, "    if False and not evidence_locations(evidence):"),
    "shalax": (SHA_RE, '_SHA_RE = re.compile(r"^[0-9a-f]+$")'),
    "nokeys": (KEYS_CHECK, "    if False:"),
    "nodup": (DUP_CHECK, "    if False:"),
    "trunctolerant": (TERMINATOR, "        if False:"),
    "silentdrop": (JSON_EXCEPT, "        except ValueError:\n            continue"),
    "schemasilent": (SCHEMA_DEFECT, "        problems = validate_row(obj, where)\n"
                                    "        if problems:\n"
                                    "            continue"),
    "noorphan": (ORPHANS, "    orphans = []"),
    "shablind": (EXACT, "        exact = idx[0] if idx else None"),
    "dedupfirst": (DEDUP_CMP, '        if str(row.get("verified_at", "")) < '
                              'str(chosen[hit].get("verified_at", "")):'),
    "dedupsha": (DEDUP_IDS, '        ids = [(str(k), "") for k in row.get("keys", [])]'),
    "noplacement": (PLACEMENT, "    if False:"),
    "nonamed": (NAMED, '                 f"    /memory/done.md\\n"'),
    "nomode": (MODE_LINE, "            mode = None"),
    "nolock": (LOCK_LINE, "    if True:"),
    "prevalidate": (PREVALIDATE, "    if bad:\n        pass"),
    # `_KEY_RE` admitting only `id:` keys. This is the one-line change that would have FORCED Task 2 to
    # mint: with it a content-keyed entry could carry no verdict at all, which is exactly the premise
    # plan revision 6 refuted by measuring that `fp:` is first-class in this ledger.
    "fponly": (KEY_RE, '_KEY_RE = re.compile(r"^id:[\\w.-]+$")'),
    # `text_sha` over the RAW body instead of the resolution-stripped one. This is what would make
    # `groom`'s own closure edit invalidate the verdict it proves — the exact thing the stripping
    # exists to prevent, and half of why a prepended `[DONE …]` marker is FREE.
    "shaonraw": (TEXT_SHA, '    return hashlib.sha1(body.encode("utf-8")).hexdigest()'),
}


def sub(src, old, new, what):
    if src.count(old) != 1:
        sys.exit("mkmut: %s occurs %dx, expected once — the mutation would not apply: %r"
                 % (what, src.count(old), old))
    return src.replace(old, new)


os.makedirs(OUT, exist_ok=True)
for path in (PARSE, IO):
    shutil.copyfile(path, os.path.join(OUT, os.path.basename(path)))
with open(LEDGER, encoding="utf-8") as fh:
    text = fh.read()
if KIND != "none":
    if KIND not in MUTATIONS:
        sys.exit("mkmut: unknown mutation %r" % KIND)
    old, new = MUTATIONS[KIND]
    text = sub(text, old, new, KIND)
with open(os.path.join(OUT, os.path.basename(LEDGER)), "w", encoding="utf-8") as fh:
    fh.write(text)
PYEOF

probe(){ python3 "$PROBE" "$@"; }

# Build the control copy through the SAME factory, so "the control passes" also proves the copy
# mechanics. A control that fails means every mutant below proves nothing.
if python3 "$MKMUT" "$LEDGER_MOD" "$PARSE_MOD" "$IO_MOD" none "$FIX/mut-none" >"$FIX/mknone.log" 2>&1; then
  ok "(G0) the mutant factory writes its CONTROL copy — a failing mutant below is a mutation, not a copy"
else
  no "(G0) the mutant factory cannot even write an unmutated copy ($(tail -1 "$FIX/mknone.log")) — every mutant assertion would be vacuous"
  finish
fi

if probe "$CTL" vocab >"$FIX/vocab.out" 2>"$FIX/vocab.err"; then
  ok "(G0) the module imports and the probe runs"
else
  no "(G0) the probe could not run: $(tail -2 "$FIX/vocab.err") — nothing below can be checked"
  finish
fi

# ================================================================================================
# V — the vocabulary: closed at five, documented, and NOT in severity-vocabulary.md
# ================================================================================================
echo "-- V: the closed verdict vocabulary --"
V_EXPECT='STILL-REAL|STALE-FIXED|STALE-OBSOLETE|DUPLICATE-OF|NOT-VERIFIABLE'
grep -qx "NVERDICTS=5" "$FIX/vocab.out" \
  && ok "(V1) the vocabulary holds exactly 5 verdicts" \
  || no "(V1) NVERDICTS is $(grep '^NVERDICTS=' "$FIX/vocab.out") — decision 1 closes it at 5"
grep -qxF "VERDICTS=$V_EXPECT" "$FIX/vocab.out" \
  && ok "(V1b) the five tokens are exactly the documented set" \
  || no "(V1b) the tokens are $(grep '^VERDICTS=' "$FIX/vocab.out"), expected $V_EXPECT"
grep -qxF "DISPOSITIONS=pending|archived|dropped|kept|no-remedy" "$FIX/vocab.out" \
  && ok "(V1c) the disposition set includes no-remedy — 'nothing performable here' is reported as itself" \
  || no "(V1c) dispositions are $(grep '^DISPOSITIONS=' "$FIX/vocab.out")"
grep -qxF "FIELDS=id|keys|text_sha|verdict|evidence|verified_at|verified_by|disposition" "$FIX/vocab.out" \
  && ok "(V1d) the row schema is decision 3's eight fields, in order" \
  || no "(V1d) fields are $(grep '^FIELDS=' "$FIX/vocab.out")"
grep -qxF "LEDGER_NAME=backlog-verdicts.jsonl" "$FIX/vocab.out" \
  && ok "(V1e) the ledger is backlog-verdicts.jsonl — undated and not .md, so it cannot read as a banned snapshot" \
  || no "(V1e) $(grep '^LEDGER_NAME=' "$FIX/vocab.out")"

# AC2, both directions. The negative alone is satisfied by a misspelled pattern, so the SAME pattern
# is required to match where the tokens DO live.
if grep -qE "$V_EXPECT" "$SEVERITY"; then
  no "(V2) severity-vocabulary.md names a verdict token — that file maps IMPACT, this maps EXISTENCE, and audit-registry-integrity.py validates its rows"
else
  ok "(V2) none of the five verdicts leaked into severity-vocabulary.md"
fi
if grep -qE "$V_EXPECT" "$INCLUDE"; then
  ok "(V2b) the SAME pattern matches backlog-grooming.md — V2's negative is not a typo passing over an unreachable regex"
else
  no "(V2b) the pattern does not match backlog-grooming.md either, so V2 proves nothing about where the tokens live"
fi
V_MISSING=""
for v in STILL-REAL STALE-FIXED STALE-OBSOLETE DUPLICATE-OF NOT-VERIFIABLE; do
  grep -qF "$v" "$INCLUDE" || V_MISSING="$V_MISSING $v"
done
[ -z "$V_MISSING" ] \
  && ok "(V3) all five verdicts are documented in backlog-grooming.md" \
  || no "(V3) backlog-grooming.md does not document:$V_MISSING"

# ================================================================================================
# S — the schema. A failing row is a DEFECT, never a skip.
# ================================================================================================
echo "-- S: row schema validation --"
probe "$CTL" schema >"$FIX/schema.out" 2>&1
sc(){ grep -E "^CASE=$1 " "$FIX/schema.out"; }
sn(){ sc "$1" | sed -E 's/^CASE=[^ ]+ n=([0-9]+) .*/\1/'; }

# VACUITY FIRST: the base row must validate, and it must really have the shape the negatives break.
if [ "$(sn valid)" = "0" ]; then
  ok "(S0) the base row validates — every rejection below is a rejection of the CHANGE, not of the base"
else
  no "(S0) the base row is already rejected ($(sc valid)) — every negative below would pass vacuously"
  finish
fi
[ "$(sn nodisp)" = "0" ] \
  && ok "(S0b) \`disposition\` is the one optional field (it defaults to pending)" \
  || no "(S0b) a row without \`disposition\` was rejected: $(sc nodisp)"
[ "$(sn obsolete)" = "0" ] && [ "$(sn notverifiable)" = "0" ] \
  && ok "(S0c) STALE-OBSOLETE and NOT-VERIFIABLE validate without a production path:line — the path-line rule is scoped, not global" \
  || no "(S0c) a verdict that legitimately cites no production path was rejected: $(sc obsolete) / $(sc notverifiable)"

s_reject(){  # case, label, substring the message must contain
  local n; n="$(sn "$1")"
  if [ -z "$n" ]; then no "(S) case '$1' did not run — the probe printed no CASE line"; return; fi
  if [ "$n" = "0" ]; then no "(S) $2: case '$1' was ACCEPTED"; return; fi
  if sc "$1" | grep -qF -- "$3"; then
    ok "(S) $2 (message names '$3')"
  else
    no "(S) $2 was rejected but the message does not name '$3': $(sc "$1")"
  fi
}
s_reject noid        "a row with no \`id\` is a defect"                     'missing field(s) id'
s_reject emptyid     "a whitespace \`id\` is a defect"                      '`id` is empty'
s_reject nokeys      "an empty \`keys\` list is a defect"                   '`keys` must be'
s_reject badkey      "a key that is not id:/fp: is a defect"                '`keys` must be'
s_reject sha39       "a 39-hex \`text_sha\` is a defect"                    'not 40 lowercase hex'
s_reject shaupper    "an UPPERCASE \`text_sha\` is a defect"                'not 40 lowercase hex'
s_reject badverdict  "a verdict outside the closed five is a defect"        'outside the closed set'
s_reject stillnoloc  "STILL-REAL with no path:line is INVALID"             'without a `path:line`'
s_reject dupnokey    "DUPLICATE-OF that names no key is a defect"          'must name the other'
s_reject noevidence  "an empty \`evidence\` is a defect"                    '`evidence` is empty'
s_reject badby       "a free-form \`verified_by\` is a defect"              'deterministic:'
s_reject baddisp     "a disposition outside the five is a defect"          'is outside'

# The two path-shaped rules need their positive twin on the SAME text, or "rejected" could be about
# anything in the row.
[ "$(sn stillloc)" = "0" ] \
  && ok "(S1) the SAME STILL-REAL prose with a path:line added is ACCEPTED — the rule is the citation, not the wording" \
  || no "(S1) STILL-REAL with a path:line was still rejected: $(sc stillloc)"
[ "$(sn dupkey)" = "0" ] \
  && ok "(S1b) the SAME DUPLICATE-OF prose naming an fp: key is ACCEPTED" \
  || no "(S1b) DUPLICATE-OF naming a key was still rejected: $(sc dupkey)"

# ================================================================================================
# The fixtures: one backlog, and the AC1 seven-row ledger derived from it.
# ================================================================================================
BL="$FIX/backlog.md"
cat > "$BL" <<'EOF'
# Tech Debt Backlog

## Open

- [ ] B-alpha-reuse scripts/zuvo-home/zuvo_backlog_io.py atomic_write still follows a planted symlink
- [ ] B-beta-drift shared/includes/backlog-protocol.md the refusal message omits the ledger sibling
- [ ] B-gamma-fresh tests/hooks/test-backlog-headings.sh the mutant factory does not count substitutions
- [ ] B-delta-notver vendor/provider.ts the upstream rate limit is undocumented
- [ ] tools/seed.py a content-keyed entry carrying no identifier at all
EOF

LED="$FIX/ac1-ledger.jsonl"
if probe "$CTL" fixture "$BL" "$LED" >"$FIX/fixture.out" 2>"$FIX/fixture.err"; then
  ok "(G0b) the AC1 fixture ledger was written"
else
  no "(G0b) the AC1 fixture could not be built: $(tail -2 "$FIX/fixture.err") — the AC1 group cannot run"
  finish
fi

# ---- the CENSUS, verified against the BYTES ------------------------------------------------------
# A printed census is a CLAIM. Every line below re-derives the same fact from the file itself, so a
# census that drifted from what was written fails here rather than reading as evidence.
echo "-- C: the seven-row fixture census, checked against the file --"
cat "$FIX/fixture.out"
C_LINES="$(awk 'END{print NR}' "$LED")"
[ "$C_LINES" = "7" ] \
  && ok "(C1) the fixture is 7 lines on disk (awk counts the unterminated last one; wc -l would say 6)" \
  || no "(C1) the fixture is $C_LINES lines, not 7"
C_MISS=""
for v in STILL-REAL STALE-FIXED STALE-OBSOLETE DUPLICATE-OF NOT-VERIFIABLE; do
  grep -qF "\"verdict\": \"$v\"" "$LED" || C_MISS="$C_MISS $v"
done
[ -z "$C_MISS" ] \
  && ok "(C2) all five verdicts are physically present in the fixture" \
  || no "(C2) the fixture never held:$C_MISS — the per-verdict assertions would pass over a case it does not contain"
C_STILL="$(grep -cF '"verdict": "STILL-REAL"' "$LED")"
[ "$C_STILL" = "2" ] \
  && ok "(C3) STILL-REAL appears twice — the two-writer duplicate really is in the file" \
  || no "(C3) STILL-REAL appears $C_STILL time(s); the dedup assertions need two"
# A command substitution strips trailing newlines, so an EMPTY result here means the last byte WAS a
# newline. This is the assertion a probe once faked by testing for the two characters `\` and `n`.
if [ -n "$(tail -c 1 "$LED")" ]; then
  ok "(C4) the fixture's last byte is not a newline — the file ends the way a killed writer ends it"
else
  no "(C4) the fixture ends with a newline, so there is no truncated line to fail closed on"
fi
C_BETA_NOW="$(sed -n 's/^BETA_CURRENT_SHA=//p' "$FIX/fixture.out")"
C_BETA_LED="$(sed -n 's/^BETA_LEDGER_SHA=//p' "$FIX/fixture.out")"
if [ -n "$C_BETA_NOW" ] && [ "$C_BETA_NOW" != "$C_BETA_LED" ] && grep -qF "$C_BETA_LED" "$LED"; then
  ok "(C5) row 2's sha (${C_BETA_LED:0:8}) differs from B-beta-drift's current sha (${C_BETA_NOW:0:8}) — the stale-sha shape is real"
else
  no "(C5) the stale-sha row is not stale: ledger=${C_BETA_LED:0:8} current=${C_BETA_NOW:0:8}"
fi
if grep -qF 'id:b-deleted-long-ago' "$LED" && ! grep -qF 'b-deleted-long-ago' "$BL"; then
  ok "(C6) row 3's key names an entry the backlog does not contain — the orphan shape is real"
else
  no "(C6) the orphan key either is missing from the ledger or DOES exist in the backlog"
fi
C_NSHAPES="$(sed -n 's/^NSHAPES=//p' "$FIX/fixture.out")"
[ "$C_NSHAPES" = "9" ] \
  && ok "(C7) the census reports 9 shapes over 7 rows (5 verdicts + stale sha + orphan + duplicate + truncation)" \
  || no "(C7) the census reports $C_NSHAPES shapes"

# ================================================================================================
# R — reading the ledger: fail CLOSED
# ================================================================================================
echo "-- R: reads fail closed --"
probe "$CTL" read "$LED" >"$FIX/read.out" 2>&1
rv(){ sed -n "s/^$1=//p" "$FIX/read.out" | head -1; }
[ "$(rv LINES)" = "7" ] \
  && ok "(R0) the reader saw all 7 lines" \
  || no "(R0) the reader saw $(rv LINES) lines, not 7"
[ "$(rv ROWS)" = "5" ] \
  && ok "(R1) 7 lines yield 5 usable rows — 6 valid, the two writers of one text deduped, the truncated one excluded" \
  || no "(R1) 7 lines yielded $(rv ROWS) rows, expected 5"
if grep -q '^DEFECT=.*:7: final line is not newline-terminated' "$FIX/read.out"; then
  ok "(R2) the truncated final line is a NAMED defect at line 7, reading UNVERIFIED"
else
  no "(R2) no named truncation defect: $(grep -c '^DEFECT=' "$FIX/read.out") defect(s) — $(grep '^DEFECT=' "$FIX/read.out" | head -1)"
fi
grep -q '^ROWID=B-delta-notver|NOT-VERIFIABLE' "$FIX/read.out" \
  && ok "(R2b) the truncated line is a PREFIX of row 5, and row 5 itself still reads — the exclusion is scoped to the broken line, not to everything that resembles it" \
  || no "(R2b) B-delta-notver is not among the rows: $(grep '^ROWID=' "$FIX/read.out" | tr '\n' ' ')"

# The three read-time fail-closed cases, each on its own minimal file, so one mutant kills one.
printf '%s\n' '{"id":"B-ok","keys":["id:b-ok"],"text_sha":"'"$(printf 'd%.0s' $(seq 1 40))"'","verdict":"NOT-VERIFIABLE","evidence":"no answer","verified_at":"2026-09-29T00:00:00+00:00","verified_by":"agent:x","disposition":"pending"}' > "$FIX/one.jsonl"
probe "$CTL" read "$FIX/one.jsonl" >"$FIX/one.out" 2>&1
[ "$(sed -n 's/^ROWS=//p' "$FIX/one.out" | head -1)" = "1" ] \
  && ok "(R3) control: a terminated one-row ledger reads as 1 row, 0 defects" \
  || no "(R3) a well-formed one-row ledger read as $(sed -n 's/^ROWS=//p' "$FIX/one.out" | head -1) row(s) — the three cases below would be vacuous"

printf '%s' "$(cat "$FIX/one.jsonl")" > "$FIX/nonl.jsonl"     # same bytes, terminator removed
if [ "$(wc -c < "$FIX/nonl.jsonl")" -lt "$(wc -c < "$FIX/one.jsonl")" ]; then
  ok "(R4a) the no-terminator fixture is the SAME bytes minus the newline — a real newline, not the two characters"
else
  no "(R4a) the no-terminator fixture is not shorter than its source; the terminator was not removed"
fi
probe "$CTL" read "$FIX/nonl.jsonl" >"$FIX/nonl.out" 2>&1
if [ "$(sed -n 's/^ROWS=//p' "$FIX/nonl.out" | head -1)" = "0" ] \
   && grep -q 'not newline-terminated' "$FIX/nonl.out"; then
  ok "(R4) a COMPLETE json object with no terminator reads UNVERIFIED — truncation is detected by the missing terminator, not by a parse error"
else
  no "(R4) an unterminated row read as $(sed -n 's/^ROWS=//p' "$FIX/nonl.out" | head -1) verified row(s) — a killed writer's last line would read as a verdict"
fi

{ cat "$FIX/one.jsonl"; printf '%s\n' '{"id":"B-cut","keys":["id:b-cut"],"text_s'; } > "$FIX/badjson.jsonl"
probe "$CTL" read "$FIX/badjson.jsonl" >"$FIX/badjson.out" 2>&1
if grep -q '^DEFECT=.*:2: unparseable JSON' "$FIX/badjson.out"; then
  ok "(R5) unparseable JSON is a NAMED defect at its line, never a silent drop"
else
  no "(R5) unparseable JSON produced no named defect: $(grep '^DEFECT=' "$FIX/badjson.out" | head -1)"
fi

{ cat "$FIX/one.jsonl"; printf '%s\n' '{"id":"B-bad","keys":["id:b-bad"],"text_sha":"zz","verdict":"STALE","evidence":"","verified_at":"","verified_by":"me","disposition":"pending"}'; } > "$FIX/badrow.jsonl"
probe "$CTL" read "$FIX/badrow.jsonl" >"$FIX/badrow.out" 2>&1
if [ "$(sed -n 's/^ROWS=//p' "$FIX/badrow.out" | head -1)" = "1" ] \
   && grep -q '^DEFECT=.*:2: ' "$FIX/badrow.out"; then
  ok "(R6) a schema-invalid row is excluded AND named — the entry it described reads unverified"
else
  no "(R6) a schema-invalid row was not excluded-and-named: rows=$(sed -n 's/^ROWS=//p' "$FIX/badrow.out" | head -1) defects=$(grep -c '^DEFECT=' "$FIX/badrow.out")"
fi

probe "$CTL" read "$FIX/does-not-exist.jsonl" >"$FIX/missing.out" 2>&1
if [ "$(sed -n 's/^ROWS=//p' "$FIX/missing.out" | head -1)" = "0" ] \
   && [ "$(sed -n 's/^NDEFECTS=//p' "$FIX/missing.out" | head -1)" = "0" ]; then
  ok "(R7) a MISSING ledger is 0 rows and 0 defects, not a traceback — an unverified backlog is every repo's starting state"
else
  no "(R7) a missing ledger did not read as empty: $(cat "$FIX/missing.out" | head -3 | tr '\n' ' ')"
fi

# ================================================================================================
# D — two writers
# ================================================================================================
echo "-- D: concurrent writers dedup on (key, text_sha) --"
[ "$(grep -c '^ROWID=B-alpha-reuse|' "$FIX/read.out")" = "1" ] \
  && ok "(D1) the two writers of B-alpha-reuse collapse to ONE row" \
  || no "(D1) B-alpha-reuse appears $(grep -c '^ROWID=B-alpha-reuse|' "$FIX/read.out") time(s) after dedup"
grep -q '^ROWID=B-alpha-reuse|STILL-REAL|agent:sonnet' "$FIX/read.out" \
  && ok "(D2) the survivor is the LATER verified_at (agent:sonnet, 09:00), not the earlier one (agent:opus, 08:00)" \
  || no "(D2) the survivor is $(grep '^ROWID=B-alpha-reuse|' "$FIX/read.out") — dedup kept the wrong writer"

# D3 needs one key at TWO shas, which the seven-row fixture does not hold, so it gets its own file.
# Vacuity first: the two rows must really share the key and really differ in sha, or "both survive"
# is a statement about two unrelated rows.
D3_SHA1="$(printf 'e%.0s' $(seq 1 40))"; D3_SHA2="$(printf 'f%.0s' $(seq 1 40))"
{
  printf '{"id":"B-two","keys":["id:b-two"],"text_sha":"%s","verdict":"STILL-REAL","evidence":"a/b.py:1 first text","verified_at":"2026-09-01T00:00:00+00:00","verified_by":"agent:a","disposition":"pending"}\n' "$D3_SHA1"
  printf '{"id":"B-two","keys":["id:b-two"],"text_sha":"%s","verdict":"STALE-FIXED","evidence":"a/b.py:2 second text","verified_at":"2026-09-02T00:00:00+00:00","verified_by":"agent:b","disposition":"pending"}\n' "$D3_SHA2"
} > "$FIX/twosha.jsonl"
if [ "$(grep -cF '"keys":["id:b-two"]' "$FIX/twosha.jsonl")" = "2" ] && [ "$D3_SHA1" != "$D3_SHA2" ]; then
  ok "(D3a) the two-sha fixture really shares one key across two different text_shas"
else
  no "(D3a) the two-sha fixture does not have the shape D3 asserts about"
fi
probe "$CTL" read "$FIX/twosha.jsonl" >"$FIX/twosha.out" 2>&1
if [ "$(sed -n 's/^ROWS=//p' "$FIX/twosha.out" | head -1)" = "2" ]; then
  ok "(D3) one key at two text_shas stays TWO rows — two judgements about two texts, and that history is what makes a re-verification auditable instead of an overwrite"
else
  no "(D3) one key at two shas collapsed to $(sed -n 's/^ROWS=//p' "$FIX/twosha.out" | head -1) row(s) — a re-verification silently erased its predecessor"
fi

# ================================================================================================
# P — the reuse decision (decision 4)
# ================================================================================================
echo "-- P: reuse, re-verify, fresh, and the orphan defect --"
probe "$CTL" plan "$BL" "$LED" >"$FIX/plan.out" 2>&1
pv(){ sed -n "s/^$1=//p" "$FIX/plan.out" | head -1; }
IDLESS_KEY="$(sed -n 's/^DUP_KEY=//p' "$FIX/fixture.out")"
[ "$(pv NENTRIES)" = "5" ] \
  && ok "(P0) the fixture backlog yields 5 entries — four id-shaped and one content-keyed" \
  || no "(P0) the fixture yields $(pv NENTRIES) entries, not 5; every bucket below would be about a different file"
[ -n "$IDLESS_KEY" ] && case "$IDLESS_KEY" in
  fp:*) ok "(P0b) the id-less entry really keys on content ($IDLESS_KEY), so the fp:/id: bridge is exercised" ;;
  *) no "(P0b) the id-less entry keyed as '$IDLESS_KEY', not fp: — the bridge is not exercised" ;;
esac
case "$(pv REUSE)" in
  *B-alpha-reuse*) ok "(P1) a key that resolves at a MATCHING text_sha is REUSED — zero dispatch" ;;
  *) no "(P1) B-alpha-reuse is not in reuse: '$(pv REUSE)'" ;;
esac
case "$(pv REUSE)" in
  *"$IDLESS_KEY"*) ok "(P1b) the content-keyed entry is reused through its fp: key" ;;
  *) no "(P1b) $IDLESS_KEY is not in reuse: '$(pv REUSE)'" ;;
esac
case "$(pv REVERIFY)" in
  *B-beta-drift*) ok "(P2) a key that resolves at a DIFFERENT text_sha is RE-VERIFIED — the verdict expired with the text, not with the clock" ;;
  *) no "(P2) B-beta-drift is not in reverify: '$(pv REVERIFY)'" ;;
esac
case "$(pv REUSE)" in
  *B-beta-drift*) no "(P2b) B-beta-drift is in BOTH reuse and reverify — a stale verdict is being spent" ;;
  *) ok "(P2b) the stale entry is not also reused — the buckets are disjoint" ;;
esac
case "$(pv FRESH)" in
  *B-gamma-fresh*) ok "(P3) an entry with no row at all is FRESH" ;;
  *) no "(P3) B-gamma-fresh is not fresh: '$(pv FRESH)'" ;;
esac
if [ "$(pv NORPHANS)" = "1" ] && grep -q "^ORPHAN=.*B-deleted-long-ago" "$FIX/plan.out"; then
  ok "(P4) a ROW no entry resolves is a NAMED defect (B-deleted-long-ago), never a silent drop"
else
  no "(P4) the orphan row was not reported by name: NORPHANS=$(pv NORPHANS) $(grep '^ORPHAN=' "$FIX/plan.out" | head -1)"
fi
[ "$(pv COVERAGE)" = "3/5" ] \
  && ok "(P5) coverage is 3 of 5: only text_sha-exact rows count as current" \
  || no "(P5) coverage reads $(pv COVERAGE), expected 3/5"
if [ "$(pv SHORT)" = "B-beta-drift,B-gamma-fresh" ]; then
  ok "(P5b) the shortfall is NAMED (B-beta-drift,B-gamma-fresh) — a refusal that says '3 of 5' sends a reader back to diff two lists by hand"
else
  no "(P5b) the shortfall reads '$(pv SHORT)'"
fi

# Idempotence, stated about the REUSE PATH and never about byte-identity of model output.
probe "$CTL" sha "$BL" >"$FIX/sha1.out" 2>&1
sed 's/planted symlink/planted symlinkx/' "$BL" > "$FIX/backlog-edited.md"
probe "$CTL" sha "$FIX/backlog-edited.md" >"$FIX/sha2.out" 2>&1
S_A="$(grep '^ENTRY=B-alpha-reuse|' "$FIX/sha1.out")"
S_B="$(grep '^ENTRY=B-alpha-reuse|' "$FIX/sha2.out")"
S_G="$(grep '^ENTRY=B-gamma-fresh|' "$FIX/sha1.out")"
S_G2="$(grep '^ENTRY=B-gamma-fresh|' "$FIX/sha2.out")"
if [ -n "$S_A" ] && [ "$S_A" != "$S_B" ] && [ "$S_G" = "$S_G2" ]; then
  ok "(P6) a one-character edit rotates that entry's text_sha and leaves every other entry's alone — re-verification is per entry, not per file"
else
  no "(P6) text_sha did not behave: edited='$S_B' was '$S_A'; untouched gamma '$S_G2' was '$S_G'"
fi

# ================================================================================================
# PL — placement: ignore status and file mode
# ================================================================================================
echo "-- PL: the ledger inherits the backlog's visibility and mode --"
# A missing file is 0 bytes here, and the guard is a `[ -f ]` rather than `2>/dev/null` on the `wc`:
# bash performs the `< "$file"` redirection BEFORE the command's own stderr redirect is in place, so
# the "No such file" line reaches the log anyway and reads as a broken assertion.
bytes_of(){ if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }

mkrepo(){  # $1 = dir, $2... = .gitignore lines
  local d="$1" line; shift
  mkdir -p "$d/memory" || return 1
  ( cd "$d" && git init -q . >/dev/null 2>&1 ) || return 1
  printf '%s\n' "- [ ] B-x tools/a.py something" > "$d/memory/backlog.md"
  : > "$d/.gitignore"
  for line in "$@"; do printf '%s\n' "$line" >> "$d/.gitignore"; done
}
ROWS_JSON="$FIX/rows.json"
cat > "$ROWS_JSON" <<'EOF'
[{"id":"B-x","keys":["id:b-x"],"text_sha":"1111111111111111111111111111111111111111",
  "verdict":"NOT-VERIFIABLE","evidence":"the repo does not answer","verified_at":"2026-09-29T00:00:00+00:00",
  "verified_by":"deterministic:probe","disposition":"pending"}]
EOF

R_TRACKED="$FIX/repo-tracked"
mkrepo "$R_TRACKED" || no "(PL0) could not build the tracked fixture repo"
if probe "$CTL" append "$R_TRACKED" "$ROWS_JSON" >"$FIX/pl1.out" 2>&1; then
  [ -s "$R_TRACKED/memory/backlog-verdicts.jsonl" ] \
    && ok "(PL1) a TRACKED backlog yields a tracked ledger, written beside it" \
    || no "(PL1) the append succeeded but wrote no ledger"
else
  no "(PL1) the append refused on a tracked backlog: $(tail -2 "$FIX/pl1.out")"
fi

R_SPLIT="$FIX/repo-split"
mkrepo "$R_SPLIT" "/memory/backlog.md" || no "(PL0b) could not build the split fixture repo"
probe "$CTL" append "$R_SPLIT" "$ROWS_JSON" >"$FIX/pl2.out" 2>&1; PL2_RC=$?
PL2_BYTES="$(bytes_of "$R_SPLIT/memory/backlog-verdicts.jsonl")"
if [ "$PL2_RC" -ne 0 ] && [ "$PL2_BYTES" -eq 0 ]; then
  ok "(PL2) a would-be-TRACKED ledger beside an IGNORED backlog is refused: rc=$PL2_RC and $PL2_BYTES bytes written"
else
  no "(PL2) rc=$PL2_RC and $PL2_BYTES bytes — judgements quoting untracked content were about to be published into git"
fi
if grep -qF 'backlog-verdicts.jsonl' "$FIX/pl2.out"; then
  ok "(PL3) the refusal NAMES the ledger — a user following a message that lists only the archive, the lock and the index ends up with a tracked ledger"
else
  no "(PL3) the refusal does not name backlog-verdicts.jsonl: $(tail -3 "$FIX/pl2.out")"
fi

R_BOTH="$FIX/repo-both"
mkrepo "$R_BOTH" "/memory/backlog.md" "/memory/backlog-verdicts.jsonl" || no "(PL0c) could not build the both-ignored repo"
chmod 600 "$R_BOTH/memory/backlog.md"
if probe "$CTL" append "$R_BOTH" "$ROWS_JSON" >"$FIX/pl4.out" 2>&1; then
  PL4_MODE="$(python3 -c "import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" "$R_BOTH/memory/backlog-verdicts.jsonl")"
  PL4_SRC="$(python3 -c "import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" "$R_BOTH/memory/backlog.md")"
  if [ "$PL4_MODE" = "$PL4_SRC" ]; then
    ok "(PL4) both ignored: the ledger is created with the SOURCE's mode ($PL4_MODE), not the umask's"
  else
    no "(PL4) the ledger is $PL4_MODE while the 0600 backlog beside it is $PL4_SRC"
  fi
else
  no "(PL4) the append refused when BOTH files are ignored: $(tail -2 "$FIX/pl4.out")"
fi

R_NOGIT="$FIX/nogit"
mkdir -p "$R_NOGIT/memory"
printf '%s\n' "- [ ] B-y tools/b.py something" > "$R_NOGIT/memory/backlog.md"
if probe "$CTL" append "$R_NOGIT" "$ROWS_JSON" >"$FIX/pl5.out" 2>&1; then
  ok "(PL5) outside a git repository the placement check does NOT refuse — is_ignored() answers None there, and 'unknown' must not read as 'tracked'"
else
  no "(PL5) the append refused outside a repo ($(tail -2 "$FIX/pl5.out")) — the canonical backlog lives outside one"
fi

# ================================================================================================
# W — write discipline
# ================================================================================================
echo "-- W: writes take the lock and fail closed --"
R_LOCK="$FIX/repo-lock"
mkrepo "$R_LOCK" || no "(W0) could not build the lock fixture repo"
probe "$CTL" append "$R_LOCK" "$ROWS_JSON" >"$FIX/w1.out" 2>&1
W1_BYTES="$(bytes_of "$R_LOCK/memory/backlog-verdicts.jsonl")"
[ "$W1_BYTES" -gt 0 ] \
  && ok "(W1) control: an unlocked append writes the row ($W1_BYTES bytes)" \
  || no "(W1) the unlocked append wrote nothing — W2 below would be vacuous"

mkdir -p "$R_LOCK/memory/.backlog-archive.lock.d"
printf '%s\n' "$$" > "$R_LOCK/memory/.backlog-archive.lock.d/pid"   # a LIVE pid: never stolen
probe "$CTL" append "$R_LOCK" "$ROWS_JSON" >"$FIX/w2.out" 2>&1; W2_RC=$?
W2_BYTES="$(bytes_of "$R_LOCK/memory/backlog-verdicts.jsonl")"
if [ "$W2_RC" -ne 0 ] && [ "$W2_BYTES" -eq "$W1_BYTES" ]; then
  ok "(W2) a HELD lock makes the write exit rc=$W2_RC having written nothing — the byte count is unchanged at $W2_BYTES, which is the assertion; an exit code alone would not notice a partial ledger"
else
  no "(W2) rc=$W2_RC and the ledger went $W1_BYTES -> $W2_BYTES bytes under a held lock"
fi
rmdir "$R_LOCK/memory/.backlog-archive.lock.d" 2>/dev/null || rm -f "$R_LOCK/memory/.backlog-archive.lock.d/pid"
rmdir "$R_LOCK/memory/.backlog-archive.lock.d" 2>/dev/null
[ -d "$R_LOCK/memory/.backlog-archive.lock.d" ] \
  && no "(W2b) the held lock dir could not be released in the fixture" \
  || ok "(W2b) the fixture lock is released, so W3 measures the pre-lock path"

BAD_JSON="$FIX/badrows.json"
printf '%s\n' '[{"id":"B-z","keys":[],"text_sha":"nope","verdict":"MAYBE","evidence":"","verified_at":"","verified_by":"me"}]' > "$BAD_JSON"
probe "$CTL" append "$R_LOCK" "$BAD_JSON" >"$FIX/w3.out" 2>&1; W3_RC=$?
W3_BYTES="$(bytes_of "$R_LOCK/memory/backlog-verdicts.jsonl")"
if [ "$W3_RC" -ne 0 ] && [ "$W3_BYTES" -eq "$W1_BYTES" ] && grep -q 'refusing to append an invalid verdict row' "$FIX/w3.out"; then
  ok "(W3) an invalid incoming row is refused BEFORE the lock: rc=$W3_RC, the ledger is unchanged at $W3_BYTES bytes, and every problem is listed at once"
else
  no "(W3) rc=$W3_RC bytes=$W1_BYTES->$W3_BYTES msg=$(head -1 "$FIX/w3.out")"
fi
[ -d "$R_LOCK/memory/.backlog-archive.lock.d" ] \
  && no "(W3b) the refused append left a lock directory behind" \
  || ok "(W3b) the refused append left no lock behind — it exited before taking one"

# Appending onto a TRUNCATED ledger: the tail is fenced off, never repaired, and never swallows the
# row appended after it.
R_TRUNC="$FIX/repo-trunc"
mkrepo "$R_TRUNC" || no "(W4a) could not build the truncation fixture repo"
printf '%s' '{"id":"B-cut","keys":["id:b-cut"],"text_s' > "$R_TRUNC/memory/backlog-verdicts.jsonl"
if probe "$CTL" append "$R_TRUNC" "$ROWS_JSON" >"$FIX/w4.out" 2>&1; then
  probe "$CTL" read "$R_TRUNC/memory/backlog-verdicts.jsonl" >"$FIX/w4read.out" 2>&1
  W4_ROWS="$(sed -n 's/^ROWS=//p' "$FIX/w4read.out" | head -1)"
  W4_DEF="$(sed -n 's/^NDEFECTS=//p' "$FIX/w4read.out" | head -1)"
  if [ "$W4_ROWS" = "1" ] && [ "$W4_DEF" = "1" ] && grep -q 'PREEXISTING_DEFECTS=1' "$FIX/w4.out"; then
    ok "(W4) appending onto a truncated tail terminates it without repairing it: the new row reads (1), the broken line stays a defect (1), and the append REPORTED the pre-existing defect"
  else
    no "(W4) after the append: rows=$W4_ROWS defects=$W4_DEF reported=$(grep PREEXISTING "$FIX/w4.out")"
  fi
else
  no "(W4) the append onto a truncated ledger failed outright: $(tail -2 "$FIX/w4.out")"
fi

# ================================================================================================
# F — the module's own limits (rules/file-limits.md: RAW lines for a module, BODY lines for a
# function; ast.stmt is not a gate). Measured and PRINTED, so the numbers are in the log.
# ================================================================================================
echo "-- F: rules/file-limits.md on the module itself --"
python3 - "$LEDGER_MOD" <<'PYEOF' >"$FIX/limits.out" 2>&1
import ast, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    src = fh.read()
lines = src.splitlines()
print("RAWLINES=%d" % len(lines))
over = []
for node in ast.walk(ast.parse(src)):
    if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        continue
    body = list(node.body)
    if (body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant)
            and isinstance(body[0].value.value, str)):
        body = body[1:]                      # the docstring is not body, by the rule's own wording
    n = 0
    if body:
        lo = body[0].lineno
        hi = max(getattr(x, "end_lineno", x.lineno) for x in body)
        for i in range(lo, hi + 1):
            s = lines[i - 1].strip()
            if s and not s.startswith("#"):  # comments and blanks are excluded, by the same wording
                n += 1
    limit = 30 if node.name.startswith("_") else 50
    print("FUNC=%s body=%d limit=%d %s" % (node.name, n, limit, "OVER" if n > limit else "ok"))
    if n > limit:
        over.append(node.name)
print("NOVER=%d" % len(over))
PYEOF
cat "$FIX/limits.out"
F_RAW="$(sed -n 's/^RAWLINES=//p' "$FIX/limits.out")"
F_NFUNC="$(grep -c '^FUNC=' "$FIX/limits.out")"
[ "${F_NFUNC:-0}" -ge 10 ] \
  && ok "(F0) the measurement found $F_NFUNC functions — a measurer that found none would report 'no function is over the limit'" \
  || no "(F0) the measurement found only ${F_NFUNC:-0} functions; it is not measuring the module"
if [ -n "$F_RAW" ] && [ "$F_RAW" -lt 400 ]; then
  ok "(F1) the module is $F_RAW RAW lines, under the 400 default (800 is the automatic CQ11 FAIL)"
elif [ -n "$F_RAW" ] && [ "$F_RAW" -lt 800 ]; then
  no "(F1) the module is $F_RAW raw lines, over the 400 default — extract a sibling rather than carrying it"
else
  no "(F1) the module is ${F_RAW:-?} raw lines — 800 is an automatic CQ11 FAIL"
fi
[ "$(sed -n 's/^NOVER=//p' "$FIX/limits.out")" = "0" ] \
  && ok "(F2) every function is inside its BODY-line limit (public 50, private 30)" \
  || no "(F2) over the body-line limit: $(grep 'OVER$' "$FIX/limits.out" | tr '\n' ' ')"
head -1 "$LEDGER_MOD" | grep -q '^#!' \
  && no "(F3) the module carries a shebang — it is a library, imported like zuvo_backlog_io.py, not a script" \
  || ok "(F3) no shebang: the module is a library, as its two siblings are"
[ -x "$LEDGER_MOD" ] \
  && no "(F3b) the module is executable; nothing runs it directly" \
  || ok "(F3b) the module is not executable"
# Asked of the SYNTAX TREE, not of a grep: this module's docstring names `sys.path` in prose to say it
# does not touch it, and a text search reads that explanation as the defect it warns about.
syspath_hits(){ python3 - "$1" <<'PYEOF'
import ast
import sys
with open(sys.argv[1], encoding="utf-8") as fh:
    tree = ast.parse(fh.read())
hits = [n.lineno for n in ast.walk(tree)
        if isinstance(n, ast.Attribute) and n.attr == "path"
        and isinstance(n.value, ast.Name) and n.value.id == "sys"]
print(",".join(str(h) for h in hits) if hits else "none")
PYEOF
}
F_SP="$(syspath_hits "$LEDGER_MOD")"
F_SP_CTL="$(syspath_hits "$PROBE")"
if [ "$F_SP_CTL" = "none" ]; then
  no "(F4a) the sys.path detector found nothing in the probe, which demonstrably inserts one — the detector is broken, so F4 below proves nothing"
else
  ok "(F4a) the detector finds the probe's own sys.path insert at line(s) $F_SP_CTL — it is not blind"
fi
[ "$F_SP" = "none" ] \
  && ok "(F4) the module never touches sys.path, so it resolves identically in the checkout and on the flattened ~/.zuvo/ layout" \
  || no "(F4) the module touches sys.path at line(s) $F_SP — putting the importer's directory on the path is the IMPORTER's job, and a module that rewrites its importer's path breaks in exactly one of the two install layouts"

# ================================================================================================
# I — the include and the extended protocol wording
# ================================================================================================
echo "-- I: backlog-grooming.md and the protocol's refusal wording --"
i_has(){  # file, label, substring
  grep -qF -- "$3" "$1" && ok "(I) $2" || no "(I) $2 — '$3' is absent from ${1#"$ROOT"/}"
}
i_has "$INCLUDE" "the include names the ledger file"                  'backlog-verdicts.jsonl'
i_has "$INCLUDE" "the include records the chunk cap"                  '25 KB'
i_has "$INCLUDE" "the include chunks by block bytes via end_lineno"   'end_lineno'
i_has "$INCLUDE" "the include states control (c)'s honest limit"      'fabrication, not misjudgement'
i_has "$INCLUDE" "the include keeps the verdicts out of severity"     'severity-vocabulary.md'
i_has "$INCLUDE" "the include states the merged-pair conservation check" 'len(set(keys_returned)) == len(rows_dispatched)'
i_has "$INCLUDE" "the include records the user's binding rule verbatim" 'wszystkie ma najpierw'
i_has "$INCLUDE" "the include says a DUPLICATE-OF is a report, not a merge" 'not a licence to merge'
I_FMISS=""
for f in id keys text_sha verdict evidence verified_at verified_by disposition; do
  grep -qF "\`$f\`" "$INCLUDE" || I_FMISS="$I_FMISS $f"
done
[ -z "$I_FMISS" ] \
  && ok "(I1) all eight schema fields are documented in the include" \
  || no "(I1) the include does not document:$I_FMISS"

i_has "$PROTOCOL" "the protocol names the ledger in its refusal wording" 'backlog-verdicts.jsonl'
# STRUCTURAL, not just present: the mention has to sit in the visibility/refusal section, or a reader
# following that section still adds three lines to .gitignore and gets a tracked ledger.
I_VIS="$(grep -n "inherits the source's visibility" "$PROTOCOL" | head -1 | cut -d: -f1)"
I_LED="$(grep -n 'backlog-verdicts.jsonl' "$PROTOCOL" | head -1 | cut -d: -f1)"
if [ -n "$I_VIS" ] && [ -n "$I_LED" ] && [ "$I_LED" -gt "$I_VIS" ] && [ $((I_LED - I_VIS)) -lt 30 ]; then
  ok "(I2) the ledger is named $((I_LED - I_VIS)) lines after the visibility rule (protocol :$I_VIS -> :$I_LED) — inside the section a reader actually follows"
else
  no "(I2) the visibility rule is at :${I_VIS:-?} and the ledger is first named at :${I_LED:-?} — too far apart to be the same instruction"
fi
i_has "$PROTOCOL" "the protocol keeps 'is False' rather than a falsy check" 'is False'

# ================================================================================================
# M — the mutants. Every assertion above must FAIL under a mutation that reverts only its behaviour.
# ================================================================================================
echo "-- M: each assertion dies under a mutant that reverts only its behaviour --"
# NOTHING here reports through a command substitution. `no()` called inside `$(...)` runs in a
# SUBSHELL: its line is captured into the variable instead of the log and its FAIL increment is
# discarded when the subshell exits — the same mechanism that makes `command_not_found_handle` unable
# to count. So `mut_build` only returns a status, the directory name is derived, and every ok/no below
# happens in this shell.
mut_build(){ python3 "$MKMUT" "$LEDGER_MOD" "$PARSE_MOD" "$IO_MOD" "$1" "$FIX/mut-$1" >"$FIX/mk-$1.log" 2>&1; }
mut_failed(){
  no "(M) mutant '$1' did NOT build: $(tail -1 "$FIX/mk-$1.log") — its substitution no longer applies, so the assertion it targets would pass on a mutant that does not exist"
}
mut_gone(){  # $1 kind, $2 label, $3 ERE that must vanish, $4... probe args
  local kind="$1" lbl="$2" pat="$3" out
  if ! mut_build "$kind"; then mut_failed "$kind"; return; fi
  shift 3
  out="$(probe "$FIX/mut-$kind" "$@" 2>&1)"
  if printf '%s\n' "$out" | grep -qE -- "$pat"; then
    no "(M) $lbl: the mutant still produced /$pat/ — the assertion is decorative"
  else
    ok "(M) $lbl: /$pat/ is gone under the mutant — the assertion is load-bearing"
  fi
}
mut_rc0(){  # $1 kind, $2 label, $3... probe args (control exits non-zero; the mutant must not)
  local kind="$1" lbl="$2"
  if ! mut_build "$kind"; then mut_failed "$kind"; return; fi
  shift 2
  if probe "$FIX/mut-$kind" "$@" >/dev/null 2>&1; then
    ok "(M) $lbl: the mutant exits 0 where the control refuses — the refusal is load-bearing"
  else
    no "(M) $lbl: the mutant ALSO refused, so the control's refusal is not attributable to this code"
  fi
}

mut_gone vocab6       "V1 closed at five"                 '^NVERDICTS=5$'                vocab
mut_gone nostillloc   "S stillnoloc rejection"            '^CASE=stillnoloc n=[1-9]'     schema
mut_gone shalax       "S sha39 rejection"                 '^CASE=sha39 n=[1-9]'          schema
mut_gone nokeys       "S nokeys rejection"                '^CASE=nokeys n=[1-9]'         schema
mut_gone nodup        "S dupnokey rejection"              '^CASE=dupnokey n=[1-9]'       schema
mut_gone trunctolerant "R4 truncation reads unverified"   '^ROWS=0$'                     read "$FIX/nonl.jsonl"
mut_gone silentdrop   "R5 unparseable JSON is named"      '^DEFECT=.*unparseable JSON'   read "$FIX/badjson.jsonl"
mut_gone schemasilent "R6 a bad row is named"             '^DEFECT=.*:2: '               read "$FIX/badrow.jsonl"
mut_gone dedupfirst   "D2 the later writer wins"          'agent:sonnet'                 read "$LED"
mut_gone dedupsha     "D3 a different sha is its own row" '^ROWS=2$'                     read "$FIX/twosha.jsonl"
mut_gone noorphan     "P4 the orphan row is named"        '^ORPHAN='                     plan "$BL" "$LED"
mut_gone shablind     "P2 a drifted sha is re-verified"   '^REVERIFY=.*B-beta-drift'     plan "$BL" "$LED"
mut_gone nonamed      "PL3 the refusal names the ledger"  'backlog-verdicts\.jsonl'      append "$R_SPLIT" "$ROWS_JSON"
mut_rc0  noplacement  "PL2 the placement refusal"                                        append "$R_SPLIT" "$ROWS_JSON"
mut_rc0  prevalidate  "W3 an invalid row is refused"                                     append "$R_LOCK" "$BAD_JSON"

# nomode and nolock need their own repos: both mutants SUCCEED, so the property is read from the
# filesystem afterwards rather than from an exit code.
if ! mut_build nomode; then mut_failed nomode; else
  R_M="$FIX/repo-mut-mode"
  mkrepo "$R_M" "/memory/backlog.md" "/memory/backlog-verdicts.jsonl"
  chmod 600 "$R_M/memory/backlog.md"
  probe "$FIX/mut-nomode" append "$R_M" "$ROWS_JSON" >/dev/null 2>&1
  M_MODE="$(python3 -c "import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" "$R_M/memory/backlog-verdicts.jsonl" 2>/dev/null || echo none)"
  [ "$M_MODE" != "0o600" ] \
    && ok "(M) PL4 mode inheritance: the mutant writes $M_MODE beside a 0o600 backlog — the assertion is load-bearing" \
    || no "(M) PL4 mode inheritance: the mutant still produced 0o600, so PL4 does not measure the chmod"
fi
if ! mut_build nolock; then mut_failed nolock; else
  R_L="$FIX/repo-mut-lock"
  mkrepo "$R_L"
  mkdir -p "$R_L/memory/.backlog-archive.lock.d"
  printf '%s\n' "$$" > "$R_L/memory/.backlog-archive.lock.d/pid"
  probe "$FIX/mut-nolock" append "$R_L" "$ROWS_JSON" >/dev/null 2>&1; M_LOCK_RC=$?
  M_LOCK_BYTES="$(bytes_of "$R_L/memory/backlog-verdicts.jsonl")"
  if [ "$M_LOCK_RC" -eq 0 ] && [ "$M_LOCK_BYTES" -gt 0 ]; then
    ok "(M) W2 the lock: without it the mutant writes $M_LOCK_BYTES bytes straight through a held lock — W2 measures the lock, not an unrelated error"
  else
    no "(M) W2 the lock: the mutant also wrote nothing (rc=$M_LOCK_RC, $M_LOCK_BYTES bytes), so W2's refusal is not attributable to the lock"
  fi
fi

# The factory's own guarantee: a substitution that no longer applies must be a HARD ERROR, not a
# silently unmutated copy. Asserted with a kind that does not exist.
if python3 "$MKMUT" "$LEDGER_MOD" "$PARSE_MOD" "$IO_MOD" no-such-mutation "$FIX/mut-bogus" >/dev/null 2>&1; then
  no "(M0) the factory accepted an unknown mutation and wrote a copy — every 'the mutant passed' above could mean 'the mutation was never made'"
else
  ok "(M0) the factory hard-errors on a mutation it cannot apply"
fi


# ==================================================================================================
# TASK 2 — the deterministic pre-pass, the mint write, the byte chunker and the committed census.
#
# WHAT THE MEASUREMENT FOUND, because it changes what these assertions can claim. The plan says "mint
# an id for every entry `iter_entries` yields without one — measured 263 of 387 here". On this repo the
# mint set really is 263 entries and **0** of them can be minted: every one is the BULLET dialect, and
# `zuvo_backlog_mint.mint_into` refuses a plain bullet BY DESIGN — `tests/hooks/test-backlog-headings.sh`
# (H20/AC7) pins `'- plain bullet, no checkbox'` as refused in as many words ("the anchor admits only
# the two entry dialects"). Widening that anchor would break a deliberate, pinned decision belonging to
# another PR, so `mintable()` filters the set and REPORTS the remainder, and the write assertions below
# run on a fixture whose id-less entries are checkboxes. 38 of the 263 are filtered for a second,
# independent reason — they already display a `B-` id that `definition_id` cannot see — and that filter
# has its own assertion and its own mutant.
#
# NO VACUOUS ASSERTIONS, same rule as the ledger half: every fixture is CENSUSED from its own bytes
# before a property of it is asserted, every negative has a positive control on the same fixture, and
# the census's per-level counts are compared against an INDEPENDENT oracle rather than against the
# numbers written into the fixture by hand.
# ==================================================================================================
echo "== Task 2: pre-pass, queue, chunker, census =="

SCRIPTS="$ROOT/scripts/zuvo-home"
GROOM_PY="$SCRIPTS/backlog-groom.py"
CENSUS_PY="$SCRIPTS/backlog-census.py"
VERDICTS_MOD="$SCRIPTS/zuvo_backlog_verdicts.py"
QUEUE_MOD="$SCRIPTS/zuvo_backlog_queue.py"
# Task 3's three siblings. They are declared HERE, beside the Task 2 modules, because the file-limits
# and library-shape loops below are the family's checks and a module that joined the family without
# joining those loops is a module nothing measures.
PREPASS_MOD="$SCRIPTS/zuvo_backlog_prepass.py"
AGENT_MOD="$SCRIPTS/zuvo_backlog_agent.py"
SEEDS_MOD="$SCRIPTS/zuvo_backlog_seeds.py"
# Task 4's two. Declared here for the same reason: the file-limits and library-shape loops below are
# the FAMILY's checks, and a module that joined the family without joining those loops is a module
# nothing measures — which is how `backlog-groom.py` reached 416 raw lines unnoticed in the first place.
APPLY_MOD="$SCRIPTS/zuvo_backlog_apply.py"
LOAD_MOD="$SCRIPTS/zuvo_backlog_load.py"
ARCHIVE_PY="$SCRIPTS/backlog-archive.py"
BLOCK_MOD="$SCRIPTS/zuvo_backlog_block.py"
MINT_MOD="$SCRIPTS/zuvo_backlog_mint.py"
CAP_REAL=25000
T2="$FIX/t2"
mkdir -p "$T2"

for f in "$GROOM_PY" "$CENSUS_PY" "$VERDICTS_MOD" "$QUEUE_MOD" "$BLOCK_MOD" "$MINT_MOD" \
         "$PREPASS_MOD" "$AGENT_MOD" "$SEEDS_MOD" "$APPLY_MOD" "$LOAD_MOD" "$ARCHIVE_PY"; do
  [ -f "$f" ] && ok "(Q0) present: ${f#"$ROOT"/}" || { no "(Q0) missing: ${f#"$ROOT"/} — nothing in this half can be checked"; finish; }
done

# --------------------------------------------------------------------------------------------------
# The Task 2 probe. It loads backlog-groom.py by PATH — the name is hyphenated, so `import` cannot
# reach it — out of whichever module directory it is pointed at, which is what makes the control/mutant
# split below possible without ever editing a file in the checkout.
# --------------------------------------------------------------------------------------------------
T2PROBE="$T2/probe2.py"
cat > "$T2PROBE" <<'PYEOF'
r"""Machine-readable probe over backlog-groom.py, zuvo_backlog_verdicts.py and zuvo_backlog_queue.py.

RAW docstring for the same reason as the ledger probe's: a `\s` in a plain one is a SyntaxWarning on
stderr, and every caller here reads stderr as "the mutant did not build".

Usage: probe2.py <moddir> <mode> [args...]
"""
import importlib.util
import json
import os
import sys

MODDIR = os.path.abspath(sys.argv[1])
sys.path.insert(0, MODDIR)
import zuvo_backlog_ledger as zl    # noqa: E402
import zuvo_backlog_parse as zb     # noqa: E402
import zuvo_backlog_queue as zq     # noqa: E402
import zuvo_backlog_verdicts as zv  # noqa: E402

KINDS = zb.DEFAULT_KINDS + (zb.KIND_HEADING,)


def load_groom():
    """backlog-groom.py as a module. `spec_from_file_location` because the filename is hyphenated,
    exactly as test-backlog-headings.sh's contract probe loads backlog-archive.py."""
    spec = importlib.util.spec_from_file_location("groom_probe",
                                                  os.path.join(MODDIR, "backlog-groom.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load_census():
    spec = importlib.util.spec_from_file_location("census_probe",
                                                  os.path.join(MODDIR, "backlog-census.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def out(key, value):
    print("%s=%s" % (key, value))


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def entries_of(text):
    return list(zb.iter_entries(text, kinds=KINDS))


def mode_classify(backlog, archive, root):
    """The four deterministic classes over a fixture: the verdict, the class, the evidence, whether
    that evidence RESOLVES, and whether the ledger's own validator would accept the row."""
    ents = entries_of(read(backlog))
    arch = entries_of(read(archive)) if os.path.exists(archive) else []
    tree = zv.Tree(root=root, real=backlog, archive=archive)
    verdicts, refused = zv.classify(ents, tree, arch)
    out("NENTRIES", len(ents))
    out("NVERDICTS", len(verdicts))
    out("NREFUSED", len(refused))
    for r in refused:
        print("REFUSED=" + r)
    for v in verdicts:
        print("V=%s|%s|%s|%s" % (v.entry.ident or v.entry.key, v.klass, v.verdict, v.evidence))
    for v in verdicts:
        print("RESOLVES=%s|%s|%s" % (v.entry.ident or v.entry.key, v.klass,
                                     ";".join(zv.unresolvable(v.evidence, tree)) or "ALL"))
    for i, row in enumerate(zv.ledger_rows(verdicts), start=1):
        probs = zl.validate_row(row, "row%d" % i)
        print("LEDGERROW=%s|%s|%d|%s" % (row["id"], row["verdict"], len(probs),
                                         probs[0] if probs else "-"))


def mode_resolve(backlog, archive, root, *evidences):
    """`unresolvable()` on crafted evidence strings — control (b), asked directly.

    Four shapes: a citation that resolves, one past the end of the file, one naming a file that is not
    there, and one with no citation at all. Each is a separate line of output, so one mutant kills one.
    """
    tree = zv.Tree(root=root, real=backlog, archive=archive)
    for i, ev in enumerate(evidences, start=1):
        print("RES=%d|%s" % (i, ";".join(zv.unresolvable(ev, tree)) or "ALL"))


def mode_mintsel(backlog):
    """The mint set, what is MINTABLE out of it, and the reason each remainder is not."""
    g = load_groom()
    text = read(backlog)
    lines = text.splitlines(keepends=True)
    ents = entries_of(text)
    declared = g.mint_set(ents)
    targets, skipped = g.mintable(lines, declared)
    out("NENTRIES", len(ents))
    out("MINT_SET", len(declared))
    out("MINTABLE", len(targets))
    out("UNMINTABLE", len(skipped))
    for e in targets:
        print("MINT=:%d kind=%s" % (e.lineno, e.kind))
    for s in skipped:
        print("SKIP=" + s)


def mode_mintlines(backlog, other):
    """`mint_lines` twice: against the lines it parsed, then against a DIFFERENT file.

    The second call reaches the identity check without a race — entries from `backlog`, lines from
    `other` is exactly the state a concurrent edit leaves behind, and it is the only way to test the
    abort deterministically.
    """
    g = load_groom()
    text = read(backlog)
    lines = text.splitlines(keepends=True)
    targets, _ = g.mintable(lines, g.mint_set(entries_of(text)))
    new, inserted, bad = g.mint_lines(lines, targets)
    out("TARGETS", len(targets))
    out("CLEAN_BAD", len(bad))
    out("CLEAN_INSERTED", inserted)
    out("CLEAN_LINES", "%d->%d" % (len(lines), len(new)))
    _, _, bad2 = g.mint_lines(read(other).splitlines(keepends=True), targets)
    out("MOVED_BAD", len(bad2))
    for b in bad2:
        print("MOVEDMSG=" + b)


def mode_chunk(backlog, cap):
    """Chunk a file and report the split, plus the three properties a chunk report cannot show."""
    text = read(backlog)
    lines = text.splitlines(keepends=True)
    rows = [zq.queue_row(lines, e, None, False) for e in entries_of(text)]
    for line in zq.chunk_report(rows, int(cap)):
        print(line)
    out("NROWS", len(rows))
    out("UNASSIGNED", sum(1 for r in rows if r["chunk"] is None))
    out("MAXROW", max((r["bytes"] for r in rows), default=0))
    out("OVERSIZE_ROWS", sum(1 for r in rows if r["bytes"] > int(cap)))
    # Which chunks each SECTION lands in: "the 117-entry section splits" is a statement about ONE
    # section, and a total chunk count cannot express it.
    per = {}
    for r in rows:
        per.setdefault(r["section"], set()).add(r["chunk"])
    if per:
        big = max(per, key=lambda s: sum(1 for r in rows if r["section"] == s))
        out("BIGGEST_SECTION_ENTRIES", sum(1 for r in rows if r["section"] == big))
        out("BIGGEST_SECTION_CHUNKS", len(per[big]))


def mode_expand(*values):
    found, missing = load_census().expand_roots(list(values))
    out("FOUND", "|".join(found))
    out("MISSING", "|".join(missing))


def mode_queuefile(path):
    """Read a written queue back: the terminator, the row count, the contract fields, the partition."""
    with open(path, "rb") as fh:
        raw = fh.read()
    out("TERMINATED", int(raw.endswith(b"\n")))
    rows = [json.loads(ln) for ln in raw.decode("utf-8").splitlines() if ln.strip()]
    out("ROWS", len(rows))
    need = ("id", "keys", "text_sha", "raw_text", "section", "cited_paths")
    out("MISSING_FIELDS", ",".join(sorted({f for r in rows for f in need if f not in r})) or "-")
    out("WITH_VERDICT", sum(1 for r in rows if r.get("verdict")))
    out("CHUNKED", sum(1 for r in rows if r.get("chunk") is not None))


MODES = {"classify": mode_classify, "resolve": mode_resolve, "mintsel": mode_mintsel,
         "mintlines": mode_mintlines, "chunk": mode_chunk, "expand": mode_expand,
         "queuefile": mode_queuefile}
MODES[sys.argv[2]](*sys.argv[3:])
PYEOF

# --------------------------------------------------------------------------------------------------
# The Task 2 mutant factory. Same contract as the ledger one: every substitution is COUNTED and a miss
# is a HARD ERROR, because a mutation that silently failed to apply makes the assertion reading it pass
# for the wrong reason — which is indistinguishable from the assertion being load-bearing.
# --------------------------------------------------------------------------------------------------
MKMUT2="$T2/mkmut2.py"
cat > "$MKMUT2" <<'PYEOF'
r"""Write a named mutation of ONE Task 2 file into its own directory, beside untouched copies of every
sibling it imports.

RAW docstring, same reason as the probe's.

Usage: mkmut2.py <scriptsdir> <kind> <outdir>

EVERY sibling travels by GLOB rather than by a list. That list was manual twice in this repo's history
and cost the identical failure both times — a new module landed, the factories still named five files,
and every mutant died with ModuleNotFoundError: an import error wearing a mutation's clothes, inside
the assertions that exist to prove the mutation fires.
"""
import glob
import os
import shutil
import sys

SRC, KIND, OUT = sys.argv[1:4]

GROOM = "backlog-groom.py"
CENSUS = "backlog-census.py"
# Task 4's `apply` delegates every closure to THIS file, found by `os.path.realpath(__file__)`'s own
# directory — so a mutant directory without it has no archiver at all and every delegation assertion
# would fail on an absence rather than on a mutation.
ARCHIVE = "backlog-archive.py"
VERDICTS = "zuvo_backlog_verdicts.py"
QUEUE = "zuvo_backlog_queue.py"
PARSE = "zuvo_backlog_parse.py"
# Task 3 extracted the mint pre-pass and added the verifier lane. backlog-groom.py measured 399 raw
# lines with the mint inlined — ONE under rules/file-limits.md's 400-line Python default — so the six
# mint mutations below moved file WITHOUT changing what they mutate. The factory's exactly-once
# substitution guard is what turns a missed move into a hard error instead of a silent pass.
PREPASS = "zuvo_backlog_prepass.py"
AGENT = "zuvo_backlog_agent.py"
SEEDS = "zuvo_backlog_seeds.py"
# Task 4 extracted the dispositions and the read-only loading layer, for the same 400-line reason:
# backlog-groom.py measured 416 raw lines with `apply` inlined.
APPLY = "zuvo_backlog_apply.py"
# Task 6 put the non-blocking coverage count here, next to the read model it derives from, because
# backlog-groom.py measured 388 raw lines before `coverage` and 397 after — rules/file-limits.md's
# 400-line Python default is the same ceiling that chose every other seam in this family.
LOAD = "zuvo_backlog_load.py"
# Task 5 extracted the working document, its scoring and the read-only fleet lane — and moved the
# seed answer-key READER next to the function that mints it, because backlog-groom.py measured 403
# raw lines with `render` and `--fleet` wired in and 388 after.
RENDER = "zuvo_backlog_render.py"
SCORE = "zuvo_backlog_score.py"
FLEET = "zuvo_backlog_fleet.py"

# (file, old, new) — `old` must occur EXACTLY once in that file.
MUTATIONS = {
    # --- the four deterministic classes ------------------------------------------------------------
    "nomarker": (VERDICTS, "    if pos >= 0:\n        return _marker_verdict(e, pos, tree)",
                 "    if False:\n        return _marker_verdict(e, pos, tree)"),
    "noarchive": (VERDICTS,
                  "    if hit is not None:\n        return _archived_verdict(e, hit[0], hit[1], tree)",
                  "    if False:\n        return _archived_verdict(e, hit[0], hit[1], tree)"),
    "nodupclass": (VERDICTS, "    if e.lineno in dups:", "    if False and e.lineno in dups:"),
    "noobsolete": (VERDICTS,
                   "    if paths and all(not os.path.exists(os.path.join(tree.root, p)) for p in paths):",
                   "    if False:"),
    # Duplicate detection keyed on `key` alone: a minted id then hides every content collision,
    # because `entry_key` prefers `id:` and stops reading the text.
    "dupkeyonly": (VERDICTS, "        for key in sorted(zb.keys_for(e.body, e.ident)):",
                   "        for key in [e.key]:"),
    # --- Task 6: the non-blocking coverage count ---------------------------------------------------
    # The count removed entirely: what `append-runlog` prints comes from this one line or from nowhere.
    "nudgesilent": (LOAD, "    if total and verified != total:", "    if False:"),
    # The guard removed: the nudge then prints on a FULLY verified repo too, which is A29's second half.
    "nudgealways": (LOAD, "    if total and verified != total:", "    if True:"),
    # Coverage by ROW COUNT instead of the ledger's `text_sha`-exact arithmetic — a ledger whose rows
    # were written against text that has since changed then reports as fully verified.
    "nudgerowcount": (LOAD, "    verified, total, _short = zl.coverage(loaded.entries, read.rows)",
                      "    verified, total, _short = (len(read.rows), len(loaded.entries), [])"),
    # The no-ledger guard removed: the nudge then speaks in every repo that has never verified, which
    # is the steady state of the fleet and the A29 noise regression this guard was added for.
    "nudgenoledger": (LOAD, "    if not os.path.exists(ledger):", "    if False:"),
    # The shape revision 5 forbids: a variable payload inside the closed-set `verdict` field.
    "duppayload": (VERDICTS, "    return Verdict(e, zl.VERDICT_DUPLICATE_OF,",
                   '    return Verdict(e, zl.VERDICT_DUPLICATE_OF + " " + key,'),
    # The obsolete class citing the MISSING path instead of the backlog line that names it.
    "obscitesgone": (VERDICTS,
                     "    return Verdict(e, zl.VERDICT_STALE_OBSOLETE,\n"
                     "                   f'{tree.open_name}:{e.lineno} \"{named}\" does not exist',"
                     " CLASS_OBSOLETE)",
                     "    return Verdict(e, zl.VERDICT_STALE_OBSOLETE,\n"
                     "                   f'{paths[0]}:1 does not exist', CLASS_OBSOLETE)"),
    # Resolvability disabled entirely: a citation pointing nowhere is accepted.
    "resolvelax": (VERDICTS, "    locs = zl.evidence_locations(evidence)",
                   "    return []\n    locs = zl.evidence_locations(evidence)"),
    # The file exists, so any line number passes — the half of control (b) that catches a plausible
    # fabrication rather than an impossible one.
    "linelax": (VERDICTS, "        if line < 1 or line > have:", "        if False:"),
    # Precedence inverted: the archive is consulted before the entry's own recorded closure.
    "archivefirst": (VERDICTS, "    pos = marker_pos(e)", "    pos = -1"),
    # A heading judged by the LOOSE marker guard — the 50 false positives PR 1 measured over 3561
    # heading entries, every one of them in the archivable direction.
    "loosemarker": (VERDICTS,
                    "    return (zb.heading_resolution_pos(e.body) if e.kind == zb.KIND_HEADING\n"
                    "            else zb.resolution_marker_pos(e.body))",
                    "    return zb.resolution_marker_pos(e.body)"),
    # --- the mint pre-pass ------------------------------------------------------------------------
    "mintany": (PREPASS, "        elif mint_into(core, mint_id(e.body)) is None:", "        elif False:"),
    "nobodyid": (PREPASS, "        if zb.BODY_ID_RE.match(e.body.strip()):", "        if False:"),
    "noidentity": (PREPASS, '        if out[idx].rstrip("\\r\\n") != e.raw:', "        if False:"),
    "identitylax": (PREPASS, '        if out[idx].rstrip("\\r\\n") != e.raw:',
                    "        if out[idx].strip() != e.raw.strip():"),
    "countoff": (GROOM, "    if len(post) != pre:", "    if len(post) != pre + 1:"),
    "linecountoff": (GROOM, "    if len(sim) != len(loaded.lines):",
                     "    if len(sim) != len(loaded.lines) + 1:"),
    "noneopen": (PREPASS, "    if zio.is_ignored(real) is None:", "    if False:"),
    "nolock2": (PREPASS, "    with zio.Lock(os.path.dirname(real)):", "    if True:"),
    "drywrites": (GROOM, "    if dry_run or not targets:", "    if not targets:"),
    # The hazard PR 1's decision 1 forbids: an id-less HEADING joining the mint set. `mint_into`
    # ACCEPTS a flush-left heading, so nothing downstream would refuse — the id would be written into
    # the structure of a tracked file (`## benchmark skill` gaining an identifier).
    "mintheadings": (GROOM, "    targets, unmintable = mintable(loaded.lines, declared)",
                     "    declared = declared + [zb.Entry(lineno=n, raw=t, body=t.split(' ', 1)[-1],\n"
                     "                                    status='open', ident='', key='fp:hhhhhhhhhhhh',\n"
                     "                                    section='', kind=zb.KIND_HEADING, end_lineno=n)\n"
                     "                           for n, t in idless_headings(loaded)]\n"
                     "    targets, unmintable = mintable(loaded.lines, declared)"),
    # --- the chunker ------------------------------------------------------------------------------
    "bytesaslines": (QUEUE,
                     '            "bytes": sum(len(ln.encode("utf-8")) for ln in lines[e.lineno - 1:end]),',
                     '            "bytes": end - e.lineno + 1,'),
    "chunktotals": (QUEUE, "        if cur and cur + size > cap:", "        if totals and cur + size > cap:"),
    # --- the census -------------------------------------------------------------------------------
    "noexpand": (CENSUS, "            path = os.path.abspath(os.path.expanduser(part))",
                 "            path = os.path.abspath(part)"),
    "rootsopen": (CENSUS, "    if not roots:", "    if False:"),
    "minreposopen": (CENSUS, "    if repos < a.min_repos:", "    if False:"),
    # --- TASK 3: conservation, the four controls, and the seeds ------------------------------------
    # Each reverts exactly ONE behaviour. Where a control has two halves (basename and words in (c),
    # count and keyset in conservation) each half gets its own mutation, because a single mutation
    # covering both would let either assertion pass on the other one's failure.
    "nocount": (AGENT, "    if len(records) != len(rows):", "    if False:"),
    "nokeyset": (AGENT, "    for i in sorted(set(range(len(rows))) - covered):", "    for i in []:"),
    "nomulti": (AGENT, "    if len(set(returned)) != len(rows):", "    if False:"),
    "nounknown": (AGENT, "    unknown = [k for k in returned if k not in at]", "    unknown = []"),
    "noambig": (AGENT, "            if other is not None:", "            if False:"),
    # Control (a): the ledger's validator dropped, and the one-line rule dropped, separately.
    "noshape": (AGENT, "    problems = zl.validate_row(ledger_row(row, rec, stamp, lane), subject)",
                "    problems = []"),
    "multiline": (AGENT, '    if isinstance(ev, str) and ("\\n" in ev or "\\r" in ev):',
                  "    if False:"),
    # Control (b), and its NOT-VERIFIABLE exemption in the OTHER direction: the exemption mutant must
    # make the honest answer EXPENSIVE, which is the incentive failure the wording exists to prevent.
    "noresolve": (AGENT, "    bad = zv.unresolvable(str(rec.get(\"evidence\", \"\")), tree)",
                  "    bad = []"),
    "nvstrict": (AGENT,
                 '    if str(rec.get("verdict", "")) == zl.VERDICT_NOT_VERIFIABLE:\n        return []',
                 "    if False:\n        return []"),
    # Control (c), one mutation per mode and one per half.
    "nobasename": (AGENT,
                   "    if base and not archive_proof and os.path.basename(cited).lower() != base:",
                   "    if False:"),
    "nowordshalf": (AGENT, "    if len(hits) < MIN_WORDS:", "    if False:"),
    "window0": (AGENT, "WINDOW = 5", "WINDOW = 0"),
    "shortstrict": (AGENT, "    if len(words) < MIN_WORDS:", "    if False:"),
    "noarchiveproof": (AGENT, '    archive_proof = (str(rec.get("verdict", "")) == zl.VERDICT_STALE_FIXED',
                       "    archive_proof = (False"),
    "cscopeopen": (AGENT,
                   "    if str(rec.get(\"verdict\", \"\")) not in (zl.VERDICT_STILL_REAL, zl.VERDICT_STALE_FIXED):",
                   "    if False:"),
    # Control (d): the miss, the unanswered seed, the shortfall, the marker stripping, the interleave.
    "noseedcheck": (AGENT, "        elif got[key] != answers[key]:", "        elif False:"),
    "seedmissing": (AGENT, "        if key not in got:", "        if False:"),
    "shortopen": (SEEDS, '    short = "" if len(rows) == k else (', "    short = \"\" if True else ("),
    "nostrip": (SEEDS, "        rows.append(seed_row(key, zb.strip_resolution_markers(body), section))",
                "        rows.append(seed_row(key, body, section))"),
    "sortorder": (SEEDS, "    return sorted(rows, key=rank)",
                  '    return sorted(rows, key=lambda r: str((r.get("keys") or [r.get("id", "")])[0]))'),
    # The all-or-nothing append, and the sha's provenance.
    "partialappend": (AGENT, "    return Result([] if rejects else keep, rejects, controls)",
                      "    return Result(keep, rejects, controls)"),
    "seedstoledger": (AGENT, '        if str(rec.get("key", "")) not in answers:',
                      "        if True:"),
    "shafromrec": (AGENT, '            "text_sha": row.get("text_sha"),',
                   '            "text_sha": rec.get("text_sha", row.get("text_sha")),'),
    # --- TASK 4: the refusal gate, the write discipline, the delegation and the fail-closed pair ---
    # The gate itself: decision 10's refusal, and the NAMING of the shortfall as a separate mutation,
    # because a refusal that fires without saying which entries are missing sends a reader back to a
    # 265 KB file to diff two lists by hand — which is how a refusal stops being acted on.
    "nogate": (APPLY, "    if verified != total:", "    if False:"),
    "gateonkeys": (APPLY, "    verified, total, short = zl.coverage(entries, rows)",
                   "    verified, total, short = len(entries), len(entries), []"),
    "shortunnamed": (APPLY, "    for subject in short:", "    for subject in []:"),
    "ledgerlax": (APPLY, "    if read.defects:", "    if False:"),
    # The delegation: the scope oracle, the batching, the gate's per-invocation scope, and the two
    # dispositions that must never be reported as a closure that did not happen.
    "noscope": (APPLY, "    if int(m.group(1)) != len(want):", "    if False:"),
    "nomoveline": (APPLY, "    if m is None:", "    if False and m is None:"),
    "nogateenv": (APPLY, "    if heading:\n        env[HEADING_GATE] = \"1\"",
                  "    if False:\n        env[HEADING_GATE] = \"1\""),
    # The gate made PROCESS-GLOBAL, which is `B-20260928-HEADING-GATE-PROCESS-GLOBAL` exactly: it works
    # for the call that wants it and stays on for every later one, including a checkbox-only drop.
    "gateexported": (APPLY, "    env = dict(os.environ)\n    if heading:\n        env[HEADING_GATE] = \"1\"",
                     "    if heading:\n        os.environ[HEADING_GATE] = \"1\"\n    env = dict(os.environ)"),
    "dropunkeyed": (APPLY, "    keys = [a.entry.key for a in actions if a.verb == VERB_DROP]",
                    "    keys = [a.entry.key for a in actions]"),
    "falsearchived": (APPLY, '    return ("no-remedy",\n            f"{verdict} with nothing performable',
                      '    return ("archived",\n            f"{verdict} with nothing performable'),
    "dupismerge": (APPLY, "    if verdict == zl.VERDICT_DUPLICATE_OF:", "    if False:"),
    "stillrealcloses": (APPLY, "    if verdict == zl.VERDICT_STILL_REAL:", "    if False:"),
    # The two fail-closed directions, one mutation each. `guardalways` breaks the OTHER direction:
    # refusing when nothing is written would refuse every canonical backlog, which is the fail-OPEN
    # placement rule revision 5 had to correct the plan about.
    "noguardwrite": (APPLY, "    if zio.is_ignored(real) is None:", "    if False:"),
    "guardalways": (APPLY, "    if any(a.verb for a in actions):", "    if True:"),
    # The disposition write-back, and the stamp it must NOT bump: a fresh `verified_at` would claim the
    # entry was re-verified by the run that merely acted on it.
    "nodisposition": (APPLY, '        row["disposition"] = a.disposition', "        pass"),
    "bumpstamp": (APPLY, '        row["disposition"] = a.disposition',
                  '        row["disposition"] = a.disposition\n        row["verified_at"] = zl.now_stamp()'),
    # Decision 7, mutated the only way it can be: by ADDING the re-emission the decision forbids. A
    # ledger that carries a `rank` then moves lines in the open file, and the sha-identity assertion is
    # the only thing standing between that and option A shipping by accident.
    "reorderwrites": (GROOM, "    zap.report(actions)",
                      "    zap.report(actions)\n"
                      "    import zuvo_backlog_io as _zio\n"
                      "    _ranked = sorted(actions, key=lambda x: x.row.get(\"rank\", 0))\n"
                      "    if _ranked and not a.dry_run:\n"
                      "        _keep = [ln for i, ln in enumerate(loaded.lines, start=1)\n"
                      "                 if i not in {x.entry.lineno for x in _ranked}]\n"
                      "        _moved = [loaded.lines[x.entry.lineno - 1] for x in _ranked]\n"
                      "        _zio.atomic_write(loaded.real, \"\".join(_keep + _moved), None)"),
    # `apply` minting: the write the pre-pass owns, performed a second time by the command that must
    # own no write at all into the open file.
    "applymints": (GROOM, "    actions = zap.dispositions(loaded.entries, read.rows, loaded.archived)",
                   "    mint_write(loaded.real, mintable(loaded.lines, mint_set(loaded.entries))[0])\n"
                   "    actions = zap.dispositions(loaded.entries, read.rows, loaded.archived)"),
    # --- the signature window (PR 1's parser, mutated here only to prove what it protects) ---------
    # `normalize_signature`'s word window is anchored AFTER the path, over the resolution-STRIPPED
    # text. Keying it off the raw body instead is the one-line "tidy-up" that would make a prepended
    # `[DONE …]` marker rotate the content key — silently orphaning every verdict `groom` writes.
    "sigrawwindow": (PARSE, "        words = _WORD_RE.findall(clean[m.end():].lower())",
                     "        words = _WORD_RE.findall(body.lower())"),
    # --- Task 5: the working document ------------------------------------------------------------
    # Decision 11's gate, removed: a partially verified backlog renders without --partial.
    "nopartialgate": (RENDER, "    if verified == total or partial:\n        return",
                      "    if True:\n        return"),
    # --partial renders the ranking anyway — the half of decision 11 that is an ABSENCE.
    "partialranks": (RENDER, "    if not doc.partial:\n        out += _ranking(doc.scored)",
                     "    if True:\n        out += _ranking(doc.scored)"),
    # ...and the banner that carries the ratio.
    "partialnobanner": (RENDER,
                        '    if doc.partial:\n'
                        '        out += [PARTIAL_BANNER % (doc.verified, doc.total), ""]',
                        '    if False:\n'
                        '        out += [PARTIAL_BANNER % (doc.verified, doc.total), ""]'),
    # Decision 12's coverage field, gone from the header.
    "nocoveragestamp": (RENDER, '"coverage: %d/%d (%.1f%%)" % (doc.verified, doc.total, pct),',
                        '"coverage: unreported",'),
    # Decision 12's sha256 stops describing the source: the digest is taken over a constant, so the
    # document's provenance is unfalsifiable in the one direction AC10 exists to test.
    "shaconstant": (RENDER, "    return hashlib.sha256(raw).hexdigest(), len(raw)",
                    '    return hashlib.sha256(b"frozen").hexdigest(), len(raw)'),
    # The self-check block removed: a mismatch is no longer detectable FROM THE DOCUMENT.
    "noselfcheck": (RENDER, "    out.append(SELF_CHECK)", "    out.append('')"),
    # The NOT-VERIFIABLE section silently omitted instead of printed empty.
    "nonotverifiable": (RENDER, "    out += _not_verifiable(doc.scored)", "    out += []"),
    # --partial stops naming what it did not render, so the document describes a subset in silence.
    "nounverifiedsection": (RENDER, "    if doc.short:\n        out += _unverified(doc.short)",
                            "    if False:\n        out += _unverified(doc.short)"),
    # The ranking stops being scoped to the verdicts that KEEP an entry, so a closure is ranked as
    # outstanding work beside the dispositions that close it.
    "rankincludesstale": (RENDER,
                          "    keep = [s for s in scored\n"
                          "            if s.verdict in (zl.VERDICT_STILL_REAL, "
                          "zl.VERDICT_NOT_VERIFIABLE)]",
                          "    keep = list(scored)"),
    # `prioritize`'s formula flattened: every entry scores alike, so the ranking is subject order
    # wearing a score column.
    "scoreflat": (SCORE, "        return (self.impact + self.risk) * (6 - self.effort)",
                  "        return 7"),
    # Clustering by section only: the cited path stops deciding the theme.
    "clusterbysection": (SCORE, "    paths = zv.cited_paths(entry.body)\n    if paths:",
                         "    paths = zv.cited_paths(entry.body)\n    if False:"),
    # --- Task 5: the fleet lane, and the refusals that keep it read-only -------------------------
    # THE ONE THAT MATTERS. The fleet lane touches another checkout's backlog — `os.utime`, so it
    # changes an mtime without changing a byte, which is exactly what AC11's snapshot measures and
    # what a content-only check would miss.
    "fleettouchesrepo": (FLEET, "        _emit(host, repo, rows, dry_run)",
                         "        _emit(host, repo, rows, dry_run)\n"
                         "        _d = os.path.join(\n"
                         "            str(groups[(host, repo)][0].get(\"repo_path\", \"\")),\n"
                         "            \"memory\", \"backlog.md\")\n"
                         "        if os.path.exists(_d):\n"
                         "            os.utime(_d, None)"),
    # `apply --fleet` stops refusing, so decision 13's "there is no fleet grooming" is prose.
    "fleetnorefuse": (FLEET, "    if not flag:\n        return", "    if True:\n        return"),
    # A disposition on a `source=index` row stops refusing — a closure decided from a 400-character
    # prefix of an entry.
    "fleetnoindexrefuse": (FLEET, "    if not bad:\n        return",
                           "    if True:\n        return"),
    # The rows stop carrying their provenance, so nothing downstream can tell a fleet verdict from
    # one made in the checkout.
    "fleetnosource": (FLEET,
                      '"source": SOURCE_INDEX, "host": str(row["host"]), "repo": str(row["repo"])})',
                      '"host": str(row["host"]), "repo": str(row["repo"])})'),
    # An empty or unusable snapshot reads as a clean pass over nothing.
    "fleetemptyok": (FLEET, "    if not read.rows:", "    if False:"),
}


def sub(text, old, new, what):
    if text.count(old) != 1:
        sys.exit("mkmut2: %s occurs %dx, expected once — the mutation would not apply: %r"
                 % (what, text.count(old), old))
    return text.replace(old, new)


os.makedirs(OUT, exist_ok=True)
names = [GROOM, CENSUS, ARCHIVE]
names += [os.path.basename(p) for p in sorted(glob.glob(os.path.join(SRC, "zuvo_backlog_*.py")))]
for name in names:
    shutil.copyfile(os.path.join(SRC, name), os.path.join(OUT, name))
if KIND != "none":
    if KIND not in MUTATIONS:
        sys.exit("mkmut2: unknown mutation %r" % KIND)
    target, old, new = MUTATIONS[KIND]
    dest = os.path.join(OUT, target)
    with open(dest, encoding="utf-8") as fh:
        text = fh.read()
    with open(dest, "w", encoding="utf-8") as fh:
        fh.write(sub(text, old, new, KIND))
PYEOF

probe2(){ python3 "$T2PROBE" "$@"; }
mut2_build(){ python3 "$MKMUT2" "$SCRIPTS" "$1" "$T2/mut-$1" >"$T2/mk-$1.log" 2>&1; }
mut2_failed(){
  no "(MU) mutant '$1' did NOT build: $(tail -1 "$T2/mk-$1.log") — its substitution no longer applies, so the assertion it targets would pass on a mutant that does not exist"
}
bytes2(){ if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }
lines2(){ if [ -f "$1" ]; then awk 'END{print NR}' "$1"; else echo 0; fi; }

if mut2_build none; then
  ok "(Q0) the Task 2 mutant factory writes its CONTROL copy — a failing mutant below is a mutation, not a copy"
else
  no "(Q0) the Task 2 factory cannot write an unmutated copy ($(tail -1 "$T2/mk-none.log")) — every mutant assertion here would be vacuous"
  finish
fi
CTL2="$T2/mut-none"
groom(){ python3 "$CTL2/backlog-groom.py" "$@"; }
census(){ python3 "$CTL2/backlog-census.py" "$@"; }

if probe2 "$CTL2" expand "$T2" >"$T2/import.out" 2>"$T2/import.err"; then
  ok "(Q0b) the Task 2 probe imports all four files and runs"
else
  no "(Q0b) the Task 2 probe could not run: $(tail -3 "$T2/import.err") — nothing below can be checked"
  finish
fi

# ==================================================================================================
# The fixture repo: ONE tracked git repo whose backlog holds a KNOWN entry per deterministic class,
# the two mintable checkboxes, the plain bullet `mint_into` refuses, an ordinal-id bullet, a template
# row, an undecidable entry, and the two files the obsolete class needs (one present, one absent).
# ==================================================================================================
FR="$T2/repo"
mkdir -p "$FR/memory" "$FR/tools"
( cd "$FR" && git init -q . >/dev/null 2>&1 ) || no "(Q0c) could not git init the Task 2 fixture repo"
printf 'print("present")\n' > "$FR/tools/present.py"
cat > "$FR/memory/backlog.md" <<'EOF'
# Tech Debt Backlog

## Open

- [ ] B-mint-one tools/present.py an entry with an id and nothing decidable about it
- [ ] tools/present.py a CHECKBOX entry with no id at all, so it is mintable
- [x] tools/present.py a second mintable checkbox, ticked but recording no outcome
- plain bullet with no id and no checkbox, which mint_into refuses by contract
- B-9 tools/present.py an ordinal id definition_id cannot see, minting would double it
- [ ] B-marker-one tools/present.py the loader leaks a handle — DONE 9f2c1a4
- [ ] B-archived-one tools/present.py the retry budget is unbounded
- [ ] B-91 tools/present.py identical duplicate content words here
- [ ] B-92 tools/present.py identical duplicate content words here
- [ ] B-gone-one tools/vanished.py the helper it patches is not in the tree
- [ ] B-tpl-one severity: [ fingerprint | source-task ] the template row
- [ ] B-plain-one tools/present.py nothing here is decidable from the bytes
EOF
cat > "$FR/memory/backlog-done.md" <<'EOF'
# Archived

## Archived from backlog.md on 2026-09-01 (2 entries)

- [x] B-archived-one tools/present.py the retry budget is unbounded — FIXED 1a2b3c4
- [x] B-marker-one tools/present.py the loader leaks a handle — FIXED 9f2c1a4
EOF
CLSARGS="$FR/memory/backlog.md $FR/memory/backlog-done.md $FR"
# An EMPTY archive, for the fixtures whose classes must not see one, and a heading entry that only the
# LOOSE marker guard reads as resolved: the id itself contains STALE, and `heading_resolution_pos`
# strips the id before it scans. 33 fleet-wide entries were decided that way, 3 of them in this repo.
: > "$T2/no-archive.md"
cat > "$T2/heading-loose.md" <<'EOF'
# Backlog

## B-heading-STALE-OPEN-DUPLICATES tools/present.py the id itself contains a verdict word
EOF

echo "-- QC: the Task 2 fixture, censused from its own bytes --"
probe2 "$CTL2" classify $CLSARGS >"$T2/cls.out" 2>"$T2/cls.err" \
  || { no "(QC0) the classify probe could not run: $(tail -3 "$T2/cls.err")"; finish; }
cat "$T2/cls.out"
cv(){ sed -n "s/^$1=//p" "$T2/cls.out" | head -1; }
echo "  fixture: $(lines2 "$FR/memory/backlog.md") lines on disk, entries=$(cv NENTRIES)"
[ "$(cv NENTRIES)" = "11" ] \
  && ok "(QC1) the fixture yields 11 entries — 12 entry-shaped lines minus the TEMPLATE_RE row" \
  || no "(QC1) the fixture yields $(cv NENTRIES) entries, not 11; every count below would be about a different file"
grep -qF 'severity: [ fingerprint | source-task ]' "$FR/memory/backlog.md" \
  && ok "(QC2) the TEMPLATE_RE row is physically in the fixture, so 'a template is not an entry' is not a claim about an absent case" \
  || no "(QC2) the template row is missing from the fixture"
grep -qE '^V=B-tpl-one\|' "$T2/cls.out" \
  && no "(QC2b) the template row was classified — a template is not an entry" \
  || ok "(QC2b) the template row is not an entry and gets no verdict"
if [ -f "$FR/tools/present.py" ] && [ ! -e "$FR/tools/vanished.py" ]; then
  ok "(QC3) tools/present.py exists and tools/vanished.py does not — the resolvable and the absent halves are both real"
else
  no "(QC3) the fixture's present/absent files are not as the obsolete class needs"
fi
QC_SIG="$(python3 -c "
import sys
sys.path.insert(0, sys.argv[1])
import zuvo_backlog_parse as zb
a = zb.entry_key('B-91 tools/present.py identical duplicate content words here', 'B-91')
b = zb.entry_key('B-92 tools/present.py identical duplicate content words here', 'B-92')
print('%s %s %d' % (a, b, int(a == b)))" "$CTL2")"
case "$QC_SIG" in
  "fp:"*" fp:"*" 1") ok "(QC4) B-91 and B-92 really share ONE content key ($QC_SIG) — ordinal ids fall back to the signature, which is what makes them a duplicate pair" ;;
  *) no "(QC4) the duplicate pair does not share a key: $QC_SIG — the duplicate assertions would be about two unrelated entries" ;;
esac

# ==================================================================================================
# E — the four deterministic classes, their evidence shapes, and resolvability
# ==================================================================================================
echo "-- E: every deterministic class emits a verdict AND a resolvable evidence line --"
e_row(){ grep -E "^V=$1\|" "$T2/cls.out" | head -1; }
e_check(){  # id, class, verdict, substring the evidence must contain, label
  local row; row="$(e_row "$1")"
  if [ -z "$row" ]; then no "(E) $5: no verdict at all for $1"; return; fi
  case "$row" in
    "V=$1|$2|$3|"*) : ;;
    *) no "(E) $5: $1 came back as '$row', expected class=$2 verdict=$3"; return ;;
  esac
  case "$row" in
    *"$4"*) ok "(E) $5 (evidence names '$4')" ;;
    *) no "(E) $5: the evidence does not name '$4': $row" ;;
  esac
}
e_check B-marker-one   marker    STALE-FIXED    'backlog.md:'      "a recorded resolution marker is STALE-FIXED, citing its own backlog line"
e_check B-archived-one archived  STALE-FIXED    'backlog-done.md:' "a key already in the archive is STALE-FIXED, citing the archive line"
e_check B-92           duplicate DUPLICATE-OF   'backlog.md:'      "a colliding key is DUPLICATE-OF, citing a backlog line"
e_check B-gone-one     obsolete  STALE-OBSOLETE 'does not exist'   "an entry whose every cited path is absent is STALE-OBSOLETE"
case "$(e_row B-marker-one)" in
  *'"DONE'*|*'DONE'*) ok "(E1b) the marker evidence QUOTES the marker clause, so a reader sees which words decided it" ;;
  *) no "(E1b) the marker evidence does not quote the clause: $(e_row B-marker-one)" ;;
esac
case "$(e_row B-archived-one)" in
  *'section="'*) ok "(E2b) the archive evidence names the archive SECTION the key sits in" ;;
  *) no "(E2b) no section= in the archive evidence: $(e_row B-archived-one)" ;;
esac

# THE AMENDMENT. `verdict` is exactly `DUPLICATE-OF`; the other entry's key rides in `evidence`.
E_DUP="$(e_row B-92)"
case "$E_DUP" in
  *"|DUPLICATE-OF|"*) ok "(E3) the verdict field is EXACTLY 'DUPLICATE-OF' — a variable payload there cannot be validated against a closed set of five, which is why revision 5 moved the key" ;;
  *) no "(E3) the verdict field carries a payload: $E_DUP" ;;
esac
case "$E_DUP" in
  *"fp:"*) ok "(E3b) the other entry's key is in the EVIDENCE, which is where a closed vocabulary can carry it" ;;
  *) no "(E3b) the duplicate evidence names no id:/fp: key: $E_DUP" ;;
esac
E_DUP_LOCS="$(printf '%s\n' "$E_DUP" | grep -oE 'backlog\.md:[0-9]+' | sort -u | wc -l | tr -d ' ')"
[ "$E_DUP_LOCS" = "2" ] \
  && ok "(E3c) BOTH line numbers are present — the report shape, never a licence to merge" \
  || no "(E3c) the duplicate evidence carries $E_DUP_LOCS distinct backlog.md line(s), expected 2: $E_DUP"
grep -qE '^V=B-91\|' "$T2/cls.out" \
  && no "(E3d) the FIRST entry of the colliding pair was also marked DUPLICATE-OF — then neither has an entry left to point at" \
  || ok "(E3d) only the later entry of the pair is marked; the first is the anchor it reports against"

# The obsolete class cites the BACKLOG line, not the missing path: a citation of the missing path could
# not resolve, so control (b) would reject every correct row of this class.
case "$(e_row B-gone-one)" in
  *'|backlog.md:'*) ok "(E4) STALE-OBSOLETE cites backlog.md, with the absence stated in the text" ;;
  *) no "(E4) STALE-OBSOLETE cites something else: $(e_row B-gone-one)" ;;
esac
case "$(e_row B-gone-one)" in
  *tools/vanished.py*) ok "(E4b) the absent path is NAMED in the evidence text, so a reader can check the absence itself" ;;
  *) no "(E4b) the evidence does not name the absent path: $(e_row B-gone-one)" ;;
esac

# RESOLVABILITY, for EVERY emitted row: the cited file exists and has at least the cited line.
E_UNRES="$(grep '^RESOLVES=' "$T2/cls.out" | grep -vc '|ALL$' || true)"
[ "${E_UNRES:-1}" = "0" ] \
  && ok "(E5/AC3) every deterministic row's evidence RESOLVES — asserted resolvable, not merely non-empty" \
  || no "(E5/AC3) $E_UNRES row(s) cite something that does not resolve: $(grep '^RESOLVES=' "$T2/cls.out" | grep -v '|ALL$' | head -2)"
[ "$(grep -c '^RESOLVES=' "$T2/cls.out")" = "$(cv NVERDICTS)" ] \
  && ok "(E5b/AC3) the resolvability check ran on all $(cv NVERDICTS) rows — a check that ran on none would also report zero failures" \
  || no "(E5b/AC3) $(grep -c '^RESOLVES=' "$T2/cls.out") resolvability results for $(cv NVERDICTS) verdicts"
E_BADROW="$(grep '^LEDGERROW=' "$T2/cls.out" | grep -vc '|0|-$' || true)"
[ "${E_BADROW:-1}" = "0" ] \
  && ok "(E6) every deterministic row passes the LEDGER's own validate_row — the pre-pass cannot write a row its reader would reject" \
  || no "(E6) $E_BADROW row(s) fail validate_row: $(grep '^LEDGERROW=' "$T2/cls.out" | grep -v '|0|-$' | head -2)"

# An entry the bytes do not answer gets NOTHING. Inventing a NOT-VERIFIABLE here would make coverage
# read full with nobody having looked — the exact failure the gate exists to prevent.
grep -qE '^V=B-plain-one\|' "$T2/cls.out" \
  && no "(E7) an undecidable entry was given a deterministic verdict — coverage would read full with nobody having looked" \
  || ok "(E7) an entry the bytes do not answer gets NO deterministic verdict; it stays the model's work"
[ "$(cv NVERDICTS)" = "4" ] \
  && ok "(E8) exactly 4 of the 11 entries are decided deterministically — one per class" \
  || no "(E8) $(cv NVERDICTS) deterministic verdicts, expected 4: $(grep '^V=' "$T2/cls.out" | tr '\n' ' ')"
[ "$(cv NREFUSED)" = "0" ] \
  && ok "(E9) nothing was refused on the clean fixture — the refusal path is not firing here by accident" \
  || no "(E9) $(cv NREFUSED) refusal(s) on the clean fixture: $(grep '^REFUSED=' "$T2/cls.out" | head -1)"
# PRECEDENCE, stated so it can fail: B-marker-one is in BOTH the open file (with a marker) and the
# archive, so the order marker > archived is what decides it.
case "$(e_row B-marker-one)" in
  *'|marker|'*) ok "(E10) an entry that is BOTH markered and archived is classed \`marker\` — its own recorded closure outranks an inference from the archive" ;;
  *) no "(E10) the precedence changed: $(e_row B-marker-one)" ;;
esac

# ---- control (b) asked directly, one shape per line -----------------------------------------------
probe2 "$CTL2" resolve "$FR/memory/backlog.md" "$FR/memory/backlog-done.md" "$FR" \
  "backlog.md:1 the first line of the backlog" \
  "backlog.md:99999 far past the end of the file" \
  "tools/vanished.py:1 a file that is not there" \
  "a reason in prose with no citation at all" >"$T2/res.out" 2>&1
cat "$T2/res.out"
grep -qx 'RES=1|ALL' "$T2/res.out" \
  && ok "(E11) control: a citation that really resolves is accepted — the three rejections below are rejections of the CHANGE" \
  || no "(E11) a resolvable citation was rejected: $(grep '^RES=1' "$T2/res.out")"
grep -q '^RES=2|.*the file has [0-9]* line' "$T2/res.out" \
  && ok "(E12) a line number PAST THE END is rejected, naming the real line count — the half of (b) that catches a plausible fabrication" \
  || no "(E12) a line past the end was accepted: $(grep '^RES=2' "$T2/res.out")"
grep -q '^RES=3|.*no such file' "$T2/res.out" \
  && ok "(E13) a citation naming a file that is not there is rejected" \
  || no "(E13) a missing file was accepted: $(grep '^RES=3' "$T2/res.out")"
grep -q '^RES=4|.*no .path:line. citation' "$T2/res.out" \
  && ok "(E14) evidence with no citation at all is rejected for a class that owes one" \
  || no "(E14) citation-free evidence was accepted: $(grep '^RES=4' "$T2/res.out")"

# ---- the pre-mint bridge: a collision visible ONLY through keys_for -------------------------------
cat > "$T2/preminted.md" <<'EOF'
## Open

- [ ] B-A20260101-abcdef tools/present.py shared duplicate content words here
- [ ] tools/present.py shared duplicate content words here
EOF
PRE_SHARED="$(python3 -c "
import sys
sys.path.insert(0, sys.argv[1])
import zuvo_backlog_parse as zb
a = zb.keys_for('B-A20260101-abcdef tools/present.py shared duplicate content words here',
                'B-A20260101-abcdef')
b = zb.keys_for('tools/present.py shared duplicate content words here', '')
print('%d %d %d' % (len(a), len(b), len(a & b)))" "$CTL2")"
case "$PRE_SHARED" in
  "2 1 1") ok "(E15a) the pre-minted pair shares exactly one key, and only through keys_for's pre-mint bridge ($PRE_SHARED)" ;;
  *) no "(E15a) the pre-minted fixture does not have the shape E15 asserts: $PRE_SHARED" ;;
esac
probe2 "$CTL2" classify "$T2/preminted.md" "$T2/no-archive.md" "$FR" >"$T2/pre.out" 2>&1
grep -qE '^V=.*\|duplicate\|' "$T2/pre.out" \
  && ok "(E15) a collision visible ONLY through the PRE-MINT key is still detected — keyed on keys_for, because entry_key prefers id: and stops reading the text once an id is minted" \
  || no "(E15) the pre-mint collision was missed: $(grep '^V=' "$T2/pre.out" | tr '\n' ' ')"

probe2 "$CTL2" classify "$T2/heading-loose.md" "$T2/no-archive.md" "$FR" >"$T2/hl.out" 2>&1
[ "$(sed -n 's/^NENTRIES=//p' "$T2/hl.out" | head -1)" = "1" ] \
  && ok "(E16a) the loose-guard fixture yields exactly 1 heading entry, so E16 is about it and not about an empty file" \
  || no "(E16a) the loose-guard fixture yields $(sed -n 's/^NENTRIES=//p' "$T2/hl.out" | head -1) entries, not 1"
grep -qE '^V=.*\|marker\|' "$T2/hl.out" \
  && no "(E16) a heading whose ID contains STALE was read as resolved — the loose guard's 33 fleet-wide false positives, every one of them in the archivable direction" \
  || ok "(E16) a heading whose ID contains a verdict word is NOT resolved: heading_resolution_pos strips the id before it scans"

# ==================================================================================================
# N — the mint pre-pass: selection, the identity check, and AC8' write discipline
# ==================================================================================================
echo "-- N: the mint pre-pass --"
probe2 "$CTL2" mintsel "$FR/memory/backlog.md" >"$T2/sel.out" 2>&1
nv(){ sed -n "s/^$1=//p" "$T2/sel.out" | head -1; }
cat "$T2/sel.out"
[ "$(nv MINT_SET)" = "4" ] \
  && ok "(N1) the mint set is the 4 entries iter_entries yields with no \`ident\` — two checkboxes and two bullets" \
  || no "(N1) the mint set is $(nv MINT_SET) on a fixture built to hold 4"
[ "$(nv MINTABLE)" = "2" ] \
  && ok "(N2) only 2 of the 4 are MINTABLE — and that gap between the plan's number and reality is the single most important measured fact here" \
  || no "(N2) $(nv MINTABLE) mintable of $(nv MINT_SET); the fixture holds exactly 2 anchored, id-free entries"
[ "$(grep -c '^MINT=.*kind=checkbox' "$T2/sel.out")" = "2" ] \
  && ok "(N2b) both mintable entries are the CHECKBOX dialect, which is one of the two mint_into admits" \
  || no "(N2b) $(grep -c '^MINT=' "$T2/sel.out") mint target(s), not 2 checkboxes: $(grep '^MINT=' "$T2/sel.out" | tr '\n' ' ')"
grep -q '^SKIP=.*no mint anchor' "$T2/sel.out" \
  && ok "(N3) the plain bullet is skipped WITH ITS REASON — mint_into admits only the checkbox and flush-heading dialects, pinned as refused in test-backlog-headings.sh (H20/AC7)" \
  || no "(N3) the unanchored entry was dropped without a reason: $(grep '^SKIP=' "$T2/sel.out" | tr '\n' ' ')"
grep -q '^SKIP=.*already shows a B-id' "$T2/sel.out" \
  && ok "(N4) an entry DISPLAYING a B-id that \`definition_id\` cannot see is not minted — a second id on one line, with entry_key preferring the new one, is worse than the content key it replaces" \
  || no "(N4) the body-id filter did not fire on the ordinal bullet: $(grep '^SKIP=' "$T2/sel.out" | tr '\n' ' ')"

# ---- the identity check, reached without a race ---------------------------------------------------
sed 's/a CHECKBOX entry with no id at all/a CHECKBOX entry whose text MOVED/' \
  "$FR/memory/backlog.md" > "$T2/moved.md"
cmp -s "$FR/memory/backlog.md" "$T2/moved.md" \
  && no "(N5a) the moved-file fixture is identical to its source, so N5 would assert nothing" \
  || ok "(N5a) the moved-file fixture really differs from the one the entries were parsed from"
probe2 "$CTL2" mintlines "$FR/memory/backlog.md" "$T2/moved.md" >"$T2/ml.out" 2>&1
mlv(){ sed -n "s/^$1=//p" "$T2/ml.out" | head -1; }
cat "$T2/ml.out"
[ "$(mlv CLEAN_BAD)" = "0" ] && [ "$(mlv TARGETS)" = "2" ] \
  && ok "(N5b) control: mint_lines against the lines it parsed refuses none of its 2 targets" \
  || no "(N5b) the clean call refused $(mlv CLEAN_BAD) of $(mlv TARGETS) — N5 below would be vacuous"
N_MB="$(mlv MOVED_BAD)"
if [ "${N_MB:-0}" -ge 1 ] && grep -q '^MOVEDMSG=.*moved' "$T2/ml.out"; then
  ok "(N5) the \`lines[idx].rstrip(\"\\r\\n\") != e.raw\` identity check ABORTS when the line moved between the read and the write — $N_MB refusal(s), each naming the line"
else
  no "(N5) a line that moved under the read was minted anyway, or the refusal does not name it: MOVED_BAD='$N_MB' $(grep -c '^MOVEDMSG=' "$T2/ml.out") message(s)"
fi
N_LC="$(mlv CLEAN_LINES)"
[ "${N_LC%%->*}" = "${N_LC##*->}" ] \
  && ok "(N6) minting leaves the LINE COUNT unchanged ($N_LC) — an id belongs inside an existing line" \
  || no "(N6) minting moved the line count: $N_LC"

# ---- AC8': the locked write on a temp copy --------------------------------------------------------
mk_wrepo(){  # $1 = dir
  mkdir -p "$1/memory" "$1/tools" || return 1
  ( cd "$1" && git init -q . >/dev/null 2>&1 ) || return 1
  cp "$FR/memory/backlog.md" "$1/memory/backlog.md" || return 1
  cp "$FR/memory/backlog-done.md" "$1/memory/backlog-done.md" || return 1
  cp "$FR/tools/present.py" "$1/tools/present.py" || return 1
}
WR="$T2/wrepo"
mk_wrepo "$WR" || no "(N7a) could not build the write fixture repo"
chmod 600 "$WR/memory/backlog.md"
W_B0="$(bytes2 "$WR/memory/backlog.md")"; W_L0="$(lines2 "$WR/memory/backlog.md")"
groom plan --repo "$WR" >"$T2/w1.out" 2>&1; W_RC=$?
W_B1="$(bytes2 "$WR/memory/backlog.md")"; W_L1="$(lines2 "$WR/memory/backlog.md")"
W_INS="$(sed -n 's/^INSERTED_BYTES=//p' "$T2/w1.out" | head -1)"
if [ "$W_RC" -eq 0 ] && [ -n "$W_INS" ] && [ "$W_INS" -gt 0 ]; then
  ok "(N7) the write run succeeded and reports $W_INS inserted bytes"
else
  no "(N7) rc=$W_RC INSERTED_BYTES='$W_INS' — $(tail -3 "$T2/w1.out")"
fi
[ "$((W_B1 - W_B0))" = "${W_INS:-x}" ] \
  && ok "(N8/AC8′) the file's byte delta is EXACTLY the sum of the inserted ids: $W_B0 -> $W_B1 = +$W_INS" \
  || no "(N8/AC8′) the byte delta is $((W_B1 - W_B0)) but ${W_INS:-?} bytes of id were inserted — something else changed too"
[ "$W_L0" = "$W_L1" ] \
  && ok "(N9/AC8′) the line count is unchanged at $W_L1" \
  || no "(N9/AC8′) the line count moved $W_L0 -> $W_L1"
W_MODE="$(python3 -c "import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" "$WR/memory/backlog.md")"
[ "$W_MODE" = "0o600" ] \
  && ok "(N10/AC8′) the 0600 mode survives the atomic replace" \
  || no "(N10/AC8′) the mode is now $W_MODE, was 0o600"
W_MINTED="$(grep -cE '^- \[[ xX]\] B-A[0-9]{8}-[0-9a-f]{6} ' "$WR/memory/backlog.md" || true)"
[ "$W_MINTED" = "2" ] \
  && ok "(N11/AC8′) both ids landed at body position 0 in MINTED_ID_RE's shape — which is exactly what keys_for strips to recover the pre-mint content key" \
  || no "(N11/AC8′) $W_MINTED line(s) carry a minted id in the right shape, expected 2"
python3 - "$WR/memory/backlog.md" "$FR/memory/backlog.md" >"$T2/strip.out" 2>&1 <<'PYEOF'
import re
import sys
with open(sys.argv[1], encoding="utf-8") as fh:
    got = fh.read()
with open(sys.argv[2], encoding="utf-8") as fh:
    want = fh.read()
stripped = re.sub(r"(?m)^(- \[[ xX]\] )B-A\d{8}-[0-9a-f]{6} ", r"\1", got)
print("IDENTICAL=%d" % int(stripped == want))
print("NSTRIPPED=%d" % len(re.findall(r"B-A\d{8}-[0-9a-f]{6} ", got)))
PYEOF
if grep -qx 'IDENTICAL=1' "$T2/strip.out" && grep -qx 'NSTRIPPED=2' "$T2/strip.out"; then
  ok "(N12/AC8′) removing the 2 minted ids restores the file BYTE-IDENTICALLY — the mint touched nothing else on any line"
else
  no "(N12/AC8′) the file differs from its source beyond the minted ids: $(tr '\n' ' ' < "$T2/strip.out")"
fi
cp "$WR/memory/backlog.md" "$T2/after1.md"
groom plan --repo "$WR" >"$T2/w2.out" 2>&1; W_RC2=$?
if [ "$W_RC2" -eq 0 ] && cmp -s "$T2/after1.md" "$WR/memory/backlog.md"; then
  ok "(N13/AC8′) a second run is a byte-identical no-op (MINTABLE=$(sed -n 's/^MINTABLE=//p' "$T2/w2.out" | head -1))"
else
  no "(N13/AC8′) the second run changed the file (rc=$W_RC2)"
fi
W_CN="$(sed -n 's/^COUNT_NEUTRAL=//p' "$T2/w1.out" | head -1)"
[ "$W_CN" = "11/11" ] \
  && ok "(N14) minting is COUNT-NEUTRAL: $W_CN, checked by RE-PARSING the minted text rather than assumed" \
  || no "(N14) COUNT_NEUTRAL reads '$W_CN' on an 11-entry fixture"
[ "$(sed -n 's/^ENTRIES=//p' "$T2/w2.out" | head -1)" = "11" ] \
  && ok "(N14b) the minted file still yields 11 entries on a FRESH parse — the neutrality claim survives a second reader" \
  || no "(N14b) the minted file yields $(sed -n 's/^ENTRIES=//p' "$T2/w2.out" | head -1) entries, not 11"

# ---- the id-less headings: REPORTED, and never written into ---------------------------------------
W_IH="$(sed -n 's/^IDLESS_HEADINGS=//p' "$T2/w1.out" | head -1)"
[ "${W_IH:-0}" -ge 2 ] \
  && ok "(N14c) the run REPORTS its $W_IH id-less heading-shaped lines by line and text — PR 1's decision 1 is that they are reported, not minted" \
  || no "(N14c) IDLESS_HEADINGS=${W_IH:-?}; the fixture holds at least '# Tech Debt Backlog' and '## Open'"
grep -q '^IDLESS_HEADING=:.* ## Open' "$T2/w1.out" \
  && ok "(N14d) the report names the plain section header itself, so a reader can see it is structure and not an entry" \
  || no "(N14d) the report does not name '## Open': $(grep '^IDLESS_HEADING=' "$T2/w1.out" | tr '\n' ' ')"
W_HEADMINT="$(grep -cE '^#{1,6} .*B-A[0-9]{8}-[0-9a-f]{6}' "$WR/memory/backlog.md" || true)"
[ "$W_HEADMINT" = "0" ] \
  && ok "(N14e) NO heading line gained a minted id — mint_into would happily accept a flush-left heading, so what keeps the id out of the file structure is the mint set being built from iter_entries output" \
  || no "(N14e) $W_HEADMINT heading line(s) now carry a minted id — an identifier was written into the structure of a tracked file"
W_TPL="$(sed -n 's/^TEMPLATES=//p' "$T2/w1.out" | head -1)"
[ "$W_TPL" = "1" ] \
  && ok "(N14f) the run counts the 1 TEMPLATE_RE row it dropped — 'a template is not an entry' is an observable number rather than an invisible absence" \
  || no "(N14f) TEMPLATES=$W_TPL on a fixture holding exactly one template row"

WCR="$T2/wcrlf"
mk_wrepo "$WCR" || no "(N15a) could not build the CRLF repo"
python3 -c "
import io, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as fh: t = fh.read()
with io.open(p, 'w', encoding='utf-8', newline='') as fh: fh.write(t.replace('\n', '\r\n'))
" "$WCR/memory/backlog.md"
crlf_count(){ python3 -c "import sys;print(open(sys.argv[1],'rb').read().count(b'\r\n'))" "$1"; }
WCR_CR0="$(crlf_count "$WCR/memory/backlog.md")"
groom plan --repo "$WCR" >"$T2/wcr.out" 2>&1; WCR_RC=$?
WCR_CR1="$(crlf_count "$WCR/memory/backlog.md")"
if [ "$WCR_RC" -eq 0 ] && [ "$WCR_CR0" = "$WCR_CR1" ] && [ "$WCR_CR0" -gt 5 ]; then
  ok "(N15/AC8′) a CRLF backlog keeps all $WCR_CR1 CRLF terminators through the mint — the identity check rstrips \"\\r\\n\", and comparing the wrong one made every entry on a CRLF backlog refuse for ever"
else
  no "(N15/AC8′) rc=$WCR_RC and the CRLF count went $WCR_CR0 -> $WCR_CR1"
fi
WSY="$T2/wsym"
mk_wrepo "$WSY" || no "(N16a) could not build the symlink repo"
# The canonical file gets its OWN git repo, and that is not decoration: `resolve()` hands back the
# REALPATH, so `is_ignored()` is asked about THIS directory — outside a repo it answers None and the
# write refuses (N17) before the symlink property could be measured at all. Two fail-closed rules in
# one fixture would make a red here unattributable.
mkdir -p "$T2/canon"
( cd "$T2/canon" && git init -q . >/dev/null 2>&1 ) || no "(N16b) could not git init the canonical dir"
command mv "$WSY/memory/backlog.md" "$T2/canon/backlog.md"
ln -s "$T2/canon/backlog.md" "$WSY/memory/backlog.md"
groom plan --repo "$WSY" >"$T2/wsy.out" 2>&1; WSY_RC=$?
if [ "$WSY_RC" -eq 0 ] && [ -L "$WSY/memory/backlog.md" ]; then
  ok "(N16/AC8′) a SYMLINKED backlog is still a symlink afterwards, and the minted ids are in the file it points AT — atomic_write replaces the REALPATH, never the link (the 2026-07-19 fork-the-backlog incident)"
else
  no "(N16/AC8′) rc=$WSY_RC; the symlink is $( [ -L "$WSY/memory/backlog.md" ] && echo intact || echo GONE)"
fi
[ "$(grep -cE '^- \[[ xX]\] B-A[0-9]{8}-[0-9a-f]{6} ' "$T2/canon/backlog.md" || true)" = "2" ] \
  && ok "(N16c/AC8′) the 2 ids landed in the TARGET file, so the write went through the link rather than replacing it" \
  || no "(N16c/AC8′) the canonical target holds $(grep -cE '^- \[[ xX]\] B-A[0-9]{8}-[0-9a-f]{6} ' "$T2/canon/backlog.md" || true) minted id(s), not 2"

# ---- the two fail-closed decisions, in OPPOSITE directions, in the SAME directory ----------------
NOGIT2="$T2/nogit"
mkdir -p "$NOGIT2/memory" "$NOGIT2/tools"
cp "$FR/memory/backlog.md" "$NOGIT2/memory/backlog.md"
cp "$FR/tools/present.py" "$NOGIT2/tools/present.py"
NG_B0="$(bytes2 "$NOGIT2/memory/backlog.md")"
groom plan --repo "$NOGIT2" >"$T2/ng.out" 2>&1; NG_RC=$?
NG_B1="$(bytes2 "$NOGIT2/memory/backlog.md")"
if [ "$NG_RC" -eq 20 ] && [ "$NG_B0" = "$NG_B1" ]; then
  ok "(N17) the WRITE path fails CLOSED on \`is_ignored() is None\`: rc=$NG_RC outside a git repository, $NG_B1 bytes unchanged"
else
  no "(N17) rc=$NG_RC (expected 20) and $NG_B0 -> $NG_B1 bytes — a write whose publishability is unknown went ahead"
fi
grep -q 'cannot tell whether' "$T2/ng.out" \
  && ok "(N17b) the refusal says WHY and what to do instead" \
  || no "(N17b) the refusal does not explain itself: $(head -2 "$T2/ng.out")"
if probe "$CTL" append "$NOGIT2" "$ROWS_JSON" >"$T2/ngled.out" 2>&1; then
  ok "(N18) the LEDGER's PLACEMENT check fails OPEN in that SAME non-repo directory — the canonical backlog lives outside a repo and 'unknown' must not read as 'tracked'. Both directions, one line apart in the code, which is why revision 5 had to correct the plan"
else
  no "(N18) the ledger refused outside a repo ($(tail -2 "$T2/ngled.out")) — then no canonical backlog could ever be verified"
fi

WD="$T2/wdry"
mk_wrepo "$WD" || no "(N19a) could not build the dry-run repo"
WD_B0="$(bytes2 "$WD/memory/backlog.md")"
groom plan --repo "$WD" --dry-run >"$T2/wd.out" 2>&1; WD_RC=$?
WD_B1="$(bytes2 "$WD/memory/backlog.md")"
WD_Q="$(sed -n 's/^QUEUE=\([^ ]*\) .*/\1/p' "$T2/wd.out" | head -1)"
if [ "$WD_RC" -eq 0 ] && [ "$WD_B0" = "$WD_B1" ] && [ -n "$WD_Q" ] && [ ! -e "$WD_Q" ] \
   && [ ! -e "$WD/memory/backlog-verdicts.jsonl" ]; then
  ok "(N19) --dry-run writes NOTHING — backlog unchanged at $WD_B1 bytes, no queue, no ledger — while still running every invariant (COUNT_NEUTRAL=$(sed -n 's/^COUNT_NEUTRAL=//p' "$T2/wd.out" | head -1))"
else
  no "(N19) rc=$WD_RC bytes $WD_B0->$WD_B1 queue='$WD_Q' $( [ -e "$WD_Q" ] && echo WRITTEN) ledger=$( [ -e "$WD/memory/backlog-verdicts.jsonl" ] && echo WRITTEN || echo absent)"
fi

WL="$T2/wlock"
mk_wrepo "$WL" || no "(N20a) could not build the lock repo"
mkdir -p "$WL/memory/.backlog-archive.lock.d"
printf '%s\n' "$$" > "$WL/memory/.backlog-archive.lock.d/pid"
WL_B0="$(bytes2 "$WL/memory/backlog.md")"
groom plan --repo "$WL" >"$T2/wl.out" 2>&1; WL_RC=$?
WL_B1="$(bytes2 "$WL/memory/backlog.md")"
if [ "$WL_RC" -ne 0 ] && [ "$WL_B0" = "$WL_B1" ]; then
  ok "(N20) a HELD lock makes the mint exit rc=$WL_RC having written nothing — the byte count is unchanged at $WL_B1, which is the assertion; an exit code alone would not notice a partial write"
else
  no "(N20) rc=$WL_RC and $WL_B0 -> $WL_B1 bytes under a held lock"
fi
rm -f "$WL/memory/.backlog-archive.lock.d/pid"; rmdir "$WL/memory/.backlog-archive.lock.d" 2>/dev/null
[ -d "$WL/memory/.backlog-archive.lock.d" ] \
  && no "(N20b) the fixture lock could not be released" \
  || ok "(N20b) the fixture lock is released"

# ---- the queue and the ledger the write run produced ----------------------------------------------
W_QUEUE="$(sed -n 's/^QUEUE=\([^ ]*\) .*/\1/p' "$T2/w1.out" | head -1)"
if [ -s "$W_QUEUE" ]; then
  probe2 "$CTL2" queuefile "$W_QUEUE" >"$T2/qf.out" 2>&1
  qf(){ sed -n "s/^$1=//p" "$T2/qf.out" | head -1; }
  cat "$T2/qf.out"
  [ "$(qf ROWS)" = "11" ] \
    && ok "(N21) the queue holds one row per entry (11) — its length IS entry_count, so conservation against it is a number a reader can check against the file" \
    || no "(N21) the queue holds $(qf ROWS) rows for 11 entries"
  [ "$(qf MISSING_FIELDS)" = "-" ] \
    && ok "(N22) every queue row carries the verifier contract's {id, keys, text_sha, raw_text, section, cited_paths}" \
    || no "(N22) queue rows are missing: $(qf MISSING_FIELDS)"
  [ "$(qf TERMINATED)" = "1" ] \
    && ok "(N22b) the queue's last line is newline-terminated, so a killed writer is detectable by the missing terminator rather than by a parse error" \
    || no "(N22b) the queue does not end in a newline"
  [ "$(qf WITH_VERDICT)" = "4" ] \
    && ok "(N23) 4 rows already carry a deterministic verdict, so nothing re-dispatches them" \
    || no "(N23) $(qf WITH_VERDICT) rows carry a verdict, expected 4"
  [ "$(( $(qf WITH_VERDICT) + $(qf CHUNKED) ))" = "$(qf ROWS)" ] \
    && ok "(N23b) decided and chunked rows PARTITION the queue — no row is both already answered and dispatched, and none is neither" \
    || no "(N23b) $(qf WITH_VERDICT) decided + $(qf CHUNKED) chunked != $(qf ROWS) rows"
else
  no "(N21) the write run produced no queue file at '$W_QUEUE'"
fi
W_LED="$WR/memory/backlog-verdicts.jsonl"
if [ -s "$W_LED" ]; then
  probe "$CTL" read "$W_LED" >"$T2/ledread.out" 2>&1
  if [ "$(sed -n 's/^ROWS=//p' "$T2/ledread.out" | head -1)" = "4" ] \
     && [ "$(sed -n 's/^NDEFECTS=//p' "$T2/ledread.out" | head -1)" = "0" ]; then
    ok "(N24) the 4 deterministic verdicts round-trip through the LEDGER's own reader: 4 rows, 0 defects"
  else
    no "(N24) the ledger reads $(sed -n 's/^ROWS=//p' "$T2/ledread.out" | head -1) row(s) / $(sed -n 's/^NDEFECTS=//p' "$T2/ledread.out" | head -1) defect(s)"
  fi
  grep -q '"verified_by": "deterministic:' "$W_LED" \
    && ok "(N24b) the rows are stamped \`deterministic:<class>\`, so 'which of these did a MODEL produce' stays answerable — the question the cross-model spot check asks" \
    || no "(N24b) no deterministic: provenance in the appended rows"
else
  no "(N24) the write run appended no ledger at $W_LED"
fi

# ==================================================================================================
# K — the chunker: block bytes, the cap, and the entry that is never split
# ==================================================================================================
echo "-- K: byte chunking over block spans --"
python3 - "$T2/big.md" <<'PYEOF'
import sys
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    fh.write("# Backlog\n\n## Open\n\n")
    fh.write("- [ ] B-huge tools/present.py " + ("x" * 12000) + "\n")
    for i in range(6):
        fh.write("- [ ] B-small-%d tools/present.py a short one\n" % i)
PYEOF
K_BIG="$(python3 -c "
import sys
for ln in open(sys.argv[1], encoding='utf-8'):
    if 'B-huge' in ln:
        print(len(ln.encode())); break" "$T2/big.md")"
[ "${K_BIG:-0}" -gt 12000 ] \
  && ok "(K0) the fixture really holds a single-LINE entry of $K_BIG bytes — a line count would read it as the smallest entry in the file" \
  || no "(K0) the big entry is ${K_BIG:-0} bytes; K1-K3 would assert nothing"
probe2 "$CTL2" chunk "$T2/big.md" 4000 >"$T2/kbig.out" 2>&1
cat "$T2/kbig.out"
kv(){ sed -n "s/^$1=//p" "$T2/kbig.out" | head -1; }
K_HUGE="$(grep -E '^CHUNK=[0-9]+ bytes=1[0-9]{4} entries=1 ' "$T2/kbig.out" | head -1)"
[ -n "$K_HUGE" ] \
  && ok "(K1/AC4) the 12 KB entry is ALONE in its chunk and never split mid-entry, even though that chunk exceeds the 4000-byte cap: $K_HUGE" \
  || no "(K1/AC4) the oversize entry did not get a chunk of its own: $(grep '^CHUNK=' "$T2/kbig.out" | tr '\n' ' ')"
[ "$(kv OVERSIZE_ROWS)" = "1" ] \
  && ok "(K1b/AC4) exactly one row exceeds the cap and the report SAYS so rather than hiding it" \
  || no "(K1b/AC4) OVERSIZE_ROWS=$(kv OVERSIZE_ROWS)"
[ "$(kv UNASSIGNED)" = "0" ] \
  && ok "(K2/AC4) every row landed in exactly one chunk — none was dropped by the split" \
  || no "(K2/AC4) $(kv UNASSIGNED) row(s) were never assigned a chunk"
python3 - "$T2/bigfirst.md" <<'PYEOF'
import sys
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    fh.write("# Backlog\n\n## Open\n\n")
    fh.write("- [ ] B-first tools/present.py " + ("x" * 9000) + "\n")
    fh.write("- [ ] B-second tools/present.py a short one after the oversize first\n")
PYEOF
probe2 "$CTL2" chunk "$T2/bigfirst.md" 4000 >"$T2/kfirst.out" 2>&1
[ "$(sed -n 's/^CHUNKS=\([0-9]*\) .*/\1/p' "$T2/kfirst.out" | head -1)" = "2" ] \
  && ok "(K3) a row after an ALREADY-oversize first chunk starts a new one — the split tests \`cur\`, not \`totals\`, which is still empty at that moment" \
  || no "(K3) the oversize first row absorbed its successor: $(grep '^CHUNK' "$T2/kfirst.out" | tr '\n' ' ')"

REAL_BACKLOG="$(python3 -c "
import sys
sys.path.insert(0, sys.argv[1])
import zuvo_backlog_io as zio
print(zio.resolve(sys.argv[2])[1])" "$CTL2" "$ROOT")"
if [ -s "$REAL_BACKLOG" ]; then
  ok "(K4a/AC4) the real backlog is readable at $REAL_BACKLOG ($(bytes2 "$REAL_BACKLOG") bytes)"
  probe2 "$CTL2" chunk "$REAL_BACKLOG" "$CAP_REAL" >"$T2/kreal.out" 2>&1
  krv(){ sed -n "s/^$1=//p" "$T2/kreal.out" | head -1; }
  K_MAX="$(sed -n 's/^CHUNKS=[0-9]* cap=[0-9]* max=//p' "$T2/kreal.out" | head -1)"
  echo "  real backlog: $(krv NROWS) entries, $(grep -c '^CHUNK=' "$T2/kreal.out") chunks, largest chunk $K_MAX bytes, largest entry $(krv MAXROW) bytes"
  if [ -n "$K_MAX" ] && [ "$K_MAX" -le "$CAP_REAL" ]; then
    ok "(K4/AC4) no chunk over the real backlog exceeds the $CAP_REAL-byte cap (largest $K_MAX)"
  else
    no "(K4/AC4) the largest chunk is ${K_MAX:-?} bytes against a cap of $CAP_REAL"
  fi
  [ "$(krv UNASSIGNED)" = "0" ] \
    && ok "(K4b/AC4) all $(krv NROWS) real entries are assigned, none split" \
    || no "(K4b/AC4) $(krv UNASSIGNED) of $(krv NROWS) real entries were not assigned"
  K_BSE="$(krv BIGGEST_SECTION_ENTRIES)"
  if [ "${K_BSE:-0}" -ge 100 ]; then
    ok "(K5a/AC4) the real backlog's biggest section still holds $(krv BIGGEST_SECTION_ENTRIES) entries — the plan's 117-entry hazard, remeasured"
  else
    no "(K5a/AC4) the biggest section holds $(krv BIGGEST_SECTION_ENTRIES) entries; the hazard has left this file and K5 would assert nothing"
  fi
  K_BSC="$(krv BIGGEST_SECTION_CHUNKS)"
  if [ "${K_BSC:-0}" -ge 2 ]; then
    ok "(K5/AC4) that section is SPLIT across $(krv BIGGEST_SECTION_CHUNKS) chunks — a count-based split would have handed the whole of it to one agent"
  else
    no "(K5/AC4) the biggest section sits in $(krv BIGGEST_SECTION_CHUNKS) chunk(s)"
  fi
else
  no "(K4a/AC4) the real backlog is not readable at '$REAL_BACKLOG' — AC4 must be measured on the real file, not a fixture, so this is a failure rather than a skip"
fi

# ==================================================================================================
# X — the census: a FIXTURE root with known per-level counts, never $HOME/DEV
# ==================================================================================================
echo "-- X: the committed census over a fixture root --"
CR="$T2/census-root"
mkdir -p "$CR/alpha/memory" "$CR/beta/memory"
cat > "$CR/alpha/memory/backlog.md" <<'EOF'
# Alpha backlog
## Open
## B-alpha-one an id-shaped heading entry
## B-alpha-two another one
## a plain section header, which is not an entry
### B-alpha-three a level-3 entry
### notes, not an entry
EOF
cat > "$CR/beta/memory/backlog.md" <<'EOF'
# Beta backlog
## B-beta-one the only entry here
## Deferred
EOF
# THE ORACLE IS DERIVED FROM THE BYTES, independently of the census, because a hand-counted expectation
# and a hand-written fixture drift together and then agree with each other about a wrong answer.
python3 - "$CR" >"$T2/oracle.out" 2>&1 <<'PYEOF'
import os
import re
import sys
ROOT = sys.argv[1]
H = re.compile(r"^(#{1,6})\s+(.*)$")
ID = re.compile(r"^B-[\w.-]+")
per = {}
files = 0
for repo in sorted(os.listdir(ROOT)):
    path = os.path.join(ROOT, repo, "memory", "backlog.md")
    if not os.path.isfile(path):
        continue
    files += 1
    with open(path, encoding="utf-8") as fh:
        for raw in fh.read().splitlines():
            m = H.match(raw.rstrip())
            if m is None:
                continue
            lvl = len(m.group(1))
            h, e, i = per.get(lvl, (0, 0, 0))
            hit = 1 if ID.match(m.group(2)) else 0
            per[lvl] = (h + 1, e + hit, i + (1 - hit))
print("ORACLE_FILES=%d" % files)
for lvl in sorted(per):
    print("ORACLE_LEVEL=%d headings=%d entries=%d idless=%d" % ((lvl,) + per[lvl]))
PYEOF
cat "$T2/oracle.out"
[ "$(grep -c '^ORACLE_LEVEL=' "$T2/oracle.out")" -ge 3 ] \
  && ok "(X0/AC5) the independent oracle found $(grep -c '^ORACLE_LEVEL=' "$T2/oracle.out") heading levels in the fixture — an oracle that found none would agree with any census" \
  || no "(X0/AC5) the oracle found $(grep -c '^ORACLE_LEVEL=' "$T2/oracle.out") level(s): $(tr '\n' ' ' < "$T2/oracle.out")"
census --roots "$CR" --min-repos 2 >"$T2/cen.out" 2>&1; CEN_RC=$?
cat "$T2/cen.out"
[ "$CEN_RC" -eq 0 ] \
  && ok "(X1/AC5) the census runs over the fixture root and exits 0" \
  || no "(X1/AC5) the census exited $CEN_RC over the fixture root: $(tail -2 "$T2/cen.out")"
grep -qF "ROOT=$CR" "$T2/cen.out" \
  && ok "(X1b/AC5) it PRINTS its root set, so every count under that line has a stated scope" \
  || no "(X1b/AC5) the census does not print its root set"
X_MISMATCH=""
while IFS= read -r line; do
  want="${line#ORACLE_}"
  grep -qxF "$want" "$T2/cen.out" || X_MISMATCH="$X_MISMATCH [$want]"
done < <(grep '^ORACLE_LEVEL=' "$T2/oracle.out")
[ -z "$X_MISMATCH" ] \
  && ok "(X2/AC5) every per-level count matches the independent oracle exactly, at all $(grep -c '^ORACLE_LEVEL=' "$T2/oracle.out") levels" \
  || no "(X2/AC5) the census disagrees with the oracle on:$X_MISMATCH"
X_FILES="$(sed -n 's/^FILES=\([0-9]*\).*/\1/p' "$T2/cen.out" | head -1)"
X_REPOS="$(sed -n 's/^FILES=[0-9]* REPOS=//p' "$T2/cen.out" | head -1)"
if [ "$X_FILES" = "$(sed -n 's/^ORACLE_FILES=//p' "$T2/oracle.out")" ] && [ "$X_REPOS" = "2" ]; then
  ok "(X3/AC5) it found $X_FILES file(s) in $X_REPOS repos, both matching the fixture"
else
  no "(X3/AC5) FILES=$X_FILES REPOS=$X_REPOS against an oracle of $(sed -n 's/^ORACLE_FILES=//p' "$T2/oracle.out") file(s) and 2 repos"
fi
X_PART="$(awk '/^LEVEL=/{h=0;e=0;i=0;for(n=1;n<=NF;n++){split($n,kv,"=");if(kv[1]=="headings")h=kv[2];if(kv[1]=="entries")e=kv[2];if(kv[1]=="idless")i=kv[2];if(kv[1]=="LEVEL")lv=kv[2]} if(h!=e+i) print lv}' "$T2/cen.out")"
[ -z "$X_PART" ] \
  && ok "(X4/AC5) entries + idless == headings at every level — the three columns partition one population instead of counting two" \
  || no "(X4/AC5) the columns do not add up at level(s): $X_PART"
census --roots "$T2/definitely-not-a-directory" >"$T2/cenempty.out" 2>&1; CEN_E=$?
[ "$CEN_E" -eq 30 ] \
  && ok "(X5/AC5) an empty root set exits 30 — an unexpanded \`~\`, a mistyped path or a glob the shell left literal cannot pass as a census of nothing" \
  || no "(X5/AC5) an empty root set exited $CEN_E"
census --roots "$CR" --min-repos 99 >"$T2/cenmin.out" 2>&1; CEN_M=$?
[ "$CEN_M" -eq 31 ] \
  && ok "(X6/AC5) --min-repos above the found count exits 31" \
  || no "(X6/AC5) --min-repos 99 over a 2-repo root exited $CEN_M"
probe2 "$CTL2" expand "~" >"$T2/cenexp.out" 2>&1
grep -qxF "FOUND=$HOME" "$T2/cenexp.out" \
  && ok "(X7/AC5) \`--roots ~\` expands to \$HOME INSIDE the script — Python's glob does not expand it, and a root that silently matched nothing would print zeros and exit 0" \
  || no "(X7/AC5) '~' expanded to '$(sed -n 's/^FOUND=//p' "$T2/cenexp.out")', expected $HOME"
probe2 "$CTL2" expand "$CR:$CR/alpha" >"$T2/cenexp2.out" 2>&1
grep -qxF "FOUND=$CR|$CR/alpha" "$T2/cenexp2.out" \
  && ok "(X8/AC5) one --roots value carrying two os.pathsep-separated paths resolves to both, which is how one shell variable carries a root set" \
  || no "(X8/AC5) a two-path value resolved to '$(sed -n 's/^FOUND=//p' "$T2/cenexp2.out")'"
census --roots "$HOME/DEV" --min-repos 1 >"$T2/cenhome.out" 2>&1
echo "  \$HOME/DEV, reported and gating NOTHING: $(grep -E '^(FILES|TOTAL)' "$T2/cenhome.out" | tr '\n' ' ')"
ok "(X9/AC5) the author's \$HOME/DEV is reported separately and is never the pass/fail oracle — the fixture root above is"


# ==================================================================================================
# R6 — plan revision 6: the mint premise is UNREACHABLE, the deadlock it feared is not real, and the
# cost of proceeding on `fp:` keys is stated rather than hidden.
#
# WHY THESE ARE ASSERTIONS AND NOT A GAP. Task 2's mint step cannot run on this repo: all 263 entries
# of the mint set are the BULLET dialect and `mint_into` refuses every one of them. Silently skipping
# would leave "the mint did nothing" indistinguishable from "the mint was never wired", so the
# impossibility is MEASURED here — 0 of 263, with every refusal carrying one of two named reasons —
# and the count-neutrality check is asserted as TRIVIALLY true rather than deleted, because it is the
# same check that refuses a write which would turn a section header into an entry.
# ==================================================================================================
echo "-- R6: the mint premise, measured against the REAL backlog --"
if [ -s "$REAL_BACKLOG" ]; then
  probe2 "$CTL2" mintsel "$REAL_BACKLOG" >"$T2/r6sel.out" 2>&1
  r6(){ sed -n "s/^$1=//p" "$T2/r6sel.out" | head -1; }
  echo "  real backlog: entries=$(r6 NENTRIES) mint_set=$(r6 MINT_SET) mintable=$(r6 MINTABLE) unmintable=$(r6 UNMINTABLE)"
  [ "$(r6 MINT_SET)" -gt 200 ] \
    && ok "(R6a) the real mint set is $(r6 MINT_SET) entries — large enough that 'nothing was mintable' is a finding rather than an empty input" \
    || no "(R6a) the real mint set is $(r6 MINT_SET); R6b below would be a statement about almost nothing"
  [ "$(r6 MINTABLE)" = "0" ] \
    && ok "(R6b) 0 of $(r6 MINT_SET) are MINTABLE — the plan's central premise is unreachable, measured rather than assumed, and plan revision 6 accepts it: verification proceeds on \`fp:\` keys" \
    || no "(R6b) $(r6 MINTABLE) of $(r6 MINT_SET) came back mintable on the real backlog; revision 6's measurement no longer holds and the decision it justifies must be revisited"
  [ "$(r6 UNMINTABLE)" = "$(r6 MINT_SET)" ] \
    && ok "(R6c) every one of the $(r6 MINT_SET) is REPORTED, so the count of refusals and the count of the set are the same number — nothing was dropped between them" \
    || no "(R6c) $(r6 UNMINTABLE) reported against a set of $(r6 MINT_SET) — $(( $(r6 MINT_SET) - $(r6 UNMINTABLE) )) entries went neither way"
  R6_UNEXPLAINED="$(grep '^SKIP=' "$T2/r6sel.out" | grep -vcE 'no mint anchor|already shows a B-id' || true)"
  [ "${R6_UNEXPLAINED:-1}" = "0" ] \
    && ok "(R6d) every refusal carries one of the two NAMED reasons — no unexplained skip, which is what keeps this a measurement instead of a silent gap" \
    || no "(R6d) $R6_UNEXPLAINED refusal(s) carry neither named reason: $(grep '^SKIP=' "$T2/r6sel.out" | grep -vE 'no mint anchor|already shows a B-id' | head -1)"
  R6_ANCHOR="$(grep -c '^SKIP=.*no mint anchor' "$T2/r6sel.out" || true)"
  R6_BODYID="$(grep -c '^SKIP=.*already shows a B-id' "$T2/r6sel.out" || true)"
  echo "  refusal reasons: $R6_ANCHOR no-anchor + $R6_BODYID already-identified = $(( R6_ANCHOR + R6_BODYID ))"
  [ "$(( R6_ANCHOR + R6_BODYID ))" = "$(r6 MINT_SET)" ] \
    && ok "(R6e) the two reasons PARTITION the set ($R6_ANCHOR + $R6_BODYID) — both filters are live on real data, not just on a fixture" \
    || no "(R6e) $R6_ANCHOR + $R6_BODYID != $(r6 MINT_SET)"
  # THE STRUCTURAL REASON, so R6b is not a coincidence of today's file: the mint set is EXCLUSIVELY the
  # bullet dialect, and the two dialects `mint_into` admits contribute nothing to it.
  R6_KINDS="$(python3 - "$CTL2" "$REAL_BACKLOG" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import zuvo_backlog_parse as zb
with open(sys.argv[2], encoding="utf-8", errors="replace") as fh:
    text = fh.read()
out = []
for label, kinds in (("all", zb.DEFAULT_KINDS + (zb.KIND_HEADING,)),
                     ("checkbox", (zb.KIND_CHECKBOX,)),
                     ("heading", (zb.KIND_HEADING,)),
                     ("bullet", (zb.KIND_BULLET,))):
    es = list(zb.iter_entries(text, kinds=kinds))
    out.append("%s:%d/%d" % (label, sum(1 for e in es if not e.ident), len(es)))
print(" ".join(out))
PYEOF
)"
  echo "  id-less/total per dialect: $R6_KINDS"
  case "$R6_KINDS" in
    *"checkbox:0/"*) ok "(R6f) ZERO checkbox entries lack an ident, so the dialect mint_into accepts contributes nothing to the mint set — R6b is structural, not an accident of today's bytes" ;;
    *) no "(R6f) the checkbox dialect contributes id-less entries ($R6_KINDS), so the mint could run and R6b needs re-deriving" ;;
  esac
  case "$R6_KINDS" in
    *"heading:0/"*) ok "(R6f2) ZERO heading ENTRIES lack an ident either — a heading entry is id-anchored by construction, so the other accepted dialect contributes nothing as well" ;;
    *) no "(R6f2) the heading dialect contributes id-less entries: $R6_KINDS" ;;
  esac
  # COUNT-NEUTRALITY, TRIVIALLY TRUE, and asserted as such rather than deleted.
  groom plan --repo "$ROOT" --dry-run >"$T2/r6plan.out" 2>&1; R6_RC=$?
  R6_CN="$(sed -n 's/^COUNT_NEUTRAL=//p' "$T2/r6plan.out" | head -1)"
  R6_INS="$(sed -n 's/^INSERTED_BYTES=//p' "$T2/r6plan.out" | head -1)"
  if [ "$R6_RC" -eq 0 ] && [ "$R6_INS" = "0" ] && [ "${R6_CN%%/*}" = "${R6_CN##*/}" ] && [ -n "$R6_CN" ]; then
    ok "(R6g) with nothing minted, count-neutrality is TRIVIALLY true and still checked: $R6_CN entries and $R6_INS bytes inserted. It stays in the code because it is the same check that refuses a write which would turn a section header into an entry (the mintheadings mutant above)"
  else
    no "(R6g) rc=$R6_RC COUNT_NEUTRAL='$R6_CN' INSERTED_BYTES='$R6_INS' on the real backlog"
  fi
else
  no "(R6a) the real backlog is not readable, so revision 6's central measurement cannot be re-derived here — that is a failure rather than a skip, because the decision rests on it"
fi

# --------------------------------------------------------------------------------------------------
# R6h-R6k — the deadlock revision 6 refuted, and the cost of the decision it took instead.
# --------------------------------------------------------------------------------------------------
echo "-- R6: fp: keys are first-class, and what that costs --"
# A row keyed ONLY on `fp:` must validate. This is the claim the whole decision rests on: if the ledger
# refused such a row, the 263 could not carry a verdict at all and the mint would be unavoidable.
FPROW="$FIX/fprow.json"
printf '%s\n' '[{"id":"fp:0123456789ab","keys":["fp:0123456789ab"],"text_sha":"'"$(printf 'a%.0s' $(seq 1 40))"'","verdict":"NOT-VERIFIABLE","evidence":"the repo does not answer either way","verified_at":"2026-09-29T00:00:00+00:00","verified_by":"deterministic:probe","disposition":"pending"}]' > "$FPROW"
R_FP="$FIX/repo-fp"
mkrepo "$R_FP" || no "(R6h0) could not build the fp-only repo"
if probe "$CTL" append "$R_FP" "$FPROW" >"$T2/fp.out" 2>&1; then
  ok "(R6h) a row keyed ONLY on \`fp:<12hex>\` is accepted by the ledger — which is the measurement revision 6 rests on: a content-keyed entry can carry a verdict, so the mint is not a precondition of verification"
else
  no "(R6h) the ledger refused an fp:-only row ($(tail -2 "$T2/fp.out")) — then the 263 could carry no verdict and revision 6's decision would not stand"
fi

# THE COST, asserted end to end: an fp: key rotates with the text, so the verdict is ORPHANED by the
# very normalisation `groom` performs — and it is reported as a NAMED defect, never dropped.
FPB="$T2/fp-backlog.md"
cat > "$FPB" <<'EOF'
# Backlog

## Open

- tools/present.py a content-keyed bullet carrying no identifier at all
EOF
FPLED="$T2/fp-ledger.jsonl"
python3 - "$CTL2" "$FPB" "$FPLED" <<'PYEOF'
import json
import sys
sys.path.insert(0, sys.argv[1])
import zuvo_backlog_ledger as zl
import zuvo_backlog_parse as zb
with open(sys.argv[2], encoding="utf-8") as fh:
    text = fh.read()
e = [x for x in zb.iter_entries(text, kinds=zb.DEFAULT_KINDS + (zb.KIND_HEADING,))][0]
row = {"id": e.key, "keys": sorted(zb.keys_for(e.body, e.ident)), "text_sha": zl.text_sha(e.body),
       "verdict": "STILL-REAL", "evidence": "tools/present.py:1 the guard is absent",
       "verified_at": "2026-09-29T00:00:00+00:00", "verified_by": "agent:probe",
       "disposition": "pending"}
with open(sys.argv[3], "w", encoding="utf-8") as fh:
    fh.write(json.dumps(row, sort_keys=True) + "\n")
print("FPKEY=%s" % e.key)
print("FPSHA=%s" % row["text_sha"])
PYEOF
FP_KEY="$(python3 -c "
import sys
sys.path.insert(0, sys.argv[1])
import zuvo_backlog_parse as zb
t = open(sys.argv[2], encoding='utf-8').read()
print([e.key for e in zb.iter_entries(t, kinds=zb.DEFAULT_KINDS + (zb.KIND_HEADING,))][0])" "$CTL2" "$FPB")"
case "$FP_KEY" in
  fp:*) ok "(R6i0) the fixture entry really keys on CONTENT ($FP_KEY) — a bullet with no ident, exactly the shape all 263 have" ;;
  *) no "(R6i0) the fixture entry keys as '$FP_KEY', not fp:, so R6i-R6k would be about a different shape" ;;
esac
probe "$CTL" plan "$FPB" "$FPLED" >"$T2/fp1.out" 2>&1
if [ "$(sed -n 's/^REUSE=//p' "$T2/fp1.out" | head -1)" = "$FP_KEY" ] \
   && [ "$(sed -n 's/^NORPHANS=//p' "$T2/fp1.out" | head -1)" = "0" ]; then
  ok "(R6i) BEFORE any edit the content-keyed verdict is REUSED at zero dispatch and orphans nobody — the deadlock the plan feared does not exist, measured through plan_reuse itself"
else
  no "(R6i) the fp: verdict was not reused: REUSE=$(sed -n 's/^REUSE=//p' "$T2/fp1.out" | head -1) NORPHANS=$(sed -n 's/^NORPHANS=//p' "$T2/fp1.out" | head -1)"
fi
# WHAT THE MEASUREMENT CORRECTED, now plan revision 7. Revision 6 stated the cost as "an `fp:` key
# rotates when the entry's text changes" and named the case "orphaned by the very normalisation `groom`
# performs". Measured on fixtures, that case is the one that does NOT happen, and it is protected
# twice over:
#
#   * `entry_key` hashes `normalize_signature`, which is the first path token's BASENAME plus the
#     **8 words FOLLOWING it**, taken over `strip_resolution_markers(body)`. A prepended
#     `[DONE 2026-09-29]` is stripped before the path is even located, and anything outside those
#     eight words is outside the window — so the KEY is kept.
#   * `text_sha` is taken over the same stripped text, so the marker does not move the SHA either.
#
# The row is therefore REUSED at zero dispatch: closing an entry costs nothing. What DOES rotate a key
# is a change of SUBJECT — the path, or one of those eight words — and that should re-verify anyway.
# The three buckets below are asserted separately, and the marker case carries two mutants because it
# has two independent mechanisms and a later "tidy-up" of either one would orphan every verdict
# `groom` writes.
FPKEY_OF(){ python3 -c "
import sys
sys.path.insert(0, sys.argv[1])
import zuvo_backlog_parse as zb
t = open(sys.argv[2], encoding='utf-8').read()
print([e.key for e in zb.iter_entries(t, kinds=zb.DEFAULT_KINDS + (zb.KIND_HEADING,))][0])" "$CTL2" "$1"; }
FPSHA_OF(){ python3 -c "
import sys
sys.path.insert(0, sys.argv[1])
import zuvo_backlog_ledger as zl
import zuvo_backlog_parse as zb
t = open(sys.argv[2], encoding='utf-8').read()
print(zl.text_sha([e.body for e in zb.iter_entries(t, kinds=zb.DEFAULT_KINDS + (zb.KIND_HEADING,))][0]))" "$CTL2" "$1"; }
FP_SHA="$(FPSHA_OF "$FPB")"

# (a) THE CASE REVISION 6 NAMED: a resolution marker prepended, which is exactly what closing an entry
# does. Both the key and the sha survive it, so the verdict is REUSED — the closure is free.
sed 's/^- tools\/present.py/- [DONE 2026-09-29] tools\/present.py/' "$FPB" > "$T2/fp-marked.md"
if ! cmp -s "$FPB" "$T2/fp-marked.md" && grep -q '\[DONE 2026-09-29\]' "$T2/fp-marked.md"; then
  ok "(R6j0) the marker fixture really differs from its source and really carries a [DONE <date>] clause"
else
  no "(R6j0) the marker fixture is identical or carries no marker, so R6j would assert nothing"
fi
FP_MK_KEY="$(FPKEY_OF "$T2/fp-marked.md")"; FP_MK_SHA="$(FPSHA_OF "$T2/fp-marked.md")"
[ -n "$FP_MK_KEY" ] && [ "$FP_MK_KEY" = "$FP_KEY" ] \
  && ok "(R6j) prepending a [DONE <date>] resolution marker KEEPS the content key ($FP_KEY) — the case revision 6 named as the cost is the one case that cannot happen, because the signature window is anchored after the path over marker-stripped text" \
  || no "(R6j) the marker rotated the key ($FP_KEY -> $FP_MK_KEY) — then groom's own closure WOULD orphan its verdict and revision 7's correction is wrong"
[ -n "$FP_MK_SHA" ] && [ "$FP_MK_SHA" = "$FP_SHA" ] \
  && ok "(R6j2) it keeps \`text_sha\` too (${FP_SHA:0:12}), because that is taken over the same stripped text — a verdict is not invalidated by the very edit that proves it" \
  || no "(R6j2) the marker moved text_sha (${FP_SHA:0:12} -> ${FP_MK_SHA:0:12})"
probe "$CTL" plan "$T2/fp-marked.md" "$FPLED" >"$T2/fpmk.out" 2>&1
if [ "$(sed -n 's/^REUSE=//p' "$T2/fpmk.out" | head -1)" = "$FP_KEY" ] \
   && [ "$(sed -n 's/^NORPHANS=//p' "$T2/fpmk.out" | head -1)" = "0" ]; then
  ok "(R6j3) so the closed entry's verdict is REUSED at zero dispatch and orphans nobody — groom's normalisation is free, which is the opposite of what revision 6 recorded"
else
  no "(R6j3) REUSE=$(sed -n 's/^REUSE=//p' "$T2/fpmk.out" | head -1) NORPHANS=$(sed -n 's/^NORPHANS=//p' "$T2/fpmk.out" | head -1) after a marker was prepended"
fi

# (b) an edit OUTSIDE the eight-word window: the key survives, the sha does not -> RE-VERIFY.
sed 's/carrying no identifier at all/carrying no identifier at all, reworded much later in the line/' \
  "$FPB" > "$T2/fp-out.md"
cmp -s "$FPB" "$T2/fp-out.md" \
  && no "(R6j4a) the outside-window fixture is identical, so R6j4 would assert nothing" \
  || ok "(R6j4a) the outside-window fixture really differs from its source"
FP_OUT_KEY="$(FPKEY_OF "$T2/fp-out.md")"
probe "$CTL" plan "$T2/fp-out.md" "$FPLED" >"$T2/fpout.out" 2>&1
if [ "$FP_OUT_KEY" = "$FP_KEY" ] \
   && [ "$(sed -n 's/^REVERIFY=//p' "$T2/fpout.out" | head -1)" = "$FP_KEY" ] \
   && [ "$(sed -n 's/^NORPHANS=//p' "$T2/fpout.out" | head -1)" = "0" ]; then
  ok "(R6j4) prose added OUTSIDE the window keeps the key and moves only the sha, so the row lands in RE-VERIFY and stays reachable — the middle bucket, and the reason the cost is bounded rather than total"
else
  no "(R6j4) key $FP_KEY -> $FP_OUT_KEY, REVERIFY=$(sed -n 's/^REVERIFY=//p' "$T2/fpout.out" | head -1), NORPHANS=$(sed -n 's/^NORPHANS=//p' "$T2/fpout.out" | head -1)"
fi

# (c) a change of SUBJECT — one of the eight words, then the path — DOES rotate the key and orphan it.
sed 's/a content-keyed bullet/a content-addressed bullet/' "$FPB" > "$T2/fp-edited.md"
cmp -s "$FPB" "$T2/fp-edited.md" \
  && no "(R6k0) the in-window fixture is identical, so R6k would assert nothing" \
  || ok "(R6k0) the in-window fixture really differs by one word inside the signature window"
FP_KEY2="$(FPKEY_OF "$T2/fp-edited.md")"
[ -n "$FP_KEY2" ] && [ "$FP_KEY2" != "$FP_KEY" ] \
  && ok "(R6k) changing one of the EIGHT words after the path rotates the key ($FP_KEY -> $FP_KEY2) — a change of subject, which should re-verify anyway; this is the real and bounded cost" \
  || no "(R6k) the key did not rotate on an in-window edit ($FP_KEY -> $FP_KEY2)"
probe "$CTL" plan "$T2/fp-edited.md" "$FPLED" >"$T2/fp2.out" 2>&1
if [ "$(sed -n 's/^NORPHANS=//p' "$T2/fp2.out" | head -1)" = "1" ] \
   && grep -q "^ORPHAN=.*$FP_KEY" "$T2/fp2.out" \
   && [ "$(sed -n 's/^FRESH=//p' "$T2/fp2.out" | head -1)" = "$FP_KEY2" ]; then
  ok "(R6k2) the row is then a NAMED orphan defect (naming $FP_KEY) and the entry reads FRESH — the cost is REPORTED, never a silent drop, which is the whole reason plan_reuse has that bucket"
else
  no "(R6k2) the rotated verdict was not reported as a named orphan: NORPHANS=$(sed -n 's/^NORPHANS=//p' "$T2/fp2.out" | head -1) FRESH=$(sed -n 's/^FRESH=//p' "$T2/fp2.out" | head -1) $(grep '^ORPHAN=' "$T2/fp2.out" | head -1)"
fi
sed 's|tools/present.py|tools/renamed.py|' "$FPB" > "$T2/fp-moved.md"
FP_KEY3="$(FPKEY_OF "$T2/fp-moved.md")"
[ -n "$FP_KEY3" ] && [ "$FP_KEY3" != "$FP_KEY" ] && [ "$FP_KEY3" != "$FP_KEY2" ] \
  && ok "(R6k3) changing the PATH rotates it too, to a third key ($FP_KEY3) — the signature is basename-plus-window, so both halves of it are live" \
  || no "(R6k3) the path change did not produce a distinct key: $FP_KEY / $FP_KEY2 / $FP_KEY3"

# The mutants. The marker case gets TWO, because it has two independent mechanisms and a later
# "tidy-up" of either one would silently orphan every verdict `groom` writes.
mut_gone noorphan "R6k2 the orphaned fp: verdict is NAMED" '^ORPHAN=' plan "$T2/fp-edited.md" "$FPLED"
# (i) the SHA half: hashing the raw body instead of the stripped one makes the closure invalidate its
# own verdict, so the reused row falls out of REUSE.
mut_gone shaonraw "R6j2 text_sha over the STRIPPED body" "^REUSE=$FP_KEY\$" plan "$T2/fp-marked.md" "$FPLED"
# (ii) the WINDOW half: keying the signature off the raw body instead of the post-path window makes a
# prepended marker rotate the key, which turns the reused row into a named orphan.
if mut2_build sigrawwindow; then
  # The classify run is not decoration: it proves the mutated PARSER still imports and executes, so a
  # differing key below is the mutation and not a broken copy.
  MU_SIG="$(probe2 "$T2/mut-sigrawwindow" classify "$T2/fp-marked.md" "$T2/no-archive.md" "$FR" 2>&1 || true)"
  case "$MU_SIG" in
    *NENTRIES=*) ok "(MU) R6j the sigrawwindow mutant imports and runs — the key comparison below is a mutation, not an import error" ;;
    *) no "(MU) R6j the sigrawwindow mutant did not run: $(printf '%s' "$MU_SIG" | tail -1 | cut -c1-110)" ;;
  esac
  MU_SIGK="$(python3 -c "
import sys
sys.path.insert(0, sys.argv[1])
import zuvo_backlog_parse as zb
t = open(sys.argv[2], encoding='utf-8').read()
print([e.key for e in zb.iter_entries(t, kinds=zb.DEFAULT_KINDS + (zb.KIND_HEADING,))][0])" \
    "$T2/mut-sigrawwindow" "$T2/fp-marked.md")"
  [ -n "$MU_SIGK" ] && [ "$MU_SIGK" != "$FP_MK_KEY" ] \
    && ok "(MU) R6j the signature WINDOW: anchored off the raw body instead of after the path, a prepended marker rotates the key ($FP_MK_KEY -> $MU_SIGK) — that one-line tidy-up is what R6j exists to block" \
    || no "(MU) R6j the signature window: the mutant produced the same key ($MU_SIGK), so R6j does not measure the anchoring"
else
  mut2_failed sigrawwindow
fi
# The INVERSE direction of mut_rc0: here the control SUCCEEDS and the mutant must refuse, because the
# claim is that `fp:` is ACCEPTED. A `_KEY_RE` that admits only `id:` keys is the one-line change that
# would have forced the mint, so it is the mutation that makes R6h load-bearing.
if mut_build fponly; then
  R_FP2="$FIX/repo-fp-mut"
  mkrepo "$R_FP2"
  if probe "$FIX/mut-fponly" append "$R_FP2" "$FPROW" >"$T2/fpmut.out" 2>&1; then
    no "(M) R6h fp: as a first-class key: the mutant ALSO accepted the fp:-only row, so R6h does not measure _KEY_RE"
  else
    ok "(M) R6h fp: as a first-class key: a _KEY_RE admitting only id: keys REFUSES the row ($(head -2 "$T2/fpmut.out" | tail -1 | cut -c1-90)) — that one-line change is what would have forced the mint, so R6h is load-bearing"
  fi
else
  mut_failed fponly
fi

# ==================================================================================================
# FL — rules/file-limits.md on the four Task 2 files (RAW lines for a module, BODY lines for a
# function; `ast.stmt` is NOT the gate, because a statement count calls a 30-line dict literal one)
# ==================================================================================================
echo "-- FL: rules/file-limits.md on the Task 2 files --"
LIMITS="$T2/limits.py"
cat > "$LIMITS" <<'PYEOF'
"""RAW module lines and BODY function lines, per rules/file-limits.md."""
import ast
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    src = fh.read()
lines = src.splitlines()
print("RAWLINES=%d" % len(lines))
over = []
n = 0
for node in ast.walk(ast.parse(src)):
    if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        continue
    n += 1
    body = list(node.body)
    if (body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant)
            and isinstance(body[0].value.value, str)):
        body = body[1:]                      # the docstring is not body, by the rule's own wording
    c = 0
    if body:
        lo = body[0].lineno
        hi = max(getattr(x, "end_lineno", x.lineno) for x in body)
        for i in range(lo, hi + 1):
            s = lines[i - 1].strip()
            if s and not s.startswith("#"):  # comments and blanks excluded, by the same wording
                c += 1
    limit = 30 if node.name.startswith("_") else 50
    print("FUNC=%s body=%d limit=%d %s" % (node.name, c, limit, "OVER" if c > limit else "ok"))
    if c > limit:
        over.append(node.name)
print("NFUNCS=%d" % n)
print("NOVER=%d" % len(over))
PYEOF
for f in "$GROOM_PY" "$CENSUS_PY" "$VERDICTS_MOD" "$QUEUE_MOD" "$PREPASS_MOD" "$AGENT_MOD" \
         "$SEEDS_MOD" "$APPLY_MOD" "$LOAD_MOD"; do
  base="${f#"$ROOT"/}"; tag="$T2/lim-$(basename "$f").out"
  if ! python3 "$LIMITS" "$f" >"$tag" 2>&1; then
    no "(FL) could not measure $base: $(tail -1 "$tag")"; continue
  fi
  cat "$tag"
  raw="$(sed -n 's/^RAWLINES=//p' "$tag")"; nf="$(sed -n 's/^NFUNCS=//p' "$tag")"
  novr="$(sed -n 's/^NOVER=//p' "$tag")"
  # THE ORACLE IS THE FILE'S OWN `def` COUNT, not a magic minimum. The first version demanded >= 5 and
  # failed on zuvo_backlog_load.py, which legitimately has four functions — a threshold that calls a
  # small module a blind measurer is measuring module size, which is FL1's job. `ast.walk` counts nested
  # defs too, and so does this grep, so the two are comparable.
  ndef="$(grep -cE '^[[:space:]]*(async )?def ' "$f")"
  [ "${nf:-0}" = "$ndef" ] && [ "${ndef:-0}" -ge 1 ] \
    && ok "(FL0) $base: all $nf of its $ndef \`def\`s were measured — a measurer that found none, or that skipped some, would report 'nothing is over the limit'" \
    || no "(FL0) $base: the measurer found ${nf:-0} function(s) where the file declares $ndef — every FL2 result below it would be about a subset"
  if [ -n "$raw" ] && [ "$raw" -lt 400 ]; then
    ok "(FL1) $base is $raw RAW lines, under the 400 default (800 is the automatic CQ11 FAIL)"
  else
    no "(FL1) $base is ${raw:-?} raw lines — extract a sibling rather than carrying it"
  fi
  [ "${novr:-1}" = "0" ] \
    && ok "(FL2) $base: every function is inside its BODY-line limit (public 50, private 30)" \
    || no "(FL2) $base: over the limit: $(grep 'OVER$' "$tag" | tr '\n' ' ')"
done
# The two COMMANDS must carry the polyglot header. `#!/usr/bin/env python3` dies on Windows/Git Bash,
# and test-windows-portability.sh sweeps this whole directory for both halves of that rule.
for f in "$GROOM_PY" "$CENSUS_PY"; do
  base="$(basename "$f")"
  head -1 "$f" | grep -qx '#!/bin/sh' \
    && ok "(FL3) $base opens with the sh half of the polyglot header" \
    || no "(FL3) $base starts with '$(head -1 "$f")' — a bare python3 shebang dies where python3 is not on PATH"
  head -8 "$f" | grep -q 'command -v python3 || command -v python' \
    && ok "(FL3b) $base re-execs through whatever Python 3 exists" \
    || no "(FL3b) $base has no polyglot exec line, so test-windows-portability.sh's corpus check fails on it"
  python3 -c "import ast,sys;ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$f" \
    && ok "(FL3c) $base still parses as Python with that header on it" \
    || no "(FL3c) $base does not parse as Python"
done
syspath2(){ python3 - "$1" <<'PYEOF'
import ast
import sys
with open(sys.argv[1], encoding="utf-8") as fh:
    tree = ast.parse(fh.read())
h = [n.lineno for n in ast.walk(tree)
     if isinstance(n, ast.Attribute) and n.attr == "path"
     and isinstance(n.value, ast.Name) and n.value.id == "sys"]
print(",".join(str(x) for x in h) if h else "none")
PYEOF
}
[ "$(syspath2 "$GROOM_PY")" != "none" ] \
  && ok "(FL4a) the sys.path detector finds backlog-groom.py's own insert at line(s) $(syspath2 "$GROOM_PY") — it is not blind, so FL4 below means something" \
  || no "(FL4a) the detector found no sys.path insert in backlog-groom.py, which demonstrably has one"
for f in "$VERDICTS_MOD" "$QUEUE_MOD" "$PREPASS_MOD" "$AGENT_MOD" "$SEEDS_MOD" "$APPLY_MOD" \
         "$LOAD_MOD"; do
  base="$(basename "$f")"
  head -1 "$f" | grep -q '^#!' \
    && no "(FL4) $base carries a shebang — it is imported like zuvo_backlog_io.py, not run" \
    || ok "(FL4) $base has no shebang"
  [ -x "$f" ] && no "(FL4b) $base is executable; nothing runs it directly" || ok "(FL4b) $base is not executable"
  [ "$(syspath2 "$f")" = "none" ] \
    && ok "(FL4c) $base never touches sys.path, so it resolves identically in the checkout and on the flattened ~/.zuvo/ layout" \
    || no "(FL4c) $base touches sys.path at line(s) $(syspath2 "$f") — that is the IMPORTER's job, and a module rewriting its importer's path breaks in exactly one of the two layouts"
done

# ==================================================================================================
# MU — every Task 2 assertion dies under a mutant that reverts only its behaviour
# ==================================================================================================
echo "-- MU: each Task 2 assertion is load-bearing --"
mu_gone(){  # kind, label, ERE that must VANISH, probe2 args...
  local kind="$1" lbl="$2" pat="$3" out
  if ! mut2_build "$kind"; then mut2_failed "$kind"; return; fi
  shift 3
  out="$(probe2 "$T2/mut-$kind" "$@" 2>&1)"
  if printf '%s\n' "$out" | grep -qE -- "$pat"; then
    no "(MU) $lbl: the mutant still produced /$pat/ — the assertion is decorative"
  else
    ok "(MU) $lbl: /$pat/ is gone under the mutant — the assertion is load-bearing"
  fi
}
mu_new(){  # kind, label, ERE that must APPEAR only under the mutant, probe2 args...
  local kind="$1" lbl="$2" pat="$3" out
  if ! mut2_build "$kind"; then mut2_failed "$kind"; return; fi
  shift 3
  out="$(probe2 "$T2/mut-$kind" "$@" 2>&1)"
  if printf '%s\n' "$out" | grep -qE -- "$pat"; then
    ok "(MU) $lbl: the mutant produces /$pat/ where the control does not — the assertion is load-bearing"
  else
    no "(MU) $lbl: the mutant produced no /$pat/, so the control's clean result is not attributable to this code"
  fi
}
mu_cli(){  # kind, label, want(0|nz), script, argv...
  local kind="$1" lbl="$2" want="$3" rc
  if ! mut2_build "$kind"; then mut2_failed "$kind"; return; fi
  shift 3
  python3 "$T2/mut-$kind/$1" "${@:2}" >"$T2/mu-$1-$kind.out" 2>&1; rc=$?
  if [ "$want" = "0" ] && [ "$rc" -eq 0 ]; then
    ok "(MU) $lbl: the mutant exits 0 where the control refuses — the refusal is load-bearing"
  elif [ "$want" = "nz" ] && [ "$rc" -ne 0 ]; then
    ok "(MU) $lbl: the mutant exits $rc where the control succeeds — the check really runs on every run"
  else
    no "(MU) $lbl: the mutant exited $rc (wanted $want): $(tail -1 "$T2/mu-$1-$kind.out")"
  fi
}

# The CLASS, not the id: B-marker-one is deliberately in the archive too (that is what E10's
# precedence is about), so with the marker branch disabled it still appears — as `archived`.
mu_gone nomarker     "E marker class"                     '^V=B-marker-one\|marker\|' classify $CLSARGS
mu_gone noarchive    "E archived class"                   '^V=B-archived-one\|'  classify $CLSARGS
mu_gone nodupclass   "E duplicate class"                  '^V=B-92\|'            classify $CLSARGS
mu_gone noobsolete   "E obsolete class"                   '^V=B-gone-one\|'      classify $CLSARGS
# mu_NEW, not mu_gone: the control produces NO marker row on that fixture, and the loose guard is what
# invents one. Asserting a disappearance here would have been asserting the absence of an absence.
mu_new  loosemarker  "E16 the strict heading predicate"   '\|marker\|' \
                     classify "$T2/heading-loose.md" "$T2/no-archive.md" "$FR"
mu_gone dupkeyonly   "E15 the pre-mint key bridge"        '\|duplicate\|'        classify "$T2/preminted.md" "$T2/no-archive.md" "$FR"
mu_new  duppayload   "E3 the closed verdict field"        '^LEDGERROW=[^|]*\|DUPLICATE-OF [^|]*\|[1-9]' classify $CLSARGS
mu_new  obscitesgone "E4 obsolete cites the backlog line" '^REFUSED=.*obsolete'  classify $CLSARGS
mu_new  archivefirst "E10 marker outranks the archive"    '^V=B-marker-one\|archived\|' classify $CLSARGS
mu_gone resolvelax   "E13 resolvability"                  '^RES=3\|.*no such file' \
                     resolve "$FR/memory/backlog.md" "$FR/memory/backlog-done.md" "$FR" \
                     "backlog.md:1 ok" "backlog.md:99999 far" "tools/vanished.py:1 gone" "no citation"
mu_gone linelax      "E12 the line-count half of (b)"     '^RES=2\|.*the file has' \
                     resolve "$FR/memory/backlog.md" "$FR/memory/backlog-done.md" "$FR" \
                     "backlog.md:1 ok" "backlog.md:99999 far" "tools/vanished.py:1 gone" "no citation"
mu_new  mintany      "N3 the mint-anchor filter"          '^MINT=.*kind=bullet'  mintsel "$FR/memory/backlog.md"
mu_gone nobodyid     "N4 the body-id filter"              '^SKIP=.*already shows a B-id' mintsel "$FR/memory/backlog.md"
mu_gone noidentity   "N5 the identity check"              '^MOVED_BAD=[1-9]'     mintlines "$FR/memory/backlog.md" "$T2/moved.md"
mu_gone bytesaslines "K1 bytes and not lines"             '^OVERSIZE_ROWS=1'     chunk "$T2/big.md" 4000
mu_gone chunktotals  "K3 the oversize-first split"        '^CHUNKS=2'            chunk "$T2/bigfirst.md" 4000
mu_gone noexpand     "X7 the ~ expansion"                 "^FOUND=$HOME\$"       expand "~"

# The CLI-level mutants: a refusal proves nothing until the mutant is shown to proceed past it.
MU_NG="$T2/mu-nogit"
mkdir -p "$MU_NG/memory" "$MU_NG/tools"
cp "$FR/memory/backlog.md" "$MU_NG/memory/backlog.md"; cp "$FR/tools/present.py" "$MU_NG/tools/"
MU_NG_B0="$(bytes2 "$MU_NG/memory/backlog.md")"
mu_cli noneopen "N17 the is_ignored() is None refusal on the WRITE path" 0 \
  backlog-groom.py plan --repo "$MU_NG"
[ "$(bytes2 "$MU_NG/memory/backlog.md")" != "$MU_NG_B0" ] \
  && ok "(MU) N17 the mutant actually WROTE into a file whose tracked-ness is unknown, which is precisely what the refusal prevents" \
  || no "(MU) N17 the mutant exited 0 without writing, so N17's rc=20 is not attributable to the \`is None\` branch"
# The LOCK mutant is read off the FILESYSTEM, not off an exit code: `zl.append_rows` takes the same
# lock for the ledger, so a run with the mint's lock removed still exits non-zero on the ledger write.
# What the mutation changes is that the MINT happens anyway — which is the data hazard the lock exists
# to prevent, and the only thing an exit code could not tell us.
MU_LK="$T2/mu-lock"
mk_wrepo "$MU_LK" || no "(MU) could not build the lock mutant repo"
mkdir -p "$MU_LK/memory/.backlog-archive.lock.d"; printf '%s\n' "$$" > "$MU_LK/memory/.backlog-archive.lock.d/pid"
MU_LK_B0="$(bytes2 "$MU_LK/memory/backlog.md")"
if mut2_build nolock2; then
  ZUVO_LOCK_WAIT=0.5 python3 "$T2/mut-nolock2/backlog-groom.py" plan --repo "$MU_LK" \
    >"$T2/mu-nolock2.out" 2>&1
  MU_LK_B1="$(bytes2 "$MU_LK/memory/backlog.md")"
  [ "$MU_LK_B0" != "$MU_LK_B1" ] \
    && ok "(MU) N20 the backlog lock: with it removed the mint writes straight through a HELD lock ($MU_LK_B0 -> $MU_LK_B1 bytes), so N20's untouched byte count measures the lock and not an unrelated error" \
    || no "(MU) N20 the lock mutant also wrote nothing ($MU_LK_B0 -> $MU_LK_B1), so N20's refusal is not attributable to the lock: $(tail -1 "$T2/mu-nolock2.out")"
else
  mut2_failed nolock2
fi
MU_DRY="$T2/mu-dry"
mk_wrepo "$MU_DRY" || no "(MU) could not build the dry-run mutant repo"
MU_DRY_B0="$(bytes2 "$MU_DRY/memory/backlog.md")"
mut2_build drywrites && python3 "$T2/mut-drywrites/backlog-groom.py" plan --repo "$MU_DRY" --dry-run \
  >"$T2/mu-dry.out" 2>&1
[ "$(bytes2 "$MU_DRY/memory/backlog.md")" != "$MU_DRY_B0" ] \
  && ok "(MU) N19 --dry-run really is what stops the write: with that one branch removed, the same command mints" \
  || no "(MU) N19 the drywrites mutant did not write either, so --dry-run's silence is not attributable to it"
MU_MH="$T2/mu-mintheadings"
mk_wrepo "$MU_MH" || no "(MU) could not build the heading-mint mutant repo"
# WHAT THIS MUTANT REVEALED, and it is the better half of the finding: unioning the id-less headings
# into the mint set does NOT reach the file, because minting `## Open` turns it into a heading ENTRY
# and the count-neutrality check then refuses. So the structure is protected TWICE — by the mint set
# being built from what `iter_entries` yields, and by a re-parse that refuses when the count moves.
# The assertion is therefore that the mutant REFUSES with the count code and writes nothing; asserting
# "the mutant writes into a heading" would have been asserting a thing that cannot happen.
MU_MH_B0="$(bytes2 "$MU_MH/memory/backlog.md")"
if mut2_build mintheadings; then
  python3 "$T2/mut-mintheadings/backlog-groom.py" plan --repo "$MU_MH" >"$T2/mu-mh.out" 2>&1
  MU_MH_RC=$?
  MU_MH_B1="$(bytes2 "$MU_MH/memory/backlog.md")"
  MU_MH_N="$(grep -cE '^#{1,6} .*B-A[0-9]{8}-[0-9a-f]{6}' "$MU_MH/memory/backlog.md" || true)"
  if [ "$MU_MH_RC" -eq 22 ] && [ "$MU_MH_B0" = "$MU_MH_B1" ] && [ "${MU_MH_N:-0}" = "0" ]; then
    ok "(MU) N14e/N14 the SECOND layer: with the id-less headings unioned into the mint set the run exits 22 (count-neutrality) having written nothing — minting a heading would turn it into an entry, and the re-parse refuses. N14's count check is what catches the structural write, not just a bookkeeping slip"
  else
    no "(MU) N14e/N14: the heading-mint mutant exited $MU_MH_RC with $MU_MH_B0 -> $MU_MH_B1 bytes and $MU_MH_N minted heading(s) — expected rc=22 and no write: $(tail -1 "$T2/mu-mh.out")"
  fi
else
  mut2_failed mintheadings
fi
MU_CN="$T2/mu-count"; mk_wrepo "$MU_CN" || no "(MU) could not build the count mutant repo"
mu_cli countoff "N14 count-neutrality really compares the two parses" nz \
  backlog-groom.py plan --repo "$MU_CN" --dry-run
MU_LN="$T2/mu-linecount"; mk_wrepo "$MU_LN" || no "(MU) could not build the line-count mutant repo"
mu_cli linecountoff "N6 the line-count invariant really runs" nz \
  backlog-groom.py plan --repo "$MU_LN" --dry-run
# `--min-repos 0` so ONLY the empty-root branch can decide: with the default 1 the mutant still
# exits 31 on the repo count, and the assertion would read as "the refusal survived the mutation".
mu_cli rootsopen "X5 the empty-root refusal" 0 \
  backlog-census.py --roots "$T2/definitely-not-a-directory" --min-repos 0
mu_cli minreposopen "X6 the --min-repos refusal" 0 backlog-census.py --roots "$CR" --min-repos 99

# ==================================================================================================
# TASK 3 — THE VERIFIER LANE and the four evidence controls.
#
# WHAT CANNOT BE TESTED HERE, said first so nothing below is mistaken for it: the TRUTH of a verdict.
# Controls (a) shape, (b) resolvability and (c) keyword overlap ask whether a verdict is well-formed and
# grounded in a line that exists. None of them can ask whether it is RIGHT — citing the very line the
# entry names satisfies all three while the verdict is still wrong. Only (d), the seeded known-answers,
# measures judgement, and it measures it on four rows per chunk. Every assertion below is about the
# mechanism; none of them is evidence that a verdict was correct.
#
# MEASURED FIRST, because three numbers in the plan were stale and one control's shape depends on them:
#   * 494 entries today (the plan says 387, an amendment says 330, the queue module said 483 — it moves
#     on every run that appends, so it is DERIVED here and never hardcoded);
#   * only 156 of the 494 have a path token in `normalize_signature`, so (c)'s basename half is
#     UNAVAILABLE for 338 of them — applied as a hard requirement it would reject two rows in three and
#     teach a verifier to cite a path the entry never named;
#   * 20 of the 494 have FEWER THAN 2 content words in their signature, which makes ">=2 of 8"
#     unsatisfiable rather than failed.
# So (c) has four recorded MODES, each with its own fixture and its own mutant, and a (c) pass rate
# quoted without that split is a number about a different control.
#
# NO VACUOUS ASSERTIONS, same rule as the two halves above: the dispatch is censused from its own bytes
# before any property of it is asserted, every rejection has a positive control on the SAME fixture, and
# the conservation cases are built so that the COUNT check passes — otherwise "the merged pair was
# caught" would be a restatement of "the count was wrong".
# ==================================================================================================
echo "== Task 3: the verifier lane and the evidence controls =="

AGENT_MD="$ROOT/skills/backlog/agents/backlog-verifier.md"
T3="$FIX/t3"
mkdir -p "$T3"
for f in "$AGENT_MD" "$AGENT_MOD" "$SEEDS_MOD" "$PREPASS_MOD"; do
  [ -f "$f" ] && ok "(V0) present: ${f#"$ROOT"/}" || { no "(V0) missing: ${f#"$ROOT"/} — nothing in this half can be checked"; finish; }
done

# --------------------------------------------------------------------------------------------------
# The Task 3 probe. Same contract as the Task 2 one: it is POINTED at a module directory, so a mutant
# is reached without editing anything in the checkout.
# --------------------------------------------------------------------------------------------------
T3PROBE="$T3/probe3.py"
cat > "$T3PROBE" <<'PYEOF'
r"""Machine-readable probe over zuvo_backlog_agent.py and zuvo_backlog_seeds.py.

RAW docstring for the same reason as its two siblings': a `\s` in a plain one is a SyntaxWarning on
stderr, and every caller reads stderr as "the mutant did not build".

Usage: probe3.py <moddir> <mode> [args...]
"""
import json
import os
import sys

MODDIR = os.path.abspath(sys.argv[1])
sys.path.insert(0, MODDIR)
import zuvo_backlog_agent as za     # noqa: E402
import zuvo_backlog_ledger as zl    # noqa: E402
import zuvo_backlog_parse as zb     # noqa: E402
import zuvo_backlog_seeds as zs     # noqa: E402
import zuvo_backlog_verdicts as zv  # noqa: E402


def out(key, value):
    print("%s=%s" % (key, value))


def jsonl(path):
    rows, defects = za.read_jsonl(path)
    for d in defects:
        print("DEFECT=" + d)
    return rows


def tree_of(real, archive, root):
    return zv.Tree(root=root, real=real, archive=archive)


def mode_ingest(dispatch, response, answers, real, archive, root):
    """The whole pipeline, and every number a caller needs to tell WHY it refused."""
    rows = jsonl(dispatch)
    recs = jsonl(response)
    with open(answers, encoding="utf-8") as fh:
        ans = {str(k): str(v) for k, v in json.load(fh).items()}
    res = za.ingest(rows, recs, ans, tree_of(real, archive, root))
    out("DISPATCHED", len(rows))
    out("RESPONDED", len(recs))
    out("NSEEDS", len(ans))
    out("NREJECTS", len(res.rejects))
    out("NACCEPTED", len(res.rows))
    for r in res.rejects:
        print("REJECT=%s|%s|%s" % (r.code, r.subject, r.why))
    for c in res.controls:
        print("CONTROL=" + c)
    for row in res.rows:
        probs = zl.validate_row(row, "accepted")
        print("ACCEPTED=%s|%s|%s|%d" % (row["id"], row["verdict"], row["verified_by"], len(probs)))
        print("SHA=%s|%s" % (row["id"], row["text_sha"]))


def mode_overlap(real, archive, root, raw_text, verdict, evidence):
    """Control (c) asked DIRECTLY on one crafted row, so one mutant kills one mode."""
    row = {"id": "B-probe", "keys": ["fp:000000000000"], "raw_text": raw_text,
           "text_sha": "0" * 40}
    rec = {"key": "fp:000000000000", "verdict": verdict, "evidence": evidence}
    mode, rej = za.check_overlap(row, rec, tree_of(real, archive, root))
    out("MODE", mode)
    out("NREJ", len(rej))
    for r in rej:
        print("REJ=%s|%s" % (r.code, r.why))


def mode_resolve(real, archive, root, verdict, evidence):
    """Control (b), including the NOT-VERIFIABLE exemption."""
    row = {"id": "B-probe"}
    rec = {"verdict": verdict, "evidence": evidence}
    rej = za.check_resolvable(row, rec, tree_of(real, archive, root))
    out("NREJ", len(rej))
    for r in rej:
        print("REJ=%s|%s" % (r.code, r.why))


def mode_shape(verdict, evidence):
    """Control (a) on one crafted record, through the LEDGER's own validator."""
    row = {"id": "B-probe", "keys": ["fp:000000000000"], "text_sha": "0" * 40}
    rej = za.check_shape(row, {"key": "fp:000000000000", "verdict": verdict, "evidence": evidence},
                         zl.now_stamp())
    out("NREJ", len(rej))
    for r in rej:
        print("REJ=%s|%s" % (r.code, r.why))


def mode_sig(raw_text):
    base, words = za.signature_parts(raw_text)
    out("BASE", base or "-")
    out("NWORDS", len(words))
    out("WORDS", " ".join(words))


def mode_seeds(root, archive, k):
    """The seeds, their answers, the shortfall, and the field set that makes them indistinguishable."""
    arch = [e.body for e in zb.iter_entries(open(archive, encoding="utf-8").read(),
                                            kinds=zb.DEFAULT_KINDS + (zb.KIND_HEADING,))]
    live = zs.live_anchors(root, int(k))
    rows, ans, short = zs.build_seeds(0, arch, live, int(k))
    out("NARCH", len(arch))
    out("NLIVE", len(live))
    out("NSEEDS", len(rows))
    out("SHORT", short or "-")
    out("EXPECTED", ",".join("%s=%s" % (k2, v) for k2, v in sorted(ans.items())))
    for r in rows:
        print("SEED=%s|%s" % (r["id"], r["raw_text"].strip()))
        print("FIELDS=%s" % ",".join(sorted(r)))


def mode_interleave(n, *keys):
    rows = [{"id": k, "keys": [k]} for k in keys]
    order = [r["id"] for r in zs.interleave(rows, "chunk%s" % n)]
    out("ORDER", ",".join(order))
    out("SEEDPOS", ",".join(str(i) for i, k in enumerate(order) if k.startswith("fp:ffff")))


def mode_conserve(dispatch, response):
    rows = jsonl(dispatch)
    recs = jsonl(response)
    rej = za.conserve(rows, recs)
    out("NREJECTS", len(rej))
    for r in rej:
        print("REJECT=%s|%s|%s" % (r.code, r.subject, r.why))


MODES = {"ingest": mode_ingest, "overlap": mode_overlap, "resolve": mode_resolve,
         "shape": mode_shape, "sig": mode_sig, "seeds": mode_seeds,
         "interleave": mode_interleave, "conserve": mode_conserve}
MODES[sys.argv[2]](*sys.argv[3:])
PYEOF
probe3(){ python3 "$T3PROBE" "$@"; }

if probe3 "$CTL2" sig "src/loader.ts the handle is never on retry" >"$T3/import.out" 2>"$T3/import.err"; then
  ok "(V0b) the Task 3 probe imports both new modules and runs"
else
  no "(V0b) the Task 3 probe could not run: $(tail -3 "$T3/import.err") — nothing below can be checked"
  finish
fi

# ==================================================================================================
# The Task 3 fixture repo. Four tracked .md/.py/.sh files so the seed derivation has four LIVE anchors
# to spread over, a production file whose lines carry the entries' signature words (control (c) needs a
# window that really contains them), and an archive whose keys deliberately do NOT collide with the open
# entries — otherwise the deterministic `archived` class decides them and nothing reaches the lane.
# ==================================================================================================
T3R="$T3/repo"
mkdir -p "$T3R/memory" "$T3R/src" "$T3R/docs" "$T3R/tools"
( cd "$T3R" && git init -q . >/dev/null 2>&1 ) || no "(V0c) could not git init the Task 3 fixture repo"
# THE LINE NUMBERS ARE THE FIXTURE. Each (c) case below depends on a DISTANCE, so the padding is
# load-bearing: alpha's signature words sit only on :3, beta's only on :12, and :15-:25 is a region
# whose tokens share NONE of alpha's words. Without that region the "unrelated window" case scored two
# hits on `the` and `handle` out of `return handle;` and (c) passed a citation it exists to reject.
cat > "$T3R/src/loader.ts" <<'EOF'
export function load() {
  const handle = open();
  // the handle is never released on the retry path
  return handle;
}


  const untouched = 1;
  const separate = 2;
export function budget() {
  // the retry budget has no ceiling anywhere in here
  return Infinity;
}
const filler1 = 1;
const filler2 = 2;
const filler3 = 3;
const filler4 = 4;
const filler5 = 5;
const filler6 = 6;
const filler7 = 7;
const filler8 = 8;
const filler9 = 9;
const filler10 = 10;
const filler11 = 11;
EOF
printf 'export const lone = 1;\n' > "$T3R/src/lone.ts"
printf 'the docs note names the loader handle explicitly here\n' > "$T3R/docs/one.md"
printf 'the second doc names the retry budget ceiling here\n'     > "$T3R/docs/two.md"
printf '# a python helper with four or more words here\n'         > "$T3R/tools/three.py"
printf '# a shell helper with four or more words here\n'          > "$T3R/tools/four.sh"
cat > "$T3R/memory/backlog.md" <<'EOF'
# Tech Debt Backlog

## Open

- [ ] B-t3-alpha src/loader.ts the handle is never released on retry
- [ ] B-t3-beta the retry budget has no ceiling anywhere in here
- [ ] B-t3-short src/lone.ts a
EOF
# `src/lone.ts` is created above ON PURPOSE. With it absent, `cited_paths` finds it, every cited path of
# that entry is gone, and the deterministic OBSOLETE class decides the row — so it never reaches the
# lane, the dispatch is 6 rows instead of 7, and every conservation case below is about a row that was
# never dispatched. Measured: that is exactly what happened on the first run.
cat > "$T3R/memory/backlog-done.md" <<'EOF'
# Archived

## Archived from backlog.md on 2026-09-01 (2 entries)

- [x] B-t3-done-one src/loader.ts the tenant was missing from the cache key — FIXED 1a2b3c4
- [x] B-t3-done-two src/loader.ts the socket timeout was pinned to zero — FIXED 9f2c1a4
EOF
printf '/memory/backlog.md\n/memory/backlog-done.md\n/memory/backlog-verdicts.jsonl\n/memory/.backlog-archive.lock.d/\n/zuvo/\n' > "$T3R/.gitignore"
( cd "$T3R" && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t commit -qm fixture >/dev/null 2>&1 ) \
  || no "(V0c) could not commit the Task 3 fixture repo — `git ls-files` drives the live anchors"

echo "-- V: the Task 3 fixture, censused from its own bytes --"
V_TRACKED="$( cd "$T3R" && git ls-files | grep -cE '\.(py|sh|md)$' )"
[ "$V_TRACKED" -ge 4 ] \
  && ok "(V1) the fixture tracks $V_TRACKED .py/.sh/.md file(s) — enough for the four live anchors, so a seed SHORTFALL below is about the control and not about the fixture's size" \
  || no "(V1) only $V_TRACKED tracked .py/.sh/.md file(s); the seed derivation would be short for a reason that has nothing to do with (d)"
grep -qF 'the handle is never released on the retry path' "$T3R/src/loader.ts" \
  && ok "(V2) src/loader.ts physically contains B-t3-alpha's signature words, so a (c) PASS below is a pass over a real window" \
  || no "(V2) the production fixture does not carry the entry's words — every (c) assertion would be about an empty window"
probe3 "$CTL2" sig "src/loader.ts the handle is never released on retry" >"$T3/sig-a.out" 2>&1
probe3 "$CTL2" sig "the retry budget has no ceiling anywhere in here"    >"$T3/sig-b.out" 2>&1
probe3 "$CTL2" sig "src/lone.ts a"                                      >"$T3/sig-c.out" 2>&1
cat "$T3/sig-a.out" "$T3/sig-b.out" "$T3/sig-c.out"
sv(){ sed -n "s/^$2=//p" "$T3/sig-$1.out" | head -1; }
[ "$(sv a BASE)" = "loader.ts" ] && [ "$(sv a NWORDS)" -ge 2 ] \
  && ok "(V3) B-t3-alpha's signature is basename=loader.ts with $(sv a NWORDS) content words — the \`full\` (c) mode is reachable on it" \
  || no "(V3) B-t3-alpha's signature is base=$(sv a BASE) words=$(sv a NWORDS); the full mode would not be exercised"
[ "$(sv b BASE)" = "-" ] && [ "$(sv b NWORDS)" -ge 2 ] \
  && ok "(V4) B-t3-beta's signature has NO path token and $(sv b NWORDS) words — the \`words-only\` mode is reachable, which is the mode 338 of this repo's 494 entries fall into" \
  || no "(V4) B-t3-beta's signature is base=$(sv b BASE) words=$(sv b NWORDS); the words-only mode would not be exercised"
[ "$(sv c NWORDS)" -lt 2 ] \
  && ok "(V5) B-t3-short's signature holds only $(sv c NWORDS) content word(s), so '>=2 of 8' is UNSATISFIABLE on it — the n/a mode is reachable, which is the mode 20 of the 494 fall into" \
  || no "(V5) B-t3-short's signature holds $(sv c NWORDS) words; the too-short mode would not be exercised"

# ==================================================================================================
# The REAL CLI round trip: plan -> dispatch -> ingest, on the fixture repo. The dispatch is built by the
# command under test rather than by hand, so "one record per row" is asserted against the row shape the
# command really emits and not against a shape this file invented.
# ==================================================================================================
echo "-- W: plan -> dispatch, through the commands themselves --"
groom3(){ python3 "$CTL2/backlog-groom.py" "$@"; }
groom3 plan --repo "$T3R" >"$T3/plan.out" 2>&1; W_PLAN_RC=$?
[ "$W_PLAN_RC" -eq 0 ] \
  && ok "(W1) plan exits 0 on the Task 3 fixture" \
  || no "(W1) plan exited $W_PLAN_RC: $(tail -2 "$T3/plan.out")"
W_ENT="$(sed -n 's/^ENTRIES=//p' "$T3/plan.out" | head -1)"
W_DET="$(sed -n 's/^DETERMINISTIC=//p' "$T3/plan.out" | head -1)"
[ "${W_ENT:-0}" = "3" ] && [ "${W_DET:-1}" = "0" ] \
  && ok "(W2) the fixture yields 3 entries and 0 deterministic verdicts, so all three reach the LANE — a fixture whose entries were decided by the pre-pass would exercise none of this" \
  || no "(W2) the fixture yields ${W_ENT:-?} entries with ${W_DET:-?} deterministic verdict(s); the lane assertions would be about a different set"

groom3 dispatch --repo "$T3R" --chunk 0 >"$T3/disp.out" 2>&1; W_DISP_RC=$?
cat "$T3/disp.out"
DISP="$T3R/zuvo/context/backlog-dispatch-0.jsonl"
ANS="$T3R/zuvo/context/backlog-answers-0.json"
if [ "$W_DISP_RC" -eq 0 ] && [ -f "$DISP" ] && [ -f "$ANS" ]; then
  ok "(W3) dispatch exits 0 and writes both files — the chunk AND the answer key, which are deliberately two files"
else
  no "(W3) dispatch exited $W_DISP_RC; dispatch=$([ -f "$DISP" ] && echo yes || echo no) answers=$([ -f "$ANS" ] && echo yes || echo no): $(tail -2 "$T3/disp.out")"
  finish
fi
W_DROWS="$(grep -c . "$DISP")"
W_NSEED="$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))))" "$ANS")"
[ "$W_DROWS" = "7" ] && [ "$W_NSEED" = "4" ] \
  && ok "(W4) the dispatch holds 7 rows = 3 real + 4 seeds (K=4), censused from the file's own bytes" \
  || no "(W4) the dispatch holds $W_DROWS row(s) with $W_NSEED seed answer(s), expected 7 and 4"
W_FIXED="$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(sum(1 for v in d.values() if v=='STALE-FIXED'))" "$ANS")"
W_REAL="$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(sum(1 for v in d.values() if v=='STILL-REAL'))" "$ANS")"
[ "$W_FIXED" = "2" ] && [ "$W_REAL" = "2" ] \
  && ok "(W5/d) the seeds split 2 provably-fixed / 2 provably-still-real, so a miss is catchable in EITHER direction" \
  || no "(W5/d) the seed split is $W_FIXED fixed / $W_REAL still-real, expected 2/2 — a one-sided seed set cannot catch a one-sided bias"
# THE ANSWER KEY IS NOT IN THE DISPATCH. A chunk carrying its own expected answers gates nothing.
grep -qE 'STALE-FIXED|STILL-REAL|expect|zuvo-seed' "$DISP" \
  && no "(W6/d) the dispatched chunk contains a verdict word or a seed marker — a verifier can read the answers off the rows it is being graded on" \
  || ok "(W6/d) the dispatched chunk carries no verdict word and no seed marker: the expected answers live only in the separate key file"
# INDISTINGUISHABLE BY FIELD SET, not only by content: a seed with one extra key is a seed a verifier
# can select on with `jq`.
W_FS="$(python3 - "$DISP" "$ANS" <<'PYEOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
ans = json.load(open(sys.argv[2], encoding="utf-8"))
sets = {frozenset(r) for r in rows}
seeds = {frozenset(r) for r in rows if r["keys"][0] in ans}
real = {frozenset(r) for r in rows if r["keys"][0] not in ans}
print("%d %d %d" % (len(sets), len(seeds), 1 if seeds == real else 0))
PYEOF
)"
case "$W_FS" in
  "1 1 1") ok "(W7/d) every dispatched row has the IDENTICAL field set ($W_FS) — a seed cannot be selected on its shape" ;;
  *) no "(W7/d) the dispatched rows have $W_FS distinct field sets / seed sets / equality — a seed distinguishable by field is a seed that gates nothing" ;;
esac
W_POS="$(sed -n 's/^DISPATCH_ROWS=[0-9]* seed_positions=//p' "$T3/disp.out" | head -1)"
# WHAT THIS CAN AND CANNOT ASSERT, measured rather than assumed, because the first two versions of it
# asserted something a correct interleave fails by chance.
#
# A POSITION assertion is not available on this chunk. K=4 seeds among 7 rows means the seeds are more
# than half the file, and "one contiguous block" is 1 of the 35 arrangements — so a correct stable hash
# lands there roughly 3% of the time. It did: the control puts all four at 0,1,2,3, and the previous
# assertion failed on a hash that is working. A bigger fixture would only move the probability, not the
# category of the mistake.
#
# THE MECHANISM IS ASSERTABLE, and it is what the interleave actually exists for: the dispatch ORDER
# must be neither the key-SORTED order (which parks every `fp:ffff…` seed key before every real `fp:`
# and `id:` key — the `sortorder` mutant below produces exactly that) nor the APPEND order (real rows,
# then seeds bolted on the end). Both are orders a verifier can reconstruct without reading a row;
# neither is what the file holds.
W_ORD="$(python3 -c "
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding='utf-8') if l.strip()]
keys = [r['keys'][0] for r in rows]
seeds = sorted(k for k in keys if k.startswith('fp:ffff'))
real  = sorted(k for k in keys if not k.startswith('fp:ffff'))
print('%d %d' % (int(keys == sorted(keys)), int(keys == real + seeds)))" "$DISP")"
case "$W_ORD" in
  "0 0") ok "(W8/d) the dispatch order is neither the key-sorted order nor 'real rows then seeds appended' — the seeds sit where a stable hash of (salt, key) puts them (here: positions $W_POS), so their position carries no information a verifier can use" ;;
  "1 "*) no "(W8/d) the dispatch is in KEY-SORTED order, which parks every fp:ffff seed key in one block before the real keys — a verifier can name the graded rows without reading one" ;;
  *"1")  no "(W8/d) the dispatch is the APPEND order (real rows, then the four seeds bolted on the end) — the last K rows are the graded ones" ;;
  *) no "(W8/d) could not decide the dispatch order (probe said '$W_ORD')" ;;
esac
[ -n "$W_POS" ] \
  && ok "(W8b/d) dispatch REPORTS the seed positions ($W_POS), so a reader can see the spread instead of inferring it" \
  || no "(W8b/d) dispatch printed no seed_positions line"
# The closed seeds are STRIPPED. Verbatim, the marker makes the answer legible from the seed's own text
# and (d) degrades into a reading test.
grep -E '^\{.*"raw_text"' "$DISP" | grep -qE 'FIXED [0-9a-f]{7}' \
  && no "(W9/d) a dispatched seed still carries its FIXED <sha> marker — the answer is legible from the row, so (d) measures reading rather than judgement" \
  || ok "(W9/d) the closed seeds arrive with their resolution markers stripped, so finding the fix is the work the seed measures"

# ==================================================================================================
# The RESPONSES. One clean, one that fails each control, and the AC6 response that fails three at once
# while keeping the COUNT correct — built by a committed generator, so a fixture change cannot silently
# turn a rejection case into a passing one.
# ==================================================================================================
MKRESP="$T3/mkresp.py"
cat > "$MKRESP" <<'PYEOF'
r"""Build a verifier response for the Task 3 dispatch.

Usage: mkresp.py <dispatch> <answers> <flavour>

The CLEAN flavour is the oracle every other one is a single edit away from: each rejection case below is
the clean response with exactly ONE thing changed, which is what makes the rejection attributable.
"""
import json
import sys

DISPATCH, ANSWERS, FLAVOUR = sys.argv[1:4]
rows = [json.loads(l) for l in open(DISPATCH, encoding="utf-8") if l.strip()]
ans = {str(k): str(v) for k, v in json.load(open(ANSWERS, encoding="utf-8")).items()}

# The evidence a CORRECT verifier would produce for each real row of the fixture.
REAL = {
    "id:b-t3-alpha": ("STILL-REAL",
                      "src/loader.ts:3 the handle is never released on the retry path"),
    "id:b-t3-beta": ("STILL-REAL",
                     "src/loader.ts:12 the retry budget has no ceiling anywhere in here"),
    "id:b-t3-short": ("NOT-VERIFIABLE",
                      "the entry names one path and one word, and the repo does not answer it"),
}


def answer(row):
    key = row["keys"][0]
    if key in ans and ans[key] == "STALE-FIXED":
        # the archive-proof shape the include's evidence table permits for this verdict
        line = 5 if key.endswith("0") else 6
        return "STALE-FIXED", ('backlog-done.md:%d section="Archived from backlog.md" '
                               'records the closure' % line)
    if key in ans:
        path, lineno = row["raw_text"].split()[0].split(":")
        words = " ".join(row["raw_text"].split()[3:9])
        return "STILL-REAL", "%s:%s %s" % (path, lineno, words)
    return REAL[key]


out = []
for row in rows:
    key = row["keys"][0]
    verdict, evidence = answer(row)
    out.append({"key": key, "verdict": verdict, "evidence": evidence})

if FLAVOUR == "clean":
    pass
elif FLAVOUR == "omit":                        # one dispatched row simply absent
    out = [r for r in out if r["key"] != "id:b-t3-short"]
elif FLAVOUR == "merged":                      # COUNT preserved: one row answered twice, one dropped
    out = [r for r in out if r["key"] != "id:b-t3-short"]
    out.append(dict(next(r for r in out if r["key"] == "id:b-t3-alpha")))
elif FLAVOUR == "extra":                       # a key nobody dispatched
    out.append({"key": "fp:aaaaaaaaaaaa", "verdict": "STILL-REAL", "evidence": "src/loader.ts:1 x"})
elif FLAVOUR == "fabricated":                  # a well-formed citation past the end of a real file
    for r in out:
        if r["key"] == "id:b-t3-alpha":
            r["evidence"] = "src/loader.ts:9000 the handle is never released on the retry path"
elif FLAVOUR == "wrongfile":                   # (c): a resolvable line in the WRONG file
    for r in out:
        if r["key"] == "id:b-t3-alpha":
            r["evidence"] = "docs/two.md:1 the handle is never released on the retry path"
elif FLAVOUR == "nowords":                     # (c): the right file, a window without the signature
    for r in out:
        if r["key"] == "id:b-t3-alpha":
            # :20 sits in the filler region, whose +/-5 window shares no WORD with alpha's signature.
            r["evidence"] = "src/loader.ts:20 const filler6 assigns six"
elif FLAVOUR == "badverdict":                  # (a): outside the closed five
    for r in out:
        if r["key"] == "id:b-t3-alpha":
            r["verdict"] = "PROBABLY-REAL"
elif FLAVOUR == "noloc":                       # (a): STILL-REAL with no path:line at all
    for r in out:
        if r["key"] == "id:b-t3-alpha":
            r["evidence"] = "the handle is never released, I checked"
elif FLAVOUR == "twoline":                     # (a): a second, unchecked citation on a second line
    for r in out:
        if r["key"] == "id:b-t3-alpha":
            r["evidence"] = ("src/loader.ts:3 the handle is never released on the retry path\n"
                             "src/loader.ts:9000 and also this")
elif FLAVOUR == "seedfixed":                   # (d): a provably-FIXED seed answered STILL-REAL
    for r in out:
        if ans.get(r["key"]) == "STALE-FIXED":
            r["verdict"] = "STILL-REAL"
            r["evidence"] = "src/loader.ts:3 the handle is never released on the retry path"
            break
elif FLAVOUR == "seedreal":                    # (d): a provably-STILL-REAL seed answered STALE-FIXED
    for r in out:
        if ans.get(r["key"]) == "STILL-REAL":
            r["verdict"] = "STALE-FIXED"
            r["evidence"] = 'backlog-done.md:5 section="Archived from backlog.md" records it'
            break
elif FLAVOUR == "ac6":                         # AC6: omit one, merge two, fabricate one — COUNT intact
    out = [r for r in out if r["key"] != "id:b-t3-short"]
    out.append(dict(next(r for r in out if r["key"] == "id:b-t3-alpha")))
    for r in out:
        if r["key"] == "id:b-t3-beta":
            r["evidence"] = "src/loader.ts:9000 the retry budget has no ceiling anywhere in here"
else:
    sys.exit("mkresp: unknown flavour %r" % FLAVOUR)

for r in out:
    print(json.dumps(r, sort_keys=True))
PYEOF
mkresp(){ python3 "$MKRESP" "$DISP" "$ANS" "$1" > "$T3/resp-$1.jsonl"; }
for fl in clean omit merged extra fabricated wrongfile nowords badverdict noloc twoline \
          seedfixed seedreal ac6; do
  mkresp "$fl" || no "(W10) could not build the '$fl' response"
done
ok "(W10) all 13 response flavours build from one committed generator, each a single edit away from the clean one"

ing3(){ probe3 "$CTL2" ingest "$DISP" "$T3/resp-$1.jsonl" "$ANS" \
        "$T3R/memory/backlog.md" "$T3R/memory/backlog-done.md" "$T3R" >"$T3/ing-$1.out" 2>&1; }
iv(){ sed -n "s/^$2=//p" "$T3/ing-$1.out" | head -1; }

# ---- THE POSITIVE CONTROL. Every rejection below is a rejection of the CHANGE, not of the fixture. --
echo "-- P: the clean response passes every control --"
ing3 clean
cat "$T3/ing-clean.out"
[ "$(iv clean NREJECTS)" = "0" ] \
  && ok "(P1) the clean response is accepted with zero rejections — without this every case below would be ambiguous between 'the control fired' and 'the fixture is broken'" \
  || no "(P1) the clean response was rejected: $(grep '^REJECT=' "$T3/ing-clean.out" | head -2)"
[ "$(iv clean NACCEPTED)" = "3" ] \
  && ok "(P2) exactly 3 ledger rows come back for 7 dispatched rows — the 4 seeds are checked and then DROPPED, because a seed is not an entry and a ledger row for one would judge text backlog.md does not contain" \
  || no "(P2) $(iv clean NACCEPTED) accepted row(s), expected 3 (7 dispatched minus 4 seeds)"
[ "$(grep -c '^ACCEPTED=' "$T3/ing-clean.out")" = "3" ] \
  && ok "(P2b) all three accepted rows were printed, so P3/P4 below are about a set that was measured rather than assumed" \
  || no "(P2b) $(grep -c '^ACCEPTED=' "$T3/ing-clean.out") accepted row(s) printed"
[ "$(grep '^ACCEPTED=' "$T3/ing-clean.out" | grep -vc '|0$')" = "0" ] \
  && ok "(P3) every accepted row passes the LEDGER's own validate_row — the lane cannot write a row its reader would reject" \
  || no "(P3) a row the lane accepted fails validate_row: $(grep '^ACCEPTED=' "$T3/ing-clean.out" | grep -v '|0$' | head -1)"
[ "$(grep '^ACCEPTED=' "$T3/ing-clean.out" | grep -c 'agent:backlog-verifier')" = "3" ] \
  && ok "(P4) all three carry verified_by=agent:backlog-verifier, which is what the cross-model spot check selects on" \
  || no "(P4) the provenance is not the lane's: $(grep '^ACCEPTED=' "$T3/ing-clean.out" | head -1)"
# The sha comes from the DISPATCH, never from the response: a responder restating the sha of the text it
# judged would turn staleness from a measurement into a claim.
P_SHA_OK=0
while IFS= read -r line; do
  rid="${line%%|*}"; rsha="${line##*|}"
  dsha="$(python3 -c "
import json,sys
for l in open(sys.argv[1],encoding='utf-8'):
    r=json.loads(l)
    if r['id']==sys.argv[2]: print(r['text_sha']); break" "$DISP" "$rid")"
  [ -n "$dsha" ] && [ "$rsha" = "$dsha" ] && P_SHA_OK=$((P_SHA_OK+1))
done <<< "$(sed -n 's/^SHA=//p' "$T3/ing-clean.out")"
[ "$P_SHA_OK" = "3" ] \
  && ok "(P5) all 3 ledger rows carry the DISPATCH's text_sha, compared row by row against the dispatch file" \
  || no "(P5) only $P_SHA_OK of 3 rows carry the dispatched sha — the invalidation key would be whatever the responder said it was"
# The four (c) modes, all four exercised on this one response.
for m in full words-only archive-proof "n/a:"; do
  grep -qF "c=$m" "$T3/ing-clean.out" \
    && ok "(P6) control (c) mode '$m' is exercised by the clean response" \
    || no "(P6) no row was checked in (c) mode '$m' — the mode is unexercised, so its assertion below would be about dead code"
done

# ==================================================================================================
# C — CONSERVATION, three ways. The merged case keeps the COUNT correct on purpose: otherwise "the merge
# was caught" would be a restatement of "the count was wrong", which is the whole reason check 3 exists.
# ==================================================================================================
echo "-- C: conservation against the dispatched queue --"
c_case(){  # flavour, code, subject-substring, label
  ing3 "$1"
  local got; got="$(grep "^REJECT=$2|" "$T3/ing-$1.out" | head -1)"
  if [ -z "$got" ]; then
    no "(C) $4: no $2 rejection at all. got: $(grep -c '^REJECT=' "$T3/ing-$1.out") rejection(s) $(grep '^REJECT=' "$T3/ing-$1.out" | cut -d'|' -f1 | sort -u | tr '\n' ' ')"
    return
  fi
  case "$got" in
    *"$3"*) ok "(C) $4 — $2 names $3" ;;
    *) no "(C) $4: $2 fired but names the wrong subject: $got" ;;
  esac
  [ "$(iv "$1" NACCEPTED)" = "0" ] \
    && ok "(C) $4: zero ledger rows come back — nothing partial is ever appended" \
    || no "(C) $4: $(iv "$1" NACCEPTED) row(s) still came back from a response that failed conservation"
}
c_case omit   KEYSET       "B-t3-short"   "an OMITTED row is a FAILURE, named by id, never an implicit verdict"
c_case extra  UNKNOWN-KEY  "fp:aaaa"      "a key nobody dispatched is rejected"
c_case merged MULTIPLICITY "id:b-t3-alpha" "a MERGED PAIR is caught by the distinct-key count"
# The merged case's own premise, asserted so C3 cannot be a restatement of a count failure.
ing3 merged
[ "$(iv merged DISPATCHED)" = "$(iv merged RESPONDED)" ] \
  && ok "(C4) the merged response has the SAME record count as the dispatch ($(iv merged RESPONDED)=$(iv merged DISPATCHED)) — so MULTIPLICITY is what caught it, and a count check alone would have passed it" \
  || no "(C4) the merged response has $(iv merged RESPONDED) records for $(iv merged DISPATCHED) rows; the merge case is testing the count check instead"
grep -q '^REJECT=COUNT|' "$T3/ing-merged.out" \
  && no "(C4b) the merged response ALSO tripped COUNT, so C3 is not attributable to the distinct-key check" \
  || ok "(C4b) the merged response trips MULTIPLICITY without tripping COUNT — the two checks are separable on this fixture"
ing3 omit
grep -q '^REJECT=COUNT|' "$T3/ing-omit.out" \
  && ok "(C5) the omit case DOES trip COUNT as well as KEYSET, which is the pair a plain omission produces" \
  || no "(C5) the omit case did not trip COUNT, so the count check is not running"
# DISPATCH-AMBIGUOUS: two rows answering to one key, refused BEFORE a model is paid for it. Measured 0
# such rows in today's 414-row dispatch, so the case is constructed.
AMBIG="$T3/ambig.jsonl"
python3 - "$DISP" > "$AMBIG" <<'PYEOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
rows[1] = dict(rows[1], keys=rows[0]["keys"], id=rows[1]["id"])
for r in rows:
    print(json.dumps(r, sort_keys=True))
PYEOF
probe3 "$CTL2" conserve "$AMBIG" "$T3/resp-clean.jsonl" >"$T3/ambig.out" 2>&1
grep -q '^REJECT=DISPATCH-AMBIGUOUS|' "$T3/ambig.out" \
  && ok "(C6) two dispatched rows sharing one key is refused as DISPATCH-AMBIGUOUS — 'exactly one record per row' has no answer there, so it is refused before the fan-out rather than after" \
  || no "(C6) a dispatch with a duplicated key was accepted: $(head -3 "$T3/ambig.out" | tr '\n' ' ')"
probe3 "$CTL2" conserve "$DISP" "$T3/resp-clean.jsonl" >"$T3/cons-clean.out" 2>&1
[ "$(sed -n 's/^NREJECTS=//p' "$T3/cons-clean.out" | head -1)" = "0" ] \
  && ok "(C6b) the UNMODIFIED dispatch is not ambiguous, so C6 is a rejection of the duplicated key and not of the fixture" \
  || no "(C6b) the clean dispatch is itself rejected by conserve: $(head -2 "$T3/cons-clean.out")"

# ==================================================================================================
# A — CONTROL (a), shape. Reused from the ledger's own validator rather than re-implemented, so the two
# cannot drift; the one thing added here is "exactly ONE evidence line".
# ==================================================================================================
echo "-- A: control (a), shape --"
a_case(){  # flavour, substring the SHAPE reason must contain, label
  ing3 "$1"
  local got; got="$(grep '^REJECT=SHAPE|' "$T3/ing-$1.out" | head -1)"
  if [ -z "$got" ]; then no "(A) $3: no SHAPE rejection; got $(grep '^REJECT=' "$T3/ing-$1.out" | cut -d'|' -f1 | sort -u | tr '\n' ' ')"; return; fi
  case "$got" in
    *"$2"*) ok "(A) $3" ;;
    *) no "(A) $3: SHAPE fired with the wrong reason: $got" ;;
  esac
}
a_case badverdict "outside the closed set" "a verdict outside the closed five is rejected, naming the set"
a_case noloc      "STILL-REAL without"     "STILL-REAL with no path:line is INVALID, not weak"
a_case twoline    "spans 2 lines"          "a two-line evidence string is rejected — a second line is where a second, unchecked citation hides"
probe3 "$CTL2" shape "STILL-REAL" "src/loader.ts:3 a citation and some words" >"$T3/shape-ok.out" 2>&1
[ "$(sed -n 's/^NREJ=//p' "$T3/shape-ok.out" | head -1)" = "0" ] \
  && ok "(A4) control (a) accepts a well-formed STILL-REAL row — the three rejections above are rejections of the CHANGE" \
  || no "(A4) control (a) rejects a well-formed row: $(grep '^REJ=' "$T3/shape-ok.out" | head -1)"
probe3 "$CTL2" shape "DUPLICATE-OF" "backlog.md:5 duplicates backlog.md:9" >"$T3/shape-dup.out" 2>&1
grep -q '^REJ=SHAPE|.*DUPLICATE-OF must name' "$T3/shape-dup.out" \
  && ok "(A5) a DUPLICATE-OF whose evidence names no id:/fp: key is rejected — the key rides in the evidence because the verdict field is a closed set of five" \
  || no "(A5) a keyless DUPLICATE-OF was accepted: $(cat "$T3/shape-dup.out" | tr '\n' ' ')"

# ==================================================================================================
# B — CONTROL (b), resolvability, and the ONE exemption that keeps NOT-VERIFIABLE cheap.
# ==================================================================================================
echo "-- B: control (b), resolvability --"
ing3 fabricated
grep -q '^REJECT=UNRESOLVABLE|B-t3-alpha|.*the file has' "$T3/ing-fabricated.out" \
  && ok "(B1) a well-formed citation PAST THE END of a real file is rejected, naming the real line count — the half of (b) that catches a plausible fabrication rather than an impossible one" \
  || no "(B1) the fabricated citation was accepted: $(grep '^REJECT=' "$T3/ing-fabricated.out" | head -2)"
[ "$(iv fabricated NACCEPTED)" = "0" ] \
  && ok "(B1b) the fabricated response writes zero rows, including the two rows that were correct" \
  || no "(B1b) $(iv fabricated NACCEPTED) row(s) were accepted alongside the fabrication"
probe3 "$CTL2" resolve "$T3R/memory/backlog.md" "$T3R/memory/backlog-done.md" "$T3R" \
  "NOT-VERIFIABLE" "the repo does not answer this and there is nothing to cite" >"$T3/res-nv.out" 2>&1
[ "$(sed -n 's/^NREJ=//p' "$T3/res-nv.out" | head -1)" = "0" ] \
  && ok "(B2) NOT-VERIFIABLE with NO citation at all is accepted — the exemption is in the CODE, which is what makes the honest answer cheap instead of merely permitted" \
  || no "(B2) NOT-VERIFIABLE was required to cite something: $(grep '^REJ=' "$T3/res-nv.out" | head -1)"
probe3 "$CTL2" resolve "$T3R/memory/backlog.md" "$T3R/memory/backlog-done.md" "$T3R" \
  "STILL-REAL" "the defect is there, take my word for it" >"$T3/res-sr.out" 2>&1
[ "$(sed -n 's/^NREJ=//p' "$T3/res-sr.out" | head -1)" != "0" ] \
  && ok "(B3) the SAME citation-free evidence IS rejected for STILL-REAL — so B2 measures the exemption and not a control that stopped running" \
  || no "(B3) citation-free evidence was accepted for STILL-REAL too, so (b) is not running at all"

# ==================================================================================================
# Cc — CONTROL (c), keyword overlap, in all four of its modes. THE LIMIT FIRST: (c) catches FABRICATION,
# not MISJUDGEMENT. Citing the very line the entry names satisfies it while the verdict is still wrong,
# and Cc6 below asserts exactly that — a deliberately WRONG verdict on a correct citation passes (c),
# which is the honest statement of what this control buys.
# ==================================================================================================
echo "-- Cc: control (c), keyword overlap and its four modes --"
ing3 wrongfile
grep -q '^REJECT=OVERLAP|B-t3-alpha|.*basenames differ' "$T3/ing-wrongfile.out" \
  && ok "(Cc1) a RESOLVABLE citation in the WRONG file is rejected on basename equality — (b) alone would have passed it, because docs/two.md:1 exists" \
  || no "(Cc1) the wrong-file citation was accepted: $(grep '^REJECT=' "$T3/ing-wrongfile.out" | head -2)"
ing3 nowords
grep -qE '^REJECT=OVERLAP\|B-t3-alpha\|[01] of [0-9]+ signature word' "$T3/ing-nowords.out" \
  && ok "(Cc2) the RIGHT file at a line whose +/-5 window holds fewer than 2 signature words is rejected, with the hit count named" \
  || no "(Cc2) a citation into an unrelated window of the right file was accepted: $(grep '^REJECT=' "$T3/ing-nowords.out" | head -2)"
c3_mode(){  # label, expected mode, raw_text, verdict, evidence
  probe3 "$CTL2" overlap "$T3R/memory/backlog.md" "$T3R/memory/backlog-done.md" "$T3R" "$3" "$4" "$5" \
    >"$T3/ov.out" 2>&1
  local m n; m="$(sed -n 's/^MODE=//p' "$T3/ov.out" | head -1)"; n="$(sed -n 's/^NREJ=//p' "$T3/ov.out" | head -1)"
  if [ "$m" = "$2" ] && [ "${n:-1}" = "0" ]; then ok "(Cc) $1 (mode=$m, accepted)"
  else no "(Cc) $1: mode=$m rejections=${n:-?} (wanted mode=$2 and 0): $(grep '^REJ=' "$T3/ov.out" | head -1)"; fi
}
c3_mode "the \`full\` mode accepts basename equality plus >=2 words in the window" full \
  "src/loader.ts the handle is never released on retry" STILL-REAL \
  "src/loader.ts:3 the handle is never released on the retry path"
c3_mode "the \`words-only\` mode runs the words half when the entry names no path at all — 338 of this repo's 494 entries" words-only \
  "the retry budget has no ceiling anywhere in here" STILL-REAL \
  "src/loader.ts:7 the retry budget has no ceiling anywhere in here"
c3_mode "the \`archive-proof\` mode accepts a STALE-FIXED citing backlog-done.md, the second shape the include's table permits" archive-proof \
  "src/loader.ts the tenant was missing from the cache key" STALE-FIXED \
  "backlog-done.md:5 section=\"Archived\" records the closure"
c3_mode "a signature with fewer than 2 content words is \`n/a\`, because '>=2 of 8' is unsatisfiable rather than failed — 20 of the 494" "n/a:signature-too-short" \
  "src/lone.ts a" STILL-REAL "src/loader.ts:3 whatever"
c3_mode "a verdict outside (c)'s scope is \`n/a:out-of-scope\`, so STALE-OBSOLETE is never asked to match a backlog basename against a missing path's" "n/a:out-of-scope" \
  "src/loader.ts the handle is never released on retry" STALE-OBSOLETE \
  "backlog.md:5 \"src/gone.ts\" does not exist"
# A STILL-REAL citing the archive is NOT archive-proof: the verdict means the defect is in the tree
# today, so the archive cannot be what shows it.
probe3 "$CTL2" overlap "$T3R/memory/backlog.md" "$T3R/memory/backlog-done.md" "$T3R" \
  "src/loader.ts the handle is never released on retry" STILL-REAL \
  "backlog-done.md:5 section=\"Archived\" says so" >"$T3/ov-sr.out" 2>&1
[ "$(sed -n 's/^NREJ=//p' "$T3/ov-sr.out" | head -1)" != "0" ] \
  && ok "(Cc6) a STILL-REAL citing backlog-done.md is still an OVERLAP rejection — the archive-proof shape belongs to STALE-FIXED alone" \
  || no "(Cc6) a STILL-REAL row was allowed to prove itself from the archive"
# (c)'s LIMIT, asserted rather than only documented: a WRONG verdict on a CORRECT citation passes.
probe3 "$CTL2" overlap "$T3R/memory/backlog.md" "$T3R/memory/backlog-done.md" "$T3R" \
  "src/loader.ts the handle is never released on retry" STALE-FIXED \
  "src/loader.ts:3 the handle is never released on the retry path" >"$T3/ov-lim.out" 2>&1
[ "$(sed -n 's/^NREJ=//p' "$T3/ov-lim.out" | head -1)" = "0" ] \
  && ok "(Cc7) (c) PASSES a STALE-FIXED verdict whose citation is the line proving the defect is still there — the control catches FABRICATION, not MISJUDGEMENT, and this is that sentence as an assertion rather than as prose" \
  || no "(Cc7) (c) rejected the mis-judged-but-correctly-cited row, which would mean this file is claiming more for (c) than the include does"

# ==================================================================================================
# D — CONTROL (d), the seeded known-answers: the ONLY control that measures judgement, and the only one
# whose failure has to re-dispatch a whole chunk.
# ==================================================================================================
echo "-- D: control (d), seeded known-answers --"
ing3 seedfixed
grep -q '^REJECT=SEED-MISS|fp:ffff.*answered STILL-REAL where the repo records STALE-FIXED' "$T3/ing-seedfixed.out" \
  && ok "(D1) a provably-FIXED seed answered STILL-REAL is a SEED-MISS — the direction that keeps dead entries alive for ever" \
  || no "(D1) the STALE-FIXED->STILL-REAL miss was not caught: $(grep '^REJECT=' "$T3/ing-seedfixed.out" | head -2)"
ing3 seedreal
grep -q '^REJECT=SEED-MISS|fp:ffff.*answered STALE-FIXED where the repo records STILL-REAL' "$T3/ing-seedreal.out" \
  && ok "(D2) a provably-STILL-REAL seed answered STALE-FIXED is a SEED-MISS — the direction that closes live ones. BOTH directions, because a one-sided check rewards a one-sided bias" \
  || no "(D2) the STILL-REAL->STALE-FIXED miss was not caught: $(grep '^REJECT=' "$T3/ing-seedreal.out" | head -2)"
for f in seedfixed seedreal; do
  [ "$(iv $f NACCEPTED)" = "0" ] \
    && ok "(D3) the '$f' chunk writes ZERO rows — a seed miss re-dispatches the CHUNK, it does not discount one row" \
    || no "(D3) $(iv $f NACCEPTED) row(s) survived a seed miss"
done
# An UNANSWERED seed is a miss too: a verifier that skipped the rows it could not place would otherwise
# escape (d) entirely while conservation reported only the count.
D_NOSEED="$T3/resp-noseed.jsonl"
python3 - "$T3/resp-clean.jsonl" "$ANS" > "$D_NOSEED" <<'PYEOF'
import json, sys
ans = json.load(open(sys.argv[2], encoding="utf-8"))
for l in open(sys.argv[1], encoding="utf-8"):
    r = json.loads(l)
    if r["key"] in ans and r["verdict"] == "STALE-FIXED":
        continue
    print(json.dumps(r, sort_keys=True))
PYEOF
probe3 "$CTL2" ingest "$DISP" "$D_NOSEED" "$ANS" "$T3R/memory/backlog.md" \
  "$T3R/memory/backlog-done.md" "$T3R" >"$T3/ing-noseed.out" 2>&1
grep -q '^REJECT=SEED-MISS|.*not answered at all' "$T3/ing-noseed.out" \
  && ok "(D4) a seed left UNANSWERED is a SEED-MISS in its own right, not only a conservation failure" \
  || no "(D4) an unanswered seed produced no SEED-MISS: $(grep '^REJECT=' "$T3/ing-noseed.out" | cut -d'|' -f1 | sort -u | tr '\n' ' ')"
# The seed derivation itself, censused: K, the 2/2 split, and the shortfall refusal.
probe3 "$CTL2" seeds "$T3R" "$T3R/memory/backlog-done.md" 4 >"$T3/seeds.out" 2>&1
cat "$T3/seeds.out"
sd(){ sed -n "s/^$1=//p" "$T3/seeds.out" | head -1; }
[ "$(sd NSEEDS)" = "4" ] && [ "$(sd SHORT)" = "-" ] \
  && ok "(D5) the derivation yields K=4 seeds from $(sd NARCH) archived entries and $(sd NLIVE) live anchors, with no shortfall" \
  || no "(D5) the derivation yields $(sd NSEEDS) seed(s), shortfall='$(sd SHORT)'"
probe3 "$CTL2" seeds "$T3R" "$T3R/memory/backlog-done.md" 8 >"$T3/seeds8.out" 2>&1
[ "$(sed -n 's/^SHORT=//p' "$T3/seeds8.out" | head -1)" != "-" ] \
  && ok "(D6) asking for more seeds than the repo can derive reports a SHORTFALL rather than silently returning fewer — a chunk with fewer seeds is an UNGATED chunk that reads identically to a gated one" \
  || no "(D6) a K the fixture cannot satisfy returned no shortfall: $(cat "$T3/seeds8.out" | tr '\n' ' ')"
# …and the shortfall REFUSES at the command, which is where it costs something.
D_NOARCH="$T3/repo-noarch"
mkdir -p "$D_NOARCH/memory"
cp "$T3R/memory/backlog.md" "$D_NOARCH/memory/backlog.md"
: > "$D_NOARCH/memory/backlog-done.md"
cp "$T3R/.gitignore" "$D_NOARCH/.gitignore"
mkdir -p "$D_NOARCH/docs" && cp "$T3R/docs/one.md" "$T3R/docs/two.md" "$D_NOARCH/docs/"
( cd "$D_NOARCH" && git init -q . >/dev/null 2>&1 && git add -A >/dev/null 2>&1 \
  && git -c user.email=t@t -c user.name=t commit -qm noarch >/dev/null 2>&1 ) \
  || no "(D7) could not build the archive-less repo"
groom3 plan --repo "$D_NOARCH" >"$T3/noarch-plan.out" 2>&1
groom3 dispatch --repo "$D_NOARCH" --chunk 0 >"$T3/noarch-disp.out" 2>&1; D_RC=$?
[ "$D_RC" -ne 0 ] && grep -q 'SEED-SHORTFALL' "$T3/noarch-disp.out" \
  && ok "(D7) a repo with NO recorded closures cannot self-seed, and dispatch REFUSES (rc=$D_RC, SEED-SHORTFALL) instead of sending an ungated chunk" \
  || no "(D7) dispatch exited $D_RC on a repo with an empty archive: $(tail -2 "$T3/noarch-disp.out")"
[ ! -f "$D_NOARCH/zuvo/context/backlog-dispatch-0.jsonl" ] \
  && ok "(D7b) …and it wrote no dispatch file, so nothing downstream can consume an ungated chunk" \
  || no "(D7b) a dispatch file was written despite the shortfall refusal"
# A seed key can never collide with a real entry's fp: key.
grep -q '^SEED=fp:ffff' "$T3/seeds.out" \
  && ok "(D8) seed keys are fp:ffff-prefixed, which no real sha1[:12] can produce as its first four nibbles by construction of the prefix — a colliding seed would put a synthetic verdict on a real row" \
  || no "(D8) the seed keys are not fp:ffff-prefixed: $(grep '^SEED=' "$T3/seeds.out" | head -1)"
# An UNREADABLE answer key must refuse, not read as "no seeds".
cp "$ANS" "$T3/ans-broken.json" && printf 'not json' > "$T3/ans-broken.json"
groom3 ingest --repo "$T3R" --dispatch "$DISP" --response "$T3/resp-clean.jsonl" \
  --answers "$T3/ans-broken.json" --dry-run >"$T3/ans-broken.out" 2>&1; D_AB=$?
[ "$D_AB" -ne 0 ] \
  && ok "(D9) an UNREADABLE seed answer key is a refusal (rc=$D_AB), not an empty one — an empty key would make (d) pass every chunk while reporting that it ran" \
  || no "(D9) ingest accepted a corrupt answer key: $(tail -1 "$T3/ans-broken.out")"

# ==================================================================================================
# L — THE LEDGER SIDE, asserted in BYTES. "Nothing was appended" is the claim, and the absence of one
# particular row is not that claim.
# ==================================================================================================
echo "-- L: the ledger, in bytes --"
LED3="$T3R/memory/backlog-verdicts.jsonl"
L_B0="$(bytes2 "$LED3")"
groom3 ingest --repo "$T3R" --dispatch "$DISP" --response "$T3/resp-ac6.jsonl" >"$T3/cli-ac6.out" 2>&1
L_AC6_RC=$?
L_B1="$(bytes2 "$LED3")"
[ "$L_B1" = "$L_B0" ] \
  && ok "(L1/AC6) the AC6 response appended ZERO BYTES ($L_B0 -> $L_B1) — asserted on the byte count, because 'no row for B-t3-beta' would also be true of a ledger that grew by two other rows" \
  || no "(L1/AC6) the ledger moved $L_B0 -> $L_B1 bytes on a response that failed three controls"
[ "$L_AC6_RC" -ne 0 ] \
  && ok "(L1b/AC6) …and the command exited $L_AC6_RC, outside {0,1,2,10,11,12}, so a caller can tell a refusal from a lookup answer" \
  || no "(L1b/AC6) the AC6 ingest exited 0"
L_AC6_CODES="$(grep '^REJECT=' "$T3/cli-ac6.out" | sed 's/^REJECT=\([A-Z-]*\) .*/\1/' | sort -u | tr '\n' ',')"
case "$L_AC6_CODES" in
  *KEYSET*) : ;; *) no "(L2/AC6) no KEYSET rejection for the omitted row; codes were $L_AC6_CODES" ;;
esac
case "$L_AC6_CODES" in
  *MULTIPLICITY*) : ;; *) no "(L2/AC6) no MULTIPLICITY rejection for the merged pair; codes were $L_AC6_CODES" ;;
esac
case "$L_AC6_CODES" in
  *UNRESOLVABLE*) : ;; *) no "(L2/AC6) no UNRESOLVABLE rejection for the fabricated citation; codes were $L_AC6_CODES" ;;
esac
case "$L_AC6_CODES" in
  *KEYSET*) case "$L_AC6_CODES" in *MULTIPLICITY*) case "$L_AC6_CODES" in *UNRESOLVABLE*)
    ok "(L2/AC6) three DISTINCT rejection classes from one response — KEYSET (omitted), MULTIPLICITY (merged) and UNRESOLVABLE (fabricated), codes=$L_AC6_CODES" ;; esac ;; esac ;;
esac
# Every rejection NAMES its offending id, which is what makes a 25 KB chunk triageable.
L_NAMED="$(grep -c '^REJECT=[A-Z-]* \(B-t3-\|id:b-t3-\|fp:\)' "$T3/cli-ac6.out")"
L_TOTAL="$(grep -c '^REJECT=' "$T3/cli-ac6.out")"
[ "${L_NAMED:-0}" -ge 3 ] && [ "$L_NAMED" = "$L_TOTAL" ] \
  && ok "(L3/AC6) all $L_TOTAL rejections name the offending id or key — a reader can find the row in the dispatch instead of diffing two lists" \
  || no "(L3/AC6) only $L_NAMED of $L_TOTAL rejections name a subject: $(grep '^REJECT=' "$T3/cli-ac6.out" | head -2)"
# THE POSITIVE HALF: a clean response really does append, so L1's zero is a zero and not a ledger that
# never grows.
groom3 ingest --repo "$T3R" --dispatch "$DISP" --response "$T3/resp-clean.jsonl" >"$T3/cli-clean.out" 2>&1
L_CLEAN_RC=$?
L_B2="$(bytes2 "$LED3")"
if [ "$L_CLEAN_RC" -eq 0 ] && [ "$L_B2" -gt "$L_B1" ]; then
  ok "(L4) the CLEAN response appends ($L_B1 -> $L_B2 bytes, rc=0) — without this, L1's 'zero bytes' would be a statement about a ledger nothing can write to"
else
  no "(L4) the clean ingest exited $L_CLEAN_RC with $L_B1 -> $L_B2 bytes: $(tail -2 "$T3/cli-clean.out")"
fi
L_ROWS="$(grep -c . "$LED3" 2>/dev/null || echo 0)"
[ "$L_ROWS" = "3" ] \
  && ok "(L5) the ledger holds exactly 3 rows for 7 dispatched rows — the 4 seeds are never written, because a seed is not an entry" \
  || no "(L5) the ledger holds $L_ROWS row(s), expected 3"
grep -q 'fp:ffff' "$LED3" \
  && no "(L6) a SEED reached the ledger — that is a verdict about text backlog.md does not contain" \
  || ok "(L6) no fp:ffff key is anywhere in the ledger"
# And the ledger the lane wrote READS BACK through the ledger's own reader, with no defects: a lane that
# wrote rows its reader rejects would report success and leave every entry unverified.
L_READ="$(probe "$CTL" read "$LED3" 2>&1)"
printf '%s\n' "$L_READ" | grep -qx 'ROWS=3' && ! printf '%s\n' "$L_READ" | grep -q '^DEFECT=' \
  && ok "(L7) read_ledger reads all 3 lane rows with zero defects — the lane's output is readable by the reader that decides coverage" \
  || no "(L7) the lane's rows do not read back cleanly: $(printf '%s\n' "$L_READ" | head -3 | tr '\n' ' ')"

# ==================================================================================================
# G — THE AGENT FILE. Three traps live here, and all three are silent: a Claude-Code-only tool name
# fails the CODEX BUILD (which validate-skills.sh does not check), a duplicate agent BASENAME silently
# collides in the Cursor and Kimi builds (both install agents FLAT with skill-prefixed names), and a
# wrong-depth include is the one thing validate-skills.sh does catch.
# ==================================================================================================
echo "-- G: skills/backlog/agents/backlog-verifier.md --"
g_has(){ grep -qF -- "$2" "$AGENT_MD" && ok "(G) $1" || no "(G) $1 — '$2' is absent from the agent file"; }
g_hasnt(){ grep -qF -- "$2" "$AGENT_MD" && no "(G) $1 — '$2' is PRESENT" || ok "(G) $1"; }
head -1 "$AGENT_MD" | grep -qx -- '---' \
  && ok "(G1) the agent file opens with YAML frontmatter, as skills/infra-audit/agents/*.md do" \
  || no "(G1) the agent file does not open with '---'"
for k in name: description: model: tools:; do
  sed -n '2,12p' "$AGENT_MD" | grep -q "^$k" \
    && ok "(G1b) frontmatter carries $k" \
    || no "(G1b) frontmatter is missing $k — the infra-audit shape the task prescribes has all four"
done
sed -n '2,12p' "$AGENT_MD" | grep -q '^name: backlog-verifier$' \
  && ok "(G1c) the frontmatter name is exactly backlog-verifier" \
  || no "(G1c) the frontmatter name is not backlog-verifier: $(sed -n '2,4p' "$AGENT_MD" | tr '\n' ' ')"
# READ-ONLY BY TOOL LIST, not only by prose. Bash is excluded deliberately: `Bash` can write, and the
# infra-audit analysts have it only because their input is a JSON bundle they must `jq`.
G_TOOLS="$(awk '/^tools:/{f=1;next} f&&/^  - /{print $2} f&&!/^  - /{exit}' "$AGENT_MD" | tr '\n' ' ')"
echo "  ... declared tools: $G_TOOLS"
# Two explicit tests rather than one `case`: `*MultiEdit*` and `*NotebookEdit*` are subsumed by
# `*Edit*`, which shellcheck flags (SC2221/SC2222) and is right to — the alternation read as five
# patterns while only one could ever match. Asking the two questions separately also makes "grants no
# Read at all" reachable, which the fall-through arm was not, and it matches WHOLE tool names rather
# than substrings.
G_WRITEABLE="$(printf '%s\n' "$G_TOOLS" | tr ' ' '\n' \
               | grep -xE 'Edit|MultiEdit|NotebookEdit|Write|Bash|KillShell|BashOutput' | tr '\n' ' ')"
[ -z "$G_WRITEABLE" ] \
  && ok "(G2) the tool list grants no write-capable tool: $G_TOOLS" \
  || no "(G2) the tool list grants write-capable tool(s) [$G_WRITEABLE] — this lane is read-only by contract, and a disposition it wrote itself would bypass the gate that exists to stop exactly that"
printf '%s\n' "$G_TOOLS" | tr ' ' '\n' | grep -qx Read \
  && ok "(G2b) …and it does grant Read, so G2 is not passing by granting nothing at all" \
  || no "(G2b) the tool list does not even grant Read: $G_TOOLS"
# THE CODEX BUILD GATE, run here because validate-skills.sh does not check it and the build only fails
# at install time. The list is build-codex-skills.sh's own.
G_CODEX="$(grep -oE 'TaskCreate|TaskUpdate|TaskList|EnterPlanMode|ExitPlanMode|AskUserQuestion|run_in_background|TeamCreate|SendMessage' "$AGENT_MD" | sort -u | tr '\n' ' ')"
[ -z "$G_CODEX" ] \
  && ok "(G3) the agent file names no Claude-Code-only tool — build-codex-skills.sh's validation list is clean on it, and that build is the one validate-skills.sh cannot speak for" \
  || no "(G3) the agent file names Claude-Code-only tool(s): $G_CODEX — the Codex build FAILS on these"
# A DUPLICATE BASENAME collides silently: the Cursor and Kimi builds install agents FLAT.
G_DUP="$(find "$ROOT/skills" -path '*/agents/backlog-verifier.md' | wc -l | tr -d ' ')"
[ "$G_DUP" = "1" ] \
  && ok "(G4) backlog-verifier.md is the only agent file with that basename — the Cursor and Kimi builds install agents FLAT, so a second one would silently overwrite this" \
  || no "(G4) $G_DUP agent files are named backlog-verifier.md; a flat install keeps whichever lands last"
# The include depth validate-skills.sh enforces for agents/.
# EVERY reference, then its DEPTH — because `../../../shared/...` CONTAINS `../../shared/...` as a
# substring, so a grep for the wrong form matched the correct one and reported a defect that was not
# there. Measured on the first run: it failed on the two includes this file gets right.
G_BADDEPTH="$(grep -oE '(\.\./)+shared/includes/[a-z0-9-]+\.md' "$AGENT_MD" | sort -u \
              | grep -v '^\.\./\.\./\.\./' | tr '\n' ' ')"
[ -z "$G_BADDEPTH" ] \
  && ok "(G5) every include reference is ../../../ deep — agents/ sits three levels below skills/, and the two-level form is what validate-skills.sh fails on" \
  || no "(G5) wrong-depth include(s): $G_BADDEPTH"
grep -qF '../../../shared/includes/backlog-grooming.md' "$AGENT_MD" \
  && ok "(G5b) the agent is told to load backlog-grooming.md, which is where the vocabulary and the controls are defined" \
  || no "(G5b) the agent file does not load the grooming include, so its verdict vocabulary would be prose it was told once"
# THE INCENTIVE DESIGN. This is the wording requirement, not a nicety: a verifier under pressure to look
# thorough guesses STILL-REAL, and a guessed STILL-REAL is invisible.
g_has "(G6) NOT-VERIFIABLE is stated as cheap AND legitimate" 'cheap, legitimate'
g_has "(G6b) …with no quota and no score attached to it" 'no quota, no score'
g_has "(G6c) …and 'when you are unsure, NOT-VERIFIABLE is the correct answer' in as many words" 'the correct answer, not the cautious one'
g_has "(G6d) …and the failure it prevents is named: a guessed STILL-REAL keeps a dead entry alive" 'guessed `STILL-REAL`'
g_has "(G7) omission is an agent FAILURE, stated to the agent" 'Never two, never none'
g_has "(G7b) merging two rows is forbidden, stated to the agent" 'Never merge two rows'
g_has "(G8) the agent is told a chunk is ALL-OR-NOTHING, so a shape slip on a boring row is not free" 'all-or-nothing'
g_has "(G9) the agent is told (a)-(c) cannot tell whether its verdict is right" 'cannot'
g_has "(G9b) …and forbidden from reporting its own output as verified" 'verified, cross-checked or confirmed'
G_VMISS=""
for v in STILL-REAL STALE-FIXED STALE-OBSOLETE DUPLICATE-OF NOT-VERIFIABLE; do
  grep -qF "$v" "$AGENT_MD" || G_VMISS="$G_VMISS $v"
done
[ -z "$G_VMISS" ] \
  && ok "(G10) all five verdicts appear in the agent file" \
  || no "(G10) the agent file never names:$G_VMISS"
g_hasnt "(G11) the agent file claims no Edit/Write capability in prose either" 'you may edit'
# THE DEFECT THIS ASSERTION EXISTS FOR, found by `tests/run-all.sh` and by nothing else in Task 3's own
# Verify list. `scripts/build-kimi-skills.sh` refuses a skill that SHIPS an `agents/` directory whose
# dist SKILL.md has no reference to it: with `src_refs == 0` it falls back to a prose marker
# (`dispatch`/`Agent tool`) and fails when neither is there. `skills/backlog/SKILL.md` had no agent
# language at all, because the backlog skill had never had an agent — so adding one broke the Kimi
# build, `validate-skills.sh` stayed green (it does not check this), and the only signal was a build
# the runbook tells you not to trust on the farm. The FIX is the stronger branch: SKILL.md names
# `agents/backlog-verifier.md`, so the build verifies the rewritten reference points at a file it
# really built rather than merely finding the word "dispatch".
BACKLOG_SKILL="$ROOT/skills/backlog/SKILL.md"
[ -f "$BACKLOG_SKILL" ] || no "(G12) skills/backlog/SKILL.md is missing"
grep -qF 'agents/backlog-verifier.md' "$BACKLOG_SKILL" \
  && ok "(G12) skills/backlog/SKILL.md REFERENCES agents/backlog-verifier.md — build-kimi-skills.sh refuses a skill that ships agents/ with no reference to it, and takes the stronger 'the rewritten reference resolves to a built file' branch when one is present" \
  || no "(G12) skills/backlog/SKILL.md does not name agents/backlog-verifier.md — build-kimi-skills.sh fails with 'ships agents/ but dist SKILL.md has no dispatch language left', and validate-skills.sh does NOT catch it"
# THE SECOND DEFECT THE SAME ONE-LINE ADDITION CAUSED, and it is the more interesting of the two.
# `tests/skill-suite/test-gate-dispatch-authorization.sh` (b) derives "every skill that mandates ANY
# delegation" FROM THE TREE, so the moment skills/backlog/SKILL.md named an agent file the backlog skill
# joined that class — and it did not carry the authorization rule. Its own header records why that
# matters twice over: without the rule an agent reaches the gate having never read the paragraph that
# authorizes dispatch, applies a session-level "do not spawn agents" policy, decides the rows inline and
# reports the gate as satisfied by the very substitution it forbids. Asserted HERE as well as there,
# because this is the file that owns the lane.
grep -qF 'execution-policy.md' "$BACKLOG_SKILL" \
  && ok "(G13) skills/backlog/SKILL.md carries the dispatch-authorization rule — a delegating skill without it is one an agent may replace with an inline pass while reporting the gate as met" \
  || no "(G13) skills/backlog/SKILL.md names an agent but carries no execution-policy.md reference; test-gate-dispatch-authorization.sh (b) fails on it, and an agent that reaches the lane under a no-subagents session policy will decide the rows itself"
grep -qiE 'not a substitute|NOT a substitute' "$BACKLOG_SKILL" \
  && ok "(G13b) …and it says plainly that inline verification is not a substitute for the lane, with the reason (no agent: provenance, controls bypassed while reported as run)" \
  || no "(G13b) the skill authorizes dispatch but never forbids the inline substitute, which is the half that shipped the 2026-08-07/08 field failures"
G_SKILLREF="$(grep -coE '(\.\./)*agents/backlog-verifier\.md' "$BACKLOG_SKILL")"
[ "${G_SKILLREF:-0}" -ge 1 ] \
  && ok "(G12b) the reference is in the agents/<name>.md shape the build greps for ($G_SKILLREF occurrence(s)), not a prose mention of the lane" \
  || no "(G12b) no agents/<name>.md-shaped reference in skills/backlog/SKILL.md"

# ==================================================================================================
# I3 — THE INCLUDE. The additions, and one DELETION: the mint premise revision 6/7 measured FALSE was
# still asserted in the shipped include, which is the copy skills actually load.
# ==================================================================================================
echo "-- I3: backlog-grooming.md, the Task 3 additions and one correction --"
i3(){ grep -qF -- "$2" "$INCLUDE" && ok "(I3) $1" || no "(I3) $1 — '$2' is absent from the include"; }
i3 "the include names the verifier lane's agent file" 'skills/backlog/agents/backlog-verifier.md'
i3 "(c)'s word-SET comparison is documented, not its first substring version" 'compared as WORD SETS'
i3 "…and so is the stop-word limit that survives the fix" 'not a similarity score'
i3 "…and the concrete response shape" '{key, verdict, evidence}'
i3 "(c)'s honest limit is still stated verbatim" 'fabrication, not misjudgement'
i3 "the honest note on conservation check 3 is present, rather than claiming independence" 'cannot fail while (1) and (2) both hold'
i3 "the NOT-VERIFIABLE exemption is documented as living in the CODE" 'exempt from (b) and (c) in the CODE'
i3 "the seed shortfall is documented as a refusal, never a smaller K" 'never a smaller K'
i3 "the seeds' indistinguishability is documented" 'indistinguishable or they gate nothing'
i3 "the all-or-nothing append is documented with the byte-count assertion it implies" 'byte count'
i3 "DISPATCH-AMBIGUOUS is documented as a pre-dispatch refusal" 'DISPATCH-AMBIGUOUS'
I3_CMISS=""
# PREFIX match, no closing backtick: the include writes the fourth mode as `n/a:…` — the ellipsis sits
# INSIDE the backticks, so a closed `\`n/a:\`` can never match it. The first version of this loop failed
# on a mode the include documents.
for m in full words-only archive-proof 'n/a:'; do
  grep -qF "\`$m" "$INCLUDE" || I3_CMISS="$I3_CMISS $m"
done
[ -z "$I3_CMISS" ] \
  && ok "(I3) all four (c) modes are named in the include, so a pass rate cannot be quoted without its denominator" \
  || no "(I3) the include does not name (c) mode(s):$I3_CMISS"
I3_RMISS=""
for c in COUNT KEYSET MULTIPLICITY UNKNOWN-KEY SHAPE UNRESOLVABLE OVERLAP SEED-MISS \
         DISPATCH-AMBIGUOUS SEED-SHORTFALL; do
  grep -qF "\`$c\`" "$INCLUDE" || I3_RMISS="$I3_RMISS $c"
done
[ -z "$I3_RMISS" ] \
  && ok "(I3b) all ten ingest rejection codes are documented — a caller greps them to decide whether to re-dispatch" \
  || no "(I3b) the include does not document rejection code(s):$I3_RMISS"
# THE DELETION. Plan revision 6/7 measured the premise false; the shipped include still asserted it.
grep -qF 'a content-keyed entry cannot carry a stable verdict until it has an id' "$INCLUDE" \
  && no "(I3c) the include still asserts that a content-keyed entry cannot carry a stable verdict until it has an id. Plan revision 6/7 MEASURED that false — keys_for gives such an entry an fp: key, _KEY_RE accepts it, and plan_reuse keys on (key, text_sha). The include is the copy skills load, so the stale premise there outranks the corrected one in the plan" \
  || ok "(I3c) the refuted mint premise is GONE from the include and replaced by the measured cost table — the runtime copy agrees with the measurement"
i3 "…and the correction states the fp: key is first-class" '`keys_for` gives such an entry a first-class'
# The chunking numbers, which disagreed with Task 2's own module docstring by 2x on two of the four.
i3 "the chunking numbers match the measurement (494 entries)" '494 entries'
i3 "…the biggest section's real byte size" '117 entries in 13 KB'
i3 "…and the real largest single entry" '17.7 KB'
grep -qF '220 KB over ~387 entries' "$INCLUDE" \
  && no "(I3d) the include still quotes '220 KB over ~387 entries', which disagrees with zuvo_backlog_queue.py's own measured docstring" \
  || ok "(I3d) the superseded 220 KB / 387 entries figure is gone"
# The +/-5 WINDOW is what the tolerance buys, asserted as a pass at distance 4 and a rejection at
# distance 6. An exact-line assert would reject CORRECT evidence — a true line number drifts with every
# edit above it — and a window of 0 would make every such row a fabrication.
probe3 "$CTL2" overlap "$T3R/memory/backlog.md" "$T3R/memory/backlog-done.md" "$T3R" \
  "src/loader.ts the handle is never released on retry" STILL-REAL \
  "src/loader.ts:7 the handle is never released on the retry path" >"$T3/ov-near.out" 2>&1
# :7 is a BLANK line four below the words, so the pass depends on the window and on nothing else — at
# WINDOW=0 the same citation sees an empty haystack, which is what makes the window0 mutant attributable.
[ "$(sed -n 's/^NREJ=//p' "$T3/ov-near.out" | head -1)" = "0" ] \
  && ok "(Cc8) a citation FOUR lines off the signature words is accepted — the +/-5 tolerance is what stops (c) rejecting correct evidence whose line number drifted" \
  || no "(Cc8) a citation four lines off was rejected: $(grep '^REJ=' "$T3/ov-near.out" | head -1)"

# ==================================================================================================
# MU3 — every Task 3 assertion dies under a mutant that reverts only its behaviour. The helpers are the
# Task 2 ones (mu_gone / mu_new / mut2_build), because the factory and the mutant directory are shared;
# the probe differs, so the two probe-driven helpers are re-expressed for probe3 here.
# ==================================================================================================
echo "-- MU3: each Task 3 assertion is load-bearing --"
mu3_gone(){  # kind, label, ERE that must VANISH, probe3 args...
  local kind="$1" lbl="$2" pat="$3" out
  if ! mut2_build "$kind"; then mut2_failed "$kind"; return; fi
  shift 3
  out="$(probe3 "$T2/mut-$kind" "$@" 2>&1)"
  if printf '%s\n' "$out" | grep -qE -- "$pat"; then
    no "(MU3) $lbl: the mutant still produced /$pat/ — the assertion is decorative"
  else
    ok "(MU3) $lbl: /$pat/ is gone under the mutant — the assertion is load-bearing"
  fi
}
mu3_new(){   # kind, label, ERE that must APPEAR only under the mutant, probe3 args...
  local kind="$1" lbl="$2" pat="$3" out
  if ! mut2_build "$kind"; then mut2_failed "$kind"; return; fi
  shift 3
  out="$(probe3 "$T2/mut-$kind" "$@" 2>&1)"
  if printf '%s\n' "$out" | grep -qE -- "$pat"; then
    ok "(MU3) $lbl: the mutant produces /$pat/ where the control does not — the assertion is load-bearing"
  else
    no "(MU3) $lbl: the mutant produced no /$pat/, so the control's clean result is not attributable to this code"
  fi
}
# ARGUMENT ARRAYS, not command substitutions. The first version built these with `echo` and relied on
# the caller leaving the substitution UNQUOTED so the shell would split it back into arguments: 17
# SC2046 warnings, and the same break H19c's own comment describes — the fixture root is a mktemp path,
# so "today it has no space" is exactly the reasoning that makes such a failure expensive to find
# later. One array per flavour rather than one helper, because several call sites are CONTINUATION
# lines and nothing can set an array from inside an argument list.
OVL=( "$T3R/memory/backlog.md" "$T3R/memory/backlog-done.md" "$T3R" )
ING_BADVERDICT=( "$DISP" "$T3/resp-badverdict.jsonl" "$ANS" "${OVL[@]}" )
ING_CLEAN=( "$DISP" "$T3/resp-clean.jsonl" "$ANS" "${OVL[@]}" )
ING_EXTRA=( "$DISP" "$T3/resp-extra.jsonl" "$ANS" "${OVL[@]}" )
ING_FABRICATED=( "$DISP" "$T3/resp-fabricated.jsonl" "$ANS" "${OVL[@]}" )
ING_MERGED=( "$DISP" "$T3/resp-merged.jsonl" "$ANS" "${OVL[@]}" )
ING_NOWORDS=( "$DISP" "$T3/resp-nowords.jsonl" "$ANS" "${OVL[@]}" )
ING_OMIT=( "$DISP" "$T3/resp-omit.jsonl" "$ANS" "${OVL[@]}" )
ING_SEEDFIXED=( "$DISP" "$T3/resp-seedfixed.jsonl" "$ANS" "${OVL[@]}" )
ING_TWOLINE=( "$DISP" "$T3/resp-twoline.jsonl" "$ANS" "${OVL[@]}" )
ING_WRONGFILE=( "$DISP" "$T3/resp-wrongfile.jsonl" "$ANS" "${OVL[@]}" )

# --- conservation, one mutant per check ------------------------------------------------------------
mu3_gone nocount    "C5 the count check"          '^REJECT=COUNT\|'          ingest "${ING_OMIT[@]}"
mu3_gone nokeyset   "C1 the omitted-row check"    '^REJECT=KEYSET\|'         ingest "${ING_OMIT[@]}"
mu3_gone nomulti    "C3 the merged-pair check"    '^REJECT=MULTIPLICITY\|'   ingest "${ING_MERGED[@]}"
mu3_gone nounknown  "C2 the unknown-key check"    '^REJECT=UNKNOWN-KEY\|'    ingest "${ING_EXTRA[@]}"
mu3_gone noambig    "C6 the ambiguous-dispatch refusal" '^REJECT=DISPATCH-AMBIGUOUS\|' \
                    conserve "$AMBIG" "$T3/resp-clean.jsonl"
# --- control (a) -----------------------------------------------------------------------------------
mu3_gone noshape    "A1/A2 the ledger validator inside (a)" '^REJECT=SHAPE\|' ingest "${ING_BADVERDICT[@]}"
mu3_gone multiline  "A3 the one-evidence-line rule" '^REJECT=SHAPE\|.*spans 2 lines' \
                    ingest "${ING_TWOLINE[@]}"
# --- control (b), and the exemption in the other direction ----------------------------------------
mu3_gone noresolve  "B1 resolvability"            '^REJECT=UNRESOLVABLE\|'   ingest "${ING_FABRICATED[@]}"
mu3_new  nvstrict   "B2 the NOT-VERIFIABLE exemption" '^REJ=UNRESOLVABLE\|' \
                    resolve "${OVL[@]}" "NOT-VERIFIABLE" "the repo does not answer this and there is nothing to cite"
# --- control (c), one mutant per half and one per mode ---------------------------------------------
mu3_gone nobasename "Cc1 basename equality"       '^REJECT=OVERLAP\|.*basenames differ' \
                    ingest "${ING_WRONGFILE[@]}"
mu3_gone nowordshalf "Cc2 the >=2-words half"     '^REJECT=OVERLAP\|.*signature word' \
                    ingest "${ING_NOWORDS[@]}"
mu3_new  window0    "Cc8 the +/-5 window"         '^REJ=OVERLAP\|' \
                    overlap "${OVL[@]}" "src/loader.ts the handle is never released on retry" STILL-REAL \
                    "src/loader.ts:7 the handle is never released on the retry path"
mu3_new  shortstrict "Cc4 the too-short signature is n/a, not a rejection" '^REJ=OVERLAP\|' \
                    overlap "${OVL[@]}" "src/lone.ts a" STILL-REAL "src/loader.ts:3 whatever"
mu3_new  noarchiveproof "Cc3 the archive-proof mode" '^REJ=OVERLAP\|' \
                    overlap "${OVL[@]}" "src/loader.ts the tenant was missing from the cache key" \
                    STALE-FIXED "backlog-done.md:5 section=\"Archived\" records the closure"
mu3_new  cscopeopen "Cc5 (c)'s verdict scope"      '^REJ=OVERLAP\|' \
                    overlap "${OVL[@]}" "src/loader.ts the handle is never released on retry" \
                    STALE-OBSOLETE "backlog.md:5 \"src/gone.ts\" does not exist"
# --- control (d) -----------------------------------------------------------------------------------
mu3_gone noseedcheck "D1/D2 the seed comparison"  '^REJECT=SEED-MISS\|'      ingest "${ING_SEEDFIXED[@]}"
mu3_gone seedmissing "D4 the unanswered seed"     '^REJECT=SEED-MISS\|.*not answered at all' \
                     ingest "$DISP" "$D_NOSEED" "$ANS" "$T3R/memory/backlog.md" \
                     "$T3R/memory/backlog-done.md" "$T3R"
mu3_new  nostrip     "W9 the marker stripping"    '^SEED=.*FIXED [0-9a-f]{7}' \
                     seeds "$T3R" "$T3R/memory/backlog-done.md" 4
mu3_gone shortopen   "D6 the shortfall report"    '^SHORT=[^-]' \
                     seeds "$T3R" "$T3R/memory/backlog-done.md" 8
# The interleave, read off the ORDER: sorted by key, all four seeds land in one contiguous block.
if mut2_build sortorder; then
  MU_ORD="$(probe3 "$T2/mut-sortorder" interleave 0 fp:ffff00000000 fp:ffff00000001 fp:ffff00000002 \
            fp:ffff00000003 id:b-one id:b-two fp:0123456789ab 2>&1 | sed -n 's/^SEEDPOS=//p')"
  CT_ORD="$(probe3 "$CTL2" interleave 0 fp:ffff00000000 fp:ffff00000001 fp:ffff00000002 \
            fp:ffff00000003 id:b-one id:b-two fp:0123456789ab 2>&1 | sed -n 's/^SEEDPOS=//p')"
  if [ "$MU_ORD" = "1,2,3,4" ] && [ "$CT_ORD" != "1,2,3,4" ]; then
    ok "(MU3) W8 the interleave: sorting by key parks all four seeds at positions $MU_ORD, where the control spreads them to $CT_ORD — a seed a verifier can find by file order gates nothing"
  else
    no "(MU3) W8 the interleave: mutant=$MU_ORD control=$CT_ORD — expected the mutant to produce one contiguous block and the control not to"
  fi
else
  mut2_failed sortorder
fi
# --- the all-or-nothing append, the seeds, and the sha's provenance --------------------------------
mu3_new  partialappend "P1/L1 the all-or-nothing append" '^ACCEPTED=' ingest "${ING_FABRICATED[@]}"
mu3_new  seedstoledger "L6/P2 seeds never reach the ledger" '^ACCEPTED=fp:ffff' ingest "${ING_CLEAN[@]}"
# The sha mutant needs a response that RESTATES a different sha; the clean one carries none, so the
# mutant's fallback would silently agree with the control. The response is built for this mutant alone.
python3 - "$T3/resp-clean.jsonl" > "$T3/resp-sha.jsonl" <<'PYEOF'
import json, sys
for l in open(sys.argv[1], encoding="utf-8"):
    r = json.loads(l)
    r["text_sha"] = "b" * 40
    print(json.dumps(r, sort_keys=True))
PYEOF
mu3_new  shafromrec "P5 the sha comes from the DISPATCH" '^SHA=[^|]*\|bbbbbbbb' \
                    ingest "$DISP" "$T3/resp-sha.jsonl" "$ANS" "$T3R/memory/backlog.md" \
                    "$T3R/memory/backlog-done.md" "$T3R"
# …and the control must NOT already say that, or the mutant's appearance proves nothing.
probe3 "$CTL2" ingest "$DISP" "$T3/resp-sha.jsonl" "$ANS" "$T3R/memory/backlog.md" \
  "$T3R/memory/backlog-done.md" "$T3R" 2>&1 | grep -q '^SHA=[^|]*|bbbbbbbb' \
  && no "(MU3) P5's control ALSO takes the sha from the response, so the mutant's appearance is not attributable" \
  || ok "(MU3) P5's control ignores a restated sha, so the shafromrec mutant's appearance is attributable to that one line"


# ==================================================================================================
# TASK 4 — `groom apply`: the REFUSAL GATE, the write discipline, and the delegated closures.
#
# THE GATE IS THE PRODUCT. Everything else in this half is plumbing around one sentence of the user's
# brief — "wszystkie ma najpierw zweryfikowac" — and decision 10 is its mechanical form: `apply`
# refuses unless every entry carries a CURRENT verdict, names the shortfall BY ID, and exits with a
# code outside {0,1,2,10,11,12} so a refusal can never be read as one of `backlog-archive.py`'s lookup
# or status answers.
#
# WHAT THE PLAN GOT WRONG HERE, measured before a line of this was written, because two of its three
# statements about this task are false:
#
#  1. THE WRITE-DISCIPLINE ASSERTIONS HAVE AN EMPTY SUBJECT ON THIS REPO. The RED asks for "the diff
#     touches exactly N lines; each gains exactly the minted id at body position 0; byte delta equals
#     the sum of inserted ids". Measured on this repo: the mint set is 263 entries and MINTABLE is
#     **0** — every one is the BULLET dialect that `mint_into` refuses by a contract
#     `test-backlog-headings.sh` (H20/AC7) pins verbatim. So N is 0 here and every one of those
#     assertions would be `0 == 0`. They therefore run over a FIXTURE with genuinely mintable
#     checkbox entries (group W), the fixture's mintable count is CENSUSED before any property of it
#     is asserted, and the real repo's N=0 is asserted SEPARATELY as a measured fact (W12) so the zero
#     is a recorded refusal rather than an untested path.
#  2. AC8'S STATED RATIONALE IS WRONG AND ITS LITERAL FORM IS UNSATISFIABLE. It says
#     `memory/backlog.md` is byte-identical "because the pre-pass already did" the minting — but the
#     pre-pass mints nothing here either; NOTHING mints on this repo at all. And it asks for a
#     byte-identical open file WHILE `backlog-done.md` changes, which cannot both hold: both
#     `cmd_archive` and `cmd_drop_stale` write BOTH files or neither (`atomic_write(archive, ...)` is
#     always followed by `atomic_write(real, ...)`), so an archive that changed is an open file that
#     changed. The assertion is kept in the only two forms that can be true at once, and they are
#     stronger than the original: (i) with a complete ledger that licenses NO closure the open file is
#     byte-identical and `apply` mints nothing (W10); (ii) with a complete ledger that DOES license
#     one, every byte of both files is BYTE-IDENTICAL to running the helper ALONE on a pristine copy
#     (D2) — which is what "written only by the helper" actually means, and it is checkable.
#  3. AC7'S "386 of 387" IS STALE, like every count in this plan. 387 has been quoted three times and
#     has been wrong three times (330 and 483/494 were also quoted). Measured here today: 495 entries
#     over `zb.DEFAULT_KINDS + (KIND_HEADING,)` — `backlog-groom.py`'s own selection — against the MAIN
#     checkout's `memory/backlog.md`, which is where `main_root` sends every worktree. The count is
#     DERIVED at run time below and the all-but-one ledger is built from it. No plan constant is quoted.
#
# NO VACUOUS ASSERTIONS, same rule as the three halves above. Every fixture ledger is built through the
# ledger's OWN `keys_for`/`text_sha`, so "complete" means complete by the same definition `coverage`
# uses — a hand-written key makes a gate that fires on a typo indistinguishable from one that fires on
# an unverified entry. Every refusal has a positive control on the SAME fixture, and every new mutant
# is shown to change the outcome.
# ==================================================================================================
echo "== Task 4: the refusal gate and the dispositions =="

T4="$FIX/t4"
mkdir -p "$T4"
for f in "$APPLY_MOD" "$LOAD_MOD" "$ARCHIVE_PY"; do
  [ -f "$f" ] && ok "(Y0) present: ${f#"$ROOT"/}" || { no "(Y0) missing: ${f#"$ROOT"/} — nothing in this half can be checked"; finish; }
done
# The factory must ship the ARCHIVER into every mutant directory, because `apply` finds it through
# `os.path.realpath(__file__)`'s own directory. Without it every delegation assertion below would fail
# on an ABSENCE and read exactly like a mutation.
[ -f "$CTL2/backlog-archive.py" ] \
  && ok "(Y0b) the control mutant directory carries backlog-archive.py — apply delegates to the copy beside ITSELF, so a missing one would make every delegation assertion below fail on an absence that reads exactly like a mutation" \
  || { no "(Y0b) $CTL2 has no backlog-archive.py; apply would refuse RC_HELPER in every scenario below"; finish; }

sha4(){ if [ -f "$1" ]; then python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1"; else echo "-"; fi; }
mode4(){ python3 -c "import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" "$1"; }
ign4(){ ( cd "$(dirname "$1")" && git check-ignore -q "$1" && echo ignored || echo tracked ); }

# --------------------------------------------------------------------------------------------------
# The fixture-ledger builder. Every row goes through the LEDGER'S OWN keys_for and text_sha, so a
# ledger this suite calls complete is complete by the same definition coverage() uses.
# --------------------------------------------------------------------------------------------------
MKLED="$T4/mkledger.py"
cat > "$MKLED" <<'PYEOF'
r"""Build a COMPLETE (or deliberately short) fixture ledger from a backlog's own bytes.

RAW docstring for the same reason as the three probes': a `\s` in a plain one is a SyntaxWarning on
stderr, and every caller reads stderr as "the fixture did not build".

Usage: mkledger.py <moddir> <backlog> <out.jsonl>
                   [--skip N] [--rank] [--default VERDICT] [--cite PATH] [--verdict SUBJECT=VERDICT]

Hand-written keys and shas were the alternative and they make a refusal unattributable: a gate that
fires because a key was mistyped looks exactly like a gate that fires because an entry is unverified.
"""
import json
import sys

args = sys.argv[1:]
MODDIR, BACKLOG, OUT = args[:3]
sys.path.insert(0, MODDIR)
import zuvo_backlog_io as zio      # noqa: E402
import zuvo_backlog_ledger as zl   # noqa: E402
import zuvo_backlog_parse as zb    # noqa: E402

KINDS = zb.DEFAULT_KINDS + (zb.KIND_HEADING,)
skip, rank, default, cite = 0, False, zl.VERDICT_STILL_REAL, "tools/present.py"
want = {}
i = 3
while i < len(args):
    a = args[i]
    if a == "--skip":
        skip = int(args[i + 1]); i += 2
    elif a == "--rank":
        rank = True; i += 1
    elif a == "--default":
        default = args[i + 1]; i += 2
    elif a == "--cite":
        cite = args[i + 1]; i += 2
    elif a == "--verdict":
        k, v = args[i + 1].split("=", 1); want[k] = v; i += 2
    else:
        sys.exit("mkledger: unknown argument %r" % a)

entries = list(zb.iter_entries(zio.read(BACKLOG), kinds=KINDS))
keep = entries[:len(entries) - skip] if skip else entries
rows = []
for n, e in enumerate(keep):
    subject = e.ident or e.key
    verdict = want.get(subject, want.get(e.ident, default))
    if verdict == zl.VERDICT_DUPLICATE_OF:
        evidence = "%s:1 duplicates %s" % (zio.ARCHIVE_NAME, e.key)
    elif verdict == zl.VERDICT_NOT_VERIFIABLE:
        evidence = "nothing in the tree decides this entry"
    else:
        evidence = "%s:1 the fixture ledger cites a line that exists" % cite
    row = {"id": subject,
           "keys": sorted(zb.keys_for(e.body, e.ident)),
           "text_sha": zl.text_sha(e.body),
           "verdict": verdict,
           "evidence": evidence,
           # A FIXED stamp, never now_stamp(): _dedup orders two writers by this string, and the
           # disposition row `apply` appends carries it over UNCHANGED, so a moving stamp would make
           # "the disposition row won" depend on the clock instead of on the code under test.
           "verified_at": "2026-09-30T00:00:00+00:00",
           "verified_by": "agent:fixture",
           "disposition": "pending"}
    if rank:
        # REVERSE document order, so the hint really asks for a move. A rank agreeing with the file
        # would make "the open file was not reordered" true for a reason unrelated to this code.
        row["rank"] = len(keep) - n
    rows.append(row)
with open(OUT, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r, sort_keys=True) + "\n")
print("LEDGER_ROWS=%d ENTRIES=%d" % (len(rows), len(entries)))
PYEOF

# A fresh repo per scenario, NEVER a reused one: a mutant that writes must not inherit a file some
# earlier run already changed, and the fixture tree is deliberately never deleted.
#
# `mktemp -d` AND NOT A COUNTER, and this is the one harness defect this half's own positive control
# found rather than confirmed. The first version did `Y_SEQ=$((Y_SEQ+1)); d="$T4/r$Y_SEQ"` — and every
# caller invokes this through `$( )`, which is a SUBSHELL, so the increment was discarded and every call
# returned the SAME directory. D2 then compared a file with itself and passed byte-identical, while the
# helper-alone run refused with "not defined in backlog.md — nothing removed" because apply had already
# dropped the entry. Only the D2b rc control noticed. Every mutant comparison below shares a repo under
# that bug, so it would have made the whole MU4 group meaningless while reporting green.
mkrepo4(){   # $1 = backlog text file, $2 = archive text file ("" for an empty archive)
  local d
  d="$(mktemp -d "$T4/rXXXXXX")" || return 1
  mkdir -p "$d/memory" "$d/tools" || return 1
  ( cd "$d" && git init -q . >/dev/null 2>&1 ) || return 1
  printf 'print("present")\n' > "$d/tools/present.py"
  cp "$1" "$d/memory/backlog.md" || return 1
  if [ -n "$2" ]; then cp "$2" "$d/memory/backlog-done.md" || return 1; else : > "$d/memory/backlog-done.md"; fi
  printf '%s\n' "$d"
}
apply4(){    # moddir, repo, extra args... -> writes $T4/last.out and echoes the rc
  local md="$1" repo="$2"; shift 2
  python3 "$md/backlog-groom.py" apply --repo "$repo" "$@" >"$T4/last.out" 2>&1
  printf '%s\n' "$?"
}
led4(){      # repo, mkledger args... -> builds the repo's own ledger, echoing mkledger's census line
  local repo="$1"; shift
  python3 "$MKLED" "$CTL2" "$repo/memory/backlog.md" "$repo/memory/backlog-verdicts.jsonl" "$@"
}

# --------------------------------------------------------------------------------------------------
# The fixture backlogs. One per concern, because a combined one makes a red unattributable — and the
# drop and archive lanes genuinely cannot share a fixture: `cmd_archive` refuses outright while an id
# is defined in BOTH files, which is exactly what a `dropped` entry is until `drop-stale` removes it.
# --------------------------------------------------------------------------------------------------
cat > "$T4/bl-disp.md" <<'EOF'
# Tech Debt Backlog

## Open

- [ ] B-still-one tools/present.py the retry budget is still unbounded here
- [ ] tools/present.py a CHECKBOX entry with no id at all, so it is mintable
- [ ] B-dup-a tools/present.py a duplicate report never licenses a merge
- [ ] B-nv-one tools/present.py nothing in the tree decides this entry at all
- [ ] B-nr-one tools/present.py stale but NOT ticked and not in the archive
- [x] B-arch-one tools/present.py ticked with a recorded outcome — DONE 1a2b3c4
EOF
cat > "$T4/bl-mint.md" <<'EOF'
# Tech Debt Backlog

## Open

- [ ] tools/present.py the first CHECKBOX entry with no id at all, mintable
- [ ] tools/present.py the second mintable checkbox, different words entirely
- [x] tools/present.py a third mintable checkbox, ticked and saying nothing
- plain bullet with no id and no checkbox, which mint_into refuses by contract
- B-9 tools/present.py an ordinal id definition_id cannot see, minting would double it
- [ ] B-has-id tools/present.py an entry that already carries an id of its own
EOF
cat > "$T4/bl-drop.md" <<'EOF'
# Tech Debt Backlog

## Open

- [ ] B-live-one tools/present.py this one is genuinely still real today
- [x] B-stale-copy tools/present.py an open copy of something already archived — DONE 1a2b3c4
- [x] B-also-done tools/present.py ticked and closed with a reason of its own — DONE 9f9f9f9
EOF
cat > "$T4/arch-drop.md" <<'EOF'
# Archived

## Archived from backlog.md on 2026-09-01 (1 entry)

- [x] B-stale-copy tools/present.py an open copy of something already archived — FIXED 1a2b3c4
EOF
cat > "$T4/bl-held.md" <<'EOF'
# Tech Debt Backlog

## Open

- [x] B-held-one tools/present.py ticked, but it still carries [ ] an open follow-up
EOF
cat > "$T4/bl-scope.md" <<'EOF'
# Tech Debt Backlog

## Open

- [x] B-tick-still tools/present.py ticked but the verdict says it is still real
- [x] B-tick-fixed tools/present.py ticked and verified stale — DONE 1a2b3c4
EOF
cat > "$T4/bl-head.md" <<'EOF'
# Tech Debt Backlog

## B-head-one tools/present.py a heading entry closed with a marker — DONE 1a2b3c4

- [ ] B-head-child tools/present.py a child that is genuinely still real today

## Open

- [ ] B-flat-one tools/present.py an ordinary open entry outside that heading
EOF

# ==================================================================================================
# P — THE REFUSAL GATE. Decision 10, and AC7.
# ==================================================================================================
echo "-- P: apply REFUSES unless every entry carries a current verdict --"

# THE EXIT-CODE REGISTRY FIRST, derived from the module rather than restated. The constraint is a
# property of the SET — no refusal may collide with {0,1,2,10,11,12}, because 1 is the namespace
# violation `append-runlog` turns into a blocked run and 10/11/12 are backlog-archive.py's lookup and
# status ANSWERS. A collision makes a refusal indistinguishable from a lookup result.
python3 - "$CTL2" >"$T4/codes.out" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import zuvo_backlog_prepass as zp      # noqa: E402
taken = {0, 1, 2, 10, 11, 12}
codes = {n: v for n, v in vars(zp).items() if n.startswith("RC_") and isinstance(v, int)}
print("NCODES=%d" % len(codes))
print("CODES=%s" % ",".join("%s=%d" % kv for kv in sorted(codes.items())))
print("COLLIDE=%s" % ",".join(sorted(n for n, v in codes.items() if v in taken)))
print("DISTINCT=%d" % int(len(set(codes.values())) == len(codes)))
PYEOF
cat "$T4/codes.out"
P_NC="$(sed -n 's/^NCODES=//p' "$T4/codes.out" | head -1)"
[ "${P_NC:-0}" -ge 10 ] \
  && ok "(P0) the registry holds $P_NC RC_* codes, so the two set properties below are asserted over a non-empty set derived from the module and not over a list retyped here" \
  || no "(P0) only ${P_NC:-0} RC_* codes were found in zuvo_backlog_prepass — the derivation is broken, and both assertions below would be vacuous"
grep -qx 'COLLIDE=' "$T4/codes.out" \
  && ok "(P0b) not one of them is in {0,1,2,10,11,12} — a refusal can never be read as a namespace violation or as one of backlog-archive.py's lookup/status answers" \
  || no "(P0b) code(s) collide with the taken set: $(sed -n 's/^COLLIDE=//p' "$T4/codes.out")"
grep -qx 'DISTINCT=1' "$T4/codes.out" \
  && ok "(P0c) …and they are pairwise DISTINCT, so an operator who greps an exit code gets one answer" \
  || no "(P0c) two RC_* constants share a value: $(sed -n 's/^CODES=//p' "$T4/codes.out")"
RC_UNVER="$(sed -n 's/.*RC_UNVERIFIED=\([0-9]*\).*/\1/p' "$T4/codes.out" | head -1)"
RC_LED="$(sed -n 's/.*RC_LEDGER=\([0-9]*\).*/\1/p' "$T4/codes.out" | head -1)"
RC_SCOPE_N="$(sed -n 's/.*RC_SCOPE=\([0-9]*\).*/\1/p' "$T4/codes.out" | head -1)"
RC_NONE_N="$(sed -n 's/.*RC_UNKNOWN_IGNORE=\([0-9]*\).*/\1/p' "$T4/codes.out" | head -1)"
[ -n "$RC_UNVER" ] && [ -n "$RC_LED" ] && [ -n "$RC_SCOPE_N" ] && [ -n "$RC_NONE_N" ] \
  && ok "(P0d) the four codes this half asserts on are READ from the module (unverified=$RC_UNVER ledger=$RC_LED scope=$RC_SCOPE_N unknown-ignore=$RC_NONE_N), so renumbering one cannot leave an assertion passing against a stale literal" \
  || { no "(P0d) could not read the four codes from the module: $(cat "$T4/codes.out" | tr '\n' ' ')"; finish; }

# THE POSITIVE CONTROL FIRST, on the SAME fixture: a complete ledger must SUCCEED, or the refusal
# below would be attributable to the fixture rather than to the one missing row.
PR_OK="$(mkrepo4 "$T4/bl-disp.md" "")" || no "(P1a) could not build the complete-ledger repo"
led4 "$PR_OK" --default STILL-REAL >"$T4/ledok.out" 2>&1
cat "$T4/ledok.out"
P_TOTAL="$(sed -n 's/.*ENTRIES=//p' "$T4/ledok.out" | head -1)"
[ "${P_TOTAL:-0}" -ge 6 ] \
  && ok "(P1a) the disposition fixture yields $P_TOTAL entries and the ledger covers all of them — DERIVED from the bytes, never a plan constant" \
  || no "(P1a) the fixture yields ${P_TOTAL:-?} entries; every count below would be about a different file"
P_RC_OK="$(apply4 "$CTL2" "$PR_OK" --dry-run)"
[ "$P_RC_OK" = "0" ] \
  && ok "(P1b) control: with a COMPLETE ledger apply exits 0 — so the refusal below is attributable to the missing row and not to the fixture" \
  || no "(P1b) apply refused a complete ledger (rc=$P_RC_OK): $(tail -3 "$T4/last.out")"
grep -q "^VERIFIED=$P_TOTAL/$P_TOTAL\$" "$T4/last.out" \
  && ok "(P1c) …and it reports VERIFIED=$P_TOTAL/$P_TOTAL, so 'complete' is a number the run printed rather than an assumption of the fixture" \
  || no "(P1c) the control run does not report full coverage: $(grep '^VERIFIED=' "$T4/last.out")"

# AC7: all-but-one. The ledger is built with --skip 1 from the SAME file, so exactly one entry differs.
PR_SHORT="$(mkrepo4 "$T4/bl-disp.md" "")" || no "(P2a) could not build the short-ledger repo"
led4 "$PR_SHORT" --default STILL-REAL --skip 1 >"$T4/ledshort.out" 2>&1
P_ROWS="$(sed -n 's/^LEDGER_ROWS=\([0-9]*\).*/\1/p' "$T4/ledshort.out" | head -1)"
[ "${P_ROWS:-0}" = "$((P_TOTAL - 1))" ] \
  && ok "(P2a) the short ledger covers $P_ROWS of $P_TOTAL entries — all but ONE, which is AC7's shape with AC7's count DERIVED" \
  || no "(P2a) the short ledger covers ${P_ROWS:-?} rows of $P_TOTAL; AC7 needs exactly all-but-one"
P_B0="$(sha4 "$PR_SHORT/memory/backlog.md")"; P_A0="$(sha4 "$PR_SHORT/memory/backlog-done.md")"
P_L0="$(sha4 "$PR_SHORT/memory/backlog-verdicts.jsonl")"
P_RC="$(apply4 "$CTL2" "$PR_SHORT")"
cp "$T4/last.out" "$T4/ac7.out"
if [ "$P_RC" = "$RC_UNVER" ]; then
  ok "(P2/AC7) apply REFUSES a ledger covering $P_ROWS of $P_TOTAL entries, exiting rc=$P_RC (RC_UNVERIFIED) — outside {0,1,2,10,11,12} by P0b, so it cannot be read as a lookup answer"
else
  no "(P2/AC7) rc=$P_RC, expected RC_UNVERIFIED=$RC_UNVER: $(tail -3 "$T4/ac7.out")"
fi
grep -q "^VERIFIED=$P_ROWS/$P_TOTAL\$" "$T4/ac7.out" \
  && ok "(P2b/AC7) the refusal reports the ratio it refused on ($P_ROWS/$P_TOTAL)" \
  || no "(P2b/AC7) no VERIFIED=$P_ROWS/$P_TOTAL line: $(grep '^VERIFIED=' "$T4/ac7.out")"
P_NAMED="$(grep -c '^UNVERIFIED=' "$T4/ac7.out")"
[ "$P_NAMED" = "1" ] \
  && ok "(P2c/AC7) the shortfall is NAMED and it is exactly one line: $(grep '^UNVERIFIED=' "$T4/ac7.out" | head -1)" \
  || no "(P2c/AC7) $P_NAMED UNVERIFIED= lines for a one-entry shortfall"
P_MISSING="$(grep '^UNVERIFIED=' "$T4/ac7.out" | head -1 | sed 's/^UNVERIFIED=//')"
grep -qF -- "$P_MISSING" "$T4/ac7.out" && grep -q "shortfall, by id.*$P_MISSING" "$T4/ac7.out" \
  && ok "(P2d/AC7) the id also appears in the REFUSAL MESSAGE on stderr, so an operator who only sees the error still learns which entry is missing" \
  || no "(P2d/AC7) the refusal message does not name $P_MISSING: $(grep 'shortfall' "$T4/ac7.out" | head -1 | cut -c1-140)"
grep -qF "$P_MISSING" "$PR_SHORT/memory/backlog-verdicts.jsonl" \
  && no "(P2e/AC7) the named entry IS in the ledger, so the gate named the wrong one and P2c is about a different entry" \
  || ok "(P2e/AC7) the named entry is genuinely absent from the ledger — the gate named the entry it is missing, not merely some entry"
if [ "$P_B0" = "$(sha4 "$PR_SHORT/memory/backlog.md")" ] \
   && [ "$P_A0" = "$(sha4 "$PR_SHORT/memory/backlog-done.md")" ] \
   && [ "$P_L0" = "$(sha4 "$PR_SHORT/memory/backlog-verdicts.jsonl")" ]; then
  ok "(P2f/AC7) ZERO BYTES were written: backlog.md, backlog-done.md and the ledger all keep their sha256 — an exit code alone would not notice a partial write"
else
  no "(P2f/AC7) the refusal wrote something: backlog $( [ "$P_B0" = "$(sha4 "$PR_SHORT/memory/backlog.md")" ] && echo same || echo CHANGED), archive $( [ "$P_A0" = "$(sha4 "$PR_SHORT/memory/backlog-done.md")" ] && echo same || echo CHANGED), ledger $( [ "$P_L0" = "$(sha4 "$PR_SHORT/memory/backlog-verdicts.jsonl")" ] && echo same || echo CHANGED)"
fi
grep -q '^DISPOSITION=' "$T4/ac7.out" \
  && no "(P2g/AC7) the refusing run still printed dispositions — the gate must stop BEFORE anything is decided, or a reader takes the list as what happened" \
  || ok "(P2g/AC7) the refusing run prints NO disposition at all: the gate is before the decisions, not after them"

# A STALE verdict is not a verdict. One character of an entry's text rotates `text_sha`, and the gate
# must then read that entry as unverified — which is the difference between a content key and a TTL.
PR_STALE="$(mkrepo4 "$T4/bl-disp.md" "")" || no "(P3a) could not build the stale-sha repo"
led4 "$PR_STALE" --default STILL-REAL >/dev/null 2>&1
python3 - "$PR_STALE/memory/backlog.md" <<'PYEOF'
import sys
p = sys.argv[1]
with open(p, encoding="utf-8") as fh:
    t = fh.read()
assert "still unbounded here" in t
with open(p, "w", encoding="utf-8") as fh:
    fh.write(t.replace("still unbounded here", "still unbounded here!"))
PYEOF
P_RC_STALE="$(apply4 "$CTL2" "$PR_STALE")"
if [ "$P_RC_STALE" = "$RC_UNVER" ] && grep -q '^UNVERIFIED=B-still-one$' "$T4/last.out"; then
  ok "(P3/AC7) a ONE-CHARACTER edit to an entry rotates its text_sha and the gate names it unverified again — a verdict expires with the text, never with the clock, and nothing is closed on the strength of a judgement about text that has since changed"
else
  no "(P3/AC7) rc=$P_RC_STALE and the edited entry was $(grep -q '^UNVERIFIED=B-still-one$' "$T4/last.out" && echo named || echo NOT named): $(tail -2 "$T4/last.out" | cut -c1-120)"
fi

# A DEFECTIVE ledger is a refusal with its OWN code, because "the ledger is broken" and "the ledger is
# fine and incomplete" have opposite remedies.
PR_BAD="$(mkrepo4 "$T4/bl-disp.md" "")" || no "(P4a) could not build the corrupt-ledger repo"
led4 "$PR_BAD" --default STILL-REAL >/dev/null 2>&1
printf '%s\n' '{"id":"B-broken","keys":["id:B-broken"],"text_sha":"nothex","verdict":"WHAT","evidence":"","verified_at":"x","verified_by":"nope","disposition":"pending"}' \
  >> "$PR_BAD/memory/backlog-verdicts.jsonl"
P_BADB0="$(sha4 "$PR_BAD/memory/backlog.md")"
P_RC_BAD="$(apply4 "$CTL2" "$PR_BAD")"
if [ "$P_RC_BAD" = "$RC_LED" ] && [ "$P_BADB0" = "$(sha4 "$PR_BAD/memory/backlog.md")" ]; then
  ok "(P4) an UNPARSEABLE ledger row makes apply refuse with its own code rc=$P_RC_BAD (RC_LEDGER), writing nothing — a line that might have said STILL-REAL is not a line to guess at, and a distinct code is what tells an operator to fix the file rather than to verify more entries"
else
  no "(P4) rc=$P_RC_BAD (expected RC_LEDGER=$RC_LED), backlog $( [ "$P_BADB0" = "$(sha4 "$PR_BAD/memory/backlog.md")" ] && echo unchanged || echo CHANGED)"
fi
grep -q '^LEDGER_DEFECT=.*verdict' "$T4/last.out" \
  && ok "(P4b) …and it names the broken line and what is wrong with it, rather than reporting the entry as unverified and sending someone to re-verify it for ever" \
  || no "(P4b) the run does not name the defective line: $(grep '^LEDGER_DEFECT=' "$T4/last.out" | head -1)"

# ==================================================================================================
# W — THE WRITE DISCIPLINE, over a fixture whose mint set is NOT EMPTY, and the real repo's N=0 as a
# measured fact rather than an untested path.
#
# Every assertion here would be `0 == 0` on this repo (MINTABLE=0, see the header). The fixture is
# CENSUSED first, so "the diff touched exactly N lines" is a statement about a non-zero N.
# ==================================================================================================
echo "-- W: the write discipline on a fixture with a NON-EMPTY mint set --"

WR4="$(mkrepo4 "$T4/bl-mint.md" "")" || no "(W0a) could not build the mintable repo"
chmod 600 "$WR4/memory/backlog.md"
W4_B0="$(wc -c < "$WR4/memory/backlog.md" | tr -d ' ')"
W4_L0="$(awk 'END{print NR}' "$WR4/memory/backlog.md")"
W4_SHA0="$(sha4 "$WR4/memory/backlog.md")"
W4_IGN0="$(ign4 "$WR4/memory/backlog.md")"
cp "$WR4/memory/backlog.md" "$T4/premint.md"
python3 "$CTL2/backlog-groom.py" plan --repo "$WR4" >"$T4/w4plan.out" 2>&1; W4_RC=$?
w4v(){ sed -n "s/^$1=//p" "$T4/w4plan.out" | head -1; }
W4_N="$(w4v MINTABLE)"
W4_INS="$(w4v INSERTED_BYTES)"
if [ "$W4_RC" -eq 0 ] && [ "${W4_N:-0}" -ge 2 ]; then
  ok "(W0/VACUITY GUARD) the fixture's mint set is $(w4v MINT_SET) and MINTABLE=$W4_N, so N is $W4_N and every assertion below has a NON-EMPTY subject — on this repo the same numbers are 263 and 0, which is why none of this could be asserted there"
else
  no "(W0/VACUITY GUARD) rc=$W4_RC MINTABLE='$W4_N' — with N=0 every write-discipline assertion below is 0 == 0 and this group proves nothing: $(tail -3 "$T4/w4plan.out")"
  finish
fi
[ "$(w4v UNMINTABLE)" -ge 2 ] \
  && ok "(W0b) …and $(w4v UNMINTABLE) entries are REPORTED as unmintable in the same fixture, so the filter is live here rather than absent" \
  || no "(W0b) UNMINTABLE=$(w4v UNMINTABLE); the fixture holds a plain bullet and an already-id'd entry and both must be filtered"
# THE HEADING DIALECT, measured rather than argued. `mint_into` ACCEPTS a flush-left heading, so the
# obvious reading is that an id-less heading is mintable — and it never is, because `_heading_entry` is
# ID-ANCHORED, so `iter_entries` does not yield one as an entry at all. N over headings is therefore 0
# BY CONSTRUCTION and not by contract, which is a different (and stronger) reason than the bullet's.
python3 - "$CTL2" >"$T4/headmint.out" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import zuvo_backlog_mint as zm     # noqa: E402
import zuvo_backlog_parse as zb    # noqa: E402
KINDS = zb.DEFAULT_KINDS + (zb.KIND_HEADING,)
text = "# Backlog\n\n## a heading with no id at all, entry-shaped prose\n"
ents = list(zb.iter_entries(text, kinds=KINDS))
print("HEADING_ENTRIES=%d" % len(ents))
print("MINT_INTO_ACCEPTS_HEADING=%d"
      % int(zm.mint_into("## a heading with no id at all", "B-A20260930-abcdef") is not None))
PYEOF
cat "$T4/headmint.out"
if grep -qx 'HEADING_ENTRIES=0' "$T4/headmint.out" \
   && grep -qx 'MINT_INTO_ACCEPTS_HEADING=1' "$T4/headmint.out"; then
  ok "(W0c) the heading dialect is mintable by mint_into and UNREACHABLE by the parser: an id-less heading is never yielded as an entry, so N over headings is 0 BY CONSTRUCTION — a different and stronger reason than the bullet's pinned refusal, and one no assertion had stated"
else
  no "(W0c) the heading measurement came back $(tr '\n' ' ' < "$T4/headmint.out") — if an id-less heading ever became an entry, the mint would write an identifier into the STRUCTURE of a tracked file"
fi

W4_B1="$(wc -c < "$WR4/memory/backlog.md" | tr -d ' ')"
W4_L1="$(awk 'END{print NR}' "$WR4/memory/backlog.md")"
# W1: THE DIFF TOUCHES EXACTLY N LINES. Counted line-by-line rather than by `git diff`, which reports a
# modified line as one insertion plus one deletion and would make "exactly N" mean 2N here.
python3 - "$T4/premint.md" "$WR4/memory/backlog.md" "$CTL2" >"$T4/w4diff.out" 2>&1 <<'PYEOF'
import re
import sys
sys.path.insert(0, sys.argv[3])
import zuvo_backlog_parse as zb           # noqa: E402
before = open(sys.argv[1], encoding="utf-8").read().splitlines()
after = open(sys.argv[2], encoding="utf-8").read().splitlines()
print("SAMELEN=%d" % int(len(before) == len(after)))
changed = [i for i, (a, b) in enumerate(zip(before, after), start=1) if a != b]
print("NCHANGED=%d" % len(changed))
bad_pos = []
for i in changed:
    a, b = before[i - 1], after[i - 1]
    # the minted id must be at BODY position 0 — MINTED_ID_RE anchored at the body, per the mint's
    # contract with keys_for, which strips exactly that prefix to recover the pre-mint content key
    body = zb.body_of(b.strip())
    if zb.MINTED_ID_RE.match(body) is None:
        bad_pos.append("%d:no minted id at body position 0 in %r" % (i, b))
        continue
    stripped = re.sub(r"^(B-A\d{8}-[0-9a-f]{6} )", "", body)
    if stripped != zb.body_of(a.strip()):
        bad_pos.append("%d:removing the id does not restore the line (%r vs %r)" % (i, stripped, a))
print("BADPOS=%s" % (";".join(bad_pos) or "-"))
ids = re.findall(r"B-A\d{8}-[0-9a-f]{6} ", "\n".join(after))
print("NIDS=%d" % len(ids))
print("IDBYTES=%d" % sum(len(x.encode("utf-8")) for x in ids))
PYEOF
cat "$T4/w4diff.out"
wd(){ sed -n "s/^$1=//p" "$T4/w4diff.out" | head -1; }
[ "$(wd NCHANGED)" = "$W4_N" ] \
  && ok "(W1) the diff touches EXACTLY N=$W4_N lines — no more, and not fewer" \
  || no "(W1) $(wd NCHANGED) lines changed for N=$W4_N mintable entries"
[ "$(wd BADPOS)" = "-" ] \
  && ok "(W2) each changed line gains exactly the minted id at BODY POSITION 0, in MINTED_ID_RE's shape — which is the position keys_for strips to recover the content key the entry had BEFORE minting" \
  || no "(W2) $(wd BADPOS)"
[ "$(wd NIDS)" = "$W4_N" ] \
  && ok "(W3) exactly $W4_N minted ids exist in the file, so nothing else on any line changed (removing them restores every touched line, checked per line above)" \
  || no "(W3) $(wd NIDS) minted ids for N=$W4_N"
[ "$((W4_B1 - W4_B0))" = "${W4_INS:-x}" ] && [ "$(wd IDBYTES)" = "${W4_INS:-x}" ] \
  && ok "(W4) the byte delta EQUALS the sum of the inserted ids three ways over: file $W4_B0 -> $W4_B1 = +$W4_INS, the run reported $W4_INS, and the ids in the file measure $(wd IDBYTES) bytes" \
  || no "(W4) delta=$((W4_B1 - W4_B0)) reported=${W4_INS:-?} id-bytes=$(wd IDBYTES) — something else changed too"
[ "$W4_SHA0" != "$(sha4 "$WR4/memory/backlog.md")" ] \
  && ok "(W4b) …and the file's sha256 really moved, so W1-W4 are about a write that happened rather than about a fixture nothing touched" \
  || no "(W4b) the sha256 is unchanged at ${W4_SHA0:0:12}… — the mint wrote nothing and every count above is 0 == 0"
[ "$W4_L0" = "$W4_L1" ] && [ "$(wd SAMELEN)" = "1" ] \
  && ok "(W5) the line count is unchanged at $W4_L1 — an id belongs INSIDE an existing line, and the anchor that once swallowed a line ending wrote it on a new one" \
  || no "(W5) the line count moved $W4_L0 -> $W4_L1"
[ "$(mode4 "$WR4/memory/backlog.md")" = "0o600" ] \
  && ok "(W6) the 0600 MODE survives the atomic replace — atomic_write(..., None) writes a fresh temp at the umask and os.replace carries THAT mode across, so a private backlog came back world-readable as a side effect of gaining an id" \
  || no "(W6) the mode is now $(mode4 "$WR4/memory/backlog.md"), was 0o600"
[ "$(ign4 "$WR4/memory/backlog.md")" = "$W4_IGN0" ] \
  && ok "(W7) the git IGNORE STATUS is unchanged ($W4_IGN0) — the property every placement refusal in this family reads, and os.replace onto a path git resolves differently would silently change what is publishable" \
  || no "(W7) the ignore status moved $W4_IGN0 -> $(ign4 "$WR4/memory/backlog.md")"
cp "$WR4/memory/backlog.md" "$T4/after1.md"
python3 "$CTL2/backlog-groom.py" plan --repo "$WR4" >"$T4/w4plan2.out" 2>&1; W4_RC2=$?
if [ "$W4_RC2" -eq 0 ] && cmp -s "$T4/after1.md" "$WR4/memory/backlog.md"; then
  ok "(W8) a SECOND run is byte-identical: MINTABLE is now $(sed -n 's/^MINTABLE=//p' "$T4/w4plan2.out" | head -1), because every target now carries an id its own definition_id can see"
else
  no "(W8) the second run changed the file (rc=$W4_RC2)"
fi
# CRLF and symlink-ness travel through the SAME mint_write, and the suite pins both in group N on the
# Task 2 fixture (N15/N16). Re-asserted here only where this fixture adds something N could not say:
# that a CRLF file's terminator count is preserved while N ids are inserted into it.
WCR4="$(mkrepo4 "$T4/bl-mint.md" "")" || no "(W9a) could not build the CRLF mint repo"
python3 - "$WCR4/memory/backlog.md" <<'PYEOF'
import io
import sys
p = sys.argv[1]
with open(p, encoding="utf-8") as fh:
    t = fh.read()
with io.open(p, "w", encoding="utf-8", newline="") as fh:
    fh.write(t.replace("\n", "\r\n"))
PYEOF
crlf4(){ python3 -c "import sys;print(open(sys.argv[1],'rb').read().count(b'\r\n'))" "$1"; }
WCR4_C0="$(crlf4 "$WCR4/memory/backlog.md")"
python3 "$CTL2/backlog-groom.py" plan --repo "$WCR4" >"$T4/wcr4.out" 2>&1; WCR4_RC=$?
WCR4_N="$(sed -n 's/^MINTABLE=//p' "$T4/wcr4.out" | head -1)"
if [ "$WCR4_RC" -eq 0 ] && [ "$WCR4_C0" = "$(crlf4 "$WCR4/memory/backlog.md")" ] \
   && [ "$WCR4_N" = "$W4_N" ] && [ "$WCR4_C0" -gt 5 ]; then
  ok "(W9) all $WCR4_C0 CRLF terminators survive while $WCR4_N ids are inserted — the identity check rstrips \"\\r\\n\" and not \"\\n\", and comparing the wrong one made every entry on a CRLF backlog refuse for ever with a message about concurrency"
else
  no "(W9) rc=$WCR4_RC, CRLF $WCR4_C0 -> $(crlf4 "$WCR4/memory/backlog.md"), MINTABLE=$WCR4_N of expected $W4_N"
fi

# W10/W11 — APPLY's own write set is EMPTY, including when the ledger asks for a reorder.
led4 "$WR4" --default STILL-REAL --rank >"$T4/w4led.out" 2>&1
cat "$T4/w4led.out"
W4_SHA_PRE="$(sha4 "$WR4/memory/backlog.md")"
W4_ARCH_PRE="$(sha4 "$WR4/memory/backlog-done.md")"
W4_RCA="$(apply4 "$CTL2" "$WR4")"
cp "$T4/last.out" "$T4/ac8.out"
W4_HINTS="$(sed -n 's/^ORDER_HINTS=\([0-9]*\).*/\1/p' "$T4/ac8.out" | head -1)"
W4_DIFFORDER="$(sed -n 's/^ORDER_HINTS=[0-9]* different_from_file=\([0-9]*\).*/\1/p' "$T4/ac8.out" | head -1)"
if [ "$W4_RCA" = "0" ] && [ "$W4_SHA_PRE" = "$(sha4 "$WR4/memory/backlog.md")" ]; then
  ok "(W10/AC8) apply on a COMPLETE ledger leaves memory/backlog.md BYTE-IDENTICAL (sha256 ${W4_SHA_PRE:0:12}…) — and the fixture is the one that HAS a mint set, so this is not 'the mint had nothing to do'; the mint is the pre-pass's, and apply's own write set into the open file is empty"
else
  no "(W10/AC8) rc=$W4_RCA and the open file $( [ "$W4_SHA_PRE" = "$(sha4 "$WR4/memory/backlog.md")" ] && echo held || echo MOVED): $(tail -3 "$T4/ac8.out")"
fi
[ "$(grep -cE 'B-A[0-9]{8}-[0-9a-f]{6} ' "$WR4/memory/backlog.md")" = "$W4_N" ] \
  && ok "(W10b/AC8) …and the id count is still exactly $W4_N, so apply minted nothing of its own on top of the pre-pass's work" \
  || no "(W10b/AC8) the file now holds $(grep -cE 'B-A[0-9]{8}-[0-9a-f]{6} ' "$WR4/memory/backlog.md") minted ids, not $W4_N — apply minted"
[ "$W4_ARCH_PRE" = "$(sha4 "$WR4/memory/backlog-done.md")" ] \
  && ok "(W10c/AC8) backlog-done.md is untouched as well, because no verdict in this ledger licenses a closure — stated as a fact of THIS ledger rather than as a property of apply, since AC8's own wording asks for a changed archive beside an unchanged open file and both files always move together" \
  || no "(W10c/AC8) the archive changed although no verdict licensed a closure"
if [ "${W4_HINTS:-0}" -ge 2 ] && [ "$W4_DIFFORDER" = "1" ]; then
  ok "(W11) THE REORDER CASE: the ledger carries $W4_HINTS rank hints asking for an order the file does NOT have (different_from_file=1), and apply reports applied=0 having moved no line — decision 7 keeps ordering in the ledger and the rendered doc, because option A has no oracle and the per-entry text_sha is the entry-level conservation check a line-level one cannot express"
else
  no "(W11) ORDER_HINTS=${W4_HINTS:-?} different_from_file=$W4_DIFFORDER — with no hints, or with hints that agree with document order, W10's byte-identity is true for a reason that has nothing to do with this code"
fi
grep -q '^ORDER_HINTS=[0-9]* different_from_file=[01] applied=0$' "$T4/ac8.out" \
  && ok "(W11b) …and applied=0 is PRINTED, so 'the open file was not reordered' is an observable claim of the run rather than an absence a reader has to infer" \
  || no "(W11b) no applied=0 report: $(grep '^ORDER_HINTS=' "$T4/ac8.out")"

# W12 — THE REAL REPO, N=0 BY MEASUREMENT. The zero is a recorded fact with a non-empty denominator,
# which is what makes it a REFUSAL rather than an absence.
python3 "$CTL2/backlog-groom.py" plan --repo "$ROOT" --dry-run >"$T4/realplan.out" 2>&1; W4_RRC=$?
R_SET="$(sed -n 's/^MINT_SET=//p' "$T4/realplan.out" | head -1)"
R_MINTABLE="$(sed -n 's/^MINTABLE=//p' "$T4/realplan.out" | head -1)"
R_ENTRIES="$(sed -n 's/^ENTRIES=//p' "$T4/realplan.out" | head -1)"
R_INS="$(sed -n 's/^INSERTED_BYTES=//p' "$T4/realplan.out" | head -1)"
if [ "$W4_RRC" -eq 0 ] && [ "${R_SET:-0}" -gt 0 ] && [ "$R_MINTABLE" = "0" ] && [ "$R_INS" = "0" ]; then
  ok "(W12) THIS REPO, measured: $R_ENTRIES entries, a mint set of $R_SET and MINTABLE=0, INSERTED_BYTES=0 — so N is 0 here and the write-discipline group above had to run on a fixture. The zero is a REFUSAL over a set of $R_SET, not an empty set: every one is the BULLET dialect mint_into declines by a contract test-backlog-headings.sh (H20/AC7) pins verbatim"
else
  no "(W12) rc=$W4_RRC MINT_SET=${R_SET:-?} MINTABLE=${R_MINTABLE:-?} INSERTED_BYTES=${R_INS:-?} — if MINTABLE ever becomes non-zero on this repo, plan revision 6's decision has changed and the fixture-only write assertions above must gain a real-repo twin"
fi
[ "${R_ENTRIES:-0}" -gt 400 ] \
  && ok "(W12b) …and the entry count is DERIVED at $R_ENTRIES rather than quoted: the plan has said 387 (three times), 330, 483 and 494 for this same number, and every one of them was wrong when it was read" \
  || no "(W12b) ENTRIES=${R_ENTRIES:-?}, which is not the shape of this repo's backlog — the derivation is broken"

# ==================================================================================================
# X — THE MOCKED PIPELINE, end to end: plan -> fixture ledger -> apply, and the dispositions read back
# through the ledger's own reader. It STOPS at apply, because `render` does not exist until Task 5.
# ==================================================================================================
echo "-- X: plan -> fixture ledger -> apply, and the disposition write-back --"
probe "$CTL" read "$WR4/memory/backlog-verdicts.jsonl" >"$T4/xread.out" 2>&1
X_ROWS="$(sed -n 's/^ROWS=//p' "$T4/xread.out" | head -1)"
X_DEF="$(sed -n 's/^NDEFECTS=//p' "$T4/xread.out" | head -1)"
if [ "$X_DEF" = "0" ] && [ "${X_ROWS:-0}" -ge 4 ]; then
  ok "(X1) after the pipeline the ledger reads $X_ROWS rows and 0 defects through the LEDGER'S OWN reader — the disposition rows apply appended pass the validator that will read them back"
else
  no "(X1) ROWS=${X_ROWS:-?} NDEFECTS=${X_DEF:-?} after apply: $(tail -2 "$T4/xread.out")"
fi
X_PENDING="$(python3 -c "
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding='utf-8') if l.strip()]
print('%d %d %d' % (len(rows), sum(1 for r in rows if r.get('disposition') == 'pending'),
                    sum(1 for r in rows if r.get('disposition') == 'kept')))" \
  "$WR4/memory/backlog-verdicts.jsonl")"
X_ALL="$(printf '%s' "$X_PENDING" | cut -d' ' -f1)"
X_PEND="$(printf '%s' "$X_PENDING" | cut -d' ' -f2)"
X_KEPT="$(printf '%s' "$X_PENDING" | cut -d' ' -f3)"
if [ "${X_KEPT:-0}" -ge 4 ] && [ "${X_PEND:-0}" -ge 4 ]; then
  ok "(X2) the ledger is APPEND-ONLY: $X_ALL physical lines hold both the $X_PEND original 'pending' rows and the $X_KEPT 'kept' ones — nothing was rewritten, so a corrupt line can never be silently dropped by the write that acts on its neighbours"
else
  no "(X2) lines=$X_ALL pending=$X_PEND kept=$X_KEPT — the disposition write-back did not append beside the verdicts"
fi
X_CUR="$(python3 -c "
import sys
sys.path.insert(0, sys.argv[1])
import zuvo_backlog_io as zio, zuvo_backlog_ledger as zl, zuvo_backlog_parse as zb
rows = zl.read_ledger(sys.argv[2]).rows
ents = list(zb.iter_entries(zio.read(sys.argv[3]), kinds=zb.DEFAULT_KINDS + (zb.KIND_HEADING,)))
plan = zl.plan_reuse(ents, rows)
print('%d %d %s' % (len(plan.reuse), len(rows),
                    ','.join(sorted({str(r.get('disposition')) for _, r in plan.reuse}))))" \
  "$CTL2" "$WR4/memory/backlog-verdicts.jsonl" "$WR4/memory/backlog.md")"
X_REUSE="$(printf '%s' "$X_CUR" | cut -d' ' -f1)"
X_NROWS="$(printf '%s' "$X_CUR" | cut -d' ' -f2)"
X_DISPS="$(printf '%s' "$X_CUR" | cut -d' ' -f3)"
if [ "$X_DISPS" = "kept" ]; then
  ok "(X3) …and _dedup resolves every entry to its DISPOSITION row, not to the pending one it superseded: all $X_REUSE current rows read 'kept'. The stamp is carried over unchanged, so 'the later write wins' holds on equal stamps rather than on a bumped clock that would claim the entry was re-verified"
else
  no "(X3) the current rows read dispositions [$X_DISPS] over $X_REUSE entries and $X_NROWS rows — the pending row is still winning, so a second apply would re-perform everything"
fi

# ==================================================================================================
# D — THE CLOSURES ARE DELEGATED, and `no-remedy` is reported rather than a false `archived`.
# ==================================================================================================
echo "-- D: closures delegated to backlog-archive.py, never written here --"

# D1, STATIC: neither this command nor its module contains a write to either backlog file. A behavioural
# assertion cannot cover the case where the write exists on a branch no fixture reaches.
python3 - "$APPLY_MOD" "$GROOM_PY" >"$T4/static.out" 2>&1 <<'PYEOF'
r"""Every write primitive in the disposition path, or `-`.

SCOPE, and the first version got it wrong: `backlog-groom.py` legitimately writes the queue and the seed
answer key from OTHER subcommands, so scanning the whole file flagged `cmd_dispatch`'s
`open(apath, "w")` as a backlog write. The apply MODULE is scanned whole (that is all it does), and in
the command file only `cmd_apply`'s own segment — which is the claim being made.
"""
import ast
import re
import sys

APPLY, GROOM = sys.argv[1], sys.argv[2]
WRITE_RE = re.compile(r"\b(atomic_write|os\.replace|os\.rename)\b")


def open_writes(src, base, offset=0):
    out = []
    for node in ast.walk(ast.parse(src)):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                and node.func.id == "open"):
            continue
        mode = next((a.value for a in node.args[1:2] if isinstance(a, ast.Constant)), "r")
        kw = next((k.value.value for k in node.keywords
                   if k.arg == "mode" and isinstance(k.value, ast.Constant)), None)
        spec = str(kw or mode)
        if "w" in spec or "a" in spec or "+" in spec:
            out.append("%s:%d open(...,%r)" % (base, node.lineno + offset, spec))
    return out


def segment(path, func):
    """The source of ONE function, and a hard error when it is absent — an empty segment would make
    every assertion about it trivially clean."""
    src = open(path, encoding="utf-8").read()
    tree = ast.parse(src)
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == func:
            lines = src.splitlines()[node.lineno - 1:node.end_lineno]
            return "\n".join(lines), node.lineno - 1
    sys.exit("static: %s has no %s()" % (path, func))


bad = []
apply_src = open(APPLY, encoding="utf-8").read()
for m in WRITE_RE.finditer(apply_src):
    bad.append("%s:%d %s" % (APPLY.rsplit("/", 1)[-1], apply_src[:m.start()].count("\n") + 1,
                             m.group(1)))
bad += open_writes(apply_src, APPLY.rsplit("/", 1)[-1])
seg, off = segment(GROOM, "cmd_apply")
print("SEGLINES=%d" % len(seg.splitlines()))
for m in WRITE_RE.finditer(seg):
    bad.append("cmd_apply:%d %s" % (seg[:m.start()].count("\n") + 1 + off, m.group(1)))
bad += open_writes("def _s():\n" + "\n".join(" " + x for x in seg.splitlines()), "cmd_apply", off)
print("WRITES=%s" % (";".join(bad) or "-"))
PYEOF
cat "$T4/static.out"
D_W="$(sed -n 's/^WRITES=//p' "$T4/static.out" | head -1)"
[ "$(sed -n 's/^SEGLINES=//p' "$T4/static.out" | head -1)" -ge 15 ] \
  && ok "(D1a) the scan really read cmd_apply's $(sed -n 's/^SEGLINES=//p' "$T4/static.out" | head -1)-line body — an empty or missing segment would make D1 trivially clean, which is why the extractor hard-errors on an absent function rather than returning nothing" \
  || no "(D1a) cmd_apply's segment measured $(sed -n 's/^SEGLINES=//p' "$T4/static.out" | head -1) lines; D1 below would be about almost no code"
if [ "$D_W" = "-" ]; then
  ok "(D1) NEITHER zuvo_backlog_apply.py NOR backlog-groom.py contains a write primitive of its own — no atomic_write, no os.replace, no open(...,'w'/'a'). The only path to backlog-done.md is the archiver subprocess, and that is a property of the SOURCE rather than of whichever branch a fixture happened to reach"
else
  no "(D1) a write primitive lives in the disposition path: $D_W — backlog-protocol.md records what the hand-written archive did (it counted LINES as items and destroyed quoted open copies), which is why this is delegated"
fi
grep -q 'subprocess.run' "$APPLY_MOD" \
  && ok "(D1b) …and it does delegate through subprocess.run, so D1 is not passing by performing no closure at all" \
  || no "(D1b) zuvo_backlog_apply.py never calls subprocess.run; then nothing is delegated and D1 is vacuous"

# D2 — THE STRONG FORM OF "WRITTEN ONLY BY THE HELPER": apply's result is BYTE-IDENTICAL to running the
# helper ALONE on a pristine copy. This is what AC8 was reaching for; its own "byte-identical open file
# beside a changed archive" cannot hold, because both helpers write both files or neither.
D_APPLY="$(mkrepo4 "$T4/bl-drop.md" "$T4/arch-drop.md")" || no "(D2a) could not build the drop repo"
D_ALONE="$(mkrepo4 "$T4/bl-drop.md" "$T4/arch-drop.md")" || no "(D2a) could not build the helper-only repo"
led4 "$D_APPLY" --default STILL-REAL --verdict B-stale-copy=STALE-FIXED >"$T4/dled.out" 2>&1
D_KEY="$(python3 -c "
import sys
sys.path.insert(0, sys.argv[1])
import zuvo_backlog_io as zio, zuvo_backlog_parse as zb
for e in zb.iter_entries(zio.read(sys.argv[2]), kinds=zb.DEFAULT_KINDS + (zb.KIND_HEADING,)):
    if e.ident == 'B-stale-copy':
        print(e.key)" "$CTL2" "$D_APPLY/memory/backlog.md")"
[ -n "$D_KEY" ] \
  && ok "(D2a) the stale open copy is filed under $D_KEY, resolved through entry_key rather than built as 'id:' plus the argument — the defect _keys_for_ids' docstring records" \
  || { no "(D2a) could not resolve the stale copy's key"; }
D_RC="$(apply4 "$CTL2" "$D_APPLY")"
cp "$T4/last.out" "$T4/d2.out"
python3 "$CTL2/backlog-archive.py" drop-stale --repo "$D_ALONE" --key "$D_KEY" >"$T4/d2alone.out" 2>&1
D_ALONE_RC=$?
if [ "$D_RC" = "0" ] && [ "$D_ALONE_RC" -eq 0 ]; then
  ok "(D2b) both runs succeeded: apply rc=$D_RC, the helper alone rc=$D_ALONE_RC — so the comparison below is between two completed closures"
else
  no "(D2b) apply rc=$D_RC ($(tail -2 "$T4/d2.out" | cut -c1-110)); helper alone rc=$D_ALONE_RC ($(tail -1 "$T4/d2alone.out" | cut -c1-110))"
fi
for f in backlog.md backlog-done.md; do
  if cmp -s "$D_APPLY/memory/$f" "$D_ALONE/memory/$f"; then
    ok "(D2/AC8) $f is BYTE-IDENTICAL between 'apply delegated it' and 'the helper did it alone' — which is the checkable form of 'written only by the helper'"
  else
    no "(D2/AC8) $f differs between the two runs: $(diff "$D_ALONE/memory/$f" "$D_APPLY/memory/$f" | head -3 | tr '\n' ' ')"
  fi
done
# …and the archive really DID change, so D2 is not comparing two untouched files.
cmp -s "$D_APPLY/memory/backlog-done.md" "$T4/arch-drop.md" \
  && no "(D2c/AC8) backlog-done.md is unchanged from the fixture, so D2 compared two files nothing wrote and AC8's 'the archive changes' half is untested here" \
  || ok "(D2c/AC8) backlog-done.md genuinely CHANGED (the open text is quoted into it verbatim), so D2's byte-equality is between two files that were both written"
grep -q '^DISPOSITION=B-stale-copy|dropped|drop-stale|' "$T4/d2.out" \
  && ok "(D2d) the disposition is 'dropped' with the verb naming drop-stale — an entry whose resolved copy is already archived is a stale duplicate, not something to archive a second time" \
  || no "(D2d) the stale copy's disposition line is $(grep '^DISPOSITION=B-stale-copy' "$T4/d2.out" | cut -c1-120)"

# D3 — no-remedy WITH A REASON, and never a false `archived`.
D_DISP="$(mkrepo4 "$T4/bl-disp.md" "")" || no "(D3a) could not build the no-remedy repo"
led4 "$D_DISP" --default STILL-REAL --verdict B-dup-a=DUPLICATE-OF --verdict B-nv-one=NOT-VERIFIABLE \
     --verdict B-nr-one=STALE-FIXED --verdict B-arch-one=STALE-FIXED >"$T4/d3led.out" 2>&1
D_RC3="$(apply4 "$CTL2" "$D_DISP" --dry-run)"
cp "$T4/last.out" "$T4/d3.out"
[ "$D_RC3" = "0" ] \
  && ok "(D3a) the five-disposition fixture applies cleanly in --dry-run (rc=$D_RC3), so every claim below is about a run that reached the decisions" \
  || no "(D3a) rc=$D_RC3: $(tail -3 "$T4/d3.out")"
d3_line(){ grep "^DISPOSITION=$1|" "$T4/d3.out" | head -1; }
d3_is(){   # subject, disposition, verb, a phrase the reason must contain, label
  local row; row="$(d3_line "$1")"
  if [ -z "$row" ]; then no "(D3) $5: no disposition line at all for $1"; return; fi
  case "$row" in
    "DISPOSITION=$1|$2|$3|"*) : ;;
    *) no "(D3) $5: $1 came back as '$row', expected $2|$3"; return ;;
  esac
  case "$row" in
    *"$4"*) ok "(D3) $5" ;;
    *) no "(D3) $5: the reason does not say '$4': $row" ;;
  esac
}
d3_is B-nr-one   no-remedy -            'NOT ticked'          "a STALE-FIXED entry no helper can act on is no-remedy, and the reason names BOTH declines (archive moves only ticked entries; drop-stale needs an archived ticked copy)"
d3_is B-dup-a    no-remedy -            'never a licence'     "DUPLICATE-OF is no-remedy with 'a REPORT, never a licence to merge' as the reason — the two entries can differ in scope and no helper can decide which text survives"
d3_is B-still-one kept     -            'still true'          "STILL-REAL is 'kept' with the reason, not silence"
d3_is B-nv-one   kept      -            'licenses nothing'    "NOT-VERIFIABLE is 'kept', so the cheap honest verdict never closes anything"
d3_is B-arch-one archived  archive      'ticked'              "a ticked STALE-FIXED entry IS archived, so D3's no-remedy cases are not passing because nothing is ever archived"
D_NOREASON="$(grep '^DISPOSITION=' "$T4/d3.out" | awk -F'|' 'NF<4 || $4 == "" {print $1}' | tr '\n' ' ')"
[ -z "$D_NOREASON" ] \
  && ok "(D3b) EVERY disposition line carries a reason, including the ones that do nothing — 'kept' and 'no-remedy' are answers an operator has to be able to audit" \
  || no "(D3b) disposition line(s) with no reason: $D_NOREASON"
[ "$(grep -c '^DISPOSITION=' "$T4/d3.out")" = "$(sed -n 's/^ENTRIES=//p' "$T4/d3.out" | head -1)" ] \
  && ok "(D3c) there is exactly ONE disposition per entry and none is omitted — the gate has already established that every entry carries a current verdict, so a missing disposition would be an entry silently left out of the run" \
  || no "(D3c) $(grep -c '^DISPOSITION=' "$T4/d3.out") disposition lines for $(sed -n 's/^ENTRIES=//p' "$T4/d3.out" | head -1) entries"
grep -q '^DISPOSED=no-remedy 2$' "$T4/d3.out" \
  && ok "(D3d) the per-disposition totals are printed and the two no-remedy rows are counted as themselves, not folded into archived" \
  || no "(D3d) the totals read $(grep '^DISPOSED=' "$T4/d3.out" | tr '\n' ' ')"

# D4/D5 — THE HEADING GATE, observed at the boundary it crosses. A STUB archiver, because the question
# is what the subprocess is HANDED and the real archiver answers a different one.
STUB_SRC="$T4/stub-archive.py"
cat > "$STUB_SRC" <<'PYEOF'
"""A stand-in for backlog-archive.py that RECORDS what it was handed and performs nothing.

The question D4/D5 ask is what crosses the process boundary — the argv and whether
ZUVO_BACKLOG_HEADING_ARCHIVE travelled — and the real archiver answers a different question (what it
would move). It logs beside ITSELF, so each stubbed module directory keeps its own log.
"""
import os
import sys

here = os.path.dirname(os.path.realpath(__file__))
with open(os.path.join(here, "stub.log"), "a", encoding="utf-8") as fh:
    fh.write("ARGV=%s\n" % " ".join(sys.argv[1:]))
    fh.write("GATE=%s\n" % os.environ.get("ZUVO_BACKLOG_HEADING_ARCHIVE", ""))
# The one line `_archive`'s scope oracle reads. One, because every stubbed fixture below intends
# exactly one archive-verb action, and a mismatch is what RC_SCOPE exists for.
print("would move 1 resolved entries out of backlog.md into backlog-done.md: "
      "1 with a recorded resolution, 0 ticked without one (separate section)")
PYEOF
stubify(){  # moddir -> a copy of it whose archiver is the stub, with a fresh log
  local out
  out="$(mktemp -d "$T4/stubXXXXXX")" || return 1        # mktemp, for the subshell reason above
  cp "$1"/*.py "$out"/ 2>/dev/null
  cp "$1/backlog-groom.py" "$out/backlog-groom.py" || return 1
  cp "$STUB_SRC" "$out/backlog-archive.py" || return 1
  : > "$out/stub.log"
  printf '%s\n' "$out"
}
D_STUB="$(stubify "$CTL2")" || no "(D4a) could not build the stubbed control directory"
D_HEAD="$(mkrepo4 "$T4/bl-head.md" "")" || no "(D4a) could not build the heading repo"
led4 "$D_HEAD" --default STILL-REAL --verdict B-head-one=STALE-FIXED >"$T4/d4led.out" 2>&1
D_RC4="$(apply4 "$D_STUB" "$D_HEAD" --dry-run)"
cp "$T4/last.out" "$T4/d4.out"
[ "$D_RC4" = "0" ] \
  && ok "(D4a) the stubbed run completed (rc=$D_RC4) — so the log below is what apply handed the archiver, not what it did after a refusal" \
  || no "(D4a) rc=$D_RC4 under the stub: $(tail -3 "$T4/d4.out")"
grep -q '^DISPOSITION=B-head-one|archived|archive|' "$T4/d4.out" \
  && ok "(D4b) the HEADING entry is the one carrying the archive verb, so the gate assertion below has a heading row to be about — a heading with a resolution marker reads 'done' because _heading_entry derives status from the marker text (24 of 82 measured), which is why PR 1 gated it" \
  || no "(D4b) the heading row is $(grep '^DISPOSITION=B-head-one' "$T4/d4.out" | cut -c1-120)"
cat "$D_STUB/stub.log"
grep -qx 'GATE=1' "$D_STUB/stub.log" \
  && ok "(D4/PR1-decision-6) ZUVO_BACKLOG_HEADING_ARCHIVE=1 DID cross into the archiver subprocess for the heading row — archiving a heading MOVES LINES, so PR 1 ships the remedy switched off and this is the one place that turns it on" \
  || no "(D4) the gate never reached the subprocess: $(tr '\n' ' ' < "$D_STUB/stub.log")"
D_NGATE="$(grep -c '^GATE=1$' "$D_STUB/stub.log")"
D_NCALL="$(grep -c '^ARGV=' "$D_STUB/stub.log")"
[ "$D_NGATE" -ge 1 ] && [ "$D_NCALL" -ge 1 ] \
  && ok "(D4c) $D_NGATE of $D_NCALL delegated call(s) carried the gate — counted, so 'it was set' cannot be satisfied by setting it on everything" \
  || no "(D4c) $D_NGATE gated of $D_NCALL calls"

# The gate must be PER-INVOCATION, never process-global. Asked in-process, because that is where the
# damage of `os.environ[...] = "1"` lives: it stays on for every later call, including a checkbox-only
# one that must not see it (`B-20260928-HEADING-GATE-PROCESS-GLOBAL`).
T4PROBE="$T4/probe4.py"
cat > "$T4PROBE" <<'PYEOF'
r"""Machine-readable probe over zuvo_backlog_apply, for the questions only an in-process call can ask.

RAW docstring for the same reason as its three siblings': a `\s` in a plain one is a SyntaxWarning on
stderr, and every caller reads stderr as "the mutant did not build".

Usage: probe4.py <moddir> gate <repo>
"""
import os
import sys

MODDIR = os.path.abspath(sys.argv[1])
sys.path.insert(0, MODDIR)
import zuvo_backlog_apply as zap    # noqa: E402

GATE = zap.HEADING_GATE
if sys.argv[2] == "gate":
    repo = sys.argv[3]
    print("BEFORE=%s" % os.environ.get(GATE, ""))
    zap._run(["status"], repo, heading=True)      # the call that legitimately wants it
    print("PARENT_AFTER=%s" % os.environ.get(GATE, ""))
    zap._run(["status"], repo, heading=False)     # a later call that must NOT see it
    print("PARENT_END=%s" % os.environ.get(GATE, ""))
else:
    sys.exit("probe4: unknown mode %r" % sys.argv[2])
PYEOF
probe4(){ python3 "$T4PROBE" "$@"; }
D_STUB2="$(stubify "$CTL2")" || no "(D5a) could not build the second stubbed directory"
probe4 "$D_STUB2" gate "$D_HEAD" >"$T4/gate.out" 2>&1 || no "(D5a) the gate probe could not run: $(tail -2 "$T4/gate.out")"
cat "$T4/gate.out" "$D_STUB2/stub.log"
if grep -qx 'BEFORE=' "$T4/gate.out" && grep -qx 'PARENT_AFTER=' "$T4/gate.out" \
   && grep -qx 'PARENT_END=' "$T4/gate.out"; then
  ok "(D5) THE GATE IS PER-INVOCATION: this process's own ZUVO_BACKLOG_HEADING_ARCHIVE is empty before the gated call, after it, and after a later ungated one. It travels in a COPY of the environment handed to one subprocess.run"
else
  no "(D5) the gate leaked into the calling process: $(tr '\n' ' ' < "$T4/gate.out") — that is B-20260928-HEADING-GATE-PROCESS-GLOBAL exactly, and it would turn heading archival on for every later delegation in the run"
fi
D_L2="$(grep '^GATE=' "$D_STUB2/stub.log" | head -2 | tr '\n' ' ')"
case "$D_L2" in
  "GATE=1 GATE= ") ok "(D5b) …and the two subprocesses saw DIFFERENT values in call order (1:gated, 2:not) — the half that a process-global set would break silently, because the call that wants the gate happens first and looks correct either way" ;;
  *) no "(D5b) the two delegated calls saw: $D_L2 — expected the first gated and the second not" ;;
esac

# D6 — THE SCOPE ORACLE. `archive` is a WHOLE-FILE action with no per-entry selection, so a ticked entry
# whose verdict is STILL-REAL would be carried out by a delegation asked for on behalf of other entries.
D_SCOPE="$(mkrepo4 "$T4/bl-scope.md" "")" || no "(D6a) could not build the scope repo"
led4 "$D_SCOPE" --default STILL-REAL --verdict B-tick-fixed=STALE-FIXED >"$T4/d6led.out" 2>&1
D_SB0="$(sha4 "$D_SCOPE/memory/backlog.md")"; D_SA0="$(sha4 "$D_SCOPE/memory/backlog-done.md")"
D_RC6="$(apply4 "$CTL2" "$D_SCOPE")"
cp "$T4/last.out" "$T4/d6.out"
if [ "$D_RC6" = "$RC_SCOPE_N" ] && [ "$D_SB0" = "$(sha4 "$D_SCOPE/memory/backlog.md")" ] \
   && [ "$D_SA0" = "$(sha4 "$D_SCOPE/memory/backlog-done.md")" ]; then
  ok "(D6) apply REFUSES rc=$D_RC6 (RC_SCOPE) when the archiver would move 2 entries where 1 carries a licensing verdict, writing nothing — the other entry is TICKED and verified STILL-REAL, and a whole-file delegation would have closed it on nobody's authority"
else
  no "(D6) rc=$D_RC6 (expected RC_SCOPE=$RC_SCOPE_N), backlog $( [ "$D_SB0" = "$(sha4 "$D_SCOPE/memory/backlog.md")" ] && echo held || echo CHANGED), archive $( [ "$D_SA0" = "$(sha4 "$D_SCOPE/memory/backlog-done.md")" ] && echo held || echo CHANGED): $(tail -2 "$T4/d6.out" | cut -c1-140)"
fi
grep -q 'whole-file action' "$T4/d6.out" \
  && ok "(D6b) …and the refusal explains WHY the two numbers may differ and what to do about it, naming the entries it intended" \
  || no "(D6b) the scope refusal does not explain itself: $(tail -2 "$T4/d6.out" | cut -c1-140)"
# The positive control on the SAME fixture: give the second entry a licensing verdict too and the same
# delegation goes through. Otherwise D6 could be passing because this fixture can never archive.
D_SCOPE_OK="$(mkrepo4 "$T4/bl-scope.md" "")" || no "(D6c) could not build the scope control repo"
led4 "$D_SCOPE_OK" --default STALE-FIXED >"$T4/d6okled.out" 2>&1
D_RC6B="$(apply4 "$CTL2" "$D_SCOPE_OK")"
if [ "$D_RC6B" = "0" ] && grep -q '^HELPER=moved 2 entries' "$T4/last.out"; then
  ok "(D6c) control: with BOTH ticked entries verified stale the same delegation moves both (rc=$D_RC6B) — so D6's refusal is attributable to the disagreement and not to the fixture"
else
  no "(D6c) rc=$D_RC6B and the helper said $(grep '^HELPER=' "$T4/last.out" | head -1 | cut -c1-110)"
fi

D_HELD="$(mkrepo4 "$T4/bl-held.md" "")" || no "(D6d) could not build the held repo"
led4 "$D_HELD" --default STALE-FIXED >"$T4/d6dled.out" 2>&1
D_HB0="$(sha4 "$D_HELD/memory/backlog.md")"
D_RC6D="$(apply4 "$CTL2" "$D_HELD")"
cp "$T4/last.out" "$T4/d6d.out"
grep -q '^DISPOSITION=B-held-one|archived|archive|' "$T4/d6d.out" \
  && ok "(D6d1) the held entry IS given the archive verb by the dispositions — it is ticked, so this is a case where apply intends a closure the archiver will refuse to perform, and not a hypothetical" \
  || no "(D6d1) the held entry's disposition is $(grep '^DISPOSITION=B-held-one' "$T4/d6d.out" | cut -c1-120)"
if [ "$D_RC6D" = "$RC_SCOPE_N" ] && [ "$D_HB0" = "$(sha4 "$D_HELD/memory/backlog.md")" ] \
   && grep -q 'printed no .would move N. line' "$T4/d6d.out"; then
  ok "(D6d/RC_SCOPE) an ABSENT count line is itself a refusal (rc=$D_RC6D), writing nothing: the archiver HOLDS a ticked entry carrying a live [ ] sub-item and prints \"nothing to do\" with no count at all, so reading a missing number as agreement would report a closure that never happened"
else
  no "(D6d/RC_SCOPE) rc=$D_RC6D (expected $RC_SCOPE_N), backlog $( [ "$D_HB0" = "$(sha4 "$D_HELD/memory/backlog.md")" ] && echo held || echo CHANGED), message $(grep -c 'printed no' "$T4/d6d.out"): $(tail -2 "$T4/d6d.out" | cut -c1-130)"
fi

# The DRY-RUN interaction, stated because it is a real limitation and not a bypass: `cmd_archive`
# refuses while an id is defined in BOTH files, which is exactly what a `dropped` entry is until
# drop-stale removes it. A real run has dropped it by then; a dry run has not.
D_BOTH="$(mkrepo4 "$T4/bl-drop.md" "$T4/arch-drop.md")" || no "(D7a) could not build the drop+archive repo"
led4 "$D_BOTH" --default STALE-FIXED >"$T4/d7led.out" 2>&1
D_RC7C="$(apply4 "$CTL2" "$D_BOTH" --dry-run)"
[ "$D_RC7C" = "0" ] && grep -q '^DISPOSITION=B-stale-copy|dropped|' "$T4/last.out" \
  && grep -q '^DISPOSITION=B-also-done|archived|' "$T4/last.out" \
  && ok "(D7a2) the fixture really licenses BOTH a drop and an archive, which is the only arrangement in which the scope oracle can be asked about a file that does not exist yet" \
  || no "(D7a2) the fixture does not license both: $(grep '^DISPOSITION=' "$T4/last.out" | tr '\n' ' ' | cut -c1-200)"
D_BB0="$(sha4 "$D_BOTH/memory/backlog.md")"
D_RC7="$(apply4 "$CTL2" "$D_BOTH" --dry-run)"
cp "$T4/last.out" "$T4/d7.out"
if [ "$D_RC7" = "0" ] && grep -q '^SCOPE=deferred' "$T4/d7.out" \
   && [ "$D_BB0" = "$(sha4 "$D_BOTH/memory/backlog.md")" ]; then
  ok "(D7) a dry run that both drops and archives SAYS the scope check could not be taken (SCOPE=deferred) and performs nothing — refusing there would make apply --dry-run unusable on every plan that does both, and pretending the check passed would be worse"
else
  no "(D7) rc=$D_RC7, deferred=$(grep -c '^SCOPE=deferred' "$T4/d7.out"), backlog $( [ "$D_BB0" = "$(sha4 "$D_BOTH/memory/backlog.md")" ] && echo held || echo CHANGED)"
fi
D_RC7B="$(apply4 "$CTL2" "$D_BOTH")"
if [ "$D_RC7B" = "0" ] && grep -q '^HELPER=removed the stale open copy' "$T4/last.out" \
   && grep -q '^HELPER=moved ' "$T4/last.out"; then
  ok "(D7b) …and the REAL run performs both in the order that makes the oracle answerable: drop-stale first (per-entry and precise), then archive over the file that is actually left"
else
  no "(D7b) rc=$D_RC7B; the real run did $(grep -c '^HELPER=' "$T4/last.out") helper line(s): $(grep '^HELPER=' "$T4/last.out" | head -2 | tr '\n' ' ' | cut -c1-150)"
fi

# ==================================================================================================
# G4 — FAIL CLOSED, in BOTH directions, in the SAME directory. Revision 5 had to correct the plan about
# exactly this: PLACEMENT fails OPEN on `is_ignored() is None` (the canonical backlog lives outside any
# repository and a refusal there would refuse every one of them), while a WRITE fails CLOSED.
# ==================================================================================================
echo "-- G4: fail closed on the write, fail OPEN on the placement, one directory --"
G4="$T4/nogit"
mkdir -p "$G4/memory" "$G4/tools"
printf 'print("present")\n' > "$G4/tools/present.py"
cp "$T4/bl-drop.md" "$G4/memory/backlog.md"
cp "$T4/arch-drop.md" "$G4/memory/backlog-done.md"
python3 -c "
import subprocess, sys
r = subprocess.run(['git', 'rev-parse', '--is-inside-work-tree'], cwd=sys.argv[1],
                   capture_output=True, text=True)
print('INSIDE=%s' % (r.stdout.strip() or 'no'))" "$G4/memory" >"$T4/g4pre.out" 2>&1
grep -qx 'INSIDE=no' "$T4/g4pre.out" \
  && ok "(G4a) the fixture directory really is outside any git repository, so is_ignored() answers None there and both directions below are about the same unknown" \
  || no "(G4a) $G4 is inside a repository ($(cat "$T4/g4pre.out")) — neither direction would be exercised"
led4 "$G4" --default STILL-REAL --verdict B-stale-copy=STALE-FIXED >"$T4/g4led.out" 2>&1
G4_B0="$(sha4 "$G4/memory/backlog.md")"; G4_A0="$(sha4 "$G4/memory/backlog-done.md")"
G4_RC="$(apply4 "$CTL2" "$G4")"
cp "$T4/last.out" "$T4/g4.out"
if [ "$G4_RC" = "$RC_NONE_N" ] && [ "$G4_B0" = "$(sha4 "$G4/memory/backlog.md")" ] \
   && [ "$G4_A0" = "$(sha4 "$G4/memory/backlog-done.md")" ]; then
  ok "(G4/CQ8) the WRITE fails CLOSED: with a closure licensed and no repository above the file, apply exits rc=$G4_RC (RC_UNKNOWN_IGNORE) and neither file moves — a closure rewrites both, and whether that is publishable is exactly what could not be determined"
else
  no "(G4/CQ8) rc=$G4_RC (expected RC_UNKNOWN_IGNORE=$RC_NONE_N), backlog $( [ "$G4_B0" = "$(sha4 "$G4/memory/backlog.md")" ] && echo held || echo CHANGED), archive $( [ "$G4_A0" = "$(sha4 "$G4/memory/backlog-done.md")" ] && echo held || echo CHANGED)"
fi
grep -q 'cannot tell whether' "$T4/g4.out" \
  && ok "(G4b) …and it says WHY and what to do instead, rather than printing a code" \
  || no "(G4b) the refusal does not explain itself: $(tail -2 "$T4/g4.out" | cut -c1-140)"
# THE OPPOSITE DIRECTION, same directory: with NO closure to perform, apply must PROCEED and write its
# dispositions. The canonical backlog legitimately lives here, and a run that refused would refuse it.
G4B="$T4/nogit-open"
mkdir -p "$G4B/memory" "$G4B/tools"
printf 'print("present")\n' > "$G4B/tools/present.py"
cp "$T4/bl-drop.md" "$G4B/memory/backlog.md"
: > "$G4B/memory/backlog-done.md"
led4 "$G4B" --default STILL-REAL >"$T4/g4bled.out" 2>&1
G4B_L0="$(wc -l < "$G4B/memory/backlog-verdicts.jsonl" | tr -d ' ')"
G4B_RC="$(apply4 "$CTL2" "$G4B")"
G4B_L1="$(wc -l < "$G4B/memory/backlog-verdicts.jsonl" | tr -d ' ')"
if [ "$G4B_RC" = "0" ] && [ "$G4B_L1" -gt "$G4B_L0" ]; then
  ok "(G4c/CQ8) …and the PLACEMENT direction fails OPEN in the very same non-repo: with nothing to close, apply proceeds (rc=$G4B_RC) and appends its dispositions ($G4B_L0 -> $G4B_L1 lines). Two opposite rules, one directory — which is what revision 5 had to correct the plan about"
else
  no "(G4c/CQ8) rc=$G4B_RC and the ledger went $G4B_L0 -> $G4B_L1 lines; if this refuses, no canonical backlog outside a repository can ever carry a disposition"
fi

# A HELD LOCK. The delegated helper takes the backlog's own lock, so a held one must stop the closure
# with nothing written — an exit code alone would not notice a partial write.
G4L="$(mkrepo4 "$T4/bl-drop.md" "$T4/arch-drop.md")" || no "(G4d) could not build the lock repo"
led4 "$G4L" --default STILL-REAL --verdict B-stale-copy=STALE-FIXED >/dev/null 2>&1
mkdir -p "$G4L/memory/.backlog-archive.lock.d"
printf '%s\n' "$$" > "$G4L/memory/.backlog-archive.lock.d/pid"
G4L_B0="$(sha4 "$G4L/memory/backlog.md")"; G4L_A0="$(sha4 "$G4L/memory/backlog-done.md")"
G4L_RC="$(apply4 "$CTL2" "$G4L")"
if [ "$G4L_RC" != "0" ] && [ "$G4L_B0" = "$(sha4 "$G4L/memory/backlog.md")" ] \
   && [ "$G4L_A0" = "$(sha4 "$G4L/memory/backlog-done.md")" ]; then
  ok "(G4d) a HELD lock makes the closure fail rc=$G4L_RC with BOTH files byte-unchanged — the lock is the archiver's own, on the real file's directory, so an archive running concurrently waits rather than interleaving"
else
  no "(G4d) rc=$G4L_RC, backlog $( [ "$G4L_B0" = "$(sha4 "$G4L/memory/backlog.md")" ] && echo held || echo CHANGED), archive $( [ "$G4L_A0" = "$(sha4 "$G4L/memory/backlog-done.md")" ] && echo held || echo CHANGED): $(tail -2 "$T4/last.out" | cut -c1-130)"
fi
grep -qE 'lock held|refused' "$T4/last.out" \
  && ok "(G4e) …and the refusal names the lock rather than reporting a generic failure" \
  || no "(G4e) the lock refusal does not name it: $(tail -2 "$T4/last.out" | cut -c1-130)"
rm -f "$G4L/memory/.backlog-archive.lock.d/pid"; rmdir "$G4L/memory/.backlog-archive.lock.d" 2>/dev/null
[ -d "$G4L/memory/.backlog-archive.lock.d" ] \
  && no "(G4f) the fixture lock could not be released" \
  || ok "(G4f) the fixture lock is released"

# ==================================================================================================
# MU4 — every Task 4 assertion dies under a mutant that reverts ONLY its behaviour.
#
# Tasks 1-3 shipped 96 of these and SIX found a real defect rather than confirming code — including one
# where the anti-fabrication control was itself fabricable. A mutant that only ever confirms is worth
# less than one that once failed, so each of these is aimed at the one line whose removal would make an
# assertion above pass for the wrong reason. The factory HARD-ERRORS when a substitution does not apply
# exactly once, which is what turns "the mutant passed" into a build failure instead of a silence.
#
# TWO OF THE EIGHTEEN ADD CODE RATHER THAN REMOVING IT, and they have to: `apply`'s central property is
# an ABSENCE (it writes nothing into the open file), and an absence cannot be reverted by deleting a
# line. `applymints` puts the pre-pass's mint back inside `apply`; `reorderwrites` adds the option-A
# re-emission decision 7 forbids. Both make the open file MOVE, which is exactly what W10/W11 assert
# it does not.
# ==================================================================================================
echo "-- MU4: each Task 4 assertion is load-bearing --"

# The scenario runner. It builds a FRESH repo every time, so a mutant that writes cannot inherit a file
# an earlier run already changed, and it prints machine-readable signature lines for the comparison.
mu4_sig(){   # moddir, backlog fixture, archive fixture, ledger args... -> RC/OPENFILE/ARCHIVE + output
  local md="$1" bl="$2" ar="$3"; shift 3
  local repo pre_b pre_a rc
  repo="$(mkrepo4 "$bl" "$ar")" || { echo "RC=fixture-failed"; return; }
  led4 "$repo" "$@" >/dev/null 2>&1
  pre_b="$(sha4 "$repo/memory/backlog.md")"; pre_a="$(sha4 "$repo/memory/backlog-done.md")"
  rc="$(apply4 "$md" "$repo")"
  printf 'RC=%s\n' "$rc"
  printf 'OPENFILE=%s\n' "$( [ "$pre_b" = "$(sha4 "$repo/memory/backlog.md")" ] && echo held || echo MOVED)"
  printf 'ARCHIVE=%s\n' "$( [ "$pre_a" = "$(sha4 "$repo/memory/backlog-done.md")" ] && echo held || echo MOVED)"
  printf 'DISPOSED_IN_LEDGER=%s\n' \
    "$(grep -c '"disposition": "\(kept\|archived\|dropped\|no-remedy\)"' "$repo/memory/backlog-verdicts.jsonl" 2>/dev/null || echo 0)"
  cat "$T4/last.out"
}
# BOTH directions guard against a mute control. A comparison whose control never produced the pattern
# measures nothing, and reporting that as "the mutant failed" is how a decorative assertion survives.
mu4_gone(){  # kind, label, ERE the CONTROL produces and the mutant must NOT, then mu4_sig args
  local kind="$1" lbl="$2" pat="$3"; shift 3
  if ! mut2_build "$kind"; then mut2_failed "$kind"; return; fi
  local ctl mut
  ctl="$(mu4_sig "$CTL2" "$@" 2>&1)"
  mut="$(mu4_sig "$T2/mut-$kind" "$@" 2>&1)"
  if ! printf '%s\n' "$ctl" | grep -qE -- "$pat"; then
    no "(MU4) $lbl: the CONTROL does not produce /$pat/ either, so this comparison measures nothing"
  elif printf '%s\n' "$mut" | grep -qE -- "$pat"; then
    no "(MU4) $lbl: the mutant STILL produces /$pat/ — the assertion is decorative"
  else
    ok "(MU4) $lbl: /$pat/ vanishes under the mutant while the control produces it — load-bearing"
  fi
}
mu4_new(){   # kind, label, ERE only the MUTANT may produce, then mu4_sig args
  local kind="$1" lbl="$2" pat="$3"; shift 3
  if ! mut2_build "$kind"; then mut2_failed "$kind"; return; fi
  local ctl mut
  ctl="$(mu4_sig "$CTL2" "$@" 2>&1)"
  mut="$(mu4_sig "$T2/mut-$kind" "$@" 2>&1)"
  if printf '%s\n' "$ctl" | grep -qE -- "$pat"; then
    no "(MU4) $lbl: the CONTROL already produces /$pat/, so the mutant's appearance is not attributable"
  elif printf '%s\n' "$mut" | grep -qE -- "$pat"; then
    ok "(MU4) $lbl: the mutant produces /$pat/ where the control does not — load-bearing"
  else
    no "(MU4) $lbl: the mutant produced no /$pat/, so the control's clean result is not attributable to this code"
  fi
}

SHORT_LED=( "$T4/bl-disp.md" "" --default STILL-REAL --skip 1 )
FULL_LED=(  "$T4/bl-disp.md" "" --default STILL-REAL )
MINT_LED=(  "$T4/bl-mint.md" "" --default STILL-REAL --rank )
SCOPE_LED=( "$T4/bl-scope.md" "" --default STILL-REAL --verdict B-tick-fixed=STALE-FIXED )
DROP_LED=(  "$T4/bl-drop.md" "$T4/arch-drop.md" --default STILL-REAL
            --verdict B-stale-copy=STALE-FIXED )
DISP_LED=(  "$T4/bl-disp.md" "" --default STILL-REAL --verdict B-dup-a=DUPLICATE-OF
            --verdict B-nv-one=NOT-VERIFIABLE --verdict B-nr-one=STALE-FIXED
            --verdict B-arch-one=STALE-FIXED )

# --- THE GATE: three independently breakable halves, one mutant each. ------------------------------
mu4_gone nogate       "P2/AC7 the refusal itself"                        "^RC=$RC_UNVER\$" "${SHORT_LED[@]}"
mu4_gone gateonkeys   "P2/AC7 coverage is text_sha-EXACT, never key-only" "^RC=$RC_UNVER\$" "${SHORT_LED[@]}"
mu4_gone shortunnamed "P2c/AC7 the shortfall is NAMED by id"             '^UNVERIFIED='    "${SHORT_LED[@]}"
# The defective-ledger refusal needs a ledger that HAS a defect, so it gets its own scenario rather than
# a shared one — mu4_gone's mute-control guard would otherwise (correctly) report the comparison as
# measuring nothing, which is a worse outcome than writing the six lines.
MU_BADREPO="$(mkrepo4 "$T4/bl-disp.md" "")" || no "(MU4) could not build the corrupt-ledger mutant repo"
led4 "$MU_BADREPO" --default STILL-REAL >/dev/null 2>&1
printf '%s\n' 'not json at all' >> "$MU_BADREPO/memory/backlog-verdicts.jsonl"
if mut2_build ledgerlax; then
  MU_LEDCTL="$(apply4 "$CTL2" "$MU_BADREPO")"
  MU_LEDMUT="$(apply4 "$T2/mut-ledgerlax" "$MU_BADREPO")"
  [ "$MU_LEDCTL" = "$RC_LED" ] && [ "$MU_LEDMUT" != "$RC_LED" ] \
    && ok "(MU4) P4 the defective-ledger refusal: the control exits RC_LEDGER=$MU_LEDCTL and the mutant $MU_LEDMUT — an unreadable line that might have said STILL-REAL would otherwise be acted on" \
    || no "(MU4) P4: control rc=$MU_LEDCTL (expected $RC_LED), mutant rc=$MU_LEDMUT — the refusal is not attributable to that line"
else
  mut2_failed ledgerlax
fi

# --- THE WRITE DISCIPLINE: the two mutants that put a write back into `apply`. ----------------------
mu4_new applymints    "W10/AC8 apply's own write set into the open file is EMPTY" \
        '^OPENFILE=MOVED$' "${MINT_LED[@]}"
mu4_new reorderwrites "W11 a ledger asking for a reorder moves no line" \
        '^OPENFILE=MOVED$' "${MINT_LED[@]}"

# --- THE DISPOSITIONS that must never report a closure that did not happen. ------------------------
mu4_new  falsearchived   "D3 no-remedy is never a false archived" \
         '^DISPOSITION=B-nr-one\|archived\|' "${DISP_LED[@]}"
mu4_gone dupismerge      "D3 DUPLICATE-OF is a report, never a licence to merge" \
         'never a licence' "${DISP_LED[@]}"
mu4_gone stillrealcloses "D3 STILL-REAL is kept, not closed" \
         '^DISPOSITION=B-still-one\|kept\|' "${DISP_LED[@]}"

# --- THE DELEGATION: the scope oracle, both of its halves, and the key selection. ------------------
mu4_gone noscope    "D6 the scope oracle refuses a set the verdicts did not license" \
                    "^RC=$RC_SCOPE_N\$" "${SCOPE_LED[@]}"
# `nomoveline` needs the scenario where the count line is genuinely ABSENT — over SCOPE_LED the line is
# present and the refusal comes from the comparison instead, so the mutant would refuse for the same
# reason as the control and the comparison would measure nothing.
HELD_LED=( "$T4/bl-held.md" "" --default STALE-FIXED )
mu4_gone nomoveline "D6d an ABSENT 'would move N' line is itself a refusal, never a pass" \
                    "^RC=$RC_SCOPE_N\$" "${HELD_LED[@]}"
mu4_new  dropunkeyed "D2d only the dropped rows are handed to drop-stale" \
         '^RC=[1-9]' "${DROP_LED[@]}"

# --- THE DISPOSITION WRITE-BACK, and the stamp it must not bump. -----------------------------------
mu4_gone nodisposition "X2/X3 the disposition really is written back into the ledger" \
         '^DISPOSED_IN_LEDGER=[1-9]' "${FULL_LED[@]}"
# The stamp is carried over UNCHANGED. Bumping it would claim the entry was re-VERIFIED by the run that
# merely acted on it — and `_dedup` compares these as strings, so the bumped row still wins and the
# corruption is invisible to every other assertion here. Asked directly against the fixture's own stamp.
MU_STAMPREPO="$(mkrepo4 "$T4/bl-disp.md" "")" || no "(MU4) could not build the stamp repo"
led4 "$MU_STAMPREPO" --default STILL-REAL >/dev/null 2>&1
apply4 "$CTL2" "$MU_STAMPREPO" >/dev/null
MU_STAMPS="$(python3 -c "
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding='utf-8') if l.strip()]
print(len({r['verified_at'] for r in rows}))" "$MU_STAMPREPO/memory/backlog-verdicts.jsonl")"
[ "$MU_STAMPS" = "1" ] \
  && ok "(X4) every row in the ledger — the verdicts AND the dispositions appended beside them — carries ONE verified_at, the fixture's own: acting on a verdict is not re-verifying it, and _dedup compares these as strings so a bumped stamp would win silently" \
  || no "(X4) the ledger holds $MU_STAMPS distinct verified_at stamps after apply; the disposition row bumped the clock"
if mut2_build bumpstamp; then
  MU_STAMPREPO2="$(mkrepo4 "$T4/bl-disp.md" "")" || no "(MU4) could not build the second stamp repo"
  led4 "$MU_STAMPREPO2" --default STILL-REAL >/dev/null 2>&1
  apply4 "$T2/mut-bumpstamp" "$MU_STAMPREPO2" >/dev/null
  MU_STAMPS2="$(python3 -c "
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding='utf-8') if l.strip()]
print(len({r['verified_at'] for r in rows}))" "$MU_STAMPREPO2/memory/backlog-verdicts.jsonl")"
  [ "$MU_STAMPS2" != "1" ] \
    && ok "(MU4) X4 the carried-over stamp: the mutant leaves $MU_STAMPS2 distinct stamps where the control leaves 1, so X4 measures that one line" \
    || no "(MU4) X4: the bumpstamp mutant also left $MU_STAMPS2 stamp(s) — X4 is decorative"
else
  mut2_failed bumpstamp
fi

# --- FAIL CLOSED, in OPPOSITE directions, one mutant each. -----------------------------------------
if mut2_build noguardwrite; then
  MU_G4="$T4/nogit-mut"
  mkdir -p "$MU_G4/memory" "$MU_G4/tools"
  printf 'print("present")\n' > "$MU_G4/tools/present.py"
  cp "$T4/bl-drop.md" "$MU_G4/memory/backlog.md"
  cp "$T4/arch-drop.md" "$MU_G4/memory/backlog-done.md"
  led4 "$MU_G4" --default STILL-REAL --verdict B-stale-copy=STALE-FIXED >/dev/null 2>&1
  MU_G4RC="$(apply4 "$T2/mut-noguardwrite" "$MU_G4")"
  [ "$MU_G4RC" != "$RC_NONE_N" ] \
    && ok "(MU4) G4/CQ8 the write's is_ignored() is None refusal: the mutant exits $MU_G4RC where the control refuses $RC_NONE_N, so the fail-CLOSED direction is that one line and not an accident of the fixture" \
    || no "(MU4) G4/CQ8: the mutant also exited $MU_G4RC — the refusal does not come from that check"
else
  mut2_failed noguardwrite
fi
if mut2_build guardalways; then
  MU_G4B="$T4/nogit-mut-open"
  mkdir -p "$MU_G4B/memory" "$MU_G4B/tools"
  printf 'print("present")\n' > "$MU_G4B/tools/present.py"
  cp "$T4/bl-drop.md" "$MU_G4B/memory/backlog.md"
  : > "$MU_G4B/memory/backlog-done.md"
  led4 "$MU_G4B" --default STILL-REAL >/dev/null 2>&1
  MU_G4BRC="$(apply4 "$T2/mut-guardalways" "$MU_G4B")"
  [ "$MU_G4BRC" = "$RC_NONE_N" ] \
    && ok "(MU4) G4c/CQ8 the OTHER direction: guarding unconditionally makes the mutant refuse rc=$MU_G4BRC a run that writes into NEITHER backlog file — which would refuse every canonical backlog, and is exactly the fail-OPEN rule revision 5 had to correct the plan about" \
    || no "(MU4) G4c/CQ8: the unconditional-guard mutant exited $MU_G4BRC rather than $RC_NONE_N, so G4c is not measuring the condition on that guard"
else
  mut2_failed guardalways
fi

# --- THE HEADING GATE, through the in-process probe: a process-global set is invisible from outside. -
mu4_gate(){  # kind, label, ERE, direction (gone|new)
  local kind="$1" lbl="$2" pat="$3" dir="$4" sd out
  if ! mut2_build "$kind"; then mut2_failed "$kind"; return; fi
  sd="$(stubify "$T2/mut-$kind")" || { no "(MU4) $lbl: could not stub the mutant directory"; return; }
  probe4 "$sd" gate "$D_HEAD" >"$T4/gate-$kind.out" 2>&1
  out="$(cat "$T4/gate-$kind.out" "$sd/stub.log" 2>&1)"
  if [ "$dir" = "gone" ]; then
    printf '%s\n' "$out" | grep -qE -- "$pat" \
      && no "(MU4) $lbl: the mutant still produces /$pat/ — the assertion is decorative" \
      || ok "(MU4) $lbl: /$pat/ vanishes under the mutant, so the control's result is attributable to that line"
  else
    printf '%s\n' "$out" | grep -qE -- "$pat" \
      && ok "(MU4) $lbl: the mutant produces /$pat/ where the control does not — load-bearing" \
      || no "(MU4) $lbl: the mutant produced no /$pat/, so the control's clean result is not attributable to this code"
  fi
}
mu4_gate nogateenv    "D4 the gate reaches the archiver subprocess"           '^GATE=1$'         gone
mu4_gate gateexported "D5 the gate is PER-INVOCATION, never process-global"   '^PARENT_AFTER=1$' new

if python3 "$MKMUT2" "$SCRIPTS" no-such-task-4-mutation "$T4/mut-bogus" >/dev/null 2>&1; then
  no "(MU4-0) the factory accepted an unknown mutation and wrote a copy — every 'the mutant failed' above could mean 'the mutation was never made'"
else
  ok "(MU4-0) the factory still hard-errors on a mutation it cannot apply, which is what makes the Task 4 mutations above statements about mutated code"
fi

if python3 "$MKMUT2" "$SCRIPTS" no-such-mutation "$T2/mut-bogus" >/dev/null 2>&1; then
  no "(MU0) the Task 2 factory accepted an unknown mutation and wrote a copy — every 'the mutant passed' above could mean 'the mutation was never made'"
else
  ok "(MU0) the Task 2 factory hard-errors on a mutation it cannot apply"
fi

# ==================================================================================================
echo
# ==================================================================================================
echo "== Task 5: the working document and the read-only fleet lane =="

T5="$FIX/t5"
mkdir -p "$T5"
RENDER_MOD="$SCRIPTS/zuvo_backlog_render.py"
SCORE_MOD="$SCRIPTS/zuvo_backlog_score.py"
FLEET_MOD="$SCRIPTS/zuvo_backlog_fleet.py"
for f in "$RENDER_MOD" "$SCORE_MOD" "$FLEET_MOD"; do
  [ -f "$f" ] && ok "(R0) present: ${f#"$ROOT"/}" || { no "(R0) missing: ${f#"$ROOT"/} — nothing in this half can be checked"; finish; }
done
# The mutant factory copies `zuvo_backlog_*.py` by GLOB, so the three new modules travel into every
# mutant directory by existing. Asserted rather than assumed: a manual list is what cost this repo the
# identical ModuleNotFoundError twice, an import error wearing a mutation's clothes.
for b in zuvo_backlog_render.py zuvo_backlog_score.py zuvo_backlog_fleet.py; do
  [ -f "$CTL2/$b" ] && ok "(R0b) the control mutant directory carries $b — the factory's glob picked it up, so a Task 5 mutant below is a mutation and not an absence" \
    || { no "(R0b) $CTL2 has no $b; every Task 5 mutant would die on an import error that reads exactly like a mutation"; finish; }
done

# THE THREE NEW EXIT CODES, READ FROM THE MODULE. P0/P0b/P0c above already assert the SET properties
# (disjoint from {0,1,2,10,11,12}, pairwise distinct) over whatever the registry holds, so these three
# are covered there by existing; what is read here is their VALUES, so no assertion below can pass
# against a stale literal.
RC_PART="$(sed -n 's/.*RC_PARTIAL=\([0-9]*\).*/\1/p' "$T4/codes.out" | head -1)"
RC_FLEET_N="$(sed -n 's/.*RC_FLEET=\([0-9]*\).*/\1/p' "$T4/codes.out" | head -1)"
RC_INDEX_N="$(sed -n 's/.*RC_INDEX=\([0-9]*\).*/\1/p' "$T4/codes.out" | head -1)"
[ -n "$RC_PART" ] && [ -n "$RC_FLEET_N" ] && [ -n "$RC_INDEX_N" ] \
  && ok "(R0c) the three Task 5 codes are READ from zuvo_backlog_prepass (partial=$RC_PART fleet=$RC_FLEET_N index=$RC_INDEX_N), and P0b/P0c already prove the whole registry is disjoint from {0,1,2,10,11,12} and pairwise distinct" \
  || { no "(R0c) could not read RC_PARTIAL/RC_FLEET/RC_INDEX from the registry: $(cat "$T4/codes.out" | tr '\n' ' ')"; finish; }

# --------------------------------------------------------------------------------------------------
# THE GOLDEN FIXTURE. Four entries, one per thing the document has to do: a high-severity entry whose
# own words name a risk, an undecidable one, a low-severity one, and a ticked+resolved one. Every
# block is ONE line and under 500 bytes, so every Effort band is 1 and the three scores are
# hand-computable — which is what makes the golden file below hand-authorable.
# --------------------------------------------------------------------------------------------------
cat > "$T5/bl-golden.md" <<'BLEOF'
# Backlog

## Open

- [ ] B-g-still [high] services/pay.ts:12 retry loop unbounded — security leak risk
- [ ] B-g-nv tools/present.py behaviour cannot be decided from the tree
- [ ] B-g-low [low] docs/readme.md stale wording in the intro
- [x] B-g-fixed api/auth.ts guard added — FIXED abc1234
BLEOF

# A fresh repo per scenario, NEVER a reused one, and `mktemp -d` rather than a counter: every caller
# invokes this through `$( )`, which is a SUBSHELL, so a counter increment is discarded and every call
# returns the SAME directory. That is the defect Task 4's own positive control found — it made a
# byte-equality check compare a file with itself and pass — and it is the third appearance of the
# subshell-discard class in this plan.
mkrepo5(){   # $1 = backlog fixture -> prints the repo dir
  local d
  d="$(mktemp -d "$T5/rXXXXXX")" || return 1
  mkdir -p "$d/memory" "$d/tools" "$d/services" "$d/docs" "$d/api" || return 1
  ( cd "$d" && git init -q . >/dev/null 2>&1 ) || return 1
  printf 'print("present")\n' > "$d/tools/present.py"
  cp "$1" "$d/memory/backlog.md" || return 1
  : > "$d/memory/backlog-done.md"
  printf '%s\n' "$d"
}
# `render` writes under $ZUVO_DIR, which `zuvo_dir()` derives from the git root unless
# ZUVO_OUTPUT_DIR overrides it. The override is used everywhere below so no scenario can write into
# this checkout's own zuvo/ tree and read another scenario's report back.
render5(){   # moddir, repo, outdir, extra args... -> writes $T5/last.out, echoes the rc
  local md="$1" repo="$2" out="$3"; shift 3
  ZUVO_OUTPUT_DIR="$out" python3 "$md/backlog-groom.py" render --repo "$repo" "$@" \
    >"$T5/last.out" 2>&1
  printf '%s\n' "$?"
}
led5(){      # repo, mkledger args... -> builds the repo's own ledger through the LEDGER's own keys
  local repo="$1"; shift
  python3 "$MKLED" "$CTL2" "$repo/memory/backlog.md" "$repo/memory/backlog-verdicts.jsonl" "$@"
}
reportof(){ sed -n 's/^REPORT=//p' "$T5/last.out" | head -1; }

# THE CENSUS FIRST. Every assertion below is about a NON-EMPTY subject, and the numbers are derived
# from the fixture's bytes rather than restated from this comment.
GR="$(mkrepo5 "$T5/bl-golden.md")" || no "(R1) could not build the golden fixture repo"
led5 "$GR" --default STILL-REAL --verdict B-g-nv=NOT-VERIFIABLE --verdict B-g-fixed=STALE-FIXED \
  >"$T5/gled.out" 2>&1
cat "$T5/gled.out"
G_TOTAL="$(sed -n 's/.*ENTRIES=//p' "$T5/gled.out" | head -1)"
G_ROWS="$(sed -n 's/^LEDGER_ROWS=\([0-9]*\).*/\1/p' "$T5/gled.out" | head -1)"
[ "${G_TOTAL:-0}" = "4" ] && [ "${G_ROWS:-0}" = "4" ] \
  && ok "(R1) the golden fixture censuses to $G_TOTAL entries with a ledger covering all $G_ROWS — derived from the bytes, so the golden compare below is over a known, non-empty document" \
  || no "(R1) the fixture censuses to ${G_TOTAL:-?} entries / ${G_ROWS:-?} rows, expected 4/4 — the golden file describes a different document"

# ==================================================================================================
# AC9 — `render` REFUSES below full verification unless `--partial`, and `--partial` keeps the
# coverage ratio while LOSING the ranking. Decision 11.
#
# THE POSITIVE CONTROL FIRST, on the same fixture: a complete ledger must render, or the refusal below
# would be attributable to the fixture rather than to the missing row.
# ==================================================================================================
echo "-- AC9: the render gate, and what --partial keeps and loses --"
G_RC="$(render5 "$CTL2" "$GR" "$T5/out-full")"
G_DOC="$(reportof)"
if [ "$G_RC" = "0" ] && [ -f "$G_DOC" ]; then
  ok "(R2a/AC9) control: with a COMPLETE ledger render exits 0 and writes $(basename "$G_DOC") — so the refusal below is attributable to coverage and not to the fixture"
else
  no "(R2a/AC9) a complete ledger did not render (rc=$G_RC doc='$G_DOC'): $(tail -3 "$T5/last.out")"
fi
grep -q '^VERIFIED=4/4$' "$T5/last.out" \
  && ok "(R2b/AC9) …and it reports VERIFIED=4/4, so 'complete' is a number the run printed rather than an assumption" \
  || no "(R2b/AC9) the control run does not report full coverage: $(grep '^VERIFIED=' "$T5/last.out")"
grep -q '^## Ranking$' "$G_DOC" 2>/dev/null \
  && ok "(R2c/AC9) the fully verified document HAS a '## Ranking' section — the vacuity guard for R4c below, which asserts its ABSENCE" \
  || no "(R2c/AC9) the fully verified document has no ranking section, so R4c's absence assertion would pass for the wrong reason"
# The filename is read from the run's own REPORT= line and never recomputed. `date +%F` is the LOCAL
# date and `generated_at` is aware UTC; a test that recomputed either would go red for several hours a
# day for a reason that has nothing to do with the code.
case "$(basename "$G_DOC")" in
  backlog-groomed-????-??-??.md) ok "(R2d/AC9) the report name is $(basename "$G_DOC") under $(dirname "$G_DOC" | sed "s|$T5|\$T5|") — derived from the run's own REPORT= line, never from a second \`date\` call" ;;
  *) no "(R2d/AC9) unexpected report name $(basename "$G_DOC")" ;;
esac

# The partial case: a ledger covering all but one entry of the SAME file.
PR5="$(mkrepo5 "$T5/bl-golden.md")" || no "(R3a/AC9) could not build the partial-ledger repo"
led5 "$PR5" --default STILL-REAL --verdict B-g-nv=NOT-VERIFIABLE --verdict B-g-fixed=STALE-FIXED \
  --skip 1 >"$T5/pled.out" 2>&1
P5_ROWS="$(sed -n 's/^LEDGER_ROWS=\([0-9]*\).*/\1/p' "$T5/pled.out" | head -1)"
[ "${P5_ROWS:-0}" = "$((G_TOTAL - 1))" ] \
  && ok "(R3a/AC9) the partial ledger covers $P5_ROWS of $G_TOTAL entries — all but ONE, derived" \
  || no "(R3a/AC9) the partial ledger covers ${P5_ROWS:-?} of $G_TOTAL rows; AC9 needs a genuine shortfall"
P5_RC="$(render5 "$CTL2" "$PR5" "$T5/out-refuse")"
cp "$T5/last.out" "$T5/ac9-refuse.out"
if [ "$P5_RC" = "$RC_PART" ]; then
  ok "(R3b/AC9) render REFUSES a ledger covering $P5_ROWS of $G_TOTAL, exiting rc=$P5_RC (RC_PARTIAL) — its OWN code, not apply's RC_UNVERIFIED=$RC_UNVER, because 'verify the rest' and 'pass --partial' are different remedies"
else
  no "(R3b/AC9) rc=$P5_RC, expected RC_PARTIAL=$RC_PART: $(tail -3 "$T5/ac9-refuse.out")"
fi
[ "$RC_PART" != "$RC_UNVER" ] \
  && ok "(R3c/AC9) …and RC_PARTIAL ($RC_PART) is not RC_UNVERIFIED ($RC_UNVER), so an operator who greps the code of a failing run learns which gate fired" \
  || no "(R3c/AC9) RC_PARTIAL and RC_UNVERIFIED are the same number — the two refusals are indistinguishable"
P5_NAMED="$(grep -c '^UNVERIFIED=' "$T5/ac9-refuse.out")"
[ "$P5_NAMED" = "1" ] \
  && ok "(R3d/AC9) the shortfall is NAMED and it is exactly one line: $(grep '^UNVERIFIED=' "$T5/ac9-refuse.out" | head -1)" \
  || no "(R3d/AC9) $P5_NAMED UNVERIFIED= lines for a one-entry shortfall"
grep -q 'pass --partial' "$T5/ac9-refuse.out" \
  && ok "(R3e/AC9) …and the refusal says what to run instead, which is the difference between a gate and a wall" \
  || no "(R3e/AC9) the refusal does not name --partial: $(tail -1 "$T5/ac9-refuse.out" | cut -c1-140)"
if [ -z "$(ls -A "$T5/out-refuse" 2>/dev/null)" ]; then
  ok "(R3f/AC9) the refusing run wrote NO document at all — an exit code alone would not notice a report written before the gate"
else
  no "(R3f/AC9) the refusal left files behind: $(find "$T5/out-refuse" -type f | head -3 | tr '\n' ' ')"
fi

# ...and the same ledger WITH --partial.
P5_RC2="$(render5 "$CTL2" "$PR5" "$T5/out-partial" --partial)"
P5_DOC="$(reportof)"
if [ "$P5_RC2" = "0" ] && [ -f "$P5_DOC" ]; then
  ok "(R4a/AC9) --partial renders the same ledger, exit 0 — the flag is the escape and the refusal above is not a dead end"
else
  no "(R4a/AC9) --partial did not render (rc=$P5_RC2): $(tail -3 "$T5/last.out")"
fi
if grep -q "^coverage: $P5_ROWS/$G_TOTAL (" "$P5_DOC" 2>/dev/null \
   && grep -q "PARTIAL VERIFICATION.*$P5_ROWS of $G_TOTAL" "$P5_DOC"; then
  ok "(R4b/AC9) the COVERAGE RATIO is stamped into the document TWICE — the machine-readable \`coverage: $P5_ROWS/$G_TOTAL\` provenance field and the human banner — so a reader cannot miss that this describes a subset"
else
  no "(R4b/AC9) the coverage ratio is not in the document: $(grep -n 'coverage:\|PARTIAL' "$P5_DOC" | head -2 | tr '\n' ' ')"
fi
grep -q '^## Ranking$' "$P5_DOC" 2>/dev/null \
  && no "(R4c/AC9) the --partial document STILL carries a '## Ranking' section — decision 11 omits the ranking, and R2c proved the full document does carry one, so this is the behaviour and not the fixture" \
  || ok "(R4c/AC9) the --partial document has NO '## Ranking' section, while the fully verified one does (R2c) — the ranking is omitted, not merely empty"
grep -q '^RANKING=omitted$' "$T5/last.out" \
  && ok "(R4d/AC9) …and the run SAYS so on stdout (RANKING=omitted), so the omission is reportable rather than only observable in the bytes" \
  || no "(R4d/AC9) the --partial run does not report RANKING=omitted: $(grep '^RANKING=' "$T5/last.out")"
if grep -q '^## Unverified$' "$P5_DOC" 2>/dev/null \
   && grep -q "^- \`$(grep '^UNVERIFIED=' "$T5/ac9-refuse.out" | head -1 | sed 's/^UNVERIFIED=//')\`\$" "$P5_DOC"; then
  ok "(R4e/AC9) the one unverified entry is NAMED in its own '## Unverified' section — named, never rendered, so the document does not silently describe a subset of its own source"
else
  no "(R4e/AC9) the --partial document does not name the unverified entry: $(grep -A3 '^## Unverified' "$P5_DOC" | head -4 | tr '\n' ' ')"
fi
P5_BODY="$(grep -c '^| [0-9]* | B-g-' "$P5_DOC" || true)"
[ "${P5_BODY:-1}" = "0" ] \
  && ok "(R4f/AC9) and NO ranked table row survives either — the section heading and its rows go together, so grepping for the heading alone cannot pass over a headless table" \
  || no "(R4f/AC9) $P5_BODY ranked table row(s) remain in the --partial document"

# ==================================================================================================
# AC10 — the provenance is DETECTABLE FROM THE DOCUMENT ALONE. The check below is EXTRACTED from the
# document's own fenced block, never retyped here: "a reader holding only the report can tell" is the
# claim, and a hand-written checker in the test would prove a different one.
# ==================================================================================================
echo "-- AC10: source sha256, coverage and version in the header, and a self-check that travels with it --"
for field in 'source: ' 'source_sha256: ' 'source_bytes: ' 'coverage: ' 'generated_by: ' 'generated_at: '; do
  grep -q "^$field" "$G_DOC" \
    && ok "(R5a/AC10) the header carries \`${field% }\`: $(grep -m1 "^$field" "$G_DOC" | cut -c1-96)" \
    || no "(R5a/AC10) the header has no \`${field% }\` line — decision 12 needs the source sha, the coverage count and the generating version"
done
grep -qE '^generated_by: backlog-groom.py render \((zuvo [0-9]|unversioned install, code sha256 [0-9a-f]{12})' "$G_DOC" \
  && ok "(R5b/AC10) …and the generating version is a real identifier (a plugin version, or a code sha256 when the flattened ~/.zuvo/ install has no package.json) rather than the word unknown, which would make the field unfalsifiable" \
  || no "(R5b/AC10) generated_by is not an identifiable version: $(grep -m1 '^generated_by:' "$G_DOC")"

# The self-check, taken out of the document by position, not by content.
AC10="$T5/selfcheck.py"
awk '/^python3 - "\$REPORT" <<.EOF.$/{f=1;next} f&&/^EOF$/{exit} f{print}' "$G_DOC" > "$AC10"
AC10_N="$(awk 'END{print NR}' "$AC10")"
[ "${AC10_N:-0}" -ge 5 ] \
  && ok "(R5c/AC10) the self-check was EXTRACTED from the document ($AC10_N lines between its own heredoc markers) — a checker retyped in this suite would prove a different claim than 'detectable from the document alone'" \
  || no "(R5c/AC10) only ${AC10_N:-0} lines came out of the document's self-check block; nothing below is about the document's own command"
AC10_OK="$(python3 "$AC10" "$G_DOC" 2>&1)"
[ "$AC10_OK" = "MATCH" ] \
  && ok "(R5d/AC10) the document's own command answers MATCH against an untouched source — the positive control, without which MISMATCH below could mean the command is simply broken" \
  || no "(R5d/AC10) the document's own self-check says '$AC10_OK' on an untouched source"
# ONE BYTE. Not a rewrite: the claim is that the header detects a change, and a change big enough to
# notice by eye would not test that.
python3 - "$GR/memory/backlog.md" <<'PYEOF'
import sys
p = sys.argv[1]
with open(p, "rb") as fh:
    raw = fh.read()
assert raw.count(b"stale wording") == 1
with open(p, "wb") as fh:
    fh.write(raw.replace(b"stale wording", b"stale wordinG"))
PYEOF
AC10_BAD="$(python3 "$AC10" "$G_DOC" 2>&1)"
case "$AC10_BAD" in
  MISMATCH*) ok "(R5e/AC10) after ONE byte changed in memory/backlog.md the same command answers '$(printf '%s' "$AC10_BAD" | cut -c1-72)…' — the mismatch is detectable with nothing in hand but the report" ;;
  *) no "(R5e/AC10) a one-byte source change was NOT detected: '$AC10_BAD'" ;;
esac

# ==================================================================================================
# THE GOLDEN FILE. Hand-authored from `prioritize`'s formula and the fixture's measurable properties,
# committed here, and COMPARED AGAINST — never refreshed by the run that asserts it. The scores were
# computed by hand before the renderer was run: every block is one line under 500 bytes so Effort is
# 1 throughout, `high`+`security` gives (5+5)x5 = 50, no severity and no risk word gives (3+3)x5 = 30,
# and `low` with no risk word gives (1+1)x5 = 10.
#
# WHAT IS NORMALISED, and why that is not a loophole: `source:`, `ledger:` and the repo path are
# mktemp paths; `source_sha256:`/`source_bytes:` describe a temp file; `generated_at:` is a clock and
# `generated_by:` a version. Each of those is asserted separately above (R5a-R5e). Everything the
# renderer DECIDES — section order, the caveat, every table row, the cluster order, the suggestions
# and the counts — is compared byte for byte.
# ==================================================================================================
echo "-- the golden document: hand-authored, compared against, never regenerated --"
cat > "$T5/golden.md" <<'GOLDEOF'
# Groomed backlog

## Provenance

```
source: <SRC>
source_sha256: <SHA256>
source_bytes: <N>
entries: 4
coverage: 4/4 (100.0%)
mode: full
ledger: <LEDGER>
ledger_rows: 4
ledger_defects: 0
generated_by: <GEN>
generated_at: <AT>
```

## Coverage

| Verdict | Entries |
|---|---|
| `STILL-REAL` | 2 |
| `STALE-FIXED` | 1 |
| `STALE-OBSOLETE` | 0 |
| `DUPLICATE-OF` | 0 |
| `NOT-VERIFIABLE` | 1 |

| Disposition | Entries |
|---|---|
| `pending` | 4 |
| `archived` | 0 |
| `dropped` | 0 |
| `kept` | 0 |
| `no-remedy` | 0 |

## Ranking

Impact, Risk and Effort are **derived from the bytes**, never judged: Impact comes from the entry's declared severity word, Risk from a small named vocabulary in its own text, Effort from its block size. The formula and the 2-50 range are `zuvo:backlog prioritize`'s, unchanged. A derived score is a reading order, not an assessment.

| Rank | ID | Score | Impact | Risk | Effort | Verdict | Entry |
|---|---|---|---|---|---|---|---|
| 1 | B-g-still | 50 | 5 | 5 | 1 | STILL-REAL | B-g-still [high] services/pay.ts:12 retry loop unbounded — security leak risk |
| 2 | B-g-nv | 30 | 3 | 3 | 1 | NOT-VERIFIABLE | B-g-nv tools/present.py behaviour cannot be decided from the tree |
| 3 | B-g-low | 10 | 1 | 1 | 1 | STILL-REAL | B-g-low [low] docs/readme.md stale wording in the intro |

## Clusters

### api (1)

suggested batch: `python3 scripts/zuvo-home/backlog-groom.py apply --repo <REPO>` — the closures are delegated to backlog-archive.py

- `B-g-fixed` — STALE-FIXED — disposition `pending` — B-g-fixed api/auth.ts guard added — FIXED abc1234

### docs (1)

suggested batch: `zuvo:refactor docs` or `zuvo:backlog fix <id>` — these entries are still true

- `B-g-low` — STILL-REAL — disposition `pending` — B-g-low [low] docs/readme.md stale wording in the intro

### services (1)

suggested batch: `zuvo:refactor services` or `zuvo:backlog fix <id>` — these entries are still true

- `B-g-still` — STILL-REAL — disposition `pending` — B-g-still [high] services/pay.ts:12 retry loop unbounded — security leak risk

### tools (1)

suggested batch: `python3 scripts/zuvo-home/backlog-groom.py plan --repo <REPO>` then the verifier lane — these need a re-verify, not a fix

- `B-g-nv` — NOT-VERIFIABLE — disposition `pending` — B-g-nv tools/present.py behaviour cannot be decided from the tree

## Not verifiable

Reported rather than omitted: an entry the repo does not answer is a known unknown, and `NOT-VERIFIABLE` is cheap and legitimate.

- `B-g-nv` — nothing in the tree decides this entry

## Provenance self-check

Run this with ONLY this document in hand. It reads `source:` and `source_sha256:` back out of the
header above and compares them with the backlog on disk, so a document that has stopped describing
its source says so without anyone having to remember what the source used to be.

```sh
REPORT=<path to this file>
python3 - "$REPORT" <<'EOF'
import hashlib, re, sys
doc = open(sys.argv[1], encoding="utf-8").read()
path = re.search(r"^source: (.+)$", doc, re.M).group(1)
want = re.search(r"^source_sha256: ([0-9a-f]{64})$", doc, re.M).group(1)
have = hashlib.sha256(open(path, "rb").read()).hexdigest()
print("MATCH" if have == want else "MISMATCH want=%s have=%s" % (want, have))
EOF
```
GOLDEOF
NORM="$T5/normalise.py"
cat > "$NORM" <<'PYEOF'
r"""Normalise the six environment-dependent provenance values and the mktemp repo path.

RAW docstring, same reason as the probes': a `\s` in a plain one is a SyntaxWarning on stderr, which
every caller here reads as "the fixture did not build".

Usage: normalise.py <document> <repo dir>
"""
import re
import sys

doc = open(sys.argv[1], encoding="utf-8").read().replace(sys.argv[2], "<REPO>")
for pat, rep in ((r"^source: .*$", "source: <SRC>"),
                 (r"^source_sha256: [0-9a-f]{64}$", "source_sha256: <SHA256>"),
                 (r"^source_bytes: \d+$", "source_bytes: <N>"),
                 (r"^ledger: .*$", "ledger: <LEDGER>"),
                 (r"^generated_by: .*$", "generated_by: <GEN>"),
                 (r"^generated_at: .*$", "generated_at: <AT>")):
    doc = re.sub(pat, rep, doc, flags=re.M)
sys.stdout.write(doc)
PYEOF
# A SECOND, pristine render: R5e mutated the first fixture's source byte, which legitimately changes
# `source_sha256`/`source_bytes` — both normalised — but a golden compare on a file another assertion
# has edited is a comparison nobody can attribute.
GR2="$(mkrepo5 "$T5/bl-golden.md")" || no "(R6a) could not build the golden-compare repo"
led5 "$GR2" --default STILL-REAL --verdict B-g-nv=NOT-VERIFIABLE --verdict B-g-fixed=STALE-FIXED \
  >/dev/null 2>&1
G2_RC="$(render5 "$CTL2" "$GR2" "$T5/out-golden")"
G2_DOC="$(reportof)"
if [ "$G2_RC" = "0" ] && [ -f "$G2_DOC" ]; then
  python3 "$NORM" "$G2_DOC" "$GR2" > "$T5/actual.md" 2>"$T5/norm.err"
  if diff -u "$T5/golden.md" "$T5/actual.md" > "$T5/golden.diff" 2>&1; then
    ok "(R6/AC10) the rendered document is BYTE-IDENTICAL to the hand-authored golden after the six environment values are normalised — section order, the derived-score caveat, all three ranked rows with their hand-computed 50/30/10, the four clusters in name order, their suggestions and both count tables"
  else
    no "(R6/AC10) the document differs from the committed golden: $(head -12 "$T5/golden.diff" | tr '\n' '|')"
  fi
else
  no "(R6a) the golden-compare render failed (rc=$G2_RC): $(tail -3 "$T5/last.out")"
fi
# The normaliser must not be doing the comparison's work: it rewrites SIX lines and nothing else.
G2_NORMED="$(diff "$G2_DOC" "$T5/actual.md" | grep -c '^> ' || true)"
[ "${G2_NORMED:-99}" -le 9 ] && [ "${G2_NORMED:-0}" -ge 6 ] \
  && ok "(R6b) the normaliser rewrites ${G2_NORMED} lines of the document — the six provenance values plus the mktemp repo path inside two suggestion lines — and leaves the rest alone, so the golden compare above is over the renderer's own decisions rather than over a heavily laundered file" \
  || no "(R6b) the normaliser rewrote ${G2_NORMED} lines — too much of the document is being normalised for R6 to mean anything"
# And the scores stay inside `prioritize`'s own range, which is the one property the formula asserts
# about itself rather than about this fixture.
python3 - "$CTL2" >"$T5/bounds.out" 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import zuvo_backlog_score as zs      # noqa: E402
bad = []
for imp in (1, 3, 5):
    for risk in (1, 3, 5):
        for eff in (1, 2, 3, 4, 5):
            s = zs.Scored(None, {}, imp, risk, eff).score
            if not (zs.SCORE_MIN <= s <= zs.SCORE_MAX):
                bad.append("%d/%d/%d=%d" % (imp, risk, eff, s))
print("BOUNDS_BAD=%s" % (",".join(bad) or "-"))
print("SPAN=%d..%d" % (zs.Scored(None, {}, 1, 1, 5).score, zs.Scored(None, {}, 5, 5, 1).score))
PYEOF
if grep -qx 'BOUNDS_BAD=-' "$T5/bounds.out" && grep -qx 'SPAN=2..50' "$T5/bounds.out"; then
  ok "(R7) every one of the 45 (Impact, Risk, Effort) combinations scores inside $(sed -n 's/^SPAN=//p' "$T5/bounds.out") — the range zuvo:backlog prioritize states for itself, reused rather than re-invented"
else
  no "(R7) the scoring leaves prioritize's range: $(cat "$T5/bounds.out" | tr '\n' ' ')"
fi
grep -q 'derived from the bytes' "$G_DOC" \
  && ok "(R8) the document itself says the three dimensions are DERIVED and not judged — the caveat is emitted into the artefact a reader holds, not left in a docstring nobody renders" \
  || no "(R8) the document does not carry the derived-score caveat, so a reading order reads as an assessment"

# ==================================================================================================
# AC11 — `verify --fleet` IS READ-ONLY, and that is MEASURED rather than reasoned about.
#
# WHY A FIXTURE FLEET AND NOT THE LIVE TREE. Derived on this machine before this suite was written:
# `~/.zuvo/backlog-local.jsonl` is ~8.5 MB / 14,583 rows over 56 distinct (host, repo) pairs, while
# `memory/backlog*.md` under ~/DEV and ~/projects comes to 3,250 files in 727 directories. Anything
# that could write runs against the fixture; the live tree is observed READ-ONLY, below, and gates
# nothing destructive.
#
# WHY MTIMES AND NOT CONTENT. The `fleettouchesrepo` mutant calls `os.utime` — it changes an mtime
# without changing a byte, which is precisely what a content-only comparison would miss and what a
# real lock-directory or temp-file write would produce as a side effect.
# ==================================================================================================
echo "-- AC11: the fleet lane writes into ~/.zuvo/ and nowhere else --"
FLEET_ROOT="$T5/fleet"
FLEET_HOME="$T5/fleethome"
mkdir -p "$FLEET_HOME"
for r in alpha beta gamma; do
  mkdir -p "$FLEET_ROOT/$r/memory"
  printf '# Backlog\n\n## Open\n\n- [ ] B-%s-one services/%s.ts:3 still unbounded here\n' "$r" "$r" \
    > "$FLEET_ROOT/$r/memory/backlog.md"
  printf '# Resolved\n' > "$FLEET_ROOT/$r/memory/backlog-done.md"
done
# The index. `repo_path` points INTO the fixture fleet, which is what gives the mutant a target — and
# what makes the assertion below non-vacuous: a snapshot whose repo_path pointed nowhere could not be
# written into even by code that tried.
python3 - "$T5" <<'PYEOF'
import json
import os
import sys

T5 = sys.argv[1]
root = os.path.join(T5, "fleet")
rows = []
for n, repo in enumerate(("alpha", "beta", "gamma"), start=1):
    rows.append({"item_id": "B-%s-one" % repo, "status": "open", "severity": "high", "added": "",
                 "text": "services/%s.ts:3 still unbounded here" % repo,
                 "fingerprint": "f%d" % n, "key": "id:B-%s-one" % repo, "host": "fixhost",
                 "repo": repo, "repo_path": os.path.join(root, repo), "repo_remote": ""})
# A recorded closure (the marker class survives truncation) and a duplicate pair inside ONE repo.
rows.append({"item_id": "B-alpha-two", "status": "done", "severity": "", "added": "",
             "text": "api/auth.ts guard added — FIXED abc1234", "fingerprint": "f4",
             "key": "id:B-alpha-two", "host": "fixhost", "repo": "alpha",
             "repo_path": os.path.join(root, "alpha"), "repo_remote": ""})
for n in (5, 6):
    rows.append({"item_id": "B-beta-dup%d" % n, "status": "open", "severity": "low", "added": "",
                 "text": "docs/x.md wording %d" % n, "fingerprint": "f%d" % n,
                 "key": "fp:aaaaaaaaaaaa", "host": "fixhost", "repo": "beta",
                 "repo_path": os.path.join(root, "beta"), "repo_remote": ""})
with open(os.path.join(T5, "index.jsonl"), "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r, sort_keys=True) + "\n")
print("INDEX_ROWS=%d REPOS=%d" % (len(rows), len({(r["host"], r["repo"]) for r in rows})))
PYEOF
F_IDX="$T5/index.jsonl"
F_FILES="$(find "$FLEET_ROOT" -type f | awk 'END{print NR}')"
[ "${F_FILES:-0}" -ge 6 ] \
  && ok "(F0) the fixture fleet holds $F_FILES files across 3 checkouts, each with a real memory/backlog.md the index's repo_path points at — so 'zero writes outside ~/.zuvo' is a claim with a subject, which Task 4's write-discipline group did NOT have on this repo (N=0)" \
  || no "(F0) the fixture fleet holds only ${F_FILES:-0} files; the mtime assertion below would be vacuous"

SNAP="$T5/snap.py"
cat > "$SNAP" <<'PYEOF'
r"""Snapshot or compare mtime_ns+size for every file under one or more roots.

RAW docstring, same reason as the probes'.

Usage: snap.py take <out.tsv> <root>...
       snap.py diff <before.tsv> <after.tsv> <allowed-prefix>

`diff` prints one CHANGED=<path> (<why>) line per path that moved OUTSIDE the allowed prefix, one
ALLOWED=<path> line per path that moved INSIDE it, and the two totals. NAMING the path is the point:
"something changed" sends a reader to 3,250 files, and an mtime assertion that cannot say which file
moved is one nobody acts on.
"""
import os
import sys


def take(roots):
    out = {}
    for root in roots:
        if os.path.isfile(root):
            st = os.stat(root)
            out[root] = "%d\t%d" % (st.st_mtime_ns, st.st_size)
            continue
        for dirpath, dirs, files in os.walk(root):
            dirs.sort()
            for name in sorted(files):
                p = os.path.join(dirpath, name)
                try:
                    st = os.stat(p)
                except OSError:
                    continue
                out[p] = "%d\t%d" % (st.st_mtime_ns, st.st_size)
    return out


def load(path):
    out = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            p, rest = line.rstrip("\n").split("\t", 1)
            out[p] = rest
    return out


mode = sys.argv[1]
if mode == "take":
    snap = take(sys.argv[3:])
    with open(sys.argv[2], "w", encoding="utf-8") as fh:
        for p in sorted(snap):
            fh.write("%s\t%s\n" % (p, snap[p]))
    print("SNAPSHOTTED=%d" % len(snap))
    sys.exit(0)

before, after, allowed = load(sys.argv[2]), load(sys.argv[3]), sys.argv[4]
outside = inside = 0
for p in sorted(set(before) | set(after)):
    if before.get(p) == after.get(p):
        continue
    why = ("created" if p not in before else "removed" if p not in after else "mtime/size moved")
    if p.startswith(allowed):
        inside += 1
        print("ALLOWED=%s (%s)" % (p, why))
    else:
        outside += 1
        print("CHANGED=%s (%s)" % (p, why))
print("OUTSIDE=%d" % outside)
print("INSIDE=%d" % inside)
print("COMPARED=%d" % len(set(before) | set(after)))
PYEOF
fleet5(){   # moddir, extra args... -> writes $T5/fleet.out, echoes the rc
  local md="$1"; shift
  ZUVO_DIR="$FLEET_HOME" ZUVO_BACKLOG_OUT="$F_IDX" \
    python3 "$md/backlog-groom.py" plan --repo "$T5" --fleet "$@" >"$T5/fleet.out" 2>&1
  printf '%s\n' "$?"
}
snapshot5(){ python3 "$SNAP" take "$1" "$FLEET_ROOT" "$FLEET_HOME" "$T5/index.jsonl"; }

# THE POSITIVE CONTROL FOR THE COMPARATOR ITSELF. A comparison that cannot report a change it was
# given reports zero for every run, and zero is what every assertion below wants to see.
snapshot5 "$T5/probe-before.tsv" >/dev/null
python3 -c "import os,sys;os.utime(sys.argv[1],(1,1))" "$FLEET_ROOT/gamma/memory/backlog.md"
snapshot5 "$T5/probe-after.tsv" >/dev/null
python3 "$SNAP" diff "$T5/probe-before.tsv" "$T5/probe-after.tsv" "$FLEET_HOME" >"$T5/probe.diff" 2>&1
if grep -qx 'OUTSIDE=1' "$T5/probe.diff" \
   && grep -q "^CHANGED=$FLEET_ROOT/gamma/memory/backlog.md (mtime/size moved)\$" "$T5/probe.diff"; then
  ok "(F1a/AC11) the comparator detects a touched file and NAMES it ($(grep -m1 '^CHANGED=' "$T5/probe.diff" | sed "s|$T5|\$T5|")) — without this control every OUTSIDE=0 below could mean the comparator sees nothing at all"
else
  no "(F1a/AC11) the comparator did not name a deliberately touched file: $(cat "$T5/probe.diff" | tr '\n' ' ')"
fi

# The DRY RUN first: it must change nothing anywhere, including ~/.zuvo.
snapshot5 "$T5/dry-before.tsv" >"$T5/snapn.out"
F_SNAP_TOTAL="$(sed -n 's/^SNAPSHOTTED=//p' "$T5/snapn.out" | head -1)"
# DERIVED, not a guessed floor: the $F_FILES fixture-fleet files plus the index the lane reads. The
# fixture ~/.zuvo is empty at this point and legitimately contributes nothing.
[ "${F_SNAP_TOTAL:-0}" -ge "$((F_FILES + 1))" ] \
  && ok "(F1a2/AC11) the snapshot covers $F_SNAP_TOTAL paths — the $F_FILES files of the three other checkouts plus the index file the lane reads, so the OUTSIDE=0 below is about a non-empty set" \
  || no "(F1a2/AC11) the snapshot covers only ${F_SNAP_TOTAL:-0} paths against $F_FILES fleet files plus the index; the zero below would be about almost nothing"
F_RC="$(fleet5 "$CTL2" --dry-run)"
snapshot5 "$T5/dry-after.tsv" >/dev/null
python3 "$SNAP" diff "$T5/dry-before.tsv" "$T5/dry-after.tsv" "$FLEET_HOME" >"$T5/dry.diff" 2>&1
[ "$F_RC" = "0" ] \
  && ok "(F1b/AC11) \`plan --fleet --dry-run\` exits 0 over the fixture index" \
  || no "(F1b/AC11) the fleet dry run failed (rc=$F_RC): $(tail -3 "$T5/fleet.out")"
if grep -qx 'OUTSIDE=0' "$T5/dry.diff" && grep -qx 'INSIDE=0' "$T5/dry.diff"; then
  ok "(F1c/AC11) across the ${F_SNAP_TOTAL:-?} paths snapshotted, the dry run moved ZERO of them — not one byte and not one mtime, inside ~/.zuvo or out"
else
  no "(F1c/AC11) the fleet dry run changed something: $(grep -E '^(CHANGED|ALLOWED)=' "$T5/dry.diff" | head -3 | tr '\n' ' ')"
fi
grep -q '^DRY_RUN=1 wrote nothing$' "$T5/fleet.out" \
  && ok "(F1d/AC11) …and it says so, so a dry run that silently became a real one would be visible in the report as well as in the mtimes" \
  || no "(F1d/AC11) the dry run does not report DRY_RUN=1: $(tail -2 "$T5/fleet.out")"

# THE REAL RUN. Writes are legitimate in exactly one subtree — ~/.zuvo/backlog-verdicts/ — because
# that is the HOME-local state convention decision 13 puts them under. Everything else is zero.
snapshot5 "$T5/real-before.tsv" >/dev/null
F_RC2="$(fleet5 "$CTL2")"
cp "$T5/fleet.out" "$T5/ac11.out"
snapshot5 "$T5/real-after.tsv" >/dev/null
python3 "$SNAP" diff "$T5/real-before.tsv" "$T5/real-after.tsv" "$FLEET_HOME/backlog-verdicts/" \
  >"$T5/real.diff" 2>&1
[ "$F_RC2" = "0" ] \
  && ok "(F2a/AC11) the real \`plan --fleet\` exits 0: $(grep -m1 '^FLEET_INDEX=' "$T5/ac11.out" | sed "s|$T5|\$T5|" | cut -c1-120)" \
  || no "(F2a/AC11) the fleet run failed (rc=$F_RC2): $(tail -3 "$T5/ac11.out")"
if grep -qx 'OUTSIDE=0' "$T5/real.diff"; then
  ok "(F2b/AC11) ZERO mtime or size changes outside ~/.zuvo/backlog-verdicts/ — across the ${F_SNAP_TOTAL:-?} snapshotted paths, including all three other checkouts' memory/ directories and the index it read"
else
  no "(F2b/AC11) the fleet run wrote outside the permitted subtree: $(grep '^CHANGED=' "$T5/real.diff" | head -3 | tr '\n' ' ')"
fi
F_INSIDE="$(sed -n 's/^INSIDE=//p' "$T5/real.diff" | head -1)"
[ "${F_INSIDE:-0}" -ge 2 ] \
  && ok "(F2c/AC11) …and it DID write $F_INSIDE file(s) inside that one permitted subtree, so F2b is 'wrote only there' and not 'wrote nothing at all' — which a dry run would also satisfy" \
  || no "(F2c/AC11) only ${F_INSIDE:-0} file(s) appeared under ~/.zuvo/backlog-verdicts/; F2b would be vacuous"
# The verdicts live beside nothing: no lock directory, no temp file, nothing in any checkout.
if find "$FLEET_ROOT" -name '.backlog-archive.lock.d' -o -name '.*.tmp.*' | grep -q .; then
  no "(F2d/AC11) the fleet run left a lock directory or a temp file inside a checkout: $(find "$FLEET_ROOT" -name '.backlog-archive.lock.d' -o -name '.*.tmp.*' | head -2 | tr '\n' ' ')"
else
  ok "(F2d/AC11) no lock directory and no temp file anywhere under the fixture fleet — the lane never takes another checkout's lock, which is the specific side effect an mtime snapshot of files alone could miss on an empty directory"
fi

# Every row carries its provenance.
F_OUTS="$(find "$FLEET_HOME/backlog-verdicts" -name '*.jsonl' 2>/dev/null | sort | tr '\n' ' ')"
F_ALL="$(cat "$FLEET_HOME/backlog-verdicts"/*.jsonl 2>/dev/null | awk 'END{print NR}')"
F_SRC="$(grep -c '"source": "index"' "$FLEET_HOME/backlog-verdicts"/*.jsonl 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')"
if [ "${F_ALL:-0}" -gt 0 ] && [ "$F_SRC" = "$F_ALL" ]; then
  ok "(F3/AC11) all $F_ALL fleet rows across $(printf '%s' "$F_OUTS" | wc -w | tr -d ' ') files carry source=index — derived by counting both, so 'every row' is not a statement about a sample"
else
  no "(F3/AC11) ${F_SRC:-0} of ${F_ALL:-0} rows carry source=index"
fi
# ...and they are rows the LEDGER would accept, so the refusal below is the only thing stopping them.
python3 - "$CTL2" "$FLEET_HOME/backlog-verdicts" >"$T5/fvalid.out" 2>&1 <<'PYEOF'
import glob
import json
import os
import sys
sys.path.insert(0, sys.argv[1])
import zuvo_backlog_ledger as zl      # noqa: E402
bad, n = [], 0
for path in sorted(glob.glob(os.path.join(sys.argv[2], "*.jsonl"))):
    for i, line in enumerate(open(path, encoding="utf-8"), start=1):
        n += 1
        bad.extend(zl.validate_row(json.loads(line), "%s:%d" % (os.path.basename(path), i)))
print("ROWS=%d" % n)
print("INVALID=%s" % (";".join(bad[:3]) or "-"))
PYEOF
grep -qx 'INVALID=-' "$T5/fvalid.out" \
  && ok "(F3b/AC11) every fleet row also passes the LEDGER's own validate_row ($(sed -n 's/^ROWS=//p' "$T5/fvalid.out") rows) — which is why the source=index refusal is load-bearing rather than belt-and-braces: nothing in the schema would reject these" \
  || no "(F3b/AC11) a fleet row is not a valid ledger row: $(sed -n 's/^INVALID=//p' "$T5/fvalid.out")"
grep -q '^FLEET_REPO=fixhost/alpha .*STALE-FIXED=1' "$T5/ac11.out" \
  && ok "(F3c) the marker class survives truncation: alpha's recorded closure is STALE-FIXED from the index text alone" \
  || no "(F3c) no STALE-FIXED row for the recorded closure: $(grep '^FLEET_REPO=' "$T5/ac11.out" | tr '\n' ' ')"
grep -q '^FLEET_REPO=fixhost/beta .*DUPLICATE-OF=2' "$T5/ac11.out" \
  && ok "(F3d) …and so does the duplicate class, scoped PER REPO: beta's two rows share a key and both report DUPLICATE-OF" \
  || no "(F3d) the duplicate pair was not detected: $(grep '^FLEET_REPO=fixhost/beta' "$T5/ac11.out")"
grep -q 'NOT-VERIFIABLE' "$T5/ac11.out" \
  && ok "(F3e) and everything else is NOT-VERIFIABLE with the reason stated — the index holds no tree, and guessing STILL-REAL there is the cheapest way to look thorough" \
  || no "(F3e) nothing came back NOT-VERIFIABLE, so the honest answer is not being given"

# REFUSAL 2: a disposition on a `source=index` row. The fixture entry is SHORT, so its fleet
# `text_sha` matches the per-repo one EXACTLY — the refusal must not be doing the truncation's work.
IR="$(mkrepo5 "$T5/bl-golden.md")" || no "(F4a/AC11) could not build the index-row repo"
led5 "$IR" --default STILL-REAL --verdict B-g-nv=NOT-VERIFIABLE --verdict B-g-fixed=STALE-FIXED \
  >/dev/null 2>&1
python3 - "$CTL2" "$IR" >"$T5/idxrow.out" 2>&1 <<'PYEOF'
import json
import os
import sys
sys.path.insert(0, sys.argv[1])
import zuvo_backlog_fleet as zf       # noqa: E402
ledger = os.path.join(sys.argv[2], "memory", "backlog-verdicts.jsonl")
rows = [json.loads(ln) for ln in open(ledger, encoding="utf-8") if ln.strip()]
rows[0]["source"] = zf.SOURCE_INDEX
with open(ledger, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r, sort_keys=True) + "\n")
print("MARKED=%s" % rows[0]["id"])
print("SHA_LEN=%d" % len(rows[0]["text_sha"]))
PYEOF
IR_ID="$(sed -n 's/^MARKED=//p' "$T5/idxrow.out" | head -1)"
IR_B0="$(sha4 "$IR/memory/backlog.md")"; IR_A0="$(sha4 "$IR/memory/backlog-done.md")"
IR_L0="$(sha4 "$IR/memory/backlog-verdicts.jsonl")"
IR_RC="$(apply4 "$CTL2" "$IR")"
if [ "$IR_RC" = "$RC_INDEX_N" ]; then
  ok "(F4/AC11) a disposition on a source=index row REFUSES with rc=$IR_RC (RC_INDEX) — and the marked row's text_sha is the per-repo one, so the refusal fires on a row that WOULD have resolved rather than on one truncation had already broken"
else
  no "(F4/AC11) rc=$IR_RC, expected RC_INDEX=$RC_INDEX_N: $(tail -3 "$T4/last.out")"
fi
grep -qF -- "$IR_ID" "$T4/last.out" \
  && ok "(F4b/AC11) …and the refusal NAMES the offending row ($IR_ID), so an operator can find which verdict to re-make in the checkout" \
  || no "(F4b/AC11) the refusal does not name $IR_ID: $(tail -2 "$T4/last.out" | cut -c1-140)"
if [ "$IR_B0" = "$(sha4 "$IR/memory/backlog.md")" ] \
   && [ "$IR_A0" = "$(sha4 "$IR/memory/backlog-done.md")" ] \
   && [ "$IR_L0" = "$(sha4 "$IR/memory/backlog-verdicts.jsonl")" ]; then
  ok "(F4c/AC11) ZERO bytes written by that refusal: backlog.md, backlog-done.md and the ledger all keep their sha256"
else
  no "(F4c/AC11) the source=index refusal wrote something"
fi
grep -q '^DISPOSITION=' "$T4/last.out" \
  && no "(F4d/AC11) the refusing run still printed dispositions — the refusal must land before anything is decided" \
  || ok "(F4d/AC11) and it prints no disposition at all: the check sits before the decisions, not after them"

# REFUSAL 3: `groom --fleet` — which on this CLI is `apply --fleet`, since `apply` is the command
# that performs the dispositions the plan calls `groom`. Rejected NAMING the per-repo command.
GF_RC="$(apply4 "$CTL2" "$GR2" --fleet)"
if [ "$GF_RC" = "$RC_FLEET_N" ]; then
  ok "(F5/AC11) \`apply --fleet\` — the plan's \`groom --fleet\` — is REJECTED with rc=$GF_RC (RC_FLEET), not silently accepted and not quietly run per-repo"
else
  no "(F5/AC11) rc=$GF_RC, expected RC_FLEET=$RC_FLEET_N: $(tail -3 "$T4/last.out")"
fi
grep -q 'apply --repo' "$T4/last.out" \
  && ok "(F5b/AC11) …and the rejection NAMES the per-repo command (\`backlog-groom.py apply --repo <checkout>\`), because a refusal that does not say what to run instead gets worked around" \
  || no "(F5b/AC11) the rejection does not name the per-repo command: $(tail -3 "$T4/last.out" | tr '\n' ' ' | cut -c1-160)"
grep -q '^BACKLOG=' "$T4/last.out" \
  && no "(F5c/AC11) the rejected run still resolved and read the repo — the refusal must land before any work, since resolving a checkout is work a fleet request has no business doing" \
  || ok "(F5c/AC11) it refuses BEFORE resolving the repo at all (no BACKLOG= line), so nothing is read, locked or parsed on the way to the refusal"

# A snapshot that yields nothing is a refusal, never a clean pass. Decision 13 also records WHICH
# file is the wrong one: ~/.zuvo/backlog-index.jsonl, measured at 0 bytes.
: > "$T5/empty.jsonl"
E_RC="$(ZUVO_DIR="$FLEET_HOME" ZUVO_BACKLOG_OUT="$T5/empty.jsonl" \
  python3 "$CTL2/backlog-groom.py" plan --repo "$T5" --fleet >"$T5/empty.out" 2>&1; printf '%s\n' "$?")"
[ "$E_RC" != "0" ] && grep -q 'clean pass over nothing' "$T5/empty.out" \
  && ok "(F6/AC11) an EMPTY snapshot is a refusal (rc=$E_RC) naming the hazard — a fleet run over zero rows would otherwise report a clean pass over nothing, which is exactly what reading the 0-byte backlog-index.jsonl would produce" \
  || no "(F6/AC11) an empty snapshot exited $E_RC: $(tail -2 "$T5/empty.out" | tr '\n' ' ')"
# The path resolution is the collector's own, and it is NOT the 0-byte file decision 13 rejects.
python3 - "$CTL2" >"$T5/paths.out" 2>&1 <<'PYEOF'
import os
import sys
sys.path.insert(0, sys.argv[1])
os.environ.pop("ZUVO_BACKLOG_OUT", None)
os.environ["ZUVO_DIR"] = "/tmp/zuvo-fleet-probe"
import zuvo_backlog_fleet as zf       # noqa: E402
print("DEFAULT=%s" % zf.index_path())
print("VERDICTS=%s" % zf.verdicts_dir())
os.environ["ZUVO_BACKLOG_OUT"] = "/tmp/elsewhere.jsonl"
print("OVERRIDE=%s" % zf.index_path())
PYEOF
if grep -qx 'DEFAULT=/tmp/zuvo-fleet-probe/backlog-local.jsonl' "$T5/paths.out" \
   && grep -qx 'OVERRIDE=/tmp/elsewhere.jsonl' "$T5/paths.out" \
   && grep -qx 'VERDICTS=/tmp/zuvo-fleet-probe/backlog-verdicts' "$T5/paths.out"; then
  ok "(F7/AC11) the lane resolves ZUVO_BACKLOG_OUT then <ZUVO_DIR>/backlog-local.jsonl — backlog-collect.py's own rule, so the reader cannot end up verifying a snapshot nothing updates — and it is NOT backlog-index.jsonl, the 0-byte file decision 13 names"
else
  no "(F7/AC11) the fleet path resolution is wrong: $(cat "$T5/paths.out" | tr '\n' ' ')"
fi
# The read-only guarantee, asserted STRUCTURALLY as well as behaviourally: this module cannot write
# into a checkout because it holds nothing that could.
F_STRUCT="$(python3 - "$FLEET_MOD" <<'PYEOF'
import re
import sys
src = open(sys.argv[1], encoding="utf-8").read()
body = "\n".join(ln for ln in src.splitlines() if not ln.lstrip().startswith("#"))
print(" ".join("%s=%d" % (name, len(re.findall(pat, body))) for name, pat in (
    ("lock", r"\bLock\("), ("subprocess", r"\bsubprocess\b"),
    ("resolve", r"\bzio\.resolve\("), ("append_rows", r"\bappend_rows\("),
    ("atomic", r"\bzio\.atomic_write\("))))
PYEOF
)"
echo "  fleet module structure: $F_STRUCT"
[ "$F_STRUCT" = "lock=0 subprocess=0 resolve=0 append_rows=0 atomic=1" ] \
  && ok "(F8/AC11) structurally read-only: the fleet module takes no Lock, spawns no subprocess, never calls zio.resolve (so it never computes a checkout's backlog path) and never append_rows (which would lock that checkout's memory/) — one atomic_write, into ~/.zuvo/" \
  || no "(F8/AC11) the fleet module's structure is '$F_STRUCT', expected 'lock=0 subprocess=0 resolve=0 append_rows=0 atomic=1' — a write path into another checkout became reachable"

# THE LIVE TREE, OBSERVED READ-ONLY. Reported so the fixture's scale is comparable with the real
# blast radius, and deliberately gating nothing: nothing below runs the lane against it.
L_IDX="$(python3 - "$CTL2" <<'PYEOF'
import os
import sys
sys.path.insert(0, sys.argv[1])
os.environ.pop("ZUVO_DIR", None)
os.environ.pop("ZUVO_BACKLOG_OUT", None)
import zuvo_backlog_fleet as zf       # noqa: E402
p = zf.index_path()
size = os.path.getsize(p) if os.path.exists(p) else 0
rows = sum(1 for _ in open(p, encoding="utf-8", errors="replace")) if size else 0
print("%s bytes=%d rows=%d" % (p, size, rows))
PYEOF
)"
echo "  live snapshot (observed, never run against): $L_IDX"
echo "  fixture fleet used for every write-capable assertion above: $FLEET_ROOT ($F_FILES files, 3 checkouts)"

# ==================================================================================================
# MU5 — every Task 5 assertion dies under a mutant that reverts ONLY its behaviour.
#
# THREE OF THEM ADD CODE RATHER THAN REMOVING IT, and they have to: this task's central properties are
# ABSENCES — the ranking is gone under --partial, nothing is written outside ~/.zuvo — and an absence
# cannot be reverted by deleting a line. `partialranks` puts the ranking back, `fleettouchesrepo`
# touches another checkout, and `fleetemptyok` lets an empty snapshot pass.
# ==================================================================================================
echo "-- MU5: each Task 5 assertion is load-bearing --"
mu5_render(){  # kind, label, direction(gone|new), ERE, repo, outdir-suffix, extra render args...
  local kind="$1" lbl="$2" dir="$3" pat="$4" repo="$5" sfx="$6"; shift 6
  if ! mut2_build "$kind"; then mut2_failed "$kind"; return; fi
  local crc mrc cdoc mdoc ctl mut
  crc="$(render5 "$CTL2" "$repo" "$T5/mu-ctl-$sfx" "$@")"; cdoc="$(reportof)"
  ctl="$(cat "$T5/last.out"; [ -f "$cdoc" ] && cat "$cdoc")"
  mrc="$(render5 "$T2/mut-$kind" "$repo" "$T5/mu-mut-$sfx" "$@")"; mdoc="$(reportof)"
  mut="$(cat "$T5/last.out"; [ -f "$mdoc" ] && cat "$mdoc")"
  if [ "$dir" = "gone" ]; then
    if ! printf '%s\n' "$ctl" | grep -qE -- "$pat"; then
      no "(MU5) $lbl: the CONTROL does not produce /$pat/ either (rc=$crc), so this comparison measures nothing"
    elif printf '%s\n' "$mut" | grep -qE -- "$pat"; then
      no "(MU5) $lbl: the mutant STILL produces /$pat/ — the assertion is decorative"
    else
      ok "(MU5) $lbl: /$pat/ vanishes under the mutant while the control produces it — load-bearing"
    fi
  else
    if printf '%s\n' "$ctl" | grep -qE -- "$pat"; then
      no "(MU5) $lbl: the CONTROL already produces /$pat/, so the mutant's appearance is not attributable"
    elif printf '%s\n' "$mut" | grep -qE -- "$pat"; then
      ok "(MU5) $lbl: the mutant produces /$pat/ where the control does not — load-bearing"
    else
      no "(MU5) $lbl: the mutant produced no /$pat/ (rc=$mrc), so the control's clean result is not attributable to this code"
    fi
  fi
}
MU5_SEQ=0
mu5_next(){ MU5_SEQ=$((MU5_SEQ + 1)); }   # a plain function, NEVER inside $( ), for the Task 4 reason

# --- the gate, and the two halves of --partial -----------------------------------------------------
mu5_next; mu5_render nopartialgate "R3b/AC9 the refusal itself" gone \
  'refusing to render' "$PR5" "g$MU5_SEQ"
mu5_next; mu5_render partialranks "R4c/AC9 --partial OMITS the ranking section" new \
  '^## Ranking$' "$PR5" "g$MU5_SEQ" --partial
mu5_next; mu5_render partialnobanner "R4b/AC9 --partial stamps the coverage ratio" gone \
  'PARTIAL VERIFICATION' "$PR5" "g$MU5_SEQ" --partial
mu5_next; mu5_render nounverifiedsection "R4e/AC9 --partial NAMES what it did not render" gone \
  '^## Unverified$' "$PR5" "g$MU5_SEQ" --partial
# --- decision 12's provenance ---------------------------------------------------------------------
mu5_next; mu5_render nocoveragestamp "R5a/AC10 the coverage count in the header" gone \
  '^coverage: [0-9]+/[0-9]+ ' "$GR2" "g$MU5_SEQ"
mu5_next; mu5_render noselfcheck "R5c/AC10 the self-check travels WITH the document" gone \
  '^## Provenance self-check$' "$GR2" "g$MU5_SEQ"
mu5_next; mu5_render nonotverifiable "R6 the explicit NOT-VERIFIABLE section" gone \
  '^## Not verifiable$' "$GR2" "g$MU5_SEQ"
# --- the ranking's own content --------------------------------------------------------------------
mu5_next; mu5_render rankincludesstale "R6 the ranking is scoped to the verdicts that KEEP an entry" new \
  '^\| [0-9]+ \| B-g-fixed \|' "$GR2" "g$MU5_SEQ"
mu5_next; mu5_render clusterbysection "R6 the cited path decides the theme" gone \
  '^### services \(1\)$' "$GR2" "g$MU5_SEQ"

# `shaconstant` and `scoreflat` are checked against the DOCUMENT rather than by grep, because what
# they break is a value's relationship to something outside the document.
if mut2_build shaconstant; then
  SC_RC="$(render5 "$T2/mut-shaconstant" "$GR2" "$T5/mu-sha")"
  SC_DOC="$(reportof)"
  SC_ANS="$(python3 "$AC10" "$SC_DOC" 2>&1 || true)"
  case "$SC_ANS" in
    MISMATCH*) ok "(MU5) R5d/AC10 the header sha is the SOURCE's sha: with the digest taken over a constant, the document's own self-check reports MISMATCH on an untouched file — so R5d's MATCH is attributable to that line" ;;
    *) no "(MU5) R5d/AC10: the shaconstant mutant still answers '$SC_ANS' (rc=$SC_RC), so the provenance sha pins nothing" ;;
  esac
else
  mut2_failed shaconstant
fi
if mut2_build scoreflat; then
  SF_RC="$(render5 "$T2/mut-scoreflat" "$GR2" "$T5/mu-score")"
  SF_DOC="$(reportof)"
  if [ "$SF_RC" = "0" ] && ! diff -q <(python3 "$NORM" "$SF_DOC" "$GR2") "$T5/golden.md" >/dev/null 2>&1; then
    ok "(MU5) R6 the golden pins prioritize's FORMULA: flattening the score to a constant changes the document, so the three hand-computed 50/30/10 rows are load-bearing rather than decorative"
  else
    no "(MU5) R6: the scoreflat mutant produced a document identical to the golden (rc=$SF_RC) — the ranked rows pin nothing"
  fi
else
  mut2_failed scoreflat
fi

# --- the fleet lane: the three refusals and the read-only guarantee --------------------------------
if mut2_build fleetnosource; then
  srccount(){ cat "$FLEET_HOME/backlog-verdicts"/*.jsonl 2>/dev/null | grep -c '"source": "index"' || true; }
  rm -rf "$FLEET_HOME/backlog-verdicts"; fleet5 "$CTL2" >/dev/null; MU_SRC_CTL="$(srccount)"
  rm -rf "$FLEET_HOME/backlog-verdicts"; fleet5 "$T2/mut-fleetnosource" >/dev/null
  MU_SRC_MUT="$(srccount)"
  rm -rf "$FLEET_HOME/backlog-verdicts"; fleet5 "$CTL2" >/dev/null
  if [ "${MU_SRC_CTL:-0}" -ge 6 ] && [ "${MU_SRC_MUT:-9}" = "0" ]; then
    ok "(MU5) F3/AC11 the provenance field: the control writes $MU_SRC_CTL rows carrying source=index and the mutant writes none, so nothing downstream could tell a fleet verdict from one made in the checkout — and the F4 refusal keys on exactly that field"
  else
    no "(MU5) F3/AC11: control=${MU_SRC_CTL:-0} mutant=${MU_SRC_MUT:-?} rows with source=index — the field assertion is not attributable"
  fi
else
  mut2_failed fleetnosource
fi

# THE ONE THAT MATTERS: the mtime assertion itself. A mutant that touches another checkout must be
# caught, and it must be caught BY NAME.
if mut2_build fleettouchesrepo; then
  snapshot5 "$T5/mu-before.tsv" >/dev/null
  MU_FRC="$(fleet5 "$T2/mut-fleettouchesrepo")"
  snapshot5 "$T5/mu-after.tsv" >/dev/null
  python3 "$SNAP" diff "$T5/mu-before.tsv" "$T5/mu-after.tsv" "$FLEET_HOME/backlog-verdicts/" \
    >"$T5/mu-fleet.diff" 2>&1
  MU_OUT="$(sed -n 's/^OUTSIDE=//p' "$T5/mu-fleet.diff" | head -1)"
  if [ "${MU_OUT:-0}" -ge 1 ] && grep -q "^CHANGED=$FLEET_ROOT/.*memory/backlog.md" "$T5/mu-fleet.diff"; then
    ok "(MU5) F2b/AC11 the mtime snapshot is load-bearing: a lane that calls os.utime on another checkout's backlog.md is caught and NAMED ($(grep -m1 '^CHANGED=' "$T5/mu-fleet.diff" | sed "s|$T5|\$T5|")) — $MU_OUT path(s) outside the permitted subtree, with no byte of content changed, which a content-only check would have missed entirely"
  else
    no "(MU5) F2b/AC11: the fleettouchesrepo mutant produced OUTSIDE=${MU_OUT:-0} (rc=$MU_FRC) — the whole read-only claim rests on a snapshot that notices nothing: $(grep -E '^(CHANGED|ALLOWED|OUTSIDE)=' "$T5/mu-fleet.diff" | head -3 | tr '\n' ' ')"
  fi
else
  mut2_failed fleettouchesrepo
fi
if mut2_build fleetnorefuse; then
  MU_GF="$(apply4 "$T2/mut-fleetnorefuse" "$GR2" --fleet)"
  [ "$MU_GF" != "$RC_FLEET_N" ] \
    && ok "(MU5) F5/AC11 \`apply --fleet\`'s rejection: the control exits RC_FLEET=$RC_FLEET_N and the mutant $MU_GF — without that line a fleet-shaped command line quietly performs a per-repo closure" \
    || no "(MU5) F5/AC11: the mutant still exits $MU_GF, so the rejection is not attributable to that line"
else
  mut2_failed fleetnorefuse
fi
if mut2_build fleetnoindexrefuse; then
  MU_IR="$(apply4 "$T2/mut-fleetnoindexrefuse" "$IR")"
  [ "$MU_IR" != "$RC_INDEX_N" ] \
    && ok "(MU5) F4/AC11 the source=index refusal: the control exits RC_INDEX=$RC_INDEX_N and the mutant $MU_IR — a closure decided from a 400-character prefix of an entry would otherwise be performed" \
    || no "(MU5) F4/AC11: the mutant still exits $MU_IR"
else
  mut2_failed fleetnoindexrefuse
fi
if mut2_build fleetemptyok; then
  MU_ERC="$(ZUVO_DIR="$FLEET_HOME" ZUVO_BACKLOG_OUT="$T5/empty.jsonl" \
    python3 "$T2/mut-fleetemptyok/backlog-groom.py" plan --repo "$T5" --fleet \
    >"$T5/mu-empty.out" 2>&1; printf '%s\n' "$?")"
  [ "$MU_ERC" = "0" ] \
    && ok "(MU5) F6/AC11 the empty-snapshot refusal: the mutant exits 0 over zero rows — a clean pass over nothing, reported exactly like a fleet that was verified" \
    || no "(MU5) F6/AC11: the mutant exited $MU_ERC, so the refusal is not attributable to that line"
else
  mut2_failed fleetemptyok
fi

if python3 "$MKMUT2" "$SCRIPTS" no-such-task-5-mutation "$T5/mut-bogus" >/dev/null 2>&1; then
  no "(MU5-0) the factory accepted an unknown mutation and wrote a copy — every 'the mutant failed' above could mean 'the mutation was never made'"
else
  ok "(MU5-0) the factory still hard-errors on a mutation it cannot apply, which is what makes the Task 5 mutations above statements about mutated code"
fi


# ==================================================================================================
# S6 — THE WIRING (Task 6). The three modes are reachable from `skills/backlog/SKILL.md`, the include
# is in the Phase 0 list at the canonical depth, and `docs/skills.md`'s row was EXTENDED.
#
# THE DEFECT THIS GROUP EXISTS FOR. The plan that commissioned the feature names `verify --fleet` and
# `groom --fleet` four times each as if they were commands. They are not: the CLI is
# `{plan, dispatch, ingest, apply, render, coverage}`. So this skill keeps `verify`/`groom`/`doc` as
# MODE WORDS and states the mapping onto the real commands in exactly one place — and the assertions
# below are about that mapping rather than about the words, because two names in two places drifting
# apart is the whole failure mode. S6d derives the legal command set FROM `--help`, so a mapping that
# invents a seventh command fails without anyone updating a list in this file.
# ==================================================================================================
echo "-- S6: the three modes, the mapping, and the Phase 0 include --"
T6="$FIX/t6"; mkdir -p "$T6"
SKILL6="$ROOT/skills/backlog/SKILL.md"
DOCS6="$ROOT/docs/skills.md"
RUNLOG6="$ROOT/scripts/zuvo-home/append-runlog"
for f in "$SKILL6" "$DOCS6" "$RUNLOG6"; do
  [ -f "$f" ] && ok "(S6-0) present: ${f#"$ROOT"/}" \
    || { no "(S6-0) missing: ${f#"$ROOT"/} — nothing in this group can be checked"; finish; }
done

# The prober. It takes the file as argv[1] so a MUTATED COPY is reached by pointing at it, never by
# editing the repo file — the same rule the module probes follow.
S6PROBE="$T6/skillprobe.py"
cat > "$S6PROBE" <<'PYEOF'
r"""Machine-readable probe over skills/backlog/SKILL.md. RAW docstring, same reason as the others'.

Usage: skillprobe.py <SKILL.md>

Every answer is derived from STRUCTURE — which table, which cell, which fence — because the words
`verify`, `groom` and `doc` appear in this file as prose too, and a grep for them would report the
prose as the wiring.
"""
import re
import sys

TEXT = open(sys.argv[1], encoding="utf-8").read()
LINES = TEXT.split("\n")


def out(key, value):
    print("%s=%s" % (key, value))


def slug(heading):
    s = heading.strip().lower()
    s = re.sub(r"[^a-z0-9 \-]", "", s)
    return re.sub(r"\s+", "-", s).strip("-")


# --- fences: which lines are inside one, so prose and code are never confused -------------------
inside, fence = [False] * (len(LINES) + 1), False
for i, ln in enumerate(LINES, 1):
    if ln.lstrip().startswith("```"):
        fence = not fence
        inside[i] = True            # the fence line itself counts as code, not prose
        continue
    inside[i] = fence

# --- headings and their slugs --------------------------------------------------------------------
slugs = set()
for i, ln in enumerate(LINES, 1):
    if not inside[i] and re.match(r"^#{1,6} ", ln):
        slugs.add(slug(re.sub(r"^#{1,6} ", "", ln)))
out("NSLUGS", len(slugs))

# --- the Argument Parsing table -----------------------------------------------------------------
rows, seen_ap = [], False
for i, ln in enumerate(LINES, 1):
    if re.match(r"^## Argument Parsing", ln):
        seen_ap = True
        continue
    if seen_ap and re.match(r"^#{2,3} ", ln):
        break
    if seen_ap and ln.startswith("|") and not re.match(r"^\|[\s:|-]+\|?\s*$", ln):
        rows.append([c.strip() for c in ln.strip().strip("|").split("|")])
# the header row is NOT an entry: it is the column names, and counting it inflates every total
body = [r for r in rows if not (r and r[0].lower() in ("input", "**input**"))]
out("ARGROWS", len(body))
for mode in ("verify", "groom", "doc"):
    hit = [r for r in body if re.match(r"^`%s\b" % mode, r[0])]
    if not hit:
        continue
    out("MODEROW", mode)
    for anchor in re.findall(r"\]\(#([a-z0-9-]+)\)", " ".join(hit[0])):
        out("MODEANCHOR", "%s:%s:%s" % (mode, anchor, "resolves" if anchor in slugs else "DANGLING"))

# --- the mapping table: identified by its COLUMN NAMES, so there can be provably one ------------
maps, n_maptables = [], 0
for i, ln in enumerate(LINES, 1):
    if inside[i] or not ln.startswith("|"):
        continue
    cells = [c.strip().lower() for c in ln.strip().strip("|").split("|")]
    if cells[:3] == ["mode", "runs", "phase section"]:
        n_maptables += 1
        for ln2 in LINES[i:]:
            if not ln2.startswith("|"):
                break
            c2 = [c.strip() for c in ln2.strip().strip("|").split("|")]
            if re.match(r"^\|[\s:|-]+\|?\s*$", ln2) or len(c2) < 2:
                continue
            mode = re.findall(r"`([a-z]+)`", c2[0])
            runs = re.findall(r"`([a-z]+)`", c2[1])
            if mode and runs:
                maps.append((mode[0], runs))
out("MAPTABLES", n_maptables)
for mode, runs in maps:
    out("MAPRUNS", "%s:%s" % (mode, ",".join(runs)))

# --- every `backlog-groom.py <word>` invocation that appears INSIDE a fence ----------------------
# This is the half that catches a mode word presented as a command: the fences must only ever name
# commands the CLI has.
for i, ln in enumerate(LINES, 1):
    if inside[i]:
        for m in re.findall(r"backlog-groom\.py\s+([a-z-]+)", ln):
            out("FENCECMD", m)

# --- the include token: inside the Phase 0 LOADING LIST, and anywhere -------------------------
TOK = re.compile(r"((?:\.\./)+shared/includes/backlog-grooming\.md)")
for i, ln in enumerate(LINES, 1):
    for m in TOK.findall(ln):
        out("ANYTOK", m)
        if re.match(r"^\s*\d+\.\s", ln):
            out("LOADTOK", m)

out("NOTCOMMANDS", int("are not commands" in TEXT))
out("FLEETREAD", int("plan --fleet" in TEXT))
out("FLEETREJECT", int("apply --fleet" in TEXT))
PYEOF

S6DOCS="$T6/docsprobe.py"
cat > "$S6DOCS" <<'PYEOF'
r"""Machine-readable probe over docs/skills.md. RAW docstring, same reason.

Usage: docsprobe.py <docs/skills.md>

The three numbers `validate-skills.sh` cross-checks are emitted SEPARATELY (per-skill row count, the
category-table sum, the Total row), because a duplicated row passes a naive grep for the skill name
and fails exactly those.
"""
import re
import sys

LINES = open(sys.argv[1], encoding="utf-8").read().split("\n")


def out(key, value):
    print("%s=%s" % (key, value))


skills, catsum, total, utility = set(), 0, "", ""
nrows = 0
for ln in LINES:
    for m in re.findall(r"^\| `zuvo:([a-z0-9-]+)` \|", ln):
        skills.add(m)
        if m == "backlog":
            nrows += 1
            cells = [c.strip() for c in ln.strip().strip("|").split("|")]
            # The LAST cell only — the switches column. The description cell names the three modes in
            # prose too, so including it made the assertion pass on a row whose switches list was
            # stripped entirely, which is the one thing it exists to notice.
            for mode in ("verify", "groom", "doc"):
                if re.search(r"`%s( |\]|`)" % mode, cells[-1]):
                    out("BLMODE", mode)
    m = re.match(r"^\| ([A-Za-z/ ]+) \| (\d+) \|", ln)
    if m:
        catsum += int(m.group(2))
        if m.group(1).strip() == "Utility":
            utility = m.group(2)
    m = re.match(r"^\| \*\*Total\*\* \| \*\*(\d+)\*\*", ln)
    if m:
        total = m.group(1)
out("BACKLOGROWS", nrows)
out("NSKILLS", len(skills))
out("CATSUM", catsum)
out("TOTAL", total)
out("UTILITY", utility)
PYEOF

s6(){ python3 "$S6PROBE" "$1" 2>&1; }
s6d(){ python3 "$S6DOCS" "$1" 2>&1; }
S6OUT="$T6/skill.out"; s6 "$SKILL6" >"$S6OUT"
S6DOUT="$T6/docs.out"; s6d "$DOCS6" >"$S6DOUT"
S6_NSLUGS="$(sed -n 's/^NSLUGS=//p' "$S6OUT")"
S6_ARGROWS="$(sed -n 's/^ARGROWS=//p' "$S6OUT")"
# THE CENSUS, PRINTED. A probe that found no headings, no table rows and no fences would report every
# absence below as a clean pass — Task 4's write-discipline assertions had an N=0 subject and passed.
echo "      census: ${S6_NSLUGS:-0} headings, ${S6_ARGROWS:-0} Argument Parsing rows, \
$(grep -c '^MAPRUNS=' "$S6OUT") mapping rows, $(grep -c '^FENCECMD=' "$S6OUT") fenced commands, \
$(grep -c '^ANYTOK=' "$S6OUT") include tokens; docs/skills.md: $(sed -n 's/^NSKILLS=//p' "$S6DOUT") skills"
{ [ "${S6_NSLUGS:-0}" -ge 10 ] && [ "${S6_ARGROWS:-0}" -ge 10 ] && [ "$(grep -c '^FENCECMD=' "$S6OUT")" -ge 3 ]; } \
  && ok "(S6-1) the prober resolved $S6_NSLUGS headings, $S6_ARGROWS Argument Parsing rows and $(grep -c '^FENCECMD=' "$S6OUT") fenced invocations — the subject of every assertion below is non-empty" \
  || { no "(S6-1) the prober found headings=${S6_NSLUGS:-0} argrows=${S6_ARGROWS:-0} fencecmds=$(grep -c '^FENCECMD=' "$S6OUT") — every assertion below would be about nothing: $(tail -2 "$S6OUT")"; finish; }

S6_MISS=""
for mode in verify groom doc; do
  grep -qx "MODEROW=$mode" "$S6OUT" || S6_MISS="$S6_MISS $mode"
done
[ -z "$S6_MISS" ] \
  && ok "(S6a/AC12) all three modes have a row in the Argument Parsing table (of $S6_ARGROWS rows), not a mention somewhere in the prose" \
  || no "(S6a/AC12) the Argument Parsing table has no row for:$S6_MISS"

S6_ANCH=""
for mode in verify groom doc; do
  grep -qx "MODEANCHOR=$mode:mode-$mode:resolves" "$S6OUT" \
    || S6_ANCH="$S6_ANCH $mode($(sed -n "s/^MODEANCHOR=$mode://p" "$S6OUT" | tr '\n' ',' || true))"
done
[ -z "$S6_ANCH" ] \
  && ok "(S6b/AC12) each of the three rows NAMES its phase section and the link resolves to a heading in the same file" \
  || no "(S6b/AC12) a row's phase-section link is missing or dangling:$S6_ANCH"

# --- the mapping, stated ONCE and checked against the CLI that exists --------------------------
S6_MAPT="$(sed -n 's/^MAPTABLES=//p' "$S6OUT")"
[ "${S6_MAPT:-0}" = "1" ] \
  && ok "(S6c/AC12) the mode-word mapping is stated in exactly ONE table — two copies is the drift this task was briefed to prevent" \
  || no "(S6c/AC12) the file carries ${S6_MAPT:-0} mapping tables; the brief asks for one place, not two names drifting apart"
S6_MAPBAD=""
grep -qx 'MAPRUNS=verify:plan,dispatch,ingest' "$S6OUT" || S6_MAPBAD="$S6_MAPBAD verify"
grep -qx 'MAPRUNS=groom:apply' "$S6OUT" || S6_MAPBAD="$S6_MAPBAD groom"
grep -qx 'MAPRUNS=doc:render' "$S6OUT" || S6_MAPBAD="$S6_MAPBAD doc"
[ -z "$S6_MAPBAD" ] \
  && ok "(S6c2/AC12) the mapping is the real one: verify -> plan,dispatch,ingest · groom -> apply · doc -> render" \
  || no "(S6c2/AC12) the mapping does not say what Task 5 measured for:$S6_MAPBAD — $(grep '^MAPRUNS=' "$S6OUT" | tr '\n' ' ')"

# THE SUBCOMMAND SET IS DERIVED FROM `--help`, never typed here. A list in this file would have to be
# updated by the same change that invents a command, which is the one thing it must not depend on.
S6_CLI="$(python3 "$CTL2/backlog-groom.py" --help 2>&1 | sed -n 's/^usage: backlog-groom\.py \[-h\] {\([a-z,]*\)}.*/\1/p' | tr ',' '\n' | sort -u)"
S6_NCLI="$(printf '%s\n' "$S6_CLI" | grep -c . || true)"
[ "${S6_NCLI:-0}" -ge 5 ] \
  && ok "(S6d-0) the CLI's own --help names $S6_NCLI subcommands ($(printf '%s' "$S6_CLI" | tr '\n' ' ')) — the oracle below is the binary's, not a list in this file" \
  || { no "(S6d-0) --help yielded ${S6_NCLI:-0} subcommands, so S6d/S6e would compare against nothing"; }
S6_INVENT=""
while IFS= read -r tok; do
  [ -n "$tok" ] || continue
  printf '%s\n' "$S6_CLI" | grep -qx "$tok" || S6_INVENT="$S6_INVENT $tok"
done <<EOF
$(sed -n 's/^MAPRUNS=[a-z]*://p' "$S6OUT" | tr ',' '\n'; sed -n 's/^FENCECMD=//p' "$S6OUT")
EOF
[ -z "$S6_INVENT" ] \
  && ok "(S6d/AC12) every command the mapping table and every fenced invocation name is one the CLI actually has — a seventh invented name fails here without a list in this file being updated" \
  || no "(S6d/AC12) the skill names command(s) the CLI does not have:$S6_INVENT — this is the plan's own \`verify --fleet\` defect, reproduced in the skill"
{ grep -qx 'NOTCOMMANDS=1' "$S6OUT" && grep -qx 'FLEETREAD=1' "$S6OUT" && grep -qx 'FLEETREJECT=1' "$S6OUT"; } \
  && ok "(S6e/AC12) the file says plainly that the two \`--fleet\` command names the plan invented are not commands, and names \`plan --fleet\` (read-only) and \`apply --fleet\` (rejected) instead" \
  || no "(S6e/AC12) the --fleet correction is missing: $(grep -E '^(NOTCOMMANDS|FLEETREAD|FLEETREJECT)=' "$S6OUT" | tr '\n' ' ')"

# --- the include, at the EXACT canonical depth ---------------------------------------------------
# NOT a substring grep. PR 1 measured that `../../../x` CONTAINS `../../x`, so `grep -q '../../shared'`
# passes on the wrong form; the check is string EQUALITY against the canonical token, plus a count of
# every token that is deeper than two levels.
# THE RUNTIME COPY, which is the one skills LOAD. The include speaks in mode words ("partial
# verification, at `groom`"), so a reader who never opens SKILL.md would type `groom` at a shell. It
# now says in its own header that these are phases and where the mapping lives — fixed in the include
# FIRST, for the reason revision 8 records: a stale premise there beats a corrected plan.
I6_MISS=""
for lit in 'are the SKILL' "{plan, dispatch, ingest, apply, render, coverage}" \
           '`groom` is `apply`' '`doc` is `render`' 'never as something to type'; do
  grep -qF -- "$lit" "$INCLUDE" || I6_MISS="$I6_MISS [$lit]"
done
[ -z "$I6_MISS" ] \
  && ok "(S6h/AC12) shared/includes/backlog-grooming.md — the copy skills LOAD — says the mode words are phases, names the real CLI set, and points at the ONE mapping rather than carrying a second one" \
  || no "(S6h/AC12) the runtime include still presents the mode words as commands; missing:$I6_MISS"

S6_LOADTOK="$(sed -n 's/^LOADTOK=//p' "$S6OUT" | head -1)"
S6_CANON="../../shared/includes/backlog-grooming.md"
[ "$S6_LOADTOK" = "$S6_CANON" ] \
  && ok "(S6f/AC12) the Phase 0 loading list carries the include at EXACTLY '$S6_CANON' (string equality, not a substring match that '../../../shared/includes/backlog-grooming.md' would also satisfy)" \
  || no "(S6f/AC12) the Phase 0 loading list's include token is '${S6_LOADTOK:-<absent>}', not '$S6_CANON' — check_include_integrity fails a SKILL.md-level file at any other depth"
S6_DEEP=0
while IFS= read -r tok; do
  case "$tok" in ../../../*) S6_DEEP=$((S6_DEEP + 1)) ;; esac
done <<EOF
$(sed -n 's/^ANYTOK=//p' "$S6OUT")
EOF
[ "$S6_DEEP" = "0" ] \
  && ok "(S6f2/AC12) no reference to the include anywhere in the file is deeper than two levels ($(grep -c '^ANYTOK=' "$S6OUT") token(s) checked)" \
  || no "(S6f2/AC12) $S6_DEEP reference(s) sit at ../../../ or deeper; a SKILL.md-level file reaches the root at ../../"

# --- docs/skills.md: the row is EXTENDED, and the three counts still agree ----------------------
S6_BLROWS="$(sed -n 's/^BACKLOGROWS=//p' "$S6DOUT")"
S6_TOTAL="$(sed -n 's/^TOTAL=//p' "$S6DOUT")"
S6_CATSUM="$(sed -n 's/^CATSUM=//p' "$S6DOUT")"
S6_NSK="$(sed -n 's/^NSKILLS=//p' "$S6DOUT")"
S6_UTIL="$(sed -n 's/^UTILITY=//p' "$S6DOUT")"
[ "${S6_BLROWS:-0}" = "1" ] \
  && ok "(S6g/G1) docs/skills.md has exactly ONE \`zuvo:backlog\` row — the existing one was extended, and a second row would pass a grep for the name while failing the category sum" \
  || no "(S6g/G1) docs/skills.md has ${S6_BLROWS:-0} \`zuvo:backlog\` rows"
S6_DMISS=""
for mode in verify groom doc; do grep -qx "BLMODE=$mode" "$S6DOUT" || S6_DMISS="$S6_DMISS $mode"; done
[ -z "$S6_DMISS" ] \
  && ok "(S6g2/G1) …and that one row names all three modes in its switches column" \
  || no "(S6g2/G1) the backlog row does not name:$S6_DMISS"
{ [ -n "$S6_TOTAL" ] && [ "$S6_CATSUM" = "$S6_TOTAL" ] && [ "$S6_UTIL" = "10" ]; } \
  && ok "(S6g3/G1) the category sum ($S6_CATSUM, Utility still 10) and the **Total** row ($S6_TOTAL) agree — the two numbers validate-skills.sh:561,564 and :601 assert in addition to the intro's 'N skills', and extending a row moves neither" \
  || no "(S6g3/G1) they disagree: catsum=$S6_CATSUM total=$S6_TOTAL utility=$S6_UTIL"
# REPORTED, NOT ASSERTED, because it is PRE-EXISTING and outside this task: the per-skill table holds
# $S6_NSK rows against a Total of $S6_TOTAL. Measured at Task 6: `agent-benchmark` and `leads` have a
# category-table entry and no per-skill row, and `validate-skills.sh` checks the intro, the category
# sum and the Total row — never the row count — so nothing catches it. Turning it into an assertion
# here would make the suite red for work this task did not do; naming it is the honest half.
if [ "$S6_NSK" != "$S6_TOTAL" ]; then
  echo "      NOTE: docs/skills.md per-skill rows=$S6_NSK vs Total=$S6_TOTAL — missing:$(
    for d in "$ROOT"/skills/*/SKILL.md; do
      n="$(basename "$(dirname "$d")")"
      grep -qF "| \`zuvo:$n\` |" "$DOCS6" || printf ' %s' "$n"
    done)  (pre-existing, no gate covers it)"
fi

# ==================================================================================================
# NU — THE NUDGE, ASSERTED TWICE. Decision 9's one count, wired into `append-runlog`.
#
# WHY TWICE, and the lesson is older than this plan. A14: the archiver shipped and two days later not
# one repo in the fleet had used it, because its only trigger was prose. A19: the same month, a check
# asserted by grep alone was wired into a branch that never ran. So the grep half (NU1/NU2) says the
# block is THERE and carries no `exit`, and the RUN half (NU3-NU6) says it FIRES — in a throwaway
# `ZUVO_HOME`, with the real `~/.zuvo/runs.log` proved untouched afterwards and the throwaway proved
# written, because "the real log is clean" is also what a hook that appended nothing anywhere looks
# like. A29's pair is the other direction: the nudge surfaces on an incomplete repo and a fully
# verified one prints NOTHING, so the line is only ever seen where there is something to do.
# ==================================================================================================
echo "-- NU: the status nudge, by grep AND by running it --"
NU_REAL="$HOME/.zuvo/runs.log"
NU_PROJ="zuvo-t6-nudge-$$-$(date -u +%H%M%S)"
nu_realn(){ if [ -f "$NU_REAL" ]; then awk 'END{print NR}' "$NU_REAL"; else echo 0; fi; }
NU_REAL_N0="$(nu_realn)"

cat > "$T6/bl-nudge.md" <<'EOF'
# Tech Debt Backlog

## Open

- [ ] B-nudge-one tools/present.py the retry budget here is still unbounded today
- [ ] B-nudge-two tools/present.py a second open entry nothing has judged yet at all
- [ ] B-nudge-three tools/present.py a third open entry with different words entirely
EOF
NU_FULL="$(mkrepo4 "$T6/bl-nudge.md" "")"  || { no "(NU0) the verified fixture repo could not be built"; finish; }
NU_SHORT="$(mkrepo4 "$T6/bl-nudge.md" "")" || { no "(NU0) the incomplete fixture repo could not be built"; finish; }
NU_STALE="$(mkrepo4 "$T6/bl-nudge.md" "")" || { no "(NU0) the stale-sha fixture repo could not be built"; finish; }
# The A29 shape: a real backlog, entries in it, and NO ledger — i.e. verification never started here.
# This is the steady state of ~65 repos in the fleet, and the fixture exists because the first version
# of the nudge printed on it and turned test-backlog-archive-dedup.sh (A29) red.
NU_NOLED="$(mkrepo4 "$T6/bl-nudge.md" "")" || { no "(NU0) the no-ledger fixture repo could not be built"; finish; }
# Three DISTINCT directories, checked rather than assumed: `mkrepo4` once incremented its scenario
# counter inside `$( )` and every scenario shared one directory, which made a byte-equality check
# compare a file with itself and pass. Same subshell-discard class, third appearance in this plan.
NU_NDIR="$(printf '%s\n' "$NU_FULL" "$NU_SHORT" "$NU_STALE" "$NU_NOLED" | sort -u | grep -c .)"
if [ "${NU_NDIR:-0}" = "4" ]; then
  ok "(NU0a) the four fixture repos are four directories ($(basename "$NU_FULL")/$(basename "$NU_SHORT")/$(basename "$NU_STALE")/$(basename "$NU_NOLED")) — a shared one would make the verified/incomplete comparison a file against itself"
else
  no "(NU0a) the four fixture repos resolve to only ${NU_NDIR:-0} directories; every comparison below would be vacuous"
  finish
fi
led4 "$NU_FULL"  >/dev/null 2>&1
led4 "$NU_SHORT" --skip 1 >/dev/null 2>&1
led4 "$NU_STALE" >/dev/null 2>&1
# The stale fixture: every row still VALID and still key-resolvable, but its `text_sha` moved. That is
# the difference between the ledger's own `coverage` and a row count, and the only fixture on which the
# two disagree — so the mutant that swaps one for the other has something to be caught by.
python3 - "$NU_STALE/memory/backlog-verdicts.jsonl" <<'PYEOF' >"$T6/stale.out" 2>&1
import json
import sys
rows = [json.loads(ln) for ln in open(sys.argv[1], encoding="utf-8") if ln.strip()]
for r in rows:
    r["text_sha"] = "a" * 40
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
print("STALED=%d" % len(rows))
PYEOF
# POSITIVE CONTROL on all three ledgers, through the LEDGER'S OWN reader: a fixture whose rows are
# defective would report "unverified" for the wrong reason, and every assertion below would be about a
# broken fixture rather than about coverage.
python3 - "$CTL2" "$NU_FULL" "$NU_SHORT" "$NU_STALE" <<'PYEOF' >"$T6/led.out" 2>&1
import os
import sys
sys.path.insert(0, sys.argv[1])
import zuvo_backlog_ledger as zl   # noqa: E402
for repo in sys.argv[2:]:
    read = zl.read_ledger(os.path.join(repo, "memory", "backlog-verdicts.jsonl"))
    print("LED=%s rows=%d defects=%d" % (os.path.basename(repo), len(read.rows), len(read.defects)))
PYEOF
cat "$T6/led.out" | sed 's/^/      /'
NU_LEDOK="$(grep -c 'defects=0' "$T6/led.out" || true)"
{ [ "${NU_LEDOK:-0}" = "3" ] && grep -q 'rows=3' "$T6/led.out" && grep -q 'rows=2' "$T6/led.out" \
  && grep -qx 'STALED=3' "$T6/stale.out"; } \
  && ok "(NU0b) the three fixture ledgers read as 3 / 2 / 3 valid rows with ZERO defects, and the stale one had all 3 shas moved — so 'unverified' below is attributable to coverage, never to a broken row" \
  || no "(NU0b) fixture ledgers: $(tr '\n' ' ' < "$T6/led.out") / $(cat "$T6/stale.out") — the comparisons below would not be attributable"

# --- NU1/NU2: the grep half, over an exact marker range ------------------------------------------
NOEXIT6="$T6/noexit.py"
cat > "$NOEXIT6" <<'PYEOF'
r"""Is there an `exit` at CODE position inside the marker-delimited nudge block?

Usage: noexit.py <append-runlog>

RAW docstring, same reason as every other probe here. Comment-only lines and trailing ` #` comments
are stripped FIRST, because the block's own comments explain the no-exit contract in words — a raw
grep would read the explanation as the defect it forbids, which is the same class as the sys.path
detector next door being asked of the syntax tree instead of of a grep.
"""
import re
import sys

LINES = open(sys.argv[1], encoding="utf-8").read().split("\n")
OPEN = ">>> zuvo-backlog-verdict-nudge"
CLOSE = "<<< zuvo-backlog-verdict-nudge <<<"
lo = [i for i, ln in enumerate(LINES, 1) if OPEN in ln]
hi = [i for i, ln in enumerate(LINES, 1) if CLOSE in ln]
print("OPENMARKERS=%d" % len(lo))
print("CLOSEMARKERS=%d" % len(hi))
if len(lo) != 1 or len(hi) != 1 or hi[0] <= lo[0]:
    print("RANGE=none")
    raise SystemExit(0)
print("RANGE=%d,%d" % (lo[0], hi[0]))
code, exits, calls = 0, [], 0
for i in range(lo[0], hi[0] + 1):
    raw = LINES[i - 1]
    if not raw.strip() or raw.strip().startswith("#"):
        continue
    stripped = re.sub(r"\s#.*$", "", raw)
    code += 1
    if re.search(r"(?:^|[;&|(){} ])exit(?:$|[ ;&|)])", stripped):
        exits.append("L%d:%s" % (i, stripped.strip()))
    # ` coverage --repo ` and not ` coverage `: the block's fallback WARN says "verdict coverage NOT
    # reported", which the looser form counted as a second invocation.
    if "backlog-groom.py" in stripped and " coverage --repo " in stripped:
        calls += 1
print("CODELINES=%d" % code)
print("EXITS=%d" % len(exits))
for e in exits:
    print("EXITLINE=%s" % e)
print("CALLSCOVERAGE=%d" % calls)
PYEOF
nu_noexit(){ python3 "$NOEXIT6" "$1" 2>&1; }
nu_noexit "$RUNLOG6" >"$T6/noexit.out"
cat "$T6/noexit.out" | sed 's/^/      /'
NU_RANGE="$(sed -n 's/^RANGE=//p' "$T6/noexit.out")"
NU_CODE="$(sed -n 's/^CODELINES=//p' "$T6/noexit.out")"
{ grep -qx 'OPENMARKERS=1' "$T6/noexit.out" && grep -qx 'CLOSEMARKERS=1' "$T6/noexit.out" \
  && [ "${NU_CODE:-0}" -ge 8 ]; } \
  && ok "(NU1/AC12) append-runlog carries the nudge block exactly once (lines $NU_RANGE, $NU_CODE code lines) — an empty or duplicated range would make NU2 a statement about nothing" \
  || { no "(NU1/AC12) the nudge block's markers are not a single well-formed range: $(tr '\n' ' ' < "$T6/noexit.out")"; }
grep -qx 'CALLSCOVERAGE=1' "$T6/noexit.out" \
  && ok "(NU1b/AC12) …and it is the block that invokes \`backlog-groom.py coverage\`, so the grep half and the run half are about the same lines" \
  || no "(NU1b/AC12) the block does not invoke \`backlog-groom.py coverage\`: $(grep '^CALLSCOVERAGE=' "$T6/noexit.out")"
grep -qx 'EXITS=0' "$T6/noexit.out" \
  && ok "(NU2/AC12) there is NO \`exit\` at code position anywhere in the block — non-blocking by contract, because an \`exit\` here turns a diagnostic into a gate on runs that have nothing to do with the backlog" \
  || no "(NU2/AC12) the block contains $(sed -n 's/^EXITS=//p' "$T6/noexit.out") exit(s): $(sed -n 's/^EXITLINE=//p' "$T6/noexit.out" | tr '\n' ' ')"

# --- NU3-NU6: the run half ------------------------------------------------------------------------
# Every run gets its OWN throwaway ZUVO_HOME and its own project token, so the real log can be checked
# by ATTRIBUTION (does our token appear anywhere in it) as well as by line delta — the attribution
# check is the one that stays true while another zuvo run on this host appends to the same file.
# A BIN DIR OF ITS OWN, with the two helper modes set EXPLICITLY. Two reasons, both measured here:
# the Task 2 factory's copies lose the executable bit, and `append-runlog`'s namespace gate tests
# `[ -x backlog-archive.py ]` — so running against the factory's directory made every run print a WARN
# about an un-executable helper, which would have turned NU4's "a verified repo prints NOTHING" into a
# statement about this suite's file modes. And `backlog-groom.py` is deliberately left at 644, which is
# how it ships: the nudge reaches it through `sh`, so an `[ -x ]` guard there would skip the nudge on
# every machine in the fleet, silently.
NU_BIN="$T6/bin"; mkdir -p "$NU_BIN"
cp "$CTL2"/*.py "$NU_BIN/" || { no "(NU0c) the nudge bin dir could not be assembled — the runs below would be about nothing"; finish; }
chmod 755 "$NU_BIN/backlog-archive.py"
chmod 644 "$NU_BIN/backlog-groom.py"
{ [ -x "$NU_BIN/backlog-archive.py" ] && [ ! -x "$NU_BIN/backlog-groom.py" ]; } \
  && ok "(NU0c) the run fixture ships backlog-archive.py executable and backlog-groom.py at 644, exactly as install.sh lays them down — so NU3 below proves the nudge fires on a helper no \`[ -x ]\` guard would have run" \
  || no "(NU0c) the fixture's helper modes are not the shipped ones: archive=$(mode4 "$NU_BIN/backlog-archive.py") groom=$(mode4 "$NU_BIN/backlog-groom.py")"

NU_SEQ=0
nu_next(){ NU_SEQ=$((NU_SEQ + 1)); }     # a plain function, NEVER inside $( ), for the Task 4 reason
nu_run(){    # runlog, bindir, repo, tag -> echoes rc; leaves $T6/nu-<tag>.{out,err} and the home
  local rl="$1" bin="$2" repo="$3" tag="$4" home ts line
  home="$T6/home-$tag"; rm -rf "$home"; mkdir -p "$home"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  line="$(printf '%s\tbacklog\t%s\t-\t-\tOK\t-\tlist\t-\tmain\tabcdef1\t-\t-' "$ts" "$NU_PROJ")"
  ( cd "$repo" && ZUVO_HOME="$home" ZUVO_BIN="$bin" "$rl" "$line" ) \
    >"$T6/nu-$tag.out" 2>"$T6/nu-$tag.err"
  printf '%s\n' "$?"
}
nu_next; NU_SHORT_RC="$(nu_run "$RUNLOG6" "$NU_BIN" "$NU_SHORT" "short$NU_SEQ")"
NU_SHORT_ERR="$T6/nu-short$NU_SEQ.err"; NU_SHORT_HOME="$T6/home-short$NU_SEQ"
nu_next; NU_FULL_RC="$(nu_run "$RUNLOG6" "$NU_BIN" "$NU_FULL" "full$NU_SEQ")"
NU_FULL_ERR="$T6/nu-full$NU_SEQ.err"; NU_FULL_HOME="$T6/home-full$NU_SEQ"
echo "      incomplete repo: rc=$NU_SHORT_RC stderr=[$(tr '\n' '|' < "$NU_SHORT_ERR")]"
echo "      verified   repo: rc=$NU_FULL_RC stderr=[$(tr '\n' '|' < "$NU_FULL_ERR")]"

grep -qx '1 of 3 entries carry no verdict — run zuvo:backlog verify' "$NU_SHORT_ERR" \
  && ok "(NU3/AC12) RUN, not grepped: the nudge reaches stderr on a repo whose ledger covers 2 of 3 entries, naming the count and the mode to run" \
  || no "(NU3/AC12) the nudge did not appear on stderr for the incomplete repo: [$(tr '\n' '|' < "$NU_SHORT_ERR")]"
[ "$NU_SHORT_RC" = "0" ] \
  && ok "(NU3b/AC12) …and the run still exits 0 — the pre-change value, measured on this same fixture before the block existed (NU3c derives it from the nudge-removed mutant rather than trusting this number)" \
  || no "(NU3b/AC12) the run exited $NU_SHORT_RC; a non-blocking nudge must not move the exit code (pre-change: 0)"
[ ! -s "$NU_FULL_ERR" ] \
  && ok "(NU4/AC12) A29's pair: a FULLY verified repo prints nothing at all on stderr, so the nudge is only ever seen where there is something to do" \
  || no "(NU4/AC12) the fully verified repo still printed: [$(tr '\n' '|' < "$NU_FULL_ERR")]"
[ "$NU_FULL_RC" = "0" ] \
  && ok "(NU4b/AC12) …and it exits 0 as well" \
  || no "(NU4b/AC12) the verified repo's run exited $NU_FULL_RC"
# THE THIRD SILENCE, and it is the one that was a DEFECT rather than a preference. A repo with a real
# backlog and NO ledger has not started verifying, so there is nothing to resume and nothing to say.
# The first version of this block printed here, and tests/hooks/test-backlog-archive-dedup.sh (A29) —
# "a run with nothing to archive prints NOTHING on stderr … or every run prints noise" — went red on
# the identical fixture shape. Asserted HERE as well as there, because this is the block that owns it.
[ ! -f "$NU_NOLED/memory/backlog-verdicts.jsonl" ] \
  && ok "(NU4c-0) the no-ledger fixture really has no ledger — the silence below is about an absent ledger, not about an empty one" \
  || no "(NU4c-0) the no-ledger fixture carries a ledger after all; NU4c would measure the wrong thing"
nu_next; NU_NOLED_RC="$(nu_run "$RUNLOG6" "$NU_BIN" "$NU_NOLED" "noled$NU_SEQ")"
NU_NOLED_ERR="$T6/nu-noled$NU_SEQ.err"
echo "      no-ledger  repo: rc=$NU_NOLED_RC stderr=[$(tr '\n' '|' < "$NU_NOLED_ERR")]"
{ [ ! -s "$NU_NOLED_ERR" ] && [ "$NU_NOLED_RC" = "0" ]; } \
  && ok "(NU4c/AC12) a repo with 3 unverified entries and NO ledger prints NOTHING and exits 0 — an unverified backlog is the steady state in ~65 repos, so a line there is a line on every run of every skill for ever" \
  || no "(NU4c/AC12) the no-ledger repo printed [$(tr '\n' '|' < "$NU_NOLED_ERR")] at rc=$NU_NOLED_RC — this is the A29 noise regression, in the stream A29 measures"

# THE ASSERTION THE BRIEF CALLS THE ONE THAT MATTERS: the real log was not polluted. Checked by
# ATTRIBUTION over the whole file (our token is unique to this run), not only by a line delta — a
# delta can move because another zuvo run on this host finished mid-suite, and reporting THAT as this
# suite's write would be a false red exactly where a false green would be worse.
NU_REAL_N1="$(nu_realn)"
NU_OURS="$(grep -c "$NU_PROJ" "$NU_REAL" 2>/dev/null || true)"
echo "      real $NU_REAL: $NU_REAL_N0 -> $NU_REAL_N1 lines, rows carrying our token: ${NU_OURS:-0}"
[ "${NU_OURS:-0}" = "0" ] \
  && ok "(NU5/AC12) the real $NU_REAL carries ZERO rows for this run's project token — the throwaway ZUVO_HOME really did redirect the state, and the line delta over the whole group was $((NU_REAL_N1 - NU_REAL_N0))" \
  || no "(NU5/AC12) ${NU_OURS} row(s) of this suite's own run reached the real $NU_REAL — the hermetic override is not holding"
# …and the positive control for it, without which NU5 also passes when the hook appends NOWHERE.
NU_H1="$(awk 'END{print NR}' "$NU_SHORT_HOME/runs.log" 2>/dev/null || echo 0)"
NU_H2="$(awk 'END{print NR}' "$NU_FULL_HOME/runs.log" 2>/dev/null || echo 0)"
{ [ "${NU_H1:-0}" = "1" ] && [ "${NU_H2:-0}" = "1" ] \
  && grep -q "$NU_PROJ" "$NU_SHORT_HOME/runs.log" && grep -q "$NU_PROJ" "$NU_FULL_HOME/runs.log"; } \
  && ok "(NU6/AC12) both runs DID append their row — to the throwaway home, one line each, carrying this run's token: so NU5's clean real log is redirection, not a hook that wrote nothing anywhere" \
  || no "(NU6/AC12) the throwaway homes hold $NU_H1 / $NU_H2 rows — NU5 would pass on a hook that appended nothing at all"

# --- NU8: an ABSENT helper is silent too, and that differs from the two gates above ----------------
# A ~/.zuvo that predates this feature has no backlog-groom.py in it, which is every machine until
# `install.sh` runs once. A WARN there is a line on every run of every skill in that window. The two
# gates above DO warn when their helper is missing, because their silence could hide a namespace
# violation; this block makes exactly one claim — a count — so saying nothing claims nothing.
# EVERY sibling travels except the one under test. The first version copied only backlog-archive.py
# and it died with ModuleNotFoundError on zuvo_backlog_parse — an import error wearing an absence's
# clothes, inside the assertion that exists to prove the absence is handled.
mkdir -p "$T6/emptybin"
for f in "$NU_BIN"/*.py; do
  case "$(basename "$f")" in backlog-groom.py) ;; *) cp "$f" "$T6/emptybin/" || true ;; esac
done
{ [ -f "$T6/emptybin/backlog-archive.py" ] && [ ! -f "$T6/emptybin/backlog-groom.py" ]; } \
  && ok "(NU8-0) the helper-less bin dir has the archiver and no backlog-groom.py — so NU8's silence is about the coverage helper and not about an empty directory the gates above would also complain over" \
  || no "(NU8-0) the helper-less bin fixture is not the shape NU8 needs: archive=$([ -f "$T6/emptybin/backlog-archive.py" ] && echo yes || echo no) groom=$([ -f "$T6/emptybin/backlog-groom.py" ] && echo yes || echo no)"
chmod +x "$T6/emptybin/backlog-archive.py" 2>/dev/null
nu_next; NU_NOBIN_RC="$(nu_run "$RUNLOG6" "$T6/emptybin" "$NU_SHORT" "nobin$NU_SEQ")"
NU_NOBIN_ERR="$T6/nu-nobin$NU_SEQ.err"
{ [ ! -s "$NU_NOBIN_ERR" ] && [ "$NU_NOBIN_RC" = "0" ]; } \
  && ok "(NU8/AC12) with backlog-groom.py absent from ZUVO_BIN the run is SILENT and exits 0 — no \`else\` branch, because that WARN would fire on every run of every skill until install.sh had run once" \
  || no "(NU8/AC12) an absent helper printed [$(tr '\n' '|' < "$NU_NOBIN_ERR")] at rc=$NU_NOBIN_RC"

# --- NU7: the helper is silent where there is no backlog at all ----------------------------------
mkdir -p "$T6/norepo"
NU_NO_OUT="$(cd "$T6/norepo" && python3 "$CTL2/backlog-groom.py" coverage --repo . 2>&1; printf 'RC=%s' "$?")"
[ "$NU_NO_OUT" = "RC=0" ] \
  && ok "(NU7) \`coverage\` over a directory with no backlog at all prints nothing and exits 0 — a nudge that reported '0 of 0' or a traceback would be noise on every run in every repo without one" \
  || no "(NU7) coverage over an empty directory answered [$NU_NO_OUT]"

# ==================================================================================================
# MU6 — every Task 6 assertion dies under a mutant that reverts ONLY its behaviour.
#
# Three of them mutate `zuvo_backlog_load.py` through the Task 2 factory (the glob carries it already);
# the other seven mutate TEXT — append-runlog, SKILL.md, docs/skills.md — through a factory with the
# identical contract: the substitution must apply EXACTLY once or the build is a hard error, because
# "the mutant passed" and "the mutation was never made" are indistinguishable otherwise.
#
# TWO OF THEM ADD A LINE RATHER THAN REMOVING ONE, and they have to: NU2's property is an ABSENCE (no
# `exit` in the block) and S6g's is a UNIQUENESS (one row in docs/skills.md). An absence cannot be
# reverted by deleting something.
# ==================================================================================================
echo "-- MU6: each Task 6 assertion is load-bearing --"

MKTXT6="$T6/mktxt6.py"
cat > "$MKTXT6" <<'PYEOF'
r"""Write a named mutation of ONE TEXT file into <outfile>. RAW docstring, same reason as the others'.

Usage: mktxt6.py <srcfile> <kind> <outfile>

HARD ERROR when the substitution does not apply EXACTLY once, and on an unknown kind — the same
contract as the two Python factories above, for the same reason: a mutation that silently failed to
apply makes the assertion reading it pass for the wrong reason, which looks exactly like the assertion
being load-bearing.
"""
import sys

SRC, KIND, OUT = sys.argv[1:4]
TEXT = open(SRC, encoding="utf-8").read()

MUTATIONS = {
    # --- append-runlog: the WIRING, separately from the helper -------------------------------------
    # The nudge invocation replaced by a no-op. This mutant IS the pre-change file for NU3's purposes,
    # which is why NU3c reads its exit code instead of trusting a number typed into this suite.
    "runlognonudge": ('sh "$ZUVO_BIN/backlog-groom.py" coverage --repo "$PWD" 2>&1', 'true'),
    # An `exit` inside the block: the one mutation that turns a diagnostic into a gate. It must break
    # NU2 (the grep) AND the run (the row stops being appended at all).
    "runlogexits": ('    if [ -n "$_bv_out" ]; then printf \'%s\\n\' "$_bv_out" >&2; fi',
                    '    if [ -n "$_bv_out" ]; then printf \'%s\\n\' "$_bv_out" >&2; exit 12; fi'),
    # The `else` branch the block deliberately does NOT have: it fires on every machine whose ~/.zuvo
    # predates the feature. An ADD mutation, because the property NU8 asserts is an absence.
    "runlogwarnsmissing": ("  fi\nfi\n# NO `else` BRANCH",
                           "  fi\nelse\n  echo \"WARN: coverage helper absent\" >&2\nfi\n# NO `else` BRANCH"),
    # --- SKILL.md ---------------------------------------------------------------------------------
    "skillnorow": ("| `verify [--fleet]` |", "| `verifyX [--fleet]` |"),
    # The Argument Parsing row's own link. `](#mode-groom) |` occurs in BOTH tables, and a target that
    # is not unique is a build error here rather than a silent half-mutation.
    "skillnoanchor": ("see [Mode: verify](#mode-verify) |", "see [Mode: verify](#mode-verifying) |"),
    # The plan's own defect, reproduced inside the skill: the mapping claims a command that is not one.
    "skillinvents": ("| `groom` | `apply` |", "| `groom` | `verify` |"),
    # The depth trap. `../../../x` CONTAINS `../../x`, so a substring grep passes on this mutant — the
    # comparison below asserts exactly that, which is what makes S6f's string equality the real check.
    "skilldeep": ("  4. ../../shared/includes/backlog-grooming.md",
                  "  4. ../../../shared/includes/backlog-grooming.md"),
    # A mode word typed as a command inside a fence: what the plan's prose would have produced.
    "skillfencemode": ("backlog-groom.py apply --repo . [--dry-run]",
                       "backlog-groom.py groom --repo . [--dry-run]"),
    "skilltwomaps": ("| Mode | Runs | Phase section |\n|------|------|---------------|",
                     "| Mode | Runs | Phase section |\n|------|------|---------------|\n"
                     "| Mode | Runs | Phase section |\n|------|------|---------------|"),
    # --- docs/skills.md ---------------------------------------------------------------------------
    "docsdup": ("| `zuvo:backlog` | Manage tech debt backlog.",
                "| `zuvo:backlog` | A SECOND row for the same skill | never | never |\n"
                "| `zuvo:backlog` | Manage tech debt backlog."),
    "docsnomodes": ("`verify [--fleet]`, `groom [--dry-run]`, `doc [--partial]` |", "|"),
}

if KIND not in MUTATIONS:
    sys.stderr.write("unknown mutation %r\n" % KIND)
    raise SystemExit(2)
old, new = MUTATIONS[KIND]
n = TEXT.count(old)
if n != 1:
    sys.stderr.write("mutation %r: its target occurs %d times, not exactly once\n" % (KIND, n))
    raise SystemExit(2)
with open(OUT, "w", encoding="utf-8") as fh:
    fh.write(TEXT.replace(old, new, 1))
print("MUTATED=%s" % KIND)
PYEOF

mut6(){     # srcfile, kind -> echoes the mutant's path, or nothing on failure
  # `out` is assigned on its OWN line, never inside the `local`: bash expands every word of a `local`
  # command BEFORE the builtin assigns any of them, so `local kind="$2" out="…$kind…"` reads the
  # CALLER's `kind` — defined inside mu6_doc, unbound at top level, which under `set -u` killed three
  # mutant builds and reported them as "the substitution no longer applies".
  local src="$1" kind="$2" out
  out="$T6/mut-$kind-$(basename "$src")"
  if python3 "$MKTXT6" "$src" "$kind" "$out" >"$T6/mk6-$kind.log" 2>&1; then
    printf '%s\n' "$out"
  fi
}
mut6_failed(){
  no "(MU6) mutant '$1' did NOT build: $(tail -1 "$T6/mk6-$1.log") — its substitution no longer applies, so the assertion it targets would pass on a mutant that does not exist"
}
# The factory's own guard, asserted the way the two Python factories' is.
if python3 "$MKTXT6" "$SKILL6" no-such-task-6-mutation "$T6/mut-bogus" >/dev/null 2>&1; then
  no "(MU6-0) the text factory accepted an unknown mutation — every 'the mutant failed' below could mean 'the mutation was never made'"
else
  ok "(MU6-0) the text factory hard-errors on a mutation it cannot apply"
fi

# --- the three SKILL.md / docs assertions, compared PROBE OUTPUT against PROBE OUTPUT -------------
mu6_doc(){  # kind, srcfile, probe(s6|s6d), label, gone|new, ERE
  local kind="$1" src="$2" pr="$3" lbl="$4" dir="$5" pat="$6" m ctl mut
  m="$(mut6 "$src" "$kind")"
  if [ -z "$m" ]; then mut6_failed "$kind"; return; fi
  ctl="$("$pr" "$src")"; mut="$("$pr" "$m")"
  if [ "$dir" = "gone" ]; then
    if ! printf '%s\n' "$ctl" | grep -qE -- "$pat"; then
      no "(MU6) $lbl: the CONTROL does not produce /$pat/ either, so this comparison measures nothing"
    elif printf '%s\n' "$mut" | grep -qE -- "$pat"; then
      no "(MU6) $lbl: the mutant STILL produces /$pat/ — the assertion is decorative"
    else
      ok "(MU6) $lbl: /$pat/ vanishes under the mutant while the control produces it — load-bearing"
    fi
  else
    if printf '%s\n' "$ctl" | grep -qE -- "$pat"; then
      no "(MU6) $lbl: the CONTROL already produces /$pat/, so the mutant's appearance is not attributable"
    elif printf '%s\n' "$mut" | grep -qE -- "$pat"; then
      ok "(MU6) $lbl: the mutant produces /$pat/ where the control does not — load-bearing"
    else
      no "(MU6) $lbl: the mutant produced no /$pat/, so the control's clean result is not attributable to this line"
    fi
  fi
}
mu6_doc skillnorow     "$SKILL6" s6  "S6a the Argument Parsing row for \`verify\`" gone '^MODEROW=verify$'
mu6_doc skillnoanchor  "$SKILL6" s6  "S6b the phase-section link resolving" gone '^MODEANCHOR=verify:mode-verify:resolves$'
mu6_doc skillinvents   "$SKILL6" s6  "S6c2/S6d the mapping naming the command that exists" gone '^MAPRUNS=groom:apply$'
mu6_doc skilltwomaps   "$SKILL6" s6  "S6c the mapping stated in exactly ONE place" gone '^MAPTABLES=1$'
mu6_doc skillfencemode "$SKILL6" s6  "S6d no fenced invocation names a mode word as a command" new '^FENCECMD=groom$'
mu6_doc docsdup        "$DOCS6"  s6d "S6g docs/skills.md's row was EXTENDED, not duplicated" gone '^BACKLOGROWS=1$'
mu6_doc docsnomodes    "$DOCS6"  s6d "S6g2 the extended row names the three modes" gone '^BLMODE=doc$'

# THE DEPTH TRAP, asserted as a trap rather than as one more comparison. The brief's question is how
# S6f avoids a substring grep that `../../../x` would satisfy, and this is the answer measured: the
# mutant's token CONTAINS the canonical string, so `grep -q` passes on it, while string equality does
# not. Both halves are shown, because only the pair proves which check is doing the work.
M6_DEEP="$(mut6 "$SKILL6" skilldeep)"
if [ -z "$M6_DEEP" ]; then mut6_failed skilldeep; else
  M6_TOK="$(s6 "$M6_DEEP" | sed -n 's/^LOADTOK=//p' | head -1)"
  if grep -qF -- '../../shared/includes/backlog-grooming.md' "$M6_DEEP" \
     && [ "$M6_TOK" != '../../shared/includes/backlog-grooming.md' ] \
     && [ -n "$M6_TOK" ]; then
    ok "(MU6) S6f the include depth: the mutant's loading line reads '$M6_TOK', which a substring grep for '../../shared/includes/backlog-grooming.md' STILL MATCHES — string equality is what rejects it, and check_include_integrity fails a SKILL.md-level file at that depth"
  else
    no "(MU6) S6f: the depth mutant yielded token '${M6_TOK:-<none>}' and substring-match=$(grep -qF -- '../../shared/includes/backlog-grooming.md' "$M6_DEEP" && echo yes || echo no) — the trap this assertion exists for is not reproduced"
  fi
fi

# --- the nudge's own three, through the Task 2 module factory --------------------------------------
nu_probe(){  # moddir, repo -> the single stdout line (or nothing) plus RC=
  ( cd "$2" && python3 "$1/backlog-groom.py" coverage --repo . 2>&1; printf 'RC=%s' "$?" )
}
if mut2_build nudgesilent; then
  M6_S="$(nu_probe "$T2/mut-nudgesilent" "$NU_SHORT")"
  C6_S="$(nu_probe "$CTL2" "$NU_SHORT")"
  if printf '%s' "$C6_S" | grep -q 'carry no verdict' && ! printf '%s' "$M6_S" | grep -q 'carry no verdict'; then
    ok "(MU6) NU3 the count itself: the control answers '$(printf '%s' "$C6_S" | head -1)' and the mutant says nothing at all — so the nudge NU3 reads is produced by that line, not by anything else on the path"
  else
    no "(MU6) NU3: control=[$C6_S] mutant=[$M6_S] — the count is not attributable to the line the mutant removes"
  fi
else
  mut2_failed nudgesilent
fi
if mut2_build nudgealways; then
  M6_A="$(nu_probe "$T2/mut-nudgealways" "$NU_FULL")"
  C6_A="$(nu_probe "$CTL2" "$NU_FULL")"
  if [ "$C6_A" = "RC=0" ] && printf '%s' "$M6_A" | grep -q 'carry no verdict'; then
    ok "(MU6) NU4 the SILENCE on a verified repo: with the coverage guard removed the same repo prints '$(printf '%s' "$M6_A" | head -1)' — A29's second half is load-bearing, not an artefact of a fixture that happens to be quiet"
  else
    no "(MU6) NU4: control=[$C6_A] mutant=[$M6_A] — the silence is not attributable to the guard"
  fi
else
  mut2_failed nudgealways
fi
if mut2_build nudgerowcount; then
  M6_R="$(nu_probe "$T2/mut-nudgerowcount" "$NU_STALE")"
  C6_R="$(nu_probe "$CTL2" "$NU_STALE")"
  if printf '%s' "$C6_R" | grep -q '3 of 3 entries carry no verdict' && [ "$M6_R" = "RC=0" ]; then
    ok "(MU6) the count is \`text_sha\`-EXACT, the same arithmetic \`apply\` refuses on: over a ledger holding 3 valid, key-resolvable rows whose shas have MOVED, the control says '3 of 3 carry no verdict' while a row-count version reports full coverage and prints nothing — which is the shape of a nudge that says 'verified' about judgements made against text that has since changed"
  else
    no "(MU6) the stale-sha comparison: control=[$C6_R] mutant=[$M6_R] — coverage is not distinguishable from a row count here"
  fi
else
  mut2_failed nudgerowcount
fi

if mut2_build nudgenoledger; then
  M6_N="$(nu_probe "$T2/mut-nudgenoledger" "$NU_NOLED")"
  C6_N="$(nu_probe "$CTL2" "$NU_NOLED")"
  if [ "$C6_N" = "RC=0" ] && printf '%s' "$M6_N" | grep -q 'carry no verdict'; then
    ok "(MU6) NU4c the no-ledger guard: without it the SAME never-verified repo prints '$(printf '%s' "$M6_N" | head -1)' — and that is not a hypothetical, it is the line that turned test-backlog-archive-dedup.sh (A29) red on the first version of this feature, on this fixture shape, in the stream A29 measures"
  else
    no "(MU6) NU4c: control=[$C6_N] mutant=[$M6_N] — the silence on a never-verified repo is not attributable to that guard"
  fi
else
  mut2_failed nudgenoledger
fi

# --- the WIRING, mutated in append-runlog itself ---------------------------------------------------
# NU3's own exit code is checked against this mutant rather than against a literal: it is byte-for-byte
# the pre-change file on the only line that matters, so it answers "unchanged from the pre-change
# value" by measurement.
M6_NON="$(mut6 "$RUNLOG6" runlognonudge)"
if [ -z "$M6_NON" ]; then mut6_failed runlognonudge; else
  chmod +x "$M6_NON"
  nu_next; M6_NON_RC="$(nu_run "$M6_NON" "$NU_BIN" "$NU_SHORT" "nonudge$NU_SEQ")"
  M6_NON_ERR="$T6/nu-nonudge$NU_SEQ.err"
  if [ ! -s "$M6_NON_ERR" ] && [ "$M6_NON_RC" = "$NU_SHORT_RC" ]; then
    ok "(MU6) NU3c the WIRING, and the pre-change exit code by measurement: with the invocation replaced by a no-op the SAME incomplete repo prints nothing on stderr, while the exit code is $M6_NON_RC both with and without the block — so the nudge comes from append-runlog calling the helper, and adding it moved no exit code"
  else
    no "(MU6) NU3c: the no-op mutant printed [$(tr '\n' '|' < "$M6_NON_ERR")] and exited $M6_NON_RC against $NU_SHORT_RC with the block — either the nudge is not wired through that line or the block changed the run's result"
  fi
  grep -qx 'CALLSCOVERAGE=0' <(nu_noexit "$M6_NON") \
    && ok "(MU6) NU1b: the no-op mutant's block invokes no \`coverage\` at all, so NU1b is about that invocation and not about the word appearing somewhere in a comment" \
    || no "(MU6) NU1b: the no-op mutant still reports $(nu_noexit "$M6_NON" | sed -n 's/^CALLSCOVERAGE=//p') invocation(s)"
fi
M6_WM="$(mut6 "$RUNLOG6" runlogwarnsmissing)"
if [ -z "$M6_WM" ]; then mut6_failed runlogwarnsmissing; else
  chmod +x "$M6_WM"
  nu_next; M6_WM_RC="$(nu_run "$M6_WM" "$T6/emptybin" "$NU_SHORT" "warnmissing$NU_SEQ")"
  M6_WM_ERR="$T6/nu-warnmissing$NU_SEQ.err"
  if [ -s "$M6_WM_ERR" ] && [ "$M6_WM_RC" = "0" ]; then
    ok "(MU6) NU8 the missing \`else\`: adding one makes the SAME helper-less bin dir print [$(tr '\n' '|' < "$M6_WM_ERR")] on a run that has nothing to say — so the absence of that branch is a decision with a measured cost, not an oversight"
  else
    no "(MU6) NU8: the added-else mutant printed [$(tr '\n' '|' < "$M6_WM_ERR")] at rc=$M6_WM_RC — the silence is not attributable to the missing branch"
  fi
fi
M6_EX="$(mut6 "$RUNLOG6" runlogexits)"
if [ -z "$M6_EX" ]; then mut6_failed runlogexits; else
  chmod +x "$M6_EX"
  nu_noexit "$M6_EX" >"$T6/noexit-mut.out"
  M6_EXN="$(sed -n 's/^EXITS=//p' "$T6/noexit-mut.out")"
  nu_next; M6_EX_RC="$(nu_run "$M6_EX" "$NU_BIN" "$NU_SHORT" "exits$NU_SEQ")"
  M6_EX_HOME="$T6/home-exits$NU_SEQ"
  M6_EX_ROWS="$(awk 'END{print NR}' "$M6_EX_HOME/runs.log" 2>/dev/null || echo 0)"
  [ "${M6_EXN:-0}" = "1" ] \
    && ok "(MU6) NU2 the no-\`exit\` check: it finds the one \`exit\` the mutant adds at code position ($(sed -n 's/^EXITLINE=//p' "$T6/noexit-mut.out")) while reporting EXITS=0 on the real file, so it is reading code rather than the comments that describe the contract" \
    || no "(MU6) NU2: the mutant's added exit was not detected (EXITS=${M6_EXN:-?}) — the check cannot tell a described contract from a kept one"
  { [ "$M6_EX_RC" != "$NU_SHORT_RC" ] && [ "${M6_EX_ROWS:-0}" = "0" ]; } \
    && ok "(MU6) …and the COST of that one word, measured: the mutant exits $M6_EX_RC instead of $NU_SHORT_RC and appends $M6_EX_ROWS rows to runs.log — a finished run refused by its own backlog diagnostic, which is the exact failure mode \`append-runlog\` records being switched off within a week" \
    || no "(MU6) the exit mutant exited $M6_EX_RC (control $NU_SHORT_RC) and still appended ${M6_EX_ROWS:-?} row(s) — the no-exit contract would then be cosmetic"
fi

finish
