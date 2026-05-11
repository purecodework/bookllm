import { test, expect } from '@playwright/test';
import {
  API,
  cleanupBooksByPrefix,
  createBookWithPages,
  createTranslatedBook,
} from './helpers';

const PREFIX = 'E2E-DL';

function cardForBook(page: import('@playwright/test').Page, bookId: string) {
  return page.locator(`a[href="/book/${bookId}"]`).filter({ visible: true }).locator('..');
}

test.beforeEach(async ({ request }) => {
  await cleanupBooksByPrefix(request, PREFIX);
});

test.afterEach(async ({ request }) => {
  await cleanupBooksByPrefix(request, PREFIX);
});

test.describe('Download controls', () => {
  test('book card download button opens format menu for a translated fixture', async ({ page, request }) => {
    const { book } = await createTranslatedBook(request, PREFIX, 'card-menu');

    await page.goto('/');
    const card = cardForBook(page, book.id);

    await expect(card).toBeVisible();
    await card.hover();
    await card.getByTitle('Download').click({ force: true });

    await expect(page.getByText('PDF').first()).toBeVisible();
    await expect(page.getByText('EPUB').first()).toBeVisible();
    await expect(page.getByText('TXT').first()).toBeVisible();
  });

  test('untranslated book card keeps download disabled', async ({ page, request }) => {
    const { book } = await createBookWithPages(request, PREFIX, 'untranslated');

    await page.goto('/');
    const card = cardForBook(page, book.id);

    await expect(card).toBeVisible();
    await card.hover();
    await expect(card.getByTitle('Download')).toBeDisabled();
  });

  test('reader toolbar download menu opens for a translated fixture', async ({ page, request }) => {
    const { book } = await createTranslatedBook(request, PREFIX, 'reader-menu');

    await page.goto(`/book/${book.id}`);
    await page.getByTitle('Download').click();

    await expect(page.getByText('PDF').first()).toBeVisible();
    await expect(page.getByText('EPUB').first()).toBeVisible();
    await expect(page.getByText('TXT').first()).toBeVisible();
  });
});

test.describe('Download API', () => {
  test('TXT and EPUB downloads return attachment responses for a translated fixture', async ({ request }) => {
    const { book } = await createTranslatedBook(request, PREFIX, 'api');

    const txt = await request.get(`${API}/books/${book.id}/download/txt`);
    expect(txt.status()).toBe(200);
    expect(txt.headers()['content-type']).toContain('text/plain');
    expect(txt.headers()['content-disposition']).toContain('attachment');
    expect(await txt.text()).not.toMatch(/第 \d+ 页|--- \d+ ---/);

    const epub = await request.get(`${API}/books/${book.id}/download/epub`);
    expect(epub.status()).toBe(200);
    expect(epub.headers()['content-type']).toContain('epub');
    expect(epub.headers()['content-disposition']).toContain('attachment');
  });

  test('missing book download returns 404', async ({ request }) => {
    const res = await request.get(`${API}/books/nonexistent-id/download/txt`);
    expect(res.status()).toBe(404);
  });
});

test.describe('Print page', () => {
  test('loads print preview for a translated fixture', async ({ page, request }) => {
    const { book } = await createTranslatedBook(request, PREFIX, 'print');

    await page.addInitScript(() => {
      window.print = () => undefined;
    });
    await page.goto(`/book/${book.id}/print`);

    await expect(page.getByText('Print preview')).toBeVisible();
    await expect(page.locator('h1').first()).not.toBeEmpty();
  });
});
