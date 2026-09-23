#!/usr/bin/env bash
# test-log-schema-marker.sh — the ledger must describe its own rows, across schema changes.
#
# `~/.zuvo/adversarial.log` is append-only and old, so its FIRST line is whatever header was
# current when it was created. Rewriting that line in place is unsafe (parallel runs hold open
# descriptors on the same inode), so the driver appends a `#schema` marker line instead and
# keeps a sentinel next to the log so it only does that once.
#
# The sentinel was the bug. It was a zero-byte file named `.schema16` — the column count of the
# day, written into the FILENAME. When column 17 (`project`) was added, that file still existed,
# init_log_header returned early, and the new marker was never appended: the live ledger
# advertised 16 columns over 1,785 seventeen-field rows. Anything trusting the schema to pick a
# field then read `provider` where `outcome` is — which is exactly how an aggregation of this
# ledger came out claiming every lane had failed 100% of its runs.
#
# So the property under test is not "a marker gets written" — that always passed, on a schema
# that had not changed. It is "a marker gets written AGAIN when the schema changes", which is
# the only thing the sentinel can get wrong, and the thing nothing was checking.
#
# Driven through the real entry point with a mock provider, like every other test in this
# suite: sourcing the driver to poke at init_log_header would test a function, not the path
# that actually writes the file.

ADV="$ROOT/scripts/adversarial-review.sh"
MOCKS="$HERE/mocks"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$MOCKS:$PATH"

LSDIR="$ADV_TEST_HOME/logschema"; mkdir -p "$LSDIR"

run_drv() { # run_drv <logfile> — one real invocation, mock provider, scoped ledger
  ZUVO_ADVERSARIAL_LOG_FILE="$1" ZUVO_REVIEW_TEST_PROVIDERS="mock-success" \
    bash "$ADV" --json --files "$EMPTY" >/dev/null 2>&1
}

# ─── 1. a fresh ledger is created with the current header ─────────────────
start_test "log.1 a new ledger gets a header, and it names every column a row carries"
L="$LSDIR/fresh.log"
run_drv "$L"
HDR="$(head -1 "$L")"
hdr_fields=$(printf '%s' "$HDR" | awk -F'\t' '{print NF}')
assert_eq "17" "$hdr_fields" "the header names 17 columns"
assert_contains "$HDR" "project" "column 17 (project) is named — the one that went unrecorded"
# The header is only useful if a real provider row has the same shape. This is the assertion
# that would have caught the drift at its source rather than in a later misreading.
row_fields=$(awk -F'\t' '$1 !~ /^(SUMMARY|#|date)/ {print NF; exit}' "$L")
assert_eq "$hdr_fields" "$row_fields" "a provider row has exactly as many fields as the header names"

# ─── 2. an OLD ledger gains a #schema marker and keeps its rows ───────────
start_test "log.2 an existing ledger is never rewritten — it gains a marker"
L="$LSDIR/old.log"
printf 'date\trun_id\tmode\tmodel\n' > "$L"
printf 'ROW-MUST-SURVIVE\n' >> "$L"
run_drv "$L"
assert_contains "$(cat "$L")" "ROW-MUST-SURVIVE" "pre-existing rows survive"
assert_eq "date	run_id	mode	model" "$(head -1 "$L")" "line 1 is left byte-for-byte as it was"
assert_contains "$(cat "$L")" "#schema	$HDR" "the current schema is appended as a marker"

# ─── 3. the marker is written ONCE while the schema is unchanged ──────────
start_test "log.3 repeat runs do not append duplicate markers"
run_drv "$L"; run_drv "$L"
assert_eq "1" "$(grep -c '^#schema' "$L")" "exactly one marker per schema"

# ─── 4. THE REGRESSION: a stale sentinel must not suppress the marker ─────
# Reproduced the way it actually happened: a sentinel left behind by an EARLIER schema. Under
# the old count-in-the-filename scheme this case appended nothing at all, and the ledger stayed
# mis-described for as long as it lived.
start_test "log.4 a schema change re-arms the marker (the .schema16 regression)"
L="$LSDIR/stale.log"
printf 'date\trun_id\n' > "$L"
: > "$L.schema16"                                    # the old, count-named sentinel
printf 'date\trun_id\tmode\tSOME-OLD-SCHEMA\n' > "$L.schema"   # a sentinel from another schema
run_drv "$L"
assert_contains "$(cat "$L")" "#schema	$HDR" "a stale sentinel does not suppress the new marker"
assert_eq "$HDR" "$(head -1 "$L.schema")" "the sentinel records the schema it confirmed"

# ─── 5. a failed append is not recorded as success ────────────────────────
# Otherwise one unwritable moment is permanent: the next run trusts the sentinel, skips the
# check, and the ledger never gets its schema line at all.
start_test "log.5 a failed append leaves the sentinel unconfirmed"
L="$LSDIR/ro.log"
printf 'date\trun_id\n' > "$L"
rm -f "$L.schema" "$L.schema16"
chmod 444 "$L"
run_drv "$L"
chmod 644 "$L"
if [ -f "$L.schema" ] && [ "$(head -1 "$L.schema")" = "$HDR" ]; then
  assert_eq "unconfirmed" "confirmed" "a failed append must not be recorded as success"
else
  assert_eq "ok" "ok" "sentinel withheld until the marker is on disk"
fi
