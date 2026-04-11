fact: wrapper returned `"No input provided"`.
cause: default `tests/fixtures/response-protocol/manifest.json` path was likely skipped.
risk: `bash scripts/eval-response-protocol.sh` exits early.
next: load the manifest by default.
conf: likely
