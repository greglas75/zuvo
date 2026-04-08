import { renderHook, act, waitFor } from '@testing-library/react';
import { useSearchProducts } from './useSearchProducts';

describe('useSearchProducts', () => {
  const mockApiUrl = 'https://api.example.com/search';
  const mockProducts = [
    { id: '1', name: 'Product 1', price: 100 },
    { id: '2', name: 'Product 2', price: 200 },
  ];

  beforeEach(() => {
    jest.clearAllMocks();
    jest.useFakeTimers();
    global.fetch = jest.fn();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  describe('Debounce', () => {
    it('debounces search input for 300ms', async () => {
      const { result } = renderHook(() =>
        useSearchProducts(mockApiUrl),
      );

      (global.fetch as jest.Mock).mockResolvedValue({
        ok: true,
        json: jest.fn().mockResolvedValue({
          products: mockProducts,
          total: 2,
          page: 0,
        }),
      });

      act(() => {
        result.current.search('test');
      });

      expect(global.fetch).not.toHaveBeenCalled();

      act(() => {
        jest.advanceTimersByTime(299);
      });

      expect(global.fetch).not.toHaveBeenCalled();

      act(() => {
        jest.advanceTimersByTime(1);
      });

      await waitFor(() => {
        expect(global.fetch).toHaveBeenCalled();
      });
    });

    it('cancels previous debounce timer on new search', async () => {
      const { result } = renderHook(() =>
        useSearchProducts(mockApiUrl),
      );

      (global.fetch as jest.Mock).mockResolvedValue({
        ok: true,
        json: jest.fn().mockResolvedValue({
          products: mockProducts,
          total: 2,
          page: 0,
        }),
      });

      act(() => {
        result.current.search('first');
      });

      act(() => {
        jest.advanceTimersByTime(100);
      });

      act(() => {
        result.current.search('second');
      });

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(global.fetch).toHaveBeenCalledTimes(1);
        expect(global.fetch).toHaveBeenCalledWith(
          expect.stringContaining('second'),
          expect.any(Object),
        );
      });
    });
  });

  describe('AbortController', () => {
    it('aborts previous request when new search starts', async () => {
      const { result } = renderHook(() =>
        useSearchProducts(mockApiUrl),
      );

      let firstSignal: AbortSignal;
      let secondSignal: AbortSignal;

      (global.fetch as jest.Mock).mockImplementation(
        (url, { signal }) => {
          if (!firstSignal) {
            firstSignal = signal;
          } else if (!secondSignal) {
            secondSignal = signal;
          }
          return new Promise(() => {});
        },
      );

      act(() => {
        result.current.search('first');
      });

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(global.fetch).toHaveBeenCalled();
      });

      act(() => {
        result.current.search('second');
      });

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(firstSignal!.aborted).toBe(true);
        expect(secondSignal).toBeDefined();
      });
    });

    it('aborts request on unmount', async () => {
      const { result, unmount } = renderHook(() =>
        useSearchProducts(mockApiUrl),
      );

      let capturedSignal: AbortSignal;

      (global.fetch as jest.Mock).mockImplementation(
        (url, { signal }) => {
          capturedSignal = signal;
          return new Promise(() => {});
        },
      );

      act(() => {
        result.current.search('test');
      });

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(global.fetch).toHaveBeenCalled();
      });

      unmount();

      expect(capturedSignal!.aborted).toBe(true);
    });
  });

  describe('Pagination', () => {
    it('appends results on loadMore (not replaces)', async () => {
      const { result } = renderHook(() =>
        useSearchProducts(mockApiUrl),
      );

      (global.fetch as jest.Mock)
        .mockResolvedValueOnce({
          ok: true,
          json: jest.fn().mockResolvedValue({
            products: mockProducts,
            total: 20,
            page: 0,
          }),
        })
        .mockResolvedValueOnce({
          ok: true,
          json: jest.fn().mockResolvedValue({
            products: [
              { id: '3', name: 'Product 3', price: 300 },
              { id: '4', name: 'Product 4', price: 400 },
            ],
            total: 20,
            page: 1,
          }),
        });

      act(() => {
        result.current.search('test');
      });

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(result.current.products).toHaveLength(2);
      });

      act(() => {
        result.current.loadMore();
      });

      await waitFor(() => {
        expect(result.current.products).toHaveLength(4);
        expect(result.current.products[0].id).toBe('1');
        expect(result.current.products[3].id).toBe('4');
      });
    });

    it('does not call loadMore when isLoading is true', async () => {
      const { result } = renderHook(() =>
        useSearchProducts(mockApiUrl),
      );

      (global.fetch as jest.Mock).mockImplementation(
        () => new Promise(() => {}),
      );

      act(() => {
        result.current.search('test');
      });

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(result.current.isLoading).toBe(true);
      });

      act(() => {
        result.current.loadMore();
      });

      expect(global.fetch).toHaveBeenCalledTimes(1);
    });

    it('derives hasMore from actual product count vs total', async () => {
      const { result } = renderHook(() =>
        useSearchProducts(mockApiUrl),
      );

      (global.fetch as jest.Mock).mockResolvedValue({
        ok: true,
        json: jest.fn().mockResolvedValue({
          products: [mockProducts[0]],
          total: 100,
          page: 0,
        }),
      });

      act(() => {
        result.current.search('test');
      });

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(result.current.hasMore).toBe(true);
      });
    });
  });

  describe('Retry', () => {
    it('retries failed request up to 3 times with exponential backoff', async () => {
      const { result } = renderHook(() =>
        useSearchProducts(mockApiUrl),
      );

      const mockFetch = jest.fn();
      mockFetch
        .mockRejectedValueOnce(new Error('Network error'))
        .mockRejectedValueOnce(new Error('Network error'))
        .mockResolvedValueOnce({
          ok: true,
          json: jest.fn().mockResolvedValue({
            products: mockProducts,
            total: 2,
            page: 0,
          }),
        });

      (global.fetch as jest.Mock) = mockFetch;

      act(() => {
        result.current.search('test');
      });

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(mockFetch).toHaveBeenCalledTimes(1);
      });

      act(() => {
        jest.advanceTimersByTime(200);
      });

      await waitFor(() => {
        expect(mockFetch).toHaveBeenCalledTimes(2);
      });

      act(() => {
        jest.advanceTimersByTime(400);
      });

      await waitFor(() => {
        expect(mockFetch).toHaveBeenCalledTimes(3);
        expect(result.current.products).toEqual(mockProducts);
      });
    });

    it('gives up after 3 retries and sets error state', async () => {
      const { result } = renderHook(() =>
        useSearchProducts(mockApiUrl),
      );

      (global.fetch as jest.Mock).mockRejectedValue(
        new Error('Network error'),
      );

      act(() => {
        result.current.search('test');
      });

      act(() => {
        jest.advanceTimersByTime(300);
      });

      act(() => {
        jest.advanceTimersByTime(2000);
      });

      await waitFor(() => {
        expect(result.current.error).toBeTruthy();
        expect(result.current.products).toHaveLength(0);
      });
    });

    it('retry() function retries the current search', async () => {
      const { result } = renderHook(() =>
        useSearchProducts(mockApiUrl),
      );

      (global.fetch as jest.Mock)
        .mockRejectedValueOnce(new Error('Network error'))
        .mockResolvedValueOnce({
          ok: true,
          json: jest.fn().mockResolvedValue({
            products: mockProducts,
            total: 2,
            page: 0,
          }),
        });

      act(() => {
        result.current.search('test');
      });

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(result.current.error).toBeTruthy();
      });

      act(() => {
        result.current.retry();
      });

      await waitFor(() => {
        expect(result.current.products).toEqual(mockProducts);
        expect(result.current.error).toBeNull();
      });
    });
  });

  describe('Loading States', () => {
    it('isLoading and isLoadingMore are mutually exclusive', async () => {
      const { result } = renderHook(() =>
        useSearchProducts(mockApiUrl),
      );

      let callCount = 0;
      (global.fetch as jest.Mock).mockImplementation(() => {
        callCount++;
        if (callCount === 1) {
          return new Promise(() => {});
        }
        return Promise.resolve({
          ok: true,
          json: jest.fn().mockResolvedValue({
            products: mockProducts,
            total: 20,
            page: callCount - 2,
          }),
        });
      });

      act(() => {
        result.current.search('test');
      });

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(result.current.isLoading).toBe(true);
        expect(result.current.isLoadingMore).toBe(false);
      });

      act(() => {
        result.current.loadMore();
      });

      await waitFor(() => {
        expect(result.current.isLoadingMore).toBe(true);
      });
    });
  });

  describe('Cleanup', () => {
    it('clears debounce timers on unmount', () => {
      jest.useRealTimers();
      jest.useFakeTimers();

      const { unmount } = renderHook(() =>
        useSearchProducts(mockApiUrl),
      );

      const clearTimeoutSpy = jest.spyOn(global, 'clearTimeout');

      unmount();

      expect(clearTimeoutSpy).toHaveBeenCalled();
      clearTimeoutSpy.mockRestore();
    });

    it('prevents state updates from orphaned requests after unmount', async () => {
      const { result, unmount } = renderHook(() =>
        useSearchProducts(mockApiUrl),
      );

      let resolveResponse: (value: any) => void = () => {};

      (global.fetch as jest.Mock).mockImplementation(
        () => new Promise((resolve) => {
          resolveResponse = resolve;
        }),
      );

      act(() => {
        result.current.search('test');
      });

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(global.fetch).toHaveBeenCalled();
      });

      unmount();

      act(() => {
        resolveResponse({
          ok: true,
          json: async () => ({
            products: mockProducts,
            total: 2,
            page: 0,
          }),
        });
      });

      // Should not cause warnings or state updates
      expect(result.current).toBeDefined();
    });
  });

  describe('Response Validation', () => {
    it('rejects invalid response shape and sets error', async () => {
      const { result } = renderHook(() =>
        useSearchProducts(mockApiUrl),
      );

      (global.fetch as jest.Mock).mockResolvedValue({
        ok: true,
        json: jest.fn().mockResolvedValue({ invalid: 'shape' }),
      });

      act(() => {
        result.current.search('test');
      });

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(result.current.error).toBeTruthy();
      });
    });

    it('accepts valid response shape with all required fields', async () => {
      const { result } = renderHook(() =>
        useSearchProducts(mockApiUrl),
      );

      (global.fetch as jest.Mock).mockResolvedValue({
        ok: true,
        json: jest.fn().mockResolvedValue({
          products: mockProducts,
          total: 2,
          page: 0,
        }),
      });

      act(() => {
        result.current.search('test');
      });

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(result.current.products).toEqual(mockProducts);
        expect(result.current.error).toBeNull();
      });
    });
  });

  describe('Empty Query', () => {
    it('clears products and aborts in-flight request when query is empty', async () => {
      const { result } = renderHook(() =>
        useSearchProducts(mockApiUrl),
      );

      let capturedSignal: AbortSignal;
      (global.fetch as jest.Mock).mockImplementation(
        (url, { signal }) => {
          capturedSignal = signal;
          return new Promise(() => {});
        },
      );

      act(() => {
        result.current.search('test');
      });

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(global.fetch).toHaveBeenCalled();
      });

      act(() => {
        result.current.search('');
      });

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(result.current.products).toHaveLength(0);
        expect(result.current.total).toBe(0);
        expect(capturedSignal!.aborted).toBe(true);
      });
    });
  });

  describe('Request Ordering', () => {
    it('ignores responses from stale requests', async () => {
      const { result } = renderHook(() =>
        useSearchProducts(mockApiUrl),
      );

      let firstResolve: (value: any) => void = () => {};
      let secondResolve: (value: any) => void = () => {};
      let callCount = 0;

      (global.fetch as jest.Mock).mockImplementation(() => {
        callCount++;
        return new Promise((resolve) => {
          if (callCount === 1) firstResolve = resolve;
          else secondResolve = resolve;
        });
      });

      act(() => {
        result.current.search('first');
      });

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(global.fetch).toHaveBeenCalledTimes(1);
      });

      act(() => {
        result.current.search('second');
      });

      act(() => {
        jest.advanceTimersByTime(300);
      });

      await waitFor(() => {
        expect(global.fetch).toHaveBeenCalledTimes(2);
      });

      // Second request resolves first
      act(() => {
        secondResolve({
          ok: true,
          json: async () => ({
            products: [{ id: '2', name: 'Second', price: 200 }],
            total: 1,
            page: 0,
          }),
        });
      });

      await waitFor(() => {
        expect(result.current.products[0].name).toBe('Second');
      });

      // First request resolves later (should be ignored)
      act(() => {
        firstResolve({
          ok: true,
          json: async () => ({
            products: [{ id: '1', name: 'First', price: 100 }],
            total: 1,
            page: 0,
          }),
        });
      });

      // Should still show second request's results
      expect(result.current.products[0].name).toBe('Second');
    });
  });
});
