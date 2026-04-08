import { useEffect, useMemo, useRef, useState } from 'react';

export interface Product {
  id: string;
  name: string;
  price?: number;
  currency?: string;
  [key: string]: unknown;
}

interface SearchProductsResponse {
  products: Product[];
  total: number;
}

interface UseSearchProductsOptions {
  endpoint?: string;
  pageSize?: number;
  debounceMs?: number;
  fetcher?: typeof fetch;
}

interface SearchRequestState {
  query: string;
  page: number;
  append: boolean;
}

interface UseSearchProductsResult {
  products: Product[];
  total: number;
  isLoading: boolean;
  isLoadingMore: boolean;
  error: Error | null;
  hasMore: boolean;
  loadMore: () => Promise<void>;
  retry: () => Promise<void>;
}

const DEFAULT_ENDPOINT = '/api/products/search';
const DEFAULT_PAGE_SIZE = 20;
const DEFAULT_DEBOUNCE_MS = 300;
const MAX_RETRY_ATTEMPTS = 3;
const BASE_RETRY_DELAY_MS = 300;

export function useSearchProducts(
  query: string,
  options: UseSearchProductsOptions = {},
): UseSearchProductsResult {
  const {
    endpoint = DEFAULT_ENDPOINT,
    pageSize = DEFAULT_PAGE_SIZE,
    debounceMs = DEFAULT_DEBOUNCE_MS,
    fetcher = fetch,
  } = options;

  const [products, setProducts] = useState<Product[]>([]);
  const [total, setTotal] = useState(0);
  const [isLoading, setIsLoading] = useState(false);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [error, setError] = useState<Error | null>(null);

  const abortControllerRef = useRef<AbortController | null>(null);
  const debounceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const retryTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const mountedRef = useRef(true);
  const latestRequestIdRef = useRef(0);
  const activeQueryRef = useRef('');
  const currentPageRef = useRef(0);
  const lastRequestRef = useRef<SearchRequestState | null>(null);

  const hasMore = useMemo(() => products.length < total, [products.length, total]);

  useEffect(() => {
    mountedRef.current = true;

    return () => {
      mountedRef.current = false;
      abortControllerRef.current?.abort();

      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current);
      }

      if (retryTimerRef.current) {
        clearTimeout(retryTimerRef.current);
      }
    };
  }, []);

  useEffect(() => {
    const trimmedQuery = query.trim();
    activeQueryRef.current = trimmedQuery;

    if (debounceTimerRef.current) {
      clearTimeout(debounceTimerRef.current);
    }

    if (retryTimerRef.current) {
      clearTimeout(retryTimerRef.current);
      retryTimerRef.current = null;
    }

    abortInFlightRequest();

    if (!trimmedQuery) {
      currentPageRef.current = 0;
      setProducts([]);
      setTotal(0);
      setError(null);
      setIsLoading(false);
      setIsLoadingMore(false);
      lastRequestRef.current = null;
      return;
    }

    debounceTimerRef.current = setTimeout(() => {
      void runRequest({
        query: trimmedQuery,
        page: 0,
        append: false,
      });
    }, debounceMs);

    return () => {
      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current);
        debounceTimerRef.current = null;
      }
    };
  }, [query, debounceMs]);

  const runRequest = async (
    request: SearchRequestState,
    attempt = 1,
  ): Promise<void> => {
    if (!request.query) {
      return;
    }

    if (retryTimerRef.current) {
      clearTimeout(retryTimerRef.current);
      retryTimerRef.current = null;
    }

    const requestId = latestRequestIdRef.current + 1;
    latestRequestIdRef.current = requestId;
    lastRequestRef.current = request;

    abortInFlightRequest();
    const controller = new AbortController();
    abortControllerRef.current = controller;

    setError(null);
    setIsLoading(!request.append);
    setIsLoadingMore(request.append);

    try {
      const response = await fetcher(
        buildRequestUrl(endpoint, request.query, request.page, pageSize),
        { signal: controller.signal },
      );

      if (!response.ok) {
        throw new Error(`Product search failed with status ${response.status}`);
      }

      const json = (await response.json()) as unknown;
      const validated = validateSearchProductsResponse(json);

      if (!isLatestRequest(requestId) || !mountedRef.current) {
        return;
      }

      currentPageRef.current = request.page;
      setTotal(validated.total);
      setProducts((currentProducts) =>
        request.append
          ? [...currentProducts, ...validated.products]
          : validated.products,
      );
    } catch (unknownError) {
      if (isAbortError(unknownError)) {
        return;
      }

      const normalizedError =
        unknownError instanceof Error
          ? unknownError
          : new Error('Product search failed');

      if (attempt < MAX_RETRY_ATTEMPTS) {
        const delay = BASE_RETRY_DELAY_MS * 2 ** (attempt - 1);
        retryTimerRef.current = setTimeout(() => {
          void runRequest(request, attempt + 1);
        }, delay);
        return;
      }

      if (!isLatestRequest(requestId) || !mountedRef.current) {
        return;
      }

      setError(normalizedError);
    } finally {
      if (!isLatestRequest(requestId) || !mountedRef.current) {
        return;
      }

      setIsLoading(false);
      setIsLoadingMore(false);
    }
  };

  const loadMore = async (): Promise<void> => {
    if (
      !activeQueryRef.current ||
      isLoading ||
      isLoadingMore ||
      !hasMore
    ) {
      return;
    }

    await runRequest({
      query: activeQueryRef.current,
      page: currentPageRef.current + 1,
      append: true,
    });
  };

  const retry = async (): Promise<void> => {
    if (!lastRequestRef.current) {
      return;
    }

    await runRequest(lastRequestRef.current, 1);
  };

  const abortInFlightRequest = (): void => {
    abortControllerRef.current?.abort();
    abortControllerRef.current = null;
  };

  const isLatestRequest = (requestId: number): boolean =>
    latestRequestIdRef.current === requestId;

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

function buildRequestUrl(
  endpoint: string,
  query: string,
  page: number,
  pageSize: number,
): string {
  const base =
    typeof window === 'undefined' ? 'http://localhost' : window.location.origin;
  const url = new URL(endpoint, base);
  url.searchParams.set('q', query);
  url.searchParams.set('page', String(page));
  url.searchParams.set('take', String(pageSize));
  return url.toString();
}

function validateSearchProductsResponse(value: unknown): SearchProductsResponse {
  if (!isRecord(value)) {
    throw new Error('Search response must be an object');
  }

  if (!Array.isArray(value.products)) {
    throw new Error('Search response.products must be an array');
  }

  if (typeof value.total !== 'number' || !Number.isFinite(value.total) || value.total < 0) {
    throw new Error('Search response.total must be a non-negative number');
  }

  const products = value.products.map((product, index) => validateProduct(product, index));

  return {
    products,
    total: value.total,
  };
}

function validateProduct(value: unknown, index: number): Product {
  if (!isRecord(value)) {
    throw new Error(`Search response.products[${index}] must be an object`);
  }

  if (typeof value.id !== 'string' || value.id.trim().length === 0) {
    throw new Error(`Search response.products[${index}].id must be a non-empty string`);
  }

  if (typeof value.name !== 'string' || value.name.trim().length === 0) {
    throw new Error(`Search response.products[${index}].name must be a non-empty string`);
  }

  if (
    value.price !== undefined &&
    (typeof value.price !== 'number' || !Number.isFinite(value.price))
  ) {
    throw new Error(`Search response.products[${index}].price must be a finite number`);
  }

  if (
    value.currency !== undefined &&
    (typeof value.currency !== 'string' || value.currency.trim().length === 0)
  ) {
    throw new Error(`Search response.products[${index}].currency must be a non-empty string`);
  }

  return value as Product;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isAbortError(error: unknown): boolean {
  return (
    error instanceof DOMException && error.name === 'AbortError'
  ) || (
    error instanceof Error && error.name === 'AbortError'
  );
}
