#!/usr/bin/env bash
# backlog-add contract: backlog-protocol.md § "Persisting a finding: backlog-add" against the CLI.
#
# The defect this catches: the protocol documents a verdict, an exit code, a class, a bar, a refusal
# reason or a flag that `backlog-add` does not produce or accept, or misses one that it does. Skills are
# written from the protocol, not from the code, so a verdict the protocol omits is a verdict no caller
# handles, a refusal reason it omits is one no caller knows how to correct, and a renamed flag sends
# every caller to exit 2. None of these shows up as a failing run.
#
# The section's tables are parsed and compared, in BOTH directions, with what the code exports:
# `VERDICTS` and `EXIT_CODES` from zuvo_backlog_add.py; the class sets, the three confidence bars,
# `REASONS` and `REFUSALS` from zuvo_backlog_admit.py; the refusals decided outside the bars (every
# `REFUSED_*` constant of zuvo_backlog_add.py and zuvo_backlog_findings.py). Five tables are compared:
# Verdict, Exit, Class, Refusal and Argument (its flags against the CLI's own argparse parser). The
# section's prose is not. Every comparison is then re-run against mutated
# copies of the section (a row dropped, a row invented, a bar moved), and each mutant must be caught,
# so a parser that silently reads nothing cannot pass.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
PROTOCOL="$ROOT/shared/includes/backlog-protocol.md"
MODULES="$ROOT/scripts/zuvo-home"

echo "== backlog-add contract: protocol vs CLI =="
python3 - "$PROTOCOL" "$MODULES" <<'PY'
import re
import sys
from typing import Callable, Dict, List, Set, Tuple

protocol_path, modules = sys.argv[1], sys.argv[2]
sys.path.insert(0, modules)
import zuvo_backlog_add as add          # noqa: E402
import zuvo_backlog_admit as adm        # noqa: E402
import zuvo_backlog_findings as fnd     # noqa: E402

SECTION = "Persisting a finding: backlog-add"
# The refusals no bar decides (`--pr` that is not a PR number, the ledger visibility check, ...): every
# module-level `REFUSED_*` string in the CLI and the ledger module, derived rather than listed, so a
# refusal added there joins the both-directions check without anyone editing this file.
CLI_REFUSALS = set(adm.REFUSALS) | {v for m in (add, fnd) for k, v in vars(m).items()
                                    if k.startswith("REFUSED_") and isinstance(v, str)}
# Every long option argparse accepts, from the parser the CLI itself builds; `--help` is argparse's own.
CLI_FLAGS = {s for a in add._parser()._actions for s in a.option_strings
             if s.startswith("--") and s != "--help"}
TICK = re.compile(r"`([^`\n]+)`")
FENCE = re.compile(r"^```.*?^```[^\n]*$", re.S | re.M)
CLASS_TOKEN = re.compile(r"^[A-Z][A-Z-]*$")
REASON_TOKEN = re.compile(r"^[a-z][a-z0-9-]*$")


class Unparseable(Exception):
    """The section or one of its tables is not where the contract says: a FAIL, never a skip."""


def section(doc: str) -> str:
    m = re.search(r"^## +%s\s*$(.*?)(?=^## |\Z)" % re.escape(SECTION), doc, re.S | re.M)
    if not m:
        raise Unparseable(f"no '## {SECTION}' section")
    return m.group(1)


def table(text: str, first_header: str) -> List[List[str]]:
    """The body rows of the table whose first header cell is `first_header`."""
    lines = text.splitlines()
    for i, ln in enumerate(lines):
        cells = [c.strip() for c in ln.strip().strip("|").split("|")]
        if ln.lstrip().startswith("|") and cells[0] == first_header:
            rows = []
            for body in lines[i + 2:]:
                if not body.lstrip().startswith("|"):
                    break
                rows.append([c.strip() for c in re.split(r"(?<!\\)\|", body.strip().strip("|"))])
            if not rows:
                raise Unparseable(f"the '{first_header}' table has no rows")
            return rows
    raise Unparseable(f"no table headed '| {first_header} |' in the section")


def ticks(cell: str) -> List[str]:
    return TICK.findall(cell)


def compare(doc: str) -> List[str]:
    """Every disagreement between the documented contract and the CLI, as one message each."""
    out: List[str] = []
    try:
        sec = section(doc)
        verdict_rows = table(sec, "Verdict")
        exit_rows = table(sec, "Exit")
        bar_rows = table(sec, "Class")
        refusal_rows = table(sec, "Refusal")
        argument_rows = table(sec, "Argument")
    except Unparseable as exc:
        return [f"unparseable: {exc}"]

    # Verdicts: the keyword is the first word of the row's code span; the order is the CLI's.
    documented: List[Tuple[str, int]] = []
    for row in verdict_rows:
        spans = ticks(row[0])
        if not spans or len(row) < 2 or not row[1].isdigit():
            out.append(f"verdict row not in '`<KEYWORD> …` | <exit>' form: {row}")
            continue
        documented.append((spans[0].split()[0], int(row[1])))
    words = tuple(w for w, _ in documented)
    out += [f"verdict documented but never printed by the CLI: {w}" for w in words if w not in add.VERDICTS]
    out += [f"verdict the CLI prints but the protocol omits: {w}" for w in add.VERDICTS if w not in words]
    if set(words) == set(add.VERDICTS) and words != add.VERDICTS:
        out.append(f"verdicts out of the CLI's order: {words} vs {add.VERDICTS}")
    for word, code in documented:
        meaning = add.EXIT_CODES.get(code, "")
        if not re.search(r"(?<![A-Z-])%s(?![A-Z-])" % re.escape(word), meaning):
            out.append(f"{word} is documented with exit {code}, but the CLI's exit {code} is: {meaning!r}")

    # Exit codes, both directions.
    codes: Set[int] = set()
    for row in exit_rows:
        if not row[0].isdigit():
            out.append(f"exit row does not start with a number: {row}")
            continue
        codes.add(int(row[0]))
    out += [f"exit code documented but not in EXIT_CODES: {c}" for c in sorted(codes - set(add.EXIT_CODES))]
    out += [f"exit code in EXIT_CODES but not documented: {c}" for c in sorted(set(add.EXIT_CODES) - codes)]

    # Bars: a row whose bar is "never" is ledger-only; any other row can reach the backlog.
    ledger_only: Set[str] = set()
    can_land: Set[str] = set()
    numbers: Set[int] = set()
    reasons: Set[str] = set()
    for row in bar_rows:
        if len(row) < 3:
            out.append(f"bar row needs three cells: {row}")
            continue
        classes = {t for t in ticks(row[0]) if CLASS_TOKEN.match(t)}
        (ledger_only if row[1].lower().startswith("never") else can_land).update(classes)
        numbers.update(int(n) for n in re.findall(r"\b\d{2}\b", row[1] + " " + row[2]))
        reasons.update(t for t in ticks(row[2]) if REASON_TOKEN.match(t))
    want_land = set(adm.BACKLOG_CLASSES) | set(adm.PROMOTABLE_CLASSES)
    want_ledger = set(adm.REPORT_ONLY_CLASSES) | {"ADVISORY"}
    out += [f"documented as able to reach the backlog, but the bars never route it there: {c}"
            for c in sorted(can_land - want_land)]
    out += [f"the bars can route it to the backlog, but no row says how: {c}" for c in sorted(want_land - can_land)]
    out += [f"documented as ledger-only, but not report-only in the CLI: {c}" for c in sorted(ledger_only - want_ledger)]
    out += [f"report-only in the CLI, but no 'never' row lists it: {c}" for c in sorted(want_ledger - ledger_only)]
    out += [f"class in the bar table that the CLI refuses as unknown-class: {c}"
            for c in sorted((can_land | ledger_only) - set(adm.CLASSES))]
    bars = {adm.FLOOR, adm.SEC_LOW, adm.BACKLOG_MIN}
    out += [f"bar table names confidence {n}, which is none of FLOOR/SEC_LOW/BACKLOG_MIN {sorted(bars)}"
            for n in sorted(numbers - bars)]
    out += [f"bar table never states the CLI's confidence bar {n}" for n in sorted(bars - numbers)]
    out += [f"ledger reason documented but not in REASONS: {r}" for r in sorted(reasons - set(adm.REASONS))]
    section_ticks = set(ticks(FENCE.sub("", sec)))   # a fence's ``` would pair with prose ticks
    out += [f"route reason the CLI records but the section never names: {r}"
            for r in sorted(set(adm.REASONS) - section_ticks)]

    # Flags, both directions: a flag the docs name but argparse lacks sends every caller to exit 2.
    documented_flags = {t.split()[0] for row in argument_rows for t in ticks(row[0]) if t.startswith("--")}
    out += [f"flag documented but the CLI has no such flag: {f}" for f in sorted(documented_flags - CLI_FLAGS)]
    out += [f"flag the CLI accepts but the argument table omits: {f}" for f in sorted(CLI_FLAGS - documented_flags)]

    # Refusals (exit 3), both directions; `missing-field:<f>` documents the reason `missing-field`.
    refusals = {t.split(":")[0] for row in refusal_rows for t in ticks(row[0])}
    out += [f"refusal documented but never given by the CLI: {r}" for r in sorted(refusals - CLI_REFUSALS)]
    out += [f"refusal the CLI gives but the protocol omits: {r}" for r in sorted(CLI_REFUSALS - refusals)]
    return out


def drop_row(start: str) -> Callable[[str], str]:
    return lambda doc: re.sub(r"^\| `%s[^\n]*\n" % re.escape(start), "", doc, count=1, flags=re.M)


def insert_after_row(start: str, row: str) -> Callable[[str], str]:
    return lambda doc: re.sub(r"(^\| `%s[^\n]*\n)" % re.escape(start), lambda m: m.group(1) + row + "\n",
                              doc, count=1, flags=re.M)


PASS = FAIL = 0


def ok(msg: str) -> None:
    global PASS
    PASS += 1
    print(f"  PASS {msg}")


def no(msg: str) -> None:
    global FAIL
    FAIL += 1
    print(f"  FAIL {msg}")


doc = open(protocol_path, encoding="utf-8").read()
problems = compare(doc)
for p in problems:
    no(f"(C1) {p}")
if not problems:
    ok(f"(C1) the protocol documents exactly the CLI's {len(add.VERDICTS)} verdicts, {len(add.EXIT_CODES)} exit "
       f"codes, {len(adm.CLASSES)} classes, bars {adm.FLOOR}/{adm.SEC_LOW}/{adm.BACKLOG_MIN} and "
       f"{len(CLI_REFUSALS)} refusals and {len(CLI_FLAGS)} flags")

# C2: each mutant reverts one documented fact and must be caught by the message that names it. A
# comparator that parsed nothing would report the real document clean AND miss every one of these.
MUTANTS: List[Tuple[str, Callable[[str], str], str]] = [
    ("a verdict the CLI prints is dropped from the docs", drop_row("LEDGER-BUMPED"),
     "protocol omits: LEDGER-BUMPED"),
    ("the docs invent a verdict", insert_after_row("DISCARDED", "| `ESCALATED backlog <B>` | 0 | invented |"),
     "never printed by the CLI: ESCALATED"),
    ("a verdict is documented with the wrong exit", lambda d: re.sub(
        r"^(\| `DISCARDED[^|]*\| )0( \|)", r"\g<1>3\2", d, count=1, flags=re.M),
     "DISCARDED is documented with exit 3"),
    ("an exit code is dropped", lambda d: re.sub(r"^\| 2 \|[^\n]*\n", "", d, count=1, flags=re.M),
     "not documented: 2"),
    ("the docs invent an exit code", lambda d: re.sub(r"^(\| 2 \|[^\n]*\n)", r"\1| 4 | invented |\n", d,
                                                     count=1, flags=re.M),
     "not in EXIT_CODES: 4"),
    ("a report-only class is dropped from the bar table", lambda d: d.replace("`DUP`, ", "", 1),
     "no 'never' row lists it: DUP"),
    ("the BUG bar is documented as 75", lambda d: d.replace("conf ≥ 80", "conf ≥ 75", 1),
     "names confidence 75"),
    ("a refusal reason is dropped", drop_row("anchor-not-at-line"), "protocol omits: anchor-not-at-line"),
    ("a flag is renamed in the docs", lambda d: d.replace("| `--evidence` |", "| `--evidance` |", 1),
     "the CLI has no such flag: --evidance"),
    ("a flag the CLI accepts is dropped from the docs", drop_row("--missing-assertion"),
     "argument table omits: --missing-assertion"),
    ("the docs invent a refusal reason", insert_after_row("anchor-not-at-line", "| `stale-anchor` | invented |"),
     "never given by the CLI: stale-anchor"),
]
# Mutated inside the section only, so the same words elsewhere in the protocol cannot absorb a mutant.
try:
    sec = section(doc)
except Unparseable:
    sec = ""
for name, mutate, expect in MUTANTS:
    mutated = doc.replace(sec, mutate(sec), 1) if sec else doc
    caught = [p for p in compare(mutated) if expect in p]
    if mutated == doc:
        no(f"(C2) mutant '{name}' changed nothing: the section no longer has the text it targets")
    elif caught:
        ok(f"(C2) mutant caught: {name}")
    else:
        no(f"(C2) mutant NOT caught: {name} (expected a message containing {expect!r})")

print(f"RESULT: PASS={PASS} FAIL={FAIL}")
sys.exit(1 if FAIL else 0)
PY
