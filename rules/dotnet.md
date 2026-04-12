# .NET Conventions

Active when .NET is detected (`*.csproj`, `*.sln`, `Directory.Build.props`, or ASP.NET projects). Not applicable to non-.NET projects.

---

## Request and Model Safety

- Validate body, query, route, header, and file inputs through model binding plus explicit validation.
- Resource-level authorization must complement `[Authorize]` attributes.
- Minimal APIs need the same auth and validation rigor as MVC controllers.

## Data and Output Safety

- Prefer EF Core or parameterized SQL. Treat raw SQL and dynamic LINQ as sinks.
- Treat `Html.Raw`, unsafe Razor rendering, and string-built HTML as XSS sinks.
- Validate redirect targets and response headers built from request data.

## Files, Processes, and Archives

- Normalize file paths before reads, writes, deletes, or extraction.
- Process execution APIs must never accept raw user-built command strings.
- Validate upload content type, size, and storage path server-side.

## Pentest Focus

- EF Core / SQL boundary checks
- `[Authorize]` without resource ownership checks
- `Html.Raw` and unsafe Razor paths
- redirects, header reflection, and file handling
- webhook, SignalR, and minimal-API auth gaps

## ASP.NET MVC Overlay

- Validate model-binding results and anti-forgery protections on cookie-authenticated form posts.
- `[Authorize]` on a controller is not sufficient without resource ownership checks in the action path.
- Treat `Html.Raw`, dynamic view data, and custom tag helpers as XSS sinks.

## Minimal API Overlay

- `RequireAuthorization()` does not replace per-resource authorization.
- Minimal APIs often skip validation parity with MVC; verify DTO or manual validation explicitly.
- Route-group middleware order and endpoint filters must be checked for public/mutation boundaries.

## SignalR Overlay

- Connection-level auth is not enough; hub methods and group joins need resource-level auth.
- Group names, channel IDs, and tenant IDs derived from user input must be validated and scoped.
- Broadcast methods must not leak cross-tenant data through shared groups.
