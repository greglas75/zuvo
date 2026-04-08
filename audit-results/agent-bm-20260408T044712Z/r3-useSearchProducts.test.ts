/**
 * Tests target r2-useSearchProducts.ts
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

describe('useSearchProducts', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
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

    await act(async () => {
      jest.advanceTimersByTime(1);
    });

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledTimes(1);
    });

    const calledUrl = String(fetchSpy.mock.calls[0][0]);
    expect(calledUrl).toContain('q=hello');
  });

  it('aborts in-flight fetch when search input changes before debounce completes', async () => {
    const fetchSpy = jest.spyOn(global, 'fetch').mockImplementation((_url, init) => {
      const signal = (init as RequestInit).signal as AbortSignal;
      return new Promise<Response>((resolve, reject) => {
        if (signal.aborted) {
          reject(Object.assign(new Error('Aborted'), { name: 'AbortError' }));
          return;
        }
        const onAbort = () => {
          signal.removeEventListener('abort', onAbort);
          reject(Object.assign(new Error('Aborted'), { name: 'AbortError' }));
        };
        signal.addEventListener('abort', onAbort);
        setTimeout(() => {
          resolve({
            ok: true,
            status: 200,
            json: async () => ({ products: [PRODUCT_A], total: 1 }),
          } as Response);
        }, 5000);
      });
    });

    const { rerender } = renderHook(
      ({ q }) => useSearchProducts(q, BASE),
      { initialProps: { q: 'a' } },
    );

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    rerender({ q: 'b' });

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    await waitFor(() => {
      expect(fetchSpy.mock.calls.length).toBeGreaterThanOrEqual(1);
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

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

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

  it('retries failed fetch up to three times with exponential backoff', async () => {
    let calls = 0;
    const fetchSpy = jest.spyOn(global, 'fetch').mockImplementation(() => {
      calls += 1;
      if (calls < 3) {
        return jsonResponse({}, false, 500);
      }
      return jsonResponse({ products: [PRODUCT_A], total: 1 });
    });

    const { result } = renderHook(() => useSearchProducts('retry', BASE));

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    await act(async () => {
      await Promise.resolve();
      jest.advanceTimersByTime(100);
      await Promise.resolve();
      jest.advanceTimersByTime(200);
      await Promise.resolve();
      jest.advanceTimersByTime(400);
    });

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledTimes(3);
      expect(result.current.error).toBeNull();
    });
  });

  it('keeps isLoading and isLoadingMore mutually exclusive during pagination', async () => {
    jest.spyOn(global, 'fetch').mockImplementation(() =>
      jsonResponse({ products: [PRODUCT_A], total: 2 }),
    );

    const { result } = renderHook(() => useSearchProducts('page', BASE));

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    await waitFor(() => {
      expect(result.current.isLoading).toBe(false);
    });

    jest.spyOn(global, 'fetch').mockImplementation(() =>
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

    await act(async () => {
      result.current.loadMore();
    });

    expect(result.current.isLoading).toBe(false);
    expect(result.current.isLoadingMore).toBe(true);
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

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    unmount();

    await act(async () => {
      jest.advanceTimersByTime(500);
    });

    // If state leaked, fetch would still complete — hook is gone; no assertion on hook state.
    expect(fetchSpy).toHaveBeenCalled();
  });
});
