// FILE: useSearchProducts.ts
import { useState, useEffect, useRef, useCallback } from 'react';

// --- Types ---

interface Product {
  id: string;
  name: string;
  price: number;
  description: string;
  imageUrl: string;
}

interface SearchResponse {
  items: Product[];
  total: number;
  page: number;
  pageSize: number;
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

// --- Constants ---

const DEBOUNCE_MS = 300;
const PAGE_SIZE = 20;
const MAX_RETRIES = 3;

// --- Response Validation ---

function isValidProduct(obj: unknown): obj is Product {
  if (!obj || typeof obj !== 'object') return false;
  const o = obj as Record<string, unknown>;
  return (
    typeof o.id === 'string' &&
    typeof o.name === 'string' &&
    typeof o.price === 'number' &&
    Number.isFinite(o.price)
  );
}

function validateSearchResponse(data: unknown): SearchResponse {
  if (!data || typeof data !== 'object') {
    throw new Error('Invalid response: expected an object');
  }

  const d = data as Record<string, unknown>;

  if (!Array.isArray(d.items)) {
    throw new Error('Invalid response: items must be an array');
  }

  if (typeof d.total !== 'number' || !Number.isFinite(d.total)) {
    throw new Error('Invalid response: total must be a finite number');
  }

  const validItems = d.items.filter(isValidProduct);
  const invalidCount = d.items.length - validItems.length;

  if (invalidCount > 0) {
    console.warn(
      `Search response contained ${invalidCount} malformed product(s) out of ${d.items.length}`,
    );
  }

  // Adjust total to reflect validated items count to prevent infinite pagination loops
  const adjustedTotal =
    invalidCount > 0 ? (d.total as number) - invalidCount : (d.total as number);

  return {
    items: validItems,
    total: adjustedTotal,
    page: typeof d.page === 'number' ? d.page : 0,
    pageSize: typeof d.pageSize === 'number' ? d.pageSize : PAGE_SIZE,
  };
}

// --- Retry Logic ---

function isRetryable(status: number): boolean {
  return status >= 500 || status === 429;
}

function getBackoffMs(attempt: number): number {
  return Math.min(1000 * Math.pow(2, attempt), 10_000);
}

// --- Hook ---

export function useSearchProducts(query: string): UseSearchProductsResult {
  const [products, setProducts] = useState<Product[]>([]);
  const [total, setTotal] = useState(0);
  const [isLoading, setIsLoading] = useState(false);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [error, setError] = useState<Error | null>(null);

  const pageRef = useRef(0);
  const mountedRef = useRef(true);
  const abortControllerRef = useRef<AbortController | null>(null);
  const debounceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const retryTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Track the query that was last committed (search completed for)
  // vs the incoming query prop. loadMore only works when they match.
  const committedQueryRef = useRef(query);
  const pendingQueryRef = useRef(query);

  const hasMore = products.length < total;

  // --- Core fetch ---

  const fetchProducts = useCallback(
    async (
      searchQuery: string,
      page: number,
      signal: AbortSignal,
      attempt = 0,
    ): Promise<SearchResponse> => {
      const url = `/api/products/search?q=${encodeURIComponent(searchQuery)}&page=${page}&pageSize=${PAGE_SIZE}`;

      const response = await fetch(url, { signal });

      if (!response.ok) {
        if (isRetryable(response.status) && attempt < MAX_RETRIES) {
          const backoff = getBackoffMs(attempt);
          await new Promise<void>((resolve, reject) => {
            const timer = setTimeout(resolve, backoff);
            signal.addEventListener(
              'abort',
              () => {
                clearTimeout(timer);
                reject(new DOMException('Aborted', 'AbortError'));
              },
              { once: true },
            );
          });
          return fetchProducts(searchQuery, page, signal, attempt + 1);
        }
        throw new Error(`Search failed with status ${response.status}`);
      }

      const json = await response.json();
      return validateSearchResponse(json);
    },
    [],
  );

  // --- Initial / reset search ---

  const executeSearch = useCallback(
    async (searchQuery: string) => {
      // Abort any in-flight request
      abortControllerRef.current?.abort();
      const controller = new AbortController();
      abortControllerRef.current = controller;

      if (!searchQuery.trim()) {
        if (mountedRef.current) {
          setProducts([]);
          setTotal(0);
          setError(null);
          setIsLoading(false);
          committedQueryRef.current = searchQuery;
        }
        return;
      }

      if (mountedRef.current) {
        setIsLoading(true);
        setError(null);
      }

      try {
        const data = await fetchProducts(searchQuery, 0, controller.signal);
        if (mountedRef.current) {
          setProducts(data.items);
          setTotal(data.total);
          pageRef.current = 0;
          committedQueryRef.current = searchQuery;
        }
      } catch (err) {
        if (err instanceof DOMException && err.name === 'AbortError') return;
        if (mountedRef.current) {
          setError(err instanceof Error ? err : new Error(String(err)));
          setProducts([]);
          setTotal(0);
        }
      } finally {
        if (mountedRef.current) {
          setIsLoading(false);
        }
      }
    },
    [fetchProducts],
  );

  // --- Debounced query effect ---

  useEffect(() => {
    pendingQueryRef.current = query;

    if (debounceTimerRef.current) {
      clearTimeout(debounceTimerRef.current);
    }

    debounceTimerRef.current = setTimeout(() => {
      executeSearch(query);
    }, DEBOUNCE_MS);

    return () => {
      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current);
      }
    };
  }, [query, executeSearch]);

  // --- Cleanup on unmount ---

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      abortControllerRef.current?.abort();
      if (debounceTimerRef.current) clearTimeout(debounceTimerRef.current);
      if (retryTimerRef.current) clearTimeout(retryTimerRef.current);
    };
  }, []);

  // --- Load more (pagination) ---

  const loadMore = useCallback(() => {
    if (!hasMore || isLoading || isLoadingMore) return;

    // Prevent loadMore from firing if query has changed but search hasn't completed
    if (pendingQueryRef.current !== committedQueryRef.current) return;

    const nextPage = pageRef.current + 1;
    const currentQuery = committedQueryRef.current;

    // Abort previous and create new controller
    abortControllerRef.current?.abort();
    const controller = new AbortController();
    abortControllerRef.current = controller;

    setIsLoadingMore(true);
    setError(null);

    fetchProducts(currentQuery, nextPage, controller.signal)
      .then((data) => {
        if (mountedRef.current) {
          setProducts((prev) => [...prev, ...data.items]); // append, not replace
          setTotal(data.total);
          pageRef.current = nextPage;
        }
      })
      .catch((err) => {
        if (err instanceof DOMException && err.name === 'AbortError') return;
        if (mountedRef.current) {
          setError(err instanceof Error ? err : new Error(String(err)));
        }
      })
      .finally(() => {
        if (mountedRef.current) {
          setIsLoadingMore(false);
        }
      });
  }, [hasMore, isLoading, isLoadingMore, fetchProducts]);

  // --- Retry ---

  const retry = useCallback(() => {
    executeSearch(committedQueryRef.current || pendingQueryRef.current);
  }, [executeSearch]);

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
