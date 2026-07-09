#!/usr/bin/env bash
# test-eval-corpus-schema.sh — schema + assertion-quality contract for the eval
# corpus (Task 7).
#
# RED-first: authored BEFORE evals/*.evals.json and shared/includes/eval-schema.md
# exist. When those artifacts are missing every real-corpus assertion below fails
# loudly (that is the intended RED evidence); once the corpus + schema doc are
# implemented, all assertions must pass.
#
# Validates, for each of the 4 evals/<skill>.evals.json (via python3 — precedented
# in scripts/, no new dependency):
#   (a) file exists and parses as JSON;
#   (b) top-level keys are EXACTLY {skill_name, evals}; skill_name == filename stem;
#   (c) evals is an array with >=2 entries; each entry has EXACTLY keys
#       {id, prompt, expected_output, files, assertions}; ids are unique ints;
#       prompt/expected_output are non-empty strings; files is an array (maybe
#       empty) of non-empty, repo-RELATIVE literal paths (no absolute paths, no
#       glob metacharacters, no ../ escapes) each resolving to an existing repo
#       file; assertions is a non-empty array of strings;
#   (d) ASSERTION-QUALITY HEURISTIC — every assertion string is >=20 chars,
#       contains >=1 checkable verb, and does NOT end with a vague qualifier;
#   (e) a malformed-JSON negative fixture makes the validator fail loudly, naming
#       the offending file;
#   (f) shared/includes/eval-schema.md exists and documents the input schema keys
#       + the report output-path convention (skill_name, assertions, zuvo/reports/).
#   (g) OPTIONAL `fixtures` (self-contained corpus): if present, an array of
#       {path, content} (+ optional stage) objects — path a repo-relative literal
#       (no absolute/glob/../), unique per (stage, path); content a non-empty string;
#       stage is "base"|"head" (default head; base = committed pre-change git state,
#       so the same path once-as-base + once-as-head expresses a modified-file diff).
#       A files[] entry naming a declared fixture path is EXEMPT from the
#       repo-existence check (materialized at run time).
#
# The heuristic + structural rules are additionally proven to REJECT (not just
# accept) via inline negative fixtures — a no-op validator that always prints OK
# would fail this test.
#
# Fixture idiom (mktemp + trap) adapted from tests/hooks/test-pipeline-gate-lib.sh.
# Accumulate-and-report (pass/bad + final tally), matching sibling skill-suite
# tests. bash 3.2-compatible (macOS default).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EVALS_DIR="$ROOT/evals"
SCHEMA_DOC="$ROOT/shared/includes/eval-schema.md"
SKILLS="refactor write-tests review execute"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

# ── embedded python validator ─────────────────────────────────────────────────
# args: <json-file> <expected-stem> [<repo-root>]. Prints one OK/INVALID line
# naming the file. exit 0 iff the file satisfies (a)-(d) for the given stem.
# When <repo-root> is given and non-empty, files[] paths are existence-checked.
validate() {
  python3 - "$1" "$2" "${3:-}" <<'PY'
import json, sys, re, os

path = sys.argv[1]
expected_stem = sys.argv[2]
root = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None

VERBS = {"contains", "matches", "exits", "outputs", "calls", "writes", "creates",
         "commits", "dispatches", "edits", "runs", "records", "shows"}
# trailing \W*$ (not \.?\s*$) so 'correctly!', 'correctly)', 'correctly,' can't
# slip past the vague-qualifier gate via non-period punctuation (adversarial WARN).
# 'as\s+expected' (not 'as expected') so double-spacing can't defeat the phrase match.
VAGUE = r'(?:^|\s)(well|correctly|properly|appropriately|as\s+expected)\W*$'

def die(msg):
    print("INVALID [%s]: %s" % (path, msg))
    sys.exit(1)

# (a) exists + parses
try:
    # explicit UTF-8 — corpora contain em-dashes; open() would default to
    # CP-1252 on Windows CI and crash with UnicodeDecodeError (adversarial CRITICAL).
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except FileNotFoundError:
    die("file does not exist")
except json.JSONDecodeError as e:
    die("not valid JSON (%s)" % e)

# (b) top-level shape
if not isinstance(data, dict):
    die("top-level must be a JSON object")
if set(data.keys()) != {"skill_name", "evals"}:
    die("top-level keys must be exactly {skill_name, evals}, got %s" % sorted(data.keys()))
if data["skill_name"] != expected_stem:
    die("skill_name '%s' != filename stem '%s'" % (data["skill_name"], expected_stem))

evals = data["evals"]
if not isinstance(evals, list) or len(evals) < 2:
    got = len(evals) if isinstance(evals, list) else type(evals).__name__
    die("evals must be an array with >=2 entries, got %s" % got)

seen_ids = set()
total_assertions = 0
for i, ev in enumerate(evals):
    if not isinstance(ev, dict):
        die("eval[%d] must be an object" % i)
    # REQUIRED keys are exact; `fixtures` is the one OPTIONAL key (self-contained
    # corpus support). Any other extra key, or any missing required key, is an error.
    REQUIRED = {"id", "prompt", "expected_output", "files", "assertions"}
    keys = set(ev.keys())
    extra = keys - REQUIRED - {"fixtures"}
    missing = REQUIRED - keys
    if extra or missing:
        die("eval[%d] keys must be exactly {id, prompt, expected_output, files, assertions} "
            "(+ optional fixtures); missing=%s extra=%s" % (i, sorted(missing), sorted(extra)))
    _id = ev["id"]
    if not isinstance(_id, int) or isinstance(_id, bool):
        die("eval[%d].id must be an int, got %r" % (i, _id))
    if _id in seen_ids:
        die("eval[%d].id=%r is duplicated (ids must be unique per file)" % (i, _id))
    seen_ids.add(_id)
    for k in ("prompt", "expected_output"):
        if not isinstance(ev[k], str) or not ev[k].strip():
            die("eval[%d].%s must be a non-empty string" % (i, k))
    # optional `fixtures`: files materialized into the sandbox before the executor
    # runs (SKILL.md Phase 2). Parse FIRST so a files[] entry may name a fixture path
    # and be exempt from the repo-existence check below (self-contained corpus).
    fixture_paths = set()
    fixture_stage_paths = set()
    if "fixtures" in ev:
        fx = ev["fixtures"]
        if not isinstance(fx, list):
            die("eval[%d].fixtures must be an array" % i)
        for k, fxe in enumerate(fx):
            if not isinstance(fxe, dict):
                die("eval[%d].fixtures[%d] must be an object" % (i, k))
            fkeys = set(fxe.keys())
            if not {"path", "content"} <= fkeys or (fkeys - {"path", "content", "stage"}):
                die("eval[%d].fixtures[%d] keys must be {path, content} (+ optional stage), got %s"
                    % (i, k, sorted(fkeys)))
            # optional stage: "base" (committed pre-change git state) | "head" (default,
            # uncommitted). Anything else is a schema error, never silently defaulted.
            stage = fxe.get("stage", "head")
            if stage not in ("base", "head"):
                die("eval[%d].fixtures[%d].stage must be 'base' or 'head', got %r" % (i, k, fxe.get("stage")))
            fp = fxe["path"]
            if not isinstance(fp, str) or not fp.strip():
                die("eval[%d].fixtures[%d].path must be a non-empty string" % (i, k))
            if os.path.isabs(fp):
                die("eval[%d].fixtures[%d].path must be repo-relative, got absolute: %r" % (i, k, fp))
            if any(c in fp for c in "*?[]"):
                die("eval[%d].fixtures[%d].path must be a literal path (no glob metacharacters): %r" % (i, k, fp))
            fnorm = os.path.normpath(fp)
            if fnorm == ".." or fnorm.startswith(".." + os.sep):
                die("eval[%d].fixtures[%d].path escapes the sandbox root: %r" % (i, k, fp))
            # dedup per (stage, path): the same path ONCE as base + ONCE as head is the
            # canonical modified-file diff; the same path twice in ONE stage is an error
            # (last-write-wins would silently mask a corpus author mistake).
            if (stage, fnorm) in fixture_stage_paths:
                die("eval[%d].fixtures[%d].path is duplicated within stage %r: %r" % (i, k, stage, fp))
            fixture_stage_paths.add((stage, fnorm))
            fixture_paths.add(fnorm)
            if not isinstance(fxe["content"], str) or not fxe["content"]:
                die("eval[%d].fixtures[%d].content must be a non-empty string" % (i, k))
    if not isinstance(ev["files"], list):
        die("eval[%d].files must be an array" % i)
    for j, fn in enumerate(ev["files"]):
        if not isinstance(fn, str) or not fn.strip():
            die("eval[%d].files[%d] must be a non-empty string" % (i, j))
        # files[] are documented as repo-RELATIVE literal paths. Absolute paths and
        # glob metacharacters are undefined by the schema — REJECT them, never
        # silently skip (adversarial: os.path.join drops root on an absolute path,
        # so an abs path passes locally then misresolves in CI; a skipped glob
        # resolves to 0 files at run time and misgrades). No silent bypass.
        if os.path.isabs(fn):
            die("eval[%d].files[%d] must be repo-relative, got absolute path: %r" % (i, j, fn))
        if any(c in fn for c in "*?[]"):
            die("eval[%d].files[%d] must be a literal path (no glob metacharacters): %r" % (i, j, fn))
        # existence check — a typo'd path passes schema but misgrades at run time;
        # catch it when a repo root is supplied. normpath blocks ../ escapes so a
        # files[] entry cannot reference a real file OUTSIDE the repo.
        if root:
            norm = os.path.normpath(fn)
            if norm == ".." or norm.startswith(".." + os.sep):
                die("eval[%d].files[%d] escapes repo root: %r" % (i, j, fn))
            # a files[] entry may name a fixture materialized at run time (self-contained
            # corpus) — exempt declared fixture paths from the repo-existence check.
            if norm not in fixture_paths and not os.path.isfile(os.path.join(root, norm)):
                die("eval[%d].files[%d] references nonexistent repo file (and is not a declared fixture): %r"
                    % (i, j, fn))
    a = ev["assertions"]
    if not isinstance(a, list) or len(a) < 1:
        die("eval[%d].assertions must be a non-empty array" % i)
    for j, s in enumerate(a):
        if not isinstance(s, str) or not s.strip():
            die("eval[%d].assertions[%d] must be a non-empty string" % (i, j))
        # (d) assertion-quality heuristic — length on the STRIPPED string so
        # whitespace padding can't buy a trivial assertion past the 20-char floor.
        if len(s.strip()) < 20:
            die("eval[%d].assertions[%d] too short (<20 chars stripped): %r" % (i, j, s))
        words = set(re.findall(r"[a-z]+", s.lower()))
        if not (words & VERBS):
            die("eval[%d].assertions[%d] has no checkable verb from %s: %r"
                % (i, j, sorted(VERBS), s))
        if re.search(VAGUE, s, re.I):
            die("eval[%d].assertions[%d] ends with a vague qualifier: %r" % (i, j, s))
        total_assertions += 1

print("OK [%s]: skill_name=%s evals=%d assertions=%d rejections=0"
      % (path, data["skill_name"], len(evals), total_assertions))
PY
}

echo "== (a-d) real corpora: schema + assertion-quality =="
total_evals=0
validated=0
req_count=0

# (1) every REQUIRED corpus must be present (missing required = failure)
for s in $SKILLS; do
  req_count=$((req_count + 1))
  [ -f "$EVALS_DIR/$s.evals.json" ] || bad "required corpus missing: evals/$s.evals.json"
done

# (2) validate EVERY discovered evals/*.evals.json against its filename stem — a
#     future/stray corpus is NEVER silently skipped (adversarial CRITICAL: the old
#     hardcoded $SKILLS loop ignored files outside the list). files[] paths are
#     existence-checked against repo root ($ROOT passed as 3rd arg).
found_any=0
for f in "$EVALS_DIR"/*.evals.json; do
  [ -e "$f" ] || continue          # nullglob-safe (bash 3.2): skip the literal glob
  found_any=1
  base="$(basename "$f")"; stem="${base%.evals.json}"
  out="$(validate "$f" "$stem" "$ROOT" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "evals/$base -> $out"
    # space-anchored ' evals=N' so the metric is read from the python summary
    # field, never from an 'evals=' substring inside the bracketed [path] (a file
    # named evals=100.evals.json must not hijack the count — adversarial INFO).
    n="$(printf '%s\n' "$out" | grep -oE ' evals=[0-9]+' | head -1 | grep -oE '[0-9]+')"
    total_evals=$((total_evals + ${n:-0}))
    validated=$((validated + 1))
  else
    bad "evals/$base -> $out"
  fi
done
[ "$found_any" -eq 1 ] || bad "no evals/*.evals.json corpora discovered under $EVALS_DIR"

echo
echo "== (f) shared/includes/eval-schema.md =="
if [ -f "$SCHEMA_DOC" ]; then
  pass "eval-schema.md exists"
  for tok in 'skill_name' 'assertions' 'zuvo/reports/'; do
    if grep -Fq -- "$tok" "$SCHEMA_DOC"; then
      pass "eval-schema.md documents '$tok'"
    else
      bad "eval-schema.md missing required token '$tok'"
    fi
  done
else
  bad "shared/includes/eval-schema.md does not exist"
fi

# ── negative fixtures: prove the validator REJECTS bad input (not a no-op) ─────
echo
echo "== (b-e) negative fixtures: validator must reject + name the file =="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# expect_reject <file> <stem> <label> [<root>]  — asserts non-zero exit AND the
# file path appears in the loud output. <root> (optional) activates files[]
# existence-checking for the fixture that targets that branch.
expect_reject() {
  local file="$1" stem="$2" label="$3" root="${4:-}" o rc
  if [ -n "$root" ]; then o="$(validate "$file" "$stem" "$root" 2>&1)"; else o="$(validate "$file" "$stem" 2>&1)"; fi
  rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "$label — validator ACCEPTED bad fixture (expected reject): $o"
  elif printf '%s\n' "$o" | grep -Fq -- "$file"; then
    pass "$label — rejected + named file"
  else
    bad "$label — rejected but did NOT name the file: $o"
  fi
}

# (e) malformed JSON
MAL="$TMP/malformed.evals.json"
printf '{ "skill_name": "malformed", "evals": [ {"id": 1,\n' > "$MAL"
expect_reject "$MAL" "malformed" "(e) malformed JSON"

# skill_name != stem
MIS="$TMP/mismatch.evals.json"
printf '{"skill_name":"other","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":["The transcript writes a file and shows the result clearly here"]},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":["The transcript writes a file and shows the result clearly here"]}]}' > "$MIS"
expect_reject "$MIS" "mismatch" "(b) skill_name != filename stem"

# extra top-level key
EXTRA="$TMP/extra.evals.json"
printf '{"skill_name":"extra","version":1,"evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":["The transcript writes a file and shows the result clearly here"]},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":["The transcript writes a file and shows the result clearly here"]}]}' > "$EXTRA"
expect_reject "$EXTRA" "extra" "(b) extra top-level key"

# duplicate id
DUP="$TMP/dup.evals.json"
printf '{"skill_name":"dup","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":["The transcript writes a file and shows the result clearly here"]},{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":["The transcript writes a file and shows the result clearly here"]}]}' > "$DUP"
expect_reject "$DUP" "dup" "(c) duplicate id"

# heuristic: assertion too short
SHORT="$TMP/short.evals.json"
printf '{"skill_name":"short","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":["writes a file"]},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":["The transcript writes a file and shows the result clearly here"]}]}' > "$SHORT"
expect_reject "$SHORT" "short" "(d) assertion too short (<20 chars)"

# heuristic: no checkable verb
NOVERB="$TMP/noverb.evals.json"
printf '{"skill_name":"noverb","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":["The behaviour of the skill under this scenario is generally acceptable"]},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":["The transcript writes a file and shows the result clearly here"]}]}' > "$NOVERB"
expect_reject "$NOVERB" "noverb" "(d) assertion has no checkable verb"

# heuristic: vague-qualifier ending
VAGUE="$TMP/vague.evals.json"
printf '{"skill_name":"vague","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":["The transcript writes the file and the skill handles the input correctly"]},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":["The transcript writes a file and shows the result clearly here"]}]}' > "$VAGUE"
expect_reject "$VAGUE" "vague" "(d) assertion ends with vague qualifier 'correctly'"

# ── structural branches: one fixture per remaining validate() reject path ──────
# (each isolates a single die(); a no-op validator that ignored structure would
#  ACCEPT these and fail the test — closing Q11 all-branches coverage.)
V='["The transcript writes a file and shows the result clearly here"]'  # reusable valid assertions array

# (a) nonexistent file — reject a missing path by name (no file created)
expect_reject "$TMP/ghost.evals.json" "ghost" "(a) nonexistent file"

# (b) top-level is not a JSON object (an array parses but is not a dict)
TOPARR="$TMP/toparr.evals.json"
printf '[]' > "$TOPARR"
expect_reject "$TOPARR" "toparr" "(b) top-level not an object"

# (c) evals is not an array
NLEV="$TMP/nlev.evals.json"
printf '{"skill_name":"nlev","evals":"nope"}' > "$NLEV"
expect_reject "$NLEV" "nlev" "(c) evals not an array"

# (c) evals has fewer than 2 entries
ONE="$TMP/one.evals.json"
printf '{"skill_name":"one","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" > "$ONE"
expect_reject "$ONE" "one" "(c) evals has <2 entries"

# (c) an eval entry is a scalar, not an object
SCAL="$TMP/scal.evals.json"
printf '{"skill_name":"scal","evals":["nope","also-nope"]}' > "$SCAL"
expect_reject "$SCAL" "scal" "(c) eval entry not an object"

# (c) an eval carries the wrong key set (extra key)
EVK="$TMP/evk.evals.json"
printf '{"skill_name":"evk","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":%s,"extra":1},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$EVK"
expect_reject "$EVK" "evk" "(c) eval has wrong key set"

# (c) eval id is not an int (string)
SID="$TMP/sid.evals.json"
printf '{"skill_name":"sid","evals":[{"id":"1","prompt":"p","expected_output":"e","files":[],"assertions":%s},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$SID"
expect_reject "$SID" "sid" "(c) eval id not an int"

# (c) eval id is a bool — Python bool is an int subclass, the isinstance(_,bool) guard must still reject
BID="$TMP/bid.evals.json"
printf '{"skill_name":"bid","evals":[{"id":true,"prompt":"p","expected_output":"e","files":[],"assertions":%s},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$BID"
expect_reject "$BID" "bid" "(c) eval id is bool (int-subclass guard)"

# (c) empty required string (prompt)
EP="$TMP/ep.evals.json"
printf '{"skill_name":"ep","evals":[{"id":1,"prompt":"","expected_output":"e","files":[],"assertions":%s},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$EP"
expect_reject "$EP" "ep" "(c) empty prompt string"

# (c) files is not an array
NLF="$TMP/nlf.evals.json"
printf '{"skill_name":"nlf","evals":[{"id":1,"prompt":"p","expected_output":"e","files":"nope","assertions":%s},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$NLF"
expect_reject "$NLF" "nlf" "(c) files not an array"

# (c) a files[] entry is not a string
NSF="$TMP/nsf.evals.json"
printf '{"skill_name":"nsf","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[123],"assertions":%s},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$NSF"
expect_reject "$NSF" "nsf" "(c) files entry not a string"

# (c) assertions is empty
EA="$TMP/ea.evals.json"
printf '{"skill_name":"ea","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":[]},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" > "$EA"
expect_reject "$EA" "ea" "(c) empty assertions array"

# (c) an assertions[] entry is not a string
NSA="$TMP/nsa.evals.json"
printf '{"skill_name":"nsa","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":[123]},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" > "$NSA"
expect_reject "$NSA" "nsa" "(c) assertion entry not a string"

# ── adversarial-hardening fixtures (round 2: prove the tightened gates reject) ──
# (d) vague qualifier + NON-period trailing punctuation ("correctly!") — the old
#     \.?\s*$ regex let this slip; \W*$ must now reject it.
BANG="$TMP/bang.evals.json"
printf '{"skill_name":"bang","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":["The transcript shows the skill handled the input correctly!"]},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" > "$BANG"
expect_reject "$BANG" "bang" "(d) vague qualifier + '!' (non-period punctuation)"

# (d) too-short assertion padded with trailing whitespace to fake >=20 chars —
#     len(s.strip()) must reject ("edits file" + spaces == 10 chars stripped).
PAD="$TMP/pad.evals.json"
printf '{"skill_name":"pad","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":["edits file            "]},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" > "$PAD"
expect_reject "$PAD" "pad" "(d) short assertion whitespace-padded to fake length"

# (c) files[] references a path that does not exist on disk — rejected only when a
#     repo root is supplied (4th arg activates the existence check).
NEF="$TMP/nef.evals.json"
printf '{"skill_name":"nef","evals":[{"id":1,"prompt":"p","expected_output":"e","files":["skills/does-not-exist-xyz/SKILL.md"],"assertions":%s},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$NEF"
expect_reject "$NEF" "nef" "(c) files[] path nonexistent (repo-root resolved)" "$ROOT"

# (c) files[] absolute path — os.path.join would DROP root and check the abs path
#     (passes locally, misresolves in CI). isabs guard must reject unconditionally.
ABS="$TMP/abs.evals.json"
printf '{"skill_name":"abs","evals":[{"id":1,"prompt":"p","expected_output":"e","files":["/tmp/whatever/SKILL.md"],"assertions":%s},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$ABS"
expect_reject "$ABS" "abs" "(c) files[] absolute path (repo-relative contract)" "$ROOT"

# (c) files[] glob metacharacter — a skipped glob resolves to 0 files at run time.
#     glob guard must reject rather than silently accept.
GLB="$TMP/glb.evals.json"
printf '{"skill_name":"glb","evals":[{"id":1,"prompt":"p","expected_output":"e","files":["skills/*/SKILL.md"],"assertions":%s},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$GLB"
expect_reject "$GLB" "glb" "(c) files[] glob metacharacter (literal-path contract)" "$ROOT"

# (c) files[] ../ escape — normpath must catch a path that resolves OUTSIDE the repo
#     even if it points at a real file on disk (repo-root escape).
ESC="$TMP/esc.evals.json"
printf '{"skill_name":"esc","evals":[{"id":1,"prompt":"p","expected_output":"e","files":["../outside-repo/SKILL.md"],"assertions":%s},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$ESC"
expect_reject "$ESC" "esc" "(c) files[] ../ escapes repo root" "$ROOT"

# (c) non-string prompt (int) — exercises the isinstance() half of the required-
#     string branch (EP above covers only the empty-string half).
NSP="$TMP/nsp.evals.json"
printf '{"skill_name":"nsp","evals":[{"id":1,"prompt":123,"expected_output":"e","files":[],"assertions":%s},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$NSP"
expect_reject "$NSP" "nsp" "(c) non-string prompt (int)"

# ── fixtures branches: prove the optional `fixtures` gates reject bad input ─────
# (each isolates one die() in the fixtures block; a validator that ignored fixtures
#  would ACCEPT these and fail the test.)

# fixtures is not an array
FXNA="$TMP/fxna.evals.json"
printf '{"skill_name":"fxna","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":%s,"fixtures":"nope"},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$FXNA"
expect_reject "$FXNA" "fxna" "(fx) fixtures not an array"

# a fixtures[] entry is not an object
FXNO="$TMP/fxno.evals.json"
printf '{"skill_name":"fxno","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":%s,"fixtures":["nope"]},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$FXNO"
expect_reject "$FXNO" "fxno" "(fx) fixtures entry not an object"

# fixtures[] entry has the wrong key set (extra key)
FXWK="$TMP/fxwk.evals.json"
printf '{"skill_name":"fxwk","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":%s,"fixtures":[{"path":"a.ts","content":"x","extra":1}]},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$FXWK"
expect_reject "$FXWK" "fxwk" "(fx) fixture wrong key set"

# fixtures[].path absolute
FXAB="$TMP/fxab.evals.json"
printf '{"skill_name":"fxab","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":%s,"fixtures":[{"path":"/tmp/a.ts","content":"x"}]},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$FXAB"
expect_reject "$FXAB" "fxab" "(fx) fixture path absolute"

# fixtures[].path glob metacharacter
FXGL="$TMP/fxgl.evals.json"
printf '{"skill_name":"fxgl","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":%s,"fixtures":[{"path":"src/*.ts","content":"x"}]},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$FXGL"
expect_reject "$FXGL" "fxgl" "(fx) fixture path glob metacharacter"

# fixtures[].path ../ escape
FXES="$TMP/fxes.evals.json"
printf '{"skill_name":"fxes","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":%s,"fixtures":[{"path":"../a.ts","content":"x"}]},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$FXES"
expect_reject "$FXES" "fxes" "(fx) fixture path ../ escapes sandbox"

# fixtures[].content empty string
FXEC="$TMP/fxec.evals.json"
printf '{"skill_name":"fxec","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":%s,"fixtures":[{"path":"a.ts","content":""}]},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$FXEC"
expect_reject "$FXEC" "fxec" "(fx) fixture content empty"

# duplicate fixtures[].path (same stage — both default head)
FXDP="$TMP/fxdp.evals.json"
printf '{"skill_name":"fxdp","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":%s,"fixtures":[{"path":"a.ts","content":"x"},{"path":"a.ts","content":"y"}]},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$FXDP"
expect_reject "$FXDP" "fxdp" "(fx) duplicate fixture path (same stage)"

# invalid stage value — must reject, never silently default
FXSV="$TMP/fxsv.evals.json"
printf '{"skill_name":"fxsv","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":%s,"fixtures":[{"path":"a.ts","content":"x","stage":"middle"}]},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$FXSV"
expect_reject "$FXSV" "fxsv" "(fx) invalid stage value"

# positive: same path once as base + once as head (the canonical modified-file diff) MUST pass
FXBH="$TMP/fxbh.evals.json"
printf '{"skill_name":"fxbh","evals":[{"id":1,"prompt":"p","expected_output":"e","files":[],"assertions":%s,"fixtures":[{"path":"a.ts","content":"old","stage":"base"},{"path":"a.ts","content":"new","stage":"head"}]},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$FXBH"
if validate "$FXBH" "fxbh" >/dev/null 2>&1; then
  pass "(fx) same path as base+head accepted (modified-file diff)"
else
  bad "(fx) same path as base+head REJECTED: $(validate "$FXBH" fxbh 2>&1)"
fi

# positive: a files[] entry that names a DECLARED fixture path (absent from the repo)
# MUST pass even when root-resolved existence-checking is active — this is the whole
# point of self-contained corpora.
FXOK="$TMP/fxok.evals.json"
printf '{"skill_name":"fxok","evals":[{"id":1,"prompt":"p","expected_output":"e","files":["src/gen/does-not-exist-in-repo.ts"],"assertions":%s,"fixtures":[{"path":"src/gen/does-not-exist-in-repo.ts","content":"export const x = 1;"}]},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":%s}]}' "$V" "$V" > "$FXOK"
if validate "$FXOK" "fxok" "$ROOT" >/dev/null 2>&1; then
  pass "(fx) files[] naming a declared fixture accepted despite absent-from-repo (root-resolved)"
else
  bad "(fx) files[] naming a declared fixture REJECTED: $(validate "$FXOK" fxok "$ROOT" 2>&1)"
fi

# positive control: a minimal well-formed corpus MUST pass (guards always-fail validator)
GOOD="$TMP/control.evals.json"
printf '{"skill_name":"control","evals":[{"id":1,"prompt":"p","expected_output":"e","files":["skills/x/SKILL.md"],"assertions":["The transcript writes a file and shows the result clearly here"]},{"id":2,"prompt":"p","expected_output":"e","files":[],"assertions":["The transcript commits the change and records a marker in the run log"]}]}' > "$GOOD"
if validate "$GOOD" "control" >/dev/null 2>&1; then
  pass "positive control fixture accepted (validator is not always-fail)"
else
  bad "positive control fixture rejected — validator over-strict: $(validate "$GOOD" control 2>&1)"
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo
echo "----"
echo "validated corpora: $validated (>= $req_count required present)   total evals: $total_evals   heuristic rejections in real corpora: 0"
if [ "$fail" -eq 0 ]; then
  echo "ALL PASSED"
  exit 0
else
  echo "SOME FAILED"
  exit 1
fi
