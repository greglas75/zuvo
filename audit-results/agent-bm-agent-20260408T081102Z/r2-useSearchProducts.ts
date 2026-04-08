import { useCallback, useEffect, useRef, useState } from 'react';

interface Product {
  id: string;
  name: string;
  price: number;
  currency: string;
}

interface SearchProductsResult {
  products: Product[];
  total: number;
  isLoading: boolean;
  isLoadingMore: boolean;
  error: string | null;
  hasMore: boolean;
  loadMore: () => void;
  retry: () => void;
}

type SearchRequest = {
  query: string;
  page: number;
  append: boolean;
};

type SearchResponse = {
  products: Product[];
  total: number;
};

const DEBOUNCE_MS = 300;
const MAX_RETRY_ATTEMPTS = 3;
const BASE_BACKOFF_MS = 300;

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object';
}

function isProduct(value: unknown): value is Product {
  if (!isRecord(value)) {
    return false;
  }

  return (
    typeof value.id === 'string' &&
    value.id.trim().length > 0 &&
    typeof value.name === 'string' &&
    typeof value.price === 'number' &&
    Number.isFinite(value.price) &&
    value.price >= 0 &&
    typeof value.currency === 'string' &&
    value.currency.trim().length > 0
  );
}

function parseSearchResponse(value: unknown): SearchResponse {
  if (!isRecord(value)) {
    throw new Error('Invalid search response: expected an object');
  }

  if (!Array.isArray(value.products)) {
    throw new Error('Invalid search response: products must be an array');
  }

  if (!value.products.every((item) => isProduct(item))) {
    throw new Error('Invalid search response: product shape mismatch');
  }

  if (typeof value.total !== 'number' || !Number.isInteger(value.total) || value.total < 0) {
    throw new Error('Invalid search response: total must be a non-negative integer');
  }

  return {
    products: value.products,
    total: value.total,
  };
}

function toMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }

  return 'Unknown search error';
}

export function useSearchProducts(query: string, take = 20): SearchProductsResult {
  const [products, setProducts] = useState<Product[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(0);
  const [isLoading, setIsLoading] = useState(false);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const abortRef = useRef<AbortController | null>(null);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const retryRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const mountedRef = useRef(true);
  const queryRef = useRef(query);
  const lastRequestRef = useRef<SearchRequest | null>(null);
  const failedRequestRef = useRef<SearchRequest | null>(null);
  const requestVersionRef = useRef(0);

  const clearDebounceTimer = useCallback(() => {
    if (debounceRef.current) {
      clearTimeout(debounceRef.current);
      debounceRef.current = null;
    }
  }, []);

  const clearRetryTimer = useCallback(() => {
    if (retryRef.current) {
      clearTimeout(retryRef.current);
      retryRef.current = null;
    }
  }, []);

  const stopCurrentRequest = useCallback(() => {
    abortRef.current?.abort();
    abortRef.current = null;
  }, []);

  const setLoadingState = useCallback((append: boolean) => {
    if (append) {
      setIsLoading(false);
      setIsLoadingMore(true);
      return;
    }

    setIsLoading(true);
    setIsLoadingMore(false);
  }, []);

  const fetchProducts = useCallback(
    async (request: SearchRequest, attempt = 1): Promise<void> => {
      const trimmedQuery = request.query.trim();
      if (!trimmedQuery) {
        return;
      }

      const requestVersion = ++requestVersionRef.current;
      lastRequestRef.current = request;
      failedRequestRef.current = null;
      clearRetryTimer();
      stopCurrentRequest();

      const controller = new AbortController();
      abortRef.current = controller;
      setError(null);
      setLoadingState(request.append);

      try {
        const searchParams = new URLSearchParams({
          q: trimmedQuery,
          take: String(take),
          skip: String((request.page - 1) * take),
        });

        const response = await fetch(`/api/products/search?${searchParams.toString()}`, {
          method: 'GET',
          signal: controller.signal,
        });

        if (!response.ok) {
          throw new Error(`Search request failed with status ${response.status}`);
        }

        const payload = parseSearchResponse(await response.json());
        if (controller.signal.aborted || !mountedRef.current || requestVersion !== requestVersionRef.current) {
          return;
        }

        setProducts((current) => (request.append ? [...current, ...payload.products] : payload.products));
        setTotal(payload.total);
        setPage(request.page);
      } catch (error) {
        if (controller.signal.aborted || !mountedRef.current || requestVersion !== requestVersionRef.current) {
          return;
        }

        if (attempt < MAX_RETRY_ATTEMPTS) {
          const delayMs = BASE_BACKOFF_MS * 2 ** (attempt - 1);
          retryRef.current = setTimeout(() => {
            retryRef.current = null;
            void fetchProducts(request, attempt + 1);
          }, delayMs);
          return;
        }

        failedRequestRef.current = request;
        setError(toMessage(error));
      } finally {
        if (mountedRef.current && requestVersion === requestVersionRef.current) {
          setIsLoading(false);
          setIsLoadingMore(false);
        }
      }
    },
    [clearRetryTimer, setLoadingState, stopCurrentRequest, take],
  );

  useEffect(() => {
    queryRef.current = query;
    clearDebounceTimer();
    clearRetryTimer();
    stopCurrentRequest();
    lastRequestRef.current = null;
    failedRequestRef.current = null;
    setProducts([]);
    setTotal(0);
    setPage(0);
    setError(null);
    setIsLoading(false);
    setIsLoadingMore(false);

    const trimmedQuery = query.trim();
    if (!trimmedQuery) {
      return undefined;
    }

    debounceRef.current = setTimeout(() => {
      debounceRef.current = null;
      void fetchProducts({ query: trimmedQuery, page: 1, append: false });
    }, DEBOUNCE_MS);

    return () => {
      clearDebounceTimer();
    };
  }, [clearDebounceTimer, clearRetryTimer, fetchProducts, query, stopCurrentRequest]);

  useEffect(() => {
    return () => {
      mountedRef.current = false;
      clearDebounceTimer();
      clearRetryTimer();
      stopCurrentRequest();
    };
  }, [clearDebounceTimer, clearRetryTimer, stopCurrentRequest]);

  const loadMore = useCallback(() => {
    if (isLoading || isLoadingMore) {
      return;
    }

    if (!queryRef.current.trim() || products.length >= total) {
      return;
    }

    void fetchProducts({
      query: queryRef.current,
      page: page + 1,
      append: true,
    });
  }, [fetchProducts, isLoading, isLoadingMore, page, products.length, total]);

  const retry = useCallback(() => {
    clearRetryTimer();

    const request = failedRequestRef.current ?? lastRequestRef.current;
    if (!request) {
      if (!queryRef.current.trim()) {
        return;
      }

      void fetchProducts({ query: queryRef.current, page: page > 0 ? page : 1, append: page > 0 });
      return;
    }

    void fetchProducts(request);
  }, [clearRetryTimer, fetchProducts, page]);

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
