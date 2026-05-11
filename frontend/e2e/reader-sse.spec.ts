import { test, expect } from '@playwright/test';

const API = 'http://localhost:3001';

test('reader applies book SSE token and progress events without re-entering page', async ({ page }) => {
  const bookId = 'book-sse-e2e';
  const chapterId = 'chapter-sse-e2e';
  const pageId = 'page-sse-e2e';

  await page.route(`${API}/books/${bookId}`, async (route) => {
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        id: bookId,
        title: 'SSE Reader Test',
        sourceLang: 'en',
        targetLang: 'zh',
        status: 'processing',
        translationProgress: 0,
        chapterId,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      }),
    });
  });

  await page.route(`${API}/chapters/book/${bookId}`, async (route) => {
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify([
        {
          id: chapterId,
          bookId,
          chapterNumber: 1,
          title: 'Chapter 1',
          status: 'processing',
          translationProgress: 0,
          translationStartedAt: new Date().toISOString(),
          tokensPerSecond: null,
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString(),
          _count: { pages: 1 },
        },
      ]),
    });
  });

  await page.route(`${API}/pages/chapter/${chapterId}`, async (route) => {
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify([
        {
          id: pageId,
          bookId,
          chapterId,
          pageNumber: 1,
          sourceText: 'Hello world.',
          targetText: null,
          ocrStatus: 'completed',
          translationStatus: 'pending',
          retryCount: 0,
          errorMessage: null,
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString(),
        },
      ]),
    });
  });

  await page.route(`${API}/events/book/${bookId}`, async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 300));
    const events = [
      { type: 'queue_state', payload: { bookId, isPaused: false } },
      {
        type: 'chapter_state',
        payload: {
          bookId,
          chapterId,
          status: 'processing',
          translationProgress: 25,
          tokensPerSecond: null,
          translationStartedAt: new Date().toISOString(),
        },
      },
      { type: 'page_token', payload: { bookId, chapterId, pageId, content: '你好，世界' } },
    ];
    await route.fulfill({
      status: 200,
      headers: {
        'content-type': 'text/event-stream',
        'cache-control': 'no-cache',
      },
      body: events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join(''),
    });
  });

  await page.goto(`/book/${bookId}`);

  await expect(page.getByText('Hello world.')).toBeVisible({ timeout: 5000 });
  await expect(page.getByText('25%')).toBeVisible();
});
