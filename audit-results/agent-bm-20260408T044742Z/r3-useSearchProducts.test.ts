import { renderHook, act, waitFor } from '@testing-library/react';
import { useSearchProducts } from './r2-useSearchProducts';

describe('useSearchProducts', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    jest.clearAllMocks();
    global.fetch = jest.fn();
  });

  afterEach(() => {
    jest.runOnlyPendingTimers();
    jest.useRealTimers();
  });

  const mockFetchResponse = (data: any, status = 200) => {
    (global.fetch as jest.Mock).mockResolvedValueOnce({
      ok: status === 200,
      status,
      json: async () => data,
    });
  };

  const validSearchResponse = {
    products: [
      { id: 'p1', name: 'Product 1', price: 10 },
      { id: 'p2', name: 'Product 2', price: 20 },
    ],
    total: 2,
    hasMore: false,
  };

  describe('debounce', () => {
    it('should not fetch immediately on query change', () => {
      const { rerender } = renderHook(
        ({ query }) => useSearchProducts(query),
        { initialProps: { query: '' } },
      );

      rerender({ query: 'laptop' });

      expect(global.fetch).not.toHaveBeenCalled();
    });

    it('should fetch after 300ms debounce delay', async () => {
      mockFetchResponse(validSearchResponse);

      const { rerender } = renderHook(
        ({ query }) => useSearchProducts(query),
        { initialProps: { query: '' } },
      );

      rerender({ query: 'laptop' });

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(global.fetch).toHaveBeenCalledWith(
          expect.stringContaining('q=laptop'),
          expect.any(Object),
        );
      });
    });

    it('should cancel previous debounce on new query', async () => {
      mockFetchResponse(validSearchResponse);
      mockFetchResponse(validSearchResponse);

      const { rerender } = renderHook(
        ({ query }) => useSearchProducts(query),
        { initialProps: { query: '' } },
      );

      rerender({ query: 'laptop' });
      act(() => {
        jest.advanceTimersByTime(150);
      });

      rerender({ query: 'laptop screen' });
      act(() => {
        jest.advanceTimersByTime(150);
      });

      // Still should not have fetched
      expect(global.fetch).not.toHaveBeenCalled();

      act(() => {
        jest.advanceTimersByTime(150);
      });

      // Only the second query should trigger
      await waitFor(() => {
        expect(global.fetch).toHaveBeenCalledWith(
          expect.stringContaining('q=laptop%20screen'),
          expect.any(Object),
        );
      });
    });

    it('should clear search when query becomes empty', async () => {
      mockFetchResponse(validSearchResponse);

      const { rerender, result } = renderHook(
        ({ query }) => useSearchProducts(query),
        { initialProps: { query: 'laptop' } },
      );

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(result.current.products.length).toBeGreaterThan(0);
      });

      rerender({ query: '' });

      expect(result.current.products).toEqual([]);
      expect(result.current.total).toBe(0);
    });
  });

  describe('AbortController', () => {
    it('should abort previous request when query changes', async () => {
      const abortSpy = jest.spyOn(AbortController.prototype, 'abort');
      mockFetchResponse(validSearchResponse);

      const { rerender } = renderHook(
        ({ query }) => useSearchProducts(query),
        { initialProps: { query: 'laptop' } },
      );

      act(() => {
        jest.advanceTimersByTime(300);
      });

      rerender({ query: 'desktop' });
      act(() => {
        jest.advanceTimersByTime(300);
      });

      expect(abortSpy).toHaveBeenCalled();

      abortSpy.mockRestore();
    });

    it('should abort request on unmount', async () => {
      const abortSpy = jest.spyOn(AbortController.prototype, 'abort');
      mockFetchResponse(validSearchResponse);

      const { unmount } = renderHook(() => useSearchProducts('laptop'));

      act(() => {
        jest.advanceTimersByTime(300);
      });

      unmount();

      expect(abortSpy).toHaveBeenCalled();

      abortSpy.mockRestore();
    });

    it('should handle fetch abort error gracefully', async () => {
      (global.fetch as jest.Mock).mockRejectedValueOnce(
        new DOMException('The operation was aborted', 'AbortError'),
      );

      const { result } = renderHook(() => useSearchProducts('laptop'));

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(result.current.error).toBeNull();
      });
    });
  });

  describe('pagination', () => {
    it('loadMore should append results instead of replacing', async () => {
      const page1 = {
        products: [
          { id: 'p1', name: 'Product 1', price: 10 },
          { id: 'p2', name: 'Product 2', price: 20 },
        ],
        total: 4,
        hasMore: true,
      };
      const page2 = {
        products: [
          { id: 'p3', name: 'Product 3', price: 30 },
          { id: 'p4', name: 'Product 4', price: 40 },
        ],
        total: 4,
        hasMore: false,
      };

      mockFetchResponse(page1);
      mockFetchResponse(page2);

      const { result } = renderHook(() => useSearchProducts('laptop'));

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(result.current.products).toEqual(page1.products);
      });

      act(() => {
        result.current.loadMore();
      });

      await waitFor(() => {
        expect(result.current.products).toHaveLength(4);
        expect(result.current.products).toEqual([...page1.products, ...page2.products]);
      });
    });

    it('should not allow loadMore when hasMore is false', async () => {
      mockFetchResponse({ ...validSearchResponse, hasMore: false });

      const { result } = renderHook(() => useSearchProducts('laptop'));

      act(() => {
        jest.advanceTimersByTime(300);
      });

      // Wait for initial fetch to process response
      await waitFor(() => {
        expect(result.current.isLoading).toBe(false);
      });

      act(() => {
        result.current.loadMore();
      });

      // Should not trigger additional fetch
      expect(global.fetch).toHaveBeenCalledTimes(1);
    });

    it('should not allow loadMore when already loading', async () => {
      mockFetchResponse(
        { ...validSearchResponse, hasMore: true },
        200,
      );
      mockFetchResponse({ ...validSearchResponse, hasMore: false });

      const { result } = renderHook(() => useSearchProducts('laptop'));

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(result.current.isLoading).toBe(false);
      });

      // Block on second fetch by not advancing timers
      act(() => {
        result.current.loadMore();
        result.current.loadMore(); // Second call while loading
      });

      // Should only queue one additional fetch
      await waitFor(() => {
        expect(global.fetch).toHaveBeenCalledTimes(2);
      });
    });
  });

  describe('retry logic', () => {
    it('should retry failed request with exponential backoff', async () => {
      (global.fetch as jest.Mock)
        .mockRejectedValueOnce(new Error('Network error'))
        .mockRejectedValueOnce(new Error('Network error'))
        .mockResolvedValueOnce({
          ok: true,
          status: 200,
          json: async () => validSearchResponse,
        });

      const { result } = renderHook(() => useSearchProducts('laptop'));

      act(() => {
        jest.advanceTimersByTime(300);
      });

      // First attempt fails immediately
      await waitFor(() => {
        expect(result.current.isLoading).toBe(true);
      });

      // Advance to trigger first retry (300ms)
      act(() => {
        jest.advanceTimersByTime(300);
      });

      // Advance to trigger second retry (600ms)
      act(() => {
        jest.advanceTimersByTime(600);
      });

      // Should succeed after 3 attempts
      await waitFor(() => {
        expect(result.current.products).toEqual(validSearchResponse.products);
      });
    });

    it('should max out at 3 retry attempts', async () => {
      (global.fetch as jest.Mock).mockRejectedValue(new Error('Network error'));

      const { result } = renderHook(() => useSearchProducts('laptop'));

      act(() => {
        jest.advanceTimersByTime(300);
      });

      // Drain all pending timers to allow all retries
      act(() => {
        jest.runAllTimers();
      });

      await waitFor(() => {
        expect(result.current.error).toBeDefined();
        expect(result.current.error?.message).toContain('Network error');
      });

      // Should have tried max 3 times
      expect(global.fetch).toHaveBeenCalledTimes(3);
    });

    it('retry callback should preserve pagination state', async () => {
      mockFetchResponse({
        products: [{ id: 'p1', name: 'Product 1', price: 10 }],
        total: 2,
        hasMore: true,
      });
      mockFetchResponse({
        products: [{ id: 'p2', name: 'Product 2', price: 20 }],
        total: 2,
        hasMore: false,
      });
      mockFetchResponse({
        products: [{ id: 'p2', name: 'Product 2', price: 20 }],
        total: 2,
        hasMore: false,
      });

      const { result } = renderHook(() => useSearchProducts('laptop'));

      // Initial search
      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(result.current.products).toHaveLength(1);
      });

      // Load more
      act(() => {
        result.current.loadMore();
      });

      await waitFor(() => {
        expect(result.current.products).toHaveLength(2);
      });

      // Retry should use correct page (1, not 0)
      act(() => {
        result.current.retry();
      });

      await waitFor(() => {
        // After retry of page 1, should still have page 2 products
        expect(result.current.products).toContainEqual({
          id: 'p2',
          name: 'Product 2',
          price: 20,
        });
      });
    });
  });

  describe('loading states', () => {
    it('should have isLoading true during initial search', async () => {
      mockFetchResponse(validSearchResponse);

      const { result } = renderHook(() => useSearchProducts('laptop'));

      act(() => {
        jest.advanceTimersByTime(300);
      });

      expect(result.current.isLoading).toBe(true);
      expect(result.current.isLoadingMore).toBe(false);

      await waitFor(() => {
        expect(result.current.isLoading).toBe(false);
      });
    });

    it('should have isLoadingMore true during pagination', async () => {
      mockFetchResponse({ ...validSearchResponse, hasMore: true });
      mockFetchResponse(validSearchResponse);

      const { result } = renderHook(() => useSearchProducts('laptop'));

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(result.current.isLoading).toBe(false);
      });

      act(() => {
        result.current.loadMore();
      });

      expect(result.current.isLoadingMore).toBe(true);
      expect(result.current.isLoading).toBe(false);

      await waitFor(() => {
        expect(result.current.isLoadingMore).toBe(false);
      });
    });

    it('states should be mutually exclusive', async () => {
      mockFetchResponse({ ...validSearchResponse, hasMore: true });
      mockFetchResponse(validSearchResponse);

      const { result } = renderHook(() => useSearchProducts('laptop'));

      act(() => {
        jest.advanceTimersByTime(300);
      });

      // During initial load: exactly one should be true
      expect(result.current.isLoading).toBe(true);
      expect(result.current.isLoadingMore).toBe(false);

      await waitFor(() => {
        expect(result.current.isLoading).toBe(false);
      });

      // At rest: both should be false
      expect(result.current.isLoading).toBe(false);
      expect(result.current.isLoadingMore).toBe(false);

      act(() => {
        result.current.loadMore();
      });

      // During pagination: exactly one should be true
      expect(result.current.isLoading).toBe(false);
      expect(result.current.isLoadingMore).toBe(true);
    });
  });

  describe('error handling', () => {
    it('should set error on invalid API response', async () => {
      (global.fetch as jest.Mock).mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => ({ invalid: 'response' }),
      });

      const { result } = renderHook(() => useSearchProducts('laptop'));

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(result.current.error).toBeDefined();
        expect(result.current.error?.message).toContain('Invalid response shape');
      });
    });

    it('should set error on HTTP failure', async () => {
      (global.fetch as jest.Mock).mockResolvedValueOnce({
        ok: false,
        status: 500,
      });

      const { result } = renderHook(() => useSearchProducts('laptop'));

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(result.current.error).toBeDefined();
      });
    });

    it('retry should clear previous error', async () => {
      (global.fetch as jest.Mock)
        .mockRejectedValueOnce(new Error('Network error'))
        .mockResolvedValueOnce({
          ok: true,
          status: 200,
          json: async () => validSearchResponse,
        });

      const { result } = renderHook(() => useSearchProducts('laptop'));

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(result.current.error).toBeDefined();
      });

      act(() => {
        result.current.retry();
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(result.current.error).toBeNull();
      });
    });
  });

  describe('cleanup on unmount', () => {
    it('should clear debounce timer on unmount', () => {
      const clearTimeoutSpy = jest.spyOn(global, 'clearTimeout');
      mockFetchResponse(validSearchResponse);

      const { unmount } = renderHook(() => useSearchProducts('laptop'));

      unmount();

      expect(clearTimeoutSpy).toHaveBeenCalled();

      clearTimeoutSpy.mockRestore();
    });

    it('should abort in-flight request on unmount', () => {
      const abortSpy = jest.spyOn(AbortController.prototype, 'abort');
      mockFetchResponse(validSearchResponse);

      const { unmount } = renderHook(() => useSearchProducts('laptop'));

      act(() => {
        jest.advanceTimersByTime(300);
      });

      unmount();

      expect(abortSpy).toHaveBeenCalled();

      abortSpy.mockRestore();
    });

    it('should not have memory leaks from multiple searches', async () => {
      const abortSpy = jest.spyOn(AbortController.prototype, 'abort');
      mockFetchResponse(validSearchResponse);
      mockFetchResponse(validSearchResponse);
      mockFetchResponse(validSearchResponse);

      const { rerender, unmount } = renderHook(
        ({ query }) => useSearchProducts(query),
        { initialProps: { query: 'laptop' } },
      );

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(global.fetch).toHaveBeenCalledTimes(1);
      });

      rerender({ query: 'desktop' });
      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(global.fetch).toHaveBeenCalledTimes(2);
      });

      rerender({ query: 'monitor' });
      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(global.fetch).toHaveBeenCalledTimes(3);
      });

      unmount();

      // Verify abort was called for cleanup
      expect(abortSpy).toHaveBeenCalled();

      abortSpy.mockRestore();
    });
  });

  describe('response validation', () => {
    it('should reject response missing products array', async () => {
      (global.fetch as jest.Mock).mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => ({ total: 2, hasMore: false }),
      });

      const { result } = renderHook(() => useSearchProducts('laptop'));

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(result.current.error).toBeDefined();
      });
    });

    it('should reject products array with invalid items', async () => {
      (global.fetch as jest.Mock).mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => ({
          products: [{ id: 'p1', name: 'Product 1' }], // Missing price
          total: 1,
          hasMore: false,
        }),
      });

      const { result } = renderHook(() => useSearchProducts('laptop'));

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(result.current.error).toBeDefined();
      });
    });
  });
});
