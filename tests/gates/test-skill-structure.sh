#!/usr/bin/env bash
# Locks the two defect classes that check-skill-structure.py exists to catch.
#
# Both got past careful manual reading of the same files, more than once:
#
#   1. A code fence closed in the WRONG PLACE still passes a parity count of
#      ```. Eight skills had their '### Retrospective (REQUIRED)' section — the
#      retro protocol, the append-runlog mandate, the VERDICT mapping — sitting
#      INSIDE the completion block's fence, where it renders as sample output to
#      print rather than an instruction to follow. Those are precisely the steps
#      the retro-gate enforces, so a skill could reach COMPLETE with all three
#      log files empty (commit 4683f85).
#
#   2. A duplicate ordinal in a Mandatory File Loading list is cosmetic. What it
#      hid is not: content-fix, geo-fix, seo-fix and structure-audit printed a
#      file as READ in their CORE FILES LOADED block that the prose list above
#      never told the agent to open — including no-pause-protocol.md, the HARD
#      rule against mid-batch pauses (commit 682d26e).
#
# The tests below feed the checker synthetic skills so a future refactor of the
# checker cannot silently stop detecting either class. They also lock the two
# false-positive classes that cost real triage time, because a linter that cries
# wolf gets ignored and then it protects nothing.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHK="$ROOT/scripts/check-skill-structure.py"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

[ -f "$CHK" ] || { bad "check-skill-structure.py missing"; echo "SOME FAILED"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Build a throwaway tree the checker can scan: it resolves its root from its own
# location, so the copy under $TMP/scripts scans $TMP/skills.
mkdir -p "$TMP/scripts" "$TMP/skills"
cp "$CHK" "$TMP/scripts/"

reset_tree() { rm -rf "$TMP/skills"; mkdir -p "$TMP/skills"; }
mkskill() { mkdir -p "$TMP/skills/$1"; cat > "$TMP/skills/$1/SKILL.md"; }
run_chk() { python3 "$TMP/scripts/check-skill-structure.py" 2>&1; }

# expect_detect <label> <grep-pattern>   — checker must exit nonzero and match
expect_detect() {
  local label="$1" pat="$2" out
  out="$(run_chk)"
  if [ $? -eq 0 ]; then
    bad "$label: checker passed a tree that should fail"
  elif printf '%s' "$out" | grep -q "$pat"; then
    pass "$label"
  else
    bad "$label: failed, but not for the expected reason. Got: $out"
  fi
}

expect_clean() {
  local label="$1" out
  if out="$(run_chk)"; then
    pass "$label"
  else
    bad "$label: checker flagged a legitimate construct. Got: $out"
  fi
}

# ---------- 1. unclosed Run-line fence swallows the retro instruction ----------
reset_tree
mkskill swallowed <<'EOF'
# zuvo:swallowed
## Completion
```
DONE
Run: <ISO>	swallowed	<p>	-	-	<V>	-	-	-	-	-	-	-

### Retrospective (REQUIRED)

Follow the retrospective protocol.
```
EOF
expect_detect "unclosed Run-line fence swallows '### Retrospective (REQUIRED)'" "Retrospective"

# ---------- 2. same-length nested fence inverts every later fence ----------
# db-audit's shape: an outer report template wraps a ```bash example. The
# example's closer silently closes the OUTER template, so the template's own
# closer becomes an OPENER and every fence after it is inverted — dragging the
# next real section heading inside a block.
reset_tree
mkskill nested <<'EOF'
# zuvo:nested
## Output: Report
```markdown
# Report

### Example
```bash
echo hi
```
trailing template text
```

## Phase 9: Wrap Up
Do the thing.
```
EOF
expect_detect "same-length nested fence leaves '## Phase 9' inside the block" "Phase 9"

# ---------- 3. a fence never closed at all ----------
reset_tree
mkskill dangling <<'EOF'
# zuvo:dangling
## Output
```
never closed
EOF
expect_detect "fence open at EOF" "never closed"

# ---------- 4. duplicate ordinal in a loading list ----------
reset_tree
mkskill dupnum <<'EOF'
# zuvo:dupnum
## Mandatory File Loading
1. `../../shared/includes/env-compat.md` -- a
2. `../../shared/includes/run-logger.md` -- b
2. `../../shared/includes/retrospective.md` -- c
EOF
expect_detect "duplicate ordinal in loading list" "expected \[1, 2, 3\]"

# ---------- 5. printed as READ but never listed to read ----------
reset_tree
mkskill ghostread <<'EOF'
# zuvo:ghostread
## Mandatory File Loading
1. `../../shared/includes/env-compat.md` -- a
2. `../../shared/includes/run-logger.md` -- b
3. `../../shared/includes/retrospective.md` -- c

```
CORE FILES LOADED:
  1. env-compat.md      -- [READ | MISSING -> STOP]
  2. run-logger.md      -- [READ | MISSING -> STOP]
  3. retrospective.md   -- [READ | MISSING -> STOP]
  4. no-pause-protocol.md -- [READ | MISSING -> STOP]
```
EOF
expect_detect "file printed as READ with no prose entry" "no-pause-protocol.md"

# ---------- 6. second list colliding with the first ----------
reset_tree
mkskill collide <<'EOF'
# zuvo:collide
## Mandatory File Loading
1. `../../shared/includes/env-compat.md` -- a
2. `../../shared/includes/run-logger.md` -- b
3. `../../shared/includes/retrospective.md` -- c

**Stage 2:**
3. `../../shared/includes/backlog-protocol.md` -- d
4. `../../shared/includes/knowledge-prime.md` -- e
5. `../../shared/includes/knowledge-curate.md` -- f
EOF
expect_detect "second list restarting mid-range" "collides"

# ---------- FALSE-POSITIVE GUARDS ----------

# 7. Headings that belong to an emitted TEMPLATE are legitimate inside a fence.
# brainstorm writes a design-spec containing '## Adversarial Review' and
# '### Edge Cases'; flagging those would train everyone to ignore this check.
reset_tree
mkskill template <<'EOF'
# zuvo:template
## Spec Structure
```markdown
# <Feature> -- Design Specification

### Edge Cases
[each edge case]

## Adversarial Review
[provider verdicts]
```
EOF
expect_clean "template headings inside a fence are not flagged"

# 8. A two-stage loading list that CONTINUES (1-2 then 3-5) is correct — that is
# how infra-audit, pentest and brainstorm defer their late-loaded files.
reset_tree
mkskill twostage <<'EOF'
# zuvo:twostage
## Mandatory File Loading
```
  1. ../../shared/includes/env-compat.md    -- [READ | MISSING -> STOP]
  2. ../../shared/includes/codesift-setup.md -- [READ | MISSING -> STOP]
```
**Stage 2 -- before report writing:**
```
  3. ../../shared/includes/run-logger.md    -- [READ | MISSING -> STOP]
  4. ../../shared/includes/retrospective.md -- [READ | MISSING -> STOP]
  5. ../../shared/includes/backlog-protocol.md -- [READ | MISSING]
```
EOF
expect_clean "continuing two-stage loading list is not a collision"

# 9. Re-displaying a deferred list at its point of use is not a second list.
# a11y-audit reprints its Stage 2 block verbatim under Phase 5.
reset_tree
mkskill redisplay <<'EOF'
# zuvo:redisplay
## Mandatory File Loading
```
  1. ../../shared/includes/env-compat.md    -- [READ | MISSING -> STOP]
  2. ../../shared/includes/codesift-setup.md -- [READ | MISSING -> STOP]
```
**Stage 2:**
```
  3. ../../shared/includes/run-logger.md    -- [READ | MISSING -> STOP]
  4. ../../shared/includes/retrospective.md -- [READ | MISSING -> STOP]
  5. ../../shared/includes/backlog-protocol.md -- [READ | MISSING]
```
## Phase 5: Report
Read deferred files:
```
  3. ../../shared/includes/run-logger.md    -- [READ | MISSING -> STOP]
  4. ../../shared/includes/retrospective.md -- [READ | MISSING -> STOP]
  5. ../../shared/includes/backlog-protocol.md -- [READ | MISSING]
```
EOF
expect_clean "verbatim re-display of a deferred list is not a collision"

# 10. A placeholder path segment must not SPLIT a list — excluding it made
# write-article's single 1-12 list read as 1-3 then 5-12, i.e. a false collision.
reset_tree
mkskill placeholder <<'EOF'
# zuvo:placeholder
## Mandatory File Loading
1. `../../shared/includes/env-compat.md` -- a
2. `../../shared/includes/run-logger.md` -- b
3. `../../shared/includes/banned-vocabulary/core.md` -- c
4. `../../shared/includes/banned-vocabulary/languages/<resolved-lang>.md` -- d
5. `../../shared/includes/retrospective.md` -- e
6. `../../shared/includes/no-pause-protocol.md` -- f
EOF
expect_clean "placeholder path segment does not split a loading list"

# ---------- 11. the real corpus must be clean ----------
if out=$(python3 "$CHK" 2>&1); then
  pass "live skills/ corpus passes ($(printf '%s' "$out" | tail -1))"
else
  bad "live skills/ corpus has structural errors:"
  printf '%s\n' "$out"
fi

echo "=== RESULT ==="
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "SOME FAILED"; exit 1
