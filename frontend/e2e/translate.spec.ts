import { test, expect } from '@playwright/test';
import {
  API,
  cleanupBooksByPrefix,
  createBook,
  createBookWithPages,
  createChapter,
} from './helpers';

const PREFIX = 'E2E-Translate';

test.beforeEach(async ({ request }) => {
  await cleanupBooksByPrefix(request, PREFIX);
});

test.afterEach(async ({ request }) => {
  await cleanupBooksByPrefix(request, PREFIX);
});

test.describe('Translation trigger API', () => {
  test('legacy chapter endpoint is disabled by default', async ({ request }) => {
    const book = await createBook(request, `${PREFIX}-legacy-${Date.now()}`);
    const chapter = await createChapter(request, book.id);

    const res = await request.post(`${API}/chapters/${chapter.id}/translate`);
    expect(res.status()).toBe(400);
    expect(String((await res.json()).message)).toContain('book-level endpoint');
  });

  test('book translation rejects empty books and missing books deterministically', async ({ request }) => {
    const book = await createBook(request, `${PREFIX}-empty-${Date.now()}`);
    await createChapter(request, book.id);

    const empty = await request.post(`${API}/chapters/book/${book.id}/translate`);
    expect(empty.status()).toBe(400);

    const missing = await request.post(`${API}/chapters/book/non-existent-book/translate`);
    expect(missing.status()).toBe(404);
  });
});

test.describe('Translation button UI', () => {
  test('reader shows start button for a book with pending pages', async ({ page, request }) => {
    const { book } = await createBookWithPages(request, PREFIX, 'button', 1);

    await page.goto(`/book/${book.id}`);

    await expect(page.getByRole('button', { name: 'Start' })).toBeVisible();
  });

  test('clicking start sends the book-level translation request and enters loading state', async ({ page, request }) => {
    const { book } = await createBookWithPages(request, PREFIX, 'click', 1);
    let requested = false;

    await page.route(`**/chapters/book/${book.id}/translate`, async (route) => {
      requested = true;
      await route.fulfill({
        status: 202,
        contentType: 'application/json',
        body: JSON.stringify({ enqueuedPages: 1 }),
      });
    });

    await page.goto(`/book/${book.id}`);
    await page.getByRole('button', { name: 'Start' }).click();

    await expect.poll(() => requested).toBe(true);
    await expect(page.getByRole('button', { name: /Start|Translating/ })).toBeVisible();
  });
});
