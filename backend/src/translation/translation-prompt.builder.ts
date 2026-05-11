import {
  GLOSSARY_EXTRACTION_PROMPT,
  TRANSLATION_PROMPT,
  REVIEW_PROMPT,
  POLISH_PROMPT,
} from './prompts';
import {
  type BookContextPackage,
  type SelectedBookContext,
  countBookContextEntries,
  mergeBookContextPackages,
  normalizeBookContextPackage,
  selectContextForText,
  toLegacyGlossaryMap,
} from './book-context';

export {
  type BookContextPackage,
  countBookContextEntries,
  mergeBookContextPackages,
  normalizeBookContextPackage,
  selectContextForText,
  toLegacyGlossaryMap,
};


export const CONTEXT_TAIL_CHARS = 350;


const SENTENCE_ENDINGS = ['\n\n', '\n', '。', '！', '？', '. ', '! ', '? ', '…'];


export function trimToSentenceBoundary(text: string, maxChars: number): string {
  if (text.length <= maxChars) return text.trim();
  const searchStart = Math.max(0, text.length - maxChars * 2);
  const window = text.slice(searchStart);
  const cutAt = window.length - maxChars;
  for (const sep of SENTENCE_ENDINGS) {
    const idx = window.indexOf(sep, cutAt);
    if (idx !== -1 && idx < window.length - 10) {
      return window.slice(idx + sep.length).trim();
    }
  }
  return text.slice(-maxChars).trim();
}

const STYLE_PROMPT_MAX_CHARS = 1000;


export const MAX_GLOSSARY_ENTRIES = 300;


const MAX_INJECT_PER_CHUNK = 20;

const MAX_GLOSSARY_TERM_CHARS = 120;
const MAX_ALLOWED_FOREIGN_TERMS = 30;


const LANGUAGE_OVERRIDE_PATTERNS = [
  /(翻译|译成|输出|回答).*(中文|英文|日文|韩文|法文|德文|俄文|西班牙文|阿拉伯文)/i,
  /\b(translate|output|respond|answer)\b.*\b(chinese|english|japanese|korean|french|german|russian|spanish|arabic)\b/i,
  /(source|target)\s*language/i,
  /(原文|目标语言|源语言)/,
];

export function sanitizeStylePrompt(raw?: string): string {
  if (!raw) return '';
  return raw
    .slice(0, STYLE_PROMPT_MAX_CHARS)
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .filter((line) => !LANGUAGE_OVERRIDE_PATTERNS.some((re) => re.test(line)))
    .join('\n');
}

function renderTerminology(entries: SelectedBookContext['entries']): string {
  return entries
    .map((entry) => {
      const aliases = entry.aliases.length > 0 ? `; aliases: ${entry.aliases.join(', ')}` : '';
      const description = entry.description ? `; ${entry.description}` : '';
      return `- ${entry.source} → ${entry.target} (${entry.type}${aliases}${description})`;
    })
    .join('\n');
}

function renderForbidden(items: SelectedBookContext['forbiddenTranslations']): string {
  return items
    .map((item) => {
      const prefer = item.prefer ? `; prefer: ${item.prefer}` : '';
      return `- ${item.source}: do not use ${item.forbidden.join(', ')}${prefer}`;
    })
    .join('\n');
}

function pushSelectedContextSections(
  lines: string[],
  selected: SelectedBookContext,
  headers: {
    terminologyHeader: string;
    doNotTranslateHeader: string;
    forbiddenTranslationsHeader: string;
    chapterSummaryHeader: string;
  },
): void {
  if (selected.entries.length > 0) {
    lines.push(headers.terminologyHeader, renderTerminology(selected.entries));
  }
  if (selected.doNotTranslate.length > 0) {
    lines.push(headers.doNotTranslateHeader, selected.doNotTranslate.map((term) => `- ${term}`).join('\n'));
  }
  if (selected.forbiddenTranslations.length > 0) {
    lines.push(headers.forbiddenTranslationsHeader, renderForbidden(selected.forbiddenTranslations));
  }
  if (selected.contextSummary) {
    const title = selected.contextSummary.title ? `${selected.contextSummary.title}: ` : '';
    lines.push(headers.chapterSummaryHeader, `${title}${selected.contextSummary.summary}`);
  }
}


export function buildSystemPrompt(
  sourceLang: string,
  targetLang: string,
  _stylePrompt?: string,
  glossary?: unknown,
  chunkText?: string,
  chapterId?: string,
  pageNumber?: number,
): string {
  const lines = [
    TRANSLATION_PROMPT.system.intro(sourceLang, targetLang),
    TRANSLATION_PROMPT.system.languagePriority(targetLang),
    ...TRANSLATION_PROMPT.system.rules,
  ];

  if (glossary && chunkText) {
    pushSelectedContextSections(
      lines,
      selectContextForText(glossary, chunkText, chapterId, { entryLimit: MAX_INJECT_PER_CHUNK, pageNumber }),
      {
        terminologyHeader: TRANSLATION_PROMPT.system.terminologyHeader,
        doNotTranslateHeader: TRANSLATION_PROMPT.system.doNotTranslateHeader,
        forbiddenTranslationsHeader: TRANSLATION_PROMPT.system.forbiddenTranslationsHeader,
        chapterSummaryHeader: TRANSLATION_PROMPT.system.chapterSummaryHeader,
      },
    );
  }

  return lines.join('\n');
}


export function buildUserPrompt(
  chunk: { text: string; contextTail: string },
  chapterTitle?: string,
): string {
  const parts: string[] = [];

  if (chapterTitle) {
    parts.push(TRANSLATION_PROMPT.user.chapter(chapterTitle));
  }

  if (chunk.contextTail) {
    parts.push(TRANSLATION_PROMPT.user.context(chunk.contextTail));
  }

  parts.push(TRANSLATION_PROMPT.user.translate(chunk.text));
  return parts.join('\n\n');
}

export function buildBookContextPrompt(
  chapterText: string,
  targetLang: string,
  existingGlossary: unknown,
): string {
  const existingKeys = Object.keys(toLegacyGlossaryMap(existingGlossary));
  return [
    GLOSSARY_EXTRACTION_PROMPT.bookContext.intro(targetLang),
    GLOSSARY_EXTRACTION_PROMPT.bookContext.analysisScope,
    '',
    GLOSSARY_EXTRACTION_PROMPT.bookContext.extractScope,
    ...GLOSSARY_EXTRACTION_PROMPT.bookContext.fields(targetLang),
    '',
    ...GLOSSARY_EXTRACTION_PROMPT.bookContext.rules,
    '',
    GLOSSARY_EXTRACTION_PROMPT.bookContext.existingGlossary(existingKeys),
    '',
    GLOSSARY_EXTRACTION_PROMPT.bookContext.returnFormat,
    '',
    GLOSSARY_EXTRACTION_PROMPT.bookContext.fullTextHeader,
    chapterText,
  ].join('\n');
}

export function buildReviewPrompt(
  sourceText: string,
  draftText: string,
  targetLang: string,
  glossary?: unknown,
  chapterId?: string,
  pageNumber?: number,
): { systemPrompt: string; userPrompt: string } {
  const selected = glossary
    ? selectContextForText(glossary, sourceText, chapterId, { entryLimit: 30, pageNumber })
    : selectContextForText(undefined, sourceText, chapterId, { entryLimit: 30 });
  const allowedForeignTerms = extractAllowedForeignTermsForReview(sourceText, glossary);
  const contextLines: string[] = [];
  pushSelectedContextSections(contextLines, selected, {
    terminologyHeader: REVIEW_PROMPT.glossaryHeader,
    doNotTranslateHeader: REVIEW_PROMPT.doNotTranslateHeader,
    forbiddenTranslationsHeader: REVIEW_PROMPT.forbiddenTranslationsHeader,
    chapterSummaryHeader: REVIEW_PROMPT.chapterSummaryHeader,
  });
  const allowedForeignTermsLines =
    allowedForeignTerms.length > 0
      ? [
          REVIEW_PROMPT.allowedForeignTermsHeader,
          ...allowedForeignTerms.map((term) => `- ${term}`),
        ].join('\n')
      : '';
  const systemPrompt = [
    REVIEW_PROMPT.systemIntro(targetLang),
    REVIEW_PROMPT.role,
    '',
    REVIEW_PROMPT.reviewClause.join('\n'),
    REVIEW_PROMPT.reviewOnlyGuard,
    '',
    ...REVIEW_PROMPT.rules,
    '- Do not rewrite acceptable translation just to make it sound different.',
    ...contextLines,
    allowedForeignTermsLines,
  ]
    .filter(Boolean)
    .join('\n');

  const userPrompt = [
    REVIEW_PROMPT.sourceHeader,
    sourceText,
    '',
    REVIEW_PROMPT.draftHeader,
    draftText,
    '',
    REVIEW_PROMPT.returnInstruction,
  ].join('\n');

  return { systemPrompt, userPrompt };
}

function extractAllowedForeignTermsForReview(
  sourceText: string,
  glossary?: unknown,
): string[] {
  const allow = new Set<string>();
  const add = (term: string) => {
    const normalized = term.trim();
    if (!normalized) return;
    if (normalized.length < 2 || normalized.length > 40) return;
    if (!/[A-Za-z]/.test(normalized)) return;
    allow.add(normalized);
  };


  if (glossary) {
    for (const entry of normalizeBookContextPackage(glossary).entries) {
      add(entry.source);
      for (const alias of entry.aliases) add(alias);
      for (const term of [entry.source, ...entry.aliases]) {
        for (const part of term.split(/[\s/,-]+/)) {
          add(part);
        }
      }
    }
    for (const term of normalizeBookContextPackage(glossary).doNotTranslate) add(term);
  }


  const sourceWords = sourceText.match(/\b[A-Za-z][A-Za-z0-9'’-]*\b/g) ?? [];
  for (const token of sourceWords) {
    if (/^[A-Z]{2,}$/.test(token)) {
      add(token);
      continue;
    }
    if (/^[A-Z][a-z]+(?:'[A-Za-z]+)?$/.test(token)) {
      add(token);
      continue;
    }
  }

  return Array.from(allow).slice(0, MAX_ALLOWED_FOREIGN_TERMS);
}

export function buildPolishPrompt(
  sourceText: string,
  draftText: string,
  targetLang: string,
  glossary?: unknown,
  stylePrompt?: string,
  chapterId?: string,
  pageNumber?: number,
): { systemPrompt: string; userPrompt: string } {
  const safeStyle = sanitizeStylePrompt(stylePrompt)
    || POLISH_PROMPT.defaultStylePreference;
  const selected = glossary
    ? selectContextForText(glossary, sourceText, chapterId, { entryLimit: 30, pageNumber })
    : selectContextForText(undefined, sourceText, chapterId, { entryLimit: 30 });
  const contextLines: string[] = [];
  pushSelectedContextSections(contextLines, selected, {
    terminologyHeader: POLISH_PROMPT.glossaryHeader,
    doNotTranslateHeader: POLISH_PROMPT.doNotTranslateHeader,
    forbiddenTranslationsHeader: POLISH_PROMPT.forbiddenTranslationsHeader,
    chapterSummaryHeader: POLISH_PROMPT.chapterSummaryHeader,
  });
  const styleLines = safeStyle
    ? `${POLISH_PROMPT.styleHeader}\n${safeStyle}`
    : '';

  const systemPrompt = [
    POLISH_PROMPT.systemIntro(targetLang),
    POLISH_PROMPT.role,
    '',
    POLISH_PROMPT.polishClause.join('\n'),
    '',
    ...POLISH_PROMPT.rules,
    ...contextLines,
    styleLines,
  ]
    .filter(Boolean)
    .join('\n');

  const userPrompt = [
    POLISH_PROMPT.sourceHeader,
    sourceText,
    '',
    POLISH_PROMPT.draftHeader,
    draftText,
    '',
    POLISH_PROMPT.returnInstruction,
  ].join('\n');

  return { systemPrompt, userPrompt };
}


export function buildGlossaryExtractionPrompt(
  sourceText: string,
  targetLang: string,
  existingGlossary: unknown,
): string {
  const existingKeys = Object.keys(toLegacyGlossaryMap(existingGlossary));
  const lines = [
    GLOSSARY_EXTRACTION_PROMPT.page.intro(targetLang),
    ...GLOSSARY_EXTRACTION_PROMPT.page.rules,
    GLOSSARY_EXTRACTION_PROMPT.page.alreadyKnown(existingKeys),
    ``,
    GLOSSARY_EXTRACTION_PROMPT.page.sourceHeader,
    sourceText,
  ];
  return lines.filter((l) => l !== undefined).join('\n');
}


export function buildGlossaryContinuationPrompt(
  sourceText: string,
  targetLang: string,
  alreadyExtracted: string[],
): string {
  return [
    GLOSSARY_EXTRACTION_PROMPT.continuation.intro(targetLang),
    ...GLOSSARY_EXTRACTION_PROMPT.continuation.rules,
    GLOSSARY_EXTRACTION_PROMPT.continuation.alreadyExtracted(alreadyExtracted),
    ``,
    GLOSSARY_EXTRACTION_PROMPT.continuation.sourceHeader,
    sourceText,
  ].filter((l) => l !== undefined).join('\n');
}

export function buildGlossaryReductionPrompt(
  packages: unknown[],
  targetLang: string,
): string {
  return [
    GLOSSARY_EXTRACTION_PROMPT.reduction.intro(targetLang),
    ...GLOSSARY_EXTRACTION_PROMPT.reduction.rules,
    '',
    GLOSSARY_EXTRACTION_PROMPT.reduction.packagesHeader,
    JSON.stringify(packages),
  ].join('\n');
}


export function isGlossaryResponseTruncated(raw: string): boolean {
  const t = raw.trim();
  const arrayOpen = t.indexOf('[');
  const objectOpen = t.indexOf('{');
  const starts = [arrayOpen, objectOpen].filter((idx) => idx >= 0);
  if (starts.length === 0) return false;
  const open = Math.min(...starts);
  const close = t[open] === '[' ? ']' : '}';
  return !t.slice(open).includes(close);
}


export function parseGlossaryResponsePartial(raw: string): Record<string, string> {
  const entries: Array<[string, string]> = [];
  const seen = new Set<string>();
  const objRe = /\{[^{}]{1,600}\}/g;
  let m: RegExpExecArray | null;
  while ((m = objRe.exec(raw)) !== null) {
    try {
      const row = JSON.parse(m[0]) as Record<string, unknown>;
      if (typeof row.source !== 'string' || typeof row.target !== 'string') continue;
      const source = sanitizeGlossaryTerm(row.source);
      const target = sanitizeGlossaryTerm(row.target);
      if (!source || !target || seen.has(source)) continue;
      if (source.length > MAX_GLOSSARY_TERM_CHARS || target.length > MAX_GLOSSARY_TERM_CHARS) continue;
      seen.add(source);
      entries.push([source, target]);
      if (entries.length >= MAX_GLOSSARY_ENTRIES) break;
    } catch {  }
  }
  return Object.fromEntries(entries);
}

function sanitizeGlossaryTerm(value: string): string {
  return value.replace(/\s+/g, ' ').trim();
}

function extractJson(raw: string): unknown | null {
  const trimmed = raw.trim();
  const objectStart = trimmed.indexOf('{');
  const arrayStart = trimmed.indexOf('[');
  const starts: number[] = [objectStart, arrayStart].filter((idx) => idx >= 0);
  if (starts.length === 0) return null;
  const start = Math.min(...starts);
  const open = trimmed[start];
  const close = open === '{' ? '}' : ']';
  const end = trimmed.lastIndexOf(close);
  if (end < start) return null;
  return JSON.parse(trimmed.slice(start, end + 1));
}

export function parseGlossaryResponse(raw: string): BookContextPackage {
  try {
    return normalizeBookContextPackage(extractJson(raw));
  } catch {
    return normalizeBookContextPackage(undefined);
  }
}
