// FILE: useSearchProducts.ts
import { useState, useEffect, useRef, useCallback } from 'react';

interface Product {
  id: string;
  name: string;
  price: number;
  description: string;
  imageUrl: string;
}

interface SearchResponse {
  products: Product[];
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

const DEBOUNCE_MS = 300;
const MAX_RETRIES = 3;
const PAGE_SIZE = 20;

function validateSearchResponse(data: unknown): data is SearchResponse {
  if (typeof data !== 'object' || data === null) return false;
  const obj = data as Record<string, unknown>;
  if (!Array.isArray(obj.products)) return false;
  if (typeof obj.total !== 'number') return false;
  if (typeof obj.page !== 'number') return false;
  if (typeof obj.pageSize !== 'number') return false;
  for (const item of obj.products) {
    if (typeof item !== 'object' || item === null) return false;
    const product = item as Record<string, unknown>;
    if (typeof product.id !== 'string') return false;
    if (typeof product.name !== 'string') return false;
    if (typeof product.price !== 'number') return false;
  }
  return true;
}

async function fetchWithRetry(
  url: string,
  signal: AbortSignal,
  attempt = 1,
): Promise<SearchResponse> {
  try {
    const response = await fetch(url, { signal });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`);
    }
    const data: unknown = await response.json();
    if (!validateSearchResponse(data)) {
      throw new Error('Invalid API response shape');
    }
    return data;
  } catch (err) {
    if ((err as Error).name === 'AbortError') {
      throw err;
    }
    if (attempt >= MAX_RETRIES) {
      throw err;
    }
    const delay = Math.pow(2, attempt) * 100; // 200ms, 400ms, 800ms
    await new Promise((resolve) => setTimeout(resolve, delay));
    return fetchWithRetry(url, signal, attempt + 1);
  }
}

export function useSearchProducts(query: string): UseSearchProductsResult {
  const [products, setProducts] = useState<Product[]>([]);
  const [total, setTotal] = useState(0);
  const [isLoading, setIsLoading] = useState(false);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [error, setError] = useState<Error | null>(null);
  const [page, setPage] = useState(1);

  const abortControllerRef = useRef<AbortController | null>(null);
  const debounceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const mountedRef = useRef(true);

  const hasMore = products.length < total;

  const fetchProducts = useCallback(
    async (searchQuery: string, pageNum: number, isLoadMore: boolean) => {
      // Abort any in-flight request
      if (abortControllerRef.current) {
        abortControllerRef.current.abort();
      }

      const controller = new AbortController();
      abortControllerRef.current = controller;

      if (isLoadMore) {
        setIsLoadingMore(true);
      } else {
        setIsLoading(true);
        setError(null);
      }

      try {
        const url = `/api/products/search?q=${encodeURIComponent(searchQuery)}&page=${pageNum}&pageSize=${PAGE_SIZE}`;
        const data = await fetchWithRetry(url, controller.signal);

        if (!mountedRef.current) return;

        if (isLoadMore) {
          setProducts((prev) => [...prev, ...data.products]);
        } else {
          setProducts(data.products);
        }
        setTotal(data.total);
        setError(null);
      } catch (err) {
        if ((err as Error).name === 'AbortError') return;
        if (!mountedRef.current) return;
        setError(err as Error);
      } finally {
        if (mountedRef.current) {
          setIsLoading(false);
          setIsLoadingMore(false);
        }
      }
    },
    [],
  );

  // Debounced search on query change
  useEffect(() => {
    if (debounceTimerRef.current) {
      clearTimeout(debounceTimerRef.current);
    }

    if (!query.trim()) {
      setProducts([]);
      setTotal(0);
      setPage(1);
      setError(null);
      setIsLoading(false);
      return;
    }

    setPage(1);

    debounceTimerRef.current = setTimeout(() => {
      fetchProducts(query, 1, false);
    }, DEBOUNCE_MS);

    return () => {
      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current);
      }
    };
  }, [query, fetchProducts]);

  // Cleanup on unmount
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      if (abortControllerRef.current) {
        abortControllerRef.current.abort();
      }
      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current);
      }
    };
  }, []);

  const loadMore = useCallback(() => {
    if (!hasMore || isLoading || isLoadingMore) return;
    const nextPage = page + 1;
    setPage(nextPage);
    fetchProducts(query, nextPage, true);
  }, [hasMore, isLoading, isLoadingMore, page, query, fetchProducts]);

  const retry = useCallback(() => {
    fetchProducts(query, page, false);
  }, [query, page, fetchProducts]);

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
