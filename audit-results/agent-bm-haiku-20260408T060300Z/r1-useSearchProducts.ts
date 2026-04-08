import { useState, useCallback, useRef, useEffect } from 'react';

interface Product {
  id: string;
  name: string;
  price: number;
  description?: string;
}

interface SearchResponse {
  products: Product[];
  total: number;
  page: number;
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

const DEBOUNCE_MS = 300;
const MAX_RETRIES = 3;

export function useSearchProducts(
  apiUrl: string,
  initialQuery?: string,
): UseSearchProductsReturn {
  // State
  const [products, setProducts] = useState<Product[]>([]);
  const [total, setTotal] = useState(0);
  const [isLoading, setIsLoading] = useState(false);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [currentPage, setCurrentPage] = useState(0);
  const [query, setQuery] = useState(initialQuery ?? '');

  // Refs
  const abortControllerRef = useRef<AbortController | null>(null);
  const debounceTimerRef = useRef<NodeJS.Timeout | null>(null);
  const retryCountRef = useRef(0);

  // Validate API response shape
  const validateResponse = (data: any): data is SearchResponse => {
    return (
      data &&
      typeof data === 'object' &&
      Array.isArray(data.products) &&
      typeof data.total === 'number' &&
      typeof data.page === 'number' &&
      data.products.every(
        (p: any) =>
          p &&
          typeof p === 'object' &&
          typeof p.id === 'string' &&
          typeof p.name === 'string' &&
          typeof p.price === 'number',
      )
    );
  };

  // Perform search with retry logic
  const performSearch = useCallback(
    async (searchQuery: string, page: number, isLoadMore: boolean) => {
      if (!searchQuery.trim()) {
        setProducts([]);
        setTotal(0);
        setError(null);
        return;
      }

      const setLoadingState = isLoadMore ? setIsLoadingMore : setIsLoading;
      setLoadingState(true);
      setError(null);

      // Cancel previous request
      if (abortControllerRef.current) {
        abortControllerRef.current.abort();
      }

      abortControllerRef.current = new AbortController();
      retryCountRef.current = 0;

      const performFetch = async (attempt: number): Promise<void> => {
        try {
          const params = new URLSearchParams({
            q: searchQuery,
            page: String(page),
          });

          const response = await fetch(`${apiUrl}?${params}`, {
            signal: abortControllerRef.current!.signal,
          });

          if (!response.ok) throw new Error(`HTTP ${response.status}`);

          const data = await response.json();
          if (!validateResponse(data)) {
            throw new Error('Invalid response shape');
          }

          if (isLoadMore) {
            setProducts((prev) => [...prev, ...data.products]);
          } else {
            setProducts(data.products);
          }

          setTotal(data.total);
          setCurrentPage(page);
          setError(null);
          setLoadingState(false);
        } catch (err) {
          if (err instanceof DOMException && err.name === 'AbortError') {
            return; // Request was cancelled, ignore
          }

          retryCountRef.current++;
          if (retryCountRef.current < MAX_RETRIES) {
            // Exponential backoff: 200ms, 400ms, 800ms
            const delay = 200 * Math.pow(2, retryCountRef.current - 1);
            await new Promise((resolve) => setTimeout(resolve, delay));
            await performFetch(attempt + 1);
          } else {
            setError(err instanceof Error ? err.message : 'Search failed');
            setLoadingState(false);
          }
        }
      };

      await performFetch(0);
    },
    [apiUrl],
  );

  // Debounced search on query change
  useEffect(() => {
    if (debounceTimerRef.current) {
      clearTimeout(debounceTimerRef.current);
    }

    debounceTimerRef.current = setTimeout(() => {
      performSearch(query, 0, false);
    }, DEBOUNCE_MS);

    return () => {
      if (debounceTimerRef.current) clearTimeout(debounceTimerRef.current);
    };
  }, [query, performSearch]);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (abortControllerRef.current) {
        abortControllerRef.current.abort();
      }
      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current);
      }
    };
  }, []);

  const loadMore = useCallback(() => {
    if (!isLoading && !isLoadingMore && currentPage * 10 < total) {
      performSearch(query, currentPage + 1, true);
    }
  }, [query, currentPage, total, isLoading, isLoadingMore, performSearch]);

  const retry = useCallback(() => {
    performSearch(query, currentPage, false);
  }, [query, currentPage, performSearch]);

  const hasMore = products.length < total;

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
