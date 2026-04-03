# Defensive Code Patterns

Paired examples of what to avoid and what to write instead. Study these before producing any code.

---

### Atomic operations over check-then-act
```typescript
// NEVER — TOCTOU: state changes between check and action
const avail = await inventory.check(id); if (avail >= qty) await inventory.reserve(id, qty);
// ALWAYS — atomic operation, handle failure
try { await inventory.reserve(id, qty); } catch (e) { if (e instanceof InsufficientError) { /* handle */ } throw e; }
```

### Idempotent mutations
```typescript
// NEVER — double call = double side effect
async cancel(id) { await inventory.release(items); }
// ALWAYS — guard against re-entry
const order = await db.find(id); if (order.status === 'cancelled') return order;
```

### Proper Error objects with cause chains
```typescript
// NEVER — string throw, swallowed catch, bare return in try, leaked infra details
throw 'failed'; .catch(() => undefined); try { return fetchData(); } catch { /* never reached */ }
// ALWAYS — Error with cause, logged catch, return await, domain error
throw new Error('Order creation failed', { cause: err }); try { return await fetchData(); } catch (e) { handleError(e); }
```

### Type-safe error narrowing with consistent naming
```typescript
// NEVER — `as Error` crashes if err is string/number/null; inconsistent naming across repo
} catch (err) { this.logger.error('Failed', { error: (err as Error).message }); }
} catch (e) { ... }     // file B uses `e`
} catch (error) { ... }  // file C uses `error`
// ALWAYS — always `err: unknown`, narrow with instanceof, fallback to String()
} catch (err: unknown) { const msg = err instanceof Error ? err.message : String(err); this.logger.error('Failed', { error: msg }); }
// Convention: one name everywhere — `err`. Not e/error/ex/er.
```

### Context-aware error strategy (CQ8)
```typescript
// NEVER — same try/catch pattern everywhere regardless of context
try { await redis.get(key); } catch (e) { logger.error(e); throw; } // copy-pasted to every callsite
// ALWAYS — strategy matches business impact
// Critical path (payment, quota enforcement): catch → rethrow (caller decides)
// Non-critical path (metrics, cache warm): catch → warn + continue
// User-facing read (dashboard): catch → return fallback data
// Availability check: catch → fail-open (don't block users on infra failure)
```

### Integer-cent arithmetic for monetary values
```typescript
// NEVER — 0.1 + 0.2 = 0.30000000000000004
const total = price * qty * (1 - discount / 100);
// ALWAYS — integer-cents arithmetic, single rounding step
const discountedCents = Math.round(priceCents * (100 - discountPercent) / 100); const totalCents = qty * discountedCents;
```

### Map-based lookups instead of find() in loops
```typescript
// NEVER — O(n²): find() scans entire array per iteration
for (const id of ids) { const item = items.find(i => i.id === id); }
// ALWAYS — O(n): build Map once, lookup O(1)
const itemMap = new Map(items.map(i => [i.id, i])); for (const id of ids) { const item = itemMap.get(id); }
```

### Paired subscribe and unsubscribe
```typescript
// NEVER — listener/timer leak
useEffect(() => { window.addEventListener('resize', fn); }, []);
// ALWAYS — cleanup everything you create
useEffect(() => { window.addEventListener('resize', fn); return () => window.removeEventListener('resize', fn); }, []);
```

### Functional updaters to avoid stale closures
```typescript
// NEVER — stale state in callback (count is always 0)
setInterval(() => setCount(count + 1), 1000);
// ALWAYS — functional updater reads current value; use useRef for current value in callbacks
setInterval(() => setCount(c => c + 1), 1000);
```

### Validate every parameter, copy before mutating
```typescript
// NEVER — skip string params; mutate input
async createOrder(userId: string, items: Item[]) { this.validateItems(items); items.sort(); }
// ALWAYS — validate string params too; copy before mutating
if (!userId?.trim()) throw new Error('userId is required'); const sorted = [...items].sort();
```

### Intentional sequential await
```typescript
// Sequential OK when rollback needs ordering — ADD COMMENT
for (const item of items) { await inventory.reserve(item.id, item.qty); reserved.push(item.id); }
// If no ordering needed → use Promise.all with concurrency limit
```

### Exhaustive switch on union types
```typescript
// NEVER — silent skip when new status added
switch (s) { case 'pending': return handlePending(); case 'shipped': return handleShipped(); }
// ALWAYS — never assertion catches missing cases at compile time
default: const _exhaustive: never = s; throw new Error(`Unhandled: ${_exhaustive}`);
```

### No async in void-returning callbacks
```typescript
// NEVER — forEach doesn't await: all fire in parallel, errors lost
items.forEach(async (item) => { await processItem(item); });
// ALWAYS — for...of for sequential, Promise.all for parallel
for (const item of items) { await processItem(item); } // or: await Promise.all(items.map(i => processItem(i)));
```

### Always chain .catch() after .then()
```typescript
// NEVER — .then() without .catch() (rejection unhandled, silent failure)
fetchData().then(data => setResults(data));
// ALWAYS — .catch() with error state, or await in try/catch
fetchData().then(data => setResults(data)).catch(err => setError(err.message));
```

### Wrap JSON.parse on external input
```typescript
// NEVER — throws on malformed input, crashes process
const data = JSON.parse(externalInput);
// ALWAYS — try/catch at boundary, then validate
let data: unknown; try { data = JSON.parse(externalInput); } catch { throw new Error('Invalid JSON'); }
```

### Keep PII out of logs and error messages
```typescript
// NEVER — tokens, passwords, emails in logs or error messages
logger.info('Login', { email, password }); throw new Error(`User ${email} not found`);
// ALWAYS — log correlation IDs only; no PII in throws
logger.info('Login', { requestId }); throw new NotFoundException('User not found');
```

### Timing-safe secret comparison (CQ5)
```typescript
// NEVER — timing attack leaks secret length via === short-circuit
if (botSecret !== expectedSecret) throw new UnauthorizedException();
// ALWAYS — constant-time comparison (crypto.timingSafeEqual)
import { timingSafeEqual } from 'crypto';
const a = Buffer.from(botSecret ?? ''); const b = Buffer.from(expectedSecret);
if (a.length !== b.length || !timingSafeEqual(a, b)) throw new UnauthorizedException();
```

### Timeout on every outbound fetch (CQ8)
```typescript
// NEVER — hook callback without timeout (hangs indefinitely on network issue)
const data = await feedbackClient.list(sessionId);
// ALWAYS — timeout on every outbound call including in hooks/callbacks
const data = await feedbackClient.list(sessionId, { signal: AbortSignal.timeout(10_000) });
```

### Bounded queries with limits
```typescript
// NEVER — returns entire table, causes OOM
const users = await prisma.user.findMany({ where: { orgId } });
// ALWAYS — paginate or cap; select slim fields
const users = await prisma.user.findMany({ where: { orgId }, take: 100, select: { id: true, email: true } });
```

### Cap user-supplied limits (CQ6)
```typescript
// NEVER — user-provided limit passed uncapped (limit=999999 → OOM)
const { limit } = req.query;
await prisma.user.findMany({ take: limit });
// ALWAYS — cap user input with MAX_PAGE_SIZE
const take = Math.min(limit ?? DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE);
await prisma.user.findMany({ take });
```

### Guard nullable values before access
```typescript
// NEVER — crashes on undefined, ! bypasses null check
const item = items.find(i => i.id === id).name; const name = user!.profile.displayName;
// ALWAYS — guard explicitly; optional chaining + fallback
const item = items.find(i => i.id === id); if (!item) throw new NotFoundException(`Item ${id} not found`);
```

### Defense in depth: guard plus query filter
```typescript
// NEVER — guard is the only defense; query fetches any org's data
return this.prisma.item.findMany({ where: { surveyId } }); // no orgId!
// ALWAYS — guard AND query filter
return this.prisma.item.findMany({ where: { surveyId, organizationId: orgId } });
```

### Schema-validate external API responses
```typescript
// NEVER — assume response matches expected shape
const data = await response.json(); return { id: data.id, name: data.user.name };
// ALWAYS — parse with schema; unknown until validated
const raw: unknown = await response.json(); const data = UserResponseSchema.parse(raw);
```

### Expose only public fields in API responses (CQ19)
```typescript
// NEVER — return raw Prisma/DB object to client (leaks internal fields, timestamps, relations)
return res.json(await prisma.user.findUnique({ where: { id } }));
// ALWAYS — explicit shape or pick only public fields
return res.json({ id: user.id, name: user.name, role: user.role });
```

### Check response.ok before parsing body
```typescript
// NEVER — 404/500 returns HTML, .json() throws confusing SyntaxError
const data = await response.json();
// ALWAYS — check response.ok first
if (!response.ok) throw new Error(`API error ${response.status}`); const data = await response.json();
```

### structuredClone for deep copying
```typescript
// NEVER — drops undefined, Date, Map, Set, functions, circular refs
const copy = JSON.parse(JSON.stringify(original));
// ALWAYS — native deep clone (Node 17+, all modern browsers)
const copy = structuredClone(original);
```

### Nullish coalescing for safe defaults
```typescript
// NEVER — || treats 0, '', false as falsy → fallback triggers on valid values
const quantity = input.quantity || 1; // quantity=0 → becomes 1!
// ALWAYS — ?? only falls back on null/undefined
const quantity = input.quantity ?? 1; // quantity=0 → stays 0
```

### Rethrow or propagate caught errors
```typescript
// NEVER — error disappears, caller thinks success
try { await saveOrder(data); } catch (err) { console.log('Error:', err); }
// ALWAYS — rethrow, notify user, or return error state
try { await saveOrder(data); } catch (err) { logger.error('Failed', { orderId }); throw err; }
```

### Log before falling back to defaults (CQ8)
```typescript
// NEVER — catch sets default state without logging (no observability)
} catch { setMemberships([]); }
// ALWAYS — log before fallback so failures are visible
} catch (err) { logger.warn('Fetch failed, using fallback', { error: err instanceof Error ? err.message : String(err) }); setMemberships([]); }
```

### Typed config from env at bootstrap
```typescript
// NEVER — process.env scattered across services (untestable, no validation)
const apiUrl = process.env.API_URL;            // service A
const secret = process.env.JWT_SECRET;          // service B
if (process.env.NODE_ENV === 'production') {}   // service C
// ALWAYS — one config module, validated at startup, injected everywhere
const env = EnvSchema.parse(process.env); function createSender(config: SenderConfig) { /* ... */ }
// NestJS: use ConfigService with validation — see nestjs.md
```

### UTC-canonical time handling
```typescript
// NEVER — formatting + reparsing is locale/DST fragile
const hcmNow = new Date(now.toLocaleString('en-US', { timeZone: 'Asia/Ho_Chi_Minh' }));
// ALWAYS — UTC canonical; use helpers for zoned calculations; Intl for display only
const hcmParts = getZonedDateParts(now, 'Asia/Ho_Chi_Minh');
```

### Concurrency limits on dynamic fan-out
```typescript
// NEVER — user-sized batch triggers unbounded outbound I/O
await Promise.all(translations.map(item => evaluateTranslation(item)));
// ALWAYS — dynamic batches need concurrency limit (fixed tuples OK)
const limit = pLimit(5); await Promise.all(translations.map(item => limit(() => evaluateTranslation(item))));
```

### Explicit Array.isArray guard
```typescript
// NEVER — typeof [] === 'object' passes, Object.keys([1,2]) = ['0','1']
if (!raw || typeof raw !== 'object') return [];
// ALWAYS — explicit array rejection when expecting Record
if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return [];
```

### Side effects after transaction, never inside
```typescript
// NEVER — promise fires before tx commits; if tx rolls back, side effect already fired
return this.db.transaction(async () => { this.email.send(order).catch(/* ... */); return order; });
// ALWAYS — fire-and-forget AFTER transaction completes
const order = await this.db.transaction(async () => { /* mutations only */ }); this.email.send(order).catch(logWarn);
```

### Stream safety: errors, backpressure, finalization
```typescript
// NEVER — write without error handling, backpressure, or stream end
writable.write(JSON.stringify(row)); writable.write(']'); // no try/finally, no end()
// ALWAYS — try/finally, check write() return, call end()
try { writable.write('['); /* ... check canContinue, await drain ... */ } finally { writable.write(']'); writable.end(); }
```

### Enforce caps when accumulating batched data
```typescript
// NEVER — batch-load but accumulate ALL in memory (defeats the point)
const rows: Row[] = []; await forEachBatch(q, (batch) => { rows.push(...build(batch)); }); return rows;
// ALWAYS — enforce cap for in-memory; use streaming for large data
rows.push(...build(batch)); if (rows.length > MAX_ROWS) throw new BadRequestException('Use streaming');
```

### Data-driven registration over repetitive boilerplate
```typescript
// NEVER — N× identical registration boilerplate
server.tool("a", "desc", schemaA, async (args) => wrap("a", args, () => fnA(args))()); // × 30
// ALWAYS — data-driven registration
const TOOLS = [{ name: "a", schema: schemaA, handler: fnA }, ...]; for (const t of TOOLS) { server.tool(t.name, ...); }
```

### Shared helpers instead of duplicated guards (CQ14)
```typescript
// NEVER — same extractOrgId/assertEditable copy-pasted in every controller/service
private extractOrgId(req) { return req.user.organizationId; } // 3× identical across controllers
private assertEditableVersion(v) { if (v.status !== 'draft') throw ...; } // 6× identical across services
// ALWAYS — shared decorator or service method
@OrgId() orgId: string // custom decorator, OR
this.authContext.getOrgId(req) // shared auth service
this.versionGuard.assertEditable(version) // shared guard service
```

### Prisma upsert over manual findFirst + create/update (CQ21)
```typescript
// NEVER — findFirst + create/update = race condition between check and write
const existing = await db.model.findFirst({ where: { key } });
if (existing) await db.model.update({ where: { id: existing.id }, data: { ... } });
else await db.model.create({ data: { key, ... } });
// ALWAYS — use Prisma upsert (atomic) or $transaction
await db.model.upsert({ where: { key }, update: { ... }, create: { key, ... } });
```

### Cache expensive computations
```typescript
// NEVER — O(n²) rebuilt on every request
const adjacency = buildAdjacencyIndex(index.symbols); // every call!
// ALWAYS — cache keyed by version, invalidate on change
const cache = new Map(); if (!cache.has(key)) cache.set(key, buildAdjacencyIndex(symbols)); return cache.get(key);
```

### Identical conditions in if/else-if — copy-paste bug
```typescript
// NEVER — same condition checked twice (second branch unreachable)
if (status === 'active') { activate(); }
else if (status === 'active') { reactivate(); }  // dead branch
// ALWAYS — each condition unique
if (status === 'active') { activate(); }
else if (status === 'pending') { reactivate(); }
```

### Identical expressions on both sides of operator
```typescript
// NEVER — always true/false/zero (wrong variable)
if (a === a) { ... }           // always true
const diff = price - price;     // always 0
return left && left;            // redundant
// ALWAYS — each side different
if (a === b) { ... }
const diff = price - discount;
```

### Collection accessed when empty
```typescript
// NEVER — read from array before populating it
const items: string[] = [];
console.log(items[0]);          // always undefined
items.push('first');
// ALWAYS — populate before access
const items: string[] = [];
items.push('first');
console.log(items[0]);
```

### Loop with at most one iteration — disguised if
```typescript
// NEVER — loop that always breaks/returns on first iteration
for (const item of items) {
  return item.name;             // always returns first
}
// ALWAYS — direct access, no loop pretense
return items[0]?.name;
```

### Ignored return value of pure function
```typescript
// NEVER — pure methods called for side effects they don't have
items.filter(i => i.active);     // result discarded
str.toUpperCase();               // result discarded
arr.map(x => x * 2);            // result discarded
// ALWAYS — use the return value
const active = items.filter(i => i.active);
const upper = str.toUpperCase();
```

### Non-existent operators =+, =-, =!
```typescript
// NEVER — typo: intended += but wrote =+
total =+ price;                  // assigns +price (unary plus), doesn't add
// ALWAYS — correct compound assignment
total += price;
```

### Cognitive complexity — max 15 per function
```typescript
// NEVER — nested conditions + loops (cognitive complexity ~25)
function processOrder(order, user, config) {
  if (order.status === 'new') {
    for (const item of order.items) {
      if (item.stock > 0) {
        if (user.isPremium || config.allowBackorder) { /* deep nesting */ }
      }
    }
  }
}
// ALWAYS — extract, flatten, early return (target: <=15)
function processOrder(order, user, config) {
  if (order.status !== 'new') return;
  const processable = order.items.filter(i => i.stock > 0);
  for (const item of processable) {
    processItem(item, user, config);  // complexity moved to focused function
  }
}
```

### Collapsible if — merge nested single-condition ifs
```typescript
// NEVER — nested ifs with no else
if (user) {
  if (user.isActive) { doSomething(); }
}
// ALWAYS — merge with && or optional chaining
if (user?.isActive) { doSomething(); }
```

### Identical functions — extract shared implementation
```typescript
// NEVER — two functions with identical body (copy-paste debt)
function getActiveUsers(org) {
  return prisma.user.findMany({ where: { orgId: org.id, active: true } });
}
function getEnabledUsers(org) {
  return prisma.user.findMany({ where: { orgId: org.id, active: true } });
}
// ALWAYS — one function, clear name
function getActiveUsersByOrg(orgId: string) {
  return prisma.user.findMany({ where: { orgId, active: true } });
}
```

### Duplicated string literals — extract to constant
```typescript
// NEVER — same string literal 3+ times
throw new Error('Survey not found');       // handler A
throw new Error('Survey not found');       // handler B
logger.warn('Survey not found');            // handler C
// ALWAYS — named constant
const SURVEY_NOT_FOUND = 'Survey not found';
throw new NotFoundException(SURVEY_NOT_FOUND);
```

### Nested template literals — extract to variable
```typescript
// NEVER — template inside template (hard to read)
const msg = `Hello ${user.name}, your order #${`ORD-${order.id}`} is ready`;
// ALWAYS — extract inner template
const orderId = `ORD-${order.id}`;
const msg = `Hello ${user.name}, your order #${orderId} is ready`;
```

### Boolean literal in comparison — simplify
```typescript
// NEVER — comparing to true/false
if (isActive === true) { ... }
if (isValid === false) { ... }
return result ? true : false;
// ALWAYS — direct boolean
if (isActive) { ... }
if (!isValid) { ... }
return result;
```

### Useless post-increment before return
```typescript
// NEVER — post-increment result is discarded
function count(items) {
  let total = 0;
  for (const item of items) { total++; }
  return total++;    // returns total BEFORE increment, increment is wasted
}
// ALWAYS — no post-increment on return
function count(items) {
  let total = 0;
  for (const item of items) { total++; }
  return total;
}
```

### Commented-out code — delete or restore
```typescript
// NEVER — dead code in comments (git has history)
// const oldPrice = calculateLegacyPrice(item);
// if (oldPrice > threshold) { applyDiscount(item); }
const newPrice = calculatePrice(item);
// ALWAYS — clean code, use git blame if you need history
const price = calculatePrice(item);
```

### Cache with TTL — never store without expiration (CQ23)
```typescript
// NEVER — cache entry lives forever, stale data served indefinitely
await redis.set(`user:${id}`, JSON.stringify(user));
const cache = new Map(); cache.set(key, value); // no eviction
// ALWAYS — TTL on every cache entry; in-memory caches need max size
await redis.set(`user:${id}`, JSON.stringify(user), 'EX', 3600);
const cache = new LRUCache({ max: 1000, ttl: 1000 * 60 * 15 });
```

### API backward compatibility — additive changes only (CQ24)
```typescript
// NEVER — remove or rename field without deprecation
// v1: { userId: string, name: string }
// v2: { id: string, fullName: string }  // breaks all clients
// ALWAYS — add new fields, deprecate old ones, remove after migration
// v2: { userId: string, id: string, name: string, fullName: string }
// v3 (after migration window): { id: string, fullName: string }
```

### Pattern consistency — follow existing conventions (CQ25)
```typescript
// NEVER — different error handling pattern in new endpoint vs existing
// Existing: throw new NotFoundException(...)
// New endpoint: return res.status(404).json({ error: 'not found' })
// ALWAYS — match the existing project pattern
throw new NotFoundException(`Order ${id} not found`); // same as every other endpoint
```

### Structured logging with context (CQ26)
```typescript
// NEVER — plain text logs without context
console.log('Processing order');
console.log('Error:', error.message);
// ALWAYS — structured logger with correlation IDs
this.logger.info('Processing order', { requestId, orderId, userId });
this.logger.error('Order processing failed', { requestId, orderId, error: err.message });
```

### Correct log levels (CQ27)
```typescript
// NEVER — validation failure as error (it's expected business logic)
this.logger.error('Invalid email format', { email: input.email });
// NEVER — stack trace as info
this.logger.info('Something went wrong', { stack: err.stack });
// ALWAYS — match severity to situation
this.logger.warn('Invalid email format', { requestId }); // expected, recoverable
this.logger.error('Database connection lost', { error: err.message }); // infrastructure, unrecoverable
```

### Timeout hierarchy — client < server < DB (CQ28)
```typescript
// NEVER — client waits longer than server (gets a connection reset instead of proper error)
// Client: fetch(url, { signal: AbortSignal.timeout(30_000) })
// Server: server.setTimeout(10_000)
// DB: statement_timeout = '5s'
// ALWAYS — outer layer times out first, gets a meaningful error
// Client: 10s → Server: 30s → DB: 60s
// Client timeout < Server timeout < DB timeout
fetch(url, { signal: AbortSignal.timeout(10_000) }); // client: 10s
// server.setTimeout(30_000);  // server: 30s
// SET statement_timeout = '60s';  // DB: 60s
```

---

## Security and Infrastructure Patterns

### No hardcoded secrets in source
```typescript
// NEVER — hardcoded secrets in source or committed .env
const API_KEY = "sk-abc123...";
SUPABASE_KEY=eyJhbGc...  // .env committed to git
// ALWAYS — runtime env, .env in .gitignore
const apiKey = process.env.API_KEY;
// .env.example with empty values only
```

### Path traversal — validate before join/resolve
```typescript
// NEVER — user input directly in path.join
const file = path.join(uploadDir, req.params.filename);
// ALWAYS — normalize + startsWith guard
const safePath = path.normalize(path.join(baseDir, userInput));
if (!safePath.startsWith(baseDir)) throw new Error('Path traversal blocked');
```

### Non-literal RegExp — escape user input
```typescript
// NEVER — user input directly in RegExp constructor (ReDoS risk)
const regex = new RegExp(userInput);
// ALWAYS — escape special chars or use literal
const escaped = userInput.replace(/[.*+?^{}()|[\]\\]/g, '\\$&');
const regex = new RegExp(escaped);
```

### Prototype pollution — guard dynamic property assignment
```typescript
// NEVER — unchecked bracket assignment in loop
for (const [key, val] of Object.entries(input)) { target[key] = val; }
// ALWAYS — hasOwnProperty guard or Object.create(null)
const safe = Object.create(null);
for (const [key, val] of Object.entries(input)) {
  if (key !== '__proto__' && key !== 'constructor') safe[key] = val;
}
```

### GCM decryption needs authTagLength
```typescript
// NEVER — GCM decipher without expected tag length
const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
// ALWAYS — specify authTagLength to prevent tag truncation attacks
const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv, { authTagLength: 16 });
```

### External scripts need subresource integrity
```html
<!-- NEVER — CDN script without integrity check -->
<script src="https://cdn.example.com/lib.js"></script>
<!-- ALWAYS — subresource integrity hash -->
<script src="https://cdn.example.com/lib.js"
  integrity="sha384-abc123..." crossorigin="anonymous"></script>
```

### Child process — avoid shell: true
```typescript
// NEVER — shell: true enables injection
execSync(`convert ${userFile} output.png`);
spawn('cmd', args, { shell: true });
// ALWAYS — array args, no shell
execFileSync('convert', [userFile, 'output.png']);
spawn('cmd', args); // shell defaults to false
```

### as any bypass — extend types instead
```typescript
// NEVER — cast to any to access/delete fields
const val = (pricing as any)[field] as number;
delete (postData as any).translatedLanguage;
// ALWAYS — extend interface or use Omit/Pick/destructure
const val = pricing[field as keyof Pricing];
const { translatedLanguage, ...postData } = rawData;
```

### Structured logger over console.log
```typescript
// NEVER — raw console in services/controllers
console.log('Creating prompt...');
console.log('API Call:', { url, body });
// ALWAYS — structured logger with level + context
logger.info('Creating prompt', { requestId, promptType });
logger.debug('API call', { url, method: 'POST' });
```

### Typed exceptions over generic Error
```typescript
// NEVER — generic Error in framework services
throw new Error('User not found');
throw new Error('Invalid input');
// ALWAYS — typed exception with HTTP semantics
throw new NotFoundException(`User ${id} not found`);
throw new BadRequestException('Survey title is required');
// Non-NestJS: extend a base AppError with code field
```

---

## Docker and Infrastructure

### Dockerfile — always set non-root USER
```dockerfile
# NEVER — run as root
FROM node:20
COPY . .
CMD ["node", "server.js"]
# ALWAYS — non-root user
FROM node:20
RUN addgroup --system app && adduser --system --ingroup app app
USER app
COPY --chown=app:app . .
CMD ["node", "server.js"]
```

### Container — drop privileges
```yaml
# ALWAYS — in docker-compose or k8s
security_context:
  run_as_non_root: true
  read_only_root_filesystem: true
  allow_privilege_escalation: false
```
