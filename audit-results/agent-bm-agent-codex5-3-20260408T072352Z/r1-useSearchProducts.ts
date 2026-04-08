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

interface FetchRequest {
  query: string;
  page: number;
  append: boolean;
}

const DEBOUNCE_MS = 300;
const MAX_RETRY_ATTEMPTS = 3;
const BASE_RETRY_DELAY_MS = 300;

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object';
}

function isProduct(value: unknown): value is Product {
  if (!isRecord(value)) {
    return false;
  }

  return (
    typeof value.id === 'string' &&
    typeof value.name === 'string' &&
    typeof value.price === 'number' &&
    Number.isFinite(value.price) &&
    typeof value.currency === 'string'
  );
}

function parseResponse(value: unknown): { products: Product[]; total: number } {
  if (!isRecord(value)) {
    throw new Error('Invalid search response: expected object');
  }

  if (!Array.isArray(value.products) || !value.products.every((item) => isProduct(item))) {
    throw new Error('Invalid search response: products[] shape mismatch');
  }

  if (typeof value.total !== 'number' || !Number.isInteger(value.total) || value.total < 0) {
    throw new Error('Invalid search response: total must be a non-negative integer');
  }

  return { products: value.products, total: value.total };
}

function toErrorMessage(error: unknown): string {
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
  const [lastFailedRequest, setLastFailedRequest] = useState<FetchRequest | null>(null);

  const abortRef = useRef<AbortController | null>(null);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const retryTimersRef = useRef<Set<ReturnType<typeof setTimeout>>>(new Set());
  const isUnmountedRef = useRef(false);
  const queryRef = useRef(query);

  const clearRetryTimers = useCallback(() => {
    retryTimersRef.current.forEach((timerId) => clearTimeout(timerId));
    retryTimersRef.current.clear();
  }, []);

  const doFetch = useCallback(
    async (request: FetchRequest, attempt = 1): Promise<void> => {
      const trimmedQuery = request.query.trim();

      if (!trimmedQuery) {
        setProducts([]);
        setTotal(0);
        setPage(0);
        setError(null);
        setIsLoading(false);
        setIsLoadingMore(false);
        return;
      }

      abortRef.current?.abort();
      const controller = new AbortController();
      abortRef.current = controller;

      setError(null);
      if (request.append) {
        setIsLoadingMore(true);
        setIsLoading(false);
      } else {
        setIsLoading(true);
        setIsLoadingMore(false);
      }

      try {
        const params = new URLSearchParams({
          q: trimmedQuery,
          take: String(take),
          skip: String((request.page - 1) * take),
        });

        const response = await fetch(`/api/products/search?${params.toString()}`, {
          method: 'GET',
          signal: controller.signal,
        });

        if (!response.ok) {
          throw new Error(`Search request failed with status ${response.status}`);
        }

        const payload = parseResponse(await response.json());
        if (controller.signal.aborted || isUnmountedRef.current || queryRef.current !== request.query) {
          return;
        }

        setProducts((previous) => (request.append ? [...previous, ...payload.products] : payload.products));
        setTotal(payload.total);
        setPage(request.page);
        setLastFailedRequest(null);
      } catch (err: unknown) {
        if (controller.signal.aborted || isUnmountedRef.current) {
          return;
        }

        if (attempt < MAX_RETRY_ATTEMPTS) {
          const backoffMs = BASE_RETRY_DELAY_MS * 2 ** (attempt - 1);
          const timerId = setTimeout(() => {
            retryTimersRef.current.delete(timerId);
            void doFetch(request, attempt + 1);
          }, backoffMs);
          retryTimersRef.current.add(timerId);
          return;
        }

        setLastFailedRequest(request);
        setError(toErrorMessage(err));
      } finally {
        if (!isUnmountedRef.current) {
          setIsLoading(false);
          setIsLoadingMore(false);
        }
      }
    },
    [take],
  );

  useEffect(() => {
    queryRef.current = query;
    abortRef.current?.abort();
    clearRetryTimers();

    if (debounceRef.current) {
      clearTimeout(debounceRef.current);
    }

    setProducts([]);
    setTotal(0);
    setPage(0);
    setError(null);
    setIsLoading(false);
    setIsLoadingMore(false);

    if (!query.trim()) {
      return undefined;
    }

    debounceRef.current = setTimeout(() => {
      void doFetch({ query, page: 1, append: false });
    }, DEBOUNCE_MS);

    return () => {
      if (debounceRef.current) {
        clearTimeout(debounceRef.current);
      }
    };
  }, [query, doFetch, clearRetryTimers]);

  useEffect(() => {
    return () => {
      isUnmountedRef.current = true;
      abortRef.current?.abort();

      if (debounceRef.current) {
        clearTimeout(debounceRef.current);
      }

      clearRetryTimers();
    };
  }, [clearRetryTimers]);

  const loadMore = useCallback(() => {
    if (isLoading || isLoadingMore) {
      return;
    }

    if (products.length >= total) {
      return;
    }

    void doFetch({ query, page: page + 1, append: true });
  }, [doFetch, isLoading, isLoadingMore, products.length, query, page, total]);

  const retry = useCallback(() => {
    const request = lastFailedRequest ?? { query, page: page || 1, append: page > 1 };
    clearRetryTimers();
    void doFetch(request, 1);
  }, [clearRetryTimers, doFetch, lastFailedRequest, page, query]);

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
