#!/usr/bin/env bash
# The verdict ledger: content-keyed staleness, named defects, and reads that fail CLOSED.
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

finish
