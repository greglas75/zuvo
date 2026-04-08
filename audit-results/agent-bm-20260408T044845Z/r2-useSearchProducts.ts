// FILE: useSearchProducts.ts
import { useState, useEffect, useRef, useCallback } from 'react';

// ── Types ──────────────────────────────────────────────────────────────────────

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
  error: string | null;
  hasMore: boolean;
  loadMore: () => void;
  retry: () => void;
}

// ── Constants ─────────────────────────────────────────────────────────────────

const PAGE_SIZE = 20;
const DEBOUNCE_MS = 300;
const MAX_RETRIES = 3;

// ── Runtime validation ────────────────────────────────────────────────────────

function isValidSearchResponse(data: unknown): data is SearchResponse {
  if (!data || typeof data !== 'object') return false;
  const obj = data as Record<string, unknown>;
  if (!Array.isArray(obj.products)) return false;
  if (typeof obj.total !== 'number') return false;
  for (const item of obj.products) {
    if (!item || typeof item !== 'object') return false;
    const p = item as Record<string, unknown>;
    if (typeof p.id !== 'string') return false;
    if (typeof p.name !== 'string') return false;
    if (typeof p.price !== 'number') return false;
  }
  return true;
}

// ── Fetch with retry (exponential backoff) ────────────────────────────────────

async function fetchWithRetry(
  url: string,
  signal: AbortSignal,
  attempt = 0,
): Promise<SearchResponse> {
  try {
    const response = await fetch(url, { signal });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`);
    }
    const data: unknown = await response.json();
    if (!isValidSearchResponse(data)) {
      throw new Error('Invalid API response shape');
    }
    return data;
  } catch (err) {
    // Never retry an abort — propagate immediately
    if (err instanceof Error && err.name === 'AbortError') throw err;

    if (attempt < MAX_RETRIES - 1) {
      const backoffMs = Math.pow(2, attempt) * 1000; // 1s → 2s → 4s
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(resolve, backoffMs);
        // Clean up: use { once: true } so the listener auto-removes after firing,
        // preventing stale listener accumulation across retry attempts.
        signal.addEventListener(
          'abort',
          () => {
            clearTimeout(timer);
            const abortErr = new Error('AbortError');
            abortErr.name = 'AbortError';
            reject(abortErr);
          },
          { once: true },
        );
      });
      return fetchWithRetry(url, signal, attempt + 1);
    }

    throw err;
  }
}

// ── Hook ──────────────────────────────────────────────────────────────────────

export function useSearchProducts(query: string): UseSearchProductsResult {
  const [products, setProducts] = useState<Product[]>([]);
  const [total, setTotal] = useState(0);
  const [isLoading, setIsLoading] = useState(false);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Refs avoid stale closures and provide synchronous guards
  const pageRef = useRef(0);
  const isLoadingRef = useRef(false);   // synchronous guard prevents double-click race
  const isLoadingMoreRef = useRef(false);

  const abortControllerRef = useRef<AbortController | null>(null);
  const debounceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const isMountedRef = useRef(true);

  const hasMore = products.length < total;

  // ── Core fetch ──────────────────────────────────────────────────────────────

  const doSearch = useCallback(
    async (searchQuery: string, page: number, append: boolean) => {
      // Cancel any in-flight request before starting a new one
      if (abortControllerRef.current) {
        abortControllerRef.current.abort();
      }
      abortControllerRef.current = new AbortController();
      const { signal } = abortControllerRef.current;

      if (append) {
        isLoadingMoreRef.current = true;
        setIsLoadingMore(true);
      } else {
        isLoadingRef.current = true;
        setIsLoading(true);
        setError(null);
      }

      try {
        const skip = page * PAGE_SIZE;
        const url = `/api/products/search?q=${encodeURIComponent(searchQuery)}&take=${PAGE_SIZE}&skip=${skip}`;
        const data = await fetchWithRetry(url, signal);

        if (!isMountedRef.current) return;

        setProducts((prev) => (append ? [...prev, ...data.products] : data.products));
        setTotal(data.total);
        setError(null);
      } catch (err) {
        if (err instanceof Error && err.name === 'AbortError') return;
        if (!isMountedRef.current) return;
        setError(err instanceof Error ? err.message : 'An unknown error occurred');
      } finally {
        if (isMountedRef.current) {
          isLoadingRef.current = false;
          isLoadingMoreRef.current = false;
          setIsLoading(false);
          setIsLoadingMore(false);
        }
      }
    },
    [],
  );

  // ── Debounced search on query change ────────────────────────────────────────

  useEffect(() => {
    // Reset state for new search
    pageRef.current = 0;
    setProducts([]);
    setTotal(0);
    setError(null);

    // Abort any in-flight request immediately on query change
    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
    }

    if (debounceTimerRef.current) {
      clearTimeout(debounceTimerRef.current);
    }

    if (!query.trim()) {
      isLoadingRef.current = false;
      setIsLoading(false);
      return;
    }

    debounceTimerRef.current = setTimeout(() => {
      doSearch(query, 0, false);
    }, DEBOUNCE_MS);

    return () => {
      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current);
      }
    };
  }, [query, doSearch]);

  // ── Cleanup on unmount ──────────────────────────────────────────────────────

  useEffect(() => {
    isMountedRef.current = true;
    return () => {
      isMountedRef.current = false;
      if (abortControllerRef.current) {
        abortControllerRef.current.abort();
      }
      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current);
      }
    };
  }, []);

  // ── Pagination ──────────────────────────────────────────────────────────────

  const loadMore = useCallback(() => {
    // Synchronous ref guard prevents double-click races before React state updates
    if (isLoadingRef.current || isLoadingMoreRef.current || !hasMore) return;
    const nextPage = pageRef.current + 1;
    pageRef.current = nextPage;
    doSearch(query, nextPage, true);
  }, [hasMore, query, doSearch]);

  // ── Manual retry ────────────────────────────────────────────────────────────

  const retry = useCallback(() => {
    if (!query.trim()) return;
    const isAppend = pageRef.current > 0;
    doSearch(query, pageRef.current, isAppend);
  }, [query, doSearch]);

  return { products, total, isLoading, isLoadingMore, error, hasMore, loadMore, retry };
}
