#!/usr/bin/env bash
# test-reviewer-lanes.sh — a plain-bash smoke of scripts/lib/reviewer-lanes.sh, the reviewer-lane grammar
# install.sh and all four non-Claude builds source.
#
# Test level: SMALL — the library sourced into this shell, its functions called on files in one temp dir.
# No build, no install, no network.
#
# Why it exists: the library's full matrix lives in scripts/tests/reviewer-model-builds.bats, and
# tests/run-all.sh SKIPs every .bats file on a machine without bats (the farm has none). This file needs
# only bash, so the helpers every build gates its agents through are exercised there too. It is a smoke:
# one or two cases per helper — its contract's statuses and the message a caller prints — not the matrix.
#
# Run (bash 3.2 and 5.x):
#   TF_ALLOW_LOCAL=1 bash tests/hooks/test-reviewer-lanes.sh
#   TF_ALLOW_LOCAL=1 /bin/bash tests/hooks/test-reviewer-lanes.sh
# ZRL_LIB_UNDER_TEST points it at another copy of the library (a RED run against an older revision);
# model-subprocess.sh must sit beside that copy, as it does wherever the library ships.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd -P)"
LIB="${ZRL_LIB_UNDER_TEST:-$ROOT/scripts/lib/reviewer-lanes.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
# is <label> <want> <got> — string equality, both shown on a miss.
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$2], got [$3])"; fi; }
# st <label> <want-status> <cmd...> — the command's exit status; its output is discarded.
st() {
  local label="$1" want="$2" rc=0
  shift 2
  "$@" >/dev/null 2>&1 || rc=$?
  is "$label" "$want" "$rc"
}
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no [$3] in [$2])" ;; esac; }

T="$(mktemp -d "${TMPDIR:-/tmp}/zrl-smoke.XXXXXX")" || { echo "  FAIL mktemp -d"; exit 1; }
cleanup() { case "$T" in */zrl-smoke.*) chmod -R u+rw "$T" 2>/dev/null; rm -rf "$T" ;; esac; }
trap cleanup EXIT

echo "== the library loads, and defines everything it lists"
# shellcheck source=scripts/lib/reviewer-lanes.sh
if . "$LIB"; then ok "reviewer-lanes.sh sources (status 0)"; else bad "reviewer-lanes.sh sources (status 0)"; echo "  --- reviewer-lanes: PASS=$PASS FAIL=$FAIL"; exit 1; fi
st "zrl_require_fns: every function of ZRL_FUNCS is defined" 0 zrl_require_fns "$LIB"
st "zrl_require_fns: a function the caller names and the library lacks is status 1" 1 zrl_require_fns "$LIB" zrl_no_such_function
has "zrl_require_fns: …and it is named on stderr" "$(zrl_require_fns "$LIB" zrl_no_such_function 2>&1)" "zrl_no_such_function is not defined after sourcing"
# The id alphabet has one definition, in model-subprocess.sh; this library keeps no copy or alias of it.
if [ -z "${ZRL_ID_ALNUM+x}" ]; then ok "the library defines no id alphabet of its own (no ZRL_ID_ALNUM)"; else bad "the library defines no id alphabet of its own (ZRL_ID_ALNUM is set)"; fi
is "zrl_is_model_id is zms_is_model_id: gpt-6-sol accepted" 0 "$(zrl_is_model_id gpt-6-sol; echo $?)"
is "zrl_is_model_id: 'a b', '-x' and '' refused" "1 1 1" "$(zrl_is_model_id 'a b'; printf '%s ' $?; zrl_is_model_id -x; printf '%s ' $?; zrl_is_model_id ''; echo $?)"

echo "== grammar: route words and the model values a build accepts"
st "zrl_is_route_word: review-primary" 0 zrl_is_route_word review-primary
st "zrl_is_route_word: any letter case (Cross-Vendor)" 0 zrl_is_route_word Cross-Vendor
st "zrl_is_route_word: review-primary-test is one token and no lane" 1 zrl_is_route_word review-primary-test
for v in haiku sonnet opus review-primary review-alt '"per-task: sonnet for standard complexity, opus for complex"' "'per-task: x'"; do
  st "zrl_agent_model_known accepts: $v" 0 zrl_agent_model_known "$v"
done
for v in '' gpt-weird cross-vendor '"review-alt"' "'sonnet'" 'sonnet extra' per-task '[review-alt]' 'x,review-alt' \
         '"per-task: review-primary"' '"per-task: x" y"' '"per-task: use the Review-Alt lane"'; do
  st "zrl_agent_model_known refuses: [$v]" 1 zrl_agent_model_known "$v"
done
# The descriptor's tokens are split on blanks whatever IFS the caller has.
is "zrl_agent_model_known under IFS=, still refuses a route word in a descriptor" 1 \
  "$(IFS=,; zrl_agent_model_known '"per-task: review-primary"'; echo $?)"

echo "== the strict rewriter"
printf '%s\n' '---' 'name: a' 'model: review-primary' '---' 'model: review-alt stays: this is the body' > "$T/a.md"
is "zrl_rewrite_lanes: the frontmatter lane becomes the id, the body line is left alone" \
  "$(printf '%s\n' '---' 'name: a' 'model: gpt-p' '---' 'model: review-alt stays: this is the body')" \
  "$(zrl_rewrite_lanes gpt-p gpt-a < "$T/a.md")"
is "zrl_rewrite_lanes: review-alt, with a trailing comment kept as written" "model: gpt-a # was opus" \
  "$(printf '%s\n' '---' 'model: review-alt # was opus' '---' | zrl_rewrite_lanes gpt-p gpt-a | sed -n 2p)"
is "zrl_rewrite_lanes: review-primary-test is not a lane" "model: review-primary-test" \
  "$(printf '%s\n' '---' 'model: review-primary-test' '---' | zrl_rewrite_lanes gpt-p gpt-a | sed -n 2p)"
st "zrl_rewrite_lanes: an id that is not one model id is status 2" 2 zrl_rewrite_lanes 'bad id' gpt-a
cp "$T/a.md" "$T/b.md"
st "zrl_rewrite_lanes_file: rewrites in place (status 0)" 0 zrl_rewrite_lanes_file gpt-p gpt-a "$T/b.md"
is "zrl_rewrite_lanes_file: the file now names the id" "model: gpt-p" "$(sed -n 3p "$T/b.md")"
is "zrl_rewrite_lanes_file: no temp file is left beside it" "" "$(cd "$T" && ls -A | awk '/^\.zrl\./')"
st "zrl_rewrite_lanes_file: a path that is not a file is status 1" 1 zrl_rewrite_lanes_file gpt-p gpt-a "$T/none.md"

echo "== the strict reader and the BOM/CRLF-normalised agent read"
is "zrl_frontmatter_model: the value, comment and blanks removed" "opus" \
  "$(printf '%s\n' '---' 'model: opus   # was sonnet' '---' > "$T/c.md"; zrl_frontmatter_model "$T/c.md")"
printf '%s\n' '---' 'name: x' '---' > "$T/nokey.md"
st "zrl_frontmatter_model: a frontmatter with no model key is status 1" 1 zrl_frontmatter_model "$T/nokey.md"
st "zrl_frontmatter_model: a missing file is status 2" 2 zrl_frontmatter_model "$T/missing.md"
is "zrl_strip_bom_crlf: the BOM and every CR go, nothing else" "$(printf -- '---\nmodel: x\n')" \
  "$(printf '\357\273\277---\r\nmodel: x\r\n' | zrl_strip_bom_crlf)"
printf '\357\273\277---\r\nname: bom\r\ndescription: an agent\r\nmodel: review-alt\r\n---\r\nBody.\r\n' > "$T/bom.md"
is "zrl_read_agent_model: a BOM + CRLF agent reads as its plain value" "review-alt" "$(zrl_read_agent_model "$T/bom.md")"
st "zrl_read_agent_model: a missing file is status 2 (unreadable)" 2 zrl_read_agent_model "$T/missing.md"
st "zrl_read_agent_model: a directory is status 2 (unreadable), never a temp failure" 2 zrl_read_agent_model "$T"
# The temp copy cannot be WRITTEN (mktemp hands back a read-only file — the shape of a full disk): that is
# a fault of the build's environment. It used to come back as 2, "could not be read", blaming the agent.
if [ "$(id -u)" -eq 0 ]; then
  echo "  SKIP the temp-write cases: root writes through a read-only file mode"
else
  ( mktemp() { local t; t="$(command mktemp "$T/ro.XXXXXX")" || return 1; chmod 444 "$t"; printf '%s\n' "$t"; }
    rc=0; zrl_read_agent_model "$T/bom.md" >/dev/null 2>&1 || rc=$?; exit "$rc" ); rc=$?
  is "zrl_read_agent_model: a temp copy that cannot be written is status 4, not 2 (unreadable)" 4 "$rc"
  out="$( mktemp() { local t; t="$(command mktemp "$T/ro.XXXXXX")" || return 1; chmod 444 "$t"; printf '%s\n' "$t"; }
          zrl_agent_gate Smoke "$T/bom.md" 2>&1; echo "rc=$?" )"
  has "zrl_agent_gate: …and the gate says so: a temp copy, the file itself is readable" "$out" "could not make or write a temp copy of $T/bom.md"
  has "zrl_agent_gate: …refusing the agent (status 1)" "$out" "rc=1"
  case "$out" in *"could not be read for its"*) bad "zrl_agent_gate: a temp-write failure is not reported as an unreadable agent" ;; *) ok "zrl_agent_gate: a temp-write failure is not reported as an unreadable agent" ;; esac
  ( mktemp() { return 1; }; rc=0; zrl_read_agent_model "$T/bom.md" >/dev/null 2>&1 || rc=$?; exit "$rc" ); rc=$?
  is "zrl_read_agent_model: no temp file at all is status 4 too" 4 "$rc"
fi

echo "== the per-agent gate"
rc=0; zrl_agent_gate Smoke "$T/bom.md" >/dev/null 2>&1 || rc=$?
is "zrl_agent_gate: an agent with a lane is accepted (status 0)" 0 "$rc"
is "zrl_agent_gate: …and ZRL_AGENT_MODEL holds its value" "review-alt" "${ZRL_AGENT_MODEL:-}"
printf '%s\n' '# Column definitions' '' 'a registry kept beside the agents' > "$T/data.md"
rc=0; zrl_agent_gate Smoke "$T/data.md" >/dev/null 2>&1 || rc=$?
is "zrl_agent_gate: a data file with no readable model is status 10 (the caller skips it)" 10 "$rc"
printf '%s\n' '---' 'name: n' 'description: an agent' '---' 'Body.' > "$T/nomodel.md"
out="$(zrl_agent_gate Smoke "$T/nomodel.md" 2>&1; echo "rc=$?")"
has "zrl_agent_gate: an agent with a description and no model is refused by name" "$out" "$T/nomodel.md has no readable \`model:\`"
has "zrl_agent_gate: …naming the build, status 1" "$out" "the Smoke build does not guess one"
printf '%s\n' '---' 'name: n' 'description: an agent' 'model: gpt-weird' '---' 'Body.' > "$T/weird.md"
out="$(zrl_agent_gate Smoke "$T/weird.md" 2>&1; echo "rc=$?")"
has "zrl_agent_gate: a value outside the grammar is refused, quoted once" "$out" "$T/weird.md: model value 'gpt-weird' is not one the Smoke build accepts"
has "zrl_agent_gate: …status 1" "$out" "rc=1"
out="$(zrl_agent_gate Smoke "$T/missing.md" 2>&1; echo "rc=$?")"
has "zrl_agent_gate: a missing agent file 'could not be read', status 1" "$out" "$T/missing.md could not be read for its \`model:\`"

echo "== the lenient validators"
mkdir -p "$T/tree/rules" "$T/tree/skills"
printf '%s\n' '---' 'Model : "Review-Alt"' '---' 'body' > "$T/tree/rules/lane.md"
printf '%s\n' '---' 'model: opus # was review-alt' '---' 'model: review-alt in the body is prose' > "$T/tree/skills/clean.md"
printf '%s\n' '---' 'model: |' '  review-alt' '---' > "$T/tree/skills/block.md"
out="$(zrl_scan_md "$T/tree" 2>&1)"; rc=$?
is "zrl_scan_md: the scan ran (status 0)" 0 "$rc"
has "zrl_scan_md: a quoted, spaced, mixed-case lane key is a hit" "$out" "$T/tree/rules/lane.md:2:Model : \"Review-Alt\""
has "zrl_scan_md: a value it cannot parse fails closed" "$out" "block.md:2:model: |  [model value not parsed - failing closed]"
case "$out" in *clean.md*) bad "zrl_scan_md: a lane in a comment or in the body is not a hit" ;; *) ok "zrl_scan_md: a lane in a comment or in the body is not a hit" ;; esac
is "zrl_count_refs: two hits" 2 "$(zrl_count_refs "$out")"
is "zrl_count_refs: no hit is 0" 0 "$(zrl_count_refs "")"
is "zrl_show_refs: indents each hit" 2 "$(zrl_show_refs "$out" '    ' | awk '/^    \// { n++ } END { print n + 0 }')"
st "zrl_scan_md: no path is status 2" 2 zrl_scan_md
st "zrl_scan_md: a missing path is status 2" 2 zrl_scan_md "$T/tree/nothing"
mkdir -p "$T/empty"
st "zrl_scan_md: a tree with no .md is status 2 (the caller expected some)" 2 zrl_scan_md "$T/empty"
rc=0; zrl_scan_and_report_lanes Smoke "$T/tree" >/dev/null 2>&1 || rc=$?
is "zrl_scan_and_report_lanes: its status is the number of leftover references (2)" 2 "$rc"
has "zrl_scan_and_report_lanes: …reported in the builds' one wording" "$(zrl_scan_and_report_lanes Smoke "$T/tree" 2>&1)" \
  "Abstract reviewer lanes remain in Smoke dist (2 leftover reference(s) — a route word, or an unparsable value, in a frontmatter model key):"
rc=0; zrl_scan_and_report_lanes Smoke "$T/tree/nothing" >/dev/null 2>&1 || rc=$?
is "zrl_scan_and_report_lanes: a scan that could not run is 1 error, never 0" 1 "$rc"
mkdir -p "$T/linked"; printf '%s\n' '# doc' > "$T/linked/doc.md"; ln -s "$T/tree/rules/lane.md" "$T/linked/out.md"
st "zrl_links_inside: a symlink pointing outside the tree is status 1" 1 zrl_links_inside "$T/linked"
st "zrl_links_inside: a tree with no symlink is status 0" 0 zrl_links_inside "$T/tree"
st "zrl_scan_md: …and the scan refuses that tree (status 2)" 2 zrl_scan_md "$T/linked"

printf '%s\n' 'name = "x"' 'model = "gpt-6-sol"' > "$T/ok.toml"
printf '%s\n' 'name = "x"' 'model = "review-alt"' > "$T/lane.toml"
printf '%s\n' 'model = "a"' 'model = "b"' > "$T/dup.toml"
printf '%s\n' 'name = "x"' > "$T/nomodel.toml"
is "zrl_toml_model: the value, quotes dropped" "gpt-6-sol" "$(zrl_toml_model "$T/ok.toml" 2>/dev/null)"
st "zrl_toml_model: no model key is status 1" 1 zrl_toml_model "$T/nomodel.toml"
st "zrl_toml_model: a duplicate key is status 3, never 'the first one wins'" 3 zrl_toml_model "$T/dup.toml"
has "zrl_scan_toml: a lane left as a TOML model is a hit" "$(zrl_scan_toml "$T/ok.toml" "$T/lane.toml" 2>&1)" "$T/lane.toml:2:model = \"review-alt\""
st "zrl_scan_toml: nothing to scan is status 2" 2 zrl_scan_toml
rc=0; zrl_scan_and_report_toml_lanes Smoke "$T/ok.toml" "$T/lane.toml" >/dev/null 2>&1 || rc=$?
is "zrl_scan_and_report_toml_lanes: one leftover reference is status 1" 1 "$rc"

echo "  --- reviewer-lanes: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
