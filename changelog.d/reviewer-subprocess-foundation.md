## One shared reviewer runner for the driver, the router and the preflight

- `scripts/lib/model-subprocess.sh` is now the single implementation of everything the three
  reviewer scripts used to carry separately (and had let drift apart): Codex host detection (all four
  signals), codex/claude binary resolution, the isolated `CODEX_HOME`, the timeout + process-group
  reap, and the auth-stub / CLI-version guards. `adversarial-review.sh`'s codex and claude lanes run
  through it byte for byte as before (golden replay); the router and the preflight answer from it.
- Isolation: a reviewer client gets its own `CODEX_HOME` (never the user's `mcp_servers` or model),
  a neutral cwd, an empty strict MCP config, and a bounded budget; the source `CODEX_HOME` is never
  built over, so its `auth.json` cannot be deleted by a mis-aimed call.
- Preflight canaries must COMPUTE an answer (the product of 6 and 7 → a line reading `42`, exit 0).
  An echoing client, answer-then-crash and answer-then-hang all fail the canary.
- A missing or incomplete library fails loudly and is never held against a lane: codex/claude record
  `no-runner` (kept out of the persistent provider-health ledger), the router prints its fail-closed
  six-key sentinel, and every other lane still runs.
- `install.sh` and the Antigravity/Kimi builds ship `scripts/lib/` beside every installed driver
  (atomic, content-verified copies); a stale `~/.zuvo/lib/model-subprocess.sh` from an older install
  is removed so it cannot shadow the fresh one.
- Fixed along the way: the auth-stub 600-byte limit is measured in bytes under any locale (a UTF-8
  review mentioning login was discarded as an auth failure); `ZUVO_CODEX_VERSION_TIMEOUT=0` no longer
  disables the version-probe timeout.
