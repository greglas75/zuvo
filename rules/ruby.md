# Ruby Conventions

Active when Ruby is detected (`Gemfile`, `.rb` files, Rails/Sinatra/Hanami projects). Not applicable to non-Ruby projects.

---

## Controller and Params Safety

- Use strong parameters or equivalent whitelist validation for all controller inputs.
- Do not trust route params, cookies, or headers without validation.
- `before_action` auth is necessary but not sufficient; resource-level authorization still applies.

## Data and Output Safety

- Prefer ActiveRecord parameterization. Treat raw SQL and interpolated where clauses as sinks.
- Treat `html_safe`, raw ERB output, and unsafe markdown rendering as XSS sinks.
- Validate redirect targets and `return_to` style parameters.

## Files, Jobs, and Serialization

- Validate uploads, attachment paths, and archive extraction.
- Treat YAML, Marshal, and dynamic constantization as dangerous deserialization sinks.
- Background jobs processing webhook or user payloads must validate input at job boundaries too.

## Pentest Focus

- raw SQL and interpolated queries
- `html_safe` and unsafe render helpers
- redirects and return URLs
- file/attachment handling
- controller authz gaps and policy coverage

## Rails Overlay

- Verify `before_action` auth plus per-resource authorization (`Pundit`, `CanCanCan`, or equivalent).
- Treat `redirect_to(params[:return_to])`, `store_location_for`, and custom `return_to` flows as open-redirect sinks.
- Treat `render html:` and `html_safe` content paths as XSS sinks.
- Reload records server-side before mutation. Do not trust IDs or serialized attrs from forms, jobs, or cookies.

## Sidekiq Overlay

- Jobs must re-validate permissions and resource state when executed; enqueue-time auth is not enough.
- Do not enqueue full user-controlled payloads when a stable ID can be reloaded server-side.
- Retries must not turn single-use tokens or links into replayable workflows.
- Signed GlobalID, message verifiers, or server-side record lookups count as safe patterns when verified.
