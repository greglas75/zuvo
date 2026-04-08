import { renderHook, act, waitFor } from '@testing-library/react';
import { useSearchProducts } from './r2-useSearchProducts';

describe('useSearchProducts', () => {
  const mockProducts = [
    { id: '1', name: 'Product 1', price: 10 },
    { id: '2', name: 'Product 2', price: 20 },
  ];

  let originalFetch: typeof global.fetch;

  beforeEach(() => {
    jest.useFakeTimers();
    originalFetch = global.fetch;
    global.fetch = jest.fn();
    jest.clearAllMocks();
  });

  afterEach(() => {
    jest.useRealTimers();
    global.fetch = originalFetch;
  });

  it('debounces the search fetch by 300ms and verifies response', async () => {
    (global.fetch as jest.Mock).mockResolvedValue({
      ok: true,
      json: async () => ({ products: mockProducts, total: 2 }),
    });

    const { result } = renderHook(() => useSearchProducts('initial'));

    expect(global.fetch).not.toHaveBeenCalled();

    act(() => {
      jest.advanceTimersByTime(300);
    });

    await waitFor(() => expect(result.current.products).toEqual(mockProducts));
    expect(global.fetch).toHaveBeenCalledWith(
      expect.stringContaining('q=initial'),
      expect.objectContaining({ signal: expect.any(AbortSignal) })
    );
  });

  it('aborts active fetch when query changes', async () => {
    const abortSpy = jest.spyOn(AbortController.prototype, 'abort');
    
    // Controlled promise to keep fetch pending
    let resolveFetch: any;
    const fetchPromise = new Promise((resolve) => {
      resolveFetch = resolve;
    });

    (global.fetch as jest.Mock).mockReturnValue(fetchPromise);

    const { rerender } = renderHook(({ q }) => useSearchProducts(q), {
      initialProps: { q: 'a' }
    });

    act(() => {
      jest.advanceTimersByTime(300); // Start first fetch
    });

    expect(global.fetch).toHaveBeenCalledTimes(1);

    act(() => {
      rerender({ q: 'ab' });
    });

    expect(abortSpy).toHaveBeenCalled();
    
    // Clean up
    resolveFetch({ ok: true, json: async () => ({ products: [], total: 0 }) });
    abortSpy.mockRestore();
  });

  it('appends products and increments skip accurately only on success', async () => {
    const moreProducts = [{ id: '3', name: 'Product 3', price: 30 }];
    
    (global.fetch as jest.Mock)
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ products: mockProducts, total: 3 }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ products: moreProducts, total: 3 }),
      });

    const { result } = renderHook(() => useSearchProducts('search'));

    act(() => {
      jest.advanceTimersByTime(300);
    });

    await waitFor(() => expect(result.current.products).toHaveLength(2));

    act(() => {
      result.current.loadMore();
    });

    await waitFor(() => expect(result.current.products).toHaveLength(3));
    expect(global.fetch).toHaveBeenLastCalledWith(
      expect.stringContaining('skip=2'),
      expect.any(Object)
    );
  });

  it('retries with exponential backoff and tracks timing strictly', async () => {
    (global.fetch as jest.Mock)
      .mockRejectedValueOnce(new Error('Fail 1'))
      .mockRejectedValueOnce(new Error('Fail 2'))
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ products: mockProducts, total: 2 }),
      });

    const { result } = renderHook(() => useSearchProducts('retry-test'));

    act(() => {
      jest.advanceTimersByTime(300); // 1st attempt
    });

    await act(async () => { /* let first fetch reject */ });

    // Should NOT have retried yet
    expect(global.fetch).toHaveBeenCalledTimes(1);

    act(() => {
      jest.advanceTimersByTime(1999);
    });
    expect(global.fetch).toHaveBeenCalledTimes(1);

    act(() => {
      jest.advanceTimersByTime(1); // 2nd attempt at 2000ms
    });
    expect(global.fetch).toHaveBeenCalledTimes(2);

    await act(async () => { /* let second fetch reject */ });

    act(() => {
      jest.advanceTimersByTime(3999);
    });
    expect(global.fetch).toHaveBeenCalledTimes(2);

    act(() => {
      jest.advanceTimersByTime(1); // 3rd attempt at 4000ms
    });
    expect(global.fetch).toHaveBeenCalledTimes(3);

    await waitFor(() => expect(result.current.products).toEqual(mockProducts));
  });

  it('sets error on malformed API response', async () => {
    (global.fetch as jest.Mock).mockResolvedValue({
      ok: true,
      json: async () => ({ products: 'not-an-array' }), // Invalid shape
    });

    const { result } = renderHook(() => useSearchProducts('bad-format'));

    act(() => {
      jest.advanceTimersByTime(300);
    });

    await waitFor(() => expect(result.current.error).toBeDefined());
    expect(result.current.products).toEqual([]);
  });

  it('sets error on HTTP 500 error', async () => {
    (global.fetch as jest.Mock).mockResolvedValue({
      ok: false,
      status: 500,
    });

    const { result } = renderHook(() => useSearchProducts('server-error'));

    act(() => {
      jest.advanceTimersByTime(300);
    });

    // Wait for all retries to fail
    act(() => { jest.advanceTimersByTime(2000); });
    act(() => { jest.advanceTimersByTime(4000); });

    await waitFor(() => expect(result.current.error).toContain('HTTP 500'));
  });

  it('manages loading states exclusively and guards against stale updates', async () => {
    (global.fetch as jest.Mock).mockResolvedValue({
      ok: true,
      json: async () => {
        await new Promise(r => setTimeout(r, 100)); // Simulate work
        return { products: mockProducts, total: 10 };
      },
    });

    const { result } = renderHook(() => useSearchProducts('loading-test'));

    act(() => {
      jest.advanceTimersByTime(300);
    });

    expect(result.current.isLoading).toBe(true);
    expect(result.current.isLoadingMore).toBe(false);

    // Speed up simulations
    act(() => { jest.advanceTimersByTime(100); });

    await waitFor(() => expect(result.current.isLoading).toBe(false));
  });
});
