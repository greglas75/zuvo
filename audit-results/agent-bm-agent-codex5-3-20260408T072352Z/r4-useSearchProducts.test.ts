import { act, renderHook, waitFor } from '@testing-library/react';

import { useSearchProducts } from './r2-useSearchProducts';

const PRODUCT_A = { id: 'p-1', name: 'Alpha', price: 10, currency: 'USD' };
const PRODUCT_B = { id: 'p-2', name: 'Beta', price: 20, currency: 'USD' };
const PRODUCT_C = { id: 'p-3', name: 'Gamma', price: 30, currency: 'USD' };
const PRODUCT_D = { id: 'p-4', name: 'Delta', price: 40, currency: 'USD' };
const PRODUCT_NEW = { id: 'p-9', name: 'New', price: 99, currency: 'USD' };

function mockJsonResponse(payload: unknown): Response {
  return {
    ok: true,
    status: 200,
    json: async () => payload,
  } as Response;
}

function mockErrorResponse(status: number): Response {
  return {
    ok: false,
    status,
    json: async () => ({}),
  } as Response;
}

async function flushDebounce(): Promise<void> {
  await act(async () => {
    jest.advanceTimersByTime(300);
  });
}

describe('useSearchProducts (round 4)', () => {
  let fetchSpy: jest.SpyInstance;

  beforeEach(() => {
    jest.useFakeTimers();
    fetchSpy = jest.spyOn(global, 'fetch');
  });

  afterEach(() => {
    jest.clearAllTimers();
    jest.useRealTimers();
    jest.restoreAllMocks();
  });

  it('debounces search requests and does not fetch before 300ms', async () => {
    fetchSpy.mockResolvedValueOnce(
      mockJsonResponse({
        products: [PRODUCT_A, PRODUCT_B],
        total: 2,
      }),
    );

    const { result } = renderHook(() => useSearchProducts('phone', 2));

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
  });

  it('passes AbortController signal to fetch and aborts old/new requests on rerender and unmount', async () => {
    fetchSpy.mockImplementation(() => new Promise(() => undefined));

    const { rerender, unmount } = renderHook(({ query }) => useSearchProducts(query, 2), {
      initialProps: { query: 'a' },
    });

    await flushDebounce();

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledTimes(1);
      expect(fetchSpy).toHaveBeenCalledWith(
        expect.any(String),
        expect.objectContaining({ signal: expect.any(AbortSignal) }),
      );
    });

    const firstSignal = (fetchSpy.mock.calls[0][1] as RequestInit).signal as AbortSignal;
    expect(firstSignal.aborted).toBe(false);

    rerender({ query: 'ab' });
    expect(firstSignal.aborted).toBe(true);

    await flushDebounce();
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledTimes(2);
    });

    const secondSignal = (fetchSpy.mock.calls[1][1] as RequestInit).signal as AbortSignal;
    expect(secondSignal.aborted).toBe(false);

    unmount();
    expect(secondSignal.aborted).toBe(true);
  });

  it('ignores stale aborted response and only applies latest query result', async () => {
    let resolveFirst: ((value: Response) => void) | undefined;
    let resolveSecond: ((value: Response) => void) | undefined;

    fetchSpy
      .mockImplementationOnce(
        () =>
          new Promise<Response>((resolve) => {
            resolveFirst = resolve;
          }),
      )
      .mockImplementationOnce(
        () =>
          new Promise<Response>((resolve) => {
            resolveSecond = resolve;
          }),
      );

    const { result, rerender } = renderHook(({ query }) => useSearchProducts(query, 2), {
      initialProps: { query: 'old' },
    });

    await flushDebounce();
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(1));

    rerender({ query: 'new' });
    await flushDebounce();
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(2));

    await act(async () => {
      resolveFirst?.(
        mockJsonResponse({
          products: [PRODUCT_A],
          total: 1,
        }),
      );
    });

    await act(async () => {
      resolveSecond?.(
        mockJsonResponse({
          products: [PRODUCT_NEW],
          total: 1,
        }),
      );
    });

    await waitFor(() => {
      expect(result.current.products).toEqual([PRODUCT_NEW]);
      expect(result.current.error).toBeNull();
    });
  });

  it('appends results on loadMore and sends correct skip offset for next page', async () => {
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

    await flushDebounce();

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
      expect(fetchSpy).toHaveBeenCalledTimes(2);
    });

    const secondUrl = fetchSpy.mock.calls[1][0] as string;
    expect(secondUrl).toContain('skip=2');
    expect(secondUrl).toContain('take=2');
  });

  it('retries with exponential backoff boundaries (300ms then 600ms)', async () => {
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

    await flushDebounce();
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(1));

    await act(async () => {
      jest.advanceTimersByTime(299);
    });
    expect(fetchSpy).toHaveBeenCalledTimes(1);

    await act(async () => {
      jest.advanceTimersByTime(1);
    });
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(2));

    await act(async () => {
      jest.advanceTimersByTime(599);
    });
    expect(fetchSpy).toHaveBeenCalledTimes(2);

    await act(async () => {
      jest.advanceTimersByTime(1);
    });
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledTimes(3);
      expect(result.current.products).toEqual([PRODUCT_A]);
      expect(result.current.error).toBeNull();
    });
  });

  it('surfaces terminal error after retries exhausted for non-ok HTTP response', async () => {
    fetchSpy.mockResolvedValue(mockErrorResponse(500));

    const { result } = renderHook(() => useSearchProducts('http-error', 2));

    await flushDebounce();
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(1));

    await act(async () => {
      jest.advanceTimersByTime(300);
    });
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(2));

    await act(async () => {
      jest.advanceTimersByTime(600);
    });
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(3));

    await waitFor(() => {
      expect(result.current.error).toContain('status 500');
      expect(result.current.isLoading).toBe(false);
      expect(result.current.isLoadingMore).toBe(false);
      expect(result.current.products).toEqual([]);
    });
  });

  it('retry() replays the last failed request and clears error after success', async () => {
    fetchSpy
      .mockRejectedValueOnce(new Error('network 1'))
      .mockRejectedValueOnce(new Error('network 2'))
      .mockRejectedValueOnce(new Error('network 3'));

    const { result } = renderHook(() => useSearchProducts('retry-api', 2));

    await flushDebounce();
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(1));

    await act(async () => {
      jest.advanceTimersByTime(300);
    });
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(2));

    await act(async () => {
      jest.advanceTimersByTime(600);
    });
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(3));

    await waitFor(() => {
      expect(result.current.error).toContain('network 3');
    });

    fetchSpy.mockResolvedValueOnce(
      mockJsonResponse({
        products: [PRODUCT_A],
        total: 1,
      }),
    );

    await act(async () => {
      result.current.retry();
    });

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledTimes(4);
      expect(result.current.products).toEqual([PRODUCT_A]);
      expect(result.current.error).toBeNull();
    });
  });

  it('keeps isLoading and isLoadingMore mutually exclusive for initial and loadMore fetches', async () => {
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

    await flushDebounce();

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

  it('cleans up retry timers on unmount and prevents post-unmount retry calls', async () => {
    fetchSpy.mockRejectedValueOnce(new Error('transient failure'));

    const { unmount } = renderHook(() => useSearchProducts('cleanup', 2));

    await flushDebounce();
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(1));

    unmount();

    await act(async () => {
      jest.runOnlyPendingTimers();
    });

    expect(fetchSpy).toHaveBeenCalledTimes(1);
  });
});
