import * as fs from 'fs';
import * as path from 'path';
import { expect, test, type APIRequestContext } from '@playwright/test';

const API = 'http://localhost:3001';
const TEST_FILES = path.resolve(__dirname, '../../test-files');
const PREFIX = `E2E-BASELINE-${Date.now()}`;

function title(name: string) {
  return `${PREFIX}-${name}`;
}

async function createBook(
  request: APIRequestContext,
  name: string,
  sourceLang = 'en',
  targetLang = 'zh',
) {
  const res = await request.post(`${API}/books`, {
    data: { title: title(name), sourceLang, targetLang },
  });
  expect(res.status()).toBe(201);
  return res.json() as Promise<{ id: string; title: string }>;
}

async function createChapter(request: APIRequestContext, bookId: string, chapterTitle = 'Chapter 1') {
  const res = await request.post(`${API}/chapters`, {
    data: { bookId, chapterNumber: 1, title: chapterTitle },
  });
  expect(res.status()).toBe(201);
  return res.json() as Promise<{ id: string }>;
}

async function cleanupBooks(request: APIRequestContext) {
  const res = await request.get(`${API}/books`);
  expect(res.status()).toBe(200);
  const books = await res.json() as Array<{ id: string; title: string }>;
  await Promise.all(
    books
      .filter((b) => b.title.startsWith(PREFIX))
      .map((b) => request.delete(`${API}/books/${b.id}`)),
  );
}

async function startAndWaitCompleted(
  request: APIRequestContext,
  bookId: string,
  timeoutMs = 240_000,
) {
  const startRes = await request.post(`${API}/chapters/book/${bookId}/translate`);
  expect(startRes.status()).toBe(202);
  const body = await startRes.json() as { enqueuedPages: number };
  expect(body.enqueuedPages).toBeGreaterThan(0);

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const chaptersRes = await request.get(`${API}/chapters/book/${bookId}`);
    expect(chaptersRes.status()).toBe(200);
    const chapters = await chaptersRes.json() as Array<{
      status: string;
      translationProgress: number;
      id?: string;
    }>;
    const failed = chapters.find((c) => c.status === 'failed');
    if (failed) {
      throw new Error(
        `Translation failed for book ${bookId}, chapter ${failed.id ?? 'unknown'} at ${failed.translationProgress}%`,
      );
    }
    if (chapters.length > 0 && chapters.every((c) => c.status === 'completed' && c.translationProgress === 100)) {
      return;
    }
    await new Promise((r) => setTimeout(r, 1500));
  }

  throw new Error(`Translation timeout for book ${bookId}`);
}

test.describe('Core baseline: txt/pdf+image/epub+image', () => {
  test.beforeEach(async ({ request }) => {
    await cleanupBooks(request);
  });

  test('TXT: upload + translate completes with target text', async ({ request }) => {
    const book = await createBook(request, 'TXT');
    const chapter = await createChapter(request, book.id);
    const txt = fs.readFileSync(path.join(TEST_FILES, 'llm-test.txt'));

    const uploadRes = await request.post(`${API}/pages/upload/txt`, {
      multipart: {
        file: { name: 'llm-test.txt', mimeType: 'text/plain', buffer: txt },
        bookId: book.id,
        chapterId: chapter.id,
      },
    });
    expect(uploadRes.status()).toBe(201);

    await startAndWaitCompleted(request, book.id);

    const pagesRes = await request.get(`${API}/pages/chapter/${chapter.id}`);
    expect(pagesRes.status()).toBe(200);
    const pages = await pagesRes.json() as Array<{ translationStatus: string; targetText: string | null }>;
    expect(pages.length).toBeGreaterThan(0);
    expect(pages.every((p) => p.translationStatus === 'completed')).toBe(true);
    expect(pages.some((p) => (p.targetText ?? '').trim().length > 0)).toBe(true);
  });

  test('EPUB+image: marker preserved after translation and image asset is readable', async ({ request }) => {
    const book = await createBook(request, 'EPUB-IMG');
    const chapter = await createChapter(request, book.id);
    const epub = fs.readFileSync(path.join(TEST_FILES, 'image-test.epub'));

    const uploadRes = await request.post(`${API}/pages/upload/epub`, {
      multipart: {
        file: { name: 'image-test.epub', mimeType: 'application/epub+zip', buffer: epub },
        bookId: book.id,
        chapterId: chapter.id,
      },
    });
    expect(uploadRes.status()).toBe(201);

    const sourcePagesRes = await request.get(`${API}/pages/chapter/${chapter.id}`);
    expect(sourcePagesRes.status()).toBe(200);
    const sourcePages = await sourcePagesRes.json() as Array<{ sourceText: string | null }>;
    const withMarker = sourcePages.find((p) => p.sourceText?.includes('[[OB_IMAGE:'));
    expect(withMarker).toBeTruthy();
    const markerMatch = withMarker?.sourceText?.match(/\[\[OB_IMAGE:([^\]|]+)(?:\|[^\]]*)?\]\]/);
    expect(markerMatch?.[1]).toBeTruthy();

    const assetRes = await request.get(
      `${API}/books/${book.id}/image-asset?path=${encodeURIComponent(markerMatch![1])}`,
    );
    expect(assetRes.status()).toBe(200);
    expect(assetRes.headers()['content-type']).toContain('image/');
    const imageBytes = await assetRes.body();
    expect(imageBytes.length).toBeGreaterThan(0);

    await startAndWaitCompleted(request, book.id);

    const translatedPagesRes = await request.get(`${API}/pages/chapter/${chapter.id}`);
    const translatedPages = await translatedPagesRes.json() as Array<{ targetText: string | null }>;
    expect(translatedPages.some((p) => (p.targetText ?? '').includes('[[OB_IMAGE:'))).toBe(true);
  });

  test('PDF+image: marker preserved after translation and image asset is readable', async ({ request }) => {
    const book = await createBook(request, 'PDF-IMG');
    const chapter = await createChapter(request, book.id);
    const pdf = fs.readFileSync(path.join(TEST_FILES, 'image-test.pdf'));

    const uploadRes = await request.post(`${API}/pages/upload/pdf`, {
      multipart: {
        file: { name: 'image-test.pdf', mimeType: 'application/pdf', buffer: pdf },
        bookId: book.id,
        chapterId: chapter.id,
        language: 'auto',
      },
    });
    expect(uploadRes.status()).toBe(201);

    const sourcePagesRes = await request.get(`${API}/pages/chapter/${chapter.id}`);
    expect(sourcePagesRes.status()).toBe(200);
    const sourcePages = await sourcePagesRes.json() as Array<{ sourceText: string | null }>;
    const withMarker = sourcePages.find((p) => p.sourceText?.includes('[[OB_IMAGE:'));
    expect(withMarker).toBeTruthy();
    const markerMatch = withMarker?.sourceText?.match(/\[\[OB_IMAGE:([^\]|]+)(?:\|[^\]]*)?\]\]/);
    expect(markerMatch?.[1]).toBeTruthy();

    const assetRes = await request.get(
      `${API}/books/${book.id}/image-asset?path=${encodeURIComponent(markerMatch![1])}`,
    );
    expect(assetRes.status()).toBe(200);
    expect(assetRes.headers()['content-type']).toContain('image/');
    const imageBytes = await assetRes.body();
    expect(imageBytes.length).toBeGreaterThan(0);

    await startAndWaitCompleted(request, book.id);

    const translatedPagesRes = await request.get(`${API}/pages/chapter/${chapter.id}`);
    const translatedPages = await translatedPagesRes.json() as Array<{ targetText: string | null }>;
    expect(translatedPages.some((p) => (p.targetText ?? '').includes('[[OB_IMAGE:'))).toBe(true);
  });
});
