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
BLOCK_MOD="$SCRIPTS/zuvo_backlog_block.py"
MINT_MOD="$SCRIPTS/zuvo_backlog_mint.py"
CAP_REAL=25000
T2="$FIX/t2"
mkdir -p "$T2"

for f in "$GROOM_PY" "$CENSUS_PY" "$VERDICTS_MOD" "$QUEUE_MOD" "$BLOCK_MOD" "$MINT_MOD"; do
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
VERDICTS = "zuvo_backlog_verdicts.py"
QUEUE = "zuvo_backlog_queue.py"
PARSE = "zuvo_backlog_parse.py"

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
    "mintany": (GROOM, "        elif mint_into(core, mint_id(e.body)) is None:", "        elif False:"),
    "nobodyid": (GROOM, "        if zb.BODY_ID_RE.match(e.body.strip()):", "        if False:"),
    "noidentity": (GROOM, '        if out[idx].rstrip("\\r\\n") != e.raw:', "        if False:"),
    "identitylax": (GROOM, '        if out[idx].rstrip("\\r\\n") != e.raw:',
                    "        if out[idx].strip() != e.raw.strip():"),
    "countoff": (GROOM, "    if len(post) != pre:", "    if len(post) != pre + 1:"),
    "linecountoff": (GROOM, "    if len(sim) != len(loaded.lines):",
                     "    if len(sim) != len(loaded.lines) + 1:"),
    "noneopen": (GROOM, "    if zio.is_ignored(loaded.real) is None:", "    if False:"),
    "nolock2": (GROOM, "    with zio.Lock(os.path.dirname(loaded.real)):", "    if True:"),
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
    # --- the signature window (PR 1's parser, mutated here only to prove what it protects) ---------
    # `normalize_signature`'s word window is anchored AFTER the path, over the resolution-STRIPPED
    # text. Keying it off the raw body instead is the one-line "tidy-up" that would make a prepended
    # `[DONE …]` marker rotate the content key — silently orphaning every verdict `groom` writes.
    "sigrawwindow": (PARSE, "        words = _WORD_RE.findall(clean[m.end():].lower())",
                     "        words = _WORD_RE.findall(body.lower())"),
}


def sub(text, old, new, what):
    if text.count(old) != 1:
        sys.exit("mkmut2: %s occurs %dx, expected once — the mutation would not apply: %r"
                 % (what, text.count(old), old))
    return text.replace(old, new)


os.makedirs(OUT, exist_ok=True)
names = [GROOM, CENSUS]
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
for f in "$GROOM_PY" "$CENSUS_PY" "$VERDICTS_MOD" "$QUEUE_MOD"; do
  base="${f#"$ROOT"/}"; tag="$T2/lim-$(basename "$f").out"
  if ! python3 "$LIMITS" "$f" >"$tag" 2>&1; then
    no "(FL) could not measure $base: $(tail -1 "$tag")"; continue
  fi
  cat "$tag"
  raw="$(sed -n 's/^RAWLINES=//p' "$tag")"; nf="$(sed -n 's/^NFUNCS=//p' "$tag")"
  novr="$(sed -n 's/^NOVER=//p' "$tag")"
  [ "${nf:-0}" -ge 5 ] \
    && ok "(FL0) $base: $nf functions measured — a measurer that found none would report 'nothing is over the limit'" \
    || no "(FL0) $base: only ${nf:-0} function(s) measured"
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
for f in "$VERDICTS_MOD" "$QUEUE_MOD"; do
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

if python3 "$MKMUT2" "$SCRIPTS" no-such-mutation "$T2/mut-bogus" >/dev/null 2>&1; then
  no "(MU0) the Task 2 factory accepted an unknown mutation and wrote a copy — every 'the mutant passed' above could mean 'the mutation was never made'"
else
  ok "(MU0) the Task 2 factory hard-errors on a mutation it cannot apply"
fi

finish
