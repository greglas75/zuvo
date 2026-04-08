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

// ── Mock Setup ──
let mockFetch: jest.SpyInstance;

function createFetchResponse(data: unknown, ok = true, status = 200) {
  return Promise.resolve({
    ok,
    status,
    statusText: ok ? 'OK' : 'Internal Server Error',
    json: () => Promise.resolve(data),
  });
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

      // Advance time but NOT past debounce
      act(() => { jest.advanceTimersByTime(299); });

      expect(mockFetch).not.toHaveBeenCalled();
    });

    it('calls fetch after 300ms debounce elapses', async () => {
      renderHook(() => useSearchProducts(SEARCH_QUERY));

      await act(async () => { jest.advanceTimersByTime(DEBOUNCE_MS); });

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

      // Still within debounce of second query — no fetch yet
      expect(mockFetch).not.toHaveBeenCalled();

      await act(async () => { jest.advanceTimersByTime(100); });

      // Now 300ms after second query change
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

      // Let first query fire
      await act(async () => { jest.advanceTimersByTime(DEBOUNCE_MS); });
      expect(mockFetch).toHaveBeenCalledTimes(1);

      // Change query — should abort previous
      rerender({ query: 'phone' });
      await act(async () => { jest.advanceTimersByTime(DEBOUNCE_MS); });

      expect(abortSpy).toHaveBeenCalled();
      abortSpy.mockRestore();
    });

    it('aborts in-flight request on unmount', async () => {
      const abortSpy = jest.spyOn(AbortController.prototype, 'abort');

      const { unmount } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      await act(async () => { jest.advanceTimersByTime(DEBOUNCE_MS); });

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

      // Initial search
      await act(async () => { jest.advanceTimersByTime(DEBOUNCE_MS); });
      await waitFor(() => expect(result.current.products).toHaveLength(2));

      expect(result.current.hasMore).toBe(true);

      // Load more
      await act(async () => { result.current.loadMore(); });
      await waitFor(() => expect(result.current.products).toHaveLength(3));

      // Verify both pages' products are present
      expect(result.current.products[0]).toEqual(MOCK_PRODUCT_1);
      expect(result.current.products[1]).toEqual(MOCK_PRODUCT_2);
      expect(result.current.products[2]).toEqual(MOCK_PRODUCT_PAGE2);
    });

    it('hasMore is false when all products are loaded', async () => {
      const allLoadedResponse = { ...MOCK_RESPONSE_PAGE1, total: 2 };
      mockFetch.mockImplementation(() => createFetchResponse(allLoadedResponse));

      const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      await act(async () => { jest.advanceTimersByTime(DEBOUNCE_MS); });
      await waitFor(() => expect(result.current.products).toHaveLength(2));

      expect(result.current.hasMore).toBe(false);
    });

    it('loadMore does not fire when already loading', async () => {
      // Make fetch hang (never resolve) to keep loading state
      mockFetch.mockImplementation(() => new Promise(() => {}));

      const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      await act(async () => { jest.advanceTimersByTime(DEBOUNCE_MS); });

      // isLoading should be true, loadMore should be a no-op
      act(() => { result.current.loadMore(); });

      // Only the initial fetch should have been called
      expect(mockFetch).toHaveBeenCalledTimes(1);
    });
  });

  // ── Loading States ──
  describe('loading states', () => {
    it('sets isLoading for initial search, not isLoadingMore', async () => {
      let resolveFirst!: (value: unknown) => void;
      mockFetch.mockImplementationOnce(() => new Promise((r) => { resolveFirst = r; }));

      const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      await act(async () => { jest.advanceTimersByTime(DEBOUNCE_MS); });

      expect(result.current.isLoading).toBe(true);
      expect(result.current.isLoadingMore).toBe(false);

      await act(async () => {
        resolveFirst({
          ok: true,
          status: 200,
          json: () => Promise.resolve(MOCK_RESPONSE_PAGE1),
        });
      });

      expect(result.current.isLoading).toBe(false);
    });

    it('sets isLoadingMore for loadMore, not isLoading', async () => {
      mockFetch.mockImplementationOnce(() => createFetchResponse(MOCK_RESPONSE_PAGE1));

      const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      await act(async () => { jest.advanceTimersByTime(DEBOUNCE_MS); });
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
      });

      expect(result.current.isLoadingMore).toBe(false);
    });
  });

  // ── Retry ──
  describe('retry', () => {
    it('retries up to 3 times with exponential backoff on failure', async () => {
      mockFetch
        .mockImplementationOnce(() => createFetchResponse(null, false, 500))
        .mockImplementationOnce(() => createFetchResponse(null, false, 500))
        .mockImplementationOnce(() => createFetchResponse(MOCK_RESPONSE_PAGE1));

      const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      await act(async () => { jest.advanceTimersByTime(DEBOUNCE_MS); });

      // First retry after 200ms backoff
      await act(async () => { jest.advanceTimersByTime(200); });
      // Second retry after 400ms backoff
      await act(async () => { jest.advanceTimersByTime(400); });

      await waitFor(() => expect(result.current.isLoading).toBe(false));

      expect(mockFetch).toHaveBeenCalledTimes(3);
      expect(result.current.error).toBeNull();
      expect(result.current.products).toHaveLength(2);
    });

    it('sets error after exhausting all 3 retry attempts', async () => {
      mockFetch.mockImplementation(() => createFetchResponse(null, false, 500));

      const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      await act(async () => { jest.advanceTimersByTime(DEBOUNCE_MS); });
      // Backoff: 200ms + 400ms
      await act(async () => { jest.advanceTimersByTime(200); });
      await act(async () => { jest.advanceTimersByTime(400); });

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
      await act(async () => { jest.advanceTimersByTime(DEBOUNCE_MS); });
      await waitFor(() => expect(result.current.products).toHaveLength(2));

      // Trigger error
      mockFetch.mockImplementation(() => createFetchResponse(null, false, 500));
      // Manually retry
      await act(async () => { result.current.retry(); });
      // Exhaust retries
      await act(async () => { jest.advanceTimersByTime(200); });
      await act(async () => { jest.advanceTimersByTime(400); });
      await waitFor(() => expect(result.current.error).not.toBeNull());

      // Now retry succeeds
      mockFetch.mockImplementation(() => createFetchResponse(MOCK_RESPONSE_PAGE1));
      await act(async () => { result.current.retry(); });
      await waitFor(() => expect(result.current.error).toBeNull());
    });
  });

  // ── Response Validation ──
  describe('response validation', () => {
    it('sets error when API returns invalid response shape', async () => {
      const invalidResponse = { data: [], count: 10 }; // wrong shape
      mockFetch.mockImplementation(() => createFetchResponse(invalidResponse));

      const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      await act(async () => { jest.advanceTimersByTime(DEBOUNCE_MS); });
      // Exhaust retries
      await act(async () => { jest.advanceTimersByTime(200); });
      await act(async () => { jest.advanceTimersByTime(400); });

      await waitFor(() => expect(result.current.error).not.toBeNull());
      expect(result.current.error!.message).toBe('Invalid API response shape');
    });
  });

  // ── Cleanup on Unmount ──
  describe('cleanup on unmount', () => {
    it('clears debounce timer on unmount before it fires', () => {
      const { unmount } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      // Timer is scheduled but not yet fired
      act(() => { jest.advanceTimersByTime(100); });

      unmount();

      // Advance past debounce — should NOT trigger fetch
      act(() => { jest.advanceTimersByTime(300); });

      expect(mockFetch).not.toHaveBeenCalled();
    });

    it('does not update state after unmount', async () => {
      const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation();

      let resolveResponse!: (value: unknown) => void;
      mockFetch.mockImplementation(() => new Promise((r) => { resolveResponse = r; }));

      const { result, unmount } = renderHook(() => useSearchProducts(SEARCH_QUERY));

      await act(async () => { jest.advanceTimersByTime(DEBOUNCE_MS); });

      unmount();

      // Resolve after unmount — should not cause state update warning
      await act(async () => {
        resolveResponse({
          ok: true,
          status: 200,
          json: () => Promise.resolve(MOCK_RESPONSE_PAGE1),
        });
      });

      // No React "can't perform state update on unmounted" warnings
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

      await act(async () => { jest.advanceTimersByTime(DEBOUNCE_MS); });
      await waitFor(() => expect(result.current.products).toHaveLength(2));

      rerender({ query: EMPTY_QUERY });

      expect(result.current.products).toEqual([]);
      expect(result.current.total).toBe(0);
      expect(result.current.error).toBeNull();
    });
  });
});
