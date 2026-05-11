import { type Job, Worker } from 'bullmq';
import { TranslationWorker } from './translation.worker';
import { type PrismaService } from '../prisma/prisma.service';
import { type GlossaryService } from '../translation/glossary.service';
import { type TranslationChunkerService } from '../translation/translation-chunker.service';
import { type TranslatePageJobData, type TranslateChunkJobData } from './translation.queue';

jest.mock('../common/logging/app-logger', () => ({
  logInfo: jest.fn(),
  logWarn: jest.fn(),
  logError: jest.fn(),
}));

jest.mock('ioredis', () => ({
  __esModule: true,
  default: jest.fn().mockReturnValue({}),
}));

jest.mock('bullmq', () => ({
  Worker: jest.fn().mockImplementation(() => ({
    on: jest.fn(),
    close: jest.fn().mockResolvedValue(undefined),
  })),
}));

function makePrismaMock() {
  return {
    settings: {
      findUnique: jest.fn().mockResolvedValue({ value: '1' }),
    },
    page: {
      findUnique: jest.fn(),
      update: jest.fn().mockResolvedValue(undefined),
      updateMany: jest.fn().mockResolvedValue({ count: 0 }),
      count: jest.fn(),
    },
    chapter: {
      update: jest.fn().mockResolvedValue({
        id: 'ch_1',
        status: 'pending',
        translationProgress: 0,
        tokensPerSecond: null,
        translationStartedAt: null,
      }),
      updateMany: jest.fn().mockResolvedValue({ count: 0 }),
      findMany: jest.fn().mockResolvedValue([]),
      findFirst: jest.fn().mockResolvedValue({ translationProgress: 0 }),
    },
    book: {
      findUnique: jest.fn().mockResolvedValue({ glossary: {} }),
      update: jest.fn().mockResolvedValue(undefined),
      updateMany: jest.fn().mockResolvedValue({ count: 0 }),
    },
    $executeRawUnsafe: jest.fn().mockResolvedValue(undefined),
  };
}

function makeChunkerMock() {
  const mock = {
    splitIntoChunks: jest.fn().mockResolvedValue([]),
    translateChunkDirect: jest.fn(),
    translateChunkStream: jest.fn(),
  };
  mock.translateChunkStream.mockImplementation(async function* (chunk: unknown, options: unknown) {
    const translated = await mock.translateChunkDirect(chunk, options);
    if (translated?.translatedText) yield translated.translatedText;
  });
  return mock;
}

function makeGlossaryServiceMock() {
  return {
    preparePageGlossary: jest.fn().mockResolvedValue({}),
    toGlossaryMap: jest.fn().mockReturnValue({}),
    toBookContextPackage: jest.fn().mockReturnValue({ version: 2, entries: [], doNotTranslate: [], forbiddenTranslations: [], styleGuide: {}, chapterSummaries: [], sections: [] }),
  };
}

function makePageJob(data: TranslatePageJobData): Job<TranslatePageJobData> {
  return {
    id: 'job-1',
    name: 'translate-page',
    data,
    attemptsMade: 0,
  } as unknown as Job<TranslatePageJobData>;
}

function callHandlePage(instance: TranslationWorker, job: Job<TranslatePageJobData>): Promise<void> {
  const privateMethods = instance as unknown as {
    handlePage(jobArg: Job<TranslatePageJobData>): Promise<void>;
  };
  return privateMethods.handlePage(job);
}

function callHandleChunk(
  instance: TranslationWorker,
  data: TranslateChunkJobData,
): Promise<void> {
  const privateMethods = instance as unknown as {
    handleChunkStep(data: TranslateChunkJobData): Promise<void>;
  };
  return privateMethods.handleChunkStep(data);
}

function callUpdateChapterProgress(
  instance: TranslationWorker,
  chapterId: string,
  bookId: string,
  tokPerSec?: number,
): Promise<void> {
  const privateMethods = instance as unknown as {
    updateChapterProgress(chapterIdArg: string, bookIdArg: string, tokPerSecArg?: number): Promise<void>;
  };
  return privateMethods.updateChapterProgress(chapterId, bookId, tokPerSec);
}

function callUpdateBookStatus(instance: TranslationWorker, bookId: string): Promise<void> {
  const privateMethods = instance as unknown as {
    updateBookStatus(bookIdArg: string): Promise<void>;
  };
  return privateMethods.updateBookStatus(bookId);
}

function callSyncWorkerConcurrency(instance: TranslationWorker): Promise<void> {
  const privateMethods = instance as unknown as {
    syncWorkerConcurrency(): Promise<void>;
  };
  return privateMethods.syncWorkerConcurrency();
}

const BASE_PAGE_JOB_DATA: TranslatePageJobData = {
  pageId: 'page_1',
  chapterId: 'ch_1',
  bookId: 'book_1',
  sourceLang: 'en',
  targetLang: 'zh',
  chapterTitle: '第一章',
};

describe('TranslationWorker', () => {
  let worker: TranslationWorker;
  let prisma: ReturnType<typeof makePrismaMock>;
  let chunker: ReturnType<typeof makeChunkerMock>;
  let glossaryService: ReturnType<typeof makeGlossaryServiceMock>;
  let redisPubSub: {
    pageChannel: jest.Mock;
    createSubscriber: jest.Mock;
    publish: jest.Mock;
    publishBookEvent: jest.Mock;
  };
  let translationQueue: { pause: jest.Mock; resume: jest.Mock };
  let settingsService: {
    getSidekickConfig: jest.Mock;
    getEffectiveSidekickConfig: jest.Mock;
    getEffectiveLlmConfig: jest.Mock;
    getTranslationConfig: jest.Mock;
  };
  let reviewService: { reviewTranslation: jest.Mock; polishTranslation: jest.Mock };

  beforeEach(async () => {
    jest.clearAllMocks();

    (Worker as unknown as jest.Mock).mockImplementation(() => ({
      on: jest.fn(),
      close: jest.fn().mockResolvedValue(undefined),
    }));

    prisma = makePrismaMock();
    chunker = makeChunkerMock();
    glossaryService = makeGlossaryServiceMock();
    redisPubSub = {
      pageChannel: jest.fn().mockReturnValue('ch'),
      createSubscriber: jest.fn(),
      publish: jest.fn().mockResolvedValue(undefined),
      publishBookEvent: jest.fn().mockResolvedValue(undefined),
    };
    translationQueue = {
      pause: jest.fn(),
      resume: jest.fn(),
    };
    settingsService = {
      getSidekickConfig: jest.fn().mockResolvedValue({ enabled: false }),
      getEffectiveSidekickConfig: jest.fn().mockResolvedValue({ enabled: false }),
      getEffectiveLlmConfig: jest.fn().mockResolvedValue({
        baseUrl: 'http://primary.test/v1',
        apiKey: 'primary-key',
        model: 'primary-model',
      }),
      getTranslationConfig: jest.fn().mockResolvedValue({
        stylePrompt: '',
        styleEnabled: false,
        glossaryEnabled: false,
        reviewEnabled: false,
        reviewModelSource: 'primary',
      }),
    };
    reviewService = {
      reviewTranslation: jest.fn().mockImplementation((_src: unknown, draft: string) =>
        Promise.resolve(draft),
      ),
      polishTranslation: jest.fn().mockImplementation((_src: unknown, draft: string) =>
        Promise.resolve(draft),
      ),
    };
    worker = new TranslationWorker(
      prisma as unknown as PrismaService,
      chunker as unknown as TranslationChunkerService,
      glossaryService as unknown as GlossaryService,
      redisPubSub as never,
      translationQueue as never,
      settingsService as never,
      reviewService as never,
    );
    await worker.onModuleInit();
  });

  afterEach(async () => {
    await worker?.onModuleDestroy();
  });

  describe('onModuleInit', () => {
    it('creates a BullMQ Worker and registers event handlers', async () => {
      await worker.onModuleDestroy();
      (Worker as unknown as jest.Mock).mockClear();
      prisma.settings.findUnique.mockResolvedValue({ value: '2' });
      await worker.onModuleInit();
      expect(Worker).toHaveBeenCalledTimes(1);
      const [queueName, , opts] = (Worker as unknown as jest.Mock).mock.calls[0];
      expect(queueName).toBe('translation-jobs');
      expect(opts.concurrency).toBe(2);
    });

    it('falls back to concurrency 1 when configured value is invalid', async () => {
      await worker.onModuleDestroy();
      (Worker as unknown as jest.Mock).mockClear();
      prisma.settings.findUnique.mockResolvedValue({ value: '0' });
      await worker.onModuleInit();
      const [, , opts] = (Worker as unknown as jest.Mock).mock.calls[0];
      expect(opts.concurrency).toBe(1);
    });

    it('resets stuck processing states on startup', async () => {
      await worker.onModuleDestroy();
      prisma.page.updateMany.mockResolvedValue({ count: 3 });
      prisma.chapter.updateMany.mockResolvedValue({ count: 2 });
      prisma.book.updateMany.mockResolvedValue({ count: 1 });
      await worker.onModuleInit();
      expect(prisma.page.updateMany).toHaveBeenCalledWith({
        where: { translationStatus: 'processing' },
        data: { translationStatus: 'pending' },
      });
      expect(prisma.chapter.updateMany).toHaveBeenCalledWith({
        where: { status: 'processing' },
        data: { status: 'pending', tokensPerSecond: null },
      });
      expect(prisma.book.updateMany).toHaveBeenCalledWith({
        where: { status: 'processing' },
        data: { status: 'pending' },
      });
    });

    it('updates Worker concurrency when settings change at runtime', async () => {
      const workerInstance = (Worker as unknown as jest.Mock).mock.results[0].value as Worker;
      prisma.settings.findUnique.mockResolvedValue({ value: '3' });

      await callSyncWorkerConcurrency(worker);

      expect(workerInstance.concurrency).toBe(3);
    });
  });

  describe('handlePage (full-page job)', () => {
    it('happy path: marks page completed and updates chapter progress after single-chunk translation', async () => {
      prisma.page.findUnique.mockResolvedValueOnce({
        id: 'page_1',
        sourceText: 'Hello world',
      }).mockResolvedValueOnce({ targetText: '你好世界' });
      chunker.splitIntoChunks.mockResolvedValue([
        { index: 0, text: 'Hello world', contextTail: '' },
      ]);
      chunker.translateChunkDirect.mockResolvedValue({
        index: 0,
        originalText: 'Hello world',
        translatedText: '你好世界',
      });
      prisma.page.count
        .mockResolvedValueOnce(1)
        .mockResolvedValueOnce(1)
        .mockResolvedValueOnce(0);

      await callHandlePage(worker, makePageJob(BASE_PAGE_JOB_DATA));

      expect(prisma.page.update).toHaveBeenCalledWith(
        expect.objectContaining({ data: expect.objectContaining({ translationStatus: 'processing' }) }),
      );
      const pageWriteCalls = prisma.$executeRawUnsafe.mock.calls.filter((call) =>
        String(call[0]).includes('UPDATE "Page"'),
      );
      expect(pageWriteCalls).toHaveLength(1);
      expect(prisma.page.update).toHaveBeenCalledWith(
        expect.objectContaining({ data: expect.objectContaining({ translationStatus: 'completed' }) }),
      );
      expect(prisma.chapter.update).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { id: 'ch_1' },
          data: expect.objectContaining({ translationProgress: 100, status: 'completed' }),
        }),
      );
    });

    it('uses primary model for review when review is enabled with primary source', async () => {
      settingsService.getTranslationConfig.mockResolvedValue({
        stylePrompt: '',
        styleEnabled: false,
        glossaryEnabled: false,
        reviewEnabled: true,
        reviewModelSource: 'primary',
      });
      prisma.page.findUnique.mockResolvedValueOnce({
        id: 'page_1',
        sourceText: 'Hello world',
      }).mockResolvedValueOnce({ targetText: '你好世界' });
      chunker.splitIntoChunks.mockResolvedValue([
        { index: 0, text: 'Hello world', contextTail: '' },
      ]);
      chunker.translateChunkDirect.mockResolvedValue({
        index: 0,
        originalText: 'Hello world',
        translatedText: '你好世界',
      });
      prisma.page.count
        .mockResolvedValueOnce(1)
        .mockResolvedValueOnce(1)
        .mockResolvedValueOnce(0);

      await callHandlePage(worker, makePageJob(BASE_PAGE_JOB_DATA));

      expect(reviewService.reviewTranslation).toHaveBeenCalledWith(
        'Hello world',
        '你好世界',
        'zh',
        expect.objectContaining({
          enabled: true,
          baseUrl: 'http://primary.test/v1',
          apiKey: 'primary-key',
          model: 'primary-model',
        }),
        undefined,
        'ch_1',
        undefined,
      );
    });

    it('multi-chunk: first chunk has no newline prefix, subsequent chunks have \\n\\n prefix', async () => {
      prisma.page.findUnique.mockResolvedValue({
        id: 'page_1',
        sourceText: 'Para1\n\nPara2',
      });
      chunker.splitIntoChunks.mockResolvedValue([
        { index: 0, text: 'Para1', contextTail: '' },
        { index: 1, text: 'Para2', contextTail: 'Para1' },
      ]);
      chunker.translateChunkDirect
        .mockResolvedValueOnce({ index: 0, originalText: 'Para1', translatedText: '段落一' })
        .mockResolvedValueOnce({ index: 1, originalText: 'Para2', translatedText: '段落二' });
      prisma.page.count.mockResolvedValue(1);

      await callHandlePage(worker, makePageJob(BASE_PAGE_JOB_DATA));

      const calls = prisma.$executeRawUnsafe.mock.calls;
      expect(calls[0][1]).toBe('段落一');
      expect(calls[1][1]).toBe('\n\n段落二');
    });

    it('skips translation without throwing when page does not exist', async () => {
      prisma.page.findUnique.mockResolvedValue(null);

      await expect(
        callHandlePage(worker, makePageJob(BASE_PAGE_JOB_DATA)),
      ).resolves.toBeUndefined();

      expect(prisma.page.update).not.toHaveBeenCalled();
    });

    it('skips translation without throwing when sourceText is empty', async () => {
      prisma.page.findUnique.mockResolvedValue({ id: 'page_1', sourceText: '' });

      await expect(
        callHandlePage(worker, makePageJob(BASE_PAGE_JOB_DATA)),
      ).resolves.toBeUndefined();

      expect(prisma.page.update).not.toHaveBeenCalled();
    });

    it('skips translation without throwing when chunk list is empty', async () => {
      prisma.page.findUnique.mockResolvedValue({ id: 'page_1', sourceText: '   ' });
      chunker.splitIntoChunks.mockResolvedValue([]);

      await expect(
        callHandlePage(worker, makePageJob(BASE_PAGE_JOB_DATA)),
      ).resolves.toBeUndefined();

      expect(prisma.page.update).not.toHaveBeenCalled();
    });

    it('marks translationStatus as failed when LLM throws', async () => {
      prisma.page.findUnique.mockResolvedValue({ id: 'page_1', sourceText: 'text' });
      chunker.splitIntoChunks.mockResolvedValue([
        { index: 0, text: 'text', contextTail: '' },
      ]);
      chunker.translateChunkDirect.mockRejectedValue(new Error('LLM connection refused'));
      prisma.page.count
        .mockResolvedValueOnce(1)
        .mockResolvedValueOnce(0)
        .mockResolvedValueOnce(1);

      await expect(
        callHandlePage(worker, makePageJob(BASE_PAGE_JOB_DATA)),
      ).rejects.toThrow('LLM connection refused');

      expect(prisma.page.update).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { id: 'page_1' },
          data: expect.objectContaining({ translationStatus: 'failed' }),
        }),
      );
      expect(prisma.chapter.update).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { id: 'ch_1' },
          data: expect.objectContaining({ status: 'failed' }),
        }),
      );
    });

    it('does not update chapter progress when chapterId is absent', async () => {
      prisma.page.findUnique.mockResolvedValue({ id: 'page_1', sourceText: 'text' });
      chunker.splitIntoChunks.mockResolvedValue([{ index: 0, text: 'text', contextTail: '' }]);
      chunker.translateChunkDirect.mockResolvedValue({
        index: 0, originalText: 'text', translatedText: '文字',
      });

      await callHandlePage(worker, makePageJob({ ...BASE_PAGE_JOB_DATA, chapterId: '' }));

      expect(prisma.chapter.update).not.toHaveBeenCalled();
    });

    it('reads book glossary and passes it to all chunks when glossaryEnabled', async () => {
      settingsService.getTranslationConfig.mockResolvedValue({ stylePrompt: '', glossaryEnabled: true });
      prisma.page.findUnique.mockResolvedValue({
        id: 'page_1',
        sourceText: 'Frodo met Gandalf.',
      });

      prisma.book.findUnique.mockResolvedValue({
        id: 'book_1',
        glossary: { Frodo: '佛罗多', Gandalf: '甘道夫' },
      });
      glossaryService.toBookContextPackage.mockReturnValue({ Frodo: '佛罗多', Gandalf: '甘道夫' });
      chunker.splitIntoChunks.mockResolvedValue([
        { index: 0, text: 'Frodo met Gandalf.', contextTail: '' },
      ]);
      chunker.translateChunkDirect.mockResolvedValue({
        index: 0,
        originalText: 'Frodo met Gandalf.',
        translatedText: '佛罗多遇见甘道夫。',
      });
      prisma.page.count.mockResolvedValue(1);

      await callHandlePage(worker, makePageJob(BASE_PAGE_JOB_DATA));

      expect(glossaryService.toBookContextPackage).toHaveBeenCalled();
      expect(chunker.translateChunkDirect).toHaveBeenCalledWith(
        expect.objectContaining({ text: 'Frodo met Gandalf.' }),
        expect.objectContaining({
          glossary: { Frodo: '佛罗多', Gandalf: '甘道夫' },
        }),
      );
    });

    it('runs polish after translation when enabled and does not pass style prompt to primary translation', async () => {
      settingsService.getTranslationConfig.mockResolvedValue({
        styleEnabled: true,
        stylePrompt: '保持克制，避免口语化。',
        polishModelSource: 'primary',
        glossaryEnabled: false,
      });
      prisma.page.findUnique.mockResolvedValueOnce({
        id: 'page_1',
        sourceText: 'The room was cold and silent.',
      }).mockResolvedValueOnce({ targetText: '房间寒冷而寂静。' });
      chunker.splitIntoChunks.mockResolvedValue([
        { index: 0, text: 'The room was cold and silent.', contextTail: '' },
      ]);
      chunker.translateChunkDirect.mockResolvedValue({
        index: 0,
        originalText: 'The room was cold and silent.',
        translatedText: '房间寒冷而寂静。',
      });
      prisma.page.count.mockResolvedValue(1);

      await callHandlePage(worker, makePageJob(BASE_PAGE_JOB_DATA));

      expect(chunker.translateChunkDirect).toHaveBeenCalledWith(
        expect.objectContaining({ text: 'The room was cold and silent.' }),
        expect.not.objectContaining({ stylePrompt: '保持克制，避免口语化。' }),
      );
      expect(reviewService.polishTranslation).toHaveBeenCalledWith(
        'The room was cold and silent.',
        '房间寒冷而寂静。',
        'zh',
        expect.objectContaining({
          enabled: true,
          baseUrl: 'http://primary.test/v1',
          apiKey: 'primary-key',
          model: 'primary-model',
        }),
        undefined,
        '保持克制，避免口语化。',
        'ch_1',
        undefined,
      );
    });

    it('runs polish with an empty prompt so the polish service can apply its default directive', async () => {
      settingsService.getTranslationConfig.mockResolvedValue({
        styleEnabled: true,
        stylePrompt: '',
        polishModelSource: 'primary',
        glossaryEnabled: false,
      });
      prisma.page.findUnique.mockResolvedValueOnce({
        id: 'page_1',
        sourceText: 'The room was cold and silent.',
      }).mockResolvedValueOnce({ targetText: '房间寒冷而寂静。' });
      chunker.splitIntoChunks.mockResolvedValue([
        { index: 0, text: 'The room was cold and silent.', contextTail: '' },
      ]);
      chunker.translateChunkDirect.mockResolvedValue({
        index: 0,
        originalText: 'The room was cold and silent.',
        translatedText: '房间寒冷而寂静。',
      });
      prisma.page.count.mockResolvedValue(1);

      await callHandlePage(worker, makePageJob(BASE_PAGE_JOB_DATA));

      expect(reviewService.polishTranslation).toHaveBeenCalledWith(
        'The room was cold and silent.',
        '房间寒冷而寂静。',
        'zh',
        expect.objectContaining({ enabled: true, model: 'primary-model' }),
        undefined,
        '',
        'ch_1',
        undefined,
      );
    });

    it('publishes reviewed text before polishing state and final polished text', async () => {
      settingsService.getTranslationConfig.mockResolvedValue({
        styleEnabled: true,
        stylePrompt: '用中国相声演员的语气改写。',
        polishModelSource: 'primary',
        glossaryEnabled: false,
        reviewEnabled: true,
        reviewModelSource: 'sidekick',
      });
      settingsService.getEffectiveSidekickConfig.mockResolvedValue({
        enabled: true,
        baseUrl: 'http://sidekick.test/v1',
        apiKey: 'sidekick-key',
        model: 'sidekick-model',
      });
      prisma.page.findUnique
        .mockResolvedValueOnce({
          id: 'page_1',
          pageNumber: 1,
          sourceText: 'The tea was cold.',
        })
        .mockResolvedValueOnce({ targetText: '茶凉了。' });
      chunker.splitIntoChunks.mockResolvedValue([
        { index: 0, text: 'The tea was cold.', contextTail: '' },
      ]);
      chunker.translateChunkDirect.mockResolvedValue({
        index: 0,
        originalText: 'The tea was cold.',
        translatedText: '茶凉了。',
      });
      reviewService.reviewTranslation.mockResolvedValue('茶已经凉了。');
      reviewService.polishTranslation.mockResolvedValue('您瞧这茶，嘿，凉透了。');
      prisma.page.count.mockResolvedValue(1);

      await callHandlePage(worker, makePageJob(BASE_PAGE_JOB_DATA));

      const eventTypes = redisPubSub.publishBookEvent.mock.calls.map((call) => call[1]);
      expect(eventTypes).toEqual(expect.arrayContaining([
        'page_reviewing',
        'page_reviewed',
        'page_polishing',
        'page_done',
      ]));
      expect(eventTypes.indexOf('page_reviewing')).toBeLessThan(eventTypes.indexOf('page_reviewed'));
      expect(eventTypes.indexOf('page_reviewed')).toBeLessThan(eventTypes.indexOf('page_polishing'));
      expect(eventTypes.indexOf('page_polishing')).toBeLessThan(eventTypes.indexOf('page_done'));
      expect(redisPubSub.publishBookEvent).toHaveBeenCalledWith(
        'book_1',
        'page_reviewed',
        expect.objectContaining({ pageId: 'page_1', targetText: '茶已经凉了。' }),
      );
      expect(redisPubSub.publishBookEvent).toHaveBeenCalledWith(
        'book_1',
        'page_done',
        expect.objectContaining({ pageId: 'page_1', targetText: '您瞧这茶，嘿，凉透了。' }),
      );
      expect(prisma.page.update).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { id: 'page_1' },
          data: { targetText: '茶已经凉了。' },
        }),
      );
    });
  });

  describe('handleChunk (single-chunk job)', () => {
    const BASE_CHUNK_DATA: TranslateChunkJobData = {
      pageId: 'page_1',
      chapterId: 'ch_1',
      bookId: 'book_1',
      chunkIndex: 0,
      totalChunks: 1,
      chunkText: 'Hello',
      contextTail: '',
      sourceLang: 'en',
      targetLang: 'zh',
      chapterTitle: '第一章',
    };

    it('calls translateChunkDirect with correct arguments', async () => {
      chunker.translateChunkDirect.mockResolvedValue({
        index: 0, originalText: 'Hello', translatedText: '你好',
      });
      prisma.page.count.mockResolvedValue(1);

      await callHandleChunk(worker, BASE_CHUNK_DATA);

      expect(chunker.translateChunkDirect).toHaveBeenCalledWith(
        { index: 0, text: 'Hello', contextTail: '' },
        expect.objectContaining({ sourceLang: 'en', targetLang: 'zh', chapterTitle: '第一章' }),
      );
    });

    it('never sets translationStatus on the page (status is owned by handlePage)', async () => {
      chunker.translateChunkDirect.mockResolvedValue({
        index: 0, originalText: 'Hello', translatedText: '你好',
      });

      await callHandleChunk(worker, BASE_CHUNK_DATA);


      expect(prisma.page.update).not.toHaveBeenCalled();
    });

    it('does not call page.update for non-final chunks either', async () => {
      chunker.translateChunkDirect.mockResolvedValue({
        index: 0, originalText: 'Part1', translatedText: '第一部分',
      });

      await callHandleChunk(worker, { ...BASE_CHUNK_DATA, chunkIndex: 0, totalChunks: 3 });

      expect(prisma.page.update).not.toHaveBeenCalled();
    });

    it('updates tokensPerSecond when token count and duration are available', async () => {
      chunker.translateChunkDirect.mockResolvedValue({
        index: 0, originalText: 'Hello', translatedText: '你好',
        tokenCount: 100, durationMs: 2000,
      });
      prisma.page.count.mockResolvedValue(1);

      await callHandleChunk(worker, BASE_CHUNK_DATA);

      const withSpeed = (prisma.chapter.update as jest.Mock).mock.calls.find(
        (c: unknown[]) => (c[0] as { data: { tokensPerSecond?: unknown } }).data.tokensPerSecond !== undefined,
      );
      expect(withSpeed).toBeDefined();
    });

    it('estimates tokensPerSecond from stream output even when provider usage is missing', async () => {
      chunker.translateChunkDirect.mockResolvedValue({
        index: 0, originalText: 'Hello', translatedText: '你好',

      });
      prisma.page.count.mockResolvedValue(1);

      await callHandleChunk(worker, BASE_CHUNK_DATA);

      const progressCall = (prisma.chapter.update as jest.Mock).mock.calls.find(
        (c: unknown[]) => (c[0] as { data: { tokensPerSecond?: unknown } }).data.tokensPerSecond !== undefined,
      );
      expect(progressCall).toBeDefined();
    });
  });

  describe('updateChapterProgress (chapter progress + book status propagation)', () => {
    it('sets progress to 100 and status completed when all pages are translated', async () => {
      prisma.page.count
        .mockResolvedValueOnce(5)
        .mockResolvedValueOnce(5)
        .mockResolvedValueOnce(0);
      prisma.chapter.findMany.mockResolvedValue([{ status: 'completed' }]);

      await callUpdateChapterProgress(worker, 'ch_1', 'book_1');

      expect(prisma.chapter.update).toHaveBeenCalledWith({
        where: { id: 'ch_1' },
        data: { translationProgress: 100, status: 'completed' },
      });
    });

    it('sets mid-range progress and processing status when partially translated', async () => {
      prisma.page.count
        .mockResolvedValueOnce(4)
        .mockResolvedValueOnce(1)
        .mockResolvedValueOnce(0);
      prisma.chapter.findMany.mockResolvedValue([{ status: 'processing' }]);

      await callUpdateChapterProgress(worker, 'ch_1', 'book_1');

      expect(prisma.chapter.update).toHaveBeenCalledWith({
        where: { id: 'ch_1' },
        data: { translationProgress: 25, status: 'processing' },
      });
    });

    it('sets status to pending when no pages are translated', async () => {
      prisma.page.count
        .mockResolvedValueOnce(3)
        .mockResolvedValueOnce(0)
        .mockResolvedValueOnce(0);
      prisma.chapter.findMany.mockResolvedValue([{ status: 'pending' }]);

      await callUpdateChapterProgress(worker, 'ch_1', 'book_1');

      expect(prisma.chapter.update).toHaveBeenCalledWith({
        where: { id: 'ch_1' },
        data: { translationProgress: 0, status: 'pending' },
      });
    });

    it('sets progress to 0 when there are no pages', async () => {
      prisma.page.count.mockResolvedValue(0);
      prisma.chapter.findMany.mockResolvedValue([{ status: 'pending' }]);

      await callUpdateChapterProgress(worker, 'ch_1', 'book_1');

      expect(prisma.chapter.update).toHaveBeenCalledWith({
        where: { id: 'ch_1' },
        data: { translationProgress: 0, status: 'pending' },
      });
    });

    it('sets status to failed when all pages are terminal and at least one failed', async () => {
      prisma.page.count
        .mockResolvedValueOnce(3)
        .mockResolvedValueOnce(1)
        .mockResolvedValueOnce(2);
      prisma.chapter.findMany.mockResolvedValue([{ status: 'failed' }]);

      await callUpdateChapterProgress(worker, 'ch_1', 'book_1');

      expect(prisma.chapter.update).toHaveBeenCalledWith({
        where: { id: 'ch_1' },
        data: { translationProgress: 33, status: 'failed' },
      });
      expect(prisma.book.update).toHaveBeenCalledWith({
        where: { id: 'book_1' },
        data: { status: 'failed' },
      });
    });
  });

  describe('updateBookStatus (book status aggregated from chapters)', () => {
    it('all chapters completed → book.status = completed', async () => {
      prisma.chapter.findMany.mockResolvedValue([
        { status: 'completed' },
        { status: 'completed' },
      ]);

      await callUpdateBookStatus(worker, 'book_1');

      expect(prisma.book.update).toHaveBeenCalledWith({
        where: { id: 'book_1' },
        data: { status: 'completed' },
      });
    });

    it('any chapter processing → book.status = processing', async () => {
      prisma.chapter.findMany.mockResolvedValue([
        { status: 'processing' },
        { status: 'pending' },
      ]);

      await callUpdateBookStatus(worker, 'book_1');

      expect(prisma.book.update).toHaveBeenCalledWith({
        where: { id: 'book_1' },
        data: { status: 'processing' },
      });
    });

    it('some chapters completed others pending → book.status = processing', async () => {
      prisma.chapter.findMany.mockResolvedValue([
        { status: 'completed' },
        { status: 'pending' },
      ]);

      await callUpdateBookStatus(worker, 'book_1');

      expect(prisma.book.update).toHaveBeenCalledWith({
        where: { id: 'book_1' },
        data: { status: 'processing' },
      });
    });

    it('any chapter failed → book.status = failed', async () => {
      prisma.chapter.findMany.mockResolvedValue([
        { status: 'completed' },
        { status: 'failed' },
      ]);

      await callUpdateBookStatus(worker, 'book_1');

      expect(prisma.book.update).toHaveBeenCalledWith({
        where: { id: 'book_1' },
        data: { status: 'failed' },
      });
    });

    it('all chapters pending → book.status = pending', async () => {
      prisma.chapter.findMany.mockResolvedValue([{ status: 'pending' }]);

      await callUpdateBookStatus(worker, 'book_1');

      expect(prisma.book.update).toHaveBeenCalledWith({
        where: { id: 'book_1' },
        data: { status: 'pending' },
      });
    });

    it('does not update book when there are no chapters', async () => {
      prisma.chapter.findMany.mockResolvedValue([]);

      await callUpdateBookStatus(worker, 'book_1');

      expect(prisma.book.update).not.toHaveBeenCalled();
    });
  });
});
