import { BadRequestException, NotFoundException } from '@nestjs/common';
import { TranslationControlService } from './translation-control.service';
import { type PrismaService } from '../prisma/prisma.service';
import { type TranslationQueueService } from './translation.queue';
import { type RedisPubSubService } from '../redis/redis-pubsub.service';

jest.mock('../common/logging/app-logger', () => ({
  logInfo: jest.fn(),
  logWarn: jest.fn(),
  logError: jest.fn(),
}));

function makePrismaMock() {
  return {
    $executeRawUnsafe: jest.fn().mockResolvedValue(undefined),
    chapter: {
      findMany: jest.fn(),
      findUnique: jest.fn(),
      findFirst: jest.fn(),
      update: jest.fn(),
      updateMany: jest.fn(),
    },
    page: {
      findMany: jest.fn(),
    },
    book: {
      findUnique: jest.fn(),
      findMany: jest.fn(),
      count: jest.fn().mockResolvedValue(0),
      update: jest.fn(),
      updateMany: jest.fn(),
    },
    bookOriginalAsset: {
      findUnique: jest.fn().mockResolvedValue(null),
    },
    settings: {
      findUnique: jest.fn().mockResolvedValue(null),
      upsert: jest.fn().mockResolvedValue(undefined),
    },
  };
}

function makeQueueMock() {
  return {
    enqueuePage: jest.fn().mockResolvedValue('job_1'),
    drain: jest.fn().mockResolvedValue(undefined),
    resume: jest.fn().mockResolvedValue(undefined),
    pause: jest.fn().mockResolvedValue(undefined),
    isPaused: jest.fn().mockResolvedValue(false),
  };
}

function makeRedisMock() {
  return {
    publishBookEvent: jest.fn().mockResolvedValue(undefined),
    getValue: jest.fn().mockResolvedValue(null),
    setValue: jest.fn().mockResolvedValue(undefined),
  };
}

function makeChapter(overrides: Partial<Record<string, unknown>> = {}) {
  return {
    id: 'ch_1',
    bookId: 'book_1',
    chapterNumber: 1,
    title: '第一章',
    status: 'pending',
    translationProgress: 0,
    translationStartedAt: null,
    tokensPerSecond: null,
    pages: [],
    createdAt: new Date('2026-01-01'),
    updatedAt: new Date('2026-01-01'),
    ...overrides,
  };
}

describe('TranslationControlService', () => {
  let service: TranslationControlService;
  let prisma: ReturnType<typeof makePrismaMock>;
  let queue: ReturnType<typeof makeQueueMock>;
  let redis: ReturnType<typeof makeRedisMock>;
  let settingsService: {
    getSidekickConfig: jest.Mock;
    getEffectiveSidekickConfig: jest.Mock;
    getTranslationConfig: jest.Mock;
  };
  let reviewService: {
    extractGlossaryWithModel: jest.Mock;
    extractGlossaryFromSegmentsWithModel: jest.Mock;
    extractGlossarySegmentWithModel: jest.Mock;
    reduceBookContextPackagesWithModel: jest.Mock;
  };
  let glossaryService: {
    toGlossaryMap: jest.Mock;
    toBookContextPackage: jest.Mock;
    mergeGlossaries: jest.Mock;
    extractGlossaryTerms: jest.Mock;
    extractGlossaryTermsRecursive: jest.Mock;
    extractBookContextFromSegments: jest.Mock;
    extractBookContextSegment: jest.Mock;
    reduceBookContextPackages: jest.Mock;
  };
  let originalChapterEndpointFlag: string | undefined;

  beforeEach(() => {
    originalChapterEndpointFlag = process.env.TRANSLATION_ENABLE_CHAPTER_ENDPOINT;
    delete process.env.TRANSLATION_ENABLE_CHAPTER_ENDPOINT;
    prisma = makePrismaMock();
    queue = makeQueueMock();
    redis = makeRedisMock();
    settingsService = {
      getSidekickConfig: jest.fn().mockResolvedValue({ enabled: false }),
      getEffectiveSidekickConfig: jest.fn().mockResolvedValue({ enabled: false }),
      getTranslationConfig: jest.fn().mockResolvedValue({
        glossaryEnabled: false,
        glossaryModelSource: 'primary',
      }),
    };
    reviewService = {
      extractGlossaryWithModel: jest.fn().mockResolvedValue({}),
      extractGlossaryFromSegmentsWithModel: jest.fn().mockResolvedValue({ version: 2, entries: [], doNotTranslate: [], forbiddenTranslations: [], styleGuide: {}, chapterSummaries: [], sections: [] }),
      extractGlossarySegmentWithModel: jest.fn().mockResolvedValue({ version: 2, entries: [], doNotTranslate: [], forbiddenTranslations: [], styleGuide: {}, chapterSummaries: [], sections: [] }),
      reduceBookContextPackagesWithModel: jest.fn().mockResolvedValue({ version: 2, entries: [], doNotTranslate: [], forbiddenTranslations: [], styleGuide: {}, chapterSummaries: [], sections: [] }),
    };
    glossaryService = {
      toGlossaryMap: jest.fn().mockReturnValue({}),
      toBookContextPackage: jest.fn().mockReturnValue({ version: 2, entries: [], doNotTranslate: [], forbiddenTranslations: [], styleGuide: {}, chapterSummaries: [], sections: [] }),
      mergeGlossaries: jest.fn((_existing, extracted) => extracted),
      extractGlossaryTerms: jest.fn().mockResolvedValue({}),
      extractGlossaryTermsRecursive: jest.fn().mockResolvedValue({ version: 2, entries: [], doNotTranslate: [], forbiddenTranslations: [], styleGuide: {}, chapterSummaries: [], sections: [] }),
      extractBookContextFromSegments: jest.fn().mockResolvedValue({ version: 2, entries: [], doNotTranslate: [], forbiddenTranslations: [], styleGuide: {}, chapterSummaries: [], sections: [] }),
      extractBookContextSegment: jest.fn().mockResolvedValue({ version: 2, entries: [], doNotTranslate: [], forbiddenTranslations: [], styleGuide: {}, chapterSummaries: [], sections: [] }),
      reduceBookContextPackages: jest.fn().mockResolvedValue({ version: 2, entries: [], doNotTranslate: [], forbiddenTranslations: [], styleGuide: {}, chapterSummaries: [], sections: [] }),
    };
    service = new TranslationControlService(
      prisma as unknown as PrismaService,
      queue as unknown as TranslationQueueService,
      redis as unknown as RedisPubSubService,
      settingsService as never,
      reviewService as never,
      glossaryService as never,
    );
  });

  afterEach(() => {
    if (originalChapterEndpointFlag === undefined) {
      delete process.env.TRANSLATION_ENABLE_CHAPTER_ENDPOINT;
      return;
    }
    process.env.TRANSLATION_ENABLE_CHAPTER_ENDPOINT = originalChapterEndpointFlag;
  });

  describe('startTranslation (chapter-level)', () => {
    it('is disabled by default without the feature flag', async () => {
      await expect(service.startTranslation('ch_1')).rejects.toBeInstanceOf(BadRequestException);
      await expect(service.startTranslation('ch_1')).rejects.toThrow(
        'Chapter-level translation is disabled by default',
      );
    });

    it('allows chapter-level start when feature flag is enabled', async () => {
      process.env.TRANSLATION_ENABLE_CHAPTER_ENDPOINT = 'true';
      prisma.chapter.findUnique.mockResolvedValue(makeChapter());
      prisma.book.findUnique.mockResolvedValue({ id: 'book_1', sourceLang: 'zh', targetLang: 'en' });
      prisma.page.findMany.mockResolvedValue([{ id: 'p1', pageNumber: 1, sourceText: 'hello' }]);
      prisma.chapter.update.mockResolvedValue(makeChapter({ status: 'processing' }));
      prisma.book.findUnique.mockResolvedValue({
        id: 'book_1',
        status: 'pending',
        chapters: [{ translationProgress: 0 }],
        sourceLang: 'zh',
        targetLang: 'en',
      });

      const result = await service.startTranslation('ch_1');

      expect(result.enqueuedPages).toBe(1);
      expect(queue.enqueuePage).toHaveBeenCalledTimes(1);
    });

    it('enqueues all OCR-completed untranslated pages and returns the count', async () => {
      prisma.chapter.findUnique.mockResolvedValue(makeChapter());
      prisma.book.findUnique.mockResolvedValue({
        id: 'book_1', sourceLang: 'zh', targetLang: 'en',
        status: 'pending', chapters: [{ translationProgress: 0 }],
      });
      prisma.page.findMany.mockResolvedValue([
        { id: 'p1', pageNumber: 1, sourceText: 'hello' },
        { id: 'p2', pageNumber: 2, sourceText: 'world' },
      ]);
      prisma.chapter.update.mockResolvedValue(makeChapter({ status: 'processing' }));

      const result = await service.startTranslation('ch_1', { internal: true });

      expect(result.enqueuedPages).toBe(2);
      expect(queue.enqueuePage).toHaveBeenCalledTimes(2);
      expect(queue.enqueuePage).toHaveBeenCalledWith(
        expect.objectContaining({ sourceLang: 'zh', targetLang: 'en' }),
      );
    });

    it('sets translationStartedAt when starting translation', async () => {
      const before = new Date();
      prisma.chapter.findUnique.mockResolvedValue(makeChapter());
      prisma.book.findUnique.mockResolvedValue({
        id: 'book_1', sourceLang: 'zh', targetLang: 'en',
        status: 'pending', chapters: [{ translationProgress: 0 }],
      });
      prisma.page.findMany.mockResolvedValue([{ id: 'p1', pageNumber: 1, sourceText: 'x' }]);
      prisma.chapter.update.mockResolvedValue(makeChapter({ status: 'processing' }));

      await service.startTranslation('ch_1', { internal: true });
      const after = new Date();

      expect(prisma.chapter.update).toHaveBeenCalledWith(
        expect.objectContaining({
          data: expect.objectContaining({
            status: 'processing',
            translationProgress: 0,
            translationStartedAt: expect.any(Date),
          }),
        }),
      );
      const calledWith = (prisma.chapter.update as jest.Mock).mock.calls[0][0] as {
        data: { translationStartedAt: Date };
      };
      const startedAt = calledWith.data.translationStartedAt;
      expect(startedAt.getTime()).toBeGreaterThanOrEqual(before.getTime());
      expect(startedAt.getTime()).toBeLessThanOrEqual(after.getTime());
    });

    it('throws BadRequestException when no OCR-completed pages exist', async () => {
      prisma.chapter.findUnique.mockResolvedValue(makeChapter());
      prisma.book.findUnique.mockResolvedValue({
        id: 'book_1', sourceLang: 'zh', targetLang: 'en',
        status: 'pending', chapters: [],
      });
      prisma.page.findMany.mockResolvedValue([]);

      await expect(service.startTranslation('ch_1', { internal: true })).rejects.toBeInstanceOf(
        BadRequestException,
      );
      expect(queue.enqueuePage).not.toHaveBeenCalled();
    });

    it('throws NotFoundException when chapter does not exist', async () => {
      prisma.chapter.findUnique.mockResolvedValue(null);

      await expect(service.startTranslation('missing', { internal: true })).rejects.toBeInstanceOf(
        NotFoundException,
      );
    });

    it('marks sidekick glossary complete after a successful extraction', async () => {
      settingsService.getTranslationConfig.mockResolvedValue({
        glossaryEnabled: true,
        glossaryModelSource: 'sidekick',
      });
      settingsService.getEffectiveSidekickConfig.mockResolvedValue({
        enabled: true,
        baseUrl: 'http://localhost:11434/v1',
        model: 'review-model',
      });
      reviewService.extractGlossaryFromSegmentsWithModel.mockResolvedValue({
        version: 2,
        entries: [{ source: 'Frodo', target: 'Frodon', type: 'character', aliases: [] }],
        doNotTranslate: [],
        forbiddenTranslations: [],
        styleGuide: {},
        chapterSummaries: [],
        sections: [],
      });
      prisma.chapter.findUnique.mockResolvedValue(makeChapter());
      prisma.book.findUnique.mockResolvedValue({
        id: 'book_1',
        sourceLang: 'es',
        targetLang: 'fr',
        status: 'pending',
        chapters: [{ translationProgress: 0 }],
        glossary: {},
      });
      prisma.page.findMany.mockResolvedValue([{ id: 'p1', pageNumber: 1, sourceText: 'Frodo camina.' }]);
      prisma.chapter.update.mockResolvedValue(makeChapter({ status: 'processing' }));

      await service.startTranslation('ch_1', { internal: true });

      expect(reviewService.extractGlossaryFromSegmentsWithModel).toHaveBeenCalledTimes(1);
      expect(prisma.settings.upsert).toHaveBeenCalledWith({
        where: { key: 'translation.glossary.done.ch_1.fr' },
        update: { value: 'true' },
        create: { key: 'translation.glossary.done.ch_1.fr', value: 'true' },
      });
    });

    it('skips sidekick glossary when the chapter target language marker already exists', async () => {
      settingsService.getTranslationConfig.mockResolvedValue({
        glossaryEnabled: true,
        glossaryModelSource: 'sidekick',
      });
      settingsService.getEffectiveSidekickConfig.mockResolvedValue({
        enabled: true,
        baseUrl: 'http://localhost:11434/v1',
        model: 'review-model',
      });
      prisma.settings.findUnique.mockResolvedValue({ value: 'true' });
      prisma.chapter.findUnique.mockResolvedValue(makeChapter());
      prisma.book.findUnique.mockResolvedValue({
        id: 'book_1',
        sourceLang: 'de',
        targetLang: 'ja',
        status: 'pending',
        chapters: [{ translationProgress: 0 }],
        glossary: { Berlin: 'ベルリン' },
      });
      prisma.page.findMany.mockResolvedValue([{ id: 'p1', pageNumber: 1, sourceText: 'Berlin.' }]);
      prisma.chapter.update.mockResolvedValue(makeChapter({ status: 'processing' }));

      await service.startTranslation('ch_1', { internal: true });

      expect(reviewService.extractGlossaryWithModel).not.toHaveBeenCalled();
      expect(prisma.settings.upsert).not.toHaveBeenCalled();
      expect(queue.enqueuePage).toHaveBeenCalledTimes(1);
    });
  });

  describe('startBookTranslation', () => {
    it('returns early without draining queue when same book is already processing', async () => {
      prisma.book.findUnique.mockResolvedValue({ id: 'book_1', status: 'processing' });

      const result = await service.startBookTranslation('book_1');

      expect(result).toEqual({ enqueuedPages: 0 });
      expect(queue.drain).not.toHaveBeenCalled();
    });

    it('resets other processing books and enqueues current book', async () => {
      prisma.book.findUnique
        .mockResolvedValueOnce({ id: 'book_1', status: 'pending' })
        .mockResolvedValue({ id: 'book_1', status: 'processing', chapters: [{ translationProgress: 0 }], sourceLang: 'en', targetLang: 'zh' });
      prisma.book.findMany.mockResolvedValue([]);
      prisma.chapter.findMany
        .mockResolvedValueOnce([{ id: 'ch_1', chapterNumber: 1, status: 'pending', title: '第一章' }]);
      prisma.chapter.findUnique.mockResolvedValue(makeChapter());
      prisma.page.findMany.mockResolvedValue([{ id: 'p1', pageNumber: 1, sourceText: 'hello' }]);
      prisma.chapter.update.mockResolvedValue(makeChapter({ status: 'processing' }));

      const result = await service.startBookTranslation('book_1');

      expect(queue.drain).toHaveBeenCalledTimes(1);
      expect(prisma.chapter.updateMany).toHaveBeenCalledWith({
        where: { bookId: { not: 'book_1' }, status: 'processing' },
        data: { status: 'pending' },
      });
      expect(prisma.book.updateMany).toHaveBeenCalledWith({
        where: { id: { not: 'book_1' }, status: 'processing' },
        data: { status: 'pending' },
      });
      expect(queue.resume).toHaveBeenCalledTimes(1);
      expect(result.enqueuedPages).toBe(1);
    });

    it('resets book back to pending when all chapters already translated', async () => {
      prisma.book.findUnique
        .mockResolvedValueOnce({ id: 'book_1', status: 'pending' })
        .mockResolvedValue({ id: 'book_1', status: 'pending', chapters: [{ translationProgress: 0 }] });
      prisma.book.findMany.mockResolvedValue([]);
      prisma.chapter.findMany.mockResolvedValueOnce([]);

      await expect(service.startBookTranslation('book_1')).rejects.toMatchObject({
        response: expect.objectContaining({ businessCode: 'BOOK_ALREADY_TRANSLATED' }),
      });

      expect(prisma.book.update).toHaveBeenCalledWith({
        where: { id: 'book_1' },
        data: { status: 'processing' },
      });
      expect(prisma.book.update).toHaveBeenCalledWith({
        where: { id: 'book_1' },
        data: { status: 'pending' },
      });
    });

    it('does not leave book processing when every chapter has no translatable pages', async () => {
      prisma.book.findUnique
        .mockResolvedValueOnce({ id: 'book_1', status: 'pending' })
        .mockResolvedValue({ id: 'book_1', sourceLang: 'en', targetLang: 'zh', status: 'pending', chapters: [{ translationProgress: 0 }] });
      prisma.book.findMany.mockResolvedValue([]);
      prisma.chapter.findMany
        .mockResolvedValueOnce([{ id: 'ch_1', chapterNumber: 1, status: 'pending', title: '第一章' }]);
      prisma.chapter.findUnique.mockResolvedValue(makeChapter());
      prisma.page.findMany.mockResolvedValue([]);

      await expect(service.startBookTranslation('book_1')).rejects.toMatchObject({
        response: expect.objectContaining({ businessCode: 'BOOK_NO_TRANSLATABLE_PAGES' }),
      });

      expect(queue.enqueuePage).not.toHaveBeenCalled();
      expect(prisma.book.update).toHaveBeenCalledWith({
        where: { id: 'book_1' },
        data: { status: 'pending' },
      });
    });

    it('finishes book glossary and writes the final package before enqueueing pages', async () => {
      const order: string[] = [];
      settingsService.getTranslationConfig.mockResolvedValue({
        glossaryEnabled: true,
        glossaryModelSource: 'primary',
        contextWindowTokens: 8192,
        inputTokenBudget: 2000,
        concurrency: 4,
      });
      glossaryService.extractBookContextSegment.mockImplementation(async () => {
        order.push('extract');
        return {
          version: 2,
          entries: [{ source: 'Frodo', target: '佛罗多', type: 'character', aliases: [] }],
          doNotTranslate: [],
          forbiddenTranslations: [],
          styleGuide: {},
          chapterSummaries: [],
          sections: [{ id: 'section_0001', pageStart: 1, pageEnd: 2, summary: 'summary' }],
        };
      });
      queue.enqueuePage.mockImplementation(async () => {
        order.push('enqueue');
        return 'job_1';
      });
      prisma.book.update.mockImplementation(async (args: { data?: { glossary?: unknown } }) => {
        if (args.data?.glossary) order.push('writeGlossary');
        return undefined;
      });
      prisma.book.findUnique
        .mockResolvedValueOnce({ id: 'book_1', status: 'pending', sourceLang: 'en', targetLang: 'zh' })
        .mockResolvedValue({ id: 'book_1', sourceLang: 'en', targetLang: 'zh', status: 'processing', chapters: [{ translationProgress: 0 }], glossary: {} });
      prisma.book.findMany.mockResolvedValue([]);
      prisma.chapter.findMany.mockResolvedValueOnce([{ id: 'ch_1', chapterNumber: 1, status: 'pending', title: '第一章' }]);
      prisma.chapter.update.mockResolvedValue(makeChapter({ status: 'processing', translationStartedAt: new Date() }));
      prisma.page.findMany.mockResolvedValue([
        {
          id: 'p1',
          chapterId: 'ch_1',
          pageNumber: 1,
          sourceText: 'Frodo walks.',
          chapter: { id: 'ch_1', title: '第一章', chapterNumber: 1 },
        },
        {
          id: 'p2',
          chapterId: 'ch_1',
          pageNumber: 2,
          sourceText: 'Frodo returns.',
          chapter: { id: 'ch_1', title: '第一章', chapterNumber: 1 },
        },
      ]);

      const result = await service.startBookTranslation('book_1');

      expect(result.enqueuedPages).toBe(2);
      expect(glossaryService.extractBookContextSegment).toHaveBeenCalledTimes(1);
      expect(prisma.book.update).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { id: 'book_1' },
          data: expect.objectContaining({ glossary: expect.any(Object) }),
        }),
      );
      expect(queue.enqueuePage).toHaveBeenCalledTimes(2);
      expect(order.indexOf('extract')).toBeLessThan(order.indexOf('enqueue'));
      expect(order.indexOf('writeGlossary')).toBeLessThan(order.indexOf('enqueue'));
      expect(redis.publishBookEvent).toHaveBeenCalledWith(
        'book_1',
        'usage_delta',
        expect.objectContaining({ stage: 'glossary', inputTokens: expect.any(Number) }),
      );
      expect(redis.publishBookEvent).toHaveBeenCalledWith(
        'book_1',
        'glossary_progress',
        expect.objectContaining({ completedSections: 1, totalSections: 1 }),
      );
      const calls = redis.publishBookEvent.mock.calls.map((call) => ({
        type: call[1],
        payload: call[2] as { extracting?: boolean },
      }));
      const doneIndex = calls.findIndex((call) =>
        call.type === 'glossary_extracting' && call.payload.extracting === false,
      );
      expect(doneIndex).toBeGreaterThan(-1);
      expect(order.indexOf('enqueue')).toBeGreaterThan(order.indexOf('writeGlossary'));
    });

    it('reuses cached book context from Redis and skips LLM extraction', async () => {
      const cachedPackage = {
        version: 2,
        entries: [{ source: 'Frodo', target: '佛罗多', type: 'character', aliases: [] }],
        doNotTranslate: [],
        forbiddenTranslations: [],
        styleGuide: {},
        chapterSummaries: [],
        sections: [{ id: 'section_0001', pageStart: 1, pageEnd: 1, summary: 'cached' }],
      };
      settingsService.getTranslationConfig.mockResolvedValue({
        glossaryEnabled: true,
        glossaryModelSource: 'primary',
        contextWindowTokens: 8192,
        inputTokenBudget: 2000,
        concurrency: 4,
      });
      prisma.bookOriginalAsset.findUnique.mockResolvedValue({ sha256: 'abc123' });
      redis.getValue.mockResolvedValue(JSON.stringify(cachedPackage));
      prisma.book.findUnique
        .mockResolvedValueOnce({ id: 'book_1', status: 'pending', sourceLang: 'en', targetLang: 'zh' })
        .mockResolvedValue({ id: 'book_1', sourceLang: 'en', targetLang: 'zh', status: 'processing', pages: [], glossary: {} });
      prisma.book.findMany.mockResolvedValue([]);
      prisma.chapter.findMany.mockResolvedValueOnce([{ id: 'ch_1', chapterNumber: 1, status: 'pending', title: '第一章' }]);
      prisma.chapter.update.mockResolvedValue(makeChapter({ status: 'processing', translationStartedAt: new Date() }));
      prisma.page.findMany.mockResolvedValue([
        {
          id: 'p1',
          chapterId: 'ch_1',
          pageNumber: 1,
          sourceText: 'Frodo walks.',
          chapter: { id: 'ch_1', title: '第一章', chapterNumber: 1 },
        },
      ]);

      const result = await service.startBookTranslation('book_1');

      expect(result).toEqual({ enqueuedPages: 1 });
      expect(redis.getValue).toHaveBeenCalledWith(
        'cache:book-context-v1:section-map-reduce-v1:abc123:zh:primary:8192:2000',
      );
      expect(glossaryService.extractBookContextSegment).not.toHaveBeenCalled();
      expect(prisma.book.update).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { id: 'book_1' },
          data: { glossary: expect.objectContaining({ entries: cachedPackage.entries }) },
        }),
      );
      expect(queue.enqueuePage).toHaveBeenCalledTimes(1);
    });

    it('writes successful book context extraction to Redis cache when source hash exists', async () => {
      settingsService.getTranslationConfig.mockResolvedValue({
        glossaryEnabled: true,
        glossaryModelSource: 'primary',
        contextWindowTokens: 8192,
        inputTokenBudget: 2000,
        concurrency: 4,
      });
      prisma.bookOriginalAsset.findUnique.mockResolvedValue({ sha256: 'abc123' });
      glossaryService.extractBookContextSegment.mockResolvedValue({
        version: 2,
        entries: [{ source: 'Frodo', target: '佛罗多', type: 'character', aliases: [] }],
        doNotTranslate: [],
        forbiddenTranslations: [],
        styleGuide: {},
        chapterSummaries: [],
        sections: [{ id: 'section_0001', pageStart: 1, pageEnd: 1, summary: 'summary' }],
      });
      prisma.book.findUnique
        .mockResolvedValueOnce({ id: 'book_1', status: 'pending', sourceLang: 'en', targetLang: 'zh' })
        .mockResolvedValue({ id: 'book_1', sourceLang: 'en', targetLang: 'zh', status: 'processing', pages: [], glossary: {} });
      prisma.book.findMany.mockResolvedValue([]);
      prisma.chapter.findMany.mockResolvedValueOnce([{ id: 'ch_1', chapterNumber: 1, status: 'pending', title: '第一章' }]);
      prisma.chapter.update.mockResolvedValue(makeChapter({ status: 'processing', translationStartedAt: new Date() }));
      prisma.page.findMany.mockResolvedValue([
        {
          id: 'p1',
          chapterId: 'ch_1',
          pageNumber: 1,
          sourceText: 'Frodo walks.',
          chapter: { id: 'ch_1', title: '第一章', chapterNumber: 1 },
        },
      ]);

      await service.startBookTranslation('book_1');

      expect(redis.setValue).toHaveBeenCalledWith(
        'cache:book-context-v1:section-map-reduce-v1:abc123:zh:primary:8192:2000',
        expect.stringContaining('Frodo'),
        604800,
      );
    });

    it('uses deterministic merge and then enqueues pages when reduce fails', async () => {
      const order: string[] = [];
      let writtenGlossary: unknown = null;
      const longPage = Array.from({ length: 3200 }, () => 'Alpha').join(' ');
      settingsService.getTranslationConfig.mockResolvedValue({
        glossaryEnabled: true,
        glossaryModelSource: 'primary',
        contextWindowTokens: 8192,
        inputTokenBudget: 1800,
        concurrency: 4,
      });
      glossaryService.extractBookContextSegment.mockImplementation(async (segment: { sectionId: string }) => ({
        version: 2,
        entries: [
          {
            source: 'Alpha',
            target: segment.sectionId === 'section_0001' ? '阿尔法' : '艾尔法',
            type: 'term',
            aliases: [],
          },
        ],
        doNotTranslate: [],
        forbiddenTranslations: [],
        styleGuide: {},
        chapterSummaries: [],
        sections: [{ id: segment.sectionId, summary: segment.sectionId }],
      }));
      glossaryService.reduceBookContextPackages.mockRejectedValue(new Error('reduce unavailable'));
      queue.enqueuePage.mockImplementation(async () => {
        order.push('enqueue');
        return 'job_1';
      });
      prisma.book.update.mockImplementation(async (args: { data?: { glossary?: unknown } }) => {
        if (args.data?.glossary) {
          order.push('writeGlossary');
          writtenGlossary = args.data.glossary;
        }
        return undefined;
      });
      prisma.book.findUnique
        .mockResolvedValueOnce({ id: 'book_1', status: 'pending', sourceLang: 'en', targetLang: 'zh' })
        .mockResolvedValue({ id: 'book_1', sourceLang: 'en', targetLang: 'zh', status: 'processing', chapters: [{ translationProgress: 0 }], glossary: {} });
      prisma.book.findMany.mockResolvedValue([]);
      prisma.chapter.findMany.mockResolvedValueOnce([{ id: 'ch_1', chapterNumber: 1, status: 'pending', title: '第一章' }]);
      prisma.chapter.update.mockResolvedValue(makeChapter({ status: 'processing', translationStartedAt: new Date() }));
      prisma.page.findMany.mockResolvedValue([
        {
            id: 'p1',
            chapterId: 'ch_1',
            pageNumber: 1,
            sourceText: longPage,
            chapter: { id: 'ch_1', title: '第一章', chapterNumber: 1 },
        },
        {
            id: 'p2',
            chapterId: 'ch_1',
            pageNumber: 2,
            sourceText: longPage,
            chapter: { id: 'ch_1', title: '第一章', chapterNumber: 1 },
        },
      ]);

      const result = await service.startBookTranslation('book_1');

      expect(result).toEqual({ enqueuedPages: 2 });
      expect(glossaryService.extractBookContextSegment).toHaveBeenCalledTimes(2);
      expect(glossaryService.reduceBookContextPackages).not.toHaveBeenCalled();
      expect(order.indexOf('writeGlossary')).toBeLessThan(order.indexOf('enqueue'));
      expect(writtenGlossary).toMatchObject({
        entries: [{ source: 'Alpha', target: '阿尔法' }],
        forbiddenTranslations: [{ source: 'Alpha', forbidden: ['艾尔法'], prefer: '阿尔法' }],
      });
    });
  });

  describe('pauseTranslation / resumeTranslation', () => {
    it('pauses the queue and returns paused: true', async () => {
      prisma.chapter.findFirst.mockResolvedValue({ bookId: 'book_1' });

      const result = await service.pauseTranslation();

      expect(queue.pause).toHaveBeenCalledTimes(1);
      expect(result).toEqual({ paused: true });
    });

    it('resumes the queue and returns paused: false', async () => {
      prisma.chapter.findFirst.mockResolvedValue({ bookId: 'book_1' });

      const result = await service.resumeTranslation();

      expect(queue.resume).toHaveBeenCalledTimes(1);
      expect(result).toEqual({ paused: false });
    });
  });

  describe('getQueueStatus', () => {
    it('returns isPaused from the queue', async () => {
      queue.isPaused.mockResolvedValue(true);

      const result = await service.getQueueStatus();

      expect(result).toEqual({ isPaused: true });
    });
  });
});
