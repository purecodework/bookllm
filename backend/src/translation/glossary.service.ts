import { Inject, Injectable } from '@nestjs/common';
import { logInfo, logWarn } from '../common/logging/app-logger';
import { PrismaService } from '../prisma/prisma.service';
import { LLM_SERVICE, LlmService } from '../llm/llm.service';
import {
  type BookContextPackage,
  buildGlossaryReductionPrompt,
  buildGlossaryExtractionPrompt,
  buildBookContextPrompt,
  buildGlossaryContinuationPrompt,
  isGlossaryResponseTruncated,
  mergeBookContextPackages,
  normalizeBookContextPackage,
  parseGlossaryResponse,
  parseGlossaryResponsePartial,
  toLegacyGlossaryMap,
} from './translation-prompt.builder';
import { type BookContextSegment } from './book-context-segments';

const REDUCE_BATCH_SIZE = 20;
const MAX_GLOSSARY_CONCURRENCY = 32;

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
export class GlossaryService {
  constructor(
    private readonly prisma: PrismaService,
    @Inject(LLM_SERVICE) private readonly llm: LlmService,
  ) {}

  toGlossaryMap(value: unknown): Record<string, string> {
    return toLegacyGlossaryMap(value);
  }

  toBookContextPackage(value: unknown): BookContextPackage {
    return normalizeBookContextPackage(value);
  }

  mergeGlossaries(
    existing: unknown,
    extracted: unknown,
  ): BookContextPackage {
    return mergeBookContextPackages(existing, extracted);
  }


  private splitAt(text: string): number {
    const mid = Math.floor(text.length / 2);
    const paraBreak = text.lastIndexOf('\n\n', mid);
    const lineBreak = text.lastIndexOf('\n', mid);
    if (paraBreak > mid - 4_000) return paraBreak;
    if (lineBreak > mid - 1_000) return lineBreak;
    return mid;
  }


  async extractGlossaryTermsRecursive(
    sourceText: string,
    targetLang: string,
    existingGlossary: unknown,
    depth = 0,
  ): Promise<BookContextPackage> {
    const MIN_CHARS = 2_000;
    const MAX_DEPTH = 3;

    if (!sourceText.trim()) return normalizeBookContextPackage(undefined);

    try {
      return await this.extractGlossaryTerms(sourceText, targetLang, existingGlossary);
    } catch (err) {
      if (depth >= MAX_DEPTH || sourceText.length < MIN_CHARS) {
        logWarn('glossary_chunk_failed_giving_up', {
          event: 'glossary_chunk_failed_giving_up',
          depth,
          textLength: sourceText.length,
          errorMessage: err instanceof Error ? err.message : String(err),
        });
        return normalizeBookContextPackage(undefined);
      }

      const splitAt = this.splitAt(sourceText);
      logInfo('glossary_extract_split', {
        event: 'glossary_extract_split',
        depth,
        textLength: sourceText.length,
        splitAt,
      });

      const firstResult = await this.extractGlossaryTermsRecursive(
        sourceText.slice(0, splitAt), targetLang, existingGlossary, depth + 1,
      );
      const knownAfterFirst = this.mergeGlossaries(existingGlossary, firstResult);
      const secondResult = await this.extractGlossaryTermsRecursive(
        sourceText.slice(splitAt), targetLang, knownAfterFirst, depth + 1,
      );

      return mergeBookContextPackages(firstResult, secondResult);
    }
  }

  async extractGlossaryTerms(
    sourceText: string,
    targetLang: string,
    existingGlossary: unknown,
  ): Promise<BookContextPackage> {
    if (!sourceText.trim()) return normalizeBookContextPackage(undefined);

    const systemPrompt = 'You extract structured translation context. Return only a valid JSON object.';
    const prompt = buildGlossaryExtractionPrompt(sourceText, targetLang, existingGlossary);
    const result = await this.llm.translate({ text: prompt, targetLang, systemPrompt });
    const raw = result.translatedText;

    const parsed = parseGlossaryResponse(raw);
    if (parsed.entries.length > 0 || parsed.doNotTranslate.length > 0 || parsed.chapterSummaries.length > 0) {
      return parsed;
    }

    if (isGlossaryResponseTruncated(raw)) {
      const partial = parseGlossaryResponsePartial(raw);
      const alreadyExtracted = [
        ...Object.keys(toLegacyGlossaryMap(existingGlossary)),
        ...Object.keys(partial),
      ];
      try {
        const contPrompt = buildGlossaryContinuationPrompt(sourceText, targetLang, alreadyExtracted);
        const contResult = await this.llm.translate({ text: contPrompt, targetLang, systemPrompt });
        const continued = parseGlossaryResponse(contResult.translatedText);
        return mergeBookContextPackages(partial, continued);
      } catch {
        return normalizeBookContextPackage(partial);
      }
    }

    return normalizeBookContextPackage(undefined);
  }

  async extractBookContextSegment(
    segment: BookContextSegment,
    targetLang: string,
    existingGlossary: unknown,
  ): Promise<BookContextPackage> {
    if (!segment.sourceText.trim()) return normalizeBookContextPackage(undefined);

    const systemPrompt = 'You extract structured translation context. Return only a valid JSON object.';
    const prompt = buildBookContextPrompt(segment.sourceText, targetLang, existingGlossary);
    const result = await this.llm.translate({ text: prompt, targetLang, systemPrompt });
    return parseGlossaryResponse(result.translatedText);
  }

  async extractBookContextFromSegments(
    segments: BookContextSegment[],
    targetLang: string,
    existingGlossary: unknown,
    concurrency = 1,
  ): Promise<BookContextPackage> {
    if (segments.length === 0) return normalizeBookContextPackage(undefined);

    const parsedConcurrency = Number.isFinite(concurrency) ? Math.floor(concurrency) : 1;
    const mapConcurrency = Math.min(MAX_GLOSSARY_CONCURRENCY, Math.max(1, parsedConcurrency));
    logInfo('book_context_extraction_started', {
      event: 'book_context_extraction_started',
      segments: segments.length,
      concurrency: mapConcurrency,
    });

    const extracted = (await runBounded(segments, mapConcurrency, async (segment) => {
      try {
        const result = await this.extractBookContextSegment(segment, targetLang, existingGlossary);
        logInfo('book_context_section_extracted', {
          event: 'book_context_section_extracted',
          sectionId: segment.sectionId,
          pageStart: segment.pageStart,
          pageEnd: segment.pageEnd,
          entries: result.entries.length,
        });
        return result;
      } catch (err) {
        logWarn('book_context_section_failed', {
          event: 'book_context_section_failed',
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
    return this.reduceBookContextPackages([normalizeBookContextPackage(existingGlossary), ...extracted], targetLang);
  }

  async reduceBookContextPackages(
    packages: unknown[],
    targetLang: string,
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
      const reduced = await this.reduceBookContextPackageBatch(normalized, targetLang);
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
      logWarn('book_context_reduce_failed', {
        event: 'book_context_reduce_failed',
        packages: normalized.length,
        errorMessage: err instanceof Error ? err.message : String(err),
      });
    }

    return normalized.reduce(
      (acc, pkg) => mergeBookContextPackages(acc, pkg),
      normalizeBookContextPackage(undefined),
    );
  }

  private async reduceBookContextPackageBatch(
    packages: BookContextPackage[],
    targetLang: string,
  ): Promise<BookContextPackage> {
    if (packages.length <= REDUCE_BATCH_SIZE) {
      const prompt = buildGlossaryReductionPrompt(packages, targetLang);
      const systemPrompt = 'You merge structured translation context. Return only a valid JSON object.';
      const result = await this.llm.translate({ text: prompt, targetLang, systemPrompt });
      return parseGlossaryResponse(result.translatedText);
    }

    const reducedBatches: BookContextPackage[] = [];
    for (let i = 0; i < packages.length; i += REDUCE_BATCH_SIZE) {
      reducedBatches.push(
        await this.reduceBookContextPackageBatch(packages.slice(i, i + REDUCE_BATCH_SIZE), targetLang),
      );
    }
    return this.reduceBookContextPackageBatch(reducedBatches, targetLang);
  }

}
