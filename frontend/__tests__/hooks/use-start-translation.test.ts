import { renderHook, act } from '@testing-library/react';
import { useStartTranslation } from '@/hooks/use-start-translation';


jest.mock('@/lib/api', () => ({
  startBookTranslation: jest.fn(),
  fetchChaptersByBook: jest.fn(),
}));

import { startBookTranslation, fetchChaptersByBook } from '@/lib/api';

const mockStartBookTranslation = startBookTranslation as jest.Mock;
const mockFetchChaptersByBook = fetchChaptersByBook as jest.Mock;

const FAKE_CHAPTERS = [{ id: 'ch-1', status: 'processing', chapterNumber: 1 }];

describe('useStartTranslation', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  it('starts with translating=false and no error', () => {
    const { result } = renderHook(() => useStartTranslation('book-1'));
    expect(result.current.translating).toBe(false);
    expect(result.current.error).toBe('');
  });

  it('trigger returns new chapter list on success', async () => {
    mockStartBookTranslation.mockResolvedValue(undefined);
    mockFetchChaptersByBook.mockResolvedValue(FAKE_CHAPTERS);

    const { result } = renderHook(() => useStartTranslation('book-1'));
    let chapters: unknown;
    await act(async () => {
      chapters = await result.current.trigger();
    });

    expect(chapters).toEqual(FAKE_CHAPTERS);
    expect(result.current.translating).toBe(false);
    expect(result.current.error).toBe('');
  });

  it('sets translating=true during the async call', async () => {
    let resolveStart!: () => void;
    mockStartBookTranslation.mockReturnValue(new Promise<void>((r) => { resolveStart = r; }));
    mockFetchChaptersByBook.mockResolvedValue(FAKE_CHAPTERS);

    const { result } = renderHook(() => useStartTranslation('book-1'));

    let triggerPromise!: Promise<unknown>;
    act(() => { triggerPromise = result.current.trigger(); });

    expect(result.current.translating).toBe(true);

    await act(async () => { resolveStart(); await triggerPromise; });
    expect(result.current.translating).toBe(false);
  });

  it('returns null and sets error when startBookTranslation rejects', async () => {
    mockStartBookTranslation.mockRejectedValue(new Error('LLM offline'));

    const { result } = renderHook(() => useStartTranslation('book-1'));
    let chapters: unknown;
    await act(async () => {
      chapters = await result.current.trigger();
    });

    expect(chapters).toBeNull();
    expect(result.current.error).toBe('LLM offline');
    expect(result.current.translating).toBe(false);
  });

  it('returns null and sets fallback error for non-Error rejections', async () => {
    mockStartBookTranslation.mockRejectedValue('unknown failure');

    const { result } = renderHook(() => useStartTranslation('book-1'));
    await act(async () => { await result.current.trigger(); });

    expect(result.current.error).toBe('Failed to start translation');
  });

  it('clears previous error on the next trigger call', async () => {
    mockStartBookTranslation
      .mockRejectedValueOnce(new Error('first error'))
      .mockResolvedValue(undefined);
    mockFetchChaptersByBook.mockResolvedValue(FAKE_CHAPTERS);

    const { result } = renderHook(() => useStartTranslation('book-1'));

    await act(async () => { await result.current.trigger(); });
    expect(result.current.error).toBe('first error');

    await act(async () => { await result.current.trigger(); });
    expect(result.current.error).toBe('');
  });
});
