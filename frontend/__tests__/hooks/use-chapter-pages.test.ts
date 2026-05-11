import { renderHook, act, waitFor } from '@testing-library/react';
import { useChapterPages } from '@/hooks/use-chapter-pages';
import type { Chapter, Page } from '@/lib/api';

jest.mock('@/lib/api', () => ({
  fetchPagesByChapter: jest.fn(),
}));

import { fetchPagesByChapter } from '@/lib/api';
const mockFetch = fetchPagesByChapter as jest.Mock;

function makeChapter(overrides: Partial<Chapter> = {}): Chapter {
  return {
    id: 'ch-1',
    bookId: 'book-1',
    chapterNumber: 1,
    title: null,
    status: 'pending',
    translationProgress: 0,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    ...overrides,
  };
}

function makePage(overrides: Partial<Page> = {}): Page {
  return {
    id: `page-${Math.random()}`,
    bookId: 'book-1',
    chapterId: 'ch-1',
    pageNumber: 1,
    sourceText: 'hello',
    targetText: null,
    ocrStatus: 'completed',
    translationStatus: 'pending',
    retryCount: 0,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    ...overrides,
  };
}

describe('useChapterPages', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    localStorage.clear();
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  function renderWithRefs(chapter: Chapter | null) {
    const { result } = renderHook(() =>
      useChapterPages('book-1', chapter),
    );
    return result;
  }

  it('returns empty pages when chapter is null', () => {
    mockFetch.mockResolvedValue([]);
    const result = renderWithRefs(null);
    expect(result.current.pages).toEqual([]);
    expect(result.current.visiblePages).toEqual([]);
  });

  it('loads pages when chapter is provided', async () => {
    const pages = [makePage({ pageNumber: 1 }), makePage({ pageNumber: 2 })];
    mockFetch.mockResolvedValue(pages);

    const result = renderWithRefs(makeChapter());

    await waitFor(() => expect(result.current.pages).toHaveLength(2));
  });

  it('visiblePages = all pages when all OCR completed', async () => {
    const pages = [
      makePage({ ocrStatus: 'completed' }),
      makePage({ ocrStatus: 'completed' }),
    ];
    mockFetch.mockResolvedValue(pages);

    const result = renderWithRefs(makeChapter());
    await waitFor(() => expect(result.current.visiblePages).toHaveLength(2));
  });

  it('visiblePages stops at first OCR-unready page', async () => {
    const pages = [
      makePage({ ocrStatus: 'completed', pageNumber: 1 }),
      makePage({ ocrStatus: 'processing', pageNumber: 2 }),
      makePage({ ocrStatus: 'pending',    pageNumber: 3 }),
    ];
    mockFetch.mockResolvedValue(pages);

    const result = renderWithRefs(makeChapter());
    await waitFor(() => expect(result.current.visiblePages).toHaveLength(2));

    expect(result.current.visiblePages[1].ocrStatus).toBe('processing');
  });

  it('does not poll chapter pages repeatedly', async () => {
    mockFetch.mockResolvedValue([makePage({ translationStatus: 'completed' })]);

    renderWithRefs(makeChapter({ status: 'completed' }));
    await waitFor(() => expect(mockFetch).toHaveBeenCalledTimes(1));
    await act(async () => { jest.advanceTimersByTime(9000); });
    expect(mockFetch).toHaveBeenCalledTimes(1);
  });

  it('reloads pages when chapter changes', async () => {
    const chA = makeChapter({ id: 'ch-a', status: 'completed' });
    const chB = makeChapter({ id: 'ch-b', status: 'completed' });

    mockFetch.mockResolvedValue([makePage()]);

    const { result, rerender } = renderHook(
      ({ chapter }: { chapter: Chapter }) =>
        useChapterPages('book-1', chapter),
      { initialProps: { chapter: chA } },
    );

    await waitFor(() => expect(mockFetch).toHaveBeenCalledWith('ch-a'));

    rerender({ chapter: chB });
    await waitFor(() => expect(mockFetch).toHaveBeenCalledWith('ch-b'));
  });
});
