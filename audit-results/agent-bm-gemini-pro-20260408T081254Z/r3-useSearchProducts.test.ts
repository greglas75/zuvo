import { renderHook, act } from '@testing-library/react';
import { useSearchProducts } from './r2-useSearchProducts';

describe('useSearchProducts', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    jest.spyOn(global, 'fetch');
  });

  afterEach(() => {
    jest.runOnlyPendingTimers();
    jest.useRealTimers();
    jest.restoreAllMocks();
  });

  const mockSuccessResponse = (total = 10, products = [{ id: 'p1', name: 'Product 1', price: 100 }]) => {
    (global.fetch as jest.Mock).mockResolvedValue({
      ok: true,
      json: jest.fn().mockResolvedValue({ total, products })
    });
  };

  const mockErrorResponse = (status = 500) => {
    (global.fetch as jest.Mock).mockResolvedValue({
      ok: false,
      status,
      json: jest.fn().mockResolvedValue({})
    });
  };

  it('initially does not fetch until 300ms debounce passes', () => {
    mockSuccessResponse();
    const { result } = renderHook(() => useSearchProducts('test'));

    expect(global.fetch).not.toHaveBeenCalled();
    expect(result.current.isLoading).toBe(false);

    act(() => {
      jest.advanceTimersByTime(299);
    });
    expect(global.fetch).not.toHaveBeenCalled();

    act(() => {
      jest.advanceTimersByTime(1);
    });
    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(global.fetch).toHaveBeenCalledWith(
        `/api/products?q=test&page=1`,
        expect.objectContaining({ signal: expect.any(AbortSignal) })
    );
  });

  it('aborts controller if query changes quickly', () => {
    mockSuccessResponse();
    const { result, rerender } = renderHook(({ query }) => useSearchProducts(query), {
        initialProps: { query: 'test' }
    });

    act(() => {
       jest.advanceTimersByTime(150);
    });
    
    rerender({ query: 'test2' });

    act(() => {
       jest.advanceTimersByTime(300);
    });
    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect((global.fetch as jest.Mock).mock.calls[0][0]).toBe('/api/products?q=test2&page=1');
  });

  it('updates state with result on success', async () => {
    mockSuccessResponse();
    const { result } = renderHook(() => useSearchProducts('good'));

    act(() => {
        jest.advanceTimersByTime(300);
    });

    await act(async () => {
        await Promise.resolve();
        await Promise.resolve();
    });

    expect(result.current.isLoading).toBe(false);
    expect(result.current.products).toHaveLength(1);
    expect(result.current.products[0].id).toBe('p1');
    expect(result.current.total).toBe(10);
    expect(result.current.error).toBeNull();
  });

  it('handles loadMore correctly (appends)', async () => {
    mockSuccessResponse(20, [{ id: 'p1', name: 'Product 1', price: 100 }]);
    const { result } = renderHook(() => useSearchProducts('good'));

    act(() => { jest.advanceTimersByTime(300); });
    await act(async () => { await Promise.resolve(); await Promise.resolve(); });

    expect(result.current.products).toHaveLength(1);
    
    // Simulate loadMore
    mockSuccessResponse(20, [{ id: 'p2', name: 'Product 2', price: 200 }]);
    
    act(() => {
       result.current.loadMore();
    });

    expect(result.current.isLoadingMore).toBe(true);
    expect(result.current.isLoading).toBe(false);

    await act(async () => { await Promise.resolve(); await Promise.resolve(); });

    expect(result.current.products).toHaveLength(2);
    expect(result.current.products[1].id).toBe('p2');
    expect(result.current.isLoadingMore).toBe(false);
  });

  it('retries with exponential backoff on 5xx errors (up to 3 times)', async () => {
    mockErrorResponse(500);
    const { result } = renderHook(() => useSearchProducts('retry'));

    act(() => { jest.advanceTimersByTime(300); });
    await act(async () => { await Promise.resolve(); await Promise.resolve(); });

    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(result.current.error).toBeNull();

    act(() => { jest.advanceTimersByTime(1000); });
    await act(async () => { await Promise.resolve(); await Promise.resolve(); });
    expect(global.fetch).toHaveBeenCalledTimes(2);

    act(() => { jest.advanceTimersByTime(2000); });
    await act(async () => { await Promise.resolve(); await Promise.resolve(); });
    expect(global.fetch).toHaveBeenCalledTimes(3);
    
    act(() => { jest.advanceTimersByTime(4000); });
    await act(async () => { await Promise.resolve(); await Promise.resolve(); });
    expect(global.fetch).toHaveBeenCalledTimes(4);

    expect(result.current.error).toBeInstanceOf(Error);
    expect(result.current.error!.message).toBe('Server error: 500');
  });

  it('does not retry on 4xx clients errors', async () => {
      mockErrorResponse(400);
      const { result } = renderHook(() => useSearchProducts('bad'));

      act(() => { jest.advanceTimersByTime(300); });
      await act(async () => { await Promise.resolve(); await Promise.resolve(); });

      expect(global.fetch).toHaveBeenCalledTimes(1);
      
      act(() => { jest.advanceTimersByTime(4000); });
      
      expect(global.fetch).toHaveBeenCalledTimes(1);
      expect(result.current.error).toBeInstanceOf(Error);
      expect(result.current.error!.message).toBe('Client error: 400');
  });

  it('cleans up on unmount', () => {
      const { unmount } = renderHook(() => useSearchProducts('unmount'));
      
      unmount();
      act(() => { jest.advanceTimersByTime(300); });
      
      expect(global.fetch).not.toHaveBeenCalled();
  });
});
