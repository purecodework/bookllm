import { Injectable } from '@nestjs/common';
import { HttpService } from '@nestjs/axios';
import { firstValueFrom } from 'rxjs';
import { logInfo, logWarn } from '../common/logging/app-logger';
import { SidekickConfig } from '../settings/settings.service';
import {
  type BookContextPackage,
  buildGlossaryReductionPrompt,
  buildReviewPrompt,
  buildBookContextPrompt,
  buildPolishPrompt,
  mergeBookContextPackages,
  normalizeBookContextPackage,
  parseGlossaryResponse,
} from '../translation/translation-prompt.builder';
import { type BookContextSegment } from '../translation/book-context-segments';

interface ChatCompletionResponse {
  choices?: Array<{ message?: { content?: string } }>;
}


const MIN_SPLIT_CHARS = 8_000;

const MAX_SPLIT_DEPTH = 3;
const REDUCE_BATCH_SIZE = 20;
const MAX_GLOSSARY_CONCURRENCY = 32;
const MIN_PASS_LENGTH_RATIO = 0.72;

async function runBounded<T, R>(
  items: T[],
  concurrency: number,
  worker: (item: T, index: number) => Promise<R>,
): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let nextIndex = 0;
  const parsedConcurrency = Number.isFinite(concurrency) ? Math.floor(concurrency) : 1;
  const workerCount = Math.min(items.length, Math.max(1, parsedConcurrency));
  await Promise.all(
    Array.from({ length: workerCount }, async () => {
      while (nextIndex < items.length) {
        const index = nextIndex;
        nextIndex += 1;
        results[index] = await worker(items[index], index);
      }
    }),
  );
  return results;
}

@Injectable()
export class ReviewService {
  constructor(private readonly httpService: HttpService) {}

  private readonly MODEL_RETRYABLE_STATUSES = [408, 429, 500, 502, 503, 504];
  private readonly MODEL_RETRYABLE_CODES = ['ECONNRESET', 'ETIMEDOUT', 'EPIPE', 'ENOTFOUND'];
  private readonly MODEL_MAX_RETRIES = 2;
  private readonly MODEL_BASE_DELAY_MS = 1000;

  private isRetryableModelError(err: unknown): boolean {
    const e = err as { response?: { status?: number }; code?: string };
    if (e?.response?.status !== undefined) {
      return this.MODEL_RETRYABLE_STATUSES.includes(e.response.status);
    }
    return this.MODEL_RETRYABLE_CODES.includes(e?.code ?? '');
  }


  private async callModel(
    config: SidekickConfig,
    systemPrompt: string,
    userPrompt: string,
    timeoutMs = 120_000,
  ): Promise<string> {
    for (let attempt = 0; attempt <= this.MODEL_MAX_RETRIES; attempt += 1) {
      try {
        const response = await firstValueFrom(
          this.httpService.post<ChatCompletionResponse>(
            `${config.baseUrl.replace(/\/$/, '')}/chat/completions`,
            {
              model: config.model,
              messages: [
                { role: 'system', content: systemPrompt },
                { role: 'user', content: userPrompt },
              ],
              stream: false,
            },
            {
              headers: {
                Authorization: `Bearer ${config.apiKey || 'local-dev-key'}`,
                'Content-Type': 'application/json',
              },
              timeout: timeoutMs,
            },
          ),
        );
        return response.data.choices?.[0]?.message?.content?.trim() ?? '';
      } catch (err) {
        if (attempt >= this.MODEL_MAX_RETRIES || !this.isRetryableModelError(err)) throw err;
        await new Promise((r) => setTimeout(r, this.MODEL_BASE_DELAY_MS * 2 ** attempt));
      }
    }
    throw new Error('Model call unreachable');
  }

  async extractGlossarySegmentWithModel(
    segment: BookContextSegment,
    targetLang: string,
    config: SidekickConfig,
    existingGlossary: unknown,
  ): Promise<BookContextPackage> {
    const prompt = buildBookContextPrompt(segment.sourceText, targetLang, existingGlossary);
    const raw = await this.callModel(
      config,
      'You extract structured translation context. Return only a valid JSON object.',
      prompt,
      60_000,
    );
    return parseGlossaryResponse(raw);
  }

  private async extractGlossaryChunk(
    text: string,
    targetLang: string,
    config: SidekickConfig,
    existingGlossary: unknown,
  ): Promise<BookContextPackage> {
    return this.extractGlossarySegmentWithModel(
      { sectionId: 'legacy', sourceText: text },
      targetLang,
      config,
      existingGlossary,
    );
  }


  private async extractWithSplit(
    text: string,
    targetLang: string,
    config: SidekickConfig,
    existingGlossary: unknown,
    depth: number,
  ): Promise<BookContextPackage> {
    try {
      return await this.extractGlossaryChunk(text, targetLang, config, existingGlossary);
    } catch (err) {
      if (depth >= MAX_SPLIT_DEPTH || text.length < MIN_SPLIT_CHARS) {
        logWarn('secondary_model_glossary_chunk_failed', {
          event: 'secondary_model_glossary_chunk_failed',
          depth,
          textLength: text.length,
          errorMessage: err instanceof Error ? err.message : String(err),
        });
        return normalizeBookContextPackage(undefined);
      }

      const mid = Math.floor(text.length / 2);
      const paraBreak = text.lastIndexOf('\n\n', mid);
      const lineBreak = text.lastIndexOf('\n', mid);
      const splitAt =
        paraBreak > mid - 4000 ? paraBreak
        : lineBreak > mid - 1000 ? lineBreak
        : mid;

      logInfo('secondary_model_glossary_split', {
        event: 'secondary_model_glossary_split',
        depth,
        textLength: text.length,
        splitAt,
      });

      const firstResult = await this.extractWithSplit(
        text.slice(0, splitAt), targetLang, config, existingGlossary, depth + 1,
      );
      const knownAfterFirst = mergeBookContextPackages(existingGlossary, firstResult);
      const secondResult = await this.extractWithSplit(
        text.slice(splitAt), targetLang, config, knownAfterFirst, depth + 1,
      );

      return mergeBookContextPackages(firstResult, secondResult);
    }
  }

  async extractGlossaryWithModel(
    chapterText: string,
    targetLang: string,
    config: SidekickConfig,
    existingGlossary: unknown,
  ): Promise<BookContextPackage> {
    if (!config.enabled || !config.baseUrl || !config.model) {
      return normalizeBookContextPackage(undefined);
    }
    if (!chapterText.trim()) return normalizeBookContextPackage(undefined);

    try {
      const extracted = await this.extractWithSplit(chapterText, targetLang, config, existingGlossary, 0);
      logInfo('secondary_model_glossary_done', {
        event: 'secondary_model_glossary_done',
        model: config.model,
        chapterLength: chapterText.length,
        extractedTerms: extracted.entries.length,
      });
      return extracted;
    } catch (err) {
      logWarn('secondary_model_glossary_failed', {
        event: 'secondary_model_glossary_failed',
        errorMessage: err instanceof Error ? err.message : String(err),
      });
      return normalizeBookContextPackage(undefined);
    }
  }

  async extractGlossaryFromSegmentsWithModel(
    segments: BookContextSegment[],
    targetLang: string,
    config: SidekickConfig,
    existingGlossary: unknown,
    concurrency = 1,
  ): Promise<BookContextPackage> {
    if (!config.enabled || !config.baseUrl || !config.model) {
      return normalizeBookContextPackage(undefined);
    }
    if (segments.length === 0) return normalizeBookContextPackage(undefined);

    const parsedConcurrency = Number.isFinite(concurrency) ? Math.floor(concurrency) : 1;
    const mapConcurrency = Math.min(MAX_GLOSSARY_CONCURRENCY, Math.max(1, parsedConcurrency));
    logInfo('secondary_model_book_context_extraction_started', {
      event: 'secondary_model_book_context_extraction_started',
      model: config.model,
      segments: segments.length,
      concurrency: mapConcurrency,
    });

    const extracted = (await runBounded(segments, mapConcurrency, async (segment) => {
      try {
        const result = await this.extractGlossarySegmentWithModel(segment, targetLang, config, existingGlossary);
        logInfo('secondary_model_book_context_section_extracted', {
          event: 'secondary_model_book_context_section_extracted',
          model: config.model,
          sectionId: segment.sectionId,
          pageStart: segment.pageStart,
          pageEnd: segment.pageEnd,
          entries: result.entries.length,
        });
        return result;
      } catch (err) {
        logWarn('secondary_model_book_context_section_failed', {
          event: 'secondary_model_book_context_section_failed',
          sectionId: segment.sectionId,
          errorMessage: err instanceof Error ? err.message : String(err),
        });
        return normalizeBookContextPackage(undefined);
      }
    })).filter((pkg) =>
      pkg.entries.length > 0
      || pkg.doNotTranslate.length > 0
      || pkg.forbiddenTranslations.length > 0
      || pkg.chapterSummaries.length > 0
      || pkg.sections.length > 0
      || Object.keys(pkg.styleGuide).length > 0,
    );

    if (extracted.length === 0) return normalizeBookContextPackage(undefined);
    return this.reduceBookContextPackagesWithModel(
      [normalizeBookContextPackage(existingGlossary), ...extracted],
      targetLang,
      config,
    );
  }

  async reduceBookContextPackagesWithModel(
    packages: unknown[],
    targetLang: string,
    config: SidekickConfig,
  ): Promise<BookContextPackage> {
    const normalized = packages
      .map((pkg) => normalizeBookContextPackage(pkg))
      .filter((pkg) =>
        pkg.entries.length > 0
        || pkg.doNotTranslate.length > 0
        || pkg.forbiddenTranslations.length > 0
        || pkg.chapterSummaries.length > 0
        || pkg.sections.length > 0
        || Object.keys(pkg.styleGuide).length > 0,
      );
    if (normalized.length === 0) return normalizeBookContextPackage(undefined);
    if (normalized.length === 1) return normalized[0];

    try {
      const reduced = await this.reduceBookContextPackageBatchWithModel(normalized, targetLang, config);
      if (
        reduced.entries.length > 0
        || reduced.doNotTranslate.length > 0
        || reduced.forbiddenTranslations.length > 0
        || reduced.chapterSummaries.length > 0
        || reduced.sections.length > 0
      ) {
        return reduced;
      }
    } catch (err) {
      logWarn('secondary_model_book_context_reduce_failed', {
        event: 'secondary_model_book_context_reduce_failed',
        packages: normalized.length,
        errorMessage: err instanceof Error ? err.message : String(err),
      });
    }

    return normalized.reduce(
      (acc, pkg) => mergeBookContextPackages(acc, pkg),
      normalizeBookContextPackage(undefined),
    );
  }

  private async reduceBookContextPackageBatchWithModel(
    packages: BookContextPackage[],
    targetLang: string,
    config: SidekickConfig,
  ): Promise<BookContextPackage> {
    if (packages.length <= REDUCE_BATCH_SIZE) {
      const raw = await this.callModel(
        config,
        'You merge structured translation context. Return only a valid JSON object.',
        buildGlossaryReductionPrompt(packages, targetLang),
        60_000,
      );
      return parseGlossaryResponse(raw);
    }

    const reducedBatches: BookContextPackage[] = [];
    for (let i = 0; i < packages.length; i += REDUCE_BATCH_SIZE) {
      reducedBatches.push(
        await this.reduceBookContextPackageBatchWithModel(
          packages.slice(i, i + REDUCE_BATCH_SIZE),
          targetLang,
          config,
        ),
      );
    }
    return this.reduceBookContextPackageBatchWithModel(reducedBatches, targetLang, config);
  }

  private async runModelPass(
    config: SidekickConfig,
    systemPrompt: string,
    userPrompt: string,
    fallbackText: string,
    pass: 'review' | 'polish',
  ): Promise<string> {
    try {
      const result = await this.callModel(config, systemPrompt, userPrompt);
      if (!result) {
        logWarn('model_empty_response', { event: 'model_empty_response', pass });
        return fallbackText;
      }
      if (this.isSuspiciousPassOutput(fallbackText, result)) {
        logWarn('model_pass_suspicious_output', {
          event: 'model_pass_suspicious_output',
          pass,
          model: config.model,
          inputLength: fallbackText.length,
          outputLength: result.length,
          inputParagraphs: this.countParagraphs(fallbackText),
          outputParagraphs: this.countParagraphs(result),
        });
        return fallbackText;
      }

      logInfo('model_pass_done', {
        event: 'model_pass_done',
        pass,
        model: config.model,
        inputLength: fallbackText.length,
        outputLength: result.length,
      });
      return result;
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : String(err);
      logWarn('model_pass_failed', {
        event: 'model_pass_failed',
        pass,
        errorMessage,
      });
      return fallbackText;
    }
  }

  private isSuspiciousPassOutput(input: string, output: string): boolean {
    const inputLength = input.trim().length;
    const outputLength = output.trim().length;
    if (inputLength < 240) return false;
    if (outputLength < Math.floor(inputLength * MIN_PASS_LENGTH_RATIO)) return true;

    const inputParagraphs = this.countParagraphs(input);
    const outputParagraphs = this.countParagraphs(output);
    if (inputParagraphs >= 3 && outputParagraphs < Math.ceil(inputParagraphs * 0.6)) return true;

    return false;
  }

  private countParagraphs(text: string): number {
    return text
      .split(/\n{2,}/)
      .map((part) => part.trim())
      .filter(Boolean).length;
  }

  async reviewTranslation(
    sourceText: string,
    draftText: string,
    targetLang: string,
    config: SidekickConfig,
    glossary?: unknown,
    chapterId?: string,
    pageNumber?: number,
  ): Promise<string> {
    if (!config.enabled || !config.baseUrl || !config.model) return draftText;

    let result = draftText;

    {
      const { systemPrompt, userPrompt } = buildReviewPrompt(
        sourceText,
        result,
        targetLang,
        glossary,
        chapterId,
        pageNumber,
      );
      result = await this.runModelPass(config, systemPrompt, userPrompt, result, 'review');
    }

    logInfo('review_done', {
      event: 'review_done',
      model: config.model,
      proofread: true,
      polish: false,
      draftLength: draftText.length,
      reviewedLength: result.length,
    });
    return result;
  }

  async polishTranslation(
    sourceText: string,
    draftText: string,
    targetLang: string,
    config: SidekickConfig,
    glossary?: unknown,
    stylePrompt?: string,
    chapterId?: string,
    pageNumber?: number,
  ): Promise<string> {
    if (!config.enabled || !config.baseUrl || !config.model) {
      return draftText;
    }

    const { systemPrompt, userPrompt } = buildPolishPrompt(
      sourceText,
      draftText,
      targetLang,
      glossary,
      stylePrompt,
      chapterId,
      pageNumber,
    );
    const result = await this.runModelPass(config, systemPrompt, userPrompt, draftText, 'polish');

    logInfo('polish_done', {
      event: 'polish_done',
      model: config.model,
      draftLength: draftText.length,
      polishedLength: result.length,
    });
    return result;
  }
}
