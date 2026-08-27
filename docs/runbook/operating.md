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

`pgrep -c` behaves identically, and the consequence is worse than a malformed log line. A watchdog
written *hours after this entry was added* used `drivers=$(pgrep -c -f ... || echo 0)`; `[ "$drivers"
-eq 0 ]` then errored on the two-line value instead of being true, which silently disabled the
idle detection that was the whole reason the watchdog existed. It logged a heartbeat every minute
and never once reported the condition it was there to report.

Two things worth taking from that. **A guard built on a malformed comparison fails OPEN and looks
healthy** — the log filled up, the process was alive, and the check was dead. And **writing the
entry does not inoculate you against the mistake**: this one was documented and then committed
anyway, in the same session, by the person who documented it. The habit that catches it is not
memory, it is reading back what the variable actually contains.

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

## 9. Backticks in a `git commit -m` message are executed by the shell

```bash
git commit -m "slimming `testing` for tokens regressed it"   # the shell runs `testing`
```

You get `command not found: testing` on stderr — and the commit still succeeds, with the backticked
words **silently removed** from the message. So the failure looks like noise from an unrelated step
while the artifact it damaged is already written. Prose in commit messages is full of backticked
identifiers, which is exactly why this one is easy to hit and easy to miss.

**Correct: pass the message on stdin or from a file**, which is what every long message here should
use anyway.

```bash
git commit -F - <<'EOF'
... backticks, dollars, quotes, all literal ...
EOF
```

An unpushed commit can be amended to repair it — but check `git log -1 --format=%B` first, because
the damage is invisible from the command's exit code.

---

## 10. Counting a thing before looking at how it is stored (10x in one session)

This is not a shell trap; it is the failure mode that produced every wrong number in the
poll-cost work, and it recurred **ten times in a single day** in ten different costumes. Each time
the result was a confident figure that read like knowledge.

| claimed | what was actually read |
|---|---|
| "8 red suites" in ten live refactors | the word `FAIL` in the **skills' own prose** being read — the run-logger's verdict vocabulary, `worktree`'s "FAIL on an aborted merge" |
| "3 production writes" | `apply_patch` is a registered **tool name**, so it appears in every call's metadata; `arguments` was empty |
| "no change since the install" | filtered on the file's **mtime** instead of each record's timestamp, so sessions that began earlier contributed their whole history |
| "0 tests, 0 blocking, 0 edits" | read `arguments`; Codex puts the command in **`input`**, as JS wrapping `tools.exec_command({cmd: …})` |
| "1 blocking call in 11,690" | the same empty field, this time in the shipped tool |
| "1,327 blocking" | `rt` credited as blocking while **3,338 polls followed those calls** — it was the START of a poll loop |
| "1,099 polls" | `write_stdin` with empty `chars` **is** a poll (the tool's own description says so) and was never counted — the real figure was 4.6x higher |
| "two platforms did not get the change" | checked the paths I expected; the installer had **printed** the real ones (Cursor reads the Claude cache; Antigravity moved to `~/.gemini/config/skills`) |
| "the fix is absent" (from a reviewer) | I sent them `git diff …HEAD` while the fix sat **uncommitted** in the working tree |
| a guard in `codex-poll-guard.sh` that matched nothing | built the search text with `json.dumps` over a dict whose value **already held escaped JSON**, so `"chars":""` became `\"chars\":\"\"` |

Three of these were caught before being reported. Seven were not, and one of those nearly told the
user that seven of their ten refactors were violating the protocol when every one had a green,
SHA-stamped baseline recorded — in the contract, which is where the protocol says the proof lives.

**The rule is an action, not an attitude.** Before reporting any count:

```bash
# 1. print a few of the matches and READ them
<your detector> | head -5
# 2. print the record you are parsing, and find the field with your own eyes
python3 -c 'import json;d=json.loads(open("<one record>").read());print(sorted(d))'
```

Two corollaries that each cost a separate hour:

- **A zero from an instrument that cannot see the thing is not a finding.** It reads exactly like
  one. `scan_codex` reported "0 blocking" three times running — first with no code path that could
  set the column, then with the path reading an empty field, then with the line prefilter dropping
  the row before the classifier saw it. Every fix looked complete and still returned the flattering
  answer.
- **When you add a classifier, widen the filter in front of it in the SAME edit.** That specific
  pairing failed three times in one file. The counter and the prefilter disagreed, and the prefilter
  won silently.

And one about wording, from the finding that nearly went out wrong: **a detector should name the
state of its own knowledge, not the state of the world.** "No baseline visible to this watcher" is a
statement it can support; "PROTOCOL VIOLATION" is a statement about someone else's work, and the
difference is the whole distance between a tool and an accusation.

## The three rules that would have prevented most of this

**Read the runbook before typing the command.** `tests/gates/test-gate-consistency.sh` and
`scripts/audit-registry-integrity.py` are both named in `testing.md` §1. They were typed from
memory as `tests/skill-suite/...` and as a test file, and both failed with "No such file or
directory" — a lookup that would have cost five seconds.

**A failure with no output is an environment failure until proven otherwise.** `exit 255` from ssh,
`exit 1` with an empty stderr, a probe that returns "no marker" — none of those are evidence about
the thing you were testing. Every one of them in this session turned out to be the harness: a
killed shell, a full disk, a container that never started. Check `df`, check the exit code's
source, and re-run the probe correctly BEFORE concluding anything about the code.

**Look at the data before you count it.** Every wrong number in §10 came from a detector written
against the shape its author expected rather than the shape on disk, and each one returned a clean,
quotable figure — usually a zero. Print five matches and read them; open one record and list its
keys. It costs one command, and it is the only one of these three rules that was broken ten times
in a single day.

## 11. Codex hooks: read, parsed, trusted — and not executed (2026-08-27)

**Before building anything that depends on a Codex hook, prove one fires.** A `touch` is enough,
and it takes one minute. Everything below was built on the assumption that a registered hook runs,
and that assumption was never tested until the guard had been through two reviews and four fixes.

What is true, each verified separately:

- The event vocabulary is exactly these eight, from the modules compiled into the binary
  (`hooks/src/events/*.rs`): `compact`, `permission_request`, `post_tool_use`, `pre_tool_use`,
  `session_end`, `session_start`, `stop`, `user_prompt_submit`. **None of them sees the model's own
  text**, so no hook can suppress narration directly.
- `~/.codex/hooks.json` IS read: give it a wrong root key and Codex says so —
  `failed to parse hooks config …: unknown field \`pre_tool_use\`, expected \`description\` or \`hooks\``.
  The root is `{"hooks": {"<event>": [{"matcher": …, "hooks": [{"type":"command", …}]}]}}`.
- The `CodexHooks` feature is enabled (it appears in the `features=[…]` line of the session log).
- Hook trust is real — `--dangerously-bypass-hook-trust` exists and `config.toml` carries
  `[hooks.state."<path>:<event>:0:0"] trusted_hash`. A stale entry from an older file will not match
  a new one.

And what is also true: **with a valid config, matcher `.*`, trust bypassed, and a hook whose entire
body is `touch /tmp/marker`, no marker appears.** Reproduced on BOTH builds present on this machine
— the Homebrew CLI (0.144.6) and the app's own binary (0.150.0-alpha.8) — for `session_start` and
`pre_tool_use`, at user level (`~/.codex/hooks.json`) and project level (`.codex/hooks.json`), in
JSON and via a `-c hooks.pre_tool_use=[…]` TOML override. Nothing runs, and nothing is logged about
why.

The one path not reachable from a shell is the **desktop GUI**, which is a different execution mode
— the dispatcher carries strings like `command execution approval is not supported in exec mode`,
so exec mode demonstrably disables some hook-driven behaviour. So the open question is narrow: does
the GUI run them? To answer it, `touch ~/.zuvo/guard-trace`, restart the Codex app (registration is
read at launch), and check whether the file grows. Until it does, treat every Codex-side hook in
this repo as **built but unproven**, and do not describe one as enforcement.

Two habits this cost:

- **A hook that registers is not a hook that runs.** `install.sh` printing `✓ registered` describes
  a file write, nothing more — the same gap as `✓ Plugin enabled` in the Claude Code section above.
- **Check which binary you are testing.** `codex` on PATH was a Homebrew build from six weeks
  earlier than the app's. Every experiment ran against the wrong one before anybody noticed, and a
  negative result from an old binary means nothing at all.

### What to do instead: put the rule in the shell

Codex runs every command as `/bin/zsh -lc '<command>'`, and a zsh **always** reads `~/.zshenv`.
So the rule the hook could not deliver can live in the shell, where it demonstrably fires:

```
$ codex exec  →  /bin/zsh -lc 'sleep 25; echo AFTERSLEEP'
 succeeded in 0ms:                      ← was 25 s
zuvo: declining `sleep 25` outside a loop — it costs one whole turn per interval.
AFTERSLEEP                              ← the rest of the command still ran
```

`hooks/zuvo-sleep-guard.zsh`, installed to `~/.zuvo/` and sourced from `~/.zshenv` by
`install.sh`. It is narrow on purpose, because it sits in front of every `sleep` on the machine:

- only a **non-interactive** zsh with a `-c` string (an interactive `sleep 5` is untouched, and so
  is a script file — a script has no `ZSH_EXECUTION_STRING`, only an inline `-c` command does);
- only when an **ancestor process is codex** — verified against the real chain,
  `/Applications/ChatGPT.app/Contents/Resources/codex exec …`. Do not simulate this with a stub
  that `exec`s: exec replaces argv, the stub's name disappears, and the test then proves nothing;
- only `sleep >= 5` **outside** a `do … done`, so a settling pause and a blocking loop both pass;
- it **declines the delay, it does not kill the command** — everything after the `;` still runs;
- off in one line: `touch ~/.zuvo/no-sleep-guard`.

The general point is worth more than the guard: when a harness's own extension point cannot be
shown to work, look for the layer underneath it that everything must pass through anyway.

### How much of the problem the shell layer can actually reach: 9.4%

Measured over 32,869 tool calls in the 300 most recent local sessions, split by which layer could
possibly see each waiting call:

| Costume | Calls | Share of waiting | Reachable by |
|---|---|---|---|
| `wait` / `wait_agent` — a TOOL call inside code mode | 4,363 | **88.5%** | a Codex hook only, and none fires |
| bare `sleep N` in a shell command | 465 | 9.4% | the shell guard (works) |
| `sleep` inside a loop — already correct | 102 | 2.1% | — |

So the mechanism that provably works addresses **under a tenth** of the waste, and the remaining
88.5% has no working lever on this machine at all: it is a tool call made inside the model's own
JavaScript, no shell is involved, and the hook that would see it does not run. `codex` also carries
a server-side `default_exec_yield_time_ms`, which would fix the whole class at a stroke — but it is
not present in any local config and cannot be set from here.

Say this number out loud whenever the guards come up. A guard that covers 9.4% and is described as
"the fix" is the same failure as a gate that reports PASS without running: the work is real, and
the claim is still false.
