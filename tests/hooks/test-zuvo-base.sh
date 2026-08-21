#!/usr/bin/env bash
# scripts/zuvo-home/zuvo-base — resolve the install root, deterministically, on every harness.
#
# The properties that matter are the ones the four-line sed recipe in env-compat.md gets wrong
# somewhere: a stale $ZUVO_BASE must not win, the SHA-named cache sibling must not outrank a
# semver directory, a container with no installed_plugins.json must still resolve, and a total
# failure must print nothing on stdout (so `X="$(zuvo-base)"` yields "" rather than a diagnostic
# used as a path).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/scripts/zuvo-home/zuvo-base"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
[ -x "$HELPER" ] || { bad "helper missing or not executable"; exit 1; }

mkroot() { mkdir -p "$1/scripts" "$1/shared/includes"; }

run() { # run <fake-home> [env assignments via caller]
  HOME="$1" "$HELPER" 2>"$TMP/err"
}

# ── (1) a valid $ZUVO_BASE override wins ─────────────────────────────────────────────────
H="$TMP/h1"; mkdir -p "$H"
OV="$TMP/override"; mkroot "$OV"
out=$(HOME="$H" ZUVO_BASE="$OV" "$HELPER" 2>/dev/null)
[ "$out" = "$OV" ] && pass "a valid ZUVO_BASE override wins" || bad "override ignored: $out"

# ── (2) a STALE override loses to a real install ─────────────────────────────────────────
H="$TMP/h2"; mkdir -p "$H/.zuvo-plugin"; mkroot "$H/.zuvo-plugin"
out=$(HOME="$H" ZUVO_BASE="$TMP/deleted-release" "$HELPER" 2>/dev/null)
[ "$out" = "$H/.zuvo-plugin" ] \
  && pass "a stale ZUVO_BASE pointing at a deleted release is ignored" \
  || bad "stale override was trusted: $out"

# ── (3) installPath from installed_plugins.json is authoritative ─────────────────────────
H="$TMP/h3"; mkdir -p "$H/.claude/plugins"
IP="$H/.claude/plugins/cache/zuvo-marketplace/zuvo/1.6.71"; mkroot "$IP"
OLD="$H/.claude/plugins/cache/zuvo-marketplace/zuvo/1.0.0"; mkroot "$OLD"
cat > "$H/.claude/plugins/installed_plugins.json" <<JSON
{"plugins":{"zuvo@zuvo-marketplace":[{"installPath":"$IP","version":"1.6.71"}]}}
JSON
out=$(HOME="$H" ZUVO_BASE='' "$HELPER" 2>/dev/null)
[ "$out" = "$IP" ] && pass "installPath is preferred over the cache glob" || bad "installPath ignored: $out"

# ── (4) the SHA-named cache sibling never outranks a semver directory ────────────────────
H="$TMP/h4"
C="$H/.claude/plugins/cache/zuvo-marketplace/zuvo"
mkroot "$C/1.4.0"; mkroot "$C/17ea9f3c8b2d4a1e"; mkroot "$C/1.10.2"
out=$(HOME="$H" ZUVO_BASE='' "$HELPER" 2>/dev/null)
[ "$out" = "$C/1.10.2" ] \
  && pass "cache pick is semver-ordered (1.10.2 > 1.4.0) and excludes the SHA dir" \
  || bad "cache resolution wrong: $out"

# ── (5) a container with no Claude Code state still resolves ─────────────────────────────
H="$TMP/h5"; mkroot "$H/.zuvo-plugin"
out=$(HOME="$H" ZUVO_BASE='' "$HELPER" 2>/dev/null)
[ "$out" = "$H/.zuvo-plugin" ] \
  && pass "~/.zuvo-plugin resolves where installed_plugins.json does not exist" \
  || bad "container mount not found: $out"

# ── (6) other harness roots resolve ──────────────────────────────────────────────────────
for pair in ".codex:Codex" ".cursor:Cursor" ".kimi-code:Kimi"; do
  d="${pair%%:*}"; label="${pair##*:}"
  H="$TMP/h6-$label"; mkroot "$H/$d"
  out=$(HOME="$H" ZUVO_BASE='' "$HELPER" 2>/dev/null)
  [ "$out" = "$H/$d" ] && pass "$label build root resolves" || bad "$label root not found: $out"
done

# The remaining cases test what happens when NOTHING resolves. Run a copy from outside the
# repo: the in-repo helper legitimately finds its own checkout via the source fallback, which
# would make every failure case here silently pass.
DETACHED="$TMP/detached/zuvo-base"
mkdir -p "$TMP/detached"; cp "$HELPER" "$DETACHED"; chmod +x "$DETACHED"

# ── (7) a directory without scripts/ is not a root ───────────────────────────────────────
H="$TMP/h7"; mkdir -p "$H/.zuvo-plugin/shared"   # no scripts/
out=$(HOME="$H" ZUVO_BASE='' "$DETACHED" 2>/dev/null); rc=$?
[ "$rc" -eq 3 ] && pass "a directory without scripts/ is rejected" || bad "empty dir accepted (rc=$rc, out=$out)"

# ── (8) total failure prints NOTHING on stdout ───────────────────────────────────────────
H="$TMP/h8"; mkdir -p "$H"
out=$(HOME="$H" ZUVO_BASE='' "$DETACHED" 2>"$TMP/err"); rc=$?
[ -z "$out" ] \
  && pass 'failure leaves stdout empty, so ZUVO_BASE="$(zuvo-base)" is "" not a diagnostic' \
  || bad "failure wrote to stdout: $out"
[ "$rc" -eq 3 ] && pass "failure exits 3" || bad "failure exit $rc (want 3)"
grep -q "cannot locate" "$TMP/err" && pass "failure explains itself on stderr" || bad "no stderr explanation"

# ── (9) --why explains the decision without polluting stdout ─────────────────────────────
H="$TMP/h9"; mkroot "$H/.zuvo-plugin"
out=$(HOME="$H" ZUVO_BASE='' "$HELPER" --why 2>"$TMP/err")
[ "$out" = "$H/.zuvo-plugin" ] && pass "--why keeps stdout to the path alone" || bad "--why polluted stdout: $out"
grep -q "container/CI mount" "$TMP/err" && pass "--why names the rule that fired" || bad "--why said nothing useful"

# ── (10) running out of the source checkout resolves to the repo itself ──────────────────
H="$TMP/h10"; mkdir -p "$H"
out=$(HOME="$H" ZUVO_BASE='' "$HELPER" 2>/dev/null)
[ "$out" = "$ROOT" ] \
  && pass "a helper run straight out of the repo resolves to that checkout" \
  || bad "source-checkout fallback wrong: $out"

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
