import { useState, useEffect, useCallback, useRef } from 'react';

// Hand-rolled product type validation
function isValidProduct(data: any): boolean {
  return (
    data &&
    typeof data.id === 'string' &&
    typeof data.name === 'string' &&
    typeof data.price === 'number'
  );
}

function isValidResponse(data: any): boolean {
  return (
    data &&
    Array.isArray(data.products) &&
    data.products.every(isValidProduct) &&
    typeof data.total === 'number'
  );
}

export function useSearchProducts(query: string) {
  const [products, setProducts] = useState<any[]>([]);
  const [total, setTotal] = useState(0);
  const [isLoading, setIsLoading] = useState(false);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [skip, setSkip] = useState(0);

  const abortControllerRef = useRef<AbortController | null>(null);
  const debounceTimerRef = useRef<NodeJS.Timeout | null>(null);
  const retryCountRef = useRef(0);

  const fetchProducts = useCallback(
    async (currentQuery: string, currentSkip: number, isMore: boolean) => {
      if (isMore) setIsLoadingMore(true);
      else setIsLoading(true);
      setError(null);

      if (abortControllerRef.current) {
        abortControllerRef.current.abort();
      }
      abortControllerRef.current = new AbortController();

      const performFetch = async (attempt: number): Promise<void> => {
        try {
          const response = await fetch(
            `/api/products?q=${encodeURIComponent(currentQuery)}&skip=${currentSkip}&take=20`,
            { signal: abortControllerRef.current?.signal }
          );

          if (!response.ok) throw new Error(`HTTP ${response.status}`);

          const data = await response.json();

          if (!isValidResponse(data)) {
            throw new Error('Invalid API response shape');
          }

          if (isMore) {
            setProducts(prev => [...prev, ...data.products]);
          } else {
            setProducts(data.products);
          }
          setTotal(data.total);
          retryCountRef.current = 0;
        } catch (err: any) {
          if (err.name === 'AbortError') return;

          if (attempt < 3) {
            const delay = Math.pow(2, attempt) * 1000;
            console.log(`Retrying fetch (attempt ${attempt + 1}) in ${delay}ms...`);
            await new Promise(resolve => setTimeout(resolve, delay));
            return performFetch(attempt + 1);
          }

          setError(err.message || 'Failed to fetch products');
        } finally {
          if (!isMore) setIsLoading(false);
          setIsLoadingMore(false);
        }
      };

      await performFetch(0);
    },
    []
  );

  useEffect(() => {
    if (debounceTimerRef.current) clearTimeout(debounceTimerRef.current);

    setProducts([]);
    setSkip(0);
    setTotal(0);

    if (!query) {
      setIsLoading(false);
      return;
    }

    debounceTimerRef.current = setTimeout(() => {
      fetchProducts(query, 0, false);
    }, 300);

    return () => {
      if (debounceTimerRef.current) clearTimeout(debounceTimerRef.current);
      if (abortControllerRef.current) abortControllerRef.current.abort();
    };
  }, [query, fetchProducts]);

  const loadMore = useCallback(() => {
    if (isLoading || isLoadingMore || products.length >= total) return;
    const nextSkip = skip + 20;
    setSkip(nextSkip);
    fetchProducts(query, nextSkip, true);
  }, [isLoading, isLoadingMore, products.length, total, query, skip, fetchProducts]);

  const retry = useCallback(() => {
    fetchProducts(query, skip, skip > 0);
  }, [fetchProducts, query, skip]);

  return {
    products,
    total,
    isLoading,
    isLoadingMore,
    error,
    hasMore: products.length < total,
    loadMore,
    retry,
  };
}
