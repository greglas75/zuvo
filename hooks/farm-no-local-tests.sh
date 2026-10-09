#!/usr/bin/env bash
# NOTHING RUNS ON THE LAPTOP — ENFORCED, NOT DOCUMENTED.
#
# The rule "send test suites to the farm" has existed in CLAUDE.md for months
# and nothing checked it, so it held exactly as well as good intentions do.
# Measured on the workstation 2026-08-29: 109 test processes, 421% CPU, load 34
# — vitest, jest and STRYKER (mutation testing, the heaviest thing we run) — all
# started with a bare `npx …`, none through `rt`. The farm was idle enough at
# the same moment to have taken every one of them.
#
# The cost is not only a slow Mac. A saturated workstation makes every agent on
# it slower, which produces more timeouts, which produces more local fallbacks.
# That loop is what a person experiences as "the farm doesn't work".
#
# So this is a PreToolUse gate on Bash: a command that starts a test runner
# outside `rt` is refused, with the corrected command in the message so the
# agent can simply run it. It is a redirect, not a wall.
#
# ── 2026-09-05: TWO defects fixed, both found the same way — by failing ───────
#
# 1. IT WAS NEVER REGISTERED. This file was written on 2026-08-29 and no entry
#    for it existed in ~/.claude/settings.json, so it had never executed once.
#    A guard that is not wired up is a comment.
#
# 2. IT ONLY KNEW JS. `RUNNERS` was vitest/jest/stryker/playwright plus npx and
#    `npm test`. The global rule it enforces says, verbatim: "This is not a
#    JS-only rule. Any test command qualifies: vitest, jest, playwright,
#    `node --test`, a bash harness, a Makefile target, pytest."
#    On 2026-09-05 an agent ran `bash tests/run-all.sh` — a bash harness, ~9
#    minutes — SIX times on this laptop, twice concurrently, killing two tasks
#    on memory exhaustion, while the farm reported 0/17 slots used and 95% idle
#    CPU. Every one of those commands passes the old matcher untouched.
#    So the matcher now covers what the rule covers, not what one stack does.
#
# WHAT IT DELIBERATELY DOES NOT BLOCK, because a gate that cries wolf gets
# disabled:
#   * anything already going through `rt`
#   * anything running ON a farm host (ssh … 'npx vitest …') — that IS the farm
#   * merely MENTIONING a runner (grep jest, cat a config, edit a file)
#   * a syntax check (`bash -n foo.sh`) — it parses, it does not run
#   * dependency installs (`npm ci`, `npm install`) — often needed locally, and
#     the farm provisions its own
#   * wrapper/release scripts (dev-push.sh, release.sh, ship). They run a suite
#     internally, but blocking a release adds friction to the one flow that must
#     not get more of it. Use `ZUVO_SKIP_TESTS=1` after an `rt` run instead.
#   * a single spec run for interactive debugging is still a suite: it goes to
#     the farm too, and `rt --light` makes that cheap
#   * TF_ALLOW_LOCAL=1 as a deliberate, visible escape hatch
set -uo pipefail

_input=$(cat 2>/dev/null) || exit 0
[ -n "$_input" ] || exit 0

# Hard opt-out for the gate itself (debugging the gate).
case "${FARM_HOOK_OFF:-}" in ?*) exit 0 ;; esac

# The command: jq when present (a fraction of python3's start-up, and this runs on EVERY Bash
# call), python3 otherwise.
if command -v jq >/dev/null 2>&1; then
  _cmd=$(printf '%s' "$_input" | jq -r '.tool_input.command // ""' 2>/dev/null) || exit 0
else
  _cmd=$(printf '%s' "$_input" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
print((d.get("tool_input") or {}).get("command","") or "")
' 2>/dev/null) || exit 0
fi
[ -n "$_cmd" ] || exit 0

# Explicit opt-out, and the farm-side execution path.  An opt-out is only
# accepted as a leading environment assignment for the whole command.  A raw
# substring match made `npm test # TF_ALLOW_LOCAL=1` and `echo TF_ALLOW_LOCAL=1;
# pytest` bypass the guard.
case "$_cmd" in
  TF_ALLOW_LOCAL=1\ *|RT_LOCAL_OK=1\ *)
    case "$_cmd" in
      *\$\(*|*\`*|*\&*|*\;*|*\|*|*$'\n'*)
        echo "BLOCKED: opt-out cannot contain shell substitutions or command separators" >&2
        exit 2
        ;;
      *) exit 0 ;;
    esac
    ;;
esac

# Fail OPEN when the farm client is not installed: refusing a test run on a box
# that has no `rt` would leave no way to run tests at all.
command -v rt >/dev/null 2>&1 || exit 0

# FAST PATH (2026-09-27) — skip the python3 matcher for commands it cannot refuse. Every refusal
# below needs one of these as a WORD in the command: a runner, a package or task runner, a shell,
# eval/source/`.`, python, or a `*.sh`/`*.bash` script. Quotes and backslashes are dropped first
# (shlex joins `v""itest` into `vitest`, so this must too), and the word boundary is ASCII
# [^A-Za-z0-9_] — looser than Python's Unicode \b, so this stays a SUPERSET of the matcher: it
# may send a harmless command on to python, never let a refusable one skip it.
# Adding a name to RUNNERS / PMS / TASK_SUBCMDS below means adding it here too.
# `tr`, not `${_cmd//[\"\'\\]/}`: that expansion is superlinear on macOS /bin/bash 3.2 (1.8 s for
# a 4 KB command, >25 s for 12 KB — review 2026-09-29); tr is one linear fork, taken only when
# there is a quote or backslash to drop.
case "$_cmd" in
  *[\"\'\\]*) _probe=$(printf '%s' "$_cmd" | tr -d "\"'\\\\") ;;
  *)          _probe=$_cmd ;;
esac
_fw='(^|[^A-Za-z0-9_])(vitest|jest|stryker|playwright|mocha|ava|cypress|pytest|phpunit|tsc|knip|biome|eslint|npx|bunx|dlx|npm|yarn|pnpm|bun|make|cargo|go|turbo|gradle|gradlew|mvn|dotnet|composer|nx|node|bash|sh|zsh|dash|eval|source)([^A-Za-z0-9_]|$)'
_fp='(^|[^A-Za-z0-9_])python'
_fs='\.(sh|bash)([^A-Za-z0-9_]|$)'
_fd='(^|[^A-Za-z0-9_./-])\.([^A-Za-z0-9_./-]|$)'
if ! [[ $_probe =~ $_fw || $_probe =~ $_fp || $_probe =~ $_fs || $_probe =~ $_fd ]]; then
  exit 0
fi

# A COMMAND WORD, NOT A SUBSTRING. `grep jest package.json` and `cat
# vitest.config.ts` must pass; only an actual invocation is refused. Split on
# the shell separators that start a new command and look at the head of each
# segment, skipping leading env assignments and `cd x &&` style prefixes.
_verdict=$(printf '%s' "$_cmd" | python3 -c '
import re, sys, os, shlex
import bisect


def _fail_closed(*_exc):
    """An internal error refuses instead of allowing: the fast path already saw a runner word."""
    sys.stdout.write("<unparseable command>\n")
    sys.stdout.flush()
    os._exit(0)


sys.excepthook = _fail_closed
if os.environ.get("FARM_HOOK_TEST_CRASH") == "1":
    raise RuntimeError("forced by the test suite; a crash can only refuse")

cmd = sys.stdin.read()

SHELLS = ("bash", "sh", "zsh", "dash", "ksh", "mksh")
UNQUOTE = str.maketrans("", "", "\"\x27\\")
RUNNER_WORD = re.compile(
    r"(?:^|[;&|\s])(vitest|jest|stryker|playwright|mocha|ava|cypress|pytest|phpunit|tsc|knip|biome|eslint)"
    r"(?:$|[;&|\s])")
PM_HEAD = re.compile(r"\b(?:npm|yarn|pnpm|bun)\b(?=\s)")
PM_TASK = re.compile(r"(?<=\s)(?:t|test|build|lint|typecheck|type-check|check|e2e|coverage)\b")
TR_HEAD = re.compile(r"\b(?:make|cargo|go|turbo|gradle|gradlew|mvn|dotnet|composer|nx)\b(?=\s)")
TR_TASK = re.compile(r"(?<=\s)(?:test|build|lint|check|typecheck|coverage|verify|package)\b")
SH_HEAD = re.compile(r"\b(?:" + "|".join(SHELLS) + r")\s+")
SH_TARGET = re.compile(r"(?:tests?|run-all|run-tests|check)\.(?:sh|bash)\b")


def _head_then_task(text, head, task):
    """A head word, whitespace, any arguments, whitespace, a task word, on one line of one command.
    The leftmost head per piece is enough, so this is linear where a nested regex backtracks."""
    for seg in re.split(r"[;&|\n]", text):
        h = head.search(seg)
        if h and task.search(seg, h.end() + 1):
            return True
    return False


def _shell_script(text):
    """A shell then a test-named script on the line its arguments start on; each line searched once."""
    for seg in re.split(r"[;&|]", text):
        done = 0
        for m in SH_HEAD.finditer(seg):
            if m.end() < done:
                continue
            eol = seg.find("\n", m.end())
            done = len(seg) if eol < 0 else eol
            if SH_TARGET.search(seg, m.end(), done):
                return True
    return False


def nested_has_suite(text):
    """Conservative check for commands executed by shell -c/heredoc; quotes and backslashes are
    dropped first, as the fast path drops them, because the shell joins `te\\st` back into `test`."""
    text = text.translate(UNQUOTE)
    if RUNNER_WORD.search(text):
        return True
    if _head_then_task(text, PM_HEAD, PM_TASK) or _head_then_task(text, TR_HEAD, TR_TASK):
        return True
    if re.search(r"\bnode\s+--test\b|\bpython3?\s+-m\s+(?:pytest|unittest)\b", text):
        return True
    return _shell_script(text)

# ONLY WHAT THE SHELL WOULD RUN OR EXPAND COUNTS. A heredoc body is data unless a shell reads it;
# single-quoted, ANSI-C quoted and comment text never expands; a backslash escapes; and $( ),
# backticks, $(( )) and $[ ] open live text again even inside double quotes or an unquoted body.
# One linear walk splits the command. The segment analysis below gets the command text with the
# bodies cut out but each opener line kept whole, plus every shell-fed body and live substitution.
# A heredoc ends at its delimiter alone on a line (after tabs only for `<<-`), else at end of input.
FED_HEADS = SHELLS + ("eval", "source", ".", "$SHELL", "${SHELL}")
WRAPPERS = {"env", "command", "builtin", "exec", "nohup", "sudo", "time", "nice", "timeout", "setsid",
            "stdbuf", "ionice", "xargs", "if", "then", "else", "elif", "do", "while", "until", "!", "{"}
SEG_SEP = re.compile(r"\$\(|[;&|()`]")
TOKEN_RE = re.compile(r"\S+")
REDIR_OP = re.compile(r"<<<|<<-?|<>|>>|>&|<&|>\||[<>]")
PIPE_RE = re.compile(r"\|")
PIPE_SHELL = re.compile(r"\b(?:" + "|".join(SHELLS) + r")\b|\$\{?SHELL\b")
SPAN_KINDS = ("sub", "bq", "arith", "arb")
OPERATOR = " \t\n;&|()<>"
FLAT = str.maketrans("()`", "   ")


def _head_word(s, tok):
    """Feed one token to a command-head state [pos, skip next, after option, verdict]: redirections and
    their targets, assignments, wrappers and option values are passed over; the next word decides."""
    if s[1]:
        s[1] = False
        return
    k = next((j for j, ch in enumerate(tok) if ch in "<>"), -1)
    if k >= 0:
        if tok[:k] in ("", "&") or tok[:k].isdigit():
            op = REDIR_OP.match(tok, k)
            s[1] = op is not None and op.end() == len(tok)
            return
        tok = tok[:k]
    w = tok.translate(UNQUOTE).rsplit("/", 1)[-1]
    if w in FED_HEADS:
        s[3] = True
    elif w in WRAPPERS or s[2] or "=" in w or (w and w[0] in "-0123456789"):
        s[2] = w.startswith("-") and "=" not in w
    else:
        s[3] = False


def _seg_scan(text, s, b):
    """Advance head state s over the tokens of text[s[0]:b]; each token is read once, so linear."""
    if s[3] is None:
        for m in TOKEN_RE.finditer(text, s[0], b):
            _head_word(s, m.group())
            if s[3] is not None:
                break
        s[0] = b
    return s[3]


def _fed_before(text, i, st, line):
    """Advance the command-head scan of this line to i: (did an earlier command feed a shell, the
    head state of the command at i, which a later word on the line can still decide)."""
    f = st["fed"]  # line start, scanned up to, an earlier command fed a shell, open head state
    if f[0] != line:
        f[:] = [line, line, False, [line, False, False, None]]
    for m in SEG_SEP.finditer(text, f[1], i):
        f[2] = f[2] or bool(_seg_scan(text, f[3], m.start()))
        f[3] = [m.end(), False, False, None]
    f[1] = max(f[1], i)
    _seg_scan(text, f[3], i)
    return f[2], f[3]


def _opener(text, i, st):
    """Queue the body of the `<<[-]WORD` at i for the next unquoted newline; return the index after WORD."""
    j, n = i + 2, len(text)
    dash = text.startswith("-", j)
    j += dash
    while j < n and text[j] in " \t":
        j += 1
    word, quoted = [], False
    while j < n and text[j] not in " \t\n;&|<>()":
        if text[j] in "\x27\"":
            close = text.find(text[j], j + 1)
            if close < 0:
                return i + 2
            word.append(text[j + 1:close])
            quoted, j = True, close + 1
            continue
        if text[j] == "\\":
            quoted, j = True, j + 1
        word.append(text[j:j + 1])
        j += 1
    if not "".join(word):
        return i + 2
    prior, head = _fed_before(text, i, st, st["line"])
    st["pending"].append(("".join(word), dash, quoted, prior, j, head))
    st["word"] = False
    return j


def _body_end(text, pos, word, dash):
    """Where a body starting at pos stops and parsing resumes; an unterminated one runs to the end."""
    n = len(text)
    if dash:
        m = re.compile("^\t*" + re.escape(word) + "$", re.M).search(text, pos)
        return (m.start(), min(m.end() + 1, n)) if m else (n, n)
    k = text.find("\n" + word + "\n", pos - 1)
    if k >= 0:
        return k + 1, k + len(word) + 2
    if text.endswith("\n" + word) and n - len(word) >= pos:
        return n - len(word), n
    return n, n


def _next_fed(text, j):
    """Is the first command after j, past blank and comment lines, a shell?"""
    n = len(text)
    while j < n:
        eol = text.find("\n", j)
        eol = n if eol < 0 else eol
        line = text[j:eol].strip()
        if line and not line.startswith("#"):
            sep = SEG_SEP.search(text, j, eol)
            return bool(_seg_scan(text, [j, False, False, None], sep.start() if sep else eol))
        j = eol + 1
    return False


def _pipe_targets(text, pend, nl, resume):
    """Per queued opener: is it piped to a shell later on its line, or (dangling |) after the bodies?"""
    pipes = [m.start() for m in PIPE_RE.finditer(text, pend[0][4], nl)]
    shells = [m.start() for m in PIPE_SHELL.finditer(text, pend[0][4], nl)]
    last = shells[-1] if shells else -1
    if pipes:
        rest = text[pipes[-1] + 1:nl].lstrip("&").strip()
        if (not rest or rest.startswith("#")) and _next_fed(text, resume):
            last = nl
    out = []
    for p in pend:
        k = bisect.bisect_left(pipes, p[4])
        out.append(k < len(pipes) and pipes[k] < last)
    return out


def _take_bodies(text, nl, st):
    """Cut the queued heredoc bodies that follow newline nl and tag each shell, quoted or unquoted."""
    pos, pend, cut = nl + 1, st["pending"], []
    _fed_before(text, nl, st, st["fed"][0])
    for word, dash, quoted, prior, _after, head in pend:
        stop, resume = _body_end(text, pos, word, dash)
        cut.append((text[pos:stop], quoted, prior or head[3] is True))
        pos = resume
    piped = _pipe_targets(text, pend, nl, pos)
    for k, (body, quoted, fed) in enumerate(cut):
        st["bodies"].append(("shell" if fed or piped[k] else "quoted" if quoted else "unquoted", body))
    st["parts"].append(text[st["seg"]:nl + 1])
    st["cut"] += pos - nl - 1
    st["seg"] = st["line"] = pos
    st["pending"], st["word"] = [], True
    return pos


def _push(stack, st, kind, start):
    stack.append([kind, start - st["cut"], 0, 0])  # kind, span start, nesting depth, open case count
    st["open"] += kind in SPAN_KINDS
    st["word"] = True


def _pop(stack, st, i):
    """Close the innermost state; an outermost expansion becomes a span of the command text."""
    kind, start = stack.pop()[:2]
    st["word"] = False
    st["open"] -= kind in SPAN_KINDS
    if kind in SPAN_KINDS and not st["open"]:
        st["spans"].append((start, i - st["cut"]))


def _expansion(text, i, stack, st, code):
    """Push the expansion opening at i; `${` in shell code keeps its quotes (parc). None if none."""
    for opener, kind in (("$((", "arith"), ("$(", "sub"), ("$[", "arb"), ("`", "bq"),
                         ("${", "parc" if code else "par")):
        if text.startswith(opener, i):
            _push(stack, st, kind, i + len(opener))
            return i + len(opener)
    return None


def _keyword(text, i, words):
    end = i + 4
    return text[i:end] in words and (end == len(text) or text[end] in OPERATOR)


def _cmd_step(text, i, stack, st):
    """One step in shell code: escapes, heredocs, closers, quotes and expansions."""
    c, top = text[i], stack[-1]
    if c == "\\":
        st["word"] = st["word"] and text.startswith("\n", i + 1)
        return i + 2
    if c == "\n" and st["pending"]:
        return _take_bodies(text, i, st)
    if text.startswith("<<<", i):
        st["word"] = True
        return i + 3
    if text.startswith("<<", i):
        return _opener(text, i, st)
    if (c == "`" and top[0] == "bq") or (c == ")" and top[0] == "sub" and not top[2] and not top[3]):
        _pop(stack, st, i)
        return i + 1
    if text.startswith("$\x27", i):
        _push(stack, st, "ansi", i + 2)
        return i + 2
    nxt = _expansion(text, i, stack, st, True)
    return _cmd_char(text, i, stack, st) if nxt is None else nxt


def _cmd_char(text, i, stack, st):
    """Quotes, comments, (( )), parens and case/esac; tracks whether the next char starts a word."""
    c, top, at_word = text[i], stack[-1], st["word"]
    st["word"] = c in OPERATOR
    if c in "\x27\"":
        _push(stack, st, "sq" if c == "\x27" else "dq", i + 1)
    elif c == "#" and at_word:
        _push(stack, st, "com", i + 1)
    elif at_word and text.startswith("((", i):
        _push(stack, st, "arith", i + 2)
        return i + 2
    elif c in "()" and top[0] == "sub":
        top[2] = max(0, top[2] + (1 if c == "(" else -1))
    elif at_word and _keyword(text, i, ("case", "esac")):
        top[3] = max(0, top[3] + (1 if text.startswith("case", i) else -1))
    return i + 1


def _arith_step(text, i, stack, st):
    """$(( )) and $[ ]: nesting, the closer and the expansions inside; `<<` is a shift here."""
    c, top = text[i], stack[-1]
    close = "))" if top[0] == "arith" else "]"
    if not top[2] and text.startswith(close, i):
        _pop(stack, st, i)
        return i + len(close)
    if c in "()[]":
        top[2] = max(0, top[2] + (1 if c in "([" else -1))
        return i + 1
    nxt = _expansion(text, i, stack, st, False)
    return i + 1 if nxt is None else nxt


def _text_step(text, i, stack, st):
    """Double quotes, unquoted heredoc text and ${...}: escapes, expansions and the closer. An unquoted
    ${...} (parc) still has quotes, but neither comments nor heredoc openers."""
    c, kind = text[i], stack[-1][0]
    if c == "\\":
        return i + 2
    if (c == "\"" and kind == "dq") or (c == "}" and kind in ("par", "parc")):
        _pop(stack, st, i)
        return i + 1
    if c == "\"" and kind in ("par", "parc"):
        _push(stack, st, "dq", i + 1)
        return i + 1
    if kind == "parc" and (c == "\x27" or text.startswith("$\x27", i)):
        skip = 1 if c == "\x27" else 2
        _push(stack, st, "sq" if skip == 1 else "ansi", i + skip)
        return i + skip
    nxt = _expansion(text, i, stack, st, kind == "parc")
    return i + 1 if nxt is None else nxt


def _quoted_step(text, i, stack, st):
    """Single quotes, ANSI-C quotes and comments: nothing expands, only the closer matters."""
    kind, c = stack[-1][0], text[i]
    if kind == "com":
        if c == "\n":
            stack.pop()
            return i
        return i + 1
    if c == "\\" and kind == "ansi":
        return i + 2
    if c == "\x27":
        _pop(stack, st, i)
    return i + 1


STEPS = {"cmd": _cmd_step, "sub": _cmd_step, "bq": _cmd_step, "arith": _arith_step, "arb": _arith_step,
         "dq": _text_step, "hd": _text_step, "par": _text_step, "parc": _text_step,
         "sq": _quoted_step, "ansi": _quoted_step, "com": _quoted_step}


def _scan(text, top):
    """Split text into command text (heredoc bodies cut out), tagged bodies and outermost live expansions."""
    st = {"parts": [], "seg": 0, "cut": 0, "line": 0, "pending": [], "bodies": [], "spans": [],
          "open": 0, "word": True, "fed": [-1, 0, False, None]}
    stack = [[top, 0, 0, 0]]
    i = 0
    while i < len(text):
        if text[i] == "\n":
            st["line"] = i + 1
        i = STEPS[stack[-1][0]](text, i, stack, st)
    out = "".join(st["parts"]) + text[st["seg"]:]
    first = next((f for f in stack if f[0] in SPAN_KINDS), None)
    if first:
        st["spans"].append((first[1], len(out)))
    return out, st["bodies"], [out[a:b] for a, b in st["spans"]]


def _live_suite(text, top="cmd", depth=0):
    """(refusal label or None, texts for the segment analysis). Shell-fed bodies and live substitutions
    are commands and get the whole analysis; past a nesting cap a body is checked whole, staying linear."""
    out, bodies, spans = _scan(text, top)
    texts = ([out] if top == "cmd" else []) + spans
    for kind, body in bodies:
        if kind == "quoted":
            continue
        if depth > 8:
            if nested_has_suite(body):
                return "heredoc <test command>", texts
            continue
        label, inner = _live_suite(body, "cmd" if kind == "shell" else "hd", depth + 1)
        if label or (kind == "shell" and nested_has_suite(body)):
            return label or "shell heredoc <test command>", texts
        texts += inner
    if any(nested_has_suite(s.translate(FLAT)) for s in spans):
        return ("heredoc substitution" if top == "hd" else "shell substitution") + " <test command>", texts
    return None, texts


_label, _texts = _live_suite(cmd)
if _label:
    print(_label)
    sys.exit(0)
cmd = "\n".join(_texts)
# Direct runner binaries: invoking one IS running a suite.
RUNNERS = {
    "vitest", "jest", "stryker", "playwright", "mocha", "ava", "cypress",
    "pytest", "phpunit", "tsc", "knip", "biome", "eslint",
}
# `<pm> run <script>`: only the script families the rule names (test/build/lint/typecheck).
RUN_SCRIPTS = ("t", "test", "build", "lint", "typecheck", "type-check", "check", "e2e", "coverage")
PMS = {"npm", "yarn", "pnpm", "bun"}
# Task runners whose first argument decides.
TASK_SUBCMDS = {
    "make":   ("test", "check", "build", "lint", "typecheck", "coverage"),
    "cargo":  ("test", "build", "clippy", "bench"),
    "go":     ("test", "build", "vet"),
    "turbo":  ("test", "build", "lint", "typecheck", "check"),
    "gradle": ("test", "build", "check"),
    "gradlew":("test", "build", "check"),
    "mvn":    ("test", "verify", "package"),
    "dotnet": ("test", "build"),
    "composer": ("test",),
    "nx":     ("test", "build", "lint", "e2e", "check"),
}

def is_run_script(name):
    """Match an actual package script, not a data-bearing name such as test-data."""
    return name in RUN_SCRIPTS or any(name.startswith(prefix + ":") for prefix in RUN_SCRIPTS)

def first_task(tokens):
    """Find a task after runner options without mistaking an option value for it."""
    value_options = {"--filter", "--prefix", "--workspace", "--cwd", "--dir", "-w", "-F", "-C"}
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token):
            i += 1
            continue
        if token in value_options and i + 1 < len(tokens):
            i += 2
            continue
        if token.startswith("-"):
            i += 1
            continue
        return token, i
    return "", -1

def split_segments(text):
    """Tokenize shell separators while retaining quoted arguments as one token."""
    try:
        lexer = shlex.shlex(text, posix=True, punctuation_chars=";&|\n()")
        lexer.whitespace = " \t\r"
        lexer.whitespace_split = True
        lexer.commenters = ""
        tokens = list(lexer)
    except ValueError:
        return [part.strip().split() for part in re.split(r"(?:&&|\|\||[;|&]|\n)", text) if part.strip()]
    segments, current = [], []
    for token in tokens:
        # shlex glues adjacent punctuation (`))` + newline is one token): all-punctuation separates
        if token and set(token) <= set(";&|\n()"):
            if current:
                segments.append(current)
                current = []
        else:
            current.append(token)
    if current:
        segments.append(current)
    return segments

def looks_like_test_script(path):
    """A bash/sh harness. The rule names `a bash harness` explicitly, and it is what the
    2026-09-05 incident actually ran — six times, ~9 minutes each."""
    base = path.rsplit("/", 1)[-1]
    if re.search(r"(^|/)(tests?|spec|e2e)/", path):
        return True
    if re.match(r"^(test|spec|run-all|run-tests|check)[-_.]", base):
        return True
    if re.search(r"[-_.](test|tests|spec|suite)\.(sh|bash)$", base):
        return True
    if base in ("run-all.sh", "run-tests.sh", "test.sh", "tests.sh", "check.sh"):
        return True
    return False

# A BACKSLASH-NEWLINE IS ONE COMMAND, NOT TWO. Splitting on the raw newline turned the
# continuation of
#     git add a.md b.md \\
#         tests/hooks/x.sh
# into its own segment whose FIRST WORD is the test path — so the guard blocked a `git add`
# (2026-09-05). Naming a file is not running it, and a guard that cries wolf on staging is a
# guard people learn to route around.
cmd = re.sub(r"\\\n", " ", cmd)

for words in split_segments(cmd):
    i = 0
    # skip env assignments (FOO=bar)
    while i < len(words) and ("=" in words[i] and not words[i].startswith("-")):
        i += 1
    head = words[i:]
    if not head:
        continue
    w0 = head[0].rsplit("/", 1)[-1]

    # already on the farm
    if w0 in ("rt", "tf-run.sh", "tf-submit.sh"):
        continue
    # transparent prefixes — look past them (and past the argument cd/timeout consume)
    while w0 in ("cd", "time", "env", "nohup", "setsid", "timeout", "exec", "sudo", "command", "nice", "if", "then", "else", "elif", "do", "while", "until", "!"):
        if w0 == "env":
            head = head[1:]
            while head and (("=" in head[0] and not head[0].startswith("-")) or head[0].startswith("-")):
                if head[0] in ("-u", "--unset", "-C", "--chdir") and len(head) > 1:
                    head = head[2:]
                else:
                    head = head[1:]
        elif w0 == "cd":
            head = head[1:]
            while head and head[0].startswith("-"):
                head = head[1:]
            if head:
                head = head[1:]
        elif w0 == "timeout":
            head = head[1:]
            while head and head[0].startswith("-"):
                # -s SIGNAL takes one value; --kill-after accepts =VALUE.
                if head[0] in ("-s", "--signal", "--kill-after") and len(head) > 1:
                    head = head[2:]
                else:
                    head = head[1:]
            if head:
                head = head[1:]
        elif w0 == "sudo":
            head = head[1:]
            while head and head[0].startswith("-"):
                if head[0] in ("-u", "-g", "-C", "--user", "--group", "--chdir") and len(head) > 1:
                    head = head[2:]
                else:
                    head = head[1:]
        elif w0 == "nice":
            head = head[1:]
            while head and head[0].startswith("-"):
                if head[0] in ("-n", "--adjustment") and len(head) > 1:
                    head = head[2:]
                else:
                    head = head[1:]
        elif w0 == "time":
            head = head[1:]
            while head and head[0].startswith("-"):
                head = head[1:]
        else:
            head = head[1:]
            if head and head[0] == "--":
                head = head[1:]
        if not head:
            break
        w0 = head[0].rsplit("/", 1)[-1]
    if not head:
        continue
    if w0 in ("rt", "tf-run.sh", "tf-submit.sh"):
        continue
    rest = head[1:]

    # Shell flags may be clustered (`bash -ec ...`), so inspect short-option
    # bundles rather than matching only a standalone token.
    _flag_limit = next((idx for idx, arg in enumerate(rest) if not arg.startswith("-")), len(rest))
    _shell_flags = rest[:_flag_limit]

    def shell_flag_index(flag):
        short = flag[1:]
        for idx, arg in enumerate(_shell_flags):
            if arg == flag or (arg.startswith("-") and not arg.startswith("--") and short in arg[1:]):
                return idx
        return -1

    # `bash -n` parses without running — never a suite, unless the same bundle
    # also contains -c (which executes the following command string).
    if w0 in SHELLS and shell_flag_index("-n") >= 0 and shell_flag_index("-c") < 0:
        continue

    if w0 in SHELLS and shell_flag_index("-c") >= 0:
        j = shell_flag_index("-c") + 1
        nested = " ".join(rest[j:])
        if nested_has_suite(nested):
            print(f"{w0} -c <test command>"); sys.exit(0)

    # 1. a bash/sh harness, or a directly-executed test script
    if w0 in SHELLS:
        # a here-string may be attached to its word: `bash <<<"npm test"` is one token
        hs = next((k for k, a in enumerate(rest) if a.startswith("<<<")), -1)
        if hs >= 0 and nested_has_suite(" ".join([rest[hs][3:]] + rest[hs + 1:])):
            print(f"{w0} <<< <test command>"); sys.exit(0)
        target = next((a for a in rest if not a.startswith("-")), "")
        if target and looks_like_test_script(target):
            print(f"{w0} {target}"); sys.exit(0)
    elif w0 in ("eval", "source", "."):
        nested = " ".join(rest)
        if nested_has_suite(nested) or any(looks_like_test_script(a) for a in rest):
            print(f"{w0} <test command>"); sys.exit(0)
    elif w0.endswith((".sh", ".bash")) and looks_like_test_script(head[0]):
        print(head[0]); sys.exit(0)

    # 2. a runner binary, directly or via npx/dlx
    if w0 in ("npx", "bunx", "dlx"):
        first = next((a for a in rest if not a.startswith("-")), "")
        b = first.rsplit("/", 1)[-1].split("@", 1)[0]
        if b in RUNNERS:
            print(f"{w0} {first}"); sys.exit(0)
        if b in TASK_SUBCMDS:
            sub = rest[rest.index(first) + 1] if rest.index(first) + 1 < len(rest) else ""
            if sub in TASK_SUBCMDS[b]:
                print(f"{w0} {first} {sub}"); sys.exit(0)
        continue
    if w0 in RUNNERS:
        print(w0); sys.exit(0)

    # 3. package-manager scripts. `npm ci` / `npm install` are NOT this.
    if w0 in PMS:
        if not rest:
            continue
        # npm/pnpm/yarn accept global options before the subcommand.  Skip only
        # options whose values are unambiguous; otherwise a command such as
        # `pnpm --filter app test` would hide the real `test` token.
        pm = list(rest)
        j = 0
        while j < len(pm) and pm[j].startswith("-"):
            if pm[j] in ("--filter", "--prefix", "--workspace", "--cwd", "--dir", "-w", "-F", "-C") and j + 1 < len(pm):
                j += 2
            else:
                j += 1
        if j >= len(pm):
            continue
        sub = pm[j]
        args = pm[j + 1:]
        # dependency management and read-only queries are not a suite run; an unknown subcommand
        # WITH a flag is still treated as ambiguous below (`npm -g outdated` used to be refused)
        if sub in ("ci", "install", "i", "add", "remove", "uninstall", "rm", "un", "update", "up", "upgrade",
                   "link", "unlink", "exec", "dlx", "why", "ls", "list", "ll", "la", "view", "info", "show",
                   "v", "outdated", "root", "bin", "prefix", "search", "explain", "fund", "audit", "doctor",
                   "cache", "config", "help"):
            if sub in ("exec", "dlx"):
                nxt = next((a for a in args if a != "--" and not a.startswith("-")), "")
                nxt = nxt.rsplit("/", 1)[-1].split("@", 1)[0]
                if nxt in RUNNERS:
                    print(f"{w0} {sub} {nxt}"); sys.exit(0)
            continue
        if is_run_script(sub):
            print(f"{w0} {sub}"); sys.exit(0)
        if sub == "run":
            script = next((a for a in args if not a.startswith("-")), "")
            if is_run_script(script):
                print(f"{w0} run {script}"); sys.exit(0)
        if sub in ("workspace", "--workspace") and any(is_run_script(a) or a.rsplit("/", 1)[-1].split("@", 1)[0] in RUNNERS for a in args):
            print(f"{w0} workspace <test command>"); sys.exit(0)
        if sub.rsplit("/", 1)[-1] in RUNNERS:
            print(f"{w0} {sub}"); sys.exit(0)
        if any(a.startswith("-") for a in rest):
            print(f"{w0} <ambiguous package-manager command>"); sys.exit(0)
        continue

    # 4. task runners decided by their first subcommand
    if w0 in TASK_SUBCMDS:
        sub, sub_index = first_task(rest)
        if sub in TASK_SUBCMDS[w0]:
            print(f"{w0} {sub}"); sys.exit(0)
        if w0 == "turbo" and sub == "run":
            task, _ = first_task(rest[sub_index + 1:])
            if task in TASK_SUBCMDS[w0]:
                print(f"{w0} run {task}"); sys.exit(0)
        if any(a.startswith("-") for a in rest):
            print(f"{w0} <ambiguous task-runner command>"); sys.exit(0)
        continue

    # 5. `node --test`, `python -m pytest`
    if w0 in ("node",) and "--test" in rest:
        print("node --test"); sys.exit(0)
    if re.match(r"^python(\d+(?:\.\d+)?)?$", w0) and "-m" in rest:
        for j, arg in enumerate(rest):
            if arg == "-m" and j + 1 < len(rest) and rest[j + 1].split(".")[0] in ("pytest", "unittest"):
                print(f"{w0} -m {rest[j+1]}"); sys.exit(0)
' 2>/dev/null) || exit 0

[ -n "$_verdict" ] || exit 0

# THE MESSAGE CARRIES THE FIX. A refusal that only says "no" costs the agent a
# round trip to work out what to do; one that hands back the corrected command
# costs nothing and gets followed.
{
  if [ "$_verdict" = "<unparseable command>" ]; then
    echo "BLOCKED: the farm guard could not parse this command, and it names a test runner."
  else
    echo "BLOCKED: '$_verdict' would run the suite on this laptop."
  fi
  echo
  echo "The farm exists for exactly this. A saturated Mac slows every agent on it,"
  echo "which causes more farm timeouts, which causes more local fallbacks — that"
  echo "loop is what looks like 'the farm is broken'. Measured 2026-09-05: six full"
  echo "local suite runs, two concurrent, two background tasks killed on memory"
  echo "exhaustion — while the farm sat at 0/17 slots and 95% idle CPU."
  echo
  echo "Run it on the farm instead — same command, prefixed:"
  echo "    rt --light <your command>      # unit tests, type-check, lint, build"
  echo "    rt <your command>              # anything needing postgres/redis"
  echo
  echo "Farm noise (a 483s timeout, 'ssh 255') is a RETRY, not a reason to go local."
  echo
  echo "If this genuinely must run locally (farm unreachable, debugging the farm"
  echo "itself), say so explicitly with TF_ALLOW_LOCAL=1 in front of the command."
} >&2
exit 2
