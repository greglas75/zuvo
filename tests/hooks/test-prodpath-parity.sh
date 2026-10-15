#!/usr/bin/env bash
# zuvo_review_prodpath.is_production (Python: escapes, curate's per-kloc denominator) must never call
# PRODUCTION a path that hooks/lib/pipeline-gate-lib.sh's pg_is_production (the push gate) calls
# non-production — otherwise the rates count lines the gate never asks anyone to review.
#   1. the bash case patterns and the module's BASH_PATTERNS are the same list (bash gains an
#      exemption -> this fails until Python learns it);
#   2. a path table: bash non-production => Python non-production;
#   3. the extras Python adds really are extras (bash production, Python not) — a stale table entry
#      bash already covers would otherwise look like coverage.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/hooks/lib/pipeline-gate-lib.sh"
MOD_DIR="$ROOT/scripts/zuvo-home"
PASS=0; FAIL=0
command_not_found_handle(){ echo "  FAIL harness: unknown command '$1'"; FAIL=$((FAIL+1)); return 127; }
ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

# shellcheck source=/dev/null
. "$LIB"
py(){ PYTHONPATH="$MOD_DIR" python3 -c "$1" "${@:2}"; }

# --- 1. pattern lists -------------------------------------------------------------------------
# Every code line of the case block must be a `<patterns>) return 1 ;;` arm, except ONE final
# `*) return 0 ;;`. Any other arm (a `return 0` exemption, a multi-line arm) is a rule the
# extraction below cannot see, so Python would silently stop mirroring the gate.
ARMS="$(awk '/^pg_is_production\(\) \{/{f=1; next} f && /^\}/{exit}
  f && /case "\$p" in/{c=1; next} c && /^[ \t]*esac/{c=0}
  c && !/^[ \t]*(#|$)/ { sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print }' "$LIB")"
ODD="$(printf '%s\n' "$ARMS" | sed '$d' | grep -vE '^[^)]+\)[[:space:]]+return 1 ;;$' || true)"
LAST="$(printf '%s\n' "$ARMS" | tail -n 1)"
if [ -z "$ODD" ] && printf '%s\n' "$LAST" | grep -qE '^\*\)[[:space:]]+return 0 ;;$'; then
  ok "pg_is_production is only 'return 1' arms then one catch-all 'return 0'"
else
  no "pg_is_production has an arm this parity check cannot mirror: ${ODD:-last arm '$LAST'}"
fi
BASH_PATS="$(awk '/^pg_is_production\(\) \{/{f=1; next} f && /^\}/{exit}
  f && /return 1 ;;/ { sub(/^[ \t]+/, ""); sub(/\)[ \t]+return 1 ;;.*/, ""); n=split($0, a, "|");
                       for (i=1; i<=n; i++) print a[i] }' "$LIB")"
PY_PATS="$(py 'import zuvo_review_prodpath as m; print("\n".join(m.BASH_PATTERNS))')"
[ "$(printf '%s\n' "$BASH_PATS" | grep -c .)" -ge 20 ] && ok "extracted $(printf '%s\n' "$BASH_PATS" | grep -c .) bash patterns" \
  || no "pattern extraction broken: '$BASH_PATS'"
if [ "$BASH_PATS" = "$PY_PATS" ]; then
  ok "BASH_PATTERNS == pg_is_production's case patterns (order included)"
else
  no "pattern drift between pg_is_production and BASH_PATTERNS:"
  diff <(printf '%s\n' "$BASH_PATS") <(printf '%s\n' "$PY_PATS") | sed 's/^/      /'
fi

# --- 2. bash non-production => python non-production ------------------------------------------
TABLE=(
  tests/a.sh pkg/tests/b.py __tests__/x.ts src/__tests__/y.tsx a.test.ts src/b.spec.js docs/x.txt
  pkg/docs/y.html README.md a/b.md package.json cfg.yaml c.yml pyproject.toml yarn.lock .eslintrc
  web/.prettierrc zuvo/plans/p.txt x/zuvo/y.txt .zuvo/proofs/a.txt a/.zuvo/b.txt VERSION pkg/VERSION
  CHANGELOG LICENSE sub/LICENCE NOTICE AUTHORS CONTRIBUTORS .github/workflows/src ""
  src/app.ts scripts/zuvo-home/bill Makefile CODEOWNERS hooks/x.sh
  memory/findings/a.jsonl x/memory/findings/b.jsonl memory/findings/evil.py
)
py_verdicts="$(py 'import sys, zuvo_review_prodpath as m; print("\n".join("1" if m.is_production(p) else "0" for p in sys.argv[1:]))' "${TABLE[@]}")"
i=0; drift=0; checked=0
while IFS= read -r pv; do
  p="${TABLE[$i]}"; i=$((i+1))
  if ! pg_is_production "$p"; then
    checked=$((checked+1))
    [ "$pv" = 0 ] || { no "bash non-production but Python production: '$p'"; drift=1; }
  fi
done <<< "$py_verdicts"
[ "$i" -eq "${#TABLE[@]}" ] || no "python answered $i of ${#TABLE[@]} paths"
[ "$drift" -eq 0 ] && ok "$checked bash non-production paths are non-production in Python"
# an over-broad extra (`*test*`, `test*/`) would make every file non-production and every rate null
# ...and a config/fixture module that is application code (inside src/, or only named like one) stays
for p in src/app.ts scripts/zuvo-home/bill Makefile CODEOWNERS src/latest.py src/contest.py \
         app/testimonials/page.tsx build.gradle.kts hooks/lib/x.sh src/config/app.ts apps/api/src/config.ts \
         packages/x/src/fixture-loader.ts apps/api/src/auth/auth-cache.config.ts src/cookie.config.ts \
         apps/api/src/modules/ci-report.ts apps/web/src/e2e-banner.tsx; do
  pv="$(py 'import sys, zuvo_review_prodpath as m; print(int(m.is_production(sys.argv[1])))' "$p")"
  pg_is_production "$p" && [ "$pv" = 1 ] && ok "production in both: $p" || no "not production in both: $p"
done

# --- 3. the extras are real extras ------------------------------------------------------------
EXTRAS=(go.sum web/dist/app.js a/vendor/lib.php node_modules/x/i.js x.min.js x.min.css app.js.map
  src/__snapshots__/a.snap api/x.pb.go svc/x_pb2.py src/__generated__/types.ts lib/x.g.dart
  src/api.generated.ts bun.lockb test/unit/a.js pkg/a_test.go test_parser.py pkg/parser_test.py
  src/__fixtures__/a.json5 spec/models/user_spec.rb
  e2e/helpers/login.ts apps/designer/e2e/pages/editor.ts src/a.fixture.ts src/b.fixtures.ts
  apps/api/src/modules/help/fixtures/manifest.ts stryker.conf.mjs apps/api/vitest.config.ts
  apps/web/playwright.config.ts tools/stryker.scoped.conf.mjs scripts/ci/bb-merge-pr.sh
  .github/actions/setup/index.js ci/deploy.sh)
for p in "${EXTRAS[@]}"; do
  pv="$(py 'import sys, zuvo_review_prodpath as m; print(int(m.is_production(sys.argv[1])))' "$p")"
  if pg_is_production "$p" && [ "$pv" = 0 ]; then ok "extra: $p"
  else no "not an extra (bash non-production already, or Python production): $p"; fi
done

echo "  --- prodpath parity: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
