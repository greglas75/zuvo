# Network mocking policy

How generated specs are allowed to intercept, allow and assert on network traffic. Gate IDs
are defined in `quality-gates.md`. Two of them are the backbone of this file, and neither is
a flag-only advisory:

- **E2E-Q4 -- fail-closed network policy -- is CRITICAL.**
- **E2E-Q5 -- mutation contract validation -- is CRITICAL.**

General assertion-quality rules live in `../../../rules/testing.md`.

## Fail-closed default

A generated spec installs a **fail-closed** network policy. Every request is classified by
the full match key -- hostname, method and pathname -- and anything without a matching rule
is denied and recorded, never passed through.

An allowed host is a **permitted destination, never an unchecked one**. Host membership is
necessary, not sufficient: a request to an allowed host still needs a rule for its method
and pathname, and mutations are recorded and contract-checked regardless of which host they
target -- including requests that are passed through to the app's own origin. Anything less
and E2E-Q5 goes blind exactly where it matters, because a mutation that is never intercepted
is a mutation no contract check can see.

```typescript
// e2e/fixtures/network-policy.ts
const MUTATING = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);

type Rule = {
  hostname: string;
  method: string;
  pathname: string;
  fulfill?: FulfillOptions; // omit to let the request reach its real destination
};

export async function installNetworkPolicy(context: BrowserContext, rules: Rule[]) {
  const blocked: string[] = [];
  const mutations: Request[] = [];

  // DENY-ALL SENTINEL. Registered on the CONTEXT, before any specific mock --
  // see "Registration order and route precedence" below. It classifies and
  // blocks; it never invents a response body.
  await context.route('**/*', async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const method = request.method();

    const rule = rules.find(
      (r) => r.hostname === url.hostname && r.method === method && r.pathname === url.pathname,
    );

    if (!rule) {
      // Allowed host or not: an unmatched method plus pathname is not permitted.
      blocked.push(`${method} ${url.hostname}${url.pathname}`);
      return route.abort('blockedbyclient');
    }

    // Recorded BEFORE the request is served, so the E2E-Q5 contract check sees
    // every mutation -- fulfilled or passed through, app origin or third party.
    if (MUTATING.has(method)) mutations.push(request);

    return rule.fulfill ? route.fulfill(rule.fulfill) : route.continue();
  });

  return { blocked, mutations };
}
```

Denials are only useful if somebody sees them, so the policy handle is surfaced in a hook:

```typescript
test.afterEach(async () => {
  const { blocked } = policy;
  if (blocked.length === 0) return;
  // Every blocked request is printed, so an unnoticed analytics, telemetry or
  // font call becomes a decision instead of ambient traffic.
  console.warn(`network policy blocked:\n  ${blocked.join('\n  ')}`);
  // An undeclared request to the app's own origin is an ERROR, not a note: the
  // app called something this spec never declared.
  const internal = blocked.filter((b) => b.includes(APP_HOST));
  expect(internal, 'app called an undeclared internal endpoint').toEqual([]);
});
```

### Two kinds of traffic `context.route` does NOT see

"Anything without a matching rule is denied" is true only for traffic Playwright routes, and
two paths escape it. Both must be closed explicitly, or E2E-Q4 reports a fail-closed policy
over a spec that still reached the network.

1. **Service workers.** Requests a registered service worker issues do not pass through
   `page.route` or `context.route`. On any PWA or offline-cached build, the sentinel above sees
   nothing and the app talks to real third parties while the gate reads green. Block them at
   the context, which also removes the SW's own cache as a source of nondeterminism:

   ```typescript
   test.use({ serviceWorkers: 'block' });   // spec-level, or in playwright.config
   ```

2. **`APIRequestContext`** — the `request` fixture, and `page.request`. These are not browser
   traffic and no `route` handler applies to them, so a teardown or setup call made through
   them bypasses the policy entirely. That matters most for mutations: a cleanup `DELETE` is
   exactly the kind of request the origin gate exists to govern. Send such calls only to the
   resolved app origin, and treat any other destination as needing the same consent a
   non-local origin needs in the spec body. Prefer `page.request` over the bare `request`
   fixture — it carries the browser context's session, whereas `request` does not and will
   401 on an authenticated route.

A spec claiming E2E-Q4 must therefore emit the service-worker block AND keep its
`APIRequestContext` calls on the app origin. Neither is optional, because neither is visible
in the `blocked` list the policy returns — an escaped request leaves no trace there at all.

Rationale: a pass-through default means the test's behavior depends on whatever the machine
can reach. It hits real third parties from CI, it goes green when an unmocked internal
endpoint happens to be up, and it hides the fact that the app called something nobody
intended. Fail-closed turns each of those into a visible, named failure the first time it
happens. Nothing is added to the rule list to make a test pass without a recorded reason.

## Registration order and route precedence

Playwright matches route handlers in **reverse registration order** inside a scope, and
`page.route()` handlers take **precedence** over `context.route()` handlers for the same
request. A catch-all sentinel that is registered last, or at the more specific scope, will
therefore shadow the very mocks this file tells authors to write -- silently, with no error,
because a shadowed handler simply never runs. This is a Playwright semantics trap; do not
expect a reader to infer it.

The shape that behaves correctly:

1. Install the deny-all sentinel once, on the **context**, in a fixture -- before any test
   body runs.
2. Register per-test mocks with **`page.route()`**. Page-level handlers win over
   context-level ones, so a specific rule always beats the sentinel.
3. If a sentinel and a specific handler must share a scope, register the **sentinel first**
   so the later, more specific handler is consulted first.
4. A handler that decides not to serve a request calls `route.fallback()` to hand it to the
   next matching handler, rather than continuing it to the network.

## Match key: hostname plus method plus pathname

A route rule matches on exactly three things: the request's **hostname**, its **method**,
and its **pathname**. All three are compared explicitly; the pathname is compared as a
whole path or against a bounded pattern, never as a substring.

```typescript
const rule = {
  hostname: 'api.example.test',
  method: 'POST',
  pathname: '/v1/projects',
};
```

Query strings and headers are inputs to the mutation contract check below, not to the match
key -- matching on them makes rules silently miss when the app adds a tracking parameter.

## Allowed-host list

Each spec declares an explicit allowed-host list. It gates destinations; the rule list above
still gates individual requests. Hosts are exact names, and the list is kept as small as the
scenario needs:

```typescript
const ALLOWED_HOSTS = ['localhost', '127.0.0.1', '[::1]', 'api.example.test'];
```

- The application's own origin is allowed by default; nothing else is. Include the IPv6
  loopback `[::1]` alongside `localhost` and `127.0.0.1` -- many dev servers bind to it, and
  `url.hostname` renders it with the brackets, so an entry of `::1` does not match.
- A wildcard host entry is not permitted. If a scenario genuinely needs a family of
  subdomains, each one is listed.
- Every entry beyond the app origin carries a one-line reason in the spec header.

## Broad directory globs are banned

Route patterns such as `**/api/**`, `**/graphql/**` or `**/*.json` are banned outright when
they are used to **intercept and fulfil**. They match on a path fragment, so they capture
whatever else happens to contain that fragment.

**The incident this rule comes from:** a spec routed `**/api/**` to intercept the app's REST
calls. Under the Vite dev server it also matched a *source module* whose path contained
`/api/` -- the module was served as an intercepted mock instead of JavaScript, so the page
failed to boot in a way that looked like an app bug rather than a test bug. The same rule
did not match the app's telemetry endpoint, which lived on a different path shape, so Sentry
traffic escaped the mock and real events were sent from CI. One glob produced both failure
directions at once: it caught what it should not have, and missed what it should have.

Use hostname plus method plus pathname rules instead. If a scenario needs several endpoints,
it declares several rules -- an explicit list is longer and is the point.

### The one legitimate catch-all: the deny-all sentinel

The fail-closed handler above registers `'**/*'`, which is the broadest glob there is. That
is deliberate and it is not a violation of the rule in this section. The distinction:

| Use of a catch-all | Verdict |
|--------------------|---------|
| Deny-all sentinel that classifies every request by the full match key and blocks anything unmatched | Required. This IS the fail-closed policy |
| Broad glob used to INTERCEPT and FULFIL a family of endpoints with a canned response | Banned. This is the Vite source-module incident above |

The sentinel is safe precisely because it never invents a response: it only decides
permitted or blocked, on the full key, and records what it blocked. A glob that fulfils
decides *content* on a path fragment, which is where it starts answering for files and
endpoints nobody enumerated. E2E-Q4's evidence line ("route pattern is a directory glob")
refers to the fulfilling kind -- a sentinel plus explicit rules passes the gate.

## Mutation contract validation

For every mutation (POST, PUT, PATCH, DELETE) the spec asserts on what the app actually
sent, not merely that something was sent to the right URL. This is E2E-Q5 and it is where a
mock earns its keep:

- **Body** -- the fields the server requires are present, with the values the scenario drove
  in. A create-project test asserts the project name it typed, not just a non-empty body.
- **Query** -- parameters the endpoint's behavior depends on, such as pagination or scoping.
- **Headers** -- only the ones the server genuinely relies on: content type, auth, tenant
  scoping, idempotency keys. Do not assert on incidental headers, which just makes the spec
  brittle.

**Register the listener BEFORE the action that triggers the request.** Awaiting
`waitForRequest` after the click is a race: a fast request can fire and be gone before the
listener attaches, and the test then fails with a timeout that looks like a broken app.

```typescript
// Listener first, action second, await third.
const requestPromise = page.waitForRequest(
  (r) => r.method() === 'POST' && new URL(r.url()).pathname === '/v1/projects',
);
await page.getByRole('button', { name: 'Create project' }).click();
const request = await requestPromise;

// headers() is a plain object: a missing header reads back as undefined, so
// guard before calling a string method on it.
const contentType = request.headers()['content-type'] ?? '';
expect(contentType).toContain('application/json');

// postDataJSON() returns null when there is no body and throws when the body is
// neither JSON nor form-urlencoded -- multipart uploads and binary payloads hit
// exactly that path -- so read the raw body and parse it per content type.
const raw = request.postData();
expect(raw, 'mutation sent no request body').not.toBeNull();
expect(JSON.parse(raw ?? '{}')).toMatchObject({ name: uniqueName, visibility: 'private' });
```

For a multipart or form-encoded endpoint, parse with the matching decoder instead of
`JSON.parse`, and assert on the decoded fields the server reads.

A spec that fulfills a mutation with a canned success response and then asserts only on the
rendered success message proves nothing about the request: the app could have sent an empty
body to the wrong endpoint. Response shape still matters too -- the fulfilled body matches
what the real endpoint returns, so the test does not pass against a shape production never
produces.

## Escape hatch and required justification

Some scenarios genuinely need a passthrough -- recording a fixture from a real backend,
exercising a proxy layer, or testing an integration whose whole point is the outbound call.

The escape hatch is explicit, narrow and documented:

```typescript
// NETWORK-POLICY-EXCEPTION: passthrough for <host> -- <why the mock cannot stand in>
// scope: <which requests>   reviewed: <who / when>
```

Rules for using it:

- It names the exact host and request shape it relaxes. A blanket "allow everything for this
  file" is not an exception, it is the removal of the policy.
- A passthrough rule is still a rule: it carries a method and a pathname, and its mutations
  are still recorded and contract-checked.
- The justification says what the mock cannot express. "Easier" is not a justification.
- Mutating passthrough to a non-local origin is never covered by this hatch; that path is
  governed by the external-mutation consent gate defined in `quality-gates.md`.
- The gate report lists every exception in force, so a spec cannot accumulate them quietly.
