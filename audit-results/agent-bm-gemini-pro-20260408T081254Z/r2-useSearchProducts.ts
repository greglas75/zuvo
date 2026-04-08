import { useState, useEffect, useRef, useCallback } from 'react';

export interface Product {
  id: string;
  name: string;
  price: number;
}

export interface SearchResponse {
  products: any[];
  total: number;
}

export const useSearchProducts = (query: string) => {
  const [products, setProducts] = useState<Product[]>([]);
  const [total, setTotal] = useState<number>(0);
  const [isLoading, setIsLoading] = useState<boolean>(false);
  const [isLoadingMore, setIsLoadingMore] = useState<boolean>(false);
  const [error, setError] = useState<Error | null>(null);
  const [page, setPage] = useState<number>(1);
  const mountedRef = useRef(true);
  
  const currentAbortController = useRef<AbortController | null>(null);
  const retryCount = useRef(0);
  const debounceTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const lastQuery = useRef<string>(query);

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      if (currentAbortController.current) {
        currentAbortController.current.abort();
      }
      if (debounceTimer.current) {
        clearTimeout(debounceTimer.current);
      }
    };
  }, []);

  const validateResponse = (data: any): data is SearchResponse => {
    if (!data || typeof data !== 'object') return false;
    if (!Array.isArray(data.products)) return false;
    if (typeof data.total !== 'number') return false;
    for (const p of data.products) {
      if (!p || typeof p.id !== 'string' || typeof p.name !== 'string' || typeof p.price !== 'number') return false;
    }
    return true;
  };

  const fetchProducts = useCallback(async (searchQuery: string, pageNum: number, isLoadMore: boolean, attempt = 0) => {
    if (currentAbortController.current) {
      currentAbortController.current.abort();
    }
    const abortController = new AbortController();
    currentAbortController.current = abortController;

    try {
      if (isLoadMore) {
        setIsLoadingMore(true);
      } else {
        setIsLoading(true);
      }
      setError(null);

      const response = await fetch(`/api/products?q=${encodeURIComponent(searchQuery)}&page=${pageNum}`, {
        signal: abortController.signal
      });

      if (!response.ok) {
        const isClientError = response.status >= 400 && response.status < 500 && response.status !== 429;
        if (isClientError) {
          throw new Error(`Client error: ${response.status}`);
        }
        throw new Error(`Server error: ${response.status}`);
      }

      const data = await response.json();

      if (!validateResponse(data)) {
        throw new Error('Invalid response format');
      }

      if (!mountedRef.current) return;

      if (isLoadMore) {
        setProducts(prev => [...prev, ...data.products]);
      } else {
        setProducts(data.products);
      }
      setTotal(data.total);
      setPage(pageNum);
      retryCount.current = 0;
      
    } catch (err: any) {
      if (err.name === 'AbortError') return;

      if (!mountedRef.current) return;

      const message = err instanceof Error ? err.message : String(err);
      
      const shouldRetry = attempt < 3 && message.includes('Server error');
      if (shouldRetry) {
        retryCount.current = attempt + 1;
        const delay = Math.pow(2, attempt) * 1000;
        debounceTimer.current = setTimeout(() => {
          fetchProducts(searchQuery, pageNum, isLoadMore, attempt + 1);
        }, delay);
      } else {
        setError(err instanceof Error ? err : new Error(message));
      }
    } finally {
      if (mountedRef.current) {
        if (isLoadMore) {
          setIsLoadingMore(false);
        } else {
          setIsLoading(false);
        }
      }
    }
  }, []);

  useEffect(() => {
    if (lastQuery.current !== query) {
      lastQuery.current = query;
      setPage(1);
      
      if (debounceTimer.current) {
        clearTimeout(debounceTimer.current);
      }

      debounceTimer.current = setTimeout(() => {
        fetchProducts(query, 1, false, 0);
      }, 300);
    } else if (mountedRef.current && products.length === 0 && total === 0 && !isLoading && !error && query === lastQuery.current && page === 1 && retryCount.current === 0) {
      // initial load
        if (debounceTimer.current) {
          clearTimeout(debounceTimer.current);
        }
        debounceTimer.current = setTimeout(() => {
          fetchProducts(query, 1, false, 0);
        }, 300);
    }
  }, [query, fetchProducts]);

  const loadMore = useCallback(() => {
    if (!isLoading && !isLoadingMore && products.length < total && !error) {
       fetchProducts(query, page + 1, true, 0);
    }
  }, [isLoading, isLoadingMore, products.length, total, error, query, page, fetchProducts]);

  const retry = useCallback(() => {
    fetchProducts(query, page, page > 1, 0);
  }, [fetchProducts, query, page]);

  return {
    products,
    total,
    isLoading,
    isLoadingMore,
    error,
    hasMore: products.length < total,
    loadMore,
    retry
  };
};
