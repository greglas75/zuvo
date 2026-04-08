// FILE: useSearchProducts.test.ts

import { renderHook, act, waitFor } from '@testing-library/react';
import { useSearchProducts } from './r2-useSearchProducts';

const mockProducts = [
  { id: 'prod-1', name: 'Widget A', price: 29.99 },
  { id: 'prod-2', name: 'Widget B', price: 39.99 },
];

const mockResponse = {
  products: mockProducts,
  total: 100,
};

describe('useSearchProducts', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    jest.useFakeTimers();
    global.fetch = jest.fn();
  });

  afterEach(() => {
    jest.runOnlyPendingTimers();
    jest.useRealTimers();
  });

  describe('debounce behavior', () => {
    it('does not call fetch until 300ms have elapsed', async () => {
      const { result } = renderHook(() => useSearchProducts());

      (global.fetch as jest.Mock).mockResolvedValueOnce({
        ok: true,
        json: async () => mockResponse,
      });

      // Set search query (should not trigger fetch yet)
      await act(async () => {
        (result.current as any).handleSearch('widget');
      });

      expect(global.fetch).not.toHaveBeenCalled();

      // Fast-forward less than 300ms
      await act(async () => {
        jest.advanceTimersByTime(200);
      });

      expect(global.fetch).not.toHaveBeenCalled();

      // Fast-forward past 300ms
      await act(async () => {
        jest.advanceTimersByTime(100);
      });

      await waitFor(() => {
        expect(global.fetch).toHaveBeenCalled();
      });
    });

    it('cancels previous debounce when new query arrives', async () => {
      const { result } = renderHook(() => useSearchProducts());

      (global.fetch as jest.Mock).mockResolvedValue({
        ok: true,
        json: async () => mockResponse,
      });

      await act(async () => {
        (result.current as any).handleSearch('widget');
      });

      await act(async () => {
        jest.advanceTimersByTime(150);
      });

      await act(async () => {
        (result.current as any).handleSearch('gadget');
      });

      await act(async () => {
        jest.advanceTimersByTime(150);
        // Should only have one fetch call, not two
      });

      await act(async () => {
        jest.runAllTimers();
      });

      expect(global.fetch).toHaveBeenCalledTimes(1);
      expect((global.fetch as jest.Mock).mock.calls[0][0]).toContain('gadget');
    });
  });

  describe('pagination', () => {
    it('loadMore appends results instead of replacing', async () => {
      const { result } = renderHook(() => useSearchProducts());

      (global.fetch as jest.Mock).mockResolvedValueOnce({
        ok: true,
        json: async () => mockResponse,
      });

      await act(async () => {
        (result.current as any).handleSearch('widget');
        jest.runAllTimers();
      });

      await waitFor(() => {
        expect(result.current.products.length).toBe(2);
      });

      const moreProducts = [
        { id: 'prod-3', name: 'Widget C', price: 49.99 },
        { id: 'prod-4', name: 'Widget D', price: 59.99 },
      ];

      (global.fetch as jest.Mock).mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          products: moreProducts,
          total: 100,
        }),
      });

      await act(async () => {
        result.current.loadMore();
      });

      await waitFor(() => {
        expect(result.current.products.length).toBe(4);
        expect(result.current.products[2].id).toBe('prod-3');
      });
    });

    it('hasMore is false when results are less than 10', async () => {
      const { result } = renderHook(() => useSearchProducts());

      (global.fetch as jest.Mock).mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          products: mockProducts,
          total: 2,
        }),
      });

      await act(async () => {
        (result.current as any).handleSearch('widget');
        jest.runAllTimers();
      });

      await waitFor(() => {
        expect(result.current.hasMore).toBe(false);
      });
    });
  });

  describe('AbortController behavior', () => {
    it('aborts in-flight request on unmount', async () => {
      const abortSpy = jest.spyOn(AbortController.prototype, 'abort');
      const { unmount } = renderHook(() => useSearchProducts());

      (global.fetch as jest.Mock).mockImplementationOnce(
        () =>
          new Promise(() => {
            /* never resolves */
          }),
      );

      await act(async () => {
        const hookInstance = renderHook(() => useSearchProducts());
        (hookInstance.result.current as any).handleSearch('widget');
        jest.runAllTimers();
        hookInstance.unmount();
      });

      expect(abortSpy).toHaveBeenCalled();
      abortSpy.mockRestore();
    });

    it('clears debounce timer on unmount', async () => {
      const { unmount } = renderHook(() => useSearchProducts());

      (global.fetch as jest.Mock).mockResolvedValue({
        ok: true,
        json: async () => mockResponse,
      });

      await act(async () => {
        const hookInstance = renderHook(() => useSearchProducts());
        (hookInstance.result.current as any).handleSearch('widget');
        hookInstance.unmount();
      });

      // Verify timers are cleared (no pending timers)
      expect(jest.getTimerCount()).toBe(0);
    });
  });

  describe('retry with exponential backoff', () => {
    it('retries on failure with exponential backoff (max 3 attempts)', async () => {
      const { result } = renderHook(() => useSearchProducts());

      (global.fetch as jest.Mock)
        .mockRejectedValueOnce(new Error('Network error'))
        .mockRejectedValueOnce(new Error('Network error'))
        .mockResolvedValueOnce({
          ok: true,
          json: async () => mockResponse,
        });

      await act(async () => {
        (result.current as any).handleSearch('widget');
      });

      // Wait for initial attempt
      await act(async () => {
        jest.advanceTimersByTime(300);
      });

      // Wait for retry 1 (backoff: 100ms)
      await act(async () => {
        jest.advanceTimersByTime(100);
      });

      // Wait for retry 2 (backoff: 200ms)
      await act(async () => {
        jest.advanceTimersByTime(200);
      });

      await waitFor(() => {
        expect(result.current.products.length).toBe(2);
      });

      expect(global.fetch).toHaveBeenCalledTimes(3);
    });

    it('sets error after max retries exceeded', async () => {
      const { result } = renderHook(() => useSearchProducts());

      (global.fetch as jest.Mock).mockRejectedValue(new Error('Network error'));

      await act(async () => {
        (result.current as any).handleSearch('widget');
      });

      // Advance through debounce + 3 attempts
      await act(async () => {
        jest.advanceTimersByTime(300); // debounce
        jest.advanceTimersByTime(100); // retry 1
        jest.advanceTimersByTime(200); // retry 2
        jest.advanceTimersByTime(400); // retry 3
      });

      await waitFor(() => {
        expect(result.current.error).not.toBeNull();
      });
    });

    it('manual retry resets attempt counter', async () => {
      const { result } = renderHook(() => useSearchProducts());

      (global.fetch as jest.Mock).mockRejectedValue(new Error('Network error'));

      await act(async () => {
        (result.current as any).handleSearch('widget');
        jest.runAllTimers();
      });

      await waitFor(() => {
        expect(result.current.error).not.toBeNull();
      });

      (global.fetch as jest.Mock).mockResolvedValueOnce({
        ok: true,
        json: async () => mockResponse,
      });

      await act(async () => {
        result.current.retry();
      });

      await waitFor(() => {
        expect(result.current.error).toBeNull();
        expect(result.current.products.length).toBe(2);
      });
    });
  });

  describe('loading states', () => {
    it('sets isLoading true during initial search', async () => {
      const { result } = renderHook(() => useSearchProducts());

      (global.fetch as jest.Mock).mockImplementation(
        () =>
          new Promise((resolve) => {
            setTimeout(() => {
              resolve({
                ok: true,
                json: async () => mockResponse,
              });
            }, 100);
          }),
      );

      await act(async () => {
        (result.current as any).handleSearch('widget');
        jest.advanceTimersByTime(300);
      });

      expect(result.current.isLoading).toBe(true);

      await act(async () => {
        jest.advanceTimersByTime(100);
      });

      await waitFor(() => {
        expect(result.current.isLoading).toBe(false);
      });
    });

    it('sets isLoadingMore true during pagination fetch', async () => {
      const { result } = renderHook(() => useSearchProducts());

      (global.fetch as jest.Mock).mockResolvedValueOnce({
        ok: true,
        json: async () => mockResponse,
      });

      await act(async () => {
        (result.current as any).handleSearch('widget');
        jest.runAllTimers();
      });

      await waitFor(() => {
        expect(result.current.isLoading).toBe(false);
      });

      (global.fetch as jest.Mock).mockImplementation(
        () =>
          new Promise((resolve) => {
            setTimeout(() => {
              resolve({
                ok: true,
                json: async () => ({
                  products: [{ id: 'prod-3', name: 'Widget C', price: 49.99 }],
                  total: 100,
                }),
              });
            }, 100);
          }),
      );

      await act(async () => {
        result.current.loadMore();
      });

      expect(result.current.isLoadingMore).toBe(true);

      await act(async () => {
        jest.advanceTimersByTime(100);
      });

      await waitFor(() => {
        expect(result.current.isLoadingMore).toBe(false);
      });
    });

    it('isLoading and isLoadingMore are mutually exclusive', async () => {
      const { result } = renderHook(() => useSearchProducts());

      (global.fetch as jest.Mock).mockResolvedValue({
        ok: true,
        json: async () => mockResponse,
      });

      await act(async () => {
        (result.current as any).handleSearch('widget');
        jest.runAllTimers();
      });

      await waitFor(() => {
        expect(result.current.isLoading || result.current.isLoadingMore).toBe(true);
      });

      // Both should never be true simultaneously
      expect(result.current.isLoading && result.current.isLoadingMore).toBe(false);
    });
  });

  describe('response validation', () => {
    it('throws error on invalid response format', async () => {
      const { result } = renderHook(() => useSearchProducts());

      (global.fetch as jest.Mock).mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          products: 'not an array',
          total: 100,
        }),
      });

      await act(async () => {
        (result.current as any).handleSearch('widget');
        jest.runAllTimers();
      });

      await waitFor(() => {
        expect(result.current.error).not.toBeNull();
      });
    });

    it('handles HTTP errors gracefully', async () => {
      const { result } = renderHook(() => useSearchProducts());

      (global.fetch as jest.Mock).mockResolvedValueOnce({
        ok: false,
        status: 500,
      });

      await act(async () => {
        (result.current as any).handleSearch('widget');
        jest.runAllTimers();
      });

      await waitFor(() => {
        expect(result.current.error).toContain('HTTP 500');
      });
    });
  });

  describe('search generation counter', () => {
    it('cancels stale retries when new search starts', async () => {
      const { result } = renderHook(() => useSearchProducts());

      let retryPromise: Promise<any>;

      (global.fetch as jest.Mock)
        .mockImplementationOnce(
          () =>
            new Promise((resolve) => {
              retryPromise = new Promise((resolve2) => {
                setTimeout(() => {
                  resolve({
                    ok: false,
                    status: 500,
                  });
                  resolve2(null);
                }, 100);
              });
              return retryPromise;
            }),
        )
        .mockResolvedValueOnce({
          ok: true,
          json: async () => mockResponse,
        });

      await act(async () => {
        (result.current as any).handleSearch('foo');
        jest.advanceTimersByTime(300);
      });

      await act(async () => {
        jest.advanceTimersByTime(100);
      });

      // Start new search before retry completes
      await act(async () => {
        (result.current as any).handleSearch('bar');
        jest.advanceTimersByTime(300);
      });

      // Verify bar results override any stale foo results
      await waitFor(() => {
        expect((global.fetch as jest.Mock).mock.calls[1][0]).toContain('bar');
      });
    });
  });
});
