## Refactor Radar: trustworthy discovery before execution

- Freeze code at a git SHA even for dirty HEAD; treat worktrees as temporary collision
  evidence, never durable candidate identities or permanent name exclusions.
- Replace implicit queue/history mutations with DISCOVER and explicitly validated REGISTER.
  New schema 2 binds decisions to source/profile/policy/evidence and preserves old artifacts.
- Correct independent nesting, family grouping, unique fix churn/fan-in/test census and
  source roles. Label regex complexity estimates and test LOC honestly; remove unjustified
  novelty penalties and blanket recent-refactor exclusions.
- Verify paginated GitHub/Bitbucket evidence and expose incomplete availability as UNKNOWN.
  Allow a short-lived local control snapshot for farm scans of the same product/SHA.
- Use purpose-specific refactor acceptance criteria instead of universal CC or bundle-count
  targets. Document secondary discovery lanes, grouping and unimplemented fleet capabilities.
- Ship a complete stdlib radar bundle through the common installer; add real-git regression,
  provider-boundary and installed-bundle tests, plus updated behavioral eval scenarios.
- Canonicalize SSH/HTTPS identities without credentials; require same-repository promotion
  PRs, exact provider hosts and safe pagination paths. Bound subprocess memory and file reads,
  and publish reports atomically without replacing another writer's artifact.
