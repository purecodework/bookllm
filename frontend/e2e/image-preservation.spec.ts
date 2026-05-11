import * as fs from 'fs';
import * as path from 'path';
import { expect, test, type APIRequestContext } from '@playwright/test';

const API = 'http://localhost:3001';
const TEST_FILES = path.resolve(__dirname, '../../test-files');

function uid(label: string) {
  return `E2E-IMG-${label}-${Date.now()}`;
}

async function createBook(
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

async function cleanupE2EBooks(request: APIRequestContext) {
  const res = await request.get(`${API}/books`);
  const books: { id: string; title: string }[] = await res.json();
  await Promise.all(
    books.filter((b) => b.title.startsWith('E2E-IMG-')).map((b) => request.delete(`${API}/books/${b.id}`)),
  );
}

async function expectBookTranslateAccepted(
  request: APIRequestContext,
  bookId: string,
) {
  const res = await request.post(`${API}/chapters/book/${bookId}/translate`);
  const status = res.status();
  expect(status).toBe(202);
}

test.describe('Image preservation core logic', () => {
  test.beforeEach(async ({ request }) => {
    await cleanupE2EBooks(request);
  });

  test('EPUB upload stores image marker and serves image asset bytes', async ({ request }) => {
    const book = await createBook(request, uid('epub-upload'));
    const chapterRes = await request.post(`${API}/chapters`, {
      data: { bookId: book.id, chapterNumber: 1, title: 'Chapter 1' },
    });
    expect(chapterRes.status()).toBe(201);
    const chapter = await chapterRes.json() as { id: string };

    const epubBuffer = fs.readFileSync(path.join(TEST_FILES, 'image-test.epub'));
    const uploadRes = await request.post(`${API}/pages/upload/epub`, {
      multipart: {
        file: { name: 'image-test.epub', mimeType: 'application/epub+zip', buffer: epubBuffer },
        bookId: book.id,
        chapterId: chapter.id,
      },
    });
    expect(uploadRes.status()).toBe(201);

    const pagesRes = await request.get(`${API}/pages/chapter/${chapter.id}`);
    expect(pagesRes.status()).toBe(200);
    const pages: Array<{ sourceText: string | null }> = await pagesRes.json();
    expect(pages.length).toBeGreaterThan(0);

    const withMarker = pages.find((p) => p.sourceText?.includes('[[OB_IMAGE:'));
    expect(withMarker).toBeTruthy();

    const markerMatch = withMarker?.sourceText?.match(/\[\[OB_IMAGE:([^\]|]+)(?:\|[^\]]*)?\]\]/);
    expect(markerMatch?.[1]).toBeTruthy();

    const imageRes = await request.get(
      `${API}/books/${book.id}/image-asset?path=${encodeURIComponent(markerMatch![1])}`,
    );
    expect(imageRes.status()).toBe(200);
    expect(imageRes.headers()['content-type']).toContain('image/');
    const imageBytes = await imageRes.body();
    expect(imageBytes.length).toBeGreaterThan(0);

    await expectBookTranslateAccepted(request, book.id);

    await request.delete(`${API}/books/${book.id}`);
  });

  test('PDF upload stores image marker and serves image asset bytes', async ({ request }) => {
    const book = await createBook(request, uid('pdf-upload'));
    const chapterRes = await request.post(`${API}/chapters`, {
      data: { bookId: book.id, chapterNumber: 1, title: 'Chapter 1' },
    });
    expect(chapterRes.status()).toBe(201);
    const chapter = await chapterRes.json() as { id: string };

    const pdfBuffer = fs.readFileSync(path.join(TEST_FILES, 'image-test.pdf'));
    const uploadRes = await request.post(`${API}/pages/upload/pdf`, {
      multipart: {
        file: { name: 'image-test.pdf', mimeType: 'application/pdf', buffer: pdfBuffer },
        bookId: book.id,
        chapterId: chapter.id,
        language: 'auto',
      },
    });
    expect(uploadRes.status()).toBe(201);

    const pagesRes = await request.get(`${API}/pages/chapter/${chapter.id}`);
    expect(pagesRes.status()).toBe(200);
    const pages: Array<{ sourceText: string | null }> = await pagesRes.json();
    expect(pages.length).toBeGreaterThan(0);

    const withMarker = pages.find((p) => p.sourceText?.includes('[[OB_IMAGE:'));
    expect(withMarker).toBeTruthy();
    const markerMatch = withMarker?.sourceText?.match(/\[\[OB_IMAGE:([^\]|]+)(?:\|[^\]]*)?\]\]/);
    expect(markerMatch?.[1]).toBeTruthy();

    const imageRes = await request.get(
      `${API}/books/${book.id}/image-asset?path=${encodeURIComponent(markerMatch![1])}`,
    );
    expect(imageRes.status()).toBe(200);
    expect(imageRes.headers()['content-type']).toContain('image/');
    const imageBytes = await imageRes.body();
    expect(imageBytes.length).toBeGreaterThan(0);

    await expectBookTranslateAccepted(request, book.id);

    await request.delete(`${API}/books/${book.id}`);
  });

  test('Reader translation column renders image marker as img node', async ({ page }) => {
    const bookId = 'mock-book';
    const chapterId = 'mock-chapter';

    await page.route('**/books/mock-book', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          id: bookId,
          title: 'Mock Book',
          sourceLang: 'en',
          targetLang: 'zh',
          status: 'completed',
          translationProgress: 100,
          chapterId,
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString(),
        }),
      });
    });

    await page.route('**/chapters/book/mock-book', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify([
          {
            id: chapterId,
            bookId,
            chapterNumber: 1,
            title: 'Mock Chapter',
            status: 'completed',
            translationProgress: 100,
            createdAt: new Date().toISOString(),
            updatedAt: new Date().toISOString(),
          },
        ]),
      });
    });

    await page.route('**/pages/chapter/mock-chapter', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify([
          {
            id: 'p1',
            bookId,
            chapterId,
            pageNumber: 1,
            sourceText: 'Plain source text.',
            targetText: '[[OB_IMAGE:images/test.png|Mock Image]]',
            ocrStatus: 'completed',
            translationStatus: 'completed',
            retryCount: 0,
            errorMessage: null,
            createdAt: new Date().toISOString(),
            updatedAt: new Date().toISOString(),
          },
        ]),
      });
    });

    await page.route('**/books/mock-book/image-asset?path=*', async (route) => {
      const png = fs.readFileSync(path.join(TEST_FILES, 'image-test.png'));
      await route.fulfill({
        status: 200,
        headers: { 'Content-Type': 'image/png' },
        body: png,
      });
    });

    await page.goto('/book/mock-book');
    await page.waitForLoadState('networkidle');

    const img = page.getByRole('img', { name: 'Mock Image' });
    await expect(img).toBeVisible();
  });
});
