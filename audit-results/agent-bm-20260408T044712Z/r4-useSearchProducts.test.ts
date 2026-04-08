/**
 * Tests target r2-useSearchProducts.ts (post-adversarial fixes).
 */

import { act, renderHook, waitFor } from '@testing-library/react';
import { useSearchProducts } from './r2-useSearchProducts';

const BASE = 'https://api.example.com/search';

const PRODUCT_A = { id: 'a', name: 'Alpha', price: 1 };
const PRODUCT_B = { id: 'b', name: 'Beta', price: 2 };

function jsonResponse(data: unknown, ok = true, status = 200) {
  return Promise.resolve({
    ok,
    status,
    json: async () => data,
  } as Response);
}

async function flushDebouncedSearch() {
  await act(async () => {
    jest.advanceTimersByTime(300);
  });
}

describe('useSearchProducts', () => {
  beforeEach(() => {
    jest.resetAllMocks();
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
    jest.restoreAllMocks();
  });

  it('does not fetch until debounce window elapses', async () => {
    const fetchSpy = jest.spyOn(global, 'fetch').mockImplementation(() =>
      jsonResponse({ products: [], total: 0 }),
    );

    renderHook(() => useSearchProducts('hello', BASE));

    expect(fetchSpy).not.toHaveBeenCalled();

    await act(async () => {
      jest.advanceTimersByTime(299);
    });
    expect(fetchSpy).not.toHaveBeenCalled();

    await flushDebouncedSearch();

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledTimes(1);
    });

    const calledUrl = String(fetchSpy.mock.calls[0][0]);
    expect(calledUrl).toContain('q=hello');
  });

  it('aborts the first in-flight fetch when the search input changes', async () => {
    const fetchSpy = jest
      .spyOn(global, 'fetch')
      .mockImplementationOnce((_url, init) => {
        const signal = (init as RequestInit).signal as AbortSignal;
        return new Promise<Response>((resolve, reject) => {
          const onAbort = () => {
            signal.removeEventListener('abort', onAbort);
            const err = new Error('Aborted');
            err.name = 'AbortError';
            reject(err);
          };
          if (signal.aborted) {
            onAbort();
            return;
          }
          signal.addEventListener('abort', onAbort, { once: true });
        });
      })
      .mockImplementation((_url, init) => {
        void init;
        return jsonResponse({ products: [PRODUCT_B], total: 1 });
      });

    const { rerender, result } = renderHook(
      ({ q }) => useSearchProducts(q, BASE),
      { initialProps: { q: 'a' } },
    );

    await flushDebouncedSearch();
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(1));

    const firstInit = fetchSpy.mock.calls[0][1] as RequestInit;
    expect(firstInit?.signal).toBeDefined();

    rerender({ q: 'b' });
    await flushDebouncedSearch();

    await waitFor(() => {
      expect(firstInit.signal?.aborted).toBe(true);
      expect(fetchSpy).toHaveBeenCalledTimes(2);
    });

    await waitFor(() => {
      expect(result.current.products.map((p) => p.id)).toEqual(['b']);
    });
  });

  it('loadMore appends products without replacing prior page', async () => {
    const fetchSpy = jest
      .spyOn(global, 'fetch')
      .mockImplementationOnce(() =>
        jsonResponse({ products: [PRODUCT_A], total: 2 }),
      )
      .mockImplementationOnce(() =>
        jsonResponse({ products: [PRODUCT_B], total: 2 }),
      );

    const { result } = renderHook(() => useSearchProducts('q', BASE));

    await flushDebouncedSearch();

    await waitFor(() => {
      expect(result.current.products).toHaveLength(1);
    });

    await act(async () => {
      result.current.loadMore();
    });

    await waitFor(() => {
      expect(result.current.products.map((p) => p.id)).toEqual(['a', 'b']);
    });

    expect(fetchSpy).toHaveBeenCalledTimes(2);
  });

  it('retries failed fetch with bounded attempts and preserves successful data', async () => {
    let calls = 0;
    const fetchSpy = jest.spyOn(global, 'fetch').mockImplementation(() => {
      calls += 1;
      if (calls < 3) {
        return jsonResponse({}, false, 500);
      }
      return jsonResponse({ products: [PRODUCT_A], total: 1 });
    });

    const { result } = renderHook(() => useSearchProducts('retry', BASE));

    await flushDebouncedSearch();
    expect(fetchSpy).toHaveBeenCalledTimes(1);

    await act(async () => {
      jest.advanceTimersByTime(99);
    });
    expect(fetchSpy).toHaveBeenCalledTimes(1);

    await act(async () => {
      jest.advanceTimersByTime(1);
    });
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(2));

    await act(async () => {
      jest.advanceTimersByTime(199);
    });
    expect(fetchSpy).toHaveBeenCalledTimes(2);

    await act(async () => {
      jest.advanceTimersByTime(1);
    });
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(3));

    await waitFor(() => {
      expect(result.current.error).toBeNull();
      expect(result.current.products).toEqual([PRODUCT_A]);
      expect(result.current.total).toBe(1);
    });
  });

  it('sets error and stops loading after retries are exhausted', async () => {
    jest.spyOn(global, 'fetch').mockImplementation(() => jsonResponse({}, false, 500));

    const { result } = renderHook(() => useSearchProducts('fail', BASE));

    await flushDebouncedSearch();

    await act(async () => {
      jest.advanceTimersByTime(10_000);
    });

    await waitFor(() => {
      expect(result.current.error).toBeTruthy();
      expect(result.current.isLoading).toBe(false);
      expect(result.current.products).toEqual([]);
    });
  });

  it('keeps isLoading false while isLoadingMore is true, then clears loadingMore after fetch', async () => {
    const fetchSpy = jest
      .spyOn(global, 'fetch')
      .mockImplementationOnce(() => jsonResponse({ products: [PRODUCT_A], total: 2 }))
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            setTimeout(
              () =>
                resolve({
                  ok: true,
                  status: 200,
                  json: async () => ({ products: [PRODUCT_B], total: 2 }),
                } as Response),
              50,
            );
          }),
      );

    const { result } = renderHook(() => useSearchProducts('page', BASE));

    await flushDebouncedSearch();

    await waitFor(() => {
      expect(result.current.isLoading).toBe(false);
    });

    await act(async () => {
      result.current.loadMore();
    });

    expect(result.current.isLoading).toBe(false);
    expect(result.current.isLoadingMore).toBe(true);

    await act(async () => {
      jest.advanceTimersByTime(50);
    });

    await waitFor(() => {
      expect(result.current.isLoadingMore).toBe(false);
      expect(result.current.products.map((p) => p.id)).toEqual(['a', 'b']);
    });

    expect(fetchSpy).toHaveBeenCalledTimes(2);
  });

  it('does not update state after unmount', async () => {
    const fetchSpy = jest.spyOn(global, 'fetch').mockImplementation(
      () =>
        new Promise((resolve) => {
          setTimeout(
            () =>
              resolve({
                ok: true,
                status: 200,
                json: async () => ({ products: [PRODUCT_A], total: 1 }),
              } as Response),
            200,
          );
        }),
    );

    const { unmount } = renderHook(() => useSearchProducts('gone', BASE));

    await flushDebouncedSearch();

    unmount();

    await act(async () => {
      jest.advanceTimersByTime(500);
    });

    expect(fetchSpy).toHaveBeenCalled();
  });
});
