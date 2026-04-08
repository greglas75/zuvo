import { act, renderHook } from '@testing-library/react';
import { useSearchProducts } from './r2-useSearchProducts';

const QUERY_A = 'laptop';
const QUERY_B = 'mouse';
const PRODUCT_1 = { id: 'p1', name: 'Laptop Pro', price: 1200 };
const PRODUCT_2 = { id: 'p2', name: 'Mouse X', price: 99 };

function makeResponse(payload: unknown, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: jest.fn().mockResolvedValue(payload),
  } as unknown as Response;
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

describe('useSearchProducts (R4)', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    jest.useFakeTimers();
    jest.spyOn(global, 'fetch').mockResolvedValue(
      makeResponse({ products: [PRODUCT_1], total: 1 }),
    );
  });

  afterEach(() => {
    jest.runOnlyPendingTimers();
    jest.useRealTimers();
    jest.restoreAllMocks();
  });

  it('debounces for exactly 300ms before first request', async () => {
    renderHook(() => useSearchProducts(QUERY_A));

    expect(global.fetch).toHaveBeenCalledTimes(0);

    await act(async () => {
      jest.advanceTimersByTime(299);
    });
    expect(global.fetch).toHaveBeenCalledTimes(0);

    await act(async () => {
      jest.advanceTimersByTime(1);
      await Promise.resolve();
    });

    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(global.fetch).toHaveBeenCalledWith(
      expect.stringContaining('query=laptop'),
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    );
  });

  it('sets isLoading=true during initial in-flight request and false after completion', async () => {
    const first = deferred<Response>();
    (global.fetch as jest.Mock).mockReturnValueOnce(first.promise);

    const { result } = renderHook(() => useSearchProducts(QUERY_A));

    await act(async () => {
      jest.advanceTimersByTime(300);
      await Promise.resolve();
    });

    expect(result.current.isLoading).toBe(true);
    expect(result.current.isLoadingMore).toBe(false);

    await act(async () => {
      first.resolve(makeResponse({ products: [PRODUCT_1], total: 1 }));
      await Promise.resolve();
    });

    expect(result.current.isLoading).toBe(false);
    expect(result.current.products).toEqual([PRODUCT_1]);
  });

  it('aborts once on query change and once on unmount', async () => {
    const abortSpy = jest.spyOn(AbortController.prototype, 'abort');

    const first = deferred<Response>();
    const second = deferred<Response>();
    (global.fetch as jest.Mock)
      .mockReturnValueOnce(first.promise)
      .mockReturnValueOnce(second.promise);

    const { rerender, unmount } = renderHook(
      ({ query }) => useSearchProducts(query),
      { initialProps: { query: QUERY_A } },
    );

    await act(async () => {
      jest.advanceTimersByTime(300);
      await Promise.resolve();
    });

    rerender({ query: QUERY_B });
    await act(async () => {
      jest.advanceTimersByTime(300);
      await Promise.resolve();
    });

    expect(abortSpy).toHaveBeenCalledTimes(1);

    unmount();
    expect(abortSpy).toHaveBeenCalledTimes(2);

    await act(async () => {
      first.resolve(makeResponse({ products: [PRODUCT_1], total: 1 }));
      second.resolve(makeResponse({ products: [PRODUCT_2], total: 1 }));
      await Promise.resolve();
    });
  });

  it('appends products on loadMore without replacing existing list', async () => {
    (global.fetch as jest.Mock)
      .mockResolvedValueOnce(makeResponse({ products: [PRODUCT_1], total: 2 }))
      .mockResolvedValueOnce(makeResponse({ products: [PRODUCT_2], total: 2 }));

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
    expect(global.fetch).toHaveBeenNthCalledWith(
      2,
      expect.stringContaining('skip=1'),
      expect.any(Object),
    );
  });

  it('retries retryable 500 responses with exponential backoff (250ms then 500ms)', async () => {
    (global.fetch as jest.Mock)
      .mockResolvedValueOnce(makeResponse({}, 500))
      .mockResolvedValueOnce(makeResponse({}, 500))
      .mockResolvedValueOnce(makeResponse({ products: [PRODUCT_1], total: 1 }, 200));

    renderHook(() => useSearchProducts(QUERY_A));

    await act(async () => {
      jest.advanceTimersByTime(300);
      await Promise.resolve();
    });
    expect(global.fetch).toHaveBeenCalledTimes(1);

    await act(async () => {
      jest.advanceTimersByTime(249);
      await Promise.resolve();
    });
    expect(global.fetch).toHaveBeenCalledTimes(1);

    await act(async () => {
      jest.advanceTimersByTime(1);
      await Promise.resolve();
    });
    expect(global.fetch).toHaveBeenCalledTimes(2);

    await act(async () => {
      jest.advanceTimersByTime(499);
      await Promise.resolve();
    });
    expect(global.fetch).toHaveBeenCalledTimes(2);

    await act(async () => {
      jest.advanceTimersByTime(1);
      await Promise.resolve();
    });
    expect(global.fetch).toHaveBeenCalledTimes(3);
  });

  it('does not retry non-retryable 400 responses', async () => {
    (global.fetch as jest.Mock).mockResolvedValueOnce(makeResponse({}, 400));

    const { result } = renderHook(() => useSearchProducts(QUERY_A));

    await act(async () => {
      jest.advanceTimersByTime(300);
      await Promise.resolve();
    });

    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(result.current.error).toContain('status 400');
  });

  it('sets isLoadingMore during pagination while keeping isLoading false', async () => {
    const initial = deferred<Response>();
    const more = deferred<Response>();
    (global.fetch as jest.Mock)
      .mockReturnValueOnce(initial.promise)
      .mockReturnValueOnce(more.promise);

    const { result } = renderHook(() => useSearchProducts(QUERY_A));

    await act(async () => {
      jest.advanceTimersByTime(300);
      await Promise.resolve();
    });

    await act(async () => {
      initial.resolve(makeResponse({ products: [PRODUCT_1], total: 2 }));
      await Promise.resolve();
    });

    await act(async () => {
      const load = result.current.loadMore();
      await Promise.resolve();
      expect(result.current.isLoading).toBe(false);
      expect(result.current.isLoadingMore).toBe(true);
      more.resolve(makeResponse({ products: [PRODUCT_2], total: 2 }));
      await load;
      await Promise.resolve();
    });

    expect(result.current.isLoading).toBe(false);
    expect(result.current.isLoadingMore).toBe(false);
  });

  it('unmount cleanup prevents post-unmount React warnings from late resolution', async () => {
    const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
    const first = deferred<Response>();
    (global.fetch as jest.Mock).mockReturnValueOnce(first.promise);

    const { unmount } = renderHook(() => useSearchProducts(QUERY_A));

    await act(async () => {
      jest.advanceTimersByTime(300);
      await Promise.resolve();
    });

    unmount();

    await act(async () => {
      first.resolve(makeResponse({ products: [PRODUCT_1], total: 1 }));
      await Promise.resolve();
    });

    expect(consoleErrorSpy).not.toHaveBeenCalled();
  });

  it('retry re-runs the last failed request', async () => {
    (global.fetch as jest.Mock)
      .mockResolvedValueOnce(makeResponse({}, 500))
      .mockResolvedValueOnce(makeResponse({}, 500))
      .mockResolvedValueOnce(makeResponse({}, 500))
      .mockResolvedValueOnce(makeResponse({ products: [PRODUCT_1], total: 1 }));

    const { result } = renderHook(() => useSearchProducts(QUERY_A));

    await act(async () => {
      jest.advanceTimersByTime(300);
      await Promise.resolve();
      jest.advanceTimersByTime(250);
      await Promise.resolve();
      jest.advanceTimersByTime(500);
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
