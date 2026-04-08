// FILE: useSearchProducts.test.ts
import { renderHook, act, waitFor } from '@testing-library/react';
import { useSearchProducts } from './r2-useSearchProducts';

// --- Test Constants ---

const PRODUCT_A = { id: 'prod-1', name: 'Widget A', price: 29.99, description: 'A widget', imageUrl: '/img/a.png' };
const PRODUCT_B = { id: 'prod-2', name: 'Widget B', price: 49.99, description: 'B widget', imageUrl: '/img/b.png' };
const PRODUCT_C = { id: 'prod-3', name: 'Widget C', price: 19.99, description: 'C widget', imageUrl: '/img/c.png' };

const PAGE_1_RESPONSE = {
  items: [PRODUCT_A, PRODUCT_B],
  total: 5,
  page: 0,
  pageSize: 20,
};

const PAGE_2_RESPONSE = {
  items: [PRODUCT_C],
  total: 5,
  page: 1,
  pageSize: 20,
};

const DEBOUNCE_MS = 300;

// --- Mock Setup ---

let mockFetch: jest.SpyInstance;

function mockFetchResponse(body: unknown, status = 200) {
  return Promise.resolve({
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(body),
  });
}

function mockFetchError(status: number) {
  return Promise.resolve({
    ok: false,
    status,
    json: () => Promise.resolve({}),
  });
}

beforeEach(() => {
  jest.useFakeTimers();
  jest.clearAllMocks();
  mockFetch = jest.spyOn(global, 'fetch').mockResolvedValue(
    mockFetchResponse(PAGE_1_RESPONSE) as any,
  );
});

afterEach(() => {
  jest.useRealTimers();
  mockFetch.mockRestore();
});

// --- Test Suite ---

describe('useSearchProducts', () => {
  // === Debounce ===

  describe('debounce', () => {
    it('does not call fetch before debounce period elapses', () => {
      renderHook(() => useSearchProducts('laptop'));

      expect(mockFetch).not.toHaveBeenCalled();
    });

    it('calls fetch after 300ms debounce with correct query parameter', async () => {
      renderHook(() => useSearchProducts('laptop'));

      act(() => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
      });

      await waitFor(() => {
        expect(mockFetch).toHaveBeenCalledTimes(1);
        expect(mockFetch).toHaveBeenCalledWith(
          expect.stringContaining('q=laptop'),
          expect.objectContaining({ signal: expect.any(AbortSignal) }),
        );
      });
    });

    it('resets debounce timer on query change within debounce period', async () => {
      const { rerender } = renderHook(
        ({ query }) => useSearchProducts(query),
        { initialProps: { query: 'lap' } },
      );

      act(() => {
        jest.advanceTimersByTime(200);
      });

      rerender({ query: 'laptop' });

      act(() => {
        jest.advanceTimersByTime(200);
      });

      expect(mockFetch).not.toHaveBeenCalled(); // only 200ms since last change

      act(() => {
        jest.advanceTimersByTime(100);
      });

      await waitFor(() => {
        expect(mockFetch).toHaveBeenCalledTimes(1);
        expect(mockFetch).toHaveBeenCalledWith(
          expect.stringContaining('q=laptop'),
          expect.any(Object),
        );
      });
    });
  });

  // === AbortController ===

  describe('AbortController', () => {
    it('aborts previous request when query changes and new request uses new query', async () => {
      let resolveFirst: (value: unknown) => void;
      const firstPromise = new Promise((resolve) => { resolveFirst = resolve; });

      mockFetch
        .mockReturnValueOnce(firstPromise)
        .mockResolvedValueOnce(mockFetchResponse({
          items: [PRODUCT_C],
          total: 1,
          page: 0,
          pageSize: 20,
        }));

      const { result, rerender } = renderHook(
        ({ query }) => useSearchProducts(query),
        { initialProps: { query: 'phone' } },
      );

      act(() => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
      });

      await waitFor(() => {
        expect(mockFetch).toHaveBeenCalledTimes(1);
        expect(mockFetch).toHaveBeenCalledWith(
          expect.stringContaining('q=phone'),
          expect.any(Object),
        );
      });

      // Capture the signal from the first fetch
      const firstSignal = mockFetch.mock.calls[0][1].signal;

      // Change query
      rerender({ query: 'tablet' });

      act(() => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
      });

      // First signal should be aborted
      expect(firstSignal.aborted).toBe(true);

      // Second fetch should use new query
      await waitFor(() => {
        expect(mockFetch).toHaveBeenCalledTimes(2);
        expect(mockFetch.mock.calls[1][0]).toContain('q=tablet');
      });

      // Resolve the stale first request — should NOT update state
      resolveFirst!(mockFetchResponse(PAGE_1_RESPONSE));

      await waitFor(() => {
        // Only the tablet result should be displayed
        expect(result.current.products).toEqual([PRODUCT_C]);
      });
    });

    it('aborts in-flight request on unmount', async () => {
      const { unmount } = renderHook(() => useSearchProducts('phone'));

      act(() => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
      });

      await waitFor(() => {
        expect(mockFetch).toHaveBeenCalledTimes(1);
      });

      const signal = mockFetch.mock.calls[0][1].signal;

      unmount();

      expect(signal.aborted).toBe(true);
    });
  });

  // === Loading States ===

  describe('loading states', () => {
    it('sets isLoading true during initial search', async () => {
      let resolvePromise: (value: unknown) => void;
      mockFetch.mockReturnValue(
        new Promise((resolve) => {
          resolvePromise = resolve;
        }),
      );

      const { result } = renderHook(() => useSearchProducts('phone'));

      act(() => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
      });

      await waitFor(() => {
        expect(result.current.isLoading).toBe(true);
        expect(result.current.isLoadingMore).toBe(false);
      });

      await act(async () => {
        resolvePromise!(mockFetchResponse(PAGE_1_RESPONSE));
      });

      await waitFor(() => {
        expect(result.current.isLoading).toBe(false);
      });
    });

    it('sets isLoadingMore true during loadMore, not isLoading', async () => {
      mockFetch
        .mockResolvedValueOnce(mockFetchResponse(PAGE_1_RESPONSE))
        .mockReturnValueOnce(new Promise(() => {})); // hang on second call

      const { result } = renderHook(() => useSearchProducts('phone'));

      act(() => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
      });

      await waitFor(() => {
        expect(result.current.products).toHaveLength(2);
      });

      act(() => {
        result.current.loadMore();
      });

      await waitFor(() => {
        expect(result.current.isLoadingMore).toBe(true);
        expect(result.current.isLoading).toBe(false);
      });
    });
  });

  // === Pagination ===

  describe('pagination', () => {
    it('appends results on loadMore and sends correct page parameter', async () => {
      mockFetch
        .mockResolvedValueOnce(mockFetchResponse(PAGE_1_RESPONSE))
        .mockResolvedValueOnce(mockFetchResponse(PAGE_2_RESPONSE));

      const { result } = renderHook(() => useSearchProducts('widget'));

      act(() => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
      });

      await waitFor(() => {
        expect(result.current.products).toHaveLength(2);
      });

      expect(result.current.hasMore).toBe(true);

      await act(async () => {
        result.current.loadMore();
      });

      await waitFor(() => {
        expect(result.current.products).toHaveLength(3);
        expect(result.current.products[0]).toEqual(PRODUCT_A);
        expect(result.current.products[2]).toEqual(PRODUCT_C);
      });

      // Verify the second fetch used page=1
      expect(mockFetch.mock.calls[1][0]).toContain('page=1');
    });

    it('sets hasMore to false when all results loaded', async () => {
      const fullResponse = { items: [PRODUCT_A], total: 1, page: 0, pageSize: 20 };
      mockFetch.mockResolvedValue(mockFetchResponse(fullResponse));

      const { result } = renderHook(() => useSearchProducts('widget'));

      act(() => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
      });

      await waitFor(() => {
        expect(result.current.hasMore).toBe(false);
      });
    });

    it('does not fire loadMore when query is pending debounce (query race protection)', async () => {
      mockFetch.mockResolvedValueOnce(mockFetchResponse(PAGE_1_RESPONSE));

      const { result, rerender } = renderHook(
        ({ query }) => useSearchProducts(query),
        { initialProps: { query: 'phone' } },
      );

      act(() => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
      });

      await waitFor(() => {
        expect(result.current.products).toHaveLength(2);
      });

      // Change query — loadMore should be blocked until search completes
      rerender({ query: 'tablet' });

      act(() => {
        result.current.loadMore();
      });

      // Only the initial fetch should have been called
      expect(mockFetch).toHaveBeenCalledTimes(1);
    });
  });

  // === Retry ===

  describe('retry', () => {
    it('retries on 5xx errors with exponential backoff up to 3 attempts', async () => {
      mockFetch
        .mockResolvedValueOnce(mockFetchError(500))
        .mockResolvedValueOnce(mockFetchError(502))
        .mockResolvedValueOnce(mockFetchError(503))
        .mockResolvedValueOnce(mockFetchError(500)); // 4th attempt = final failure

      const { result } = renderHook(() => useSearchProducts('phone'));

      act(() => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
      });

      // Advance through backoff timers: 1000ms, 2000ms, 4000ms
      await act(async () => {
        jest.advanceTimersByTime(1000);
      });
      await act(async () => {
        jest.advanceTimersByTime(2000);
      });
      await act(async () => {
        jest.advanceTimersByTime(4000);
      });

      await waitFor(() => {
        expect(result.current.error).not.toBeNull();
        expect(result.current.error!.message).toBe('Search failed with status 500');
      });

      // 1 original + 3 retries = 4 total calls
      expect(mockFetch).toHaveBeenCalledTimes(4);
    });

    it('retries on 429 (rate limit) and succeeds', async () => {
      mockFetch
        .mockResolvedValueOnce(mockFetchError(429))
        .mockResolvedValueOnce(mockFetchResponse(PAGE_1_RESPONSE));

      const { result } = renderHook(() => useSearchProducts('phone'));

      act(() => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
      });

      await act(async () => {
        jest.advanceTimersByTime(1000);
      });

      await waitFor(() => {
        expect(result.current.products).toHaveLength(2);
        expect(result.current.error).toBeNull();
      });
    });

    it('does not retry on 4xx errors (except 429)', async () => {
      mockFetch.mockResolvedValue(mockFetchError(400));

      const { result } = renderHook(() => useSearchProducts('phone'));

      act(() => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
      });

      await waitFor(() => {
        expect(result.current.error).not.toBeNull();
        expect(result.current.error!.message).toBe('Search failed with status 400');
      });

      expect(mockFetch).toHaveBeenCalledTimes(1); // no retry
    });

    it('does not retry on 404', async () => {
      mockFetch.mockResolvedValue(mockFetchError(404));

      const { result } = renderHook(() => useSearchProducts('phone'));

      act(() => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
      });

      await waitFor(() => {
        expect(result.current.error!.message).toBe('Search failed with status 404');
      });

      expect(mockFetch).toHaveBeenCalledTimes(1);
    });

    it('retry() function re-executes the search from scratch', async () => {
      mockFetch
        .mockResolvedValueOnce(mockFetchError(400))
        .mockResolvedValueOnce(mockFetchResponse(PAGE_1_RESPONSE));

      const { result } = renderHook(() => useSearchProducts('phone'));

      act(() => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
      });

      await waitFor(() => {
        expect(result.current.error).not.toBeNull();
      });

      await act(async () => {
        result.current.retry();
      });

      await waitFor(() => {
        expect(result.current.products).toHaveLength(2);
        expect(result.current.error).toBeNull();
        expect(result.current.isLoading).toBe(false);
      });
    });
  });

  // === Response Validation ===

  describe('response validation', () => {
    it('filters out malformed products and adjusts total', async () => {
      const consoleSpy = jest.spyOn(console, 'warn').mockImplementation();
      const responseWithBadItems = {
        items: [
          PRODUCT_A,
          { id: 123, name: 'Bad', price: 'not-a-number' }, // invalid
          PRODUCT_B,
        ],
        total: 10,
        page: 0,
        pageSize: 20,
      };
      mockFetch.mockResolvedValue(mockFetchResponse(responseWithBadItems));

      const { result } = renderHook(() => useSearchProducts('widget'));

      act(() => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
      });

      await waitFor(() => {
        expect(result.current.products).toHaveLength(2);
        expect(result.current.total).toBe(9); // adjusted: 10 - 1 invalid
      });

      expect(consoleSpy).toHaveBeenCalledWith(
        expect.stringContaining('1 malformed product'),
      );
      consoleSpy.mockRestore();
    });

    it('sets error on completely invalid response shape', async () => {
      mockFetch.mockResolvedValue(mockFetchResponse('not-an-object'));

      const { result } = renderHook(() => useSearchProducts('widget'));

      act(() => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
      });

      await waitFor(() => {
        expect(result.current.error).not.toBeNull();
        expect(result.current.error!.message).toContain('Invalid response');
      });
    });

    it('sets error when items field is not an array', async () => {
      mockFetch.mockResolvedValue(mockFetchResponse({ items: 'not-array', total: 5 }));

      const { result } = renderHook(() => useSearchProducts('widget'));

      act(() => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
      });

      await waitFor(() => {
        expect(result.current.error!.message).toContain('items must be an array');
      });
    });
  });

  // === Cleanup ===

  describe('cleanup on unmount', () => {
    it('clears debounce timer on unmount', () => {
      const clearTimeoutSpy = jest.spyOn(global, 'clearTimeout');

      const { unmount } = renderHook(() => useSearchProducts('phone'));

      unmount();

      expect(clearTimeoutSpy).toHaveBeenCalled();
      clearTimeoutSpy.mockRestore();
    });

    it('does not update state after unmount (mountedRef guard)', async () => {
      let resolvePromise: (value: unknown) => void;
      mockFetch.mockReturnValue(
        new Promise((resolve) => {
          resolvePromise = resolve;
        }),
      );

      const { result, unmount } = renderHook(() => useSearchProducts('phone'));

      act(() => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
      });

      unmount();

      // Resolve the fetch AFTER unmount — should not cause state update
      await act(async () => {
        resolvePromise!(mockFetchResponse(PAGE_1_RESPONSE));
      });

      expect(result.current.products).toHaveLength(0);
    });
  });

  // === Empty / Whitespace Query ===

  describe('empty and whitespace query', () => {
    it('clears products and does not fetch for empty string query', async () => {
      const { result } = renderHook(() => useSearchProducts(''));

      act(() => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
      });

      expect(result.current.products).toEqual([]);
      expect(result.current.total).toBe(0);
      expect(result.current.error).toBeNull();
      expect(mockFetch).not.toHaveBeenCalled();
    });

    it('clears products and does not fetch for whitespace-only query', async () => {
      const { result } = renderHook(() => useSearchProducts('   '));

      act(() => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
      });

      expect(result.current.products).toEqual([]);
      expect(result.current.total).toBe(0);
      expect(result.current.error).toBeNull();
      expect(mockFetch).not.toHaveBeenCalled();
    });
  });

  // === URL Encoding ===

  describe('URL encoding', () => {
    it('encodes special characters in query parameter', async () => {
      renderHook(() => useSearchProducts('a&b=c'));

      act(() => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
      });

      await waitFor(() => {
        expect(mockFetch).toHaveBeenCalledWith(
          expect.stringContaining('q=a%26b%3Dc'),
          expect.any(Object),
        );
      });
    });
  });
});
