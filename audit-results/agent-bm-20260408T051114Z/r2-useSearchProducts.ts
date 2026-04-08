// FILE: useSearchProducts.ts
import { useState, useEffect, useRef, useCallback } from 'react';

// ── Types ─────────────────────────────────────────────────────────────────────

interface Product {
  id: string;
  name: string;
  price: number;
  [key: string]: unknown;
}

interface SearchResponse {
  products: Product[];
  total: number;
}

interface UseSearchProductsResult {
  products: Product[];
  total: number;
  isLoading: boolean;
  isLoadingMore: boolean;
  error: Error | null;
  hasMore: boolean;
  loadMore: () => void;
  retry: () => void;
}

// ── Constants ─────────────────────────────────────────────────────────────────

const PAGE_SIZE = 20;
const DEBOUNCE_MS = 300;
const MAX_RETRIES = 3;

// ── Runtime validation ────────────────────────────────────────────────────────

function isProduct(item: unknown): item is Product {
  if (!item || typeof item !== 'object') return false;
  const p = item as Record<string, unknown>;
  return (
    typeof p.id === 'string' &&
    typeof p.name === 'string' &&
    typeof p.price === 'number'
  );
}

function isValidSearchResponse(data: unknown): data is SearchResponse {
  if (!data || typeof data !== 'object') return false;
  const obj = data as Record<string, unknown>;
  return (
    Array.isArray(obj.products) &&
    obj.products.every(isProduct) &&
    typeof obj.total === 'number'
  );
}

// ── Fetch with retry (exponential backoff, 5xx/429 only) ─────────────────────

// FIX: Only retry on transient errors (5xx and 429). Immediately throw on 4xx
// to avoid wasting retries and adding latency for permanent client errors.
function isRetryable(status: number): boolean {
  return status >= 500 || status === 429;
}

async function fetchWithRetry(
  url: string,
  signal: AbortSignal,
  attempt = 0,
): Promise<SearchResponse> {
  const response = await fetch(url, { signal });

  if (!response.ok) {
    const err = new Error(`HTTP ${response.status}: ${response.statusText}`);
    if (attempt < MAX_RETRIES - 1 && isRetryable(response.status)) {
      const delay = Math.pow(2, attempt) * 200; // 200 ms, 400 ms, 800 ms
      await new Promise((resolve) => setTimeout(resolve, delay));
      return fetchWithRetry(url, signal, attempt + 1);
    }
    throw err;
  }

  const data: unknown = await response.json();

  if (!isValidSearchResponse(data)) {
    throw new Error('Invalid response shape from search API');
  }

  return data;
}

// ── Hook ──────────────────────────────────────────────────────────────────────

export function useSearchProducts(query: string): UseSearchProductsResult {
  const [products, setProducts] = useState<Product[]>([]);
  const [total, setTotal] = useState(0);
  const [isLoading, setIsLoading] = useState(false);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [error, setError] = useState<Error | null>(null);
  const [page, setPage] = useState(0);

  const abortRef = useRef<AbortController | null>(null);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const mountedRef = useRef(true);
  // FIX: Synchronous ref guard against double-fire on loadMore.
  // React state updates are async, so isLoadingMore may not be true yet
  // when a second rapid click arrives. A ref is set/cleared synchronously.
  const loadingMoreRef = useRef(false);

  const hasMore = products.length < total;

  // ── Core fetch ─────────────────────────────────────────────────────────

  const performSearch = useCallback(
    async (searchQuery: string, pageNum: number, append: boolean) => {
      // Cancel any in-flight request
      if (abortRef.current) {
        abortRef.current.abort();
      }
      const controller = new AbortController();
      abortRef.current = controller;

      if (append) {
        loadingMoreRef.current = true;
        setIsLoadingMore(true);
      } else {
        setIsLoading(true);
        setError(null);
      }

      try {
        const skip = pageNum * PAGE_SIZE;
        const url = `/api/products/search?q=${encodeURIComponent(searchQuery)}&take=${PAGE_SIZE}&skip=${skip}`;
        const result = await fetchWithRetry(url, controller.signal);

        if (!mountedRef.current) return;

        setProducts((prev) => (append ? [...prev, ...result.products] : result.products));
        setTotal(result.total);
        setError(null);
      } catch (err) {
        if (!mountedRef.current) return;
        if ((err as Error).name === 'AbortError') return;
        setError(err as Error);
      } finally {
        if (mountedRef.current) {
          loadingMoreRef.current = false;
          setIsLoading(false);
          setIsLoadingMore(false);
        }
      }
    },
    [],
  );

  // ── Debounced query effect ────────────────────────────────────────────

  useEffect(() => {
    if (debounceRef.current) {
      clearTimeout(debounceRef.current);
    }

    debounceRef.current = setTimeout(() => {
      setPage(0);
      setProducts([]);
      setTotal(0);
      setError(null);

      if (query.trim()) {
        performSearch(query, 0, false);
      } else {
        // Clear loading state when query is empty
        setIsLoading(false);
      }
    }, DEBOUNCE_MS);

    return () => {
      if (debounceRef.current) {
        clearTimeout(debounceRef.current);
      }
    };
  }, [query, performSearch]);

  // ── Unmount cleanup ───────────────────────────────────────────────────

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      abortRef.current?.abort();
      if (debounceRef.current) {
        clearTimeout(debounceRef.current);
      }
    };
  }, []);

  // ── loadMore ──────────────────────────────────────────────────────────

  const loadMore = useCallback(() => {
    // FIX: Use synchronous ref check (loadingMoreRef) in addition to state,
    // preventing double-fire before React re-render flushes isLoadingMore=true.
    if (loadingMoreRef.current || isLoading || !hasMore) return;
    const nextPage = page + 1;
    setPage(nextPage);
    performSearch(query, nextPage, true);
  }, [isLoading, hasMore, page, query, performSearch]);

  // ── retry ─────────────────────────────────────────────────────────────

  const retry = useCallback(() => {
    if (!query.trim()) return;
    // Retry the current page; if page > 0 (after loadMore failures),
    // retry the last attempted page to append results.
    performSearch(query, page, page > 0);
  }, [query, page, performSearch]);

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
