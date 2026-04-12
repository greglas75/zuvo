# Rust Conventions

Active when Rust is detected (`Cargo.toml`, `.rs` files, or Rust web frameworks). Not applicable to non-Rust projects.

---

## Request Extraction

- Use typed extractors for params, query values, and JSON bodies.
- Validate optional fields and enum/state transitions explicitly.
- Do not deserialize untrusted payloads into overly broad types without validation.

## Data and Output Safety

- Prefer parameterized SQL via `sqlx`, Diesel, or equivalent.
- Treat custom HTML responses and unsafe template helpers as sinks.
- Validate redirect targets and outbound URLs assembled from request data.

## Files, Commands, and Archives

- Normalize file paths before file-system operations.
- Process execution and shell wrappers must never accept raw user strings.
- Validate archive extraction and upload paths against traversal.

## Pentest Focus

- SQL construction in handlers and services
- extractor-to-sink flows
- auth middleware and state guards
- path and command execution boundaries
- deserialization and replay/state-machine bugs

## axum / actix / rocket Overlays

### axum

- Verify extractor validation plus tower middleware order.
- Check websocket or SSE auth on subscription paths, not just handshake setup.
- Review shared state access for tenant/resource scoping leaks.

### actix

- Check extractor and guard coverage on every mutation route.
- Review `wrap` / `service` order for auth, rate limiting, and error handling.
- Multipart and temp-file handling must enforce size and path safety.

### rocket

- Request guards and fairings can hide auth gaps; verify both route and guard behavior.
- Review form parsing, temporary file handling, and redirect construction.
- Route rank and catchers must not expose privileged fallback behavior.
