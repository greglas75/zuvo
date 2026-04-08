import { act, renderHook } from '@testing-library/react';

import { useSearchProducts } from './r2-useSearchProducts';

const SEARCH_QUERY = 'keyboard';
const NEXT_QUERY = 'monitor';
const PAGE_SIZE = 2;
const FIRST_PAGE_TOTAL = 4;
const SECOND_PAGE_TOTAL = 2;
const HTTP_500 = 500;

const PRODUCT_A = { id: 'product-a', name: 'Keyboard', price: 99.99, currency: 'USD' };
const PRODUCT_B = { id: 'product-b', name: 'Mouse', price: 49.99, currency: 'USD' };
const PRODUCT_C = { id: 'product-c', name: 'Monitor', price: 199.99, currency: 'USD' };
const PRODUCT_D = { id: 'product-d', name: 'Headset', price: 89.99, currency: 'USD' };

describe('useSearchProducts', () => {
  let fetchSpy: jest.SpiedFunction<typeof fetch>;

  beforeEach(() => {
    jest.useFakeTimers();
    jest.clearAllMocks();
    global.fetch = jest.fn() as unknown as typeof fetch;
    fetchSpy = jest.spyOn(global, 'fetch');
  });

  afterEach(() => {
    fetchSpy.mockRestore();
    jest.runOnlyPendingTimers();
    jest.useRealTimers();
  });

  it('waits for the debounce window before fetching', async () => {
    fetchSpy.mockResolvedValue(
      createFetchResponse({
        products: [PRODUCT_A],
        total: 1,
      }),
    );

    const { result } = renderHook(
      ({ query }) => useSearchProducts(query),
      { initialProps: { query: SEARCH_QUERY } },
    );

    expect(fetchSpy).not.toHaveBeenCalled();

    await advanceAndFlush(299);
    expect(fetchSpy).not.toHaveBeenCalled();

    await advanceAndFlush(1);

    expect(fetchSpy).toHaveBeenCalledTimes(1);
    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining(`q=${SEARCH_QUERY}`),
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    );
    expect(result.current.products).toEqual([PRODUCT_A]);
    expect(result.current.total).toBe(1);
  });

  it('aborts the in-flight request when the query changes and again on unmount', async () => {
    const abortSpy = jest
      .spyOn(AbortController.prototype, 'abort')
      .mockImplementation(() => undefined);
    const firstRequest = createDeferred<Response>();

    fetchSpy.mockImplementation(() => firstRequest.promise);

    const { rerender, unmount } = renderHook(
      ({ query }) => useSearchProducts(query),
      { initialProps: { query: SEARCH_QUERY } },
    );

    await advanceAndFlush(300);
    expect(fetchSpy).toHaveBeenCalledTimes(1);

    rerender({ query: NEXT_QUERY });
    expect(abortSpy).toHaveBeenCalledTimes(1);

    unmount();
    expect(abortSpy).toHaveBeenCalledTimes(2);

    abortSpy.mockRestore();
  });

  it('appends products instead of replacing them when loadMore succeeds', async () => {
    fetchSpy
      .mockResolvedValueOnce(
        createFetchResponse({
          products: [PRODUCT_A, PRODUCT_B],
          total: FIRST_PAGE_TOTAL,
        }),
      )
      .mockResolvedValueOnce(
        createFetchResponse({
          products: [PRODUCT_C, PRODUCT_D],
          total: FIRST_PAGE_TOTAL,
        }),
      );

    const { result } = renderHook(() =>
      useSearchProducts(SEARCH_QUERY, { pageSize: PAGE_SIZE }),
    );

    await advanceAndFlush(300);

    expect(result.current.products.map((product) => product.id)).toEqual([
      PRODUCT_A.id,
      PRODUCT_B.id,
    ]);
    expect(result.current.hasMore).toBe(true);

    await act(async () => {
      await result.current.loadMore();
      await flushMicrotasks();
    });

    expect(result.current.products.map((product) => product.id)).toEqual([
      PRODUCT_A.id,
      PRODUCT_B.id,
      PRODUCT_C.id,
      PRODUCT_D.id,
    ]);
    expect(result.current.hasMore).toBe(false);
  });

  it('retries failed searches up to three times with exponential backoff', async () => {
    fetchSpy.mockResolvedValue(createFetchResponse({}, HTTP_500));

    const { result } = renderHook(() => useSearchProducts(SEARCH_QUERY));

    await advanceAndFlush(300);
    expect(fetchSpy).toHaveBeenCalledTimes(1);

    await advanceAndFlush(300);
    expect(fetchSpy).toHaveBeenCalledTimes(2);

    await advanceAndFlush(600);
    expect(fetchSpy).toHaveBeenCalledTimes(3);

    expect(result.current.error?.message).toBe(
      `Product search failed with status ${HTTP_500}`,
    );
  });

  it('keeps isLoading and isLoadingMore mutually exclusive', async () => {
    const initialRequest = createDeferred<Response>();
    const loadMoreRequest = createDeferred<Response>();

    fetchSpy
      .mockImplementationOnce(() => initialRequest.promise)
      .mockImplementationOnce(() => loadMoreRequest.promise);

    const { result } = renderHook(() =>
      useSearchProducts(SEARCH_QUERY, { pageSize: 1 }),
    );

    await advanceAndFlush(300);

    expect(result.current.isLoading).toBe(true);
    expect(result.current.isLoadingMore).toBe(false);

    await act(async () => {
      initialRequest.resolve(
        createFetchResponse({
          products: [PRODUCT_A],
          total: SECOND_PAGE_TOTAL,
        }),
      );
      await flushMicrotasks();
    });

    expect(result.current.isLoading).toBe(false);
    expect(result.current.isLoadingMore).toBe(false);

    act(() => {
      void result.current.loadMore();
    });

    expect(result.current.isLoading).toBe(false);
    expect(result.current.isLoadingMore).toBe(true);

    await act(async () => {
      loadMoreRequest.resolve(
        createFetchResponse({
          products: [PRODUCT_B],
          total: SECOND_PAGE_TOTAL,
        }),
      );
      await flushMicrotasks();
    });

    expect(result.current.isLoading).toBe(false);
    expect(result.current.isLoadingMore).toBe(false);
  });

  it('clears pending debounce timers on unmount before a request starts', () => {
    const { unmount } = renderHook(() => useSearchProducts(SEARCH_QUERY));

    expect(jest.getTimerCount()).toBe(1);

    unmount();

    expect(fetchSpy).not.toHaveBeenCalled();
    expect(jest.getTimerCount()).toBe(0);
  });

  it('avoids state updates after unmount and lets retry rerun the last failed request', async () => {
    const abortSpy = jest
      .spyOn(AbortController.prototype, 'abort')
      .mockImplementation(() => undefined);
    const consoleErrorSpy = jest
      .spyOn(console, 'error')
      .mockImplementation(() => undefined);
    const pendingRequest = createDeferred<Response>();

    fetchSpy
      .mockImplementationOnce(() => pendingRequest.promise)
      .mockResolvedValueOnce(createFetchResponse({}, HTTP_500))
      .mockResolvedValueOnce(createFetchResponse({}, HTTP_500))
      .mockResolvedValueOnce(createFetchResponse({}, HTTP_500))
      .mockResolvedValueOnce(
        createFetchResponse({
          products: [PRODUCT_A],
          total: 1,
        }),
      );

    const { result, unmount } = renderHook(() => useSearchProducts(SEARCH_QUERY));

    await advanceAndFlush(300);
    unmount();

    expect(abortSpy).toHaveBeenCalled();

    await act(async () => {
      pendingRequest.resolve(
        createFetchResponse({
          products: [PRODUCT_A],
          total: 1,
        }),
      );
      await flushMicrotasks();
    });

    expect(consoleErrorSpy).not.toHaveBeenCalled();

    const retryRender = renderHook(() => useSearchProducts(SEARCH_QUERY));

    await advanceAndFlush(300);
    await advanceAndFlush(300);
    await advanceAndFlush(600);

    expect(retryRender.result.current.error?.message).toBe(
      `Product search failed with status ${HTTP_500}`,
    );

    await act(async () => {
      await retryRender.result.current.retry();
      await flushMicrotasks();
    });

    expect(retryRender.result.current.products).toEqual([PRODUCT_A]);
    expect(retryRender.result.current.error).toBeNull();

    retryRender.unmount();
    abortSpy.mockRestore();
    consoleErrorSpy.mockRestore();
  });
});

function createFetchResponse(
  body: Record<string, unknown>,
  status = 200,
): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: jest.fn().mockResolvedValue(body),
  } as unknown as Response;
}

function createDeferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;

  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });

  return { promise, resolve, reject };
}

async function flushMicrotasks(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}

async function advanceAndFlush(milliseconds: number): Promise<void> {
  await act(async () => {
    jest.advanceTimersByTime(milliseconds);
    await flushMicrotasks();
  });
}
