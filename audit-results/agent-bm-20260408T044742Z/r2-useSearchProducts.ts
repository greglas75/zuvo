import { useState, useRef, useCallback, useEffect } from 'react';

interface Product {
  id: string;
  name: string;
  price: number;
  description?: string;
}

interface SearchResponse {
  products: Product[];
  total: number;
  hasMore: boolean;
}

interface UseSearchProductsReturn {
  products: Product[];
  total: number;
  isLoading: boolean;
  isLoadingMore: boolean;
  error: Error | null;
  hasMore: boolean;
  loadMore: () => void;
  retry: () => void;
}

export function useSearchProducts(query: string): UseSearchProductsReturn {
  const [products, setProducts] = useState<Product[]>([]);
  const [total, setTotal] = useState(0);
  const [isLoading, setIsLoading] = useState(false);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [error, setError] = useState<Error | null>(null);
  const [hasMore, setHasMore] = useState(true);
  const [page, setPage] = useState(0);

  const debounceTimerRef = useRef<NodeJS.Timeout | null>(null);
  const abortControllerRef = useRef<AbortController | null>(null);
  const pageRef = useRef(0);
  const maxRetries = 3;

  // Runtime validation of response shape
  const validateResponse = (data: unknown): data is SearchResponse => {
    if (typeof data !== 'object' || data === null) return false;
    const obj = data as Record<string, unknown>;
    return (
      Array.isArray(obj.products) &&
      typeof obj.total === 'number' &&
      typeof obj.hasMore === 'boolean' &&
      obj.products.every(
        (p: unknown) =>
          typeof p === 'object' &&
          p !== null &&
          typeof (p as Record<string, unknown>).id === 'string' &&
          typeof (p as Record<string, unknown>).name === 'string' &&
          typeof (p as Record<string, unknown>).price === 'number',
      )
    );
  };

  const fetchWithRetry = useCallback(
    async (searchQuery: string, pageNum: number, isLoadMore: boolean) => {
      const setLoadingState = isLoadMore ? setIsLoadingMore : setIsLoading;

      try {
        setLoadingState(true);
        setError(null);

        // Cancel previous request if it exists
        if (abortControllerRef.current) {
          abortControllerRef.current.abort();
        }

        // Capture the controller for this request
        const controller = new AbortController();
        abortControllerRef.current = controller;

        const attemptFetch = async (attempt: number): Promise<SearchResponse> => {
          try {
            const response = await fetch(
              `/api/search?q=${encodeURIComponent(searchQuery)}&page=${pageNum}`,
              {
                signal: controller.signal,
              },
            );

            if (!response.ok) {
              throw new Error(`HTTP ${response.status}`);
            }

            const data = await response.json();

            if (!validateResponse(data)) {
              throw new Error('Invalid response shape from API');
            }

            return data;
          } catch (err) {
            // Don't retry on abort (user cancelled)
            if (err instanceof DOMException && err.name === 'AbortError') {
              throw err;
            }

            if (attempt < maxRetries) {
              // Exponential backoff
              const delay = 300 * Math.pow(2, attempt);
              await new Promise((resolve) => setTimeout(resolve, delay));
              return attemptFetch(attempt + 1);
            }

            throw err;
          }
        };

        const data = await attemptFetch(0);

        // Success path
        if (isLoadMore) {
          setProducts((prev) => [...prev, ...data.products]);
        } else {
          setProducts(data.products);
          pageRef.current = 0;
          setPage(0);
        }

        setTotal(data.total);
        setHasMore(data.hasMore);
      } catch (err) {
        // Don't set error on abort
        if (err instanceof DOMException && err.name === 'AbortError') {
          return;
        }

        const errorObj = err instanceof Error ? err : new Error('Unknown error');
        setError(errorObj);
      } finally {
        setLoadingState(false);
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
      setHasMore(true);
      pageRef.current = 0;
      setPage(0);
      return;
    }

    debounceTimerRef.current = setTimeout(() => {
      fetchWithRetry(query, 0, false);
    }, 300);

    return () => {
      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current);
      }
    };
  }, [query, fetchWithRetry]);

  const loadMore = useCallback(() => {
    if (!hasMore || isLoadingMore || isLoading || !query.trim()) return;
    const nextPage = pageRef.current + 1;
    pageRef.current = nextPage;
    setPage(nextPage);
    fetchWithRetry(query, nextPage, true);
  }, [hasMore, isLoadingMore, isLoading, query, fetchWithRetry]);

  const retry = useCallback(() => {
    if (query.trim()) {
      // Use pageRef to get the correct page number (not stale closure)
      const retryPage = pageRef.current;
      const isLoadMore = retryPage > 0;
      fetchWithRetry(query, retryPage, isLoadMore);
    }
  }, [query, fetchWithRetry]);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current);
      }
      if (abortControllerRef.current) {
        abortControllerRef.current.abort();
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
