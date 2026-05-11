import {
  BadRequestException,
  HttpException,
  HttpStatus,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { computeBookProgress } from '../common/book-progress';
import { logInfo, logWarn } from '../common/logging/app-logger';
import { estimateTokens } from '../common/token-estimate';
import { persistBookUsageDelta, type UsageStage } from '../common/token-usage';
import { PrismaService } from '../prisma/prisma.service';
import { SettingsService } from '../settings/settings.service';
import { RedisPubSubService } from '../redis/redis-pubsub.service';
import { ReviewService } from '../review/review.service';
import { GlossaryService } from '../translation/glossary.service';
import {
  buildGlossaryReductionPrompt,
  countBookContextEntries,
  buildBookContextPrompt,
  mergeBookContextPackages,
  normalizeBookContextPackage,
} from '../translation/translation-prompt.builder';
import {
  buildBookContextSegmentsFromPages,
  type BookContextPageInput,
} from '../translation/book-context-segments';
import { TranslationQueueService } from './translation.queue';


const PREV_PAGE_TAIL_CHARS = 350;
const BOOK_GLOSSARY_CHAPTER_ID = '__book__';
const MIN_GLOSSARY_PACKAGES_FOR_LLM_REDUCTION = 4;
const BOOK_CONTEXT_CACHE_VERSION = 'book-context-v1';
const BOOK_CONTEXT_SECTION_STRATEGY_VERSION = 'section-map-reduce-v1';
const DEFAULT_BOOK_CONTEXT_CACHE_TTL_SECONDS = 60 * 60 * 24 * 7;

type ContextPackage = ReturnType<typeof normalizeBookContextPackage>;

interface GlossaryProgressState {
  bookId: string;
  completedSections: number;
  totalSections: number;
  currentSectionId?: string;
  elapsedMs: number;
  estimatedRemainingMs?: number;
}

interface TranslatablePage {
  id: string;
  chapterId: string | null;
  pageNumber: number;
  sourceText: string | null;
  chapter: { id: string; title: string | null; chapterNumber: number } | null;
}

async function runBounded<T>(
  items: T[],
  concurrency: number,
  worker: (item: T, index: number) => Promise<void>,
): Promise<void> {
  let nextIndex = 0;
  const parsed = Number.isFinite(concurrency) ? Math.floor(concurrency) : 1;
  const workerCount = Math.min(items.length, Math.max(1, parsed));
  await Promise.all(
    Array.from({ length: workerCount }, async () => {
      while (nextIndex < items.length) {
        const index = nextIndex;
        nextIndex += 1;
        await worker(items[index], index);
      }
    }),
  );
}

@Injectable()
export class TranslationControlService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly translationQueue: TranslationQueueService,
    private readonly redisPubSub: RedisPubSubService,
    private readonly settingsService: SettingsService,
    private readonly reviewService: ReviewService,
    private readonly glossaryService: GlossaryService,
  ) {}

  private getQueueLimitConfig() {
    return {
      maxProcessingBooks: Number(process.env.TRANSLATION_MAX_PROCESSING_BOOKS ?? 1),
    };
  }

  private isChapterTranslateEndpointEnabled(): boolean {
    const flag = (process.env.TRANSLATION_ENABLE_CHAPTER_ENDPOINT ?? '').trim().toLowerCase();
    return flag === '1' || flag === 'true';
  }

  private glossaryDoneKey(id: string, targetLang: string): string {
    return `translation.glossary.done.${id}.${targetLang}`;
  }

  private glossaryProgressKey(bookId: string, targetLang: string): string {
    return `translation.glossary.progress.${bookId}.${targetLang}`;
  }

  private bookContextCacheTtlSeconds(): number {
    const raw = Number(process.env.BOOK_CONTEXT_CACHE_TTL_SECONDS);
    if (!Number.isFinite(raw)) return DEFAULT_BOOK_CONTEXT_CACHE_TTL_SECONDS;
    return Math.max(0, Math.floor(raw));
  }

  private async buildBookContextCacheKey(
    bookId: string,
    targetLang: string,
    modelSource: 'primary' | 'sidekick',
    contextWindowTokens: number,
    inputTokenBudget: number,
  ): Promise<string | null> {
    const asset = await this.prisma.bookOriginalAsset.findUnique({
      where: { bookId },
      select: { sha256: true },
    });
    const sha256 = asset?.sha256?.trim();
    if (!sha256) return null;
    return [
      'cache',
      BOOK_CONTEXT_CACHE_VERSION,
      BOOK_CONTEXT_SECTION_STRATEGY_VERSION,
      sha256,
      targetLang,
      modelSource,
      contextWindowTokens,
      inputTokenBudget,
    ].join(':');
  }

  private async readBookContextCache(cacheKey: string): Promise<ContextPackage | null> {
    const cached = await this.redisPubSub.getValue(cacheKey);
    if (!cached) return null;
    try {
      const parsed = JSON.parse(cached) as unknown;
      const pkg = normalizeBookContextPackage(parsed);
      return this.hasContextContent(pkg) ? pkg : null;
    } catch {
      return null;
    }
  }

  private async writeBookContextCache(cacheKey: string, pkg: ContextPackage): Promise<void> {
    if (!this.hasContextContent(pkg)) return;
    await this.redisPubSub.setValue(
      cacheKey,
      JSON.stringify(pkg),
      this.bookContextCacheTtlSeconds(),
    );
  }

  private async isGlossaryDone(id: string, targetLang: string): Promise<boolean> {
    const row = await this.prisma.settings.findUnique({
      where: { key: this.glossaryDoneKey(id, targetLang) },
      select: { value: true },
    });
    return row?.value === 'true';
  }

  private async markGlossaryDone(id: string, targetLang: string): Promise<void> {
    await this.prisma.settings.upsert({
      where: { key: this.glossaryDoneKey(id, targetLang) },
      update: { value: 'true' },
      create: { key: this.glossaryDoneKey(id, targetLang), value: 'true' },
    });
  }

  private async saveGlossaryProgress(bookId: string, targetLang: string, state: GlossaryProgressState): Promise<void> {
    await this.prisma.settings.upsert({
      where: { key: this.glossaryProgressKey(bookId, targetLang) },
      update: { value: JSON.stringify(state) },
      create: { key: this.glossaryProgressKey(bookId, targetLang), value: JSON.stringify(state) },
    });
  }

  private async loadGlossaryProgress(bookId: string, targetLang: string): Promise<GlossaryProgressState | null> {
    const row = await this.prisma.settings.findUnique({
      where: { key: this.glossaryProgressKey(bookId, targetLang) },
      select: { value: true },
    });
    if (!row?.value) return null;
    try {
      return JSON.parse(row.value) as GlossaryProgressState;
    } catch {
      return null;
    }
  }

  private async publishGlossaryProgress(bookId: string, targetLang: string, state: GlossaryProgressState): Promise<void> {
    await this.saveGlossaryProgress(bookId, targetLang, state);
    await this.redisPubSub.publishBookEvent(bookId, 'glossary_progress', state);
  }

  private async replayGlossaryProgress(bookId: string, targetLang: string): Promise<void> {
    const state = await this.loadGlossaryProgress(bookId, targetLang);
    if (!state || state.completedSections >= state.totalSections) return;
    await this.redisPubSub.publishBookEvent(bookId, 'glossary_extracting', {
      bookId,
      chapterId: BOOK_GLOSSARY_CHAPTER_ID,
      extracting: true,
    });
    await this.redisPubSub.publishBookEvent(bookId, 'glossary_progress', state);
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


  private async shouldUseSidekickGlossary(
    glossaryModelSource: string,
  ): Promise<boolean> {
    if (glossaryModelSource !== 'sidekick') return false;
    const sidekick = await this.settingsService.getEffectiveSidekickConfig();
    return sidekick.enabled && !!sidekick.baseUrl && !!sidekick.model;
  }

  private async assertCanStartTranslation(targetBookId: string): Promise<void> {
    const { maxProcessingBooks } = this.getQueueLimitConfig();
    const processingBooksCount = await this.prisma.book.count({ where: { status: 'processing' } });

    if (processingBooksCount >= maxProcessingBooks) {
      const target = await this.prisma.book.findUnique({
        where: { id: targetBookId },
        select: { status: true },
      });
      if (target?.status !== 'processing') {
        throw new HttpException(
          {
            message: `${processingBooksCount} books are already translating. Please try again later.`,
            businessCode: 'TRANSLATION_CAPACITY_EXCEEDED',
          },
          HttpStatus.TOO_MANY_REQUESTS,
        );
      }
    }
  }

  private async publishBookState(bookId: string): Promise<void> {
    const book = await this.prisma.book.findUnique({
      where: { id: bookId },
      select: {
        id: true,
        status: true,
        pages: {
          select: { translationStatus: true },
        },
      },
    });
    if (!book) return;
    await this.redisPubSub.publishBookEvent(bookId, 'book_state', {
      bookId,
      status: book.status,
      translationProgress: computeBookProgress(book.pages ?? []),
    });
  }

  private async publishQueueState(bookId: string, isPaused: boolean): Promise<void> {
    await this.redisPubSub.publishBookEvent(bookId, 'queue_state', {
      bookId,
      isPaused,
    });
  }

  async startTranslation(
    chapterId: string,
    options?: { skipCapacityCheck?: boolean; internal?: boolean },
  ): Promise<{ enqueuedPages: number }> {
    if (!options?.internal && !this.isChapterTranslateEndpointEnabled()) {
      throw new BadRequestException({
        message: 'Chapter-level translation is disabled by default. Use the book-level endpoint.',
        businessCode: 'CHAPTER_ENDPOINT_DISABLED',
      });
    }

    const chapter = await this.prisma.chapter.findUnique({
      where: { id: chapterId },
      include: { pages: { orderBy: { pageNumber: 'asc' } } },
    });
    if (!chapter) throw new NotFoundException(`Chapter ${chapterId} not found`);

    if (!options?.skipCapacityCheck) {
      await this.assertCanStartTranslation(chapter.bookId);
    }

    const book = await this.prisma.book.findUnique({ where: { id: chapter.bookId } });
    if (!book) throw new NotFoundException(`Book ${chapter.bookId} not found`);

    const pages = await this.prisma.page.findMany({
      where: {
        chapterId,
        ocrStatus: 'completed',
        translationStatus: { not: 'completed' },
      },
      orderBy: { pageNumber: 'asc' },
    });

    if (pages.length === 0) {
      throw new BadRequestException({
        message: 'This chapter has no OCR-completed pages to translate.',
        businessCode: 'CHAPTER_NO_TRANSLATABLE_PAGES',
      });
    }

    const updatedChapter = await this.prisma.chapter.update({
      where: { id: chapterId },
      data: {
        status: 'processing',
        translationProgress: 0,
        translationStartedAt: new Date(),
        tokensPerSecond: null,
      },
    });
    await this.redisPubSub.publishBookEvent(book.id, 'chapter_state', {
      bookId: book.id,
      chapterId: updatedChapter.id,
      status: updatedChapter.status,
      translationProgress: updatedChapter.translationProgress,
      tokensPerSecond: updatedChapter.tokensPerSecond,
      translationStartedAt: updatedChapter.translationStartedAt?.toISOString() ?? null,
    });
    logInfo('chapter_state', {
      event: 'chapter_state',
      bookId: book.id,
      chapterId: updatedChapter.id,
      status: updatedChapter.status,
      translationProgress: updatedChapter.translationProgress,
      translationStartedAt: updatedChapter.translationStartedAt?.toISOString() ?? null,
    });
    await this.publishBookState(book.id);

    const translationConfig = await this.settingsService.getTranslationConfig();

    if (translationConfig.glossaryEnabled) {
      const bookGlossaryDone = await this.isGlossaryDone(book.id, book.targetLang);
      if (bookGlossaryDone) {
        logInfo('chapter_glossary_skipped_book_level', {
          event: 'chapter_glossary_skipped_book_level',
          bookId: book.id,
          chapterId,
        });
      } else {
        const chapterGlossaryDone = await this.isGlossaryDone(chapterId, book.targetLang);
        if (chapterGlossaryDone) {
          logInfo('chapter_glossary_skipped_done', {
            event: 'chapter_glossary_skipped_done',
            bookId: book.id,
            chapterId,
          });
        } else {
          const useSidekick = await this.shouldUseSidekickGlossary(translationConfig.glossaryModelSource);
          await this.redisPubSub.publishBookEvent(book.id, 'glossary_extracting', {
            bookId: book.id, chapterId, extracting: true,
          });
          const glossaryPages: BookContextPageInput[] = pages.map((page) => ({
            sourceText: page.sourceText,
            pageNumber: page.pageNumber,
            chapter: {
              id: chapter.id,
              title: chapter.title,
              chapterNumber: chapter.chapterNumber,
            },
          }));
          const completed = useSidekick
            ? await this.runSidekickGlossaryBlocking(
                glossaryPages,
                book,
                chapterId,
                translationConfig.contextWindowTokens,
                translationConfig.inputTokenBudget,
                translationConfig.concurrency,
              )
            : await this.runPrimaryGlossaryBlocking(
                glossaryPages,
                book,
                chapterId,
                translationConfig.contextWindowTokens,
                translationConfig.inputTokenBudget,
                translationConfig.concurrency,
              );
          await this.redisPubSub.publishBookEvent(book.id, 'glossary_extracting', {
            bookId: book.id, chapterId, extracting: false,
          });
          if (completed) await this.markGlossaryDone(chapterId, book.targetLang);
        }
      }
    }

    await Promise.all(
      pages.map((page, idx) =>
        this.translationQueue.enqueuePage({
          pageId: page.id,
          chapterId,
          bookId: book.id,
          sourceLang: book.sourceLang,
          targetLang: book.targetLang,
          chapterTitle: chapter.title ?? undefined,
          pageNumber: page.pageNumber,
          previousPageTail:
            idx > 0
              ? (pages[idx - 1].sourceText?.trimEnd().slice(-PREV_PAGE_TAIL_CHARS) ?? undefined)
              : undefined,
        }),
      ),
    );

    return { enqueuedPages: pages.length };
  }

  private async runSidekickGlossaryBlocking(
    pages: BookContextPageInput[],
    book: { id: string; targetLang: string },
    chapterId: string,
    contextWindowTokens: number,
    inputTokenBudget: number,
    concurrency: number,
  ): Promise<boolean> {
    try {
      const sidekick = await this.settingsService.getEffectiveSidekickConfig();
      if (!sidekick.enabled || !sidekick.baseUrl || !sidekick.model) return true;

      const segments = buildBookContextSegmentsFromPages(pages, contextWindowTokens, inputTokenBudget);
      if (segments.length === 0) return true;

      const existingBook = await this.prisma.book.findUnique({
        where: { id: book.id },
        select: { glossary: true },
      });
      const existingGlossary = normalizeBookContextPackage(existingBook?.glossary);
      const extracted = await this.reviewService.extractGlossaryFromSegmentsWithModel(
        segments,
        book.targetLang,
        sidekick,
        existingGlossary,
        concurrency,
      );
      const merged = mergeBookContextPackages(existingGlossary, extracted);
      const newTermCount = countBookContextEntries(extracted);
      if (this.hasContextContent(extracted)) {
        await this.prisma.book.update({
          where: { id: book.id },
          data: { glossary: merged as unknown as Prisma.InputJsonValue },
        });
        logInfo('sidekick_glossary_merged', {
          event: 'sidekick_glossary_merged',
          bookId: book.id,
          chapterId,
          newTerms: newTermCount,
          sections: extracted.sections.length,
        });
      }
      return true;
    } catch (err) {
      logWarn('sidekick_glossary_blocking_failed', {
        event: 'sidekick_glossary_blocking_failed',
        chapterId,
        errorMessage: err instanceof Error ? err.message : String(err),
      });
      return false;
    }
  }

  private async runPrimaryGlossaryBlocking(
    pages: BookContextPageInput[],
    book: { id: string; targetLang: string },
    chapterId: string,
    contextWindowTokens: number,
    inputTokenBudget: number,
    concurrency: number,
  ): Promise<boolean> {
    try {
      const segments = buildBookContextSegmentsFromPages(pages, contextWindowTokens, inputTokenBudget);
      if (segments.length === 0) return true;

      const existingBook = await this.prisma.book.findUnique({
        where: { id: book.id },
        select: { glossary: true },
      });
      const existingGlossary = this.glossaryService.toBookContextPackage(existingBook?.glossary);
      const extracted = await this.glossaryService.extractBookContextFromSegments(
        segments,
        book.targetLang,
        existingGlossary,
        concurrency,
      );
      const merged = this.glossaryService.mergeGlossaries(existingGlossary, extracted);
      const newTermCount = countBookContextEntries(extracted);
      if (this.hasContextContent(extracted)) {
        await this.prisma.book.update({
          where: { id: book.id },
          data: { glossary: merged as unknown as Prisma.InputJsonValue },
        });
        logInfo('primary_glossary_merged', {
          event: 'primary_glossary_merged',
          bookId: book.id,
          chapterId,
          newTerms: newTermCount,
          sections: extracted.sections.length,
        });
      }
      return true;
    } catch (err) {
      logWarn('primary_glossary_blocking_failed', {
        event: 'primary_glossary_blocking_failed',
        chapterId,
        errorMessage: err instanceof Error ? err.message : String(err),
      });
      return false;
    }
  }

  private hasContextContent(value: unknown): boolean {
    const context = normalizeBookContextPackage(value);
    return context.entries.length > 0
      || context.doNotTranslate.length > 0
      || context.forbiddenTranslations.length > 0
      || context.chapterSummaries.length > 0
      || context.sections.length > 0
      || Object.keys(context.styleGuide).length > 0;
  }

  private previousTailForPage(page: TranslatablePage, sortedPages: TranslatablePage[]): string | undefined {
    const idx = sortedPages.findIndex((candidate) => candidate.id === page.id);
    if (idx <= 0) return undefined;
    return sortedPages[idx - 1].sourceText?.trimEnd().slice(-PREV_PAGE_TAIL_CHARS) ?? undefined;
  }

  private async markChaptersProcessing(bookId: string, pages: TranslatablePage[]): Promise<void> {
    const chapterIds = Array.from(new Set(pages.map((page) => page.chapterId).filter(Boolean))) as string[];
    for (const chapterId of chapterIds) {
      const chapter = await this.prisma.chapter.update({
        where: { id: chapterId },
        data: {
          status: 'processing',
          translationProgress: 0,
          translationStartedAt: new Date(),
          tokensPerSecond: null,
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
  }

  private async enqueueRemainingPages(
    book: { id: string; sourceLang: string; targetLang: string },
    pages: TranslatablePage[],
  ): Promise<number> {
    const remaining = pages.filter((page) => page.chapterId);
    if (remaining.length === 0) return 0;
    await this.markChaptersProcessing(book.id, remaining);
    await Promise.all(remaining.map((page) => {
      return this.translationQueue.enqueuePage({
        pageId: page.id,
        chapterId: page.chapterId!,
        bookId: book.id,
        sourceLang: book.sourceLang,
        targetLang: book.targetLang,
        chapterTitle: page.chapter?.title ?? undefined,
        pageNumber: page.pageNumber,
        previousPageTail: this.previousTailForPage(page, pages),
      });
    }));
    return remaining.length;
  }

  private async runBookGlossaryBlockingAndEnqueue(
    book: { id: string; sourceLang: string; targetLang: string },
    pages: TranslatablePage[],
    contextWindowTokens: number,
    inputTokenBudget: number,
    concurrency: number,
    useSidekick: boolean,
  ): Promise<{ enqueuedPages: number; completed: boolean }> {
    const contextPages: BookContextPageInput[] = pages.map((page) => ({
      sourceText: page.sourceText,
      pageNumber: page.pageNumber,
      chapter: page.chapter,
    }));
    const segments = buildBookContextSegmentsFromPages(contextPages, contextWindowTokens, inputTokenBudget);
    if (segments.length === 0) {
      return {
        enqueuedPages: await this.enqueueRemainingPages(book, pages),
        completed: true,
      };
    }

    const modelSource = useSidekick ? 'sidekick' : 'primary';
    const cacheKey = await this.buildBookContextCacheKey(
      book.id,
      book.targetLang,
      modelSource,
      contextWindowTokens,
      inputTokenBudget,
    );
    if (cacheKey) {
      const cached = await this.readBookContextCache(cacheKey);
      if (cached) {
        await this.prisma.book.update({
          where: { id: book.id },
          data: { glossary: cached as unknown as Prisma.InputJsonValue },
        });
        logInfo('book_context_cache_hit', {
          event: 'book_context_cache_hit',
          bookId: book.id,
          modelSource,
          targetLang: book.targetLang,
          entries: countBookContextEntries(cached),
        });
        const enqueuedPages = await this.enqueueRemainingPages(book, pages);
        return { enqueuedPages, completed: true };
      }
    }

    const mapConcurrency = Math.min(32, Math.max(1, Math.floor(Number.isFinite(concurrency) ? concurrency : 1)));
    const startedAt = Date.now();
    let completedSections = 0;
    const existingGlossary = this.glossaryService.toBookContextPackage(
      (await this.prisma.book.findUnique({ where: { id: book.id }, select: { glossary: true } }))?.glossary,
    );
    const sectionPackages: ContextPackage[] = new Array(segments.length);
    let allSucceeded = true;

    await this.redisPubSub.publishBookEvent(book.id, 'glossary_extracting', {
      bookId: book.id,
      chapterId: BOOK_GLOSSARY_CHAPTER_ID,
      extracting: true,
    });
    await this.redisPubSub.publishBookEvent(book.id, 'pipeline_phase', {
      bookId: book.id,
      phase: 'glossary',
      label: 'Building glossary',
    });
    await this.publishGlossaryProgress(book.id, book.targetLang, {
      bookId: book.id,
      completedSections: 0,
      totalSections: segments.length,
      elapsedMs: 0,
    });

    await runBounded(segments, mapConcurrency, async (segment, index) => {
      await this.publishUsageDelta(book.id, 'glossary', {
        sectionId: segment.sectionId,
        inputTokens: this.estimateGlossaryInputTokens(segment.sourceText, book.targetLang, existingGlossary),
      });

      let extracted = normalizeBookContextPackage(undefined);
      try {
        if (useSidekick) {
          const sidekick = await this.settingsService.getEffectiveSidekickConfig();
          if (sidekick.enabled && sidekick.baseUrl && sidekick.model) {
            extracted = await this.reviewService.extractGlossarySegmentWithModel(
              segment,
              book.targetLang,
              sidekick,
              existingGlossary,
            );
          }
        } else {
          extracted = await this.glossaryService.extractBookContextSegment(segment, book.targetLang, existingGlossary);
        }
      } catch (err) {
        allSucceeded = false;
        logWarn('book_context_section_failed', {
          event: 'book_context_section_failed',
          bookId: book.id,
          sectionId: segment.sectionId,
          errorMessage: err instanceof Error ? err.message : String(err),
        });
      }

      await this.publishUsageDelta(book.id, 'glossary', {
        sectionId: segment.sectionId,
        outputTokens: this.hasContextContent(extracted) ? estimateTokens(JSON.stringify(extracted)) : 0,
      });

      if (this.hasContextContent(extracted)) {
        sectionPackages[index] = extracted;
      }

      completedSections += 1;
      const elapsedMs = Date.now() - startedAt;
      const avgMs = elapsedMs / Math.max(completedSections, 1);
      await this.publishGlossaryProgress(book.id, book.targetLang, {
        bookId: book.id,
        completedSections,
        totalSections: segments.length,
        currentSectionId: segment.sectionId,
        elapsedMs,
        estimatedRemainingMs: Math.max(0, Math.round(avgMs * (segments.length - completedSections))),
      });
    });

    const extractedPackages = sectionPackages.filter((pkg): pkg is ContextPackage => Boolean(pkg));
    let merged: ContextPackage = extractedPackages.reduce(
      (acc, pkg) => mergeBookContextPackages(acc, pkg),
      existingGlossary,
    );

    if (extractedPackages.length >= MIN_GLOSSARY_PACKAGES_FOR_LLM_REDUCTION) {
      try {
        const reductionPackages = [merged, ...extractedPackages];
        await this.publishUsageDelta(book.id, 'glossary', {
          sectionId: 'reduce',
          inputTokens: this.estimateGlossaryReductionInputTokens(reductionPackages, book.targetLang),
        });
        const sidekick = useSidekick ? await this.settingsService.getEffectiveSidekickConfig() : null;
        const reduced = useSidekick && sidekick?.enabled && sidekick.baseUrl && sidekick.model
          ? await this.reviewService.reduceBookContextPackagesWithModel(reductionPackages, book.targetLang, sidekick)
          : await this.glossaryService.reduceBookContextPackages(reductionPackages, book.targetLang);
        await this.publishUsageDelta(book.id, 'glossary', {
          sectionId: 'reduce',
          outputTokens: this.hasContextContent(reduced) ? estimateTokens(JSON.stringify(reduced)) : 0,
        });
        if (this.hasContextContent(reduced)) {
          merged = mergeBookContextPackages(merged, reduced);
        }
      } catch (err) {
        logWarn('book_context_reduce_failed', {
          event: 'book_context_reduce_failed',
          bookId: book.id,
          errorMessage: err instanceof Error ? err.message : String(err),
        });
      }
    }

    if (this.hasContextContent(merged)) {
      await this.prisma.book.update({
        where: { id: book.id },
        data: { glossary: merged as unknown as Prisma.InputJsonValue },
      });
      if (cacheKey) {
        await this.writeBookContextCache(cacheKey, merged);
      }
    }

    await this.publishGlossaryProgress(book.id, book.targetLang, {
      bookId: book.id,
      completedSections: segments.length,
      totalSections: segments.length,
      elapsedMs: Date.now() - startedAt,
      estimatedRemainingMs: 0,
    });
    await this.redisPubSub.publishBookEvent(book.id, 'glossary_extracting', {
      bookId: book.id,
      chapterId: BOOK_GLOSSARY_CHAPTER_ID,
      extracting: false,
    });

    const enqueuedPages = await this.enqueueRemainingPages(book, pages);
    return { enqueuedPages, completed: allSucceeded };
  }

  private estimateGlossaryInputTokens(
    sourceText: string,
    targetLang: string,
    existingGlossary: unknown,
  ): number {
    const systemPrompt = 'You extract structured translation context. Return only a valid JSON object.';
    const userPrompt = buildBookContextPrompt(sourceText, targetLang, existingGlossary);
    return estimateTokens(`${systemPrompt}\n\n${userPrompt}`);
  }

  private estimateGlossaryReductionInputTokens(
    packages: unknown[],
    targetLang: string,
  ): number {
    const systemPrompt = 'You merge structured translation context. Return only a valid JSON object.';
    const userPrompt = buildGlossaryReductionPrompt(packages, targetLang);
    return estimateTokens(`${systemPrompt}\n\n${userPrompt}`);
  }

  private buildGlossarySourceText(pages: BookContextPageInput[], fallbackChapterId: string): string {
    let lastChapterKey = '';
    const parts: string[] = [];
    for (const page of pages) {
      const text = page.sourceText?.trim();
      if (!text) continue;
      const chapter = page.chapter;
      const chapterKey = chapter?.id ?? fallbackChapterId;
      if (chapterKey && chapterKey !== lastChapterKey) {
        const title = chapter?.title ? ` title="${chapter.title}"` : '';
        const number = chapter?.chapterNumber ? ` number="${chapter.chapterNumber}"` : '';
        parts.push(`[CHAPTER id="${chapterKey}"${number}${title}]`);
        lastChapterKey = chapterKey;
      }
      const pageNumber = page.pageNumber ? ` page="${page.pageNumber}"` : '';
      parts.push(`[PAGE${pageNumber}]\n${text}`);
    }
    return parts.join('\n\n');
  }


  async startBookTranslation(bookId: string): Promise<{ enqueuedPages: number }> {
    const book = await this.prisma.book.findUnique({ where: { id: bookId } });
    if (!book) throw new NotFoundException(`Book ${bookId} not found`);
    logInfo('start_book_translation', { event: 'startBookTranslation', bookId });

    if (book.status === 'processing') {
      logInfo('start_book_translation_idempotent', {
        event: 'startBookTranslation',
        bookId,
        status: 'processing',
      });
      await this.replayGlossaryProgress(bookId, book.targetLang);
      return { enqueuedPages: 0 };
    }

    await this.translationQueue.drain();

    const switched = await this.prisma.book.findMany({
      where: { id: { not: bookId }, status: 'processing' },
      select: { id: true },
    });
    const switchedBookIds = (switched ?? []).map((b) => b.id);
    await this.prisma.chapter.updateMany({
      where: { bookId: { not: bookId }, status: 'processing' },
      data: { status: 'pending' },
    });
    await this.prisma.book.updateMany({
      where: { id: { not: bookId }, status: 'processing' },
      data: { status: 'pending' },
    });

    await this.translationQueue.resume();
    await this.prisma.book.update({
      where: { id: bookId },
      data: { status: 'processing' },
    });
    await this.publishQueueState(bookId, false);
    await this.publishBookState(bookId);
    for (const oldBookId of switchedBookIds) {
      await this.publishQueueState(oldBookId, false);
      await this.publishBookState(oldBookId);
    }
    if (switchedBookIds.length > 0) {
      logInfo('translation_switched_books', {
        event: 'startBookTranslation',
        bookId,
        switchedBookIds,
      });
    }

    const chapters = await this.prisma.chapter.findMany({
      where: { bookId, status: { not: 'completed' } },
      orderBy: { chapterNumber: 'asc' },
    });

    if (chapters.length === 0) {
      await this.prisma.book.update({ where: { id: bookId }, data: { status: 'pending' } });
      await this.publishBookState(bookId);
      throw new BadRequestException({
        message: 'All chapters in this book are already translated.',
        businessCode: 'BOOK_ALREADY_TRANSLATED',
      });
    }

    const translationConfig = await this.settingsService.getTranslationConfig();
    if (translationConfig.glossaryEnabled) {
      const bookGlossaryAlreadyDone = await this.isGlossaryDone(bookId, book.targetLang);
      if (bookGlossaryAlreadyDone) {
        logInfo('book_glossary_skipped_done', {
          event: 'book_glossary_skipped_done',
          bookId,
        });
      } else {
        const allPages = await this.prisma.page.findMany({
          where: {
            bookId,
            sourceText: { not: null },
            ocrStatus: 'completed',
            translationStatus: { not: 'completed' },
          },
          orderBy: [
            { chapter: { chapterNumber: 'asc' } },
            { pageNumber: 'asc' },
          ],
          select: {
            id: true,
            chapterId: true,
            sourceText: true,
            pageNumber: true,
            chapter: { select: { id: true, title: true, chapterNumber: true } },
          },
        });

        if (allPages.length > 0) {
          const useSidekick = await this.shouldUseSidekickGlossary(translationConfig.glossaryModelSource);
          const glossaryResult = await this.runBookGlossaryBlockingAndEnqueue(
            book,
            allPages,
            translationConfig.contextWindowTokens,
            translationConfig.inputTokenBudget,
            translationConfig.concurrency,
            useSidekick,
          );
          if (glossaryResult.enqueuedPages > 0) {
            await this.publishBookState(bookId);
            if (glossaryResult.completed) await this.markGlossaryDone(bookId, book.targetLang);
            logInfo('start_book_translation_enqueued_after_glossary', {
              event: 'startBookTranslation',
              bookId,
              enqueuedPages: glossaryResult.enqueuedPages,
            });
            return { enqueuedPages: glossaryResult.enqueuedPages };
          }
          if (glossaryResult.completed) await this.markGlossaryDone(bookId, book.targetLang);
        }
      }
    }

    let totalEnqueued = 0;
    const enqueueFailures: Array<{ chapterId: string; message: string; businessCode?: string }> = [];
    for (const chapter of chapters) {
      try {
        const result = await this.startTranslation(chapter.id, {
          skipCapacityCheck: true,
          internal: true,
        });
        totalEnqueued += result.enqueuedPages;
      } catch (err) {
        const response = err instanceof HttpException ? err.getResponse() : undefined;
        const body =
          typeof response === 'object' && response !== null
            ? (response as Record<string, unknown>)
            : {};
        const message =
          typeof body.message === 'string'
            ? body.message
            : err instanceof Error
              ? err.message
              : String(err);
        const businessCode =
          typeof body.businessCode === 'string' ? body.businessCode : undefined;
        enqueueFailures.push({ chapterId: chapter.id, message, businessCode });
      }
    }

    if (totalEnqueued === 0) {
      await this.prisma.book.update({ where: { id: bookId }, data: { status: 'pending' } });
      await this.publishBookState(bookId);
      logWarn('start_book_translation_no_jobs', {
        event: 'startBookTranslation',
        bookId,
        failures: enqueueFailures,
      });
      throw new BadRequestException({
        message: 'This book has no OCR-completed pages to translate.',
        businessCode: 'BOOK_NO_TRANSLATABLE_PAGES',
        details: enqueueFailures,
      });
    }

    if (enqueueFailures.length > 0) {
      logWarn('start_book_translation_partial_failures', {
        event: 'startBookTranslation',
        bookId,
        failures: enqueueFailures,
      });
    }
    logInfo('start_book_translation_enqueued', {
      event: 'startBookTranslation',
      bookId,
      enqueuedPages: totalEnqueued,
      pendingChapters: chapters.length,
    });
    return { enqueuedPages: totalEnqueued };
  }

  async pauseTranslation(): Promise<{ paused: boolean }> {
    const chapter = await this.prisma.chapter.findFirst({
      where: { status: 'processing' },
      select: { bookId: true },
    });
    await this.translationQueue.pause();
    if (chapter?.bookId) {
      await this.publishQueueState(chapter.bookId, true);
    }
    logInfo('pause_translation', { event: 'pause', bookId: chapter?.bookId ?? null });
    return { paused: true };
  }

  async resumeTranslation(): Promise<{ paused: boolean }> {
    const chapter = await this.prisma.chapter.findFirst({
      where: { status: 'processing' },
      select: { bookId: true },
    });
    await this.translationQueue.resume();
    if (chapter?.bookId) {
      await this.publishQueueState(chapter.bookId, false);
    }
    logInfo('resume_translation', { event: 'resume', bookId: chapter?.bookId ?? null });
    return { paused: false };
  }

  async getQueueStatus(): Promise<{ isPaused: boolean }> {
    const isPaused = await this.translationQueue.isPaused();
    return { isPaused };
  }
}
