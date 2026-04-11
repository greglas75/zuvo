fact: `hooks/session-start` uses `${RESPONSE_PROTOCOL_MODE,,}`.
risk: macOS `/bin/bash` 3.2 can fail before hook output.
next: normalize with `tr '[:upper:]' '[:lower:]'`.
conf: confirmed
