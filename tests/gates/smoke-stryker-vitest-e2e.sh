#!/usr/bin/env bash
# Whole-feature smoke for RD-121: the scoper's output, run verbatim by real Stryker + Vitest.
#
# Proves what the gate tests cannot: that the generated Vitest config, loaded by vite from inside
# Stryker's sandbox, imports the SANDBOX copy of the workspace config (mutants are killed, none
# "survive" against unmutated originals), that only the co-located tests run (an unrelated test that
# throws would fail the initial run), that a `[id]` path survives include escaping, and that
# run_command goes through the watchdog and ends 0.
#
# Not a test-*.sh: run-all.sh never picks it up, because it installs Stryker and Vitest from the npm
# registry. Run it on the farm when the scoper, its lib or the watchdog changes:
#   TF_HOST=waw-tf rt --light bash tests/gates/smoke-stryker-vitest-e2e.sh
# Exit: 0 SMOKE PASS · 1 SMOKE FAIL · 2 SMOKE NOT RUN (npm or a tool unavailable — never a pass).
# SMOKE_SCOPER=<path> runs another scoper against the same fixture (to show the old one fails).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCOPER="${SMOKE_SCOPER:-$ROOT/scripts/stryker-scoped-config.sh}"
SCOPER="$(cd "$(dirname "$SCOPER")" && pwd)/$(basename "$SCOPER")"  # absolute: the script cd's into the fixture
not_run() { echo "SMOKE NOT RUN: $1"; exit 2; }
for tool in node npm git timeout; do command -v "$tool" >/dev/null 2>&1 || not_run "$tool is not installed"; done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export GIT_CONFIG_GLOBAL=/dev/null  # the fixture's commits must not run the caller's global git hooks
P="$TMP/proj"
mkdir -p "$P/ws/src" "$P/ws2/src"
cd "$P" || exit 1
git init -q -b main . && git config user.email t@t && git config user.name t && git config commit.gpgsign false
cat > package.json <<'EOF'
{"name":"smoke","private":true,"devDependencies":{"vitest":"4.1.11","@stryker-mutator/core":"10.0.0","@stryker-mutator/vitest-runner":"10.0.0"}}
EOF
printf 'node_modules\nreports\n' > .gitignore
# The root config is a multi-project aggregator: handed to Stryker, it would run every project —
# including ws2, whose test imports the scoped code (so `related` keeps it) and throws.
printf "import { defineConfig } from 'vitest/config';\nexport default defineConfig({ test: { projects: ['ws/vitest.config.ts', 'ws2/vitest.config.ts'] } });\n" > vitest.config.ts
printf '{"name":"ws2","private":true}\n' > ws2/package.json
printf "import { defineConfig } from 'vitest/config';\nexport default defineConfig({ test: { include: ['src/**/*.test.ts'] } });\n" > ws2/vitest.config.ts
printf "import { it } from 'vitest';\nimport { add } from '../../ws/src/foo';\nit('another project must never run', () => { add(1, 1); throw new Error('UNRELATED TEST RAN'); });\n" > ws2/src/uses.test.ts
printf '{"name":"ws","private":true}\n' > ws/package.json
cat > ws/vitest.config.ts <<'EOF'
import { defineConfig } from 'vitest/config';
import path from 'path';
export default defineConfig({
  resolve: { alias: { '@': path.resolve(__dirname, 'src') } },
  test: { include: ['src/**/*.test.ts'], coverage: { include: ['src/**'] } },
});
EOF
printf 'export const add = (a: number, b: number) => a + b;\nexport const isPos = (n: number) => n >= 1;\n' > ws/src/foo.ts
cat > ws/src/foo.test.ts <<'EOF'
import { it, expect } from 'vitest';
import { add, isPos } from '@/foo';
it('adds', () => { expect(add(2, 3)).toBe(5); });
it('pos', () => { expect(isPos(1)).toBe(true); expect(isPos(0)).toBe(false); });
EOF
printf "import { it } from 'vitest';\nit('unrelated must never run', () => { throw new Error('UNRELATED TEST RAN'); });\n" > ws/src/other.test.ts
git add -A && git commit -qm base
git checkout -q -b feature
printf 'export const add = (a: number, b: number) => a + b;\nexport const isPos = (n: number) => n > 0;\n' > ws/src/foo.ts
mkdir -p 'ws/src/[id]'
printf 'export const twice = (n: number) => n * 2;\n' > 'ws/src/[id]/bar.ts'
printf "import { it, expect } from 'vitest';\nimport { twice } from './bar';\nit('twice', () => { expect(twice(3)).toBe(6); });\n" > 'ws/src/[id]/bar.test.ts'
git add -A && git commit -qm feature

timeout 600 npm install --no-audit --no-fund --loglevel=error >"$TMP/npm.log" 2>&1 || not_run "npm install failed: $(tail -3 "$TMP/npm.log")"

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
out="$(timeout 120 bash "$SCOPER" --repo "$P" --diff main 2>"$TMP/scope.err")"; rc=$?
kv() { sed -n "s/^$1=//p" <<<"$out"; }
[ "$rc" = 0 ] || { cat "$TMP/scope.err"; echo "SMOKE FAIL: the scoper exited $rc"; exit 1; }
[ "$(kv vitest_root)" = ws ] && ok "scoper: vitest_root=ws (not the root aggregator)" || bad "scoper: vitest_root=$(kv vitest_root)"
[ "$(kv vitest_include_source)" = colocated ] && [ "$(kv vitest_include_count)" = 2 ] \
  && ok "scoper: the two co-located tests, nothing else" \
  || bad "scoper: source=$(kv vitest_include_source) count=$(kv vitest_include_count) include=[$(kv vitest_include | tr '\n' ' ')]"

cmd="$(kv run_command)"
[[ "$cmd" =~ "&& bash ./.stryker-scoped-"[^\ ]+".watchdog.sh --idle-timeout "[0-9]+" -- npx stryker run " ]] \
  && ok "run_command runs npx stryker under the watchdog" || bad "run_command: $cmd"
start=$SECONDS
timeout 900 bash -c "$cmd" >"$TMP/run.log" 2>&1; run_rc=$?
echo "stryker run: exit $run_rc in $((SECONDS - start))s"
[ -s "$TMP/run.log" ] || bad "the Stryker run printed nothing"
grep -q 'UNRELATED TEST RAN' "$TMP/run.log" && bad "a test outside the covering set ran (another project or file)" \
  || ok "no test outside the covering set ran (the other project's and the unrelated file's throwing tests)"
if [ "$run_rc" = 0 ]; then ok "run_command exited 0"; else bad "run_command exited $run_rc"; tail -30 "$TMP/run.log"; fi
counts="$(node -e '
  const r = require(require("path").resolve(process.argv[1])); const c = {};
  for (const f of Object.values(r.files)) for (const m of f.mutants) c[m.status] = (c[m.status] || 0) + 1;
  process.stdout.write(JSON.stringify(c));' "$(kv report_path)" 2>/dev/null)"
echo "mutants: ${counts:-<no report>}"
node -e 'const c = JSON.parse(process.argv[1] || "{}");
  process.exit((c.Killed || 0) >= 2 && Object.keys(c).every((k) => k === "Killed" || k === "Ignored") ? 0 : 1)' "$counts" \
  && ok "every tested mutant killed in the sandbox (no survivor, timeout, error or no-coverage)" \
  || bad "mutant outcome $counts — survivors mean the run tested unmutated originals"

node -e '
  const r = require(require("path").resolve(process.argv[1]));
  const f = Object.entries(r.files).find(([k]) => k.endsWith("[id]/bar.ts"));
  process.exit(f && f[1].mutants.some((m) => m.status === "Killed") ? 0 : 1);' "$(kv report_path)" 2>/dev/null \
  && ok "the [id]/bar.ts mutants were killed: its escaped include reached Vitest" \
  || bad "no killed mutant in [id]/bar.ts — its co-located test did not run"

if [ "$fail" = 0 ]; then echo "SMOKE PASS"; exit 0; fi
echo "SMOKE FAIL"; exit 1
