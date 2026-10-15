#!/usr/bin/env bash
# Every literal `backlog-add` command the prose prints is run against the real CLI.
#
# The defect this catches: a skill, agent, reference or include tells an agent to run a `backlog-add`
# command the CLI does not take. An invented flag (`--dimension PT3`) exits 2, a source the CLI refuses
# (`--source zuvo:refactor`) exits 3, a conf under the floor is DISCARDED, and none of it shows up until
# an agent runs the sentence in a real session, where the finding is then lost. Skills copy these
# commands verbatim, so the prose is the place to catch them.
#
# Scope: the files the hand-append guard scans (tests/hooks/test-backlog-hand-append-prose.sh,
# SCOPE_GLOBS; this file mirrors that list and fails when the two differ), plus EXTRA_SOURCES: the
# pre-commit warning hook, whose `printf` prints a command to every agent that appended by hand.
#
# Checks, in order (each label names the bug it catches):
#   S   self-check: a fixture table of good and bad spans, each with the verdict it must get. Runs first,
#       so an extractor that finds nothing or a checker that reports nothing cannot pass.
#   T   the mirrored scope equals the guard's.
#   C   every command in scope: a backtick span (one wrapped across lines of a paragraph included) or a
#       fenced logical line (`\` continuations joined; a fence closes only on its own run) where
#       `backlog-add`, behind any path, starts a command (after `VAR=`, an operator or `$(`) and has at
#       least one argument; split with shlex, shell operators split off. A bare `backlog-add`, or one in
#       a prose parenthesis, is a mention; one glued to syntax shlex cannot split is a problem. Then:
#         flag check (every command): each argument is a `--flag` the CLI's own parser accepts
#         (allow_abbrev=False), `--flag=value` included, none repeated, `--class` present; an argument
#         that cannot be checked (`"$ARGS"`) is a problem. A command with any problem is never run.
#         run check: variables and placeholders filled INSIDE each value from one table (an unknown
#         `$VAR` or a `<…>` left over is a problem), the cited files seeded in a fresh temp git repo
#         (never outside it or under memory/, lines 1..cap), run with `--dry-run --json`. `--class <C>`
#         runs once per class the location can carry (a file: every class; a target: its kind's set),
#         narrowed by a list item's lead-in ("`BUG`, `SEC`, `DATA`:", "any other class ...:"), with a
#         conf above every bar; no class left is a problem. Each run must exit 0, ACCEPTED or LEDGER.
#       Counts are printed and held to floors (the counts of T4 round 3; later batches only add commands).
#   F   flow: three canonical sentences of backlog-protocol.md "Filing from a skill" run for real in a
#       repo on feat/x: BUG -> ACCEPTED with [branch:feat/x], CQ -> LEDGER class-report-only with the
#       backlog byte-identical, the process item twice -> LEDGER then LEDGER-BUMPED seen=2.
#
# `~/.zuvo` is filled by the REAL `install_zuvo_home` into a temp HOME (the test-backlog-add-e2e.sh
# pattern), so the CLI under test is the one the installer ships. Every run builds its own repos.
#
# Usage: bash tests/hooks/test-backlog-prose-commands.sh. Exit 0 = PASS, 1 = any FAIL.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
echo "== backlog-add commands in the prose, run against the CLI =="

fail_pre(){ echo "  FAIL $1"; echo "RESULT: PASS=0 FAIL=1"; exit 1; }

tmp=""
trap '[ -n "$tmp" ] && rm -rf "$tmp"' EXIT
for tool in git python3; do
  command -v "$tool" >/dev/null 2>&1 || fail_pre "(pre) $tool not on PATH"
done
tmp="$(mktemp -d)" || { tmp=""; fail_pre "(pre) mktemp -d failed"; }
tmp="$(cd "$tmp" && pwd -P)" || fail_pre "(pre) temp dir unreadable"

# Hermetic: nothing from the caller's shell, an outer git or a git hook steers the CLI or the fixtures.
unset PYTHONPATH PYTHONHOME BASH_ENV 2>/dev/null || true
for v in $(compgen -e); do
  case "$v" in ZUVO_*|GIT_*) unset "$v" ;; esac
done
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" ZUVO_PR_LOOKUP=0 \
       GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$tmp/install-tmp" "$tmp/work" || fail_pre "(pre) could not create the temp HOME"

inst="$(cd "$ROOT" && env -i HOME="$HOME" TMPDIR="$tmp/install-tmp" PATH="$PATH" \
          XDG_CONFIG_HOME="$XDG_CONFIG_HOME" ZDOTDIR="$HOME" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
          bash -c 'set +u; . ./scripts/install.sh >/dev/null 2>&1 || { echo "source-failed"; exit 0; }
                   install_zuvo_home >"$1" 2>&1; echo "rc=$? missing=${INSTALL_VERIFY_MISSING:-unset}"' \
          _ "$tmp/install.log")"
if [ "$inst" != "rc=0 missing=0" ]; then
  tail -15 "$tmp/install.log" 2>/dev/null | sed 's/^/      /'
  fail_pre "(pre) install_zuvo_home into the temp HOME: '$inst'"
fi
cmp -s "$ROOT/scripts/zuvo-home/zuvo_backlog_add.py" "$HOME/.zuvo/zuvo_backlog_add.py" && [ -x "$HOME/.zuvo/backlog-add" ] \
  || fail_pre "(pre) ~/.zuvo/backlog-add is not the installed copy of scripts/zuvo-home"
echo "  PASS (pre) install_zuvo_home into the temp HOME: exit 0, nothing missing"

python3 - "$ROOT" "$HOME/.zuvo" "$tmp/work" <<'PY'
import ast
import glob
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from typing import Callable, Dict, FrozenSet, List, Optional, Sequence, Tuple

ROOT, ZUVO, WORK = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, ZUVO)
import zuvo_backlog_add as add
import zuvo_backlog_admit as adm

CLI = os.path.join(ZUVO, "backlog-add")
GUARD = os.path.join(ROOT, "tests/hooks/test-backlog-hand-append-prose.sh")
PROTOCOL = "shared/includes/backlog-protocol.md"
# Mirrors test-backlog-hand-append-prose.sh SCOPE_GLOBS (embedded Python there, so not importable);
# check T fails when the two differ.
SCOPE_GLOBS = ("skills/*/SKILL.md", "skills/*/agents/*.md", "skills/*/references/*.md",
               "shared/includes/*.md")
# Files outside the prose scope that print a backlog-add command to an agent: the pre-commit warning
# prints one to every agent that appended by hand. Read through its `printf` format strings.
EXTRA_SOURCES = ("hooks/backlog-hand-append-warn.sh",)
# The counts the tree yields at T4 round 3. Later batches add commands without editing this file, so the
# check is `>=`; a splitter that stops splitting or a scope that loses a directory drops below.
SPAN_FLOOR = 12
RUN_FLOOR = 63
OK_VERDICTS = ("ACCEPTED", "LEDGER")
# {"<path>:<line>": reason}: a documented example whose finding the CLI is meant to discard. Empty: a
# command the prose prints for filing a finding must not drop it.
DISCARDED_OK: Dict[str, str] = {}
# {"<path>:<line>": reason}: a documented command with no `--class` (so never run). Empty: the CLI
# refuses a call without one, so a command that omits it loses the finding.
NO_CLASS_OK: Dict[str, str] = {}
LINE_CAP = 10000                 # the highest line a span may seed: a bigger one is a problem, not a file
URL = "https://example.test/p"
DEFAULT_FILE = "src/seeded.py"
DEFAULT_LINE = "5"
DEFAULT_ANCHOR = "if total > limit:"
CONF = str(adm.BACKLOG_MIN + 5)  # `<N>`: above every class's bar (BACKLOG_MIN is the highest)
# {path: {flag: {bare word: value}}}: bare metavariables a non-prose source uses in its printed command.
# The warning hook prints `--conf N --file F --line N` for a human; the plan keeps that hook untouched
# (part-2 plan, "is not touched"), so its words are read as the placeholders they stand for.
METAVARS: Dict[str, Dict[str, Dict[str, str]]] = {
    "hooks/backlog-hand-append-warn.sh": {"--conf": {"N": CONF}, "--line": {"N": DEFAULT_LINE},
                                          "--file": {"F": DEFAULT_FILE}},
}
TITLE = "the limit check accepts a total equal to the limit"
EVIDENCE = "limit=100 and total=100 pass the check"
FIX = "compare with >="
# The only variables a command may use: the protocol's `"$F"`, `"$A"`, `"$U"`, `"$T"`, `"$E"`, `"$M"`, the backlog
# skill's slug `"$S"`, and `"$PWD"` (the repo). Any other is a problem: the shell expands it to nothing.
VARIABLES = {"F": DEFAULT_FILE, "A": DEFAULT_ANCHOR, "U": URL, "T": TITLE, "E": EVIDENCE, "S": "slug",
             "M": "the check never compares the total with the limit"}
# Placeholders a free-text value may keep: the pentest title prefix, which the agent completes.
FREE_TEXT_ALLOWED = re.compile(r"PT<n>:")
TEMPLATE = """# Tech Debt Backlog

| ID | Status | Fingerprint | File | Problem | Severity | Category | Source | Seen | Added |
|----|--------|-------------|------|---------|----------|----------|--------|------|-------|
"""

# Every long option argparse accepts, from the parser `main` parses with (the contract test's source).
ACTIONS = list(add._parser()._actions)
CLI_FLAGS = {s for a in ACTIONS for s in a.option_strings if s.startswith("--")}
VALUE_FLAGS = {s for a in ACTIONS for s in a.option_strings if s.startswith("--") and a.nargs != 0}
FREE_TEXT = {"--title": TITLE, "--evidence": EVIDENCE, "--fix": FIX, "--anchor": DEFAULT_ANCHOR}
# Which classes a target kind may carry. Private, and still the only exact source: the admit module
# refuses any other pairing with `bad-combination`. A file record may carry every class.
TARGET_CLASSES: Dict[str, FrozenSet[str]] = adm._TARGET_CLASSES
CLASSES: FrozenSet[str] = adm.CLASSES

FENCE = re.compile(r"^\s*(`{3,}|~{3,})")       # the whole opening run: a ```` fence is not closed by ```
TICK = re.compile(r"`([^`]+)`")
# Where a command a script prints starts in its sentence: the helper's name, bare or behind a path.
CMD = re.compile(r"(?<![^\s=])(?:[^\s()'\"`]*/)?backlog-add(?![-\w.'])")
MENTION = re.compile(r"(?<![\w-])backlog-add(?![-\w])")
CMD_WORD = re.compile(r"(?:[^\s()'\"`;|&$]*/)?backlog-add")
# A token that holds the command word glued to syntax shlex cannot split off (`` ID=`backlog-add ``).
GLUED = re.compile(r"[=`$]\S*backlog-add(?![-\w])")
PUNCT = "();|&"                 # shell operators shlex splits off (not `<`/`>`: those are placeholders)
REDIRECT = re.compile(r"\d*>.*")
ASSIGNMENT = re.compile(r"[A-Za-z_]\w*=")
OPTIONAL = re.compile(r"\[(--[^\[\]]*)\]")       # `[--severity <level>]`: the optional flag is checked too
VAR = re.compile(r"\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))")
PLACEHOLDER = re.compile(r"<[^<>\n]+>")
LEAD = re.compile(r"^(\s*)[-*]\s+(.*?):\s*`")
CLASS_NAME = re.compile(r"`([A-Z][A-Z-]*)`")
PRINTF = re.compile(r"^\s*printf\s+'([^']*)'")

Lead = Optional[Tuple[str, FrozenSet[str]]]      # ("only", classes) or ("except", classes)


@dataclass
class Span:
    path: str
    line: int
    ordinal: int
    text: str
    lead: Lead = None
    args: List[str] = field(default_factory=list)
    flags: List[str] = field(default_factory=list)
    problems: List[str] = field(default_factory=list)

    @property
    def where(self) -> str:
        return f"{self.path}:{self.line}"

    @property
    def key(self) -> str:
        return f"{self.where}#{self.ordinal}"

    @property
    def runs(self) -> bool:
        return "--class" in self.flags


@dataclass
class Report:
    spans: List[Span] = field(default_factory=list)
    problems: List[Tuple[str, str]] = field(default_factory=list)   # (key, message)
    verdicts: Dict[str, str] = field(default_factory=dict)          # key -> "LEDGER class-report-only"
    classes: Dict[str, List[str]] = field(default_factory=dict)     # key -> the classes a `<C>` span ran
    executed: int = 0


class Out:
    passed = 0
    failed = 0


def ok(msg: str) -> None:
    Out.passed += 1
    print(f"  PASS {msg}")


def no(msg: str) -> None:
    Out.failed += 1
    print(f"  FAIL {msg}")


class SeedError(Exception):
    """A span names a file the test must not or cannot create: a per-span problem."""


# ── extraction ────────────────────────────────────────────────────────────────────────────────────
def lead_of(lines: Sequence[str], idx: int, span: str) -> Lead:
    """The classes a list item's lead-in limits its command to: "- `BUG`, `SEC`, `DATA`: `<cmd>`" runs
    those; "- any other class with a file: `<cmd>`" runs every class its siblings do not name."""
    m = LEAD.match(lines[idx])
    if not m or not lines[idx][m.end() - 1:].startswith("`" + span):
        return None
    named = frozenset(CLASS_NAME.findall(m.group(2))) & CLASSES
    if named:
        return ("only", named)
    if "any other class" not in m.group(2).lower():
        return None
    indent, others = m.group(1), set()
    for step in (-1, 1):
        k = idx + step
        while 0 <= k < len(lines) and lines[k].strip():
            sib = LEAD.match(lines[k])
            if sib and sib.group(1) == indent:
                others |= set(CLASS_NAME.findall(sib.group(2))) & CLASSES
            elif not lines[k].startswith(indent + " "):
                break
            k += step
    return ("except", frozenset(others))


def closes(line: str, fence: str) -> bool:
    """A fence closes only on its own character, at least as long, with nothing after it."""
    return re.fullmatch(r"\s*%s{%d,}\s*" % (re.escape(fence[0]), len(fence)), line) is not None


def md_texts(text: str) -> Tuple[List[Tuple[int, str, Lead]], List[Tuple[int, str]]]:
    """(line, span text, lead-in) for every backtick span outside fences, a span wrapped across lines of
    one paragraph included, and every logical line (continuations joined) inside fences; plus a problem
    for a paragraph whose backticks do not pair next to backlog-add."""
    out: List[Tuple[int, str, Lead]] = []
    bad: List[Tuple[int, str]] = []
    lines = text.split("\n")
    fence: Optional[str] = None
    i = 0
    while i < len(lines):
        ln = lines[i]
        m = FENCE.match(ln)
        if fence is None and m:
            fence = m.group(1)
        elif fence is not None and closes(ln, fence):
            fence = None
        elif fence is not None:
            start, joined = i + 1, ln
            while joined.rstrip().endswith("\\") and i + 1 < len(lines) and not closes(lines[i + 1], fence):
                i += 1
                joined = joined.rstrip()[:-1] + " " + lines[i].strip()
            if not joined.lstrip().startswith("#"):
                out.append((start, joined.strip(), None))
        else:
            # Markdown renders a newline inside an inline code span as a space, so the joined span is the
            # command a reader copies.
            first, buf, starts = i, ln, [(0, i)]
            while buf.count("`") % 2 and i + 1 < len(lines) and lines[i + 1].strip() \
                    and not FENCE.match(lines[i + 1]):
                i += 1
                buf += " "
                starts.append((len(buf), i))
                buf += lines[i].strip()
            if buf.count("`") % 2 and MENTION.search(buf):
                bad.append((first + 1, "a backtick that does not pair next to backlog-add: unreadable span"))
            for t in TICK.finditer(buf):
                idx = max(n for off, n in starts if off <= t.start())
                out.append((idx + 1, t.group(1), lead_of(lines, idx, t.group(1))))
        i += 1
    return out, bad


def decode_printf(fmt: str) -> str:
    return re.sub(r"\\(.)", lambda m: {"\\": "\\", "n": "\n", "t": "\t"}.get(m.group(1), m.group(0)),
                  fmt.replace("%%", "%"))


def sh_texts(text: str) -> Tuple[List[Tuple[int, str, Lead]], List[Tuple[int, str]]]:
    """The commands a script prints: its single-quoted `printf` formats, `\\`+newline joined, each printed
    line from the command word to the first run of two spaces (the human note after it). A line is
    complete at its newline, at a statement that is not a printf, or at the end of the file. A
    non-comment line naming backlog-add in any other form is a problem: this reader cannot see it."""
    out: List[Tuple[int, str, Lead]] = []
    bad: List[Tuple[int, str]] = []
    cur, start, cont = "", 0, False

    def flush() -> None:
        nonlocal cur, cont
        hit = CMD.search(cur)
        if hit:
            out.append((start, re.split(r"\s{2,}", cur[hit.start():].strip())[0], None))
        cur, cont = "", False

    for n, ln in enumerate(text.split("\n"), 1):
        m = PRINTF.match(ln)
        if not m:
            flush()
            if MENTION.search(ln) and not ln.lstrip().startswith("#"):
                bad.append((n, "prints backlog-add in a form this reader cannot parse (only printf '…')"))
            continue
        pieces = decode_printf(m.group(1)).split("\n")
        for k, piece in enumerate(pieces):
            if not cur:
                start = n
            if piece:                              # the empty tail after a `\`+newline keeps it open
                cur += piece.lstrip() if cont else piece
                cont = False
            if k == len(pieces) - 1:
                break                              # no newline yet: the next printf continues the line
            if cur.rstrip().endswith("\\"):
                cur, cont = cur.rstrip()[:-1].rstrip() + " ", True
                continue
            flush()
    flush()
    return out, bad


def split(text: str) -> List[str]:
    """shlex words, with the shell operators in PUNCT split off even when glued (`$(cmd`, `;cmd`)."""
    lex = shlex.shlex(text, posix=True, punctuation_chars=PUNCT)
    lex.whitespace_split = True
    lex.commenters = ""
    return list(lex)


def is_operator(token: str) -> bool:
    return bool(token) and all(c in PUNCT for c in token)


def position(tokens: Sequence[str], at: int) -> str:
    """Where the command word at `at` stands: "start" (first word, after `VAR=` assignments, at the start
    or after an operator or `$(`), "label" (inside a prose parenthesis: `NOT PERSISTED (backlog-add exit
    1)`), or "inside" (after other words)."""
    k = at - 1
    while k >= 0 and ASSIGNMENT.match(tokens[k]):
        k -= 1
    if k < 0:
        return "start"
    if not is_operator(tokens[k]):
        return "inside"
    before = tokens[k - 1] if k > 0 else ""
    if tokens[k].endswith("(") and before and not before.endswith("$") and not is_operator(before):
        return "label"
    return "start"


def parse(span: Span) -> bool:
    """Fill args/flags/problems. False: not a command (no command word, a prose label, or nothing after
    the command word)."""
    text = OPTIONAL.sub(r"\1", span.text)
    if not MENTION.search(text):
        return False
    try:
        tokens = split(text)
    except ValueError as exc:
        if CMD.search(text):
            span.problems.append(f"does not split as a shell command ({exc})")
            return True
        return False
    at = next((k for k, t in enumerate(tokens) if CMD_WORD.fullmatch(t)), None)
    if at is None:
        glued = next((k for k, t in enumerate(tokens) if GLUED.search(t)), None)
        if glued is None or glued == len(tokens) - 1:
            return False
        span.problems.append(f"the command word is glued to shell syntax ({tokens[glued]!r}), so it "
                             "cannot be checked")
        return True
    where = position(tokens, at)
    if where == "label":
        return False
    args: List[str] = []
    value_next = False
    for t in tokens[at + 1:]:
        if not value_next and (is_operator(t) or REDIRECT.fullmatch(t)):
            break                                  # an operator ends the command; a flag's value never does
        name, eq, val = t.partition("=")
        if not value_next and eq and name in VALUE_FLAGS:
            args += [name, val]
            continue
        args.append(t)
        value_next = not value_next and t in VALUE_FLAGS
    if not args:
        return False                               # a bare mention
    if where == "inside":
        span.problems.append("the command word is not at the start, so its arguments cannot be checked")
    span.args = args
    k = 0
    while k < len(args):
        t = args[k]
        name = t.split("=", 1)[0]
        if not t.startswith("--"):
            span.problems.append(f"argument {t!r} is not a --flag, so it cannot be checked")
        elif name not in CLI_FLAGS:
            span.problems.append(f"unknown flag {name} (the CLI exits 2 on it)")
        elif "=" in t:
            span.problems.append(f"{name} takes no value")
        else:
            if name in span.flags and name != "--also":
                span.problems.append(f"{name} is repeated: argparse keeps the last, the seeding would not")
            span.flags.append(name)
            if name in VALUE_FLAGS:
                if k + 1 >= len(args) or args[k + 1].startswith("--"):
                    span.problems.append(f"{name} has no value")
                else:
                    k += 1
        k += 1
    if "--class" not in span.flags and span.where not in NO_CLASS_OK:
        span.problems.append("no --class: the CLI refuses the call, so the command is never run")
    return True


def extract(path: str, text: str) -> Tuple[List[Span], List[Tuple[str, str]]]:
    found, bad = sh_texts(text) if path.endswith(".sh") else md_texts(text)
    spans: List[Span] = []
    seen: Dict[int, int] = {}
    for line, body, lead in found:
        span = Span(path, line, seen.get(line, 0), body, lead)
        if parse(span):
            seen[line] = span.ordinal + 1
            spans.append(span)
    return spans, [(f"{path}:{line}#0", msg) for line, msg in bad]


def owner(path: str) -> str:
    """`<skill>`: the owning skill directory, or the file's basename."""
    parts = path.split("/")
    if parts[0] == "skills" and len(parts) > 1:
        return parts[1]
    return os.path.splitext(os.path.basename(path))[0]


# ── the run check ─────────────────────────────────────────────────────────────────────────────────
def value(args: Sequence[str], flag: str) -> Optional[str]:
    return next((args[k + 1] for k in range(len(args) - 1) if args[k] == flag), None)


def lookup(table: Dict[str, str]) -> Callable[["re.Match[str]"], str]:
    return lambda m: table.get(m.group(0), m.group(0))


def substitute(span: Span, repo: str, cls: Optional[str], conf: Optional[str] = None
               ) -> Tuple[List[str], List[str]]:
    """The argv to run and the problems. Variables and placeholders are filled INSIDE each value; a
    variable outside VARIABLES and a `<…>` left in any value are problems. A free-text value that is
    wholly one `<…>` is that field's text, and FREE_TEXT_ALLOWED (`PT<n>:`) stays literal."""
    variables = {**VARIABLES, "PWD": repo}
    places = {"<skill>": owner(span.path), "<C>": cls or "<C>", "<N>": conf or CONF, "<gate>": "gate",
              "<slug>": "slug", "<path>": DEFAULT_FILE, "<url>": URL, "<level>": "high"}
    numbers = {"<n>": DEFAULT_LINE, "<line>": DEFAULT_LINE}
    meta = METAVARS.get(span.path, {})
    out: List[str] = []
    problems: List[str] = []

    def var(m: "re.Match[str]") -> str:
        name = m.group(1) or m.group(2)
        if name not in variables:
            problems.append(f"unknown variable ${name}: the shell expands it to nothing")
        return variables.get(name, "")

    for k, t in enumerate(span.args):
        flag = span.args[k - 1] if k else ""
        if t.startswith("--") or flag not in VALUE_FLAGS:
            out.append(t)
            continue
        if t in meta.get(flag, {}):
            out.append(meta[flag][t])
            continue
        v = VAR.sub(var, t)
        if flag in FREE_TEXT and PLACEHOLDER.fullmatch(v):
            out.append(FREE_TEXT[flag])
            continue
        table = {**places, **numbers} if flag in ("--line", "--also") else places
        v = PLACEHOLDER.sub(lookup(table), v)
        left = PLACEHOLDER.findall(FREE_TEXT_ALLOWED.sub("", v) if flag in FREE_TEXT else v)
        if left:
            problems.append(f"{flag} {t!r}: unresolved placeholder {', '.join(left)}")
        out.append(v)
    return out, problems


def line_no(text: str, what: str) -> int:
    if not text.isdigit():
        raise SeedError(f"{what} {text!r} is not a line number")
    if int(text) < 1:
        raise SeedError(f"{what} {text} is below 1")
    if int(text) > LINE_CAP:
        raise SeedError(f"{what} {text} is above the seeding cap {LINE_CAP}")
    return int(text)


def inside(repo: str, rel: str) -> str:
    """The absolute seed path, or SeedError when `rel` is absolute, climbs with `..`, leaves `repo` or
    lands under memory/ (the backlog and ledger the CLI reads)."""
    if not rel or os.path.isabs(rel) or ".." in rel.replace("\\", "/").split("/"):
        raise SeedError(f"path {rel!r} is outside the temp repo")
    full = os.path.normpath(os.path.join(repo, rel))
    if full == repo or os.path.commonpath([repo, full]) != repo:
        raise SeedError(f"path {rel!r} is outside the temp repo")
    if os.path.relpath(full, repo).split(os.sep)[0] == "memory":
        raise SeedError(f"path {rel!r} is under memory/, where the CLI keeps the backlog it reads")
    return full


Seeds = Dict[str, Tuple[int, Optional[str]]]


def seeds_of(args: Sequence[str]) -> Seeds:
    """{path: (line, anchor or None)}: the cited file with its anchor (or filler) at its line, and every
    `--also PATH:LINE`."""
    seeds: Seeds = {}
    path = value(args, "--file")
    if path is not None:
        raw = value(args, "--line")
        seeds[path] = (line_no(raw, "--line") if raw is not None else 1, value(args, "--anchor"))
    for k in range(len(args) - 1):
        if args[k] == "--also":
            p, _, n = args[k + 1].rpartition(":")
            seeds.setdefault(p, (line_no(n, "--also line"), None))
    return seeds


def git(repo: str, *args: str) -> None:
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
                    "-c", "init.defaultBranch=main", "-C", repo, *args],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def seed_repo(repo: str, seeds: Seeds, branch: Optional[str] = None) -> None:
    """A git repo in `repo`: the backlog template, each seeded file with its anchor (or filler) at its
    line. A path `inside` rejects, or one a file and a directory both claim, is a SeedError."""
    os.makedirs(os.path.join(repo, "memory"))
    with open(os.path.join(repo, "memory/backlog.md"), "w", encoding="utf-8") as fh:
        fh.write(TEMPLATE)
    for rel, (line, anchor) in seeds.items():
        full = inside(repo, rel)
        body = [f"x_{i} = {i}" for i in range(1, line + 4)]
        body[line - 1] = anchor if anchor is not None else f"filler_{line} = {line}"
        try:
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w", encoding="utf-8") as fh:
                fh.write("\n".join(body) + "\n")
        except OSError as exc:
            raise SeedError(f"cannot seed {rel!r}: {type(exc).__name__}") from exc
    git(repo, "init", "-q")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "seed")
    if branch:
        git(repo, "checkout", "-qb", branch)


def cli(repo: str, argv: Sequence[str]) -> Tuple[int, str, str]:
    p = subprocess.run([CLI, *argv], cwd=repo, capture_output=True, text=True, timeout=120)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def classes_for(span: Span, probe: Sequence[str]) -> List[Optional[str]]:
    """[None] for a literal class. For `<C>`: every class the location can carry (a file: all; a target:
    its kind's set), narrowed by the list item's lead-in; [] when the lead-in leaves none."""
    raw = value(span.args, "--class") or ""
    if "<C>" not in raw:
        return [None]
    target = value(probe, "--target")
    kind = adm.target_kind(target) if target else None
    allowed = TARGET_CLASSES.get(kind or "", CLASSES)
    if span.lead and span.lead[0] == "only":
        allowed = allowed & span.lead[1]
    elif span.lead:
        allowed = allowed - span.lead[1]
    return list(sorted(allowed))


def run_span(span: Span, rep: Report) -> None:
    """Substitute the span once per class it can mean, seed one repo with the union of those seeds, then
    run each, `--dry-run --json`."""
    repo = tempfile.mkdtemp(dir=WORK)
    probe, problems = substitute(span, repo, "CQ")
    if problems:
        rep.problems += [(span.key, p) for p in problems]
        return
    classes = classes_for(span, probe)
    if not classes:
        rep.problems.append((span.key, "the lead-in leaves no class this location can carry: nothing runs"))
        return
    runs: List[Tuple[Optional[str], List[str]]] = []
    seeds: Seeds = {}
    for cls in classes:
        argv, problems = substitute(span, repo, cls)
        if problems:
            rep.problems += [(span.key, f"class {cls}: {p}") for p in problems]
            return
        for path, seed in seeds_of(argv).items():
            if seeds.setdefault(path, seed) != seed:
                raise SeedError(f"classes seed {path!r} differently")
        runs.append((cls, argv))
    seed_repo(repo, seeds)
    words: List[str] = []
    for cls, argv in runs:
        rc, out, err = cli(repo, [*argv, "--dry-run", "--json"])
        rep.executed += 1
        try:
            doc = json.loads(out)
            word = doc.get("verdict")
            verdict = " ".join(x for x in (word, doc.get("reason")) if x)
        except ValueError:
            word, verdict = None, f"<no JSON verdict: {out or err}>"
        words.append(f"{cls}={word}" if cls else verdict)
        good = rc == 0 and (word in OK_VERDICTS or (word == "DISCARDED" and span.where in DISCARDED_OK))
        if not good:
            tag = f"class {cls}: " if cls else ""
            rep.problems.append((span.key, f"{tag}exit {rc}, verdict '{verdict}' (want exit 0 and "
                                 f"{'/'.join(OK_VERDICTS)}); ran: backlog-add {shlex.join(argv)}; "
                                 f"stderr: {err[-300:]}"))
    rep.verdicts[span.key] = " ".join(words)
    if classes != [None]:
        rep.classes[span.key] = [c for c in classes if c]


# ── the checker ───────────────────────────────────────────────────────────────────────────────────
def check(docs: Sequence[Tuple[str, str]]) -> Report:
    rep = Report()
    for path, text in docs:
        spans, bad = extract(path, text)
        rep.problems += bad
        for span in spans:
            rep.spans.append(span)
            rep.problems += [(span.key, p) for p in span.problems]
            if span.problems or not span.runs:
                continue                           # an unknown or unreadable argument is never run
            try:
                run_span(span, rep)
            except SeedError as exc:
                rep.problems.append((span.key, str(exc)))
            except Exception as exc:               # one broken span is a problem, never the end of C
                rep.problems.append((span.key, f"crashed: {type(exc).__name__}: {exc}"))
    return rep


# ── S: self-check fixture table ───────────────────────────────────────────────────────────────────
FIXTURE_PATH = "skills/fixture/SKILL.md"
Z = "~/.zuvo/backlog-add"
FIXTURE_LINES: List[Tuple[str, str]] = [
    ("", "# fixture"),
    ("unknown", f'Unknown flag: `{Z} --repo "$PWD" --class SEC --conf 60 --source pentest --target "$U" '
                '--evidence "$E" --title "$T" --dimension PT3`.'),
    ("badsource", f'Bad source: `{Z} --class CQ --conf 60 --source zuvo:refactor --file "$F" --line <n> '
                  '--title "$T"`.'),
    ("subject", f'Subject: `{Z} --class PROCESS --conf 90 --source <skill> --target subject:<skill>-<gate> '
                '--title "$T"`.'),
    ("anchored", f"Anchored: `{Z} --class BUG --conf 85 --source <skill> --file <path> --line <line> "
                 "--anchor '<anchor>' --title '<title>' --evidence '<evidence>' --fix '<fix>'`."),
    ("mention", "A mention: `backlog-add` with no argument, and `NOT PERSISTED (backlog-add exit 1)`."),
    ("flagvalue", f'Flag as value: `{Z} --class --invented --conf 60 --source <skill> --file "$F" '
                  '--line <n> --title "$T"`.'),
    ("eqform", f'Equals form: `{Z} --class=CQ --conf=60 --source=<skill> --file="$F" --line=<n> '
               '--title="$T"`.'),
    ("quoted", f'Quoted arguments: `{Z} "$ARGS"`.'),
    ("absolute", f"Absolute: `{Z} --class CQ --conf 60 --source <skill> --file /tmp/zuvo-prose-escape.py "
                 '--line 3 --title "$T"`.'),
    ("parent", f"Parent: `{Z} --class DUP --conf 60 --source <skill> --file src/a.py --line 2 "
               '--also ../zuvo-prose-escape.py:2 --title "$T"`.'),
    ("clash", f'Clash: `{Z} --class DUP --conf 60 --source <skill> --file src --line 2 --also src/a.py:2 '
              '--title "$T"`.'),
    ("cap", f'Cap: `{Z} --class CQ --conf 60 --source <skill> --file "$F" --line 20000 --title "$T"`.'),
    ("prefix", f'Prefix: `{Z} --class CQ --conf 60 --source <skill> --file "$F" --line prefix<n> '
               '--title "$T"`.'),
    ("unresolved", f'Unresolved: `{Z} --class CQ --conf 60 --source <owner> --file "$F" --line <n> '
                   '--title "$T"`.'),
    ("noanchor", f'Any class, no anchor: `{Z} --class <C> --conf <N> --source <skill> --file "$F" --line <n> '
                 '--title "$T"`.'),
    ("", ""),
    ("leadonly", f'- `BUG`, `SEC`, `DATA`: `{Z} --class <C> --conf <N> --source <skill> --file "$F" '
                 '--line <n> --anchor "$A" --title "$T"`'),
    ("leadexcept", f'- any other class with a file: `{Z} --class <C> --conf <N> --source <skill> --file "$F" '
                   '--line <n> --title "$T"`'),
    ("", ""),
    ("subjectC", f'Subject, any class: `{Z} --class <C> --conf <N> --source <skill> '
                 '--target subject:<skill>-x --title "$T"`.'),
    ("discard", f'Discarded: `{Z} --class CQ --conf 20 --source <skill> --file "$F" --line <n> '
                '--title "$T"`.'),
    ("twoonline", f'Two: `{Z} --class BUG --conf 85 --source <skill> --file "$F" --line <n> --anchor "$A" '
                  f'--title "$T"` and `{Z} --class CQ --conf 60 --source <skill> --file "$F" --line <n> '
                  '--title "$T"`.'),
    ("wrapped", f"Wrapped: `{Z} --class CQ --conf 60 --source <skill>"),
    ("", '--file "$F" --line <n> --title "$T"` across two lines.'),
    ("", ""),
    ("unbalanced", f"Broken: `{Z} --class CQ --conf 60"),
    ("", ""),
    ("", "```bash"),
    ("fenced", 'scripts/zuvo-home/backlog-add --repo "$PWD" --class CQ --conf <N> --source <skill> \\'),
    ("", '  --file "$F" --line <n> --title "$T"'),
    ("", "```"),
    ("", ""),
    ("emptyclass", f'- `BUG`, `DATA`: `{Z} --class <C> --conf <N> --source <skill> '
                   '--target subject:<skill>-y --title "$T"`'),
    ("", ""),
    ("perclass", f'- `BUG`, `DATA`: `{Z} --class <C> --conf <N> --source <skill> --file src/<C>.py '
                 '--line <n> --anchor "$A" --title "$T"`'),
    ("", ""),
    ("memoryseed", f'Memory: `{Z} --class CQ --conf 60 --source <skill> --file memory/backlog.md --line 2 '
                   '--title "$T"`.'),
    ("unknownvar", f'Unknown variable: `{Z} --class CQ --conf 60 --source <skill> --file "$F" --line <n> '
                   '--title "$TYPO"`.'),
    ("partialfree", f'Partial placeholder: `{Z} --class CQ --conf 60 --source <skill> --file "$F" --line <n> '
                    '--title "Fix <titl> here"`.'),
    ("zeroline", f'Line zero: `{Z} --class CQ --conf 60 --source <skill> --file "$F" --line 0 '
                 '--title "$T"`.'),
    ("repeated", f'Repeated: `{Z} --class CQ --conf 60 --source <skill> --file "$F" --line <n> '
                 '--file src/other.py --title "$T"`.'),
    ("noclass", f'No class: `{Z} --source <skill> --file "$F" --line <n> --title "$T"`.'),
    ("glued", f'Substitution: `X=$({Z} --class CQ --conf 60 --source <skill> --file "$F" --line <n> '
              '--title "$T")`.'),
    ("operators", f'Quoted operators: `{Z} --class CQ --conf 60 --source <skill> --file "$F" --line <n> '
                  "--fix '>= limit' --evidence 'a | b' --title \"$T\"`."),
    ("", ""),
    ("", "````markdown"),
    ("", "```python"),
    ("nestedfence", 'scripts/zuvo-home/backlog-add --class CQ --conf 60 --source <skill> --file "$F" '
                    '--line <n> --title "$T"'),
    ("", "```"),
    ("", "````"),
    ("", ""),
    ("", "```bash"),
    ("gluedfence", f"ID=`{Z} --class CQ --conf 60`"),
    ("", "```"),
]
FIXTURE_LINE = {k: n for n, (k, _) in enumerate(FIXTURE_LINES, 1) if k}
FIXTURE = "\n".join(t for _, t in FIXTURE_LINES)
SH_PATH = "hooks/fixture-warn.sh"
SH_FIXTURE = "\n".join([
    "#!/bin/sh",
    r"""printf '  Use: ~/.zuvo/backlog-add --repo "$PWD" --class CQ --conf 60 --source <skill> \\\n' >&2""",
    r"""printf '    --file src/seeded.py --line 5 --title "..."   (see backlog-protocol.md)\n' >&2""",
    r"""printf '~/.zuvo/backlog-add --class CQ --conf 60 --source <skill> --file src/seeded.py --line 5 """
    r"""--title "no newline"' >&2""",
    r"""echo "Use ~/.zuvo/backlog-add --class CQ" >&2""",
    r"""printf '~/.zuvo/backlog-add --class CQ --conf 60 --source <skill> --file src/seeded.py --line 5 """
    r"""--title "at eof"'""",
])
SENTENCE_PATH = "shared/includes/fixture-protocol.md"
SENTENCE_FIXTURE = "\n".join([
    "## Filing from a skill",
    "",
    f'3. **Process item.** Not `{Z} --class CQ --conf 60 --source x --file "$F" --line <n> --title "$T"` '
    f'but `{Z} --class PROCESS --conf 90 --source <skill> --target subject:<skill>-<gate> --title "$T"`.',
])
# (fixture id, ordinal, label naming the bug it catches, kind, expected). Kinds:
#   problem  a problem at that span holds `expected`
#   verdict  the span's verdict holds `expected` and no problem is reported there
#   notrun   the span reports a problem and the CLI never ran it
#   classes  a `<C>` span ran exactly these classes, with no problem
#   none     no span and no problem at that line
FIXTURE_ROWS: List[Tuple[str, int, str, str, str]] = [
    ("unknown", 0, "an invented flag (--dimension) is reported as unknown", "problem",
     "unknown flag --dimension"),
    ("unknown", 0, "a span with an unknown flag is not run", "notrun", ""),
    ("badsource", 0, "a source the CLI refuses is reported with its REFUSED reason", "problem",
     "REFUSED bad-source"),
    ("subject", 0, "subject:<skill>-<gate> is substituted, so it is not refused bad-target", "verdict",
     "LEDGER"),
    ("anchored", 0, "a BUG span's <anchor> is seeded at its <line>, so it runs to exit 0", "verdict",
     "ACCEPTED"),
    ("mention", 0, "a bare mention and a `(backlog-add exit 1)` label are not commands", "none", ""),
    ("flagvalue", 0, "a flag after a value flag (--class --invented) is still checked", "problem",
     "unknown flag --invented"),
    ("eqform", 0, "--flag=value is read as the flag and its value", "verdict", "LEDGER"),
    ("quoted", 0, "arguments hidden in a variable (\"$ARGS\") are a problem, not a skip", "problem",
     "cannot be checked"),
    ("absolute", 0, "an absolute --file is never seeded outside the temp repo", "problem",
     "outside the temp repo"),
    ("parent", 0, "a `..` --also is never seeded outside the temp repo", "problem", "outside the temp repo"),
    ("clash", 0, "a file/directory clash is a span problem, not a crash of the whole check", "problem",
     "cannot seed"),
    ("cap", 0, "a --line above the cap is a problem, not a 20000-line seed", "problem",
     "above the seeding cap"),
    ("prefix", 0, "--line prefix<n> is substituted in place and fails, not replaced by a valid default",
     "problem", "not a line number"),
    ("unresolved", 0, "a placeholder outside the table is a problem", "problem",
     "unresolved placeholder <owner>"),
    ("noanchor", 0, "--class <C> runs BUG too, so a span without --anchor fails", "problem",
     "class BUG: exit 3, verdict 'REFUSED missing-field:anchor'"),
    ("leadonly", 0, "a lead-in naming BUG, SEC, DATA runs exactly those", "classes", "BUG,DATA,SEC"),
    ("leadexcept", 0, "\"any other class\" runs every class its sibling does not name", "classes",
     ",".join(sorted(CLASSES - {"BUG", "SEC", "DATA"}))),
    ("subjectC", 0, "a subject target runs only the classes a subject can carry", "classes", "PROCESS,SEC"),
    ("discard", 0, "a command whose finding is DISCARDED fails", "problem", "DISCARDED"),
    ("twoonline", 0, "the first of two spans on one line keeps its own verdict", "verdict", "ACCEPTED"),
    ("twoonline", 1, "the second of two spans on one line keeps its own verdict", "verdict", "LEDGER"),
    ("wrapped", 0, "a span wrapped across two lines of a paragraph is extracted whole", "verdict", "LEDGER"),
    ("unbalanced", 0, "an unpaired backtick next to backlog-add is a problem, not a silent skip", "problem",
     "does not pair"),
    ("fenced", 0, "a non-~/.zuvo prefix with a \\ continuation is extracted whole and runs", "verdict",
     "LEDGER"),
    ("emptyclass", 0, "a lead-in that leaves no class is a problem, not a command that never runs", "problem",
     "leaves no class"),
    ("perclass", 0, "a <C> inside --file is seeded for every class, not only the probe's", "classes",
     "BUG,DATA"),
    ("memoryseed", 0, "a seed under memory/ never overwrites the backlog the CLI reads", "problem",
     "under memory/"),
    ("unknownvar", 0, "a variable outside the table is a problem, not a stand-in value", "problem",
     "unknown variable $TYPO"),
    ("partialfree", 0, "a <…> left inside a free-text value is a problem", "problem",
     "unresolved placeholder <titl>"),
    ("zeroline", 0, "--line 0 is a problem, not a seed on the last line", "problem", "below 1"),
    ("repeated", 0, "a repeated --file is a problem: argparse keeps the last, the seed the first", "problem",
     "--file is repeated"),
    ("noclass", 0, "a command with no --class is a problem, not a flag check only", "problem", "no --class"),
    ("glued", 0, "a command inside $( … ) is found and run", "verdict", "LEDGER"),
    ("gluedfence", 0, "a command word glued to a backtick is a problem, not a silent skip", "problem",
     "glued to shell syntax"),
    ("operators", 0, "a quoted '>= limit' or 'a | b' value does not end the command", "verdict", "LEDGER"),
    ("nestedfence", 0, "a ```python line inside a ```` fence does not close it", "verdict", "LEDGER"),
]
# (line, ordinal, label, kind, expected) for SH_FIXTURE, judged like FIXTURE_ROWS.
SH_ROWS: List[Tuple[int, int, str, str, str]] = [
    (2, 0, "a command a hook prints through printf, `\\`+newline joined, is extracted and run", "verdict",
     "LEDGER"),
    (4, 0, "a printf with no newline before another statement still yields its command", "verdict", "LEDGER"),
    (5, 0, "a printed backlog-add this reader cannot parse (echo) is a problem", "problem",
     "cannot parse"),
    (6, 0, "a printf with no newline at the end of the file still yields its command", "verdict", "LEDGER"),
]


def judge(rep: Report, path: str, line: int, ordinal: int, label: str, kind: str, want: str) -> None:
    """One fixture row against the checker's report."""
    at = {s.line for s in rep.spans if s.path == path}
    key = f"{path}:{line}#{ordinal}"
    mine = [p for k, p in rep.problems if k == key]
    verdict = rep.verdicts.get(key)
    if kind == "problem":
        good, got = any(want in p for p in mine), "; ".join(mine) or "nothing reported"
    elif kind == "verdict":
        good = verdict is not None and want in verdict and not mine
        got = f"verdict '{verdict}'" + (f"; problems: {'; '.join(mine)}" if mine else "")
    elif kind == "notrun":
        good, got = bool(mine) and verdict is None, f"verdict '{verdict}', problems {mine}"
    elif kind == "classes":
        ran = ",".join(rep.classes.get(key, []))
        good, got = ran == want and not mine, f"classes '{ran}'" + (f"; problems: {mine}" if mine else "")
    else:
        good = line not in at and not mine
        got = "a span was extracted" if line in at else "; ".join(mine)
    miss = "" if good else f" — expected {kind} '{want}', got {got}"
    (ok if good else no)(f"S {key} {label}{miss}")


def self_check() -> None:
    rep = check([(FIXTURE_PATH, FIXTURE), (SH_PATH, SH_FIXTURE)])
    for fid, ordinal, label, kind, want in FIXTURE_ROWS:
        judge(rep, FIXTURE_PATH, FIXTURE_LINE[fid], ordinal, label, kind, want)
    for line, ordinal, label, kind, want in SH_ROWS:
        judge(rep, SH_PATH, line, ordinal, label, kind, want)
    spans, _ = extract(SENTENCE_PATH, SENTENCE_FIXTURE)
    picked = sentence(spans, SENTENCE_FIXTURE, "3. **Process item.**", is_process)
    (ok if picked is not None and picked.ordinal == 1 else no)(
        f"S {SENTENCE_PATH}:3 the flow picks the span its sentence means, not the first on the line "
        f"(picked {picked.key if picked else None})")


# ── T: scope mirror ───────────────────────────────────────────────────────────────────────────────
def scope_check() -> None:
    m = re.search(r"^SCOPE_GLOBS = (\(.*?\))\n", open(GUARD, encoding="utf-8").read(), re.S | re.M)
    theirs = ast.literal_eval(m.group(1)) if m else None
    (ok if theirs == SCOPE_GLOBS else no)(
        f"T the scope equals the hand-append guard's SCOPE_GLOBS (a drifted copy skips files): {theirs!r}")


# ── C: the tree ───────────────────────────────────────────────────────────────────────────────────
def tree_check() -> None:
    files = sorted({os.path.relpath(f, ROOT) for g in SCOPE_GLOBS for f in glob.glob(os.path.join(ROOT, g))})
    files += list(EXTRA_SOURCES)
    docs = [(f, open(os.path.join(ROOT, f), encoding="utf-8").read()) for f in files]
    rep = check(docs)
    runs = [s for s in rep.spans if s.runs]
    print(f"  ... {len(files)} files, {len(rep.spans)} commands: {len(runs)} with --class (run), "
          f"{len(rep.spans) - len(runs)} flag check only; {rep.executed} CLI runs")
    for s in rep.spans:
        print(f"      {s.key}: {rep.verdicts.get(s.key, 'flag check only')}")
    for extra in EXTRA_SOURCES:
        n = sum(1 for s in rep.spans if s.path == extra)
        (ok if n else no)(f"C {extra} yields its printed command ({n}): a reworded hook the reader lost")
    if rep.problems:
        for key, p in rep.problems:
            no(f"C {key}: {p}")
    else:
        ok("C every command's flags are the CLI's; every --class command runs to exit 0, ACCEPTED or LEDGER")
    (ok if len(rep.spans) >= SPAN_FLOOR else no)(
        f"C command count {len(rep.spans)} >= floor {SPAN_FLOOR} (an extractor that stopped finding spans)")
    (ok if rep.executed >= RUN_FLOOR else no)(
        f"C CLI run count {rep.executed} >= floor {RUN_FLOOR} (a run check that stopped running)")


# ── F: the canonical flow ─────────────────────────────────────────────────────────────────────────
def is_generic(s: Span) -> bool:
    return value(s.args, "--class") == "<C>" and "--file" in s.flags


def is_process(s: Span) -> bool:
    return value(s.args, "--class") == "PROCESS" and "--target" in s.flags


def sentence(spans: Sequence[Span], text: str, head: str, want: Callable[[Span], bool]) -> Optional[Span]:
    """The one span on the "Filing from a skill" line starting with `head` that `want` accepts."""
    lines = text.split("\n")
    sec = next((k for k, ln in enumerate(lines) if ln.strip() == "## Filing from a skill"), None)
    if sec is None:
        return None
    for k in range(sec + 1, len(lines)):
        if lines[k].startswith("## "):
            return None
        if lines[k].lstrip().startswith(head):
            hits = [s for s in spans if s.line == k + 1 and want(s)]
            return hits[0] if len(hits) == 1 else None
    return None


def sha(path: str) -> str:
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def flow_check() -> None:
    text = open(os.path.join(ROOT, PROTOCOL), encoding="utf-8").read()
    spans, _ = extract(PROTOCOL, text)
    generic = sentence(spans, text, "1. **Generic write.**", is_generic)
    process = sentence(spans, text, "3. **Process item.**", is_process)
    if generic is None or process is None:
        no(f"F the protocol's sentences 1 and 3 hold one backlog-add command each ({generic=}, {process=})")
        return
    repo = tempfile.mkdtemp(dir=WORK)
    probe, _ = substitute(generic, repo, "BUG")
    seed_repo(repo, seeds_of(probe), branch="feat/x")
    backlog = os.path.join(repo, "memory/backlog.md")

    def run(label: str, span: Span, cls: Optional[str], conf: Optional[str]) -> str:
        argv, problems = substitute(span, repo, cls, conf)
        rc, out, err = cli(repo, argv)
        print(f"  ... F {label}: rc={rc} {out}")
        if rc != 0 or problems:
            no(f"F {label}: exit {rc}; {problems}; stdout: {out}; stderr: {err[-300:]}")
        return out

    out = run("BUG conf 85", generic, "BUG", "85")
    bid = out.split()[2] if out.startswith("ACCEPTED backlog B-") else "<none>"
    lines = open(backlog, encoding="utf-8").read().splitlines()
    entry = [ln for ln in lines if ln.startswith(f"- [ ] {bid} ")]
    (ok if bid != "<none>" and len(entry) == 1 and entry[0].endswith(" [branch:feat/x]") else no)(
        f"F BUG -> 'ACCEPTED backlog B-', one entry ending [branch:feat/x] (a sentence that lands no entry, "
        f"or untagged): {out} / {entry}")

    before = sha(backlog)
    out = run("CQ conf 90", generic, "CQ", "90")
    (ok if out.startswith("LEDGER F-") and " reason=class-report-only " in f" {out} " else no)(
        f"F CQ -> 'LEDGER F-' reason=class-report-only (a report-only class ticketed): {out}")
    (ok if sha(backlog) == before else no)(
        "F CQ leaves memory/backlog.md byte-identical (a ledger route that writes the backlog)")

    first = run("PROCESS 1", process, None, None)
    second = run("PROCESS 2", process, None, None)
    (ok if first.startswith("LEDGER F-") else no)(f"F PROCESS first run -> 'LEDGER F-': {first}")
    (ok if second.startswith("LEDGER-BUMPED ") and " seen=2 " in f" {second} " else no)(
        f"F PROCESS repeat -> 'LEDGER-BUMPED' seen=2 (a fixed title that still splits the record): {second}")


def main() -> None:
    for name, step in (("S", self_check), ("T", scope_check), ("C", tree_check), ("F", flow_check)):
        try:
            step()
        except Exception as exc:  # a crash in one step is a FAIL, never a silent pass of the rest
            no(f"{name} crashed: {type(exc).__name__}: {exc}")
    print(f"RESULT: PASS={Out.passed} FAIL={Out.failed}")
    sys.exit(1 if Out.failed else 0)


main()
PY
