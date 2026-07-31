# Live validation, origin safety and the verification model

What `zuvo:write-e2e` is allowed to execute, against which origin, and what it may claim
afterwards. Two independent gates live here and neither substitutes for the other:

- **Preflight** answers "can Playwright run at all in this project?"
- **Origin classification** answers "is this URL safe to send traffic at?"

Live probing etiquette (rate, timeouts, identification) follows
`../../../shared/includes/live-probe-protocol.md`. Severity words follow
`../../../shared/includes/severity-vocabulary.md`.

## Preflight: can Playwright run here

Ask the helper, never guess:

```bash
# ~/.zuvo/e2e-preflight probe [dir] -- stdout is exactly one of
# READY | GENERATE_ONLY | BOOTSTRAP_REQUIRED, reasons go to stderr.
if [ -x "$HOME/.zuvo/e2e-preflight" ]; then
  PREFLIGHT="$("$HOME/.zuvo/e2e-preflight" probe "$SCOPE")"
else
  PREFLIGHT="$(manual_detection "$SCOPE")"   # see the fallback below
fi
```

| Preflight state | Evidence | What the run may do |
|-----------------|----------|---------------------|
| READY | Local `playwright` binary answers `--version`, browser cache is non-empty, config or dependency present | Generate specs AND execute them locally. `VERIFIED_LOCAL` is reachable |
| GENERATE_ONLY | No runnable local binary, or the browser cache is empty | Generate and statically check only. Ceiling is `STATIC_CHECKED`; say so in the output |
| BOOTSTRAP_REQUIRED | Playwright is configured or declared but has no runnable local binary | Generate, then print the exact install command for the user to run. The run NEVER installs anything itself |

A `BOOTSTRAP_REQUIRED` project is not broken -- it is uninstalled. Reporting it as a failure
sends the user hunting for a bug that does not exist.

### Fallback when the helper is absent

`~/.zuvo/e2e-preflight` installs from `scripts/zuvo-home/` via `install.sh`, and that install
step only runs in the `both|all` branch. A Codex-only or Cursor-only install therefore has the
skill without the helper. In that case reproduce the SAME three states from the same four
signals -- never improvise a fourth outcome and never treat "helper missing" as READY:

| Signal | How to detect it |
|--------|------------------|
| config | `playwright.config.ts` / `.js` / `.mjs` / `.cts` in the scope dir |
| dependency | `node_modules/@playwright/test/` exists, or `@playwright/test` in a dependency map of `package.json` |
| runnable binary | `node_modules/.bin/playwright --version` executed FROM the project dir, exit 0 within a few seconds |
| browsers | `$PLAYWRIGHT_BROWSERS_PATH` if set, else `~/Library/Caches/ms-playwright` or `~/.cache/ms-playwright`, non-empty |

Classification, identical to the helper's:

- runnable binary AND browsers AND (config OR dependency) -> `READY`
- runnable binary AND no browsers -> `GENERATE_ONLY` (report: browsers not installed)
- no runnable binary AND (config OR dependency declared) -> `BOOTSTRAP_REQUIRED`
- nothing found -> `GENERATE_ONLY`

**NEVER probe or run through unpinned `npx playwright`.** `npx` silently downloads and
installs a package that is not in the project, so a "detection" step mutates the user's
machine and can report READY for a version the project never pinned. Use the local binary or
report the state honestly.

## Origin classification

Every `--live` / `--base-url` target is classified BEFORE a single request is sent, and
re-classified at every navigation after that (see "Classification is continuous"):

```
Origin: LOCAL | STAGING | EXTERNAL_UNKNOWN
```

### LOCAL is a destination, not a name

LOCAL takes two steps, and the second one is the one that matters.

Step 1 -- the URL must match the LOCAL shape:

```
^https?://(localhost|127\.0\.0\.1|\[::1\]|0\.0\.0\.0|host\.docker\.internal|[a-z0-9-]+\.(local|localhost|test))(:\d+)?(/|$)
```

Step 2 -- **LOCAL means loopback only**: `127.0.0.0/8` and `::1`. Every host form except a
literal IP address is resolved first, and every address the resolver returns must be loopback:

| Host form | Check |
|-----------|-------|
| `127.0.0.1`, `[::1]`, `0.0.0.0` | Literal IP addresses -- nothing to resolve, and the ONLY no-resolution cases in this table. `0.0.0.0` as a destination is handled as loopback by the OS |
| `localhost` | Resolved like any other name; every returned address must be in `127.0.0.0/8` or `::1` |
| `*.local`, `*.localhost`, `*.test` | Resolved; every returned address must be in `127.0.0.0/8` or `::1` |
| `host.docker.internal` | Resolved, and admitted ONLY IF it resolves to loopback -- which on Docker Desktop it does not (see below) |

If resolution fails, returns nothing, or returns any address outside loopback, the origin is EXTERNAL_UNKNOWN -- regardless of the suffix and regardless of how local the name looks. Mixed answers fail closed: one routable address in the set is enough to disqualify the whole name.

**Link-local is NOT loopback and is never LOCAL.** The ranges `169.254.0.0/16` and `fe80::/10`
must not be accepted by this check, because `169.254.169.254` is the cloud instance metadata
endpoint: admitting the range would classify a name that resolves to the metadata service as
LOCAL and hand it unrestricted mutating traffic -- an SSRF target, granted by the very file
whose job is to prevent that. This is a deliberate exclusion; do not re-add the range as a
convenience. A genuine link-local dev host goes through STAGING instead -- a human names that
exact host, which is what consent is for.

**`localhost` gets no free pass.** It is an ordinary name that usually resolves to loopback by
convention, and `/etc/hosts` can repoint it like any other entry. A document arguing that names
are not evidence cannot then exempt one name because it reads as trustworthy, so `localhost` is
resolved and checked. Only literal IP forms are axiomatic, because there is nothing left to
look up.

**`host.docker.internal` carve-out.** On Docker Desktop it resolves to the host-gateway bridge
address (a routable private address, not loopback), so under the rule above it classifies as
EXTERNAL_UNKNOWN and stays there. That is the correct outcome, not a bug to work around: the
container's view of the host is not evidence about what is listening there. It remains in the
shape list for the one setup where it is admissible -- an `/etc/hosts` mapping to `127.0.0.1` --
and the run reaches a containerized app either by publishing the port on loopback and targeting
`127.0.0.1`, or by naming the host in `ZUVO_E2E_STAGING_HOSTS`.

**A hostname is not evidence about where traffic goes.** The suffix branch of that regex is a naming convention, and names resolve through `/etc/hosts`, mDNS and internal DNS -- every one of them configured by somebody other than this run. `shop.test` can be an `/etc/hosts` line pointing at a production load balancer; `admin.local` can be an mDNS name claimed by any machine on the network. DNS rebinding is the same defect weaponized: a name that resolves to loopback on the first lookup can resolve to a routable address on the next, so a cached classification is not evidence either -- which is the second reason the check is repeated per navigation rather than kept.

**Resolution is a pre-flight heuristic, not a guarantee (TOCTOU).** Re-resolving a name before navigating does not prove the browser will connect to the address that was checked.
DNS can change between the time of check and the time of connection; the browser keeps its own DNS cache and may reuse an entry this run never observed; a proxy or VPN can route the
connection somewhere else entirely. So the resolution rule above is triage -- it catches the
common cases cheaply and honestly, and it is not a boundary.
The layer that actually enforces the boundary is request-level: the allowed-host list in `network-mocking.md` (E2E-Q4) inspects every real request, redirects and background calls
included, and fails the run the moment an unexpected host is contacted. Resolution decides what
the run is willing to attempt; request-level enforcement decides what it is allowed to complete.
Neither replaces the other, and a run that has only one of them is not gated.

STAGING keeps name matching on purpose: there a HUMAN named the exact host, so the name IS the
authorization. LOCAL's wildcard suffixes are claimed by the environment, and an environment
cannot consent on the operator's behalf.

### STAGING is explicit only

A target is STAGING when, and only when, the operator said so:

- `--allow-external-origin` was passed for this run -- which permits READ-ONLY execution against
  that origin and nothing more (see the consent matrix below), or
- the target host is an EXACT match in `ZUVO_E2E_STAGING_HOSTS` (comma-separated hostnames;
  no wildcards, no suffix matching, no port-insensitive fuzz).

There are no hostname heuristics, and adding one is a defect, not an improvement. A
`staging.` prefix, a `*.vercel.app` domain or a "-dev" suffix are guesses about someone
else's naming convention -- `staging.example.com` can be a customer-facing tenant and a
preview domain can be aliased onto production. Guessing is exactly how a test suite ends up
writing to production.

**EXTERNAL_UNKNOWN is the default for everything else**, including every host that merely
looks internal. On an EXTERNAL_UNKNOWN origin the run generates read-only specs: navigation,
GET traffic, rendering assertions.

Any mutating step is BLOCKED, not warned about, and not emitted behind a comment: a form
submit, a non-GET route, a destructive copy of an existing flow, any spec that would create,
update or delete a record. BLOCKED is a state the run reports and stops at.

| Origin | How it is decided | Generation | Execution |
|--------|-------------------|------------|-----------|
| LOCAL | LOCAL shape AND a loopback/link-local resolved destination | full, mutations included | allowed |
| STAGING | `--allow-external-origin` or exact `ZUVO_E2E_STAGING_HOSTS` match | full, mutations included | read-only; mutating and destructive flows need the second consent below |
| EXTERNAL_UNKNOWN | default, and any failed LOCAL resolution | read-only specs only | none; mutating steps BLOCKED |

### Two consents, four combinations

**Destructive consent is separate from `--allow-external-origin`.** Permission to talk to a
non-local origin is not permission to delete a user, cancel a subscription or wipe a tenant.
The second consent is `--allow-destructive <operation>[,<operation>]`, which names the
operations it authorizes; a mutating or destructive flow outside that named set stays BLOCKED
even on a consented STAGING origin (E2E-Q8).

Execution against a NON-LOCAL origin, all four combinations:

| `--allow-external-origin` | `--allow-destructive` | Read-only flows | Mutating / destructive flows |
|---------------------------|-----------------------|-----------------|------------------------------|
| no | no | BLOCKED | BLOCKED |
| no | yes | BLOCKED | BLOCKED |
| yes | no | allowed | BLOCKED |
| yes | yes | allowed | allowed |

Row 2 is not a typo: destructive consent without a permitted destination grants nothing, so a
stale `--allow-destructive` in a script cannot start authorizing traffic the moment somebody
adds an external base URL. Row 3 is the one the gate exists for -- reaching a staging origin is
routinely fine, and deleting rows in it is a different decision by a different person.

A LOCAL origin needs neither flag: mutations and cleanup run freely there, which is the entire
reason the LOCAL check is on the resolved destination rather than on the name.

## Classification is continuous

Classification is not a one-time check on the base URL. A redirect chain, an SSO bounce or an
in-test `goto` moves the run to a different origin, and the gate must read the CURRENT origin
at the moment of the action -- never the origin the run started on.

- Re-classify on every navigation: `page.goto`, link clicks, form submits that navigate, popups
  and new tabs.
- Follow redirect chains hop by hop: each hop is classified in turn. A 302 into an identity
  provider is a cross-origin bounce and is classified exactly like any other hop, including
  when it lands back on the original host afterwards.
- Enforce at request level, not only before the first action: the allowed-host list from
  `network-mocking.md` (E2E-Q4) sees redirects and background calls that a pre-flight check on
  the base URL never does.
- Re-resolve rather than reuse a cached verdict -- see the DNS-rebinding note above.

**A transition into EXTERNAL_UNKNOWN blocks mutations from that point.**
The test must fail loudly, naming the new origin, the hop that introduced it, and the action
that was refused. The
run does NOT degrade into a quiet read-only mode: a spec that silently continues reports green
having proven nothing, and the operator never finds out that a "localhost" run walked off the
machine.

## Validation states

A flow carries exactly one state, and the state is earned by evidence -- never by intent:

| State | The evidence that earns it |
|-------|----------------------------|
| GENERATED | The spec file was written. Nothing was executed or parsed |
| STATIC_CHECKED | The spec parses, typechecks or lints clean and passes the E2E-Q gates. No browser was launched |
| VERIFIED_LOCAL | The spec was EXECUTED green with `playwright test` against a LOCAL origin |
| VALIDATED_LIVE | The spec was executed green against a consented STAGING origin, with live DOM/locator inspection confirming the oracles |
| BLOCKED | An origin, consent or preflight gate refused the work. This is a stop, never a pass |
| FAILED | The spec was executed and went red. The failure is triaged below, not hidden |

When evidence is missing, record the LOWER state. A spec that was written but never run is
GENERATED, however confident the generator feels about it.

## MCP decoupling

Running `playwright test` locally requires preflight READY and nothing else -- no Playwright
MCP server, no browser automation tool, no network. Playwright MCP gates ONLY live DOM and
locator inspection, which is the step that lifts a flow from VERIFIED_LOCAL to VALIDATED_LIVE.

V1 gated the whole validation phase on MCP availability. That was wrong: it made an
installed, runnable Playwright unusable and pushed every run to report GENERATED, which is
how untested specs entered suites as coverage.

## Failure triage

Executed and red is information, not noise. Categorize each failure before reporting:

| Category | Signal | What it means |
|----------|--------|---------------|
| locatorMiss | Element not found, strict-mode violation | The locator or the markup assumption is wrong |
| timing | Not visible, waitFor timeout | Missing wait on the decisive event -- fix the oracle, never add a sleep (E2E-Q1) |
| data | Assertion failed on an expected value | Test data factory or fixture mismatch |
| auth | 401/403, redirected to login | `storageState` fixture is stale or scoped wrong |
| backend | 500, connection refused | An application defect, not a test defect. Report it as a finding |

## Coverage registry

State lands in `memory/e2e-coverage.md`, which gains a `State` column:

```
| Flow ID | Name | Score | Confidence | Status | Spec File | Last Updated | State |
```

Write rows through the helper, never by hand-editing the table:

```bash
"$HOME/.zuvo/e2e-preflight" coverage-upsert \
  --file memory/e2e-coverage.md \
  --flow auth-login --state VERIFIED_LOCAL \
  --spec e2e/flows/auth/login.spec.ts --score 92 --confidence HIGH
```

A legacy row with no `State` cell reads as GENERATED. Never back-fill a legacy row to
VERIFIED_LOCAL or VALIDATED_LIVE: the registry records what was proven, and nothing about an
old row proves a run ever happened.
