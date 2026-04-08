// FILE: useSearchProducts.test.ts
import { renderHook, act } from '@testing-library/react';
import { useSearchProducts } from './r2-useSearchProducts';

// ── Constants ──────────────────────────────────────────────────────────────────

const DEBOUNCE_MS = 300;
const PAGE_SIZE = 20;
const BACKOFF_1S = 1000;
const BACKOFF_2S = 2000;

const PRODUCT_A = { id: 'p1', name: 'Widget A', price: 1999 };
const PRODUCT_B = { id: 'p2', name: 'Widget B', price: 2999 };

const MOCK_RESPONSE_PAGE_1 = { products: [PRODUCT_A], total: 2 };
const MOCK_RESPONSE_PAGE_2 = { products: [PRODUCT_B], total: 2 };

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

function mockFetchSuccess(data: object, delayMs = 0) {
  fetchSpy.mockImplementation(
    () =>
      new Promise((resolve) =>
        setTimeout(
          () =>
            resolve({
              ok: true,
              json: () => Promise.resolve(data),
            } as Response),
          delayMs,
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
    statusText: 'Server Error',
    json: () => Promise.resolve({}),
  } as Response);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe('useSearchProducts', () => {
  // ── Debounce ──────────────────────────────────────────────────────────────

  describe('debouncing', () => {
    it('does not call fetch before 300ms have elapsed', () => {
      mockFetchSuccess(MOCK_RESPONSE_PAGE_1);

      renderHook(() => useSearchProducts('widget'));

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

    it('does not fetch for empty or whitespace-only query', () => {
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
      let capturedAbortController: { abort: jest.Mock } | null = null;

      const OriginalAbortController = globalThis.AbortController;
      class MockAbortController {
        signal = {
          addEventListener: jest.fn(),
          removeEventListener: jest.fn(),
          aborted: false,
        };
        abort = abortSpy;
        constructor() {
          capturedAbortController = this;
        }
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

      // Changing the query should trigger abort on the in-flight controller
      rerender({ query: 'second' });

      expect(abortSpy).toHaveBeenCalled();

      globalThis.AbortController = OriginalAbortController;
    });

    it('aborts in-flight request on unmount', async () => {
      const abortSpy = jest.fn();
      const OriginalAbortController = globalThis.AbortController;
      class MockAbortController {
        signal = { addEventListener: jest.fn(), removeEventListener: jest.fn(), aborted: false };
        abort = abortSpy;
      }
      // @ts-ignore
      globalThis.AbortController = MockAbortController;

      mockFetchSuccess(MOCK_RESPONSE_PAGE_1, 500);

      const { unmount } = renderHook(() => useSearchProducts('widget'));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await Promise.resolve();
      });

      act(() => unmount());

      // Abort must be called to cancel the in-flight request
      expect(abortSpy).toHaveBeenCalled();

      globalThis.AbortController = OriginalAbortController;
    });
  });

  // ── Loading states ────────────────────────────────────────────────────────

  describe('loading states', () => {
    it('sets isLoading=true during initial search and false after completion', async () => {
      mockFetchSuccess(MOCK_RESPONSE_PAGE_1);

      const { result } = renderHook(() => useSearchProducts('widget'));

      expect(result.current.isLoading).toBe(false);

      act(() => jest.advanceTimersByTime(DEBOUNCE_MS));
      expect(result.current.isLoading).toBe(true);

      await act(async () => {
        await Promise.resolve();
        await Promise.resolve();
      });

      expect(result.current.isLoading).toBe(false);
    });

    it('sets isLoadingMore=true during loadMore and false after completion', async () => {
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
      expect(result.current.isLoading).toBe(false);

      await act(async () => {
        await Promise.resolve();
        await Promise.resolve();
      });

      expect(result.current.isLoadingMore).toBe(false);
    });

    it('isLoading and isLoadingMore are mutually exclusive: when isLoadingMore is true, isLoading is false', async () => {
      mockFetchSuccess(MOCK_RESPONSE_PAGE_1);

      const { result } = renderHook(() => useSearchProducts('widget'));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await Promise.resolve();
        await Promise.resolve();
      });

      mockFetchSuccess(MOCK_RESPONSE_PAGE_2);
      act(() => result.current.loadMore());

      // Explicit mutual exclusion: one is true, the other must be false
      expect(result.current.isLoadingMore).toBe(true);
      expect(result.current.isLoading).toBe(false);
    });
  });

  // ── Pagination ────────────────────────────────────────────────────────────

  describe('pagination', () => {
    it('appends results from loadMore without replacing existing products', async () => {
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

    it('hasMore is false when products.length equals total', async () => {
      mockFetchSuccess({ products: [PRODUCT_A, PRODUCT_B], total: 2 });

      const { result } = renderHook(() => useSearchProducts('widget'));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await Promise.resolve();
        await Promise.resolve();
      });

      expect(result.current.hasMore).toBe(false);
    });

    it('passes correct skip offset to API for second page', async () => {
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

      const secondCallUrl = (fetchSpy.mock.calls[1] as [string])[0];
      expect(secondCallUrl).toContain(`skip=${PAGE_SIZE}`);
    });

    it('loadMore is a no-op when isLoading is true', async () => {
      mockFetchSuccess(MOCK_RESPONSE_PAGE_1, 200); // slow

      const { result } = renderHook(() => useSearchProducts('widget'));

      act(() => jest.advanceTimersByTime(DEBOUNCE_MS));

      // isLoading=true — loadMore should be ignored
      act(() => result.current.loadMore());

      expect(fetchSpy).toHaveBeenCalledTimes(1);
    });
  });

  // ── Retry ─────────────────────────────────────────────────────────────────

  describe('retry', () => {
    it('retries up to 3 times on failure with exponential backoff delays', async () => {
      mockFetchFailure('Network Error');

      const { result } = renderHook(() => useSearchProducts('widget'));

      // Attempt 1: fires after debounce
      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await Promise.resolve();
      });

      // Attempt 2: fires after 1s backoff
      await act(async () => {
        jest.advanceTimersByTime(BACKOFF_1S);
        await Promise.resolve();
      });

      // Attempt 3: fires after 2s backoff
      await act(async () => {
        jest.advanceTimersByTime(BACKOFF_2S);
        await Promise.resolve();
      });

      expect(fetchSpy).toHaveBeenCalledTimes(3);
      expect(result.current.error).toBe('Network Error');
    });

    it('sets error state after all retries are exhausted', async () => {
      mockFetchFailure('Service Unavailable');

      const { result } = renderHook(() => useSearchProducts('widget'));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS + BACKOFF_1S + BACKOFF_2S + 100);
        await Promise.resolve();
        await Promise.resolve();
      });

      expect(result.current.error).toBe('Service Unavailable');
      expect(result.current.isLoading).toBe(false);
    });

    it('retry() re-issues the request and clears error on success', async () => {
      mockFetchFailure('Network Error');

      const { result } = renderHook(() => useSearchProducts('widget'));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS + BACKOFF_1S + BACKOFF_2S + 100);
        await Promise.resolve();
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

    it('aborts retry during backoff when unmounted', async () => {
      mockFetchFailure('Network Error');

      const { unmount } = renderHook(() => useSearchProducts('widget'));

      // Trigger first failed attempt
      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS);
        await Promise.resolve();
      });

      const callsAfterFirst = fetchSpy.mock.calls.length;

      // Unmount while in backoff period (before 2nd retry fires)
      act(() => unmount());

      // Advance through backoff — second retry should NOT fire
      await act(async () => {
        jest.advanceTimersByTime(BACKOFF_1S + BACKOFF_2S + 100);
        await Promise.resolve();
      });

      // No additional fetches after unmount
      expect(fetchSpy).toHaveBeenCalledTimes(callsAfterFirst);
    });
  });

  // ── Error handling ────────────────────────────────────────────────────────

  describe('error handling', () => {
    it('sets error message when API returns non-ok HTTP status', async () => {
      mockFetchStatus(500);

      const { result } = renderHook(() => useSearchProducts('widget'));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS + BACKOFF_1S + BACKOFF_2S + 100);
        await Promise.resolve();
        await Promise.resolve();
      });

      expect(result.current.error).toMatch(/HTTP 500/);
    });

    it('sets error when API response fails runtime validation', async () => {
      fetchSpy.mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ wrong: 'shape' }),
      } as Response);

      const { result } = renderHook(() => useSearchProducts('widget'));

      await act(async () => {
        jest.advanceTimersByTime(DEBOUNCE_MS + BACKOFF_1S + BACKOFF_2S + 100);
        await Promise.resolve();
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

    it('does not update state after unmount (no React state warning)', async () => {
      mockFetchSuccess(MOCK_RESPONSE_PAGE_1, 200); // delayed

      // Track console.error calls — React emits an error if setState is called post-unmount
      const consoleSpy = jest.spyOn(console, 'error').mockImplementation(() => {});

      const { result, unmount } = renderHook(() => useSearchProducts('widget'));

      act(() => jest.advanceTimersByTime(DEBOUNCE_MS));
      act(() => unmount());

      await act(async () => {
        jest.advanceTimersByTime(200);
        await Promise.resolve();
        await Promise.resolve();
      });

      // If isMountedRef guard is missing, React warns about setState on unmounted component
      expect(consoleSpy).not.toHaveBeenCalled();

      // Products remain empty — no state update after unmount
      expect(result.current.products).toHaveLength(0);

      consoleSpy.mockRestore();
    });
  });
});
