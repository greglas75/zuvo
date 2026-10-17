#!/usr/bin/env bash
# test-muse-quota.sh — a spent Muse subscription window (run_muse, _muse_quota_*, adversarial-lanes.sh).
#
# 2026-10-16/17: muse answered every call with "API error 429 … Subscription quota exhausted. Your usage window
# resets at …" under a "workspace root: …" banner, and the lane reported the banner — a workspace problem — for two
# days. A spent window is recorded, named, and the lane is not run (nor held against it) until the reset.

ADV="$ROOT/scripts/adversarial-review.sh"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1

MTMP="$HERE/.tmp/muq.$$"; mkdir -p "$MTMP/bin"
cleanup_muq() { rm -rf "$MTMP"; }
trap cleanup_muq EXIT

# Fake muse: counts its calls (muse.calls); with $MUQ_RESET set it fails as a spent window would, else it reviews.
cat > "$MTMP/bin/muse" <<'EOF'
#!/usr/bin/env bash
echo x >> "$MUQ_REC/muse.calls"
if [ -n "${MUQ_RESET:-}" ]; then
  echo "muse: workspace root: /tmp/ws (explicit)" >&2
  echo "agent loop failed: model failed: API error 429 [request_id=r]: Subscription quota exhausted. Your usage window resets at ${MUQ_RESET}. (rate_limit_error)" >&2
  exit 1
fi
echo "NO ISSUES FOUND."
EOF
chmod +x "$MTMP/bin/muse"

iso_in() { date -u -d "@$(( $(date +%s) + $1 ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$(( $(date +%s) + $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }

# run_m <case> [VAR=value…] -> the lane's captured stderr; exit code in <home>/rc; stop file <home>/quota.
run_m() {
  local home="$MTMP/$1"; shift
  mkdir -p "$home"
  env -u MUQ_RESET PATH="$MTMP/bin:$PATH" MUQ_REC="$home" HOME="$home" ZUVO_HOME="$home" \
    ZUVO_MUSE_QUOTA_FILE="$home/quota" ZUVO_PROVIDER_HEALTH_FILE="$home/health" ZUVO_PROVIDER_BENCH=0 \
    ZUVO_REVIEW_TIMEOUT=25 "$@" bash "$ADV" --provider muse --mode code --files "$EMPTY" >/dev/null 2>&1
  echo "$?" > "$home/rc"
  cat "$home"/adversarial-failures/*/provider_*.stderr 2>/dev/null
}
calls() { if [ -f "$MTMP/$1/muse.calls" ]; then wc -l < "$MTMP/$1/muse.calls" | tr -d ' '; else echo 0; fi; }

# Bug caught: the spent window reported as a workspace error, retried on every review, and benching the lane.
start_test "mq.1 a spent window is named, its reset recorded, and not held against the lane"
reset_iso="$(iso_in 172800)"
out=$(run_m c1 MUQ_RESET="$reset_iso")
assert_contains "$out" "Muse subscription quota exhausted until" "the lane names the quota, not the workspace banner"
got=$(cut -f1 "$MTMP/c1/quota" 2>/dev/null); want=$(date -u -d "$reset_iso" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$reset_iso" +%s)
assert_eq "$want" "$got" "the reset the message names is recorded"
case "$(cat "$MTMP/c1/health" 2>/dev/null)" in
  *muse*) fail "the quota stop was recorded in the provider-health ledger" "$(cat "$MTMP/c1/health")" ;;
  *) pass "the provider-health ledger holds nothing against muse" ;;
esac

# Bug caught: every later review paying a failing call while the window is still spent.
start_test "mq.2 while the stop is ahead muse is not called; once it has passed, it is"
mkdir -p "$MTMP/c2" "$MTMP/c2b"
printf '%s\tmuse\n' "$(( $(date +%s) + 3600 ))" > "$MTMP/c2/quota"
run_m c2 >/dev/null
assert_eq "0" "$(calls c2)" "no call while the stop is ahead"
printf '%s\tmuse\n' "$(( $(date +%s) - 60 ))" > "$MTMP/c2b/quota"
run_m c2b >/dev/null
assert_eq "1 0" "$(calls c2b) $(cat "$MTMP/c2b/rc")" "a past stop: muse is called and reviews"

# Bug caught: a message with no usable reset shutting muse out for good.
start_test "mq.3 a reset that is missing or implausible is taken as one hour"
run_m c3 MUQ_RESET="sometime soon" >/dev/null
got=$(cut -f1 "$MTMP/c3/quota" 2>/dev/null); got=${got:-0}; now=$(date +%s)
if (( got >= now + 3500 && got <= now + 3600 )); then pass "about an hour ahead"; else fail "expected about now + 3600, got $got (now $now)"; fi
