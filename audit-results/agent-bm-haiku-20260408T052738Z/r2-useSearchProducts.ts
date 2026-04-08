// FILE: useSearchProducts.ts (Fixed)

import { useState, useEffect, useRef, useCallback } from 'react';

interface Product {
  id: string;
  name: string;
  price: number;
}

interface SearchResponse {
  products: Product[];
  total: number;
}

interface UseSearchProductsReturn {
  products: Product[];
  total: number;
  isLoading: boolean;
  isLoadingMore: boolean;
  error: string | null;
  hasMore: boolean;
  loadMore: () => void;
  retry: () => void;
}

export function useSearchProducts(): UseSearchProductsReturn {
  const [products, setProducts] = useState<Product[]>([]);
  const [total, setTotal] = useState(0);
  const [isLoading, setIsLoading] = useState(false);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [hasMore, setHasMore] = useState(true);

  const abortControllerRef = useRef<AbortController | null>(null);
  const debounceTimerRef = useRef<NodeJS.Timeout | null>(null);
  const queryRef = useRef('');
  const pageRef = useRef(0);
  const searchIdRef = useRef(0);
  const currentSearchIdRef = useRef(0);
  const maxAttemptsRef = useRef(3);

  const isValidResponse = (data: any): data is SearchResponse => {
    return (
      typeof data === 'object' &&
      data !== null &&
      Array.isArray(data.products) &&
      typeof data.total === 'number' &&
      data.products.every((p: any) => typeof p.id === 'string' && typeof p.name === 'string' && typeof p.price === 'number')
    );
  };

  const performSearch = useCallback(
    async (query: string, isLoadMore = false) => {
      if (isLoadMore) {
        setIsLoadingMore(true);
      } else {
        setIsLoading(true);
        setProducts([]);
        setError(null);
        pageRef.current = 0;
      }

      searchIdRef.current += 1;
      currentSearchIdRef.current = searchIdRef.current;
      const currentSearchId = searchIdRef.current;

      abortControllerRef.current?.abort();
      abortControllerRef.current = new AbortController();
      const attemptsRef = useRef(0);

      const attemptFetch = async (): Promise<void> => {
        try {
          attemptsRef.current += 1;

          // Bail out if a new search has started
          if (currentSearchId !== currentSearchIdRef.current) {
            return;
          }

          const skip = pageRef.current * 10;
          const response = await fetch(`/api/products/search?q=${encodeURIComponent(query)}&skip=${skip}&take=10`, {
            signal: abortControllerRef.current!.signal,
          });

          if (!response.ok) {
            throw new Error(`HTTP ${response.status}`);
          }

          const data = await response.json();

          if (!isValidResponse(data)) {
            throw new Error('Invalid response format');
          }

          // Check again if this search is still current
          if (currentSearchId !== currentSearchIdRef.current) {
            return;
          }

          if (isLoadMore) {
            setProducts((prev) => [...prev, ...data.products]);
          } else {
            setProducts(data.products);
          }

          setTotal(data.total);
          setHasMore(data.products.length === 10);
          setError(null);

          if (isLoadingMore) {
            setIsLoadingMore(false);
          } else {
            setIsLoading(false);
          }
        } catch (err: any) {
          if (err.name === 'AbortError') {
            return;
          }

          if (attemptsRef.current < maxAttemptsRef.current && currentSearchId === currentSearchIdRef.current) {
            const backoffMs = Math.pow(2, attemptsRef.current - 1) * 100;
            await new Promise((resolve) => setTimeout(resolve, backoffMs));
            await attemptFetch();
          } else if (currentSearchId === currentSearchIdRef.current) {
            setError(err.message || 'Search failed');
            if (isLoadingMore) {
              setIsLoadingMore(false);
            } else {
              setIsLoading(false);
            }
          }
        }
      };

      await attemptFetch();
    },
    [],
  );

  const handleSearch = useCallback((query: string) => {
    queryRef.current = query;

    if (debounceTimerRef.current) {
      clearTimeout(debounceTimerRef.current);
    }

    if (!query.trim()) {
      setProducts([]);
      setTotal(0);
      setError(null);
      setHasMore(true);
      return;
    }

    debounceTimerRef.current = setTimeout(() => {
      performSearch(query, false);
    }, 300);
  }, [performSearch]);

  const loadMore = useCallback(() => {
    if (!isLoadingMore && hasMore && queryRef.current) {
      pageRef.current += 1;
      performSearch(queryRef.current, true);
    }
  }, [isLoadingMore, hasMore, performSearch]);

  const retry = useCallback(() => {
    if (queryRef.current) {
      performSearch(queryRef.current, false);
    }
  }, [performSearch]);

  useEffect(() => {
    return () => {
      abortControllerRef.current?.abort();
      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current);
      }
    };
  }, []);

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
