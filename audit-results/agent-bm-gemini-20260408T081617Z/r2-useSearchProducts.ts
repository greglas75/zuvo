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
  const currentRequestTokenRef = useRef(0);

  const fetchProducts = useCallback(
    async (currentQuery: string, currentSkip: number, isMore: boolean) => {
      // Create a unique token/identifier for this request invocation
      const requestToken = ++currentRequestTokenRef.current;
      
      if (isMore) setIsLoadingMore(true);
      else setIsLoading(true);
      setError(null);

      // Abort previous request (if any)
      if (abortControllerRef.current) {
        abortControllerRef.current.abort();
      }
      const controller = new AbortController();
      abortControllerRef.current = controller;
      const { signal } = controller;

      const performFetch = async (attempt: number): Promise<void> => {
        // Fix: check signal before even starting a retry attempt
        if (signal.aborted) return;

        try {
          const response = await fetch(
            `/api/products?q=${encodeURIComponent(currentQuery)}&skip=${currentSkip}&take=20`,
            { signal }
          );

          if (!response.ok) throw new Error(`HTTP ${response.status}`);

          const data = await response.json();

          // Fix: Ensure we are still processing the latest request before updating state
          if (requestToken !== currentRequestTokenRef.current || signal.aborted) return;

          if (!isValidResponse(data)) {
            throw new Error('Invalid API response shape');
          }

          if (isMore) {
            setProducts(prev => [...prev, ...data.products]);
          } else {
            setProducts(data.products);
          }
          setTotal(data.total);
          // Fix: Advance skip only on success
          setSkip(currentSkip);
        } catch (err: any) {
          if (err.name === 'AbortError' || signal.aborted) return;

          if (attempt < 2) { // 0, 1, 2 = 3 total attempts
            const delay = Math.pow(2, attempt + 1) * 1000;
            // Fix: Check signal before waiting
            await new Promise(resolve => {
              const timer = setTimeout(resolve, delay);
              signal.addEventListener('abort', () => clearTimeout(timer));
            });
            
            if (signal.aborted) return;
            return performFetch(attempt + 1);
          }

          if (requestToken === currentRequestTokenRef.current) {
            setError(err.message || 'Failed to fetch products');
          }
        } finally {
          // Fix: Guard cleanup to ensure we don't clear loading state of a NEWER parallel request
          if (requestToken === currentRequestTokenRef.current) {
            setIsLoading(false);
            setIsLoadingMore(false);
          }
        }
      };

      await performFetch(0);
    },
    []
  );

  useEffect(() => {
    if (debounceTimerRef.current) clearTimeout(debounceTimerRef.current);

    if (!query) {
      setProducts([]);
      setSkip(0);
      setTotal(0);
      setIsLoading(false);
      return;
    }

    debounceTimerRef.current = setTimeout(() => {
      // When query changes, we start from skip 0
      fetchProducts(query, 0, false);
    }, 300);

    return () => {
      if (debounceTimerRef.current) clearTimeout(debounceTimerRef.current);
      if (abortControllerRef.current) abortControllerRef.current.abort();
    };
  }, [query, fetchProducts]);

  const loadMore = useCallback(() => {
    if (isLoading || isLoadingMore || products.length >= total) return;
    const nextSkip = products.length; // Better to derive from length than local state for atomicity
    fetchProducts(query, nextSkip, true);
  }, [isLoading, isLoadingMore, products.length, total, query, fetchProducts]);

  const retry = useCallback(() => {
    fetchProducts(query, skip, skip > 0);
  }, [fetchProducts, query, skip]);

  return {
    products,
    total,
    isLoading,
    isLoadingMore,
    error,
    hasMore: products.length < total && total > 0,
    loadMore,
    retry,
  };
}
