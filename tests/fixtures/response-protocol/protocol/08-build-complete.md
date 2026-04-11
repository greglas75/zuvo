## BUILD COMPLETE

Implemented the compressed response protocol rollout for hook-enabled main assistant sessions.

Changed:
- `shared/includes/compressed-response-protocol.md`
- `hooks/session-start`
- `skills/using-zuvo/SKILL.md`

Verification:
- `bash scripts/validate-response-protocol.sh`
- `bash scripts/eval-response-protocol.sh`

Residual risk: hookless sessions remain degraded in v1.
