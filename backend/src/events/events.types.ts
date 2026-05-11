export interface QueueStatePayload {
  bookId: string;
  isPaused: boolean;
}

export interface ChapterStatePayload {
  bookId: string;
  chapterId: string;
  status: string;
  translationProgress: number;
  tokensPerSecond?: number | null;
  translationStartedAt?: string | null;
}

export interface PageTokenPayload {
  bookId: string;
  chapterId: string;
  pageId: string;
  content: string;
}

export interface PageDonePayload {
  bookId: string;
  chapterId: string;
  pageId: string;
  targetText: string;
}

export interface PageFailedPayload {
  bookId: string;
  chapterId: string;
  pageId: string;
  errorMessage: string;
}

export interface PageReviewingPayload {
  bookId: string;
  chapterId: string;
  pageId: string;
}

export interface PageReviewedPayload {
  bookId: string;
  chapterId: string;
  pageId: string;
  targetText: string;
}

export interface PagePolishingPayload {
  bookId: string;
  chapterId: string;
  pageId: string;
}

export interface GlossaryExtractingPayload {
  bookId: string;
  chapterId: string;

  extracting: boolean;
}

export interface GlossaryProgressPayload {
  bookId: string;
  completedSections: number;
  totalSections: number;
  currentSectionId?: string;
  elapsedMs: number;
  estimatedRemainingMs?: number;
}

export interface UsageDeltaPayload {
  bookId: string;
  stage: 'glossary' | 'translation' | 'review' | 'polish';
  pageId?: string;
  sectionId?: string;
  inputTokens?: number;
  outputTokens?: number;
}

export interface PipelinePhasePayload {
  bookId: string;
  phase: 'glossary' | 'translation' | 'review' | 'polish' | 'completed';
  pageId?: string;
  label?: string;
}

export interface BookStatePayload {
  bookId: string;
  status: string;
  translationProgress: number;
}

export type EventPayloadMap = {
  queue_state: QueueStatePayload;
  chapter_state: ChapterStatePayload;
  page_token: PageTokenPayload;
  page_done: PageDonePayload;
  page_failed: PageFailedPayload;
  page_reviewing: PageReviewingPayload;
  page_reviewed: PageReviewedPayload;
  page_polishing: PagePolishingPayload;
  glossary_extracting: GlossaryExtractingPayload;
  glossary_progress: GlossaryProgressPayload;
  usage_delta: UsageDeltaPayload;
  pipeline_phase: PipelinePhasePayload;
  book_state: BookStatePayload;
};

export type EventType = keyof EventPayloadMap;

export type AppEvent<K extends EventType = EventType> = {
  type: K;
  payload: EventPayloadMap[K];
};
