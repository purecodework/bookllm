import { renderHook, act } from '@testing-library/react';
import { useLocalStorage } from '@/hooks/use-local-storage';

const KEY = 'test:use-local-storage';

describe('useLocalStorage', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('returns defaultValue when key is absent', () => {
    const { result } = renderHook(() => useLocalStorage(KEY, 42));
    expect(result.current[0]).toBe(42);
  });

  it('reads existing value from localStorage after mount', async () => {
    localStorage.setItem(KEY, JSON.stringify('hello'));
    const { result } = renderHook(() => useLocalStorage(KEY, ''));
    await act(async () => {});
    expect(result.current[0]).toBe('hello');
  });

  it('setValue updates state and writes to localStorage', () => {
    const { result } = renderHook(() => useLocalStorage(KEY, 0));
    act(() => { result.current[1](99); });
    expect(result.current[0]).toBe(99);
    expect(JSON.parse(localStorage.getItem(KEY)!)).toBe(99);
  });

  it('works with objects', () => {
    const { result } = renderHook(() =>
      useLocalStorage<{ a: number }>(KEY, { a: 0 }),
    );
    act(() => { result.current[1]({ a: 7 }); });
    expect(result.current[0]).toEqual({ a: 7 });
    expect(JSON.parse(localStorage.getItem(KEY)!)).toEqual({ a: 7 });
  });

  it('keeps defaultValue when stored JSON is invalid', async () => {
    localStorage.setItem(KEY, '{{bad json');
    const { result } = renderHook(() => useLocalStorage(KEY, 'default'));
    await act(async () => {});
    expect(result.current[0]).toBe('default');
  });

  it('successive setValue calls reflect the latest value', () => {
    const { result } = renderHook(() => useLocalStorage(KEY, ''));
    act(() => { result.current[1]('first'); });
    act(() => { result.current[1]('second'); });
    expect(result.current[0]).toBe('second');
    expect(JSON.parse(localStorage.getItem(KEY)!)).toBe('second');
  });

  it('re-reads when the key changes', async () => {
    localStorage.setItem('key-a', JSON.stringify('alpha'));
    localStorage.setItem('key-b', JSON.stringify('beta'));

    const { result, rerender } = renderHook(
      ({ k }: { k: string }) => useLocalStorage(k, ''),
      { initialProps: { k: 'key-a' } },
    );
    await act(async () => {});
    expect(result.current[0]).toBe('alpha');

    rerender({ k: 'key-b' });
    await act(async () => {});
    expect(result.current[0]).toBe('beta');
  });
});
