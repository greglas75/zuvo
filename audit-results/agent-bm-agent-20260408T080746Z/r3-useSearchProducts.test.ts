import { act, renderHook } from '@testing-library/react';
import { useSearchProducts } from './r2-useSearchProducts';

const QUERY_A = 'laptop';
const QUERY_B = 'mouse';
const PRODUCT_1 = { id: 'p1', name: 'Laptop Pro', price: 1200 };
const PRODUCT_2 = { id: 'p2', name: 'Mouse X', price: 99 };

function mockOkResponse(payload: unknown, status = 200) {
  return {
    ok: true,
    status,
    json: jest.fn().mockResolvedValue(payload),
  } as unknown as Response;
}

describe('useSearchProducts', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    jest.useFakeTimers();
    jest.spyOn(global, 'fetch').mockResolvedValue(
      mockOkResponse({ products: [PRODUCT_1], total: 1 }),
    );
  });

  afterEach(() => {
    jest.runOnlyPendingTimers();
    jest.useRealTimers();
    jest.restoreAllMocks();
  });

  it('debounces by 300ms before calling fetch', async () => {
    renderHook(({ query }) => useSearchProducts(query), {
      initialProps: { query: QUERY_A },
    });

    expect(global.fetch).not.toHaveBeenCalled();

    await act(async () => {
      jest.advanceTimersByTime(299);
    });
    expect(global.fetch).not.toHaveBeenCalled();

    await act(async () => {
      jest.advanceTimersByTime(1);
    });

    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(global.fetch).toHaveBeenCalledWith(
      expect.stringContaining('query=laptop'),
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    );
  });

  it('aborts in-flight request on query change and on unmount', async () => {
    const abortSpy = jest.spyOn(AbortController.prototype, 'abort');

    const { rerender, unmount } = renderHook(({ query }) => useSearchProducts(query), {
      initialProps: { query: QUERY_A },
    });

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    rerender({ query: QUERY_B });

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    unmount();

    expect(abortSpy).toHaveBeenCalled();
    expect(global.fetch).toHaveBeenCalledWith(
      expect.stringContaining('query=mouse'),
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    );
  });

  it('loadMore appends results and does not replace existing list', async () => {
    (global.fetch as jest.Mock)
      .mockResolvedValueOnce(mockOkResponse({ products: [PRODUCT_1], total: 2 }))
      .mockResolvedValueOnce(mockOkResponse({ products: [PRODUCT_2], total: 2 }));

    const { result } = renderHook(() => useSearchProducts(QUERY_A));

    await act(async () => {
      jest.advanceTimersByTime(300);
      await Promise.resolve();
    });

    await act(async () => {
      await result.current.loadMore();
      await Promise.resolve();
    });

    expect(result.current.products).toEqual([PRODUCT_1, PRODUCT_2]);
    expect(result.current.total).toBe(2);
    expect(global.fetch).toHaveBeenNthCalledWith(
      2,
      expect.stringContaining('skip=1'),
      expect.any(Object),
    );
  });

  it('retries up to 3 attempts with exponential backoff on retryable failure', async () => {
    (global.fetch as jest.Mock)
      .mockResolvedValueOnce({ ok: false, status: 500, json: jest.fn() })
      .mockResolvedValueOnce({ ok: false, status: 500, json: jest.fn() })
      .mockResolvedValueOnce(mockOkResponse({ products: [PRODUCT_1], total: 1 }));

    renderHook(() => useSearchProducts(QUERY_A));

    await act(async () => {
      jest.advanceTimersByTime(300);
      await Promise.resolve();
    });

    await act(async () => {
      jest.advanceTimersByTime(250);
      await Promise.resolve();
    });

    await act(async () => {
      jest.advanceTimersByTime(500);
      await Promise.resolve();
    });

    expect(global.fetch).toHaveBeenCalledTimes(3);
  });

  it('sets only isLoading during initial fetch and only isLoadingMore during pagination', async () => {
    (global.fetch as jest.Mock)
      .mockResolvedValueOnce(mockOkResponse({ products: [PRODUCT_1], total: 2 }))
      .mockResolvedValueOnce(mockOkResponse({ products: [PRODUCT_2], total: 2 }));

    const { result } = renderHook(() => useSearchProducts(QUERY_A));

    expect(result.current.isLoading).toBe(false);
    expect(result.current.isLoadingMore).toBe(false);

    await act(async () => {
      jest.advanceTimersByTime(300);
      await Promise.resolve();
    });

    expect(result.current.isLoading).toBe(false);
    expect(result.current.isLoadingMore).toBe(false);

    await act(async () => {
      const promise = result.current.loadMore();
      expect(result.current.isLoading).toBe(false);
      expect(result.current.isLoadingMore).toBe(true);
      await promise;
      await Promise.resolve();
    });

    expect(result.current.isLoading).toBe(false);
    expect(result.current.isLoadingMore).toBe(false);
  });

  it('cleans up timers and avoids state updates after unmount', async () => {
    const lateResolve = new Promise<Response>((resolve) => {
      setTimeout(() => {
        resolve(mockOkResponse({ products: [PRODUCT_1], total: 1 }));
      }, 200);
    });

    (global.fetch as jest.Mock).mockReturnValue(lateResolve);

    const { unmount } = renderHook(() => useSearchProducts(QUERY_A));

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    unmount();

    await act(async () => {
      jest.advanceTimersByTime(1000);
      await Promise.resolve();
    });

    expect(global.fetch).toHaveBeenCalledTimes(1);
  });

  it('retry triggers last failed request again', async () => {
    (global.fetch as jest.Mock)
      .mockResolvedValueOnce({ ok: false, status: 500, json: jest.fn() })
      .mockResolvedValueOnce({ ok: false, status: 500, json: jest.fn() })
      .mockResolvedValueOnce({ ok: false, status: 500, json: jest.fn() })
      .mockResolvedValueOnce(mockOkResponse({ products: [PRODUCT_1], total: 1 }));

    const { result } = renderHook(() => useSearchProducts(QUERY_A));

    await act(async () => {
      jest.advanceTimersByTime(300);
      jest.advanceTimersByTime(250 + 500);
      await Promise.resolve();
    });

    expect(result.current.error).toContain('status 500');

    await act(async () => {
      await result.current.retry();
      await Promise.resolve();
    });

    expect(global.fetch).toHaveBeenCalledTimes(4);
    expect(result.current.products).toEqual([PRODUCT_1]);
  });
});
