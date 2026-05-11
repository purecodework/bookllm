import { Injectable, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { Worker, Job } from 'bullmq';
import IORedis from 'ioredis';
import { ensureImageMarkersInTarget } from '../common/image-markers';
import { computeChapterProgress } from '../common/chapter-progress';
import { logError, logInfo, logWarn } from '../common/logging/app-logger';
import { estimateTokens } from '../common/token-estimate';
import { persistBookUsageDelta, type UsageStage } from '../common/token-usage';
import { PrismaService } from '../prisma/prisma.service';
import { SettingsService, type LlmConfig, type SidekickConfig } from '../settings/settings.service';
import { GlossaryService } from '../translation/glossary.service';
import { TranslationChunkerService } from '../translation/translation-chunker.service';
import {
  buildPolishPrompt,
  buildReviewPrompt,
  buildSystemPrompt,
  buildUserPrompt,
} from '../translation/translation-prompt.builder';
import { RedisPubSubService } from '../redis/redis-pubsub.service';
import { ReviewService } from '../review/review.service';
import { TranslateChunkJobData, TranslatePageJobData, TranslationQueueService } from './translation.queue';

@Injectable()
export class TranslationWorker implements OnModuleInit, OnModuleDestroy {
  private worker!: Worker;
  private readonly minConcurrency = 1;
  private readonly maxConcurrency = 32;
  private concurrencySyncTimer?: NodeJS.Timeout;
  private currentConcurrency = this.minConcurrency;

  constructor(
    private readonly prisma: PrismaService,
    private readonly chunker: TranslationChunkerService,
    private readonly glossaryService: GlossaryService,
    private readonly redisPubSub: RedisPubSubService,
    private readonly translationQueue: TranslationQueueService,
    private readonly settingsService: SettingsService,
    private readonly reviewService: ReviewService,
  ) {}

  async onModuleInit() {


    await this.recoverStuckProcessingStates();

    const connection = new IORedis({
      host: process.env.REDIS_HOST ?? '127.0.0.1',
      port: Number(process.env.REDIS_PORT ?? 6379),
      maxRetriesPerRequest: null,
    });
    const concurrency = await this.loadConcurrency();
    this.currentConcurrency = concurrency;

    this.worker = new Worker(
      'translation-jobs',
      async (job: Job) => {
        if (job.name === 'translate-page') {
          await this.handlePage(job as Job<TranslatePageJobData>);
        } else {
          logWarn('queue_job_ignored', {
            event: 'queue_job_ignored',
            jobId: job.id,
            jobName: job.name,
          });
        }
      },
      { connection, concurrency },
    );

    this.worker.on('completed', (job) => {
      logInfo('queue_job_completed', {
        event: 'queue_job_completed',
        jobId: job.id,
        jobName: job.name,
      });
    });
    this.worker.on('failed', (job, err) => {
      logError('queue_job_failed', {
        event: 'queue_job_failed',
        jobId: job?.id,
        jobName: job?.name,
        error: err,
      });
    });
    this.concurrencySyncTimer = setInterval(() => {
      void this.syncWorkerConcurrency();
    }, 2000);
    this.concurrencySyncTimer.unref?.();
  }


  private async recoverStuckProcessingStates(): Promise<void> {
    try {
      const [pages, chapters, books] = await Promise.all([
        this.prisma.page.updateMany({
          where: { translationStatus: 'processing' },
          data: { translationStatus: 'pending' },
        }),
        this.prisma.chapter.updateMany({
          where: { status: 'processing' },
          data: { status: 'pending', tokensPerSecond: null },
        }),
        this.prisma.book.updateMany({
          where: { status: 'processing' },
          data: { status: 'pending' },
        }),
      ]);
      if (pages.count > 0 || chapters.count > 0 || books.count > 0) {
        logInfo('startup_stuck_state_recovery', {
          event: 'startup_stuck_state_recovery',
          pages: pages.count,
          chapters: chapters.count,
          books: books.count,
        });
      }
    } catch (err) {
      logWarn('startup_stuck_state_recovery_failed', {
        event: 'startup_stuck_state_recovery_failed',
        errorMessage: err instanceof Error ? err.message : String(err),
      });
    }
  }

  async onModuleDestroy() {
    if (this.concurrencySyncTimer) {
      clearInterval(this.concurrencySyncTimer);
      this.concurrencySyncTimer = undefined;
    }
    await this.worker?.close();
  }

  private async loadConcurrency(): Promise<number> {
    try {
      const row = await this.prisma.settings.findUnique({
        where: { key: 'translation.concurrency' },
        select: { value: true },
      });
      const parsed = Number(row?.value ?? this.minConcurrency);
      if (!Number.isFinite(parsed)) return this.minConcurrency;
      return Math.min(this.maxConcurrency, Math.max(this.minConcurrency, Math.floor(parsed)));
    } catch {
      return this.minConcurrency;
    }
  }

  private async syncWorkerConcurrency(): Promise<void> {
    if (!this.worker) return;
    const nextConcurrency = await this.loadConcurrency();
    if (nextConcurrency === this.currentConcurrency) return;
    this.worker.concurrency = nextConcurrency;
    this.currentConcurrency = nextConcurrency;
    logInfo('translation_worker_concurrency_updated', {
      event: 'translation_worker_concurrency_updated',
      concurrency: nextConcurrency,
    });
  }

  private async handlePage(job: Job<TranslatePageJobData>): Promise<void> {
    const { pageId, chapterId, bookId, sourceLang, targetLang, chapterTitle } = job.data;

    const page = await this.prisma.page.findUnique({ where: { id: pageId } });
    if (!page?.sourceText) {
      logWarn('page_skipped_no_source', { event: 'page_skipped', bookId, chapterId, pageId, reason: 'missing_source_text' });
      return;
    }
    if (page.translationStatus === 'completed') {
      logInfo('page_skipped_completed', { event: 'page_skipped', bookId, chapterId, pageId, reason: 'already_completed' });
      return;
    }
    const sourceText = page.sourceText;

    const [translationConfig, sidekick, primaryLlm] = await Promise.all([
      this.settingsService.getTranslationConfig(),
      this.settingsService.getEffectiveSidekickConfig(),
      this.settingsService.getEffectiveLlmConfig(),
    ]);

    const polishPrompt = translationConfig.styleEnabled
      ? (translationConfig.stylePrompt || '')
      : '';

    let glossary: unknown = undefined;
    if (translationConfig.glossaryEnabled) {
      const bookWithGlossary = await this.prisma.book.findUnique({
        where: { id: bookId },
        select: { glossary: true },
      });
      glossary = this.glossaryService.toBookContextPackage(bookWithGlossary?.glossary);
    }

    const chunks = await this.chunker.splitIntoChunks(sourceText, {
      sourceLang,
      targetLang,
      chapterTitle,
    });
    if (chunks.length === 0) {
      logWarn('page_skipped_empty_chunks', { event: 'page_skipped', bookId, chapterId, pageId, reason: 'empty_chunks' });
      return;
    }


    if (job.data.previousPageTail && chunks[0].contextTail === '') {
      chunks[0] = { ...chunks[0], contextTail: job.data.previousPageTail };
    }

    logInfo('page_translation_started', {
      event: 'page_started',
      bookId,
      chapterId,
      pageId,
      totalChunks: chunks.length,
      sourceLength: sourceText.length,
    });

    await this.prisma.page.update({
      where: { id: pageId },
      data: { targetText: null, translationStatus: 'processing' },
    });
    await this.redisPubSub.publishBookEvent(bookId, 'page_token', {
      bookId,
      chapterId,
      pageId,
      content: '',
    });

    try {
      for (const chunk of chunks) {
        await this.handleChunkStep({
          pageId,
          chapterId,
          bookId,
          chunkIndex: chunk.index,
          totalChunks: chunks.length,
          chunkText: chunk.text,
          contextTail: chunk.contextTail,
          glossary,
          chapterTitle,
          pageNumber: page.pageNumber,
          sourceLang,
          targetLang,
        });
      }

      const donePage = await this.prisma.page.findUnique({ where: { id: pageId } });
      let mergedTarget = ensureImageMarkersInTarget(sourceText, donePage?.targetText ?? '');

      const reviewConfig = this.resolveReviewConfig(
        translationConfig.reviewEnabled,
        translationConfig.reviewModelSource,
        primaryLlm,
        sidekick,
      );
      const polishConfig = this.resolveStageModelConfig(
        translationConfig.styleEnabled,
        translationConfig.polishModelSource ?? 'primary',
        primaryLlm,
        sidekick,
      );
      if (reviewConfig.enabled) {
        await this.redisPubSub.publishBookEvent(bookId, 'pipeline_phase', {
          bookId,
          phase: 'review',
          pageId,
          label: 'Editing',
        });
        await this.publishUsageDelta(bookId, 'review', {
          pageId,
          inputTokens: this.estimateReviewInputTokens(
            sourceText,
            mergedTarget,
            targetLang,
            glossary,
            chapterId,
            page.pageNumber,
          ),
        });
        await this.redisPubSub.publishBookEvent(bookId, 'page_reviewing', {
          bookId,
          chapterId,
          pageId,
        });
        mergedTarget = await this.reviewService.reviewTranslation(
          sourceText,
          mergedTarget,
          targetLang,
          reviewConfig,
          glossary,
          chapterId,
          page.pageNumber,
        );
        mergedTarget = ensureImageMarkersInTarget(sourceText, mergedTarget);
        await this.prisma.page.update({
          where: { id: pageId },
          data: { targetText: mergedTarget },
        });
        await this.redisPubSub.publishBookEvent(bookId, 'page_reviewed', {
          bookId,
          chapterId,
          pageId,
          targetText: mergedTarget,
        });
        await this.publishUsageDelta(bookId, 'review', {
          pageId,
          outputTokens: estimateTokens(mergedTarget),
        });
      }

      if (polishConfig.enabled) {
        await this.redisPubSub.publishBookEvent(bookId, 'pipeline_phase', {
          bookId,
          phase: 'polish',
          pageId,
          label: 'Polishing',
        });
        await this.publishUsageDelta(bookId, 'polish', {
          pageId,
          inputTokens: this.estimatePolishInputTokens(
            sourceText,
            mergedTarget,
            targetLang,
            glossary,
            polishPrompt,
            chapterId,
            page.pageNumber,
          ),
        });
        await this.redisPubSub.publishBookEvent(bookId, 'page_polishing', {
          bookId,
          chapterId,
          pageId,
        });
        mergedTarget = await this.reviewService.polishTranslation(
          sourceText,
          mergedTarget,
          targetLang,
          polishConfig,
          glossary,
          polishPrompt,
          chapterId,
          page.pageNumber,
        );
        await this.publishUsageDelta(bookId, 'polish', {
          pageId,
          outputTokens: estimateTokens(mergedTarget),
        });
      }
      mergedTarget = ensureImageMarkersInTarget(sourceText, mergedTarget);


      await this.prisma.page.update({
        where: { id: pageId },
        data: { targetText: mergedTarget, translationStatus: 'completed', retryCount: job.attemptsMade },
      });
      if (chapterId) {
        await this.updateChapterProgress(chapterId, bookId, undefined);
      }
      await this.redisPubSub.publishBookEvent(bookId, 'page_done', {
        bookId,
        chapterId,
        pageId,
        targetText: mergedTarget,
      });
      await this.redisPubSub.publishBookEvent(bookId, 'pipeline_phase', {
        bookId,
        phase: 'completed',
        pageId,
        label: 'Completed',
      });
      logInfo('page_done', {
        event: 'page_done',
        bookId,
        chapterId,
        pageId,
        targetLength: mergedTarget.length,
      });
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : String(err);
      await this.prisma.page.update({
        where: { id: pageId },
        data: { translationStatus: 'failed', errorMessage },
      });
      await this.redisPubSub.publishBookEvent(bookId, 'page_failed', {
        bookId,
        chapterId,
        pageId,
        errorMessage,
      });
      if (chapterId) {
        await this.updateChapterProgress(chapterId, bookId, undefined);
      }
      logError('page_failed', {
        event: 'page_failed',
        bookId,
        chapterId,
        pageId,
        errorMessage,
      });
      throw err;
    }
  }

  private resolveReviewConfig(
    reviewEnabled: boolean,
    reviewModelSource: 'primary' | 'sidekick',
    primary: LlmConfig,
    sidekick: SidekickConfig,
  ): SidekickConfig {
    return this.resolveStageModelConfig(reviewEnabled, reviewModelSource, primary, sidekick);
  }

  private resolveStageModelConfig(
    enabled: boolean,
    modelSource: 'primary' | 'sidekick',
    primary: LlmConfig,
    sidekick: SidekickConfig,
  ): SidekickConfig {
    if (!enabled) return { enabled: false, baseUrl: '', apiKey: '', model: '', proofreadEnabled: false, polishEnabled: false, glossaryEnabled: false };
    if (modelSource === 'sidekick' && sidekick.enabled && sidekick.baseUrl && sidekick.model) {
      return { ...sidekick, enabled: true, proofreadEnabled: true, polishEnabled: false };
    }
    return {
      enabled: true,
      baseUrl: primary.baseUrl,
      apiKey: primary.apiKey,
      model: primary.model,
      proofreadEnabled: true,
      polishEnabled: false,
      glossaryEnabled: false,
    };
  }

  private async handleChunkStep(data: TranslateChunkJobData): Promise<void> {
    const {
      pageId, chapterId, chunkIndex, totalChunks,
      chunkText, contextTail, chapterTitle, pageNumber, sourceLang, targetLang, glossary, stylePrompt,
    } = data;

    logInfo('chunk_translation_started', {
      event: 'chunk_started',
      bookId: data.bookId,
      chapterId,
      pageId,
      chunkIndex,
      totalChunks,
      chunkLength: chunkText.length,
    });


    let fullText = '';
    let streamEventCount = 0;
    const startedAt = Date.now();
    let lastSpeedPublishAt = 0;
    await this.publishUsageDelta(data.bookId, 'translation', {
      pageId,
      inputTokens: this.estimateTranslationInputTokens(data),
    });
    for await (const token of this.chunker.translateChunkStream(
      { index: chunkIndex, text: chunkText, contextTail },
      { sourceLang, targetLang, sourceText: '', chapterId, chapterTitle, pageNumber, glossary, stylePrompt },
    )) {
      fullText += token;
      streamEventCount++;
      await this.redisPubSub.publishBookEvent(data.bookId, 'page_token', {
        bookId: data.bookId,
        chapterId,
        pageId,
        content: token,
      });
      const now = Date.now();
      if (chapterId && now - lastSpeedPublishAt >= 1000) {
        lastSpeedPublishAt = now;
        const elapsedSec = Math.max((now - startedAt) / 1000, 0.001);
        const tokensPerSecond = Math.round((streamEventCount / elapsedSec) * 10) / 10;
        await this.publishChapterRuntimeState(chapterId, data.bookId, tokensPerSecond);
      }
    }
    await this.publishUsageDelta(data.bookId, 'translation', {
      pageId,
      outputTokens: estimateTokens(fullText),
    });

    if (!fullText) {
      logWarn('chunk_empty_output', {
        event: 'chunk_empty_output',
        bookId: data.bookId,
        chapterId,
        pageId,
        chunkIndex,
      });
    }


    await this.prisma.$executeRawUnsafe(
      `UPDATE "Page"
       SET "targetText" = COALESCE("targetText", '') || $1,
           "updatedAt"  = NOW()
       WHERE id = $2`,
      chunkIndex === 0 ? fullText : `\n\n${fullText}`,
      pageId,
    );

    if (chunkIndex === totalChunks - 1) {
      logInfo('chunk_last_appended', {
        event: 'chunk_last_appended',
        bookId: data.bookId,
        chapterId,
        pageId,
      });
    }
  }

  private async publishUsageDelta(
    bookId: string,
    stage: UsageStage,
    delta: { pageId?: string; sectionId?: string; inputTokens?: number; outputTokens?: number },
  ): Promise<void> {
    if (!delta.inputTokens && !delta.outputTokens) return;
    await persistBookUsageDelta(this.prisma, bookId, stage, delta);
    await this.redisPubSub.publishBookEvent(bookId, 'usage_delta', {
      bookId,
      stage,
      ...delta,
    });
  }

  private estimateTranslationInputTokens(data: TranslateChunkJobData): number {
    const systemPrompt = buildSystemPrompt(
      data.sourceLang,
      data.targetLang,
      data.stylePrompt,
      data.glossary,
      data.chunkText,
      data.chapterId,
      data.pageNumber,
    );
    const userPrompt = buildUserPrompt(
      { text: data.chunkText, contextTail: data.contextTail ?? '' },
      data.chapterTitle,
    );
    return estimateTokens(`${systemPrompt}\n\n${userPrompt}`);
  }

  private estimateReviewInputTokens(
    sourceText: string,
    draftText: string,
    targetLang: string,
    glossary: unknown,
    chapterId: string,
    pageNumber?: number,
  ): number {
    const { systemPrompt, userPrompt } = buildReviewPrompt(
      sourceText,
      draftText,
      targetLang,
      glossary,
      chapterId,
      pageNumber,
    );
    return estimateTokens(`${systemPrompt}\n\n${userPrompt}`);
  }

  private estimatePolishInputTokens(
    sourceText: string,
    draftText: string,
    targetLang: string,
    glossary: unknown,
    polishPrompt: string,
    chapterId: string,
    pageNumber?: number,
  ): number {
    const { systemPrompt, userPrompt } = buildPolishPrompt(
      sourceText,
      draftText,
      targetLang,
      glossary,
      polishPrompt,
      chapterId,
      pageNumber,
    );
    return estimateTokens(`${systemPrompt}\n\n${userPrompt}`);
  }

  private async publishChapterRuntimeState(
    chapterId: string,
    bookId: string,
    tokensPerSecond: number,
  ): Promise<void> {
    const chapter = await this.prisma.chapter.update({
      where: { id: chapterId },
      data: { tokensPerSecond },
      select: {
        id: true,
        status: true,
        translationProgress: true,
        tokensPerSecond: true,
        translationStartedAt: true,
      },
    });
    await this.redisPubSub.publishBookEvent(bookId, 'chapter_state', {
      bookId,
      chapterId: chapter.id,
      status: chapter.status,
      translationProgress: chapter.translationProgress,
      tokensPerSecond: chapter.tokensPerSecond,
      translationStartedAt: chapter.translationStartedAt?.toISOString() ?? null,
    });
  }

  private async updateChapterProgress(
    chapterId: string,
    bookId: string,
    tokPerSec?: number,
  ): Promise<void> {
    const [total, translated, failed] = await Promise.all([
      this.prisma.page.count({ where: { chapterId } }),
      this.prisma.page.count({ where: { chapterId, translationStatus: 'completed' } }),
      this.prisma.page.count({ where: { chapterId, translationStatus: 'failed' } }),
    ]);

    const { progress, status: chapterStatus } = computeChapterProgress(translated, total, failed);

    const chapter = await this.prisma.chapter.update({
      where: { id: chapterId },
      data: {
        translationProgress: progress,
        status: chapterStatus,
        ...(tokPerSec !== undefined && { tokensPerSecond: tokPerSec }),
      },
    });
    await this.redisPubSub.publishBookEvent(bookId, 'chapter_state', {
      bookId,
      chapterId: chapter.id,
      status: chapter.status,
      translationProgress: chapter.translationProgress,
      tokensPerSecond: chapter.tokensPerSecond,
      translationStartedAt: chapter.translationStartedAt?.toISOString() ?? null,
    });
    logInfo('chapter_state', {
      event: 'chapter_state',
      bookId,
      chapterId: chapter.id,
      status: chapter.status,
      translationProgress: chapter.translationProgress,
      tokensPerSecond: chapter.tokensPerSecond,
    });


    if (chapterStatus === 'completed') {
      await this.updateBookStatus(bookId);
    } else if (chapterStatus === 'failed') {
      await this.updateBookStatus(bookId);
    } else if (chapterStatus === 'processing') {

      await this.prisma.book.update({
        where: { id: bookId },
        data: { status: 'processing' },
      });
      await this.publishBookState(bookId, 'processing');
    }
  }

  private async updateBookStatus(bookId: string): Promise<void> {
    const chapters = await this.prisma.chapter.findMany({
      where: { bookId },
      select: { status: true },
    });
    if (chapters.length === 0) return;


    const bookStatus =
      chapters.every((c) => c.status === 'completed') ? 'completed'
      : chapters.some((c) => c.status === 'processing') ? 'processing'
      : chapters.some((c) => c.status === 'failed') ? 'failed'
      : chapters.some((c) => c.status === 'completed') ? 'processing'
      : 'pending';

    await this.prisma.book.update({
      where: { id: bookId },
      data: { status: bookStatus },
    });
    await this.publishBookState(bookId, bookStatus);
  }

  private async publishBookState(bookId: string, status: string): Promise<void> {
    const firstChapter = await this.prisma.chapter.findFirst({
      where: { bookId },
      orderBy: { chapterNumber: 'asc' },
      select: { translationProgress: true },
    });
    await this.redisPubSub.publishBookEvent(bookId, 'book_state', {
      bookId,
      status,
      translationProgress: firstChapter?.translationProgress ?? 0,
    });
    logInfo('book_state', {
      event: 'book_state',
      bookId,
      status,
      translationProgress: firstChapter?.translationProgress ?? 0,
    });
  }
}
