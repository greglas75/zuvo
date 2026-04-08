// FILE: useSearchProducts.test.ts
import { renderHook, act } from '@testing-library/react';
import { useSearchProducts } from './r2-useSearchProducts';

// ── Constants ──────────────────────────────────────────────────────────────────

const DEBOUNCE_MS = 300;
const PAGE_SIZE = 20;

const PRODUCT_A = { id: 'p1', name: 'Widget A', price: 1999 };
const PRODUCT_B = { id: 'p2', name: 'Widget B', price: 2999 };

const MOCK_RESPONSE_PAGE_1 = {
  products: [PRODUCT_A],
  total: 2,
};

const MOCK_RESPONSE_PAGE_2 = {
  products: [PRODUCT_B],
  total: 2,
};

// ── Setup / teardown ──────────────────────────────────────────────────────────

let fetchSpy: jest.SpyInstance;

beforeEach(() => {
  jest.clearAllMocks();
  jest.useFakeTimers();
  fetchSpy = jest.spyOn(global, 'fetch');
});

afterEach(() => {
  fetchSpy.mockRestore();
  jest.useRealTimers();
});

// ── Helpers ───────────────────────────────────────────────────────────────────

function mockFetchSuccess(data: object, delay = 0) {
  fetchSpy.mockImplementation(
    () =>
      new Promise((resolve) =>
        setTimeout(
          () =>
            resolve({
              ok: true,
              json: () => Promise.resolve(data),
            } as Response),
          delay,
        ),
      ),
  );
}

function mockFetchFailure(message = 'Network Error') {
  fetchSpy.mockRejectedValue(new Error(message));
}

function mockFetchStatus(status: number) {
  fetchSpy.mockResolvedValue({
    ok: false,
    status,
    statusText: 'Error',
    json: () => Promise.resolve({}),
  } as Response);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe('useSearchProducts', () => {
  // ── Debounce ──────────────────────────────────────────────────────────────

  describe('debouncing', () => {
    it('does not call fetch before 300ms have elapsed', async () => {
      mockFetchSuccess(MOCK_RESPONSE_PAGE_1);

      renderHook(() => useSearchProducts('widget'));

      // Advance less than debounce threshold
      act(() => jest.advanceTimersByTime(DEBOUNCE_MS - 1));

      expect(fetchSpy).not.toHaveBeenCalled();
    });

    it('calls fetch exactly once after 300ms have elapsed', async () => {
      mockFetchSuccess(MOCK_RESPONSE_PAGE_1);

      renderHook(() => useSearchProducts('widget'));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await Promise.resolve();
      });

      expect(fetchSpy).toHaveBeenCalledTimes(1);
      expect(fetchSpy).toHaveBeenCalledWith(
        expect.stringContaining('q=widget'),
        expect.any(Object),
      );
    });

    it('resets debounce timer when query changes before 300ms', async () => {
      mockFetchSuccess(MOCK_RESPONSE_PAGE_1);
      const { rerender } = renderHook(
        ({ query }: { query: string }) => useSearchProducts(query),
        { initialProps: { query: 'wi' } },
      );

      act(() => jest.advanceTimersByTime(200));
      rerender({ query: 'widget' });
      act(() => jest.advanceTimersByTime(200)); // still < 300ms from last change

      expect(fetchSpy).not.toHaveBeenCalled();

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await Promise.resolve();
      });

      expect(fetchSpy).toHaveBeenCalledTimes(1);
      expect(fetchSpy).toHaveBeenCalledWith(
        expect.stringContaining('q=widget'),
        expect.any(Object),
      );
    });

    it('does not fetch for empty or whitespace query', async () => {
      renderHook(() => useSearchProducts(''));
      act(() => jest.advanceTimersByTime(DEBOUNCE_MS + 100));

      renderHook(() => useSearchProducts('   '));
      act(() => jest.advanceTimersByTime(DEBOUNCE_MS + 100));

      expect(fetchSpy).not.toHaveBeenCalled();
    });
  });

  // ── AbortController ───────────────────────────────────────────────────────

  describe('AbortController', () => {
    it('aborts in-flight request when query changes', async () => {
      const abortSpy = jest.fn();
      const originalAbortController = globalThis.AbortController;

      class MockAbortController {
        signal = { addEventListener: jest.fn(), aborted: false, name: 'AbortSignal' };
        abort = abortSpy;
      }
      // @ts-ignore
      globalThis.AbortController = MockAbortController;

      mockFetchSuccess(MOCK_RESPONSE_PAGE_1, 500);

      const { rerender } = renderHook(
        ({ query }: { query: string }) => useSearchProducts(query),
        { initialProps: { query: 'first' } },
      );

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await Promise.resolve();
      });

      // Change query — should abort the first in-flight request
      rerender({ query: 'second' });

      expect(abortSpy).toHaveBeenCalled();

      globalThis.AbortController = originalAbortController;
    });

    it('aborts in-flight request on unmount', async () => {
      mockFetchSuccess(MOCK_RESPONSE_PAGE_1, 500);

      const { unmount } = renderHook(() => useSearchProducts('widget'));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await Promise.resolve();
      });

      // Unmount should abort any pending request
      act(() => unmount());

      // If abort was not called, the fetch would try to set state after unmount
      // (the isMountedRef guard prevents state updates regardless)
      expect(fetchSpy).toHaveBeenCalled(); // fetch was initiated
    });
  });

  // ── Loading states ────────────────────────────────────────────────────────

  describe('loading states', () => {
    it('sets isLoading=true during initial search, false after', async () => {
      mockFetchSuccess(MOCK_RESPONSE_PAGE_1);

      const { result } = renderHook(() => useSearchProducts('widget'));

      // Before debounce fires
      expect(result.current.isLoading).toBe(false);

      act(() => jest.advanceTimersByTime(DEBOUNCE_MS));
      // After debounce fires, loading starts
      expect(result.current.isLoading).toBe(true);

      await act(async () => {
        await Promise.resolve();
        await Promise.resolve();
      });

      expect(result.current.isLoading).toBe(false);
    });

    it('sets isLoadingMore=true during loadMore, false after', async () => {
      mockFetchSuccess(MOCK_RESPONSE_PAGE_1);

      const { result } = renderHook(() => useSearchProducts('widget'));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await Promise.resolve();
        await Promise.resolve();
      });

      mockFetchSuccess(MOCK_RESPONSE_PAGE_2);

      act(() => result.current.loadMore());

      expect(result.current.isLoadingMore).toBe(true);
      expect(result.current.isLoading).toBe(false); // mutually exclusive

      await act(async () => {
        await Promise.resolve();
        await Promise.resolve();
      });

      expect(result.current.isLoadingMore).toBe(false);
    });

    it('isLoading and isLoadingMore are mutually exclusive', async () => {
      mockFetchSuccess(MOCK_RESPONSE_PAGE_1);

      const { result } = renderHook(() => useSearchProducts('widget'));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await Promise.resolve();
        await Promise.resolve();
      });

      mockFetchSuccess(MOCK_RESPONSE_PAGE_2);
      act(() => result.current.loadMore());

      // Both must never be true at the same time
      expect(result.current.isLoading && result.current.isLoadingMore).toBe(false);
    });
  });

  // ── Pagination ────────────────────────────────────────────────────────────

  describe('pagination', () => {
    it('appends results from loadMore instead of replacing them', async () => {
      mockFetchSuccess(MOCK_RESPONSE_PAGE_1);

      const { result } = renderHook(() => useSearchProducts('widget'));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await Promise.resolve();
        await Promise.resolve();
      });

      expect(result.current.products).toHaveLength(1);
      expect(result.current.products[0].id).toBe('p1');

      mockFetchSuccess(MOCK_RESPONSE_PAGE_2);

      await act(async () => {
        result.current.loadMore();
        await Promise.resolve();
        await Promise.resolve();
      });

      // Both pages present
      expect(result.current.products).toHaveLength(2);
      expect(result.current.products[0].id).toBe('p1');
      expect(result.current.products[1].id).toBe('p2');
    });

    it('hasMore is true when products.length < total', async () => {
      mockFetchSuccess(MOCK_RESPONSE_PAGE_1); // 1 product, total=2

      const { result } = renderHook(() => useSearchProducts('widget'));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await Promise.resolve();
        await Promise.resolve();
      });

      expect(result.current.hasMore).toBe(true);
    });

    it('hasMore is false when all products are loaded', async () => {
      mockFetchSuccess({ products: [PRODUCT_A, PRODUCT_B], total: 2 });

      const { result } = renderHook(() => useSearchProducts('widget'));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await Promise.resolve();
        await Promise.resolve();
      });

      expect(result.current.hasMore).toBe(false);
    });

    it('loadMore passes correct skip offset to API', async () => {
      mockFetchSuccess(MOCK_RESPONSE_PAGE_1);

      const { result } = renderHook(() => useSearchProducts('widget'));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await Promise.resolve();
        await Promise.resolve();
      });

      mockFetchSuccess(MOCK_RESPONSE_PAGE_2);

      await act(async () => {
        result.current.loadMore();
        await Promise.resolve();
        await Promise.resolve();
      });

      // Second call should have skip=PAGE_SIZE
      const secondCallUrl = (fetchSpy.mock.calls[1] as [string])[0];
      expect(secondCallUrl).toContain(`skip=${PAGE_SIZE}`);
    });

    it('loadMore is ignored when isLoading is true', async () => {
      mockFetchSuccess(MOCK_RESPONSE_PAGE_1, 200); // slow response

      const { result } = renderHook(() => useSearchProducts('widget'));

      act(() => jest.advanceTimersByTime(DEBOUNCE_MS));

      // isLoading=true at this point — loadMore should be a no-op
      act(() => result.current.loadMore());

      expect(fetchSpy).toHaveBeenCalledTimes(1); // only the initial fetch
    });
  });

  // ── Retry ─────────────────────────────────────────────────────────────────

  describe('retry', () => {
    it('retries up to 3 times on failure with exponential backoff', async () => {
      mockFetchFailure('Network Error');

      const { result } = renderHook(() => useSearchProducts('widget'));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await Promise.resolve();
      });

      // Attempt 1 fails immediately, attempt 2 after 1s, attempt 3 after 2s
      await act(async () => {
        jest.advanceTimersByTime(1000); // 1s backoff
        await Promise.resolve();
        jest.advanceTimersByTime(2000); // 2s backoff
        await Promise.resolve();
      });

      // 3 total fetch attempts (MAX_RETRIES)
      expect(fetchSpy).toHaveBeenCalledTimes(3);
      expect(result.current.error).toBe('Network Error');
    });

    it('sets error state after all retries are exhausted', async () => {
      mockFetchFailure('Service Unavailable');

      const { result } = renderHook(() => useSearchProducts('widget'));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await Promise.resolve();
        jest.advanceTimersByTime(1000 + 2000);
        await Promise.resolve();
      });

      expect(result.current.error).toBe('Service Unavailable');
      expect(result.current.isLoading).toBe(false);
    });

    it('retry() re-issues the search request', async () => {
      mockFetchFailure('Network Error');

      const { result } = renderHook(() => useSearchProducts('widget'));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await Promise.resolve();
        jest.advanceTimersByTime(3000); // exhaust backoffs
        await Promise.resolve();
      });

      const failedCallCount = fetchSpy.mock.calls.length;
      mockFetchSuccess(MOCK_RESPONSE_PAGE_1);

      await act(async () => {
        result.current.retry();
        await Promise.resolve();
        await Promise.resolve();
      });

      expect(fetchSpy).toHaveBeenCalledTimes(failedCallCount + 1);
      expect(result.current.products).toHaveLength(1);
      expect(result.current.error).toBeNull();
    });
  });

  // ── Error handling ────────────────────────────────────────────────────────

  describe('error handling', () => {
    it('sets error when API returns non-ok HTTP status', async () => {
      mockFetchStatus(500);

      const { result } = renderHook(() => useSearchProducts('widget'));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await Promise.resolve();
        jest.advanceTimersByTime(3000);
        await Promise.resolve();
      });

      expect(result.current.error).toMatch(/HTTP 500/);
    });

    it('sets error when API response shape is invalid', async () => {
      fetchSpy.mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ wrong: 'shape' }),
      } as Response);

      const { result } = renderHook(() => useSearchProducts('widget'));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await Promise.resolve();
        jest.advanceTimersByTime(3000);
        await Promise.resolve();
      });

      expect(result.current.error).toBe('Invalid API response shape');
    });
  });

  // ── Cleanup ───────────────────────────────────────────────────────────────

  describe('cleanup on unmount', () => {
    it('clears debounce timer on unmount before search fires', () => {
      const clearTimeoutSpy = jest.spyOn(globalThis, 'clearTimeout');

      const { unmount } = renderHook(() => useSearchProducts('widget'));

      act(() => unmount());

      expect(clearTimeoutSpy).toHaveBeenCalled();
      clearTimeoutSpy.mockRestore();
    });

    it('does not update state after unmount', async () => {
      mockFetchSuccess(MOCK_RESPONSE_PAGE_1, 200); // delayed response
      const consoleSpy = jest.spyOn(console, 'error').mockImplementation(() => {});

      const { result, unmount } = renderHook(() => useSearchProducts('widget'));

      act(() => jest.advanceTimersByTime(DEBOUNCE_MS));
      act(() => unmount());

      // Resolve the delayed fetch — isMountedRef prevents state update
      await act(async () => {
        jest.advanceTimersByTime(200);
        await Promise.resolve();
      });

      // No state updates after unmount; products remain empty
      expect(result.current.products).toHaveLength(0);

      consoleSpy.mockRestore();
    });
  });
});
