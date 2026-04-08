import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

type Product = {
  id: string;
  name: string;
  price: number;
};

type SearchResponse = {
  products: Product[];
  total: number;
};

type UseSearchProductsResult = {
  products: Product[];
  total: number;
  isLoading: boolean;
  isLoadingMore: boolean;
  error: string | null;
  hasMore: boolean;
  loadMore: () => Promise<void>;
  retry: () => Promise<void>;
};

const PAGE_SIZE = 20;
const DEBOUNCE_MS = 300;
const MAX_RETRIES = 3;
const RETRY_BASE_DELAY_MS = 250;

function isProduct(value: unknown): value is Product {
  if (!value || typeof value !== 'object') {
    return false;
  }

  const item = value as Record<string, unknown>;
  return (
    typeof item.id === 'string' &&
    typeof item.name === 'string' &&
    typeof item.price === 'number' &&
    Number.isFinite(item.price)
  );
}

function isSearchResponse(value: unknown): value is SearchResponse {
  if (!value || typeof value !== 'object') {
    return false;
  }

  const payload = value as Record<string, unknown>;
  return (
    Array.isArray(payload.products) &&
    payload.products.every((item) => isProduct(item)) &&
    typeof payload.total === 'number' &&
    Number.isInteger(payload.total) &&
    payload.total >= 0
  );
}

function sleepAbortable(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(new DOMException('Request aborted', 'AbortError'));
      return;
    }

    const timer = setTimeout(() => {
      signal.removeEventListener('abort', onAbort);
      resolve();
    }, ms);

    const onAbort = () => {
      clearTimeout(timer);
      signal.removeEventListener('abort', onAbort);
      reject(new DOMException('Request aborted', 'AbortError'));
    };

    signal.addEventListener('abort', onAbort);
  });
}

export function useSearchProducts(query: string): UseSearchProductsResult {
  const [products, setProducts] = useState<Product[]>([]);
  const [total, setTotal] = useState(0);
  const [isLoading, setIsLoading] = useState(false);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const mountedRef = useRef(true);
  const debounceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const requestAbortRef = useRef<AbortController | null>(null);
  const requestIdRef = useRef(0);
  const hasLoadedInitialRef = useRef(false);
  const lastRequestRef = useRef<{ query: string; offset: number; append: boolean }>({
    query,
    offset: 0,
    append: false,
  });

  const abortInFlight = useCallback(() => {
    if (requestAbortRef.current) {
      requestAbortRef.current.abort();
      requestAbortRef.current = null;
    }
  }, []);

  const requestWithRetry = useCallback(
    async (url: string, signal: AbortSignal): Promise<SearchResponse> => {
      let attempt = 0;

      while (attempt < MAX_RETRIES) {
        attempt += 1;

        if (signal.aborted) {
          throw new DOMException('Request aborted', 'AbortError');
        }

        try {
          const response = await fetch(url, { signal });

          if (!response.ok) {
            const retryable = response.status >= 500 || response.status === 429;
            if (!retryable) {
              throw new Error(`Search request failed with status ${response.status}`);
            }
            if (attempt >= MAX_RETRIES) {
              throw new Error(`Search request failed with status ${response.status}`);
            }
            await sleepAbortable(RETRY_BASE_DELAY_MS * 2 ** (attempt - 1), signal);
            continue;
          }

          const payload: unknown = await response.json();
          if (!isSearchResponse(payload)) {
            throw new Error('Invalid API response shape');
          }

          return payload;
        } catch (errorValue) {
          if ((errorValue as Error)?.name === 'AbortError') {
            throw errorValue;
          }

          const isValidationError =
            errorValue instanceof Error && errorValue.message === 'Invalid API response shape';
          if (isValidationError) {
            throw errorValue;
          }

          if (attempt >= MAX_RETRIES) {
            throw errorValue instanceof Error
              ? errorValue
              : new Error('Product search failed');
          }

          await sleepAbortable(RETRY_BASE_DELAY_MS * 2 ** (attempt - 1), signal);
        }
      }

      throw new Error('Product search failed');
    },
    [],
  );

  const executeSearch = useCallback(
    async (nextQuery: string, offset: number, append: boolean): Promise<void> => {
      lastRequestRef.current = { query: nextQuery, offset, append };
      setError(null);

      if (append) {
        setIsLoadingMore(true);
        setIsLoading(false);
      } else {
        setIsLoading(true);
        setIsLoadingMore(false);
      }

      abortInFlight();
      const controller = new AbortController();
      requestAbortRef.current = controller;
      const requestId = ++requestIdRef.current;

      try {
        const params = new URLSearchParams({
          query: nextQuery,
          take: String(PAGE_SIZE),
          skip: String(offset),
        });

        const data = await requestWithRetry(
          `/api/products/search?${params.toString()}`,
          controller.signal,
        );

        if (!mountedRef.current || requestId !== requestIdRef.current) {
          return;
        }

        hasLoadedInitialRef.current = true;
        setTotal(data.total);
        setProducts((prev) => (append ? [...prev, ...data.products] : data.products));
      } catch (errorValue) {
        if (!mountedRef.current || (errorValue as Error)?.name === 'AbortError') {
          return;
        }
        setError(
          errorValue instanceof Error ? errorValue.message : 'Failed to search products',
        );
      } finally {
        if (!mountedRef.current || requestId !== requestIdRef.current) {
          return;
        }
        setIsLoading(false);
        setIsLoadingMore(false);
      }
    },
    [abortInFlight, requestWithRetry],
  );

  useEffect(() => {
    hasLoadedInitialRef.current = false;
    setProducts([]);
    setTotal(0);

    if (debounceTimerRef.current) {
      clearTimeout(debounceTimerRef.current);
    }

    debounceTimerRef.current = setTimeout(() => {
      void executeSearch(query, 0, false);
    }, DEBOUNCE_MS);

    return () => {
      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current);
      }
    };
  }, [query, executeSearch]);

  useEffect(() => {
    mountedRef.current = true;

    return () => {
      mountedRef.current = false;
      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current);
      }
      abortInFlight();
    };
  }, [abortInFlight]);

  const hasMore = useMemo(() => products.length < total, [products.length, total]);

  const loadMore = useCallback(async (): Promise<void> => {
    if (!hasLoadedInitialRef.current) {
      return;
    }
    if (isLoading || isLoadingMore || !hasMore) {
      return;
    }

    await executeSearch(query, products.length, true);
  }, [executeSearch, hasMore, isLoading, isLoadingMore, products.length, query]);

  const retry = useCallback(async (): Promise<void> => {
    const last = lastRequestRef.current;
    await executeSearch(last.query, last.offset, last.append);
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
