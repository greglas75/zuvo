## A writer is reviewed by the other vendor — Claude by Codex gpt-6-sol, Codex by Opus 5.5

- `scripts/reviewer-model-route.sh` answers a six-key contract (status, client, model, effort, route,
  reason). A Claude writer routes to Codex gpt-6-sol, a Codex writer to Claude Opus 5.5
  (`route=cross-vendor`); an unknown writer is no longer assumed to be Sonnet. `--fallback` gives an
  honestly labelled `in-family-fallback`, never reported as cross-vendor.
- New `~/.zuvo/model-run` runs the routed reviewer isolated (own `CODEX_HOME`, neutral cwd, empty MCP,
  bounded budget, process-group teardown) and refuses to pass a fallback off as the real thing. Exit
  0 ok, 1 unavailable, 2 usage, 3/4 answer or output failures, 124 timeout.
- `zuvo:test-audit` batch auditors run as that routed reviewer on Claude Code and Codex hosts, through
  the new `~/.zuvo/test-audit-batch` (run lock, parallel groups, a DONE gate per listed file). Cursor,
  Antigravity and Kimi keep the in-harness agent. The batch prompt is a shared include any client can
  be handed; a file with nothing applicable is `Tier: INCOMPLETE`.
- The reviewer preflight checks the routed reviewer first. An `ok` route on Cursor, Kimi and
  Antigravity stays ok (a regression caught by the aggregate review).
- One model-id grammar, one route-contract check and one same-vendor guard, in
  `scripts/lib/model-subprocess.sh`; one per-agent model gate for all four dist builds in
  `scripts/lib/reviewer-lanes.sh`. Codex agent tiers (haiku/sonnet/opus) take their ids from the model
  registry — they used to ship with ids the account refuses.
- Fixed along the way: Homebrew bash 5.3 crashed (status 139) in forked subshells of an `env -i` shell
  with no locale variable, which made the Antigravity build refuse every agent now and then; sourcing
  the runner library now names the C locale when LC_ALL and LANG are both unset.
