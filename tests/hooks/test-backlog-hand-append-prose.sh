#!/usr/bin/env bash
# The prose guard: no skill, agent, reference or include tells an agent to write `memory/backlog.md`
# by hand.
#
# The defect this catches: a skill sentence such as "If fix is larger, add to backlog with file:line"
# makes the agent append a row itself, which skips every bar, the dedupe and the lock of
# `~/.zuvo/backlog-add`; the intake then tickets that row. The runtime hook only warns after the fact,
# so the sentence has to be caught where it is written.
#
# Usage: bash tests/hooks/test-backlog-hand-append-prose.sh [--only PATH ...]
# Exit 0 = PASS, 1 = any FAIL, 2 = usage error. The self-test (G2), the mutants (G2m), the verdict-logic
# checks (G2u) and the tree-path mutation (G2t) run on every invocation, so a matcher that silently reads
# nothing cannot pass. `--only` narrows the per-file scan; the tree mutation always runs on the full
# scope, because it proves the scanner, not the files.
#
# Reads only files under the repo root: no git, no ~/.zuvo, no network, no subprocess.
#
# Rules, all in the Python below:
#   Tier A  hand-write mechanics (a `B-{N}` row template, a dated process id, "increment Seen",
#           "Remove row by fingerprint", ...). Exempt only by a negation in the same sentence (an
#           abbreviation's full stop ends none) or the allowlist; a `unit` key excuses its own sentence only.
#   Tier B  soft verbs ("add it to backlog", "-> per-file backlog", "**Backlog:**", ...). Also exempt
#           when the SENTENCE holding the match (the line, inside a fence) cites `backlog-add`,
#           `drive-by-findings.md` or the protocol sections.
#   B:restated-verdict-table  a `| Verdict | Exit |` table outside the protocol (CQ14).
#   G6      every `--source` in a `backlog-add` unit is valid, and the legacy source tokens are gone.
# Every flagged unit in any file is a FAIL. No PENDING list remains; the allowlist (G5) is the only
# exemption, and it is checked for rot.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"

echo "== backlog hand-append prose guard =="
python3 - "$ROOT" "$@" <<'PY'
import glob
import os
import re
import sys
import time
from dataclasses import dataclass, replace
from typing import Callable, Dict, FrozenSet, List, Optional, Pattern, Sequence, Set, Tuple

STARTED = time.monotonic()
ROOT = sys.argv[1]
ARGV = sys.argv[2:]

SCOPE_GLOBS = ("skills/*/SKILL.md", "skills/*/agents/*.md", "skills/*/references/*.md",
               "shared/includes/*.md")
FILE_FLOOR = 200
# 90% of the units measured on the tree this guard shipped with: a splitter that stops splitting, or a
# glob that loses a directory, drops below it.
UNIT_FLOOR = 25146
PROTOCOL = "shared/includes/backlog-protocol.md"
FILE_SCOPE_ALLOWED = ("shared/includes/backlog-protocol.md", "shared/includes/backlog-grooming.md",
                      "skills/backlog/agents/backlog-verifier.md")
FORBIDDEN_SECTIONS = ("Adding Items",)

# (path, scope, key, reason). scope: file | section (an exact heading) | unit (an exact substring of
# one unit, for a proven false positive). No line numbers: they drift.
Allow = Tuple[str, str, str, str]
ALLOWLIST: List[Allow] = [
    ("shared/includes/backlog-protocol.md", "file", "",
     "the protocol defines the backlog format, the lookup and the archive; it is the contract itself"),
    ("shared/includes/backlog-grooming.md", "file", "",
     "grooming verdicts and dispositions over existing entries; no finding is filed from it"),
    ("skills/backlog/agents/backlog-verifier.md", "file", "",
     "read-only grooming lane: it returns verdicts on existing entries"),
    ("skills/backlog/SKILL.md", "unit", "It writes nothing to `memory/backlog.md`",
     "groom mode states that `apply` writes nothing to the backlog itself; the archive helper closes entries"),
    ("shared/includes/drive-by-findings.md", "unit",
     "goes at the TOP of the final summary, not only in the backlog",
     "says a SEC drive-by is also shown in the summary, beside the entry backlog-add filed; no hand write"),
    ("skills/refactor/references/completion.md", "unit",
     "an adversarial pass that surfaces 8 bugs and backlogs them",
     "a prohibition: parking findings instead of fixing them is BLOCKED; the negation sits outside the window"),
]

# {path: [quote, ...]}: sentences a batch retired. A quote back in its file is a FAIL, permanently. Matched
# with whitespace collapsed and dashes folded (DASH_CHARS and `--` to `-`, spacing around a dash made one
# ` - `), so neither a reflow nor a swapped dash lets one back in.
RETIRED_QUOTES: Dict[str, List[str]] = {
    # a "**Backlog:**" step label: the batch loop's deferred items now go through backlog-add
    "shared/includes/refactor-reference.md": ["**Backlog:** Persist ONLY"],
    # POLICY with no write verb, so the patterns never flagged it: the path wraps onto the next line
    "shared/includes/test-bugfix-protocol.md": ["user-declined items remain in"],
    # a11y-audit: the persist step wrote a pipe-less B-{N} line by hand, deduped it with a `seen:N` counter,
    # and was automatic on a CRITICAL finding; the flag row said "Emit backlog entries"
    "skills/a11y-audit/SKILL.md": ["For each CRITICAL or HIGH finding, persist to `memory/backlog.md`",
                                   "increment `seen:N`",
                                   "Emit backlog entries for CRITICAL/HIGH findings"],
    # api-audit: the opt-in persist step read, fingerprinted, deduped and deleted by hand
    "skills/api-audit/SKILL.md": ["persist findings (confidence 26+) to `memory/backlog.md`",
                                  "If missing, create with template",
                                  "Delete resolved items. Confidence 0-25 = DISCARD"],
    # architecture: every output item was written to memory/backlog.md by hand, and "may be silently
    # discarded" was a rule with no bar behind it
    "skills/architecture/SKILL.md": ["persist actionable items to `memory/backlog.md`",
                                     "they must reach the backlog"],
    # the auditor's deferred label and its stale "Phase 4.4" hand-off (the hand template is gone), and a
    # checklist label for the below-A WARN, which is now filed through backlog-add
    "skills/build/SKILL.md": ["DEFER (backlog)", "Persist to backlog in Phase 4.4", "or WARN + backlogged"],
    # code-audit: the persist step and Tier A rule deleted open entries; the checklist and the incomplete-run
    # item named a hand backlog update and a dated B-id
    "skills/code-audit/SKILL.md": ["Delete any open backlog items for Tier A files",
                                   "Delete resolved items (Tier A files with open items)",
                                   "If missing, create with template",
                                   "[ ] Backlog updated for deferred findings",
                                   "`B-code-audit-incomplete-<date>`"],
    # container-audit: the flag pushed findings to a skill that has no such mode
    "skills/container-audit/SKILL.md": ["Push findings to `zuvo:backlog`"],
    # the web and content family: the opt-in persist steps emitted, fingerprinted and deduped by hand, and the
    # fix tables removed rows by fingerprint and added OPEN rows; live pages are filed by URL now. content-expand
    # persisted "per backlog-protocol.md" (no backlog word, so the patterns never flagged it)
    "skills/content-audit/SKILL.md": ["Append findings to memory/backlog.md",
                                      "persist findings per `shared/includes/backlog-protocol.md`",
                                      "Add as OPEN with category `content-blocking`",
                                      "**Fingerprint format:** `{file}|{dimension}|{check}`"],
    "skills/content-expand/SKILL.md": ["Persist findings per `backlog-protocol.md`"],
    "skills/content-fix/SKILL.md": ["`memory/backlog.md` for backlog updates",
                                    "Remove row by fingerprint",
                                    "Add as OPEN with category `content-manual`",
                                    "**Fingerprint format:** `{file}|{dimension}|{check}`"],
    # db-audit: an incomplete run and a missing tool were a dated B-id and a "[BLOCKER]" item, and the report
    # template and checklist asked for /backlog add commands and a hand "updated" tick
    "skills/db-audit/SKILL.md": ["`[BLOCKER] db-audit needs <tool> on <project>`",
                                 "`B-db-audit-incomplete-<date>`",
                                 "[/backlog add commands for HIGH+ findings]",
                                 "[ ] Backlog updated for HIGH+ findings",
                                 "and add a backlog item."],
    # the legacy drive-by source, now `drive-by:debug`
    "skills/debug/SKILL.md": ["debug/[date]"],
    # execute's own fingerprint, dedupe and confidence bands, and the labels and references that named them
    "skills/execute/SKILL.md": ["0-25 discard, 26-50 backlog only",
                                "New work → `memory/backlog.md`",
                                "is a backlog candidate (persist via `backlog-protocol.md`)",
                                "same scheme as Backlog Persistence",
                                "or WARN + backlogged",
                                "[ ] Backlog persistence ran for deferred findings",
                                "every finding with confidence above 25% is persisted"],
    # fix-tests: the policy line and the persist step wrote memory/backlog.md by hand, and the adversarial
    # boilerplate told the agent to add to the backlog; the report line and checklist named the backlog
    "skills/fix-tests/SKILL.md": ["`memory/backlog.md` receives only what is genuinely out-of-scope or user-declined.",
                                  "or files that could not be fixed automatically, to `memory/backlog.md`",
                                  "If fix is larger, add to backlog with specific file:line",
                                  "add it to backlog with file:line",
                                  "Backlog holds only genuinely out-of-scope or user-declined items",
                                  "Bugs discovered: [N] (see backlog)"],
    "skills/geo-audit/SKILL.md": ["Persist findings to `memory/backlog.md`",
                                  "Emit entries to `memory/backlog.md` for findings that meet",
                                  "Same format used by geo-fix for backlog updates"],
    "skills/geo-fix/SKILL.md": ["`memory/backlog.md` for backlog updates",
                                "If fix is larger, add to backlog with specific file:line",
                                "add it to backlog with file:line",
                                "Remove row by fingerprint",
                                "Persist with scaffold content reference",
                                "Add as OPEN with category `geo-manual`",
                                "**Fingerprint format:** `{file}|{dimension}|{check}`"],
    # infra-audit: the Stage 2 load line read "findings → backlog entries", a hand-written step with no body
    "skills/infra-audit/SKILL.md": ["(findings → backlog entries)"],
    # pentest: the suggested `zuvo:backlog add` used flags (`--severity HIGH`, `--dimension`) that do not exist; the
    # full quote is kept, because `--dimensions PT1,PT2` in the flag table is a real flag
    "skills/pentest/SKILL.md": ["--source pentest --dimension PT3",
                                "suggest a backlog entry:"],
    # performance-audit: a "propose a backlog entry" step whose `/backlog add` command was a hand-written entry
    "skills/performance-audit/SKILL.md": ["/backlog add PERF", "propose a backlog entry:"],
    # the auditor's own deferred-item line, which drifted from the preamble's format
    "skills/refactor/agents/cq-auditor.md": ["description (confidence: N%)"],
    # staging policy with no write verb: the `wrote=` paths backlog-add prints are staged now; the old
    # source is the whole span, since the agent's name may still appear in `--evidence`
    "skills/refactor/references/completion.md": ["is LOCAL telemetry — never stage it",
                                                 "--source zuvo:refactor/cq-auditor"],
    # a hand-written per-file entry for surviving mutants
    "skills/refactor/references/remediation.md": ["per-file backlog entry naming each"],
    # review's retired confidence tags (0-25 is not passed to backlog-add; the column is `Disposition`)
    "skills/review/agents/confidence-rescorer.md": ["[low-confidence]", "[below-threshold]"],
    # review read and edited the backlog as a commit queue (D6), tagged findings by confidence (D3), keyed
    # the drift gate on B-ids only (D2), and named its backlog writes and IDs outside backlog-add
    "skills/review/SKILL.md": ["clean `memory/backlog.md`",
                               "-> clean backlog",
                               "unchecked entries -> oldest entry's parent hash",
                               "Remove reviewed commits from backlog",
                               "[low-confidence]",
                               "[below-threshold]",
                               "If yes, remove the line",
                               "All backlog writes happen AFTER Phase 4",
                               "<B-id> NO_VALID_DEFER_REASON",
                               "Record applied vs deferred (backlog IDs)"],
    # security-audit: the opt-in persist step fingerprinted by hand, the grace line counted "backlogged"
    # findings, and the incomplete-run item was a dated B-id
    "skills/security-audit/SKILL.md": ["persist CRITICAL and HIGH findings to `memory/backlog.md`",
                                       "Fingerprint: `file|dimension|endpoint`",
                                       "reported + backlogged",
                                       "`B-security-audit-incomplete-<date>`"],
    "skills/seo-audit/SKILL.md": ["Persist prioritized findings to `memory/backlog.md`",
                                  "Emit entries to `memory/backlog.md` for findings that meet",
                                  "Same format used by seo-fix for backlog updates"],
    "skills/seo-fix/SKILL.md": ["`memory/backlog.md` for backlog updates",
                                "If fix is larger, add to backlog with specific file:line",
                                "add it to backlog with file:line",
                                "Remove row by fingerprint",
                                "Add as OPEN with category `seo-manual`",
                                "**Fingerprint format:** `{file}|{dimension}|{check}`"],
    # ship let a NIT be dropped silently (D7), wrote carried failures and RECOMMENDED by hand, and its report
    # line counted hand-backlogged findings
    "skills/ship/SKILL.md": ["<n> backlogged", "backlog or ignore", "record it in `memory/backlog.md`",
                             "silently is fine", "write them to `memory/backlog.md`"],
    # structure-audit: HIGH/CRITICAL findings were fingerprinted and deduped by hand under a dated incomplete id
    "skills/structure-audit/SKILL.md": ["persist to `memory/backlog.md`",
                                        "Fingerprint format: `file|SA-dimension|check-id`",
                                        "`B-structure-audit-incomplete-<date>`"],
    # test-audit wrote memory/backlog.md by hand (read, fingerprint, increment Seen, delete resolved items)
    # under an invalid dated source, and its report and checklist counted those hand writes
    "skills/test-audit/SKILL.md": ["test-audit/{date}",
                                   "Delete resolved items",
                                   "If missing, create with template",
                                   "backlog.md updated: [N] entries ([N] new, [N] deduped)",
                                   "[ ] Backlog updated for critical gate failures"],
    # write-e2e: the adversarial boilerplate and the below-A WARN named a hand backlog row
    "skills/write-e2e/SKILL.md": ["else backlog with file:line",
                                  "WARN + per-file backlog",
                                  "WARN + backlogged"],
    # write-tests: environment blockers, skipped tiers and deferred findings said "backlog" with no helper;
    # the resume column, the checklist and the completion step named the backlog as the place they went
    "skills/write-tests/SKILL.md": ["backlog the environment issue",
                                    "backlog one run-level environment issue",
                                    "`FAILED`, backlog, no Step 4",
                                    "run-level ENV blocker — backlog",
                                    "backlog `duplicate-test-suite`",
                                    "and backlog the extraction",
                                    "printed as context and backlogged",
                                    "skip after backlog",
                                    "| Backlog with file:line |",
                                    "rejection requires backlog entry",
                                    "`FAILED` + backlog",
                                    "unfixed out-of-scope issues → `memory/backlog.md`",
                                    "loud WARN + backlog",
                                    "backlog the problems noticed OUTSIDE the files under test",
                                    "sub-A files fixed (or WARN + backlog)",
                                    "Skip (already backlogged)"],
}

VERB_PATH = r"(?:persist|add|writ|wrote|record|append|push|emit|clean|remov|drop|delet)"
VERB_DEST = r"(?:persist|add|writ|record|push|go|went|rout|defer|reach|stay)"
# (name, required literal, regex). A rule can only match a unit that holds its literal (lowercase
# literal: compared case-insensitively), so the literal is an exact pre-filter; check_config proves each
# literal is spelled inside its own regex.
TIER_A: Tuple[Tuple[str, str, str], ...] = (
    ("b-n-pipe", "B-{N}", r"B-\{N\}\s*\|"),
    ("next-b-n", "B-{N}", r"\bnext .{0,10}B-\{N\}"),
    ("b-n-line", "B-{N}", r"(?m:^\s*- B-\{N\})"),
    ("dated-process-id", "B-", r"\bB-[\w-]+-(?:<date>|YYYY-MM-DD)"),
    ("increment-seen", "een", r"(?i:increment)\s+[`*]*[Ss]een"),
    ("add-as-open", "dd as OPEN", r"\b[Aa]dd as OPEN\b"),
    ("remove-row-by-fingerprint", "remove row by fingerprint", r"(?i:remove row by fingerprint)"),
    ("delete-resolved", "delete ", r"(?i:\bdelete (?:resolved items|any open backlog))"),
    ("create-if-missing", "if missing, create", r"(?i:memory/backlog\.md`?\. if missing, create)"),
    ("slash-backlog-add", "backlog add", r"(?:zuvo:|/)backlog add\b"),
)
TIER_B: Tuple[Tuple[str, str, str], ...] = (
    ("verb-before-backlog-md", "memory/backlog.md", r"(?i:\b%s\w*\b.{0,80}?memory/backlog\.md)" % VERB_PATH),
    ("verb-to-backlog", "backlog", r"(?i:\b%s\w*\b.{0,60}?\b(?:to|in|into)\s+(?:the\s+)?backlog(?![-\w]))" % VERB_DEST),
    ("backlog-object", "backlog", r"(?i:\bbacklog(?:s|ged)? (?:it|them|the \w+|each|with)\b)"),
    ("arrow-backlog", "backlog", r"(?i:(?:→|->|\+) (?:per-file |per-module )?backlog(?![-\w]))"),
    ("record-backlog-item", "backlog", r"(?i:\b(?:add|record)\w*\b.{0,40}?\bbacklog (?:item|entry))"),
    ("and-backlogged", "backlog", r"(?i:\band backlogged\b)"),
    ("backlog-only-if", "backlog", r"(?i:\bbacklog only if\b)"),
    ("and-the-backlog", "backlog", r"(?i:\band the backlog(?![-\w]))"),
    ("backlog-label", "backlog", r"(?i:\*\*backlog(?: persistence)?:\*\*)"),
    ("named-backlog-item", "backlog", r"(?i:\b(?:per-file|per-module|named) backlog (?:item|entry))"),
    ("after-backlog", "backlog", r"(?i:\bafter backlog\b)"),
    ("push-zuvo-backlog", "zuvo:backlog", r"(?i:\b(?:push|emit|send)\w*\b.{0,40}?`?zuvo:backlog\b)"),
)
TABLE_RULE = ("B", "restated-verdict-table")
G6_RULES = (("G6", "bad-source"), ("G6", "legacy-source"))

# `backlog-add(?!s)`: the telemetry field `backlog-adds` names a count, not the helper, so it cites nothing.
CITE = re.compile(r"~/\.zuvo/backlog-add|backlog-add(?!s)|drive-by-findings\.md|Persisting a finding|"
                  r"Filing from a skill")
NEG_WORDS: FrozenSet[str] = frozenset({"never", "not", "no", "don't", "nor", "without"})
NEG_PAIRS = {("instead", "of"), ("rather", "than")}
# "not fixed", "no ... resolved": a condition on the finding, not a prohibition of the write.
STATE_WORDS = frozenset({"fixed", "resolved", "done", "addressed", "handled", "applied"})
WORD = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)?")
CODE_SPAN = re.compile(r"`[^`\n]*`")
QUOTE = re.compile(r'"[^"\n]*"|“[^”\n]*”')
# A quoted span is kept (only its quote marks blanked, so `to "the backlog"` still reads "to the backlog")
# when it is part of an instruction: it holds both a write verb and the destination (`"append the row to
# memory/backlog.md"`), or it is nothing but the destination (`Append the row to "memory/backlog.md"`) or
# nothing but the verb (`Then "add" it to the backlog`), or it names the destination while a write verb sits
# before it in the same sentence (`Add it to the "main backlog"`: only the destination words survive). A quoted phrase with other words in it is a
# mention and is blanked: `the "RECOMMENDED → backlog" reflex`, `"I'll backlog the bug" is the rationalization`.
QUOTE_DEST = re.compile(r"(?i)\bbacklog(?![-\w])|memory/")
QUOTE_DEST_TOKEN = re.compile(r"(?i)\bbacklog(?![-\w])|memory/[\w./-]*")
QUOTE_VERB = re.compile(r"(?i)\b(?:%s|%s)\w*" % (VERB_PATH, VERB_DEST))
QUOTE_ONLY_DEST = re.compile(r"(?i)\s*(?:the\s+)?(?:backlog|memory/[\w./-]*)\s*")
QUOTE_ONLY_VERB = re.compile(r"(?i)\s*(?:%s|%s)\w*\s*" % (VERB_PATH, VERB_DEST))
MASK = re.compile(r"\x00(\d+)\x00")
ITEM_START = re.compile(r"^(?:[-*+]|\d+[a-z]?[.)]|\|)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
# The whole opening run: a ```` fence is not closed by a ```python line inside it.
FENCE_OPEN = re.compile(r"^(`{3,}|~{3,})")
FENCE_OPEN_PREFIX = re.compile(r"^(```|~~~)")  # the retired reading, kept for its mutant only
TABLE_SEP = re.compile(r"^\s*\|[\s:|-]+\|?\s*$")
# The dashes a retired-quote match folds to `-`: U+2010 to U+2015 (hyphen, non-breaking hyphen, figure
# dash, en dash, em dash, horizontal bar) and U+2212 (minus sign).
DASH_CHARS = "\u2010\u2011\u2012\u2013\u2014\u2015\u2212"
SENTENCE_END = re.compile(r"[.!?](?=\s)|\s\|\s")
# An abbreviation's full stop ends no sentence: "Add the finding (e.g. src/x.py) to the backlog." is one.
# `etc.` is not one: it usually ends the sentence ("... BUG, SEC, etc. Otherwise add it to backlog.").
ABBREVIATION = re.compile(r"(?i)\b(?:e\.g|i\.e|vs|cf)\.")
ABBREVIATION_ETC = re.compile(r"(?i)\b(?:e\.g|i\.e|etc|vs|cf)\.")
G6_CONTEXT = re.compile(r"backlog-add(?!s)|zuvo:backlog add")
SOURCE_TOKEN = re.compile(r"--source(?![-\w])(?:=|\s+)(?:\"([^\"\n]*)\"|'([^'\n]*)'|([^\s'`\"|),;]+))")
SOURCE_OK = re.compile(r"(?:drive-by:)?[a-z0-9-]+")
SOURCE_PLACEHOLDERS = {"<skill>", "drive-by:<skill>", "<src>"}
LEGACY_SOURCE = re.compile(r"(?i)--source zuvo:|source:\**\s*`?test-audit/|source:\**\s*`manual`|formerly `debug/")


def fence_opening(s: str, prefix: bool = False) -> Optional[str]:
    """The opening run of a fence line (stripped), or None."""
    m = (FENCE_OPEN_PREFIX if prefix else FENCE_OPEN).match(s)
    return m.group(1) if m else None


def fence_closes(s: str, fence: str, prefix: bool = False) -> bool:
    """A fence closes only on its own character, at least as long as its opener, with nothing after it."""
    if prefix:
        return s.startswith(fence)
    return re.fullmatch(r"%s{%d,}\s*" % (re.escape(fence[0]), len(fence)), s) is not None


@dataclass(frozen=True)
class Cfg:
    """Everything a mutant may change. The real guard is `REAL`; each mutant is one `replace` of it."""
    rules: Tuple[Tuple[str, str, str, str], ...]
    table_check: bool = True
    table_icase: bool = True
    table_exact: bool = True
    table_all: bool = True
    g6_bad: bool = True
    g6_legacy: bool = True
    g6_raw: bool = True
    neg_window: Optional[int] = 3
    neg_sentence: bool = True
    neg_words: FrozenSet[str] = NEG_WORDS
    state_is_condition: bool = True
    cite: Pattern[str] = CITE
    cite_scope: str = "sentence"
    fence_lines: bool = True
    mask_abbrev: bool = True
    abbreviation: Pattern[str] = ABBREVIATION
    split_items: bool = True
    join_lines: bool = True
    quote_mode: str = "line"
    cite_tier_a: bool = False
    allow_unit_wide: bool = False
    fence_prefix: bool = False
    retired_norm: bool = True
    retired_dash: bool = True
    retired_dashes: str = DASH_CHARS
    retired_runs: bool = True
    retired_dash_space: bool = True


@dataclass(frozen=True)
class Unit:
    """`text` is `raw` with quotations blanked, character for character, so offsets are shared."""
    start: int
    end: int
    text: str
    raw: str
    fence: bool


@dataclass(frozen=True)
class Hit:
    """`lo`/`hi`: the sentence (or fence line) holding the match, as offsets into the unit; -1 when the
    hit belongs to the whole unit (G6, the verdict table), which a `unit` allowlist key never excuses."""
    tier: str
    name: str
    lo: int = -1
    hi: int = -1


@dataclass(frozen=True)
class Flag:
    line: int
    hits: Tuple[Hit, ...]
    text: str
    raw: str


_COMPILED: Dict[Tuple[Tuple[str, str, str, str], ...], Tuple[Tuple[str, str, str, Pattern[str]], ...]] = {}


def compiled(cfg: Cfg) -> Tuple[Tuple[str, str, str, Pattern[str]], ...]:
    if cfg.rules not in _COMPILED:
        _COMPILED[cfg.rules] = tuple((t, n, tok, re.compile(p)) for t, n, tok, p in cfg.rules)
    return _COMPILED[cfg.rules]


def blank(s: str) -> str:
    return re.sub(r"[^\n]", " ", s)


def sentence_head(prefix: str) -> str:
    """The part of `prefix` after its last sentence end: the words before a quote that are in its sentence."""
    masked = ABBREVIATION.sub(lambda m: "x" * len(m.group(0)), prefix)
    ends = [m.end() for m in SENTENCE_END.finditer(masked)]
    return prefix[ends[-1]:] if ends else prefix


def strip_quotes(line: str, mode: str) -> str:
    """Blank a balanced quotation of <= 80 characters within the line, unless it is part of an instruction
    (see QUOTE_DEST); code spans are kept verbatim."""
    if mode not in ("line", "prior", "all", "both") or ('"' not in line and "“" not in line):
        return line
    codes: List[str] = []

    def mask(m: "re.Match[str]") -> str:
        codes.append(m.group(0))
        return "\x00%d\x00" % (len(codes) - 1)

    def unmask(s: str) -> str:
        return MASK.sub(lambda m: codes[int(m.group(1))], s)

    def drop(m: "re.Match[str]") -> str:
        span = unmask(m.group(0))
        if len(span) > 80:
            return m.group(0)
        inner = span[1:-1]
        both = bool(QUOTE_DEST.search(inner) and QUOTE_VERB.search(inner))
        alone = bool(QUOTE_ONLY_DEST.fullmatch(inner) or QUOTE_ONLY_VERB.fullmatch(inner))
        # A write verb before the quote, in its own sentence, makes a quoted destination the object of
        # that verb (`Add it to the "main backlog"`), whatever else the quote says.
        after_verb = bool(QUOTE_DEST.search(inner) and QUOTE_VERB.search(sentence_head(m.string[:m.start()])))
        # "both": only a span holding both halves is kept (the earlier rule); "prior": the round-3 rule
        # without the verb-before-the-quote case. Each is a mutant.
        if (mode == "line" and (both or alone)) or (mode == "prior" and (both or alone)) or (mode == "both" and both):
            return " " + inner + " "
        if mode == "line" and after_verb:
            # Only the destination survives, so `to the "main backlog"` still reads "to the   backlog".
            kept = [" "] * len(inner)
            for d in QUOTE_DEST_TOKEN.finditer(inner):
                kept[d.start():d.end()] = list(d.group(0))
            return " " + "".join(kept) + " "
        return blank(span)

    return unmask(QUOTE.sub(drop, CODE_SPAN.sub(mask, line)))


def split_units(text: str, cfg: Cfg) -> List[Unit]:
    units: List[Unit] = []
    cur: List[Tuple[int, str]] = []
    fence: Optional[str] = None

    def flush(is_fence: bool = False) -> None:
        if not cur:
            return
        raws = [r.strip() for _, r in cur]
        sep = "\n" if is_fence else " "
        raw = sep.join(raws)
        joined = sep.join(strip_quotes(r, cfg.quote_mode) for r in raws)
        if cfg.quote_mode == "greedy":
            joined = re.sub(r'".*"', lambda m: blank(m.group(0)), joined, flags=re.S)
        units.append(Unit(cur[0][0], cur[-1][0], joined, raw, is_fence))
        cur.clear()

    for n, line in enumerate(text.split("\n"), 1):
        s = line.strip()
        if fence is not None:
            cur.append((n, line))
            if fence_closes(s, fence, cfg.fence_prefix):
                flush(True)
                fence = None
            continue
        opener = fence_opening(s, cfg.fence_prefix)
        if opener:
            flush()
            fence = opener
            cur.append((n, line))
            continue
        if not s:
            flush()
            continue
        if (cfg.split_items and ITEM_START.match(s)) or HEADING.match(s) or not cfg.join_lines:
            flush()
        cur.append((n, line))
    flush(fence is not None)
    return units


def boundaries(unit: Unit, cfg: Cfg) -> List[Tuple[int, int]]:
    """Where one sentence (or table cell) ends and the next begins; inside a fence, each line break."""
    if unit.fence and cfg.fence_lines:
        return [(m.start(), m.end()) for m in re.finditer("\n", unit.raw)]
    masked = CODE_SPAN.sub(lambda m: "x" * len(m.group(0)), unit.raw)
    if cfg.mask_abbrev:
        masked = cfg.abbreviation.sub(lambda m: "x" * len(m.group(0)), masked)
    return [(m.start(), m.end()) for m in SENTENCE_END.finditer(masked)]


def sentence_of(bounds: List[Tuple[int, int]], start: int, end: int, size: int) -> Optional[Tuple[int, int]]:
    """The sentence holding [start, end), or None when the match runs across a sentence boundary: a verb
    in one sentence and "backlog" in the next are two statements, not one instruction."""
    a, b = 0, size
    for bs, be in bounds:
        if be <= start:
            a = be
        elif bs >= end:
            b = bs
            break
        else:
            return None
    return a, b


def negated(unit: Unit, start: int, sentence_start: int, cfg: Cfg) -> bool:
    """A NEG word among the `neg_window` words before the match, within its sentence: "Do not skip this.
    Add it to backlog." negates nothing in the second sentence. `if not` / `or not` and a `not`/`no`
    followed by a state word ("not fixed") are conditions; inside a fence the window stops at the line."""
    text = unit.text
    floor = text.rfind("\n", 0, start) + 1 if unit.fence and cfg.fence_lines else 0
    if cfg.neg_sentence:
        floor = max(floor, sentence_start)
    lo = floor if cfg.neg_window is None else max(floor, start - 200)
    words = [w.lower() for w in WORD.findall(text[lo:start].replace("’", "'"))]
    first = 0 if cfg.neg_window is None else max(0, len(words) - cfg.neg_window)
    for i in range(first, len(words)):
        w = words[i]
        prev = words[i - 1] if i > 0 else ""
        nxt = words[i + 1] if i + 1 < len(words) else ""
        if w == "not" and prev in ("if", "or"):
            continue
        if cfg.state_is_condition and w in ("not", "no") and nxt in STATE_WORDS:
            continue
        if w in cfg.neg_words or (cfg.neg_words and (w.startswith("forbid") or (prev, w) in NEG_PAIRS)):
            return True
    return False


def g6_hits(unit: Unit, cfg: Cfg) -> List[Hit]:
    body = unit.raw if cfg.g6_raw else unit.text
    out: List[Hit] = []
    if cfg.g6_bad and G6_CONTEXT.search(body):
        for m in SOURCE_TOKEN.finditer(body):
            quoted = m.group(1) if m.group(1) is not None else m.group(2)
            tok = quoted if quoted is not None else m.group(3).rstrip(".:")
            if tok not in SOURCE_PLACEHOLDERS and not SOURCE_OK.fullmatch(tok):
                out.append(Hit("G6", "bad-source"))
                break
    if cfg.g6_legacy and LEGACY_SOURCE.search(unit.raw):
        out.append(Hit("G6", "legacy-source"))
    return out


def unit_hits(unit: Unit, cfg: Cfg) -> List[Hit]:
    text = unit.text
    lower = text.lower()
    hits: List[Hit] = []
    bounds: Optional[List[Tuple[int, int]]] = None
    for tier, name, tok, rx in compiled(cfg):
        if tok not in (lower if tok.islower() else text):
            continue
        m = rx.search(text)
        while m:
            if bounds is None:
                bounds = boundaries(unit, cfg)
            # Tier A phrases are mechanics that may span a full stop ("backlog.md. If missing, create"),
            # so only a Tier B match must sit inside one sentence.
            span = sentence_of(bounds, m.start(), m.end() if tier == "B" else m.start() + 1, len(text))
            cited = False
            if span is not None and (tier == "B" or cfg.cite_tier_a):
                lo, hi = (0, len(text)) if cfg.cite_scope == "unit" else span
                cited = cfg.cite.search(unit.raw, lo, hi) is not None
            if span is not None and not cited and not negated(unit, m.start(), span[0], cfg):
                hits.append(Hit(tier, name, span[0], span[1]))
                # One hit per rule per sentence: a later sentence may hold another, which a `unit`
                # allowlist key on this one must not excuse.
                m = rx.search(text, max(span[1], m.start() + 1))
                continue
            # Overlapping search: an excused match must not hide a later one that starts inside it.
            m = rx.search(text, m.start() + 1)
    return hits + g6_hits(unit, cfg)


def verdict_table_lines(lines: Sequence[str], icase: bool, exact: bool = True, every: bool = True) -> Set[int]:
    """Header rows with a cell that is exactly `Verdict` and one that is exactly `Exit`. A cell holding both
    words ("Driver exit / verdict") or a table with only a Verdict column is not the protocol's table."""
    out: Set[int] = set()
    for i, ln in enumerate(lines[:-1]):
        if ln.lstrip().startswith("|") and TABLE_SEP.match(lines[i + 1]):
            cells = {c.strip().strip("*`").strip() for c in ln.strip().strip("|").split("|")}
            if icase:
                cells = {c.lower() for c in cells}
                want = {"verdict", "exit"}
            else:
                want = {"Verdict", "Exit"}
            if exact:
                found = {w for w in want if w in cells}
            else:
                found = {w for w in want for c in cells if w in c}
            header = found == want if every else bool(found)
            if header:
                out.add(i + 1)
    return out


def scan_text(text: str, cfg: Cfg) -> Tuple[List[Unit], List[Flag]]:
    units = split_units(text, cfg)
    tables = (verdict_table_lines(text.split("\n"), cfg.table_icase, cfg.table_exact, cfg.table_all)
              if cfg.table_check else set())
    flags: List[Flag] = []
    for u in units:
        hits = unit_hits(u, cfg)
        if any(u.start <= t <= u.end for t in tables):
            hits.append(Hit(*TABLE_RULE))
        if hits:
            flags.append(Flag(u.start, tuple(hits), u.text, u.raw))
    return units, flags


def sections(text: str) -> Dict[str, Tuple[int, int]]:
    """Each heading's text -> (first line, last line) up to the next heading of the same or higher level.
    A fence closes only on its own opening run, so a ~~~ inside a ``` block and a ```python inside a ````
    block toggle nothing."""
    lines = text.split("\n")
    heads: List[Tuple[int, int, str]] = []
    fence: Optional[str] = None
    for n, ln in enumerate(lines, 1):
        s = ln.strip()
        if fence is not None:
            if fence_closes(s, fence):
                fence = None
            continue
        opener = fence_opening(s)
        if opener:
            fence = opener
            continue
        m = HEADING.match(ln)
        if m:
            heads.append((n, len(m.group(1)), m.group(2)))
    out: Dict[str, Tuple[int, int]] = {}
    for i, (n, level, title) in enumerate(heads):
        end = next((h[0] - 1 for h in heads[i + 1:] if h[1] <= level), len(lines))
        out.setdefault(title, (n, end))
    return out


def key_in_sentence(raw: str, key: str, hit: Hit) -> bool:
    """An occurrence of `key` overlaps the sentence that holds `hit`."""
    if hit.lo < 0:
        return False
    at = raw.find(key)
    while at >= 0:
        if at < hit.hi and at + len(key) > hit.lo:
            return True
        at = raw.find(key, at + 1)
    return False


def kept_hits(rel: str, text: str, flag: Flag, allowlist: Sequence[Allow], cfg: Cfg) -> Tuple[Hit, ...]:
    """The flag's hits the allowlist does not excuse. G6 hits are never excused; a `unit` key excuses only
    the hits in the sentence it sits in, so a second hand write added to that unit still flags."""
    kept: List[Hit] = []
    for h in flag.hits:
        excused = False
        for path, scope_name, key, _ in allowlist if h.tier != "G6" else ():
            if path != rel:
                continue
            if scope_name == "file":
                excused = True
            elif scope_name == "section":
                span = sections(text).get(key)
                excused = bool(span and span[0] <= flag.line <= span[1])
            elif scope_name == "unit":
                excused = key in flag.raw if cfg.allow_unit_wide else key_in_sentence(flag.raw, key, h)
            if excused:
                break
        if not excused:
            kept.append(h)
    return tuple(kept)


@dataclass(frozen=True)
class FileScan:
    units: List[Unit]
    raw_flags: List[Flag]
    flags: List[Flag]


def scan_file(rel: str, text: str, cfg: Cfg, allowlist: Sequence[Allow] = ALLOWLIST) -> FileScan:
    """The tree scan: every rule, then the allowlist. G2t calls this same function on a mutated text."""
    units, raw = scan_text(text, cfg)
    kept: List[Flag] = []
    for f in raw:
        hits = kept_hits(rel, text, f, allowlist, cfg)
        if hits:
            kept.append(replace(f, hits=hits))
    return FileScan(units, raw, kept)


class Tally:
    def __init__(self, echo: bool) -> None:
        self.passed = 0
        self.failed = 0
        self.echo = echo

    def ok(self, msg: str) -> None:
        self.passed += 1
        if self.echo:
            print(f"  PASS {msg}")

    def no(self, msg: str) -> None:
        self.failed += 1
        if self.echo:
            print(f"  FAIL {msg}")


OUT = Tally(echo=True)


def ok(msg: str) -> None:
    OUT.ok(msg)


def no(msg: str) -> None:
    OUT.no(msg)


def failures(check: Callable[[], None]) -> int:
    """The FAILs one verdict function reports, counted silently (the G2u checks)."""
    global OUT
    saved, OUT = OUT, Tally(echo=False)
    try:
        check()
        return OUT.failed
    finally:
        OUT = saved


REAL = Cfg(rules=tuple(("A", n, t, p) for n, t, p in TIER_A) + tuple(("B", n, t, p) for n, t, p in TIER_B))
ALL_RULES: List[Tuple[str, str]] = [(t, n) for t, n, _, _ in REAL.rules] + [TABLE_RULE, *G6_RULES]

# ---- G2 self-test: (the defect it catches, document, expected "tier:pattern" or None for clean) --------
FIXTURES: List[Tuple[str, str, Optional[str]]] = [
    # Tier A, one dedicated true positive each.
    ("a B-{N} row template with a citation nearby still hand-writes a row (citation never exempts Tier A)",
     "- [ ] `B-{N} | {file}:{line} | {title}` is the entry line (see `backlog-add`).", "A:b-n-pipe"),
    ("minting the next id by hand", "Assign the next free B-{N} to the entry.", "A:next-b-n"),
    ("a fenced hand-append line", "```\n- B-{N} {file}:{line} {title}\n```", "A:b-n-line"),
    ("a hand-append list item under an intro line (list items must start their own unit)",
     "Each entry is one line:\n- B-{N} {file}:{line} {title}", "A:b-n-line"),
    ("a dated process id makes every repeat a new entry",
     "If the run stops early, file `B-review-incomplete-<date>` with the reason.", "A:dated-process-id"),
    ("a hand-maintained Seen counter", "If it exists, increment `Seen` and update the date.", "A:increment-seen"),
    ("a fix table that appends rows itself", "| NEEDS_REVIEW | Add as OPEN with the finding text |",
     "A:add-as-open"),
    ("a fix table that deletes rows itself", "| FIXED | Remove row by fingerprint |",
     "A:remove-row-by-fingerprint"),
    ("deleting resolved entries instead of archiving them", "3. Delete resolved items.", "A:delete-resolved"),
    ("a lowercase hand delete of resolved entries", "3. delete resolved items.", "A:delete-resolved"),
    ("creating the backlog file by hand",
     "1. Read `memory/backlog.md`. If missing, create it from the template.", "A:create-if-missing"),
    ("a lowercase hand creation of the backlog file",
     "1. Read `memory/backlog.md`. if missing, create it.", "A:create-if-missing"),
    ("a slash command that files outside backlog-add",
     "Suggest `/backlog add PERF-D7: N+1 in the order list` for each finding.", "A:slash-backlog-add"),
    # Tier B, one dedicated true positive each.
    ("a hand write whose path is on the next line (lines must be joined)",
     "For each finding the run leaves open, record it in\n`memory/backlog.md` with its file and line.",
     "B:verb-before-backlog-md"),
    ("the adversarial boilerplate", "Persist to backlog if not fixed in this session.", "B:verb-to-backlog"),
    ("'if not' is a condition, not a negation", "If not, add it to backlog.", "B:verb-to-backlog"),
    ("quotes must pair within the line, never greedily across it",
     '{"a": 1} persist to backlog {"b": 2}', "B:verb-to-backlog"),
    ("the telemetry field `backlog-adds` is not a citation of the helper",
     "Count the `backlog-adds` and persist the rest to the backlog.", "B:verb-to-backlog"),
    ("a citation in the next list item does not excuse this one",
     "- If fix is larger, add to backlog with specific file:line.\n"
     "- Pre-existing issues elsewhere: see `drive-by-findings.md`.", "B:verb-to-backlog"),
    ("a citation in the previous sentence does not excuse this one",
     "Call `backlog-add` for BUG. Otherwise add to backlog by hand.", "B:verb-to-backlog"),
    ("a citation on another line of the same fence does not excuse this line",
     "```\n~/.zuvo/backlog-add --class CQ --conf 60 --source review --file a.py --line 1 --title t\n"
     "then append the row to memory/backlog.md by hand\n```", "B:verb-before-backlog-md"),
    ("a quoted instruction is still an instruction",
     'Then "append the row to memory/backlog.md".', "B:verb-before-backlog-md"),
    ("a negation far before the verb does not negate it",
     "Not every finding is fixed in this run; the remaining ones go straight to the backlog.",
     "B:verb-to-backlog"),
    ("'not fixed' is a condition, not a prohibition", "Items that are not fixed, add to backlog.",
     "B:verb-to-backlog"),
    ("'not fixed' before an arrow is a condition", "Anything not fixed → backlog", "B:arrow-backlog"),
    ("a negation ending the previous sentence negates nothing in this one",
     "Do not skip this. Add it to backlog with file:line.", "B:verb-to-backlog"),
    ("a negation in the previous sentence, beyond the word window, negates nothing (the review's example)",
     "Do not skip this step. Add it to backlog with file:line.", "B:verb-to-backlog"),
    ("a prohibition in the previous sentence does not excuse this hand write",
     "Never drop findings. Persist to backlog with file:line.", "B:verb-to-backlog"),
    ("an abbreviation's full stop does not split the instruction",
     "Add the finding (e.g. src/x.py) to the backlog.", "B:verb-to-backlog"),
    ("an abbreviation inside a hand write to the backlog path",
     "Persist the finding (e.g. with file:line) to memory/backlog.md.", "B:verb-before-backlog-md"),
    ("a quote holding only the destination hides the hand append",
     'Append the row to "memory/backlog.md" by hand.', "B:verb-before-backlog-md"),
    ("a quote holding only the destination hides the hand record",
     'Record the row in "memory/backlog.md" directly.', "B:verb-before-backlog-md"),
    ("a quote holding only the verb hides the hand write", 'Then "add" it to the backlog.', "B:verb-to-backlog"),
    ("a quoted destination after the verb hides the hand write", 'Add it to "the backlog" now.',
     "B:verb-to-backlog"),
    ("a quote holding the destination and extra words hides the hand append (path, 'the backlog file')",
     'Append it to "the backlog file memory/backlog.md".', "B:verb-before-backlog-md"),
    ("a quote holding 'the file' and the path hides the hand append",
     'Append the row to "the file memory/backlog.md" by hand.', "B:verb-before-backlog-md"),
    ("a quoted 'main backlog' hides the hand write", 'Add it to the "main backlog".', "B:verb-to-backlog"),
    ("a quoted 'the project backlog' hides the hand write",
     'Write the finding to "the project backlog".', "B:verb-to-backlog"),
    ("a quoted path with a trailing gloss hides the hand record",
     'Record it in "memory/backlog.md (the open file)".', "B:verb-before-backlog-md"),
    ("`etc.` ends the sentence, so the citation before it does not excuse the hand write after it",
     "Call `backlog-add` for BUG, SEC, etc. Otherwise add it to backlog by hand.", "B:verb-to-backlog"),
    ("a negation before `etc.` negates nothing after it",
     "Never guess etc. Add it to backlog.", "B:verb-to-backlog"),
    ("backlog used as a verb on a finding", "Backlog it with the file and line when the fix is larger.",
     "B:backlog-object"),
    ("an arrow routing a result to the backlog", "Below-A after the cap → WARN + per-file backlog.",
     "B:arrow-backlog"),
    ("adding a backlog item by hand", "Add a backlog item for the blocked tool.", "B:record-backlog-item"),
    ("reported and filed by hand", "Unfixed findings are reported and backlogged.", "B:and-backlogged"),
    ("a conditional hand write", "Backlog only if the user declines.", "B:backlog-only-if"),
    ("a second destination named beside the commit", "Record it in the commit body and the backlog.",
     "B:and-the-backlog"),
    ("a bold step label that means 'write the backlog'",
     "**Backlog:** unfixed out-of-scope items are kept for later.", "B:backlog-label"),
    ("a named entry per file", "Each skipped file gets a named backlog entry.", "B:named-backlog-item"),
    ("a skip that presumes a hand write", "Skip after backlog when the file cannot be fixed.",
     "B:after-backlog"),
    ("pushing findings through the backlog skill",
     "Push findings to `zuvo:backlog` when the flag is set.", "B:push-zuvo-backlog"),
    ("a skill restating the protocol's verdict table",
     "| Verdict | Exit | What you do |\n|---|---|---|\n| `ACCEPTED` | 0 | report it |",
     "B:restated-verdict-table"),
    ("a restated verdict table with a lowercase header",
     "| verdict | exit | next step |\n|---|---|---|\n| ok | 0 | report it |", "B:restated-verdict-table"),
    ("a source the CLI refuses",
     "Run `~/.zuvo/backlog-add --class CQ --conf 60 --source Review_Pass --file a.py --line 1 --title 't'`.",
     "G6:bad-source"),
    ("a double-quoted source the CLI refuses, in a fence",
     "```\n~/.zuvo/backlog-add --class CQ --conf 60 --file a.py --line 1 --title t --source \"Zuvo Review\"\n```",
     "G6:bad-source"),
    ("a legacy source token", "Source: `manual`", "G6:legacy-source"),
    ("a ```python line inside a ```` fence closes it early, so the prose after the real close is read as "
     "fenced (one sentence per line) and the hand write after a citation goes unflagged",
     "````md\n```python\nx = 1\n````\nCall `backlog-add` for BUG. Otherwise add it to backlog by hand.",
     "B:verb-to-backlog"),
    ("a ```python line inside a ```` fence closes it early, so a citation on another line of the fence "
     "excuses the fenced hand write",
     "````md\n```python\n~/.zuvo/backlog-add --class CQ --conf 60 --source review --file a.py --line 1 "
     "--title t\nthen append the row to memory/backlog.md by hand\n```\n````", "B:verb-before-backlog-md"),
    # True negatives, each named by the false positive it would be.
    ("a ```python line inside a ```` fence closing it early, so its one-line citation no longer excuses "
     "the sentence on that line",
     "````md\n```python\nx = 1\nCall `backlog-add` for BUG. Otherwise add it to backlog.\n```\n````", None),
    ("the pinned 'no backlog' phrase flagged as a hand write", "no cap, no backlog", None),
    ("a negation right before the verb flagged as a hand write", "never backlog it", None),
    ("a negated noun phrase flagged as a hand write", "Never a silent backlog row.", None),
    ("a quoted mention flagged as an instruction", 'This closes the "RECOMMENDED → backlog" reflex.', None),
    ("the adversarial driver's exit/verdict table flagged as the protocol's verdict table",
     "| Driver exit / verdict | Meaning |\n|---|---|\n| 0 / PASS | the lane answered |", None),
    ("a findings table with only a Verdict column flagged as the protocol's verdict table",
     "| Finding | Verdict |\n|---|---|\n| F1 | CONFIRMED |", None),
    ("a placeholder source flagged as invalid",
     "Use `--source drive-by:<skill>` for a file the run is not editing.", None),
    ("a command on an existing id flagged as minting one", "Run `fix B-<id>` once the change is merged.", None),
    ("a valid source in a backlog-add unit flagged as invalid",
     "`~/.zuvo/backlog-add --repo \"$R\" --class PROCESS --conf 90 --source review --target "
     "subject:review-gate --title 't'`", None),
    ("the canonical generic-write sentence flagged as a hand write",
     "Record it with `~/.zuvo/backlog-add --repo \"$R\" --class <C> --conf <N> --source <skill> --file \"$F\" "
     "--line <n> --anchor \"$A\" --title \"$T\"` (one call per finding; `backlog-protocol.md` "
     "\"Persisting a finding\"; `--anchor` is required on a BUG, SEC or DATA file record). The helper decides "
     "whether it reaches `memory/backlog.md` or only the findings ledger; report the B- or F-id it prints. "
     "On a non-zero exit act on the protocol's exit table; a finding still not persisted is listed under "
     "`NOT PERSISTED (<reason>)`, never appended by hand.", None),
    ("the canonical adversarial WARNING sentence flagged as a hand write",
     "**WARNING**: fix if localized (< 10 lines). Otherwise record it with `~/.zuvo/backlog-add --repo \"$R\" "
     "--class <C> --conf <N> --source <skill> --file \"$F\" --line <n> --anchor \"$A\" --title \"$T\"` "
     "(`--anchor` is required on a BUG, SEC or DATA file record; `backlog-protocol.md` \"Persisting a "
     "finding\").", None),
    ("the canonical pre-existing (drive-by) sentence flagged as a hand write",
     "\"Pre-existing\" is NOT a reason to skip a finding. If the issue is in a file you are already editing, "
     "fix it now. If not, record it with `~/.zuvo/backlog-add --repo \"$R\" --class <C> --conf <N> --source "
     "drive-by:<skill> --file \"$F\" --line <n> --anchor \"$A\" --title \"$T\"` (`--anchor` is required on a "
     "BUG, SEC or DATA file record; `drive-by-findings.md`). The adversarial review found a real problem: "
     "don't dismiss it just because it existed before your changes.", None),
    ("the canonical process-item sentence flagged as a hand write",
     "Record it as a process item: `~/.zuvo/backlog-add --repo \"$R\" --class PROCESS --conf 90 --source "
     "<skill> --target subject:<skill>-<gate> --title \"$T\"`, with `T` the gate's fixed title, the same words "
     "on every run (`backlog-protocol.md` \"Filing from a skill\"). It is kept in the findings ledger, not "
     "ticketed; name its F-id in the report, with this run's reason, which never goes in the title. A "
     "deferred decision uses `subject:<skill>-decision-<slug>`, the question as the title and both options "
     "in `--evidence \"$E\"`.", None),
    ("the canonical pentest rows flagged as a hand write or a bad source",
     "| A white-box pentest finding, traced to a file and line | `SEC` | `pentest` | `~/.zuvo/backlog-add "
     "--repo \"$PWD\" --class SEC --conf <N> --source pentest --file \"$F\" --line <n> --anchor \"$A\" "
     "--title \"PT<n>: $T\"`; the dimension again in the `PT<n>:` prefix |", None),
    ("the canonical closing-not-removing sentence flagged as a hand delete",
     "Do not call `backlog-add` for a finding this run fixed. An open backlog entry the run resolved is "
     "closed, never removed: tick it and append its resolution marker (`[FIXED <sha7>]`) as "
     "`backlog-protocol.md` \"How to Persist Findings\" step 3 says; the archive helper moves it "
     "(\"Archiving is done by the helper, never by hand\").", None),
    ("code-audit's Tier A closing rule flagged as a hand delete",
     "A Tier A score does not prove any one defect is gone: close only an entry whose cited code this run "
     "re-read and found fixed.", None),
]

# The allowlist's own self-test: (the defect it catches, document, `unit` key, expected or None).
ALLOW_FIXTURES: List[Tuple[str, str, str, Optional[str]]] = [
    ("a unit allowlist key excuses the whole unit, so a second hand write beside it goes unflagged",
     "The summary goes at the TOP, not only in the backlog. Add it to backlog by hand.",
     "goes at the TOP, not only in the backlog", "B:verb-to-backlog"),
    ("a unit allowlist key that no longer excuses its own sentence",
     "The summary goes at the TOP, not only in the backlog.", "goes at the TOP, not only in the backlog", None),
]
ALLOW_REL = "skills/x/SKILL.md"

STRUCTURAL: List[Tuple[str, Cfg]] = [
    ("negation-crosses-sentence", replace(REAL, neg_sentence=False)),
    ("abbreviations-end-sentences", replace(REAL, mask_abbrev=False)),
    ("quote-kept-only-with-both-halves", replace(REAL, quote_mode="both")),
    ("quote-kept-without-a-verb-before-it", replace(REAL, quote_mode="prior")),
    ("etc-masked-as-an-abbreviation", replace(REAL, abbreviation=ABBREVIATION_ETC)),
    ("unit-allowlist-unit-wide", replace(REAL, allow_unit_wide=True)),
    ("table-header-substring", replace(REAL, table_exact=False)),
    ("table-header-any-word", replace(REAL, table_all=False)),
    ("negation-window-unbounded", replace(REAL, neg_window=None)),
    ("negation-lexicon-empty", replace(REAL, neg_words=frozenset())),
    ("state-words-negate", replace(REAL, state_is_condition=False)),
    ("backlog-adds-guard-dropped", replace(REAL, cite=re.compile(CITE.pattern.replace("(?!s)", "")))),
    ("citation-unit-wide", replace(REAL, cite_scope="unit")),
    ("fence-exemptions-unit-wide", replace(REAL, fence_lines=False)),
    ("paragraph-level-split", replace(REAL, split_items=False)),
    ("quote-stripping-off", replace(REAL, quote_mode="off")),
    ("quote-stripping-greedy", replace(REAL, quote_mode="greedy")),
    ("quote-stripping-hides-instructions", replace(REAL, quote_mode="all")),
    ("wrapped-lines-not-joined", replace(REAL, join_lines=False)),
    ("citation-exempts-tier-a", replace(REAL, cite_tier_a=True)),
    ("table-header-case-sensitive", replace(REAL, table_icase=False)),
    ("g6-reads-quote-stripped-text", replace(REAL, g6_raw=False)),
    ("fence-closes-on-any-prefix", replace(REAL, fence_prefix=True)),
    ("retired-quote-wrap-sensitive", replace(REAL, retired_norm=False)),
    ("retired-quote-dash-sensitive", replace(REAL, retired_dash=False)),
    ("retired-quote-en-dash-not-folded", replace(REAL, retired_dashes=DASH_CHARS.replace("\u2013", ""))),
    ("retired-quote-double-hyphen-not-folded", replace(REAL, retired_runs=False)),
    ("retired-quote-dash-spacing-kept", replace(REAL, retired_dash_space=False)),
]

# (the defect it catches, text, retired quote, back in the text?): neither a reflow nor a dash swap may let a
# retired sentence back in, and a real rewording must still count as gone.
RETIRED_FIXTURES: List[Tuple[str, str, str, bool]] = [
    ("a retired quote wrapped across a line break is still back", "user-declined items remain\n  in `x`",
     "user-declined items remain in", True),
    ("a retired quote reworded is gone", "user-declined items are recorded", "user-declined items remain in", False),
    ("a retired quote whose em dash an editor swapped for a hyphen is still back",
     "is LOCAL telemetry - never stage it", "is LOCAL telemetry \u2014 never stage it", True),
    ("a retired quote whose em dash an editor swapped for an en dash is still back",
     "is LOCAL telemetry \u2013 never stage it", "is LOCAL telemetry \u2014 never stage it", True),
    ("a retired quote written with a hyphen is back when the text has an em dash",
     "per\u2014file backlog entry naming each", "per-file backlog entry naming each", True),
    ("a retired quote whose em dash an editor typed as `--` is still back",
     "is LOCAL telemetry -- never stage it", "is LOCAL telemetry \u2014 never stage it", True),
    ("a retired quote whose dash lost its spaces is still back",
     "is LOCAL telemetry\u2014never stage it", "is LOCAL telemetry \u2014 never stage it", True),
]
DASH_RUN = re.compile(r"-{2,}")
DASH_SPACING = re.compile(r"\s*-\s*")


def dash_fold(s: str, cfg: Cfg) -> str:
    """Every DASH_CHARS code point to `-`, a run of `-` (an ASCII `--`) to one, and the spacing around a dash
    to one ` - `, so `a\u2014b`, `a \u2014 b`, `a -- b` and `a - b` read the same."""
    s = s.translate({ord(c): "-" for c in cfg.retired_dashes})
    if cfg.retired_runs:
        s = DASH_RUN.sub("-", s)
    if cfg.retired_dash_space:
        s = DASH_SPACING.sub(" - ", s)
    return s


def retired_present(text: str, quote: str, cfg: Cfg) -> bool:
    if cfg.retired_norm:
        text, quote = " ".join(text.split()), " ".join(quote.split())
    if cfg.retired_dash:
        text, quote = dash_fold(text, cfg), dash_fold(quote, cfg)
    return quote in text


def fixture_names(doc: str, cfg: Cfg) -> Set[str]:
    return {f"{h.tier}:{h.name}" for f in scan_text(doc, cfg)[1] for h in f.hits}


def fixture_holds(doc: str, expect: Optional[str], cfg: Cfg) -> bool:
    names = fixture_names(doc, cfg)
    return not names if expect is None else expect in names


def allow_fixture_holds(doc: str, key: str, expect: Optional[str], cfg: Cfg) -> bool:
    scan = scan_file(ALLOW_REL, doc, cfg, [(ALLOW_REL, "unit", key, "fixture")])
    names = {f"{h.tier}:{h.name}" for f in scan.flags for h in f.hits}
    return not names if expect is None else expect in names


def all_fixtures_hold(cfg: Cfg) -> bool:
    return (all(fixture_holds(doc, e, cfg) for _, doc, e in FIXTURES)
            and all(retired_present(t, q, cfg) == back for _, t, q, back in RETIRED_FIXTURES)
            and all(allow_fixture_holds(doc, k, e, cfg) for _, doc, k, e in ALLOW_FIXTURES))


def without(rule: Tuple[str, str]) -> Cfg:
    if rule == TABLE_RULE:
        return replace(REAL, table_check=False)
    if rule == ("G6", "bad-source"):
        return replace(REAL, g6_bad=False)
    if rule == ("G6", "legacy-source"):
        return replace(REAL, g6_legacy=False)
    return replace(REAL, rules=tuple(r for r in REAL.rules if (r[0], r[1]) != rule))


def self_test() -> None:
    for why, doc, expect in FIXTURES:
        got = sorted(fixture_names(doc, REAL))
        if fixture_holds(doc, expect, REAL):
            ok(f"(G2) {'TP' if expect else 'TN'} {expect or 'clean'}: {why}")
        else:
            no(f"(G2) {'TP' if expect else 'TN'} {expect or 'clean'} got {got}: {why}")
    for why, doc, key, expect in ALLOW_FIXTURES:
        verdict = "TP" if expect else "TN"
        (ok if allow_fixture_holds(doc, key, expect, REAL) else no)(
            f"(G2) allowlist {verdict} {expect or 'clean'}: {why}")
    for why, text, quote, back in RETIRED_FIXTURES:
        (ok if retired_present(text, quote, REAL) == back else no)(f"(G2) retired quote: {why}")
    caught = 0
    for rule in ALL_RULES:
        label = f"{rule[0]}:{rule[1]}"
        tps = [doc for _, doc, e in FIXTURES if e == label]
        if not tps:
            no(f"(G2m) pattern without fixture: {label}")
            continue
        # The dedicated TP must go fully clean without the rule: the rule is the only thing catching it.
        if any(not fixture_names(doc, without(rule)) for doc in tps):
            caught += 1
            ok(f"(G2m) mutant {label} caught")
        else:
            no(f"(G2m) mutant {label} NOT caught: every TP naming it is still flagged without it")
    for name, cfg in STRUCTURAL:
        if not all_fixtures_hold(cfg):
            caught += 1
            ok(f"(G2m) mutant {name} caught")
        else:
            no(f"(G2m) mutant {name} NOT caught: it changes no fixture's outcome")
    want = len(ALL_RULES) + len(STRUCTURAL)
    if caught == want:
        ok(f"(G2m) {caught} caught mutants == {len(ALL_RULES)} patterns + {len(STRUCTURAL)} structural")
    else:
        no(f"(G2m) {caught} caught mutants, expected {want}")


def synthetic(n_flags: int, raw: str = "add it to backlog by hand") -> FileScan:
    units = [Unit(i + 1, i + 1, raw, raw, False) for i in range(max(n_flags, 1))]
    flags = [Flag(u.start, (Hit("B", "verb-to-backlog"),), u.text, u.raw) for u in units[:n_flags]]
    return FileScan(units, flags, flags)


def verdict_logic_checks() -> None:
    """G2u: each verdict function, fed a synthetic scan, must move the FAIL counter exactly as stated."""
    rel = "skills/x/SKILL.md"
    cases: List[Tuple[str, Callable[[], None], int]] = [
        ("every flagged unit in a file is a FAIL of its own", lambda: judge_file(rel, synthetic(2)), 2),
        ("a clean file adds no FAIL", lambda: judge_file(rel, synthetic(0)), 0),
        ("a unit allowlist key matching no unit is stale",
         lambda: check_allowlist_rot(rel, "x", synthetic(1), [(rel, "unit", "no such text", "r")]), 1),
        ("a unit allowlist key matching two units is stale",
         lambda: check_allowlist_rot(rel, "x", synthetic(2), [(rel, "unit", "add it", "r")]), 1),
        ("a unit allowlist key matching one flagged unit resolves",
         lambda: check_allowlist_rot(rel, "x", synthetic(1), [(rel, "unit", "add it", "r")]), 0),
        ("a section allowlist key whose heading is gone is stale",
         lambda: check_allowlist_rot(rel, "# Other\n", synthetic(1), [(rel, "section", "Gone", "r")]), 1),
        ("a retired quote back in its file fails",
         lambda: check_retired(rel, "then add it to backlog", {rel: ["add it to backlog"]}), 1),
        ("a retired quote wrapped across a line break still fails",
         lambda: check_retired(rel, "then add it\n  to backlog", {rel: ["add it to backlog"]}), 1),
        ("a retired quote that stays gone passes",
         lambda: check_retired(rel, "record it with backlog-add", {rel: ["add it to backlog"]}), 0),
    ]
    for why, check, want in cases:
        got = failures(check)
        (ok if got == want else no)(f"(G2u) {why}: {got} FAIL(s), expected {want}")
    heads = set(sections("```\n~~~\n# not a heading\n~~~\n```\n# Real\n"))
    (ok if heads == {"Real"} else no)(f"(G2u) a ~~~ inside a ``` fence toggles nothing: headings {sorted(heads)}")
    nested = set(sections("````\n```python\n# not a heading\n```\n````\n# Real\n"))
    (ok if nested == {"Real"} else no)(f"(G2u) a ```python inside a ```` fence closes it not: {sorted(nested)}")
    n_units = len(split_units("+ one\n+ two\n1) three\n2) four", REAL))
    (ok if n_units == 4 else no)(f"(G2u) `+` and `N)` items each start a unit: {n_units} of 4")


def check_config() -> None:
    for tier, name, tok, pattern in REAL.rules:
        spelled = re.sub(r"\\(.)", r"\1", pattern)
        if tok not in spelled and not (tok.islower() and tok in spelled.lower()):
            no(f"(G2) rule {tier}:{name}: its pre-filter literal {tok!r} is not spelled in its regex")
    for path, scope_name, key, reason in ALLOWLIST:
        if scope_name not in ("file", "section", "unit") or not reason:
            no(f"(G5) allowlist entry needs a scope of file|section|unit and a reason: {path} {key!r}")
        if scope_name == "file" and path not in FILE_SCOPE_ALLOWED:
            no(f"(G5) file-scope allowlist is reserved for {FILE_SCOPE_ALLOWED}: {path}")
        if scope_name == "section" and key in FORBIDDEN_SECTIONS:
            no(f"(G5) section {key!r} may never be allowlisted: {path}")


def check_anchors() -> None:
    try:
        doc = open(os.path.join(ROOT, PROTOCOL), encoding="utf-8").read()
    except OSError as exc:
        no(f"(G1) {PROTOCOL} unreadable: {exc}")
        return
    spans = sections(doc)
    persist = spans.get("Persisting a finding: backlog-add")
    body = "\n".join(doc.split("\n")[persist[0] - 1:persist[1]]) if persist else ""
    if "Never append a finding to `memory/backlog.md` by hand" in re.sub(r"\s+", " ", body):
        ok("(G1) 'Persisting a finding: backlog-add' forbids a hand append")
    else:
        no("(G1) '## Persisting a finding: backlog-add' is missing or no longer says "
           "\"Never append a finding to `memory/backlog.md` by hand\"")
    filing = spans.get("Filing from a skill")
    table_fmt = spans.get("Backlog Table Format")
    if filing and persist and table_fmt and persist[0] < filing[0] < table_fmt[0]:
        ok("(G1) '## Filing from a skill' sits between 'Persisting a finding' and 'Backlog Table Format'")
    else:
        no("(G1) '## Filing from a skill' is missing or not between '## Persisting a finding: backlog-add' "
           "and '## Backlog Table Format'")


def parse_only(expansion: Set[str]) -> Optional[List[str]]:
    if not ARGV:
        return None
    if ARGV[0] != "--only" or len(ARGV) < 2:
        print("usage: test-backlog-hand-append-prose.sh [--only PATH ...]", file=sys.stderr)
        sys.exit(2)
    out: List[str] = []
    for arg in ARGV[1:]:
        full = os.path.normpath(arg if os.path.isabs(arg) else os.path.join(ROOT, arg))
        rel = os.path.relpath(full, ROOT)
        if rel.startswith(".."):
            no(f"(G3) --only path is outside the repo: {arg}")
        elif not os.path.isfile(full):
            no(f"(G3) --only path does not exist: {arg}")
        elif rel not in expansion:
            no(f"(G3) --only path is outside the guard's scope {SCOPE_GLOBS}: {arg}")
        else:
            out.append(rel)
    return out


def read(rel: str) -> Optional[str]:
    try:
        return open(os.path.join(ROOT, rel), encoding="utf-8").read()
    except (OSError, UnicodeDecodeError) as exc:
        no(f"(G3) unreadable {rel}: {exc}")
        return None


def judge_file(rel: str, scan: FileScan) -> None:
    for f in scan.flags:
        h = f.hits[0]
        no(f"{rel}:{f.line} [{h.tier}:{h.name}] {f.text[:140]}")


def check_allowlist_rot(rel: str, text: str, scan: FileScan, allowlist: Sequence[Allow]) -> None:
    secs = sections(text)
    ab_flagged = [f for f in scan.raw_flags if any(h.tier != "G6" for h in f.hits)]
    for path, scope_name, key, _ in allowlist:
        if path != rel:
            continue
        if scope_name == "file":
            ok(f"(G5) file allowlist key resolves: {rel}")
        elif scope_name == "section":
            span = secs.get(key)
            if span and any(span[0] <= f.line <= span[1] for f in ab_flagged):
                ok(f"(G5) section allowlist key resolves and excuses a flag: {rel} '{key}'")
            else:
                no(f"(G5) stale allowlist key: {rel} section '{key}' is gone or holds no flagged unit")
        elif scope_name == "unit":
            matching = [u for u in scan.units if key in u.raw]
            flagged = [f for f in ab_flagged if key in f.raw]
            if len(matching) == 1 and flagged:
                ok(f"(G5) unit allowlist key matches exactly one flagged unit: {rel} {key[:60]!r}")
            else:
                no(f"(G5) stale allowlist key: {rel} {key[:60]!r} matches {len(matching)} unit(s), "
                   f"{len(flagged)} flagged")


def check_retired(rel: str, text: str, retired: Dict[str, List[str]]) -> None:
    for quote in retired.get(rel, []):
        if retired_present(text, quote, REAL):
            no(f"(G5) retired quote back in {rel}: {quote!r}")
        else:
            ok(f"(G5) retired quote absent from {rel}: {quote[:60]!r}")


def tree_mutation(expansion: List[str], cache: Dict[str, FileScan], texts: Dict[str, str]) -> None:
    allowlisted = {p for p, *_ in ALLOWLIST}
    line = "If fix is larger, add to backlog with specific file:line."
    for rel in expansion:
        if rel in allowlisted:
            continue
        text = texts.get(rel)
        if text is None:
            text = read(rel)
            if text is None:
                continue
            texts[rel] = text
        before = cache.get(rel) or scan_file(rel, text, REAL)
        if before.flags:
            continue
        after = scan_file(rel, text.rstrip("\n") + "\n\n" + line + "\n", REAL)
        new = [f for f in after.flags if line in f.raw]
        if len(after.flags) == 1 and len(new) == 1:
            ok(f"(G2t) tree-mutation caught {rel}")
        else:
            no(f"(G2t) tree mutation of {rel}: expected exactly one new flag, got {len(after.flags)}")
        return
    no("(G2t) no clean, non-allowlisted file to mutate")


def main() -> None:
    expansion = sorted({os.path.relpath(p, ROOT) for g in SCOPE_GLOBS for p in glob.glob(os.path.join(ROOT, g))})
    exp_set = set(expansion)
    only = parse_only(exp_set)
    self_test()
    verdict_logic_checks()
    check_config()
    check_anchors()
    targets = expansion if only is None else only
    cache: Dict[str, FileScan] = {}
    texts: Dict[str, str] = {}
    counts: Dict[str, int] = {}
    units_total = 0
    for rel in targets:
        text = read(rel)
        if text is None:
            continue
        texts[rel] = text
        scan = scan_file(rel, text, REAL)
        cache[rel] = scan
        units_total += len(scan.units)
        if only is not None and not scan.units:
            no(f"(G3) --only path yields no unit: {rel}")
        judge_file(rel, scan)
        check_allowlist_rot(rel, text, scan, ALLOWLIST)
        check_retired(rel, text, RETIRED_QUOTES)
        if scan.flags:
            counts[rel] = len(scan.flags)
    if only is None:
        for path in RETIRED_QUOTES:
            if path not in exp_set:
                no(f"(G5) RETIRED_QUOTES names a file outside the scope: {path}")
        for p in [p for p, *_ in ALLOWLIST if p not in exp_set]:
            no(f"(G5) stale allowlist key: {p} does not exist")
        if len(texts) == len(expansion) >= FILE_FLOOR:
            ok(f"(G3) scanned {len(texts)} files == the globs' expansion (floor {FILE_FLOOR})")
        else:
            no(f"(G3) scanned {len(texts)} of {len(expansion)} files (floor {FILE_FLOOR})")
        if units_total >= UNIT_FLOOR:
            ok(f"(G3) {units_total} units >= floor {UNIT_FLOOR}")
        else:
            no(f"(G3) {units_total} units < floor {UNIT_FLOOR}: the splitter or the globs lost text")
    tree_mutation(expansion, cache, texts)
    print(f"  units scanned: {units_total} in {len(texts)} files")
    for rel in sorted(counts):
        print(f"  flagged-units {rel} {counts[rel]}")
    print(f"  flagged total: {sum(counts.values())} units in {len(counts)} files")
    print(f"  runtime: {time.monotonic() - STARTED:.2f}s")
    print(f"RESULT: PASS={OUT.passed} FAIL={OUT.failed}")
    sys.exit(1 if OUT.failed else 0)


main()
PY
