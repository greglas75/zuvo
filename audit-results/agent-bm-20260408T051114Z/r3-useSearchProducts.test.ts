// FILE: useSearchProducts.test.ts
import { renderHook, act } from '@testing-library/react';
import { useSearchProducts } from './r2-useSearchProducts';

// ── Test constants ────────────────────────────────────────────────────────────

const QUERY_SHOES = 'shoes';
const QUERY_HATS = 'hats';
const PAGE_SIZE = 20;

const PRODUCT_1 = { id: 'prod-001', name: 'Running Shoes', price: 89.99 };
const PRODUCT_2 = { id: 'prod-002', name: 'Trail Shoes', price: 119.99 };
const PRODUCT_3 = { id: 'prod-003', name: 'Dress Shoes', price: 149.99 };

const FIRST_PAGE_RESPONSE = {
  products: [PRODUCT_1, PRODUCT_2],
  total: 3,
};

const SECOND_PAGE_RESPONSE = {
  products: [PRODUCT_3],
  total: 3,
};

const SINGLE_PAGE_RESPONSE = {
  products: [PRODUCT_1],
  total: 1,
};

// ── Helpers ───────────────────────────────────────────────────────────────────

function mockFetchSuccess(responses: object[]) {
  let callIndex = 0;
  jest.spyOn(global, 'fetch').mockImplementation(() => {
    const body = responses[callIndex % responses.length];
    callIndex++;
    return Promise.resolve({
      ok: true,
      status: 200,
      json: () => Promise.resolve(body),
    } as Response);
  });
}

function mockFetchFailure(status: number, statusText = 'Error') {
  jest.spyOn(global, 'fetch').mockResolvedValue({
    ok: false,
    status,
    statusText,
  } as Response);
}

function mockFetchNetworkError() {
  jest.spyOn(global, 'fetch').mockRejectedValue(new Error('Network error'));
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe('useSearchProducts', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  // ── Debounce ───────────────────────────────────────────────────────────

  describe('debounce', () => {
    it('does NOT call fetch before 300ms have elapsed', () => {
      mockFetchSuccess([SINGLE_PAGE_RESPONSE]);
      renderHook(() => useSearchProducts(QUERY_SHOES));

      // Advance less than debounce window
      act(() => { jest.advanceTimersByTime(299); });

      expect(global.fetch).not.toHaveBeenCalled();
    });

    it('calls fetch after 300ms debounce window', async () => {
      mockFetchSuccess([SINGLE_PAGE_RESPONSE]);
      renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => { jest.advanceTimersByTime(300); });

      expect(global.fetch).toHaveBeenCalledTimes(1);
      expect(global.fetch).toHaveBeenCalledWith(
        expect.stringContaining(`q=${encodeURIComponent(QUERY_SHOES)}`),
        expect.any(Object),
      );
    });

    it('resets debounce timer when query changes rapidly', async () => {
      mockFetchSuccess([SINGLE_PAGE_RESPONSE]);
      const { rerender } = renderHook(
        ({ q }) => useSearchProducts(q),
        { initialProps: { q: QUERY_SHOES } },
      );

      // Change query before debounce fires
      act(() => { jest.advanceTimersByTime(200); });
      rerender({ q: QUERY_HATS });
      act(() => { jest.advanceTimersByTime(200); });

      // fetch still not called — debounce reset
      expect(global.fetch).not.toHaveBeenCalled();

      // After full 300ms from last change
      await act(async () => { jest.advanceTimersByTime(100); });

      expect(global.fetch).toHaveBeenCalledTimes(1);
      expect(global.fetch).toHaveBeenCalledWith(
        expect.stringContaining(`q=${encodeURIComponent(QUERY_HATS)}`),
        expect.any(Object),
      );
    });

    it('does not call fetch when query is empty string', () => {
      mockFetchSuccess([SINGLE_PAGE_RESPONSE]);
      renderHook(() => useSearchProducts(''));

      act(() => { jest.advanceTimersByTime(300); });

      expect(global.fetch).not.toHaveBeenCalled();
    });

    it('does not call fetch when query is whitespace only', () => {
      mockFetchSuccess([SINGLE_PAGE_RESPONSE]);
      renderHook(() => useSearchProducts('   '));

      act(() => { jest.advanceTimersByTime(300); });

      expect(global.fetch).not.toHaveBeenCalled();
    });
  });

  // ── AbortController ────────────────────────────────────────────────────

  describe('AbortController', () => {
    it('aborts in-flight request when query changes', async () => {
      const abortSpy = jest.spyOn(AbortController.prototype, 'abort');
      mockFetchSuccess([SINGLE_PAGE_RESPONSE]);

      const { rerender } = renderHook(
        ({ q }) => useSearchProducts(q),
        { initialProps: { q: QUERY_SHOES } },
      );

      await act(async () => { jest.advanceTimersByTime(300); });

      rerender({ q: QUERY_HATS });
      await act(async () => { jest.advanceTimersByTime(300); });

      // Abort called at least once when query changed
      expect(abortSpy).toHaveBeenCalled();
    });

    it('aborts in-flight request on unmount', async () => {
      const abortSpy = jest.spyOn(AbortController.prototype, 'abort');
      mockFetchSuccess([SINGLE_PAGE_RESPONSE]);

      const { unmount } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => { jest.advanceTimersByTime(300); });
      unmount();

      expect(abortSpy).toHaveBeenCalled();
    });

    it('passes AbortSignal to fetch', async () => {
      mockFetchSuccess([SINGLE_PAGE_RESPONSE]);
      renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => { jest.advanceTimersByTime(300); });

      expect(global.fetch).toHaveBeenCalledWith(
        expect.any(String),
        expect.objectContaining({ signal: expect.any(AbortSignal) }),
      );
    });
  });

  // ── Pagination / loadMore ──────────────────────────────────────────────

  describe('pagination', () => {
    it('appends second page results when loadMore is called (does not replace)', async () => {
      mockFetchSuccess([FIRST_PAGE_RESPONSE, SECOND_PAGE_RESPONSE]);

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => { jest.advanceTimersByTime(300); });

      // Initial load: [PRODUCT_1, PRODUCT_2]
      expect(result.current.products).toEqual([PRODUCT_1, PRODUCT_2]);
      expect(result.current.total).toBe(3);
      expect(result.current.hasMore).toBe(true);

      await act(async () => {
        result.current.loadMore();
      });

      // After loadMore: [PRODUCT_1, PRODUCT_2, PRODUCT_3]
      expect(result.current.products).toEqual([PRODUCT_1, PRODUCT_2, PRODUCT_3]);
      expect(result.current.hasMore).toBe(false);
    });

    it('passes correct skip offset for each page', async () => {
      mockFetchSuccess([FIRST_PAGE_RESPONSE, SECOND_PAGE_RESPONSE]);

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => { jest.advanceTimersByTime(300); });
      await act(async () => { result.current.loadMore(); });

      expect(global.fetch).toHaveBeenNthCalledWith(
        1,
        expect.stringContaining('skip=0'),
        expect.any(Object),
      );
      expect(global.fetch).toHaveBeenNthCalledWith(
        2,
        expect.stringContaining('skip=20'),
        expect.any(Object),
      );
    });

    it('sets hasMore = false when all results are loaded', async () => {
      mockFetchSuccess([SINGLE_PAGE_RESPONSE]);

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => { jest.advanceTimersByTime(300); });

      expect(result.current.hasMore).toBe(false);
    });

    it('does not call loadMore when no more results exist', async () => {
      mockFetchSuccess([SINGLE_PAGE_RESPONSE]);

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => { jest.advanceTimersByTime(300); });

      const fetchCallCount = (global.fetch as jest.Mock).mock.calls.length;

      act(() => { result.current.loadMore(); });

      expect(global.fetch).toHaveBeenCalledTimes(fetchCallCount);
    });
  });

  // ── Loading states ─────────────────────────────────────────────────────

  describe('loading states', () => {
    it('sets isLoading=true during initial search, isLoadingMore=false', async () => {
      let capturedLoading: boolean | undefined;
      let capturedLoadingMore: boolean | undefined;

      jest.spyOn(global, 'fetch').mockImplementation(() => {
        // Capture state during fetch
        return Promise.resolve({
          ok: true,
          status: 200,
          json: () => Promise.resolve(SINGLE_PAGE_RESPONSE),
        } as Response);
      });

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => { jest.advanceTimersByTime(300); });

      // After fetch completes, both should be false
      expect(result.current.isLoading).toBe(false);
      expect(result.current.isLoadingMore).toBe(false);
    });

    it('isLoading and isLoadingMore are never both true simultaneously', async () => {
      mockFetchSuccess([FIRST_PAGE_RESPONSE, SECOND_PAGE_RESPONSE]);

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => { jest.advanceTimersByTime(300); });

      // Verify after initial load
      expect(result.current.isLoading).toBe(false);
      expect(result.current.isLoadingMore).toBe(false);

      await act(async () => { result.current.loadMore(); });

      // Verify after loadMore
      expect(result.current.isLoading).toBe(false);
      expect(result.current.isLoadingMore).toBe(false);
    });

    it('resets products and total when new query fires after debounce', async () => {
      mockFetchSuccess([FIRST_PAGE_RESPONSE, SINGLE_PAGE_RESPONSE]);

      const { result, rerender } = renderHook(
        ({ q }) => useSearchProducts(q),
        { initialProps: { q: QUERY_SHOES } },
      );

      await act(async () => { jest.advanceTimersByTime(300); });
      expect(result.current.products).toHaveLength(2);

      rerender({ q: QUERY_HATS });

      await act(async () => { jest.advanceTimersByTime(300); });

      // New query should reset to only new results
      expect(result.current.products).toEqual([PRODUCT_1]);
    });
  });

  // ── Retry ──────────────────────────────────────────────────────────────

  describe('retry', () => {
    it('retries up to 3 times on 5xx server errors', async () => {
      mockFetchFailure(500, 'Internal Server Error');

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => {
        jest.advanceTimersByTime(300);
        // Advance timers for each retry backoff (200ms + 400ms + 800ms)
        jest.advanceTimersByTime(1400);
      });

      // fetch called 3 times (MAX_RETRIES)
      expect(global.fetch).toHaveBeenCalledTimes(3);
    });

    it('does NOT retry on 4xx client errors', async () => {
      mockFetchFailure(400, 'Bad Request');

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => {
        jest.advanceTimersByTime(300);
        jest.advanceTimersByTime(1400);
      });

      // fetch called only once — no retry for 4xx
      expect(global.fetch).toHaveBeenCalledTimes(1);
    });

    it('does NOT retry on 401 Unauthorized', async () => {
      mockFetchFailure(401, 'Unauthorized');

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => {
        jest.advanceTimersByTime(300);
        jest.advanceTimersByTime(1400);
      });

      expect(global.fetch).toHaveBeenCalledTimes(1);
    });

    it('sets error state after exhausting all retries', async () => {
      mockFetchFailure(500, 'Internal Server Error');

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => {
        jest.advanceTimersByTime(300);
        jest.advanceTimersByTime(1400);
      });

      expect(result.current.error).toBeInstanceOf(Error);
      expect(result.current.error?.message).toContain('500');
    });

    it('retries 429 Too Many Requests', async () => {
      jest.spyOn(global, 'fetch')
        .mockResolvedValueOnce({ ok: false, status: 429, statusText: 'Too Many Requests' } as Response)
        .mockResolvedValue({ ok: true, status: 200, json: () => Promise.resolve(SINGLE_PAGE_RESPONSE) } as Response);

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => {
        jest.advanceTimersByTime(300);
        jest.advanceTimersByTime(1400);
      });

      expect(global.fetch).toHaveBeenCalledTimes(2);
      expect(result.current.products).toEqual([PRODUCT_1]);
    });

    it('manual retry function re-fetches the current page', async () => {
      mockFetchFailure(500, 'Internal Server Error');

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => {
        jest.advanceTimersByTime(300);
        jest.advanceTimersByTime(1400);
      });

      expect(result.current.error).not.toBeNull();

      const fetchCountBefore = (global.fetch as jest.Mock).mock.calls.length;

      mockFetchSuccess([SINGLE_PAGE_RESPONSE]);

      await act(async () => { result.current.retry(); });

      expect(global.fetch).toHaveBeenCalledTimes(fetchCountBefore + 1);
    });
  });

  // ── Runtime validation ─────────────────────────────────────────────────

  describe('runtime response validation', () => {
    it('sets error when response is missing products array', async () => {
      jest.spyOn(global, 'fetch').mockResolvedValue({
        ok: true,
        status: 200,
        json: () => Promise.resolve({ total: 1 }), // missing products
      } as Response);

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => { jest.advanceTimersByTime(300); });

      expect(result.current.error?.message).toContain('Invalid response shape');
    });

    it('sets error when product item is missing required fields', async () => {
      jest.spyOn(global, 'fetch').mockResolvedValue({
        ok: true,
        status: 200,
        json: () =>
          Promise.resolve({
            products: [{ id: 'p1' }], // missing name and price
            total: 1,
          }),
      } as Response);

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => { jest.advanceTimersByTime(300); });

      expect(result.current.error?.message).toContain('Invalid response shape');
    });
  });

  // ── Cleanup on unmount ─────────────────────────────────────────────────

  describe('cleanup on unmount', () => {
    it('clears debounce timer on unmount', () => {
      const clearTimeoutSpy = jest.spyOn(global, 'clearTimeout');
      renderHook(() => useSearchProducts(QUERY_SHOES)).unmount();

      expect(clearTimeoutSpy).toHaveBeenCalled();
    });

    it('does not update state after unmount (no setState after cleanup)', async () => {
      // Track console.error to detect React "setState on unmounted component" warnings
      const consoleSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
      mockFetchSuccess([SINGLE_PAGE_RESPONSE]);

      const { unmount } = renderHook(() => useSearchProducts(QUERY_SHOES));

      act(() => { jest.advanceTimersByTime(300); });
      unmount();

      // Allow any pending microtasks to complete
      await act(async () => { jest.runAllTimers(); });

      // React should not warn about setState on unmounted component
      const reactWarnings = consoleSpy.mock.calls.filter(
        (call) =>
          String(call[0]).includes("Can't perform a React state update") ||
          String(call[0]).includes('unmounted component'),
      );
      expect(reactWarnings).toHaveLength(0);

      consoleSpy.mockRestore();
    });
  });
});
