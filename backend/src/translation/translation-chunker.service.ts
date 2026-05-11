import { Inject, Injectable } from '@nestjs/common';
import { RecursiveCharacterTextSplitter } from '@langchain/textsplitters';
import { logDebug } from '../common/logging/app-logger';
import { estimateTokens } from '../common/token-estimate';
import { LLM_SERVICE, LlmService } from '../llm/llm.service';
import { SettingsService } from '../settings/settings.service';
import {
  buildSystemPrompt,
  buildUserPrompt,
  CONTEXT_TAIL_CHARS,
  trimToSentenceBoundary,
} from './translation-prompt.builder';


export interface TextChunk {
  index: number;
  text: string;

  contextTail: string;
}


export interface ChunkTranslation {
  index: number;
  originalText: string;
  translatedText: string;
  tokenCount?: number;
  durationMs?: number;
}


export interface TranslatePageOptions {
  sourceText: string;
  sourceLang: string;
  targetLang: string;
  chapterId?: string;
  chapterTitle?: string;
  pageNumber?: number;
  glossary?: unknown;
  stylePrompt?: string;
}

interface SplitBudgetContext {
  sourceLang: string;
  targetLang: string;
  chapterTitle?: string;
  stylePrompt?: string;
  inputTokenBudget: number;
  contextWindowTokens: number;
}

const DEFAULT_INPUT_TOKEN_BUDGET = Number(process.env.TRANSLATION_INPUT_TOKEN_BUDGET ?? 1200);
const DEFAULT_CONTEXT_WINDOW_TOKENS = Number(process.env.TRANSLATION_CONTEXT_WINDOW_TOKENS ?? 8192);
const MIN_DYNAMIC_CHUNK_TOKENS = 64;
const OUTPUT_RESERVE_FLOOR_TOKENS = 512;
const SAFETY_MARGIN_RATIO = 0.2;
const MAX_BUDGET_FALLBACKS = 3;
const FALLBACK_SHRINK_RATIO = 0.8;

const SEPARATORS = ['\n\n', '\n', '。', '！', '？', '；', '.', '!', '?', ';', '，', ',', ' ', ''];

@Injectable()
export class TranslationChunkerService {
  constructor(
    @Inject(LLM_SERVICE) private readonly llm: LlmService,
    private readonly settings: SettingsService,
  ) {}

  async translatePage(
    options: TranslatePageOptions,
    onChunkDone?: (chunk: ChunkTranslation, total: number) => void,
  ): Promise<string> {
    const chunks = await this.splitIntoChunks(options.sourceText, {
      sourceLang: options.sourceLang,
      targetLang: options.targetLang,
      chapterTitle: options.chapterTitle,
      stylePrompt: options.stylePrompt,
    });
    const results: ChunkTranslation[] = [];

    for (const chunk of chunks) {
      const translated = await this.translateChunk(chunk, options, options.glossary);
      results.push(translated);
      onChunkDone?.(translated, chunks.length);
    }

    return results
      .sort((a, b) => a.index - b.index)
      .map((r) => r.translatedText)
      .join('\n\n');
  }


  async *streamPage(options: TranslatePageOptions): AsyncGenerator<string> {
    const chunks = await this.splitIntoChunks(options.sourceText, {
      sourceLang: options.sourceLang,
      targetLang: options.targetLang,
      chapterTitle: options.chapterTitle,
      stylePrompt: options.stylePrompt,
    });
    for (const chunk of chunks) {
      const sys = buildSystemPrompt(
        options.sourceLang,
        options.targetLang,
        options.stylePrompt,
        options.glossary,
        chunk.text,
        options.chapterId,
        options.pageNumber,
      );
      const user = buildUserPrompt(chunk, options.chapterTitle);
      yield* this.llm.translateStream({ text: user, targetLang: options.targetLang, systemPrompt: sys });
      if (chunk.index < chunks.length - 1) yield '\n\n';
    }
  }


  async translateChunkDirect(
    chunk: TextChunk,
    options: TranslatePageOptions,
  ): Promise<ChunkTranslation> {
    return this.translateChunk(chunk, options, options.glossary);
  }


  async *translateChunkStream(
    chunk: TextChunk,
    options: TranslatePageOptions,
  ): AsyncGenerator<string> {
    const sys = buildSystemPrompt(
      options.sourceLang,
      options.targetLang,
      options.stylePrompt,
      options.glossary,
      chunk.text,
      options.chapterId,
      options.pageNumber,
    );
    const user = buildUserPrompt(chunk, options.chapterTitle);
    yield* this.llm.translateStream({ text: user, targetLang: options.targetLang, systemPrompt: sys });
  }

  async splitIntoChunks(
    text: string,
    context?: Partial<SplitBudgetContext>,
  ): Promise<TextChunk[]> {
    if (!text.trim()) return [];

    const cfg = await this.settings.getTranslationConfig();
    const splitContext: SplitBudgetContext = {
      sourceLang: context?.sourceLang ?? 'auto',
      targetLang: context?.targetLang ?? 'target',
      chapterTitle: context?.chapterTitle,
      stylePrompt: context?.stylePrompt ?? '',
      inputTokenBudget: context?.inputTokenBudget ?? cfg.inputTokenBudget ?? DEFAULT_INPUT_TOKEN_BUDGET,
      contextWindowTokens: context?.contextWindowTokens ?? cfg.contextWindowTokens ?? DEFAULT_CONTEXT_WINDOW_TOKENS,
    };

    const budget = this.resolveChunkBudget(splitContext);
    const texts = await this.splitWithFallback(text, budget);
    const chunks = texts
      .map((t) => t.trim())
      .filter((t) => t.length > 0)
      .map((t, i, arr) => ({
        index: i,
        text: t,
        contextTail: i > 0 ? trimToSentenceBoundary(arr[i - 1], CONTEXT_TAIL_CHARS) : '',
      }));

    logDebug('translation_chunk_plan', {
      event: 'translation_chunk_plan',
      inputTokenBudget: splitContext.inputTokenBudget,
      contextWindowTokens: splitContext.contextWindowTokens,
      effectiveInputBudget: budget.effectiveInputBudget,
      fixedOverheadTokens: budget.fixedOverheadTokens,
      outputReserveTokens: OUTPUT_RESERVE_FLOOR_TOKENS,
      safetyMarginTokens: budget.safetyMarginTokens,
      chunks: chunks.length,
    });
    return chunks;
  }

  private resolveChunkBudget(context: SplitBudgetContext): {
    effectiveInputBudget: number;
    fixedOverheadTokens: number;
    safetyMarginTokens: number;
  } {
    const fixedOverheadTokens = estimateTokens(
      [
        buildSystemPrompt(
          context.sourceLang,
          context.targetLang,
          context.stylePrompt,
          undefined,
          '',
        ),
        buildUserPrompt({ text: '', contextTail: '' }, context.chapterTitle),
      ].join('\n\n'),
    );
    const safetyMarginTokens = Math.ceil(context.contextWindowTokens * SAFETY_MARGIN_RATIO);
    const availableInput =
      context.contextWindowTokens
      - OUTPUT_RESERVE_FLOOR_TOKENS
      - safetyMarginTokens
      - fixedOverheadTokens;
    if (availableInput < MIN_DYNAMIC_CHUNK_TOKENS) {
      throw new Error(
        `TRANSLATION_CHUNK_BUDGET_EXCEEDED: context window ${context.contextWindowTokens} leaves only ${availableInput} input tokens`,
      );
    }
    return {
      effectiveInputBudget: Math.max(
        MIN_DYNAMIC_CHUNK_TOKENS,
        Math.min(context.inputTokenBudget, availableInput),
      ),
      fixedOverheadTokens,
      safetyMarginTokens,
    };
  }

  private async splitWithFallback(
    text: string,
    budget: { effectiveInputBudget: number; fixedOverheadTokens: number; safetyMarginTokens: number },
  ): Promise<string[]> {
    let chunkSize = budget.effectiveInputBudget;
    let lastTexts: string[] = [];
    for (let attempt = 0; attempt <= MAX_BUDGET_FALLBACKS; attempt += 1) {
      const splitter = new RecursiveCharacterTextSplitter({
        chunkSize,
        chunkOverlap: 0,
        separators: SEPARATORS,
        lengthFunction: estimateTokens,
      });
      const texts = await splitter.splitText(text);
      lastTexts = texts;
      const maxChunkTokens = Math.max(0, ...texts.map((chunk) => estimateTokens(chunk)));
      if (maxChunkTokens <= budget.effectiveInputBudget) {
        return texts;
      }
      chunkSize = Math.max(MIN_DYNAMIC_CHUNK_TOKENS, Math.floor(chunkSize * FALLBACK_SHRINK_RATIO));
    }
    throw new Error(
      `TRANSLATION_CHUNK_BUDGET_EXCEEDED: failed to split within ${budget.effectiveInputBudget} input tokens after ${MAX_BUDGET_FALLBACKS} fallbacks; lastChunks=${lastTexts.length}`,
    );
  }

  private async translateChunk(
    chunk: TextChunk,
    options: TranslatePageOptions,
    glossary?: unknown,
  ): Promise<ChunkTranslation> {
    const systemPrompt = buildSystemPrompt(
      options.sourceLang,
      options.targetLang,
      options.stylePrompt,
      glossary,
      chunk.text,
      options.chapterId,
      options.pageNumber,
    );
    const userPrompt = buildUserPrompt(chunk, options.chapterTitle);

    const result = await this.llm.translate({
      text: userPrompt,
      targetLang: options.targetLang,
      systemPrompt,
    });

    return {
      index: chunk.index,
      originalText: chunk.text,
      translatedText: result.translatedText,
      tokenCount: result.tokenCount,
      durationMs: result.durationMs,
    };
  }
}
