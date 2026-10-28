## review and build run `codesift dup-check` on the branch's new code

- `zuvo:review` gets a mandatory row in its tool table: when the diff adds or changes production code and
  the `codesift` CLI has `dup-check`, the review runs `codesift dup-check --base <REVIEWED_FROM>`. A copy of
  existing code is MUST-FIX unless it carries `codesift-dup-ok: <reason>` and the reason holds.
- `zuvo:build` runs the same check in its verification step on every tier and replaces a copy with the
  existing symbol before reporting done.
- Builds whose CodeSift has no `dup-check` record `dup-check: absent-in-build` and continue.
