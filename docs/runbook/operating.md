# Operating runbook — commands that look right and are not

Companion to `testing.md`, which says WHAT to run. This says how to run it without losing an hour,
and every entry below is a mistake that was actually made — most of them more than once, in a
single session, by an agent that had the information available and typed from memory instead.

Read the two rules at the bottom first if you read nothing else.

---

## 1. `pkill -f` / `pgrep -f` match your own command line

**Made 3 times in one session, cost an `exit 255` each time.**

```bash
ssh host 'pkill -f "stryker run /tmp/probe.json"'      # kills the ssh shell running it
```

Your command string contains the pattern, so the pattern matches the process running it. Over ssh
the victim is the shell, and you get `exit 255` with no explanation — it reads like a network
fault.

The bracket trick is not enough on its own:

```bash
ssh host 'pkill -9 -f "probe[.]json"'                  # STILL dies: the command also contains
                                                       # /tmp/probe.json elsewhere in the line
```

**Correct: two calls. Find the pid, then kill the pid.** A pid cannot be spelled two ways.

```bash
PID=$(ssh host 'ps -eo pid,args | awk "/stryker run/ && !/awk/ {print \$1}" | head -1')
ssh host "kill -9 $PID"
```

The same trap applies to any watcher that waits on a pattern. A chain script that polled
`pgrep -f "^bash /root/bench/night10.sh"` fired IMMEDIATELY, because the driver had been launched
with a relative path (`bash night10.sh`) and the anchored pattern matched nothing. Two sweeps then
raced for the same cores. **Wait on a pid, never on a pattern.**

---

## 2. Nested heredocs through `ssh '...'` get mangled

**Made 4+ times. Symptom: `unmatched "`, `no matches found`, or a file written with the literal
text `EOF` in it.**

```bash
ssh host 'python3 - <<EOF
d = {"a": "b"}          # the outer single-quotes, the shell on the far side, and the heredoc
EOF'                    # each get a turn at your quoting. One of them wins and it is not you.
```

**Correct: write the script locally, `scp` it, run it by name.** It is one extra line and it
never fails.

```bash
cat > /tmp/patch.py <<'OUTER'
...whatever you want, quoted however you like...
OUTER
scp -q /tmp/patch.py host:/tmp/patch.py && ssh host 'python3 /tmp/patch.py'
```

This also gives you the artifact to re-run when it turns out you needed one more edit.

---

## 3. `grep -c` prints `0` **and** exits 1

**Cost: a retry limiter that silently never limited.**

```bash
count=$(grep -c "^ATTEMPT" state 2>/dev/null || echo 0)   # count is now "0\n0"
[ "$count" -ge 3 ] && ...                                 # [: 0\n0: integer expression expected
```

`grep -c` already prints `0` on no match; the `|| echo 0` appends a SECOND zero, and the test then
errors out every iteration — which reads as "condition false", so the guard never fires.

**Correct:**

```bash
count=$(grep -c "^ATTEMPT" state 2>/dev/null) || count=0
count=${count:-0}
```

---

## 4. A long `find` / `du` / `grep -r` over ssh hits the 120 s tool window

**Made 4 times.** `find /root -name x`, `du -sh /root/bench/*`, `grep -rl pattern ws/*/apps` — each
walks `node_modules` and gets backgrounded mid-answer, so you poll for output you could have had
immediately.

**Correct: scope it before you run it.** `-maxdepth`, `-not -path "*/node_modules/*"`, or name the
two directories you actually mean. If it genuinely is long, `run_in_background: true` from the
start rather than discovering it the hard way.

---

## 5. Do not edit a bash script that is currently running

Bash reads a script incrementally, by byte offset. Editing a running driver can make it resume in
the middle of a different line. Two safe alternatives:

- Edit a file that has NOT started yet (a later stage in a chain).
- Let the running one finish and chain the next one on its **pid** (see rule 1).

---

## 6. `install.sh` can leave the plugin disabled — and enabling it does not help *this* session

`testing.md` §5 documents this for releases; it applies to a plain `install.sh` too, and it bites
in a specific order that is easy to misread:

1. Run `install.sh` while Claude Code is running.
2. The running app owns `~/.claude/settings.json` and persists its older view afterwards.
3. **This** session keeps working; the NEXT one starts with zero zuvo skills.
4. `claude plugin enable` fixes the file but **not the running session** — skills and hooks are
   indexed at session start.

So `Unknown skill: zuvo:review` is not necessarily a missing skill. Check
`claude plugin list | grep -A3 zuvo` first, enable if needed, and **restart** — the enable-guard
hook heals it at the next start, not mid-flight.

---

## 7. Bench rig: a per-run home is copied at run START

`run_arm.sh` copies hooks and settings into `homes/<case>-<arm>/` when the run begins. Editing a
hook while a batch is in flight therefore changes NOTHING for the containers already up, and
everything for the next batch — which silently makes the two halves incomparable.

**If you fix an instrument mid-sweep, re-queue every batch that started before the fix.** A batch
measured with the old instrument is not a data point about the new one.

---

## 8. `cp -a SRC DST` nests instead of replacing when DST already exists

**Cost: one rep of a benchmark case given up after burning all three of its attempts, and twenty
minutes of forensics aimed at the wrong layer.**

```bash
rm -rf "$WS"
cp -a "$REPO" "$WS"        # if anything recreated $WS in between, you now have $WS/repo/...
```

The copy succeeds and prints nothing. What you get is a tree the right SIZE (so a `du`-based guard
passes) with every path one level deeper than expected (so a `[ -f "$WS/$SRC" ]` guard fires). On
the rig it surfaced as an agent politely reporting that the workspace was empty and asking where
the repository was — which reads as a model failure, not a copy failure.

**Correct: make the target on purpose and copy CONTENTS.** The trailing `/.` makes the result
independent of whether the target already existed.

```bash
rm -rf "$WS"; mkdir -p "$WS"
cp -a "$REPO/." "$WS/"
```

Two corollaries, both of which turned one bad copy into three dead attempts:

- **A failure path must delete what it half-built.** The guard above exited without removing `$WS`,
  so every retry inherited the poisoned tree and failed identically.
- **A relaunch must clear the workspace, not just the run directory.** A supervisor that resets
  `runs/<case>/<arm>` and leaves `ws/<case>-<arm>` is not retrying from scratch.

---

## The two rules that would have prevented most of this

**Read the runbook before typing the command.** `tests/gates/test-gate-consistency.sh` and
`scripts/audit-registry-integrity.py` are both named in `testing.md` §1. They were typed from
memory as `tests/skill-suite/...` and as a test file, and both failed with "No such file or
directory" — a lookup that would have cost five seconds.

**A failure with no output is an environment failure until proven otherwise.** `exit 255` from ssh,
`exit 1` with an empty stderr, a probe that returns "no marker" — none of those are evidence about
the thing you were testing. Every one of them in this session turned out to be the harness: a
killed shell, a full disk, a container that never started. Check `df`, check the exit code's
source, and re-run the probe correctly BEFORE concluding anything about the code.
