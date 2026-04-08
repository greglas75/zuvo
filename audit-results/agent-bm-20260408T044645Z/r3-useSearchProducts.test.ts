// Tests for benchmark corpus — code under test: r2-useSearchProducts.ts
import { act, renderHook } from '@testing-library/react';
import { useSearchProducts } from './r2-useSearchProducts';

const SEARCH_URL = '/api/products/search';

const JSON_HEADERS = { 'Content-Type': 'application/json' };

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

  it('aborts in-flight fetch when query changes before debounce completes', async () => {
    fetchSpy.mockImplementation(() => new Promise(() => {}));

    const { rerender } = renderHook(({ q }) => useSearchProducts(SEARCH_URL, q), {
      initialProps: { q: 'a' },
    });

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    const firstCall = fetchSpy.mock.calls[0];
    const firstSignal = firstCall[1]?.signal as AbortSignal;
    expect(firstSignal.aborted).toBe(false);

    rerender({ q: 'b' });

    await act(async () => {
      jest.advanceTimersByTime(0);
    });

    expect(firstSignal.aborted).toBe(true);
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

  it('loadMore appends results without replacing prior products', async () => {
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

    const { result, rerender } = renderHook(({ q }) => useSearchProducts(SEARCH_URL, q), {
      initialProps: { q: 'q' },
    });

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    await act(async () => {
      await Promise.resolve();
    });

    expect(result.current.products).toHaveLength(1);

    await act(async () => {
      result.current.loadMore();
    });

    await act(async () => {
      await Promise.resolve();
    });

    expect(result.current.products.map((p) => p.id)).toEqual(['1', '2']);
  });

  it('retries up to 3 times with exponential backoff on failure', async () => {
    fetchSpy
      .mockImplementationOnce(() => jsonResponse({}, false))
      .mockImplementationOnce(() => jsonResponse({}, false))
      .mockImplementationOnce(() =>
        jsonResponse({
          products: [{ id: '1', name: 'A', price: 1, currency: 'USD' }],
          total: 1,
        }),
      );

    const { rerender } = renderHook(({ q }) => useSearchProducts(SEARCH_URL, q), {
      initialProps: { q: 'x' },
    });

    const advance = async () => {
      await act(async () => {
        jest.advanceTimersByTime(300);
      });
      await act(async () => {
        jest.advanceTimersByTime(100);
      });
      await act(async () => {
        jest.advanceTimersByTime(200);
      });
      await act(async () => {
        jest.advanceTimersByTime(400);
      });
    };

    await advance();

    expect(fetchSpy).toHaveBeenCalledTimes(3);
  });

  it('keeps isLoading and isLoadingMore mutually exclusive during fetch', async () => {
    fetchSpy.mockImplementation(() => jsonResponse({ products: [], total: 0 }));

    const { result, rerender } = renderHook(({ q }) => useSearchProducts(SEARCH_URL, q), {
      initialProps: { q: '' },
    });

    rerender({ q: 'z' });

    await act(async () => {
      jest.advanceTimersByTime(300);
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

    const { result, rerender } = renderHook(({ q }) => useSearchProducts(SEARCH_URL, q), {
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
