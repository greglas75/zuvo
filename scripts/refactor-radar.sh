#!/usr/bin/env bash
#
# refactor-radar.sh — deterministic ranking of refactor candidates for ANY git repo.
#
# Why a script and not a prompt: the same ranking was hand-derived six times in one
# session of one repo, each time from scratch and each time with a different mistake
# (raw churn instead of fix-churn, max-CC instead of ΣCC, files already in flight, a
# facade measured without its satellites). A ranking nobody can reproduce is an opinion.
# This script produces the SAME table for the SAME snapshot, records the snapshot so the
# next run can tell a persistent hotspot from a one-week burst, and hands zuvo:refactor a
# queue file in its batch format. The LLM's job starts AFTER this script: validate the
# top of the list against the code (G1-G5 in skills/refactor-radar/SKILL.md), classify,
# write the orders.
#
# Signals (all per MODULE FAMILY = facade + its split-off satellites, never per file):
#   ΣCC      sum of cyclomatic complexity over ALL functions (max-CC has a flat
#            distribution — P80 ≈ 14 in a 5k-file repo — and hides a file of 74 small
#            functions; the sum does not)
#   fix      commits whose subject starts with fix (conventional commits) that touched
#            the family in the window — bug-driven churn. Raw churn is dominated by
#            `refactor:`/`test:` commits and by facades that every fix passes through.
#   K        criticality of the path, declared in the manifest (5 / 3 / 1), never inferred
#            from churn: low churn in an untouched area measures lack of attention.
#   R        persistence: 1.0 when the family was in the previous snapshot's top list,
#            0.6 on first appearance (a temporary activity spike is not debt)
#   fan_in   importers of the family (risk), tests LOC ratio (testability), LOC (effort)
#
#   score = ΣCC × (1+fix)^0.5 × K × R ÷ ((1 + fan_in/20) × testability × effort^0.3)
#
# Exclusions (reported, never silent): files touched by a worktree diff, families whose
# stem appears in a worktree/branch NAME (a `refactor/<stem>-split` worktree with zero
# commits is still someone's job), open PRs (gh / Bitbucket when reachable), and
# families touched by a `refactor:` commit within --fresh-days (their churn is the
# refactor itself).
#
# Usage:
#   refactor-radar.sh [--repo DIR] [--ref REF] [--top N] [--min-cc N] [--since DAYS]
#                     [--fresh-days DAYS] [--engine builtin|codesift] [--config FILE]
#                     [--json FILE] [--queue FILE] [--history DIR] [--busy-file FILE]
#                     [--no-remote] [--mode refactor|tests] [--quiet]
#
#   --ref        analyse this tree (default: HEAD of the working tree; the tree must be
#                clean for --ref to mean anything — a dirty tree is reported)
#   --min-cc     ΣCC floor; default = P80 of the population (self-calibrating per repo)
#   --engine     builtin = regex CC estimator (zero deps, any ref, TS/JS/PHP/Kotlin/Python);
#                codesift = `codesift complexity` JSON (needs the CLI + an index of the tree)
#   --history    directory of snapshots; enables R (persistence) and writes a new snapshot
#   --queue      write a zuvo:refactor batch queue (`- [ ] path | TYPE | Score: 0.NN`)
#   --busy-file  extra newline-separated list of busy paths/stems (CI, tests, hand-offs)
#   --mode tests rank by MISSING coverage instead (ΣCC × √fix × K × (1 − cov))
#
# Manifest (optional): <repo>/.radar.json or <repo>/zuvo/radar.json — keys:
#   noise[]     extra path regexes to exclude          critical[] {pattern, k} → K (first match wins)
#   k_default   K for families no pattern matches (default 3)
#   ext[]       source extensions (default ts tsx js jsx mjs py php kt)
#   since_days, fresh_days, top, min_cc, ref, history_dir, remote ("gh"|"bb"|"none"),
#   bb_repo ("owner/slug"), bb_user (Atlassian e-mail; token from keychain `bitbucket-api-token`)
#
# Output: stderr = progress + exclusion counts; stdout = the table (or nothing with --quiet).
# Exit: 0 ok | 2 usage / engine unavailable | 3 not a git repo
#
# Requires: git, python3. bash 3.2-compatible (no mapfile, no associative arrays).
set -uo pipefail

REPO=""; REF=""; TOP=""; MIN_CC=""; SINCE=""; FRESH=""; ENGINE=""; CONFIG=""
JSON_OUT=""; QUEUE_OUT=""; HISTORY=""; BUSY_FILE=""; NO_REMOTE=0; MODE="refactor"; QUIET=0
usage() { sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --top) TOP="$2"; shift 2 ;;
    --min-cc) MIN_CC="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --fresh-days) FRESH="$2"; shift 2 ;;
    --engine) ENGINE="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --json) JSON_OUT="$2"; shift 2 ;;
    --queue) QUEUE_OUT="$2"; shift 2 ;;
    --history) HISTORY="$2"; shift 2 ;;
    --busy-file) BUSY_FILE="$2"; shift 2 ;;
    --no-remote) NO_REMOTE=1; shift ;;
    --mode) MODE="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "refactor-radar: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$MODE" in refactor|tests) ;; *) echo "refactor-radar: --mode must be refactor|tests" >&2; exit 2 ;; esac
case "${ENGINE:-builtin}" in builtin|codesift) ;; *) echo "refactor-radar: --engine must be builtin|codesift" >&2; exit 2 ;; esac

ROOT="$(git -C "${REPO:-.}" rev-parse --show-toplevel 2>/dev/null)" || { echo "refactor-radar: not a git repo: ${REPO:-.}" >&2; exit 3; }
WORK="$(mktemp -d)" || { echo "refactor-radar: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT INT TERM

# --- manifest -------------------------------------------------------------------
if [ -z "$CONFIG" ]; then
  for c in "$ROOT/.radar.json" "$ROOT/zuvo/radar.json"; do [ -f "$c" ] && { CONFIG="$c"; break; }; done
fi
[ -n "$CONFIG" ] && [ ! -f "$CONFIG" ] && { echo "refactor-radar: config not found: $CONFIG" >&2; exit 2; }

# --- resolve ref + dirty state ----------------------------------------------------
# Manifest values fill in only what the command line left empty (CLI wins).
eval "$(python3 - "$CONFIG" <<'PY'
import json,sys,shlex
cfg={}
if sys.argv[1]:
    cfg=json.load(open(sys.argv[1]))
def emit(k,v):
    if v is None: return
    print("CFG_%s=%s" % (k.upper(), shlex.quote(str(v))))
for k in ("since_days","fresh_days","top","min_cc","ref","history_dir","remote","bb_repo","bb_user","engine"):
    emit(k,cfg.get(k))
PY
)"
REF="${REF:-${CFG_REF:-HEAD}}"; TOP="${TOP:-${CFG_TOP:-50}}"; SINCE="${SINCE:-${CFG_SINCE_DAYS:-180}}"
FRESH="${FRESH:-${CFG_FRESH_DAYS:-30}}"; ENGINE="${ENGINE:-${CFG_ENGINE:-builtin}}"
HISTORY="${HISTORY:-${CFG_HISTORY_DIR:-}}"; REMOTE="${CFG_REMOTE:-auto}"
MIN_CC="${MIN_CC:-${CFG_MIN_CC:-}}"
SHA="$(git -C "$ROOT" rev-parse "$REF" 2>/dev/null)" || { echo "refactor-radar: unknown ref: $REF" >&2; exit 2; }
DIRTY=0
if [ "$REF" = "HEAD" ] && [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]; then DIRTY=1; fi
[ "$QUIET" = 1 ] || echo "→ radar: $ROOT @ ${SHA:0:9} (${REF}) engine=$ENGINE window=${SINCE}d fresh=${FRESH}d$([ "$DIRTY" = 1 ] && echo '  [DIRTY working tree — ΣCC read from disk, churn from git; commit or use --ref]')" >&2

# --- source listing from the ref (not the working tree, unless HEAD+dirty) --------------
git -C "$ROOT" ls-tree -r --name-only "$SHA" > "$WORK/files.txt"

# --- churn: ONE pass over the log, commit type from the conventional prefix -------------
# %x00 keeps the subject line distinguishable from a path that happens to look like one.
git -C "$ROOT" log --since="${SINCE} days ago" --format='%x00%ct%x00%s' --name-only "$SHA" > "$WORK/log.txt" 2>/dev/null || : > "$WORK/log.txt"

# --- busy set: worktree DIFFS + worktree/branch NAMES + open PRs -----------------------
: > "$WORK/busy-paths.txt"; : > "$WORK/busy-names.txt"
git -C "$ROOT" worktree list --porcelain 2>/dev/null \
  | awk '/^worktree /{w=$2} /^HEAD /{h=$2} /^branch /{b=$2; print w"\t"h"\t"b}' \
  | while IFS="$(printf '\t')" read -r w h b; do
      printf '%s\n%s\n' "$(basename "$w")" "${b#refs/heads/}" >> "$WORK/busy-names.txt"
      [ "$h" = "$SHA" ] && continue
      mb="$(git -C "$ROOT" merge-base "$SHA" "$h" 2>/dev/null)" || continue
      git -C "$ROOT" diff --name-only "$mb" "$h" 2>/dev/null >> "$WORK/busy-paths.txt" || true
    done
git -C "$ROOT" branch --format='%(refname:short)' 2>/dev/null >> "$WORK/busy-names.txt"
if [ "$NO_REMOTE" = 0 ] && [ "$REMOTE" != "none" ]; then
  if { [ "$REMOTE" = "gh" ] || [ "$REMOTE" = "auto" ]; } && command -v gh >/dev/null 2>&1; then
    gh pr list --state open --limit 100 --json headRefName,files \
      --jq '.[] | (.headRefName), (.files[]?.path)' 2>/dev/null > "$WORK/pr.txt" || : > "$WORK/pr.txt"
    [ -s "$WORK/pr.txt" ] && cat "$WORK/pr.txt" >> "$WORK/busy-names.txt"
  fi
  if { [ "$REMOTE" = "bb" ] || [ "$REMOTE" = "auto" ]; } && [ -n "${CFG_BB_REPO:-}" ]; then
    TOK="$(security find-generic-password -s bitbucket-api-token -w 2>/dev/null || true)"
    if [ -n "$TOK" ]; then
      curl -s -u "${CFG_BB_USER:-}:${TOK}" \
        "https://api.bitbucket.org/2.0/repositories/${CFG_BB_REPO}/pullrequests?state=OPEN&pagelen=50" \
        | python3 -c "import sys,json;[print(v['source']['branch']['name']) for v in json.load(sys.stdin).get('values',[])]" \
        >> "$WORK/busy-names.txt" 2>/dev/null || true
    else
      [ "$QUIET" = 1 ] || echo "  WARN: bb_repo set but no bitbucket-api-token in keychain — open PRs NOT excluded" >&2
    fi
  fi
fi
[ -n "$BUSY_FILE" ] && [ -f "$BUSY_FILE" ] && cat "$BUSY_FILE" >> "$WORK/busy-names.txt"

# --- complexity engine -------------------------------------------------------------
: > "$WORK/cc.json"
if [ "$ENGINE" = "codesift" ]; then
  command -v codesift >/dev/null 2>&1 || { echo "refactor-radar: --engine codesift but no codesift CLI on PATH" >&2; exit 2; }
  RID="$(codesift repos 2>/dev/null | tr -d ' "' | tr ',' '\n' | grep -E "@$(basename "$ROOT")\$" | head -1 || true)"
  [ -n "$RID" ] || { echo "refactor-radar: repo '$(basename "$ROOT")' is not in \`codesift repos\` — index it first (codesift index .)" >&2; exit 2; }
  codesift complexity "$RID" --top-n 60000 --min-complexity 1 2>/dev/null > "$WORK/cc.json" \
    || { echo "refactor-radar: codesift complexity failed" >&2; exit 2; }
fi

# --- previous snapshot for R ------------------------------------------------------------
PREV=""
if [ -n "$HISTORY" ]; then
  mkdir -p "$HISTORY" 2>/dev/null || { echo "refactor-radar: cannot create --history $HISTORY" >&2; exit 2; }
  PREV="$(ls -1 "$HISTORY"/*.json 2>/dev/null | sort | tail -1 || true)"
fi

python3 - "$ROOT" "$SHA" "$WORK" "$CONFIG" "$TOP" "${MIN_CC:-auto}" "$FRESH" "$ENGINE" "$JSON_OUT" "$QUEUE_OUT" "$HISTORY" "$PREV" "$MODE" "$QUIET" "$DIRTY" "$SINCE" <<'PY'
import json, os, re, sys, subprocess, collections, math, datetime
(ROOT, SHA, W, CONFIG, TOP, MIN_CC, FRESH, ENGINE, JSON_OUT, QUEUE_OUT, HISTORY, PREV, MODE, QUIET, DIRTY, SINCE) = sys.argv[1:17]
TOP = int(TOP); FRESH = int(FRESH); QUIET = QUIET == "1"; DIRTY = DIRTY == "1"; SINCE = int(SINCE)
cfg = json.load(open(CONFIG)) if CONFIG else {}
def log(msg):
    if not QUIET: print(msg, file=sys.stderr)

EXT = set(cfg.get("ext") or ["ts", "tsx", "js", "jsx", "mjs", "py", "php", "kt"])
NOISE_DEFAULT = [
    r"(^|/)(node_modules|dist|build|out|vendor|coverage|playwright-report|test-results|\.worktrees|\.turbo|\.next|__pycache__|storybook-static)/",
    r"(^|/)(e2e|docs|scripts|migrations|seeds?|fixtures?|__mocks__|__tests__|__snapshots__|generated|gen)/",
    r"\.(test|spec|stories|d|min|config|setup|mock|fixture|e2e)\.[a-z]+$",
    r"(^|/)(seed|fixtures?|showcase|help-content)[^/]*\.[a-z]+$",
    r"(^|/)[^/]*(mock|stub|fake|test-?utils?|testing|__fixtures__)[^/]*\.[a-z]+$",
    r"\.(data|styles|constants|types|manifest)\.[a-z]+$",
    r"/trace/assets/", r"(^|/)zuvo/",
]
NOISE = [re.compile(p) for p in NOISE_DEFAULT + list(cfg.get("noise") or [])]
CRIT_DEFAULT = [{"pattern": r"(submission|validation|validator|auth|guard|persistence|repository|mutation|payment|billing|tenant|scope|export|session|migration)", "k": 5}]
CRIT = [(re.compile(c["pattern"], re.I), float(c.get("k", 5))) for c in (cfg.get("critical") or CRIT_DEFAULT)]
K_DEFAULT = float(cfg.get("k_default", 3))
TEST_RE = re.compile(r"\.(test|spec)\.[a-z]+$|(^|/)(__tests__|tests?)/")

def is_src(p):
    ext = p.rsplit(".", 1)[-1] if "." in p else ""
    if ext not in EXT: return False
    return not any(n.search(p) for n in NOISE)

files = [l.strip() for l in open(f"{W}/files.txt", encoding="utf-8", errors="ignore") if l.strip()]
src = [p for p in files if is_src(p)]
tests = [p for p in files if TEST_RE.search(p) and p.rsplit(".", 1)[-1] in EXT]

# ---------------------------------------------------------------- file contents (ref-aware)
_head = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
_cache = {}
def preload_from_ref(paths):
    # ONE `git cat-file --batch` for every file instead of one `git show` per file:
    # measured 4:35 → seconds on a 5.5k-file repo when --ref is not HEAD.
    if not paths: return
    proc = subprocess.Popen(["git", "-C", ROOT, "cat-file", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    out, _ = proc.communicate("".join(f"{SHA}:{p}\n" for p in paths).encode())
    pos = 0; i = 0
    while pos < len(out) and i < len(paths):
        nl = out.find(b"\n", pos); hdr = out[pos:nl].decode(errors="ignore").split(); pos = nl + 1
        if len(hdr) == 3 and hdr[1] != "missing":
            size = int(hdr[2]); _cache[paths[i]] = out[pos:pos + size].decode("utf-8", errors="ignore"); pos += size + 1
        else:
            _cache[paths[i]] = ""
        i += 1
def read(p):
    if p in _cache: return _cache[p]
    t = ""
    if SHA == _head:
        try: t = open(os.path.join(ROOT, p), encoding="utf-8", errors="ignore").read()
        except Exception: t = ""
    if not t:
        r = subprocess.run(["git", "-C", ROOT, "show", f"{SHA}:{p}"], capture_output=True, text=True, errors="ignore")
        t = r.stdout if r.returncode == 0 else ""
    _cache[p] = t
    return t
if SHA != _head:
    preload_from_ref(src + tests)

# ---------------------------------------------------------------- builtin CC engine
# Regex estimator, deliberately simple and DOCUMENTED: strips comments/strings, finds
# function-like constructs, brace-matches their bodies, counts decision tokens in the body
# minus nested functions (each nested function is its own row). Numbers are comparable
# across snapshots of the same repo with the same engine — that is the only comparison
# the score needs; do not compare builtin ΣCC with codesift ΣCC.
TOK_C = re.compile(r"\b(if|for|foreach|while|case|catch|do|when)\b|&&|\|\||\?\?|\?(?![.:])")
FN_C = re.compile(
    r"\bfunction\s*\*?\s*([A-Za-z_$][\w$]*)?\s*\([^()]{0,400}(?:\([^()]{0,200}\)[^()]{0,400}){0,6}\)\s*(?::\s*[^{;=]{0,120})?\s*\{|"   # function name(...) {
    r"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]{0,80})?=\s*(?:async\s*)?(?:\([^()]{0,400}(?:\([^()]{0,200}\)[^()]{0,400}){0,6}\)|[A-Za-z_$][\w$]*)\s*(?::\s*[^=;{]{0,80})?=>\s*\{|"  # const x = (...) => {
    r"(?:^|[\s;{}])(?:(?:public|private|protected|static|async|override|fun|suspend|export|default)\s+)*([A-Za-z_$][\w$]*)\s*(?:<[^>]{0,80}>)?\s*\([^()]{0,400}(?:\([^()]{0,200}\)[^()]{0,400}){0,6}\)\s*(?::\s*[^{;=]{0,120})?\s*\{",  # method(...) {
    re.M)
KEYWORDS = {"if", "for", "while", "switch", "catch", "return", "else", "do", "try", "function", "when", "foreach", "with", "elseif", "constructor"}

STRIP_RE = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'|`(?:\\.|[^`\\])*`', re.S)
def strip_c(t):
    # comments and string literals become blanks of the same length (newlines kept), so
    # every offset below still points at the same place in the original text
    return STRIP_RE.sub(lambda m: "".join("\n" if ch == "\n" else " " for ch in m.group(0)), t)

MAX_FILE_CHARS = 400_000   # a generated/minified file above this is noise, not a candidate

def funcs_clike(text):
    if len(text) > MAX_FILE_CHARS: return []
    t = strip_c(text)
    opens = []   # positions of every "{" / "}" once, then each function reads its own span
    spans = []
    for m in FN_C.finditer(t):
        name = m.group(1) or m.group(2) or m.group(3) or "<anon>"
        if name in KEYWORDS: continue
        ob = t.find("{", m.end() - 1)
        if ob < 0 or ob != m.end() - 1: continue
        spans.append((ob, name))
    # brace matching in ONE pass: a stack of open positions gives every "{" its "}"
    close_of = {}; stack = []
    for i, ch in enumerate(t):
        if ch == "{": stack.append(i)
        elif ch == "}" and stack: close_of[stack.pop()] = i
    fns = [(a, close_of.get(a, len(t) - 1), name) for (a, name) in spans]
    fns.sort()
    rows = []
    # direct children of each span, in one forward walk (spans are sorted by start)
    for idx, (a, b, name) in enumerate(fns):
        direct = []; cursor = a
        for (x, y, _) in fns[idx + 1:]:
            if x > b: break
            if x >= cursor: direct.append((x, y)); cursor = y + 1
        body = t[a:b + 1]
        total = len(TOK_C.findall(body))
        sub = sum(len(TOK_C.findall(t[x:y + 1])) for (x, y) in direct)
        depth = 0; mx = 0; pos = a; k = 0
        while pos <= b:
            if k < len(direct) and pos == direct[k][0]:
                pos = direct[k][1] + 1; k += 1; continue
            ch = t[pos]
            if ch == "{": depth += 1; mx = max(mx, depth)
            elif ch == "}": depth -= 1
            pos += 1
        rows.append({"name": name, "cc": 1 + total - sub, "lines": body.count("\n") + 1, "nest": max(0, mx - 1)})
    return rows

TOK_PY = re.compile(r"^\s*(if|elif|for|while|except|with|case)\b|\band\b|\bor\b", re.M)
def funcs_py(text):
    lines = text.split("\n"); rows = []
    for i, l in enumerate(lines):
        m = re.match(r"^(\s*)(?:async\s+)?def\s+(\w+)", l)
        if not m: continue
        ind = len(m.group(1)); j = i + 1
        while j < len(lines) and (not lines[j].strip() or len(lines[j]) - len(lines[j].lstrip()) > ind): j += 1
        body = [x for x in lines[i+1:j] if x.strip() and not x.strip().startswith("#")]
        own = []; k = 0
        while k < len(body):
            mm = re.match(r"^(\s*)(?:async\s+)?def\s+", body[k])
            if mm:
                d = len(mm.group(1)); k += 1
                while k < len(body) and len(body[k]) - len(body[k].lstrip()) > d: k += 1
                continue
            own.append(body[k]); k += 1
        cc = 1 + sum(len(TOK_PY.findall(x)) for x in own)
        nest = max([(len(x) - len(x.lstrip()) - ind) // 4 for x in own] or [1]) - 1
        rows.append({"name": m.group(2), "cc": cc, "lines": j - i, "nest": max(0, nest)})
    return rows

def builtin_cc(p):
    t = read(p)
    if not t: return []
    return funcs_py(t) if p.endswith(".py") else funcs_clike(t)

per_file = collections.defaultdict(lambda: {"sum": 0, "max": 0, "n": 0, "top": "", "topln": 0, "nest": 0, "fns": []})
if ENGINE == "codesift":
    for f in json.load(open(f"{W}/cc.json")).get("functions", []):
        p = f["file"]
        if not is_src(p): continue
        a = per_file[p]; c = int(f.get("cyclomatic_complexity", 0))
        a["sum"] += c; a["n"] += 1; a["fns"].append({"name": f.get("name"), "cc": c, "lines": f.get("lines", 0)})
        if c > a["max"]: a.update(max=c, top=f.get("name", ""), topln=f.get("lines", 0), nest=f.get("max_nesting_depth", 0))
else:
    for p in src:
        for f in builtin_cc(p):
            a = per_file[p]; c = f["cc"]
            a["sum"] += c; a["n"] += 1; a["fns"].append(f)
            if c > a["max"]: a.update(max=c, top=f["name"], topln=f["lines"], nest=f["nest"])

def loc(p, _c={}):
    if p not in _c: _c[p] = sum(1 for l in read(p).split("\n") if l.strip())
    return _c[p]

# ---------------------------------------------------------------- churn by commit type
# Parsed into commits first; per-file AND per-family counts are derived later, so a commit
# that touches a facade and its satellite is ONE fix for the family, not two.
commits = []   # (type, epoch, [paths])
now = int(datetime.datetime.now().timestamp())
cur = None
for raw in open(f"{W}/log.txt", encoding="utf-8", errors="ignore"):
    l = raw.rstrip("\n")
    if l.startswith("\x00"):
        _, ts, subj = l.split("\x00", 2)
        s = subj.strip().lower()
        ctype = "fix" if s.startswith("fix") else "feat" if s.startswith("feat") else "ref" if s.startswith("refactor") else "other"
        cur = (ctype, int(ts or 0), []); commits.append(cur)
        continue
    if l and cur is not None: cur[2].append(l)
churn = collections.defaultdict(lambda: {"fix": 0, "feat": 0, "ref": 0, "all": 0})
by_path = {"fix": collections.defaultdict(set), "feat": collections.defaultdict(set), "ref": collections.defaultdict(set)}  # path -> commit ids
fresh_ref = {}   # path -> newest refactor-commit epoch inside the fresh window
for ci, (ctype, cts, paths) in enumerate(commits):
    for l in paths:
        c = churn[l]; c["all"] += 1
        if ctype in ("fix", "feat", "ref"):
            c[ctype] += 1; by_path[ctype][l].add(ci)
        if ctype == "ref" and now - cts < FRESH * 86400:
            fresh_ref[l] = max(fresh_ref.get(l, 0), cts)
def family_churn(kind, members):
    s = set()
    for p in members: s |= by_path[kind].get(p, set())
    return len(s)

# ---------------------------------------------------------------- families
set_src = set(src)
def stem(p):
    b = os.path.basename(p)
    return b.split(".")[0]
def family_of(p):
    d = os.path.dirname(p); s = stem(p)
    # a directory named like a facade next to it joins the facade's family:  x/foo.ts + x/foo/*
    parts = d.split("/")
    if len(parts) >= 1 and parts[-1]:
        parent = "/".join(parts[:-1]); dirname = parts[-1]
        for e in EXT:
            if f"{parent}/{dirname}.{e}" in set_src or f"{parent}/{dirname}.service.{e}" in set_src:
                return f"{parent}/{dirname}"
    return f"{d}/{s}" if d else s
fam = collections.defaultdict(list)
for p in src: fam[family_of(p)].append(p)

# ---------------------------------------------------------------- fan-in (relative imports, C-like)
IMP = re.compile(r"""(?:from|import|require\()\s*['"](\.{1,2}/[^'"]+)['"]""")
fan_in = collections.Counter(); importers = collections.defaultdict(set)
if any(e in EXT for e in ("ts", "tsx", "js", "jsx", "mjs")):
    idx = set(src)
    for p in src:
        if p.rsplit(".", 1)[-1] not in ("ts", "tsx", "js", "jsx", "mjs"): continue
        for m in IMP.finditer(read(p)):
            target = os.path.normpath(os.path.join(os.path.dirname(p), m.group(1)))
            for cand in (target, *[f"{target}.{e}" for e in ("ts", "tsx", "js", "jsx", "mjs")], *[f"{target}/index.{e}" for e in ("ts", "tsx", "js")]):
                if cand in idx and cand != p:
                    fan_in[cand] += 1; importers[cand].add(p); break

# ---------------------------------------------------------------- tests proxy
tests_by_stem = collections.defaultdict(list)
for t in tests: tests_by_stem[stem(t)].append(t)

# ---------------------------------------------------------------- busy set
busy_paths = {l.strip() for l in open(f"{W}/busy-paths.txt", encoding="utf-8", errors="ignore") if l.strip()}
busy_names = [l.strip().lower() for l in open(f"{W}/busy-names.txt", encoding="utf-8", errors="ignore") if l.strip()]
def busy_by_name(fkey):
    s = os.path.basename(fkey).lower()
    if len(s) < 6: return None            # one-word stems (page, survey) match everything — hand-check
    for n in busy_names:
        if s in n and ("refactor" in n or "split" in n or "extract" in n or "/" in n): return n
    return None

# ---------------------------------------------------------------- previous snapshot → R
prev_top = set(); prev_meta = None
if PREV:
    try:
        pj = json.load(open(PREV)); prev_meta = pj.get("meta", {})
        prev_top = {r["family"] for r in pj.get("rows", [])[:100]}
        if prev_meta.get("engine") != ENGINE:
            log(f"  WARN: previous snapshot used engine={prev_meta.get('engine')} — ΣCC not comparable; R still computed from membership")
    except Exception as e:
        log(f"  WARN: cannot read previous snapshot {PREV}: {e}")

# ---------------------------------------------------------------- rows per family
rows = []
for key, members in fam.items():
    members = sorted(members)
    s = sum(per_file[p]["sum"] for p in members)
    if s == 0 and ENGINE == "builtin" and all(per_file[p]["n"] == 0 for p in members): continue
    mx = max((per_file[p]["max"], per_file[p]["top"], per_file[p]["topln"], per_file[p]["nest"], p) for p in members)
    n = sum(per_file[p]["n"] for p in members)
    L = sum(loc(p) for p in members)
    if L == 0: continue
    fx = family_churn("fix", members); ft = family_churn("feat", members); rf = family_churn("ref", members)
    fi = sum(fan_in[p] for p in members) - sum(1 for p in members for q in importers.get(p, ()) if q in set(members))
    tl = sum(loc(t) for p in members for t in tests_by_stem.get(stem(p), []))
    cov = tl / L
    K = K_DEFAULT                     # first matching manifest pattern wins (ordered list), else k_default
    for rx, k in CRIT:
        if any(rx.search(p) for p in members): K = k; break
    fresh = max((fresh_ref.get(p, 0) for p in members), default=0)
    busy_p = [p for p in members if p in busy_paths]
    busy_n = busy_by_name(key)
    satd = sum(len(re.findall(r"\b(TODO|FIXME|HACK|XXX)\b|@deprecated", read(p))) for p in members)
    tdebt = sum(len(re.findall(r"\bas any\b|@ts-ignore|@ts-expect-error", read(p))) for p in members)
    R = 1.0 if (not PREV or key in prev_top) else 0.6
    testability = 1.0 if tl > 0 else 1.5
    effort = L + 10 * len(members)
    if MODE == "tests":
        score = s * math.sqrt(fx + 1) * K * max(0.0, 1.0 - min(cov, 1.0))
    else:
        score = s * math.sqrt(fx + 1) * K * R / ((1 + fi / 20.0) * testability * (effort ** 0.3))
    conc = (mx[0] / s) if s else 0
    if L > 600 and n >= 10: rtype = "GOD_CLASS"
    elif conc >= 0.4: rtype = "EXTRACT_METHODS"
    elif mx[3] >= 6: rtype = "SIMPLIFY"
    elif n >= 10: rtype = "SPLIT_FILE"
    else: rtype = "EXTRACT_METHODS"
    rows.append(dict(family=key, files=members, n_files=len(members), sum=s, max=mx[0], max_fn=mx[1], max_fn_lines=mx[2],
                     max_file=mx[4], nest=mx[3], n=n, loc=L, fix=fx, feat=ft, ref=rf, fan_in=fi, cov=round(cov, 2),
                     k=K, r=R, satd=satd, type_debt=tdebt, fresh=bool(fresh), fresh_at=fresh or None,
                     busy_paths=busy_p, busy_name=busy_n, concentration=round(conc, 2), rtype=rtype, score=round(score, 2)))

# ---------------------------------------------------------------- thresholds (self-calibrating)
sums = sorted(r["sum"] for r in rows)
def pct(q):
    if not sums: return 0
    return sums[min(len(sums) - 1, int(q * len(sums)))]
min_cc = pct(0.8) if MIN_CC == "auto" else int(MIN_CC)
fixes = sorted(r["fix"] for r in rows)
log(f"  population: {len(src)} source files → {len(rows)} families | ΣCC P50={pct(.5)} P80={pct(.8)} P90={pct(.9)} | fix-churn P90={fixes[int(.9*len(fixes))] if fixes else 0} | floor ΣCC≥{min_cc}")

excluded = collections.Counter()
free = []
for r in rows:
    if r["busy_paths"]: excluded["busy:diff"] += 1; r["excluded"] = "busy:diff"; continue
    if r["busy_name"]: excluded["busy:name"] += 1; r["excluded"] = "busy:name"; continue
    if r["fresh"]: excluded["fresh-refactor"] += 1; r["excluded"] = "fresh-refactor"; continue
    if r["sum"] < min_cc: excluded["below-floor"] += 1; r["excluded"] = "below-floor"; continue
    if MODE == "tests" and r["cov"] >= 0.6: excluded["covered"] += 1; r["excluded"] = "covered"; continue
    r["excluded"] = None; free.append(r)
free.sort(key=lambda r: (-r["score"], r["family"]))
log("  excluded: " + ", ".join(f"{k}={v}" for k, v in sorted(excluded.items())) if excluded else "  excluded: none")
if free:
    top_score = free[0]["score"] or 1.0
    for i, r in enumerate(free, 1):
        r["rank"] = i; r["score_norm"] = round(min(1.0, r["score"] / top_score), 2)

meta = dict(schema=1, repo=ROOT, sha=SHA, date=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), engine=ENGINE,
            since_days=SINCE, fresh_days=FRESH, min_cc=min_cc, mode=MODE, dirty=DIRTY, prev=PREV or None,
            excluded=dict(excluded), population=len(rows))
out = {"meta": meta, "rows": free, "excluded_rows": [r for r in rows if r["excluded"]]}
if JSON_OUT:
    json.dump(out, open(JSON_OUT, "w"), indent=1); log(f"  json → {JSON_OUT}")
if HISTORY:
    snap = os.path.join(HISTORY, f"{meta['date'][:10]}-{SHA[:7]}-{MODE}.json")
    json.dump({"meta": meta, "rows": free[:200]}, open(snap, "w")); log(f"  snapshot → {snap}" + (f" (prev: {os.path.basename(PREV)})" if PREV else " (first snapshot — R=1.0 for all)"))
if QUEUE_OUT:
    with open(QUEUE_OUT, "w") as q:
        q.write(f"# Refactor Batch -- {meta['date']}\n# Source: refactor-radar {SHA[:9]} engine={ENGINE} window={SINCE}d floor=ΣCC≥{min_cc}\n")
        q.write(f"# Total: {min(TOP, len(free))} | Completed: 0 | Failed: 0 | Pending: {min(TOP, len(free))}\n")
        q.write("# Columns after the type: radar score (normalised), then evidence. zuvo:refactor batch triage re-enriches these lines.\n\n")
        for r in free[:TOP]:
            q.write(f"- [ ] {r['max_file']} | {r['rtype']} | Score: {r['score_norm']:.2f}\n")
            q.write(f"#     family={r['family']} files={r['n_files']} ΣCC={r['sum']} max={r['max']}({r['max_fn']}) nest={r['nest']} fix={r['fix']} K={int(r['k'])} R={r['r']} fan_in={r['fan_in']} tests={int(r['cov']*100)}%\n")
    log(f"  queue → {QUEUE_OUT} ({min(TOP, len(free))} entries, zuvo:refactor batch format)")

if not QUIET:
    def short(p):
        return re.sub(r"^(apps|packages|src)/", "", p)
    title = "REFACTOR" if MODE == "refactor" else "TEST COVERAGE"
    print(f"\n{title} RADAR — {len(free)} candidates of {len(rows)} families (engine={ENGINE}, ΣCC≥{min_cc}, window {SINCE}d)")
    print(f"{'#':>3} {'score':>6} {'type':<15} {'ΣCC':>4} {'max':>4} {'nest':>4} {'fn':>3} {'LOC':>5} {'fix':>3} {'feat':>4} {'K':>1} {'R':>3} {'fan':>3} {'test':>5} {'fam':>3}  FAMILY / worst function")
    for r in free[:TOP]:
        cov = (f"{min(999, int(r['cov']*100))}%") if r["cov"] else "NONE"
        print(f"{r['rank']:>3} {r['score_norm']:>6.2f} {r['rtype']:<15} {r['sum']:>4} {r['max']:>4} {r['nest']:>4} {r['n']:>3} {r['loc']:>5} {r['fix']:>3} {r['feat']:>4} {int(r['k']):>1} {r['r']:>3} {r['fan_in']:>3} {cov:>5} {r['n_files']:>3}  {short(r['family'])}  ← {r['max_fn']}({r['max']})")
PY
