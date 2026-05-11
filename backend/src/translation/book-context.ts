export type BookContextEntryType = 'character' | 'place' | 'org' | 'term';

export interface BookContextEntry {
  source: string;
  target: string;
  type: BookContextEntryType;
  aliases: string[];
  description?: string;
}

export interface ForbiddenTranslation {
  source: string;
  forbidden: string[];
  prefer?: string;
}

export interface StyleGuide {
  register?: string;
  tone?: string;
  dialogue?: string;
  terminology?: string;
  punctuation?: string;
}

export interface ChapterSummary {
  chapterId: string;
  title?: string;
  summary: string;
}

export interface SectionSummary {
  id: string;
  chapterId?: string;
  title?: string;
  pageStart?: number;
  pageEnd?: number;
  summary: string;
}

export interface BookContextPackage {
  version: 2;
  entries: BookContextEntry[];
  doNotTranslate: string[];
  forbiddenTranslations: ForbiddenTranslation[];
  styleGuide: StyleGuide;
  chapterSummaries: ChapterSummary[];
  sections: SectionSummary[];
}

export interface SelectedBookContext {
  entries: BookContextEntry[];
  doNotTranslate: string[];
  forbiddenTranslations: ForbiddenTranslation[];
  styleGuide: StyleGuide;
  contextSummary?: { title?: string; summary: string };
}

const MAX_STRING_CHARS = 500;
const MAX_TERM_CHARS = 120;
const MAX_ENTRIES = 300;
const MAX_AliASES_PER_ENTRY = 8;
const STYLE_KEYS: Array<keyof StyleGuide> = ['register', 'tone', 'dialogue', 'terminology', 'punctuation'];

export const EMPTY_BOOK_CONTEXT: BookContextPackage = {
  version: 2,
  entries: [],
  doNotTranslate: [],
  forbiddenTranslations: [],
  styleGuide: {},
  chapterSummaries: [],
  sections: [],
};

function cleanString(value: unknown, maxChars = MAX_STRING_CHARS): string {
  return typeof value === 'string' ? value.replace(/\s+/g, ' ').trim().slice(0, maxChars) : '';
}

function cleanMultiline(value: unknown, maxChars = MAX_STRING_CHARS): string {
  return typeof value === 'string' ? value.trim().replace(/\n{3,}/g, '\n\n').slice(0, maxChars) : '';
}

function normalizeType(value: unknown): BookContextEntryType {
  return value === 'character' || value === 'place' || value === 'org' || value === 'term'
    ? value
    : 'term';
}

function uniqueStrings(values: unknown[], max = 100): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const value of values) {
    const cleaned = cleanString(value, MAX_TERM_CHARS);
    if (!cleaned || seen.has(cleaned)) continue;
    seen.add(cleaned);
    result.push(cleaned);
    if (result.length >= max) break;
  }
  return result;
}

function normalizeEntry(value: unknown): BookContextEntry | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const row = value as Record<string, unknown>;
  if (
    (typeof row.source === 'string' && row.source.trim().length > MAX_TERM_CHARS) ||
    (typeof row.target === 'string' && row.target.trim().length > MAX_TERM_CHARS)
  ) {
    return null;
  }
  const source = cleanString(row.source, MAX_TERM_CHARS);
  const target = cleanString(row.target, MAX_TERM_CHARS);
  if (!source || !target) return null;
  const aliases = Array.isArray(row.aliases)
    ? uniqueStrings(row.aliases, MAX_AliASES_PER_ENTRY).filter((alias) => alias !== source)
    : [];
  const description = cleanString(row.description, 240);
  return {
    source,
    target,
    type: normalizeType(row.type),
    aliases,
    ...(description && { description }),
  };
}

function normalizeForbidden(value: unknown): ForbiddenTranslation | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const row = value as Record<string, unknown>;
  const source = cleanString(row.source, MAX_TERM_CHARS);
  const forbidden = Array.isArray(row.forbidden) ? uniqueStrings(row.forbidden, 12) : [];
  if (!source || forbidden.length === 0) return null;
  const prefer = cleanString(row.prefer, MAX_TERM_CHARS);
  return { source, forbidden, ...(prefer && { prefer }) };
}

function normalizeStyleGuide(value: unknown): StyleGuide {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
  const row = value as Record<string, unknown>;
  const styleGuide: StyleGuide = {};
  for (const key of STYLE_KEYS) {
    const cleaned = cleanString(row[key], 240);
    if (cleaned) styleGuide[key] = cleaned;
  }
  return styleGuide;
}

function normalizeChapterSummary(value: unknown): ChapterSummary | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const row = value as Record<string, unknown>;
  const chapterId = cleanString(row.chapterId, 120);
  const summary = cleanMultiline(row.summary, 500);
  if (!chapterId || !summary) return null;
  const title = cleanString(row.title, 160);
  return { chapterId, ...(title && { title }), summary };
}

function normalizePositiveInteger(value: unknown): number | undefined {
  const num = Number(value);
  if (!Number.isFinite(num) || num <= 0) return undefined;
  return Math.floor(num);
}

function normalizeSectionSummary(value: unknown): SectionSummary | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const row = value as Record<string, unknown>;
  const id = cleanString(row.id, 120);
  const summary = cleanMultiline(row.summary, 500);
  if (!id || !summary) return null;
  const chapterId = cleanString(row.chapterId, 120);
  const title = cleanString(row.title, 160);
  const pageStart = normalizePositiveInteger(row.pageStart);
  const pageEnd = normalizePositiveInteger(row.pageEnd);
  return {
    id,
    ...(chapterId && { chapterId }),
    ...(title && { title }),
    ...(pageStart !== undefined && { pageStart }),
    ...(pageEnd !== undefined && { pageEnd }),
    summary,
  };
}

function fromEntries(entries: BookContextEntry[]): BookContextPackage {
  const seen = new Set<string>();
  const deduped: BookContextEntry[] = [];
  for (const entry of entries) {
    if (seen.has(entry.source)) continue;
    seen.add(entry.source);
    deduped.push(entry);
    if (deduped.length >= MAX_ENTRIES) break;
  }
  return { ...EMPTY_BOOK_CONTEXT, entries: deduped };
}

export function normalizeBookContextPackage(value: unknown): BookContextPackage {
  if (!value) return { ...EMPTY_BOOK_CONTEXT, entries: [] };

  if (Array.isArray(value)) {
    return fromEntries(value.map(normalizeEntry).filter((entry): entry is BookContextEntry => Boolean(entry)));
  }

  if (typeof value !== 'object') return { ...EMPTY_BOOK_CONTEXT, entries: [] };
  const row = value as Record<string, unknown>;

  if (row.version === 2 || Array.isArray(row.entries)) {
    const entries = Array.isArray(row.entries)
      ? row.entries.map(normalizeEntry).filter((entry): entry is BookContextEntry => Boolean(entry))
      : [];
    const doNotTranslate = Array.isArray(row.doNotTranslate) ? uniqueStrings(row.doNotTranslate, 100) : [];
    const forbiddenTranslations = Array.isArray(row.forbiddenTranslations)
      ? row.forbiddenTranslations
          .map(normalizeForbidden)
          .filter((item): item is ForbiddenTranslation => Boolean(item))
          .slice(0, 100)
      : [];
    const chapterSummaries = Array.isArray(row.chapterSummaries)
      ? row.chapterSummaries
          .map(normalizeChapterSummary)
          .filter((item): item is ChapterSummary => Boolean(item))
          .slice(0, 200)
      : [];
    const sections = Array.isArray(row.sections)
      ? row.sections
          .map(normalizeSectionSummary)
          .filter((item): item is SectionSummary => Boolean(item))
          .slice(0, 500)
      : [];
    return {
      version: 2,
      entries: fromEntries(entries).entries,
      doNotTranslate,
      forbiddenTranslations,
      styleGuide: normalizeStyleGuide(row.styleGuide),
      chapterSummaries,
      sections,
    };
  }

  const legacyEntries = Object.entries(row)
    .map(([source, target]) => normalizeEntry({ source, target, type: 'term', aliases: [] }))
    .filter((entry): entry is BookContextEntry => Boolean(entry));
  return fromEntries(legacyEntries);
}

export function toLegacyGlossaryMap(value: unknown): Record<string, string> {
  const context = normalizeBookContextPackage(value);
  return Object.fromEntries(context.entries.map((entry) => [entry.source, entry.target]));
}

export function mergeBookContextPackages(existingRaw: unknown, extractedRaw: unknown): BookContextPackage {
  const existing = normalizeBookContextPackage(existingRaw);
  const extracted = normalizeBookContextPackage(extractedRaw);
  const entriesBySource = new Map<string, BookContextEntry>();
  const conflictForbidden: ForbiddenTranslation[] = [];

  for (const entry of existing.entries) {
    entriesBySource.set(entry.source, entry);
  }
  for (const entry of extracted.entries) {
    const current = entriesBySource.get(entry.source);
    if (!current) {
      entriesBySource.set(entry.source, entry);
      continue;
    }
    if (entry.target !== current.target) {
      conflictForbidden.push({
        source: current.source,
        forbidden: [entry.target],
        prefer: current.target,
      });
    }
    entriesBySource.set(entry.source, {
      ...current,
      aliases: uniqueStrings([...current.aliases, ...entry.aliases], MAX_AliASES_PER_ENTRY),
      description: current.description ?? entry.description,
    });
  }

  const styleGuide: StyleGuide = {};
  for (const key of STYLE_KEYS) {
    styleGuide[key] = existing.styleGuide[key] ?? extracted.styleGuide[key];
  }

  const summaries = new Map<string, ChapterSummary>();
  for (const summary of existing.chapterSummaries) summaries.set(summary.chapterId, summary);
  for (const summary of extracted.chapterSummaries) summaries.set(summary.chapterId, summary);

  const sections = new Map<string, SectionSummary>();
  for (const section of existing.sections) sections.set(section.id, section);
  for (const section of extracted.sections) sections.set(section.id, section);

  return {
    version: 2,
    entries: Array.from(entriesBySource.values()).slice(0, MAX_ENTRIES),
    doNotTranslate: uniqueStrings([...existing.doNotTranslate, ...extracted.doNotTranslate], 100),
    forbiddenTranslations: mergeForbidden(
      existing.forbiddenTranslations,
      [...extracted.forbiddenTranslations, ...conflictForbidden],
    ),
    styleGuide,
    chapterSummaries: Array.from(summaries.values()).slice(0, 200),
    sections: Array.from(sections.values()).slice(0, 500),
  };
}

function mergeForbidden(
  existing: ForbiddenTranslation[],
  extracted: ForbiddenTranslation[],
): ForbiddenTranslation[] {
  const bySource = new Map<string, ForbiddenTranslation>();
  const upsert = (item: ForbiddenTranslation, preferExisting: boolean) => {
    const current = bySource.get(item.source);
    bySource.set(item.source, {
      source: item.source,
      forbidden: uniqueStrings([...(current?.forbidden ?? []), ...item.forbidden], 12),
      prefer: preferExisting ? (item.prefer ?? current?.prefer) : (current?.prefer ?? item.prefer),
    });
  };

  for (const item of extracted) upsert(item, false);
  for (const item of existing) {
    upsert(item, true);
  }
  return Array.from(bySource.values()).slice(0, 100);
}

function textMatches(text: string, term: string): boolean {
  if (!term) return false;
  if (text.includes(term)) return true;
  if (term.includes(' ')) {
    return term.split(/\s+/).some((word) => word.length >= 3 && text.includes(word));
  }
  return false;
}

export function selectContextForText(
  value: unknown,
  text: string,
  chapterId?: string,
  options: { entryLimit?: number; pageNumber?: number } = {},
): SelectedBookContext {
  const context = normalizeBookContextPackage(value);
  const entryLimit = options.entryLimit ?? 20;
  const entries = context.entries
    .filter((entry) =>
      textMatches(text, entry.source) || entry.aliases.some((alias) => textMatches(text, alias)),
    )
    .slice(0, entryLimit);
  const doNotTranslate = context.doNotTranslate
    .filter((term) => textMatches(text, term))
    .slice(0, 30);
  const forbiddenTranslations = context.forbiddenTranslations
    .filter((item) => textMatches(text, item.source))
    .slice(0, 20);
  const sectionSummary = options.pageNumber !== undefined
    ? context.sections.find((section) =>
        section.pageStart !== undefined
        && section.pageEnd !== undefined
        && options.pageNumber !== undefined
        && options.pageNumber >= section.pageStart
        && options.pageNumber <= section.pageEnd,
      )
    : undefined;
  const chapterSummary = !sectionSummary && chapterId
    ? context.chapterSummaries.find((summary) => summary.chapterId === chapterId)
    : undefined;
  return {
    entries,
    doNotTranslate,
    forbiddenTranslations,
    styleGuide: context.styleGuide,
    ...(sectionSummary && { contextSummary: { title: sectionSummary.title, summary: sectionSummary.summary } }),
    ...(chapterSummary && { contextSummary: { title: chapterSummary.title, summary: chapterSummary.summary } }),
  };
}

export function countBookContextEntries(value: unknown): number {
  return normalizeBookContextPackage(value).entries.length;
}
