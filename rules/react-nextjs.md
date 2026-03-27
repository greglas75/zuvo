# React and Next.js Conventions

Active when React or Next.js is detected in the project. Not applicable to non-React codebases.

---

## Component Architecture

- **One component per file** — no multiple exported components in a single module
- **Functional components only** — no class components
- **Props interface at top of file** or in a `.types.ts` file when exceeding 50 lines
- **No inline function definitions in JSX** for event handlers used in lists — extract or wrap with useCallback

## Hook Discipline

- Place hooks at the top of the component, before any conditionals or early returns
- Custom hooks belong in separate files (`useFeatureName.ts`)
- Never call hooks inside loops, conditions, or nested functions
- Include all dependencies in useEffect/useMemo/useCallback dependency arrays
- Use `useMemo`/`useCallback` only when there is a measurable performance benefit — avoid premature optimization
- **Extract pure logic out of hooks** — validation, retry functions, merge operations as module-level pure functions. This enables unit testing without rendering.
```typescript
// GOOD — pure, testable, reusable
function mergeProducts(existing: Product[], incoming: Product[]): Product[] { ... }
function validateSearchResponse(raw: unknown): SearchResponse { ... }
export function useSearchProducts(query: string) { /* uses above */ }
```
- **Stable useCallback for data-fetching:** when a callback appears in useEffect deps, prefer zero deps with variable data passed as arguments to prevent re-fetch cascades.
```typescript
// BAD — new identity on every query/page change → useEffect re-fires
const fetchData = useCallback(() => fetch(`/api?q=${query}&p=${page}`), [query, page]);

// GOOD — stable identity, caller passes current values
const fetchData = useCallback((q: string, p: number) => fetch(`/api?q=${q}&p=${p}`), []);
```

### Common Anti-Patterns

- **N x useState for form** → use `useReducer` or form library when 5+ related fields
- **useEffect to sync props → state** → use `key=` prop to force remount instead
- **useCallback + debounce with frequently changing deps** → creates new debounce instance per deps change, defeating the debounce. Use `useRef` for the debounce function.
- **Multiple `setState` in a loop** → batch into single state update (build array/object first, set once)
- **Raw fetch + setState when project uses React Query/SWR** → use the established data fetching pattern
- **Optimistic updates without rollback** → API failure leaves UI in wrong state
- **`document.getElementById` / direct DOM manipulation** → breaks React virtual DOM, causes hydration errors in SSR
- **Native `confirm()`/`alert()`** → use custom modal consistent with UI framework

### Bug-Producing Patterns (auto-flag)

- **Component defined inside render function** → unmounts and remounts on every parent render, destroying child state, focus, and effects.
```typescript
// BUG — new component identity each render
function Parent() {
  const ItemList = () => <div>{items.map(...)}</div>;
  return <ItemList />;
}
// FIX — define at module level
const ItemList = ({ items }) => <div>{items.map(...)}</div>;
```

- **`{items.length && <Component />}`** → renders `0` on screen when array is empty (0 is falsy but renderable). Use `items.length > 0 &&` or ternary.

- **Derived state in useState synced via useEffect** → causes extra re-renders and stale data. Compute during render or use useMemo.
```typescript
// BUG — extra render, stale data risk
const [filtered, setFiltered] = useState([]);
useEffect(() => { setFiltered(items.filter(i => i.active)); }, [items]);

// FIX — compute during render
const filtered = items.filter(i => i.active);
```

- **Stale closure in timer/interval** → state captured at render time never updates. Use functional updater (`setCount(c => c + 1)`) or `useRef`.

- **Missing useEffect cleanup for async operations** → stale response from slow request overwrites fresh data. Use `active` flag or `AbortController` in cleanup. For retry loops: make sleep cancellable via AbortSignal.
```typescript
const sleep = (ms: number, signal: AbortSignal) =>
  new Promise<void>((resolve, reject) => {
    const timer = setTimeout(resolve, ms);
    signal.addEventListener('abort', () => { clearTimeout(timer); reject(signal.reason); });
  });
```

- **Stale response overwrites fresh data** → when requests overlap, slow first response arrives after fast second response. Use request sequence counter or AbortController identity comparison.

- **`key={index}` on dynamic lists** → when items are reordered or deleted, state sticks to wrong items. Use stable unique IDs from data. Index keys are fine only for static lists that never reorder.
```typescript
// BUG
{items.map((item, i) => <ItemCard key={i} item={item} />)}
// FIX
{items.map(item => <ItemCard key={item.id} item={item} />)}
```

- **`Math.random()` or `Date.now()` as key** → every item unmounts and remounts on every render. Use stable IDs.

- **Selector creates new reference each render** → `.filter()`/`.map()` inside Zustand/Redux selector returns new array, causing infinite re-renders. Memoize or use shallow equality.
```typescript
// BUG — new array reference every render
const active = useStore(state => state.items.filter(i => i.active));
// FIX
const active = useStore(state => state.items.filter(i => i.active), shallow);
```

- **Context Provider value not memoized** → new object reference every render forces all consumers to re-render.
```typescript
// BUG
<ThemeContext.Provider value={{ theme, setTheme }}>
// FIX
const value = useMemo(() => ({ theme, setTheme }), [theme, setTheme]);
<ThemeContext.Provider value={value}>
```

- **`window.location` for navigation** → forces full page reload, loses React state. Use router.
```typescript
// NEVER
window.location.href = '/dashboard';
// ALWAYS
const router = useRouter();
router.push('/dashboard');
```

- **`useState` + `fetch` when project has React Query/SWR** → use the established data fetching library for caching, deduplication, and error handling.

- **Large inline `style={{}}` objects (5+ properties)** → new object reference per render. Extract to const or use CSS classes.
```typescript
// NEVER
<div style={{ display: 'flex', flexDirection: 'column', gap: 8, padding: 16, borderRadius: 8 }}>
// ALWAYS
const containerStyle = { display: 'flex', flexDirection: 'column', gap: 8, padding: 16, borderRadius: 8 } as const;
<div style={containerStyle}>
```

### Form State: useReducer Threshold
- 5+ useState for related form fields → switch to useReducer or form library
- Independent UI states (isOpen, isLoading, error) are fine as separate useState
- Test: if resetting the form requires 5+ setter calls → it should be a reducer

## State Management Selection

```
Is this SERVER data? (API, database)
  └─ YES → TanStack Query / SWR / server actions
  └─ NO → Is this GLOBAL client state?
      └─ YES → Zustand / Redux
      └─ NO → Shared between 2-3 components?
          └─ YES → React Context (small subtree)
          └─ NO → local useState
```

- **Server state** (TanStack Query/SWR): cache, refetch, stale/fresh management
- **Global client state** (Zustand): theme, sidebar, user preferences
- **Context**: small component subtrees only (forms, wizards) — not global state
- **Local state**: component-specific UI state

## Next.js App Router

### Server vs Client Components
- **Default to Server Components** — add `"use client"` only when required
- `"use client"` triggers: hooks, browser APIs, event handlers, Context providers
- Server Components handle: data fetching, heavy computation, secrets access
- **Never import server-only code into client components**

### Server Actions
- Validate inputs with Zod in every server action
- Check auth in every server action (not just pages)
- Use `revalidatePath`/`revalidateTag` after mutations
- Never expose sensitive data in action responses

### Route Boundaries
- **Every route segment needs `loading.tsx`** — without it, users see blank screens
- **Every route segment needs `error.tsx`** — without it, unhandled errors crash the layout
- Missing these means no progressive loading, no error recovery, no Suspense boundaries

### redirect() — never wrap in try/catch
```typescript
// BUG — redirect() throws internally, catch swallows it
try {
  const user = await getUser();
  if (!user) redirect('/login');
  await processData(user);
} catch (err) {
  console.error(err); // catches the redirect!
}

// FIX — redirect outside try/catch, or re-throw NEXT_REDIRECT
try { await processData(user); }
catch (err) {
  if (err instanceof Error && err.message === 'NEXT_REDIRECT') throw err;
  console.error(err);
}
```

### dangerouslySetInnerHTML — always sanitize
```typescript
// NEVER
<div dangerouslySetInnerHTML={{ __html: comment.content }} />
// ALWAYS
import DOMPurify from 'dompurify';
<div dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(comment.content) }} />
```

### Environment Variables
- `NEXT_PUBLIC_*` — exposed to client (never for secrets)
- Non-prefixed vars — server-only (safe for API keys, DB URLs)

## Performance Patterns

### Debouncing
```typescript
// Debounce search/filter inputs (300ms)
const debouncedSearch = useDebounce(search, 300);
```

### Retry and Error Recovery
- **Set timeouts on every fetch** — individual requests can hang indefinitely:
```typescript
const response = await fetch(url, { signal: AbortSignal.timeout(8000) });
```
- **Exponential backoff** for retries: `delay * 2^attempt` with jitter. Skip retry on 4xx (except 429).
- **Dedup on append** for infinite scroll: deduplicate by item ID when appending pages. Server data can shift between pages.
- **`lastRequestRef` for retry accuracy** — retry must resume from failed cursor, not restart from beginning.

### Large Lists
- Virtual scrolling for 1000+ items (`react-window`, `@tanstack/virtual`)
- Paginate or infinite-scroll for API-backed lists

### Code Splitting
- `React.lazy()` + `Suspense` for route-level splitting
- `next/dynamic` in Next.js for heavy components

## Accessibility (WCAG 2.1 AA)

- **ARIA labels** on all interactive elements without visible text
- **Keyboard navigation**: all actions reachable via keyboard
- **Focus management**: trap focus in modals, restore on close
- **Color contrast**: 4.5:1 for text, 3:1 for UI components
- **Live regions**: `aria-live="polite"` for dynamic content updates
- **Semantic HTML**: use `<button>`, `<a>`, `<nav>`, `<main>` — not `<div onClick>`
- Decorative icons: `aria-hidden="true"`

## Error Handling

- Wrap feature sections in `ErrorBoundary`
- Log errors to monitoring (Sentry) with context tags
- Show user-friendly fallback UI, not raw error messages
- Re-throw errors after logging so error boundaries can catch them

## Hook-Specific CQ Adjustments

When evaluating hooks (`use*.ts` files) against CQ1-CQ22:

- **CQ11:** Hook body limit is 100 lines (not 50). The 50L limit applies to each `useCallback`/`useEffect` body individually.
- **CQ8:** `AbortController.abort()` causing `AbortError` is intentional control flow. `if (err.name === 'AbortError') return;` is correct.
- **CQ19:** Hooks with internal API response validation ARE the boundary. Hand-rolled validation satisfies CQ19 if all fields have type and range checks.
- **CQ3:** Hook params validated by TS types satisfy CQ3 if only called from TS code with simple primitives.
- **CQ6:** Spread accumulation `[...prev, ...data]`: PASS if `hasMore` check exists and items are lightweight.
- **CQ14:** Similar async patterns (abort + fetch + state) across effects are scaffolding. Flag only when the business logic inside is duplicated.
- **CQ16:** Storing or passing monetary fields without arithmetic = N/A. `toFixed()` during computation = FAIL.

## Tailwind CSS (when used)

- Design tokens in `tailwind.config` — no magic values (`bg-[#3b82f6]`)
- Cap at ~15 utility classes inline — extract component if more
- Mobile-first breakpoints (`w-full md:w-1/2 lg:w-1/3`)
- Use `cn()` utility for conditional class merging
