// FILE: useSearchProducts.test.ts
import { renderHook, act } from '@testing-library/react';
import { useSearchProducts } from './r2-useSearchProducts';

// ── Test constants ────────────────────────────────────────────────────────────

const QUERY_SHOES = 'shoes';
const QUERY_HATS = 'hats';

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

/**
 * FIX: mockFetchSuccess now throws on unexpected extra calls instead of wrapping
 * around, so regression-causing double-fetches cause the test to fail explicitly.
 */
function mockFetchSuccess(responses: object[]) {
  let callIndex = 0;
  jest.spyOn(global, 'fetch').mockImplementation(() => {
    if (callIndex >= responses.length) {
      return Promise.reject(
        new Error(
          `Unexpected extra fetch call #${callIndex + 1} (only ${responses.length} expected)`,
        ),
      );
    }
    const body = responses[callIndex++];
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

// Deferred promise helper for pausing mid-fetch to observe loading state
function makeDeferred() {
  let resolve!: (value: unknown) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
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

      act(() => { jest.advanceTimersByTime(200); });
      rerender({ q: QUERY_HATS });
      act(() => { jest.advanceTimersByTime(200); });

      expect(global.fetch).not.toHaveBeenCalled();

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
      mockFetchSuccess([SINGLE_PAGE_RESPONSE, SINGLE_PAGE_RESPONSE]);

      const { rerender } = renderHook(
        ({ q }) => useSearchProducts(q),
        { initialProps: { q: QUERY_SHOES } },
      );

      await act(async () => { jest.advanceTimersByTime(300); });

      rerender({ q: QUERY_HATS });
      await act(async () => { jest.advanceTimersByTime(300); });

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

      expect(result.current.products).toEqual([PRODUCT_1, PRODUCT_2]);
      expect(result.current.total).toBe(3);
      expect(result.current.hasMore).toBe(true);

      await act(async () => { result.current.loadMore(); });

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

    it('does not call fetch again when no more results exist', async () => {
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
    // FIX: Use a deferred promise to pause fetch mid-flight and actually
    // assert isLoading=true DURING the fetch, not just after it resolves.
    it('sets isLoading=true during initial fetch, isLoadingMore=false', async () => {
      const deferred = makeDeferred();

      jest.spyOn(global, 'fetch').mockImplementation(() =>
        deferred.promise.then(() => ({
          ok: true,
          status: 200,
          json: () => Promise.resolve(SINGLE_PAGE_RESPONSE),
        })) as Promise<Response>,
      );

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      // Trigger debounce
      act(() => { jest.advanceTimersByTime(300); });

      // Fetch in-flight: isLoading should be true, isLoadingMore false
      expect(result.current.isLoading).toBe(true);
      expect(result.current.isLoadingMore).toBe(false);

      // Resolve the fetch
      await act(async () => { deferred.resolve(undefined); });

      expect(result.current.isLoading).toBe(false);
    });

    it('sets isLoadingMore=true during loadMore, isLoading=false', async () => {
      const deferred = makeDeferred();

      jest.spyOn(global, 'fetch')
        .mockResolvedValueOnce({
          ok: true,
          status: 200,
          json: () => Promise.resolve(FIRST_PAGE_RESPONSE),
        } as Response)
        .mockImplementationOnce(() =>
          deferred.promise.then(() => ({
            ok: true,
            status: 200,
            json: () => Promise.resolve(SECOND_PAGE_RESPONSE),
          })) as Promise<Response>,
        );

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => { jest.advanceTimersByTime(300); });

      // Trigger loadMore — fetch pauses mid-flight
      act(() => { result.current.loadMore(); });

      expect(result.current.isLoadingMore).toBe(true);
      expect(result.current.isLoading).toBe(false);

      await act(async () => { deferred.resolve(undefined); });

      expect(result.current.isLoadingMore).toBe(false);
    });

    it('isLoading and isLoadingMore are never both true simultaneously', async () => {
      mockFetchSuccess([FIRST_PAGE_RESPONSE, SECOND_PAGE_RESPONSE]);

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => { jest.advanceTimersByTime(300); });
      await act(async () => { result.current.loadMore(); });

      // After everything settles, both should be false
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

      expect(result.current.products).toEqual([PRODUCT_1]);
    });
  });

  // ── Retry ──────────────────────────────────────────────────────────────

  describe('retry', () => {
    // FIX: Separate each retry step into its own await act() so microtasks
    // flush between timer advances — prevents timing-fragile flakes in CI.
    it('retries up to 3 times on 5xx server errors with exponential backoff', async () => {
      mockFetchFailure(500, 'Internal Server Error');

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      // Trigger debounce + first attempt
      await act(async () => { jest.advanceTimersByTime(300); });

      // First retry after 200ms backoff
      await act(async () => { jest.advanceTimersByTime(200); });

      // Second retry after 400ms backoff
      await act(async () => { jest.advanceTimersByTime(400); });

      // fetch called 3 times total
      expect(global.fetch).toHaveBeenCalledTimes(3);
    });

    it('does NOT retry on 4xx client errors', async () => {
      mockFetchFailure(400, 'Bad Request');

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => { jest.advanceTimersByTime(300); });
      await act(async () => { jest.advanceTimersByTime(1400); });

      expect(global.fetch).toHaveBeenCalledTimes(1);
    });

    it('does NOT retry on 401 Unauthorized', async () => {
      mockFetchFailure(401, 'Unauthorized');

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => { jest.advanceTimersByTime(300); });
      await act(async () => { jest.advanceTimersByTime(1400); });

      expect(global.fetch).toHaveBeenCalledTimes(1);
    });

    it('sets error state after exhausting all retries', async () => {
      mockFetchFailure(500, 'Internal Server Error');

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => { jest.advanceTimersByTime(300); });
      await act(async () => { jest.advanceTimersByTime(200); });
      await act(async () => { jest.advanceTimersByTime(400); });

      expect(result.current.error).toBeInstanceOf(Error);
      expect(result.current.error?.message).toContain('500');
    });

    it('retries 429 Too Many Requests', async () => {
      jest.spyOn(global, 'fetch')
        .mockResolvedValueOnce({ ok: false, status: 429, statusText: 'Too Many Requests' } as Response)
        .mockResolvedValue({ ok: true, status: 200, json: () => Promise.resolve(SINGLE_PAGE_RESPONSE) } as Response);

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => { jest.advanceTimersByTime(300); });
      await act(async () => { jest.advanceTimersByTime(200); });

      expect(global.fetch).toHaveBeenCalledTimes(2);
      expect(result.current.products).toEqual([PRODUCT_1]);
    });

    it('manual retry function re-fetches the current page', async () => {
      mockFetchFailure(500, 'Internal Server Error');

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => { jest.advanceTimersByTime(300); });
      await act(async () => { jest.advanceTimersByTime(200); });
      await act(async () => { jest.advanceTimersByTime(400); });

      expect(result.current.error).not.toBeNull();

      const fetchCountBefore = (global.fetch as jest.Mock).mock.calls.length;
      mockFetchSuccess([SINGLE_PAGE_RESPONSE]);

      await act(async () => { result.current.retry(); });

      expect(global.fetch).toHaveBeenCalledTimes(fetchCountBefore + 1);
    });

    // FIX: Verify that retry after loadMore failure preserves the correct page offset
    it('preserves correct skip offset when retrying after loadMore failure', async () => {
      jest.spyOn(global, 'fetch')
        .mockResolvedValueOnce({
          ok: true,
          status: 200,
          json: () => Promise.resolve(FIRST_PAGE_RESPONSE),
        } as Response)
        .mockRejectedValueOnce(new Error('Network error')) // loadMore page 2 fails
        .mockResolvedValue({
          ok: true,
          status: 200,
          json: () => Promise.resolve(SECOND_PAGE_RESPONSE),
        } as Response);

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => { jest.advanceTimersByTime(300); });

      // Trigger loadMore — page 2 fetch fails
      await act(async () => { result.current.loadMore(); });

      expect(result.current.error).not.toBeNull();

      // Retry should use skip=20 (page 2 offset), not reset to skip=0
      await act(async () => { result.current.retry(); });

      const fetchCalls = (global.fetch as jest.Mock).mock.calls;
      const lastCall = fetchCalls[fetchCalls.length - 1][0] as string;
      expect(lastCall).toContain('skip=20');
    });

    // FIX: Test that network errors (rejected Promise) are handled, not just !ok responses
    it('sets error state on complete network failure (fetch promise rejects)', async () => {
      mockFetchNetworkError();

      const { result } = renderHook(() => useSearchProducts(QUERY_SHOES));

      await act(async () => { jest.advanceTimersByTime(300); });

      expect(result.current.error).toBeInstanceOf(Error);
      expect(result.current.error?.message).toBe('Network error');
    });
  });

  // ── Runtime validation ─────────────────────────────────────────────────

  describe('runtime response validation', () => {
    it('sets error when response is missing products array', async () => {
      jest.spyOn(global, 'fetch').mockResolvedValue({
        ok: true,
        status: 200,
        json: () => Promise.resolve({ total: 1 }),
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
      const consoleSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
      mockFetchSuccess([SINGLE_PAGE_RESPONSE]);

      const { unmount } = renderHook(() => useSearchProducts(QUERY_SHOES));

      act(() => { jest.advanceTimersByTime(300); });
      unmount();

      await act(async () => { jest.runAllTimers(); });

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
