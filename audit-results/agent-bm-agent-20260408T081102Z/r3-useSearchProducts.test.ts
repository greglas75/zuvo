import { act, renderHook, waitFor } from '@testing-library/react';

import { useSearchProducts } from './r2-useSearchProducts';

const PRODUCT_A = { id: 'p-1', name: 'Alpha', price: 10, currency: 'USD' };
const PRODUCT_B = { id: 'p-2', name: 'Beta', price: 20, currency: 'USD' };
const PRODUCT_C = { id: 'p-3', name: 'Gamma', price: 30, currency: 'USD' };
const PRODUCT_D = { id: 'p-4', name: 'Delta', price: 40, currency: 'USD' };
const SEARCH_QUERY = 'phone';
const PAGE_SIZE = 2;

function mockResponse(payload: unknown, ok = true, status = 200): Response {
  return {
    ok,
    status,
    json: async () => payload,
  } as Response;
}

function deferredResponse(): { promise: Promise<Response>; resolve: (response: Response) => void } {
  let resolve!: (response: Response) => void;
  const promise = new Promise<Response>((res) => {
    resolve = res;
  });

  return { promise, resolve };
}

describe('useSearchProducts (round 3)', () => {
  let fetchSpy: jest.SpyInstance;
  let abortSpy: jest.SpyInstance;

  beforeEach(() => {
    jest.clearAllMocks();
    jest.useFakeTimers();
    fetchSpy = jest.spyOn(global, 'fetch');
    abortSpy = jest.spyOn(AbortController.prototype, 'abort');
  });

  afterEach(() => {
    jest.runOnlyPendingTimers();
    jest.useRealTimers();
    fetchSpy.mockRestore();
    abortSpy.mockRestore();
  });

  it('debounces the initial search for 300ms before calling fetch', async () => {
    fetchSpy.mockResolvedValueOnce(
      mockResponse({
        products: [PRODUCT_A, PRODUCT_B],
        total: 2,
      }),
    );

    const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY, PAGE_SIZE));

    expect(result.current.isLoading).toBe(false);
    expect(fetchSpy).not.toHaveBeenCalled();

    await act(async () => {
      jest.advanceTimersByTime(299);
    });
    expect(fetchSpy).not.toHaveBeenCalled();

    await act(async () => {
      jest.advanceTimersByTime(1);
    });

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledTimes(1);
      expect(result.current.products).toEqual([PRODUCT_A, PRODUCT_B]);
    });

    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining(`q=${encodeURIComponent(SEARCH_QUERY)}`),
      expect.objectContaining({ method: 'GET' }),
    );
  });

  it('aborts the in-flight request on query change and on unmount', async () => {
    const pending = deferredResponse();
    fetchSpy.mockImplementation(() => pending.promise);

    const { rerender, unmount } = renderHook(({ query }) => useSearchProducts(query, PAGE_SIZE), {
      initialProps: { query: 'a' },
    });

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledTimes(1);
    });

    rerender({ query: 'ab' });
    expect(abortSpy).toHaveBeenCalled();

    unmount();
    expect(abortSpy).toHaveBeenCalledTimes(2);
  });

  it('appends loadMore results instead of replacing the existing products', async () => {
    fetchSpy
      .mockResolvedValueOnce(
        mockResponse({
          products: [PRODUCT_A, PRODUCT_B],
          total: 4,
        }),
      )
      .mockResolvedValueOnce(
        mockResponse({
          products: [PRODUCT_C, PRODUCT_D],
          total: 4,
        }),
      );

    const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY, PAGE_SIZE));

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    await waitFor(() => {
      expect(result.current.products).toEqual([PRODUCT_A, PRODUCT_B]);
      expect(result.current.hasMore).toBe(true);
    });

    await act(async () => {
      result.current.loadMore();
    });

    await waitFor(() => {
      expect(result.current.products).toEqual([PRODUCT_A, PRODUCT_B, PRODUCT_C, PRODUCT_D]);
      expect(result.current.hasMore).toBe(false);
    });
  });

  it('retries failed searches up to 3 attempts with exponential backoff', async () => {
    fetchSpy
      .mockRejectedValueOnce(new Error('temporary failure 1'))
      .mockRejectedValueOnce(new Error('temporary failure 2'))
      .mockResolvedValueOnce(
        mockResponse({
          products: [PRODUCT_A],
          total: 1,
        }),
      );

    const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY, 1));

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledTimes(1);
    });

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledTimes(2);
    });

    await act(async () => {
      jest.advanceTimersByTime(600);
    });

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledTimes(3);
      expect(result.current.products).toEqual([PRODUCT_A]);
      expect(result.current.error).toBeNull();
    });
  });

  it('keeps isLoading and isLoadingMore mutually exclusive across initial and pagination fetches', async () => {
    const initial = deferredResponse();
    const loadMore = deferredResponse();
    fetchSpy
      .mockImplementationOnce(() => initial.promise)
      .mockImplementationOnce(() => loadMore.promise);

    const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY, PAGE_SIZE));

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    await waitFor(() => {
      expect(result.current.isLoading).toBe(true);
      expect(result.current.isLoadingMore).toBe(false);
    });

    await act(async () => {
      initial.resolve(
        mockResponse({
          products: [PRODUCT_A, PRODUCT_B],
          total: 4,
        }),
      );
    });

    await waitFor(() => {
      expect(result.current.isLoading).toBe(false);
      expect(result.current.isLoadingMore).toBe(false);
    });

    await act(async () => {
      result.current.loadMore();
    });

    await waitFor(() => {
      expect(result.current.isLoading).toBe(false);
      expect(result.current.isLoadingMore).toBe(true);
    });

    await act(async () => {
      loadMore.resolve(
        mockResponse({
          products: [PRODUCT_C, PRODUCT_D],
          total: 4,
        }),
      );
    });

    await waitFor(() => {
      expect(result.current.isLoading).toBe(false);
      expect(result.current.isLoadingMore).toBe(false);
    });
  });

  it('clears debounce timers on unmount before the search fires', async () => {
    const { unmount } = renderHook(() => useSearchProducts(SEARCH_QUERY, PAGE_SIZE));

    await act(async () => {
      jest.advanceTimersByTime(100);
    });

    unmount();

    await act(async () => {
      jest.advanceTimersByTime(250);
    });

    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('reports an invalid API shape after exhausting retries', async () => {
    fetchSpy.mockResolvedValue(
      mockResponse({
        products: [{ id: 1, name: 'broken', price: 'x', currency: 'USD' }],
        total: 1,
      }),
    );

    const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY, PAGE_SIZE));

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    await act(async () => {
      jest.advanceTimersByTime(600);
    });

    await waitFor(() => {
      expect(result.current.error).toContain('Invalid search response');
      expect(fetchSpy).toHaveBeenCalledTimes(3);
    });
  });

  it('retries a failed loadMore request for the same page instead of falling back to page 1', async () => {
    fetchSpy
      .mockResolvedValueOnce(
        mockResponse({
          products: [PRODUCT_A, PRODUCT_B],
          total: 4,
        }),
      )
      .mockRejectedValueOnce(new Error('load more failed'))
      .mockResolvedValueOnce(
        mockResponse({
          products: [PRODUCT_C, PRODUCT_D],
          total: 4,
        }),
      );

    const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY, PAGE_SIZE));

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    await waitFor(() => {
      expect(result.current.products).toEqual([PRODUCT_A, PRODUCT_B]);
      expect(result.current.hasMore).toBe(true);
    });

    await act(async () => {
      result.current.loadMore();
    });

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledTimes(2);
    });

    await act(async () => {
      result.current.retry();
    });

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledTimes(3);
    });

    expect(fetchSpy.mock.calls[2][0]).toContain('skip=2');
    await waitFor(() => {
      expect(result.current.products).toEqual([PRODUCT_A, PRODUCT_B, PRODUCT_C, PRODUCT_D]);
    });
  });
});
