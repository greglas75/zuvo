import { act, renderHook, waitFor } from '@testing-library/react';

import { useSearchProducts } from './r2-useSearchProducts';

const PRODUCT_A = { id: 'p-1', name: 'Alpha', price: 10, currency: 'USD' };
const PRODUCT_B = { id: 'p-2', name: 'Beta', price: 20, currency: 'USD' };
const PRODUCT_C = { id: 'p-3', name: 'Gamma', price: 30, currency: 'USD' };
const PRODUCT_D = { id: 'p-4', name: 'Delta', price: 40, currency: 'USD' };

function mockJsonResponse(payload: unknown): Response {
  return {
    ok: true,
    status: 200,
    json: async () => payload,
  } as Response;
}

describe('useSearchProducts (round 3)', () => {
  let fetchSpy: jest.SpyInstance;

  beforeEach(() => {
    jest.useFakeTimers();
    fetchSpy = jest.spyOn(global, 'fetch');
    fetchSpy.mockReset();
  });

  afterEach(() => {
    jest.runOnlyPendingTimers();
    jest.useRealTimers();
    fetchSpy.mockRestore();
  });

  it('debounces search requests and waits 300ms before firing fetch', async () => {
    fetchSpy.mockResolvedValueOnce(
      mockJsonResponse({
        products: [PRODUCT_A, PRODUCT_B],
        total: 2,
      }),
    );

    const { result } = renderHook(() => useSearchProducts('phone', 2));

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
      expect(result.current.products).toHaveLength(2);
    });
  });

  it('aborts in-flight request on query change and on unmount', async () => {
    fetchSpy.mockImplementation(() => new Promise(() => undefined));
    const abortSpy = jest.spyOn(AbortController.prototype, 'abort');

    const { rerender, unmount } = renderHook(({ query }) => useSearchProducts(query, 2), {
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

  it('appends results on loadMore instead of replacing existing products', async () => {
    fetchSpy
      .mockResolvedValueOnce(
        mockJsonResponse({
          products: [PRODUCT_A, PRODUCT_B],
          total: 4,
        }),
      )
      .mockResolvedValueOnce(
        mockJsonResponse({
          products: [PRODUCT_C, PRODUCT_D],
          total: 4,
        }),
      );

    const { result } = renderHook(() => useSearchProducts('bag', 2));

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

  it('retries up to 3 attempts with exponential backoff on failures', async () => {
    fetchSpy
      .mockRejectedValueOnce(new Error('temporary network 1'))
      .mockRejectedValueOnce(new Error('temporary network 2'))
      .mockResolvedValueOnce(
        mockJsonResponse({
          products: [PRODUCT_A],
          total: 1,
        }),
      );

    const { result } = renderHook(() => useSearchProducts('retry-query', 1));

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

  it('keeps isLoading and isLoadingMore mutually exclusive across initial and pagination loads', async () => {
    let resolveInitial: ((response: Response) => void) | undefined;
    let resolveLoadMore: ((response: Response) => void) | undefined;

    fetchSpy
      .mockImplementationOnce(
        () =>
          new Promise<Response>((resolve) => {
            resolveInitial = resolve;
          }),
      )
      .mockImplementationOnce(
        () =>
          new Promise<Response>((resolve) => {
            resolveLoadMore = resolve;
          }),
      );

    const { result } = renderHook(() => useSearchProducts('state-check', 2));

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    await waitFor(() => {
      expect(result.current.isLoading).toBe(true);
      expect(result.current.isLoadingMore).toBe(false);
    });

    await act(async () => {
      resolveInitial?.(
        mockJsonResponse({
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
      resolveLoadMore?.(
        mockJsonResponse({
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

  it('cleans up retry timers on unmount and prevents post-unmount retries', async () => {
    fetchSpy.mockRejectedValueOnce(new Error('transient failure'));

    const { unmount } = renderHook(() => useSearchProducts('cleanup', 2));

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledTimes(1);
    });

    unmount();

    await act(async () => {
      jest.runOnlyPendingTimers();
    });

    expect(fetchSpy).toHaveBeenCalledTimes(1);
  });
});
