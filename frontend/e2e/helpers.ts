import { expect, type APIRequestContext } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import * as path from 'node:path';

export const API = 'http://localhost:3001';

export function e2eTitle(prefix: string, label: string) {
  return `${prefix}-${label}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

export async function cleanupBooksByPrefix(request: APIRequestContext, prefix: string) {
  const res = await request.get(`${API}/books`);
  expect(res.status()).toBe(200);
  const books = (await res.json()) as Array<{ id: string; title: string }>;
  await Promise.all(
    books
      .filter((book) => book.title.startsWith(prefix))
      .map((book) => request.delete(`${API}/books/${book.id}`)),
  );
}

export async function createBook(
  request: APIRequestContext,
  title: string,
  sourceLang = 'en',
  targetLang = 'zh',
) {
  const res = await request.post(`${API}/books`, {
    data: { title, sourceLang, targetLang },
  });
  expect(res.status()).toBe(201);
  return res.json() as Promise<{ id: string; title: string }>;
}

export async function createChapter(
  request: APIRequestContext,
  bookId: string,
  chapterNumber = 1,
  title = `Chapter ${chapterNumber}`,
) {
  const res = await request.post(`${API}/chapters`, {
    data: { bookId, chapterNumber, title },
  });
  expect(res.status()).toBe(201);
  return res.json() as Promise<{ id: string }>;
}

export async function uploadTxtPages(
  request: APIRequestContext,
  bookId: string,
  chapterId: string,
  pageCount = 2,
) {
  const paragraphs = Array.from({ length: pageCount }, (_, index) =>
    Array.from(
      { length: 900 },
      () => `Page ${index + 1} sentence`,
    ).join(' '),
  );
  const res = await request.post(`${API}/pages/upload/txt`, {
    multipart: {
      file: {
        name: 'fixture.txt',
        mimeType: 'text/plain',
        buffer: Buffer.from(paragraphs.join('\n\n'), 'utf8'),
      },
      bookId,
      chapterId,
    },
  });
  expect(res.status()).toBe(201);

  const pagesRes = await request.get(`${API}/pages/chapter/${chapterId}`);
  expect(pagesRes.status()).toBe(200);
  return pagesRes.json() as Promise<Array<{ id: string; pageNumber: number }>>;
}

function sqlQuote(value: string) {
  return `'${value.replace(/'/g, "''")}'`;
}

export function markBookTranslated(bookId: string, chapterId: string) {
  const sql = `
    update "Page"
       set "translationStatus" = 'completed',
           "targetText" = 'Translated fixture page ' || "pageNumber",
           "updatedAt" = now()
     where "bookId" = ${sqlQuote(bookId)};
    update "Chapter"
       set "status" = 'completed',
           "translationProgress" = 100,
           "updatedAt" = now()
     where "id" = ${sqlQuote(chapterId)};
    update "Book"
       set "status" = 'completed',
           "updatedAt" = now()
     where "id" = ${sqlQuote(bookId)};
  `;
  execFileSync(
    'docker',
    ['compose', 'exec', '-T', 'postgres', 'psql', '-U', 'bookllm', '-d', 'bookllm', '-v', 'ON_ERROR_STOP=1', '-c', sql],
    { cwd: path.resolve(__dirname, '../..') },
  );
}

export async function createBookWithPages(
  request: APIRequestContext,
  prefix: string,
  label: string,
  pageCount = 2,
) {
  const book = await createBook(request, e2eTitle(prefix, label));
  const chapter = await createChapter(request, book.id);
  const pages = await uploadTxtPages(request, book.id, chapter.id, pageCount);
  return { book, chapter, pages };
}

export async function createTranslatedBook(
  request: APIRequestContext,
  prefix: string,
  label: string,
  pageCount = 2,
) {
  const fixture = await createBookWithPages(request, prefix, label, pageCount);
  markBookTranslated(fixture.book.id, fixture.chapter.id);
  return fixture;
}
