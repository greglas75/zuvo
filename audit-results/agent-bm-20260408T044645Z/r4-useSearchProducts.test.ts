// Tests for benchmark corpus — code under test: r2-useSearchProducts.ts (R4: stricter assertions)
import { act, renderHook } from '@testing-library/react';
import { useSearchProducts } from './r2-useSearchProducts';

const SEARCH_URL = '/api/products/search';

function jsonResponse(data: unknown, ok = true) {
  return Promise.resolve({
    ok,
    status: ok ? 200 : 500,
    json: async () => data,
  }) as unknown as ReturnType<typeof fetch>;
}

describe('useSearchProducts', () => {
  let fetchSpy: jest.SpyInstance;

  beforeEach(() => {
    jest.clearAllMocks();
    jest.useFakeTimers();
    fetchSpy = jest.spyOn(global, 'fetch');
  });

  afterEach(() => {
    jest.useRealTimers();
    fetchSpy.mockRestore();
  });

  it('does not call fetch until 300ms after query changes', async () => {
    fetchSpy.mockImplementation(() => jsonResponse({ products: [], total: 0 }));

    const { rerender } = renderHook(({ q }) => useSearchProducts(SEARCH_URL, q), {
      initialProps: { q: '' },
    });

    rerender({ q: 'abc' });
    expect(fetchSpy).not.toHaveBeenCalled();

    await act(async () => {
      jest.advanceTimersByTime(299);
    });
    expect(fetchSpy).not.toHaveBeenCalled();

    await act(async () => {
      jest.advanceTimersByTime(1);
    });
    expect(fetchSpy).toHaveBeenCalledTimes(1);
  });

  it('aborts in-flight fetch immediately when query changes (before debounced fetch)', async () => {
    fetchSpy.mockImplementation(() => new Promise(() => {}));

    const { rerender } = renderHook(({ q }) => useSearchProducts(SEARCH_URL, q), {
      initialProps: { q: '' },
    });

    rerender({ q: 'first' });
    await act(async () => {
      jest.advanceTimersByTime(299);
    });
    expect(fetchSpy).not.toHaveBeenCalled();

    rerender({ q: 'second' });
    await act(async () => {
      jest.advanceTimersByTime(299);
    });
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    const url = String(fetchSpy.mock.calls[0][0]);
    expect(url).toContain('q=second');
  });

  it('aborts on unmount', async () => {
    fetchSpy.mockImplementation(() => new Promise(() => {}));

    const { unmount, rerender } = renderHook(({ q }) => useSearchProducts(SEARCH_URL, q), {
      initialProps: { q: 'x' },
    });

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    const signal = fetchSpy.mock.calls[0][1]?.signal as AbortSignal;
    expect(signal.aborted).toBe(false);

    unmount();

    expect(signal.aborted).toBe(true);
  });

  it('loadMore requests the next page and appends results', async () => {
    fetchSpy
      .mockImplementationOnce(() =>
        jsonResponse({
          products: [{ id: '1', name: 'A', price: 1, currency: 'USD' }],
          total: 2,
        }),
      )
      .mockImplementationOnce(() =>
        jsonResponse({
          products: [{ id: '2', name: 'B', price: 2, currency: 'USD' }],
          total: 2,
        }),
      );

    const { result } = renderHook(({ q }) => useSearchProducts(SEARCH_URL, q), {
      initialProps: { q: 'q' },
    });

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    await act(async () => {
      await Promise.resolve();
    });

    expect(result.current.products).toHaveLength(1);
    const firstUrl = String(fetchSpy.mock.calls[0][0]);
    expect(firstUrl).toContain('page=0');

    await act(async () => {
      result.current.loadMore();
    });

    await act(async () => {
      await Promise.resolve();
    });

    expect(result.current.products.map((p) => p.id)).toEqual(['1', '2']);
    const secondUrl = String(fetchSpy.mock.calls[1][0]);
    expect(secondUrl).toContain('page=1');
  });

  it('does not call fetch for loadMore when no more results', async () => {
    fetchSpy.mockImplementation(() =>
      jsonResponse({
        products: [{ id: '1', name: 'A', price: 1, currency: 'USD' }],
        total: 1,
      }),
    );

    const { result } = renderHook(({ q }) => useSearchProducts(SEARCH_URL, q), {
      initialProps: { q: 'q' },
    });

    await act(async () => {
      jest.advanceTimersByTime(300);
    });
    await act(async () => {
      await Promise.resolve();
    });

    fetchSpy.mockClear();

    await act(async () => {
      result.current.loadMore();
    });

    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('retries with exponential backoff and succeeds on the third attempt', async () => {
    fetchSpy
      .mockImplementationOnce(() => jsonResponse({}, false))
      .mockImplementationOnce(() => jsonResponse({}, false))
      .mockImplementationOnce(() =>
        jsonResponse({
          products: [{ id: '1', name: 'A', price: 1, currency: 'USD' }],
          total: 1,
        }),
      );

    const { result } = renderHook(({ q }) => useSearchProducts(SEARCH_URL, q), {
      initialProps: { q: 'x' },
    });

    await act(async () => {
      jest.advanceTimersByTime(300);
    });
    expect(fetchSpy).toHaveBeenCalledTimes(1);

    await act(async () => {
      jest.advanceTimersByTime(100);
    });
    expect(fetchSpy).toHaveBeenCalledTimes(2);

    await act(async () => {
      jest.advanceTimersByTime(200);
    });
    expect(fetchSpy).toHaveBeenCalledTimes(3);

    await act(async () => {
      await Promise.resolve();
    });

    expect(result.current.products).toHaveLength(1);
    expect(result.current.error).toBeNull();
  });

  it('sets isLoading while the initial fetch is pending, then clears it', async () => {
    let resolveFirst!: (v: Awaited<ReturnType<typeof jsonResponse>>) => void;
    fetchSpy.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          resolveFirst = resolve;
        }) as Promise<Response>,
    );
    fetchSpy.mockImplementation(() => jsonResponse({ products: [], total: 0 }));

    const { result, rerender } = renderHook(({ q }) => useSearchProducts(SEARCH_URL, q), {
      initialProps: { q: '' },
    });

    rerender({ q: 'z' });

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    expect(result.current.isLoading).toBe(true);
    expect(result.current.isLoadingMore).toBe(false);

    await act(async () => {
      resolveFirst(await jsonResponse({ products: [], total: 0 }));
    });

    expect(result.current.isLoading).toBe(false);
  });

  it('sets isLoadingMore while loadMore fetch is pending', async () => {
    fetchSpy
      .mockImplementationOnce(() =>
        jsonResponse({
          products: [{ id: '1', name: 'A', price: 1, currency: 'USD' }],
          total: 2,
        }),
      )
      .mockImplementationOnce(
        () =>
          new Promise<Response>((resolve) => {
            setTimeout(() => {
              void jsonResponse({
                products: [{ id: '2', name: 'B', price: 2, currency: 'USD' }],
                total: 2,
              }).then(resolve);
            }, 50);
          }),
      );

    const { result } = renderHook(({ q }) => useSearchProducts(SEARCH_URL, q), {
      initialProps: { q: 'q' },
    });

    await act(async () => {
      jest.advanceTimersByTime(300);
    });
    await act(async () => {
      await Promise.resolve();
    });

    await act(async () => {
      result.current.loadMore();
    });

    expect(result.current.isLoadingMore).toBe(true);
    expect(result.current.isLoading).toBe(false);

    await act(async () => {
      jest.advanceTimersByTime(50);
    });
    await act(async () => {
      await Promise.resolve();
    });

    expect(result.current.isLoadingMore).toBe(false);
  });

  it('clears debounce timer on unmount', async () => {
    fetchSpy.mockImplementation(() => jsonResponse({ products: [], total: 0 }));

    const { unmount, rerender } = renderHook(({ q }) => useSearchProducts(SEARCH_URL, q), {
      initialProps: { q: 'a' },
    });

    rerender({ q: 'b' });
    unmount();

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('retry re-runs search for current query', async () => {
    fetchSpy.mockImplementation(() => jsonResponse({ products: [], total: 0 }));

    const { result } = renderHook(({ q }) => useSearchProducts(SEARCH_URL, q), {
      initialProps: { q: 'q' },
    });

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    fetchSpy.mockClear();

    await act(async () => {
      result.current.retry();
    });

    await act(async () => {
      await Promise.resolve();
    });

    expect(fetchSpy).toHaveBeenCalled();
  });
});
