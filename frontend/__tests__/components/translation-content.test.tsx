import { render, screen } from '@testing-library/react';
import { TranslationContent } from '@/components/reader/translation-content';
import type { Page } from '@/lib/api';

const basePage: Page = {
  id: 'p1',
  bookId: 'b1',
  chapterId: 'c1',
  pageNumber: 1,
  sourceText: 'source',
  targetText: null,
  ocrStatus: 'completed',
  translationStatus: 'pending',
  retryCount: 0,
  errorMessage: null,
  createdAt: new Date().toISOString(),
  updatedAt: new Date().toISOString(),
};

describe('TranslationContent', () => {
  it('shows LLM prefill state after an empty stream token connects the page', () => {
    render(
      <TranslationContent
        page={{ ...basePage, translationStatus: 'processing' }}
        fontSize="text-base"
        lineHeight="leading-7"
        isConnected
        bookId="b1"
      />,
    );

    expect(screen.getByText('LLM Prefill')).toBeInTheDocument();
  });

  it('shows readable error details when translation failed', () => {
    render(
      <TranslationContent
        page={{ ...basePage, translationStatus: 'failed', errorMessage: 'LLM connection refused' }}
        fontSize="text-base"
        lineHeight="leading-7"
        bookId="b1"
      />,
    );

    expect(screen.getByText('Translation failed')).toBeInTheDocument();
    expect(screen.getByText('LLM connection refused')).toBeInTheDocument();
  });
});
