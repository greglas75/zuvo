import { useCallback, useEffect, useRef, useState } from 'react';

export interface Product {
  id: string;
  name: string;
  price: number;
}

interface SearchApiResponse {
  products: Product[];
  total: number;
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function isProduct(v: unknown): v is Product {
  if (!isRecord(v)) return false;
  return (
    typeof v.id === 'string' &&
    typeof v.name === 'string' &&
    typeof v.price === 'number' &&
    Number.isFinite(v.price)
  );
}

function parseSearchResponse(json: unknown): SearchApiResponse {
  if (!isRecord(json)) {
    throw new Error('Invalid API response: root must be an object');
  }
  const { products, total } = json;
  if (!Array.isArray(products) || typeof total !== 'number' || !Number.isFinite(total)) {
    throw new Error('Invalid API response: products/total shape');
  }
  if (!products.every(isProduct)) {
    throw new Error('Invalid API response: product entries failed validation');
  }
  return { products, total };
}

const DEBOUNCE_MS = 300;
const MAX_RETRIES = 3;
const PAGE_SIZE = 20;

function abortError(): Error {
  const e = new Error('Aborted');
  e.name = 'AbortError';
  return e;
}

function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(abortError());
      return;
    }
    const t = setTimeout(() => {
      signal.removeEventListener('abort', onAbort);
      resolve();
    }, ms);
    const onAbort = () => {
      clearTimeout(t);
      signal.removeEventListener('abort', onAbort);
      reject(abortError());
    };
    signal.addEventListener('abort', onAbort, { once: true });
  });
}

function mergeProducts(prev: Product[], next: Product[]): Product[] {
  const seen = new Set(prev.map((p) => p.id));
  const merged = [...prev];
  for (const p of next) {
    if (!seen.has(p.id)) {
      seen.add(p.id);
      merged.push(p);
    }
  }
  return merged;
}

function isNonRetryableHttp(err: unknown): boolean {
  if (!(err instanceof Error)) return false;
  const m = /^HTTP (\d{3})$/.exec(err.message);
  if (!m) return false;
  const code = Number(m[1]);
  return code >= 400 && code < 500 && code !== 429;
}

async function fetchWithRetries(
  url: string,
  signal: AbortSignal,
): Promise<SearchApiResponse> {
  let attempt = 0;
  let lastError: unknown;
  while (attempt < MAX_RETRIES) {
    try {
      const res = await fetch(url, { signal });
      if (signal.aborted) {
        throw abortError();
      }
      if (!res.ok) {
        const err = new Error(`HTTP ${res.status}`);
        if (isNonRetryableHttp(err)) {
          throw err;
        }
        throw err;
      }
      const body: unknown = await res.json();
      if (signal.aborted) {
        throw abortError();
      }
      return parseSearchResponse(body);
    } catch (e) {
      lastError = e;
      if ((e as Error).name === 'AbortError') throw e;
      if (isNonRetryableHttp(e)) {
        break;
      }
      attempt += 1;
      if (attempt >= MAX_RETRIES) break;
      const backoff = 2 ** (attempt - 1) * 100;
      try {
        await sleep(backoff, signal);
      } catch (sleepErr) {
        if ((sleepErr as Error).name === 'AbortError') throw sleepErr;
      }
    }
  }
  throw lastError instanceof Error ? lastError : new Error(String(lastError));
}

function buildSearchUrl(searchUrlBase: string, q: string, nextPage: number): string {
  const u = new URL(
    searchUrlBase,
    typeof window !== 'undefined' ? window.location.origin : 'http://localhost',
  );
  u.searchParams.set('q', q);
  u.searchParams.set('page', String(nextPage));
  u.searchParams.set('limit', String(PAGE_SIZE));
  return u.toString();
}

/**
 * Debounced product search. Pass `searchInput` from controlled input state in the parent.
 */
export function useSearchProducts(searchInput: string, searchUrlBase: string) {
  const [debouncedQuery, setDebouncedQuery] = useState('');
  const [products, setProducts] = useState<Product[]>([]);
  const [total, setTotal] = useState(0);
  const [isLoading, setIsLoading] = useState(false);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [error, setError] = useState<Error | null>(null);
  const [page, setPage] = useState(0);

  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const abortRef = useRef<AbortController | null>(null);
  const mountedRef = useRef(true);
  const requestGenRef = useRef(0);
  const loadMoreLockRef = useRef(false);

  const hasMore = products.length < total;

  const cancelInFlight = useCallback(() => {
    abortRef.current?.abort();
    abortRef.current = null;
  }, []);

  const runSearch = useCallback(
    async (q: string, nextPage: number, append: boolean) => {
      cancelInFlight();
      const myGen = ++requestGenRef.current;
      const controller = new AbortController();
      abortRef.current = controller;
      const { signal } = controller;

      const url = buildSearchUrl(searchUrlBase, q, nextPage);

      try {
        const data = await fetchWithRetries(url, signal);
        if (signal.aborted || myGen !== requestGenRef.current) return;
        if (!mountedRef.current) return;
        setTotal(data.total);
        setProducts((prev) => (append ? mergeProducts(prev, data.products) : data.products));
        setPage(nextPage);
        setError(null);
      } catch (e) {
        if ((e as Error).name === 'AbortError') return;
        if (myGen !== requestGenRef.current || !mountedRef.current) return;
        setError(e instanceof Error ? e : new Error(String(e)));
      } finally {
        if (signal.aborted || myGen !== requestGenRef.current) {
          loadMoreLockRef.current = false;
          return;
        }
        if (!mountedRef.current) {
          loadMoreLockRef.current = false;
          return;
        }
        if (append) {
          setIsLoadingMore(false);
        } else {
          setIsLoading(false);
        }
        loadMoreLockRef.current = false;
      }
    },
    [cancelInFlight, searchUrlBase],
  );

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      cancelInFlight();
      if (debounceRef.current) {
        clearTimeout(debounceRef.current);
        debounceRef.current = null;
      }
    };
  }, [cancelInFlight]);

  useEffect(() => {
    cancelInFlight();
    requestGenRef.current += 1;
    if (debounceRef.current) {
      clearTimeout(debounceRef.current);
    }
    debounceRef.current = setTimeout(() => {
      debounceRef.current = null;
      setDebouncedQuery(searchInput);
    }, DEBOUNCE_MS);

    return () => {
      if (debounceRef.current) {
        clearTimeout(debounceRef.current);
        debounceRef.current = null;
      }
    };
  }, [searchInput, cancelInFlight]);

  useEffect(() => {
    if (!debouncedQuery.trim()) {
      cancelInFlight();
      requestGenRef.current += 1;
      if (!mountedRef.current) return;
      setProducts([]);
      setTotal(0);
      setPage(0);
      setError(null);
      setIsLoading(false);
      setIsLoadingMore(false);
      loadMoreLockRef.current = false;
      return;
    }
    setIsLoading(true);
    setIsLoadingMore(false);
    void runSearch(debouncedQuery, 0, false);
  }, [debouncedQuery, runSearch, cancelInFlight]);

  const loadMore = useCallback(() => {
    if (!debouncedQuery.trim() || isLoading || isLoadingMore || !hasMore) return;
    if (loadMoreLockRef.current) return;
    loadMoreLockRef.current = true;
    setIsLoadingMore(true);
    setIsLoading(false);
    void runSearch(debouncedQuery, page + 1, true);
  }, [debouncedQuery, isLoading, isLoadingMore, hasMore, page, runSearch]);

  const retry = useCallback(() => {
    if (!debouncedQuery.trim()) return;
    cancelInFlight();
    requestGenRef.current += 1;
    setIsLoading(true);
    setIsLoadingMore(false);
    void runSearch(debouncedQuery, 0, false);
  }, [debouncedQuery, runSearch, cancelInFlight]);

  return {
    products,
    total,
    isLoading,
    isLoadingMore,
    error,
    hasMore,
    loadMore,
    retry,
  };
}
