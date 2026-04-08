import { useCallback, useEffect, useRef, useState } from 'react';

export interface Product {
  id: string;
  name: string;
  price: number;
  currency: string;
}

export interface SearchProductsResult {
  products: Product[];
  total: number;
}

const DEBOUNCE_MS = 300;
const MAX_RETRIES = 3;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isProduct(value: unknown): value is Product {
  if (!isRecord(value)) return false;
  return (
    typeof value.id === 'string' &&
    typeof value.name === 'string' &&
    typeof value.price === 'number' &&
    typeof value.currency === 'string'
  );
}

function parseSearchResponse(data: unknown): SearchProductsResult {
  if (!isRecord(data)) {
    throw new Error('Invalid API response: expected object');
  }
  const total = data.total;
  if (typeof total !== 'number' || !Number.isFinite(total)) {
    throw new Error('Invalid API response: total must be a finite number');
  }
  const productsRaw = data.products;
  if (!Array.isArray(productsRaw)) {
    throw new Error('Invalid API response: products must be an array');
  }
  const products: Product[] = [];
  for (const p of productsRaw) {
    if (!isProduct(p)) {
      throw new Error('Invalid API response: invalid product shape');
    }
    products.push(p);
  }
  return { products, total };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Product search hook. Pass `query` from the parent (controlled input).
 * Debounces server requests by 300ms; cancels in-flight fetches on query change or unmount.
 */
export function useSearchProducts(searchUrl: string, query: string) {
  const [products, setProducts] = useState<Product[]>([]);
  const [total, setTotal] = useState(0);
  const [isLoading, setIsLoading] = useState(false);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [error, setError] = useState<Error | null>(null);

  const abortRef = useRef<AbortController | null>(null);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const mountedRef = useRef(true);
  const nextPageRef = useRef(0);

  const cancelInFlight = useCallback(() => {
    if (abortRef.current) {
      abortRef.current.abort();
      abortRef.current = null;
    }
  }, []);

  const runFetch = useCallback(
    async (q: string, pageIndex: number, signal: AbortSignal): Promise<SearchProductsResult> => {
      let attempt = 0;
      let lastErr: Error | null = null;
      while (attempt < MAX_RETRIES) {
        try {
          const base =
            typeof window !== 'undefined' && window.location?.origin
              ? window.location.origin
              : 'http://localhost';
          const url = new URL(searchUrl, base);
          url.searchParams.set('q', q);
          url.searchParams.set('page', String(pageIndex));

          const res = await fetch(url.toString(), { signal });
          if (!res.ok) {
            throw new Error(`HTTP ${res.status}`);
          }
          const json: unknown = await res.json();
          return parseSearchResponse(json);
        } catch (e) {
          if (signal.aborted) {
            throw e;
          }
          lastErr = e instanceof Error ? e : new Error(String(e));
          attempt += 1;
          if (attempt >= MAX_RETRIES) {
            break;
          }
          const backoff = 2 ** (attempt - 1) * 100;
          await sleep(backoff);
        }
      }
      throw lastErr ?? new Error('Request failed');
    },
    [searchUrl],
  );

  const fetchPage = useCallback(
    async (q: string, pageIndex: number, append: boolean) => {
      cancelInFlight();
      const controller = new AbortController();
      abortRef.current = controller;
      const { signal } = controller;

      if (append) {
        setIsLoadingMore(true);
        setIsLoading(false);
      } else {
        setIsLoading(true);
        setIsLoadingMore(false);
      }
      setError(null);

      try {
        const result = await runFetch(q, pageIndex, signal);
        if (!mountedRef.current || signal.aborted) {
          return;
        }
        if (append) {
          setProducts((prev) => [...prev, ...result.products]);
        } else {
          setProducts(result.products);
          nextPageRef.current = 1;
        }
        setTotal(result.total);
        if (append) {
          nextPageRef.current = pageIndex + 1;
        }
      } catch (e) {
        if (signal.aborted || !mountedRef.current) {
          return;
        }
        setError(e instanceof Error ? e : new Error(String(e)));
      } finally {
        if (mountedRef.current && !signal.aborted) {
          setIsLoading(false);
          setIsLoadingMore(false);
        }
      }
    },
    [cancelInFlight, runFetch],
  );

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      if (debounceRef.current) {
        clearTimeout(debounceRef.current);
        debounceRef.current = null;
      }
      cancelInFlight();
    };
  }, [cancelInFlight]);

  useEffect(() => {
    if (debounceRef.current) {
      clearTimeout(debounceRef.current);
    }
    debounceRef.current = setTimeout(() => {
      debounceRef.current = null;
      const q = query.trim();
      if (!q) {
        setProducts([]);
        setTotal(0);
        setError(null);
        nextPageRef.current = 0;
        return;
      }
      nextPageRef.current = 0;
      void fetchPage(q, 0, false);
    }, DEBOUNCE_MS);

    return () => {
      if (debounceRef.current) {
        clearTimeout(debounceRef.current);
        debounceRef.current = null;
      }
    };
  }, [query, fetchPage]);

  const loadMore = useCallback(() => {
    const q = query.trim();
    if (!q || isLoading || isLoadingMore) {
      return;
    }
    if (products.length >= total && total > 0) {
      return;
    }
    void fetchPage(q, nextPageRef.current, true);
  }, [query, isLoading, isLoadingMore, products.length, total, fetchPage]);

  const retry = useCallback(() => {
    const q = query.trim();
    if (!q) {
      return;
    }
    nextPageRef.current = 0;
    void fetchPage(q, 0, false);
  }, [query, fetchPage]);

  const hasMore = total > 0 && products.length < total;

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
