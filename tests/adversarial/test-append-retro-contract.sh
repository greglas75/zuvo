#!/usr/bin/env bash
# test-append-retro-contract.sh — the binding WRITE↔READ contract.
# append-retro output MUST satisfy append-runlog's gate for the SAME
# skill+project (the asymmetry that left 12 execute runs un-loggable on
# 2026-05-29: drifted retros could never match the NF==17 gate). Also asserts
# append-retro REJECTS the corruption classes at the source.

ARET="$ROOT/scripts/zuvo-home/append-retro"
ARUN="$ROOT/scripts/zuvo-home/append-runlog"
_o=""; _oc(){ for d in $_o; do rm -rf "$d" 2>/dev/null; done; }; trap _oc EXIT INT TERM
_z(){ local d; d=$(mktemp -d); _o="$_o $d"; printf '%s' "$d"; }
T="2026-05-29T00:00:00Z"

start_test "append-retro output PASSES append-runlog gate (write↔read contract)"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --skill=execute --project=TestProj --code-type=DATA_SERVICE \
  --friction=other --context-gap=none --turns=4 --tool-calls=120 \
  --files-read=18 --files-modified=6 --blind-audit=clean:strict \
  --adversarial=2findings --codesift=indexed --routing=ok \
  --sha7=testsha --date="$T" >/dev/null 2>&1
assert_exit_code 0 "$?" "append-retro emits a full retro"
RL=$(printf '%s\texecute\tTestProj\t-\t-\tPASS\t1\t1-tasks\tredo\tmain\ttestsha\t-\t-' "$T")
printf '%b\n' "$RL" | ZUVO_HOME="$Z" "$ARUN" >/dev/null 2>&1; rc=$?
assert_exit_code 0 "$rc" "append-runlog accepts the run line (retro matched the gate)"
n=$(grep -c . "$Z/runs.log" 2>/dev/null || echo 0)
assert_eq 1 "$n" "exactly one runs.log row written"

start_test "append-retro REJECTS empty SKILL / empty FRICTION"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --project=X --friction=other >/dev/null 2>&1
assert_exit_code 2 "$?" "empty --skill rejected"
ZUVO_HOME="$Z" "$ARET" --skill=execute --project=X >/dev/null 2>&1
assert_exit_code 2 "$?" "empty --friction rejected"

start_test "append-retro REJECTS embedded TAB in a field"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --skill=execute --project="$(printf 'a\tb')" --friction=other >/dev/null 2>&1
assert_exit_code 2 "$?" "TAB in --project rejected (would corrupt TSV)"

start_test "append-retro REJECTS stub friction on the full-retro path"
Z=$(_z)
for fr in abandoned context-out partial-recovery degraded-autolog; do
  ZUVO_HOME="$Z" "$ARET" --skill=execute --project=X --friction="$fr" >/dev/null 2>&1
  rc=$?
  assert_exit_code 2 "$rc" "--friction=$fr rejected on full path"
done

start_test "append-retro REJECTS a FUTURE --date (forgery class)"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --skill=execute --project=X --friction=other --date=2099-01-01T00:00:00Z >/dev/null 2>&1
assert_exit_code 2 "$?" "future --date rejected"

# ─── N/A must be answerable for gate columns the skill does not have ─────────
# 2026-08-06: the BLIND_AUDIT enum had no `N/A`, so a skill with no blind-audit
# step could not answer truthfully. Measured over 246 retros: 164 blind-audit
# verdicts, 108 of them (66%) from skills whose SKILL.md never mentions the step
# (ship 42, review 34, test-audit 23) — `clean:degraded` the popular choice.
# Agents were not inventing; the validator REJECTED the truth, so they picked the
# safest-sounding value. The column became unusable for analysis and was about to
# ship fleet-wide as a `blind_audit_ran` metric. CODESIFT and ROUTING already
# allowed N/A, which is exactly why those two columns read sanely.
start_test "append-retro accepts N/A for gate columns a skill does not have"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --skill=ship --project=P --code-type=MIXED \
  --friction=other --context-gap=none --turns=1 --tool-calls=1 \
  --files-read=1 --files-modified=0 --blind-audit=N/A \
  --adversarial=N/A --codesift=indexed --routing=ok \
  --sha7=testsha --date="$T" >/dev/null 2>&1
assert_exit_code 0 "$?" "blind-audit=N/A and adversarial=N/A accepted"

start_test "N/A lands in the log as N/A, not silently rewritten"
grep -q "$(printf 'N/A\tN/A\tindexed')" "$Z/retros.log" 2>/dev/null \
  && pass "the N/A pair is written verbatim (a reader can tell 'no such step' from 'skipped')" \
  || fail "N/A round-trip" "$(tail -1 "$Z/retros.log" 2>/dev/null | cut -c1-160)"

start_test "a junk gate value is STILL rejected (N/A did not open the enum)"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --skill=ship --project=P --code-type=MIXED \
  --friction=other --context-gap=none --turns=1 --tool-calls=1 \
  --files-read=1 --files-modified=0 --blind-audit=probably-fine \
  --adversarial=N/A --codesift=indexed --routing=ok \
  --sha7=testsha --date="$T" >/dev/null 2>&1
assert_exit_code 2 "$?" "unrecognised blind-audit value still exits 2"

# ─── the protocol's vocabulary and the script's enum must not drift apart ─────
# `Nfindings:preserved` is defined in retrospective.md field 15 as its OWN verdict:
# a behavior-preserving refactor draws findings on patterns it MOVED but did not
# introduce, fixing them would change behavior, and `Nfindings` would claim they
# drove a fix. The case statement accepted `*findings` and nothing after it, so
# every run that followed the documented protocol exited 2 here — and since
# append-runlog gates on a matching retro, that run lost its telemetry entirely.
# Four separately-mined change proposals pointed at this one line before anyone
# reconciled the doc against the script (2026-09-22).
start_test "append-retro accepts the documented Nfindings:preserved verdict"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --skill=refactor --project=P --code-type=PURE_FUNCTION \
  --friction=other --context-gap=none --turns=1 --tool-calls=1 \
  --files-read=1 --files-modified=1 --blind-audit=N/A \
  --adversarial=3findings:preserved --codesift=indexed --routing=ok \
  --sha7=testsha --date="$T" >/dev/null 2>&1
assert_exit_code 0 "$?" "a behavior-preserving refactor can record its real verdict"

start_test "and it lands verbatim, distinguishable from a plain Nfindings"
grep -q "3findings:preserved" "$Z/retros.log" 2>/dev/null \
  && pass "preserved-disposition findings stay distinct from findings that drove fixes" \
  || fail "Nfindings:preserved round-trip" "$(tail -1 "$Z/retros.log" 2>/dev/null | cut -c1-160)"

start_test "the suffix did not open the enum to anything ending in a colon"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --skill=refactor --project=P --code-type=PURE_FUNCTION \
  --friction=other --context-gap=none --turns=1 --tool-calls=1 \
  --files-read=1 --files-modified=1 --blind-audit=N/A \
  --adversarial=3findings:mostly-fine --codesift=indexed --routing=ok \
  --sha7=testsha --date="$T" >/dev/null 2>&1
assert_exit_code 2 "$?" "an invented disposition suffix is still rejected"

# ─── same skill + project + sha7 from two sessions: one row, both narratives ─────
# The row key is shared with append-runlog's gate and must stay one-per-sha7. The retros.md block
# is a run's content, and a second session on the same commit used to lose it with the row.
start_test "a second run on the same sha7 keeps its retros.md block, a retry does not duplicate"
Z=$(_z)
M1=$(mktemp); M2=$(mktemp); _o="$_o $M1 $M2"
printf '### run one\nfirst narrative\n' > "$M1"
printf '### run two\nsecond narrative\n' > "$M2"
for md in "$M1" "$M2" "$M2"; do
  ZUVO_HOME="$Z" "$ARET" --skill=method-audit --project=P --code-type=MIXED \
    --friction=other --context-gap=none --turns=1 --tool-calls=1 \
    --files-read=1 --files-modified=0 --blind-audit=N/A \
    --adversarial=N/A --codesift=indexed --routing=ok \
    --sha7=testsha --date="$T" --md="$md" >/dev/null 2>&1
done
rows=$(grep -c '^RETRO:' "$Z/retros.log" 2>/dev/null || echo 0)
assert_eq 1 "$rows" "one 17-field row per skill+project+sha7 (the runlog gate key)"
one=$(grep -c 'first narrative' "$Z/retros.md" 2>/dev/null || echo 0)
two=$(grep -c 'second narrative' "$Z/retros.md" 2>/dev/null || echo 0)
assert_eq 1 "$one" "the first run's narrative is there"
assert_eq 1 "$two" "the second run's narrative is kept, and its retry did not duplicate it"

# ─── ROUTING_STATUS: every status the reviewer router emits can be recorded ─────
# Plan C (docs/specs/2026-09-25-cross-vendor-reviewer-routing-plan.md) gave
# scripts/reviewer-model-route.sh two statuses — `cross-vendor-unavailable` and
# `in-family-fallback` — that neither retrospective.md field 17 nor this writer knew, so a
# run recording its REAL routing status exited 2 here and, through append-runlog's retro
# gate, lost its telemetry: the Nfindings:preserved failure above, one column over.
# `rate-limited` was already in field 17 and still rejected here — the same drift.
# The router's statuses are taken by RUNNING it (every host, client present/missing, Kimi with
# and without MOONSHOT_API_KEY, --fallback, the fail-closed and no-host paths). The EXECUTED runs
# are the authority; a regex over the router source is only a SUPPLEMENTARY cross-check that the
# runs reach every literal the source names (it can miss computed values, so it never defines the
# vocabulary). Each run's stdout must be exactly the six contract keys, in order, each once — a
# duplicate key is a reject, never collapsed by a dict. Field 17 is parsed as a table cell, so the
# check is two-way: every emitted status is in field 17, and field 17 holds nothing else but the
# caller-side `rate-limited` and `N/A` — which the router itself must never emit.
RETRO_DOC="$ROOT/shared/includes/retrospective.md"
ROUTER="$ROOT/scripts/reviewer-model-route.sh"
_rv_out=$(mktemp); _rv_err=$(mktemp); _rv_work=$(mktemp -d)
_o="$_o $_rv_out $_rv_err $_rv_work"
python3 - "$RETRO_DOC" "$ROUTER" "$_rv_work" >"$_rv_out" 2>"$_rv_err" <<'PY'
import os, re, shutil, signal, subprocess, sys, tempfile

retro_doc, router, work = sys.argv[1:4]
KEYS = ["platform", "writer_model", "writer_lane", "reviewer_lane", "reviewer_model", "routing_status"]
CALLER_SIDE = {"rate-limited", "N/A"}  # recorded by the caller (throttled dispatch / a skill with no such step)


def say(ok, label, detail=""):
    print("ok\t%s" % label if ok else "no\t%s\t%s" % (label, str(detail).replace("\t", " ").replace("\n", " ")[:1200] or "-"))


def ticks(text):
    return re.findall(r"`([^`]+)`", text)


text = open(retro_doc, encoding="utf-8").read()
rows = []
for line in text.splitlines():
    if line.lstrip().startswith("|"):
        cells = [c.strip() for c in re.split(r"(?<!\\)\|", line.strip())[1:-1]]
        if len(cells) >= 4 and cells[0] == "17" and cells[1] == "ROUTING_STATUS":
            rows.append(cells)
f17 = []
if len(rows) == 1:
    lead = re.match(r"\s*((?:`[^`]+`\s*,\s*)*`[^`]+`)", rows[0][3])
    f17 = ticks(lead.group(1)) if lead else []
print("F17\t%s" % " ".join(f17))
say(len(rows) == 1 and f17, "field 17 is ONE ROUTING_STATUS table row with a leading enum", "%d rows, enum %r" % (len(rows), f17))
say(len(rows) == 1 and "the router's `routing_status`" in rows[0][3] and "`reviewer_lane`" in rows[0][3]
    and "caller-side `rate-limited`" in rows[0][3] and "`N/A` when no route was resolved" in rows[0][3]
    and "exactly as emitted" not in rows[0][3] and "recorded under `ok`" not in rows[0][3],
    "field 17 records the router's routing_status (never its reviewer_lane), or the caller-side rate-limited, or N/A "
    "when no route was resolved", rows[0][3][:300] if rows else "-")
for name, rx in (("the append-retro --routing template", r'--routing="<([^>]*)>"'),
                 ("the infra_status 'routing:' template", r"routing: <([^>]*)>")):
    found = re.findall(rx, text)
    say(len(found) == 1 and sorted(found[0].split("|")) == sorted(f17),
        "%s = field 17 (exactly one template)" % name, "found %r, field 17 %r" % (found, f17))

T = tempfile.mkdtemp(dir=work)
sent = os.path.join(T, "sentinel")
with open(sent, "w") as fh:
    fh.write("#!/bin/sh\nexit 1\n")
os.chmod(sent, 0o755)
shim = os.path.join(T, "shim")
os.mkdir(shim)
os.symlink(sent, os.path.join(shim, "agy"))
lone = os.path.join(T, "lone")
os.mkdir(lone)
shutil.copy(router, lone)
emitted, crashes = set(), []


def run(extra, args=(), path=router):
    home = tempfile.mkdtemp(prefix="case-", dir=T)
    try:
        return _run(home, extra, args, path)
    finally:
        shutil.rmtree(home, ignore_errors=True)


def _run(home, extra, args, path):
    env = {"PATH": "/usr/bin:/bin", "HOME": home, "CODEX_HOME": os.path.join(home, "codex"),
           "ZUVO_CODEX_APP_BIN": "/nonexistent", "ZUVO_CODEX_BIN": "/nonexistent", "ZUVO_CLAUDE_BIN": "/nonexistent"}
    env.update(extra)
    try:  # its own process group, killed whole on timeout
        p = subprocess.Popen(["/bin/bash", path] + list(args), env=env, cwd=home, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, start_new_session=True)
        try:
            so, _ = p.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.communicate()
            crashes.append("%r %r: timeout (process group killed)" % (extra, args))
            return
        pairs = [l.split("=", 1) for l in so.decode("utf-8").splitlines()]
    except (OSError, UnicodeDecodeError) as exc:
        crashes.append("%r: %s" % (extra, exc))
        return
    if p.returncode != 0 or [q[0] for q in pairs] != KEYS \
            or any(len(q) != 2 or not q[1].strip() or q[1] != q[1].strip() for q in pairs):
        crashes.append("%r %r: rc=%s stdout keys %r" % (extra, args, p.returncode, [q[0] for q in pairs]))
        return
    emitted.add(dict(pairs)["routing_status"])


for fb in ((), ("--fallback",)):
    for w in ("opus", None):
        for seam in (sent, "/nonexistent"):
            run(dict({"CLAUDECODE": "1", "ZUVO_CODEX_BIN": seam}, **({"CLAUDE_MODEL": w} if w else {})), fb)
            run(dict({"CODEX_SHELL": "1", "ZUVO_CLAUDE_BIN": seam}, **({"ZUVO_CODEX_MODEL": "gpt-5.5"} if w else {})), fb)
    for path in (shim + ":/usr/bin:/bin", "/usr/bin:/bin"):
        run({"CURSOR_AGENT_MODEL": "composer-2.5-fast", "PATH": path}, fb)
        for kimi in ("kimi-code", "kimi-k2.6"):
            run({"ZUVO_KIMI_CLI_MODEL": kimi, "PATH": path}, fb)
            run({"ZUVO_KIMI_CLI_MODEL": kimi, "PATH": path, "MOONSHOT_API_KEY": "k"}, fb)
    for g in ("gemini-3-flash", "gemini", "mystery-model"):
        run({"ANTIGRAVITY_SESSION_ID": "1", "GEMINI_MODEL": g}, fb)
    run({}, fb)
    run({"CLAUDECODE": "1", "ZUVO_MODEL_CODEX_PRIMARY": "a b"}, fb)
    run({"CLAUDECODE": "1"}, fb, os.path.join(lone, os.path.basename(router)))
say(not crashes, "every router run exits 0 with exactly the six keys, in order, each once, non-empty and unpadded",
    " | ".join(crashes))
left = [d for d in os.listdir(T) if d.startswith("case-")]
say(not left, "every per-run temp HOME was removed after its run", left)
say(not (emitted & {"rate-limited"}), "the router never emits the caller-side rate-limited", sorted(emitted))
src = set(re.findall(r"routing_status=[\"']?([a-z][a-z-]*)", open(router, encoding="utf-8").read()))
say(src <= emitted, "supplementary: the runs reach every status literal the router source names (%s)" % " ".join(sorted(emitted)),
    "unreached %r" % sorted(src - emitted))
say(emitted <= set(f17), "field 17 lists every status the router emits", "missing %r" % sorted(emitted - set(f17)))
say(set(f17) <= emitted | CALLER_SIDE, "field 17 lists nothing the router never emits except rate-limited and N/A",
    "extra %r" % sorted(set(f17) - emitted - CALLER_SIDE))
PY
_rv_rc=$?
F17=""; _rv_n=0
start_test "field 17 ROUTING_STATUS = the statuses the router emits (+ caller-side), both routing templates agree"
while IFS="$(printf '\t')" read -r _rv_v _rv_l _rv_d; do
  case "$_rv_v" in
    F17) F17="$_rv_l" ;;
    ok) pass "$_rv_l"; _rv_n=$((_rv_n + 1)) ;;
    no) fail "$_rv_l" "$_rv_d"; _rv_n=$((_rv_n + 1)) ;;
    *) fail "the routing-vocabulary checker printed a malformed line" "[$_rv_v $_rv_l $_rv_d]" ;;
  esac
done < "$_rv_out"
if [ "$_rv_rc" -ne 0 ] || [ -s "$_rv_err" ] || [ "$_rv_n" -eq 0 ]; then
  fail "the routing-vocabulary checker itself" "rc=$_rv_rc results=$_rv_n stderr=$(head -c 400 "$_rv_err")"
fi

start_test "append-retro accepts every ROUTING_STATUS value field 17 documents, verbatim"
[ -n "$F17" ] || fail "field 17 enum derivation" "no ROUTING_STATUS row enum found in $RETRO_DOC"
for s in $F17; do
  Z=$(_z)
  ZUVO_HOME="$Z" "$ARET" --skill=write-tests --project=P --code-type=MIXED \
    --friction=other --context-gap=none --turns=1 --tool-calls=1 \
    --files-read=1 --files-modified=1 --blind-audit=N/A \
    --adversarial=N/A --codesift=indexed --routing="$s" \
    --sha7=testsha --date="$T" >/dev/null 2>&1
  assert_exit_code 0 "$?" "--routing=$s accepted"
  assert_eq "$s" "$(grep '^RETRO:' "$Z/retros.log" 2>/dev/null | tail -1 | awk -F'\t' '{print $NF}')" \
    "--routing=$s lands verbatim as the last column"
done

start_test "a lane is not a status: --routing=cross-vendor is still rejected"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --skill=write-tests --project=P --code-type=MIXED \
  --friction=other --context-gap=none --turns=1 --tool-calls=1 \
  --files-read=1 --files-modified=1 --blind-audit=N/A \
  --adversarial=N/A --codesift=indexed --routing=cross-vendor \
  --sha7=testsha --date="$T" >/dev/null 2>&1
assert_exit_code 2 "$?" "the lane word cross-vendor is not a ROUTING_STATUS"
