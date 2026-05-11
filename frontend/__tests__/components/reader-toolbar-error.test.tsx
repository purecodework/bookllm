import { render, screen } from '@testing-library/react';
import { ReaderToolbar } from '@/components/reader/reader-toolbar';
import type { Book, Chapter } from '@/lib/api';

jest.mock('@/hooks/use-translation-control', () => ({
  useTranslationControl: () => ({
    phase: 'idle',
    isPaused: false,
    start: jest.fn(),
    togglePause: jest.fn(),
    startLoading: false,
    toggleLoading: false,
    error: 'Model is at capacity',
  }),
}));

jest.mock('@/components/reader/translation-progress-bar', () => ({
  TranslationProgressBar: () => <div>progress</div>,
}));

jest.mock('@/components/reader/reader-settings', () => ({
  ReaderSettings: () => <div>settings</div>,
}));

jest.mock('@/components/reader/download-popover', () => ({
  DownloadPopover: () => <div>download</div>,
}));

const book: Book = {
  id: 'b1',
  title: 'Book',
  sourceLang: 'en',
  targetLang: 'zh',
  status: 'pending',
  translationProgress: 0,
  chapterId: 'c1',
  createdAt: new Date().toISOString(),
  updatedAt: new Date().toISOString(),
};

const chapter: Chapter = {
  id: 'c1',
  bookId: 'b1',
  chapterNumber: 1,
  title: 'ch1',
  status: 'pending',
  translationProgress: 0,
  createdAt: new Date().toISOString(),
  updatedAt: new Date().toISOString(),
};

describe('ReaderToolbar error visibility', () => {
  it('renders explicit error message instead of icon-only indicator', () => {
    render(
      <ReaderToolbar
        book={book}
        chapters={[chapter]}
        currentChapter={chapter}
        onChapterChange={() => undefined}
        onTranslationStarted={() => undefined}
        prefs={{ fontSize: 'base', lineHeight: 'relaxed' }}
        onUpdatePrefs={() => undefined}
        hasTranslated={false}
      />,
    );

    expect(screen.getByText(/Translation failed: Model is at capacity/)).toBeInTheDocument();
  });

  it('shows token counts in the toolbar language slot', () => {
    render(
      <ReaderToolbar
        book={book}
        chapters={[chapter]}
        currentChapter={chapter}
        onChapterChange={() => undefined}
        onTranslationStarted={() => undefined}
        prefs={{ fontSize: 'base', lineHeight: 'relaxed' }}
        onUpdatePrefs={() => undefined}
        hasTranslated={false}
        usageStats={{ inputTokens: 1234, outputTokens: 5678 }}
      />,
    );

    expect(screen.getByText('Est. in 1.2k')).toBeInTheDocument();
    expect(screen.getByText('Est. out 5.7k')).toBeInTheDocument();
    expect(screen.queryByText('English')).not.toBeInTheDocument();
  });
});
