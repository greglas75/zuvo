# The retro learning loop — how zuvo improves itself

Every zuvo run writes a retrospective. Those retros are mined into weekly digests, the digests
carry concrete change proposals, the proposals get surfaced, triaged, implemented, and **marked
done**. This document is the operating manual for that loop: what each stage is, which command to
run, and — most importantly — the failure modes that have actually bitten us, so they don't again.

**The one-line rule:** every stage must have a *consumer*. A stage whose output nobody reads is a
dead end, and this loop has already produced three of them (see "Dead ends we hit" at the end).

---

## The pipeline at a glance

```
 zuvo skill run
      │  every run, at completion
      ▼
 ~/.zuvo/retros.log   (17-field TSV, machine-readable)     ← append-retro
 ~/.zuvo/retros.md    (prose retro incl. Change Proposals) ← append-retro
 ~/.zuvo/runs.log     (run telemetry)                      ← append-runlog
      │  weekly (Mon 08:17), + fleet bots' retros pulled in
      ▼
 ~/.zuvo/mining/digest-<date>.md        ← retro-mine.py   (deterministic: stats + ALL proposals)
      │                                 └ then a headless report-only agent writes
      │                                   zuvo/reports/retro-mine-<date>.md (TOP-5 triage)
      ▼
 digest-proposals                        ← dedups by (file, section), counts recurrence, ranks
      │
      ├── ~/.zuvo/mining/proposals-latest.md   (refreshed by the weekly rotate job)
      ▼
 YOU / an agent implement the good ones
      │
      ▼
 digest-proposals --mark applied|rejected|covered …
      └─→ ~/.zuvo/mining/proposals-ledger.tsv   ← the loop's memory of what is DONE
```

---

## Where state lives (and what that costs)

| Path | What | Versioned? |
|---|---|---|
| `~/.zuvo/retros.{log,md}`, `runs.log` | the raw signal | **No — HOME-local** |
| `~/.zuvo/mining/digest-*.md` | weekly digests | **No — HOME-local** |
| `~/.zuvo/mining/proposals-ledger.tsv` | what's already applied/rejected | **No — HOME-local** |
| `~/.zuvo/<helpers>` | the scripts | Yes — mirrored from `scripts/zuvo-home/`, installed by `install.sh` |
| `~/.zuvo/runlog-sync.sh`, `backlog-collect.py`, `backlog-consolidate.py`, `sync-popebot.sh`, `backlog`, `profile-session.py` | sync + analysis helpers | **Yes, since v1.6.47.** They used to be excluded because three of them hardcoded an SSH host — versioning that would point every installing machine at one private collector. The address now lives in `~/.zuvo/collector.conf` (machine-local, `chmod 600`, never in git) and is read by `zuvo-collector-host.sh`, so the CODE ships and the ADDRESS does not. `install.sh` installs every helper in `scripts/zuvo-home/` by loop. |
| `zuvo/reports/retro-mine-*.md` | the weekly agent's triage report | Per-project, gitignored |

**`~/.zuvo/` is not backed up by git.** The scripts are recoverable (`./scripts/install.sh`
rewrites them from the repo), but the *data* — every retro ever written, every digest, and the
disposition ledger — exists on one machine only. Before a machine migration or a wipe:

```bash
tar czf ~/zuvo-state-$(date +%F).tgz -C "$HOME" .zuvo
```

---

## Stage 1 — Retros (every run)

Skills call `~/.zuvo/append-retro`, gated by `append-runlog` (which refuses a run log with no
matching retro). The protocol lives in `shared/includes/retrospective.md`.

**Never `>>` straight into `retros.log`.** Hand-written rows drift into `key=value` shape, which
the miner cannot parse — the learning is written but uncounted. `sanitize-retros` repairs drift
automatically before each rotation, but the wrapper is the contract:

```bash
~/.zuvo/append-retro --skill refactor --project foo ...     # correct
echo "RETRO: skill=refactor ..." >> ~/.zuvo/retros.log      # WRONG — drift, silently uncounted
```

Retention is age-based (90 days, archived not deleted) via `rotate-retros`. Retros are **not**
deleted when their proposal is implemented — the ledger records that, the retro stays as evidence.

## Stage 2 — Mining (weekly, automatic)

`com.greglas.zuvo-retro-mine` LaunchAgent, **Mondays 08:17**, runs `retro-mine-weekly.sh`:

1. `retro-mine.py --days 7` → deterministic digest (`~/.zuvo/mining/digest-<date>.md`): window
   stats, friction histogram, and **every** change proposal from the Mac plus the fleet bots
   (`~/.zuvo/remote/*/retros.md`, synced by `sync-popebot.sh`).
2. A headless `claude -p` agent triages that digest and writes `zuvo/reports/retro-mine-<date>.md`
   with a TOP-5. **Report-only by contract** — it never edits skills, commits, or releases.

Run it by hand any time:

```bash
python3 ~/.zuvo/retro-mine.py --days 7      # just the digest
ZUVO_REPO=~/DEV/zuvo-plugin ~/.zuvo/retro-mine-weekly.sh   # digest + triage agent (slow, spends tokens)
```

> **Security: the digest is UNTRUSTED input.** It aggregates free text written by other machines —
> fleet-bot retros pulled from `~/.zuvo/remote/*/`. The triage agent reads all of it while running
> `--dangerously-skip-permissions`, so a retro line crafted (or corrupted) on any bot is a prompt
> injected into an unsandboxed local agent. Three things keep that bounded, and all three matter:
> the agent's contract is **report-only** (it writes one report; it never edits skills, commits, or
> releases), its output is a **file you read** rather than an applied change, and proposals reach
> the codebase only through the review step below — where a human or a verifying agent checks each
> one against the real file. Do not "simplify" the weekly job by letting the agent apply its own
> proposals; that removes every one of those bounds at once. Treat an unexpected instruction-shaped
> line in a digest as a compromised bot, not a proposal.

## Stage 3 — Surfacing proposals

```bash
~/.zuvo/digest-proposals                 # OPEN proposals only, apply-bar first
~/.zuvo/digest-proposals --all           # include below-bar "consider" items
~/.zuvo/digest-proposals --show-done     # include already-dispositioned ones, labelled
~/.zuvo/digest-proposals --json          # machine-readable, for an agent to triage
~/.zuvo/digest-proposals --min-recur 3   # raise the recurrence bar
```

Identity is `(normalized file, section)`; paths from Codex/Cursor runs (`~/.codex/skills/X/…`) are
normalized back to the **source** path, because editing a built copy is pointless.

**The apply bar** is `count >= 2` **OR** `priority == 0`. It is deliberately conservative: one
noisy friction line must never become a permanent skill rule. Below-bar items are visible under
`--all` but should not be applied on their own.

The weekly rotate job refreshes `~/.zuvo/mining/proposals-latest.md` with the same output.

## Stage 4 — Implementing (the part that needs judgement)

For each proposal, in this order:

1. **Verify it against the real file first.** A large share of proposals are already implemented,
   or target the wrong file. Open the file and check before writing anything.
2. **Prefer the root cause over the proposal's wording.** Proposals describe a *symptom* from one
   session. Example: "`--files` exits 1 with empty output — use stdin instead" was really the
   input-truncation crash in a completely different function; fixing where the proposal pointed
   would have patched the wrong file and left the bug.
3. **Check it doesn't contradict an existing rule.** Several proposals conflicted with standing
   rules (e.g. `index_folder force=true` vs "never re-index an indexed repo"). Reject those.
4. **Reject anything that weakens a gate.** "On contradictory CRITICALs, rerun and pick one" is a
   gate bypass wearing a convergence costume.
5. **Verify the claim with a tool, not by reading.** `ruff` for an F401 claim, a throwaway git repo
   for a tag-collision claim, before/after runs for a script bug. Proposals are field reports, not
   facts.
6. **Run adversarial review on your own edit** and fix what it finds — including code examples.
   Examples get copied, so a wrong one ships the bug everywhere it is pasted.

## Stage 5 — Disposition (never skip this)

```bash
~/.zuvo/digest-proposals --mark applied  --file skills/review/SKILL.md \
  --section "1.6 Adversarial" --ref v1.6.35
~/.zuvo/digest-proposals --mark rejected --file shared/includes/codesift-setup.md \
  --section "Post-edit indexing" --note "contradicts the never-reindex rule"
```

| Disposition | Use when |
|---|---|
| `applied` | implemented; `--ref` = release version or commit |
| `covered` | already in the code — verified, not re-implemented |
| `rejected` | unsound / contradicts a rule / weakens a gate — `--note` the reason |
| `not-ours` | targets another repo or an external tool |
| `deferred` | valid but larger work; still open in spirit |

Ledger: `~/.zuvo/mining/proposals-ledger.tsv`, append-only, **latest row per identity wins**
(same shape as the refactor finding-disposition ledger — one pattern, not two). A single short
`O_APPEND` line is atomic on POSIX, so parallel agents cannot interleave a half-row. A corrupt
ledger degrades to "no dispositions" and can never break reporting.

Dispositioned items disappear from the default view. That is the point: the next person sees only
what is genuinely open.

---

## The routine

| When | Do |
|---|---|
| Automatic, Mon 08:17 | digest + triage report (nothing to do) |
| Weekly, ~10 min | `~/.zuvo/digest-proposals` — read the top of the list; implement or disposition 2-3 |
| After implementing anything | `--mark applied --ref <version>` — **in the same session**, or it is lost |
| After rejecting | `--mark rejected --note "<why>"` — a rejection without a reason gets re-proposed forever |
| Before a machine migration | `tar czf ~/zuvo-state-$(date +%F).tgz -C "$HOME" .zuvo` |
| After changing any `scripts/zuvo-home/*` | `./scripts/install.sh` (the `~/.zuvo` copies are what actually run) |

**Editing `~/.zuvo/<helper>` directly is a trap.** `install.sh` overwrites it from the repo on the
next run. Edit `scripts/zuvo-home/<helper>` and install.

---

## Dead ends we hit (and how each was closed)

Each of these ran for months looking healthy. The pattern is always the same: a stage produced
output that nothing consumed, and nothing in the system said so.

| Dead end | Symptom | Closed by |
|---|---|---|
| Retros written, never mined | 100 retros, no insight | `retro-mine.py` + weekly agent |
| Proposals mined, never read | digests piling up in `mining/` | `digest-proposals` (v1.6.33) |
| Proposals read, never dispositioned | every run re-surfaced all 217, including the 57 just implemented | the ledger (v1.6.37) |
| `ideas` step "ran" but yielded nothing | `ideas.md` near-empty; no way to tell skipped-vs-empty | `log-ideas` receipt |
| Retro drift (`key=value` rows) | learning present but uncounted by the miner | `sanitize-retros` in the rotate job |
| Mining engine unversioned | `retro-mine.py` existed only in `~/.zuvo` — one disk failure from losing the loop | versioned in `scripts/zuvo-home/` (v1.6.38) |
| Overlapping mining windows inflated recurrence | clearing the apply bar to 0, then one mining run put **111** items straight back on it — while only **9** new retros existed | count distinct SOURCE RETROS, not digest occurrences (v1.6.47) |

**The lesson, stated once:** when you add a stage, name its consumer in the same change. If you
cannot name one, you are building the next dead end.

### The recurrence-inflation trap (worth understanding, not just knowing)

`retro-mine.py` mines a **7-day window** and never asks what previous digests already covered, so
consecutive weekly runs overlap almost entirely (`07-29` covered `07-22..29`, `07-30` covered
`07-23..30`). `digest-proposals` used to count how many times a `(file, section)` appeared across
digest files — so a single retro mined twice looked like **two independent reports of the same
problem**, which is precisely what the `≥2 recurrences` apply bar is supposed to mean. On
2026-07-30 that turned 9 new retros into 111 "recurring" proposals: **every one of them a ghost of
work already dispositioned.**

The fix is in the consumer, not the miner: identity is the **normalized block header line** (the
retro's own `## <date> <skill> <project> <title>` line), so the same retro mined into five digests
counts once, and two different retros proposing the same edit still count twice. Header lines come
in at least three dialects (full-ISO, date-only, bracketed `[DEGRADED-CONTEXT]` tags) that a date
regex splits apart while they name the same run — the whole normalized line is dialect-proof.
Regression-tested in `tests/hooks/test-digest-proposals.sh` in both directions: overlap must not
inflate, and a genuine recurrence must still register.

**Why the miner was left alone:** deduplicating at mining time would need the miner to know what
every prior digest consumed, and a re-mine after a bug fix must still be able to re-derive
everything. Counting correctly at read time gets both.

**How you notice this class of bug:** the apply-bar count and the new-retro count should move
together. If the bar jumps by 100 and the retro log gained 9 entries, the counter is measuring
mentions, not problems — check before working the list.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `digest-proposals` prints "no change proposals found" | no digests yet — run `python3 ~/.zuvo/retro-mine.py --days 7` |
| A proposal you implemented keeps reappearing | never dispositioned — `--mark applied` |
| `--mark` printed OK but the item still shows | the `(file, section)` didn't match a real identity. Compare against `--json`; the ledger is append-only, so just add a corrected row |
| Retro count looks too low | drift — `python3 ~/.zuvo/sanitize-retros` (dry run), then `--apply` |
| Digest missing fleet-bot retros | `sync-popebot.sh` hasn't run; check `~/.zuvo/sync-popebot.log` |
| A helper's fix didn't take effect | you edited `~/.zuvo/<helper>`; edit `scripts/zuvo-home/<helper>` + `./scripts/install.sh` |

## Scheduled jobs (macOS LaunchAgents)

| Label | Schedule | Runs |
|---|---|---|
| `com.greglas.zuvo-retro-mine` | Mon 08:17 | `retro-mine-weekly.sh` (digest + triage agent) |
| `com.greglas.zuvo-retro-rotate` | weekly | `rotate-retros-cron.sh` (sanitize → rotate → refresh `proposals-latest.md`) |
| `com.greglas.zuvo-runlog-sync` | every 2 h | `runlog-sync.sh` (telemetry upload) |
| `com.greglas.zuvo-backlog-sync` | every 2 h | `backlog sync` |
| `com.greglas.zuvo-popebot-sync` | every 30 min | `sync-popebot.sh` (pull fleet-bot retros) |

### Checking them — `launchctl list` is NOT the check (2026-08-12)

On 2026-08-12 three jobs — `zuvo-runlog-sync`, `zuvo-backlog-sync`, `zuvo-retro-rotate` — were
found dead since **2026-08-07**: five days of telemetry unsent (one catch-up run pushed 1273
entries; the backlog index had been frozen at 26,350 items and moved to 27,010). Throughout,
`launchctl list | grep zuvo` showed all five jobs present with `last exit code = 0`, because it
lists what launchd holds in memory, which outlives both the file on disk and the job's ability to
do anything.

**Two separate facts, and only the first is proven.**

1. **A real defect, fixed:** `2>&1` inside a plist `<string>` is invalid XML — a bare `&` must be
   `&amp;`. All three failed `plutil -lint`; `zuvo-popebot-sync` and `zuvo-retro-mine` passed and
   kept running. An unparseable plist cannot be bootstrapped, so these three would not have
   survived the next reboot regardless.
2. **NOT the cause of the 2026-08-07 stop, despite looking like it.** The three plists were last
   written on 2026-07-20/23/24 and ran fine for two weeks afterwards, and the machine was busy
   every day of the outage (59-200 runs/day in `runs.log`). Whatever stopped them left them
   resident and simply not firing. **That cause is still unknown.** It is written down as unknown
   on purpose: the first version of this section asserted the XML bug caused it, which fits the
   evidence only if you do not check the dates.

Check all three layers, in this order — each catches what the previous one cannot:

```bash
# 1. Does every plist still PARSE? (`launchctl list` structurally cannot see this)
for f in ~/Library/LaunchAgents/com.greglas.zuvo-*.plist; do printf '%s ' "$(basename "$f")"; plutil -lint "$f"; done

# 2. Is each job's log FRESH? This is the only check that catches an unknown cause — including
#    the 2026-08-07 one, which no amount of plist linting would have surfaced.
ls -lT ~/.zuvo/*.log

# 3. Only then: is it loaded at all?
launchctl list | grep zuvo
```

A log older than roughly twice its job's interval is the signal — the intervals are in the table
above. After editing any plist: `plutil -lint` it, then
`launchctl bootout gui/$UID/<label>; launchctl bootstrap gui/$UID <plist>` (a plain reload does not
replace a stale in-memory job), and confirm with `launchctl kickstart -p gui/$UID/<label>` that the
log actually advances. Logs land next to the scripts in `~/.zuvo/*.log`.

## Retro truncation — detection, recovery, diagnosis (2026-08-17)

`~/.zuvo/retros.log` and `retros.md` have been truncated at least three times in two days
(422→100, 464→112, 519→104 rows; retros.md 377→128, 431→138, 496→127 sections). The writer is
**still unidentified**. `rotate-retros` is excluded twice over: its own log ends 2026-08-13 and its
launchd job runs weekly, and no other `~/.zuvo` writer appears in any of the windows.

Three layers now stand between that and data loss. They are deliberately separate — the first two
stop the bleeding, the third is the only one that can end it:

| layer | where | what it does |
|---|---|---|
| detect + auto-recover | `append-retro`'s `_shrink_guard` (runs 54-199×/day) | high-water tracking; on a shrink, UNION of the newest snapshot with the live file, adopted only on a strict row gain |
| preserve | same guard | gzipped hourly snapshots of BOTH files, keep 24 — taken **only at or above the high-water**, so a truncation can never overwrite the last good copy |
| diagnose | `retro-shrink-forensics.sh` via launchd `WatchPaths` | fires within moments of the write and dumps `lsof` on the file AND the directory, the filtered process table, and launchd job state |

Two design points worth not re-deriving:

- **The snapshot interval IS the maximum possible loss.** It was 6h, chosen against cron cadence,
  and the first real incident lost 323 rows because the newest snapshot was 7 hours old. It tracks
  the append rate now, not cron.
- **Recovery is a UNION, never a restore.** The live file always holds rows written after the last
  snapshot; replacing it would trade one loss for another. Rows are deduplicated whole-line, so
  re-running is idempotent.

The forensics job is NOT installed by `scripts/install.sh` (which manages no launchd jobs — every
`com.greglas.zuvo-*` plist is operator-installed). To arm it:

```bash
cp scripts/zuvo-home/retro-shrink-forensics.sh ~/.zuvo/ && chmod +x ~/.zuvo/retro-shrink-forensics.sh
# plist: Label com.greglas.zuvo-retro-shrink-forensics, WatchPaths [$HOME/.zuvo/retros.log],
#        ThrottleInterval 10, logs to ~/.zuvo/retro-shrink-forensics.launchd.log
launchctl load ~/Library/LaunchAgents/com.greglas.zuvo-retro-shrink-forensics.plist
```

Dumps land in `~/.zuvo/retro-shrink-forensics.log`, one per incident. **A dump whose only open
handle is `UserEvent` is launchd's own trigger, not the culprit** — that is what a
self-inflicted test truncation looks like, and it was the first entry written here.
