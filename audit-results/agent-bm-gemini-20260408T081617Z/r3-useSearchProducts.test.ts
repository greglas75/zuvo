import { renderHook, act } from '@testing-library/react';
import { useSearchProducts } from './r2-useSearchProducts';

describe('useSearchProducts', () => {
  const mockProducts = [
    { id: '1', name: 'Product 1', price: 10 },
    { id: '2', name: 'Product 2', price: 20 },
  ];

  beforeEach(() => {
    jest.useFakeTimers();
    global.fetch = jest.fn();
    jest.clearAllMocks();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('debounces the search fetch by 300ms', async () => {
    (global.fetch as jest.Mock).mockResolvedValue({
      ok: true,
      json: async () => ({ products: mockProducts, total: 2 }),
    });

    const { result } = renderHook(() => useSearchProducts('initial'));

    expect(global.fetch).not.toHaveBeenCalled();

    act(() => {
      jest.advanceTimersByTime(300);
    });

    await act(async () => {
      // Allow promises to resolve
    });

    expect(global.fetch).toHaveBeenCalledWith(
      expect.stringContaining('q=initial'),
      expect.any(Object)
    );
    expect(result.current.products).toEqual(mockProducts);
  });

  it('aborts previous request when query changes', async () => {
    const abortSpy = jest.spyOn(AbortController.prototype, 'abort');
    
    const { rerender } = renderHook(({ q }) => useSearchProducts(q), {
      initialProps: { q: 'a' }
    });

    act(() => {
      jest.advanceTimersByTime(300);
    });

    act(() => {
      rerender({ q: 'ab' });
    });

    expect(abortSpy).toHaveBeenCalled();
    abortSpy.mockRestore();
  });

  it('appends products when loadMore is called', async () => {
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

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    expect(result.current.products).toHaveLength(2);

    await act(async () => {
      result.current.loadMore();
    });

    expect(result.current.products).toHaveLength(3);
    expect(result.current.products[2]).toEqual(moreProducts[0]);
  });

  it('retries on failure with exponential backoff (up to 3 attempts total)', async () => {
    (global.fetch as jest.Mock)
      .mockRejectedValueOnce(new Error('Fail 1'))
      .mockRejectedValueOnce(new Error('Fail 2'))
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ products: mockProducts, total: 2 }),
      });

    renderHook(() => useSearchProducts('retry-test'));

    await act(async () => {
      jest.advanceTimersByTime(300); // Trigger first fetch
    });

    // Attempt 1 failed. Wait for 2s backoff.
    await act(async () => {
      jest.advanceTimersByTime(2000);
    });

    // Attempt 2 failed. Wait for 4s backoff.
    await act(async () => {
      jest.advanceTimersByTime(4000);
    });

    expect(global.fetch).toHaveBeenCalledTimes(3);
  });

  it('sets error after 3 failed attempts', async () => {
    (global.fetch as jest.Mock).mockRejectedValue(new Error('Permanent Fail'));

    const { result } = renderHook(() => useSearchProducts('fail-test'));

    await act(async () => {
      jest.advanceTimersByTime(300);
    });

    // Backoff 1 (2s)
    await act(async () => {
      jest.advanceTimersByTime(2000);
    });

    // Backoff 2 (4s)
    await act(async () => {
      jest.advanceTimersByTime(4000);
    });

    expect(result.current.error).toBe('Permanent Fail');
  });

  it('cleans up on unmount', () => {
    const abortSpy = jest.spyOn(AbortController.prototype, 'abort');
    const { unmount } = renderHook(() => useSearchProducts('unmount'));

    unmount();

    expect(abortSpy).toHaveBeenCalled();
    abortSpy.mockRestore();
  });

  it('isLoading and isLoadingMore are managed correctly', async () => {
    (global.fetch as jest.Mock).mockResolvedValue({
      ok: true,
      json: async () => ({ products: mockProducts, total: 10 }),
    });

    const { result } = renderHook(() => useSearchProducts('loading-test'));

    expect(result.current.isLoading).toBe(false);

    act(() => {
      jest.advanceTimersByTime(300);
    });

    // During fetch
    expect(result.current.isLoading).toBe(true);
    expect(result.current.isLoadingMore).toBe(false);

    await act(async () => { /* resolve fetch */ });

    expect(result.current.isLoading).toBe(false);

    // Load more
    act(() => {
      result.current.loadMore();
    });

    expect(result.current.isLoading).toBe(false);
    expect(result.current.isLoadingMore).toBe(true);

    await act(async () => { /* resolve fetch */ });

    expect(result.current.isLoadingMore).toBe(false);
  });
});
