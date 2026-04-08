// FILE: useSearchProducts.test.ts
import { renderHook, act, waitFor } from '@testing-library/react';
import { useSearchProducts } from './r2-useSearchProducts';

// ── Test Data Constants ──
const SEARCH_QUERY = 'laptop';
const EMPTY_QUERY = '';
const PAGE_SIZE = 20;
const DEBOUNCE_MS = 300;

const MOCK_PRODUCT_1 = {
  id: 'prod-001',
  name: 'Gaming Laptop',
  price: 1299.99,
  description: 'High-performance gaming laptop',
  imageUrl: 'https://example.com/laptop1.jpg',
};

const MOCK_PRODUCT_2 = {
  id: 'prod-002',
  name: 'Work Laptop',
  price: 899.99,
  description: 'Business laptop',
  imageUrl: 'https://example.com/laptop2.jpg',
};

const MOCK_PRODUCT_PAGE2 = {
  id: 'prod-021',
  name: 'Laptop Stand',
  price: 49.99,
  description: 'Ergonomic stand',
  imageUrl: 'https://example.com/stand.jpg',
};

const MOCK_RESPONSE_PAGE1 = {
  products: [MOCK_PRODUCT_1, MOCK_PRODUCT_2],
  total: 25,
  page: 1,
  pageSize: PAGE_SIZE,
};

const MOCK_RESPONSE_PAGE2 = {
  products: [MOCK_PRODUCT_PAGE2],
  total: 25,
  page: 2,
  pageSize: PAGE_SIZE,
};

const MOCK_EMPTY_RESPONSE = {
  products: [],
  total: 0,
  page: 1,
  pageSize: PAGE_SIZE,
};

// ── Helpers ──
let mockFetch: jest.SpyInstance;

function createFetchResponse(data: unknown, ok = true, status = 200) {
  return Promise.resolve({
    ok,
    status,
    statusText: ok ? 'OK' : 'Internal Server Error',
    json: () => Promise.resolve(data),
  });
}

/** Flush microtask queue — ensures async state updates settle between timer advances */
function flushPromises(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

describe('useSearchProducts', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    jest.useFakeTimers();
    mockFetch = jest.spyOn(global, 'fetch').mockImplementation(() =>
      createFetchResponse(MOCK_RESPONSE_PAGE1),
    );
  });

  afterEach(() => {
    jest.useRealTimers();
    mockFetch.mockRestore();
  });

  // ── Initial State ──
  it('returns empty initial state before any search', () => {
    const { result } = renderHook(() => useSearchProducts(EMPTY_QUERY));

    expect(result.current.products).toEqual([]);
    expect(result.current.total).toBe(0);
    expect(result.current.isLoading).toBe(false);
    expect(result.current.isLoadingMore).toBe(false);
    expect(result.current.error).toBeNull();
    expect(result.current.hasMore).toBe(false);
  });

  // ── Debounce ──
  describe('debounce', () => {
    it('does not call fetch before 300ms debounce elapses', () => {
      renderHook(() => useSearchProducts(SEARCH_QUERY));

      act(() => { jest.advanceTimersByTime(299); });

      expect(mockFetch).not.toHaveBeenCalled();
    });

    it('calls fetch after 300ms debounce elapses', async () => {
      renderHook(() => useSearchProducts(SEARCH_QUERY));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await flushPromises();
      });

      expect(mockFetch).toHaveBeenCalledTimes(1);
      expect(mockFetch).toHaveBeenCalledWith(
        expect.stringContaining(`q=${encodeURIComponent(SEARCH_QUERY)}`),
        expect.objectContaining({ signal: expect.any(AbortSignal) }),
      );
    });

    it('resets debounce timer when query changes rapidly', async () => {
      const { rerender } = renderHook(
        ({ query }: { query: string }) => useSearchProducts(query),
        { initialProps: { query: 'lap' } },
      );

      act(() => { jest.advanceTimersByTime(200); });
      rerender({ query: 'laptop' });
      act(() => { jest.advanceTimersByTime(200); });

      expect(mockFetch).not.toHaveBeenCalled();

      await act(async () => {
        jest.advanceTimersByTime(100);
        await flushPromises();
      });

      expect(mockFetch).toHaveBeenCalledTimes(1);
      expect(mockFetch).toHaveBeenCalledWith(
        expect.stringContaining('q=laptop'),
        expect.any(Object),
      );
    });
  });

  // ── AbortController ──
  describe('AbortController', () => {
    it('aborts in-flight request when query changes', async () => {
      const abortSpy = jest.spyOn(AbortController.prototype, 'abort');

      const { rerender } = renderHook(
        ({ query }: { query: string }) => useSearchProducts(query),
        { initialProps: { query: 'lap' } },
      );

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await flushPromises();
      });
      expect(mockFetch).toHaveBeenCalledTimes(1);

      rerender({ query: 'phone' });
      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await flushPromises();
      });

      expect(abortSpy).toHaveBeenCalled();
      abortSpy.mockRestore();
    });

    it('aborts in-flight request on unmount', async () => {
      const abortSpy = jest.spyOn(AbortController.prototype, 'abort');

      const { unmount } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await flushPromises();
      });

      unmount();

      expect(abortSpy).toHaveBeenCalled();
      abortSpy.mockRestore();
    });
  });

  // ── Pagination ──
  describe('pagination', () => {
    it('loadMore appends results instead of replacing', async () => {
      mockFetch
        .mockImplementationOnce(() => createFetchResponse(MOCK_RESPONSE_PAGE1))
        .mockImplementationOnce(() => createFetchResponse(MOCK_RESPONSE_PAGE2));

      const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await flushPromises();
      });
      await waitFor(() => expect(result.current.products).toHaveLength(2));

      expect(result.current.hasMore).toBe(true);

      await act(async () => {
        result.current.loadMore();
        await flushPromises();
      });
      await waitFor(() => expect(result.current.products).toHaveLength(3));

      expect(result.current.products[0]).toEqual(MOCK_PRODUCT_1);
      expect(result.current.products[1]).toEqual(MOCK_PRODUCT_2);
      expect(result.current.products[2]).toEqual(MOCK_PRODUCT_PAGE2);
    });

    it('hasMore is false when all products are loaded', async () => {
      const allLoadedResponse = { ...MOCK_RESPONSE_PAGE1, total: 2 };
      mockFetch.mockImplementation(() => createFetchResponse(allLoadedResponse));

      const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await flushPromises();
      });
      await waitFor(() => expect(result.current.products).toHaveLength(2));

      expect(result.current.hasMore).toBe(false);
    });

    it('loadMore does not fire when already loading', async () => {
      mockFetch.mockImplementation(() => new Promise(() => {}));

      const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await flushPromises();
      });

      act(() => { result.current.loadMore(); });

      expect(mockFetch).toHaveBeenCalledTimes(1);
    });
  });

  // ── Loading States ──
  describe('loading states', () => {
    it('sets isLoading for initial search, not isLoadingMore', async () => {
      let resolveFirst!: (value: unknown) => void;
      mockFetch.mockImplementationOnce(() => new Promise((r) => { resolveFirst = r; }));

      const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await flushPromises();
      });

      expect(result.current.isLoading).toBe(true);
      expect(result.current.isLoadingMore).toBe(false);

      await act(async () => {
        resolveFirst({
          ok: true,
          status: 200,
          json: () => Promise.resolve(MOCK_RESPONSE_PAGE1),
        });
        await flushPromises();
      });

      expect(result.current.isLoading).toBe(false);
    });

    it('sets isLoadingMore for loadMore, not isLoading', async () => {
      mockFetch.mockImplementationOnce(() => createFetchResponse(MOCK_RESPONSE_PAGE1));

      const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await flushPromises();
      });
      await waitFor(() => expect(result.current.isLoading).toBe(false));

      let resolveMore!: (value: unknown) => void;
      mockFetch.mockImplementationOnce(() => new Promise((r) => { resolveMore = r; }));

      act(() => { result.current.loadMore(); });

      await waitFor(() => expect(result.current.isLoadingMore).toBe(true));
      expect(result.current.isLoading).toBe(false);

      await act(async () => {
        resolveMore({
          ok: true,
          status: 200,
          json: () => Promise.resolve(MOCK_RESPONSE_PAGE2),
        });
        await flushPromises();
      });

      expect(result.current.isLoadingMore).toBe(false);
    });
  });

  // ── Retry ──
  describe('retry', () => {
    // FIX: Use flushPromises between timer advances for stable microtask ordering
    it('retries up to 3 times with exponential backoff on failure', async () => {
      mockFetch
        .mockImplementationOnce(() => createFetchResponse(null, false, 500))
        .mockImplementationOnce(() => createFetchResponse(null, false, 500))
        .mockImplementationOnce(() => createFetchResponse(MOCK_RESPONSE_PAGE1));

      const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await flushPromises();
      });

      // First retry after 200ms backoff
      await act(async () => {
        jest.advanceTimersByTime(200);
        await flushPromises();
      });
      // Second retry after 400ms backoff
      await act(async () => {
        jest.advanceTimersByTime(400);
        await flushPromises();
      });

      await waitFor(() => expect(result.current.isLoading).toBe(false));

      expect(mockFetch).toHaveBeenCalledTimes(3);
      expect(result.current.error).toBeNull();
      expect(result.current.products).toHaveLength(2);
    });

    it('sets error after exhausting all 3 retry attempts', async () => {
      mockFetch.mockImplementation(() => createFetchResponse(null, false, 500));

      const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await flushPromises();
      });
      await act(async () => {
        jest.advanceTimersByTime(200);
        await flushPromises();
      });
      await act(async () => {
        jest.advanceTimersByTime(400);
        await flushPromises();
      });

      await waitFor(() => expect(result.current.error).not.toBeNull());

      expect(result.current.error!.message).toContain('HTTP 500');
      expect(mockFetch).toHaveBeenCalledTimes(3);
    });

    it('retry function re-fetches with current page state', async () => {
      mockFetch
        .mockImplementationOnce(() => createFetchResponse(MOCK_RESPONSE_PAGE1))
        .mockImplementationOnce(() => createFetchResponse(null, false, 500))
        .mockImplementationOnce(() => createFetchResponse(null, false, 500))
        .mockImplementationOnce(() => createFetchResponse(null, false, 500))
        .mockImplementationOnce(() => createFetchResponse(MOCK_RESPONSE_PAGE1));

      const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      // Initial fetch succeeds
      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await flushPromises();
      });
      await waitFor(() => expect(result.current.products).toHaveLength(2));

      // Trigger error via retry
      mockFetch.mockImplementation(() => createFetchResponse(null, false, 500));
      await act(async () => {
        result.current.retry();
        await flushPromises();
      });
      // Exhaust retries
      await act(async () => {
        jest.advanceTimersByTime(200);
        await flushPromises();
      });
      await act(async () => {
        jest.advanceTimersByTime(400);
        await flushPromises();
      });
      await waitFor(() => expect(result.current.error).not.toBeNull());

      // Now retry succeeds
      mockFetch.mockImplementation(() => createFetchResponse(MOCK_RESPONSE_PAGE1));
      await act(async () => {
        result.current.retry();
        await flushPromises();
      });
      await waitFor(() => expect(result.current.error).toBeNull());
    });
  });

  // ── Response Validation ──
  describe('response validation', () => {
    it('sets error when API returns invalid response shape', async () => {
      const invalidResponse = { data: [], count: 10 };
      mockFetch.mockImplementation(() => createFetchResponse(invalidResponse));

      const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await flushPromises();
      });
      await act(async () => {
        jest.advanceTimersByTime(200);
        await flushPromises();
      });
      await act(async () => {
        jest.advanceTimersByTime(400);
        await flushPromises();
      });

      await waitFor(() => expect(result.current.error).not.toBeNull());
      expect(result.current.error!.message).toBe('Invalid API response shape');
    });
  });

  // ── Cleanup on Unmount ──
  describe('cleanup on unmount', () => {
    it('clears debounce timer on unmount before it fires', () => {
      const { unmount } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      act(() => { jest.advanceTimersByTime(100); });

      unmount();

      act(() => { jest.advanceTimersByTime(300); });

      expect(mockFetch).not.toHaveBeenCalled();
    });

    it('does not update state after unmount', async () => {
      const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation();

      let resolveResponse!: (value: unknown) => void;
      mockFetch.mockImplementation(() => new Promise((r) => { resolveResponse = r; }));

      const { unmount } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await flushPromises();
      });

      unmount();

      await act(async () => {
        resolveResponse({
          ok: true,
          status: 200,
          json: () => Promise.resolve(MOCK_RESPONSE_PAGE1),
        });
        await flushPromises();
      });

      const stateUpdateWarnings = consoleErrorSpy.mock.calls.filter((call) =>
        String(call[0]).includes('unmounted'),
      );
      expect(stateUpdateWarnings).toHaveLength(0);

      consoleErrorSpy.mockRestore();
    });
  });

  // ── Empty Query ──
  describe('empty query', () => {
    it('clears products and resets state when query becomes empty', async () => {
      mockFetch.mockImplementation(() => createFetchResponse(MOCK_RESPONSE_PAGE1));

      const { result, rerender } = renderHook(
        ({ query }: { query: string }) => useSearchProducts(query),
        { initialProps: { query: SEARCH_QUERY } },
      );

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await flushPromises();
      });
      await waitFor(() => expect(result.current.products).toHaveLength(2));

      rerender({ query: EMPTY_QUERY });

      expect(result.current.products).toEqual([]);
      expect(result.current.total).toBe(0);
      expect(result.current.error).toBeNull();
    });
  });
});
