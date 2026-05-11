import { estimateTokens } from '../common/token-estimate';

export interface BookContextPageInput {
  sourceText: string | null;
  pageNumber?: number | null;
  chapter?: { id: string; title: string | null; chapterNumber: number } | null;
}

export interface BookContextSegment {
  sectionId: string;
  chapterId?: string;
  title?: string;
  pageStart?: number;
  pageEnd?: number;
  sourceText: string;
}

export function resolveBookContextSectionTokenTarget(
  contextWindowTokens: number,
  inputTokenBudget?: number,
): number {
  const contextBasedTarget = Math.min(6000, Math.max(2500, Math.floor(contextWindowTokens * 0.55)));
  if (!inputTokenBudget || !Number.isFinite(inputTokenBudget)) return contextBasedTarget;
  return Math.min(contextBasedTarget, Math.max(1800, Math.floor(inputTokenBudget)));
}

function formatSectionText(segment: Omit<BookContextSegment, 'sourceText'>, body: string): string {
  const attrs = [
    `id="${segment.sectionId}"`,
    segment.chapterId ? `chapterId="${segment.chapterId}"` : '',
    segment.title ? `title="${segment.title}"` : '',
    segment.pageStart !== undefined ? `pageStart="${segment.pageStart}"` : '',
    segment.pageEnd !== undefined ? `pageEnd="${segment.pageEnd}"` : '',
  ].filter(Boolean);
  return [`[SECTION ${attrs.join(' ')}]`, body.trim()].join('\n');
}

function pageHeader(page: BookContextPageInput): string {
  const attrs = [
    page.pageNumber ? `page="${page.pageNumber}"` : '',
    page.chapter?.id ? `chapterId="${page.chapter.id}"` : '',
    page.chapter?.chapterNumber ? `chapterNumber="${page.chapter.chapterNumber}"` : '',
    page.chapter?.title ? `chapterTitle="${page.chapter.title}"` : '',
  ].filter(Boolean);
  return `[PAGE${attrs.length > 0 ? ` ${attrs.join(' ')}` : ''}]`;
}

function splitOversizedText(text: string, tokenTarget: number): string[] {
  const paragraphs = text.split(/\n{2,}/);
  const chunks: string[] = [];
  let current = '';

  const pushCurrent = () => {
    const trimmed = current.trim();
    if (trimmed) chunks.push(trimmed);
    current = '';
  };

  for (const paragraph of paragraphs) {
    const trimmed = paragraph.trim();
    if (!trimmed) continue;
    const candidate = current ? `${current}\n\n${trimmed}` : trimmed;
    if (estimateTokens(candidate) <= tokenTarget) {
      current = candidate;
      continue;
    }
    pushCurrent();
    if (estimateTokens(trimmed) <= tokenTarget) {
      current = trimmed;
      continue;
    }

    const lines = trimmed.split(/\n/);
    for (const line of lines) {
      const lineText = line.trim();
      if (!lineText) continue;
      const lineCandidate = current ? `${current}\n${lineText}` : lineText;
      if (estimateTokens(lineCandidate) <= tokenTarget) {
        current = lineCandidate;
      } else {
        pushCurrent();
        current = lineText;
      }
    }
  }
  pushCurrent();
  return chunks;
}

export function buildBookContextSegmentsFromPages(
  pages: BookContextPageInput[],
  contextWindowTokens: number,
  inputTokenBudget?: number,
): BookContextSegment[] {
  const tokenTarget = resolveBookContextSectionTokenTarget(contextWindowTokens, inputTokenBudget);
  const segments: BookContextSegment[] = [];
  let sectionIndex = 1;
  let currentParts: string[] = [];
  let currentTokens = 0;
  let currentChapterId: string | undefined;
  let currentTitle: string | undefined;
  let pageStart: number | undefined;
  let pageEnd: number | undefined;

  const nextSectionId = () => `section_${String(sectionIndex++).padStart(4, '0')}`;

  const flush = () => {
    const body = currentParts.join('\n\n').trim();
    if (!body) return;
    const segmentBase = {
      sectionId: nextSectionId(),
      ...(currentChapterId && { chapterId: currentChapterId }),
      ...(currentTitle && { title: currentTitle }),
      ...(pageStart !== undefined && { pageStart }),
      ...(pageEnd !== undefined && { pageEnd }),
    };
    segments.push({
      ...segmentBase,
      sourceText: formatSectionText(segmentBase, body),
    });
    currentParts = [];
    currentTokens = 0;
    currentChapterId = undefined;
    currentTitle = undefined;
    pageStart = undefined;
    pageEnd = undefined;
  };

  const addPart = (part: string, page: BookContextPageInput, forceNewSection = false) => {
    const chapterId = page.chapter?.id;
    const chapterChanged = currentChapterId && chapterId && chapterId !== currentChapterId;
    const partTokens = estimateTokens(part);
    if (forceNewSection || chapterChanged || (currentParts.length > 0 && currentTokens + partTokens > tokenTarget)) {
      flush();
    }

    currentParts.push(part);
    currentTokens += partTokens;
    currentChapterId = currentChapterId ?? chapterId;
    currentTitle = currentTitle ?? page.chapter?.title ?? undefined;
    if (page.pageNumber !== null && page.pageNumber !== undefined) {
      pageStart = pageStart ?? page.pageNumber;
      pageEnd = page.pageNumber;
    }
  };

  for (const page of pages) {
    const text = page.sourceText?.trim();
    if (!text) continue;
    const fullPage = `${pageHeader(page)}\n${text}`;
    if (estimateTokens(fullPage) <= tokenTarget) {
      addPart(fullPage, page);
      continue;
    }

    for (const part of splitOversizedText(text, tokenTarget)) {
      addPart(`${pageHeader(page)}\n${part}`, page, true);
    }
  }

  flush();
  return segments;
}
