#!/bin/bash
# Validates website/skills/*.yaml files against spec requirements
# Spec: docs/specs/2026-03-29-skill-seo-pages-spec.md

set -euo pipefail

SKILLS_DIR="website/skills"
EXPECTED_COUNT=41
ERRORS=0

echo "=== Zuvo Skill SEO Page Validator ==="
echo ""

# 1. Count files (excluding _schema.yaml)
ACTUAL=$(ls "$SKILLS_DIR"/*.yaml 2>/dev/null | grep -v _schema | wc -l | tr -d ' ')
if [ "$ACTUAL" != "$EXPECTED_COUNT" ]; then
  echo "FAIL: Expected $EXPECTED_COUNT YAML files, found $ACTUAL"
  ERRORS=$((ERRORS + 1))
else
  echo "OK: $ACTUAL YAML files found"
fi

# 2. Check each file has required top-level keys
echo ""
echo "--- Required Keys ---"
for f in "$SKILLS_DIR"/*.yaml; do
  [[ "$f" == *"_schema"* ]] && continue
  slug=$(basename "$f" .yaml)

  for key in schema_version last_synced meta stats problem how_it_works \
             examples when_to_use when_not_to_use related_skills faq arguments; do
    if ! grep -q "^${key}:" "$f" 2>/dev/null; then
      echo "FAIL: $slug.yaml missing required key: $key"
      ERRORS=$((ERRORS + 1))
    fi
  done
done
echo "OK: Required keys check complete"

# 3. Check last_synced is present and non-empty
echo ""
echo "--- last_synced ---"
for f in "$SKILLS_DIR"/*.yaml; do
  [[ "$f" == *"_schema"* ]] && continue
  slug=$(basename "$f" .yaml)
  if ! grep -q "^last_synced:" "$f" 2>/dev/null; then
    echo "FAIL: $slug.yaml missing last_synced field"
    ERRORS=$((ERRORS + 1))
  fi
done
echo "OK: last_synced check complete"

# 4. Check meta.description length (< 155 chars)
echo ""
echo "--- Description Length ---"
for f in "$SKILLS_DIR"/*.yaml; do
  [[ "$f" == *"_schema"* ]] && continue
  slug=$(basename "$f" .yaml)
  # Extract description value (handles both quoted and unquoted)
  desc=$(grep "  description:" "$f" | head -1 | sed 's/.*description: *//' | sed 's/^"//' | sed 's/"$//')
  len=${#desc}
  if [ "$len" -gt 155 ]; then
    echo "FAIL: $slug.yaml meta.description is $len chars (max 155)"
    ERRORS=$((ERRORS + 1))
  fi
done
echo "OK: Description length check complete"

# 5. Check title uniqueness
echo ""
echo "--- Title Uniqueness ---"
titles=$(grep "  title:" "$SKILLS_DIR"/*.yaml | grep -v _schema | sed 's/.*title: *//' | sort)
dupes=$(echo "$titles" | uniq -d)
if [ -n "$dupes" ]; then
  echo "FAIL: Duplicate titles found:"
  echo "$dupes"
  ERRORS=$((ERRORS + 1))
else
  echo "OK: All titles unique"
fi

# 6. Check description uniqueness
echo ""
echo "--- Description Uniqueness ---"
# ANCHORED to exactly two spaces: this rule polices meta.description only. An
# unanchored `grep "  description:"` also matches argument- and mode-level
# descriptions nested deeper in the file, where two skills legitimately share
# wording ("Apply only fixes of the specified fix_type categories") -- which is
# how this check reported four false duplicates.
# The filename prefix is kept until after _schema is filtered out -- `grep -h`
# would drop it and the `grep -v _schema` would then match on description TEXT
# instead of the path, silently letting the schema file back in.
descs=$(grep "^  description:" "$SKILLS_DIR"/*.yaml | grep -v _schema | sed 's/.*description: *//' | sort)
desc_dupes=$(echo "$descs" | uniq -d)
if [ -n "$desc_dupes" ]; then
  echo "FAIL: Duplicate descriptions found:"
  echo "$desc_dupes"
  ERRORS=$((ERRORS + 1))
else
  echo "OK: All descriptions unique"
fi

# 7. Check cross-reference slugs are in allow-list
echo ""
echo "--- Cross-Reference Integrity ---"
ALLOW_LIST="api-audit architecture backlog brainstorm build canary ci-audit code-audit db-audit debug deploy dependency-audit design design-review docs env-audit execute fix-tests pentest performance-audit plan presentation receive-review refactor release-docs retro review security-audit seo-audit seo-fix ship structure-audit test-audit tests-performance ui-design-team using-zuvo worktree write-e2e write-tests geo-audit geo-fix"

for f in "$SKILLS_DIR"/*.yaml; do
  [[ "$f" == *"_schema"* ]] && continue
  slug=$(basename "$f" .yaml)
  # Fed by process substitution, NOT a pipe: a pipe runs the loop in a subshell,
  # so ERRORS incremented inside it is discarded and the script prints
  # "FAIL: ... unknown slug" and "PASS: all files validated" in the same run,
  # exiting 0. This check was advisory-only for exactly that reason.
  while read -r ref_slug; do
    [ -n "$ref_slug" ] || continue
    # Exact whole-token match, NOT `grep -qw`: grep's word boundary treats `-`
    # as a separator, so `audit` matches inside `code-audit` and `tests` inside
    # `write-tests` — every hyphenated slug in the list acts as a wildcard for
    # its own fragments. That made a reference to a NONEXISTENT slug pass. The
    # space-padded case match compares whole tokens and has no such hole.
    case " $ALLOW_LIST " in
      *" $ref_slug "*) ;;
      *)
        echo "FAIL: $slug.yaml references unknown slug: $ref_slug"
        ERRORS=$((ERRORS + 1))
        ;;
    esac
  done < <(grep "  - slug:" "$f" 2>/dev/null | sed 's/.*slug: *//')
done
echo "OK: Cross-reference check complete"

# 8. Check array cardinality: faq (min 3), stats (min 3)
echo ""
echo "--- Array Cardinality ---"
for f in "$SKILLS_DIR"/*.yaml; do
  [[ "$f" == *"_schema"* ]] && continue
  slug=$(basename "$f" .yaml)

  faq_count=$(grep -c "  - q:" "$f" 2>/dev/null || echo 0)
  if [ "$faq_count" -lt 3 ]; then
    echo "FAIL: $slug.yaml has only $faq_count FAQ entries (min 3)"
    ERRORS=$((ERRORS + 1))
  fi

  stats_count=$(grep -c "  - label:" "$f" 2>/dev/null || echo 0)
  if [ "$stats_count" -lt 3 ]; then
    echo "FAIL: $slug.yaml has only $stats_count stat cards (min 3)"
    ERRORS=$((ERRORS + 1))
  fi
done
echo "OK: Array cardinality check complete"

# 9. Check category is valid enum
echo ""
echo "--- Category Enum ---"
VALID_CATEGORIES="audit task pipeline utility design release"
for f in "$SKILLS_DIR"/*.yaml; do
  [[ "$f" == *"_schema"* ]] && continue
  slug=$(basename "$f" .yaml)
  cat=$(grep "  category:" "$f" | head -1 | sed 's/.*category: *//')
  if ! echo "$VALID_CATEGORIES" | grep -qw "$cat"; then
    echo "FAIL: $slug.yaml has invalid category: $cat"
    ERRORS=$((ERRORS + 1))
  fi
done
echo "OK: Category enum check complete"

# Summary
echo ""
echo "=== Summary ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "PASS: All $EXPECTED_COUNT skill YAML files validated successfully"
  exit 0
else
  echo "FAIL: $ERRORS validation errors found"
  exit 1
fi
