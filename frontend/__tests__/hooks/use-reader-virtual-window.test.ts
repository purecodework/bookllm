import { act, renderHook } from '@testing-library/react';
import { useReaderVirtualWindow } from '@/hooks/use-reader-virtual-window';

function makePage(id: string) {
  return { id };
}

function makeScrollRef() {
  return {
    current: {
      scrollTop: 0,
      clientHeight: 700,
      addEventListener: jest.fn(),
      removeEventListener: jest.fn(),
      scrollTo: jest.fn(),
    } as unknown as HTMLDivElement,
  };
}

describe('useReaderVirtualWindow', () => {
  beforeEach(() => {
    window.requestAnimationFrame = (cb: FrameRequestCallback) => {
      cb(0);
      return 0;
    };
  });

  it('keeps processing pages mounted even when they are outside the initial window', () => {
    const pages = Array.from({ length: 30 }, (_, index) => makePage(`p${index}`));
    const pageRefs = { current: new Map<string, HTMLDivElement>() };
    const scrollRef = makeScrollRef();

    const { result } = renderHook(() =>
      useReaderVirtualWindow({
        visiblePages: pages,
        processingIds: new Set(['p25']),
        currentChapterId: 'ch-1',
        activePageId: null,
        isTranslationOnly: false,
        pageRefs,
        scrollRef,
      }),
    );

    expect(result.current.visibleWindowPages.some((page) => page.id === 'p25')).toBe(true);
  });

  it('mounts pages before the current virtual window before scrolling to them', () => {
    const pages = Array.from({ length: 40 }, (_, index) => makePage(`p${index}`));
    const pageRefs = { current: new Map<string, HTMLDivElement>() };
    const scrollRef = makeScrollRef();

    const { result } = renderHook(() =>
      useReaderVirtualWindow({
        visiblePages: pages,
        processingIds: new Set(),
        currentChapterId: 'ch-1',
        activePageId: null,
        isTranslationOnly: false,
        pageRefs,
        scrollRef,
      }),
    );

    act(() => {
      scrollRef.current.scrollTop = 14000;
      result.current.recalcWindow();
    });
    expect(result.current.visibleWindowPages.some((page) => page.id === 'p2')).toBe(false);

    act(() => {
      result.current.scrollToPageId('p2');
    });

    expect(result.current.visibleWindowPages.some((page) => page.id === 'p2')).toBe(true);
  });
});
