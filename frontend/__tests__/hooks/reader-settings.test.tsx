import { renderHook, act } from '@testing-library/react';
import {
  useReaderPrefs,
  fontSizeClass,
  lineHeightClass,
} from '@/components/reader/reader-settings';

const STORAGE_KEY = 'bookllm:reader-prefs';


describe('useReaderPrefs', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('localStorage 为空时返回默认值', () => {
    const { result } = renderHook(() => useReaderPrefs());

    expect(result.current.prefs).toEqual({ fontSize: 'base', lineHeight: 'relaxed' });
  });

  it('mount 后从 localStorage 读取已保存的偏好', async () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ fontSize: 'lg', lineHeight: 'loose' }),
    );
    const { result } = renderHook(() => useReaderPrefs());

    await act(async () => {});
    expect(result.current.prefs).toEqual({ fontSize: 'lg', lineHeight: 'loose' });
  });

  it('updatePrefs 更新 state 并写入 localStorage', () => {
    const { result } = renderHook(() => useReaderPrefs());

    act(() => {
      result.current.updatePrefs({ fontSize: 'sm' });
    });

    expect(result.current.prefs.fontSize).toBe('sm');
    const stored = JSON.parse(localStorage.getItem(STORAGE_KEY)!);
    expect(stored.fontSize).toBe('sm');
  });

  it('updatePrefs 是部分更新，不覆盖其他字段', () => {
    const { result } = renderHook(() => useReaderPrefs());

    act(() => { result.current.updatePrefs({ fontSize: 'lg' }); });
    act(() => { result.current.updatePrefs({ lineHeight: 'loose' }); });

    expect(result.current.prefs).toEqual({ fontSize: 'lg', lineHeight: 'loose' });
  });

  it('localStorage 存有非法 JSON 时静默回退到默认值', async () => {
    localStorage.setItem(STORAGE_KEY, 'not-valid-json{{');
    const { result } = renderHook(() => useReaderPrefs());
    await act(async () => {});

    expect(result.current.prefs).toEqual({ fontSize: 'base', lineHeight: 'relaxed' });
  });

  it('多次 updatePrefs 后 localStorage 保存最新值', () => {
    const { result } = renderHook(() => useReaderPrefs());

    act(() => { result.current.updatePrefs({ fontSize: 'sm' }); });
    act(() => { result.current.updatePrefs({ fontSize: 'lg' }); });

    const stored = JSON.parse(localStorage.getItem(STORAGE_KEY)!);
    expect(stored.fontSize).toBe('lg');
  });
});


describe('fontSizeClass', () => {
  it('sm → text-sm', () => expect(fontSizeClass('sm')).toBe('text-sm'));
  it('base → text-base', () => expect(fontSizeClass('base')).toBe('text-base'));
  it('lg → text-lg', () => expect(fontSizeClass('lg')).toBe('text-lg'));
});


describe('lineHeightClass', () => {
  it('relaxed → leading-relaxed', () => expect(lineHeightClass('relaxed')).toBe('leading-relaxed'));
  it('loose → leading-loose', () => expect(lineHeightClass('loose')).toBe('leading-loose'));
});
