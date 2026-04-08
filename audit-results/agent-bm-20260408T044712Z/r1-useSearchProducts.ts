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

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
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
      if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
      }
      const body: unknown = await res.json();
      return parseSearchResponse(body);
    } catch (e) {
      lastError = e;
      if (signal.aborted) throw e;
      attempt += 1;
      if (attempt >= MAX_RETRIES) break;
      const backoff = 2 ** (attempt - 1) * 100;
      await sleep(backoff);
    }
  }
  throw lastError instanceof Error ? lastError : new Error(String(lastError));
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

  const hasMore = products.length < total;

  const cancelInFlight = useCallback(() => {
    abortRef.current?.abort();
    abortRef.current = null;
  }, []);

  const runSearch = useCallback(
    async (q: string, nextPage: number, append: boolean) => {
      cancelInFlight();
      const controller = new AbortController();
      abortRef.current = controller;
      const { signal } = controller;

      const url = `${searchUrlBase}?q=${encodeURIComponent(q)}&page=${nextPage}&limit=${PAGE_SIZE}`;

      try {
        const data = await fetchWithRetries(url, signal);
        if (!mountedRef.current) return;
        setTotal(data.total);
        setProducts((prev) => (append ? [...prev, ...data.products] : data.products));
        setPage(nextPage);
        setError(null);
      } catch (e) {
        if ((e as Error).name === 'AbortError') return;
        if (!mountedRef.current) return;
        setError(e instanceof Error ? e : new Error(String(e)));
      } finally {
        if (!mountedRef.current) return;
        if (append) {
          setIsLoadingMore(false);
        } else {
          setIsLoading(false);
        }
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
      if (!mountedRef.current) return;
      setProducts([]);
      setTotal(0);
      setPage(0);
      setError(null);
      setIsLoading(false);
      setIsLoadingMore(false);
      return;
    }
    setIsLoading(true);
    setIsLoadingMore(false);
    void runSearch(debouncedQuery, 0, false);
  }, [debouncedQuery, runSearch, cancelInFlight]);

  const loadMore = useCallback(() => {
    if (!debouncedQuery.trim() || isLoading || isLoadingMore || !hasMore) return;
    setIsLoadingMore(true);
    setIsLoading(false);
    void runSearch(debouncedQuery, page + 1, true);
  }, [debouncedQuery, isLoading, isLoadingMore, hasMore, page, runSearch]);

  const retry = useCallback(() => {
    if (!debouncedQuery.trim()) return;
    cancelInFlight();
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
